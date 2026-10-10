import Foundation

public enum PipelineControlPorts {
  public static let completed = "completed"
  public static let repeatPort = "repeat"
  public static let again = "again"
  public static let incrementSeed = "incrementSeed"
  public static let increment = "increment"
}

public struct PipelineActiveLoop: Equatable, Sendable {
  public let outputNodeID: PipelineNodeID
  public let loopNodeID: PipelineNodeID
  public let startNodeID: PipelineNodeID
  public let settings: PipelineLoopSettings
}

public struct PipelineActiveTimeline: Equatable, Sendable {
  public let outputNodeID: PipelineNodeID
  public let timelineNodeID: PipelineNodeID
  public let startNodeID: PipelineNodeID
  public let settings: PipelineTimelineSettings
}

/// Control edges only schedule another whole-graph evaluation. They never
/// participate in data reachability, port values, or topological sorting.
public enum PipelineControlFlow {
  public static let startKind = PipelineNodeKind(rawValue: "control.start")
  public static let loopKind = PipelineNodeKind(rawValue: "control.loop")
  public static let timelineKind = PipelineNodeKind(rawValue: "control.timeline")
  public static let seedKind = PipelineNodeKind(rawValue: "input.seed")

  /// The Seed explicitly selected for incrementing must contribute to the
  /// selected result through the ordinary, acyclic data graph.
  public static func incrementSeedNodeID(
    in document: PipelineDocument, loop: PipelineActiveLoop
  ) -> PipelineNodeID? {
    incrementSeedNodeID(
      in: document, loopNodeID: loop.loopNodeID, outputNodeID: loop.outputNodeID)
  }

  public static func incrementSeedNodeID(
    in document: PipelineDocument,
    loopNodeID: PipelineNodeID,
    outputNodeID: PipelineNodeID
  ) -> PipelineNodeID? {
    let links = document.controlConnections.filter {
      $0.output == .init(nodeID: loopNodeID, port: PipelineControlPorts.incrementSeed)
    }
    guard links.count == 1,
      links[0].input.port == PipelineControlPorts.increment,
      let seed = document.nodes.first(where: {
        $0.id == links[0].input.nodeID && $0.kind == seedKind
          && $0.executionState == .enabled
      })
    else { return nil }
    var visited: Set<PipelineNodeID> = []
    var pending = document.connections.filter {
      $0.output == .init(nodeID: seed.id, port: "seed")
    }.map(\.input.nodeID)
    while let next = pending.popLast() {
      if next == outputNodeID { return seed.id }
      guard visited.insert(next).inserted else { continue }
      pending.append(contentsOf: document.connections.filter {
        $0.output.nodeID == next
      }.map(\.input.nodeID))
    }
    return nil
  }

  public static func activeLoop(
    in document: PipelineDocument, registry: PipelineNodeRegistry
  ) -> PipelineActiveLoop? {
    guard let output = PipelineGraphOutputs.selectedOutputNode(
      in: document, registry: registry)
    else { return nil }
    let loops = document.nodes.filter {
      $0.kind == loopKind && $0.executionState == .enabled
    }
    let starts = document.nodes.filter {
      $0.kind == startKind && $0.executionState == .enabled
    }
    let matching = loops.compactMap { loop -> PipelineActiveLoop? in
      guard let settings = PipelineLoopSettings(node: loop) else { return nil }
      let intoLoop = document.controlConnections.filter {
        $0.input == .init(nodeID: loop.id, port: PipelineControlPorts.completed)
      }
      let outOfLoop = document.controlConnections.filter {
        $0.output == .init(nodeID: loop.id, port: PipelineControlPorts.repeatPort)
      }
      guard intoLoop.count == 1, outOfLoop.count == 1,
        intoLoop[0].output == .init(
          nodeID: output.id, port: PipelineControlPorts.completed),
        let start = starts.first(where: {
          outOfLoop[0].input == .init(
            nodeID: $0.id, port: PipelineControlPorts.again)
        }),
        document.controlConnections.filter({
          $0.input == .init(nodeID: start.id, port: PipelineControlPorts.again)
        }).count == 1
      else { return nil }
      return PipelineActiveLoop(
        outputNodeID: output.id, loopNodeID: loop.id,
        startNodeID: start.id, settings: settings)
    }
    return matching.count == 1 ? matching[0] : nil
  }

  public static func activeTimeline(
    in document: PipelineDocument, registry: PipelineNodeRegistry
  ) -> PipelineActiveTimeline? {
    guard let output = PipelineGraphOutputs.selectedOutputNode(
      in: document, registry: registry)
    else { return nil }
    let timelines = document.nodes.filter {
      $0.kind == timelineKind && $0.executionState == .enabled
    }
    let starts = document.nodes.filter {
      $0.kind == startKind && $0.executionState == .enabled
    }
    let matching = timelines.compactMap { timeline -> PipelineActiveTimeline? in
      guard let settings = PipelineTimelineSettings(node: timeline) else { return nil }
      let intoTimeline = document.controlConnections.filter {
        $0.input == .init(nodeID: timeline.id, port: PipelineControlPorts.completed)
      }
      let outOfTimeline = document.controlConnections.filter {
        $0.output == .init(nodeID: timeline.id, port: PipelineControlPorts.repeatPort)
      }
      guard intoTimeline.count == 1, outOfTimeline.count == 1,
        intoTimeline[0].output == .init(
          nodeID: output.id, port: PipelineControlPorts.completed),
        let start = starts.first(where: {
          outOfTimeline[0].input == .init(
            nodeID: $0.id, port: PipelineControlPorts.again)
        }),
        document.controlConnections.filter({
          $0.input == .init(nodeID: start.id, port: PipelineControlPorts.again)
        }).count == 1
      else { return nil }
      return PipelineActiveTimeline(
        outputNodeID: output.id, timelineNodeID: timeline.id,
        startNodeID: start.id, settings: settings)
    }
    return matching.count == 1 ? matching[0] : nil
  }

  public static func isAllowedControlEdge(
    output: PipelinePortReference,
    input: PipelinePortReference,
    in document: PipelineDocument,
    registry: PipelineNodeRegistry
  ) -> Bool {
    guard let source = document.nodes.first(where: { $0.id == output.nodeID }),
      let destination = document.nodes.first(where: { $0.id == input.nodeID })
    else { return false }
    if output.port == PipelineControlPorts.completed,
      input.port == PipelineControlPorts.completed,
      (destination.kind == loopKind || destination.kind == timelineKind) {
      return PipelineGraphOutputs.selectedOutputNode(
        in: document, registry: registry)?.id == source.id
    }
    if source.kind == loopKind && destination.kind == seedKind,
      output.port == PipelineControlPorts.incrementSeed,
      input.port == PipelineControlPorts.increment {
      return true
    }
    return (source.kind == loopKind || source.kind == timelineKind)
      && destination.kind == startKind
      && output.port == PipelineControlPorts.repeatPort
      && input.port == PipelineControlPorts.again
  }
}

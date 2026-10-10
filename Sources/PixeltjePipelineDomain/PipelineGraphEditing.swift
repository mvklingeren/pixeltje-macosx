import Foundation

public enum PipelineConnectionRejection: Equatable, Sendable {
  case missingNode
  case missingPort
  case sameNode
  case duplicate
  case occupiedInput
  case incompatibleTypes
  case cycle

  public var message: String {
    switch self {
    case .missingNode:
      "One of the connection's nodes no longer exists."
    case .missingPort:
      "One of the connection's ports no longer exists."
    case .sameNode:
      "A node cannot connect to itself."
    case .duplicate:
      "That connection already exists."
    case .occupiedInput:
      "That input already has a connection."
    case .incompatibleTypes:
      "The output and input port types are incompatible."
    case .cycle:
      "That connection would create a cycle."
    }
  }
}

public struct PipelineConnectionDecision: Equatable, Sendable {
  public var rejection: PipelineConnectionRejection?

  public init(rejection: PipelineConnectionRejection? = nil) {
    self.rejection = rejection
  }

  public var isAllowed: Bool { rejection == nil }
}

/// Shared admission rules for interactive graph editors. The complete graph is
/// still validated after mutation; this prevents gestures from inserting
/// edges that are known to be structurally impossible.
public enum PipelineGraphEditing {
  public static func descriptor(
    for node: PipelineNode,
    registry: PipelineNodeRegistry
  ) -> PipelineNodeDescriptor? {
    guard var descriptor = registry.descriptor(for: node.kind) ?? node.importedDescriptor else {
      return nil
    }
    guard node.kind.rawValue == "cache.assets" else { return descriptor }
    let savedCount: Int64 = if case .integer(let value)? = node.parameters["slotCount"] {
      value
    } else {
      1
    }
    let count = Int(min(max(savedCount, 1), 16))
    for index in 0..<count {
      let name = "asset\(index)"
      descriptor.inputs.append(.init(name: name, type: .any,
        typeVariable: name))
      descriptor.outputs.append(.init(name: name, type: .any,
        typeVariable: name))
    }
    return descriptor
  }

  public static func connectionDecision(
    in document: PipelineDocument,
    output: PipelinePortReference,
    input: PipelinePortReference,
    registry: PipelineNodeRegistry,
    engineVersion: Int = 1
  ) -> PipelineConnectionDecision {
    guard let outputNode = document.nodes.first(where: { $0.id == output.nodeID }),
      let inputNode = document.nodes.first(where: { $0.id == input.nodeID })
    else {
      return PipelineConnectionDecision(rejection: .missingNode)
    }
    guard output.nodeID != input.nodeID else {
      return PipelineConnectionDecision(rejection: .sameNode)
    }
    guard let outputDescriptor = descriptor(for: outputNode, registry: registry),
      let outputPort = outputDescriptor.output(named: output.port),
      let inputDescriptor = descriptor(for: inputNode, registry: registry),
      let inputPort = inputDescriptor.input(named: input.port)
    else {
      return PipelineConnectionDecision(rejection: .missingPort)
    }
    if outputPort.type == .control || inputPort.type == .control {
      guard outputPort.type == .control, inputPort.type == .control,
        PipelineControlFlow.isAllowedControlEdge(
          output: output, input: input, in: document, registry: registry)
      else { return PipelineConnectionDecision(rejection: .incompatibleTypes) }
      if document.controlConnections.contains(where: {
        $0.output == output && $0.input == input
      }) {
        return PipelineConnectionDecision(rejection: .duplicate)
      }
      if document.controlConnections.contains(where: { $0.input == input }) {
        return PipelineConnectionDecision(rejection: .occupiedInput)
      }
      if document.controlConnections.count >= 3 {
        return PipelineConnectionDecision(rejection: .occupiedInput)
      }
      return PipelineConnectionDecision()
    }
    if document.connections.contains(where: { $0.output == output && $0.input == input }) {
      return PipelineConnectionDecision(rejection: .duplicate)
    }
    if !inputPort.allowsMultipleConnections,
      document.connections.contains(where: { $0.input == input })
    {
      return PipelineConnectionDecision(rejection: .occupiedInput)
    }
    if isReachable(from: input.nodeID, to: output.nodeID, in: document.connections) {
      return PipelineConnectionDecision(rejection: .cycle)
    }

    var candidate = document
    let candidateIndex = candidate.connections.count
    candidate.connections.append(PipelineConnection(output: output, input: input))
    let report = PipelineGraphValidator.validate(
      candidate,
      registry: registry,
      engineVersion: engineVersion)
    if report.errors.contains(where: {
      $0.connectionIndex == candidateIndex && $0.code == .incompatiblePorts
    }) {
      return PipelineConnectionDecision(rejection: .incompatibleTypes)
    }
    return PipelineConnectionDecision()
  }

  private static func isReachable(
    from start: PipelineNodeID,
    to target: PipelineNodeID,
    in connections: [PipelineConnection]
  ) -> Bool {
    var outgoing: [PipelineNodeID: Set<PipelineNodeID>] = [:]
    for connection in connections {
      outgoing[connection.output.nodeID, default: []].insert(connection.input.nodeID)
    }
    var visited: Set<PipelineNodeID> = [start]
    var pending = [start]
    while let nodeID = pending.popLast() {
      for next in outgoing[nodeID] ?? [] {
        if next == target { return true }
        if visited.insert(next).inserted { pending.append(next) }
      }
    }
    return false
  }
}

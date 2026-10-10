import Foundation

public struct ModelIssue: Equatable, Sendable, Identifiable {
  public var id: String { "\(nodeID?.uuidString ?? "document"):\(message)" }
  public var nodeID: UUID?
  public var message: String

  public init(_ message: String, nodeID: UUID? = nil) {
    self.nodeID = nodeID
    self.message = message
  }
}

public struct ModelValidationReport: Sendable {
  public var issues: [ModelIssue]
  public var orderedNodeIDs: [UUID]
  public var shapes: [UUID: [Int]]
  public var isValid: Bool { issues.isEmpty }
}

public enum ModelDesignValidator {
  public static func validate(_ document: ModelDesignDocument) -> ModelValidationReport {
    var issues: [ModelIssue] = []
    if document.schemaVersion != ModelDesignDocument.currentSchemaVersion {
      issues.append(.init("Unsupported model-design schema version."))
    }
    if document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.init("Give the model a name."))
    }
    if document.training.epochs < 1 || document.training.batchSize < 1
      || !document.training.learningRate.isFinite || document.training.learningRate <= 0
    {
      issues.append(.init("Training needs positive epochs, batch size, and learning rate."))
    }

    let nodes = Dictionary(document.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    if nodes.count != document.nodes.count { issues.append(.init("Node IDs must be unique.")) }
    let inputs = document.nodes.filter { $0.kind == .input }
    let outputs = document.nodes.filter { $0.kind == .output }
    if !document.nodes.contains(where: {
      $0.kind == .layer && ($0.layer == .conv2d || $0.layer == .dense)
    }) {
      issues.append(.init("Training needs at least one parameterized layer."))
    }
    if inputs.count != 1 || outputs.count != 1 {
      issues.append(.init("This first training workflow needs exactly one input and one output."))
    }

    var incoming: [UUID: [String: UUID]] = [:]
    var outgoing: [UUID: [UUID]] = [:]
    var indegree = Dictionary(uniqueKeysWithValues: nodes.keys.map { ($0, 0) })
    var seenEdges: Set<ModelEdge> = []
    for edge in document.edges {
      guard let source = nodes[edge.source], let target = nodes[edge.target] else {
        issues.append(.init("A connection refers to a missing node."))
        continue
      }
      if !seenEdges.insert(edge).inserted {
        issues.append(.init("Duplicate connection.", nodeID: target.id))
        continue
      }
      if source.id == target.id || source.kind == .output || target.kind == .input {
        issues.append(.init("Invalid connection direction.", nodeID: target.id))
        continue
      }
      let validPorts = target.kind == .merge ? ["left", "right"] : ["input"]
      if !validPorts.contains(edge.input) {
        issues.append(.init("Unknown input port \(edge.input).", nodeID: target.id))
        continue
      }
      if incoming[target.id, default: [:]][edge.input] != nil {
        issues.append(.init("Input \(edge.input) already has a connection.", nodeID: target.id))
        continue
      }
      incoming[target.id, default: [:]][edge.input] = source.id
      outgoing[source.id, default: []].append(target.id)
      indegree[target.id, default: 0] += 1
    }

    var ready = indegree.filter { $0.value == 0 }.map(\.key).sorted { $0.uuidString < $1.uuidString }
    var ordered: [UUID] = []
    while !ready.isEmpty {
      let id = ready.removeFirst()
      ordered.append(id)
      for next in outgoing[id, default: []] {
        indegree[next, default: 0] -= 1
        if indegree[next] == 0 {
          ready.append(next)
          ready.sort { $0.uuidString < $1.uuidString }
        }
      }
    }
    if ordered.count != nodes.count { issues.append(.init("Model connections contain a cycle.")) }

    var shapes: [UUID: [Int]] = [:]
    for id in ordered {
      guard let node = nodes[id] else { continue }
      let ports = incoming[id, default: [:]]
      switch node.kind {
      case .input:
        if node.shape.isEmpty || node.shape.count > 4 || node.shape.contains(where: { $0 <= 0 }) {
          issues.append(.init("Input shape needs 1–4 positive dimensions, excluding batch.", nodeID: id))
        } else {
          shapes[id] = node.shape
        }
      case .layer:
        guard let predecessor = ports["input"], let shape = shapes[predecessor] else {
          issues.append(.init("Connect a valid tensor to input.", nodeID: id))
          continue
        }
        guard let operation = node.layer else {
          issues.append(.init("Choose a layer operation.", nodeID: id))
          continue
        }
        switch operation {
        case .relu:
          shapes[id] = shape
        case .conv2d:
          if shape.count != 3 || node.units < 1 || node.kernelSize < 1
            || node.kernelSize % 2 == 0 {
            issues.append(.init("Conv2D needs [channels, height, width], positive filters, and an odd kernel size.", nodeID: id))
          } else {
            shapes[id] = [node.units, shape[1], shape[2]]
          }
        case .dense:
          if shape.count != 1 || node.units < 1 {
            issues.append(.init("Dense needs a vector input and positive units.", nodeID: id))
          } else {
            shapes[id] = [node.units]
          }
        case .flatten:
          let count = shape.reduce(1) { partial, dimension in
            let (value, overflow) = partial.multipliedReportingOverflow(by: dimension)
            return overflow ? 0 : value
          }
          if count == 0 {
            issues.append(.init("Flattened tensor is too large.", nodeID: id))
          } else {
            shapes[id] = [count]
          }
        }
      case .merge:
        guard let left = ports["left"].flatMap({ shapes[$0] }),
          let right = ports["right"].flatMap({ shapes[$0] }) else {
          issues.append(.init("Connect both merge inputs.", nodeID: id))
          continue
        }
        guard let operation = node.merge else {
          issues.append(.init("Choose a merge operation.", nodeID: id))
          continue
        }
        switch operation {
        case .add:
          if left == right { shapes[id] = left }
          else { issues.append(.init("Add requires equal tensor shapes.", nodeID: id)) }
        case .concatenate:
          if left.count != right.count || !left.indices.contains(node.axis)
            || left.indices.contains(where: { $0 != node.axis && left[$0] != right[$0] }) {
            issues.append(.init("Concatenate requires matching dimensions outside its axis.", nodeID: id))
          } else {
            var shape = left
            let (dimension, overflow) = left[node.axis].addingReportingOverflow(right[node.axis])
            if overflow { issues.append(.init("Concatenated tensor is too large.", nodeID: id)) }
            else { shape[node.axis] = dimension; shapes[id] = shape }
          }
        }
      case .output:
        guard let predecessor = ports["input"], let shape = shapes[predecessor] else {
          issues.append(.init("Connect a valid tensor to output.", nodeID: id))
          continue
        }
        shapes[id] = shape
      }
    }

    if let input = inputs.first, let output = outputs.first,
      let inputShape = shapes[input.id], let outputShape = shapes[output.id] {
      switch document.training.resolvedTask {
      case .pairedImages:
        if inputShape.count != 3 || inputShape[0] != 3 || outputShape != inputShape {
          issues.append(.init("Paired-image training requires RGB input and an output of the same shape."))
        }
      case .classification:
        if inputShape.count != 3 || outputShape.count != 1 || outputShape[0] < 2 {
          issues.append(.init("Image classification requires [channels, height, width] input and a vector of at least two class scores."))
        }
        if document.training.datasetPreset == .mnist
          && (inputShape != [1, 28, 28] || outputShape != [10]) {
          issues.append(.init("MNIST needs [1, 28, 28] input and ten output scores."))
        }
      }
    }
    if document.training.datasetPreset != nil
      && document.training.resolvedTask != .classification {
      issues.append(.init("The MNIST dataset preset requires classification training."))
    }
    if let output = outputs.first {
      var reachable: Set<UUID> = [output.id]
      var pending = [output.id]
      while let id = pending.popLast() {
        for source in incoming[id, default: [:]].values where reachable.insert(source).inserted {
          pending.append(source)
        }
      }
      for node in document.nodes where !reachable.contains(node.id) {
        issues.append(.init("Node does not contribute to the output.", nodeID: node.id))
      }
    }
    return ModelValidationReport(issues: issues, orderedNodeIDs: ordered, shapes: shapes)
  }
}

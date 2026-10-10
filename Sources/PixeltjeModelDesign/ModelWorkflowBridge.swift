import CryptoKit
import Foundation
import PixeltjePipelineDomain

public extension PipelineNodeKind {
  static let modelInput = PipelineNodeKind(rawValue: "model.input")
  static let modelLayer = PipelineNodeKind(rawValue: "model.layer")
  static let modelMerge = PipelineNodeKind(rawValue: "model.merge")
  static let modelOutput = PipelineNodeKind(rawValue: "model.output")
  static let modelTrain = PipelineNodeKind(rawValue: "model.train")
}

public extension PipelinePortType {
  /// A symbolic tensor in an architecture graph, never image pixels.
  static let modelTensor = PipelinePortType(rawValue: "modelTensor")
  static let modelDefinition = PipelinePortType(rawValue: "modelDefinition")
}

public enum ModelWorkflowError: Error, LocalizedError {
  case invalid(String)

  public var errorDescription: String? {
    guard case .invalid(let message) = self else { return nil }
    return message
  }
}

/// Adapts the existing model compiler to the canonical PipelineDocument graph.
/// The old .pixmodel.json shape remains supported only as an import source.
public enum ModelWorkflowBridge {
  public static let modelKinds: Set<PipelineNodeKind> = [
    .modelInput, .modelLayer, .modelMerge, .modelOutput,
  ]

  public static func trainingNode(in document: PipelineDocument) -> PipelineNode? {
    if let selected = document.primaryOutputNodeIDs?.first,
      let node = document.nodes.first(where: { $0.id == selected && $0.kind == .modelTrain }) {
      return node
    }
    return document.nodes.first { $0.kind == .modelTrain && $0.executionState == .enabled }
  }

  public static func design(in document: PipelineDocument) throws -> ModelDesignDocument {
    guard let train = trainingNode(in: document) else {
      throw ModelWorkflowError.invalid("Select a connected Train Model output.")
    }
    return try design(in: document, for: train.id)
  }

  public static func design(
    in document: PipelineDocument, for trainID: PipelineNodeID
  ) throws -> ModelDesignDocument {
    guard let train = document.nodes.first(where: {
      $0.id == trainID && $0.kind == .modelTrain && $0.executionState == .enabled
    }) else {
      throw ModelWorkflowError.invalid("The Train Model output is unavailable.")
    }
    let nodesByID = Dictionary(document.nodes.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    guard let modelConnection = document.connections.first(where: {
      $0.input.nodeID == trainID && $0.input.port == "model"
    }), let output = nodesByID[modelConnection.output.nodeID],
      output.kind == .modelOutput else {
      throw ModelWorkflowError.invalid("Connect Model Output to Train Model's model input.")
    }
    let incoming = Dictionary(grouping: document.connections, by: \.input.nodeID)
    var pending = [output.id]
    var contributing: Set<PipelineNodeID> = []
    while let id = pending.popLast() {
      guard contributing.insert(id).inserted else { continue }
      guard let node = nodesByID[id], modelKinds.contains(node.kind),
        node.executionState == .enabled else {
        throw ModelWorkflowError.invalid("The model architecture contains an unsupported node.")
      }
      pending.append(contentsOf: (incoming[id] ?? []).map(\.output.nodeID))
    }
    let modelNodes = try document.nodes.filter { contributing.contains($0.id) }.map { node in
      try modelNode(node, position: document.presentation?.nodePositions[node.id.rawValue])
    }
    let edges = document.connections.compactMap { connection -> ModelEdge? in
      guard contributing.contains(connection.input.nodeID),
        contributing.contains(connection.output.nodeID) else { return nil }
      return ModelEdge(
        source: stableUUID(connection.output.nodeID.rawValue),
        target: stableUUID(connection.input.nodeID.rawValue),
        input: connection.input.port)
    }
    let taskName = string(train, "task", default: ModelTrainingTask.pairedImages.rawValue)
    guard let task = ModelTrainingTask(rawValue: taskName) else {
      throw ModelWorkflowError.invalid("Choose paired-image or classification training.")
    }
    let presetName = string(train, "datasetPreset", default: "none")
    guard presetName == "none" || ModelDatasetPreset(rawValue: presetName) != nil else {
      throw ModelWorkflowError.invalid("Choose a supported dataset preset.")
    }
    let preset = ModelDatasetPreset(rawValue: presetName)
    if task == .classification && preset == nil
      && !document.connections.contains(where: {
        $0.input.nodeID == trainID && $0.input.port == "dataset"
      }) {
      throw ModelWorkflowError.invalid(
        "Classification needs a connected dataset or the MNIST preset.")
    }
    let design = ModelDesignDocument(
      id: stableUUID(document.id.rawValue), name: document.name,
      nodes: modelNodes, edges: edges,
      training: ModelTrainingRecipe(
        epochs: integer(train, "epochs", default: 10),
        batchSize: integer(train, "batchSize", default: 8),
        learningRate: number(train, "learningRate", default: 0.001),
        seed: integer(train, "seed", default: 42),
        task: task == .classification ? task : nil,
        datasetPreset: preset))
    let report = ModelDesignValidator.validate(design)
    guard report.isValid else {
      throw ModelWorkflowError.invalid(report.issues.map(\.message).joined(separator: "\n"))
    }
    return design
  }

  public static func importLegacy(_ design: ModelDesignDocument) -> PipelineDocument {
    let trainID = PipelineNodeID(rawValue: "model-train")
    let pipelineNodes = design.nodes.map { node -> PipelineNode in
      let kind: PipelineNodeKind
      var parameters: [String: PipelineValue] = ["name": .string(node.name)]
      switch node.kind {
      case .input:
        kind = .modelInput
        parameters["channels"] = .integer(Int64(node.shape.first ?? 3))
        parameters["height"] = .integer(Int64(node.shape.dropFirst().first ?? 64))
        parameters["width"] = .integer(Int64(node.shape.dropFirst(2).first ?? 64))
        parameters["dtype"] = .string("float32")
      case .layer:
        kind = .modelLayer
        parameters["operation"] = .string(node.layer?.rawValue ?? "conv2d")
        parameters["units"] = .integer(Int64(node.units))
        parameters["kernelSize"] = .integer(Int64(node.kernelSize))
      case .merge:
        kind = .modelMerge
        parameters["operation"] = .string(node.merge?.rawValue ?? "add")
        parameters["axis"] = .integer(Int64(node.axis))
      case .output:
        kind = .modelOutput
      }
      return PipelineNode(
        id: PipelineNodeID(rawValue: node.id.uuidString.lowercased()),
        kind: kind, title: node.name, parameters: parameters)
    }
    let ids = Dictionary(uniqueKeysWithValues: design.nodes.map {
      ($0.id, PipelineNodeID(rawValue: $0.id.uuidString.lowercased()))
    })
    var connections = design.edges.compactMap { edge -> PipelineConnection? in
      guard let source = ids[edge.source], let target = ids[edge.target] else { return nil }
      return PipelineConnection(
        output: .init(nodeID: source, port: "tensor"),
        input: .init(nodeID: target, port: edge.input))
    }
    if let output = design.nodes.first(where: { $0.kind == .output }),
      let outputID = ids[output.id] {
      connections.append(.init(
        output: .init(nodeID: outputID, port: "model"),
        input: .init(nodeID: trainID, port: "model")))
    }
    let training = design.training
    var trainParameters: [String: PipelineValue] = [
        "epochs": .integer(Int64(training.epochs)),
        "batchSize": .integer(Int64(training.batchSize)),
        "learningRate": .number(training.learningRate),
        "seed": .integer(Int64(training.seed)),
      ]
    if let task = training.task { trainParameters["task"] = .string(task.rawValue) }
    if let preset = training.datasetPreset {
      trainParameters["datasetPreset"] = .string(preset.rawValue)
    }
    let train = PipelineNode(id: trainID, kind: .modelTrain, title: "Train Model",
      parameters: trainParameters)
    var positions = Dictionary(uniqueKeysWithValues: design.nodes.map { node in
      (node.id.uuidString.lowercased(),
        PipelinePoint(x: node.position.x, y: node.position.y))
    })
    positions[trainID.rawValue] = PipelinePoint(x: 760, y: 150)
    return PipelineDocument(
      id: PipelineID(rawValue: design.id.uuidString.lowercased()),
      name: design.name, mode: .generic, nodes: pipelineNodes + [train],
      connections: connections, primaryOutputNodeIDs: [trainID],
      presentation: PipelinePresentation(nodePositions: positions))
  }

  private static func modelNode(
    _ node: PipelineNode, position: PipelinePoint?
  ) throws -> ModelNode {
    let kind: ModelNodeKind
    switch node.kind {
    case .modelInput: kind = .input
    case .modelLayer: kind = .layer
    case .modelMerge: kind = .merge
    case .modelOutput: kind = .output
    default: throw ModelWorkflowError.invalid("Unsupported model node \(node.kind.rawValue).")
    }
    if kind == .input && string(node, "dtype", default: "float32") != "float32" {
      throw ModelWorkflowError.invalid("Model Input currently supports float32 tensors only.")
    }
    return ModelNode(
      id: stableUUID(node.id.rawValue), kind: kind,
      name: string(node, "name", default: node.title ?? kind.rawValue),
      position: ModelPoint(x: position?.x ?? 0, y: position?.y ?? 0),
      shape: kind == .input ? [
        integer(node, "channels", default: 3),
        integer(node, "height", default: 64),
        integer(node, "width", default: 64),
      ] : [],
      layer: kind == .layer
        ? ModelLayerOperation(rawValue: string(node, "operation", default: "conv2d")) : nil,
      merge: kind == .merge
        ? ModelMergeOperation(rawValue: string(node, "operation", default: "add")) : nil,
      units: integer(node, "units", default: 16),
      kernelSize: integer(node, "kernelSize", default: 3),
      axis: integer(node, "axis", default: 0))
  }

  private static func stableUUID(_ value: String) -> UUID {
    if let uuid = UUID(uuidString: value) { return uuid }
    let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  private static func string(_ node: PipelineNode, _ name: String, default fallback: String) -> String {
    guard case .string(let value)? = node.parameters[name] else { return fallback }
    return value
  }

  private static func integer(_ node: PipelineNode, _ name: String, default fallback: Int) -> Int {
    guard case .integer(let value)? = node.parameters[name],
      let exact = Int(exactly: value) else { return fallback }
    return exact
  }

  private static func number(_ node: PipelineNode, _ name: String, default fallback: Double) -> Double {
    guard case .number(let value)? = node.parameters[name] else { return fallback }
    return value
  }
}

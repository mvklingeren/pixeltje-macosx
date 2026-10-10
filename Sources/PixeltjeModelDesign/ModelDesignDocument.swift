import CryptoKit
import Foundation

public struct ModelPoint: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public enum ModelNodeKind: String, Codable, CaseIterable, Sendable {
  case input, layer, merge, output
}

public enum ModelLayerOperation: String, Codable, CaseIterable, Sendable {
  case conv2d, relu, dense, flatten
}

public enum ModelMergeOperation: String, Codable, CaseIterable, Sendable {
  case add, concatenate
}

public struct ModelNode: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var kind: ModelNodeKind
  public var name: String
  public var position: ModelPoint
  /// Excludes the batch dimension. Image tensors use channels-first order.
  public var shape: [Int]
  public var layer: ModelLayerOperation?
  public var merge: ModelMergeOperation?
  public var units: Int
  public var kernelSize: Int
  public var axis: Int

  public init(
    id: UUID = UUID(), kind: ModelNodeKind, name: String,
    position: ModelPoint, shape: [Int] = [],
    layer: ModelLayerOperation? = nil, merge: ModelMergeOperation? = nil,
    units: Int = 16, kernelSize: Int = 3, axis: Int = 0
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.position = position
    self.shape = shape
    self.layer = layer
    self.merge = merge
    self.units = units
    self.kernelSize = kernelSize
    self.axis = axis
  }

  public static func make(_ kind: ModelNodeKind, at position: ModelPoint) -> ModelNode {
    switch kind {
    case .input: ModelNode(kind: .input, name: "image", position: position, shape: [3, 64, 64])
    case .layer: ModelNode(kind: .layer, name: "Conv2D", position: position, layer: .conv2d)
    case .merge: ModelNode(kind: .merge, name: "Add", position: position, merge: .add)
    case .output: ModelNode(kind: .output, name: "output", position: position)
    }
  }
}

public struct ModelEdge: Codable, Equatable, Hashable, Sendable {
  public var source: UUID
  public var target: UUID
  /// Unary nodes use `input`; merge nodes use `left` and `right`.
  public var input: String

  public init(source: UUID, target: UUID, input: String = "input") {
    self.source = source
    self.target = target
    self.input = input
  }
}

public enum ModelTrainingTask: String, Codable, Sendable {
  case pairedImages
  case classification
}

public enum ModelDatasetPreset: String, Codable, Sendable {
  case mnist
}

public struct ModelTrainingRecipe: Codable, Equatable, Sendable {
  public var epochs: Int
  public var batchSize: Int
  public var learningRate: Double
  public var seed: Int
  /// Optional so schema-one model designs retain their original checkpoint hash.
  public var task: ModelTrainingTask?
  public var datasetPreset: ModelDatasetPreset?

  public var resolvedTask: ModelTrainingTask { task ?? .pairedImages }

  public init(
    epochs: Int = 10, batchSize: Int = 8, learningRate: Double = 0.001,
    seed: Int = 42, task: ModelTrainingTask? = nil,
    datasetPreset: ModelDatasetPreset? = nil
  ) {
    self.epochs = epochs
    self.batchSize = batchSize
    self.learningRate = learningRate
    self.seed = seed
    self.task = task
    self.datasetPreset = datasetPreset
  }
}

public struct ModelDesignDocument: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public var schemaVersion: Int
  public var id: UUID
  public var name: String
  public var nodes: [ModelNode]
  public var edges: [ModelEdge]
  public var training: ModelTrainingRecipe

  public init(
    schemaVersion: Int = currentSchemaVersion, id: UUID = UUID(),
    name: String, nodes: [ModelNode] = [], edges: [ModelEdge] = [],
    training: ModelTrainingRecipe = .init()
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.name = name
    self.nodes = nodes
    self.edges = edges
    self.training = training
  }

  public static func starter() -> ModelDesignDocument {
    let input = ModelNode.make(.input, at: .init(x: 40, y: 150))
    var convolution = ModelNode.make(.layer, at: .init(x: 280, y: 150))
    convolution.units = 3
    let output = ModelNode.make(.output, at: .init(x: 520, y: 150))
    return ModelDesignDocument(name: "Image Model", nodes: [input, convolution, output], edges: [
      .init(source: input.id, target: convolution.id),
      .init(source: convolution.id, target: output.id),
    ])
  }

  public static func mnistStarter() -> ModelDesignDocument {
    var input = ModelNode.make(.input, at: .init(x: 40, y: 150))
    input.shape = [1, 28, 28]
    input.name = "Digit image"
    var convolution = ModelNode.make(.layer, at: .init(x: 250, y: 150))
    convolution.name = "Conv2D · 8 filters"
    convolution.units = 8
    var activation = ModelNode.make(.layer, at: .init(x: 460, y: 150))
    activation.name = "ReLU"
    activation.layer = .relu
    var flatten = ModelNode.make(.layer, at: .init(x: 670, y: 150))
    flatten.name = "Flatten"
    flatten.layer = .flatten
    var dense = ModelNode.make(.layer, at: .init(x: 880, y: 150))
    dense.name = "Ten digit scores"
    dense.layer = .dense
    dense.units = 10
    let output = ModelNode.make(.output, at: .init(x: 1_090, y: 150))
    let layers = [input, convolution, activation, flatten, dense, output]
    return ModelDesignDocument(
      name: "MNIST Digit Classifier", nodes: layers,
      edges: zip(layers, layers.dropFirst()).map { pair in
        .init(source: pair.0.id, target: pair.1.id)
      },
      training: .init(epochs: 3, batchSize: 128, task: .classification,
        datasetPreset: .mnist))
  }
}

public enum ModelDesignJSON {
  public static func encode(_ document: ModelDesignDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(document)
  }

  public static func decode(_ data: Data) throws -> ModelDesignDocument {
    try JSONDecoder().decode(ModelDesignDocument.self, from: data)
  }

  /// Checkpoint identity depends on the architecture and training task, not
  /// canvas layout, display names, dataset location, or hyperparameters.
  public static func architectureSHA256(_ document: ModelDesignDocument) throws -> String {
    var semantic = document
    semantic.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    semantic.name = ""
    semantic.training = .init(task: document.training.resolvedTask == .classification
      ? .classification : nil)
    semantic.nodes = semantic.nodes.map { node in
      var result = node
      result.name = ""
      result.position = .init(x: 0, y: 0)
      switch result.kind {
      case .input:
        result.layer = nil
        result.merge = nil
        result.units = 0
        result.kernelSize = 0
        result.axis = 0
      case .layer:
        result.shape = []
        result.merge = nil
        result.axis = 0
        if result.layer != .conv2d { result.kernelSize = 0 }
        if result.layer != .conv2d && result.layer != .dense { result.units = 0 }
      case .merge:
        result.shape = []
        result.layer = nil
        result.units = 0
        result.kernelSize = 0
        if result.merge != .concatenate { result.axis = 0 }
      case .output:
        result.shape = []
        result.layer = nil
        result.merge = nil
        result.units = 0
        result.kernelSize = 0
        result.axis = 0
      }
      return result
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    semantic.edges.sort {
      ($0.source.uuidString, $0.target.uuidString, $0.input)
        < ($1.source.uuidString, $1.target.uuidString, $1.input)
    }
    let digest = SHA256.hash(data: try encode(semantic))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

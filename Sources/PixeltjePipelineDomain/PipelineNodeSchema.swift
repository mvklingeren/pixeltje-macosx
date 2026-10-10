import Foundation

/// A semantic value carried by a graph edge. Shape and model-family checks are
/// additional engine validation layered on top of this structural type.
public struct PipelinePortType: Codable, Hashable, RawRepresentable, Sendable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let prompt = PipelinePortType(rawValue: "prompt")
  public static let boolean = PipelinePortType(rawValue: "boolean")
  public static let integer = PipelinePortType(rawValue: "integer")
  public static let number = PipelinePortType(rawValue: "number")
  public static let curve1D = PipelinePortType(rawValue: "curve1D")
  public static let mesh3D = PipelinePortType(rawValue: "mesh3D")
  public static let matrix4x4 = PipelinePortType(rawValue: "matrix4x4")
  public static let string = PipelinePortType(rawValue: "string")
  public static let stringList = PipelinePortType(rawValue: "stringList")
  public static let tokens = PipelinePortType(rawValue: "tokens")
  public static let conditioning = PipelinePortType(rawValue: "conditioning")
  public static let seed = PipelinePortType(rawValue: "seed")
  public static let image = PipelinePortType(rawValue: "image")
  public static let assetBundle = PipelinePortType(rawValue: "assetBundle")
  public static let mask = PipelinePortType(rawValue: "mask")
  public static let labeledMasks = PipelinePortType(rawValue: "labeledMasks")
  public static let video = PipelinePortType(rawValue: "video")
  public static let audio = PipelinePortType(rawValue: "audio")
  public static let latent = PipelinePortType(rawValue: "latent")
  public static let noise = PipelinePortType(rawValue: "noise")
  public static let schedule = PipelinePortType(rawValue: "schedule")
  public static let modelFunction = PipelinePortType(rawValue: "modelFunction")
  public static let textEncoderFunction = PipelinePortType(rawValue: "textEncoderFunction")
  public static let languageModelFunction = PipelinePortType(rawValue: "languageModelFunction")
  public static let vaeFunction = PipelinePortType(rawValue: "vaeFunction")
  public static let samplerFunction = PipelinePortType(rawValue: "samplerFunction")
  public static let upscaleModelFunction = PipelinePortType(rawValue: "upscaleModelFunction")
  public static let controlNetFunction = PipelinePortType(rawValue: "controlNetFunction")
  public static let visionEncoderFunction = PipelinePortType(rawValue: "visionEncoderFunction")
  /// Image embedding produced by a vision encoder, such as ComfyUI's
  /// CLIP_VISION_OUTPUT.
  public static let visionEmbedding = PipelinePortType(rawValue: "visionEmbedding")
  public static let styleModelFunction = PipelinePortType(rawValue: "styleModelFunction")
  public static let guider = PipelinePortType(rawValue: "guider")
  public static let generatedImage = PipelinePortType(rawValue: "generatedImage")
  /// A polymorphic port. A descriptor can use `typeVariable` to require a
  /// group of `any` ports on one node to resolve to the same concrete type.
  public static let any = PipelinePortType(rawValue: "any")
  /// Execution control only. Control connections are stored separately from data edges.
  public static let control = PipelinePortType(rawValue: "control")
}

public struct PipelinePortDescriptor: Codable, Equatable, Sendable {
  public var name: String
  public var type: PipelinePortType
  public var isRequired: Bool
  public var allowsMultipleConnections: Bool
  public var typeVariable: String?

  public init(
    name: String,
    type: PipelinePortType,
    isRequired: Bool = true,
    allowsMultipleConnections: Bool = false,
    typeVariable: String? = nil
  ) {
    self.name = name
    self.type = type
    self.isRequired = isRequired
    self.allowsMultipleConnections = allowsMultipleConnections
    self.typeVariable = typeVariable
  }
}

public struct PipelineParameterDescriptor: Codable, Equatable, Sendable {
  public var name: String
  public var valueType: PipelineParameterValueType
  public var isRequired: Bool
  public var defaultValue: PipelineValue?

  public init(
    name: String,
    valueType: PipelineParameterValueType,
    isRequired: Bool = false,
    defaultValue: PipelineValue? = nil
  ) {
    self.name = name
    self.valueType = valueType
    self.isRequired = isRequired
    self.defaultValue = defaultValue
  }
}

public struct PipelineNodeDescriptor: Codable, Equatable, Sendable {
  public var kind: PipelineNodeKind
  public var displayName: String
  public var category: String
  public var inputs: [PipelinePortDescriptor]
  public var outputs: [PipelinePortDescriptor]
  public var parameters: [PipelineParameterDescriptor]
  public var requiredResourceSlots: Set<String>
  public var isTerminal: Bool

  public init(
    kind: PipelineNodeKind,
    displayName: String,
    category: String,
    inputs: [PipelinePortDescriptor] = [],
    outputs: [PipelinePortDescriptor] = [],
    parameters: [PipelineParameterDescriptor] = [],
    requiredResourceSlots: Set<String> = [],
    isTerminal: Bool = false
  ) {
    self.kind = kind
    self.displayName = displayName
    self.category = category
    self.inputs = inputs
    self.outputs = outputs
    self.parameters = parameters
    self.requiredResourceSlots = requiredResourceSlots
    self.isTerminal = isTerminal
  }

  public func input(named name: String) -> PipelinePortDescriptor? {
    inputs.first { $0.name == name }
  }

  public func output(named name: String) -> PipelinePortDescriptor? {
    outputs.first { $0.name == name }
  }

  public func parameter(named name: String) -> PipelineParameterDescriptor? {
    parameters.first { $0.name == name }
  }
}

public struct PipelineNodeRegistry: Sendable {
  private var descriptors: [PipelineNodeKind: PipelineNodeDescriptor]

  public init(_ descriptors: [PipelineNodeDescriptor] = []) {
    self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.kind, $0) })
  }

  public var allDescriptors: [PipelineNodeDescriptor] {
    descriptors.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
  }

  public func descriptor(for kind: PipelineNodeKind) -> PipelineNodeDescriptor? {
    descriptors[kind]
  }

  public mutating func register(_ descriptor: PipelineNodeDescriptor) {
    descriptors[descriptor.kind] = descriptor
  }
}

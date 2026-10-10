import Foundation

public struct PipelineID: Codable, Hashable, RawRepresentable, Sendable {
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
}

public struct PipelineNodeID: Codable, Hashable, RawRepresentable, Sendable {
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
}

/// A namespaced node kind. String-backed kinds let newer engines add nodes
/// without making an older decoder unable to open and inspect the document.
public struct PipelineNodeKind: Codable, Hashable, RawRepresentable, Sendable {
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
}

public enum PipelineMode: String, Codable, CaseIterable, Sendable {
  case textToImage
  case imageToImage
  case inpainting
  case outpainting
  case selection
  /// Imported graphs whose output modality is not implemented by Pixeltje.
  case generic
}

public enum PipelineResourceKind: String, Codable, Sendable {
  case coreAIModel
  case tokenizer
  case adapter
  case data
}

/// Link-only identity for a model, tokenizer, adapter, or immutable data asset.
/// Pipeline files never persist a filesystem path or security-scoped bookmark.
public struct PipelineResourceReference: Codable, Equatable, Sendable {
  public var kind: PipelineResourceKind
  public var packageID: String
  public var packageVersion: String
  public var contentHash: String
  public var componentRole: String
  public var functionName: String?
  public var familyABI: String?

  public init(
    kind: PipelineResourceKind,
    packageID: String,
    packageVersion: String,
    contentHash: String,
    componentRole: String,
    functionName: String? = nil,
    familyABI: String? = nil
  ) {
    self.kind = kind
    self.packageID = packageID
    self.packageVersion = packageVersion
    self.contentHash = contentHash
    self.componentRole = componentRole
    self.functionName = functionName
    self.familyABI = familyABI
  }
}

/// A resource named by an imported workflow but not yet linked to a compatible
/// Pixeltje package. Source filenames and URLs are provenance hints only: they
/// are never treated as runtime paths or downloaded by the converter.
public struct PipelineResourceRequirement: Codable, Equatable, Sendable {
  public var kind: PipelineResourceKind
  public var componentRole: String
  public var sourceName: String
  public var sourceFormat: String?
  public var sourceURL: String?
  public var familyABI: String?

  public init(
    kind: PipelineResourceKind,
    componentRole: String,
    sourceName: String,
    sourceFormat: String? = nil,
    sourceURL: String? = nil,
    familyABI: String? = nil
  ) {
    self.kind = kind
    self.componentRole = componentRole
    self.sourceName = sourceName
    self.sourceFormat = sourceFormat
    self.sourceURL = sourceURL
    self.familyABI = familyABI
  }
}

/// A model or data dependency is either reproducibly linked, or an explicit
/// unresolved requirement. There is no sentinel package ID or invented hash.
public enum PipelineResourceBinding: Codable, Equatable, Sendable {
  case linked(PipelineResourceReference)
  case unresolved(PipelineResourceRequirement)

  private enum CodingKeys: String, CodingKey {
    case state
    case reference
    case requirement
  }

  private enum State: String, Codable {
    case linked
    case unresolved
  }

  public init(from decoder: any Decoder) throws {
    if let container = try? decoder.container(keyedBy: CodingKeys.self),
      let state = try? container.decode(State.self, forKey: .state)
    {
      switch state {
      case .linked:
        self = .linked(try container.decode(PipelineResourceReference.self, forKey: .reference))
      case .unresolved:
        self = .unresolved(
          try container.decode(PipelineResourceRequirement.self, forKey: .requirement))
      }
      return
    }
    // Schema 1 encoded a linked reference directly in the resource slot.
    self = .linked(try PipelineResourceReference(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .linked(let reference):
      try container.encode(State.linked, forKey: .state)
      try container.encode(reference, forKey: .reference)
    case .unresolved(let requirement):
      try container.encode(State.unresolved, forKey: .state)
      try container.encode(requirement, forKey: .requirement)
    }
  }

  public var linkedReference: PipelineResourceReference? {
    guard case .linked(let reference) = self else { return nil }
    return reference
  }

  public var unresolvedRequirement: PipelineResourceRequirement? {
    guard case .unresolved(let requirement) = self else { return nil }
    return requirement
  }
}

/// JSON-compatible parameter data. Executable code and native objects are not
/// representable, which keeps a pipeline document safe to inspect before use.
public indirect enum PipelineValue: Codable, Equatable, Sendable {
  case null
  case boolean(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([PipelineValue])
  case object([String: PipelineValue])

  private enum NumericCodingKeys: String, CodingKey {
    case type = "$type"
    case value
  }

  public init(from decoder: any Decoder) throws {
    if let keyed = try? decoder.container(keyedBy: NumericCodingKeys.self),
      let type = try? keyed.decode(String.self, forKey: .type)
    {
      switch type {
      case "integer":
        self = .integer(try keyed.decode(Int64.self, forKey: .value))
        return
      case "number":
        self = .number(try keyed.decode(Double.self, forKey: .value))
        return
      default:
        break
      }
    }
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([PipelineValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: PipelineValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Pipeline parameters must contain JSON-compatible values.")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .integer(let value):
      var container = encoder.container(keyedBy: NumericCodingKeys.self)
      try container.encode("integer", forKey: .type)
      try container.encode(value, forKey: .value)
      return
    case .number(let value):
      var container = encoder.container(keyedBy: NumericCodingKeys.self)
      try container.encode("number", forKey: .type)
      try container.encode(value, forKey: .value)
      return
    default:
      break
    }
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .boolean(let value):
      try container.encode(value)
    case .integer, .number:
      preconditionFailure("Numeric pipeline values use keyed encoding.")
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

public enum PipelineNodeExecutionState: String, Codable, Sendable {
  case enabled
  case disabled
  case bypassed
}

public struct PipelineNodeOrigin: Codable, Equatable, Sendable {
  public var system: String
  public var sourceNodeID: String
  public var sourceType: String
  public var metadata: [String: PipelineValue]

  public init(
    system: String,
    sourceNodeID: String,
    sourceType: String,
    metadata: [String: PipelineValue] = [:]
  ) {
    self.system = system
    self.sourceNodeID = sourceNodeID
    self.sourceType = sourceType
    self.metadata = metadata
  }
}

public struct PipelineNode: Codable, Equatable, Identifiable, Sendable {
  public var id: PipelineNodeID
  public var kind: PipelineNodeKind
  public var title: String?
  public var parameters: [String: PipelineValue]
  public var resources: [String: PipelineResourceBinding]
  /// A data-only interface for imported nodes. It enables inspection and
  /// structural validation but never supplies executable implementation code.
  public var importedDescriptor: PipelineNodeDescriptor?
  public var executionState: PipelineNodeExecutionState
  public var origin: PipelineNodeOrigin?

  public init(
    id: PipelineNodeID,
    kind: PipelineNodeKind,
    title: String? = nil,
    parameters: [String: PipelineValue] = [:],
    resources: [String: PipelineResourceBinding] = [:],
    importedDescriptor: PipelineNodeDescriptor? = nil,
    executionState: PipelineNodeExecutionState = .enabled,
    origin: PipelineNodeOrigin? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.parameters = parameters
    self.resources = resources
    self.importedDescriptor = importedDescriptor
    self.executionState = executionState
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case title
    case parameters
    case resources
    case importedDescriptor
    case executionState
    case origin
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(PipelineNodeID.self, forKey: .id)
    kind = try container.decode(PipelineNodeKind.self, forKey: .kind)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    parameters = try container.decodeIfPresent([String: PipelineValue].self, forKey: .parameters) ?? [:]
    resources = try container.decodeIfPresent([String: PipelineResourceBinding].self, forKey: .resources) ?? [:]
    importedDescriptor = try container.decodeIfPresent(
      PipelineNodeDescriptor.self, forKey: .importedDescriptor)
    executionState = try container.decodeIfPresent(
      PipelineNodeExecutionState.self, forKey: .executionState) ?? .enabled
    origin = try container.decodeIfPresent(PipelineNodeOrigin.self, forKey: .origin)
  }
}

public struct PipelineConnectionID: Codable, Hashable, RawRepresentable, Sendable {
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
}

public struct PipelinePortReference: Codable, Equatable, Hashable, Sendable {
  public var nodeID: PipelineNodeID
  public var port: String

  public init(nodeID: PipelineNodeID, port: String) {
    self.nodeID = nodeID
    self.port = port
  }
}

public struct PipelineConnection: Codable, Equatable, Identifiable, Sendable {
  public var id: PipelineConnectionID
  public var output: PipelinePortReference
  public var input: PipelinePortReference

  public init(
    id: PipelineConnectionID? = nil,
    output: PipelinePortReference,
    input: PipelinePortReference
  ) {
    self.id = id ?? Self.deterministicID(output: output, input: input)
    self.output = output
    self.input = input
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case output
    case input
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    output = try container.decode(PipelinePortReference.self, forKey: .output)
    input = try container.decode(PipelinePortReference.self, forKey: .input)
    id = try container.decodeIfPresent(PipelineConnectionID.self, forKey: .id)
      ?? Self.deterministicID(output: output, input: input)
  }

  private static func deterministicID(
    output: PipelinePortReference,
    input: PipelinePortReference
  ) -> PipelineConnectionID {
    PipelineConnectionID(
      rawValue: "\(output.nodeID.rawValue).\(output.port)->\(input.nodeID.rawValue).\(input.port)")
  }
}

public enum PipelineParameterValueType: String, Codable, Sendable {
  case boolean
  case integer
  case number
  case string
  case array
  case object
  case any
}

public struct PipelineParameterReference: Codable, Equatable, Hashable, Sendable {
  public var nodeID: PipelineNodeID
  public var parameter: String

  public init(nodeID: PipelineNodeID, parameter: String) {
    self.nodeID = nodeID
    self.parameter = parameter
  }
}

/// A node parameter intentionally promoted into Pixeltje's generation controls
/// or a script API. Internal node settings stay private to the graph.
public struct PipelineExposedParameter: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public var valueType: PipelineParameterValueType
  public var target: PipelineParameterReference
  public var defaultValue: PipelineValue?
  public var minimum: Double?
  public var maximum: Double?

  public init(
    id: String,
    label: String,
    valueType: PipelineParameterValueType,
    target: PipelineParameterReference,
    defaultValue: PipelineValue? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil
  ) {
    self.id = id
    self.label = label
    self.valueType = valueType
    self.target = target
    self.defaultValue = defaultValue
    self.minimum = minimum
    self.maximum = maximum
  }
}

public struct PipelineRequirements: Codable, Equatable, Sendable {
  public var minimumEngineVersion: Int
  public var familyABIs: [String]

  public init(minimumEngineVersion: Int = 1, familyABIs: [String] = []) {
    self.minimumEngineVersion = minimumEngineVersion
    self.familyABIs = familyABIs
  }
}

public struct PipelinePoint: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct PipelineSize: Codable, Equatable, Sendable {
  public var width: Double
  public var height: Double

  public init(width: Double, height: Double) {
    self.width = width
    self.height = height
  }
}

public struct PipelinePresentationGroup: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var origin: PipelinePoint
  public var size: PipelineSize
  public var color: String?
  public var metadata: [String: PipelineValue]

  public init(
    id: String,
    title: String,
    origin: PipelinePoint,
    size: PipelineSize,
    color: String? = nil,
    metadata: [String: PipelineValue] = [:]
  ) {
    self.id = id
    self.title = title
    self.origin = origin
    self.size = size
    self.color = color
    self.metadata = metadata
  }
}

/// Editor-only state. The executor ignores this entire value and semantic
/// hashing omits it, so rearranging nodes never changes a pipeline recipe.
public struct PipelinePresentation: Codable, Equatable, Sendable {
  public var nodePositions: [String: PipelinePoint]
  public var nodeSizes: [String: PipelineSize]
  public var groups: [PipelinePresentationGroup]
  public var viewportOrigin: PipelinePoint?
  public var viewportScale: Double?

  public init(
    nodePositions: [String: PipelinePoint] = [:],
    nodeSizes: [String: PipelineSize] = [:],
    groups: [PipelinePresentationGroup] = [],
    viewportOrigin: PipelinePoint? = nil,
    viewportScale: Double? = nil
  ) {
    self.nodePositions = nodePositions
    self.nodeSizes = nodeSizes
    self.groups = groups
    self.viewportOrigin = viewportOrigin
    self.viewportScale = viewportScale
  }

  private enum CodingKeys: String, CodingKey {
    case nodePositions
    case nodeSizes
    case groups
    case viewportOrigin
    case viewportScale
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    nodePositions = try container.decodeIfPresent(
      [String: PipelinePoint].self, forKey: .nodePositions) ?? [:]
    nodeSizes = try container.decodeIfPresent(
      [String: PipelineSize].self, forKey: .nodeSizes) ?? [:]
    groups = try container.decodeIfPresent(
      [PipelinePresentationGroup].self, forKey: .groups) ?? []
    viewportOrigin = try container.decodeIfPresent(PipelinePoint.self, forKey: .viewportOrigin)
    viewportScale = try container.decodeIfPresent(Double.self, forKey: .viewportScale)
  }
}

/// Settings authored on a control.loop node. Max calls includes the first pass.
public struct PipelineLoopSettings: Equatable, Sendable {
  public enum SeedStrategy: String, Codable, Sendable {
    case fixed
    case increment
  }

  public enum Feedback: String, Codable, Sendable {
    case textToPrompt
    case imageToSourceImage
    /// Carries the image output's prompt-derived scene plan to the next call.
    case scenePlanToNextView
    /// Carries both the scene plan and pixels for image-conditioned navigation.
    case scenePlanAndImageToNextView
    /// Carries an image and arbitrary text attached to its output.
    case imageAndTextToNextView
    /// Carries committed JSON state, image and interaction masks between turns.
    case stateAndImage
  }

  /// Includes the initial execution. Nil means unlimited calls.
  public var maxCalls: Int?
  public var delayMilliseconds: Int
  /// Maximum whole-graph call starts per second. Nil leaves the rate uncapped.
  public var limitHz: Int?
  /// Restarts a finite sequence at call index zero after its last call.
  public var autoRepeat: Bool
  /// Waits for the editor to proceed before starting each later call.
  public var autoPause: Bool
  public var seedStrategy: SeedStrategy
  public var feedback: Feedback?

  public init(
    maxCalls: Int? = 3, delayMilliseconds: Int = 1_000, limitHz: Int? = nil,
    autoRepeat: Bool = false, autoPause: Bool = false,
    seedStrategy: SeedStrategy = .fixed, feedback: Feedback? = nil
  ) {
    self.maxCalls = maxCalls
    self.delayMilliseconds = delayMilliseconds
    self.limitHz = limitHz
    self.autoRepeat = autoRepeat && maxCalls != nil
    self.autoPause = autoPause
    self.seedStrategy = seedStrategy
    self.feedback = feedback
  }

  public init?(node: PipelineNode) {
    guard node.kind.rawValue == "control.loop" else { return nil }
    let storedMax: Int64 = if case .integer(let value)? = node.parameters["maxCalls"] {
      value
    } else { 3 }
    guard storedMax == -1 || (1...10_000).contains(storedMax) else { return nil }
    let storedDelay: Int64 = if case .integer(let value)? = node.parameters["delayMilliseconds"] {
      value
    } else { 1_000 }
    guard (0...60_000).contains(storedDelay) else { return nil }
    let storedLimit: Int64
    switch node.parameters["limitHz"] {
    case .integer(let value)?: storedLimit = value
    case nil: storedLimit = 0
    default: return nil
    }
    guard (0...240).contains(storedLimit) else { return nil }
    let autoRepeat: Bool
    switch node.parameters["autoRepeat"] {
    case .boolean(let value): autoRepeat = value
    case nil: autoRepeat = false
    default: return nil
    }
    guard storedMax != -1 || !autoRepeat else { return nil }
    let autoPause: Bool
    switch node.parameters["autoPause"] {
    case .boolean(let value): autoPause = value
    case nil: autoPause = false
    default: return nil
    }
    let seedName: String = if case .string(let value)? = node.parameters["seedStrategy"] {
      value
    } else { "fixed" }
    guard let seed = SeedStrategy(rawValue: seedName) else { return nil }
    let feedbackName: String = if case .string(let value)? = node.parameters["feedback"] {
      value
    } else { "none" }
    guard feedbackName == "none" || Feedback(rawValue: feedbackName) != nil else { return nil }
    self.init(
      maxCalls: storedMax == -1 ? nil : Int(storedMax),
      delayMilliseconds: Int(storedDelay),
      limitHz: storedLimit == 0 ? nil : Int(storedLimit),
      autoRepeat: autoRepeat,
      autoPause: autoPause, seedStrategy: seed,
      feedback: Feedback(rawValue: feedbackName))
  }

  /// The zero-based graph call index for a one-based call within the run.
  public func callIndex(forRunCall runCall: Int) -> Int {
    let index = max(runCall - 1, 0)
    if autoRepeat, let maxCalls, maxCalls > 0 { return index % maxCalls }
    return index
  }

  public func continues(afterRunCall runCall: Int) -> Bool {
    if autoRepeat, maxCalls != nil { return true }
    return maxCalls.map { runCall < $0 } ?? true
  }
}

/// The portable product of Pixeltje Pipeline Editor.
public struct PipelineDocument: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var id: PipelineID
  public var name: String
  public var mode: PipelineMode
  public var requirements: PipelineRequirements
  public var nodes: [PipelineNode]
  public var connections: [PipelineConnection]
  /// Control edges may return to Start; they are never data dependencies.
  public var controlConnections: [PipelineConnection]
  public var exposedParameters: [PipelineExposedParameter]
  public var primaryOutputNodeIDs: [PipelineNodeID]?
  public var presentation: PipelinePresentation?

  public init(
    schemaVersion: Int = currentSchemaVersion,
    id: PipelineID,
    name: String,
    mode: PipelineMode,
    requirements: PipelineRequirements = PipelineRequirements(),
    nodes: [PipelineNode],
    connections: [PipelineConnection],
    controlConnections: [PipelineConnection] = [],
    exposedParameters: [PipelineExposedParameter] = [],
    primaryOutputNodeIDs: [PipelineNodeID]? = nil,
    presentation: PipelinePresentation? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.name = name
    self.mode = mode
    self.requirements = requirements
    self.nodes = nodes
    self.connections = connections
    self.controlConnections = controlConnections
    self.exposedParameters = exposedParameters
    self.primaryOutputNodeIDs = primaryOutputNodeIDs
    self.presentation = presentation
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, id, name, mode, requirements, nodes, connections
    case controlConnections, exposedParameters, primaryOutputNodeIDs, presentation
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    id = try values.decode(PipelineID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    mode = try values.decode(PipelineMode.self, forKey: .mode)
    requirements = try values.decode(PipelineRequirements.self, forKey: .requirements)
    nodes = try values.decode([PipelineNode].self, forKey: .nodes)
    connections = try values.decode([PipelineConnection].self, forKey: .connections)
    controlConnections = try values.decodeIfPresent(
      [PipelineConnection].self, forKey: .controlConnections) ?? []
    exposedParameters = try values.decodeIfPresent(
      [PipelineExposedParameter].self, forKey: .exposedParameters) ?? []
    primaryOutputNodeIDs = try values.decodeIfPresent(
      [PipelineNodeID].self, forKey: .primaryOutputNodeIDs)
    presentation = try values.decodeIfPresent(
      PipelinePresentation.self, forKey: .presentation)
  }
}

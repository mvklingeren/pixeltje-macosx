import Foundation
import PixeltjePipelineDomain

/// Top-down, premultiplied display-referred sRGB RGBA with normalized float
/// components. This is transient host input, never a linked or serialized
/// pipeline resource. Hosts convert from their own working space at capture.
public struct PipelineImageInput: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let rgba: [Float]

  public init(width: Int, height: Int, rgba: [Float]) throws {
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    let (components, componentOverflow) = pixels.multipliedReportingOverflow(by: 4)
    guard width > 0, height > 0, !overflow, !componentOverflow,
      rgba.count == components, rgba.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.invalidInvocation("Invalid host image raster.")
    }
    self.width = width
    self.height = height
    self.rgba = rgba
  }

  /// Converts a generated image to the image-input contract without flipping
  /// rows or quantizing pixels. Generated RGB is unpremultiplied and planar.
  public init(generatedImage image: PipelineGeneratedImage) throws {
    let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
    let (rgbCount, rgbOverflow) = pixels.multipliedReportingOverflow(by: 3)
    let (rgbaCount, rgbaOverflow) = pixels.multipliedReportingOverflow(by: 4)
    guard image.width > 0, image.height > 0, !overflow, !rgbOverflow, !rgbaOverflow,
      image.planarRGB.count == rgbCount,
      image.planarRGB.allSatisfy(\.isFinite),
      image.alpha.map({ $0.count == pixels && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) ?? true
    else { throw PipelineEngineError.invalidInvocation("Invalid generated image raster.") }
    var rgba = [Float](repeating: 1, count: rgbaCount)
    for pixel in 0..<pixels {
      if pixel.isMultiple(of: 16_384) { try Task.checkCancellation() }
      let alpha = image.alpha?[pixel] ?? 1
      rgba[pixel * 4 + 3] = alpha
      for channel in 0..<3 {
        let component = image.encoding.normalizedSRGBComponent(
          from: image.planarRGB[channel * pixels + pixel])
        rgba[pixel * 4 + channel] = min(max(component, 0), 1) * alpha
      }
    }
    self.width = image.width
    self.height = image.height
    self.rgba = rgba
  }
}

/// Top-down, linear selection coverage in the same canvas space as the host
/// image. Zero protects a pixel; one permits a full edit.
public struct PipelineMaskInput: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let coverage: [Float]

  public init(width: Int, height: Int, coverage: [Float]) throws {
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow, coverage.count == pixels,
      coverage.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
      throw PipelineEngineError.invalidInvocation("Invalid host selection mask.")
    }
    self.width = width
    self.height = height
    self.coverage = coverage
  }
}

/// One instance mask associated with the text that requested its segmentation.
public struct PipelineLabeledMask: Equatable, Sendable {
  public let label: String
  public let mask: PipelineMaskInput
  public let score: Float

  public init(label: String, mask: PipelineMaskInput, score: Float) throws {
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      score.isFinite, (0...1).contains(score) else {
      throw PipelineEngineError.invalidInvocation("Invalid labeled mask.")
    }
    self.label = label
    self.mask = mask
    self.score = score
  }
}

/// A host-supplied value for one execution input. Invocation values are
/// transient and are never serialized into a pipeline document.
public enum PipelineInvocationValue: Equatable, Sendable {
  case boolean(Bool)
  case integer(Int64)
  case unsignedInteger(UInt64)
  case number(Double)
  case string(String)
  case image(PipelineImageInput)
  case mask(PipelineMaskInput)
  case labeledMasks([PipelineLabeledMask])
}

/// Generic host input for an executable pipeline. Adapters interpret only the
/// keys they declare in their execution profile.
public struct PipelineInvocation: Equatable, Sendable {
  public static let promptKey = "prompt"
  public static let negativePromptKey = "negativePrompt"
  public static let seedKey = "seed"
  public static let widthKey = "width"
  public static let heightKey = "height"
  public static let stepsKey = "steps"
  public static let guidanceKey = "guidance"
  public static let systemPromptKey = "systemPrompt"
  public static let maximumResponseTokensKey = "maximumResponseTokens"
  public static let temperatureKey = "temperature"
  public static let topKKey = "topK"
  public static let sourceImageKey = "sourceImage"
  public static let selectionMaskKey = "selectionMask"
  public static let previousScenePlanKey = "previousScenePlan"
  public static let trackpadXKey = "trackpadX"
  public static let trackpadYKey = "trackpadY"
  public static let trackpadEngagedKey = "trackpadEngaged"
  public static let trackpadEngagedAtCallKey = "trackpadEngagedAtCall"
  public static let trackpadActionCountKey = "trackpadActionCount"
  public static let stateKey = "state"
  public static let interactionMasksKey = "interactionMasks"
  public static let loopCallIndexKey = "loopCallIndex"
  /// Defer GPU program state advancement until the host has published the output.
  public static let gpuProgramDeferredCommitKey = "gpuProgramDeferredCommit"
  /// Editor-only rendering hints for a Metal Render card. These never enter a saved graph.
  public static let metalPreviewWidthKey = "metalPreviewWidth"
  public static let metalPreviewHeightKey = "metalPreviewHeight"
  public static let metalPreviewOnlyKey = "metalPreviewOnly"
  /// Seconds to interpolate toward the next workflow sample in a live shader preview.
  public static let metalPreviewTimeStepKey = "metalPreviewTimeStep"
  /// Expected seconds between whole-graph calls; live preview drawing is independent.
  public static let metalPreviewCallIntervalKey = "metalPreviewCallInterval"

  public var values: [String: PipelineInvocationValue]

  public init(values: [String: PipelineInvocationValue] = [:]) {
    self.values = values
  }

  public subscript(key: String) -> PipelineInvocationValue? {
    get { values[key] }
    set { values[key] = newValue }
  }

  public func mergingDefaults(_ defaults: [String: PipelineInvocationValue]) -> Self {
    var merged = defaults
    merged.merge(values) { _, supplied in supplied }
    return Self(values: merged)
  }

  public func string(for key: String, default defaultValue: String? = nil) throws -> String {
    guard let value = values[key] else {
      if let defaultValue { return defaultValue }
      throw PipelineEngineError.invalidInvocation("Missing \(key) execution value.")
    }
    guard case .string(let result) = value else {
      throw PipelineEngineError.invalidInvocation("Execution value \(key) must be a string.")
    }
    return result
  }

  public func unsignedInteger(for key: String, default defaultValue: UInt64? = nil) throws -> UInt64 {
    guard let value = values[key] else {
      if let defaultValue { return defaultValue }
      throw PipelineEngineError.invalidInvocation("Missing \(key) execution value.")
    }
    switch value {
    case .unsignedInteger(let result): return result
    case .integer(let result) where result >= 0: return UInt64(result)
    default:
      throw PipelineEngineError.invalidInvocation(
        "Execution value \(key) must be a non-negative integer.")
    }
  }

  public func integer(for key: String, default defaultValue: Int? = nil) throws -> Int {
    guard let value = values[key] else {
      if let defaultValue { return defaultValue }
      throw PipelineEngineError.invalidInvocation("Missing \(key) execution value.")
    }
    let result: Int?
    switch value {
    case .integer(let value): result = Int(exactly: value)
    case .unsignedInteger(let value): result = Int(exactly: value)
    default: result = nil
    }
    guard let result else {
      throw PipelineEngineError.invalidInvocation("Execution value \(key) must be an integer.")
    }
    return result
  }

  public func number(for key: String, default defaultValue: Double? = nil) throws -> Double {
    guard let value = values[key] else {
      if let defaultValue { return defaultValue }
      throw PipelineEngineError.invalidInvocation("Missing \(key) execution value.")
    }
    switch value {
    case .number(let result): return result
    case .integer(let result): return Double(result)
    case .unsignedInteger(let result): return Double(result)
    default:
      throw PipelineEngineError.invalidInvocation("Execution value \(key) must be numeric.")
    }
  }
}

/// How a generated image's planar RGB values map to display-referred sRGB.
/// This describes an adapter's output, independently of any host's working space.
public enum PipelineGeneratedRGBEncoding: Equatable, Sendable {
  /// Encoded sRGB components in the range 0...1.
  case sRGBZeroToOne
  /// Encoded sRGB components mapped to the range -1...1.
  case sRGBMinusOneToOne

  public func normalizedSRGBComponent(from value: Float) -> Float {
    switch self {
    case .sRGBZeroToOne: value
    case .sRGBMinusOneToOne: (value + 1) * 0.5
    }
  }
}

/// Generated output in top-down, unpremultiplied planar RGB. Its encoding identifies both the
/// numeric range and color interpretation; hosts convert it at their boundary.
public struct PipelineGeneratedImage: Equatable, Sendable {
  public var width: Int
  public var height: Int
  public var planarRGB: [Float]
  public var encoding: PipelineGeneratedRGBEncoding
  public var semanticPipelineSHA256: String
  /// Optional normalized alpha in top-down pixel order. Nil means opaque.
  public var alpha: [Float]?
  /// Prompt-derived placement metadata carried beside an image for loop feedback.
  public var scenePlanJSON: String?
  /// Arbitrary text attached to the image for a later loop call.
  public var feedbackText: String?
  public var nextStateJSON: String?
  public private(set) var interactionMasks: [PipelineLabeledMask] = []

  public mutating func setInteractionMasks(_ masks: [PipelineLabeledMask]) throws {
    guard masks.count <= 200, masks.allSatisfy({
      $0.mask.width == width && $0.mask.height == height
    }) else {
      throw PipelineEngineError.invalidInvocation("Interaction masks must match the rendered frame and contain at most 200 instances.")
    }
    interactionMasks = masks
  }

  public init(
    width: Int,
    height: Int,
    planarRGB: [Float],
    encoding: PipelineGeneratedRGBEncoding,
    semanticPipelineSHA256: String,
    alpha: [Float]? = nil,
    scenePlanJSON: String? = nil,
    feedbackText: String? = nil,
    nextStateJSON: String? = nil
  ) {
    self.width = width
    self.height = height
    self.planarRGB = planarRGB
    self.encoding = encoding
    self.semanticPipelineSHA256 = semanticPipelineSHA256
    self.alpha = alpha
    self.scenePlanJSON = scenePlanJSON
    self.feedbackText = feedbackText
    self.nextStateJSON = nextStateJSON
  }
}

public enum PipelineTextFinishReason: String, Equatable, Sendable {
  case completed
  case maximumResponseTokens
}

/// Final text produced by a language-model pipeline. Model identity is retained
/// beside the semantic graph hash so a host can persist reproducible provenance.
public struct PipelineGeneratedText: Equatable, Sendable {
  public var text: String
  public var seed: UInt64?
  public var semanticPipelineSHA256: String
  public var modelPackageID: String
  public var modelPackageVersion: String
  public var finishReason: PipelineTextFinishReason
  public var inputTokenCount: Int?
  public var outputTokenCount: Int?

  public init(
    text: String,
    seed: UInt64? = nil,
    semanticPipelineSHA256: String,
    modelPackageID: String,
    modelPackageVersion: String,
    finishReason: PipelineTextFinishReason,
    inputTokenCount: Int? = nil,
    outputTokenCount: Int? = nil
  ) {
    self.text = text
    self.seed = seed
    self.semanticPipelineSHA256 = semanticPipelineSHA256
    self.modelPackageID = modelPackageID
    self.modelPackageVersion = modelPackageVersion
    self.finishReason = finishReason
    self.inputTokenCount = inputTokenCount
    self.outputTokenCount = outputTokenCount
  }
}

/// An encoded video produced by an execution adapter. The temporary file is
/// owned by the caller after execution and can be moved to its final location.
public struct PipelineGeneratedVideo: Equatable, Sendable {
  public var fileURL: URL
  public var width: Int
  public var height: Int
  public var frameCount: Int
  public var framesPerSecond: Double
  public var semanticPipelineSHA256: String

  public init(
    fileURL: URL,
    width: Int,
    height: Int,
    frameCount: Int,
    framesPerSecond: Double,
    semanticPipelineSHA256: String
  ) {
    self.fileURL = fileURL
    self.width = width
    self.height = height
    self.frameCount = frameCount
    self.framesPerSecond = framesPerSecond
    self.semanticPipelineSHA256 = semanticPipelineSHA256
  }
}

/// One frame from a video output driven by successive pipeline calls. The host
/// writes it before requesting the next call, so a recording need not retain
/// the preceding frames in memory.
public struct PipelineVideoFrame: Equatable, Sendable {
  public var image: PipelineGeneratedImage
  public var framesPerSecond: Double

  public init(image: PipelineGeneratedImage, framesPerSecond: Double) {
    self.image = image
    self.framesPerSecond = framesPerSecond
  }
}

/// An audio file returned by an execution adapter. The caller may copy it to
/// a persistent destination; the source can also be a linked input file.
public struct PipelineGeneratedAudio: Equatable, Sendable {
  public var fileURL: URL
  public var semanticPipelineSHA256: String

  public init(fileURL: URL, semanticPipelineSHA256: String) {
    self.fileURL = fileURL
    self.semanticPipelineSHA256 = semanticPipelineSHA256
  }
}

/// Deterministic text from a graph that has no language-model package.
public struct PipelinePlainText: Equatable, Sendable {
  public var text: String
  public var semanticPipelineSHA256: String

  public init(text: String, semanticPipelineSHA256: String) {
    self.text = text
    self.semanticPipelineSHA256 = semanticPipelineSHA256
  }
}

public struct PipelineTrainedModel: Equatable, Sendable {
  public let assetURL: URL
  public let checkpointURL: URL
  public let validationLoss: Double?
  public let validationAccuracy: Double?
  public let testAccuracy: Double?
  public let semanticPipelineSHA256: String

  public init(assetURL: URL, checkpointURL: URL, validationLoss: Double?,
    validationAccuracy: Double? = nil, testAccuracy: Double? = nil,
    semanticPipelineSHA256: String) {
    self.assetURL = assetURL
    self.checkpointURL = checkpointURL
    self.validationLoss = validationLoss
    self.validationAccuracy = validationAccuracy
    self.testAccuracy = testAccuracy
    self.semanticPipelineSHA256 = semanticPipelineSHA256
  }
}

public enum PipelineExecutionOutput: Equatable, Sendable {
  case none
  case image(PipelineGeneratedImage)
  case text(PipelineGeneratedText)
  case plainText(PipelinePlainText)
  case video(PipelineGeneratedVideo)
  case videoFrame(PipelineVideoFrame)
  case audio(PipelineGeneratedAudio)
  case model(PipelineTrainedModel)

  public var image: PipelineGeneratedImage? {
    guard case .image(let image) = self else { return nil }
    return image
  }

  public var text: PipelineGeneratedText? {
    guard case .text(let text) = self else { return nil }
    return text
  }

  public var video: PipelineGeneratedVideo? {
    guard case .video(let video) = self else { return nil }
    return video
  }

  public var audio: PipelineGeneratedAudio? {
    guard case .audio(let audio) = self else { return nil }
    return audio
  }
}

public enum PipelineExecutionStage: String, Equatable, Sendable {
  case validating
  case loadingModels
  case preparing
  case denoising
  case generating
  case decoding
  case completed
}

/// A transient preview for one input of an Asset Cache node.
public struct PipelineAssetPreview: Equatable, Sendable {
  public let nodeID: PipelineNodeID
  public let slot: String
  public let image: PipelineGeneratedImage?
  public let audioURL: URL?

  public init(nodeID: PipelineNodeID, slot: String,
    image: PipelineGeneratedImage? = nil, audioURL: URL? = nil) {
    self.nodeID = nodeID
    self.slot = slot
    self.image = image
    self.audioURL = audioURL
  }
}

public struct PipelineExecutionProgress: Equatable, Sendable {
  public var stage: PipelineExecutionStage
  public var message: String
  public var completedUnitCount: Int
  public var totalUnitCount: Int
  public var preview: PipelineGeneratedImage?
  public var assetPreview: PipelineAssetPreview?
  /// Identifies an Image Preview node whose current image should appear in its card.
  public var previewNodeID: PipelineNodeID?
  /// A playable video for a Video Preview node. The URL is transient host state.
  public var previewVideoURL: URL?
  public var previewVideoNodeID: PipelineNodeID?
  public var previewVideoIsTemporary: Bool
  public var previewFramesPerSecond: Double?
  /// Resolved text from a Text node, for its transient on-node preview.
  public var textValueNodeID: PipelineNodeID?
  public var textValue: String?
  /// Accumulated generated text. Streaming adapters update this as snapshots arrive.
  public var generatedText: String?
  /// The text appended since the preceding progress update.
  public var textDelta: String?
  public var inputTokenCount: Int?
  public var outputTokenCount: Int?
  /// Nodes participating in the work represented by this progress snapshot.
  /// This is transient execution telemetry and is never persisted in a pipeline.
  public var activeNodeIDs: Set<PipelineNodeID>

  public init(
    stage: PipelineExecutionStage,
    message: String,
    completedUnitCount: Int = 0,
    totalUnitCount: Int = 0,
    preview: PipelineGeneratedImage? = nil,
    assetPreview: PipelineAssetPreview? = nil,
    previewNodeID: PipelineNodeID? = nil,
    previewVideoURL: URL? = nil,
    previewVideoNodeID: PipelineNodeID? = nil,
    previewVideoIsTemporary: Bool = false,
    previewFramesPerSecond: Double? = nil,
    textValueNodeID: PipelineNodeID? = nil,
    textValue: String? = nil,
    generatedText: String? = nil,
    textDelta: String? = nil,
    inputTokenCount: Int? = nil,
    outputTokenCount: Int? = nil,
    activeNodeIDs: Set<PipelineNodeID> = []
  ) {
    self.stage = stage
    self.message = message
    self.completedUnitCount = completedUnitCount
    self.totalUnitCount = totalUnitCount
    self.preview = preview
    self.assetPreview = assetPreview
    self.previewNodeID = previewNodeID
    self.previewVideoURL = previewVideoURL
    self.previewVideoNodeID = previewVideoNodeID
    self.previewVideoIsTemporary = previewVideoIsTemporary
    self.previewFramesPerSecond = previewFramesPerSecond
    self.textValueNodeID = textValueNodeID
    self.textValue = textValue
    self.generatedText = generatedText
    self.textDelta = textDelta
    self.inputTokenCount = inputTokenCount
    self.outputTokenCount = outputTokenCount
    self.activeNodeIDs = activeNodeIDs
  }
}

public typealias PipelineExecutionProgressHandler =
  @Sendable (PipelineExecutionProgress) async -> Void

public struct PipelinePixelSize: Equatable, Sendable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

public enum PipelineExecutionOutputKind: String, Hashable, Sendable {
  case none
  case image
  case text
  case video
  case audio
  case model
}

/// Declarative host metadata for a native node graph.
public struct PipelineExecutionProfile: Equatable, Sendable {
  public var identifier: String
  public var displayName: String
  public var supportedModes: [PipelineMode]
  public var defaultPackageURL: URL
  public var outputKind: PipelineExecutionOutputKind
  public var outputSize: PipelinePixelSize?
  public var defaultInvocation: [String: PipelineInvocationValue]
  public var editableInvocationKeys: Set<String>
  public var maximumSeed: UInt64?

  public init(
    identifier: String,
    displayName: String,
    supportedModes: [PipelineMode],
    defaultPackageURL: URL,
    outputKind: PipelineExecutionOutputKind = .image,
    outputSize: PipelinePixelSize? = nil,
    defaultInvocation: [String: PipelineInvocationValue] = [:],
    editableInvocationKeys: Set<String> = [],
    maximumSeed: UInt64? = nil
  ) {
    self.identifier = identifier
    self.displayName = displayName
    self.supportedModes = supportedModes
    self.defaultPackageURL = defaultPackageURL
    self.outputKind = outputKind
    self.outputSize = outputSize
    self.defaultInvocation = defaultInvocation
    self.editableInvocationKeys = editableInvocationKeys
    self.maximumSeed = maximumSeed
  }

}

public struct PipelinePackageInspectionReport: Equatable, Sendable {
  public var adapterIdentifier: String
  public var packageRoot: URL
  public var isUsable: Bool
  public var summary: String
  public var missingComponents: [String]
  public var mismatchedComponents: [String]
  public var incompatibleComponents: [String]

  public init(
    adapterIdentifier: String,
    packageRoot: URL,
    isUsable: Bool,
    summary: String,
    missingComponents: [String] = [],
    mismatchedComponents: [String] = [],
    incompatibleComponents: [String] = []
  ) {
    self.adapterIdentifier = adapterIdentifier
    self.packageRoot = packageRoot
    self.isUsable = isUsable
    self.summary = summary
    self.missingComponents = missingComponents
    self.mismatchedComponents = mismatchedComponents
    self.incompatibleComponents = incompatibleComponents
  }
}

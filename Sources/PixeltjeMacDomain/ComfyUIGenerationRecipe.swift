import Foundation

public enum ComfyUIExecutionTarget: String, Codable, Equatable, Sendable, CaseIterable {
  case local
  case cloud
}

/// A stable address for one value-bearing input in a ComfyUI API workflow.
///
/// Labels and node titles are presentation metadata and may change. The node
/// identifier plus input name is the execution contract used when applying a
/// draft to the immutable workflow template.
public struct ComfyUIParameterAddress: Codable, Equatable, Hashable, Sendable {
  public var nodeID: String
  public var inputName: String

  public init(nodeID: String, inputName: String) {
    self.nodeID = nodeID
    self.inputName = inputName
  }

  public var displayValue: String { "\(nodeID).\(inputName)" }
}

/// The lossless scalar values Pixeltje can edit in a ComfyUI workflow.
///
/// Signed and unsigned integers remain distinct so a 64-bit noise seed is not
/// rounded through `Double` or rejected merely because it exceeds `Int64.max`.
public enum ComfyUIParameterValue: Codable, Equatable, Hashable, Sendable {
  case string(String)
  case signedInteger(Int64)
  case unsignedInteger(UInt64)
  case decimal(Double)
  case boolean(Bool)

  private enum CodingKeys: String, CodingKey {
    case kind, string, signedInteger, unsignedInteger, decimal, boolean
  }

  private enum Kind: String, Codable {
    case string, signedInteger, unsignedInteger, decimal, boolean
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .kind) {
    case .string:
      self = .string(try values.decode(String.self, forKey: .string))
    case .signedInteger:
      self = .signedInteger(try values.decode(Int64.self, forKey: .signedInteger))
    case .unsignedInteger:
      self = .unsignedInteger(try values.decode(UInt64.self, forKey: .unsignedInteger))
    case .decimal:
      self = .decimal(try values.decode(Double.self, forKey: .decimal))
    case .boolean:
      self = .boolean(try values.decode(Bool.self, forKey: .boolean))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .string(let value):
      try values.encode(Kind.string, forKey: .kind)
      try values.encode(value, forKey: .string)
    case .signedInteger(let value):
      try values.encode(Kind.signedInteger, forKey: .kind)
      try values.encode(value, forKey: .signedInteger)
    case .unsignedInteger(let value):
      try values.encode(Kind.unsignedInteger, forKey: .kind)
      try values.encode(value, forKey: .unsignedInteger)
    case .decimal(let value):
      try values.encode(Kind.decimal, forKey: .kind)
      try values.encode(value, forKey: .decimal)
    case .boolean(let value):
      try values.encode(Kind.boolean, forKey: .kind)
      try values.encode(value, forKey: .boolean)
    }
  }
}

/// One resolved workflow value recorded on the generated layer.
public struct ComfyUIParameterRecord: Codable, Equatable, Hashable, Sendable {
  public var address: ComfyUIParameterAddress
  public var value: ComfyUIParameterValue

  public init(address: ComfyUIParameterAddress, value: ComfyUIParameterValue) {
    self.address = address
    self.value = value
  }
}

/// Identifies the document-owned mask source requested or resolved for one
/// generation job without embedding document pixels or transport artifacts.
public struct GenerationMaskSource: Codable, Equatable, Sendable {
  /// `automatic` is a user-facing request that must be resolved against the
  /// frozen document state before a generation job starts. The legacy case
  /// preserves the behavior of callers and projects that predate selectable
  /// generation-mask sources.
  public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
    case automatic
    case legacySelectionOrEntireOutput
    case documentSelection
    case layerMask
    case localMask
    case transparentPixels
    case entireOutput
  }

  public var kind: Kind
  public var layerID: ProjectLayerID?
  public var maskID: MaskID?

  public init(
    kind: Kind,
    layerID: ProjectLayerID? = nil,
    maskID: MaskID? = nil
  ) {
    self.kind = kind
    self.layerID = layerID
    self.maskID = maskID
  }

  /// Whether the source identifies one concrete mask captured for execution.
  /// Requested sources may be automatic or omit IDs; resolved layer-owned
  /// sources must retain both owning identities.
  public var isResolved: Bool {
    switch kind {
    case .documentSelection:
      // A saved selection may retain its MaskID, but it is document-owned.
      layerID == nil
    case .transparentPixels, .entireOutput:
      layerID == nil && maskID == nil
    case .layerMask, .localMask:
      layerID != nil && maskID != nil
    case .automatic, .legacySelectionOrEntireOutput:
      false
    }
  }
}

/// The frozen editor conditioning supplied to an external inpainting workflow.
///
/// Uploaded server filenames are deliberately absent. They are temporary
/// transport details; the shared mask and source identity are the reproducible
/// project intent.
public struct ComfyUIInpaintingConditioningRecipe: Codable, Equatable, Sendable {
  public var source: GenerationSourceIdentity
  public var mask: MaskRecipe
  public var strength: Double
  public var maskFeatherPixels: Double
  /// Legacy baked-raster cutoff retained for older projects. Editable
  /// generated-inpaint layers own their cutoff separately from generation.
  public var changeThreshold: Double
  public var transparentPixelBackground: GenerationBackground
  /// Whether the mask sent to ComfyUI was expanded beyond the original mask
  /// retained for final layer alpha. Older recipes used one identical mask.
  public var expandMaskForComfyUI: Bool
  /// Compatibility mirror retained for older project readers. New recipes
  /// derive this solely from whether the resolved source is `entireOutput`.
  public var usesFullOutputMask: Bool
  /// What the caller asked Pixeltje to use. This may be automatic or the
  /// compatibility behavior used before mask sources were selectable.
  public var requestedMaskSource: GenerationMaskSource
  /// The concrete source frozen when the job started. This is provenance only;
  /// `mask` remains the exact shared-mask recipe captured for reproduction.
  public var resolvedMaskSource: GenerationMaskSource
  public var sourceWorkingColorSpace: String
  public var outputWorkingColorSpace: String

  public init(
    source: GenerationSourceIdentity,
    mask: MaskRecipe,
    strength: Double,
    maskFeatherPixels: Double,
    changeThreshold: Double = 0,
    transparentPixelBackground: GenerationBackground,
    expandMaskForComfyUI: Bool = false,
    usesFullOutputMask: Bool,
    requestedMaskSource: GenerationMaskSource? = nil,
    resolvedMaskSource: GenerationMaskSource? = nil,
    sourceWorkingColorSpace: String = "extendedLinearDisplayP3",
    outputWorkingColorSpace: String = "extendedLinearDisplayP3"
  ) {
    let legacyResolvedSource = GenerationMaskSource(
      kind: usesFullOutputMask ? .entireOutput : .documentSelection)
    let concreteSource = resolvedMaskSource ?? legacyResolvedSource
    precondition(concreteSource.isResolved, "A resolved generation mask source must be concrete.")
    self.source = source
    self.mask = mask
    self.strength = min(max(strength, 0), 1)
    self.maskFeatherPixels = max(maskFeatherPixels, 0)
    self.changeThreshold = min(max(changeThreshold, 0), 100)
    self.transparentPixelBackground = transparentPixelBackground
    self.expandMaskForComfyUI = expandMaskForComfyUI
    self.usesFullOutputMask = concreteSource.kind == .entireOutput
    self.requestedMaskSource = requestedMaskSource
      ?? GenerationMaskSource(kind: .legacySelectionOrEntireOutput)
    self.resolvedMaskSource = concreteSource
    self.sourceWorkingColorSpace = sourceWorkingColorSpace
    self.outputWorkingColorSpace = outputWorkingColorSpace
  }

  private enum CodingKeys: String, CodingKey {
    case source, mask, strength, maskFeatherPixels, changeThreshold
    case transparentPixelBackground, expandMaskForComfyUI, usesFullOutputMask
    case requestedMaskSource, resolvedMaskSource
    case sourceWorkingColorSpace, outputWorkingColorSpace
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let usesFullOutputMask = try values.decode(Bool.self, forKey: .usesFullOutputMask)
    let legacyResolvedSource = GenerationMaskSource(
      kind: usesFullOutputMask ? .entireOutput : .documentSelection)
    let resolvedMaskSource = try values.decodeIfPresent(
      GenerationMaskSource.self, forKey: .resolvedMaskSource) ?? legacyResolvedSource
    guard resolvedMaskSource.isResolved else {
      throw DecodingError.dataCorruptedError(
        forKey: .resolvedMaskSource,
        in: values,
        debugDescription: "The stored resolved generation mask source is not concrete.")
    }
    self.init(
      source: try values.decode(GenerationSourceIdentity.self, forKey: .source),
      mask: try values.decode(MaskRecipe.self, forKey: .mask),
      strength: try values.decode(Double.self, forKey: .strength),
      maskFeatherPixels: try values.decode(Double.self, forKey: .maskFeatherPixels),
      changeThreshold: try values.decodeIfPresent(Double.self, forKey: .changeThreshold) ?? 0,
      transparentPixelBackground: try values.decode(
        GenerationBackground.self, forKey: .transparentPixelBackground),
      expandMaskForComfyUI: try values.decodeIfPresent(
        Bool.self, forKey: .expandMaskForComfyUI) ?? false,
      usesFullOutputMask: usesFullOutputMask,
      requestedMaskSource: try values.decodeIfPresent(
        GenerationMaskSource.self, forKey: .requestedMaskSource),
      resolvedMaskSource: resolvedMaskSource,
      sourceWorkingColorSpace: try values.decode(String.self, forKey: .sourceWorkingColorSpace),
      outputWorkingColorSpace: try values.decode(String.self, forKey: .outputWorkingColorSpace))
  }
}

/// The frozen editor source supplied to an external image-to-image workflow.
///
/// Server upload names are temporary transport details and are deliberately
/// absent. The source identity and transparency treatment preserve the editor
/// intent needed to understand or explicitly regenerate the raster later.
public struct ComfyUIImageConditioningRecipe: Codable, Equatable, Sendable {
  public var source: GenerationSourceIdentity
  /// The canvas-pixel region uploaded to ComfyUI, or `nil` when the complete
  /// composite was used. A generated result is placed back over this region.
  public var sourceRegion: LayerFrame?
  public var transparentPixelBackground: GenerationBackground
  public var sourceWorkingColorSpace: String
  public var outputWorkingColorSpace: String

  public init(
    source: GenerationSourceIdentity,
    sourceRegion: LayerFrame? = nil,
    transparentPixelBackground: GenerationBackground,
    sourceWorkingColorSpace: String = "extendedLinearDisplayP3",
    outputWorkingColorSpace: String = "extendedLinearDisplayP3"
  ) {
    self.source = source
    self.sourceRegion = sourceRegion
    self.transparentPixelBackground = transparentPixelBackground
    self.sourceWorkingColorSpace = sourceWorkingColorSpace
    self.outputWorkingColorSpace = outputWorkingColorSpace
  }
}

/// The reproducible editor intent behind pixels generated by a ComfyUI workflow.
///
/// ComfyUI and its models remain link-only dependencies. The project records the
/// template identity and the exact values Pixeltje supplied, but never embeds a
/// server URL, model weights, or an arbitrary workflow copied from that server.
public struct ComfyUIGenerationRecipe: Codable, Equatable, Sendable {
  public var templateID: String
  public var templateRevision: String
  public var promptID: String
  /// The service that accepted promptID. Older recipes used local ComfyUI.
  public var executionTarget: ComfyUIExecutionTarget
  public var prompt: String
  public var negativePrompt: String
  public var seed: UInt64
  public var steps: Int
  public var guidance: Double
  public var outputWidth: Int
  public var outputHeight: Int
  /// Optional for compatibility with the first ComfyUI recipes, which were
  /// always text-to-image. Source-conditioned modes also carry their frozen
  /// editor intent below.
  public var mode: GenerationMode?
  public var inpainting: ComfyUIInpaintingConditioningRecipe?
  public var imageConditioning: ComfyUIImageConditioningRecipe?
  /// Every editable scalar resolved for this run, including workflow-authored
  /// values the user left unchanged. Older projects decode this as an empty
  /// array and retain their fixed summary fields above.
  public var parameters: [ComfyUIParameterRecord]

  public init(
    templateID: String,
    templateRevision: String,
    promptID: String,
    executionTarget: ComfyUIExecutionTarget = .local,
    prompt: String,
    negativePrompt: String,
    seed: UInt64,
    steps: Int,
    guidance: Double,
    outputWidth: Int,
    outputHeight: Int,
    mode: GenerationMode? = .textToImage,
    inpainting: ComfyUIInpaintingConditioningRecipe? = nil,
    imageConditioning: ComfyUIImageConditioningRecipe? = nil,
    parameters: [ComfyUIParameterRecord] = []
  ) {
    self.templateID = templateID
    self.templateRevision = templateRevision
    self.promptID = promptID
    self.executionTarget = executionTarget
    self.prompt = prompt
    self.negativePrompt = negativePrompt
    self.seed = seed
    self.steps = max(steps, 1)
    self.guidance = guidance
    self.outputWidth = max(outputWidth, 1)
    self.outputHeight = max(outputHeight, 1)
    self.mode = mode
    self.inpainting = inpainting
    self.imageConditioning = imageConditioning
    self.parameters = parameters
  }

  public var effectiveMode: GenerationMode {
    mode
      ?? (inpainting != nil
        ? .inpainting : imageConditioning != nil ? .imageToImage : .textToImage)
  }

  private enum CodingKeys: String, CodingKey {
    case templateID, templateRevision, promptID, executionTarget, prompt, negativePrompt
    case seed, steps, guidance, outputWidth, outputHeight, mode, inpainting, imageConditioning
    case parameters
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      templateID: try values.decode(String.self, forKey: .templateID),
      templateRevision: try values.decode(String.self, forKey: .templateRevision),
      promptID: try values.decode(String.self, forKey: .promptID),
      executionTarget: try values.decodeIfPresent(
        ComfyUIExecutionTarget.self, forKey: .executionTarget) ?? .local,
      prompt: try values.decode(String.self, forKey: .prompt),
      negativePrompt: try values.decode(String.self, forKey: .negativePrompt),
      seed: try values.decode(UInt64.self, forKey: .seed),
      steps: try values.decode(Int.self, forKey: .steps),
      guidance: try values.decode(Double.self, forKey: .guidance),
      outputWidth: try values.decode(Int.self, forKey: .outputWidth),
      outputHeight: try values.decode(Int.self, forKey: .outputHeight),
      mode: try values.decodeIfPresent(GenerationMode.self, forKey: .mode),
      inpainting: try values.decodeIfPresent(
        ComfyUIInpaintingConditioningRecipe.self, forKey: .inpainting),
      imageConditioning: try values.decodeIfPresent(
        ComfyUIImageConditioningRecipe.self, forKey: .imageConditioning),
      parameters: try values.decodeIfPresent([ComfyUIParameterRecord].self, forKey: .parameters)
        ?? [])
  }
}

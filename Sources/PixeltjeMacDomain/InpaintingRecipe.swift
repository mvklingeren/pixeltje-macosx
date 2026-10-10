import Foundation

/// Stable, link-only identity for the Core AI package functions needed to
/// reproduce a generated layer. The package itself never enters the project.
public struct CoreAIModelPackageIdentity: Codable, Equatable, Sendable {
  public struct Function: Codable, Equatable, Sendable {
    public var role: String
    public var packageName: String
    public var functionName: String
    /// Publisher-declared identity metadata only. The loader neither computes
    /// nor verifies this value.
    public var declaredContentHash: String?

    public init(
      role: String,
      packageName: String,
      functionName: String = "main",
      declaredContentHash: String? = nil
    ) {
      self.role = role
      self.packageName = packageName
      self.functionName = functionName
      self.declaredContentHash = declaredContentHash
    }
  }

  public var provider: String
  public var model: String
  public var modelRevision: String
  public var hostPipelineRevision: String
  public var functions: [Function]

  public init(
    provider: String,
    model: String,
    modelRevision: String,
    hostPipelineRevision: String,
    functions: [Function]
  ) {
    self.provider = provider
    self.model = model
    self.modelRevision = modelRevision
    self.hostPipelineRevision = hostPipelineRevision
    self.functions = functions
  }
}

public enum GenerationSourceCapture: String, Codable, Equatable, Sendable {
  case composite
  case activeLayer
}

/// The immutable editor state that supplied pixels to a generation job.
public struct GenerationSourceIdentity: Codable, Equatable, Sendable {
  public var documentID: String
  public var contentRevision: UInt64
  public var capture: GenerationSourceCapture
  public var activeLayerID: ProjectLayerID?

  public init(
    documentID: String,
    contentRevision: UInt64,
    capture: GenerationSourceCapture = .composite,
    activeLayerID: ProjectLayerID? = nil
  ) {
    self.documentID = documentID
    self.contentRevision = contentRevision
    self.capture = capture
    self.activeLayerID = activeLayerID
  }
}

public enum GenerationSampler: String, Codable, Equatable, Sendable {
  case euler
}

public enum GenerationScheduler: String, Codable, Equatable, Sendable {
  case flowMatchEuler
}

public enum GenerationMode: String, Codable, Equatable, Hashable, Sendable {
  case textToImage
  case imageToImage
  case inpainting
  case selection
}

/// The color supplied to the model wherever the captured source is transparent.
///
/// This is conditioning input, not a promise that diffusion will produce a
/// flat background of the same color.
public enum GenerationBackground: String, Codable, CaseIterable, Equatable, Sendable {
  case white
  case gray
  case black
}

/// Everything needed to understand and explicitly regenerate a generated
/// raster. Text-to-image ignores source conditioning and the captured mask;
/// inpainting uses both. The historical type name remains part of the saved
/// project/API compatibility surface.
public struct InpaintingRecipe: Codable, Equatable, Sendable {
  /// Optional for compatibility with recipes created before blank-canvas
  /// generation had a distinct noise-to-image path. A missing value means the
  /// historical inpainting behavior.
  public var mode: GenerationMode?
  public var model: CoreAIModelPackageIdentity
  public var prompt: String
  public var negativePrompt: String
  public var source: GenerationSourceIdentity
  public var mask: MaskRecipe
  public var seed: UInt64
  public var sampler: GenerationSampler
  public var scheduler: GenerationScheduler
  public var steps: Int
  public var guidance: Double
  public var strength: Double
  public var maskFeatherPixels: Double
  /// Optional so projects created before this setting reproduce their original
  /// black transparent-source conditioning when decoded.
  public var transparentPixelBackground: GenerationBackground?
  public var modelWidth: Int
  public var modelHeight: Int
  /// Pixel dimensions of the authored raster. Optional so generated layers
  /// saved before output size became independent of the canvas still decode.
  public var outputWidth: Int?
  public var outputHeight: Int?
  /// `true` when generation began without a selection, so the implicit mask
  /// follows the independent output extent rather than the source canvas.
  public var usesFullOutputMask: Bool?
  public var sourceWorkingColorSpace: String
  public var outputWorkingColorSpace: String

  public init(
    mode: GenerationMode? = .inpainting,
    model: CoreAIModelPackageIdentity,
    prompt: String,
    negativePrompt: String = "",
    source: GenerationSourceIdentity,
    mask: MaskRecipe,
    seed: UInt64,
    sampler: GenerationSampler = .euler,
    scheduler: GenerationScheduler = .flowMatchEuler,
    steps: Int = 8,
    guidance: Double = 1,
    strength: Double = 0.85,
    maskFeatherPixels: Double = 8,
    transparentPixelBackground: GenerationBackground? = .white,
    modelWidth: Int = 512,
    modelHeight: Int = 512,
    outputWidth: Int? = nil,
    outputHeight: Int? = nil,
    usesFullOutputMask: Bool? = nil,
    sourceWorkingColorSpace: String = "extendedLinearDisplayP3",
    outputWorkingColorSpace: String = "extendedLinearDisplayP3"
  ) {
    self.mode = mode
    self.model = model
    self.prompt = prompt
    self.negativePrompt = negativePrompt
    self.source = source
    self.mask = mask
    self.seed = seed
    self.sampler = sampler
    self.scheduler = scheduler
    self.steps = max(1, steps)
    self.guidance = guidance
    self.strength = min(max(strength, 0), 1)
    self.maskFeatherPixels = max(maskFeatherPixels, 0)
    self.transparentPixelBackground = transparentPixelBackground
    self.modelWidth = max(modelWidth, 1)
    self.modelHeight = max(modelHeight, 1)
    self.outputWidth = outputWidth.map { max($0, 1) }
    self.outputHeight = outputHeight.map { max($0, 1) }
    self.usesFullOutputMask = usesFullOutputMask
    self.sourceWorkingColorSpace = sourceWorkingColorSpace
    self.outputWorkingColorSpace = outputWorkingColorSpace
  }

  public var effectiveMode: GenerationMode { mode ?? .inpainting }
}

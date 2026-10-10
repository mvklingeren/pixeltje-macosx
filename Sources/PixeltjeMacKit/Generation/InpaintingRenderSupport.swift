import CoreImage
import Foundation
import IOSurface
import PixeltjeMacDomain
import PixeltjePipelineEngine

public struct InpaintingRenderRequest: Sendable {
  public var sourceFrame: RenderedFrame
  public var recipe: InpaintingRecipe
  public var modelPackageURL: URL

  public init(
    sourceFrame: RenderedFrame,
    recipe: InpaintingRecipe,
    modelPackageURL: URL
  ) {
    self.sourceFrame = sourceFrame
    self.recipe = recipe
    self.modelPackageURL = modelPackageURL
  }
}

/// The immutable editor mask whose coverage is frozen for one inpainting job.
///
/// Document masks already live in canvas coordinates. Layer-owned masks need
/// their owning layer's pixel stage, crop, and transform hierarchy, so they
/// are identified rather than copied out and evaluated as document masks.
public enum InpaintingMaskRenderSource: Equatable, Sendable {
  case documentMask(MaskRecipe)
  case layerMask(layerID: ProjectLayerID, maskID: MaskID)
  case localMask(layerID: ProjectLayerID, maskID: MaskID)
}

/// Everything the render actor needs to freeze a mask at the same revision as
/// the source composite. The request has value semantics, so later document
/// edits cannot change either the pixels read by a source-dependent mask or
/// the spatial transforms applied to its coverage.
public struct InpaintingMaskRenderRequest: Sendable {
  public var renderRequest: RenderRequest
  public var source: InpaintingMaskRenderSource

  public init(renderRequest: RenderRequest, source: InpaintingMaskRenderSource) {
    self.renderRequest = renderRequest
    self.source = source
  }
}

/// Final canvas-space mask coverage captured for one document revision.
/// Coverage is row-major in Core Image's top-down bitmap storage order, one
/// clamped linear value per pixel. `nonzeroBounds` uses Core Image's
/// bottom-left image coordinates.
public struct InpaintingMaskRenderResult: Sendable {
  public let documentID: UUID
  public let revision: UInt64
  public let contentRevision: UInt64
  public let width: Int
  public let height: Int
  public let coverage: [Float]
  public let nonzeroBounds: LayerFrame
}

public struct TextToImageRenderRequest: Sendable {
  public var documentID: UUID
  public var revision: UInt64
  public var contentRevision: UInt64
  public var canvas: CanvasRecipe
  public var recipe: InpaintingRecipe
  public var modelPackageURL: URL

  public init(
    documentID: UUID,
    revision: UInt64,
    contentRevision: UInt64,
    canvas: CanvasRecipe,
    recipe: InpaintingRecipe,
    modelPackageURL: URL
  ) {
    self.documentID = documentID
    self.revision = revision
    self.contentRevision = contentRevision
    self.canvas = canvas
    self.recipe = recipe
    self.modelPackageURL = modelPackageURL
  }
}

public struct GenerationRenderPreview: Sendable {
  public var frame: RenderedFrame
  public var step: Int
  public var totalSteps: Int
}

public struct GenerationRenderResult: Sendable {
  public var raster: RasterBakeResult
  public var placementFrame: LayerFrame
  public var outsideMaskPixelCount: Int
  public var preservedOutsideMaskPixelCount: Int
}

struct InpaintingOutputGeometry: Equatable, Sendable {
  var outputBounds: CGRect
  var sourceOffset: CanvasOffset
  var placementFrame: LayerFrame
}

/// Active ComfyUI inpainting geometry separates the server's bounded working
/// raster from the canvas region it represents. A small mask keeps the former
/// one-pixel-for-one focused patch. A mask wider or taller than that patch —
/// including Entire Output — sends the complete composite aspect-fitted into
/// the configured maximum, then maps the returned pixels back over the frozen
/// full-resolution source region locally.
struct ComfyUIInpaintingGeometry: Equatable, Sendable {
  var uploadBounds: CGRect
  var placementFrame: LayerFrame

  var compositeBounds: CGRect {
    CGRect(
      x: 0,
      y: 0,
      width: placementFrame.width,
      height: placementFrame.height)
  }
}

struct ComfyUIInpaintingPreparation: Sendable {
  var sourcePNG: Data
  var maskPNG: Data
  var originalPixels: Data
  var maskCoverage: [Float]
  var placementFrame: LayerFrame
  var width: Int
  var height: Int
  var conditioning: ComfyUIInpaintingConditioningRecipe

  var compositeWidth: Int { max(Int(placementFrame.width.rounded()), 1) }
  var compositeHeight: Int { max(Int(placementFrame.height.rounded()), 1) }
  var compositeBounds: CGRect {
    CGRect(x: 0, y: 0, width: compositeWidth, height: compositeHeight)
  }
}

/// Decoded once after ComfyUI returns and converted to the immutable backing
/// assets of an editable generated-inpaint layer.
struct ComfyUIInpaintingOutput: Sendable {
  var preparation: ComfyUIInpaintingPreparation
  var generatedPixels: Data
  var perceptualDifference: [Float]
}

struct ComfyUIInpaintingLayerAssets: Sendable {
  var source: RasterBakeResult
  var generated: RasterBakeResult
  var analysis: RasterBakeResult

  var all: [RasterBakeResult] { [source, generated, analysis] }
}

struct ComfyUIImageConditioningPreparation: Sendable {
  var sourcePNG: Data
  var sourceRaster: RasterBakeResult
  var placementFrame: LayerFrame
  var width: Int
  var height: Int
  var conditioning: ComfyUIImageConditioningRecipe
}

/// Actor-owned working set for editable inpaint layers. The immutable inputs
/// survive threshold changes; only the most recent masked layer per input set
/// is retained, so a slider drag cannot fill the cache with 101 full-size images.
struct GeneratedInpaintCache {
  struct Key: Hashable {
    var source: RasterAssetReference
    var generated: RasterAssetReference
    var analysis: RasterAssetReference

    init(_ recipe: GeneratedInpaintLayerRecipe) {
      source = recipe.source
      generated = recipe.generated
      analysis = recipe.analysis
    }
  }

  struct Decoded {
    var generated: Data
    var difference: [Float]
    var coverage: [Float]
    var lastAccess: UInt64 = 0

    var byteCost: Int {
      generated.count + (difference.count + coverage.count) * MemoryLayout<Float>.stride
    }
  }

  private struct Composed {
    var threshold: Float
    /// `CIImage(bitmapData:)` is lazy, so keep these bytes alive with the image.
    var pixels: Data
    var image: CIImage
    var lastAccess: UInt64

    var byteCost: Int { pixels.count }
  }

  struct Statistics: Sendable {
    var decodedBuilds = 0
    var composedBuilds = 0
    var imageHits = 0
  }

  // Each tier is bounded independently. A very large layer can still retain
  // its cheaper finished image even when its three decoded inputs exceed the
  // input budget. Memory-pressure handling clears both tiers.
  private static let decodedByteLimit = 256 * 1_024 * 1_024
  private static let composedByteLimit = 256 * 1_024 * 1_024
  private var decodedEntries: [Key: Decoded] = [:]
  private var composedEntries: [Key: Composed] = [:]
  private var decodedBytes = 0
  private var composedBytes = 0
  private var accessClock: UInt64 = 0
  private(set) var statistics = Statistics()

  mutating func clear() {
    decodedEntries.removeAll()
    composedEntries.removeAll()
    decodedBytes = 0
    composedBytes = 0
  }

  mutating func image(for key: Key, threshold: Float) -> (image: CIImage, pixels: Data)? {
    guard var entry = composedEntries[key], entry.threshold == threshold else { return nil }
    accessClock &+= 1
    entry.lastAccess = accessClock
    composedEntries[key] = entry
    statistics.imageHits += 1
    return (entry.image, entry.pixels)
  }

  mutating func decoded(for key: Key) -> Decoded? {
    guard var entry = decodedEntries[key] else { return nil }
    accessClock &+= 1
    entry.lastAccess = accessClock
    decodedEntries[key] = entry
    return entry
  }

  mutating func storeDecoded(_ decoded: Decoded, for key: Key) {
    statistics.decodedBuilds += 1
    guard decoded.byteCost <= Self.decodedByteLimit else { return }
    if let old = decodedEntries.removeValue(forKey: key) { decodedBytes -= old.byteCost }
    accessClock &+= 1
    var entry = decoded
    entry.lastAccess = accessClock
    decodedEntries[key] = entry
    decodedBytes += entry.byteCost
    while decodedBytes > Self.decodedByteLimit,
      let oldest = decodedEntries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
    {
      decodedEntries.removeValue(forKey: oldest.key)
      decodedBytes -= oldest.value.byteCost
    }
  }

  mutating func storeImage(_ image: CIImage, pixels: Data, for key: Key, threshold: Float) {
    statistics.composedBuilds += 1
    guard pixels.count <= Self.composedByteLimit else { return }
    if let old = composedEntries.removeValue(forKey: key) { composedBytes -= old.byteCost }
    accessClock &+= 1
    let entry = Composed(
      threshold: threshold, pixels: pixels, image: image, lastAccess: accessClock)
    composedEntries[key] = entry
    composedBytes += entry.byteCost
    while composedBytes > Self.composedByteLimit,
      let oldest = composedEntries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
    {
      composedEntries.removeValue(forKey: oldest.key)
      composedBytes -= oldest.value.byteCost
    }
  }
}

extension RenderEngine {
  /// One upload-space VAE cell of overscan keeps ComfyUI's latent/noise-mask
  /// transition outside the original mask used for final layer alpha.
  nonisolated static let comfyUITransportMaskExpansionPixels = 8.0

  func generatedInpaintCacheStatistics() -> GeneratedInpaintCache.Statistics {
    generatedInpaintCache.statistics
  }

  /// Fits a source-conditioned workflow inside the selected generation box
  /// without changing the source aspect ratio. FLUX.2 dimensions are rounded
  /// down to whole sixteen-pixel blocks so its latent path does not shrink the
  /// returned image after Pixeltje has frozen the conditioning geometry.
  nonisolated static func imageConditioningOutputSize(
    source: CanvasRecipe,
    maximum: CanvasRecipe
  ) -> CanvasRecipe {
    guard source.isResolved, maximum.isResolved else { return maximum }
    let scale = min(
      Double(maximum.width) / Double(source.width),
      Double(maximum.height) / Double(source.height))
    func aligned(_ value: Double) -> Int {
      max(Int(value.rounded(.down)) / 16 * 16, 16)
    }
    return CanvasRecipe(
      width: aligned(Double(source.width) * scale),
      height: aligned(Double(source.height) * scale))
  }

  /// Freezes the selected region of the current composite as the sole runtime
  /// input to a ComfyUI image-to-image graph. With no selection the region is
  /// the complete canvas. Pixeltje resolves the requested dimensions before
  /// upload, so the bundled workflow must preserve this source geometry.
  func prepareComfyUIImageConditioning(
    sourceFrame: RenderedFrame,
    conditioning: ComfyUIImageConditioningRecipe,
    outputWidth: Int,
    outputHeight: Int
  ) throws -> ComfyUIImageConditioningPreparation {
    guard sourceFrame.width > 0, sourceFrame.height > 0 else {
      throw PixeltjeMacError("Image editing unavailable", "The displayed image has no pixels.")
    }
    guard sourceFrame.documentID.uuidString == conditioning.source.documentID,
      sourceFrame.contentRevision == conditioning.source.contentRevision
    else {
      throw PixeltjeMacError(
        "Source changed",
        "The image-editing source no longer matches the document revision captured by the recipe."
      )
    }

    let sourceBounds = CGRect(
      x: 0, y: 0, width: sourceFrame.width, height: sourceFrame.height)
    let sourceRegion: CGRect
    if let requestedRegion = conditioning.sourceRegion {
      guard requestedRegion.x.isFinite, requestedRegion.y.isFinite,
        requestedRegion.width.isFinite, requestedRegion.height.isFinite
      else {
        throw PixeltjeMacError(
          "Image editing unavailable", "The selected source region is invalid.")
      }
      let clipped = CGRect(
        x: requestedRegion.x,
        y: requestedRegion.y,
        width: requestedRegion.width,
        height: requestedRegion.height
      ).integral.intersection(sourceBounds)
      guard !clipped.isNull, !clipped.isEmpty else {
        throw PixeltjeMacError(
          "Image editing unavailable", "The active selection does not contain any pixels.")
      }
      sourceRegion = clipped
    } else {
      sourceRegion = sourceBounds
    }
    let outputBounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
    let source = CIImage(
      ioSurface: sourceFrame.surface,
      options: [.colorSpace: workingColorSpace]
    ).cropped(to: sourceBounds)
    let sourceForOutput = source
      .cropped(to: sourceRegion)
      .transformed(
        by: CGAffineTransform(
          translationX: -sourceRegion.minX,
          y: -sourceRegion.minY))
      .transformed(
        by: CGAffineTransform(
          scaleX: CGFloat(outputWidth) / sourceRegion.width,
          y: CGFloat(outputHeight) / sourceRegion.height))
      .cropped(to: outputBounds)
    let background: CIColor =
      switch conditioning.transparentPixelBackground {
      case .white: CIColor(red: 1, green: 1, blue: 1, alpha: 1)
      case .gray: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
      case .black: CIColor(red: 0, green: 0, blue: 0, alpha: 1)
      }
    let opaqueSource = sourceForOutput
      .composited(over: CIImage(color: background).cropped(to: outputBounds))
      .cropped(to: outputBounds)
    let uploadColorSpace =
      CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let sourcePNG = processingContext.pngRepresentation(
        of: opaqueSource,
        format: .RGBA8,
        colorSpace: uploadColorSpace,
        options: [:])
    else {
      throw PixeltjeMacError(
        "Image-editing upload unavailable", "The source could not be encoded as PNG.")
    }
    try Task.checkCancellation()
    guard let uploadedSource = CIImage(data: sourcePNG) else {
      throw PixeltjeMacError(
        "Image-editing upload unavailable", "The encoded source could not be read back.")
    }
    let sourceRaster = try importRaster(uploadedSource)
    return ComfyUIImageConditioningPreparation(
      sourcePNG: sourcePNG,
      sourceRaster: sourceRaster,
      placementFrame: LayerFrame(
        x: sourceRegion.minX,
        y: sourceRegion.minY,
        width: sourceRegion.width,
        height: sourceRegion.height),
      width: outputWidth,
      height: outputHeight,
      conditioning: conditioning)
  }

  /// Imports a complete image-to-image result at the exact location occupied
  /// by the frozen source passed to the workflow.
  func finishComfyUIImageConditioning(
    imageData: Data,
    preparation: ComfyUIImageConditioningPreparation
  ) throws -> GenerationRenderResult {
    guard
      let decoded = CIImage(
        data: imageData,
        options: [.applyOrientationProperty: true])
    else {
      throw PixeltjeMacError(
        "ComfyUI output unreadable", "The server output is not a supported image.")
    }
    let width = Int(decoded.extent.width.rounded())
    let height = Int(decoded.extent.height.rounded())
    guard width == preparation.width, height == preparation.height else {
      throw PixeltjeMacError(
        "ComfyUI output size changed",
        "The workflow returned \(width) × \(height), but the frozen image-editing source is \(preparation.width) × \(preparation.height)."
      )
    }
    let grounded = decoded.transformed(
      by: CGAffineTransform(
        translationX: -decoded.extent.minX,
        y: -decoded.extent.minY))
    let raster = try importRaster(grounded)
    try Task.checkCancellation()
    return GenerationRenderResult(
      raster: raster,
      placementFrame: preparation.placementFrame,
      outsideMaskPixelCount: 0,
      preservedOutsideMaskPixelCount: 0)
  }

  /// Freezes the editor's source and shared mask into the two PNG inputs used
  /// by ComfyUI. The source is made opaque for model conditioning; the
  /// original linear-P3 half-float pixels stay local for the exact compositor.
  func prepareComfyUIInpainting(
    sourceFrame: RenderedFrame,
    conditioning: ComfyUIInpaintingConditioningRecipe,
    outputWidth: Int,
    outputHeight: Int,
    imageAlignment: Int = 8,
    renderedMask: InpaintingMaskRenderResult? = nil
  ) async throws -> ComfyUIInpaintingPreparation {
    guard sourceFrame.width > 0, sourceFrame.height > 0 else {
      throw PixeltjeMacError("Inpainting unavailable", "The displayed image has no pixels.")
    }
    guard sourceFrame.documentID.uuidString == conditioning.source.documentID,
      sourceFrame.contentRevision == conditioning.source.contentRevision
    else {
      throw PixeltjeMacError(
        "Source changed",
        "The generation source no longer matches the document revision captured by the recipe.")
    }

    let sourceBounds = CGRect(
      x: 0, y: 0, width: sourceFrame.width, height: sourceFrame.height)
    let source = CIImage(
      ioSurface: sourceFrame.surface,
      options: [.colorSpace: workingColorSpace]
    ).cropped(to: sourceBounds)
    let usesTransparencyMask =
      conditioning.resolvedMaskSource.kind == .transparentPixels
    let frozenMask = conditioning.usesFullOutputMask ? nil : renderedMask
    if !conditioning.usesFullOutputMask,
      !usesTransparencyMask,
      frozenMask == nil,
      conditioning.requestedMaskSource.kind != .legacySelectionOrEntireOutput
    {
      throw PixeltjeMacError(
        "Inpainting mask unavailable",
        "The resolved inpainting mask was not captured with the generation source.")
    }
    if let frozenMask {
      guard frozenMask.documentID == sourceFrame.documentID,
        frozenMask.revision == sourceFrame.revision,
        frozenMask.contentRevision == sourceFrame.contentRevision,
        frozenMask.width == sourceFrame.width,
        frozenMask.height == sourceFrame.height
      else {
        throw PixeltjeMacError(
          "Source changed",
          "The frozen inpainting mask does not match the captured composite.")
      }
    }
    let transparencyMask: CIImage?
    let transparencyBounds: LayerFrame?
    if usesTransparencyMask {
      let mask = sourceTransparencyMask(from: source, in: sourceBounds)
      let coverage = try maskCoverage(from: mask, in: sourceBounds)
      guard let bounds = Self.nonzeroMaskBounds(
        coverage, width: sourceFrame.width, height: sourceFrame.height)
      else {
        throw PixeltjeMacError(
          "Inpainting needs transparent pixels",
          "The composite is fully opaque. Create a selection, choose a layer mask, or choose Entire Output explicitly.")
      }
      transparencyMask = mask
      transparencyBounds = bounds
    } else {
      transparencyMask = nil
      transparencyBounds = nil
    }
    let resolvedMaskBounds = transparencyBounds ?? frozenMask?.nonzeroBounds
      ?? Self.inpaintingSelectionBounds(conditioning.mask, in: sourceBounds)
    let maskBounds = resolvedMaskBounds.map { bounds -> LayerFrame in
      let blur = max(conditioning.maskFeatherPixels, 0)
      let transportExpansion = conditioning.expandMaskForComfyUI
        ? Self.comfyUITransportMaskExpansionPixels
        : 0
      let expansion = blur + transportExpansion
      guard expansion > 0 else { return bounds }
      let expanded = CGRect(
        x: bounds.x - expansion,
        y: bounds.y - expansion,
        width: bounds.width + expansion * 2,
        height: bounds.height + expansion * 2
      ).intersection(sourceBounds)
      return LayerFrame(
        x: expanded.minX,
        y: expanded.minY,
        width: expanded.width,
        height: expanded.height)
    }
    let geometry = Self.comfyUIInpaintingGeometry(
      sourceWidth: sourceFrame.width,
      sourceHeight: sourceFrame.height,
      maximumWidth: outputWidth,
      maximumHeight: outputHeight,
      maskBounds: maskBounds,
      usesFullOutputMask: conditioning.usesFullOutputMask,
      alignment: imageAlignment)
    let compositeBounds = geometry.compositeBounds
    let uploadBounds = geometry.uploadBounds
    let sourceForComposite = source
      .transformed(
        by: CGAffineTransform(
          translationX: -CGFloat(geometry.placementFrame.x),
          y: -CGFloat(geometry.placementFrame.y)))
      .composited(over: CIImage(color: .clear).cropped(to: compositeBounds))
      .cropped(to: compositeBounds)

    let compositeCanvas = CanvasRecipe(
      width: Int(compositeBounds.width), height: Int(compositeBounds.height))
    let maskImage: CIImage
    if let transparencyMask {
      let zero = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
        .cropped(to: compositeBounds)
      var translated = transparencyMask
        .transformed(
          by: CGAffineTransform(
            translationX: -CGFloat(geometry.placementFrame.x),
            y: -CGFloat(geometry.placementFrame.y)))
        .composited(over: zero)
        .cropped(to: compositeBounds)
      translated = maskRenderer.feathered(
        translated,
        by: conditioning.maskFeatherPixels,
        in: MaskSpace(extent: compositeBounds, pixelsPerCanvasPixel: 1))
      maskImage = translated
    } else if conditioning.usesFullOutputMask {
      guard
        let evaluated = try maskRenderer.evaluate(
          .selectingAll,
          in: MaskSpace(extent: compositeBounds, pixelsPerCanvasPixel: 1),
          source: sourceForComposite,
          sourceIdentity:
            "comfy-generation:\(sourceFrame.documentID.uuidString):\(sourceFrame.contentRevision):\(compositeCanvas.width)x\(compositeCanvas.height)")
      else {
        throw PixeltjeMacError(
          "Inpainting needs a mask", "The entire-output mask could not be prepared.")
      }
      maskImage = evaluated
    } else if let frozenMask {
      let zero = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
        .cropped(to: compositeBounds)
      var translated = coverageImage(from: frozenMask)
        .transformed(
          by: CGAffineTransform(
            translationX: -CGFloat(geometry.placementFrame.x),
            y: -CGFloat(geometry.placementFrame.y)))
        .composited(over: zero)
        .cropped(to: compositeBounds)
      // The mask recipe's own feather was already resolved in its owning
      // coordinate space. Prompt Box blur is applied to the retained local
      // mask before the transport copy is resized, so upload and final
      // composition remain derived from exactly the same coverage.
      translated = maskRenderer.feathered(
        translated,
        by: conditioning.maskFeatherPixels,
        in: MaskSpace(extent: compositeBounds, pixelsPerCanvasPixel: 1))
      maskImage = translated
    } else {
      // Compatibility for old callers and recipes: document selection masks
      // keep their former direct evaluation path until they opt into an
      // explicit immutable mask-render request.
      let sourceCanvas = CanvasRecipe(width: sourceFrame.width, height: sourceFrame.height)
      var featheredMask = conditioning.mask.resizingCanvas(
        from: sourceCanvas,
        to: compositeCanvas,
        offset: CanvasOffset(
          x: -geometry.placementFrame.x,
          y: -geometry.placementFrame.y))
      featheredMask.feather += conditioning.maskFeatherPixels
      guard
        let evaluated = try maskRenderer.evaluate(
          featheredMask,
          in: MaskSpace(extent: compositeBounds, pixelsPerCanvasPixel: 1),
          source: sourceForComposite,
          sourceIdentity:
            "comfy-generation:\(sourceFrame.documentID.uuidString):\(sourceFrame.contentRevision):\(compositeCanvas.width)x\(compositeCanvas.height)")
      else {
        throw PixeltjeMacError(
          "Inpainting needs a selection",
          "The active selection could not produce mask coverage.")
      }
      maskImage = evaluated
    }
    let coverage = try maskCoverage(from: maskImage, in: compositeBounds)
    guard coverage.contains(where: { $0 > 0 }) else {
      let source = usesTransparencyMask ? "transparent-pixel mask" : "resolved mask"
      throw PixeltjeMacError(
        "Inpainting mask preparation failed",
        "The \(source) became empty while preparing its focused patch.")
    }

    let background: CIColor =
      switch conditioning.transparentPixelBackground {
      case .white: CIColor(red: 1, green: 1, blue: 1, alpha: 1)
      case .gray: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
      case .black: CIColor(red: 0, green: 0, blue: 0, alpha: 1)
      }
    let uploadScale = CGAffineTransform(
      scaleX: uploadBounds.width / compositeBounds.width,
      y: uploadBounds.height / compositeBounds.height)
    let sourceForUpload = sourceForComposite
      .transformed(by: uploadScale)
      .cropped(to: uploadBounds)
    let opaqueSource = sourceForUpload
      .composited(over: CIImage(color: background).cropped(to: uploadBounds))
      .cropped(to: uploadBounds)
    let finalMaskForUpload = maskImage
      .transformed(by: uploadScale)
      .cropped(to: uploadBounds)
    let transportMaskForUpload = conditioning.expandMaskForComfyUI
      ? finalMaskForUpload
        .applyingFilter(
          "CIMorphologyMaximum",
          parameters: [
            kCIInputRadiusKey: Self.comfyUITransportMaskExpansionPixels
          ])
        .cropped(to: uploadBounds)
      : finalMaskForUpload
    let uploadMask = transportMaskForUpload.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputAVector": CIVector(x: -1, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
      ]
    ).cropped(to: uploadBounds)
    let uploadColorSpace =
      CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let sourcePNG = processingContext.pngRepresentation(
        of: opaqueSource,
        format: .RGBA8,
        colorSpace: uploadColorSpace,
        options: [:]),
      let maskPNG = processingContext.pngRepresentation(
        of: uploadMask,
        format: .RGBA8,
        colorSpace: uploadColorSpace,
        options: [:])
    else {
      throw PixeltjeMacError(
        "Inpainting upload unavailable", "The source and mask could not be encoded as PNG.")
    }
    try Task.checkCancellation()
    return ComfyUIInpaintingPreparation(
      sourcePNG: sourcePNG,
      maskPNG: maskPNG,
      originalPixels: rgba16Pixels(of: sourceForComposite, in: compositeBounds),
      maskCoverage: coverage,
      placementFrame: geometry.placementFrame,
      width: Int(uploadBounds.width),
      height: Int(uploadBounds.height),
      conditioning: conditioning)
  }

  /// Converts the server image back into the document working space and
  /// restores every zero-coverage pixel from the frozen source byte-for-byte.
  func finishComfyUIInpainting(
    imageData: Data,
    preparation: ComfyUIInpaintingPreparation
  ) throws -> GenerationRenderResult {
    let output = try prepareComfyUIInpaintingOutput(
      imageData: imageData, preparation: preparation)
    return try finishComfyUIInpainting(output)
  }

  func prepareComfyUIInpaintingOutput(
    imageData: Data,
    preparation: ComfyUIInpaintingPreparation
  ) throws -> ComfyUIInpaintingOutput {
    guard
      let decoded = CIImage(
        data: imageData,
        options: [.applyOrientationProperty: true])
    else {
      throw PixeltjeMacError(
        "ComfyUI output unreadable", "The server output is not a supported image.")
    }
    let width = Int(decoded.extent.width.rounded())
    let height = Int(decoded.extent.height.rounded())
    guard width == preparation.width, height == preparation.height else {
      throw PixeltjeMacError(
        "ComfyUI output size changed",
        "The workflow returned \(width) × \(height), but the frozen inpainting source is \(preparation.width) × \(preparation.height).")
    }
    let uploadBounds = CGRect(x: 0, y: 0, width: width, height: height)
    let compositeBounds = preparation.compositeBounds
    let outputScale = CGAffineTransform(
      scaleX: compositeBounds.width / uploadBounds.width,
      y: compositeBounds.height / uploadBounds.height)
    let generated = decoded
      .transformed(
        by: CGAffineTransform(
          translationX: -decoded.extent.minX,
          y: -decoded.extent.minY))
      .cropped(to: uploadBounds)
      .transformed(by: outputScale)
      .cropped(to: compositeBounds)
    guard let uploaded = CIImage(data: preparation.sourcePNG) else {
      throw PixeltjeMacError(
        "Inpainting source unavailable", "The frozen ComfyUI source could not be decoded.")
    }
    let uploadedForComparison = uploaded
      .transformed(
        by: CGAffineTransform(
          translationX: -uploaded.extent.minX,
          y: -uploaded.extent.minY))
      .cropped(to: uploadBounds)
      .transformed(by: outputScale)
      .cropped(to: compositeBounds)
    let originalSRGB = srgb8Pixels(of: uploadedForComparison, in: compositeBounds)
    let generatedSRGB = srgb8Pixels(of: generated, in: compositeBounds)
    let difference = Self.perceptualDifference(
      uploaded: originalSRGB,
      returned: generatedSRGB,
      original: preparation.originalPixels)
    try Task.checkCancellation()
    return ComfyUIInpaintingOutput(
      preparation: preparation,
      generatedPixels: rgba16Pixels(of: generated, in: compositeBounds),
      perceptualDifference: difference)
  }

  func finishComfyUIInpainting(
    _ output: ComfyUIInpaintingOutput,
    changeThreshold: Double? = nil
  ) throws -> GenerationRenderResult {
    try Task.checkCancellation()
    let preparation = output.preparation
    let width = preparation.compositeWidth
    let height = preparation.compositeHeight
    let threshold = min(max(changeThreshold ?? preparation.conditioning.changeThreshold, 0), 100)
    let changeMatte = threshold > 0
      ? Self.changeMatte(
        difference: output.perceptualDifference,
        width: width,
        height: height,
        threshold: Float(threshold))
      : nil
    let masked = Self.maskedGeneratedPixels(
      generated: output.generatedPixels,
      mask: preparation.maskCoverage,
      changeMatte: changeMatte)
    try Task.checkCancellation()
    let encoded = try RasterAssetPayload.encode(
      masked.pixels,
      width: width,
      height: height)
    try Task.checkCancellation()
    return GenerationRenderResult(
      raster: RasterBakeResult(
        reference: encoded.reference,
        compressedPixels: encoded.compressedPixels),
      placementFrame: preparation.placementFrame,
      outsideMaskPixelCount: masked.outsideCount,
      preservedOutsideMaskPixelCount: masked.clearedCount)
  }

  /// Retain only immutable inputs. The layer's visible pixels are derived from
  /// these project assets and its saved threshold whenever it is rendered.
  func makeComfyUIInpaintingLayerAssets(
    _ output: ComfyUIInpaintingOutput
  ) throws -> ComfyUIInpaintingLayerAssets {
    let preparation = output.preparation
    let width = preparation.compositeWidth
    let height = preparation.compositeHeight
    let source = try RasterAssetPayload.encode(
      preparation.originalPixels, width: width, height: height)
    let generated = try RasterAssetPayload.encode(
      output.generatedPixels, width: width, height: height)
    var analysisValues = [Float](repeating: 0, count: width * height * 2)
    for pixel in output.perceptualDifference.indices {
      analysisValues[pixel * 2] = output.perceptualDifference[pixel]
      analysisValues[pixel * 2 + 1] = preparation.maskCoverage[pixel]
    }
    let analysisData = analysisValues.withUnsafeBytes { Data($0) }
    let analysis = try RasterAssetPayload.encode(
      analysisData,
      width: width,
      height: height,
      pixelFormat: RasterAssetReference.inpaintAnalysisPixelFormat,
      colorSpace: "none")
    try Task.checkCancellation()
    return ComfyUIInpaintingLayerAssets(
      source: RasterBakeResult(
        reference: source.reference, compressedPixels: source.compressedPixels),
      generated: RasterBakeResult(
        reference: generated.reference, compressedPixels: generated.compressedPixels),
      analysis: RasterBakeResult(
        reference: analysis.reference, compressedPixels: analysis.compressedPixels))
  }

  func generatedInpaintImage(
    _ inpaint: GeneratedInpaintLayerRecipe,
    assets: [RasterAssetID: Data]
  ) throws -> (image: CIImage, pixels: Data) {
    try Task.checkCancellation()
    let width = inpaint.source.width
    let height = inpaint.source.height
    guard inpaint.generated.width == width, inpaint.generated.height == height,
      inpaint.analysis.width == width, inpaint.analysis.height == height,
      inpaint.source.pixelFormat == "rgba16FloatPremultiplied",
      inpaint.generated.pixelFormat == "rgba16FloatPremultiplied",
      inpaint.analysis.pixelFormat == RasterAssetReference.inpaintAnalysisPixelFormat,
      inpaint.generation.inpainting != nil
    else {
      throw PixeltjeMacError(
        "Inpaint layer invalid", "The saved inpaint inputs do not match their layer recipe.")
    }
    for reference in inpaint.assetReferences {
      guard assets[reference.id] != nil else {
        throw PixeltjeMacError(
          "Inpaint asset missing", "The saved inpaint layer is missing one of its inputs.")
      }
    }
    let key = GeneratedInpaintCache.Key(inpaint)
    let threshold = Float(inpaint.changeThreshold)
    if let cached = generatedInpaintCache.image(for: key, threshold: threshold) {
      return cached
    }

    let decoded: GeneratedInpaintCache.Decoded
    if let cached = generatedInpaintCache.decoded(for: key) {
      decoded = cached
    } else {
      func pixels(_ reference: RasterAssetReference) throws -> Data {
        // Presence was checked above; retain the existing damage/format checks
        // on a cache miss, before any decoded bytes can enter the cache.
        guard let compressed = assets[reference.id] else {
          throw PixeltjeMacError(
            "Inpaint asset missing", "The saved inpaint layer is missing one of its inputs.")
        }
        return try RasterAssetPayload.decode(compressed, reference: reference)
      }
      let generated = try pixels(inpaint.generated)
      try Task.checkCancellation()
      let analysis = try pixels(inpaint.analysis)
      try Task.checkCancellation()
      var difference = [Float](repeating: 0, count: width * height)
      var coverage = [Float](repeating: 0, count: width * height)
      try analysis.withUnsafeBytes { bytes in
        let values = bytes.bindMemory(to: Float.self)
        for pixel in difference.indices {
          let distance = values[pixel * 2]
          let mask = values[pixel * 2 + 1]
          guard (distance >= 0 && (distance.isFinite || distance.isInfinite)),
            mask.isFinite, (0...1).contains(mask)
          else {
            throw PixeltjeMacError("Inpaint asset damaged", "The saved change map is invalid.")
          }
          difference[pixel] = distance
          coverage[pixel] = mask
        }
      }
      try Task.checkCancellation()
      decoded = GeneratedInpaintCache.Decoded(
        generated: generated, difference: difference, coverage: coverage)
      generatedInpaintCache.storeDecoded(decoded, for: key)
    }
    try Task.checkCancellation()
    let matte = threshold > 0
      ? Self.changeMatte(difference: decoded.difference, width: width, height: height,
        threshold: threshold)
      : nil
    try Task.checkCancellation()
    let pixels = Self.maskedGeneratedPixels(
      generated: decoded.generated, mask: decoded.coverage, changeMatte: matte).pixels
    try Task.checkCancellation()
    let image = CIImage(
      bitmapData: pixels,
      bytesPerRow: width * 8,
      size: CGSize(width: width, height: height),
      format: .RGBAh,
      colorSpace: workingColorSpace)
    generatedInpaintCache.storeImage(image, pixels: pixels, for: key, threshold: threshold)
    return (image, pixels)
  }

  /// Generates a complete raster from seeded noise. Blank documents take this
  /// path, so they never construct a fake transparent inpainting source or run
  /// the VAE encoder.
  public func generateTextToImage(
    _ request: TextToImageRenderRequest,
    modelLoadState: @escaping @Sendable (Bool) async -> Void = { _ in },
    preview: @escaping @Sendable (GenerationRenderPreview) async -> Void
  ) async throws -> GenerationRenderResult {
    guard request.canvas.isResolved else {
      throw PixeltjeMacError("Generation unavailable", "The document canvas has no size.")
    }
    let outputWidth = request.recipe.outputWidth ?? request.canvas.width
    let outputHeight = request.recipe.outputHeight ?? request.canvas.height
    let geometry = Self.inpaintingOutputGeometry(
      sourceWidth: request.canvas.width,
      sourceHeight: request.canvas.height,
      outputWidth: outputWidth,
      outputHeight: outputHeight)
    guard let modelResolution = ZImageCoreAIPipeline.ModelResolution(
      width: request.recipe.modelWidth,
      height: request.recipe.modelHeight)
    else {
      throw PixeltjeMacError(
        "Generation size unavailable",
        "The linked Z-Image pipeline cannot generate at \(request.recipe.modelWidth) × \(request.recipe.modelHeight).")
    }
    let needsModelLoad = !(await zImagePipeline.isLoaded(
      from: request.modelPackageURL,
      resolution: modelResolution,
      mode: .textToImage))
    await modelLoadState(needsModelLoad)
    try await zImagePipeline.load(
      from: request.modelPackageURL,
      resolution: modelResolution,
      mode: .textToImage)
    let generatedRGB = try await zImagePipeline.textToImage(
      prompt: request.recipe.prompt,
      negativePrompt: request.recipe.negativePrompt,
      seed: request.recipe.seed,
      steps: request.recipe.steps,
      guidance: Float(request.recipe.guidance),
      resolution: modelResolution
    ) { [geometry, request] step in
      let frame = try await self.makeTextToImagePreview(
        step,
        request: request,
        geometry: geometry)
      await preview(frame)
    }
    try Task.checkCancellation()

    let generated = generatedImage(
      from: generatedRGB,
      modelWidth: modelResolution.width,
      modelHeight: modelResolution.height,
      destination: geometry.outputBounds)
    let pixels = rgba16Pixels(of: generated, in: geometry.outputBounds)
    let encoded = try RasterAssetPayload.encode(
      pixels,
      width: Int(geometry.outputBounds.width),
      height: Int(geometry.outputBounds.height))
    return GenerationRenderResult(
      raster: RasterBakeResult(
        reference: encoded.reference,
        compressedPixels: encoded.compressedPixels),
      placementFrame: geometry.placementFrame,
      outsideMaskPixelCount: 0,
      preservedOutsideMaskPixelCount: 0)
  }

  /// Generates against a frozen displayed frame and shared mask, returning one
  /// complete project raster. No preview enters the document recipe.
  public func generateInpainting(
    _ request: InpaintingRenderRequest,
    modelLoadState: @escaping @Sendable (Bool) async -> Void = { _ in },
    preview: @escaping @Sendable (GenerationRenderPreview) async -> Void
  ) async throws -> GenerationRenderResult {
    let sourceFrame = request.sourceFrame
    guard sourceFrame.width > 0, sourceFrame.height > 0 else {
      throw PixeltjeMacError("Inpainting unavailable", "The displayed image has no pixels.")
    }
    guard sourceFrame.documentID.uuidString == request.recipe.source.documentID,
      sourceFrame.contentRevision == request.recipe.source.contentRevision
    else {
      throw PixeltjeMacError(
        "Source changed",
        "The generation source no longer matches the document revision captured by the recipe.")
    }

    let sourceBounds = CGRect(
      x: 0, y: 0, width: sourceFrame.width, height: sourceFrame.height)
    let source = CIImage(
      ioSurface: sourceFrame.surface,
      options: [.colorSpace: workingColorSpace]
    ).cropped(to: sourceBounds)
    let sourceFocus = request.recipe.usesFullOutputMask == true
      ? nil
      : Self.inpaintingSelectionFocus(request.recipe.mask, in: sourceBounds)
    let geometry = Self.inpaintingOutputGeometry(
      sourceWidth: sourceFrame.width,
      sourceHeight: sourceFrame.height,
      outputWidth: request.recipe.outputWidth ?? sourceFrame.width,
      outputHeight: request.recipe.outputHeight ?? sourceFrame.height,
      sourceFocus: sourceFocus)
    guard let modelResolution = ZImageCoreAIPipeline.ModelResolution(
      width: request.recipe.modelWidth,
      height: request.recipe.modelHeight)
    else {
      throw PixeltjeMacError(
        "Generation size unavailable",
        "The linked Z-Image pipeline cannot generate at \(request.recipe.modelWidth) × \(request.recipe.modelHeight).")
    }
    let outputCanvas = CanvasRecipe(
      width: Int(geometry.outputBounds.width),
      height: Int(geometry.outputBounds.height))
    let sourceCanvas = CanvasRecipe(width: sourceFrame.width, height: sourceFrame.height)
    let sourceForOutput = source
      .transformed(
        by: CGAffineTransform(
          translationX: CGFloat(geometry.sourceOffset.x),
          y: CGFloat(geometry.sourceOffset.y)))
      .composited(over: CIImage(color: .clear).cropped(to: geometry.outputBounds))
      .cropped(to: geometry.outputBounds)
    var featheredMask = request.recipe.usesFullOutputMask == true
      ? MaskRecipe.selectingAll
      : request.recipe.mask.resizingCanvas(
        from: sourceCanvas,
        to: outputCanvas,
        offset: geometry.sourceOffset)
    featheredMask.feather += request.recipe.maskFeatherPixels
    let fullMaskImage = try maskRenderer.evaluate(
      featheredMask,
      in: MaskSpace(extent: geometry.outputBounds, pixelsPerCanvasPixel: 1),
      source: sourceForOutput,
      sourceIdentity:
        "generation:\(sourceFrame.documentID.uuidString):\(sourceFrame.contentRevision):\(outputCanvas.width)x\(outputCanvas.height)"
    )
    guard let fullMaskImage else {
      throw PixeltjeMacError(
        "Inpainting needs a selection",
        "The active selection could not produce mask coverage.")
    }

    let modelBounds = CGRect(
      x: 0,
      y: 0,
      width: modelResolution.width,
      height: modelResolution.height)
    let sourceForModel = sourceForOutput.transformed(
      by: CGAffineTransform(
        scaleX: CGFloat(modelResolution.width) / geometry.outputBounds.width,
        y: CGFloat(modelResolution.height) / geometry.outputBounds.height)
    ).cropped(to: modelBounds)
    let modelMaskImage = try maskRenderer.evaluate(
      featheredMask,
      in: MaskSpace(
        extent: modelBounds,
        pixelsPerCanvasPixel: min(
          CGFloat(modelResolution.width) / geometry.outputBounds.width,
          CGFloat(modelResolution.height) / geometry.outputBounds.height)),
      source: sourceForModel,
      sourceIdentity:
        "generation-model:\(sourceFrame.documentID.uuidString):\(sourceFrame.contentRevision)"
    )
    guard let modelMaskImage else {
      throw PixeltjeMacError("Inpainting needs a selection", "The selection is empty.")
    }

    let sourceRGB = try modelRGB(
      from: sourceForModel,
      in: modelBounds,
      transparentPixelBackground: request.recipe.transparentPixelBackground ?? .black)
    let modelMask = try maskCoverage(from: modelMaskImage, in: modelBounds)
    guard modelMask.contains(where: { $0 > 0 }) else {
      throw PixeltjeMacError("Inpainting needs a selection", "The selection is empty.")
    }
    let needsModelLoad = !(await zImagePipeline.isLoaded(
      from: request.modelPackageURL,
      resolution: modelResolution,
      mode: .inpainting))
    await modelLoadState(needsModelLoad)
    try await zImagePipeline.load(
      from: request.modelPackageURL,
      resolution: modelResolution,
      mode: .inpainting)
    let generatedRGB = try await zImagePipeline.inpaint(
      sourceRGB: sourceRGB,
      mask: modelMask,
      prompt: request.recipe.prompt,
      negativePrompt: request.recipe.negativePrompt,
      seed: request.recipe.seed,
      steps: request.recipe.steps,
      guidance: Float(request.recipe.guidance),
      strength: Float(request.recipe.strength),
      resolution: modelResolution
    ) { [source, sourceForOutput, fullMaskImage, sourceBounds, geometry, sourceFrame]
      (step: ZImageCoreAIPipeline.StepOutput) in
      let rendered = try await self.makeInpaintingPreview(
        step,
        source: source,
        sourceForOutput: sourceForOutput,
        mask: fullMaskImage,
        sourceBounds: sourceBounds,
        geometry: geometry,
        sourceFrame: sourceFrame)
      await preview(rendered)
    }
    try Task.checkCancellation()

    let generated = generatedImage(
      from: generatedRGB,
      modelWidth: modelResolution.width,
      modelHeight: modelResolution.height,
      destination: geometry.outputBounds)
    let originalPixels = rgba16Pixels(of: sourceForOutput, in: geometry.outputBounds)
    let generatedPixels = rgba16Pixels(of: generated, in: geometry.outputBounds)
    let fullMask = try maskCoverage(from: fullMaskImage, in: geometry.outputBounds)
    let composed = Self.compositePixels(
      original: originalPixels,
      generated: generatedPixels,
      mask: fullMask)
    let encoded = try RasterAssetPayload.encode(
      composed.pixels,
      width: Int(geometry.outputBounds.width),
      height: Int(geometry.outputBounds.height))
    return GenerationRenderResult(
      raster: RasterBakeResult(
        reference: encoded.reference,
        compressedPixels: encoded.compressedPixels),
      placementFrame: geometry.placementFrame,
      outsideMaskPixelCount: composed.outsideCount,
      preservedOutsideMaskPixelCount: composed.preservedCount
    )
  }

  private func makeTextToImagePreview(
    _ step: ZImageCoreAIPipeline.StepOutput,
    request: TextToImageRenderRequest,
    geometry: InpaintingOutputGeometry
  ) throws -> GenerationRenderPreview {
    let canvasBounds = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(request.canvas.width),
      height: CGFloat(request.canvas.height))
    let generated = generatedImage(
      from: step.decodedRGB,
      modelWidth: step.width,
      modelHeight: step.height,
      destination: geometry.outputBounds)
      .transformed(
        by: CGAffineTransform(
          translationX: CGFloat(geometry.placementFrame.x),
          y: CGFloat(geometry.placementFrame.y)))
      .composited(over: CIImage(color: .clear).cropped(to: canvasBounds))
      .cropped(to: canvasBounds)
    let surface = try makeSurface(for: canvasBounds)
    processingContext.render(
      generated,
      to: surface,
      bounds: canvasBounds,
      colorSpace: workingColorSpace)
    return GenerationRenderPreview(
      frame: RenderedFrame(
        documentID: request.documentID,
        revision: request.revision,
        contentRevision: request.contentRevision,
        surface: surface,
        activeLayerSamplingSurface: nil,
        sampledActiveLayerID: nil,
        samplingLayerStack: nil,
        width: request.canvas.width,
        height: request.canvas.height,
        isProxy: false,
        inspection: nil,
        rawInspections: [:],
        elapsedSeconds: 0),
      step: step.step,
      totalSteps: step.totalSteps)
  }

  private func makeInpaintingPreview(
    _ step: ZImageCoreAIPipeline.StepOutput,
    source: CIImage,
    sourceForOutput: CIImage,
    mask: CIImage,
    sourceBounds: CGRect,
    geometry: InpaintingOutputGeometry,
    sourceFrame: RenderedFrame
  ) throws -> GenerationRenderPreview {
    let generated = generatedImage(
      from: step.decodedRGB,
      modelWidth: step.width,
      modelHeight: step.height,
      destination: geometry.outputBounds)
    let outputLayer = generated.applyingFilter(
      "CIBlendWithMask",
      parameters: [
        kCIInputBackgroundImageKey: sourceForOutput,
        kCIInputMaskImageKey: maskRenderer.maskImage(from: mask),
      ]
    ).cropped(to: geometry.outputBounds)
    let composited = outputLayer
      .transformed(
        by: CGAffineTransform(
          translationX: CGFloat(geometry.placementFrame.x),
          y: CGFloat(geometry.placementFrame.y)))
      .composited(over: source)
      .cropped(to: sourceBounds)
    let surface = try makeSurface(for: sourceBounds)
    processingContext.render(
      composited, to: surface, bounds: sourceBounds, colorSpace: workingColorSpace)
    return GenerationRenderPreview(
      frame: RenderedFrame(
        documentID: sourceFrame.documentID,
        revision: sourceFrame.revision,
        contentRevision: sourceFrame.contentRevision,
        surface: surface,
        activeLayerSamplingSurface: nil,
        sampledActiveLayerID: nil,
        samplingLayerStack: nil,
        width: sourceFrame.width,
        height: sourceFrame.height,
        isProxy: false,
        inspection: nil,
        rawInspections: [:],
        elapsedSeconds: 0),
      step: step.step,
      totalSteps: step.totalSteps)
  }

  /// Resolves the source region and bounded upload raster for active ComfyUI
  /// inpainting. `maximumWidth`/`maximumHeight` are limits, not a crop that may
  /// discard part of a broad mask.
  static func comfyUIInpaintingGeometry(
    sourceWidth: Int,
    sourceHeight: Int,
    maximumWidth: Int,
    maximumHeight: Int,
    maskBounds: LayerFrame?,
    usesFullOutputMask: Bool,
    alignment: Int
  ) -> ComfyUIInpaintingGeometry {
    let safeSourceWidth = max(sourceWidth, 1)
    let safeSourceHeight = max(sourceHeight, 1)
    let safeMaximumWidth = max(maximumWidth, 1)
    let safeMaximumHeight = max(maximumHeight, 1)
    let safeAlignment = max(alignment, 1)
    let needsWholeSource = usesFullOutputMask
      || (maskBounds?.width ?? 0) > Double(safeMaximumWidth)
      || (maskBounds?.height ?? 0) > Double(safeMaximumHeight)

    if needsWholeSource {
      let scale = min(
        Double(safeMaximumWidth) / Double(safeSourceWidth),
        Double(safeMaximumHeight) / Double(safeSourceHeight))
      func aligned(_ value: Double, maximum: Int) -> Int {
        let roundedDown = Int(value.rounded(.down)) / safeAlignment * safeAlignment
        return min(max(roundedDown, safeAlignment), maximum)
      }
      let uploadWidth = aligned(
        Double(safeSourceWidth) * scale, maximum: safeMaximumWidth)
      let uploadHeight = aligned(
        Double(safeSourceHeight) * scale, maximum: safeMaximumHeight)
      return ComfyUIInpaintingGeometry(
        uploadBounds: CGRect(x: 0, y: 0, width: uploadWidth, height: uploadHeight),
        placementFrame: LayerFrame(
          x: 0,
          y: 0,
          width: Double(safeSourceWidth),
          height: Double(safeSourceHeight)))
    }

    let focus = maskBounds.map {
      CanvasOffset(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2)
    }
    let focused = inpaintingOutputGeometry(
      sourceWidth: safeSourceWidth,
      sourceHeight: safeSourceHeight,
      outputWidth: safeMaximumWidth,
      outputHeight: safeMaximumHeight,
      sourceFocus: focus)
    return ComfyUIInpaintingGeometry(
      uploadBounds: focused.outputBounds,
      placementFrame: focused.placementFrame)
  }

  static func inpaintingOutputGeometry(
    sourceWidth: Int,
    sourceHeight: Int,
    outputWidth: Int,
    outputHeight: Int,
    sourceFocus: CanvasOffset? = nil
  ) -> InpaintingOutputGeometry {
    let outputCanvas = CanvasRecipe(width: max(outputWidth, 1), height: max(outputHeight, 1))
    func placementOrigin(source: Int, output: Int, focus: Double?) -> Double {
      guard output < source else { return -Double(output - source) / 2 }
      let center = focus ?? Double(source) / 2
      return min(max(center - Double(output) / 2, 0), Double(source - output))
    }
    let placementX = placementOrigin(
      source: sourceWidth,
      output: outputCanvas.width,
      focus: sourceFocus?.x)
    let placementY = placementOrigin(
      source: sourceHeight,
      output: outputCanvas.height,
      focus: sourceFocus?.y)
    let offset = CanvasOffset(x: -placementX, y: -placementY)
    return InpaintingOutputGeometry(
      outputBounds: CGRect(
        x: 0,
        y: 0,
        width: CGFloat(outputCanvas.width),
        height: CGFloat(outputCanvas.height)),
      sourceOffset: offset,
      placementFrame: LayerFrame(
        x: -offset.x,
        y: -offset.y,
        width: Double(outputCanvas.width),
        height: Double(outputCanvas.height)))
  }

  /// Selection tools store normalized vector geometry. Its effective path is
  /// enough to decide whether a bounded patch can contain the complete mask,
  /// and to place that patch without allocating a full-resolution bitmap.
  static func inpaintingSelectionBounds(
    _ mask: MaskRecipe,
    in sourceBounds: CGRect
  ) -> LayerFrame? {
    guard let path = SelectionGeometry.path(for: mask, in: sourceBounds) else { return nil }
    let bounds = path.boundingBoxOfPath.intersection(sourceBounds)
    guard !bounds.isNull, !bounds.isEmpty else { return nil }
    return LayerFrame(
      x: bounds.minX,
      y: bounds.minY,
      width: bounds.width,
      height: bounds.height)
  }

  static func inpaintingSelectionFocus(
    _ mask: MaskRecipe,
    in sourceBounds: CGRect
  ) -> CanvasOffset? {
    inpaintingSelectionBounds(mask, in: sourceBounds).map {
      CanvasOffset(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2)
    }
  }

  private func modelRGB(
    from image: CIImage,
    in bounds: CGRect,
    transparentPixelBackground: GenerationBackground
  ) throws -> [Float] {
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    var interleaved = [Float](repeating: 0, count: width * height * 4)
    let modelColorSpace =
      CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    interleaved.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      processingContext.render(
        image,
        toBitmap: base,
        rowBytes: width * MemoryLayout<Float>.size * 4,
        bounds: bounds,
        format: .RGBAf,
        colorSpace: modelColorSpace)
    }
    var planar = [Float](repeating: 0, count: width * height * 3)
    let plane = width * height
    for pixel in 0..<plane {
      let alpha = min(max(interleaved[pixel * 4 + 3], 0), 1)
      planar[pixel] = Self.modelInputValue(
        premultipliedSource: interleaved[pixel * 4],
        alpha: alpha,
        transparentPixelBackground: transparentPixelBackground)
      planar[plane + pixel] = Self.modelInputValue(
        premultipliedSource: interleaved[pixel * 4 + 1],
        alpha: alpha,
        transparentPixelBackground: transparentPixelBackground)
      planar[plane * 2 + pixel] = Self.modelInputValue(
        premultipliedSource: interleaved[pixel * 4 + 2],
        alpha: alpha,
        transparentPixelBackground: transparentPixelBackground)
    }
    return planar
  }

  static func modelInputValue(
    premultipliedSource: Float,
    alpha: Float,
    transparentPixelBackground: GenerationBackground
  ) -> Float {
    let background: Float =
      switch transparentPixelBackground {
      case .white: 1
      case .gray: 0.5
      case .black: 0
      }
    let clampedAlpha = min(max(alpha, 0), 1)
    let composited = min(
      max(premultipliedSource + background * (1 - clampedAlpha), 0), 1)
    return composited * 2 - 1
  }

  func maskCoverage(from image: CIImage, in bounds: CGRect) throws -> [Float] {
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      processingContext.render(
        image,
        toBitmap: base,
        rowBytes: width * MemoryLayout<Float>.size * 4,
        bounds: bounds,
        format: .RGBAf,
        colorSpace: workingColorSpace)
    }
    return stride(from: 0, to: rgba.count, by: 4).map {
      min(max(rgba[$0], 0), 1)
    }
  }

  /// Converts the frozen composite alpha into ordinary editor coverage:
  /// transparent pixels are editable, opaque pixels are protected, and soft
  /// source edges retain their fractional alpha as a soft inpainting mask.
  private func sourceTransparencyMask(from image: CIImage, in bounds: CGRect) -> CIImage {
    image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: -1),
        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: -1),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: -1),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
      ]
    ).cropped(to: bounds)
  }

  /// Converts nonzero rows from Core Image's top-down bitmap storage into the
  /// bottom-left coordinate system used by CIImage transforms and crops.
  nonisolated static func nonzeroMaskBounds(
    _ coverage: [Float], width: Int, height: Int
  ) -> LayerFrame? {
    guard width > 0, height > 0, coverage.count == width * height else { return nil }
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
      for x in 0..<width where coverage[y * width + x] > 0 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return LayerFrame(
      x: Double(minX),
      y: Double(height - (maxY + 1)),
      width: Double(maxX - minX + 1),
      height: Double(maxY - minY + 1))
  }

  /// Reconstitutes actor-owned frozen coverage as an opaque linear image.
  /// Alpha stays one so a soft mask value is not premultiplied a second time.
  private func coverageImage(from capture: InpaintingMaskRenderResult) -> CIImage {
    var rgba = [Float](repeating: 1, count: capture.coverage.count * 4)
    for pixel in capture.coverage.indices {
      let value = min(max(capture.coverage[pixel], 0), 1)
      rgba[pixel * 4] = value
      rgba[pixel * 4 + 1] = value
      rgba[pixel * 4 + 2] = value
    }
    let data = rgba.withUnsafeBytes { Data($0) }
    return CIImage(
      bitmapData: data,
      bytesPerRow: capture.width * MemoryLayout<Float>.size * 4,
      size: CGSize(width: capture.width, height: capture.height),
      format: .RGBAf,
      colorSpace: workingColorSpace)
  }

  private func generatedImage(
    from planarRGB: [Float],
    modelWidth: Int,
    modelHeight: Int,
    destination: CGRect
  ) -> CIImage {
    let plane = modelWidth * modelHeight
    precondition(planarRGB.count == plane * 3)
    var interleaved = [Float](repeating: 1, count: plane * 4)
    for pixel in 0..<plane {
      interleaved[pixel * 4] = min(max((planarRGB[pixel] + 1) / 2, 0), 1)
      interleaved[pixel * 4 + 1] = min(max((planarRGB[plane + pixel] + 1) / 2, 0), 1)
      interleaved[pixel * 4 + 2] = min(max((planarRGB[plane * 2 + pixel] + 1) / 2, 0), 1)
    }
    let data = interleaved.withUnsafeBytes { Data($0) }
    let modelColorSpace =
      CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    return CIImage(
      bitmapData: data,
      bytesPerRow: modelWidth * MemoryLayout<Float>.size * 4,
      size: CGSize(width: modelWidth, height: modelHeight),
      format: .RGBAf,
      colorSpace: modelColorSpace
    ).transformed(
      by: CGAffineTransform(
        scaleX: destination.width / CGFloat(modelWidth),
        y: destination.height / CGFloat(modelHeight))
    ).cropped(to: destination)
  }

  private func rgba16Pixels(of image: CIImage, in bounds: CGRect) -> Data {
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    var pixels = Data(count: width * height * 8)
    pixels.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      processingContext.render(
        image,
        toBitmap: base,
        rowBytes: width * 8,
        bounds: bounds,
        format: .RGBAh,
        colorSpace: workingColorSpace)
    }
    return pixels
  }

  private func srgb8Pixels(of image: CIImage, in bounds: CGRect) -> [UInt8] {
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    pixels.withUnsafeMutableBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      processingContext.render(
        image, toBitmap: base, rowBytes: width * 4,
        bounds: bounds, format: .RGBA8, colorSpace: srgb)
    }
    return pixels
  }

  /// Compare in the display-referred sRGB space actually sent to the model,
  /// not against unclipped linear-P3 source pixels. Oklab receives linearized
  /// sRGB and yields one perceptual distance per output pixel.
  static func perceptualDifference(
    uploaded: [UInt8], returned: [UInt8], original: Data
  ) -> [Float] {
    precondition(uploaded.count == returned.count)
    precondition(original.count == uploaded.count * 2)
    var distance = [Float](repeating: 0, count: uploaded.count / 4)
    original.withUnsafeBytes { originalBytes in
      let source = originalBytes.bindMemory(to: Float16.self)
      for pixel in distance.indices {
        let base = pixel * 4
        // The uploaded image was flattened behind a temporary background.
        // Revealing a transparent source pixel is meaningful even if its new
        // RGB happens to match that background.
        if Float(source[base + 3]) < 0.999 || returned[base + 3] < 254 {
          distance[pixel] = .infinity
          continue
        }
        let before = oklab(
          uploaded[base], uploaded[base + 1], uploaded[base + 2])
        let after = oklab(
          returned[base], returned[base + 1], returned[base + 2])
        let dl = before.0 - after.0
        let da = before.1 - after.1
        let db = before.2 - after.2
        distance[pixel] = 100 * (dl * dl + da * da + db * db).squareRoot()
      }
    }
    return distance
  }

  private static func oklab(_ red: UInt8, _ green: UInt8, _ blue: UInt8)
    -> (Float, Float, Float)
  {
    func linear(_ component: UInt8) -> Float {
      let value = Float(component) / 255
      return value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }
    let r = linear(red)
    let g = linear(green)
    let b = linear(blue)
    let l = cbrtf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrtf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrtf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
  }

  /// A soft perceptual cutoff with a two-pixel spatial halo. The original
  /// matte remains at full strength for definite edits, including tiny ones.
  static func changeMatte(
    difference: [Float], width: Int, height: Int, threshold: Float
  ) -> [Float] {
    precondition(difference.count == width * height)
    guard threshold > 0 else { return [Float](repeating: 1, count: difference.count) }
    // The distance is already on a 0–100 perceptual scale. Keep the slider
    // on that same scale so its upper range can suppress ordinary model drift.
    let cutoff = min(max(threshold, 0), 100)
    let halfWidth = max(0.5, cutoff * 0.2)
    let low = max(0, cutoff - halfWidth)
    let high = cutoff + halfWidth
    var core = difference.map { value -> Float in
      guard value.isFinite else { return 1 }
      let position = min(max((value - low) / (high - low), 0), 1)
      return position * position * (3 - 2 * position)
    }
    let weights: [Float] = [1, 4, 6, 4, 1]
    var horizontal = [Float](repeating: 0, count: core.count)
    for y in 0..<height {
      for x in 0..<width {
        var sum: Float = 0
        for tap in -2...2 {
          let sampleX = min(max(x + tap, 0), width - 1)
          sum += core[y * width + sampleX] * weights[tap + 2]
        }
        horizontal[y * width + x] = sum / 16
      }
    }
    for y in 0..<height {
      for x in 0..<width {
        var sum: Float = 0
        for tap in -2...2 {
          let sampleY = min(max(y + tap, 0), height - 1)
          sum += horizontal[sampleY * width + x] * weights[tap + 2]
        }
        let index = y * width + x
        core[index] = max(core[index], sum / 16)
      }
    }
    return core
  }

  /// Byte-identical copying outside the final feathered mask is deliberate.
  /// Half-float arithmetic occurs only where coverage is greater than zero.
  static func compositePixels(
    original: Data,
    generated: Data,
    mask: [Float],
    changeMatte: [Float]? = nil
  ) -> (pixels: Data, outsideCount: Int, preservedCount: Int) {
    precondition(original.count == generated.count)
    precondition(original.count == mask.count * 8)
    precondition(changeMatte == nil || changeMatte?.count == mask.count)
    var result = original
    var outsideCount = 0
    var preservedCount = 0
    result.withUnsafeMutableBytes { resultBytes in
      original.withUnsafeBytes { originalBytes in
        generated.withUnsafeBytes { generatedBytes in
          let destination = resultBytes.bindMemory(to: Float16.self)
          let source = originalBytes.bindMemory(to: Float16.self)
          let replacement = generatedBytes.bindMemory(to: Float16.self)
          for pixel in mask.indices {
            let selectionCoverage = min(max(mask[pixel], 0), 1)
            let coverage = selectionCoverage
              * min(max(changeMatte?[pixel] ?? 1, 0), 1)
            let base = pixel * 4
            if coverage <= 0 {
              if selectionCoverage <= 0 { outsideCount += 1 }
              var matches = true
              for channel in 0..<4 {
                matches = matches && destination[base + channel] == source[base + channel]
              }
              if matches && selectionCoverage <= 0 { preservedCount += 1 }
              continue
            }
            for channel in 0..<4 {
              let value =
                Float(source[base + channel]) * (1 - coverage)
                + Float(replacement[base + channel]) * coverage
              destination[base + channel] = Float16(value)
            }
          }
        }
      }
    }
    return (result, outsideCount, preservedCount)
  }

  /// Turns a complete ComfyUI response into an ordinary premultiplied layer.
  /// The existing document remains the sole source of pixels outside the
  /// frozen inpainting mask; threshold-suppressed pixels are transparent too.
  static func maskedGeneratedPixels(
    generated: Data,
    mask: [Float],
    changeMatte: [Float]? = nil
  ) -> (pixels: Data, outsideCount: Int, clearedCount: Int) {
    precondition(generated.count == mask.count * 8)
    precondition(changeMatte == nil || changeMatte?.count == mask.count)
    var result = Data(count: generated.count)
    var outsideCount = 0
    var clearedCount = 0
    result.withUnsafeMutableBytes { resultBytes in
      generated.withUnsafeBytes { generatedBytes in
        let destination = resultBytes.bindMemory(to: Float16.self)
        let replacement = generatedBytes.bindMemory(to: Float16.self)
        for pixel in mask.indices {
          let selectionCoverage = min(max(mask[pixel], 0), 1)
          let coverage = selectionCoverage
            * min(max(changeMatte?[pixel] ?? 1, 0), 1)
          let base = pixel * 4
          if selectionCoverage <= 0 {
            outsideCount += 1
            clearedCount += 1
          }
          guard coverage > 0 else { continue }
          for channel in 0..<4 {
            destination[base + channel] = Float16(Float(replacement[base + channel]) * coverage)
          }
        }
      }
    }
    return (result, outsideCount, clearedCount)
  }
}

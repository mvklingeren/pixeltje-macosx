import CoreImage
import CoreVideo
import Foundation
import IOSurface
import ImageIO
import Metal
import OSLog
import PixeltjeMacDomain
import PixeltjePipelineEngine
import Vision

public struct RenderRequest: Sendable {
  public var documentID: UUID
  public var revision: UInt64
  public var contentRevision: UInt64
  /// The linked RAW inputs keyed by their owning layer. A canvas document
  /// renders from placed images alone; a RAW composite can develop several
  /// sources independently in one request.
  public var rawInputs: [ProjectLayerID: RawInput]
  /// Losslessly compressed project-local raster payloads keyed by their
  /// content identity. External image links remain separate in the recipe.
  public var rasterAssets: [RasterAssetID: Data]
  /// Compatibility view of the original RAW background input. New code uses
  /// `rawInputs`; retaining this preserves callers constructing old requests.
  public var input: RawInput?
  public var recipe: ProjectRecipe
  public var quality: RenderQuality
  /// Session-only canvas inspection. Export and source-capture requests leave it nil.
  public var differencePreviewLayerID: ProjectLayerID?

  public init(
    documentID: UUID,
    revision: UInt64,
    contentRevision: UInt64 = 0,
    input: RawInput?,
    rasterAssets: [RasterAssetID: Data] = [:],
    recipe: ProjectRecipe,
    quality: RenderQuality
  ) {
    self.documentID = documentID
    self.revision = revision
    self.contentRevision = contentRevision
    self.input = input
    self.rawInputs = input.map { [.rawBackground: $0] } ?? [:]
    self.rasterAssets = rasterAssets
    self.recipe = recipe
    self.quality = quality
    self.differencePreviewLayerID = nil
  }

  public init(
    documentID: UUID,
    revision: UInt64,
    contentRevision: UInt64 = 0,
    rawInputs: [ProjectLayerID: RawInput],
    rasterAssets: [RasterAssetID: Data] = [:],
    recipe: ProjectRecipe,
    quality: RenderQuality
  ) {
    self.documentID = documentID
    self.revision = revision
    self.contentRevision = contentRevision
    self.rawInputs = rawInputs
    self.rasterAssets = rasterAssets
    self.input = rawInputs[.rawBackground]
    self.recipe = recipe
    self.quality = quality
    self.differencePreviewLayerID = nil
  }
}

/// Transient pipeline inputs captured together from one immutable document
/// render request. The caller must discard a result whose revision is stale.
public struct PipelineHostInputSnapshot: Sendable {
  public let documentID: UUID
  public let revision: UInt64
  public let contentRevision: UInt64
  public let invocation: PipelineInvocation
}

/// One project-local raster produced by a full-quality layer bake.
public struct RasterBakeResult: Sendable {
  public var reference: RasterAssetReference
  public var compressedPixels: Data

  public init(reference: RasterAssetReference, compressedPixels: Data) {
    self.reference = reference
    self.compressedPixels = compressedPixels
  }
}

/// One baked region in both the flavours a copy needs: the project's own
/// lossless pixels, and a PNG the rest of the system can read.
///
/// Both come out of a single render. Rendering twice to produce two encodings
/// of the same picture would be the same work done twice and could, with a
/// document edit in between, produce two pictures.
public struct SelectionBakeResult: Sendable {
  public var raster: RasterBakeResult
  public var png: Data
  /// Where the pixels came from, in canvas pixels.
  public var bounds: CGRect

  public init(raster: RasterBakeResult, png: Data, bounds: CGRect) {
    self.raster = raster
    self.png = png
    self.bounds = bounds
  }
}

public struct RenderedFrame: Sendable {
  public let documentID: UUID
  public let revision: UInt64
  public let contentRevision: UInt64
  public let surface: IOSurface
  /// Optional canvas-only matte view. Content operations use `surface`.
  public var differencePreviewSurface: IOSurface? = nil
  /// The selected layer rendered against transparency under the Active Layer
  /// sampling contract. It is revision-tagged by travelling with this frame.
  public let activeLayerSamplingSurface: IOSurface?
  public let sampledActiveLayerID: ProjectLayerID?
  /// The immutable recipe needed to draw a picker-sized vector region on
  /// demand. Value semantics keep this tied to the same revision as `surface`.
  public let samplingLayerStack: LayerStack?
  public let width: Int
  public let height: Int
  public let isProxy: Bool
  /// What the RAW decoder reported, or `nil` when no RAW was developed.
  /// This is the original RAW background's inspection when one exists, kept
  /// for crop and legacy callers. Use `rawInspections` for every RAW layer.
  public let inspection: RawInspection?
  public let rawInspections: [ProjectLayerID: RawInspection]
  public let elapsedSeconds: Double
}

/// Statistical information derived after a frame is ready to display.
///
/// Analysis deliberately travels separately from `RenderedFrame`: making the
/// canvas wait for a bounded readback made a completed RAW look as though it
/// was still rendering. The same identity fields keep the old guarantee that
/// results can only be attached to the exact frame they describe.
public struct RenderedFrameAnalysis: Sendable {
  public let documentID: UUID
  public let revision: UInt64
  public let contentRevision: UInt64
  public let histogram: ImageHistogram?
  /// Empty on a proxy frame, which is not authoritative palette input.
  public let palette: [PaletteColor]
  public let contentTags: [ImageContentTag]
  public let isProxy: Bool

  public init(
    documentID: UUID,
    revision: UInt64,
    contentRevision: UInt64,
    histogram: ImageHistogram?,
    palette: [PaletteColor],
    contentTags: [ImageContentTag] = [],
    isProxy: Bool
  ) {
    self.documentID = documentID
    self.revision = revision
    self.contentRevision = contentRevision
    self.histogram = histogram
    self.palette = palette
    self.contentTags = contentTags
    self.isProxy = isProxy
  }
}

public enum ImageContentTagSource: Equatable, Sendable {
  case vision
  case foundationModel
}

public struct ImageContentTag: Identifiable, Equatable, Sendable {
  public let id: String
  public let isRecommended: Bool
  public let source: ImageContentTagSource

  public init(
    id: String,
    isRecommended: Bool,
    source: ImageContentTagSource = .vision
  ) {
    self.id = id
    self.isRecommended = isRecommended
    self.source = source
  }

  public var label: String { id.replacingOccurrences(of: "_", with: " ") }
}

/// Owns the context used for bounded readbacks, independently of the render
/// actor. Histogram and palette work therefore cannot hold up the next edit's
/// render after the current surface has already been handed to the canvas.
private actor RenderedFrameAnalyzer {
  private let context: CIContext
  private let workingColorSpace: CGColorSpace
  private let displayReferredColorSpace: CGColorSpace

  init(device: any MTLDevice) throws {
    guard
      let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
      let displayReferredColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
    else {
      throw PixeltjeMacError(
        "Color space unavailable",
        "The required Extended Linear Display P3 color space is unavailable."
      )
    }
    self.workingColorSpace = workingColorSpace
    self.displayReferredColorSpace = displayReferredColorSpace
    self.context = CIContext(
      mtlDevice: device,
      options: [
        .workingColorSpace: workingColorSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
      ]
    )
  }

  func analyze(_ frame: RenderedFrame) throws -> RenderedFrameAnalysis {
    try Task.checkCancellation()
    let image = CIImage(
      ioSurface: frame.surface,
      options: [.colorSpace: workingColorSpace]
    )
    let histogram = ImageHistogram.measure(
      image,
      context: context,
      displayColorSpace: displayReferredColorSpace,
      maximumSampleEdge: frame.isProxy ? 512 : 1024
    )
    try Task.checkCancellation()
    let palette =
      frame.isProxy
      ? []
      : SampledPalette.sample(
        image,
        context: context,
        displayColorSpace: displayReferredColorSpace
      )
    try Task.checkCancellation()
    let contentTags = frame.isProxy ? [] : classifyContent(in: image, frame: frame)
    try Task.checkCancellation()
    return RenderedFrameAnalysis(
      documentID: frame.documentID,
      revision: frame.revision,
      contentRevision: frame.contentRevision,
      histogram: histogram,
      palette: palette,
      contentTags: contentTags,
      isProxy: frame.isProxy
    )
  }

  private func classifyContent(in image: CIImage, frame: RenderedFrame) -> [ImageContentTag] {
    let maximumEdge: CGFloat = 1024
    let scale = min(1, maximumEdge / CGFloat(max(frame.width, frame.height)))
    let extent = CGRect(
      x: 0, y: 0,
      width: max(1, Int((CGFloat(frame.width) * scale).rounded())),
      height: max(1, Int((CGFloat(frame.height) * scale).rounded())))
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .cropped(to: extent)
      .composited(over: CIImage(color: .white).cropped(to: extent))
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let cgImage = context.createCGImage(
      scaled, from: extent, format: .RGBA8, colorSpace: sRGB)
    else { return [] }
    let request = VNClassifyImageRequest()
    do {
      try VNImageRequestHandler(cgImage: cgImage).perform([request])
    } catch {
      // Tags are suggestions. A Vision failure must not suppress the histogram
      // or prevent the document from becoming ready to edit.
      return []
    }
    return (request.results ?? []).prefix(64).map { observation in
      ImageContentTag(
        id: observation.identifier,
        isRecommended: observation.hasMinimumRecall(0.01, forPrecision: 0.9))
    }
  }

  func clearCaches() {
    context.clearCaches()
  }
}

public actor RenderEngine {
  private let logger = Logger(subsystem: "org.pixeltje.PixeltjeMacApp", category: "render")
  let device: any MTLDevice
  /// Core AI inference is encoded onto the render path's Metal queue.
  let coreAICommandQueue: any MTLCommandQueue
  private let rawContext: CIContext
  let processingContext: CIContext
  private let differenceSignalKernel: CIColorKernel?
  private let differenceThresholdKernel: CIColorKernel?
  private static let differenceSignalSource = """
    vec3 keyOklab(vec3 p3) {
      vec3 rgb = max(vec3(
        1.2249401 * p3.r - 0.2249401 * p3.g,
        -0.0420569 * p3.r + 1.0420569 * p3.g,
        -0.0196376 * p3.r - 0.0786361 * p3.g + 1.0982735 * p3.b), vec3(0.0));
      vec3 lms = vec3(
        0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b,
        0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b,
        0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b);
      lms = pow(max(lms, vec3(0.0)), vec3(0.3333333333));
      return vec3(
        0.2104542553 * lms.r + 0.7936177850 * lms.g - 0.0040720468 * lms.b,
        1.9779984951 * lms.r - 2.4285922050 * lms.g + 0.4505937099 * lms.b,
        0.0259040371 * lms.r + 0.7827717662 * lms.g - 0.8086757660 * lms.b);
    }
    kernel vec4 differenceSignal(
      __sample front, __sample back, __sample frontLow, __sample backLow,
      float structure, float drift) {
      if (front.a < 0.0001) return vec4(0.0, 0.0, 0.0, 1.0);
      if (back.a < 0.0001) return vec4(1.0, 1.0, 1.0, 1.0);
      float color = length(keyOklab(front.rgb) - keyOklab(back.rgb));
      float broad = length(keyOklab(frontLow.rgb) - keyOklab(backLow.rgb));
      float detail = length((front.rgb - frontLow.rgb) - (back.rgb - backLow.rgb));
      float score = max(0.0, color - drift * broad * 0.85);
      score = score * (1.0 - 0.35 * structure) + detail * structure * 0.6;
      return vec4(score, score, score, 1.0);
    }
    """
  private static let differenceThresholdSource = """
    kernel vec4 differenceThreshold(__sample signal, float cutoff, float softness) {
      float score = signal.r;
      float matte;
      if (softness <= 0.0) {
        matte = score > cutoff ? 1.0 : 0.0;
      } else {
        float low = max(0.0, cutoff - softness * 0.5);
        float width = max(cutoff + softness * 0.5 - low, 0.001);
        float x = clamp((score - low) / width, 0.0, 1.0);
        matte = x * x * (3.0 - 2.0 * x);
      }
      return vec4(matte, matte, matte, 1.0);
    }
    """
  private let frameAnalyzer: RenderedFrameAnalyzer
  private let imageSubjectTagger: ImageSubjectTagger?
  /// Internal rather than private: the heal solve lives in its own file and
  /// needs the same stroke-surface renderer to evaluate a heal's coverage.
  let brushRenderer: BrushMetalRenderer
  let workingColorSpace: CGColorSpace
  /// The display-referred space the histogram and the palette are read in.
  /// See `ImageHistogram` for why it is not the linear working space.
  private let displayReferredColorSpace: CGColorSpace
  /// Resolves mask recipes to coverage images. It lives inside this actor, so
  /// its Vision requests never run on the main actor.
  let maskRenderer: MaskRenderer
  let zImagePipeline: ZImageCoreAIPipeline

  private struct ImageLayerCacheEntry {
    var fingerprint: SourceFingerprint
    var image: CIImage
  }

  private struct RasterLayerCacheEntry {
    var reference: RasterAssetReference
    /// `CIImage(bitmapData:)` is lazy; retain the decompressed storage beside it.
    var pixels: Data
    var image: CIImage
  }

  private struct RawCache {
    var input: RawInput
    var byteLength: UInt64?
    var modificationDate: Date?
    var requestedDecoder: String?
    var session: RawCoreImage
    var quality: RenderQuality
    var parameters: RawParameters?
    var image: CIImage?

    func matchesSource(_ input: RawInput, source: SourceReference?) -> Bool {
      input == self.input
        && byteLength == source?.fingerprint.byteLength
        && modificationDate == source?.fingerprint.modificationDate
    }

    func matchesDecoder(_ decoder: String?) -> Bool {
      decoder.map { $0 == session.inspection.selectedDecoderVersion } ?? (requestedDecoder == nil)
    }
  }

  // Each quality retains at most a small working set of complete developed
  // surfaces. A full RAW can be very large, so unlimited per-layer caches turn
  // a multi-RAW document into a memory-pressure machine.
  private let observesMemoryPressure: Bool
  private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
  private static let maximumCachedRawLayers = 4
  private var proxyCache: [ProjectLayerID: RawCache] = [:]
  private var fullCache: [ProjectLayerID: RawCache] = [:]
  private var imageLayerCache: [String: ImageLayerCacheEntry] = [:]
  private var rasterLayerCache: [RasterAssetID: RasterLayerCacheEntry] = [:]
  var generatedInpaintCache = GeneratedInpaintCache()
  private(set) var rawSessionCount = 0
  private(set) var rawDevelopmentCount = 0
  private(set) var rawCacheHitCount = 0

  /// Actor-confined side channel used while the ordinary compositor walks a
  /// layer tree. It records the selected mask before content alpha,
  /// compositing opacity, blend mode, and unrelated masks can narrow it, then
  /// follows the same crop and spatial transforms as its owner.
  private final class InpaintingMaskCaptureContext {
    enum Kind: Equatable {
      case layerMask
      case localMask
    }

    let layerID: ProjectLayerID
    let maskID: MaskID
    let kind: Kind
    let transformPath: Set<ProjectLayerID>
    var coverage: CIImage?

    init(
      layerID: ProjectLayerID,
      maskID: MaskID,
      kind: Kind,
      transformPath: Set<ProjectLayerID>
    ) {
      self.layerID = layerID
      self.maskID = maskID
      self.kind = kind
      self.transformPath = transformPath
    }

    func capturesLocalMask(_ mask: MaskRecipe, on layer: ProjectLayer) -> Bool {
      kind == .localMask && layer.id == layerID && mask.id == maskID
    }

    func capturesLayerMask(_ mask: MaskRecipe, on layer: ProjectLayer) -> Bool {
      kind == .layerMask && layer.id == layerID && mask.id == maskID
    }
  }

  private final class DifferenceKeyPreviewCapture {
    let layerID: ProjectLayerID
    var image: CIImage?

    init(layerID: ProjectLayerID) { self.layerID = layerID }
  }

  isolated deinit { memoryPressureSource?.cancel() }

  func hasCachedFullResolution(_ request: RenderRequest) -> Bool {
    let rawLayers = request.recipe.layerStack.flattenedLayers.compactMap { entry in
      entry.isEffectivelyEnabled ? entry.layer.developedRawLayer.map { (entry.id, $0) } : nil
    }
    guard !rawLayers.isEmpty else { return false }
    return rawLayers.allSatisfy { id, raw in
      let input =
        request.rawInputs[id]
        ?? (request.rawInputs.count == 1 ? request.input : nil)
      guard let input, let entry = fullCache[id] else { return false }
      return entry.matchesSource(input, source: raw.source)
        && entry.image != nil
        && entry.matchesDecoder(raw.rawDevelopment.decoderVersion)
        && entry.parameters == (raw.rawDevelopment.parameters ?? entry.session.inspection.defaults)
    }
  }

  func clearCaches() async {
    proxyCache = [:]
    fullCache = [:]
    imageLayerCache = [:]
    rasterLayerCache = [:]
    generatedInpaintCache.clear()
    maskRenderer.clearCaches()
    brushRenderer.clearCaches()
    rawContext.clearCaches()
    processingContext.clearCaches()
    await frameAnalyzer.clearCaches()
    await imageSubjectTagger?.clearCaches()
  }

  private func developedRaw(
    layerID: ProjectLayerID,
    raw: DevelopedRawLayer,
    input: RawInput,
    quality: RenderQuality
  ) async throws -> (CIImage, RawInspection) {
    var cache = quality.isProxy ? proxyCache : fullCache
    var cached = cache[layerID]
    let decoder = raw.rawDevelopment.decoderVersion
    if cached?.matchesSource(input, source: raw.source) != true
      || cached?.matchesDecoder(decoder) != true
    {
      cached = nil
    }
    if cached == nil {
      let session = try await RawCoreImage.create(
        input: input, recipe: raw.rawDevelopment)
      try Task.checkCancellation()
      rawSessionCount += 1
      cached = RawCache(
        input: input,
        byteLength: raw.source?.fingerprint.byteLength,
        modificationDate: raw.source?.fingerprint.modificationDate,
        requestedDecoder: decoder, session: session, quality: quality)
    }
    var entry = cached!
    let parameters = raw.rawDevelopment.parameters ?? entry.session.inspection.defaults
    if entry.parameters == parameters, entry.quality == quality, let image = entry.image {
      rawCacheHitCount += 1
      return (image, entry.session.inspection)
    }
    try Task.checkCancellation()
    let prepared = try entry.session.prepare(parameters: parameters, quality: quality)
    let rawImage = normalized(prepared.image)
    let surface = try makeSurface(for: rawImage.extent)
    // CIRAWFilter returns a lazy graph. It must execute in Core Image's documented
    // Extended Linear sRGB working space; evaluating it in Extended Linear Display
    // P3 changes RawCamera's filter-kernel results and produces a cyan, oversaturated
    // image. The destination color space performs the actual conversion to the
    // downstream Extended Linear Display P3 representation.
    rawContext.render(
      rawImage,
      to: surface,
      bounds: rawImage.extent,
      colorSpace: workingColorSpace
    )
    rawDevelopmentCount += 1
    let image = CIImage(ioSurface: surface, options: [.colorSpace: workingColorSpace])
    entry.parameters = parameters
    entry.quality = quality
    entry.image = image
    cache[layerID] = entry
    if cache.count > Self.maximumCachedRawLayers {
      // The active entry stays resident; otherwise the bounded cache may evict
      // any older peer. Memory pressure still clears all entries immediately.
      // This bounds complete RAW IOSurfaces per quality without growing with
      // the layer stack.
      cache.removeValue(forKey: cache.keys.first { $0 != layerID } ?? layerID)
    }
    if quality.isProxy { proxyCache = cache } else { fullCache = cache }
    try Task.checkCancellation()
    return (image, entry.session.inspection)
  }

  // Tests can isolate cache reuse from unrelated system memory-pressure events.
  // Normal app instances always observe memory pressure and release their caches.
  public init(observesMemoryPressure: Bool = true) throws {
    self.observesMemoryPressure = observesMemoryPressure
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw PixeltjeMacError("Metal unavailable", "This Mac did not provide a Metal device.")
    }
    guard let coreAICommandQueue = device.makeCommandQueue() else {
      throw PixeltjeMacError(
        "Metal unavailable", "A command queue could not be created for Core AI inference.")
    }
    guard
      let rawWorkingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
      let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
      let displayReferredColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
    else {
      throw PixeltjeMacError(
        "Color space unavailable",
        "The required Extended Linear sRGB or Extended Linear Display P3 color space is unavailable."
      )
    }
    let rawContext = CIContext(
      mtlDevice: device,
      options: [
        .workingColorSpace: rawWorkingColorSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
      ]
    )
    let processingContext = CIContext(
      mtlDevice: device,
      options: [
        .workingColorSpace: workingColorSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
      ]
    )
    let differenceSignalKernel = CIColorKernel(source: Self.differenceSignalSource)
    let differenceThresholdKernel = CIColorKernel(source: Self.differenceThresholdSource)
    let maskRenderer = MaskRenderer(
      context: processingContext,
      workingColorSpace: workingColorSpace
    )
    self.device = device
    self.coreAICommandQueue = coreAICommandQueue
    self.workingColorSpace = workingColorSpace
    self.displayReferredColorSpace = displayReferredColorSpace
    self.rawContext = rawContext
    self.processingContext = processingContext
    self.differenceSignalKernel = differenceSignalKernel
    self.differenceThresholdKernel = differenceThresholdKernel
    self.frameAnalyzer = try RenderedFrameAnalyzer(device: device)
    self.imageSubjectTagger = try? ImageSubjectTagger(device: device)
    self.maskRenderer = maskRenderer
    self.brushRenderer = try BrushMetalRenderer(
      device: device,
      context: processingContext,
      maskRenderer: maskRenderer,
      workingColorSpace: workingColorSpace
    )
    self.zImagePipeline = ZImageCoreAIPipeline(commandQueue: coreAICommandQueue)
  }

  /// Renders a color or mask stroke surface without involving the document
  /// composite. The same entry point backs provisional paint and future mask
  /// consumers.
  public func renderStrokeSurface(_ request: StrokeSurfaceRequest) throws -> StrokeSurfaceFrame {
    try brushRenderer.render(request)
  }

  public func readStrokeSurfacePixels(_ request: StrokeSurfaceRequest) throws
    -> StrokeSurfacePixels
  {
    try brushRenderer.readPixels(request)
  }

  public func discardStrokeSurface(cacheID: String) {
    brushRenderer.removeSurface(cacheID: cacheID)
  }

  /// Renders a small deterministic stroke for a brush-library row. The caller
  /// receives the same tiled display boundary used by provisional paint; views
  /// never obtain Metal resources or perform brush rendering themselves.
  public func renderBrushPresetPreview(
    _ presetID: BrushPresetID,
    width: Int = 144,
    height: Int = 44,
    color: LinearRGBAColor? = nil
  ) throws -> StrokeSurfaceFrame {
    try brushRenderer.render(previewRequest(presetID, width: width, height: height, color: color))
  }

  /// The same preview as finished pixels, which is what the brush library
  /// shows. SwiftUI displays the result and never renders a brush itself.
  public func brushPresetPreviewImage(
    _ presetID: BrushPresetID,
    width: Int = 144,
    height: Int = 44,
    color: LinearRGBAColor? = nil
  ) throws -> CGImage? {
    let request = previewRequest(presetID, width: width, height: height, color: color)
    guard
      let image = try brushRenderer.colorImage(for: request, workingColorSpace: workingColorSpace)
    else { return nil }
    // Previews are transient: keep the tiles out of the paint budget rather
    // than letting fourteen library rows compete with the document's layers.
    defer { brushRenderer.removeSurface(cacheID: request.cacheID) }
    return processingContext.createCGImage(
      image,
      from: CGRect(x: 0, y: 0, width: request.width, height: request.height),
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.displayP3) ?? workingColorSpace
    )
  }

  /// One deterministic tapered curve, sized so every preset in the library is
  /// stroked identically and only the brush accounts for the difference.
  private func previewRequest(
    _ presetID: BrushPresetID,
    width: Int,
    height: Int,
    color: LinearRGBAColor?
  ) -> StrokeSurfaceRequest {
    let preset = BrushCatalog.preset(presetID)
    let safeWidth = min(max(width, 24), 512)
    let safeHeight = min(max(height, 24), 128)
    let inset = min(max(preset.settings.size / 2 + 2, 6), Double(safeWidth) / 3)
    let stroke = PaintStroke(
      seed: 0x5052_4556_4945_57,
      settings: preset.settings,
      brush: preset.definition,
      color: color ?? preset.previewColor,
      samples: [
        BrushSample(x: inset, y: Double(safeHeight) * 0.38, pressure: 0.35, sequence: 0),
        BrushSample(
          x: Double(safeWidth) * 0.48, y: Double(safeHeight) * 0.64, pressure: 0.8, sequence: 1),
        BrushSample(
          x: Double(safeWidth) - inset, y: Double(safeHeight) * 0.42, pressure: 0.55, sequence: 2),
      ]
    )
    return StrokeSurfaceRequest(
      cacheID: "built-in-brush-preview-\(presetID.rawValue)-\(safeWidth)x\(safeHeight)",
      recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [stroke]),
      width: safeWidth,
      height: safeHeight
    )
  }

  /// Freezes one explicit mask source into final, canvas-space coverage.
  ///
  /// Layer-owned masks are captured while the ordinary compositor is walking
  /// their owner. That gives range and Vision generators the correct
  /// layer-stage pixels, replays painted stroke surfaces through Metal, and
  /// applies the same owner crop and transform ancestry as the visible layer.
  public func captureInpaintingMask(
    _ request: InpaintingMaskRenderRequest
  ) async throws -> InpaintingMaskRenderResult {
    try await captureInpaintingMask(request, documentSourceFrame: nil)
  }

  /// Freezes the visible composite and document selection for pipeline input.
  /// Both rasters use Core Image's top-down bitmap order and the same canvas
  /// dimensions. A missing selection stays missing; an empty one stays zero.
  public func capturePipelineInputs(
    _ request: RenderRequest
  ) async throws -> PipelineHostInputSnapshot {
    guard request.quality == .full else {
      throw PixeltjeMacError(
        "Pipeline source unavailable", "Pipeline inputs need a full-quality render request.")
    }
    let frame = try await render(request)
    try Task.checkCancellation()
    guard frame.documentID == request.documentID,
      frame.revision == request.revision,
      frame.contentRevision == request.contentRevision,
      !frame.isProxy else {
      throw PixeltjeMacError(
        "Pipeline source changed", "The rendered composite no longer matches the request.")
    }
    let width = frame.width
    let height = frame.height
    guard width > 0, height > 0, width <= 8192, height <= 8192,
      width * height <= 16 * 1024 * 1024 else {
      throw PixeltjeMacError(
        "Pipeline source too large", "The native pipeline currently accepts up to 16 megapixels per input.")
    }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let source = CIImage(
      ioSurface: frame.surface, options: [.colorSpace: workingColorSpace]
    ).cropped(to: bounds)
    guard let pipelineColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw PixeltjeMacError(
        "Pipeline source unavailable", "sRGB is unavailable for pipeline interchange.")
    }
    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { bytes in
      processingContext.render(
        source, toBitmap: bytes.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: bounds, format: .RGBAf, colorSpace: pipelineColorSpace)
    }
    var values: [String: PipelineInvocationValue] = [
      PipelineInvocation.sourceImageKey: .image(
        try PipelineImageInput(width: width, height: height, rgba: rgba)),
    ]
    if let selection = request.recipe.selection {
      guard selection.isEnabled,
        selection.unavailableComponents.filter(\.isEnabled).isEmpty else {
        throw PixeltjeMacError(
          "Selection unavailable", "The current selection contains unavailable mask components.")
      }
      let coverage: [Float]
      if !selection.isEvaluable {
        coverage = [Float](repeating: 0, count: width * height)
      } else {
        let space = CompositeSpace(
          extent: bounds,
          scaleX: request.recipe.layerStack.canvas.isResolved
            ? bounds.width / CGFloat(request.recipe.layerStack.canvas.width) : 1,
          scaleY: request.recipe.layerStack.canvas.isResolved
            ? bounds.height / CGFloat(request.recipe.layerStack.canvas.height) : 1)
        guard let image = try maskRenderer.evaluate(
          selection,
          in: MaskSpace(extent: bounds, pixelsPerCanvasPixel: space.scaleY),
          source: source,
          sourceIdentity: "pipeline-selection:\(frame.documentID):\(frame.contentRevision)",
          strokeSurfaceCoverage: { surface in
            try self.paintedMaskCoverage(
              surface,
              cacheID: "pipeline-selection:\(selection.id.rawValue)",
              in: space)
          }) else {
          throw PixeltjeMacError(
            "Selection unavailable", "The current selection could not produce mask coverage.")
        }
        coverage = try maskCoverage(from: image, in: bounds)
      }
      values[PipelineInvocation.selectionMaskKey] = .mask(
        try PipelineMaskInput(width: width, height: height, coverage: coverage))
    }
    try Task.checkCancellation()
    return PipelineHostInputSnapshot(
      documentID: frame.documentID,
      revision: frame.revision,
      contentRevision: frame.contentRevision,
      invocation: PipelineInvocation(values: values))
  }

  /// The generation path already has the revision-tagged composite on hand.
  /// Reuse it for document masks; owner masks still walk the immutable render
  /// request because their pre-composite layer pixels are intentionally absent
  /// from `RenderedFrame`.
  func captureInpaintingMask(
    _ request: InpaintingMaskRenderRequest,
    documentSourceFrame: RenderedFrame?
  ) async throws -> InpaintingMaskRenderResult {
    let renderRequest = request.renderRequest
    guard renderRequest.quality == .full else {
      throw PixeltjeMacError(
        "Mask capture unavailable",
        "Inpainting masks must be captured from a full-quality render request.")
    }

    switch request.source {
    case .documentMask(let mask):
      try validateInpaintingMask(mask)
      let frame: RenderedFrame
      if let documentSourceFrame {
        guard documentSourceFrame.documentID == renderRequest.documentID,
          documentSourceFrame.revision == renderRequest.revision,
          documentSourceFrame.contentRevision == renderRequest.contentRevision,
          !documentSourceFrame.isProxy
        else {
          throw PixeltjeMacError(
            "Source changed",
            "The displayed composite does not match the mask capture request.")
        }
        frame = documentSourceFrame
      } else {
        frame = try await render(renderRequest)
      }
      let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
      let canvas = renderRequest.recipe.layerStack.canvas
      let space = CompositeSpace(
        extent: bounds,
        scaleX: canvas.isResolved ? bounds.width / CGFloat(canvas.width) : 1,
        scaleY: canvas.isResolved ? bounds.height / CGFloat(canvas.height) : 1)
      let source = CIImage(
        ioSurface: frame.surface,
        options: [.colorSpace: workingColorSpace]
      ).cropped(to: bounds)
      guard
        let coverage = try maskRenderer.evaluate(
          mask,
          in: MaskSpace(extent: bounds, pixelsPerCanvasPixel: space.scaleY),
          source: source,
          sourceIdentity:
            "inpainting-document-mask:\(frame.documentID.uuidString):\(frame.contentRevision)",
          strokeSurfaceCoverage: { surface in
            try self.paintedMaskCoverage(
              surface,
              cacheID: "inpainting-document-mask:\(mask.id.rawValue)",
              in: space)
          })
      else {
        throw PixeltjeMacError(
          "Inpainting needs a mask", "The selected document mask produced no coverage.")
      }
      return try inpaintingMaskResult(
        coverage,
        bounds: bounds,
        documentID: renderRequest.documentID,
        revision: renderRequest.revision,
        contentRevision: renderRequest.contentRevision)

    case .layerMask(let layerID, let maskID):
      return try await captureOwnedInpaintingMask(
        request: renderRequest,
        layerID: layerID,
        maskID: maskID,
        kind: .layerMask)

    case .localMask(let layerID, let maskID):
      return try await captureOwnedInpaintingMask(
        request: renderRequest,
        layerID: layerID,
        maskID: maskID,
        kind: .localMask)
    }
  }

  private func validateInpaintingMask(_ mask: MaskRecipe) throws {
    guard mask.isEnabled else {
      throw PixeltjeMacError(
        "Inpainting mask disabled", "Enable the selected mask before using it for inpainting.")
    }
    guard mask.isEvaluable else {
      throw PixeltjeMacError(
        "Inpainting mask unavailable", "The selected mask has no available components.")
    }
    let unavailable = mask.components.filter {
      $0.isEnabled && !$0.availability.isAvailable
    }
    guard unavailable.isEmpty else {
      throw PixeltjeMacError(
        "Inpainting mask unavailable",
        "The selected mask contains components that are not available on this Mac.")
    }
  }

  private func captureOwnedInpaintingMask(
    request: RenderRequest,
    layerID: ProjectLayerID,
    maskID: MaskID,
    kind: InpaintingMaskCaptureContext.Kind
  ) async throws -> InpaintingMaskRenderResult {
    guard let entry = request.recipe.layerStack.entry(id: layerID) else {
      throw PixeltjeMacError(
        "Inpainting mask missing", "The layer that owned the selected mask no longer exists.")
    }
    guard entry.isEffectivelyEnabled else {
      throw PixeltjeMacError(
        "Inpainting mask unavailable", "Enable the selected mask's layer and its parent groups.")
    }
    let mask: MaskRecipe?
    switch kind {
    case .layerMask:
      mask = entry.layer.layerMask.flatMap { $0.id == maskID ? $0 : nil }
    case .localMask:
      mask = entry.layer.mask(id: maskID)
    }
    guard let mask else {
      throw PixeltjeMacError(
        "Inpainting mask missing", "The selected mask no longer exists on its layer.")
    }
    try validateInpaintingMask(mask)

    let accessedRawInputs = request.rawInputs.values.filter {
      $0.startAccessingSecurityScope()
    }
    defer {
      for input in accessedRawInputs { input.stopAccessingSecurityScope(if: true) }
    }
    let placedImages = try resolveImageLayers(request.recipe.layerStack)
    let accessedImages = placedImages.values.filter {
      $0.url.startAccessingSecurityScopedResource()
    }
    defer {
      for placed in accessedImages { placed.url.stopAccessingSecurityScopedResource() }
    }

    try Task.checkCancellation()
    var developedRaws: [ProjectLayerID: CIImage] = [:]
    var backgroundExtent: CGRect?
    for candidate in request.recipe.layerStack.flattenedLayers
    where candidate.isEffectivelyEnabled {
      let input =
        request.rawInputs[candidate.id]
        ?? (request.rawInputs.count == 1 ? request.input : nil)
      guard let raw = candidate.layer.developedRawLayer, let input else { continue }
      let (developedImage, inspection) = try await developedRaw(
        layerID: candidate.id,
        raw: raw,
        input: input,
        quality: .full)
      try Task.checkCancellation()
      var image = developedImage
      if inspection.exifOrientation != 1 {
        image = image.oriented(forExifOrientation: inspection.exifOrientation)
      }
      image = normalized(image)
      if candidate.id == .rawBackground {
        image = normalized(applyStraightenAndCrop(request.recipe.crop, to: image))
        image = normalized(applyUpright(raw.upright, to: image))
        image = normalized(applyPostProcessing(request.recipe.postProcessing, to: image))
        backgroundExtent = image.extent
      } else {
        image = normalized(applyUpright(raw.upright, to: image))
      }
      developedRaws[candidate.id] = image
    }

    let resolvedRasters = try resolveRasterLayers(
      request.recipe.layerStack, assets: request.rasterAssets)
    let extent = try backgroundExtent
      ?? transparentCanvas(request.recipe.layerStack.canvas, quality: .full).extent
    let canvas = request.recipe.layerStack.canvas
    let space = CompositeSpace(
      extent: extent,
      scaleX: canvas.isResolved ? extent.width / CGFloat(canvas.width) : 1,
      scaleY: canvas.isResolved ? extent.height / CGFloat(canvas.height) : 1)
    let rawIdentity = request.recipe.layerStack.flattenedLayers.compactMap { candidate in
      candidate.layer.developedRawLayer.map {
        "\(candidate.id.rawValue):\($0.rawDevelopment.parameters as Any)"
      }
    }.joined(separator: "|")
    let identitySeed =
      "\(request.documentID)|\(rawIdentity)|\(request.recipe.crop)|\(request.recipe.postProcessing)"
    let layerCropFrames = Dictionary(uniqueKeysWithValues:
      request.recipe.layerStack.flattenedLayers.compactMap { candidate in
        request.recipe.layerStack.cropFrame(of: candidate.id).map { (candidate.id, $0) }
      })
    let capture = InpaintingMaskCaptureContext(
      layerID: layerID,
      maskID: maskID,
      kind: kind,
      transformPath: Set([entry.id] + entry.ancestorIDs))
    _ = try composite(
      request.recipe.layerStack.layers,
      over: CIImage(color: .clear).cropped(to: extent),
      in: space,
      developedRaws: developedRaws,
      placedImages: placedImages,
      projectRasters: resolvedRasters.images,
      differenceSources: resolvedRasters.differenceSources,
      healPatches: resolvedRasters.healPatches,
      layerCropFrames: layerCropFrames,
      identitySeed: "\(identitySeed)|inpainting-mask",
      inpaintingMaskCapture: capture)
    guard let captured = capture.coverage else {
      throw PixeltjeMacError(
        "Inpainting mask unavailable",
        "The selected mask could not be evaluated against its owning layer.")
    }
    let zero = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
      .cropped(to: extent)
    let finalCoverage = captured
      .composited(over: zero)
      .cropped(to: extent)
    let result = try inpaintingMaskResult(
      finalCoverage,
      bounds: extent,
      documentID: request.documentID,
      revision: request.revision,
      contentRevision: request.contentRevision)
    // `CIImage(bitmapData:)` and generated-inpaint assets are lazy. Keep every
    // decoded project buffer alive through the coverage readback.
    withExtendedLifetime(resolvedRasters.backingPixels) {}
    return result
  }

  private func inpaintingMaskResult(
    _ image: CIImage,
    bounds: CGRect,
    documentID: UUID,
    revision: UInt64,
    contentRevision: UInt64
  ) throws -> InpaintingMaskRenderResult {
    let width = Int(bounds.width.rounded())
    let height = Int(bounds.height.rounded())
    let coverage = try maskCoverage(from: image, in: bounds)
    guard let nonzeroBounds = Self.nonzeroMaskBounds(
      coverage, width: width, height: height)
    else {
      throw PixeltjeMacError("Inpainting needs a mask", "The selected mask is empty.")
    }
    return InpaintingMaskRenderResult(
      documentID: documentID,
      revision: revision,
      contentRevision: contentRevision,
      width: width,
      height: height,
      coverage: coverage,
      nonzeroBounds: nonzeroBounds)
  }

  public func render(_ request: RenderRequest) async throws -> RenderedFrame {
    if observesMemoryPressure, memoryPressureSource == nil {
      let source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical], queue: .global())
      source.setEventHandler { [weak self] in Task { await self?.clearCaches() } }
      source.resume()
      memoryPressureSource = source
    }
    let clock = ContinuousClock()
    let start = clock.now
    let accessedRawInputs = request.rawInputs.values.filter {
      $0.startAccessingSecurityScope()
    }
    defer {
      for input in accessedRawInputs { input.stopAccessingSecurityScope(if: true) }
    }

    // Linked images stay accessible for the whole render, not just while they
    // are loaded: `CIImage(contentsOf:)` reads its pixels lazily, when the
    // composite below is finally rendered into the output surface.
    let placedImages = try resolveImageLayers(request.recipe.layerStack)
    let accessedImages = placedImages.values.filter {
      $0.url.startAccessingSecurityScopedResource()
    }
    defer {
      for placed in accessedImages { placed.url.stopAccessingSecurityScopedResource() }
    }

    try Task.checkCancellation()
    var inspections: [ProjectLayerID: RawInspection] = [:]
    var developedRaws: [ProjectLayerID: CIImage] = [:]
    var backgroundExtent: CGRect?
    for entry in request.recipe.layerStack.flattenedLayers where entry.isEffectivelyEnabled {
      let input =
        request.rawInputs[entry.id]
        ?? (request.rawInputs.count == 1 ? request.input : nil)
      guard let raw = entry.layer.developedRawLayer, let input else {
        continue
      }
      let (developedImage, inspection) = try await developedRaw(
        layerID: entry.id,
        raw: raw,
        input: input,
        quality: request.quality
      )
      try Task.checkCancellation()
      inspections[entry.id] = inspection
      var image = developedImage
      if inspection.exifOrientation != 1 {
        image = image.oriented(forExifOrientation: inspection.exifOrientation)
      }
      image = normalized(image)
      if entry.id == .rawBackground {
        image = normalized(applyStraightenAndCrop(request.recipe.crop, to: image))
        image = normalized(applyUpright(raw.upright, to: image))
        // `postProcessing` is legacy document state. It continues to affect
        // only the background RAW it historically belonged to, never every
        // layer in a new RAW composite.
        image = normalized(applyPostProcessing(request.recipe.postProcessing, to: image))
        backgroundExtent = image.extent
      } else {
        image = normalized(applyUpright(raw.upright, to: image))
      }
      developedRaws[entry.id] = image
    }
    // Resolve project rasters after RAW development's suspension points. The
    // cached bitmap storage then stays alive through the synchronous composite.
    let resolvedRasters = try resolveRasterLayers(
      request.recipe.layerStack, assets: request.rasterAssets)
    let projectRasters = resolvedRasters.images
    let differenceSources = resolvedRasters.differenceSources
    let healPatches = resolvedRasters.healPatches
    let extent: CGRect
    if let backgroundExtent {
      extent = backgroundExtent
    } else {
      extent = try transparentCanvas(
        request.recipe.layerStack.canvas,
        quality: request.quality
      ).extent
    }
    // Layer frames are written in canvas pixels. A proxy render carries fewer
    // pixels than the canvas it stands for, so placement scales with the
    // render extent rather than assuming the two are the same size.
    let canvas = request.recipe.layerStack.canvas
    let space = CompositeSpace(
      extent: extent,
      scaleX: canvas.isResolved ? extent.width / CGFloat(canvas.width) : 1,
      scaleY: canvas.isResolved ? extent.height / CGFloat(canvas.height) : 1
    )
    // Names the pixels a Vision segmentation would analyse, so a cached subject
    // or person mask is reused across mask-parameter changes but dropped as
    // soon as the underlying development changes.
    let rawIdentity = request.recipe.layerStack.flattenedLayers.compactMap { entry in
      entry.layer.developedRawLayer.map {
        "\(entry.id.rawValue):\($0.rawDevelopment.parameters as Any)"
      }
    }.joined(separator: "|")
    let identitySeed =
      "\(request.documentID)|\(rawIdentity)|\(request.recipe.crop)|\(request.recipe.postProcessing)"
    let layerCropFrames = Dictionary(uniqueKeysWithValues:
      request.recipe.layerStack.flattenedLayers.compactMap { entry in
        request.recipe.layerStack.cropFrame(of: entry.id).map { (entry.id, $0) }
      })
    let differencePreview = request.differencePreviewLayerID.map(DifferenceKeyPreviewCapture.init)
    var finalImage = try composite(
      request.recipe.layerStack.layers,
      over: CIImage(color: .clear).cropped(to: extent),
      in: space,
      developedRaws: developedRaws,
      placedImages: placedImages,
      projectRasters: projectRasters,
      differenceSources: differenceSources,
      healPatches: healPatches,
      layerCropFrames: layerCropFrames,
      identitySeed: identitySeed,
      differencePreview: differencePreview
    )
    finalImage = normalized(finalImage.cropped(to: extent))

    let finalSurface = try makeSurface(for: finalImage.extent)
    processingContext.render(
      finalImage,
      to: finalSurface,
      bounds: finalImage.extent,
      colorSpace: workingColorSpace
    )
    let differencePreviewSurface: IOSurface?
    if let preview = differencePreview?.image {
      let image = normalized(preview.cropped(to: extent))
      let surface = try makeSurface(for: image.extent)
      processingContext.render(
        image, to: surface, bounds: image.extent, colorSpace: workingColorSpace)
      differencePreviewSurface = surface
    } else {
      differencePreviewSurface = nil
    }

    let activeLayerID = request.recipe.layerStack.activeLayerID
    let activeLayerSamplingSurface: IOSurface?
    if let layerID = activeLayerID,
      let entry = request.recipe.layerStack.entry(id: layerID),
      entry.isEffectivelyEnabled, !entry.layer.isCanvasLayer
    {
      if entry.layer.isVectorLayer {
        // Like the composite vector overlay, an active vector layer is cheap to
        // evaluate over the picker's handful of pixels and expensive to retain
        // as another complete document-sized surface.
        activeLayerSamplingSurface = nil
      } else {
        let clear = CIImage(color: .clear).cropped(to: extent)
        var isolatedLayer = entry.layer
        // Active Layer reads the layer before its blend interaction with what
        // is below. Opacity and fill still apply against transparency.
        isolatedLayer.compositing.blendMode = .normal
        let isolated = try composite(
          [isolatedLayer],
          over: clear,
          in: space,
          developedRaws: developedRaws,
          placedImages: placedImages,
          projectRasters: projectRasters,
          differenceSources: differenceSources,
          healPatches: healPatches,
          layerCropFrames: layerCropFrames,
          identitySeed: "\(identitySeed)|active:\(layerID.rawValue)"
        )
        let image = normalized(isolated.cropped(to: extent))
        let surface = try makeSurface(for: image.extent)
        processingContext.render(
          image, to: surface, bounds: image.extent, colorSpace: workingColorSpace)
        activeLayerSamplingSurface = surface
      }
    } else {
      activeLayerSamplingSurface = nil
    }

    // A bounded cache may evict an earlier layer while resolving later ones.
    // Keep every lazy bitmap's storage alive until both surfaces are complete.
    withExtendedLifetime(resolvedRasters.backingPixels) {}

    let duration = start.duration(to: clock.now)
    let elapsed =
      Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    logger.info(
      "Rendered \(request.rawInputs.isEmpty ? "canvas" : "RAW composite", privacy: .public) at \(Int(finalImage.extent.width))x\(Int(finalImage.extent.height)) in \(elapsed, format: .fixed(precision: 3))s"
    )
    var frame = RenderedFrame(
      documentID: request.documentID,
      revision: request.revision,
      contentRevision: request.contentRevision,
      surface: finalSurface,
      activeLayerSamplingSurface: activeLayerSamplingSurface,
      sampledActiveLayerID: activeLayerID,
      samplingLayerStack: request.recipe.layerStack,
      width: Int(finalImage.extent.width.rounded()),
      height: Int(finalImage.extent.height.rounded()),
      isProxy: request.quality.isProxy,
      inspection: inspections[.rawBackground] ?? inspections.values.first,
      rawInspections: inspections,
      elapsedSeconds: elapsed
    )
    frame.differencePreviewSurface = differencePreviewSurface
    return frame
  }

  /// Measures a frame after it has been returned for presentation.
  ///
  /// The dedicated analyzer actor owns its own context, so this suspension
  /// leaves `RenderEngine` available for a newer render while the readback is
  /// being counted.
  public func analyze(_ frame: RenderedFrame) async throws -> RenderedFrameAnalysis {
    try await frameAnalyzer.analyze(frame)
  }

  /// Optional, on-device subject names for the prompt box. This actor owns a
  /// separate readback context and does not delay rendering or the histogram.
  func suggestSubjectTags(for frame: RenderedFrame) async throws -> [ImageContentTag]? {
    try await imageSubjectTagger?.suggestTags(for: frame)
  }

  /// Materializes the complete visible result of an isolated layer recipe as
  /// lossless, premultiplied RGBA16F project pixels.
  ///
  /// `crop` narrows the result to a region of the canvas, for a copy that takes
  /// only what a selection encloses. A full-quality render resolves the canvas
  /// one pixel for one, so the crop is stated in canvas pixels like any other
  /// `LayerFrame`.
  public func bakeRaster(
    _ request: RenderRequest,
    cropTo crop: CGRect? = nil
  ) async throws -> RasterBakeResult {
    let (image, bounds) = try await bakedImage(request, cropTo: crop)
    return try encodeRaster(image, in: bounds)
  }

  /// Bakes one region twice over: as project pixels and as a PNG, from a single
  /// render, which is what putting a selection on the pasteboard needs.
  public func bakeSelection(
    _ request: RenderRequest,
    cropTo crop: CGRect
  ) async throws -> SelectionBakeResult {
    let (image, bounds) = try await bakedImage(request, cropTo: crop)
    let raster = try encodeRaster(image, in: bounds)
    try Task.checkCancellation()
    return SelectionBakeResult(raster: raster, png: try pngData(image, in: bounds), bounds: bounds)
  }

  /// Embeds pixels that came from outside the project — an image pasted from
  /// another application — as lossless project pixels.
  ///
  /// The image is grounded at the origin first, so the asset it becomes starts
  /// at (0, 0) the way every other project raster does.
  public func importRaster(_ image: CIImage) throws -> RasterBakeResult {
    let extent = image.extent
    guard !extent.isInfinite, !extent.isEmpty, extent.width >= 1, extent.height >= 1 else {
      throw PixeltjeMacError(
        "Paste failed", "The pasted image has no pixels to place on the canvas.")
    }
    let grounded = image.transformed(
      by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    return try encodeRaster(
      grounded,
      in: CGRect(x: 0, y: 0, width: extent.width.rounded(), height: extent.height.rounded()))
  }

  /// Renders a request to full quality and says which region of it to read
  /// back, with the crop resolved against what was actually rendered.
  private func bakedImage(
    _ request: RenderRequest,
    cropTo crop: CGRect?
  ) async throws -> (image: CIImage, bounds: CGRect) {
    guard request.quality == .full else {
      throw PixeltjeMacError("Rasterization unavailable", "Layer baking requires full quality.")
    }
    let frame = try await render(request)
    try Task.checkCancellation()
    let image = CIImage(ioSurface: frame.surface, options: [.colorSpace: workingColorSpace])
    let rendered = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
    // A crop that falls entirely off the canvas would encode an asset with no
    // pixels at all, which is a failure worth naming rather than an empty
    // layer nobody can see.
    let bounds = crop.map { $0.integral.intersection(rendered) } ?? rendered
    guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else {
      throw PixeltjeMacError(
        "Nothing to copy", "The selected area does not overlap the canvas.")
    }
    return (image, bounds)
  }

  /// Reads one region of a working-space image back as lossless, premultiplied
  /// RGBA16F project pixels.
  func encodeRaster(_ image: CIImage, in bounds: CGRect) throws -> RasterBakeResult {
    let width = Int(bounds.width.rounded())
    let height = Int(bounds.height.rounded())
    let rowBytes = width * MemoryLayout<Float16>.size * 4
    var pixels = Data(count: rowBytes * height)
    pixels.withUnsafeMutableBytes { storage in
      guard let baseAddress = storage.baseAddress else { return }
      processingContext.render(
        image,
        toBitmap: baseAddress,
        rowBytes: rowBytes,
        bounds: bounds,
        format: .RGBAh,
        colorSpace: workingColorSpace
      )
    }
    try Task.checkCancellation()
    let encoded = try RasterAssetPayload.encode(pixels, width: width, height: height)
    return RasterBakeResult(
      reference: encoded.reference,
      compressedPixels: encoded.compressedPixels
    )
  }

  /// A display-referred PNG of one region, for the system pasteboard.
  ///
  /// The working space is linear and extended, so the image is normalized and
  /// written through Display P3 the way an export is; another application
  /// reading the pasteboard has no idea what an extended linear primary means.
  private func pngData(_ image: CIImage, in bounds: CGRect) throws -> Data {
    let region = normalized(image.cropped(to: bounds))
      .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    guard
      let data = processingContext.pngRepresentation(
        of: region,
        format: .RGBA8,
        colorSpace: displayReferredColorSpace,
        options: [:]
      )
    else {
      throw PixeltjeMacError("Copy failed", "The selected pixels could not be encoded.")
    }
    return data
  }

  /// Averages a small neighbourhood of the linear working-space image around a
  /// document point, for the white-balance picker.
  ///
  /// The point is normalized to the frame, origin at the bottom left, which is
  /// both the canvas's document space and Core Image's. Sampling several pixels
  /// keeps one noisy photosite from deciding the white balance of the image.
  ///
  /// The values come back in Extended Linear Display P3 — linear light, not a
  /// display encoding — because the neutral maths reads a chromaticity, which
  /// only means anything before a transfer function.
  public func sampleLinearColor(
    in frame: RenderedFrame,
    atNormalizedX x: Double,
    y: Double,
    radiusInPixels: Int = 4
  ) -> LinearRGBSample? {
    // White balance continues to read the developed raster, not vector
    // artwork the canvas draws above it for composition work.
    guard let color = sampleLinearRGBAColor(
      in: frame.surface,
      atNormalizedX: x,
      y: y,
      diameter: max(radiusInPixels, 0) * 2 + 1
    ) else { return nil }
    return LinearRGBSample(red: color.red, green: color.green, blue: color.blue)
  }

  /// Samples a square image-pixel neighbourhood in Extended Linear Display P3.
  /// Transparent pixels contribute no hue; a fully transparent window returns
  /// nil. Returned tool colors are opaque, leaving brush opacity and flow as
  /// the sole coverage controls. The region clips at image edges.
  public func sampleLinearRGBAColor(
    in frame: RenderedFrame,
    layerStack: LayerStack? = nil,
    source: ColorSampleSource,
    atNormalizedX x: Double,
    y: Double,
    sampleSize: ColorSampleSize
  ) -> LinearRGBAColor? {
    sampleLinearRGBAColor(
      in: frame,
      layerStack: layerStack,
      source: source,
      atNormalizedX: x,
      y: y,
      diameter: sampleSize.rawValue
    )
  }

  private func sampleLinearRGBAColor(
    in frame: RenderedFrame,
    layerStack: LayerStack?,
    source: ColorSampleSource,
    atNormalizedX x: Double,
    y: Double,
    diameter: Int
  ) -> LinearRGBAColor? {
    let layerStack = layerStack ?? frame.samplingLayerStack
    let frameImage = CIImage(ioSurface: frame.surface, options: [.colorSpace: workingColorSpace])
    guard let region = samplingRegion(
      in: frameImage.extent, x: x, y: y, diameter: diameter)
    else { return nil }

    switch source {
    case .composite:
      return sampleLinearRGBAColor(in: frameImage, region: region)

    case .activeLayer:
      guard let activeLayerID = frame.sampledActiveLayerID else { return nil }
      if let layerStack,
        let entry = layerStack.entry(id: activeLayerID),
        let vectorLayer = entry.layer.content.vectorValue
      {
        guard
          let vectorImage = try? VectorArtworkRenderer.makeImage(
            vectorLayer: vectorLayer,
            width: frame.width,
            height: frame.height,
            workingColorSpace: workingColorSpace,
            region: region)
        else { return nil }
        return sampleLinearRGBAColor(in: vectorImage, region: vectorImage.extent)
      }
      guard let active = frame.activeLayerSamplingSurface else { return nil }
      let activeImage = CIImage(ioSurface: active, options: [.colorSpace: workingColorSpace])
      return sampleLinearRGBAColor(in: activeImage, region: region)
    }
  }

  private func sampleLinearRGBAColor(
    in surface: IOSurface,
    atNormalizedX x: Double,
    y: Double,
    diameter: Int
  ) -> LinearRGBAColor? {
    let image = CIImage(ioSurface: surface, options: [.colorSpace: workingColorSpace])
    guard let region = samplingRegion(in: image.extent, x: x, y: y, diameter: diameter)
    else { return nil }
    return sampleLinearRGBAColor(in: image, region: region)
  }

  private func samplingRegion(
    in extent: CGRect, x: Double, y: Double, diameter: Int
  ) -> CGRect? {
    guard extent.width >= 1, extent.height >= 1, (0...1).contains(x), (0...1).contains(y) else {
      return nil
    }
    // Normalized 1.0 names the final pixel rather than the coordinate just
    // beyond the extent. Integer regions also ensure Point really reads one
    // pixel instead of `.integral` expanding a half-pixel rectangle to two.
    let pixelX = min(Int(x * Double(extent.width)), Int(extent.width) - 1)
    let pixelY = min(Int(y * Double(extent.height)), Int(extent.height) - 1)
    let radius = max(diameter - 1, 0) / 2
    let region = CGRect(
      x: Int(extent.minX) + pixelX - radius,
      y: Int(extent.minY) + pixelY - radius,
      width: radius * 2 + 1,
      height: radius * 2 + 1
    ).intersection(extent)
    return !region.isNull && region.width >= 1 && region.height >= 1 ? region : nil
  }

  private func sampleLinearRGBAColor(
    in image: CIImage, region: CGRect
  ) -> LinearRGBAColor? {
    let width = Int(region.width)
    let height = Int(region.height)
    var pixels = [Float](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      processingContext.render(
        image,
        toBitmap: base,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: region,
        format: .RGBAf,
        colorSpace: workingColorSpace
      )
    }

    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var alphaSum = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Double(pixels[index + 3])
      guard alpha > 0, alpha.isFinite else { continue }
      // Core Image renders premultiplied. Summing premultiplied values and
      // dividing once by coverage gives partially transparent edge pixels the
      // right influence without letting invisible RGB contaminate the result.
      red += Double(pixels[index])
      green += Double(pixels[index + 1])
      blue += Double(pixels[index + 2])
      alphaSum += alpha
    }
    guard alphaSum > 0 else { return nil }
    return LinearRGBAColor(
      red: red / alphaSum,
      green: green / alphaSum,
      blue: blue / alphaSum,
      alpha: 1
    )
  }

  /// Captures a connected region from the displayed linear-P3 frame. Matching
  /// converts those pixels to display-referred components so tolerance remains
  /// useful in shadows. The result is recipe geometry, so reopening never has
  /// to guess the region again from pixels that may since have changed.
  public func contiguousMask(
    in frame: RenderedFrame,
    source: FillSampleSource = .composite,
    atNormalizedX x: Double,
    y: Double,
    tolerance: Double,
    smoothness: Double = 0
  ) throws -> MaskRecipe? {
    let image = try maskSourceImage(in: frame, source: source)
    return try contiguousMask(
      in: image, x: x, y: y, tolerance: tolerance, smoothness: smoothness)
  }

  private func contiguousMask(
    in image: CIImage,
    x: Double,
    y: Double,
    tolerance: Double,
    smoothness: Double = 0
  ) throws -> MaskRecipe? {
    let capture = try capturedMaskPixels(in: image, x: x, y: y)
    let raster = ContiguousRegionBuilder.mask(
      width: capture.width, height: capture.height, premultipliedRGBA: capture.pixels,
      seedX: capture.seedX, seedY: capture.seedY, tolerance: tolerance,
      smoothness: smoothness,
      isCancelled: { Task.isCancelled })
    try Task.checkCancellation()
    guard let raster, !raster.isEmpty else {
      throw PixeltjeMacError(
        "Selection is too complex",
        "Try a smaller tolerance or less Smoothness, then click again.")
    }
    return .single(.raster(raster), name: "Contiguous Region")
  }

  /// Captures all pixels near the clicked color, whether or not they touch the
  /// clicked point. The soft coverage is stored in the raster runs, so later
  /// edits cannot move the selection and every consumer sees the same result.
  public func colorRangeMask(
    in frame: RenderedFrame,
    source: FillSampleSource = .composite,
    atNormalizedX x: Double,
    y: Double,
    tolerance: Double,
    smoothness: Double
  ) throws -> MaskRecipe? {
    let image = try maskSourceImage(in: frame, source: source)
    let capture = try capturedMaskPixels(in: image, x: x, y: y)
    let raster = ColorRangeRegionBuilder.mask(
      width: capture.width, height: capture.height,
      premultipliedRGBA: capture.pixels,
      seedX: capture.seedX, seedY: capture.seedY,
      tolerance: tolerance, smoothness: smoothness,
      isCancelled: { Task.isCancelled })
    try Task.checkCancellation()
    guard let raster, !raster.isEmpty else {
      throw PixeltjeMacError(
        "Selection is too complex",
        "Try a smaller tolerance or less Smoothness, then click again.")
    }
    return .single(.raster(raster), name: "Color Range")
  }

  /// Uses one painted stroke as a set of foreground hints, then captures an
  /// edge-aware region from the same bounded proxy used by Magnet Selection.
  /// The stroke itself remains in canonical canvas pixels; it is scaled only
  /// for this analysis and is never rewritten into the document recipe.
  public func quickSelectionMask(
    in frame: RenderedFrame,
    source: FillSampleSource = .composite,
    hints: PaintStroke,
    tolerance: Double,
    edgeSensitivity: Double,
    smoothness: Double
  ) throws -> MaskRecipe? {
    guard let first = hints.samples.first, frame.width > 0, frame.height > 0 else {
      throw PixeltjeMacError(
        "Quick Select needs a brush hint",
        "Paint over the object you want to select, then release the pointer.")
    }
    let image = try maskSourceImage(in: frame, source: source)
    let capture = try capturedMaskPixels(
      in: image,
      x: min(max(first.x / Double(frame.width), 0), 1),
      y: min(max(first.y / Double(frame.height), 0), 1))
    let scaled = hints.scaled(
      byX: Double(capture.width) / Double(frame.width),
      y: Double(capture.height) / Double(frame.height))
    var hinted = [UInt8](repeating: 0, count: capture.width * capture.height)
    for (stampIndex, stamp) in scaled.interpolatedStamps().enumerated() {
      if stampIndex & 0x3FF == 0 { try Task.checkCancellation() }
      let radiusX = max(stamp.diameter / 2, 0.5)
      let radiusY = max(radiusX * stamp.aspectRatio, 0.5)
      let minX = max(Int((stamp.x - radiusX).rounded(.down)), 0)
      let maxX = min(Int((stamp.x + radiusX).rounded(.up)), capture.width - 1)
      let minY = max(Int((stamp.y - radiusY).rounded(.down)), 0)
      let maxY = min(Int((stamp.y + radiusY).rounded(.up)), capture.height - 1)
      guard minX <= maxX, minY <= maxY else { continue }
      for y in minY...maxY {
        for x in minX...maxX {
          let dx = (Double(x) + 0.5 - stamp.x) / radiusX
          let dy = (Double(y) + 0.5 - stamp.y) / radiusY
          if dx * dx + dy * dy <= 1 { hinted[y * capture.width + x] = 1 }
        }
      }
    }
    let seeds = hinted.indices.filter { hinted[$0] != 0 }
    let raster = QuickSelectionRegionBuilder.mask(
      width: capture.width,
      height: capture.height,
      premultipliedRGBA: capture.pixels,
      seedIndices: seeds,
      tolerance: tolerance,
      edgeSensitivity: edgeSensitivity,
      smoothness: smoothness,
      isCancelled: { Task.isCancelled })
    try Task.checkCancellation()
    guard let raster, !raster.isEmpty else {
      throw PixeltjeMacError(
        "Quick Select could not find a region",
        "Paint a more representative hint, raise Tolerance, or reduce Edge Sensitivity.")
    }
    return .single(.raster(raster), name: "Quick Select")
  }

  private func maskSourceImage(
    in frame: RenderedFrame,
    source: FillSampleSource
  ) throws -> CIImage {
    switch source {
    case .composite:
      return CIImage(ioSurface: frame.surface, options: [.colorSpace: workingColorSpace])
    case .activeLayer:
      guard let surface = frame.activeLayerSamplingSurface else {
        throw PixeltjeMacError(
          "Current Layer pixels are unavailable",
          "Select a visible RAW, image, paint, or text layer and wait for the canvas to finish rendering.")
      }
      return CIImage(ioSurface: surface, options: [.colorSpace: workingColorSpace])
    }
  }

  private func capturedMaskPixels(
    in image: CIImage,
    x: Double,
    y: Double
  ) throws -> (width: Int, height: Int, pixels: [Float], seedX: Int, seedY: Int) {
    try Task.checkCancellation()
    let sourceWidth = Int(image.extent.width.rounded())
    let sourceHeight = Int(image.extent.height.rounded())
    guard sourceWidth > 0, sourceHeight > 0 else {
      throw PixeltjeMacError(
        "Image has no selectable pixels",
        "The rendered image has no usable extent for color-based selection."
      )
    }
    guard (0...1).contains(x), (0...1).contains(y) else {
      throw PixeltjeMacError(
        "Capture point is outside the canvas",
        "Click inside the rendered image to capture a color region.")
    }
    let size = Self.boundedMaskCaptureSize(width: sourceWidth, height: sourceHeight)
    let width = size.width
    let height = size.height
    let sourceSeedX = min(max(Int((x * Double(sourceWidth)).rounded(.down)), 0), sourceWidth - 1)
    let sourceSeedY = min(max(Int((y * Double(sourceHeight)).rounded(.down)), 0), sourceHeight - 1)
    var exactSeed = [Float](repeating: 0, count: 4)
    exactSeed.withUnsafeMutableBytes { bytes in
      guard let address = bytes.baseAddress else { return }
      processingContext.render(
        image,
        toBitmap: address,
        rowBytes: 4 * MemoryLayout<Float>.size,
        bounds: CGRect(
          x: image.extent.minX + CGFloat(sourceSeedX),
          y: image.extent.minY + CGFloat(sourceSeedY),
          width: 1,
          height: 1),
        format: .RGBAf,
        colorSpace: workingColorSpace)
    }
    try Task.checkCancellation()
    let normalized = image.transformed(by: CGAffineTransform(
      translationX: -image.extent.minX,
      y: -image.extent.minY))
    let sampled = normalized.transformed(by: CGAffineTransform(
      scaleX: CGFloat(width) / image.extent.width,
      y: CGFloat(height) / image.extent.height))
      .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    var raw = [Float](repeating: 0, count: width * height * 4)
    raw.withUnsafeMutableBytes { bytes in
      guard let address = bytes.baseAddress else { return }
      processingContext.render(
        sampled,
        toBitmap: address,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: sampled.extent,
        format: .RGBAf,
        colorSpace: workingColorSpace
      )
    }
    try Task.checkCancellation()
    // `CIContext.render(toBitmap:)` writes the image's top row first, while
    // `RasterMask` follows the document's canonical bottom-left, y-up space.
    // Normalize that boundary once before either locating the seed or building
    // runs; otherwise the sampled pixels and resulting coverage are reflected
    // vertically when the mask renderer replays them.
    Self.flipMaskCaptureRows(&raw, width: width, height: height)
    let seedX = min(max(Int((x * Double(width)).rounded(.down)), 0), width - 1)
    let seedY = min(max(Int((y * Double(height)).rounded(.down)), 0), height - 1)
    let seedOffset = (seedY * width + seedX) * 4
    raw.replaceSubrange(seedOffset..<(seedOffset + 4), with: exactSeed)
    return (
      width, height, raw, seedX, seedY
    )
  }

  /// Pixel-driven selections are explicit proxy work, not a canvas preview.
  /// Bound their readback while preserving aspect ratio; the captured raster
  /// scales back over the canonical canvas when the shared mask renderer uses
  /// it. This lets large RAW files use the tool without allocating a complete
  /// RGBAf sensor-sized readback.
  static func boundedMaskCaptureSize(width: Int, height: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { return (0, 0) }
    // At most one run can be emitted per analysed pixel. Keeping the proxy at
    // or below the persisted run limit prevents a valid click from disappearing
    // merely because photographic noise fragmented its soft coverage.
    let maximumAnalysisAxis = 2_048
    let maximumAnalysisPixels = PaintOperationLimits.maximumRasterRuns
    let axisScale = min(
      Double(maximumAnalysisAxis) / Double(width),
      Double(maximumAnalysisAxis) / Double(height))
    let pixelScale = sqrt(
      Double(maximumAnalysisPixels)
        / (Double(width) * Double(height)))
    let scale = min(1, min(axisScale, pixelScale))
    return (
      max(Int((Double(width) * scale).rounded(.down)), 1),
      max(Int((Double(height) * scale).rounded(.down)), 1)
    )
  }

  static func flipMaskCaptureRows(
    _ pixels: inout [Float],
    width: Int,
    height: Int
  ) {
    let valuesPerRow = width * 4
    guard width > 0, height > 1, pixels.count == valuesPerRow * height else { return }
    for topRow in 0..<(height / 2) {
      let bottomRow = height - topRow - 1
      let topOffset = topRow * valuesPerRow
      let bottomOffset = bottomRow * valuesPerRow
      for column in 0..<valuesPerRow {
        pixels.swapAt(topOffset + column, bottomOffset + column)
      }
    }
  }

  /// Renders and encodes one export exactly as a preset describes it.
  ///
  /// The request carries the recipe as it stood when the export was queued, so
  /// a queued job keeps exporting what the user asked for while they go on
  /// editing. Pixels are written to a temporary file beside the destination and
  /// moved into place only after a final cancellation check, so a cancelled or
  /// failed job never leaves a partial file behind.
  public func export(
    _ request: RenderRequest,
    preset: ExportPreset,
    to destination: URL,
    progress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws {
    let fullRequest = RenderRequest(
      documentID: request.documentID,
      revision: request.revision,
      contentRevision: request.contentRevision,
      rawInputs: request.rawInputs,
      rasterAssets: request.rasterAssets,
      recipe: request.recipe,
      quality: .full
    )
    progress(0.05)
    let frame = try await render(fullRequest)
    try Task.checkCancellation()
    progress(0.55)

    var image = CIImage(ioSurface: frame.surface, options: [.colorSpace: workingColorSpace])

    image = resized(image, using: preset.resize)
    try Task.checkCancellation()
    image = sharpened(image, using: preset.sharpening)
    image = watermarked(image, using: preset.watermark)
    image = normalized(image)
    // The generation features are deferred, so there is no generation metadata
    // to embed yet. The preset records the user's answer; this path writes
    // nothing for it rather than inventing a format to migrate later.
    if preset.embedsGenerationMetadata {
      logger.info("Generation metadata requested, but no generation recipe exists to embed yet.")
    }
    try Task.checkCancellation()
    progress(0.7)

    // The preset's color space is what the user asked this file to be; the
    // project's own export color space stands in when a preset predates it.
    let outputColorSpace = try exportColorSpace(for: preset.colorSpace)
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(
        ".pixeltje-export-\(UUID().uuidString).\(preset.format.fileExtension)")
    do {
      try write(image, format: preset, colorSpace: outputColorSpace, to: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw PixeltjeMacError("Export failed", error.localizedDescription)
    }
    progress(0.95)

    // Last chance to abandon the work: a cancelled job must not publish a file.
    if Task.isCancelled {
      try? FileManager.default.removeItem(at: temporary)
      throw CancellationError()
    }
    do {
      let manager = FileManager.default
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw PixeltjeMacError(
        "Export failed",
        "Could not write \(destination.lastPathComponent): \(error.localizedDescription)"
      )
    }
    progress(1)
  }

  private func write(
    _ image: CIImage,
    format preset: ExportPreset,
    colorSpace: CGColorSpace,
    to destination: URL
  ) throws {
    var options: [CIImageRepresentationOption: Any] = [:]
    if preset.format.usesQuality {
      options[
        CIImageRepresentationOption(
          rawValue: kCGImageDestinationLossyCompressionQuality as String)
      ] = preset.clampedQuality
    }
    let pixelFormat: CIFormat = preset.bitDepth == .sixteen ? .RGBA16 : .RGBA8
    switch preset.format {
    case .tiff:
      try processingContext.writeTIFFRepresentation(
        of: image,
        to: destination,
        format: pixelFormat,
        colorSpace: colorSpace,
        options: options
      )
    case .png:
      try processingContext.writePNGRepresentation(
        of: image,
        to: destination,
        format: pixelFormat,
        colorSpace: colorSpace,
        options: options
      )
    case .jpeg:
      try processingContext.writeJPEGRepresentation(
        of: image,
        to: destination,
        colorSpace: colorSpace,
        options: options
      )
    case .heif:
      try processingContext.writeHEIFRepresentation(
        of: image,
        to: destination,
        format: .RGBA8,
        colorSpace: colorSpace,
        options: options
      )
    }
  }

  /// Scales the export to the preset's target size, keeping the aspect ratio.
  private func resized(_ image: CIImage, using resize: ExportResize) -> CIImage {
    let extent = image.extent
    guard !extent.isEmpty else { return image }
    guard
      let target = resize.targetSize(
        sourceWidth: Int(extent.width.rounded()),
        sourceHeight: Int(extent.height.rounded())
      )
    else { return image }
    let scale = Double(target.height) / Double(extent.height)
    let aspect = (Double(target.width) / Double(extent.width)) / scale
    let scaled = image.applyingFilter(
      "CILanczosScaleTransform",
      parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: aspect]
    )
    return normalized(scaled).cropped(
      to: CGRect(x: 0, y: 0, width: target.width, height: target.height)
    )
  }

  /// Applies output sharpening, after the resize, in output pixels.
  private func sharpened(_ image: CIImage, using sharpening: ExportSharpening) -> CIImage {
    guard sharpening.isEnabled else { return image }
    return image.applyingFilter(
      "CIUnsharpMask",
      parameters: [
        kCIInputRadiusKey: sharpening.radius,
        kCIInputIntensityKey: sharpening.effectiveIntensity,
      ]
    )
  }

  /// Draws the text watermark over the exported image.
  ///
  /// The text is rasterized with Core Text into an sRGB bitmap, so Core Image
  /// converts it into the working space like any other tagged source instead of
  /// having its numbers reinterpreted.
  private func watermarked(_ image: CIImage, using watermark: ExportWatermark) -> CIImage {
    guard watermark.isDrawable else { return image }
    let extent = image.extent
    guard !extent.isEmpty else { return image }
    let longEdge = max(extent.width, extent.height)
    let pointSize = max(8, longEdge * watermark.sizePercent / 100)
    guard let text = WatermarkTextImage.make(watermark.text, pointSize: pointSize) else {
      logger.error("Watermark text could not be rasterized; exporting without it.")
      return image
    }
    let inset = longEdge * watermark.insetPercent / 100
    let anchor = watermark.position.anchor
    let available = CGSize(
      width: max(0, extent.width - 2 * inset - text.extent.width),
      height: max(0, extent.height - 2 * inset - text.extent.height)
    )
    let x = extent.minX + inset + available.width * anchor.x
    let y = extent.minY + inset + available.height * anchor.y
    let faded = text.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputAVector": CIVector(
          x: 0, y: 0, z: 0, w: CGFloat(max(0, min(1, watermark.opacity))))
      ]
    )
    return
      faded
      .transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
      .composited(over: image)
      .cropped(to: extent)
  }

  /// One placed image layer, with its link already resolved to a file URL.
  private struct PlacedImage {
    var url: URL
    var source: SourceReference
    var frame: LayerFrame
    var adjustments: LayerAdjustments
  }

  /// The render extent and how canvas pixels map into it.
  private struct CompositeSpace {
    var extent: CGRect
    var scaleX: CGFloat
    var scaleY: CGFloat

    /// A canvas-pixel frame in render pixels.
    func rect(for frame: LayerFrame) -> CGRect {
      CGRect(
        x: extent.minX + frame.x * scaleX,
        y: extent.minY + frame.y * scaleY,
        width: frame.width * scaleX,
        height: frame.height * scaleY
      )
    }
  }

  /// The enabled image layers anywhere in the tree, with their links resolved.
  ///
  /// Resolution happens before any pixels are touched so a missing or renamed
  /// file fails as one clear message instead of a half-drawn canvas.
  private func resolveImageLayers(_ layerStack: LayerStackRecipe)
    throws -> [ProjectLayerID: PlacedImage]
  {
    var placed: [ProjectLayerID: PlacedImage] = [:]
    for entry in layerStack.flattenedLayers where entry.isEffectivelyEnabled {
      guard let image = entry.layer.imageLayer, !image.frame.isEmpty else { continue }
      placed[entry.id] = PlacedImage(
        url: try SourceReferenceFactory.resolve(image.source),
        source: image.source,
        frame: image.frame,
        adjustments: entry.layer.adjustments
      )
    }
    return placed
  }

  /// Resolves every enabled project-local raster before composition so a
  /// missing or damaged package asset fails the whole frame explicitly.
  private struct ResolvedRasterLayers {
    var images: [ProjectLayerID: CIImage]
    var differenceSources: [ProjectLayerID: CIImage]
    var backingPixels: [Data]
    /// Healed patches, keyed by content identity rather than by layer: one
    /// paint layer carries a run of them, and two identical heals share an
    /// asset the way any other project raster does.
    var healPatches: [RasterAssetID: CIImage]
  }

  private func resolveRasterLayers(
    _ layerStack: LayerStackRecipe,
    assets: [RasterAssetID: Data]
  ) throws -> ResolvedRasterLayers {
    var resolved: [ProjectLayerID: CIImage] = [:]
    var differenceSources: [ProjectLayerID: CIImage] = [:]
    var backingPixels: [Data] = []
    var healPatches: [RasterAssetID: CIImage] = [:]
    for entry in layerStack.flattenedLayers where entry.isEffectivelyEnabled {
      switch entry.layer.content {
      case .raster(let raster) where !raster.frame.isEmpty:
        guard let compressed = assets[raster.asset.id] else {
          throw PixeltjeMacError(
            "Raster asset missing",
            "\(entry.layer.name) refers to pixels that are not present in the project package."
          )
        }
        resolved[entry.id] = try loadRaster(raster.asset, compressedPixels: compressed)
        if let reference = raster.differenceSource {
          guard let compressedSource = assets[reference.id] else {
            throw PixeltjeMacError(
              "Difference Key source missing",
              "\(entry.layer.name) refers to comparison pixels missing from the project package.")
          }
          differenceSources[entry.id] = try loadRaster(reference, compressedPixels: compressedSource)
        }
      case .generatedInpaint(let inpaint) where !inpaint.frame.isEmpty:
        let generated = try generatedInpaintImage(inpaint, assets: assets)
        resolved[entry.id] = generated.image
        backingPixels.append(generated.pixels)
      case .paint(let paint) where !paint.heals.isEmpty:
        for heal in paint.heals where heal.isRenderable {
          guard healPatches[heal.patch.id] == nil else { continue }
          guard let compressed = assets[heal.patch.id] else {
            throw PixeltjeMacError(
              "Heal patch missing",
              "\(entry.layer.name) refers to healed pixels that are not in the project package."
            )
          }
          healPatches[heal.patch.id] = try loadRaster(
            heal.patch, compressedPixels: compressed)
        }
      default:
        continue
      }
    }
    return ResolvedRasterLayers(
      images: resolved, differenceSources: differenceSources,
      backingPixels: backingPixels, healPatches: healPatches)
  }

  /// Composites one level of the layer tree, bottom to top, over a backdrop.
  ///
  /// This is the whole stack at the top level and a group's children below
  /// it. A group is composited onto a transparent canvas of its own first and
  /// then blended as one layer, so its blend mode and opacity apply to the
  /// group as a whole and an adjustment inside it reaches only the siblings
  /// beneath it. Vector artwork enters here as ordinary layer pixels, preserving
  /// its exact position among raster, text, adjustment and group layers.
  private func composite(
    _ layers: [ProjectLayer],
    over backdrop: CIImage,
    in space: CompositeSpace,
    developedRaws: [ProjectLayerID: CIImage],
    placedImages: [ProjectLayerID: PlacedImage],
    projectRasters: [ProjectLayerID: CIImage],
    differenceSources: [ProjectLayerID: CIImage] = [:],
    healPatches: [RasterAssetID: CIImage],
    layerCropFrames: [ProjectLayerID: LayerFrame],
    identitySeed: String,
    inpaintingMaskCapture: InpaintingMaskCaptureContext? = nil,
    differencePreview: DifferenceKeyPreviewCapture? = nil
  ) throws -> CIImage {
    var output = backdrop
    for layer in layers.reversed() where layer.isEnabled {
      try Task.checkCancellation()
      var source: CIImage?
      var keyReference: CIImage?
      switch layer.content {
      case .canvas:
        continue
      case .vector(let vector):
        source = try VectorArtworkRenderer.makeImage(
          vectorLayer: vector,
          width: Int(space.extent.width.rounded(.up)),
          height: Int(space.extent.height.rounded(.up)),
          workingColorSpace: workingColorSpace)
      case .developedRaw(let raw):
        guard let developed = developedRaws[layer.id] else { continue }
        if raw.needsInitialPlacement == true {
          source = initiallyPlacedRaw(developed, in: space)
        } else {
          source = raw.frame.map { place(developed, in: $0, space: space) } ?? developed
        }
      case .image:
        source = try placedImages[layer.id].flatMap { try placedImage($0, in: space) }
      case .raster(let raster):
        source = projectRasters[layer.id].flatMap { place($0, in: raster.frame, space: space) }
        keyReference = differenceSources[layer.id].flatMap {
          place($0, in: raster.frame, space: space)
        }
      case .generatedInpaint(let inpaint):
        source = projectRasters[layer.id].flatMap { place($0, in: inpaint.frame, space: space) }
      case .paint(let paint):
        source = try paintImage(
          paint,
          cacheID: "paint-layer:\(layer.id.rawValue)",
          in: space,
          sourceIdentity: "\(identitySeed)|paint:\(layer.id.rawValue)",
          healPatches: healPatches
        )
      case .text(let text):
        source = try TextLayerRenderer.makeImage(
          text,
          target: space.rect(for: text.frame),
          scale: space.scaleY,
          workingColorSpace: workingColorSpace
        )
      case .group(let group):
        source = try composite(
          group.children,
          over: CIImage(color: .clear).cropped(to: space.extent),
          in: space,
          developedRaws: developedRaws,
          placedImages: placedImages,
          projectRasters: projectRasters,
          differenceSources: differenceSources,
          healPatches: healPatches,
          layerCropFrames: layerCropFrames,
          identitySeed: identitySeed,
          inpaintingMaskCapture: inpaintingMaskCapture,
          differencePreview: differencePreview
        )
      case .adjustment(let adjustment):
        source = apply(adjustment, to: output)
      }
      // An empty paint layer has no color image for the ordinary compositor,
      // but its layer/local mask is still a complete reusable recipe. Give
      // that selected mask transparent owner-stage pixels so geometric and
      // painted coverage can be captured, then avoid contributing the
      // synthetic image to the visible composite below.
      let usesSyntheticMaskSource = source == nil && inpaintingMaskCapture?.layerID == layer.id
      if usesSyntheticMaskSource {
        source = CIImage(color: .clear).cropped(to: space.extent)
      }
      // Per-mask adjustments: each mask on this layer changes only the pixels
      // it selects, before the layer is blended into what is beneath it. The
      // masks belong to the layer, so they travel with it.
      if var masked = source, !layer.activeMasks.isEmpty {
        if let capture = inpaintingMaskCapture,
          capture.kind == .localMask,
          capture.layerID == layer.id
        {
          // A local mask reads the same layer-stage pixels as it does during a
          // normal render: earlier local adjustments have run, later ones have
          // not. A mask without an adjustment is still a valid explicit
          // inpainting source, so it is evaluated even though it does not alter
          // the displayed layer by itself.
          for (maskIndex, mask) in layer.activeMasks.enumerated() {
            let isCaptureTarget = capture.capturesLocalMask(mask, on: layer)
            guard isCaptureTarget || mask.adjustment != nil else { continue }
            guard
              let coverage = try maskRenderer.evaluate(
                mask,
                in: MaskSpace(extent: space.extent, pixelsPerCanvasPixel: space.scaleY),
                source: masked,
                sourceIdentity: "\(identitySeed)|\(layer.id.rawValue)",
                strokeSurfaceCoverage: { surface in
                  return try self.paintedMaskCoverage(
                    surface,
                    cacheID: "local-mask:\(layer.id.rawValue):\(maskIndex)",
                    in: space)
                })
            else { continue }
            if isCaptureTarget { capture.coverage = coverage }
            if let adjustment = mask.adjustment {
              let adjusted = apply(adjustment, to: masked)
              masked = adjusted.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                  kCIInputBackgroundImageKey: masked,
                  kCIInputMaskImageKey: maskRenderer.maskImage(from: coverage),
                ]
              ).cropped(to: space.extent)
            }
          }
        } else {
          var paintedMaskIndex = 0
          masked = try maskRenderer.applyAdjustments(
            layer.activeMasks,
            to: masked,
            in: MaskSpace(extent: space.extent, pixelsPerCanvasPixel: space.scaleY),
            sourceIdentity: "\(identitySeed)|\(layer.id.rawValue)",
            strokeSurfaceCoverage: { surface in
              defer { paintedMaskIndex += 1 }
              return try self.paintedMaskCoverage(
                surface,
                cacheID: "local-mask:\(layer.id.rawValue):\(paintedMaskIndex)",
                in: space)
            },
            adjust: { adjustment, image in self.apply(adjustment, to: image) }
          )
        }
        source = masked
      }
      guard let source else { continue }
      // A layer's develop adjustments belong to that layer and run on its own
      // pixels, at their placed size, before it joins the composite. A neutral
      // recipe adds no filter at all.
      let developed =
        layer.supportsAdjustments
        ? LayerAdjustmentGraph.apply(
          layer.adjustments, to: source, pixelScale: Double(space.scaleX))
        : source
      var layerOutput = developed
      if let layerMask = layer.layerMask,
        layerMask.isEnabled,
        layerMask.isEvaluable,
        let coverage = try maskRenderer.evaluate(
          layerMask,
          in: MaskSpace(extent: space.extent, pixelsPerCanvasPixel: space.scaleY),
          source: developed,
          sourceIdentity: "\(identitySeed)|layer-mask|\(layer.id.rawValue)",
          strokeSurfaceCoverage: { surface in
            try self.paintedMaskCoverage(
              surface,
              cacheID: "layer-mask:\(layer.id.rawValue):\(layerMask.id.rawValue)",
              in: space)
          })
      {
        if inpaintingMaskCapture?.capturesLayerMask(layerMask, on: layer) == true {
          inpaintingMaskCapture?.coverage = coverage
        }
        layerOutput = developed.applyingFilter(
          "CIBlendWithMask",
          parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: space.extent),
            kCIInputMaskImageKey: maskRenderer.maskImage(from: coverage),
          ]).cropped(to: space.extent)
      }
      if let crop = layer.crop, let frame = layerCropFrames[layer.id] {
        layerOutput = applyLayerCrop(crop, to: layerOutput, frame: frame, in: space)
      }
      if let capture = inpaintingMaskCapture,
        capture.transformPath.contains(layer.id),
        var coverage = capture.coverage
      {
        // Only the owning layer's crop is part of the mask's own spatial
        // contract. Ancestor masks and compositing properties are unrelated;
        // ancestor transforms still move the child in the normal hierarchy.
        if layer.id == capture.layerID,
          let crop = layer.crop,
          let frame = layerCropFrames[layer.id]
        {
          coverage = applyLayerCrop(crop, to: coverage, frame: frame, in: space)
        }
        capture.coverage = transformed(coverage, by: layer.transform, in: space)
      }
      if usesSyntheticMaskSource { continue }
      output = try blend(
        transformed(layerOutput, by: layer.transform, in: space),
        over: output,
        with: layer.compositing,
        in: space,
        differenceReference: keyReference.map { transformed($0, by: layer.transform, in: space) },
        layerID: layer.id,
        differencePreview: differencePreview,
        sourceIdentity: identitySeed
      )
    }
    // Keep group intermediates in their declared coordinate space. Cropping
    // here would discard a child that an ancestor later moves back on canvas.
    // The render entry point clips once, after the complete hierarchy.
    return output
  }

  /// Applies a placed layer's crop before its non-destructive transform. The
  /// Core Image extent keeps its canvas origin, so later placement and parent
  /// composition do not stretch the cropped pixels back over the old frame.
  private func applyLayerCrop(
    _ crop: CropRecipe,
    to image: CIImage,
    frame: LayerFrame,
    in space: CompositeSpace
  ) -> CIImage {
    guard !crop.isFullFrame else { return image }
    // Measure against the layer's whole frame, never the part of it that has
    // pixels here: a layer mask trims a layer that overhangs the canvas, and
    // the crop must still keep the rectangle the Crop tool drew over the frame.
    let reference = space.rect(for: frame)
    guard !reference.isEmpty else { return image }
    return applyStraightenAndCrop(crop, to: image.cropped(to: reference), reference: reference)
  }

  private func paintImage(
    _ paint: PaintLayerRecipe,
    cacheID: String,
    in space: CompositeSpace,
    sourceIdentity: String,
    healPatches: [RasterAssetID: CIImage]
  ) throws -> CIImage? {
    let width = Int(space.extent.width.rounded(.up))
    let height = Int(space.extent.height.rounded(.up))
    var output = CIImage(color: .clear).cropped(to: space.extent)
    var hasContent = false

    if !paint.surface.strokes.isEmpty {
      let scaled = paint.surface.scaled(byX: Double(space.scaleX), y: Double(space.scaleY))
      if let strokes = try brushRenderer.colorImage(
        for: StrokeSurfaceRequest(cacheID: cacheID, recipe: scaled, width: width, height: height),
        workingColorSpace: workingColorSpace
      ) {
        output = strokes.composited(over: output)
        hasContent = true
      }
    }

    for (index, fill) in paint.fills.enumerated() {
      guard let coverage = try maskRenderer.evaluate(
        fill.coverage,
        in: MaskSpace(extent: space.extent, pixelsPerCanvasPixel: space.scaleY),
        source: nil,
        sourceIdentity: "\(sourceIdentity)|fill:\(index)"
      ) else { continue }
      // Write the stored straight linear components as working-space numbers.
      // Constructing a profile-tagged CIColor for an extended primary can be
      // rejected by Core Image on some SDK/runtime combinations; a matrix over
      // opaque white is explicit and preserves HDR component values.
      let solid = CIImage(color: .white).applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: fill.color.red),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: fill.color.green),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: fill.color.blue),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: fill.color.alpha),
        ]).cropped(to: space.extent)
      let clipped = solid.applyingFilter(
        "CIBlendWithMask",
        parameters: [
          kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: space.extent),
          kCIInputMaskImageKey: maskRenderer.maskImage(from: coverage),
        ])
      output = clipped.composited(over: output)
      hasContent = true
    }

    for (index, gradient) in paint.gradients.enumerated() {
      let start = CGPoint(
        x: space.extent.minX + CGFloat(gradient.start.x) * space.extent.width,
        y: space.extent.minY + CGFloat(gradient.start.y) * space.extent.height)
      let end = CGPoint(
        x: space.extent.minX + CGFloat(gradient.end.x) * space.extent.width,
        y: space.extent.minY + CGFloat(gradient.end.y) * space.extent.height)
      let first = workingCIColor(gradient.startColor)
      let second = workingCIColor(gradient.endColor)
      let generated: CIImage?
      switch gradient.kind {
      case .linear:
        generated = CIFilter(name: "CILinearGradient", parameters: [
          "inputPoint0": CIVector(cgPoint: start), "inputPoint1": CIVector(cgPoint: end),
          "inputColor0": first, "inputColor1": second,
        ])?.outputImage
      case .radial:
        generated = CIFilter(name: "CIRadialGradient", parameters: [
          "inputCenter": CIVector(cgPoint: start), "inputRadius0": 0,
          "inputRadius1": max(hypot(end.x - start.x, end.y - start.y), 0.5),
          "inputColor0": first, "inputColor1": second,
        ])?.outputImage
      }
      guard var generated = generated?.cropped(to: space.extent) else { continue }
      if let selection = gradient.coverage,
        let coverage = try maskRenderer.evaluate(
          selection,
          in: MaskSpace(extent: space.extent, pixelsPerCanvasPixel: space.scaleY),
          source: nil,
          sourceIdentity: "\(sourceIdentity)|gradient:\(index)"
        )
      {
        generated = generated.applyingFilter(
          "CIBlendWithMask",
          parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: space.extent),
            kCIInputMaskImageKey: maskRenderer.maskImage(from: coverage),
          ])
      }
      output = generated.composited(over: output)
      hasContent = true
    }

    // Healed patches last, in commit order. Each is an ordinary placed raster:
    // its painted coverage was premultiplied into its alpha when it was
    // solved, so there is no mask to evaluate here and a long retouching
    // session costs one composited image per patch rather than one
    // canvas-sized mask render per patch per frame.
    for heal in paint.heals {
      guard heal.isRenderable, let patch = healPatches[heal.patch.id],
        let placed = place(patch, in: heal.frame, space: space)
      else { continue }
      output = placed.cropped(to: space.rect(for: heal.frame)).composited(over: output)
      hasContent = true
    }
    return hasContent ? output.cropped(to: space.extent) : nil
  }

  private func workingCIColor(_ color: LinearRGBAColor) -> CIColor {
    guard let value = CGColor(
      colorSpace: workingColorSpace,
      components: [color.red, color.green, color.blue, color.alpha]
    ) else {
      return CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
    return CIColor(cgColor: value)
  }

  private func paintedMaskCoverage(
    _ surface: StrokeSurfaceRecipe,
    cacheID: String,
    in space: CompositeSpace
  ) throws -> CIImage? {
    let scaled = StrokeSurfaceRecipe(
      kind: .mask,
      initialCoverage: surface.initialCoverage,
      strokes: surface.strokes
    ).scaled(byX: Double(space.scaleX), y: Double(space.scaleY))
    return try brushRenderer.maskCoverageImage(
      for: StrokeSurfaceRequest(
        cacheID: cacheID,
        recipe: scaled,
        width: Int(space.extent.width.rounded(.up)),
        height: Int(space.extent.height.rounded(.up))))
  }

  /// Puts one layer's pixels over the backdrop with its blend mode, opacity
  /// and fill.
  ///
  /// Fill scales the layer's own alpha before it is blended, which is what
  /// leaves layer styles untouched once they exist. Opacity then fades the
  /// blended result back toward the backdrop, so it applies to everything the
  /// layer contributes, whatever the blend mode did.
  private func blend(
    _ source: CIImage,
    over backdrop: CIImage,
    with compositing: LayerCompositing,
    in space: CompositeSpace,
    differenceReference: CIImage? = nil,
    layerID: ProjectLayerID? = nil,
    differencePreview: DifferenceKeyPreviewCapture? = nil,
    sourceIdentity: String = ""
  ) throws -> CIImage {
    var layer = source
    if compositing.fill < 1 {
      layer = layer.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(compositing.fill))
        ]
      )
    }
    var blended: CIImage
    if compositing.blendMode == .differenceKey {
      let reference: CIImage
      if compositing.differenceReference == .generationInput {
        guard let differenceReference else {
          throw PixeltjeMacError(
            "Difference Key source unavailable",
            "The selected layer has no frozen generation input. Choose Current Backdrop instead.")
        }
        reference = differenceReference
      } else {
        reference = backdrop
      }
      var matte = try differenceKeyMatte(
        source, reference: reference, compositing: compositing, in: space)
      let maskSpace = MaskSpace(extent: space.extent, pixelsPerCanvasPixel: space.scaleY)
      if let reveal = compositing.differenceRevealMask, reveal.isEnabled,
        let coverage = try maskRenderer.evaluate(
          reveal, in: maskSpace, source: source,
          sourceIdentity: "\(sourceIdentity)|difference-reveal|\(layerID?.rawValue ?? "")",
          strokeSurfaceCoverage: { surface in
            try self.paintedMaskCoverage(surface,
              cacheID: "difference-reveal:\(layerID?.rawValue ?? "")",
              in: space)
          })
      {
        matte = coverage.applyingFilter("CILightenBlendMode",
          parameters: [kCIInputBackgroundImageKey: matte])
      }
      if let protect = compositing.differenceProtectMask, protect.isEnabled,
        let coverage = try maskRenderer.evaluate(
          protect, in: maskSpace, source: source,
          sourceIdentity: "\(sourceIdentity)|difference-protect|\(layerID?.rawValue ?? "")",
          strokeSurfaceCoverage: { surface in
            try self.paintedMaskCoverage(surface,
              cacheID: "difference-protect:\(layerID?.rawValue ?? "")",
              in: space)
          })
      {
        let inverse = coverage.applyingFilter("CIColorInvert")
        matte = matte.applyingFilter("CIMultiplyBlendMode",
          parameters: [kCIInputBackgroundImageKey: inverse])
      }
      if layerID == differencePreview?.layerID {
        differencePreview?.image = matte.cropped(to: space.extent)
      }
      blended = layer.composited(over: backdrop).applyingFilter(
        "CIBlendWithMask",
        parameters: [
          kCIInputBackgroundImageKey: backdrop,
          kCIInputMaskImageKey: matte,
        ])
    } else if let filterName = compositing.blendMode.coreImageFilterName {
      blended = layer.applyingFilter(
        filterName,
        parameters: [kCIInputBackgroundImageKey: backdrop]
      )
    } else {
      blended = layer.composited(over: backdrop)
    }
    if compositing.opacity < 1 {
      blended = blended.applyingFilter(
        "CIMix",
        parameters: [
          kCIInputBackgroundImageKey: backdrop,
          "inputAmount": compositing.opacity,
        ]
      )
    }
    return blended
  }

  /// Spatial difference keying: compare the adjusted foreground with the
  /// current backdrop in linear P3, average color change over a neighborhood,
  /// then turn that signal into a soft matte. A small expansion and feather
  /// keep the replacement across the low-contrast edges of a changed region.
  private func differenceKeyMatte(
    _ layer: CIImage,
    reference: CIImage,
    compositing: LayerCompositing,
    in space: CompositeSpace
  ) throws -> CIImage {
    let extent = layer.extent.union(reference.extent)
    let radius = compositing.differenceRadius * Double(space.scaleY)
    let driftRadius = max(12 * Double(space.scaleY), radius * 6)
    let layerLow = layer.clampedToExtent().applyingFilter(
      "CIGaussianBlur", parameters: [kCIInputRadiusKey: driftRadius]).cropped(to: extent)
    let referenceLow = reference.clampedToExtent().applyingFilter(
      "CIGaussianBlur", parameters: [kCIInputRadiusKey: driftRadius]).cropped(to: extent)
    guard let signal = differenceSignalKernel?.apply(extent: extent, arguments: [
      layer, reference, layerLow, referenceLow,
      compositing.differenceStructure / 100,
      compositing.differenceDrift / 100,
    ]) else {
      throw PixeltjeMacError(
        "Difference Key unavailable", "The perceptual comparison could not be rendered.")
    }
    let localChange = radius > 0
      ? signal.clampedToExtent().applyingFilter(
        "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
      : signal

    // The broad signal catches coherent edits; a high-confidence pixel can
    // survive smoothing so a small but definite edit is not erased.
    let fineStrength = compositing.differenceFineDetail / 100
    let fine = signal.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: fineStrength, y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: fineStrength, y: 0, z: 0, w: 0),
      "inputBVector": CIVector(x: fineStrength, y: 0, z: 0, w: 0),
    ])
    let multiscale = localChange.applyingFilter("CILightenBlendMode",
      parameters: [kCIInputBackgroundImageKey: fine])

    // Zero softness is a true binary cutoff. Positive values retain the
    // existing smooth transition; edge feathering remains a separate control.
    guard let core = differenceThresholdKernel?.apply(extent: extent, arguments: [
      multiscale, compositing.differenceCutoff / 100,
      compositing.differenceSoftness / 100,
    ]) else {
      throw PixeltjeMacError(
        "Difference Key unavailable", "The difference cutoff could not be rendered.")
    }
    let grow = compositing.differenceGrow * Double(space.scaleY)
    let shaped: CIImage
    if grow > 0 {
      shaped = core.applyingFilter("CIMorphologyMaximum",
        parameters: [kCIInputRadiusKey: grow])
    } else if grow < 0 {
      shaped = core.applyingFilter("CIMorphologyMinimum",
        parameters: [kCIInputRadiusKey: -grow])
    } else {
      shaped = core
    }
    let feather = compositing.differenceFeather * Double(space.scaleY)
    guard feather > 0 else { return shaped.cropped(to: extent) }
    let edgeMap = layer.applyingFilter("CIEdges", parameters: [
      kCIInputIntensityKey: 0.5,
    ]).applyingFilter("CIColorInvert").cropped(to: extent)
    return shaped.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
      kCIInputRadiusKey: feather,
      "inputMask": edgeMap,
    ]).cropped(to: extent)
  }

  /// Applies the affine part of a layer transform in render coordinates. Layer
  /// recipes are in full canvas pixels while proxy frames have their own scale,
  /// so this is S · M · S⁻¹ rather than a scaled translation.
  private func transformed(
    _ image: CIImage, by transform: LayerTransform?, in space: CompositeSpace
  ) -> CIImage {
    guard let transform, !transform.isIdentity else { return image }
    // Perspective and mesh are validated/persisted now. Their sampling path is
    // intentionally kept separate from this affine adapter; a later kernel can
    // replace it without changing authoring coordinates or saved parameters.
    let perspectived = perspectiveTransformed(image, transform: transform, in: space)
    let radians = transform.rotationDegrees * .pi / 180
    let cosine = cos(radians)
    let sine = sin(radians)
    let a = cosine * transform.scaleX
    let b = sine * transform.scaleX
    let c = (cosine * transform.shearX - sine) * transform.scaleY
    let d = (sine * transform.shearX + cosine) * transform.scaleY
    let tx = transform.position.x - a * transform.anchor.x - c * transform.anchor.y
    let ty = transform.position.y - b * transform.anchor.x - d * transform.anchor.y
    let sx = Double(space.scaleX)
    let sy = Double(space.scaleY)
    guard sx > 0, sy > 0 else { return image }
    let matrix = CGAffineTransform(
      a: a, b: b * sy / sx, c: c * sx / sy, d: d,
      tx: tx * sx, ty: ty * sy
    )
    return perspectived.transformed(by: matrix)
  }

  private func perspectiveTransformed(
    _ image: CIImage, transform: LayerTransform, in space: CompositeSpace
  ) -> CIImage {
    guard let corners = transform.perspective, !corners.isIdentity else { return image }
    let reference = transform.referenceRect
    guard !reference.isEmpty else { return image }
    func point(_ x: Double, _ y: Double, _ offset: PixelPoint) -> CIVector {
      CIVector(
        x: (x + offset.x * reference.width) * Double(space.scaleX),
        y: (y + offset.y * reference.height) * Double(space.scaleY)
      )
    }
    return image.applyingFilter(
      "CIPerspectiveTransform",
      parameters: [
        "inputTopLeft": point(reference.x, reference.y + reference.height, corners.topLeft),
        "inputTopRight": point(
          reference.x + reference.width, reference.y + reference.height, corners.topRight),
        "inputBottomRight": point(reference.x + reference.width, reference.y, corners.bottomRight),
        "inputBottomLeft": point(reference.x, reference.y, corners.bottomLeft),
      ]
    )
  }

  private func apply(_ adjustment: AdjustmentRecipe, to image: CIImage) -> CIImage {
    LayerAdjustmentGraph.apply(adjustment, to: image)
  }

  /// A placed image scaled and moved into its frame.
  private func placedImage(_ placed: PlacedImage, in space: CompositeSpace) throws -> CIImage? {
    let source = normalized(try loadImage(placed))
    guard !source.extent.isEmpty else { return nil }
    return place(source, in: placed.frame, space: space)
  }

  /// Scales a complete, already-developed raster into its layer frame. RAW and
  /// ordinary image layers share this geometry; the only difference is how the
  /// source image arrived here.
  private func place(_ source: CIImage, in frame: LayerFrame, space: CompositeSpace) -> CIImage? {
    let target = space.rect(for: frame)
    guard !target.isEmpty else { return nil }
    return
      source
      .transformed(
        by: CGAffineTransform(
          scaleX: target.width / source.extent.width,
          y: target.height / source.extent.height
        )
      )
      .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
  }

  /// The first visible frame of an opt-in RAW layer. Its persisted placement
  /// is still waiting for the decoder inspection to reach the document, so fit
  /// the already-developed image into the known canvas without another
  /// geometry authority or a temporary stretched image.
  private func initiallyPlacedRaw(_ source: CIImage, in space: CompositeSpace) -> CIImage? {
    guard !source.extent.isEmpty, !space.extent.isEmpty else { return nil }
    let scale = min(
      space.extent.width / source.extent.width,
      space.extent.height / source.extent.height
    )
    guard scale.isFinite, scale > 0 else { return nil }
    let width = source.extent.width * scale
    let height = source.extent.height * scale
    return
      source
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .transformed(
        by: CGAffineTransform(
          translationX: space.extent.midX - width / 2,
          y: space.extent.midY - height / 2
        )
      )
  }

  private func loadImage(_ placed: PlacedImage) throws -> CIImage {
    let key = placed.url.standardizedFileURL.path
    if let entry = imageLayerCache[key], entry.fingerprint == placed.source.fingerprint {
      return entry.image
    }
    guard
      let image = CIImage(
        contentsOf: placed.url,
        options: [.applyOrientationProperty: true]
      )
    else {
      throw PixeltjeMacError(
        "Image unavailable",
        "Core Image cannot open the linked image \(placed.source.originalFilename). Relink it or remove the layer."
      )
    }
    imageLayerCache[key] = ImageLayerCacheEntry(
      fingerprint: placed.source.fingerprint,
      image: image
    )
    return image
  }

  private func loadRaster(
    _ reference: RasterAssetReference,
    compressedPixels: Data
  ) throws -> CIImage {
    guard reference.pixelFormat == "rgba16FloatPremultiplied",
      reference.colorSpace == "extendedLinearDisplayP3"
    else {
      throw PixeltjeMacError("Raster asset unsupported", "This layer does not contain image pixels.")
    }
    if let cached = rasterLayerCache[reference.id], cached.reference == reference {
      return cached.image
    }
    let pixels = try RasterAssetPayload.decode(compressedPixels, reference: reference)
    let image = CIImage(
      bitmapData: pixels,
      bytesPerRow: reference.width * 8,
      size: CGSize(width: reference.width, height: reference.height),
      format: .RGBAh,
      colorSpace: workingColorSpace
    )
    rasterLayerCache[reference.id] = RasterLayerCacheEntry(
      reference: reference, pixels: pixels, image: image)
    return image
  }

  /// The empty document a canvas without a RAW source starts from.
  private func transparentCanvas(_ canvas: CanvasRecipe, quality: RenderQuality) throws -> CIImage {
    guard canvas.isResolved else {
      throw PixeltjeMacError(
        "No canvas size",
        "The document has no canvas size to render into."
      )
    }
    let fullWidth = Double(canvas.width)
    let fullHeight = Double(canvas.height)
    let scale: Double
    if case .proxy(let maximumLongEdge) = quality {
      scale = min(1, Double(maximumLongEdge) / max(fullWidth, fullHeight))
    } else {
      scale = 1
    }
    return CIImage(color: .clear).cropped(
      to: CGRect(x: 0, y: 0, width: fullWidth * scale, height: fullHeight * scale)
    )
  }

  func makeSurface(for extent: CGRect) throws -> IOSurface {
    let width = Int(extent.width.rounded(.up))
    let height = Int(extent.height.rounded(.up))
    guard width > 0, height > 0 else {
      throw PixeltjeMacError("Empty render", "Core Image produced an empty image extent.")
    }
    guard
      let surface = IOSurface(properties: [
        .width: width,
        .height: height,
        .bytesPerElement: 8,
        .pixelFormat: kCVPixelFormatType_64RGBAHalf,
        .name: "PixeltjeMac RGBA16F",
      ])
    else {
      throw PixeltjeMacError(
        "Image allocation failed",
        "Could not allocate a \(width)×\(height) half-float image surface."
      )
    }
    return surface
  }

  private func normalized(_ image: CIImage) -> CIImage {
    let extent = image.extent.integral
    guard extent.origin != .zero else { return image.cropped(to: extent) }
    return
      image
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
      .cropped(to: CGRect(origin: .zero, size: extent.size))
  }

  /// The canonical orientation and crop stage of the RAW rendering contract.
  ///
  /// The incoming image is the developed RAW with its EXIF orientation already
  /// applied exactly once, normalized to an origin of zero. That is the
  /// canonical image coordinate space `CropRecipe` is written in, so the unit
  /// rectangle crosses into pixels here through `CropGeometry` and nowhere
  /// else.
  ///
  /// Straightening turns the image about its own center. Rotation about the
  /// center is its own inverse in one respect that matters here: the center
  /// does not move, so the crop rectangle's coordinates mean the same thing
  /// before and after, and one rectangle serves both this stage and the crop
  /// tool's overlay. Cropping to it afterwards is what makes the canvas extent
  /// follow the crop.
  ///
  /// `reference` is the rectangle the unit crop is written against. It
  /// defaults to the image's own extent; a layer crop passes the layer's frame,
  /// which can be larger than the pixels a trimmed layer still has.
  private func applyStraightenAndCrop(
    _ recipe: CropRecipe,
    to image: CIImage,
    reference: CGRect? = nil
  ) -> CIImage {
    let crop = recipe.clamped
    let extent = reference ?? image.extent
    guard extent.width > 0, extent.height > 0 else { return image }

    var output = image
    if crop.angleDegrees != 0 {
      // Positive degrees turn the image counter-clockwise, which is Core
      // Image's own direction, so no sign adapter is needed here.
      let radians = crop.angleDegrees * .pi / 180
      let center = CGPoint(x: extent.midX, y: extent.midY)
      let transform = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: radians)
        .translatedBy(x: -center.x, y: -center.y)
      output = image.transformed(by: transform)
    }

    let rect = CropGeometry.pixelRect(
      crop,
      imageWidth: Double(extent.width),
      imageHeight: Double(extent.height)
    )
    let rectangle = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
      .offsetBy(dx: extent.minX, dy: extent.minY)
      .integral
    guard !rectangle.isEmpty else { return output }
    return output.cropped(to: rectangle)
  }

  /// Manual upright, as one Core Image perspective transform in the post-RAW
  /// graph.
  ///
  /// `CIPerspectiveTransform` maps the corners of its input onto four points,
  /// which is exactly what `UprightRecipe.quadrilateral` describes. The result
  /// is trimmed back to the incoming extent so the document keeps the size its
  /// crop gave it; the empty wedges a keystone leaves behind are the user's to
  /// crop away.
  private func applyUpright(_ recipe: UprightRecipe, to image: CIImage) -> CIImage {
    guard recipe.isActive else { return image }
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return image }

    let quad = recipe.quadrilateral(
      imageWidth: Double(extent.width),
      imageHeight: Double(extent.height)
    )
    // The recipe speaks in the canonical space, whose origin is the image's own
    // bottom-left corner. Core Image places the filter in the extent it is
    // given, so each corner is offset onto that extent here.
    func point(_ corner: UprightCorner) -> CIVector {
      CIVector(x: extent.minX + CGFloat(corner.x), y: extent.minY + CGFloat(corner.y))
    }

    return
      image
      .applyingFilter(
        "CIPerspectiveTransform",
        parameters: [
          "inputBottomLeft": point(quad.bottomLeft),
          "inputBottomRight": point(quad.bottomRight),
          "inputTopLeft": point(quad.topLeft),
          "inputTopRight": point(quad.topRight),
        ]
      )
      .cropped(to: extent)
  }

  private func applyPostProcessing(
    _ recipe: PostProcessingRecipe,
    to image: CIImage
  ) -> CIImage {
    guard recipe != PostProcessingRecipe() else { return image }
    return image.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputBrightnessKey: recipe.brightness,
        kCIInputContrastKey: recipe.contrast,
        kCIInputSaturationKey: recipe.saturation,
      ]
    )
  }

  private func exportColorSpace(for selection: ExportColorSpace) throws -> CGColorSpace {
    let name: CFString =
      switch selection {
      case .sRGB: CGColorSpace.sRGB
      case .displayP3: CGColorSpace.displayP3
      }
    guard let colorSpace = CGColorSpace(name: name) else {
      throw PixeltjeMacError("Color space unavailable", "The export color space is unavailable.")
    }
    return colorSpace
  }
}

extension LayerBlendMode {
  /// The Core Image blend filter for this mode, or `nil` for plain
  /// source-over compositing.
  ///
  /// Every filter here is alpha-aware: where the layer is transparent the
  /// backdrop shows through unchanged, so a layer smaller than the canvas
  /// blends only where it has pixels.
  var coreImageFilterName: String? {
    switch self {
    case .normal: nil
    case .differenceKey: nil
    case .multiply: "CIMultiplyBlendMode"
    case .screen: "CIScreenBlendMode"
    case .overlay: "CIOverlayBlendMode"
    case .darken: "CIDarkenBlendMode"
    case .lighten: "CILightenBlendMode"
    case .colorDodge: "CIColorDodgeBlendMode"
    case .colorBurn: "CIColorBurnBlendMode"
    case .softLight: "CISoftLightBlendMode"
    case .hardLight: "CIHardLightBlendMode"
    case .difference: "CIDifferenceBlendMode"
    case .exclusion: "CIExclusionBlendMode"
    case .hue: "CIHueBlendMode"
    case .saturation: "CISaturationBlendMode"
    case .color: "CIColorBlendMode"
    case .luminosity: "CILuminosityBlendMode"
    }
  }
}

extension RawInput {
  fileprivate func startAccessingSecurityScope() -> Bool {
    guard case .file(let url) = self else { return false }
    return url.startAccessingSecurityScopedResource()
  }

  fileprivate func stopAccessingSecurityScope(if accessed: Bool) {
    guard accessed, case .file(let url) = self else { return }
    url.stopAccessingSecurityScopedResource()
  }
}

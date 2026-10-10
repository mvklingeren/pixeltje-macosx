import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import PixeltjeMacDomain
import Vision

/// Where a mask is being evaluated: the render extent, and how canvas pixels
/// map into it.
///
/// Mask geometry is normalized to the canvas, so a proxy render and a final
/// render resolve the same recipe through different spaces and get the same
/// picture at different resolutions. Nothing about a mask depends on which
/// quality asked for it.
struct MaskSpace {
  var extent: CGRect
  /// Render pixels per canvas pixel, for feather radii and brush widths.
  var pixelsPerCanvasPixel: CGFloat

  /// A normalized mask point in render pixels.
  func point(_ point: VectorPoint) -> CGPoint {
    CGPoint(
      x: extent.minX + CGFloat(point.x) * extent.width,
      y: extent.minY + CGFloat(point.y) * extent.height
    )
  }

  /// A canvas-pixel distance in render pixels.
  func length(_ canvasPixels: Double) -> CGFloat {
    CGFloat(canvasPixels) * pixelsPerCanvasPixel
  }

  /// A fraction of the shorter canvas edge in render pixels.
  func radius(_ fraction: Double) -> CGFloat {
    CGFloat(fraction) * min(extent.width, extent.height)
  }
}

/// Resolves a `MaskRecipe` to a single-channel Core Image mask.
///
/// The renderer is owned by `RenderEngine` and runs inside that actor, which is
/// not the main actor: the Vision requests below therefore never touch the main
/// thread. They are performed synchronously on the render actor rather than
/// hopped onto a detached task because `CIImage`, `CVPixelBuffer` and
/// `VNImageRequestHandler` are not `Sendable` and must not cross an isolation
/// boundary.
///
/// Every mask is evaluated as an **opaque grayscale coverage image**: alpha is
/// 1 everywhere and the RGB channels all carry the same coverage value in
/// `0...1`. Keeping the accumulator opaque is what makes the combine operations
/// exact, because Core Image's compositing filters then reduce to plain
/// per-channel arithmetic:
///
/// - add       → `CIMaximumCompositing`, i.e. `max(a, b)`
/// - subtract  → `CIMultiplyCompositing` against the inverse, i.e. `a * (1 - b)`
/// - intersect → `CIMinimumCompositing`, i.e. `min(a, b)`
///
/// Consumers use `CIBlendWithMask`, which reads the opaque image's color
/// channels. Keeping alpha at one avoids multiplying soft coverage twice.
final class MaskRenderer {
  /// A Vision segmentation result, kept so a slider drag does not re-run
  /// segmentation on every frame.
  private struct SegmentationCacheEntry {
    var sourceIdentity: String
    var width: Int
    var height: Int
    var image: CIImage
  }

  private let context: CIContext
  private let workingColorSpace: CGColorSpace
  private let displayColorSpace: CGColorSpace
  /// Brush coverage is drawn into a linear gray bitmap so the value written is
  /// the value read: a gamma-encoded gray space would bend coverage on the way
  /// into the linear working space.
  private let grayColorSpace: CGColorSpace
  private var segmentationCache: [String: SegmentationCacheEntry] = [:]

  /// The longest edge Vision analyses. Segmentation quality plateaus well
  /// before full sensor resolution and the request is the slowest thing in a
  /// mask, so the mask is produced small and scaled up to the render extent.
  private let segmentationLongEdge: CGFloat = 1024

  init(context: CIContext, workingColorSpace: CGColorSpace) {
    self.context = context
    self.workingColorSpace = workingColorSpace
    self.displayColorSpace =
      CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    self.grayColorSpace =
      CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
  }

  func clearCaches() {
    segmentationCache = [:]
  }

  // MARK: - Evaluation

  /// Resolves a mask recipe to a coverage image over `space.extent`, or `nil`
  /// when nothing in it can produce coverage.
  ///
  /// `source` is the image the mask is being applied to. Luminance range, color
  /// range and the Vision generators read it; gradients and brush strokes do
  /// not, so a mask made only of those resolves without one.
  ///
  /// `sourceIdentity` names the pixels in `source` well enough to cache a
  /// segmentation against them. Passing a value that changes whenever the
  /// pixels do is the caller's job.
  func evaluate(
    _ mask: MaskRecipe,
    in space: MaskSpace,
    source: CIImage?,
    sourceIdentity: String,
    strokeSurfaceCoverage: ((StrokeSurfaceRecipe) throws -> CIImage?)? = nil
  ) throws -> CIImage? {
    var coverage: CIImage?
    for component in mask.components where component.isEnabled {
      guard component.availability.isAvailable else { continue }
      try Task.checkCancellation()
      guard
        var produced = try self.coverage(
          for: component.generator,
          in: space,
          source: source,
          sourceIdentity: sourceIdentity,
          strokeSurfaceCoverage: strokeSurfaceCoverage
        )
      else { continue }

      if component.isInverted { produced = inverted(produced) }
      if component.feather > 0 { produced = feathered(produced, by: component.feather, in: space) }
      if component.density < 1 { produced = scaled(produced, by: component.density) }

      guard let existing = coverage else {
        // The first component starts the coverage; its operation has nothing
        // to act on and is ignored.
        coverage = produced
        continue
      }
      coverage = combine(produced, onto: existing, with: component.combine, in: space)
    }

    guard var result = coverage else { return nil }
    if mask.isInverted { result = inverted(result) }
    if mask.feather > 0 { result = feathered(result, by: mask.feather, in: space) }
    return result.cropped(to: space.extent)
  }

  /// Applies every enabled mask's own adjustment to `image`, each one only
  /// where its mask is opaque.
  ///
  /// This is the "per-mask adjustments" of the masks tool. Masks are applied in
  /// order, so a later mask adjusts what the earlier ones already changed, the
  /// way a stack of local adjustments behaves.
  func applyAdjustments(
    _ masks: [MaskRecipe],
    to image: CIImage,
    in space: MaskSpace,
    sourceIdentity: String,
    strokeSurfaceCoverage: ((StrokeSurfaceRecipe) throws -> CIImage?)? = nil,
    adjust: (AdjustmentRecipe, CIImage) -> CIImage
  ) throws -> CIImage {
    var output = image
    for mask in masks where mask.isEnabled {
      guard let adjustment = mask.adjustment, mask.isEvaluable else { continue }
      try Task.checkCancellation()
      guard
        let coverage = try evaluate(
          mask,
          in: space,
          // Segmentation and range keying read the pixels the user is looking
          // at, which are the ones the earlier masks have already changed.
          source: output,
          sourceIdentity: sourceIdentity,
          strokeSurfaceCoverage: strokeSurfaceCoverage
        )
      else { continue }
      let adjusted = adjust(adjustment, output)
      output = adjusted.applyingFilter(
        "CIBlendWithMask",
        parameters: [
          kCIInputBackgroundImageKey: output,
          kCIInputMaskImageKey: maskImage(from: coverage),
        ]
      ).cropped(to: space.extent)
    }
    return output
  }

  /// Returns the opaque grayscale image consumed by `CIBlendWithMask`.
  /// Coverage must remain in RGB with alpha one: putting the same fractional
  /// value in alpha premultiplies RGB and squares a soft edge (0.5 becomes
  /// 0.25). Alpha-mask consumers should receive a separately constructed
  /// alpha-only image if one is introduced later.
  func maskImage(from coverage: CIImage) -> CIImage {
    coverage
  }

  // MARK: - Generators

  private func coverage(
    for generator: MaskGenerator,
    in space: MaskSpace,
    source: CIImage?,
    sourceIdentity: String,
    strokeSurfaceCoverage: ((StrokeSurfaceRecipe) throws -> CIImage?)?
  ) throws -> CIImage? {
    switch generator {
    case .rectangle(let shape):
      return try shapeCoverage(shape, elliptical: false, in: space)
    case .ellipse(let shape):
      return try shapeCoverage(shape, elliptical: true, in: space)
    case .polygon(let polygon):
      return try polygonCoverage(polygon, in: space)
    case .linearGradient(let gradient):
      return linearGradientCoverage(gradient, in: space)
    case .radialGradient(let gradient):
      return radialGradientCoverage(gradient, in: space)
    case .brush(let strokes):
      return try brushCoverage(strokes, in: space)
    case .strokeSurface(let surface):
      return try strokeSurfaceCoverage?(surface)?.cropped(to: space.extent)
    case .luminanceRange(let range):
      guard let source else { return nil }
      return luminanceRangeCoverage(range, of: source, in: space)
    case .colorRange(let range):
      guard let source else { return nil }
      return colorRangeCoverage(range, of: source, in: space)
    case .raster(let raster):
      return try rasterCoverage(raster, in: space)
    case .placedRaster(let placed):
      return try placedRasterCoverage(placed, in: space)
    case .subject:
      guard let source else { return nil }
      return try segmentation(.subject, of: source, in: space, sourceIdentity: sourceIdentity)
    case .background:
      guard let source else { return nil }
      // The background is defined as the inverse of the subject rather than as
      // a second segmentation, so the two can never disagree about the edge.
      guard
        let subject = try segmentation(
          .subject, of: source, in: space, sourceIdentity: sourceIdentity)
      else { return nil }
      return inverted(subject)
    case .person:
      guard let source else { return nil }
      return try segmentation(.person, of: source, in: space, sourceIdentity: sourceIdentity)
    case .sky:
      // Defined in the model, deliberately not produced. The Core AI
      // segmentation package and the model manager that loads it are out of
      // scope; the UI reports the reason rather than substituting a guess.
      return nil
    }
  }

  private func linearGradientCoverage(
    _ gradient: LinearGradientMask,
    in space: MaskSpace
  ) -> CIImage {
    let start = space.point(gradient.start)
    let end = space.point(gradient.end)
    guard hypot(end.x - start.x, end.y - start.y) > 0.5 else {
      // A zero-length drag has no direction to ramp along; treat it as fully
      // covered rather than as an undefined gradient.
      return solid(1, in: space)
    }
    let image = CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(cgPoint: start),
        "inputPoint1": CIVector(cgPoint: end),
        "inputColor0": linearGray(1),
        "inputColor1": linearGray(0),
      ]
    )?.outputImage
    guard let image else { return solid(0, in: space) }
    return image.cropped(to: space.extent)
  }

  private func radialGradientCoverage(
    _ gradient: RadialGradientMask,
    in space: MaskSpace
  ) -> CIImage {
    let outer = max(space.radius(gradient.radius), 1)
    let inner = outer * CGFloat(1 - gradient.softness)
    let image = CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(cgPoint: space.point(gradient.center)),
        "inputRadius0": inner,
        "inputRadius1": outer,
        "inputColor0": linearGray(gradient.coversInside ? 1 : 0),
        "inputColor1": linearGray(gradient.coversInside ? 0 : 1),
      ]
    )?.outputImage
    guard let image else { return solid(0, in: space) }
    return image.cropped(to: space.extent)
  }

  /// Draws geometry into a linear-gray coverage bitmap sized to the render
  /// extent, and hands back the result as a Core Image mask.
  ///
  /// Every generator that is drawn rather than computed — brush strokes,
  /// rectangles, ellipses and freehand polygons — goes through here, so they
  /// share one allocation policy, one antialiasing setting and one route back
  /// into the working color space. The bitmap is linear gray so the value
  /// written is the value read: a gamma-encoded space would bend coverage on
  /// the way in.
  ///
  /// The context arrives cleared to no coverage and with its origin at the
  /// extent's bottom-left, so `draw` may use `space.point(_:)` directly.
  private func coverageBitmap(
    in space: MaskSpace,
    describing subject: String,
    draw: (CGContext) -> Void
  ) throws -> CIImage? {
    let width = Int(space.extent.width.rounded(.up))
    let height = Int(space.extent.height.rounded(.up))
    guard width > 0, height > 0 else { return nil }

    guard
      let cgContext = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: grayColorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else {
      throw PixeltjeMacError(
        "Mask rendering failed",
        "Could not allocate a \(width)×\(height) \(subject) surface."
      )
    }
    // Coverage starts at nothing; what is drawn adds to it.
    setLinearCoverage(0, in: cgContext)
    cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
    cgContext.setShouldAntialias(true)
    // The bitmap's origin is the extent's origin, so drawing can speak in the
    // same render-pixel coordinates `MaskSpace` hands out.
    cgContext.translateBy(x: -space.extent.minX, y: -space.extent.minY)

    draw(cgContext)

    guard let cgImage = cgContext.makeImage() else { return nil }
    return CIImage(cgImage: cgImage, options: [.colorSpace: grayColorSpace])
      .transformed(by: CGAffineTransform(translationX: space.extent.minX, y: space.extent.minY))
      .cropped(to: space.extent)
  }

  /// `CGContext.setFillColor(gray:alpha:)` constructs its gray in a generic
  /// transfer function before converting it into the destination bitmap. That
  /// bends fractional mask values even when the bitmap itself is linear. An
  /// explicitly tagged color keeps stored coverage such as 128/255 numeric.
  private func setLinearCoverage(_ value: CGFloat, in context: CGContext) {
    let clamped = min(max(value, 0), 1)
    if let color = CGColor(colorSpace: grayColorSpace, components: [clamped, 1]) {
      context.setFillColor(color)
    }
  }

  /// Fills the rectangle, or the ellipse inscribed in it, with full coverage.
  ///
  /// Density, feather, inversion and how this joins the rest of the mask are
  /// all the component's business, so the shape itself is a hard-edged, fully
  /// covered area and nothing more.
  ///
  /// A rectangle may round its corners. `SelectionGeometry` draws the same
  /// rounding for the marching ants, so what the user outlines and what gets
  /// covered stay the same shape.
  private func shapeCoverage(
    _ shape: ShapeMask,
    elliptical: Bool,
    in space: MaskSpace
  ) throws -> CIImage? {
    guard !shape.isEmpty else { return nil }
    let origin = space.point(shape.origin)
    let opposite = space.point(VectorPoint(x: shape.maxX, y: shape.maxY))
    let rect = CGRect(
      x: origin.x,
      y: origin.y,
      width: opposite.x - origin.x,
      height: opposite.y - origin.y
    )
    guard rect.width > 0, rect.height > 0 else { return nil }
    // Half the shorter edge is already a stadium; anything past that would
    // start eating into the opposite corner.
    let cornerRadius = min(
      space.radius(shape.cornerRadius), min(rect.width, rect.height) / 2)
    return try coverageBitmap(in: space, describing: elliptical ? "ellipse mask" : "rectangle mask")
    { cgContext in
      setLinearCoverage(1, in: cgContext)
      if elliptical {
        cgContext.fillEllipse(in: rect)
      } else if cornerRadius > 0 {
        cgContext.addPath(
          CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil))
        cgContext.fillPath()
      } else {
        cgContext.fill(rect)
      }
    }
  }

  /// Fills the closed polygon a freehand gesture recorded.
  ///
  /// The closing edge is implicit in the recipe, so it is added here rather
  /// than stored. Non-zero winding is used deliberately: a lasso that crosses
  /// itself selects everything it looped around, which is what a user drawing
  /// a rough circle expects, rather than punching a hole with even-odd.
  private func polygonCoverage(_ polygon: PolygonMask, in space: MaskSpace) throws -> CIImage? {
    guard !polygon.isEmpty else { return nil }
    return try coverageBitmap(in: space, describing: "freehand mask") { cgContext in
      setLinearCoverage(1, in: cgContext)
      cgContext.beginPath()
      cgContext.move(to: space.point(polygon.points[0]))
      for point in polygon.points.dropFirst() {
        cgContext.addLine(to: space.point(point))
      }
      cgContext.closePath()
      cgContext.fillPath(using: .winding)
    }
  }

  /// Replays captured coverage as scaled run geometry. Nearest-neighbour pixel
  /// cells preserve the exact captured membership and soft coverage at its
  /// native canvas size; proxy renders only change the evaluation scale, never
  /// the recipe.
  private func rasterCoverage(_ raster: RasterMask, in space: MaskSpace) throws -> CIImage? {
    guard !raster.isEmpty else { return nil }
    let scaleX = space.extent.width / CGFloat(raster.width)
    let scaleY = space.extent.height / CGFloat(raster.height)
    return try coverageBitmap(in: space, describing: "contiguous fill mask") { context in
      context.setShouldAntialias(false)
      for run in raster.runs {
        setLinearCoverage(CGFloat(run.coverage) / 255, in: context)
        context.fill(
          CGRect(
            x: space.extent.minX + CGFloat(run.startX) * scaleX,
            y: space.extent.minY + CGFloat(run.y) * scaleY,
            width: CGFloat(run.length) * scaleX,
            height: scaleY
          )
        )
      }
    }
  }

  private func placedRasterCoverage(
    _ placed: PlacedRasterMask, in space: MaskSpace
  ) throws -> CIImage? {
    guard !placed.isEmpty else { return nil }
    let frame = placed.frame
    let cellWidth = space.extent.width * frame.width / CGFloat(placed.raster.width)
    let cellHeight = space.extent.height * frame.height / CGFloat(placed.raster.height)
    let originX = space.extent.minX + space.extent.width * frame.origin.x
    let originY = space.extent.minY + space.extent.height * frame.origin.y
    return try coverageBitmap(in: space, describing: "placed selection mask") { context in
      context.setShouldAntialias(false)
      for run in placed.raster.runs {
        setLinearCoverage(CGFloat(run.coverage) / 255, in: context)
        context.fill(
          CGRect(
            x: originX + CGFloat(run.startX) * cellWidth,
            y: originY + CGFloat(run.y) * cellHeight,
            width: CGFloat(run.length) * cellWidth,
            height: cellHeight))
      }
    }
  }

  /// Draws the stored stroke geometry again at this render's resolution.
  ///
  /// The recipe holds points, radii and pressures, never pixels, so the same
  /// strokes are redrawn crisply for a final render after having been drawn
  /// coarsely for a proxy.
  private func brushCoverage(_ strokes: BrushStrokeMask, in space: MaskSpace) throws -> CIImage? {
    guard !strokes.isEmpty else { return nil }
    return try coverageBitmap(in: space, describing: "brush mask") { cgContext in
      cgContext.setLineCap(.round)
      cgContext.setLineJoin(.round)
      drawStrokes(strokes, in: space, into: cgContext)
    }
  }

  private func drawStrokes(
    _ strokes: BrushStrokeMask,
    in space: MaskSpace,
    into cgContext: CGContext
  ) {
    for stroke in strokes.strokes where stroke.points.count > 0 {
      let coverage = stroke.flow
      cgContext.setBlendMode(stroke.isErasing ? .darken : .lighten)
      cgContext.setStrokeColor(gray: stroke.isErasing ? 0 : coverage, alpha: 1)
      setLinearCoverage(stroke.isErasing ? 0 : coverage, in: cgContext)
      // Hardness is the fraction of the radius that is solid. A soft brush is
      // drawn as a solid core with a shadow-free ring of progressively wider,
      // fainter passes, which is a decent feathered dab without a custom
      // kernel and stays identical across resolutions.
      let radius = space.length(stroke.radius)
      let core = max(radius * CGFloat(stroke.hardness), 0.5)
      let passes = stroke.hardness >= 1 ? 1 : 5
      for pass in 0..<passes {
        let t = passes == 1 ? 0 : CGFloat(pass) / CGFloat(passes - 1)
        let passWidth = (core + (radius - core) * t) * 2
        let passCoverage = coverage * Double(1 - t * 0.85)
        cgContext.setStrokeColor(gray: stroke.isErasing ? 0 : passCoverage, alpha: 1)
        cgContext.setLineWidth(passWidth)
        cgContext.beginPath()
        let first = space.point(stroke.points[0].position)
        if stroke.points.count == 1 {
          cgContext.addEllipse(
            in: CGRect(
              x: first.x - passWidth / 2, y: first.y - passWidth / 2,
              width: passWidth, height: passWidth))
          setLinearCoverage(stroke.isErasing ? 0 : passCoverage, in: cgContext)
          cgContext.fillPath()
          continue
        }
        cgContext.move(to: first)
        for sample in stroke.points.dropFirst() {
          cgContext.addLine(to: space.point(sample.position))
        }
        cgContext.strokePath()
      }
    }
  }

  /// `clamp((L - lower) / lowerFalloff) * clamp((upper - L) / upperFalloff)`,
  /// built from stock filters so it costs one graph rather than a kernel.
  private func luminanceRangeCoverage(
    _ range: LuminanceRangeMask,
    of source: CIImage,
    in space: MaskSpace
  ) -> CIImage {
    let luma = luminance(of: source)
    let lowerFalloff = max(range.lowerFalloff, 0.001)
    let upperFalloff = max(range.upperFalloff, 0.001)
    let low = clamped(
      scaledAndBiased(luma, scale: 1 / lowerFalloff, bias: -range.lowerBound / lowerFalloff))
    let high = clamped(
      scaledAndBiased(luma, scale: -1 / upperFalloff, bias: range.upperBound / upperFalloff))
    return
      low
      .applyingFilter(
        "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: high]
      )
      .cropped(to: space.extent)
  }

  /// `clamp((tolerance - |C - S|) / (smoothness * tolerance))`, with the
  /// per-channel difference averaged into one scalar.
  private func colorRangeCoverage(
    _ range: ColorRangeMask,
    of source: CIImage,
    in space: MaskSpace
  ) -> CIImage {
    let sample = CIImage(color: sampleColor(range.sample)).cropped(to: space.extent)
    let opaqueSource = opaque(source.cropped(to: space.extent))
    // Difference blending gives |C - S| per channel on opaque inputs.
    let difference = opaqueSource.applyingFilter(
      "CIDifferenceBlendMode",
      parameters: [kCIInputBackgroundImageKey: sample]
    )
    let distance = luminance(of: difference)
    let tolerance = max(range.tolerance, 0.001)
    let falloff = max(range.smoothness * range.tolerance, 0.001)
    return clamped(
      scaledAndBiased(distance, scale: -1 / falloff, bias: tolerance / falloff)
    ).cropped(to: space.extent)
  }

  // MARK: - Vision

  private enum Segmentation: String {
    case subject
    case person
  }

  /// Runs a Vision segmentation request and returns its result as opaque
  /// coverage over the render extent.
  ///
  /// This runs on the render actor, off the main actor. Vision is given a
  /// bounded, explicitly color-managed sRGB rendering of the image rather than
  /// the extended-linear working image, because its models are trained on
  /// display-referred pixels.
  private func segmentation(
    _ kind: Segmentation,
    of source: CIImage,
    in space: MaskSpace,
    sourceIdentity: String
  ) throws -> CIImage? {
    let width = Int(space.extent.width.rounded(.up))
    let height = Int(space.extent.height.rounded(.up))
    let key = "\(kind.rawValue)|\(sourceIdentity)"
    if let cached = segmentationCache[key], cached.sourceIdentity == sourceIdentity,
      cached.width == width, cached.height == height
    {
      return cached.image
    }

    guard let analysed = analysisImage(for: source) else { return nil }
    try Task.checkCancellation()

    let handler = VNImageRequestHandler(cgImage: analysed, options: [:])
    let maskBuffer: CVPixelBuffer
    switch kind {
    case .subject:
      let request = VNGenerateForegroundInstanceMaskRequest()
      try handler.perform([request])
      guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        return nil
      }
      maskBuffer = try observation.generateScaledMaskForImage(
        forInstances: observation.allInstances,
        from: handler
      )
    case .person:
      let request = VNGeneratePersonSegmentationRequest()
      // A proxy render can afford the fast path; a final render should not.
      request.qualityLevel = space.pixelsPerCanvasPixel < 0.9 ? .balanced : .accurate
      request.outputPixelFormat = kCVPixelFormatType_OneComponent8
      try handler.perform([request])
      guard let buffer = request.results?.first?.pixelBuffer else { return nil }
      maskBuffer = buffer
    }

    try Task.checkCancellation()
    let raw = CIImage(cvPixelBuffer: maskBuffer)
    guard !raw.extent.isEmpty else { return nil }
    // Vision reports its mask in its own pixel space. Scale it onto the render
    // extent, which is the space every other generator already works in.
    let scaled =
      raw
      .transformed(
        by: CGAffineTransform(
          scaleX: space.extent.width / raw.extent.width,
          y: space.extent.height / raw.extent.height
        )
      )
      .transformed(by: CGAffineTransform(translationX: space.extent.minX, y: space.extent.minY))
    let coverage = opaque(scaled.cropped(to: space.extent))
    segmentationCache[key] = SegmentationCacheEntry(
      sourceIdentity: sourceIdentity,
      width: width,
      height: height,
      image: coverage
    )
    return coverage
  }

  /// A bounded, display-referred rendering of the image for Vision to analyse.
  private func analysisImage(for source: CIImage) -> CGImage? {
    let extent = source.extent
    guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return nil }
    let longEdge = max(extent.width, extent.height)
    let scale = longEdge > segmentationLongEdge ? segmentationLongEdge / longEdge : 1
    let scaledImage =
      scale < 1
      ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      : source
    return context.createCGImage(
      scaledImage,
      from: scaledImage.extent,
      format: .RGBA8,
      colorSpace: displayColorSpace
    )
  }

  // MARK: - Coverage arithmetic

  private func combine(
    _ component: CIImage,
    onto existing: CIImage,
    with operation: MaskCombineOperation,
    in space: MaskSpace
  ) -> CIImage {
    let result: CIImage
    switch operation {
    case .add:
      result = component.applyingFilter(
        "CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: existing])
    case .subtract:
      result = inverted(component).applyingFilter(
        "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: existing])
    case .intersect:
      result = component.applyingFilter(
        "CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: existing])
    }
    return result.cropped(to: space.extent)
  }

  private func inverted(_ coverage: CIImage) -> CIImage {
    scaledAndBiased(coverage, scale: -1, bias: 1)
  }

  private func scaled(_ coverage: CIImage, by density: Double) -> CIImage {
    scaledAndBiased(coverage, scale: density, bias: 0)
  }

  /// A Gaussian blur of the coverage, which is what softening a mask edge is.
  ///
  /// The radius is given in canvas pixels and converted here, so a mask
  /// feathered by 40 px looks the same in a proxy and a final render.
  func feathered(_ coverage: CIImage, by canvasPixels: Double, in space: MaskSpace)
    -> CIImage
  {
    let radius = space.length(canvasPixels)
    guard radius >= 0.5 else { return coverage }
    return
      coverage
      // Clamping first stops the blur pulling transparent black in from
      // outside the extent and eating the mask at the frame edge.
      .clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
      .cropped(to: space.extent)
  }

  /// Per-channel `value * scale + bias`, with alpha left opaque.
  private func scaledAndBiased(_ image: CIImage, scale: Double, bias: Double) -> CIImage {
    image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(
          x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 1),
      ]
    )
  }

  private func clamped(_ image: CIImage) -> CIImage {
    image.applyingFilter(
      "CIColorClamp",
      parameters: [
        "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
      ]
    )
  }

  /// The image's luminance, written into every channel, opaque.
  private func luminance(of image: CIImage) -> CIImage {
    // Rec. 709 weights, applied in the linear working space where a weighted
    // sum of channels is what luminance actually means.
    let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
    return image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": weights,
        "inputGVector": weights,
        "inputBVector": weights,
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ]
    )
  }

  /// Forces alpha to 1 without touching the color channels, which is the form
  /// every coverage image in this file is in.
  private func opaque(_ image: CIImage) -> CIImage {
    image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ]
    )
  }

  private func solid(_ coverage: Double, in space: MaskSpace) -> CIImage {
    CIImage(color: linearGray(coverage)).cropped(to: space.extent)
  }

  /// A gray whose numeric value survives into the working space.
  ///
  /// Constructing the color in the same extended-linear space the context works
  /// in means Core Image performs no conversion, so 0.5 stays 0.5. A `CIColor`
  /// built without a color space would be read as sRGB and gamma-shifted, which
  /// is wrong for a coverage value.
  private func linearGray(_ value: Double) -> CIColor {
    CIColor(
      red: CGFloat(value),
      green: CGFloat(value),
      blue: CGFloat(value),
      alpha: 1,
      colorSpace: workingColorSpace
    ) ?? CIColor(red: CGFloat(value), green: CGFloat(value), blue: CGFloat(value))
  }

  /// A sampled Display P3 color, converted into the working space.
  private func sampleColor(_ color: VectorColor) -> CIColor {
    CIColor(
      red: CGFloat(color.red),
      green: CGFloat(color.green),
      blue: CGFloat(color.blue),
      alpha: 1,
      colorSpace: displayColorSpace
    ) ?? CIColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue))
  }
}

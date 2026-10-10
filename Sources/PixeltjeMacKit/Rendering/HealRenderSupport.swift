import CoreGraphics
import CoreImage
import Foundation
import PixeltjeMacDomain

/// Everything one heal needs solved, as values.
///
/// The request carries a complete render request rather than a frame: a heal
/// must read full-quality pixels, and the frame on screen may be a proxy. It
/// is the same reason the Fill tool renders its own isolated request instead
/// of sampling what is presented.
struct HealSolveRequest: Sendable {
  /// The source render. Already isolated to the active layer by the caller
  /// when the tool is set to sample the current layer.
  var render: RenderRequest
  /// The painted region, as a mask-kind stroke surface in canvas pixels.
  var coverage: MaskRecipe
  /// The patch's bounds in canonical canvas pixels, dilated past the coverage
  /// so the solve has a ring of boundary pixels to meet.
  var bounds: CGRect
  /// The canvas the bounds and the stroke are written in. The render extent
  /// can differ from it — a cropped RAW background, or a proxy render — so the
  /// two are mapped rather than assumed equal.
  var canvasSize: CGSize
  var mode: HealSourceMode
  var sourceOffsetX: Double
  var sourceOffsetY: Double
  var blend: HealBlendMethod
  var iterations: Int
  /// Distinguishes this stroke's coverage in the brush renderer's cache.
  var cacheID: String
}

/// A solved patch and where it belongs.
struct HealSolveResult: Sendable {
  var raster: RasterBakeResult
  var frame: LayerFrame
}

extension RenderEngine {
  /// Solves one heal and encodes the result as project-local pixels.
  ///
  /// The patch is baked here, once, rather than re-derived per frame. A heal
  /// reads the composite it becomes part of, so a live recipe would feed it
  /// its own output; and a patch re-solved against whatever happens to be
  /// beneath it would change silently when an earlier edit was undone.
  func solveHeal(_ request: HealSolveRequest) async throws -> HealSolveResult? {
    let frame = try await render(request.render)
    try Task.checkCancellation()
    let renderExtent = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)

    // A rendered frame is not always canvas-sized: a cropped, straightened or
    // uprighted RAW background sets the render extent, and a proxy render
    // carries fewer pixels than the canvas it stands for. The stroke and the
    // patch's stored frame are in canvas pixels, so the region actually read
    // has to be mapped into the render's own pixels — the same mapping
    // `CompositeSpace` applies to every other layer frame.
    let scale = request.canvasSize.width > 0 && request.canvasSize.height > 0
      ? CGPoint(
        x: renderExtent.width / request.canvasSize.width,
        y: renderExtent.height / request.canvasSize.height)
      : CGPoint(x: 1, y: 1)
    guard scale.x > 0, scale.y > 0 else { return nil }
    let readBounds = CGRect(
      x: request.bounds.minX * scale.x,
      y: request.bounds.minY * scale.y,
      width: request.bounds.width * scale.x,
      height: request.bounds.height * scale.y
    ).integral

    let pixelWidth = Int(readBounds.width.rounded())
    let pixelHeight = Int(readBounds.height.rounded())
    guard pixelWidth > 2, pixelHeight > 2,
      pixelWidth <= HealLimits.maximumPatchAxis,
      pixelHeight <= HealLimits.maximumPatchAxis,
      pixelWidth * pixelHeight <= HealLimits.maximumPatchPixels
    else {
      throw PixeltjeMacError(
        "Heal too large",
        "That stroke covers more than the healing brush can solve at once. Use a smaller brush or a shorter stroke."
      )
    }
    // The read has to lie inside what was rendered. The caller clamps to the
    // canvas; this refuses rather than reading past the edge and taking
    // transparent black for image pixels.
    guard renderExtent.contains(readBounds) else { return nil }

    let image = CIImage(ioSurface: frame.surface, options: [.colorSpace: workingColorSpace])
    let destination = readPremultipliedRGBA(image, in: readBounds)

    var source: [Float]?
    if request.mode == .sourcePoint {
      let sourceBounds = readBounds.offsetBy(
        dx: CGFloat(request.sourceOffsetX) * scale.x,
        dy: CGFloat(request.sourceOffsetY) * scale.y)
      guard renderExtent.contains(sourceBounds) else {
        throw PixeltjeMacError(
          "Source outside the image",
          "The heal source lies partly off the canvas. Option-click a source further inside the image."
        )
      }
      source = readPremultipliedRGBA(image, in: sourceBounds)
    }
    try Task.checkCancellation()

    let coverage = try healCoverage(
      request, readingFrom: readBounds, in: renderExtent, scale: scale)
    try Task.checkCancellation()

    guard var solved = HealSolver.solve(
      destination: destination,
      source: source,
      coverage: coverage,
      width: pixelWidth,
      height: pixelHeight,
      blend: request.blend,
      iterations: request.iterations
    ) else { return nil }
    try Task.checkCancellation()

    // Carry the painted coverage in the patch's own alpha, so the render path
    // is left with an ordinary placed raster.
    solved = HealSolver.applyingCoverage(coverage, to: solved)

    let raster = try encodePatch(solved, width: pixelWidth, height: pixelHeight)
    // Stored in canvas pixels, whatever resolution the patch was solved at.
    // The renderer scales an asset into its frame exactly as it does for any
    // other placed raster, so the patch keeps its own resolution and a later
    // canvas resize stays a pure value transform.
    return HealSolveResult(
      raster: raster,
      frame: LayerFrame(
        x: Double(request.bounds.minX),
        y: Double(request.bounds.minY),
        width: Double(request.bounds.width),
        height: Double(request.bounds.height)
      )
    )
  }

  /// The painted coverage over the patch region, one value per pixel of the
  /// region that was read.
  private func healCoverage(
    _ request: HealSolveRequest,
    readingFrom readBounds: CGRect,
    in renderExtent: CGRect,
    scale: CGPoint
  ) throws -> [Float] {
    let space = MaskSpace(extent: renderExtent, pixelsPerCanvasPixel: scale.y)
    let width = Int(readBounds.width.rounded())
    let height = Int(readBounds.height.rounded())
    guard let evaluated = try maskRenderer.evaluate(
      request.coverage,
      in: space,
      source: nil,
      sourceIdentity: "heal:\(request.cacheID)",
      strokeSurfaceCoverage: { surface in
        try self.healStrokeCoverage(
          surface, cacheID: request.cacheID, in: renderExtent, scale: scale)
      }
    ) else { return [Float](repeating: 0, count: width * height) }

    var values = [Float](repeating: 0, count: width * height)
    var interleaved = [Float](repeating: 0, count: width * height * 4)
    interleaved.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      processingContext.render(
        evaluated,
        toBitmap: base,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: readBounds,
        format: .RGBAf,
        colorSpace: nil
      )
    }
    // Mask coverage is carried in every channel; red is as good as any.
    for index in 0..<(width * height) {
      let value = interleaved[index * 4]
      values[index] = value.isFinite ? min(max(value, 0), 1) : 0
    }
    return values
  }

  private func healStrokeCoverage(
    _ surface: StrokeSurfaceRecipe,
    cacheID: String,
    in renderExtent: CGRect,
    scale: CGPoint
  ) throws -> CIImage? {
    // The stroke is captured in canvas pixels, so it scales into the render's
    // own pixels the way a painted layer mask's does.
    let scaled = surface.scaled(byX: Double(scale.x), y: Double(scale.y))
    return try brushRenderer.maskCoverageImage(
      for: StrokeSurfaceRequest(
        cacheID: "heal-coverage:\(cacheID)",
        recipe: scaled,
        width: Int(renderExtent.width.rounded(.up)),
        height: Int(renderExtent.height.rounded(.up))
      ))
  }

  /// One region of the working-space image as premultiplied RGBA floats.
  private func readPremultipliedRGBA(_ image: CIImage, in bounds: CGRect) -> [Float] {
    let width = Int(bounds.width.rounded())
    let height = Int(bounds.height.rounded())
    var values = [Float](repeating: 0, count: width * height * 4)
    values.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      processingContext.render(
        image,
        toBitmap: base,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: bounds,
        format: .RGBAf,
        colorSpace: workingColorSpace
      )
    }
    return values
  }

  /// Stores the solved floats as the project's own lossless pixels.
  ///
  /// The solver's output is already the finished patch, so it goes to the
  /// encoder directly rather than back through Core Image: a round trip would
  /// only risk another premultiply and another colour conversion.
  private func encodePatch(_ values: [Float], width: Int, height: Int) throws
    -> RasterBakeResult
  {
    var pixels = Data(count: width * height * 4 * MemoryLayout<Float16>.size)
    pixels.withUnsafeMutableBytes { storage in
      guard let base = storage.baseAddress?.assumingMemoryBound(to: Float16.self) else { return }
      for index in 0..<(width * height * 4) {
        base[index] = Float16(values[index])
      }
    }
    let encoded = try RasterAssetPayload.encode(pixels, width: width, height: height)
    return RasterBakeResult(
      reference: encoded.reference,
      compressedPixels: encoded.compressedPixels
    )
  }
}

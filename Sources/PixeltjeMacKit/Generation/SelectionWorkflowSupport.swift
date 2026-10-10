import CoreGraphics
import Foundation
import ImageIO
import PixeltjeMacDomain

enum SelectionWorkflowSupport {
  static func mask(
    imageData: Data,
    width: Int,
    height: Int,
    placement: LayerFrame,
    canvas: CanvasRecipe,
    prompt: String
  ) throws -> MaskRecipe {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw PixeltjeMacError("Selection output unreadable", "The server did not return an image.")
    }
    guard image.width == width, image.height == height,
      width > 0, height > 0,
      width <= PaintOperationLimits.maximumRasterAxis,
      height <= PaintOperationLimits.maximumRasterAxis,
      width <= PaintOperationLimits.maximumRasterPixels / height
    else {
      throw PixeltjeMacError(
        "Selection output size changed",
        "The returned mask must match the image sent to the workflow.")
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard let base = bytes.baseAddress,
        let context = CGContext(
          data: base,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      throw PixeltjeMacError(
        "Selection output unreadable", "The returned mask could not be decoded.")
    }
    // ImageIO's bitmap rows start at the PNG's top edge. RasterMask rows use
    // the document's bottom-left coordinate space.
    var bottomUp = [UInt8](repeating: 0, count: rgba.count)
    for y in 0..<height {
      let source = (height - 1 - y) * width * 4
      let destination = y * width * 4
      bottomUp.replaceSubrange(
        destination..<(destination + width * 4),
        with: rgba[source..<(source + width * 4)])
    }
    return try mask(
      rgba: bottomUp,
      width: width,
      height: height,
      placement: placement,
      canvas: canvas,
      prompt: prompt)
  }

  /// ComfyUI's MaskToImage writes white for selected pixels and black elsewhere.
  /// The decoded pixels are converted to RasterMask's bottom-left coordinates.
  static func mask(
    rgba: [UInt8],
    width: Int,
    height: Int,
    placement: LayerFrame,
    canvas: CanvasRecipe,
    prompt: String
  ) throws -> MaskRecipe {
    guard width > 0, height > 0,
      width <= PaintOperationLimits.maximumRasterAxis,
      height <= PaintOperationLimits.maximumRasterAxis,
      width <= PaintOperationLimits.maximumRasterPixels / height,
      rgba.count == width * height * 4,
      canvas.isResolved,
      placement.x.isFinite, placement.y.isFinite,
      placement.width > 0, placement.height > 0
    else {
      throw PixeltjeMacError("Selection output invalid", "The returned mask has invalid geometry.")
    }

    var runs: [RasterMaskRun] = []
    for y in 0..<height {
      var runStart: Int?
      for x in 0...width {
        let selected = x < width && rgba[(y * width + x) * 4] >= 128
        if selected {
          if runStart == nil { runStart = x }
        } else if let start = runStart {
          runs.append(RasterMaskRun(y: y, startX: start, length: x - start))
          if runs.count > PaintOperationLimits.maximumRasterRuns {
            throw PixeltjeMacError(
              "Selection output too complex", "The returned mask exceeds the document limit.")
          }
          runStart = nil
        }
      }
    }
    guard !runs.isEmpty else {
      throw PixeltjeMacError(
        "Nothing selected", "The workflow found no pixels matching the object prompt.")
    }
    let frame = ShapeMask(
      origin: VectorPoint(
        x: placement.x / Double(canvas.width),
        y: placement.y / Double(canvas.height)),
      width: placement.width / Double(canvas.width),
      height: placement.height / Double(canvas.height))
    return MaskRecipe.single(
      .placedRaster(
        PlacedRasterMask(
          raster: RasterMask(width: width, height: height, runs: runs),
          frame: frame)),
      name: "Selected — \(String(prompt.prefix(36)))")
  }
}

extension RenderEngine {
  func finishComfyUISelection(
    imageData: Data,
    preparation: ComfyUIImageConditioningPreparation,
    canvas: CanvasRecipe,
    prompt: String
  ) throws -> MaskRecipe {
    try SelectionWorkflowSupport.mask(
      imageData: imageData,
      width: preparation.width,
      height: preparation.height,
      placement: preparation.placementFrame,
      canvas: canvas,
      prompt: prompt)
  }
}

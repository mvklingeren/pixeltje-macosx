import CoreGraphics
import CoreImage
import Foundation

/// A bounded, display-referred RGBA8 read of a rendered image.
///
/// Two readers want the same thing from a frame — the histogram wants its
/// distribution, the palette wants its colors — and both want it cheaply and in
/// the space the display works in. Reading the frame once here, rather than
/// twice in two shapes, keeps them measuring identical pixels.
///
/// The image is decimated, never averaged: nearest sampling keeps a clipped
/// pixel clipped and keeps a small area of a strong color a strong color, where
/// a smooth downscale would average both away. Both readers are statistical, so
/// a bounded sample is enough and keeps the readback off the critical path of
/// an interactive drag.
struct DecimatedReadback {
  /// Display-referred, premultiplied RGBA, four bytes per pixel.
  var bytes: [UInt8]
  var width: Int
  var height: Int

  static func read(
    _ image: CIImage,
    context: CIContext,
    displayColorSpace: CGColorSpace,
    maximumSampleEdge: Int
  ) -> DecimatedReadback? {
    let extent = image.extent
    guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return nil }

    let longEdge = max(extent.width, extent.height)
    let scale = min(1, CGFloat(maximumSampleEdge) / longEdge)
    let sampled =
      scale < 1
      ? image.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      : image
    let width = Int(sampled.extent.width.rounded(.down))
    let height = Int(sampled.extent.height.rounded(.down))
    guard width > 0, height > 0 else { return nil }

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let bounds = CGRect(
      x: sampled.extent.origin.x,
      y: sampled.extent.origin.y,
      width: CGFloat(width),
      height: CGFloat(height)
    )
    bytes.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      // The destination color space is what performs the linear to
      // display-referred conversion; see the note on `ImageHistogram`.
      context.render(
        sampled,
        toBitmap: base,
        rowBytes: width * 4,
        bounds: bounds,
        format: .RGBA8,
        colorSpace: displayColorSpace
      )
    }
    return DecimatedReadback(bytes: bytes, width: width, height: height)
  }

  /// The straight — un-premultiplied — channels at a pixel, or `nil` where the
  /// pixel is fully transparent.
  ///
  /// A canvas document is transparent outside its content, and reading that as
  /// black would tell both readers the image is darker than it is. Core Image
  /// renders premultiplied, so a half-transparent highlight has to be divided
  /// back out or it reads as a midtone.
  func straightPixel(atByteOffset offset: Int) -> (red: Int, green: Int, blue: Int)? {
    let alpha = bytes[offset + 3]
    guard alpha > 0 else { return nil }
    var red = Int(bytes[offset])
    var green = Int(bytes[offset + 1])
    var blue = Int(bytes[offset + 2])
    if alpha < 255 {
      let scale = 255.0 / Double(alpha)
      red = min(Int((Double(red) * scale).rounded()), 255)
      green = min(Int((Double(green) * scale).rounded()), 255)
      blue = min(Int((Double(blue) * scale).rounded()), 255)
    }
    return (red, green, blue)
  }
}

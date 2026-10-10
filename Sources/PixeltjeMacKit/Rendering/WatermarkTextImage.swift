import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Rasterizes an export watermark's text.
///
/// Core Text rather than AppKit, so it can run inside the render actor without
/// touching a main-actor framework object, and sRGB rather than the working
/// space, so Core Image converts the glyphs like any other tagged image instead
/// of reinterpreting their numbers as linear.
enum WatermarkTextImage {
  /// The drawn text, its origin at zero, or `nil` when it cannot be drawn.
  static func make(_ text: String, pointSize: CGFloat) -> CIImage? {
    let line = text.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty, pointSize > 0 else { return nil }

    let font = CTFontCreateUIFontForLanguage(.system, pointSize, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    let white = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 1])
    let attributes: [String: Any] = [
      kCTFontAttributeName as String: font,
      kCTForegroundColorAttributeName as String: white as Any,
      kCTKernAttributeName as String: pointSize * 0.02,
    ]
    let attributed = CFAttributedStringCreate(nil, line as CFString, attributes as CFDictionary)
    guard let attributed else { return nil }
    let typeset = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(typeset, [.useOpticalBounds])
    guard bounds.width > 0, bounds.height > 0 else { return nil }

    // A shadow keeps the mark legible over a bright image; the padding gives it
    // room so it is not clipped at the bitmap edge.
    let blur = pointSize * 0.14
    let padding = ceil(blur * 2 + pointSize * 0.1)
    let width = Int(ceil(bounds.width + padding * 2))
    let height = Int(ceil(bounds.height + padding * 2))
    guard width > 0, height > 0,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    context.setShadow(
      offset: CGSize(width: 0, height: -pointSize * 0.04),
      blur: blur,
      color: CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 0.55])
    )
    context.textPosition = CGPoint(x: padding - bounds.minX, y: padding - bounds.minY)
    CTLineDraw(typeset, context)
    guard let image = context.makeImage() else { return nil }
    return CIImage(cgImage: image, options: [.colorSpace: colorSpace])
  }
}

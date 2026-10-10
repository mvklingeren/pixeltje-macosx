import CoreGraphics
import CoreImage
import CoreText
import Foundation
import PixeltjeMacDomain

/// Rasterizes a text layer for the compositor.
///
/// Text is set with Core Text into a Display P3 bitmap the size of the layer's
/// frame at the render resolution, so a proxy render sets smaller type instead
/// of scaling a full-size raster. The bitmap carries its color space, and
/// `CIImage(cgImage:)` converts it into the linear working space the way every
/// other placed pixel enters the pipeline.
enum TextLayerRenderer {
  /// The text drawn inside `target`, a rectangle in render pixels, or `nil`
  /// when there is nothing to draw.
  ///
  /// `scale` is render pixels per canvas pixel, which sizes the type.
  static func makeImage(
    _ text: TextLayer,
    target: CGRect,
    scale: CGFloat,
    workingColorSpace: CGColorSpace
  ) throws -> CIImage? {
    let width = Int(target.width.rounded(.up))
    let height = Int(target.height.rounded(.up))
    guard width > 0, height > 0, scale > 0,
      !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? workingColorSpace
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    else {
      throw PixeltjeMacError(
        "Text rendering failed",
        "Could not allocate the transparent text surface."
      )
    }
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.setShouldSmoothFonts(true)
    context.setAllowsFontSmoothing(true)

    let attributed = NSAttributedString(
      string: text.text,
      attributes: attributes(for: text, scale: scale, colorSpace: colorSpace)
    )
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)

    guard let cgImage = context.makeImage() else {
      throw PixeltjeMacError(
        "Text rendering failed",
        "Core Graphics did not produce text pixels."
      )
    }
    return CIImage(cgImage: cgImage)
      .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
  }

  private static func attributes(
    for text: TextLayer,
    scale: CGFloat,
    colorSpace: CGColorSpace
  ) -> [NSAttributedString.Key: Any] {
    let font = CTFontCreateWithName(text.fontName as CFString, text.fontSize * scale, nil)
    let color =
      CGColor(
        colorSpace: colorSpace,
        components: [text.color.red, text.color.green, text.color.blue, text.color.alpha]
      )
      ?? CGColor(
        red: text.color.red, green: text.color.green, blue: text.color.blue,
        alpha: text.color.alpha)
    let alignment: CTTextAlignment =
      switch text.alignment {
      case .leading: .left
      case .center: .center
      case .trailing: .right
      }
    // The setting borrows the value, so the pointer has to outlive the create
    // call rather than a temporary `&alignment` argument.
    let paragraphStyle = withUnsafePointer(to: alignment) { pointer in
      let settings = [
        CTParagraphStyleSetting(
          spec: .alignment,
          valueSize: MemoryLayout<CTTextAlignment>.size,
          value: pointer
        )
      ]
      return CTParagraphStyleCreate(settings, settings.count)
    }
    return [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
    ]
  }
}

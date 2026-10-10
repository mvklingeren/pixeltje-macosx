import CoreImage
import CoreGraphics
import Foundation

/// The backdrop the canvas is drawn against.
///
/// Two grids: a light one inside the canvas marking transparent pixels, and a
/// darker one outside it marking everything beyond the document extent. Both are
/// fixed in screen space and share a phase anchored at the drawable origin, so
/// they stay still while the canvas moves across them.
enum CanvasCheckerboard {
  /// sRGB greys. Authoring them here rather than as `CIColor` components is what
  /// keeps the conversion below the single place that has to be right.
  static let inside = (light: 1.0 as CGFloat, dark: 0.80 as CGFloat)
  // Keep the workspace related to the transparency grid instead of turning it
  // into a nearly black surround. It remains one shade darker, so the document
  // extent is still apparent without needing a heavy border.
  static let outside = (light: 0.72 as CGFloat, dark: 0.62 as CGFloat)
  static let squareSizeInPoints: CGFloat = 8

  /// An infinite-extent checkerboard. Callers crop it to the region they need.
  static func image(light: CGFloat, dark: CGFloat, squareSize: CGFloat) -> CIImage {
    guard
      let output = CIFilter(
        name: "CICheckerboardGenerator",
        parameters: [
          "inputCenter": CIVector(x: 0, y: 0),
          "inputColor0": color(light),
          "inputColor1": color(dark),
          "inputWidth": squareSize,
          "inputSharpness": 1.0,
        ]
      )?.outputImage
    else {
      return CIImage(color: color(dark))
    }
    return output
  }

  /// The canvas renders into extended linear Display P3, where `CIColor`
  /// components are linear light. Converting here is what keeps a "50% grey" from
  /// arriving on screen far too bright.
  static func color(_ srgb: CGFloat) -> CIColor {
    let value = linear(srgb)
    return CIColor(red: value, green: value, blue: value, alpha: 1)
  }

  static func linear(_ srgb: CGFloat) -> CGFloat {
    srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
  }
}

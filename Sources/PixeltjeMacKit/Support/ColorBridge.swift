import AppKit
import PixeltjeMacDomain
import SwiftUI

/// The one place the document's color types meet SwiftUI's `Color`.
///
/// Two color types are in play and they are not interchangeable: `VectorColor`
/// is gamma-encoded Display P3, the space vector and text colors are written
/// in, while `LinearRGBAColor` is the linear-light Extended Linear Display P3
/// working space the brush paints in. Both conversions go through a named
/// color space rather than a hand-rolled transfer function, so a color picked
/// once looks the same wherever it is used.

extension VectorColor {
  var swiftUIColor: Color {
    Color(.displayP3, red: red, green: green, blue: blue, opacity: alpha)
  }

  /// The picked color in Display P3 components, the space vector and text
  /// colors are written in.
  init(_ color: Color) {
    let converted = NSColor(color).usingColorSpace(.displayP3) ?? .white
    self.init(
      red: Double(converted.redComponent),
      green: Double(converted.greenComponent),
      blue: Double(converted.blueComponent),
      alpha: Double(converted.alphaComponent)
    )
  }

  /// Converts the shared linear working-space foreground/background color to
  /// the gamma-encoded Display P3 representation persisted by vector and text
  /// recipes.
  init(_ color: LinearRGBAColor) {
    self.init(color.swiftUIColor)
  }
}

extension LinearRGBAColor {
  /// The working-space color as something a `ColorPicker` can show.
  ///
  /// Components can sit outside 0...1 — the type allows the extended range an
  /// HDR document needs — which is exactly what the extended linear space is
  /// for, so they are handed over untouched rather than clamped here.
  var swiftUIColor: Color {
    guard let space = NSColorSpace.extendedLinearDisplayP3 else {
      return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
    let components = [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]
    return Color(nsColor: NSColor(colorSpace: space, components: components, count: 4))
  }

  /// The picked color converted into the linear-light working space.
  init(_ color: Color) {
    guard let space = NSColorSpace.extendedLinearDisplayP3,
      let converted = NSColor(color).usingColorSpace(space)
    else {
      self = .black
      return
    }
    self.init(
      red: Double(converted.redComponent),
      green: Double(converted.greenComponent),
      blue: Double(converted.blueComponent),
      alpha: Double(converted.alphaComponent)
    )
  }


  /// Converts a persisted vector/text color back into the shared linear
  /// working-space color state.
  init(_ color: VectorColor) {
    self.init(color.swiftUIColor)
  }

  var nsColor: NSColor {
    guard let space = NSColorSpace.extendedLinearDisplayP3 else { return .black }
    return NSColor(
      colorSpace: space,
      components: [red, green, blue, alpha].map { CGFloat($0) },
      count: 4
    )
  }

  init(_ color: NSColor) {
    guard let space = NSColorSpace.extendedLinearDisplayP3,
      let converted = color.usingColorSpace(space)
    else {
      self = .black
      return
    }
    self.init(
      red: Double(converted.redComponent),
      green: Double(converted.greenComponent),
      blue: Double(converted.blueComponent),
      alpha: Double(converted.alphaComponent)
    )
  }
}

extension NSColorSpace {
  /// The document's working space as an `NSColorSpace`, or `nil` on a system
  /// that does not publish it. Callers fall back rather than trapping, because
  /// a missing color space must not take a color well down with it.
  static let extendedLinearDisplayP3: NSColorSpace? = {
    guard let cgSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
      return nil
    }
    return NSColorSpace(cgColorSpace: cgSpace)
  }()
}

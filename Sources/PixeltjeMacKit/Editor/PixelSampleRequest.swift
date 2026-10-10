import Foundation
import PixeltjeMacDomain

/// A standing request for one pixel of the rendered frame.
///
/// Sampling a pixel is a one-shot action, not a mode, so it is an overlay on
/// whatever tool is active rather than a case of `EditorTool`. Arming it takes
/// the crosshair and the next click inside the image; the tool underneath is
/// never switched, so there is nothing to restore afterwards and no armed tool
/// left behind to swallow the click after that.
///
/// `purpose` says who asked. Only the white balance asks today, but a brush
/// colour, a levels black point and a gradient sample are all the same
/// gesture, and each would otherwise have arrived as another tool that owns no
/// drag and has no settings.
public struct PixelSampleRequest: Equatable, Sendable {
  public enum Purpose: Equatable, Sendable {
    case whiteBalance
    case foregroundColor
  }

  public var purpose: Purpose
  public var source: ColorSampleSource
  public var sampleSize: ColorSampleSize
  /// The result the pixel under the pointer would produce, or `nil` when the
  /// pointer is outside the image or that pixel yields nothing usable.
  ///
  /// This is what makes several samples comparable: the value is readable
  /// before it is committed, so choosing between two patches does not cost two
  /// undo steps.
  public var preview: PixelSamplePreview?

  public init(
    purpose: Purpose,
    source: ColorSampleSource = .composite,
    sampleSize: ColorSampleSize = .fiveByFive,
    preview: PixelSamplePreview? = nil
  ) {
    self.purpose = purpose
    self.source = source
    self.sampleSize = sampleSize
    self.preview = preview
  }
}

/// Which pixels an ordinary color pick reads.
public enum ColorSampleSource: String, CaseIterable, Equatable, Sendable {
  /// The complete visible result, including vector artwork.
  case composite
  /// The selected layer against transparency, after its own masks,
  /// adjustments, transform, fill and opacity, but before it interacts with
  /// layers beneath it. Enclosing group effects are deliberately excluded.
  case activeLayer

  public var label: String {
    switch self {
    case .composite: "Composite"
    case .activeLayer: "Active Layer"
    }
  }
}

/// The square image-pixel neighbourhood averaged by an ordinary color pick.
/// It is independent of the canvas zoom and clipped at image edges.
public enum ColorSampleSize: Int, CaseIterable, Equatable, Sendable {
  case point = 1
  case threeByThree = 3
  case fiveByFive = 5
  case elevenByEleven = 11

  public var label: String { self == .point ? "Point" : "\(rawValue)×\(rawValue)" }
}

public enum PixelSamplePreview: Equatable, Sendable {
  case whiteBalance(WhiteBalanceSamplePreview)
  case color(ColorSamplePreview)

  public var summary: String {
    switch self {
    case .whiteBalance(let preview): preview.summary
    case .color(let preview): preview.summary
    }
  }
}

/// A sampled working-space color and the color it would replace.
public struct ColorSamplePreview: Equatable, Sendable {
  public var oldColor: LinearRGBAColor
  public var newColor: LinearRGBAColor

  public init(oldColor: LinearRGBAColor, newColor: LinearRGBAColor) {
    self.oldColor = oldColor
    self.newColor = newColor
  }

  public var summary: String {
    let red = (newColor.red * 100).formatted(.number.precision(.fractionLength(0)))
    let green = (newColor.green * 100).formatted(.number.precision(.fractionLength(0)))
    let blue = (newColor.blue * 100).formatted(.number.precision(.fractionLength(0)))
    return "Linear Display P3 • R \(red)%  G \(green)%  B \(blue)%"
  }
}

/// The white balance the hovered pixel would ask for.
public struct WhiteBalanceSamplePreview: Equatable, Sendable {
  public var temperature: Double
  public var tint: Double

  public init(temperature: Double, tint: Double) {
    self.temperature = temperature
    self.tint = tint
  }

  /// The readout, in the units the two sliders are labelled with.
  public var summary: String {
    let kelvin = temperature.formatted(.number.precision(.fractionLength(0)))
    let tintValue = tint.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always()))
    return "\(kelvin) K, tint \(tintValue)"
  }
}

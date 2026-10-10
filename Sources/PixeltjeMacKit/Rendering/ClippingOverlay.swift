import CoreImage
import Foundation

/// Which clipping the canvas paints over the frame.
///
/// This is view state, not recipe state: it changes what the user is shown, and
/// never what the document develops or exports.
public struct ClippingIndicators: Equatable, Sendable {
  public var highlights: Bool
  public var shadows: Bool

  public init(highlights: Bool = false, shadows: Bool = false) {
    self.highlights = highlights
    self.shadows = shadows
  }

  public var isOn: Bool { highlights || shadows }

  /// What the J key does: one key arms or clears both indicators together.
  public var toggledTogether: ClippingIndicators {
    isOn ? ClippingIndicators() : ClippingIndicators(highlights: true, shadows: true)
  }
}

/// Marks clipped pixels on the displayed frame.
///
/// A Core Image pass in the display path, built from stock filters. It never
/// touches the recipe, so turning it on changes nothing about the document, the
/// render request, or the export; and it costs no re-render, so the indicator
/// answers the moment it is toggled.
///
/// Thresholds are read in the canvas working space, Extended Linear Display P3.
/// That space shares 0 and 1 with the display encoding, so "at or above 1" and
/// "at or below 0" mean the same clipping there as on screen, and EDR values
/// above 1 are correctly counted as clipped for this display.
enum ClippingOverlay {
  /// Just below 1, so a value that reaches white through half-float rounding
  /// still reads as clipped.
  static let highlightThreshold = 0.996
  /// Just above 0, matching the low end.
  static let shadowThreshold = 0.004

  static func apply(
    to image: CIImage,
    indicators: ClippingIndicators
  ) -> CIImage {
    guard indicators.isOn, !image.extent.isEmpty, !image.extent.isInfinite else { return image }
    var output = image
    if indicators.highlights {
      output = marking(
        output,
        // Any channel at the top clips, so the brightest channel decides. The
        // frame is first laid over black: a transparent pixel has no highlight
        // to blow, and black keeps it out of the mask.
        mask: mask(
          of: image.composited(over: opaque(.black, like: image)),
          component: "CIMaximumComponent",
          threshold: highlightThreshold,
          invert: false
        ),
        color: CIColor(red: 1, green: 0, blue: 0)
      )
    }
    if indicators.shadows {
      output = marking(
        output,
        // Every channel must be at the bottom, so the darkest channel decides.
        // Laid over white first, so transparency does not read as black.
        mask: mask(
          of: image.composited(over: opaque(.white, like: image)),
          component: "CIMinimumComponent",
          threshold: 1 - shadowThreshold,
          invert: true
        ),
        color: CIColor(red: 0, green: 0.35, blue: 1)
      )
    }
    return output.cropped(to: image.extent)
  }

  /// A black-and-white mask: white where the chosen component crosses the
  /// threshold.
  ///
  /// `CIColorThreshold` thresholds luminance, and both component filters emit a
  /// grey whose luminance is that component, so the pair reads a single channel
  /// extreme. Inverting first turns "at or below" into "at or above", which is
  /// the only form the threshold filter offers.
  private static func mask(
    of image: CIImage,
    component: String,
    threshold: Double,
    invert: Bool
  ) -> CIImage {
    var source = image.applyingFilter(component)
    if invert { source = source.applyingFilter("CIColorInvert") }
    return source.applyingFilter(
      "CIColorThreshold",
      parameters: ["inputThreshold": threshold]
    )
  }

  private static func marking(_ image: CIImage, mask: CIImage, color: CIColor) -> CIImage {
    let paint = CIImage(color: color).cropped(to: image.extent)
    return paint.applyingFilter(
      "CIBlendWithMask",
      parameters: [
        kCIInputBackgroundImageKey: image,
        kCIInputMaskImageKey: mask,
      ]
    )
  }

  private static func opaque(_ color: CIColor, like image: CIImage) -> CIImage {
    CIImage(color: color).cropped(to: image.extent)
  }
}

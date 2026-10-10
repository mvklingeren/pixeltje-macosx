import Foundation

/// One colour read from the linear working space.
///
/// The picker samples the developed image, not an encoded preview, so the
/// values are linear and unbounded: an EDR highlight is legitimately above 1
/// and a shadow can sit just above 0.
public struct LinearRGBSample: Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// Whether a chromaticity can be read from this sample at all.
  ///
  /// A pixel at or below black has no hue to neutralize, and a non-finite
  /// value means the sample never reached the CPU intact.
  public var isUsable: Bool {
    red.isFinite && green.isFinite && blue.isFinite && red > 0 && green > 0 && blue > 0
  }
}

/// The white-balance maths behind the picker.
///
/// The rules are deliberately small and framework-free so they can be tested on
/// synthetic colours without a RAW file, a GPU, or Core Image.
///
/// Model: `neutralTemperature` and `neutralTint` describe the illuminant the
/// decoder assumes. Telling the decoder the light was bluer (a higher kelvin
/// value) makes it warm the image; telling it the light was greener (a higher
/// tint value) makes it push the image toward magenta. So a sample that renders
/// warm asks for a lower temperature, and a sample that renders green asks for a
/// higher tint.
public enum NeutralWhiteBalance {
  /// D65, the white point of the Display P3 space the sample is measured in.
  /// A perfectly neutral sample lands here and changes nothing.
  public static let referenceTemperature = 6504.0
  public static let temperatureRange = 2000.0...50_000.0
  public static let tintRange = -150.0...150.0

  /// How much tint one stop of green excess asks for.
  ///
  /// A first-order approximation: `CIRAWFilter` does not publish the mapping
  /// from its tint units to a chromaticity offset, so this is calibrated to
  /// reach the end of the tint range at a very strong cast rather than derived.
  static let tintPerGreenStop = 150.0

  /// The CIE 1931 chromaticity of a linear Display P3 colour.
  ///
  /// Chromaticity is exposure independent, so a dark but coloured sample is
  /// still usable; only a black or negative one is not.
  public static func chromaticity(ofLinearDisplayP3 sample: LinearRGBSample) -> (x: Double, y: Double)? {
    guard sample.isUsable else { return nil }
    // Display P3 to CIE XYZ (D65), the standard matrix for the P3-D65 primaries.
    let x =
      0.486_570_9 * sample.red + 0.265_667_7 * sample.green + 0.198_217_3 * sample.blue
    let y =
      0.228_974_6 * sample.red + 0.691_738_5 * sample.green + 0.079_286_9 * sample.blue
    let z = 0.045_113_4 * sample.green + 1.043_944_4 * sample.blue
    let sum = x + y + z
    guard sum > 0, sum.isFinite else { return nil }
    return (x / sum, y / sum)
  }

  /// The correlated colour temperature of a chromaticity, by McCamy's
  /// approximation.
  ///
  /// Valid near the Planckian locus, which is where a sample the user calls
  /// neutral lives. A chromaticity far off the locus returns `nil` rather than
  /// a fabricated kelvin value.
  public static func correlatedColorTemperature(x: Double, y: Double) -> Double? {
    let denominator = 0.1858 - y
    guard abs(denominator) > 1e-6 else { return nil }
    let n = (x - 0.3320) / denominator
    let cct = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
    guard cct.isFinite, cct > 1000, cct < 100_000 else { return nil }
    return cct
  }

  /// How far the sample leans green, in stops, symmetric around neutral.
  ///
  /// Zero for any grey, positive for green, negative for magenta.
  public static func greenStops(of sample: LinearRGBSample) -> Double? {
    guard sample.isUsable else { return nil }
    let magenta = (sample.red * sample.blue).squareRoot()
    guard magenta > 0 else { return nil }
    return log2(sample.green / magenta)
  }

  /// The white balance that makes `sample` neutral, given the values it was
  /// developed with.
  ///
  /// Temperature is corrected in mireds, where an illuminant shift is roughly
  /// additive, and the result is clamped to the range the inspector exposes.
  public static func neutralizing(
    sample: LinearRGBSample,
    temperature: Double,
    tint: Double
  ) -> (temperature: Double, tint: Double)? {
    guard
      let chromaticity = chromaticity(ofLinearDisplayP3: sample),
      let sampleTemperature = correlatedColorTemperature(
        x: chromaticity.x, y: chromaticity.y),
      let greenStops = greenStops(of: sample),
      temperature > 0
    else { return nil }

    let mired = 1_000_000.0
    let correction = mired / sampleTemperature - mired / referenceTemperature
    let corrected = mired / (mired / temperature + correction)
    guard corrected.isFinite, corrected > 0 else { return nil }

    return (
      temperature: corrected.clamped(to: temperatureRange),
      tint: (tint + greenStops * tintPerGreenStop).clamped(to: tintRange)
    )
  }
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

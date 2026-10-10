import Foundation

/// Pure math for the 1D tone lookup tables the renderer applies in the
/// Display P3 transfer encoding.
///
/// A table is `sampleCount` RGB triplets of `Float` over the input domain 0…1.
/// Every builder returns the identity table for neutral inputs, and every
/// table is non-decreasing per channel.
public enum ToneLookupTable {
  public static let defaultSampleCount = 256

  /// The identity table.
  public static func identity(sampleCount: Int = defaultSampleCount) -> [Float] {
    table(sampleCount: sampleCount) { x in (x, x, x) }
  }

  /// The basic tone table: blacks and whites remap the endpoints, contrast is a
  /// fixed-endpoint S curve around middle gray.
  ///
  /// - Blacks: +100 lifts the black point by 0.15, -100 crushes everything
  ///   below 0.15 to black.
  /// - Whites: +100 maps 0.75 to white, -100 maps white to 0.8.
  /// - Contrast: `y - k·sin(2πy)` with `k = ±0.15` at ±100, which keeps the
  ///   endpoints fixed and the slope positive.
  public static func basicTone(
    blacks: Double,
    whites: Double,
    contrast: Double,
    sampleCount: Int = defaultSampleCount
  ) -> [Float] {
    let blackPoint = -clampAmount(blacks) * 0.15
    let whitePoint = 1 - clampAmount(whites) * 0.25
    let k = clampAmount(contrast) * 0.15
    return table(sampleCount: sampleCount) { x in
      let y = basicToneValue(x, blackPoint: blackPoint, whitePoint: whitePoint, contrast: k)
      return (y, y, y)
    }
  }

  /// One sample of the basic tone curve, exposed for tests.
  public static func basicToneValue(
    _ x: Double, blackPoint: Double, whitePoint: Double, contrast: Double
  ) -> Double {
    let span = max(whitePoint - blackPoint, 0.01)
    var y = min(max((x - blackPoint) / span, 0), 1)
    y -= contrast * sin(2 * Double.pi * y)
    return min(max(y, 0), 1)
  }

  /// Builds a table from a per-sample function and enforces monotonicity per
  /// channel so a table can never invert tones.
  public static func table(
    sampleCount: Int,
    _ sample: (Double) -> (Double, Double, Double)
  ) -> [Float] {
    let count = max(sampleCount, 2)
    var values = [Float](repeating: 0, count: count * 3)
    var previous: (Double, Double, Double) = (0, 0, 0)
    for index in 0..<count {
      let x = Double(index) / Double(count - 1)
      var (r, g, b) = sample(x)
      r = min(max(r, 0), 1)
      g = min(max(g, 0), 1)
      b = min(max(b, 0), 1)
      if index > 0 {
        r = max(r, previous.0)
        g = max(g, previous.1)
        b = max(b, previous.2)
      }
      previous = (r, g, b)
      values[index * 3] = Float(r)
      values[index * 3 + 1] = Float(g)
      values[index * 3 + 2] = Float(b)
    }
    return values
  }

  private static func clampAmount(_ amount: Double) -> Double {
    min(max(amount / 100, -1), 1)
  }
}

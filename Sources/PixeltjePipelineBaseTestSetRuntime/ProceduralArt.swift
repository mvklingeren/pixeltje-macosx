import Foundation

/// Deterministic, model-free image sources and spatial controls for native graphs.
enum ProceduralArt {
  struct Sinusoid: Sendable {
    let cycles: Double
    let amplitude: Double
    let phaseDegrees: Double
    let centerY: Double
  }

  /// A resolution-independent curve over normalized horizontal and vertical coordinates.
  enum Curve1D: Sendable {
    case sinusoid(Sinusoid)

    var summary: String {
      switch self {
      case .sinusoid(let wave):
        "Sinusoid \(wave.cycles) cycles, amplitude \(wave.amplitude), phase \(wave.phaseDegrees)°"
      }
    }

    func verticalPosition(at x: Double) -> Double {
      switch self {
      case .sinusoid(let wave):
        wave.centerY + wave.amplitude
          * sin(2 * .pi * wave.cycles * x + wave.phaseDegrees * .pi / 180)
      }
    }
  }

  static func makeSinusoid(
    cycles: Double, amplitude: Double, phaseDegrees: Double, centerY: Double,
    frequencyControl: Double?, amplitudeControl: Double?, phaseShiftDegrees: Double?
  ) throws -> Sinusoid {
    guard cycles.isFinite, (0.1...24).contains(cycles),
      amplitude.isFinite, (0...0.45).contains(amplitude),
      phaseDegrees.isFinite, (-36_000...36_000).contains(phaseDegrees),
      phaseShiftDegrees?.isFinite ?? true,
      centerY.isFinite, (0...1).contains(centerY),
      [frequencyControl, amplitudeControl].compactMap({ $0 }).allSatisfy({
        $0.isFinite && (0...1).contains($0)
      })
    else { throw BaseTestSetError.invalid("Sinusoid settings are out of range.") }
    return Sinusoid(
      cycles: min(24, max(0.1, cycles * (0.5 + (frequencyControl ?? 0.5)))),
      amplitude: min(0.45, amplitude * (0.25 + 1.5 * (amplitudeControl ?? 0.5))),
      phaseDegrees: (phaseDegrees + (phaseShiftDegrees ?? 0)
        .truncatingRemainder(dividingBy: 360))
        .truncatingRemainder(dividingBy: 360),
      centerY: centerY)
  }

  static func drawCurve(
    curve: Curve1D, background: BaseTestSetImage?, width: Int, height: Int,
    strokeWidth: Double, color: String, opacity: Double
  ) throws -> (image: BaseTestSetImage, mask: BaseTestSetMask) {
    try BaseTestSetImage.validateDimensions(width: width, height: height)
    guard strokeWidth.isFinite, (0.5...32).contains(strokeWidth),
      opacity.isFinite, (0...1).contains(opacity),
      let lineColor = curveColor(color)
    else {
      throw BaseTestSetError.invalid("Curve drawing settings are out of range.")
    }
    let base: BaseTestSetImage
    if let background {
      base = background.width == width && background.height == height
        ? background : try background.resized(to: width, height, method: "bilinear")
    } else {
      base = try BaseTestSetImage(width: width, height: height, fill: (0, 0, 0, 0))
    }
    var mask = try rasterizeCurveMask(
      curve, width: width, height: height, strokeWidth: strokeWidth)
    if opacity < 1 {
      for index in mask.values.indices { mask.values[index] *= Float(opacity) }
    }
    let plate = try BaseTestSetImage(width: width, height: height,
      fill: (Float(lineColor.0), Float(lineColor.1), Float(lineColor.2), 1))
    let image = try base.compositingSRGB(
      plate, through: mask, x: 0, y: 0, resizeSource: false)
    return (image, mask)
  }

  static func noise(
    seed: Int, width: Int, height: Int, scale: Double, octaves: Int,
    salt: Int, pattern: String, palette: String
  ) throws -> (image: BaseTestSetImage, height: BaseTestSetMask) {
    try BaseTestSetImage.validateDimensions(width: width, height: height)
    guard scale.isFinite, (1...64).contains(scale), (1...6).contains(octaves),
      ["smooth", "mosaic"].contains(pattern), let colors = palettes[palette]
    else { throw BaseTestSetError.invalid("Procedural noise settings are out of range.") }
    let key = UInt64(bitPattern: Int64(seed)) ^
      (UInt64(bitPattern: Int64(salt)) &* 0x9E3779B97F4A7C15)
    var image = try BaseTestSetImage(width: width, height: height)
    var mask = try BaseTestSetMask(width: width, height: height, value: 0)
    let block = max(3, Int(Double(min(width, height)) / (scale * 3)))
    for y in 0..<height {
      for x in 0..<width {
        let sampleX = pattern == "mosaic" ? (x / block) * block + block / 2 : x
        let sampleY = pattern == "mosaic" ? (y / block) * block + block / 2 : y
        let u = (Double(sampleX) + 0.5) / Double(width) * scale
        let v = (Double(sampleY) + 0.5) / Double(height) * scale
        var frequency = 1.0
        var amplitude = 1.0
        var sum = 0.0
        var weight = 0.0
        for octave in 0..<octaves {
          sum += amplitude * valueNoise(u * frequency, v * frequency,
            key: key &+ UInt64(octave) &* 0xD1B54A32D192ED03)
          weight += amplitude
          frequency *= 2
          amplitude *= 0.5
        }
        let value = min(max(0.5 + (sum / weight - 0.5) * 1.65, 0), 1)
        let index = y * width + x
        mask.values[index] = Float(value)
        let color = color(at: value, stops: colors)
        let offset = index * 4
        image.rgba[offset] = Float(color.0)
        image.rgba[offset + 1] = Float(color.1)
        image.rgba[offset + 2] = Float(color.2)
        image.rgba[offset + 3] = 1
      }
    }
    return (image, mask)
  }

  static func sinusoid(
    width: Int, height: Int, cycles: Double, amplitude: Double,
    phaseDegrees: Double, centerY: Double, strokeWidth: Double, color: String,
    frequencyControl: Double?, amplitudeControl: Double?
  ) throws -> (image: BaseTestSetImage, mask: BaseTestSetMask) {
    try BaseTestSetImage.validateDimensions(width: width, height: height)
    guard cycles.isFinite, (0.1...24).contains(cycles),
      amplitude.isFinite, (0...0.45).contains(amplitude),
      phaseDegrees.isFinite, (-36_000...36_000).contains(phaseDegrees),
      centerY.isFinite, (0...1).contains(centerY),
      strokeWidth.isFinite, (0.5...32).contains(strokeWidth),
      let lineColor = sinusoidColors[color],
      [frequencyControl, amplitudeControl].compactMap({ $0 }).allSatisfy({
        $0.isFinite && (0...1).contains($0)
      })
    else { throw BaseTestSetError.invalid("Sinus generator settings are out of range.") }
    let waveCycles = frequencyControl.map { 1 + 6 * $0 } ?? cycles
    let waveAmplitude = amplitudeControl.map { 0.04 + 0.36 * $0 } ?? amplitude
    let curve = Curve1D.sinusoid(Sinusoid(
      cycles: waveCycles, amplitude: waveAmplitude,
      phaseDegrees: phaseDegrees, centerY: centerY))
    let image = try BaseTestSetImage(width: width, height: height,
      fill: (Float(lineColor.0), Float(lineColor.1), Float(lineColor.2), 1))
    let mask = try rasterizeCurveMask(
      curve, width: width, height: height, strokeWidth: strokeWidth)
    return (image, mask)
  }

  private static func rasterizeCurveMask(
    _ curve: Curve1D, width: Int, height: Int, strokeWidth: Double
  ) throws -> BaseTestSetMask {
    let sigma = strokeWidth / 2.355
    let glowSigma = sigma * 3.2
    let reach = Int(ceil(glowSigma * 4))
    var mask = try BaseTestSetMask(width: width, height: height, value: 0)
    for x in 0..<width {
      let fraction = Double(x) / Double(max(width - 1, 1))
      let center = curve.verticalPosition(at: fraction) * Double(height - 1)
      let first = max(0, Int(floor(center)) - reach)
      let last = min(height - 1, Int(ceil(center)) + reach)
      guard first <= last else { continue }
      for y in first...last {
        let distance = abs(Double(y) - center)
        let core = exp(-0.5 * pow(distance / sigma, 2))
        let glow = 0.17 * exp(-0.5 * pow(distance / glowSigma, 2))
        mask.values[y * width + x] = Float(min(1, core + glow))
      }
    }
    return mask
  }

  static func radialMask(
    width: Int, height: Int, centerX: Double, centerY: Double,
    radius: Double, softness: Double
  ) throws -> BaseTestSetMask {
    guard centerX.isFinite, centerY.isFinite, radius.isFinite, softness.isFinite,
      (0...1).contains(centerX), (0...1).contains(centerY),
      radius > 0, radius <= 2, softness >= 0, softness <= radius
    else { throw BaseTestSetError.invalid("Radial mask settings are out of range.") }
    var mask = try BaseTestSetMask(width: width, height: height, value: 0)
    let aspect = Double(width) / Double(height)
    for y in 0..<height {
      for x in 0..<width {
        let dx = ((Double(x) + 0.5) / Double(width) - centerX) * aspect
        let dy = (Double(y) + 0.5) / Double(height) - centerY
        let distance = hypot(dx, dy)
        let coverage: Double
        if softness == 0 {
          coverage = distance <= radius ? 1 : 0
        } else {
          coverage = 1 - smoothstep((distance - (radius - softness)) / softness)
        }
        mask.values[y * width + x] = Float(coverage)
      }
    }
    return mask
  }

  static func stripeMask(
    width: Int, height: Int, count: Int, duty: Double,
    phase: Double, orientation: String
  ) throws -> BaseTestSetMask {
    guard (1...128).contains(count), duty.isFinite, (0...1).contains(duty),
      phase.isFinite, ["horizontal", "vertical"].contains(orientation)
    else { throw BaseTestSetError.invalid("Stripe mask settings are out of range.") }
    var mask = try BaseTestSetMask(width: width, height: height, value: 0)
    let horizontal = orientation == "horizontal"
    let extent = horizontal ? height : width
    let edge = min(0.08, Double(count) / Double(extent))
    for y in 0..<height {
      for x in 0..<width {
        let coordinate = Double(horizontal ? y : x) + 0.5
        let position = (coordinate / Double(extent) * Double(count) + phase)
          .truncatingRemainder(dividingBy: 1)
        let wrapped = position < 0 ? position + 1 : position
        let opening = smoothstep(wrapped / edge)
        let closing = smoothstep((duty - wrapped) / edge)
        mask.values[y * width + x] = Float(opening * closing)
      }
    }
    return mask
  }

  static func translate(_ image: BaseTestSetImage, x: Int, y: Int, wrap: Bool)
    throws -> BaseTestSetImage {
    guard (-8192...8192).contains(x), (-8192...8192).contains(y) else {
      throw BaseTestSetError.invalid("Image translation is out of range.")
    }
    var output = try BaseTestSetImage(width: image.width, height: image.height,
      fill: (0, 0, 0, 0))
    for targetY in 0..<image.height {
      let sourceY = targetY - y
      if !wrap && !(0..<image.height).contains(sourceY) { continue }
      let wrappedY = (sourceY % image.height + image.height) % image.height
      for targetX in 0..<image.width {
        let sourceX = targetX - x
        if !wrap && !(0..<image.width).contains(sourceX) { continue }
        let wrappedX = (sourceX % image.width + image.width) % image.width
        let source = (wrappedY * image.width + wrappedX) * 4
        let target = (targetY * image.width + targetX) * 4
        output.rgba[target..<(target + 4)] = image.rgba[source..<(source + 4)]
      }
    }
    return output
  }

  private typealias Color = (Double, Double, Double)
  private static let palettes: [String: [Color]] = [
    "night": [(0.012, 0.025, 0.07), (0.07, 0.13, 0.25), (0.3, 0.12, 0.35)],
    "aurora": [(0.01, 0.15, 0.22), (0.09, 0.69, 0.54), (0.95, 0.81, 0.33)],
    "coral": [(0.15, 0.025, 0.12), (0.87, 0.25, 0.3), (1, 0.8, 0.48)],
    "paper": [(0.75, 0.72, 0.65), (0.92, 0.89, 0.81), (1, 0.98, 0.92)],
    "inkBlue": [(0.015, 0.06, 0.15), (0.06, 0.21, 0.38), (0.22, 0.47, 0.58)],
    "inkCoral": [(0.22, 0.035, 0.08), (0.69, 0.16, 0.16), (0.95, 0.48, 0.25)],
    "neon": [(0.03, 0.02, 0.15), (0.46, 0.08, 0.63), (0.1, 0.93, 0.91)],
  ]
  private static let sinusoidColors: [String: Color] = [
    "red": (1, 0.24, 0.3),
    "green": (0.3, 1, 0.56),
    "blue": (0.37, 0.63, 1),
  ]

  private static func curveColor(_ name: String) -> Color? {
    if let named = sinusoidColors[name] { return named }
    guard name.count == 7, name.first == "#",
      let rgb = UInt32(String(name.dropFirst()), radix: 16)
    else { return nil }
    return (Double((rgb >> 16) & 0xFF) / 255,
      Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
  }

  private static func color(at value: Double, stops: [Color]) -> Color {
    let doubled = value * 2
    let index = min(Int(doubled), 1)
    let fraction = doubled - Double(index)
    let a = stops[index]
    let b = stops[index + 1]
    return (a.0 + (b.0 - a.0) * fraction,
      a.1 + (b.1 - a.1) * fraction,
      a.2 + (b.2 - a.2) * fraction)
  }

  private static func valueNoise(_ x: Double, _ y: Double, key: UInt64) -> Double {
    let ix = Int(floor(x))
    let iy = Int(floor(y))
    let tx = smoothstep(x - Double(ix))
    let ty = smoothstep(y - Double(iy))
    let a = random(ix, iy, key: key)
    let b = random(ix + 1, iy, key: key)
    let c = random(ix, iy + 1, key: key)
    let d = random(ix + 1, iy + 1, key: key)
    return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
  }

  private static func random(_ x: Int, _ y: Int, key: UInt64) -> Double {
    var value = key ^ (UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15)
      ^ (UInt64(bitPattern: Int64(y)) &* 0xD1B54A32D192ED03)
    value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
    value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
    value ^= value >> 31
    return Double(value >> 11) / Double(1 << 53)
  }

  private static func smoothstep(_ value: Double) -> Double {
    let t = min(max(value, 0), 1)
    return t * t * (3 - 2 * t)
  }
}

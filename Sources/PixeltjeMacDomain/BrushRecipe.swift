import Foundation

/// Hard limits shared by decoding, input capture, and rendering.
///
/// They make malformed project files and runaway tablet streams finite without
/// putting any framework or GPU policy into the saved recipe.
public enum BrushLimits {
  public static let minimumSize = 0.25
  public static let maximumSize = 2_048.0
  public static let maximumCanvasAxis = 131_072
  public static let maximumSamplesPerStroke = 65_536
  public static let maximumStampsPerStroke = 262_144
  public static let minimumSpacing = 0.02
  public static let maximumSpacing = 1.0
}

public struct BrushEngineVersion: RawRepresentable, Codable, Equatable, Sendable {
  public var rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = max(rawValue, 1)
  }

  public static let version1 = BrushEngineVersion(rawValue: 1)
  public static let current = BrushEngineVersion(rawValue: 2)
}

public enum BrushStrokeMode: String, Codable, Equatable, Sendable {
  case paint
  case erase
}

/// A stable, linear-light color in the document's Extended Linear Display P3
/// working space. Values are straight (not premultiplied); the renderer
/// premultiplies them by the stamp coverage before source-over compositing.
public struct LinearRGBAColor: Codable, Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = Self.component(red)
    self.green = Self.component(green)
    self.blue = Self.component(blue)
    self.alpha = Self.unit(alpha)
  }

  public static let black = LinearRGBAColor(red: 0, green: 0, blue: 0)
  public static let white = LinearRGBAColor(red: 1, green: 1, blue: 1)

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      red: try values.decodeIfPresent(Double.self, forKey: .red) ?? 0,
      green: try values.decodeIfPresent(Double.self, forKey: .green) ?? 0,
      blue: try values.decodeIfPresent(Double.self, forKey: .blue) ?? 0,
      alpha: try values.decodeIfPresent(Double.self, forKey: .alpha) ?? 1
    )
  }

  private static func component(_ value: Double) -> Double {
    value.isFinite ? min(max(value, -0.5), 16) : 0
  }

  private static func unit(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : 1
  }

  private enum CodingKeys: String, CodingKey {
    case red, green, blue, alpha
  }
}

/// Settings copied from tool state into every completed stroke.
public struct BrushSettings: Codable, Equatable, Sendable {
  public var size: Double
  public var hardness: Double
  public var opacity: Double
  public var flow: Double
  /// Stamp separation as a fraction of the unpressured diameter.
  public var spacing: Double
  /// Zero gives mouse-like constant pressure; one follows the tablet pressure.
  public var pressureResponse: Double

  public init(
    size: Double = 40,
    hardness: Double = 0.8,
    opacity: Double = 1,
    flow: Double = 1,
    spacing: Double = 0.12,
    pressureResponse: Double = 0.75
  ) {
    self.size = Self.clamp(
      size, BrushLimits.minimumSize...BrushLimits.maximumSize, fallback: 40)
    self.hardness = Self.clamp(hardness, 0...1, fallback: 0.8)
    self.opacity = Self.clamp(opacity, 0...1, fallback: 1)
    self.flow = Self.clamp(flow, 0...1, fallback: 1)
    self.spacing = Self.clamp(
      spacing, BrushLimits.minimumSpacing...BrushLimits.maximumSpacing, fallback: 0.12)
    self.pressureResponse = Self.clamp(pressureResponse, 0...1, fallback: 0.75)
  }

  public var validated: BrushSettings {
    BrushSettings(
      size: size,
      hardness: hardness,
      opacity: opacity,
      flow: flow,
      spacing: spacing,
      pressureResponse: pressureResponse
    )
  }

  public func mappedPressure(_ pressure: Double) -> Double {
    let normalized = Self.clamp(pressure, 0...1, fallback: 1)
    return 1 - pressureResponse + pressureResponse * normalized
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      size: try values.decodeIfPresent(Double.self, forKey: .size) ?? 40,
      hardness: try values.decodeIfPresent(Double.self, forKey: .hardness) ?? 0.8,
      opacity: try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
      flow: try values.decodeIfPresent(Double.self, forKey: .flow) ?? 1,
      spacing: try values.decodeIfPresent(Double.self, forKey: .spacing) ?? 0.12,
      pressureResponse: try values.decodeIfPresent(Double.self, forKey: .pressureResponse) ?? 0.75
    )
  }

  private static func clamp(
    _ value: Double,
    _ range: ClosedRange<Double>,
    fallback: Double
  ) -> Double {
    value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
  }

  private enum CodingKeys: String, CodingKey {
    case size, hardness, opacity, flow, spacing, pressureResponse
  }
}

/// One input event after conversion into canonical bottom-left canvas pixels.
public struct BrushSample: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var pressure: Double
  /// Normalized tablet tilt components in `-1...1`.
  public var tiltX: Double
  public var tiltY: Double
  /// Tablet barrel rotation in degrees, normalized to `0..<360`.
  public var rotationDegrees: Double
  /// Whether this sample's input device supplied a barrel-rotation value.
  /// A reported zero is valid and must not be confused with mouse input.
  public var reportsRotation: Bool
  /// Seconds since the first sample in this stroke.
  public var elapsedTime: Double
  public var sequence: UInt64

  public init(
    x: Double,
    y: Double,
    pressure: Double = 1,
    tiltX: Double = 0,
    tiltY: Double = 0,
    rotationDegrees: Double = 0,
    reportsRotation: Bool = false,
    elapsedTime: Double = 0,
    sequence: UInt64 = 0
  ) {
    self.x = Self.coordinate(x)
    self.y = Self.coordinate(y)
    self.pressure = Self.unit(pressure, fallback: 1)
    self.tiltX = Self.signedUnit(tiltX)
    self.tiltY = Self.signedUnit(tiltY)
    self.rotationDegrees = Self.rotation(rotationDegrees)
    self.reportsRotation = reportsRotation
    self.elapsedTime = elapsedTime.isFinite ? min(max(elapsedTime, 0), 86_400) : 0
    self.sequence = sequence
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      x: try values.decodeIfPresent(Double.self, forKey: .x) ?? 0,
      y: try values.decodeIfPresent(Double.self, forKey: .y) ?? 0,
      pressure: try values.decodeIfPresent(Double.self, forKey: .pressure) ?? 1,
      tiltX: try values.decodeIfPresent(Double.self, forKey: .tiltX) ?? 0,
      tiltY: try values.decodeIfPresent(Double.self, forKey: .tiltY) ?? 0,
      rotationDegrees: try values.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
      reportsRotation: try values.decodeIfPresent(Bool.self, forKey: .reportsRotation) ?? false,
      elapsedTime: try values.decodeIfPresent(Double.self, forKey: .elapsedTime) ?? 0,
      sequence: try values.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
    )
  }

  private static func coordinate(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    let limit = Double(BrushLimits.maximumCanvasAxis)
    return min(max(value, -limit), limit * 2)
  }

  private static func unit(_ value: Double, fallback: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : fallback
  }

  private static func signedUnit(_ value: Double) -> Double {
    value.isFinite ? min(max(value, -1), 1) : 0
  }

  private static func rotation(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    let normalized = value.truncatingRemainder(dividingBy: 360)
    return normalized >= 0 ? normalized : normalized + 360
  }

  private enum CodingKeys: String, CodingKey {
    case x, y, pressure, tiltX, tiltY, rotationDegrees, reportsRotation, elapsedTime, sequence
  }

  public func translated(byX deltaX: Double, y deltaY: Double) -> BrushSample {
    BrushSample(
      x: x + deltaX,
      y: y + deltaY,
      pressure: pressure,
      tiltX: tiltX,
      tiltY: tiltY,
      rotationDegrees: rotationDegrees,
      reportsRotation: reportsRotation,
      elapsedTime: elapsedTime,
      sequence: sequence
    )
  }

  public func scaled(byX scaleX: Double, y scaleY: Double) -> BrushSample {
    BrushSample(
      x: x * scaleX,
      y: y * scaleY,
      pressure: pressure,
      tiltX: tiltX,
      tiltY: tiltY,
      rotationDegrees: rotationDegrees,
      reportsRotation: reportsRotation,
      elapsedTime: elapsedTime,
      sequence: sequence
    )
  }
}

/// A renderer-ready round stamp. It remains framework-light so interpolation
/// and pressure behavior can be tested without Metal.
public struct BrushStamp: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var diameter: Double
  public var opacity: Double
  /// Minor/major diameter ratio, used by elliptical and chisel tips.
  public var aspectRatio: Double
  /// Brush-local orientation measured counter-clockwise in canvas space.
  public var angleRadians: Double
  public var shape: BrushTipShape
  public var grain: BrushGrain
  public var grainAmount: Double

  public init(
    x: Double, y: Double, diameter: Double, opacity: Double,
    aspectRatio: Double = 1, angleRadians: Double = 0,
    shape: BrushTipShape = .round, grain: BrushGrain = .none, grainAmount: Double = 0
  ) {
    self.x = x
    self.y = y
    self.diameter = diameter
    self.opacity = opacity
    self.aspectRatio = aspectRatio
    self.angleRadians = angleRadians
    self.shape = shape
    self.grain = grain
    self.grainAmount = grainAmount
  }
}

public struct PaintStroke: Codable, Equatable, Sendable {
  public var engineVersion: BrushEngineVersion
  public var seed: UInt64
  public var mode: BrushStrokeMode
  public var settings: BrushSettings
  /// The complete version-2 appearance snapshot. `nil` means the original
  /// version-1 round-stamp behavior, even after the app gains later presets.
  public var brush: BrushDefinition?
  public var color: LinearRGBAColor
  /// The active selection captured when this stroke began. Keeping it on the
  /// stroke makes replay independent of later selection changes.
  public var selectionClip: MaskRecipe?
  public var samples: [BrushSample]

  public init(
    engineVersion: BrushEngineVersion = .current,
    seed: UInt64 = 0,
    mode: BrushStrokeMode = .paint,
    settings: BrushSettings = BrushSettings(),
    brush: BrushDefinition? = nil,
    color: LinearRGBAColor = .black,
    selectionClip: MaskRecipe? = nil,
    samples: [BrushSample]
  ) {
    self.engineVersion = engineVersion
    self.seed = seed
    self.mode = mode
    self.settings = settings.validated
    self.brush = engineVersion.rawValue >= BrushEngineVersion.current.rawValue
      ? (brush ?? BrushCatalog.preset(.hardRound).definition)
      : nil
    self.color = color
    self.selectionClip = selectionClip
    self.samples = Array(samples.prefix(BrushLimits.maximumSamplesPerStroke))
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      engineVersion: try values.decodeIfPresent(BrushEngineVersion.self, forKey: .engineVersion)
        ?? .version1,
      seed: try values.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0,
      mode: try values.decodeIfPresent(BrushStrokeMode.self, forKey: .mode) ?? .paint,
      settings: try values.decodeIfPresent(BrushSettings.self, forKey: .settings)
        ?? BrushSettings(),
      brush: try values.decodeIfPresent(BrushDefinition.self, forKey: .brush),
      color: try values.decodeIfPresent(LinearRGBAColor.self, forKey: .color) ?? .black,
      selectionClip: try values.decodeIfPresent(MaskRecipe.self, forKey: .selectionClip),
      samples: try values.decodeIfPresent([BrushSample].self, forKey: .samples) ?? []
    )
  }

  /// Deterministically resamples event positions at fixed canvas-pixel
  /// intervals. A one-sample stroke is deliberately one stamp, so a click is a
  /// visible dot.
  public func interpolatedStamps() -> [BrushStamp] {
    guard let first = samples.first else { return [] }
    let settings = settings.validated
    let definition = brush
    let distancePerStamp = max(0.25, settings.size * settings.spacing)
    // A shaped tip needs an orientation on its opening stamp too. Looking ahead
    // to the first sample that actually moves keeps the start of a flat or
    // chisel stroke aligned with the stroke instead of lying at zero degrees.
    let openingDirection = samples.dropFirst()
      .first { $0.x != first.x || $0.y != first.y }
      .map { atan2($0.y - first.y, $0.x - first.x) } ?? 0
    var stamps = [
      stamp(for: first, direction: openingDirection, settings: settings, definition: definition)
    ]
    var untilNext = distancePerStamp

    for (start, end) in zip(samples, samples.dropFirst()) {
      let dx = end.x - start.x
      let dy = end.y - start.y
      let distance = hypot(dx, dy)
      guard distance.isFinite, distance > 0 else { continue }
      let segmentDirection = atan2(dy, dx)
      var travelled = untilNext
      while travelled <= distance, stamps.count < BrushLimits.maximumStampsPerStroke {
        let t = travelled / distance
        let interpolated = BrushSample(
          x: start.x + dx * t,
          y: start.y + dy * t,
          pressure: start.pressure + (end.pressure - start.pressure) * t,
          tiltX: start.tiltX + (end.tiltX - start.tiltX) * t,
          tiltY: start.tiltY + (end.tiltY - start.tiltY) * t,
          rotationDegrees: start.rotationDegrees
            + (end.rotationDegrees - start.rotationDegrees) * t,
          reportsRotation: start.reportsRotation || end.reportsRotation,
          elapsedTime: start.elapsedTime + (end.elapsedTime - start.elapsedTime) * t,
          sequence: end.sequence
        )
        stamps.append(
          stamp(
            for: interpolated, direction: segmentDirection, settings: settings,
            definition: definition))
        travelled += distancePerStamp
      }
      untilNext = travelled - distance
    }
    return stamps
  }

  private func stamp(
    for sample: BrushSample,
    direction: Double,
    settings: BrushSettings,
    definition: BrushDefinition?
  ) -> BrushStamp {
    let pressure = settings.mappedPressure(sample.pressure)
    guard let definition else {
      return BrushStamp(
        x: sample.x, y: sample.y, diameter: settings.size * max(pressure, 0.05),
        opacity: settings.opacity * settings.flow * pressure)
    }
    let sizePressure = definition.pressureAffectsSize ? pressure : 1
    let opacityPressure = definition.pressureAffectsOpacity ? pressure : 1
    let tiltMagnitude = min(hypot(sample.tiltX, sample.tiltY), 1)
    // Laying a pencil or a pastel over on its side shades with the flank of
    // the tip. The mark grows along the lean and stays about as wide as the
    // upright point, so it covers more paper with less pigment per pixel.
    // Dividing the aspect ratio by the same factor is what holds that width.
    let tiltBroadening = definition.tiltShading ? 1 + 1.5 * tiltMagnitude : 1
    let tiltLightening = definition.tiltShading ? 1 / (1 + 0.6 * tiltMagnitude) : 1
    let angle: Double
    switch definition.orientation {
    case .fixed: angle = 0
    case .strokeDirection: angle = direction
    case .barrelRotation: angle = sample.reportsRotation ? sample.rotationDegrees * .pi / 180 : direction
    case .tilt: angle = tiltMagnitude > 0.001 ? atan2(sample.tiltY, sample.tiltX) : direction
    }
    return BrushStamp(
      x: sample.x,
      y: sample.y,
      diameter: settings.size * max(sizePressure, 0.05) * tiltBroadening,
      opacity: settings.opacity * settings.flow * opacityPressure * tiltLightening,
      aspectRatio: definition.aspectRatio / tiltBroadening,
      angleRadians: angle,
      shape: definition.tipShape,
      grain: definition.grain,
      grainAmount: definition.grainAmount
    )
  }

  private enum CodingKeys: String, CodingKey {
    case engineVersion, seed, mode, settings, brush, color, selectionClip, samples
  }

  public func translated(byX deltaX: Double, y deltaY: Double) -> PaintStroke {
    PaintStroke(
      engineVersion: engineVersion,
      seed: seed,
      mode: mode,
      settings: settings,
      brush: brush,
      color: color,
      selectionClip: selectionClip,
      samples: samples.map { $0.translated(byX: deltaX, y: deltaY) }
    )
  }

  public func scaled(byX scaleX: Double, y scaleY: Double) -> PaintStroke {
    var scaledSettings = settings
    let coverageScale = max((abs(scaleX) + abs(scaleY)) / 2, 0.000_1)
    scaledSettings.size *= coverageScale
    return PaintStroke(
      engineVersion: engineVersion,
      seed: seed,
      mode: mode,
      settings: scaledSettings,
      brush: brush,
      color: color,
      selectionClip: selectionClip?.scalingCoverage(by: coverageScale),
      samples: samples.map { $0.scaled(byX: scaleX, y: scaleY) }
    )
  }
}

/// The common stroke-surface boundary used by color paint today and by masks
/// later. The target changes storage and paint semantics, not input capture.
public enum StrokeSurfaceKind: String, Codable, Equatable, Sendable {
  case colorRGBA
  case mask
}

public struct StrokeSurfaceRecipe: Codable, Equatable, Sendable {
  public var kind: StrokeSurfaceKind
  /// Coverage present before any stroke is replayed. Color paint is always
  /// transparent; mask surfaces may begin black (hide all) or white (reveal
  /// all) without allocating a canvas-sized texture.
  public var initialCoverage: Double
  public var strokes: [PaintStroke]

  public init(
    kind: StrokeSurfaceKind,
    initialCoverage: Double = 0,
    strokes: [PaintStroke] = []
  ) {
    self.kind = kind
    self.initialCoverage = kind == .mask
      ? min(max(initialCoverage.isFinite ? initialCoverage : 0, 0), 1)
      : 0
    self.strokes = strokes
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      kind: try values.decode(StrokeSurfaceKind.self, forKey: .kind),
      initialCoverage: try values.decodeIfPresent(Double.self, forKey: .initialCoverage) ?? 0,
      strokes: try values.decodeIfPresent([PaintStroke].self, forKey: .strokes) ?? []
    )
  }

  public func appending(_ stroke: PaintStroke) -> StrokeSurfaceRecipe {
    guard !stroke.samples.isEmpty else { return self }
    var copy = self
    copy.strokes.append(stroke)
    return copy
  }

  public func scaled(byX scaleX: Double, y scaleY: Double) -> StrokeSurfaceRecipe {
    StrokeSurfaceRecipe(
      kind: kind,
      initialCoverage: initialCoverage,
      strokes: strokes.map { $0.scaled(byX: scaleX, y: scaleY) }
    )
  }

  public func translated(byX deltaX: Double, y deltaY: Double) -> StrokeSurfaceRecipe {
    StrokeSurfaceRecipe(
      kind: kind,
      initialCoverage: initialCoverage,
      strokes: strokes.map { $0.translated(byX: deltaX, y: deltaY) }
    )
  }

  private enum CodingKeys: String, CodingKey {
    case kind, initialCoverage, strokes
  }
}

public struct PaintLayerRecipe: Codable, Equatable, Sendable {
  public var surface: StrokeSurfaceRecipe
  /// Non-brush paint is kept on the same layer recipe and render boundary.
  /// The tools currently create one fill/gradient layer per commit, which
  /// preserves ordering with brush layers without inventing a second layer
  /// model or flattening pixels.
  public var fills: [PaintFillRecipe]
  public var gradients: [PaintGradientRecipe]
  /// Healed patches, in the order they were committed. Unlike a stroke or a
  /// fill these carry baked pixels, so they are the one paint primitive whose
  /// appearance does not come from the recipe alone.
  public var heals: [PaintHealRecipe]

  public init(
    strokes: [PaintStroke] = [],
    fills: [PaintFillRecipe] = [],
    gradients: [PaintGradientRecipe] = [],
    heals: [PaintHealRecipe] = []
  ) {
    surface = StrokeSurfaceRecipe(kind: .colorRGBA, strokes: strokes)
    self.fills = Array(fills.prefix(256))
    self.gradients = Array(gradients.prefix(256))
    self.heals = Array(heals.prefix(HealLimits.maximumHealsPerLayer))
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let decoded = try values.decodeIfPresent(StrokeSurfaceRecipe.self, forKey: .surface)
      ?? StrokeSurfaceRecipe(kind: .colorRGBA)
    surface = StrokeSurfaceRecipe(kind: .colorRGBA, strokes: decoded.strokes)
    fills = Array(
      (try values.decodeIfPresent([PaintFillRecipe].self, forKey: .fills) ?? []).prefix(256)
    )
    gradients = Array(
      (try values.decodeIfPresent([PaintGradientRecipe].self, forKey: .gradients) ?? []).prefix(256)
    )
    // Absent in schema 27 and earlier, which is every project saved before the
    // healing brush existed.
    heals = Array(
      (try values.decodeIfPresent([PaintHealRecipe].self, forKey: .heals) ?? [])
        .prefix(HealLimits.maximumHealsPerLayer)
    )
  }

  public mutating func append(_ stroke: PaintStroke) {
    surface = surface.appending(stroke)
  }

  public mutating func append(_ heal: PaintHealRecipe) {
    guard heals.count < HealLimits.maximumHealsPerLayer else { return }
    heals.append(heal)
  }

  public func translated(byX deltaX: Double, y deltaY: Double) -> PaintLayerRecipe {
    PaintLayerRecipe(
      strokes: surface.strokes.map { $0.translated(byX: deltaX, y: deltaY) },
      fills: fills,
      gradients: gradients,
      // A heal's pixels are placed by canvas-pixel geometry, so they move with
      // the layer. Leaving them out would strand every patch where the canvas
      // used to be while the strokes around them moved.
      heals: heals.map { $0.translated(byX: deltaX, y: deltaY) }
    )
  }

  public var acceptsBrushStrokes: Bool {
    fills.isEmpty && gradients.isEmpty && heals.isEmpty
  }

  /// Whether another heal may join this layer.
  ///
  /// Retouching is a long run of small dabs, so heals accumulate on one layer
  /// instead of adding a layer each. They still refuse to share with strokes,
  /// fills or gradients, because those are composited in a fixed order and a
  /// heal is only meaningful over what was beneath it when it was solved.
  public var acceptsHeals: Bool {
    surface.strokes.isEmpty && fills.isEmpty && gradients.isEmpty
      && heals.count < HealLimits.maximumHealsPerLayer
  }

  private enum CodingKeys: String, CodingKey {
    case surface, fills, gradients, heals
  }
}

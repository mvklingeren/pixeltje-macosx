import Foundation

/// One control point of a tone curve, in the 0…1 curve domain.
///
/// The domain is the input value and the range is the output value, both in
/// the encoding the renderer states when it applies the curve. Points are
/// stored, never the sampled curve, so a project reproduces the same curve on
/// any build.
public struct ToneCurvePoint: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  /// The point with both coordinates inside 0…1.
  public var clamped: ToneCurvePoint {
    ToneCurvePoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
  }
}

/// Shape-preserving cubic interpolation through sorted control points.
///
/// This is the Fritsch–Carlson construction: average tangents limited so that
/// no segment overshoots its own endpoints. Between two points the result
/// therefore stays within their values, which is what makes a point tone curve
/// safe to drag — the curve never loops back on itself between two points the
/// way an unconstrained Catmull-Rom spline does.
public struct MonotoneCubicSpline: Equatable, Sendable {
  private let xs: [Double]
  private let ys: [Double]
  private let tangents: [Double]

  /// Builds a spline through `points`. Points are sorted by `x` and points that
  /// repeat an `x` are dropped, because a curve is a function of its input.
  public init(points: [ToneCurvePoint]) {
    var xs: [Double] = []
    var ys: [Double] = []
    for point in points.sorted(by: { $0.x < $1.x }) {
      if let last = xs.last, point.x - last < 1e-9 { continue }
      xs.append(point.x)
      ys.append(point.y)
    }
    if xs.count < 2 {
      let value = ys.first ?? 0
      xs = [0, 1]
      ys = [value, value]
    }
    self.xs = xs
    self.ys = ys
    self.tangents = Self.makeTangents(xs: xs, ys: ys)
  }

  private static func makeTangents(xs: [Double], ys: [Double]) -> [Double] {
    let count = xs.count
    var slopes = [Double](repeating: 0, count: count - 1)
    for index in 0..<(count - 1) {
      slopes[index] = (ys[index + 1] - ys[index]) / (xs[index + 1] - xs[index])
    }
    var tangents = [Double](repeating: 0, count: count)
    tangents[0] = slopes[0]
    tangents[count - 1] = slopes[count - 2]
    for index in 1..<(count - 1) {
      tangents[index] = (slopes[index - 1] + slopes[index]) / 2
    }
    // Fritsch–Carlson limiter: keep every tangent inside the circle of radius 3
    // around its segment slope, and flatten across a segment with zero slope.
    for index in 0..<(count - 1) {
      let slope = slopes[index]
      if abs(slope) < 1e-12 {
        tangents[index] = 0
        tangents[index + 1] = 0
        continue
      }
      let a = tangents[index] / slope
      let b = tangents[index + 1] / slope
      let magnitude = a * a + b * b
      if magnitude > 9 {
        let scale = 3 / magnitude.squareRoot()
        tangents[index] = scale * a * slope
        tangents[index + 1] = scale * b * slope
      }
    }
    return tangents
  }

  /// The curve value at `x`. Outside the control points the curve holds its
  /// endpoint value, so a curve never extrapolates past what the user drew.
  public func value(at x: Double) -> Double {
    guard let first = xs.first, let last = xs.last else { return x }
    if x <= first { return ys[0] }
    if x >= last { return ys[ys.count - 1] }
    var lower = 0
    var upper = xs.count - 1
    while upper - lower > 1 {
      let middle = (lower + upper) / 2
      if xs[middle] <= x { lower = middle } else { upper = middle }
    }
    let span = xs[upper] - xs[lower]
    let t = (x - xs[lower]) / span
    let t2 = t * t
    let t3 = t2 * t
    // Cubic Hermite basis.
    let h00 = 2 * t3 - 3 * t2 + 1
    let h10 = t3 - 2 * t2 + t
    let h01 = -2 * t3 + 3 * t2
    let h11 = t3 - t2
    return h00 * ys[lower] + h10 * span * tangents[lower] + h01 * ys[upper] + h11 * span
      * tangents[upper]
  }
}

/// A draggable point curve for one channel.
///
/// The identity curve is the two endpoints on the diagonal and is a pixel
/// no-op. Editing helpers keep the invariants the editor relies on: the first
/// point stays at x = 0, the last at x = 1, interior points stay strictly
/// between their neighbours, and every coordinate stays inside 0…1.
public struct PointToneCurve: Codable, Equatable, Sendable {
  /// The minimum horizontal gap between neighbouring points.
  public static let minimumSpacing = 0.01

  public var points: [ToneCurvePoint]

  public init(points: [ToneCurvePoint] = PointToneCurve.identity.points) {
    self.points = points
  }

  public static let identity = PointToneCurve(points: [
    ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1),
  ])

  public var isIdentity: Bool { self == .identity }

  public var spline: MonotoneCubicSpline { MonotoneCubicSpline(points: points) }

  public func value(at x: Double) -> Double { spline.value(at: x) }

  /// Adds a point, keeping the list sorted. A point too close in x to one that
  /// already exists is ignored, and the returned index is where the point
  /// landed so the editor can keep dragging it.
  public func adding(_ point: ToneCurvePoint) -> (curve: PointToneCurve, index: Int)? {
    let point = point.clamped
    guard point.x > Self.minimumSpacing, point.x < 1 - Self.minimumSpacing else { return nil }
    guard points.allSatisfy({ abs($0.x - point.x) >= Self.minimumSpacing }) else { return nil }
    var copy = self
    let index = copy.points.firstIndex { $0.x > point.x } ?? copy.points.count
    copy.points.insert(point, at: index)
    return (copy, index)
  }

  /// Moves one point. The endpoints keep their x; interior points are held
  /// between their neighbours so the curve stays a function of its input.
  public func moving(_ index: Int, to point: ToneCurvePoint) -> PointToneCurve {
    guard points.indices.contains(index) else { return self }
    var copy = self
    let target = point.clamped
    if index == 0 {
      copy.points[0] = ToneCurvePoint(x: 0, y: target.y)
    } else if index == points.count - 1 {
      copy.points[index] = ToneCurvePoint(x: 1, y: target.y)
    } else {
      let lower = points[index - 1].x + Self.minimumSpacing
      let upper = points[index + 1].x - Self.minimumSpacing
      let x = min(max(target.x, lower), max(lower, upper))
      copy.points[index] = ToneCurvePoint(x: x, y: target.y)
    }
    return copy
  }

  /// Removes an interior point. The two endpoints cannot be removed.
  public func removing(_ index: Int) -> PointToneCurve {
    guard points.indices.contains(index), index > 0, index < points.count - 1 else { return self }
    var copy = self
    copy.points.remove(at: index)
    return copy
  }

  /// The index of the point within `distance` of `x`, `y`, if any. Distances
  /// are measured in the curve's own 0…1 space, so the caller converts from
  /// view points first.
  public func index(near x: Double, y: Double, within distance: Double) -> Int? {
    var best: (index: Int, distance: Double)?
    for (index, point) in points.enumerated() {
      let dx = point.x - x
      let dy = point.y - y
      let candidate = (dx * dx + dy * dy).squareRoot()
      guard candidate <= distance else { continue }
      if best == nil || candidate < best!.distance { best = (index, candidate) }
    }
    return best?.index
  }
}

/// The parametric curve: four region amounts and the three split points that
/// say where the regions meet.
///
/// Each amount shifts the curve within its region by up to 0.25 at ±100 and
/// nothing at 0, so the neutral recipe is the identity. The shift is
/// interpolated between the region centres with the same shape-preserving
/// spline the point curve uses, which keeps neighbouring regions blending into
/// each other instead of meeting at a corner.
public struct ParametricToneCurve: Codable, Equatable, Sendable {
  /// The largest shift, in curve units, one region applies at ±100.
  public static let maximumShift = 0.25

  public var highlights: Double
  public var lights: Double
  public var darks: Double
  public var shadows: Double
  public var shadowSplit: Double
  public var midtoneSplit: Double
  public var highlightSplit: Double

  public init(
    highlights: Double = 0,
    lights: Double = 0,
    darks: Double = 0,
    shadows: Double = 0,
    shadowSplit: Double = 0.25,
    midtoneSplit: Double = 0.5,
    highlightSplit: Double = 0.75
  ) {
    self.highlights = highlights
    self.lights = lights
    self.darks = darks
    self.shadows = shadows
    self.shadowSplit = shadowSplit
    self.midtoneSplit = midtoneSplit
    self.highlightSplit = highlightSplit
  }

  public static let neutral = ParametricToneCurve()

  /// Neutral means the identity curve. The split points may sit anywhere; with
  /// every amount at zero they change nothing.
  public var isNeutral: Bool {
    highlights == 0 && lights == 0 && darks == 0 && shadows == 0
  }

  /// The four region amounts, in panel order.
  public enum Region: String, CaseIterable, Codable, Sendable {
    case highlights
    case lights
    case darks
    case shadows
  }

  /// The three split points, in panel order.
  public enum Split: String, CaseIterable, Codable, Sendable {
    case shadowSplit
    case midtoneSplit
    case highlightSplit
  }

  public subscript(region: Region) -> Double {
    get {
      switch region {
      case .highlights: highlights
      case .lights: lights
      case .darks: darks
      case .shadows: shadows
      }
    }
    set {
      switch region {
      case .highlights: highlights = newValue
      case .lights: lights = newValue
      case .darks: darks = newValue
      case .shadows: shadows = newValue
      }
    }
  }

  /// Reading a split gives its stored value; writing one keeps the three in
  /// ascending order with a minimum gap, so regions can never cross.
  public subscript(split: Split) -> Double {
    get {
      switch split {
      case .shadowSplit: shadowSplit
      case .midtoneSplit: midtoneSplit
      case .highlightSplit: highlightSplit
      }
    }
    set {
      let gap = 0.05
      switch split {
      case .shadowSplit:
        shadowSplit = min(max(newValue, gap), midtoneSplit - gap)
      case .midtoneSplit:
        midtoneSplit = min(max(newValue, shadowSplit + gap), highlightSplit - gap)
      case .highlightSplit:
        highlightSplit = min(max(newValue, midtoneSplit + gap), 1 - gap)
      }
    }
  }

  /// The centre of each region: the input value that slider moves the most.
  var regionCentres: [Double] {
    [
      shadowSplit / 2,
      (shadowSplit + midtoneSplit) / 2,
      (midtoneSplit + highlightSplit) / 2,
      (highlightSplit + 1) / 2,
    ]
  }

  /// The curve value at `x`.
  public func value(at x: Double) -> Double {
    guard !isNeutral else { return min(max(x, 0), 1) }
    let scale = Self.maximumShift / 100
    let centres = regionCentres
    let shifts = [shadows, darks, lights, highlights].map { $0 * scale }
    var anchors = [ToneCurvePoint(x: 0, y: 0)]
    for (centre, shift) in zip(centres, shifts) {
      anchors.append(ToneCurvePoint(x: centre, y: shift))
    }
    anchors.append(ToneCurvePoint(x: 1, y: 0))
    let shift = MonotoneCubicSpline(points: anchors).value(at: min(max(x, 0), 1))
    return min(max(x + shift, 0), 1)
  }
}

/// The tone curve of one layer: the parametric curve, the RGB point curve, and
/// a point curve per channel, all in one recipe.
///
/// Evaluation order is parametric, then the RGB point curve, then the per
/// channel curve, so the three stack the way the editor's tabs suggest. The
/// renderer turns the whole recipe into one lookup table and states the
/// encoding it applies it in.
///
/// The editor's current mode and channel tab are view state, not recipe state:
/// switching tabs is not an edit and must not create an undo step.
public struct ToneCurveRecipe: Codable, Equatable, Sendable {
  /// Which editor the panel shows.
  public enum Mode: String, CaseIterable, Codable, Sendable {
    case parametric
    case point

    public var label: String {
      switch self {
      case .parametric: "Parametric"
      case .point: "Point"
      }
    }
  }

  /// The tabs of the point editor. `rgb` is the composite curve applied to
  /// every channel; the others are per-channel.
  public enum Channel: String, CaseIterable, Codable, Sendable {
    case rgb
    case red
    case green
    case blue

    public var label: String {
      switch self {
      case .rgb: "RGB"
      case .red: "R"
      case .green: "G"
      case .blue: "B"
      }
    }
  }

  public var parametric: ParametricToneCurve
  public var rgb: PointToneCurve
  public var red: PointToneCurve
  public var green: PointToneCurve
  public var blue: PointToneCurve

  public init(
    parametric: ParametricToneCurve = .neutral,
    rgb: PointToneCurve = .identity,
    red: PointToneCurve = .identity,
    green: PointToneCurve = .identity,
    blue: PointToneCurve = .identity
  ) {
    self.parametric = parametric
    self.rgb = rgb
    self.red = red
    self.green = green
    self.blue = blue
  }

  public static let neutral = ToneCurveRecipe()

  /// A neutral curve renders nothing. The parametric split points are excluded
  /// on purpose: with every amount at zero they change no pixel, so a project
  /// that only moved a split still renders as a no-op.
  public var isNeutral: Bool {
    parametric.isNeutral && Channel.allCases.allSatisfy { self[$0].isIdentity }
  }

  public subscript(channel: Channel) -> PointToneCurve {
    get {
      switch channel {
      case .rgb: rgb
      case .red: red
      case .green: green
      case .blue: blue
      }
    }
    set {
      switch channel {
      case .rgb: rgb = newValue
      case .red: red = newValue
      case .green: green = newValue
      case .blue: blue = newValue
      }
    }
  }

  /// The composed value of one channel at `x`, for the editor's preview and
  /// for tests.
  public func value(at x: Double, channel: Channel) -> Double {
    let base = rgb.value(at: parametric.value(at: x))
    guard channel != .rgb else { return min(max(base, 0), 1) }
    return min(max(self[channel].value(at: base), 0), 1)
  }

  /// The recipe as a 1D RGB lookup table over the 0…1 input domain.
  ///
  /// The table is `sampleCount` RGB triplets, monotone per channel, and is
  /// exactly the identity table for a neutral recipe.
  public func lookupTable(sampleCount: Int = ToneLookupTable.defaultSampleCount) -> [Float] {
    guard !isNeutral else { return ToneLookupTable.identity(sampleCount: sampleCount) }
    let parametricCurve = parametric
    let rgbSpline = rgb.spline
    let redSpline = red.spline
    let greenSpline = green.spline
    let blueSpline = blue.spline
    return ToneLookupTable.table(sampleCount: sampleCount) { x in
      let base = rgbSpline.value(at: min(max(parametricCurve.value(at: x), 0), 1))
      let clampedBase = min(max(base, 0), 1)
      return (
        redSpline.value(at: clampedBase),
        greenSpline.value(at: clampedBase),
        blueSpline.value(at: clampedBase)
      )
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    parametric = try container.decodeIfPresent(ParametricToneCurve.self, forKey: .parametric) ?? .neutral
    rgb = try container.decodeIfPresent(PointToneCurve.self, forKey: .rgb) ?? .identity
    red = try container.decodeIfPresent(PointToneCurve.self, forKey: .red) ?? .identity
    green = try container.decodeIfPresent(PointToneCurve.self, forKey: .green) ?? .identity
    blue = try container.decodeIfPresent(PointToneCurve.self, forKey: .blue) ?? .identity
  }

  private enum CodingKeys: String, CodingKey {
    case parametric
    case rgb
    case red
    case green
    case blue
  }
}

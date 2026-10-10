import Foundation

/// One color stop in a vector gradient.
///
/// `midpoint` says where the blend to the *next* stop is half complete, as a
/// fraction of the span between them. It is a property of the span that starts
/// at this stop, which is why it lives here rather than between stops: adding
/// or removing a stop then cannot orphan a midpoint.
public struct VectorGradientStop: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var color: VectorColor
  /// Where the stop sits along the gradient, 0 to 1.
  public var position: Double
  /// Where the blend to the next stop is half done, 0 to 1 within that span.
  public var midpoint: Double

  public init(
    id: UUID = UUID(),
    color: VectorColor,
    position: Double,
    midpoint: Double = 0.5
  ) {
    self.id = id
    self.color = color
    self.position = position.isFinite ? min(max(position, 0), 1) : 0
    // A midpoint at either extreme would make the eased blend degenerate.
    self.midpoint = midpoint.isFinite ? min(max(midpoint, 0.05), 0.95) : 0.5
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case color
    case position
    case midpoint
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      color: try container.decode(VectorColor.self, forKey: .color),
      position: try container.decode(Double.self, forKey: .position),
      midpoint: try container.decode(Double.self, forKey: .midpoint))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(color, forKey: .color)
    try container.encode(position, forKey: .position)
    try container.encode(midpoint, forKey: .midpoint)
  }
}

public enum VectorGradientKind: String, Codable, CaseIterable, Sendable {
  case linear
  case radial

  public var label: String {
    switch self {
    case .linear: "Linear"
    case .radial: "Radial"
    }
  }

  public var symbolName: String {
    switch self {
    case .linear: "square.righthalf.filled"
    case .radial: "circle.righthalf.filled"
    }
  }
}

/// A gradient fill, in the same normalized image coordinates as the geometry
/// it fills.
///
/// The geometry is stored explicitly rather than reconstructed from the
/// object's bounds. Deriving it would make a gradient jump whenever an anchor
/// moved, and would leave nothing for an object transform to carry; storing it
/// means a moved, scaled, or rotated object keeps the gradient it was given.
public struct VectorGradient: Codable, Equatable, Hashable, Sendable {
  public var kind: VectorGradientKind
  /// Bottom to top: stops are kept sorted by position.
  public var stops: [VectorGradientStop]
  /// Linear: where the gradient begins. Radial: the center.
  public var start: VectorPoint
  /// Linear: where the gradient ends. Radial: a point on the primary radius,
  /// so one handle carries both the radius and the ellipse's rotation.
  public var end: VectorPoint
  /// Radial only: where the first stop sits, when it is not the center.
  public var focal: VectorPoint?
  /// Radial only: the secondary radius as a fraction of the primary one. One
  /// makes a circle; anything else makes an ellipse.
  public var aspectRatio: Double
  /// Fill opacity, separate from object and layer opacity.
  public var opacity: Double

  public init(
    kind: VectorGradientKind = .linear,
    stops: [VectorGradientStop] = VectorGradient.defaultStops,
    start: VectorPoint = VectorPoint(x: 0, y: 0),
    end: VectorPoint = VectorPoint(x: 1, y: 1),
    focal: VectorPoint? = nil,
    aspectRatio: Double = 1,
    opacity: Double = 1
  ) {
    self.kind = kind
    self.stops = VectorGradient.normalized(stops)
    self.start = start
    self.end = end
    self.focal = focal
    self.aspectRatio = aspectRatio.isFinite ? min(max(aspectRatio, 0.01), 100) : 1
    self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case stops
    case start
    case end
    case focal
    case aspectRatio
    case opacity
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      kind: try container.decode(VectorGradientKind.self, forKey: .kind),
      stops: try container.decode([VectorGradientStop].self, forKey: .stops),
      start: try container.decode(VectorPoint.self, forKey: .start),
      end: try container.decode(VectorPoint.self, forKey: .end),
      focal: try container.decodeIfPresent(VectorPoint.self, forKey: .focal),
      aspectRatio: try container.decode(Double.self, forKey: .aspectRatio),
      opacity: try container.decode(Double.self, forKey: .opacity))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(stops, forKey: .stops)
    try container.encode(start, forKey: .start)
    try container.encode(end, forKey: .end)
    try container.encodeIfPresent(focal, forKey: .focal)
    try container.encode(aspectRatio, forKey: .aspectRatio)
    try container.encode(opacity, forKey: .opacity)
  }

  public static let defaultStops = [
    VectorGradientStop(color: .black, position: 0),
    VectorGradientStop(color: .white, position: 1),
  ]

  /// Stops sorted by position, with at least two of them.
  ///
  /// A gradient with fewer than two stops has no blend to describe, and every
  /// evaluator downstream would have to invent one; normalizing here means none
  /// of them has to.
  static func normalized(_ stops: [VectorGradientStop]) -> [VectorGradientStop] {
    let sorted = stops.sorted { $0.position < $1.position }
    switch sorted.count {
    case 0: return defaultStops
    case 1:
      var last = sorted[0]
      last.id = UUID()
      last.position = 1
      var first = sorted[0]
      first.position = 0
      return [first, last]
    default: return sorted
    }
  }

  /// The authored Display P3 color at `t`, after interpolation in linear light
  /// and midpoint easing. This is suitable for a color well or a newly inserted
  /// stop; converting the interpolated result back to authored components is
  /// what keeps that stop from changing the visible ramp.
  public func color(at t: Double) -> VectorColor {
    let clamped = t.isFinite ? min(max(t, 0), 1) : 0
    guard let first = stops.first, let last = stops.last else { return .black }
    if clamped <= first.position { return first.color }
    if clamped >= last.position { return last.color }
    if let exact = stops.last(where: { $0.position == clamped }) { return exact.color }
    return linearColor(at: clamped).encodedDisplayP3
  }

  /// The color at `t` as Extended Linear Display P3 components. Renderers use
  /// this directly so both ordinary spans and sampled custom-midpoint spans
  /// interpolate in the document's linear working space.
  public func linearColor(at t: Double) -> VectorColor {
    let clamped = t.isFinite ? min(max(t, 0), 1) : 0
    guard let first = stops.first, let last = stops.last else {
      return VectorColor.black.linearDisplayP3
    }
    if clamped <= first.position { return first.color.linearDisplayP3 }
    if clamped >= last.position { return last.color.linearDisplayP3 }

    for index in 0..<(stops.count - 1) {
      let lower = stops[index]
      let upper = stops[index + 1]
      guard clamped >= lower.position, clamped <= upper.position else { continue }
      let span = upper.position - lower.position
      guard span > 0 else { return upper.color.linearDisplayP3 }
      let raw = (clamped - lower.position) / span
      return blend(
        lower.color.linearDisplayP3,
        upper.color.linearDisplayP3,
        t: VectorGradient.eased(raw, midpoint: lower.midpoint))
    }
    return last.color.linearDisplayP3
  }

  /// The classic midpoint easing: an exponent chosen so that the blend is
  /// exactly half done at the midpoint.
  static func eased(_ t: Double, midpoint: Double) -> Double {
    guard midpoint > 0, midpoint < 1, abs(midpoint - 0.5) > 0.000_1 else { return t }
    return pow(t, log(0.5) / log(midpoint))
  }

  private func blend(_ from: VectorColor, _ to: VectorColor, t: Double) -> VectorColor {
    VectorColor(
      red: from.red + (to.red - from.red) * t,
      green: from.green + (to.green - from.green) * t,
      blue: from.blue + (to.blue - from.blue) * t,
      alpha: from.alpha + (to.alpha - from.alpha) * t
    )
  }

  // MARK: - Stop editing

  public func addingStop(at position: Double) -> VectorGradient {
    var copy = self
    copy.stops = VectorGradient.normalized(
      stops + [VectorGradientStop(color: color(at: position), position: position)])
    return copy
  }

  /// Removes a stop, unless it is one of the last two: a gradient always keeps
  /// something to blend between.
  public func removingStop(id: UUID) -> VectorGradient {
    guard stops.count > 2 else { return self }
    var copy = self
    copy.stops = VectorGradient.normalized(stops.filter { $0.id != id })
    return copy
  }

  /// Duplicates a stop just after itself, which is how a hard edge is built.
  public func duplicatingStop(id: UUID) -> VectorGradient {
    guard let stop = stops.first(where: { $0.id == id }) else { return self }
    var copy = stop
    copy.id = UUID()
    copy.position = min(stop.position + 0.02, 1)
    var result = self
    result.stops = VectorGradient.normalized(stops + [copy])
    return result
  }

  public func updatingStop(id: UUID, _ edit: (inout VectorGradientStop) -> Void) -> VectorGradient {
    var copy = self
    var updated = stops
    guard let index = updated.firstIndex(where: { $0.id == id }) else { return self }
    edit(&updated[index])
    updated[index] = VectorGradientStop(
      id: updated[index].id,
      color: updated[index].color,
      position: updated[index].position,
      midpoint: updated[index].midpoint
    )
    copy.stops = VectorGradient.normalized(updated)
    return copy
  }

  /// Mirrors the ramp in place. Midpoints belong to the span that follows a
  /// stop, so reversing the order also reflects each of them.
  public func reversingStops() -> VectorGradient {
    var copy = self
    let reversed = stops.reversed().map { stop in
      VectorGradientStop(
        id: stop.id, color: stop.color, position: 1 - stop.position, midpoint: stop.midpoint)
    }
    var result = VectorGradient.normalized(reversed)
    for index in result.indices.dropLast() {
      result[index].midpoint = 1 - result[index + 1].midpoint
    }
    // The last stop's span does not exist; leave it neutral.
    if var last = result.last {
      last.midpoint = 0.5
      result[result.count - 1] = last
    }
    copy.stops = result
    return copy
  }

  /// Spreads the stops evenly from the first to the last, keeping their order
  /// and colors.
  public func distributingStopsEvenly() -> VectorGradient {
    guard stops.count > 2, let first = stops.first, let last = stops.last else { return self }
    let span = last.position - first.position
    var copy = self
    copy.stops = stops.enumerated().map { index, stop in
      var moved = stop
      moved.position = first.position + span * Double(index) / Double(stops.count - 1)
      return moved
    }
    return copy
  }

  /// Moves the gradient's stored geometry with the object it fills.
  ///
  /// A radial gradient stores one radius and the ratio of its perpendicular
  /// radius. An affine transform can change both lengths independently (or
  /// shear their basis), so its resulting ellipse is recovered from the two
  /// transformed axes instead of carrying the old ratio forward.
  public func transformed(
    by transform: VectorAffineTransform, aspect: Double = 1
  ) -> VectorGradient {
    guard !transform.isIdentity else { return self }
    var copy = self
    copy.start = transform.apply(to: start)
    copy.end = transform.apply(to: end)
    copy.focal = focal.map(transform.apply(to:))
    guard kind == .radial else { return copy }

    let safeAspect = aspect > 0 && aspect.isFinite ? aspect : 1
    let primary = (
      x: (end.x - start.x) * safeAspect,
      y: end.y - start.y)
    let primaryLength = hypot(primary.x, primary.y)
    guard primaryLength > 0, primaryLength.isFinite else { return copy }
    let secondary = (
      x: -primary.y * aspectRatio,
      y: primary.x * aspectRatio)

    // Conjugate the normalized-coordinate transform into pixel proportions.
    let m00 = transform.a
    let m01 = transform.c * safeAspect
    let m10 = transform.b / safeAspect
    let m11 = transform.d
    let movedPrimary = (
      x: m00 * primary.x + m01 * primary.y,
      y: m10 * primary.x + m11 * primary.y)
    let movedSecondary = (
      x: m00 * secondary.x + m01 * secondary.y,
      y: m10 * secondary.x + m11 * secondary.y)

    // The columns above map the unit circle to the transformed ellipse. Its
    // orthogonal radii are the eigenvectors of B·Bᵀ (the left side of an SVD).
    let xx = movedPrimary.x * movedPrimary.x + movedSecondary.x * movedSecondary.x
    let xy = movedPrimary.x * movedPrimary.y + movedSecondary.x * movedSecondary.y
    let yy = movedPrimary.y * movedPrimary.y + movedSecondary.y * movedSecondary.y
    let root = hypot(xx - yy, 2 * xy)
    let high = max((xx + yy + root) / 2, 0)
    let low = max((xx + yy - root) / 2, 0)
    guard high.isFinite, low.isFinite, high > 0 else { return copy }

    var highAxis: (x: Double, y: Double)
    if root <= high * 0.000_000_001 {
      let length = hypot(movedPrimary.x, movedPrimary.y)
      highAxis = length > 0
        ? (movedPrimary.x / length, movedPrimary.y / length)
        : (1, 0)
    } else if abs(xy) > abs(high - xx) {
      let length = hypot(xy, high - xx)
      highAxis = (xy / length, (high - xx) / length)
    } else {
      let length = hypot(high - yy, xy)
      highAxis = ((high - yy) / length, xy / length)
    }
    let lowAxis = (x: -highAxis.y, y: highAxis.x)

    // Either principal radius can be the stored primary one. Choose the one
    // closest to the transformed end handle so ordinary moves, rotations, and
    // axis-aligned scales do not make the handle jump by ninety degrees.
    let highAlignment = abs(
      highAxis.x * movedPrimary.x + highAxis.y * movedPrimary.y)
    let lowAlignment = abs(
      lowAxis.x * movedPrimary.x + lowAxis.y * movedPrimary.y)
    var axis = highAlignment >= lowAlignment ? highAxis : lowAxis
    let selectedLength = sqrt(highAlignment >= lowAlignment ? high : low)
    let otherLength = sqrt(highAlignment >= lowAlignment ? low : high)
    if axis.x * movedPrimary.x + axis.y * movedPrimary.y < 0 {
      axis = (-axis.x, -axis.y)
    }
    guard selectedLength > 0, selectedLength.isFinite, otherLength.isFinite else { return copy }

    copy.end = VectorPoint(
      x: copy.start.x + axis.x * selectedLength / safeAspect,
      y: copy.start.y + axis.y * selectedLength)
    copy.aspectRatio = min(max(otherLength / selectedLength, 0.01), 100)
    return copy
  }
}

/// What a fill paints.
///
/// A tagged case rather than a structure holding one color: the fill system
/// grows by adding cases, and every evaluator has to handle each of them
/// explicitly rather than silently painting a default.
public enum VectorFillContent: Equatable, Hashable, Sendable {
  case solid(VectorColor)
  case gradient(VectorGradient)
}

extension VectorFillContent: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case color
    case gradient
  }

  private enum Kind: String, Codable {
    case solid
    case gradient
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .solid: self = .solid(try container.decode(VectorColor.self, forKey: .color))
    case .gradient: self = .gradient(try container.decode(VectorGradient.self, forKey: .gradient))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .solid(let color):
      try container.encode(Kind.solid, forKey: .kind)
      try container.encode(color, forKey: .color)
    case .gradient(let gradient):
      try container.encode(Kind.gradient, forKey: .kind)
      try container.encode(gradient, forKey: .gradient)
    }
  }
}

extension VectorFillStyle {
  /// The solid color, for the many callers that only deal in one.
  ///
  /// Reading a gradient reports its first stop, so a color well shows something
  /// recognizable; writing replaces the whole fill with that solid color, which
  /// is what choosing a color in a color well means.
  public var color: VectorColor {
    get {
      switch content {
      case .solid(let color): color
      case .gradient(let gradient): gradient.stops.first?.color ?? .black
      }
    }
    set { content = .solid(newValue) }
  }

  public var gradient: VectorGradient? {
    get {
      guard case .gradient(let gradient) = content else { return nil }
      return gradient
    }
    set {
      guard let newValue else { return }
      content = .gradient(newValue)
    }
  }

  public var isGradient: Bool { gradient != nil }

  /// How opaque the fill is on its own, before object and layer opacity.
  ///
  /// A gradient carries its own opacity so the two travel together through
  /// copy, paste, and presets; a solid fill keeps it beside the color.
  public var opacity: Double {
    get {
      switch content {
      case .solid: solidOpacity
      case .gradient(let gradient): gradient.opacity
      }
    }
    set {
      let clamped = min(max(newValue, 0), 1)
      switch content {
      case .solid: solidOpacity = clamped
      case .gradient(var gradient):
        gradient.opacity = clamped
        content = .gradient(gradient)
      }
    }
  }

  /// Moves stored gradient coordinates with the object.
  public func transformed(
    by transform: VectorAffineTransform, aspect: Double = 1
  ) -> VectorFillStyle {
    guard case .gradient(let gradient) = content else { return self }
    var copy = self
    copy.content = .gradient(gradient.transformed(by: transform, aspect: aspect))
    return copy
  }
}

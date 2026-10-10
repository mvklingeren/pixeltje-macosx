import Foundation

// MARK: - The shared mask model
//
// There is one mask type in this application. A local adjustment mask, a layer
// mask, a saved selection and an inpaint mask are all `MaskRecipe`; a mask made
// by any tool can be handed to any other without conversion, because nothing in
// this file knows which tool produced it.
//
// A mask is a recipe, never pixels. It is an ordered list of `MaskComponent`s,
// each of which pairs a `MaskGenerator` — the thing that produces coverage —
// with a `MaskCombineOperation` saying how that coverage joins everything
// already accumulated beneath it. Components are evaluated bottom-up in array
// order, which is the order the mask list shows them in.
//
// Coverage is a single scalar in `0...1` at every point on the canvas: 0 means
// the mask does not select that pixel and 1 means it fully does. The renderer
// resolves a recipe to a single-channel Core Image mask at whatever resolution
// it is asked for, so the same recipe drives a proxy render and a final render
// with no separate state.
//
// Geometry is normalized to the canvas extent, exactly like vector artwork:
// `VectorPoint(x: 0, y: 0)` is the bottom-left corner of the canvas and
// `(1, 1)` the top-right. That is what lets one mask survive a proxy render, a
// canvas resize, and a round trip through the project file.

/// Hard limits shared by decoding and canvas capture.
///
/// They make a malformed project file and a runaway pointer stream finite
/// without putting any framework or GPU policy into the saved recipe, exactly
/// as `BrushLimits` does for painting.
public enum MaskLimits {
  /// A freehand gesture appends a point every few canvas pixels; this is the
  /// ceiling a very long loop is truncated to.
  public static let maximumPolygonPoints = 16_384
}

/// Identifies one mask within the layer that owns it.
public struct MaskID: Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String = UUID().uuidString) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self) {
      rawValue = value
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rawValue = try container.decode(String.self, forKey: .rawValue)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }
}

/// Identifies one component within the mask that owns it.
public struct MaskComponentID: Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String = UUID().uuidString) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self) {
      rawValue = value
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rawValue = try container.decode(String.self, forKey: .rawValue)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }
}

/// How one component's coverage joins the coverage accumulated beneath it.
///
/// `add` takes the larger of the two, `subtract` removes the component's
/// coverage from what is there, and `intersect` keeps only what both cover.
/// The first component in a mask has nothing beneath it, so its operation is
/// ignored and its coverage becomes the starting value.
public enum MaskCombineOperation: String, Codable, CaseIterable, Sendable {
  case add
  case subtract
  case intersect

  public var label: String {
    switch self {
    case .add: "Add"
    case .subtract: "Subtract"
    case .intersect: "Intersect"
    }
  }

  public var symbolName: String {
    switch self {
    case .add: "plus.circle"
    case .subtract: "minus.circle"
    case .intersect: "circle.circle"
    }
  }
}

/// An axis-aligned rectangle in normalized canvas coordinates.
///
/// `origin` is the bottom-left corner and the extents run toward the top right,
/// so a rectangle covering the whole canvas is `origin (0, 0)`, width 1,
/// height 1. A drag can run in any direction, so a negative extent is
/// normalized here rather than at every call site: the stored rectangle always
/// has a bottom-left origin and non-negative extents.
///
/// The same rectangle describes both a rectangular and an elliptical selection;
/// the ellipse is the one inscribed in it. That keeps one gesture, one payload
/// and one set of edit handles behind both shapes.
public struct ShapeMask: Codable, Equatable, Sendable {
  public var origin: VectorPoint
  public var width: Double
  public var height: Double
  /// Corner rounding as a fraction of the shorter canvas edge, the same
  /// convention `RadialGradientMask.radius` uses, so one number means the same
  /// distance horizontally and vertically on a non-square canvas.
  ///
  /// A rectangle uses it; the inscribed ellipse ignores it. Half the shorter
  /// edge is already a stadium, so nothing larger is worth storing.
  public var cornerRadius: Double

  public init(
    origin: VectorPoint,
    width: Double,
    height: Double,
    cornerRadius: Double = 0
  ) {
    let x = Self.coordinate(origin.x)
    let y = Self.coordinate(origin.y)
    let w = Self.extent(width)
    let h = Self.extent(height)
    self.origin = VectorPoint(x: min(x, x + w), y: min(y, y + h))
    self.width = abs(w)
    self.height = abs(h)
    self.cornerRadius = Self.radius(cornerRadius)
  }

  /// The rectangle a drag from one corner to another describes.
  ///
  /// The origin is taken from the corners rather than from `start` plus a
  /// signed extent, so dragging up-right and down-left across the same two
  /// corners produces exactly the same rectangle instead of one that differs in
  /// the last bit.
  public init(from start: VectorPoint, to end: VectorPoint, cornerRadius: Double = 0) {
    self.init(
      origin: VectorPoint(x: min(start.x, end.x), y: min(start.y, end.y)),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y),
      cornerRadius: cornerRadius
    )
  }

  /// The whole canvas, which is what Select All produces.
  public static let full = ShapeMask(origin: VectorPoint(x: 0, y: 0), width: 1, height: 1)

  public var maxX: Double { origin.x + width }
  public var maxY: Double { origin.y + height }

  public var center: VectorPoint {
    VectorPoint(x: origin.x + width / 2, y: origin.y + height / 2)
  }

  /// Whether the rectangle has any area at all. A zero-extent drag selects
  /// nothing, which is a deselect rather than a mask nobody can see.
  public var isEmpty: Bool { width <= 0 || height <= 0 }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      origin: try container.decodeIfPresent(VectorPoint.self, forKey: .origin) ?? .zero,
      width: try container.decodeIfPresent(Double.self, forKey: .width) ?? 0,
      height: try container.decodeIfPresent(Double.self, forKey: .height) ?? 0,
      cornerRadius: try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
    )
  }

  /// Geometry is normalized but a component may sit partly outside the canvas,
  /// so coordinates are bounded generously rather than clamped to `0...1`.
  private static func coordinate(_ value: Double) -> Double {
    value.isFinite ? min(max(value, -16), 16) : 0
  }

  private static func extent(_ value: Double) -> Double {
    value.isFinite ? min(max(value, -32), 32) : 0
  }

  private static func radius(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 0.5) : 0
  }

  private enum CodingKeys: String, CodingKey {
    case origin, width, height, cornerRadius
  }
}

/// A closed polygon in normalized canvas coordinates, as freehand input
/// produces it.
///
/// The recipe stores where the pointer went, never the pixels that came out,
/// so a lasso drawn on a proxy render resolves crisply for a final render. The
/// polygon is implicitly closed: the last point joins the first, and the
/// closing edge is never stored.
public struct PolygonMask: Codable, Equatable, Sendable {
  public var points: [VectorPoint]

  public init(points: [VectorPoint]) {
    self.points = Array(
      points
        .filter { $0.x.isFinite && $0.y.isFinite }
        .prefix(MaskLimits.maximumPolygonPoints)
    )
  }

  /// A polygon needs three corners before it encloses anything.
  public var isEmpty: Bool { points.count < 3 }

  /// Adds a point, which is what one freehand drag event contributes.
  public func appending(_ point: VectorPoint) -> PolygonMask {
    guard points.count < MaskLimits.maximumPolygonPoints else { return self }
    return PolygonMask(points: points + [point])
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(points: try container.decodeIfPresent([VectorPoint].self, forKey: .points) ?? [])
  }

  private enum CodingKeys: String, CodingKey {
    case points
  }
}

/// A straight ramp from full coverage at `start` to no coverage at `end`.
///
/// Both points are normalized canvas coordinates, so the gradient's angle and
/// length are recorded rather than a baked ramp. The band perpendicular to the
/// line is constant, which is what a graduated filter is.
public struct LinearGradientMask: Codable, Equatable, Sendable {
  public var start: VectorPoint
  public var end: VectorPoint

  public init(start: VectorPoint, end: VectorPoint) {
    self.start = start
    self.end = end
  }

  /// The default placement on a canvas with no interaction yet: a ramp down
  /// the upper half of the frame.
  public static let centered = LinearGradientMask(
    start: VectorPoint(x: 0.5, y: 1),
    end: VectorPoint(x: 0.5, y: 0.5)
  )
}

/// A round ramp centered on `center`.
///
/// `radius` is a fraction of the canvas's shorter edge. `softness` is where the
/// ramp begins, as a fraction of the radius: 0 is a hard-edged circle and 1 is
/// a ramp that starts at the very center. `coversInside` says which side of the
/// ramp is selected, so an ellipse can select its subject or everything around
/// it without needing an extra inverted component.
public struct RadialGradientMask: Codable, Equatable, Sendable {
  public var center: VectorPoint
  public var radius: Double
  public var softness: Double
  public var coversInside: Bool

  public init(
    center: VectorPoint,
    radius: Double,
    softness: Double = 0.5,
    coversInside: Bool = true
  ) {
    self.center = center
    self.radius = max(radius, 0)
    self.softness = min(max(softness, 0), 1)
    self.coversInside = coversInside
  }

  public static let centered = RadialGradientMask(
    center: VectorPoint(x: 0.5, y: 0.5),
    radius: 0.3
  )
}

/// Selects pixels whose luminance falls inside a band.
///
/// Bounds are in the linear working space, where 1 is diffuse white; an EDR
/// highlight can exceed it, so `upperBound` may be raised above 1 to reach one.
/// The falloffs are the widths of the linear ramps at each end of the band, so
/// a range with both falloffs at zero is a hard threshold.
public struct LuminanceRangeMask: Codable, Equatable, Sendable {
  public var lowerBound: Double
  public var upperBound: Double
  public var lowerFalloff: Double
  public var upperFalloff: Double

  public init(
    lowerBound: Double,
    upperBound: Double,
    lowerFalloff: Double = 0.1,
    upperFalloff: Double = 0.1
  ) {
    self.lowerBound = lowerBound
    self.upperBound = max(upperBound, lowerBound)
    self.lowerFalloff = max(lowerFalloff, 0)
    self.upperFalloff = max(upperFalloff, 0)
  }

  public static let highlights = LuminanceRangeMask(lowerBound: 0.6, upperBound: 4)
  public static let shadows = LuminanceRangeMask(lowerBound: -1, upperBound: 0.25)

  /// A band centered on a sampled luminance, which is what a canvas click
  /// produces.
  public static func sampling(_ luminance: Double, width: Double = 0.15) -> LuminanceRangeMask {
    LuminanceRangeMask(
      lowerBound: luminance - width,
      upperBound: luminance + width,
      lowerFalloff: width,
      upperFalloff: width
    )
  }
}

/// Selects pixels close to a sampled color.
///
/// The sample is written in Display P3 components, the way vector and text
/// colors are, and enters the linear working space through a color-managed
/// conversion when the mask is evaluated. `tolerance` is the distance at which
/// coverage reaches zero and `smoothness` is the fraction of that distance
/// spent ramping down, so smoothness 0 is a hard key.
public struct ColorRangeMask: Codable, Equatable, Sendable {
  public var sample: VectorColor
  public var tolerance: Double
  public var smoothness: Double

  public init(sample: VectorColor, tolerance: Double = 0.2, smoothness: Double = 0.5) {
    self.sample = sample
    self.tolerance = max(tolerance, 0)
    self.smoothness = min(max(smoothness, 0), 1)
  }

  public static let neutral = ColorRangeMask(sample: VectorColor(red: 0.5, green: 0.5, blue: 0.5))
}

/// One sample along a brush stroke.
///
/// Position is a normalized canvas coordinate. Pressure scales the radius and
/// the flow at that sample, so a tablet stroke keeps its dynamics in the recipe
/// instead of only in the pixels it produced.
public struct BrushStrokePoint: Codable, Equatable, Sendable {
  public var position: VectorPoint
  public var pressure: Double

  public init(position: VectorPoint, pressure: Double = 1) {
    self.position = position
    self.pressure = min(max(pressure, 0), 1)
  }
}

/// One continuous press of the brush, stored as geometry.
///
/// A stroke is never flattened into pixels in the project: the recipe records
/// where the pointer went and how the brush was set, and the renderer draws it
/// again at whatever resolution it is asked for. That is what keeps a painted
/// mask reproducible, resolution independent and editable after the fact.
public struct BrushStroke: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var points: [BrushStrokePoint]
  /// Brush radius in canvas pixels.
  public var radius: Double
  /// 0 is a fully feathered dab, 1 a hard-edged one.
  public var hardness: Double
  /// How much coverage one dab lays down, in `0...1`.
  public var flow: Double
  /// An erasing stroke removes coverage instead of adding it, within this one
  /// component. It is not the same thing as a `subtract` component: erasing
  /// works inside the stroke list so a mistake can be wiped without splitting
  /// the mask.
  public var isErasing: Bool

  public init(
    id: UUID = UUID(),
    points: [BrushStrokePoint],
    radius: Double,
    hardness: Double = 0.5,
    flow: Double = 1,
    isErasing: Bool = false
  ) {
    self.id = id
    self.points = points
    self.radius = max(radius, 0)
    self.hardness = min(max(hardness, 0), 1)
    self.flow = min(max(flow, 0), 1)
    self.isErasing = isErasing
  }
}

/// Coverage painted by the brush, as an ordered list of strokes.
public struct BrushStrokeMask: Codable, Equatable, Sendable {
  public var strokes: [BrushStroke]

  public init(strokes: [BrushStroke] = []) {
    self.strokes = strokes
  }

  public var isEmpty: Bool {
    strokes.allSatisfy { $0.points.isEmpty }
  }

  /// Adds one stroke, which is the whole of what a brush gesture commits.
  public func appending(_ stroke: BrushStroke) -> BrushStrokeMask {
    BrushStrokeMask(strokes: strokes + [stroke])
  }

  /// Replaces a stroke in place, which is what a live drag does while the
  /// pointer is still down.
  public func replacing(_ stroke: BrushStroke) -> BrushStrokeMask {
    guard let index = strokes.firstIndex(where: { $0.id == stroke.id }) else {
      return appending(stroke)
    }
    var copy = strokes
    copy[index] = stroke
    return BrushStrokeMask(strokes: copy)
  }
}

/// What kind of coverage a component produces, without its parameters.
///
/// This is what the tool-setting picker lists and what `availability` answers
/// about, so a case can exist in the model before the machinery behind it does.
public enum MaskGeneratorKind: String, Codable, CaseIterable, Sendable {
  case rectangle
  case ellipse
  case polygon
  case linearGradient
  case radialGradient
  case brush
  /// A deterministic `PaintStroke` surface rendered by the shared Metal brush
  /// engine. This is an internal recipe kind, not a Masks-tool generator.
  case strokeSurface
  case luminanceRange
  case colorRange
  /// Captured contiguous coverage. Produced by the Fill tool, not offered as
  /// an ordinary mask-generator choice in the panel.
  case raster
  /// A captured mask placed within a source region, such as text-guided selection.
  case placedRaster
  case subject
  case person
  case background
  case sky

  public var label: String {
    switch self {
    case .rectangle: "Rectangle"
    case .ellipse: "Ellipse"
    case .polygon: "Freehand"
    case .linearGradient: "Linear Gradient"
    case .radialGradient: "Radial Gradient"
    case .brush: "Brush"
    case .strokeSurface: "Painted Mask"
    case .luminanceRange: "Luminance Range"
    case .colorRange: "Color Range"
    case .raster: "Contiguous Region"
    case .placedRaster: "AI Selection"
    case .subject: "Subject"
    case .person: "Person"
    case .background: "Background"
    case .sky: "Sky"
    }
  }

  public var symbolName: String {
    switch self {
    case .rectangle: "rectangle.dashed"
    case .ellipse: "circle.dashed"
    case .polygon: "lasso"
    case .linearGradient: "square.righthalf.filled"
    case .radialGradient: "circle.righthalf.filled"
    case .brush: "paintbrush"
    case .strokeSurface: "paintbrush.pointed"
    case .luminanceRange: "sun.max"
    case .colorRange: "eyedropper"
    case .raster: "paintbucket"
    case .placedRaster: "selection.pin.in.out"
    case .subject: "person.and.background.dotted"
    case .person: "person.crop.square"
    case .background: "rectangle.on.rectangle"
    case .sky: "cloud.sun"
    }
  }

  /// Whether placing this kind of component needs a drag or a click on the
  /// canvas, as opposed to being produced outright from the panel.
  public var needsCanvasPlacement: Bool {
    switch self {
    case .rectangle, .ellipse, .polygon, .linearGradient, .radialGradient, .brush,
      .luminanceRange, .colorRange:
      true
    case .strokeSurface, .subject, .person, .background, .sky, .raster, .placedRaster: false
    }
  }

  /// Whether this kind reads the image it is masking, rather than only the
  /// geometry the user drew.
  public var readsSourceImage: Bool {
    switch self {
    case .luminanceRange, .colorRange, .subject, .person, .background, .sky: true
    case .rectangle, .ellipse, .polygon, .linearGradient, .radialGradient, .brush,
      .strokeSurface, .raster, .placedRaster: false
    }
  }

  /// Whether the application can evaluate this kind today, and why not when it
  /// cannot.
  ///
  /// Sky segmentation is specified to come from a Core AI package loaded by the
  /// model manager. Neither exists yet and both are deliberately out of scope
  /// here, so the case is defined, offered, and reported unavailable with its
  /// real reason. It is never quietly substituted with something else: a
  /// missing package is a prompt, not a silent fallback.
  public var availability: MaskGeneratorAvailability {
    switch self {
    case .sky:
      .unavailable(
        "Sky segmentation needs a Core AI segmentation package. The model manager that "
          + "imports and loads packages is not in this build yet, so no sky mask can be "
          + "produced. Nothing else is substituted for it."
      )
    case .raster, .placedRaster:
      .available
    default:
      .available
    }
  }

  /// A component of this kind with sensible starting parameters.
  ///
  /// `canvasPoint` is where the user clicked, when there was a click.
  public func defaultGenerator(at canvasPoint: VectorPoint? = nil) -> MaskGenerator {
    let point = canvasPoint ?? VectorPoint(x: 0.5, y: 0.5)
    switch self {
    case .rectangle:
      return .rectangle(ShapeMask(origin: point, width: 0, height: 0))
    case .ellipse:
      return .ellipse(ShapeMask(origin: point, width: 0, height: 0))
    case .polygon:
      return .polygon(PolygonMask(points: canvasPoint.map { [$0] } ?? []))
    case .linearGradient:
      return .linearGradient(
        LinearGradientMask(start: point, end: VectorPoint(x: point.x, y: max(point.y - 0.35, 0))))
    case .radialGradient:
      return .radialGradient(RadialGradientMask(center: point, radius: 0.3))
    case .brush:
      return .brush(BrushStrokeMask())
    case .strokeSurface:
      return .strokeSurface(StrokeSurfaceRecipe(kind: .mask))
    case .luminanceRange:
      return .luminanceRange(.highlights)
    case .colorRange:
      return .colorRange(.neutral)
    case .subject:
      return .subject
    case .person:
      return .person
    case .background:
      return .background
    case .sky:
      return .sky
    case .raster:
      return .raster(RasterMask(width: 0, height: 0, runs: []))
    case .placedRaster:
      return .placedRaster(
        PlacedRasterMask(
          raster: RasterMask(width: 0, height: 0, runs: []),
          frame: .full))
    }
  }
}

/// Whether a generator can run, with the reason when it cannot.
public struct MaskGeneratorAvailability: Equatable, Sendable {
  public var isAvailable: Bool
  public var unavailableReason: String?

  public static let available = MaskGeneratorAvailability(
    isAvailable: true, unavailableReason: nil)

  public static func unavailable(_ reason: String) -> MaskGeneratorAvailability {
    MaskGeneratorAvailability(isAvailable: false, unavailableReason: reason)
  }
}

/// The coverage one component produces, with its parameters.
///
/// `subject`, `person` and `background` are answered by Vision on the image
/// being masked; `background` is defined as the inverse of `subject` so the two
/// always agree about the same edge. `sky` is defined here and reported
/// unavailable until a Core AI segmentation package can be loaded.
public enum MaskGenerator: Codable, Equatable, Sendable {
  case rectangle(ShapeMask)
  case ellipse(ShapeMask)
  case polygon(PolygonMask)
  case linearGradient(LinearGradientMask)
  case radialGradient(RadialGradientMask)
  case brush(BrushStrokeMask)
  case strokeSurface(StrokeSurfaceRecipe)
  case luminanceRange(LuminanceRangeMask)
  case colorRange(ColorRangeMask)
  case raster(RasterMask)
  case placedRaster(PlacedRasterMask)
  case subject
  case person
  case background
  case sky

  public var kind: MaskGeneratorKind {
    switch self {
    case .rectangle: .rectangle
    case .ellipse: .ellipse
    case .polygon: .polygon
    case .linearGradient: .linearGradient
    case .radialGradient: .radialGradient
    case .brush: .brush
    case .strokeSurface: .strokeSurface
    case .luminanceRange: .luminanceRange
    case .colorRange: .colorRange
    case .raster: .raster
    case .placedRaster: .placedRaster
    case .subject: .subject
    case .person: .person
    case .background: .background
    case .sky: .sky
    }
  }

  /// Whether this generator encloses no area at all.
  ///
  /// A zero-extent marquee drag or a two-point lasso is a gesture the user
  /// abandoned, not a component worth keeping, so the tools drop it rather than
  /// leaving an invisible entry in the mask.
  public var isEmptyGeometry: Bool {
    switch self {
    case .rectangle(let shape), .ellipse(let shape): shape.isEmpty
    case .polygon(let polygon): polygon.isEmpty
    case .brush(let strokes): strokes.isEmpty
    case .strokeSurface(let surface):
      surface.initialCoverage <= 0 && surface.strokes.isEmpty
    case .raster(let raster): raster.isEmpty
    case .placedRaster(let placed): placed.isEmpty
    default: false
    }
  }

  public var label: String { kind.label }

  public var availability: MaskGeneratorAvailability { kind.availability }

  /// The brush strokes this generator carries, for a brush generator only.
  public var brushStrokes: BrushStrokeMask? {
    if case .brush(let strokes) = self { strokes } else { nil }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(MaskGeneratorKind.self, forKey: .kind) {
    case .rectangle:
      self = .rectangle(try container.decode(ShapeMask.self, forKey: .rectangle))
    case .ellipse:
      self = .ellipse(try container.decode(ShapeMask.self, forKey: .ellipse))
    case .polygon:
      self = .polygon(try container.decodeIfPresent(PolygonMask.self, forKey: .polygon) ?? .init(points: []))
    case .linearGradient:
      self = .linearGradient(try container.decode(LinearGradientMask.self, forKey: .linearGradient))
    case .radialGradient:
      self = .radialGradient(try container.decode(RadialGradientMask.self, forKey: .radialGradient))
    case .brush:
      self = .brush(try container.decodeIfPresent(BrushStrokeMask.self, forKey: .brush) ?? .init())
    case .strokeSurface:
      self = .strokeSurface(
        try container.decodeIfPresent(StrokeSurfaceRecipe.self, forKey: .strokeSurface)
          ?? StrokeSurfaceRecipe(kind: .mask))
    case .luminanceRange:
      self = .luminanceRange(try container.decode(LuminanceRangeMask.self, forKey: .luminanceRange))
    case .colorRange:
      self = .colorRange(try container.decode(ColorRangeMask.self, forKey: .colorRange))
    case .raster:
      self = .raster(try container.decode(RasterMask.self, forKey: .raster))
    case .placedRaster:
      self = .placedRaster(try container.decode(PlacedRasterMask.self, forKey: .placedRaster))
    case .subject:
      self = .subject
    case .person:
      self = .person
    case .background:
      self = .background
    case .sky:
      self = .sky
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .rectangle(let value): try container.encode(value, forKey: .rectangle)
    case .ellipse(let value): try container.encode(value, forKey: .ellipse)
    case .polygon(let value): try container.encode(value, forKey: .polygon)
    case .linearGradient(let value): try container.encode(value, forKey: .linearGradient)
    case .radialGradient(let value): try container.encode(value, forKey: .radialGradient)
    case .brush(let value): try container.encode(value, forKey: .brush)
    case .strokeSurface(let value): try container.encode(value, forKey: .strokeSurface)
    case .luminanceRange(let value): try container.encode(value, forKey: .luminanceRange)
    case .colorRange(let value): try container.encode(value, forKey: .colorRange)
    case .raster(let value): try container.encode(value, forKey: .raster)
    case .placedRaster(let value): try container.encode(value, forKey: .placedRaster)
    case .subject, .person, .background, .sky: break
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case rectangle
    case ellipse
    case polygon
    case linearGradient
    case radialGradient
    case brush
    case strokeSurface
    case luminanceRange
    case colorRange
    case raster
    case placedRaster
  }
}

/// One generator plus how it joins the components beneath it.
public struct MaskComponent: Codable, Equatable, Identifiable, Sendable {
  public var id: MaskComponentID
  public var name: String
  public var isEnabled: Bool
  public var generator: MaskGenerator
  public var combine: MaskCombineOperation
  /// Flips this component's own coverage before it is combined.
  public var isInverted: Bool
  /// Edge softening in canvas pixels, applied to this component alone.
  public var feather: Double
  /// Scales this component's coverage, so a component can select an area only
  /// partly.
  public var density: Double

  public init(
    id: MaskComponentID = MaskComponentID(),
    name: String? = nil,
    isEnabled: Bool = true,
    generator: MaskGenerator,
    combine: MaskCombineOperation = .add,
    isInverted: Bool = false,
    feather: Double = 0,
    density: Double = 1
  ) {
    self.id = id
    self.name = name ?? generator.label
    self.isEnabled = isEnabled
    self.generator = generator
    self.combine = combine
    self.isInverted = isInverted
    self.feather = max(feather, 0)
    self.density = min(max(density, 0), 1)
  }

  public var kind: MaskGeneratorKind { generator.kind }

  public var availability: MaskGeneratorAvailability { generator.availability }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let generator = try container.decode(MaskGenerator.self, forKey: .generator)
    self.init(
      id: try container.decodeIfPresent(MaskComponentID.self, forKey: .id) ?? MaskComponentID(),
      name: try container.decodeIfPresent(String.self, forKey: .name),
      isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
      generator: generator,
      combine: try container.decodeIfPresent(MaskCombineOperation.self, forKey: .combine) ?? .add,
      isInverted: try container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false,
      feather: try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0,
      density: try container.decodeIfPresent(Double.self, forKey: .density) ?? 1
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case isEnabled
    case generator
    case combine
    case isInverted
    case feather
    case density
  }
}

/// One mask: an ordered list of components, plus what the mask as a whole does
/// with the result, plus the adjustment it applies where it is opaque.
///
/// The adjustment is the "per-mask adjustment" of the masks tool: it changes
/// only the pixels this mask selects, and it belongs to the layer the mask
/// belongs to rather than to the project. A mask used as a layer mask, a saved
/// selection or an inpaint mask simply leaves `adjustment` nil; nothing else
/// about the type changes.
public struct MaskRecipe: Codable, Equatable, Identifiable, Sendable {
  public var id: MaskID
  public var name: String
  public var isEnabled: Bool
  /// Bottom-up: the first component starts the coverage, each later one is
  /// combined onto what came before with its own operation.
  public var components: [MaskComponent]
  /// Flips the whole mask after every component has been combined.
  public var isInverted: Bool
  /// Edge softening in canvas pixels, applied to the combined result.
  public var feather: Double
  /// What this mask does to the pixels it selects, or `nil` for a mask that
  /// only describes an area.
  public var adjustment: AdjustmentRecipe?

  public init(
    id: MaskID = MaskID(),
    name: String = "Mask",
    isEnabled: Bool = true,
    components: [MaskComponent] = [],
    isInverted: Bool = false,
    feather: Double = 0,
    adjustment: AdjustmentRecipe? = nil
  ) {
    self.id = id
    self.name = name
    self.isEnabled = isEnabled
    self.components = components
    self.isInverted = isInverted
    self.feather = max(feather, 0)
    self.adjustment = adjustment
  }

  /// A mask holding one component, which is what every tool produces first.
  public static func single(
    _ generator: MaskGenerator,
    id: MaskID = MaskID(),
    componentID: MaskComponentID = MaskComponentID(),
    name: String? = nil,
    combine: MaskCombineOperation = .add,
    adjustment: AdjustmentRecipe? = nil
  ) -> MaskRecipe {
    MaskRecipe(
      id: id,
      name: name ?? generator.label,
      components: [
        MaskComponent(id: componentID, generator: generator, combine: combine)
      ],
      adjustment: adjustment
    )
  }

  /// A paintable layer mask backed by the same deterministic stroke recipe as
  /// a paint layer. Reveal All starts white; Hide All starts black.
  public static func layerMask(revealsLayer: Bool = true, id: MaskID = MaskID()) -> MaskRecipe {
    MaskRecipe.single(
      .strokeSurface(
        StrokeSurfaceRecipe(kind: .mask, initialCoverage: revealsLayer ? 1 : 0)),
      id: id,
      name: "Layer Mask"
    )
  }

  public var strokeSurface: StrokeSurfaceRecipe? {
    guard components.count == 1,
      case .strokeSurface(let surface) = components[0].generator
    else { return nil }
    return surface
  }

  public func appendingLayerMaskStroke(_ stroke: PaintStroke) -> MaskRecipe {
    guard components.count == 1,
      case .strokeSurface(let surface) = components[0].generator
    else { return self }
    var copy = self
    copy.components[0].generator = .strokeSurface(surface.appending(stroke))
    return copy
  }

  public func translatedPaint(byX deltaX: Double, y deltaY: Double) -> MaskRecipe {
    var copy = self
    copy.components = copy.components.map { component in
      var moved = component
      if case .strokeSurface(let surface) = component.generator {
        moved.generator = .strokeSurface(surface.translated(byX: deltaX, y: deltaY))
      }
      return moved
    }
    return copy
  }

  /// Keeps mask geometry on the same pixels when a canvas is resized and
  /// anchored. Normalized generators are renormalized; deterministic brush
  /// samples remain in canvas pixels and are translated by the same offset.
  public func resizingCanvas(
    from old: CanvasRecipe,
    to new: CanvasRecipe,
    offset: CanvasOffset
  ) -> MaskRecipe {
    guard old.isResolved, new.isResolved else { return self }
    let oldWidth = Double(old.width)
    let oldHeight = Double(old.height)
    let newWidth = Double(new.width)
    let newHeight = Double(new.height)
    func point(_ value: VectorPoint) -> VectorPoint {
      VectorPoint(
        x: (value.x * oldWidth + offset.x) / newWidth,
        y: (value.y * oldHeight + offset.y) / newHeight)
    }
    func stroke(_ value: PaintStroke) -> PaintStroke {
      var moved = value
      moved.samples = value.samples.map { $0.translated(byX: offset.x, y: offset.y) }
      moved.selectionClip = value.selectionClip?.resizingCanvas(
        from: old, to: new, offset: offset)
      return moved
    }
    var copy = self
    copy.components = components.map { component in
      var moved = component
      switch component.generator {
      case .rectangle(let shape):
        // The corner radius is a fraction of the shorter edge, so it is
        // renormalized against the new one exactly as a radial gradient's is.
        let shortRatio =
          Double(min(old.width, old.height)) / Double(min(new.width, new.height))
        moved.generator = .rectangle(
          ShapeMask(
            from: point(shape.origin),
            to: point(VectorPoint(x: shape.maxX, y: shape.maxY)),
            cornerRadius: shape.cornerRadius * shortRatio))
      case .ellipse(let shape):
        moved.generator = .ellipse(
          ShapeMask(from: point(shape.origin), to: point(VectorPoint(x: shape.maxX, y: shape.maxY))))
      case .polygon(let polygon):
        moved.generator = .polygon(PolygonMask(points: polygon.points.map(point)))
      case .linearGradient(let gradient):
        moved.generator = .linearGradient(
          LinearGradientMask(start: point(gradient.start), end: point(gradient.end)))
      case .radialGradient(let gradient):
        let oldShort = Double(min(old.width, old.height))
        let newShort = Double(min(new.width, new.height))
        moved.generator = .radialGradient(
          RadialGradientMask(
            center: point(gradient.center),
            radius: gradient.radius * oldShort / newShort,
            softness: gradient.softness,
            coversInside: gradient.coversInside))
      case .brush(let brush):
        moved.generator = .brush(
          BrushStrokeMask(
            strokes: brush.strokes.map { brushStroke in
              BrushStroke(
                id: brushStroke.id,
                points: brushStroke.points.map {
                  BrushStrokePoint(position: point($0.position), pressure: $0.pressure)
                },
                radius: brushStroke.radius,
                hardness: brushStroke.hardness,
                flow: brushStroke.flow,
                isErasing: brushStroke.isErasing)
            }))
      case .strokeSurface(let surface):
        moved.generator = .strokeSurface(
          StrokeSurfaceRecipe(
            kind: .mask,
            initialCoverage: surface.initialCoverage,
            strokes: surface.strokes.map(stroke)))
      case .raster:
        // Captured fill coverage remains resolution-bound and scales through
        // MaskSpace when the destination canvas extent changes.
        break
      case .placedRaster(let placed):
        moved.generator = .placedRaster(
          PlacedRasterMask(
            raster: placed.raster,
            frame: ShapeMask(
              from: point(placed.frame.origin),
              to: point(
                VectorPoint(x: placed.frame.maxX, y: placed.frame.maxY)))))
      case .luminanceRange, .colorRange, .subject, .person, .background, .sky:
        break
      }
      return moved
    }
    return copy
  }

  /// Whether this mask can produce coverage at all: it needs at least one
  /// enabled component whose generator is available.
  public var isEvaluable: Bool {
    components.contains { $0.isEnabled && $0.availability.isAvailable }
  }

  /// The components that cannot run, so the inspector can say so instead of
  /// silently rendering less than the user asked for.
  public var unavailableComponents: [MaskComponent] {
    components.filter { !$0.availability.isAvailable }
  }

  /// Whether evaluating this mask needs the pixels it is masking.
  public var readsSourceImage: Bool {
    components.contains { $0.isEnabled && $0.kind.readsSourceImage }
  }

  public func component(id: MaskComponentID) -> MaskComponent? {
    components.first { $0.id == id }
  }

  public func adding(_ component: MaskComponent) -> MaskRecipe {
    var copy = self
    copy.components.append(component)
    return copy
  }

  public func removing(_ componentID: MaskComponentID) -> MaskRecipe {
    var copy = self
    copy.components.removeAll { $0.id == componentID }
    return copy
  }

  public func setting(_ component: MaskComponent) -> MaskRecipe {
    guard let index = components.firstIndex(where: { $0.id == component.id }) else { return self }
    var copy = self
    copy.components[index] = component
    return copy
  }

  public func updatingComponent(
    _ componentID: MaskComponentID,
    _ update: (inout MaskComponent) -> Void
  ) -> MaskRecipe {
    guard let index = components.firstIndex(where: { $0.id == componentID }) else { return self }
    var copy = self
    update(&copy.components[index])
    return copy
  }

  /// Scales the canvas-pixel distances in a mask while leaving its normalized
  /// geometry unchanged. Proxy paint uses this when its stroke samples and
  /// brush diameter are scaled to the render surface.
  public func scalingCoverage(by scale: Double) -> MaskRecipe {
    let safeScale = scale.isFinite ? max(scale, 0) : 1
    var copy = self
    copy.feather *= safeScale
    copy.components = copy.components.map { component in
      var scaled = component
      scaled.feather *= safeScale
      if case .brush(let strokes) = component.generator {
        scaled.generator = .brush(
          BrushStrokeMask(
            strokes: strokes.strokes.map { stroke in
              BrushStroke(
                id: stroke.id,
                points: stroke.points,
                radius: stroke.radius * safeScale,
                hardness: stroke.hardness,
                flow: stroke.flow,
                isErasing: stroke.isErasing
              )
            }
          )
        )
      } else if case .strokeSurface(let surface) = component.generator {
        scaled.generator = .strokeSurface(surface.scaled(byX: safeScale, y: safeScale))
      }
      return scaled
    }
    return copy
  }

  // MARK: Selections
  //
  // A selection is a `MaskRecipe` like any other; these are the operations the
  // Select menu and the marquee and freehand tools are written in terms of.
  // Nothing here is specific to those tools — a mask built any other way
  // answers them the same.

  /// The name a mask made by the selection tools carries into the mask list
  /// once it is saved onto a layer.
  public static let selectionName = "Selection"

  /// The whole canvas, which is what Select All produces.
  public static var selectingAll: MaskRecipe {
    .single(.rectangle(.full), name: selectionName)
  }

  /// A selection holding one freshly placed component, replacing whatever was
  /// selected before. This is what "New" does, and what the first drag of any
  /// gesture does when no selection exists.
  public static func selecting(
    _ generator: MaskGenerator,
    feather: Double = 0
  ) -> MaskRecipe {
    MaskRecipe(
      name: selectionName,
      components: [MaskComponent(generator: generator, feather: feather)]
    )
  }

  /// Joins one more component onto this mask with the stated operation.
  ///
  /// Add, subtract and intersect are already what a component's `combine` means
  /// against everything beneath it, so combining a selection is appending, not
  /// a special case.
  public func combining(
    _ generator: MaskGenerator,
    using combine: MaskCombineOperation,
    feather: Double = 0
  ) -> MaskRecipe {
    adding(MaskComponent(generator: generator, combine: combine, feather: feather))
  }

  /// The layer mask that keeps everything `existing` keeps except what
  /// `selection` selects, or `nil` when that cannot be written down.
  ///
  /// This is what deleting a selection means on a layer: the pixels are not
  /// erased, they are masked away, so the delete is visible in the mask list
  /// and can be undone by removing what it added.
  ///
  /// The catch is that `isInverted` applies to the *whole* recipe once its
  /// components have combined, and the model has no nested masks, so
  /// `M ∩ ¬S` has to be folded into one flat component list. That is exact in
  /// every ordinary case and impossible in one: an inverted selection made of
  /// several components, over a layer that already carries a mask, would need
  /// a union to intersect against. `nil` says so rather than writing a region
  /// that is nearly right.
  public static func hiding(
    _ selection: MaskRecipe,
    from existing: MaskRecipe?
  ) -> MaskRecipe? {
    func effectiveComponents(of mask: MaskRecipe) -> [MaskComponent] {
      mask.components.filter {
        $0.isEnabled && $0.availability.isAvailable && !$0.generator.isEmptyGeometry
      }
    }

    let hidden = effectiveComponents(of: selection)
    // A selection with no geometry hides nothing, so the layer keeps the mask
    // it already had.
    guard !hidden.isEmpty else { return existing }

    // Either the layer carries no mask, or the one it carries restricts
    // nothing. Both mean the layer currently keeps everything, and everything
    // except the selection is simply the selection inverted — exact whatever
    // the selection is made of, which is why the common case never fails.
    guard let existing, !effectiveComponents(of: existing).isEmpty else {
      var mask = selection
      mask.id = existing?.id ?? MaskID()
      mask.name = existing?.name ?? "Layer Mask"
      mask.isEnabled = true
      mask.isInverted.toggle()
      // A layer mask carries coverage, never an adjustment of its own.
      mask.adjustment = nil
      return mask
    }

    var mask = existing
    mask.isEnabled = true

    // An inverted selection hides everything outside its components, so what
    // remains is what they enclose: an intersection. Only a single component
    // can be intersected against; several would have to be unioned first.
    if selection.isInverted {
      guard hidden.count == 1, var kept = hidden.first else { return nil }
      kept.id = MaskComponentID()
      if mask.isInverted {
        // ¬U ∩ c is the same region as c − U, and the second form is the one
        // this model can write: the kept component becomes the base and the
        // old components are taken out of it.
        kept.combine = .add
        mask.components =
          [kept]
          + mask.components.map { component in
            var removed = component
            removed.combine = .subtract
            return removed
          }
        mask.isInverted = false
      } else {
        kept.combine = .intersect
        mask.components.append(kept)
      }
      return mask
    }

    // Appending only reads as "and also this area" when the components already
    // read as a union, which is what a selection built by adding gestures is.
    guard hidden.allSatisfy({ $0.combine == .add }) else { return nil }

    // Read through the inversion: taking S out of ¬U gives ¬(U ∪ S), so an
    // inverted mask grows by addition where an ordinary one shrinks by
    // subtraction. Subtracting from an inverted mask would hide the wrong half.
    let combine: MaskCombineOperation = mask.isInverted ? .add : .subtract
    mask.components += hidden.map { component in
      var part = component
      part.id = MaskComponentID()
      part.combine = combine
      return part
    }
    return mask
  }

  /// Whether this mask selects nothing: no components, or only components with
  /// no geometry to speak of.
  ///
  /// This is distinct from having no selection at all. A document with no
  /// selection places no restriction on editing; a document with an empty
  /// selection restricts editing to nothing.
  public var selectsNothing: Bool {
    components.allSatisfy { !$0.isEnabled || $0.generator.isEmptyGeometry }
  }

  /// A one-line description of what the mask is made of, for the mask list.
  public var summary: String {
    guard !components.isEmpty else { return "Empty" }
    return components.map { component in
      switch component.combine {
      case .add: component.name
      case .subtract: "− \(component.name)"
      case .intersect: "∩ \(component.name)"
      }
    }.joined(separator: " ")
  }
}

extension ProjectLayer {
  /// A mask attached to this layer, by id.
  public func mask(id: MaskID) -> MaskRecipe? {
    masks.first { $0.id == id }
  }

  /// The masks that will actually change pixels in a render.
  public var activeMasks: [MaskRecipe] {
    masks.filter { $0.isEnabled && $0.isEvaluable }
  }

  /// A name no other mask on this layer is using.
  public func availableMaskName(_ base: String = "Mask") -> String {
    let existing = Set(masks.map(\.name))
    guard existing.contains(base) else { return base }
    var number = 2
    while existing.contains("\(base) \(number)") { number += 1 }
    return "\(base) \(number)"
  }
}

extension LayerStackRecipe {
  public func mask(_ maskID: MaskID, on layerID: ProjectLayerID) -> MaskRecipe? {
    layer(id: layerID)?.mask(id: maskID)
  }

  /// Puts a new mask on a layer. The canvas layer carries the document extent
  /// and no pixels, so it never takes one.
  public func addingMask(_ mask: MaskRecipe, to layerID: ProjectLayerID) -> LayerStackRecipe {
    guard let layer = layer(id: layerID), !layer.isCanvasLayer,
      layer.mask(id: mask.id) == nil
    else { return self }
    var copy = self
    copy.updateLayer(id: layerID) { $0.masks.append(mask) }
    return copy
  }

  public func removingMask(_ maskID: MaskID, from layerID: ProjectLayerID) -> LayerStackRecipe {
    guard layer(id: layerID)?.mask(id: maskID) != nil else { return self }
    var copy = self
    copy.updateLayer(id: layerID) { $0.masks.removeAll { $0.id == maskID } }
    return copy
  }

  /// Replaces a mask in place, which is what every mask edit does: the caller
  /// builds the mask it wants and names the undo step.
  public func settingMask(_ mask: MaskRecipe, on layerID: ProjectLayerID) -> LayerStackRecipe {
    guard let layer = layer(id: layerID),
      let index = layer.masks.firstIndex(where: { $0.id == mask.id })
    else { return self }
    var copy = self
    copy.updateLayer(id: layerID) { $0.masks[index] = mask }
    return copy
  }

  public func settingMaskEnabled(
    _ enabled: Bool,
    _ maskID: MaskID,
    on layerID: ProjectLayerID
  ) -> LayerStackRecipe {
    guard var mask = layer(id: layerID)?.mask(id: maskID), mask.isEnabled != enabled else {
      return self
    }
    mask.isEnabled = enabled
    return settingMask(mask, on: layerID)
  }

  public func settingMaskAdjustment(
    _ adjustment: AdjustmentRecipe?,
    _ maskID: MaskID,
    on layerID: ProjectLayerID
  ) -> LayerStackRecipe {
    guard var mask = layer(id: layerID)?.mask(id: maskID), mask.adjustment != adjustment else {
      return self
    }
    mask.adjustment = adjustment
    return settingMask(mask, on: layerID)
  }

  /// Every mask in the document with the layer it belongs to, in visual order.
  ///
  /// Selections, layer masks and inpaint masks will all show up here once they
  /// are attached, so anything asking "what masks does this document have?"
  /// asks this.
  public var allMasks: [(layerID: ProjectLayerID, mask: MaskRecipe)] {
    flattenedLayers.flatMap { entry in
      entry.layer.masks.map { (entry.id, $0) }
    }
  }
}

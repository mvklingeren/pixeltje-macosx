import Foundation

/// Vector geometry is stored in the canonical, post-orientation and post-crop
/// image coordinate space. Positions are normalized to the image extent so a
/// path remains stable while the app swaps proxy and full-resolution RAW
/// renders. Values remain `Double` throughout editing and are only changed by
/// an explicit snap operation.
public struct VectorPoint: Codable, Equatable, Hashable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  public static let zero = VectorPoint(x: 0, y: 0)

  public func distance(to other: VectorPoint) -> Double {
    hypot(other.x - x, other.y - y)
  }

  public func interpolated(to other: VectorPoint, t: Double) -> VectorPoint {
    VectorPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t)
  }

  public static func + (lhs: VectorPoint, rhs: VectorPoint) -> VectorPoint {
    VectorPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
  }

  public static func - (lhs: VectorPoint, rhs: VectorPoint) -> VectorPoint {
    VectorPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }

  public static func * (lhs: VectorPoint, rhs: Double) -> VectorPoint {
    VectorPoint(x: lhs.x * rhs, y: lhs.y * rhs)
  }
}

public struct VectorColor: Codable, Equatable, Hashable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public static let black = VectorColor(red: 0, green: 0, blue: 0)
  public static let white = VectorColor(red: 1, green: 1, blue: 1)

  /// Display P3 uses the sRGB transfer curve. Vector recipes persist those
  /// authored (gamma-encoded) components, while the document renderer blends
  /// in Extended Linear Display P3.
  var linearDisplayP3: VectorColor {
    VectorColor(
      red: Self.decodeTransfer(red),
      green: Self.decodeTransfer(green),
      blue: Self.decodeTransfer(blue),
      alpha: alpha)
  }

  /// Converts linear-light Display P3 components back to the representation
  /// stored in a vector recipe and shown by a Display P3 color well.
  var encodedDisplayP3: VectorColor {
    VectorColor(
      red: Self.encodeTransfer(red),
      green: Self.encodeTransfer(green),
      blue: Self.encodeTransfer(blue),
      alpha: alpha)
  }

  private static func decodeTransfer(_ component: Double) -> Double {
    let magnitude = abs(component)
    let linear = magnitude <= 0.04045
      ? magnitude / 12.92
      : pow((magnitude + 0.055) / 1.055, 2.4)
    return component < 0 ? -linear : linear
  }

  private static func encodeTransfer(_ component: Double) -> Double {
    let magnitude = abs(component)
    let encoded = magnitude <= 0.003_130_8
      ? magnitude * 12.92
      : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
    return component < 0 ? -encoded : encoded
  }
}

public enum VectorLineCap: String, Codable, CaseIterable, Sendable {
  case butt
  case round
  case square
}

public enum VectorLineJoin: String, Codable, CaseIterable, Sendable {
  case miter
  case round
  case bevel
}

/// Where a stroke sits relative to the outline it follows.
///
/// Only a closed outline has an inside, so an open path is always centered
/// whatever this says; the renderer decides that rather than the model, so a
/// path that is later closed keeps the alignment it was given.
public enum VectorStrokeAlignment: String, Codable, CaseIterable, Sendable {
  case inside
  case center
  case outside

  public var label: String {
    switch self {
    case .inside: "Inside"
    case .center: "Center"
    case .outside: "Outside"
    }
  }
}

/// A head drawn at one end of an open stroke.
public struct VectorArrowhead: Codable, Equatable, Hashable, Sendable {
  public enum Style: String, Codable, CaseIterable, Sendable {
    case triangle
    case openTriangle
    case circle
    case square
    case bar

    public var label: String {
      switch self {
      case .triangle: "Triangle"
      case .openTriangle: "Open"
      case .circle: "Circle"
      case .square: "Square"
      case .bar: "Bar"
      }
    }
  }

  public var style: Style
  /// Length as a multiple of the stroke width, so a head stays in proportion
  /// when the stroke is made thicker.
  public var scale: Double

  public init(style: Style = .triangle, scale: Double = 3) {
    self.style = style
    self.scale = scale.isFinite ? min(max(scale, 0.5), 20) : 3
  }

  private enum CodingKeys: String, CodingKey {
    case style
    case scale
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      style: try container.decode(Style.self, forKey: .style),
      scale: try container.decode(Double.self, forKey: .scale))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(style, forKey: .style)
    try container.encode(scale, forKey: .scale)
  }
}

public struct VectorStrokeStyle: Equatable, Hashable, Sendable {
  public var color: VectorColor
  /// Stroke width in canonical image pixels.
  public var width: Double
  public var lineCap: VectorLineCap
  public var lineJoin: VectorLineJoin
  /// How far a miter may extend, as a multiple of the width, before the join
  /// falls back to a bevel.
  public var miterLimit: Double
  /// Alternating dash and gap lengths, in canonical image pixels.
  public var dashPattern: [Double]
  /// How far into the pattern the first dash starts.
  public var dashPhase: Double
  public var alignment: VectorStrokeAlignment
  /// Stroke opacity, separate from the color's own alpha so a color can be
  /// reused while the stroke fades.
  public var opacity: Double
  public var startArrowhead: VectorArrowhead?
  public var endArrowhead: VectorArrowhead?

  public init(
    color: VectorColor = .white,
    width: Double = 8,
    lineCap: VectorLineCap = .round,
    lineJoin: VectorLineJoin = .round,
    miterLimit: Double = 10,
    dashPattern: [Double] = [],
    dashPhase: Double = 0,
    alignment: VectorStrokeAlignment = .center,
    opacity: Double = 1,
    startArrowhead: VectorArrowhead? = nil,
    endArrowhead: VectorArrowhead? = nil
  ) {
    self.color = color
    self.width = width
    self.lineCap = lineCap
    self.lineJoin = lineJoin
    self.miterLimit = miterLimit.isFinite ? max(miterLimit, 1) : 10
    self.dashPattern = dashPattern.filter { $0.isFinite && $0 >= 0 }
    self.dashPhase = dashPhase.isFinite ? dashPhase : 0
    self.alignment = alignment
    self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1
    self.startArrowhead = startArrowhead
    self.endArrowhead = endArrowhead
  }

  /// Whether the stroke would paint anything at all.
  public var isVisible: Bool { width > 0 && opacity > 0 && color.alpha > 0 }

  /// The color as drawn, with stroke opacity folded in.
  public var effectiveColor: VectorColor {
    var result = color
    result.alpha = color.alpha * opacity
    return result
  }

  /// A dash pattern Core Graphics will accept: at least one non-zero length,
  /// and no negative entries.
  public var usableDashPattern: [Double]? {
    let cleaned = dashPattern.filter { $0.isFinite && $0 >= 0 }
    guard cleaned.count >= 2, cleaned.contains(where: { $0 > 0 }) else { return nil }
    return cleaned
  }
}

extension VectorStrokeStyle: Codable {
  private enum CodingKeys: String, CodingKey {
    case color
    case width
    case lineCap
    case lineJoin
    case miterLimit
    case dashPattern
    case dashPhase
    case alignment
    case opacity
    case startArrowhead
    case endArrowhead
  }

  /// Everything past the original five keys is optional, so a project written
  /// before the stroke model was completed decodes with the defaults it was
  /// drawn with.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      color: try container.decode(VectorColor.self, forKey: .color),
      width: try container.decode(Double.self, forKey: .width),
      lineCap: try container.decode(VectorLineCap.self, forKey: .lineCap),
      lineJoin: try container.decode(VectorLineJoin.self, forKey: .lineJoin),
      miterLimit: try container.decodeIfPresent(Double.self, forKey: .miterLimit) ?? 10,
      dashPattern: try container.decode([Double].self, forKey: .dashPattern),
      dashPhase: try container.decodeIfPresent(Double.self, forKey: .dashPhase) ?? 0,
      alignment: try container.decodeIfPresent(
        VectorStrokeAlignment.self, forKey: .alignment) ?? .center,
      opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
      startArrowhead: try container.decodeIfPresent(
        VectorArrowhead.self, forKey: .startArrowhead),
      endArrowhead: try container.decodeIfPresent(VectorArrowhead.self, forKey: .endArrowhead)
    )
  }
}

/// One fill on one object: what it paints, and how opaque it is.
///
/// Older projects stored only a color. Those decode into a solid fill with full
/// opacity, so reopening one looks exactly as it did.
public struct VectorFillStyle: Equatable, Hashable, Sendable {
  public var content: VectorFillContent
  /// Opacity for a solid fill. A gradient keeps its own, so the two travel
  /// together; `opacity` reads and writes whichever applies.
  var solidOpacity: Double

  public init(color: VectorColor, opacity: Double = 1) {
    self.content = .solid(color)
    self.solidOpacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1
  }

  public init(gradient: VectorGradient) {
    self.content = .gradient(gradient)
    self.solidOpacity = 1
  }

  public init(content: VectorFillContent, opacity: Double = 1) {
    self.content = content
    self.solidOpacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1
  }
}

extension VectorFillStyle: Codable {
  private enum CodingKeys: String, CodingKey {
    case content
    case opacity
    /// Schema 17 and earlier: the fill was one color and nothing else.
    case color
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let content = try container.decodeIfPresent(VectorFillContent.self, forKey: .content) {
      self.init(
        content: content,
        opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1)
    } else {
      self.init(color: try container.decode(VectorColor.self, forKey: .color))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(content, forKey: .content)
    try container.encode(solidOpacity, forKey: .opacity)
  }
}

public enum VectorAnchorKind: String, Codable, CaseIterable, Sendable {
  case corner
  case smooth
  case symmetric
}

public struct VectorAnchor: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var position: VectorPoint
  public var incomingHandle: VectorPoint?
  public var outgoingHandle: VectorPoint?
  public var kind: VectorAnchorKind

  public init(
    id: UUID = UUID(),
    position: VectorPoint,
    incomingHandle: VectorPoint? = nil,
    outgoingHandle: VectorPoint? = nil,
    kind: VectorAnchorKind = .corner
  ) {
    self.id = id
    self.position = position
    self.incomingHandle = incomingHandle
    self.outgoingHandle = outgoingHandle
    self.kind = kind
  }

  public func translated(by delta: VectorPoint) -> VectorAnchor {
    var copy = self
    copy.position = position + delta
    if let incomingHandle { copy.incomingHandle = incomingHandle + delta }
    if let outgoingHandle { copy.outgoingHandle = outgoingHandle + delta }
    return copy
  }

  public var accessibilityDescription: String {
    let handleCount = [incomingHandle, outgoingHandle].compactMap { $0 }.filter {
      $0 != position
    }.count
    let type =
      switch kind {
      case .corner: "Corner"
      case .smooth: "Smooth"
      case .symmetric: "Symmetric"
      }
    let handles =
      switch handleCount {
      case 0: "no handles"
      case 1: "one handle"
      default: "two handles"
      }
    return "\(type) anchor, \(handles)."
  }
}

public struct VectorPath: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var zOrder: Int
  public var anchors: [VectorAnchor]
  public var isClosed: Bool
  public var stroke: VectorStrokeStyle?
  public var fill: VectorFillStyle?

  public init(
    id: UUID = UUID(),
    name: String = "Path",
    zOrder: Int = 0,
    anchors: [VectorAnchor] = [],
    isClosed: Bool = false,
    stroke: VectorStrokeStyle? = VectorStrokeStyle(),
    fill: VectorFillStyle? = nil
  ) {
    self.id = id
    self.name = name
    self.zOrder = zOrder
    self.anchors = anchors
    self.isClosed = isClosed
    self.stroke = stroke
    self.fill = fill
  }

  public func reversed() -> VectorPath {
    var copy = self
    copy.anchors = anchors.reversed().map { anchor in
      var reversed = anchor
      reversed.incomingHandle = anchor.outgoingHandle
      reversed.outgoingHandle = anchor.incomingHandle
      return reversed
    }
    return copy
  }
}

/// A tagged object container keeps vector layers independent of the Pen tool.
///
/// Adding a case adds a kind of artwork without changing layer ownership,
/// ordering, visibility, or document persistence. Every case answers the same
/// questions — identity, order, name, appearance, and the Bezier geometry it
/// draws as — so renderers and tools never have to know which case they hold.
public enum VectorObject: Codable, Equatable, Hashable, Identifiable, Sendable {
  case path(VectorPath)
  case shape(VectorShape)
  case compound(VectorCompoundPath)

  public var id: UUID {
    switch self {
    case .path(let path): path.id
    case .shape(let shape): shape.id
    case .compound(let compound): compound.id
    }
  }

  public var zOrder: Int {
    get {
      switch self {
      case .path(let path): path.zOrder
      case .shape(let shape): shape.zOrder
      case .compound(let compound): compound.zOrder
      }
    }
    set {
      switch self {
      case .path(var path):
        path.zOrder = newValue
        self = .path(path)
      case .shape(var shape):
        shape.zOrder = newValue
        self = .shape(shape)
      case .compound(var compound):
        compound.zOrder = newValue
        self = .compound(compound)
      }
    }
  }

  public var name: String {
    get {
      switch self {
      case .path(let path): path.name
      case .shape(let shape): shape.name
      case .compound(let compound): compound.name
      }
    }
    set {
      switch self {
      case .path(var path):
        path.name = newValue
        self = .path(path)
      case .shape(var shape):
        shape.name = newValue
        self = .shape(shape)
      case .compound(var compound):
        compound.name = newValue
        self = .compound(compound)
      }
    }
  }

  public var stroke: VectorStrokeStyle? {
    get {
      switch self {
      case .path(let path): path.stroke
      case .shape(let shape): shape.stroke
      case .compound(let compound): compound.stroke
      }
    }
    set {
      switch self {
      case .path(var path):
        path.stroke = newValue
        self = .path(path)
      case .shape(var shape):
        shape.stroke = newValue
        self = .shape(shape)
      case .compound(var compound):
        compound.stroke = newValue
        self = .compound(compound)
      }
    }
  }

  public var fill: VectorFillStyle? {
    get {
      switch self {
      case .path(let path): path.fill
      case .shape(let shape): shape.fill
      case .compound(let compound): compound.fill
      }
    }
    set {
      switch self {
      case .path(var path):
        path.fill = newValue
        self = .path(path)
      case .shape(var shape):
        shape.fill = newValue
        self = .shape(shape)
      case .compound(var compound):
        compound.fill = newValue
        self = .compound(compound)
      }
    }
  }

  /// Whether the object encloses an area, and so can be filled.
  public var isClosed: Bool {
    switch self {
    case .path(let path): path.isClosed
    case .shape(let shape): shape.kind.isClosed
    case .compound(let compound): compound.isClosed
    }
  }

  /// The stored path, for objects that are one.
  ///
  /// A shape has parameters instead. Writing through this accessor therefore
  /// changes nothing on a shape: anchor editing must go through Convert Shape
  /// to Path, so a stray edit cannot silently discard a side count or a corner
  /// radius.
  public var path: VectorPath? {
    get {
      guard case .path(let path) = self else { return nil }
      return path
    }
    set {
      guard case .path = self, let newValue else { return }
      self = .path(newValue)
    }
  }

  public var shape: VectorShape? {
    get {
      guard case .shape(let shape) = self else { return nil }
      return shape
    }
    set {
      guard case .shape = self, let newValue else { return }
      self = .shape(newValue)
    }
  }

  public var compound: VectorCompoundPath? {
    get {
      guard case .compound(let compound) = self else { return nil }
      return compound
    }
    set {
      guard case .compound = self, let newValue else { return }
      self = .compound(newValue)
    }
  }

  /// The object's first contour, for callers that only ever deal in one.
  ///
  /// A compound path has more than one; `resolvedContours(aspect:)` is what a
  /// renderer wants.
  public func resolvedPath(aspect: Double = 1) -> VectorPath {
    resolvedContours(aspect: aspect).first ?? VectorPath(id: id, name: name, zOrder: zOrder)
  }
}

public struct VectorLayer: Codable, Equatable, Sendable {
  public var objects: [VectorObject]

  public init(objects: [VectorObject] = []) {
    self.objects = objects
  }

  /// The stored paths, bottom to top. Shapes are not stored as paths and are
  /// not listed here; `resolvedPaths(aspect:)` is what a renderer wants.
  public var paths: [VectorPath] {
    objects.compactMap(\.path).sorted { $0.zOrder < $1.zOrder }
  }

  /// Every object as Bezier geometry, bottom to top.
  ///
  /// This is the one thing renderers, hit testing, and export read, so a shape
  /// and a path are indistinguishable to them.
  public func resolvedPaths(aspect: Double = 1) -> [VectorPath] {
    objects.sorted { $0.zOrder < $1.zOrder }.flatMap { object in
      object.resolvedContours(aspect: aspect).map { contour in
        // Contours carry no appearance of their own, so a caller drawing them
        // one at a time still gets the object's stroke and fill.
        var styled = contour
        styled.stroke = object.stroke
        styled.fill = object.fill
        return styled
      }
    }
  }

  /// Recolors objects without changing their geometry. Shape controls normally
  /// target closed objects only; the Pen tool also updates an open path's
  /// stored fill so that the chosen color appears if that path is later closed.
  ///
  /// `objectIDs` limits the change to the current object selection. Passing nil
  /// keeps the older whole-layer behavior, which is what a layer-level control
  /// with nothing selected still means.
  public func settingFillColor(
    _ color: VectorColor?,
    includingOpenPaths: Bool = false,
    objectIDs: Set<UUID>? = nil
  ) -> VectorLayer {
    updatingObjects(ids: objectIDs) { object in
      guard object.isClosed || includingOpenPaths else { return }
      object.fill = color.map { VectorFillStyle(color: $0) }
    }
  }

  /// Recolors objects while preserving their existing width, cap, join, and
  /// dash pattern. An object without a stroke receives the supplied default
  /// width.
  public func settingStrokeColor(
    _ color: VectorColor?,
    defaultWidth: Double = 4,
    objectIDs: Set<UUID>? = nil
  ) -> VectorLayer {
    updatingObjects(ids: objectIDs) { object in
      guard let color else {
        object.stroke = nil
        return
      }
      if var stroke = object.stroke {
        stroke.color = color
        object.stroke = stroke
      } else {
        object.stroke = VectorStrokeStyle(color: color, width: max(defaultWidth, 0))
      }
    }
  }

  /// Changes stroke width while retaining the other stroke details. Objects
  /// without a stroke receive the supplied default color.
  public func settingStrokeWidth(
    _ width: Double,
    defaultColor: VectorColor = .white,
    objectIDs: Set<UUID>? = nil
  ) -> VectorLayer {
    updatingObjects(ids: objectIDs) { object in
      if var stroke = object.stroke {
        stroke.width = max(width, 0)
        object.stroke = stroke
      } else {
        object.stroke = VectorStrokeStyle(color: defaultColor, width: max(width, 0))
      }
    }
  }
}

extension ProjectLayerContent {
  public var vectorValue: VectorLayer? {
    guard case .vector(let layer) = self else { return nil }
    return layer
  }
}

/// One vector layer as the canvas overlay and the export path draw it.
public struct VectorArtworkEntry: Equatable, Sendable {
  public var layer: ProjectLayer
  public var vectorLayer: VectorLayer
  /// The layer's opacity and fill, and those of every group around it.
  public var effectiveOpacity: Double
}

extension LayerStackRecipe {
  public mutating func ensureActiveVectorLayer() -> ProjectLayerID {
    if let activeLayerID,
      let layer = layer(id: activeLayerID),
      layer.isVectorLayer, !layer.isLocked
    {
      return layer.id
    }

    let nextZ = (allLayers.map(\.zOrder).max() ?? -1) + 1
    let layer = ProjectLayer(
      name: "Vector Layer",
      isEnabled: true,
      isLocked: false,
      zOrder: nextZ,
      content: .vector(VectorLayer())
    )
    layers.insert(layer, at: 0)
    activeLayerID = layer.id
    return layer.id
  }

  /// The effectively visible vector layers, bottom to top, wherever they sit
  /// in the group tree. Editing overlays and standalone vector previews use
  /// this flattened view; the render engine walks the recursive tree itself so
  /// masks, group boundaries and blend modes remain authoritative.
  public var vectorArtwork: [VectorArtworkEntry] {
    return flattenedLayers
      .filter(\.isEffectivelyEnabled)
      .compactMap { entry in
        guard case .vector(let vectorLayer) = entry.layer.content else { return nil }
        return VectorArtworkEntry(
          layer: entry.layer,
          vectorLayer: vectorLayer,
          effectiveOpacity: entry.effectiveOpacity
        )
      }
      .sorted { $0.layer.zOrder < $1.layer.zOrder }
  }

  public func path(id: UUID) -> (layerID: ProjectLayerID, path: VectorPath)? {
    for layer in allLayers {
      guard case .vector(let vectorLayer) = layer.content else { continue }
      if let path = vectorLayer.paths.first(where: { $0.id == id }) {
        return (layer.id, path)
      }
    }
    return nil
  }

  public mutating func updatePath(id: UUID, _ update: (inout VectorPath) -> Void) {
    guard let owner = path(id: id)?.layerID else { return }
    updateLayer(id: owner) { layer in
      guard case .vector(var vectorLayer) = layer.content,
        let objectIndex = vectorLayer.objects.firstIndex(where: { $0.id == id }),
        case .path(var path) = vectorLayer.objects[objectIndex]
      else { return }
      update(&path)
      vectorLayer.objects[objectIndex] = .path(path)
      layer.content = .vector(vectorLayer)
    }
  }

  public mutating func removePath(id: UUID) {
    guard let owner = path(id: id)?.layerID else { return }
    updateLayer(id: owner) { layer in
      guard case .vector(var vectorLayer) = layer.content else { return }
      vectorLayer.objects.removeAll { $0.id == id }
      layer.content = .vector(vectorLayer)
    }
  }

  public mutating func appendPath(_ path: VectorPath, to layerID: ProjectLayerID) {
    updateLayer(id: layerID) { layer in
      guard case .vector(var vectorLayer) = layer.content else { return }
      vectorLayer.objects.append(.path(path))
      layer.content = .vector(vectorLayer)
    }
  }
}

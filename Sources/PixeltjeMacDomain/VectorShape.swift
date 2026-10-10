import Foundation

/// A rectangle's four corner radii, each a fraction of the shape's shorter
/// side: 0 is square and 0.5 is fully rounded.
///
/// Radii are stored per corner rather than as one value so a card, a tab, or a
/// speech bubble is still a rectangle rather than something that had to be
/// converted to a path. They are fractions rather than pixels so a shape keeps
/// its proportions through a canvas resize; the controls convert to and from
/// pixels where the canvas extent is known.
public struct VectorCornerRadii: Codable, Equatable, Hashable, Sendable {
  public var bottomLeft: Double
  public var bottomRight: Double
  public var topRight: Double
  public var topLeft: Double

  public init(
    bottomLeft: Double = 0,
    bottomRight: Double = 0,
    topRight: Double = 0,
    topLeft: Double = 0
  ) {
    self.bottomLeft = bottomLeft.isFinite ? max(bottomLeft, 0) : 0
    self.bottomRight = bottomRight.isFinite ? max(bottomRight, 0) : 0
    self.topRight = topRight.isFinite ? max(topRight, 0) : 0
    self.topLeft = topLeft.isFinite ? max(topLeft, 0) : 0
  }

  public init(uniform radius: Double) {
    self.init(
      bottomLeft: radius, bottomRight: radius, topRight: radius, topLeft: radius)
  }

  public var uniformValue: Double? { isUniform ? bottomLeft : nil }

  public static let none = VectorCornerRadii()

  public var isUniform: Bool {
    bottomLeft == bottomRight && bottomRight == topRight && topRight == topLeft
  }

  public var isZero: Bool { isUniform && bottomLeft == 0 }

  public var largest: Double { max(max(bottomLeft, bottomRight), max(topRight, topLeft)) }

  private enum CodingKeys: String, CodingKey {
    case bottomLeft
    case bottomRight
    case topRight
    case topLeft
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      bottomLeft: try container.decode(Double.self, forKey: .bottomLeft),
      bottomRight: try container.decode(Double.self, forKey: .bottomRight),
      topRight: try container.decode(Double.self, forKey: .topRight),
      topLeft: try container.decode(Double.self, forKey: .topLeft))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(bottomLeft, forKey: .bottomLeft)
    try container.encode(bottomRight, forKey: .bottomRight)
    try container.encode(topRight, forKey: .topRight)
    try container.encode(topLeft, forKey: .topLeft)
  }

}

/// What a parametric shape is, and the parameters that make it that shape.
public enum VectorShapeKind: Codable, Equatable, Hashable, Sendable {
  case rectangle(corners: VectorCornerRadii)
  case ellipse
  case line
  case polygon(sides: Int)
  case star(points: Int, innerRatio: Double)

  public static let minimumSides = 3
  public static let maximumSides = 64

  public var label: String {
    switch self {
    case .rectangle(let corners): corners.isZero ? "Rectangle" : "Rounded Rectangle"
    case .ellipse: "Ellipse"
    case .line: "Line"
    case .polygon: "Polygon"
    case .star: "Star"
    }
  }

  public var symbolName: String {
    switch self {
    case .rectangle: "rectangle"
    case .ellipse: "circle"
    case .line: "line.diagonal"
    case .polygon: "pentagon"
    case .star: "star"
    }
  }

  /// Whether the shape encloses an area, and so can be filled.
  public var isClosed: Bool {
    if case .line = self { return false }
    return true
  }

  /// Clamps the parameters that have a valid range, so a decoded or
  /// hand-edited project cannot ask for a two-sided polygon.
  public var validated: VectorShapeKind {
    switch self {
    case .rectangle(let corners):
      .rectangle(
        corners: VectorCornerRadii(
          bottomLeft: corners.bottomLeft,
          bottomRight: corners.bottomRight,
          topRight: corners.topRight,
          topLeft: corners.topLeft))
    case .ellipse: .ellipse
    case .line: .line
    case .polygon(let sides):
      .polygon(sides: min(max(sides, Self.minimumSides), Self.maximumSides))
    case .star(let points, let innerRatio):
      .star(
        points: min(max(points, Self.minimumSides), Self.maximumSides),
        innerRatio: innerRatio.isFinite ? min(max(innerRatio, 0.05), 0.95) : 0.5
      )
    }
  }
}

/// A shape that stays what it is.
///
/// The Shape tool used to convert its result into ordinary anchors the moment
/// it was drawn, which threw away the side count, the corner radius, and the
/// rotation the user had chosen. A shape keeps those parameters and resolves to
/// Bezier geometry on demand, so it can still be restyled, transformed,
/// rendered, and exported like any other object — and converted to a path
/// explicitly, when the user wants anchors.
public struct VectorShape: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var zOrder: Int
  public var kind: VectorShapeKind
  /// The unrotated box the shape is inscribed in, in normalized image
  /// coordinates. A line runs from the box's lower-left to its upper-right.
  public var frame: VectorBounds
  /// Rotation about the frame's center, in degrees, measured on screen.
  ///
  /// Normalized coordinates are anisotropic, so resolving a rotation needs the
  /// image's aspect; storing degrees rather than a matrix keeps the parameter
  /// meaningful in the inspector and stable across a canvas resize.
  public var rotationDegrees: Double
  public var stroke: VectorStrokeStyle?
  public var fill: VectorFillStyle?

  public init(
    id: UUID = UUID(),
    name: String? = nil,
    zOrder: Int = 0,
    kind: VectorShapeKind,
    frame: VectorBounds,
    rotationDegrees: Double = 0,
    stroke: VectorStrokeStyle? = VectorStrokeStyle(),
    fill: VectorFillStyle? = nil
  ) {
    self.id = id
    self.kind = kind.validated
    self.name = name ?? self.kind.label
    self.zOrder = zOrder
    self.frame = frame
    self.rotationDegrees = rotationDegrees.isFinite ? rotationDegrees : 0
    self.stroke = stroke
    self.fill = self.kind.isClosed ? fill : nil
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case zOrder
    case kind
    case frame
    case rotationDegrees
    case stroke
    case fill
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      name: try container.decode(String.self, forKey: .name),
      zOrder: try container.decode(Int.self, forKey: .zOrder),
      kind: try container.decode(VectorShapeKind.self, forKey: .kind),
      frame: try container.decode(VectorBounds.self, forKey: .frame),
      rotationDegrees: try container.decode(Double.self, forKey: .rotationDegrees),
      stroke: try container.decodeIfPresent(VectorStrokeStyle.self, forKey: .stroke),
      fill: try container.decodeIfPresent(VectorFillStyle.self, forKey: .fill))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(zOrder, forKey: .zOrder)
    try container.encode(kind, forKey: .kind)
    try container.encode(frame, forKey: .frame)
    try container.encode(rotationDegrees, forKey: .rotationDegrees)
    try container.encodeIfPresent(stroke, forKey: .stroke)
    try container.encodeIfPresent(fill, forKey: .fill)
  }

  public var center: VectorPoint { frame.center }

  /// The Bezier geometry this shape currently describes.
  ///
  /// One conversion serves rendering, hit testing, export, and Convert Shape to
  /// Path, so a shape can never look like one thing and select like another.
  /// `aspect` is the image's width divided by its height; it makes the stored
  /// rotation a rotation on screen rather than a shear.
  public func resolvedPath(aspect: Double = 1) -> VectorPath {
    var path = VectorPath(
      id: id,
      name: name,
      zOrder: zOrder,
      anchors: anchors(aspect: aspect),
      isClosed: kind.isClosed,
      stroke: stroke,
      fill: fill
    )
    guard rotationDegrees != 0 else { return path }
    let rotation = VectorAffineTransform.rotation(
      radians: rotationDegrees * .pi / 180, about: center, aspect: aspect)
    path = path.transformed(by: rotation, aspect: aspect)
    // The transform scales stroke width by its determinant; a rotation has one,
    // but floating point can nudge it, so the authored width is restored.
    path.stroke = stroke
    return path
  }

  /// Replaces the shape with the anchors it currently resolves to, keeping its
  /// identity, name, ordering, and appearance.
  public func convertedToPath(aspect: Double = 1) -> VectorPath {
    resolvedPath(aspect: aspect)
  }

  /// The same shape after a transform, or nil when the transform is one no
  /// shape parameter can describe.
  ///
  /// A move, a scale, a rotation, and a reflection all keep the shape
  /// parametric. A shear does not: the caller converts to a path instead, which
  /// is the honest result rather than a shape that quietly ignores part of the
  /// transform.
  public func transformed(
    by transform: VectorAffineTransform, aspect: Double = 1
  ) -> VectorShape? {
    guard !transform.isIdentity else { return self }
    let safeAspect = aspect > 0 ? aspect : 1
    let authoredRotation = VectorAffineTransform.rotation(
      radians: rotationDegrees * .pi / 180,
      about: center,
      aspect: safeAspect)
    let originalX = authoredRotation.apply(
      to: VectorPoint(x: center.x + frame.width / 2, y: center.y))
    let originalY = authoredRotation.apply(
      to: VectorPoint(x: center.x, y: center.y + frame.height / 2))
    let movedCenter = transform.apply(to: center)
    let movedX = transform.apply(to: originalX)
    let movedY = transform.apply(to: originalY)

    // Measure the composed axes in pixels. Looking only at the incoming
    // transform misses the shear produced when an already-rotated shape is
    // scaled non-uniformly in canvas coordinates.
    var xAxis = (
      x: (movedX.x - movedCenter.x) * safeAspect,
      y: movedX.y - movedCenter.y)
    let yAxis = (
      x: (movedY.x - movedCenter.x) * safeAspect,
      y: movedY.y - movedCenter.y)
    let xLength = hypot(xAxis.x, xAxis.y)
    let yLength = hypot(yAxis.x, yAxis.y)
    guard xLength.isFinite, yLength.isFinite, xLength > 0, yLength > 0 else { return nil }
    let dot = xAxis.x * yAxis.x + xAxis.y * yAxis.y
    guard abs(dot) <= xLength * yLength * 0.000_1 else { return nil }

    var transformedKind = kind
    let determinant = xAxis.x * yAxis.y - xAxis.y * yAxis.x
    if determinant < 0 {
      // A positive frame plus rotation has no reflection bit. Flipping the
      // represented x-axis restores a positive basis for symmetric shapes;
      // asymmetric rectangle corners follow that flip. A diagonal line is not
      // symmetric under it and must become an ordinary path.
      guard case .line = kind else {
        xAxis = (-xAxis.x, -xAxis.y)
        if case .rectangle(let corners) = kind {
          transformedKind = .rectangle(
            corners: VectorCornerRadii(
              bottomLeft: corners.bottomRight,
              bottomRight: corners.bottomLeft,
              topRight: corners.topLeft,
              topLeft: corners.topRight))
        }
        return transformedShape(
          kind: transformedKind,
          center: movedCenter,
          xAxis: xAxis,
          xLength: xLength,
          yLength: yLength,
          transform: transform,
          aspect: safeAspect)
      }
      return nil
    }

    return transformedShape(
      kind: transformedKind,
      center: movedCenter,
      xAxis: xAxis,
      xLength: xLength,
      yLength: yLength,
      transform: transform,
      aspect: safeAspect)
  }

  private func transformedShape(
    kind: VectorShapeKind,
    center movedCenter: VectorPoint,
    xAxis: (x: Double, y: Double),
    xLength: Double,
    yLength: Double,
    transform: VectorAffineTransform,
    aspect: Double
  ) -> VectorShape? {
    if case .rectangle(let corners) = kind, !corners.isZero {
      let originalXLength = frame.width * aspect / 2
      let originalYLength = frame.height / 2
      guard originalXLength > 0, originalYLength > 0 else { return nil }
      let scaleX = xLength / originalXLength
      let scaleY = yLength / originalYLength
      // Rounded corners resolve as circles in pixel space. An anisotropic
      // scale turns them into ellipses, which this parametric shape cannot
      // express without changing its appearance.
      guard abs(scaleX - scaleY) <= max(scaleX, scaleY) * 0.000_1 else { return nil }
    }

    var copy = self
    copy.kind = kind
    copy.rotationDegrees = atan2(xAxis.y, xAxis.x) * 180 / .pi
    let width = xLength * 2 / aspect
    let height = yLength * 2
    copy.frame = VectorBounds(
      minX: movedCenter.x - width / 2,
      minY: movedCenter.y - height / 2,
      maxX: movedCenter.x + width / 2,
      maxY: movedCenter.y + height / 2
    )
    if var stroke = copy.stroke {
      stroke.width = max(stroke.width * transform.uniformScale, 0)
      copy.stroke = stroke
    }
    copy.fill = fill?.transformed(by: transform, aspect: aspect)
    return copy
  }

  // MARK: - Geometry

  private func anchors(aspect: Double) -> [VectorAnchor] {
    let x0 = frame.minX
    let y0 = frame.minY
    let x1 = frame.maxX
    let y1 = frame.maxY

    // `kind` remains publicly mutable for editor ergonomics. Validate again at
    // this allocation boundary so even an in-memory or hand-decoded value can
    // never make `points * 2` overflow or allocate an unreasonable path.
    switch kind.validated {
    case .line:
      return [
        VectorAnchor(position: VectorPoint(x: x0, y: y0)),
        VectorAnchor(position: VectorPoint(x: x1, y: y1)),
      ]
    case .rectangle(let corners):
      return rectangleAnchors(corners: corners, aspect: aspect)
    case .ellipse:
      // Four cubic quarters: the standard circle constant, applied per axis.
      let center = frame.center
      let rx = frame.width / 2
      let ry = frame.height / 2
      let k = VectorShape.circleControl
      return [
        VectorAnchor(
          position: VectorPoint(x: center.x + rx, y: center.y),
          incomingHandle: VectorPoint(x: center.x + rx, y: center.y - ry * k),
          outgoingHandle: VectorPoint(x: center.x + rx, y: center.y + ry * k),
          kind: .smooth),
        VectorAnchor(
          position: VectorPoint(x: center.x, y: center.y + ry),
          incomingHandle: VectorPoint(x: center.x + rx * k, y: center.y + ry),
          outgoingHandle: VectorPoint(x: center.x - rx * k, y: center.y + ry),
          kind: .smooth),
        VectorAnchor(
          position: VectorPoint(x: center.x - rx, y: center.y),
          incomingHandle: VectorPoint(x: center.x - rx, y: center.y + ry * k),
          outgoingHandle: VectorPoint(x: center.x - rx, y: center.y - ry * k),
          kind: .smooth),
        VectorAnchor(
          position: VectorPoint(x: center.x, y: center.y - ry),
          incomingHandle: VectorPoint(x: center.x - rx * k, y: center.y - ry),
          outgoingHandle: VectorPoint(x: center.x + rx * k, y: center.y - ry),
          kind: .smooth),
      ]
    case .polygon(let sides):
      return radialAnchors(count: sides) { _ in 1 }
    case .star(let points, let innerRatio):
      // Alternating outer and inner vertices, so a five-pointed star has ten.
      return radialAnchors(count: points * 2) { index in
        index.isMultiple(of: 2) ? 1 : innerRatio
      }
    }
  }

  /// Vertices on the frame's inscribed ellipse, starting at the top so a
  /// polygon or star points upward at zero rotation.
  private func radialAnchors(
    count: Int, radiusFactor: (Int) -> Double
  ) -> [VectorAnchor] {
    guard count >= 3 else { return [] }
    let center = frame.center
    let rx = frame.width / 2
    let ry = frame.height / 2
    return (0..<count).map { index in
      let angle = Double.pi / 2 + Double(index) * 2 * Double.pi / Double(count)
      let factor = radiusFactor(index)
      return VectorAnchor(
        position: VectorPoint(
          x: center.x + cos(angle) * rx * factor,
          y: center.y + sin(angle) * ry * factor
        ))
    }
  }

  private func rectangleAnchors(
    corners: VectorCornerRadii, aspect: Double
  ) -> [VectorAnchor] {
    let x0 = frame.minX
    let y0 = frame.minY
    let x1 = frame.maxX
    let y1 = frame.maxY
    let radii = resolvedRadii(corners, aspect: aspect)
    guard radii.contains(where: { $0.x > 0 || $0.y > 0 }) else {
      return [
        VectorAnchor(position: VectorPoint(x: x0, y: y0)),
        VectorAnchor(position: VectorPoint(x: x1, y: y0)),
        VectorAnchor(position: VectorPoint(x: x1, y: y1)),
        VectorAnchor(position: VectorPoint(x: x0, y: y1)),
      ]
    }

    // Each rounded corner becomes two anchors — where the straight edges leave
    // and rejoin the arc — with handles pulling a quarter circle between them.
    let k = VectorShape.circleControl
    let corners: [(point: VectorPoint, radius: VectorPoint, inX: Double, inY: Double, outX: Double, outY: Double)] = [
      (VectorPoint(x: x0, y: y0), radii[0], 0, 1, 1, 0),
      (VectorPoint(x: x1, y: y0), radii[1], -1, 0, 0, 1),
      (VectorPoint(x: x1, y: y1), radii[2], 0, -1, -1, 0),
      (VectorPoint(x: x0, y: y1), radii[3], 1, 0, 0, -1),
    ]

    var anchors: [VectorAnchor] = []
    for corner in corners {
      guard corner.radius.x > 0 || corner.radius.y > 0 else {
        anchors.append(VectorAnchor(position: corner.point))
        continue
      }
      let start = VectorPoint(
        x: corner.point.x + corner.inX * corner.radius.x,
        y: corner.point.y + corner.inY * corner.radius.y)
      let end = VectorPoint(
        x: corner.point.x + corner.outX * corner.radius.x,
        y: corner.point.y + corner.outY * corner.radius.y)
      anchors.append(
        VectorAnchor(
          position: start,
          outgoingHandle: start.interpolated(to: corner.point, t: k),
          kind: .corner))
      anchors.append(
        VectorAnchor(
          position: end,
          incomingHandle: end.interpolated(to: corner.point, t: k),
          kind: .corner))
    }
    return anchors
  }

  /// The four radii as normalized offsets, bottom-left first and counter
  /// clockwise.
  ///
  /// A radius is a fraction of the shorter side measured on screen, so it is
  /// resolved in pixel proportions and converted back per axis: that is what
  /// makes a corner read as a quarter circle rather than a quarter ellipse on a
  /// non-square image. Two radii sharing an edge are reduced together so they
  /// can never overlap.
  private func resolvedRadii(
    _ corners: VectorCornerRadii, aspect: Double
  ) -> [VectorPoint] {
    let safeAspect = aspect > 0 ? aspect : 1
    // Work in units of image height, so both axes are comparable.
    let widthInHeightUnits = frame.width * safeAspect
    let heightInHeightUnits = frame.height
    let shorter = min(widthInHeightUnits, heightInHeightUnits)
    guard shorter > 0 else { return Array(repeating: .zero, count: 4) }

    var lengths = [
      corners.bottomLeft * shorter,
      corners.bottomRight * shorter,
      corners.topRight * shorter,
      corners.topLeft * shorter,
    ]
    // Neighbours along each edge: bottom, right, top, left.
    for (first, second, edge) in [
      (0, 1, widthInHeightUnits), (1, 2, heightInHeightUnits),
      (2, 3, widthInHeightUnits), (3, 0, heightInHeightUnits),
    ] {
      let total = lengths[first] + lengths[second]
      guard total > edge, total > 0 else { continue }
      let scale = edge / total
      lengths[first] *= scale
      lengths[second] *= scale
    }
    return lengths.map { VectorPoint(x: $0 / safeAspect, y: $0) }
  }

  private func signum(_ value: Double) -> Double { value >= 0 ? 1 : -1 }

  /// The control-point distance that turns a cubic into a quarter circle.
  static let circleControl = 0.552_284_749_830_793_6
}

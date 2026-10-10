import CoreGraphics
import Foundation

/// An axis-aligned box in the normalized vector coordinate space.
///
/// Object selection, alignment, and transform handles all need to ask where an
/// object is. Keeping the answer in the domain keeps it testable and keeps the
/// canvas and the export path answering the same question the same way.
public struct VectorBounds: Codable, Equatable, Hashable, Sendable {
  public var minX: Double
  public var minY: Double
  public var maxX: Double
  public var maxY: Double

  public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
    let safeMinX = minX.isFinite ? minX : 0
    let safeMinY = minY.isFinite ? minY : 0
    let safeMaxX = maxX.isFinite ? maxX : safeMinX
    let safeMaxY = maxY.isFinite ? maxY : safeMinY
    self.minX = min(safeMinX, safeMaxX)
    self.minY = min(safeMinY, safeMaxY)
    self.maxX = max(safeMinX, safeMaxX)
    self.maxY = max(safeMinY, safeMaxY)
  }

  private enum CodingKeys: String, CodingKey {
    case minX
    case minY
    case maxX
    case maxY
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      minX: try container.decode(Double.self, forKey: .minX),
      minY: try container.decode(Double.self, forKey: .minY),
      maxX: try container.decode(Double.self, forKey: .maxX),
      maxY: try container.decode(Double.self, forKey: .maxY))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(minX, forKey: .minX)
    try container.encode(minY, forKey: .minY)
    try container.encode(maxX, forKey: .maxX)
    try container.encode(maxY, forKey: .maxY)
  }

  public init?(containing points: [VectorPoint]) {
    guard let first = points.first else { return nil }
    var box = VectorBounds(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
    for point in points.dropFirst() {
      box.minX = min(box.minX, point.x)
      box.minY = min(box.minY, point.y)
      box.maxX = max(box.maxX, point.x)
      box.maxY = max(box.maxY, point.y)
    }
    self = box
  }

  public var width: Double { maxX - minX }
  public var height: Double { maxY - minY }
  public var center: VectorPoint {
    VectorPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
  }

  public func contains(_ point: VectorPoint) -> Bool {
    point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
  }

  public func intersects(_ other: VectorBounds) -> Bool {
    minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
  }

  public func union(_ other: VectorBounds) -> VectorBounds {
    VectorBounds(
      minX: min(minX, other.minX),
      minY: min(minY, other.minY),
      maxX: max(maxX, other.maxX),
      maxY: max(maxY, other.maxY)
    )
  }
}

/// A 2×3 affine transform over normalized vector coordinates.
///
/// Object transforms are applied to stored geometry rather than kept beside it,
/// so a moved or scaled object still round-trips through the recipe as ordinary
/// anchors. The affine arithmetic stays explicit here; Core Graphics is used
/// only to materialize painted stroke regions later in this file.
public struct VectorAffineTransform: Equatable, Sendable {
  public var a: Double
  public var b: Double
  public var c: Double
  public var d: Double
  public var tx: Double
  public var ty: Double

  public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
    self.a = a
    self.b = b
    self.c = c
    self.d = d
    self.tx = tx
    self.ty = ty
  }

  public static let identity = VectorAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

  public static func translation(x: Double, y: Double) -> VectorAffineTransform {
    VectorAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
  }

  public static func scale(
    x: Double, y: Double, about origin: VectorPoint = .zero
  ) -> VectorAffineTransform {
    VectorAffineTransform(
      a: x,
      b: 0,
      c: 0,
      d: y,
      tx: origin.x - origin.x * x,
      ty: origin.y - origin.y * y
    )
  }

  /// A rotation that reads as a rotation on screen.
  ///
  /// Vector coordinates are normalized to the image extent, so a plain rotation
  /// matrix would shear whenever the image is not square. `aspect` is the
  /// image's width divided by its height; the rotation is conjugated by that
  /// scaling so the result is a true rotation in pixels.
  public static func rotation(
    radians: Double, about origin: VectorPoint = .zero, aspect: Double = 1
  ) -> VectorAffineTransform {
    let safeAspect = aspect > 0 ? aspect : 1
    let cosine = cos(radians)
    let sine = sin(radians)
    // In pixels the rotation is the usual matrix. Converting back to normalized
    // coordinates divides x by the width and y by the height, which is where
    // the aspect factors come from.
    let linear = VectorAffineTransform(
      a: cosine,
      b: sine * safeAspect,
      c: -sine / safeAspect,
      d: cosine,
      tx: 0,
      ty: 0
    )
    return VectorAffineTransform.translation(x: -origin.x, y: -origin.y)
      .concatenating(linear)
      .concatenating(.translation(x: origin.x, y: origin.y))
  }

  /// Mirrors across the vertical or horizontal line through `origin`.
  public static func reflection(
    horizontally: Bool, about origin: VectorPoint
  ) -> VectorAffineTransform {
    horizontally
      ? .scale(x: -1, y: 1, about: origin)
      : .scale(x: 1, y: -1, about: origin)
  }

  /// `self` followed by `other`.
  public func concatenating(_ other: VectorAffineTransform) -> VectorAffineTransform {
    VectorAffineTransform(
      a: a * other.a + b * other.c,
      b: a * other.b + b * other.d,
      c: c * other.a + d * other.c,
      d: c * other.b + d * other.d,
      tx: tx * other.a + ty * other.c + other.tx,
      ty: tx * other.b + ty * other.d + other.ty
    )
  }

  public func apply(to point: VectorPoint) -> VectorPoint {
    VectorPoint(x: a * point.x + c * point.y + tx, y: b * point.x + d * point.y + ty)
  }

  /// The transform's linear part as it acts in pixels, decomposed into the
  /// rotation, scale, and shear a parametric shape would have to express.
  ///
  /// Normalized coordinates are anisotropic, so the decomposition is done after
  /// conjugating into pixel proportions: otherwise a plain rotation would look
  /// like a shear and a shape would be converted to a path for no reason.
  public func pixelDecomposition(
    aspect: Double
  ) -> (rotationDegrees: Double, scaleX: Double, scaleY: Double, shear: Double) {
    let safeAspect = aspect > 0 ? aspect : 1
    let m00 = a
    let m01 = c * safeAspect
    let m10 = b / safeAspect
    let m11 = d

    let scaleX = (m00 * m00 + m10 * m10).squareRoot()
    guard scaleX > 0 else { return (0, 0, 0, 0) }
    let rotation = atan2(m10, m00)
    let shear = (m00 * m01 + m10 * m11) / (scaleX * scaleX)
    let determinant = m00 * m11 - m01 * m10
    let scaleY = determinant / scaleX
    return (rotation * 180 / .pi, scaleX, scaleY, shear)
  }

  /// How much the transform grows a length, averaged over direction.
  ///
  /// Stroke width is a single scalar, so a non-uniform scale has no exact
  /// answer. The square root of the determinant keeps area consistent, which
  /// matches what a user expects when scaling a stroked object.
  public var uniformScale: Double {
    let determinant = abs(a * d - b * c)
    return determinant > 0 ? determinant.squareRoot() : 1
  }

  public var isIdentity: Bool { self == .identity }
}

extension VectorPath {
  /// The path as one polyline in normalized coordinates, closing back onto the
  /// first anchor when the path is closed.
  ///
  /// Sixteen samples per curve keeps hit testing and bounds well inside a pixel
  /// at ordinary zoom without making selection allocate heavily during a drag.
  public func flattened(segmentsPerCurve: Int = 16) -> [VectorPoint] {
    guard anchors.count >= 2 else { return anchors.map(\.position) }
    let steps = max(segmentsPerCurve, 1)
    var points: [VectorPoint] = [anchors[0].position]
    let lastSegment = isClosed ? anchors.count - 1 : anchors.count - 2
    guard lastSegment >= 0 else { return points }
    for index in 0...lastSegment {
      guard let cubic = segment(startingAt: index) else { continue }
      let isStraight = cubic.control1 == cubic.start && cubic.control2 == cubic.end
      if isStraight {
        points.append(cubic.end)
      } else {
        for step in 1...steps {
          points.append(cubic.point(at: Double(step) / Double(steps)))
        }
      }
    }
    return points
  }

  /// The geometric extent, ignoring the stroke.
  public var boundingBox: VectorBounds? {
    VectorBounds(containing: flattened())
  }

  /// The extent the object and its complete stroke occupy.
  public func renderedBoundingBox(pixelWidth: Double, pixelHeight: Double) -> VectorBounds? {
    VectorObject.path(self).boundingBox(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
  }

  /// Whether a click at `point` lands on this object.
  ///
  /// A filled closed path is hit anywhere inside it; every path is also hit
  /// near its outline, so an unfilled or open path stays selectable. `tolerance`
  /// is in canonical image pixels so the target keeps a constant screen size
  /// once the caller converts its own hit radius.
  public func hitTest(
    _ point: VectorPoint,
    pixelWidth: Double,
    pixelHeight: Double,
    tolerance: Double
  ) -> Bool {
    VectorObject.path(self).hitTest(
      point, pixelWidth: pixelWidth, pixelHeight: pixelHeight, tolerance: tolerance)
  }

  /// Non-zero winding containment against the flattened contour.
  public func contains(_ point: VectorPoint) -> Bool {
    windingNumber(at: point) != 0
  }

  /// How many times this contour wraps around a point, signed by direction.
  ///
  /// Summed across a compound's contours this is the non-zero fill rule; on its
  /// own it is what `contains` asks. A reversed contour contributes the
  /// opposite sign, which is how a hole cancels the shape around it.
  public func windingNumber(at point: VectorPoint) -> Int {
    let outline = flattened()
    guard outline.count >= 3 else { return 0 }
    var winding = 0
    for index in outline.indices {
      let start = outline[index]
      let end = outline[(index + 1) % outline.count]
      if start.y <= point.y {
        if end.y > point.y, cross(start, end, point) > 0 { winding += 1 }
      } else if end.y <= point.y, cross(start, end, point) < 0 {
        winding -= 1
      }
    }
    return winding
  }

  /// How many times a ray from the point crosses this contour, whatever the
  /// direction. Summed across contours and taken odd or even, this is the
  /// even-odd fill rule.
  public func crossingCount(at point: VectorPoint) -> Int {
    let outline = flattened()
    guard outline.count >= 3 else { return 0 }
    var crossings = 0
    for index in outline.indices {
      let start = outline[index]
      let end = outline[(index + 1) % outline.count]
      guard (start.y > point.y) != (end.y > point.y) else { continue }
      let t = (point.y - start.y) / (end.y - start.y)
      if start.x + t * (end.x - start.x) > point.x { crossings += 1 }
    }
    return crossings
  }

  /// The distance from `point` to the outline, in canonical image pixels.
  public func outlineDistanceInPixels(
    to point: VectorPoint, pixelWidth: Double, pixelHeight: Double
  ) -> Double {
    let outline = flattened()
    guard outline.count >= 2 else { return .infinity }
    return outlineDistance(
      to: point, outline: outline, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
  }

  /// Moves and reshapes geometry, fill coordinates, and the stroke together.
  ///
  /// The stroke width follows the transform's uniform scale so a scaled object
  /// keeps its proportions rather than growing a hairline outline.
  public func transformed(
    by transform: VectorAffineTransform, aspect: Double = 1
  ) -> VectorPath {
    guard !transform.isIdentity else { return self }
    var copy = self
    copy.anchors = anchors.map { anchor in
      var moved = anchor
      moved.position = transform.apply(to: anchor.position)
      moved.incomingHandle = anchor.incomingHandle.map(transform.apply(to:))
      moved.outgoingHandle = anchor.outgoingHandle.map(transform.apply(to:))
      return moved
    }
    if var stroke = copy.stroke {
      stroke.width = max(stroke.width * transform.uniformScale, 0)
      copy.stroke = stroke
    }
    // Gradient coordinates are stored, not derived, so they have to be carried
    // by the same transform or the fill would slide off the shape.
    copy.fill = fill?.transformed(by: transform, aspect: aspect)
    return copy
  }

  private func cross(_ a: VectorPoint, _ b: VectorPoint, _ point: VectorPoint) -> Double {
    (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
  }

  private func outlineDistance(
    to point: VectorPoint, outline: [VectorPoint], pixelWidth: Double, pixelHeight: Double
  ) -> Double {
    var best = Double.infinity
    let upperBound = isClosed ? outline.count : outline.count - 1
    for index in 0..<max(upperBound, 0) {
      let start = outline[index]
      let end = outline[(index + 1) % outline.count]
      best = min(
        best,
        pixelDistanceToSegment(
          point, start, end, pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }
    return best
  }

  private func pixelDistanceToSegment(
    _ point: VectorPoint,
    _ start: VectorPoint,
    _ end: VectorPoint,
    pixelWidth: Double,
    pixelHeight: Double
  ) -> Double {
    let px = point.x * pixelWidth
    let py = point.y * pixelHeight
    let ax = start.x * pixelWidth
    let ay = start.y * pixelHeight
    let bx = end.x * pixelWidth
    let by = end.y * pixelHeight
    let dx = bx - ax
    let dy = by - ay
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(px - ax, py - ay) }
    let t = min(max(((px - ax) * dx + (py - ay) * dy) / lengthSquared, 0), 1)
    return hypot(px - (ax + dx * t), py - (ay + dy * t))
  }
}

extension VectorObject {
  /// The Bezier geometry this object draws as, one entry per contour.
  ///
  /// A path and a shape have exactly one; a compound path has as many as it
  /// holds. Renderers, hit testing, and export read this, so none of them has
  /// to know which case they are looking at.
  public func resolvedContours(aspect: Double = 1) -> [VectorPath] {
    switch self {
    case .path(let path): [path]
    case .shape(let shape): [shape.resolvedPath(aspect: aspect)]
    case .compound(let compound): compound.paths
    }
  }

  /// How this object's contours decide what is inside its fill.
  public var fillRule: VectorFillRule {
    switch self {
    case .path, .shape: .nonZero
    case .compound(let compound): compound.fillRule
    }
  }

  /// The rendered extent, including the actual stroked outline and arrowheads.
  ///
  /// The aspect a shape needs to resolve its rotation comes from the pixel
  /// dimensions the caller already supplies, so hit testing and bounds see an
  /// object exactly as the renderer draws it.
  public func boundingBox(pixelWidth: Double, pixelHeight: Double) -> VectorBounds? {
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    let contours = resolvedContours(aspect: aspect(pixelWidth, pixelHeight))
    guard !contours.isEmpty else { return nil }
    let geometry = vectorCGPath(
      contours: contours, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    var result = vectorBounds(
      geometry.boundingBoxOfPath, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      ?? VectorBounds(containing: contours.flatMap { $0.flattened() })
    if let paintedStroke = paintedStrokePath(
      contours: contours,
      stroke: stroke,
      objectIsClosed: isClosed,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight),
      let strokeBounds = vectorBounds(
        paintedStroke.boundingBoxOfPath, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    {
      result = result?.union(strokeBounds) ?? strokeBounds
    }
    return result
  }

  /// Whether a click lands on this object.
  ///
  /// A filled object is hit wherever its fill rule says it is inside, so a hole
  /// in a compound path is a hole to the pointer as well as to the eye. Every
  /// object is also hit near its outline, so an unfilled or open one stays
  /// selectable.
  public func hitTest(
    _ point: VectorPoint, pixelWidth: Double, pixelHeight: Double, tolerance: Double
  ) -> Bool {
    guard pixelWidth > 0, pixelHeight > 0 else { return false }
    let contours = resolvedContours(aspect: aspect(pixelWidth, pixelHeight))
    guard !contours.isEmpty else { return false }

    if isClosed, fill != nil,
      fillRule.contains(point, contours: contours.filter(\.isClosed))
    {
      return true
    }

    let pixelPoint = CGPoint(x: point.x * pixelWidth, y: point.y * pixelHeight)
    if let paintedStroke = paintedStrokePath(
      contours: contours,
      stroke: stroke,
      objectIsClosed: isClosed,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight)
    {
      if paintedStroke.contains(pixelPoint, using: .winding) { return true }
      let expansion = max(tolerance, 0) * 2
      guard expansion > 0 else { return false }
      let nearby = paintedStroke.copy(
        strokingWithWidth: expansion,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 1)
      return nearby.contains(pixelPoint, using: .winding)
    }

    // An object without a visible stroke remains selectable near its authored
    // outline. This is editing tolerance, not painted extent.
    let expansion = max(tolerance, 0) * 2
    guard expansion > 0 else { return false }
    let geometry = vectorCGPath(
      contours: contours, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    let nearby = geometry.copy(
      strokingWithWidth: expansion,
      lineCap: .round,
      lineJoin: .round,
      miterLimit: 1)
    return nearby.contains(pixelPoint, using: .winding)
  }

  /// Moves and reshapes the object.
  ///
  /// A path and a compound are transformed contour by contour. A shape keeps
  /// its parameters where the transform is one it can express — a move, a
  /// scale, a rotation, or a reflection — and becomes an ordinary path only
  /// when the transform shears it, which no shape parameter can describe.
  public func transformed(
    by transform: VectorAffineTransform, aspect: Double = 1
  ) -> VectorObject {
    switch self {
    case .path(let path): .path(path.transformed(by: transform, aspect: aspect))
    case .compound(let compound):
      .compound(compound.transformed(by: transform, aspect: aspect))
    case .shape(let shape):
      shape.transformed(by: transform, aspect: aspect)
        .map(VectorObject.shape)
        ?? .path(
          shape.resolvedPath(aspect: aspect).transformed(by: transform, aspect: aspect))
    }
  }

  private func aspect(_ pixelWidth: Double, _ pixelHeight: Double) -> Double {
    pixelHeight > 0 ? pixelWidth / pixelHeight : 1
  }
}

// MARK: - Painted stroke geometry

/// The same Bezier geometry the renderer sends to Core Graphics, expressed in
/// canonical image pixels so stroke widths need no coordinate conversion.
private func vectorCGPath(
  contours: [VectorPath], pixelWidth: Double, pixelHeight: Double
) -> CGPath {
  let combined = CGMutablePath()
  for contour in contours where contour.anchors.count >= 2 {
    let path = CGMutablePath()
    let first = contour.anchors[0]
    path.move(to: pixelPoint(first.position, width: pixelWidth, height: pixelHeight))
    let segmentCount = contour.isClosed ? contour.anchors.count : contour.anchors.count - 1
    for index in 0..<segmentCount {
      let start = contour.anchors[index]
      let end = contour.anchors[(index + 1) % contour.anchors.count]
      let startPoint = pixelPoint(start.position, width: pixelWidth, height: pixelHeight)
      let endPoint = pixelPoint(end.position, width: pixelWidth, height: pixelHeight)
      let control1 = pixelPoint(
        start.outgoingHandle ?? start.position, width: pixelWidth, height: pixelHeight)
      let control2 = pixelPoint(
        end.incomingHandle ?? end.position, width: pixelWidth, height: pixelHeight)
      if control1 == startPoint, control2 == endPoint {
        path.addLine(to: endPoint)
      } else {
        path.addCurve(to: endPoint, control1: control1, control2: control2)
      }
    }
    if contour.isClosed { path.closeSubpath() }
    combined.addPath(path)
  }
  return combined
}

private func paintedStrokePath(
  contours: [VectorPath],
  stroke: VectorStrokeStyle?,
  objectIsClosed: Bool,
  pixelWidth: Double,
  pixelHeight: Double
) -> CGPath? {
  guard let stroke, stroke.isVisible else { return nil }
  let geometry = vectorCGPath(
    contours: contours, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
  let source: CGPath
  if let dashes = stroke.usableDashPattern {
    source = geometry.copy(
      dashingWithPhase: stroke.dashPhase,
      lengths: dashes.map { CGFloat($0) })
  } else {
    source = geometry
  }

  let alignment = objectIsClosed ? stroke.alignment : .center
  let lineWidth = alignment == .center ? stroke.width : stroke.width * 2
  var painted = source.copy(
    strokingWithWidth: lineWidth,
    lineCap: cgLineCap(stroke.lineCap),
    lineJoin: cgLineJoin(stroke.lineJoin),
    miterLimit: stroke.miterLimit)
  if alignment != .center {
    let outline = geometry.normalized(using: .evenOdd)
    let normalizedStroke = painted.normalized(using: .winding)
    painted = alignment == .inside
      ? normalizedStroke.intersection(outline, using: .winding)
      : normalizedStroke.subtracting(outline, using: .winding)
  }

  for contour in contours where !contour.isClosed {
    for arrow in arrowheadPaths(
      stroke: stroke,
      contour: contour,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight)
    {
      painted = painted.union(arrow.normalized(using: .winding), using: .winding)
    }
  }
  return painted
}

private func arrowheadPaths(
  stroke: VectorStrokeStyle,
  contour: VectorPath,
  pixelWidth: Double,
  pixelHeight: Double
) -> [CGPath] {
  let outline = contour.flattened().map {
    pixelPoint($0, width: pixelWidth, height: pixelHeight)
  }
  guard outline.count >= 2 else { return [] }
  var paths: [CGPath] = []
  if let head = stroke.startArrowhead,
    let path = arrowheadPath(
      head,
      tip: outline[0],
      previous: outline[1],
      stroke: stroke)
  {
    paths.append(path)
  }
  if let head = stroke.endArrowhead,
    let path = arrowheadPath(
      head,
      tip: outline[outline.count - 1],
      previous: outline[outline.count - 2],
      stroke: stroke)
  {
    paths.append(path)
  }
  return paths
}

private func arrowheadPath(
  _ head: VectorArrowhead,
  tip: CGPoint,
  previous: CGPoint,
  stroke: VectorStrokeStyle
) -> CGPath? {
  let dx = tip.x - previous.x
  let dy = tip.y - previous.y
  let length = hypot(dx, dy)
  guard length > 0 else { return nil }
  let ux = dx / length
  let uy = dy / length
  let size = stroke.width * head.scale
  let half = size / 2
  let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
  let left = CGPoint(x: base.x - uy * half, y: base.y + ux * half)
  let right = CGPoint(x: base.x + uy * half, y: base.y - ux * half)
  let shape = CGMutablePath()

  switch head.style {
  case .triangle:
    shape.move(to: tip)
    shape.addLine(to: left)
    shape.addLine(to: right)
    shape.closeSubpath()
    return shape
  case .openTriangle:
    shape.move(to: left)
    shape.addLine(to: tip)
    shape.addLine(to: right)
    return shape.copy(
      strokingWithWidth: stroke.width,
      lineCap: cgLineCap(stroke.lineCap),
      lineJoin: cgLineJoin(stroke.lineJoin),
      miterLimit: stroke.miterLimit)
  case .circle:
    return CGPath(
      ellipseIn: CGRect(
        x: tip.x - half, y: tip.y - half, width: size, height: size),
      transform: nil)
  case .square:
    shape.move(
      to: CGPoint(x: tip.x - ux * half - uy * half, y: tip.y - uy * half + ux * half))
    shape.addLine(
      to: CGPoint(x: tip.x + ux * half - uy * half, y: tip.y + uy * half + ux * half))
    shape.addLine(
      to: CGPoint(x: tip.x + ux * half + uy * half, y: tip.y + uy * half - ux * half))
    shape.addLine(
      to: CGPoint(x: tip.x - ux * half + uy * half, y: tip.y - uy * half - ux * half))
    shape.closeSubpath()
    return shape
  case .bar:
    shape.move(to: CGPoint(x: tip.x - uy * half, y: tip.y + ux * half))
    shape.addLine(to: CGPoint(x: tip.x + uy * half, y: tip.y - ux * half))
    return shape.copy(
      strokingWithWidth: stroke.width,
      lineCap: cgLineCap(stroke.lineCap),
      lineJoin: cgLineJoin(stroke.lineJoin),
      miterLimit: stroke.miterLimit)
  }
}

private func pixelPoint(_ point: VectorPoint, width: Double, height: Double) -> CGPoint {
  CGPoint(x: point.x * width, y: point.y * height)
}

private func vectorBounds(
  _ rect: CGRect, pixelWidth: Double, pixelHeight: Double
) -> VectorBounds? {
  guard !rect.isNull, !rect.isInfinite, pixelWidth > 0, pixelHeight > 0 else { return nil }
  return VectorBounds(
    minX: rect.minX / pixelWidth,
    minY: rect.minY / pixelHeight,
    maxX: rect.maxX / pixelWidth,
    maxY: rect.maxY / pixelHeight)
}

private func cgLineCap(_ cap: VectorLineCap) -> CGLineCap {
  switch cap {
  case .butt: .butt
  case .round: .round
  case .square: .square
  }
}

private func cgLineJoin(_ join: VectorLineJoin) -> CGLineJoin {
  switch join {
  case .miter: .miter
  case .round: .round
  case .bevel: .bevel
  }
}

extension LayerTransform {
  /// The same affine map, expressed over normalized vector coordinates.
  ///
  /// Free Transform is authored in canvas pixels, while vector geometry is
  /// normalized to the canvas extent. Converting the map rather than adding a
  /// separate vector transform tool is what lets objects be moved, scaled,
  /// rotated, and reflected by the tool users already know, and keeps the
  /// result exact vector geometry rather than a resampled layer.
  ///
  /// Only the affine stage converts: perspective and warp are evaluated by the
  /// renderer and have no closed form here, so they return nil rather than a
  /// wrong answer.
  public func vectorTransform(
    canvasWidth: Double, canvasHeight: Double
  ) -> VectorAffineTransform? {
    guard isAffine, isValid, canvasWidth > 0, canvasHeight > 0 else { return nil }
    let radians = rotationDegrees * .pi / 180
    let cosine = cos(radians)
    let sine = sin(radians)
    // The pixel-space linear part: shear and scale, then rotation.
    let m00 = cosine * scaleX
    let m01 = cosine * shearX * scaleY - sine * scaleY
    let m10 = sine * scaleX
    let m11 = sine * shearX * scaleY + cosine * scaleY
    return VectorAffineTransform(
      a: m00,
      b: m10 * canvasWidth / canvasHeight,
      c: m01 * canvasHeight / canvasWidth,
      d: m11,
      tx: (position.x - m00 * anchor.x - m01 * anchor.y) / canvasWidth,
      ty: (position.y - m10 * anchor.x - m11 * anchor.y) / canvasHeight
    )
  }
}

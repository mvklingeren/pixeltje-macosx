import CoreGraphics
import Foundation
import PixeltjeMacDomain

/// The Boolean operations two or more vector objects can be combined by.
public enum VectorBooleanOperation: String, CaseIterable, Sendable {
  case union
  case subtract
  case intersect
  case exclude

  public var label: String {
    switch self {
    case .union: "Union"
    case .subtract: "Subtract"
    case .intersect: "Intersect"
    case .exclude: "Exclude Overlap"
    }
  }

  public var symbolName: String {
    switch self {
    case .union: "square.on.square.dashed"
    case .subtract: "square.on.square.intersection.dashed"
    case .intersect: "square.filled.on.square"
    case .exclude: "square.on.square.squareshape.controlhandles"
    }
  }

  public var help: String {
    switch self {
    case .union: "Merges the selected objects into one outline."
    case .subtract: "Removes the objects above from the bottom-most one."
    case .intersect: "Keeps only what every selected object covers."
    case .exclude: "Keeps what an odd number of the objects cover."
    }
  }
}

/// Boolean geometry for vector objects.
///
/// Core Graphics' own path operations do the work: they are exact on curves,
/// so a union of two circles stays circular instead of becoming a polygon, and
/// there is no clipper of our own to get wrong. The engine's job is converting
/// between the recipe's normalized anchors and `CGPath`, and back again.
///
/// The first implementation is deliberately destructive: it produces an
/// editable compound path in one undoable step, rather than a live group that
/// would need its own editing model.
public enum VectorBooleanEngine {
  /// Where the geometry is evaluated.
  ///
  /// Normalized coordinates run zero to one, which leaves Core Graphics
  /// resolving intersections at a scale where its tolerance is coarse relative
  /// to the artwork. The work is done in a canvas-sized space and mapped back,
  /// so the result is as precise as the image it is drawn on.
  private static let workingWidth = 4_096.0

  /// Combines objects, bottom to top, into one compound path.
  ///
  /// Returns nil when fewer than two objects would take part, or when the
  /// operation leaves nothing behind — subtracting a shape from itself, say,
  /// which should report that there is nothing to do rather than quietly
  /// deleting the artwork.
  public static func combine(
    _ objects: [VectorObject],
    operation: VectorBooleanOperation,
    aspect: Double
  ) -> VectorCompoundPath? {
    guard objects.count >= 2 else { return nil }
    let ordered = objects.sorted { $0.zOrder < $1.zOrder }
    let scale = workingScale(aspect: aspect)
    let paths = ordered.map { object in
      cgPath(for: object, aspect: aspect, scale: scale)
        .normalized(using: object.fillRule == .evenOdd ? .evenOdd : .winding)
    }
    guard let first = paths.first else { return nil }

    // Each operand has already been normalized according to its own authored
    // fill rule. The resulting contours are unambiguous winding geometry, so
    // no operand can accidentally impose its rule on the others.
    let rule = CGPathFillRule.winding
    var result = first
    switch operation {
    case .union:
      for path in paths.dropFirst() { result = result.union(path, using: rule) }
    case .subtract:
      // The bottom-most object is the base; everything above is removed from
      // it, which is what dragging a shape over another to cut it looks like.
      for path in paths.dropFirst() { result = result.subtracting(path, using: rule) }
    case .intersect:
      for path in paths.dropFirst() { result = result.intersection(path, using: rule) }
    case .exclude:
      for path in paths.dropFirst() {
        result = result.symmetricDifference(path, using: rule)
      }
    }

    let contours = contours(from: result, scale: scale)
    guard !contours.isEmpty else { return nil }

    // The base object's appearance survives, so the result looks like the thing
    // that was being cut rather than the tool that cut it.
    let base = ordered[0]
    return VectorCompoundPath(
      name: base.name,
      zOrder: base.zOrder,
      contours: contours,
      // Core Graphics returns non-overlapping, correctly wound contours, so
      // non-zero is the rule that reproduces what it computed.
      fillRule: .nonZero,
      stroke: base.stroke,
      fill: base.fill
    )
  }

  /// The scale normalized coordinates are multiplied by while the geometry is
  /// evaluated. Both axes are scaled to keep the working space proportional to
  /// the image, so a curve is not distorted before it is intersected.
  private static func workingScale(aspect: Double) -> CGPoint {
    let safeAspect = aspect > 0 ? aspect : 1
    return CGPoint(x: workingWidth, y: workingWidth / safeAspect)
  }

  private static func cgPath(
    for object: VectorObject, aspect: Double, scale: CGPoint
  ) -> CGPath {
    let combined = CGMutablePath()
    for contour in object.resolvedContours(aspect: aspect) {
      // An open contour has no interior to combine, so it is closed for the
      // purpose of the operation. That is what every editor does, and it is
      // the only reading under which the result is an area at all.
      var closed = contour
      closed.isClosed = true
      combined.addPath(
        VectorArtworkRenderer.makePath(closed) { point in
          CGPoint(x: point.x * scale.x, y: point.y * scale.y)
        })
    }
    return combined
  }

  /// Reads a `CGPath` back into anchors.
  ///
  /// Core Graphics reports the result as move, line, curve, and close elements;
  /// each move starts a contour, and a curve's control points become the
  /// handles of the anchors on either side of it.
  static func contours(from path: CGPath, scale: CGPoint) -> [VectorContour] {
    var contours: [VectorContour] = []
    var anchors: [VectorAnchor] = []
    var isClosed = false

    func point(_ value: CGPoint) -> VectorPoint {
      VectorPoint(
        x: scale.x > 0 ? Double(value.x) / scale.x : 0,
        y: scale.y > 0 ? Double(value.y) / scale.y : 0)
    }

    func finish() {
      defer {
        anchors = []
        isClosed = false
      }
      guard anchors.count >= 2 else { return }
      var finished = anchors
      // Core Graphics usually returns to the start before closing. That last
      // anchor is the first one again, so it is folded back in rather than left
      // as a zero-length segment.
      if isClosed, let first = finished.first, let last = finished.last,
        first.position.distance(to: last.position) < 1e-9
      {
        finished.removeLast()
        finished[0].incomingHandle = last.incomingHandle
      }
      guard finished.count >= 2 else { return }
      contours.append(VectorContour(anchors: finished, isClosed: isClosed))
    }

    path.applyWithBlock { element in
      let points = element.pointee.points
      switch element.pointee.type {
      case .moveToPoint:
        finish()
        anchors = [VectorAnchor(position: point(points[0]))]
      case .addLineToPoint:
        anchors.append(VectorAnchor(position: point(points[0])))
      case .addQuadCurveToPoint:
        // A quadratic raised to a cubic: both controls sit two thirds of the
        // way from their endpoint towards the quadratic's single control.
        guard let start = anchors.last?.position else { break }
        let control = point(points[0])
        let end = point(points[1])
        anchors[anchors.count - 1].outgoingHandle = start.interpolated(to: control, t: 2.0 / 3)
        anchors.append(
          VectorAnchor(
            position: end,
            incomingHandle: end.interpolated(to: control, t: 2.0 / 3),
            kind: .smooth))
      case .addCurveToPoint:
        guard !anchors.isEmpty else { break }
        anchors[anchors.count - 1].outgoingHandle = point(points[0])
        anchors.append(
          VectorAnchor(
            position: point(points[2]),
            incomingHandle: point(points[1]),
            kind: .smooth))
      case .closeSubpath:
        isClosed = true
      @unknown default:
        break
      }
    }
    finish()
    return contours
  }
}

extension VectorLayer {
  /// Replaces the named objects with one compound path holding the Boolean
  /// result.
  ///
  /// The result takes the bottom-most object's place in the draw order, so a
  /// combined shape stays where the artwork it came from was.
  public func combining(
    ids: Set<UUID>, operation: VectorBooleanOperation, aspect: Double
  ) -> VectorLayer? {
    let operands = objectsInDrawOrder.filter { ids.contains($0.id) }
    guard operands.count >= 2,
      let combined = VectorBooleanEngine.combine(
        operands, operation: operation, aspect: aspect)
    else { return nil }

    var copy = self
    copy.objects.removeAll { ids.contains($0.id) }
    copy.objects.append(.compound(combined))
    // The result sits where the base object was, which keeps a cut shape from
    // jumping to the front of the layer.
    var order = copy.objectIDsInDrawOrder.filter { $0 != combined.id }
    let index = objectIDsInDrawOrder.firstIndex(of: operands[0].id) ?? order.count
    order.insert(combined.id, at: min(index, order.count))
    return copy.applying(order: order)
  }

  /// Splits the named compound paths back into ordinary paths.
  public func releasingCompoundPaths(ids: Set<UUID>) -> (layer: VectorLayer, newIDs: [UUID])? {
    let compounds = objectsInDrawOrder.filter { ids.contains($0.id) && $0.compound != nil }
    guard !compounds.isEmpty else { return nil }

    var expanded: [VectorObject] = []
    var released: [UUID] = []
    for object in objectsInDrawOrder {
      guard ids.contains(object.id), let compound = object.compound else {
        expanded.append(object)
        continue
      }
      let paths = compound.released()
      expanded.append(contentsOf: paths.map(VectorObject.path))
      released.append(contentsOf: paths.map(\.id))
    }
    let order = expanded.map(\.id)
    return (VectorLayer(objects: expanded).applying(order: order), released)
  }
}

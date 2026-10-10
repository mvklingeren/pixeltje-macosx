import Foundation

/// How overlapping contours decide what is inside a fill.
public enum VectorFillRule: String, Codable, CaseIterable, Sendable {
  /// A point is inside when the contours' winding numbers do not cancel. The
  /// usual rule, and the one Boolean results are produced in.
  case nonZero
  /// A point is inside when it is crossed an odd number of times, which is how
  /// a self-intersecting outline gets holes without reversing anything.
  case evenOdd

  public var label: String {
    switch self {
    case .nonZero: "Non-Zero"
    case .evenOdd: "Even-Odd"
    }
  }
}

/// One closed or open outline inside a compound path.
///
/// A contour is geometry and nothing else: the compound owns the stroke, the
/// fill, the name, and the ordering, so a hole cannot carry an appearance that
/// disagrees with the shape it is a hole in.
public struct VectorContour: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var anchors: [VectorAnchor]
  public var isClosed: Bool

  public init(id: UUID = UUID(), anchors: [VectorAnchor] = [], isClosed: Bool = true) {
    self.id = id
    self.anchors = anchors
    self.isClosed = isClosed
  }

  public init(_ path: VectorPath) {
    self.init(id: path.id, anchors: path.anchors, isClosed: path.isClosed)
  }

  /// The contour as a path, so the existing segment, flattening, and transform
  /// code serves compounds without being duplicated.
  ///
  /// The appearance is deliberately empty: it belongs to the compound.
  public var asPath: VectorPath {
    VectorPath(id: id, anchors: anchors, isClosed: isClosed, stroke: nil, fill: nil)
  }

  public func transformed(by transform: VectorAffineTransform) -> VectorContour {
    VectorContour(asPath.transformed(by: transform))
  }
}

/// Several contours drawn and filled as one object.
///
/// This is what holes need: a letter O is one object with an outer and an inner
/// contour, and no arrangement of single-contour paths gives the same result.
/// It is also what a Boolean operation produces, since a union or a subtraction
/// can leave any number of pieces and holes behind.
public struct VectorCompoundPath: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var zOrder: Int
  public var contours: [VectorContour]
  public var fillRule: VectorFillRule
  public var stroke: VectorStrokeStyle?
  public var fill: VectorFillStyle?

  public init(
    id: UUID = UUID(),
    name: String = "Compound Path",
    zOrder: Int = 0,
    contours: [VectorContour] = [],
    fillRule: VectorFillRule = .nonZero,
    stroke: VectorStrokeStyle? = nil,
    fill: VectorFillStyle? = nil
  ) {
    self.id = id
    self.name = name
    self.zOrder = zOrder
    self.contours = contours
    self.fillRule = fillRule
    self.stroke = stroke
    self.fill = fill
  }

  /// Whether anything encloses an area. A compound of only open contours is
  /// stroked but never filled.
  public var isClosed: Bool { contours.contains { $0.isClosed } }

  public var paths: [VectorPath] { contours.map(\.asPath) }

  public func transformed(
    by transform: VectorAffineTransform, aspect: Double = 1
  ) -> VectorCompoundPath {
    guard !transform.isIdentity else { return self }
    var copy = self
    copy.contours = contours.map { $0.transformed(by: transform) }
    if var stroke = copy.stroke {
      stroke.width = max(stroke.width * transform.uniformScale, 0)
      copy.stroke = stroke
    }
    copy.fill = fill?.transformed(by: transform, aspect: aspect)
    return copy
  }

  /// Splits the compound back into one object per contour, each keeping the
  /// compound's appearance.
  ///
  /// Release is the way out: a compound that turned out to be the wrong answer
  /// becomes ordinary paths again rather than something that has to be redrawn.
  public func released() -> [VectorPath] {
    contours.enumerated().map { index, contour in
      var path = contour.asPath
      path.id = contour.id
      path.name = contours.count == 1 ? name : "\(name) \(index + 1)"
      path.zOrder = zOrder + index
      path.stroke = stroke
      path.fill = fill
      return path
    }
  }
}

extension VectorFillRule {
  /// Whether a point is inside a set of contours under this rule.
  public func contains(
    _ point: VectorPoint, contours: [VectorPath]
  ) -> Bool {
    switch self {
    case .nonZero:
      return contours.reduce(0) { $0 + $1.windingNumber(at: point) } != 0
    case .evenOdd:
      return contours.reduce(0) { $0 + $1.crossingCount(at: point) } % 2 != 0
    }
  }
}

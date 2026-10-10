import Foundation

/// A point in the document's canonical, bottom-left-origin pixel space.
public struct PixelPoint: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// The four destination offsets of a perspective stage, expressed as fractions
/// of the transform's stable reference rectangle.
public struct PerspectiveCorners: Codable, Equatable, Sendable {
  public var bottomLeft: PixelPoint
  public var bottomRight: PixelPoint
  public var topRight: PixelPoint
  public var topLeft: PixelPoint

  public init(
    bottomLeft: PixelPoint = .init(x: 0, y: 0),
    bottomRight: PixelPoint = .init(x: 0, y: 0),
    topRight: PixelPoint = .init(x: 0, y: 0),
    topLeft: PixelPoint = .init(x: 0, y: 0)
  ) {
    self.bottomLeft = bottomLeft
    self.bottomRight = bottomRight
    self.topRight = topRight
    self.topLeft = topLeft
  }

  public var isIdentity: Bool {
    [bottomLeft, bottomRight, topRight, topLeft].allSatisfy { $0.x == 0 && $0.y == 0 }
  }
}

/// A bounded, versioned mesh. The renderer accepts the initial bilinear grid
/// only after validating that every cell has a positive Jacobian.
public struct MeshWarp: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public var version: Int
  public var domain: LayerFrame
  public var columns: Int
  public var rows: Int
  /// Row-major normalized destination points. There are `columns * rows`.
  public var points: [PixelPoint]

  public init(
    version: Int = currentVersion,
    domain: LayerFrame,
    columns: Int = 4,
    rows: Int = 4,
    points: [PixelPoint]? = nil
  ) {
    self.version = version
    self.domain = domain
    self.columns = columns
    self.rows = rows
    self.points = points ?? Self.identityPoints(columns: columns, rows: rows)
  }

  public static func identityPoints(columns: Int, rows: Int) -> [PixelPoint] {
    guard columns >= 2, rows >= 2 else { return [] }
    return (0..<rows).flatMap { row in
      (0..<columns).map { column in
        PixelPoint(
          x: Double(column) / Double(columns - 1),
          y: Double(row) / Double(rows - 1)
        )
      }
    }
  }

  public var isIdentity: Bool { points == Self.identityPoints(columns: columns, rows: rows) }

  public var isStructurallyValid: Bool {
    version == Self.currentVersion && columns >= 2 && rows >= 2
      && columns <= 32 && rows <= 32 && points.count == columns * rows
      && !domain.isEmpty && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
  }
}

/// One layer's non-destructive placement and deformation in its parent space.
/// The parameter order is stable: source → mesh → perspective → affine.
public struct LayerTransform: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public var version: Int
  public var referenceRect: LayerFrame
  public var anchor: PixelPoint
  public var position: PixelPoint
  public var scaleX: Double
  public var scaleY: Double
  public var rotationDegrees: Double
  public var shearX: Double
  public var perspective: PerspectiveCorners?
  public var warp: MeshWarp?

  public init(
    version: Int = currentVersion,
    referenceRect: LayerFrame,
    anchor: PixelPoint? = nil,
    position: PixelPoint? = nil,
    scaleX: Double = 1,
    scaleY: Double = 1,
    rotationDegrees: Double = 0,
    shearX: Double = 0,
    perspective: PerspectiveCorners? = nil,
    warp: MeshWarp? = nil
  ) {
    self.version = version
    self.referenceRect = referenceRect
    let center = PixelPoint(x: referenceRect.x + referenceRect.width / 2, y: referenceRect.y + referenceRect.height / 2)
    self.anchor = anchor ?? center
    self.position = position ?? self.anchor
    self.scaleX = scaleX
    self.scaleY = scaleY
    self.rotationDegrees = rotationDegrees
    self.shearX = shearX
    self.perspective = perspective
    self.warp = warp
  }

  public static func identity(for referenceRect: LayerFrame) -> LayerTransform {
    LayerTransform(referenceRect: referenceRect)
  }

  public var isAffine: Bool { perspective == nil && warp == nil }
  /// Whether an axis-aligned crop rectangle remains axis-aligned after this
  /// transform. The Crop tool can map such a layer through its ordinary frame
  /// adapter without pretending a rotated or warped quadrilateral is a rect.
  public var supportsAxisAlignedCrop: Bool {
    isAffine && rotationDegrees == 0 && shearX == 0 && scaleX > 0 && scaleY > 0
  }
  public var isIdentity: Bool {
    position == anchor && scaleX == 1 && scaleY == 1 && rotationDegrees == 0 && shearX == 0
      && (perspective?.isIdentity ?? true) && (warp?.isIdentity ?? true)
  }

  public var isValid: Bool {
    version == Self.currentVersion && !referenceRect.isEmpty
      && [anchor.x, anchor.y, position.x, position.y, scaleX, scaleY, rotationDegrees, shearX].allSatisfy(\.isFinite)
      && abs(scaleX) > 0.000_001 && abs(scaleY) > 0.000_001
      && (perspective.map { corners in
        [corners.bottomLeft, corners.bottomRight, corners.topRight, corners.topLeft]
          .allSatisfy { $0.x.isFinite && $0.y.isFinite }
      } ?? true)
      && (warp?.isStructurallyValid ?? true)
  }

  /// Maps an authoring point through the affine stage. Nonlinear stages are
  /// deliberately evaluated by the renderer; callers that need exact warped
  /// geometry must use the mesh evaluator rather than treating this as a full map.
  public func applyingAffine(to point: PixelPoint) -> PixelPoint {
    let radians = rotationDegrees * .pi / 180
    let dx = point.x - anchor.x
    let dy = point.y - anchor.y
    let shearedX = scaleX * dx + shearX * scaleY * dy
    let shearedY = scaleY * dy
    return PixelPoint(
      x: position.x + cos(radians) * shearedX - sin(radians) * shearedY,
      y: position.y + sin(radians) * shearedX + cos(radians) * shearedY
    )
  }

  public func inverseAffine(_ point: PixelPoint) -> PixelPoint? {
    guard isValid else { return nil }
    let radians = rotationDegrees * .pi / 180
    let dx = point.x - position.x
    let dy = point.y - position.y
    let rotatedX = cos(radians) * dx + sin(radians) * dy
    let rotatedY = -sin(radians) * dx + cos(radians) * dy
    let sourceY = rotatedY / scaleY
    return PixelPoint(x: anchor.x + (rotatedX - shearX * rotatedY) / scaleX, y: anchor.y + sourceY)
  }

  public func affineBounds(of frame: LayerFrame) -> LayerFrame {
    let corners = [
      PixelPoint(x: frame.x, y: frame.y), PixelPoint(x: frame.x + frame.width, y: frame.y),
      PixelPoint(x: frame.x + frame.width, y: frame.y + frame.height), PixelPoint(x: frame.x, y: frame.y + frame.height),
    ].map(applyingAffine)
    let minX = corners.map(\.x).min() ?? frame.x
    let maxX = corners.map(\.x).max() ?? frame.x
    let minY = corners.map(\.y).min() ?? frame.y
    let maxY = corners.map(\.y).max() ?? frame.y
    return LayerFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

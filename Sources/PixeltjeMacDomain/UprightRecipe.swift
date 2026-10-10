import Foundation

/// User-controlled perspective correction, applied after the RAW develop.
///
/// This is upright in its manual form: two amounts the user sets, turned into
/// one Core Image perspective transform in the post-RAW graph. There is no
/// automatic mode. Apple's public frameworks expose no deterministic
/// perspective estimator — Vision reports a horizon angle, which is a
/// straighten and not a keystone — and the RAW rendering contract forbids
/// guessing an equivalent, so the amounts stay in the user's hands.
///
/// Both amounts are in the canonical image coordinate space described at the
/// top of `CropRecipe.swift`: origin bottom-left, x right, y up.
///
/// - `vertical` corrects converging verticals. A positive value widens the top
///   of the frame and narrows the bottom, which straightens a building that
///   leans away from a camera pointed upward.
/// - `horizontal` corrects converging horizontals. A positive value widens the
///   left edge and narrows the right, straightening a wall shot from its right.
public struct UprightRecipe: Codable, Equatable, Sendable {
  /// The strongest correction either amount can ask for, as a fraction of the
  /// image edge each corner may travel.
  public static let maximumCornerShift = 0.25

  public var vertical: Double
  public var horizontal: Double

  public init(vertical: Double = 0, horizontal: Double = 0) {
    self.vertical = vertical
    self.horizontal = horizontal
  }

  public static let identity = UprightRecipe()

  public var clamped: UprightRecipe {
    UprightRecipe(
      vertical: Self.clamp(vertical),
      horizontal: Self.clamp(horizontal)
    )
  }

  /// Whether this recipe changes any pixels.
  public var isActive: Bool {
    let clamped = self.clamped
    return clamped.vertical != 0 || clamped.horizontal != 0
  }

  private static func clamp(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, -1), 1)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    vertical = try container.decodeIfPresent(Double.self, forKey: .vertical) ?? 0
    horizontal = try container.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0
  }

  private enum CodingKeys: String, CodingKey {
    case vertical
    case horizontal
  }
}

/// One corner of the image, in the canonical image coordinate space.
public struct UprightCorner: Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// Where the four corners of the image travel under an upright correction.
///
/// `CIPerspectiveTransform` maps the corners of its input image onto the four
/// points it is given, so these are exactly its parameters. The adapter into
/// Core Image's own coordinates happens at the render engine, not here.
public struct UprightQuadrilateral: Equatable, Sendable {
  public var bottomLeft: UprightCorner
  public var bottomRight: UprightCorner
  public var topLeft: UprightCorner
  public var topRight: UprightCorner

  public init(
    bottomLeft: UprightCorner,
    bottomRight: UprightCorner,
    topLeft: UprightCorner,
    topRight: UprightCorner
  ) {
    self.bottomLeft = bottomLeft
    self.bottomRight = bottomRight
    self.topLeft = topLeft
    self.topRight = topRight
  }
}

extension UprightRecipe {
  /// The corner positions this correction asks for, on an image of this size.
  ///
  /// The two amounts are symmetric about the image center: what one edge gains
  /// the opposite edge gives up, so the correction pivots the picture instead
  /// of sliding it. Empty wedges appear where the quadrilateral leaves the
  /// frame; the crop rectangle is how the user removes them.
  public func quadrilateral(imageWidth: Double, imageHeight: Double) -> UprightQuadrilateral {
    let clamped = self.clamped
    let dx = clamped.vertical * Self.maximumCornerShift * imageWidth
    let dy = clamped.horizontal * Self.maximumCornerShift * imageHeight
    return UprightQuadrilateral(
      bottomLeft: UprightCorner(x: dx, y: -dy),
      bottomRight: UprightCorner(x: imageWidth - dx, y: dy),
      topLeft: UprightCorner(x: -dx, y: imageHeight + dy),
      topRight: UprightCorner(x: imageWidth + dx, y: imageHeight - dy)
    )
  }
}

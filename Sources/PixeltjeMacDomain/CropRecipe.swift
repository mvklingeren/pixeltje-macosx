import Foundation

// MARK: - Canonical image coordinate space
//
// Every crop value in this file is written in the canonical image coordinate
// space:
//
// - the developed RAW after its EXIF orientation has been applied exactly once
//   and before any straighten or crop;
// - origin at the bottom-left corner, x to the right, y up (the Core Image
//   convention, which `LayerFrame` and `VectorPoint` also follow);
// - positions stored as unit fractions of that oriented extent, so a proxy
//   render and the full-resolution render share one recipe and the crop
//   survives a change of decoder resolution.
//
// `CropGeometry.pixelRect(of:in:)` is the adapter into pixels of a specific
// image size, and `CropGeometry.orientedSize(...)` is the adapter from a
// sensor-oriented native size and EXIF orientation into this space.
//
// Straightening rotates the image about its center by `angleDegrees`,
// counter-clockwise for positive values (Core Image's rotation direction). The
// crop rectangle stays axis-aligned in the output: the image turns underneath
// it, the way a crop tool shows a straighten. Because the rotation is about the
// center, the rectangle's coordinates in the output are the same numbers as in
// the unrotated space, so one rectangle serves both the render and the canvas.

/// Guide lines drawn inside the crop rectangle while cropping.
public enum CropOverlay: String, Codable, CaseIterable, Sendable {
  case none
  case thirds
  case grid
  case golden

  public var label: String {
    switch self {
    case .none: "None"
    case .thirds: "Thirds"
    case .grid: "Grid"
    case .golden: "Golden ratio"
    }
  }
}

/// The aspect lock of a crop, as a width-to-height ratio.
public enum CropAspectRatio: Equatable, Sendable {
  case free
  /// The oriented image's own ratio.
  case original
  case ratio(width: Double, height: Double)

  /// The pixel width-to-height ratio the lock stands for, or `nil` when free.
  public func value(imageWidth: Double, imageHeight: Double) -> Double? {
    switch self {
    case .free:
      return nil
    case .original:
      guard imageWidth > 0, imageHeight > 0 else { return nil }
      return imageWidth / imageHeight
    case .ratio(let width, let height):
      guard width > 0, height > 0 else { return nil }
      return width / height
    }
  }

  /// The same lock turned a quarter turn: a 3:2 landscape becomes 2:3 portrait.
  public func swapped(imageWidth: Double, imageHeight: Double) -> CropAspectRatio {
    switch self {
    case .free:
      return .free
    case .original:
      guard imageWidth > 0, imageHeight > 0 else { return .original }
      return CropAspectRatio.ratio(width: imageHeight, height: imageWidth).reduced
    case .ratio(let width, let height):
      return .ratio(width: height, height: width)
    }
  }

  /// Whether the lock is taller than wide.
  public func isPortrait(imageWidth: Double, imageHeight: Double) -> Bool {
    guard let value = value(imageWidth: imageWidth, imageHeight: imageHeight) else { return false }
    return value < 1
  }

  /// A ratio written with the smallest whole numbers, so 4000:6000 reads 2:3.
  public var reduced: CropAspectRatio {
    guard case .ratio(let width, let height) = self, width > 0, height > 0 else { return self }
    let w = Int(width.rounded())
    let h = Int(height.rounded())
    guard Double(w) == width, Double(h) == height, w > 0, h > 0 else { return self }
    let divisor = greatestCommonDivisor(w, h)
    return .ratio(width: Double(w / divisor), height: Double(h / divisor))
  }

  /// The preset this lock matches in either orientation, if any.
  public var presetName: String? {
    Self.presets.first { $0.aspect.matchesIgnoringOrientation(self) }?.name
  }

  fileprivate func matchesIgnoringOrientation(_ other: CropAspectRatio) -> Bool {
    switch (self, other) {
    case (.free, .free), (.original, .original):
      return true
    case (.ratio(let w1, let h1), .ratio(let w2, let h2)):
      return (w1 == w2 && h1 == h2) || (w1 == h2 && h1 == w2)
    default:
      return false
    }
  }
}

private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
  var a = abs(a)
  var b = abs(b)
  while b != 0 { (a, b) = (b, a % b) }
  return max(a, 1)
}

extension CropAspectRatio: Codable {
  private enum Kind: String, Codable {
    case free
    case original
    case ratio
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case width
    case height
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .free:
      self = .free
    case .original:
      self = .original
    case .ratio:
      self = .ratio(
        width: try container.decode(Double.self, forKey: .width),
        height: try container.decode(Double.self, forKey: .height)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .free:
      try container.encode(Kind.free, forKey: .kind)
    case .original:
      try container.encode(Kind.original, forKey: .kind)
    case .ratio(let width, let height):
      try container.encode(Kind.ratio, forKey: .kind)
      try container.encode(width, forKey: .width)
      try container.encode(height, forKey: .height)
    }
  }
}

/// A named aspect lock offered by the crop tool.
public struct CropAspectPreset: Identifiable, Equatable, Sendable {
  public let name: String
  public let aspect: CropAspectRatio

  public init(name: String, aspect: CropAspectRatio) {
    self.name = name
    self.aspect = aspect
  }

  public var id: String { name }
}

extension CropAspectRatio {
  /// The locks the crop tool lists. Anything else is a custom ratio.
  public static let presets: [CropAspectPreset] = [
    CropAspectPreset(name: "Free", aspect: .free),
    CropAspectPreset(name: "Original", aspect: .original),
    CropAspectPreset(name: "1:1", aspect: .ratio(width: 1, height: 1)),
    CropAspectPreset(name: "3:2", aspect: .ratio(width: 3, height: 2)),
    CropAspectPreset(name: "4:3", aspect: .ratio(width: 4, height: 3)),
    CropAspectPreset(name: "5:4", aspect: .ratio(width: 5, height: 4)),
    CropAspectPreset(name: "7:5", aspect: .ratio(width: 7, height: 5)),
    CropAspectPreset(name: "16:9", aspect: .ratio(width: 16, height: 9)),
  ]
}

/// The document-level crop and straighten.
///
/// See the note at the top of this file for the coordinate space. The rectangle
/// is `left`/`bottom`/`right`/`top` in unit coordinates of the oriented image,
/// and `angleDegrees` is the straighten applied underneath it.
public struct CropRecipe: Codable, Equatable, Sendable {
  public static let maximumAngleDegrees = 45.0
  /// The smallest crop edge, as a fraction of the image.
  public static let minimumUnitSize = 0.01

  public var left: Double
  public var bottom: Double
  public var right: Double
  public var top: Double
  public var angleDegrees: Double
  public var aspectRatio: CropAspectRatio
  public var overlay: CropOverlay

  public init(
    left: Double = 0,
    bottom: Double = 0,
    right: Double = 1,
    top: Double = 1,
    angleDegrees: Double = 0,
    aspectRatio: CropAspectRatio = .free,
    overlay: CropOverlay = .thirds
  ) {
    self.left = left
    self.bottom = bottom
    self.right = right
    self.top = top
    self.angleDegrees = angleDegrees
    self.aspectRatio = aspectRatio
    self.overlay = overlay
  }

  /// The whole image, unrotated.
  public static let identity = CropRecipe()

  public var clamped: CropRecipe {
    let left = min(max(self.left, 0), 1)
    let bottom = min(max(self.bottom, 0), 1)
    let right = min(max(self.right, left), 1)
    let top = min(max(self.top, bottom), 1)
    let angle = min(max(angleDegrees, -Self.maximumAngleDegrees), Self.maximumAngleDegrees)
    return CropRecipe(
      left: left,
      bottom: bottom,
      right: right,
      top: top,
      angleDegrees: angle.isFinite ? angle : 0,
      aspectRatio: aspectRatio,
      overlay: overlay
    )
  }

  public var unitWidth: Double { right - left }
  public var unitHeight: Double { top - bottom }
  public var centerX: Double { (left + right) / 2 }
  public var centerY: Double { (bottom + top) / 2 }

  /// Whether the crop leaves every pixel of the oriented image in place.
  public var isFullFrame: Bool {
    left == 0 && bottom == 0 && right == 1 && top == 1 && angleDegrees == 0
  }

  /// Whether rendering with this crop instead of `other` changes pixels.
  ///
  /// The aspect lock and the overlay are how the crop tool behaves, not what
  /// the image looks like, so changing them alone needs no new render.
  public func affectsPixels(comparedTo other: CropRecipe) -> Bool {
    left != other.left || bottom != other.bottom || right != other.right || top != other.top
      || angleDegrees != other.angleDegrees
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    left = try container.decodeIfPresent(Double.self, forKey: .left) ?? 0
    bottom = try container.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
    right = try container.decodeIfPresent(Double.self, forKey: .right) ?? 1
    top = try container.decodeIfPresent(Double.self, forKey: .top) ?? 1
    // Projects written before schema 6 carry the rectangle alone.
    angleDegrees = try container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 0
    aspectRatio =
      try container.decodeIfPresent(CropAspectRatio.self, forKey: .aspectRatio) ?? .free
    overlay = try container.decodeIfPresent(CropOverlay.self, forKey: .overlay) ?? .thirds
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(left, forKey: .left)
    try container.encode(bottom, forKey: .bottom)
    try container.encode(right, forKey: .right)
    try container.encode(top, forKey: .top)
    try container.encode(angleDegrees, forKey: .angleDegrees)
    try container.encode(aspectRatio, forKey: .aspectRatio)
    try container.encode(overlay, forKey: .overlay)
  }

  private enum CodingKeys: String, CodingKey {
    case left
    case bottom
    case right
    case top
    case angleDegrees
    case aspectRatio
    case overlay
  }
}

/// The surface whose pixels a Crop tool session edits.
///
/// Canvas crops change the document extent. Layer crops are non-destructive
/// clips owned by one pixel-backed layer; the identifier keeps an in-flight
/// draft bound to the layer it was opened for even if selection later changes.
public enum CropTarget: Hashable, Sendable {
  case canvas
  case layer(ProjectLayerID)
}

/// Uncommitted Crop tool state shared by the settings panel and canvas.
public struct CropDraft: Equatable, Sendable {
  public var target: CropTarget
  public var recipe: CropRecipe
  /// Whether rendering temporarily reveals the target outside `recipe` so the
  /// rectangle can be expanded again. Apply keeps the draft (and therefore the
  /// settings) alive but turns this off so the committed result is visible.
  public var revealsFullTarget: Bool

  public init(
    target: CropTarget,
    recipe: CropRecipe,
    revealsFullTarget: Bool = true
  ) {
    self.target = target
    self.recipe = recipe
    self.revealsFullTarget = revealsFullTarget
  }
}

import Foundation

/// The document extent, in image pixels.
///
/// The canvas layer carries this and nothing else: no color, no content, and no
/// transform. It exists so a document has a size that survives a hidden image
/// layer, an empty stack, or a project with no RAW source at all.
public struct CanvasRecipe: Codable, Equatable, Sendable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = max(width, 0)
    self.height = max(height, 0)
  }

  /// A canvas whose size is not known yet.
  ///
  /// Projects saved before the canvas layer existed decode to this, as do RAW
  /// documents that have not completed their first render. Both adopt the
  /// developed image's extent as soon as one is available.
  public static let unresolved = CanvasRecipe(width: 0, height: 0)

  public var isResolved: Bool { width > 0 && height > 0 }
}

/// A curated pixel size for one aspect ratio in the canvas inspector.
public struct CanvasSizePreset: Identifiable, Equatable, Sendable {
  public let canvas: CanvasRecipe

  public var id: String { "\(canvas.width)x\(canvas.height)" }
}

/// A shape in the canvas inspector's aspect-ratio strip.
public struct CanvasAspectPreset: Identifiable, Equatable, Sendable {
  public let name: String
  public let description: String
  public let ratioWidth: Int
  public let ratioHeight: Int
  public let sizes: [CanvasSizePreset]

  public var id: String { name }

  fileprivate init(
    name: String, description: String, ratioWidth: Int, ratioHeight: Int, widths: [Int]
  ) {
    self.name = name
    self.description = description
    self.ratioWidth = ratioWidth
    self.ratioHeight = ratioHeight
    // Every listed width is divisible by the ratio numerator, so each size
    // represents the exact ratio rather than a rounded approximation.
    sizes = widths.map { width in
      CanvasSizePreset(canvas: CanvasRecipe(
        width: width, height: width * ratioHeight / ratioWidth))
    }
  }

  /// Changing shape chooses a listed size near the current pixel count.
  public func closestSize(to canvas: CanvasRecipe) -> CanvasSizePreset? {
    guard canvas.isResolved else { return sizes.first }
    let targetPixels = Double(canvas.width) * Double(canvas.height)
    return sizes.min {
      abs(log(Double($0.canvas.width) * Double($0.canvas.height) / targetPixels))
        < abs(log(Double($1.canvas.width) * Double($1.canvas.height) / targetPixels))
    }
  }

  /// Exact ratio matching also keeps a manually entered size highlighted.
  public func matches(_ canvas: CanvasRecipe) -> Bool {
    guard canvas.isResolved else { return false }
    var a = canvas.width
    var b = canvas.height
    while b != 0 { (a, b) = (b, a % b) }
    return canvas.width / a == ratioWidth && canvas.height / a == ratioHeight
  }
}

extension CanvasRecipe {
  /// Familiar editor sizes plus the smaller, varied shapes used by image makers.
  /// Each aspect's widths are ordered from smaller to larger pixel area.
  public static let aspectPresets: [CanvasAspectPreset] = [
    CanvasAspectPreset(name: "1:1", description: "Square", ratioWidth: 1, ratioHeight: 1,
      widths: [448, 512, 640, 768, 960, 1024, 1440, 2048]),
    CanvasAspectPreset(name: "4:5", description: "Portrait", ratioWidth: 4, ratioHeight: 5,
      widths: [896, 1280, 1792]),
    CanvasAspectPreset(name: "5:4", description: "Landscape", ratioWidth: 5, ratioHeight: 4,
      widths: [1120, 1600, 2240]),
    CanvasAspectPreset(name: "3:2", description: "Photo landscape", ratioWidth: 3, ratioHeight: 2,
      widths: [576, 768, 960, 1152, 1200, 1800, 2400]),
    CanvasAspectPreset(name: "2:3", description: "Photo portrait", ratioWidth: 2, ratioHeight: 3,
      widths: [384, 512, 640, 768, 800, 1200, 1600]),
    CanvasAspectPreset(name: "4:3", description: "Classic landscape", ratioWidth: 4,
      ratioHeight: 3, widths: [1152, 1600, 2304]),
    CanvasAspectPreset(name: "3:4", description: "Classic portrait", ratioWidth: 3,
      ratioHeight: 4, widths: [864, 1200, 1728]),
    CanvasAspectPreset(name: "16:9", description: "Widescreen", ratioWidth: 16,
      ratioHeight: 9, widths: [1024, 1280, 1920, 2560]),
    CanvasAspectPreset(name: "9:16", description: "Vertical", ratioWidth: 9,
      ratioHeight: 16, widths: [576, 720, 1080, 1440]),
    CanvasAspectPreset(name: "2:1", description: "Panorama", ratioWidth: 2,
      ratioHeight: 1, widths: [640, 768, 1024, 1280, 1408, 2048]),
    CanvasAspectPreset(name: "1:2", description: "Tall panorama", ratioWidth: 1,
      ratioHeight: 2, widths: [320, 384, 512, 640, 704, 1024]),
    CanvasAspectPreset(name: "8:5", description: "Wide", ratioWidth: 8,
      ratioHeight: 5, widths: [1024]),
    CanvasAspectPreset(name: "5:8", description: "Tall", ratioWidth: 5,
      ratioHeight: 8, widths: [640]),
    CanvasAspectPreset(name: "9:5", description: "Wide", ratioWidth: 9,
      ratioHeight: 5, widths: [1152]),
    CanvasAspectPreset(name: "5:9", description: "Tall", ratioWidth: 5,
      ratioHeight: 9, widths: [640]),
    CanvasAspectPreset(name: "7:4", description: "Wide", ratioWidth: 7,
      ratioHeight: 4, widths: [1344]),
    CanvasAspectPreset(name: "4:7", description: "Tall", ratioWidth: 4,
      ratioHeight: 7, widths: [768]),
    CanvasAspectPreset(name: "9:7", description: "Landscape", ratioWidth: 9,
      ratioHeight: 7, widths: [1152]),
    CanvasAspectPreset(name: "7:9", description: "Portrait", ratioWidth: 7,
      ratioHeight: 9, widths: [896]),
    CanvasAspectPreset(name: "19:13", description: "Landscape", ratioWidth: 19,
      ratioHeight: 13, widths: [1216]),
    CanvasAspectPreset(name: "13:19", description: "Portrait", ratioWidth: 13,
      ratioHeight: 19, widths: [832]),
  ]

  /// The full menu, ordered by pixel count, with landscape before portrait
  /// when two sizes have the same area.
  public static let presets: [CanvasSizePreset] = aspectPresets.flatMap(\.sizes).sorted {
    let leftPixels = $0.canvas.width * $0.canvas.height
    let rightPixels = $1.canvas.width * $1.canvas.height
    if leftPixels == rightPixels { return $0.canvas.width > $1.canvas.width }
    return leftPixels < rightPixels
  }

  public var aspectPreset: CanvasAspectPreset? {
    Self.aspectPresets.first { $0.matches(self) }
  }

  public var sizePreset: CanvasSizePreset? {
    aspectPreset?.sizes.first { $0.canvas == self }
  }

  public var presetName: String? {
    guard let aspectPreset, sizePreset != nil else { return nil }
    if self == CanvasRecipe(width: 1920, height: 1080) { return "HD 1080p" }
    return aspectPreset.name
  }
}

import Foundation

/// A rectangle in canvas pixels, with the origin at the canvas's bottom-left
/// corner and the y axis pointing up.
///
/// This is the same coordinate space the canvas extent is written in, so a
/// frame can be compared against `CanvasRecipe` without an adapter.
public struct LayerFrame: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = max(width, 0)
    self.height = max(height, 0)
  }

  public var isEmpty: Bool { width <= 0 || height <= 0 }

  /// Where an image of this pixel size lands when it is first placed.
  ///
  /// A placed image keeps its own pixels when it fits and shrinks to fit when it
  /// does not, so a camera-sized photo dropped on an HD canvas arrives fully
  /// visible instead of mostly off-canvas. The result is stored in the recipe,
  /// so the placement survives a later canvas resize rather than silently
  /// re-fitting.
  public static func placing(
    naturalWidth: Int,
    naturalHeight: Int,
    in canvas: CanvasRecipe
  ) -> LayerFrame {
    let imageWidth = Double(max(naturalWidth, 1))
    let imageHeight = Double(max(naturalHeight, 1))
    guard canvas.isResolved else {
      return LayerFrame(x: 0, y: 0, width: imageWidth, height: imageHeight)
    }
    let canvasWidth = Double(canvas.width)
    let canvasHeight = Double(canvas.height)
    let scale = min(1, min(canvasWidth / imageWidth, canvasHeight / imageHeight))
    let width = (imageWidth * scale).rounded()
    let height = (imageHeight * scale).rounded()
    return LayerFrame(
      x: ((canvasWidth - width) / 2).rounded(),
      y: ((canvasHeight - height) / 2).rounded(),
      width: width,
      height: height
    )
  }
}

/// A raster image placed on the canvas.
///
/// The layer carries a link to the file and its placement, never its pixels.
/// Rendering resolves the link every time, so editing the file on disk shows up
/// in the project and saving the project never copies image data.
public struct ImageLayer: Codable, Equatable, Sendable {
  public var source: SourceReference
  public var frame: LayerFrame
  /// The file's own pixel dimensions, recorded when the image was placed.
  public var naturalWidth: Int
  public var naturalHeight: Int

  public init(
    source: SourceReference,
    frame: LayerFrame,
    naturalWidth: Int,
    naturalHeight: Int
  ) {
    self.source = source
    self.frame = frame
    self.naturalWidth = max(naturalWidth, 0)
    self.naturalHeight = max(naturalHeight, 0)
  }

  public var naturalSizeDescription: String {
    "\(naturalWidth) × \(naturalHeight) px"
  }
}

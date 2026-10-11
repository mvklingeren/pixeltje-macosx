import AppKit
import CoreImage
import Foundation
import PixeltjeMacDomain

/// What Copy puts on the pasteboard and what Paste reads back.
///
/// Two flavours go on together and neither is a fallback for the other. The
/// private payload carries the project's own lossless RGBA16F pixels plus where
/// they came from, so a copy and paste inside Pixeltje loses nothing and lands
/// back in place. The PNG beside it is what every other application on the
/// system can actually read.
///
/// Reading prefers the private payload for the same reason: it is the same
/// pixels, in the working space, without a trip through a display encoding.
@MainActor
enum SelectionPasteboard {
  /// Private to the app, so no other application tries to interpret it.
  static let type = NSPasteboard.PasteboardType("org.pixeltje.PixeltjeMacApp.selection-raster")

  /// Where Copy writes and Paste reads: the general pasteboard every
  /// application shares. Tests point it at a private one, so nothing outside
  /// the test can replace a copy while it is still rendering.
  static var pasteboard = NSPasteboard.general

  /// The pixels a copy took, and the canvas geometry needed to put them back
  /// where they were.
  struct Payload: Codable, Equatable, Sendable {
    var reference: RasterAssetReference
    var compressedPixels: Data
    /// Where the pixels sat on the canvas they were copied from.
    var frame: LayerFrame
    var canvasWidth: Int
    var canvasHeight: Int

    init(
      reference: RasterAssetReference,
      compressedPixels: Data,
      frame: LayerFrame,
      canvasWidth: Int,
      canvasHeight: Int
    ) {
      self.reference = reference
      self.compressedPixels = compressedPixels
      self.frame = frame
      self.canvasWidth = canvasWidth
      self.canvasHeight = canvasHeight
    }

    /// Whether these pixels can go back exactly where they came from, which is
    /// only true on a canvas of the same size.
    func fitsInPlace(on canvas: CanvasRecipe) -> Bool {
      canvas.isResolved && canvas.width == canvasWidth && canvas.height == canvasHeight
    }
  }

  /// The image types worth reading from another application, best first: PNG
  /// keeps alpha, TIFF is what the older parts of AppKit put on the pasteboard.
  private static let readableImageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

  /// Replaces the pasteboard with one copied selection.
  ///
  /// A binary property list, not JSON: the pixel blob is the whole payload and
  /// JSON would base64 it, costing a third again in size for nothing.
  static func write(_ payload: Payload, png: Data) throws {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let encoded = try encoder.encode(payload)
    pasteboard.clearContents()
    pasteboard.setData(encoded, forType: type)
    pasteboard.setData(png, forType: .png)
  }

  /// The project's own pixels, when the copy came from Pixeltje.
  static func readPayload() -> Payload? {
    guard let data = pasteboard.data(forType: type) else { return nil }
    return try? PropertyListDecoder().decode(Payload.self, from: data)
  }

  /// An image copied from another application, at its own pixel size.
  ///
  /// Core Image decodes PNG and TIFF data straight to the image's pixel extent.
  /// `NSImage` is a list of representations measured in points, so a Retina
  /// screenshot read that way arrives at half its pixels; going through the data
  /// first keeps every pixel the other application put on the pasteboard.
  static func readCIImage() -> CIImage? {
    for imageType in readableImageTypes {
      guard let data = pasteboard.data(forType: imageType),
        let image = CIImage(data: data)
      else { continue }
      return image
    }
    // Some applications advertise only the class, not a concrete data type.
    return readImage()?.ciImage()
  }

  /// An image copied from another application.
  static func readImage() -> NSImage? {
    for imageType in readableImageTypes {
      guard let data = pasteboard.data(forType: imageType),
        let image = NSImage(data: data)
      else { continue }
      return image
    }
    // Some applications advertise only the class, not a concrete data type.
    return pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage
  }

  /// Graphical clipboard content, resolved once so that the commands reading it
  /// and the menu validation standing them up cannot disagree about what is
  /// there.
  enum Content {
    /// The project's own copy: the same lossless pixels, still unverified.
    case payload(Payload)
    /// An image from another application.
    case image(CIImage)

    /// The size of a canvas that would hold these pixels one for one.
    var pixelSize: CanvasRecipe {
      switch self {
      case .payload(let payload):
        return CanvasRecipe(width: payload.reference.width, height: payload.reference.height)
      case .image(let image):
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { return .unresolved }
        return CanvasRecipe(
          width: Int(extent.width.rounded()), height: Int(extent.height.rounded()))
      }
    }
  }

  /// What is on the pasteboard, the project's own pixels first for the same
  /// reason Paste prefers them: the working space, without a display encoding
  /// in between.
  static func readContent() -> Content? {
    if let payload = readPayload() { return .payload(payload) }
    if let image = readCIImage() { return .image(image) }
    return nil
  }

  /// Whether Paste has anything to work with. Read cheaply, from the type list
  /// alone, because menu validation asks on every menu open.
  static var hasContent: Bool {
    pasteboard.canReadItem(withDataConformingToTypes:
      [type.rawValue] + readableImageTypes.map(\.rawValue))
  }
}

extension NSImage {
  /// The image as Core Image sees it, at its own pixel size.
  ///
  /// `NSImage` is a list of representations rather than pixels, so the best one
  /// for the image's full size is drawn out rather than assumed.
  func ciImage() -> CIImage? {
    var rect = CGRect(origin: .zero, size: size)
    guard let cgImage = cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
      return nil
    }
    return CIImage(cgImage: cgImage)
  }
}

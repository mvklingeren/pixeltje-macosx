import Foundation
import ImageIO
import PixeltjeMacDomain
import UniformTypeIdentifiers

/// Builds a placed image layer from a file the user chose.
///
/// The layer records a link and a placement, never pixels, so the project keeps
/// its size and the file on disk stays authoritative.
enum ImageLayerFactory {
  /// The image types that can be placed on the canvas.
  ///
  /// Camera RAW is deliberately absent. A RAW file is developed by
  /// `CIRAWFilter` under its own recipe, which a placed layer has no way to
  /// carry yet, and the rendering contract forbids sending RAW through the
  /// generic Core Image loading path.
  static var allowedContentTypes: [UTType] {
    let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
    let types = identifiers.compactMap(UTType.init).filter {
      !$0.conforms(to: ImageFolderScanner.cameraRawType)
    }
    return types.isEmpty ? [.image] : types
  }

  static func makeLayer(for url: URL, canvas: CanvasRecipe) throws -> ProjectLayer {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }

    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw PixeltjeMacError(
        "Unsupported image",
        "ImageIO could not read \(url.lastPathComponent)."
      )
    }
    if let identifier = CGImageSourceGetType(imageSource) as String?,
      let type = UTType(identifier),
      type.conforms(to: ImageFolderScanner.cameraRawType)
    {
      throw PixeltjeMacError(
        "RAW images cannot be placed",
        "\(url.lastPathComponent) is a camera RAW file. Open it with File ▸ Open, which develops it through Apple's RAW decoder."
      )
    }

    let size = try pixelSize(of: imageSource, filename: url.lastPathComponent)
    let image = ImageLayer(
      source: try SourceReferenceFactory.make(for: url),
      frame: LayerFrame.placing(
        naturalWidth: size.width,
        naturalHeight: size.height,
        in: canvas
      ),
      naturalWidth: size.width,
      naturalHeight: size.height
    )
    return .image(image)
  }

  /// The image's dimensions as displayed, with a quarter-turn orientation
  /// applied, so a portrait photo is placed portrait.
  private static func pixelSize(
    of imageSource: CGImageSource,
    filename: String
  ) throws -> (width: Int, height: Int) {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else {
      throw PixeltjeMacError(
        "Unsupported image",
        "\(filename) does not report a pixel size."
      )
    }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return [5, 6, 7, 8].contains(orientation)
      ? (width: height, height: width)
      : (width: width, height: height)
  }
}

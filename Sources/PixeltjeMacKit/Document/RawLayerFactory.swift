import Foundation
import PixeltjeMacDomain
import UniformTypeIdentifiers

/// Builds an opt-in placed RAW layer without ever sending it through the
/// generic image loader. Pixels and RAW geometry remain the sole
/// responsibility of `CIRAWFilter` on the render actor.
enum RawLayerFactory {
  static func makeLayer(for url: URL, canvas: CanvasRecipe) throws -> ProjectLayer {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }

    guard isCameraRaw(url) else {
      throw PixeltjeMacError(
        "Not a camera RAW",
        "\(url.lastPathComponent) is not a camera RAW file. Add JPEG, TIFF, or PNG files with Add Image instead."
      )
    }

    // Start with the known canvas rectangle. The first CIRAWFilter inspection
    // replaces it with an aspect-fitted frame derived from the decoder's own
    // oriented extent; no generic image reader gets to define RAW geometry.
    let initialFrame = canvas.isResolved
      ? LayerFrame(x: 0, y: 0, width: Double(canvas.width), height: Double(canvas.height))
      : LayerFrame(x: 0, y: 0, width: 1, height: 1)
    let raw = DevelopedRawLayer(
      source: try SourceReferenceFactory.make(for: url),
      frame: initialFrame,
      needsInitialPlacement: true
    )
    return .placedRaw(raw)
  }

  private static func isCameraRaw(_ url: URL) -> Bool {
    let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    let extensionType = UTType(filenameExtension: url.pathExtension)
    return [resourceType, extensionType].compactMap { $0 }.contains {
      $0.conforms(to: ImageFolderScanner.cameraRawType)
    }
  }
}

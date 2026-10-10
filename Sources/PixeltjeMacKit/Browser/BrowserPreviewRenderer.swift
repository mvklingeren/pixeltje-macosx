import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

struct BrowserPreview: @unchecked Sendable {
  let image: CGImage
  let sourceKind: BrowserFileKind
}

actor BrowserPreviewRenderer {
  private let context: CIContext
  private let outputColorSpace: CGColorSpace

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw PixeltjeMacError("Metal unavailable", "This Mac did not provide a Metal device.")
    }
    guard let outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3) else {
      throw PixeltjeMacError(
        "Color space unavailable", "The Display P3 color space is unavailable."
      )
    }
    self.outputColorSpace = outputColorSpace
    self.context = CIContext(
      mtlDevice: device,
      options: [
        .workingColorSpace: CGColorSpace(
          name: CGColorSpace.extendedLinearDisplayP3
        ) as Any,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
      ]
    )
  }

  func preview(for file: BrowserFile, maximumPixelSize: Int) throws -> BrowserPreview {
    try Task.checkCancellation()
    let accessed = file.url.startAccessingSecurityScopedResource()
    defer {
      if accessed { file.url.stopAccessingSecurityScopedResource() }
    }

    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    let source = CGImageSourceCreateWithURL(file.url as CFURL, sourceOptions)
    let sourceKind = resolvedKind(source: source, fallback: file.kind)

    switch sourceKind {
    case .cameraRaw:
      guard let source else {
        throw PixeltjeMacError(
          "Preview unavailable", "ImageIO could not inspect \(file.displayName)."
        )
      }
      guard let embedded = embeddedThumbnail(from: source, maximumPixelSize: maximumPixelSize)
      else {
        throw PixeltjeMacError(
          "Preview unavailable",
          "\(file.displayName) does not contain an embedded preview."
        )
      }
      try Task.checkCancellation()
      return BrowserPreview(
        image: try makeDisplayImage(
          from: CIImage(cgImage: embedded),
          maximumPixelSize: maximumPixelSize
        ),
        sourceKind: .cameraRaw
      )

    case .coreImage:
      guard
        let image = CIImage(
          contentsOf: file.url,
          options: [.applyOrientationProperty: true]
        )
      else {
        throw PixeltjeMacError(
          "Preview unavailable", "Core Image cannot open \(file.displayName)."
        )
      }
      try Task.checkCancellation()
      return BrowserPreview(
        image: try makeDisplayImage(from: image, maximumPixelSize: maximumPixelSize),
        sourceKind: .coreImage
      )
    }
  }

  private func resolvedKind(
    source: CGImageSource?,
    fallback: BrowserFileKind
  ) -> BrowserFileKind {
    guard
      let source,
      let identifier = CGImageSourceGetType(source),
      let type = UTType(identifier as String)
    else { return fallback }
    return type.conforms(to: ImageFolderScanner.cameraRawType) ? .cameraRaw : fallback
  }

  private func embeddedThumbnail(
    from source: CGImageSource,
    maximumPixelSize: Int
  ) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: false,
      kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
    ]
    var best: CGImage?
    for index in 0..<CGImageSourceGetCount(source) {
      guard
        let candidate = CGImageSourceCreateThumbnailAtIndex(
          source,
          index,
          options as CFDictionary
        )
      else { continue }
      if let currentBest = best {
        if candidate.width * candidate.height > currentBest.width * currentBest.height {
          best = candidate
        }
      } else {
        best = candidate
      }
    }
    return best
  }

  private func makeDisplayImage(from input: CIImage, maximumPixelSize: Int) throws -> CGImage {
    var image = normalized(input)
    let longEdge = max(image.extent.width, image.extent.height)
    if longEdge > CGFloat(maximumPixelSize) {
      let scale = CGFloat(maximumPixelSize) / longEdge
      image = image.applyingFilter(
        "CILanczosScaleTransform",
        parameters: [
          kCIInputScaleKey: scale,
          kCIInputAspectRatioKey: 1,
        ]
      )
      image = normalized(image)
    }
    try Task.checkCancellation()
    guard
      let output = context.createCGImage(
        image,
        from: image.extent.integral,
        format: .RGBA8,
        colorSpace: outputColorSpace
      )
    else {
      throw PixeltjeMacError("Preview unavailable", "Core Image could not render the preview.")
    }
    return output
  }

  private func normalized(_ image: CIImage) -> CIImage {
    let extent = image.extent.integral
    guard extent.origin != .zero else { return image.cropped(to: extent) }
    return
      image
      .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
      .cropped(to: CGRect(origin: .zero, size: extent.size))
  }
}

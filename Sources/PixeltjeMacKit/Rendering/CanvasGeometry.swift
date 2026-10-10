import Foundation
import PixeltjeMacDomain

/// The explicit AppKit-view to canonical-canvas adapter used by painting and
/// tested independently of `NSWindow` and `MTKView`.
public struct CanvasCoordinateTransform: Equatable, Sendable {
  public var viewSize: CGSize
  public var drawableSize: CGSize
  public var canvasSize: CGSize
  public var backingScale: CGFloat
  public var zoom: CGFloat
  /// Pan is stored in drawable pixels, matching `MetalCanvasView`.
  public var panInDrawablePixels: CGPoint

  public init(
    viewSize: CGSize,
    drawableSize: CGSize,
    canvasSize: CGSize,
    backingScale: CGFloat,
    zoom: CGFloat,
    panInDrawablePixels: CGPoint
  ) {
    self.viewSize = viewSize
    self.drawableSize = drawableSize
    self.canvasSize = canvasSize
    self.backingScale = max(backingScale, 0.000_1)
    self.zoom = max(zoom, 0.000_1)
    self.panInDrawablePixels = panInDrawablePixels
  }

  public var canvasRectInView: CGRect {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
    let fit = min(drawableSize.width / canvasSize.width, drawableSize.height / canvasSize.height)
    let scale = fit * zoom / backingScale
    let rendered = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
    return CGRect(
      x: (viewSize.width - rendered.width) / 2 + panInDrawablePixels.x / backingScale,
      y: (viewSize.height - rendered.height) / 2 + panInDrawablePixels.y / backingScale,
      width: rendered.width,
      height: rendered.height
    )
  }

  /// The same rectangle in drawable pixels, which is the space Core Image
  /// composites and presents in.
  ///
  /// `canvasRectInView` divides by the backing scale because AppKit hit testing
  /// and overlay layers work in points. A render pass does not, so both live
  /// here rather than each surface deriving the fit, zoom and centring again.
  public var canvasRectInDrawablePixels: CGRect {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
    let fit = min(drawableSize.width / canvasSize.width, drawableSize.height / canvasSize.height)
    let scale = fit * zoom
    let rendered = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
    return CGRect(
      x: (drawableSize.width - rendered.width) / 2 + panInDrawablePixels.x,
      y: (drawableSize.height - rendered.height) / 2 + panInDrawablePixels.y,
      width: rendered.width,
      height: rendered.height
    )
  }

  public func canvasPoint(fromView point: CGPoint) -> CGPoint? {
    let rect = canvasRectInView
    guard rect.width > 0, rect.height > 0 else { return nil }
    return CGPoint(
      x: (point.x - rect.minX) * canvasSize.width / rect.width,
      y: (point.y - rect.minY) * canvasSize.height / rect.height
    )
  }

  /// Returns the pan that keeps the canvas pixel beneath `viewPoint` fixed
  /// while changing zoom. A missing point, or one outside the canvas, anchors
  /// the zoom at the viewport centre instead.
  public func anchoredPanInDrawablePixels(
    forViewPoint viewPoint: CGPoint?,
    atZoom newZoom: CGFloat
  ) -> CGPoint? {
    let rectInView = canvasRectInView
    guard !rectInView.isEmpty, newZoom > 0 else { return nil }

    let zoomRatio = newZoom / zoom
    let rectInDrawablePixels = canvasRectInDrawablePixels
    let anchorInView = viewPoint.flatMap { rectInView.contains($0) ? $0 : nil }
      ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    let anchorInDrawablePixels = CGPoint(
      x: anchorInView.x * backingScale,
      y: anchorInView.y * backingScale
    )
    let imageCentreInDrawablePixels = CGPoint(
      x: rectInDrawablePixels.midX,
      y: rectInDrawablePixels.midY
    )

    return CGPoint(
      x: panInDrawablePixels.x
        + (1 - zoomRatio) * (anchorInDrawablePixels.x - imageCentreInDrawablePixels.x),
      y: panInDrawablePixels.y
        + (1 - zoomRatio) * (anchorInDrawablePixels.y - imageCentreInDrawablePixels.y)
    )
  }
}

extension RawInspection {
  /// The extent a developed RAW occupies after orientation and crop.
  ///
  /// This is the canvas size a RAW-backed document adopts, and it is also the
  /// geometry the canvas view maps pen coordinates against, so both read it
  /// from here rather than each deriving it.
  public func canvasRecipe(crop: CropRecipe) -> CanvasRecipe {
    let size = orientedSize
    let cropped = CropGeometry.croppedPixelSize(
      crop,
      imageWidth: size.width,
      imageHeight: size.height
    )
    return CanvasRecipe(width: cropped.width, height: cropped.height)
  }

  /// The decoder's native size after its EXIF orientation, which is the extent
  /// the canonical image coordinate space is measured against.
  public var orientedSize: (width: Double, height: Double) {
    CropGeometry.orientedSize(
      nativeWidth: nativeWidth,
      nativeHeight: nativeHeight,
      exifOrientation: Int(exifOrientation)
    )
  }
}

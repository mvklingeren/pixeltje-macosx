import CoreGraphics
import Testing

@testable import PixeltjeMacKit

/// The canvas and the fullscreen preview both place the image with
/// `CanvasCoordinateTransform`, so fit, zoom, pan and centring are covered here
/// once rather than through either view.

private func transform(
  canvas: CGSize,
  drawable: CGSize = CGSize(width: 200, height: 200),
  backingScale: CGFloat = 2,
  zoom: CGFloat = 1,
  pan: CGPoint = .zero
) -> CanvasCoordinateTransform {
  CanvasCoordinateTransform(
    viewSize: CGSize(width: drawable.width / backingScale, height: drawable.height / backingScale),
    drawableSize: drawable,
    canvasSize: canvas,
    backingScale: backingScale,
    zoom: zoom,
    panInDrawablePixels: pan
  )
}

@Test func aFittedImageIsCentredAndLetterboxedOnTheAxisWithRoomToSpare() {
  // 2:1 into a square: width fills, so the bars are above and below.
  let rect = transform(canvas: CGSize(width: 100, height: 50)).canvasRectInDrawablePixels
  #expect(rect == CGRect(x: 0, y: 50, width: 200, height: 100))
}

@Test func zoomingScalesAboutTheCentreSoTheImageGrowsOffBothEdges() {
  let rect = transform(canvas: CGSize(width: 100, height: 50), zoom: 2)
    .canvasRectInDrawablePixels
  #expect(rect == CGRect(x: -100, y: 0, width: 400, height: 200))
}

@Test func panMovesTheImageByItsOwnDrawablePixelsWithoutResizingIt() {
  let rect = transform(canvas: CGSize(width: 100, height: 50), pan: CGPoint(x: 10, y: -20))
    .canvasRectInDrawablePixels
  #expect(rect == CGRect(x: 10, y: 30, width: 200, height: 100))
}

@Test func pointerAnchoredZoomKeepsTheSameCanvasPixelUnderThePointer() throws {
  let before = transform(
    canvas: CGSize(width: 100, height: 50),
    zoom: 1.25,
    pan: CGPoint(x: 12, y: -8)
  )
  let pointer = CGPoint(x: 72, y: 44)
  let canvasPointBefore = try #require(before.canvasPoint(fromView: pointer))
  let anchoredPan = try #require(
    before.anchoredPanInDrawablePixels(forViewPoint: pointer, atZoom: 3.5)
  )
  let after = transform(
    canvas: before.canvasSize,
    drawable: before.drawableSize,
    backingScale: before.backingScale,
    zoom: 3.5,
    pan: anchoredPan
  )
  let canvasPointAfter = try #require(after.canvasPoint(fromView: pointer))

  #expect(abs(canvasPointBefore.x - canvasPointAfter.x) < 0.000_1)
  #expect(abs(canvasPointBefore.y - canvasPointAfter.y) < 0.000_1)
}

@Test func zoomOutsideTheImageFallsBackToTheViewportCentre() throws {
  let before = transform(
    canvas: CGSize(width: 100, height: 50),
    zoom: 1.25,
    pan: CGPoint(x: 16, y: -12)
  )
  let viewportCentre = CGPoint(x: before.viewSize.width / 2, y: before.viewSize.height / 2)
  let canvasPointBefore = try #require(before.canvasPoint(fromView: viewportCentre))
  let outsidePointer = CGPoint(x: 50, y: 5)
  let anchoredPan = try #require(
    before.anchoredPanInDrawablePixels(forViewPoint: outsidePointer, atZoom: 2)
  )
  let after = transform(
    canvas: before.canvasSize,
    drawable: before.drawableSize,
    backingScale: before.backingScale,
    zoom: 2,
    pan: anchoredPan
  )
  let canvasPointAfter = try #require(after.canvasPoint(fromView: viewportCentre))

  #expect(abs(canvasPointBefore.x - canvasPointAfter.x) < 0.000_1)
  #expect(abs(canvasPointBefore.y - canvasPointAfter.y) < 0.000_1)
  #expect(
    anchoredPan
      == before.anchoredPanInDrawablePixels(forViewPoint: nil, atZoom: 2)
  )
}

/// The two rectangles are the same placement in different units: one for
/// AppKit hit testing and overlay layers, one for the render pass. A drift
/// between them would put the marching ants somewhere the pixels are not.
@Test func theDrawableRectangleIsTheViewRectangleInBackingPixels() {
  let subject = transform(canvas: CGSize(width: 100, height: 50), zoom: 1.5,
    pan: CGPoint(x: 12, y: 8))
  let inView = subject.canvasRectInView
  let inDrawable = subject.canvasRectInDrawablePixels
  let scaled = CGRect(
    x: inView.minX * subject.backingScale,
    y: inView.minY * subject.backingScale,
    width: inView.width * subject.backingScale,
    height: inView.height * subject.backingScale
  )
  #expect(abs(scaled.minX - inDrawable.minX) < 0.000_1)
  #expect(abs(scaled.minY - inDrawable.minY) < 0.000_1)
  #expect(abs(scaled.width - inDrawable.width) < 0.000_1)
  #expect(abs(scaled.height - inDrawable.height) < 0.000_1)
}

@Test func aCanvasWithNoExtentPlacesNothing() {
  #expect(transform(canvas: .zero).canvasRectInDrawablePixels == .zero)
}

import AppKit
import CoreImage
import Metal
import MetalKit

/// The composited frame on its own, fitted on black.
///
/// This is a presentation surface, not a second canvas: it shows
/// `RenderedFrame.surface`, which `RenderEngine` has already composited from
/// every layer and which is the same image an export writes. The checkerboard,
/// guides, selection ants, crop box and vector handles the canvas draws are
/// editing furniture, so none of them appear here. Nothing in this view can
/// reach the document.
@MainActor
final class FullscreenPreviewView: MTKView, MTKViewDelegate {
  /// Called by a click, Escape, or F: the view says the viewing is over and the
  /// window controller decides what that means.
  var onExit: (() -> Void)?

  private lazy var displayColorSpace: CGColorSpace = {
    CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
  }()
  private lazy var imageContext: CIContext = {
    CIContext(
      mtlDevice: device!,
      options: [
        .workingColorSpace: CGColorSpace(
          name: CGColorSpace.extendedLinearDisplayP3
        ) as Any,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
      ]
    )
  }()
  private lazy var commandQueue = device?.makeCommandQueue()

  private var frameImage: CIImage?
  private var frameSize: CGSize = .zero
  private var zoomMultiplier: CGFloat = 1
  private var panInPixels: CGPoint = .zero
  /// Where the press landed and how far it has travelled, so a release can tell
  /// a click that exits from the end of a pan that does not.
  private var dragOrigin: NSPoint?
  private var dragDistance: CGFloat = 0

  init() {
    super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
    delegate = self
    framebufferOnly = false
    colorPixelFormat = .rgba16Float
    clearColor = MTLClearColorMake(0, 0, 0, 1)
    isPaused = true
    enableSetNeedsDisplay = true
    preferredFramesPerSecond = 60
    colorspace = displayColorSpace
    layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    // The same EDR presentation path as the canvas, so a highlight that glows
    // in the document window glows here rather than clipping to white.
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.wantsExtendedDynamicRangeContent = true
      metalLayer.colorspace = displayColorSpace
    }
    setAccessibilityRole(.image)
    setAccessibilityLabel("Fullscreen preview")
    setAccessibilityHelp(
      "The composited image on black. Scroll to pan, ⌘-scroll to zoom, Escape or F to leave."
    )
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("FullscreenPreviewView is created programmatically")
  }

  override var acceptsFirstResponder: Bool { true }

  func present(_ frame: RenderedFrame) {
    frameImage = CIImage(
      ioSurface: frame.surface,
      options: [
        .colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any
      ]
    )
    frameSize = CGSize(width: frame.width, height: frame.height)
    needsDisplay = true
  }

  func clearFrame() {
    frameImage = nil
    frameSize = .zero
    needsDisplay = true
  }

  func zoomToFit() {
    zoomMultiplier = 1
    panInPixels = .zero
    needsDisplay = true
  }

  func zoomToActualSize() {
    let fit = fitScale()
    zoomMultiplier = fit > 0 ? 1 / fit : 1
    panInPixels = .zero
    needsDisplay = true
  }

  func zoomIn() {
    setZoom(zoomMultiplier * 1.25, anchoredAt: nil)
  }

  func zoomOut() {
    setZoom(zoomMultiplier / 1.25, anchoredAt: nil)
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    needsDisplay = true
  }

  func draw(in view: MTKView) {
    guard
      let drawable = currentDrawable,
      let commandBuffer = commandQueue?.makeCommandBuffer()
    else { return }

    let destination = CGRect(origin: .zero, size: drawableSize)
    // Black is drawn rather than cleared to: Core Image renders straight into
    // the drawable without a render pass, so `clearColor` never runs.
    var output = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
      .cropped(to: destination)

    let target = coordinateTransform.canvasRectInDrawablePixels
    if let frameImage, !target.isEmpty, frameSize.width > 0, frameSize.height > 0 {
      let transform = CGAffineTransform(
        a: target.width / frameSize.width,
        b: 0,
        c: 0,
        d: target.height / frameSize.height,
        tx: target.minX,
        ty: target.minY
      )
      output = frameImage.transformed(by: transform).composited(over: output)
        .cropped(to: destination)
    }

    imageContext.render(
      output,
      to: drawable.texture,
      commandBuffer: commandBuffer,
      bounds: destination,
      colorSpace: displayColorSpace
    )
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  override func magnify(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    setZoom(zoomMultiplier * (1 + event.magnification), anchoredAt: point)
  }

  override func scrollWheel(with event: NSEvent) {
    let backingScale = window?.backingScaleFactor ?? 1
    if event.modifierFlags.contains(.command) {
      let factor = exp(-event.scrollingDeltaY * 0.01)
      let point = convert(event.locationInWindow, from: nil)
      setZoom(zoomMultiplier * factor, anchoredAt: point)
      return
    } else {
      let direction: CGFloat = InteractionPreferences.invertsPanDirection ? -1 : 1
      panInPixels.x += event.scrollingDeltaX * backingScale * direction
      panInPixels.y -= event.scrollingDeltaY * backingScale * direction
    }
    needsDisplay = true
  }

  private func setZoom(_ proposedZoom: CGFloat, anchoredAt viewPoint: CGPoint?) {
    let newZoom = min(max(proposedZoom, 0.05), 64)
    if let anchoredPan = coordinateTransform.anchoredPanInDrawablePixels(
      forViewPoint: viewPoint,
      atZoom: newZoom
    )
    {
      panInPixels = anchoredPan
    }
    zoomMultiplier = newZoom
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    dragOrigin = convert(event.locationInWindow, from: nil)
    dragDistance = 0
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragOrigin else { return }
    let point = convert(event.locationInWindow, from: nil)
    let backingScale = window?.backingScaleFactor ?? 1
    let direction: CGFloat = InteractionPreferences.invertsPanDirection ? -1 : 1
    panInPixels.x += (point.x - dragOrigin.x) * backingScale * direction
    panInPixels.y += (point.y - dragOrigin.y) * backingScale * direction
    dragDistance += hypot(point.x - dragOrigin.x, point.y - dragOrigin.y)
    self.dragOrigin = point
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let wasClick = dragOrigin != nil && dragDistance <= 3
    dragOrigin = nil
    dragDistance = 0
    if wasClick { onExit?() }
  }

  override func cancelOperation(_ sender: Any?) {
    onExit?()
  }

  override func keyDown(with event: NSEvent) {
    // F closes what F opened. The View menu's item is what usually catches this,
    // but the key still has to mean the same thing if it reaches the view.
    if !event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "f"
    {
      onExit?()
      return
    }
    super.keyDown(with: event)
  }

  private var coordinateTransform: CanvasCoordinateTransform {
    CanvasCoordinateTransform(
      viewSize: bounds.size,
      drawableSize: drawableSize,
      canvasSize: frameSize,
      backingScale: window?.backingScaleFactor ?? 1,
      zoom: zoomMultiplier,
      panInDrawablePixels: panInPixels
    )
  }

  private func fitScale() -> CGFloat {
    guard frameSize.width > 0, frameSize.height > 0 else { return 1 }
    return min(drawableSize.width / frameSize.width, drawableSize.height / frameSize.height)
  }
}

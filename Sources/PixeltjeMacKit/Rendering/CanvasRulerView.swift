import AppKit
import PixeltjeMacDomain

/// What the rulers need to know about the viewport.
///
/// The canvas owns pan and zoom, so it reports where the canvas extent landed
/// rather than letting anything else recompute it.
struct CanvasViewportInfo: Equatable {
  /// The canvas extent's rectangle in the canvas view's own coordinates.
  var canvasRectInView: CGRect = .zero
  /// The canvas extent in canvas pixels.
  var canvasSize: CGSize = .zero
  /// Where the pointer sits in canvas pixels, or `nil` when it is elsewhere.
  var pointerInCanvasPixels: CGPoint?
}

/// A ruler along one edge of the canvas, in image pixels.
///
/// Rulers are presentation and nothing else: they read the viewport the canvas
/// reports and never touch the document. Creating a guide by dragging out of
/// one is forwarded as a raw mouse event, so the canvas — which already owns
/// canvas-pixel coordinates and the editor intents — decides what it means.
@MainActor
final class CanvasRulerView: NSView {
  enum Orientation {
    case horizontal
    case vertical
  }

  static let thickness: CGFloat = 20

  let orientation: Orientation
  var onMouseDown: ((NSEvent) -> Void)?
  var onMouseDragged: ((NSEvent) -> Void)?
  var onMouseUp: ((NSEvent) -> Void)?

  private var viewport = CanvasViewportInfo()

  /// Steps a ruler is willing to label, so the numbers stay round at every
  /// zoom level instead of landing on 37 or 1.4.
  private static let tickSteps: [Double] = [
    1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500,
    1_000, 2_000, 2_500, 5_000, 10_000, 20_000, 50_000, 100_000,
  ]
  private let minimumLabelSpacingInPoints: CGFloat = 56

  init(orientation: Orientation) {
    self.orientation = orientation
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityRole(.ruler)
    setAccessibilityLabel(
      orientation == .horizontal ? "Horizontal ruler, image pixels" : "Vertical ruler, image pixels"
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CanvasRulerView is created programmatically")
  }

  func update(_ viewport: CanvasViewportInfo) {
    guard viewport != self.viewport else { return }
    self.viewport = viewport
    needsDisplay = true
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(
      bounds,
      cursor: orientation == .horizontal ? .resizeUpDown : .resizeLeftRight
    )
  }

  override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
  override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
  override func mouseUp(with event: NSEvent) { onMouseUp?(event) }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    bounds.fill()

    // The stretch that actually holds canvas pixels is tinted, so the extent is
    // readable even when the canvas is scrolled far off centre.
    let canvasRect = viewport.canvasRectInView
    if !canvasRect.isEmpty {
      NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
      switch orientation {
      case .horizontal:
        NSRect(x: canvasRect.minX, y: 0, width: canvasRect.width, height: bounds.height).fill()
      case .vertical:
        NSRect(x: 0, y: canvasRect.minY, width: bounds.width, height: canvasRect.height).fill()
      }
    }

    NSColor.separatorColor.setStroke()
    let edge = NSBezierPath()
    switch orientation {
    case .horizontal:
      edge.move(to: NSPoint(x: 0, y: 0.5))
      edge.line(to: NSPoint(x: bounds.maxX, y: 0.5))
    case .vertical:
      edge.move(to: NSPoint(x: bounds.maxX - 0.5, y: 0))
      edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
    }
    edge.lineWidth = 1
    edge.stroke()

    drawTicks()
    drawCursorMarker()
  }

  /// View points per canvas pixel along this ruler's axis.
  private var scale: CGFloat {
    let rect = viewport.canvasRectInView
    switch orientation {
    case .horizontal:
      guard viewport.canvasSize.width > 0 else { return 0 }
      return rect.width / viewport.canvasSize.width
    case .vertical:
      guard viewport.canvasSize.height > 0 else { return 0 }
      return rect.height / viewport.canvasSize.height
    }
  }

  /// Where canvas pixel zero sits along this ruler, in the ruler's own points.
  private var zeroOffset: CGFloat {
    orientation == .horizontal
      ? viewport.canvasRectInView.minX : viewport.canvasRectInView.minY
  }

  private func point(forCanvasPixel value: Double) -> CGFloat {
    zeroOffset + CGFloat(value) * scale
  }

  private func canvasPixel(forPoint value: CGFloat) -> Double {
    guard scale > 0 else { return 0 }
    return Double((value - zeroOffset) / scale)
  }

  private func drawTicks() {
    let scale = self.scale
    guard scale > 0 else { return }
    let step = Self.tickSteps.first { CGFloat($0) * scale >= minimumLabelSpacingInPoints }
      ?? Self.tickSteps[Self.tickSteps.count - 1]
    let minorStep = step / 5

    let length = orientation == .horizontal ? bounds.width : bounds.height
    let first = (canvasPixel(forPoint: 0) / minorStep).rounded(.down) * minorStep
    let last = canvasPixel(forPoint: length)
    guard last > first, (last - first) / minorStep < 20_000 else { return }

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 8, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]

    NSColor.tertiaryLabelColor.setStroke()
    let ticks = NSBezierPath()
    ticks.lineWidth = 1

    var value = first
    while value <= last {
      let isMajor = abs((value / step).rounded() * step - value) < minorStep / 2
      let position = (point(forCanvasPixel: value)).rounded() + 0.5
      let depth: CGFloat = isMajor ? 8 : 4
      switch orientation {
      case .horizontal:
        ticks.move(to: NSPoint(x: position, y: 0))
        ticks.line(to: NSPoint(x: position, y: depth))
      case .vertical:
        ticks.move(to: NSPoint(x: bounds.maxX, y: position))
        ticks.line(to: NSPoint(x: bounds.maxX - depth, y: position))
      }
      if isMajor {
        let label = Int(value.rounded()).formatted(.number.grouping(.never))
        draw(label, atRulerPosition: position, attributes: attributes)
      }
      value += minorStep
    }
    ticks.stroke()
  }

  private func draw(
    _ label: String,
    atRulerPosition position: CGFloat,
    attributes: [NSAttributedString.Key: Any]
  ) {
    let text = NSAttributedString(string: label, attributes: attributes)
    let size = text.size()
    switch orientation {
    case .horizontal:
      text.draw(at: NSPoint(x: position + 2, y: bounds.height - size.height - 2))
    case .vertical:
      // Turned to read bottom-to-top, which is the only way four digits fit in
      // a 20-point ruler. A positive quarter turn makes the text's height
      // extend left from its origin, so offset that origin by the text height
      // to keep the glyphs inside the ruler.
      guard let context = NSGraphicsContext.current else { return }
      context.saveGraphicsState()
      let origin = Self.verticalLabelOrigin(for: size, at: position)
      let transform = NSAffineTransform()
      transform.translateX(by: origin.x, yBy: origin.y)
      transform.rotate(byDegrees: 90)
      transform.concat()
      text.draw(at: .zero)
      context.restoreGraphicsState()
    }
  }

  static func verticalLabelOrigin(for textSize: CGSize, at position: CGFloat) -> CGPoint {
    CGPoint(x: textSize.height + 2, y: position + 2)
  }

  private func drawCursorMarker() {
    guard let pointer = viewport.pointerInCanvasPixels else { return }
    let value = orientation == .horizontal ? Double(pointer.x) : Double(pointer.y)
    let position = point(forCanvasPixel: value).rounded() + 0.5
    NSColor.controlAccentColor.setStroke()
    let marker = NSBezierPath()
    marker.lineWidth = 1
    switch orientation {
    case .horizontal:
      marker.move(to: NSPoint(x: position, y: 0))
      marker.line(to: NSPoint(x: position, y: bounds.height))
    case .vertical:
      marker.move(to: NSPoint(x: 0, y: position))
      marker.line(to: NSPoint(x: bounds.width, y: position))
    }
    marker.stroke()
  }
}

/// The square where the two rulers meet.
@MainActor
final class CanvasRulerCornerView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    bounds.fill()
    NSColor.separatorColor.setStroke()
    let edge = NSBezierPath()
    edge.move(to: NSPoint(x: bounds.maxX - 0.5, y: 0))
    edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
    edge.move(to: NSPoint(x: 0, y: 0.5))
    edge.line(to: NSPoint(x: bounds.maxX, y: 0.5))
    edge.lineWidth = 1
    edge.stroke()
  }
}

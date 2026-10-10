import AppKit

/// A browser preview is deliberately separate from a document's fullscreen
/// preview: it uses the browser's safe preview renderer, which asks RAW files
/// only for their embedded preview and never starts a RAW decode.
@MainActor
final class BrowserFullscreenPreviewWindowController: NSWindowController, NSWindowDelegate {
  var closed: ((BrowserFullscreenPreviewWindowController) -> Void)?
  var navigateRequested: ((BrowserPreviewNavigation) -> Void)?

  private let imageView = BrowserFullscreenImageView()
  private let progress = NSProgressIndicator()
  private let message = NSTextField(labelWithString: "")
  private let renderer: BrowserPreviewRenderer
  private var previewTask: Task<Void, Never>?
  private(set) var currentFile: BrowserFile?

  init(renderer: BrowserPreviewRenderer, on screen: NSScreen?) {
    self.renderer = renderer

    let frame = (screen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let window = BrowserFullscreenPreviewWindow(
      contentRect: frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.backgroundColor = .black
    window.isOpaque = true
    window.isReleasedWhenClosed = false
    window.level = .popUpMenu
    window.collectionBehavior = [.fullScreenAuxiliary]

    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.black.cgColor
    window.contentView = content

    imageView.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(imageView)

    progress.style = .spinning
    progress.controlSize = .regular
    progress.isIndeterminate = true
    progress.isDisplayedWhenStopped = false
    progress.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(progress)

    message.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    message.textColor = .secondaryLabelColor
    message.alignment = .center
    message.stringValue = "Loading preview…"
    message.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(message)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: content.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      progress.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      progress.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -12),
      message.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      message.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 10),
      message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48),
    ])

    super.init(window: window)
    window.delegate = self
    imageView.onExit = { [weak self] in self?.close() }
    imageView.onNavigate = { [weak self] direction in self?.navigateRequested?(direction) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("BrowserFullscreenPreviewWindowController is created programmatically")
  }

  func show(_ file: BrowserFile) {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(imageView)
    load(file)
  }

  private func load(_ file: BrowserFile) {
    previewTask?.cancel()
    currentFile = file
    imageView.setImage(nil)
    progress.isHidden = false
    progress.startAnimation(nil)
    message.isHidden = false
    message.stringValue = "Loading \(file.displayName)…"

    let maximumPixelSize = previewMaximumPixelSize()
    previewTask = Task { [weak self, file, renderer] in
      do {
        let preview = try await renderer.preview(for: file, maximumPixelSize: maximumPixelSize)
        try Task.checkCancellation()
        self?.present(preview)
      } catch is CancellationError {
        // Closing the preview cancels work without turning it into a failure.
      } catch {
        self?.presentFailure(error.userFacingMessage)
      }
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    close()
  }

  func windowWillClose(_ notification: Notification) {
    previewTask?.cancel()
    previewTask = nil
    closed?(self)
  }

  private func present(_ preview: BrowserPreview) {
    guard window?.isVisible == true else { return }
    progress.stopAnimation(nil)
    progress.isHidden = true
    message.isHidden = true
    imageView.setImage(NSImage(
      cgImage: preview.image,
      size: NSSize(width: preview.image.width, height: preview.image.height)
    ))
  }

  private func presentFailure(_ text: String) {
    guard window?.isVisible == true else { return }
    progress.stopAnimation(nil)
    progress.isHidden = true
    message.stringValue = text
  }

  private func previewMaximumPixelSize() -> Int {
    let screen = window?.screen ?? NSScreen.main
    let scale = screen?.backingScaleFactor ?? 2
    let size = screen?.frame.size ?? NSSize(width: 1_440, height: 900)
    return min(max(Int(max(size.width, size.height) * scale), 1_024), 4_096)
  }
}

@MainActor
private final class BrowserFullscreenPreviewWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}

@MainActor
private final class BrowserFullscreenImageView: NSImageView {
  var onExit: (() -> Void)?
  var onNavigate: ((BrowserPreviewNavigation) -> Void)?

  private var zoomMultiplier: CGFloat = 1
  private var pan = CGPoint.zero
  private var dragOrigin: NSPoint?
  private var dragDistance: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Browser fullscreen preview")
    setAccessibilityHelp(
      "The browser preview. Drag or scroll to pan, pinch or Command-scroll to zoom. "
        + "Arrow keys navigate; click or press Escape to return to the browser."
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("BrowserFullscreenImageView is created programmatically")
  }

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    dragOrigin = convert(event.locationInWindow, from: nil)
    dragDistance = 0
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragOrigin else { return }
    let point = convert(event.locationInWindow, from: nil)
    let direction: CGFloat = InteractionPreferences.invertsPanDirection ? -1 : 1
    pan.x += (point.x - dragOrigin.x) * direction
    pan.y += (point.y - dragOrigin.y) * direction
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

  override func magnify(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    setZoom(zoomMultiplier * (1 + event.magnification), anchoredAt: point)
  }

  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
      let factor = exp(-event.scrollingDeltaY * 0.01)
      let point = convert(event.locationInWindow, from: nil)
      setZoom(zoomMultiplier * factor, anchoredAt: point)
      return
    } else {
      let direction: CGFloat = InteractionPreferences.invertsPanDirection ? -1 : 1
      pan.x += event.scrollingDeltaX * direction
      // AppKit scrolling is expressed from the viewport, while this view's
      // image rect uses its bottom-left coordinate space. Match the canvas:
      // a vertical scroll moves the image in the expected direction.
      pan.y -= event.scrollingDeltaY * direction
    }
    needsDisplay = true
  }

  private func setZoom(_ proposedZoom: CGFloat, anchoredAt viewPoint: CGPoint?) {
    let newZoom = min(max(proposedZoom, 0.05), 64)
    if let anchoredPan = coordinateTransform?.anchoredPanInDrawablePixels(
      forViewPoint: viewPoint,
      atZoom: newZoom
    )
    {
      // This image view renders in view points, so its transform deliberately
      // has a backing scale of one and drawable pixels are the stored pan unit.
      pan = anchoredPan
    }
    zoomMultiplier = newZoom
    needsDisplay = true
  }

  func setImage(_ image: NSImage?) {
    self.image = image
    zoomMultiplier = 1
    pan = .zero
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let image, let coordinateTransform else { return }
    let rect = coordinateTransform.canvasRectInView
    image.draw(
      in: rect,
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
  }

  private var coordinateTransform: CanvasCoordinateTransform? {
    guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
    return CanvasCoordinateTransform(
      viewSize: bounds.size,
      drawableSize: bounds.size,
      canvasSize: image.size,
      backingScale: 1,
      zoom: zoomMultiplier,
      panInDrawablePixels: pan
    )
  }

  override func cancelOperation(_ sender: Any?) {
    onExit?()
  }

  override func keyDown(with event: NSEvent) {
    guard !event.modifierFlags.contains(.command) else {
      super.keyDown(with: event)
      return
    }
    switch event.keyCode {
    case 123:
      onNavigate?(.previous)
      return
    case 124:
      onNavigate?(.next)
      return
    case 125:
      onNavigate?(.forwardFive)
      return
    case 126:
      onNavigate?(.backFive)
      return
    default:
      break
    }
    if !event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "f"
    {
      onExit?()
      return
    }
    super.keyDown(with: event)
  }
}

enum BrowserPreviewNavigation {
  case previous
  case next
  case backFive
  case forwardFive

  var offset: Int {
    switch self {
    case .previous: -1
    case .next: 1
    case .backFive: -5
    case .forwardFive: 5
    }
  }
}

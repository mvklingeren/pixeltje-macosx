import AppKit
import Combine

/// A borderless window cannot become key, and a preview that cannot take a key
/// press cannot be dismissed by one.
@MainActor
private final class FullscreenPreviewWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}

/// The document's image alone, on the whole screen.
///
/// One per document window, owned by it and torn down with it. The controller
/// answers the same View-menu selectors the document window does, because while
/// this window is key it is the one the menu reaches: without that, ⌘9 and ⌘0
/// would grey out the moment the preview opened.
@MainActor
final class FullscreenPreviewWindowController: NSWindowController, NSWindowDelegate,
  NSMenuItemValidation
{
  var closed: ((FullscreenPreviewWindowController) -> Void)?

  private let previewView = FullscreenPreviewView()
  private var subscriptions: Set<AnyCancellable> = []

  init(model: EditorModel, on screen: NSScreen?) {
    let frame = (screen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let window = FullscreenPreviewWindow(
      contentRect: frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.backgroundColor = .black
    window.isOpaque = true
    window.isReleasedWhenClosed = false
    // Above the menu bar and the Dock, so neither shows through and neither
    // springs out when the pointer reaches an edge.
    window.level = .popUpMenu
    // A document window that is already in a fullscreen Space still gets
    // covered rather than being switched away from.
    window.collectionBehavior = [.fullScreenAuxiliary]
    window.contentView = previewView

    super.init(window: window)
    window.delegate = self
    previewView.onExit = { [weak self] in self?.close() }

    // The same subscription the canvas keeps, so a render that lands while the
    // preview is up replaces what is being looked at.
    model.$renderedFrame
      .sink { [weak self] frame in
        guard let frame else {
          self?.previewView.clearFrame()
          return
        }
        self?.previewView.present(frame)
      }
      .store(in: &subscriptions)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("FullscreenPreviewWindowController is created programmatically")
  }

  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(previewView)
  }

  /// F, or the toolbar button, pressed again while the preview is up.
  @objc func toggleFullscreenPreview(_ sender: Any?) {
    close()
  }

  @objc func zoomIn(_ sender: Any?) {
    previewView.zoomIn()
  }

  @objc func zoomOut(_ sender: Any?) {
    previewView.zoomOut()
  }

  @objc func zoomToFit(_ sender: Any?) {
    previewView.zoomToFit()
  }

  @objc func zoomToActualSize(_ sender: Any?) {
    previewView.zoomToActualSize()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(toggleFullscreenPreview(_:)):
      menuItem.state = .on
      return true
    case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomToFit(_:)),
      #selector(zoomToActualSize(_:)):
      return true
    default:
      return true
    }
  }

  /// Switching away ends the viewing: a preview left behind an active window
  /// would sit above everything with no way back to it.
  func windowDidResignKey(_ notification: Notification) {
    close()
  }

  func windowWillClose(_ notification: Notification) {
    subscriptions.removeAll()
    closed?(self)
  }
}

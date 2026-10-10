import AppKit

final class BrowserCollectionItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("PixeltjeMac.BrowserCollectionItem")

  var representedURL: URL?
  var previewRequested: (() -> Void)?
  var thumbnailRequestID: UUID?

  private let previewView = NSImageView()
  private let caption = NSTextField(labelWithString: "")
  private let captionBackground = NSVisualEffectView()
  private let progress = NSProgressIndicator()
  private let warning = NSImageView()
  private let previewBackground = NSVisualEffectView()
  private let previewButton = NSButton()
  private var pointerInside = false {
    didSet { updateHoverPresentation() }
  }

  override var isSelected: Bool {
    didSet { updateSelectionAppearance() }
  }

  override func loadView() {
    let root = BrowserHoverView()
    root.hoverChanged = { [weak self] inside in self?.pointerInside = inside }
    root.wantsLayer = true
    root.layer?.cornerRadius = 6
    root.layer?.cornerCurve = .continuous
    root.layer?.masksToBounds = true
    view = root

    previewView.imageScaling = .scaleProportionallyUpOrDown
    previewView.wantsLayer = true
    previewView.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(previewView)

    progress.style = .spinning
    progress.controlSize = .small
    progress.isIndeterminate = true
    // `stopAnimation` alone keeps the stopped spinner's glyph on screen for
    // some AppKit appearances. Make its loading-only lifetime explicit.
    progress.isDisplayedWhenStopped = false
    progress.isHidden = true
    progress.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(progress)

    warning.image = NSImage(
      systemSymbolName: "exclamationmark.triangle",
      accessibilityDescription: "Preview unavailable"
    )
    warning.contentTintColor = .tertiaryLabelColor
    warning.translatesAutoresizingMaskIntoConstraints = false
    warning.isHidden = true
    root.addSubview(warning)

    captionBackground.material = .hudWindow
    captionBackground.blendingMode = .withinWindow
    captionBackground.state = .active
    captionBackground.translatesAutoresizingMaskIntoConstraints = false
    captionBackground.alphaValue = 0
    root.addSubview(captionBackground)

    caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    caption.textColor = .labelColor
    caption.lineBreakMode = .byTruncatingMiddle
    caption.translatesAutoresizingMaskIntoConstraints = false
    caption.alphaValue = 0
    root.addSubview(caption)

    previewBackground.material = .hudWindow
    previewBackground.blendingMode = .withinWindow
    previewBackground.state = .active
    previewBackground.wantsLayer = true
    previewBackground.layer?.cornerRadius = 16
    previewBackground.layer?.cornerCurve = .continuous
    previewBackground.alphaValue = 0
    previewBackground.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(previewBackground)

    previewButton.bezelStyle = .inline
    previewButton.image = NSImage(
      systemSymbolName: "magnifyingglass",
      accessibilityDescription: "Preview fullscreen"
    )
    previewButton.contentTintColor = .labelColor
    previewButton.toolTip = "Preview fullscreen"
    previewButton.target = self
    previewButton.action = #selector(requestPreview(_:))
    previewButton.alphaValue = 0
    previewButton.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(previewButton)

    NSLayoutConstraint.activate([
      previewView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      previewView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      previewView.topAnchor.constraint(equalTo: root.topAnchor),
      previewView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      progress.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      progress.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      warning.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      warning.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      captionBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      captionBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      captionBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      captionBackground.heightAnchor.constraint(equalToConstant: 24),
      caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
      caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
      caption.centerYAnchor.constraint(equalTo: captionBackground.centerYAnchor),
      previewBackground.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
      previewBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
      previewBackground.widthAnchor.constraint(equalToConstant: 32),
      previewBackground.heightAnchor.constraint(equalToConstant: 32),
      previewButton.centerXAnchor.constraint(equalTo: previewBackground.centerXAnchor),
      previewButton.centerYAnchor.constraint(equalTo: previewBackground.centerYAnchor),
      previewButton.widthAnchor.constraint(equalToConstant: 32),
      previewButton.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    updateSelectionAppearance()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedURL = nil
    previewRequested = nil
    thumbnailRequestID = nil
    view.toolTip = nil
    previewView.layer?.removeAllAnimations()
    previewView.image = nil
    previewView.alphaValue = 1
    stopLoading()
    warning.isHidden = true
    previewButton.isEnabled = true
    pointerInside = false
  }

  func showLoading(name: String, url: URL) {
    representedURL = url
    view.toolTip = nil
    caption.stringValue = name
    previewView.layer?.removeAllAnimations()
    previewView.image = nil
    warning.isHidden = true
    previewButton.isEnabled = true
    startLoading()
    view.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor
  }

  func show(_ preview: BrowserPreview, name: String, url: URL, animated: Bool) {
    representedURL = url
    view.toolTip = nil
    caption.stringValue = name
    previewView.layer?.removeAllAnimations()
    stopLoading()
    warning.isHidden = true
    previewButton.isEnabled = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    previewView.image = NSImage(
      cgImage: preview.image,
      size: NSSize(width: preview.image.width, height: preview.image.height)
    )
    guard animated else { return }
    previewView.alphaValue = 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      previewView.animator().alphaValue = 1
    }
  }

  func showFailure(name: String, url: URL) {
    representedURL = url
    caption.stringValue = name
    previewView.layer?.removeAllAnimations()
    stopLoading()
    previewView.image = nil
    warning.isHidden = false
    previewButton.isEnabled = false
    view.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor
  }

  /// A collection view can move a cell beneath a stationary pointer while it
  /// scrolls. AppKit does not reliably send that cell a mouse-exit event, so
  /// recompute the state from the window's current pointer position.
  func refreshHoverState() {
    guard let window = view.window else {
      guard pointerInside else { return }
      pointerInside = false
      return
    }
    let pointer = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    let isInside = view.bounds.contains(pointer)
    guard isInside != pointerInside else { return }
    pointerInside = isInside
  }

  @objc private func requestPreview(_ sender: Any?) {
    previewRequested?()
  }

  private func startLoading() {
    progress.isHidden = false
    progress.startAnimation(nil)
  }

  private func stopLoading() {
    progress.stopAnimation(nil)
    progress.isHidden = true
  }

  private func updateSelectionAppearance() {
    guard isViewLoaded else { return }
    view.layer?.borderWidth = isSelected ? 3 : 0
    view.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
  }

  private func updateHoverPresentation() {
    guard isViewLoaded else { return }
    let alpha: CGFloat = pointerInside ? 1 : 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      caption.animator().alphaValue = alpha
      captionBackground.animator().alphaValue = alpha
      previewButton.animator().alphaValue = alpha
      previewBackground.animator().alphaValue = alpha
    }
  }
}

private final class BrowserHoverView: NSView {
  var hoverChanged: ((Bool) -> Void)?
  private var hoverArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
      owner: self
    )
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    hoverChanged?(true)
  }

  override func mouseExited(with event: NSEvent) {
    hoverChanged?(false)
  }
}

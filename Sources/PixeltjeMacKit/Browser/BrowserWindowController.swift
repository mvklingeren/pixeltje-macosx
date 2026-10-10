import AppKit

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
  var closed: ((BrowserWindowController) -> Void)?

  private let renderer: BrowserPreviewRenderer
  private let openFile: (BrowserFile) -> Void
  private var browserViewController: BrowserViewController?
  private var folder: URL
  private var activeSecurityScopes: [URL] = []

  private lazy var sizeSlider: NSSlider = {
    let slider = NSSlider()
    slider.minValue = 90
    slider.maxValue = 420
    slider.doubleValue = BrowserPreferences.thumbnailSize
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(thumbnailSizeChanged(_:))
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(equalToConstant: 120).isActive = true
    return slider
  }()

  init(folder: URL, openFile: @escaping (BrowserFile) -> Void) throws {
    self.folder = folder
    self.openFile = openFile
    self.renderer = try BrowserPreviewRenderer()

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.minSize = NSSize(width: 520, height: 400)
    window.titleVisibility = .visible
    window.toolbarStyle = .unified
    window.tabbingMode = .preferred
    window.isReleasedWhenClosed = false

    super.init(window: window)
    window.delegate = self
    let toolbar = NSToolbar(identifier: "PixeltjeMac.BrowserToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.setFrameAutosaveName("PixeltjeMacBrowserWindow")
    install(folder: folder)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("BrowserWindowController is created programmatically")
  }

  deinit {
    for scope in activeSecurityScopes {
      scope.stopAccessingSecurityScopedResource()
    }
  }

  func windowWillClose(_ notification: Notification) {
    browserViewController?.cancel()
    releaseSecurityScopes()
    closed?(self)
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.browserThumbnailSize, .browserChooseFolder, .flexibleSpace, .space]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, .browserThumbnailSize, .browserChooseFolder]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case .browserThumbnailSize:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Thumbnail Size"
      item.view = sizeSlider
      return item
    case .browserChooseFolder:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Browse Folder"
      item.image = NSImage(
        systemSymbolName: "folder",
        accessibilityDescription: "Browse Folder"
      )
      item.target = self
      item.action = #selector(chooseFolder(_:))
      return item
    default:
      return nil
    }
  }

  @objc private func thumbnailSizeChanged(_ sender: NSSlider) {
    browserViewController?.thumbnailSize = CGFloat(sender.doubleValue)
  }

  @objc private func chooseFolder(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Browse Image Folder"
    panel.prompt = "Browse"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.directoryURL = folder
    guard let window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let selected = panel.url else { return }
      self?.install(folder: selected)
    }
  }

  private func install(folder: URL) {
    if folder.startAccessingSecurityScopedResource() {
      activeSecurityScopes.append(folder)
    }
    self.folder = folder
    browserViewController?.cancel()

    let controller = BrowserViewController(
      folder: folder,
      renderer: renderer,
      openFile: openFile
    )
    controller.thumbnailSize = CGFloat(sizeSlider.doubleValue)
    controller.progressChanged = { [weak self] progress in
      self?.updateTitle(progress: progress)
    }
    browserViewController = controller
    contentViewController = controller
    window?.makeFirstResponder(controller.view)
    updateTitle(progress: BrowserProgress(loaded: 0, total: 0, isScanning: true))
  }

  private func updateTitle(progress: BrowserProgress) {
    window?.title = folder.lastPathComponent
    if progress.isScanning {
      window?.subtitle = "Scanning…"
    } else if progress.total == 0 {
      window?.subtitle = "No supported images"
    } else if progress.loaded < progress.total {
      window?.subtitle = "\(progress.loaded) of \(progress.total) previews"
    } else {
      window?.subtitle = "\(progress.total) images"
    }
  }

  private func releaseSecurityScopes() {
    let scopes = activeSecurityScopes
    activeSecurityScopes.removeAll()
    for scope in scopes {
      scope.stopAccessingSecurityScopedResource()
    }
  }
}

extension NSToolbarItem.Identifier {
  fileprivate static let browserThumbnailSize = NSToolbarItem.Identifier(
    "PixeltjeMac.BrowserThumbnailSize")
  fileprivate static let browserChooseFolder = NSToolbarItem.Identifier(
    "PixeltjeMac.BrowserChooseFolder")
}

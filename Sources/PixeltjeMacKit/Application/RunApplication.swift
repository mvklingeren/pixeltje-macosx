import AppKit
import Combine
import PixeltjeMCP
import PixeltjeMacDomain
import PixeltjeScripting
import UniformTypeIdentifiers

@MainActor
public func runPixeltjeMacApplication(opening urls: [URL] = []) {
  runPixeltjeMacApplication(options: PixeltjeMacLaunchOptions(urls: urls))
}

@MainActor
public func runPixeltjeMacApplication(options: PixeltjeMacLaunchOptions) {
  let application = NSApplication.shared
  let delegate = PixeltjeMacAppDelegate(
    opening: options.urls,
    newDocumentSize: options.newDocumentSize)
  application.delegate = delegate
  application.run()
  withExtendedLifetime(delegate) {}
}

enum StartupAction: Equatable {
  case open([URL])
  case showOpenDialog
  case newDocument
  case doNothing
}

@MainActor
public final class PixeltjeMacAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var startupURLs: [URL] = []
  private var startupDocumentSize: CanvasRecipe?
  private var receivedOpenRequest = false
  private var browserControllers: [BrowserWindowController] = []
  private let settings = AppSettings()
  private lazy var settingsWindowController = SettingsWindowController(settings: settings)
  private lazy var automationController = ProjectAutomationController()
  private var automationServer: PixeltjeMCPServer?
  private var activeScriptRunners: [UUID: PixeltjeScriptRunner] = [:]
  private var mainMenuObservation: AnyCancellable?

  public override init() {
    super.init()
  }

  public convenience init(opening urls: [URL], newDocumentSize: CanvasRecipe? = nil) {
    self.init()
    startupURLs = urls
    startupDocumentSize = newDocumentSize
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    BrowserPreferences.registerDefaults()
    ColorPanelPreferences.applyOpeningMode()
    ColorPanelPalette.shared.setUsesSampledColors(settings.usesSampledPaletteColors)
    ColorPanelPalette.shared.attachCurrentColors()
    mainMenuObservation = MainMenu.install(delegate: self)
    settings.automationEnabledDidChange = { [weak self] enabled in
      self?.configureAutomation(enabled: enabled)
    }
    settings.automationTokenRotationRequested = { [weak self] in
      self?.rotateAutomationToken()
    }
    configureAutomation(enabled: settings.enablesAutomation)
    NSApp.activate(ignoringOtherApps: true)

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let urls = self.startupURLs
      self.startupURLs = []
      switch Self.startupAction(
        urls: urls,
        receivedOpenRequest: self.receivedOpenRequest,
        hasOpenDocuments: !NSDocumentController.shared.documents.isEmpty,
        showsOpenDialogOnStart: self.settings.showsOpenDialogOnStart,
        requestsSizedDocument: self.startupDocumentSize != nil
      ) {
      case .open(let urls):
        self.receivedOpenRequest = true
        urls.forEach(self.open)
      case .showOpenDialog:
        self.openDocument(nil)
      case .newDocument:
        let size = self.startupDocumentSize
        self.startupDocumentSize = nil
        self.makeNewDocument(canvas: size)
      case .doNothing:
        break
      }
    }
  }

  public func application(_ application: NSApplication, open urls: [URL]) {
    receivedOpenRequest = receivedOpenRequest || !urls.isEmpty
    urls.forEach(open)
  }

  public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
    false
  }

  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  public func applicationWillTerminate(_ notification: Notification) {
    automationServer?.stop()
    activeScriptRunners.values.forEach { $0.cancel() }
  }

  public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  /// What a launch with the given input and settings should put on screen.
  ///
  /// Launching with nothing to show leaves the user staring at an empty app, so
  /// a launch that opens no file always ends in one of the two entry points:
  /// the file chooser when it is turned on, and a new document otherwise.
  static func startupAction(
    urls: [URL],
    receivedOpenRequest: Bool,
    hasOpenDocuments: Bool,
    showsOpenDialogOnStart: Bool,
    requestsSizedDocument: Bool = false
  ) -> StartupAction {
    guard urls.isEmpty else { return .open(urls) }
    // Finder or a reopened autosaved document already decided what to show.
    guard !receivedOpenRequest, !hasOpenDocuments else { return .doNothing }
    if requestsSizedDocument { return .newDocument }
    return showsOpenDialogOnStart ? .showOpenDialog : .newDocument
  }

  /// Creates an empty document at the configured default canvas size.
  ///
  /// `NSDocumentController.newDocument(_:)` stays disabled here because the
  /// document class is never registered through a bundle: the app builds and
  /// runs straight from the package. Creating the document directly, the way
  /// `openDocument(_:)` already opens one, keeps File ▸ New working in both a
  /// bundled build and `swift run`.
  @objc public func newDocument(_ sender: Any?) {
    makeNewDocument(canvas: nil)
  }

  private func makeNewDocument(canvas: CanvasRecipe?) {
    let document = canvas.map { ProjectDocument(canvas: $0) } ?? ProjectDocument()
    NSDocumentController.shared.addDocument(document)
    document.makeWindowControllers()
    document.showWindows()
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Creates a document the size of the clipboard image, holding it.
  ///
  /// Built the same way as `newDocument(_:)`, and for the same reason: the
  /// document class is never registered through a bundle.
  @objc public func newDocumentFromClipboard(_ sender: Any?) {
    guard let content = SelectionPasteboard.readContent() else { return }
    do {
      let document = try ProjectDocument(clipboard: content)
      NSDocumentController.shared.addDocument(document)
      document.makeWindowControllers()
      document.showWindows()
      NSApp.activate(ignoringOtherApps: true)
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Can’t create a document from the clipboard"
      alert.informativeText = error.userFacingMessage
      alert.runModal()
    }
  }

  @objc public func openDocument(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Open Image or Pixeltje Mac Project"
    panel.prompt = "Open"
    panel.canChooseFiles = true
    // A .pxmac project is a directory package. The unbundled `swift run` app
    // cannot rely on Launch Services to present that extension as a file.
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    panel.begin { [weak self] response in
      guard response == .OK else { return }
      for url in panel.urls {
        self?.open(url)
      }
    }
  }

  @objc public func browseFolder(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Browse Image Folder"
    panel.prompt = "Browse"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.begin { [weak self] response in
      guard response == .OK, let folder = panel.url else { return }
      self?.showBrowser(folder: folder)
    }
  }

  /// Lets the user explicitly grant one trusted local JavaScript file access
  /// to the semantic automation surface. The script receives no file URL or
  /// ambient filesystem capability; the panel grant is used only to read its
  /// source before JavaScriptCore evaluates it off the main thread.
  @objc public func runScript(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Run Pixeltje Script"
    panel.prompt = "Run"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .plainText]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.startScript(at: url)
    }
  }

  @objc public func cancelRunningScripts(_ sender: Any?) {
    activeScriptRunners.values.forEach { $0.cancel() }
  }

  @objc public func showSettings(_ sender: Any?) {
    settingsWindowController.show()
  }

  @objc public func showComfyUIWorkflowSettings(_ sender: Any?) {
    settingsWindowController.show(destination: .comfyUIWorkflows)
  }

  private func configureAutomation(enabled: Bool) {
    automationServer?.stop()
    automationServer = nil
    guard enabled else {
      settings.setAutomationRuntime(endpoint: nil, accessToken: nil, status: "Disabled")
      return
    }
    do {
      let token = try AutomationAccessTokenStore.loadOrCreate()
      let server = PixeltjeMCPServer(
        service: automationController,
        accessToken: token,
        scopes: settings.automationScopes
      )
      server.onReady = { [weak self, weak server] in
        guard let self, let server else { return }
        self.settings.setAutomationRuntime(
          endpoint: server.endpoint,
          accessToken: token,
          status: "Running"
        )
      }
      server.onFailure = { [weak self] message in
        self?.automationServer = nil
        self?.settings.setAutomationRuntime(
          endpoint: nil,
          accessToken: nil,
          status: "Failed: \(message)"
        )
      }
      try server.start()
      automationServer = server
      settings.setAutomationRuntime(
        endpoint: server.endpoint,
        accessToken: token,
        status: "Starting…"
      )
    } catch {
      settings.setAutomationRuntime(
        endpoint: nil,
        accessToken: nil,
        status: "Failed: \(error.localizedDescription)"
      )
    }
  }

  private func rotateAutomationToken() {
    automationServer?.stop()
    automationServer = nil
    do {
      _ = try AutomationAccessTokenStore.rotate()
      configureAutomation(enabled: settings.enablesAutomation)
    } catch {
      settings.setAutomationRuntime(
        endpoint: nil,
        accessToken: nil,
        status: "Failed: \(error.localizedDescription)"
      )
    }
  }

  /// Flips one canvas overlay for every window at once.
  ///
  /// The menu item carries its option as its tag, so the View menu adds a
  /// toggle without adding a selector. The right panel's Canvas section reads
  /// and writes the same object, which is what keeps the two in step.
  @objc public func toggleCanvasViewOption(_ sender: Any?) {
    guard let item = sender as? NSMenuItem,
      let option = CanvasViewOption(rawValue: item.tag)
    else { return }
    CanvasViewSettings.shared.toggle(option)
  }

  /// Stands up the delegate's own menu items and puts the checkmarks on the
  /// View menu's overlay toggles.
  ///
  /// Only items targeted at the delegate reach this, so everything else is left
  /// to the responder chain and answers yes.
  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(newDocumentFromClipboard(_:)):
      return ProjectDocument.canCreateFromClipboard
    case #selector(toggleCanvasViewOption(_:)):
      guard let option = CanvasViewOption(rawValue: menuItem.tag) else { return true }
      let settings = CanvasViewSettings.shared
      menuItem.state = settings.isOn(option) ? .on : .off
      // Locking guides only says anything while they are on screen.
      return option != .lockGuides || settings.isOn(.guides)
    case #selector(cancelRunningScripts(_:)):
      return !activeScriptRunners.isEmpty
    default:
      return true
    }
  }

  @objc public func showAboutPanel(_ sender: Any?) {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Pixeltje Mac",
      .applicationVersion: "0.1",
      .credits: NSAttributedString(
        string: "A native macOS 27 RAW developer powered directly by Core Image.\n\n"
          + "ComfyUI is a trademark of Comfy Org. Pixeltje is an independent integration "
          + "and is not affiliated with or endorsed by Comfy Org."
      ),
    ])
  }

  private func open(_ url: URL) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      present(
        PixeltjeMacError("File unavailable", "The selected item could not be found."),
        for: url
      )
      return
    }
    do {
      let document: ProjectDocument
      let openedImage: Bool
      if url.pathExtension.caseInsensitiveCompare(ProjectDocument.projectFilenameExtension)
        == .orderedSame
      {
        document = try ProjectDocument(
          contentsOf: url,
          ofType: ProjectDocument.projectTypeIdentifier
        )
        openedImage = false
      } else if isDirectory.boolValue {
        showBrowser(folder: url)
        return
      } else if Self.opensAsOrdinaryImage(url) {
        document = try ProjectDocument(importingImage: url)
        openedImage = true
      } else {
        document = try ProjectDocument(importingRaw: url)
        openedImage = true
      }
      NSDocumentController.shared.addDocument(document)
      NSDocumentController.shared.noteNewRecentDocumentURL(url)
      document.makeWindowControllers()
      if openedImage && settings.closesUnusedUntitledOnImageOpen {
        for existing in NSDocumentController.shared.documents where existing !== document {
          guard let existing = existing as? ProjectDocument,
            existing.isUnusedUntitledDocument
          else { continue }
          existing.close()
        }
      }
      document.showWindows()
    } catch {
      present(error, for: url)
    }
  }

  /// Whether a non-project file belongs on a linked image layer instead of in
  /// the RAW developer. The shared browser classifier checks both the file's
  /// declared type and its extension, and always recognizes camera RAW first.
  static func opensAsOrdinaryImage(_ url: URL) -> Bool {
    let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    return ImageFolderScanner.kind(for: contentType, pathExtension: url.pathExtension)
      == .coreImage
  }

  private func showBrowser(folder: URL) {
    do {
      let controller = try BrowserWindowController(folder: folder) { [weak self] file in
        switch file.kind {
        case .cameraRaw:
          self?.open(file.url)
        case .coreImage:
          if !NSWorkspace.shared.open(file.url) {
            self?.present(
              PixeltjeMacError(
                "Can’t open image",
                "No application accepted \(file.displayName)."
              ),
              for: file.url
            )
          }
        }
      }
      controller.closed = { [weak self] closedController in
        self?.browserControllers.removeAll { $0 === closedController }
      }
      if let previous = browserControllers.last?.window, let window = controller.window {
        window.setFrameTopLeftPoint(
          NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24)
        )
      }
      browserControllers.append(controller)
      controller.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)
    } catch {
      present(error, for: folder)
    }
  }

  private func startScript(at url: URL) {
    let executionID = UUID()
    Task { [weak self] in
      guard let self else { return }
      do {
        let source = try await Self.readScriptSource(at: url)
        let runner = PixeltjeScriptRunner(
          service: automationController,
          clientID: "local-script:\(executionID.uuidString)",
          scopes: [.read, .edit, .jobs]
        )
        activeScriptRunners[executionID] = runner
        defer { activeScriptRunners.removeValue(forKey: executionID) }

        let result = try await runner.run(source: source, sourceName: url.lastPathComponent)
        presentScriptSuccess(result)
      } catch let error as PixeltjeScriptError {
        presentScriptFailure(error)
      } catch {
        presentScriptFailure(
          PixeltjeScriptError(
            kind: .setup,
            message: error.userFacingMessage,
            sourceName: url.lastPathComponent
          )
        )
      }
    }
  }

  nonisolated private static func readScriptSource(at url: URL) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let hasScopedAccess = url.startAccessingSecurityScopedResource()
      defer {
        if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
      }
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true else {
        throw PixeltjeMacError("Invalid script", "The selected item is not a regular file.")
      }
      let maximumByteCount = 2 * 1_024 * 1_024
      guard (values.fileSize ?? 0) <= maximumByteCount else {
        throw PixeltjeMacError(
          "Script too large",
          "Local scripts are limited to 2 MiB."
        )
      }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count <= maximumByteCount, let source = String(data: data, encoding: .utf8) else {
        throw PixeltjeMacError(
          "Invalid script",
          "The selected script must be UTF-8 text no larger than 2 MiB."
        )
      }
      return source
    }.value
  }

  private func presentScriptSuccess(_ result: PixeltjeScriptResult) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Script Finished"
    if let value = result.valueDescription, !value.isEmpty {
      alert.informativeText = "\(result.sourceName)\n\nResult: \(limited(value, to: 2_000))"
    } else {
      alert.informativeText = result.sourceName
    }
    alert.runModal()
  }

  private func presentScriptFailure(_ error: PixeltjeScriptError) {
    let alert = NSAlert()
    alert.alertStyle = error.kind == .cancelled ? .informational : .warning
    alert.messageText = error.kind == .cancelled ? "Script Cancelled" : "Script Failed"
    alert.informativeText = limited(error.userFacingDescription, to: 6_000)
    alert.runModal()
  }

  private func limited(_ value: String, to maximumCount: Int) -> String {
    guard value.count > maximumCount else { return value }
    return String(value.prefix(maximumCount)) + "…"
  }

  private func present(_ error: Error, for url: URL) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Can’t open \(url.lastPathComponent)"
    alert.informativeText = error.userFacingMessage
    alert.runModal()
  }
}

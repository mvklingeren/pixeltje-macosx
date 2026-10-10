import AppKit
import Combine
import PixeltjeModelDesign
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineTextRuntime
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PipelineEditorWindowController: NSWindowController, NSMenuItemValidation, NSWindowDelegate {
  let model: PipelineEditorModel

  private let hostingController: NSHostingController<PipelineEditorView>
  private var observations: Set<AnyCancellable> = []
  private var settingsWindow: NSWindow?
  private var executionLogWindow: NSWindow?
  private var previewWindow: NSWindow?
  private var previewTrackpadNodeID: PipelineNodeID?

  init() {
    let model = PipelineEditorModel(newWorkflowSettings: PipelineNewWorkflowSettings())
    self.model = model
    hostingController = NSHostingController(
      rootView: PipelineEditorView(
        model: model,
        newDocument: {},
        openDocument: {},
        saveDocument: {},
        chooseModelPackage: { _ in },
        chooseImageFile: { _ in },
        chooseVideoFile: { _ in },
        chooseFilePath: { _ in },
        showOutputDirectory: {},
        openGeneratedOutput: { _ in },
        showPreviewFullScreen: { _ in }))
    let window = PipelineEditorWindow(contentViewController: hostingController)
    window.onUnmodifiedEnter = { [weak model] in
      guard let model, model.canUsePrimaryExecutionAction else { return false }
      model.primaryExecutionAction()
      return true
    }
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.setContentSize(NSSize(width: 1_260, height: 780))
    window.minSize = NSSize(width: 940, height: 620)
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    model.requestTrainingPython = { [weak self] in
      self?.chooseTrainingPython(runAfterSelection: true)
    }

    hostingController.rootView = PipelineEditorView(
      model: model,
      newDocument: { [weak self] in self?.newDocument(nil) },
      openDocument: { [weak self] in self?.openDocument(nil) },
      saveDocument: { [weak self] in self?.saveDocument(nil) },
      chooseModelPackage: { [weak self] nodeID in
        self?.chooseModelPackage(for: nodeID)
      },
      chooseImageFile: { [weak self] nodeID in self?.chooseImageFile(for: nodeID) },
      chooseVideoFile: { [weak self] nodeID in self?.chooseVideoFile(for: nodeID) },
      chooseFilePath: { [weak self] nodeID in self?.chooseFilePath(for: nodeID) },
      showOutputDirectory: { [weak self] in self?.showOutputDirectory() },
      openGeneratedOutput: { [weak self] url in self?.openGeneratedOutput(url) },
      showPreviewFullScreen: { [weak self] nodeID in
        self?.showPreviewFullScreen(for: nodeID)
      })
    model.$document.map(\.name).removeDuplicates()
      .combineLatest(model.$fileURL.removeDuplicates(), model.$isDirty.removeDuplicates())
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.updateWindowTitle() }
      }
      .store(in: &observations)
    updateWindowTitle()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("PipelineEditorWindowController is created programmatically")
  }

  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    if let closingWindow = notification.object as? NSWindow,
      closingWindow === previewWindow {
      if let previewTrackpadNodeID {
        model.endTrackpadEdit(for: previewTrackpadNodeID)
        self.previewTrackpadNodeID = nil
      }
      model.setFullScreenPreviewNode(nil)
      previewWindow = nil
      return
    }
    model.cancelExecution()
    previewWindow?.close()
  }

  private func showPreviewFullScreen(for nodeID: PipelineNodeID) {
    guard model.nodeImagePreviews[nodeID] != nil
      || (model.liveMetalPreviewNodeID == nodeID && model.liveMetalPreviewSize != nil)
    else { return }
    previewWindow?.close()
    let trackpadNodeID = model.trackpadNodeID(forGPUProgramPreview: nodeID)
    let preview = PipelineFullScreenPreviewWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    preview.canCloseOnEnter = { [weak model] in model?.isRunning == false }
    let isGPUProgram = model.document.nodes.contains {
      $0.id == nodeID && $0.kind == .gpuProgram
    }
    let fpsHUD = PipelinePreviewFPSHUD()
    if isGPUProgram {
      preview.onUnmodifiedF = { fpsHUD.showsFPS.toggle() }
    }
    preview.onUnmodifiedSpace = { [weak model] in
      guard let model, let trackpadNodeID,
        model.canTriggerTrackpadAction(for: trackpadNodeID) else { return false }
      model.triggerTrackpadAction(for: trackpadNodeID)
      return true
    }
    preview.title = "Pipeline Image Preview"
    preview.collectionBehavior.insert(.fullScreenPrimary)
    preview.isReleasedWhenClosed = false
    preview.delegate = self
    preview.contentViewController = NSHostingController(rootView:
      PipelineFullScreenPreviewView(
        model: model, nodeID: nodeID, trackpadNodeID: trackpadNodeID,
        isGPUProgram: isGPUProgram, fpsHUD: fpsHUD))
    preview.center()
    previewWindow = preview
    previewTrackpadNodeID = trackpadNodeID
    model.setFullScreenPreviewNode(nodeID)
    preview.makeKeyAndOrderFront(nil)
    preview.toggleFullScreen(nil)
  }

  func open(_ url: URL) {
    do {
      if url.lastPathComponent.hasSuffix(".pixmodel.json") {
        try model.importLegacyModelDesign(url)
      } else {
        try model.open(url)
      }
      updateWindowTitle()
    } catch {
      present(error)
    }
  }

  @objc func newDocument(_ sender: Any?) {
    do {
      try model.createNewDocument()
      updateWindowTitle()
    } catch {
      present(error)
    }
  }

  @objc func chooseTrainingPython(_ sender: Any?) {
    chooseTrainingPython(runAfterSelection: false)
  }

  private func chooseTrainingPython(runAfterSelection: Bool) {
    let panel = NSOpenPanel()
    panel.title = "Choose Training Python"
    panel.message = "Select a virtual environment folder, or a Python executable with the training packages installed."
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    guard panel.runModal() == .OK, let selection = panel.url else { return }
    var isDirectory: ObjCBool = false
    let isEnvironment = FileManager.default.fileExists(
      atPath: selection.path, isDirectory: &isDirectory) && isDirectory.boolValue
    let url = isEnvironment
      ? selection.appendingPathComponent("bin/python") : selection
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      present(ModelWorkflowError.invalid(
        "Choose a Python executable or a virtual environment containing bin/python."))
      return
    }
    model.setTrainingPython(url)
    if runAfterSelection { model.run() }
  }

  @objc func exportModelPython(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.title = "Export Python Training Project"
    panel.nameFieldStringValue = "model-training"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let design = try ModelWorkflowBridge.design(in: model.document)
      try ModelPythonExporter.export(design, workflow: model.document, to: url)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch { present(error) }
  }

  @objc func showSettings(_ sender: Any?) {
    if settingsWindow == nil {
      let content = PipelineNewWorkflowSettingsView(
        settings: model.newWorkflowSettings,
        chooseWorkflow: { [weak self] in self?.chooseNewWorkflow() })
      let window = NSWindow(contentViewController: NSHostingController(rootView: content))
      window.title = "Pipeline Settings"
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.isReleasedWhenClosed = false
      window.center()
      settingsWindow = window
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc func showExecutionLog(_ sender: Any?) {
    if executionLogWindow == nil {
      let content = PipelineExecutionLogView(model: model,
        openFile: { [weak self] in self?.openExecutionLogFile() })
      let window = NSWindow(contentViewController: NSHostingController(rootView: content))
      window.title = "Execution Log"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.setContentSize(NSSize(width: 900, height: 600))
      window.minSize = NSSize(width: 600, height: 400)
      window.isReleasedWhenClosed = false
      window.center()
      executionLogWindow = window
    }
    executionLogWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func openExecutionLogFile() {
    let panel = NSOpenPanel()
    panel.title = "Open Execution Log"
    panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.openTrace(url)
  }

  private func chooseNewWorkflow() {
    let panel = NSOpenPanel()
    panel.title = "Choose New Workflow"
    panel.message = "Choose a .pixpipeline.json file to use as the starting point for New."
    panel.prompt = "Choose"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try model.newWorkflowSettings.select(url)
    } catch {
      present(error)
    }
  }

  @objc func newNativeNodeDocument(_ sender: Any?) {
    model.createNewNativeNodeDocument()
    updateWindowTitle()
  }

  @objc func newNativeZImageDocument(_ sender: Any?) {
    model.createNewNativeZImageDocument()
    updateWindowTitle()
  }

  @objc func openDocument(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Open Pipeline or Model Design"
    panel.prompt = "Open"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    open(url)
  }

  @objc func showExampleWorkflows(_ sender: Any?) {
    openBundledResource("Examples")
  }

  @objc func openKlein9BModelSetupGuide(_ sender: Any?) {
    openBundledResource("ModelSetup/Model-Setup-Guide.html")
  }

  private func openBundledResource(_ path: String) {
    let sourceTreeURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(path)
    let candidates = [Bundle.main.resourceURL?.appendingPathComponent(path), sourceTreeURL]
    guard let url = candidates.compactMap({ $0 }).first(where: {
      FileManager.default.fileExists(atPath: $0.path)
    })
    else {
      present(NSError(domain: "PixeltjePipeline", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Bundled resource is missing: \(path)"]))
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc func importComfyUIWorkflow(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Import ComfyUI Workflow"
    panel.message = "Choose a regular ComfyUI frontend workflow JSON file."
    panel.prompt = "Choose"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let choice = NSAlert()
    choice.messageText = "How should recognized ComfyUI nodes be imported?"
    choice.informativeText =
      "Lossless import preserves every node as an editable placeholder. Mapping additionally converts only nodes with an unambiguous Pixeltje equivalent. Model availability is not checked during import."
    choice.addButton(withTitle: "Import Losslessly")
    choice.addButton(withTitle: "Import and Map Nodes")
    choice.addButton(withTitle: "Cancel")
    let response = choice.runModal()
    guard response != .alertThirdButtonReturn else { return }

    do {
      try model.importComfyUI(url, mapNodes: response == .alertSecondButtonReturn)
      updateWindowTitle()
    } catch {
      present(error)
    }
  }

  @objc func saveDocument(_ sender: Any?) {
    if let fileURL = model.fileURL {
      save(to: fileURL)
    } else {
      saveDocumentAs(sender)
    }
  }

  @objc func saveDocumentAs(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.title = "Save Pipeline"
    panel.prompt = "Save"
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = model.displayName + ".pixpipeline.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    save(to: url)
  }

  @objc func validateDocument(_ sender: Any?) {
    model.validate()
  }

  @objc func undoGraphEdit(_ sender: Any?) {
    model.undo()
  }

  @objc func redoGraphEdit(_ sender: Any?) {
    model.redo()
  }

  @objc func deleteGraphSelection(_ sender: Any?) {
    model.deleteSelection()
  }

  @objc func toggleNodeLibrary(_ sender: Any?) {
    model.toggleNodeLibrary()
  }

  @objc func toggleInspector(_ sender: Any?) {
    model.toggleInspector()
  }

  @objc func arrangeNodesLeftToRight(_ sender: Any?) {
    model.arrangeNodes(.leftToRight)
  }

  @objc func arrangeNodesTopToBottom(_ sender: Any?) {
    model.arrangeNodes(.topToBottom)
  }

  @objc func arrangeNodesInGrid(_ sender: Any?) {
    model.arrangeNodes(.grid)
  }

  @objc func arrangeNodesInSmartFlow(_ sender: Any?) {
    model.arrangeNodes(.smartFlow)
  }

  @objc func fitWorkflow(_ sender: Any?) {
    model.fitWorkflow()
  }

  private func chooseModelPackage(for requestedNodeID: PipelineNodeID?) {
    let node = requestedNodeID.flatMap { requestedID in
      model.modelPackageNodes.first { $0.id == requestedID }
    }
    guard model.modelPackageNodes.isEmpty || node != nil else { return }
    let panel = NSOpenPanel()
    let profileName = node?.title ?? model.executionProfile?.displayName ?? "Core AI"
    panel.title = model.isBaseTestSetExecution
      ? "Choose Source Media Folder" : "Choose \(profileName) Package"
    panel.message = model.isBaseTestSetExecution
      ? "Choose the folder containing this graph's local source files."
      : node?.kind == CoreAITextPipelineFamily.compositeNodeKind
        ? "Choose a language-model bundle containing metadata.json, an embedded tokenizer, and a .aimodel or .aimodelc asset."
        : node?.kind == .coreAIImageClassifier
          ? "Choose the trained image classifier's .aimodel package. The workflow saves its identity, not this path."
        : "Choose the package directory that contains the model resources."
    panel.prompt = "Choose"
    panel.canChooseDirectories = true
    panel.canChooseFiles = node?.kind == .coreAIImageClassifier
    panel.allowsMultipleSelection = false
    let startingURL = node.flatMap(model.packageURL(for:)) ?? model.modelPackageURL
    panel.directoryURL = node?.kind == .coreAIImageClassifier
      && startingURL.pathExtension.isEmpty
      ? startingURL : startingURL.deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.setModelPackageURL(url, for: node?.id)
  }

  func chooseImageFile(for nodeID: PipelineNodeID) {
    let panel = NSOpenPanel()
    panel.title = "Choose Source Image"
    panel.message = "Choose the image file for this pipeline input."
    panel.prompt = "Choose"
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = model.selectedImageURLs[nodeID]?.deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.setImageFile(url, for: nodeID)
  }

  func chooseVideoFile(for nodeID: PipelineNodeID) {
    let panel = NSOpenPanel()
    panel.title = "Choose Source Video"
    panel.message = "Choose the video file for this pipeline input."
    panel.prompt = "Choose"
    panel.allowedContentTypes = [.movie]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = model.selectedImageURLs[nodeID]?.deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.setVideoFile(url, for: nodeID)
  }

  func chooseFilePath(for nodeID: PipelineNodeID) {
    let panel = NSOpenPanel()
    panel.title = "Choose File Path"
    panel.message = "Choose the file represented by this node. Relative paths use the pipeline source folder."
    panel.prompt = "Choose"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = model.filePathChooserDirectoryURL
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.setFilePath(url, for: nodeID)
  }

  func showOutputDirectory() {
    do {
      try model.ensureOutputDirectoryExists()
      guard NSWorkspace.shared.open(model.currentOutputDirectoryURL) else {
        throw CocoaError(.fileNoSuchFile)
      }
    } catch {
      present(error)
    }
  }

  func openGeneratedOutput(_ outputURL: URL) {
    guard FileManager.default.fileExists(atPath: outputURL.path)
    else {
      present(PipelineEditorError.generatedOutputUnavailable)
      return
    }
    if outputURL.pathExtension.lowercased() == "aimodel" {
      NSWorkspace.shared.activateFileViewerSelecting([outputURL])
      return
    }
    let applicationID: String
    switch outputURL.pathExtension.lowercased() {
    case "png": applicationID = "com.apple.Preview"
    case "mp4": applicationID = "com.apple.QuickTimePlayerX"
    default:
      if !NSWorkspace.shared.open(outputURL) {
        present(PipelineEditorError.generatedOutputUnavailable)
      }
      return
    }
    guard let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: applicationID)
    else {
      if !NSWorkspace.shared.open(outputURL) {
        present(PipelineEditorError.generatedOutputUnavailable)
      }
      return
    }

    NSWorkspace.shared.open(
      [outputURL],
      withApplicationAt: applicationURL,
      configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] _, error in
      guard let error else { return }
      DispatchQueue.main.async {
        self?.present(error)
      }
    }
  }

  @objc func runPipeline(_ sender: Any?) {
    model.primaryExecutionAction()
  }

  @objc func cancelPipeline(_ sender: Any?) {
    model.cancelExecution()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(exportModelPython(_:)):
      return model.isModelTraining && !model.isRunning
    case #selector(undoGraphEdit(_:)):
      menuItem.title = model.undoActionName.isEmpty ? "Undo" : "Undo \(model.undoActionName)"
      return model.canUndo
    case #selector(redoGraphEdit(_:)):
      menuItem.title = model.redoActionName.isEmpty ? "Redo" : "Redo \(model.redoActionName)"
      return model.canRedo
    case #selector(deleteGraphSelection(_:)):
      return model.selection != nil
    case #selector(runPipeline(_:)):
      menuItem.title = "\(model.primaryExecutionTitle) Pipeline"
      return model.canUsePrimaryExecutionAction
    case #selector(cancelPipeline(_:)):
      return model.isRunning && model.executionState != .cancelling
    case #selector(toggleNodeLibrary(_:)):
      menuItem.title = model.isNodeLibraryVisible ? "Hide Node Library" : "Show Node Library"
      return true
    case #selector(toggleInspector(_:)):
      menuItem.title = model.isInspectorVisible ? "Hide Inspector" : "Show Inspector"
      return true
    case #selector(arrangeNodesInSmartFlow(_:)), #selector(arrangeNodesLeftToRight(_:)),
      #selector(arrangeNodesTopToBottom(_:)),
      #selector(arrangeNodesInGrid(_:)):
      return model.canArrangeNodes
    case #selector(fitWorkflow(_:)):
      return model.canFitWorkflow
    default:
      return true
    }
  }

  private func save(to url: URL) {
    do {
      _ = try model.save(to: url)
      updateWindowTitle()
    } catch {
      present(error)
    }
  }

  private func updateWindowTitle() {
    window?.title = model.windowTitle
    window?.representedURL = model.fileURL
    window?.isDocumentEdited = model.isDirty
  }

  private func present(_ error: any Error) {
    let alert = NSAlert(error: error)
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }
}

private struct PipelineFullScreenPreviewView: View {
  @ObservedObject var model: PipelineEditorModel
  let nodeID: PipelineNodeID
  let trackpadNodeID: PipelineNodeID?
  let isGPUProgram: Bool
  @ObservedObject var fpsHUD: PipelinePreviewFPSHUD

  var body: some View {
    GeometryReader { geometry in
      let liveSize = model.liveMetalPreviewNodeID == nodeID
        ? model.liveMetalPreviewSize : nil
      let livePreview = liveSize == nil ? nil : model.livePreview
      let image = liveSize == nil
        ? (model.fullScreenPreviewImage ?? model.nodeImagePreviews[nodeID]) : nil
      let imageSize = liveSize ?? image?.size
      ZStack {
        Color.black.ignoresSafeArea()
        if let imageSize {
          let fittedSize = Self.fittedSize(imageSize, in: geometry.size)
          if let trackpadNodeID,
            let position = model.trackpadPosition(for: trackpadNodeID) {
            PipelineTrackpadView(
              image: image,
              livePreview: livePreview,
              overlay: nil,
              x: position.x,
              y: position.y,
              showsControls: false,
              isEnabled: model.canEditTrackpad,
              beginEditing: { model.beginTrackpadEdit(for: trackpadNodeID) },
              setPosition: { x, y in
                model.setTrackpadPosition(x: x, y: y, for: trackpadNodeID)
              },
              endEditing: { model.endTrackpadEdit(for: trackpadNodeID) })
              .frame(width: fittedSize.width, height: fittedSize.height)
          } else if let livePreview {
            PipelineMetalPreviewSurfaceView(presenter: livePreview)
              .frame(width: fittedSize.width, height: fittedSize.height)
          } else if let image {
            Image(nsImage: image)
              .resizable()
              .interpolation(.high)
              .frame(width: fittedSize.width, height: fittedSize.height)
          }
        } else {
          ContentUnavailableView("No preview yet", systemImage: "photo")
        }
        if let trackpadNodeID, model.canTriggerTrackpadAction(for: trackpadNodeID) {
          VStack {
            Spacer()
            HStack {
              Spacer()
              Button("Action") { model.triggerTrackpadAction(for: trackpadNodeID) }
                .buttonStyle(.borderedProminent)
                .help("Press Space or click to trigger the connected action")
            }
          }
          .padding(32)
        }
        if isGPUProgram && fpsHUD.showsFPS {
          VStack {
            HStack {
              Spacer()
              Text("\(fpsHUD.framesPerSecond) FPS")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.3, green: 1, blue: 0.2))
                .shadow(color: .black, radius: 3)
            }
            Spacer()
          }
          .padding(32)
          .allowsHitTesting(false)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .task(id: fpsHUD.showsFPS) {
      guard isGPUProgram, fpsHUD.showsFPS else { return }
      while !Task.isCancelled {
        fpsHUD.refresh(from: model.livePreview)
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  private static func fittedSize(_ image: CGSize, in available: CGSize) -> CGSize {
    guard image.width > 0, image.height > 0 else { return .zero }
    let width = max(available.width - 48, 0)
    let height = max(available.height - 48, 0)
    let scale = min(width / image.width, height / image.height)
    return CGSize(width: image.width * scale, height: image.height * scale)
  }
}

@MainActor
private final class PipelinePreviewFPSHUD: ObservableObject {
  @Published var showsFPS = false
  @Published private(set) var framesPerSecond = 0

  /// Reads the completed-frame count without waking the editor per frame.
  func refresh(from presenter: PipelineLivePreviewPresenter) {
    let rate = presenter.framesPerSecond
    if framesPerSecond != rate { framesPerSecond = rate }
  }
}

@MainActor
private final class PipelineFullScreenPreviewWindow: NSWindow {
  var canCloseOnEnter: (() -> Bool)?
  var onUnmodifiedF: (() -> Void)?
  var onUnmodifiedSpace: (() -> Bool)?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, !event.isARepeat,
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
      if event.charactersIgnoringModifiers?.lowercased() == "f", let onUnmodifiedF {
        onUnmodifiedF()
        return
      }
      if event.keyCode == 49, onUnmodifiedSpace?() == true {
        return
      }
      if event.keyCode == 53 ||
        ((event.keyCode == 36 || event.keyCode == 76) && canCloseOnEnter?() == true) {
        close()
        return
      }
    }
    super.sendEvent(event)
  }
}

@MainActor
private final class PipelineEditorWindow: NSWindow {
  var onUnmodifiedEnter: (() -> Bool)?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown,
      (event.keyCode == 36 || event.keyCode == 76),
      !event.isARepeat,
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
      !(firstResponder is NSTextView),
      !(firstResponder is NSTextField),
      onUnmodifiedEnter?() == true
    {
      return
    }
    super.sendEvent(event)
  }
}

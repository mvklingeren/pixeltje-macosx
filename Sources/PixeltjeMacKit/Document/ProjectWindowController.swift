import AppKit
import Combine
import PixeltjeMacDomain
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class ProjectWindowController: NSWindowController, NSWindowDelegate,
  NSMenuItemValidation, NSToolbarDelegate
{
  private let projectDocument: ProjectDocument
  private let canvasController: CanvasViewController
  /// The left panel's section registry. Features install their own section here
  /// rather than editing this controller's layout; see `PanelModel`.
  let leftPanelModel = PanelModel()
  /// The pixel-layer development panel's section registry. Its host makes the
  /// panel unavailable unless the active layer is RAW, a linked image, or paint.
  let developPanelModel = PanelModel()
  /// The assistance panel's registry: how the work is going — the edit record
  /// and the background queues — as opposed to the tool in hand on the left or
  /// the document itself on the right.
  let assistancePanelModel = PanelModel()
  private var leftPanelItem: NSSplitViewItem?
  private var rightPanelItem: NSSplitViewItem?
  private var toolBeforeGenerate: EditorTool?
  private var rightPanelWasCollapsedBeforeGenerate: Bool?
  private var developPanelItem: NSSplitViewItem?
  private var assistancePanelItem: NSSplitViewItem?
  private var renderProgressToolbarItem: NSToolbarItem?
  private var rawDecoderToolbarItem: NSToolbarItem?
  private var rawDecoderToolbarLabel: NSTextField?
  private let renderProgressIndicator = NSProgressIndicator()
  private var subscriptions: Set<AnyCancellable> = []
  /// Export presets are shared by every window, so the store is the app's one.
  private let presetStore = ExportPresetStore.shared
  private var exportPopup: NSViewController?
  private var exportPopupModel: ExportPopupModel?
  /// The document's own fullscreen preview, while one is up.
  private var fullscreenPreview: FullscreenPreviewWindowController?
  private var maximizesOnFirstShow = true

  var hasUnsubmittedPrompt: Bool { canvasController.promptBoxModel.hasUnsubmittedPrompt }

  init(projectDocument: ProjectDocument) {
    self.projectDocument = projectDocument
    self.canvasController = CanvasViewController(
      model: projectDocument.editorModel,
      send: {
      [weak projectDocument] intent in
      guard let projectDocument else { return }
      switch intent {
      case .beginGesture:
        projectDocument.beginEditGesture()
      case .change(let action, let interactive):
        projectDocument.perform(action, interactive: interactive)
      case .endGesture(let name):
        projectDocument.endEditGesture(actionName: name)
      case .sampleWhiteBalance(let x, let y, let keepArmed):
        projectDocument.sampleWhiteBalance(atNormalizedX: x, y: y, keepArmed: keepArmed)
      case .sampleForegroundColor(let x, let y, let keepArmed):
        projectDocument.sampleForegroundColor(atNormalizedX: x, y: y, keepArmed: keepArmed)
      case .previewSample(let x, let y):
        projectDocument.previewWhiteBalanceSample(atNormalizedX: x, y: y)
      case .cancelSample:
        projectDocument.cancelPendingSample()
      case .updateCropDraft(let draft, let interactive):
        projectDocument.updateCropDraft(draft, interactive: interactive)
      case .commitCrop:
        projectDocument.commitCropDraft()
      case .cancelCrop:
        projectDocument.cancelCropDraft()
      case .updateTransformDraft(let transform):
        projectDocument.updateTransformDraft(transform)
      case .commitTransform:
        projectDocument.commitTransformDraft()
      case .cancelTransform:
        projectDocument.cancelTransformDraft()
      case .activateMask(let maskID, let layerID):
        projectDocument.editorModel.activateMask(maskID, on: layerID)
      case .updateSelectionDraft(let draft):
        projectDocument.updateSelectionDraft(draft)
      case .commitSelection(let selection, let name):
        projectDocument.commitSelection(selection, actionName: name)
      case .cancelSelectionDraft:
        projectDocument.cancelSelectionDraft()
      case .applyMagnetSelection(let point, let combine):
        projectDocument.applyMagnetSelection(at: point, combine: combine)
      case .beginSelectionBrushStroke(let sample, let combine):
        projectDocument.beginSelectionBrushStroke(with: sample, combine: combine)
      case .beginBrushStroke(let sample):
        projectDocument.beginBrushStroke(with: sample)
      case .appendBrushSamples(let samples):
        projectDocument.appendBrushSamples(samples)
      case .commitBrushStroke:
        projectDocument.commitBrushStroke()
      case .commitSelectionBrushStroke:
        projectDocument.commitSelectionBrushStroke()
      case .cancelBrushStroke:
        projectDocument.cancelBrushStroke()
      case .adjustBrushSize(let increasing):
        projectDocument.editorModel.adjustActiveBrushSize(increasing: increasing)
      case .commitHeal:
        projectDocument.commitHealStroke()
      case .setHealSource(let x, let y):
        projectDocument.editorModel.setHealSourceAnchor(VectorPoint(x: x, y: y))
      case .commitGradient(let layerID, let start, let end):
        projectDocument.commitGradient(from: start, to: end, editing: layerID)
      case .applyFill(let point):
        projectDocument.applyFill(at: point)
      case .commitShape(let start, let end, let constrained, let fromCenter):
        projectDocument.commitShape(
          from: start, to: end, constrained: constrained, fromCenter: fromCenter)
      case .selectLayer(let id):
        projectDocument.selectLayers([id])
      case .deleteVectorObjects:
        projectDocument.deleteVectorObjects()
      case .setVectorObjectSelection(let ids):
        projectDocument.editorModel.setSelectedVectorObjects(ids)
      }
    }, generate: { [weak projectDocument] prompt in
      projectDocument?.startGenerationFromUI(prompt: prompt)
    }, cancelGeneration: { [weak projectDocument] in
      projectDocument?.cancelActiveGeneration()
    }, updateGenerationSettings: { [weak projectDocument] settings in
      projectDocument?.editorModel.setInpaintingTool(settings)
    }, clearComfyUIDebugEvents: { [weak projectDocument] in
      projectDocument?.editorModel.clearComfyUIDebugEvents()
    }, setComfyUIDebugDiskLoggingEnabled: { [weak projectDocument] enabled in
      projectDocument?.setComfyUIDebugDiskLoggingEnabled(enabled)
    }, revealComfyUIDebugLog: { [weak projectDocument] in
      projectDocument?.revealComfyUIDebugLog()
    }, applyComfyUIResultAnyway: { [weak projectDocument] jobID in
      projectDocument?.applyComfyUIResultAnyway(jobID: jobID)
    }, selectGenerationMode: { [weak projectDocument] mode in
      projectDocument?.selectComfyUIWorkflow(
        AppSettings.storedDefaultComfyUIWorkflowID(for: mode), expectedMode: mode)
    }, selectGenerationMaskSource: { [weak projectDocument] source in
      projectDocument?.editorModel.setGenerationMaskSource(source)
    }, selectExecutionTarget: { [weak projectDocument] target in
      projectDocument?.selectComfyUIExecutionTarget(target)
    }, selectContentTag: { [weak projectDocument] _ in
      projectDocument?.selectComfyUIWorkflow(
        AppSettings.storedDefaultComfyUIWorkflowID(for: .selection), expectedMode: .selection)
    }, applySelectionPreview: { [weak projectDocument] in
      projectDocument?.applyComfyUISelectionPreview()
    }, discardSelectionPreview: { [weak projectDocument] in
      projectDocument?.discardComfyUISelectionPreview()
    })

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1420, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.titleVisibility = .visible
    window.toolbarStyle = .unified
    window.tabbingMode = .preferred
    window.isReleasedWhenClosed = false

    super.init(window: window)
    canvasController.onPromptBoxVisibilityChange = { [weak self] visible in
      self?.setComfyUIOptionsVisible(visible)
      self?.projectDocument.setSubjectTagSuggestionsEnabled(visible)
      if !visible { self?.finishGeneratePresentation() }
    }
    window.delegate = self
    window.toolbar = makeToolbar()
    window.setFrameAutosaveName("PixeltjeMacDocumentWindow")
    installContent()
    observeModel()
    updateTitle()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("ProjectWindowController is created programmatically")
  }

  public override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    guard maximizesOnFirstShow, let window else { return }
    maximizesOnFirstShow = false
    if !window.isZoomed {
      window.zoom(nil)
    }
  }

  /// Hands the window this document's undo manager.
  ///
  /// Edit ▸ Undo and Edit ▸ Redo have no target: AppKit resolves `undo:` and
  /// `redo:` through the window's undo manager, which is also what validates
  /// the two items and names them after the step they will take back. Stating
  /// it here keeps that routing independent of what the delegate inherits.
  public func windowDidBecomeMain(_ notification: Notification) {
    ColorPanelPalette.shared.setSampledColors(projectDocument.editorModel.sampledPalette)
  }

  public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
    projectDocument.undoManager
  }

  @objc public func zoomToFit(_ sender: Any?) {
    canvasController.canvas.zoomToFit()
  }

  @objc public func zoomToActualSize(_ sender: Any?) {
    canvasController.canvas.zoomToActualSize()
  }

  @objc public func zoomIn(_ sender: Any?) {
    canvasController.canvas.zoomIn()
  }

  @objc public func zoomOut(_ sender: Any?) {
    canvasController.canvas.zoomOut()
  }

  @objc public func activateNavigateTool(_ sender: Any?) {
    activate(.navigate)
  }

  @objc public func activateMoveTool(_ sender: Any?) {
    activate(.move)
  }

  @objc public func activateTransformTool(_ sender: Any?) {
    if activate(.transform) {
      projectDocument.beginTransformSession()
    }
  }

  @objc public func activateMarqueeTool(_ sender: Any?) {
    activate(.marquee)
  }

  @objc public func activateLassoTool(_ sender: Any?) {
    activate(.lasso)
  }

  @objc public func activateMagnetSelectionTool(_ sender: Any?) {
    activate(.magnetSelection)
  }

  @objc public func activateSelectionBrushTool(_ sender: Any?) {
    activate(.selectionBrush)
  }

  @objc public func activateCropTool(_ sender: Any?) {
    activate(.crop)
  }

  @objc public func activateBrushTool(_ sender: Any?) {
    activate(.brush)
  }

  @objc public func activateEraserTool(_ sender: Any?) {
    activate(.eraser)
  }

  @objc public func decreaseBrushSize(_ sender: Any?) {
    projectDocument.editorModel.adjustActiveBrushSize(increasing: false)
  }

  @objc public func increaseBrushSize(_ sender: Any?) {
    projectDocument.editorModel.adjustActiveBrushSize(increasing: true)
  }

  @objc public func activateHealTool(_ sender: Any?) {
    activate(.heal)
  }

  @objc public func activatePenTool(_ sender: Any?) {
    activate(.pen)
  }

  @objc public func activateShapeTool(_ sender: Any?) { activate(.shape) }

  @objc public func activateGradientTool(_ sender: Any?) { activate(.gradient) }

  @objc public func activateFillTool(_ sender: Any?) { activate(.fill) }

  @objc public func activateTextTool(_ sender: Any?) {
    activate(.text)
  }

  @objc public func activateGenerateTool(_ sender: Any?) {
    if canvasController.isPromptBoxVisible {
      canvasController.setPromptBoxVisible(false)
      return
    }
    let currentTool = projectDocument.editorModel.activeTool
    toolBeforeGenerate = currentTool == .generate ? .navigate : currentTool
    rightPanelWasCollapsedBeforeGenerate = rightPanelItem?.isCollapsed
    activate(.generate)
    leftPanelItem?.isCollapsed = true
    rightPanelItem?.animator().isCollapsed = true
    canvasController.setPromptBoxVisible(true)
  }

  private func finishGeneratePresentation() {
    guard let previousTool = toolBeforeGenerate else { return }
    toolBeforeGenerate = nil
    if projectDocument.editorModel.activeTool == .generate {
      activate(previousTool)
    }
    if rightPanelWasCollapsedBeforeGenerate == false, rightPanelItem?.isCollapsed == true {
      rightPanelItem?.animator().isCollapsed = false
    }
    rightPanelWasCollapsedBeforeGenerate = nil
  }

  /// Switches tools, or toggles the current tool's settings panel on reselect.
  /// Opens and closes the crop session around a tool change.
  ///
  /// Leaving the Crop tool commits what the user has set up, the way a tool
  /// change does elsewhere: the commit is one undoable step, so nothing is lost
  /// silently. Escape on the canvas is still the way to abandon a crop.
  @discardableResult
  private func activate(_ tool: EditorTool) -> Bool {
    let model = projectDocument.editorModel
    if model.activeTool == tool {
      // Repeating a tool command toggles its settings; tools without settings
      // can only close the panel, never open an empty one.
      if tool.hasToolSettings {
        toggleLeftPanel(nil)
      } else {
        leftPanelItem?.animator().isCollapsed = true
      }
      window?.makeFirstResponder(canvasController.canvas)
      return false
    }
    let isLeavingCrop = model.activeTool == .crop && tool != .crop
    let isLeavingTransform = model.activeTool == .transform && tool != .transform
    model.setActiveTool(tool)
    if isLeavingCrop {
      // Change the active tool first so committing does not resume the
      // persistent Crop session that is being left.
      projectDocument.commitCropDraft()
    }
    if isLeavingTransform {
      projectDocument.cancelTransformDraft()
    }
    if tool == .crop {
      projectDocument.beginCropSession()
    }
    window?.makeFirstResponder(canvasController.canvas)
    return true
  }

  /// Arms the white-balance picker over whatever tool is active.
  ///
  /// Not a tool activation: the request takes the cursor and the next canvas
  /// click, and the tool underneath is untouched. The canvas is made first
  /// responder so the click and the Escape that withdraws it both land.
  @objc public func pickWhiteBalance(_ sender: Any?) {
    projectDocument.armWhiteBalanceSample()
    window?.makeFirstResponder(canvasController.canvas)
  }

  @objc public func pickForegroundColor(_ sender: Any?) {
    if projectDocument.editorModel.pendingSample?.purpose == .foregroundColor {
      projectDocument.cancelPendingSample()
      return
    }
    projectDocument.armForegroundColorSample()
    window?.makeFirstResponder(canvasController.canvas)
  }

  @objc public func swapForegroundAndBackgroundColors(_ sender: Any?) {
    handle(ColorWorkflowIntent.swap)
  }

  @objc public func resetForegroundAndBackgroundColors(_ sender: Any?) {
    handle(ColorWorkflowIntent.reset)
  }

  /// The one route every color control takes. It runs through the document
  /// because the shared pair reaches the selected vector objects and the text
  /// layer being edited, not only the defaults for the next thing created.
  func handle(_ intent: ColorWorkflowIntent) {
    switch intent {
    case .setForeground(let color): projectDocument.setForegroundColor(color)
    case .setBackground(let color): projectDocument.setBackgroundColor(color)
    case .swap: projectDocument.swapForegroundAndBackgroundColors()
    case .reset: projectDocument.resetForegroundAndBackgroundColors()
    }
  }

  /// Puts temperature and tint back to the values the file was shot with.
  @objc public func resetWhiteBalanceToAsShot(_ sender: Any?) {
    projectDocument.resetWhiteBalanceToAsShot()
  }

  /// Marks clipped highlights and shadows, or clears both. One key for the pair,
  /// the way a histogram's two corners are usually armed together.
  @objc public func toggleClippingIndicators(_ sender: Any?) {
    projectDocument.toggleClippingIndicators()
  }

  @objc public func toggleBeforeAfter(_ sender: Any?) {
    projectDocument.toggleBeforeAfter()
  }

  /// Removes every guide as one undoable step.
  ///
  /// Guides are recipe state, so this is a document command rather than a view
  /// toggle: it goes through `ProjectDocument` like any other edit.
  @objc public func clearGuides(_ sender: Any?) {
    let settings = projectDocument.editorModel.recipe.canvasSettings
    guard !settings.guides.isEmpty else { return }
    projectDocument.perform(
      .setCanvasSettings(settings.removingAllGuides(), actionName: "Clear Guides"),
      interactive: false
    )
  }

  @objc public func activateMasksTool(_ sender: Any?) {
    let model = projectDocument.editorModel
    guard activate(.masks) else { return }
    // A mask belongs to a layer, so choosing the tool aims it at the layer the
    // layers inspector has selected.
    model.activateMask(model.maskTool.activeMaskID, on: model.recipe.layerStack.activeLayerID)
  }

  // MARK: - Select menu
  //
  // Pixel selections are document edits; vector-object selections are
  // transient editor state shared with the Layers inspector.

  /// Selects objects in the active vector layer under Select/Move, or the
  /// complete canvas for a pixel-selection workflow.
  ///
  /// This is the same selector as `NSText.selectAll(_:)`, which is what lets
  /// Edit ▸ Select All keep ⌘A: a text field that has the keyboard answers it
  /// first, and the canvas gets it only when nothing else claimed it. Menu
  /// validation stands the command down while a text view is first responder.
  /// `NSResponder` already declares this, which is exactly why it works: the
  /// canvas simply becomes another responder that answers it.
  @objc public override func selectAll(_ sender: Any?) {
    if projectDocument.isEditingVectorObjects
      && !projectDocument.editorModel.recipe.hasSelection,
      let vector = projectDocument.editorModel.activeVectorLayer?.vector
    {
      projectDocument.editorModel.setSelectedVectorObjects(Set(vector.objects.map(\.id)))
    } else {
      projectDocument.selectAll()
    }
  }

  @objc public func deselect(_ sender: Any?) {
    if projectDocument.isEditingVectorObjects
      && !projectDocument.editorModel.recipe.hasSelection
      && !projectDocument.editorModel.selectedVectorObjectIDs.isEmpty
    {
      projectDocument.editorModel.clearVectorObjectSelection()
    } else {
      projectDocument.deselect()
    }
  }

  @objc public func reselect(_ sender: Any?) {
    projectDocument.reselect()
  }

  @objc public func invertSelection(_ sender: Any?) {
    projectDocument.invertSelection()
  }

  /// Hands the active selection to the selected layer as an ordinary mask.
  @objc public func saveSelectionAsMask(_ sender: Any?) {
    projectDocument.saveSelectionAsMask()
  }

  // MARK: - Edit menu clipboard
  //
  // `NSResponder` declares `selectAll(_:)` but none of these, so they are plain
  // actions rather than overrides. They still reach the canvas the same way:
  // through the responder chain, with menu validation standing them down while
  // a text field has the keyboard so a field keeps its own clipboard.

  // A standing pixel selection wins over a vector-object selection. Without
  // one, Select/Move uses the selected objects in the active vector layer.

  private var usesVectorObjectClipboard: Bool {
    projectDocument.isEditingVectorObjects
      && !projectDocument.editorModel.recipe.hasSelection
  }

  @objc public func copy(_ sender: Any?) {
    if usesVectorObjectClipboard {
      projectDocument.copyVectorObjects()
      return
    }
    projectDocument.copySelection(merged: false)
  }

  /// Copies what is visible rather than what is being worked on.
  @objc public func copyMerged(_ sender: Any?) {
    projectDocument.copySelection(merged: true)
  }

  @objc public func cut(_ sender: Any?) {
    if usesVectorObjectClipboard {
      projectDocument.cutVectorObjects()
      return
    }
    projectDocument.cutSelection(merged: false)
  }

  @objc public func paste(_ sender: Any?) {
    if usesVectorObjectClipboard {
      projectDocument.pasteVectorObjects()
      return
    }
    projectDocument.paste()
  }

  /// Edit ▸ Delete, and the ⌫ behind it.
  @objc public func delete(_ sender: Any?) {
    if usesVectorObjectClipboard && projectDocument.canDeleteVectorObjects {
      projectDocument.deleteVectorObjects()
    } else {
      projectDocument.clearSelection()
    }
  }

  // MARK: - Object menu

  // Arrangement commands are also in the left tool settings; these items give
  // them keyboard access and make them discoverable. Each forwards to the one
  // document operation, so both surfaces record the same history step.

  @objc public func alignVectorObjectsLeft(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.align(.left, alignmentReference))
  }

  @objc public func alignVectorObjectsHorizontalCenter(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.align(.horizontalCenter, alignmentReference))
  }

  @objc public func alignVectorObjectsRight(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.align(.right, alignmentReference))
  }

  @objc public func alignVectorObjectsTop(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.align(.top, alignmentReference))
  }

  @objc public func alignVectorObjectsVerticalMiddle(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.align(.verticalMiddle, alignmentReference))
  }

  @objc public func alignVectorObjectsBottom(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.align(.bottom, alignmentReference))
  }

  @objc public func distributeVectorObjectsHorizontally(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.distribute(.horizontal))
  }

  @objc public func distributeVectorObjectsVertically(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.distribute(.vertical))
  }

  @objc public func reflectVectorObjectsHorizontally(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.reflect(horizontally: true))
  }

  @objc public func reflectVectorObjectsVertically(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.reflect(horizontally: false))
  }

  @objc public func bringVectorObjectsToFront(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.order(.front))
  }

  @objc public func bringVectorObjectsForward(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.order(.forward))
  }

  @objc public func sendVectorObjectsBackward(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.order(.backward))
  }

  @objc public func sendVectorObjectsToBack(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.order(.back))
  }

  @objc public func duplicateVectorObjectsInPlace(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.duplicateInPlace)
  }

  @objc public func moveVectorObjectsToNewLayer(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.moveToNewLayer)
  }

  @objc public func unionVectorObjects(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.boolean(.union))
  }

  @objc public func subtractVectorObjects(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.boolean(.subtract))
  }

  @objc public func intersectVectorObjects(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.boolean(.intersect))
  }

  @objc public func excludeVectorObjects(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.boolean(.exclude))
  }

  @objc public func releaseCompoundPath(_ sender: Any?) {
    projectDocument.arrangeVectorObjects(.releaseCompoundPath)
  }

  /// The reference the left panel's picker is set to, so a menu command lines
  /// objects up against the same thing the buttons do.
  private var alignmentReference: VectorAlignmentReference {
    let stored = UserDefaults.standard.string(forKey: "VectorAlignmentReference")
    let preferred = stored.flatMap(VectorAlignmentReference.init(rawValue:)) ?? .selection
    // One object aligned to itself would not move.
    return projectDocument.editorModel.selectedVectorObjectIDs.count <= 1 ? .canvas : preferred
  }

  @objc public func convertAnchorToCorner(_ sender: Any?) {
    canvasController.canvas.convertSelectedAnchor(to: .corner)
  }

  @objc public func convertAnchorToSmooth(_ sender: Any?) {
    canvasController.canvas.convertSelectedAnchor(to: .smooth)
  }

  @objc public func convertAnchorToSymmetric(_ sender: Any?) {
    canvasController.canvas.convertSelectedAnchor(to: .symmetric)
  }

  @objc public func addImageLayer(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Add Image to Canvas"
    panel.message = "The project links to the image. It is never copied into the project file."
    panel.prompt = "Add"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    panel.allowedContentTypes = ImageLayerFactory.allowedContentTypes
    guard let window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      self?.placeImages(panel.urls)
    }
  }

  /// Opens the advanced, RAW-only placement flow. It is deliberately separate
  /// from Add Image: a RAW always reaches `CIRAWFilter` with its own recipe,
  /// never the generic image loader.
  @objc public func addRawLayer(_ sender: Any?) {
    guard AppSettings.storedAllowsMultipleRawLayers() else { return }
    let panel = NSOpenPanel()
    panel.title = "Add RAW Layer"
    panel.message = "Each RAW stays linked and is developed independently. For ordinary compositing, develop a RAW first and add its JPEG, TIFF, or PNG output instead."
    panel.prompt = "Add RAW"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    panel.allowedContentTypes = [ImageFolderScanner.cameraRawType]
    guard let window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      self?.placeRawLayers(panel.urls)
    }
  }

  private func placeImages(_ urls: [URL]) {
    for url in urls {
      do {
        try projectDocument.placeImage(at: url)
      } catch {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can’t place \(url.lastPathComponent)"
        alert.informativeText = error.userFacingMessage
        alert.runModal()
        return
      }
    }
  }

  private func placeRawLayers(_ urls: [URL]) {
    for url in urls {
      do {
        try projectDocument.placeRaw(at: url)
      } catch {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can’t place (url.lastPathComponent) as RAW"
        alert.informativeText = error.userFacingMessage
        alert.runModal()
        return
      }
    }
  }

  /// File ▸ Export…: the preset popup, not a bare save panel.
  ///
  /// The popup decides what to export; the work then goes to the document's
  /// background queue, which the left panel shows.
  @objc public func exportDocument(_ sender: Any?) {
    guard exportPopup == nil else { return }
    let popupModel = ExportPopupModel(destination: presetStore.lastDestination)
    self.exportPopupModel = popupModel
    let view = ExportPopupView(
      store: presetStore,
      popup: popupModel,
      originalName: projectDocument.exportSourceName,
      previewSequence: presetStore.upcomingSequenceNumber
    ) { [weak self] intent in
      guard let self else { return }
      switch intent {
      case .chooseDestination:
        self.chooseExportDestination()
      case .export(let preset, let destination):
        self.startExport(preset: preset, destination: destination)
      case .cancel:
        self.dismissExportPopup()
      }
    }
    let controller = NSHostingController(rootView: view)
    exportPopup = controller
    contentViewController?.presentAsSheet(controller)
  }

  private func chooseExportDestination() {
    let panel = NSOpenPanel()
    panel.title = "Export To"
    panel.message = "Choose the folder exported files are written to."
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = exportPopupModel?.destination
    // The popup is itself a sheet, so the chooser hangs off it rather than off
    // the window behind it.
    guard let host = exportPopup?.view.window ?? window else { return }
    panel.beginSheetModal(for: host) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.exportPopupModel?.destination = url
      self?.presetStore.rememberDestination(url)
    }
  }

  private func startExport(preset: ExportPreset, destination: URL) {
    presetStore.rememberDestination(destination)
    projectDocument.enqueueExport(
      preset: preset,
      to: destination,
      sequence: presetStore.nextSequenceNumber()
    )
    dismissExportPopup()
    // The queue is where the export now lives, so show it.
    leftPanelItem?.animator().isCollapsed = false
  }

  private func dismissExportPopup() {
    if let exportPopup {
      contentViewController?.dismiss(exportPopup)
    }
    exportPopup = nil
    exportPopupModel = nil
  }

  /// Routes controls shared by the layers inspector and the Develop panel.
  ///
  /// Both are presentation surfaces over the same document state. Keeping this
  /// routing in the window controller ensures neither SwiftUI view reaches for
  /// file panels, document persistence, or render orchestration directly.
  private func inspectorSend() -> (InspectorIntent) -> Void {
    { [weak self, weak projectDocument] intent in
      guard let projectDocument else { return }
      switch intent {
      case .beginGesture:
        projectDocument.beginEditGesture()
      case .change(let action, let interactive):
        projectDocument.perform(action, interactive: interactive)
      case .endGesture(let name):
        projectDocument.endEditGesture(actionName: name)
      case .addImage:
        self?.addImageLayer(nil)
      case .addRaw:
        self?.addRawLayer(nil)
      case .setClipping(let indicators):
        projectDocument.setClippingIndicators(indicators)
      case .setDifferencePreview(let layerID):
        projectDocument.setDifferencePreview(layerID)
      case .mask(let maskIntent):
        self?.handle(maskIntent)
      case .setPaintTarget(let target):
        projectDocument.editorModel.setPaintTarget(target)
      case .selectLayers(let ids):
        projectDocument.selectLayers(ids)
      case .rasterizeLayer(let id):
        projectDocument.rasterizeLayer(id)
      case .mergeLayers(let ids):
        projectDocument.mergeLayers(ids)
      case .cancelLayerOperation:
        projectDocument.cancelLayerOperation()
      case .pickWhiteBalance:
        self?.pickWhiteBalance(nil)
      case .resetWhiteBalanceToAsShot:
        projectDocument.resetWhiteBalanceToAsShot()
      case .toggleBefore:
        projectDocument.toggleBeforeAfter()
      case .selectVectorObjects(let ids):
        projectDocument.editorModel.setSelectedVectorObjects(ids)
      }
    }
  }

  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(toggleLeftPanel(_:)):
      menuItem.state = leftPanelItem?.isCollapsed == false ? .on : .off
      return leftPanelItem != nil
    case #selector(toggleRightPanel(_:)):
      menuItem.state = rightPanelItem?.isCollapsed == false ? .on : .off
      return rightPanelItem != nil
    case #selector(toggleDevelopPanel(_:)):
      menuItem.state = developPanelItem?.isCollapsed == false ? .on : .off
      return developPanelItem != nil
    case #selector(toggleAssistancePanel(_:)):
      menuItem.state = assistancePanelItem?.isCollapsed == false ? .on : .off
      return assistancePanelItem != nil
    case #selector(togglePromptBox(_:)):
      menuItem.state = canvasController.isPromptBoxVisible ? .on : .off
      return true
    case #selector(exportDocument(_:)):
      return projectDocument.editorModel.renderedFrame != nil
    case #selector(toggleFullscreenPreview(_:)):
      // Nothing to preview until something has been rendered, and the bare F
      // stands down while a text field has the keyboard.
      menuItem.state = fullscreenPreview == nil ? .off : .on
      return projectDocument.editorModel.renderedFrame != nil
        && !(window?.firstResponder is NSTextView)
    case #selector(zoomToFit(_:)), #selector(zoomToActualSize(_:)),
      #selector(zoomIn(_:)), #selector(zoomOut(_:)):
      // A canvas-only document has an extent to zoom around without a frame.
      return projectDocument.editorModel.renderedFrame != nil
        || projectDocument.editorModel.recipe.layerStack.canvas.isResolved
    case #selector(clearGuides(_:)):
      return !projectDocument.editorModel.recipe.canvasSettings.guides.isEmpty
    case #selector(convertAnchorToCorner(_:)), #selector(convertAnchorToSmooth(_:)),
      #selector(convertAnchorToSymmetric(_:)):
      return canvasController.canvas.hasSelectedAnchor
    case #selector(alignVectorObjectsLeft(_:)):
      return projectDocument.canArrangeVectorObjects(.align(.left, alignmentReference))
    case #selector(alignVectorObjectsHorizontalCenter(_:)):
      return projectDocument.canArrangeVectorObjects(
        .align(.horizontalCenter, alignmentReference))
    case #selector(alignVectorObjectsRight(_:)):
      return projectDocument.canArrangeVectorObjects(.align(.right, alignmentReference))
    case #selector(alignVectorObjectsTop(_:)):
      return projectDocument.canArrangeVectorObjects(.align(.top, alignmentReference))
    case #selector(alignVectorObjectsVerticalMiddle(_:)):
      return projectDocument.canArrangeVectorObjects(
        .align(.verticalMiddle, alignmentReference))
    case #selector(alignVectorObjectsBottom(_:)):
      return projectDocument.canArrangeVectorObjects(.align(.bottom, alignmentReference))
    case #selector(distributeVectorObjectsHorizontally(_:)):
      return projectDocument.canArrangeVectorObjects(.distribute(.horizontal))
    case #selector(distributeVectorObjectsVertically(_:)):
      return projectDocument.canArrangeVectorObjects(.distribute(.vertical))
    case #selector(reflectVectorObjectsHorizontally(_:)):
      return projectDocument.canArrangeVectorObjects(.reflect(horizontally: true))
    case #selector(reflectVectorObjectsVertically(_:)):
      return projectDocument.canArrangeVectorObjects(.reflect(horizontally: false))
    case #selector(bringVectorObjectsToFront(_:)):
      return projectDocument.canArrangeVectorObjects(.order(.front))
    case #selector(bringVectorObjectsForward(_:)):
      return projectDocument.canArrangeVectorObjects(.order(.forward))
    case #selector(sendVectorObjectsBackward(_:)):
      return projectDocument.canArrangeVectorObjects(.order(.backward))
    case #selector(sendVectorObjectsToBack(_:)):
      return projectDocument.canArrangeVectorObjects(.order(.back))
    case #selector(duplicateVectorObjectsInPlace(_:)):
      return projectDocument.canArrangeVectorObjects(.duplicateInPlace)
    case #selector(moveVectorObjectsToNewLayer(_:)):
      return projectDocument.canArrangeVectorObjects(.moveToNewLayer)
    case #selector(unionVectorObjects(_:)):
      return projectDocument.canArrangeVectorObjects(.boolean(.union))
    case #selector(subtractVectorObjects(_:)):
      return projectDocument.canArrangeVectorObjects(.boolean(.subtract))
    case #selector(intersectVectorObjects(_:)):
      return projectDocument.canArrangeVectorObjects(.boolean(.intersect))
    case #selector(excludeVectorObjects(_:)):
      return projectDocument.canArrangeVectorObjects(.boolean(.exclude))
    case #selector(releaseCompoundPath(_:)):
      return projectDocument.canArrangeVectorObjects(.releaseCompoundPath)
    case #selector(activateBrushTool(_:)):
      menuItem.state = projectDocument.editorModel.activeTool == .brush ? .on : .off
      return !(window?.firstResponder is NSTextView)
    case #selector(decreaseBrushSize(_:)), #selector(increaseBrushSize(_:)):
      return (projectDocument.editorModel.activeTool == .brush
        || projectDocument.editorModel.activeTool == .eraser
        || projectDocument.editorModel.activeTool == .selectionBrush)
        && !(window?.firstResponder is NSTextView)
    case #selector(activatePenTool(_:)), #selector(activateShapeTool(_:)),
      #selector(activateGradientTool(_:)), #selector(activateFillTool(_:)),
      #selector(activateNavigateTool(_:)),
      #selector(activateMoveTool(_:)), #selector(activateTransformTool(_:)), #selector(activateCropTool(_:)),
      #selector(activateEraserTool(_:)), #selector(activateHealTool(_:)),
      #selector(activateTextTool(_:)),
      #selector(activateMasksTool(_:)), #selector(activateMarqueeTool(_:)),
      #selector(activateLassoTool(_:)), #selector(activateMagnetSelectionTool(_:)),
      #selector(activateSelectionBrushTool(_:)):
      return !(window?.firstResponder is NSTextView)
    case #selector(swapForegroundAndBackgroundColors(_:)),
      #selector(resetForegroundAndBackgroundColors(_:)):
      return !(window?.firstResponder is NSTextView)
    case #selector(pickForegroundColor(_:)):
      return (projectDocument.editorModel.renderedFrame != nil
        || !projectDocument.editorModel.recipe.layerStack.vectorArtwork.isEmpty)
        && !(window?.firstResponder is NSTextView)
    case #selector(selectAll(_:)):
      // A text field that has the keyboard answers ⌘A itself; the canvas takes
      // it only otherwise, and needs an extent to select.
      return (projectDocument.editorModel.recipe.layerStack.canvas.isResolved
        || projectDocument.isEditingVectorObjects)
        && !(window?.firstResponder is NSTextView)
    case #selector(deselect(_:)):
      return (projectDocument.editorModel.recipe.hasSelection
        || projectDocument.isEditingVectorObjects
          && !projectDocument.editorModel.selectedVectorObjectIDs.isEmpty)
        && !(window?.firstResponder is NSTextView)
    case #selector(invertSelection(_:)):
      return projectDocument.editorModel.recipe.hasSelection
        && !(window?.firstResponder is NSTextView)
    case #selector(reselect(_:)):
      return projectDocument.canReselect && !(window?.firstResponder is NSTextView)
    case #selector(saveSelectionAsMask(_:)):
      return projectDocument.canSaveSelectionAsMask && !(window?.firstResponder is NSTextView)
    case #selector(copy(_:)):
      return (usesVectorObjectClipboard
        ? projectDocument.canCopyVectorObjects
        : projectDocument.canCopySelection)
        && !(window?.firstResponder is NSTextView)
    case #selector(copyMerged(_:)):
      return projectDocument.canCopySelection && !(window?.firstResponder is NSTextView)
    case #selector(cut(_:)):
      return (usesVectorObjectClipboard
        ? projectDocument.canCutVectorObjects
        : projectDocument.canCopySelection && projectDocument.canClearSelection)
        && !(window?.firstResponder is NSTextView)
    case #selector(paste(_:)):
      return (usesVectorObjectClipboard
        ? projectDocument.canPasteVectorObjects
        : projectDocument.canPaste)
        && !(window?.firstResponder is NSTextView)
    case #selector(delete(_:)):
      // ⌫ is a bare key equivalent, and a disabled item does not consume one,
      // so standing this down is what leaves the key to whoever else wants it:
      // the pen tool, which deletes its newest anchor with it, and any text
      // field, which deletes a character.
      return (projectDocument.canClearSelection
        || usesVectorObjectClipboard && projectDocument.canDeleteVectorObjects)
        && projectDocument.editorModel.activeTool != .pen
        && !(window?.firstResponder is NSTextView)
    case #selector(pickWhiteBalance(_:)):
      // The picker states its own precondition, so the menu offers it only when
      // the document actually has a white balance to neutralize.
      return projectDocument.editorModel.canPickWhiteBalance
        && !(window?.firstResponder is NSTextView)
    case #selector(resetWhiteBalanceToAsShot(_:)):
      return projectDocument.editorModel.whiteBalanceDiffersFromAsShot
        && !(window?.firstResponder is NSTextView)
    case #selector(toggleClippingIndicators(_:)):
      // One item for the pair: on when either indicator is armed, matching what
      // the key does and what the two triangles in the panel show.
      menuItem.state = projectDocument.editorModel.clipping.isOn ? .on : .off
      return !(window?.firstResponder is NSTextView)
    case #selector(toggleBeforeAfter(_:)):
      menuItem.state = projectDocument.editorModel.isShowingBefore ? .on : .off
      return projectDocument.editorModel.canShowBefore
        && !(window?.firstResponder is NSTextView)
    default:
      return true
    }
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .leftPanel, .rawDecoder, .zoomGroup, .fullscreenPreview, .export, .renderProgress, .rightPanel,
      .developPanel, .flexibleSpace, .space,
    ]
  }

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      .leftPanel, .space, .rawDecoder, .flexibleSpace, .zoomGroup, .space, .fullscreenPreview, .export,
      .renderProgress, .space, .developPanel, .rightPanel,
    ]
  }

  public func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case .leftPanel:
      let item = panelToggleToolbarItem(
        identifier: itemIdentifier,
        label: "Left Panel",
        symbol: "sidebar.left",
        shortcut: "⌘1",
        width: 48,
        action: #selector(toggleLeftPanel(_:))
      )
      item.isNavigational = true
      return item
    case .rawDecoder:
      return makeRawDecoderToolbarItem(trackUpdates: flag)
    case .zoomGroup:
      let item = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
      item.label = "Zoom"
      item.paletteLabel = "Zoom"
      item.subitems = [
        toolbarButton(
          "Fit", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(zoomToFit(_:))),
        toolbarButton(
          "Actual Size", symbol: "1.magnifyingglass", action: #selector(zoomToActualSize(_:))),
      ]
      return item
    case .fullscreenPreview:
      return panelToggleToolbarItem(
        identifier: itemIdentifier,
        label: "Fullscreen Preview",
        symbol: "arrow.up.left.and.arrow.down.right.rectangle",
        shortcut: "F",
        accessibilityDescription: "Preview the canvas fullscreen",
        action: #selector(toggleFullscreenPreview(_:))
      )
    case .export:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Export"
      item.image = NSImage(
        systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
      item.target = self
      item.action = #selector(exportDocument(_:))
      return item
    case .renderProgress:
      renderProgressIndicator.style = .spinning
      renderProgressIndicator.controlSize = .small
      renderProgressIndicator.isIndeterminate = true
      renderProgressIndicator.isDisplayedWhenStopped = false
      renderProgressIndicator.setAccessibilityLabel("Rendering image")
      renderProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
      let content = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
      content.addSubview(renderProgressIndicator)
      NSLayoutConstraint.activate([
        renderProgressIndicator.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        renderProgressIndicator.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      ])
      let container = NSGlassEffectView(frame: content.frame)
      container.style = .regular
      container.cornerRadius = 8
      container.contentView = content
      container.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: 32),
        container.heightAnchor.constraint(equalToConstant: 28),
      ])
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Render Activity"
      item.paletteLabel = "Render Activity"
      item.view = container
      item.isHidden = !projectDocument.editorModel.renderStatus.isBusy
      renderProgressToolbarItem = item
      return item
    case .rightPanel:
      return panelToggleToolbarItem(
        identifier: itemIdentifier,
        label: "Right Panel",
        symbol: "sidebar.right",
        shortcut: "⌘2",
        action: #selector(toggleRightPanel(_:))
      )
    case .developPanel:
      return panelToggleToolbarItem(
        identifier: itemIdentifier,
        label: "Develop Panel",
        symbol: "slider.horizontal.3",
        shortcut: "⌘3",
        action: #selector(toggleDevelopPanel(_:))
      )
    default:
      return nil
    }
  }

  private func installContent() {
    let inspector = NSHostingController(
      rootView: InspectorView(
        model: projectDocument.editorModel,
        send: inspectorSend()
      )
    )

    let toolbox = ToolboxViewController(
      model: projectDocument.editorModel,
      selectTool: { [weak self] tool in
        switch tool {
        case .navigate: self?.activateNavigateTool(nil)
        case .move: self?.activateMoveTool(nil)
        case .transform: self?.activateTransformTool(nil)
        case .marquee: self?.activateMarqueeTool(nil)
        case .lasso: self?.activateLassoTool(nil)
        case .magnetSelection: self?.activateMagnetSelectionTool(nil)
        case .selectionBrush: self?.activateSelectionBrushTool(nil)
        case .crop: self?.activateCropTool(nil)
        case .brush: self?.activateBrushTool(nil)
        case .eraser: self?.activateEraserTool(nil)
        case .heal: self?.activateHealTool(nil)
        case .pen: self?.activatePenTool(nil)
        case .shape: self?.activateShapeTool(nil)
        case .gradient: self?.activateGradientTool(nil)
        case .fill: self?.activateFillTool(nil)
        case .masks: self?.activateMasksTool(nil)
        case .text: self?.activateTextTool(nil)
        case .generate: self?.activateGenerateTool(nil)
        }
      },
      pickForegroundColor: { [weak self] in self?.pickForegroundColor(nil) },
      colorSend: { [weak self] intent in self?.handle(intent) }
    )

    installPanelSections()
    let leftPanel = PanelViewController(
      model: leftPanelModel,
      emptyDescription: "Settings for the active tool appear here."
    )
    let assistancePanel = PanelViewController(
      model: assistancePanelModel,
      emptyDescription: "History, snapshots and background queues appear here."
    )
    let developPanel = NSHostingController(
      rootView: DevelopPanelView(
        model: projectDocument.editorModel,
        panelModel: developPanelModel
      )
    )
    // This controller is one column inside an already-sized AppKit split view.
    // If its SwiftUI fitting sizes propagate through NSHostingController, the
    // tall RAW form turns that momentary ideal height into a fixed window
    // height. The scroll view must adapt to the window, not size the window.
    developPanel.sizingOptions = []

    let split = NSSplitViewController()
    let toolboxItem = NSSplitViewItem(viewController: toolbox)
    toolboxItem.minimumThickness = 48
    toolboxItem.maximumThickness = 48
    toolboxItem.canCollapse = false
    // Tools on the left with their settings beside them; canvas in the middle;
    // per-layer development immediately to the left of the right-hand layers
    // panel, and the record of the work outside those. The left panel starts
    // collapsed while the navigate tool (or any other tool without settings)
    // is active, so a new window does not show an empty placeholder. Develop
    // and assistance also start collapsed so a new window gives the canvas
    // useful room; each panel can be opened deliberately.
    let leftPanelItem = NSSplitViewItem(viewController: leftPanel)
    leftPanelItem.minimumThickness = 266
    leftPanelItem.maximumThickness = 360
    leftPanelItem.canCollapse = true
    leftPanelItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    leftPanelItem.isCollapsed = !projectDocument.editorModel.activeTool.hasToolSettings
    leftPanelItem.holdingPriority = NSLayoutConstraint.Priority(261)
    self.leftPanelItem = leftPanelItem
    let canvasItem = NSSplitViewItem(viewController: canvasController)
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.minimumThickness = 280
    inspectorItem.maximumThickness = 440
    inspectorItem.canCollapse = true
    inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    inspectorItem.allowsFullHeightLayout = false
    self.rightPanelItem = inspectorItem
    let developItem = NSSplitViewItem(inspectorWithViewController: developPanel)
    // RAW controls carry longer labels and live numeric values than the
    // document inspector. Keeping this column a little wider prevents its
    // SwiftUI controls from reflowing as those values change during a drag.
    developItem.minimumThickness = 300
    developItem.maximumThickness = 440
    developItem.canCollapse = true
    developItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    developItem.isCollapsed = true
    developItem.holdingPriority = NSLayoutConstraint.Priority(262)
    self.developPanelItem = developItem
    let assistanceItem = NSSplitViewItem(viewController: assistancePanel)
    assistanceItem.minimumThickness = 240
    assistanceItem.maximumThickness = 400
    assistanceItem.canCollapse = true
    assistanceItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    assistanceItem.isCollapsed = true
    assistanceItem.holdingPriority = NSLayoutConstraint.Priority(260)
    self.assistancePanelItem = assistanceItem
    split.addSplitViewItem(toolboxItem)
    split.addSplitViewItem(leftPanelItem)
    split.addSplitViewItem(canvasItem)
    split.addSplitViewItem(developItem)
    split.addSplitViewItem(inspectorItem)
    split.addSplitViewItem(assistanceItem)
    contentViewController = split
  }

  /// Installs the sections this window owns, into the panel each belongs to.
  ///
  /// The split is what the section is about, not how wide its scope is: the
  /// left panel is the tool in hand, the right panel is what the document is,
  /// and the assistance panel is how the work is going — the edit record and
  /// the queues running beside it. Selection and crop are document-wide and
  /// still belong on the left, because they are what a tool is doing.
  ///
  /// Other features add their own by calling `install(_:)` on the registry they
  /// belong in; each panel sorts by `PanelOrder`, so nothing here needs to
  /// change.
  private func installPanelSections() {
    let send: (HistoryIntent) -> Void = { [weak projectDocument] intent in
      guard let projectDocument else { return }
      switch intent {
      case .returnToStep(let id):
        projectDocument.returnToHistoryStep(id)
      case .takeSnapshot:
        projectDocument.takeSnapshot()
      case .restoreSnapshot(let id):
        projectDocument.restoreSnapshot(id)
      case .renameSnapshot(let id, let name):
        projectDocument.renameSnapshot(id, to: name)
      case .deleteSnapshot(let id):
        projectDocument.deleteSnapshot(id)
      }
    }
    let model = projectDocument.editorModel

    installDevelopmentSection()

    leftPanelModel.install(
      PanelSection(
        id: .toolSettings,
        title: "Tool Settings",
        systemImage: "slider.horizontal.3",
        order: PanelOrder.toolSettings
      ) {
        ToolSettingsView(
          model: model,
          cropSend: { [weak projectDocument] intent in
            guard let projectDocument else { return }
            switch intent {
            case .begin:
              projectDocument.beginCropSession()
            case .setTarget(let target):
              projectDocument.setCropTarget(target)
            case .updateDraft(let draft, let interactive):
              projectDocument.updateCropDraft(draft, interactive: interactive)
            case .commit:
              projectDocument.commitCropDraft()
            case .cancel:
              projectDocument.cancelCropDraft()
            }
          },
          selectionSend: { [weak projectDocument] intent in
            guard let projectDocument else { return }
            switch intent {
            case .setSelectionTool(let state):
              projectDocument.editorModel.setSelectionTool(state)
            case .setMagnetSelectionTool(let state):
              projectDocument.editorModel.setMagnetSelectionTool(state)
            case .setSelectionBrushTool(let state):
              projectDocument.editorModel.setSelectionBrushTool(state)
            case .invertSelection:
              projectDocument.invertSelection()
            case .setSelection(let selection, let name):
              projectDocument.setSelection(selection, actionName: name)
            }
          },
          transformSend: { [weak projectDocument] intent in
            guard let projectDocument else { return }
            switch intent {
            case .begin: projectDocument.beginTransformSession()
            case .update(let transform): projectDocument.updateTransformDraft(transform)
            case .commit: projectDocument.commitTransformDraft()
            case .cancel: projectDocument.cancelTransformDraft()
            }
          },
          colorSend: { [weak self] intent in
            self?.handle(intent)
          },
          vectorSend: { [weak projectDocument] intent in
            guard let projectDocument else { return }
            switch intent {
            case .setStyle(let style):
              projectDocument.editorModel.setVectorToolStyle(style)
            case .arrange(let command):
              projectDocument.arrangeVectorObjects(command)
            case .setVectorLayer(let id, let vector, let actionName, let interactive):
              projectDocument.perform(
                .setVectorLayer(id, vector, actionName: actionName), interactive: interactive)
            case .beginGesture:
              projectDocument.beginEditGesture()
            case .endGesture(let name):
              projectDocument.endEditGesture(actionName: name)
            }
          },
          penSend: { [weak projectDocument] intent in
            guard let projectDocument else { return }
            switch intent {
            case .setEditMode(let mode):
              projectDocument.editorModel.setVectorEditMode(mode)
            }
          },
          shapeSend: { [weak projectDocument] intent in
            guard let projectDocument else { return }
            switch intent {
            case .setState(let style):
              projectDocument.editorModel.setShapeTool(style)
            }
          },
          textSend: { [weak projectDocument] intent in
            guard let projectDocument else { return }
            switch intent {
            case .setStyle(let style):
              projectDocument.editorModel.setTextToolStyle(style)
            case .setTextLayer(let id, let text, let interactive):
              projectDocument.perform(.setTextLayer(id, text), interactive: interactive)
            case .beginGesture:
              projectDocument.beginEditGesture()
            case .endGesture(let name):
              projectDocument.endEditGesture(actionName: name)
            }
          },
          maskSend: { [weak self] intent in
            self?.handle(intent)
          }
        )
      }
    )

    assistancePanelModel.install(
      PanelSection(
        id: .history,
        title: "History",
        systemImage: "clock.arrow.circlepath",
        order: PanelOrder.history
      ) {
        HistoryPanelView(model: model, send: send)
      }
    )
    assistancePanelModel.install(
      PanelSection(
        id: .snapshots,
        title: "Snapshots",
        systemImage: "camera.aperture",
        order: PanelOrder.snapshots
      ) {
        SnapshotsPanelView(model: model, send: send)
      }
    )

    // The export queue observes the same editor model; the queue publishes its
    // jobs into it, so the rows update while the document keeps being edited.
    let sendExport: (ExportQueueIntent) -> Void = { [weak self] intent in
      guard let self else { return }
      switch intent {
      case .showExportPopup:
        self.exportDocument(nil)
      case .cancel(let id):
        self.projectDocument.cancelExport(id)
      case .remove(let id):
        self.projectDocument.removeExport(id)
      case .clearCompleted:
        self.projectDocument.clearCompletedExports()
      case .reveal(let url):
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    }
    assistancePanelModel.install(
      PanelSection(
        id: .exportQueue,
        title: "Export Queue",
        systemImage: "square.and.arrow.up",
        order: PanelOrder.exportQueue
      ) {
        ExportQueuePanelView(model: model, send: sendExport)
      }
    )
  }

  private func setComfyUIOptionsVisible(_ visible: Bool) {
    if visible {
      developPanelModel.remove(.development)
      installComfyUISection()
      developPanelItem?.animator().isCollapsed = false
      projectDocument.refreshComfyUI()
    } else {
      developPanelModel.remove(.comfyUI)
      installDevelopmentSection()
    }
  }

  private func installDevelopmentSection() {
    guard !developPanelModel.contains(.development) else { return }
    let model = projectDocument.editorModel
    developPanelModel.install(
      PanelSection(
        id: .development,
        title: "Development",
        systemImage: "slider.horizontal.3",
        order: PanelOrder.development
      ) {
        DevelopLayerInspectorView(model: model, send: self.inspectorSend())
      }
    )
  }

  private func installComfyUISection() {
    guard !developPanelModel.contains(.comfyUI) else { return }
    let model = projectDocument.editorModel
    developPanelModel.install(
      PanelSection(
        id: .comfyUI,
        title: "ComfyUI",
        systemImage: "server.rack",
        order: PanelOrder.comfyUI
      ) {
        ComfyUIPanelView(
          model: model,
          historyStore: .shared,
          selectWorkflow: { [weak projectDocument] id in
            projectDocument?.selectComfyUIWorkflow(id)
          },
          updateParameter: { [weak projectDocument] address, value in
            projectDocument?.editorModel.setComfyUIParameter(address, value: value)
          },
          resetParameter: { [weak projectDocument] address in
            projectDocument?.editorModel.resetComfyUIParameter(address)
          },
          resetNode: { [weak projectDocument] nodeID in
            projectDocument?.editorModel.resetComfyUINode(nodeID)
          },
          refreshConnection: { [weak projectDocument] in
            projectDocument?.refreshComfyUI()
          },
          refreshJob: { [weak projectDocument] id in
            projectDocument?.refreshComfyUIJob(id)
          },
          restoreHistory: { [weak self] entry in
            self?.restoreComfyUIHistory(entry)
          },
          clearHistory: {
            ComfyUIHistoryStore.shared.clear()
          },
          manageWorkflows: {
            NSApp.sendAction(
              #selector(PixeltjeMacAppDelegate.showComfyUIWorkflowSettings(_:)),
              to: NSApp.delegate,
              from: nil)
          })
      })
  }

  private func restoreComfyUIHistory(_ entry: ComfyUIHistoryEntry) {
    guard projectDocument.restoreComfyUIHistoryEntry(entry) else { return }
    canvasController.promptBoxModel.restorePrompt(entry.prompt)
  }

  @objc public func toggleLeftPanel(_ sender: Any?) {
    guard let leftPanelItem else { return }
    togglePanel(leftPanelItem)
  }

  @objc public func toggleRightPanel(_ sender: Any?) {
    guard let rightPanelItem else { return }
    if canvasController.isPromptBoxVisible {
      rightPanelWasCollapsedBeforeGenerate = nil
    }
    togglePanel(rightPanelItem)
  }

  @objc public func toggleDevelopPanel(_ sender: Any?) {
    guard let developPanelItem else { return }
    togglePanel(developPanelItem)
  }

  @objc public func toggleAssistancePanel(_ sender: Any?) {
    guard let assistancePanelItem else { return }
    togglePanel(assistancePanelItem)
  }

  /// Reads the split item's real state before sending an explicit destination
  /// to AppKit's animation proxy. Mutating the proxy with `toggle()` makes its
  /// getter part of the decision and can reuse transitional animation state.
  private func togglePanel(_ item: NSSplitViewItem) {
    let shouldCollapse = !item.isCollapsed
    item.animator().isCollapsed = shouldCollapse
  }

  @objc public func togglePromptBox(_ sender: Any?) {
    canvasController.togglePromptBox()
  }

  /// Shows the composited image on its own, on the whole screen.
  ///
  /// The preview is a separate window rather than this one stripped down: it
  /// presents `RenderedFrame.surface`, which is the picture an export writes,
  /// without the checkerboard, guides, ants and handles the canvas needs in
  /// order to be worked on.
  @objc public func toggleFullscreenPreview(_ sender: Any?) {
    if let fullscreenPreview {
      fullscreenPreview.close()
      return
    }
    let controller = FullscreenPreviewWindowController(
      model: projectDocument.editorModel,
      on: window?.screen
    )
    controller.closed = { [weak self] closedController in
      guard self?.fullscreenPreview === closedController else { return }
      self?.fullscreenPreview = nil
    }
    fullscreenPreview = controller
    controller.show()
  }

  /// The preview belongs to this document, so it goes when the document does.
  public func windowWillClose(_ notification: Notification) {
    fullscreenPreview?.close()
  }

  /// Routes one mask intent: document mutations to the document, tool state to
  /// the editor model.
  private func handle(_ intent: MaskIntent) {
    switch intent {
    case .beginGesture:
      projectDocument.beginEditGesture()
    case .change(let action, let interactive):
      projectDocument.perform(action, interactive: interactive)
    case .endGesture(let name):
      projectDocument.endEditGesture(actionName: name)
    case .setMaskTool(let state):
      projectDocument.editorModel.setMaskTool(state)
    case .activateMask(let maskID, let layerID):
      projectDocument.editorModel.activateMask(maskID, on: layerID)
    }
  }

  @objc public func takeSnapshot(_ sender: Any?) {
    projectDocument.takeSnapshot()
    leftPanelItem?.animator().isCollapsed = false
  }

  private func observeModel() {
    projectDocument.reconcileComfyUIWorkflowLibrary()
    ComfyUIWorkflowLibrary.shared.$revision
      .dropFirst()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.projectDocument.reconcileComfyUIWorkflowLibrary() }
      .store(in: &subscriptions)
    NotificationCenter.default.publisher(for: ComfyCloudCredentialStore.didChange)
      .sink { [weak self] _ in self?.projectDocument.refreshComfyCloudAvailability() }
      .store(in: &subscriptions)
    projectDocument.editorModel.$recipe
      .receive(on: RunLoop.main)
      .sink { [weak self] recipe in
        self?.updateTitle()
        self?.updateRawDecoderIndicator(for: recipe)
      }
      .store(in: &subscriptions)
    projectDocument.editorModel.$activeTool
      .receive(on: RunLoop.main)
      .sink { [weak self] tool in
        if tool.hasToolSettings {
          self?.leftPanelItem?.animator().isCollapsed = false
        }
        if tool == .brush || tool == .eraser {
          self?.projectDocument.loadBrushLibraryPreviews()
        }
      }
      .store(in: &subscriptions)
    // Choosing a different brush mid-stroke discards the provisional stroke,
    // the same way switching tools does: the settings a stroke captured at its
    // start must stay the settings it is drawn with.
    Publishers.Merge(
      projectDocument.editorModel.$brushPresetID.dropFirst().map { _ in () },
      projectDocument.editorModel.$eraserPresetID.dropFirst().map { _ in () }
    )
    .receive(on: RunLoop.main)
    .sink { [weak self] in self?.projectDocument.cancelBrushStroke() }
    .store(in: &subscriptions)
    projectDocument.editorModel.$renderStatus
      .receive(on: RunLoop.main)
      .sink { [weak self] status in
        self?.updateRenderProgress(isBusy: status.isBusy)
      }
      .store(in: &subscriptions)
    // The color panel is one shared window, so only the document being looked
    // at gets to say what is in its palette. A background render finishing in
    // another window must not swap the swatches out from under this one.
    projectDocument.editorModel.$sampledPalette
      .receive(on: RunLoop.main)
      .sink { [weak self] palette in
        guard self?.window?.isMainWindow == true else { return }
        ColorPanelPalette.shared.setSampledColors(palette)
      }
      .store(in: &subscriptions)
  }

  private func updateRenderProgress(isBusy: Bool) {
    renderProgressToolbarItem?.isHidden = !isBusy
    if isBusy {
      renderProgressIndicator.startAnimation(nil)
    } else {
      renderProgressIndicator.stopAnimation(nil)
    }
  }

  private func updateTitle() {
    let source = projectDocument.editorModel.recipe.source?.originalFilename ?? "Untitled"
    window?.title = projectDocument.displayName.isEmpty ? source : projectDocument.displayName
    window?.subtitle = source
  }

  private func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: "PixeltjeMacDocumentToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = true
    return toolbar
  }

  private func toolbarButton(_ label: String, symbol: String, action: Selector) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(label))
    item.label = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.target = self
    item.action = action
    return item
  }

  /// A read-only summary of the Apple decoder selected for a single linked
  /// RAW. Multiple RAW layers keep independent decoder choices, so a lone
  /// badge would be ambiguous and is hidden for those documents.
  private func makeRawDecoderToolbarItem(trackUpdates: Bool) -> NSToolbarItem {
    let label = NSTextField(labelWithString: "")
    label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    let content = NSView(frame: NSRect(x: 0, y: 0, width: 48, height: 32))
    content.addSubview(label)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      content.widthAnchor.constraint(equalToConstant: 48),
      content.heightAnchor.constraint(equalToConstant: 32),
    ])

    let item = NSToolbarItem(itemIdentifier: .rawDecoder)
    item.label = "Apple RAW Decoder"
    item.paletteLabel = "Apple RAW Decoder"
    item.view = content
    applyRawDecoderIndicator(for: projectDocument.editorModel.recipe, to: item, label: label)
    if trackUpdates {
      rawDecoderToolbarItem = item
      rawDecoderToolbarLabel = label
    }
    return item
  }

  private func updateRawDecoderIndicator(for recipe: ProjectRecipe) {
    guard let item = rawDecoderToolbarItem, let label = rawDecoderToolbarLabel else { return }
    applyRawDecoderIndicator(for: recipe, to: item, label: label)
  }

  private func applyRawDecoderIndicator(
    for recipe: ProjectRecipe,
    to item: NSToolbarItem,
    label: NSTextField
  ) {
    let rawLayers = recipe.layerStack.flattenedLayers.compactMap { entry -> DevelopedRawLayer? in
      guard let raw = entry.layer.developedRawLayer else { return nil }
      let source = raw.source ?? (entry.id == .rawBackground ? recipe.source : nil)
      return source == nil ? nil : raw
    }
    guard rawLayers.count == 1, let identifier = rawLayers[0].rawDevelopment.decoderVersion else {
      item.isHidden = true
      label.stringValue = ""
      return
    }

    let shortName = Self.shortRawDecoderName(identifier)
    let description = "Apple RAW decoder: \(identifier)"
    label.stringValue = shortName
    label.toolTip = description
    label.setAccessibilityLabel("Apple RAW decoder \(shortName)")
    label.setAccessibilityHelp(description)
    item.toolTip = description
    item.isHidden = false
  }

  private static func shortRawDecoderName(_ identifier: String) -> String {
    let suffix: Substring
    if let versionRange = identifier.range(of: "Version") {
      suffix = identifier[versionRange.upperBound...]
    } else {
      suffix = identifier[...]
    }
    let digits = suffix.prefix(while: \Character.isNumber)
    return digits.isEmpty ? "RAW" : "RAW\(digits)"
  }

  /// A glass icon button that names its keyboard shortcut in its tooltip.
  ///
  /// Panel toggles describe themselves as showing or hiding; a button that does
  /// something else says so through `accessibilityDescription`.
  private func panelToggleToolbarItem(
    identifier: NSToolbarItem.Identifier,
    label: String,
    symbol: String,
    shortcut: String,
    accessibilityDescription: String? = nil,
    width: CGFloat = 32,
    action: Selector
  ) -> NSToolbarItem {
    let accessibilityDescription =
      accessibilityDescription ?? "Show or hide \(label.lowercased())"
    let button = NSButton()
    button.image = NSImage(
      systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
    button.target = self
    button.action = action
    button.isBordered = false
    button.imagePosition = .imageOnly
    let toolTip = "\(accessibilityDescription) (\(shortcut))"
    button.toolTip = toolTip
    button.setAccessibilityLabel(accessibilityDescription)
    button.setAccessibilityHelp(toolTip)
    button.translatesAutoresizingMaskIntoConstraints = true
    let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 32))
    content.toolTip = toolTip
    button.frame = content.bounds
    button.autoresizingMask = [.width, .height]
    content.addSubview(button)
    let container = NSGlassEffectView(frame: content.frame)
    container.style = .regular
    container.cornerRadius = 16
    container.effectIsInteractive = true
    container.contentView = content
    container.toolTip = toolTip
    container.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      container.widthAnchor.constraint(equalToConstant: width),
      container.heightAnchor.constraint(equalToConstant: 32),
    ])
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.paletteLabel = label
    item.toolTip = toolTip
    item.view = container
    return item
  }
}

extension NSToolbarItem.Identifier {
  fileprivate static let leftPanel = NSToolbarItem.Identifier("PixeltjeMac.LeftPanel")
  fileprivate static let rawDecoder = NSToolbarItem.Identifier("PixeltjeMac.RawDecoder")
  fileprivate static let zoomGroup = NSToolbarItem.Identifier("PixeltjeMac.Zoom")
  fileprivate static let fullscreenPreview = NSToolbarItem.Identifier(
    "PixeltjeMac.FullscreenPreview")
  fileprivate static let export = NSToolbarItem.Identifier("PixeltjeMac.Export")
  fileprivate static let renderProgress = NSToolbarItem.Identifier("PixeltjeMac.RenderProgress")
  fileprivate static let rightPanel = NSToolbarItem.Identifier("PixeltjeMac.RightPanel")
  fileprivate static let developPanel = NSToolbarItem.Identifier("PixeltjeMac.DevelopPanel")
}

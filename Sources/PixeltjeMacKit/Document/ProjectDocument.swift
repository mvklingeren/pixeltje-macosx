import AppKit
import CoreImage
import Foundation
import OSLog
import PixeltjeAutomation
import PixeltjeMacDomain
import PixeltjePipelineEngine

@MainActor
public final class ProjectDocument: NSDocument {
  nonisolated public static let projectTypeIdentifier = "org.pixeltje.mac-project"
  nonisolated public static let projectFilenameExtension = "pxmac"

  public let projectID = UUID()
  public let editorModel: EditorModel
  private let generationLogger = Logger(
    subsystem: "org.pixeltje.PixeltjeMacApp", category: "generation")
  private let subjectTagLogger = Logger(
    subsystem: "org.pixeltje.PixeltjeMacApp", category: "subject-tags")
  private let maskPaintLogger = Logger(
    subsystem: "org.pixeltje.PixeltjeMacApp", category: "mask-paint")

  private let renderEngine: RenderEngine?
  /// The document's background exports.
  ///
  /// Owned here rather than by the window, so a queued export outlives panel
  /// collapses and keeps running while the document is edited.
  private(set) var exportQueue: ExportQueue!
  nonisolated(unsafe) private var loadedRecipe: ProjectRecipe?
  private var renderTask: Task<Void, Never>?
  private var frameAnalysisTask: Task<Void, Never>?
  private var frameAnalysisGeneration: UInt64 = 0
  private var subjectTagTask: Task<Void, Never>?
  private var subjectTagGeneration: UInt64 = 0
  private var wantsSubjectTags = false
  private var interactiveRenderTask: Task<Void, Never>?
  private var pendingInteractiveRequest: RenderRequest?
  private var interactiveRenderGeneration: UInt64 = 0
  private var hashTask: Task<Void, Never>?
  private var brushPreviewTask: Task<Void, Never>?
  private var layerOperationTask: Task<Void, Never>?
  private var magnetSelectionTask: Task<Void, Never>?
  private var magnetSelectionGeneration: UInt64 = 0
  private var selectionBrushTask: Task<Void, Never>?
  private var selectionBrushGeneration: UInt64 = 0
  /// Separate from `layerOperationTask`: a heal is a layer operation for
  /// status purposes, but it must not cancel an in-flight rasterize or merge,
  /// nor be cancelled by one.
  private var healSolveTask: Task<Void, Never>?
  /// A Paste issued while Copy is rendering uses that copy's pixels when they
  /// arrive, rather than whatever older image is still on the system clipboard.
  private var pasteAfterCopy = false
  private var generationTask: Task<Void, Never>?
  private struct PendingComfyUIResult {
    var layer: ProjectLayer
    var assets: [RasterBakeResult]
  }
  /// One mask-source decision frozen before an asynchronous generation task
  /// starts. Keeping the authored mask and the render source together prevents
  /// the full-output flag, persisted provenance, and pixels sent to ComfyUI
  /// from drifting into three independent interpretations.
  private struct ResolvedGenerationMask {
    var requested: GenerationMaskSource
    var resolved: GenerationMaskSource
    var mask: MaskRecipe
    var renderSource: InpaintingMaskRenderSource?

    var usesFullOutputMask: Bool { resolved.kind == .entireOutput }
  }
  /// Completed server outputs whose source revision no longer matches the
  /// document. They remain session-only until the user explicitly commits one.
  private var pendingComfyUIResults: [UUID: PendingComfyUIResult] = [:]
  private var pendingComfyUIResultOrder: [UUID] = []
  private var pendingComfyUISelection: (mask: MaskRecipe, sourceRevision: UInt64)?
  private static let maximumPendingComfyUIResultCount = 4
  private var comfyUIRefreshTask: Task<Void, Never>?
  private let comfyUIClient = ComfyUIClient()
  private let comfyUIHistoryStore = ComfyUIHistoryStore.shared
  private var activeGenerationBackend: ComfyUIBackend?
  private var comfyUIDebugDiskLogger: ComfyUIDebugDiskLogger?
  /// Compressed, content-addressed pixels and generated-inpaint backing maps.
  /// The session keeps undo/redo assets alive; a save writes only references
  /// reachable from the current recipe.
  private var rasterAssets: [RasterAssetID: Data] = [:]
  nonisolated(unsafe) private var loadedRasterAssets: [RasterAssetID: Data]?
  private var revision: UInt64 = 0
  private var contentRevision: UInt64 = 0
  /// Only File ▸ New documents carry this baseline. Imported and reopened
  /// documents must never be treated as disposable blank tabs.
  private var initialUntitledRecipe: ProjectRecipe?
  private var gestureStartRecipe: ProjectRecipe?
  private var gestureChanged = false
  private var gestureRequiresRasterRender = false
  private var brushPreviewGeneration: UInt64 = 0
  private var brushLibraryPreviewsRequested = false
  /// The latest point the pointer asked to preview, and whether a preview is
  /// already crossing to the render actor. Together they coalesce hover
  /// sampling to one request in flight, latest point wins.
  private var pendingPreviewPoint: CGPoint?
  private var isPreviewingSample = false
  /// What Reselect brings back: the selection most recently replaced or
  /// cleared. Session state, so it is neither saved nor undone.
  private var lastDiscardedSelection: MaskRecipe?

  private struct ActiveBrushSession {
    var cacheID: String
    var stroke: PaintStroke
    var target: PaintTarget
    /// Non-nil only when pixel paint can append to an existing paint layer.
    var targetPaintLayerID: ProjectLayerID?
    /// An image eraser gesture writes mask coverage as image visibility.
    var erasesImageLayer: Bool
    /// Layer/ancestor transforms frozen at mouse-down. Mask strokes are stored
    /// in the same pre-transform authoring space as the layer they gate.
    var inputTransforms: [LayerTransform]
    var baseContentRevision: UInt64
    /// Present only for a Healing Brush stroke. The capture is identical to a
    /// brush's, so it shares this session rather than running a second input
    /// path; what differs is that release solves a patch instead of appending
    /// the stroke.
    var heal: HealSessionContext?
  }

  /// A Selection Brush gesture shares the ordinary brush input and preview
  /// renderer, but its destination is the document selection rather than a
  /// layer. Quick Select additionally freezes the displayed pixels at
  /// mouse-down so release analyses exactly what the hint was painted over.
  private struct ActiveSelectionBrushSession {
    var cacheID: String
    var stroke: PaintStroke
    var state: SelectionBrushToolState
    var combine: MaskCombineOperation?
    var selectionAtStart: MaskRecipe?
    var sourceFrame: RenderedFrame?
    var baseContentRevision: UInt64
  }

  /// What a heal stroke needs on release, frozen at mouse-down.
  private struct HealSessionContext {
    var tool: HealToolState
    /// Source displacement in canonical canvas pixels, derived once from the
    /// anchor and the first sample. Zero in spot mode, which has no source.
    var sourceOffsetX: Double
    var sourceOffsetY: Double
  }

  private var activeBrushSession: ActiveBrushSession?
  private var activeSelectionBrushSession: ActiveSelectionBrushSession?

  public override class var autosavesInPlace: Bool { true }
  nonisolated public override class var readableTypes: [String] { [projectTypeIdentifier] }
  nonisolated public override class var writableTypes: [String] { [projectTypeIdentifier] }

  nonisolated public override class func isNativeType(_ type: String) -> Bool {
    type == projectTypeIdentifier
  }

  public override init() {
    editorModel = EditorModel()
    renderEngine = try? RenderEngine()
    super.init()
    // The queue publishes its jobs into the editor model, so every view that
    // shows them observes the same model as the rest of the window.
    exportQueue = ExportQueue(renderEngine: renderEngine) { [weak self] jobs in
      self?.editorModel.setExportJobs(jobs)
    }
    // Every document saves as the project package, including one created by
    // File ▸ New, so the type is known before there is a file on disk.
    fileType = Self.projectTypeIdentifier
    // A document with no source has no image to take its extent from, so it
    // starts at the configured default. Importing a RAW replaces this recipe
    // outright, and reopening a project replaces it from disk.
    var recipe = ProjectRecipe()
    recipe.layerStack.canvas = AppSettings.storedDefaultCanvas()
    editorModel.replaceRecipe(recipe, historyName: "New Project")
    initialUntitledRecipe = recipe
    refreshComfyCloudAvailability()
  }

  /// Creates an untitled project with a one-off canvas size, such as the size
  /// supplied on the command line. This does not modify the File > New default.
  public convenience init(canvas: CanvasRecipe) {
    self.init()
    guard canvas.isResolved else { return }
    var recipe = ProjectRecipe()
    recipe.layerStack.canvas = canvas
    editorModel.replaceRecipe(recipe, historyName: "New Project")
    initialUntitledRecipe = recipe
  }

  public convenience init(importingRaw url: URL) throws {
    self.init()
    let source = try SourceReferenceFactory.make(for: url)
    editorModel.replaceRecipe(ProjectRecipe(source: source), historyName: "Open RAW")
    initialUntitledRecipe = nil
    updateChangeCount(.changeDone)
    startFingerprinting(url, layerID: .rawBackground)
  }

  /// A new document sized to an image file, with that image as its only layer.
  ///
  /// The counterpart of File ▸ New from Clipboard for a file on disk: the canvas
  /// takes the image's own pixel size, so the image lands at 1:1 at the origin.
  /// The layer is the ordinary linked image layer that Add Image places, so
  /// nothing is copied into the project and the file on disk stays
  /// authoritative.
  public convenience init(importingImage url: URL) throws {
    self.init()
    // An unresolved canvas makes the shared placement path preserve the
    // image's natural size at the origin. The document can then adopt that
    // exact size without inspecting or loading the file a second time.
    let layer = try ImageLayerFactory.makeLayer(for: url, canvas: .unresolved)
    guard let image = layer.imageLayer else {
      throw PixeltjeMacError(
        "Unsupported image",
        "\(url.lastPathComponent) could not be made into an image layer."
      )
    }
    var recipe = ProjectRecipe()
    recipe.layerStack.canvas = CanvasRecipe(
      width: image.naturalWidth,
      height: image.naturalHeight
    )
    recipe = recipe.applying(.addImageLayer(layer))
    editorModel.replaceRecipe(recipe, historyName: "Open Image")
    initialUntitledRecipe = nil
    // The image is a source, not this document's file: saving writes a project
    // package the user still has to name, and the image is never overwritten.
    displayName = url.deletingPathExtension().lastPathComponent
    updateChangeCount(.changeDone)
  }

  /// A new document sized to the clipboard image, with those pixels as its only
  /// layer.
  ///
  /// The canvas is sized before the paste runs, and that ordering is what makes
  /// the pixels land at 1:1: `LayerFrame.placing` scales by `min(1, …)` and
  /// centres what is left, so on a canvas of exactly the image's size it returns
  /// the image's own frame at the origin. The paste itself is the ordinary one,
  /// so the project's own copies stay lossless and a foreign image still goes
  /// through the render engine.
  convenience init(clipboard content: SelectionPasteboard.Content) throws {
    self.init()
    let canvas = content.pixelSize
    guard canvas.isResolved else {
      throw PixeltjeMacError(
        "Can’t read the clipboard",
        "The clipboard image has no usable size."
      )
    }
    var recipe = ProjectRecipe()
    recipe.layerStack.canvas = canvas
    editorModel.replaceRecipe(recipe, historyName: "New from Clipboard")
    initialUntitledRecipe = nil
    paste(content)
    // Unlike File ▸ New, this document has content from the moment it appears.
    updateChangeCount(.changeDone)
  }

  deinit {
    renderTask?.cancel()
    frameAnalysisTask?.cancel()
    subjectTagTask?.cancel()
    interactiveRenderTask?.cancel()
    hashTask?.cancel()
    brushPreviewTask?.cancel()
    layerOperationTask?.cancel()
    magnetSelectionTask?.cancel()
    selectionBrushTask?.cancel()
    healSolveTask?.cancel()
    generationTask?.cancel()
    comfyUIRefreshTask?.cancel()
  }

  public override func makeWindowControllers() {
    restoreLoadedState()
    let controller = ProjectWindowController(projectDocument: self)
    addWindowController(controller)
    scheduleRender(interactive: false)
  }

  /// Safe to discard after another image has opened. Checking the original
  /// recipe as well as AppKit's edited flag protects changes outside the usual
  /// save/undo path, while the revision and draft checks preserve in-progress
  /// work that has not reached the document recipe yet.
  var isUnusedUntitledDocument: Bool {
    guard let initialUntitledRecipe else { return false }
    return fileURL == nil
      && !isDocumentEdited
      && contentRevision == 0
      && editorModel.recipe == initialUntitledRecipe
      && editorModel.history.steps.count == 1
      && editorModel.history.snapshots.isEmpty
      && editorModel.cropDraft == nil
      && editorModel.transformDraft == nil
      && editorModel.selectionDraft == nil
      && gestureStartRecipe == nil
      && activeBrushSession == nil
      && activeSelectionBrushSession == nil
      && selectionBrushTask == nil
      && editorModel.exportJobs.isEmpty
      && editorModel.generationJobs.isEmpty
      && pendingComfyUIResults.isEmpty
      && pendingComfyUISelection == nil
      && windowControllers.compactMap { $0 as? ProjectWindowController }
        .allSatisfy { !$0.hasUnsubmittedPrompt }
  }

  func restoreLoadedState() {
    if let loadedRecipe {
      editorModel.replaceRecipe(loadedRecipe, historyName: "Open Project")
      initialUntitledRecipe = nil
      self.loadedRecipe = nil
      rasterAssets = loadedRasterAssets ?? [:]
      loadedRasterAssets = nil
    }
  }

  public override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
    commitTransformDraft()
    guard typeName == Self.projectTypeIdentifier else {
      throw PixeltjeMacError("Unsupported project type", "Cannot save project type \(typeName).")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let recipe = FileWrapper(regularFileWithContents: try encoder.encode(editorModel.recipe))
    var children = ["project.json": recipe]
    let references = editorModel.recipe.layerStack.allLayers.flatMap(\.rasterAssetReferences)
    if !references.isEmpty {
      var assetWrappers: [String: FileWrapper] = [:]
      for reference in references {
        guard let payload = rasterAssets[reference.id] else {
          throw PixeltjeMacError(
            "Raster asset missing",
            "The project cannot be saved because one raster layer has no pixel asset."
          )
        }
        assetWrappers[Self.rasterAssetFilename(reference.id)] = FileWrapper(
          regularFileWithContents: payload)
      }
      children["Assets"] = FileWrapper(directoryWithFileWrappers: assetWrappers)
    }
    return FileWrapper(directoryWithFileWrappers: children)
  }

  public override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
    guard typeName == Self.projectTypeIdentifier else {
      throw PixeltjeMacError("Unsupported project type", "Cannot open project type \(typeName).")
    }
    guard
      let wrappers = fileWrapper.fileWrappers,
      let recipeData = wrappers["project.json"]?.regularFileContents
    else {
      throw PixeltjeMacError("Invalid project", "The project package has no project.json recipe.")
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let recipe = try decoder.decode(ProjectRecipe.self, from: recipeData)
    guard recipe.schemaVersion <= ProjectRecipe.currentSchemaVersion else {
      throw PixeltjeMacError(
        "Newer project format",
        "This project uses schema \(recipe.schemaVersion), but this app supports schema \(ProjectRecipe.currentSchemaVersion)."
      )
    }

    var assets: [RasterAssetID: Data] = [:]
    let assetFiles = wrappers["Assets"]?.fileWrappers ?? [:]
    for reference in recipe.layerStack.allLayers.flatMap(\.rasterAssetReferences) {
      let filename = Self.rasterAssetFilename(reference.id)
      guard let payload = assetFiles[filename]?.regularFileContents else {
        throw PixeltjeMacError(
          "Invalid project",
          "The project package is missing raster asset \(filename)."
        )
      }
      _ = try RasterAssetPayload.decode(payload, reference: reference)
      assets[reference.id] = payload
    }

    // Projects written before sources became links may still carry a Sources
    // directory. It is ignored rather than rejected: the link is what the
    // project renders from, and the next save drops the copied pixels.
    loadedRecipe = recipe
    loadedRasterAssets = assets
  }

  private nonisolated static func rasterAssetFilename(_ id: RasterAssetID) -> String {
    "\(id.rawValue).pixa"
  }

  /// Places an image file on the canvas as a new linked layer.
  ///
  /// Nothing is copied into the project: the layer keeps a link, its
  /// placement, and the file's own pixel size.
  public func placeImage(at url: URL) throws {
    let layer = try ImageLayerFactory.makeLayer(
      for: url,
      canvas: editorModel.recipe.layerStack.canvas
    )
    perform(.addImageLayer(layer), interactive: false)
  }

  /// Places another camera RAW as an independently developed layer.
  ///
  /// The caller exposes this only when the advanced multi-RAW preference is
  /// on. The document intentionally remains capable of restoring and editing
  /// an existing multi-RAW project regardless of that preference.
  public func placeRaw(at url: URL) throws {
    let layer = try RawLayerFactory.makeLayer(
      for: url,
      canvas: editorModel.recipe.layerStack.canvas
    )
    perform(.addLayer(layer), interactive: false)
    startFingerprinting(url, layerID: layer.id)
  }

  // MARK: - Crop tool session
  //
  // The crop tool works on a target-aware draft. Opening it renders the whole
  // target so the rectangle has something to be dragged over; committing turns
  // the draft into one undoable canvas or layer crop. A lightweight applied
  // draft then keeps the controls visible while the committed result renders.
  // Rectangle movement is overlay-only once the full target is visible; an
  // angle change, or the first edit after Apply, asks for another render.

  public func beginCropSession(
    target requestedTarget: CropTarget? = nil,
    revealsFullTarget: Bool = true
  ) {
    guard editorModel.cropDraft == nil else { return }
    let preferred = requestedTarget ?? editorModel.defaultCropTarget
    let target: CropTarget =
      switch preferred {
      case .layer(let id) where editorModel.recipe.layerStack.canCropLayer(id): preferred
      default: .canvas
      }
    var draft: CropRecipe =
      switch target {
      case .canvas: editorModel.recipe.crop
      case .layer(let id): editorModel.recipe.layerStack.layer(id: id)?.crop ?? .identity
      }
    // A canvas without a base RAW is cropped by reframing its authored extent.
    // Rotating every heterogeneous layer is a different operation; straighten
    // remains available on a selected pixel layer or the base RAW canvas.
    if target == .canvas, !canvasUsesRawCrop { draft.angleDegrees = 0 }
    if let size = editorModel.cropReferenceSize(for: target) {
      draft = CropGeometry.fitted(draft, imageWidth: size.width, imageHeight: size.height)
    }
    editorModel.setCropDraft(
      CropDraft(target: target, recipe: draft, revealsFullTarget: revealsFullTarget))
    if revealsFullTarget {
      revision &+= 1
      contentRevision &+= 1
      scheduleRender(interactive: false)
    }
  }

  public func updateCropDraft(_ draft: CropRecipe, interactive: Bool) {
    guard let current = editorModel.cropDraft,
      current.recipe != draft || !current.revealsFullTarget
    else { return }
    editorModel.setCropDraft(
      CropDraft(target: current.target, recipe: draft, revealsFullTarget: true))
    contentRevision &+= 1
    guard !current.revealsFullTarget || current.recipe.angleDegrees != draft.angleDegrees
    else { return }
    revision &+= 1
    scheduleRender(interactive: interactive)
  }

  public func setCropTarget(_ target: CropTarget) {
    guard editorModel.cropDraft?.target != target else { return }
    commitCropDraft(resume: false)
    beginCropSession(target: target)
  }

  public func commitCropDraft() {
    commitCropDraft(resume: true)
  }

  private func commitCropDraft(resume: Bool) {
    guard let draft = editorModel.cropDraft else {
      if resume { resumeCropSessionIfActive() }
      return
    }
    editorModel.setCropDraft(nil)
    let action: EditorAction?
    switch draft.target {
    case .canvas:
      let previous = editorModel.recipe.crop
      if draft.recipe.clamped == previous.clamped {
        action = nil
      } else if canvasUsesRawCrop {
        action = .setCrop(
          draft.recipe,
          actionName: cropActionName(from: previous, to: draft.recipe))
      } else {
        action = .cropCanvas(
          draft.recipe,
          actionName: cropActionName(from: previous, to: draft.recipe))
      }
    case .layer(let id):
      let previous = editorModel.recipe.layerStack.layer(id: id)?.crop ?? .identity
      action =
        draft.recipe.clamped == previous.clamped
        ? nil
        : .setLayerCrop(
          id, draft.recipe,
          actionName: cropActionName(from: previous, to: draft.recipe))
    }
    let actionRequiresRender = action?.requiresRasterRender(in: editorModel.recipe) == true
    if let action {
      perform(action, interactive: false)
    }
    if !actionRequiresRender {
      // Clearing a draft puts the committed crop back into the render recipe.
      revision &+= 1
      contentRevision &+= 1
      scheduleRender(interactive: false)
    }
    if resume {
      resumeCropSessionIfActive(
        preferredTarget: draft.target,
        revealsFullTarget: false)
    }
  }

  public func cancelCropDraft() {
    guard let draft = editorModel.cropDraft else {
      resumeCropSessionIfActive()
      return
    }
    editorModel.setCropDraft(nil)
    revision &+= 1
    contentRevision &+= 1
    scheduleRender(interactive: false)
    resumeCropSessionIfActive(
      preferredTarget: draft.target,
      revealsFullTarget: false)
  }

  private var canvasUsesRawCrop: Bool {
    editorModel.recipe.layerStack.layer(id: .rawBackground)?.isDevelopedRaw == true
  }

  private func resumeCropSessionIfActive(
    preferredTarget: CropTarget? = nil,
    revealsFullTarget: Bool = false
  ) {
    guard editorModel.activeTool == .crop, editorModel.cropDraft == nil else { return }
    let target: CropTarget
    if case .layer(let id) = preferredTarget,
      editorModel.recipe.layerStack.canCropLayer(id)
    {
      target = .layer(id)
    } else {
      target = preferredTarget == .canvas ? .canvas : editorModel.defaultCropTarget
    }
    beginCropSession(target: target, revealsFullTarget: revealsFullTarget)
  }

  // MARK: - Selection
  //
  // A selection change moves no pixels, so none of this touches `revision` or
  // asks for a render: the marching ants are a canvas overlay, and a drag must
  // never cost a RAW develop. Only the committed step reaches the recipe.

  public func updateSelectionDraft(_ draft: MaskRecipe?) {
    if pendingComfyUISelection != nil { discardComfyUISelectionPreview() }
    editorModel.setSelectionDraft(draft)
  }

  /// Ends a selection gesture as one undoable step.
  public func commitSelection(_ selection: MaskRecipe?, actionName: String) {
    if pendingComfyUISelection != nil { discardComfyUISelectionPreview() }
    editorModel.setSelectionDraft(nil)
    setSelection(selection, actionName: actionName)
  }

  public func cancelSelectionDraft() {
    if pendingComfyUISelection != nil { discardComfyUISelectionPreview() }
    editorModel.setSelectionDraft(nil)
  }

  func applyComfyUISelectionPreview() {
    guard let pending = pendingComfyUISelection else { return }
    guard pending.sourceRevision == contentRevision else {
      discardComfyUISelectionPreview()
      recordComfyUIDebug(
        stage: "Selection changed",
        message: "The document changed after the selection was prepared. Run the selection workflow again.")
      return
    }
    pendingComfyUISelection = nil
    editorModel.setComfyUISelectionPreview(nil)
    setSelection(pending.mask, actionName: "Select \(pending.mask.name)")
  }

  func discardComfyUISelectionPreview() {
    pendingComfyUISelection = nil
    editorModel.setComfyUISelectionPreview(nil)
  }

  /// Replaces the active selection, remembering what was there so Reselect can
  /// bring it back.
  ///
  /// The remembered selection is session state rather than recipe state: it is
  /// a convenience for the menu, not something a saved project should carry or
  /// an undo should restore.
  public func setSelection(_ selection: MaskRecipe?, actionName: String) {
    if pendingComfyUISelection != nil { discardComfyUISelectionPreview() }
    let previous = editorModel.recipe.selection
    guard previous != selection else { return }
    if let previous { lastDiscardedSelection = previous }
    perform(.setSelection(selection, actionName: actionName), interactive: false)
  }

  /// Samples the displayed composite or isolated active layer and captures the
  /// requested color-driven region as the document selection. Capturing makes
  /// the result stable: later pixel edits cannot move a color-range boundary,
  /// and every paint/generation consumer can evaluate it without the source
  /// image that originally produced it.
  public func applyMagnetSelection(
    at point: VectorPoint,
    combine: MaskCombineOperation?
  ) {
    let state = editorModel.magnetSelectionTool
    guard editorModel.recipe.layerStack.canvas.isResolved else {
      editorModel.setRenderStatus(.failed("Set a canvas size before selecting by color."))
      return
    }
    guard let renderEngine, let displayedFrame = editorModel.renderedFrame,
      MagnetSelectionSupport.acceptsDisplayedFrame(
        documentID: projectID,
        renderRevision: revision,
        frameDocumentID: displayedFrame.documentID,
        frameRevision: displayedFrame.revision,
        frameIsProxy: displayedFrame.isProxy)
    else {
      editorModel.setRenderStatus(
        .failed("Wait for the canvas to finish rendering before using Magnet Selection."))
      return
    }

    let capturedContentRevision = contentRevision
    let selectionAtClick = editorModel.recipe.selection
    if state.sampleSource == .activeLayer {
      guard let layerID = editorModel.recipe.layerStack.activeLayerID,
        let activeLayer = editorModel.recipe.layerStack.layer(id: layerID),
        activeLayer.isRasterContent,
        displayedFrame.sampledActiveLayerID == layerID,
        displayedFrame.activeLayerSamplingSurface != nil
      else {
        editorModel.setRenderStatus(
          .failed(
            "Current Layer sampling needs a visible RAW, image, paint, or text layer from the displayed frame."
          ))
        return
      }
    }

    magnetSelectionTask?.cancel()
    magnetSelectionGeneration &+= 1
    let generation = magnetSelectionGeneration
    editorModel.setRenderStatus(.preparing("Selecting similar colors…"))
    magnetSelectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let captured: MaskRecipe?
        switch state.mode {
        case .contiguous:
          captured = try await renderEngine.contiguousMask(
            in: displayedFrame,
            source: state.sampleSource,
            atNormalizedX: point.x,
            y: point.y,
            tolerance: state.tolerance,
            smoothness: state.smoothness)
        case .colorRange:
          captured = try await renderEngine.colorRangeMask(
            in: displayedFrame,
            source: state.sampleSource,
            atNormalizedX: point.x,
            y: point.y,
            tolerance: state.tolerance,
            smoothness: state.smoothness)
        }
        try Task.checkCancellation()
        guard generation == self.magnetSelectionGeneration else { return }
        guard self.contentRevision == capturedContentRevision,
          self.editorModel.recipe.selection == selectionAtClick
        else {
          self.editorModel.setRenderStatus(
            .failed("The document changed while Magnet Selection was analysing it. Click again."))
          return
        }
        guard let generated = captured,
          let commit = MagnetSelectionSupport.commit(
            captured: generated, existing: selectionAtClick, mode: state.mode,
            combine: combine, feather: state.feather)
        else {
          self.editorModel.setRenderStatus(
            .failed("Magnet Selection could not produce usable coverage. Try another point."))
          return
        }
        self.setSelection(commit.selection, actionName: commit.actionName)
        self.editorModel.setRenderStatus(.ready("\(state.mode.label) selection updated."))
      } catch is CancellationError {
        // A newer click superseded this analysis.
      } catch {
        guard generation == self.magnetSelectionGeneration else { return }
        self.editorModel.setRenderStatus(.failed(error.userFacingMessage))
      }
      if generation == self.magnetSelectionGeneration {
        self.magnetSelectionTask = nil
      }
    }
  }

  public func selectAll() {
    setSelection(.selectingAll, actionName: "Select All")
  }

  public func deselect() {
    setSelection(nil, actionName: "Deselect")
  }

  /// Restores the selection that was last replaced or cleared.
  public func reselect() {
    guard let restored = lastDiscardedSelection else { return }
    setSelection(restored, actionName: "Reselect")
  }

  /// Flips the whole selection, which is what the mask's own inversion means.
  public func invertSelection() {
    guard var inverted = editorModel.recipe.selection else { return }
    inverted.isInverted.toggle()
    setSelection(inverted, actionName: "Invert Selection")
  }

  /// Copies the active selection onto a layer as an ordinary mask.
  public func saveSelectionAsMask(on layerID: ProjectLayerID? = nil) {
    guard editorModel.recipe.selection != nil else { return }
    guard let layerID = layerID ?? editorModel.recipe.layerStack.activeLayerID,
      let layer = editorModel.recipe.layerStack.layer(id: layerID),
      !layer.isCanvasLayer
    else { return }
    perform(.saveSelectionAsMask(layerID, MaskID()), interactive: false)
  }

  /// Whether Save Selection as Mask has both a selection and a layer to put it
  /// on. The canvas layer carries the document extent and no pixels, so it
  /// never takes a mask.
  public var canSaveSelectionAsMask: Bool {
    guard editorModel.recipe.selection != nil,
      let layerID = editorModel.recipe.layerStack.activeLayerID,
      let layer = editorModel.recipe.layerStack.layer(id: layerID)
    else { return false }
    return !layer.isCanvasLayer
  }

  public var canReselect: Bool {
    lastDiscardedSelection != nil && editorModel.recipe.selection != lastDiscardedSelection
  }

  // MARK: - Clipboard and Delete
  //
  // A selection encloses an area of the canvas; these are the four commands
  // that act on the pixels inside it. Copy reads without changing anything,
  // Delete masks them away, Paste brings pixels back as a layer of their own.

  /// The canvas-pixel region the selection encloses, or the whole canvas when
  /// nothing is selected.
  ///
  /// The geometric outline is only half of it: feather spreads coverage past
  /// the shape it softens, so the region grows by the widest feather in the
  /// recipe. Three radii is where a Gaussian has nothing left worth carrying.
  func selectionBounds() -> CGRect? {
    let canvas = editorModel.recipe.layerStack.canvas
    guard canvas.isResolved else { return nil }
    let extent = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
    guard let selection = editorModel.recipe.selection else { return extent }
    guard !selection.selectsNothing else { return nil }
    // A workflow selection may contain hundreds of thousands of raster runs.
    // Its crop needs only their bounds; building and normalizing the complete
    // marching-ants path here can make Copy appear to do nothing.
    let simpleRaster = selection.isEnabled && !selection.isInverted
      && selection.components.count == 1
      && selection.components[0].isEnabled
      && selection.components[0].density > 0
      && !selection.components[0].isInverted
      && selection.components[0].availability.isAvailable
    let outlineBounds: CGRect?
    if simpleRaster,
      let bounds = SelectionGeometry.rasterBounds(
        for: selection.components[0].generator, in: extent)
    {
      outlineBounds = bounds
    } else {
      outlineBounds = SelectionGeometry.path(for: selection, in: extent)?.boundingBoxOfPath
    }
    guard let outlineBounds else {
      // A brush or luminance-range selection has no outline to resolve, but it
      // still clips the copy through the mask — only the tight crop is lost, so
      // the whole canvas is read instead. A selection that *is* pure geometry
      // and still resolves to nothing genuinely encloses nothing.
      let isPureGeometry = selection.components.allSatisfy {
        switch $0.generator {
        case .rectangle, .ellipse, .polygon: true
        default: false
        }
      }
      return isPureGeometry ? nil : extent
    }
    let feather = selection.feather + (selection.components.map(\.feather).max() ?? 0)
    let bounds = outlineBounds.insetBy(dx: -feather * 3, dy: -feather * 3)
    let clipped = bounds.integral.intersection(extent)
    return clipped.isNull || clipped.isEmpty ? nil : clipped
  }

  /// Whether there is anything to copy.
  ///
  /// Deliberately cheap: menu validation runs on every key equivalent the app
  /// sees, and resolving a selection outline is a path boolean solve. The
  /// region itself is worked out once, when the copy actually runs.
  public var canCopySelection: Bool {
    guard layerOperationTask == nil, renderEngine != nil,
      editorModel.recipe.layerStack.canvas.isResolved
    else { return false }
    if editorModel.recipe.selection?.selectsNothing == true { return false }
    return !editorModel.recipe.layerStack.contentLayers.isEmpty
  }

  /// A generated workflow selection was calculated from the visible document,
  /// so copying it uses the composite rather than an isolated source layer.
  var hasWorkflowSelection: Bool {
    editorModel.recipe.selection.map { selection in
      selection.isEnabled && selection.components.contains { component in
        guard component.isEnabled && component.density > 0
          && component.availability.isAvailable else { return false }
        if case .placedRaster = component.generator { return true }
        return false
      }
    } ?? false
  }

  public var canPaste: Bool {
    editorModel.recipe.layerStack.canvas.isResolved
      && (editorModel.layerOperationStatus == .copying || SelectionPasteboard.hasContent)
  }

  /// Whether File ▸ New from Clipboard has anything to build a document from.
  ///
  /// Read from the pasteboard's type list alone, because menu validation asks
  /// on every menu open.
  public static var canCreateFromClipboard: Bool { SelectionPasteboard.hasContent }

  /// Puts the pixels inside the selection on the pasteboard.
  ///
  /// `merged` chooses between the layer being worked on and the whole visible
  /// composite. A workflow selection always copies the composite it analyzed.
  public func copySelection(merged: Bool) {
    guard let job = makeCopyJob(merged: merged || hasWorkflowSelection) else { return }
    run(job, validAt: contentRevision)
  }

  /// Copy, then take the pixels out of the layer.
  ///
  /// The copy is snapshotted before the delete and rendered after it. That
  /// order matters twice over: the pixels it puts on the pasteboard are the
  /// ones that were there before the cut, and the delete stays in the undo
  /// group of the command the user actually gave rather than landing later,
  /// out of a background task, in whatever group happens to be open.
  public func cutSelection(merged: Bool) {
    guard canClearSelection, let job = makeCopyJob(merged: merged) else { return }
    clearSelection()
    // The delete has moved the document on by one edit, and that edit is this
    // command's own. Anything after it is somebody else's and still disqualifies
    // the copy.
    run(job, validAt: contentRevision)
  }

  /// Everything a copy needs, read from the recipe as it stands now.
  private struct CopyJob {
    var request: RenderRequest
    var crop: CGRect
    var canvas: CanvasRecipe
  }

  private func makeCopyJob(merged: Bool) -> CopyJob? {
    guard layerOperationTask == nil, renderEngine != nil else { return nil }
    let canvas = editorModel.recipe.layerStack.canvas
    guard canvas.isResolved, let crop = selectionBounds() else { return nil }
    guard let children = copySourceLayers(merged: merged) else { return nil }

    // The selection goes on a group wrapped around the sources rather than on
    // the sources themselves: a group composites its children and its own mask
    // then clips the result, so one layer and the whole stack take the same
    // path and neither has the masks it already carries disturbed.
    var group = ProjectLayer.group(children, name: "Copy")
    group.layerMask = editorModel.recipe.selection
    do {
      return CopyJob(
        request: try makeLayerBakeRequest(layers: [group], activeLayerID: nil),
        crop: crop,
        canvas: canvas)
    } catch {
      editorModel.setLayerOperationStatus(.failed(error.userFacingMessage))
      return nil
    }
  }

  /// Renders a prepared copy and writes it to the pasteboard, as long as the
  /// document still stands where `revision` says it did.
  private func run(_ job: CopyJob, validAt revision: UInt64) {
    guard let renderEngine else { return }
    editorModel.setLayerOperationStatus(.copying)
    layerOperationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.layerOperationTask = nil
        self.pasteAfterCopy = false
      }
      do {
        let result = try await renderEngine.bakeSelection(job.request, cropTo: job.crop)
        try Task.checkCancellation()
        // Copy changes nothing, so there is no edit to lose — but pixels from a
        // document that has moved on are not what the user asked to copy.
        guard self.contentRevision == revision else {
          self.editorModel.setLayerOperationStatus(
            .failed("The document changed while it was being copied. Try again."))
          return
        }
        let payload = SelectionPasteboard.Payload(
          reference: result.raster.reference,
          compressedPixels: result.raster.compressedPixels,
          frame: LayerFrame(
            x: result.bounds.minX,
            y: result.bounds.minY,
            width: result.bounds.width,
            height: result.bounds.height),
          canvasWidth: job.canvas.width,
          canvasHeight: job.canvas.height)
        try SelectionPasteboard.write(payload, png: result.png)
        self.editorModel.setLayerOperationStatus(.idle)
        if self.pasteAfterCopy { self.paste(.payload(payload)) }
      } catch is CancellationError {
        self.editorModel.setLayerOperationStatus(.idle)
      } catch {
        self.editorModel.setLayerOperationStatus(.failed(error.userFacingMessage))
      }
    }
  }

  /// The layers a copy reads, or `nil` when there is nothing to read.
  private func copySourceLayers(merged: Bool) -> [ProjectLayer]? {
    let stack = editorModel.recipe.layerStack
    if merged || stack.activeLayerID == .canvas {
      let visible = stack.contentLayers
      return visible.isEmpty ? nil : visible
    }
    guard let id = stack.activeLayerID, var layer = stack.layer(id: id), !layer.isCanvasLayer
    else { return nil }
    // A single layer is copied as it looks on its own: hidden is not a reason
    // to hand back nothing, and a blend mode describes how it meets the layers
    // beneath it, which are not part of this copy.
    layer.isEnabled = true
    layer.compositing.blendMode = .normal
    return [layer]
  }

  /// Brings pasteboard pixels back as a new raster layer.
  ///
  /// Always a new layer, and not by convention: layers here are recipes, not
  /// framebuffers, and nothing in the model can write pixels into part of an
  /// existing one. A layer of its own is the only honest place to put them.
  public func paste() {
    if editorModel.layerOperationStatus == .copying {
      pasteAfterCopy = true
      return
    }
    guard let content = SelectionPasteboard.readContent() else { return }
    paste(content)
  }

  /// Pastes clipboard content that has already been read.
  ///
  /// Split out so a command that needs to know what is on the clipboard before
  /// it acts — sizing a new document to it, say — reads it once and pastes the
  /// very same thing, rather than reading the pasteboard twice and hoping it did
  /// not change in between.
  func paste(_ content: SelectionPasteboard.Content) {
    let canvas = editorModel.recipe.layerStack.canvas
    guard canvas.isResolved else { return }

    switch content {
    case .payload(let payload):
      // Pasteboard data comes from outside the document. Verifying it here
      // means a damaged payload fails one paste instead of breaking every
      // render that follows.
      guard
        (try? RasterAssetPayload.decode(payload.compressedPixels, reference: payload.reference))
          != nil
      else { return }
      rasterAssets[payload.reference.id] = payload.compressedPixels
      addPastedLayer(
        RasterLayerRecipe(
          asset: payload.reference,
          frame: payload.fitsInPlace(on: canvas)
            ? payload.frame
            : .placing(
              naturalWidth: payload.reference.width,
              naturalHeight: payload.reference.height,
              in: canvas)))

    case .image(let ciImage):
      guard let renderEngine, layerOperationTask == nil else { return }
      editorModel.setLayerOperationStatus(.pasting)
      layerOperationTask = Task { [weak self] in
        guard let self else { return }
        defer { self.layerOperationTask = nil }
        do {
          let result = try await renderEngine.importRaster(ciImage)
          try Task.checkCancellation()
          let canvas = self.editorModel.recipe.layerStack.canvas
          guard canvas.isResolved else {
            self.editorModel.setLayerOperationStatus(.idle)
            return
          }
          self.rasterAssets[result.reference.id] = result.compressedPixels
          self.addPastedLayer(
            RasterLayerRecipe(
              asset: result.reference,
              frame: .placing(
                naturalWidth: result.reference.width,
                naturalHeight: result.reference.height,
                in: canvas)))
          self.editorModel.setLayerOperationStatus(.idle)
        } catch is CancellationError {
          self.editorModel.setLayerOperationStatus(.idle)
        } catch {
          self.editorModel.setLayerOperationStatus(.failed(error.userFacingMessage))
        }
      }
    }
  }

  /// One layer, one history step. `setLayerStack` carries its own name, so the
  /// paste needs no action of its own to read correctly in the history.
  private func addPastedLayer(_ raster: RasterLayerRecipe) {
    let layer = ProjectLayer.raster(raster, name: "Pasted Layer")
    perform(
      .setLayerStack(editorModel.recipe.layerStack.adding(layer), actionName: "Paste"),
      interactive: false)
    editorModel.setLayerSelection([layer.id])
  }

  public var canClearSelection: Bool { clearSelectionTarget() != nil }

  /// Takes the selected pixels out of the layer being worked on.
  ///
  /// Nothing is erased. The layer keeps its content and gains a layer mask that
  /// hides what was selected, so the delete is visible in the mask list, can be
  /// undone, and costs the document no pixels.
  public func clearSelection() {
    guard let target = clearSelectionTarget() else { return }
    perform(
      .setLayerMask(target.id, target.mask, actionName: "Delete"),
      interactive: false)
  }

  /// The layer a delete would act on and the mask it would leave behind.
  ///
  /// `MaskRecipe.hiding` answers `nil` when the combination cannot be written
  /// as one flat component list, and the command stands down rather than
  /// masking away a region that is nearly the right one.
  private func clearSelectionTarget() -> (id: ProjectLayerID, mask: MaskRecipe)? {
    guard let selection = editorModel.recipe.selection, !selection.selectsNothing,
      let id = editorModel.recipe.layerStack.activeLayerID,
      let layer = editorModel.recipe.layerStack.layer(id: id),
      !layer.isCanvasLayer, (!layer.isLocked || id == .rawBackground),
      let mask = MaskRecipe.hiding(selection, from: layer.layerMask)
    else { return nil }
    return (id, mask)
  }

  // MARK: - Gradient, Fill, and Shape tools

  public func commitGradient(
    from start: VectorPoint, to end: VectorPoint,
    editing layerID: ProjectLayerID? = nil
  ) {
    guard editorModel.recipe.layerStack.canvas.isResolved,
      start.distance(to: end) > 0.000_001
    else { return }
    let state = editorModel.gradientTool
    var gradient = PaintGradientRecipe(
      kind: state.kind,
      start: start,
      end: end,
      startColor: state.startColor,
      endColor: state.endColor,
      coverage: editorModel.recipe.selection
    )
    if let layerID,
      var paint = editorModel.recipe.layerStack.layer(id: layerID)?.paintLayer,
      paint.gradients.count == 1
    {
      let existing = paint.gradients[0]
      gradient = PaintGradientRecipe(
        kind: existing.kind, start: start, end: end,
        startColor: existing.startColor, endColor: existing.endColor,
        coverage: existing.coverage)
      paint.gradients[0] = gradient
      perform(.setPaintLayer(layerID, paint, actionName: "Adjust Gradient"), interactive: false)
      return
    }
    let layer = ProjectLayer.paint(
      PaintLayerRecipe(gradients: [gradient]),
      name: "\(state.kind.label) Gradient"
    )
    perform(.addLayer(layer), interactive: false)
  }

  public func applyFill(at point: VectorPoint) {
    let state = editorModel.fillTool
    guard editorModel.recipe.layerStack.canvas.isResolved else {
      editorModel.setRenderStatus(.failed("Set a canvas size before filling."))
      return
    }
    if state.mode == .selection {
      let coverage = editorModel.recipe.selection ?? .selectingAll
      commitFill(PaintFillRecipe(
        color: state.color, coverage: coverage, source: state.sampleSource,
        tolerance: state.tolerance))
      return
    }
    guard let renderEngine, let frame = editorModel.renderedFrame else {
      editorModel.setRenderStatus(.failed("Wait for the canvas to finish rendering before a contiguous fill."))
      return
    }
    let capturedRevision = contentRevision
    let activeLayer = editorModel.recipe.layerStack.activeLayerID.flatMap {
      editorModel.recipe.layerStack.layer(id: $0)
    }
    let currentLayerRequest: RenderRequest?
    if state.sampleSource == .activeLayer {
      guard let activeLayer, activeLayer.isRasterContent,
        let entry = editorModel.recipe.layerStack.entry(id: activeLayer.id)
      else {
        editorModel.setRenderStatus(
          .failed("Current Layer sampling needs a RAW, image, paint, or text layer. Choose All Layers for structural content."))
        return
      }
      do {
        var request = try makeRenderRequest(quality: .full)
        var isolated = request.recipe
        let retained = Set(entry.ancestorIDs + [activeLayer.id])
        for candidate in isolated.layerStack.flattenedLayers
        where candidate.id != .canvas && !retained.contains(candidate.id) {
          isolated.layerStack.updateLayer(id: candidate.id) { $0.isEnabled = false }
        }
        request.recipe = isolated
        currentLayerRequest = request
      } catch {
        editorModel.setRenderStatus(.failed(error.userFacingMessage))
        return
      }
    } else {
      currentLayerRequest = nil
    }
    Task { [weak self] in
      guard let self else { return }
      do {
        let coverage: MaskRecipe?
        if let currentLayerRequest {
          let isolatedFrame = try await renderEngine.render(currentLayerRequest)
          coverage = try await renderEngine.contiguousMask(
            in: isolatedFrame, atNormalizedX: point.x, y: point.y,
            tolerance: state.tolerance)
        } else {
          coverage = try await renderEngine.contiguousMask(
            in: frame, atNormalizedX: point.x, y: point.y, tolerance: state.tolerance)
        }
        guard !Task.isCancelled, self.contentRevision == capturedRevision,
          let coverage
        else { return }
        self.commitFill(PaintFillRecipe(
          color: state.color, coverage: coverage, source: state.sampleSource,
          tolerance: state.tolerance))
      } catch {
        self.editorModel.setRenderStatus(.failed(error.localizedDescription))
      }
    }
  }

  private func commitFill(_ fill: PaintFillRecipe) {
    let layer = ProjectLayer.paint(
      PaintLayerRecipe(fills: [fill]), name: "Fill"
    )
    perform(.addLayer(layer), interactive: false)
  }

  /// Commits a Shape-tool drag as a parametric object.
  ///
  /// The shape keeps its kind, side count, corner radius, and rotation rather
  /// than being flattened into anchors, so it stays editable as the thing the
  /// user drew.
  public func commitShape(
    from start: VectorPoint,
    to end: VectorPoint,
    constrained: Bool,
    fromCenter: Bool = false
  ) {
    let state = editorModel.shapeTool
    guard start.distance(to: end) > 0.000_001 else { return }
    let canvas = editorModel.recipe.layerStack.canvas
    let aspect = canvas.isResolved ? Double(canvas.width) / Double(canvas.height) : 1
    var shape = state.makeShape(
      from: start,
      to: end,
      fromCenter: fromCenter != state.drawsFromCenter,
      constrained: constrained,
      aspect: aspect,
      stroke: editorModel.vectorToolStyle.fullStroke,
      fill: editorModel.vectorToolStyle.fill
    )
    shape.zOrder = 0
    let layer = ProjectLayer(
      name: shape.name,
      content: .vector(VectorLayer(objects: [.shape(shape)]))
    )
    var stack = editorModel.recipe.layerStack
    stack = stack.adding(layer)
    perform(.setLayerStack(stack, actionName: "Add \(shape.name)"), interactive: false)
    editorModel.setSelectedVectorObjects([shape.id])
  }

  // MARK: - Vector object clipboard

  /// Select/Move edits individual objects when a vector layer is active.
  /// The controller gives a standing workflow pixel selection precedence.
  var isEditingVectorObjects: Bool {
    editorModel.activeTool == .move && editorModel.activeVectorLayer != nil
  }

  var canCopyVectorObjects: Bool {
    isEditingVectorObjects && !editorModel.selectedVectorObjectIDs.isEmpty
      && editorModel.activeVectorLayer != nil
  }

  var canCutVectorObjects: Bool {
    canCopyVectorObjects && editorModel.activeVectorLayer?.isLocked == false
  }

  var canDeleteVectorObjects: Bool { canCutVectorObjects }

  var canPasteVectorObjects: Bool {
    isEditingVectorObjects && !VectorObjectClipboard.shared.isEmpty
  }

  func copyVectorObjects() {
    guard let active = editorModel.activeVectorLayer else { return }
    let selected = active.vector.objectsInDrawOrder.filter {
      editorModel.selectedVectorObjectIDs.contains($0.id)
    }
    VectorObjectClipboard.shared.copy(selected)
  }

  func cutVectorObjects() {
    guard let active = editorModel.activeVectorLayer, !active.isLocked else { return }
    copyVectorObjects()
    let ids = editorModel.selectedVectorObjectIDs
    let remaining = active.vector.removing(ids: ids)
    guard remaining != active.vector else { return }
    editorModel.setSelectedVectorObjects([])
    perform(
      .setVectorLayer(active.id, remaining, actionName: "Cut Vector Objects"),
      interactive: false)
  }

  func deleteVectorObjects() {
    guard canDeleteVectorObjects, let active = editorModel.activeVectorLayer else { return }
    let remaining = active.vector.removing(ids: editorModel.selectedVectorObjectIDs)
    guard remaining != active.vector else { return }
    editorModel.setSelectedVectorObjects([])
    perform(
      .setVectorLayer(active.id, remaining, actionName: "Delete Vector Objects"),
      interactive: false)
  }

  /// Pastes into the active vector layer, or onto a new one when the active
  /// layer cannot hold vector objects.
  func pasteVectorObjects() {
    let incoming = VectorObjectClipboard.shared.objects
    guard !incoming.isEmpty else { return }
    var stack = editorModel.recipe.layerStack

    if let active = editorModel.activeVectorLayer, !active.isLocked {
      let newIDs = stack.addingVectorObjects(incoming, to: active.id)
      guard !newIDs.isEmpty else { return }
      perform(
        .setLayerStack(stack, actionName: "Paste Vector Objects"), interactive: false)
      editorModel.setSelectedVectorObjects(Set(newIDs))
      return
    }

    let layerID = stack.ensureActiveVectorLayer()
    let newIDs = stack.addingVectorObjects(incoming, to: layerID)
    guard !newIDs.isEmpty else { return }
    perform(.setLayerStack(stack, actionName: "Paste Vector Objects"), interactive: false)
    editorModel.setLayerSelection([layerID])
    editorModel.setSelectedVectorObjects(Set(newIDs))
  }

  // MARK: - Vector object arrangement

  /// Runs one arrangement command against the selected vector objects.
  ///
  /// The left panel and the Object menu both ask for this, so there is one
  /// definition of what each command does and one history step per command.
  func arrangeVectorObjects(_ command: VectorArrangeCommand) {
    guard let target = arrangeableVectorSelection() else { return }
    let stack = editorModel.recipe.layerStack
    let width = Double(stack.canvas.width)
    let height = Double(stack.canvas.height)

    switch command {
    case .moveToNewLayer:
      var updated = stack
      guard
        let result = updated.movingVectorObjectsToNewLayer(
          ids: target.ids, from: target.layerID)
      else { return }
      perform(
        .setLayerStack(updated, actionName: command.actionName), interactive: false)
      editorModel.setLayerSelection([result.layerID])
      editorModel.setSelectedVectorObjects(Set(result.objectIDs))
      return

    case .duplicateInPlace:
      let result = target.vector.duplicating(ids: target.ids)
      guard !result.newIDs.isEmpty else { return }
      apply(result.layer, to: target.layerID, actionName: command.actionName)
      // The copies are what the user now works with, as when a layer is
      // duplicated.
      editorModel.setSelectedVectorObjects(Set(result.newIDs))
      return

    case .align(let alignment, let reference):
      apply(
        target.vector.aligning(
          ids: target.ids,
          to: alignment,
          reference: reference,
          pixelWidth: width,
          pixelHeight: height),
        to: target.layerID,
        actionName: command.actionName)

    case .distribute(let axis):
      apply(
        target.vector.distributing(
          ids: target.ids, axis: axis, pixelWidth: width, pixelHeight: height),
        to: target.layerID,
        actionName: command.actionName)

    case .reflect(let horizontally):
      apply(
        target.vector.reflecting(
          ids: target.ids,
          horizontally: horizontally,
          pixelWidth: width,
          pixelHeight: height),
        to: target.layerID,
        actionName: command.actionName)

    case .order(let placement):
      apply(
        target.vector.reordering(ids: target.ids, placement: placement),
        to: target.layerID,
        actionName: command.actionName)

    case .boolean(let operation):
      // A Boolean is destructive and produces an editable compound path, in one
      // step: the operands are gone and Undo is what puts them back.
      let existingIDs = Set(target.vector.objects.map(\.id))
      guard
        let combined = target.vector.combining(
          ids: target.ids, operation: operation, aspect: stack.vectorAspect)
      else { return }
      apply(combined, to: target.layerID, actionName: command.actionName)
      if let result = combined.objects.first(where: {
        $0.compound != nil && !existingIDs.contains($0.id)
      }) {
        editorModel.setSelectedVectorObjects([result.id])
      }

    case .releaseCompoundPath:
      guard let released = target.vector.releasingCompoundPaths(ids: target.ids) else { return }
      apply(released.layer, to: target.layerID, actionName: command.actionName)
      editorModel.setSelectedVectorObjects(Set(released.newIDs))

    case .setFillRule(let rule):
      apply(
        target.vector.updatingObjects(ids: target.ids) { object in
          guard var compound = object.compound else { return }
          compound.fillRule = rule
          object = .compound(compound)
        },
        to: target.layerID,
        actionName: command.actionName)
    }
  }

  /// Whether an arrangement command has something to act on, for menu
  /// validation.
  func canArrangeVectorObjects(_ command: VectorArrangeCommand) -> Bool {
    guard let target = arrangeableVectorSelection() else { return false }
    switch command {
    case .distribute: return target.ids.count >= 3
    case .align(_, let reference):
      return reference == .canvas || target.ids.count > 1
    case .boolean: return target.ids.count >= 2
    case .releaseCompoundPath, .setFillRule:
      return target.vector.objects.contains {
        target.ids.contains($0.id) && $0.compound != nil
      }
    default: return true
    }
  }

  /// The selected objects, when they are on an editable vector layer and the
  /// canvas has a size to measure against.
  private func arrangeableVectorSelection() -> (
    layerID: ProjectLayerID, vector: VectorLayer, ids: Set<UUID>
  )? {
    guard let active = editorModel.activeVectorLayer, !active.isLocked,
      editorModel.recipe.layerStack.canvas.isResolved
    else { return nil }
    let ids = editorModel.selectedVectorObjectIDs.intersection(
      Set(active.vector.objects.map(\.id)))
    guard !ids.isEmpty else { return nil }
    return (active.id, active.vector, ids)
  }

  private func apply(
    _ vector: VectorLayer, to layerID: ProjectLayerID, actionName: String
  ) {
    guard vector != editorModel.recipe.layerStack.layer(id: layerID)?.content.vectorValue
    else { return }
    perform(
      .setVectorLayer(layerID, vector, actionName: actionName), interactive: false)
  }

  // MARK: - Brush tool session

  /// Starts one Selection Brush gesture without mutating the recipe. Paint
  /// mode will store this deterministic stroke directly; Quick Select uses it
  /// as a foreground hint over the revision-tagged displayed frame frozen
  /// here.
  public func beginSelectionBrushStroke(
    with firstSample: BrushSample,
    combine: MaskCombineOperation?
  ) {
    cancelBrushStroke()
    guard let renderEngine else {
      editorModel.setRenderStatus(.failed("Metal rendering is unavailable."))
      return
    }
    let canvas = editorModel.recipe.layerStack.canvas
    guard canvas.isResolved,
      canvas.width <= BrushLimits.maximumCanvasAxis,
      canvas.height <= BrushLimits.maximumCanvasAxis
    else {
      editorModel.setRenderStatus(.failed("Set a supported canvas size before selecting."))
      return
    }

    let state = editorModel.selectionBrushTool
    let sourceFrame: RenderedFrame?
    if state.mode == .quickSelect {
      guard let displayedFrame = editorModel.renderedFrame,
        MagnetSelectionSupport.acceptsDisplayedFrame(
          documentID: projectID,
          renderRevision: revision,
          frameDocumentID: displayedFrame.documentID,
          frameRevision: displayedFrame.revision,
          frameIsProxy: displayedFrame.isProxy)
      else {
        editorModel.setRenderStatus(
          .failed("Wait for the canvas to finish rendering before using Quick Select."))
        return
      }
      if state.sampleSource == .activeLayer {
        guard let layerID = editorModel.recipe.layerStack.activeLayerID,
          let activeLayer = editorModel.recipe.layerStack.layer(id: layerID),
          activeLayer.isRasterContent,
          displayedFrame.sampledActiveLayerID == layerID,
          displayedFrame.activeLayerSamplingSurface != nil
        else {
          editorModel.setRenderStatus(
            .failed(
              "Current Layer sampling needs a visible RAW, image, paint, or text layer from the displayed frame."
            ))
          return
        }
      }
      sourceFrame = displayedFrame
    } else {
      sourceFrame = nil
    }

    let settings = state.mode == .paint ? state.brushSettings : state.quickHintSettings
    let cacheID = "selection-brush-preview:\(UUID().uuidString)"
    activeSelectionBrushSession = ActiveSelectionBrushSession(
      cacheID: cacheID,
      stroke: PaintStroke(
        seed: UInt64.random(in: UInt64.min...UInt64.max),
        mode: .paint,
        settings: settings,
        brush: BrushCatalog.hardRound.definition,
        color: .white,
        selectionClip: nil,
        samples: [firstSample]),
      state: state,
      combine: combine,
      selectionAtStart: editorModel.recipe.selection,
      sourceFrame: sourceFrame,
      baseContentRevision: contentRevision)
    updateSelectionBrushPreview(using: renderEngine, canvas: canvas)
  }

  /// Begins transient paint without touching the recipe. Settings and color
  /// are copied now, so changing a control later cannot change this stroke.
  public func beginBrushStroke(with firstSample: BrushSample) {
    cancelBrushStroke()
    guard let renderEngine else {
      editorModel.setRenderStatus(.failed("Metal rendering is unavailable."))
      return
    }
    let canvas = editorModel.recipe.layerStack.canvas
    guard canvas.isResolved,
      canvas.width <= BrushLimits.maximumCanvasAxis,
      canvas.height <= BrushLimits.maximumCanvasAxis
    else {
      editorModel.setRenderStatus(.failed("Set a supported canvas size before painting."))
      return
    }
    // A heal captures the same stroke but resolves a different destination and
    // has its own readiness to check, so it branches before the paint target
    // is worked out rather than threading a second meaning through it.
    if editorModel.activeTool == .heal {
      beginHealStroke(with: firstSample, renderEngine: renderEngine, canvas: canvas)
      return
    }

    let mode: BrushStrokeMode
    switch editorModel.activeTool {
    case .brush: mode = .paint
    case .eraser: mode = .erase
    default: return
    }

    let activeID = editorModel.recipe.layerStack.activeLayerID
    let requestedTarget = editorModel.resolvedPaintTarget
      ?? .layerPixels(activeID ?? .canvas)
    var target = requestedTarget
    let targetPaintLayerID: ProjectLayerID?
    var erasesImageLayer = false
    var inputTransforms: [LayerTransform] = []
    switch requestedTarget {
    case .layerMask(let layerID, let maskID):
      maskPaintLogger.debug(
        "Begin \(mode.rawValue, privacy: .public) layer=\(layerID.rawValue, privacy: .public) mask=\(maskID.rawValue, privacy: .public)"
      )
      guard let layer = editorModel.recipe.layerStack.layer(id: layerID) else {
        maskPaintLogger.error(
          "Rejected mask stroke: layer is missing layer=\(layerID.rawValue, privacy: .public)"
        )
        editorModel.setRenderStatus(.failed("The selected layer no longer exists."))
        return
      }
      guard !layer.isLocked else {
        maskPaintLogger.error(
          "Rejected mask stroke: layer is locked layer=\(layerID.rawValue, privacy: .public)"
        )
        editorModel.setRenderStatus(.failed("Unlock the layer before painting its mask."))
        return
      }
      guard let mask = layer.layerMask else {
        maskPaintLogger.error(
          "Rejected mask stroke: layer has no layer mask layer=\(layerID.rawValue, privacy: .public)"
        )
        editorModel.setRenderStatus(.failed("Add a layer mask before painting."))
        return
      }
      guard mask.id == maskID else {
        maskPaintLogger.error(
          "Rejected mask stroke: target mask is stale layer=\(layerID.rawValue, privacy: .public) requested=\(maskID.rawValue, privacy: .public) current=\(mask.id.rawValue, privacy: .public)"
        )
        editorModel.setPaintTarget(.layerMask(layerID, mask.id))
        editorModel.setRenderStatus(
          .failed("The layer mask changed. Its current mask is selected; paint again."))
        return
      }
      guard mask.isEnabled else {
        maskPaintLogger.error(
          "Rejected mask stroke: mask is disabled layer=\(layerID.rawValue, privacy: .public) mask=\(mask.id.rawValue, privacy: .public)"
        )
        editorModel.setRenderStatus(.failed("Enable the layer mask before painting."))
        return
      }
      guard mask.strokeSurface != nil else {
        maskPaintLogger.error(
          "Rejected mask stroke: mask has no paint surface layer=\(layerID.rawValue, privacy: .public) mask=\(mask.id.rawValue, privacy: .public) inverted=\(mask.isInverted, privacy: .public)"
        )
        editorModel.setRenderStatus(.failed("This layer mask is not paintable."))
        return
      }
      maskPaintLogger.debug(
        "Accepted mask stroke layer=\(layerID.rawValue, privacy: .public) mask=\(mask.id.rawValue, privacy: .public) inverted=\(mask.isInverted, privacy: .public)"
      )
      targetPaintLayerID = nil
    case .layerPixels(let requestedLayerID):
      let requestedLayer = editorModel.recipe.layerStack.layer(id: requestedLayerID)
      if mode == .erase, let requestedLayer, requestedLayer.isImageLayer {
        guard !requestedLayer.isLocked else {
          editorModel.setRenderStatus(.failed("Unlock the image layer before erasing."))
          return
        }
        if let mask = requestedLayer.layerMask {
          guard mask.isEnabled else {
            editorModel.setRenderStatus(.failed("Enable the image layer mask before erasing."))
            return
          }
          guard mask.strokeSurface != nil else {
            editorModel.setRenderStatus(.failed("The image layer mask is not paintable."))
            return
          }
          target = .layerMask(requestedLayer.id, mask.id)
        } else {
          let maskID = MaskID()
          target = .layerMask(requestedLayer.id, maskID)
        }
        erasesImageLayer = true
        targetPaintLayerID = nil
      } else {
        targetPaintLayerID =
          if let requestedLayer, requestedLayer.isPaintLayer, !requestedLayer.isLocked,
            requestedLayer.paintLayer?.acceptsBrushStrokes == true
          {
            requestedLayer.id
          } else {
            nil
          }
        if mode == .erase, targetPaintLayerID == nil {
          editorModel.setRenderStatus(.failed("Select an unlocked paint layer before erasing pixels."))
          return
        }
      }
    }
    if case .layerMask(let layerID, _) = target,
      let entry = editorModel.recipe.layerStack.entry(id: layerID)
    {
      inputTransforms = (entry.ancestorIDs + [layerID]).compactMap {
        editorModel.recipe.layerStack.layer(id: $0)?.transform
      }
    }

    let cacheID = "brush-preview:\(UUID().uuidString)"
    let authoredFirstSample = sample(firstSample, inverseThrough: inputTransforms)
    var strokeSettings = editorModel.activeBrushSettings
    let magnification = inputTransforms.reduce(1.0) { partial, transform in
      partial * max((abs(transform.scaleX) + abs(transform.scaleY)) / 2, 0.000_1)
    }
    strokeSettings.size /= magnification
    activeBrushSession = ActiveBrushSession(
      cacheID: cacheID,
      stroke: PaintStroke(
        seed: UInt64.random(in: UInt64.min...UInt64.max),
        mode: mode,
        settings: strokeSettings,
        brush: editorModel.activeBrushDefinition,
        color: editorModel.brushColor,
        selectionClip: editorModel.recipe.selection,
        samples: [authoredFirstSample]
      ),
      target: target,
      targetPaintLayerID: targetPaintLayerID,
      erasesImageLayer: erasesImageLayer,
      inputTransforms: inputTransforms,
      baseContentRevision: contentRevision
    )
    updateBrushPreview(using: renderEngine, canvas: canvas)
  }

  /// Extends only the transient stroke and asks the render actor to stamp its
  /// new segments. No recipe, history, undo, or full-frame render changes.
  public func appendBrushSamples(_ samples: [BrushSample]) {
    if var session = activeSelectionBrushSession, !samples.isEmpty {
      let remaining = BrushLimits.maximumSamplesPerStroke - session.stroke.samples.count
      guard remaining > 0 else { return }
      session.stroke.samples.append(contentsOf: samples.prefix(remaining))
      activeSelectionBrushSession = session
      if let renderEngine {
        updateSelectionBrushPreview(
          using: renderEngine, canvas: editorModel.recipe.layerStack.canvas)
      }
      return
    }
    guard var session = activeBrushSession, !samples.isEmpty else { return }
    let remaining = BrushLimits.maximumSamplesPerStroke - session.stroke.samples.count
    guard remaining > 0 else { return }
    session.stroke.samples.append(
      contentsOf: samples.prefix(remaining).map {
        sample($0, inverseThrough: session.inputTransforms)
      })
    activeBrushSession = session
    guard let renderEngine else { return }
    updateBrushPreview(using: renderEngine, canvas: editorModel.recipe.layerStack.canvas)
  }

  /// Commits exactly one stroke action and leaves the last provisional tile on
  /// screen until the revision-tagged document frame replaces it.
  public func commitBrushStroke() {
    guard let session = activeBrushSession, !session.stroke.samples.isEmpty else { return }
    // A heal captured through the same session must never be committed as
    // paint: its stroke is coverage, and its colour is meaningless.
    guard session.heal == nil else {
      commitHealStroke()
      return
    }
    activeBrushSession = nil
    brushPreviewGeneration &+= 1
    brushPreviewTask?.cancel()
    brushPreviewTask = nil
    switch session.target {
    case .layerMask(let layerID, let maskID):
      if session.erasesImageLayer {
        perform(.commitImageEraserStroke(layerID, maskID, session.stroke), interactive: false)
      } else {
        perform(.commitLayerMaskStroke(layerID, maskID, session.stroke), interactive: false)
      }
      if let mask = editorModel.recipe.layerStack.layer(id: layerID)?.layerMask,
        mask.id == maskID,
        // Keep the image target on an inverted mask: selecting the thumbnail
        // would make the next Eraser stroke paint black and reveal the image.
        !session.erasesImageLayer || !mask.isInverted
      {
        editorModel.setPaintTarget(.layerMask(layerID, maskID))
      }
    case .layerPixels:
      let newLayerID = ProjectLayerID()
      perform(
        .commitBrushStroke(
          session.stroke,
          toPaintLayer: session.targetPaintLayerID,
          newLayerID: newLayerID
        ),
        interactive: false
      )
      if session.targetPaintLayerID == nil,
        editorModel.recipe.layerStack.layer(id: newLayerID)?.isPaintLayer == true
      {
        editorModel.setPaintTarget(.layerPixels(newLayerID))
      }
    }
    if let renderEngine {
      Task { await renderEngine.discardStrokeSurface(cacheID: session.cacheID) }
    }
  }

  /// Commits Paint immediately as a deterministic mask stroke, or starts one
  /// cancellable bounded analysis for Quick Select. Both paths create exactly
  /// one selection history step through the shared commit boundary.
  public func commitSelectionBrushStroke() {
    guard let session = activeSelectionBrushSession, !session.stroke.samples.isEmpty else {
      return
    }
    activeSelectionBrushSession = nil
    brushPreviewGeneration &+= 1
    brushPreviewTask?.cancel()
    brushPreviewTask = nil
    editorModel.setBrushPreview(nil)
    if let renderEngine {
      Task { await renderEngine.discardStrokeSurface(cacheID: session.cacheID) }
    }
    guard contentRevision == session.baseContentRevision,
      editorModel.recipe.selection == session.selectionAtStart
    else {
      editorModel.setRenderStatus(
        .failed("The selection changed during the brush gesture. Paint the stroke again."))
      return
    }

    switch session.state.mode {
    case .paint:
      let captured = MaskRecipe.single(
        .strokeSurface(StrokeSurfaceRecipe(kind: .mask, strokes: [session.stroke])),
        name: SelectionBrushMode.paint.label)
      guard let commit = CapturedSelectionSupport.commit(
        captured: captured,
        existing: session.selectionAtStart,
        componentName: SelectionBrushMode.paint.label,
        defaultActionName: "Brush Selection",
        combine: session.combine,
        feather: session.state.feather)
      else { return }
      setSelection(commit.selection, actionName: commit.actionName)
      editorModel.setRenderStatus(.ready("Paint selection updated."))

    case .quickSelect:
      guard let renderEngine, let sourceFrame = session.sourceFrame else {
        editorModel.setRenderStatus(.failed("Quick Select pixels are no longer available."))
        return
      }
      selectionBrushTask?.cancel()
      selectionBrushGeneration &+= 1
      let generation = selectionBrushGeneration
      editorModel.setRenderStatus(.preparing("Expanding the painted selection hint…"))
      selectionBrushTask = Task { [weak self] in
        guard let self else { return }
        defer {
          if generation == self.selectionBrushGeneration {
            self.selectionBrushTask = nil
          }
        }
        do {
          let captured = try await renderEngine.quickSelectionMask(
            in: sourceFrame,
            source: session.state.sampleSource,
            hints: session.stroke,
            tolerance: session.state.tolerance,
            edgeSensitivity: session.state.edgeSensitivity,
            smoothness: session.state.smoothness)
          try Task.checkCancellation()
          guard generation == self.selectionBrushGeneration else { return }
          guard self.contentRevision == session.baseContentRevision,
            self.editorModel.recipe.selection == session.selectionAtStart
          else {
            self.editorModel.setRenderStatus(
              .failed("The document changed while Quick Select was analysing it. Paint again."))
            return
          }
          guard let captured,
            let commit = CapturedSelectionSupport.commit(
              captured: captured,
              existing: session.selectionAtStart,
              componentName: SelectionBrushMode.quickSelect.label,
              defaultActionName: "Quick Selection",
              combine: session.combine,
              feather: session.state.feather)
          else {
            self.editorModel.setRenderStatus(
              .failed("Quick Select could not produce usable coverage. Paint another hint."))
            return
          }
          self.setSelection(commit.selection, actionName: commit.actionName)
          self.editorModel.setRenderStatus(.ready("Quick Select updated the selection."))
        } catch is CancellationError {
          // A newer Selection Brush gesture superseded this analysis.
        } catch {
          guard generation == self.selectionBrushGeneration else { return }
          self.editorModel.setRenderStatus(.failed(error.userFacingMessage))
        }
      }
    }
  }

  /// Solves the captured heal stroke and commits it as one undoable patch.
  ///
  /// Release is where the work happens. The stroke's coverage says which
  /// pixels to replace; the solve reads full-quality pixels through the render
  /// actor, reconstructs them, and the result is stored as project-local
  /// pixels on a healing layer above the image. A patch solved against a
  /// revision the document has since left behind is discarded rather than
  /// committed against pixels it never saw.
  public func commitHealStroke() {
    guard let session = activeBrushSession, let heal = session.heal,
      !session.stroke.samples.isEmpty
    else { return }
    activeBrushSession = nil
    brushPreviewGeneration &+= 1
    brushPreviewTask?.cancel()
    brushPreviewTask = nil

    guard let renderEngine else {
      editorModel.setBrushPreview(nil)
      return
    }
    let canvas = editorModel.recipe.layerStack.canvas
    guard canvas.isResolved else {
      editorModel.setBrushPreview(nil)
      return
    }
    guard let bounds = healPatchBounds(for: session.stroke, in: canvas) else {
      editorModel.setBrushPreview(nil)
      editorModel.setRenderStatus(.failed("That stroke covers no pixels to heal."))
      return
    }

    let coverage = MaskRecipe.healCoverage(session.stroke)
    let renderRequest: RenderRequest
    do {
      renderRequest = try healSourceRequest(for: heal.tool.sampleSource)
    } catch {
      editorModel.setBrushPreview(nil)
      editorModel.setRenderStatus(.failed(error.userFacingMessage))
      return
    }

    let solveRequest = HealSolveRequest(
      render: renderRequest,
      coverage: coverage,
      bounds: bounds,
      canvasSize: CGSize(width: canvas.width, height: canvas.height),
      mode: heal.tool.mode,
      sourceOffsetX: heal.sourceOffsetX,
      sourceOffsetY: heal.sourceOffsetY,
      blend: heal.tool.blend,
      iterations: heal.tool.solverIterations,
      cacheID: session.cacheID
    )
    let capturedRevision = contentRevision
    let targetPaintLayerID = session.targetPaintLayerID
    editorModel.setLayerOperationStatus(.healing)
    healSolveTask?.cancel()
    healSolveTask = Task { [weak self] in
      guard let self else { return }
      defer { self.healSolveTask = nil }
      do {
        let solved = try await renderEngine.solveHeal(solveRequest)
        try Task.checkCancellation()
        guard self.contentRevision == capturedRevision else {
          self.editorModel.setLayerOperationStatus(
            .failed("The image changed while that heal was being solved. Try again."))
          self.editorModel.setBrushPreview(nil)
          return
        }
        guard let solved else {
          self.editorModel.setLayerOperationStatus(.idle)
          self.editorModel.setBrushPreview(nil)
          self.editorModel.setRenderStatus(
            .failed("There was nothing to heal under that stroke."))
          return
        }
        self.rasterAssets[solved.raster.reference.id] = solved.raster.compressedPixels
        let patch = PaintHealRecipe(
          patch: solved.raster.reference,
          frame: solved.frame,
          coverage: coverage,
          provenance: HealProvenance(
            mode: heal.tool.mode,
            sourceOffsetX: heal.sourceOffsetX,
            sourceOffsetY: heal.sourceOffsetY,
            sampleSource: heal.tool.sampleSource,
            blend: heal.tool.blend,
            solverIterations: heal.tool.solverIterations,
            baseContentRevision: capturedRevision
          )
        )
        let newLayerID = ProjectLayerID()
        self.perform(
          .commitHeal(patch, toPaintLayer: targetPaintLayerID, newLayerID: newLayerID),
          interactive: false
        )
        self.editorModel.setLayerOperationStatus(.idle)
      } catch is CancellationError {
        self.editorModel.setLayerOperationStatus(.idle)
        self.editorModel.setBrushPreview(nil)
      } catch {
        self.editorModel.setLayerOperationStatus(.failed(error.userFacingMessage))
        self.editorModel.setBrushPreview(nil)
      }
      if let renderEngine = self.renderEngine {
        // Two entries: the provisional preview's, and the one the solve made
        // when it evaluated the same coverage at canvas resolution.
        await renderEngine.discardStrokeSurface(cacheID: session.cacheID)
        await renderEngine.discardStrokeSurface(cacheID: "heal-coverage:\(session.cacheID)")
      }
    }
  }

  /// The region a heal patch has to cover: the stroke's own footprint, grown
  /// by a ring of surrounding pixels for the solve to meet, clamped to the
  /// canvas and snapped to whole pixels.
  ///
  /// Without the ring there would be no boundary condition — the solve would
  /// have only the pixels it is replacing to work from.
  private func healPatchBounds(
    for stroke: PaintStroke,
    in canvas: CanvasRecipe
  ) -> CGRect? {
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    for sample in stroke.samples {
      let diameter = stroke.settings.size
        * max(stroke.settings.mappedPressure(sample.pressure), 0.05)
      let radius = diameter / 2
      minX = min(minX, sample.x - radius)
      minY = min(minY, sample.y - radius)
      maxX = max(maxX, sample.x + radius)
      maxY = max(maxY, sample.y + radius)
    }
    guard minX <= maxX, minY <= maxY else { return nil }
    // Wide enough to carry the destination's colour and brightness into the
    // solve, and proportional to the tip so a large heal gets a large ring.
    let ring = max(8.0, stroke.settings.size * 0.35)
    let rect = CGRect(
      x: (minX - ring).rounded(.down),
      y: (minY - ring).rounded(.down),
      width: (maxX + ring).rounded(.up) - (minX - ring).rounded(.down),
      height: (maxY + ring).rounded(.up) - (minY - ring).rounded(.down)
    ).intersection(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
    guard !rect.isNull, rect.width > 2, rect.height > 2 else { return nil }
    return rect
  }

  /// The render the heal reads its pixels from.
  ///
  /// Always full quality: the frame on screen may be a proxy, and a patch
  /// solved from one would be soft. Current Layer isolates the active layer
  /// the same way the Fill tool's does.
  private func healSourceRequest(for source: HealSampleSource) throws -> RenderRequest {
    var request = try makeRenderRequest(quality: .full)
    guard source == .activeLayer else { return request }
    guard let activeLayer = editorModel.recipe.layerStack.activeLayerID.flatMap({
      editorModel.recipe.layerStack.layer(id: $0)
    }), activeLayer.isRasterContent,
      let entry = editorModel.recipe.layerStack.entry(id: activeLayer.id)
    else {
      throw PixeltjeMacError(
        "Nothing to heal from",
        "Current Layer healing needs a RAW, image, paint, or text layer. Choose All Layers instead."
      )
    }
    var isolated = request.recipe
    let retained = Set(entry.ancestorIDs + [activeLayer.id])
    for candidate in isolated.layerStack.flattenedLayers
    where candidate.id != .canvas && !retained.contains(candidate.id) {
      isolated.layerStack.updateLayer(id: candidate.id) { $0.isEnabled = false }
    }
    request.recipe = isolated
    return request
  }

  /// Opens a Healing Brush stroke.
  ///
  /// The stroke captured here is coverage, not colour: it says which pixels
  /// the patch will replace. Nothing is solved until release, because a
  /// gradient-domain solve per pointer event is not affordable and a heal has
  /// no useful partial result to show.
  private func beginHealStroke(
    with firstSample: BrushSample,
    renderEngine: RenderEngine,
    canvas: CanvasRecipe
  ) {
    let tool = editorModel.healTool
    guard tool.isReadyToPaint else {
      editorModel.setRenderStatus(
        .failed("Option-click to set a source before healing from a source point."))
      return
    }
    // A heal needs pixels to read. Nothing rendered yet means nothing to heal
    // from, and saying so now is better than solving an empty patch later.
    guard editorModel.renderedFrame != nil else {
      editorModel.setRenderStatus(.failed("Wait for the canvas to finish rendering before healing."))
      return
    }
    // Before shows the captured RAW defaults, not the document. Healing from
    // it would bake pixels the recipe does not contain into the recipe.
    guard !editorModel.isShowingBefore else {
      editorModel.setRenderStatus(
        .failed("Turn off Before to heal. It shows the captured defaults, not the edit."))
      return
    }

    var offsetX = 0.0
    var offsetY = 0.0
    if tool.mode == .sourcePoint, let anchor = tool.sourceAnchor {
      offsetX = anchor.x * Double(canvas.width) - firstSample.x
      offsetY = anchor.y * Double(canvas.height) - firstSample.y
    }

    // Heals accumulate on a layer that holds only heals, so a retouching
    // session is one layer rather than one per dab. A transformed layer is
    // excluded: its pixels no longer sit where the patch was solved.
    let activeID = editorModel.recipe.layerStack.activeLayerID
    let candidate = activeID.flatMap { editorModel.recipe.layerStack.layer(id: $0) }
    let targetPaintLayerID: ProjectLayerID? =
      if let candidate, candidate.isPaintLayer, !candidate.isLocked,
        candidate.transform == nil, candidate.paintLayer?.acceptsHeals == true
      {
        candidate.id
      } else {
        nil
      }

    let cacheID = "heal-preview:\(UUID().uuidString)"
    activeBrushSession = ActiveBrushSession(
      cacheID: cacheID,
      stroke: PaintStroke(
        seed: UInt64.random(in: UInt64.min...UInt64.max),
        mode: .paint,
        settings: tool.settings,
        brush: BrushDefinition.healCoverage,
        color: .white,
        selectionClip: editorModel.recipe.selection,
        samples: [firstSample]
      ),
      target: .layerPixels(targetPaintLayerID ?? activeID ?? .canvas),
      targetPaintLayerID: targetPaintLayerID,
      erasesImageLayer: false,
      // A heal is authored in canvas space and lands on an untransformed
      // healing layer, so there is no transform chain to map input through.
      inputTransforms: [],
      baseContentRevision: contentRevision,
      heal: HealSessionContext(
        tool: tool, sourceOffsetX: offsetX, sourceOffsetY: offsetY)
    )
    updateBrushPreview(using: renderEngine, canvas: canvas)
  }

  /// Fills the brush library's row previews, once per document session. They
  /// come from the same render engine and the same stroke surface as painting
  /// does, so a row cannot drift from what the brush actually puts down.
  public func loadBrushLibraryPreviews() {
    guard !brushLibraryPreviewsRequested, let renderEngine else { return }
    brushLibraryPreviewsRequested = true
    Task { [weak self] in
      for preset in BrushCatalog.presets {
        guard !Task.isCancelled else { return }
        // A row that never gets its preview still shows its name, so one
        // failure must not stop the rest of the library from arriving.
        guard let image = try? await renderEngine.brushPresetPreviewImage(preset.id) else {
          continue
        }
        guard let self else { return }
        self.editorModel.setBrushPresetPreview(image, for: preset.id)
      }
    }
  }

  /// Cancels provisional work without creating a recipe or history change.
  public func cancelBrushStroke() {
    selectionBrushGeneration &+= 1
    selectionBrushTask?.cancel()
    selectionBrushTask = nil
    if let session = activeSelectionBrushSession {
      activeSelectionBrushSession = nil
      brushPreviewGeneration &+= 1
      brushPreviewTask?.cancel()
      brushPreviewTask = nil
      editorModel.setBrushPreview(nil)
      if let renderEngine {
        Task { await renderEngine.discardStrokeSurface(cacheID: session.cacheID) }
      }
      return
    }
    guard let session = activeBrushSession else {
      editorModel.setBrushPreview(nil)
      return
    }
    activeBrushSession = nil
    brushPreviewGeneration &+= 1
    brushPreviewTask?.cancel()
    brushPreviewTask = nil
    editorModel.setBrushPreview(nil)
    if let renderEngine {
      Task { await renderEngine.discardStrokeSurface(cacheID: session.cacheID) }
    }
  }

  private func updateSelectionBrushPreview(
    using renderEngine: RenderEngine,
    canvas: CanvasRecipe
  ) {
    guard let session = activeSelectionBrushSession, canvas.isResolved else { return }
    brushPreviewGeneration &+= 1
    let generation = brushPreviewGeneration
    let request = StrokeSurfaceRequest(
      cacheID: session.cacheID,
      recipe: StrokeSurfaceRecipe(kind: .mask, strokes: [session.stroke]),
      width: canvas.width,
      height: canvas.height)
    brushPreviewTask?.cancel()
    brushPreviewTask = Task { [weak self] in
      do {
        let frame = try await renderEngine.renderStrokeSurface(request)
        guard let self,
          self.brushPreviewGeneration == generation,
          self.activeSelectionBrushSession?.cacheID == session.cacheID,
          self.contentRevision == session.baseContentRevision
        else { return }
        self.editorModel.setBrushPreview(
          BrushPreview(
            frame: frame,
            baseContentRevision: session.baseContentRevision,
            strokeMode: session.combine == .subtract ? .erase : .paint))
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.brushPreviewGeneration == generation else { return }
        self.editorModel.setRenderStatus(.failed(error.userFacingMessage))
      }
    }
  }

  private func updateBrushPreview(using renderEngine: RenderEngine, canvas: CanvasRecipe) {
    guard let session = activeBrushSession, canvas.isResolved else { return }
    brushPreviewGeneration &+= 1
    let generation = brushPreviewGeneration
    var previewStroke = session.stroke
    var isMaskTarget: Bool
    if case .layerMask = session.target { isMaskTarget = true } else { isMaskTarget = false }
    // A heal has no result to show until it is solved, so the drag presents
    // its coverage through the same one-channel path a mask stroke uses. The
    // canvas tints it distinctly.
    let isHealCoverage = session.heal != nil
    if isHealCoverage { isMaskTarget = true }
    if previewStroke.mode == .erase || isMaskTarget {
      // Until layer-isolated presentation exists, show pixel erasure and mask
      // coverage as a translucent guide during the gesture.
      previewStroke.mode = .paint
      previewStroke.color = LinearRGBAColor(red: 1, green: 1, blue: 1, alpha: 0.35)
    }
    let request = StrokeSurfaceRequest(
      cacheID: session.cacheID,
      recipe: StrokeSurfaceRecipe(
        kind: isMaskTarget ? .mask : .colorRGBA,
        strokes: [previewStroke]),
      width: canvas.width,
      height: canvas.height
    )
    brushPreviewTask?.cancel()
    brushPreviewTask = Task { [weak self] in
      do {
        let frame = try await renderEngine.renderStrokeSurface(request)
        guard let self,
          self.brushPreviewGeneration == generation,
          self.activeBrushSession?.cacheID == session.cacheID,
          self.contentRevision == session.baseContentRevision
        else { return }
        self.editorModel.setBrushPreview(
          BrushPreview(
            frame: frame,
            baseContentRevision: session.baseContentRevision,
            target: session.target,
            strokeMode: session.stroke.mode,
            isHealCoverage: isHealCoverage))
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.brushPreviewGeneration == generation else { return }
        self.editorModel.setRenderStatus(.failed(error.userFacingMessage))
      }
    }
  }

  private func sample(
    _ sample: BrushSample,
    inverseThrough transforms: [LayerTransform]
  ) -> BrushSample {
    var point = PixelPoint(x: sample.x, y: sample.y)
    for transform in transforms {
      guard let mapped = transform.inverseAffine(point) else { continue }
      point = mapped
    }
    return BrushSample(
      x: point.x,
      y: point.y,
      pressure: sample.pressure,
      tiltX: sample.tiltX,
      tiltY: sample.tiltY,
      rotationDegrees: sample.rotationDegrees,
      reportsRotation: sample.reportsRotation,
      elapsedTime: sample.elapsedTime,
      sequence: sample.sequence)
  }

  private func cropActionName(from previous: CropRecipe, to draft: CropRecipe) -> String {
    let angleChanged = previous.angleDegrees != draft.angleDegrees
    let rectangleChanged =
      previous.left != draft.left || previous.bottom != draft.bottom
      || previous.right != draft.right || previous.top != draft.top
    switch (rectangleChanged, angleChanged) {
    case (true, true): return "Crop and Straighten"
    case (false, true): return "Straighten"
    default: return "Crop"
    }
  }

  public func beginEditGesture() {
    guard gestureStartRecipe == nil else { return }
    gestureStartRecipe = editorModel.recipe
    gestureChanged = false
    gestureRequiresRasterRender = false
  }

  // MARK: - Free Transform

  /// Opens a draft that renders but is neither saved nor recorded in history.
  public func beginTransformSession(for id: ProjectLayerID? = nil) {
    guard editorModel.transformDraft == nil else { return }
    guard let draft = transformDraft(for: id) else { return }
    editorModel.setTransformDraft(draft)
    contentRevision &+= 1
    revision &+= 1
    scheduleRender(interactive: true)
  }

  public func updateTransformDraft(_ transform: LayerTransform) {
    guard let draft = editorModel.transformDraft, transform.isValid else { return }
    editorModel.setTransformDraft(TransformDraft(targetID: draft.targetID, transform: transform))
    contentRevision &+= 1
    revision &+= 1
    scheduleRender(interactive: true)
  }

  public func commitTransformDraft() {
    guard let draft = editorModel.transformDraft else {
      resumeTransformSessionIfActive()
      return
    }
    editorModel.setTransformDraft(nil)
    // An object transform is baked into the geometry, so the recipe keeps exact
    // vector artwork instead of a transform layered over it.
    if !draft.objectIDs.isEmpty {
      if !draft.transform.isIdentity,
        let baked = editorModel.transformedVectorLayer(
          for: draft, in: editorModel.recipe.layerStack)
      {
        perform(
          .setVectorLayer(draft.targetID, baked, actionName: "Transform Vector Objects"),
          interactive: false)
      } else {
        contentRevision &+= 1
        revision &+= 1
        scheduleRender(interactive: true)
      }
      resumeTransformSessionIfActive()
      return
    }
    guard editorModel.recipe.layerStack.layer(id: draft.targetID)?.transform != draft.transform
    else {
      resumeTransformSessionIfActive()
      return
    }
    perform(.setLayerTransform(draft.targetID, draft.transform), interactive: false)
    resumeTransformSessionIfActive()
  }

  public func cancelTransformDraft() {
    guard editorModel.transformDraft != nil else {
      resumeTransformSessionIfActive()
      return
    }
    editorModel.setTransformDraft(nil)
    contentRevision &+= 1
    revision &+= 1
    scheduleRender(interactive: true)
    resumeTransformSessionIfActive()
  }

  // MARK: - Layer rasterization and merging

  /// Selects rows in the Layers panel without creating document history. The
  /// editor model retains the first-selected row as the primary tool target.
  public func selectLayers(_ ids: Set<ProjectLayerID>) {
    let previousPrimary = editorModel.recipe.layerStack.activeLayerID
    let cropTarget = editorModel.cropDraft?.target
    editorModel.setLayerSelection(ids)
    if editorModel.differencePreviewLayerID != editorModel.recipe.layerStack.activeLayerID {
      editorModel.setDifferencePreviewLayerID(nil)
    }
    guard editorModel.recipe.layerStack.activeLayerID != previousPrimary else { return }
    if editorModel.activeTool == .crop, case .some(.layer) = cropTarget {
      // Like Free Transform, a layer crop follows the primary selection. The
      // completed rectangle belongs to the old layer; the new eligible layer
      // starts its own draft, otherwise the Canvas target is the fallback.
      commitCropDraft(resume: false)
      beginCropSession()
    }
    // The composite is unchanged, but a render also carries the isolated
    // primary-layer surface used by color sampling. Give that session-only
    // refresh its own revision so an older selection cannot win the race.
    revision &+= 1
    scheduleRender(interactive: false)
  }

  public func rasterizeLayer(_ id: ProjectLayerID) {
    guard layerOperationTask == nil,
      let source = editorModel.recipe.layerStack.layer(id: id),
      source.isVectorLayer, !source.isLocked,
      source.compositing.blendMode == .normal,
      source.masks.isEmpty, source.layerMask == nil, source.transform == nil,
      editorModel.recipe.layerStack.canvas.isResolved,
      let renderEngine
    else { return }

    var content = source
    content.isEnabled = true
    content.isLocked = false
    content.compositing = .normal
    content.adjustments = .neutral
    content.masks = []
    content.layerMask = nil
    content.transform = nil

    let capturedRevision = contentRevision
    let originalContent = source.content
    let request: RenderRequest
    do {
      request = try makeLayerBakeRequest(layers: [content], activeLayerID: id)
    } catch {
      editorModel.setLayerOperationStatus(.failed(error.userFacingMessage))
      return
    }
    editorModel.setLayerOperationStatus(.rasterizing)
    layerOperationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.layerOperationTask = nil }
      do {
        let result = try await renderEngine.bakeRaster(request)
        try Task.checkCancellation()
        guard self.contentRevision == capturedRevision,
          self.editorModel.recipe.layerStack.layer(id: id)?.content == originalContent
        else {
          self.editorModel.setLayerOperationStatus(
            .failed("The layer changed while it was being rasterized. Try again."))
          return
        }
        self.rasterAssets[result.reference.id] = result.compressedPixels
        let canvas = self.editorModel.recipe.layerStack.canvas
        let raster = RasterLayerRecipe(
          asset: result.reference,
          frame: LayerFrame(
            x: 0, y: 0, width: Double(canvas.width), height: Double(canvas.height)))
        self.perform(.rasterizeLayer(id, raster), interactive: false)
        self.editorModel.setLayerSelection([id])
        self.editorModel.setLayerOperationStatus(.idle)
      } catch is CancellationError {
        self.editorModel.setLayerOperationStatus(.idle)
      } catch {
        self.editorModel.setLayerOperationStatus(.failed(error.userFacingMessage))
      }
    }
  }

  public func mergeLayers(_ ids: Set<ProjectLayerID>) {
    guard layerOperationTask == nil,
      let plan = editorModel.recipe.layerStack.mergePlan(for: ids),
      editorModel.recipe.layerStack.canvas.isResolved,
      let renderEngine
    else { return }
    let layers = plan.layerIDs.compactMap { editorModel.recipe.layerStack.layer(id: $0) }
    guard layers.count == plan.layerIDs.count else { return }

    let capturedRevision = contentRevision
    let request: RenderRequest
    do {
      request = try makeLayerBakeRequest(layers: layers, activeLayerID: plan.layerIDs.first)
    } catch {
      editorModel.setLayerOperationStatus(.failed(error.userFacingMessage))
      return
    }
    editorModel.setLayerOperationStatus(.merging(plan.layerIDs.count))
    layerOperationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.layerOperationTask = nil }
      do {
        let result = try await renderEngine.bakeRaster(request)
        try Task.checkCancellation()
        guard self.contentRevision == capturedRevision,
          self.editorModel.recipe.layerStack.mergePlan(for: ids) == plan
        else {
          self.editorModel.setLayerOperationStatus(
            .failed("The selected layers changed while they were being merged. Try again."))
          return
        }
        self.rasterAssets[result.reference.id] = result.compressedPixels
        let canvas = self.editorModel.recipe.layerStack.canvas
        let raster = RasterLayerRecipe(
          asset: result.reference,
          frame: LayerFrame(
            x: 0, y: 0, width: Double(canvas.width), height: Double(canvas.height)))
        let merged = ProjectLayer.raster(raster, name: "Merged Layers")
        self.perform(.mergeLayers(plan, merged), interactive: false)
        self.editorModel.setLayerSelection([merged.id])
        self.editorModel.setLayerOperationStatus(.idle)
      } catch is CancellationError {
        self.editorModel.setLayerOperationStatus(.idle)
      } catch {
        self.editorModel.setLayerOperationStatus(.failed(error.userFacingMessage))
      }
    }
  }

  public func cancelLayerOperation() {
    layerOperationTask?.cancel()
    editorModel.setLayerOperationStatus(.idle)
  }

  private func makeLayerBakeRequest(
    layers: [ProjectLayer],
    activeLayerID: ProjectLayerID?
  ) throws -> RenderRequest {
    var isolated = editorModel.recipe
    let canvas = isolated.layerStack.canvas
    isolated.layerStack = LayerStackRecipe(layers: layers, activeLayerID: activeLayerID)
    isolated.layerStack.canvas = canvas
    return RenderRequest(
      documentID: projectID,
      revision: revision,
      contentRevision: contentRevision,
      rawInputs: try rawInputs(in: isolated),
      rasterAssets: try rasterAssets(in: isolated),
      recipe: isolated,
      quality: .full
    )
  }

  /// The Transform tool is persistent: Apply and Cancel end one draft and
  /// immediately make the selected eligible layer ready for the next edit.
  /// Switching tools changes `activeTool` first, so leaving Transform does not
  /// accidentally reopen the session being dismissed.
  private func resumeTransformSessionIfActive() {
    guard editorModel.activeTool == .transform,
      editorModel.transformDraft == nil,
      let draft = transformDraft(for: nil)
    else { return }
    editorModel.setTransformDraft(draft)
  }

  private func transformDraft(for id: ProjectLayerID?) -> TransformDraft? {
    let stack = editorModel.recipe.layerStack
    guard let targetID = id ?? stack.activeLayerID else { return nil }
    // A vector layer takes no layer transform: Free Transform reshapes the
    // selected objects instead, and bakes the result into their geometry.
    if let objects = vectorObjectTransformDraft(for: targetID) { return objects }
    guard stack.canTransform(targetID), let frame = stack.frame(of: targetID) else { return nil }
    let transform = stack.layer(id: targetID)?.transform ?? .identity(for: frame)
    return TransformDraft(targetID: targetID, transform: transform)
  }

  /// A draft that transforms the selected objects of a vector layer.
  ///
  /// The reference rectangle is the selection's own extent, so the handles and
  /// the numeric fields describe what is actually being moved rather than the
  /// whole layer.
  private func vectorObjectTransformDraft(for id: ProjectLayerID) -> TransformDraft? {
    let stack = editorModel.recipe.layerStack
    guard let layer = stack.layer(id: id), case .vector(let vector) = layer.content,
      !layer.isLocked, stack.canvas.isResolved
    else { return nil }
    let objectIDs = editorModel.selectedVectorObjectIDs.intersection(
      Set(vector.objects.map(\.id)))
    guard !objectIDs.isEmpty else { return nil }
    let width = Double(stack.canvas.width)
    let height = Double(stack.canvas.height)
    guard let box = vector.bounds(of: objectIDs, pixelWidth: width, pixelHeight: height)
    else { return nil }
    let frame = LayerFrame(
      x: box.minX * width,
      y: box.minY * height,
      width: box.width * width,
      height: box.height * height
    )
    guard !frame.isEmpty else { return nil }
    return TransformDraft(
      targetID: id, transform: .identity(for: frame), objectIDs: objectIDs)
  }

  public func perform(_ action: EditorAction, interactive: Bool) {
    let old = editorModel.recipe
    let updated = old.applying(action)
    guard updated != old else { return }
    // Whether an action moves pixels can depend on the layer it names, so it is
    // decided once, against the recipe the action was formed for.
    let requiresRasterRender = action.requiresRasterRender(in: old)
    contentRevision &+= 1
    if requiresRasterRender {
      revision &+= 1
    }

    if gestureStartRecipe != nil {
      // A drag is one step, not one per event: intermediate recipes drive the
      // preview without entering the history.
      editorModel.setTransientRecipe(updated)
      gestureChanged = true
      gestureRequiresRasterRender = gestureRequiresRasterRender || requiresRasterRender
    } else {
      commitEdit(
        updated,
        actionName: actionName(for: action),
        requiresRasterRender: requiresRasterRender
      )
    }
    if requiresRasterRender {
      scheduleRender(interactive: interactive)
    }
  }

  /// The optimistic-concurrency token exposed to automation clients.
  ///
  /// It advances for every committed recipe change, including edits that do
  /// not require another raster render. The render revision is deliberately a
  /// separate implementation detail.
  var automationContentRevision: UInt64 { contentRevision }

  /// Whether the window currently owns uncommitted edit intent.
  ///
  /// Automation never steals or commits a human's in-flight gesture. The
  /// caller can retry after the gesture or background layer operation ends.
  var isBusyForAutomation: Bool {
    gestureStartRecipe != nil || activeBrushSession != nil
      || activeSelectionBrushSession != nil || selectionBrushTask != nil
      || editorModel.cropDraft != nil || editorModel.transformDraft != nil
      || editorModel.selectionDraft != nil || editorModel.layerOperationStatus.isRunning
      || editorModel.generationJobs.contains(where: { $0.state.isActive })
  }

  // MARK: - Prompt-driven ComfyUI generation

  private var comfyUIDebugSink: ComfyUIDebugSink {
    { [weak self] event in
      self?.recordComfyUIDebug(event)
    }
  }

  private func recordComfyUIDebug(stage: String, message: String) {
    recordComfyUIDebug(ComfyUIDebugEvent(stage: stage, message: message))
  }

  private func recordComfyUIDebug(_ event: ComfyUIDebugEvent) {
    editorModel.appendComfyUIDebugEvent(event)
    guard let logger = comfyUIDebugDiskLogger else { return }
    Task { [weak self] in
      do {
        try await logger.append(event)
      } catch {
        self?.failComfyUIDebugDiskLogging(error, logger: logger)
      }
    }
  }

  private func recordComfyUIDebugImage(_ image: ComfyUIDebugImage) {
    editorModel.appendComfyUIDebugImage(image)
    guard let logger = comfyUIDebugDiskLogger else { return }
    Task { [weak self] in
      do {
        try await logger.append(image)
      } catch {
        self?.failComfyUIDebugDiskLogging(error, logger: logger)
      }
    }
  }

  func setComfyUIDebugDiskLoggingEnabled(_ enabled: Bool) {
    if !enabled {
      comfyUIDebugDiskLogger = nil
      editorModel.setComfyUIDebugDiskLoggingState(.disabled)
      return
    }
    guard comfyUIDebugDiskLogger == nil else { return }

    let existingEvents = editorModel.comfyUIDebugEvents
    let existingImages = editorModel.comfyUIDebugImages
    let logger = ComfyUIDebugDiskLogger(documentID: projectID)
    comfyUIDebugDiskLogger = logger
    editorModel.setComfyUIDebugDiskLoggingState(.starting)
    Task { [weak self] in
      do {
        let directory = try await logger.start(
          existingEvents: existingEvents,
          existingImages: existingImages)
        guard let self, self.comfyUIDebugDiskLogger === logger else { return }
        self.editorModel.setComfyUIDebugDiskLoggingState(.enabled(directory))
        self.recordComfyUIDebug(
          stage: "Debug logging",
          message: "ComfyUI disk logging enabled.\nFolder: \(directory.path(percentEncoded: false))")
      } catch {
        self?.failComfyUIDebugDiskLogging(error, logger: logger)
      }
    }
  }

  func revealComfyUIDebugLog() {
    guard
      let directory = editorModel.comfyUIDebugDiskLoggingState.directoryURL
    else { return }
    NSWorkspace.shared.activateFileViewerSelecting([directory])
  }

  private func failComfyUIDebugDiskLogging(
    _ error: Error,
    logger: ComfyUIDebugDiskLogger
  ) {
    guard comfyUIDebugDiskLogger === logger else { return }
    comfyUIDebugDiskLogger = nil
    let message = error.localizedDescription
    editorModel.setComfyUIDebugDiskLoggingState(.failed(message))
    editorModel.appendComfyUIDebugEvent(
      ComfyUIDebugEvent(
        stage: "Debug logging",
        message: "ComfyUI disk logging stopped: \(message)"))
  }

  /// UI entry point. Failures stay visible in the generation queue rather than
  /// escaping an AppKit target/action callback.
  func startGenerationFromUI(prompt: String) {
    do {
      var settings = editorModel.inpaintingTool
      if settings.randomizeSeed {
        settings.seed = UInt64.random(in: UInt64.min...UInt64.max)
        editorModel.setInpaintingTool(settings)
      }
      _ = try startComfyUIGeneration(
        prompt: prompt,
        parameters: editorModel.comfyUIParameterValues,
        settings: settings,
        maskSourceChoice: editorModel.generationMaskSource,
        target: editorModel.comfyUIExecutionTarget,
        offerResourceDownload: true,
        expectedRevision: contentRevision)
    } catch {
      recordComfyUIDebug(
        stage: "Rejected",
        message: "Workflow did not pass local validation:\n\(error.userFacingMessage)")
      recordRejectedGeneration(prompt: prompt, message: error.userFacingMessage)
    }
  }

  /// The historical automation method name remains stable while ComfyUI owns
  /// the active generation path.
  @discardableResult
  func startInpainting(
    prompt: String,
    negativePrompt: String,
    settings: InpaintingToolState,
    maskSource: AutomationInpaintingMaskSource? = nil,
    expectedRevision: UInt64
  ) throws -> UUID {
    var parameters: [ComfyUIParameterAddress: ComfyUIParameterValue] = [:]
    let templateID = ComfyUIWorkflowCatalog.defaultInpaintingTemplateID
    func set(_ role: ComfyUIWorkflowRole, _ value: ComfyUIParameterValue) {
      if let address = ComfyUIWorkflowCatalog.address(for: role, templateID: templateID) {
        parameters[address] = value
      }
    }
    var settings = settings.clamped
    settings.negativePrompt = negativePrompt
    set(.negativePrompt, .string(negativePrompt))
    set(.seed, .unsignedInteger(settings.seed))
    set(.steps, .signedInteger(Int64(settings.steps)))
    set(.guidance, .decimal(settings.guidance))
    set(.strength, .decimal(settings.strength))
    let maskSourceChoice = try generationMaskSourceChoice(from: maskSource)
    return try startComfyUIGeneration(
      prompt: prompt,
      parameters: parameters,
      settings: settings,
      templateID: templateID,
      maskSourceChoice: maskSourceChoice,
      expectedRevision: expectedRevision)
  }

  private func startComfyUIGeneration(
    prompt: String,
    parameters: [ComfyUIParameterAddress: ComfyUIParameterValue],
    settings: InpaintingToolState,
    templateID explicitTemplateID: String? = nil,
    maskSourceChoice: GenerationMaskSourceChoice? = nil,
    target: ComfyUIExecutionTarget = .local,
    offerResourceDownload: Bool = false,
    expectedRevision: UInt64
  ) throws -> UUID {
    let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let templateID = explicitTemplateID ?? editorModel.selectedComfyUIWorkflowID
    let workflowDefinition = try ComfyUIWorkflowCatalog.resolve(templateID: templateID)
    let templateMode = workflowDefinition.template.mode
    recordComfyUIDebug(
      stage: "Preflight",
      message: "Server: \(serverAddress(for: target))\nDocument: \(projectID.uuidString)\nExpected content revision: \(expectedRevision)\nPrompt: \(cleanPrompt)")
    guard !cleanPrompt.isEmpty || templateMode == .inpainting else {
      throw PixeltjeMacError("Prompt required", "Enter a generation prompt first.")
    }
    guard expectedRevision == contentRevision else {
      throw AutomationServiceError(
        .staleRevision,
        "The document changed after the generation request was prepared.",
        details: [
          "expectedRevision": String(expectedRevision),
          "currentRevision": String(contentRevision),
        ])
    }
    guard generationTask == nil,
      !editorModel.generationJobs.contains(where: { $0.state.isActive })
    else {
      throw AutomationServiceError(
        .documentBusy, "This document already has an active generation job.")
    }
    guard pendingComfyUISelection == nil else {
      throw PixeltjeMacError(
        "Selection preview pending",
        "Apply or discard the selection preview before executing another workflow.")
    }
    guard !isShowingTransientHumanEdit else {
      throw AutomationServiceError(
        .documentBusy, "Finish the current canvas gesture before starting generation.")
    }
    guard let renderEngine else {
      throw PixeltjeMacError(
        "Rendering unavailable", "The generated image cannot be imported into the document.")
    }
    let backend = try makeComfyUIBackend(for: target)

    let capturedSettings = settings.clamped
    var frozenParameters = parameters
    func bind(_ role: ComfyUIWorkflowRole, _ value: ComfyUIParameterValue) {
      if let address = workflowDefinition.roles[role],
        frozenParameters[address] == nil
      {
        frozenParameters[address] = value
      }
    }
    bind(.negativePrompt, .string(capturedSettings.negativePrompt))
    bind(.seed, .unsignedInteger(capturedSettings.seed))
    bind(.steps, .signedInteger(Int64(capturedSettings.steps)))
    bind(.guidance, .decimal(capturedSettings.guidance))
    bind(.width, .signedInteger(Int64(capturedSettings.outputSize.width)))
    bind(.height, .signedInteger(Int64(capturedSettings.outputSize.height)))
    bind(.strength, .decimal(capturedSettings.strength))
    let workflowStrength = workflowDefinition.roles[.strength] == nil
      ? 1 : capturedSettings.strength
    let generationCanvas = editorModel.recipe.layerStack.canvas
    let inpaintingImageAlignment = workflowDefinition.imageAlignment
    let imageConditioningSourceRegion: CGRect?
    if templateMode == .imageToImage || templateMode == .selection,
      let selection = editorModel.recipe.selection {
      guard !selection.selectsNothing, let selectedBounds = selectionBounds() else {
        throw PixeltjeMacError(
          "Image editing needs a selection",
          "The active selection does not contain any pixels.")
      }
      imageConditioningSourceRegion = selectedBounds
    } else {
      imageConditioningSourceRegion = nil
    }
    let imageConditioningSourceSize = imageConditioningSourceRegion.map {
      CanvasRecipe(width: Int($0.width), height: Int($0.height))
    } ?? generationCanvas
    let workflowOutputSize = templateMode == .imageToImage || templateMode == .selection
      ? RenderEngine.imageConditioningOutputSize(
        source: imageConditioningSourceSize,
        maximum: capturedSettings.outputSize)
      : capturedSettings.outputSize
    let preflightWorkflow = try ComfyUIWorkflowCatalog.request(
      resolved: workflowDefinition,
      parameters: frozenParameters,
      prompt: cleanPrompt,
      outputSize: workflowOutputSize)
    var conditioning: ComfyUIInpaintingConditioningRecipe?
    var imageConditioning: ComfyUIImageConditioningRecipe?
    var displayedSource: RenderedFrame?
    var sourceRenderRequest: RenderRequest?
    var inpaintingMaskRenderRequest: InpaintingMaskRenderRequest?
    if preflightWorkflow.mode != .textToImage {
      guard editorModel.generationMode == .inpainting else {
        throw PixeltjeMacError(
          "Image generation needs source pixels",
          "Add or open an image before running this source-conditioned workflow.")
      }
      guard !editorModel.isShowingBefore else {
        throw PixeltjeMacError(
          "Image is not ready",
          "Wait for the current full-quality canvas render before starting generation.")
      }
      guard capturedSettings.outputSize.width.isMultiple(of: inpaintingImageAlignment),
        capturedSettings.outputSize.height.isMultiple(of: inpaintingImageAlignment)
      else {
        throw PixeltjeMacError(
          "Generation size unavailable",
          "This ComfyUI workflow requires width and height to be multiples of \(inpaintingImageAlignment) pixels.")
      }
      displayedSource = editorModel.renderedFrame.flatMap { frame in
        generationSourceFrame(from: frame, contentRevision: contentRevision)
      }
      sourceRenderRequest = try displayedSource == nil ? makeRenderRequest(quality: .full) : nil
      let source = GenerationSourceIdentity(
        documentID: projectID.uuidString,
        contentRevision: contentRevision,
        capture: .composite,
        activeLayerID: editorModel.recipe.layerStack.activeLayerID)
      if preflightWorkflow.mode == .inpainting {
        let resolvedMask = try resolvedGenerationMask(
          requested: maskSourceChoice ?? .automatic,
          in: editorModel.recipe)
        conditioning = ComfyUIInpaintingConditioningRecipe(
          source: source,
          mask: resolvedMask.mask,
          strength: workflowStrength,
          maskFeatherPixels: capturedSettings.maskBlur,
          transparentPixelBackground: capturedSettings.transparentPixelBackground,
          expandMaskForComfyUI: capturedSettings.expandMaskForComfyUI,
          usesFullOutputMask: resolvedMask.usesFullOutputMask,
          requestedMaskSource: resolvedMask.requested,
          resolvedMaskSource: resolvedMask.resolved)
        if let renderSource = resolvedMask.renderSource {
          let request = try sourceRenderRequest ?? makeRenderRequest(quality: .full)
          inpaintingMaskRenderRequest = InpaintingMaskRenderRequest(
            renderRequest: request,
            source: renderSource)
        }
      } else {
        imageConditioning = ComfyUIImageConditioningRecipe(
          source: source,
          sourceRegion: imageConditioningSourceRegion.map {
            LayerFrame(
              x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
          },
          transparentPixelBackground: capturedSettings.transparentPixelBackground)
      }
    }
    let id = UUID()
    let queuedAt = Date()
    recordComfyUIDebug(
      stage: "Job",
      message: "Local job: \(id.uuidString)\nWorkflow: \(templateID)\nMode: \(preflightWorkflow.mode.rawValue)\nPrompt: \(preflightWorkflow.prompt)\nOutput: \(preflightWorkflow.width) × \(preflightWorkflow.height)\nSeed: \(preflightWorkflow.seed)\nSteps: \(preflightWorkflow.steps)\nGuidance: \(preflightWorkflow.guidance)\nStrength: \(workflowStrength)\nNegative prompt: \(capturedSettings.negativePrompt)\nResolved scalar parameters: \(preflightWorkflow.parameters.count)\nRequested mask source: \(conditioning?.requestedMaskSource.kind.rawValue ?? "none")\nResolved mask source: \(conditioning?.resolvedMaskSource.kind.rawValue ?? "none")\nUses Entire Output: \(conditioning?.usesFullOutputMask == true)")
    var historySettings = capturedSettings
    historySettings.randomizeSeed = false
    historySettings.negativePrompt = preflightWorkflow.negativePrompt
    historySettings.seed = preflightWorkflow.seed
    historySettings.steps = preflightWorkflow.steps
    historySettings.guidance = preflightWorkflow.guidance
    let defaultParameters =
      (try? ComfyUIWorkflowCatalog.defaultParameterValues(in: workflowDefinition)) ?? [:]
    let promptAddress = workflowDefinition.roles[.prompt]
    let modifiedParameters = preflightWorkflow.parameters.filter { record in
      record.address != promptAddress && defaultParameters[record.address] != record.value
    }
    comfyUIHistoryStore.record(
      ComfyUIHistoryEntry(
        id: id,
        queuedAt: queuedAt,
        finishedAt: nil,
        status: .queued,
        statusDetail: nil,
        backendID: nil,
        executionTarget: target,
        templateID: templateID,
        templateRevision: preflightWorkflow.templateRevision,
        mode: preflightWorkflow.mode,
        prompt: preflightWorkflow.prompt,
        generationSettings: historySettings,
        modifiedParameters: modifiedParameters))

    var jobs = editorModel.generationJobs
    jobs.append(
      GenerationJob(
        id: id,
        prompt: preflightWorkflow.prompt,
        queuedAt: queuedAt,
        sourceContentRevision: contentRevision,
        state: .queued,
        executionTarget: target,
        templateID: templateID))
    editorModel.setGenerationJobs(jobs)
    activeGenerationBackend = backend
    generationLogger.info(
      "Queued ComfyUI job \(id.uuidString, privacy: .public) template=\(templateID, privacy: .public) mode=\(preflightWorkflow.mode.rawValue, privacy: .public) revision=\(self.contentRevision, privacy: .public) output=\(preflightWorkflow.width, privacy: .public)x\(preflightWorkflow.height, privacy: .public) seed=\(preflightWorkflow.seed, privacy: .public) steps=\(preflightWorkflow.steps, privacy: .public) guidance=\(preflightWorkflow.guidance, privacy: .public)"
    )

    generationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.activeGenerationBackend = nil
        self.generationTask = nil
      }
      let debugSink = self.comfyUIDebugSink
      do {
        self.editorModel.setComfyUIConnection(.checking)
        var workflow = preflightWorkflow
        let missingModels = try await backend.missingModels(
          in: workflow, onDebug: debugSink)
        try Task.checkCancellation()
        self.editorModel.setComfyUIConnection(.connected)
        if !missingModels.isEmpty {
          let names = missingModels.map(\.filename).joined(separator: ", ")
          let message = "\(target == .cloud ? "Comfy Cloud" : "ComfyUI") is missing \(names)."
          self.recordComfyUIDebug(
            stage: "Missing models",
            message: "The connected server does not list: \(missingModels.map(\.relativePath).joined(separator: ", ")).")
          self.updateGeneration(
            id: id, state: .failed(message), progress: 0,
            canApplyAnyway: false)
          if target == .local, offerResourceDownload,
            let required = try? ComfyUIResourceCatalog.requiredModels(in: workflow.workflow),
            let resources = try? ComfyUIResourceCatalog.downloadableResources(
              templateID: templateID),
            Set(resources.keys) == Set(required.map(\.relativePath)),
            let host = ComfyUIClient.configuredBaseURL.host?.lowercased(),
            ["127.0.0.1", "localhost", "::1"].contains(host)
          {
            let missingResources = missingModels.compactMap { resources[$0.relativePath] }
            if missingResources.count == missingModels.count {
              await self.offerComfyUIResourceDownload(
                missingResources, templateID: templateID)
            }
          }
          return
        }
        var inpaintingPreparation: ComfyUIInpaintingPreparation?
        var imageConditioningPreparation: ComfyUIImageConditioningPreparation?
        if conditioning != nil || imageConditioning != nil {
          self.updateGeneration(id: id, state: .preparing, progress: 0.01)
          let sourceFrame: RenderedFrame
          if let displayedSource {
            sourceFrame = displayedSource
            self.recordComfyUIDebug(
              stage: "Source capture",
              message: "Reused displayed composite.\nSize: \(sourceFrame.width) × \(sourceFrame.height)\nRender revision: \(sourceFrame.revision)\nContent revision: \(sourceFrame.contentRevision)")
            self.generationLogger.debug(
              "ComfyUI job \(id.uuidString, privacy: .public) reused raster revision \(sourceFrame.revision, privacy: .public)"
            )
          } else if let sourceRenderRequest {
            sourceFrame = try await renderEngine.render(sourceRenderRequest)
            self.recordComfyUIDebug(
              stage: "Source capture",
              message: "Rendered a fresh full-quality composite.\nSize: \(sourceFrame.width) × \(sourceFrame.height)\nRender revision: \(sourceFrame.revision)\nContent revision: \(sourceFrame.contentRevision)\nRender time: \(sourceFrame.elapsedSeconds.formatted(.number.precision(.fractionLength(3)))) seconds")
            try Task.checkCancellation()
            guard self.contentRevision == expectedRevision,
              self.revision == sourceRenderRequest.revision
            else {
              throw AutomationServiceError(
                .staleRevision,
                "The document changed while the generation source was being prepared.")
            }
            self.editorModel.merge(sourceFrame.rawInspections)
            self.editorModel.present(sourceFrame)
            self.scheduleAnalysis(of: sourceFrame, using: renderEngine)
          } else {
            throw PixeltjeMacError(
              "Image is not ready", "The canvas could not provide source pixels for generation.")
          }
          var renderedMask: InpaintingMaskRenderResult?
          if let inpaintingMaskRenderRequest {
            let capturedMask = try await renderEngine.captureInpaintingMask(
              inpaintingMaskRenderRequest,
              documentSourceFrame: sourceFrame)
            try Task.checkCancellation()
            guard self.contentRevision == expectedRevision,
              self.revision == inpaintingMaskRenderRequest.renderRequest.revision
            else {
              throw AutomationServiceError(
                .staleRevision,
                "The document changed while the inpainting mask was being prepared.")
            }
            renderedMask = capturedMask
            self.recordComfyUIDebug(
              stage: "Mask capture",
              message: "Rendered the resolved mask through its document/layer stage.\nCanvas: \(capturedMask.width) × \(capturedMask.height)\nNonzero bounds: x \(capturedMask.nonzeroBounds.x.formatted(.number.precision(.fractionLength(2)))), y \(capturedMask.nonzeroBounds.y.formatted(.number.precision(.fractionLength(2)))), width \(capturedMask.nonzeroBounds.width.formatted(.number.precision(.fractionLength(2)))), height \(capturedMask.nonzeroBounds.height.formatted(.number.precision(.fractionLength(2))))")
          }
          if let conditioning {
            let preparation = try await renderEngine.prepareComfyUIInpainting(
              sourceFrame: sourceFrame,
              conditioning: conditioning,
              outputWidth: workflow.width,
              outputHeight: workflow.height,
              imageAlignment: inpaintingImageAlignment,
              renderedMask: renderedMask)
            self.recordComfyUIDebug(
              stage: "Conditioning",
              message: Self.comfyUIConditioningDebugDescription(preparation))
            self.recordComfyUIDebugImage(
              ComfyUIDebugImage(
                label: "Sent to ComfyUI — source",
                imageData: preparation.sourcePNG))
            self.recordComfyUIDebugImage(
              ComfyUIDebugImage(
                label: "Sent to ComfyUI — mask (transparent = edit)",
                imageData: preparation.maskPNG))
            try Task.checkCancellation()
            guard self.contentRevision == expectedRevision else {
              throw AutomationServiceError(
                .staleRevision,
                "The document changed while the inpainting inputs were being prepared.")
            }

            self.updateGeneration(id: id, state: .uploading, progress: 0.02)
            let uploadFolder = "pixeltje/\(id.uuidString.lowercased())"
            async let sourceUpload = backend.uploadPNG(
              preparation.sourcePNG,
              filename: "source.png",
              subfolder: uploadFolder,
              onDebug: debugSink)
            async let maskUpload = backend.uploadPNG(
              preparation.maskPNG,
              filename: "mask.png",
              subfolder: uploadFolder,
              onDebug: debugSink)
            let (uploadedSource, uploadedMask) = try await (sourceUpload, maskUpload)
            try Task.checkCancellation()
            guard self.contentRevision == expectedRevision else {
              throw AutomationServiceError(
                .staleRevision,
                "The document changed while the inpainting inputs were being uploaded.")
            }
            workflow = try ComfyUIWorkflowCatalog.request(
              resolved: workflowDefinition,
              parameters: frozenParameters,
              prompt: cleanPrompt,
              outputSize: CanvasRecipe(
                width: preparation.width,
                height: preparation.height),
              runtimeValues: [
                .sourceImage: uploadedSource.runtimeValue,
                .maskImage: uploadedMask.runtimeValue,
              ])
            self.recordComfyUIDebug(
              stage: "Workflow binding",
              message: "Source input: \(uploadedSource.runtimeValue.debugDescription)\nMask input: \(uploadedMask.runtimeValue.debugDescription)\nFrozen workflow bytes: \(workflow.workflow.count)\nTemplate revision: \(workflow.templateRevision)")
            inpaintingPreparation = preparation
          } else if let imageConditioning {
            let preparation = try await renderEngine.prepareComfyUIImageConditioning(
              sourceFrame: sourceFrame,
              conditioning: imageConditioning,
              outputWidth: workflow.width,
              outputHeight: workflow.height)
            self.recordComfyUIDebug(
              stage: "Conditioning",
              message: "Image-editing source: \(preparation.width) × \(preparation.height)\nSource PNG: \(preparation.sourcePNG.count) bytes\nSource identity: \(imageConditioning.source.documentID) @ content revision \(imageConditioning.source.contentRevision)")
            self.recordComfyUIDebugImage(
              ComfyUIDebugImage(
                label: "Sent to ComfyUI — source",
                imageData: preparation.sourcePNG))
            try Task.checkCancellation()
            guard self.contentRevision == expectedRevision else {
              throw AutomationServiceError(
                .staleRevision,
                "The document changed while the image-editing input was being prepared.")
            }

            self.updateGeneration(id: id, state: .uploading, progress: 0.02)
            let uploadedSource = try await backend.uploadPNG(
              preparation.sourcePNG,
              filename: "source.png",
              subfolder: "pixeltje/\(id.uuidString.lowercased())",
              onDebug: debugSink)
            try Task.checkCancellation()
            guard self.contentRevision == expectedRevision else {
              throw AutomationServiceError(
                .staleRevision,
                "The document changed while the image-editing input was being uploaded.")
            }
            workflow = try ComfyUIWorkflowCatalog.request(
              resolved: workflowDefinition,
              parameters: frozenParameters,
              prompt: cleanPrompt,
              outputSize: workflowOutputSize,
              runtimeValues: [.sourceImage: uploadedSource.runtimeValue])
            self.recordComfyUIDebug(
              stage: "Workflow binding",
              message: "Source input: \(uploadedSource.runtimeValue.debugDescription)\nFrozen workflow bytes: \(workflow.workflow.count)\nTemplate revision: \(workflow.templateRevision)")
            imageConditioningPreparation = preparation
          }
        }
        let result = try await backend.run(
          workflow,
          onAccepted: { [weak self] promptID in
            await MainActor.run {
              guard let self else { return }
              self.setGenerationBackendID(id: id, backendID: promptID)
              self.editorModel.setComfyUIConnection(.connected)
            }
          },
          onState: { [weak self] state, progress in
            await MainActor.run {
              guard let self else { return }
              self.editorModel.setComfyUIConnection(.connected)
              self.updateGeneration(id: id, state: state, progress: progress)
            }
          },
          onDebug: debugSink)
        self.recordComfyUIDebugImage(
          ComfyUIDebugImage(
            label: "Returned by ComfyUI — raw output",
            imageData: result.imageData))
        try Task.checkCancellation()
        if self.contentRevision != expectedRevision {
          self.recordComfyUIDebug(
            stage: "Revision conflict",
            message: "ComfyUI completed from content revision \(expectedRevision), while the document is now at revision \(self.contentRevision). Finishing the frozen result so it can be applied explicitly.")
        }
        self.updateGeneration(id: id, state: .finalizing, progress: 0.97)
        if workflow.mode == .selection {
          guard let imageConditioningPreparation else {
            throw PixeltjeMacError(
              "Selection source unavailable", "The workflow has no captured source image.")
          }
          let selection = try await renderEngine.finishComfyUISelection(
            imageData: result.imageData,
            preparation: imageConditioningPreparation,
            canvas: generationCanvas,
            prompt: cleanPrompt)
          try Task.checkCancellation()
          guard self.contentRevision == expectedRevision else {
            throw AutomationServiceError(
              .staleRevision,
              "The document changed before the selection preview was ready.")
          }
          self.pendingComfyUISelection = (selection, expectedRevision)
          self.editorModel.setComfyUISelectionPreview(selection)
          self.recordComfyUIDebug(
            stage: "Selection preview",
            message: "Prepared \(selection.name) with \(selection.components.count) mask component. Apply it to commit one undoable selection step.")
          self.updateGeneration(id: id, state: .succeeded, progress: 1)
          self.generationTask = nil
          return
        }
        let raster: RasterBakeResult
        let placementFrame: LayerFrame
        var outsideMaskPixelCount = 0
        var preservedOutsideMaskPixelCount = 0
        var inpaintingAssets: ComfyUIInpaintingLayerAssets?
        if let inpaintingPreparation {
          let output = try await renderEngine.prepareComfyUIInpaintingOutput(
            imageData: result.imageData, preparation: inpaintingPreparation)
          let generated = try await renderEngine.finishComfyUIInpainting(
            output, changeThreshold: 0)
          guard generated.outsideMaskPixelCount == generated.preservedOutsideMaskPixelCount else {
            throw PixeltjeMacError(
              "Inpainting invariant failed",
              "Pixels outside the feathered mask were not cleared from the generated layer.")
          }
          raster = generated.raster
          placementFrame = generated.placementFrame
          outsideMaskPixelCount = generated.outsideMaskPixelCount
          preservedOutsideMaskPixelCount = generated.preservedOutsideMaskPixelCount
          inpaintingAssets = try await renderEngine.makeComfyUIInpaintingLayerAssets(output)
          self.recordComfyUIDebug(
            stage: "Composite",
            message: "Decoded and masked server output: \(generated.raster.reference.width) × \(generated.raster.reference.height)\nPlacement: x=\(generated.placementFrame.x), y=\(generated.placementFrame.y), width=\(generated.placementFrame.width), height=\(generated.placementFrame.height)\nTransparent outside-mask pixels: \(generated.preservedOutsideMaskPixelCount) of \(generated.outsideMaskPixelCount)")
        } else if let imageConditioningPreparation {
          let generated = try await renderEngine.finishComfyUIImageConditioning(
            imageData: result.imageData,
            preparation: imageConditioningPreparation)
          raster = generated.raster
          placementFrame = generated.placementFrame
          self.recordComfyUIDebug(
            stage: "Image editing",
            message: "Decoded server output: \(generated.raster.reference.width) × \(generated.raster.reference.height)\nPlacement: x=\(generated.placementFrame.x), y=\(generated.placementFrame.y), width=\(generated.placementFrame.width), height=\(generated.placementFrame.height)")
        } else {
          guard let image = CIImage(
            data: result.imageData,
            options: [.applyOrientationProperty: true])
          else {
            throw PixeltjeMacError(
              "ComfyUI output unreadable", "The server output is not a supported image.")
          }
          raster = try await renderEngine.importRaster(image)
          placementFrame = .placing(
            naturalWidth: raster.reference.width,
            naturalHeight: raster.reference.height,
            in: generationCanvas)
        }
        try Task.checkCancellation()
        let inpaintingRecipe = inpaintingPreparation?.conditioning
        let generationRecipe = ComfyUIGenerationRecipe(
          templateID: workflow.templateID,
          templateRevision: workflow.templateRevision,
          promptID: result.promptID,
          executionTarget: target,
          prompt: workflow.prompt,
          negativePrompt: workflow.negativePrompt,
          seed: workflow.seed,
          steps: workflow.steps,
          guidance: workflow.guidance,
          outputWidth: raster.reference.width,
          outputHeight: raster.reference.height,
          mode: workflow.mode,
          inpainting: inpaintingRecipe,
          imageConditioning: imageConditioningPreparation?.conditioning,
          parameters: workflow.parameters)
        let layerContent: ProjectLayerContent
        if let inpaintingAssets {
          layerContent = .generatedInpaint(GeneratedInpaintLayerRecipe(
            source: inpaintingAssets.source.reference,
            generated: inpaintingAssets.generated.reference,
            analysis: inpaintingAssets.analysis.reference,
            frame: placementFrame,
            generation: generationRecipe))
        } else {
          layerContent = .raster(RasterLayerRecipe(
            asset: raster.reference,
            frame: placementFrame,
            comfyUIGeneration: generationRecipe,
            differenceSource: imageConditioningPreparation?.sourceRaster.reference))
        }
        let layerName = cleanPrompt.isEmpty
          ? "Generated Inpaint"
          : "Generated — \(String(cleanPrompt.prefix(36)))"
        let layer = ProjectLayer(name: layerName, content: layerContent)
        if self.contentRevision != expectedRevision {
          self.retainComfyUIResultForManualApplication(
            jobID: id, layer: layer,
            assets: inpaintingAssets?.all ??
              ([raster] + (imageConditioningPreparation.map { [$0.sourceRaster] } ?? [])))
          self.generationLogger.notice(
            "Retained stale ComfyUI job \(result.promptID, privacy: .public) for explicit application; expected revision=\(expectedRevision, privacy: .public) current=\(self.contentRevision, privacy: .public)"
          )
        } else {
          for asset in inpaintingAssets?.all ??
            ([raster] + (imageConditioningPreparation.map { [$0.sourceRaster] } ?? [])) {
            self.rasterAssets[asset.reference.id] = asset.compressedPixels
          }
          self.perform(.addGeneratedLayer(layer), interactive: false)
          self.recordComfyUIDebug(
            stage: "Commit",
            message: "Added generated layer \(layer.id.rawValue).\nProject assets: \(layer.rasterAssetReferences.count)\nRemote job: \(result.promptID)")
          self.updateGeneration(
            id: id, state: .succeeded, progress: 1, canApplyAnyway: false)
          self.generationLogger.info(
            "Completed ComfyUI job \(result.promptID, privacy: .public) output=\(raster.reference.width, privacy: .public)x\(raster.reference.height, privacy: .public) transparentOutsideMask=\(preservedOutsideMaskPixelCount, privacy: .public)/\(outsideMaskPixelCount, privacy: .public)"
          )
        }
      } catch is CancellationError {
        self.recordComfyUIDebug(
          stage: "Cancelled", message: "Local job \(id.uuidString) was cancelled.")
        self.updateGeneration(id: id, state: .cancelled, progress: 0)
        self.generationLogger.info("Cancelled ComfyUI job \(id.uuidString, privacy: .public)")
      } catch {
        self.recordComfyUIDebug(
          stage: "Failure",
          message: "Local job \(id.uuidString) failed:\n\(error.userFacingMessage)\n\nRaw error:\n\(error)")
        self.editorModel.setComfyUIConnection(.disconnected(error.userFacingMessage))
        self.updateGeneration(
          id: id, state: .failed(error.userFacingMessage), progress: 0,
          canApplyAnyway: false)
        self.generationLogger.error(
          "Failed ComfyUI job \(id.uuidString, privacy: .public): \(error.userFacingMessage, privacy: .public)"
        )
      }
      self.generationTask = nil
    }
    return id
  }

  private func offerComfyUIResourceDownload(
    _ resources: [ComfyUIDownloadResource],
    templateID: String
  ) async {
    guard let window = windowControllers.compactMap(\.window).first else { return }
    let scriptName = "\(templateID).command"
    let bundledScript = Bundle.main.resourceURL?
      .appendingPathComponent("ComfyUISetup")
      .appendingPathComponent(scriptName)
    let developmentScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Scripts/ComfyUI")
      .appendingPathComponent(scriptName)
    let scriptURL = [bundledScript, developmentScript].compactMap { $0 }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    guard let scriptURL else {
      recordComfyUIDebug(
        stage: "Download unavailable",
        message: "The \(scriptName) helper could not be found in this app installation.")
      return
    }

    let alert = NSAlert()
    alert.alertStyle = .informational
    if resources.count == 1, let resource = resources.first {
      alert.messageText = "Download \(URL(fileURLWithPath: resource.relativePath).lastPathComponent) (\(resource.sizeLabel))?"
    } else {
      let name = ComfyUIWorkflowCatalog.templates.first { $0.id == templateID }?.name
        ?? templateID
      alert.messageText = "Download missing models for \(name)?"
    }
    let list = resources.map { resource in
      "• \(URL(fileURLWithPath: resource.relativePath).lastPathComponent) — \(resource.sizeLabel)"
    }.joined(separator: "\n")
    alert.informativeText = """
      ComfyUI cannot run this workflow until these files are available:

      \(list)

      The Terminal script will propose ~/ComfyUI-Shared/models, let you choose another folder, check its files, and confirm before downloading. If that folder differs from the server's other model paths, the script may offer additional files. Rescan or restart ComfyUI afterward, then retry the workflow.
      """
    alert.addButton(withTitle: "Open Download Script")
    alert.addButton(withTitle: "Cancel")
    let response = await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
    guard response == .alertFirstButtonReturn else { return }
    if !NSWorkspace.shared.open(scriptURL) {
      let errorAlert = NSAlert()
      errorAlert.alertStyle = .warning
      errorAlert.messageText = "Couldn’t open the download script"
      errorAlert.informativeText = "Open \(scriptName) from the app’s ComfyUISetup resources folder in Terminal."
      errorAlert.beginSheetModal(for: window) { _ in }
    }
  }

  private static func comfyUIConditioningDebugDescription(
    _ preparation: ComfyUIInpaintingPreparation
  ) -> String {
    var coveredPixelCount = 0
    var fullyCoveredPixelCount = 0
    var partialPixelCount = 0
    var coverageSum = 0.0
    var minimumCoverage = Float.greatestFiniteMagnitude
    var maximumCoverage: Float = 0
    let retainedWidth = preparation.compositeWidth
    let retainedHeight = preparation.compositeHeight
    var minimumX = retainedWidth
    var minimumY = retainedHeight
    var maximumX = -1
    var maximumY = -1
    for (index, coverage) in preparation.maskCoverage.enumerated() {
      minimumCoverage = min(minimumCoverage, coverage)
      maximumCoverage = max(maximumCoverage, coverage)
      coverageSum += Double(coverage)
      guard coverage > 0 else { continue }
      coveredPixelCount += 1
      if coverage >= 1 {
        fullyCoveredPixelCount += 1
      } else {
        partialPixelCount += 1
      }
      let x = index % retainedWidth
      let y = index / retainedWidth
      minimumX = min(minimumX, x)
      minimumY = min(minimumY, y)
      maximumX = max(maximumX, x)
      maximumY = max(maximumY, y)
    }
    if preparation.maskCoverage.isEmpty { minimumCoverage = 0 }
    let totalPixelCount = preparation.maskCoverage.count
    let averageCoverage = totalPixelCount > 0
      ? coverageSum / Double(totalPixelCount)
      : 0
    let coveredBounds = coveredPixelCount > 0
      ? "x=\(minimumX)...\(maximumX), y=\(minimumY)...\(maximumY)"
      : "empty"
    return """
      ComfyUI upload size: \(preparation.width) × \(preparation.height)
      Retained composition size: \(retainedWidth) × \(retainedHeight)
      Placement: x=\(preparation.placementFrame.x), y=\(preparation.placementFrame.y), width=\(preparation.placementFrame.width), height=\(preparation.placementFrame.height)
      Source PNG: \(preparation.sourcePNG.count) bytes
      Mask PNG: \(preparation.maskPNG.count) bytes
      Mask transport convention: ComfyUI LoadImage uses 1 − PNG alpha; transparent pixels are selected for editing
      Retained RGBA16F source: \(preparation.originalPixels.count) bytes
      Mask samples: \(totalPixelCount)
      Nonzero mask pixels: \(coveredPixelCount)
      Fully covered pixels: \(fullyCoveredPixelCount)
      Feathered edge pixels: \(partialPixelCount)
      Coverage min/max/average: \(minimumCoverage) / \(maximumCoverage) / \(String(format: "%.6f", averageCoverage))
      Nonzero mask bounds: \(coveredBounds)
      Additional feather: \(preparation.conditioning.maskFeatherPixels) px
      Expanded ComfyUI mask: \(preparation.conditioning.expandMaskForComfyUI)
      ComfyUI mask expansion: \(preparation.conditioning.expandMaskForComfyUI ? "\(Int(RenderEngine.comfyUITransportMaskExpansionPixels)) upload px" : "disabled")
      Full output mask: \(preparation.conditioning.usesFullOutputMask)
      Requested mask source: \(preparation.conditioning.requestedMaskSource.kind.rawValue)
      Resolved mask source: \(preparation.conditioning.resolvedMaskSource.kind.rawValue)
      Resolved mask layer ID: \(preparation.conditioning.resolvedMaskSource.layerID?.rawValue ?? "none")
      Resolved mask ID: \(preparation.conditioning.resolvedMaskSource.maskID?.rawValue ?? "none")
      Source identity: \(preparation.conditioning.source.documentID) @ content revision \(preparation.conditioning.source.contentRevision)
      """
  }

  // MARK: - Parked Core AI generation

  /// Retained while the in-process PixAIModel work is parked. No active UI or
  /// automation path calls this implementation.
  @discardableResult
  private func startCoreAIInpainting(
    prompt: String,
    negativePrompt: String,
    settings: InpaintingToolState,
    expectedRevision: UInt64
  ) throws -> UUID {
    let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPrompt.isEmpty else {
      throw PixeltjeMacError("Prompt required", "Enter a generation prompt first.")
    }
    guard expectedRevision == contentRevision else {
      throw AutomationServiceError(
        .staleRevision,
        "The document changed after the generation request was prepared.",
        details: [
          "expectedRevision": String(expectedRevision),
          "currentRevision": String(contentRevision),
        ])
    }
    guard generationTask == nil,
      !editorModel.generationJobs.contains(where: { $0.state.isActive })
    else {
      throw AutomationServiceError(
        .documentBusy, "This document already has an active generation job.")
    }
    guard !isShowingTransientHumanEdit else {
      throw AutomationServiceError(
        .documentBusy,
        "Finish the current canvas gesture before starting generation.")
    }
    let generationMode = editorModel.generationMode
    let usesFullCanvasMask = editorModel.recipe.selection == nil
    let mask = generationMode == .textToImage ? MaskRecipe.selectingAll : effectiveGenerationMask
    if generationMode == .inpainting, !mask.isEvaluable || mask.selectsNothing {
      throw PixeltjeMacError(
        "Inpainting needs a selection",
        "The active selection is empty. Deselect it to generate across the full canvas.")
    }
    guard !editorModel.isShowingBefore else {
      throw PixeltjeMacError(
        "Image is not ready",
        "Wait for the current full-quality canvas render before starting generation.")
    }
    guard let renderEngine else {
      throw PixeltjeMacError(
        "Core AI unavailable",
        "Metal rendering is unavailable, so Z-Image cannot start.")
    }

    // A selection changes document intent but not the composited pixels. Reuse
    // a full frame from the current raster revision and retag that immutable
    // pixel snapshot with the revision whose selection the job captures.
    let displayedSource = generationMode == .inpainting
      ? editorModel.renderedFrame.flatMap { frame in
        generationSourceFrame(from: frame, contentRevision: contentRevision)
      }
      : nil
    let sourceRenderRequest = try generationMode == .inpainting && displayedSource == nil
      ? makeRenderRequest(quality: .full)
      : nil

    let capturedSettings = settings.clamped
    guard let modelResolution = ZImageCoreAIPipeline.modelResolution(
      outputWidth: capturedSettings.outputSize.width,
      outputHeight: capturedSettings.outputSize.height)
    else {
      throw PixeltjeMacError(
        "Generation size unavailable",
        "Z-Image requires width and height from 512 through 2048 pixels in multiples of 16.")
    }
    let modelURL = Self.zImageModelURL
    let modelIdentity = ZImageCoreAIPipeline.modelIdentity(
      for: generationMode,
      resolution: modelResolution)
    let requiredComponentNames = modelIdentity.functions.compactMap { function in
      ["vaeEncoder", "vaeDecoder"].contains(function.role) ? function.packageName : nil
    }
    if let missingComponentName = requiredComponentNames.first(where: { name in
      !FileManager.default.fileExists(
        atPath: modelURL.appendingPathComponent("Resources/\(name)").path)
    }) {
      throw PixeltjeMacError(
        "Core AI component missing",
        "The linked Z-Image package has no \(missingComponentName) component.")
    }

    let generationCanvas = editorModel.recipe.layerStack.canvas
    let inpaintingRecipe = InpaintingRecipe(
      mode: generationMode,
      model: modelIdentity,
      prompt: cleanPrompt,
      negativePrompt: negativePrompt,
      source: GenerationSourceIdentity(
        documentID: projectID.uuidString,
        contentRevision: contentRevision,
        capture: .composite,
        activeLayerID: editorModel.recipe.layerStack.activeLayerID),
      mask: mask,
      seed: capturedSettings.seed,
      steps: capturedSettings.steps,
      guidance: capturedSettings.guidance,
      strength: generationMode == .textToImage ? 1 : capturedSettings.strength,
      maskFeatherPixels: generationMode == .textToImage ? 0 : capturedSettings.maskBlur,
      transparentPixelBackground: capturedSettings.transparentPixelBackground,
      modelWidth: modelResolution.width,
      modelHeight: modelResolution.height,
      outputWidth: capturedSettings.outputSize.width,
      outputHeight: capturedSettings.outputSize.height,
      usesFullOutputMask: generationMode == .textToImage || usesFullCanvasMask)
    let id = UUID()
    var jobs = editorModel.generationJobs
    jobs.append(
      GenerationJob(
        id: id,
        prompt: cleanPrompt,
        sourceContentRevision: contentRevision,
        state: .queued))
    editorModel.setGenerationJobs(jobs)
    generationLogger.info(
      "Queued job \(id.uuidString, privacy: .public) document=\(self.projectID.uuidString, privacy: .public) revision=\(self.contentRevision, privacy: .public) mode=\(generationMode.rawValue, privacy: .public) canvas=\(generationCanvas.width, privacy: .public)x\(generationCanvas.height, privacy: .public) output=\(capturedSettings.outputSize.width, privacy: .public)x\(capturedSettings.outputSize.height, privacy: .public) fullCanvas=\(usesFullCanvasMask, privacy: .public) seed=\(capturedSettings.seed, privacy: .public) randomSeed=\(capturedSettings.randomizeSeed, privacy: .public) steps=\(capturedSettings.steps, privacy: .public) guidance=\(capturedSettings.guidance, privacy: .public) strength=\(capturedSettings.strength, privacy: .public) base=\(capturedSettings.transparentPixelBackground.rawValue, privacy: .public) promptCharacters=\(cleanPrompt.count, privacy: .public) negativePromptCharacters=\(negativePrompt.count, privacy: .public)"
    )

    generationTask = Task { [weak self] in
      guard let self else { return }
      do {
        self.updateGeneration(id: id, state: .preparing, progress: 0.02)
        let modelLoadState: @Sendable (Bool) async -> Void = { [weak self] needsLoad in
          guard needsLoad else { return }
          await MainActor.run {
            self?.updateGeneration(id: id, state: .loadingModel, progress: 0.02)
          }
        }
        let previewHandler: @Sendable (GenerationRenderPreview) async -> Void = {
          [weak self] preview in
          guard !Task.isCancelled else { return }
          await MainActor.run {
            guard let self, self.contentRevision == expectedRevision else { return }
            self.editorModel.setGenerationPreview(preview.frame)
            self.updateGeneration(
              id: id,
              state: .denoising(step: preview.step, total: preview.totalSteps),
              progress: 0.05 + 0.88 * Double(preview.step) / Double(preview.totalSteps))
            self.generationLogger.debug(
              "Job \(id.uuidString, privacy: .public) preview step \(preview.step, privacy: .public) of \(preview.totalSteps, privacy: .public)"
            )
          }
        }

        let result: GenerationRenderResult
        switch generationMode {
        case .textToImage:
          result = try await renderEngine.generateTextToImage(
            TextToImageRenderRequest(
              documentID: self.projectID,
              revision: self.revision,
              contentRevision: expectedRevision,
              canvas: generationCanvas,
              recipe: inpaintingRecipe,
              modelPackageURL: modelURL),
            modelLoadState: modelLoadState,
            preview: previewHandler)
        case .imageToImage:
          throw PixeltjeMacError(
            "Image editing unavailable",
            "Image-to-image workflows run through the active ComfyUI connector.")
        case .selection:
          throw PixeltjeMacError(
            "Selection unavailable",
            "Text-guided selection runs through the active ComfyUI connector.")
        case .inpainting:
          let sourceFrame: RenderedFrame
          if let displayedSource {
            sourceFrame = displayedSource
            self.generationLogger.debug(
              "Job \(id.uuidString, privacy: .public) reused raster revision \(sourceFrame.revision, privacy: .public)"
            )
          } else if let sourceRenderRequest {
            self.generationLogger.info(
              "Job \(id.uuidString, privacy: .public) preparing a generation source frame"
            )
            sourceFrame = try await renderEngine.render(sourceRenderRequest)
            try Task.checkCancellation()
            guard self.contentRevision == expectedRevision,
              self.revision == sourceRenderRequest.revision
            else {
              throw AutomationServiceError(
                .staleRevision,
                "The document changed while the generation source was being prepared.")
            }
            self.editorModel.merge(sourceFrame.rawInspections)
            self.editorModel.present(sourceFrame)
            self.scheduleAnalysis(of: sourceFrame, using: renderEngine)
            self.generationLogger.info(
              "Job \(id.uuidString, privacy: .public) prepared source \(sourceFrame.width, privacy: .public)x\(sourceFrame.height, privacy: .public)"
            )
          } else {
            throw PixeltjeMacError(
              "Image is not ready",
              "The canvas could not provide pixels for inpainting.")
          }
          result = try await renderEngine.generateInpainting(
            InpaintingRenderRequest(
              sourceFrame: sourceFrame,
              recipe: inpaintingRecipe,
              modelPackageURL: modelURL),
            modelLoadState: modelLoadState,
            preview: previewHandler)
        }
        try Task.checkCancellation()
        guard self.contentRevision == expectedRevision else {
          throw AutomationServiceError(
            .staleRevision,
            "The document changed while Core AI was generating. No pixels were committed.")
        }
        guard result.outsideMaskPixelCount == result.preservedOutsideMaskPixelCount else {
          throw PixeltjeMacError(
            "Inpainting invariant failed",
            "Pixels outside the feathered mask did not match the captured source.")
        }
        self.updateGeneration(id: id, state: .finalizing, progress: 0.97)
        self.rasterAssets[result.raster.reference.id] = result.raster.compressedPixels
        let layer = ProjectLayer(
          name: "Generated — \(String(cleanPrompt.prefix(36)))",
          content: .raster(
            RasterLayerRecipe(
              asset: result.raster.reference,
              frame: result.placementFrame,
              generation: inpaintingRecipe)))
        self.editorModel.setGenerationPreview(nil)
        self.perform(.addGeneratedLayer(layer), interactive: false)
        self.updateGeneration(id: id, state: .succeeded, progress: 1)
        self.generationLogger.info(
          "Completed job \(id.uuidString, privacy: .public) output=\(result.raster.reference.width, privacy: .public)x\(result.raster.reference.height, privacy: .public) preservedOutsideMask=\(result.preservedOutsideMaskPixelCount, privacy: .public)/\(result.outsideMaskPixelCount, privacy: .public)"
        )
      } catch is CancellationError {
        self.editorModel.setGenerationPreview(nil)
        self.updateGeneration(id: id, state: .cancelled, progress: 0)
        self.generationLogger.info("Cancelled job \(id.uuidString, privacy: .public)")
      } catch {
        self.editorModel.setGenerationPreview(nil)
        self.updateGeneration(id: id, state: .failed(error.userFacingMessage), progress: 0)
        self.generationLogger.error(
          "Failed job \(id.uuidString, privacy: .public): \(error.userFacingMessage, privacy: .public)"
        )
      }
      self.generationTask = nil
    }
    return id
  }

  private func generationMaskSourceChoice(
    from source: AutomationInpaintingMaskSource?
  ) throws -> GenerationMaskSourceChoice {
    guard let source else { return .legacySelectionOrEntireOutput }

    func requiredID(_ value: String?, name: String) throws -> String {
      guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AutomationServiceError(
          .invalidArgument,
          "The inpainting mask source requires a non-empty \(name).")
      }
      return value
    }

    switch source.kind {
    case .automatic:
      return .automatic
    case .documentSelection:
      return .documentSelection
    case .activeLayerMask:
      guard let layerID = editorModel.recipe.layerStack.activeLayerID,
        let mask = editorModel.recipe.layerStack.layer(id: layerID)?.layerMask
      else {
        throw AutomationServiceError(
          .invalidArgument,
          "The active layer does not have a layer mask.")
      }
      return .layerMask(layerID, mask.id)
    case .layerMask:
      return .layerMask(
        ProjectLayerID(rawValue: try requiredID(source.layerID, name: "layerID")),
        MaskID(rawValue: try requiredID(source.maskID, name: "maskID")))
    case .localMask:
      return .localMask(
        ProjectLayerID(rawValue: try requiredID(source.layerID, name: "layerID")),
        MaskID(rawValue: try requiredID(source.maskID, name: "maskID")))
    case .transparentPixels:
      return .transparentPixels
    case .entireOutput:
      return .entireOutput
    }
  }

  /// Resolves the session-level picker value against one frozen document
  /// recipe. The result travels as a unit: authored recipe, provenance, and
  /// render-stage identity cannot disagree once asynchronous preparation
  /// begins.
  private func resolvedGenerationMask(
    requested choice: GenerationMaskSourceChoice,
    in recipe: ProjectRecipe
  ) throws -> ResolvedGenerationMask {
    func hasEnabledUnavailableComponents(_ mask: MaskRecipe) -> Bool {
      mask.components.contains { $0.isEnabled && !$0.availability.isAvailable }
    }

    let requested: GenerationMaskSource
    let concreteChoice: GenerationMaskSourceChoice
    switch choice {
    case .automatic:
      requested = GenerationMaskSource(kind: .automatic)
      if recipe.selection != nil {
        // A present but invalid selection is authoritative. Report it below
        // instead of silently widening generation to another mask source.
        concreteChoice = .documentSelection
      } else if let layerID = recipe.layerStack.activeLayerID,
        recipe.layerStack.entry(id: layerID)?.isEffectivelyEnabled == true,
        let mask = recipe.layerStack.layer(id: layerID)?.layerMask,
        mask.isEnabled,
        mask.isEvaluable,
        !hasEnabledUnavailableComponents(mask)
      {
        concreteChoice = .layerMask(layerID, mask.id)
      } else {
        concreteChoice = .transparentPixels
      }
    case .legacySelectionOrEntireOutput:
      requested = GenerationMaskSource(kind: .legacySelectionOrEntireOutput)
      concreteChoice = recipe.selection == nil ? .entireOutput : .documentSelection
    case .documentSelection:
      requested = GenerationMaskSource(kind: .documentSelection)
      concreteChoice = choice
    case .layerMask(let layerID, let maskID):
      requested = GenerationMaskSource(
        kind: .layerMask, layerID: layerID, maskID: maskID)
      concreteChoice = choice
    case .localMask(let layerID, let maskID):
      requested = GenerationMaskSource(
        kind: .localMask, layerID: layerID, maskID: maskID)
      concreteChoice = choice
    case .transparentPixels:
      requested = GenerationMaskSource(kind: .transparentPixels)
      concreteChoice = choice
    case .entireOutput:
      requested = GenerationMaskSource(kind: .entireOutput)
      concreteChoice = choice
    }

    func validate(_ mask: MaskRecipe, label: String) throws {
      guard mask.isEnabled else {
        throw PixeltjeMacError(
          "Inpainting mask disabled",
          "\(label) is disabled. Enable it or choose a different mask source.")
      }
      guard mask.isEvaluable else {
        throw PixeltjeMacError(
          "Inpainting mask unavailable",
          "\(label) has no available mask components. Choose a different mask source.")
      }
      guard !hasEnabledUnavailableComponents(mask) else {
        throw PixeltjeMacError(
          "Inpainting mask unavailable",
          "\(label) contains mask components that are unavailable on this Mac.")
      }
    }

    switch concreteChoice {
    case .documentSelection:
      guard let mask = recipe.selection else {
        throw PixeltjeMacError(
          "Inpainting needs a selection",
          "Create a document selection or choose another mask source.")
      }
      try validate(mask, label: "The document selection")
      return ResolvedGenerationMask(
        requested: requested,
        resolved: GenerationMaskSource(kind: .documentSelection, maskID: mask.id),
        mask: mask,
        renderSource: .documentMask(mask))

    case .layerMask(let layerID, let maskID):
      guard recipe.layerStack.activeLayerID == layerID else {
        throw PixeltjeMacError(
          "Inpainting mask changed",
          "The requested layer mask does not belong to the active layer anymore.")
      }
      guard recipe.layerStack.entry(id: layerID)?.isEffectivelyEnabled == true,
        let layer = recipe.layerStack.layer(id: layerID),
        let mask = layer.layerMask,
        mask.id == maskID
      else {
        throw PixeltjeMacError(
          "Inpainting mask unavailable",
          "The active layer or its requested layer mask is disabled or no longer available.")
      }
      try validate(mask, label: "The layer mask on \(layer.name)")
      return ResolvedGenerationMask(
        requested: requested,
        resolved: GenerationMaskSource(
          kind: .layerMask, layerID: layerID, maskID: mask.id),
        mask: mask,
        renderSource: .layerMask(layerID: layerID, maskID: mask.id))

    case .localMask(let layerID, let maskID):
      guard recipe.layerStack.activeLayerID == layerID else {
        throw PixeltjeMacError(
          "Inpainting mask changed",
          "The requested local mask does not belong to the active layer anymore.")
      }
      guard recipe.layerStack.entry(id: layerID)?.isEffectivelyEnabled == true,
        let layer = recipe.layerStack.layer(id: layerID),
        let mask = layer.mask(id: maskID)
      else {
        throw PixeltjeMacError(
          "Inpainting mask unavailable",
          "The active layer or its requested local mask is disabled or no longer available.")
      }
      try validate(mask, label: mask.name)
      return ResolvedGenerationMask(
        requested: requested,
        resolved: GenerationMaskSource(
          kind: .localMask, layerID: layerID, maskID: mask.id),
        mask: mask,
        renderSource: .localMask(layerID: layerID, maskID: mask.id))

    case .transparentPixels:
      return ResolvedGenerationMask(
        requested: requested,
        resolved: GenerationMaskSource(kind: .transparentPixels),
        mask: .selectingAll,
        renderSource: nil)

    case .entireOutput:
      return ResolvedGenerationMask(
        requested: requested,
        resolved: GenerationMaskSource(kind: .entireOutput),
        mask: .selectingAll,
        renderSource: nil)

    case .automatic, .legacySelectionOrEntireOutput:
      preconditionFailure("Generation mask source resolution must produce a concrete source.")
    }
  }

  /// Compatibility helper for the parked Core AI path. Active ComfyUI
  /// inpainting resolves its selectable mask source explicitly above.
  var effectiveGenerationMask: MaskRecipe {
    editorModel.recipe.selection ?? .selectingAll
  }

  private func generationSourceFrame(
    from frame: RenderedFrame,
    contentRevision: UInt64
  ) -> RenderedFrame? {
    guard accepts(frame), !frame.isProxy,
      frame.samplingLayerStack == displayRecipe.layerStack
    else { return nil }
    return RenderedFrame(
      documentID: frame.documentID,
      revision: frame.revision,
      contentRevision: contentRevision,
      surface: frame.surface,
      activeLayerSamplingSurface: frame.activeLayerSamplingSurface,
      sampledActiveLayerID: frame.sampledActiveLayerID,
      samplingLayerStack: frame.samplingLayerStack,
      width: frame.width,
      height: frame.height,
      isProxy: frame.isProxy,
      inspection: frame.inspection,
      rawInspections: frame.rawInspections,
      elapsedSeconds: frame.elapsedSeconds)
  }

  func cancelActiveGeneration() {
    guard let active = editorModel.generationJobs.last(where: { $0.state.isActive }) else { return }
    recordComfyUIDebug(
      stage: "Cancellation",
      message: "Cancellation requested for local job \(active.id.uuidString).\nRemote job: \(active.backendID ?? "not accepted yet")")
    generationLogger.info("Cancellation requested for job \(active.id.uuidString, privacy: .public)")
    if let promptID = active.backendID {
      let debugSink = comfyUIDebugSink
      let backend = activeGenerationBackend
      // This is the sole owner of remote cancellation. Its independent lifecycle
      // lets the request finish after `generationTask` is cancelled below.
      Task { await backend?.cancel(jobID: promptID, onDebug: debugSink) }
    }
    generationTask?.cancel()
    editorModel.setGenerationPreview(nil)
    updateGeneration(id: active.id, state: .cancelled, progress: active.progress)
  }

  func cancelGeneration(_ id: UUID) -> Bool {
    guard let job = editorModel.generationJobs.first(where: { $0.id == id }), job.state.isActive
    else { return false }
    cancelActiveGeneration()
    return true
  }

  /// Commits a completed output whose source revision diverged while ComfyUI
  /// was running. The generated pixels and placement are frozen, but the add
  /// itself targets the current recipe and remains one ordinary undoable edit.
  func applyComfyUIResultAnyway(jobID: UUID) {
    guard let pending = pendingComfyUIResults.removeValue(forKey: jobID) else {
      pendingComfyUIResultOrder.removeAll { $0 == jobID }
      updateGeneration(
        id: jobID,
        state: .failed("The retained ComfyUI result is no longer available."),
        progress: 1,
        canApplyAnyway: false)
      recordComfyUIDebug(
        stage: "Apply Anyway",
        message: "Could not apply local job \(jobID.uuidString): its retained pixels were unavailable.")
      return
    }

    pendingComfyUIResultOrder.removeAll { $0 == jobID }
    for asset in pending.assets {
      rasterAssets[asset.reference.id] = asset.compressedPixels
    }
    perform(.addGeneratedLayer(pending.layer), interactive: false)
    updateGeneration(
      id: jobID, state: .succeeded, progress: 1, canApplyAnyway: false)
    recordComfyUIDebug(
      stage: "Apply Anyway",
      message: "Added retained layer \(pending.layer.id.rawValue) to the current document.\nProject assets: \(pending.layer.rasterAssetReferences.count)")
    generationLogger.notice(
      "Applied retained ComfyUI job \(jobID.uuidString, privacy: .public) as layer \(pending.layer.id.rawValue, privacy: .public)"
    )
  }

  /// Holds only a small number of completed outputs. This avoids discarding a
  /// useful result on a revision race without allowing session memory to grow
  /// without bound when several stale jobs accumulate.
  func retainComfyUIResultForManualApplication(
    jobID: UUID,
    layer: ProjectLayer,
    assets: [RasterBakeResult]
  ) {
    pendingComfyUIResults[jobID] = PendingComfyUIResult(
      layer: layer, assets: assets)
    pendingComfyUIResultOrder.removeAll { $0 == jobID }
    pendingComfyUIResultOrder.append(jobID)

    while pendingComfyUIResultOrder.count > Self.maximumPendingComfyUIResultCount {
      let evictedJobID = pendingComfyUIResultOrder.removeFirst()
      pendingComfyUIResults.removeValue(forKey: evictedJobID)
      updateGeneration(
        id: evictedJobID,
        state: .failed("The retained ComfyUI result expired after newer results completed."),
        progress: 1,
        canApplyAnyway: false)
    }

    let message =
      "The document changed while ComfyUI was generating. The completed result was retained; choose Apply Anyway to add it as a new layer."
    updateGeneration(
      id: jobID, state: .failed(message), progress: 1, canApplyAnyway: true)
    recordComfyUIDebug(
      stage: "Result retained",
      message: "Local job \(jobID.uuidString) is ready for Apply Anyway.\nSource content revision: \(editorModel.generationJobs.first(where: { $0.id == jobID })?.sourceContentRevision ?? 0)\nCurrent content revision: \(contentRevision)\nProject assets: \(assets.count)")
  }

  private var isShowingTransientHumanEdit: Bool {
    gestureStartRecipe != nil || activeBrushSession != nil
      || activeSelectionBrushSession != nil || selectionBrushTask != nil
      || editorModel.cropDraft != nil || editorModel.transformDraft != nil
      || editorModel.selectionDraft != nil || editorModel.layerOperationStatus.isRunning
  }

  private func updateGeneration(
    id: UUID,
    state: GenerationJobState,
    progress: Double,
    canApplyAnyway: Bool? = nil
  ) {
    var jobs = editorModel.generationJobs
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    let previousState = jobs[index].state
    let isComfyUIJob = jobs[index].templateID != nil
    jobs[index].state = state
    jobs[index].progress = min(max(progress, 0), 1)
    if let canApplyAnyway {
      jobs[index].canApplyAnyway = canApplyAnyway
    }
    editorModel.setGenerationJobs(jobs)
    comfyUIHistoryStore.update(jobID: id, state: state)
    if isComfyUIJob, previousState != state {
      recordComfyUIDebug(
        stage: "Stage",
        message: "\(previousState.label) → \(state.label)\nProgress: \(jobs[index].progress.formatted(.percent.precision(.fractionLength(1))))")
    }
  }

  private func setGenerationBackendID(id: UUID, backendID: String) {
    var jobs = editorModel.generationJobs
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    jobs[index].backendID = backendID
    editorModel.setGenerationJobs(jobs)
    comfyUIHistoryStore.setBackendID(backendID, for: id)
    recordComfyUIDebug(
      stage: "Submission",
      message: "Local job \(id.uuidString) is \(jobs[index].executionTarget.label) job \(backendID).")
  }

  var comfyUIServerAddress: String {
    serverAddress(for: editorModel.comfyUIExecutionTarget)
  }

  private func serverAddress(for target: ComfyUIExecutionTarget) -> String {
    target == .cloud
      ? ComfyCloudClient.baseURL.absoluteString
      : ComfyUIClient.configuredBaseURL.absoluteString
  }

  private func makeComfyUIBackend(for target: ComfyUIExecutionTarget) throws
    -> ComfyUIBackend
  {
    switch target {
    case .local:
      return .local(comfyUIClient)
    case .cloud:
      guard let key = try ComfyCloudCredentialStore.load() else {
        throw PixeltjeMacError(
          "Cloud API key required", "Save a Comfy Cloud API key in Settings first.")
      }
      return .cloud(ComfyCloudClient(apiKey: key))
    }
  }

  func refreshComfyCloudAvailability() {
    let available = (try? ComfyCloudCredentialStore.load()) != nil
    let previousTarget = editorModel.comfyUIExecutionTarget
    editorModel.setComfyCloudAPIKeyAvailable(available)
    if previousTarget == .cloud { refreshComfyUI() }
  }

  func selectComfyUIExecutionTarget(_ target: ComfyUIExecutionTarget) {
    guard !editorModel.generationJobs.contains(where: { $0.state.isActive }),
      target != editorModel.comfyUIExecutionTarget
    else { return }
    editorModel.setComfyUIExecutionTarget(target)
    refreshComfyUI()
  }

  /// Rechecks the server and reconciles active jobs. WebSocket messages are
  /// primary; this is the explicit recovery path exposed beside each task.
  func refreshComfyUI() {
    comfyUIRefreshTask?.cancel()
    editorModel.setComfyUIConnection(.checking)
    editorModel.setComfyUIWorkflowFormLoading()
    let templateID = editorModel.selectedComfyUIWorkflowID
    let target = editorModel.comfyUIExecutionTarget
    let debugSink = comfyUIDebugSink
    let backend: ComfyUIBackend
    let workflowDefinition: ComfyUIResolvedWorkflow
    do {
      backend = try makeComfyUIBackend(for: target)
      workflowDefinition = try ComfyUIWorkflowCatalog.resolve(templateID: templateID)
    } catch {
      editorModel.setComfyUIConnection(.disconnected(error.userFacingMessage))
      editorModel.setComfyUIWorkflowFormFailure(error.userFacingMessage)
      return
    }
    recordComfyUIDebug(
      stage: "Refresh",
      message: "Checking \(comfyUIServerAddress) and loading live schema for \(templateID).")
    comfyUIRefreshTask = Task { [weak self] in
      guard let self else { return }
      let connected = await backend.checkConnection(onDebug: debugSink)
      guard !Task.isCancelled, self.editorModel.comfyUIExecutionTarget == target else { return }
      self.editorModel.setComfyUIConnection(
        connected ? .connected : .disconnected(
          target == .cloud
            ? "Comfy Cloud did not answer. Check your API key and connection."
            : "ComfyUI did not answer at the configured address."))
      guard connected else {
        self.editorModel.setComfyUIWorkflowFormFailure(
          "Connect to ComfyUI to inspect this workflow's node settings.")
        return
      }
      do {
        let form = try await backend.workflowForm(
          resolved: workflowDefinition, onDebug: debugSink)
        guard !Task.isCancelled,
          self.editorModel.comfyUIExecutionTarget == target,
          self.editorModel.selectedComfyUIWorkflowID == templateID
        else { return }
        self.editorModel.setComfyUIWorkflowForm(form)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
          self.editorModel.comfyUIExecutionTarget == target,
          self.editorModel.selectedComfyUIWorkflowID == templateID
        else { return }
        self.editorModel.setComfyUIWorkflowFormFailure(error.userFacingMessage)
      }
      for job in self.editorModel.generationJobs where job.state.isActive && job.backendID != nil {
        guard !Task.isCancelled else { return }
        await self.refreshComfyUIJobNow(job.id)
      }
    }
  }

  func selectComfyUIWorkflow(_ id: String, expectedMode: GenerationMode? = nil) {
    editorModel.selectComfyUIWorkflow(id, expectedMode: expectedMode)
    refreshComfyUI()
  }

  func reconcileComfyUIWorkflowLibrary() {
    let library = ComfyUIWorkflowLibrary.shared
    guard library.isLoaded else { return }
    let currentID = editorModel.selectedComfyUIWorkflowID
    if let current = ComfyUIWorkflowCatalog.templates.first(where: { $0.id == currentID }) {
      if let expectedMode = editorModel.unresolvedComfyUIWorkflowMode,
        current.mode != expectedMode
      {
        selectComfyUIWorkflow(
          AppSettings.storedDefaultComfyUIWorkflowID(for: expectedMode),
          expectedMode: expectedMode)
        return
      }
      if currentID.hasPrefix("user-") {
        selectComfyUIWorkflow(currentID)
      }
      return
    }
    let mode = editorModel.unresolvedComfyUIWorkflowMode ?? editorModel.comfyUIGenerationMode
    selectComfyUIWorkflow(
      AppSettings.storedDefaultComfyUIWorkflowID(for: mode), expectedMode: mode)
  }

  @discardableResult
  func restoreComfyUIHistoryEntry(_ entry: ComfyUIHistoryEntry) -> Bool {
    guard !editorModel.generationJobs.contains(where: { $0.state.isActive }),
      pendingComfyUISelection == nil,
      ComfyUIWorkflowCatalog.templates.contains(where: { $0.id == entry.templateID })
    else { return false }

    let target: ComfyUIExecutionTarget
    let warning: String?
    if entry.executionTarget == .cloud, !editorModel.hasComfyCloudAPIKey {
      target = .local
      warning = "Comfy Cloud is unavailable, so Local was selected"
    } else {
      target = entry.executionTarget
      warning = nil
    }
    editorModel.restoreComfyUIHistoryDraft(
      entry, executionTarget: target, warning: warning)
    // History is app-wide and intentionally excludes document-owned mask IDs.
    // Restoring an older or cross-document entry therefore keeps the exact
    // historical selection-or-entire-output behavior instead of allowing the
    // new Automatic mode to pick an unrelated active-layer mask.
    editorModel.useLegacyGenerationMaskSourceForRestoredHistory()
    refreshComfyUI()
    return true
  }

  func refreshComfyUIJob(_ id: UUID) {
    Task { [weak self] in await self?.refreshComfyUIJobNow(id) }
  }

  private func refreshComfyUIJobNow(_ id: UUID) async {
    guard let job = editorModel.generationJobs.first(where: { $0.id == id }),
      let promptID = job.backendID
    else { return }
    do {
      let debugSink = comfyUIDebugSink
      let backend = try activeGenerationBackend ?? makeComfyUIBackend(for: job.executionTarget)
      let status = try await backend.status(jobID: promptID, onDebug: debugSink)
      editorModel.setComfyUIConnection(.connected)
      switch status {
      case .queued:
        updateGeneration(id: id, state: .queued, progress: job.progress)
      case .running:
        if !job.state.isActive || job.state == .queued {
          updateGeneration(id: id, state: .preparing, progress: max(job.progress, 0.03))
        }
      case .succeeded:
        // The owning generation task still retrieves and imports the output.
        if generationTask == nil {
          updateGeneration(id: id, state: .succeeded, progress: 1)
        }
      case .failed(let message):
        updateGeneration(id: id, state: .failed(message), progress: job.progress)
      case .unknown:
        break
      }
    } catch {
      editorModel.setComfyUIConnection(.disconnected(error.userFacingMessage))
    }
  }

  private func recordRejectedGeneration(prompt: String, message: String) {
    generationLogger.error(
      "Rejected generation document=\(self.projectID.uuidString, privacy: .public) revision=\(self.contentRevision, privacy: .public) promptCharacters=\(prompt.count, privacy: .public): \(message, privacy: .public)"
    )
    var jobs = editorModel.generationJobs
    jobs.append(
      GenerationJob(
        prompt: prompt,
        sourceContentRevision: contentRevision,
        state: .failed(message)))
    editorModel.setGenerationJobs(jobs)
  }

  private static var zImageModelURL: URL {
    if let override = ProcessInfo.processInfo.environment["PIXELTJE_ZIMAGE_MODEL_PATH"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pixeltje/models/z-image-turbo-coreai", isDirectory: true)
  }

  /// Applies a semantic automation request as one recipe mutation, one undo
  /// step, and at most one render. Intermediate recipes are never published.
  func performAutomationActions(
    _ actions: [EditorAction],
    expectedRevision: UInt64,
    actionName: String
  ) throws -> AutomationMutationReceipt {
    guard expectedRevision == contentRevision else {
      throw AutomationServiceError(
        .staleRevision,
        "The document changed after the automation client read it.",
        details: [
          "expectedRevision": String(expectedRevision),
          "currentRevision": String(contentRevision),
        ]
      )
    }
    guard !isBusyForAutomation else {
      throw AutomationServiceError(
        .documentBusy,
        "The document has an in-progress interactive edit. Retry after it finishes."
      )
    }

    let old = editorModel.recipe
    var updated = old
    var requiresRasterRender = false
    for action in actions {
      requiresRasterRender = requiresRasterRender || action.requiresRasterRender(in: updated)
      updated = updated.applying(action)
    }
    guard updated != old else {
      return AutomationMutationReceipt(
        documentID: projectID.uuidString,
        beforeRevision: contentRevision,
        afterRevision: contentRevision,
        historyStepID: editorModel.history.currentStepID.rawValue,
        changed: false
      )
    }

    let beforeRevision = contentRevision
    contentRevision &+= 1
    if requiresRasterRender { revision &+= 1 }
    commitEdit(
      updated,
      actionName: actionName,
      requiresRasterRender: requiresRasterRender
    )
    if requiresRasterRender { scheduleRender(interactive: false) }
    return AutomationMutationReceipt(
      documentID: projectID.uuidString,
      beforeRevision: beforeRevision,
      afterRevision: contentRevision,
      historyStepID: editorModel.history.currentStepID.rawValue,
      changed: true
    )
  }

  public func endEditGesture(actionName: String = "Adjust RAW") {
    guard let initial = gestureStartRecipe else { return }
    gestureStartRecipe = nil
    let final = editorModel.recipe
    if gestureChanged, initial != final {
      // The gesture's intermediate recipes never reached the history, so the
      // drag lands as the single step the current position still points before.
      commitEdit(
        final,
        actionName: actionName,
        requiresRasterRender: gestureRequiresRasterRender
      )
      if gestureRequiresRasterRender {
        scheduleRender(interactive: false)
      }
    }
    gestureChanged = false
    gestureRequiresRasterRender = false
  }

  // MARK: - History

  /// Returns the document to a recorded step, as the history panel does.
  ///
  /// The move is itself undoable, so a jump backwards through the list can be
  /// taken back with ⌘Z like any other edit.
  public func returnToHistoryStep(_ id: HistoryStepID) {
    cancelBrushStroke()
    guard editorModel.history.contains(id), id != editorModel.history.currentStepID else { return }
    let previous = editorModel.history.currentStepID
    let name = editorModel.history.steps.first { $0.id == id }?.name ?? "History"
    guard editorModel.moveHistory(toStep: id) != nil else { return }
    registerUndo(
      returningTo: previous,
      actionName: "Return to \(name)",
      requiresRasterRender: true
    )
    updateChangeCount(.changeDone)
    contentRevision &+= 1
    revision &+= 1
    scheduleRender(interactive: false)
  }

  /// Pins the current state under a name.
  ///
  /// A snapshot is a bookmark rather than an edit: it changes no pixels, so it
  /// is not itself undoable and does not dirty the document.
  @discardableResult
  public func takeSnapshot(named name: String? = nil) -> HistorySnapshotID {
    editorModel.addSnapshot(name: name ?? editorModel.history.suggestedSnapshotName())
  }

  public func deleteSnapshot(_ id: HistorySnapshotID) {
    editorModel.removeSnapshot(id)
  }

  public func renameSnapshot(_ id: HistorySnapshotID, to name: String) {
    editorModel.renameSnapshot(id, to: name)
  }

  /// Restores a pinned state as a new, undoable history step.
  public func restoreSnapshot(_ id: HistorySnapshotID) {
    cancelBrushStroke()
    guard let snapshot = editorModel.history.snapshot(id) else { return }
    guard snapshot.recipe != editorModel.recipe else { return }
    contentRevision &+= 1
    revision &+= 1
    commitEdit(
      snapshot.recipe,
      actionName: "Restore “\(snapshot.name)”",
      requiresRasterRender: true
    )
    scheduleRender(interactive: false)
  }

  /// Records one named step, registers its undo, and marks the document edited.
  private func commitEdit(
    _ recipe: ProjectRecipe,
    actionName: String,
    requiresRasterRender: Bool
  ) {
    let previous = editorModel.history.currentStepID
    editorModel.recordEdit(recipe, name: actionName)
    registerUndo(
      returningTo: previous,
      actionName: actionName,
      requiresRasterRender: requiresRasterRender
    )
    updateChangeCount(.changeDone)
  }

  // MARK: - Export

  /// Queues one export of the document as it stands right now.
  ///
  /// The recipe is snapshotted into the request, so the job keeps exporting
  /// what the user saw when they pressed Export while they go on editing. The
  /// work itself runs in the background queue rather than blocking the window.
  @discardableResult
  public func enqueueExport(
    preset: ExportPreset,
    to folder: URL,
    sequence: Int
  ) -> ExportJob? {
    commitTransformDraft()
    let request: RenderRequest
    do {
      request = try makeRenderRequest(quality: .full)
    } catch {
      editorModel.setRenderStatus(.failed(error.userFacingMessage))
      return nil
    }
    let filename = preset.naming.filename(
      originalName: exportSourceName,
      sequence: sequence,
      presetName: preset.name,
      format: preset.format
    )
    let destination = Self.uniqueDestination(in: folder, filename: filename)
    // The queue reports its own progress in the left panel. The document's
    // render status stays about what the canvas is showing, so a background
    // export never leaves the window looking busy.
    return exportQueue.enqueue(request: request, preset: preset, destination: destination)
  }

  public func cancelExport(_ id: UUID) {
    exportQueue.cancel(id)
  }

  public func removeExport(_ id: UUID) {
    exportQueue.remove(id)
  }

  public func clearCompletedExports() {
    exportQueue.clearCompleted()
  }

  /// The name a naming template expands `{name}` from.
  public var exportSourceName: String {
    editorModel.recipe.source?.originalFilename
      ?? (displayName.isEmpty ? "Untitled" : displayName)
  }

  /// A destination that does not overwrite an existing file.
  ///
  /// Two exports of the same image with the same preset are a normal thing to
  /// do; silently replacing the first one is not.
  private static func uniqueDestination(in folder: URL, filename: String) -> URL {
    let candidate = folder.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
    let base = candidate.deletingPathExtension().lastPathComponent
    let fileExtension = candidate.pathExtension
    for suffix in 1...999 {
      let next = folder.appendingPathComponent("\(base)-\(suffix)")
        .appendingPathExtension(fileExtension)
      if !FileManager.default.fileExists(atPath: next.path) { return next }
    }
    return candidate
  }

  public func scheduleRender(interactive: Bool) {
    // Not a failure: an empty canvas document has nothing to develop or place,
    // and the canvas view shows its extent and vector artwork without a raster
    // frame.
    let needsVectorSamplingFrame = editorModel.pendingSample?.purpose == .foregroundColor
      && !editorModel.recipe.layerStack.vectorArtwork.isEmpty
    guard hasRasterContent || needsVectorSamplingFrame else {
      cancelInteractiveRenderLoop()
      renderTask?.cancel()
      renderTask = nil
      frameAnalysisGeneration &+= 1
      frameAnalysisTask?.cancel()
      frameAnalysisTask = nil
      subjectTagTask?.cancel()
      subjectTagTask = nil
      editorModel.clearRenderedFrame()
      editorModel.setRenderStatus(.idle)
      return
    }
    guard let renderEngine else {
      editorModel.setRenderStatus(.failed("Metal rendering is unavailable."))
      return
    }
    // Every preview is the real image: a slider drag renders at full resolution
    // like any other edit, so what the canvas shows is never a draft standing in
    // for a sharper frame that arrives later.
    let request: RenderRequest
    do {
      request = try makeRenderRequest(quality: .full, includeDifferencePreview: true)
    } catch {
      editorModel.setRenderStatus(.failed(error.userFacingMessage))
      return
    }

    // The toolbar spinner reads this; the canvas keeps its own overlay clear.
    editorModel.setRenderStatus(.preparing("Updating image…"))
    if interactive {
      pendingInteractiveRequest = request
      renderTask?.cancel()
      renderTask = nil
      startInteractiveRenderLoop(using: renderEngine)
      return
    }

    cancelInteractiveRenderLoop()
    renderTask?.cancel()
    renderTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        let frame = try await renderEngine.render(request)
        guard let self, self.accepts(frame) else { return }
        self.editorModel.merge(frame.rawInspections)
        self.editorModel.present(frame)
        self.scheduleAnalysis(of: frame, using: renderEngine)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self?.revision == request.revision else { return }
        self?.editorModel.setRenderStatus(.failed(error.userFacingMessage))
      }
    }
  }

  private func startInteractiveRenderLoop(using renderEngine: RenderEngine) {
    guard interactiveRenderTask == nil else { return }
    interactiveRenderGeneration &+= 1
    let generation = interactiveRenderGeneration
    interactiveRenderTask = Task { [weak self] in
      await self?.runInteractiveRenderLoop(using: renderEngine)
      guard let self, self.interactiveRenderGeneration == generation else { return }
      self.interactiveRenderTask = nil
    }
  }

  private func runInteractiveRenderLoop(using renderEngine: RenderEngine) async {
    while !Task.isCancelled {
      do {
        // Throttle instead of debouncing: slider events replace the pending
        // request without postponing the next frame indefinitely.
        try await Task.sleep(for: .milliseconds(35))
        guard let request = pendingInteractiveRequest else { return }
        pendingInteractiveRequest = nil
        let frame = try await renderEngine.render(request)
        try Task.checkCancellation()
        guard frame.documentID == projectID, frame.revision <= revision else { continue }

        // During a continuous drag, a completed frame can legitimately trail
        // the newest slider value. Present it while the loop starts the latest
        // pending request; mouse-up cancels this loop and renders the exact value.
        editorModel.merge(frame.rawInspections)
        editorModel.present(frame)
        scheduleAnalysis(of: frame, using: renderEngine)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        editorModel.setRenderStatus(.failed(error.userFacingMessage))
      }
    }
  }

  private func cancelInteractiveRenderLoop() {
    interactiveRenderGeneration &+= 1
    pendingInteractiveRequest = nil
    interactiveRenderTask?.cancel()
    interactiveRenderTask = nil
  }

  private func scheduleAnalysis(of frame: RenderedFrame, using renderEngine: RenderEngine) {
    frameAnalysisGeneration &+= 1
    let generation = frameAnalysisGeneration
    frameAnalysisTask?.cancel()
    frameAnalysisTask = Task(priority: .utility) { [weak self] in
      defer {
        if let self, self.frameAnalysisGeneration == generation {
          self.frameAnalysisTask = nil
        }
      }
      // Give AppKit an opportunity to draw the surface published immediately
      // before this task was created.
      await Task.yield()
      do {
        let analysis = try await renderEngine.analyze(frame)
        try Task.checkCancellation()
        self?.editorModel.present(analysis)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self?.editorModel.finishAnalysis(
          documentID: frame.documentID,
          revision: frame.revision,
          contentRevision: frame.contentRevision
        )
      }
    }
    if wantsSubjectTags { scheduleSubjectTags(of: frame, using: renderEngine) }
  }

  /// The prompt box is the only consumer of generated subject names. The
  /// existing Vision classifications remain available while this work runs,
  /// and are retained when the system model cannot be used.
  func setSubjectTagSuggestionsEnabled(_ enabled: Bool) {
    wantsSubjectTags = enabled
    guard enabled, let frame = editorModel.renderedFrame, let renderEngine else {
      subjectTagTask?.cancel()
      subjectTagTask = nil
      return
    }
    scheduleSubjectTags(of: frame, using: renderEngine)
  }

  private func scheduleSubjectTags(of frame: RenderedFrame, using renderEngine: RenderEngine) {
    guard !frame.isProxy else { return }
    subjectTagGeneration &+= 1
    let generation = subjectTagGeneration
    subjectTagTask?.cancel()
    subjectTagTask = Task(priority: .utility) { [weak self] in
      defer {
        if let self, self.subjectTagGeneration == generation {
          self.subjectTagTask = nil
        }
      }
      do {
        // Slider drags replace frames rapidly; wait for a settled frame before
        // asking the language model to inspect it.
        try await Task.sleep(for: .milliseconds(300))
        guard let tags = try await renderEngine.suggestSubjectTags(for: frame) else { return }
        try Task.checkCancellation()
        guard let self, self.wantsSubjectTags else { return }
        self.editorModel.presentGeneratedContentTags(tags, for: frame)
      } catch is CancellationError {
        return
      } catch {
        self?.subjectTagLogger.debug("Subject suggestions unavailable: \(error.localizedDescription)")
      }
    }
  }

  /// Whether this document has pixels to render: a RAW source, a placed image
  /// or text layer anywhere in the tree, or any of them together.
  private var hasRasterContent: Bool {
    editorModel.recipe.layerStack.flattenedLayers.contains {
      $0.isEffectivelyEnabled && !$0.layer.isGroupLayer && $0.layer.isRasterContent
    }
  }

  private func makeRenderRequest(
    quality: RenderQuality, includeDifferencePreview: Bool = false
  ) throws -> RenderRequest {
    var request = RenderRequest(
      documentID: projectID,
      revision: revision,
      contentRevision: contentRevision,
      rawInputs: try currentRawInputs(),
      rasterAssets: try rasterAssets(in: displayRecipe),
      recipe: displayRecipe,
      quality: quality
    )
    if includeDifferencePreview {
      request.differencePreviewLayerID = editorModel.differencePreviewLayerID
    }
    return request
  }

  /// Captures the current composite and document selection as one transient
  /// pipeline invocation. The request and result must match the live revision
  /// before a caller is allowed to use the pixels.
  public func capturePipelineInputs() async throws -> PipelineHostInputSnapshot {
    guard let renderEngine else {
      throw PixeltjeMacError(
        "Pipeline source unavailable", "The document has no active render engine.")
    }
    let request = try makeRenderRequest(quality: .full)
    let snapshot = try await renderEngine.capturePipelineInputs(request)
    try Task.checkCancellation()
    guard isCurrentPipelineInput(snapshot) else {
      throw PixeltjeMacError(
        "Pipeline source changed", "The document changed while its pipeline inputs were captured.")
    }
    return snapshot
  }

  /// Check again after awaiting pipeline execution, before presenting or
  /// committing its result to this document.
  public func isCurrentPipelineInput(_ snapshot: PipelineHostInputSnapshot) -> Bool {
    projectID == snapshot.documentID
      && revision == snapshot.revision
      && contentRevision == snapshot.contentRevision
  }

  /// The recipe this render should draw, which is the document's own except
  /// while Before is on.
  ///
  /// Before is a view of the captured RAW defaults. It is built here, per
  /// request, so the stored recipe, the undo stack, and the dirty state never
  /// learn about it, and it travels the same render path with the same revision
  /// tagging as any other frame.
  private var displayRecipe: ProjectRecipe {
    let recipe = editorModel.renderRecipe
    guard editorModel.isShowingBefore,
      let layerID = recipe.layerStack.activeLayerID,
      let raw = recipe.layerStack.layer(id: layerID)?.developedRawLayer,
      let defaults = raw.rawDevelopment.capturedDefaults
    else { return recipe }
    var before = recipe
    before.layerStack.updateLayer(id: layerID) {
      $0.content = .developedRaw(
        DevelopedRawLayer(
          source: raw.source,
          rawDevelopment: RawDevelopmentRecipe(
            decoderVersion: raw.rawDevelopment.decoderVersion,
            supportedDecoderVersions: raw.rawDevelopment.supportedDecoderVersions,
            parameters: defaults,
            capturedDefaults: raw.rawDevelopment.capturedDefaults,
            capabilities: raw.rawDevelopment.capabilities
          ),
          upright: raw.upright,
          frame: raw.frame,
          needsInitialPlacement: raw.needsInitialPlacement == true
        )
      )
    }
    // This legacy document-wide graph historically belongs only to the base
    // RAW. It must not disappear merely because Before is being viewed on a
    // second, placed RAW layer.
    if layerID == .rawBackground {
      before.rawDevelopment.parameters = defaults
      before.postProcessing = PostProcessingRecipe()
    }
    return before
  }

  /// Arms or clears the clipping indicators.
  ///
  /// They are drawn over the frame in the canvas's display path, so this
  /// changes neither the recipe nor the rendered pixels and needs no re-render.
  public func setClippingIndicators(_ indicators: ClippingIndicators) {
    editorModel.setClipping(indicators)
  }

  public func setDifferencePreview(_ layerID: ProjectLayerID?) {
    guard editorModel.differencePreviewLayerID != layerID else { return }
    editorModel.setDifferencePreviewLayerID(layerID)
    revision &+= 1
    scheduleRender(interactive: false)
  }

  /// What the J key does: both indicators on, or both off.
  public func toggleClippingIndicators() {
    setClippingIndicators(editorModel.clipping.toggledTogether)
  }

  /// Shows the captured RAW defaults, or returns to the current recipe.
  ///
  /// The pixels change, so the render revision advances; nothing else does.
  public func toggleBeforeAfter() {
    guard editorModel.canShowBefore else {
      editorModel.setRenderStatus(
        .failed("There are no captured RAW defaults to compare against."))
      return
    }
    let showing = !editorModel.isShowingBefore
    editorModel.setShowingBefore(showing)
    // A sample taken off the captured defaults would neutralize the very values
    // it is being read from, so turning Before on withdraws a standing request.
    // The tool underneath is left alone: it was never the picker.
    if showing { editorModel.clearPendingSample() }
    revision &+= 1
    scheduleRender(interactive: false)
  }

  /// Asks the canvas for a pixel to neutralize the RAW white balance from.
  ///
  /// The request stands over whatever tool is active until a click fulfils it
  /// or Escape withdraws it.
  public func armWhiteBalanceSample() {
    guard editorModel.canPickWhiteBalance else {
      editorModel.setRenderStatus(
        .failed(
          "The white-balance picker needs a RAW whose white balance the decoder has reported."))
      return
    }
    // Before shows the captured defaults, which is precisely what a sample
    // would be reading. Turning it off is what the user meant by arming the
    // picker while it was on.
    if editorModel.isShowingBefore { toggleBeforeAfter() }
    editorModel.armSample(PixelSampleRequest(purpose: .whiteBalance))
  }

  // MARK: - The shared foreground and background colors

  /// Sets the window's foreground color, and restrokes the selected vector
  /// objects with it.
  ///
  /// The foreground chip and the stroke editor's color well are one control
  /// showing one value, so setting it has to reach as far as the stroke editor
  /// does. With objects selected under a vector tool that means the objects
  /// themselves, not only the default for the next one.
  public func setForegroundColor(_ color: LinearRGBAColor) {
    editorModel.setForegroundColor(color)
    recolorVectorSelection(
      stroke: VectorColor(color), fill: nil, actionName: "Change Vector Stroke")
    recolorActiveTextLayer(VectorColor(color))
  }

  /// The background half of the pair, reaching the selected objects' fills.
  public func setBackgroundColor(_ color: LinearRGBAColor) {
    editorModel.setBackgroundColor(color)
    recolorVectorSelection(
      stroke: nil, fill: VectorColor(color), actionName: "Change Vector Fill")
  }

  public func swapForegroundAndBackgroundColors() {
    editorModel.swapForegroundAndBackgroundColors()
    recolorVectorSelectionFromSharedColors("Swap Foreground and Background Colors")
  }

  public func resetForegroundAndBackgroundColors() {
    editorModel.resetForegroundAndBackgroundColors()
    recolorVectorSelectionFromSharedColors("Reset Foreground and Background Colors")
  }

  private func recolorVectorSelectionFromSharedColors(_ actionName: String) {
    recolorVectorSelection(
      stroke: VectorColor(editorModel.colorTool.foreground),
      fill: VectorColor(editorModel.colorTool.background),
      actionName: actionName)
    recolorActiveTextLayer(VectorColor(editorModel.colorTool.foreground))
  }

  /// The text tool's color row is the foreground chip under another name and
  /// sets the layer being edited, so the chip has to reach that layer too.
  private func recolorActiveTextLayer(_ color: VectorColor) {
    guard editorModel.activeTool == .text,
      let id = editorModel.recipe.layerStack.activeLayerID,
      let layer = editorModel.recipe.layerStack.layer(id: id),
      case .text(let text) = layer.content,
      text.color != color
    else { return }
    var updated = text
    updated.color = color
    perform(.setTextLayer(id, updated), interactive: false)
  }

  /// Recolors the selected vector objects, when a vector tool is what that
  /// selection belongs to. A color control sets colors and nothing else, so an
  /// object with no stroke stays unstroked and one with no fill stays unfilled;
  /// turning either on is the stroke and fill editors' job. A gradient fill is
  /// left alone for the same reason — flattening it to a solid is a change of
  /// fill type, which only the fill type control makes.
  private func recolorVectorSelection(
    stroke: VectorColor?, fill: VectorColor?, actionName: String
  ) {
    guard editorModel.activeTool == .pen || editorModel.activeTool == .shape,
      let target = arrangeableVectorSelection()
    else { return }
    let updated = target.vector.updatingObjects(ids: target.ids) { object in
      if let stroke, object.stroke != nil { object.stroke?.color = stroke }
      if let fill, let existing = object.fill, !existing.isGradient {
        object.fill?.color = fill
      }
    }
    guard updated != target.vector else { return }
    perform(
      .setVectorLayer(target.layerID, updated, actionName: actionName), interactive: false)
  }

  /// Arms an ordinary foreground-color pick over the active tool. This is
  /// window-local tool state: fulfilling it creates no recipe revision,
  /// history entry, undo registration or dirty-document change.
  public func armForegroundColorSample() {
    let hasVisibleVectors = !editorModel.recipe.layerStack.vectorArtwork.isEmpty
    guard editorModel.renderedFrame != nil || hasVisibleVectors else {
      editorModel.setRenderStatus(.failed("Render the canvas before sampling a color."))
      return
    }
    editorModel.armSample(
      PixelSampleRequest(
        purpose: .foregroundColor,
        source: editorModel.colorTool.sampleSource,
        sampleSize: editorModel.colorTool.sampleSize
      )
    )
    if editorModel.renderedFrame == nil { scheduleRender(interactive: false) }
  }

  public func cancelPendingSample() {
    editorModel.clearPendingSample()
  }

  /// Puts the white balance back to the values the file was shot with.
  ///
  /// The targeted counterpart to Reset Apple RAW, which returns every parameter
  /// to its captured default and so costs the exposure and the tone settings to
  /// undo one pick. Before cannot answer this either: it shows the whole frame
  /// as captured, not this one decision reversed.
  public func resetWhiteBalanceToAsShot() {
    guard let asShot = editorModel.asShotWhiteBalance else {
      editorModel.setRenderStatus(
        .failed("There are no captured RAW defaults to return the white balance to."))
      return
    }
    beginEditGesture()
    guard let layerID = editorModel.activeLayer?.id else { return }
    perform(.setRawLayerFloat(layerID, .neutralTemperature, asShot.temperature), interactive: false)
    perform(.setRawLayerFloat(layerID, .neutralTint, asShot.tint), interactive: false)
    endEditGesture(actionName: "As Shot White Balance")
  }

  /// Reads the pixel under the pointer and publishes what it would produce,
  /// without committing anything.
  ///
  /// This is what makes two candidate patches comparable: the kelvin and tint a
  /// pixel asks for are readable before the click, so choosing between them
  /// costs no undo steps. Passing `nil` clears the readout, for a pointer that
  /// has left the image.
  ///
  /// Requests coalesce rather than queue. A sample crosses to the render actor
  /// and back, which is slower than the pointer moves, so only the latest point
  /// is kept while one is in flight and stale results are dropped on arrival.
  public func previewWhiteBalanceSample(atNormalizedX x: Double?, y: Double?) {
    guard editorModel.pendingSample != nil else { return }
    guard let x, let y else {
      pendingPreviewPoint = nil
      editorModel.setSamplePreview(nil)
      return
    }
    pendingPreviewPoint = CGPoint(x: x, y: y)
    guard !isPreviewingSample else { return }
    isPreviewingSample = true
    Task { [weak self] in
      while let self, let point = self.pendingPreviewPoint {
        self.pendingPreviewPoint = nil
        guard let request = self.editorModel.pendingSample else { break }
        let preview: PixelSamplePreview?
        switch request.purpose {
        case .whiteBalance:
          let neutral = await self.neutralWhiteBalance(atNormalizedX: point.x, y: point.y)
          preview = neutral.map {
            .whiteBalance(WhiteBalanceSamplePreview(temperature: $0.temperature, tint: $0.tint))
          }
        case .foregroundColor:
          let sampled = await self.sampledToolColor(
            atNormalizedX: point.x, y: point.y, request: request)
          preview = sampled.map {
            .color(ColorSamplePreview(oldColor: self.editorModel.colorTool.foreground, newColor: $0))
          }
        }
        guard let current = self.editorModel.pendingSample,
          current.purpose == request.purpose,
          current.source == request.source,
          current.sampleSize == request.sampleSize
        else { break }
        self.editorModel.setSamplePreview(preview)
      }
      self?.isPreviewingSample = false
    }
  }

  /// Fulfils a standing request: neutralizes the RAW white balance from the
  /// pixel that was clicked.
  ///
  /// The point is normalized to the document, origin at the bottom left. The
  /// sample is read from the rendered frame through the render actor, and the
  /// two resulting values are applied as one undoable step, named for the
  /// kelvin it landed on so the history panel reads as the list of candidates
  /// it is.
  ///
  /// `keepArmed` is the Option-click: the request survives so the next patch
  /// can be tried straight away.
  public func sampleWhiteBalance(atNormalizedX x: Double, y: Double, keepArmed: Bool = false) {
    guard editorModel.canPickWhiteBalance else {
      editorModel.setRenderStatus(
        .failed(
          "The white-balance picker needs a RAW whose white balance the decoder has reported."))
      return
    }
    Task { [weak self] in
      guard let self else { return }
      // Arming while Before is shown turns it off and schedules a render. The
      // old Before frame can remain on screen until that completes, but it must
      // never be sampled into the editable recipe.
      guard self.editorModel.renderedFrame?.revision == self.revision else {
        self.editorModel.setRenderStatus(.preparing("Updating image…"))
        return
      }
      guard let neutral = await self.neutralWhiteBalance(atNormalizedX: x, y: y) else {
        self.editorModel.setRenderStatus(
          .failed("That pixel is too dark or too clipped to read a white balance from."))
        return
      }
      // Two values, one gesture: temperature and tint undo together.
      self.beginEditGesture()
      guard let layerID = self.editorModel.activeLayer?.id else { return }
      self.perform(
        .setRawLayerFloat(layerID, .neutralTemperature, neutral.temperature), interactive: false)
      self.perform(.setRawLayerFloat(layerID, .neutralTint, neutral.tint), interactive: false)
      let kelvin = neutral.temperature.formatted(.number.precision(.fractionLength(0)))
      self.endEditGesture(actionName: "Pick White Balance (\(kelvin) K)")
      // A one-shot request is spent. An Option-click asked to stay armed, and
      // keeps the crosshair for the next candidate.
      if keepArmed {
        self.editorModel.setSamplePreview(nil)
      } else {
        self.editorModel.clearPendingSample()
      }
    }
  }

  /// Samples into the shared foreground chip, either from an armed visible
  /// action or from an Option-click while painting. The latter passes no
  /// standing request and therefore returns to the brush immediately.
  public func sampleForegroundColor(
    atNormalizedX x: Double,
    y: Double,
    keepArmed: Bool = false
  ) {
    let request = editorModel.pendingSample?.purpose == .foregroundColor
      ? editorModel.pendingSample!
      : PixelSampleRequest(
        purpose: .foregroundColor,
        source: editorModel.colorTool.sampleSource,
        sampleSize: editorModel.colorTool.sampleSize
      )
    Task { [weak self] in
      guard let self else { return }
      guard self.editorModel.renderedFrame?.revision == self.revision else {
        self.editorModel.setRenderStatus(.preparing("Updating image…"))
        return
      }
      let sampledRevision = self.revision
      guard let color = await self.sampledToolColor(
        atNormalizedX: x, y: y, request: request)
      else {
        // A stale completion is simply discarded. It must not overwrite the
        // foreground, clear the standing request, or report transparency for
        // a frame the canvas has already replaced.
        guard self.revision == sampledRevision else { return }
        self.editorModel.setRenderStatus(
          .failed("That sample contains no visible pixels in the selected source."))
        return
      }
      // Through the document rather than the model: an eyedropper pick is a
      // foreground change like any other, and has to reach a vector selection
      // the same way the color well does.
      self.setForegroundColor(color)
      if keepArmed, self.editorModel.pendingSample?.purpose == .foregroundColor {
        self.editorModel.setSamplePreview(nil)
      } else if self.editorModel.pendingSample?.purpose == .foregroundColor {
        self.editorModel.clearPendingSample()
      }
    }
  }

  private func sampledToolColor(
    atNormalizedX x: Double,
    y: Double,
    request: PixelSampleRequest
  ) async -> LinearRGBAColor? {
    guard let renderEngine, let frame = editorModel.renderedFrame,
      frame.revision == revision
    else { return nil }
    let sampledRevision = revision
    let activeLayerID = editorModel.recipe.layerStack.activeLayerID
    guard request.source != .activeLayer || frame.sampledActiveLayerID == activeLayerID else {
      return nil
    }
    let color = await renderEngine.sampleLinearRGBAColor(
      in: frame,
      layerStack: editorModel.recipe.layerStack,
      source: request.source,
      atNormalizedX: x,
      y: y,
      sampleSize: request.sampleSize
    )
    guard revision == sampledRevision,
      frame.revision == sampledRevision,
      request.source != .activeLayer
        || (activeLayerID == editorModel.recipe.layerStack.activeLayerID
          && frame.sampledActiveLayerID == activeLayerID)
    else { return nil }
    return color
  }

  /// The white balance a pixel of the current frame asks for, or `nil` when it
  /// is too dark, too clipped or no longer the frame that was sampled.
  ///
  /// Shared by the hover readout and the click that commits, so the number the
  /// user was shown is the number they get.
  private func neutralWhiteBalance(
    atNormalizedX x: Double,
    y: Double
  ) async -> (temperature: Double, tint: Double)? {
    guard let renderEngine,
      let frame = editorModel.renderedFrame,
      let parameters = editorModel.activeLayer?.developedRawLayer?.rawDevelopment.parameters,
      frame.revision == revision
    else { return nil }
    let sampledRevision = revision
    let sample = await renderEngine.sampleLinearColor(in: frame, atNormalizedX: x, y: y)
    guard revision == sampledRevision, let sample else { return nil }
    return NeutralWhiteBalance.neutralizing(
      sample: sample,
      temperature: parameters.neutralTemperature,
      tint: parameters.neutralTint
    )
  }

  /// The RAW input for every enabled RAW layer in this render.
  ///
  /// A canvas document with placed image layers returns an empty map. A missing
  /// source is reported before rendering rather than producing a partial
  /// composite that silently omits one selected layer.
  private func currentRawInputs() throws -> [ProjectLayerID: RawInput] {
    try rawInputs(in: editorModel.recipe)
  }

  private func rawInputs(in recipe: ProjectRecipe) throws -> [ProjectLayerID: RawInput] {
    var inputs: [ProjectLayerID: RawInput] = [:]
    for entry in recipe.layerStack.flattenedLayers where entry.isEffectivelyEnabled {
      guard let raw = entry.layer.developedRawLayer else { continue }
      guard
        let source = raw.source ?? (entry.id == .rawBackground ? recipe.source : nil)
      else {
        throw PixeltjeMacError(
          "RAW source unavailable",
          "(entry.layer.name) has no linked RAW source. Relink it before rendering."
        )
      }
      let url = try SourceReferenceFactory.resolve(source)
      try SourceReferenceFactory.validateQuickFingerprint(source, at: url)
      inputs[entry.id] = .file(url)
    }
    return inputs
  }

  private func rasterAssets(in recipe: ProjectRecipe) throws -> [RasterAssetID: Data] {
    var result: [RasterAssetID: Data] = [:]
    for reference in recipe.layerStack.flattenedLayers.flatMap({ $0.layer.rasterAssetReferences }) {
      guard let payload = rasterAssets[reference.id] else {
        throw PixeltjeMacError(
          "Raster asset missing",
          "The project does not contain the pixels for raster asset \(reference.id.rawValue)."
        )
      }
      result[reference.id] = payload
    }
    return result
  }

  private func accepts(_ frame: RenderedFrame) -> Bool {
    accepts(documentID: frame.documentID, revision: frame.revision)
  }

  /// Kept framework-free so revision rejection is testable without fabricating
  /// an IOSurface-backed frame.
  func accepts(documentID: UUID, revision candidate: UInt64) -> Bool {
    documentID == projectID && candidate == revision
  }

  var currentRenderRevision: UInt64 { revision }

  /// Registers the undo that walks the history back to `stepID`.
  ///
  /// Undo and redo are moves through the same ordered history the panel shows,
  /// not a second stack of recipes beside it, so ⌘Z and clicking an entry
  /// always agree about where the document is.
  private func registerUndo(
    returningTo stepID: HistoryStepID,
    actionName: String,
    requiresRasterRender: Bool
  ) {
    undoManager?.registerUndo(withTarget: self) { document in
      document.cancelBrushStroke()
      let returnPoint = document.editorModel.history.currentStepID
      document.registerUndo(
        returningTo: returnPoint,
        actionName: actionName,
        requiresRasterRender: requiresRasterRender
      )
      // A trimmed-away step leaves nothing to restore; the registration above
      // keeps the stacks paired either way.
      guard document.editorModel.moveHistory(toStep: stepID) != nil else { return }
      document.contentRevision &+= 1
      if requiresRasterRender {
        document.revision &+= 1
        document.scheduleRender(interactive: false)
      }
    }
    undoManager?.setActionName(actionName)
  }

  private func actionName(for action: EditorAction) -> String {
    switch action {
    case .setRawFloat, .setRawBool, .setRawLayerFloat, .setRawLayerBool: "Adjust RAW"
    case .resetRaw, .resetRawLayer: "Reset RAW"
    case .applyRawPreset(let preset), .applyRawLayerPreset(_, let preset):
      "Apply Preset: \(preset.name)"
    case .setPostProcessing: "Adjust Image"
    case .setLayerEnabled: "Change Layer Visibility"
    case .addImageLayer: "Add Image"
    case .addLayer(let layer):
      switch layer.content {
      case .text: "Add Text"
      case .group: "Add Group"
      case .adjustment(let adjustment): "Add \(adjustment.label) Adjustment"
      case .image: "Add Image"
      case .raster: "Add Raster Layer"
      case .generatedInpaint: "Add Inpaint Layer"
      case .paint: "Add Paint Layer"
      case .vector: "Add Vector Layer"
      case .developedRaw, .canvas: "Add Layer"
      }
    case .addGeneratedLayer: "Generate Image"
    case .removeLayer: "Delete Layer"
    case .duplicateLayer: "Duplicate Layer"
    case .rasterizeLayer: "Rasterize Layer"
    case .mergeLayers: "Merge Layers"
    case .moveLayer: "Reorder Layer"
    case .groupLayer: "Group Layer"
    case .ungroupLayer: "Ungroup"
    case .moveLayerToGroup(_, let groupID):
      groupID == nil ? "Move Layer Out of Group" : "Move Layer into Group"
    case .setLayerBlendMode: "Change Blend Mode"
    case .setLayerOpacity: "Change Opacity"
    case .setLayerFill: "Change Fill"
    case .setLayerDifferenceCutoff: "Change Difference Cutoff"
    case .setLayerDifferenceSoftness: "Change Difference Softness"
    case .setLayerDifferenceRadius: "Change Difference Neighborhood"
    case .setLayerDifferenceOptions(_, _, let actionName): actionName
    case .setGeneratedInpaintThreshold: "Change Inpaint Threshold"
    case .setTextLayer: "Edit Text"
    case .setPaintLayer(_, _, let actionName): actionName
    case .setVectorLayer(_, _, let actionName): actionName
    case .setAdjustment: "Adjust Layer"
    case .setNamedAdjustment(_, _, let actionName): actionName
    case .commitBrushStroke(let stroke, _, _):
      stroke.mode == .erase ? "Erase Stroke" : "Brush Stroke"
    case .commitHeal(let heal, _, _):
      heal.provenance.mode == .spot ? "Spot Heal" : "Heal"
    case .setLayerMask(_, let mask, let actionName):
      actionName ?? (mask == nil ? "Delete Layer Mask" : "Add Layer Mask")
    case .setLayerMaskEnabled(_, let enabled): enabled ? "Enable Layer Mask" : "Disable Layer Mask"
    case .setLayerMaskInverted: "Invert Layer Mask"
    case .commitLayerMaskStroke(_, _, let stroke):
      stroke.mode == .erase ? "Erase Layer Mask" : "Paint Layer Mask"
    case .commitImageEraserStroke: "Erase Layer Mask"
    case .translateLayer: "Move Layer"
    case .setLayerTransform: "Transform Layer"
    case .setLayerStack(_, let actionName): actionName
    case .setCanvasSize, .resizeCanvas: "Resize Canvas"
    case .setLayerAdjustments(_, _, let actionName): actionName
    case .setCanvasSettings(_, let actionName): actionName
    case .setCrop(_, let actionName), .setLayerCrop(_, _, let actionName),
      .cropCanvas(_, let actionName): actionName
    case .setUpright, .setRawLayerUpright: "Adjust Upright"
    case .addMask(_, let mask): "Add \(mask.name)"
    case .removeMask: "Delete Mask"
    case .setMaskEnabled(_, _, let enabled): enabled ? "Show Mask" : "Hide Mask"
    case .setMask(_, _, let actionName): actionName
    case .setMaskAdjustment(_, _, let adjustment):
      adjustment == nil ? "Remove Mask Adjustment" : "Set Mask Adjustment"
    case .setSelection(_, let actionName): actionName
    case .saveSelectionAsMask: "Save Selection as Mask"
    }
  }

  private func startFingerprinting(_ url: URL, layerID: ProjectLayerID) {
    hashTask?.cancel()
    hashTask = Task.detached(priority: .utility) { [weak self] in
      do {
        let hash = try SourceReferenceFactory.sha256(of: url)
        try Task.checkCancellation()
        await MainActor.run {
          guard let self else { return }
          var recipe = self.editorModel.recipe
          guard var raw = recipe.layerStack.layer(id: layerID)?.developedRawLayer,
            raw.source?.linkedPath == url.path
          else { return }
          raw.source?.fingerprint.sha256 = hash
          recipe.layerStack.updateLayer(id: layerID) { $0.content = .developedRaw(raw) }
          if layerID == .rawBackground, recipe.source?.linkedPath == url.path {
            recipe.source?.fingerprint.sha256 = hash
            recipe.rawDevelopment = raw.rawDevelopment
            recipe.upright = raw.upright
          }
          // Not an edit: the hash finishes computing behind the document, so it
          // updates the current history step instead of adding one.
          self.editorModel.updateRecipeInPlace(recipe)
        }
      } catch {
        // A quick size/date fingerprint remains usable; rendering reports
        // source-access problems through the normal document status.
      }
    }
  }
}

extension EditorAction {
  /// Whether applying this action changes the pixels the render engine
  /// composites, rather than only what the canvas draws over them.
  func requiresRasterRender(in recipe: ProjectRecipe) -> Bool {
    return switch self {
    // Vector edits are drawn as overlays above the rendered frame.
    case .setLayerStack, .setVectorLayer:
      false
    // Moving a placed image or text moves pixels the render engine composites.
    // Moving vector artwork moves an overlay the canvas draws itself, and so
    // does fading it.
    case .translateLayer(let id, _, _), .setLayerTransform(let id, _), .setLayerOpacity(let id, _),
      .setLayerFill(let id, _):
      !(recipe.layerStack.layer(id: id)?.isVectorLayer ?? true)
    // The rendered frame is canvas sized, so a resize changes the raster even
    // though no layer content moved.
    case .setCanvasSize, .resizeCanvas:
      true
    // Guides and the grid are drawn over the composited frame, not into it.
    case .setCanvasSettings:
      false
    // The aspect lock and the overlay are how the crop tool behaves, not what
    // the image looks like, so changing only those needs no new render.
    case .setCrop(let crop, _):
      crop.affectsPixels(comparedTo: recipe.crop)
    case .setLayerCrop(let id, let crop, _):
      (crop ?? .identity).affectsPixels(
        comparedTo: recipe.layerStack.layer(id: id)?.crop ?? .identity)
    case .cropCanvas(let crop, _):
      crop.affectsPixels(comparedTo: .identity)
    // Every mask edit changes pixels the render engine composites: a mask
    // carries its own adjustment and is evaluated inside the composite, not
    // drawn as a canvas overlay.
    // The selection is drawn as marching ants over the composited frame, and
    // nothing yet renders differently because of it, so changing it must not
    // cost a develop. This becomes conditional once painting clips to it.
    case .setSelection:
      false
    case .setRawFloat, .setRawBool, .resetRaw, .applyRawPreset,
      .setRawLayerFloat, .setRawLayerBool, .resetRawLayer, .applyRawLayerPreset,
      .setRawLayerUpright, .setPostProcessing, .addImageLayer,
      .addLayer, .addGeneratedLayer, .removeLayer, .setLayerEnabled, .duplicateLayer, .rasterizeLayer,
      .mergeLayers, .moveLayer,
      .groupLayer, .ungroupLayer, .moveLayerToGroup, .setLayerBlendMode,
      .setLayerDifferenceCutoff, .setLayerDifferenceSoftness, .setLayerDifferenceRadius,
      .setLayerDifferenceOptions,
      .setTextLayer, .setPaintLayer, .setGeneratedInpaintThreshold,
      .setAdjustment, .setNamedAdjustment,
      .commitBrushStroke, .commitHeal, .setLayerMask,
      .setLayerMaskEnabled, .setLayerMaskInverted, .commitLayerMaskStroke,
      .commitImageEraserStroke,
      .setLayerAdjustments, .setUpright,
      .addMask, .removeMask, .setMaskEnabled, .setMask, .setMaskAdjustment,
      // Saving a selection adds a mask the composite evaluates, so it does.
      .saveSelectionAsMask:
      true
    }
  }
}

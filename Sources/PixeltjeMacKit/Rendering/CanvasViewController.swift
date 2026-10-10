import AppKit
import Combine
import PixeltjeMacDomain
import SwiftUI

enum CanvasIntent {
  case beginGesture
  case change(EditorAction, interactive: Bool)
  case endGesture(String)
  /// A white-balance pick, in document coordinates normalized to the canvas
  /// with the origin at the bottom left. The canvas states where it was
  /// clicked; the document owns the sampling and the resulting edit.
  ///
  /// `keepArmed` is an Option-click: the request survives its own result so the
  /// next patch can be tried without re-arming, which is what makes comparing
  /// candidates a sequence of clicks rather than a sequence of round trips
  /// through the panel.
  case sampleWhiteBalance(x: Double, y: Double, keepArmed: Bool)
  case sampleForegroundColor(x: Double, y: Double, keepArmed: Bool)
  /// Where the pointer is while a sample is armed, for the readout, or nil
  /// coordinates when it has left the image. Commits nothing.
  case previewSample(x: Double?, y: Double?)
  /// Withdraws a standing sample request: Escape, or a click with nothing to
  /// read under it.
  case cancelSample
  /// The crop tool moved its rectangle or its straighten angle. Nothing is
  /// committed until `commitCrop`.
  case updateCropDraft(CropRecipe, interactive: Bool)
  case commitCrop
  case cancelCrop
  case updateTransformDraft(LayerTransform)
  case commitTransform
  case cancelTransform
  /// Points the masks tool at the mask a canvas gesture just created, so the
  /// next placement joins it instead of starting another one. Tool state, so
  /// it goes to the editor model rather than through the document.
  case activateMask(MaskID?, on: ProjectLayerID?)
  /// The selection tools moved their shape. Nothing reaches the document until
  /// `commitSelection`, so a drag costs no revision and no render.
  case updateSelectionDraft(MaskRecipe?)
  /// Mouse-up: one selection, one undoable step, named for what was done.
  case commitSelection(MaskRecipe?, actionName: String)
  case cancelSelectionDraft
  /// A click from Magnet Selection. Pixel analysis and the undoable selection
  /// change belong to the document, not the canvas.
  case applyMagnetSelection(at: VectorPoint, combine: MaskCombineOperation?)
  case beginSelectionBrushStroke(BrushSample, combine: MaskCombineOperation?)
  case beginBrushStroke(BrushSample)
  case appendBrushSamples([BrushSample])
  case commitBrushStroke
  case commitSelectionBrushStroke
  case cancelBrushStroke
  case adjustBrushSize(increasing: Bool)
  /// Mouse-up under the Healing Brush. The captured stroke is the same one a
  /// brush would have committed; the document solves it before it becomes an
  /// edit, so this is a separate intent rather than a flag on the one above.
  case commitHeal
  /// Option-click under the Healing Brush: the source region's anchor, in
  /// document coordinates normalized to the canvas with the origin at the
  /// bottom left. Tool state, so it goes to the editor model.
  case setHealSource(x: Double, y: Double)
  case commitGradient(layerID: ProjectLayerID?, start: VectorPoint, end: VectorPoint)
  case applyFill(at: VectorPoint)
  case commitShape(
    start: VectorPoint, end: VectorPoint, constrained: Bool, fromCenter: Bool)
  case selectLayer(ProjectLayerID)
  case deleteVectorObjects
  /// Which vector objects the canvas has selected. Transient tool state: it
  /// goes to the editor model, never into the recipe or history.
  case setVectorObjectSelection(Set<UUID>)
}

@MainActor
final class CanvasViewController: NSViewController {
  let canvas: MetalCanvasView
  private let viewSettings: CanvasViewSettings
  private let topRuler = CanvasRulerView(orientation: .horizontal)
  private let leftRuler = CanvasRulerView(orientation: .vertical)
  private let rulerCorner = CanvasRulerCornerView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let beforeBadge = NSTextField(labelWithString: "Before")
  let promptBoxModel: PromptBoxModel
  private let promptBox: PromptBoxHostingView
  private var canvasLeading: NSLayoutConstraint?
  private var canvasTop: NSLayoutConstraint?
  private var statusBottomToCanvas: NSLayoutConstraint?
  private var statusBottomToPrompt: NSLayoutConstraint?
  private var promptCenterX: NSLayoutConstraint?
  private var promptBottom: NSLayoutConstraint?
  private var promptWidth: NSLayoutConstraint?
  private var promptHeight: NSLayoutConstraint?
  private var collapsedPromptBoxHeight: CGFloat = 180
  private var expandedPromptBoxHeight: CGFloat = 470
  private var subscriptions: Set<AnyCancellable> = []
  private var latestStatus: RenderStatus = .idle
  private var latestTool: EditorTool = .navigate
  private var latestPaintTarget: PaintTarget?
  private var pendingSample: PixelSampleRequest?
  private var latestShowingBefore = false
  private var latestBaseFrame: RenderedFrame?
  private(set) var isPromptBoxVisible = false
  var onPromptBoxVisibilityChange: (Bool) -> Void = { _ in }

  init(
    model: EditorModel,
    viewSettings: CanvasViewSettings = .shared,
    send: @escaping (CanvasIntent) -> Void,
    generate: @escaping (String) -> Void = { _ in },
    cancelGeneration: @escaping () -> Void = {},
    updateGenerationSettings: @escaping (InpaintingToolState) -> Void = { _ in },
    clearComfyUIDebugEvents: @escaping () -> Void = {},
    setComfyUIDebugDiskLoggingEnabled: @escaping (Bool) -> Void = { _ in },
    revealComfyUIDebugLog: @escaping () -> Void = {},
    applyComfyUIResultAnyway: @escaping (UUID) -> Void = { _ in },
    selectGenerationMode: @escaping (GenerationMode) -> Void = { _ in },
    selectGenerationMaskSource: @escaping (GenerationMaskSourceChoice) -> Void = { _ in },
    selectExecutionTarget: @escaping (ComfyUIExecutionTarget) -> Void = { _ in },
    selectContentTag: @escaping (String) -> Void = { _ in },
    applySelectionPreview: @escaping () -> Void = {},
    discardSelectionPreview: @escaping () -> Void = {}
  ) {
    self.viewSettings = viewSettings
    canvas = MetalCanvasView(viewSettings: viewSettings, send: send)
    let promptBoxModel = PromptBoxModel(
      generationSettings: model.inpaintingTool,
      generationMode: model.comfyUIGenerationMode,
      comfyUIDebugDiskLoggingState: model.comfyUIDebugDiskLoggingState,
      generationMaskSourcePresentation: model.generationMaskSourcePresentation,
      generationMaskSourceOptions: model.generationMaskSourceOptions,
      onSubmit: generate,
      onCancelGeneration: cancelGeneration,
      onUpdateGenerationSettings: updateGenerationSettings,
      onClearComfyUIDebugEvents: clearComfyUIDebugEvents,
      onSetComfyUIDebugDiskLoggingEnabled: setComfyUIDebugDiskLoggingEnabled,
      onRevealComfyUIDebugLog: revealComfyUIDebugLog,
      onApplyComfyUIResultAnyway: applyComfyUIResultAnyway,
      onSelectGenerationMode: selectGenerationMode,
      onSelectGenerationMaskSource: selectGenerationMaskSource,
      onSelectExecutionTarget: selectExecutionTarget,
      onSelectTag: selectContentTag,
      onApplySelectionPreview: applySelectionPreview,
      onDiscardSelectionPreview: discardSelectionPreview)
    self.promptBoxModel = promptBoxModel
    let promptBox = PromptBoxHostingView(rootView: PromptBoxView(model: promptBoxModel))
    promptBox.sizingOptions = []
    self.promptBox = promptBox
    super.init(nibName: nil, bundle: nil)
    NotificationCenter.default.publisher(
      for: UserDefaults.didChangeNotification, object: UserDefaults.standard
    )
    .sink { [weak self] _ in self?.updateStatusLabel() }
    .store(in: &subscriptions)
    promptBoxModel.onMove = { [weak self] delta in self?.movePromptBox(by: delta) }
    promptBox.onMove = { [weak self] delta in self?.movePromptBox(by: delta) }
    promptBoxModel.onResize = { [weak self] delta in self?.resizePromptBox(by: delta) }
    promptBoxModel.onClose = { [weak self] in self?.setPromptBoxVisible(false) }
    // Applying a generated selection ends prompt entry and starts canvas work.
    // A SwiftUI button does not resign the prompt field on macOS, so without
    // this handoff Command-C and Backspace keep going to that field instead of
    // the document's copy and selection-delete commands.
    promptBoxModel.onApplySelectionPreview = { [weak self] in
      applySelectionPreview()
      guard let self else { return }
      self.view.window?.makeFirstResponder(self.canvas)
    }
    canvas.onViewportChange = { [weak self] viewport in
      self?.topRuler.update(viewport)
      self?.leftRuler.update(viewport)
    }
    // Dragging out of a ruler makes a guide. The ruler forwards the raw event
    // and the canvas decides what it means, so the ruler stays presentation.
    configureGuideDragging(from: topRuler, axis: .horizontal)
    configureGuideDragging(from: leftRuler, axis: .vertical)
    // EditorModel publishes on the main actor. Keep delivery synchronous because
    // RunLoop.main's default mode pauses while a SwiftUI slider tracks the mouse.
    model.$recipe
      .sink { [weak self, weak canvas, weak model] recipe in
        canvas?.updateRecipe(recipe)
        self?.latestPaintTarget = model?.resolvedPaintTarget
        if let model {
          self?.promptBoxModel.setGenerationMaskSources(
            presentation: model.generationMaskSourcePresentation(
              for: model.generationMaskSource, in: recipe),
            options: model.generationMaskSourceOptions)
        }
        self?.updateStatusLabel()
      }
      .store(in: &subscriptions)
    model.$generationMaskSource
      .sink { [weak self, weak model] source in
        guard let model else { return }
        self?.promptBoxModel.setGenerationMaskSources(
          presentation: model.generationMaskSourcePresentation(for: source, in: model.recipe),
          options: model.generationMaskSourceOptions)
      }
      .store(in: &subscriptions)
    model.$selectedComfyUIWorkflowMode
      .sink { [weak self] mode in
        self?.promptBoxModel.setGenerationMode(mode)
      }
      .store(in: &subscriptions)
    model.$comfyUIExecutionTarget
      .sink { [weak self] target in self?.promptBoxModel.setExecutionTarget(target) }
      .store(in: &subscriptions)
    model.$hasComfyCloudAPIKey
      .sink { [weak self] available in
        self?.promptBoxModel.setComfyCloudAPIKeyAvailable(available)
      }
      .store(in: &subscriptions)
    model.$imageContentTags
      .sink { [weak self] tags in self?.promptBoxModel.setContentTags(tags) }
      .store(in: &subscriptions)
    model.$comfyUISelectionPreview
      .sink { [weak self] selection in self?.promptBoxModel.setSelectionPreview(selection) }
      .store(in: &subscriptions)
    model.$pendingSample
      .sink { [weak self] request in
        self?.pendingSample = request
        self?.canvas.setPendingSample(request)
        self?.updateStatusLabel()
      }
      .store(in: &subscriptions)
    model.$clipping
      .sink { [weak canvas] indicators in canvas?.setClipping(indicators) }
      .store(in: &subscriptions)
    model.$isShowingBefore
      .sink { [weak self] showing in
        self?.latestShowingBefore = showing
        self?.updateBeforeBadge()
        self?.updateStatusLabel()
      }
      .store(in: &subscriptions)
    // A project with no RAW source publishes no frame; the canvas still has an
    // extent to show, so nil clears the raster instead of being dropped.
    model.$renderedFrame
      .sink { [weak self, weak model] frame in
        self?.latestBaseFrame = frame
        guard model?.generationPreview == nil else { return }
        guard let frame else {
          self?.canvas.clearFrame()
          return
        }
        self?.canvas.present(frame)
      }
      .store(in: &subscriptions)
    model.$generationPreview
      .sink { [weak self] preview in
        guard let self else { return }
        if let preview {
          self.canvas.present(preview)
        } else if let latestBaseFrame = self.latestBaseFrame {
          self.canvas.present(latestBaseFrame)
        } else {
          self.canvas.clearFrame()
        }
      }
      .store(in: &subscriptions)
    model.$generationJobs
      .sink { [weak self] jobs in
        self?.promptBoxModel.setGenerationJobs(jobs)
      }
      .store(in: &subscriptions)
    model.$comfyUIDebugEvents
      .sink { [weak self] events in
        self?.promptBoxModel.setComfyUIDebugEvents(events)
      }
      .store(in: &subscriptions)
    model.$comfyUIDebugImages
      .sink { [weak self] images in
        self?.promptBoxModel.setComfyUIDebugImages(images)
      }
      .store(in: &subscriptions)
    model.$comfyUIDebugDiskLoggingState
      .sink { [weak self] state in
        self?.promptBoxModel.setComfyUIDebugDiskLoggingState(state)
      }
      .store(in: &subscriptions)
    promptBoxModel.$isFailureExpanded
      .removeDuplicates()
      .sink { [weak self] expanded in
        self?.updatePromptBoxHeight(failureExpanded: expanded)
      }
      .store(in: &subscriptions)
    promptBoxModel.$isDetailsExpanded
      .removeDuplicates()
      .sink { [weak self] expanded in
        self?.updatePromptBoxHeight(detailsExpanded: expanded)
      }
      .store(in: &subscriptions)
    model.$inpaintingTool
      .sink { [weak self] settings in
        self?.promptBoxModel.setGenerationSettings(settings)
      }
      .store(in: &subscriptions)
    model.$renderStatus
      .sink { [weak self] status in
        self?.latestStatus = status
        self?.updateStatusLabel()
      }
      .store(in: &subscriptions)
    model.$activeTool
      .sink { [weak self, weak model] tool in
        self?.latestTool = tool
        self?.canvas.setTool(tool)
        let settings: BrushSettings? = switch tool {
        case .eraser: model?.eraserSettings
        case .selectionBrush: model?.selectionBrushTool.brushSettings
        default: model?.brushSettings
        }
        if let settings {
          self?.canvas.setBrushSettings(settings)
        }
        self?.updateStatusLabel()
      }
      .store(in: &subscriptions)
    model.$transformDraft
      .sink { [weak canvas] draft in canvas?.setTransformDraft(draft) }
      .store(in: &subscriptions)
    model.$vectorToolStyle
      .sink { [weak canvas] style in canvas?.setVectorToolStyle(style) }
      .store(in: &subscriptions)
    model.$shapeTool
      .sink { [weak canvas] state in canvas?.setShapeTool(state) }
      .store(in: &subscriptions)
    model.$textToolStyle
      .sink { [weak canvas] style in canvas?.setTextToolStyle(style) }
      .store(in: &subscriptions)
    model.$brushSettings
      .sink { [weak canvas, weak model] settings in
        if model?.activeTool == .brush { canvas?.setBrushSettings(settings) }
      }
      .store(in: &subscriptions)
    model.$eraserSettings
      .sink { [weak canvas, weak model] settings in
        if model?.activeTool == .eraser { canvas?.setBrushSettings(settings) }
      }
      .store(in: &subscriptions)
    // The canvas draws the source anchor and sizes the heal cursor, so it
    // needs the tool's own settings rather than the Brush's.
    model.$healTool
      .sink { [weak canvas] state in canvas?.setHealTool(state) }
      .store(in: &subscriptions)
    model.$brushPreview
      .sink { [weak canvas] preview in canvas?.presentBrushPreview(preview) }
      .store(in: &subscriptions)
    model.$paintTarget
      .sink { [weak self, weak model] _ in
        self?.latestPaintTarget = model?.resolvedPaintTarget
        self?.updateStatusLabel()
      }
      .store(in: &subscriptions)
    // Rulers, guides and the grid are view state: the same toggle serves the
    // View menu and the inspector, so both surfaces move together.
    viewSettings.$values
      .sink { [weak self] values in
        guard let self else { return }
        if let showsRulers = values[.rulers] {
          updateRulerVisibility(shows: showsRulers)
        }
        canvas.refreshOverlays()
      }
      .store(in: &subscriptions)
    model.$cropDraft
      .sink { [weak canvas] draft in canvas?.setCropDraft(draft) }
      .store(in: &subscriptions)
    // The canvas places masks, so it needs to know what the left panel is set
    // to and which mask the next gesture should join.
    model.$maskTool
      .sink { [weak canvas] state in canvas?.setMaskTool(state) }
      .store(in: &subscriptions)
    model.$selectionTool
      .sink { [weak canvas] state in canvas?.setSelectionTool(state) }
      .store(in: &subscriptions)
    model.$magnetSelectionTool
      .sink { [weak canvas] state in canvas?.setMagnetSelectionTool(state) }
      .store(in: &subscriptions)
    model.$selectionBrushTool
      .sink { [weak canvas] state in canvas?.setSelectionBrushTool(state) }
      .store(in: &subscriptions)
    model.$selectionDraft
      .sink { [weak canvas] draft in canvas?.setSelectionDraft(draft) }
      .store(in: &subscriptions)
    model.$vectorEditMode
      .sink { [weak canvas] mode in canvas?.setVectorEditMode(mode) }
      .store(in: &subscriptions)
    model.$selectedVectorObjectIDs
      .sink { [weak canvas] ids in canvas?.setSelectedVectorObjects(ids) }
      .store(in: &subscriptions)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CanvasViewController is created programmatically")
  }

  override func loadView() {
    let container = NSView()
    for subview in [canvas, topRuler, leftRuler, rulerCorner, statusLabel, promptBox] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
    }
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.alignment = .center
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    statusLabel.wantsLayer = true
    statusLabel.layer?.cornerRadius = 8
    statusLabel.layer?.backgroundColor =
      NSColor.windowBackgroundColor.withAlphaComponent(0.86).cgColor

    // A badge, not a status line: Before stays on screen for as long as the
    // comparison does, and the status line keeps reporting rendering.
    beforeBadge.translatesAutoresizingMaskIntoConstraints = false
    beforeBadge.font = .systemFont(ofSize: 11, weight: .semibold)
    beforeBadge.alignment = .center
    beforeBadge.textColor = .white
    beforeBadge.wantsLayer = true
    beforeBadge.layer?.cornerRadius = 6
    beforeBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    beforeBadge.isHidden = true
    beforeBadge.setAccessibilityLabel("Showing the captured RAW defaults")
    promptBox.isHidden = !isPromptBoxVisible
    // This overlay must follow the canvas rather than advertise a document
    // width to the surrounding split view. Its normal width is only a
    // preference; narrow multi-panel layouts are allowed to compress it.
    promptBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    container.addSubview(canvas)
    container.addSubview(topRuler)
    container.addSubview(leftRuler)
    container.addSubview(rulerCorner)
    container.addSubview(statusLabel)
    container.addSubview(beforeBadge)
    container.addSubview(promptBox)

    let thickness = CanvasRulerView.thickness
    let canvasLeading = canvas.leadingAnchor.constraint(
      equalTo: container.leadingAnchor, constant: thickness)
    let canvasTop = canvas.topAnchor.constraint(equalTo: container.topAnchor, constant: thickness)
    self.canvasLeading = canvasLeading
    self.canvasTop = canvasTop
    let statusBottomToCanvas = statusLabel.bottomAnchor.constraint(
      equalTo: container.bottomAnchor, constant: -18)
    let statusBottomToPrompt = statusLabel.bottomAnchor.constraint(
      equalTo: promptBox.topAnchor, constant: -12)
    self.statusBottomToCanvas = statusBottomToCanvas
    self.statusBottomToPrompt = statusBottomToPrompt
    let preferredPromptWidth = promptBox.widthAnchor.constraint(equalToConstant: 760)
    preferredPromptWidth.priority = .defaultLow
    self.promptWidth = preferredPromptWidth
    let promptCenterX = promptBox.centerXAnchor.constraint(equalTo: canvas.centerXAnchor)
    let promptBottom = promptBox.bottomAnchor.constraint(
      equalTo: canvas.bottomAnchor, constant: -28)
    self.promptCenterX = promptCenterX
    self.promptBottom = promptBottom
    let promptHeight = promptBox.heightAnchor.constraint(
      equalToConstant: preferredPromptBoxHeight)
    self.promptHeight = promptHeight

    let promptFitsCanvas = promptBox.widthAnchor.constraint(
      lessThanOrEqualTo: canvas.widthAnchor, constant: -48)
    promptFitsCanvas.priority = .defaultHigh
    let statusFitsContainer = statusLabel.widthAnchor.constraint(
      lessThanOrEqualTo: container.widthAnchor, constant: -48)
    statusFitsContainer.priority = .defaultHigh

    NSLayoutConstraint.activate([
      canvasLeading,
      canvasTop,
      canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),

      // Each ruler shares the canvas's own span, so a position along a ruler is
      // the same coordinate the canvas reported without another conversion.
      topRuler.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
      topRuler.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
      topRuler.topAnchor.constraint(equalTo: container.topAnchor),
      topRuler.heightAnchor.constraint(equalToConstant: thickness),

      leftRuler.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      leftRuler.widthAnchor.constraint(equalToConstant: thickness),
      leftRuler.topAnchor.constraint(equalTo: canvas.topAnchor),
      leftRuler.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

      rulerCorner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      rulerCorner.topAnchor.constraint(equalTo: container.topAnchor),
      rulerCorner.widthAnchor.constraint(equalToConstant: thickness),
      rulerCorner.heightAnchor.constraint(equalToConstant: thickness),

      beforeBadge.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 16),
      beforeBadge.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 16),
      beforeBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
      beforeBadge.heightAnchor.constraint(equalToConstant: 22),

      statusLabel.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
      statusBottomToCanvas,
      statusFitsContainer,
      statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

      promptCenterX,
      promptBottom,
      preferredPromptWidth,
      promptFitsCanvas,
      promptHeight,
    ])
    view = container
    updateRulerVisibility(shows: viewSettings.isOn(.rulers))
    updateBeforeBadge()
    updateStatusLabel()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    if isPromptBoxVisible { clampPromptBoxToCanvas() }
  }

  /// Shows or hides the prompt without changing document or shared view state.
  /// Each document window owns its own prompt and draft text.
  func togglePromptBox() {
    setPromptBoxVisible(!isPromptBoxVisible)
  }

  func setPromptBoxVisible(_ visible: Bool) {
    guard visible != isPromptBoxVisible else {
      if visible { promptBoxModel.requestFocus() }
      return
    }
    isPromptBoxVisible = visible
    onPromptBoxVisibilityChange(visible)
    promptBox.isHidden = !visible
    statusBottomToCanvas?.isActive = !visible
    statusBottomToPrompt?.isActive = visible

    if visible {
      view.layoutSubtreeIfNeeded()
      view.layoutSubtreeIfNeeded()
      promptBoxModel.requestFocus()
    } else {
      view.window?.makeFirstResponder(canvas)
    }
  }

  private func movePromptBox(by delta: CGPoint) {
    guard isPromptBoxVisible, let promptCenterX, let promptBottom else { return }
    view.layoutSubtreeIfNeeded()
    let translation = clampedPromptTranslation(delta)
    promptCenterX.constant += translation.x
    promptBottom.constant += translation.y
    view.layoutSubtreeIfNeeded()
  }

  /// Resizes from the bottom-trailing corner while keeping the opposite corner
  /// stable. A details height and a compact height are remembered separately,
  /// so collapsing the log never discards the user's preferred expanded size.
  private func resizePromptBox(by delta: CGSize) {
    guard isPromptBoxVisible, let promptCenterX, let promptBottom,
      let promptWidth, let promptHeight
    else { return }
    view.layoutSubtreeIfNeeded()

    let allowed = canvas.frame.insetBy(dx: 16, dy: 16)
    guard allowed.width > 0, allowed.height > 0 else { return }
    let oldFrame = promptBox.frame
    let minimumWidth = min(460, allowed.width)
    let newWidth = min(max(oldFrame.width + delta.width, minimumWidth), allowed.width)
    let failureHeight = promptBoxModel.isFailureExpanded ? 154.0 : 0.0
    let minimumContentHeight = promptBoxModel.isDetailsExpanded ? 360.0 : 180.0
    let minimumHeight = minimumContentHeight + failureHeight
    let maximumHeight = max(minimumHeight, allowed.height)
    let newHeight = min(max(oldFrame.height + delta.height, minimumHeight), maximumHeight)

    let widthChange = newWidth - oldFrame.width
    let heightChange = newHeight - oldFrame.height
    guard widthChange != 0 || heightChange != 0 else { return }

    promptWidth.constant = newWidth
    promptHeight.constant = newHeight
    // Width grows to the right; height grows down from the resize handle.
    // The controller's bottom constraint uses the inverse of frame Y.
    promptCenterX.constant += widthChange / 2
    promptBottom.constant += heightChange
    if promptBoxModel.isDetailsExpanded {
      expandedPromptBoxHeight = newHeight - failureHeight
    } else {
      collapsedPromptBoxHeight = newHeight - failureHeight
    }
    view.layoutSubtreeIfNeeded()
    clampPromptBoxToCanvas()
    view.layoutSubtreeIfNeeded()
  }

  private var preferredPromptBoxHeight: CGFloat {
    (promptBoxModel.isDetailsExpanded ? expandedPromptBoxHeight : collapsedPromptBoxHeight)
      + (promptBoxModel.isFailureExpanded ? 154 : 0)
  }

  private func updatePromptBoxHeight(
    failureExpanded: Bool? = nil,
    detailsExpanded: Bool? = nil
  ) {
    guard let promptHeight else { return }
    let isFailureExpanded = failureExpanded ?? promptBoxModel.isFailureExpanded
    let isDetailsExpanded = detailsExpanded ?? promptBoxModel.isDetailsExpanded
    promptHeight.constant =
      (isDetailsExpanded ? expandedPromptBoxHeight : collapsedPromptBoxHeight)
      + (isFailureExpanded ? 154 : 0)
    guard isViewLoaded, isPromptBoxVisible else { return }
    // @Published sends the new value before storing it. Laying out here would
    // size the hosting view for the new state while SwiftUI still sees the old
    // one, leaving the newly expanded glass empty until another state change.
    view.needsLayout = true
  }

  /// Keeps the draggable surface reachable after a drag or window resize.
  private func clampPromptBoxToCanvas() {
    guard let promptCenterX, let promptBottom else { return }
    let correction = clampedPromptTranslation(.zero)
    promptCenterX.constant += correction.x
    promptBottom.constant += correction.y
  }

  /// Constrains a requested movement before it reaches Auto Layout. Applying a
  /// correction after layout from both the drag path and `viewDidLayout` used
  /// the same stale frame twice, which could launch the box beyond the edge.
  private func clampedPromptTranslation(_ requested: CGPoint) -> CGPoint {
    let allowed = canvas.frame.insetBy(dx: 16, dy: 16)
    let frame = promptBox.frame
    guard allowed.width > 0, allowed.height > 0, !frame.isEmpty else { return .zero }

    // Horizontal constraint and frame coordinates share a direction. The
    // hosted view's bottom constraint is flipped relative to its frame Y.
    let proposed = frame.offsetBy(dx: requested.x, dy: -requested.y)
    let minimumX = allowed.minX
    let maximumX = allowed.maxX - frame.width

    // When an expanded details box is taller than the available canvas, keeping
    // every pixel inside is impossible. Keep its complete 44-point title area
    // reachable so it can always be dragged back or collapsed.
    let minimumY = frame.height <= allowed.height
      ? allowed.minY
      : allowed.minY + min(44, allowed.height) - frame.height
    let maximumY = allowed.maxY - frame.height

    let clampedX = minimumX <= maximumX
      ? min(max(proposed.minX, minimumX), maximumX)
      : frame.minX
    let clampedY = min(max(proposed.minY, minimumY), maximumY)

    return CGPoint(x: clampedX - frame.minX, y: frame.minY - clampedY)
  }

  private func updateBeforeBadge() {
    guard isViewLoaded else { return }
    beforeBadge.isHidden = !latestShowingBefore
  }

  private func configureGuideDragging(from ruler: CanvasRulerView, axis: GuideAxis) {
    ruler.onMouseDown = { [weak self] event in
      self?.canvas.beginGuideCreation(axis: axis, windowPoint: event.locationInWindow)
    }
    ruler.onMouseDragged = { [weak self] event in
      self?.canvas.updateGuideGesture(windowPoint: event.locationInWindow)
    }
    ruler.onMouseUp = { [weak self] event in
      self?.canvas.endGuideGesture(windowPoint: event.locationInWindow)
    }
  }

  private func updateRulerVisibility(shows: Bool) {
    guard isViewLoaded else { return }
    topRuler.isHidden = !shows
    leftRuler.isHidden = !shows
    rulerCorner.isHidden = !shows
    canvasLeading?.constant = shows ? CanvasRulerView.thickness : 0
    canvasTop?.constant = shows ? CanvasRulerView.thickness : 0
  }

  private func updateStatusLabel() {
    guard isViewLoaded else { return }
    statusLabel.textColor = statusIsFailure ? .systemRed : .secondaryLabelColor
    // Render progress belongs to the toolbar spinner, not to a balloon over the
    // photo: only something the spinner cannot say — a failure — earns the
    // overlay, and the rest of it stays with the tool hints.
    if statusIsFailure {
      statusLabel.stringValue = latestStatus.message
      statusLabel.setAccessibilityLabel(latestStatus.message)
      statusLabel.isHidden = false
    } else if InteractionPreferences.disablesHints {
      statusLabel.isHidden = true
    } else if pendingSample != nil {
      // The armed picker outranks the tool underneath, because it owns the next
      // click. Hovering reports the white balance that pixel would produce, so
      // two candidate patches can be compared before either is committed.
      let hint =
        if let preview = pendingSample?.preview {
          "\(preview.summary) · Click to apply · ⌥ click to keep picking · Escape cancels"
        } else if pendingSample?.purpose == .foregroundColor {
          "Click to sample the foreground color · ⌥ click to keep picking · Escape cancels"
        } else {
          "Click a grey or white part of the image to neutralize its white balance"
        }
      statusLabel.stringValue = hint
      let picker = pendingSample?.purpose == .foregroundColor ? "Color picker" : "White balance picker"
      statusLabel.setAccessibilityLabel("\(picker). \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .move {
      let hint = "Drag inside the box to move the selected layer · ⇧ constrain · Arrows nudge"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Move tool. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .text {
      let hint = "Click the canvas to place text · Edit the selected text in the right panel"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Text tool. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .masks {
      let hint = "Drag to place a gradient mask · Click to sample a luminance or color range"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Masks tool. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .brush || latestTool == .eraser {
      let name = latestTool == .brush ? "Brush" : "Eraser"
      let destination = if case .layerMask = latestPaintTarget {
        "layer-mask coverage"
      } else {
        "layer pixels"
      }
      let hint = "\(name) targets \(destination) · Pressure controls size and coverage · Escape cancels"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("\(name) tool. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .selectionBrush {
      let hint = "Paint over the area to select · Shift adds · Option subtracts · Shift-Option intersects · Escape cancels"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Selection Brush tool. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .move {
      let hint = "Click to select a shape, path, or layer · Shift-click adds objects on one vector layer · Drag to move"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Select/Move tool. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .pen {
      let hint = "Drag: smooth point · ⇧ constrain · ⌥ split handles · Space move point"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Pen modifiers. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .gradient {
      let hint = "Drag to set the gradient handles · The current selection clips the result"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Gradient tool. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .fill {
      let hint = "Click a connected region, or choose Selection in Tool Settings"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Fill tool. \(hint)")
      statusLabel.isHidden = false
    } else if latestTool == .shape {
      let hint = "Drag to add a vector shape · Hold Shift for equal width and height"
      statusLabel.stringValue = hint
      statusLabel.setAccessibilityLabel("Shape tool. \(hint)")
      statusLabel.isHidden = false
    } else {
      statusLabel.isHidden = true
    }
  }

  private var statusIsFailure: Bool {
    if case .failed = latestStatus { true } else { false }
  }
}

import AppKit
import Foundation
import PixeltjeMacDomain
import SwiftUI
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func promptBoxIsHiddenByDefaultAndCanBeToggled() {
  let controller = CanvasViewController(model: EditorModel()) { _ in }

  _ = controller.view

  #expect(!controller.isPromptBoxVisible)
  controller.togglePromptBox()
  #expect(controller.isPromptBoxVisible)
  controller.togglePromptBox()
  #expect(!controller.isPromptBoxVisible)
}

@MainActor
@Test func showingPromptAgainRequestsFocus() {
  let controller = CanvasViewController(model: EditorModel()) { _ in }
  _ = controller.view

  #expect(controller.promptBoxModel.focusRequest == 0)
  controller.togglePromptBox()
  #expect(controller.promptBoxModel.focusRequest == 1)
  controller.setPromptBoxVisible(true)
  #expect(controller.promptBoxModel.focusRequest == 2)
  controller.togglePromptBox()
  #expect(controller.promptBoxModel.focusRequest == 2)
}

@MainActor
@Test func applyingASelectionReturnsKeyboardCommandsToTheCanvas() throws {
  var didApply = false
  let controller = CanvasViewController(
    model: EditorModel(), send: { _ in },
    applySelectionPreview: { didApply = true })
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller

  let promptField = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
  controller.view.addSubview(promptField)
  #expect(window.makeFirstResponder(promptField))
  #expect(window.firstResponder === promptField)

  controller.promptBoxModel.applySelectionPreview()

  #expect(didApply)
  #expect(window.firstResponder === controller.canvas)
}

@MainActor
@Test func typedPromptKeepsAnOtherwiseEmptyDocumentFromBeingDiscarded() {
  let model = PromptBoxModel()
  #expect(!model.hasUnsubmittedPrompt)

  model.prompt = "A landscape at dusk"
  #expect(model.hasUnsubmittedPrompt)

  model.prompt = "  \n "
  #expect(!model.hasUnsubmittedPrompt)
}

@MainActor
@Test func promptBoxDragHandleTracksStableWindowCoordinateDeltas() throws {
  let handle = PromptBoxDragTrackingView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
  var deltas: [CGPoint] = []
  handle.onMove = { deltas.append($0) }

  func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1))
  }

  #expect(handle.acceptsFirstMouse(for: nil))
  handle.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 80)))
  handle.mouseDragged(
    with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 125, y: 95)))
  handle.mouseDragged(
    with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 115)))
  handle.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 115)))

  #expect(deltas == [CGPoint(x: 25, y: -15), CGPoint(x: -5, y: -20)])
}

@MainActor
@Test func promptBoxResizeHandleTracksVisualSizeDeltas() throws {
  let handle = PromptBoxResizeTrackingView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
  var deltas: [CGSize] = []
  handle.onResize = { deltas.append($0) }

  func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1))
  }

  #expect(handle.acceptsFirstMouse(for: nil))
  handle.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 80)))
  handle.mouseDragged(
    with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 125, y: 65)))
  handle.mouseDragged(
    with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 90)))
  handle.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 120, y: 90)))

  #expect(deltas == [CGSize(width: 25, height: 15), CGSize(width: -5, height: -25)])
}

@MainActor
@Test func promptBoxHostingRoutesInteractionSurfacesAndBlocksClickThrough() throws {
  let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
  let canvas = NSView(frame: container.bounds)
  container.addSubview(canvas)
  let hostingView = PromptBoxHostingView(rootView: PromptBoxView(model: PromptBoxModel()))
  hostingView.frame = NSRect(x: 240, y: 260, width: 760, height: 180)
  container.addSubview(hostingView)
  hostingView.layoutSubtreeIfNeeded()

  var pendingViews = hostingView.subviews
  var dragSurface: PromptBoxDragTrackingView?
  while let candidate = pendingViews.popLast() {
    if let candidate = candidate as? PromptBoxDragTrackingView {
      dragSurface = candidate
      break
    }
    pendingViews.append(contentsOf: candidate.subviews)
  }

  let surface = try #require(dragSurface)
  #expect(surface.bounds.width > 100)
  #expect(surface.bounds.height >= 20)
  let dragCenterInContainer = surface.convert(
    CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: container)
  #expect(hostingView.hitTest(dragCenterInContainer) === surface)
  #expect(container.hitTest(dragCenterInContainer) === surface)

  var pendingResizeViews = hostingView.subviews
  var resizeSurface: PromptBoxResizeTrackingView?
  while let candidate = pendingResizeViews.popLast() {
    if let candidate = candidate as? PromptBoxResizeTrackingView {
      resizeSurface = candidate
      break
    }
    pendingResizeViews.append(contentsOf: candidate.subviews)
  }
  let resolvedResizeSurface = try #require(resizeSurface)
  let resizeCenterInContainer = resolvedResizeSurface.convert(
    CGPoint(x: resolvedResizeSurface.bounds.midX, y: resolvedResizeSurface.bounds.midY),
    to: container)
  #expect(hostingView.hitTest(resizeCenterInContainer) === resolvedResizeSurface)
  #expect(container.hitTest(resizeCenterInContainer) === resolvedResizeSurface)

  // Transparent glass pixels are still owned by the overlay instead of
  // falling through to the canvas.
  let blankGlassPoints = [
    CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 90),
    CGPoint(x: 758, y: 2), CGPoint(x: 758, y: 90),
    CGPoint(x: 380, y: 2),
  ]
  for localPoint in blankGlassPoints {
    let point = hostingView.convert(localPoint, to: container)
    #expect(hostingView.hitTest(point) === hostingView)
    #expect(container.hitTest(point) === hostingView)
  }
  #expect(container.hitTest(hostingView.convert(CGPoint(x: -2, y: 90), to: container)) === canvas)
  #expect(hostingView.hitTest(hostingView.convert(CGPoint(x: -2, y: 90), to: container)) == nil)
}

@MainActor
@Test func blankPromptGlassTracksDragWithoutStartingACanvasGesture() throws {
  let controller = CanvasViewController(model: EditorModel()) { _ in }
  controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
  controller.setPromptBoxVisible(true)
  controller.view.layoutSubtreeIfNeeded()
  let hostingView = try #require(
    controller.view.subviews.first(where: { $0 is PromptBoxHostingView })
      as? PromptBoxHostingView)
  let initialFrame = hostingView.frame
  let blankGlassPoint = hostingView.convert(CGPoint(x: 2, y: 2), to: controller.view)
  #expect(controller.view.hitTest(blankGlassPoint) === hostingView)

  func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }
  #expect(hostingView.acceptsFirstMouse(for: nil))
  hostingView.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 80)))
  hostingView.mouseDragged(
    with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 125, y: 95)))
  hostingView.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 125, y: 95)))
  controller.view.layoutSubtreeIfNeeded()
  #expect(abs(hostingView.frame.minX - initialFrame.minX - 25) < 0.5)
  #expect(abs(hostingView.frame.minY - initialFrame.minY - 15) < 0.5)
}

@MainActor
@Test func promptBoxCannotBeDraggedPastTheCanvasEdges() throws {
  let controller = CanvasViewController(model: EditorModel()) { _ in }
  controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
  controller.view.layoutSubtreeIfNeeded()
  controller.setPromptBoxVisible(true)
  let promptBox = try #require(
    controller.view.subviews.first(where: { $0 is PromptBoxHostingView }))

  for delta in [
    CGPoint(x: 0, y: -10_000),
    CGPoint(x: 0, y: 10_000),
    CGPoint(x: -10_000, y: 0),
    CGPoint(x: 10_000, y: 0),
  ] {
    controller.promptBoxModel.onMove(delta)
    controller.view.layoutSubtreeIfNeeded()
    let allowed = controller.canvas.frame.insetBy(dx: 16, dy: 16)
    #expect(promptBox.frame.minX >= allowed.minX)
    #expect(promptBox.frame.maxX <= allowed.maxX)
    #expect(promptBox.frame.minY >= allowed.minY)
    #expect(promptBox.frame.maxY <= allowed.maxY)
  }
}

@MainActor
@Test func oversizedPromptBoxKeepsItsDragHeaderReachable() throws {
  let controller = CanvasViewController(model: EditorModel()) { _ in }
  controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 360)
  controller.promptBoxModel.toggleDetails()
  controller.setPromptBoxVisible(true)
  controller.view.layoutSubtreeIfNeeded()
  let promptBox = try #require(
    controller.view.subviews.first(where: { $0 is PromptBoxHostingView }))
  let allowed = controller.canvas.frame.insetBy(dx: 16, dy: 16)
  #expect(promptBox.frame.height > allowed.height)

  controller.promptBoxModel.onMove(CGPoint(x: 0, y: 10_000))
  controller.view.layoutSubtreeIfNeeded()
  #expect(promptBox.frame.maxY >= allowed.minY + 44)

  controller.promptBoxModel.onMove(CGPoint(x: 0, y: -10_000))
  controller.view.layoutSubtreeIfNeeded()
  #expect(promptBox.frame.maxY <= allowed.maxY)
}

@MainActor
@Test func promptBoxCanBeResizedAndRemembersCompactAndDetailsHeights() throws {
  let controller = CanvasViewController(model: EditorModel()) { _ in }
  controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
  controller.setPromptBoxVisible(true)
  controller.view.layoutSubtreeIfNeeded()
  let promptBox = try #require(
    controller.view.subviews.first(where: { $0 is PromptBoxHostingView }))

  controller.promptBoxModel.onResize(CGSize(width: -120, height: 80))
  controller.view.layoutSubtreeIfNeeded()
  #expect(abs(promptBox.frame.width - 640) < 0.5)
  #expect(abs(promptBox.frame.height - 260) < 0.5)

  controller.promptBoxModel.toggleDetails()
  controller.view.layoutSubtreeIfNeeded()
  #expect(abs(promptBox.frame.height - 470) < 0.5)
  controller.promptBoxModel.onResize(CGSize(width: 40, height: -80))
  controller.view.layoutSubtreeIfNeeded()
  #expect(abs(promptBox.frame.width - 680) < 0.5)
  #expect(abs(promptBox.frame.height - 390) < 0.5)

  controller.promptBoxModel.toggleDetails()
  controller.view.layoutSubtreeIfNeeded()
  #expect(abs(promptBox.frame.height - 260) < 0.5)
  controller.promptBoxModel.toggleDetails()
  controller.view.layoutSubtreeIfNeeded()
  #expect(abs(promptBox.frame.height - 390) < 0.5)
}

@MainActor
@Test func promptBoxReplacesDevelopmentWithComfyUIOptions() {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  _ = controller.window

  #expect(controller.developPanelModel.sections.map(\.id) == [.development])

  controller.togglePromptBox(nil)
  #expect(controller.developPanelModel.sections.map(\.id) == [.comfyUI])

  controller.togglePromptBox(nil)
  #expect(controller.developPanelModel.sections.map(\.id) == [.development])
}

@MainActor
@Test func generateToolTogglesPromptAndTemporarilyHidesOtherPanels() throws {
  let document = ProjectDocument()
  let controller = ProjectWindowController(projectDocument: document)
  let window = try #require(controller.window)
  window.layoutIfNeeded()
  let split = try #require(controller.contentViewController as? NSSplitViewController)
  let leftPanel = split.splitViewItems[1]
  let rightPanel = split.splitViewItems[4]
  let promptMenuItem = NSMenuItem(
    title: "Prompt Box",
    action: #selector(ProjectWindowController.togglePromptBox(_:)),
    keyEquivalent: "k"
  )

  controller.activateBrushTool(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  #expect(!leftPanel.isCollapsed)
  #expect(!rightPanel.isCollapsed)

  controller.activateGenerateTool(nil)
  #expect(document.editorModel.activeTool == .generate)
  #expect(leftPanel.isCollapsed)
  #expect(rightPanel.isCollapsed)
  #expect(controller.validateMenuItem(promptMenuItem))
  #expect(promptMenuItem.state == .on)

  controller.activateGenerateTool(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  #expect(document.editorModel.activeTool == .brush)
  #expect(!leftPanel.isCollapsed)
  #expect(!rightPanel.isCollapsed)
  #expect(controller.validateMenuItem(promptMenuItem))
  #expect(promptMenuItem.state == .off)
}

@MainActor
@Test func generateToolPreservesAnAlreadyHiddenLayersPanel() throws {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  let window = try #require(controller.window)
  window.layoutIfNeeded()
  let split = try #require(controller.contentViewController as? NSSplitViewController)
  let rightPanel = split.splitViewItems[4]

  controller.toggleRightPanel(nil)
  #expect(rightPanel.isCollapsed)
  controller.activateGenerateTool(nil)
  #expect(rightPanel.isCollapsed)
  controller.togglePromptBox(nil)
  #expect(rightPanel.isCollapsed)

  controller.activateGenerateTool(nil)
  controller.toggleRightPanel(nil)
  #expect(!rightPanel.isCollapsed)
  controller.activateGenerateTool(nil)
  #expect(!rightPanel.isCollapsed)
}

@MainActor
@Test func idleGenerateStaysActionableAndSubmitsThePrompt() {
  var submittedPrompt: String?
  let controller = CanvasViewController(
    model: EditorModel(),
    send: { _ in },
    generate: { submittedPrompt = $0 })
  _ = controller.view
  let model = controller.promptBoxModel

  #expect(model.isPrimaryActionEnabled)
  #expect(model.primaryActionTitle == "Execute")
  model.prompt = "  replace the selected area with red flowers  "
  model.performPrimaryAction()
  #expect(submittedPrompt == "replace the selected area with red flowers")
}

@MainActor
@Test func emptyPromptKeepsIdleGenerateEnabledAndShowsRequirement() {
  var submitted = false
  let model = PromptBoxModel(
    onSubmit: { _ in submitted = true },
    onPromptRequired: {})

  model.prompt = " \n "
  model.performPrimaryAction()

  #expect(!submitted)
  #expect(model.statusText == "Enter a prompt")
  #expect(model.primaryActionTitle == "Execute")
  #expect(model.isPrimaryActionEnabled)
}

@MainActor
@Test func emptyPromptSubmitsForInpainting() {
  var submittedPrompt: String?
  let model = PromptBoxModel(
    generationMode: .inpainting,
    onSubmit: { submittedPrompt = $0 },
    onPromptRequired: {})

  model.prompt = " \n "
  model.performPrimaryAction()

  #expect(submittedPrompt == "")
  #expect(model.statusText == nil)
}

@MainActor
@Test func activeGenerationTurnsPrimaryActionIntoCancellation() {
  var submitted = false
  var cancellationCount = 0
  let editorModel = EditorModel()
  let controller = CanvasViewController(
    model: editorModel,
    send: { _ in },
    generate: { _ in submitted = true },
    cancelGeneration: { cancellationCount += 1 })
  _ = controller.view
  let model = controller.promptBoxModel
  model.prompt = "red flowers"
  editorModel.setGenerationJobs([
    GenerationJob(
      prompt: "red flowers",
      sourceContentRevision: 17,
      state: .loadingModel,
      progress: 0.02)
  ])

  #expect(model.primaryActionTitle == "Stop")
  #expect(model.isPrimaryActionEnabled)
  model.performPrimaryAction()

  #expect(!submitted)
  #expect(cancellationCount == 1)
}

@MainActor
@Test func generationProgressAndStatusTrackTheActiveJob() {
  let editorModel = EditorModel()
  let controller = CanvasViewController(model: editorModel) { _ in }
  _ = controller.view
  let model = controller.promptBoxModel
  editorModel.setGenerationJobs([
    GenerationJob(
      prompt: "red flowers",
      sourceContentRevision: 17,
      state: .denoising(step: 3, total: 8),
      progress: 0.375)
  ])

  #expect(model.statusText == "Denoising 3 of 8")
  #expect(model.progress == 0.375)
  #expect(model.primaryActionTitle == "Stop")

  editorModel.setGenerationJobs([])
  #expect(model.statusText == nil)
  #expect(model.progress == nil)
  #expect(model.primaryActionTitle == "Execute")
}

@MainActor
@Test func terminalGenerationFailureRemainsVisibleAndGenerateBecomesActionable() {
  let editorModel = EditorModel()
  let controller = CanvasViewController(model: editorModel) { _ in }
  _ = controller.view
  let model = controller.promptBoxModel

  editorModel.setGenerationJobs([
    GenerationJob(
      id: UUID(uuidString: "A1A2A3A4-A5A6-A7A8-A9AA-ABACADAEAFB0")!,
      prompt: "red flowers",
      sourceContentRevision: 17,
      state: .failed("Node 70 failed.\nTraceback: model unavailable"),
      backendID: "comfy-prompt-42",
      templateID: "z-image")
  ])

  #expect(model.statusText == "Workflow failed")
  #expect(model.terminalFailure?.message == "Node 70 failed.\nTraceback: model unavailable")
  #expect(model.terminalFailure?.copyText.contains("Workflow: z-image") == true)
  #expect(model.terminalFailure?.copyText.contains("ComfyUI prompt: comfy-prompt-42") == true)
  #expect(!model.isFailureExpanded)
  model.toggleFailureDetails()
  #expect(model.isFailureExpanded)
  #expect(model.progress == nil)
  #expect(model.primaryActionTitle == "Execute")
  #expect(model.isPrimaryActionEnabled)

  model.prompt = "try a different prompt"
  #expect(model.terminalFailure == nil)
  #expect(!model.isFailureExpanded)
}

@MainActor
@Test func retainedStaleGenerationCanBeAppliedAnywayFromPromptBox() {
  let jobID = UUID(uuidString: "B1B2B3B4-B5B6-B7B8-B9BA-BBBCBDBEBFC0")!
  var appliedJobID: UUID?
  let model = PromptBoxModel(
    onApplyComfyUIResultAnyway: { appliedJobID = $0 })
  model.setGenerationJobs([
    GenerationJob(
      id: jobID,
      prompt: "red flowers",
      sourceContentRevision: 17,
      state: .failed("The document changed while ComfyUI was generating."),
      templateID: "flux2-klein-inpaint-base",
      canApplyAnyway: true),
    GenerationJob(
      prompt: "a later generation",
      sourceContentRevision: 18,
      state: .succeeded,
      progress: 1,
      templateID: "flux2-klein-inpaint-base"),
  ])

  #expect(model.terminalFailure?.canApplyAnyway == true)
  #expect(model.terminalFailure?.copyText.contains("available to apply anyway") == true)
  model.applyComfyUIResultAnyway()
  #expect(appliedJobID == jobID)
}

@MainActor
@Test func generationResolutionMenuUpdatesOutputSizeWithoutChangingTheCanvas() {
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 1600, height: 900)
  let editorModel = EditorModel(recipe: recipe)
  let controller = CanvasViewController(
    model: editorModel,
    send: { _ in },
    updateGenerationSettings: { editorModel.setInpaintingTool($0) })
  let model = controller.promptBoxModel

  model.selectResolution(CanvasRecipe(width: 512, height: 512))

  #expect(editorModel.recipe.layerStack.canvas == CanvasRecipe(width: 1600, height: 900))
  #expect(editorModel.inpaintingTool.outputSize == CanvasRecipe(width: 512, height: 512))
  #expect(model.resolutionTitle == "512 × 512")
}

@Test func generationDefaultsToTheModelsReferenceResolution() {
  let settings = InpaintingToolState()
  #expect(settings.outputSize == CanvasRecipe(width: 1024, height: 1024))
  #expect(settings.maskBlur == 0)
}

@MainActor
@Test func promptBoxUpdatesSeedModeTransparentBackgroundAndMaskExpansion() {
  var latestSettings: InpaintingToolState?
  let model = PromptBoxModel(
    onUpdateGenerationSettings: { latestSettings = $0 })

  var settings = InpaintingToolState()
  settings.seed = 42
  settings.randomizeSeed = true
  model.setGenerationSettings(settings)
  model.reuseCurrentSeed()
  #expect(latestSettings?.randomizeSeed == false)
  #expect(latestSettings?.seed == 42)
  #expect(model.seedTitle == "Seed: 42")
  model.setBackground(.gray)
  #expect(latestSettings?.transparentPixelBackground == .gray)
  #expect(model.backgroundTitle == "Base: Gray")
  #expect(model.generationSettings.expandMaskForComfyUI)
  model.setExpandMaskForComfyUI(false)
  #expect(latestSettings?.expandMaskForComfyUI == false)
  #expect(model.generationSettings.expandMaskForComfyUI == false)
}

@Test func legacyGenerationSettingsEnableComfyUIMaskExpansionByDefault() throws {
  let saved = try JSONEncoder().encode(InpaintingToolState())
  var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
  object.removeValue(forKey: "expandMaskForComfyUI")

  let legacy = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(InpaintingToolState.self, from: legacy)

  #expect(decoded.expandMaskForComfyUI)
}

@MainActor
@Test func promptBoxDescribesBlankCanvasGenerationAsTextToImage() {
  let model = PromptBoxModel(generationMode: .textToImage)

  #expect(model.primaryActionHelp.contains("seeded noise"))
  model.setGenerationMode(.inpainting)
  #expect(model.primaryActionHelp.contains("Automatic"))
  #expect(model.primaryActionHelp.contains("Transparent Pixels"))
}

@MainActor
@Test func imageTagChoosesSelectionWorkflowAndPreservesTheEditPrompt() {
  let model = PromptBoxModel(generationMode: .inpainting)
  model.prompt = "remove the clock from the wall"
  var chosenTag: String?
  model.onSelectTag = { tag in
    chosenTag = tag
    model.setGenerationMode(.selection)
  }
  let clock = ImageContentTag(id: "clock", isRecommended: false)
  model.setContentTags([
    ImageContentTag(id: "outdoor", isRecommended: true),
    clock,
  ])
  #expect(model.moreContentTags.contains(clock))
  model.chooseContentTag(clock)
  #expect(chosenTag == "clock")
  #expect(model.generationMode == .selection)
  #expect(model.prompt == "clock")
  #expect(model.primaryActionTitle == "Execute")
  model.setGenerationMode(.inpainting)
  #expect(model.prompt == "remove the clock from the wall")
}

@MainActor
@Test func generatedSubjectNamesBecomeDistinctSelectionPrompts() {
  let tags = normalizedSubjectTags([
    "  Red   bicycle. ",
    "red bicycle",
    "\ncat\t",
    "",
    String(repeating: "x", count: 81),
  ])

  #expect(tags.map(\.label) == ["Red bicycle", "cat"])
  #expect(tags.allSatisfy { $0.isRecommended })
  #expect(tags.allSatisfy { $0.source == .foundationModel })
  let model = PromptBoxModel()
  model.setContentTags(tags)
  #expect(model.visibleContentTags == tags)
  #expect(normalizedSubjectTags((0..<40).map { "object \($0)" }).count == 32)
}

@MainActor
@Test func visibleImageTagsIncludeBothSourcesWithinThirtyTwoSlots() {
  let model = PromptBoxModel()
  let generated = (0..<32).map {
    ImageContentTag(id: "object \($0)", isRecommended: true, source: .foundationModel)
  }
  let vision = [
    ImageContentTag(id: "cat", isRecommended: true),
    ImageContentTag(id: "outdoor", isRecommended: true),
    ImageContentTag(id: "uncertain", isRecommended: false),
  ]
  model.setContentTags(generated + vision)

  #expect(model.visibleContentTags.count == 32)
  #expect(model.visibleContentTags.prefix(4).map(\.id) == [
    "cat", "object 0", "outdoor", "object 1",
  ])
  #expect(model.moreContentTags.contains(generated[31]))
  #expect(model.moreContentTags.contains(vision[2]))
}

@MainActor
@Test func selectingAWorkflowUpdatesThePromptModeImmediately() {
  let editorModel = EditorModel()
  let controller = CanvasViewController(model: editorModel) { _ in }
  _ = controller.view

  #expect(controller.promptBoxModel.primaryActionHelp.contains("seeded noise"))
  #expect(controller.promptBoxModel.workflowModeTitle == "Mode: Generating")
  editorModel.selectComfyUIWorkflow("flux2-klein-text-to-image-9b-base")
  #expect(controller.promptBoxModel.workflowModeTitle == "Mode: Generating")
  editorModel.selectComfyUIWorkflow("flux2-klein-text-to-image-9b-distilled")
  #expect(controller.promptBoxModel.workflowModeTitle == "Mode: Generating")
  editorModel.selectComfyUIWorkflow("flux2-klein-image-edit-9b-base")
  #expect(controller.promptBoxModel.workflowModeTitle == "Mode: Editing")
  editorModel.selectComfyUIWorkflow("flux2-klein-image-edit-9b-distilled")
  #expect(controller.promptBoxModel.workflowModeTitle == "Mode: Editing")
  editorModel.selectComfyUIWorkflow("flux2-klein-inpaint-base")
  #expect(controller.promptBoxModel.primaryActionHelp.contains("Transparent Pixels"))
  #expect(controller.promptBoxModel.workflowModeTitle == "Mode: Inpainting")
  editorModel.selectComfyUIWorkflow("sam3-selection")
  #expect(controller.promptBoxModel.workflowModeTitle == "Mode: Selection")
}

@MainActor
@Test func promptModeSelectionUsesTheSavedDefaultWorkflow() throws {
  let suiteName = "PromptBoxTests.comfyUI.\(UUID().uuidString)"
  let suite = try #require(UserDefaults(suiteName: suiteName))
  defer { suite.removePersistentDomain(forName: suiteName) }
  let settings = AppSettings(preferences: suite)
  settings.setDefaultComfyUIWorkflowID("flux2-klein-inpaint-distilled", for: .inpainting)
  settings.setDefaultComfyUIWorkflowID("z-image-upscaled", for: .textToImage)
  settings.setDefaultComfyUIWorkflowID("flux2-klein-image-edit-distilled", for: .imageToImage)

  let editorModel = EditorModel()
  let controller = CanvasViewController(
    model: editorModel,
    send: { _ in },
    selectGenerationMode: { mode in
      editorModel.selectComfyUIWorkflow(settings.defaultComfyUIWorkflowID(for: mode))
    })
  _ = controller.view
  let prompt = controller.promptBoxModel

  prompt.selectGenerationMode(.inpainting)
  #expect(editorModel.selectedComfyUIWorkflowID == "flux2-klein-inpaint-distilled")
  #expect(prompt.workflowModeTitle == "Mode: Inpainting")

  editorModel.selectComfyUIWorkflow("flux2-klein-inpaint-base")
  prompt.selectGenerationMode(.inpainting)
  #expect(editorModel.selectedComfyUIWorkflowID == "flux2-klein-inpaint-base")

  prompt.selectGenerationMode(.textToImage)
  #expect(editorModel.selectedComfyUIWorkflowID == "z-image-upscaled")
  #expect(prompt.workflowModeTitle == "Mode: Generating")

  prompt.selectGenerationMode(.imageToImage)
  #expect(editorModel.selectedComfyUIWorkflowID == "flux2-klein-image-edit-distilled")
  #expect(prompt.workflowModeTitle == "Mode: Editing")

  prompt.selectGenerationMode(.selection)
  #expect(editorModel.selectedComfyUIWorkflowID == "sam3-selection")
  #expect(prompt.workflowModeTitle == "Mode: Selection")
}

@MainActor
@Test func promptBoxDetailsRetainEventsRecordedWhileCollapsed() {
  let editorModel = EditorModel()
  let controller = CanvasViewController(
    model: editorModel,
    send: { _ in },
    clearComfyUIDebugEvents: { editorModel.clearComfyUIDebugEvents() })
  _ = controller.view
  let prompt = controller.promptBoxModel

  #expect(!prompt.isDetailsExpanded)

  editorModel.appendComfyUIDebugEvent(
    ComfyUIDebugEvent(
      timestamp: Date(timeIntervalSince1970: 1_000),
      stage: "Upload",
      message: "Source PNG: 4096 bytes"))
  #expect(prompt.comfyUIDebugTranscript.contains("[Upload]"))
  #expect(prompt.comfyUIDebugTranscript.contains("Source PNG: 4096 bytes"))
  prompt.toggleDetails()
  #expect(prompt.isDetailsExpanded)
  #expect(prompt.comfyUIDebugTranscript.contains("Source PNG: 4096 bytes"))
  editorModel.appendComfyUIDebugImage(
    ComfyUIDebugImage(label: "Sent to ComfyUI — source", imageData: Data([0x89, 0x50])))
  editorModel.appendComfyUIDebugImage(
    ComfyUIDebugImage(label: "Returned by ComfyUI — raw output", imageData: Data([0x89, 0x50])))
  #expect(
    prompt.comfyUIDebugImages.map(\.label) == [
      "Sent to ComfyUI — source", "Returned by ComfyUI — raw output",
    ])

  prompt.clearComfyUIDebugEvents()
  #expect(editorModel.comfyUIDebugEvents.isEmpty)
  #expect(prompt.comfyUIDebugEvents.isEmpty)
  #expect(editorModel.comfyUIDebugImages.isEmpty)
  #expect(prompt.comfyUIDebugImages.isEmpty)
}

@MainActor
@Test func generationPathLogsBeforeDetailsAreOpened() {
  let document = ProjectDocument()

  document.startGenerationFromUI(prompt: "  ")

  #expect(document.editorModel.comfyUIDebugEvents.map(\.stage).contains("Preflight"))
  #expect(document.editorModel.comfyUIDebugEvents.map(\.stage).contains("Rejected"))
}

@MainActor
@Test func comfyUIDebugTranscriptIsAlwaysCollectedAndBounded() {
  let model = EditorModel()
  for index in 0..<510 {
    model.appendComfyUIDebugEvent(
      ComfyUIDebugEvent(stage: "Event", message: "entry \(index)"))
  }
  #expect(model.comfyUIDebugEvents.count == 500)
  #expect(model.comfyUIDebugEvents.last?.message == "entry 509")

  for index in 0..<14 {
    model.appendComfyUIDebugImage(
      ComfyUIDebugImage(label: "image \(index)", imageData: Data([UInt8(index)])))
  }
  #expect(model.comfyUIDebugImages.count == 12)
  #expect(model.comfyUIDebugImages.first?.label == "image 2")
}

import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
private func documentWithUndoManager() -> ProjectDocument {
  let document = ProjectDocument()
  // In the app the run loop closes one undo group per event. A test has no run
  // loop, so grouping is taken over explicitly by `edit(_:_:)` below and each
  // recorded edit still undoes on its own.
  let undoManager = UndoManager()
  undoManager.groupsByEvent = false
  document.undoManager = undoManager
  return document
}

/// Runs one user edit inside its own undo group, standing in for the event
/// group the run loop would close in the running app.
@MainActor
private func edit(_ document: ProjectDocument, _ body: () -> Void) {
  document.undoManager?.beginUndoGrouping()
  body()
  document.undoManager?.endUndoGrouping()
}

@MainActor
private func setBrightness(_ document: ProjectDocument, _ value: Double) {
  edit(document) {
    var post = document.editorModel.recipe.postProcessing
    post.brightness = value
    document.perform(.setPostProcessing(post), interactive: false)
  }
}

@MainActor
@Test func everyEditBecomesOneNamedHistoryStep() {
  let document = documentWithUndoManager()
  setBrightness(document, 0.2)
  setBrightness(document, 0.4)

  let history = document.editorModel.history
  #expect(history.steps.map(\.name) == ["New Project", "Adjust Image", "Adjust Image"])
  #expect(history.currentIndex == 2)
}

@MainActor
@Test func undoAndRedoMoveThroughTheSameHistoryThePanelShows() {
  let document = documentWithUndoManager()
  setBrightness(document, 0.2)
  setBrightness(document, 0.4)
  let top = document.editorModel.history.currentStepID

  document.undoManager?.undo()
  #expect(document.editorModel.recipe.postProcessing.brightness == 0.2)
  #expect(document.editorModel.history.isAhead(top))

  document.undoManager?.redo()
  #expect(document.editorModel.recipe.postProcessing.brightness == 0.4)
  #expect(document.editorModel.history.currentStepID == top)
}

@MainActor
@Test func clickingAHistoryEntryReturnsToItAndIsItselfUndoable() {
  let document = documentWithUndoManager()
  setBrightness(document, 0.2)
  let middle = document.editorModel.history.currentStepID
  setBrightness(document, 0.4)

  edit(document) { document.returnToHistoryStep(middle) }
  #expect(document.editorModel.recipe.postProcessing.brightness == 0.2)

  document.undoManager?.undo()
  #expect(document.editorModel.recipe.postProcessing.brightness == 0.4)
}

@MainActor
@Test func editingAfterUndoingDiscardsTheForwardBranch() {
  let document = documentWithUndoManager()
  setBrightness(document, 0.2)
  setBrightness(document, 0.4)
  let discarded = document.editorModel.history.currentStepID

  document.undoManager?.undo()
  setBrightness(document, 0.9)

  #expect(document.editorModel.history.contains(discarded) == false)
  #expect(document.editorModel.history.canRedo == false)
  #expect(document.editorModel.history.steps.count == 3)
}

@MainActor
@Test func restoringASnapshotIsOneUndoableStep() {
  let document = documentWithUndoManager()
  setBrightness(document, 0.6)
  let pinned = document.takeSnapshot(named: "Warm")
  setBrightness(document, -0.3)

  edit(document) { document.restoreSnapshot(pinned) }
  #expect(document.editorModel.recipe.postProcessing.brightness == 0.6)
  #expect(document.editorModel.history.currentStep.name == "Restore “Warm”")

  document.undoManager?.undo()
  #expect(document.editorModel.recipe.postProcessing.brightness == -0.3)
}

@MainActor
@Test func aDragRecordsOneStepRatherThanOnePerEvent() {
  let document = documentWithUndoManager()
  let before = document.editorModel.history.steps.count

  edit(document) {
    document.beginEditGesture()
    for step in 1...5 {
      var post = document.editorModel.recipe.postProcessing
      post.brightness = Double(step) / 10
      document.perform(.setPostProcessing(post), interactive: false)
    }
    document.endEditGesture(actionName: "Brightness")
  }

  #expect(document.editorModel.history.steps.count == before + 1)
  #expect(document.editorModel.history.currentStep.name == "Brightness")

  document.undoManager?.undo()
  #expect(document.editorModel.recipe.postProcessing.brightness == 0)
}

@MainActor
@Test func rapidColorEditsCoalesceAndSnapshotsRestoreTheWholeLayerRecipe() throws {
  let document = documentWithUndoManager()
  let source = SourceReference(
    originalFilename: "color.dng",
    linkedPath: "/frames/color.dng",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 2048, modificationDate: nil)
  )
  document.editorModel.updateRecipeInPlace(ProjectRecipe(source: source))
  let before = document.editorModel.history.steps.count
  let renderRevision = document.currentRenderRevision

  edit(document) {
    document.beginEditGesture()
    for value in stride(from: -20.0, through: 40.0, by: 10) {
      var adjustments = document.editorModel.recipe.layerStack.layer(id: .rawBackground)!
        .adjustments
      adjustments.colorMixer[.orange].saturation = value
      document.perform(
        .setLayerAdjustments(
          .rawBackground, adjustments, actionName: "Adjust Orange Saturation"),
        interactive: true)
    }
    document.endEditGesture(actionName: "Adjust Orange Saturation")
  }

  #expect(document.editorModel.history.steps.count == before + 1)
  #expect(document.currentRenderRevision > renderRevision)
  #expect(document.editorModel.history.currentStep.name == "Adjust Orange Saturation")
  #expect(
    document.editorModel.recipe.layerStack.layer(id: .rawBackground)?
      .adjustments.colorMixer[.orange].saturation == 40)

  let snapshot = document.takeSnapshot(named: "Orange mix")
  edit(document) {
    var adjustments = document.editorModel.recipe.layerStack.layer(id: .rawBackground)!.adjustments
    adjustments.colorGrading.highlights = ColorGradingWheel(
      hue: 42, saturation: 30, luminance: 8)
    document.perform(
      .setLayerAdjustments(
        .rawBackground, adjustments, actionName: "Adjust Highlights Grading"),
      interactive: false)
  }
  edit(document) { document.restoreSnapshot(snapshot) }

  let restored = try #require(
    document.editorModel.recipe.layerStack.layer(id: .rawBackground)?.adjustments)
  #expect(restored.colorMixer[.orange].saturation == 40)
  #expect(restored.colorGrading == .neutral)
  #expect(document.editorModel.history.currentStep.name == "Restore “Orange mix”")
}

@MainActor
@Test func decoderMetadataUpdatesTheCurrentStepInsteadOfAddingOne() {
  let document = documentWithUndoManager()
  setBrightness(document, 0.2)
  let count = document.editorModel.history.steps.count

  var updated = document.editorModel.recipe
  updated.rawDevelopment.decoderVersion = "CIRAWDecoderVersion9"
  document.editorModel.updateRecipeInPlace(updated)

  #expect(document.editorModel.history.steps.count == count)
  #expect(
    document.editorModel.history.currentStep.recipe.rawDevelopment.decoderVersion
      == "CIRAWDecoderVersion9"
  )
}

@MainActor
@Test func layerMaskPaintingIsOneUndoableRoundTrippableStepAndCancelIsNoStep() throws {
  let document = documentWithUndoManager()
  let layerID = ProjectLayerID(rawValue: "mask-history-layer")
  let mask = MaskRecipe.layerMask(revealsLayer: false, id: MaskID(rawValue: "mask-history"))
  var recipe = document.editorModel.recipe
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  recipe.layerStack = recipe.layerStack.adding(
    ProjectLayer.paint(PaintLayerRecipe(), id: layerID))
  recipe = recipe.applying(.setLayerMask(layerID, mask))
  document.editorModel.replaceRecipe(recipe, historyName: "Test")
  document.editorModel.setPaintTarget(.layerMask(layerID, mask.id))
  document.editorModel.setActiveTool(.brush)
  let baseline = document.editorModel.recipe
  let baselineCount = document.editorModel.history.steps.count

  document.beginBrushStroke(with: BrushSample(x: 10, y: 10))
  document.appendBrushSamples([BrushSample(x: 20, y: 20, sequence: 1)])
  document.cancelBrushStroke()
  #expect(document.editorModel.recipe == baseline)
  #expect(document.editorModel.history.steps.count == baselineCount)

  edit(document) {
    document.beginBrushStroke(with: BrushSample(x: 10, y: 10))
    document.appendBrushSamples([BrushSample(x: 20, y: 20, sequence: 1)])
    document.commitBrushStroke()
  }
  #expect(document.editorModel.history.steps.count == baselineCount + 1)
  #expect(document.editorModel.history.currentStep.name == "Paint Layer Mask")
  #expect(
    document.editorModel.recipe.layerStack.layer(id: layerID)?
      .layerMask?.strokeSurface?.strokes.count == 1)
  #expect(document.editorModel.recipe.layerStack.layer(id: layerID)?.paintLayer?.surface.strokes.isEmpty == true)

  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()
  #expect(reopened.editorModel.recipe == document.editorModel.recipe)

  document.undoManager?.undo()
  #expect(document.editorModel.recipe == baseline)
}

@MainActor
@Test func imageEraserCreatesAndTargetsItsMaskAsOneUndoableStroke() throws {
  let document = documentWithUndoManager()
  let layerID = ProjectLayerID(rawValue: "eraser-image")
  let image = ImageLayer(
    source: SourceReference(
      originalFilename: "eraser.png",
      linkedPath: "/Pictures/eraser.png",
      securityScopedBookmark: nil,
      fingerprint: SourceFingerprint(byteLength: 1024, modificationDate: nil)
    ),
    frame: LayerFrame(x: 0, y: 0, width: 64, height: 64),
    naturalWidth: 64,
    naturalHeight: 64
  )
  var recipe = document.editorModel.recipe
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  recipe.layerStack = recipe.layerStack.adding(.image(image, id: layerID))
  recipe.selection = .selecting(.rectangle(.full))
  document.editorModel.replaceRecipe(recipe, historyName: "Test")
  document.editorModel.setActiveTool(.eraser)
  document.editorModel.setPaintTarget(.layerPixels(layerID))
  let baseline = document.editorModel.recipe
  let baselineCount = document.editorModel.history.steps.count

  document.beginBrushStroke(with: BrushSample(x: 10, y: 10))
  document.cancelBrushStroke()
  #expect(document.editorModel.recipe == baseline)
  #expect(document.editorModel.history.steps.count == baselineCount)

  edit(document) {
    document.beginBrushStroke(with: BrushSample(x: 10, y: 10))
    document.appendBrushSamples([BrushSample(x: 20, y: 20, sequence: 1)])
    document.commitBrushStroke()
  }
  #expect(document.editorModel.history.steps.count == baselineCount + 1)
  #expect(document.editorModel.history.currentStep.name == "Erase Layer Mask")
  let layer = try #require(document.editorModel.recipe.layerStack.layer(id: layerID))
  let mask = try #require(layer.layerMask)
  #expect(layer.imageLayer == image)
  #expect(mask.strokeSurface?.initialCoverage == 1)
  #expect(mask.strokeSurface?.strokes.count == 1)
  #expect(mask.strokeSurface?.strokes.first?.mode == .erase)
  #expect(mask.strokeSurface?.strokes.first?.selectionClip == recipe.selection)
  #expect(document.editorModel.resolvedPaintTarget == .layerMask(layerID, mask.id))

  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()
  #expect(reopened.editorModel.recipe == document.editorModel.recipe)

  document.undoManager?.undo()
  #expect(document.editorModel.recipe == baseline)
  #expect(document.editorModel.resolvedPaintTarget == .layerPixels(layerID))
}

@MainActor
@Test func imageEraserReusesAnExistingMaskAndLeavesUnwritableImagesAlone() throws {
  let document = documentWithUndoManager()
  let layerID = ProjectLayerID(rawValue: "masked-image")
  let mask = MaskRecipe.layerMask(id: MaskID(rawValue: "existing-mask"))
  let image = ImageLayer(
    source: SourceReference(
      originalFilename: "masked.png",
      linkedPath: "/Pictures/masked.png",
      securityScopedBookmark: nil,
      fingerprint: SourceFingerprint(byteLength: 1024, modificationDate: nil)
    ),
    frame: LayerFrame(x: 0, y: 0, width: 64, height: 64),
    naturalWidth: 64,
    naturalHeight: 64
  )
  var recipe = document.editorModel.recipe
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  recipe.layerStack = recipe.layerStack.adding(
    ProjectLayer(id: layerID, name: "Masked", content: .image(image), layerMask: mask))
  document.editorModel.replaceRecipe(recipe, historyName: "Test")
  document.editorModel.setActiveTool(.eraser)
  document.editorModel.setPaintTarget(.layerPixels(layerID))

  edit(document) {
    document.beginBrushStroke(with: BrushSample(x: 10, y: 10))
    document.commitBrushStroke()
  }
  #expect(document.editorModel.recipe.layerStack.layer(id: layerID)?.layerMask?.id == mask.id)
  #expect(
    document.editorModel.recipe.layerStack.layer(id: layerID)?
      .layerMask?.strokeSurface?.strokes.count == 1)
  #expect(document.editorModel.resolvedPaintTarget == .layerMask(layerID, mask.id))

  var inverted = recipe
  inverted.layerStack.updateLayer(id: layerID) { $0.layerMask?.isInverted = true }
  document.editorModel.replaceRecipe(inverted, historyName: "Inverted Mask")
  document.editorModel.setPaintTarget(.layerPixels(layerID))
  edit(document) {
    document.beginBrushStroke(with: BrushSample(x: 10, y: 10))
    document.commitBrushStroke()
  }
  #expect(
    document.editorModel.recipe.layerStack.layer(id: layerID)?
      .layerMask?.strokeSurface?.strokes.last?.mode == .paint)
  #expect(document.editorModel.resolvedPaintTarget == .layerPixels(layerID))

  var disabled = recipe
  disabled.layerStack.updateLayer(id: layerID) { $0.layerMask?.isEnabled = false }
  document.editorModel.replaceRecipe(disabled, historyName: "Disabled Mask")
  document.editorModel.setPaintTarget(.layerPixels(layerID))
  document.beginBrushStroke(with: BrushSample(x: 10, y: 10))
  document.commitBrushStroke()
  #expect(document.editorModel.recipe == disabled)

  var locked = recipe
  locked.layerStack.updateLayer(id: layerID) { $0.isLocked = true }
  document.editorModel.replaceRecipe(locked, historyName: "Locked Image")
  document.editorModel.setPaintTarget(.layerPixels(layerID))
  document.beginBrushStroke(with: BrushSample(x: 10, y: 10))
  document.commitBrushStroke()
  #expect(document.editorModel.recipe == locked)
}

@MainActor
@Test func addingAnEmptyPaintLayerIsOneNamedUndoableStepAndMakesItThePixelTarget() throws {
  let document = documentWithUndoManager()
  let layer = ProjectLayer.paint(id: ProjectLayerID(rawValue: "blank-paint"))
  let baseline = document.editorModel.recipe

  edit(document) {
    document.perform(.addLayer(layer), interactive: false)
    document.editorModel.setPaintTarget(.layerPixels(layer.id))
  }

  let added = try #require(document.editorModel.recipe.layerStack.layer(id: layer.id))
  #expect(added.paintLayer?.surface.strokes.isEmpty == true)
  #expect(document.editorModel.recipe.layerStack.activeLayerID == layer.id)
  #expect(document.editorModel.resolvedPaintTarget == .layerPixels(layer.id))
  #expect(document.editorModel.history.currentStep.name == "Add Paint Layer")

  document.undoManager?.undo()
  #expect(document.editorModel.recipe == baseline)
  #expect(document.editorModel.recipe.layerStack.layer(id: layer.id) == nil)
}

/// A preset is one action, so it is one history step named after itself and one
/// undo — not four slider changes that happen to land together.
@MainActor
@Test func applyingAPresetIsOneUndoableStepNamedAfterIt() {
  let document = documentWithUndoManager()
  let source = SourceReference(
    originalFilename: "preset.dng",
    linkedPath: "/frames/preset.dng",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 1024, modificationDate: nil)
  )
  let rawDevelopment = RawDevelopmentRecipe(
    parameters: RawParameters(),
    capturedDefaults: RawParameters(),
    capabilities: RawCapabilities(contrast: true, localToneMap: true)
  )
  var seeded = ProjectRecipe(source: source, rawDevelopment: rawDevelopment)
  seeded.layerStack.canvas = document.editorModel.recipe.layerStack.canvas
  document.editorModel.updateRecipeInPlace(seeded)
  let count = document.editorModel.history.steps.count

  edit(document) {
    document.perform(
      .applyRawLayerPreset(.rawBackground, RawPresetCatalog.boost), interactive: false)
  }

  #expect(document.editorModel.history.steps.count == count + 1)
  #expect(document.editorModel.history.currentStep.name == "Apply Preset: Boost")
  #expect(
    document.editorModel.recipe.layerStack.layer(id: .rawBackground)?
      .developedRawLayer?.rawDevelopment.parameters?.contrast == 0.35
  )

  document.undoManager?.undo()
  let restored = document.editorModel.recipe.layerStack.layer(id: .rawBackground)?
    .developedRawLayer?.rawDevelopment.parameters
  #expect(restored?.contrast == 0)
  #expect(restored?.localToneMap == 0)
  #expect(restored?.boostShadowAmount == 1)
}

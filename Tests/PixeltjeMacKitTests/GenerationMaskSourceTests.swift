import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func automaticGenerationMaskPrefersSelectionThenActiveLayerMaskThenTransparency() {
  let layerID = ProjectLayerID(rawValue: "masked")
  let layerMask = MaskRecipe.layerMask(
    revealsLayer: true, id: MaskID(rawValue: "visibility"))
  var layer = ProjectLayer.paint(PaintLayerRecipe(), id: layerID)
  layer.layerMask = layerMask
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layerID)
  let model = EditorModel(recipe: recipe)

  #expect(model.generationMaskSource == .automatic)
  #expect(model.resolvedGenerationMaskSource == .layerMask(layerID, layerMask.id))
  #expect(model.generationMaskSourcePresentation.compactLabel.contains("Layer Mask"))

  var selected = recipe
  selected.selection = .selectingAll
  model.recordEdit(selected, name: "Select All")
  #expect(model.resolvedGenerationMaskSource == .documentSelection)

  selected.selection = nil
  selected.layerStack.updateLayer(id: layerID) { $0.layerMask = nil }
  model.recordEdit(selected, name: "Remove Layer Mask")
  #expect(model.resolvedGenerationMaskSource == .transparentPixels)
}

@MainActor
@Test func automaticGenerationMaskDoesNotBroadenAnInvalidDocumentSelection() {
  let layerID = ProjectLayerID(rawValue: "masked")
  var layer = ProjectLayer.paint(PaintLayerRecipe(), id: layerID)
  layer.layerMask = .layerMask(revealsLayer: true)
  var invalidSelection = MaskRecipe.selectingAll
  invalidSelection.isEnabled = false
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layerID)
  recipe.selection = invalidSelection
  let model = EditorModel(recipe: recipe)

  #expect(model.resolvedGenerationMaskSource == .documentSelection)
  #expect(model.generationMaskSourcePresentation.unavailableReason?.contains("disabled") == true)
}

@MainActor
@Test func concreteGenerationMaskTracksItsPrimaryLayerAndMaskIdentity() {
  let firstID = ProjectLayerID(rawValue: "first")
  let secondID = ProjectLayerID(rawValue: "second")
  let maskID = MaskID(rawValue: "first-layer-mask")
  var first = ProjectLayer.paint(PaintLayerRecipe(), id: firstID)
  first.layerMask = .layerMask(revealsLayer: true, id: maskID)
  let second = ProjectLayer.paint(PaintLayerRecipe(), id: secondID)
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [first, second], activeLayerID: firstID)
  let model = EditorModel(recipe: recipe)

  model.setGenerationMaskSource(.layerMask(firstID, maskID))
  var disabled = model.recipe
  disabled.layerStack.updateLayer(id: firstID) { $0.layerMask?.isEnabled = false }
  model.recordEdit(disabled, name: "Disable Layer Mask")
  #expect(model.generationMaskSource == .layerMask(firstID, maskID))
  #expect(model.resolvedGenerationMaskSource == nil)

  model.setLayerSelection([secondID])
  #expect(model.generationMaskSource == .automatic)
}

@MainActor
@Test func generationMaskPickerNamesLocalMasksAndReportsAvailability() throws {
  let layerID = ProjectLayerID(rawValue: "portrait")
  let face = MaskRecipe.selecting(.ellipse(.full), feather: 4)
  var disabled = MaskRecipe.selectingAll
  disabled.name = "Background"
  disabled.isEnabled = false
  var namedFace = face
  namedFace.name = "Face"
  var layer = ProjectLayer.paint(PaintLayerRecipe(), id: layerID)
  layer.masks = [namedFace, disabled]
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layerID)
  let model = EditorModel(recipe: recipe)

  let faceOption = try #require(
    model.generationMaskSourceOptions.first {
      $0.source == .localMask(layerID, namedFace.id)
    })
  #expect(faceOption.label == "Face — Paint Layer")
  #expect(faceOption.isAvailable)
  let disabledOption = try #require(
    model.generationMaskSourceOptions.first {
      $0.source == .localMask(layerID, disabled.id)
    })
  #expect(!disabledOption.isAvailable)
  #expect(disabledOption.unavailableReason?.contains("disabled") == true)
}

@MainActor
@Test func deletingAConcreteLocalGenerationMaskReturnsToAutomatic() {
  let layerID = ProjectLayerID(rawValue: "paint")
  let localMask = MaskRecipe.selectingAll
  var layer = ProjectLayer.paint(PaintLayerRecipe(), id: layerID)
  layer.masks = [localMask]
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layerID)
  let model = EditorModel(recipe: recipe)

  model.setGenerationMaskSource(.localMask(layerID, localMask.id))
  var removed = recipe
  removed.layerStack.updateLayer(id: layerID) { $0.masks = [] }
  model.recordEdit(removed, name: "Delete Mask")

  #expect(model.generationMaskSource == .automatic)
}

@MainActor
@Test func restoredLegacyGenerationMaskRemainsRepresentableInPicker() {
  let model = EditorModel()

  model.useLegacyGenerationMaskSourceForRestoredHistory()

  #expect(model.generationMaskSource == .legacySelectionOrEntireOutput)
  #expect(
    model.generationMaskSourceOptions.contains {
      $0.source == .legacySelectionOrEntireOutput
    })
}

@MainActor
@Test func promptBoxReceivesLiveRequestedAndResolvedMaskSource() {
  let layerID = ProjectLayerID(rawValue: "masked")
  let maskID = MaskID(rawValue: "mask")
  var layer = ProjectLayer.paint(PaintLayerRecipe(), id: layerID)
  layer.layerMask = .layerMask(revealsLayer: true, id: maskID)
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layerID)
  let editorModel = EditorModel(recipe: recipe)
  let controller = CanvasViewController(model: editorModel) { _ in }

  #expect(controller.promptBoxModel.maskSourceTitle.contains("Layer Mask"))
  editorModel.selectComfyUIWorkflow("flux2-klein-inpaint-base")
  editorModel.setGenerationMaskSource(.entireOutput)
  #expect(controller.promptBoxModel.maskSourceTitle == "Mask: Entire Output")
  #expect(controller.promptBoxModel.primaryActionHelp.contains("Entire Output"))
}

@MainActor
@Test func promptBoxCanChooseTransparentPixelsAsTheMaskSource() {
  let editorModel = EditorModel()
  editorModel.selectComfyUIWorkflow("flux2-klein-inpaint-base")
  let controller = CanvasViewController(
    model: editorModel,
    send: { _ in },
    selectGenerationMaskSource: { editorModel.setGenerationMaskSource($0) })

  #expect(
    controller.promptBoxModel.generationMaskSourceOptions.contains {
      $0.source == .transparentPixels && $0.isAvailable
    })

  controller.promptBoxModel.selectGenerationMaskSource(.transparentPixels)

  #expect(editorModel.generationMaskSource == .transparentPixels)
  #expect(controller.promptBoxModel.maskSourceTitle == "Mask: Transparent Pixels")
}

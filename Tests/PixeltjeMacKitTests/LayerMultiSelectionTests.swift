import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func commandExtendingSelectionKeepsFirstLayerPrimaryWithoutHistory() throws {
  let first = ProjectLayer(
    id: ProjectLayerID(rawValue: "first"), name: "First", content: .vector(VectorLayer()))
  let second = ProjectLayer(
    id: ProjectLayerID(rawValue: "second"), name: "Second", content: .vector(VectorLayer()))
  let third = ProjectLayer(
    id: ProjectLayerID(rawValue: "third"), name: "Third", content: .vector(VectorLayer()))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [first, second, third], activeLayerID: first.id)
  let model = EditorModel(recipe: recipe)
  let historyCount = model.history.steps.count

  model.setLayerSelection([first.id, second.id])
  #expect(model.recipe.layerStack.activeLayerID == first.id)
  model.setLayerSelection([first.id, second.id, third.id])
  #expect(model.recipe.layerStack.activeLayerID == first.id)
  #expect(model.selectedLayerIDs == [first.id, second.id, third.id])
  #expect(model.history.steps.count == historyCount)

  model.setLayerSelection([second.id, third.id])
  #expect(model.recipe.layerStack.activeLayerID == second.id)
  #expect(model.history.steps.count == historyCount)

  model.setLayerSelection([third.id])
  #expect(model.recipe.layerStack.activeLayerID == third.id)
  #expect(model.selectedLayerIDs == [third.id])
}

@MainActor
@Test func changingThePrimaryLayerRefreshesSamplingWithoutCreatingHistory() {
  let first = ProjectLayer(
    id: ProjectLayerID(rawValue: "first"), name: "First", content: .vector(VectorLayer()))
  let second = ProjectLayer(
    id: ProjectLayerID(rawValue: "second"), name: "Second", content: .vector(VectorLayer()))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [first, second], activeLayerID: first.id)
  let document = ProjectDocument()
  document.editorModel.replaceRecipe(recipe, historyName: "Selection Test")
  let revision = document.currentRenderRevision
  let historyCount = document.editorModel.history.steps.count

  document.selectLayers([second.id])

  #expect(document.currentRenderRevision == revision + 1)
  #expect(document.editorModel.history.steps.count == historyCount)
  #expect(document.editorModel.recipe.layerStack.activeLayerID == second.id)
}

@MainActor
@Test func redundantLayerSelectionAfterInvertingMaskKeepsMaskPaintTarget() {
  let layerID = ProjectLayerID(rawValue: "masked-image")
  let mask = MaskRecipe.layerMask(
    revealsLayer: false,
    id: MaskID(rawValue: "paint-target"))
  let layer = ProjectLayer.paint(PaintLayerRecipe(), id: layerID)
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layerID)
  recipe = recipe.applying(.setLayerMask(layerID, mask))
  let model = EditorModel(recipe: recipe)
  model.setPaintTarget(.layerMask(layerID, mask.id))

  model.recordEdit(
    recipe.applying(.setLayerMaskInverted(layerID, true)),
    name: "Invert Layer Mask")
  // SwiftUI's List selection binding can send the unchanged selection again
  // when the recipe refreshes. That is not a request to retarget the Brush to
  // pixels; only an actual layer-selection change should do that.
  model.setLayerSelection([layerID])

  #expect(model.recipe.layerStack.layer(id: layerID)?.layerMask?.isInverted == true)
  #expect(model.resolvedPaintTarget == .layerMask(layerID, mask.id))
}

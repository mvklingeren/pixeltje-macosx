import AppKit
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@Test func penKeepsOnlyDrawingAndAnchorEditingModes() {
  #expect(VectorEditMode.allCases == [.draw, .direct])
}

private func selectionFixture() -> (
  stack: LayerStackRecipe, path: VectorPath, shape: VectorShape,
  pathLayerID: ProjectLayerID, shapeLayerID: ProjectLayerID
) {
  let path = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.2, y: 0.2)),
      VectorAnchor(position: VectorPoint(x: 0.6, y: 0.2)),
      VectorAnchor(position: VectorPoint(x: 0.6, y: 0.6)),
      VectorAnchor(position: VectorPoint(x: 0.2, y: 0.6)),
    ],
    isClosed: true,
    stroke: nil,
    fill: VectorFillStyle(color: .white))
  let shape = VectorShape(
    kind: .rectangle(corners: .none),
    frame: VectorBounds(minX: 0.3, minY: 0.3, maxX: 0.7, maxY: 0.7),
    stroke: nil,
    fill: VectorFillStyle(color: .white))
  let pathLayer = ProjectLayer(
    name: "Path", content: .vector(VectorLayer(objects: [.path(path)])))
  let shapeLayer = ProjectLayer(
    name: "Shape", isLocked: true,
    content: .vector(VectorLayer(objects: [.shape(shape)])))
  return (
    LayerStackRecipe(
      layers: [shapeLayer, pathLayer, .canvasBase(CanvasRecipe(width: 100, height: 100))],
      activeLayerID: pathLayer.id),
    path, shape, pathLayer.id, shapeLayer.id)
}

@Test func selectMovePicksTopmostVisibleObjectAcrossVectorLayers() {
  var fixture = selectionFixture()
  let point = VectorPoint(x: 0.4, y: 0.4)
  let picked = VectorObjectPicker.pick(
    in: fixture.stack, at: point, pixelWidth: 100, pixelHeight: 100, tolerance: 2)
  #expect(picked?.layerID == fixture.shapeLayerID)
  #expect(picked?.objectID == fixture.shape.id)

  fixture.stack.updateLayer(id: fixture.shapeLayerID) { $0.isEnabled = false }
  let beneath = VectorObjectPicker.pick(
    in: fixture.stack, at: point, pixelWidth: 100, pixelHeight: 100, tolerance: 2)
  #expect(beneath?.layerID == fixture.pathLayerID)
  #expect(beneath?.objectID == fixture.path.id)
}

@Test func selectMoveMapsAnAffineLayerBeforeHitTestingItsShape() {
  var fixture = selectionFixture()
  var transform = LayerTransform(
    referenceRect: LayerFrame(x: 30, y: 30, width: 40, height: 40))
  transform.position = PixelPoint(x: 75, y: 65)
  transform.rotationDegrees = 30
  transform.scaleX = 1.3
  fixture.stack.updateLayer(id: fixture.shapeLayerID) { $0.transform = transform }

  let canvasCenter = transform.applyingAffine(to: PixelPoint(x: 50, y: 50))
  let canvasPoint = VectorPoint(x: canvasCenter.x / 100, y: canvasCenter.y / 100)
  let picked = VectorObjectPicker.pick(
    in: fixture.stack, at: canvasPoint,
    pixelWidth: 100, pixelHeight: 100, tolerance: 2)
  #expect(picked?.objectID == fixture.shape.id)
  let local = VectorObjectPicker.localPoint(
    in: fixture.stack, layerID: fixture.shapeLayerID, at: canvasPoint,
    pixelWidth: 100, pixelHeight: 100)
  #expect(abs((local?.x ?? 0) - 0.5) < 0.000_001)
  #expect(abs((local?.y ?? 0) - 0.5) < 0.000_001)
}

@Test func selectMovePicksAPerspectiveTransformedShape() {
  var fixture = selectionFixture()
  var transform = LayerTransform(
    referenceRect: LayerFrame(x: 30, y: 30, width: 40, height: 40))
  transform.perspective = PerspectiveCorners(
    bottomLeft: PixelPoint(x: 0.4, y: 0),
    bottomRight: PixelPoint(x: 0.4, y: 0),
    topRight: PixelPoint(x: 0.65, y: 0),
    topLeft: PixelPoint(x: 0.15, y: 0))
  fixture.stack.updateLayer(id: fixture.shapeLayerID) { $0.transform = transform }

  let point = VectorPoint(x: 0.9, y: 0.5)
  let picked = VectorObjectPicker.pick(
    in: fixture.stack, at: point,
    pixelWidth: 100, pixelHeight: 100, tolerance: 2)
  #expect(picked?.objectID == fixture.shape.id)
  let local = VectorObjectPicker.localPoint(
    in: fixture.stack, layerID: fixture.shapeLayerID, at: point,
    pixelWidth: 100, pixelHeight: 100)
  #expect((local?.x ?? 0) > 0.3 && (local?.x ?? 1) < 0.7)
  #expect((local?.y ?? 0) > 0.3 && (local?.y ?? 1) < 0.7)
}

@Test func selectedPenVerticesFollowTheRenderedLayerTransform() {
  var fixture = selectionFixture()
  var transform = LayerTransform(
    referenceRect: LayerFrame(x: 20, y: 20, width: 40, height: 40))
  transform.position = PixelPoint(x: 65, y: 55)
  transform.rotationDegrees = 20
  transform.perspective = PerspectiveCorners(
    bottomLeft: PixelPoint(x: 0.1, y: 0),
    bottomRight: PixelPoint(x: 0.2, y: 0),
    topRight: PixelPoint(x: 0.1, y: 0.1),
    topLeft: PixelPoint(x: 0, y: 0.1))
  fixture.stack.updateLayer(id: fixture.pathLayerID) { $0.transform = transform }

  for anchor in fixture.path.anchors {
    let canvas = VectorObjectPicker.canvasPoint(
      anchor.position, in: fixture.stack, layerID: fixture.pathLayerID,
      pixelWidth: 100, pixelHeight: 100)
    let mapped = VectorObjectPicker.localPoint(
      in: fixture.stack, layerID: fixture.pathLayerID,
      at: canvas ?? .zero, pixelWidth: 100, pixelHeight: 100)
    #expect(canvas != nil)
    #expect(abs((mapped?.x ?? 0) - anchor.position.x) < 0.000_001)
    #expect(abs((mapped?.y ?? 0) - anchor.position.y) < 0.000_001)
  }
  let first = fixture.path.anchors[0].position
  let transformed = VectorObjectPicker.canvasPoint(
    first, in: fixture.stack, layerID: fixture.pathLayerID,
    pixelWidth: 100, pixelHeight: 100)
  #expect((transformed?.distance(to: first) ?? 0) > 0.1)
}

@MainActor
@Test func newlyDrawnShapeStaysSelectedWhenSwitchingToSelectMove() throws {
  let document = ProjectDocument()
  var recipe = document.editorModel.recipe
  recipe.layerStack.canvas = CanvasRecipe(width: 100, height: 100)
  document.editorModel.replaceRecipe(recipe)
  document.editorModel.setActiveTool(.shape)
  document.commitShape(
    from: VectorPoint(x: 0.2, y: 0.2),
    to: VectorPoint(x: 0.6, y: 0.6), constrained: false)
  let id = try #require(document.editorModel.selectedVectorObjectIDs.first)

  document.editorModel.setActiveTool(.move)
  #expect(document.editorModel.selectedVectorObjectIDs == [id])
  #expect(document.editorModel.activeVectorLayer?.vector.object(id: id)?.shape != nil)
}

@MainActor
@Test func selectMoveCommandsTargetObjectsWithoutCreatingPixelSelection() {
  let fixture = selectionFixture()
  let document = ProjectDocument()
  var recipe = document.editorModel.recipe
  recipe.layerStack = fixture.stack
  document.editorModel.replaceRecipe(recipe)
  document.editorModel.setActiveTool(.move)
  let controller = ProjectWindowController(projectDocument: document)

  controller.selectAll(nil)
  #expect(document.editorModel.selectedVectorObjectIDs == [fixture.path.id])
  #expect(document.editorModel.recipe.selection == nil)
  controller.deselect(nil)
  #expect(document.editorModel.selectedVectorObjectIDs.isEmpty)

  var withPixelSelection = document.editorModel.recipe
  withPixelSelection.selection = .selectingAll
  document.editorModel.updateRecipeInPlace(withPixelSelection)
  document.editorModel.setSelectedVectorObjects([fixture.path.id])
  controller.deselect(nil)
  #expect(document.editorModel.recipe.selection == nil)
  #expect(document.editorModel.selectedVectorObjectIDs == [fixture.path.id])
  controller.deselect(nil)
  #expect(document.editorModel.selectedVectorObjectIDs.isEmpty)

  document.selectLayers([fixture.shapeLayerID])
  document.editorModel.setSelectedVectorObjects([fixture.shape.id])
  #expect(!document.canDeleteVectorObjects)
  document.editorModel.setSelectedVectorObjects([])
  document.selectLayers([fixture.pathLayerID])
  document.editorModel.setSelectedVectorObjects([fixture.path.id])
  let deleteItem = NSMenuItem(
    title: "Delete", action: #selector(ProjectWindowController.delete(_:)),
    keyEquivalent: "\u{8}")
  #expect(controller.validateMenuItem(deleteItem))
  controller.delete(nil)
  #expect(document.editorModel.activeVectorLayer?.vector.object(id: fixture.path.id) == nil)
}

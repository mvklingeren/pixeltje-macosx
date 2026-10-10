import Foundation
import PixeltjeMacDomain
import Testing

/// A square canvas keeps the arithmetic in these tests readable: alignment and
/// distribution are measured in normalized coordinates, and a square image
/// makes those match pixel proportions.
private let pixelWidth = 100.0
private let pixelHeight = 100.0

private func box(
  _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double, name: String = "Shape"
) -> VectorObject {
  .shape(
    VectorShape(
      name: name,
      kind: .rectangle(corners: .none),
      frame: VectorBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
      stroke: nil,
      fill: VectorFillStyle(color: .white)
    ))
}

private func extent(
  _ layer: VectorLayer, _ id: UUID
) -> VectorBounds? {
  layer.object(id: id)?.boundingBox(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
}

@Test func aligningMovesObjectsWithoutResizingThem() throws {
  let first = box(0.0, 0.0, 0.2, 0.2, name: "First")
  let second = box(0.5, 0.6, 0.9, 0.7, name: "Second")
  let layer = VectorLayer(objects: [first, second])

  let aligned = layer.aligning(
    ids: [first.id, second.id],
    to: .left,
    reference: .selection,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight
  )
  let firstBox = try #require(extent(aligned, first.id))
  let secondBox = try #require(extent(aligned, second.id))
  #expect(abs(firstBox.minX - secondBox.minX) < 1e-9)
  #expect(abs(firstBox.minX) < 1e-9)
  // Sizes are untouched: alignment moves, it does not resize.
  #expect(abs(secondBox.width - 0.4) < 1e-9)
  #expect(abs(secondBox.height - 0.1) < 1e-9)
}

@Test func aligningToTheCanvasIsWhatASingleObjectNeeds() throws {
  let only = box(0.1, 0.1, 0.3, 0.3)
  let layer = VectorLayer(objects: [only])

  // Against itself, one object cannot move.
  let toSelection = layer.aligning(
    ids: [only.id], to: .right, reference: .selection,
    pixelWidth: pixelWidth, pixelHeight: pixelHeight)
  #expect(toSelection == layer)

  let toCanvas = layer.aligning(
    ids: [only.id], to: .right, reference: .canvas,
    pixelWidth: pixelWidth, pixelHeight: pixelHeight)
  let moved = try #require(extent(toCanvas, only.id))
  #expect(abs(moved.maxX - 1) < 1e-9)
  #expect(abs(moved.minY - 0.1) < 1e-9)
}

@Test func everyAlignmentEdgeLandsOnTheEdgeItNames() throws {
  let only = box(0.1, 0.2, 0.3, 0.4)
  let layer = VectorLayer(objects: [only])

  func aligned(_ alignment: VectorAlignment) throws -> VectorBounds {
    let result = layer.aligning(
      ids: [only.id], to: alignment, reference: .canvas,
      pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    return try #require(extent(result, only.id))
  }

  #expect(abs(try aligned(.left).minX) < 1e-9)
  #expect(abs(try aligned(.right).maxX - 1) < 1e-9)
  #expect(abs(try aligned(.horizontalCenter).center.x - 0.5) < 1e-9)
  #expect(abs(try aligned(.bottom).minY) < 1e-9)
  #expect(abs(try aligned(.top).maxY - 1) < 1e-9)
  #expect(abs(try aligned(.verticalMiddle).center.y - 0.5) < 1e-9)
}

@Test func distributionSpacesCentersEvenlyAndLeavesTheOutermostTwoAlone() throws {
  let left = box(0.0, 0.0, 0.1, 0.1, name: "Left")
  let middle = box(0.15, 0.0, 0.25, 0.1, name: "Middle")
  let right = box(0.9, 0.0, 1.0, 0.1, name: "Right")
  let layer = VectorLayer(objects: [left, middle, right])

  let distributed = layer.distributing(
    ids: [left.id, middle.id, right.id],
    axis: .horizontal,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight
  )
  let leftBox = try #require(extent(distributed, left.id))
  let middleBox = try #require(extent(distributed, middle.id))
  let rightBox = try #require(extent(distributed, right.id))

  // The outermost two do not move.
  #expect(abs(leftBox.center.x - 0.05) < 1e-9)
  #expect(abs(rightBox.center.x - 0.95) < 1e-9)
  #expect(abs(middleBox.center.x - 0.5) < 1e-9)
}

@Test func distributionNeedsThreeObjectsToHaveAnythingToSay() {
  let first = box(0.0, 0.0, 0.1, 0.1)
  let second = box(0.5, 0.0, 0.6, 0.1)
  let layer = VectorLayer(objects: [first, second])
  #expect(
    layer.distributing(
      ids: [first.id, second.id], axis: .horizontal,
      pixelWidth: pixelWidth, pixelHeight: pixelHeight) == layer)
}

@Test func reflectingMirrorsAboutTheSelectionRatherThanEachObject() throws {
  let left = box(0.0, 0.0, 0.2, 0.2, name: "Left")
  let right = box(0.8, 0.0, 1.0, 0.2, name: "Right")
  let layer = VectorLayer(objects: [left, right])

  let reflected = layer.reflecting(
    ids: [left.id, right.id], horizontally: true,
    pixelWidth: pixelWidth, pixelHeight: pixelHeight)
  let leftBox = try #require(extent(reflected, left.id))
  let rightBox = try #require(extent(reflected, right.id))
  // The two swap sides, which is what reflecting a group means.
  #expect(abs(leftBox.minX - 0.8) < 1e-9)
  #expect(abs(rightBox.minX) < 1e-9)
}

@Test func reflectingOneShapeKeepsItParametricAndInPlace() throws {
  let only = box(0.2, 0.2, 0.6, 0.4)
  let layer = VectorLayer(objects: [only])
  let reflected = layer.reflecting(
    ids: [only.id], horizontally: false,
    pixelWidth: pixelWidth, pixelHeight: pixelHeight)
  let shape = try #require(reflected.object(id: only.id)?.shape)
  #expect(abs(shape.frame.minX - 0.2) < 1e-9)
  #expect(abs(shape.frame.minY - 0.2) < 1e-9)
}

@Test func movingObjectsToANewLayerTakesThemOutOfTheOldOne() throws {
  let staying = box(0.0, 0.0, 0.1, 0.1, name: "Staying")
  let leaving = box(0.5, 0.5, 0.6, 0.6, name: "Leaving")
  var stack = LayerStackRecipe(
    layers: [
      ProjectLayer(
        name: "Vector Layer",
        isEnabled: true,
        isLocked: false,
        zOrder: 0,
        content: .vector(VectorLayer(objects: [staying, leaving])))
    ])
  stack.canvas = CanvasRecipe(width: 100, height: 100)
  let sourceID = try #require(stack.allLayers.first?.id)

  let moveResult = stack.movingVectorObjectsToNewLayer(ids: [leaving.id], from: sourceID)
  let result = try #require(moveResult)
  #expect(result.objectIDs == [leaving.id])
  #expect(stack.activeLayerID == result.layerID)

  let source = try #require(stack.layer(id: sourceID)?.content.vectorValue)
  #expect(source.objects.map(\.id) == [staying.id])
  let created = try #require(stack.layer(id: result.layerID)?.content.vectorValue)
  #expect(created.objects.map(\.id) == [leaving.id])
  // The artwork is the same object, moved, so its identity survives.
  #expect(created.object(id: leaving.id)?.name == "Leaving")
}

@Test func pastingIntoALayerReidentifiesTheObjectsItAdds() throws {
  let original = box(0.1, 0.1, 0.2, 0.2, name: "Badge")
  var stack = LayerStackRecipe(
    layers: [
      ProjectLayer(
        name: "Vector Layer",
        isEnabled: true,
        isLocked: false,
        zOrder: 0,
        content: .vector(VectorLayer(objects: [original])))
    ])
  stack.canvas = CanvasRecipe(width: 100, height: 100)
  let layerID = try #require(stack.allLayers.first?.id)

  let newIDs = stack.addingVectorObjects([original], to: layerID)
  let newID = try #require(newIDs.first)
  #expect(newID != original.id)

  let layer = try #require(stack.layer(id: layerID)?.content.vectorValue)
  #expect(layer.objects.count == 2)
  // Two objects with the same name would be indistinguishable in the list.
  #expect(layer.object(id: newID)?.name == "Badge copy")
  #expect(layer.objectIDsInDrawOrder == [original.id, newID])
}

@Test func aLockedLayerRefusesToGiveUpOrTakeObjects() throws {
  let only = box(0.1, 0.1, 0.2, 0.2)
  var stack = LayerStackRecipe(
    layers: [
      ProjectLayer(
        name: "Vector Layer",
        isEnabled: true,
        isLocked: true,
        zOrder: 0,
        content: .vector(VectorLayer(objects: [only])))
    ])
  stack.canvas = CanvasRecipe(width: 100, height: 100)
  let layerID = try #require(stack.allLayers.first?.id)

  let refusedMove = stack.movingVectorObjectsToNewLayer(ids: [only.id], from: layerID)
  #expect(refusedMove == nil)
  let refusedPaste = stack.addingVectorObjects([only], to: layerID)
  #expect(refusedPaste.isEmpty)
}

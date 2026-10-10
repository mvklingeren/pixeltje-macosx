import CoreGraphics
import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

/// An axis-aligned rectangle as a closed four-anchor path.
private func rectangle(
  _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
  name: String = "Rectangle",
  zOrder: Int = 0
) -> VectorObject {
  .path(
    VectorPath(
      name: name,
      zOrder: zOrder,
      anchors: [
        VectorAnchor(position: VectorPoint(x: minX, y: minY)),
        VectorAnchor(position: VectorPoint(x: maxX, y: minY)),
        VectorAnchor(position: VectorPoint(x: maxX, y: maxY)),
        VectorAnchor(position: VectorPoint(x: minX, y: maxY)),
      ],
      isClosed: true,
      stroke: VectorStrokeStyle(color: .black, width: 2),
      fill: VectorFillStyle(color: .white)
    ))
}

private func combinedBounds(_ compound: VectorCompoundPath) -> VectorBounds? {
  compound.paths
    .compactMap(\.boundingBox)
    .reduce(nil) { partial, box in partial?.union(box) ?? box }
}

@Test func unionMergesOverlappingObjectsIntoOneOutline() throws {
  let left = rectangle(0.1, 0.1, 0.5, 0.5, name: "Left", zOrder: 0)
  let right = rectangle(0.3, 0.1, 0.7, 0.5, name: "Right", zOrder: 1)

  let result = try #require(
    VectorBooleanEngine.combine([left, right], operation: .union, aspect: 1))
  #expect(result.contours.count == 1)
  let box = try #require(combinedBounds(result))
  #expect(abs(box.minX - 0.1) < 1e-3)
  #expect(abs(box.maxX - 0.7) < 1e-3)
  #expect(abs(box.height - 0.4) < 1e-3)
  // The base object's appearance survives the operation.
  #expect(result.name == "Left")
  #expect(result.fill?.color == .white)
  #expect(result.stroke?.width == 2)
}

@Test func subtractRemovesWhatSitsAboveTheBottomMostObject() throws {
  let base = rectangle(0.1, 0.1, 0.9, 0.9, name: "Base", zOrder: 0)
  let bite = rectangle(0.5, 0.0, 1.0, 1.0, name: "Bite", zOrder: 1)

  let result = try #require(
    VectorBooleanEngine.combine([base, bite], operation: .subtract, aspect: 1))
  let box = try #require(combinedBounds(result))
  #expect(abs(box.minX - 0.1) < 1e-3)
  // The right half is gone.
  #expect(abs(box.maxX - 0.5) < 1e-3)
}

@Test func intersectKeepsOnlyWhatEveryObjectCovers() throws {
  let left = rectangle(0.1, 0.1, 0.5, 0.5, zOrder: 0)
  let right = rectangle(0.3, 0.2, 0.7, 0.6, zOrder: 1)

  let result = try #require(
    VectorBooleanEngine.combine([left, right], operation: .intersect, aspect: 1))
  let box = try #require(combinedBounds(result))
  #expect(abs(box.minX - 0.3) < 1e-3)
  #expect(abs(box.maxX - 0.5) < 1e-3)
  #expect(abs(box.minY - 0.2) < 1e-3)
  #expect(abs(box.maxY - 0.5) < 1e-3)
}

@Test func booleanOperationsHonorEachOperandsOwnFillRule() {
  let base = rectangle(0.4, 0.4, 0.6, 0.6, name: "Inside the hole", zOrder: 0)
  let ring = VectorObject.compound(
    VectorCompoundPath(
      name: "Even-Odd Ring",
      zOrder: 1,
      contours: [
        VectorContour(rectangle(0.1, 0.1, 0.9, 0.9).resolvedPath()),
        // Same winding as the outer contour: only even-odd makes this a hole.
        VectorContour(rectangle(0.3, 0.3, 0.7, 0.7).resolvedPath()),
      ],
      fillRule: .evenOdd,
      fill: VectorFillStyle(color: .white)))

  // The first operand uses non-zero. Applying that rule to both inputs would
  // fill the ring's center and incorrectly retain the base rectangle.
  #expect(VectorBooleanEngine.combine([base, ring], operation: .intersect, aspect: 1) == nil)
}

@Test func excludeLeavesTheOverlapAsAHole() throws {
  let left = rectangle(0.1, 0.1, 0.5, 0.5, zOrder: 0)
  let right = rectangle(0.3, 0.3, 0.7, 0.7, zOrder: 1)

  let result = try #require(
    VectorBooleanEngine.combine([left, right], operation: .exclude, aspect: 1))
  // The overlap becomes a hole, so the result needs more than one contour.
  #expect(result.contours.count >= 2)

  // A point in the overlap is outside the result; a point in one square only is
  // inside it.
  let contours = result.paths
  #expect(!result.fillRule.contains(VectorPoint(x: 0.4, y: 0.4), contours: contours))
  #expect(result.fillRule.contains(VectorPoint(x: 0.2, y: 0.2), contours: contours))
}

@Test func subtractingAShapeFromItselfReportsThatNothingIsLeft() {
  let square = rectangle(0.2, 0.2, 0.6, 0.6, zOrder: 0)
  var above = square
  above.zOrder = 1
  // Nothing survives, so the engine says so rather than quietly deleting the
  // artwork and leaving an empty object behind.
  #expect(VectorBooleanEngine.combine([square, above], operation: .subtract, aspect: 1) == nil)
}

@Test func aBooleanNeedsTwoObjectsToHaveAnythingToCombine() {
  let only = rectangle(0.2, 0.2, 0.6, 0.6)
  #expect(VectorBooleanEngine.combine([only], operation: .union, aspect: 1) == nil)
}

@Test func curvesSurviveABooleanRatherThanBecomingPolygons() throws {
  // Two overlapping circles. Their union has to keep curve segments: flattening
  // would show up as a large number of straight anchors.
  let left = VectorObject.shape(
    VectorShape(
      kind: .ellipse,
      frame: VectorBounds(minX: 0.1, minY: 0.3, maxX: 0.5, maxY: 0.7)))
  let right = VectorObject.shape(
    VectorShape(
      zOrder: 1,
      kind: .ellipse,
      frame: VectorBounds(minX: 0.3, minY: 0.3, maxX: 0.7, maxY: 0.7)))

  let result = try #require(
    VectorBooleanEngine.combine([left, right], operation: .union, aspect: 1))
  let anchors = result.contours.flatMap(\.anchors)
  #expect(anchors.count < 20)
  #expect(anchors.contains { $0.outgoingHandle != nil })
}

@Test func combiningReplacesTheOperandsAndKeepsTheBaseInPlace() throws {
  let under = rectangle(0.0, 0.0, 0.2, 0.2, name: "Under", zOrder: 0)
  let left = rectangle(0.3, 0.3, 0.6, 0.6, name: "Left", zOrder: 1)
  let right = rectangle(0.5, 0.3, 0.8, 0.6, name: "Right", zOrder: 2)
  let over = rectangle(0.9, 0.9, 1.0, 1.0, name: "Over", zOrder: 3)
  let layer = VectorLayer(objects: [under, left, right, over])

  let combined = try #require(
    layer.combining(ids: [left.id, right.id], operation: .union, aspect: 1))
  #expect(combined.objects.count == 3)
  #expect(combined.object(id: left.id) == nil)
  #expect(combined.object(id: right.id) == nil)

  // The result sits where the base object was, between the two that were not
  // part of the operation.
  let order = combined.objectIDsInDrawOrder
  #expect(order.first == under.id)
  #expect(order.last == over.id)
  #expect(combined.objects.contains { $0.compound != nil })
}

@Test func releaseSplitsACompoundBackIntoOrdinaryPaths() throws {
  let left = rectangle(0.1, 0.1, 0.4, 0.4, zOrder: 0)
  let right = rectangle(0.6, 0.1, 0.9, 0.4, zOrder: 1)
  let layer = try #require(
    VectorLayer(objects: [left, right]).combining(
      ids: [left.id, right.id], operation: .union, aspect: 1))
  let compoundID = try #require(layer.objects.first { $0.compound != nil }?.id)

  let released = try #require(layer.releasingCompoundPaths(ids: [compoundID]))
  #expect(released.newIDs.count == 2)
  #expect(released.layer.objects.allSatisfy { $0.compound == nil })
  #expect(released.layer.objects.allSatisfy { $0.path != nil })
  // Each released path keeps the compound's appearance.
  #expect(released.layer.objects.allSatisfy { $0.fill?.color == .white })
}

@Test func releasingACompoundKeepsItsContoursTogetherInItsDrawPosition() throws {
  let under = rectangle(0.0, 0.0, 0.1, 0.1, name: "Under", zOrder: 0)
  let first = rectangle(0.2, 0.2, 0.4, 0.4, name: "First", zOrder: 0)
  let second = rectangle(0.5, 0.2, 0.7, 0.4, name: "Second", zOrder: 0)
  let compound = VectorCompoundPath(
    name: "Compound",
    zOrder: 1,
    contours: [VectorContour(first.resolvedPath()), VectorContour(second.resolvedPath())],
    fill: VectorFillStyle(color: .white))
  let over = rectangle(0.8, 0.8, 0.9, 0.9, name: "Over", zOrder: 2)
  let layer = VectorLayer(objects: [under, .compound(compound), over])

  let released = try #require(layer.releasingCompoundPaths(ids: [compound.id]))

  #expect(
    released.layer.objectIDsInDrawOrder
      == [under.id, first.id, second.id, over.id])
  #expect(released.layer.objectsInDrawOrder.map(\.zOrder) == [0, 1, 2, 3])
  #expect(released.newIDs == [first.id, second.id])
}

@MainActor
@Test func documentSelectsTheNewBooleanResultWhenACompoundAlreadyExists() throws {
  let oldCompound = VectorCompoundPath(
    name: "Existing Compound",
    zOrder: 0,
    contours: [VectorContour(rectangle(0, 0, 0.1, 0.1).resolvedPath())],
    fill: VectorFillStyle(color: .white))
  let left = rectangle(0.2, 0.2, 0.6, 0.6, name: "Left", zOrder: 1)
  let right = rectangle(0.4, 0.2, 0.8, 0.6, name: "Right", zOrder: 2)
  let layer = ProjectLayer(
    name: "Vector Layer",
    content: .vector(VectorLayer(objects: [.compound(oldCompound), left, right])))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [layer, .canvasBase(CanvasRecipe(width: 100, height: 100))],
    activeLayerID: layer.id)
  let document = ProjectDocument()
  document.editorModel.updateRecipeInPlace(recipe)
  document.editorModel.setActiveTool(.move)
  document.editorModel.setSelectedVectorObjects([left.id, right.id])

  document.arrangeVectorObjects(.boolean(.union))

  let selectedID = try #require(document.editorModel.selectedVectorObjectIDs.first)
  #expect(document.editorModel.selectedVectorObjectIDs.count == 1)
  #expect(selectedID != oldCompound.id)
  #expect(document.editorModel.activeVectorLayer?.vector.object(id: selectedID)?.compound != nil)
}

@Test func aCompoundPathHasAHoleForHitTestingAsWellAsForTheEye() throws {
  let outer = VectorContour(rectangle(0.1, 0.1, 0.9, 0.9).resolvedPath())
  // A hole is wound the other way, so non-zero cancels it out.
  var innerPath = rectangle(0.3, 0.3, 0.7, 0.7).resolvedPath()
  innerPath = innerPath.reversed()
  let compound = VectorCompoundPath(
    contours: [outer, VectorContour(innerPath)],
    fill: VectorFillStyle(color: .white)
  )
  let object = VectorObject.compound(compound)

  #expect(
    object.hitTest(
      VectorPoint(x: 0.2, y: 0.5), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 1))
  #expect(
    !object.hitTest(
      VectorPoint(x: 0.5, y: 0.5), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 1))

  // Even-odd reaches the same answer without the winding having to disagree.
  var evenOdd = compound
  evenOdd.contours = [outer, VectorContour(rectangle(0.3, 0.3, 0.7, 0.7).resolvedPath())]
  evenOdd.fillRule = .evenOdd
  let evenOddObject = VectorObject.compound(evenOdd)
  #expect(
    !evenOddObject.hitTest(
      VectorPoint(x: 0.5, y: 0.5), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 1))
}

@Test func aCompoundPathRoundTripsThroughAProject() throws {
  let compound = VectorCompoundPath(
    name: "Ring",
    zOrder: 2,
    contours: [
      VectorContour(rectangle(0.1, 0.1, 0.9, 0.9).resolvedPath()),
      VectorContour(rectangle(0.3, 0.3, 0.7, 0.7).resolvedPath().reversed()),
    ],
    fillRule: .evenOdd,
    stroke: VectorStrokeStyle(color: .black, width: 3, alignment: .inside),
    fill: VectorFillStyle(gradient: VectorGradient())
  )
  var project = ProjectRecipe()
  project.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  project = project.applying(
    .addLayer(
      ProjectLayer(
        name: "Vector Layer",
        isEnabled: true,
        isLocked: false,
        zOrder: 1,
        content: .vector(VectorLayer(objects: [.compound(compound)])))))

  let reopened = try JSONDecoder().decode(
    ProjectRecipe.self, from: try JSONEncoder().encode(project))
  let stored = try #require(
    reopened.layerStack.allLayers.compactMap(\.content.vectorValue).first)
  #expect(stored.object(id: compound.id)?.compound == compound)
}

@Test func aCompoundHoleIsNotPaintedByTheRenderer() throws {
  var inner = rectangle(0.35, 0.35, 0.65, 0.65).resolvedPath()
  inner = inner.reversed()
  let compound = VectorCompoundPath(
    contours: [
      VectorContour(rectangle(0.15, 0.15, 0.85, 0.85).resolvedPath()),
      VectorContour(inner),
    ],
    fill: VectorFillStyle(color: .white)
  )
  let layer = ProjectLayer(
    name: "Vector Layer",
    isEnabled: true,
    isLocked: false,
    zOrder: 1,
    content: .vector(VectorLayer(objects: [.compound(compound)]))
  )
  let sample = try sampled(layer, width: 64, height: 64)

  // Inside the ring is painted; the hole in the middle is not.
  #expect(sample.pixels[32 * sample.bytesPerRow + 15 * 4 + 3] > 200)
  #expect(sample.pixels[32 * sample.bytesPerRow + 32 * 4 + 3] == 0)
}

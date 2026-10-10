import Foundation
import Testing

@testable import PixeltjeMacDomain

// MARK: - Geometry

@Test func aRectangleNormalizesADragMadeInAnyDirection() {
  // Dragging up-right and down-left across the same two corners must describe
  // the same rectangle, so nothing downstream has to cope with a negative
  // extent.
  let upRight = ShapeMask(
    from: VectorPoint(x: 0.2, y: 0.3), to: VectorPoint(x: 0.8, y: 0.9))
  let downLeft = ShapeMask(
    from: VectorPoint(x: 0.8, y: 0.9), to: VectorPoint(x: 0.2, y: 0.3))

  #expect(upRight == downLeft)
  #expect(abs(upRight.origin.x - 0.2) < 1e-12)
  #expect(abs(upRight.origin.y - 0.3) < 1e-12)
  #expect(abs(upRight.width - 0.6) < 1e-12)
  #expect(abs(upRight.height - 0.6) < 1e-12)
  #expect(abs(upRight.maxX - 0.8) < 1e-12)
  #expect(abs(upRight.center.x - 0.5) < 1e-12)
}

@Test func aRectangleRejectsNonFiniteGeometry() {
  let broken = ShapeMask(
    origin: VectorPoint(x: .nan, y: .infinity), width: .nan, height: 0.5)
  #expect(broken.origin.x == 0)
  #expect(broken.origin.y.isFinite)
  #expect(broken.width == 0)
  #expect(broken.height == 0.5)
}

@Test func aZeroExtentRectangleEnclosesNothing() {
  #expect(ShapeMask(origin: VectorPoint(x: 0.5, y: 0.5), width: 0, height: 0.4).isEmpty)
  #expect(!ShapeMask.full.isEmpty)
  #expect(ShapeMask.full.width == 1)
}

@Test func aPolygonNeedsThreeCornersAndDropsBrokenPoints() {
  #expect(PolygonMask(points: []).isEmpty)
  #expect(PolygonMask(points: [VectorPoint(x: 0, y: 0), VectorPoint(x: 1, y: 1)]).isEmpty)

  let triangle = PolygonMask(points: [
    VectorPoint(x: 0, y: 0), VectorPoint(x: 1, y: 0), VectorPoint(x: 0, y: 1),
  ])
  #expect(!triangle.isEmpty)

  let withNaN = PolygonMask(points: [
    VectorPoint(x: 0, y: 0), VectorPoint(x: .nan, y: 0), VectorPoint(x: 1, y: 0),
    VectorPoint(x: 0, y: 1),
  ])
  #expect(withNaN.points.count == 3)
}

@Test func aPolygonIsCappedSoARunawayGestureStaysFinite() {
  let overLimit = (0...(MaskLimits.maximumPolygonPoints + 500)).map {
    VectorPoint(x: Double($0) / 100_000, y: 0.5)
  }
  let polygon = PolygonMask(points: overLimit)
  #expect(polygon.points.count == MaskLimits.maximumPolygonPoints)
  // Appending past the cap is a no-op rather than a silent overflow.
  #expect(polygon.appending(VectorPoint(x: 1, y: 1)).points.count
    == MaskLimits.maximumPolygonPoints)
}

// MARK: - The shared model

@Test func theNewGeneratorsSurviveARoundTrip() throws {
  let generators: [MaskGenerator] = [
    .rectangle(ShapeMask(origin: VectorPoint(x: 0.1, y: 0.2), width: 0.3, height: 0.4)),
    .ellipse(ShapeMask(origin: VectorPoint(x: 0, y: 0), width: 1, height: 0.5)),
    .polygon(
      PolygonMask(points: [
        VectorPoint(x: 0, y: 0), VectorPoint(x: 0.5, y: 0), VectorPoint(x: 0.25, y: 0.5),
      ])),
  ]
  for generator in generators {
    let data = try JSONEncoder().encode(generator)
    let decoded = try JSONDecoder().decode(MaskGenerator.self, from: data)
    #expect(decoded == generator)
    #expect(decoded.kind == generator.kind)
  }
}

@Test func drawnGeneratorsAreCanvasPlacedAndDoNotReadTheImage() {
  for kind in [MaskGeneratorKind.rectangle, .ellipse, .polygon] {
    #expect(kind.needsCanvasPlacement)
    #expect(!kind.readsSourceImage)
    #expect(kind.availability.isAvailable)
  }
}

@Test func anAbandonedGestureIsRecognizedAsEmptyGeometry() {
  #expect(MaskGenerator.rectangle(ShapeMask(origin: .zero, width: 0, height: 0)).isEmptyGeometry)
  #expect(MaskGenerator.polygon(PolygonMask(points: [.zero])).isEmptyGeometry)
  #expect(!MaskGenerator.rectangle(.full).isEmptyGeometry)
  // A generator with no geometry to abandon is never "empty" in this sense.
  #expect(!MaskGenerator.subject.isEmptyGeometry)
}

@Test func combiningAppendsComponentsInTheOrderTheyWereDrawn() {
  let first = MaskRecipe.selecting(.rectangle(.full))
  let combined =
    first
    .combining(.ellipse(ShapeMask(origin: .zero, width: 0.5, height: 0.5)), using: .subtract)
    .combining(.rectangle(ShapeMask(origin: .zero, width: 0.2, height: 0.2)), using: .intersect)

  #expect(combined.components.count == 3)
  #expect(combined.components[0].combine == .add)
  #expect(combined.components[1].combine == .subtract)
  #expect(combined.components[2].combine == .intersect)
  #expect(combined.summary == "Rectangle − Ellipse ∩ Rectangle")
}

@Test func aSelectionOfAbandonedGesturesSelectsNothing() {
  #expect(MaskRecipe(name: "Selection").selectsNothing)
  #expect(
    MaskRecipe.selecting(.rectangle(ShapeMask(origin: .zero, width: 0, height: 0)))
      .selectsNothing)
  #expect(!MaskRecipe.selectingAll.selectsNothing)
}

@Test func featherTravelsWithTheComponentTheGestureMade() {
  let selection = MaskRecipe.selecting(.rectangle(.full), feather: 12)
  #expect(selection.components[0].feather == 12)
  #expect(selection.name == MaskRecipe.selectionName)
}

// MARK: - The document-level selection

@Test func aNewProjectHasNoSelectionAtAll() {
  let recipe = ProjectRecipe()
  #expect(recipe.selection == nil)
  #expect(!recipe.hasSelection)
}

@Test func settingAndClearingTheSelectionAreBothOrdinaryEdits() {
  var recipe = ProjectRecipe()
  recipe = recipe.applying(.setSelection(.selectingAll, actionName: "Select All"))
  #expect(recipe.hasSelection)
  #expect(recipe.selection?.components.count == 1)

  recipe = recipe.applying(.setSelection(nil, actionName: "Deselect"))
  #expect(!recipe.hasSelection)
}

@Test func selectAllCoversTheWholeCanvas() {
  let selection = MaskRecipe.selectingAll
  guard case .rectangle(let shape) = selection.components[0].generator else {
    Issue.record("Select All should produce a rectangle")
    return
  }
  #expect(shape == .full)
}

@Test func theSelectionIsSavedAndReadBack() throws {
  var recipe = ProjectRecipe()
  recipe.selection = MaskRecipe.selecting(.rectangle(.full))
    .combining(
      .polygon(
        PolygonMask(points: [
          VectorPoint(x: 0.1, y: 0.1), VectorPoint(x: 0.9, y: 0.1),
          VectorPoint(x: 0.5, y: 0.8),
        ])),
      using: .subtract
    )

  let data = try JSONEncoder().encode(recipe)
  let decoded = try JSONDecoder().decode(ProjectRecipe.self, from: data)
  #expect(decoded.selection == recipe.selection)
  #expect(decoded.schemaVersion == ProjectRecipe.currentSchemaVersion)
}

@Test func aProjectWrittenBeforeSelectionsExistedDecodesWithNone() throws {
  // Schema 8 is the last version without a selection. Rather than hand-write
  // that shape, take what this version writes and remove what schema 8 did not
  // have, so the fixture cannot drift away from the real encoding.
  var recipe = ProjectRecipe()
  recipe.selection = .selectingAll
  let encoded = try JSONSerialization.jsonObject(
    with: try JSONEncoder().encode(recipe)
  )
  var object = try #require(encoded as? [String: Any])
  object.removeValue(forKey: "selection")
  object["schemaVersion"] = 8

  let decoded = try JSONDecoder().decode(
    ProjectRecipe.self,
    from: try JSONSerialization.data(withJSONObject: object)
  )
  // No selection at all, which is unrestricted editing — not an empty one.
  #expect(decoded.selection == nil)
  #expect(!decoded.hasSelection)
  #expect(decoded.schemaVersion == ProjectRecipe.currentSchemaVersion)
}

@Test func invertingASelectionFlipsTheWholeMask() {
  var selection = MaskRecipe.selectingAll
  #expect(!selection.isInverted)
  selection.isInverted.toggle()
  #expect(selection.isInverted)
  // Inversion is a property of the mask, not an extra component, so the
  // geometry the user drew is untouched and can be inverted back.
  #expect(selection.components.count == 1)
}

@Test func savingASelectionCopiesItOntoTheLayerUnchanged() {
  var stack = LayerStackRecipe.empty
  let layer = ProjectLayer.paint(PaintLayerRecipe(), id: ProjectLayerID())
  stack = stack.adding(layer)

  var recipe = ProjectRecipe(layerStack: stack)
  recipe.selection = MaskRecipe.selecting(.ellipse(.full))

  let maskID = MaskID()
  let saved = recipe.applying(.saveSelectionAsMask(layer.id, maskID))

  let mask = saved.layerStack.mask(maskID, on: layer.id)
  #expect(mask != nil)
  // The shared mask model is what makes this a copy rather than a conversion:
  // the components arrive byte for byte as they were drawn.
  #expect(mask?.components.map(\.generator) == recipe.selection?.components.map(\.generator))
  // Saving does not clear the selection.
  #expect(saved.hasSelection)
}

@Test func savingWithoutASelectionChangesNothing() {
  var stack = LayerStackRecipe.empty
  let layer = ProjectLayer.paint(PaintLayerRecipe(), id: ProjectLayerID())
  stack = stack.adding(layer)
  let recipe = ProjectRecipe(layerStack: stack)

  #expect(recipe.applying(.saveSelectionAsMask(layer.id, MaskID())) == recipe)
}

// MARK: - Rounded corners

@Test func aRectangleClampsItsCornerRadiusToHalfTheShorterEdge() {
  // The radius is a fraction of the shorter canvas edge, and half of that is
  // already a stadium, so nothing past it is worth storing.
  #expect(ShapeMask(origin: .zero, width: 1, height: 1, cornerRadius: 4).cornerRadius == 0.5)
  #expect(ShapeMask(origin: .zero, width: 1, height: 1, cornerRadius: -1).cornerRadius == 0)
  #expect(ShapeMask(origin: .zero, width: 1, height: 1, cornerRadius: .nan).cornerRadius == 0)
  #expect(
    abs(ShapeMask(origin: .zero, width: 1, height: 1, cornerRadius: 0.25).cornerRadius - 0.25)
      < 1e-12)
}

@Test func aDragCarriesItsCornerRadiusThroughNormalization() {
  let shape = ShapeMask(
    from: VectorPoint(x: 0.8, y: 0.9), to: VectorPoint(x: 0.2, y: 0.3), cornerRadius: 0.1)
  #expect(abs(shape.cornerRadius - 0.1) < 1e-12)
  #expect(abs(shape.origin.x - 0.2) < 1e-12)
}

@Test func aRectangleWithoutAStoredCornerRadiusDecodesSquare() throws {
  // Projects written before the radius existed carry no key for it, and must
  // keep loading as the square rectangles they were.
  let legacy = Data(#"{"origin":{"x":0.1,"y":0.2},"width":0.5,"height":0.4}"#.utf8)
  let shape = try JSONDecoder().decode(ShapeMask.self, from: legacy)

  #expect(shape.cornerRadius == 0)
  #expect(abs(shape.width - 0.5) < 1e-12)
}

@Test func aCornerRadiusSurvivesACodingRoundTrip() throws {
  let shape = ShapeMask(origin: VectorPoint(x: 0, y: 0), width: 0.5, height: 0.5, cornerRadius: 0.2)
  let decoded = try JSONDecoder().decode(
    ShapeMask.self, from: try JSONEncoder().encode(shape))

  #expect(decoded == shape)
  #expect(abs(decoded.cornerRadius - 0.2) < 1e-12)
}

@Test func resizingTheCanvasKeepsACornerRadiusTheSameSizeInPixels() {
  // The radius is stored against the shorter edge, so halving that edge has to
  // double the fraction for the corner to stay the same number of pixels.
  let old = CanvasRecipe(width: 1_000, height: 1_000)
  let new = CanvasRecipe(width: 500, height: 500)
  let mask = MaskRecipe.selecting(
    .rectangle(ShapeMask(origin: .zero, width: 0.5, height: 0.5, cornerRadius: 0.1)))

  let resized = mask.resizingCanvas(from: old, to: new, offset: CanvasOffset(x: 0, y: 0))

  guard case .rectangle(let shape) = resized.components[0].generator else {
    Issue.record("expected a rectangle")
    return
  }
  #expect(abs(shape.cornerRadius - 0.2) < 1e-12)
}

// MARK: - Hiding a selection behind a layer mask

private func rectangle(_ x: Double, _ y: Double, _ size: Double = 0.2) -> MaskGenerator {
  .rectangle(ShapeMask(origin: VectorPoint(x: x, y: y), width: size, height: size))
}

@Test func hidingASelectionFromNoMaskIsTheSelectionInverted() {
  // The common case: the layer keeps everything, so everything except the
  // selection is simply the selection the other way round.
  let selection = MaskRecipe.selecting(rectangle(0.1, 0.1))

  let mask = MaskRecipe.hiding(selection, from: nil)

  #expect(mask?.isInverted == true)
  #expect(mask?.components.count == 1)
  #expect(mask?.isEnabled == true)
}

@Test func hidingAnInvertedSelectionFromNoMaskIsExactWhateverItContains() {
  // Inversion is a flag on the whole recipe, so toggling it is exact even for
  // a selection several components deep.
  var selection = MaskRecipe.selecting(rectangle(0.1, 0.1))
  selection = selection.combining(rectangle(0.5, 0.5), using: .add)
  selection.isInverted = true

  let mask = MaskRecipe.hiding(selection, from: nil)

  #expect(mask?.isInverted == false)
  #expect(mask?.components.count == 2)
}

@Test func hidingASelectionFromAnOrdinaryMaskSubtractsIt() {
  let existing = MaskRecipe.selecting(rectangle(0, 0, 1))
  let selection = MaskRecipe.selecting(rectangle(0.1, 0.1))

  let mask = MaskRecipe.hiding(selection, from: existing)

  #expect(mask?.components.count == 2)
  #expect(mask?.components.last?.combine == .subtract)
  #expect(mask?.isInverted == false)
}

@Test func hidingASelectionFromAnInvertedMaskAddsIt() {
  // A mask that already hides one area is `¬U`. Hiding S as well means
  // `¬(U ∪ S)`, so the new component is added, not subtracted — subtracting
  // would uncover the very pixels the second delete meant to hide. This is the
  // shape a second delete on the same layer takes.
  let first = MaskRecipe.hiding(MaskRecipe.selecting(rectangle(0.1, 0.1)), from: nil)
  let second = MaskRecipe.hiding(MaskRecipe.selecting(rectangle(0.5, 0.5)), from: first)

  #expect(second?.isInverted == true)
  #expect(second?.components.count == 2)
  #expect(second?.components.last?.combine == .add)
}

@Test func hidingAnInvertedSelectionFromAMaskIntersectsWhatItKeeps() {
  let existing = MaskRecipe.selecting(rectangle(0, 0, 1))
  var selection = MaskRecipe.selecting(rectangle(0.2, 0.2, 0.5))
  selection.isInverted = true

  let mask = MaskRecipe.hiding(selection, from: existing)

  #expect(mask?.components.count == 2)
  #expect(mask?.components.last?.combine == .intersect)
  #expect(mask?.isInverted == false)
}

@Test func hidingAnInvertedSelectionFromAnInvertedMaskIsRewrittenAsASubtraction() {
  // `¬U ∩ c` cannot be written by appending — the inversion applies after the
  // components combine — but it is the same region as `c − U`, which can.
  let existing = MaskRecipe.hiding(MaskRecipe.selecting(rectangle(0.1, 0.1)), from: nil)
  var selection = MaskRecipe.selecting(rectangle(0.4, 0.4, 0.4))
  selection.isInverted = true

  let mask = MaskRecipe.hiding(selection, from: existing)

  #expect(mask?.isInverted == false)
  #expect(mask?.components.count == 2)
  #expect(mask?.components.last?.combine == .subtract)
}

@Test func hidingAMultiPartInvertedSelectionFromAMaskIsRefused() {
  // Intersecting against a union would need a nested mask, which the model has
  // no room for. Saying so is better than masking a region that is nearly right.
  let existing = MaskRecipe.selecting(rectangle(0, 0, 1))
  var selection = MaskRecipe.selecting(rectangle(0.1, 0.1))
  selection = selection.combining(rectangle(0.6, 0.6), using: .add)
  selection.isInverted = true

  #expect(MaskRecipe.hiding(selection, from: existing) == nil)
}

@Test func hidingASelectionThatSubtractsFromItselfIsRefused() {
  // Appending only reads as "and also this area" when the parts are a union.
  let existing = MaskRecipe.selecting(rectangle(0, 0, 1))
  let selection = MaskRecipe.selecting(rectangle(0.1, 0.1))
    .combining(rectangle(0.15, 0.15), using: .subtract)

  #expect(MaskRecipe.hiding(selection, from: existing) == nil)
}

@Test func hidingNothingLeavesTheMaskAlone() {
  let existing = MaskRecipe.selecting(rectangle(0, 0, 1))
  let empty = MaskRecipe(name: "Selection", components: [])

  #expect(MaskRecipe.hiding(empty, from: existing) == existing)
  #expect(MaskRecipe.hiding(empty, from: nil) == nil)
}

@Test func hidingASelectionFromAnEmptyMaskTreatsTheLayerAsUnmasked() {
  // A mask with nothing in it restricts nothing, so it must be replaced rather
  // than appended to: appending would make the first component the base and
  // select exactly what the delete meant to remove.
  let hollow = MaskRecipe(name: "Layer Mask", components: [])
  let selection = MaskRecipe.selecting(rectangle(0.1, 0.1))

  let mask = MaskRecipe.hiding(selection, from: hollow)

  #expect(mask?.isInverted == true)
  #expect(mask?.components.count == 1)
  // The mask row it replaces keeps its identity, so the layer does not appear
  // to gain a second mask.
  #expect(mask?.id == hollow.id)
}

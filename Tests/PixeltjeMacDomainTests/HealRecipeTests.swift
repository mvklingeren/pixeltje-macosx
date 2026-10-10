import Foundation
import PixeltjeMacDomain
import Testing

private func healSample(_ x: Double, _ y: Double, pressure: Double = 1) -> BrushSample {
  BrushSample(x: x, y: y, pressure: pressure)
}

private func patchReference(
  id: String = "heal-asset",
  width: Int = 16,
  height: Int = 16
) -> RasterAssetReference {
  RasterAssetReference(
    id: RasterAssetID(rawValue: id),
    width: width,
    height: height,
    uncompressedByteCount: width * height * 8
  )
}

private func heal(
  id: String = "heal-asset",
  x: Double = 10,
  y: Double = 20,
  size: Double = 16,
  mode: HealSourceMode = .spot
) -> PaintHealRecipe {
  let stroke = PaintStroke(
    settings: BrushSettings(size: size),
    brush: BrushDefinition.healCoverage,
    samples: [healSample(x + size / 2, y + size / 2)]
  )
  return PaintHealRecipe(
    patch: patchReference(id: id, width: Int(size), height: Int(size)),
    frame: LayerFrame(x: x, y: y, width: size, height: size),
    coverage: MaskRecipe.healCoverage(stroke),
    provenance: HealProvenance(mode: mode, sourceOffsetX: 40, sourceOffsetY: -12)
  )
}

@Test func healRecipeRoundTripsThroughCoding() throws {
  let original = heal(mode: .sourcePoint)
  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(PaintHealRecipe.self, from: data)

  #expect(decoded == original)
  #expect(decoded.provenance.mode == .sourcePoint)
  #expect(decoded.provenance.sourceOffsetX == 40)
  #expect(decoded.provenance.sourceOffsetY == -12)
  #expect(decoded.coverage.strokeSurface?.kind == .mask)
  #expect(decoded.coverage.strokeSurface?.initialCoverage == 0)
}

@Test func healCoverageAlwaysRaisesCoverageEvenFromAnEraseStroke() {
  // An erase-mode stroke would lower coverage that was never laid down, so
  // the coverage builder normalizes the mode rather than trusting its caller.
  let erasing = PaintStroke(mode: .erase, samples: [healSample(4, 4)])
  let coverage = MaskRecipe.healCoverage(erasing)

  #expect(coverage.strokeSurface?.strokes.first?.mode == .paint)
}

@Test func aPaintLayerFromBeforeTheHealingBrushDecodesWithNoHeals() throws {
  // Schema 27 and earlier wrote no `heals` key at all.
  let legacy = """
    {"surface":{"kind":"colorRGBA","initialCoverage":0,"strokes":[]},
     "fills":[],"gradients":[]}
    """
  let decoded = try JSONDecoder().decode(
    PaintLayerRecipe.self, from: Data(legacy.utf8))

  #expect(decoded.heals.isEmpty)
  #expect(decoded.acceptsHeals)
  #expect(decoded.acceptsBrushStrokes)
}

@Test func healsAreBoundedPerLayer() {
  let many = (0..<(HealLimits.maximumHealsPerLayer + 40)).map { heal(id: "heal-\($0)") }
  var layer = PaintLayerRecipe(heals: many)

  #expect(layer.heals.count == HealLimits.maximumHealsPerLayer)
  #expect(!layer.acceptsHeals)

  layer.append(heal(id: "one-more"))
  #expect(layer.heals.count == HealLimits.maximumHealsPerLayer)
}

@Test func translatingAPaintLayerCarriesHealsWithItsStrokes() {
  let stroke = PaintStroke(samples: [healSample(5, 6)])
  let layer = PaintLayerRecipe(strokes: [stroke], heals: [heal(x: 10, y: 20)])

  let moved = layer.translated(byX: 7, y: -3)

  #expect(moved.surface.strokes[0].samples[0].x == 12)
  #expect(moved.surface.strokes[0].samples[0].y == 3)
  // The pixels and their visible shape have to move together, or a canvas
  // resize would strand every patch where the canvas used to be.
  #expect(moved.heals[0].frame.x == 17)
  #expect(moved.heals[0].frame.y == 17)
  let originalSample = layer.heals[0].coverage.strokeSurface?.strokes[0].samples[0]
  let movedSample = moved.heals[0].coverage.strokeSurface?.strokes[0].samples[0]
  #expect(movedSample?.x == (originalSample?.x ?? 0) + 7)
  #expect(movedSample?.y == (originalSample?.y ?? 0) - 3)
}

@Test func aCanvasResizeMovesHealsByTheAnchorOffset() {
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 100, height: 100)
  let layerID = ProjectLayerID(rawValue: "healing")
  recipe = recipe.applying(
    .addLayer(.paint(PaintLayerRecipe(heals: [heal(x: 10, y: 10)]), id: layerID)))

  let resized = recipe.applying(
    .resizeCanvas(CanvasRecipe(width: 140, height: 100), anchor: .center))
  let moved = resized.layerStack.layer(id: layerID)?.paintLayer?.heals.first

  #expect(moved?.frame.x == 30)
  #expect(moved?.frame.y == 10)
}

@Test func aLayerHoldingAnythingElseRefusesHeals() {
  let stroke = PaintStroke(samples: [healSample(1, 1)])
  #expect(!PaintLayerRecipe(strokes: [stroke]).acceptsHeals)
  #expect(PaintLayerRecipe().acceptsHeals)
  // And the reverse: a layer carrying heals is not a brush destination, so a
  // stroke cannot land on top of pixels that were solved without it.
  #expect(!PaintLayerRecipe(heals: [heal()]).acceptsBrushStrokes)
}

@Test func healPatchesAreListedAsProjectAssets() {
  let layer = ProjectLayer.paint(
    PaintLayerRecipe(heals: [heal(id: "first"), heal(id: "second")]))

  let ids = layer.rasterAssetReferences.map(\.id.rawValue)

  // Saving writes only the assets a layer claims, so an unclaimed patch would
  // be a recipe pointing at pixels the package does not contain.
  #expect(ids == ["first", "second"])
}

@Test func layerGeometryCoversHealPatches() throws {
  // The Move tool and the canvas overlays outline a layer by this rectangle,
  // so a layer whose only content is healed pixels must still have one.
  let layerID = ProjectLayerID(rawValue: "healing")
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 200, height: 200)
  recipe = recipe.applying(
    .addLayer(.paint(PaintLayerRecipe(heals: [heal(x: 10, y: 20, size: 16)]), id: layerID)))

  let frame = try #require(recipe.layerStack.frame(of: layerID))

  #expect(frame.x == 10)
  #expect(frame.y == 20)
  #expect(frame.width == 16)
  #expect(frame.height == 16)
}

@Test func committingHealsCreatesThenReusesOneHealingLayer() throws {
  let healingID = ProjectLayerID(rawValue: "healing")
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 128, height: 128)

  let first = heal(id: "first")
  recipe = recipe.applying(
    .commitHeal(first, toPaintLayer: nil, newLayerID: healingID))
  let created = try #require(recipe.layerStack.layer(id: healingID))

  #expect(created.name == "Healing")
  #expect(created.paintLayer?.heals == [first])
  #expect(recipe.layerStack.activeLayerID == healingID)

  // A retouching session is a run of dabs, so the second one joins the first
  // rather than adding another layer.
  let second = heal(id: "second")
  recipe = recipe.applying(
    .commitHeal(second, toPaintLayer: healingID, newLayerID: ProjectLayerID(rawValue: "unused")))

  #expect(recipe.layerStack.layer(id: healingID)?.paintLayer?.heals == [first, second])
  #expect(recipe.layerStack.layer(id: ProjectLayerID(rawValue: "unused")) == nil)

  let data = try JSONEncoder().encode(recipe)
  let reopened = try JSONDecoder().decode(ProjectRecipe.self, from: data)
  #expect(reopened == recipe)
  #expect(reopened.schemaVersion == ProjectRecipe.currentSchemaVersion)
}

@Test func anUnrenderablePatchIsNeverCommitted() {
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  let empty = PaintHealRecipe(
    patch: patchReference(width: 0, height: 0),
    frame: LayerFrame(x: 0, y: 0, width: 0, height: 0),
    coverage: MaskRecipe.healCoverage(PaintStroke(samples: [healSample(4, 4)]))
  )

  #expect(!empty.isRenderable)
  #expect(
    recipe.applying(
      .commitHeal(empty, toPaintLayer: nil, newLayerID: ProjectLayerID(rawValue: "new")))
      == recipe)
}

@Test func malformedProvenanceIsBounded() {
  // Non-finite offsets fall back to no offset, the way a brush sample's
  // coordinates do; a finite but absurd one is clamped instead.
  let nonFinite = HealProvenance(sourceOffsetX: .nan, sourceOffsetY: .infinity)
  #expect(nonFinite.sourceOffsetX == 0)
  #expect(nonFinite.sourceOffsetY == 0)

  let huge = HealProvenance(
    sourceOffsetX: 1e12,
    sourceOffsetY: -1e12,
    solverIterations: 10_000
  )
  #expect(huge.sourceOffsetX == Double(BrushLimits.maximumCanvasAxis))
  #expect(huge.sourceOffsetY == -Double(BrushLimits.maximumCanvasAxis))
  #expect(huge.solverIterations == HealLimits.maximumSolverIterations)

  #expect(
    HealProvenance(solverIterations: 0).solverIterations
      == HealLimits.minimumSolverIterations)
}

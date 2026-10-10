import Foundation
import PixeltjeMacDomain
import Testing

private func maskStroke(
  mode: BrushStrokeMode = .paint,
  x: Double = 12,
  y: Double = 18
) -> PaintStroke {
  PaintStroke(
    seed: 91,
    mode: mode,
    settings: BrushSettings(size: 14, hardness: 1, pressureResponse: 0),
    brush: BrushCatalog.preset(.hardRound).definition,
    selectionClip: .selecting(.rectangle(.full)),
    samples: [BrushSample(x: x, y: y)]
  )
}

@Test func layerMaskActionsAreTypedAndKeepPixelPaintSeparate() throws {
  let layerID = ProjectLayerID(rawValue: "paint")
  let maskID = MaskID(rawValue: "layer-mask")
  let layer = ProjectLayer.paint(PaintLayerRecipe(), id: layerID)
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 48)
  recipe.layerStack = recipe.layerStack.adding(layer)

  recipe = recipe.applying(.setLayerMask(layerID, .layerMask(revealsLayer: false, id: maskID)))
  #expect(recipe.layerStack.layer(id: layerID)?.layerMask?.strokeSurface?.initialCoverage == 0)
  #expect(recipe.layerStack.layer(id: layerID)?.paintLayer?.surface.strokes.isEmpty == true)

  let stroke = maskStroke()
  recipe = recipe.applying(.commitLayerMaskStroke(layerID, maskID, stroke))
  #expect(recipe.layerStack.layer(id: layerID)?.layerMask?.strokeSurface?.strokes == [stroke])
  #expect(recipe.layerStack.layer(id: layerID)?.paintLayer?.surface.strokes.isEmpty == true)

  recipe = recipe.applying(.setLayerMaskEnabled(layerID, false))
  #expect(recipe.layerStack.layer(id: layerID)?.layerMask?.isEnabled == false)
  // A disabled mask is not a writable target.
  #expect(recipe.applying(.commitLayerMaskStroke(layerID, maskID, maskStroke(x: 30))) == recipe)

  recipe = recipe.applying(.setLayerMaskInverted(layerID, true))
  #expect(recipe.layerStack.layer(id: layerID)?.layerMask?.isInverted == true)
  recipe = recipe.applying(.setLayerMask(layerID, nil))
  #expect(recipe.layerStack.layer(id: layerID)?.layerMask == nil)
}

@Test func imageEraserCreatesAWhiteMaskAndStrokeInOneAction() throws {
  let layerID = ProjectLayerID(rawValue: "linked-image")
  let maskID = MaskID(rawValue: "automatic-mask")
  let image = ImageLayer(
    source: SourceReference(
      originalFilename: "image.png",
      linkedPath: "/Pictures/image.png",
      securityScopedBookmark: nil,
      fingerprint: SourceFingerprint(byteLength: 1024, modificationDate: nil)
    ),
    frame: LayerFrame(x: 0, y: 0, width: 64, height: 48),
    naturalWidth: 64,
    naturalHeight: 48
  )
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 48)
  recipe.layerStack = recipe.layerStack.adding(.image(image, id: layerID))
  let stroke = maskStroke(mode: .erase)

  let erased = recipe.applying(.commitImageEraserStroke(layerID, maskID, stroke))
  let layer = try #require(erased.layerStack.layer(id: layerID))
  #expect(layer.imageLayer == image)
  #expect(layer.layerMask?.id == maskID)
  #expect(layer.layerMask?.strokeSurface?.initialCoverage == 1)
  #expect(layer.layerMask?.strokeSurface?.strokes == [stroke])
  #expect(erased.layerStack.contentLayers.map(\.id) == [layerID])
  #expect(try JSONDecoder().decode(ProjectRecipe.self, from: JSONEncoder().encode(erased)) == erased)

  // An auto-created mask cannot replace a mask added while the gesture ran.
  #expect(erased.applying(.commitImageEraserStroke(layerID, MaskID(), stroke)) == erased)
  var locked = recipe
  locked.layerStack.updateLayer(id: layerID) { $0.isLocked = true }
  #expect(locked.applying(.commitImageEraserStroke(layerID, maskID, stroke)) == locked)
  #expect(recipe.applying(.commitImageEraserStroke(layerID, maskID, maskStroke())) == recipe)

  var inverted = erased
  inverted.layerStack.updateLayer(id: layerID) { $0.layerMask?.isInverted = true }
  let further = inverted.applying(.commitImageEraserStroke(layerID, maskID, stroke))
  #expect(further.layerStack.layer(id: layerID)?.layerMask?.isInverted == true)
  #expect(further.layerStack.layer(id: layerID)?.layerMask?.strokeSurface?.strokes.count == 2)
  #expect(further.layerStack.layer(id: layerID)?.layerMask?.strokeSurface?.strokes.last?.mode == .paint)
}

@Test func whiteAndBlackLayerMasksRoundTripAndLegacyLayersDecodeUnchanged() throws {
  let white = MaskRecipe.layerMask(revealsLayer: true, id: MaskID(rawValue: "white"))
    .appendingLayerMaskStroke(maskStroke(mode: .erase))
  let black = MaskRecipe.layerMask(revealsLayer: false, id: MaskID(rawValue: "black"))
  #expect(white.strokeSurface?.initialCoverage == 1)
  #expect(black.strokeSurface?.initialCoverage == 0)

  let layer = ProjectLayer(
    id: ProjectLayerID(rawValue: "masked"),
    name: "Masked",
    content: .paint(PaintLayerRecipe()),
    layerMask: white
  )
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 40, height: 30)
  recipe.layerStack = recipe.layerStack.adding(layer)
  let reopened = try JSONDecoder().decode(ProjectRecipe.self, from: JSONEncoder().encode(recipe))
  #expect(reopened == recipe)
  #expect(reopened.schemaVersion == ProjectRecipe.currentSchemaVersion)

  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(layer)) as? [String: Any])
  object.removeValue(forKey: "layerMask")
  let legacy = try JSONDecoder().decode(
    ProjectLayer.self,
    from: JSONSerialization.data(withJSONObject: object))
  #expect(legacy.layerMask == nil)
}

@Test func duplicationAndCanvasAnchoringPreserveIndependentPaintedMasks() throws {
  let sourceID = ProjectLayerID(rawValue: "source")
  let duplicateID = ProjectLayerID(rawValue: "duplicate")
  let mask = MaskRecipe.layerMask(revealsLayer: true, id: MaskID(rawValue: "mask"))
    .appendingLayerMaskStroke(maskStroke(x: 10, y: 12))
  var stack = LayerStackRecipe(
    layers: [
      ProjectLayer(
        id: sourceID,
        name: "Source",
        content: .paint(PaintLayerRecipe()),
        layerMask: mask)
    ],
    activeLayerID: sourceID)
  stack.canvas = CanvasRecipe(width: 40, height: 30)
  stack = stack.duplicating(sourceID, as: duplicateID)

  #expect(stack.layer(id: duplicateID)?.layerMask == mask)
  stack.updateLayer(id: duplicateID) { layer in
    layer.layerMask = layer.layerMask?.appendingLayerMaskStroke(maskStroke(x: 20, y: 20))
  }
  #expect(stack.layer(id: sourceID)?.layerMask?.strokeSurface?.strokes.count == 1)
  #expect(stack.layer(id: duplicateID)?.layerMask?.strokeSurface?.strokes.count == 2)

  let resized = stack.resizingCanvas(
    to: CanvasRecipe(width: 60, height: 50),
    anchor: .center)
  let moved = try #require(
    resized.layer(id: sourceID)?.layerMask?.strokeSurface?.strokes.first?.samples.first)
  #expect(moved.x == 20)
  #expect(moved.y == 22)
}

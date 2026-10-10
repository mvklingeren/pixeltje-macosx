import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

private func inpaintingMaskDot(x: Double, y: Double, size: Double) -> PaintStroke {
  PaintStroke(
    seed: 0x4D_41_53_4B,
    settings: BrushSettings(
      size: size,
      hardness: 1,
      opacity: 1,
      flow: 1,
      spacing: 0.1,
      pressureResponse: 0),
    brush: BrushCatalog.preset(.hardRound).definition,
    color: .white,
    samples: [BrushSample(x: x, y: y, pressure: 1)])
}

@Test func nonzeroMaskBoundsConvertTopDownBitmapRowsToCoreImageCoordinates() {
  let width = 4
  let height = 8
  var coverage = [Float](repeating: 0, count: width * height)
  coverage[1 * width + 1] = 1
  coverage[2 * width + 2] = 1

  #expect(
    RenderEngine.nonzeroMaskBounds(coverage, width: width, height: height)
      == LayerFrame(x: 1, y: 5, width: 2, height: 2))
}

@Test func offCenterDocumentSelectionSurvivesFrozenFocusedPatchPreparation() async throws {
  guard let engine = try? RenderEngine(observesMemoryPressure: false) else { return }
  let documentID = UUID()
  let selection = MaskRecipe.selecting(
    .rectangle(
      ShapeMask(
        origin: VectorPoint(x: 0.25, y: 0.8),
        width: 0.5,
        height: 0.1)))
  var recipe = ProjectRecipe()
  recipe.selection = selection
  recipe.layerStack.canvas = CanvasRecipe(width: 32, height: 96)
  let request = RenderRequest(
    documentID: documentID,
    revision: 2,
    contentRevision: 3,
    input: nil,
    recipe: recipe,
    quality: .full)
  let frozen = try await engine.captureInpaintingMask(
    InpaintingMaskRenderRequest(
      renderRequest: request,
      source: .documentMask(selection)))

  #expect(frozen.nonzeroBounds.y > 70)
  #expect(frozen.nonzeroBounds.y + frozen.nonzeroBounds.height < 90)

  let frame = try await engine.render(request)
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 3,
      capture: .composite),
    mask: selection,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .black,
    usesFullOutputMask: false,
    requestedMaskSource: GenerationMaskSource(
      kind: .documentSelection, maskID: selection.id),
    resolvedMaskSource: GenerationMaskSource(
      kind: .documentSelection, maskID: selection.id))
  let preparation = try await engine.prepareComfyUIInpainting(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 32,
    outputHeight: 32,
    renderedMask: frozen)

  #expect(preparation.placementFrame.y > 60)
  #expect(preparation.maskCoverage.contains(where: { $0 > 0.99 }))
  #expect(preparation.maskCoverage.contains(0))
}

@Test func wholeDocumentSelectionSurvivesAspectFitPreparation() async throws {
  guard let engine = try? RenderEngine(observesMemoryPressure: false) else { return }
  let documentID = UUID()
  let selection = MaskRecipe.selectingAll
  var recipe = ProjectRecipe()
  recipe.selection = selection
  recipe.layerStack.canvas = CanvasRecipe(width: 32, height: 96)
  let request = RenderRequest(
    documentID: documentID,
    revision: 4,
    contentRevision: 5,
    input: nil,
    recipe: recipe,
    quality: .full)
  let frozen = try await engine.captureInpaintingMask(
    InpaintingMaskRenderRequest(
      renderRequest: request,
      source: .documentMask(selection)))
  let frame = try await engine.render(request)
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 5,
      capture: .composite),
    mask: selection,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .black,
    usesFullOutputMask: false,
    requestedMaskSource: GenerationMaskSource(
      kind: .documentSelection, maskID: selection.id),
    resolvedMaskSource: GenerationMaskSource(
      kind: .documentSelection, maskID: selection.id))

  let preparation = try await engine.prepareComfyUIInpainting(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 32,
    outputHeight: 32,
    renderedMask: frozen)

  #expect(preparation.placementFrame == LayerFrame(x: 0, y: 0, width: 32, height: 96))
  #expect(preparation.width == 8)
  #expect(preparation.height == 32)
  #expect(preparation.maskCoverage.allSatisfy { $0 > 0.99 })
}

@Test func capturedLayerMaskReplaysPaintAndFocusesTheGenerationPatch() async throws {
  guard let engine = try? RenderEngine(observesMemoryPressure: false) else { return }
  let documentID = UUID()
  let maskID = MaskID(rawValue: "painted-inpainting-mask")
  let sourceStroke = inpaintingMaskDot(x: 32, y: 16, size: 96)
  var layer = ProjectLayer(
    id: ProjectLayerID(rawValue: "painted-owner"),
    name: "Painted owner",
    content: .paint(PaintLayerRecipe(strokes: [sourceStroke])))
  layer.layerMask = MaskRecipe.layerMask(revealsLayer: false, id: maskID)
    .appendingLayerMaskStroke(inpaintingMaskDot(x: 56, y: 16, size: 6))

  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer])
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 32)
  let renderRequest = RenderRequest(
    documentID: documentID,
    revision: 7,
    contentRevision: 11,
    input: nil,
    recipe: recipe,
    quality: .full)

  let frozen = try await engine.captureInpaintingMask(
    InpaintingMaskRenderRequest(
      renderRequest: renderRequest,
      source: .layerMask(layerID: layer.id, maskID: maskID)))
  #expect(frozen.coverage.contains(where: { $0 > 0 }))
  #expect(frozen.nonzeroBounds.x > 50)
  #expect(frozen.nonzeroBounds.x + frozen.nonzeroBounds.width <= 61)

  let frame = try await engine.render(renderRequest)
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 11,
      capture: .composite,
      activeLayerID: layer.id),
    mask: layer.layerMask!,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .black,
    usesFullOutputMask: false,
    requestedMaskSource: GenerationMaskSource(
      kind: .layerMask, layerID: layer.id, maskID: maskID),
    resolvedMaskSource: GenerationMaskSource(
      kind: .layerMask, layerID: layer.id, maskID: maskID))
  let preparation = try await engine.prepareComfyUIInpainting(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 16,
    outputHeight: 16,
    renderedMask: frozen)

  #expect(preparation.placementFrame == LayerFrame(x: 48, y: 8, width: 16, height: 16))
  #expect(preparation.maskCoverage.contains(where: { $0 > 0 }))
}

@Test func capturedLayerMaskUsesOwnerCropAndNestedTransformsWithoutContentAlpha() async throws {
  guard let engine = try? RenderEngine(observesMemoryPressure: false) else { return }
  let width = 32
  let height = 32
  // The owner has real raster geometry but is fully transparent. Coverage must
  // therefore come from the selected mask, not from the layer's content alpha.
  let encoded = try RasterAssetPayload.encode(
    Data(repeating: 0, count: width * height * 8),
    width: width,
    height: height)
  let layerID = ProjectLayerID(rawValue: "transparent-mask-owner")
  let maskID = MaskID(rawValue: "cropped-transformed-mask")
  let ownerFrame = LayerFrame(x: 0, y: 0, width: 32, height: 32)
  var owner = ProjectLayer(
    id: layerID,
    name: "Transparent owner",
    content: .raster(RasterLayerRecipe(asset: encoded.reference, frame: ownerFrame)),
    layerMask: MaskRecipe.layerMask(revealsLayer: true, id: maskID),
    crop: CropRecipe(left: 0, bottom: 0, right: 0.5, top: 1))
  var ownerTransform = LayerTransform.identity(for: ownerFrame)
  ownerTransform.position.x += 4
  owner.transform = ownerTransform

  var group = ProjectLayer.group(
    [owner], id: ProjectLayerID(rawValue: "translated-mask-group"))
  var groupTransform = LayerTransform.identity(for: ownerFrame)
  groupTransform.position.x += 4
  group.transform = groupTransform

  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [group])
  recipe.layerStack.canvas = CanvasRecipe(width: 40, height: 32)
  let renderRequest = RenderRequest(
    documentID: UUID(),
    revision: 3,
    contentRevision: 5,
    input: nil,
    rasterAssets: [encoded.reference.id: encoded.compressedPixels],
    recipe: recipe,
    quality: .full)

  let frozen = try await engine.captureInpaintingMask(
    InpaintingMaskRenderRequest(
      renderRequest: renderRequest,
      source: .layerMask(layerID: layerID, maskID: maskID)))

  #expect(frozen.nonzeroBounds == LayerFrame(x: 8, y: 0, width: 16, height: 32))
  #expect(frozen.coverage[16 * frozen.width + 12] > 0.99)
  #expect(frozen.coverage[16 * frozen.width + 4] == 0)
  #expect(frozen.coverage[16 * frozen.width + 28] == 0)
}

@Test func capturedLayerMaskDoesNotRequirePaintPixelsForGeometricCoverage() async throws {
  guard let engine = try? RenderEngine(observesMemoryPressure: false) else { return }
  let layerID = ProjectLayerID(rawValue: "empty-paint-owner")
  let maskID = MaskID(rawValue: "geometric-mask")
  var mask = MaskRecipe.selecting(
    .rectangle(
      ShapeMask(
        origin: VectorPoint(x: 0.25, y: 0.25),
        width: 0.5,
        height: 0.5)))
  mask.id = maskID
  var layer = ProjectLayer.paint(PaintLayerRecipe(), id: layerID)
  layer.layerMask = mask

  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layerID)
  recipe.layerStack.canvas = CanvasRecipe(width: 32, height: 32)
  let request = RenderRequest(
    documentID: UUID(),
    revision: 1,
    contentRevision: 1,
    input: nil,
    recipe: recipe,
    quality: .full)

  let frozen = try await engine.captureInpaintingMask(
    InpaintingMaskRenderRequest(
      renderRequest: request,
      source: .layerMask(layerID: layerID, maskID: maskID)))

  #expect(frozen.nonzeroBounds == LayerFrame(x: 8, y: 8, width: 16, height: 16))
  #expect(frozen.coverage[16 * frozen.width + 16] > 0.99)
  #expect(frozen.coverage[2 * frozen.width + 2] == 0)
}

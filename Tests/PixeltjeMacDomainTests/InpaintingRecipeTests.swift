import Foundation
import PixeltjeMacDomain
import Testing

@Test func generatedRasterRecipeRoundTripsWithoutEmbeddingModelBytes() throws {
  let mask = MaskRecipe.single(
    .rectangle(
      ShapeMask(
        origin: VectorPoint(x: 0.25, y: 0.25), width: 0.5, height: 0.5)))
  let identity = CoreAIModelPackageIdentity(
    provider: "coreai.z-image",
    model: "z-image-turbo",
    modelRevision: "publisher-revision",
    hostPipelineRevision: "host-revision",
    functions: [
      .init(
        role: "denoiser", packageName: "dit.aimodel", declaredContentHash: "declared")
    ])
  let generation = InpaintingRecipe(
    mode: .textToImage,
    model: identity,
    prompt: "replace the flower with a lantern",
    negativePrompt: "text",
    source: GenerationSourceIdentity(
      documentID: "document", contentRevision: 42, activeLayerID: .rawBackground),
    mask: mask,
    seed: 99,
    steps: 8,
    guidance: 1,
    strength: 0.8,
    maskFeatherPixels: 12,
    transparentPixelBackground: .gray,
    outputWidth: 1024,
    outputHeight: 1024,
    usesFullOutputMask: false)
  let asset = RasterAssetReference(
    id: RasterAssetID(rawValue: "pixels"), width: 512, height: 512,
    uncompressedByteCount: 512 * 512 * 8)
  let layer = ProjectLayer.raster(
    RasterLayerRecipe(
      asset: asset,
      frame: LayerFrame(x: 0, y: 0, width: 512, height: 512),
      generation: generation),
    name: "Generated")
  var recipe = ProjectRecipe()
  recipe = recipe.applying(.setCanvasSize(CanvasRecipe(width: 512, height: 512)))
  recipe = recipe.applying(.addGeneratedLayer(layer))

  let data = try JSONEncoder().encode(recipe)
  let decoded = try JSONDecoder().decode(ProjectRecipe.self, from: data)

  #expect(decoded.schemaVersion == ProjectRecipe.currentSchemaVersion)
  #expect(decoded.layerStack.layer(id: layer.id)?.rasterLayer?.generation == generation)
  #expect(!String(decoding: data, as: UTF8.self).contains("main.mlirb"))
}

@Test func generationRecipeWithoutBackgroundDecodesAsLegacyConditioning() throws {
  let generation = InpaintingRecipe(
    model: CoreAIModelPackageIdentity(
      provider: "provider", model: "model", modelRevision: "1",
      hostPipelineRevision: "1", functions: []),
    prompt: "subject",
    source: GenerationSourceIdentity(documentID: "document", contentRevision: 1),
    mask: .selectingAll,
    seed: 7)
  let encoded = try JSONEncoder().encode(generation)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object.removeValue(forKey: "transparentPixelBackground")
  object.removeValue(forKey: "mode")
  object.removeValue(forKey: "outputWidth")
  object.removeValue(forKey: "outputHeight")
  object.removeValue(forKey: "usesFullOutputMask")

  let legacyData = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(InpaintingRecipe.self, from: legacyData)

  #expect(decoded.transparentPixelBackground == nil)
  #expect(decoded.mode == nil)
  #expect(decoded.effectiveMode == .inpainting)
  #expect(decoded.outputWidth == nil)
  #expect(decoded.outputHeight == nil)
  #expect(decoded.usesFullOutputMask == nil)
}

@Test func oneGeneratedLayerActionCanBeRecordedAsOneHistoryStep() {
  let initial = ProjectRecipe()
  let asset = RasterAssetReference(
    id: RasterAssetID(rawValue: "result"), width: 2, height: 2,
    uncompressedByteCount: 32)
  let layer = ProjectLayer.raster(
    RasterLayerRecipe(asset: asset, frame: LayerFrame(x: 0, y: 0, width: 2, height: 2)))
  let generated = initial.applying(.addGeneratedLayer(layer))
  var history = EditHistory(initial: initial)

  history.record(generated, name: "Generate Image")

  #expect(history.steps.count == 2)
  #expect(history.steps.last?.name == "Generate Image")
  #expect(history.undo() == initial)
}

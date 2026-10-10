import CoreImage
import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@Test func changeThresholdPreservesNearUnchangedPixelsAndStrongEdits() {
  let originalValues: [Float16] = [
    0.25, 0.25, 0.25, 1,
    0.25, 0.25, 0.25, 1,
    0.25, 0.25, 0.25, 1,
  ]
  let generatedValues: [Float16] = [
    0.26, 0.25, 0.25, 1,
    1, 0, 0, 1,
    1, 0, 0, 1,
  ]
  let original = originalValues.withUnsafeBytes { Data($0) }
  let generated = generatedValues.withUnsafeBytes { Data($0) }
  let uploaded: [UInt8] = [
    137, 137, 137, 255,
    137, 137, 137, 255,
    137, 137, 137, 255,
  ]
  let returned: [UInt8] = [
    138, 137, 137, 255,
    255, 0, 0, 255,
    255, 0, 0, 255,
  ]
  let distance = RenderEngine.perceptualDifference(
    uploaded: uploaded, returned: returned, original: original)
  let matte = RenderEngine.changeMatte(
    difference: distance, width: 3, height: 1, threshold: 10)
  let result = RenderEngine.compositePixels(
    original: original, generated: generated, mask: [1, 1, 0], changeMatte: matte)
  let output = result.pixels.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }

  #expect(matte[0] > 0 && matte[0] < 1) // The edit edge is spatially feathered.
  #expect(matte[1] == 1)
  #expect(Array(output[4..<8]) == Array(generatedValues[4..<8]))
  #expect(Array(output[8..<12]) == Array(originalValues[8..<12]))
  #expect(result.outsideCount == 1)
  #expect(result.preservedCount == 1)
}

@Test func changeThresholdCopiesQuietInteriorsExactly() {
  let originalValues = [Float16](repeating: 0.25, count: 5 * 5 * 4)
  let generatedValues = [Float16](repeating: 0.26, count: 5 * 5 * 4)
  let original = originalValues.withUnsafeBytes { Data($0) }
  let generated = generatedValues.withUnsafeBytes { Data($0) }
  let matte = RenderEngine.changeMatte(
    difference: [Float](repeating: 0.2, count: 25),
    width: 5, height: 5, threshold: 50)
  let result = RenderEngine.compositePixels(
    original: original, generated: generated,
    mask: [Float](repeating: 1, count: 25), changeMatte: matte)

  #expect(matte.allSatisfy { $0 == 0 })
  #expect(result.pixels == original)
  #expect(result.outsideCount == 0)
}

@Test func changeThresholdRangeSuppressesOrdinaryModelDrift() {
  // A 25-point perceptual difference exceeded the old slider's 10-point
  // maximum, so every position previously kept these pixels unchanged.
  let difference: [Float] = [25]
  let low = RenderEngine.changeMatte(
    difference: difference, width: 1, height: 1, threshold: 5)
  let middle = RenderEngine.changeMatte(
    difference: difference, width: 1, height: 1, threshold: 25)
  let high = RenderEngine.changeMatte(
    difference: difference, width: 1, height: 1, threshold: 50)

  #expect(low == [1])
  #expect(middle == [0.5])
  #expect(high == [0])
}

@Test func transparentSourceIsNeverSuppressedByColorSimilarity() {
  let source: [Float16] = [0, 0, 0, 0]
  let original = source.withUnsafeBytes { Data($0) }
  let uploaded: [UInt8] = [255, 255, 255, 255]
  let returned = uploaded
  let distance = RenderEngine.perceptualDifference(
    uploaded: uploaded, returned: returned, original: original)
  let matte = RenderEngine.changeMatte(
    difference: distance, width: 1, height: 1, threshold: 100)

  #expect(distance[0].isInfinite)
  #expect(matte == [1])
}

@Test func missingSavedChangeThresholdDecodesAsOff() throws {
  let recipe = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: UUID().uuidString, contentRevision: 1, capture: .composite),
    mask: .selectingAll,
    strength: 0.8,
    maskFeatherPixels: 8,
    changeThreshold: 73,
    transparentPixelBackground: .white,
    usesFullOutputMask: true)
  let saved = try JSONEncoder().encode(recipe)
  var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
  object.removeValue(forKey: "changeThreshold")
  let older = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(
    ComfyUIInpaintingConditioningRecipe.self, from: older)

  #expect(try JSONDecoder().decode(
    ComfyUIInpaintingConditioningRecipe.self, from: saved).changeThreshold == 73)
  #expect(decoded.changeThreshold == 0)
}

@Test func identicalComfyUIResponseBecomesTransparentWhenThresholdSuppressesIt() async throws {
  guard let engine = try? RenderEngine() else { return }
  let bounds = CGRect(x: 0, y: 0, width: 2, height: 1)
  let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let upload = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    .cropped(to: bounds)
  let png = try #require(CIContext().pngRepresentation(
    of: upload, format: .RGBA8, colorSpace: srgb, options: [:]))
  let frozenValues: [Float16] = [
    0.2, 0.3, 0.4, 1,
    0.5, 0.6, 0.7, 1,
  ]
  let frozen = frozenValues.withUnsafeBytes { Data($0) }
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: UUID().uuidString, contentRevision: 1, capture: .composite),
    mask: .selectingAll,
    strength: 0.8,
    maskFeatherPixels: 0,
    changeThreshold: 50,
    transparentPixelBackground: .white,
    usesFullOutputMask: true)
  let preparation = ComfyUIInpaintingPreparation(
    sourcePNG: png,
    maskPNG: png,
    originalPixels: frozen,
    maskCoverage: [1, 1],
    placementFrame: LayerFrame(x: 0, y: 0, width: 2, height: 1),
    width: 2,
    height: 1,
    conditioning: conditioning)
  let output = try await engine.prepareComfyUIInpaintingOutput(
    imageData: png, preparation: preparation)
  let finished = try await engine.finishComfyUIInpainting(output)
  let masked = try RasterAssetPayload.decode(
    finished.raster.compressedPixels,
    reference: finished.raster.reference)

  #expect(output.perceptualDifference == [0, 0])
  #expect(masked == Data(repeating: 0, count: frozen.count))
  #expect(finished.raster.reference.width == 2)
  #expect(finished.raster.reference.height == 1)
}

@Test func comfyUIResponseUsesMaskAsPremultipliedLayerAlpha() {
  let generatedValues: [Float16] = [
    1, 0.5, 0.25, 1,
    1, 0.5, 0.25, 1,
    1, 0.5, 0.25, 1,
  ]
  let generated = generatedValues.withUnsafeBytes { Data($0) }
  let result = RenderEngine.maskedGeneratedPixels(
    generated: generated,
    mask: [0, 0.5, 1])
  let pixels = result.pixels.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }

  #expect(Array(pixels[0..<4]) == [0, 0, 0, 0])
  #expect(Array(pixels[4..<8]) == [0.5, 0.25, 0.125, 0.5])
  #expect(Array(pixels[8..<12]) == Array(generatedValues[8..<12]))
  #expect(result.outsideCount == 1)
  #expect(result.clearedCount == 1)
}

@Test func generatedInpaintLayerRetainsInputsAndRecomposesAfterRecipeEdit() async throws {
  guard let engine = try? RenderEngine() else { return }
  let documentID = UUID()
  let sourceValues: [Float16] = [
    0.25, 0.25, 0.25, 1,
    0.1, 0.2, 0.3, 1,
  ]
  let generatedValues: [Float16] = [
    0.8, 0.8, 0.8, 1,
    1, 0, 0, 1,
  ]
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString, contentRevision: 1, capture: .composite),
    mask: .selectingAll,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .white,
    usesFullOutputMask: true)
  let preparation = ComfyUIInpaintingPreparation(
    sourcePNG: Data(), maskPNG: Data(),
    originalPixels: sourceValues.withUnsafeBytes { Data($0) },
    maskCoverage: [1, 0],
    placementFrame: LayerFrame(x: 0, y: 0, width: 2, height: 1),
    width: 2, height: 1, conditioning: conditioning)
  let output = ComfyUIInpaintingOutput(
    preparation: preparation,
    generatedPixels: generatedValues.withUnsafeBytes { Data($0) },
    perceptualDifference: [25, 25])
  let assets = try await engine.makeComfyUIInpaintingLayerAssets(output)
  let generation = ComfyUIGenerationRecipe(
    templateID: "flux2-klein-inpaint-base", templateRevision: "test", promptID: "test",
    prompt: "edit", negativePrompt: "", seed: 1, steps: 8, guidance: 1,
    outputWidth: 2, outputHeight: 1, mode: .inpainting,
    inpainting: conditioning)
  let layer = ProjectLayer(
    name: "Generated inpaint",
    content: .generatedInpaint(GeneratedInpaintLayerRecipe(
      source: assets.source.reference,
      generated: assets.generated.reference,
      analysis: assets.analysis.reference,
      frame: preparation.placementFrame,
      generation: generation)))
  let backing = ProjectLayer.raster(
    RasterLayerRecipe(asset: assets.source.reference, frame: preparation.placementFrame))
  var project = ProjectRecipe()
  project.layerStack = LayerStackRecipe(
    layers: [layer, backing, .canvasBase(CanvasRecipe(width: 2, height: 1))],
    activeLayerID: layer.id)
  var payloads = Dictionary(uniqueKeysWithValues: assets.all.map {
    ($0.reference.id, $0.compressedPixels)
  })
  let before = try await engine.render(RenderRequest(
    documentID: documentID, revision: 1, input: nil,
    rasterAssets: payloads, recipe: project, quality: .full))
  let beforeColor = try #require(await engine.sampleLinearRGBAColor(
    in: before, source: .composite, atNormalizedX: 0.25, y: 0.5,
    sampleSize: .point))
  let firstCache = await engine.generatedInpaintCacheStatistics()
  #expect(firstCache.decodedBuilds == 1)
  #expect(firstCache.composedBuilds == 1)

  project = project.applying(.setGeneratedInpaintThreshold(layer.id, 50))
  let saved = try JSONEncoder().encode(project)
  let reopened = try JSONDecoder().decode(ProjectRecipe.self, from: saved)
  let edited = try #require(reopened.layerStack.layer(id: layer.id)?.generatedInpaintLayer)
  #expect(edited.changeThreshold == 50)
  #expect(edited.generation.inpainting?.changeThreshold == 0)
  #expect(edited.assetReferences.count == 3)
  let after = try await engine.render(RenderRequest(
    documentID: documentID, revision: 2, input: nil,
    rasterAssets: payloads, recipe: reopened, quality: .full))
  let afterColor = try #require(await engine.sampleLinearRGBAColor(
    in: after, source: .composite, atNormalizedX: 0.25, y: 0.5,
    sampleSize: .point))
  #expect(beforeColor.red > afterColor.red + 0.3)
  #expect(abs(afterColor.red - 0.25) < 0.05)
  let thresholdCache = await engine.generatedInpaintCacheStatistics()
  #expect(thresholdCache.decodedBuilds == 1)
  #expect(thresholdCache.composedBuilds == 2)

  // An unrelated render reuses the finished inpaint image, and replacing one
  // content-addressed asset invalidates both cache tiers.
  _ = try await engine.render(RenderRequest(
    documentID: documentID, revision: 3, input: nil,
    rasterAssets: payloads, recipe: reopened, quality: .full))
  let repeatedCache = await engine.generatedInpaintCacheStatistics()
  #expect(repeatedCache.decodedBuilds == 1)
  #expect(repeatedCache.composedBuilds == 2)
  #expect(repeatedCache.imageHits == 1)

  let replacementValues: [Float16] = [
    0.4, 0.4, 0.4, 1,
    1, 0, 0, 1,
  ]
  let replacement = try RasterAssetPayload.encode(
    replacementValues.withUnsafeBytes { Data($0) }, width: 2, height: 1)
  payloads[replacement.reference.id] = replacement.compressedPixels
  var changedAssets = reopened
  changedAssets.layerStack.updateLayer(id: layer.id) { layer in
    guard case .generatedInpaint(var inpaint) = layer.content else { return }
    inpaint.generated = replacement.reference
    layer.content = .generatedInpaint(inpaint)
  }
  _ = try await engine.render(RenderRequest(
    documentID: documentID, revision: 4, input: nil,
    rasterAssets: payloads, recipe: changedAssets, quality: .full))
  let replacedCache = await engine.generatedInpaintCacheStatistics()
  #expect(replacedCache.decodedBuilds == 2)
  #expect(replacedCache.composedBuilds == 3)

  await engine.clearCaches()
  _ = try await engine.render(RenderRequest(
    documentID: documentID, revision: 5, input: nil,
    rasterAssets: payloads, recipe: changedAssets, quality: .full))
  let clearedCache = await engine.generatedInpaintCacheStatistics()
  #expect(clearedCache.decodedBuilds == 3)
  #expect(clearedCache.composedBuilds == 4)

  let undone = reopened.applying(.setGeneratedInpaintThreshold(layer.id, 0))
  #expect(undone.layerStack.layer(id: layer.id)?.generatedInpaintLayer?.changeThreshold == 0)
  let clamped = reopened.applying(.setGeneratedInpaintThreshold(layer.id, 120))
  #expect(clamped.layerStack.layer(id: layer.id)?.generatedInpaintLayer?.changeThreshold == 100)
}

@MainActor
@Test func generatedInpaintLayerSavesAndReopensWithAllBackingAssets() throws {
  let source = try RasterAssetPayload.encode(
    [Float16(0.25), 0.25, 0.25, 1].withUnsafeBytes { Data($0) },
    width: 1, height: 1)
  let generated = try RasterAssetPayload.encode(
    [Float16(0.8), 0.8, 0.8, 1].withUnsafeBytes { Data($0) },
    width: 1, height: 1)
  let analysis = try RasterAssetPayload.encode(
    [Float(25), 1].withUnsafeBytes { Data($0) },
    width: 1, height: 1,
    pixelFormat: RasterAssetReference.inpaintAnalysisPixelFormat,
    colorSpace: "none")
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: UUID().uuidString, contentRevision: 1, capture: .composite),
    mask: .selectingAll,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .white,
    usesFullOutputMask: true)
  let generation = ComfyUIGenerationRecipe(
    templateID: "flux2-klein-inpaint-base", templateRevision: "test", promptID: "test",
    prompt: "edit", negativePrompt: "", seed: 1, steps: 8, guidance: 1,
    outputWidth: 1, outputHeight: 1, mode: .inpainting,
    inpainting: conditioning)
  let layer = ProjectLayer(
    name: "Generated inpaint",
    content: .generatedInpaint(GeneratedInpaintLayerRecipe(
      source: source.reference, generated: generated.reference,
      analysis: analysis.reference,
      frame: LayerFrame(x: 0, y: 0, width: 1, height: 1),
      generation: generation)))
  let document = ProjectDocument(canvas: CanvasRecipe(width: 1, height: 1))
  let undoManager = UndoManager()
  undoManager.groupsByEvent = false
  document.undoManager = undoManager
  let jobID = UUID()
  document.editorModel.setGenerationJobs([
    GenerationJob(id: jobID, prompt: "edit", sourceContentRevision: 1,
      state: .finalizing, templateID: "flux2-klein-inpaint-base")
  ])
  document.retainComfyUIResultForManualApplication(
    jobID: jobID,
    layer: layer,
    assets: [
      RasterBakeResult(reference: source.reference, compressedPixels: source.compressedPixels),
      RasterBakeResult(reference: generated.reference, compressedPixels: generated.compressedPixels),
      RasterBakeResult(reference: analysis.reference, compressedPixels: analysis.compressedPixels),
    ])
  undoManager.beginUndoGrouping()
  document.applyComfyUIResultAnyway(jobID: jobID)
  undoManager.endUndoGrouping()
  undoManager.beginUndoGrouping()
  document.perform(.setGeneratedInpaintThreshold(layer.id, 50), interactive: false)
  undoManager.endUndoGrouping()
  #expect(document.editorModel.recipe.layerStack.activeLayerID == layer.id)
  undoManager.undo()
  #expect(document.editorModel.recipe.layerStack.layer(id: layer.id)?
    .generatedInpaintLayer?.changeThreshold == 0)
  undoManager.redo()
  #expect(document.editorModel.recipe.layerStack.layer(id: layer.id)?
    .generatedInpaintLayer?.changeThreshold == 50)

  let package = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  let files = try #require(package.fileWrappers?["Assets"]?.fileWrappers)
  #expect(files.count == 3)
  let reopened = ProjectDocument()
  try reopened.read(from: package, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()
  let savedLayer = try #require(
    reopened.editorModel.recipe.layerStack.layer(id: layer.id)?.generatedInpaintLayer)
  #expect(savedLayer.changeThreshold == 50)
  #expect(savedLayer.assetReferences.count == 3)
}

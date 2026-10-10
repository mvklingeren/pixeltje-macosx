import CoreImage
import Foundation
import Metal
import PixeltjeMacDomain
import PixeltjePipelineEngine
import Testing

@testable import PixeltjeMacKit

@Test func patchLayoutRoundTripsExactly() {
  let latent = (0..<(16 * 8 * 8)).map(Float.init)
  let tokens = ZImageCoreAIPipeline.patchify(latent, side: 8)
  let restored = ZImageCoreAIPipeline.unpatchify(tokens, side: 8)

  #expect(tokens.count == 4 * 4 * 64)
  #expect(restored == latent)
}

@Test func rectangularPatchLayoutRoundTripsExactly() {
  let width = 8
  let height = 6
  let latent = (0..<(16 * width * height)).map(Float.init)
  let tokens = ZImageCoreAIPipeline.patchify(latent, width: width, height: height)
  let restored = ZImageCoreAIPipeline.unpatchify(tokens, width: width, height: height)

  #expect(tokens.count == 4 * 3 * 64)
  #expect(restored == latent)
}

@Test func seededNoiseIsDeterministicAndSeedSensitive() {
  let first = ZImageCoreAIPipeline.noise(count: 128, seed: 7)
  let repeated = ZImageCoreAIPipeline.noise(count: 128, seed: 7)
  let other = ZImageCoreAIPipeline.noise(count: 128, seed: 8)

  #expect(first == repeated)
  #expect(first != other)
  #expect(first.allSatisfy { $0.isFinite })
}

@Test func latentMaskDownsamplingAveragesCoverage() {
  let mask: [Float] = [
    1, 1, 0, 0,
    1, 1, 0, 0,
    0, 0, 0.5, 0.5,
    0, 0, 0.5, 0.5,
  ]
  #expect(
    ZImageCoreAIPipeline.downsampleMask(mask, sourceSide: 4, destinationSide: 2)
      == [1, 0, 0, 0.5])
}

@Test func rectangularLatentMaskDownsamplingAveragesCoverage() {
  let mask: [Float] = [
    1, 1, 0, 0,
    1, 1, 0, 0,
  ]
  #expect(
    ZImageCoreAIPipeline.downsampleMask(
      mask,
      sourceWidth: 4,
      sourceHeight: 2,
      destinationWidth: 2,
      destinationHeight: 1) == [1, 0])
}

@Test func finalCompositionPreservesEveryOutsideMaskPixelExactly() {
  let originalValues: [Float16] = [
    0.1, 0.2, 0.3, 1,
    0.4, 0.5, 0.6, 1,
    0.7, 0.8, 0.9, 1,
  ]
  let generatedValues: [Float16] = [
    1, 0, 0, 1,
    0, 1, 0, 1,
    0, 0, 1, 1,
  ]
  let original = originalValues.withUnsafeBytes { Data($0) }
  let generated = generatedValues.withUnsafeBytes { Data($0) }

  let result = RenderEngine.compositePixels(
    original: original, generated: generated, mask: [0, 1, 0.5])
  let output = result.pixels.withUnsafeBytes {
    Array($0.bindMemory(to: Float16.self))
  }

  #expect(result.outsideCount == 1)
  #expect(result.preservedCount == 1)
  #expect(Array(output[0..<4]) == Array(originalValues[0..<4]))
  #expect(Array(output[4..<8]) == Array(generatedValues[4..<8]))
  #expect(output[8] == Float16((Float(originalValues[8]) + Float(generatedValues[8])) / 2))
}

@Test func generationJobLifecycleReportsProgressAndCancellation() {
  let running = GenerationJobState.denoising(step: 3, total: 8)
  #expect(running.isActive)
  #expect(running.label == "Denoising 3 of 8")
  #expect(GenerationJobState.preparing.label == "Preparing generation")
  #expect(!GenerationJobState.cancelled.isActive)
  #expect(GenerationJobState.cancelled.label == "Cancelled")
}

@Test func generatedOutputKeepsItsRequestedSizeAndCentersOnTheCanvas() {
  let smaller = RenderEngine.inpaintingOutputGeometry(
    sourceWidth: 1600,
    sourceHeight: 900,
    outputWidth: 512,
    outputHeight: 512)
  #expect(smaller.outputBounds == CGRect(x: 0, y: 0, width: 512, height: 512))
  #expect(smaller.sourceOffset == CanvasOffset(x: -544, y: -194))
  #expect(smaller.placementFrame == LayerFrame(x: 544, y: 194, width: 512, height: 512))

  let larger = RenderEngine.inpaintingOutputGeometry(
    sourceWidth: 800,
    sourceHeight: 600,
    outputWidth: 1024,
    outputHeight: 1024)
  #expect(larger.sourceOffset == CanvasOffset(x: 112, y: 212))
  #expect(larger.placementFrame == LayerFrame(x: -112, y: -212, width: 1024, height: 1024))
}

@Test func inpaintingOutputFollowsAnOffCenterSelectionAndStaysInsideTheCanvas() {
  let left = RenderEngine.inpaintingOutputGeometry(
    sourceWidth: 1600,
    sourceHeight: 900,
    outputWidth: 512,
    outputHeight: 512,
    sourceFocus: CanvasOffset(x: 120, y: 450))
  #expect(left.sourceOffset == CanvasOffset(x: 0, y: -194))
  #expect(left.placementFrame == LayerFrame(x: 0, y: 194, width: 512, height: 512))

  let lowerRight = RenderEngine.inpaintingOutputGeometry(
    sourceWidth: 1600,
    sourceHeight: 900,
    outputWidth: 512,
    outputHeight: 512,
    sourceFocus: CanvasOffset(x: 1_500, y: 80))
  #expect(lowerRight.sourceOffset == CanvasOffset(x: -1088, y: 0))
  #expect(lowerRight.placementFrame == LayerFrame(x: 1088, y: 0, width: 512, height: 512))
}

@Test func comfyUIBroadInpaintingUsesTheWholeSourceWithinTheMaximumSize() {
  let entireOutput = RenderEngine.comfyUIInpaintingGeometry(
    sourceWidth: 1600,
    sourceHeight: 900,
    maximumWidth: 1024,
    maximumHeight: 1024,
    maskBounds: nil,
    usesFullOutputMask: true,
    alignment: 8)
  #expect(entireOutput.uploadBounds == CGRect(x: 0, y: 0, width: 1024, height: 576))
  #expect(
    entireOutput.placementFrame
      == LayerFrame(x: 0, y: 0, width: 1600, height: 900))

  let broadMask = RenderEngine.comfyUIInpaintingGeometry(
    sourceWidth: 1600,
    sourceHeight: 900,
    maximumWidth: 1024,
    maximumHeight: 1024,
    maskBounds: LayerFrame(x: 50, y: 50, width: 1500, height: 800),
    usesFullOutputMask: false,
    alignment: 8)
  #expect(broadMask == entireOutput)
}

@Test func comfyUISmallInpaintingMaskKeepsAFocusedPatch() {
  let geometry = RenderEngine.comfyUIInpaintingGeometry(
    sourceWidth: 1600,
    sourceHeight: 900,
    maximumWidth: 512,
    maximumHeight: 512,
    maskBounds: LayerFrame(x: 1400, y: 20, width: 100, height: 100),
    usesFullOutputMask: false,
    alignment: 8)

  #expect(geometry.uploadBounds == CGRect(x: 0, y: 0, width: 512, height: 512))
  #expect(geometry.placementFrame == LayerFrame(x: 1088, y: 0, width: 512, height: 512))
}

@Test func transparentSourceBackgroundMapsIntoModelInputRange() {
  #expect(
    RenderEngine.modelInputValue(
      premultipliedSource: 0, alpha: 0, transparentPixelBackground: .white) == 1)
  #expect(
    RenderEngine.modelInputValue(
      premultipliedSource: 0, alpha: 0, transparentPixelBackground: .gray) == 0)
  #expect(
    RenderEngine.modelInputValue(
      premultipliedSource: 0, alpha: 0, transparentPixelBackground: .black) == -1)
  #expect(
    RenderEngine.modelInputValue(
      premultipliedSource: 0.25, alpha: 1, transparentPixelBackground: .white) == -0.5)
}

@MainActor
@Test func noSelectionUsesTheFullCanvasAsTheGenerationMask() throws {
  let document = ProjectDocument()

  #expect(document.editorModel.generationMode == .textToImage)
  #expect(document.editorModel.recipe.selection == nil)
  let mask = document.effectiveGenerationMask
  let component = try #require(mask.components.first)
  guard case .rectangle(let rectangle) = component.generator else {
    Issue.record("The implicit full-canvas mask is not a rectangle.")
    return
  }
  #expect(rectangle.origin == VectorPoint(x: 0, y: 0))
  #expect(rectangle.width == 1)
  #expect(rectangle.height == 1)
}

@MainActor
@Test func anEnabledRasterLayerSwitchesGenerationToInpainting() {
  let asset = RasterAssetReference(
    id: RasterAssetID(rawValue: "source"),
    width: 2,
    height: 2,
    uncompressedByteCount: 32)
  let layer = ProjectLayer.raster(
    RasterLayerRecipe(
      asset: asset,
      frame: LayerFrame(x: 0, y: 0, width: 2, height: 2)))
  var recipe = ProjectRecipe()
  recipe.layerStack = recipe.layerStack.adding(layer)

  #expect(EditorModel(recipe: recipe).generationMode == .inpainting)
}

@Test func textToImageIdentityDoesNotClaimToUseTheVAEEncoder() {
  let textToImage = ZImageCoreAIPipeline.modelIdentity(for: .textToImage)
  let inpainting = ZImageCoreAIPipeline.modelIdentity(for: .inpainting)

  #expect(!textToImage.functions.contains { $0.role == "vaeEncoder" })
  #expect(inpainting.functions.contains { $0.role == "vaeEncoder" })
}

@Test func generationUsesTheRequestedNativeResolution() throws {
  let square512 = try #require(
    ZImageCoreAIPipeline.modelResolution(outputWidth: 512, outputHeight: 512))
  let square768 = try #require(
    ZImageCoreAIPipeline.modelResolution(outputWidth: 768, outputHeight: 768))
  let landscape = try #require(
    ZImageCoreAIPipeline.modelResolution(outputWidth: 1280, outputHeight: 720))

  #expect(square512.width == 512)
  #expect(square768.width == 768)
  #expect(landscape.width == 1280)
  #expect(landscape.height == 720)
  #expect(ZImageCoreAIPipeline.modelResolution(outputWidth: 500, outputHeight: 512) == nil)
  #expect(ZImageCoreAIPipeline.modelResolution(outputWidth: 513, outputHeight: 512) == nil)

  let identity = ZImageCoreAIPipeline.modelIdentity(
    for: .textToImage,
    resolution: landscape)
  let decoder = try #require(identity.functions.first { $0.role == "vaeDecoder" })
  #expect(decoder.packageName == "zimage_vae_1280x720_fp32.aimodel")
  #expect(!identity.functions.contains { $0.role == "vaeEncoder" })
}

@MainActor
@Test func selectionOnlyEditKeepsTheRenderedPixelRevisionUsableForGeneration() {
  let document = ProjectDocument()
  let renderedRevision = document.currentRenderRevision

  document.selectAll()

  #expect(document.currentRenderRevision == renderedRevision)
  #expect(document.accepts(documentID: document.projectID, revision: renderedRevision))
}

@Test func blankCanvasCanBeMaterializedAsGenerationSourceOnDemand() async throws {
  guard let engine = try? RenderEngine() else { return }
  let documentID = UUID()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 48)

  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 1,
      input: nil,
      recipe: recipe,
      quality: .full))

  #expect(frame.documentID == documentID)
  #expect(frame.contentRevision == 1)
  #expect(frame.width == 64)
  #expect(frame.height == 48)
}

@Test func comfyUIConditioningPreparesPNGsAndPreservesOutsideMaskPixels() async throws {
  guard let engine = try? RenderEngine() else { return }
  let documentID = UUID()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 16, height: 16)
  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 3,
      input: nil,
      recipe: recipe,
      quality: .full))
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 3,
      capture: .composite),
    mask: .single(
      .rectangle(
        ShapeMask(origin: VectorPoint(x: 0, y: 0), width: 0.5, height: 1))),
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .black,
    usesFullOutputMask: false)

  let preparation = try await engine.prepareComfyUIInpainting(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 16,
    outputHeight: 16)
  #expect(preparation.sourcePNG.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  #expect(preparation.maskPNG.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  #expect(preparation.maskCoverage.contains(0))
  #expect(preparation.maskCoverage.contains(where: { $0 > 0 }))
  let sourceBytes = try rgba8Pixels(from: preparation.sourcePNG, width: 16, height: 16)
  let maskBytes = try rgba8Pixels(from: preparation.maskPNG, width: 16, height: 16)
  #expect(stride(from: 3, to: sourceBytes.count, by: 4).allSatisfy { sourceBytes[$0] == 255 })
  for pixel in preparation.maskCoverage.indices {
    // ComfyUI's LoadImage mask output is one minus PNG alpha.
    let decodedCoverage = 1 - Float(maskBytes[pixel * 4 + 3]) / 255
    #expect(abs(decodedCoverage - preparation.maskCoverage[pixel]) <= 1.0 / 255.0 + 0.0001)
  }

  let result = try await engine.finishComfyUIInpainting(
    imageData: preparation.sourcePNG,
    preparation: preparation)
  #expect(result.raster.reference.width == 16)
  #expect(result.raster.reference.height == 16)
  #expect(result.outsideMaskPixelCount > 0)
  #expect(result.preservedOutsideMaskPixelCount == result.outsideMaskPixelCount)
}

@Test func comfyUIAutomaticInpaintingUsesCompositeTransparencyAsTheMask() async throws {
  guard let engine = try? RenderEngine() else { return }
  let width = 16
  let height = 16
  var values = [Float16](repeating: 0, count: width * height * 4)
  for y in 0..<height {
    for x in 0..<(width / 2) {
      let offset = (y * width + x) * 4
      values[offset] = 0.25
      values[offset + 1] = 0.5
      values[offset + 2] = 0.75
      values[offset + 3] = 1
    }
  }
  let payload = try RasterAssetPayload.encode(
    values.withUnsafeBytes { Data($0) }, width: width, height: height)
  let layer = ProjectLayer.raster(
    RasterLayerRecipe(
      asset: payload.reference,
      frame: LayerFrame(x: 0, y: 0, width: Double(width), height: Double(height))))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layer.id)
  recipe.layerStack.canvas = CanvasRecipe(width: width, height: height)
  let documentID = UUID()
  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 6,
      input: nil,
      rasterAssets: [payload.reference.id: payload.compressedPixels],
      recipe: recipe,
      quality: .full))
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 6,
      capture: .composite),
    mask: .selectingAll,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .white,
    usesFullOutputMask: false,
    requestedMaskSource: GenerationMaskSource(kind: .automatic),
    resolvedMaskSource: GenerationMaskSource(kind: .transparentPixels))

  let preparation = try await engine.prepareComfyUIInpainting(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: width,
    outputHeight: height)

  for y in 0..<height {
    for x in 0..<width {
      let coverage = preparation.maskCoverage[y * width + x]
      if x < width / 2 {
        #expect(coverage == 0)
      } else {
        #expect(coverage > 0.99)
      }
    }
  }
  let sourceBytes = try rgba8Pixels(
    from: preparation.sourcePNG, width: width, height: height)
  let maskBytes = try rgba8Pixels(
    from: preparation.maskPNG, width: width, height: height)
  for y in 0..<height {
    for x in 0..<width {
      let offset = (y * width + x) * 4
      #expect(sourceBytes[offset + 3] == 255)
      #expect(maskBytes[offset + 3] == (x < width / 2 ? 255 : 0))
      if x >= width / 2 {
        #expect(sourceBytes[offset] == 255)
        #expect(sourceBytes[offset + 1] == 255)
        #expect(sourceBytes[offset + 2] == 255)
      }
    }
  }
}

@Test func comfyUIMaskExpansionGrowsOnlyTheUploadedTransportMask() async throws {
  guard let engine = try? RenderEngine(observesMemoryPressure: false) else { return }
  let width = 32
  let height = 32
  var values = [Float16](repeating: 0, count: width * height * 4)
  for pixel in 0..<(width * height) {
    values[pixel * 4] = 0.2
    values[pixel * 4 + 1] = 0.4
    values[pixel * 4 + 2] = 0.6
    values[pixel * 4 + 3] = 1
  }
  for y in 14..<18 {
    for x in 14..<18 {
      let offset = (y * width + x) * 4
      values[offset] = 0
      values[offset + 1] = 0
      values[offset + 2] = 0
      values[offset + 3] = 0
    }
  }
  let payload = try RasterAssetPayload.encode(
    values.withUnsafeBytes { Data($0) }, width: width, height: height)
  let layer = ProjectLayer.raster(
    RasterLayerRecipe(
      asset: payload.reference,
      frame: LayerFrame(x: 0, y: 0, width: Double(width), height: Double(height))))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layer.id)
  recipe.layerStack.canvas = CanvasRecipe(width: width, height: height)
  let documentID = UUID()
  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 12,
      input: nil,
      rasterAssets: [payload.reference.id: payload.compressedPixels],
      recipe: recipe,
      quality: .full))

  func preparation(expandsMask: Bool) async throws -> ComfyUIInpaintingPreparation {
    let conditioning = ComfyUIInpaintingConditioningRecipe(
      source: GenerationSourceIdentity(
        documentID: documentID.uuidString,
        contentRevision: 12,
        capture: .composite),
      mask: .selectingAll,
      strength: 0.8,
      maskFeatherPixels: 0,
      transparentPixelBackground: .white,
      expandMaskForComfyUI: expandsMask,
      usesFullOutputMask: false,
      requestedMaskSource: GenerationMaskSource(kind: .transparentPixels),
      resolvedMaskSource: GenerationMaskSource(kind: .transparentPixels))
    return try await engine.prepareComfyUIInpainting(
      sourceFrame: frame,
      conditioning: conditioning,
      outputWidth: width,
      outputHeight: height)
  }

  let original = try await preparation(expandsMask: false)
  let expanded = try await preparation(expandsMask: true)
  #expect(expanded.maskCoverage == original.maskCoverage)

  let originalMask = try rgba8Pixels(
    from: original.maskPNG, width: width, height: height)
  let expandedMask = try rgba8Pixels(
    from: expanded.maskPNG, width: width, height: height)
  func alpha(_ pixels: [UInt8], x: Int, y: Int) -> UInt8 {
    pixels[(y * width + x) * 4 + 3]
  }

  #expect(original.maskCoverage[16 * width + 12] == 0)
  #expect(original.maskCoverage[16 * width + 15] > 0.99)
  #expect(alpha(originalMask, x: 12, y: 16) == 255)
  #expect(alpha(expandedMask, x: 12, y: 16) == 0)
  #expect(alpha(expandedMask, x: 2, y: 16) == 255)
}

@Test func comfyUITransparentPixelsKeepAnOffCenterVerticalHoleInsideTheFocusedPatch() async throws {
  guard let engine = try? RenderEngine(observesMemoryPressure: false) else { return }
  let width = 32
  let height = 96
  var values = [Float16](repeating: 0, count: width * height * 4)
  for pixel in 0..<(width * height) {
    values[pixel * 4] = 0.25
    values[pixel * 4 + 1] = 0.5
    values[pixel * 4 + 2] = 0.75
    values[pixel * 4 + 3] = 1
  }
  // Raster buffers are top-down. These rows become an off-centre transparent
  // hole near the top of the bottom-left Core Image coordinate space.
  for row in 4..<12 {
    for x in 8..<24 {
      let offset = (row * width + x) * 4
      values[offset] = 0
      values[offset + 1] = 0
      values[offset + 2] = 0
      values[offset + 3] = 0
    }
  }
  let payload = try RasterAssetPayload.encode(
    values.withUnsafeBytes { Data($0) }, width: width, height: height)
  let layer = ProjectLayer.raster(
    RasterLayerRecipe(
      asset: payload.reference,
      frame: LayerFrame(x: 0, y: 0, width: Double(width), height: Double(height))))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [layer], activeLayerID: layer.id)
  recipe.layerStack.canvas = CanvasRecipe(width: width, height: height)
  let documentID = UUID()
  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 9,
      input: nil,
      rasterAssets: [payload.reference.id: payload.compressedPixels],
      recipe: recipe,
      quality: .full))
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 9,
      capture: .composite),
    mask: .selectingAll,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .white,
    usesFullOutputMask: false,
    requestedMaskSource: GenerationMaskSource(kind: .transparentPixels),
    resolvedMaskSource: GenerationMaskSource(kind: .transparentPixels))

  let preparation = try await engine.prepareComfyUIInpainting(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 32,
    outputHeight: 32)

  #expect(preparation.placementFrame == LayerFrame(x: 0, y: 64, width: 32, height: 32))
  #expect(preparation.maskCoverage[6 * width + 12] > 0.99)
  #expect(preparation.maskCoverage[20 * width + 12] == 0)
  let maskBytes = try rgba8Pixels(
    from: preparation.maskPNG, width: preparation.width, height: preparation.height)
  #expect(maskBytes[3] == 255)
  #expect(maskBytes[(6 * width + 12) * 4 + 3] == 0)
}

@Test func comfyUIConditioningKeepsAnOffCenterSelectionInsideItsPatch() async throws {
  guard let engine = try? RenderEngine() else { return }
  let documentID = UUID()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 32)
  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 4,
      input: nil,
      recipe: recipe,
      quality: .full))
  let selection = MaskRecipe.single(
    .rectangle(
      ShapeMask(origin: VectorPoint(x: 0, y: 0.25), width: 0.125, height: 0.5)))
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 4,
      capture: .composite),
    mask: selection,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .black,
    usesFullOutputMask: false)

  let preparation = try await engine.prepareComfyUIInpainting(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 16,
    outputHeight: 16)

  #expect(preparation.placementFrame == LayerFrame(x: 0, y: 8, width: 16, height: 16))
  #expect(preparation.maskCoverage.contains(where: { $0 > 0 }))
}

@Test func comfyUIEntireOutputRoundTripsAcrossTheFullCanvas() async throws {
  guard let engine = try? RenderEngine() else { return }
  let documentID = UUID()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 32)
  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 5,
      input: nil,
      recipe: recipe,
      quality: .full))
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 5,
      capture: .composite),
    mask: .selectingAll,
    strength: 0.8,
    maskFeatherPixels: 0,
    transparentPixelBackground: .black,
    usesFullOutputMask: true)

  let preparation = try await engine.prepareComfyUIInpainting(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 16,
    outputHeight: 16,
    imageAlignment: 8)

  #expect(preparation.width == 16)
  #expect(preparation.height == 8)
  #expect(preparation.compositeWidth == 64)
  #expect(preparation.compositeHeight == 32)
  #expect(preparation.placementFrame == LayerFrame(x: 0, y: 0, width: 64, height: 32))
  #expect(preparation.maskCoverage.count == 64 * 32)

  let result = try await engine.finishComfyUIInpainting(
    imageData: preparation.sourcePNG,
    preparation: preparation)
  #expect(result.raster.reference.width == 64)
  #expect(result.raster.reference.height == 32)
}

private func rgba8Pixels(from png: Data, width: Int, height: Int) throws -> [UInt8] {
  let image = try #require(CIImage(data: png))
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  pixels.withUnsafeMutableBytes { storage in
    guard let base = storage.baseAddress else { return }
    CIContext().render(
      image,
      toBitmap: base,
      rowBytes: width * 4,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      format: .RGBA8,
      colorSpace: colorSpace)
  }
  return pixels
}

private actor PreviewCollector {
  private(set) var steps: [Int] = []
  private(set) var lastPixelCount = 0

  func append(_ output: ZImageCoreAIPipeline.StepOutput) {
    steps.append(output.step)
    lastPixelCount = output.decodedRGB.count
  }
}

/// Opt-in because it specializes and loads roughly 20 GB of linked Core AI
/// graphs. The ordinary suite covers the deterministic host contract without
/// touching a user's model library.
@Test func linkedZImageCoreAIPackageRunsPromptDrivenImageConditioningWhenEnabled() async throws {
  guard ProcessInfo.processInfo.environment["PIXELTJE_RUN_COREAI_INTEGRATION"] == "1" else {
    return
  }
  let root =
    ProcessInfo.processInfo.environment["PIXELTJE_ZIMAGE_MODEL_PATH"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".pixeltje/models/z-image-turbo-coreai", isDirectory: true)
  let device = try #require(MTLCreateSystemDefaultDevice())
  let queue = try #require(device.makeCommandQueue())
  let pipeline = ZImageCoreAIPipeline(commandQueue: queue)
  let textResolution = try #require(
    ZImageCoreAIPipeline.modelResolution(outputWidth: 1024, outputHeight: 1024))
  #expect(
    try await pipeline.load(
      from: root,
      resolution: textResolution,
      mode: .textToImage) == .loaded)
  #expect(
    await pipeline.isLoaded(
      from: root,
      resolution: textResolution,
      mode: .textToImage))
  #expect(
    try await pipeline.load(
      from: root,
      resolution: textResolution,
      mode: .textToImage) == .reused)

  let textCollector = PreviewCollector()
  let textOutput = try await pipeline.textToImage(
    prompt: "a small red ceramic vase on a neutral studio background",
    negativePrompt: "text",
    seed: 7,
    steps: 1,
    guidance: 0,
    resolution: textResolution
  ) { step in
    await textCollector.append(step)
  }
  #expect(textOutput.count == 3 * 1024 * 1024)
  #expect(textOutput.allSatisfy { $0.isFinite })
  #expect(await textCollector.steps == [1])

  #expect(try await pipeline.load(from: root) == .loaded)

  let side = 512
  let plane = side * side
  var source = [Float](repeating: 0, count: plane * 3)
  for pixel in 0..<plane {
    let value = Float(pixel % side) / Float(side - 1) * 2 - 1
    source[pixel] = value
    source[plane + pixel] = 0
    source[plane * 2 + pixel] = -value
  }
  var mask = [Float](repeating: 0, count: plane)
  for y in 192..<320 {
    for x in 192..<320 { mask[y * side + x] = 1 }
  }
  let collector = PreviewCollector()
  let output = try await pipeline.inpaint(
    sourceRGB: source,
    mask: mask,
    prompt: "replace the selected square with a small red ceramic vase",
    negativePrompt: "text",
    seed: 7,
    steps: 1,
    guidance: 0,
    strength: 1
  ) { step in
    await collector.append(step)
  }

  #expect(output.count == plane * 3)
  #expect(output.allSatisfy { $0.isFinite })
  #expect(await collector.steps == [1])
  #expect(await collector.lastPixelCount == plane * 3)
}

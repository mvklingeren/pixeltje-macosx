import Foundation
import Metal
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@Test func rasterAssetPayloadIsLosslessAndRejectsCorruption() throws {
  let pixels = Data((0..<(4 * 3 * 8)).map { UInt8($0 % 251) })
  let encoded = try RasterAssetPayload.encode(pixels, width: 4, height: 3)
  #expect(
    try RasterAssetPayload.decode(
      encoded.compressedPixels, reference: encoded.reference) == pixels)

  var damaged = encoded.compressedPixels
  damaged[damaged.startIndex] ^= 0xff
  #expect(throws: PixeltjeMacError.self) {
    try RasterAssetPayload.decode(damaged, reference: encoded.reference)
  }
}

@MainActor
@Test func staleComfyUIResultIsRetainedUntilAppliedAsANewLayer() throws {
  let document = ProjectDocument(canvas: CanvasRecipe(width: 64, height: 64))
  let jobID = UUID(uuidString: "C1C2C3C4-C5C6-C7C8-C9CA-CBCCCDCECFC0")!
  document.editorModel.setGenerationJobs([
    GenerationJob(
      id: jobID,
      prompt: "replace the selection",
      sourceContentRevision: 3,
      state: .finalizing,
      templateID: "flux2-klein-inpaint-base")
  ])
  let encoded = try RasterAssetPayload.encode(
    Data(repeating: 0, count: 2 * 2 * 8), width: 2, height: 2)
  let layer = ProjectLayer(
    name: "Generated — replace the selection",
    content: .raster(
      RasterLayerRecipe(
        asset: encoded.reference,
        frame: LayerFrame(x: 7, y: 11, width: 2, height: 2))))

  document.retainComfyUIResultForManualApplication(
    jobID: jobID,
    layer: layer,
    assets: [RasterBakeResult(
      reference: encoded.reference,
      compressedPixels: encoded.compressedPixels)])

  #expect(!document.editorModel.recipe.layerStack.layers.contains(where: { $0.id == layer.id }))
  #expect(document.editorModel.generationJobs.first?.canApplyAnyway == true)
  guard case .failed(let message) = document.editorModel.generationJobs.first?.state else {
    Issue.record("Expected the retained result to be a recoverable failed job")
    return
  }
  #expect(message.contains("Apply Anyway"))

  document.applyComfyUIResultAnyway(jobID: jobID)

  #expect(document.editorModel.recipe.layerStack.layers.contains(where: { $0.id == layer.id }))
  #expect(document.editorModel.recipe.layerStack.activeLayerID == layer.id)
  #expect(document.editorModel.generationJobs.first?.state == .succeeded)
  #expect(document.editorModel.generationJobs.first?.canApplyAnyway == false)
}

@MainActor
@Test func projectOpenRejectsMissingOrDamagedRasterAssets() throws {
  let pixels = Data(repeating: 0x5a, count: 2 * 3 * 8)
  let encoded = try RasterAssetPayload.encode(pixels, width: 2, height: 3)
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [
      .raster(
        RasterLayerRecipe(
          asset: encoded.reference,
          frame: LayerFrame(x: 0, y: 0, width: 2, height: 3))),
      .canvasBase(CanvasRecipe(width: 2, height: 3)),
    ]
  )
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let projectJSON = FileWrapper(regularFileWithContents: try encoder.encode(recipe))

  let missing = FileWrapper(directoryWithFileWrappers: ["project.json": projectJSON])
  #expect(throws: PixeltjeMacError.self) {
    try ProjectDocument().read(
      from: missing, ofType: ProjectDocument.projectTypeIdentifier)
  }

  var damagedPixels = encoded.compressedPixels
  damagedPixels[damagedPixels.startIndex] ^= 0xff
  let damaged = FileWrapper(directoryWithFileWrappers: [
    "project.json": FileWrapper(regularFileWithContents: try encoder.encode(recipe)),
    "Assets": FileWrapper(directoryWithFileWrappers: [
      "\(encoded.reference.id.rawValue).pixa": FileWrapper(
        regularFileWithContents: damagedPixels)
    ]),
  ])
  #expect(throws: PixeltjeMacError.self) {
    try ProjectDocument().read(
      from: damaged, ofType: ProjectDocument.projectTypeIdentifier)
  }
}

private func filledVectorLayer(id: ProjectLayerID) -> ProjectLayer {
  ProjectLayer(
    id: id,
    name: "Vector",
    content: .vector(
      VectorLayer(objects: [
        .path(
          .shape(
            .rectangle,
            from: VectorPoint(x: 0.2, y: 0.2),
            to: VectorPoint(x: 0.8, y: 0.8),
            stroke: nil,
            fill: VectorFillStyle(color: VectorColor(red: 0.8, green: 0.2, blue: 0.1))
          ))
      ]))
  )
}

@Test func bakedVectorRasterMatchesTheVisibleVectorPixels() async throws {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let engine = try RenderEngine(observesMemoryPressure: false)
  let id = ProjectLayerID(rawValue: "vector-to-raster")
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [filledVectorLayer(id: id), .canvasBase(CanvasRecipe(width: 32, height: 24))],
    activeLayerID: id)
  let request = RenderRequest(
    documentID: UUID(), revision: 1, input: nil, recipe: recipe, quality: .full)
  let before = try await engine.render(request)
  let baked = try await engine.bakeRaster(request)

  let raster = RasterLayerRecipe(
    asset: baked.reference,
    frame: LayerFrame(x: 0, y: 0, width: 32, height: 24))
  recipe.layerStack = recipe.layerStack.rasterizing(id, as: raster)
  let after = try await engine.render(
    RenderRequest(
      documentID: request.documentID,
      revision: 2,
      input: nil,
      rasterAssets: [baked.reference.id: baked.compressedPixels],
      recipe: recipe,
      quality: .full))

  let vectorColor = await engine.sampleLinearRGBAColor(
    in: before, source: .composite, atNormalizedX: 0.5, y: 0.5, sampleSize: .point)
  let rasterColor = await engine.sampleLinearRGBAColor(
    in: after, source: .composite, atNormalizedX: 0.5, y: 0.5, sampleSize: .point)
  let lhs = try #require(vectorColor)
  let rhs = try #require(rasterColor)
  #expect(abs(lhs.red - rhs.red) < 0.002)
  #expect(abs(lhs.green - rhs.green) < 0.002)
  #expect(abs(lhs.blue - rhs.blue) < 0.002)
}

@MainActor
@Test func documentRasterizationIsOneUndoableStepAndSavesItsAsset() async throws {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let document = ProjectDocument()
  let undoManager = UndoManager()
  undoManager.groupsByEvent = false
  document.undoManager = undoManager
  let id = ProjectLayerID(rawValue: "saved-raster")
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [filledVectorLayer(id: id), .canvasBase(CanvasRecipe(width: 16, height: 16))],
    activeLayerID: id)
  document.editorModel.replaceRecipe(recipe, historyName: "Raster Test")

  undoManager.beginUndoGrouping()
  document.rasterizeLayer(id)
  for _ in 0..<500 where document.editorModel.recipe.layerStack.layer(id: id)?.isRasterLayer != true
  {
    try await Task.sleep(for: .milliseconds(10))
  }
  undoManager.endUndoGrouping()

  #expect(document.editorModel.recipe.layerStack.layer(id: id)?.isRasterLayer == true)
  #expect(document.editorModel.history.currentStep.name == "Rasterize Layer")
  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  #expect(wrapper.fileWrappers?["Assets"]?.fileWrappers?.count == 1)

  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()
  #expect(reopened.editorModel.recipe == document.editorModel.recipe)

  undoManager.undo()
  #expect(document.editorModel.recipe.layerStack.layer(id: id)?.isVectorLayer == true)
  undoManager.redo()
  #expect(document.editorModel.recipe.layerStack.layer(id: id)?.isRasterLayer == true)
}

@MainActor
@Test func documentMergeIsOneUndoableStepAndSavesItsAsset() async throws {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let document = ProjectDocument()
  let undoManager = UndoManager()
  undoManager.groupsByEvent = false
  document.undoManager = undoManager
  let firstID = ProjectLayerID(rawValue: "merge-first")
  let secondID = ProjectLayerID(rawValue: "merge-second")
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [
      filledVectorLayer(id: firstID),
      filledVectorLayer(id: secondID),
      .canvasBase(CanvasRecipe(width: 16, height: 16)),
    ],
    activeLayerID: firstID)
  document.editorModel.replaceRecipe(recipe, historyName: "Merge Test")

  undoManager.beginUndoGrouping()
  document.selectLayers([firstID, secondID])
  document.mergeLayers([firstID, secondID])
  for _ in 0..<500 where document.editorModel.recipe.layerStack.contentLayers.count != 1 {
    try await Task.sleep(for: .milliseconds(10))
  }
  undoManager.endUndoGrouping()

  let merged = try #require(document.editorModel.recipe.layerStack.contentLayers.first)
  #expect(merged.isRasterLayer)
  #expect(merged.name == "Merged Layers")
  #expect(document.editorModel.selectedLayerIDs == [merged.id])
  #expect(document.editorModel.history.currentStep.name == "Merge Layers")
  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  #expect(wrapper.fileWrappers?["Assets"]?.fileWrappers?.count == 1)

  undoManager.undo()
  #expect(document.editorModel.recipe.layerStack.layer(id: firstID)?.isVectorLayer == true)
  #expect(document.editorModel.recipe.layerStack.layer(id: secondID)?.isVectorLayer == true)
  undoManager.redo()
  #expect(document.editorModel.recipe.layerStack.contentLayers.first?.isRasterLayer == true)
}

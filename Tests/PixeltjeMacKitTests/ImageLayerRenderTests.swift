import CoreGraphics
import CoreImage
import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

/// Writes a solid red PNG so the render can be checked without a fixture file.
private func writeRedPNG(width: Int, height: Int) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-image-layer-\(UUID().uuidString).png")
  let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
  try CIContext().writePNGRepresentation(
    of: image,
    to: url,
    format: .RGBA8,
    colorSpace: try #require(CGColorSpace(name: CGColorSpace.sRGB))
  )
  return url
}

private func samples(_ frame: RenderedFrame, at point: CGPoint) -> [Float] {
  var pixel = [Float](repeating: 0, count: 4)
  let image = CIImage(
    ioSurface: frame.surface,
    options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any]
  )
  CIContext().render(
    image,
    toBitmap: &pixel,
    rowBytes: 16,
    bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
    format: .RGBAf,
    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
  )
  return pixel
}

private func solidVectorLayer(_ color: VectorColor, zOrder: Int) -> ProjectLayer {
  let path = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0, y: 0)),
      VectorAnchor(position: VectorPoint(x: 1, y: 0)),
      VectorAnchor(position: VectorPoint(x: 1, y: 1)),
      VectorAnchor(position: VectorPoint(x: 0, y: 1)),
    ],
    isClosed: true,
    stroke: nil,
    fill: VectorFillStyle(color: color))
  return ProjectLayer(
    name: "Vector",
    isEnabled: true,
    isLocked: false,
    zOrder: zOrder,
    content: .vector(VectorLayer(objects: [.path(path)])))
}

@MainActor
@Test func placingAnImageRecordsItsLinkSizeAndFittedFrame() throws {
  let url = try writeRedPNG(width: 100, height: 50)
  defer { try? FileManager.default.removeItem(at: url) }

  let layer = try ImageLayerFactory.makeLayer(
    for: url,
    canvas: CanvasRecipe(width: 200, height: 100)
  )
  let image = try #require(layer.imageLayer)

  #expect(image.naturalWidth == 100)
  #expect(image.naturalHeight == 50)
  #expect(image.frame == LayerFrame(x: 50, y: 25, width: 100, height: 50))
  #expect(image.source.linkedPath == url.path)
  #expect(image.source.originalFilename == url.lastPathComponent)
  #expect(layer.name == url.lastPathComponent)
}

@MainActor
@Test func openingAnImageCreatesAnImageSizedDocumentWithOneLinkedLayer() throws {
  let url = try writeRedPNG(width: 100, height: 50)
  defer { try? FileManager.default.removeItem(at: url) }

  let document = try ProjectDocument(importingImage: url)
  let recipe = document.editorModel.recipe
  let layers = recipe.layerStack.contentLayers
  let image = try #require(layers.first?.imageLayer)

  #expect(document.fileType == ProjectDocument.projectTypeIdentifier)
  #expect(document.isDocumentEdited)
  #expect(recipe.source == nil)
  #expect(recipe.layerStack.canvas == CanvasRecipe(width: 100, height: 50))
  #expect(layers.count == 1)
  #expect(recipe.layerStack.activeLayerID == layers.first?.id)
  #expect(image.frame == LayerFrame(x: 0, y: 0, width: 100, height: 50))
  #expect(image.source.linkedPath == url.path)
}

@MainActor
@Test func applyingCropDefaultsToTheSelectedLayerAndKeepsTheSessionVisible() throws {
  let url = try writeRedPNG(width: 100, height: 50)
  defer { try? FileManager.default.removeItem(at: url) }

  let document = try ProjectDocument(importingImage: url)
  let layerID = try #require(document.editorModel.recipe.layerStack.activeLayerID)
  document.editorModel.setActiveTool(.crop)
  document.beginCropSession()
  #expect(document.editorModel.cropDraft?.target == .layer(layerID))

  let crop = CropRecipe(left: 0.2, bottom: 0.1, right: 0.8, top: 0.9)
  document.updateCropDraft(crop, interactive: false)
  document.commitCropDraft()

  #expect(document.editorModel.recipe.layerStack.layer(id: layerID)?.crop == crop)
  #expect(document.editorModel.cropDraft?.target == .layer(layerID))
  #expect(document.editorModel.cropDraft?.recipe == crop)
  #expect(document.editorModel.cropDraft?.revealsFullTarget == false)
}

@MainActor
@Test func aCanvasDocumentWithNoRawRendersItsPlacedImages() async throws {
  let url = try writeRedPNG(width: 100, height: 50)
  defer { try? FileManager.default.removeItem(at: url) }

  let canvas = CanvasRecipe(width: 200, height: 100)
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = canvas
  recipe = recipe.applying(
    .addImageLayer(try ImageLayerFactory.makeLayer(for: url, canvas: canvas))
  )

  let engine = try RenderEngine(observesMemoryPressure: false)
  let frame = try await engine.render(
    RenderRequest(
      documentID: UUID(),
      revision: 1,
      input: nil,
      recipe: recipe,
      quality: .full
    )
  )

  // The document is the canvas, whatever the placed image's own size is.
  #expect(frame.width == 200)
  #expect(frame.height == 100)
  #expect(frame.inspection == nil)

  // The image lands centered and opaque, and the canvas around it stays clear
  // so the checkerboard shows through.
  let center = samples(frame, at: CGPoint(x: 100, y: 50))
  #expect(center[3] > 0.99)
  #expect(center[0] > center[1])
  #expect(center[0] > center[2])
  #expect(samples(frame, at: CGPoint(x: 4, y: 4))[3] < 0.01)

  // A hidden image layer leaves nothing to render.
  let hiddenID = try #require(recipe.layerStack.layers.first?.id)
  let hidden = try await engine.render(
    RenderRequest(
      documentID: UUID(),
      revision: 2,
      input: nil,
      recipe: recipe.applying(.setLayerEnabled(hiddenID, false)),
      quality: .full
    )
  )
  #expect(samples(hidden, at: CGPoint(x: 100, y: 50))[3] < 0.01)
}

@MainActor
@Test func croppingAnImageLayerClipsOnlyThatLayersPixels() async throws {
  let url = try writeRedPNG(width: 100, height: 50)
  defer { try? FileManager.default.removeItem(at: url) }

  let canvas = CanvasRecipe(width: 100, height: 50)
  let image = try ImageLayerFactory.makeLayer(for: url, canvas: canvas)
  var recipe = ProjectRecipe(
    layerStack: LayerStackRecipe(
      layers: [image, .canvasBase(canvas)], activeLayerID: image.id)
  )
  recipe = recipe.applying(
    .setLayerCrop(
      image.id,
      CropRecipe(left: 0.5, bottom: 0, right: 1, top: 1),
      actionName: "Crop Layer"
    )
  )

  let engine = try RenderEngine(observesMemoryPressure: false)
  let frame = try await engine.render(
    RenderRequest(
      documentID: UUID(), revision: 1, input: nil,
      recipe: recipe, quality: .full)
  )

  // Cropping a layer preserves the document extent and does not stretch the
  // remaining pixels back across the layer's original frame.
  #expect(frame.width == 100)
  #expect(frame.height == 50)
  #expect(samples(frame, at: CGPoint(x: 25, y: 25))[3] < 0.01)
  #expect(samples(frame, at: CGPoint(x: 75, y: 25))[3] > 0.99)
}

@MainActor
@Test func erasingAnImageThroughItsAutomaticMaskRevealsTransparency() async throws {
  let url = try writeRedPNG(width: 64, height: 64)
  defer { try? FileManager.default.removeItem(at: url) }

  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  let image = try ImageLayerFactory.makeLayer(for: url, canvas: recipe.layerStack.canvas)
  recipe = recipe.applying(.addImageLayer(image))
  let maskID = MaskID(rawValue: "automatic-render-mask")
  let stroke = PaintStroke(
    seed: 19,
    mode: .erase,
    settings: BrushSettings(size: 16, hardness: 1, pressureResponse: 0),
    brush: BrushCatalog.preset(.hardRound).definition,
    samples: [BrushSample(x: 32, y: 32, pressure: 1)]
  )
  recipe = recipe.applying(.commitImageEraserStroke(image.id, maskID, stroke))

  let engine = try RenderEngine(observesMemoryPressure: false)
  let frame = try await engine.render(
    RenderRequest(
      documentID: UUID(),
      revision: 1,
      input: nil,
      recipe: recipe,
      quality: .full
    )
  )
  #expect(samples(frame, at: CGPoint(x: 32, y: 32))[3] < 0.01)
  #expect(samples(frame, at: CGPoint(x: 4, y: 4))[3] > 0.99)

  let blackMask = MaskRecipe.layerMask(revealsLayer: false, id: maskID)
  let inverted = recipe
    .applying(.setLayerMask(image.id, blackMask))
    .applying(.setLayerMaskInverted(image.id, true))
    .applying(.commitImageEraserStroke(image.id, maskID, stroke))
  let invertedFrame = try await engine.render(
    RenderRequest(
      documentID: UUID(),
      revision: 2,
      input: nil,
      recipe: inverted,
      quality: .full
    )
  )
  #expect(samples(invertedFrame, at: CGPoint(x: 32, y: 32))[3] < 0.01)
  #expect(samples(invertedFrame, at: CGPoint(x: 4, y: 4))[3] > 0.99)
}

@Test func vectorLayersObeyTheirPositionAmongRasterLayers() async throws {
  let url = try writeRedPNG(width: 32, height: 32)
  defer { try? FileManager.default.removeItem(at: url) }
  let canvas = CanvasRecipe(width: 32, height: 32)
  var image = try ImageLayerFactory.makeLayer(for: url, canvas: canvas)
  image.zOrder = 2
  let green = VectorColor(red: 0, green: 1, blue: 0)
  let engine = try RenderEngine(observesMemoryPressure: false)

  func rendered(vectorZ: Int, opacity: Double = 1) async throws -> [Float] {
    var vector = solidVectorLayer(green, zOrder: vectorZ)
    vector.opacity = opacity
    var recipe = ProjectRecipe()
    recipe.layerStack = LayerStack(
      layers: [image, vector, .canvasBase(canvas)], activeLayerID: vector.id)
    let frame = try await engine.render(
      RenderRequest(
        documentID: UUID(), revision: UInt64(vectorZ), input: nil,
        recipe: recipe, quality: .full))
    return samples(frame, at: CGPoint(x: 16, y: 16))
  }

  let below = try await rendered(vectorZ: 1)
  #expect(below[3] > 0.99 && below[0] > below[1] * 3)

  let above = try await rendered(vectorZ: 3)
  #expect(above[3] > 0.99 && above[1] > above[0] * 3)

  let faded = try await rendered(vectorZ: 3, opacity: 0.5)
  #expect(faded[0] > 0.4 && faded[1] > 0.4)
}

@MainActor
@Test func differenceKeyKeepsOriginalDetailOutsideAChangedRegion() async throws {
  let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
  let originalURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-difference-original-\(UUID().uuidString).png")
  let generatedURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-difference-generated-\(UUID().uuidString).png")
  defer {
    try? FileManager.default.removeItem(at: originalURL)
    try? FileManager.default.removeItem(at: generatedURL)
  }
  let originalBase = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
    .cropped(to: bounds)
  let watermark = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1))
    .cropped(to: CGRect(x: 26, y: 26, width: 12, height: 12))
  let original = watermark.composited(over: originalBase).cropped(to: bounds)
  let generated = CIImage(color: CIColor(red: 0.21, green: 0.39, blue: 0.59))
    .cropped(to: bounds)
  let context = CIContext()
  let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  try context.writePNGRepresentation(of: original, to: originalURL,
    format: .RGBA8, colorSpace: srgb)
  try context.writePNGRepresentation(of: generated, to: generatedURL,
    format: .RGBA8, colorSpace: srgb)

  let canvas = CanvasRecipe(width: 64, height: 64)
  var sourceLayer = try ImageLayerFactory.makeLayer(for: originalURL, canvas: canvas)
  sourceLayer.zOrder = 1
  var editLayer = try ImageLayerFactory.makeLayer(for: generatedURL, canvas: canvas)
  editLayer.zOrder = 2
  editLayer.compositing = LayerCompositing(blendMode: .differenceKey,
    differenceCutoff: 8, differenceSoftness: 4, differenceRadius: 3)
  let recipe = ProjectRecipe(layerStack: LayerStackRecipe(
    layers: [editLayer, sourceLayer, .canvasBase(canvas)], activeLayerID: editLayer.id))
  let engine = try RenderEngine(observesMemoryPressure: false)
  func render(_ value: ProjectRecipe, revision: UInt64) async throws -> RenderedFrame {
    try await engine.render(RenderRequest(documentID: UUID(), revision: revision,
      input: nil, recipe: value, quality: .full))
  }
  let keyed = try await render(recipe, revision: 1)
  let source = try await render(
    recipe.applying(.setLayerEnabled(editLayer.id, false)), revision: 2)
  let replacement = try await render(
    recipe.applying(.setLayerBlendMode(editLayer.id, .normal)), revision: 3)

  let quiet = samples(keyed, at: CGPoint(x: 8, y: 8))
  let originalQuiet = samples(source, at: CGPoint(x: 8, y: 8))
  let edited = samples(keyed, at: CGPoint(x: 32, y: 32))
  let generatedEdit = samples(replacement, at: CGPoint(x: 32, y: 32))
  #expect(zip(quiet, originalQuiet).allSatisfy { abs($0.0 - $0.1) < 0.005 })
  #expect(zip(edited, generatedEdit).allSatisfy { abs($0.0 - $0.1) < 0.02 })
}

@MainActor
@Test func differenceKeyCanUseFrozenInputAndSelectionCorrections() async throws {
  let bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
  let engine = try RenderEngine(observesMemoryPressure: false)
  func raster(_ color: CIColor) async throws -> RasterBakeResult {
    try await engine.importRaster(CIImage(color: color).cropped(to: bounds))
  }
  let original = try await raster(CIColor(red: 0, green: 0, blue: 1))
  let changedBackdrop = try await raster(CIColor(red: 1, green: 0, blue: 0))
  let assets = [
    original.reference.id: original.compressedPixels,
    changedBackdrop.reference.id: changedBackdrop.compressedPixels,
  ]
  let canvas = CanvasRecipe(width: 32, height: 32)
  let frame = LayerFrame(x: 0, y: 0, width: 32, height: 32)
  let base = ProjectLayer(name: "Changed backdrop", zOrder: 1,
    content: .raster(RasterLayerRecipe(asset: changedBackdrop.reference, frame: frame)))
  var edit = ProjectLayer(name: "Generated", zOrder: 2,
    content: .raster(RasterLayerRecipe(asset: original.reference, frame: frame,
      differenceSource: original.reference)))
  edit.compositing = LayerCompositing(blendMode: .differenceKey,
    differenceCutoff: 8, differenceSoftness: 4, differenceRadius: 0,
    differenceStructure: 0, differenceGrow: 0, differenceFeather: 0,
    differenceReference: .generationInput)

  func render(_ layer: ProjectLayer, preview: Bool = false) async throws -> RenderedFrame {
    let recipe = ProjectRecipe(layerStack: LayerStackRecipe(
      layers: [layer, base, .canvasBase(canvas)], activeLayerID: layer.id))
    var request = RenderRequest(documentID: UUID(), revision: 1, input: nil,
      rasterAssets: assets, recipe: recipe, quality: .full)
    if preview { request.differencePreviewLayerID = layer.id }
    return try await engine.render(request)
  }

  // sRGB red samples at about 0.82 in the linear Display P3 working space.
  let frozen = try await render(edit, preview: true)
  #expect(frozen.differencePreviewSurface != nil)
  #expect(samples(frozen, at: CGPoint(x: 16, y: 16))[0] > 0.8)
  var live = edit
  live.compositing.differenceReference = .currentBackdrop
  let liveFrame = try await render(live)
  #expect(samples(liveFrame, at: CGPoint(x: 16, y: 16))[2] > 0.9)

  edit.compositing.differenceRevealMask = .layerMask(revealsLayer: true)
  let revealed = try await render(edit)
  #expect(samples(revealed, at: CGPoint(x: 16, y: 16))[2] > 0.9)
  edit.compositing.differenceProtectMask = .layerMask(revealsLayer: true)
  let protected = try await render(edit)
  #expect(samples(protected, at: CGPoint(x: 16, y: 16))[0] > 0.8)
}

import CoreImage
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

private func creativeFrame(_ paint: PaintLayerRecipe, width: Int = 8, height: Int = 4) async throws -> RenderedFrame {
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: width, height: height)
  recipe = recipe.applying(.addLayer(.paint(paint)))
  let engine = try RenderEngine(observesMemoryPressure: false)
  return try await engine.render(RenderRequest(
    documentID: UUID(), revision: 1, input: nil, recipe: recipe, quality: .full))
}

private func creativePixel(_ frame: RenderedFrame, x: Int, y: Int) -> [Float] {
  let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  let image = CIImage(ioSurface: frame.surface, options: [.colorSpace: space])
  var values = [Float](repeating: 0, count: 4)
  CIContext(options: [.workingColorSpace: space]).render(
    image, toBitmap: &values, rowBytes: 16,
    bounds: CGRect(x: x, y: y, width: 1, height: 1),
    format: .RGBAf, colorSpace: space)
  return values
}

@Test func creativeDragUpdatesPreviewGeometryBeforeCommit() {
  var shape = CreativeDragState(
    start: VectorPoint(x: 0.1, y: 0.2),
    end: VectorPoint(x: 0.1, y: 0.2),
    editingLayerID: nil,
    movingStartHandle: nil)
  shape.update(to: VectorPoint(x: 0.7, y: 0.8))
  #expect(shape.start == VectorPoint(x: 0.1, y: 0.2))
  #expect(shape.end == VectorPoint(x: 0.7, y: 0.8))

  var gradientHandle = CreativeDragState(
    start: VectorPoint(x: 0.2, y: 0.3),
    end: VectorPoint(x: 0.8, y: 0.9),
    editingLayerID: ProjectLayerID(),
    movingStartHandle: true)
  gradientHandle.update(to: VectorPoint(x: 0.4, y: 0.5))
  #expect(gradientHandle.start == VectorPoint(x: 0.4, y: 0.5))
  #expect(gradientHandle.end == VectorPoint(x: 0.8, y: 0.9))
}

@Test func linearGradientRendersInTheLinearWorkingSpaceAndHonorsSelection() async throws {
  let leftHalf = MaskRecipe.selecting(
    .rectangle(ShapeMask(origin: .zero, width: 0.5, height: 1)))
  let gradient = PaintGradientRecipe(
    kind: .linear,
    start: VectorPoint(x: 0, y: 0.5), end: VectorPoint(x: 1, y: 0.5),
    startColor: LinearRGBAColor(red: 1, green: 0, blue: 0),
    endColor: LinearRGBAColor(red: 0, green: 0, blue: 1), coverage: leftHalf)
  let frame = try await creativeFrame(PaintLayerRecipe(gradients: [gradient]))
  let nearStart = creativePixel(frame, x: 0, y: 2)
  let middle = creativePixel(frame, x: 3, y: 2)
  let clipped = creativePixel(frame, x: 6, y: 2)
  #expect(nearStart[0] > nearStart[2])
  #expect(middle[0] > 0.4 && middle[2] > 0.3)
  #expect(clipped[3] < 0.01)
}

@Test func radialGradientHasStableCenterAndOuterEndpointColors() async throws {
  let gradient = PaintGradientRecipe(
    kind: .radial,
    start: VectorPoint(x: 0.5, y: 0.5), end: VectorPoint(x: 0.75, y: 0.5),
    startColor: LinearRGBAColor(red: 1, green: 0, blue: 0),
    endColor: LinearRGBAColor(red: 0, green: 0, blue: 1))
  let first = try await creativeFrame(
    PaintLayerRecipe(gradients: [gradient]), width: 16, height: 16)
  let replay = try await creativeFrame(
    PaintLayerRecipe(gradients: [gradient]), width: 16, height: 16)
  let center = creativePixel(first, x: 8, y: 8)
  let outside = creativePixel(first, x: 14, y: 8)

  #expect(center[0] > center[2])
  #expect(outside[2] > outside[0])
  #expect(zip(center, creativePixel(replay, x: 8, y: 8)).allSatisfy {
    abs($0 - $1) < 0.000_1
  })
}

@Test func fillReplaysCapturedRasterCoverageExactly() async throws {
  let raster = RasterMask(width: 4, height: 2, runs: [
    RasterMaskRun(y: 0, startX: 0, length: 2),
    RasterMaskRun(y: 1, startX: 0, length: 2),
  ])
  let fill = PaintFillRecipe(
    color: LinearRGBAColor(red: 1, green: 0, blue: 0),
    coverage: .single(.raster(raster)))
  let frame = try await creativeFrame(PaintLayerRecipe(fills: [fill]), width: 4, height: 2)
  let filled = creativePixel(frame, x: 1, y: 1)
  #expect(filled[3] > 0.99)
  #expect(filled[0] > filled[1] && filled[0] > filled[2])
  #expect(creativePixel(frame, x: 3, y: 1)[3] < 0.01)
}

@Test func capturedRasterReplaysSoftSelectionCoverage() async throws {
  let raster = RasterMask(width: 1, height: 1, runs: [
    RasterMaskRun(y: 0, startX: 0, length: 1, coverage: 128)
  ])
  let fill = PaintFillRecipe(color: .white, coverage: .single(.raster(raster)))
  let frame = try await creativeFrame(PaintLayerRecipe(fills: [fill]), width: 1, height: 1)
  let pixel = creativePixel(frame, x: 0, y: 0)
  #expect(
    abs(pixel[3] - Float(128) / 255) < 0.01,
    "Rendered alpha was \(pixel[3])")
}

@Test func renderedFrameCanBeCapturedAsAContiguousSharedMask() async throws {
  let selection = MaskRecipe.selecting(
    .rectangle(ShapeMask(origin: .zero, width: 0.5, height: 1)))
  let fill = PaintFillRecipe(color: .white, coverage: selection)
  let frame = try await creativeFrame(PaintLayerRecipe(fills: [fill]), width: 4, height: 2)
  let engine = try RenderEngine(observesMemoryPressure: false)
  let mask = try #require(try await engine.contiguousMask(
    in: frame, atNormalizedX: 0.1, y: 0.5, tolerance: 0))
  guard case .raster(let raster) = try #require(mask.components.first).generator else {
    Issue.record("Expected captured raster generator")
    return
  }
  #expect(raster.runs == [
    RasterMaskRun(y: 0, startX: 0, length: 2),
    RasterMaskRun(y: 1, startX: 0, length: 2),
  ])
}

@Test func largeRawSelectionCaptureUsesABoundedAspectFitProxy() {
  let source = (width: 8_256, height: 5_504)
  let bounded = RenderEngine.boundedMaskCaptureSize(
    width: source.width, height: source.height)

  #expect(bounded.width <= PaintOperationLimits.maximumRasterAxis)
  #expect(bounded.height <= PaintOperationLimits.maximumRasterAxis)
  #expect(bounded.width * bounded.height <= PaintOperationLimits.maximumRasterPixels)
  #expect(bounded.width <= 2_048)
  #expect(bounded.height <= 2_048)
  #expect(bounded.width * bounded.height <= PaintOperationLimits.maximumRasterRuns)
  #expect(bounded.width < source.width)
  #expect(abs(
    Double(bounded.width) / Double(bounded.height)
      - Double(source.width) / Double(source.height)) < 0.001)
}

@MainActor
@Test func creativeToolCommitsAreUndoableAndReopenAsRecipes() throws {
  let document = ProjectDocument()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  document.editorModel.replaceRecipe(recipe, historyName: "Creative Test")

  document.commitGradient(
    from: VectorPoint(x: 0.1, y: 0.2), to: VectorPoint(x: 0.9, y: 0.8))
  #expect(document.editorModel.recipe.layerStack.allLayers.contains {
    $0.paintLayer?.gradients.count == 1
  })
  document.undoManager?.undo()
  #expect(!document.editorModel.recipe.layerStack.allLayers.contains { $0.isPaintLayer })
  document.undoManager?.redo()

  document.editorModel.setFillTool(FillToolState(mode: .selection))
  document.applyFill(at: VectorPoint(x: 0.5, y: 0.5))
  #expect(document.editorModel.recipe.layerStack.allLayers.contains {
    $0.paintLayer?.fills.count == 1
  })
  document.undoManager?.undo()
  #expect(!document.editorModel.recipe.layerStack.allLayers.contains {
    $0.paintLayer?.fills.count == 1
  })
  document.undoManager?.redo()

  document.commitShape(
    from: VectorPoint(x: 0.2, y: 0.25),
    to: VectorPoint(x: 0.7, y: 0.75), constrained: false)
  // A drawn shape stays parametric, so it is an object rather than anchors.
  #expect(document.editorModel.recipe.layerStack.vectorArtwork.contains {
    $0.vectorLayer.objects.first?.shape?.kind == .rectangle(corners: .none)
  })

  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()
  #expect(reopened.editorModel.recipe == document.editorModel.recipe)
}

@MainActor
@Test func shapeCreationUsesTheCompleteSharedVectorAppearance() throws {
  let document = ProjectDocument()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  document.editorModel.replaceRecipe(recipe, historyName: "Shared Vector Style Test")

  let gradient = VectorGradient(
    kind: .radial,
    stops: [
      VectorGradientStop(
        color: VectorColor(red: 0.9, green: 0.2, blue: 0.1), position: 0),
      VectorGradientStop(
        color: VectorColor(red: 0.1, green: 0.3, blue: 0.9), position: 1),
    ],
    start: VectorPoint(x: 0.4, y: 0.4),
    end: VectorPoint(x: 0.7, y: 0.4),
    aspectRatio: 0.6,
    opacity: 0.7)
  let stroke = VectorStrokeStyle(
    color: VectorColor(red: 0.2, green: 0.8, blue: 0.4),
    width: 19,
    lineCap: .square,
    lineJoin: .bevel,
    miterLimit: 6,
    dashPattern: [8, 3],
    dashPhase: 2,
    alignment: .outside,
    opacity: 0.65,
    endArrowhead: VectorArrowhead(style: .triangle, scale: 4))
  var style = document.editorModel.vectorToolStyle
  style.setStroke(stroke)
  style.setFill(VectorFillStyle(gradient: gradient))
  document.editorModel.setVectorToolStyle(style)

  document.commitShape(
    from: VectorPoint(x: 0.2, y: 0.2),
    to: VectorPoint(x: 0.8, y: 0.8),
    constrained: false)
  let closed = try #require(
    document.editorModel.activeVectorLayer?.vector.objects.first?.shape)
  #expect(closed.stroke == stroke)
  #expect(closed.fill == VectorFillStyle(gradient: gradient))

  var lineState = document.editorModel.shapeTool
  lineState.kind = .line
  document.editorModel.setShapeTool(lineState)
  document.commitShape(
    from: VectorPoint(x: 0.1, y: 0.1),
    to: VectorPoint(x: 0.9, y: 0.9),
    constrained: false)
  let line = try #require(
    document.editorModel.activeVectorLayer?.vector.objects.first?.shape)
  #expect(line.kind == .line)
  #expect(line.stroke == stroke)
  #expect(line.fill == nil)

  // The line did not destroy the shared fill; switching back to a closed shape
  // restores the exact gradient as the next-object default.
  #expect(document.editorModel.vectorToolStyle.fill == VectorFillStyle(gradient: gradient))
}

@Test func vectorToolCapabilitiesFollowTheObjectBeingCreated() {
  #expect(VectorNextObject.path.hasClosedGeometry)
  #expect(VectorNextObject.path.hasOpenGeometry)
  #expect(VectorNextObject.shape(isClosed: true).hasClosedGeometry)
  #expect(!VectorNextObject.shape(isClosed: true).hasOpenGeometry)
  #expect(!VectorNextObject.shape(isClosed: false).hasClosedGeometry)
  #expect(VectorNextObject.shape(isClosed: false).hasOpenGeometry)
}

@MainActor
@Test func selectedVectorLayerColorChangeIsOneUndoableRecipeEdit() throws {
  let document = ProjectDocument()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  var vectorStack = recipe.layerStack
  let layerID = vectorStack.ensureActiveVectorLayer()
  vectorStack.appendPath(
    .shape(
      .rectangle,
      from: VectorPoint(x: 0.2, y: 0.25),
      to: VectorPoint(x: 0.7, y: 0.75)),
    to: layerID)
  recipe.layerStack = vectorStack
  document.editorModel.replaceRecipe(recipe, historyName: "Vector Color Test")
  let original = try #require(
    document.editorModel.recipe.layerStack.layer(id: layerID)?.content.vectorValue)
  let color = VectorColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 0.75)

  document.perform(
    .setVectorLayer(
      layerID, original.settingFillColor(color), actionName: "Change Vector Fill"),
    interactive: false)
  #expect(
    document.editorModel.recipe.layerStack.layer(id: layerID)?
      .content.vectorValue?.paths.first?.fill?.color == color)
  document.undoManager?.undo()
  #expect(
    document.editorModel.recipe.layerStack.layer(id: layerID)?.content.vectorValue == original)
}

@MainActor
@Test func everyDrawnShapeGetsItsOwnSelectedVectorLayer() throws {
  let document = ProjectDocument()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  var stack = recipe.layerStack
  let penLayerID = stack.ensureActiveVectorLayer()
  let penPath = VectorPath(
    name: "Pen Path",
    anchors: [VectorAnchor(position: VectorPoint(x: 0.1, y: 0.1))])
  stack.appendPath(penPath, to: penLayerID)
  recipe.layerStack = stack
  document.editorModel.replaceRecipe(recipe, historyName: "Shape Layer Test")

  document.commitShape(
    from: VectorPoint(x: 0.2, y: 0.2),
    to: VectorPoint(x: 0.6, y: 0.7), constrained: false)

  let firstShapeID = try #require(document.editorModel.recipe.layerStack.activeLayerID)
  #expect(firstShapeID != penLayerID)
  #expect(
    document.editorModel.recipe.layerStack.layer(id: penLayerID)?
      .content.vectorValue?.paths == [penPath])
  #expect(
    document.editorModel.recipe.layerStack.layer(id: firstShapeID)?
      .content.vectorValue?.objects.count == 1)
  #expect(document.editorModel.recipe.layerStack.layer(id: firstShapeID)?.name == "Rectangle")

  document.commitShape(
    from: VectorPoint(x: 0.3, y: 0.3),
    to: VectorPoint(x: 0.8, y: 0.8), constrained: false)
  let secondShapeID = try #require(document.editorModel.recipe.layerStack.activeLayerID)
  #expect(secondShapeID != firstShapeID)
  #expect(document.editorModel.recipe.layerStack.allLayers.filter(\.isVectorLayer).count == 3)
  #expect(
    document.editorModel.recipe.layerStack.layer(id: firstShapeID)?
      .content.vectorValue?.objects.count == 1)
}

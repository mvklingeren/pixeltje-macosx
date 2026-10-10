import CoreImage
import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

private enum MagnetSelectionTestFailure: Error {
  case expectedRaster
}

private func region(
  _ color: LinearRGBAColor,
  from x: Double,
  width: Double
) -> PaintFillRecipe {
  PaintFillRecipe(
    color: color,
    coverage: .selecting(
      .rectangle(ShapeMask(
        origin: VectorPoint(x: x, y: 0),
        width: width,
        height: 1))))
}

private func disconnectedColorRecipe() -> ProjectRecipe {
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 6, height: 1)
  let red = LinearRGBAColor(red: 1, green: 0, blue: 0)
  let blue = LinearRGBAColor(red: 0, green: 0, blue: 1)
  let paint = PaintLayerRecipe(fills: [
    region(red, from: 0, width: 2.0 / 6.0),
    region(blue, from: 2.0 / 6.0, width: 2.0 / 6.0),
    region(red, from: 4.0 / 6.0, width: 2.0 / 6.0),
  ])
  return recipe.applying(.addLayer(.paint(paint)))
}

private func layeredSampleRecipe() -> ProjectRecipe {
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 4, height: 1)
  let red = LinearRGBAColor(red: 1, green: 0, blue: 0)
  let green = LinearRGBAColor(red: 0, green: 1, blue: 0)
  let blue = LinearRGBAColor(red: 0, green: 0, blue: 1)
  let bottom = ProjectLayer.paint(PaintLayerRecipe(fills: [
    region(red, from: 0, width: 0.5),
    region(green, from: 0.5, width: 0.5),
  ]), name: "Split Background")
  var top = ProjectLayer.paint(
    PaintLayerRecipe(fills: [region(blue, from: 0, width: 1)]),
    name: "Blue Sample Layer")
  top.opacity = 0.5
  recipe = recipe.applying(.addLayer(bottom))
  return recipe.applying(.addLayer(top))
}

private func verticallySplitRecipe() -> ProjectRecipe {
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 1, height: 2)
  let bottom = PaintFillRecipe(
    color: LinearRGBAColor(red: 1, green: 0, blue: 0),
    coverage: .selecting(.rectangle(ShapeMask(
      origin: VectorPoint(x: 0, y: 0), width: 1, height: 0.5))))
  let top = PaintFillRecipe(
    color: LinearRGBAColor(red: 0, green: 0, blue: 1),
    coverage: .selecting(.rectangle(ShapeMask(
      origin: VectorPoint(x: 0, y: 0.5), width: 1, height: 0.5))))
  return recipe.applying(.addLayer(.paint(PaintLayerRecipe(fills: [bottom, top]))))
}

private func renderedFrame(
  for recipe: ProjectRecipe,
  documentID: UUID = UUID(),
  revision: UInt64 = 0,
  contentRevision: UInt64 = 0
) async throws -> RenderedFrame {
  let engine = try RenderEngine(observesMemoryPressure: false)
  return try await engine.render(RenderRequest(
    documentID: documentID,
    revision: revision,
    contentRevision: contentRevision,
    input: nil,
    recipe: recipe,
    quality: .full))
}

private func raster(in mask: MaskRecipe) throws -> RasterMask {
  let component = try #require(mask.components.first)
  guard case .raster(let raster) = component.generator else {
    Issue.record("Expected captured raster selection coverage")
    throw MagnetSelectionTestFailure.expectedRaster
  }
  return raster
}

private func selectedColumns(in raster: RasterMask) -> Set<Int> {
  Set(raster.runs.flatMap { run in
    run.coverage > 0 ? Array(run.startX..<(run.startX + run.length)) : []
  })
}

@Test func contiguousAndColorRangeHaveDistinctConnectivity() async throws {
  let frame = try await renderedFrame(for: disconnectedColorRecipe())
  let engine = try RenderEngine(observesMemoryPressure: false)

  let contiguous = try #require(try await engine.contiguousMask(
    in: frame,
    atNormalizedX: 0.1,
    y: 0.5,
    tolerance: 0,
    smoothness: 0))
  #expect(selectedColumns(in: try raster(in: contiguous)) == [0, 1])

  let colorRange = try #require(try await engine.colorRangeMask(
    in: frame,
    atNormalizedX: 0.1,
    y: 0.5,
    tolerance: 0,
    smoothness: 0))
  #expect(selectedColumns(in: try raster(in: colorRange)) == [0, 1, 4, 5])
}

@Test func repeatedMagnetClicksReusePixelValidFrameAndCombineSelections() throws {
  let documentID = UUID()

  // A selection-only recipe edit advances contentRevision but not the render
  // revision. Eligibility deliberately depends on pixel identity, so the same
  // displayed frame remains available for the next Magnet click.
  #expect(MagnetSelectionSupport.acceptsDisplayedFrame(
    documentID: documentID,
    renderRevision: 4,
    frameDocumentID: documentID,
    frameRevision: 4,
    frameIsProxy: false))
  #expect(!MagnetSelectionSupport.acceptsDisplayedFrame(
    documentID: documentID,
    renderRevision: 5,
    frameDocumentID: documentID,
    frameRevision: 4,
    frameIsProxy: false))
  #expect(!MagnetSelectionSupport.acceptsDisplayedFrame(
    documentID: documentID,
    renderRevision: 4,
    frameDocumentID: documentID,
    frameRevision: 4,
    frameIsProxy: true))

  let firstCapture = MaskRecipe.single(.raster(RasterMask(
    width: 6, height: 1,
    runs: [RasterMaskRun(y: 0, startX: 0, length: 2)])))
  let first = try #require(MagnetSelectionSupport.commit(
    captured: firstCapture,
    existing: nil,
    mode: .contiguous,
    combine: nil,
    feather: 3))
  #expect(first.actionName == "Magnet Selection")
  #expect(first.selection.components[0].name == "Contiguous")
  #expect(first.selection.components[0].feather == 3)

  let secondCapture = MaskRecipe.single(.raster(RasterMask(
    width: 6, height: 1,
    runs: [RasterMaskRun(y: 0, startX: 4, length: 2)])))
  let combined = try #require(MagnetSelectionSupport.commit(
    captured: secondCapture,
    existing: first.selection,
    mode: .contiguous,
    combine: .add,
    feather: 0))
  #expect(combined.actionName == "Add to Selection")
  #expect(combined.selection.components.count == 2)
  #expect(combined.selection.components[1].combine == .add)
  #expect(selectedColumns(in: try raster(in: MaskRecipe(
    components: [combined.selection.components[1]]))) == [4, 5])
}

@Test func magnetSelectionHonorsCompositeAndCurrentLayerSampling() async throws {
  let recipe = layeredSampleRecipe()
  let engine = try RenderEngine(observesMemoryPressure: false)
  let compositeFrame = try await renderedFrame(for: recipe)
  let composite = try #require(try await engine.colorRangeMask(
    in: compositeFrame,
    atNormalizedX: 0.1,
    y: 0.5,
    tolerance: 0,
    smoothness: 0))
  #expect(selectedColumns(in: try raster(in: composite)) == [0, 1])

  let activeLayer = try #require(try await engine.colorRangeMask(
    in: compositeFrame,
    source: .activeLayer,
    atNormalizedX: 0.1,
    y: 0.5,
    tolerance: 0,
    smoothness: 0))
  #expect(selectedColumns(in: try raster(in: activeLayer)) == [0, 1, 2, 3])
}

@Test func magnetSelectionKeepsBottomLeftDocumentOrientation() async throws {
  let frame = try await renderedFrame(for: verticallySplitRecipe())
  let engine = try RenderEngine(observesMemoryPressure: false)

  let bottom = try #require(try await engine.contiguousMask(
    in: frame,
    atNormalizedX: 0.5,
    y: 0.25,
    tolerance: 0,
    smoothness: 0))
  #expect(try raster(in: bottom).runs.map(\.y) == [0])

  let top = try #require(try await engine.contiguousMask(
    in: frame,
    atNormalizedX: 0.5,
    y: 0.75,
    tolerance: 0,
    smoothness: 0))
  #expect(try raster(in: top).runs.map(\.y) == [1])
}

@Test func capturedRasterOutlineTracesTheExteriorInsteadOfEveryRunRectangle() throws {
  let raster = RasterMask(
    width: 8,
    height: 8,
    runs: (0..<8).map { RasterMaskRun(y: $0, startX: 0, length: 8) })
  let selection = MaskRecipe.single(.raster(raster))
  let path = try #require(SelectionGeometry.path(
    for: selection,
    in: CGRect(x: 0, y: 0, width: 80, height: 80)))

  var lineCount = 0
  path.applyWithBlock { element in
    if element.pointee.type == .addLineToPoint { lineCount += 1 }
  }
  #expect(lineCount == 4)
  #expect(path.contains(CGPoint(x: 40, y: 40)))
}

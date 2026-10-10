import Foundation
import PixeltjeMacDomain
import Testing

@Test func contiguousFillKeepsOnlyTheConnectedMatchingRegion() throws {
  let red = LinearRGBAColor(red: 1, green: 0, blue: 0)
  let blue = LinearRGBAColor(red: 0, green: 0, blue: 1)
  // The last red pixel is separated from the first region by blue pixels.
  let pixels = [red, red, blue, red, red, blue, blue, red]
  let mask = try #require(ContiguousRegionBuilder.mask(
    width: 4, height: 2, pixels: pixels, seedX: 0, seedY: 0, tolerance: 0
  ))
  #expect(mask.runs == [RasterMaskRun(y: 0, startX: 0, length: 2), RasterMaskRun(y: 1, startX: 0, length: 1)])
  #expect(mask == ContiguousRegionBuilder.mask(
    width: 4, height: 2, pixels: pixels, seedX: 0, seedY: 0, tolerance: 0))
}

@Test func colorRangeSelectsDisconnectedMatchingPixels() throws {
  // Red at x=0 and x=2 is separated by blue, but Color Range is deliberately
  // global rather than flood-connected.
  let pixels: [Float] = [
    1, 0, 0, 1,
    0, 0, 1, 1,
    1, 0, 0, 1,
  ]
  let mask = try #require(ColorRangeRegionBuilder.mask(
    width: 3, height: 1, premultipliedRGBA: pixels,
    seedX: 0, seedY: 0, tolerance: 0, smoothness: 0))
  #expect(mask.runs == [
    RasterMaskRun(y: 0, startX: 0, length: 1),
    RasterMaskRun(y: 0, startX: 2, length: 1),
  ])
}

@Test func colorRangePersistsQuantizedSoftCoverage() throws {
  let pixels: [Float] = [
    1, 0, 0, 1,
    0.8, 0, 0, 1,
  ]
  let mask = try #require(ColorRangeRegionBuilder.mask(
    width: 2, height: 1, premultipliedRGBA: pixels,
    seedX: 0, seedY: 0, tolerance: 0.2, smoothness: 1))
  #expect(mask.runs.count == 2)
  #expect(mask.runs[0].coverage == 255)
  // Linear 0.8 becomes about 0.906 in the display-referred comparison space.
  #expect(mask.runs[1].coverage == 197)

  let reopened = try JSONDecoder().decode(
    RasterMask.self, from: JSONEncoder().encode(mask))
  #expect(reopened == mask)
}

@Test func colorRangeToleranceRemainsUsefulNearBlack() throws {
  let pixels: [Float] = [
    0, 0, 0, 1,
    0.001, 0.001, 0.001, 1,
    0.02, 0.02, 0.02, 1,
  ]
  let mask = try #require(ColorRangeRegionBuilder.mask(
    width: 3, height: 1, premultipliedRGBA: pixels,
    seedX: 0, seedY: 0, tolerance: 0.05, smoothness: 0))

  #expect(mask.runs == [RasterMaskRun(y: 0, startX: 0, length: 2)])
}

@Test func colorDrivenRegionBuildersHonorCancellation() {
  let pixels = [Float](repeating: 0, count: 16 * 16 * 4)
  #expect(ColorRangeRegionBuilder.mask(
    width: 16, height: 16, premultipliedRGBA: pixels,
    seedX: 0, seedY: 0, tolerance: 1, smoothness: 0,
    isCancelled: { true }) == nil)
  #expect(ContiguousRegionBuilder.mask(
    width: 16, height: 16, premultipliedRGBA: pixels,
    seedX: 0, seedY: 0, tolerance: 1,
    isCancelled: { true }) == nil)
  #expect(QuickSelectionRegionBuilder.mask(
    width: 16, height: 16, premultipliedRGBA: pixels,
    seedIndices: [0], tolerance: 1, edgeSensitivity: 0, smoothness: 0,
    isCancelled: { true }) == nil)
}

@Test func quickSelectionExpandsFromEveryPaintedHintWithoutCrossingAnUnmatchedGap() throws {
  let pixels: [Float] = [
    1, 0, 0, 1,
    1, 0, 0, 1,
    0, 0, 1, 1,
    1, 0, 0, 1,
    1, 0, 0, 1,
  ]
  let mask = try #require(QuickSelectionRegionBuilder.mask(
    width: 5, height: 1,
    premultipliedRGBA: pixels,
    seedIndices: [0, 4],
    tolerance: 0,
    edgeSensitivity: 1,
    smoothness: 0))

  #expect(mask.runs == [
    RasterMaskRun(y: 0, startX: 0, length: 2),
    RasterMaskRun(y: 0, startX: 3, length: 2),
  ])
}

@Test func quickSelectionPersistsSoftCoverageFromItsHintPalette() throws {
  let pixels: [Float] = [
    1, 0, 0, 1,
    0.8, 0, 0, 1,
  ]
  let mask = try #require(QuickSelectionRegionBuilder.mask(
    width: 2, height: 1,
    premultipliedRGBA: pixels,
    seedIndices: [0],
    tolerance: 0.2,
    edgeSensitivity: 0,
    smoothness: 1))

  #expect(mask.runs.count == 2)
  #expect(mask.runs[0].coverage == 255)
  #expect(mask.runs[1].coverage == 197)
  #expect(try JSONDecoder().decode(
    RasterMask.self, from: JSONEncoder().encode(mask)) == mask)
}

@Test func creativePaintRecipesRoundTripWithCapturedSelectionAndRasterCoverage() throws {
  let raster = RasterMask(width: 4, height: 2, runs: [RasterMaskRun(y: 1, startX: 1, length: 2)])
  let fill = PaintFillRecipe(
    color: LinearRGBAColor(red: 0.25, green: 1.5, blue: 0.5, alpha: 0.8),
    coverage: .single(.raster(raster)), source: .activeLayer, tolerance: 0.33)
  let selection = MaskRecipe.selecting(
    .ellipse(ShapeMask(origin: .zero, width: 0.5, height: 1)))
  let gradient = PaintGradientRecipe(
    kind: .radial,
    start: VectorPoint(x: 0.2, y: 0.3),
    end: VectorPoint(x: 0.8, y: 0.7),
    startColor: .white,
    endColor: LinearRGBAColor(red: 0, green: 0, blue: 0, alpha: 0),
    coverage: selection)
  let paint = PaintLayerRecipe(fills: [fill], gradients: [gradient])

  let data = try JSONEncoder().encode(paint)
  #expect(try JSONDecoder().decode(PaintLayerRecipe.self, from: data) == paint)

  var project = ProjectRecipe()
  project.layerStack.canvas = CanvasRecipe(width: 40, height: 20)
  project = project.applying(.addLayer(.paint(paint)))
  let reopened = try JSONDecoder().decode(
    ProjectRecipe.self, from: JSONEncoder().encode(project))
  #expect(reopened.layerStack.flattenedLayers.contains { $0.layer.paintLayer == paint })
}

@Test func malformedRasterCoverageIsBoundedDuringInitialization() {
  let raster = RasterMask(
    width: PaintOperationLimits.maximumRasterAxis + 1,
    height: 3,
    runs: [
      RasterMaskRun(y: 0, startX: 0, length: Int.max),
      RasterMaskRun(y: 9, startX: 0, length: 2),
    ])
  #expect(raster.width == PaintOperationLimits.maximumRasterAxis)
  #expect(raster.runs == [RasterMaskRun(y: 0, startX: 0, length: PaintOperationLimits.maximumRasterAxis)])
}

@Test func malformedRasterCoverageIsBoundedWhileDecoding() throws {
  let data = Data("""
    {
      "width": 999999,
      "height": 999999,
      "runs": [{"y": -2, "startX": -4, "length": 999999999}]
    }
    """.utf8)
  let raster = try JSONDecoder().decode(RasterMask.self, from: data)
  #expect(raster.width == PaintOperationLimits.maximumRasterAxis)
  #expect(raster.height == PaintOperationLimits.maximumRasterPixels / raster.width)
  #expect(raster.runs == [
    RasterMaskRun(y: 0, startX: 0, length: PaintOperationLimits.maximumRasterAxis)
  ])
}

@Test func shapeToolUsesEditableVectorPathsForAllInitialPrimitives() {
  let start = VectorPoint(x: 0.1, y: 0.2)
  let end = VectorPoint(x: 0.8, y: 0.7)
  let rectangle = VectorPath.shape(.rectangle, from: start, to: end, cornerRadius: 0.05)
  let ellipse = VectorPath.shape(.ellipse, from: start, to: end)
  let line = VectorPath.shape(.line, from: start, to: end)
  let polygon = VectorPath.shape(.polygon, from: start, to: end, polygonSides: 7)

  #expect(rectangle.isClosed && rectangle.anchors.count == 8)
  #expect(ellipse.isClosed && ellipse.anchors.count == 4)
  #expect(!line.isClosed && line.anchors.count == 2 && line.fill == nil)
  #expect(polygon.isClosed && polygon.anchors.count == 7)
}

@Test func vectorLayerColorEditsPreserveGeometryAndStrokeDetails() throws {
  let rectangle = VectorPath.shape(
    .rectangle,
    from: VectorPoint(x: 0.1, y: 0.2),
    to: VectorPoint(x: 0.7, y: 0.8),
    stroke: VectorStrokeStyle(color: .black, width: 12, lineCap: .square),
    fill: VectorFillStyle(color: .white))
  let line = VectorPath.shape(
    .line,
    from: VectorPoint(x: 0.2, y: 0.3),
    to: VectorPoint(x: 0.9, y: 0.4),
    stroke: VectorStrokeStyle(color: .white, width: 3))
  let layer = VectorLayer(objects: [.path(rectangle), .path(line)])
  let fill = VectorColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 0.8)
  let stroke = VectorColor(red: 0.9, green: 0.1, blue: 0.3)

  let recolored = layer.settingFillColor(fill).settingStrokeColor(stroke)
  let paths = recolored.paths.sorted { $0.name < $1.name }
  let recoloredLine = try #require(paths.first { $0.name == "Line" })
  let recoloredRectangle = try #require(paths.first { $0.name == "Rectangle" })
  #expect(recoloredLine.fill == nil)
  #expect(recoloredLine.stroke?.color == stroke)
  #expect(recoloredLine.stroke?.width == 3)
  #expect(recoloredRectangle.fill?.color == fill)
  #expect(recoloredRectangle.stroke?.color == stroke)
  #expect(recoloredRectangle.stroke?.width == 12)
  #expect(recoloredRectangle.stroke?.lineCap == .square)
  #expect(recoloredRectangle.anchors == rectangle.anchors)
}

@Test func penStyleEditsAlsoUpdateOpenPathsAndPreserveStrokeDetails() throws {
  let openPath = VectorPath(
    name: "Open Pen Path",
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.1, y: 0.2)),
      VectorAnchor(position: VectorPoint(x: 0.8, y: 0.7)),
    ],
    isClosed: false,
    stroke: VectorStrokeStyle(
      color: .black, width: 5, lineCap: .square, lineJoin: .bevel,
      dashPattern: [3, 2]),
    fill: nil)
  let layer = VectorLayer(objects: [.path(openPath)])
  let fill = VectorColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 0.7)
  let stroke = VectorColor(red: 0.9, green: 0.3, blue: 0.1)

  let edited = layer
    .settingFillColor(fill, includingOpenPaths: true)
    .settingStrokeColor(stroke)
    .settingStrokeWidth(18)
  let path = try #require(edited.paths.first)
  #expect(path.fill?.color == fill)
  #expect(path.stroke?.color == stroke)
  #expect(path.stroke?.width == 18)
  #expect(path.stroke?.lineCap == .square)
  #expect(path.stroke?.lineJoin == .bevel)
  #expect(path.stroke?.dashPattern == [3, 2])
  #expect(path.anchors == openPath.anchors)
}

@Test func schemaThirteenDoesNotReapplyLegacyRawMigrationAfterCreativeSchemaBump() throws {
  var recipe = ProjectRecipe(schemaVersion: 13)
  recipe.schemaVersion = 13
  recipe.layerStack.canvas = CanvasRecipe(width: 10, height: 10)
  let data = try JSONEncoder().encode(recipe)
  let reopened = try JSONDecoder().decode(ProjectRecipe.self, from: data)
  #expect(reopened.schemaVersion == ProjectRecipe.currentSchemaVersion)
}

import CoreImage
import IOSurface
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func sharedColorsAreWindowLocalDefaultsAndDoNotRewriteTheRecipe() {
  let model = EditorModel()
  let recipe = model.recipe
  let historyCount = model.history.steps.count
  var brush = model.brushSettings
  brush.opacity = 0.42
  brush.flow = 0.31
  model.setBrushSettings(brush)

  let foreground = LinearRGBAColor(red: 0.18, green: 0.42, blue: 0.77)
  let background = LinearRGBAColor(red: 0.82, green: 0.23, blue: 0.11)
  model.setForegroundColor(foreground)
  model.setBackgroundColor(background)

  #expect(model.brushColor == foreground)
  #expect(model.vectorToolStyle.strokeColor == VectorColor(foreground))
  #expect(model.vectorToolStyle.fillColor == VectorColor(background))
  #expect(model.textToolStyle.color == VectorColor(foreground))
  #expect(model.brushSettings.opacity == 0.42)
  #expect(model.brushSettings.flow == 0.31)
  #expect(model.recipe == recipe)
  #expect(model.history.steps.count == historyCount)
}

@MainActor
@Test func sharedColorsSwapResetRememberAndPinWithoutDocumentHistory() {
  let model = EditorModel()
  let first = LinearRGBAColor(red: 0.2, green: 0.3, blue: 0.4)
  let second = LinearRGBAColor(red: 0.8, green: 0.7, blue: 0.6)
  model.setForegroundColor(first)
  model.setBackgroundColor(second)
  model.togglePinnedColor(first)
  model.swapForegroundAndBackgroundColors()

  #expect(model.colorTool.foreground == second)
  #expect(model.colorTool.background == first)
  #expect(model.colorTool.recentColors.prefix(2) == [second, first])
  #expect(model.colorTool.pinnedColors == [first])

  model.resetForegroundAndBackgroundColors()
  #expect(model.colorTool.foreground == .black)
  #expect(model.colorTool.background == .white)
  #expect(model.history.steps.count == 1)
}

@Test func colorSampleSizesNameExactImagePixelWindows() {
  #expect(ColorSampleSize.allCases.map(\.rawValue) == [1, 3, 5, 11])
  #expect(ColorSampleSize.point.label == "Point")
  #expect(ColorSampleSize.elevenByEleven.label == "11×11")
}

@MainActor
@Test func frameAnalysisArrivesAfterPresentationAndRejectsAStaleRevision() throws {
  let model = EditorModel()
  let frame = sampledFrame(
    composite: try colorSurface(linearColor(0.2, 0.4, 0.6), width: 2, height: 2),
    width: 2,
    height: 2
  )
  model.present(frame)

  #expect(model.renderedFrame?.revision == frame.revision)
  #expect(model.histogram == nil)
  #expect(model.sampledPalette.isEmpty)
  #expect(model.isAnalyzingRenderedFrame)

  let histogram = ImageHistogram(
    red: [4],
    green: [4],
    blue: [4],
    luminance: [4],
    sampleCount: 4,
    clippedHighlights: 0,
    clippedShadows: 0
  )
  let palette = [PaletteColor(red: 0.2, green: 0.4, blue: 0.6)]
  model.present(
    RenderedFrameAnalysis(
      documentID: frame.documentID,
      revision: frame.revision + 1,
      contentRevision: frame.contentRevision,
      histogram: histogram,
      palette: palette,
      isProxy: false
    )
  )

  #expect(model.histogram == nil)
  #expect(model.isAnalyzingRenderedFrame)

  model.present(
    RenderedFrameAnalysis(
      documentID: frame.documentID,
      revision: frame.revision,
      contentRevision: frame.contentRevision,
      histogram: histogram,
      palette: palette,
      isProxy: false
    )
  )

  #expect(model.histogram == histogram)
  #expect(model.sampledPalette == palette)
  #expect(!model.isAnalyzingRenderedFrame)
}

@MainActor
@Test func generatedAndVisionTagsMergeForTheirDisplayedFrameInEitherArrivalOrder() throws {
  let model = EditorModel()
  let frame = sampledFrame(
    composite: try colorSurface(linearColor(0.2, 0.4, 0.6), width: 2, height: 2),
    width: 2,
    height: 2
  )
  let visionTags = [
    ImageContentTag(id: "outdoor", isRecommended: true),
    ImageContentTag(id: "red_bicycle", isRecommended: true),
    ImageContentTag(id: "cat", isRecommended: false),
  ]
  let subjectTags = [
    ImageContentTag(id: "Red bicycle", isRecommended: true, source: .foundationModel),
    ImageContentTag(id: "The cat", isRecommended: true, source: .foundationModel),
  ]
  let combinedTags = subjectTags + [visionTags[0]]
  model.present(frame)
  model.presentGeneratedContentTags(subjectTags, for: frame)
  model.present(RenderedFrameAnalysis(
    documentID: frame.documentID,
    revision: frame.revision,
    contentRevision: frame.contentRevision,
    histogram: nil,
    palette: [],
    contentTags: visionTags,
    isProxy: false
  ))
  #expect(model.imageContentTags == combinedTags)

  let nextFrame = RenderedFrame(
    documentID: frame.documentID,
    revision: frame.revision + 1,
    contentRevision: frame.contentRevision + 1,
    surface: frame.surface,
    activeLayerSamplingSurface: nil,
    sampledActiveLayerID: nil,
    samplingLayerStack: nil,
    width: frame.width,
    height: frame.height,
    isProxy: false,
    inspection: nil,
    rawInspections: [:],
    elapsedSeconds: 0
  )
  model.present(nextFrame)
  model.presentGeneratedContentTags(subjectTags, for: frame)
  #expect(model.imageContentTags.isEmpty)
  model.present(RenderedFrameAnalysis(
    documentID: nextFrame.documentID,
    revision: nextFrame.revision,
    contentRevision: nextFrame.contentRevision,
    histogram: nil,
    palette: [],
    contentTags: visionTags,
    isProxy: false
  ))
  #expect(model.imageContentTags == visionTags)
  model.presentGeneratedContentTags(subjectTags, for: nextFrame)
  #expect(model.imageContentTags == combinedTags)
  model.clearRenderedFrame()
  #expect(model.imageContentTags.isEmpty)
}

@MainActor
@Test func colorSamplingIsAnOverlayAndItsOptionsUpdateTheStandingRequest() {
  let model = EditorModel()
  model.setActiveTool(.brush)
  model.armSample(PixelSampleRequest(purpose: .foregroundColor))
  model.setColorSampleSource(.activeLayer)
  model.setColorSampleSize(.elevenByEleven)

  #expect(model.activeTool == .brush)
  #expect(model.pendingSample?.purpose == .foregroundColor)
  #expect(model.pendingSample?.source == .activeLayer)
  #expect(model.pendingSample?.sampleSize == .elevenByEleven)
  #expect(model.pendingSample?.preview == nil)
}

@Test func compositeAndActiveLayerSamplingUseTheirOwnRevisionTaggedSurfaces() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let composite = try colorSurface(linearColor(1, 0, 0), width: 2, height: 2)
  let active = try colorSurface(linearColor(0, 1, 0), width: 2, height: 2)
  let layerID = ProjectLayerID()
  let frame = sampledFrame(
    composite: composite,
    active: active,
    activeLayerID: layerID,
    width: 2,
    height: 2
  )

  let compositeColor = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .composite, atNormalizedX: 0.25, y: 0.25, sampleSize: .point))
  let activeColor = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .activeLayer, atNormalizedX: 0.25, y: 0.25, sampleSize: .point))

  #expect(compositeColor.red > 0.99 && compositeColor.green < 0.01)
  #expect(activeColor.green > 0.99 && activeColor.red < 0.01)
}

@Test func renderedCompositeAndActiveLayerSamplingSeparateOverlappingPaint() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let topID = ProjectLayerID()
  let bottomID = ProjectLayerID()
  let top = ProjectLayer.paint(
    PaintLayerRecipe(strokes: [sampleDot(color: LinearRGBAColor(red: 0, green: 1, blue: 0))]),
    id: topID, name: "Green")
  let bottom = ProjectLayer.paint(
    PaintLayerRecipe(strokes: [sampleDot(color: LinearRGBAColor(red: 1, green: 0, blue: 0))]),
    id: bottomID, name: "Red")
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [top, bottom, .canvasBase(CanvasRecipe(width: 32, height: 32))],
    activeLayerID: bottomID
  )
  let frame = try await engine.render(
    RenderRequest(
      documentID: UUID(), revision: 3, input: nil, recipe: recipe, quality: .full))

  let composite = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .composite, atNormalizedX: 0.5, y: 0.5, sampleSize: .point))
  let active = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .activeLayer, atNormalizedX: 0.5, y: 0.5, sampleSize: .point))
  #expect(composite.green > 0.95 && composite.red < 0.05)
  #expect(active.red > 0.95 && active.green < 0.05)
}

@Test func transparentPixelsDoNotContaminateAveragesAndFullyTransparentSamplesAreEmpty() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let clear = try colorSurface(linearColor(0, 0, 0, 0), width: 3, height: 1)
  let redCenter = CIImage(color: linearColor(1, 0, 0)).cropped(to: CGRect(x: 1, y: 0, width: 1, height: 1))
  let mixed = try surface(for: redCenter, width: 3, height: 1)
  let frame = sampledFrame(composite: mixed, active: clear, width: 3, height: 1)

  let color = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .composite, atNormalizedX: 0.5, y: 0.5, sampleSize: .threeByThree))
  #expect(color.red > 0.99 && color.green < 0.01 && color.alpha == 1)
  #expect(await engine.sampleLinearRGBAColor(
    in: frame, source: .activeLayer, atNormalizedX: 0.5, y: 0.5, sampleSize: .threeByThree) == nil)
}

@Test func averagingClipsAtEdgesAndNormalizedCoordinatesAreZoomIndependent() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let red = CIImage(color: linearColor(1, 0, 0)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
  let green = CIImage(color: linearColor(0, 1, 0)).cropped(to: CGRect(x: 1, y: 0, width: 1, height: 1))
  let blue = CIImage(color: linearColor(0, 0, 1)).cropped(to: CGRect(x: 2, y: 0, width: 1, height: 1))
  let surface = try surface(for: red.composited(over: green).composited(over: blue), width: 3, height: 1)
  let frame = sampledFrame(composite: surface, width: 3, height: 1)

  let edge = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .composite, atNormalizedX: 0, y: 0.5, sampleSize: .threeByThree))
  let farEdge = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .composite, atNormalizedX: 1, y: 0.5, sampleSize: .point))
  #expect(abs(edge.red - 0.5) < 0.01)
  #expect(abs(edge.green - 0.5) < 0.01)
  #expect(farEdge.blue > 0.99)

  // Sampling receives canonical normalized image coordinates, not view points;
  // there is intentionally no zoom input capable of changing this answer.
  let repeated = await engine.sampleLinearRGBAColor(
    in: frame, source: .composite, atNormalizedX: 0, y: 0.5, sampleSize: .threeByThree)
  #expect(repeated == edge)
}

@Test func vectorColorsAreSampledWithoutDocumentSizedVectorSurfaces() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let path = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0, y: 0)),
      VectorAnchor(position: VectorPoint(x: 1, y: 0)),
      VectorAnchor(position: VectorPoint(x: 1, y: 1)),
      VectorAnchor(position: VectorPoint(x: 0, y: 1)),
    ],
    isClosed: true,
    stroke: nil,
    fill: VectorFillStyle(color: VectorColor(red: 1, green: 0, blue: 0))
  )
  let vectorLayer = ProjectLayer(
    name: "Vector",
    isEnabled: true,
    isLocked: false,
    zOrder: 1,
    content: .vector(VectorLayer(objects: [.path(path)])))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStack(
    layers: [vectorLayer, .canvasBase(CanvasRecipe(width: 64, height: 64))],
    activeLayerID: vectorLayer.id)

  let frame = try await engine.render(
    RenderRequest(
      documentID: UUID(), revision: 1, input: nil, recipe: recipe, quality: .full))
  #expect(frame.activeLayerSamplingSurface == nil)

  let composite = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .composite,
    atNormalizedX: 0.5, y: 0.5, sampleSize: .threeByThree))
  let active = try #require(await engine.sampleLinearRGBAColor(
    in: frame, source: .activeLayer,
    atNormalizedX: 0.5, y: 0.5, sampleSize: .threeByThree))
  #expect(composite.red > 0.99 && composite.green < 0.01 && composite.blue < 0.01)
  #expect(active.red > 0.99 && active.green < 0.01 && active.blue < 0.01)
}

private func sampledFrame(
  composite: IOSurface,
  active: IOSurface? = nil,
  activeLayerID: ProjectLayerID = ProjectLayerID(),
  width: Int,
  height: Int
) -> RenderedFrame {
  RenderedFrame(
    documentID: UUID(),
    revision: 7,
    contentRevision: 4,
    surface: composite,
    activeLayerSamplingSurface: active,
    sampledActiveLayerID: active == nil ? nil : activeLayerID,
    samplingLayerStack: nil,
    width: width,
    height: height,
    isProxy: false,
    inspection: nil,
    rawInspections: [:],
    elapsedSeconds: 0
  )
}

private func sampleDot(color: LinearRGBAColor) -> PaintStroke {
  PaintStroke(
    seed: 19,
    settings: BrushSettings(
      size: 20, hardness: 1, opacity: 1, flow: 1, spacing: 0.1, pressureResponse: 0),
    color: color,
    samples: [BrushSample(x: 16, y: 16, pressure: 1)]
  )
}

private func colorSurface(_ color: CIColor, width: Int, height: Int) throws -> IOSurface {
  try surface(
    for: CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)),
    width: width,
    height: height
  )
}

private func linearColor(
  _ red: CGFloat,
  _ green: CGFloat,
  _ blue: CGFloat,
  _ alpha: CGFloat = 1
) -> CIColor {
  CIColor(
    red: red,
    green: green,
    blue: blue,
    alpha: alpha,
    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  )!
}

private func surface(for image: CIImage, width: Int, height: Int) throws -> IOSurface {
  let surface = try #require(IOSurface(properties: [
    .width: width,
    .height: height,
    .bytesPerElement: 8,
    .pixelFormat: kCVPixelFormatType_64RGBAHalf,
  ]))
  let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
  CIContext(options: [.workingColorSpace: space]).render(
    image,
    to: surface,
    bounds: CGRect(x: 0, y: 0, width: width, height: height),
    colorSpace: space
  )
  return surface
}

// MARK: - One pair of colors, shared by every tool that makes something colored

/// Switching a vector stroke or fill off says nothing about what color anything
/// is. It used to say it by setting that color's alpha to zero, and those two
/// colors are the shared foreground and background.
@MainActor
@Test func turningAVectorStrokeOrFillOffKeepsTheColorItWasUsing() {
  var style = VectorToolStyle(strokeColor: .black, fillMode: .solid, fillColor: .white)

  style.setStroke(nil)
  #expect(style.fullStroke == nil)
  #expect(style.strokeColor == .black)

  style.setFill(nil)
  #expect(style.fill == nil)
  #expect(style.fillColor == .white)

  // Which is the color each one comes back with.
  style.setStroke(style.stroke)
  style.setFill(VectorFillStyle(color: style.fillColor))
  #expect(style.fullStroke?.color == .black)
  #expect(style.fill?.color == .white)
}

/// The same thing seen from the shared colors: switching either one off used to
/// hand the brush and the text tool a transparent color to paint with.
@MainActor
@Test func turningAVectorStrokeOrFillOffLeavesTheSharedColorsOpaque() {
  let model = EditorModel()
  var style = model.vectorToolStyle
  style.setStroke(nil)
  style.setFill(nil)
  model.setVectorToolStyle(style)

  #expect(model.vectorToolStyle.fullStroke == nil)
  #expect(model.vectorToolStyle.fill == nil)
  #expect(model.colorTool.foreground.alpha == 1)
  #expect(model.colorTool.background.alpha == 1)
  #expect(model.brushColor.alpha == 1)
  #expect(model.textToolStyle.color.alpha == 1)
  #expect(model.vectorToolStyle.strokeColor.alpha == 1)
  #expect(model.vectorToolStyle.fillColor.alpha == 1)
}

/// The flood fill's color and a gradient's two ends are the shared pair, not
/// three more colors that happen to look like it.
@MainActor
@Test func theSharedPairDrivesTheFillAndGradientTools() {
  let model = EditorModel()
  let foreground = LinearRGBAColor(red: 0.64, green: 0.12, blue: 0.05)
  let background = LinearRGBAColor(red: 0.07, green: 0.44, blue: 0.51)
  model.setForegroundColor(foreground)
  model.setBackgroundColor(background)

  #expect(model.fillTool.color == foreground)
  #expect(model.gradientTool.startColor == foreground)
  #expect(model.gradientTool.endColor == background)

  model.swapForegroundAndBackgroundColors()
  #expect(model.fillTool.color == background)
  #expect(model.gradientTool.startColor == background)
  #expect(model.gradientTool.endColor == foreground)
}

/// Those two panels edit everything except their colors, so a stale copy of a
/// state cannot put a fourth color back into circulation.
@MainActor
@Test func toolStatesCannotWriteColorsBehindTheSharedPair() {
  let model = EditorModel()
  let foreground = LinearRGBAColor(red: 0.2, green: 0.9, blue: 0.4)
  let background = LinearRGBAColor(red: 0.5, green: 0.1, blue: 0.7)
  model.setForegroundColor(foreground)
  model.setBackgroundColor(background)

  var gradient = model.gradientTool
  gradient.kind = .radial
  gradient.startColor = .white
  gradient.endColor = .black
  model.setGradientTool(gradient)
  #expect(model.gradientTool.kind == .radial)
  #expect(model.gradientTool.startColor == foreground)
  #expect(model.gradientTool.endColor == background)

  var fill = model.fillTool
  fill.tolerance = 0.4
  fill.color = .white
  model.setFillTool(fill)
  #expect(model.fillTool.tolerance == 0.4)
  #expect(model.fillTool.color == foreground)
}

/// Picking a background color used to throw away a gradient default. The fill
/// type control is the only thing that changes what a fill is made of.
@MainActor
@Test func aBackgroundColorLeavesAGradientFillDefaultStanding() {
  let model = EditorModel()
  let gradient = VectorGradient()
  var style = model.vectorToolStyle
  style.setFill(VectorFillStyle(gradient: gradient))
  model.setVectorToolStyle(style)

  model.setBackgroundColor(LinearRGBAColor(red: 0.9, green: 0.3, blue: 0.1))

  #expect(model.vectorToolStyle.fill?.isGradient == true)
  #expect(model.vectorToolStyle.fillGradient == gradient)
}

/// The foreground chip and the stroke editor's color well are one control, so
/// the chip has to reach the selected objects exactly as the well does.
@MainActor
@Test func theSharedColorsRecolorTheSelectedVectorObjects() throws {
  let document = ProjectDocument()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  document.editorModel.replaceRecipe(recipe, historyName: "Shared Color Test")
  document.editorModel.setActiveTool(.shape)
  document.commitShape(
    from: VectorPoint(x: 0.2, y: 0.2),
    to: VectorPoint(x: 0.8, y: 0.8),
    constrained: false)

  let stroke = LinearRGBAColor(red: 0.87, green: 0.14, blue: 0.09)
  let fill = LinearRGBAColor(red: 0.12, green: 0.36, blue: 0.94)
  document.setForegroundColor(stroke)
  document.setBackgroundColor(fill)

  let object = try #require(
    document.editorModel.activeVectorLayer?.vector.objects.first)
  #expect(object.stroke?.color == VectorColor(stroke))
  #expect(object.fill?.color == VectorColor(fill))
  #expect(document.editorModel.colorTool.foreground == stroke)
  #expect(document.editorModel.colorTool.background == fill)
}

/// A selection made with a vector tool is not a standing licence to recolor it
/// from the brush's paint chip.
@MainActor
@Test func theSharedColorsLeaveVectorObjectsAloneUnderOtherTools() throws {
  let document = ProjectDocument()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  document.editorModel.replaceRecipe(recipe, historyName: "Shared Color Test")
  document.editorModel.setActiveTool(.shape)
  document.commitShape(
    from: VectorPoint(x: 0.2, y: 0.2),
    to: VectorPoint(x: 0.8, y: 0.8),
    constrained: false)
  let before = try #require(
    document.editorModel.activeVectorLayer?.vector.objects.first)

  document.editorModel.setActiveTool(.brush)
  document.setForegroundColor(LinearRGBAColor(red: 0.4, green: 0.4, blue: 0.4))

  let after = try #require(
    document.editorModel.activeVectorLayer?.vector.objects.first)
  #expect(after == before)
}

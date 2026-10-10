import AppKit
import CoreImage
import Foundation
import Metal
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

private func dot(
  mode: BrushStrokeMode = .paint,
  size: Double = 12,
  opacity: Double = 1,
  color: LinearRGBAColor = LinearRGBAColor(red: 1, green: 0, blue: 0),
  selectionClip: MaskRecipe? = nil,
  x: Double = 16,
  y: Double = 16
) -> PaintStroke {
  PaintStroke(
    seed: 17,
    mode: mode,
    settings: BrushSettings(
      size: size,
      hardness: 1,
      opacity: opacity,
      flow: 1,
      spacing: 0.1,
      pressureResponse: 0
    ),
    color: color,
    selectionClip: selectionClip,
    samples: [BrushSample(x: x, y: y, pressure: 1)]
  )
}

@Test func paintAndEraseAreClippedByTheSelectionCapturedOnEachStroke() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let rightHalf = ShapeMask(origin: VectorPoint(x: 0.5, y: 0), width: 0.5, height: 1)
  let selection = MaskRecipe.selectingAll.combining(.rectangle(rightHalf), using: .subtract)
  let inside = dot(selectionClip: selection, x: 8, y: 16)
  let outside = dot(selectionClip: selection, x: 24, y: 16)

  let pixels = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "selection-clip-test",
      recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [inside, outside]),
      width: 32,
      height: 32
    ))

  #expect((try #require(pixels.value(x: 8, y: 16, component: 3))) > 0.998)
  #expect((try #require(pixels.value(x: 24, y: 16, component: 3))) < 0.002)

  let erased = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "selection-clipped-erase-test",
      recipe: StrokeSurfaceRecipe(
        kind: .colorRGBA,
        strokes: [
          dot(x: 8, y: 16),
          dot(x: 24, y: 16),
          dot(mode: .erase, selectionClip: selection, x: 8, y: 16),
          dot(mode: .erase, selectionClip: selection, x: 24, y: 16),
        ]
      ),
      width: 32,
      height: 32
    ))

  #expect((try #require(erased.value(x: 8, y: 16, component: 3))) < 0.002)
  #expect((try #require(erased.value(x: 24, y: 16, component: 3))) > 0.998)
}

private func sample(_ frame: RenderedFrame, x: Int, y: Int) -> [Float] {
  var pixel = [Float](repeating: 0, count: 4)
  let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  let image = CIImage(ioSurface: frame.surface, options: [.colorSpace: space])
  CIContext(options: [.workingColorSpace: space]).render(
    image,
    toBitmap: &pixel,
    rowBytes: 4 * MemoryLayout<Float>.size,
    bounds: CGRect(x: x, y: y, width: 1, height: 1),
    format: .RGBAf,
    colorSpace: space
  )
  return pixel
}

@Test func canvasCoordinatesIgnoreBackingScalePanZoomAndProxyResolution() throws {
  let centered = CanvasCoordinateTransform(
    viewSize: CGSize(width: 400, height: 300),
    drawableSize: CGSize(width: 800, height: 600),
    canvasSize: CGSize(width: 1_000, height: 500),
    backingScale: 2,
    zoom: 1,
    panInDrawablePixels: .zero
  )
  #expect(centered.canvasRectInView == CGRect(x: 0, y: 50, width: 400, height: 200))
  #expect(centered.canvasPoint(fromView: CGPoint(x: 200, y: 150)) == CGPoint(x: 500, y: 250))

  let movedAndZoomed = CanvasCoordinateTransform(
    viewSize: centered.viewSize,
    drawableSize: centered.drawableSize,
    canvasSize: centered.canvasSize,
    backingScale: 2,
    zoom: 4,
    panInDrawablePixels: CGPoint(x: 40, y: -20)
  )
  let centerInView = CGPoint(
    x: movedAndZoomed.canvasRectInView.midX,
    y: movedAndZoomed.canvasRectInView.midY
  )
  #expect(movedAndZoomed.canvasPoint(fromView: centerInView) == CGPoint(x: 500, y: 250))

  // A pointer can leave the view during a captured drag. Its canonical sample
  // remains outside the canvas and is clipped by the renderer, not clamped by
  // viewport conversion.
  let outside = try #require(centered.canvasPoint(fromView: CGPoint(x: -40, y: 350)))
  #expect(outside.x < 0)
  #expect(outside.y > 500)
}

@Test func metalBrushPaintEraseAndMaskPixels() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let paint = dot()
  let erase = dot(mode: .erase, size: 8)

  // The canvas receives an IOSurface tile and creates only a read-only Metal
  // view of it for provisional presentation.
  let preview = try await engine.renderStrokeSurface(
    StrokeSurfaceRequest(
      cacheID: "preview-tile-test",
      recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [paint]),
      width: 32,
      height: 32
    ))
  let previewTile = try #require(preview.tiles.first)
  let device = try #require(MTLCreateSystemDefaultDevice())
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba16Float,
    width: BrushMetalRenderer.tileSize,
    height: BrushMetalRenderer.tileSize,
    mipmapped: false
  )
  descriptor.usage = .shaderRead
  descriptor.storageMode = .shared
  let previewTexture = try #require(
    device.makeTexture(descriptor: descriptor, iosurface: previewTile.surface, plane: 0))
  let previewImage = try #require(
    CIImage(
      mtlTexture: previewTexture,
      options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any]
    ))
  var previewPixel = [Float](repeating: 0, count: 4)
  CIContext().render(
    previewImage,
    toBitmap: &previewPixel,
    rowBytes: 4 * MemoryLayout<Float>.size,
    bounds: CGRect(x: 16, y: 16, width: 1, height: 1),
    format: .RGBAf,
    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
  )
  #expect(previewPixel[3] > 0.998)

  let color = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "paint-erase-test",
      recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [paint, erase]),
      width: 32,
      height: 32
    ))
  let centerAlpha = try #require(color.value(x: 16, y: 16, component: 3))
  let outerRed = try #require(color.value(x: 21, y: 16, component: 0))
  let outerAlpha = try #require(color.value(x: 21, y: 16, component: 3))
  // Half-float and GPU edge math are allowed a two-millipercent tolerance.
  #expect(centerAlpha < 0.002)
  #expect(outerRed > 0.998)
  #expect(outerAlpha > 0.998)

  let mask = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "mask-test",
      recipe: StrokeSurfaceRecipe(kind: .mask, strokes: [paint]),
      width: 32,
      height: 32
    ))
  #expect(mask.componentCount == 1)
  #expect((try #require(mask.value(x: 16, y: 16))) > 0.998)
  #expect((try #require(mask.value(x: 1, y: 1))) < 0.002)
}

@Test func maskSurfacesHonorWhiteAndBlackSparseDefaults() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let white = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "white-mask-default",
      recipe: StrokeSurfaceRecipe(kind: .mask, initialCoverage: 1),
      width: 32,
      height: 32))
  #expect(white.componentCount == 1)
  #expect((try #require(white.value(x: 1, y: 1))) > 0.998)

  let erased = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "white-mask-default",
      recipe: StrokeSurfaceRecipe(
        kind: .mask,
        initialCoverage: 1,
        strokes: [dot(mode: .erase, size: 10)]),
      width: 32,
      height: 32))
  #expect((try #require(erased.value(x: 16, y: 16))) < 0.002)
  #expect((try #require(erased.value(x: 1, y: 1))) > 0.998)

  let black = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "black-mask-default",
      recipe: StrokeSurfaceRecipe(kind: .mask, strokes: [dot(size: 10)]),
      width: 32,
      height: 32))
  #expect((try #require(black.value(x: 16, y: 16))) > 0.998)
  #expect((try #require(black.value(x: 1, y: 1))) < 0.002)

  let leftHalf = MaskRecipe.selecting(
    .rectangle(ShapeMask(origin: .zero, width: 0.5, height: 1)))
  let clipped = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "selection-clipped-mask",
      recipe: StrokeSurfaceRecipe(
        kind: .mask,
        strokes: [
          dot(selectionClip: leftHalf, x: 8),
          dot(selectionClip: leftHalf, x: 24),
        ]),
      width: 32,
      height: 32))
  #expect((try #require(clipped.value(x: 8, y: 16))) > 0.998)
  #expect((try #require(clipped.value(x: 24, y: 16))) < 0.002)
}

@Test func paintedLayerMaskGatesPixelsAndMovesWithAnAffineTransform() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let layerID = ProjectLayerID(rawValue: "masked-paint")
  let mask = MaskRecipe.layerMask(revealsLayer: false)
    .appendingLayerMaskStroke(dot(size: 10))
  var layer = ProjectLayer(
    id: layerID,
    name: "Masked Paint",
    content: .paint(PaintLayerRecipe(strokes: [dot(size: 80, color: .white)])),
    layerMask: mask)
  layer.transform = LayerTransform(
    referenceRect: LayerFrame(x: 0, y: 0, width: 32, height: 32),
    position: PixelPoint(x: 24, y: 16))
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 32, height: 32)
  recipe.layerStack = recipe.layerStack.adding(layer)

  let frame = try await engine.render(
    RenderRequest(
      documentID: UUID(),
      revision: 1,
      input: nil,
      recipe: recipe,
      quality: .full))
  #expect(sample(frame, x: 16, y: 16)[3] < 0.01)
  #expect(sample(frame, x: 24, y: 16)[3] > 0.98)
  #expect(sample(frame, x: 2, y: 2)[3] < 0.01)
}

@Test func aLayerMaskLimitsAnAdjustmentLayerAndCanBeInverted() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let base = ProjectLayer(
    id: ProjectLayerID(rawValue: "base"),
    name: "Base",
    content: .paint(PaintLayerRecipe(strokes: [dot(size: 80)])))
  var adjustment = ProjectLayer.adjustment(
    .invert,
    id: ProjectLayerID(rawValue: "masked-adjustment"))
  adjustment.layerMask = MaskRecipe.layerMask(revealsLayer: false)
    .appendingLayerMaskStroke(dot(size: 10))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [adjustment, base])
  recipe.layerStack.canvas = CanvasRecipe(width: 32, height: 32)

  func render(_ recipe: ProjectRecipe, revision: UInt64) async throws -> RenderedFrame {
    try await engine.render(
      RenderRequest(documentID: UUID(), revision: revision, input: nil, recipe: recipe, quality: .full))
  }
  let masked = try await render(recipe, revision: 1)
  #expect(sample(masked, x: 16, y: 16)[1] > 0.98)
  #expect(sample(masked, x: 2, y: 2)[0] > 0.98)
  #expect(sample(masked, x: 2, y: 2)[1] < 0.02)

  recipe = recipe.applying(.setLayerMaskInverted(adjustment.id, true))
  let inverted = try await render(recipe, revision: 2)
  #expect(sample(inverted, x: 16, y: 16)[0] > 0.98)
  #expect(sample(inverted, x: 2, y: 2)[1] > 0.98)
}

@Test func aGroupLayerMaskGatesTheCompositedChildren() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let child = ProjectLayer(
    id: ProjectLayerID(rawValue: "group-child"),
    name: "Child",
    content: .paint(PaintLayerRecipe(strokes: [dot(size: 80, color: .white)])))
  var group = ProjectLayer.group(
    [child],
    id: ProjectLayerID(rawValue: "masked-group"))
  group.layerMask = MaskRecipe.layerMask(revealsLayer: false)
    .appendingLayerMaskStroke(dot(size: 10))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(layers: [group])
  recipe.layerStack.canvas = CanvasRecipe(width: 32, height: 32)

  let frame = try await engine.render(
    RenderRequest(documentID: UUID(), revision: 1, input: nil, recipe: recipe, quality: .full))
  #expect(sample(frame, x: 16, y: 16)[3] > 0.98)
  #expect(sample(frame, x: 2, y: 2)[3] < 0.01)
}

@Test func metalStrokeReplayIsDeterministicAfterEviction() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let stroke = PaintStroke(
    seed: 99,
    settings: BrushSettings(
      size: 9,
      hardness: 0.4,
      opacity: 0.7,
      flow: 0.6,
      spacing: 0.08,
      pressureResponse: 1
    ),
    color: LinearRGBAColor(red: 0.2, green: 0.6, blue: 1, alpha: 0.8),
    samples: [
      BrushSample(x: 2, y: 3, pressure: 0.2, sequence: 0),
      BrushSample(x: 40, y: 31, pressure: 0.9, elapsedTime: 0.04, sequence: 1),
    ]
  )
  let request = StrokeSurfaceRequest(
    cacheID: "determinism",
    recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [stroke]),
    width: 48,
    height: 40
  )
  let first = try await engine.readStrokeSurfacePixels(request)
  await engine.clearCaches()
  let second = try await engine.readStrokeSurfacePixels(request)
  #expect(first.values == second.values)
}

@Test func restrainedMarkerStaysEvenWithinOneStrokeAndBuildsAcrossStrokes() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let preset = BrushCatalog.preset(.chiselHighlighter)
  func stroke(_ seed: UInt64) -> PaintStroke {
    PaintStroke(
      seed: seed,
      settings: preset.settings,
      brush: preset.definition,
      color: LinearRGBAColor(red: 1, green: 1, blue: 0, alpha: 1),
      samples: [
        BrushSample(x: 8, y: 16, pressure: 1, sequence: 0),
        BrushSample(x: 24, y: 16, pressure: 1, sequence: 1),
      ]
    )
  }
  let one = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "restrained-one",
      recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [stroke(1)]), width: 32, height: 32))
  let two = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "restrained-two",
      recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [stroke(1), stroke(2)]), width: 32, height: 32))
  let alphaOne = try #require(one.value(x: 16, y: 16, component: 3))
  let alphaTwo = try #require(two.value(x: 16, y: 16, component: 3))
  #expect(abs(alphaOne - Float(preset.settings.opacity)) < 0.01)
  #expect(alphaTwo > alphaOne + 0.15)
}

@Test func everyBuiltInPresetProducesATiledPreview() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  for preset in BrushCatalog.presets {
    let frame = try await engine.renderBrushPresetPreview(preset.id)
    #expect(frame.kind == .colorRGBA)
    #expect(frame.width == 144)
    #expect(!frame.tiles.isEmpty)
  }
}

@Test func paintLayerParticipatesInCompositionOpacityAndErase() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let layer = ProjectLayer(
    id: ProjectLayerID(rawValue: "paint"),
    name: "Paint",
    content: .paint(PaintLayerRecipe(strokes: [dot()])),
    compositing: LayerCompositing(blendMode: .normal, opacity: 0.5, fill: 1)
  )
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 32, height: 32)
  recipe.layerStack = recipe.layerStack.adding(layer)

  let frame = try await engine.render(
    RenderRequest(
      documentID: UUID(),
      revision: 1,
      contentRevision: 1,
      input: nil,
      recipe: recipe,
      quality: .full
    ))
  let center = sample(frame, x: 16, y: 16)
  #expect(abs(center[0] - 0.5) < 0.01)
  #expect(abs(center[3] - 0.5) < 0.01)
  #expect(sample(frame, x: 1, y: 1)[3] < 0.002)
}

/// The color the panel picks is snapshotted into the stroke when it starts,
/// so what a stroke is drawn with is fixed at mouse-down rather than read back
/// from tool state at render time.
@MainActor
@Test func theChosenPaintColorIsTheColorTheCommittedStrokeKeeps() throws {
  let document = ProjectDocument()
  var recipe = document.editorModel.recipe
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  document.editorModel.replaceRecipe(recipe, historyName: "Test")
  document.editorModel.setActiveTool(.brush)

  let chosen = LinearRGBAColor(red: 0.9, green: 0.1, blue: 0.35, alpha: 0.8)
  document.editorModel.setBrushColor(chosen)
  #expect(document.editorModel.brushColor == chosen)

  document.beginBrushStroke(with: BrushSample(x: 8, y: 8, pressure: 1))
  document.appendBrushSamples([BrushSample(x: 20, y: 20, pressure: 1, sequence: 1)])
  document.commitBrushStroke()

  let paint = try #require(document.editorModel.recipe.layerStack.topmostEnabledLayer?.paintLayer)
  #expect(paint.surface.strokes.last?.color == chosen)

  // A later color change cannot reach back into a stroke already committed.
  document.editorModel.setBrushColor(.white)
  #expect(paint.surface.strokes.last?.color == chosen)
}

@MainActor
@Test func oneStrokeIsOneUndoStepCancellationIsNoStepAndProjectReopens() throws {
  let document = ProjectDocument()
  let undo = UndoManager()
  undo.groupsByEvent = false
  document.undoManager = undo
  var recipe = document.editorModel.recipe
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  document.editorModel.replaceRecipe(recipe, historyName: "Test")
  document.editorModel.setActiveTool(.brush)
  let baseline = document.editorModel.recipe
  let baselineCount = document.editorModel.history.steps.count

  document.beginBrushStroke(with: BrushSample(x: 8, y: 8, pressure: 1))
  document.appendBrushSamples([BrushSample(x: 20, y: 20, pressure: 0.5, sequence: 1)])
  document.cancelBrushStroke()
  #expect(document.editorModel.recipe == baseline)
  #expect(document.editorModel.history.steps.count == baselineCount)

  undo.beginUndoGrouping()
  document.beginBrushStroke(with: BrushSample(x: 8, y: 8, pressure: 1))
  document.appendBrushSamples([BrushSample(x: 20, y: 20, pressure: 0.5, sequence: 1)])
  document.commitBrushStroke()
  undo.endUndoGrouping()

  #expect(document.editorModel.history.steps.count == baselineCount + 1)
  #expect(document.editorModel.history.currentStep.name == "Brush Stroke")
  let paint = try #require(document.editorModel.recipe.layerStack.topmostEnabledLayer?.paintLayer)
  #expect(paint.surface.strokes.count == 1)

  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()
  #expect(reopened.editorModel.recipe == document.editorModel.recipe)

  undo.undo()
  #expect(document.editorModel.recipe == baseline)
}

@MainActor
@Test func completedPaintInvalidatesOlderRenderRevisions() {
  let document = ProjectDocument()
  var recipe = document.editorModel.recipe
  recipe.layerStack.canvas = CanvasRecipe(width: 32, height: 32)
  document.editorModel.replaceRecipe(recipe)
  let oldRevision = document.currentRenderRevision
  #expect(document.accepts(documentID: document.projectID, revision: oldRevision))

  document.perform(
    .commitBrushStroke(
      dot(),
      toPaintLayer: nil,
      newLayerID: ProjectLayerID(rawValue: "paint")
    ),
    interactive: false
  )
  #expect(!document.accepts(documentID: document.projectID, revision: oldRevision))
  #expect(document.accepts(documentID: document.projectID, revision: document.currentRenderRevision))
  #expect(!document.accepts(documentID: UUID(), revision: document.currentRenderRevision))
}

/// The same stroke with and without grain. Comparing the two isolates the
/// grain from the tip's own falloff.
private func grainedAndPlainAlpha(
  seed: UInt64,
  width: Int,
  y: Int,
  at columns: [Int]
) async throws -> (grained: [Float], plain: [Float]) {
  let engine = try RenderEngine(observesMemoryPressure: false)
  let preset = BrushCatalog.preset(.charcoal)
  var plainDefinition = preset.definition
  plainDefinition.grainAmount = 0
  func pixels(_ definition: BrushDefinition, _ id: String) async throws -> StrokeSurfacePixels {
    let stroke = PaintStroke(
      seed: seed,
      settings: preset.settings,
      brush: definition,
      color: LinearRGBAColor(red: 1, green: 1, blue: 1),
      samples: [
        BrushSample(x: 4, y: Double(y), pressure: 1, sequence: 0),
        BrushSample(x: Double(width - 4), y: Double(y), pressure: 1, sequence: 1),
      ]
    )
    return try await engine.readStrokeSurfacePixels(
      StrokeSurfaceRequest(
        cacheID: id,
        recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [stroke]),
        width: width, height: 64))
  }
  let grained = try await pixels(preset.definition, "grained-\(seed)-\(width)")
  let plain = try await pixels(plainDefinition, "plain-\(seed)-\(width)")
  return (
    columns.map { grained.value(x: $0, y: y, component: 3) ?? 0 },
    columns.map { plain.value(x: $0, y: y, component: 3) ?? 0 }
  )
}

@Test func grainTexturesCoverageAtSeedsTheAppActuallyProduces() async throws {
  // A stroke seed is a full random UInt64. A grain hash that loses precision
  // at that magnitude returns one constant, which scales coverage uniformly
  // and erases the texture rather than failing, so compare the ratio.
  let columns = Array(stride(from: 20, to: 200, by: 6))
  let (grained, plain) = try await grainedAndPlainAlpha(
    seed: 0x9E37_79B9_7F4A_7C15, width: 220, y: 32, at: columns)
  let ratios = zip(grained, plain).filter { $0.1 > 0.05 }.map { $0.0 / $0.1 }
  #expect(ratios.count > 10)
  let mean = ratios.reduce(0, +) / Float(ratios.count)
  let spread = ratios.map { abs($0 - mean) }.max() ?? 0
  #expect(spread > 0.05)
}

@Test func grainDoesNotRepeatFromOneTileToTheNext() async throws {
  // Tile 0 and tile 1 hold the same stroke at the same height, so identical
  // coverage at the same offset within each tile would mean grain is anchored
  // to the tile instead of to the canvas.
  let tile = BrushMetalRenderer.tileSize
  let offsets = Array(stride(from: 40, to: 200, by: 8))
  let columns = offsets + offsets.map { $0 + tile }
  let (grained, plain) = try await grainedAndPlainAlpha(
    seed: 0x2545_F491_4F6C_DD1D, width: tile * 2, y: 32, at: columns)
  // Stamps land at a different phase inside each tile, so raw coverage
  // differs for reasons that have nothing to do with grain. Dividing by the
  // same stroke drawn without grain cancels the geometry and leaves the grain.
  let factors = zip(grained, plain).map { $0.1 > 0.05 ? $0.0 / $0.1 : Float.nan }
  let first = Array(factors.prefix(offsets.count))
  let second = Array(factors.suffix(offsets.count))
  let comparable = zip(first, second).filter { !$0.0.isNaN && !$0.1.isNaN }
  #expect(comparable.count > 10)
  #expect(comparable.contains { abs($0.0 - $0.1) > 0.02 })
}

@Test func aRotatedRectangularTipKeepsItsCorners() async throws {
  let engine = try RenderEngine(observesMemoryPressure: false)
  // A 200pt chisel with a 28pt half-width, leaning far enough that a corner
  // overhangs the box drawn around its long semi-axis. The tip's stamp bounds
  // have to come from the corner, or the overhang is simply never dispatched.
  let semiMajor = 100.0
  let semiMinor = 40.0
  let degrees = 22.0
  let angle = degrees * .pi / 180
  let corner = (
    x: semiMajor * cos(angle) + semiMinor * sin(angle),
    y: semiMajor * sin(angle) - semiMinor * cos(angle)
  )
  // The overhang the old bound dropped, in whole pixels.
  #expect(corner.x > semiMajor + 4)

  let definition = BrushDefinition(
    presetID: .chiselHighlighter, tipShape: .roundedRectangle,
    aspectRatio: semiMinor / semiMajor,
    orientation: .barrelRotation, pressureAffectsSize: false)
  let centre = 128.0
  let stroke = PaintStroke(
    settings: BrushSettings(
      size: semiMajor * 2, hardness: 1, opacity: 1, flow: 1, pressureResponse: 0),
    brush: definition,
    color: LinearRGBAColor(red: 1, green: 1, blue: 1),
    samples: [
      BrushSample(
        x: centre, y: centre, pressure: 1, rotationDegrees: degrees, reportsRotation: true)
    ]
  )
  let pixels = try await engine.readStrokeSurfacePixels(
    StrokeSurfaceRequest(
      cacheID: "rotated-chisel",
      recipe: StrokeSurfaceRecipe(kind: .colorRGBA, strokes: [stroke]),
      width: 256, height: 256))

  func alpha(at reach: Double) throws -> Float {
    try #require(
      pixels.value(
        x: Int((centre + corner.x * reach).rounded(.down)),
        y: Int((centre + corner.y * reach).rounded(.down)),
        component: 3))
  }
  // Inside the corner, but beyond the long semi-axis the old bound used.
  #expect(try alpha(at: 0.98) > 0.9)
  // Past the corner, where the tip genuinely ends.
  #expect(try alpha(at: 1.06) < 0.05)
}

@MainActor
@Test func brushAndEraserKeepSeparatePresetsSettingsAndOverrides() {
  let model = EditorModel()
  model.setActiveTool(.brush)
  model.selectBrushPreset(.softAirbrush)
  model.setActiveTool(.eraser)
  model.selectBrushPreset(.hardRound)

  // Editing one eraser control must not drag the brush's other values over.
  var eraserEdit = model.activeBrushSettings
  eraserEdit.opacity = 0.25
  model.setBrushSettings(eraserEdit)
  #expect(model.eraserSettings.opacity == 0.25)
  #expect(model.eraserSettings.size == BrushCatalog.preset(.hardRound).settings.size)
  #expect(model.brushSettings == BrushCatalog.preset(.softAirbrush).settings)
  #expect(model.activeBrushIsModified)

  // Browsing away and back restores the edit; Reset drops it.
  model.selectBrushPreset(.charcoal)
  #expect(!model.activeBrushIsModified)
  model.selectBrushPreset(.hardRound)
  #expect(model.eraserSettings.opacity == 0.25)
  model.resetActiveBrush()
  #expect(model.eraserSettings == BrushCatalog.preset(.hardRound).settings)
  #expect(!model.activeBrushIsModified)

  model.setActiveTool(.brush)
  #expect(model.activeBrushPresetID == .softAirbrush)
  #expect(!model.activeBrushIsModified)
}

@MainActor
@Test func bracketKeysResizeTheActiveBrushOrEraser() throws {
  let model = EditorModel()
  let initialRecipe = model.recipe
  let canvas = MetalCanvasView(viewSettings: CanvasViewSettings()) { intent in
    if case .adjustBrushSize(let increasing) = intent {
      model.adjustActiveBrushSize(increasing: increasing)
    }
  }

  func press(_ character: String, keyCode: UInt16) throws {
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, characters: character,
      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
    ))
    canvas.keyDown(with: event)
  }

  model.setActiveTool(.brush)
  canvas.setTool(.brush)
  let originalBrushSize = model.brushSettings.size
  try press("]", keyCode: 30)
  #expect(model.brushSettings.size > originalBrushSize)
  try press("[", keyCode: 33)
  #expect(abs(model.brushSettings.size - originalBrushSize) < 0.000_001)

  model.setActiveTool(.eraser)
  canvas.setTool(.eraser)
  let originalEraserSize = model.eraserSettings.size
  try press("[", keyCode: 33)
  #expect(model.eraserSettings.size < originalEraserSize)
  #expect(model.brushSettings.size == originalBrushSize)
  #expect(model.recipe == initialRecipe)

  var minimum = model.activeBrushSettings
  minimum.size = BrushLimits.minimumSize
  model.setBrushSettings(minimum)
  try press("[", keyCode: 33)
  #expect(model.eraserSettings.size == BrushLimits.minimumSize)
}

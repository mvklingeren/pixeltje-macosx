import AppKit
import CoreGraphics
import CoreImage
import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
private func documentWithUndoManager() -> ProjectDocument {
  let document = ProjectDocument()
  // In the app the run loop closes one undo group per event; a test has none.
  let undoManager = UndoManager()
  undoManager.groupsByEvent = false
  document.undoManager = undoManager
  return document
}

/// Runs one user edit inside its own undo group, standing in for the event
/// group the run loop would close in the running app.
@MainActor
private func edit(_ document: ProjectDocument, _ body: () -> Void) {
  document.undoManager?.beginUndoGrouping()
  body()
  document.undoManager?.endUndoGrouping()
}

@MainActor
private func documentWithAPaintLayer() -> (ProjectDocument, ProjectLayerID) {
  let document = documentWithUndoManager()
  let layer = ProjectLayer.paint(PaintLayerRecipe(), id: ProjectLayerID())
  edit(document) { document.perform(.addLayer(layer), interactive: false) }
  return (document, layer.id)
}

// MARK: - The tools

@Test func marqueeAndLassoTakeTheirConventionalKeysAndMasksMoves() {
  #expect(EditorTool.activated(by: "m") == .marquee)
  #expect(EditorTool.activated(by: "M") == .marquee)
  #expect(EditorTool.activated(by: "l") == .lasso)
  #expect(EditorTool.activated(by: "m", shifted: true) == .magnetSelection)
  // Masks held M before the selection tools existed.
  #expect(EditorTool.activated(by: "k") == .masks)

  #expect(EditorTool.marquee.toolTip == "Marquee Tool (M)")
  #expect(EditorTool.lasso.toolTip == "Lasso Tool (L)")
  #expect(EditorTool.magnetSelection.toolTip == "Magnet Selection Tool (⇧M)")
  #expect(EditorTool.selectionBrush.toolTip == "Selection Brush Tool")
  #expect(EditorTool.masks.toolTip == "Masks Tool (K)")
}

@MainActor
@Test func magnetSelectionHasANonemptyTemplateToolbarIcon() throws {
  let image = EditorToolIcon.image(for: .magnetSelection)
  #expect(image.isTemplate)
  #expect(image.size == NSSize(width: 18, height: 18))

  let cgImage = try #require(image.cgImage(
    forProposedRect: nil,
    context: nil,
    hints: nil))
  let bitmap = NSBitmapImageRep(cgImage: cgImage)
  let containsVisibleInk = (0..<bitmap.pixelsHigh).contains { y in
    (0..<bitmap.pixelsWide).contains { x in
      (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
    }
  }
  #expect(containsVisibleInk)
}

@Test func noTwoToolsClaimTheSameKey() {
  let keys = EditorTool.allCases.compactMap(\.activationKey)
  #expect(Set(keys).count == keys.count)
}

@Test func selectionToolsAreInTheToolboxAndHaveSettings() {
  // The toolbox iterates `allCases`, so being a case is being in the toolbar.
  #expect(EditorTool.allCases.contains(.marquee))
  #expect(EditorTool.allCases.contains(.lasso))
  #expect(EditorTool.allCases.contains(.magnetSelection))
  #expect(EditorTool.allCases.contains(.selectionBrush))
  #expect(EditorTool.marquee.isSelectionTool)
  #expect(EditorTool.lasso.isSelectionTool)
  #expect(EditorTool.magnetSelection.isSelectionTool)
  #expect(EditorTool.selectionBrush.isSelectionTool)
  #expect(!EditorTool.magnetSelection.drawsSelectionGeometry)
  #expect(!EditorTool.selectionBrush.drawsSelectionGeometry)
  #expect(EditorTool.marquee.hasToolSettings)
  #expect(EditorTool.lasso.hasToolSettings)
  #expect(EditorTool.magnetSelection.hasToolSettings)
  #expect(EditorTool.selectionBrush.hasToolSettings)
  #expect(EditorTool.selectionBrush.usesBrushStrokeCapture)
  #expect(!EditorTool.move.isSelectionTool)
}

@MainActor
@Test func selectionBrushSettingsClampBothModesControls() {
  let model = EditorModel()
  model.setSelectionBrushTool(SelectionBrushToolState(
    mode: .quickSelect,
    combine: .subtract,
    brushSettings: BrushSettings(size: 88, hardness: 0.25, opacity: 0.4, flow: 0.6),
    sampleSource: .activeLayer,
    tolerance: 3,
    edgeSensitivity: -2,
    smoothness: 4,
    feather: 900))

  #expect(model.selectionBrushTool.mode == .quickSelect)
  #expect(model.selectionBrushTool.combine == .subtract)
  #expect(model.selectionBrushTool.brushSettings.size == 88)
  #expect(model.selectionBrushTool.sampleSource == .activeLayer)
  #expect(model.selectionBrushTool.tolerance == 1)
  #expect(model.selectionBrushTool.edgeSensitivity == 0)
  #expect(model.selectionBrushTool.smoothness == 1)
  #expect(model.selectionBrushTool.feather == 250)
  #expect(model.selectionBrushTool.quickHintSettings.opacity == 1)
  #expect(model.selectionBrushTool.quickHintSettings.flow == 1)
}

@MainActor
@Test func paintedSelectionIsOneUndoablePersistentStrokeSurface() throws {
  let document = ProjectDocument(canvas: CanvasRecipe(width: 64, height: 64))
  let undoManager = UndoManager()
  undoManager.groupsByEvent = false
  document.undoManager = undoManager
  document.editorModel.setActiveTool(.selectionBrush)
  let baseline = document.editorModel.recipe
  let historyCount = document.editorModel.history.steps.count

  edit(document) {
    document.beginSelectionBrushStroke(
      with: BrushSample(x: 8, y: 12, pressure: 1), combine: nil)
    document.appendBrushSamples([
      BrushSample(x: 36, y: 12, pressure: 0.7, sequence: 1)
    ])
    document.commitSelectionBrushStroke()
  }

  let selection = try #require(document.editorModel.recipe.selection)
  let component = try #require(selection.components.first)
  guard case .strokeSurface(let surface) = component.generator else {
    Issue.record("Paint mode should persist deterministic stroke-surface coverage")
    return
  }
  #expect(surface.kind == .mask)
  #expect(surface.strokes.count == 1)
  #expect(surface.strokes[0].selectionClip == nil)
  #expect(document.editorModel.history.steps.count == historyCount + 1)
  #expect(document.editorModel.history.currentStep.name == "Brush Selection")

  let outline = try #require(SelectionGeometry.path(
    for: selection, in: CGRect(x: 0, y: 0, width: 64, height: 64)))
  #expect(outline.contains(CGPoint(x: 20, y: 12)))
  #expect(!outline.contains(CGPoint(x: 60, y: 60)))

  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()
  #expect(reopened.editorModel.recipe.selection == selection)

  undoManager.undo()
  #expect(document.editorModel.recipe == baseline)
}

@MainActor
@Test func magnetSelectionSettingsClampPixelAnalysisControls() {
  let model = EditorModel()
  model.setMagnetSelectionTool(MagnetSelectionToolState(
    mode: .colorRange,
    combine: .add,
    tolerance: 2,
    smoothness: -0.5,
    sampleSource: .activeLayer,
    feather: 900))

  #expect(model.magnetSelectionTool.mode == .colorRange)
  #expect(model.magnetSelectionTool.combine == .add)
  #expect(model.magnetSelectionTool.tolerance == 1)
  #expect(model.magnetSelectionTool.smoothness == 0)
  #expect(model.magnetSelectionTool.sampleSource == .activeLayer)
  #expect(model.magnetSelectionTool.feather == 250)
}

@Test func theLassoAlwaysDrawsAPolygonWhateverTheShapeSettingSays() {
  var state = SelectionToolState(shape: .ellipse)
  #expect(state.generatorKind(for: .marquee) == .ellipse)
  #expect(state.generatorKind(for: .lasso) == .polygon)
  state.shape = .rectangle
  #expect(state.generatorKind(for: .marquee) == .rectangle)
  #expect(state.generatorKind(for: .lasso) == .polygon)
}

@Test func rectangularSelectionReadoutUsesCanvasPixelsAndClipsAtTheEdge() {
  let canvas = CanvasRecipe(width: 200, height: 100)
  let rectangle = ShapeMask(
    from: VectorPoint(x: 0.1, y: 0.2), to: VectorPoint(x: 0.6, y: 0.7))
  let measurement = SelectionMeasurement.measure(.rectangle(rectangle), in: canvas)
  #expect(measurement == .dimensions(width: 100, height: 50))
  #expect(measurement?.label == "100 × 50 px")

  let crossingEdge = ShapeMask(
    from: VectorPoint(x: -0.2, y: 0.2), to: VectorPoint(x: 0.3, y: 0.8))
  #expect(SelectionMeasurement.measure(.rectangle(crossingEdge), in: canvas)
    == .dimensions(width: 60, height: 60))
}

@Test func freehandSelectionReadoutMeasuresTheEnclosedArea() {
  let canvas = CanvasRecipe(width: 200, height: 100)
  let triangle = PolygonMask(points: [
    VectorPoint(x: 0, y: 0), VectorPoint(x: 1, y: 0), VectorPoint(x: 0, y: 1),
  ])
  #expect(SelectionMeasurement.measure(.polygon(triangle), in: canvas)
    == .area(squarePixels: 10_000))

  let crossingEdge = PolygonMask(points: [
    VectorPoint(x: -0.5, y: 0), VectorPoint(x: 0.5, y: 0),
    VectorPoint(x: 0.5, y: 1), VectorPoint(x: -0.5, y: 1),
  ])
  let clipped = SelectionMeasurement.measure(.polygon(crossingEdge), in: canvas)
  #expect(clipped == .area(squarePixels: 10_000))
  #expect(clipped?.label.contains("px²") == true)
}

@Test func ellipseSelectionReadoutShowsApproximateArea() {
  let canvas = CanvasRecipe(width: 200, height: 100)
  let measurement = SelectionMeasurement.measure(.ellipse(.full), in: canvas)
  guard case .area(let squarePixels) = measurement else {
    Issue.record("Expected an area readout")
    return
  }
  #expect(abs(squarePixels - Int((Double.pi * 5_000).rounded())) < 20)
  #expect(measurement?.label.contains("≈") == true)
}

// MARK: - Document commands

@MainActor
@Test func aSelectionIsOneNamedUndoableStep() {
  let document = documentWithUndoManager()
  document.undoManager?.beginUndoGrouping()
  document.commitSelection(.selectingAll, actionName: "Rectangle Selection")
  document.undoManager?.endUndoGrouping()

  #expect(document.editorModel.recipe.hasSelection)
  #expect(document.editorModel.history.steps.map(\.name).last == "Rectangle Selection")

  document.undoManager?.undo()
  #expect(!document.editorModel.recipe.hasSelection)
}

@MainActor
@Test func aDraftNeverReachesTheDocumentUntilItIsCommitted() {
  let document = documentWithUndoManager()
  let stepsBefore = document.editorModel.history.steps.count

  document.updateSelectionDraft(.selectingAll)
  #expect(document.editorModel.selectionDraft != nil)
  // The draft is what the canvas draws; the document still has no selection.
  #expect(!document.editorModel.recipe.hasSelection)
  #expect(document.editorModel.history.steps.count == stepsBefore)

  document.cancelSelectionDraft()
  #expect(document.editorModel.selectionDraft == nil)
  #expect(!document.editorModel.recipe.hasSelection)
  #expect(document.editorModel.history.steps.count == stepsBefore)
}

@MainActor
@Test func selectAllDeselectAndReselectFollowEachOther() {
  let document = documentWithUndoManager()

  edit(document) { document.selectAll() }
  // Each selection carries its own identity, so what Reselect must restore is
  // this exact one rather than an equivalent freshly built mask.
  let selected = document.editorModel.recipe.selection
  #expect(selected?.components.first?.generator == .rectangle(.full))
  #expect(!document.canReselect)

  edit(document) { document.deselect() }
  #expect(!document.editorModel.recipe.hasSelection)
  #expect(document.canReselect)

  edit(document) { document.reselect() }
  #expect(document.editorModel.recipe.selection == selected)
  #expect(document.editorModel.history.steps.map(\.name).suffix(3)
    == ["Select All", "Deselect", "Reselect"])
}

@MainActor
@Test func invertingFlipsTheSelectionAndInvertsBack() {
  let document = documentWithUndoManager()
  edit(document) { document.selectAll() }

  edit(document) { document.invertSelection() }
  #expect(document.editorModel.recipe.selection?.isInverted == true)

  edit(document) { document.invertSelection() }
  #expect(document.editorModel.recipe.selection?.isInverted == false)
}

@MainActor
@Test func invertingWithNothingSelectedDoesNothing() {
  let document = documentWithUndoManager()
  let before = document.editorModel.recipe
  edit(document) { document.invertSelection() }
  #expect(document.editorModel.recipe == before)
}

@MainActor
@Test func savingASelectionAttachesItToTheSelectedLayer() {
  let (document, layerID) = documentWithAPaintLayer()
  #expect(!document.canSaveSelectionAsMask)

  edit(document) { document.selectAll() }
  #expect(document.canSaveSelectionAsMask)

  edit(document) { document.saveSelectionAsMask(on: layerID) }
  let layer = document.editorModel.recipe.layerStack.layer(id: layerID)
  #expect(layer?.masks.count == 1)
  #expect(layer?.masks.first?.components.first?.generator == .rectangle(.full))
  // The selection stays put; saving copies it rather than consuming it.
  #expect(document.editorModel.recipe.hasSelection)
}

@MainActor
@Test func theCanvasLayerNeverTakesASavedSelection() {
  let document = documentWithUndoManager()
  edit(document) { document.selectAll() }
  // A canvas-only project has nothing but the canvas layer selected, and that
  // layer carries the document extent rather than pixels.
  let activeID = document.editorModel.recipe.layerStack.activeLayerID
  let isCanvas =
    activeID.flatMap { document.editorModel.recipe.layerStack.layer(id: $0)?.isCanvasLayer }
    ?? true
  #expect(isCanvas)
  #expect(!document.canSaveSelectionAsMask)
}

// MARK: - Coverage

/// Resolves a selection the way the render engine does, and hands back the mask
/// image blend filters actually consume.
///
/// `evaluate` produces an *opaque* coverage image with the value in the color
/// channels. `CIBlendWithMask` reads those channels; alpha deliberately remains
/// one so fractional coverage is not premultiplied and squared.
@MainActor
private func coverage(
  of selection: MaskRecipe,
  size: Int = 64
) throws -> (CIImage, CIContext) {
  let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
  let context = CIContext(options: [.workingColorSpace: space])
  let renderer = MaskRenderer(context: context, workingColorSpace: space)
  let evaluated = try #require(
    try renderer.evaluate(
      selection,
      in: MaskSpace(
        extent: CGRect(x: 0, y: 0, width: size, height: size),
        pixelsPerCanvasPixel: 1
      ),
      source: nil,
      sourceIdentity: "test"
    )
  )
  return (renderer.maskImage(from: evaluated), context)
}

/// How strongly the mask selects one pixel, read from its linear red channel.
private func alpha(_ image: CIImage, _ context: CIContext, x: Int, y: Int) -> Float {
  var pixel = [Float](repeating: 0, count: 4)
  context.render(
    image,
    toBitmap: &pixel,
    rowBytes: 4 * MemoryLayout<Float>.size,
    bounds: CGRect(x: x, y: y, width: 1, height: 1),
    format: .RGBAf,
    colorSpace: nil
  )
  #expect(abs(pixel[3] - 1) < 0.01)
  return pixel[0]
}

@MainActor
@Test func aHalfCanvasRectangleCoversExactlyItsHalf() throws {
  // The left half of a 64-square canvas.
  let selection = MaskRecipe.selecting(
    .rectangle(ShapeMask(origin: VectorPoint(x: 0, y: 0), width: 0.5, height: 1)))
  let (image, context) = try coverage(of: selection)

  #expect(alpha(image, context, x: 8, y: 32) > 0.9)
  #expect(alpha(image, context, x: 56, y: 32) < 0.1)
}

@MainActor
@Test func anEllipseCoversItsCenterButNotTheCornersOfItsBox() throws {
  let selection = MaskRecipe.selecting(.ellipse(.full))
  let (image, context) = try coverage(of: selection)

  #expect(alpha(image, context, x: 32, y: 32) > 0.9)
  // A corner of the bounding box is outside the inscribed ellipse.
  #expect(alpha(image, context, x: 2, y: 2) < 0.1)
}

@MainActor
@Test func aFreehandTriangleCoversInsideAndNotOutside() throws {
  // A right triangle filling the bottom-left half of the canvas.
  let selection = MaskRecipe.selecting(
    .polygon(
      PolygonMask(points: [
        VectorPoint(x: 0, y: 0), VectorPoint(x: 1, y: 0), VectorPoint(x: 0, y: 1),
      ])))
  let (image, context) = try coverage(of: selection)

  #expect(alpha(image, context, x: 8, y: 8) > 0.9)
  // Well above the hypotenuse, so outside the triangle.
  #expect(alpha(image, context, x: 56, y: 56) < 0.1)
}

@MainActor
@Test func subtractingCutsAHoleInWhatWasSelected() throws {
  let selection = MaskRecipe.selecting(.rectangle(.full))
    .combining(
      .rectangle(ShapeMask(origin: VectorPoint(x: 0.25, y: 0.25), width: 0.5, height: 0.5)),
      using: .subtract
    )
  let (image, context) = try coverage(of: selection)

  // Outside the hole, still selected.
  #expect(alpha(image, context, x: 4, y: 4) > 0.9)
  // Inside the hole, cut away.
  #expect(alpha(image, context, x: 32, y: 32) < 0.1)
}

@MainActor
@Test func intersectingKeepsOnlyTheOverlap() throws {
  let left = ShapeMask(origin: VectorPoint(x: 0, y: 0), width: 0.6, height: 1)
  let bottom = ShapeMask(origin: VectorPoint(x: 0, y: 0), width: 1, height: 0.6)
  let selection = MaskRecipe.selecting(.rectangle(left))
    .combining(.rectangle(bottom), using: .intersect)
  let (image, context) = try coverage(of: selection)

  // In both rectangles.
  #expect(alpha(image, context, x: 16, y: 16) > 0.9)
  // In the tall one only.
  #expect(alpha(image, context, x: 16, y: 56) < 0.1)
  // In the wide one only.
  #expect(alpha(image, context, x: 56, y: 16) < 0.1)
}

@Test func marchingAntsResolveBooleanCombinationAndInversion() throws {
  let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
  let rightHalf = ShapeMask(origin: VectorPoint(x: 0.5, y: 0), width: 0.5, height: 1)
  let subtracted = MaskRecipe.selectingAll.combining(.rectangle(rightHalf), using: .subtract)
  let subtractedPath = try #require(SelectionGeometry.path(for: subtracted, in: canvas))
  #expect(subtractedPath.contains(CGPoint(x: 25, y: 50)))
  #expect(!subtractedPath.contains(CGPoint(x: 75, y: 50)))

  var inverted = subtracted
  inverted.isInverted = true
  let invertedPath = try #require(SelectionGeometry.path(for: inverted, in: canvas))
  #expect(!invertedPath.contains(CGPoint(x: 25, y: 50)))
  #expect(invertedPath.contains(CGPoint(x: 75, y: 50)))

  let bottomHalf = ShapeMask(origin: .zero, width: 1, height: 0.5)
  let intersection = MaskRecipe.selecting(.rectangle(rightHalf))
    .combining(.rectangle(bottomHalf), using: .intersect)
  let intersectionPath = try #require(SelectionGeometry.path(for: intersection, in: canvas))
  #expect(intersectionPath.contains(CGPoint(x: 75, y: 25)))
  #expect(!intersectionPath.contains(CGPoint(x: 75, y: 75)))
  #expect(!intersectionPath.contains(CGPoint(x: 25, y: 25)))
}

// MARK: - Rounded corners

@MainActor
@Test func aRoundedRectangleGivesUpItsCorners() throws {
  // A quarter-canvas radius on a full-canvas rectangle: the middle of an edge
  // is still inside, the very corner is not.
  let selection = MaskRecipe.selecting(
    .rectangle(ShapeMask(origin: .zero, width: 1, height: 1, cornerRadius: 0.25)))
  let (image, context) = try coverage(of: selection)

  #expect(alpha(image, context, x: 32, y: 32) > 0.9)
  #expect(alpha(image, context, x: 32, y: 2) > 0.9)
  #expect(alpha(image, context, x: 1, y: 1) < 0.1)
  #expect(alpha(image, context, x: 62, y: 62) < 0.1)
}

@MainActor
@Test func aSquareCornerStaysSquareWithoutARadius() throws {
  let selection = MaskRecipe.selecting(.rectangle(.full))
  let (image, context) = try coverage(of: selection)

  #expect(alpha(image, context, x: 1, y: 1) > 0.9)
}

@MainActor
@Test func anEllipseIgnoresACornerRadius() throws {
  // One payload describes both shapes, so the ellipse has to be indifferent to
  // a field that only means something for a rectangle.
  let rounded = MaskRecipe.selecting(
    .ellipse(ShapeMask(origin: .zero, width: 1, height: 1, cornerRadius: 0.5)))
  let (image, context) = try coverage(of: rounded)

  #expect(alpha(image, context, x: 32, y: 32) > 0.9)
  #expect(alpha(image, context, x: 2, y: 2) < 0.1)
}

@MainActor
@Test func theAntsRoundTheSameCornersTheCoverageDoes() throws {
  // The outline and the pixels are drawn by two independent rasterizers. If
  // they disagree, the user selects one shape and gets another — so the same
  // points are asked of both.
  let shape = ShapeMask(origin: .zero, width: 1, height: 1, cornerRadius: 0.25)
  let selection = MaskRecipe.selecting(.rectangle(shape))
  let canvas = CGRect(x: 0, y: 0, width: 64, height: 64)
  let path = try #require(SelectionGeometry.path(for: selection, in: canvas))
  let (image, context) = try coverage(of: selection)

  for point in [CGPoint(x: 32, y: 32), CGPoint(x: 32, y: 2)] {
    #expect(path.contains(point))
    #expect(alpha(image, context, x: Int(point.x), y: Int(point.y)) > 0.9)
  }
  for point in [CGPoint(x: 1, y: 1), CGPoint(x: 62, y: 62)] {
    #expect(!path.contains(point))
    #expect(alpha(image, context, x: Int(point.x), y: Int(point.y)) < 0.1)
  }
}

@MainActor
@Test func aCornerRadiusNeverEatsPastTheMiddleOfAnEdge() throws {
  // Half the shorter edge is a stadium; the clamp has to stop there rather
  // than letting the corners meet and swallow the middle.
  let selection = MaskRecipe.selecting(
    .rectangle(ShapeMask(origin: .zero, width: 1, height: 1, cornerRadius: 0.5)))
  let (image, context) = try coverage(of: selection)

  #expect(alpha(image, context, x: 32, y: 32) > 0.9)
  #expect(alpha(image, context, x: 32, y: 1) > 0.9)
  #expect(alpha(image, context, x: 1, y: 32) > 0.9)
}

// MARK: - Selection tool settings

@MainActor
@Test func theSelectionToolClampsWhatThePanelSendsIt() {
  // The panel copies the struct, sets one field and sends it back, which walks
  // past the initializer's clamps. The setter has to catch that.
  let model = ProjectDocument().editorModel
  var state = model.selectionTool
  state.feather = 10_000
  state.cornerRadius = -5
  model.setSelectionTool(state)

  #expect(model.selectionTool.feather == 250)
  #expect(model.selectionTool.cornerRadius == 0)

  var broken = model.selectionTool
  broken.cornerRadius = .nan
  model.setSelectionTool(broken)
  #expect(model.selectionTool.cornerRadius == 0)
}

// MARK: - Snapping the marquee to whole pixels
//
// The pointer moves continuously, so a marquee is drawn in fractions of a
// pixel. Left that way it rasterizes with partial coverage on every edge, which
// is a feather nobody asked for — and one that survives a copy, because the
// copy crops outward to whole pixels and carries those half-covered rows onto
// the pasteboard.

private let square = CanvasRecipe(width: 64, height: 64)

/// The snapped rectangle back in canvas pixels, which is what the assertions
/// below are actually about.
private func snappedPixels(
  _ shape: ShapeMask,
  in canvas: CanvasRecipe = square
) -> (x: Double, y: Double, width: Double, height: Double) {
  let snapped = SelectionGeometry.pixelSnapped(shape, in: canvas)
  let width = Double(canvas.width)
  let height = Double(canvas.height)
  let edges = (
    x: snapped.origin.x * width,
    y: snapped.origin.y * height,
    width: snapped.width * width,
    height: snapped.height * height
  )
  // Landing on the grid is the whole point, so it is asserted here rather than
  // rounded away — every caller below would otherwise pass without a snap.
  // Normalized storage costs about 1e-13 on the round trip, hence the epsilon
  // rather than an exact integer comparison.
  for edge in [edges.x, edges.y, edges.width, edges.height] {
    #expect(abs(edge - edge.rounded()) < 1e-9, "\(edge) is not a whole pixel")
  }
  return (edges.x.rounded(), edges.y.rounded(), edges.width.rounded(), edges.height.rounded())
}

@Test func aMarqueeDrawnBetweenPixelsLandsOnTheGrid() {
  // 16.37 → 48.91, which is what an unsnapped drag actually produces.
  let drawn = ShapeMask(
    from: VectorPoint(x: 16.37 / 64, y: 20.2 / 64),
    to: VectorPoint(x: 48.91 / 64, y: 33.8 / 64))

  let snapped = snappedPixels(drawn)
  #expect(snapped.x == 16)
  #expect(snapped.y == 20)
  #expect(snapped.width == 33)
  #expect(snapped.height == 14)
}

@MainActor
@Test func aSnappedMarqueeCoversItsEdgePixelsCompletely() throws {
  // The bug this guards: partial coverage on the boundary reads as a feather
  // even with the feather slider at zero.
  let drawn = ShapeMask(
    from: VectorPoint(x: 16.37 / 64, y: 16.37 / 64),
    to: VectorPoint(x: 48.91 / 64, y: 48.91 / 64))
  let selection = MaskRecipe.selecting(
    .rectangle(SelectionGeometry.pixelSnapped(drawn, in: square)))
  let (image, context) = try coverage(of: selection)

  // Both edge columns of the snapped rectangle, fully selected.
  #expect(alpha(image, context, x: 16, y: 32) > 0.99)
  #expect(alpha(image, context, x: 48, y: 32) > 0.99)
  // And the pixels just outside it, not selected at all.
  #expect(alpha(image, context, x: 15, y: 32) < 0.01)
  #expect(alpha(image, context, x: 49, y: 32) < 0.01)
}

@Test func aMarqueeAlreadyOnTheGridIsLeftAlone() {
  let drawn = ShapeMask(origin: VectorPoint(x: 0.25, y: 0.25), width: 0.5, height: 0.5)
  let snapped = snappedPixels(drawn)

  #expect(snapped == (x: 16, y: 16, width: 32, height: 32))
}

@Test func aDragAcrossPartOfAPixelStillSelectsOne() {
  // Rounding both edges onto the same boundary would turn a deliberate drag
  // into a click, and a click deselects.
  let drawn = ShapeMask(
    from: VectorPoint(x: 10.6 / 64, y: 10.6 / 64),
    to: VectorPoint(x: 11.4 / 64, y: 11.4 / 64))

  let snapped = snappedPixels(drawn)
  #expect(snapped.width == 1)
  #expect(snapped.height == 1)
}

@Test func aSliverAgainstTheFarEdgeWidensInwards() {
  // There is no pixel 64 to grow into, so the extra pixel has to come off the
  // other side rather than off the canvas.
  let drawn = ShapeMask(
    from: VectorPoint(x: 63.6 / 64, y: 63.6 / 64),
    to: VectorPoint(x: 63.9 / 64, y: 63.9 / 64))

  let snapped = snappedPixels(drawn)
  #expect(snapped.x == 63)
  #expect(snapped.width == 1)
  #expect(snapped.y == 63)
  #expect(snapped.height == 1)
}

@Test func aClickWithNoDragStaysEmptySoItDeselects() {
  let drawn = ShapeMask(
    from: VectorPoint(x: 20.4 / 64, y: 20.4 / 64),
    to: VectorPoint(x: 20.4 / 64, y: 20.4 / 64))

  #expect(SelectionGeometry.pixelSnapped(drawn, in: square).isEmpty)
}

@Test func snappingUsesEachAxisOwnPixelCountOnANonSquareCanvas() {
  let canvas = CanvasRecipe(width: 200, height: 50)
  let drawn = ShapeMask(
    from: VectorPoint(x: 10.4 / 200, y: 10.4 / 50),
    to: VectorPoint(x: 100.6 / 200, y: 40.6 / 50))

  let snapped = snappedPixels(drawn, in: canvas)
  #expect(snapped == (x: 10, y: 10, width: 91, height: 31))
}

@Test func anUnresolvedCanvasHasNoGridToSnapTo() {
  let drawn = ShapeMask(origin: VectorPoint(x: 0.123, y: 0.456), width: 0.2, height: 0.3)

  #expect(SelectionGeometry.pixelSnapped(drawn, in: .unresolved) == drawn)
}

@Test func snappingKeepsTheCornerRadiusItWasGiven() {
  let drawn = ShapeMask(
    origin: VectorPoint(x: 0.1, y: 0.1), width: 0.5, height: 0.5, cornerRadius: 0.25)

  #expect(SelectionGeometry.pixelSnapped(drawn, in: square).cornerRadius == 0.25)
}

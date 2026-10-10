import AppKit
import CoreGraphics
import ImageIO
import Metal
import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
private func edit(_ document: ProjectDocument, _ body: () -> Void) {
  document.undoManager?.beginUndoGrouping()
  body()
  document.undoManager?.endUndoGrouping()
}

/// A document with a square canvas and one paint layer to act on, which is the
/// least a clipboard or delete command needs.
@MainActor
private func documentWithCanvas(
  _ size: Int = 100
) -> (ProjectDocument, ProjectLayerID) {
  let document = ProjectDocument()
  let undoManager = UndoManager()
  undoManager.groupsByEvent = false
  document.undoManager = undoManager
  let layer = ProjectLayer.paint(PaintLayerRecipe(), id: ProjectLayerID())
  edit(document) {
    document.perform(.setCanvasSize(CanvasRecipe(width: size, height: size)), interactive: false)
    document.perform(.addLayer(layer), interactive: false)
  }
  return (document, layer.id)
}

private func rectangleSelection(
  x: Double, y: Double, size: Double, feather: Double = 0
) -> MaskRecipe {
  .selecting(
    .rectangle(ShapeMask(origin: VectorPoint(x: x, y: y), width: size, height: size)),
    feather: feather)
}

// MARK: - The region a copy reads

@MainActor
@Test func nothingSelectedMeansTheWholeCanvas() {
  let (document, _) = documentWithCanvas()

  #expect(document.selectionBounds() == CGRect(x: 0, y: 0, width: 100, height: 100))
}

@MainActor
@Test func aRectangleSelectionBoundsItselfInCanvasPixels() {
  let (document, _) = documentWithCanvas()
  edit(document) {
    document.setSelection(rectangleSelection(x: 0.2, y: 0.4, size: 0.3), actionName: "Select")
  }

  let bounds = document.selectionBounds()
  #expect(bounds == CGRect(x: 20, y: 40, width: 30, height: 30))
}

@MainActor
@Test func aFeatheredSelectionCopiesTheEdgeItSoftens() throws {
  // Feather spreads coverage past the shape, so a copy that stopped at the
  // outline would cut the soft edge off square.
  let (document, _) = documentWithCanvas()
  edit(document) {
    document.setSelection(
      rectangleSelection(x: 0.4, y: 0.4, size: 0.2, feather: 4), actionName: "Select")
  }

  let bounds = try #require(document.selectionBounds())
  #expect(bounds.width > 20)
  #expect(bounds.contains(CGRect(x: 40, y: 40, width: 20, height: 20)))
}

@MainActor
@Test func selectionBoundsNeverLeaveTheCanvas() throws {
  // A marquee can be dragged past the edge, and a feather can push it further,
  // but there are no pixels out there to read back.
  let (document, _) = documentWithCanvas()
  edit(document) {
    document.setSelection(
      rectangleSelection(x: 0.8, y: 0.8, size: 0.6, feather: 30), actionName: "Select")
  }

  let bounds = try #require(document.selectionBounds())
  #expect(CGRect(x: 0, y: 0, width: 100, height: 100).contains(bounds))
}

@MainActor
@Test func workflowSelectionBoundsUseOccupiedRasterCells() throws {
  let (document, _) = documentWithCanvas(16)
  var rgba = [UInt8](repeating: 0, count: 4 * 4 * 4)
  for y in 1..<3 {
    for x in 1..<3 { rgba[(y * 4 + x) * 4] = 255 }
  }
  let selection = try SelectionWorkflowSupport.mask(
    rgba: rgba,
    width: 4,
    height: 4,
    placement: LayerFrame(x: 0, y: 0, width: 16, height: 16),
    canvas: CanvasRecipe(width: 16, height: 16),
    prompt: "red square")
  edit(document) { document.setSelection(selection, actionName: "Select red square") }

  #expect(document.selectionBounds() == CGRect(x: 4, y: 4, width: 8, height: 8))
}

@MainActor
@Test func anUnresolvedCanvasHasNoRegionToCopy() {
  // A new document takes its extent from the configured default, so the
  // unresolved case has to be arranged rather than assumed.
  let (document, _) = documentWithCanvas()
  #expect(document.canCopySelection)

  edit(document) {
    document.perform(.setCanvasSize(.unresolved), interactive: false)
  }

  #expect(document.selectionBounds() == nil)
  #expect(!document.canCopySelection)
}

// MARK: - Delete

@MainActor
@Test func deletingMasksTheSelectionAwayInsteadOfErasingIt() {
  let (document, layerID) = documentWithCanvas()
  #expect(!document.canClearSelection)

  edit(document) {
    document.setSelection(rectangleSelection(x: 0.2, y: 0.2, size: 0.3), actionName: "Select")
  }
  #expect(document.canClearSelection)
  edit(document) { document.clearSelection() }

  let layer = document.editorModel.recipe.layerStack.layer(id: layerID)
  // The pixels are still there; a mask now hides the part that was selected.
  #expect(layer?.content == .paint(PaintLayerRecipe()))
  #expect(layer?.layerMask?.isInverted == true)
  #expect(layer?.layerMask?.components.count == 1)
}

@MainActor
@Test func deletingFromTheLockedRawBackgroundCreatesALayerMask() {
  let document = ProjectDocument()
  var recipe = document.editorModel.recipe
  recipe.layerStack = .initialRawBackground()
  recipe.layerStack.canvas = CanvasRecipe(width: 100, height: 100)
  document.editorModel.replaceRecipe(recipe, historyName: "RAW Document")

  let raw = document.editorModel.recipe.layerStack.layer(id: .rawBackground)
  #expect(raw?.isLocked == true)
  edit(document) {
    document.setSelection(
      rectangleSelection(x: 0.2, y: 0.2, size: 0.3), actionName: "Select")
  }
  #expect(document.canClearSelection)

  edit(document) { document.clearSelection() }

  let masked = document.editorModel.recipe.layerStack.layer(id: .rawBackground)
  #expect(masked?.isLocked == true)
  #expect(masked?.content == raw?.content)
  #expect(masked?.layerMask?.isInverted == true)
  #expect(masked?.layerMask?.components.count == 1)
}

@MainActor
@Test func aDeleteIsOneUndoableStepNamedForWhatItDid() {
  let (document, layerID) = documentWithCanvas()
  edit(document) {
    document.setSelection(rectangleSelection(x: 0.2, y: 0.2, size: 0.3), actionName: "Select")
  }
  let revisionBeforeDelete = document.currentRenderRevision
  edit(document) { document.clearSelection() }
  #expect(document.undoManager?.undoActionName == "Delete")
  #expect(document.currentRenderRevision == revisionBeforeDelete + 1)

  document.undoManager?.undo()
  #expect(document.editorModel.recipe.layerStack.layer(id: layerID)?.layerMask == nil)
}

@MainActor
@Test func aSecondDeleteHidesMoreRatherThanUncoveringTheFirst() {
  // The mask left by the first delete is inverted, and inversion applies after
  // the components combine — so the second area has to be added, not
  // subtracted. Subtracting would hand the first deleted area back.
  let (document, layerID) = documentWithCanvas()
  edit(document) {
    document.setSelection(rectangleSelection(x: 0.1, y: 0.1, size: 0.2), actionName: "Select")
  }
  edit(document) { document.clearSelection() }
  edit(document) {
    document.setSelection(rectangleSelection(x: 0.6, y: 0.6, size: 0.2), actionName: "Select")
  }
  edit(document) { document.clearSelection() }

  let mask = document.editorModel.recipe.layerStack.layer(id: layerID)?.layerMask
  #expect(mask?.isInverted == true)
  #expect(mask?.components.count == 2)
  #expect(mask?.components.last?.combine == .add)
}

@MainActor
@Test func deleteStandsDownWithNothingSelectedOrNothingToActOn() {
  let (document, _) = documentWithCanvas()
  #expect(!document.canClearSelection)

  // An empty selection restricts editing to nothing, so there is nothing to
  // take out of the layer.
  edit(document) {
    document.setSelection(
      MaskRecipe(name: "Selection", components: []), actionName: "Select")
  }
  #expect(!document.canClearSelection)
}

@MainActor
@Test func theCanvasLayerIsNeverDeletedInto() {
  // A canvas-only project has the canvas layer selected, and that layer carries
  // the document extent rather than pixels.
  let document = ProjectDocument()
  document.perform(.setCanvasSize(CanvasRecipe(width: 64, height: 64)), interactive: false)
  document.perform(.setSelection(.selectingAll, actionName: "Select All"), interactive: false)

  #expect(!document.canClearSelection)
}

// MARK: - The pasteboard payload

private func payload(canvas: Int = 100) -> SelectionPasteboard.Payload {
  SelectionPasteboard.Payload(
    reference: RasterAssetReference(
      id: RasterAssetID(rawValue: "abc123"),
      width: 20,
      height: 10,
      uncompressedByteCount: 20 * 10 * 8),
    compressedPixels: Data([0x01, 0x02, 0x03]),
    frame: LayerFrame(x: 30, y: 40, width: 20, height: 10),
    canvasWidth: canvas,
    canvasHeight: canvas)
}

@Test func aCopiedSelectionSurvivesTheTripThroughThePasteboard() throws {
  let encoder = PropertyListEncoder()
  encoder.outputFormat = .binary
  let decoded = try PropertyListDecoder().decode(
    SelectionPasteboard.Payload.self, from: try encoder.encode(payload()))

  #expect(decoded == payload())
  #expect(decoded.frame.x == 30)
  #expect(decoded.reference.width == 20)
}

@Test func pixelsGoBackWhereTheyCameFromOnlyOnTheSameCanvas() {
  // Paste in place is only meaningful when the frame still means the same
  // thing; on a different canvas the pasted layer is centred instead.
  #expect(payload().fitsInPlace(on: CanvasRecipe(width: 100, height: 100)))
  #expect(!payload().fitsInPlace(on: CanvasRecipe(width: 200, height: 100)))
  #expect(!payload().fitsInPlace(on: .unresolved))
}

@MainActor
@Test func pasteStandsDownWithoutACanvasOrAClipboard() {
  NSPasteboard.general.clearContents()
  let (document, _) = documentWithCanvas()

  #expect(!document.canPaste)
  #expect(!SelectionPasteboard.hasContent)
  #expect(SelectionPasteboard.readPayload() == nil)
}

@MainActor
@Test func aDamagedPayloadIsRefusedRatherThanPasted() throws {
  // Pasteboard data comes from outside the document; a payload whose pixels do
  // not match the identity recorded beside them must not become a layer that
  // breaks every render afterwards.
  try SelectionPasteboard.write(payload(), png: Data([0x00]))
  let (document, _) = documentWithCanvas()
  let before = document.editorModel.recipe.layerStack.contentLayers.count

  #expect(document.canPaste)
  document.paste()

  #expect(document.editorModel.recipe.layerStack.contentLayers.count == before)
  NSPasteboard.general.clearContents()
}

@MainActor
@Test func aBrushSelectionCopiesTheWholeCanvasRatherThanNothing() {
  // A brush selection has no outline to resolve. The mask still clips the copy
  // correctly, so the region falls back to the canvas instead of refusing.
  let (document, _) = documentWithCanvas()
  edit(document) {
    document.setSelection(
      .selecting(.brush(BrushStrokeMask(strokes: [
        BrushStroke(
          points: [BrushStrokePoint(position: VectorPoint(x: 0.5, y: 0.5))],
          radius: 5),
      ]))), actionName: "Select")
  }

  #expect(document.selectionBounds() == CGRect(x: 0, y: 0, width: 100, height: 100))
}

@MainActor
@Test func anEmptySelectionHasNoPixelsToCopy() {
  let (document, _) = documentWithCanvas()
  edit(document) {
    document.setSelection(MaskRecipe(name: "Empty", components: []), actionName: "Select")
  }

  #expect(document.selectionBounds() == nil)
  #expect(!document.canCopySelection)
}

@MainActor
@Test func workflowSelectionCopiesVisiblePixelsAndCanPasteThem() async throws {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let redPixel: [UInt8] = [0, 0x3c, 0, 0, 0, 0, 0, 0x3c]
  var pixels = Data()
  for _ in 0..<(16 * 16) { pixels.append(contentsOf: redPixel) }
  let source = try RasterAssetPayload.encode(pixels, width: 16, height: 16)
  let document = try ProjectDocument(clipboard: .payload(
    SelectionPasteboard.Payload(
      reference: source.reference,
      compressedPixels: source.compressedPixels,
      frame: LayerFrame(x: 0, y: 0, width: 16, height: 16),
      canvasWidth: 16,
      canvasHeight: 16)))
  // The workflow analyzes the visible composite, but Copy used to read this
  // empty active paint layer and put transparent pixels on the pasteboard.
  edit(document) {
    document.perform(.addLayer(ProjectLayer.paint(PaintLayerRecipe())), interactive: false)
  }
  var rgba = [UInt8](repeating: 0, count: 4 * 4 * 4)
  for y in 1..<3 {
    for x in 1..<3 { rgba[(y * 4 + x) * 4] = 255 }
  }
  let selection = try SelectionWorkflowSupport.mask(
    rgba: rgba,
    width: 4,
    height: 4,
    placement: LayerFrame(x: 0, y: 0, width: 16, height: 16),
    canvas: CanvasRecipe(width: 16, height: 16),
    prompt: "red square")
  edit(document) { document.setSelection(selection, actionName: "Select red square") }
  // A workflow pixel selection keeps clipboard priority under Select/Move.
  document.editorModel.setActiveTool(.move)
  let controller = ProjectWindowController(projectDocument: document)
  let copyItem = NSMenuItem(
    title: "Copy", action: #selector(ProjectWindowController.copy(_:)), keyEquivalent: "c")
  #expect(controller.validateMenuItem(copyItem))
  let pasteItem = NSMenuItem(
    title: "Paste", action: #selector(ProjectWindowController.paste(_:)), keyEquivalent: "v")
  NSPasteboard.general.clearContents()

  let beforePaste = document.editorModel.recipe.layerStack.contentLayers.count
  controller.copy(nil)
  // The copy renders in the background. A quick Command-V must wait for these
  // pixels instead of pasting an older clipboard entry or doing nothing.
  #expect(controller.validateMenuItem(pasteItem))
  controller.paste(nil)
  for _ in 0..<500 where SelectionPasteboard.readPayload() == nil {
    try await Task.sleep(for: .milliseconds(10))
  }
  for _ in 0..<500
  where document.editorModel.recipe.layerStack.contentLayers.count == beforePaste {
    try await Task.sleep(for: .milliseconds(10))
  }
  let copied = try #require(SelectionPasteboard.readPayload())
  #expect(copied.frame == LayerFrame(x: 4, y: 4, width: 8, height: 8))
  #expect(NSPasteboard.general.data(forType: .png) != nil)
  let copiedPixels = try RasterAssetPayload.decode(
    copied.compressedPixels, reference: copied.reference)
  let red = UInt16(copiedPixels[0]) | (UInt16(copiedPixels[1]) << 8)
  let alpha = UInt16(copiedPixels[6]) | (UInt16(copiedPixels[7]) << 8)
  #expect(Float16(bitPattern: red) > 0.9)
  #expect(Float16(bitPattern: alpha) > 0.9)

  #expect(document.editorModel.recipe.layerStack.contentLayers.count == beforePaste + 1)
  #expect(document.editorModel.recipe.layerStack.contentLayers.first?.rasterLayer?.frame
    == copied.frame)
  NSPasteboard.general.clearContents()
}

@MainActor
@Test func cutPutsThePixelsOnTheClipboardBeforeItTakesThemOut() async throws {
  // A cut has to end with the pixels on the pasteboard and gone from the layer.
  // The copy is snapshotted before the delete and rendered after it, so the
  // delete cannot abort the copy it was paired with.
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let (document, layerID) = documentWithCanvas(16)
  NSPasteboard.general.clearContents()
  edit(document) {
    document.setSelection(rectangleSelection(x: 0.2, y: 0.2, size: 0.5), actionName: "Select")
  }

  edit(document) { document.cutSelection(merged: false) }
  // The delete lands inside the command's own undo group, so it is there at
  // once rather than arriving later out of a background task.
  #expect(document.editorModel.recipe.layerStack.layer(id: layerID)?.layerMask?.isInverted == true)
  #expect(document.undoManager?.undoActionName == "Delete")

  for _ in 0..<500 where SelectionPasteboard.readPayload() == nil {
    try await Task.sleep(for: .milliseconds(10))
  }

  // The pixels on the pasteboard are the ones that were there before the cut:
  // the copy was snapshotted from the recipe as it stood, then rendered.
  let payload = try #require(SelectionPasteboard.readPayload())
  #expect(payload.canvasWidth == 16)
  #expect(payload.frame.width > 0)
  NSPasteboard.general.clearContents()
}

// MARK: - New from clipboard

/// A payload whose pixels really are the ones its reference names, so it
/// survives the verification a paste puts it through.
private func validPayload(width: Int, height: Int, canvas: Int = 100) throws
  -> SelectionPasteboard.Payload
{
  let pixels = Data(repeating: 0, count: width * height * 8)
  let encoded = try RasterAssetPayload.encode(pixels, width: width, height: height)
  return SelectionPasteboard.Payload(
    reference: encoded.reference,
    compressedPixels: encoded.compressedPixels,
    frame: LayerFrame(x: 5, y: 6, width: Double(width), height: Double(height)),
    canvasWidth: canvas,
    canvasHeight: canvas)
}

/// PNG data of a known pixel size, to stand in for another application's copy.
private func png(width: Int, height: Int) throws -> Data {
  let image = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0)
  return try #require(image?.representation(using: .png, properties: [:]))
}

@Test func theClipboardSaysWhatIsOnItAndHowBigItIs() throws {
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  #expect(SelectionPasteboard.readContent() == nil)

  pasteboard.clearContents()
  pasteboard.setString("not an image", forType: .string)
  #expect(SelectionPasteboard.readContent() == nil)
  #expect(!SelectionPasteboard.hasContent)

  // Another application's PNG, read at its own pixels rather than its points:
  // a Retina screenshot must not arrive at half its size.
  pasteboard.clearContents()
  pasteboard.setData(try png(width: 64, height: 32), forType: .png)
  guard case .image = try #require(SelectionPasteboard.readContent()) else {
    Issue.record("A PNG on the pasteboard should read back as an image.")
    return
  }
  #expect(try #require(SelectionPasteboard.readContent()).pixelSize
    == CanvasRecipe(width: 64, height: 32))

  // The project's own payload wins when both are there, and knows its size
  // from the pixels it carries rather than the canvas it came from.
  let payload = try validPayload(width: 20, height: 10)
  try SelectionPasteboard.write(payload, png: try png(width: 64, height: 32))
  guard case .payload(let read) = try #require(SelectionPasteboard.readContent()) else {
    Issue.record("The project's own payload should be preferred over the PNG beside it.")
    return
  }
  #expect(read == payload)
  #expect(try #require(SelectionPasteboard.readContent()).pixelSize
    == CanvasRecipe(width: 20, height: 10))
  pasteboard.clearContents()
}

@MainActor
@Test func aDocumentFromTheClipboardIsTheSizeOfTheClipboard() throws {
  let payload = try validPayload(width: 20, height: 10)
  let document = try ProjectDocument(clipboard: .payload(payload))

  #expect(document.editorModel.recipe.layerStack.canvas == CanvasRecipe(width: 20, height: 10))
  let layers = document.editorModel.recipe.layerStack.contentLayers
  #expect(layers.count == 1)
  // The canvas is the image's own size, so the pixels land at 1:1 in the
  // corner rather than fitted and centred.
  #expect(layers.first?.rasterLayer?.frame == LayerFrame(x: 0, y: 0, width: 20, height: 10))
  #expect(document.isDocumentEdited)
}

@MainActor
@Test func aDocumentFromTheClipboardExportsItsRasterPixels() async throws {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let document = try ProjectDocument(
    clipboard: .payload(validPayload(width: 20, height: 10)))
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pixeltje-clipboard-export-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }

  let preset = ExportPreset(
    name: "Clipboard PNG",
    format: .png,
    bitDepth: .eight,
    colorSpace: .sRGB)
  let queued = try #require(document.enqueueExport(preset: preset, to: folder, sequence: 1))

  for _ in 0..<500 {
    guard
      document.editorModel.exportJobs.first(where: { $0.id == queued.id })?.state.isActive
        != false
    else { break }
    try await Task.sleep(for: .milliseconds(10))
  }

  let job = try #require(document.editorModel.exportJobs.first(where: { $0.id == queued.id }))
  #expect(job.state == .finished)
  #expect(FileManager.default.fileExists(atPath: job.destination.path))
  let source = try #require(CGImageSourceCreateWithURL(job.destination as CFURL, nil))
  let properties = try #require(
    CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
  #expect(properties[kCGImagePropertyPixelWidth] as? Int == 20)
  #expect(properties[kCGImagePropertyPixelHeight] as? Int == 10)
}

@MainActor
@Test func aDamagedPayloadMakesNoDocumentContent() throws {
  // The same refusal as a paste: pasteboard data is outside data, and a
  // mismatched payload must not become a layer that breaks every render.
  let document = try ProjectDocument(clipboard: .payload(payload()))

  #expect(document.editorModel.recipe.layerStack.canvas == CanvasRecipe(width: 20, height: 10))
  #expect(document.editorModel.recipe.layerStack.contentLayers.isEmpty)
}

@MainActor
@Test func aClipboardImageBecomesTheOnlyLayerOfANewDocument() async throws {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  pasteboard.setData(try png(width: 48, height: 24), forType: .png)
  let content = try #require(SelectionPasteboard.readContent())

  let document = try ProjectDocument(clipboard: content)
  #expect(document.editorModel.recipe.layerStack.canvas == CanvasRecipe(width: 48, height: 24))

  for _ in 0..<500 where document.editorModel.recipe.layerStack.contentLayers.isEmpty {
    try await Task.sleep(for: .milliseconds(10))
  }
  let layers = document.editorModel.recipe.layerStack.contentLayers
  #expect(layers.count == 1)
  #expect(layers.first?.rasterLayer?.frame == LayerFrame(x: 0, y: 0, width: 48, height: 24))
  pasteboard.clearContents()
}

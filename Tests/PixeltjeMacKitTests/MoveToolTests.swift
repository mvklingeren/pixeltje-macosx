import AppKit
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

private func placedImageLayer() -> ProjectLayer {
  ProjectLayer.image(
    ImageLayer(
      source: SourceReference(
        originalFilename: "sky.png",
        linkedPath: "/Pictures/sky.png",
        securityScopedBookmark: nil,
        fingerprint: SourceFingerprint(byteLength: 1024, modificationDate: nil)
      ),
      frame: LayerFrame(x: 100, y: 50, width: 640, height: 480),
      naturalWidth: 640,
      naturalHeight: 480
    )
  )
}

@Test func bareKeysActivateTheirTools() {
  #expect(EditorTool.activated(by: "v") == .move)
  #expect(EditorTool.activated(by: "V") == .move)
  #expect(EditorTool.activated(by: "p") == .pen)
  #expect(EditorTool.activated(by: "t") == .text)
  #expect(EditorTool.activated(by: "b") == .brush)
  #expect(EditorTool.activated(by: "e") == .eraser)
  #expect(EditorTool.activated(by: "g") == .gradient)
  #expect(EditorTool.activated(by: "g", shifted: true) == .fill)
  #expect(EditorTool.activated(by: "f") == nil)
  #expect(EditorTool.activated(by: "") == nil)
  #expect(EditorTool.activated(by: nil) == nil)

  // The toolbox tooltip and the menu item state the same shortcut.
  #expect(EditorTool.move.toolTip == "Select/Move Tool (V)")
  #expect(EditorTool.transform.toolTip == "Free Transform Tool (⌘T)")
  #expect(EditorTool.fill.toolTip == "Fill Tool (⇧G)")
  #expect(EditorTool.text.toolTip == "Text Tool (T)")
  #expect(EditorTool.navigate.toolTip == "Navigate Tool")
  #expect(EditorTool.gradient.symbolName == "square.righthalf.filled")
}

@Test func everyToolSystemSymbolCanBeLoaded() {
  for tool in EditorTool.allCases {
    #expect(
      NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil) != nil,
      "Missing system symbol for \(tool.label)"
    )
  }
}

@Test func transformFieldsFollowTheirVisualKeyboardOrder() {
  #expect(TransformField.x.adjacent(backward: false) == .y)
  #expect(TransformField.y.adjacent(backward: false) == .scaleX)
  #expect(TransformField.scaleX.adjacent(backward: false) == .scaleY)
  #expect(TransformField.scaleY.adjacent(backward: false) == .rotation)
  #expect(TransformField.rotation.adjacent(backward: false) == .shear)
  #expect(TransformField.shear.adjacent(backward: false) == .x)
  #expect(TransformField.x.adjacent(backward: true) == .shear)
}

@Test func scaleLockPreservesTheExistingProportionFromEitherField() {
  let transform = LayerTransform(
    referenceRect: LayerFrame(x: 0, y: 0, width: 640, height: 480),
    scaleX: 2,
    scaleY: 3
  )

  let changedX = settingScale(transform, axis: .x, percentage: 400, constrained: true)
  #expect(changedX.scaleX == 4)
  #expect(changedX.scaleY == 6)

  let changedY = settingScale(transform, axis: .y, percentage: 150, constrained: true)
  #expect(changedY.scaleX == 1)
  #expect(changedY.scaleY == 1.5)

  let unlocked = settingScale(transform, axis: .x, percentage: 400, constrained: false)
  #expect(unlocked.scaleX == 4)
  #expect(unlocked.scaleY == 3)
}

@Test func scaleSliderUsesItsFastRangeWithoutRestrictingPreciseValues() {
  #expect(transformScaleSliderRange == 10...400)
  #expect(clampedTransformScaleSliderValue(5) == 10)
  #expect(clampedTransformScaleSliderValue(50) == 50)
  #expect(clampedTransformScaleSliderValue(275) == 275)
  #expect(clampedTransformScaleSliderValue(800) == 400)
}

@MainActor
@Test func transformToolKeepsAnEligibleLayerReadyUntilAnotherToolIsChosen() throws {
  let document = ProjectDocument()
  let layer = placedImageLayer()
  var recipe = document.editorModel.recipe
  recipe.layerStack = recipe.layerStack.adding(layer)
  document.editorModel.replaceRecipe(recipe)
  let controller = ProjectWindowController(projectDocument: document)

  controller.activateTransformTool(nil)
  var changed = try #require(document.editorModel.transformDraft?.transform)
  changed.scaleX = 3
  document.updateTransformDraft(changed)
  document.commitTransformDraft()

  #expect(document.editorModel.recipe.layerStack.layer(id: layer.id)?.transform?.scaleX == 3)
  #expect(document.editorModel.transformDraft?.targetID == layer.id)
  #expect(document.editorModel.transformDraft?.transform.scaleX == 3)

  controller.activateMoveTool(nil)
  #expect(document.editorModel.activeTool == .move)
  #expect(document.editorModel.transformDraft == nil)
}

@MainActor
@Test func aSingleRawShowsItsSelectedAppleDecoderInTheToolbar() throws {
  let document = ProjectDocument()
  let source = SourceReference(
    originalFilename: "photo.raf",
    linkedPath: "/tmp/photo.raf",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 1, modificationDate: nil)
  )
  document.editorModel.replaceRecipe(
    ProjectRecipe(
      source: source,
      rawDevelopment: RawDevelopmentRecipe(decoderVersion: "CIRAWDecoderVersion9DNG")
    )
  )
  let controller = ProjectWindowController(projectDocument: document)
  let toolbar = NSToolbar(identifier: "RawDecoderToolbarTest")
  let rawDecoderIdentifier = NSToolbarItem.Identifier("PixeltjeMac.RawDecoder")
  let oldBrushIdentifier = NSToolbarItem.Identifier("PixeltjeMac.Brush")

  #expect(controller.toolbarAllowedItemIdentifiers(toolbar).contains(rawDecoderIdentifier))
  #expect(controller.toolbarDefaultItemIdentifiers(toolbar).contains(rawDecoderIdentifier))
  #expect(!controller.toolbarAllowedItemIdentifiers(toolbar).contains(oldBrushIdentifier))
  #expect(!controller.toolbarDefaultItemIdentifiers(toolbar).contains(oldBrushIdentifier))

  let item = try #require(
    controller.toolbar(
      toolbar,
      itemForItemIdentifier: rawDecoderIdentifier,
      willBeInsertedIntoToolbar: true
    )
  )
  #expect(item.label == "Apple RAW Decoder")
  #expect(!item.isHidden)
  #expect(!(item.view is NSGlassEffectView))
  let label = try #require(item.view?.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(label.stringValue == "RAW9")
  #expect(label.toolTip == "Apple RAW decoder: CIRAWDecoderVersion9DNG")
}

@MainActor
@Test func theRawDecoderIndicatorHidesUntilOneDecoderIsUnambiguous() throws {
  let rawDecoderIdentifier = NSToolbarItem.Identifier("PixeltjeMac.RawDecoder")

  let pendingDocument = ProjectDocument()
  pendingDocument.editorModel.replaceRecipe(ProjectRecipe(source: rawSource("pending.raf")))
  let pendingController = ProjectWindowController(projectDocument: pendingDocument)
  let pendingItem = try #require(
    pendingController.toolbar(
      NSToolbar(identifier: "PendingRawDecoderToolbarTest"),
      itemForItemIdentifier: rawDecoderIdentifier,
      willBeInsertedIntoToolbar: true
    )
  )
  #expect(pendingItem.isHidden)

  let backgroundSource = rawSource("background.raf")
  let placedSource = rawSource("placed.dng")
  let placedRaw = ProjectLayer.placedRaw(
    DevelopedRawLayer(
      source: placedSource,
      rawDevelopment: RawDevelopmentRecipe(decoderVersion: "CIRAWDecoderVersion8"),
      frame: LayerFrame(x: 0, y: 0, width: 100, height: 100)
    )
  )
  let multiRawRecipe = ProjectRecipe(
    source: backgroundSource,
    rawDevelopment: RawDevelopmentRecipe(decoderVersion: "CIRAWDecoderVersion9")
  ).applying(.addLayer(placedRaw))
  let multiDocument = ProjectDocument()
  multiDocument.editorModel.replaceRecipe(multiRawRecipe)
  let multiController = ProjectWindowController(projectDocument: multiDocument)
  let multiItem = try #require(
    multiController.toolbar(
      NSToolbar(identifier: "MultipleRawDecoderToolbarTest"),
      itemForItemIdentifier: rawDecoderIdentifier,
      willBeInsertedIntoToolbar: true
    )
  )
  #expect(multiItem.isHidden)
}

private func rawSource(_ filename: String) -> SourceReference {
  SourceReference(
    originalFilename: filename,
    linkedPath: "/tmp/\(filename)",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 1, modificationDate: nil)
  )
}

@MainActor
@Test func penToolColorsBecomeNewPathStyles() {
  let model = EditorModel()
  #expect(model.vectorToolStyle.stroke.color == .black)
  #expect(model.vectorToolStyle.fill?.color == .white)

  let style = VectorToolStyle(
    strokeColor: VectorColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.75),
    fillMode: .solid,
    fillColor: VectorColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 0.5),
    strokeWidth: 24
  )
  model.setVectorToolStyle(style)

  #expect(model.vectorToolStyle.stroke.color == style.strokeColor)
  #expect(model.vectorToolStyle.stroke.width == 24)
  #expect(model.vectorToolStyle.fill?.color == style.fillColor)
}

/// A zero width is how the panel says "no outline", and the renderer already
/// skips a stroke of no width, so the style must carry it through rather than
/// clamping it back up to something visible.
@MainActor
@Test func aZeroStrokeWidthLeavesAPathUnstroked() {
  let model = EditorModel()
  var style = model.vectorToolStyle
  style.strokeWidth = 0
  model.setVectorToolStyle(style)

  #expect(model.vectorToolStyle.stroke.width == 0)
}

@MainActor
@Test func aDragUndoesAsOneMoveRatherThanOneStepPerEvent() {
  let document = ProjectDocument()
  let layer = placedImageLayer()
  var recipe = document.editorModel.recipe
  recipe.layerStack = recipe.layerStack.adding(layer)
  document.editorModel.replaceRecipe(recipe)
  let placed = document.editorModel.recipe

  // What a drag sends: the distance travelled since the previous event, all
  // inside one gesture.
  document.beginEditGesture()
  document.perform(.translateLayer(layer.id, byX: 10, y: 0), interactive: true)
  document.perform(.translateLayer(layer.id, byX: 5, y: -3), interactive: true)
  document.endEditGesture(actionName: "Move Layer")

  let transform = document.editorModel.recipe.layerStack.layer(id: layer.id)?.transform
  #expect(transform?.position == PixelPoint(x: 435, y: 287))
  #expect(
    document.editorModel.recipe.layerStack.layer(id: layer.id)?.imageLayer?.frame
      == layer.imageLayer?.frame
  )

  // One gesture, one undo: the layer returns to where the drag picked it up.
  document.undoManager?.undo()
  #expect(document.editorModel.recipe == placed)
}

@Test func movingAVectorLayerNeedsNoNewRaster() {
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 1920, height: 1080)
  var stack = recipe.layerStack
  let vectorLayerID = stack.ensureActiveVectorLayer()
  stack.appendPath(
    VectorPath(anchors: [VectorAnchor(position: VectorPoint(x: 0.5, y: 0.5))]),
    to: vectorLayerID
  )
  let imageLayer = placedImageLayer()
  recipe.layerStack = stack.adding(imageLayer)

  // Vector artwork is drawn as an overlay above the rendered frame; only a
  // placed image is composited into it.
  let movedVector = EditorAction.translateLayer(vectorLayerID, byX: 8, y: 0)
  let movedImage = EditorAction.translateLayer(imageLayer.id, byX: 8, y: 0)
  #expect(movedVector.requiresRasterRender(in: recipe) == false)
  #expect(movedImage.requiresRasterRender(in: recipe) == true)
}

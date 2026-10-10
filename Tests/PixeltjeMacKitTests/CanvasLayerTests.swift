import CoreGraphics
import CoreImage
import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

private func inspection(width: Int, height: Int, orientation: Int32) -> RawInspection {
  RawInspection(
    selectedDecoderVersion: "test",
    supportedDecoderVersions: ["test"],
    defaults: RawParameters(),
    capabilities: RawCapabilities(),
    exifOrientation: orientation,
    nativeWidth: width,
    nativeHeight: height
  )
}

@Test func canvasFollowsOrientationAndCropOfTheDevelopedImage() {
  let upright = inspection(width: 6000, height: 4000, orientation: 1)
  #expect(upright.canvasRecipe(crop: CropRecipe()) == CanvasRecipe(width: 6000, height: 4000))

  // Orientations 5 through 8 are the quarter turns, which swap the extent.
  let rotated = inspection(width: 6000, height: 4000, orientation: 6)
  #expect(rotated.canvasRecipe(crop: CropRecipe()) == CanvasRecipe(width: 4000, height: 6000))

  let cropped = upright.canvasRecipe(
    crop: CropRecipe(left: 0.25, bottom: 0, right: 0.75, top: 0.5)
  )
  #expect(cropped == CanvasRecipe(width: 3000, height: 2000))
}

@MainActor
@Test func rawDocumentAdoptsItsCanvasFromTheDevelopedExtent() {
  let model = EditorModel(
    recipe: ProjectRecipe(
      source: SourceReference(
        originalFilename: "fixture.dng",
        linkedPath: "/tmp/fixture.dng",
        securityScopedBookmark: nil,
        fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil)
      )
    )
  )
  #expect(model.recipe.layerStack.canvas == .unresolved)

  model.mergeInspection(inspection(width: 6000, height: 4000, orientation: 6))
  #expect(model.recipe.layerStack.canvas == CanvasRecipe(width: 4000, height: 6000))
}

@MainActor
@Test func canvasOnlyProjectSavesAndReopensWithItsExtent() throws {
  let document = ProjectDocument()
  #expect(document.editorModel.recipe.source == nil)
  #expect(document.editorModel.recipe.layerStack.canvas.isResolved)

  document.perform(.setCanvasSize(CanvasRecipe(width: 1200, height: 800)), interactive: false)
  var stack = document.editorModel.recipe.layerStack
  let layerID = stack.ensureActiveVectorLayer()
  let path = VectorPath(anchors: [
    VectorAnchor(position: VectorPoint(x: 0.2, y: 0.3)),
    VectorAnchor(position: VectorPoint(x: 0.8, y: 0.7)),
  ])
  stack.appendPath(path, to: layerID)
  document.perform(.setLayerStack(stack, actionName: "Add Path"), interactive: false)

  // A project with no RAW source is a real document: it saves without a Sources
  // directory and comes back with its extent and artwork intact.
  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  #expect(wrapper.fileWrappers?["Sources"] == nil)

  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()

  #expect(reopened.editorModel.recipe == document.editorModel.recipe)
  #expect(reopened.editorModel.recipe.layerStack.canvas == CanvasRecipe(width: 1200, height: 800))
  #expect(reopened.editorModel.recipe.layerStack.path(id: path.id)?.path == path)
}

@MainActor
@Test func canvasOnlyDocumentRendersNothingWithoutReportingFailure() {
  let document = ProjectDocument()
  document.scheduleRender(interactive: false)

  #expect(document.editorModel.renderedFrame == nil)
  #expect(document.editorModel.renderStatus == .idle)
}

@MainActor
@Test func defaultCanvasFallsBackWhenThePreferenceIsAbsentOrInvalid() throws {
  let suite = try #require(UserDefaults(suiteName: "PixeltjeMacKitTests.\(UUID().uuidString)"))
  defer { suite.removePersistentDomain(forName: suite.description) }

  #expect(AppSettings.storedDefaultCanvas(in: suite) == CanvasRecipe(width: 1920, height: 1080))

  let settings = AppSettings(preferences: suite)
  settings.setDefaultCanvas(CanvasRecipe(width: 2400, height: 1600))
  #expect(AppSettings.storedDefaultCanvas(in: suite) == CanvasRecipe(width: 2400, height: 1600))

  // A zero extent would leave a new document with no canvas, so it is refused.
  settings.setDefaultCanvas(CanvasRecipe(width: 0, height: 0))
  #expect(settings.defaultCanvas == CanvasRecipe(width: 2400, height: 1600))
}

private func renderedGrey(_ image: CIImage, at point: CGPoint) -> Double {
  var pixel = [Float](repeating: 0, count: 4)
  let context = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any
  ])
  context.render(
    image,
    toBitmap: &pixel,
    rowBytes: 16,
    bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
    format: .RGBAf,
    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
  )
  return Double(pixel[0])
}

@Test func checkerboardsAlternateAndOutsideStaysCloseToInside() {
  let square: CGFloat = 8
  let inside = CanvasCheckerboard.image(
    light: CanvasCheckerboard.inside.light,
    dark: CanvasCheckerboard.inside.dark,
    squareSize: square
  )
  let outside = CanvasCheckerboard.image(
    light: CanvasCheckerboard.outside.light,
    dark: CanvasCheckerboard.outside.dark,
    squareSize: square
  )

  // Adjacent squares must actually differ, which is what fails if the generator
  // name is wrong and the fallback solid color is returned instead.
  let first = renderedGrey(inside, at: CGPoint(x: 4, y: 4))
  let second = renderedGrey(inside, at: CGPoint(x: 12, y: 4))
  #expect(abs(first - second) > 0.05)
  #expect(renderedGrey(inside, at: CGPoint(x: 4, y: 12)) == second)

  // Every square outside the canvas is darker than every square inside it, so
  // the extent reads at a glance.
  let insideDarkest = min(first, second)
  let outsideFirst = renderedGrey(outside, at: CGPoint(x: 4, y: 4))
  let outsideSecond = renderedGrey(outside, at: CGPoint(x: 12, y: 4))
  let outsideLightest = max(outsideFirst, outsideSecond)
  #expect(abs(outsideFirst - outsideSecond) > 0.05)
  #expect(outsideLightest < insideDarkest)

  // The workspace should read as a dimmer continuation of the transparency
  // pattern, not as a near-black field around it.
  let insideAverage = (CanvasCheckerboard.inside.light + CanvasCheckerboard.inside.dark) / 2
  let outsideAverage =
    (CanvasCheckerboard.outside.light + CanvasCheckerboard.outside.dark) / 2
  #expect(insideAverage - outsideAverage < 0.25)
}

@Test func checkerGreysAreConvertedFromSRGBToLinearLight() {
  // 0.5 sRGB is ~0.21 linear. Passing sRGB values through unconverted is the
  // failure this guards: the checkerboard would render far too bright.
  #expect(abs(CanvasCheckerboard.linear(0.5) - 0.2140) < 0.001)
  #expect(CanvasCheckerboard.linear(0) == 0)
  #expect(abs(CanvasCheckerboard.linear(1) - 1) < 0.000_1)
  #expect(CanvasCheckerboard.linear(0.8) < 0.8)
}

@MainActor
@Test func savingWritesTheRecipeOnlyAndNeverCopiesLinkedPixels() throws {
  let document = ProjectDocument()
  let raw = SourceReference(
    originalFilename: "portrait.raf",
    linkedPath: "/Pictures/portrait.raf",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil)
  )
  let image = ImageLayer(
    source: SourceReference(
      originalFilename: "sky.png",
      linkedPath: "/Pictures/sky.png",
      securityScopedBookmark: nil,
      fingerprint: SourceFingerprint(byteLength: 2048, modificationDate: nil)
    ),
    frame: LayerFrame(x: 0, y: 0, width: 640, height: 480),
    naturalWidth: 640,
    naturalHeight: 480
  )
  document.editorModel.replaceRecipe(
    ProjectRecipe(source: raw).applying(.addImageLayer(.image(image)))
  )

  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)

  // A saved project is its JSON recipe and nothing else: no Sources directory
  // for the RAW, and no copy of any placed image.
  #expect(wrapper.fileWrappers?.keys.sorted() == ["project.json"])

  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()

  #expect(reopened.editorModel.recipe == document.editorModel.recipe)
  #expect(reopened.editorModel.recipe.layerStack.layers.first?.imageLayer == image)
}

@MainActor
@Test func aProjectThatStillCarriesEmbeddedPixelsOpensFromItsLink() throws {
  let document = ProjectDocument()
  let raw = SourceReference(
    originalFilename: "portrait.raf",
    linkedPath: "/Pictures/portrait.raf",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil)
  )
  document.editorModel.replaceRecipe(ProjectRecipe(source: raw))
  let recipe = try #require(
    document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
      .fileWrappers?["project.json"]
  )
  // Older projects copied the RAW into the package. Opening one must not fail;
  // the copy is ignored and the next save drops it.
  let legacy = FileWrapper(directoryWithFileWrappers: [
    "project.json": recipe,
    "Sources": FileWrapper(directoryWithFileWrappers: [
      "portrait.raf": FileWrapper(regularFileWithContents: Data("raw pixels".utf8))
    ]),
  ])

  let reopened = ProjectDocument()
  try reopened.read(from: legacy, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()

  #expect(reopened.editorModel.recipe.source?.linkedPath == "/Pictures/portrait.raf")
  let resaved = try reopened.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  #expect(resaved.fileWrappers?["Sources"] == nil)
}

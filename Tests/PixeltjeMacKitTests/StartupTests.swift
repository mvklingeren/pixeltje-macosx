import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func launchWithoutFilesStartsANewDocumentUnlessTheOpenDialogIsOn() {
  #expect(
    PixeltjeMacAppDelegate.startupAction(
      urls: [],
      receivedOpenRequest: false,
      hasOpenDocuments: false,
      showsOpenDialogOnStart: false
    ) == .newDocument
  )
  #expect(
    PixeltjeMacAppDelegate.startupAction(
      urls: [],
      receivedOpenRequest: false,
      hasOpenDocuments: false,
      showsOpenDialogOnStart: true
    ) == .showOpenDialog
  )
}

@MainActor
@Test func launchDoesNotAddADocumentWhenSomethingIsAlreadyOpening() {
  let url = URL(fileURLWithPath: "/tmp/fixture.dng")
  // Command-line and Finder input wins over both startup entry points.
  #expect(
    PixeltjeMacAppDelegate.startupAction(
      urls: [url],
      receivedOpenRequest: false,
      hasOpenDocuments: false,
      showsOpenDialogOnStart: true
    ) == .open([url])
  )
  #expect(
    PixeltjeMacAppDelegate.startupAction(
      urls: [],
      receivedOpenRequest: true,
      hasOpenDocuments: false,
      showsOpenDialogOnStart: false
    ) == .doNothing
  )
  // A restored autosaved document is already on screen.
  #expect(
    PixeltjeMacAppDelegate.startupAction(
      urls: [],
      receivedOpenRequest: false,
      hasOpenDocuments: true,
      showsOpenDialogOnStart: false
    ) == .doNothing
  )
}

@MainActor
@Test func requestedLaunchSizeOverridesTheStartupOpenDialog() {
  #expect(
    PixeltjeMacAppDelegate.startupAction(
      urls: [],
      receivedOpenRequest: false,
      hasOpenDocuments: false,
      showsOpenDialogOnStart: true,
      requestsSizedDocument: true
    ) == .newDocument
  )
}

@MainActor
@Test func newDocumentIsAnEmptyProjectAtTheDefaultCanvas() {
  let document = ProjectDocument()

  // File ▸ New saves as the project package without first asking for a type.
  #expect(document.fileType == ProjectDocument.projectTypeIdentifier)
  #expect(document.editorModel.recipe.source == nil)
  #expect(document.editorModel.recipe.layerStack.canvas == AppSettings.storedDefaultCanvas())
  #expect(document.editorModel.recipe.layerStack.canvas.isResolved)
}

@MainActor
@Test func sizedNewDocumentDoesNotUseTheStoredDefaultCanvas() {
  let document = ProjectDocument(canvas: CanvasRecipe(width: 1024, height: 1024))

  #expect(document.editorModel.recipe.source == nil)
  #expect(document.editorModel.recipe.layerStack.canvas == CanvasRecipe(width: 1024, height: 1024))
}

@MainActor
@Test func onlyUntouchedUntitledDocumentsAreDisposableWhenAnImageOpens() {
  let untouched = ProjectDocument()
  #expect(untouched.isUnusedUntitledDocument)

  let sized = ProjectDocument(canvas: CanvasRecipe(width: 1024, height: 1024))
  #expect(sized.isUnusedUntitledDocument)

  let edited = ProjectDocument()
  edited.perform(
    .setCanvasSize(CanvasRecipe(width: 1024, height: 1024)), interactive: false)
  #expect(!edited.isUnusedUntitledDocument)

  let drafting = ProjectDocument()
  drafting.beginEditGesture()
  #expect(!drafting.isUnusedUntitledDocument)

  let snapshotted = ProjectDocument()
  snapshotted.takeSnapshot(named: "Keep this")
  #expect(!snapshotted.isUnusedUntitledDocument)
}

@MainActor
@Test func ordinaryImageExtensionsOpenAsImagesAndRawStaysInTheRawPath() {
  #expect(
    PixeltjeMacAppDelegate.opensAsOrdinaryImage(
      URL(fileURLWithPath: "/tmp/photo.jpg")))
  #expect(
    PixeltjeMacAppDelegate.opensAsOrdinaryImage(
      URL(fileURLWithPath: "/tmp/artwork.png")))
  #expect(
    !PixeltjeMacAppDelegate.opensAsOrdinaryImage(
      URL(fileURLWithPath: "/tmp/capture.dng")))
}

import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
private func rawDocument(
  temperature: Double = 5_000,
  tint: Double = 0,
  capturedTemperature: Double = 5_500,
  capturedTint: Double = 10
) -> ProjectDocument {
  let document = ProjectDocument()
  let undoManager = UndoManager()
  undoManager.groupsByEvent = false
  document.undoManager = undoManager

  let source = SourceReference(
    originalFilename: "frame.dng",
    linkedPath: "/frames/frame.dng",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 1024, modificationDate: nil)
  )
  var parameters = RawParameters()
  parameters.neutralTemperature = temperature
  parameters.neutralTint = tint
  var captured = RawParameters()
  captured.neutralTemperature = capturedTemperature
  captured.neutralTint = capturedTint
  let rawDevelopment = RawDevelopmentRecipe(
    parameters: parameters,
    capturedDefaults: captured
  )
  var seeded = ProjectRecipe(source: source, rawDevelopment: rawDevelopment)
  seeded.layerStack.canvas = document.editorModel.recipe.layerStack.canvas
  document.editorModel.updateRecipeInPlace(seeded)
  return document
}

/// The picker used to be a case of `EditorTool`, which meant arming it threw
/// away whatever tool the user was working in and left a mode behind that
/// re-picked on the next click. It is a request over the active tool now, so
/// the tool underneath is untouched.
@MainActor
@Test func armingThePickerLeavesTheActiveToolAlone() {
  let document = rawDocument()
  document.editorModel.setActiveTool(.brush)

  document.armWhiteBalanceSample()

  #expect(document.editorModel.activeTool == .brush)
  #expect(document.editorModel.pendingSample?.purpose == .whiteBalance)
}

/// A request is armed over one tool. Switching tools underneath it means the
/// user has moved on, so the crosshair goes with the tool it was armed over
/// rather than swallowing the first click of the new one.
@MainActor
@Test func changingToolWithdrawsAStandingRequest() {
  let document = rawDocument()
  document.armWhiteBalanceSample()

  document.editorModel.setActiveTool(.crop)

  #expect(document.editorModel.pendingSample == nil)
}

/// Before shows the captured defaults, which is exactly what a sample would be
/// reading. The two used to be mutually exclusive toggles that each refused
/// while the other was on; arming now simply leaves Before.
@MainActor
@Test func armingThePickerLeavesBeforeRatherThanRefusing() {
  let document = rawDocument()
  document.toggleBeforeAfter()
  #expect(document.editorModel.isShowingBefore)

  document.armWhiteBalanceSample()

  #expect(!document.editorModel.isShowingBefore)
  #expect(document.editorModel.pendingSample != nil)
}

/// And the other direction: turning Before on withdraws a standing request
/// instead of leaving it armed against the values it would be undoing.
@MainActor
@Test func turningBeforeOnWithdrawsAStandingRequest() {
  let document = rawDocument()
  document.armWhiteBalanceSample()

  document.toggleBeforeAfter()

  #expect(document.editorModel.pendingSample == nil)
}

/// A document with no RAW has no white balance to neutralize. The picker says
/// so rather than arming a crosshair that would refuse every click.
@MainActor
@Test func thePickerRefusesToArmWithoutARawWhiteBalance() {
  let document = ProjectDocument()

  document.armWhiteBalanceSample()

  #expect(document.editorModel.pendingSample == nil)
  #expect(!document.editorModel.canPickWhiteBalance)
}

/// As Shot is the targeted counterpart to Reset Apple RAW: it returns the two
/// white-balance values and nothing else, as one undoable step.
@MainActor
@Test func asShotReturnsTemperatureAndTintAsOneStep() throws {
  let document = rawDocument(temperature: 5_000, tint: 0)
  var seeded = document.editorModel.recipe
  var raw = try #require(seeded.layerStack.layer(id: .rawBackground)?.developedRawLayer)
  raw.rawDevelopment.parameters?.exposure = 1.25
  seeded.layerStack.updateLayer(id: .rawBackground) { $0.content = .developedRaw(raw) }
  seeded.rawDevelopment = raw.rawDevelopment
  document.editorModel.updateRecipeInPlace(seeded)
  let steps = document.editorModel.history.steps.count

  document.undoManager?.beginUndoGrouping()
  document.resetWhiteBalanceToAsShot()
  document.undoManager?.endUndoGrouping()

  let parameters = document.editorModel.recipe.layerStack.layer(id: .rawBackground)?
    .developedRawLayer?.rawDevelopment.parameters
  #expect(parameters?.neutralTemperature == 5_500)
  #expect(parameters?.neutralTint == 10)
  // The exposure is left where it was: that is the whole point of having this
  // beside Reset Apple RAW rather than relying on it.
  #expect(parameters?.exposure == 1.25)
  #expect(document.editorModel.history.steps.count == steps + 1)
  #expect(document.editorModel.history.currentStep.name == "As Shot White Balance")
}

/// The As Shot control is only offered when it would change something.
@MainActor
@Test func asShotIsOfferedOnlyWhileTheWhiteBalanceDiffers() {
  let document = rawDocument(temperature: 5_000, tint: 0)
  #expect(document.editorModel.whiteBalanceDiffersFromAsShot)

  // `rawDocument` disables event grouping so tests control undo boundaries;
  // mirror the event group the running app supplies.
  document.undoManager?.beginUndoGrouping()
  document.resetWhiteBalanceToAsShot()
  document.undoManager?.endUndoGrouping()

  #expect(!document.editorModel.whiteBalanceDiffersFromAsShot)
}

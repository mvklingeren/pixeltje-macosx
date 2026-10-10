import Foundation
import PixeltjeMacDomain
import Testing

private func recipe(brightness: Double) -> ProjectRecipe {
  ProjectRecipe(postProcessing: PostProcessingRecipe(brightness: brightness))
}

@Test func historyStartsAtTheOpeningStateWithNothingToUndo() {
  let history = EditHistory(initial: recipe(brightness: 0), name: "Open RAW")

  #expect(history.steps.count == 1)
  #expect(history.steps[0].name == "Open RAW")
  #expect(history.canUndo == false)
  #expect(history.canRedo == false)
  #expect(history.currentRecipe == recipe(brightness: 0))
}

@Test func recordingAppendsOneNamedStepAndMakesItCurrent() {
  var history = EditHistory(initial: recipe(brightness: 0))
  history.record(recipe(brightness: 0.2), name: "Brightness")
  history.record(recipe(brightness: 0.4), name: "Contrast")

  #expect(history.steps.map(\.name) == ["Open", "Brightness", "Contrast"])
  #expect(history.currentIndex == 2)
  #expect(history.canUndo)
  #expect(history.canRedo == false)
}

@Test func undoAndRedoWalkTheSameOrderedList() {
  var history = EditHistory(initial: recipe(brightness: 0))
  history.record(recipe(brightness: 0.2), name: "Brightness")
  history.record(recipe(brightness: 0.4), name: "Contrast")

  #expect(history.undo() == recipe(brightness: 0.2))
  #expect(history.undo() == recipe(brightness: 0))
  #expect(history.undo() == nil)
  #expect(history.canUndo == false)

  #expect(history.redo() == recipe(brightness: 0.2))
  #expect(history.redo() == recipe(brightness: 0.4))
  #expect(history.redo() == nil)
}

@Test func clickingAnEarlierStepReturnsToItsExactState() {
  var history = EditHistory(initial: recipe(brightness: 0))
  history.record(recipe(brightness: 0.2), name: "Brightness")
  let target = history.currentStepID
  history.record(recipe(brightness: 0.4), name: "Contrast")

  #expect(history.move(to: target) == recipe(brightness: 0.2))
  #expect(history.currentStepID == target)
  // The abandoned branch is still there until something replaces it.
  #expect(history.canRedo)
  #expect(history.move(to: target) == nil)
}

@Test func aNewEditAfterUndoingTruncatesTheForwardHistory() {
  var history = EditHistory(initial: recipe(brightness: 0))
  history.record(recipe(brightness: 0.2), name: "Brightness")
  history.record(recipe(brightness: 0.4), name: "Contrast")
  let discarded = history.currentStepID
  history.undo()

  history.record(recipe(brightness: 0.9), name: "Saturation")

  #expect(history.steps.map(\.name) == ["Open", "Brightness", "Saturation"])
  #expect(history.contains(discarded) == false)
  #expect(history.canRedo == false)
  #expect(history.currentRecipe == recipe(brightness: 0.9))
}

@Test func aStepAheadOfTheCurrentPositionIsMarkedAsUndone() {
  var history = EditHistory(initial: recipe(brightness: 0))
  history.record(recipe(brightness: 0.2), name: "Brightness")
  let ahead = history.currentStepID
  history.undo()

  #expect(history.isAhead(ahead))
  #expect(history.isAhead(history.currentStepID) == false)
}

@Test func aSnapshotRestoresAfterItsOwnBranchHasBeenDiscarded() {
  var history = EditHistory(initial: recipe(brightness: 0))
  history.record(recipe(brightness: 0.6), name: "Brightness")
  let pinned = history.addSnapshot(name: "Warm", recipe: history.currentRecipe)

  history.undo()
  history.record(recipe(brightness: -0.3), name: "Brightness")

  // The step that produced the snapshot is gone; the snapshot is not.
  #expect(history.steps.count == 2)
  #expect(history.snapshot(pinned)?.recipe == recipe(brightness: 0.6))

  // Restoring is recorded as an ordinary step, so it undoes like any edit.
  history.record(history.snapshot(pinned)!.recipe, name: "Restore “Warm”")
  #expect(history.currentRecipe == recipe(brightness: 0.6))
  #expect(history.undo() == recipe(brightness: -0.3))
}

@Test func snapshotsRenameDeleteAndSuggestUniqueNames() {
  var history = EditHistory(initial: recipe(brightness: 0))
  let first = history.addSnapshot(name: history.suggestedSnapshotName(), recipe: recipe(brightness: 0))
  #expect(history.snapshot(first)?.name == "Snapshot 1")

  let second = history.addSnapshot(name: history.suggestedSnapshotName(), recipe: recipe(brightness: 1))
  #expect(history.snapshot(second)?.name == "Snapshot 2")

  history.renameSnapshot(first, to: "  Base look  ")
  #expect(history.snapshot(first)?.name == "Base look")
  // An empty name is not a rename.
  history.renameSnapshot(first, to: "   ")
  #expect(history.snapshot(first)?.name == "Base look")

  history.removeSnapshot(first)
  #expect(history.snapshots.map(\.id) == [second])
}

@Test func trimmingDropsTheOldestEditsButNeverTheOpeningState() {
  var history = EditHistory(initial: recipe(brightness: 0), name: "Open RAW", stepLimit: 4)
  for index in 1...6 {
    history.record(recipe(brightness: Double(index)), name: "Edit \(index)")
  }

  #expect(history.steps.count == 4)
  #expect(history.steps[0].name == "Open RAW")
  #expect(history.steps.map(\.name) == ["Open RAW", "Edit 4", "Edit 5", "Edit 6"])
  #expect(history.currentIndex == 3)
  #expect(history.currentRecipe == recipe(brightness: 6))
}

@Test func historySurvivesEncodingAndDecoding() throws {
  var history = EditHistory(initial: recipe(brightness: 0), name: "Open RAW")
  history.record(recipe(brightness: 0.5), name: "Brightness")
  history.addSnapshot(name: "Warm", recipe: recipe(brightness: 0.5))
  history.undo()

  let data = try JSONEncoder().encode(history)
  let restored = try JSONDecoder().decode(EditHistory.self, from: data)

  #expect(restored == history)
  #expect(restored.currentIndex == 0)
  #expect(restored.canRedo)
}

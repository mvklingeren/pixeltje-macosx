import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func comfyUIHistoryPersistsAcrossDocumentsAndRecordsTerminalOutcome() throws {
  let fixture = try ComfyUIHistoryFixture()
  defer { fixture.cleanUp() }
  let store = ComfyUIHistoryStore(
    fileURL: fixture.fileURL, preferences: fixture.preferences)
  let entry = fixture.entry()

  store.record(entry)
  store.setBackendID("remote-42", for: entry.id)
  store.update(jobID: entry.id, state: .succeeded)

  let reloaded = ComfyUIHistoryStore(
    fileURL: fixture.fileURL, preferences: fixture.preferences)
  #expect(reloaded.entries.count == 1)
  #expect(reloaded.entries[0].id == entry.id)
  #expect(reloaded.entries[0].backendID == "remote-42")
  #expect(reloaded.entries[0].status == .succeeded)
  #expect(reloaded.entries[0].finishedAt != nil)
  #expect(reloaded.entries[0].modifiedParameters == entry.modifiedParameters)
}

@MainActor
@Test func disabledComfyUIHistoryLeavesExistingEntriesAndRejectsNewOnes() throws {
  let fixture = try ComfyUIHistoryFixture()
  defer { fixture.cleanUp() }
  let store = ComfyUIHistoryStore(
    fileURL: fixture.fileURL, preferences: fixture.preferences)
  let first = fixture.entry()
  store.record(first)

  let settings = AppSettings(preferences: fixture.preferences)
  settings.setDisablesComfyUIHistory(true)
  store.record(fixture.entry(id: UUID(), prompt: "private prompt"))

  #expect(store.entries.map(\.id) == [first.id])
}

@MainActor
@Test func unfinishedComfyUIHistoryBecomesInterruptedWhenReloaded() throws {
  let fixture = try ComfyUIHistoryFixture()
  defer { fixture.cleanUp() }
  let store = ComfyUIHistoryStore(
    fileURL: fixture.fileURL, preferences: fixture.preferences)
  let entry = fixture.entry()
  store.record(entry)
  store.update(jobID: entry.id, state: .denoising(step: 3, total: 12))

  let reloaded = ComfyUIHistoryStore(
    fileURL: fixture.fileURL, preferences: fixture.preferences)
  #expect(reloaded.entries[0].status == .interrupted)
  #expect(reloaded.entries[0].statusDetail?.contains("closed") == true)
}

@MainActor
@Test func comfyUIHistoryMeasuresElapsedTimeFromQueueToFinish() {
  let fixture = try? ComfyUIHistoryFixture()
  guard let fixture else {
    Issue.record("Could not create ComfyUI history fixture")
    return
  }
  defer { fixture.cleanUp() }
  var entry = fixture.entry()

  #expect(entry.elapsedSeconds == nil)

  entry.finishedAt = entry.queuedAt.addingTimeInterval(2.6)
  #expect(abs((entry.elapsedSeconds ?? 0) - 2.6) < 0.000_001)
}

@MainActor
@Test func restoringComfyUIHistoryUsesFixedSeedAndSkipsChangedSettings() {
  let model = EditorModel()
  model.selectComfyUIWorkflow("z-image")
  let steps = ComfyUIParameterAddress(nodeID: "70", inputName: "steps")
  let removed = ComfyUIParameterAddress(nodeID: "old-node", inputName: "old-input")
  let form = ComfyUIWorkflowForm(
    templateID: "z-image",
    templateRevision: "new-revision",
    nodes: [
      ComfyUIWorkflowNodeDefinition(
        id: "70",
        title: "Sampler",
        classType: "KSampler",
        order: 1,
        parameters: [
          ComfyUIParameterDefinition(
            address: steps,
            label: "Steps",
            control: .integer(isUnsigned: false),
            templateValue: .signedInteger(8),
            minimum: .signedInteger(1),
            maximum: .signedInteger(50),
            step: .signedInteger(1),
            tooltip: nil,
            isAdvanced: false,
            isConnected: false)
        ])
    ],
    templateValues: [steps: .signedInteger(8)])
  model.setComfyUIWorkflowForm(form)

  var settings = InpaintingToolState()
  settings.seed = 9_876
  settings.randomizeSeed = true
  settings.maskBlur = 14
  let entry = ComfyUIHistoryEntry(
    id: UUID(),
    queuedAt: Date(),
    finishedAt: Date(),
    status: .succeeded,
    statusDetail: nil,
    backendID: "remote",
    executionTarget: .local,
    templateID: "z-image",
    templateRevision: "old-revision",
    mode: .textToImage,
    prompt: "restored prompt",
    generationSettings: settings,
    modifiedParameters: [
      ComfyUIParameterRecord(address: steps, value: .signedInteger(12)),
      ComfyUIParameterRecord(address: removed, value: .boolean(true)),
    ])

  model.restoreComfyUIHistoryDraft(entry, executionTarget: .local)

  #expect(model.inpaintingTool.seed == 9_876)
  #expect(model.inpaintingTool.randomizeSeed == false)
  #expect(model.inpaintingTool.maskBlur == 14)
  #expect(model.comfyUIParameterValues[steps] == .signedInteger(12))
  #expect(model.comfyUIHistoryRestoreNotice?.contains("workflow has changed") == true)
  #expect(model.comfyUIHistoryRestoreNotice?.contains("1 unavailable setting") == true)
}

@MainActor
private struct ComfyUIHistoryFixture {
  let directory: URL
  let fileURL: URL
  let suiteName: String
  let preferences: UserDefaults

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComfyUIHistoryTests-\(UUID().uuidString)", isDirectory: true)
    fileURL = directory.appendingPathComponent("history.json")
    suiteName = "ComfyUIHistoryTests.\(UUID().uuidString)"
    preferences = try #require(UserDefaults(suiteName: suiteName))
  }

  func entry(
    id: UUID = UUID(),
    prompt: String = "a small red boat"
  ) -> ComfyUIHistoryEntry {
    var settings = InpaintingToolState()
    settings.randomizeSeed = false
    settings.seed = 42
    return ComfyUIHistoryEntry(
      id: id,
      queuedAt: Date(timeIntervalSince1970: 1_000),
      finishedAt: nil,
      status: .queued,
      statusDetail: nil,
      backendID: nil,
      executionTarget: .local,
      templateID: "z-image",
      templateRevision: "revision",
      mode: .textToImage,
      prompt: prompt,
      generationSettings: settings,
      modifiedParameters: [
        ComfyUIParameterRecord(
          address: ComfyUIParameterAddress(nodeID: "70", inputName: "steps"),
          value: .signedInteger(12))
      ])
  }

  func cleanUp() {
    preferences.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }
}

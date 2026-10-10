import Foundation
@testable import PixeltjePipelineEditor
import Testing

@MainActor
@Test func classifierPackageSelectionLinksTheCreatedInferenceWorkflow() async throws {
  guard let modelPath = ProcessInfo.processInfo.environment["PIXELTJE_MNIST_CLASSIFIER_MODEL"]
  else { return }
  let preferences = try #require(UserDefaults(suiteName: UUID().uuidString))
  let model = PipelineEditorModel(
    newWorkflowSettings: PipelineNewWorkflowSettings(preferences: preferences))
  model.createModelInferenceDocument()
  let node = try #require(model.modelPackageNodes.first)
  #expect(node.kind.rawValue == "coreai.imageClassifier")
  model.setModelPackageURL(URL(fileURLWithPath: modelPath, isDirectory: true),
    for: node.id)
  for _ in 0..<100 where model.modelPackageNodes.first?
    .resources["model"]?.linkedReference == nil {
    try await Task.sleep(for: .milliseconds(50))
  }
  let linked = try #require(model.modelPackageNodes.first?
    .resources["model"]?.linkedReference)
  #expect(linked.functionName == "main")
  #expect(linked.componentRole == "classifier")
  #expect(linked.packageID.hasPrefix("coreai.classifier."))
}

@MainActor
@Test func directGPUProgramRunAdvancesAndKeepsItsPreview() async throws {
  try await verifyDirectPreviewRun("shader-flurry.pixpipeline.json")
}

@MainActor
@Test func directMetalShaderRunAdvancesAndKeepsItsPreview() async throws {
  // Without an attached preview view, shaders produce one bootstrap frame.
  // Further frames and their FPS require display refreshes; GPU Programs
  // publish a frame on every graph call instead.
  try await verifyDirectPreviewRun("shadertoy-sdf-primitives.pixpipeline.json",
    expectsFrameRate: false)
}

@MainActor
@Test func GPUProgramRunWithDebugCaptureCompletesOneCall() async throws {
  let preferences = try #require(UserDefaults(suiteName: UUID().uuidString))
  preferences.set(true, forKey: "PipelineEditor.debugModeEnabled")
  let model = PipelineEditorModel(
    newWorkflowSettings: PipelineNewWorkflowSettings(preferences: preferences))
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  try model.open(examples.appendingPathComponent("shader-flurry.pixpipeline.json"))

  for _ in 0..<100 where !model.canRun {
    try await Task.sleep(for: .milliseconds(50))
  }
  let canRun = model.canRun
  try #require(canRun, Comment(rawValue: model.runUnavailableReason ?? "Run unavailable"))

  model.run(previewFrame: 0)
  defer { model.cancelExecution() }
  for _ in 0..<100 where model.isRunning {
    try await Task.sleep(for: .milliseconds(50))
  }
  let completed = !model.isRunning && model.currentCall == 1
  #expect(completed, Comment(rawValue: model.statusMessage))
  let hasPreview = model.generatedPreview != nil
  #expect(hasPreview, Comment(rawValue: model.statusMessage))
}

@MainActor
private func verifyDirectPreviewRun(_ filename: String,
  expectsFrameRate: Bool = true) async throws {
  let preferences = try #require(UserDefaults(suiteName: UUID().uuidString))
  preferences.set(false, forKey: "PipelineEditor.saveGeneratedImagesToDisk")
  let model = PipelineEditorModel(
    newWorkflowSettings: PipelineNewWorkflowSettings(preferences: preferences))
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  try model.open(examples.appendingPathComponent(filename))

  for _ in 0..<100 where !model.canRun {
    try await Task.sleep(for: .milliseconds(50))
  }
  let canRun = model.canRun
  let diagnostics = model.validationReport.errors.map(\.message).joined(separator: " | ")
  try #require(canRun, Comment(rawValue: "\(model.runUnavailableReason ?? "Run unavailable") | \(diagnostics)"))

  model.run()
  defer { model.cancelExecution() }
  for _ in 0..<100 where model.isRunning && model.currentCall < 3 {
    try await Task.sleep(for: .milliseconds(50))
  }
  let isRunning = model.isRunning
  let advanced = model.currentCall >= 3
  let hasPreview = model.liveMetalPreviewSize != nil
  let reportedFPS = model.livePreview.framesPerSecond
  #expect(isRunning, Comment(rawValue: model.statusMessage))
  #expect(advanced, Comment(rawValue: model.statusMessage))
  #expect(hasPreview, Comment(rawValue: model.statusMessage))
  if expectsFrameRate {
    #expect(reportedFPS > 0, Comment(rawValue: "Live preview reports \(reportedFPS) FPS"))
  }
}

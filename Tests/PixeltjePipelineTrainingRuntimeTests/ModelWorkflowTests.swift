import Foundation
import PixeltjeModelDesign
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineTrainingRuntime
import Testing

@Test func legacyModelOpensAsCanonicalPipelineWorkflow() throws {
  let legacy = ModelDesignDocument.starter()
  let workflow = ModelWorkflowBridge.importLegacy(legacy)
  #expect(workflow.mode == .generic)
  #expect(workflow.nodes.last?.kind == .modelTrain)
  #expect(workflow.primaryOutputNodeIDs == [workflow.nodes.last!.id])
  let decoded = try PipelineJSON.decode(PipelineJSON.encode(workflow))
  let recovered = try ModelWorkflowBridge.design(in: decoded)
  #expect(try ModelDesignJSON.architectureSHA256(recovered)
    == ModelDesignJSON.architectureSHA256(legacy))
  #expect(PipelineNodeRegistry.coreAIV1.descriptor(for: .modelInput) != nil)
  #expect(PipelineNodeRegistry.coreAIV1.descriptor(for: .modelTrain)?.isTerminal == true)
}

@Test func modelWorkflowRejectsUnsupportedDtypeBeforeTraining() throws {
  var workflow = ModelWorkflowBridge.importLegacy(.starter())
  let inputIndex = try #require(workflow.nodes.firstIndex(where: { $0.kind == .modelInput }))
  workflow.nodes[inputIndex].parameters["dtype"] = .string("float16")
  #expect(throws: ModelWorkflowError.self) {
    try ModelWorkflowBridge.design(in: workflow)
  }
}

@Test func trainingWorkflowHasAnExecutableModelOutput() async throws {
  let workflow = ModelWorkflowBridge.importLegacy(.starter())
  let worker = ModelTrainingWorker()
  let engine = PixeltjePipelineEngine(additionalNodeExecutors: [
    ModelTrainingRuntime.executor(worker: worker),
  ])
  let report = await engine.validate(workflow)
  #expect(report.isValid)
  let profile = await engine.executionProfile(for: workflow)
  #expect(profile?.outputKind == .model)
}

@Test func mnistWorkflowIsAnOrdinaryPipelineWithoutDatasetBytes() async throws {
  let workflow = ModelWorkflowBridge.importLegacy(.mnistStarter())
  let design = try ModelWorkflowBridge.design(in: workflow)
  #expect(design.training.resolvedTask == .classification)
  #expect(design.training.datasetPreset == .mnist)
  #expect(workflow.nodes.filter { $0.kind == .modelTrain }.count == 1)
  let engine = PixeltjePipelineEngine(additionalNodeExecutors: [
    ModelTrainingRuntime.executor(worker: ModelTrainingWorker()),
  ])
  #expect(await engine.validate(workflow).isValid)
  let json = try String(decoding: PipelineJSON.encode(workflow), as: UTF8.self)
  #expect(json.contains("mnist"))
  #expect(!json.contains("x_train"))
}

@Test func missingTrainingPackagesFailBeforeCreatingARunFolder() async throws {
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pixeltje-training-preflight-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporary) }
  let python = temporary.appendingPathComponent("python")
  try "#!/bin/sh\nexec /usr/bin/python3 -I -S \"$@\"\n".write(
    to: python, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755],
    ofItemAtPath: python.path)
  let outputRoot = temporary.appendingPathComponent("runs", isDirectory: true)
  let engine = PixeltjePipelineEngine(additionalNodeExecutors: [
    ModelTrainingRuntime.executor(worker: ModelTrainingWorker()),
  ])
  do {
    _ = try await engine.execute(ModelWorkflowBridge.importLegacy(.starter()),
      packageRootsByID: [:], invocation: PipelineInvocation(values: [
        ModelTrainingInvocation.pythonExecutableKey: .string(python.path),
        ModelTrainingInvocation.outputDirectoryKey: .string(outputRoot.path),
      ]))
    Issue.record("Training should require its Python packages")
  } catch {
    #expect(error.localizedDescription.contains("Missing training packages"))
  }
  #expect(!FileManager.default.fileExists(atPath: outputRoot.path))
}

/// Set PIXELTJE_TRAINING_TEST_PYTHON to a compatible environment to exercise
/// training, Core AI conversion, and the real Pipeline scheduler together.
@Test func trainingWorkflowRunsThroughSharedEngineWhenPythonIsConfigured() async throws {
  guard let python = ProcessInfo.processInfo.environment["PIXELTJE_TRAINING_TEST_PYTHON"] else {
    return
  }
  var workflow = ModelWorkflowBridge.importLegacy(.starter())
  let trainIndex = try #require(workflow.nodes.firstIndex(where: { $0.kind == .modelTrain }))
  workflow.nodes[trainIndex].parameters["epochs"] = .integer(1)
  let outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pixeltje-training-integration-\(UUID().uuidString)", isDirectory: true)
  let worker = ModelTrainingWorker()
  let engine = PixeltjePipelineEngine(additionalNodeExecutors: [
    ModelTrainingRuntime.executor(worker: worker),
  ])
  let result = try await engine.execute(workflow, packageRootsByID: [:],
    invocation: PipelineInvocation(values: [
      ModelTrainingInvocation.pythonExecutableKey: .string(python),
      ModelTrainingInvocation.outputDirectoryKey: .string(outputRoot.path),
    ]))
  guard case .model(let trained) = result else {
    Issue.record("Train Model did not produce an .aimodel asset")
    return
  }
  #expect(FileManager.default.fileExists(atPath: trained.assetURL.path))
  #expect(FileManager.default.fileExists(atPath: trained.checkpointURL.path))
  #expect(trained.validationLoss?.isFinite == true)
}

@Test func classifierTrainsAndExportsThroughSharedEngineWhenPythonIsConfigured() async throws {
  guard let python = ProcessInfo.processInfo.environment["PIXELTJE_TRAINING_TEST_PYTHON"] else {
    return
  }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pixeltje-classifier-integration-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let dataset = root.appendingPathComponent("sample-labels.npz")
  let fixture = Process()
  fixture.executableURL = URL(fileURLWithPath: python)
  fixture.arguments = ["-c", """
    import numpy as np
    import sys
    rng = np.random.default_rng(42)
    np.savez(sys.argv[1], inputs=rng.random((40, 1, 28, 28), dtype=np.float32),
             labels=np.arange(40, dtype=np.int64) % 10,
             test_inputs=rng.random((10, 1, 28, 28), dtype=np.float32),
             test_labels=np.arange(10, dtype=np.int64))
    """, dataset.path]
  try fixture.run()
  fixture.waitUntilExit()
  #expect(fixture.terminationStatus == 0)
  var workflow = ModelWorkflowBridge.importLegacy(.mnistStarter())
  let trainID = try #require(workflow.nodes.first(where: { $0.kind == .modelTrain })?.id)
  let trainIndex = try #require(workflow.nodes.firstIndex(where: { $0.id == trainID }))
  workflow.nodes[trainIndex].parameters["epochs"] = .integer(1)
  let pathID = PipelineNodeID(rawValue: "test-classification-dataset")
  workflow.nodes.append(PipelineNode(id: pathID, kind: .primitiveFilePath,
    parameters: ["path": .string(dataset.path), "mode": .string("absolute")]))
  workflow.connections.append(.init(
    output: .init(nodeID: pathID, port: "value"),
    input: .init(nodeID: trainID, port: "dataset")))
  let engine = PixeltjePipelineEngine(additionalNodeExecutors: [
    ModelTrainingRuntime.executor(worker: ModelTrainingWorker()),
  ])
  let result = try await engine.execute(workflow, packageRootsByID: [:],
    invocation: PipelineInvocation(values: [
      ModelTrainingInvocation.pythonExecutableKey: .string(python),
      ModelTrainingInvocation.outputDirectoryKey: .string(root.path),
    ]))
  guard case .model(let trained) = result else {
    Issue.record("Classifier did not produce a Core AI model")
    return
  }
  #expect(FileManager.default.fileExists(atPath: trained.assetURL.path))
  #expect(FileManager.default.fileExists(atPath: trained.checkpointURL.path))
  #expect(trained.validationAccuracy.map { (0...1).contains($0) } == true)
  #expect(trained.testAccuracy.map { (0...1).contains($0) } == true)
  #expect(FileManager.default.fileExists(atPath:
    trained.checkpointURL.deletingLastPathComponent()
      .appendingPathComponent("metrics.json").path))
}

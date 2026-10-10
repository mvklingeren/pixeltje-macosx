import Foundation
import PixeltjeModelDesign
import PixeltjePipelineDomain
import PixeltjePipelineEngine

public enum ModelTrainingInvocation {
  public static let pythonExecutableKey = "modelTraining.pythonExecutable"
  public static let outputDirectoryKey = "modelTraining.outputDirectory"
}

public enum ModelTrainingRuntimeError: Error, LocalizedError {
  case invalid(String)
  case processFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message), .processFailed(let message): message
    }
  }
}

/// One reviewed external executor installed in the shared Pipeline engine.
/// Python is selected by the host and never stored in the workflow document.
public actor ModelTrainingWorker {
  private var activeProcess: Process?

  public init() {}

  public func cancel() {
    guard let activeProcess, activeProcess.isRunning else { return }
    activeProcess.terminate()
  }

  public func train(
    node: PipelineNode, inputs: [String: PipelineNodeValue],
    context: PipelineNodeExecutionContext
  ) async throws -> PipelineTrainedModel {
    guard inputs["model"]?.value(as: PipelineNodeID.self) != nil,
      let document = context.document else {
      throw ModelTrainingRuntimeError.invalid("Train Model needs a connected Model Output.")
    }
    let design = try ModelWorkflowBridge.design(in: document, for: node.id)
    let pythonPath = try context.invocation.string(for: ModelTrainingInvocation.pythonExecutableKey)
    guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
      throw ModelTrainingRuntimeError.invalid(
        "Choose an executable Python environment in the Pipeline Editor.")
    }
    try await runPython(
      executable: URL(fileURLWithPath: pythonPath),
      arguments: ["-c", Self.environmentCheck],
      directory: FileManager.default.temporaryDirectory) { _ in }
    let rootPath = try context.invocation.string(for: ModelTrainingInvocation.outputDirectoryKey)
    let outputRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
    let graphHash = try ModelDesignJSON.architectureSHA256(design)
    let runRoot = outputRoot.appendingPathComponent(
      "model-\(graphHash.prefix(12))-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
    let project = runRoot.appendingPathComponent("project", isDirectory: true)
    try ModelPythonExporter.export(design, workflow: document, to: project)

    let dataset = try inputs["dataset"]?.value(as: String.self).flatMap {
      try resolveDataset($0, relativeTo: context.sourceMediaRoot)
    }
    var trainingArguments = [
      "train.py", "--output-dir", runRoot.appendingPathComponent("checkpoints").path,
      "--epochs", String(design.training.epochs),
      "--batch-size", String(design.training.batchSize),
      "--learning-rate", String(design.training.learningRate),
      "--seed", String(design.training.seed),
    ]
    if let dataset { trainingArguments += ["--data", dataset.path] }
    if design.training.datasetPreset == .mnist && dataset == nil {
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
      let cache = support.appendingPathComponent(
        "Pixeltje/Datasets/MNIST/mnist.npz")
      trainingArguments += ["--dataset-cache", cache.path]
    }
    var validationLoss: Double?
    var validationAccuracy: Double?
    var testAccuracy: Double?
    try await runPython(
      executable: URL(fileURLWithPath: pythonPath), arguments: trainingArguments,
      directory: project) { line in
        if let metric = Self.epochMetric(from: line) {
          validationLoss = metric.validationLoss
          validationAccuracy = metric.validationAccuracy
          let accuracy = metric.validationAccuracy.map {
            " · validation accuracy \(String(format: "%.2f", $0 * 100))%"
          } ?? ""
          await context.progress(.init(
            stage: .generating,
            message: "Epoch \(metric.epoch)/\(metric.epochs) · validation loss \(String(format: "%.6f", metric.validationLoss))\(accuracy)",
            completedUnitCount: metric.epoch,
            totalUnitCount: metric.epochs,
            activeNodeIDs: [node.id]))
        } else if let metric = Self.testMetric(from: line) {
          testAccuracy = metric.testAccuracy
          await context.progress(.init(stage: .generating,
            message: "Held-out test accuracy \(String(format: "%.2f", metric.testAccuracy * 100))%",
            activeNodeIDs: [node.id]))
        } else if line.hasPrefix("Downloading MNIST") || line.hasPrefix("Using dataset") {
          await context.progress(.init(stage: .preparing, message: line,
            activeNodeIDs: [node.id]))
        }
      }
    try Task.checkCancellation()
    await context.progress(.init(stage: .preparing, message: "Converting trained model to Core AI…",
      activeNodeIDs: [node.id]))
    let checkpoint = runRoot.appendingPathComponent("checkpoints/checkpoint.pt")
    let asset = runRoot.appendingPathComponent("trained.aimodel", isDirectory: true)
    try await runPython(
      executable: URL(fileURLWithPath: pythonPath),
      arguments: [
        "export_coreai.py", "--checkpoint", checkpoint.path, "--output", asset.path,
      ], directory: project) { line in
        await context.progress(.init(stage: .generating, message: line,
          activeNodeIDs: [node.id]))
      }
    try Task.checkCancellation()
    guard FileManager.default.fileExists(atPath: asset.path) else {
      throw ModelTrainingRuntimeError.processFailed(
        "Core AI conversion returned without creating the .aimodel package.")
    }
    return PipelineTrainedModel(assetURL: asset, checkpointURL: checkpoint,
      validationLoss: validationLoss, validationAccuracy: validationAccuracy,
      testAccuracy: testAccuracy, semanticPipelineSHA256: context.semanticSHA256)
  }

  private func resolveDataset(_ value: String, relativeTo root: URL?) throws -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ModelTrainingRuntimeError.invalid("The connected dataset path is empty.")
    }
    let url: URL
    if trimmed.hasPrefix("/") {
      url = URL(fileURLWithPath: trimmed)
    } else {
      guard let root else {
        throw ModelTrainingRuntimeError.invalid(
          "Save the workflow before using a relative dataset path.")
      }
      let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
      url = resolvedRoot.appendingPathComponent(trimmed)
        .resolvingSymlinksInPath().standardizedFileURL
      guard url.path == resolvedRoot.path
        || url.path.hasPrefix(resolvedRoot.path + "/") else {
        throw ModelTrainingRuntimeError.invalid(
          "A relative dataset path must stay inside the workflow folder.")
      }
    }
    var isDirectory: ObjCBool = false
    guard url.pathExtension.lowercased() == "npz",
      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue else {
      throw ModelTrainingRuntimeError.invalid(
        "The dataset must be an existing .npz file with arrays for the selected training task.")
    }
    return url
  }

  private struct EpochMetric: Decodable {
    let epoch: Int
    let epochs: Int
    let validationLoss: Double
    let validationAccuracy: Double?

    enum CodingKeys: String, CodingKey {
      case epoch, epochs
      case validationLoss = "validation_loss"
      case validationAccuracy = "validation_accuracy"
    }
  }

  private struct TestMetric: Decodable {
    let kind: String
    let testAccuracy: Double

    enum CodingKeys: String, CodingKey {
      case kind
      case testAccuracy = "test_accuracy"
    }
  }

  private static let environmentCheck = """
    import importlib.util
    import sys
    packages = (("torch", "torch"), ("numpy", "numpy"),
                ("coreai_torch", "coreai-torch"), ("coreai", "coreai-core"))
    missing = [name for module, name in packages
               if importlib.util.find_spec(module) is None]
    if missing:
        sys.exit("Missing training packages: " + ", ".join(missing)
                 + ". Choose a virtual environment with these packages installed.")
    """

  private static func epochMetric(from line: String) -> EpochMetric? {
    try? JSONDecoder().decode(EpochMetric.self, from: Data(line.utf8))
  }

  private static func testMetric(from line: String) -> TestMetric? {
    guard let metric = try? JSONDecoder().decode(TestMetric.self, from: Data(line.utf8)),
      metric.kind == "test" else { return nil }
    return metric
  }

  private func runPython(
    executable: URL, arguments: [String], directory: URL,
    onLine: @escaping (String) async -> Void
  ) async throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = output
    try process.run()
    activeProcess = process
    var recentLines: [String] = []
    defer { activeProcess = nil }
    try await withTaskCancellationHandler {
      for try await line in output.fileHandleForReading.bytes.lines {
        if Task.isCancelled { throw CancellationError() }
        recentLines.append(line)
        if recentLines.count > 20 { recentLines.removeFirst() }
        await onLine(line)
      }
      process.waitUntilExit()
      try Task.checkCancellation()
      guard process.terminationStatus == 0 else {
        throw ModelTrainingRuntimeError.processFailed(
          recentLines.suffix(8).joined(separator: "\n").isEmpty
            ? "Python exited with status \(process.terminationStatus)."
            : recentLines.suffix(8).joined(separator: "\n"))
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }
}

public enum ModelTrainingRuntime {
  public static func executor(worker: ModelTrainingWorker) -> PipelineNodeExecutor {
    PipelineNodeExecutor(kind: .modelTrain) { node, inputs, context in
      let model = try await worker.train(node: node, inputs: inputs, context: context)
      return PipelineNodeResult(terminalOutput: .model(model))
    }
  }
}

import Darwin
import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineTextRuntime

/// Headless verification and demonstration of the saved Core AI text loop.
@main
enum PipelineTextLoopCommand {
  static func main() async {
    do {
      var arguments = Array(CommandLine.arguments.dropFirst())
      let traceURL = try PipelineTraceCLIOptions.takeDebugLog(from: &arguments)
      let checkOnly = arguments.first == "--check"
      if checkOnly { arguments.removeFirst() }
      guard (1...3).contains(arguments.count) else {
        throw Failure.usage
      }
      let workflow = URL(fileURLWithPath: arguments[0])
      let package = arguments.count > 1
        ? URL(fileURLWithPath: arguments[1])
        : CoreAITextPipelineFamily.defaultPackageURL()
      let directory = arguments.count > 2
        ? URL(fileURLWithPath: arguments[2])
        : FileManager.default.temporaryDirectory.appendingPathComponent(
          "PixeltjePipelineTextLoop", isDirectory: true)
      let document = try PipelineJSON.decode(Data(contentsOf: workflow))
      var registry = PipelineNodeRegistry.coreAIV1
      registry.register(CoreAITextPipelineFamily.makeCompositeNodeDescriptor())
      guard let loop = PipelineControlFlow.activeLoop(in: document, registry: registry)
      else { throw Failure.invalidLoop }
      let settings = loop.settings
      guard let limit = settings.maxCalls,
        (1...100).contains(limit), (0...60_000).contains(settings.delayMilliseconds),
        settings.feedback == nil,
        document.nodes.contains(where: {
          $0.id == loop.outputNodeID
            && $0.kind == CoreAITextPipelineFamily.compositeNodeKind
        }),
        let seedID = PipelineControlFlow.incrementSeedNodeID(in: document, loop: loop),
        let seedNode = document.nodes.first(where: { $0.id == seedID }),
        (seedNode.parameters["mode"] == nil
          || seedNode.parameters["mode"] == .string("fixed")),
        case .integer(let savedSeed)? = seedNode.parameters["value"], savedSeed >= 0
      else { throw Failure.invalidLoop }
      let report = PipelineGraphValidator.validate(
        document, registry: registry,
        engineVersion: PixeltjePipelineEngine.currentEngineVersion)
      guard report.isValid else {
        throw Failure.graph(report.errors.map(\.message).joined(separator: "; "))
      }
      if checkOnly {
        guard traceURL == nil else { throw Failure.usage }
        let checkRunner = CoreAITextPipelineRunner()
        let checkEngine = PixeltjePipelineEngine(
          additionalNodeDescriptors: [CoreAITextPipelineFamily.makeCompositeNodeDescriptor()],
          additionalNodeExecutors: [CoreAITextPipelineFamily.makeNodeExecutor(
            runner: checkRunner)])
        let prepared = try await checkEngine.prepare(document)
        let inspection = CoreAITextPipelineFamily.inspectPackage(
          at: package, for: document)
        guard inspection.isUsable else { throw Failure.package(inspection.summary) }
        print("Graph and linked Qwen package are valid.")
        print("Semantic graph SHA-256: \(prepared.semanticSHA256)")
        print("Planned calls:")
        for call in 1...limit {
          let seed = settings.seedStrategy == .increment
            ? UInt64(savedSeed) &+ UInt64(call - 1) : UInt64(savedSeed)
          print("Call \(call)/\(limit) · seed \(seed)")
        }
        return
      }
      let runner = CoreAITextPipelineRunner()
      let engine = try PixeltjePipelineEngine.makeDefault(
        additionalNodeDescriptors: [CoreAITextPipelineFamily.makeCompositeNodeDescriptor()],
        additionalNodeExecutors: [CoreAITextPipelineFamily.makeNodeExecutor(runner: runner)])
      let inspection = await CoreAITextPipelineFamily.inspectPackageForExecution(
        at: package, for: document)
      guard inspection.isUsable, let packageID = inspection.packageID else {
        throw Failure.package(inspection.summary)
      }
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      let traceLog = try traceURL.map { try PipelineTraceLog(url: $0) }
      let trace = traceLog?.handler()
      let traceRunID = UUID()
      for call in 1...limit {
        try Task.checkCancellation()
        let seed = settings.seedStrategy == .increment
          ? UInt64(savedSeed) &+ UInt64(call - 1) : UInt64(savedSeed)
        let output = try await engine.execute(
          document,
          packageRootsByID: [packageID: package],
          invocation: PipelineInvocation(values: [
            PipelineInvocation.seedKey: .unsignedInteger(seed),
          ]), trace: trace, traceRunID: traceRunID, traceCall: call)
        guard case .text(let text) = output else { throw Failure.invalidOutput }
        let url = directory.appendingPathComponent(
          "call-\(call)-seed-\(seed)-\(UUID().uuidString.lowercased()).txt")
        try Data(text.text.utf8).write(to: url, options: .atomic)
        print("Call \(call)/\(limit) · seed \(seed) · \(url.path)")
        print(text.text)
        if call < limit {
          try await Task.sleep(for: .milliseconds(settings.delayMilliseconds))
        }
      }
      try await traceLog?.close()
    } catch {
      FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private enum Failure: LocalizedError {
    case usage
    case invalidLoop
    case invalidOutput
    case graph(String)
    case package(String)

    var errorDescription: String? {
      switch self {
      case .usage:
        "Usage: pixeltje-pipeline-run-text-loop [--check] WORKFLOW.pixpipeline.json [MODEL-DIRECTORY] [OUTPUT-DIRECTORY] [--debug-log FILE]"
      case .invalidLoop:
        "The text workflow needs Output → Loop → Start, Loop → Seed, Seed → Text Generate, a fixed saved seed, a finite 1–100 call limit, and no feedback."
      case .invalidOutput:
        "The workflow did not return generated text."
      case .graph(let reason): "Invalid workflow: \(reason)"
      case .package(let reason): reason
      }
    }
  }
}

import Foundation
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineStableAudioRuntime

@main
enum StableAudio3ExampleRunner {
  static func main() async {
    do {
      try await run()
    } catch {
      fputs("Stable Audio 3 example failed: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard (1...3).contains(args.count) else {
      throw RunError.usage
    }
    let workflowURL = URL(fileURLWithPath: args[0])
    let packageURL = args.count >= 2
      ? URL(fileURLWithPath: args[1], isDirectory: true)
      : StableAudio3Family.defaultPackageURL()
    let outputURL = args.count >= 3
      ? URL(fileURLWithPath: args[2])
      : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("gunshot.wav")
    let document = try PipelineJSON.decode(Data(contentsOf: workflowURL))
    if let error = StableAudio3Family.inspectPackage(at: packageURL, for: document) {
      throw RunError.package(error)
    }
    let engine = try PixeltjePipelineEngine.makeDefault(
      additionalNodeDescriptors: [StableAudio3Family.descriptor()],
      additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors()
        + [StableAudio3Family.executor(runner: StableAudio3Runner())])
    _ = try await engine.prepare(document)
    let result = try await engine.execute(
      document, packageRootsByID: [StableAudio3Family.packageID: packageURL],
      invocation: PipelineInvocation())
    guard case .audio(let audio) = result else { throw RunError.noAudio }
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    try FileManager.default.copyItem(at: audio.fileURL, to: outputURL)
    print(outputURL.path)
  }
}

private enum RunError: LocalizedError {
  case usage
  case package(String)
  case noAudio

  var errorDescription: String? {
    switch self {
    case .usage:
      "Usage: pixeltje-pipeline-run-stable-audio-3 <workflow.pixpipeline.json> [package-directory] [output.wav]"
    case .package(let detail): detail
    case .noAudio: "The example produced no audio."
    }
  }
}

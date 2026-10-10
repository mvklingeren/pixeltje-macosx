import Darwin
import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineSDXSRuntime
import PixeltjePipelineSegmentationRuntime
import PixeltjePipelineTextRuntime

private struct Options {
  let workflow: URL
  let package: URL
  let output: URL
  let requiredHFModel: String?
  let force: Bool
}

private enum LinkError: LocalizedError {
  case usage(String)
  case outputExists(String)
  case unexpectedModel(expected: String, actual: String)
  case invalidGraph(String)

  var errorDescription: String? {
    switch self {
    case .usage(let message): message
    case .outputExists(let path): "Output already exists: \(path). Pass --force to replace it."
    case .unexpectedModel(let expected, let actual):
      "Expected Hugging Face model \(expected), but the package declares \(actual)."
    case .invalidGraph(let message): "Linked workflow is invalid: \(message)"
    }
  }
}

@main
private enum PixeltjePipelineTextLinkCommand {
  private static let usage = """
    Usage: pixeltje-pipeline-link-text --workflow INPUT.pixpipeline.json \\
      --package MODEL-BUNDLE --output LINKED.pixpipeline.json \\
      [--require-hf-model MODEL-ID] [--force]
    """

  static func main() {
    do {
      let options = try parse(Array(CommandLine.arguments.dropFirst()))
      if FileManager.default.fileExists(atPath: options.output.path), !options.force {
        throw LinkError.outputExists(options.output.path)
      }
      if let expected = options.requiredHFModel {
        let manifest = options.package.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: manifest)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let source = object?["source"] as? [String: Any]
        let actual = source?["hf_model_id"] as? String ?? "<missing>"
        guard actual == expected else {
          throw LinkError.unexpectedModel(expected: expected, actual: actual)
        }
      }

      let source = try PipelineJSON.decode(Data(contentsOf: options.workflow))
      let linked = try CoreAITextPipelineFamily.linkPackage(in: source, at: options.package)
      var registry = PipelineNodeRegistry.coreAIV1
      registry.register(CoreAITextPipelineFamily.makeCompositeNodeDescriptor())
      registry.register(SDXSPipelineFamily.descriptor())
      registry.register(SAM31PipelineFamily.descriptor())
      let report = PipelineGraphValidator.validate(
        linked, registry: registry,
        engineVersion: PixeltjePipelineEngine.currentEngineVersion)
      guard report.isValid else {
        throw LinkError.invalidGraph(report.errors.map(\.message).joined(separator: "; "))
      }
      let inspection = CoreAITextPipelineFamily.inspectPackage(
        at: options.package, for: linked)
      guard inspection.isUsable else {
        throw LinkError.invalidGraph(inspection.summary)
      }

      try FileManager.default.createDirectory(
        at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PipelineJSON.encode(linked).write(to: options.output, options: .atomic)
      print("Linked \(linked.name) to \(inspection.packageID ?? "unknown package")")
      print(options.output.path)
    } catch {
      FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n\n\(usage)\n".utf8))
      exit(1)
    }
  }

  private static func parse(_ arguments: [String]) throws -> Options {
    if arguments.contains("--help") || arguments.contains("-h") {
      print(usage)
      exit(0)
    }
    var workflow: String?
    var package: String?
    var output: String?
    var requiredHFModel: String?
    var force = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--force" {
        force = true
      } else {
        index += 1
        guard arguments.indices.contains(index) else {
          throw LinkError.usage("Missing value for \(argument).")
        }
        switch argument {
        case "--workflow": workflow = arguments[index]
        case "--package": package = arguments[index]
        case "--output": output = arguments[index]
        case "--require-hf-model": requiredHFModel = arguments[index]
        default: throw LinkError.usage("Unknown option \(argument).")
        }
      }
      index += 1
    }
    guard let workflow, let package, let output else {
      throw LinkError.usage("A workflow, package and output path are required.")
    }
    return Options(
      workflow: URL(fileURLWithPath: workflow).standardizedFileURL,
      package: URL(fileURLWithPath: package).standardizedFileURL,
      output: URL(fileURLWithPath: output).standardizedFileURL,
      requiredHFModel: requiredHFModel,
      force: force)
  }
}

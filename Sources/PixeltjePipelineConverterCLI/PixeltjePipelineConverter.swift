import Darwin
import Foundation
import PixeltjePipelineComfyUIConverter
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineResourceLinking

private struct Options {
  var inputURL: URL
  var outputURL: URL
  var coreAIPackageURL: URL?
  var documentName: String?
  var mapNodes: Bool
  var projectedOutputSourceNodeID: String?
  var validate: Bool
  var failOnValidationError: Bool
  var force: Bool
}

@main
private enum PixeltjePipelineConverterCommand {
  static func main() {
    do {
      var arguments = CommandLine.arguments
      arguments.removeFirst()
      let options = try parse(arguments)
      let data = try Data(contentsOf: options.inputURL)
      var conversion = try ComfyUIWorkflowConverter.convert(
        data,
        sourceName: options.documentName ?? options.inputURL.lastPathComponent,
        options: ComfyUIConversionOptions(
          mapNodes: options.mapNodes,
          projectedOutputSourceNodeID: options.projectedOutputSourceNodeID))
      if let packageURL = options.coreAIPackageURL {
        let relinked = try PipelineCoreAIPackageRelinker.relinkCompatibleResources(
          in: conversion.document,
          toPackageAt: packageURL)
        conversion.document = relinked.document
        conversion.summary.unresolvedResourceCount = relinked.remainingUnresolvedResourceCount
        conversion.diagnostics.append(
          contentsOf: relinked.notices.map { notice in
            ComfyUIConversionDiagnostic(severity: .information, message: notice.message)
          })
      }

      if FileManager.default.fileExists(atPath: options.outputURL.path), !options.force {
        throw CommandError.outputExists(options.outputURL.path)
      }
      try PipelineJSON.encode(conversion.document).write(to: options.outputURL, options: .atomic)
      printSummary(conversion, outputURL: options.outputURL)

      guard options.validate else { return }
      let report = PipelineGraphValidator.validate(
        conversion.document,
        registry: .coreAIV1,
        engineVersion: PixeltjePipelineEngine.currentEngineVersion)
      printValidation(report)
      if options.failOnValidationError, !report.isValid { exit(2) }
    } catch {
      writeError("Error: \(error.localizedDescription)\n\n\(usage)")
      exit(1)
    }
  }

  private static func parse(_ arguments: [String]) throws -> Options {
    if arguments.contains("--help") || arguments.contains("-h") {
      print(usage)
      exit(0)
    }
    var mapNodes = false
    var validate = false
    var failOnValidationError = false
    var force = false
    var coreAIPackagePath: String?
    var documentName: String?
    var projectedOutputSourceNodeID: String?
    var outputPath: String?
    var inputPath: String?
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--map-nodes": mapNodes = true
      case "--validate": validate = true
      case "--fail-on-validation-error":
        validate = true
        failOnValidationError = true
      case "--force": force = true
      case "--coreai-package":
        index += 1
        guard arguments.indices.contains(index) else {
          throw CommandError.missingCoreAIPackagePath
        }
        coreAIPackagePath = arguments[index]
      case "--document-name":
        index += 1
        guard arguments.indices.contains(index) else {
          throw CommandError.missingDocumentName
        }
        documentName = arguments[index]
      case "--project-output":
        index += 1
        guard arguments.indices.contains(index) else {
          throw CommandError.missingProjectedOutputNodeID
        }
        projectedOutputSourceNodeID = arguments[index]
      case "--output", "-o":
        index += 1
        guard arguments.indices.contains(index) else { throw CommandError.missingOutputPath }
        outputPath = arguments[index]
      default:
        guard !argument.hasPrefix("-") else { throw CommandError.unknownOption(argument) }
        guard inputPath == nil else { throw CommandError.multipleInputs }
        inputPath = argument
      }
      index += 1
    }
    guard let inputPath else { throw CommandError.missingInput }
    let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
    let outputURL: URL
    if let outputPath {
      outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    } else {
      outputURL = inputURL.deletingPathExtension().appendingPathExtension("pixpipeline.json")
    }
    return Options(
      inputURL: inputURL,
      outputURL: outputURL,
      coreAIPackageURL: coreAIPackagePath.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
      },
      documentName: documentName,
      mapNodes: mapNodes,
      projectedOutputSourceNodeID: projectedOutputSourceNodeID,
      validate: validate,
      failOnValidationError: failOnValidationError,
      force: force)
  }

  private static func printSummary(_ result: ComfyUIConversionResult, outputURL: URL) {
    print("Converted \(result.summary.sourceNodeCount) ComfyUI nodes")
    print("Connections: \(result.summary.connectionCount)")
    print("Mapped to native nodes: \(result.summary.mappedNodeCount)")
    print("Preserved as placeholders: \(result.summary.placeholderNodeCount)")
    print("Unresolved resources: \(result.summary.unresolvedResourceCount)")
    for diagnostic in result.diagnostics {
      print("Conversion \(diagnostic.severity.rawValue): \(diagnostic.message)")
    }
    print("Output: \(outputURL.path)")
  }

  private static func printValidation(_ report: PipelineValidationReport) {
    if report.diagnostics.isEmpty {
      print("Validation: ready")
      return
    }
    print("Validation: \(report.errors.count) errors, \(report.warnings.count) warnings")
    for diagnostic in report.diagnostics {
      let node = diagnostic.nodeID.map { " [\($0.rawValue)]" } ?? ""
      print(
        "\(diagnostic.severity.rawValue): \(diagnostic.code.rawValue)\(node): \(diagnostic.message)"
      )
    }
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
  }
}

private enum CommandError: Error, LocalizedError {
  case missingInput
  case multipleInputs
  case missingOutputPath
  case missingCoreAIPackagePath
  case missingDocumentName
  case missingProjectedOutputNodeID
  case outputExists(String)
  case unknownOption(String)

  var errorDescription: String? {
    switch self {
    case .missingInput: "An input ComfyUI JSON file is required."
    case .multipleInputs: "Convert one ComfyUI workflow at a time."
    case .missingOutputPath: "--output requires a destination path."
    case .missingCoreAIPackagePath: "--coreai-package requires a package directory."
    case .missingDocumentName: "--document-name requires a name."
    case .missingProjectedOutputNodeID: "--project-output requires a source node ID."
    case .outputExists(let path): "Output already exists at \(path). Use --force to replace it."
    case .unknownOption(let option): "Unknown option \(option)."
    }
  }
}

private let usage = """
  Usage: pixeltje-pipeline-convert [options] INPUT.json

  Options:
    -o, --output PATH             Output *.pixpipeline.json path
        --document-name NAME      Override the portable pipeline display name
        --map-nodes              Conservatively map recognized nodes
        --project-output NODE_ID  Keep and enable only this top-level output branch
        --coreai-package PATH     Explicitly link compatible resources from a Core AI package
        --validate               Validate after writing; never blocks conversion
        --fail-on-validation-error
                                 Exit 2 when explicit validation finds errors
        --force                  Replace an existing output file
    -h, --help                   Show this help
  """

import Foundation
import PixeltjePipelineDomain

/// A path literal and a bounded UTF-8 reader for its optional contents output.
enum PipelineFilePath {
  static let maximumContentBytes = 1_048_576

  static func value(from node: PipelineNode) throws -> String {
    let path = node.parameters["path"]?.stringValue ?? ""
    let mode = node.parameters["mode"]?.stringValue ?? "relative"
    guard !path.isEmpty, !path.contains("\0") else {
      throw PipelineEngineError.invalidInvocation("File Path needs a nonempty path.")
    }
    let absolute = (path as NSString).isAbsolutePath
    switch mode {
    case "relative" where !absolute:
      return path
    case "absolute" where absolute:
      return path
    case "relative":
      throw PipelineEngineError.invalidInvocation(
        "File Path must not be absolute in relative mode.")
    case "absolute":
      throw PipelineEngineError.invalidInvocation(
        "File Path must start at the filesystem root in absolute mode.")
    default:
      throw PipelineEngineError.invalidInvocation(
        "File Path mode must be relative or absolute.")
    }
  }

  static func diagnostics(for node: PipelineNode) -> [PipelineDiagnostic] {
    do {
      _ = try value(from: node)
      return []
    } catch {
      return [.init(severity: .error, code: .invalidParameter,
        message: error.localizedDescription, nodeID: node.id)]
    }
  }

  static func contents(from node: PipelineNode, sourceRoot: URL?) throws -> String {
    let path = try value(from: node)
    let mode = node.parameters["mode"]?.stringValue ?? "relative"
    let url: URL
    if mode == "relative" {
      guard let sourceRoot else {
        throw PipelineEngineError.invalidInvocation(
          "File Path contents need the pipeline source folder for a relative path.")
      }
      let root = sourceRoot.resolvingSymlinksInPath().standardizedFileURL
      url = root.appendingPathComponent(path).resolvingSymlinksInPath()
        .standardizedFileURL
      let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
      guard url.path.hasPrefix(prefix) else {
        throw PipelineEngineError.invalidInvocation(
          "File Path contents must stay inside the pipeline source folder.")
      }
    } else {
      url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        .standardizedFileURL
    }
    let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard attributes.isRegularFile == true else {
      throw PipelineEngineError.invalidInvocation(
        "File Path contents require a regular file.")
    }
    if let fileSize = attributes.fileSize, fileSize > maximumContentBytes {
      throw PipelineEngineError.invalidInvocation(
        "File Path contents must be at most 1 MiB.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumContentBytes + 1) ?? Data()
    guard data.count <= maximumContentBytes else {
      throw PipelineEngineError.invalidInvocation(
        "File Path contents must be at most 1 MiB.")
    }
    guard let contents = String(data: data, encoding: .utf8) else {
      throw PipelineEngineError.invalidInvocation(
        "File Path contents must be UTF-8 text.")
    }
    return contents
  }
}

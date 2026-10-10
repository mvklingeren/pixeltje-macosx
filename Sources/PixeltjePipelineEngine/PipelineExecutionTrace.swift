import CoreGraphics
import Foundation
import ImageIO
import PixeltjePipelineDomain

/// Debug-only, bounded presentation of a runtime value. PNG previews are
/// embedded in the JSONL log so a trace remains a single portable file.
public struct PipelineTraceValue: Codable, Sendable {
  public var type: String
  public var summary: String
  public var text: String?
  public var previewPNG: Data?

  public init(type: String, summary: String, text: String? = nil, previewPNG: Data? = nil) {
    self.type = type
    self.summary = summary
    self.text = text
    self.previewPNG = previewPNG
  }

  public static func text(_ text: String, type: String = "string") -> Self {
    let limit = 65_536
    let clipped = String(text.prefix(limit))
    return .init(type: type, summary: text.count > limit ? "Text (truncated)" : "Text",
      text: clipped)
  }

  /// Samples the source without retaining a second full-size raster.
  public static func image(
    width: Int, height: Int, type: String = "image",
    pixel: (Int, Int) -> (Float, Float, Float, Float)
  ) -> Self {
    guard width > 0, height > 0 else {
      return .init(type: type, summary: "Invalid image dimensions")
    }
    let scale = min(1.0, 256.0 / Double(max(width, height)))
    let previewWidth = max(1, Int((Double(width) * scale).rounded()))
    let previewHeight = max(1, Int((Double(height) * scale).rounded()))
    var bytes = [UInt8](repeating: 0, count: previewWidth * previewHeight * 4)
    for y in 0..<previewHeight {
      for x in 0..<previewWidth {
        let sourceX = min(width - 1, x * width / previewWidth)
        let sourceY = min(height - 1, y * height / previewHeight)
        let rgba = pixel(sourceX, sourceY)
        let offset = (y * previewWidth + x) * 4
        for (index, component) in [rgba.0, rgba.1, rgba.2, rgba.3].enumerated() {
          let clamped = component.isFinite ? min(max(component, 0), 1) : 0
          bytes[offset + index] = UInt8((clamped * 255).rounded())
        }
      }
    }
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(width: previewWidth, height: previewHeight,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: previewWidth * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let destinationData = CFDataCreateMutable(nil, 0),
      let destination = CGImageDestinationCreateWithData(
        destinationData, "public.png" as CFString, 1, nil)
    else { return .init(type: type, summary: "\(width) × \(height) · preview unavailable") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      return .init(type: type, summary: "\(width) × \(height) · preview unavailable")
    }
    return .init(type: type, summary: "\(width) × \(height)",
      previewPNG: destinationData as Data)
  }
}

/// Runtime implementations with private payload types can opt into inspection.
public protocol PipelineTraceRepresentable: Sendable {
  func pipelineTraceValue() -> PipelineTraceValue
}

public struct PipelineTraceRecord: Codable, Sendable, Identifiable {
  public var formatVersion = 1
  public var id = UUID()
  public var timestamp = Date()
  public var runID: UUID
  public var call: Int
  public var workflow: String
  public var graphSHA256: String
  public var nodeID: String
  public var nodeKind: String
  public var nodeTitle: String
  public var phase: String
  public var durationSeconds: Double?
  public var inputs: [String: PipelineTraceValue]?
  public var parameters: [String: PipelineTraceValue]?
  public var outputs: [String: PipelineTraceValue]?
  public var error: String?

  public init(
    runID: UUID, call: Int, workflow: String, graphSHA256: String,
    node: PipelineNode, phase: String, durationSeconds: Double? = nil,
    inputs: [String: PipelineTraceValue]? = nil,
    parameters: [String: PipelineTraceValue]? = nil,
    outputs: [String: PipelineTraceValue]? = nil, error: String? = nil
  ) {
    self.runID = runID
    self.call = call
    self.workflow = workflow
    self.graphSHA256 = graphSHA256
    nodeID = node.id.rawValue
    nodeKind = node.kind.rawValue
    nodeTitle = node.title ?? node.kind.rawValue
    self.phase = phase
    self.durationSeconds = durationSeconds
    self.inputs = inputs
    self.parameters = parameters
    self.outputs = outputs
    self.error = error
  }
}

public typealias PipelineTraceHandler = @Sendable (PipelineTraceRecord) async -> Void

/// A single JSONL file, created only when a host explicitly enables tracing.
public actor PipelineTraceLog {
  public let url: URL
  private let handle: FileHandle
  private var byteCount = 0
  private var writeFailure: (any Error)?
  private let maximumBytes: Int
  private let encoder = JSONEncoder()

  public init(url: URL, maximumBytes: Int = 128 * 1024 * 1024) throws {
    self.url = url
    self.maximumBytes = maximumBytes
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    guard FileManager.default.createFile(atPath: url.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    handle = try FileHandle(forWritingTo: url)
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
  }

  private func append(_ record: PipelineTraceRecord) throws -> PipelineTraceRecord {
    var record = record
    var data = try encoder.encode(record)
    if byteCount + data.count + 1 > maximumBytes {
      record.inputs = record.inputs?.mapValues { value in
        var value = value
        value.previewPNG = nil
        value.text = nil
        value.summary += " (content omitted: trace limit)"
        return value
      }
      record.outputs = record.outputs?.mapValues { value in
        var value = value
        value.previewPNG = nil
        value.text = nil
        value.summary += " (content omitted: trace limit)"
        return value
      }
      record.parameters = record.parameters?.mapValues { value in
        var value = value
        value.text = nil
        value.summary += " (content omitted: trace limit)"
        return value
      }
      data = try encoder.encode(record)
    }
    data.append(0x0A)
    try handle.write(contentsOf: data)
    byteCount += data.count
    return record
  }

  @discardableResult
  public func record(_ record: PipelineTraceRecord) -> PipelineTraceRecord? {
    guard writeFailure == nil else { return nil }
    do { return try append(record) }
    catch { writeFailure = error; return nil }
  }

  public func failureMessage() -> String? { writeFailure?.localizedDescription }

  public nonisolated func handler() -> PipelineTraceHandler {
    { record in _ = await self.record(record) }
  }

  public func close() throws {
    try handle.close()
    if let writeFailure { throw writeFailure }
  }

  deinit { try? handle.close() }

  public static func read(_ url: URL) throws -> [PipelineTraceRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try Data(contentsOf: url)
    var lines = data.split(separator: 0x0A)
    // A process may stop during its final write. Earlier complete lines remain usable.
    if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
    return try lines.map {
      try decoder.decode(PipelineTraceRecord.self, from: Data($0))
    }
  }

  /// Retains only recent logs owned by the Pipeline Editor's temporary folder.
  public static func pruneEditorLogs(in directory: URL, retaining count: Int = 3) {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let logs = files.filter {
      $0.lastPathComponent.hasPrefix("run-") && $0.pathExtension == "jsonl"
    }.sorted {
      let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      return lhs > rhs
    }
    for old in logs.dropFirst(max(count, 0)) {
      try? FileManager.default.removeItem(at: old)
    }
  }
}

public enum PipelineTraceCLIOptions {
  /// Removes --debug-log PATH from an existing runner's argument list.
  public static func takeDebugLog(from arguments: inout [String]) throws -> URL? {
    guard let index = arguments.firstIndex(of: "--debug-log") else { return nil }
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
      arguments.filter({ $0 == "--debug-log" }).count == 1 else {
      throw PipelineEngineError.invalidInvocation("--debug-log requires one file path.")
    }
    let path = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return URL(fileURLWithPath: path).standardizedFileURL
  }
}

extension PipelineNodeValue {
  public func traceValue() -> PipelineTraceValue {
    if let value = payload as? any PipelineTraceRepresentable {
      return value.pipelineTraceValue()
    }
    if let value = payload as? String { return .text(value, type: type.rawValue) }
    if let value = payload as? Bool {
      return .init(type: type.rawValue, summary: String(value))
    }
    if let value = payload as? Int { return .init(type: type.rawValue, summary: String(value)) }
    if let value = payload as? Int64 { return .init(type: type.rawValue, summary: String(value)) }
    if let value = payload as? UInt64 { return .init(type: type.rawValue, summary: String(value)) }
    if let value = payload as? Double { return .init(type: type.rawValue, summary: String(value)) }
    if let value = payload as? [Double] {
      return .text(value.map { String($0) }.joined(separator: ", "), type: type.rawValue)
    }
    if let value = payload as? [String] {
      return .text(value.joined(separator: " | "), type: type.rawValue)
    }
    if let value = payload as? [PipelineLabeledMask] {
      let summary = value.map { "\($0.label) (\($0.score))" }.joined(separator: ", ")
      return .text(summary, type: type.rawValue)
    }
    if let value = payload as? PipelineImageInput {
      return .image(width: value.width, height: value.height) { x, y in
        let offset = (y * value.width + x) * 4
        return (value.rgba[offset], value.rgba[offset + 1],
          value.rgba[offset + 2], value.rgba[offset + 3])
      }
    }
    if let value = payload as? PipelineGeneratedImage {
      let (count, overflow) = value.width.multipliedReportingOverflow(by: value.height)
      guard value.width > 0, value.height > 0, !overflow,
        count <= Int.max / 3, value.planarRGB.count == count * 3,
        value.alpha.map({ $0.count == count }) ?? true else {
        return .init(type: type.rawValue, summary: "Invalid generated image buffer")
      }
      return .image(width: value.width, height: value.height) { x, y in
        let index = y * value.width + x
        return (value.encoding.normalizedSRGBComponent(from: value.planarRGB[index]),
          value.encoding.normalizedSRGBComponent(from: value.planarRGB[count + index]),
          value.encoding.normalizedSRGBComponent(from: value.planarRGB[2 * count + index]),
          value.alpha?[index] ?? 1)
      }
    }
    if let value = payload as? PipelineMaskInput {
      return .image(width: value.width, height: value.height, type: type.rawValue) { x, y in
        let coverage = value.coverage[y * value.width + x]
        return (coverage, coverage, coverage, 1)
      }
    }
    if let value = payload as? PipelineLatent {
      return .init(type: type.rawValue,
        summary: "Shape \(value.shape.map { $0.map(String.init) ?? "?" }.joined(separator: " × "))")
    }
    return .init(type: type.rawValue, summary: "Opaque runtime value")
  }
}

extension PipelineValue {
  public func traceValue() -> PipelineTraceValue {
    switch self {
    case .null: .init(type: "null", summary: "null")
    case .boolean(let value): .init(type: "boolean", summary: String(value))
    case .integer(let value): .init(type: "integer", summary: String(value))
    case .number(let value): .init(type: "number", summary: String(value))
    case .string(let value): .text(value)
    case .array(let value): .text(String(describing: value), type: "array")
    case .object(let value): .text(String(describing: value), type: "object")
    }
  }
}

extension PipelineExecutionOutput {
  public func traceValue() -> PipelineTraceValue {
    switch self {
    case .none: return .init(type: "none", summary: "No output")
    case .plainText(let result): return .text(result.text)
    case .text(let result): return .text(result.text)
    case .image(let result):
      let (count, overflow) = result.width.multipliedReportingOverflow(by: result.height)
      guard result.width > 0, result.height > 0, !overflow,
        count <= Int.max / 3, result.planarRGB.count == count * 3,
        result.alpha.map({ $0.count == count }) ?? true else {
        return .init(type: "image", summary: "Invalid generated image buffer")
      }
      var traced = PipelineTraceValue.image(width: result.width, height: result.height) { x, y in
        let index = y * result.width + x
        return (result.encoding.normalizedSRGBComponent(from: result.planarRGB[index]),
          result.encoding.normalizedSRGBComponent(from: result.planarRGB[count + index]),
          result.encoding.normalizedSRGBComponent(from: result.planarRGB[2 * count + index]),
          result.alpha?[index] ?? 1)
      }
      traced.summary += result.feedbackText == nil ? " · no feedback text" : " · feedback text"
      return traced
    case .video(let result):
      return .init(type: "video", summary: "\(result.width) × \(result.height), \(result.frameCount) frames")
    case .videoFrame(let result):
      return .init(type: "videoFrame", summary:
        "\(result.image.width) × \(result.image.height) at \(result.framesPerSecond) fps")
    case .audio(let result):
      return .init(type: "audio", summary: result.fileURL.lastPathComponent)
    case .model(let result):
      return .init(type: "model", summary: result.assetURL.lastPathComponent)
    }
  }
}

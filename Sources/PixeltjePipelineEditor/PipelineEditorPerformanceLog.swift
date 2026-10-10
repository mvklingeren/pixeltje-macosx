import Foundation
import OSLog
import PixeltjePipelineEngine
import Synchronization

/// Opt-in timing diagnostics without inspecting graph values or image pixels.
actor PipelineEditorPerformanceLog {
  struct Frame: Encodable, Sendable {
    let formatVersion = 9
    let event = "call"
    let timestamp = Date()
    let runID: UUID
    let call: Int
    let configuration: String
    let executable: String?
    let inputPreparationSeconds: Double
    let engineSeconds: Double
    let outputSavingSeconds: Double
    let progressFlushSeconds: Double
    let outputWriterSeconds: Double
    let gpuCommitSeconds: Double
    let publicationSeconds: Double
    let callSeconds: Double
    /// Start-to-start wall time; includes the previous call, loop delay and scheduling.
    let frameIntervalSeconds: Double?
    let configuredDelayMilliseconds: Int
    let configuredLimitHz: Int?
    let directMetalPreview: Bool
    let saveGeneratedImagesToDisk: Bool
    /// Whether a visible preview view's refresh paced this call.
    let previewClockAvailable: Bool
    let gpuProgram: PipelineGPUProgramPerformance?
    /// These fields belong to the preceding call and explain its start-to-start gap.
    let previousLogEnqueueSeconds: Double?
    let previousRequestedWaitSeconds: Double?
    let previousActualWaitSeconds: Double?
    let previousReadyToStartSeconds: Double?
    let debugCaptureEnabled: Bool
    let highlightingEnabled: Bool
    let nodeSpeedLabelsEnabled: Bool
    let callbacks: PipelineEditorCallbackTimings.Snapshot
  }

  struct Display: Encodable, Sendable {
    let formatVersion = 9
    let event: String
    let runID: UUID
    let viewID: UUID
    let surfaceID: UInt32
    let uptimeSeconds: Double
    /// Seconds since the runner published the frame.
    let latencySeconds: Double
  }

  static var configuration: String {
    #if DEBUG
      "debug"
    #else
      "release"
    #endif
  }

  private static let logger = Logger(
    subsystem: "org.pixeltje.PixeltjeMacApp", category: "pipeline-performance")
  private let handle: FileHandle
  private let encoder = JSONEncoder()
  private var byteCount = 0
  private var stopped = false

  /// The workflow remains the first positional argument; this option may follow it.
  static func requested() throws -> PipelineEditorPerformanceLog? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let index = arguments.firstIndex(of: "--performance-log") else { return nil }
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
      arguments.filter({ $0 == "--performance-log" }).count == 1 else {
      throw NSError(domain: "PixeltjePipeline", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "--performance-log requires one new JSONL file path."
      ])
    }
    return try PipelineEditorPerformanceLog(url: URL(fileURLWithPath: arguments[index + 1]))
  }

  init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

  func record(_ frame: Frame) {
    recordEncoded(frame)
  }

  func recordDisplay(_ display: Display) {
    recordEncoded(display)
  }

  private func recordEncoded(_ entry: some Encodable) {
    guard !stopped else { return }
    do {
      var data = try encoder.encode(entry)
      data.append(0x0A)
      // Constant-memory capture, with a bounded file for an infinite loop.
      guard byteCount + data.count <= 32 * 1024 * 1024 else {
        stopped = true
        return
      }
      try handle.write(contentsOf: data)
      byteCount += data.count
    } catch {
      stopped = true
      Self.logger.error("Performance logging stopped: \(error.localizedDescription, privacy: .public)")
    }
  }

  deinit { try? handle.close() }
}

/// Measures awaited engine callbacks and separate batched main-actor publication.
final class PipelineEditorCallbackTimings: Sendable {
  struct Snapshot: Encodable, Sendable {
    var progressCount = 0
    var progressSeconds = 0.0
    /// Synchronous batched UI publication, outside the awaited progress callback.
    var progressPublicationSeconds = 0.0
    var traceCount = 0
    var traceSeconds = 0.0
  }

  private let values = Mutex(Snapshot())

  func recordProgress(since start: UInt64) {
    let elapsed = Self.seconds(since: start)
    values.withLock {
      $0.progressCount += 1
      $0.progressSeconds += elapsed
    }
  }

  func recordTrace(since start: UInt64) {
    let elapsed = Self.seconds(since: start)
    values.withLock {
      $0.traceCount += 1
      $0.traceSeconds += elapsed
    }
  }

  func recordProgressPublication(since start: UInt64) {
    let elapsed = Self.seconds(since: start)
    values.withLock { $0.progressPublicationSeconds += elapsed }
  }

  func snapshot() -> Snapshot { values.withLock { $0 } }

  static func seconds(since start: UInt64, until end: UInt64 = DispatchTime.now().uptimeNanoseconds)
    -> Double {
    Double(end - start) / 1_000_000_000
  }
}

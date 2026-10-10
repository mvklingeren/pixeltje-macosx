import Foundation
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
import PixeltjePipelineEngine

/// Records Image-fed Video Preview nodes without retaining earlier frames.
actor PipelineVideoPreviewRecorder {
  private let runID: UUID
  private var writers: [PipelineNodeID: PipelineStreamingVideoWriter] = [:]
  private var failure: Error?

  init(runID: UUID) { self.runID = runID }

  func record(_ progress: PipelineExecutionProgress) async {
    guard failure == nil else { return }
    do { try await append(progress) }
    catch { failure = error }
  }

  func check() throws {
    if let failure { throw failure }
  }

  private func append(_ progress: PipelineExecutionProgress) async throws {
    guard let nodeID = progress.previewNodeID,
      let image = progress.preview,
      let framesPerSecond = progress.previewFramesPerSecond else { return }
    let writer: PipelineStreamingVideoWriter
    if let existing = writers[nodeID] {
      writer = existing
    } else {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "pixeltje-video-preview-\(runID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).mp4")
      writer = try PipelineStreamingVideoWriter(
        outputURL: url, framesPerSecond: framesPerSecond)
      writers[nodeID] = writer
    }
    try await writer.append(.init(image: image, framesPerSecond: framesPerSecond))
  }

  func finish() async throws -> [PipelineNodeID: URL] {
    try check()
    var result: [PipelineNodeID: URL] = [:]
    for (nodeID, writer) in writers {
      result[nodeID] = try await writer.finish().fileURL
    }
    writers = [:]
    return result
  }

  func cancel() async {
    for writer in writers.values { await writer.cancel() }
    writers = [:]
  }
}

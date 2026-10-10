import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import Synchronization

/// Collects progress without requiring the engine to enter the main actor.
/// Keeps the latest values and all node transitions between UI refreshes.
final class PipelineEditorProgressBuffer: Sendable {
  struct Batch: Sendable {
    let progress: PipelineExecutionProgress
    let nodePreviews: [PipelineNodeID: PipelineGeneratedImage]
    let assetPreviews: [PipelineNodeID: [String: PipelineAssetPreview]]
    let videoPreviews: [PipelineNodeID: (url: URL, isTemporary: Bool)]
    let preview: PipelineGeneratedImage?
    let generatedText: String?
    let nodeTextValues: [PipelineNodeID: String]
    let activatedNodeIDs: Set<PipelineNodeID>
    let nodeExecutionSeconds: [PipelineNodeID: Double]
  }

  private struct State {
    var progress: PipelineExecutionProgress?
    var nodePreviews: [PipelineNodeID: PipelineGeneratedImage] = [:]
    var assetPreviews: [PipelineNodeID: [String: PipelineAssetPreview]] = [:]
    var videoPreviews: [PipelineNodeID: (url: URL, isTemporary: Bool)] = [:]
    var preview: PipelineGeneratedImage?
    var generatedText: String?
    var nodeTextValues: [PipelineNodeID: String] = [:]
    var activeNodeIDs: Set<PipelineNodeID> = []
    var startedAt: [PipelineNodeID: UInt64] = [:]
    var activatedNodeIDs: Set<PipelineNodeID> = []
    var nodeExecutionSeconds: [PipelineNodeID: Double] = [:]
  }

  private let state = Mutex(State())

  func submit(_ progress: PipelineExecutionProgress) {
    let now = DispatchTime.now().uptimeNanoseconds
    state.withLock { state in
      for nodeID in state.activeNodeIDs.subtracting(progress.activeNodeIDs) {
        if let started = state.startedAt.removeValue(forKey: nodeID) {
          state.nodeExecutionSeconds[nodeID] = Double(now - started) / 1_000_000_000
        }
      }
      for nodeID in progress.activeNodeIDs.subtracting(state.activeNodeIDs) {
        state.startedAt[nodeID] = now
      }
      state.activeNodeIDs = progress.activeNodeIDs
      state.activatedNodeIDs.formUnion(progress.activeNodeIDs)
      state.progress = progress
      if let preview = progress.preview {
        state.preview = preview
        if let nodeID = progress.previewNodeID { state.nodePreviews[nodeID] = preview }
      }
      if let asset = progress.assetPreview {
        state.assetPreviews[asset.nodeID, default: [:]][asset.slot] = asset
      }
      if let url = progress.previewVideoURL,
        let nodeID = progress.previewVideoNodeID {
        state.videoPreviews[nodeID] = (url, progress.previewVideoIsTemporary)
      }
      if let text = progress.generatedText { state.generatedText = text }
      if let nodeID = progress.textValueNodeID,
        let text = progress.textValue { state.nodeTextValues[nodeID] = text }
    }
  }

  func drain() -> Batch? {
    state.withLock { state in
      guard let progress = state.progress else { return nil }
      let batch = Batch(
        progress: progress, nodePreviews: state.nodePreviews,
        assetPreviews: state.assetPreviews,
        videoPreviews: state.videoPreviews,
        preview: state.preview, generatedText: state.generatedText,
        nodeTextValues: state.nodeTextValues,
        activatedNodeIDs: state.activatedNodeIDs,
        nodeExecutionSeconds: state.nodeExecutionSeconds)
      state.progress = nil
      state.nodePreviews = [:]
      state.assetPreviews = [:]
      state.videoPreviews = [:]
      state.preview = nil
      state.generatedText = nil
      state.nodeTextValues = [:]
      state.activatedNodeIDs = []
      state.nodeExecutionSeconds = [:]
      return batch
    }
  }
}

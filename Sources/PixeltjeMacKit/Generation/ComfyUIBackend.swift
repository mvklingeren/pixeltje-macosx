import Foundation
import PixeltjeMacDomain

enum ComfyUIUploadedInput: Sendable {
  case local(ComfyUIUploadedImage)
  case cloud(ComfyCloudUploadedAsset)

  var runtimeValue: ComfyUIRuntimeValue {
    switch self {
    case .local(let image): .path(image.workflowValue)
    case .cloud(let asset): asset.runtimeValue
    }
  }
}

/// One document-facing execution interface. The editor's preparation and
/// import path does not need to know which remote protocol ran the graph.
enum ComfyUIBackend: Sendable {
  case local(ComfyUIClient)
  case cloud(ComfyCloudClient)

  var target: ComfyUIExecutionTarget {
    switch self {
    case .local: .local
    case .cloud: .cloud
    }
  }

  func checkConnection(onDebug: ComfyUIDebugSink? = nil) async -> Bool {
    switch self {
    case .local(let client): await client.checkConnection(onDebug: onDebug)
    case .cloud(let client): await client.checkConnection(onDebug: onDebug)
    }
  }

  func workflowForm(
    templateID: String, onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIWorkflowForm {
    switch self {
    case .local(let client):
      try await client.workflowForm(templateID: templateID, onDebug: onDebug)
    case .cloud(let client):
      try await client.workflowForm(templateID: templateID, onDebug: onDebug)
    }
  }

  func workflowForm(
    resolved: ComfyUIResolvedWorkflow, onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIWorkflowForm {
    switch self {
    case .local(let client):
      try await client.workflowForm(resolved: resolved, onDebug: onDebug)
    case .cloud(let client):
      try await client.workflowForm(resolved: resolved, onDebug: onDebug)
    }
  }

  func missingModels(
    in workflow: ComfyUIWorkflowRequest, onDebug: ComfyUIDebugSink? = nil
  ) async throws -> [ComfyUIRequiredModel] {
    switch self {
    case .local(let client):
      try await client.missingModels(in: workflow, onDebug: onDebug)
    case .cloud(let client):
      try await client.missingModels(in: workflow, onDebug: onDebug)
    }
  }

  func uploadPNG(
    _ png: Data, filename: String, subfolder: String,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIUploadedInput {
    switch self {
    case .local(let client):
      .local(try await client.uploadPNG(
        png, filename: filename, subfolder: subfolder, onDebug: onDebug))
    case .cloud(let client):
      .cloud(try await client.uploadPNG(
        png, filename: filename, subfolder: subfolder, onDebug: onDebug))
    }
  }

  func run(
    _ workflow: ComfyUIWorkflowRequest,
    onAccepted: @Sendable (String) async -> Void,
    onState: @Sendable (GenerationJobState, Double) async -> Void,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIRunResult {
    // Cancelling this task stops observation and import. The document owns the
    // one corresponding remote cancel request once `onAccepted` supplies an ID.
    switch self {
    case .local(let client):
      try await client.run(
        workflow, onAccepted: onAccepted, onState: onState, onDebug: onDebug)
    case .cloud(let client):
      try await client.run(
        workflow, onAccepted: onAccepted, onState: onState, onDebug: onDebug)
    }
  }

  func status(
    jobID: String, onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIRemoteJobStatus {
    switch self {
    case .local(let client): try await client.status(promptID: jobID, onDebug: onDebug)
    case .cloud(let client): try await client.status(jobID: jobID, onDebug: onDebug)
    }
  }

  func cancel(jobID: String, onDebug: ComfyUIDebugSink? = nil) async {
    switch self {
    case .local(let client): await client.cancel(promptID: jobID, onDebug: onDebug)
    case .cloud(let client): await client.cancel(jobID: jobID, onDebug: onDebug)
    }
  }
}

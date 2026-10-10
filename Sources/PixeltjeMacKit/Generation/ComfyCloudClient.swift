import Foundation

struct ComfyCloudUploadedAsset: Sendable {
  let id: String
  let hash: String?
  let filePath: String

  var runtimeValue: ComfyUIRuntimeValue {
    .cloudAsset(id: id, hash: hash, filePath: filePath)
  }
}

/// Comfy Cloud execution uses the versioned v2 jobs and assets API. The older
/// Cloud API remains necessary for node definitions and model browsing, which
/// v2 deliberately does not provide yet.
actor ComfyCloudClient {
  static let baseURL = URL(string: "https://cloud.comfy.org")!

  private let apiKey: String
  private let session: URLSession

  init(apiKey: String, session: URLSession = .shared) {
    self.apiKey = apiKey
    self.session = session
  }

  func checkConnection(onDebug: ComfyUIDebugSink? = nil) async -> Bool {
    do {
      _ = try await request("api/user", onDebug: onDebug)
      return true
    } catch {
      await emit(onDebug, stage: "Cloud connection", message: error.userFacingMessage)
      return false
    }
  }

  func workflowForm(
    templateID: String,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIWorkflowForm {
    try await workflowForm(
      resolved: ComfyUIWorkflowCatalog.resolve(templateID: templateID), onDebug: onDebug)
  }

  func workflowForm(
    resolved: ComfyUIResolvedWorkflow,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIWorkflowForm {
    let classes = try ComfyUIWorkflowCatalog.nodeClassTypes(in: resolved)
    let data = try await request("api/object_info", onDebug: onDebug)
    guard let catalogue = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PixeltjeMacError(
        "Cloud node settings unavailable", "Comfy Cloud returned an invalid node catalogue.")
    }
    var definitions: [String: Data] = [:]
    for classType in classes {
      guard let definition = catalogue[classType] else {
        throw PixeltjeMacError(
          "Cloud workflow unavailable",
          "Comfy Cloud does not offer the \(classType) node required by this workflow.")
      }
      definitions[classType] = try JSONSerialization.data(
        withJSONObject: [classType: definition])
    }
    return try ComfyUIWorkflowCatalog.workflowForm(
      resolved: resolved, objectInfoByClass: definitions)
  }

  func missingModels(
    in workflow: ComfyUIWorkflowRequest,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> [ComfyUIRequiredModel] {
    let requirements = try ComfyUIResourceCatalog.requiredModels(in: workflow.workflow)
    var available: [String: Set<String>] = [:]
    for folder in Set(requirements.map(\.directory)).sorted() {
      try Task.checkCancellation()
      do {
        let data = try await request("api/experiment/models/\(folder)", onDebug: onDebug)
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
          continue
        }
        available[folder] = Set(records.compactMap { $0["name"] as? String })
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // This Cloud-only discovery endpoint is experimental. Submission is
        // still the authority when its inventory cannot be read.
        await emit(
          onDebug, stage: "Cloud model check",
          message: "Could not list \(folder) models; submission will validate the workflow.")
      }
    }
    for requirement in requirements {
      guard let names = available[requirement.directory] else { continue }
      if names.contains(requirement.selectedName) { continue }
      if let cloudName = names.first(where: {
        Self.cloudModelName($0, matches: requirement.selectedName)
      }) {
        await emit(
          onDebug, stage: "Cloud model check",
          message: "Matched \(requirement.selectedName) to Cloud model \(cloudName).")
      } else {
        // This endpoint describes Cloud's visible filesystem inventory, but
        // managed/on-demand models shown by Cloud's workflow UI can be absent
        // from it. Do not reject a valid Cloud workflow on that advisory list.
        await emit(
          onDebug, stage: "Cloud model check",
          message:
            "Cloud's model inventory does not list \(requirement.selectedName); job submission will validate it.")
      }
    }
    return []
  }

  /// Cloud's managed-model catalogue can label an entry by repository while
  /// workflow JSON keeps ComfyUI's local filename. Match the filename stem as
  /// a contiguous token sequence so `FLUX.2` and `flux-2` compare equally,
  /// without conflating Base and Distilled variants.
  nonisolated static func cloudModelName(_ available: String, matches selected: String) -> Bool {
    if available.caseInsensitiveCompare(selected) == .orderedSame { return true }
    let filename = selected.split(separator: "/").last.map(String.init) ?? selected
    let stem = filename.split(separator: ".", omittingEmptySubsequences: false).dropLast()
      .joined(separator: ".")
    let requiredTokens = modelNameTokens(stem.isEmpty ? filename : stem)
    let availableTokens = modelNameTokens(available)
    guard !requiredTokens.isEmpty, requiredTokens.count <= availableTokens.count else {
      return false
    }
    for start in 0...(availableTokens.count - requiredTokens.count) {
      if Array(availableTokens[start..<(start + requiredTokens.count)]) == requiredTokens {
        return true
      }
    }
    return false
  }

  private nonisolated static func modelNameTokens(_ value: String) -> [String] {
    value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  func uploadPNG(
    _ png: Data,
    filename: String,
    subfolder: String,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyCloudUploadedAsset {
    let filePath = "\(subfolder)/\(filename)"
    let boundary = "Pixeltje-\(UUID().uuidString)"
    let body = Self.multipartBody(
      png: png, filename: filename, filePath: filePath, boundary: boundary)
    let response = try await request(
      "api/v2/assets", method: "POST", body: body,
      contentType: "multipart/form-data; boundary=\(boundary)",
      idempotencyKey: UUID().uuidString, onDebug: onDebug)
    guard let asset = try JSONSerialization.jsonObject(with: response) as? [String: Any],
      let id = asset["id"] as? String, UUID(uuidString: id) != nil
    else {
      throw PixeltjeMacError(
        "Cloud upload failed", "Comfy Cloud did not return an asset ID.")
    }
    await emit(
      onDebug, stage: "Cloud upload",
      message: "Uploaded \(filename) (\(png.count) bytes) as asset \(id).")
    return ComfyCloudUploadedAsset(
      id: id, hash: asset["hash"] as? String,
      filePath: asset["file_path"] as? String ?? filePath)
  }

  func run(
    _ workflow: ComfyUIWorkflowRequest,
    onAccepted: @Sendable (String) async -> Void,
    onState: @Sendable (GenerationJobState, Double) async -> Void,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIRunResult {
    guard let graph = try JSONSerialization.jsonObject(with: workflow.workflow) as? [String: Any]
    else {
      throw PixeltjeMacError("Workflow invalid", "The frozen workflow is not a JSON object.")
    }
    let body = try JSONSerialization.data(withJSONObject: ["workflow": graph])
    let response = try await request(
      "api/v2/jobs", method: "POST", body: body,
      idempotencyKey: UUID().uuidString, onDebug: onDebug)
    let accepted = try job(from: response)
    guard let jobID = accepted["id"] as? String, UUID(uuidString: jobID) != nil else {
      throw PixeltjeMacError("Cloud job unavailable", "Comfy Cloud did not return a job ID.")
    }
    await emit(onDebug, stage: "Cloud submission", message: "Accepted job \(jobID).")
    await onAccepted(jobID)

    do {
      var current = accepted
      while true {
        try Task.checkCancellation()
        let state = Self.remoteStatus(from: current)
        switch state {
        case .queued:
          await onState(.queued, 0.03)
        case .running:
          let progress = current["progress"] as? [String: Any]
          let value = min(max(progress?["value"] as? Double ?? 0, 0), 1)
          if let step = progress?["step"] as? Int,
            let steps = progress?["steps"] as? Int, steps > 0
          {
            await onState(.denoising(step: step, total: steps), 0.03 + value * 0.93)
          } else {
            await onState(.loadingModel, 0.03 + value * 0.93)
          }
        case .succeeded:
          await onState(.finalizing, 0.97)
          let image = try await downloadImage(
            from: current, preferredNodeIDs: workflow.outputNodeIDs, onDebug: onDebug)
          return ComfyUIRunResult(promptID: jobID, imageData: image)
        case .failed(let message):
          throw PixeltjeMacError("Cloud generation failed", message)
        case .unknown:
          throw PixeltjeMacError("Cloud job unavailable", "Comfy Cloud returned an unknown job state.")
        }
        try await Task.sleep(for: .seconds(2))
        current = try job(from: await request(
          "api/v2/jobs/\(jobID)", onDebug: onDebug))
      }
    } catch is CancellationError {
      // The document owns remote cancellation so one user action maps to one
      // job-specific cancellation request.
      throw CancellationError()
    }
  }

  func status(jobID: String, onDebug: ComfyUIDebugSink? = nil) async throws
    -> ComfyUIRemoteJobStatus
  {
    guard UUID(uuidString: jobID) != nil else { return .unknown }
    let response = try await request("api/v2/jobs/\(jobID)", onDebug: onDebug)
    return Self.remoteStatus(from: try job(from: response))
  }

  func cancel(jobID: String, onDebug: ComfyUIDebugSink? = nil) async {
    guard UUID(uuidString: jobID) != nil else { return }
    _ = try? await request(
      "api/v2/jobs/\(jobID)/cancel", method: "POST", onDebug: onDebug)
  }

  private func downloadImage(
    from job: [String: Any],
    preferredNodeIDs: [String],
    onDebug: ComfyUIDebugSink?
  ) async throws -> Data {
    let outputs = (job["outputs"] as? [[String: Any]] ?? []).filter {
      ($0["type"] as? String) == "image"
    }
    let selected = preferredNodeIDs.lazy.compactMap { nodeID in
      outputs.first { ($0["node_id"] as? String) == nodeID }
    }.first ?? outputs.first
    guard let selected, let assetID = selected["id"] as? String,
      UUID(uuidString: assetID) != nil
    else {
      throw PixeltjeMacError(
        "Cloud output unavailable", "The completed workflow did not publish an image.")
    }
    // Fetch a fresh short-lived signed URL instead of logging or persisting it.
    let assetData = try await request("api/v2/assets/\(assetID)", onDebug: onDebug)
    guard let asset = try JSONSerialization.jsonObject(with: assetData) as? [String: Any],
      let address = asset["url"] as? String,
      let url = URL(string: address), url.scheme == "https", url.host != nil
    else {
      throw PixeltjeMacError("Cloud output unavailable", "The image download URL is invalid.")
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(from: url)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      // Transport errors can contain the signed URL. Keep it out of job
      // details and debug events.
      throw PixeltjeMacError("Cloud download failed", "Could not download the generated image.")
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw PixeltjeMacError("Cloud download failed", "Could not download the generated image.")
    }
    await emit(
      onDebug, stage: "Cloud download",
      message: "Downloaded \(data.count) image bytes from asset \(assetID).")
    return data
  }

  private static func remoteStatus(from job: [String: Any]) -> ComfyUIRemoteJobStatus {
    switch job["status"] as? String {
    case "queued": return .queued
    case "running", "canceling": return .running
    case "succeeded": return .succeeded
    case "failed":
      let error = job["error"] as? [String: Any]
      return .failed(error?["message"] as? String ?? "Comfy Cloud could not run the workflow.")
    case "canceled": return .failed("The Cloud job was cancelled.")
    case "expired": return .failed("The Cloud job expired before completion.")
    default: return .unknown
    }
  }

  private func job(from data: Data) throws -> [String: Any] {
    guard let job = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PixeltjeMacError("Cloud job unavailable", "Comfy Cloud returned invalid job data.")
    }
    return job
  }

  private func request(
    _ path: String,
    method: String = "GET",
    body: Data? = nil,
    contentType: String = "application/json",
    idempotencyKey: String? = nil,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> Data {
    let url = Self.baseURL.appendingPathComponent(path)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 60
    if path.hasPrefix("api/v2/") {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    } else {
      request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    }
    if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    if let idempotencyKey {
      request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
    guard let http = response as? HTTPURLResponse else {
      throw PixeltjeMacError("Cloud request failed", "Comfy Cloud returned no HTTP response.")
    }
    await emit(
      onDebug, stage: "Cloud HTTP",
      message: "\(method) /\(path) → HTTP \(http.statusCode).")
    guard (200..<300).contains(http.statusCode) else {
      let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let detail = envelope?["error"] as? [String: Any]
      let message = detail?["message"] as? String
      switch http.statusCode {
      case 401:
        throw PixeltjeMacError("Cloud authentication failed", "Check the Comfy Cloud API key in Settings.")
      case 402:
        throw PixeltjeMacError("Cloud credits exhausted", message ?? "Your Comfy Cloud account needs more credits.")
      default:
        throw PixeltjeMacError(
          "Cloud request failed", message ?? "Comfy Cloud returned HTTP \(http.statusCode).")
      }
    }
    return data
  }

  private func emit(_ sink: ComfyUIDebugSink?, stage: String, message: String) async {
    await sink?(ComfyUIDebugEvent(stage: stage, message: message))
  }

  nonisolated static func multipartBody(
    png: Data, filename: String, filePath: String, boundary: String
  ) -> Data {
    var body = Data()
    func append(_ string: String) { body.append(contentsOf: string.utf8) }
    func field(_ name: String, _ value: String) {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      append("\(value)\r\n")
    }
    // Cloud streams the file part as it arrives and needs its metadata before
    // those bytes. Sending these fields after `file` is valid multipart, but
    // the v2 endpoint rejects it because it cannot classify the stream yet.
    field("content_type", "image/png")
    field("file_path", filePath)
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
    append("Content-Type: image/png\r\n\r\n")
    body.append(png)
    append("\r\n")
    append("--\(boundary)--\r\n")
    return body
  }
}

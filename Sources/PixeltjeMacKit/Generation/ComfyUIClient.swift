import Foundation

enum ComfyUIRemoteJobStatus: Equatable, Sendable {
  case queued
  case running
  case succeeded
  case failed(String)
  case unknown
}

struct ComfyUIRunResult: Sendable {
  var promptID: String
  var imageData: Data
}

struct ComfyUIUploadedImage: Decodable, Equatable, Sendable {
  var name: String
  var subfolder: String
  var type: String

  var workflowValue: String {
    let path = subfolder.isEmpty ? name : "\(subfolder)/\(name)"
    return type == "input" ? path : "\(path) [\(type)]"
  }
}

actor ComfyUIClient {
  private let baseURL: URL
  private let session: URLSession

  init(
    baseURL: URL = ComfyUIClient.configuredBaseURL,
    session: URLSession = .shared
  ) {
    self.baseURL = baseURL
    self.session = session
  }

  nonisolated static var configuredBaseURL: URL {
    let configured = ProcessInfo.processInfo.environment["PIXELTJE_COMFYUI_URL"]
      ?? "http://127.0.0.1:8188"
    return URL(string: configured) ?? URL(string: "http://127.0.0.1:8188")!
  }

  nonisolated var displayAddress: String { baseURL.absoluteString }

  func checkConnection(onDebug: ComfyUIDebugSink? = nil) async -> Bool {
    do {
      _ = try await data(path: "system_stats", onDebug: onDebug)
      return true
    } catch {
      await emitDebug(onDebug, stage: "Connection", message: "Health check failed: \(error)")
      return false
    }
  }

  /// Loads only the node definitions used by one installed workflow. This
  /// keeps the form faithful to the connected server (including custom nodes
  /// and its model lists) without downloading the full object-info catalogue.
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
    let classTypes = try ComfyUIWorkflowCatalog.nodeClassTypes(in: resolved)
    await emitDebug(
      onDebug,
      stage: "Schema",
      message: "Loading live definitions for \(classTypes.count) node classes:\n\(classTypes.joined(separator: ", "))")
    var objectInfoByClass: [String: Data] = [:]
    for classType in classTypes {
      try Task.checkCancellation()
      objectInfoByClass[classType] = try await data(
        path: "object_info/\(classType)", onDebug: onDebug)
    }
    return try ComfyUIWorkflowCatalog.workflowForm(
      resolved: resolved,
      objectInfoByClass: objectInfoByClass)
  }

  /// Compares resolved model selections with ComfyUI's model-folder inventory.
  /// This honors extra model paths without depending on how loader nodes
  /// describe their inputs in /object_info.
  func missingModels(
    in workflow: ComfyUIWorkflowRequest,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> [ComfyUIRequiredModel] {
    let requirements = try ComfyUIResourceCatalog.requiredModels(in: workflow.workflow)
    var availableByDirectory: [String: Set<String>] = [:]
    for directory in Set(requirements.map(\.directory)).sorted() {
      try Task.checkCancellation()
      do {
        let response = try await data(path: "models/\(directory)", onDebug: onDebug)
        guard let names = try JSONSerialization.jsonObject(with: response) as? [String] else {
          await emitDebug(
            onDebug, stage: "Model preflight",
            message: "ComfyUI returned an unreadable model list for \(directory); server submission will validate this folder.")
          continue
        }
        availableByDirectory[directory] = Set(names)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        await emitDebug(
          onDebug, stage: "Model preflight",
          message: "Could not list \(directory) models: \(error). Server submission will validate this folder.")
      }
    }
    let missing = requirements.filter { requirement in
      availableByDirectory[requirement.directory].map {
        !$0.contains(requirement.selectedName)
      } ?? false
    }
    await emitDebug(
      onDebug,
      stage: "Model preflight",
      message: "Checked \(requirements.count) selected model(s) across \(availableByDirectory.count) model folder(s); \(missing.count) unavailable.")
    return missing
  }

  /// Uploads one generated PNG into a unique temporary ComfyUI subfolder.
  /// The returned value, rather than the requested name, is what must be
  /// frozen into LoadImage because the server owns collision handling.
  func uploadPNG(
    _ png: Data,
    filename: String,
    subfolder: String,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIUploadedImage {
    await emitDebug(
      onDebug,
      stage: "Upload",
      message: "Preparing \(filename)\nPNG bytes: \(png.count)\nTemporary subfolder: \(subfolder)")
    let boundary = "Pixeltje-\(UUID().uuidString)"
    let body = Self.multipartBody(
      png: png,
      filename: filename,
      subfolder: subfolder,
      boundary: boundary)
    let response = try await request(
      path: "upload/image",
      method: "POST",
      body: body,
      contentType: "multipart/form-data; boundary=\(boundary)",
      onDebug: onDebug)
    do {
      let uploaded = try JSONDecoder().decode(ComfyUIUploadedImage.self, from: response)
      await emitDebug(
        onDebug,
        stage: "Upload",
        message: "Server accepted \(filename)\nWorkflow value: \(uploaded.workflowValue)\nReturned type: \(uploaded.type)")
      return uploaded
    } catch {
      throw PixeltjeMacError(
        "ComfyUI upload failed", "The server returned an invalid image-upload response.")
    }
  }

  /// Submits with HTTP, then follows execution over one WebSocket. If the
  /// socket is lost after submission, history polling keeps ownership of the
  /// accepted server job instead of reporting a false failure.
  func run(
    _ workflow: ComfyUIWorkflowRequest,
    onAccepted: @Sendable (String) async -> Void,
    onState: @Sendable (GenerationJobState, Double) async -> Void,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIRunResult {
    let clientID = UUID().uuidString
    let socketURL = try webSocketURL(clientID: clientID)
    await emitDebug(
      onDebug,
      stage: "WebSocket",
      message: "Opening \(socketURL.absoluteString)\nClient ID: \(clientID)")
    let socket = session.webSocketTask(with: socketURL)
    socket.resume()
    defer { socket.cancel(with: .normalClosure, reason: nil) }

    let promptID = try await submit(
      workflow.workflow, clientID: clientID, onDebug: onDebug)
    await emitDebug(
      onDebug,
      stage: "Submission",
      message: "ComfyUI accepted prompt \(promptID).")
    await onAccepted(promptID)

    do {
      try await withTaskCancellationHandler {
        try await followExecution(
          promptID: promptID,
          socket: socket,
          steps: workflow.steps,
          onState: onState,
          onDebug: onDebug)
      } onCancel: {
        socket.cancel(with: .goingAway, reason: nil)
      }
    } catch is CancellationError {
      // The document owns remote cancellation. Keeping it out of the run task
      // prevents one user action from issuing the same cancellation twice.
      throw CancellationError()
    } catch {
      // The prompt is already accepted. A severed WebSocket is recoverable by
      // asking history/queue until the job reaches a terminal state.
      await emitDebug(
        onDebug,
        stage: "WebSocket",
        message: "Live event stream ended with \(error). Falling back to history and queue polling.")
      try await pollUntilComplete(
        promptID: promptID, onState: onState, onDebug: onDebug)
    }

    await onState(.finalizing, 0.97)
    let output = try await waitForOutput(
      promptID: promptID,
      preferredNodeIDs: workflow.outputNodeIDs,
      onDebug: onDebug)
    await emitDebug(
      onDebug,
      stage: "Download",
      message: "Received \(output.count) encoded image bytes for prompt \(promptID).")
    return ComfyUIRunResult(promptID: promptID, imageData: output)
  }

  func status(
    promptID: String,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> ComfyUIRemoteJobStatus {
    if let record = try await historyRecord(promptID: promptID, onDebug: onDebug) {
      if let failure = historyFailure(in: record) { return .failed(failure) }
      if outputDescriptor(in: record, preferredNodeIDs: []) != nil { return .succeeded }
      if let status = record["status"] as? [String: Any],
        status["completed"] as? Bool == true
      {
        return .failed("ComfyUI completed without an image output.")
      }
      return .running
    }

    let queueData = try await data(path: "queue", onDebug: onDebug)
    guard let queue = try JSONSerialization.jsonObject(with: queueData) as? [String: Any] else {
      return .unknown
    }
    if contains(promptID, in: queue["queue_running"]) { return .running }
    if contains(promptID, in: queue["queue_pending"]) { return .queued }
    return .unknown
  }

  func cancel(promptID: String, onDebug: ComfyUIDebugSink? = nil) async {
    let path = "api/jobs/\(promptID)/cancel"
    let result: (data: Data, response: HTTPURLResponse?)
    do {
      result = try await sendRequest(
        path: path, method: "POST", onDebug: onDebug)
    } catch {
      return
    }

    if let response = result.response, (200..<300).contains(response.statusCode) {
      await emitDebug(
        onDebug,
        stage: "Cancellation",
        message: "Cancelled ComfyUI prompt \(promptID) through the prompt-specific job route.")
      return
    }

    guard let statusCode = result.response?.statusCode, statusCode == 404 || statusCode == 405
    else {
      await emitDebug(
        onDebug,
        stage: "Cancellation",
        message: "ComfyUI did not accept prompt-specific cancellation for \(promptID). The remote prompt may continue, but no other document was interrupted.")
      return
    }

    // Older ComfyUI servers do not have an atomic prompt-specific cancellation
    // route. Deleting this exact queue entry is safe if it is still pending. If
    // it has started, leave it running rather than calling the legacy global
    // /interrupt route and risking another document's prompt.
    await emitDebug(
      onDebug,
      stage: "Cancellation compatibility",
      message: "This ComfyUI server does not support prompt-specific job cancellation. Removing \(promptID) only if it is still queued; an already-running prompt will finish remotely to protect other documents.")
    if let body = try? JSONSerialization.data(withJSONObject: ["delete": [promptID]]) {
      _ = try? await request(
        path: "queue", method: "POST", body: body, onDebug: onDebug)
    }
  }

  private func submit(
    _ workflow: Data,
    clientID: String,
    onDebug: ComfyUIDebugSink?
  ) async throws -> String {
    guard let prompt = try JSONSerialization.jsonObject(with: workflow) as? [String: Any] else {
      throw PixeltjeMacError("Workflow invalid", "The rendered workflow is not a JSON object.")
    }
    let body: [String: Any] = [
      "prompt": prompt,
      "client_id": clientID,
    ]
    let encoded = try JSONSerialization.data(withJSONObject: body)
    let response = try await request(
      path: "prompt", method: "POST", body: encoded, onDebug: onDebug)
    guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any]
    else {
      throw PixeltjeMacError("ComfyUI rejected the job", "The server returned invalid JSON.")
    }
    if let error = json["error"] as? [String: Any] {
      throw PixeltjeMacError(
        "ComfyUI rejected the workflow",
        workflowRejectionDetails(error: error, nodeErrors: json["node_errors"]))
    }
    guard let promptID = json["prompt_id"] as? String else {
      throw PixeltjeMacError(
        "ComfyUI rejected the job", "The server response did not contain a prompt ID.")
    }
    return promptID
  }

  private func followExecution(
    promptID: String,
    socket: URLSessionWebSocketTask,
    steps: Int,
    onState: @Sendable (GenerationJobState, Double) async -> Void,
    onDebug: ComfyUIDebugSink?
  ) async throws {
    var hasReportedProgress = false
    while true {
      try Task.checkCancellation()
      let message = try await socket.receive()
      let payload: Data
      switch message {
      case .data(let data):
        // Binary messages are preview images with a small ComfyUI header. The
        // first integration tracks progress but imports only the final output.
        if data.first != UInt8(ascii: "{") {
          await emitDebug(
            onDebug,
            stage: "WebSocket preview",
            message: "Received \(data.count) binary preview bytes; preview payload omitted.")
          continue
        }
        payload = data
      case .string(let text):
        payload = Data(text.utf8)
      @unknown default:
        continue
      }
      guard let envelope = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
        let type = envelope["type"] as? String,
        let event = envelope["data"] as? [String: Any]
      else {
        await emitDebug(
          onDebug,
          stage: "WebSocket",
          message: "Ignored an undecodable event:\n\(String(decoding: payload.prefix(4_096), as: UTF8.self))")
        continue
      }
      if let eventPromptID = event["prompt_id"] as? String, eventPromptID != promptID {
        continue
      }
      await emitDebug(
        onDebug,
        stage: "WebSocket \(type)",
        message: prettyJSON(envelope))

      switch type {
      case "execution_start":
        await onState(.preparing, 0.03)
      case "executing":
        if event["node"] is NSNull {
          return
        }
        if hasReportedProgress {
          await onState(.finalizing, 0.95)
        } else {
          await onState(.loadingModel, 0.05)
        }
      case "progress":
        hasReportedProgress = true
        let value = numericInt(event["value"])
        let maximum = max(numericInt(event["max"]), steps, 1)
        let current = clamp(value, minimum: 0, maximum: maximum)
        await onState(
          .denoising(step: current, total: maximum),
          0.05 + 0.88 * Double(current) / Double(maximum))
      case "execution_success":
        return
      case "execution_error":
        throw PixeltjeMacError(
          "ComfyUI generation failed", executionErrorDetails(event))
      case "execution_interrupted":
        throw CancellationError()
      default:
        continue
      }
    }
  }

  private func pollUntilComplete(
    promptID: String,
    onState: @Sendable (GenerationJobState, Double) async -> Void,
    onDebug: ComfyUIDebugSink?
  ) async throws {
    while true {
      try Task.checkCancellation()
      let status = try await status(promptID: promptID, onDebug: onDebug)
      await emitDebug(
        onDebug,
        stage: "Polling",
        message: "Prompt \(promptID) status: \(debugLabel(for: status))")
      switch status {
      case .succeeded:
        return
      case .failed(let message):
        throw PixeltjeMacError("ComfyUI generation failed", message)
      case .queued:
        await onState(.queued, 0)
      case .running:
        await onState(.preparing, 0.03)
      case .unknown:
        break
      }
      try await Task.sleep(for: .seconds(1))
    }
  }

  private func waitForOutput(
    promptID: String,
    preferredNodeIDs: [String],
    onDebug: ComfyUIDebugSink?
  ) async throws -> Data {
    for attempt in 1...20 {
      try Task.checkCancellation()
      if let record = try await historyRecord(promptID: promptID, onDebug: onDebug) {
        if let failure = historyFailure(in: record) {
          throw PixeltjeMacError("ComfyUI generation failed", failure)
        }
        if let descriptor = outputDescriptor(
          in: record,
          preferredNodeIDs: preferredNodeIDs)
        {
          await emitDebug(
            onDebug,
            stage: "Output",
            message: "Selected published image\nFilename: \(descriptor.filename)\nSubfolder: \(descriptor.subfolder)\nType: \(descriptor.type)\nPreferred nodes: \(preferredNodeIDs.joined(separator: ", "))")
          return try await data(
            path: "view",
            queryItems: [
              URLQueryItem(name: "filename", value: descriptor.filename),
              URLQueryItem(name: "subfolder", value: descriptor.subfolder),
              URLQueryItem(name: "type", value: descriptor.type),
            ],
            onDebug: onDebug)
        }
      }
      await emitDebug(
        onDebug,
        stage: "Output",
        message: "History attempt \(attempt) of 20 has no published image yet.")
      try await Task.sleep(for: .milliseconds(250))
    }
    throw PixeltjeMacError(
      "ComfyUI output unavailable", "The completed workflow did not publish an image.")
  }

  private func historyRecord(
    promptID: String,
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> [String: Any]? {
    let payload = try await data(path: "history/\(promptID)", onDebug: onDebug)
    guard let history = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
    else { return nil }
    return history[promptID] as? [String: Any]
  }

  private func outputDescriptor(
    in record: [String: Any],
    preferredNodeIDs: [String]
  ) -> OutputDescriptor? {
    guard let outputs = record["outputs"] as? [String: Any] else { return nil }
    let preferred = preferredNodeIDs.compactMap { outputs[$0] as? [String: Any] }
    let fallback = outputs.keys.sorted()
      .filter { !preferredNodeIDs.contains($0) }
      .compactMap { outputs[$0] as? [String: Any] }
    let candidates = preferred + fallback
    for output in candidates {
      guard let images = output["images"] as? [[String: Any]] else { continue }
      for image in images {
        if let filename = image["filename"] as? String {
          return OutputDescriptor(
            filename: filename,
            subfolder: image["subfolder"] as? String ?? "",
            type: image["type"] as? String ?? "output")
        }
      }
    }
    return nil
  }

  private func historyFailure(in record: [String: Any]) -> String? {
    guard let status = record["status"] as? [String: Any] else { return nil }
    if status["status_str"] as? String == "error" {
      if let messages = status["messages"] as? [Any] {
        for case let entry as [Any] in messages.reversed() {
          guard entry.count >= 2,
            entry[0] as? String == "execution_error",
            let event = entry[1] as? [String: Any]
          else { continue }
          return executionErrorDetails(event)
        }
      }
      return "ComfyUI reported an execution error."
    }
    return nil
  }

  private func workflowRejectionDetails(error: [String: Any], nodeErrors: Any?) -> String {
    var sections: [String] = []
    appendDetail(error["message"] as? String, to: &sections)
    appendDetail(error["details"] as? String, to: &sections)
    if let type = nonempty(error["type"] as? String) {
      sections.append("Type: \(type)")
    }

    if let nodes = nodeErrors as? [String: Any] {
      for nodeID in nodes.keys.sorted() {
        guard let node = nodes[nodeID] as? [String: Any] else { continue }
        let classType = nonempty(node["class_type"] as? String)
        sections.append(classType.map { "Node \(nodeID) (\($0))" } ?? "Node \(nodeID)")
        guard let errors = node["errors"] as? [[String: Any]] else { continue }
        for error in errors {
          let message =
            nonempty(error["message"] as? String)
            ?? nonempty(error["type"] as? String)
            ?? "Validation failed."
          sections.append("- \(message)")
          if let details = nonempty(error["details"] as? String), details != message {
            sections.append("  \(details)")
          }
        }
      }
    }

    return boundedDetails(
      sections.isEmpty ? "The workflow was rejected." : sections.joined(separator: "\n"))
  }

  private func executionErrorDetails(_ event: [String: Any]) -> String {
    var sections: [String] = []
    appendDetail(event["exception_message"] as? String, to: &sections)
    if let nodeID = nonempty(event["node_id"] as? String) {
      let nodeType = nonempty(event["node_type"] as? String)
      sections.append(nodeType.map { "Node: \(nodeID) (\($0))" } ?? "Node: \(nodeID)")
    }
    if let type = nonempty(event["exception_type"] as? String) {
      sections.append("Exception: \(type)")
    }
    if let traceback = event["traceback"] as? [String], !traceback.isEmpty {
      sections.append("Traceback:\n\(traceback.joined())")
    }
    return boundedDetails(
      sections.isEmpty
        ? "ComfyUI failed while executing the workflow."
        : sections.joined(separator: "\n\n"))
  }

  private func appendDetail(_ value: String?, to sections: inout [String]) {
    guard let value = nonempty(value), !sections.contains(value) else { return }
    sections.append(value)
  }

  private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func boundedDetails(_ value: String) -> String {
    let limit = 32_000
    guard value.count > limit else { return value }
    return String(value.prefix(limit)) + "\n\n…additional ComfyUI details omitted"
  }

  private func contains(_ promptID: String, in value: Any?) -> Bool {
    if let string = value as? String { return string == promptID }
    if let array = value as? [Any] { return array.contains { contains(promptID, in: $0) } }
    if let dictionary = value as? [String: Any] {
      return dictionary.values.contains { contains(promptID, in: $0) }
    }
    return false
  }

  private func data(
    path: String,
    queryItems: [URLQueryItem] = [],
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> Data {
    try await request(
      path: path, method: "GET", queryItems: queryItems, onDebug: onDebug)
  }

  private func request(
    path: String,
    method: String,
    body: Data? = nil,
    contentType: String? = "application/json",
    queryItems: [URLQueryItem] = [],
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> Data {
    let result = try await sendRequest(
      path: path,
      method: method,
      body: body,
      contentType: contentType,
      queryItems: queryItems,
      onDebug: onDebug)
    guard let httpResponse = result.response,
      (200..<300).contains(httpResponse.statusCode)
    else {
      let message = String(data: result.data, encoding: .utf8) ?? "No response body."
      throw PixeltjeMacError(
        "ComfyUI request failed",
        "HTTP \(result.response?.statusCode ?? 0): \(message)")
    }
    return result.data
  }

  private func sendRequest(
    path: String,
    method: String,
    body: Data? = nil,
    contentType: String? = "application/json",
    queryItems: [URLQueryItem] = [],
    onDebug: ComfyUIDebugSink? = nil
  ) async throws -> (data: Data, response: HTTPURLResponse?) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    components?.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components?.url else {
      throw PixeltjeMacError("ComfyUI URL invalid", "Could not construct the server URL.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 30
    if body != nil, let contentType {
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    await emitDebug(
      onDebug,
      stage: "HTTP request",
      message: "\(method) \(url.absoluteString)\n\(requestBodyDescription(body, contentType: contentType))")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      await emitDebug(
        onDebug,
        stage: "HTTP transport error",
        message: "\(method) \(url.absoluteString)\n\(error)")
      throw error
    }
    let httpResponse = response as? HTTPURLResponse
    await emitDebug(
      onDebug,
      stage: "HTTP response",
      message: "\(method) \(url.absoluteString)\nStatus: \(httpResponse?.statusCode ?? 0)\n\(responseBodyDescription(data, response: httpResponse))")
    return (data, httpResponse)
  }

  private func emitDebug(
    _ sink: ComfyUIDebugSink?,
    stage: String,
    message: String
  ) async {
    guard let sink else { return }
    await sink(ComfyUIDebugEvent(stage: stage, message: boundedDetails(message)))
  }

  private func requestBodyDescription(_ body: Data?, contentType: String?) -> String {
    guard let body else { return "Body: none" }
    if contentType?.contains("application/json") == true,
      let object = try? JSONSerialization.jsonObject(with: body)
    {
      return "Body: \(body.count) bytes\n\(prettyJSON(object))"
    }
    return "Body: \(body.count) bytes; binary multipart content omitted"
  }

  private func responseBodyDescription(_ data: Data, response: HTTPURLResponse?) -> String {
    let mimeType = response?.mimeType ?? "unknown"
    if mimeType.contains("json") || data.first == UInt8(ascii: "{")
      || data.first == UInt8(ascii: "[")
    {
      if let object = try? JSONSerialization.jsonObject(with: data) {
        return "Content-Type: \(mimeType)\nBody: \(data.count) bytes\n\(prettyJSON(object))"
      }
    }
    return "Content-Type: \(mimeType)\nBody: \(data.count) bytes; binary content omitted"
  }

  private func prettyJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return String(describing: value) }
    return text
  }

  private func debugLabel(for status: ComfyUIRemoteJobStatus) -> String {
    switch status {
    case .queued: "queued"
    case .running: "running"
    case .succeeded: "succeeded"
    case .failed(let message): "failed: \(message)"
    case .unknown: "unknown"
    }
  }

  private func webSocketURL(clientID: String) throws -> URL {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
    components?.path = baseURL.path.appending("/ws")
    components?.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
    guard let url = components?.url else {
      throw PixeltjeMacError("ComfyUI URL invalid", "Could not construct the WebSocket URL.")
    }
    return url
  }

  private func numericInt(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return 0
  }

  private func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
    min(max(value, minimum), maximum)
  }

  nonisolated static func multipartBody(
    png: Data,
    filename: String,
    subfolder: String,
    boundary: String
  ) -> Data {
    var result = Data()
    func append(_ value: String) {
      result.append(contentsOf: value.utf8)
    }
    func appendField(name: String, value: String) {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      append("\(value)\r\n")
    }

    append("--\(boundary)\r\n")
    append(
      "Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n")
    append("Content-Type: image/png\r\n\r\n")
    result.append(png)
    append("\r\n")
    appendField(name: "type", value: "temp")
    appendField(name: "subfolder", value: subfolder)
    appendField(name: "overwrite", value: "true")
    append("--\(boundary)--\r\n")
    return result
  }

  private struct OutputDescriptor {
    var filename: String
    var subfolder: String
    var type: String
  }
}

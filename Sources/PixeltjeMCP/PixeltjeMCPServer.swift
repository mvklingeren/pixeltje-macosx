import Foundation
import Network
import PixeltjeAutomation

/// A small in-process MCP Streamable HTTP adapter.
///
/// It binds only to IPv4 loopback, requires a bearer token for every request,
/// and delegates all product behavior to `PixeltjeAutomationService`.
@MainActor
public final class PixeltjeMCPServer {
  public static let defaultPort: UInt16 = 46_372

  private let service: any PixeltjeAutomationService
  private let accessToken: String
  private let scopes: Set<AutomationScope>
  private let port: UInt16
  private let networkQueue = DispatchQueue(label: "org.pixeltje.mac.mcp")
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: MCPHTTPConnection] = [:]
  public var onReady: (@MainActor () -> Void)?
  public var onFailure: (@MainActor (String) -> Void)?

  public init(
    service: any PixeltjeAutomationService,
    accessToken: String,
    scopes: Set<AutomationScope> = [.read],
    port: UInt16 = PixeltjeMCPServer.defaultPort
  ) {
    self.service = service
    self.accessToken = accessToken
    self.scopes = scopes.union([.read])
    self.port = port
  }

  public var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

  public func start() throws {
    guard listener == nil else { return }
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw MCPServerError("Invalid automation port \(port).")
    }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state {
        Task { @MainActor in self?.onReady?() }
      } else if case .failed(let error) = state {
        Task { @MainActor in
          self?.stop()
          self?.onFailure?(error.localizedDescription)
        }
      }
    }
    self.listener = listener
    listener.start(queue: networkQueue)
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    let active = Array(connections.values)
    connections.removeAll()
    for connection in active { connection.stop() }
  }

  private func accept(_ connection: NWConnection) {
    let client = MCPHTTPConnection(
      connection: connection,
      accessToken: accessToken,
      queue: networkQueue,
      handle: { [weak self] body, clientID in
        guard let self else {
          return .json(status: 503, object: ["error": "Automation server stopped."])
        }
        return self.handle(body, clientID: clientID)
      }
    )
    let id = ObjectIdentifier(client)
    client.onClose = { [weak self] in self?.connections.removeValue(forKey: id) }
    connections[id] = client
    client.start()
  }

  private func handle(_ body: Data, clientID: String) -> MCPHTTPResponse {
    let request: [String: Any]
    do {
      guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return jsonRPCError(id: NSNull(), code: -32_600, message: "Invalid Request")
      }
      request = object
    } catch {
      return jsonRPCError(id: NSNull(), code: -32_700, message: "Parse error")
    }

    let id = request["id"] ?? NSNull()
    guard request["jsonrpc"] as? String == "2.0",
      let method = request["method"] as? String
    else {
      return jsonRPCError(id: id, code: -32_600, message: "Invalid Request")
    }
    let params = request["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
      let requested = params["protocolVersion"] as? String
      let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
      let version = requested.flatMap { supported.contains($0) ? $0 : nil } ?? supported[0]
      return jsonRPCResult(
        id: id,
        result: [
          "protocolVersion": version,
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": ["name": "Pixeltje Mac", "version": "0.1"],
          "instructions":
            "Inspect open documents before editing. Pass the current contentRevision and a unique idempotencyKey with every mutation. Pixeltje rejects stale revisions and in-progress human gestures.",
        ]
      )
    case "ping":
      return jsonRPCResult(id: id, result: [:])
    case "notifications/initialized", "notifications/cancelled":
      return .empty(status: 202)
    case "tools/list":
      return jsonRPCResult(id: id, result: ["tools": availableToolDefinitions])
    case "tools/call":
      guard let name = params["name"] as? String else {
        return jsonRPCError(id: id, code: -32_602, message: "Tool name is required.")
      }
      let arguments = params["arguments"] as? [String: Any] ?? [:]
      return callTool(name, arguments: arguments, id: id, clientID: clientID)
    default:
      if request["id"] == nil { return .empty(status: 202) }
      return jsonRPCError(id: id, code: -32_601, message: "Method not found")
    }
  }

  /// Pure JSON-RPC entry point used by protocol tests. Tool discovery and calls
  /// can be verified without opening a port; authentication, Origin validation,
  /// and HTTP framing stay confined to the small connection adapter below.
  func handleJSONRPCForTesting(_ body: Data, clientID: String = "test") -> (Int, Data) {
    let response = handle(body, clientID: clientID)
    return (response.status, response.body)
  }

  private func callTool(
    _ name: String,
    arguments: [String: Any],
    id: Any,
    clientID: String
  ) -> MCPHTTPResponse {
    let context = AutomationRequestContext(
      clientID: clientID,
      scopes: scopes
    )
    do {
      let output: Any
      switch name {
      case "pixeltje_list_documents":
        output = ["documents": try encodableObject(service.listDocuments(context: context))]
      case "pixeltje_get_document":
        output = try encodableObject(
          service.getDocument(id: try string("documentID", in: arguments), context: context)
        )
      case "pixeltje_list_layers":
        output = [
          "layers": try encodableObject(
            service.listLayers(
              documentID: try string("documentID", in: arguments), context: context)
          )
        ]
      case "pixeltje_get_develop_settings":
        output = try encodableObject(
          service.getDevelopSettings(
            documentID: try string("documentID", in: arguments),
            layerID: try string("layerID", in: arguments),
            context: context
          )
        )
      case "pixeltje_get_history":
        output = try encodableObject(
          service.getHistory(
            documentID: try string("documentID", in: arguments), context: context)
        )
      case "pixeltje_get_histogram":
        output = try encodableObject(
          service.getHistogram(
            documentID: try string("documentID", in: arguments), context: context)
        )
      case "pixeltje_list_jobs":
        output = [
          "jobs": try encodableObject(
            service.listJobs(
              documentID: try string("documentID", in: arguments), context: context)
          )
        ]
      case "pixeltje_update_develop":
        output = try encodableObject(
          service.execute(
            .updateDevelop(try decode(AutomationDevelopPatch.self, from: arguments)),
            context: context
          )
        )
      case "pixeltje_update_layer":
        output = try encodableObject(
          service.execute(
            .updateLayer(try decode(AutomationLayerPatch.self, from: arguments)),
            context: context
          )
        )
      case "pixeltje_move_layer":
        output = try encodableObject(
          service.execute(
            .moveLayer(try decode(AutomationMoveLayerCommand.self, from: arguments)),
            context: context
          )
        )
      case "pixeltje_set_crop":
        output = try encodableObject(
          service.execute(
            .setCrop(try decode(AutomationCropCommand.self, from: arguments)),
            context: context
          )
        )
      case "pixeltje_resize_canvas":
        output = try encodableObject(
          service.execute(
            .resizeCanvas(try decode(AutomationResizeCanvasCommand.self, from: arguments)),
            context: context
          )
        )
      case "pixeltje_create_snapshot":
        output = try encodableObject(
          service.execute(
            .createSnapshot(try decode(AutomationCreateSnapshotCommand.self, from: arguments)),
            context: context
          )
        )
      case "pixeltje_restore_snapshot":
        output = try encodableObject(
          service.execute(
            .restoreSnapshot(try decode(AutomationRestoreSnapshotCommand.self, from: arguments)),
            context: context
          )
        )
      case "pixeltje_cancel_job":
        output = try encodableObject(
          service.execute(
            .cancelJob(try decode(AutomationCancelJobCommand.self, from: arguments)),
            context: context
          )
        )
      case "pixeltje_start_inpainting":
        output = try encodableObject(
          service.execute(
            .startInpainting(
              try decode(AutomationStartInpaintingCommand.self, from: arguments)),
            context: context
          )
        )
      default:
        throw AutomationServiceError(.unsupportedOperation, "Unknown tool: \(name).")
      }
      return toolResult(id: id, output: output, isError: false)
    } catch let error as AutomationServiceError {
      return toolResult(
        id: id,
        output: [
          "error": [
            "code": error.code.rawValue,
            "message": error.message,
            "details": error.details,
          ]
        ],
        isError: true
      )
    } catch {
      return toolResult(
        id: id,
        output: [
          "error": [
            "code": AutomationErrorCode.invalidArgument.rawValue,
            "message": error.localizedDescription,
          ]
        ],
        isError: true
      )
    }
  }

  private func toolResult(id: Any, output: Any, isError: Bool) -> MCPHTTPResponse {
    let text: String
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
      let encoded = String(data: data, encoding: .utf8)
    {
      text = encoded
    } else {
      text = "{\"error\":{\"code\":\"internalError\",\"message\":\"Response encoding failed.\"}}"
    }
    return jsonRPCResult(
      id: id,
      result: [
        "content": [["type": "text", "text": text]],
        "structuredContent": output,
        "isError": isError,
      ]
    )
  }

  private func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
    do {
      let data = try JSONSerialization.data(withJSONObject: object)
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw AutomationServiceError(
        .invalidArgument, "Invalid tool arguments: \(error.localizedDescription)")
    }
  }

  private func string(_ name: String, in object: [String: Any]) throws -> String {
    guard let value = object[name] as? String, !value.isEmpty else {
      throw AutomationServiceError(.invalidArgument, "\(name) is required.")
    }
    return value
  }

  private func encodableObject<T: Encodable>(_ value: T) throws -> Any {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private func jsonRPCResult(id: Any, result: Any) -> MCPHTTPResponse {
    .json(status: 200, object: ["jsonrpc": "2.0", "id": id, "result": result])
  }

  private func jsonRPCError(id: Any, code: Int, message: String) -> MCPHTTPResponse {
    .json(
      status: 200,
      object: [
        "jsonrpc": "2.0",
        "id": id,
        "error": ["code": code, "message": message],
      ]
    )
  }

  private var toolDefinitions: [[String: Any]] {
    let documentID = stringProperty("Open document ID returned by pixeltje_list_documents.")
    let layerID = stringProperty("Stable layer ID returned by pixeltje_list_layers.")
    let expectedRevision: [String: Any] = [
      "type": "integer",
      "minimum": 0,
      "description": "contentRevision from the latest document read. Stale writes are rejected.",
    ]
    let idempotencyKey = stringProperty(
      "Unique key for this logical mutation. Reuse it only when retrying the same call.")
    let readOnly: [String: Any] = [
      "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
      "openWorldHint": false,
    ]
    let edit: [String: Any] = [
      "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true,
      "openWorldHint": false,
    ]
    return [
      tool(
        "pixeltje_list_documents",
        "List open Pixeltje documents and their current revision tokens.",
        properties: [:], required: [], annotations: readOnly),
      tool(
        "pixeltje_get_document",
        "Inspect one open document without exposing source paths or bookmarks.",
        properties: ["documentID": documentID], required: ["documentID"], annotations: readOnly),
      tool(
        "pixeltje_list_layers",
        "List the complete layer tree with stable IDs, compositing, and sanitized source names.",
        properties: ["documentID": documentID], required: ["documentID"], annotations: readOnly),
      tool(
        "pixeltje_get_develop_settings",
        "Read Apple RAW capabilities and Basic Tone values for one layer.",
        properties: ["documentID": documentID, "layerID": layerID],
        required: ["documentID", "layerID"], annotations: readOnly),
      tool(
        "pixeltje_get_history", "List undo history and pinned snapshots.",
        properties: ["documentID": documentID], required: ["documentID"], annotations: readOnly),
      tool(
        "pixeltje_get_histogram", "Read the revision-tagged composite histogram when available.",
        properties: ["documentID": documentID], required: ["documentID"], annotations: readOnly),
      tool(
        "pixeltje_list_jobs", "List export and inpainting jobs without revealing filesystem paths.",
        properties: ["documentID": documentID], required: ["documentID"], annotations: readOnly),
      tool(
        "pixeltje_update_develop",
        "Atomically patch RAW and Basic Tone settings as one undoable edit.",
        properties: mutationProperties(documentID, expectedRevision, idempotencyKey).merging([
          "layerID": layerID,
          "rawFloats": numberMap("RAW parameter names to values."),
          "rawBooleans": booleanMap("RAW switch names to values."),
          "basicTone": numberMap("Basic Tone control names to values."),
        ]) { _, new in new },
        required: ["documentID", "layerID", "expectedRevision", "idempotencyKey"],
        annotations: edit),
      tool(
        "pixeltje_update_layer",
        "Atomically patch visibility, blend mode, opacity, and fill for one layer.",
        properties: mutationProperties(documentID, expectedRevision, idempotencyKey).merging([
          "layerID": layerID,
          "isEnabled": ["type": "boolean"],
          "blendMode": [
            "type": "string",
            "enum": [
              "normal", "multiply", "screen", "overlay", "darken", "lighten", "colorDodge",
              "colorBurn", "softLight", "hardLight", "difference", "exclusion", "hue",
              "saturation", "color", "luminosity",
            ],
          ],
          "opacity": unitNumber,
          "fill": unitNumber,
        ]) { _, new in new },
        required: ["documentID", "layerID", "expectedRevision", "idempotencyKey"],
        annotations: edit),
      tool(
        "pixeltje_move_layer", "Move a layer by one sibling position.",
        properties: mutationProperties(documentID, expectedRevision, idempotencyKey).merging([
          "layerID": layerID,
          "direction": ["type": "string", "enum": ["up", "down"]],
        ]) { _, new in new },
        required: ["documentID", "layerID", "direction", "expectedRevision", "idempotencyKey"],
        annotations: edit),
      tool(
        "pixeltje_set_crop",
        "Set the document crop in bottom-left-origin unit coordinates and straighten angle.",
        properties: mutationProperties(documentID, expectedRevision, idempotencyKey).merging([
          "left": unitNumber, "bottom": unitNumber, "right": unitNumber, "top": unitNumber,
          "angleDegrees": ["type": "number", "minimum": -45, "maximum": 45],
        ]) { _, new in new },
        required: [
          "documentID", "expectedRevision", "idempotencyKey", "left", "bottom", "right", "top",
          "angleDegrees",
        ], annotations: edit),
      tool(
        "pixeltje_resize_canvas",
        "Resize the canvas and place existing content by a nine-point anchor.",
        properties: mutationProperties(documentID, expectedRevision, idempotencyKey).merging([
          "width": ["type": "integer", "minimum": 1, "maximum": 32_768],
          "height": ["type": "integer", "minimum": 1, "maximum": 32_768],
          "anchor": [
            "type": "string",
            "enum": [
              "topLeft", "top", "topRight", "left", "center", "right", "bottomLeft", "bottom",
              "bottomRight",
            ],
          ],
        ]) { _, new in new },
        required: [
          "documentID", "expectedRevision", "idempotencyKey", "width", "height", "anchor",
        ],
        annotations: edit),
      tool(
        "pixeltje_create_snapshot", "Pin the current recipe as a named history snapshot.",
        properties: mutationProperties(documentID, expectedRevision, idempotencyKey).merging([
          "name": ["type": "string", "maxLength": 200]
        ]) { _, new in new },
        required: ["documentID", "expectedRevision", "idempotencyKey"], annotations: edit),
      tool(
        "pixeltje_restore_snapshot", "Restore a pinned snapshot as a new undoable history step.",
        properties: mutationProperties(documentID, expectedRevision, idempotencyKey).merging([
          "snapshotID": stringProperty("Snapshot ID returned by pixeltje_get_history.")
        ]) { _, new in new },
        required: ["documentID", "snapshotID", "expectedRevision", "idempotencyKey"],
        annotations: edit),
      tool(
        "pixeltje_start_inpainting",
        "Start FLUX.2 Klein Base inpainting against the current composite and a requested mask source.",
        properties: mutationProperties(documentID, expectedRevision, idempotencyKey).merging([
          "prompt": ["type": "string", "minLength": 1, "maxLength": 2_000],
          "negativePrompt": ["type": "string", "maxLength": 2_000],
          "seed": ["type": "integer", "minimum": 0],
          "strength": unitNumber,
          "maskBlur": ["type": "number", "minimum": 0, "maximum": 250],
          "steps": ["type": "integer", "minimum": 1, "maximum": 20],
          "guidance": ["type": "number", "minimum": 0, "maximum": 20],
          "maskSource": [
            "type": "object",
            "description":
              "Optional generation mask source. Omit it to retain legacy selection-or-entire-output behavior.",
            "properties": [
              "kind": [
                "type": "string",
                "enum": [
                  "automatic", "documentSelection", "activeLayerMask", "layerMask",
                  "localMask", "transparentPixels", "entireOutput",
                ],
              ],
              "layerID": stringProperty(
                "Owning layer ID, required for an explicit layerMask or localMask."),
              "maskID": stringProperty(
                "Mask ID, required for an explicit layerMask or localMask."),
            ],
            "required": ["kind"],
            "additionalProperties": false,
          ],
        ]) { _, new in new },
        required: [
          "documentID", "expectedRevision", "idempotencyKey", "prompt", "negativePrompt",
          "seed", "strength", "maskBlur", "steps", "guidance",
        ],
        annotations: edit),
      tool(
        "pixeltje_cancel_job", "Cancel one waiting or running export or inpainting job.",
        properties: [
          "documentID": documentID,
          "jobID": stringProperty("Job ID returned by pixeltje_list_jobs."),
          "idempotencyKey": idempotencyKey,
        ],
        required: ["documentID", "jobID", "idempotencyKey"],
        annotations: [
          "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true,
          "openWorldHint": false,
        ]),
    ]
  }

  /// Do not advertise tools the current local credential cannot use. The
  /// service repeats scope checks as defense in depth for clients that call a
  /// remembered tool name after permissions change.
  private var availableToolDefinitions: [[String: Any]] {
    toolDefinitions.filter { definition in
      guard let name = definition["name"] as? String else { return false }
      if name == "pixeltje_cancel_job" { return scopes.contains(.jobs) }
      if name == "pixeltje_start_inpainting" {
        return scopes.contains(.jobs) && scopes.contains(.edit)
      }
      if Self.editToolNames.contains(name) { return scopes.contains(.edit) }
      return scopes.contains(.read)
    }
  }

  private static let editToolNames: Set<String> = [
    "pixeltje_update_develop",
    "pixeltje_update_layer",
    "pixeltje_move_layer",
    "pixeltje_set_crop",
    "pixeltje_resize_canvas",
    "pixeltje_create_snapshot",
    "pixeltje_restore_snapshot",
    "pixeltje_start_inpainting",
  ]

  private var unitNumber: [String: Any] {
    ["type": "number", "minimum": 0, "maximum": 1]
  }

  private func mutationProperties(
    _ documentID: [String: Any],
    _ expectedRevision: [String: Any],
    _ idempotencyKey: [String: Any]
  ) -> [String: [String: Any]] {
    [
      "documentID": documentID,
      "expectedRevision": expectedRevision,
      "idempotencyKey": idempotencyKey,
    ]
  }

  private func stringProperty(_ description: String) -> [String: Any] {
    ["type": "string", "minLength": 1, "description": description]
  }

  private func numberMap(_ description: String) -> [String: Any] {
    [
      "type": "object",
      "description": description,
      "additionalProperties": ["type": "number"],
    ]
  }

  private func booleanMap(_ description: String) -> [String: Any] {
    [
      "type": "object",
      "description": description,
      "additionalProperties": ["type": "boolean"],
    ]
  }

  private func tool(
    _ name: String,
    _ description: String,
    properties: [String: [String: Any]],
    required: [String],
    annotations: [String: Any]
  ) -> [String: Any] {
    [
      "name": name,
      "description": description,
      "inputSchema": [
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": false,
      ],
      "annotations": annotations,
    ]
  }
}

private struct MCPHTTPResponse {
  var status: Int
  var body: Data
  var contentType: String?

  static func json(status: Int, object: Any) -> MCPHTTPResponse {
    let data =
      (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      ?? Data("{\"error\":\"Response encoding failed.\"}".utf8)
    return MCPHTTPResponse(status: status, body: data, contentType: "application/json")
  }

  static func empty(status: Int) -> MCPHTTPResponse {
    MCPHTTPResponse(status: status, body: Data(), contentType: nil)
  }
}

@MainActor
private final class MCPHTTPConnection {
  private static let maximumRequestBytes = 1_048_576

  let connection: NWConnection
  let accessToken: String
  let queue: DispatchQueue
  let handle: @MainActor (Data, String) -> MCPHTTPResponse
  var onClose: (@MainActor () -> Void)?
  private var buffer = Data()
  private var isClosed = false

  init(
    connection: NWConnection,
    accessToken: String,
    queue: DispatchQueue,
    handle: @escaping @MainActor (Data, String) -> MCPHTTPResponse
  ) {
    self.connection = connection
    self.accessToken = accessToken
    self.queue = queue
    self.handle = handle
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state {
        Task { @MainActor in self?.close() }
      }
      if case .cancelled = state {
        Task { @MainActor in self?.close() }
      }
    }
    connection.start(queue: queue)
    receive()
  }

  func stop() {
    connection.cancel()
    close()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      Task { @MainActor in
        guard let self, !self.isClosed else { return }
        if let data { self.buffer.append(data) }
        if self.buffer.count > Self.maximumRequestBytes {
          self.send(.json(status: 413, object: ["error": "Request too large."]))
          return
        }
        if let request = self.parsedRequest() {
          self.respond(to: request)
        } else if error != nil || isComplete {
          self.send(.json(status: 400, object: ["error": "Incomplete HTTP request."]))
        } else {
          self.receive()
        }
      }
    }
  }

  private struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
  }

  private func parsedRequest() -> Request? {
    let separator = Data("\r\n\r\n".utf8)
    guard let range = buffer.range(of: separator) else { return nil }
    let headerData = buffer[..<range.lowerBound]
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    guard let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0
    else { return nil }
    let bodyStart = range.upperBound
    guard buffer.count - bodyStart >= length else { return nil }
    let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
    return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
  }

  private func respond(to request: Request) {
    guard request.method == "POST", request.path == "/mcp" else {
      send(.json(status: 404, object: ["error": "Not found."]))
      return
    }
    guard request.headers["authorization"] == "Bearer \(accessToken)" else {
      send(.json(status: 401, object: ["error": "Bearer authentication required."]))
      return
    }
    if let origin = request.headers["origin"], !MCPRequestSecurity.isAllowedOrigin(origin) {
      send(.json(status: 403, object: ["error": "Origin is not allowed."]))
      return
    }
    guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
      send(.json(status: 415, object: ["error": "Content-Type must be application/json."]))
      return
    }
    let clientID =
      request.headers["mcp-session-id"]
      ?? request.headers["x-pixeltje-client-id"]
      ?? "local-mcp"
    send(handle(request.body, clientID))
  }

  private func send(_ response: MCPHTTPResponse) {
    let reason: String
    switch response.status {
    case 200: reason = "OK"
    case 202: reason = "Accepted"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 403: reason = "Forbidden"
    case 404: reason = "Not Found"
    case 413: reason = "Content Too Large"
    case 415: reason = "Unsupported Media Type"
    case 503: reason = "Service Unavailable"
    default: reason = "Error"
    }
    var headers = "HTTP/1.1 \(response.status) \(reason)\r\n"
    if let type = response.contentType { headers += "Content-Type: \(type)\r\n" }
    headers += "Content-Length: \(response.body.count)\r\n"
    headers += "Cache-Control: no-store\r\n"
    headers += "Connection: close\r\n\r\n"
    var packet = Data(headers.utf8)
    packet.append(response.body)
    connection.send(
      content: packet,
      completion: .contentProcessed { [weak self] _ in
        Task { @MainActor in self?.stop() }
      })
  }

  private func close() {
    guard !isClosed else { return }
    isClosed = true
    onClose?()
    onClose = nil
  }
}

/// Native MCP clients normally omit Origin. If one is supplied, only an
/// explicit loopback web origin is accepted, preventing DNS-rebinding from
/// turning a remote page into a local automation client.
enum MCPRequestSecurity {
  static func isAllowedOrigin(_ value: String) -> Bool {
    guard let components = URLComponents(string: value),
      components.scheme == "http" || components.scheme == "https",
      let host = components.host?.lowercased()
    else { return false }
    return host == "127.0.0.1" || host == "localhost"
  }
}

private struct MCPServerError: LocalizedError {
  var message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

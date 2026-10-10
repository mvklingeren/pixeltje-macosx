import Foundation
import PixeltjeAutomation
@preconcurrency import JavaScriptCore

/// The compatibility number exposed as `pixeltje.apiVersion` inside scripts.
public enum PixeltjeScriptAPI {
  public static let currentVersion = 1
}

public enum PixeltjeScriptErrorKind: String, Sendable {
  case setup
  case javascript
  case automation
  case cancelled
}

/// A transport-safe description of a script failure.
///
/// JavaScriptCore values never escape the private script queue. Keeping only
/// strings and source positions also makes this suitable for AppKit alerts and
/// future history or console presentation.
public struct PixeltjeScriptError: Error, LocalizedError, Equatable, Sendable {
  public var kind: PixeltjeScriptErrorKind
  public var message: String
  public var sourceName: String
  public var line: Int?
  public var column: Int?
  public var stack: String?
  public var code: String?
  public var details: [String: String]

  public init(
    kind: PixeltjeScriptErrorKind,
    message: String,
    sourceName: String,
    line: Int? = nil,
    column: Int? = nil,
    stack: String? = nil,
    code: String? = nil,
    details: [String: String] = [:]
  ) {
    self.kind = kind
    self.message = message
    self.sourceName = sourceName
    self.line = line
    self.column = column
    self.stack = stack
    self.code = code
    self.details = details
  }

  public var errorDescription: String? { message }

  /// Concise diagnostics for the File-menu runner.
  public var userFacingDescription: String {
    var location = sourceName
    if let line {
      location += ":\(line)"
      if let column { location += ":\(column)" }
    }
    var parts = ["\(location): \(message)"]
    if let code { parts.append("Code: \(code)") }
    if let stack, !stack.isEmpty { parts.append(stack) }
    return parts.joined(separator: "\n")
  }
}

public struct PixeltjeScriptResult: Equatable, Sendable {
  public var sourceName: String
  public var valueDescription: String?

  public init(sourceName: String, valueDescription: String? = nil) {
    self.sourceName = sourceName
    self.valueDescription = valueDescription
  }
}

/// Runs one trusted local JavaScript file against the semantic automation API.
///
/// Each runner is single-use. JavaScriptCore and every value it creates stay on
/// `queue`; the native bridge blocks that queue briefly while a call is
/// marshalled to the main-actor automation service. A script can observe
/// cancellation with `pixeltje.checkCancellation()`, and every native call
/// checks it automatically. JavaScriptCore has no public hard execution limit,
/// so pure JavaScript that never returns to the bridge cannot be interrupted by
/// this in-process v1 runner.
public final class PixeltjeScriptRunner: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.pixeltje.scripting", qos: .userInitiated)
  private let adapter: ScriptAutomationAdapter
  private let cancellation = ScriptCancellationToken()
  private let stateLock = NSLock()
  private var hasStarted = false

  @MainActor
  public init(
    service: any PixeltjeAutomationService,
    clientID: String = "local-script",
    scopes: Set<AutomationScope> = [.read, .edit, .jobs]
  ) {
    adapter = ScriptAutomationAdapter(
      service: service,
      requestContext: AutomationRequestContext(clientID: clientID, scopes: scopes)
    )
  }

  public func cancel() {
    cancellation.cancel()
  }

  public func run(
    source: String,
    sourceName: String = "Script.js"
  ) async throws -> PixeltjeScriptResult {
    guard claimRun() else {
      throw PixeltjeScriptError(
        kind: .setup,
        message: "A script runner can execute only one script.",
        sourceName: sourceName
      )
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          do {
            continuation.resume(returning: try execute(source: source, sourceName: sourceName))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: { [self] in
      cancel()
    }
  }

  private func claimRun() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !hasStarted else { return false }
    hasStarted = true
    return true
  }

  private func execute(source: String, sourceName: String) throws -> PixeltjeScriptResult {
    guard !cancellation.isCancelled else {
      throw cancelledError(sourceName: sourceName)
    }
    guard let context = JSContext() else {
      throw PixeltjeScriptError(
        kind: .setup,
        message: "JavaScriptCore could not create an execution context.",
        sourceName: sourceName
      )
    }

    let captured = ScriptExceptionCapture()
    context.exceptionHandler = { _, exception in
      captured.record(exception)
    }

    typealias NativeCall = @convention(block) (String, String) -> String
    let nativeCall: NativeCall = { [adapter, cancellation] method, argumentsJSON in
      if Thread.isMainThread {
        return MainActor.assumeIsolated {
          adapter.response(
            method: method,
            argumentsJSON: argumentsJSON,
            isCancelled: cancellation.isCancelled
          )
        }
      }
      return DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          adapter.response(
            method: method,
            argumentsJSON: argumentsJSON,
            isCancelled: cancellation.isCancelled
          )
        }
      }
    }
    context.setObject(nativeCall, forKeyedSubscript: "__pixeltjeNativeCall" as NSString)

    _ = context.evaluateScript(
      Self.bootstrap,
      withSourceURL: URL(string: "pixeltje-internal:///api-v1.js")!
    )
    if let exception = captured.take() {
      throw exception.error(sourceName: "Pixeltje Script API")
    }

    guard !cancellation.isCancelled else {
      throw cancelledError(sourceName: sourceName)
    }
    let value = context.evaluateScript(source, withSourceURL: Self.sourceURL(for: sourceName))
    if let exception = captured.take() {
      throw exception.error(sourceName: sourceName)
    }
    guard !cancellation.isCancelled else {
      throw cancelledError(sourceName: sourceName)
    }

    let valueDescription: String?
    if let value, !value.isUndefined, !value.isNull {
      valueDescription = value.toString()
    } else {
      valueDescription = nil
    }
    return PixeltjeScriptResult(sourceName: sourceName, valueDescription: valueDescription)
  }

  private func cancelledError(sourceName: String) -> PixeltjeScriptError {
    PixeltjeScriptError(
      kind: .cancelled,
      message: "The script was cancelled.",
      sourceName: sourceName,
      code: "scriptCancelled"
    )
  }

  private static func sourceURL(for sourceName: String) -> URL {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
    let escaped = sourceName.addingPercentEncoding(withAllowedCharacters: allowed) ?? "Script.js"
    return URL(string: "pixeltje-script:///\(escaped)")!
  }

  private static let bootstrap = #"""
    (function(nativeCall) {
      "use strict";

      function automationError(payload) {
        const error = new Error(payload.message || "Pixeltje automation failed.");
        error.name = "PixeltjeAutomationError";
        error.code = payload.code || "internalError";
        error.details = Object.freeze(payload.details || {});
        return error;
      }

      function invoke(method, argumentsValue) {
        const argumentsJSON = JSON.stringify(argumentsValue === undefined ? {} : argumentsValue);
        const envelope = JSON.parse(nativeCall(method, argumentsJSON));
        if (!envelope.ok) {
          throw automationError(envelope.error || {});
        }
        return envelope.value;
      }

      function requireVersion(version) {
        if (version !== 1) {
          const error = new Error(
            "This script requires Pixeltje scripting API " + version +
            ", but this application provides API 1."
          );
          error.name = "PixeltjeAPIVersionError";
          error.code = "unsupportedAPIVersion";
          throw error;
        }
        return true;
      }

      const documents = Object.freeze({
        list: function() { return invoke("documents.list", {}); },
        get: function(documentID) {
          return invoke("documents.get", { documentID: documentID });
        }
      });

      const layers = Object.freeze({
        list: function(documentID) {
          return invoke("layers.list", { documentID: documentID });
        },
        update: function(options) { return invoke("layers.update", options); },
        move: function(options) { return invoke("layers.move", options); }
      });

      const develop = Object.freeze({
        get: function(documentID, layerID) {
          return invoke("develop.get", { documentID: documentID, layerID: layerID });
        },
        update: function(options) { return invoke("develop.update", options); }
      });

      const history = Object.freeze({
        get: function(documentID) {
          return invoke("history.get", { documentID: documentID });
        },
        createSnapshot: function(options) {
          return invoke("history.createSnapshot", options);
        },
        restoreSnapshot: function(options) {
          return invoke("history.restoreSnapshot", options);
        }
      });

      const histogram = Object.freeze({
        get: function(documentID) {
          return invoke("histogram.get", { documentID: documentID });
        }
      });

      function jobHandle(documentID, jobID) {
        return Object.freeze({
          documentID: documentID,
          id: jobID,
          snapshot: function() {
            const jobs = invoke("jobs.list", { documentID: documentID });
            return jobs.find(function(job) { return job.id === jobID; }) || null;
          },
          cancel: function(idempotencyKey) {
            return invoke("jobs.cancel", {
              documentID: documentID,
              jobID: jobID,
              idempotencyKey: idempotencyKey
            });
          }
        });
      }

      const jobs = Object.freeze({
        list: function(documentID) {
          return invoke("jobs.list", { documentID: documentID });
        },
        cancel: function(options) { return invoke("jobs.cancel", options); },
        handle: jobHandle
      });

      const canvas = Object.freeze({
        setCrop: function(options) { return invoke("canvas.setCrop", options); },
        resize: function(options) { return invoke("canvas.resize", options); }
      });

      const api = Object.freeze({
        apiVersion: 1,
        requireVersion: requireVersion,
        checkCancellation: function() {
          return invoke("script.checkCancellation", {});
        },
        documents: documents,
        layers: layers,
        develop: develop,
        history: history,
        histogram: histogram,
        jobs: jobs,
        canvas: canvas
      });

      Object.defineProperty(globalThis, "pixeltje", {
        value: api,
        writable: false,
        configurable: false,
        enumerable: true
      });
    })(__pixeltjeNativeCall);
    delete globalThis.__pixeltjeNativeCall;
    """#
}

private final class ScriptCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

private struct CapturedScriptException {
  var message: String
  var line: Int?
  var column: Int?
  var stack: String?
  var code: String?
  var details: [String: String]

  func error(sourceName: String) -> PixeltjeScriptError {
    let kind: PixeltjeScriptErrorKind
    switch code {
    case ScriptAutomationAdapter.cancelledCode:
      kind = .cancelled
    case nil, "unsupportedAPIVersion":
      kind = .javascript
    default:
      kind = .automation
    }
    return PixeltjeScriptError(
      kind: kind,
      message: message,
      sourceName: sourceName,
      line: line,
      column: column,
      stack: stack,
      code: code,
      details: details
    )
  }
}

/// Confined to the script queue along with its JSValues.
private final class ScriptExceptionCapture {
  private var value: CapturedScriptException?

  func record(_ exception: JSValue?) {
    guard let exception else { return }
    let message = exception.forProperty("message")?.toString() ?? exception.toString()
      ?? "JavaScript execution failed."
    value = CapturedScriptException(
      message: message,
      line: positiveInteger(exception.forProperty("line")),
      column: positiveInteger(exception.forProperty("column")),
      stack: nonemptyString(exception.forProperty("stack")),
      code: nonemptyString(exception.forProperty("code")),
      details: stringDictionary(exception.forProperty("details"))
    )
  }

  func take() -> CapturedScriptException? {
    defer { value = nil }
    return value
  }

  private func positiveInteger(_ value: JSValue?) -> Int? {
    guard let value, !value.isUndefined, !value.isNull else { return nil }
    let number = Int(value.toInt32())
    return number > 0 ? number : nil
  }

  private func nonemptyString(_ value: JSValue?) -> String? {
    guard let value, !value.isUndefined, !value.isNull,
      let string = value.toString(), !string.isEmpty
    else { return nil }
    return string
  }

  private func stringDictionary(_ value: JSValue?) -> [String: String] {
    guard let object = value?.toDictionary() else { return [:] }
    var result: [String: String] = [:]
    for (key, value) in object {
      result[String(describing: key)] = String(describing: value)
    }
    return result
  }
}

/// Owns the only reference to the live automation service. No JavaScriptCore
/// object crosses this boundary.
@MainActor
private final class ScriptAutomationAdapter {
  static let cancelledCode = "scriptCancelled"

  private let service: any PixeltjeAutomationService
  private let requestContext: AutomationRequestContext

  init(service: any PixeltjeAutomationService, requestContext: AutomationRequestContext) {
    self.service = service
    self.requestContext = requestContext
  }

  func response(method: String, argumentsJSON: String, isCancelled: Bool) -> String {
    do {
      guard !isCancelled else {
        throw AutomationServiceError(
          .unsupportedOperation,
          "The script was cancelled.",
          details: ["scriptCode": Self.cancelledCode]
        )
      }
      let arguments = try parseObject(argumentsJSON)
      let value: Any
      switch method {
      case "script.checkCancellation":
        value = true
      case "documents.list":
        try requestContext.require(.read)
        value = try encodable(service.listDocuments(context: requestContext))
      case "documents.get":
        try requestContext.require(.read)
        value = try encodable(
          service.getDocument(
            id: try string("documentID", in: arguments),
            context: requestContext
          )
        )
      case "layers.list":
        try requestContext.require(.read)
        value = try encodable(
          service.listLayers(
            documentID: try string("documentID", in: arguments),
            context: requestContext
          )
        )
      case "develop.get":
        try requestContext.require(.read)
        value = try encodable(
          service.getDevelopSettings(
            documentID: try string("documentID", in: arguments),
            layerID: try string("layerID", in: arguments),
            context: requestContext
          )
        )
      case "history.get":
        try requestContext.require(.read)
        value = try encodable(
          service.getHistory(
            documentID: try string("documentID", in: arguments),
            context: requestContext
          )
        )
      case "histogram.get":
        try requestContext.require(.read)
        value = try encodable(
          service.getHistogram(
            documentID: try string("documentID", in: arguments),
            context: requestContext
          )
        )
      case "jobs.list":
        try requestContext.require(.read)
        value = try encodable(
          service.listJobs(
            documentID: try string("documentID", in: arguments),
            context: requestContext
          )
        )
      case "develop.update":
        try requestContext.require(.edit)
        value = try encodable(
          service.execute(
            .updateDevelop(try decode(AutomationDevelopPatch.self, from: arguments)),
            context: requestContext
          )
        )
      case "layers.update":
        try requestContext.require(.edit)
        value = try encodable(
          service.execute(
            .updateLayer(try decode(AutomationLayerPatch.self, from: arguments)),
            context: requestContext
          )
        )
      case "layers.move":
        try requestContext.require(.edit)
        value = try encodable(
          service.execute(
            .moveLayer(try decode(AutomationMoveLayerCommand.self, from: arguments)),
            context: requestContext
          )
        )
      case "canvas.setCrop":
        try requestContext.require(.edit)
        value = try encodable(
          service.execute(
            .setCrop(try decode(AutomationCropCommand.self, from: arguments)),
            context: requestContext
          )
        )
      case "canvas.resize":
        try requestContext.require(.edit)
        value = try encodable(
          service.execute(
            .resizeCanvas(try decode(AutomationResizeCanvasCommand.self, from: arguments)),
            context: requestContext
          )
        )
      case "history.createSnapshot":
        try requestContext.require(.edit)
        value = try encodable(
          service.execute(
            .createSnapshot(try decode(AutomationCreateSnapshotCommand.self, from: arguments)),
            context: requestContext
          )
        )
      case "history.restoreSnapshot":
        try requestContext.require(.edit)
        value = try encodable(
          service.execute(
            .restoreSnapshot(try decode(AutomationRestoreSnapshotCommand.self, from: arguments)),
            context: requestContext
          )
        )
      case "jobs.cancel":
        try requestContext.require(.jobs)
        value = try encodable(
          service.execute(
            .cancelJob(try decode(AutomationCancelJobCommand.self, from: arguments)),
            context: requestContext
          )
        )
      default:
        throw AutomationServiceError(
          .unsupportedOperation,
          "Unknown scripting operation: \(method)."
        )
      }
      return envelope(ok: value)
    } catch let error as AutomationServiceError {
      let code = error.details["scriptCode"] ?? error.code.rawValue
      return envelope(
        errorCode: code,
        message: error.message,
        details: error.details.filter { $0.key != "scriptCode" }
      )
    } catch {
      return envelope(
        errorCode: AutomationErrorCode.internalError.rawValue,
        message: error.localizedDescription,
        details: [:]
      )
    }
  }

  private func parseObject(_ json: String) throws -> [String: Any] {
    do {
      let data = Data(json.utf8)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AutomationServiceError(.invalidArgument, "Script arguments must be an object.")
      }
      return object
    } catch let error as AutomationServiceError {
      throw error
    } catch {
      throw AutomationServiceError(
        .invalidArgument,
        "Script arguments are not valid JSON: \(error.localizedDescription)"
      )
    }
  }

  private func string(_ name: String, in object: [String: Any]) throws -> String {
    guard let value = object[name] as? String, !value.isEmpty else {
      throw AutomationServiceError(.invalidArgument, "\(name) is required.")
    }
    return value
  }

  private func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
    do {
      let data = try JSONSerialization.data(withJSONObject: object)
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw AutomationServiceError(
        .invalidArgument,
        "Invalid script arguments: \(error.localizedDescription)"
      )
    }
  }

  private func encodable<T: Encodable>(_ value: T) throws -> Any {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private func envelope(ok value: Any) -> String {
    jsonString(["ok": true, "value": value])
  }

  private func envelope(
    errorCode: String,
    message: String,
    details: [String: String]
  ) -> String {
    jsonString([
      "ok": false,
      "error": ["code": errorCode, "message": message, "details": details],
    ])
  }

  private func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      return
        #"{"error":{"code":"internalError","details":{},"message":"The scripting bridge could not encode its response."},"ok":false}"#
    }
    return string
  }
}

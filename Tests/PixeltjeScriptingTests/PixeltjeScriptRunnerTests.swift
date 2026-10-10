import Foundation
import PixeltjeAutomation
import Testing

@testable import PixeltjeScripting

@MainActor
private final class ScriptStubService: PixeltjeAutomationService {
  let documentID = "00000000-0000-0000-0000-000000000001"
  let layerID = "layer-1"
  var lastCommand: AutomationCommand?
  var forcedMutationError: AutomationServiceError?

  func listDocuments(context: AutomationRequestContext) throws -> [AutomationDocumentSummary] {
    try context.require(.read)
    return [documentSummary]
  }

  func getDocument(
    id: String,
    context: AutomationRequestContext
  ) throws -> AutomationDocumentSnapshot {
    try context.require(.read)
    guard id == documentID else {
      throw AutomationServiceError(.documentNotFound, "Unknown test document.")
    }
    return AutomationDocumentSnapshot(
      document: documentSummary,
      activeLayerID: layerID,
      layerCount: 1,
      hasSelection: true,
      workingColorSpace: "Extended Linear Display P3",
      render: AutomationRenderSnapshot(state: "ready", message: "Ready", isBusy: false)
    )
  }

  func listLayers(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> [AutomationLayerSnapshot] {
    try context.require(.read)
    return [
      AutomationLayerSnapshot(
        id: layerID,
        name: "Test layer",
        kind: "group",
        parentID: nil,
        depth: 0,
        isEnabled: true,
        isEffectivelyEnabled: true,
        isLocked: false,
        zOrder: 1,
        blendMode: "normal",
        opacity: 1,
        fill: 1,
        frame: nil,
        sourceFilename: nil,
        supportsDevelop: true,
        adjustmentMaskCount: 0,
        hasLayerMask: false
      )
    ]
  }

  func getDevelopSettings(
    documentID: String,
    layerID: String,
    context: AutomationRequestContext
  ) throws -> AutomationDevelopSnapshot {
    try context.require(.read)
    return AutomationDevelopSnapshot(
      documentID: documentID,
      layerID: layerID,
      contentRevision: 3,
      layerKind: "image",
      rawFloats: [:],
      rawBooleans: [:],
      supportedRawFloats: [],
      supportedRawBooleans: [],
      basicTone: ["contrast": 0]
    )
  }

  func getHistory(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> AutomationHistorySnapshot {
    try context.require(.read)
    return AutomationHistorySnapshot(
      documentID: documentID,
      contentRevision: 3,
      canUndo: true,
      canRedo: false,
      steps: [],
      snapshots: []
    )
  }

  func getHistogram(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> AutomationHistogramSnapshot {
    try context.require(.read)
    return AutomationHistogramSnapshot(
      documentID: documentID,
      contentRevision: 3,
      isAvailable: true,
      isAnalyzing: false,
      sampleCount: 1,
      red: [1],
      green: [1],
      blue: [1],
      luminance: [1]
    )
  }

  func listJobs(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> [AutomationJobSnapshot] {
    try context.require(.read)
    return [
      AutomationJobSnapshot(
        id: "job-1",
        filename: "output.tiff",
        presetName: "TIFF",
        summary: "Export",
        queuedAt: Date(timeIntervalSince1970: 0),
        state: "running",
        progress: 0.5,
        message: "Rendering"
      )
    ]
  }

  func execute(
    _ command: AutomationCommand,
    context: AutomationRequestContext
  ) throws -> AutomationMutationReceipt {
    if let forcedMutationError { throw forcedMutationError }
    lastCommand = command
    return AutomationMutationReceipt(
      documentID: documentID,
      beforeRevision: 3,
      afterRevision: 4,
      historyStepID: "step-4",
      changed: true
    )
  }

  private var documentSummary: AutomationDocumentSummary {
    AutomationDocumentSummary(
      id: documentID,
      name: "Test document",
      isEdited: false,
      contentRevision: 3,
      canvas: AutomationCanvasSnapshot(width: 1920, height: 1080)
    )
  }
}

@MainActor
@Test func scriptAPIVersionGlobalAndReadSurfaceAreStable() async throws {
  let service = ScriptStubService()
  let runner = PixeltjeScriptRunner(service: service, scopes: [.read])
  let result = try await runner.run(
    source: """
      pixeltje.requireVersion(1);
      if (!Object.isFrozen(pixeltje) || !Object.isFrozen(pixeltje.documents)) {
        throw new Error("The API is mutable");
      }
      if (typeof globalThis.__pixeltjeNativeCall !== "undefined") {
        throw new Error("The native bridge leaked");
      }
      const document = pixeltje.documents.list()[0];
      const snapshot = pixeltje.documents.get(document.id);
      const layers = pixeltje.layers.list(document.id);
      const develop = pixeltje.develop.get(document.id, layers[0].id);
      const history = pixeltje.history.get(document.id);
      const histogram = pixeltje.histogram.get(document.id);
      const jobs = pixeltje.jobs.list(document.id);
      [snapshot.document.name, develop.layerKind, history.canUndo,
        histogram.sampleCount, jobs[0].state].join("|");
      """,
    sourceName: "reads.js"
  )

  #expect(PixeltjeScriptAPI.currentVersion == 1)
  #expect(result.valueDescription == "Test document|image|true|1|running")
}

@MainActor
@Test func scriptMutationMapsToTypedCommandAndReturnsReceipt() async throws {
  let service = ScriptStubService()
  let runner = PixeltjeScriptRunner(service: service, scopes: [.edit])
  let result = try await runner.run(
    source: """
      const receipt = pixeltje.layers.update({
        documentID: "\(service.documentID)",
        layerID: "\(service.layerID)",
        expectedRevision: 3,
        idempotencyKey: "script-layer-1",
        opacity: 0.4,
        fill: 0.75
      });
      receipt.afterRevision;
      """,
    sourceName: "mutate.js"
  )

  #expect(result.valueDescription == "4")
  guard case .updateLayer(let patch) = service.lastCommand else {
    Issue.record("Expected an updateLayer command")
    return
  }
  #expect(patch.documentID == service.documentID)
  #expect(patch.layerID == service.layerID)
  #expect(patch.idempotencyKey == "script-layer-1")
  #expect(patch.opacity == 0.4)
  #expect(patch.fill == 0.75)
}

@MainActor
@Test func scriptScopesRejectMutationBeforeItReachesTheService() async throws {
  let service = ScriptStubService()
  let runner = PixeltjeScriptRunner(service: service, scopes: [.read])
  do {
    _ = try await runner.run(
      source: """
        pixeltje.layers.update({
          documentID: "\(service.documentID)", layerID: "\(service.layerID)",
          expectedRevision: 3, idempotencyKey: "denied", opacity: 0.5
        });
        """,
      sourceName: "scope.js"
    )
    Issue.record("Expected accessDenied")
  } catch let error as PixeltjeScriptError {
    #expect(error.kind == .automation)
    #expect(error.code == AutomationErrorCode.accessDenied.rawValue)
    #expect(service.lastCommand == nil)
  }
}

@MainActor
@Test func staleRevisionDetailsBecomeAJavaScriptAutomationError() async throws {
  let service = ScriptStubService()
  service.forcedMutationError = AutomationServiceError(
    .staleRevision,
    "The document changed.",
    details: ["expectedRevision": "3", "currentRevision": "4"]
  )
  let runner = PixeltjeScriptRunner(service: service, scopes: [.edit])
  do {
    _ = try await runner.run(
      source: """
        pixeltje.canvas.resize({
          documentID: "\(service.documentID)", expectedRevision: 3,
          idempotencyKey: "resize-1", width: 800, height: 600, anchor: "center"
        });
        """,
      sourceName: "stale.js"
    )
    Issue.record("Expected staleRevision")
  } catch let error as PixeltjeScriptError {
    #expect(error.code == AutomationErrorCode.staleRevision.rawValue)
    #expect(error.details["currentRevision"] == "4")
    #expect(error.sourceName == "stale.js")
  }
}

@MainActor
@Test func jobHandlesUseTheJobsScopeForCancellation() async throws {
  let service = ScriptStubService()
  let runner = PixeltjeScriptRunner(service: service, scopes: [.read, .jobs])
  let result = try await runner.run(
    source: """
      const job = pixeltje.jobs.handle("\(service.documentID)", "job-1");
      if (job.snapshot().state !== "running") throw new Error("Missing job");
      job.cancel("cancel-1").changed;
      """,
    sourceName: "jobs.js"
  )

  #expect(result.valueDescription == "true")
  guard case .cancelJob(let command) = service.lastCommand else {
    Issue.record("Expected a cancelJob command")
    return
  }
  #expect(command.jobID == "job-1")
  #expect(command.idempotencyKey == "cancel-1")
}

@MainActor
@Test func invalidArgumentsAndAPIVersionFailuresAreDiagnosable() async throws {
  let service = ScriptStubService()
  let invalidRunner = PixeltjeScriptRunner(service: service, scopes: [.read])
  do {
    _ = try await invalidRunner.run(
      source: "pixeltje.documents.get();",
      sourceName: "invalid.js"
    )
    Issue.record("Expected invalidArgument")
  } catch let error as PixeltjeScriptError {
    #expect(error.code == AutomationErrorCode.invalidArgument.rawValue)
    #expect(error.message.contains("documentID"))
  }

  let versionRunner = PixeltjeScriptRunner(service: service, scopes: [])
  do {
    _ = try await versionRunner.run(
      source: "pixeltje.requireVersion(2);",
      sourceName: "version.js"
    )
    Issue.record("Expected unsupportedAPIVersion")
  } catch let error as PixeltjeScriptError {
    #expect(error.kind == .javascript)
    #expect(error.code == "unsupportedAPIVersion")
  }
}

@MainActor
@Test func JavaScriptExceptionsCarryFilenameAndStack() async throws {
  let runner = PixeltjeScriptRunner(service: ScriptStubService(), scopes: [])
  do {
    _ = try await runner.run(
      source: """
        const value = 1;
        throw new Error("deliberate failure");
        """,
      sourceName: "failure.js"
    )
    Issue.record("Expected a JavaScript exception")
  } catch let error as PixeltjeScriptError {
    #expect(error.kind == .javascript)
    #expect(error.message == "deliberate failure")
    #expect(error.sourceName == "failure.js")
    #expect(error.stack?.contains("failure.js") == true)
  }
}

@MainActor
@Test func cancellationBeforeExecutionReturnsACancelledScriptError() async throws {
  let runner = PixeltjeScriptRunner(service: ScriptStubService(), scopes: [])
  runner.cancel()
  do {
    _ = try await runner.run(
      source: "pixeltje.checkCancellation();",
      sourceName: "cancel.js"
    )
    Issue.record("Expected cancellation")
  } catch let error as PixeltjeScriptError {
    #expect(error.kind == .cancelled)
    #expect(error.code == "scriptCancelled")
  }
}

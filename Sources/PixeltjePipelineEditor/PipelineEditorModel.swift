import AppKit
import AVFoundation
import Combine
import Foundation
import PixeltjePipelineComfyUIConverter
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineFLUX2Runtime
import PixeltjePipelineSDXSRuntime
import PixeltjePipelineStableAudioRuntime
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineResourceLinking
import PixeltjePipelineTextRuntime
import PixeltjePipelineSegmentationRuntime
import PixeltjeModelDesign
import PixeltjePipelineTrainingRuntime

enum PipelineEditorSelection: Equatable {
  case node(PipelineNodeID)
  case connection(PipelineConnectionID)
}

struct PipelineCompletedResult: Identifiable {
  let call: Int
  let seed: UInt64?
  let durationSeconds: TimeInterval
  let outputURL: URL?
  let text: String?
  let imagePreviewData: Data?
  let summary: String

  var id: Int { call }

  var durationLabel: String { Self.durationLabel(seconds: durationSeconds) }

  static func durationLabel(seconds: TimeInterval) -> String {
    if seconds >= 1 {
      return "\(seconds.formatted(.number.precision(.fractionLength(1))))sec"
    }
    return "\(Int((seconds * 1_000).rounded()))ms"
  }
}

enum PipelineEditorExecutionState {
  case idle
  case running
  case pausing
  case paused
  case cancelling
}

actor PipelineExecutionPauseGate {
  private var isPaused = false
  private var isFinishing = false

  func pause() { if !isFinishing { isPaused = true } }
  func resume() { isPaused = false }
  func finishCurrentCall() {
    isFinishing = true
    isPaused = false
  }

  func checkpoint(onPaused: @Sendable () async -> Void) async throws {
    try Task.checkCancellation()
    guard isPaused else { return }
    await onPaused()
    while isPaused {
      try await Task.sleep(for: .milliseconds(100))
    }
    try Task.checkCancellation()
  }
}

/// Main-actor bookkeeping for one direct live preview run. The runner, the
/// preview renderers and the editor share only these thread-safe boxes.
@MainActor
private final class PipelineLiveRun {
  let executionID: UUID
  let loopNodeID: PipelineNodeID
  let trackpadNodeID: PipelineNodeID?
  let shaderMetalRenderID: PipelineNodeID?
  let source: PipelineLivePreviewSource
  let controls = PipelineLiveRunControls()
  let telemetry = PipelineLiveRunTelemetry()
  let progress = PipelineEditorProgressBuffer()
  var samplerTask: Task<Void, Never>?
  var reportedCall = 0

  init(executionID: UUID, loopNodeID: PipelineNodeID,
    trackpadNodeID: PipelineNodeID?, shaderMetalRenderID: PipelineNodeID?,
    source: PipelineLivePreviewSource) {
    self.executionID = executionID
    self.loopNodeID = loopNodeID
    self.trackpadNodeID = trackpadNodeID
    self.shaderMetalRenderID = shaderMetalRenderID
    self.source = source
  }
}

@MainActor
final class PipelineEditorModel: ObservableObject {
  private static let defaultPrompt = "A tiny red sailboat crossing a calm blue lake at sunrise"
  @Published private(set) var document: PipelineDocument
  @Published private(set) var fileURL: URL?
  @Published private(set) var isDirty = false
  @Published private(set) var validationReport = PipelineValidationReport()
  @Published private(set) var shaderValidationPending = false
  @Published private(set) var engineSnapshot: PipelineEngineSnapshot?
  @Published private(set) var statusMessage = "Starting Core AI pipeline engine…"
  @Published private(set) var modelPackageURL: URL
  @Published private(set) var nativePackageURLsByID: [String: URL] = [:]
  @Published private(set) var selectedNativePackageID: String?
  @Published private(set) var packageInspection: PipelinePackageInspectionReport?
  @Published private(set) var executionProfile: PipelineExecutionProfile?
  @Published private(set) var executionState: PipelineEditorExecutionState = .idle {
    didSet { syncLiveRunControls() }
  }
  @Published private(set) var executionProgress: PipelineExecutionProgress?
  @Published private(set) var traceRecords: [PipelineTraceRecord] = []
  @Published private(set) var traceLogURL: URL?
  @Published private(set) var traceError: String?
  @Published private(set) var activeNodeIDs: Set<PipelineNodeID> = []
  @Published private(set) var glowingNodeIDs: Set<PipelineNodeID> = []
  @Published private(set) var activatedNodeIDs: Set<PipelineNodeID> = []
  @Published private(set) var lastNodeExecutionSeconds: [PipelineNodeID: TimeInterval] = [:]
  @Published private(set) var generatedPreview: NSImage?
  @Published private(set) var nodeImagePreviews: [PipelineNodeID: NSImage] = [:]
  @Published private(set) var cacheAssetImages: [PipelineNodeID: [String: NSImage]] = [:]
  @Published private(set) var cacheAssetAudioURLs: [PipelineNodeID: [String: URL]] = [:]
  private var liveAudioData: [URL: Data] = [:]
  private var liveAudioPlayers: [AVAudioPlayer] = []
  private var liveAudioVoices: PipelineLiveAudioVoices?
  /// Set when looping sound failed once in this run, so it is not retried
  /// on every frame.
  private var liveAudioVoicesFailed = false
  @Published private(set) var nodeTextValues: [PipelineNodeID: String] = [:]
  /// Size of the live preview's newest frame, set once a frame exists. The
  /// frames themselves reach preview views through `livePreview`.
  @Published private(set) var liveMetalPreviewSize: CGSize?
  @Published private(set) var liveMetalPreviewNodeID: PipelineNodeID?
  let livePreview = PipelineLivePreviewPresenter()
  @Published private(set) var nodeVideoPreviewURLs: [PipelineNodeID: URL] = [:]
  private var temporaryVideoPreviewURLs: Set<URL> = []
  @Published private(set) var nodeImageDimensions: [PipelineNodeID: CGSize] = [:]
  private var nodePreviewTaskIDs: [PipelineNodeID: UUID] = [:]
  private var pendingNodePreviews: [PipelineNodeID: PipelineGeneratedImage] = [:]
  @Published private(set) var fullScreenPreviewImage: NSImage?
  private var fullScreenPreviewNodeID: PipelineNodeID? {
    didSet { syncLiveRunControls() }
  }
  private var fullScreenPreviewTask: Task<Void, Never>?
  private var fullScreenPreviewRequestID: UUID?
  private var pendingFullScreenPreview: (nodeID: PipelineNodeID, image: PipelineGeneratedImage)?
  private var latestMetalPreview: (nodeID: PipelineNodeID, image: PipelineGeneratedImage)?
  private var latestMetalFullPreview: (nodeID: PipelineNodeID, image: PipelineGeneratedImage)?
  @Published private(set) var generatedText = ""
  @Published private(set) var generatedOutputURL: URL?
  @Published private(set) var currentStateJSON: String?
  @Published private(set) var trackpadMaskPreview: NSImage?
  @Published private(set) var trackpadFocus = "Open scene"
  private var currentInteractionMasks: [PipelineLabeledMask] = []
  private var interactionPreviews: [NSImage?] = []
  @Published private(set) var currentScenePlan: PipelineScenePlan?
  @Published private(set) var completedResults: [PipelineCompletedResult] = []
  @Published private(set) var selectedResultCall: Int?
  @Published private(set) var selectedCompletedPreview: NSImage?
  @Published private(set) var currentCall = 0
  @Published private(set) var currentSeed: UInt64?
  @Published private(set) var activeCallLimit: Int? = 1
  @Published private(set) var activeRepeatLength: Int?
  @Published private(set) var autoPausedLoopNodeID: PipelineNodeID? {
    didSet { syncLiveRunControls() }
  }
  @Published private(set) var selectedImageURLs: [PipelineNodeID: URL] = [:]
  @Published private(set) var selection: PipelineEditorSelection?
  @Published private(set) var isNodeLibraryVisible = true
  @Published private(set) var isInspectorVisible = true
  @Published private(set) var undoStateRevision = 0
  @Published private(set) var graphViewportSize = CGSize.zero

  @Published var prompt = defaultPrompt
  @Published var negativePrompt = ""
  @Published var seedText = "0"
  @Published var steps = 8
  @Published var guidance = 1.0
  @Published var systemPrompt = CoreAITextPipelineFamily.defaultSystemPrompt
  @Published var maximumResponseTokens = 256
  @Published var temperature = 0.7
  @Published var topK = 40

  private let engine: PixeltjePipelineEngine?
  let outputDirectoryURL: URL
  let trainingOutputDirectoryURL: URL
  private(set) var trainingPythonURL: URL?
  var requestTrainingPython: (() -> Void)?
  private var executionProfileTask: Task<Void, Never>?
  private var validationTask: Task<Void, Never>?
  private var packageInspectionTask: Task<Void, Never>?
  private var packageLinkTask: Task<Void, Never>?
  private var activePackageLinkID: UUID?
  private var executionTask: Task<Void, Never>?
  private var executionPauseGate: PipelineExecutionPauseGate?
  private var previewTask: Task<Void, Never>?
  private var activePreviewID: UUID?
  private var lastPreviewStartedAt = Date.distantPast
  private var continueRepeating = false {
    didSet { syncLiveRunControls() }
  }
  private var activeExecutionID: UUID?
  private var cachedAssetPreviewFingerprints: [PipelineNodeID: String] = [:]
  private var cacheClearTask: Task<Void, Never>?
  private var trackpadEngagedAtRunIndex: [PipelineNodeID: Int] = [:] {
    didSet { syncLiveRunControls() }
  }
  private var trackpadActionCounts: [PipelineNodeID: Int] = [:] {
    didSet { syncLiveRunControls() }
  }
  private var trackpadSecondaryActionCounts: [PipelineNodeID: Int] = [:] {
    didSet { syncLiveRunControls() }
  }
  /// Full-screen GPU look follows the pointer without editing the workflow.
  private var previewLookPosition: (nodeID: PipelineNodeID, x: Double, y: Double)?
  @Published private(set) var directionPadX = 0.0
  @Published private(set) var directionPadY = 0.0
  @Published private(set) var directionPadKeys = 0
  private var directionKeys: Set<String> = []
  private var liveGPUProgramPointerRevision: UInt64 = 0
  private var nodeGlowTasks: [PipelineNodeID: Task<Void, Never>] = [:]
  private var performanceLog: PipelineEditorPerformanceLog?
  private var liveRun: PipelineLiveRun?
  private var viewportScrollEndTask: Task<Void, Never>?
  private var trackpadArtPreviewTask: Task<Void, Never>?
  private let editorUndoManager = UndoManager()
  let newWorkflowSettings: PipelineNewWorkflowSettings
  private var newWorkflowSourceURL: URL?
  private var cleanDocument: PipelineDocument?
  private var interactiveEdit: InteractiveEdit?

  private struct GraphState {
    var document: PipelineDocument
    var selectedImageURLs: [PipelineNodeID: URL]
  }

  private enum ExecutionSeedSource {
    case fixed(UInt64)
    case random
  }

  private struct InteractiveEdit {
    var key: String
    var actionName: String
    var before: GraphState
  }

  init(newWorkflowSettings: PipelineNewWorkflowSettings) {
    self.newWorkflowSettings = newWorkflowSettings
    let initialWorkflow = Result { try newWorkflowSettings.makeNewDocument() }
    document = (try? initialWorkflow.get())
      ?? (try? newWorkflowSettings.makeBundledNewDocument())
      ?? PipelineDocument(
        id: PipelineID(rawValue: UUID().uuidString), name: "Untitled",
        mode: .generic, nodes: [], connections: [])
    newWorkflowSourceURL = (try? initialWorkflow.get()) == nil
      ? nil : (try? newWorkflowSettings.selectedWorkflowURL())
    modelPackageURL = ZImagePipelineFamily.defaultPackageURL()
    outputDirectoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixeltjePipelineEditor", isDirectory: true)
      .appendingPathComponent("Outputs", isDirectory: true)
    trainingOutputDirectoryURL = (FileManager.default.urls(
      for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser)
      .appendingPathComponent("Pixeltje/Model Runs", isDirectory: true)
    trainingPythonURL = UserDefaults.standard.string(forKey: "PipelineEditor.trainingPython")
      .map { URL(fileURLWithPath: $0) }
    do {
      let fluxRunner = FLUX2KleinPipelineRunner()
      let flux9BRunner = FLUX2Klein9BSplitRunner()
      let sdxsRunner = SDXSPipelineRunner()
      let stableAudioRunner = StableAudio3Runner()
      let textRunner = CoreAITextPipelineRunner()
      let sam31Runner = SAM31PipelineRunner()
      let trainingWorker = ModelTrainingWorker()
      engine = try PixeltjePipelineEngine.makeDefault(
        persistentAssetCacheDirectory: (FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask).first
          ?? FileManager.default.homeDirectoryForCurrentUser)
          .appendingPathComponent("Pixeltje/Pipeline Asset Cache", isDirectory: true),
        additionalNodeDescriptors: [
          FLUX2KleinPipelineFamily.makeCompositeNodeDescriptor(),
          FLUX2Klein9BSplitFamily.descriptor(),
          SDXSPipelineFamily.descriptor(),
          StableAudio3Family.descriptor(),
          CoreAITextPipelineFamily.makeCompositeNodeDescriptor(),
          SAM31PipelineFamily.descriptor(),
        ],
        additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors()
          + [FLUX2KleinPipelineFamily.makeNodeExecutor(runner: fluxRunner),
            FLUX2Klein9BSplitFamily.executor(runner: flux9BRunner),
            SDXSPipelineFamily.executor(runner: sdxsRunner),
            StableAudio3Family.executor(runner: stableAudioRunner),
            CoreAITextPipelineFamily.makeNodeExecutor(runner: textRunner),
            SAM31PipelineFamily.executor(runner: sam31Runner),
            ModelTrainingRuntime.executor(worker: trainingWorker)])
    } catch {
      engine = nil
      statusMessage = error.localizedDescription
    }
    cleanDocument = document
    refreshEngineAndValidation()
    refreshExecutionProfile(resetPackageURL: true)
    if case .failure(let error) = initialWorkflow {
      statusMessage = "Could not load the selected New workflow: \(error.localizedDescription)"
    }
  }

  var displayName: String {
    fileURL?.deletingPathExtension().deletingPathExtension().lastPathComponent
      ?? document.name
  }

  var windowTitle: String {
    "\(displayName)\(isDirty ? " — Edited" : "") — Pixeltje Pipeline"
  }

  var canRun: Bool {
    runUnavailableReason == nil
  }

  var runUnavailableReason: String? {
    guard engine != nil else { return "The pipeline engine is unavailable." }
    guard !isRunning else { return "A pipeline call is already active." }
    guard validationReport.isValid else { return "Resolve the graph’s validation errors before running." }
    guard !shaderValidationPending else { return "Checking the Metal shader…" }
    guard executionProfile != nil else { return "No execution profile is available for this graph yet." }
    if isNativeNodeExecution {
      if let emptyPrompt = document.nodes.first(where: {
        guard $0.kind == .promptInput, $0.executionState == .enabled else { return false }
        guard case .string(let value)? = $0.parameters["value"] else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }) {
        return "Enter a prompt in \(emptyPrompt.title ?? emptyPrompt.id.rawValue)."
      }
    } else if document.nodes.contains(where: { $0.kind == .promptInput }),
      prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Enter a prompt before running."
    }
    guard isNativeNodeExecution || isBaseTestSetExecution || validExecutionSeed else {
      return "Enter a valid non-negative seed."
    }
    if let loopIssue { return loopIssue }
    guard let packageInspection else { return "Checking model packages and source media…" }
    guard packageInspection.isUsable else { return packageInspection.summary }
    return nil
  }

  var isRunning: Bool { executionState != .idle }
  private var isFinishingLoop: Bool {
    isRunning && activeLoop != nil && !continueRepeating
  }

  var primaryExecutionTitle: String {
    switch executionState {
    case .idle: "Run"
    case .running: isModelTraining ? "Training…" : isFinishingLoop ? "Finishing…" : "Pause"
    case .pausing: "Pausing…"
    case .paused: "Resume"
    case .cancelling: "Cancelling…"
    }
  }

  var primaryExecutionSymbol: String {
    switch executionState {
    case .idle, .paused: "play.fill"
    case .running: isModelTraining || isFinishingLoop ? "stop.fill" : "pause.fill"
    case .pausing: "pause.fill"
    case .cancelling: "stop.fill"
    }
  }

  var canUsePrimaryExecutionAction: Bool {
    switch executionState {
    case .idle: canRun
    case .running: !isModelTraining && !isFinishingLoop
    case .paused: true
    case .pausing, .cancelling: false
    }
  }

  func primaryExecutionAction() {
    switch executionState {
    case .idle: run()
    case .running: if !isModelTraining && !isFinishingLoop { pauseExecution() }
    case .paused: resumeExecution()
    case .pausing, .cancelling: break
    }
  }

  var isModelTraining: Bool {
    PipelineGraphOutputs.selectedOutputNode(in: document, registry: .pipelineEditor)?.kind
      == .modelTrain
  }

  var currentOutputDirectoryURL: URL {
    isModelTraining ? trainingOutputDirectoryURL : outputDirectoryURL
  }

  func setTrainingPython(_ url: URL) {
    trainingPythonURL = url
    UserDefaults.standard.set(url.path, forKey: "PipelineEditor.trainingPython")
    statusMessage = "Training Python: \(url.path)"
  }

  var outputSizeLabel: String {
    if isBaseTestSetExecution || isNativeNodeExecution { return "Determined by graph" }
    guard let size = executionProfile?.outputSize else { return "Unavailable" }
    return "\(size.width) × \(size.height)"
  }

  var outcomeLabel: String {
    switch executionProfile?.outputKind {
    case .image: "Image"
    case .text: "Text"
    case .video: "Video"
    case .audio: "Audio"
    case .model: "Model"
    case .some(.none), nil: "None"
    }
  }

  var isTextExecution: Bool {
    executionProfile?.outputKind == .text
  }

  var canClearOutput: Bool {
    !isRunning && (generatedPreview != nil || !generatedText.isEmpty
      || generatedOutputURL != nil || !completedResults.isEmpty || !nodeImagePreviews.isEmpty)
  }

  var selectedCompletedResult: PipelineCompletedResult? {
    if let selectedResultCall {
      return completedResults.first { $0.call == selectedResultCall }
    }
    return completedResults.last
  }

  func selectCompletedResult(call: Int?) {
    guard call == nil || completedResults.contains(where: { $0.call == call }) else { return }
    selectedResultCall = call
    selectedCompletedPreview = selectedCompletedResult?.imagePreviewData.flatMap(NSImage.init(data:))
  }

  var activeLoop: PipelineActiveLoop? {
    PipelineControlFlow.activeLoop(in: document, registry: .pipelineEditor)
  }

  var activeTimeline: PipelineActiveTimeline? {
    PipelineControlFlow.activeTimeline(in: document, registry: .pipelineEditor)
  }

  var activeCallLimitLabel: String {
    activeCallLimit.map(String.init) ?? "∞"
  }

  var activeCallProgressLabel: String { callProgressLabel(for: currentCall) }

  private func callProgressLabel(for call: Int) -> String {
    if let activeRepeatLength, call > 0 {
      let cycleCall = (call - 1) % activeRepeatLength + 1
      let cycle = (call - 1) / activeRepeatLength + 1
      return "\(cycleCall)/\(activeRepeatLength) · cycle \(cycle)"
    }
    return "\(call)/\(activeCallLimitLabel)"
  }

  func loopSettings(for nodeID: PipelineNodeID) -> PipelineLoopSettings? {
    document.nodes.first(where: { $0.id == nodeID }).flatMap(PipelineLoopSettings.init(node:))
  }

  var availableFeedback: [PipelineLoopSettings.Feedback] {
    switch executionProfile?.outputKind {
    case .text where feedbackInputIsUsed(kind: .promptInput):
      return [.textToPrompt]
    case .image:
      var options: [PipelineLoopSettings.Feedback] = []
      if feedbackInputIsUsed(kind: .imageInput) { options.append(.imageToSourceImage) }
      if hasScenePlanFeedbackPath { options.append(.scenePlanToNextView) }
      if hasScenePlanFeedbackPath && feedbackInputIsUsed(kind: .previousFrameInput) {
        options.append(.scenePlanAndImageToNextView)
      }
      if hasImageTextFeedbackPath { options.append(.imageAndTextToNextView) }
      if hasStateFeedbackPath { options.append(.stateAndImage) }
      return options
    default: return []
    }
  }

  private var hasScenePlanFeedbackPath: Bool {
    guard let output = PipelineGraphOutputs.selectedOutputNode(
      in: document, registry: .pipelineEditor),
      output.kind == .imageOutput,
      document.connections.contains(where: {
        $0.input == .init(nodeID: output.id, port: "scenePlan")
      })
    else { return false }
    return feedbackInputIsUsed(kind: .promptInput)
      && feedbackInputIsUsed(kind: .previousScenePlanInput)
      && feedbackInputIsUsed(kind: .trackpad)
  }

  private var hasImageTextFeedbackPath: Bool {
    guard let output = PipelineGraphOutputs.selectedOutputNode(
      in: document, registry: .pipelineEditor),
      output.kind == .imageOutput,
      document.connections.contains(where: {
        $0.input == .init(nodeID: output.id, port: "feedbackText")
      })
    else { return false }
    return feedbackInputIsUsed(kind: .promptInput)
      && feedbackInputIsUsed(kind: .previousFrameInput)
  }

  var initialStateJSON: String {
    if case .string(let text)? = document.nodes.first(where: { $0.kind == .stateInput })?.parameters["initialState"] { return text }
    return "{}"
  }

  var stateScalars: [String: String] {
    guard case .object(let fields)? = try? PipelineStateJSON.read(
      currentStateJSON ?? initialStateJSON, key: "") else { return [:] }
    var summary: [String: String] = [:]
    for (key, value) in fields {
      switch value {
      case .array, .object: continue
      default: summary[key] = try? PipelineStateJSON.text(value)
      }
    }
    return summary
  }

  var detectedInteractionSubjects: [String] {
    Array(Set(currentInteractionMasks.map(\.label))).sorted()
  }

  var hasStateFeedbackPath: Bool {
    guard let output = PipelineGraphOutputs.selectedOutputNode(in: document, registry: .pipelineEditor),
      output.kind == .imageOutput,
      document.connections.contains(where: { $0.input == .init(nodeID: output.id, port: "nextState") })
    else { return false }
    return feedbackInputIsUsed(kind: .stateInput) && feedbackInputIsUsed(kind: .previousFrameInput)
      && feedbackInputIsUsed(kind: .trackpad)
  }

  var canEditTrackpad: Bool {
    if isRunning, activeLoop?.settings.feedback == .stateAndImage {
      return executionState == .paused && autoPausedLoopNodeID != nil
    }
    return !isRunning || activeLoop?.settings.feedback == .scenePlanToNextView
      || activeLoop?.settings.feedback == .scenePlanAndImageToNextView
      || activeLoop?.settings.feedback == .imageAndTextToNextView
      || hasLiveProceduralTrackpadLoop
  }

  private var hasLiveProceduralTrackpadLoop: Bool {
    isNativeNodeExecution && activeLoop != nil
      && ((isBaseTestSetExecution && document.nodes.contains(where: {
        $0.kind == .imageProceduralNoise && $0.executionState == .enabled
      })) || hasTrackpadDrivenMetalNode)
      && feedbackInputIsUsed(kind: .trackpad)
  }

  private var hasTrackpadDrivenMetalNode: Bool {
    let renderIDs = Set(document.nodes.compactMap { node in
      (node.kind == .renderMetal || node.kind == .gpuProgram)
        && node.executionState == .enabled ? node.id : nil
    })
    return document.connections.contains {
      renderIDs.contains($0.input.nodeID)
        && ["state", "pointerX", "pointerY", "actionCount",
          "secondaryActionCount"].contains($0.input.port)
    }
  }

  func isGPUProgramTrackpad(_ nodeID: PipelineNodeID) -> Bool {
    guard document.nodes.contains(where: { $0.id == nodeID && $0.kind == .trackpad })
    else { return false }
    let programIDs = Set(document.nodes.compactMap { node in
      node.kind == .gpuProgram && node.executionState == .enabled ? node.id : nil
    })
    return document.connections.contains {
      $0.output.nodeID == nodeID && programIDs.contains($0.input.nodeID)
        && ["pointerX", "pointerY", "actionCount",
          "secondaryActionCount"].contains($0.input.port)
    }
  }

  func trackpadNodeID(forGPUProgramPreview nodeID: PipelineNodeID) -> PipelineNodeID? {
    let programIDs = gpuProgramIDs(forPreview: nodeID)
    return document.nodes.first { trackpad in
      trackpad.kind == .trackpad && document.connections.contains { connection in
        connection.output.nodeID == trackpad.id
          && programIDs.contains(connection.input.nodeID)
          && (connection.input.port == "pointerX" || connection.input.port == "pointerY")
      }
    }?.id
  }

  func hasMovementPad(forGPUProgramPreview nodeID: PipelineNodeID) -> Bool {
    let programIDs = gpuProgramIDs(forPreview: nodeID)
    let padIDs = Set(document.nodes.compactMap { node in
      node.kind == .directionPad && node.executionState == .enabled ? node.id : nil
    })
    return document.connections.contains { connection in
      programIDs.contains(connection.input.nodeID)
        && ["moveX", "moveY"].contains(connection.input.port)
        && padIDs.contains(connection.output.nodeID)
    }
  }

  private func gpuProgramIDs(forPreview nodeID: PipelineNodeID) -> Set<PipelineNodeID> {
    if document.nodes.contains(where: { $0.id == nodeID && $0.kind == .gpuProgram }) {
      return [nodeID]
    }
    guard document.nodes.contains(where: { $0.id == nodeID && $0.kind == .sceneSwitch })
    else { return [] }
    return Set(document.connections.compactMap { connection in
      guard connection.input.nodeID == nodeID,
        connection.input.port.hasPrefix("scene"),
        connection.output.port == "image",
        document.nodes.contains(where: {
          $0.id == connection.output.nodeID && $0.kind == .gpuProgram
        }) else { return nil }
      return connection.output.nodeID
    })
  }

  func trackpadPosition(for nodeID: PipelineNodeID) -> (x: Double, y: Double)? {
    guard let node = document.nodes.first(where: { $0.id == nodeID && $0.kind == .trackpad })
    else { return nil }
    return (Self.trackpadCoordinate("x", in: node), Self.trackpadCoordinate("y", in: node))
  }

  func plannedFocus(for nodeID: PipelineNodeID) -> String? {
    if hasStateFeedbackPath { return trackpadFocus }
    guard let currentScenePlan,
      let node = document.nodes.first(where: { $0.id == nodeID && $0.kind == .trackpad })
    else { return nil }
    let x = Self.trackpadCoordinate("x", in: node)
    let y = Self.trackpadCoordinate("y", in: node)
    return currentScenePlan.region(atX: x, y: y)?.label ?? "Open scene"
  }

  private func updateTrackpadFocus() {
    guard let pad = document.nodes.first(where: { $0.kind == .trackpad }) else { return }
    let hitNode = document.nodes.first(where: { $0.kind == .maskHitTest })
    let threshold: Float = if case .number(let value)? = hitNode?.parameters["coverageThreshold"] { Float(value) } else { 0.5 }
    let radius: Int = if case .integer(let value)? = hitNode?.parameters["radiusPixels"] { Int(value) } else { 2 }
    let index = try? PipelineMaskHitTest.index(masks: currentInteractionMasks,
      x: Self.trackpadCoordinate("x", in: pad), y: Self.trackpadCoordinate("y", in: pad),
      threshold: threshold, radius: radius)
    trackpadFocus = index.map { currentInteractionMasks[$0].label } ?? "Open scene"
    trackpadMaskPreview = index.flatMap { interactionPreviews.indices.contains($0) ? interactionPreviews[$0] : nil }
  }

  func resetState() {
    guard !isRunning else { return }
    currentStateJSON = nil
    currentInteractionMasks = []
    interactionPreviews = []
    trackpadMaskPreview = nil
    trackpadFocus = "Open scene"
    for node in document.nodes where node.kind == .trackpad { nodeImagePreviews[node.id] = nil }
    statusMessage = "State reset. Run to begin from Initial State."
  }

  func loadState() {
    guard !isRunning else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = "Choose a saved .state.json checkpoint. Run recreates its scene with the saved score."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard size <= PipelineStateJSON.maximumBytes else {
        throw PipelineEditorError.stateCheckpointTooLarge
      }
      let text = try PipelineStateJSON.canonicalObject(String(contentsOf: url, encoding: .utf8))
      resetState()
      currentStateJSON = text
      statusMessage = "State loaded. Run to recreate the scene and continue."
    } catch { statusMessage = "Could not load state: \(error.localizedDescription)" }
  }

  private static func trackpadCoordinate(_ name: String, in node: PipelineNode) -> Double {
    switch node.parameters[name] {
    case .number(let value) where value.isFinite: return min(max(value, 0), 1)
    case .integer(let value): return min(max(Double(value), 0), 1)
    default: return 0.5
    }
  }

  private func feedbackInputIsUsed(kind: PipelineNodeKind) -> Bool {
    let candidates = document.nodes.filter { node in
      guard node.kind == kind, node.executionState == .enabled else { return false }
      if kind == .imageInput {
        guard case .string(let name)? = node.parameters["sourceName"] else { return false }
        return !name.isEmpty
      }
      return true
    }
    guard candidates.count == 1, let input = candidates.first,
      let output = PipelineGraphOutputs.selectedOutputNode(
        in: document, registry: .pipelineEditor)
    else { return false }
    var seen: Set<PipelineNodeID> = []
    var pending = [input.id]
    while let next = pending.popLast() {
      if next == output.id { return true }
      guard seen.insert(next).inserted else { continue }
      pending.append(contentsOf: document.connections.filter {
        $0.output.nodeID == next
      }.map(\.input.nodeID))
    }
    return false
  }

  var loopIssue: String? {
    if let loop = activeLoop, loop.settings.feedback == .stateAndImage, !loop.settings.autoPause {
      return "State feedback requires Auto pause so each turn consumes one committed action."
    }
    if let activeLoop, let feedback = activeLoop.settings.feedback,
      !availableFeedback.contains(feedback) {
      return "The selected feedback needs a matching output and input node."
    }
    if let incrementingLoop = document.nodes.first(where: {
      $0.kind == .controlLoop && $0.executionState == .enabled
        && PipelineLoopSettings(node: $0)?.seedStrategy == .increment
    }) {
      guard let outputID = PipelineGraphOutputs.selectedOutputNode(
        in: document, registry: .pipelineEditor)?.id
      else { return "Increment Seed needs a selected output." }
      guard let seedID = PipelineControlFlow.incrementSeedNodeID(
        in: document, loopNodeID: incrementingLoop.id, outputNodeID: outputID)
      else {
        return "Connect Loop’s Increment Seed port to a Seed node that feeds the selected output."
      }
      guard seedSource(for: seedID) != nil else {
        return "The connected Seed needs Fixed or Random mode and a valid seed value."
      }
    }
    return nil
  }

  func stopLoopAfterCurrentCall() {
    guard isRunning, activeLoop != nil, executionState != .cancelling,
      continueRepeating else { return }
    continueRepeating = false
    autoPausedLoopNodeID = nil
    if executionState == .paused || executionState == .pausing {
      executionState = .running
    }
    if let executionPauseGate {
      Task { await executionPauseGate.finishCurrentCall() }
    }
    statusMessage = "Loop stopped; finishing the current call."
  }

  func canStopLoop(_ nodeID: PipelineNodeID) -> Bool {
    isRunning && executionState != .cancelling && continueRepeating
      && activeLoop?.loopNodeID == nodeID
  }

  func setLoopMaxCalls(_ value: Int?, for nodeID: PipelineNodeID) {
    guard !isRunning,
      let index = document.nodes.firstIndex(where: {
        $0.id == nodeID && $0.kind == .controlLoop
      }) else { return }
    let stored = PipelineValue.integer(Int64(value ?? -1))
    guard document.nodes[index].parameters["maxCalls"] != stored
      || (value == nil && document.nodes[index].parameters["autoRepeat"] == .boolean(true))
    else { return }
    performGraphMutation(actionName: "Change Loop max calls") { state in
      state.document.nodes[index].parameters["maxCalls"] = stored
      if value == nil { state.document.nodes[index].parameters["autoRepeat"] = .boolean(false) }
    }
  }

  func setLoopAutoRepeat(_ enabled: Bool, for nodeID: PipelineNodeID) {
    guard !enabled || loopSettings(for: nodeID)?.maxCalls != nil else { return }
    setLoopParameter(.boolean(enabled), named: "autoRepeat", for: nodeID)
  }

  func setLoopDelay(_ milliseconds: Int, for nodeID: PipelineNodeID) {
    setLoopParameter(.integer(Int64(milliseconds)), named: "delayMilliseconds", for: nodeID)
  }

  func setLoopLimitHz(_ hz: Int?, for nodeID: PipelineNodeID) {
    setLoopParameter(.integer(Int64(hz ?? 0)), named: "limitHz", for: nodeID)
  }

  func setLoopAutoPause(_ enabled: Bool, for nodeID: PipelineNodeID) {
    if !enabled, activeLoop?.settings.feedback == .stateAndImage { return }
    guard executionState != .cancelling,
      let index = document.nodes.firstIndex(where: {
        $0.id == nodeID && $0.kind == .controlLoop
      }), document.nodes[index].parameters["autoPause"] != .boolean(enabled)
    else { return }
    performGraphMutation(actionName: "Change Loop auto pause") { state in
      state.document.nodes[index].parameters["autoPause"] = .boolean(enabled)
    }
    if !enabled, autoPausedLoopNodeID == nodeID {
      if executionState == .paused {
        resumeExecution()
      } else if executionState == .pausing {
        autoPausedLoopNodeID = nil
        executionState = .running
        statusMessage = "Resuming pipeline…"
        if let executionPauseGate {
          Task { await executionPauseGate.resume() }
        }
      }
    }
  }

  func canProceedLoop(_ nodeID: PipelineNodeID) -> Bool {
    executionState == .paused && autoPausedLoopNodeID == nodeID
  }

  func proceedLoop(_ nodeID: PipelineNodeID) {
    guard canProceedLoop(nodeID) else { return }
    resumeExecution()
  }

  func setLoopSeedStrategy(
    _ value: PipelineLoopSettings.SeedStrategy, for nodeID: PipelineNodeID
  ) {
    setLoopParameter(.string(value.rawValue), named: "seedStrategy", for: nodeID)
  }

  func setLoopFeedback(
    _ value: PipelineLoopSettings.Feedback?, for nodeID: PipelineNodeID
  ) {
    guard value == nil || availableFeedback.contains(value!) else { return }
    setLoopParameter(.string(value?.rawValue ?? "none"), named: "feedback", for: nodeID)
  }

  private func setLoopParameter(
    _ value: PipelineValue, named name: String, for nodeID: PipelineNodeID
  ) {
    guard !isRunning,
      let index = document.nodes.firstIndex(where: {
        $0.id == nodeID && $0.kind == .controlLoop
      }), document.nodes[index].parameters[name] != value
    else { return }
    performGraphMutation(actionName: "Change Loop \(name)") { state in
      state.document.nodes[index].parameters[name] = value
    }
  }

  var isBaseTestSetExecution: Bool {
    isNativeNodeExecution && nativePackageIDs.isEmpty
      && !document.nodes.contains(where: { $0.kind == .promptInput })
  }

  var isNativeNodeExecution: Bool {
    document.requirements.familyABIs.isEmpty
  }

  var nativePackageIDs: [String] {
    var ids = Set(document.nodes.flatMap { node in
      node.resources.values.compactMap(\.linkedReference).map(\.packageID)
    })
    if document.nodes.contains(where: {
      $0.kind == FLUX2KleinPipelineFamily.compositeNodeKind
    }) {
      ids.insert(FLUX2KleinPipelineFamily.packageID)
    }
    if document.nodes.contains(where: { $0.kind == FLUX2Klein9BSplitFamily.nodeKind }) {
      ids.insert(FLUX2Klein9BSplitFamily.packageID)
    }
    if document.nodes.contains(where: { $0.kind == SDXSPipelineFamily.nodeKind }) {
      ids.insert(SDXSPipelineFamily.packageID)
    }
    if document.nodes.contains(where: { $0.kind == StableAudio3Family.nodeKind }) {
      ids.insert(StableAudio3Family.packageID)
    }
    if document.nodes.contains(where: { $0.kind == .zImageGenerate }) {
      ids.insert(ZImagePipelineFamily.packageID)
    }
    if document.nodes.contains(where: {
      $0.kind == CoreAITextPipelineFamily.compositeNodeKind
        && $0.resources["model"]?.linkedReference == nil
    }) {
      ids.insert("coreai.text.unlinked")
    }
    if document.nodes.contains(where: {
      $0.kind == .coreAIImageClassifier
        && $0.resources["model"]?.linkedReference == nil
    }) {
      ids.insert(PipelineImageClassifierPackage.unlinkedPackageID)
    }
    return ids.sorted()
  }

  var modelPackageNodes: [PipelineNode] {
    guard isNativeNodeExecution else { return [] }
    return document.nodes.filter { packageID(for: $0) != nil }
  }

  func packageID(for node: PipelineNode) -> String? {
    switch node.kind {
    case FLUX2KleinPipelineFamily.compositeNodeKind:
      return FLUX2KleinPipelineFamily.packageID
    case FLUX2Klein9BSplitFamily.nodeKind:
      return FLUX2Klein9BSplitFamily.packageID
    case SDXSPipelineFamily.nodeKind:
      return SDXSPipelineFamily.packageID
    case StableAudio3Family.nodeKind:
      return StableAudio3Family.packageID
    case .zImageGenerate:
      return ZImagePipelineFamily.packageID
    case SAM31PipelineFamily.nodeKind:
      return SAM31PipelineFamily.packageID
    case CoreAITextPipelineFamily.compositeNodeKind:
      return node.resources["model"]?.linkedReference?.packageID
        ?? "coreai.text.unlinked"
    case .coreAIImageClassifier:
      return node.resources["model"]?.linkedReference?.packageID
        ?? PipelineImageClassifierPackage.unlinkedPackageID
    default:
      let ids = Set(node.resources.values.compactMap(\.linkedReference).map(\.packageID))
      return ids.count == 1 ? ids.first : nil
    }
  }

  func packageURL(for node: PipelineNode) -> URL? {
    guard let packageID = packageID(for: node) else { return nil }
    return nativePackageURLsByID[packageID] ?? defaultPackageURL(for: packageID)
  }

  func displayName(forPackageID packageID: String) -> String {
    switch packageID {
    case FLUX2KleinPipelineFamily.packageID: "FLUX.2 Klein"
    case FLUX2Klein9BSplitFamily.packageID: "FLUX.2 Klein 9B FP8"
    case SDXSPipelineFamily.packageID: "SDXS 512"
    case StableAudio3Family.packageID: "Stable Audio 3 Small SFX"
    case ZImagePipelineFamily.packageID: "Z-Image"
    case SAM31PipelineFamily.packageID: "SAM 3.1 Selection"
    case "coreai.text.unlinked": "Core AI Text"
    case PipelineImageClassifierPackage.unlinkedPackageID: "Core AI Image Classifier"
    default: packageID
    }
  }

  private func defaultPackageURL(for packageID: String) -> URL {
    if document.nodes.contains(where: {
      $0.kind == CoreAITextPipelineFamily.compositeNodeKind
        && $0.resources["model"]?.linkedReference?.packageID == packageID
    }) {
      if packageID.contains("gemma-3-12b") {
        return FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".pixeltje/models/gemma-3-12b-instruct-coreai",
            isDirectory: true)
      }
      return CoreAITextPipelineFamily.defaultPackageURL()
    }
    if document.nodes.contains(where: {
      $0.kind == .coreAIImageClassifier
        && ($0.resources["model"]?.linkedReference?.packageID
          ?? PipelineImageClassifierPackage.unlinkedPackageID) == packageID
    }) {
      return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Pixeltje/Model Runs", isDirectory: true)
    }
    if packageID == FLUX2KleinPipelineFamily.packageID,
      document.nodes.contains(where: {
        $0.kind == FLUX2KleinPipelineFamily.compositeNodeKind
          && $0.resources["vaeEncoder"] != nil
      }) {
      return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
          "coreai-models/exports-image-conditioned/FLUX.2-klein-4B",
          isDirectory: true)
    }
    return switch packageID {
    case FLUX2KleinPipelineFamily.packageID:
      FLUX2KleinPipelineFamily.defaultPackageURL()
    case FLUX2Klein9BSplitFamily.packageID:
      FLUX2Klein9BSplitFamily.defaultPackageURL(adapted: document.nodes.contains { node in
        node.kind == FLUX2Klein9BSplitFamily.nodeKind
          && node.origin?.metadata["adapterSHA256"] != nil
      })
    case SDXSPipelineFamily.packageID:
      SDXSPipelineFamily.defaultPackageURL()
    case StableAudio3Family.packageID:
      StableAudio3Family.defaultPackageURL()
    case ZImagePipelineFamily.packageID:
      ZImagePipelineFamily.defaultPackageURL()
    case SAM31PipelineFamily.packageID:
      SAM31PipelineFamily.defaultPackageURL()
    case "coreai.text.unlinked":
      CoreAITextPipelineFamily.defaultPackageURL()
    default:
      FileManager.default.homeDirectoryForCurrentUser
    }
  }

  var canEditGuidance: Bool {
    executionProfile?.editableInvocationKeys.contains(PipelineInvocation.guidanceKey) == true
  }

  var canUndo: Bool { editorUndoManager.canUndo }
  var canRedo: Bool { editorUndoManager.canRedo }
  var undoActionName: String { editorUndoManager.undoActionName }
  var redoActionName: String { editorUndoManager.redoActionName }
  var viewportOrigin: PipelinePoint {
    document.presentation?.viewportOrigin ?? PipelinePoint(x: 0, y: 0)
  }
  var viewportScale: Double {
    min(max(document.presentation?.viewportScale ?? 1, 0.05), 2.5)
  }

  var canFitWorkflow: Bool {
    !document.nodes.isEmpty && graphViewportSize.width > 0 && graphViewportSize.height > 0
      && interactiveEdit == nil
  }

  func setGraphViewportSize(_ size: CGSize) {
    if graphViewportSize != size { graphViewportSize = size }
  }

  func createNewDocument() throws {
    let newDocument = try newWorkflowSettings.makeNewDocument()
    let sourceURL = try newWorkflowSettings.selectedWorkflowURL()
    replaceWithNewDocument(
      newDocument,
      status: "Created a new pipeline from \(newWorkflowSettings.selectedName).",
      sourceURL: sourceURL)
  }

  func createNewNativeNodeDocument() {
    replaceWithNewDocument(
      Self.newNativeNodeDocument(), status: "Created a composable native node workflow.")
  }

  func createNewNativeZImageDocument() {
    replaceWithNewDocument(
      Self.newNativeNodeDocument(zImage: true),
      status: "Created a composable Z-Image node workflow.")
  }

  func createNewTextDocument() {
    var document = CoreAITextPipelineFamily.makeNativeTextCompletionDocument()
    if let index = document.nodes.firstIndex(where: { $0.kind == .promptInput }) {
      document.nodes[index].parameters["value"] =
        .string("Write a short description of a quiet sunrise over a lake.")
    }
    replaceWithNewDocument(
      document,
      status: "Created a new Core AI text pipeline.")
  }

  func createModelTrainingDocument() {
    replaceWithNewDocument(ModelWorkflowBridge.importLegacy(.mnistStarter()),
      status: "Created an MNIST digit-training workflow in the Pipeline Editor.")
  }

  func createModelInferenceDocument() {
    replaceWithNewDocument(PipelineImageClassifierPackage.mnistWorkflow(),
      status: "Created a digit-recognition workflow. Choose its .aimodel and source image.")
  }

  func importLegacyModelDesign(_ url: URL) throws {
    let legacy = try ModelDesignJSON.decode(Data(contentsOf: url))
    replaceWithNewDocument(ModelWorkflowBridge.importLegacy(legacy),
      status: "Imported \(url.lastPathComponent). Save it as a .pixpipeline.json workflow.")
  }

  private func replaceWithNewDocument(
    _ newDocument: PipelineDocument, status: String, sourceURL: URL? = nil
  ) {
    cancelExecutionForDocumentReplacement()
    cancelViewportScroll()
    document = newDocument
    fileURL = nil
    newWorkflowSourceURL = sourceURL
    selectedImageURLs = [:]
    clearGeneratedOutput()
    selection = nil
    isDirty = false
    cleanDocument = document
    interactiveEdit = nil
    editorUndoManager.removeAllActions()
    publishUndoState()
    statusMessage = status
    validate()
    refreshExecutionProfile(resetPackageURL: true)
  }

  func open(_ url: URL) throws {
    cancelExecutionForDocumentReplacement()
    cancelViewportScroll()
    let decoded = try PipelineJSON.decode(Data(contentsOf: url))
    document = decoded
    fileURL = url
    newWorkflowSourceURL = nil
    selectedImageURLs = [:]
    clearGeneratedOutput()
    selection = nil
    isDirty = false
    cleanDocument = document
    interactiveEdit = nil
    editorUndoManager.removeAllActions()
    publishUndoState()
    statusMessage = "Opened \(url.lastPathComponent)."
    validate()
    refreshExecutionProfile(resetPackageURL: true)
  }

  func importComfyUI(_ url: URL, mapNodes: Bool) throws {
    cancelExecutionForDocumentReplacement()
    cancelViewportScroll()
    let result = try ComfyUIWorkflowConverter.convert(
      Data(contentsOf: url),
      sourceName: url.lastPathComponent,
      options: ComfyUIConversionOptions(mapNodes: mapNodes))
    document = result.document
    fileURL = nil
    newWorkflowSourceURL = nil
    selectedImageURLs = [:]
    selection = nil
    isDirty = true
    cleanDocument = nil
    interactiveEdit = nil
    editorUndoManager.removeAllActions()
    publishUndoState()
    clearGeneratedOutput()
    packageInspectionTask?.cancel()
    packageInspection = nil
    refreshExecutionProfile(resetPackageURL: true)
    let mapping = mapNodes
      ? "mapped \(result.summary.mappedNodeCount) recognized nodes"
      : "preserved every node as imported"
    statusMessage = "Imported \(result.summary.sourceNodeCount) ComfyUI nodes; \(mapping)."
    validate()
  }

  @discardableResult
  func save(to proposedURL: URL? = nil) throws -> URL {
    let destination = Self.pipelineURL(proposedURL ?? fileURL ?? URL(fileURLWithPath: ""))
    guard !destination.path.isEmpty else {
      throw PipelineEditorError.saveDestinationRequired
    }
    try PipelineJSON.encode(document).write(to: destination, options: .atomic)
    fileURL = destination
    cleanDocument = document
    isDirty = false
    statusMessage = "Saved \(destination.lastPathComponent)."
    return destination
  }

  func setDocumentName(_ name: String) {
    guard name != document.name else { return }
    performGraphMutation(actionName: "Rename Pipeline") { state in
      state.document.name = name
    }
  }

  func setNodeTitle(_ title: String, for nodeID: PipelineNodeID) {
    guard !isRunning,
      let index = document.nodes.firstIndex(where: { $0.id == nodeID })
    else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let updatedTitle = trimmed.isEmpty ? nil : trimmed
    guard document.nodes[index].title != updatedTitle else { return }
    performGraphMutation(actionName: "Rename Node") { state in
      state.document.nodes[index].title = updatedTitle
    }
  }

  func klein9BSteps(for nodeID: PipelineNodeID) -> Int {
    guard let node = document.nodes.first(where: {
      $0.id == nodeID && $0.kind == FLUX2Klein9BSplitFamily.nodeKind
    }), case .integer(let saved)? = node.parameters["steps"],
      let steps = Int(exactly: saved)
    else { return 4 }
    return steps
  }

  func setKlein9BSteps(_ requestedSteps: Int, for nodeID: PipelineNodeID) {
    guard !isRunning,
      let index = document.nodes.firstIndex(where: {
        $0.id == nodeID && $0.kind == FLUX2Klein9BSplitFamily.nodeKind
      })
    else { return }
    let steps = min(max(requestedSteps, 1), 20)
    guard document.nodes[index].parameters["steps"] != .integer(Int64(steps)) else { return }
    performGraphMutation(actionName: "Change Klein 9B Steps") { state in
      state.document.nodes[index].parameters["steps"] = .integer(Int64(steps))
    }
  }

  func setParameter(_ value: PipelineValue, named name: String, for nodeID: PipelineNodeID) {
    guard !isRunning,
      let index = document.nodes.firstIndex(where: { $0.id == nodeID }),
      let descriptor = PipelineGraphEditing.descriptor(
        for: document.nodes[index], registry: .pipelineEditor)?.parameter(named: name),
      Self.isEditable(value, as: descriptor.valueType)
    else { return }
    if document.nodes[index].kind == .trackpad, name == "spaceAction",
      value != .string("primary") && value != .string("secondary") { return }
    if document.nodes[index].kind == .assetCache, name == "slotCount" {
      guard case .integer(let count) = value, (1...16).contains(count),
        document.nodes[index].parameters[name] != value else { return }
      var updated = document
      updated.nodes[index].parameters[name] = value
      updated.connections.removeAll { connection in
        let port: String
        if connection.input.nodeID == nodeID {
          port = connection.input.port
        } else if connection.output.nodeID == nodeID {
          port = connection.output.port
        } else {
          return false
        }
        guard port.hasPrefix("asset"),
          let slot = Int(port.dropFirst("asset".count)) else { return false }
        return slot >= Int(count)
      }
      if interactiveEdit?.key == parameterEditKey(name, for: nodeID) {
        applyTransientDocument(updated)
      } else {
        performGraphMutation(actionName: "Change Cache Slots") { state in
          state.document = updated
        }
      }
      return
    }
    let normalizedValue: PipelineValue
    if document.nodes[index].kind == .trackpad, name == "x" || name == "y" {
      let coordinate: Double
      switch value {
      case .number(let number): coordinate = number
      case .integer(let integer): coordinate = Double(integer)
      default: return
      }
      guard coordinate.isFinite else { return }
      normalizedValue = .number(min(max(coordinate, 0), 1))
    } else {
      normalizedValue = value
    }
    guard document.nodes[index].parameters[name] != normalizedValue else { return }
    if interactiveEdit?.key == parameterEditKey(name, for: nodeID) {
      var updated = document
      updated.nodes[index].parameters[name] = normalizedValue
      applyTransientDocument(updated)
    } else {
      performGraphMutation(actionName: "Change \(name)") { state in
        state.document.nodes[index].parameters[name] = normalizedValue
      }
    }
    if document.nodes[index].kind == .assetCache, name == "keepBetweenRuns",
      normalizedValue == .boolean(false) {
      clearCachedAssets(for: nodeID)
    }
  }

  func clearCachedAssets(for nodeID: PipelineNodeID) {
    guard !isRunning,
      document.nodes.contains(where: { $0.id == nodeID && $0.kind == .assetCache }),
      let engine else { return }
    cacheAssetImages[nodeID] = nil
    cacheAssetAudioURLs[nodeID] = nil
    let documentID = document.id
    let previous = cacheClearTask
    cacheClearTask = Task {
      await previous?.value
      await engine.clearCachedAssets(for: nodeID, documentID: documentID)
    }
  }

  func setTimelineTracks(_ tracks: [PipelineTimelineSettings.Track], for nodeID: PipelineNodeID) {
    guard !isRunning,
      let index = document.nodes.firstIndex(where: {
        $0.id == nodeID && $0.kind == .controlTimeline
      }) else { return }
    let value = PipelineValue.array(tracks.map(\.parameterValue))
    guard document.nodes[index].parameters["tracks"] != value else { return }
    var candidate = document.nodes[index]
    candidate.parameters["tracks"] = value
    guard PipelineTimelineSettings(node: candidate) != nil else { return }
    performGraphMutation(actionName: "Edit Timeline") { state in
      state.document.nodes[index].parameters["tracks"] = value
    }
  }

  func beginParameterEdit(named name: String, for nodeID: PipelineNodeID) {
    guard !isRunning,
      let node = document.nodes.first(where: { $0.id == nodeID }),
      PipelineGraphEditing.descriptor(for: node, registry: .pipelineEditor)?
        .parameter(named: name) != nil
    else { return }
    let key = parameterEditKey(name, for: nodeID)
    if let active = interactiveEdit, active.key != key {
      endInteractiveEdit(key: active.key)
    }
    beginInteractiveEdit(key: key, actionName: "Change \(name)")
  }

  func endParameterEdit(named name: String, for nodeID: PipelineNodeID) {
    endInteractiveEdit(key: parameterEditKey(name, for: nodeID))
  }

  func beginTrackpadEdit(for nodeID: PipelineNodeID) {
    guard canEditTrackpad,
      document.nodes.contains(where: { $0.id == nodeID && $0.kind == .trackpad })
    else { return }
    if previewLookPosition?.nodeID == nodeID {
      previewLookPosition = nil
      syncLiveRunControls()
    }
    let key = trackpadEditKey(for: nodeID)
    if let active = interactiveEdit, active.key != key {
      endInteractiveEdit(key: active.key)
    }
    beginInteractiveEdit(key: key, actionName: "Move Trackpad")
    selectNode(nodeID)
    setTrackpadEngaged(true, for: nodeID)
  }

  private func setTrackpadEngaged(_ engaged: Bool, for nodeID: PipelineNodeID) {
    guard let index = document.nodes.firstIndex(where: {
      $0.id == nodeID && $0.kind == .trackpad
    })
    else { return }
    defer { syncLiveRunControls() }
    // A live run reports its call at the editor's sampling rate; read the
    // runner's own call so an engagement lands on the frame being drawn.
    let call = liveRun?.telemetry.snapshot.call ?? currentCall
    let runIndex = max(call - 1, 0)
    let atCall = engaged ? Int64(activeRepeatLength.map { runIndex % $0 } ?? runIndex) : 0
    if engaged, document.nodes[index].parameters["engaged"] == .boolean(true) {
      return
    }
    if engaged {
      trackpadEngagedAtRunIndex[nodeID] = runIndex
    } else {
      trackpadEngagedAtRunIndex.removeValue(forKey: nodeID)
    }
    let savedAtCall: Int64
    if case .integer(let value)? = document.nodes[index].parameters["engagedAtCall"] {
      savedAtCall = value
    } else {
      savedAtCall = 0
    }
    if !engaged,
      document.nodes[index].parameters["engaged"] != .boolean(true),
      savedAtCall == 0 {
      return
    }
    if interactiveEdit?.key == trackpadEditKey(for: nodeID) {
      var updated = document
      updated.nodes[index].parameters["engaged"] = .boolean(engaged)
      updated.nodes[index].parameters["engagedAtCall"] = .integer(atCall)
      if isRunning {
        document = updated
        updateDirtyState()
      } else {
        applyTransientDocument(updated)
      }
    } else {
      performGraphMutation(actionName: "Change Trackpad") { state in
        state.document.nodes[index].parameters["engaged"] = .boolean(engaged)
        state.document.nodes[index].parameters["engagedAtCall"] = .integer(atCall)
      }
    }
  }

  func setTrackpadPosition(x: Double, y: Double, for nodeID: PipelineNodeID) {
    guard canEditTrackpad, x.isFinite, y.isFinite,
      let index = document.nodes.firstIndex(where: {
        $0.id == nodeID && $0.kind == .trackpad
      })
    else { return }
    defer {
      updateTrackpadFocus()
      publishLiveGPUProgramPointer(for: nodeID)
      syncLiveRunControls()
    }
    let x = PipelineValue.number(min(max(x, 0), 1))
    let y = PipelineValue.number(min(max(y, 0), 1))
    guard document.nodes[index].parameters["x"] != x
      || document.nodes[index].parameters["y"] != y
    else { return }
    if interactiveEdit?.key == trackpadEditKey(for: nodeID) {
      var updated = document
      updated.nodes[index].parameters["x"] = x
      updated.nodes[index].parameters["y"] = y
      if isRunning {
        // The active graph is frozen. The next call receives transient inputs,
        // while a direct GPU preview also reads the live pointer before tick.
        document = updated
        updateDirtyState()
      } else {
        applyTransientDocument(updated)
      }
    } else {
      performGraphMutation(actionName: "Move Trackpad") { state in
        state.document.nodes[index].parameters["x"] = x
        state.document.nodes[index].parameters["y"] = y
      }
    }
  }

  func endTrackpadEdit(for nodeID: PipelineNodeID, commitAction: Bool = true) {
    let key = trackpadEditKey(for: nodeID)
    let hadGesture = interactiveEdit?.key == key
    let changed = interactiveEdit?.key == key
      && interactiveEdit?.before.document != document
    endInteractiveEdit(key: key)
    if changed { scheduleTrackpadArtPreview() }
    if commitAction, hadGesture, activeLoop?.settings.feedback == .stateAndImage,
      let loopID = autoPausedLoopNodeID { proceedLoop(loopID) }
  }

  func resetTrackpad(for nodeID: PipelineNodeID) {
    guard canEditTrackpad,
      document.nodes.contains(where: { $0.id == nodeID && $0.kind == .trackpad })
    else { return }
    let key = trackpadEditKey(for: nodeID)
    if let active = interactiveEdit, active.key != key {
      endInteractiveEdit(key: active.key)
    }
    beginInteractiveEdit(key: key, actionName: "Reset Trackpad")
    selectNode(nodeID)
    setTrackpadPosition(x: 0.5, y: 0.5, for: nodeID)
    setTrackpadEngaged(false, for: nodeID)
    endTrackpadEdit(for: nodeID, commitAction: false)
  }

  func canTriggerTrackpadAction(for nodeID: PipelineNodeID) -> Bool {
    isRunning && canEditTrackpad && document.connections.contains {
      $0.output == .init(nodeID: nodeID, port: "actionCount")
    }
  }

  func triggerTrackpadAction(for nodeID: PipelineNodeID) {
    guard canTriggerTrackpadAction(for: nodeID) else { return }
    trackpadActionCounts[nodeID] = min(
      (trackpadActionCounts[nodeID] ?? 0) + 1, 16_777_215)
    publishLiveGPUProgramPointer(for: nodeID)
  }

  func canTriggerTrackpadSecondaryAction(for nodeID: PipelineNodeID) -> Bool {
    isRunning && canEditTrackpad && document.connections.contains {
      $0.output == .init(nodeID: nodeID, port: "secondaryActionCount")
    }
  }

  func triggerTrackpadSecondaryAction(for nodeID: PipelineNodeID) {
    guard canTriggerTrackpadSecondaryAction(for: nodeID) else { return }
    trackpadSecondaryActionCounts[nodeID] = min(
      (trackpadSecondaryActionCounts[nodeID] ?? 0) + 1, 16_777_215)
    publishLiveGPUProgramPointer(for: nodeID)
  }

  func spaceTriggersTrackpadSecondaryAction(for nodeID: PipelineNodeID) -> Bool {
    document.nodes.first { $0.id == nodeID && $0.kind == .trackpad }?
      .parameters["spaceAction"] == .string("secondary")
  }

  @discardableResult
  func triggerTrackpadSpaceAction(for nodeID: PipelineNodeID) -> Bool {
    if spaceTriggersTrackpadSecondaryAction(for: nodeID) {
      guard canTriggerTrackpadSecondaryAction(for: nodeID) else { return false }
      triggerTrackpadSecondaryAction(for: nodeID)
    } else {
      guard canTriggerTrackpadAction(for: nodeID) else { return false }
      triggerTrackpadAction(for: nodeID)
    }
    return true
  }

  /// Keyboard state is transient and never changes the saved workflow.
  @discardableResult
  func setDirectionKey(_ characters: String?, pressed: Bool) -> Bool {
    guard let key = characters?.lowercased(),
      ["w", "a", "s", "d"].contains(key) || PipelineDirectionPadKeys.bit(for: key) != nil,
      liveRun != nil,
      document.nodes.contains(where: { $0.kind == .directionPad
        && $0.executionState == .enabled }) else { return false }
    if pressed { directionKeys.insert(key) }
    else { directionKeys.remove(key) }
    let x = Double((directionKeys.contains("d") ? 1 : 0)
      - (directionKeys.contains("a") ? 1 : 0))
    let y = Double((directionKeys.contains("w") ? 1 : 0)
      - (directionKeys.contains("s") ? 1 : 0))
    let keys = directionKeys.reduce(0) { $0 | (PipelineDirectionPadKeys.bit(for: $1) ?? 0) }
    if directionPadX != x || directionPadY != y || directionPadKeys != keys {
      directionPadX = x
      directionPadY = y
      directionPadKeys = keys
      syncLiveRunControls()
    }
    return true
  }

  func clearDirectionKeys() {
    guard !directionKeys.isEmpty else { return }
    directionKeys.removeAll()
    directionPadX = 0
    directionPadY = 0
    directionPadKeys = 0
    syncLiveRunControls()
  }

  func setPreviewLookPosition(x: Double, y: Double, for trackpadID: PipelineNodeID) {
    guard isRunning, canEditTrackpad, x.isFinite, y.isFinite,
      let programID = fullScreenPreviewNodeID,
      trackpadNodeID(forGPUProgramPreview: programID) == trackpadID
    else { return }
    let x = min(max(x, 0), 1)
    let y = min(max(y, 0), 1)
    if let position = previewLookPosition,
      position.nodeID == trackpadID && position.x == x && position.y == y { return }
    previewLookPosition = (trackpadID, x, y)
    publishLiveGPUProgramPointer(for: trackpadID)
    syncLiveRunControls()
  }

  func addPreviewLookDelta(x: Double, y: Double, for trackpadID: PipelineNodeID) {
    guard x.isFinite, y.isFinite,
      let saved = trackpadPosition(for: trackpadID) else { return }
    let current: (x: Double, y: Double)
    if let previewLookPosition, previewLookPosition.nodeID == trackpadID {
      current = (previewLookPosition.x, previewLookPosition.y)
    } else {
      current = saved
    }
    // The horizontal axis wraps so a captured mouse can turn indefinitely.
    let unwrappedX = current.x + x * 0.0006
    let wrappedX = unwrappedX - floor(unwrappedX)
    setPreviewLookPosition(x: wrappedX, y: current.y + y * 0.002,
      for: trackpadID)
  }

  private func publishLiveGPUProgramPointer(for trackpadID: PipelineNodeID) {
    guard let runID = activeExecutionID,
      let programID = liveMetalPreviewNodeID,
      trackpadNodeID(forGPUProgramPreview: programID) == trackpadID,
      let savedPosition = trackpadPosition(for: trackpadID),
      let engine else { return }
    let position: (x: Double, y: Double)
    if let previewLookPosition, previewLookPosition.nodeID == trackpadID {
      position = (previewLookPosition.x, previewLookPosition.y)
    } else {
      position = savedPosition
    }
    liveGPUProgramPointerRevision &+= 1
    let revision = liveGPUProgramPointerRevision
    let actionCount = trackpadActionCounts[trackpadID] ?? 0
    let secondaryActionCount = trackpadSecondaryActionCounts[trackpadID] ?? 0
    Task {
      await engine.updateLiveGPUProgramPointer(runID: runID, nodeID: programID,
        revision: revision, x: position.x, y: position.y, actionCount: actionCount,
        secondaryActionCount: secondaryActionCount)
    }
  }

  private func scheduleTrackpadArtPreview() {
    guard isBaseTestSetExecution,
      (activeLoop == nil || activeLoop?.settings.maxCalls == 1),
      (document.nodes.contains(where: { $0.kind == .imageProceduralNoise })
        || hasTrackpadDrivenMetalNode)
    else { return }
    trackpadArtPreviewTask?.cancel()
    trackpadArtPreviewTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, let self, self.canRun else { return }
      self.trackpadArtPreviewTask = nil
      self.run()
    }
  }

  private func trackpadEditKey(for nodeID: PipelineNodeID) -> String {
    "trackpad:\(nodeID.rawValue)"
  }

  private func parameterEditKey(_ name: String, for nodeID: PipelineNodeID) -> String {
    "parameter:\(nodeID.rawValue):\(name)"
  }

  private static func isEditable(
    _ value: PipelineValue, as type: PipelineParameterValueType
  ) -> Bool {
    switch (value, type) {
    case (.string, .string), (.boolean, .boolean), (.integer, .integer),
      (.number, .number), (.integer, .number):
      true
    case (.string, .any), (.boolean, .any), (.integer, .any), (.number, .any):
      true
    default:
      false
    }
  }

  func setModelPackageURL(_ url: URL, for nodeID: PipelineNodeID? = nil) {
    if let nodeID {
      guard let node = modelPackageNodes.first(where: { $0.id == nodeID }),
        let packageID = packageID(for: node)
      else { return }
      selectedNativePackageID = packageID
      modelPackageURL = packageURL(for: node) ?? defaultPackageURL(for: packageID)
    }
    let selectedURL = url.standardizedFileURL
    let previousURL = modelPackageURL
    modelPackageURL = selectedURL
    if isBaseTestSetExecution { newWorkflowSourceURL = nil }
    if isNativeNodeExecution, let selectedNativePackageID {
      nativePackageURLsByID[selectedNativePackageID] = selectedURL
    }
    clearGeneratedOutput()
    packageLinkTask?.cancel()
    packageLinkTask = nil
    activePackageLinkID = nil
    if selectedNativePackageID == StableAudio3Family.packageID,
      document.nodes.contains(where: { $0.kind == StableAudio3Family.nodeKind }) {
      packageInspectionTask?.cancel()
      packageInspection = nil
      let pipeline = document
      let nodes = pipeline.nodes.filter { $0.kind == StableAudio3Family.nodeKind }
      if previousURL == selectedURL, nodes.allSatisfy({ node in
        StableAudio3Package.slots.allSatisfy { node.resources[$0.name]?.linkedReference != nil }
      }) {
        inspectModelPackage()
        return
      }
      statusMessage = "Linking Stable Audio 3 node resources…"
      let linkID = UUID()
      activePackageLinkID = linkID
      packageLinkTask = Task { [weak self] in
        let linking = Task.detached(priority: .userInitiated) {
          try PipelineCoreAIPackageRelinker.relinkNativeStableAudio3(
            in: pipeline, toPackageAt: selectedURL)
        }
        do {
          let result = try await withTaskCancellationHandler {
            try await linking.value
          } onCancel: { linking.cancel() }
          try Task.checkCancellation()
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL, self.document == pipeline else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          if result.document != self.document {
            self.performGraphMutation(actionName: "Link Stable Audio 3 Package") { state in
              state.document = result.document
            }
          }
          self.inspectModelPackage()
        } catch is CancellationError {
          guard let self, self.activePackageLinkID == linkID else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
        } catch {
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          self.packageInspection = nil
          self.statusMessage = error.localizedDescription
        }
      }
      return
    }
    if selectedNativePackageID == SDXSPipelineFamily.packageID,
      document.nodes.contains(where: { $0.kind == SDXSPipelineFamily.nodeKind }) {
      packageInspectionTask?.cancel()
      packageInspection = nil
      let pipeline = document
      let nodes = pipeline.nodes.filter { $0.kind == SDXSPipelineFamily.nodeKind }
      if previousURL == selectedURL, nodes.allSatisfy({ node in
        ["denoiser", "textEncoder", "vaeDecoder"].allSatisfy {
          node.resources[$0]?.linkedReference != nil
        }
      }) {
        inspectModelPackage()
        return
      }
      statusMessage = "Linking SDXS node resources…"
      let linkID = UUID()
      activePackageLinkID = linkID
      packageLinkTask = Task { [weak self] in
        let linking = Task.detached(priority: .userInitiated) {
          try PipelineCoreAIPackageRelinker.relinkNativeSDXS(
            in: pipeline, toPackageAt: selectedURL)
        }
        do {
          let result = try await withTaskCancellationHandler {
            try await linking.value
          } onCancel: { linking.cancel() }
          try Task.checkCancellation()
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL, self.document == pipeline
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          if result.document != self.document {
            self.performGraphMutation(actionName: "Link SDXS Package") { state in
              state.document = result.document
            }
          }
          self.inspectModelPackage()
        } catch is CancellationError {
          guard let self, self.activePackageLinkID == linkID else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
        } catch {
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          self.packageInspection = nil
          self.statusMessage = error.localizedDescription
        }
      }
      return
    }
    if (selectedNativePackageID == FLUX2KleinPipelineFamily.packageID
      || selectedNativePackageID == FLUX2Klein9BSplitFamily.packageID),
      document.nodes.contains(where: {
      $0.kind == FLUX2KleinPipelineFamily.compositeNodeKind
        || $0.kind == FLUX2Klein9BSplitFamily.nodeKind
      }) {
      packageInspectionTask?.cancel()
      packageInspection = nil
      let compositeNodes = document.nodes.filter {
        $0.kind == FLUX2KleinPipelineFamily.compositeNodeKind
          || $0.kind == FLUX2Klein9BSplitFamily.nodeKind
      }
      if previousURL == selectedURL, compositeNodes.allSatisfy({ node in
        ["denoiser", "textEncoder", "vaeDecoder"].allSatisfy {
          node.resources[$0]?.linkedReference != nil
        }
      }) {
        inspectModelPackage()
        return
      }
      statusMessage = "Linking FLUX.2 Klein node resources…"
      let pipeline = document
      let linkID = UUID()
      activePackageLinkID = linkID
      packageLinkTask = Task { [weak self] in
        let linking = Task.detached(priority: .userInitiated) {
          if pipeline.nodes.contains(where: { $0.kind == FLUX2Klein9BSplitFamily.nodeKind }) {
            return try PipelineCoreAIPackageRelinker.relinkNativeFlux9BSplit(
              in: pipeline, toPackageAt: selectedURL)
          }
          return try PipelineCoreAIPackageRelinker.relinkNativeFluxComposite(
            in: pipeline, toPackageAt: selectedURL)
        }
        do {
          let result = try await withTaskCancellationHandler {
            try await linking.value
          } onCancel: {
            linking.cancel()
          }
          try Task.checkCancellation()
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL, self.document == pipeline
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          if result.document != self.document {
            self.performGraphMutation(actionName: "Link FLUX.2 Klein Package") { state in
              state.document = result.document
            }
          }
          self.inspectModelPackage()
        } catch is CancellationError {
          guard let self, self.activePackageLinkID == linkID else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
        } catch {
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          self.packageInspection = nil
          self.statusMessage = error.localizedDescription
        }
      }
      return
    }
    if selectedNativePackageID == ZImagePipelineFamily.packageID,
      document.nodes.contains(where: { $0.kind == .zImageGenerate }) {
      packageInspectionTask?.cancel()
      packageInspection = nil
      let pipeline = document
      let linkID = UUID()
      activePackageLinkID = linkID
      statusMessage = "Linking Z-Image node resources…"
      packageLinkTask = Task { [weak self] in
        let linking = Task.detached(priority: .userInitiated) {
          try PipelineCoreAIPackageRelinker.relinkNativeZImageComposite(
            in: pipeline, toPackageAt: selectedURL)
        }
        do {
          let result = try await withTaskCancellationHandler {
            try await linking.value
          } onCancel: { linking.cancel() }
          try Task.checkCancellation()
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL, self.document == pipeline
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          if result.document != self.document {
            self.performGraphMutation(actionName: "Link Z-Image Package") { state in
              state.document = result.document
            }
          }
          self.inspectModelPackage()
        } catch is CancellationError {
          guard let self, self.activePackageLinkID == linkID else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
        } catch {
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          self.packageInspection = nil
          self.statusMessage = error.localizedDescription
        }
      }
      return
    }
    if selectedNativePackageID == SAM31PipelineFamily.packageID,
      document.nodes.contains(where: { $0.kind == SAM31PipelineFamily.nodeKind }) {
      packageInspectionTask?.cancel()
      packageInspection = nil
      statusMessage = "Linking SAM 3.1 model and tokenizer…"
      let pipeline = document
      let linkID = UUID()
      activePackageLinkID = linkID
      packageLinkTask = Task { [weak self] in
        let linking = Task.detached(priority: .userInitiated) {
          try SAM31PipelineFamily.linkPackage(in: pipeline, at: selectedURL)
        }
        do {
          let linked = try await withTaskCancellationHandler {
            try await linking.value
          } onCancel: { linking.cancel() }
          try Task.checkCancellation()
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL, self.document == pipeline
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          if linked != self.document {
            self.performGraphMutation(actionName: "Link SAM 3.1 Package") { state in
              state.document = linked
            }
          }
          self.inspectModelPackage()
        } catch is CancellationError {
          guard let self, self.activePackageLinkID == linkID else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
        } catch {
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          self.packageInspection = nil
          self.statusMessage = error.localizedDescription
        }
      }
      return
    }
    if document.nodes.contains(where: {
        $0.kind == CoreAITextPipelineFamily.compositeNodeKind
          && ($0.resources["model"]?.linkedReference?.packageID
            ?? "coreai.text.unlinked") == selectedNativePackageID
      }) {
      packageInspectionTask?.cancel()
      packageInspection = nil
      statusMessage = "Reading Core AI language-model package identity…"
      let pipeline = document
      let packageIDToReplace = selectedNativePackageID
      let selectedTextNodeID = pipeline.nodes.first(where: {
        $0.kind == CoreAITextPipelineFamily.compositeNodeKind
          && $0.executionState == .enabled
          && ($0.resources["model"]?.linkedReference?.packageID
            ?? "coreai.text.unlinked") == packageIDToReplace
      })?.id
      let linkID = UUID()
      activePackageLinkID = linkID
      packageLinkTask = Task { [weak self] in
        let linking = Task.detached(priority: .userInitiated) {
          try CoreAITextPipelineFamily.linkPackage(
            in: pipeline, at: selectedURL, replacingPackageID: packageIDToReplace)
        }
        do {
          let linked = try await withTaskCancellationHandler {
            try await linking.value
          } onCancel: {
            linking.cancel()
          }
          try Task.checkCancellation()
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL, self.document == pipeline
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          if let packageID = linked.nodes.first(where: {
            $0.id == selectedTextNodeID
          })?.resources["model"]?.linkedReference?.packageID {
            self.nativePackageURLsByID[packageID] = selectedURL
            self.nativePackageURLsByID.removeValue(forKey: "coreai.text.unlinked")
            self.selectedNativePackageID = packageID
          }
          if linked != self.document {
            self.performGraphMutation(actionName: "Link Core AI Language Model") { state in
              state.document = linked
            }
          }
          self.inspectModelPackage()
        } catch is CancellationError {
          guard let self, self.activePackageLinkID == linkID else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
        } catch {
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL
          else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          self.packageInspection = nil
          self.statusMessage = error.localizedDescription
        }
      }
      return
    }
    if document.nodes.contains(where: {
      $0.kind == .coreAIImageClassifier
        && ($0.resources["model"]?.linkedReference?.packageID
          ?? PipelineImageClassifierPackage.unlinkedPackageID) == selectedNativePackageID
    }), let selectedNativePackageID {
      packageInspectionTask?.cancel()
      packageInspection = nil
      statusMessage = "Linking Core AI image classifier…"
      let pipeline = document
      let linkID = UUID()
      activePackageLinkID = linkID
      packageLinkTask = Task { [weak self] in
        let linking = Task.detached(priority: .userInitiated) {
          try PipelineImageClassifierPackage.link(pipeline, at: selectedURL,
            replacingPackageID: selectedNativePackageID, nodeID: nodeID)
        }
        do {
          let linked = try await withTaskCancellationHandler {
            try await linking.value
          } onCancel: { linking.cancel() }
          try Task.checkCancellation()
          guard let self, self.activePackageLinkID == linkID,
            self.modelPackageURL == selectedURL, self.document == pipeline else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          self.nativePackageURLsByID[linked.packageID] = selectedURL
          self.nativePackageURLsByID.removeValue(forKey: selectedNativePackageID)
          self.selectedNativePackageID = linked.packageID
          if linked.document != self.document {
            self.performGraphMutation(actionName: "Link Image Classifier") { state in
              state.document = linked.document
            }
          }
          self.inspectModelPackage()
        } catch is CancellationError {
          guard let self, self.activePackageLinkID == linkID else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
        } catch {
          guard let self, self.activePackageLinkID == linkID else { return }
          self.packageLinkTask = nil
          self.activePackageLinkID = nil
          self.packageInspection = nil
          self.statusMessage = error.localizedDescription
        }
      }
      return
    }
    inspectModelPackage()
  }

  func ensureOutputDirectoryExists() throws {
    try FileManager.default.createDirectory(
      at: currentOutputDirectoryURL,
      withIntermediateDirectories: true)
  }

  func setImageFile(_ url: URL, for nodeID: PipelineNodeID) {
    guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }),
      document.nodes[index].kind == .imageInput
    else { return }

    let selectedURL = url.standardizedFileURL
    let sourceName = selectedURL.lastPathComponent
    performGraphMutation(actionName: "Choose Source Image") { state in
      state.selectedImageURLs[nodeID] = selectedURL
      guard let currentIndex = state.document.nodes.firstIndex(where: { $0.id == nodeID }) else {
        return
      }
      state.document.nodes[currentIndex].parameters["sourceName"] = .string(sourceName)
    }
    if isBaseTestSetExecution {
      modelPackageURL = selectedURL.deletingLastPathComponent()
      inspectModelPackage()
    }
    statusMessage = "Selected \(sourceName) for \(document.nodes[index].title ?? "Source Image")."
  }

  func setVideoFile(_ url: URL, for nodeID: PipelineNodeID) {
    guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }),
      document.nodes[index].kind == .videoInput else { return }
    let selectedURL = url.standardizedFileURL
    let sourceName = selectedURL.lastPathComponent
    performGraphMutation(actionName: "Choose Source Video") { state in
      state.selectedImageURLs[nodeID] = selectedURL
      guard let currentIndex = state.document.nodes.firstIndex(where: { $0.id == nodeID }) else {
        return
      }
      state.document.nodes[currentIndex].parameters["sourceName"] = .string(sourceName)
    }
    if isBaseTestSetExecution {
      modelPackageURL = selectedURL.deletingLastPathComponent()
      inspectModelPackage()
    }
    statusMessage = "Selected \(sourceName) for Source Video."
  }

  func setFilePath(_ url: URL, for nodeID: PipelineNodeID) {
    guard !isRunning,
      let index = document.nodes.firstIndex(where: {
        $0.id == nodeID && $0.kind == .primitiveFilePath
      }) else { return }
    let selectedURL = url.standardizedFileURL
    let mode: String = if case .string(let saved)? = document.nodes[index].parameters["mode"] {
      saved
    } else {
      "relative"
    }
    let path: String
    if mode == "relative" {
      guard fileURL != nil || newWorkflowSourceURL != nil else {
        statusMessage = "Save the workflow before choosing a relative file path."
        return
      }
      let root = sourceMediaRootURL
        .resolvingSymlinksInPath().standardizedFileURL
      let resolved = selectedURL.resolvingSymlinksInPath().standardizedFileURL
      let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
      guard resolved.path.hasPrefix(prefix) else {
        statusMessage = "Choose a file inside the pipeline source folder for a relative path."
        return
      }
      path = String(resolved.path.dropFirst(prefix.count))
    } else if mode == "absolute" {
      path = selectedURL.path
    } else {
      statusMessage = "File Path mode must be relative or absolute."
      return
    }
    performGraphMutation(actionName: "Choose File Path") { state in
      guard let currentIndex = state.document.nodes.firstIndex(where: {
        $0.id == nodeID
      }) else { return }
      state.document.nodes[currentIndex].parameters["path"] = .string(path)
    }
    statusMessage = "Selected \(path)."
  }

  func videoFileURL(for node: PipelineNode) -> URL? {
    guard node.kind == .videoInput,
      case .string(let sourceName)? = node.parameters["sourceName"],
      !sourceName.isEmpty, !sourceName.contains("/"), !sourceName.contains("\\"),
      sourceName != ".", sourceName != ".." else { return nil }
    if let selectedURL = selectedImageURLs[node.id],
      selectedURL.lastPathComponent == sourceName { return selectedURL }
    return sourceMediaRootURL.appendingPathComponent(sourceName)
  }

  func imageFileURL(for node: PipelineNode) -> URL? {
    guard node.kind == .imageInput,
      case .string(let sourceName)? = node.parameters["sourceName"],
      !sourceName.isEmpty,
      !sourceName.contains("/"), !sourceName.contains("\\"),
      sourceName != ".", sourceName != ".."
    else { return nil }
    if let selectedURL = selectedImageURLs[node.id],
      selectedURL.lastPathComponent == sourceName {
      return selectedURL
    }
    return sourceMediaRootURL.appendingPathComponent(sourceName)
  }

  /// Resolve workflow files before the asynchronous execution profile chooses
  /// a package directory, so an immediate Run uses the workflow's own folder.
  private var sourceMediaRootURL: URL {
    return selectedImageURLs.values.first?.deletingLastPathComponent()
      ?? fileURL?.deletingLastPathComponent()
      ?? newWorkflowSourceURL?.deletingLastPathComponent()
      ?? modelPackageURL
  }

  var filePathChooserDirectoryURL: URL { sourceMediaRootURL }

  func beginMultilineStringEdit(_ nodeID: PipelineNodeID) {
    guard !isRunning, document.nodes.contains(where: {
      $0.id == nodeID && ($0.kind == .primitiveString
        || $0.kind == .stateInput)
    }) else { return }
    beginInteractiveEdit(
      key: multilineStringEditKey(for: nodeID),
      actionName: "Edit Text")
    selectNode(nodeID)
  }

  func setMultilineString(_ value: String, for nodeID: PipelineNodeID) {
    guard !isRunning, let index = document.nodes.firstIndex(where: {
      $0.id == nodeID && ($0.kind == .primitiveString
        || $0.kind == .stateInput)
    }), document.nodes[index].kind != .primitiveString
      || !document.connections.contains(where: {
        $0.input.nodeID == nodeID && $0.input.port == "value"
      }) else { return }
    let parameter = document.nodes[index].kind == .stateInput ? "initialState" : "value"
    guard document.nodes[index].parameters[parameter] != .string(value) else { return }

    beginMultilineStringEdit(nodeID)
    var updated = document
    updated.nodes[index].parameters[parameter] = .string(value)
    applyTransientDocument(updated)
  }

  func endMultilineStringEdit(_ nodeID: PipelineNodeID) {
    endInteractiveEdit(key: multilineStringEditKey(for: nodeID))
  }

  func selectNode(_ nodeID: PipelineNodeID) {
    guard document.nodes.contains(where: { $0.id == nodeID }) else { return }
    selection = .node(nodeID)
  }

  func selectConnection(_ connectionID: PipelineConnectionID) {
    guard (document.connections + document.controlConnections).contains(where: {
      $0.id == connectionID
    }) else { return }
    selection = .connection(connectionID)
  }

  func clearSelection() {
    selection = nil
  }

  func toggleNodeLibrary() {
    isNodeLibraryVisible.toggle()
  }

  func toggleInspector() {
    isInspectorVisible.toggle()
  }

  @discardableResult
  func addNode(kind: PipelineNodeKind, at position: PipelinePoint) -> PipelineNodeID? {
    if (kind == FLUX2KleinPipelineFamily.compositeNodeKind
      || kind == SDXSPipelineFamily.nodeKind
      || kind == StableAudio3Family.nodeKind
      || kind == FLUX2Klein9BSplitFamily.nodeKind || kind == .zImageGenerate
      || kind == CoreAITextPipelineFamily.compositeNodeKind),
      !document.requirements.familyABIs.isEmpty
    {
      statusMessage = "Create a native node workflow before adding a generation node."
      return nil
    }
    let registry = PipelineNodeRegistry.pipelineEditor
    guard let descriptor = registry.descriptor(for: kind) else {
      statusMessage = "Node kind \(kind.rawValue) is not installed."
      return nil
    }
    let nodeID = uniqueNodeID(for: kind)
    let parameters = Dictionary(
      uniqueKeysWithValues: descriptor.parameters.compactMap { parameter in
        parameter.defaultValue.map { (parameter.name, $0) }
      })
    let node: PipelineNode
    if kind == FLUX2KleinPipelineFamily.compositeNodeKind {
      node = FLUX2KleinPipelineFamily.makeCompositeNode(id: nodeID)
    } else if kind == SDXSPipelineFamily.nodeKind {
      node = SDXSPipelineFamily.makeNode(id: nodeID)
    } else if kind == StableAudio3Family.nodeKind {
      node = StableAudio3Family.makeNode(id: nodeID)
    } else if kind == FLUX2Klein9BSplitFamily.nodeKind {
      node = FLUX2Klein9BSplitFamily.makeNode(id: nodeID)
    } else if kind == .zImageGenerate {
      node = ZImageCompositeNode.makeNode(id: nodeID)
    } else if kind == CoreAITextPipelineFamily.compositeNodeKind {
      node = CoreAITextPipelineFamily.makeCompositeNode(id: nodeID)
    } else if kind == .coreAIImageClassifier {
      node = PipelineNode(id: nodeID, kind: kind, title: descriptor.displayName,
        parameters: parameters,
        resources: ["model": PipelineImageClassifierPackage.unresolved])
    } else {
      node = PipelineNode(
        id: nodeID,
        kind: kind,
        title: descriptor.displayName,
        parameters: parameters)
    }
    performGraphMutation(actionName: "Add \(descriptor.displayName)") { state in
      state.document.nodes.append(node)
      var presentation = state.document.presentation ?? PipelinePresentation()
      presentation.nodePositions[nodeID.rawValue] = position
      state.document.presentation = presentation
      if descriptor.isTerminal, state.document.primaryOutputNodeIDs != nil {
        state.document.primaryOutputNodeIDs?.append(nodeID)
      }
    }
    selection = .node(nodeID)
    statusMessage = "Added \(descriptor.displayName)."
    return nodeID
  }

  func beginNodeMove(_ nodeID: PipelineNodeID) {
    beginInteractiveEdit(key: "node:\(nodeID.rawValue)", actionName: "Move Node")
    selectNode(nodeID)
  }

  func moveNode(_ nodeID: PipelineNodeID, to position: PipelinePoint) {
    guard document.nodes.contains(where: { $0.id == nodeID }) else { return }
    var updated = document
    var presentation = updated.presentation ?? PipelinePresentation()
    presentation.nodePositions[nodeID.rawValue] = PipelinePoint(
      x: position.x.rounded(),
      y: position.y.rounded())
    updated.presentation = presentation
    applyTransientDocument(updated)
  }

  func endNodeMove(_ nodeID: PipelineNodeID) {
    endInteractiveEdit(key: "node:\(nodeID.rawValue)")
  }

  var canArrangeNodes: Bool { !document.nodes.isEmpty && interactiveEdit == nil }

  func arrangeNodes(_ arrangement: PipelineNodeArrangement) {
    finishViewportScroll()
    guard canArrangeNodes else { return }
    let origin = PipelinePoint(
      x: viewportOrigin.x + 80 / viewportScale,
      y: viewportOrigin.y + 80 / viewportScale)
    let positions = PipelineGraphLayout.positions(
      in: document, arrangement: arrangement, origin: origin)
    performGraphMutation(actionName: "Arrange Nodes \(arrangement.title)") { state in
      var presentation = state.document.presentation ?? PipelinePresentation()
      presentation.nodePositions.merge(positions) { _, new in new }
      state.document.presentation = presentation
    }
  }

  func fitWorkflow() {
    finishViewportScroll()
    guard canFitWorkflow, let bounds = PipelineGraphLayout.bounds(in: document) else { return }
    let padding = 40.0
    let scale = min(2.5, max(0.05, min(
      Double(graphViewportSize.width - padding * 2) / max(1, bounds.width),
      Double(graphViewportSize.height - padding * 2) / max(1, bounds.height))))
    let visibleWidth = Double(graphViewportSize.width) / scale
    let visibleHeight = Double(graphViewportSize.height) / scale
    let origin = PipelinePoint(
      x: bounds.midX - visibleWidth / 2,
      y: bounds.midY - visibleHeight / 2)
    performGraphMutation(actionName: "Fit Workflow") { state in
      var presentation = state.document.presentation ?? PipelinePresentation()
      presentation.viewportOrigin = origin
      presentation.viewportScale = scale
      state.document.presentation = presentation
    }
  }

  func beginNodeResize(_ nodeID: PipelineNodeID) {
    guard let node = document.nodes.first(where: { $0.id == nodeID }),
      node.kind == .imagePreview || node.kind == .videoPreview || node.kind == .renderMetal
        || node.kind == .gpuProgram || node.kind == .sceneSwitch
        || node.kind == .assetCache
        || node.kind == .markdownNote || node.kind == .trackpad
        || node.kind == .primitiveString
    else { return }
    let actionName: String
    switch node.kind {
    case .markdownNote: actionName = "Resize Markdown Note"
    case .primitiveString: actionName = "Resize Text Editor"
    case .trackpad: actionName = "Resize Trackpad"
    case .renderMetal: actionName = "Resize Metal Render Preview"
    case .gpuProgram: actionName = "Resize GPU Program Preview"
    case .sceneSwitch: actionName = "Resize Scene Switch Preview"
    case .assetCache: actionName = "Resize Asset Cache"
    case .videoPreview: actionName = "Resize Video Preview"
    default: actionName = "Resize Image Preview"
    }
    beginInteractiveEdit(
      key: "node-size:\(nodeID.rawValue)",
      actionName: actionName)
    selectNode(nodeID)
  }

  func resizeNode(_ nodeID: PipelineNodeID, to size: PipelineSize) {
    guard document.nodes.contains(where: {
      $0.id == nodeID && ($0.kind == .imagePreview || $0.kind == .videoPreview
        || $0.kind == .renderMetal || $0.kind == .gpuProgram
        || $0.kind == .sceneSwitch
        || $0.kind == .assetCache
        || $0.kind == .markdownNote
        || $0.kind == .primitiveString
        || $0.kind == .trackpad)
    }) else {
      return
    }
    var updated = document
    var presentation = updated.presentation ?? PipelinePresentation()
    presentation.nodeSizes[nodeID.rawValue] = PipelineSize(
      width: size.width.rounded(), height: size.height.rounded())
    updated.presentation = presentation
    applyTransientDocument(updated)
  }

  func endNodeResize(_ nodeID: PipelineNodeID) {
    endInteractiveEdit(key: "node-size:\(nodeID.rawValue)")
  }

  func beginViewportChange() {
    finishViewportScroll()
    beginInteractiveEdit(key: "viewport", actionName: "Change Canvas View")
  }

  func setViewport(origin: PipelinePoint, scale: Double) {
    var updated = document
    var presentation = updated.presentation ?? PipelinePresentation()
    presentation.viewportOrigin = origin
    presentation.viewportScale = min(max(scale, 0.05), 2.5)
    updated.presentation = presentation
    applyTransientDocument(updated)
  }

  func endViewportChange() {
    endInteractiveEdit(key: "viewport")
  }

  func scrollViewport(deltaX: Double, deltaY: Double) {
    guard deltaX != 0 || deltaY != 0 else { return }
    if viewportScrollEndTask == nil {
      beginInteractiveEdit(key: "viewport-scroll", actionName: "Pan Canvas")
    }
    viewportScrollEndTask?.cancel()

    var updated = document
    var presentation = updated.presentation ?? PipelinePresentation()
    let scale = viewportScale
    let origin = presentation.viewportOrigin ?? PipelinePoint(x: 0, y: 0)
    presentation.viewportOrigin = PipelinePoint(
      x: origin.x - deltaX / scale,
      y: origin.y - deltaY / scale)
    presentation.viewportScale = scale
    updated.presentation = presentation
    applyTransientDocument(updated)

    viewportScrollEndTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(180))
      } catch {
        return
      }
      guard let self else { return }
      self.viewportScrollEndTask = nil
      self.endInteractiveEdit(key: "viewport-scroll")
    }
  }

  func setViewportScale(_ scale: Double) {
    finishViewportScroll()
    performGraphMutation(actionName: "Zoom Canvas") { state in
      var presentation = state.document.presentation ?? PipelinePresentation()
      presentation.viewportScale = min(max(scale, 0.05), 2.5)
      state.document.presentation = presentation
    }
  }

  func resetViewport() {
    finishViewportScroll()
    performGraphMutation(actionName: "Reset Canvas View") { state in
      var presentation = state.document.presentation ?? PipelinePresentation()
      presentation.viewportOrigin = PipelinePoint(x: 0, y: 0)
      presentation.viewportScale = 1
      state.document.presentation = presentation
    }
  }

  func connectionDecision(
    output: PipelinePortReference,
    input: PipelinePortReference
  ) -> PipelineConnectionDecision {
    PipelineGraphEditing.connectionDecision(
      in: document,
      output: output,
      input: input,
      registry: .pipelineEditor,
      engineVersion: PixeltjePipelineEngine.currentEngineVersion)
  }

  @discardableResult
  func addConnection(
    output: PipelinePortReference,
    input: PipelinePortReference
  ) -> Bool {
    let decision = connectionDecision(output: output, input: input)
    guard decision.isAllowed else {
      statusMessage = decision.rejection?.message ?? "That connection is not allowed."
      return false
    }
    let connection = PipelineConnection(output: output, input: input)
    let outputKind = document.nodes.first(where: { $0.id == output.nodeID })?.kind
    let isControl = outputKind.flatMap {
      PipelineNodeRegistry.pipelineEditor.descriptor(for: $0)?
        .outputs.first(where: { $0.name == output.port })?.type == .control
    } ?? false
    performGraphMutation(actionName: "Connect Nodes") { state in
      if isControl {
        state.document.controlConnections.append(connection)
      } else {
        state.document.connections.append(connection)
      }
    }
    selection = .connection(connection.id)
    statusMessage = "Connected \(output.port) to \(input.port)."
    return true
  }

  func deleteSelection() {
    switch selection {
    case .node(let nodeID):
      deleteNode(nodeID)
    case .connection(let connectionID):
      deleteConnection(connectionID)
    case nil:
      break
    }
  }

  func deleteNode(_ nodeID: PipelineNodeID) {
    guard let node = document.nodes.first(where: { $0.id == nodeID }) else { return }
    let title = node.title ?? node.kind.rawValue
    performGraphMutation(actionName: "Delete \(title)") { state in
      state.document.nodes.removeAll { $0.id == nodeID }
      state.document.connections.removeAll {
        $0.output.nodeID == nodeID || $0.input.nodeID == nodeID
      }
      state.document.controlConnections.removeAll {
        $0.output.nodeID == nodeID || $0.input.nodeID == nodeID
      }
      state.document.exposedParameters.removeAll { $0.target.nodeID == nodeID }
      state.document.primaryOutputNodeIDs?.removeAll { $0 == nodeID }
      if var presentation = state.document.presentation {
        presentation.nodePositions.removeValue(forKey: nodeID.rawValue)
        presentation.nodeSizes.removeValue(forKey: nodeID.rawValue)
        state.document.presentation = presentation
      }
      state.selectedImageURLs.removeValue(forKey: nodeID)
    }
    selection = nil
    statusMessage = "Deleted \(title) and its connections."
  }

  func deleteConnection(_ connectionID: PipelineConnectionID) {
    guard (document.connections + document.controlConnections).contains(where: {
      $0.id == connectionID
    }) else { return }
    performGraphMutation(actionName: "Delete Connection") { state in
      state.document.connections.removeAll { $0.id == connectionID }
      state.document.controlConnections.removeAll { $0.id == connectionID }
    }
    selection = nil
    statusMessage = "Deleted connection."
  }

  func undo() {
    finishViewportScroll()
    guard editorUndoManager.canUndo else { return }
    editorUndoManager.undo()
    publishUndoState()
  }

  func redo() {
    finishViewportScroll()
    guard editorUndoManager.canRedo else { return }
    editorUndoManager.redo()
    publishUndoState()
  }

  func inspectModelPackage() {
    packageInspectionTask?.cancel()
    let url = modelPackageURL
    let pipeline = document
    let nativeIDs = nativePackageIDs
    let nativeURLs = nativePackageURLsByID
    guard let engine, let profile = executionProfile else {
      packageInspection = nil
      statusMessage = "This graph has no native execution profile. Check its output node and workflow-family ABI requirements."
      return
    }
    statusMessage = isBaseTestSetExecution
      ? "Checking local source media…"
      : "Checking the linked \(profile.displayName) package…"
    packageInspectionTask = Task { [weak self] in
      do {
        let inspection: PipelinePackageInspectionReport
        if pipeline.requirements.familyABIs.isEmpty, !nativeIDs.isEmpty {
          var failures: [String] = []
          for packageID in nativeIDs {
            let packageURL = nativeURLs[packageID]
              ?? self?.defaultPackageURL(for: packageID)
              ?? url
            var scoped = pipeline
            scoped.nodes = pipeline.nodes.filter { node in
              node.resources.values.contains { binding in
                binding.linkedReference?.packageID == packageID
              } || (packageID == FLUX2KleinPipelineFamily.packageID
                && node.kind == FLUX2KleinPipelineFamily.compositeNodeKind)
                || (packageID == FLUX2Klein9BSplitFamily.packageID
                  && node.kind == FLUX2Klein9BSplitFamily.nodeKind)
                || (packageID == SDXSPipelineFamily.packageID
                  && node.kind == SDXSPipelineFamily.nodeKind)
                || (packageID == StableAudio3Family.packageID
                  && node.kind == StableAudio3Family.nodeKind)
                || (packageID == ZImagePipelineFamily.packageID
                  && node.kind == .zImageGenerate)
                || (packageID == "coreai.text.unlinked"
                  && node.kind == CoreAITextPipelineFamily.compositeNodeKind)
                || (packageID == PipelineImageClassifierPackage.unlinkedPackageID
                  && node.kind == .coreAIImageClassifier)
            }
            scoped.connections = []
            let summary: String
            let usable: Bool
            if packageID == FLUX2KleinPipelineFamily.packageID {
              let needsReference = scoped.nodes.contains {
                $0.kind == FLUX2KleinPipelineFamily.compositeNodeKind
                  && $0.resources["vaeEncoder"] != nil
              }
              let result = await FLUX2KleinPipelineFamily.inspectPackageForExecution(
                at: packageURL, for: scoped,
                requiresImageConditioning: needsReference)
              summary = result.summary
              usable = result.isUsable
            } else if packageID == FLUX2Klein9BSplitFamily.packageID {
              let result = FLUX2Klein9BSplitFamily.inspectPackage(
                at: packageURL, for: scoped)
              summary = result.summary
              usable = result.isUsable
            } else if packageID == SDXSPipelineFamily.packageID {
              let error = SDXSPipelineFamily.inspectPackage(at: packageURL, for: scoped)
              summary = error ?? "SDXS Core AI package is ready."
              usable = error == nil
            } else if packageID == StableAudio3Family.packageID {
              let error = StableAudio3Family.inspectPackage(at: packageURL, for: scoped)
              summary = error ?? "Stable Audio 3 Core AI package is ready."
              usable = error == nil
            } else if packageID == ZImagePipelineFamily.packageID {
              let result = ZImagePipelineFamily.inspectPackage(at: packageURL, for: scoped)
              summary = result.summary
              usable = result.isUsable
            } else if packageID == SAM31PipelineFamily.packageID {
              let result = SAM31PipelineFamily.inspectPackage(at: packageURL, for: scoped)
              summary = result.summary
              usable = result.isUsable
            } else if packageID == "coreai.text.unlinked"
              || scoped.nodes.contains(where: {
                $0.kind == CoreAITextPipelineFamily.compositeNodeKind
              }) {
              let result = await CoreAITextPipelineFamily.inspectPackageForExecution(
                at: packageURL, for: scoped)
              summary = result.summary
              usable = result.isUsable
            } else if scoped.nodes.contains(where: { $0.kind == .coreAIImageClassifier }) {
              let error = PipelineImageClassifierPackage.inspect(scoped,
                at: packageURL, packageID: packageID)
              summary = error ?? "Core AI image classifier is ready."
              usable = error == nil
            } else {
              summary = "No package inspector is installed for \(packageID)."
              usable = false
            }
            if !usable { failures.append("\(packageID): \(summary)") }
          }
          inspection = PipelinePackageInspectionReport(
            adapterIdentifier: profile.identifier,
            packageRoot: url,
            isUsable: failures.isEmpty,
            summary: failures.isEmpty
              ? "All linked node packages are ready."
              : failures.joined(separator: " "),
            missingComponents: failures)
        } else {
          inspection = try await engine.inspectPackage(for: pipeline, at: url)
        }
        guard !Task.isCancelled, let self,
          self.modelPackageURL == url,
          self.executionProfile?.identifier == inspection.adapterIdentifier
        else { return }
        guard Self.hasSameValidationInputs(self.document, pipeline) else {
          self.inspectModelPackage()
          return
        }
        self.packageInspection = inspection
        self.statusMessage = inspection.summary
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, let self,
          self.modelPackageURL == url,
          self.executionProfile?.identifier == profile.identifier
        else { return }
        guard Self.hasSameValidationInputs(self.document, pipeline) else {
          self.inspectModelPackage()
          return
        }
        self.packageInspection = PipelinePackageInspectionReport(
          adapterIdentifier: profile.identifier,
          packageRoot: url,
          isUsable: false,
          summary: error.localizedDescription,
          missingComponents: [])
        self.statusMessage = error.localizedDescription
      }
    }
  }

  func previewTimelineFrame(_ frame: Int, for nodeID: PipelineNodeID) {
    guard let node = document.nodes.first(where: { $0.id == nodeID }),
      let settings = PipelineTimelineSettings(node: node),
      (0..<settings.frameCount).contains(frame),
      !isRunning else { return }
    run(previewFrame: frame)
  }

  func run(previewFrame: Int? = nil) {
    guard let engine, canRun else {
      if let reason = runUnavailableReason { statusMessage = reason }
      return
    }
    if isModelTraining && trainingPythonURL == nil {
      requestTrainingPython?()
      return
    }
    guard isNativeNodeExecution || isBaseTestSetExecution || UInt64(seedText) != nil else {
      statusMessage = "Seed must be a non-negative whole number."
      return
    }
    guard let profile = executionProfile else {
      statusMessage = "This graph has no native execution profile. Check its output node and workflow-family ABI requirements."
      return
    }
    clearDirectionKeys()
    let pipeline = document
    let resumeState = currentStateJSON
    let nativeRoots = nativePackageURLsByID
    let nativeIDs = nativePackageIDs
    let sourceMediaRoot = sourceMediaRootURL
    let executionSourceRoot: URL? = isModelTraining
      ? fileURL?.deletingLastPathComponent() : sourceMediaRoot
    let usesSavedInputs = isNativeNodeExecution
    let runPrompt = prompt
    let saveGeneratedImagesToDisk = newWorkflowSettings.saveGeneratedImagesToDisk
    let outputSize = profile.outputSize
    let loop = activeLoop
    let timeline = activeTimeline
    let selectedPreviewFrame = previewFrame
    let repeats = (loop != nil || timeline != nil) && selectedPreviewFrame == nil
    let usesLiveProceduralTrackpad = hasLiveProceduralTrackpadLoop
    let settings = loop?.settings ?? PipelineLoopSettings(maxCalls: 1, delayMilliseconds: 0)
    let maximumCalls = selectedPreviewFrame != nil ? 1
      : (timeline?.settings.frameCount ?? (loop == nil ? 1 : settings.maxCalls))
    let repeatLength = loop != nil && settings.autoRepeat && selectedPreviewFrame == nil
      ? settings.maxCalls : nil
    let selectedOutput = PipelineGraphOutputs.selectedOutputNode(
      in: pipeline, registry: .pipelineEditor)
    let directMetalRender = selectedOutput.flatMap { output -> PipelineNode? in
      guard output.kind == .imageOutput else { return nil }
      let inputs = pipeline.connections.filter { $0.input.nodeID == output.id }
      guard inputs.count == 1, inputs[0].input.port == "image",
        inputs[0].output.port == "image" else { return nil }
      guard let candidate = pipeline.nodes.first(where: {
        $0.id == inputs[0].output.nodeID && $0.executionState == .enabled
      }) else { return nil }
      if candidate.kind == .renderMetal || candidate.kind == .gpuProgram {
        return candidate
      }
      guard candidate.kind == .sceneSwitch else { return nil }
      let count: Int
      if case .integer(let saved)? = candidate.parameters["sceneCount"] {
        count = Int(saved)
      } else { count = 2 }
      guard (2...8).contains(count) else { return nil }
      for index in 0..<count {
        guard let edge = pipeline.connections.first(where: {
          $0.input.nodeID == candidate.id
            && $0.input.port == "scene\(index)"
        }), edge.output.port == "image",
          pipeline.nodes.contains(where: {
            $0.id == edge.output.nodeID && $0.kind == .gpuProgram
          }) else { return nil }
      }
      return candidate
    }
    let metalRender = directMetalRender ?? pipeline.nodes.first { node in
      (node.kind == .renderMetal || node.kind == .gpuProgram)
        && node.executionState == .enabled
    }
    let shaderMetalRender = metalRender.flatMap { node in
      pipeline.connections.contains {
        $0.input == .init(nodeID: node.id, port: "state")
      } ? node : nil
    }
    let shaderTimeline = shaderMetalRender.flatMap { render in
      pipeline.connections.first(where: {
        $0.input == .init(nodeID: render.id, port: "state")
          && $0.output.port == "value"
      }).flatMap { connection in
        pipeline.nodes.first(where: {
          $0.id == connection.output.nodeID && $0.kind == .controlTimeline
        }).flatMap(PipelineTimelineSettings.init(node:))
      }
    }
    let directMetalOutput = directMetalRender?.id
    let gpuTrackpad = pipeline.nodes.first { trackpad in
      guard trackpad.kind == .trackpad,
        (directMetalRender?.kind == .gpuProgram
          || directMetalRender?.kind == .sceneSwitch) else { return false }
      let programIDs: Set<PipelineNodeID> = Set(pipeline.connections.compactMap { connection in
        guard connection.input.nodeID == directMetalOutput,
          connection.input.port.hasPrefix("scene"),
          connection.output.port == "image" else { return nil }
        return connection.output.nodeID
      })
      return pipeline.connections.contains { connection in
        connection.output.nodeID == trackpad.id
          && (connection.input.nodeID == directMetalOutput
            || programIDs.contains(connection.input.nodeID))
          && (connection.input.port == "pointerX"
            || connection.input.port == "pointerY")
      }
    }
    // Preview views draw these on their own display links; a GPU Program
    // publishes a surface per call and shader state is drawn per refresh.
    let directMetalPreview = loop != nil && repeats && !saveGeneratedImagesToDisk
      && settings.feedback == nil && !newWorkflowSettings.debugModeEnabled
      && directMetalOutput != nil
      && (directMetalOutput == shaderMetalRender?.id
        || metalRender?.kind == .gpuProgram
        || metalRender?.kind == .sceneSwitch)
    let seedSource: ExecutionSeedSource?
    if let loop, settings.seedStrategy == .increment,
      let seedID = PipelineControlFlow.incrementSeedNodeID(in: pipeline, loop: loop) {
      seedSource = self.seedSource(for: seedID)
    } else {
      seedSource = executionSeedSource
    }
    let baseSeed: UInt64?
    switch seedSource {
    case .fixed(let value):
      baseSeed = value
    case .random:
      baseSeed = loop != nil && settings.seedStrategy == .increment
        ? UInt64.random(in: 0...UInt64(UInt32.max)) : nil
    case nil:
      baseSeed = nil
    }
    let executionID = UUID()
    do {
      if performanceLog == nil {
        performanceLog = try PipelineEditorPerformanceLog.requested()
      }
    } catch {
      statusMessage = "Could not create performance log: \(error.localizedDescription)"
      return
    }
    let performanceLog = self.performanceLog
    let traceLog: PipelineTraceLog?
    if newWorkflowSettings.debugModeEnabled {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PixeltjePipelineEditor/Traces", isDirectory: true)
        .appendingPathComponent("run-\(executionID.uuidString.lowercased()).jsonl")
      do {
        traceLog = try PipelineTraceLog(url: url)
        traceLogURL = url
        PipelineTraceLog.pruneEditorLogs(in: url.deletingLastPathComponent())
      } catch {
        statusMessage = "Could not create debug log: \(error.localizedDescription)"
        return
      }
    } else {
      traceLog = nil
      traceLogURL = nil
    }
    traceRecords = []
    traceError = nil
    let trace: PipelineTraceHandler?
    if let traceLog {
      trace = { [weak self] record in
        let retained = await traceLog.record(record)
        if let message = await traceLog.failureMessage() {
          await self?.receiveTraceError(message, executionID: executionID)
        }
        if let retained {
          await self?.receiveTrace(retained, executionID: executionID)
        }
      }
    } else {
      trace = nil
    }
    let pauseGate = PipelineExecutionPauseGate()
    activeExecutionID = executionID
    executionPauseGate = pauseGate
    continueRepeating = repeats
    currentCall = 0
    trackpadEngagedAtRunIndex = [:]
    trackpadActionCounts = [:]
    trackpadSecondaryActionCounts = [:]
    previewLookPosition = nil
    liveGPUProgramPointerRevision = 0
    autoPausedLoopNodeID = nil
    currentSeed = nil
    activeCallLimit = maximumCalls
    activeRepeatLength = repeatLength
    lastNodeExecutionSeconds = [:]
    resetExecutionActivity()
    executionState = .running
    let retainedCacheNodeIDs = Set(pipeline.nodes.filter {
      $0.kind == .assetCache && $0.executionState == .enabled
        && $0.parameters["keepBetweenRuns"] == .boolean(true)
    }.map(\.id))
    let previewFingerprints = Self.assetCacheFingerprints(in: pipeline)
    let retainedImages = cacheAssetImages.filter {
      retainedCacheNodeIDs.contains($0.key)
        && previewFingerprints[$0.key] != nil
        && previewFingerprints[$0.key] == cachedAssetPreviewFingerprints[$0.key]
    }
    let retainedAudio = cacheAssetAudioURLs.filter {
      retainedCacheNodeIDs.contains($0.key)
        && previewFingerprints[$0.key] != nil
        && previewFingerprints[$0.key] == cachedAssetPreviewFingerprints[$0.key]
    }
    clearGeneratedOutput(keepingNodeImagePreviews: true, keepingState: true)
    cacheAssetImages = retainedImages
    cacheAssetAudioURLs = retainedAudio
    cachedAssetPreviewFingerprints = previewFingerprints
    liveMetalPreviewSize = nil
    livePreview.clear()
    liveMetalPreviewNodeID = directMetalPreview ? directMetalOutput : nil
    if directMetalPreview, let directMetalOutput {
      nodeImagePreviews[directMetalOutput] = nil
      fullScreenPreviewImage = nil
      latestMetalPreview = nil
      latestMetalFullPreview = nil
    }
    executionProgress = .init(stage: .validating, message: "Starting pipeline…")
    statusMessage = "Starting pipeline…"
    let pendingCacheClear = cacheClearTask
    if directMetalPreview, let directMetalOutput, let loop, let metalRender {
      let isGPUProgram = metalRender.kind == .gpuProgram
        || metalRender.kind == .sceneSwitch
      let configuration = PipelineLivePreviewRunner.Configuration(
        engine: engine, pipeline: pipeline, executionID: executionID,
        liveNodeID: directMetalOutput, isGPUProgram: isGPUProgram,
        shaderMetalRenderID: shaderMetalRender?.id, shaderTimeline: shaderTimeline,
        loopNodeID: loop.loopNodeID, settings: settings,
        sourceMediaRoot: sourceMediaRoot,
        packageRoots: Dictionary(uniqueKeysWithValues: nativeIDs.map {
          ($0, nativeRoots[$0] ?? defaultPackageURL(for: $0))
        }),
        usesSavedInputs: usesSavedInputs, runPrompt: runPrompt, baseSeed: baseSeed,
        resumeState: resumeState, outputSize: outputSize,
        usesLiveProceduralTrackpad: usesLiveProceduralTrackpad,
        repeatLength: repeatLength,
        containsGPUProgram: pipeline.nodes.contains { $0.kind == .gpuProgram },
        performanceLog: performanceLog,
        highlightingEnabled: newWorkflowSettings.highlightNodesOnExecution,
        nodeSpeedLabelsEnabled: newWorkflowSettings.showExecutionSpeedPerNode)
      // A GPU Program's frames change only at its Loop rate; its views refresh
      // at that rate. Shader-state previews use the display's full rate.
      let source = PipelineLivePreviewSource(runID: executionID,
        preferredFramesPerSecond: isGPUProgram
          ? settings.limitHz ?? PipelineLivePreviewRunner.unlimitedRateHz : nil,
        performanceLog: performanceLog)
      startLivePreviewRun(configuration,
        liveRun: PipelineLiveRun(executionID: executionID, loopNodeID: loop.loopNodeID,
          trackpadNodeID: pipeline.nodes.first(where: { $0.kind == .trackpad })?.id,
          shaderMetalRenderID: shaderMetalRender?.id, source: source),
        pauseGate: pauseGate,
        pendingCacheClear: pendingCacheClear,
        retainedCacheNodeIDs: retainedCacheNodeIDs, gpuTrackpadID: gpuTrackpad?.id)
      return
    }
    executionTask = Task { [weak self] in
      guard let self else { return }
      await pendingCacheClear?.value
      await engine.setGPUProgramPerformanceCapture(
        runID: performanceLog == nil ? nil : executionID)
      defer {
        self.cacheAssetAudioURLs = self.cacheAssetAudioURLs.filter {
          retainedCacheNodeIDs.contains($0.key)
        }
        Task { await engine.endLiveMetalPreview(runID: executionID) }
      }
      var streamingVideoWriter: PipelineStreamingVideoWriter?
      let videoPreviewRecorder = PipelineVideoPreviewRecorder(runID: executionID)
      do {
        let packageRoots = Dictionary(uniqueKeysWithValues: nativeIDs.map {
          ($0, nativeRoots[$0] ?? self.defaultPackageURL(for: $0))
        })
        var priorOutput: PipelineExecutionOutput?
        var previousCallStartedAt: UInt64?
        var previousLogEnqueueSeconds: Double?
        var previousRequestedWaitSeconds: Double?
        var previousActualWaitSeconds: Double?
        var previousReadyAt: UInt64?
        var call = 1
        while true {
          try await self.pauseCheckpoint(pauseGate, executionID: executionID)
          try Task.checkCancellation()
          guard self.activeExecutionID == executionID else { return }
          let cycleIndex = selectedPreviewFrame ?? settings.callIndex(forRunCall: call)
          let cycleCall = cycleIndex + 1
          if call > 1 && cycleCall == 1 {
            priorOutput = nil
            self.currentStateJSON = resumeState
            self.currentInteractionMasks = []
            self.interactionPreviews = []
            self.updateTrackpadFocus()
          }
          let callStartedAt = DispatchTime.now().uptimeNanoseconds
          let frameInterval = previousCallStartedAt.map {
            PipelineEditorCallbackTimings.seconds(since: $0, until: callStartedAt)
          }
          let previousReadyToStartSeconds = previousReadyAt.map {
            PipelineEditorCallbackTimings.seconds(since: $0, until: callStartedAt)
          }
          previousCallStartedAt = callStartedAt
          let callbackTimings = performanceLog.map { _ in PipelineEditorCallbackTimings() }
          let callTrace: PipelineTraceHandler?
          if let trace, let callbackTimings {
            callTrace = { record in
              let started = DispatchTime.now().uptimeNanoseconds
              await trace(record)
              callbackTimings.recordTrace(since: started)
            }
          } else {
            callTrace = trace
          }
          self.currentCall = call
          if call > 1 {
            self.generatedText = ""
            self.generatedPreview = nil
          }
          let seed = baseSeed.map { base in
            loop != nil && settings.seedStrategy == .increment
              ? base &+ UInt64(cycleIndex) : base
          }
          self.currentSeed = seed
          self.executionProgress = .init(
            stage: .validating, message: "Starting call \(self.activeCallProgressLabel)…")
          var values: [String: PipelineInvocationValue] = usesSavedInputs ? [:] : [
            PipelineInvocation.promptKey: .string(runPrompt)
          ]
          if self.isModelTraining, let python = self.trainingPythonURL {
            values[ModelTrainingInvocation.pythonExecutableKey] = .string(python.path)
            values[ModelTrainingInvocation.outputDirectoryKey] = .string(
              self.trainingOutputDirectoryURL.path)
          }
          values[PipelineInvocation.loopCallIndexKey] = .integer(
            Int64(cycleIndex))
          if pipeline.nodes.contains(where: { $0.kind == .gpuProgram }) {
            values[PipelineInvocation.gpuProgramDeferredCommitKey] = .boolean(true)
          }
          if let metalRender = shaderMetalRender {
            let size = PipelineGraphMetrics.metalPreviewPixelSize(
              for: metalRender, in: self.document)
            values[PipelineInvocation.metalPreviewWidthKey] = .integer(Int64(size.width))
            values[PipelineInvocation.metalPreviewHeightKey] = .integer(Int64(size.height))
            values[PipelineInvocation.metalPreviewOnlyKey] = .boolean(
              repeats && !saveGeneratedImagesToDisk
                && directMetalOutput == metalRender.id
                && self.fullScreenPreviewNodeID != metalRender.id)
          }
          if let resumeState { values[PipelineInvocation.stateKey] = .string(resumeState) }
          if let outputSize {
            values[PipelineInvocation.widthKey] = .integer(Int64(outputSize.width))
            values[PipelineInvocation.heightKey] = .integer(Int64(outputSize.height))
          }
          if loop != nil, let seed,
            settings.seedStrategy == .increment || !usesSavedInputs {
            values[PipelineInvocation.seedKey] = .unsignedInteger(seed)
          }
          if settings.feedback == .scenePlanToNextView
            || settings.feedback == .scenePlanAndImageToNextView
            || settings.feedback == .imageAndTextToNextView
            || settings.feedback == .stateAndImage
            || usesLiveProceduralTrackpad,
            let trackpadID = pipeline.nodes.first(where: { $0.kind == .trackpad })?.id,
            let trackpad = self.document.nodes.first(where: { $0.id == trackpadID })
          {
            values[PipelineInvocation.trackpadXKey] = .number(
              Self.trackpadCoordinate("x", in: trackpad))
            values[PipelineInvocation.trackpadYKey] = .number(
              Self.trackpadCoordinate("y", in: trackpad))
            values[PipelineInvocation.trackpadEngagedKey] = .boolean(
              trackpad.parameters["engaged"] == .boolean(true))
            let engagedAtCall: Int64
            if case .integer(let value)? = trackpad.parameters["engagedAtCall"] {
              engagedAtCall = value
            } else {
              engagedAtCall = 0
            }
            let cycleEngagedAtCall: Int64
            if let repeatLength, trackpad.parameters["engaged"] == .boolean(true) {
              let engagedRunIndex = self.trackpadEngagedAtRunIndex[trackpadID] ?? 0
              cycleEngagedAtCall = engagedRunIndex / repeatLength == (call - 1) / repeatLength
                ? Int64(engagedRunIndex % repeatLength) : 0
            } else {
              cycleEngagedAtCall = engagedAtCall
            }
            values[PipelineInvocation.trackpadEngagedAtCallKey] = .integer(cycleEngagedAtCall)
            values[PipelineInvocation.trackpadActionCountKey] = .integer(
              Int64(self.trackpadActionCounts[trackpadID] ?? 0))
            values[PipelineInvocation.trackpadSecondaryActionCountKey] = .integer(
              Int64(self.trackpadSecondaryActionCounts[trackpadID] ?? 0))
          }
          if cycleCall > 1, let feedback = settings.feedback {
            guard let priorOutput else {
              throw PipelineEditorError.feedbackUnavailable
            }
            switch (feedback, priorOutput) {
            case (.textToPrompt, .text(let result)):
              values[PipelineInvocation.promptKey] = .string(result.text)
            case (.textToPrompt, .plainText(let result)):
              values[PipelineInvocation.promptKey] = .string(result.text)
            case (.imageToSourceImage, .image(let result)):
              values[PipelineInvocation.sourceImageKey] = .image(
                try await PipelineOutputWriter.feedbackImage(from: result))
            case (.scenePlanToNextView, .image(let result)):
              guard let planJSON = result.scenePlanJSON else {
                throw PipelineEditorError.feedbackUnavailable
              }
              values[PipelineInvocation.previousScenePlanKey] = .string(planJSON)
            case (.scenePlanAndImageToNextView, .image(let result)):
              guard let planJSON = result.scenePlanJSON else {
                throw PipelineEditorError.feedbackUnavailable
              }
              values[PipelineInvocation.previousScenePlanKey] = .string(planJSON)
              values[PipelineInvocation.sourceImageKey] = .image(
                try await PipelineOutputWriter.feedbackImage(from: result))
            case (.imageAndTextToNextView, .image(let result)):
              guard let feedbackText = result.feedbackText else {
                throw PipelineEditorError.imageFeedbackTextUnavailable
              }
              values[PipelineInvocation.promptKey] = .string(feedbackText)
              values[PipelineInvocation.sourceImageKey] = .image(
                try await PipelineOutputWriter.feedbackImage(from: result))
            case (.stateAndImage, .image(let result)):
              guard let state = result.nextStateJSON else { throw PipelineEditorError.feedbackUnavailable }
              values[PipelineInvocation.stateKey] = .string(state)
              values[PipelineInvocation.sourceImageKey] = .image(try await PipelineOutputWriter.feedbackImage(from: result))
              values[PipelineInvocation.interactionMasksKey] = .labeledMasks(result.interactionMasks)
            default:
              throw PipelineEditorError.feedbackUnavailable
            }
          }
          let inputState = try pipeline.nodes.first(where: { $0.kind == .stateInput }).map { node in
            let initial: String = if case .string(let text)? = node.parameters["initialState"] { text } else { "{}" }
            return try PipelineStateJSON.canonicalObject(PipelineInvocation(values: values).string(
              for: PipelineInvocation.stateKey, default: initial))
          }
          let startedAt = Date()
          let progressBuffer = PipelineEditorProgressBuffer()
          let progressCall = call
          let progressTask = Task { [weak self] in
            do {
              while true {
                try await Task.sleep(for: .milliseconds(50))
                guard let self, self.activeExecutionID == executionID,
                  self.currentCall == progressCall else { return }
                self.receiveBufferedProgress(
                  progressBuffer, executionID: executionID, callbackTimings: callbackTimings)
              }
            } catch { return }
          }
          defer {
            progressTask.cancel()
            // Preserve the latest streamed text and previews on error, too.
            self.receiveBufferedProgress(
              progressBuffer, executionID: executionID, callbackTimings: callbackTimings)
          }
          let engineStartedAt = DispatchTime.now().uptimeNanoseconds
          let callProgress: PipelineExecutionProgressHandler = { [weak self] update in
              let started = callbackTimings.map { _ in DispatchTime.now().uptimeNanoseconds }
              do {
                try await pauseGate.checkpoint { [weak self] in
                  await self?.markPaused(executionID: executionID)
                }
                await videoPreviewRecorder.record(update)
                progressBuffer.submit(update)
              } catch { return }
              if let started { callbackTimings?.recordProgress(since: started) }
            }
          let output = try await engine.execute(
            pipeline, sourceMediaRoot: executionSourceRoot,
            packageRootsByID: packageRoots,
            invocation: PipelineInvocation(values: values),
            progress: callProgress,
            trace: callTrace, traceRunID: executionID, traceCall: call)
          try await videoPreviewRecorder.check()
          if let directMetalOutput, let image = output.image {
            if self.fullScreenPreviewNodeID == directMetalOutput {
              self.latestMetalFullPreview = (directMetalOutput, image)
              self.scheduleFullScreenPreview(image, for: directMetalOutput)
            }
          }
          let engineCompletedAt = DispatchTime.now().uptimeNanoseconds
          if selectedPreviewFrame == nil, case .videoFrame(let frame) = output {
            if streamingVideoWriter == nil {
              let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pixeltje-video-\(executionID.uuidString.lowercased()).mp4")
              streamingVideoWriter = try PipelineStreamingVideoWriter(
                outputURL: temporaryURL, framesPerSecond: frame.framesPerSecond)
            }
            try await streamingVideoWriter?.append(frame)
          }
          progressTask.cancel()
          try Task.checkCancellation()
          guard self.activeExecutionID == executionID else { return }
          let progressFlushStartedAt = DispatchTime.now().uptimeNanoseconds
          self.receiveBufferedProgress(
            progressBuffer, executionID: executionID, callbackTimings: callbackTimings)
          let progressFlushSeconds = PipelineEditorCallbackTimings.seconds(
            since: progressFlushStartedAt)
          if case .text(let result) = output {
            self.currentSeed = result.seed
          }
          let outputWriterStartedAt = DispatchTime.now().uptimeNanoseconds
          let saved = try await PipelineOutputWriter.save(
            output, to: self.outputDirectoryURL,
            saveGeneratedImagesToDisk: selectedPreviewFrame == nil
              && saveGeneratedImagesToDisk)
          let outputWriterSeconds = PipelineEditorCallbackTimings.seconds(
            since: outputWriterStartedAt)
          var maskPreviews: [Data] = []
          if let image = output.image, let state = image.nextStateJSON, let url = saved.url {
            try await PipelineOutputWriter.saveTurn(.init(
              pipelineID: pipeline.id.rawValue, graphSHA256: image.semanticPipelineSHA256,
              call: call, seed: seed,
              x: values[PipelineInvocation.trackpadXKey].flatMap { if case .number(let n) = $0 { return n }; return nil },
              y: values[PipelineInvocation.trackpadYKey].flatMap { if case .number(let n) = $0 { return n }; return nil },
              previousState: inputState, nextState: state, renderPrompt: image.feedbackText,
              resources: pipeline.nodes.flatMap { $0.resources.values.compactMap(\.linkedReference) }), beside: url)
            maskPreviews = try await PipelineOutputWriter.interactionPreviews(image.interactionMasks)
          }
          try Task.checkCancellation()
          guard self.activeExecutionID == executionID else { return }
          let gpuCommitStartedAt = DispatchTime.now().uptimeNanoseconds
          await engine.commitGPUProgramFrame(runID: executionID)
          let gpuCommitSeconds = PipelineEditorCallbackTimings.seconds(
            since: gpuCommitStartedAt)
          let publicationStartedAt = DispatchTime.now().uptimeNanoseconds
          self.currentStateJSON = output.image?.nextStateJSON ?? self.currentStateJSON
          self.currentInteractionMasks = output.image?.interactionMasks ?? []
          self.interactionPreviews = maskPreviews.map(NSImage.init(data:))
          self.updateTrackpadFocus()
          self.previewTask?.cancel()
          self.previewTask = nil
          self.activePreviewID = nil
          let completedPreview = saved.imageData.flatMap(NSImage.init(data:))
          if let completedPreview {
            self.generatedPreview = completedPreview
            if settings.feedback == .stateAndImage,
              let trackpad = pipeline.nodes.first(where: { $0.kind == .trackpad }) {
              self.nodeImagePreviews[trackpad.id] = completedPreview
            }
          }
          if let text = saved.text { self.generatedText = text }
          self.currentScenePlan = output.image?.scenePlanJSON.flatMap {
            try? PipelineScenePlan.decode($0)
          }
          self.generatedOutputURL = saved.url
          let summary: String
          if let text = saved.text {
            let line = text.replacingOccurrences(of: "\n", with: " ")
            summary = line.isEmpty ? "Empty text" : String(line.prefix(120))
          } else if case .videoFrame(let frame) = output {
            summary = "Video frame \(call) · \(frame.image.width) × \(frame.image.height)"
          } else if let image = output.image {
            summary = saved.url?.lastPathComponent ?? "Image \(image.width) × \(image.height)"
          } else {
            summary = saved.url?.lastPathComponent ?? "No output"
          }
          let durationSeconds = max(Date().timeIntervalSince(startedAt), 0)
          let completedResult = PipelineCompletedResult(
            call: call, seed: self.currentSeed, durationSeconds: durationSeconds,
            outputURL: saved.url,
            text: saved.text, imagePreviewData: saved.imageData,
            summary: summary)
          self.completedResults = Array((self.completedResults + [completedResult]).suffix(100))
          if let selected = self.selectedResultCall,
            !self.completedResults.contains(where: { $0.call == selected }) {
            self.selectedResultCall = nil
          }
          if self.selectedResultCall == nil {
            self.selectedCompletedPreview = completedPreview
          }
          let seedLabel = self.currentSeed.map { " · seed \($0)" } ?? ""
          self.statusMessage = "Call \(self.activeCallProgressLabel) completed\(seedLabel) · \(completedResult.durationLabel)"
          self.setActiveNodeIDs([])
          priorOutput = settings.feedback == nil ? nil : output
          if let performanceLog, let callbackTimings {
            let completedAt = DispatchTime.now().uptimeNanoseconds
            let logStartedAt = DispatchTime.now().uptimeNanoseconds
            let gpuPerformance = engine.takeGPUProgramPerformance(runID: executionID)
            let record = PipelineEditorPerformanceLog.Frame(
              runID: executionID, call: call,
              configuration: PipelineEditorPerformanceLog.configuration,
              executable: Bundle.main.executableURL?.path,
              inputPreparationSeconds: PipelineEditorCallbackTimings.seconds(
                since: callStartedAt, until: engineStartedAt),
              engineSeconds: PipelineEditorCallbackTimings.seconds(
                since: engineStartedAt, until: engineCompletedAt),
              outputSavingSeconds: PipelineEditorCallbackTimings.seconds(
                since: engineCompletedAt, until: publicationStartedAt),
              progressFlushSeconds: progressFlushSeconds,
              outputWriterSeconds: outputWriterSeconds,
              gpuCommitSeconds: gpuCommitSeconds,
              publicationSeconds: PipelineEditorCallbackTimings.seconds(
                since: publicationStartedAt, until: completedAt),
              callSeconds: PipelineEditorCallbackTimings.seconds(since: callStartedAt, until: completedAt),
              frameIntervalSeconds: frameInterval,
              configuredDelayMilliseconds: settings.delayMilliseconds,
              configuredLimitHz: settings.limitHz,
              directMetalPreview: directMetalPreview,
              saveGeneratedImagesToDisk: saveGeneratedImagesToDisk,
              previewClockAvailable: false,
              gpuProgram: gpuPerformance,
              previousLogEnqueueSeconds: previousLogEnqueueSeconds,
              previousRequestedWaitSeconds: previousRequestedWaitSeconds,
              previousActualWaitSeconds: previousActualWaitSeconds,
              previousReadyToStartSeconds: previousReadyToStartSeconds,
              debugCaptureEnabled: trace != nil,
              highlightingEnabled: self.newWorkflowSettings.highlightNodesOnExecution,
              nodeSpeedLabelsEnabled: self.newWorkflowSettings.showExecutionSpeedPerNode,
              callbacks: callbackTimings.snapshot())
            Task.detached(priority: .utility) {
              await performanceLog.record(record)
            }
            previousLogEnqueueSeconds = PipelineEditorCallbackTimings.seconds(
              since: logStartedAt)
          }
          guard repeats, self.continueRepeating,
            loop != nil ? settings.continues(afterRunCall: call)
              : (maximumCalls.map({ call < $0 }) ?? true) else { break }
          if settings.feedback == .stateAndImage, output.image?.nextStateJSON == nil {
            throw PipelineEditorError.feedbackUnavailable
          }
          if settings.feedback == .imageAndTextToNextView,
            output.image?.feedbackText == nil {
            throw PipelineEditorError.imageFeedbackTextUnavailable
          }
          let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - callStartedAt
          let minimumInterval = settings.limitHz.map { UInt64(1_000_000_000 / $0) } ?? 0
          let rateLimitWait = minimumInterval > elapsedNanoseconds
            ? minimumInterval - elapsedNanoseconds : 0
          var remainingWait = max(
            UInt64(settings.delayMilliseconds) * 1_000_000, rateLimitWait)
          previousRequestedWaitSeconds = Double(remainingWait) / 1_000_000_000
          let waitStartedAt = DispatchTime.now().uptimeNanoseconds
          if remainingWait > 0 {
            self.statusMessage += " · next call in \((remainingWait + 999_999) / 1_000_000) ms"
          }
          while remainingWait > 0 && self.continueRepeating {
            try await self.pauseCheckpoint(pauseGate, executionID: executionID)
            let slice = min(remainingWait, 100_000_000)
            try await Task.sleep(for: .nanoseconds(Int64(slice)))
            remainingWait -= slice
          }
          previousActualWaitSeconds = PipelineEditorCallbackTimings.seconds(since: waitStartedAt)
          previousReadyAt = DispatchTime.now().uptimeNanoseconds
          guard self.continueRepeating else { break }
          if let loop, self.loopSettings(for: loop.loopNodeID)?.autoPause == true {
            self.executionState = .pausing
            self.autoPausedLoopNodeID = loop.loopNodeID
            self.statusMessage = "Call \(self.activeCallProgressLabel) completed · waiting to proceed."
            await pauseGate.pause()
            guard self.continueRepeating else {
              await pauseGate.resume()
              break
            }
            if self.autoPausedLoopNodeID == loop.loopNodeID,
              self.loopSettings(for: loop.loopNodeID)?.autoPause == true {
              try await self.pauseCheckpoint(pauseGate, executionID: executionID)
            } else {
              await pauseGate.resume()
              self.autoPausedLoopNodeID = nil
              self.executionState = .running
            }
            guard self.continueRepeating else { break }
          }
          call += 1
        }
        if let streamingVideoWriter {
          let video = try await streamingVideoWriter.finish()
          let savedVideo = try await PipelineOutputWriter.save(.video(video),
            to: self.outputDirectoryURL, saveGeneratedImagesToDisk: true)
          try? FileManager.default.removeItem(at: video.fileURL)
          try Task.checkCancellation()
          guard self.activeExecutionID == executionID else { return }
          self.generatedOutputURL = savedVideo.url
          self.statusMessage = "Saved \(video.frameCount) frames at \(video.framesPerSecond) fps to \(savedVideo.url?.lastPathComponent ?? "video")"
          if let last = self.completedResults.last {
            self.completedResults[self.completedResults.count - 1] = PipelineCompletedResult(
              call: last.call, seed: last.seed, durationSeconds: last.durationSeconds,
              outputURL: savedVideo.url, text: nil,
              imagePreviewData: last.imagePreviewData,
              summary: savedVideo.url?.lastPathComponent ?? "Video")
          }
        }
        let recordedPreviews = try await videoPreviewRecorder.finish()
        for (nodeID, url) in recordedPreviews {
          self.nodeVideoPreviewURLs[nodeID] = url
          self.temporaryVideoPreviewURLs.insert(url)
        }
        self.setActiveNodeIDs([])
        do { try await traceLog?.close() }
        catch { self.traceError = error.localizedDescription }
        self.continueRepeating = false
        self.autoPausedLoopNodeID = nil
        self.activeExecutionID = nil
        self.executionPauseGate = nil
        self.executionState = .idle
        self.executionTask = nil
      } catch is CancellationError {
        await streamingVideoWriter?.cancel()
        await videoPreviewRecorder.cancel()
        guard self.activeExecutionID == executionID else { return }
        do { try await traceLog?.close() }
        catch { self.traceError = error.localizedDescription }
        self.statusMessage = "Pipeline cancelled."
        self.resetExecutionActivity()
        self.continueRepeating = false
        self.autoPausedLoopNodeID = nil
        self.activeExecutionID = nil
        self.executionPauseGate = nil
        self.executionState = .idle
        self.executionTask = nil
      } catch {
        await streamingVideoWriter?.cancel()
        await videoPreviewRecorder.cancel()
        guard self.activeExecutionID == executionID else { return }
        do { try await traceLog?.close() }
        catch { self.traceError = error.localizedDescription }
        let message = error.localizedDescription
        if let engineError = error as? PipelineEngineError,
          case .invalidInvocation(let reason) = engineError,
          reason.localizedCaseInsensitiveContains("scene"),
          !self.generatedText.isEmpty
        {
          let failure = PipelineOutputWriter.ScenePlanFailure(
            recordedAt: Date(),
            pipelineName: pipeline.name,
            call: self.currentCall,
            seed: self.currentSeed,
            error: message,
            rawSceneWriterText: self.generatedText,
            previousScenePlanJSON: try? self.currentScenePlan?.encodedJSON())
          if let url = try? await PipelineOutputWriter.saveScenePlanFailure(failure) {
            self.statusMessage = "\(message) Scene writer response saved to \(url.path)"
          } else {
            self.statusMessage = message
          }
        } else {
          self.statusMessage = message
        }
        self.setActiveNodeIDs([])
        self.continueRepeating = false
        self.autoPausedLoopNodeID = nil
        self.activeExecutionID = nil
        self.executionPauseGate = nil
        self.executionState = .idle
        self.executionTask = nil
      }
    }
  }

  /// Runs a direct Metal Render or GPU Program preview Loop on its own actor.
  /// Preview views draw its frames on the render thread and the main actor
  /// only samples its progress, so a SwiftUI update never delays a frame.
  private func startLivePreviewRun(
    _ configuration: PipelineLivePreviewRunner.Configuration,
    liveRun: PipelineLiveRun,
    pauseGate: PipelineExecutionPauseGate,
    pendingCacheClear: Task<Void, Never>?,
    retainedCacheNodeIDs: Set<PipelineNodeID>,
    gpuTrackpadID: PipelineNodeID?
  ) {
    let engine = configuration.engine
    let executionID = configuration.executionID
    let liveNodeID = configuration.liveNodeID
    self.liveRun = liveRun
    syncLiveRunControls()
    let videoPreviewRecorder = PipelineVideoPreviewRecorder(runID: executionID)
    let runner = PipelineLivePreviewRunner(
      configuration: configuration,
      host: .init(
        markPaused: { [weak self] in await self?.markPaused(executionID: executionID) },
        beginAutoPause: { [weak self] call in
          await self?.beginLiveAutoPause(afterCall: call, executionID: executionID)
        },
        endAutoPause: { [weak self] in await self?.endLiveAutoPause(executionID: executionID) },
        frameSizeChanged: { [weak self] size in
          await self?.liveMetalPreviewSizeChanged(size, nodeID: liveNodeID)
        },
        playAudioEvent: { [weak self] url in
          await self?.playLiveAudioEvent(url, executionID: executionID)
        },
        updateAudioVoices: { [weak self] call, voices in
          await self?.updateLiveAudioVoices(voices, call: call, executionID: executionID)
        }),
      controls: liveRun.controls, telemetry: liveRun.telemetry,
      progressBuffer: liveRun.progress, source: liveRun.source,
      pauseGate: pauseGate, videoPreviewRecorder: videoPreviewRecorder)
    executionTask = Task { [weak self] in
      guard let self else { return }
      await pendingCacheClear?.value
      await engine.setGPUProgramPerformanceCapture(
        runID: configuration.performanceLog == nil ? nil : executionID)
      defer {
        self.endLiveRun(executionID)
        self.cacheAssetAudioURLs = self.cacheAssetAudioURLs.filter {
          retainedCacheNodeIDs.contains($0.key)
        }
        Task { await engine.endLiveMetalPreview(runID: executionID) }
      }
      do {
        await engine.beginLiveMetalPreview(runID: executionID, nodeID: liveNodeID)
        try Task.checkCancellation()
        self.livePreview.begin(liveRun.source)
        if let gpuTrackpadID { self.publishLiveGPUProgramPointer(for: gpuTrackpadID) }
        self.startLiveRunSampler(liveRun)
        try await runner.run()
        guard self.activeExecutionID == executionID else { return }
        self.applyLiveRunTelemetry(liveRun)
        let recordedPreviews = try await videoPreviewRecorder.finish()
        for (nodeID, url) in recordedPreviews {
          self.nodeVideoPreviewURLs[nodeID] = url
          self.temporaryVideoPreviewURLs.insert(url)
        }
        self.setActiveNodeIDs([])
        self.finishLiveRunExecution()
      } catch is CancellationError {
        await videoPreviewRecorder.cancel()
        guard self.activeExecutionID == executionID else { return }
        self.statusMessage = "Pipeline cancelled."
        self.resetExecutionActivity()
        self.finishLiveRunExecution()
      } catch {
        await videoPreviewRecorder.cancel()
        guard self.activeExecutionID == executionID else { return }
        self.statusMessage = error.localizedDescription
        self.setActiveNodeIDs([])
        self.finishLiveRunExecution()
      }
    }
  }

  private func finishLiveRunExecution() {
    continueRepeating = false
    autoPausedLoopNodeID = nil
    activeExecutionID = nil
    executionPauseGate = nil
    executionState = .idle
    executionTask = nil
  }

  private func endLiveRun(_ executionID: UUID) {
    livePreview.finish(runID: executionID)
    guard let liveRun, liveRun.executionID == executionID else { return }
    clearDirectionKeys()
    liveRun.samplerTask?.cancel()
    self.liveRun = nil
    liveAudioPlayers = []
    liveAudioData = [:]
    liveAudioVoices?.stop()
    liveAudioVoices = nil
    liveAudioVoicesFailed = false
  }

  private func playLiveAudioEvent(_ url: URL, executionID: UUID) {
    guard activeExecutionID == executionID,
      FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      let data: Data
      if let cached = liveAudioData[url] { data = cached }
      else {
        data = try Data(contentsOf: url)
        liveAudioData[url] = data
      }
      liveAudioPlayers.removeAll { !$0.isPlaying }
      let player = try AVAudioPlayer(data: data)
      player.prepareToPlay()
      guard player.play() else { return }
      liveAudioPlayers.append(player)
    } catch {
      statusMessage = "Could not play sound: \(error.localizedDescription)"
    }
  }

  private func updateLiveAudioVoices(_ voices: [PipelineGPUAudioVoice], call: Int,
    executionID: UUID) {
    guard activeExecutionID == executionID, liveRun?.executionID == executionID,
      executionState == .running, !liveAudioVoicesFailed else { return }
    let player = liveAudioVoices ?? PipelineLiveAudioVoices()
    liveAudioVoices = player
    do { try player.apply(call: call, voices: voices) } catch {
      player.stop()
      liveAudioVoicesFailed = true
      statusMessage = "Could not play looping sound: \(error.localizedDescription)"
    }
  }

  /// Publishes a live run's progress at a rate SwiftUI can follow, rather
  /// than once per frame.
  private func startLiveRunSampler(_ liveRun: PipelineLiveRun) {
    liveRun.samplerTask = Task { [weak self, weak liveRun] in
      while true {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        guard let self, let liveRun, self.liveRun === liveRun else { return }
        self.syncLiveRunControls()
        self.applyLiveRunTelemetry(liveRun)
      }
    }
  }

  private func applyLiveRunTelemetry(_ liveRun: PipelineLiveRun) {
    guard self.liveRun === liveRun, activeExecutionID == liveRun.executionID else { return }
    let telemetry = liveRun.telemetry.snapshot
    if currentCall != telemetry.call { currentCall = telemetry.call }
    if currentSeed != telemetry.seed { currentSeed = telemetry.seed }
    if let batch = liveRun.progress.drain() {
      receive(batch, executionID: liveRun.executionID)
    }
    guard executionState == .running, telemetry.completedCall > 0,
      telemetry.completedCall != liveRun.reportedCall else { return }
    liveRun.reportedCall = telemetry.completedCall
    let seedLabel = currentSeed.map { " · seed \($0)" } ?? ""
    let duration = PipelineCompletedResult.durationLabel(
      seconds: telemetry.completedCallSeconds)
    let message = "Call \(callProgressLabel(for: telemetry.completedCall)) completed\(seedLabel) · \(duration)"
    if statusMessage != message { statusMessage = message }
  }

  /// Hands the editor inputs that a live run reads per call to its runner.
  private func syncLiveRunControls() {
    guard let liveRun else { return }
    var snapshot = PipelineLiveRunControls.Snapshot()
    snapshot.continueRepeating = continueRepeating
    snapshot.isRunning = executionState == .running
    snapshot.autoPause = loopSettings(for: liveRun.loopNodeID)?.autoPause == true
    snapshot.autoPausedLoopNodeID = autoPausedLoopNodeID
    snapshot.fullScreenPreviewNodeID = fullScreenPreviewNodeID
    if document.nodes.contains(where: { $0.kind == .directionPad
      && $0.executionState == .enabled }) {
      snapshot.directionPad = .init(x: directionPadX, y: directionPadY,
        keys: directionPadKeys)
    }
    if let trackpadID = liveRun.trackpadNodeID,
      let trackpad = document.nodes.first(where: { $0.id == trackpadID }) {
      let previewPosition = previewLookPosition?.nodeID == trackpadID
        ? previewLookPosition : nil
      let engagedAtCall: Int64 = if case .integer(let value)? = trackpad.parameters["engagedAtCall"] {
        value
      } else {
        0
      }
      snapshot.trackpad = .init(
        x: previewPosition?.x ?? Self.trackpadCoordinate("x", in: trackpad),
        y: previewPosition?.y ?? Self.trackpadCoordinate("y", in: trackpad),
        engaged: trackpad.parameters["engaged"] == .boolean(true),
        engagedAtCall: engagedAtCall,
        engagedAtRunIndex: trackpadEngagedAtRunIndex[trackpadID],
        actionCount: trackpadActionCounts[trackpadID] ?? 0,
        secondaryActionCount: trackpadSecondaryActionCounts[trackpadID] ?? 0)
    }
    if let renderID = liveRun.shaderMetalRenderID,
      let render = document.nodes.first(where: { $0.id == renderID }) {
      let size = PipelineGraphMetrics.metalPreviewPixelSize(for: render, in: document)
      snapshot.metalPreviewSize = .init(width: size.width, height: size.height)
    }
    liveRun.controls.update(snapshot)
  }

  private func beginLiveAutoPause(afterCall call: Int, executionID: UUID) {
    guard activeExecutionID == executionID, let liveRun else { return }
    applyLiveRunTelemetry(liveRun)
    executionState = .pausing
    autoPausedLoopNodeID = liveRun.loopNodeID
    statusMessage = "Call \(callProgressLabel(for: call)) completed · waiting to proceed."
  }

  private func endLiveAutoPause(executionID: UUID) {
    guard activeExecutionID == executionID else { return }
    autoPausedLoopNodeID = nil
    executionState = .running
  }

  private func liveMetalPreviewSizeChanged(_ size: CGSize, nodeID: PipelineNodeID) {
    guard liveMetalPreviewNodeID == nodeID else { return }
    if liveMetalPreviewSize != size { liveMetalPreviewSize = size }
    if nodeImageDimensions[nodeID] != size { nodeImageDimensions[nodeID] = size }
  }

  private func receiveTrace(_ record: PipelineTraceRecord, executionID: UUID) {
    guard activeExecutionID == executionID else { return }
    traceRecords.append(record)
  }

  private func receiveTraceError(_ message: String, executionID: UUID) {
    guard activeExecutionID == executionID else { return }
    traceError = message
  }

  func openTrace(_ url: URL) {
    guard !isRunning else {
      traceError = "Finish or cancel the current run before opening another log."
      return
    }
    traceLogURL = url
    traceError = nil
    Task { [weak self] in
      do {
        let records = try await Task.detached(priority: .userInitiated) {
          try PipelineTraceLog.read(url)
        }.value
        if self?.traceLogURL == url && self?.isRunning == false {
          self?.traceRecords = records
        }
      } catch {
        if self?.traceLogURL == url { self?.traceError = error.localizedDescription }
      }
    }
  }

  func pauseExecution() {
    guard executionState == .running, let executionPauseGate else { return }
    executionState = .pausing
    statusMessage = "Pausing pipeline…"
    Task { await executionPauseGate.pause() }
  }

  func resumeExecution() {
    guard executionState == .paused, let executionPauseGate else { return }
    autoPausedLoopNodeID = nil
    executionState = .running
    statusMessage = "Resuming pipeline…"
    Task { await executionPauseGate.resume() }
  }

  func cancelExecution() {
    guard isRunning, executionState != .cancelling else { return }
    clearDirectionKeys()
    executionState = .cancelling
    autoPausedLoopNodeID = nil
    continueRepeating = false
    previewTask?.cancel()
    activePreviewID = nil
    executionTask?.cancel()
    if let executionPauseGate {
      Task { await executionPauseGate.resume() }
    }
    statusMessage = "Cancelling pipeline…"
  }

  func clearOutput() {
    guard canClearOutput else { return }
    clearGeneratedOutput(keepingAssetCachePreviews: true)
    executionProgress = nil
    statusMessage = "Output cleared from the editor. Saved files remain on disk."
  }

  func validate() {
    validateImmediately(document)
  }

  private func refreshEngineAndValidation() {
    guard let engine else {
      validate()
      return
    }
    Task { [weak self] in
      let snapshot = await engine.snapshot()
      guard let self else { return }
      self.engineSnapshot = snapshot
      self.statusMessage = "Pipeline engine initialized on \(snapshot.deviceName)."
      self.validate()
    }
  }

  private func refreshExecutionProfile(resetPackageURL: Bool) {
    executionProfileTask?.cancel()
    packageInspectionTask?.cancel()
    packageInspection = nil
    let pipeline = document
    guard let engine else {
      executionProfile = nil
      return
    }
    executionProfileTask = Task { [weak self] in
      let profile = await engine.executionProfile(for: pipeline)
      guard !Task.isCancelled, let self else { return }
      guard Self.hasSameValidationInputs(self.document, pipeline) else {
        self.refreshExecutionProfile(resetPackageURL: false)
        return
      }
      let adapterChanged = self.executionProfile?.identifier != profile?.identifier
      self.executionProfile = profile
      guard let profile else {
        self.statusMessage = "This graph has no native execution profile. Check its output node and workflow-family ABI requirements."
        return
      }
      if resetPackageURL || adapterChanged {
        if self.isNativeNodeExecution {
          self.synchronizeNativePackageSelection(reset: true)
          if self.nativePackageIDs.isEmpty {
            self.modelPackageURL = self.selectedImageURLs.values.first?.deletingLastPathComponent()
              ?? self.fileURL?.deletingLastPathComponent()
              ?? self.newWorkflowSourceURL?.deletingLastPathComponent()
              ?? profile.defaultPackageURL
          }
        } else {
          self.nativePackageURLsByID = [:]
          self.selectedNativePackageID = nil
          self.modelPackageURL = self.isBaseTestSetExecution
            ? self.fileURL?.deletingLastPathComponent() ?? profile.defaultPackageURL
            : profile.defaultPackageURL
        }
        self.applyExecutionDefaults(from: profile)
      }
      self.inspectModelPackage()
    }
  }

  private func validationStatus(for report: PipelineValidationReport) -> String {
    report.isValid
      ? "Pipeline is valid."
      : "Pipeline has \(report.errors.count) validation error\(report.errors.count == 1 ? "" : "s")."
  }

  private func synchronizeNativePackageSelection(reset: Bool) {
    guard isNativeNodeExecution else { return }
    let ids = nativePackageIDs
    if reset { nativePackageURLsByID = [:] }
    for id in ids where nativePackageURLsByID[id] == nil {
      nativePackageURLsByID[id] = defaultPackageURL(for: id)
    }
    nativePackageURLsByID = nativePackageURLsByID.filter { ids.contains($0.key) }
    if let selectedNativePackageID, ids.contains(selectedNativePackageID) {
      modelPackageURL = nativePackageURLsByID[selectedNativePackageID]
        ?? defaultPackageURL(for: selectedNativePackageID)
    } else {
      selectedNativePackageID = ids.first
      if let first = ids.first {
        modelPackageURL = nativePackageURLsByID[first] ?? defaultPackageURL(for: first)
      }
    }
  }

  private func currentGraphState() -> GraphState {
    GraphState(document: document, selectedImageURLs: selectedImageURLs)
  }

  private func performGraphMutation(
    actionName: String,
    _ mutate: (inout GraphState) -> Void
  ) {
    let before = currentGraphState()
    var after = before
    mutate(&after)
    guard after.document != before.document
      || after.selectedImageURLs != before.selectedImageURLs
    else { return }
    applyGraphState(after)
    registerUndo(to: before, actionName: actionName)
  }

  private func registerUndo(to state: GraphState, actionName: String) {
    editorUndoManager.registerUndo(withTarget: self) { target in
      target.restoreGraphState(state, actionName: actionName)
    }
    editorUndoManager.setActionName(actionName)
    publishUndoState()
  }

  private func restoreGraphState(_ state: GraphState, actionName: String) {
    let inverse = currentGraphState()
    applyGraphState(state)
    registerUndo(to: inverse, actionName: actionName)
  }

  private func applyGraphState(_ state: GraphState) {
    let previousMode = document.mode
    let previousABIs = document.requirements.familyABIs
    let needsValidation = !Self.hasSameValidationInputs(document, state.document)
    invalidateCachedAssets(ifDifferentFrom: state.document)
    if needsValidation && !isRunning { lastNodeExecutionSeconds = [:] }
    if needsValidation || state.selectedImageURLs != selectedImageURLs {
      nodeTextValues = [:]
    }
    document = state.document
    synchronizeNativePackageSelection(reset: false)
    selectedImageURLs = state.selectedImageURLs
    discardInvalidSelection()
    updateDirtyState()
    if needsValidation { validate() }
    let adapterSelectionChanged = document.mode != previousMode
      || document.requirements.familyABIs != previousABIs
    if adapterSelectionChanged || needsValidation {
      refreshExecutionProfile(resetPackageURL: adapterSelectionChanged)
    }
  }

  private func applyTransientDocument(_ updated: PipelineDocument) {
    guard updated != document else { return }
    invalidateCachedAssets(ifDifferentFrom: updated)
    let needsValidation = !Self.hasSameValidationInputs(document, updated)
    if needsValidation { nodeTextValues = [:] }
    document = updated
    updateDirtyState()
    if needsValidation { validateImmediately(updated) }
  }

  private static func hasSameValidationInputs(
    _ lhs: PipelineDocument,
    _ rhs: PipelineDocument
  ) -> Bool {
    var lhs = lhs
    var rhs = rhs
    // Panning, zooming, and arranging nodes do not change validation, the
    // execution profile, or package readiness. Accept in-flight results after
    // these edits so the editor cannot stay indefinitely disabled.
    lhs.presentation = nil
    rhs.presentation = nil
    return lhs == rhs
  }

  private func validateImmediately(_ snapshot: PipelineDocument) {
    validationTask?.cancel()
    var report = PipelineGraphValidator.validate(
      snapshot,
      registry: .pipelineEditor,
      engineVersion: PixeltjePipelineEngine.currentEngineVersion)
    if snapshot.requirements.familyABIs.isEmpty,
      let installed = engineSnapshot?.executableNodeKinds
    {
      let supported = Set(installed)
      let incoming = Dictionary(grouping: snapshot.connections, by: \.input.nodeID)
      let outputID = PipelineGraphOutputs.selectedOutputNode(
        in: snapshot, registry: .pipelineEditor)?.id
      var pending = outputID.map { [$0] } ?? snapshot.nodes.compactMap { node in
        guard node.executionState == .enabled else { return nil }
        let isUnconnectedOutput = PipelineNodeRegistry.pipelineEditor.descriptor(
          for: node.kind)?.isTerminal == true && incoming[node.id] == nil
        return isUnconnectedOutput ? nil : node.id
      }
      pending.append(contentsOf: snapshot.nodes.compactMap { node in
        (node.kind == .imagePreview || node.kind == .videoPreview)
          && node.executionState == .enabled ? node.id : nil
      })
      var reachable: Set<PipelineNodeID> = []
      while let current = pending.popLast() {
        guard reachable.insert(current).inserted else { continue }
        pending.append(contentsOf: (incoming[current] ?? []).map(\.output.nodeID))
      }
      for node in snapshot.nodes where reachable.contains(node.id) {
        if node.executionState != .enabled || !supported.contains(node.kind) {
          report.diagnostics.append(.init(
            severity: .error,
            code: .unsupportedNodeImplementation,
            message: "Node \(node.id.rawValue) has no active native Swift executor.",
            nodeID: node.id))
        }
      }
    }
    validationReport = report
    shaderValidationPending = report.isValid && engine != nil
      && snapshot.nodes.contains(where: { node in
        node.kind == .gpuProgram || (node.kind == .renderMetal
          && snapshot.connections.contains(where: {
            $0.input.nodeID == node.id && $0.input.port == "state"
          }))
      })
    let immediateStatus = shaderValidationPending
      ? "Checking Metal shader…" : validationStatus(for: report)
    statusMessage = immediateStatus
    if let engine {
      let sourceMediaRoot = sourceMediaRootURL
      let shouldDebounce = shaderValidationPending
      validationTask = Task { [weak self] in
        if shouldDebounce {
          do { try await Task.sleep(for: .milliseconds(250)) }
          catch { return }
        }
        let authoritativeReport = await engine.validate(
          snapshot, sourceMediaRoot: sourceMediaRoot)
        guard !Task.isCancelled, let self,
          Self.hasSameValidationInputs(self.document, snapshot)
        else { return }
        self.shaderValidationPending = false
        self.validationReport = authoritativeReport
        if self.statusMessage == immediateStatus {
          self.statusMessage = self.validationStatus(for: authoritativeReport)
        }
      }
    }
  }

  private func beginInteractiveEdit(key: String, actionName: String) {
    guard interactiveEdit == nil else { return }
    interactiveEdit = InteractiveEdit(
      key: key,
      actionName: actionName,
      before: currentGraphState())
  }

  private func endInteractiveEdit(key: String) {
    guard let edit = interactiveEdit, edit.key == key else { return }
    interactiveEdit = nil
    let after = currentGraphState()
    guard after.document != edit.before.document
      || after.selectedImageURLs != edit.before.selectedImageURLs
    else { return }
    registerUndo(to: edit.before, actionName: edit.actionName)
  }

  private func finishViewportScroll() {
    guard viewportScrollEndTask != nil else { return }
    viewportScrollEndTask?.cancel()
    viewportScrollEndTask = nil
    endInteractiveEdit(key: "viewport-scroll")
  }

  private func cancelViewportScroll() {
    viewportScrollEndTask?.cancel()
    viewportScrollEndTask = nil
    if interactiveEdit?.key == "viewport-scroll" {
      interactiveEdit = nil
    }
  }

  private func updateDirtyState() {
    isDirty = cleanDocument.map { document != $0 } ?? true
  }

  private func discardInvalidSelection() {
    switch selection {
    case .node(let nodeID) where !document.nodes.contains(where: { $0.id == nodeID }):
      selection = nil
    case .connection(let connectionID)
    where !(document.connections + document.controlConnections).contains(where: {
      $0.id == connectionID
    }):
      selection = nil
    default:
      break
    }
  }

  private func publishUndoState() {
    undoStateRevision &+= 1
  }

  private func multilineStringEditKey(for nodeID: PipelineNodeID) -> String {
    "parameter:\(nodeID.rawValue):value"
  }

  private func uniqueNodeID(for kind: PipelineNodeKind) -> PipelineNodeID {
    let scalarSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let base = kind.rawValue.unicodeScalars.map { scalarSet.contains($0) ? Character(String($0)) : "-" }
    let normalized = String(base).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    var candidate = normalized.isEmpty ? "node" : normalized
    var suffix = 2
    let existing = Set(document.nodes.map(\.id.rawValue))
    while existing.contains(candidate) {
      candidate = "\(normalized)-\(suffix)"
      suffix += 1
    }
    return PipelineNodeID(rawValue: candidate)
  }

  private func receive(
    _ batch: PipelineEditorProgressBuffer.Batch,
    executionID: UUID
  ) {
    guard activeExecutionID == executionID, executionTask?.isCancelled != true else { return }
    let progress = batch.progress
    // Each write to published state re-renders the editor, so repeated loop
    // calls only write values that changed.
    for (nodeID, text) in batch.nodeTextValues where nodeTextValues[nodeID] != text {
      nodeTextValues[nodeID] = text
    }
    if executionProgress != progress { executionProgress = progress }
    let seedLabel = currentSeed.map { " · seed \($0)" } ?? ""
    if executionState == .running {
      let message = "Call \(activeCallProgressLabel)\(seedLabel): \(progress.message)"
      if statusMessage != message { statusMessage = message }
    }
    setActiveNodeIDs(progress.activeNodeIDs)
    for (nodeID, seconds) in batch.nodeExecutionSeconds
    where lastNodeExecutionSeconds[nodeID] != seconds {
      lastNodeExecutionSeconds[nodeID] = seconds
    }
    if !activatedNodeIDs.isSuperset(of: batch.activatedNodeIDs) {
      activatedNodeIDs.formUnion(batch.activatedNodeIDs)
    }
    if newWorkflowSettings.highlightNodesOnExecution {
      if !glowingNodeIDs.isSuperset(of: batch.activatedNodeIDs) {
        glowingNodeIDs.formUnion(batch.activatedNodeIDs)
      }
      for nodeID in batch.activatedNodeIDs.subtracting(progress.activeNodeIDs) {
        scheduleGlowOut(for: nodeID)
      }
    }
    for (nodeID, preview) in batch.nodePreviews {
      if document.nodes.contains(where: {
        $0.id == nodeID && ($0.kind == .renderMetal || $0.kind == .gpuProgram)
      }) {
        latestMetalPreview = (nodeID, preview)
        let feedsSelectedOutput = PipelineGraphOutputs.selectedOutputNode(
          in: document, registry: .pipelineEditor).map { output in
            document.connections.contains {
              $0.output == .init(nodeID: nodeID, port: "image")
                && $0.input == .init(nodeID: output.id, port: "image")
            }
          } ?? false
        if document.nodes.contains(where: {
          $0.id == nodeID && $0.kind == .gpuProgram
        }) || !feedsSelectedOutput {
          scheduleFullScreenPreview(preview, for: nodeID)
        }
      }
      scheduleNodePreview(preview, for: nodeID, executionID: executionID)
      for edge in document.connections where edge.output.nodeID == nodeID
        && edge.output.port == "image" && edge.input.port.hasPrefix("scene")
        && document.nodes.contains(where: {
          $0.id == edge.input.nodeID && $0.kind == .sceneSwitch
        }) {
        scheduleNodePreview(preview, for: edge.input.nodeID,
          executionID: executionID)
        if fullScreenPreviewNodeID == edge.input.nodeID {
          scheduleFullScreenPreview(preview, for: edge.input.nodeID)
        }
      }
    }
    for (nodeID, slots) in batch.assetPreviews {
      for (slot, asset) in slots {
        if let image = asset.image {
          Task { [weak self] in
            let bitmap = try? await PipelineOutputWriter.previewBitmap(from: image)
            guard let self, self.activeExecutionID == executionID,
              let bitmap, let cgImage = bitmap.cgImage() else { return }
            self.cacheAssetImages[nodeID, default: [:]][slot] = NSImage(
              cgImage: cgImage,
              size: NSSize(width: bitmap.width, height: bitmap.height))
          }
        }
        if let url = asset.audioURL {
          cacheAssetAudioURLs[nodeID, default: [:]][slot] = url
        }
      }
    }
    for (nodeID, video) in batch.videoPreviews {
      nodeVideoPreviewURLs[nodeID] = video.url
      if video.isTemporary { temporaryVideoPreviewURLs.insert(video.url) }
    }
    if let preview = batch.preview, previewTask == nil,
      Date().timeIntervalSince(lastPreviewStartedAt) >= 0.35 {
      lastPreviewStartedAt = Date()
      let previewID = UUID()
      activePreviewID = previewID
      previewTask = Task { [weak self] in
        defer {
          if self?.activePreviewID == previewID {
            self?.previewTask = nil
            self?.activePreviewID = nil
          }
        }
        guard let data = try? await PipelineOutputWriter.previewData(from: preview),
          !Task.isCancelled, let self, self.activeExecutionID == executionID,
          self.executionTask?.isCancelled != true
        else { return }
        self.generatedPreview = NSImage(data: data)
      }
    }
    if let text = batch.generatedText {
      generatedText = text
    }
  }

  private func scheduleNodePreview(
    _ preview: PipelineGeneratedImage, for nodeID: PipelineNodeID, executionID: UUID
  ) {
    if nodePreviewTaskIDs[nodeID] != nil {
      pendingNodePreviews[nodeID] = preview
      return
    }
    let requestID = UUID()
    nodePreviewTaskIDs[nodeID] = requestID
    Task { [weak self] in
      let bitmap = try? await PipelineOutputWriter.previewBitmap(from: preview)
      guard let self, self.nodePreviewTaskIDs[nodeID] == requestID else { return }
      self.nodePreviewTaskIDs[nodeID] = nil
      if let bitmap, let cgImage = bitmap.cgImage(),
        self.activeExecutionID == executionID,
        self.document.nodes.contains(where: { $0.id == nodeID }) {
        self.nodeImagePreviews[nodeID] = NSImage(cgImage: cgImage,
          size: NSSize(width: bitmap.width, height: bitmap.height))
        self.nodeImageDimensions[nodeID] = CGSize(width: preview.width, height: preview.height)
      }
      if let pending = self.pendingNodePreviews.removeValue(forKey: nodeID),
        self.activeExecutionID == executionID {
        self.scheduleNodePreview(pending, for: nodeID, executionID: executionID)
      }
    }
  }

  func setFullScreenPreviewNode(_ nodeID: PipelineNodeID?) {
    fullScreenPreviewNodeID = nodeID
    if nodeID == nil { latestMetalFullPreview = nil }
    fullScreenPreviewTask?.cancel()
    fullScreenPreviewTask = nil
    fullScreenPreviewRequestID = nil
    pendingFullScreenPreview = nil
    fullScreenPreviewImage = nil
    if nodeID == liveMetalPreviewNodeID, liveMetalPreviewSize != nil { return }
    if let nodeID {
      if let latestMetalFullPreview, latestMetalFullPreview.nodeID == nodeID {
        scheduleFullScreenPreview(latestMetalFullPreview.image, for: nodeID)
      } else if let latestMetalPreview, latestMetalPreview.nodeID == nodeID {
        scheduleFullScreenPreview(latestMetalPreview.image, for: nodeID)
      }
    }
  }

  private func scheduleFullScreenPreview(
    _ preview: PipelineGeneratedImage, for nodeID: PipelineNodeID
  ) {
    guard fullScreenPreviewNodeID == nodeID else { return }
    if fullScreenPreviewTask != nil {
      pendingFullScreenPreview = (nodeID, preview)
      return
    }
    let requestID = UUID()
    fullScreenPreviewRequestID = requestID
    fullScreenPreviewTask = Task { [weak self] in
      let data = try? await PipelineOutputWriter.previewData(from: preview, maxDimension: nil)
      guard let self, self.fullScreenPreviewRequestID == requestID else { return }
      self.fullScreenPreviewTask = nil
      self.fullScreenPreviewRequestID = nil
      if let data, !Task.isCancelled, self.fullScreenPreviewNodeID == nodeID {
        self.fullScreenPreviewImage = NSImage(data: data)
      }
      if let pending = self.pendingFullScreenPreview {
        self.pendingFullScreenPreview = nil
        self.scheduleFullScreenPreview(pending.image, for: pending.nodeID)
      }
    }
  }

  private func pauseCheckpoint(
    _ gate: PipelineExecutionPauseGate, executionID: UUID
  ) async throws {
    try await gate.checkpoint { [weak self] in
      await self?.markPaused(executionID: executionID)
    }
  }

  private func receiveBufferedProgress(
    _ buffer: PipelineEditorProgressBuffer,
    executionID: UUID,
    callbackTimings: PipelineEditorCallbackTimings?
  ) {
    guard let batch = buffer.drain() else { return }
    let started = callbackTimings.map { _ in DispatchTime.now().uptimeNanoseconds }
    receive(batch, executionID: executionID)
    if let started { callbackTimings?.recordProgressPublication(since: started) }
  }

  private func markPaused(executionID: UUID) {
    guard activeExecutionID == executionID, executionState == .pausing else { return }
    executionState = .paused
    liveAudioVoices?.stop()
    statusMessage = autoPausedLoopNodeID == nil
      ? "Pipeline paused." : "Loop paused. Click Proceed or Resume to start the next call."
  }

  private func setActiveNodeIDs(_ nodeIDs: Set<PipelineNodeID>) {
    guard nodeIDs != activeNodeIDs else { return }
    let departed = activeNodeIDs.subtracting(nodeIDs)
    if newWorkflowSettings.highlightNodesOnExecution {
      for nodeID in nodeIDs {
        nodeGlowTasks.removeValue(forKey: nodeID)?.cancel()
        glowingNodeIDs.insert(nodeID)
      }
    }
    activeNodeIDs = nodeIDs
    activatedNodeIDs.formUnion(nodeIDs)
    if newWorkflowSettings.highlightNodesOnExecution {
      for nodeID in departed {
        scheduleGlowOut(for: nodeID)
      }
    }
  }

  private func scheduleGlowOut(for nodeID: PipelineNodeID) {
    nodeGlowTasks.removeValue(forKey: nodeID)?.cancel()
    nodeGlowTasks[nodeID] = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(450))
      } catch {
        return
      }
      guard let self, !self.activeNodeIDs.contains(nodeID) else { return }
      self.glowingNodeIDs.remove(nodeID)
      self.nodeGlowTasks.removeValue(forKey: nodeID)
    }
  }

  private func resetExecutionActivity() {
    for task in nodeGlowTasks.values { task.cancel() }
    nodeGlowTasks.removeAll()
    activeNodeIDs = []
    glowingNodeIDs = []
    activatedNodeIDs = []
  }

  private func cancelExecutionForDocumentReplacement() {
    clearDirectionKeys()
    let endingExecution = executionTask
    let previousClear = cacheClearTask
    if let engine {
      cacheClearTask = Task {
        await endingExecution?.value
        await previousClear?.value
        await engine.discardCachedAssetsInMemory()
      }
    }
    cachedAssetPreviewFingerprints = [:]
    packageLinkTask?.cancel()
    packageLinkTask = nil
    activePackageLinkID = nil
    executionTask?.cancel()
    if let executionPauseGate {
      Task { await executionPauseGate.resume() }
    }
    previewTask?.cancel()
    previewTask = nil
    activePreviewID = nil
    executionTask = nil
    executionPauseGate = nil
    activeExecutionID = nil
    continueRepeating = false
    autoPausedLoopNodeID = nil
    executionState = .idle
    currentCall = 0
    trackpadEngagedAtRunIndex = [:]
    trackpadActionCounts = [:]
    trackpadSecondaryActionCounts = [:]
    previewLookPosition = nil
    currentSeed = nil
    activeCallLimit = 1
    activeRepeatLength = nil
    lastNodeExecutionSeconds = [:]
    resetExecutionActivity()
  }

  private func invalidateCachedAssets(ifDifferentFrom updated: PipelineDocument) {
    let fingerprints = Self.assetCacheFingerprints(in: updated)
    let changed = cachedAssetPreviewFingerprints.keys.filter {
      fingerprints[$0] != cachedAssetPreviewFingerprints[$0]
    }
    guard !changed.isEmpty else { return }
    cachedAssetPreviewFingerprints = fingerprints
    for nodeID in changed {
      cacheAssetImages[nodeID] = nil
      cacheAssetAudioURLs[nodeID] = nil
    }
    guard let engine else { return }
    let previous = cacheClearTask
    cacheClearTask = Task {
      await previous?.value
      for nodeID in changed {
        await engine.clearCachedAssets(for: nodeID, documentID: updated.id)
      }
    }
  }

  private static func assetCacheFingerprints(
    in document: PipelineDocument
  ) -> [PipelineNodeID: String] {
    Dictionary(uniqueKeysWithValues: document.nodes.filter {
      $0.kind == .assetCache
    }.compactMap { node in
      (try? PipelineJSON.assetCacheSHA256(document, nodeID: node.id))
        .map { (node.id, $0) }
    })
  }

  private func clearGeneratedOutput(keepingNodeImagePreviews: Bool = false,
    keepingState: Bool = false, keepingAssetCachePreviews: Bool = false) {
    nodeTextValues = [:]
    for url in temporaryVideoPreviewURLs { try? FileManager.default.removeItem(at: url) }
    temporaryVideoPreviewURLs = []
    nodeVideoPreviewURLs = [:]
    if keepingAssetCachePreviews {
      let retained = Set(document.nodes.filter {
        $0.kind == .assetCache && $0.executionState == .enabled
          && $0.parameters["keepBetweenRuns"] == .boolean(true)
      }.map(\.id))
      cacheAssetImages = cacheAssetImages.filter { retained.contains($0.key) }
      cacheAssetAudioURLs = cacheAssetAudioURLs.filter { retained.contains($0.key) }
    } else {
      cacheAssetImages = [:]
      cacheAssetAudioURLs = [:]
    }
    if !keepingState { currentStateJSON = nil }
    currentInteractionMasks = []
    interactionPreviews = []
    trackpadMaskPreview = nil
    trackpadFocus = "Open scene"
    generatedPreview = nil
    nodePreviewTaskIDs = [:]
    pendingNodePreviews = [:]
    if !keepingNodeImagePreviews {
      nodeImagePreviews = [:]
      nodeImageDimensions = [:]
      liveMetalPreviewSize = nil
      livePreview.clear()
      liveMetalPreviewNodeID = nil
      latestMetalPreview = nil
      latestMetalFullPreview = nil
      fullScreenPreviewTask?.cancel()
      fullScreenPreviewTask = nil
      fullScreenPreviewRequestID = nil
      pendingFullScreenPreview = nil
      fullScreenPreviewNodeID = nil
      fullScreenPreviewImage = nil
    }
    generatedText = ""
    generatedOutputURL = nil
    currentScenePlan = nil
    completedResults = []
    selectedResultCall = nil
    selectedCompletedPreview = nil
  }

  private static func pipelineURL(_ url: URL) -> URL {
    guard !url.path.isEmpty else { return url }
    return url.lastPathComponent.hasSuffix(".pixpipeline.json")
      ? url
      : url.appendingPathExtension("pixpipeline.json")
  }

  private static func newNativeNodeDocument(zImage: Bool = false) -> PipelineDocument {
    let promptID = PipelineNodeID(rawValue: "prompt")
    let seedID = PipelineNodeID(rawValue: "seed")
    let generationID = PipelineNodeID(rawValue: zImage ? "z-image-generate" : "flux2-generate")
    let outputID = PipelineNodeID(rawValue: "output")
    let prompt = PipelineNode(
      id: promptID, kind: .promptInput, title: "Prompt",
      parameters: ["value": .string(defaultPrompt)])
    let seed = PipelineNode(id: seedID, kind: .seedInput, title: "Seed")
    let generation = zImage
      ? ZImageCompositeNode.makeNode(id: generationID)
      : FLUX2KleinPipelineFamily.makeCompositeNode(id: generationID)
    let output = PipelineNode(id: outputID, kind: .imageOutput, title: "Image Output")
    func link(
      _ source: PipelineNodeID, _ port: String,
      _ destination: PipelineNodeID, _ input: String
    ) -> PipelineConnection {
      PipelineConnection(
        output: .init(nodeID: source, port: port),
        input: .init(nodeID: destination, port: input))
    }
    return PipelineDocument(
      id: PipelineID(rawValue: UUID().uuidString),
      name: zImage ? "Native Z-Image Node Workflow" : "Native FLUX.2 Node Workflow",
      mode: .textToImage,
      nodes: [prompt, seed, generation, output],
      connections: [
        link(promptID, "prompt", generationID, "prompt"),
        link(seedID, "seed", generationID, "seed"),
        link(generationID, "image", outputID, "image"),
      ],
      primaryOutputNodeIDs: [outputID],
      presentation: PipelinePresentation(nodePositions: [
        promptID.rawValue: .init(x: 40, y: 80),
        seedID.rawValue: .init(x: 40, y: 250),
        generationID.rawValue: .init(x: 330, y: 110),
        outputID.rawValue: .init(x: 660, y: 130),
      ]))
  }

  private var validExecutionSeed: Bool {
    guard let seed = UInt64(seedText) else { return false }
    guard let profile = executionProfile else { return false }
    return profile.maximumSeed.map { seed <= $0 } ?? true
  }

  private var executionSeedSource: ExecutionSeedSource? {
    if !isNativeNodeExecution {
      return UInt64(seedText).map(ExecutionSeedSource.fixed)
    }
    if let node = document.nodes.first(where: { node in
      node.kind == .seedInput && node.executionState == .enabled
        && document.connections.contains { connection in
          connection.output.nodeID == node.id && connection.output.port == "seed"
        }
    }) {
      return seedSource(for: node.id)
    }
    if let node = document.nodes.first(where: {
      $0.kind == CoreAITextPipelineFamily.compositeNodeKind
        && $0.executionState == .enabled
    }) {
      let value: Int64
      if case .integer(let saved)? = node.parameters["seed"] {
        value = saved
      } else {
        value = 0
      }
      guard value >= 0 else { return nil }
      return .fixed(UInt64(value))
    }
    return nil
  }

  private func seedSource(for nodeID: PipelineNodeID) -> ExecutionSeedSource? {
    guard let node = document.nodes.first(where: {
      $0.id == nodeID && $0.kind == .seedInput && $0.executionState == .enabled
    }) else { return nil }
    let mode: String
    if case .string(let saved)? = node.parameters["mode"] {
      mode = saved
    } else {
      mode = "fixed"
    }
    if mode == "random" { return .random }
    guard mode == "fixed" else { return nil }
    let value: Int64
    if case .integer(let saved)? = node.parameters["value"] {
      value = saved
    } else {
      value = 0
    }
    guard value >= 0 else { return nil }
    return .fixed(UInt64(value))
  }

  private func applyExecutionDefaults(from profile: PipelineExecutionProfile) {
    let invocation = PipelineInvocation(values: profile.defaultInvocation)
    if let defaultSteps = try? invocation.integer(for: PipelineInvocation.stepsKey) {
      steps = defaultSteps
    }
    if let defaultGuidance = try? invocation.number(for: PipelineInvocation.guidanceKey) {
      guidance = defaultGuidance
    }
    if let defaultSystemPrompt = try? invocation.string(
      for: PipelineInvocation.systemPromptKey)
    {
      systemPrompt = defaultSystemPrompt
    }
    if let defaultMaximumResponseTokens = try? invocation.integer(
      for: PipelineInvocation.maximumResponseTokensKey)
    {
      maximumResponseTokens = defaultMaximumResponseTokens
    }
    if let defaultTemperature = try? invocation.number(
      for: PipelineInvocation.temperatureKey)
    {
      temperature = defaultTemperature
    }
    if let defaultTopK = try? invocation.integer(for: PipelineInvocation.topKKey) {
      topK = defaultTopK
    }
    if let defaultPrompt = try? invocation.string(for: PipelineInvocation.promptKey),
      !defaultPrompt.isEmpty
    {
      prompt = defaultPrompt
    }
  }


}

enum PipelineEditorError: Error, LocalizedError {
  case saveDestinationRequired
  case cannotEncodeGeneratedOutput
  case generatedOutputUnavailable
  case feedbackUnavailable
  case imageFeedbackTextUnavailable
  case stateCheckpointTooLarge

  var errorDescription: String? {
    switch self {
    case .saveDestinationRequired:
      "Choose where to save the pipeline."
    case .cannotEncodeGeneratedOutput:
      "The generated image could not be encoded as a PNG."
    case .generatedOutputUnavailable:
      "The generated output file is no longer available. Run the pipeline again."
    case .feedbackUnavailable:
      "The previous output cannot feed the selected input. The loop stopped."
    case .stateCheckpointTooLarge:
      "State checkpoints must be at most 64 KiB."
    case .imageFeedbackTextUnavailable:
      "The image output did not carry feedbackText into the loop. The loop stopped."
    }
  }
}

import Foundation
import PixeltjeModelDesign
import Metal
import PixeltjePipelineDomain

public struct PipelineEngineSnapshot: Equatable, Sendable {
  public var engineVersion: Int
  public var deviceName: String
  public var nodeKinds: [PipelineNodeKind]
  public var executableNodeKinds: [PipelineNodeKind]

  public init(
    engineVersion: Int,
    deviceName: String,
    nodeKinds: [PipelineNodeKind],
    executableNodeKinds: [PipelineNodeKind] = []
  ) {
    self.engineVersion = engineVersion
    self.deviceName = deviceName
    self.nodeKinds = nodeKinds
    self.executableNodeKinds = executableNodeKinds
  }
}

public struct PipelineLinkedResourceRequirement: Equatable, Sendable {
  public var nodeID: PipelineNodeID
  public var slot: String
  public var reference: PipelineResourceReference

  public init(
    nodeID: PipelineNodeID,
    slot: String,
    reference: PipelineResourceReference
  ) {
    self.nodeID = nodeID
    self.slot = slot
    self.reference = reference
  }
}

/// Immutable output of graph validation and planning. Model-library resolution,
/// specialization, and execution are deliberately later phases.
public struct PreparedPipeline: Sendable {
  public var document: PipelineDocument
  public var semanticSHA256: String
  public var orderedNodeIDs: [PipelineNodeID]
  public var requiredResources: [PipelineLinkedResourceRequirement]

  public init(
    document: PipelineDocument,
    semanticSHA256: String,
    orderedNodeIDs: [PipelineNodeID],
    requiredResources: [PipelineLinkedResourceRequirement]
  ) {
    self.document = document
    self.semanticSHA256 = semanticSHA256
    self.orderedNodeIDs = orderedNodeIDs
    self.requiredResources = requiredResources
  }
}

public enum PipelineEngineError: Error, LocalizedError, Sendable {
  case metalCommandQueueUnavailable
  case invalidPipeline(PipelineValidationReport)
  case planningFailed(String)
  case unsupportedPipeline(String)
  case invalidInvocation(String)
  case modelPackageUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .metalCommandQueueUnavailable:
      "Metal could not create the command queue required by Core AI."
    case .invalidPipeline(let report):
      report.errors.first?.message ?? "The pipeline is invalid."
    case .planningFailed(let message):
      message
    case .unsupportedPipeline(let message):
      message
    case .invalidInvocation(let message):
      message
    case .modelPackageUnavailable(let message):
      message
    }
  }
}

/// Shared native runtime used by Pixeltje Mac and Pixeltje Pipeline Editor.
/// Non-Sendable Metal and Core AI values never leave this actor.
public actor PixeltjePipelineEngine {
  public static let currentEngineVersion = 1

  private let device: (any MTLDevice)?
  private let commandQueue: (any MTLCommandQueue)?
  private let meshRenderer: PipelineMeshRenderer?
  private let gpuProgram: PipelineGPUProgram?
  private let imageCache: PipelineImageCache
  private let assetCache: PipelineAssetCache
  private let registry: PipelineNodeRegistry
  private let nodeExecutors: [PipelineNodeKind: PipelineNodeExecutor]
  private var cachedPreparedPipeline: PreparedPipeline?
  private var cachedAssetFingerprintGraphSHA256: String?
  private var cachedAssetFingerprints: [PipelineNodeID: String] = [:]
  private struct SceneSwitchSession {
    let runID: UUID?
    let graphSHA256: String
    let nextCallIndex: Int64
    let activeScene: Int
    let sceneFrames: [Int64]
  }
  private var committedSceneSwitches: [PipelineNodeID: SceneSwitchSession] = [:]
  private var pendingSceneSwitches: [PipelineNodeID: SceneSwitchSession] = [:]

  public init(
    device: any MTLDevice,
    commandQueue: any MTLCommandQueue,
    persistentAssetCacheDirectory: URL? = nil,
    additionalNodeDescriptors: [PipelineNodeDescriptor] = [],
    additionalNodeExecutors: [PipelineNodeExecutor] = []
  ) {
    var registry = PipelineNodeRegistry.coreAIV1
    registry.register(ZImageCompositeNode.descriptor())
    for descriptor in additionalNodeDescriptors {
      registry.register(descriptor)
    }
    self.device = device
    self.commandQueue = commandQueue
    let meshRenderer = PipelineMeshRenderer(commandQueue: commandQueue)
    self.meshRenderer = meshRenderer
    let gpuProgram = PipelineGPUProgram(commandQueue: commandQueue)
    self.gpuProgram = gpuProgram
    let imageCache = PipelineImageCache()
    self.imageCache = imageCache
    let assetCache = PipelineAssetCache(
      persistentDirectory: persistentAssetCacheDirectory)
    self.assetCache = assetCache
    let zImagePipeline = ZImageCoreAIPipeline(commandQueue: commandQueue)
    let imageClassifier = PipelineCoreAIImageClassifier(commandQueue: commandQueue)
    self.registry = registry
    var nativeExecutors = Dictionary(
      uniqueKeysWithValues: BuiltInPipelineNodeExecutors.all.map { ($0.kind, $0) })
    nativeExecutors[.zImageGenerate] = ZImageCompositeNode.executor(pipeline: zImagePipeline)
    nativeExecutors[.coreAIImageClassifier] =
      PipelineCoreAIImageClassifier.executor(runner: imageClassifier)
    nativeExecutors[.renderMetal] = PipelineMeshRenderer.executor(renderer: meshRenderer)
    nativeExecutors[.gpuProgram] = PipelineGPUProgram.executor(runner: gpuProgram)
    nativeExecutors[.imageCache] = PipelineImageCache.executor(cache: imageCache)
    nativeExecutors[.assetCache] = PipelineAssetCache.executor(cache: assetCache)
    for executor in additionalNodeExecutors { nativeExecutors[executor.kind] = executor }
    self.nodeExecutors = nativeExecutors
  }

  /// A CLI host can run model-free node graphs without Metal.
  public init(
    persistentAssetCacheDirectory: URL? = nil,
    additionalNodeDescriptors: [PipelineNodeDescriptor] = [],
    additionalNodeExecutors: [PipelineNodeExecutor] = []
  ) {
    var registry = PipelineNodeRegistry.coreAIV1
    registry.register(ZImageCompositeNode.descriptor())
    for descriptor in additionalNodeDescriptors {
      registry.register(descriptor)
    }
    device = nil
    commandQueue = nil
    meshRenderer = nil
    gpuProgram = nil
    let imageCache = PipelineImageCache()
    self.imageCache = imageCache
    let assetCache = PipelineAssetCache(
      persistentDirectory: persistentAssetCacheDirectory)
    self.assetCache = assetCache
    self.registry = registry
    var nativeExecutors = Dictionary(
      uniqueKeysWithValues: BuiltInPipelineNodeExecutors.all.map { ($0.kind, $0) })
    nativeExecutors[.imageCache] = PipelineImageCache.executor(cache: imageCache)
    nativeExecutors[.assetCache] = PipelineAssetCache.executor(cache: assetCache)
    for executor in additionalNodeExecutors { nativeExecutors[executor.kind] = executor }
    nodeExecutors = nativeExecutors
  }

  public static func makeDefault(
    persistentAssetCacheDirectory: URL? = nil,
    additionalNodeDescriptors: [PipelineNodeDescriptor] = [],
    additionalNodeExecutors: [PipelineNodeExecutor] = []
  ) throws -> PixeltjePipelineEngine {
    guard let device = MTLCreateSystemDefaultDevice(),
      let commandQueue = device.makeCommandQueue()
    else { throw PipelineEngineError.metalCommandQueueUnavailable }
    return PixeltjePipelineEngine(
      device: device,
      commandQueue: commandQueue,
      persistentAssetCacheDirectory: persistentAssetCacheDirectory,
      additionalNodeDescriptors: additionalNodeDescriptors,
      additionalNodeExecutors: additionalNodeExecutors)
  }

  public func snapshot() -> PipelineEngineSnapshot {
    _ = commandQueue
    return PipelineEngineSnapshot(
      engineVersion: Self.currentEngineVersion,
      deviceName: device?.name ?? "No Metal device",
      nodeKinds: registry.allDescriptors.map(\.kind),
      executableNodeKinds: nodeExecutors.keys.sorted { $0.rawValue < $1.rawValue })
  }

  /// Enables bounded, per-call GPU timing only while an editor log is active.
  public func setGPUProgramPerformanceCapture(runID: UUID?) async {
    await gpuProgram?.setPerformanceCapture(runID: runID)
  }

  public nonisolated func takeGPUProgramPerformance(
    runID: UUID
  ) -> PipelineGPUProgramPerformance? {
    gpuProgram?.takePerformance(runID: runID)
  }

  /// Transient editor preview state; it never changes graph execution or saved output.
  public func beginLiveMetalPreview(runID: UUID, nodeID: PipelineNodeID) async {
    await meshRenderer?.beginLivePreview(runID: runID, nodeID: nodeID)
    await gpuProgram?.beginLivePreview(runID: runID, nodeID: nodeID)
  }

  /// Updates only the transient pointer used by a direct GPU Program preview.
  /// Saved and replayed graph calls continue to use their invocation values.
  public func updateLiveGPUProgramPointer(runID: UUID, nodeID: PipelineNodeID,
    revision: UInt64, x: Double, y: Double, actionCount: Int,
    secondaryActionCount: Int = 0) async {
    await gpuProgram?.updateLivePointer(runID: runID, nodeID: nodeID,
      revision: revision, x: x, y: y, actionCount: actionCount,
      secondaryActionCount: secondaryActionCount)
  }

  public func liveMetalPreview(runID: UUID) async throws -> PipelineMetalPreviewFrame? {
    if let frame = await gpuProgram?.livePreview(runID: runID) { return frame }
    return try await meshRenderer?.renderLivePreview(runID: runID)
  }

  /// Evaluates the upstream graph for a direct, unsaved Metal-to-Image Output
  /// preview. The terminal image has no CPU consumer, so rasterization is
  /// deferred to the display refresh path.
  public func updateLiveMetalPreviewState(
    _ document: PipelineDocument, runID: UUID, nodeID: PipelineNodeID,
    sourceMediaRoot: URL? = nil,
    packageRootsByID: [String: URL], invocation: PipelineInvocation,
    progress: @escaping PipelineExecutionProgressHandler = { _ in }
  ) async throws -> PipelineExecutionOutput {
    guard document.requirements.familyABIs.isEmpty else {
      throw PipelineEngineError.unsupportedPipeline(
        "Workflow-family ABIs are no longer executable; use native node graphs.")
    }
    let selected = selectedOutputNode(in: document)
    let terminalInputs = document.connections.filter { $0.input.nodeID == selected?.id }
    let previewNode = document.nodes.first { $0.id == nodeID }
    let directMetal = previewNode.map {
      $0.kind == .renderMetal || $0.kind == .gpuProgram
    } ?? false
    let switchedMetal = previewNode?.kind == .sceneSwitch
      && (0..<Int(previewNode?.parameters["sceneCount"]?.integerValue ?? 2))
        .allSatisfy { index in
          document.connections.contains { connection in
            connection.input == .init(nodeID: nodeID, port: "scene\(index)")
              && connection.output.port == "image"
              && document.nodes.contains {
                $0.id == connection.output.nodeID && $0.kind == .gpuProgram
              }
          }
        }
    guard meshRenderer != nil || gpuProgram != nil,
      let output = selected, output.kind == .imageOutput,
      document.connections.contains(where: {
        $0.output == .init(nodeID: nodeID, port: "image")
          && $0.input == .init(nodeID: output.id, port: "image")
      }),
      terminalInputs.allSatisfy({
        $0.output == .init(nodeID: nodeID, port: "image")
          && $0.input.port == "image"
      }),
      previewNode?.executionState == .enabled,
      directMetal || switchedMetal else {
      throw PipelineEngineError.invalidInvocation(
        "Live Metal preview needs a direct Metal node or Scene Switch to Image Output.")
    }
    let prepared = try prepare(document)
    do {
      let previewOutput = try await executeNodeGraph(prepared,
        sourceMediaRoot: sourceMediaRoot,
        packageRootsByID: packageRootsByID, invocation: invocation,
        progress: progress, trace: nil, traceRunID: runID, traceCall: 1,
        livePreviewTarget: (runID, nodeID))
      await gpuProgram?.commit(runID: runID)
      commitSceneSwitches(runID: runID)
      return previewOutput
    } catch {
      await gpuProgram?.discard(runID: runID)
      discardSceneSwitches(runID: runID)
      throw error
    }
  }

  public func endLiveMetalPreview(runID: UUID) async {
    await meshRenderer?.endLivePreview(runID: runID)
    await gpuProgram?.endLivePreview(runID: runID)
    await imageCache.end(runID: runID)
    await assetCache.end(runID: runID)
  }

  /// Audio requested by the last successfully committed live GPU frame.
  public func takeLiveMetalAudioEvents(runID: UUID) async -> [URL] {
    await gpuProgram?.takeLiveAudioEvents(runID: runID) ?? []
  }

  public func clearCachedAssets(for nodeID: PipelineNodeID,
    documentID: PipelineID? = nil) async {
    await assetCache.clear(nodeID, documentID: documentID?.rawValue)
  }

  public func clearAllCachedAssets() async {
    await assetCache.clearAll()
  }

  public func discardCachedAssetsInMemory() async {
    await assetCache.clearInMemory()
  }

  public func executionProfile(for document: PipelineDocument) -> PipelineExecutionProfile? {
    if document.requirements.familyABIs.isEmpty {
      let outputKind = detectedOutputKind(in: document)
      var profile = PipelineExecutionProfile(
        identifier: "org.pixeltje.pipeline.nodes",
        displayName: "Native nodes",
        supportedModes: [document.mode],
        defaultPackageURL: FileManager.default.homeDirectoryForCurrentUser,
        outputKind: outputKind)
      if let generation = document.nodes.first(where: {
        $0.kind.rawValue == "coreai.textGenerate"
      }) {
        profile.defaultInvocation = [
          PipelineInvocation.systemPromptKey: .string(
            generation.parameters["systemPrompt"]?.stringValue ?? ""),
          PipelineInvocation.maximumResponseTokensKey: .integer(
            generation.parameters["maxTokens"]?.integerValue ?? 256),
          PipelineInvocation.temperatureKey: .number(
            generation.parameters["temperature"]?.numberValue ?? 0.7),
          PipelineInvocation.topKKey: .integer(
            generation.parameters["topK"]?.integerValue ?? 40),
        ]
        profile.editableInvocationKeys = [
          PipelineInvocation.systemPromptKey,
          PipelineInvocation.maximumResponseTokensKey,
          PipelineInvocation.temperatureKey,
          PipelineInvocation.topKKey,
          PipelineInvocation.seedKey,
        ]
      }
      if let savedPrompt = document.nodes.first(where: { $0.kind == .promptInput })?
        .parameters["value"]?.stringValue, !savedPrompt.isEmpty {
        profile.defaultInvocation[PipelineInvocation.promptKey] = .string(savedPrompt)
      }
      return profile
    }
    return nil
  }

  public func inspectPackage(
    for document: PipelineDocument,
    at packageRoot: URL
  ) async throws -> PipelinePackageInspectionReport {
    let prepared = try prepare(document)
    if document.requirements.familyABIs.isEmpty {
      let reachable = executionNodeIDs(in: document)
      let required = prepared.requiredResources.filter { reachable.contains($0.nodeID) }
      let missingMedia = document.nodes.filter { reachable.contains($0.id) }
        .compactMap { node -> String? in
          if node.kind == .renderMetal,
            let fileConnection = document.connections.first(where: {
              $0.input.nodeID == node.id && $0.input.port == "sourceFile"
            }),
            let sourceNode = document.nodes.first(where: {
              $0.id == fileConnection.output.nodeID
            }),
            (sourceNode.kind == .primitiveString
              || sourceNode.kind == .primitiveFilePath),
            !document.connections.contains(where: {
              $0.input.nodeID == sourceNode.id && $0.input.port == "value"
            }),
            case .string(let name)? = sourceNode.parameters[
              sourceNode.kind == .primitiveFilePath ? "path" : "value"], !name.isEmpty {
            guard !name.contains("/"), !name.contains("\\"),
              name.hasSuffix(".metal") else { return name }
            return FileManager.default.fileExists(
              atPath: packageRoot.appendingPathComponent(name).path) ? nil : name
          }
          guard ["input.image", "input.maskImage", "input.video", "input.audio"]
            .contains(node.kind.rawValue),
            case .string(let name)? = node.parameters["sourceName"], !name.isEmpty
          else { return nil }
          return FileManager.default.fileExists(
            atPath: packageRoot.appendingPathComponent(name).path) ? nil : name
        }
      return PipelinePackageInspectionReport(
        adapterIdentifier: "org.pixeltje.pipeline.nodes",
        packageRoot: packageRoot,
        isUsable: required.isEmpty && missingMedia.isEmpty,
        summary: !required.isEmpty
          ? "Inspect linked model packages by package identity."
          : missingMedia.isEmpty ? "Native nodes are ready." : "Source media is missing.",
        missingComponents: required.map { $0.reference.packageID } + missingMedia)
    }
    throw PipelineEngineError.unsupportedPipeline(
      "Workflow-family ABIs are no longer executable; use native node graphs.")
  }

  /// Executes a graph through its installed node implementations. Resource
  /// locations are transient host state; graph files retain only identities.
  public func execute(
    _ document: PipelineDocument,
    sourceMediaRoot: URL? = nil,
    packageRootsByID: [String: URL],
    invocation: PipelineInvocation,
    progress: @escaping PipelineExecutionProgressHandler = { _ in },
    trace: PipelineTraceHandler? = nil,
    traceRunID: UUID? = nil,
    traceCall: Int = 1
  ) async throws -> PipelineExecutionOutput {
    guard document.requirements.familyABIs.isEmpty else {
      throw PipelineEngineError.unsupportedPipeline(
        "Workflow-family ABIs are no longer executable; use native node graphs.")
    }
    let prepared = try prepare(document)
    do {
      let output = try await executeNodeGraph(
        prepared,
        sourceMediaRoot: sourceMediaRoot,
        packageRootsByID: packageRootsByID,
        invocation: invocation,
        progress: progress,
        trace: trace, traceRunID: traceRunID, traceCall: traceCall)
      if invocation[PipelineInvocation.gpuProgramDeferredCommitKey] != .boolean(true) {
        await gpuProgram?.commit(runID: traceRunID)
        commitSceneSwitches(runID: traceRunID)
      }
      return output
    } catch {
      await gpuProgram?.discard(runID: traceRunID)
      discardSceneSwitches(runID: traceRunID)
      throw error
    }
  }

  /// Called by a host after saving and publishing the frame from a deferred run.
  public func commitGPUProgramFrame(runID: UUID) async {
    await gpuProgram?.commit(runID: runID)
    commitSceneSwitches(runID: runID)
  }

  public func discardGPUProgramFrame(runID: UUID) async {
    await gpuProgram?.discard(runID: runID)
    discardSceneSwitches(runID: runID)
  }

  private func commitSceneSwitches(runID: UUID?) {
    for (nodeID, session) in pendingSceneSwitches where session.runID == runID {
      committedSceneSwitches[nodeID] = session
      pendingSceneSwitches[nodeID] = nil
    }
  }

  private func discardSceneSwitches(runID: UUID?) {
    pendingSceneSwitches = pendingSceneSwitches.filter { $0.value.runID != runID }
  }

  public func validate(_ document: PipelineDocument) -> PipelineValidationReport {
    var report = PipelineGraphValidator.validate(
      document,
      registry: registry,
      engineVersion: Self.currentEngineVersion)
    for node in document.nodes where node.kind == .modelTrain
      && node.executionState == .enabled {
      do {
        _ = try ModelWorkflowBridge.design(in: document, for: node.id)
      } catch {
        report.diagnostics.append(.init(
          severity: .error, code: .invalidParameter,
          message: error.localizedDescription, nodeID: node.id))
      }
    }
    report.diagnostics.append(contentsOf: imageCacheDiagnostics(in: document))
    if !document.requirements.familyABIs.isEmpty {
      report.diagnostics.append(.init(
        severity: .error, code: .unsupportedNodeImplementation,
        message: "Workflow-family ABIs are no longer executable; use native node graphs."))
    }
    let reachable = executionNodeIDs(in: document)
    for node in document.nodes where reachable.contains(node.id) {
      if node.kind == .renderMetal, node.executionState == .enabled {
        let connected = Set(document.connections.filter { $0.input.nodeID == node.id }
          .map(\.input.port))
        let geometryPorts = ["mesh", "viewMatrix", "projectionMatrix"]
        if connected.contains("state") {
          if geometryPorts.contains(where: connected.contains) {
            report.diagnostics.append(.init(
              severity: .error, code: .incompatiblePorts,
              message: "Metal Render shader state cannot be combined with mesh, view or projection inputs.",
              nodeID: node.id))
          }
          if connected.contains("source") == connected.contains("sourceFile") {
            report.diagnostics.append(.init(
              severity: .error, code: .missingInput,
              message: "Metal Render shader mode needs exactly one Source or Source File connection.",
              nodeID: node.id))
          }
        } else {
          if connected.contains("source") || connected.contains("sourceFile") {
            report.diagnostics.append(.init(
              severity: .error, code: .incompatiblePorts,
              message: "Metal Render source is only available with shader state.",
              nodeID: node.id))
          }
          for port in geometryPorts where !connected.contains(port) {
            report.diagnostics.append(.init(
              severity: .error, code: .missingInput,
              message: "Metal Render mesh mode requires \(port), or connect shader state.",
              nodeID: node.id))
          }
        }
      }
      if node.kind == .gpuProgram, node.executionState == .enabled {
        let connected = Set(document.connections.filter { $0.input.nodeID == node.id }
          .map(\.input.port))
        if connected.contains("source") == connected.contains("sourceFile") {
          report.diagnostics.append(.init(
            severity: .error, code: .missingInput,
            message: "GPU Program needs exactly one Source or Source File connection.",
            nodeID: node.id))
        }
      }
      if node.executionState != .enabled {
        report.diagnostics.append(.init(
          severity: .error, code: .unsupportedNodeImplementation,
          message: "Node \(node.id.rawValue) is \(node.executionState.rawValue); native execution requires an enabled node.",
          nodeID: node.id))
      } else if nodeExecutors[node.kind] == nil {
        report.diagnostics.append(.init(
          severity: .error, code: .unsupportedNodeImplementation,
          message: "Node \(node.id.rawValue) (\(node.kind.rawValue)) has no installed Swift executor.",
          nodeID: node.id))
      } else if let executor = nodeExecutors[node.kind] {
        report.diagnostics.append(contentsOf: executor.validate(node))
      }
    }
    return report
  }

  private func imageCacheDiagnostics(in document: PipelineDocument) -> [PipelineDiagnostic] {
    let nodes = document.nodes.filter {
      $0.kind == .imageCache && $0.executionState == .enabled
    }
    let incoming = Dictionary(grouping: document.connections, by: \.input.nodeID)
    var writers: [String: PipelineNodeID] = [:]
    var diagnostics: [PipelineDiagnostic] = []
    for node in nodes {
      let key = node.parameters["key"]?.stringValue ?? ""
      let mode = node.parameters["mode"]?.stringValue ?? "store"
      let hasImage = (incoming[node.id] ?? []).contains { $0.input.port == "image" }
      if mode == "store" {
        if !hasImage {
          diagnostics.append(.init(severity: .error, code: .invalidParameter,
            message: "Image Cache store \(key) needs an image connection.", nodeID: node.id))
        }
        if writers.updateValue(node.id, forKey: key) != nil {
          diagnostics.append(.init(severity: .error, code: .invalidParameter,
            message: "Image Cache key \(key) has more than one store.", nodeID: node.id))
        }
      } else if mode == "load" && hasImage {
        diagnostics.append(.init(severity: .error, code: .invalidParameter,
          message: "Image Cache load \(key) cannot take an image connection.", nodeID: node.id))
      }
    }
    for node in nodes where node.parameters["mode"]?.stringValue == "load" {
      let key = node.parameters["key"]?.stringValue ?? ""
      if writers[key] == nil {
        diagnostics.append(.init(severity: .error, code: .invalidParameter,
          message: "Image Cache load \(key) has no store in this workflow.", nodeID: node.id))
      }
    }
    for node in nodes where (node.parameters["mode"]?.stringValue ?? "store") == "store" {
      let ancestors = reachableNodeIDs(from: node.id, in: document)
      if nodes.contains(where: {
        ancestors.contains($0.id) && $0.parameters["mode"]?.stringValue == "load"
      }) {
        diagnostics.append(.init(severity: .error, code: .invalidParameter,
          message: "Image Cache stores cannot depend on cache loads.", nodeID: node.id))
      }
    }
    return diagnostics
  }

  /// Extends graph validation with Metal compilation when shader inputs are
  /// literal graph values. The source folder is transient host state.
  public func validate(
    _ document: PipelineDocument, sourceMediaRoot: URL?
  ) async -> PipelineValidationReport {
    var report = validate(document)
    guard report.isValid else { return report }
    let reachable = executionNodeIDs(in: document)
    for node in document.nodes where node.kind == .renderMetal
      && node.executionState == .enabled && reachable.contains(node.id) {
      guard let meshRenderer else { continue }
      if Task.isCancelled { return report }
      guard let stateConnection = document.connections.first(where: {
        $0.input.nodeID == node.id && $0.input.port == "state"
      }) else { continue } // Mesh mode has no workflow-supplied shader.
      guard let stateJSON = literalString(
        from: stateConnection.output, in: document,
        sourceKind: .stateInput, parameter: "initialState") else {
        report.diagnostics.append(.init(
          severity: .warning, code: .shaderNotChecked,
          message: "Metal shader compilation was not checked because its state is computed by the graph.",
          nodeID: node.id))
        continue
      }
      let state: PipelineMetalShaderState
      do {
        state = try PipelineMetalShaderState(json: stateJSON)
      } catch {
        report.diagnostics.append(.init(
          severity: .error, code: .invalidShader,
          message: "Metal shader state: \(error.localizedDescription)", nodeID: node.id))
        continue
      }
      guard let sourceConnection = document.connections.first(where: {
        $0.input.nodeID == node.id
          && ($0.input.port == "source" || $0.input.port == "sourceFile")
      }), let literalResult = literalShaderSource(
        from: sourceConnection, in: document, sourceMediaRoot: sourceMediaRoot) else {
        report.diagnostics.append(.init(
          severity: .warning, code: .shaderNotChecked,
          message: "Metal shader compilation was not checked because its source is computed by the graph.",
          nodeID: node.id))
        continue
      }
      let literal: String
      switch literalResult {
      case .success(let value): literal = value
      case .failure(let error):
        report.diagnostics.append(.init(severity: .error, code: .invalidShader,
          message: "Metal shader source could not be read: \(error.localizedDescription)",
          nodeID: node.id))
        continue
      }
      if sourceConnection.input.port == "sourceFile" && sourceMediaRoot == nil {
        report.diagnostics.append(.init(
          severity: .warning, code: .shaderNotChecked,
          message: "Metal shader compilation needs the workflow's source folder to read its .metal file.",
          nodeID: node.id))
        continue
      }
      do {
        let source = try PipelineMeshRenderer.shaderSource(
          supplied: sourceConnection.input.port == "source" ? literal : nil,
          fileName: sourceConnection.input.port == "sourceFile" ? literal : nil,
          sourceMediaRoot: sourceMediaRoot)
        try await meshRenderer.validateShader(
          source: source, fragmentFunction: state.fragmentFunction)
      } catch {
        report.diagnostics.append(.init(
          severity: .error, code: .invalidShader,
          message: "Metal shader compilation failed: \(error.localizedDescription)",
          nodeID: node.id))
      }
    }
    for node in document.nodes where node.kind == .gpuProgram
      && node.executionState == .enabled && reachable.contains(node.id) {
      guard let gpuProgram else { continue }
      let links = document.connections.filter { $0.input.nodeID == node.id }
      guard let programLink = links.first(where: { $0.input.port == "program" }),
        let programJSON = literalString(from: programLink.output, in: document,
          sourceKind: .primitiveString, parameter: "value"),
        let sourceLink = links.first(where: {
          $0.input.port == "source" || $0.input.port == "sourceFile"
        }), let literalResult = literalShaderSource(
          from: sourceLink, in: document, sourceMediaRoot: sourceMediaRoot) else {
        report.diagnostics.append(.init(severity: .warning, code: .shaderNotChecked,
          message: "GPU Program compilation was not checked because its inputs are computed by the graph.",
          nodeID: node.id))
        continue
      }
      let literal: String
      switch literalResult {
      case .success(let value): literal = value
      case .failure(let error):
        report.diagnostics.append(.init(severity: .error, code: .invalidShader,
          message: "GPU Program source could not be read: \(error.localizedDescription)",
          nodeID: node.id))
        continue
      }
      if sourceLink.input.port == "sourceFile" && sourceMediaRoot == nil {
        report.diagnostics.append(.init(severity: .warning, code: .shaderNotChecked,
          message: "GPU Program compilation needs the workflow source folder.",
          nodeID: node.id))
        continue
      }
      do {
        let source = try PipelineMeshRenderer.shaderSource(
          supplied: sourceLink.input.port == "source" ? literal : nil,
          fileName: sourceLink.input.port == "sourceFile" ? literal : nil,
          sourceMediaRoot: sourceMediaRoot)
        try await gpuProgram.validateLiteral(programJSON: programJSON, source: source)
      } catch {
        report.diagnostics.append(.init(severity: .error, code: .invalidShader,
          message: "GPU Program validation failed: \(error.localizedDescription)",
          nodeID: node.id))
      }
    }
    return report
  }

  private func literalString(
    from output: PipelinePortReference, in document: PipelineDocument,
    sourceKind: PipelineNodeKind, parameter: String
  ) -> String? {
    guard let source = document.nodes.first(where: { $0.id == output.nodeID }),
      source.kind == sourceKind,
      output.port == (sourceKind == .stateInput ? "state" : "value"),
      !document.connections.contains(where: {
        $0.input.nodeID == source.id && $0.input.port == output.port
      }) else { return nil }
    return source.parameters[parameter]?.stringValue
      ?? (sourceKind == .stateInput ? "{}" : "")
  }

  private func literalShaderSource(
    from connection: PipelineConnection, in document: PipelineDocument,
    sourceMediaRoot: URL?
  ) -> Result<String, Error>? {
    if let source = document.nodes.first(where: {
      $0.id == connection.output.nodeID
    }), source.kind == .primitiveFilePath {
      if connection.input.port == "sourceFile", connection.output.port == "value" {
        return Result { try PipelineFilePath.value(from: source) }
      }
      if connection.input.port == "source", connection.output.port == "contents" {
        if sourceMediaRoot == nil,
          (source.parameters["mode"]?.stringValue ?? "relative") == "relative" {
          return nil
        }
        return Result {
          try PipelineFilePath.contents(from: source, sourceRoot: sourceMediaRoot)
        }
      }
    }
    return literalString(from: connection.output, in: document,
      sourceKind: .primitiveString, parameter: "value").map(Result.success)
  }

  public func prepare(_ document: PipelineDocument) throws -> PreparedPipeline {
    if let cachedPreparedPipeline, cachedPreparedPipeline.document == document {
      return cachedPreparedPipeline
    }
    let report = validate(document)
    guard report.isValid else { throw PipelineEngineError.invalidPipeline(report) }
    let orderedNodeIDs: [PipelineNodeID]
    do {
      orderedNodeIDs = try PipelineGraphTopology.orderedNodeIDs(in: document)
    } catch {
      throw PipelineEngineError.planningFailed("Pipeline connections contain a cycle.")
    }
    let requiredResources = document.nodes.flatMap { node in
      node.resources.keys.sorted().compactMap { slot in
        node.resources[slot]?.linkedReference.map {
          PipelineLinkedResourceRequirement(nodeID: node.id, slot: slot, reference: $0)
        }
      }
    }
    let prepared = PreparedPipeline(
      document: document,
      semanticSHA256: try PipelineJSON.semanticSHA256(document),
      orderedNodeIDs: orderedNodeIDs,
      requiredResources: requiredResources)
    cachedPreparedPipeline = prepared
    return prepared
  }

  private func selectedOutputNode(in document: PipelineDocument) -> PipelineNode? {
    PipelineGraphOutputs.selectedOutputNode(in: document, registry: registry)
  }

  private func detectedOutputKind(in document: PipelineDocument) -> PipelineExecutionOutputKind {
    guard let output = selectedOutputNode(in: document),
      let descriptor = registry.descriptor(for: output.kind)
    else { return .none }
    if output.kind == .modelTrain { return .model }
    let incoming = document.connections.filter {
      $0.input.nodeID == output.id
        && (output.kind != .imageOutput || $0.input.port == "image")
    }
    let types: [PipelinePortType] = if incoming.isEmpty {
      descriptor.outputs.map(\.type)
    } else {
      incoming.compactMap { connection in
        guard let source = document.nodes.first(where: {
          $0.id == connection.output.nodeID
        }), let sourceDescriptor = registry.descriptor(for: source.kind)
        else { return nil }
        let sourceType = sourceDescriptor.output(named: connection.output.port)?.type
        return sourceType == .any
          ? descriptor.input(named: connection.input.port)?.type
          : sourceType
      }
    }
    let kinds = Set(types.compactMap { type -> PipelineExecutionOutputKind? in
      switch type {
      case .image, .generatedImage, .mask: .image
      case .string, .prompt: .text
      case .video: .video
      case .audio: .audio
      default: nil
      }
    })
    return kinds.count == 1 ? kinds.first ?? .none : .none
  }

  private func sceneSwitchSelections(
    _ prepared: PreparedPipeline, invocation: PipelineInvocation,
    runID: UUID?
  ) throws -> (callIndex: Int64, scenes: [PipelineNodeID: Int],
    frames: [PipelineNodeID: [Int64]]) {
    let callIndex = try invocation.integer(
      for: PipelineInvocation.loopCallIndexKey, default: 0)
    guard callIndex >= 0 else {
      throw PipelineEngineError.invalidInvocation(
        "Scene Switch call index must be non-negative.")
    }
    var scenes: [PipelineNodeID: Int] = [:]
    var frames: [PipelineNodeID: [Int64]] = [:]
    let relevant = executionNodeIDs(in: prepared.document)
    for node in prepared.document.nodes where node.kind == .sceneSwitch
      && node.executionState == .enabled && relevant.contains(node.id) {
      let initial = Int(node.parameters["initialScene"]?.integerValue ?? 0)
      if callIndex == 0 {
        scenes[node.id] = initial
        frames[node.id] = [Int64](repeating: 0,
          count: Int(node.parameters["sceneCount"]?.integerValue ?? 2))
      } else if let saved = committedSceneSwitches[node.id],
        saved.runID == runID,
        saved.graphSHA256 == prepared.semanticSHA256,
        saved.nextCallIndex == callIndex {
        scenes[node.id] = saved.activeScene
        frames[node.id] = saved.sceneFrames
      } else {
        throw PipelineEngineError.invalidInvocation(
          "Scene Switch needs sequential Loop calls; restart at call zero.")
      }
    }
    return (Int64(callIndex), scenes, frames)
  }

  private func executionNodeIDs(
    in document: PipelineDocument,
    activeScenes: [PipelineNodeID: Int] = [:]
  ) -> Set<PipelineNodeID> {
    if let output = selectedOutputNode(in: document) {
      return includingCacheStoreAncestors(
        executionNodeIDs(for: output, in: document,
          activeScenes: activeScenes), in: document)
    }
    // Without a result sink, evaluate the connected work and discard its
    // transient values. Unconnected output sinks cannot consume any value.
    let disconnectedOutputs = Set(document.nodes.filter { node in
      registry.descriptor(for: node.kind)?.isTerminal == true
        && !document.connections.contains { $0.input.nodeID == node.id }
    }.map(\.id))
    return includingCacheStoreAncestors(Set(document.nodes.filter {
      $0.executionState == .enabled && !disconnectedOutputs.contains($0.id)
    }.map(\.id)), in: document)
  }

  private func includingCacheStoreAncestors(
    _ initial: Set<PipelineNodeID>, in document: PipelineDocument
  ) -> Set<PipelineNodeID> {
    var reachable = initial
    let keys = Set(document.nodes.filter {
      reachable.contains($0.id) && $0.kind == .imageCache
    }.compactMap { $0.parameters["key"]?.stringValue })
    for writer in document.nodes where writer.kind == .imageCache
      && writer.executionState == .enabled
      && (writer.parameters["mode"]?.stringValue ?? "store") == "store"
      && keys.contains(writer.parameters["key"]?.stringValue ?? "") {
      reachable.formUnion(reachableNodeIDs(from: writer.id, in: document))
    }
    return reachable
  }

  private func reachableNodeIDs(
    from outputID: PipelineNodeID, in document: PipelineDocument,
    stopAtCacheStores: Bool = false,
    activeScenes: [PipelineNodeID: Int] = [:]
  ) -> Set<PipelineNodeID> {
    let incoming = Dictionary(grouping: document.connections, by: \.input.nodeID)
    let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
    var pending = [outputID]
    var reachable: Set<PipelineNodeID> = []
    while let nodeID = pending.popLast() {
      guard reachable.insert(nodeID).inserted else { continue }
      if stopAtCacheStores, let node = nodes[nodeID],
        node.kind == .assetCache || (node.kind == .imageCache &&
          (node.parameters["mode"]?.stringValue ?? "store") == "store") {
        continue
      }
      let edges = (incoming[nodeID] ?? []).filter { edge in
        guard let active = activeScenes[nodeID],
          nodes[nodeID]?.kind == .sceneSwitch else { return true }
        return edge.input.port == "scene\(active)"
          || edge.input.port == "request\(active)"
      }
      pending.append(contentsOf: edges.map(\.output.nodeID))
    }
    return reachable
  }

  private func executionNodeIDs(
    for output: PipelineNode, in document: PipelineDocument,
    activeScenes: [PipelineNodeID: Int] = [:]
  ) -> Set<PipelineNodeID> {
    var reachable = reachableNodeIDs(from: output.id, in: document,
      activeScenes: activeScenes)
    // Preview sinks are observable graph results even when they do not feed
    // the primary output. Their producers must run in the same evaluation.
    for preview in document.nodes where preview.executionState == .enabled
      && (preview.kind == .imagePreview || preview.kind == .videoPreview) {
      reachable.formUnion(reachableNodeIDs(from: preview.id, in: document,
        activeScenes: activeScenes))
    }
    return reachable
  }

  private func executeNodeGraph(
    _ prepared: PreparedPipeline,
    sourceMediaRoot: URL?,
    packageRootsByID: [String: URL],
    invocation: PipelineInvocation,
    progress: @escaping PipelineExecutionProgressHandler,
    trace: PipelineTraceHandler?,
    traceRunID: UUID?,
    traceCall: Int,
    livePreviewTarget: (runID: UUID, nodeID: PipelineNodeID)? = nil
  ) async throws -> PipelineExecutionOutput {
    let document = prepared.document
    let outputNode = selectedOutputNode(in: document)
    let runID = traceRunID ?? UUID()
    let switchState = try sceneSwitchSelections(prepared,
      invocation: invocation, runID: traceRunID)
    let activeScenes = switchState.scenes
    await imageCache.begin(runID: runID, graphSHA256: prepared.semanticSHA256)
    let retainedAssetNodes = Set(document.nodes.filter {
      $0.kind == .assetCache && $0.executionState == .enabled
        && $0.parameters["keepBetweenRuns"] == .boolean(true)
    }.map(\.id))
    let assetCacheFingerprints: [PipelineNodeID: String]
    if cachedAssetFingerprintGraphSHA256 == prepared.semanticSHA256 {
      assetCacheFingerprints = cachedAssetFingerprints
    } else {
      assetCacheFingerprints = try Dictionary(uniqueKeysWithValues:
        document.nodes.filter { $0.kind == .assetCache }.map { node in
          (node.id, try PipelineJSON.assetCacheSHA256(document, nodeID: node.id))
        })
      cachedAssetFingerprintGraphSHA256 = prepared.semanticSHA256
      cachedAssetFingerprints = assetCacheFingerprints
    }
    await assetCache.begin(runID: runID, documentID: document.id.rawValue,
      fingerprintsByNodeID: assetCacheFingerprints,
      retainedNodeIDs: retainedAssetNodes)
    let baseReachable = executionNodeIDs(in: document,
      activeScenes: activeScenes)
    let cacheNodes = document.nodes.filter { $0.kind == .imageCache &&
      $0.executionState == .enabled }
    let stores = Dictionary(uniqueKeysWithValues: cacheNodes.filter {
      ($0.parameters["mode"]?.stringValue ?? "store") == "store"
    }.compactMap { node -> (String, PipelineNodeID)? in
      node.parameters["key"]?.stringValue.map { ($0, node.id) }
    })
    let neededKeys = Set(cacheNodes.filter { baseReachable.contains($0.id) }
      .compactMap { $0.parameters["key"]?.stringValue })
    var preflight: Set<PipelineNodeID> = []
    for key in neededKeys.sorted() where !(await imageCache.contains(key)) {
      guard let writer = stores[key] else {
        throw PipelineEngineError.planningFailed("Image Cache has no store for \(key).")
      }
      preflight.formUnion(reachableNodeIDs(from: writer, in: document,
        activeScenes: activeScenes))
    }
    for node in document.nodes where node.kind == .assetCache
      && node.executionState == .enabled && baseReachable.contains(node.id) {
      if !(await assetCache.contains(node.id)) {
        preflight.formUnion(reachableNodeIDs(from: node.id, in: document,
          activeScenes: activeScenes))
      }
    }
    var mainReachable: Set<PipelineNodeID> = []
    if let outputNode {
      mainReachable = reachableNodeIDs(from: outputNode.id, in: document,
        stopAtCacheStores: true, activeScenes: activeScenes)
      for preview in document.nodes where preview.executionState == .enabled &&
        (preview.kind == .imagePreview || preview.kind == .videoPreview) {
        mainReachable.formUnion(reachableNodeIDs(from: preview.id, in: document,
          stopAtCacheStores: true, activeScenes: activeScenes))
      }
    } else {
      mainReachable = baseReachable
    }
    let reachable = preflight.union(mainReachable)
    for requirement in prepared.requiredResources
    where reachable.contains(requirement.nodeID)
      && packageRootsByID[requirement.reference.packageID] == nil
    {
      throw PipelineEngineError.modelPackageUnavailable(
        "Node \(requirement.nodeID.rawValue) needs package \(requirement.reference.packageID).")
    }
    let preflightOrder = prepared.orderedNodeIDs.filter(preflight.contains)
    let ordered = preflightOrder + prepared.orderedNodeIDs.filter {
      mainReachable.contains($0) && !preflight.contains($0)
    }
    let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
    let incoming = Dictionary(grouping: document.connections, by: \.input.nodeID)
    var values: [PipelinePortReference: PipelineNodeValue] = [:]
    var finalOutput: PipelineExecutionOutput?
    let traceID = traceRunID ?? UUID()

    for (index, nodeID) in ordered.enumerated() {
      try Task.checkCancellation()
      guard let node = nodes[nodeID], let executor = nodeExecutors[node.kind],
        let descriptor = PipelineGraphEditing.descriptor(for: node, registry: registry)
      else {
        throw PipelineEngineError.unsupportedPipeline(
          "Node \(nodeID.rawValue) has no installed Swift executor.")
      }
      let assetCacheIsFilled: Bool
      if node.kind == .assetCache {
        assetCacheIsFilled = await assetCache.contains(nodeID)
      } else {
        assetCacheIsFilled = false
      }
      var inputs: [String: PipelineNodeValue] = [:]
      for connection in incoming[nodeID] ?? [] {
        if assetCacheIsFilled { break }
        if let active = activeScenes[nodeID], node.kind == .sceneSwitch,
          connection.input.port != "scene\(active)",
          connection.input.port != "request\(active)" { continue }
        guard let value = values[connection.output] else {
          if descriptor.input(named: connection.input.port)?.isRequired == false {
            continue
          }
          let message = "Node \(nodeID.rawValue) needs output \(connection.output.port) from \(connection.output.nodeID.rawValue)."
          if let trace {
            await trace(.init(runID: traceID, call: traceCall, workflow: document.name,
              graphSHA256: prepared.semanticSHA256, node: node, phase: "failed",
              inputs: inputs.mapValues { $0.traceValue() }, error: message))
          }
          throw PipelineEngineError.planningFailed(message)
        }
        inputs[connection.input.port] = value
      }
      if let active = activeScenes[nodeID], node.kind == .sceneSwitch {
        inputs["__activeScene"] = PipelineNodeValue(Int64(active), type: .integer)
      }
      await progress(.init(
        stage: .generating, message: node.title ?? node.kind.rawValue,
        completedUnitCount: index, totalUnitCount: ordered.count,
        activeNodeIDs: [nodeID]))
      try Task.checkCancellation()
      var nodeInvocation = invocation
      if node.kind == .gpuProgram,
        let owner = activeScenes.first(where: { entry in
          document.connections.contains {
            $0.output == .init(nodeID: nodeID, port: "image")
              && $0.input == .init(nodeID: entry.key,
                port: "scene\(entry.value)")
          }
        }), let frame = switchState.frames[owner.key]?[owner.value] {
        nodeInvocation.values[PipelineInvocation.loopCallIndexKey] = .integer(frame)
      }
      let context = PipelineNodeExecutionContext(
        semanticSHA256: prepared.semanticSHA256,
        invocation: nodeInvocation,
        sourceMediaRoot: sourceMediaRoot,
        packageRootsByID: packageRootsByID,
        nodeIndex: index,
        nodeCount: ordered.count,
        progress: progress,
        runID: traceRunID,
        requestedOutputPorts: Set(document.connections.filter {
          $0.output.nodeID == nodeID
        }.map(\.output.port)), document: document)
      if let target = livePreviewTarget,
        let active = activeScenes[target.nodeID],
        node.kind == .gpuProgram,
        document.connections.contains(where: {
          $0.output == .init(nodeID: nodeID, port: "image")
            && $0.input == .init(nodeID: target.nodeID,
              port: "scene\(active)")
        }) {
        guard let gpuProgram else {
          throw PipelineEngineError.invalidInvocation("GPU preview needs a Metal device.")
        }
        let request = try await gpuProgram.captureLivePreview(node: node,
          inputs: inputs, context: context)
        let switchNode = nodes[target.nodeID]!
        let count = Int(switchNode.parameters["sceneCount"]?.integerValue ?? 2)
        guard request == -1 || (0..<Int64(count)).contains(request) else {
          throw PipelineEngineError.invalidInvocation(
            "Scene Switch request must be -1 or a connected scene index.")
        }
        var frames = switchState.frames[target.nodeID]!
        frames[active] += 1
        pendingSceneSwitches[target.nodeID] = SceneSwitchSession(
          runID: traceRunID, graphSHA256: prepared.semanticSHA256,
          nextCallIndex: switchState.callIndex + 1,
          activeScene: request == -1 ? active : Int(request),
          sceneFrames: frames)
        await progress(.init(stage: .completed,
          message: "Scene Switch preview ready.",
          completedUnitCount: ordered.count,
          totalUnitCount: ordered.count))
        return .none
      }
      if let livePreviewTarget, nodeID == livePreviewTarget.nodeID {
        if node.kind == .gpuProgram {
          guard let gpuProgram else {
            throw PipelineEngineError.invalidInvocation("GPU preview needs a Metal device.")
          }
          _ = try await gpuProgram.captureLivePreview(node: node,
            inputs: inputs, context: context)
        } else {
          guard let meshRenderer else {
            throw PipelineEngineError.invalidInvocation("Metal preview needs a Metal device.")
          }
          try await meshRenderer.captureShaderPreview(runID: livePreviewTarget.runID,
            nodeID: nodeID, inputs: inputs, context: context)
        }
        await progress(.init(stage: .completed, message: "Metal preview state ready.",
          completedUnitCount: ordered.count, totalUnitCount: ordered.count))
        return .none
      }
      if let trace {
        var parameters = descriptor.parameters.reduce(into: [String: PipelineTraceValue]()) {
          result, parameter in
          if let value = node.parameters[parameter.name] ?? parameter.defaultValue {
            result[parameter.name] = value.traceValue()
          }
        }
        for (name, value) in node.parameters where parameters[name] == nil {
          parameters[name] = value.traceValue()
        }
        await trace(.init(runID: traceID, call: traceCall, workflow: document.name,
          graphSHA256: prepared.semanticSHA256, node: node, phase: "started",
          inputs: inputs.mapValues { $0.traceValue() }, parameters: parameters))
      }
      let started = Date()
      do {
        let result = try await executor.execute(node, inputs: inputs, context: context)
        for (port, value) in result.outputs {
          guard let declared = descriptor.output(named: port),
            Self.compatible(value.type, with: declared.type)
          else {
            throw PipelineEngineError.planningFailed(
              "Node \(nodeID.rawValue) produced an undeclared or mistyped \(port) output.")
          }
          values[.init(nodeID: nodeID, port: port)] = value
        }
        if node.kind == .sceneSwitch, let active = activeScenes[nodeID] {
          let count = Int(node.parameters["sceneCount"]?.integerValue ?? 2)
          let request = inputs["request\(active)"]?.value(as: Int64.self) ?? -1
          guard request == -1 || (0..<Int64(count)).contains(request) else {
            throw PipelineEngineError.invalidInvocation(
              "Scene Switch request must be -1 or a connected scene index.")
          }
          var frames = switchState.frames[nodeID]!
          frames[active] += 1
          pendingSceneSwitches[nodeID] = SceneSwitchSession(
            runID: traceRunID, graphSHA256: prepared.semanticSHA256,
            nextCallIndex: switchState.callIndex + 1,
            activeScene: request == -1 ? active : Int(request),
            sceneFrames: frames)
        }
        for connection in document.connections where connection.output.nodeID == nodeID
          && nodes[connection.input.nodeID]?.kind == .assetCache {
          guard let value = result.outputs[connection.output.port], value.type == .image,
            let assetPreview = PipelineAssetCache.preview(
              nodeID: connection.input.nodeID, slot: connection.input.port,
              value: value, graphSHA256: prepared.semanticSHA256)
          else { continue }
          await progress(.init(stage: .generating,
            message: "Asset Cache: \(connection.input.port) ready",
            completedUnitCount: index + 1, totalUnitCount: ordered.count,
            assetPreview: assetPreview, activeNodeIDs: [nodeID]))
        }
        let publishRestoredAssetPreview = node.kind == .assetCache
          ? await assetCache.takeRestoredPreviewFlag(nodeID) : false
        if node.kind == .assetCache,
          (!assetCacheIsFilled || publishRestoredAssetPreview),
          let bundle = result.outputs["assets"]?.value(as: PipelineAssetBundle.self) {
          for (slot, value) in bundle.values.sorted(by: { $0.key < $1.key }) {
            guard let assetPreview = PipelineAssetCache.preview(nodeID: nodeID,
              slot: slot, value: value, graphSHA256: prepared.semanticSHA256)
            else { continue }
            await progress(.init(stage: .generating,
              message: "Asset Cache: \(slot) ready",
              completedUnitCount: index + 1, totalUnitCount: ordered.count,
              assetPreview: assetPreview, activeNodeIDs: [nodeID]))
          }
        }
        if node.kind == .primitiveString,
          let text = result.outputs["value"]?.payload as? String {
          await progress(.init(stage: .generating,
            message: node.title ?? node.kind.rawValue,
            completedUnitCount: index + 1, totalUnitCount: ordered.count,
            textValueNodeID: nodeID, textValue: text))
        }
        if nodeID == outputNode?.id {
          guard let output = result.terminalOutput else {
            throw PipelineEngineError.planningFailed(
              "Output node \(nodeID.rawValue) produced no result.")
          }
          finalOutput = output
        }
        if let trace {
          var outputs = result.outputs.mapValues { $0.traceValue() }
          if let terminal = result.terminalOutput {
            outputs["terminal"] = terminal.traceValue()
          }
          await trace(.init(runID: traceID, call: traceCall, workflow: document.name,
            graphSHA256: prepared.semanticSHA256, node: node, phase: "completed",
            durationSeconds: Date().timeIntervalSince(started), outputs: outputs))
        }
      } catch {
        if let trace {
          await trace(.init(runID: traceID, call: traceCall, workflow: document.name,
            graphSHA256: prepared.semanticSHA256, node: node, phase: "failed",
            durationSeconds: Date().timeIntervalSince(started),
            error: error.localizedDescription))
        }
        throw error
      }
    }
    if outputNode != nil && finalOutput == nil {
      throw PipelineEngineError.planningFailed("The selected output was not executed.")
    }
    await progress(.init(
      stage: .completed, message: "Pipeline completed.",
      completedUnitCount: ordered.count, totalUnitCount: ordered.count))
    return finalOutput ?? .none
  }

  private static func compatible(_ actual: PipelinePortType, with declared: PipelinePortType) -> Bool {
    actual == declared || declared == .any
      || (actual == .string && declared == .prompt)
      || (actual == .prompt && declared == .string)
      || (actual == .integer && declared == .seed)
      || (actual == .seed && declared == .integer)
  }
}

import CoreAILanguageModels
import CryptoKit
import Foundation
import FoundationModels
import OSLog
import PixeltjePipelineDomain
import PixeltjePipelineEngine

public struct CoreAITextGenerationInvocation: Equatable, Sendable {
  public var prompt: String
  public var systemPrompt: String
  public var maximumResponseTokens: Int
  public var temperature: Double
  public var topK: Int
  public var seed: UInt64
  public var previousPrompt: String?
  public var previousResponse: String?

  public init(
    prompt: String,
    systemPrompt: String = "",
    maximumResponseTokens: Int = 256,
    temperature: Double = 0.7,
    topK: Int = 40,
    seed: UInt64 = 0,
    previousPrompt: String? = nil,
    previousResponse: String? = nil
  ) {
    self.prompt = prompt
    self.systemPrompt = systemPrompt
    self.maximumResponseTokens = maximumResponseTokens
    self.temperature = temperature
    self.topK = topK
    self.seed = seed
    self.previousPrompt = previousPrompt
    self.previousResponse = previousResponse
  }
}

public struct CoreAITextPackageInspection: Equatable, Sendable {
  public var packageRoot: URL
  public var packageID: String?
  public var packageVersion: String?
  public var modelURL: URL?
  public var modelHash: String?
  public var manifestHash: String?
  public var tokenizerHash: String?
  public var missingComponents: [String]
  public var mismatchedComponents: [String]
  public var incompatibleComponents: [String]

  public init(
    packageRoot: URL,
    packageID: String? = nil,
    packageVersion: String? = nil,
    modelURL: URL? = nil,
    modelHash: String? = nil,
    manifestHash: String? = nil,
    tokenizerHash: String? = nil,
    missingComponents: [String] = [],
    mismatchedComponents: [String] = [],
    incompatibleComponents: [String] = []
  ) {
    self.packageRoot = packageRoot
    self.packageID = packageID
    self.packageVersion = packageVersion
    self.modelURL = modelURL
    self.modelHash = modelHash
    self.manifestHash = manifestHash
    self.tokenizerHash = tokenizerHash
    self.missingComponents = missingComponents
    self.mismatchedComponents = mismatchedComponents
    self.incompatibleComponents = incompatibleComponents
  }

  public var isUsable: Bool {
    packageID != nil && packageVersion != nil && modelURL != nil && modelHash != nil
      && manifestHash != nil && tokenizerHash != nil
      && missingComponents.isEmpty && mismatchedComponents.isEmpty
      && incompatibleComponents.isEmpty
  }

  public var summary: String {
    if isUsable { return "Core AI language-model package is ready." }
    let problems =
      (missingComponents.map { "missing \($0)" }
      + mismatchedComponents.map { "changed \($0)" }
      + incompatibleComponents.map { "incompatible \($0)" }).joined(separator: ", ")
    return problems.isEmpty
      ? "Core AI language-model package cannot be used."
      : "Core AI language-model package cannot be used: \(problems)."
  }
}

public struct CoreAITextAgentSessionState: Sendable {
  public let transcript: Transcript
  public let packageID: String
  public let packageVersion: String
}

/// Reviewed bridge from the portable text graph to Apple's pinned CoreAILM
/// runtime. The graph stays data-only; tokenizer, state, prefill and decode
/// semantics remain inside the installed Swift adapter.
public enum CoreAITextPipelineFamily {
  public static let familyABI = "coreai-language-model@1"
  public static let compositeNodeKind = PipelineNodeKind(rawValue: "coreai.textGenerate")
  public static let defaultSystemPrompt =
    "You are a concise, helpful writing assistant. Return only the requested text."

  public static func defaultPackageURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let configured = environment["PIXELTJE_TEXT_MODEL_PATH"], !configured.isEmpty {
      return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return homeDirectory.appendingPathComponent(
      ".pixeltje/models/qwen3-coreai", isDirectory: true)
  }

  private static func unlinkedResources() -> [String: PipelineResourceBinding] {
    [
      "model": .unresolved(.init(
        kind: .coreAIModel, componentRole: "languageModel",
        sourceName: "Core AI language-model bundle",
        sourceFormat: ".aimodel or .aimodelc", familyABI: familyABI)),
      "manifest": .unresolved(.init(
        kind: .data, componentRole: "languageModelManifest",
        sourceName: "metadata.json", sourceFormat: "json",
        familyABI: familyABI)),
      "tokenizer": .unresolved(.init(
        kind: .tokenizer, componentRole: "tokenizer",
        sourceName: "embedded tokenizer",
        sourceFormat: "Hugging Face tokenizer directory", familyABI: familyABI)),
    ]
  }

  public static func makeCompositeNodeDescriptor() -> PipelineNodeDescriptor {
    PipelineNodeDescriptor(
      kind: compositeNodeKind,
      displayName: "Core AI Text Generate",
      category: "Generation",
      inputs: [
        .init(name: "prompt", type: .prompt),
        .init(name: "seed", type: .seed, isRequired: false),
        .init(name: "previousPrompt", type: .prompt, isRequired: false),
        .init(name: "previousResponse", type: .string, isRequired: false),
      ],
      outputs: [.init(name: "text", type: .string)],
      parameters: [
        .init(name: "systemPrompt", valueType: .string,
          defaultValue: .string(defaultSystemPrompt)),
        .init(name: "maxTokens", valueType: .integer, defaultValue: .integer(256)),
        .init(name: "temperature", valueType: .number, defaultValue: .number(0.7)),
        .init(name: "topK", valueType: .integer, defaultValue: .integer(40)),
        .init(name: "seed", valueType: .integer, defaultValue: .integer(0)),
      ],
      requiredResourceSlots: ["manifest", "model", "tokenizer"],
      isTerminal: true)
  }

  public static func makeNativeTextCompletionDocument(
    name: String = "Core AI Text Completion"
  ) -> PipelineDocument {
    let promptID = PipelineNodeID(rawValue: "prompt")
    let completionID = PipelineNodeID(rawValue: "completion")
    return PipelineDocument(
      id: PipelineID(rawValue: "org.pixeltje.pipeline.coreai-text-completion"),
      name: name, mode: .generic,
      nodes: [
        PipelineNode(id: promptID, kind: .promptInput, title: "Prompt"),
        makeCompositeNode(id: completionID),
      ],
      connections: [PipelineConnection(
        output: .init(nodeID: promptID, port: "prompt"),
        input: .init(nodeID: completionID, port: "prompt"))],
      exposedParameters: [
        .init(id: "maximum-response-tokens", label: "Maximum response tokens",
          valueType: .integer,
          target: .init(nodeID: completionID, parameter: "maxTokens"),
          defaultValue: .integer(256), minimum: 1, maximum: 4096),
        .init(id: "temperature", label: "Temperature", valueType: .number,
          target: .init(nodeID: completionID, parameter: "temperature"),
          defaultValue: .number(0.7), minimum: 0, maximum: 2),
        .init(id: "top-k", label: "Top K", valueType: .integer,
          target: .init(nodeID: completionID, parameter: "topK"),
          defaultValue: .integer(40), minimum: 1, maximum: 1000),
        .init(id: "seed", label: "Seed", valueType: .integer,
          target: .init(nodeID: completionID, parameter: "seed"),
          defaultValue: .integer(0), minimum: 0, maximum: Double(UInt32.max)),
      ],
      primaryOutputNodeIDs: [completionID],
      presentation: PipelinePresentation(
        nodePositions: [
          promptID.rawValue: .init(x: 40, y: 120),
          completionID.rawValue: .init(x: 320, y: 120),
        ],
        viewportOrigin: .init(x: 0, y: 0), viewportScale: 1))
  }

  public static func makeCompositeNode(id: PipelineNodeID) -> PipelineNode {
    PipelineNode(
      id: id, kind: compositeNodeKind, title: "Generate Text",
      parameters: [
        "systemPrompt": .string(defaultSystemPrompt),
        "maxTokens": .integer(256),
        "temperature": .number(0.7),
        "topK": .integer(40),
        "seed": .integer(0),
      ],
      resources: unlinkedResources())
  }

  public static func makeNodeExecutor(
    runner: CoreAITextPipelineRunner
  ) -> PipelineNodeExecutor {
    PipelineNodeExecutor(kind: compositeNodeKind) { node, inputs, context in
      guard let prompt = inputs["prompt"]?.value(as: String.self) else {
        throw PipelineEngineError.invalidInvocation("Text generation needs a prompt.")
      }
      guard let reference = node.resources["model"]?.linkedReference else {
        throw PipelineEngineError.modelPackageUnavailable("Text model is not linked.")
      }
      let root = try context.packageRoot(for: reference)
      let scoped = PipelineDocument(
        id: PipelineID(rawValue: "text-composite-\(node.id.rawValue)"),
        name: "Core AI text generation", mode: .generic,
        nodes: [node], connections: [], primaryOutputNodeIDs: [node.id])
      let prepared = PreparedPipeline(
        document: scoped, semanticSHA256: context.semanticSHA256,
        orderedNodeIDs: [node.id],
        requiredResources: node.resources.keys.sorted().compactMap { slot in
          node.resources[slot]?.linkedReference.map {
            PipelineLinkedResourceRequirement(nodeID: node.id, slot: slot, reference: $0)
          }
        })
      let seed = try inputs["seed"]?.value(as: UInt64.self)
        ?? context.invocation.unsignedInteger(
          for: PipelineInvocation.seedKey,
          default: UInt64(node.parameters["seed"]?.integerValue ?? 0))
      let result = try await runner.executeTextCompletion(
        prepared, packageRoot: root,
        invocation: CoreAITextGenerationInvocation(
          prompt: prompt,
          systemPrompt: try context.invocation.string(
            for: PipelineInvocation.systemPromptKey,
            default: node.parameters["systemPrompt"]?.stringValue ?? defaultSystemPrompt),
          maximumResponseTokens: try context.invocation.integer(
            for: PipelineInvocation.maximumResponseTokensKey,
            default: Int(node.parameters["maxTokens"]?.integerValue ?? 256)),
          temperature: try context.invocation.number(
            for: PipelineInvocation.temperatureKey,
            default: node.parameters["temperature"]?.numberValue ?? 0.7),
          topK: try context.invocation.integer(
            for: PipelineInvocation.topKKey,
            default: Int(node.parameters["topK"]?.integerValue ?? 40)),
          seed: seed,
          previousPrompt: inputs["previousPrompt"]?.value(as: String.self),
          previousResponse: inputs["previousResponse"]?.value(as: String.self)),
        progress: { update in
          var mapped = update
          mapped.activeNodeIDs = [node.id]
          // The text node can feed later graph nodes, so its completion is
          // still an in-progress pipeline update. Forward the final text even
          // when a host coalesces intermediate streaming snapshots.
          if mapped.stage == .completed { mapped.stage = .generating }
          await context.progress(mapped)
        })
      return PipelineNodeResult(
        outputs: ["text": PipelineNodeValue(result.text, type: .string)],
        terminalOutput: .text(result))
    }
  }

  /// Explicitly binds the selected local bundle to the model node. The local
  /// path is intentionally not persisted in the returned document.
  public static func linkPackage(
    in document: PipelineDocument,
    at packageRoot: URL,
    replacingPackageID: String? = nil
  ) throws -> PipelineDocument {
    let inspection = inspectPackage(at: packageRoot)
    guard inspection.isUsable,
      let packageID = inspection.packageID,
      let packageVersion = inspection.packageVersion,
      let modelHash = inspection.modelHash,
      let manifestHash = inspection.manifestHash,
      let tokenizerHash = inspection.tokenizerHash
    else {
      throw PipelineEngineError.modelPackageUnavailable(inspection.summary)
    }

    let modelIndices = document.nodes.indices.filter {
      document.nodes[$0].kind == compositeNodeKind
        && document.nodes[$0].executionState == .enabled
        && (replacingPackageID == nil
          || (document.nodes[$0].resources["model"]?.linkedReference?.packageID
            ?? "coreai.text.unlinked") == replacingPackageID)
    }
    guard !modelIndices.isEmpty else {
      throw PipelineEngineError.unsupportedPipeline(
        "The text workflow needs an enabled Core AI language-model node matching the selected package.")
    }

    func reference(
      kind: PipelineResourceKind,
      hash: String,
      role: String
    ) -> PipelineResourceBinding {
      .linked(
        PipelineResourceReference(
          kind: kind,
          packageID: packageID,
          packageVersion: packageVersion,
          contentHash: hash,
          componentRole: role,
          familyABI: familyABI))
    }

    var linked = document
    for modelIndex in modelIndices {
      linked.nodes[modelIndex].resources = [
        "manifest": reference(
          kind: .data, hash: manifestHash, role: "languageModelManifest"),
        "model": reference(kind: .coreAIModel, hash: modelHash, role: "languageModel"),
        "tokenizer": reference(kind: .tokenizer, hash: tokenizerHash, role: "tokenizer"),
      ]
    }
    return linked
  }

  public static func inspectPackage(
    at packageRoot: URL,
    for document: PipelineDocument? = nil
  ) -> CoreAITextPackageInspection {
    let root = packageRoot.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return CoreAITextPackageInspection(
        packageRoot: root, missingComponents: ["package directory"])
    }

    let manifestURL = root.appendingPathComponent("metadata.json")
    guard let manifestData = try? Data(contentsOf: manifestURL) else {
      return CoreAITextPackageInspection(
        packageRoot: root, missingComponents: ["metadata.json"])
    }

    let languageBundle: LanguageBundle
    do {
      languageBundle = try LanguageBundle(at: root)
      try languageBundle.bundle.verify()
    } catch {
      return CoreAITextPackageInspection(
        packageRoot: root,
        incompatibleComponents: [error.localizedDescription])
    }

    var missing: [String] = []
    var incompatible: [String] = []
    guard languageBundle.hasEmbeddedTokenizer, let tokenizerURL = languageBundle.tokenizerPath
    else {
      return CoreAITextPackageInspection(
        packageRoot: root,
        incompatibleComponents: [
          "metadata.json must require an embedded tokenizer; network tokenizer fallback is disabled"
        ])
    }
    let tokenizerConfigURL = tokenizerURL.appendingPathComponent("tokenizer_config.json")
    if !isMaterializedFile(tokenizerConfigURL) {
      missing.append("tokenizer/tokenizer_config.json")
    }

    let modelURL: URL
    do {
      modelURL = try languageBundle.requireModelURL(for: "main")
    } catch {
      return CoreAITextPackageInspection(
        packageRoot: root,
        missingComponents: ["main language-model asset"])
    }
    let extensionName = modelURL.pathExtension.lowercased()
    if extensionName != "aimodel" && extensionName != "aimodelc" {
      incompatible.append("main asset must be .aimodel or .aimodelc")
    }

    let packageID = packageIdentifier(from: manifestData, fallbackName: languageBundle.name)
    let manifestHash = SHA256.hash(data: manifestData).hexadecimalString
    let modelHash: String?
    let tokenizerHash: String?
    do {
      modelHash = try modelContentHash(at: modelURL)
    } catch {
      modelHash = nil
      incompatible.append("model content identity could not be calculated")
    }
    do {
      tokenizerHash = try directoryContentHash(at: tokenizerURL)
    } catch {
      tokenizerHash = nil
      incompatible.append("tokenizer content identity could not be calculated")
    }

    let packageVersion: String?
    if let modelHash, let tokenizerHash {
      var hasher = SHA256()
      for value in [packageID, manifestHash, modelHash, tokenizerHash] {
        hasher.update(data: Data(value.utf8))
        hasher.update(data: Data([0]))
      }
      packageVersion = "sha256." + Data(hasher.finalize()).hexadecimalString
    } else {
      packageVersion = nil
    }

    var mismatched: [String] = []
    if let document, let packageVersion, let modelHash, let tokenizerHash {
      let manifestReference = linkedReference(
        in: document, slot: "manifest", role: "languageModelManifest")
      let modelReference = linkedReference(
        in: document, slot: "model", role: "languageModel")
      let tokenizerReference = linkedReference(
        in: document, slot: "tokenizer", role: "tokenizer")
      let expected: [(String, PipelineResourceReference?, PipelineResourceKind, String)] = [
        ("manifest", manifestReference, .data, manifestHash),
        ("model", modelReference, .coreAIModel, modelHash),
        ("tokenizer", tokenizerReference, .tokenizer, tokenizerHash),
      ]
      for (name, reference, kind, hash) in expected {
        guard let reference,
          reference.kind == kind,
          reference.packageID == packageID,
          reference.packageVersion == packageVersion,
          reference.familyABI == familyABI,
          normalizedHash(reference.contentHash) == normalizedHash(hash)
        else {
          mismatched.append(name)
          continue
        }
      }
    }

    return CoreAITextPackageInspection(
      packageRoot: root,
      packageID: packageID,
      packageVersion: packageVersion,
      modelURL: modelURL,
      modelHash: modelHash,
      manifestHash: manifestHash,
      tokenizerHash: tokenizerHash,
      missingComponents: Array(Set(missing)).sorted(),
      mismatchedComponents: Array(Set(mismatched)).sorted(),
      incompatibleComponents: Array(Set(incompatible)).sorted())
  }

  public static func inspectPackageForExecution(
    at packageRoot: URL,
    for document: PipelineDocument
  ) async -> CoreAITextPackageInspection {
    var inspection = inspectPackage(at: packageRoot, for: document)
    guard inspection.isUsable else { return inspection }
    do {
      _ = try await CoreAILanguageModel(resourcesAt: packageRoot, mode: .lazy)
    } catch is CancellationError {
      inspection.incompatibleComponents.append("language-model inspection was cancelled")
    } catch {
      inspection.incompatibleComponents.append(error.localizedDescription)
    }
    inspection.incompatibleComponents = Array(Set(inspection.incompatibleComponents)).sorted()
    return inspection
  }

  private static func linkedReference(
    in document: PipelineDocument,
    slot: String,
    role: String
  ) -> PipelineResourceReference? {
    document.nodes.first(where: {
      $0.kind == compositeNodeKind
    })?
      .resources[slot]?.linkedReference.flatMap { reference in
        reference.componentRole == role ? reference : nil
      }
  }

  private static func packageIdentifier(from data: Data, fallbackName: String) -> String {
    let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let source = metadata?["source"] as? [String: Any]
    let sourceName = source?["hf_model_id"] as? String
    let raw = sourceName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
    let normalized = raw.lowercased().unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let suffix = String(normalized)
      .replacingOccurrences(of: "--", with: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "coreai." + (suffix.isEmpty ? "language-model" : suffix)
  }

  private static func modelContentHash(at url: URL) throws -> String {
    let direct = url.appendingPathComponent("main.hash")
    if let hash = normalizedHashFile(at: direct) { return hash }

    let hashes = try regularFiles(in: url).filter { $0.lastPathComponent == "main.hash" }
    if hashes.count == 1, let hash = normalizedHashFile(at: hashes[0]) { return hash }
    if !hashes.isEmpty { return try contentHash(of: hashes, relativeTo: url) }
    return try directoryContentHash(at: url)
  }

  private static func directoryContentHash(at url: URL) throws -> String {
    try contentHash(of: regularFiles(in: url), relativeTo: url)
  }

  private static func contentHash(of files: [URL], relativeTo root: URL) throws -> String {
    var hasher = SHA256()
    for file in files.sorted(by: { $0.path < $1.path }) {
      let relativePath = String(file.path.dropFirst(root.path.count))
      hasher.update(data: Data(relativePath.utf8))
      hasher.update(data: Data([0]))
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        try Task.checkCancellation()
        hasher.update(data: chunk)
      }
      hasher.update(data: Data([0]))
    }
    return Data(hasher.finalize()).hexadecimalString
  }

  private static func regularFiles(in directory: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
    else { throw CocoaError(.fileReadNoSuchFile) }
    var result: [URL] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true { continue }
      if values.isRegularFile == true { result.append(url) }
    }
    return result
  }

  private static func normalizedHashFile(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    let text = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return text.count == 64 && text.allSatisfy(\.isHexDigit)
      ? text
      : SHA256.hash(data: data).hexadecimalString
  }

  private static func normalizedHash(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: "sha256:", with: "")
  }

  private static func isMaterializedFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
      return false
    }
    return values.isRegularFile == true && (values.fileSize ?? 0) > 0
  }
}

public actor CoreAITextPipelineRunner {
  private let logger = Logger(
    subsystem: "org.pixeltje.PixeltjeMacApp", category: "coreai-text")

  private struct PackageFileRevision: Equatable {
    var path: String
    var size: Int
    var modifiedAt: Date?
    var fileIdentifier: String
  }

  private struct CachedInspection {
    var document: PipelineDocument
    var packageRoot: URL
    var files: [PackageFileRevision]
    var result: CoreAITextPackageInspection
  }

  private var loadedPackageRoot: URL?
  private var loadedPackageVersion: String?
  private var loadedPackageFiles: [PackageFileRevision]?
  private var loadedModel: CoreAILanguageModel?
  private var cachedInspection: CachedInspection?
  private var agentSessions: [String: AgentSession] = [:]

  private struct AgentSession {
    let modelSession: LanguageModelSession
    let tools: [any Tool]
    let prepared: PreparedPipeline
    let packageID: String
    let packageVersion: String
    let maximumResponseTokens: Int
    let temperature: Double
    let topK: Int
    let seed: UInt64
    var isGenerating = false
  }

  public init() {}

  public func inspectPackage(
    at packageRoot: URL,
    for document: PipelineDocument
  ) async -> CoreAITextPackageInspection {
    let root = packageRoot.standardizedFileURL
    if let cached = reusableInspection(at: root, for: document) {
      return cached
    }

    let filesBefore = Self.packageFileRevisions(at: root)
    let inspection = await CoreAITextPipelineFamily.inspectPackageForExecution(
      at: root, for: document)
    let filesAfter = Self.packageFileRevisions(at: root)
    if inspection.isUsable, let filesBefore, filesBefore == filesAfter {
      cachedInspection = CachedInspection(
        document: document,
        packageRoot: root,
        files: filesBefore,
        result: inspection)
    } else {
      cachedInspection = nil
    }
    return inspection
  }

  public func executeTextCompletion(
    _ prepared: PreparedPipeline,
    packageRoot: URL,
    invocation: CoreAITextGenerationInvocation,
    progress: @escaping PipelineExecutionProgressHandler = { _ in }
  ) async throws -> PipelineGeneratedText {
    try Task.checkCancellation()
    guard prepared.document.requirements.familyABIs.isEmpty,
      prepared.document.nodes.count == 1,
      let node = prepared.document.nodes.first,
      node.kind == CoreAITextPipelineFamily.compositeNodeKind,
      node.executionState == .enabled
    else {
      throw PipelineEngineError.unsupportedPipeline(
        "Text execution requires one native generation node.")
    }
    try validate(invocation)
    let activeNodeIDs: Set<PipelineNodeID> = [node.id]

    let root = packageRoot.standardizedFileURL
    let inspection: CoreAITextPackageInspection
    if let cached = reusableInspection(at: root, for: prepared.document) {
      inspection = cached
    } else {
      await progress(.init(stage: .validating, message: "Validating text package…"))
      inspection = await inspectPackage(at: root, for: prepared.document)
    }
    try Task.checkCancellation()
    guard inspection.isUsable,
      let packageID = inspection.packageID,
      let packageVersion = inspection.packageVersion
    else {
      throw PipelineEngineError.modelPackageUnavailable(inspection.summary)
    }

    let model = try await model(
      at: root, version: packageVersion,
      loadingNodeIDs: activeNodeIDs, progress: progress)

    let instructions = invocation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    var attempt = 0
    while true {
      try Task.checkCancellation()
      await progress(
        .init(
          stage: .preparing,
          message: attempt == 0
            ? "Preparing prompt and generation state…"
            : "Retrying text generation (attempt \(attempt + 1)/3)…",
          completedUnitCount: 0,
          totalUnitCount: invocation.maximumResponseTokens,
          generatedText: attempt == 0 ? nil : "",
          activeNodeIDs: activeNodeIDs))

      // A fresh session and seed avoid replaying a malformed generation.
      // Only Foundation Models' content-parse failure is safe to retry here.
      let attemptSeed = invocation.seed &+ UInt64(attempt)
      let session: LanguageModelSession
      if let previousResponse = invocation.previousResponse,
        !previousResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let previousPrompt = invocation.previousPrompt
      {
        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty {
          entries.append(.instructions(.init(
            segments: [.text(.init(content: instructions))], toolDefinitions: [])))
        }
        entries.append(.prompt(.init(segments: [.text(.init(content: previousPrompt))])))
        entries.append(.response(.init(segments: [.text(.init(content: previousResponse))])))
        session = LanguageModelSession(model: model, transcript: Transcript(entries: entries))
      } else {
        session = LanguageModelSession(
          model: model,
          instructions: instructions.isEmpty ? nil : instructions)
      }
      let samplingMode: GenerationOptions.SamplingMode =
        invocation.temperature == 0
        ? .greedy
        : .random(top: invocation.topK, seed: attemptSeed)
      let options = GenerationOptions(
        samplingMode: samplingMode,
        temperature: invocation.temperature == 0 ? nil : invocation.temperature,
        maximumResponseTokens: invocation.maximumResponseTokens)
      var generatedText = ""
      var inputTokenCount: Int?
      var outputTokenCount: Int?
      do {
        for try await snapshot in session.streamResponse(to: invocation.prompt, options: options) {
          try Task.checkCancellation()
          let accumulated = snapshot.content
          let delta: String? =
            accumulated.hasPrefix(generatedText)
            ? String(accumulated.dropFirst(generatedText.count))
            : nil
          generatedText = accumulated
          inputTokenCount = snapshot.usage.input.totalTokenCount
          outputTokenCount = snapshot.usage.output.totalTokenCount
          await progress(
            .init(
              stage: .generating,
              message: "Generating text…",
              completedUnitCount: outputTokenCount ?? 0,
              totalUnitCount: invocation.maximumResponseTokens,
              generatedText: accumulated,
              textDelta: delta,
              inputTokenCount: inputTokenCount,
              outputTokenCount: outputTokenCount,
              activeNodeIDs: activeNodeIDs))
        }
        try Task.checkCancellation()
        let result = PipelineGeneratedText(
          text: generatedText,
          seed: attemptSeed,
          semanticPipelineSHA256: prepared.semanticSHA256,
          modelPackageID: packageID,
          modelPackageVersion: packageVersion,
          finishReason: (outputTokenCount ?? 0) >= invocation.maximumResponseTokens
            ? .maximumResponseTokens : .completed,
          inputTokenCount: inputTokenCount,
          outputTokenCount: outputTokenCount)
        await progress(
          .init(
            stage: .completed,
            message: "Text generation completed.",
            completedUnitCount: outputTokenCount ?? 0,
            totalUnitCount: invocation.maximumResponseTokens,
            generatedText: generatedText,
            inputTokenCount: inputTokenCount,
            outputTokenCount: outputTokenCount,
            activeNodeIDs: activeNodeIDs))
        if attempt > 0 {
          logger.notice(
            "Core AI text generation recovered on attempt \(attempt + 1); seed \(attemptSeed)")
        }
        return result
      } catch {
        try Task.checkCancellation()
        let message = error.localizedDescription.trimmingCharacters(
          in: .whitespacesAndNewlines)
        let willRetry = attempt < 2 && invocation.temperature > 0
          && (message == "Failed to parse generated content."
            || message == "Failed to parse generated content")
        let nsError = error as NSError
        let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let record = CoreAITextFailureLog.Record(
          recordedAt: Date(),
          modelPackageID: packageID,
          modelPackageVersion: packageVersion,
          attempt: attempt + 1,
          willRetry: willRetry,
          requestedSeed: invocation.seed,
          effectiveSeed: attemptSeed,
          temperature: invocation.temperature,
          topK: invocation.topK,
          maximumResponseTokens: invocation.maximumResponseTokens,
          prompt: invocation.prompt,
          systemPrompt: invocation.systemPrompt,
          previousPrompt: invocation.previousPrompt,
          previousResponse: invocation.previousResponse,
          partialGeneratedText: generatedText,
          inputTokenCount: inputTokenCount,
          outputTokenCount: outputTokenCount,
          errorType: String(reflecting: type(of: error)),
          errorDescription: message,
          errorDebugDescription: String(reflecting: error),
          errorDomain: nsError.domain,
          errorCode: nsError.code,
          underlyingErrorDescription: underlyingError?.localizedDescription,
          underlyingErrorDomain: underlyingError?.domain,
          underlyingErrorCode: underlyingError?.code)
        do {
          let url = try CoreAITextFailureLog.write(record)
          logger.error(
            "Core AI text attempt \(attempt + 1) failed; seed \(attemptSeed); partial characters \(generatedText.count); error: \(message, privacy: .public); diagnostic: \(url.path, privacy: .public)")
        } catch {
          logger.error(
            "Core AI text attempt \(attempt + 1) failed; seed \(attemptSeed); error: \(message, privacy: .public); diagnostic write failed: \(error.localizedDescription, privacy: .public)")
        }
        guard willRetry else { throw error }
        attempt += 1
      }
    }
  }

  public func unloadResources() {
    agentSessions.removeAll()
    loadedModel?.unload()
    loadedModel = nil
    loadedPackageRoot = nil
    loadedPackageVersion = nil
    loadedPackageFiles = nil
    cachedInspection = nil
  }

  /// Opens a conversation against one prepared graph. The FoundationModels
  /// session retains its transcript and model state across prompt turns.
  public func openAgentSession(
    id: String,
    document: PipelineDocument,
    using engine: PixeltjePipelineEngine,
    packageRoot: URL,
    settings: CoreAITextGenerationInvocation,
    tools: [any Tool] = [],
    transcript: Transcript? = nil
  ) async throws {
    guard agentSessions[id] == nil else {
      throw PipelineEngineError.invalidInvocation("Agent session already exists.")
    }
    try validateSettings(settings)
    let prepared = try await engine.prepare(document)
    guard prepared.document.requirements.familyABIs.isEmpty,
      prepared.document.nodes.filter({
        $0.kind == CoreAITextPipelineFamily.compositeNodeKind && $0.executionState == .enabled
      }).count == 1,
      let modelNode = prepared.document.nodes.first(where: {
        $0.kind == CoreAITextPipelineFamily.compositeNodeKind
      })
    else {
      throw PipelineEngineError.unsupportedPipeline(
        "Agent sessions require one native Core AI text generation node.")
    }
    let root = packageRoot.standardizedFileURL
    let inspection = await inspectPackage(at: root, for: prepared.document)
    guard inspection.isUsable,
      let packageID = inspection.packageID,
      let packageVersion = inspection.packageVersion
    else { throw PipelineEngineError.modelPackageUnavailable(inspection.summary) }
    let model = try await model(
      at: root, version: packageVersion,
      loadingNodeIDs: [modelNode.id], progress: { _ in })
    let supportedTools = model.capabilities.contains(.toolCalling) ? tools : []
    let instructions = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let session: LanguageModelSession
    if let transcript {
      session = LanguageModelSession(
        model: model, tools: supportedTools, transcript: transcript)
    } else {
      session = LanguageModelSession(
        model: model, tools: supportedTools,
        instructions: instructions.isEmpty ? nil : instructions)
    }
    agentSessions[id] = AgentSession(
      modelSession: session, tools: supportedTools, prepared: prepared,
      packageID: packageID, packageVersion: packageVersion,
      maximumResponseTokens: settings.maximumResponseTokens,
      temperature: settings.temperature, topK: settings.topK, seed: settings.seed)
  }

  public func promptAgentSession(
    id: String,
    prompt: String,
    progress: @escaping PipelineExecutionProgressHandler = { _ in }
  ) async throws -> PipelineGeneratedText {
    try Task.checkCancellation()
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PipelineEngineError.invalidInvocation("Enter a prompt before running the pipeline.")
    }
    guard var state = agentSessions[id] else {
      throw PipelineEngineError.invalidInvocation("Unknown agent session.")
    }
    guard !state.isGenerating else {
      throw PipelineEngineError.invalidInvocation("Agent session is already generating.")
    }
    state.isGenerating = true
    agentSessions[id] = state
    let samplingMode: GenerationOptions.SamplingMode =
      state.temperature == 0 ? .greedy : .random(top: state.topK, seed: state.seed)
    let options = GenerationOptions(
      samplingMode: samplingMode,
      temperature: state.temperature == 0 ? nil : state.temperature,
      maximumResponseTokens: state.maximumResponseTokens)
    var generatedText = ""
    let priorTranscript = state.modelSession.transcript
    var inputTokenCount: Int?
    var outputTokenCount: Int?
    do {
      for try await snapshot in state.modelSession.streamResponse(to: prompt, options: options) {
        try Task.checkCancellation()
        let accumulated = snapshot.content
        let delta = accumulated.hasPrefix(generatedText)
          ? String(accumulated.dropFirst(generatedText.count)) : nil
        generatedText = accumulated
        inputTokenCount = snapshot.usage.input.totalTokenCount
        outputTokenCount = snapshot.usage.output.totalTokenCount
        await progress(.init(
          stage: .generating, message: "Generating text…",
          completedUnitCount: outputTokenCount ?? 0,
          totalUnitCount: state.maximumResponseTokens,
          generatedText: accumulated, textDelta: delta,
          inputTokenCount: inputTokenCount, outputTokenCount: outputTokenCount))
      }
      try Task.checkCancellation()
    } catch {
      // Restore the last complete conversation when a turn leaves a partial
      // transcript (for example after ACP cancellation).
      if let loadedModel {
        state = AgentSession(
          modelSession: LanguageModelSession(
            model: loadedModel, tools: state.tools, transcript: priorTranscript),
          tools: state.tools, prepared: state.prepared,
          packageID: state.packageID, packageVersion: state.packageVersion,
          maximumResponseTokens: state.maximumResponseTokens,
          temperature: state.temperature, topK: state.topK, seed: state.seed)
        agentSessions[id] = state
      } else {
        agentSessions.removeValue(forKey: id)
      }
      throw error
    }
    state.isGenerating = false
    agentSessions[id] = state
    return PipelineGeneratedText(
      text: generatedText, seed: state.seed,
      semanticPipelineSHA256: state.prepared.semanticSHA256,
      modelPackageID: state.packageID, modelPackageVersion: state.packageVersion,
      finishReason: (outputTokenCount ?? 0) >= state.maximumResponseTokens
        ? .maximumResponseTokens : .completed,
      inputTokenCount: inputTokenCount, outputTokenCount: outputTokenCount)
  }

  public func closeAgentSession(id: String) {
    agentSessions.removeValue(forKey: id)
  }

  public func agentSessionState(id: String) -> CoreAITextAgentSessionState? {
    guard let session = agentSessions[id], !session.isGenerating else { return nil }
    return CoreAITextAgentSessionState(
      transcript: session.modelSession.transcript,
      packageID: session.packageID, packageVersion: session.packageVersion)
  }

  private func model(
    at root: URL,
    version: String,
    loadingNodeIDs: Set<PipelineNodeID>,
    progress: @escaping PipelineExecutionProgressHandler
  ) async throws -> CoreAILanguageModel {
    let currentFiles = Self.packageFileRevisions(at: root)
    if loadedPackageRoot == root, loadedPackageVersion == version,
      let currentFiles, currentFiles == loadedPackageFiles, let loadedModel
    { return loadedModel }
    agentSessions.removeAll()
    loadedModel?.unload()
    loadedModel = nil
    loadedPackageRoot = nil
    loadedPackageVersion = nil
    loadedPackageFiles = nil
    await progress(.init(
      stage: .loadingModels, message: "Loading Core AI language model…",
      activeNodeIDs: loadingNodeIDs))
    let newModel = try await CoreAILanguageModel(resourcesAt: root, mode: .lazy)
    try await newModel.load()
    do { try Task.checkCancellation() }
    catch { newModel.unload(); throw error }
    loadedPackageRoot = root
    loadedPackageVersion = version
    loadedPackageFiles = currentFiles
    loadedModel = newModel
    return newModel
  }

  private func reusableInspection(
    at root: URL,
    for document: PipelineDocument
  ) -> CoreAITextPackageInspection? {
    guard let cachedInspection,
      cachedInspection.packageRoot == root,
      cachedInspection.document == document,
      let files = Self.packageFileRevisions(at: root),
      files == cachedInspection.files
    else { return nil }
    return cachedInspection.result
  }

  /// File metadata is only a quick invalidation check. A cache miss repeats
  /// the full content-hash and Core AI compatibility inspection.
  private static func packageFileRevisions(at root: URL) -> [PackageFileRevision]? {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      .contentModificationDateKey, .fileResourceIdentifierKey,
    ]
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: Array(keys))
    else { return nil }
    var files: [PackageFileRevision] = []
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: keys),
        values.isSymbolicLink != true
      else { return nil }
      guard values.isRegularFile == true else { continue }
      files.append(PackageFileRevision(
        path: String(url.path.dropFirst(root.path.count)),
        size: values.fileSize ?? -1,
        modifiedAt: values.contentModificationDate,
        fileIdentifier: String(describing: values.fileResourceIdentifier)))
    }
    return files.sorted { $0.path < $1.path }
  }

  private func validate(_ invocation: CoreAITextGenerationInvocation) throws {
    guard !invocation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PipelineEngineError.invalidInvocation("Enter a prompt before running the pipeline.")
    }
    if let previousResponse = invocation.previousResponse,
      !previousResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      invocation.previousPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    {
      throw PipelineEngineError.invalidInvocation(
        "A previous text response needs its previous prompt to continue the conversation.")
    }
    try validateSettings(invocation)
  }

  private func validateSettings(_ invocation: CoreAITextGenerationInvocation) throws {
    guard (1...4096).contains(invocation.maximumResponseTokens) else {
      throw PipelineEngineError.invalidInvocation(
        "Maximum response tokens must be between 1 and 4096.")
    }
    guard invocation.temperature.isFinite, (0...2).contains(invocation.temperature) else {
      throw PipelineEngineError.invalidInvocation("Temperature must be between 0 and 2.")
    }
    guard (1...1000).contains(invocation.topK) else {
      throw PipelineEngineError.invalidInvocation("Top K must be between 1 and 1000.")
    }
  }
}

extension PipelineValue {
  fileprivate var integerValue: Int? {
    switch self {
    case .integer(let value): Int(exactly: value)
    case .number(let value) where value.rounded() == value: Int(exactly: value)
    default: nil
    }
  }

  fileprivate var numberValue: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .number(let value): value
    default: nil
    }
  }

  fileprivate var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}

extension Digest {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

extension Data {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

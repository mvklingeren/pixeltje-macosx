import CoreAI
import CoreAIDiffusionPipeline
import CoreGraphics
import CryptoKit
import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine

public struct FLUX2KleinTextToImageInvocation: Equatable, Sendable {
  public var prompt: String
  public var negativePrompt: String
  public var seed: UInt64
  public var width: Int
  public var height: Int
  public var steps: Int
  public var guidance: Float
  public var referenceImage: PipelineImageInput?
  public var referenceGrid: ReferenceGrid

  public init(
    prompt: String,
    negativePrompt: String = "",
    seed: UInt64 = 0,
    width: Int = 1024,
    height: Int = 1024,
    steps: Int = 4,
    guidance: Float = 1,
    referenceImage: PipelineImageInput? = nil,
    referenceGrid: ReferenceGrid = .half
  ) {
    self.prompt = prompt
    self.negativePrompt = negativePrompt
    self.seed = seed
    self.width = width
    self.height = height
    self.steps = steps
    self.guidance = guidance
    self.referenceImage = referenceImage
    self.referenceGrid = referenceGrid
  }
}

public struct FLUX2KleinPackageInspection: Equatable, Sendable {
  public var packageRoot: URL
  public var missingComponents: [String]
  public var mismatchedComponents: [String]
  public var incompatibleComponents: [String]

  public init(
    packageRoot: URL,
    missingComponents: [String] = [],
    mismatchedComponents: [String] = [],
    incompatibleComponents: [String] = []
  ) {
    self.packageRoot = packageRoot
    self.missingComponents = missingComponents
    self.mismatchedComponents = mismatchedComponents
    self.incompatibleComponents = incompatibleComponents
  }

  public var isUsable: Bool {
    missingComponents.isEmpty && mismatchedComponents.isEmpty && incompatibleComponents.isEmpty
  }

  public var summary: String {
    if isUsable { return "FLUX.2 Klein Core AI package is ready." }
    let problems =
      (missingComponents.map { "missing \($0)" }
      + mismatchedComponents.map { "changed \($0)" }
      + incompatibleComponents.map { "incompatible \($0)" }).joined(separator: ", ")
    return "FLUX.2 Klein Core AI package cannot be used: \(problems)."
  }
}

struct FLUX2KleinTensorDescriptor: Equatable, Sendable {
  var name: String
  var shape: [Int]
  var scalarType: String
}

/// Reviewed bridge between portable FLUX.2 graph nodes and Apple's official
/// CoreAIDiffusion FLUX.2 runtime. The local package path remains editor state;
/// it is never serialized into the pipeline document.
public enum FLUX2KleinPipelineFamily {
  public static let packageID = "coreai.black-forest-labs.flux2-klein-4b"
  public static let familyABI = "flux2-klein-4b-coreai@2"
  public static let compositeNodeKind = PipelineNodeKind(rawValue: "coreai.flux2KleinGenerate")

  /// Apple's current FLUX API runs the complete diffusion operation. Expose
  /// that operation as one honest, composable node until its internals have
  /// independently executable Core AI implementations.
  public static func makeCompositeNodeDescriptor() -> PipelineNodeDescriptor {
    PipelineNodeDescriptor(
      kind: compositeNodeKind,
      displayName: "FLUX.2 Klein Generate",
      category: "Generation",
      inputs: [
        .init(name: "prompt", type: .prompt),
        .init(name: "negativePrompt", type: .prompt, isRequired: false),
        .init(name: "seed", type: .seed, isRequired: false),
        .init(name: "referenceImage", type: .image, isRequired: false),
      ],
      outputs: [.init(name: "image", type: .image)],
      parameters: [
        .init(name: "width", valueType: .integer, defaultValue: .integer(1024)),
        .init(name: "height", valueType: .integer, defaultValue: .integer(1024)),
        .init(name: "steps", valueType: .integer, defaultValue: .integer(4)),
        .init(name: "guidance", valueType: .number, defaultValue: .number(1)),
        .init(name: "referenceGrid", valueType: .string, defaultValue: .string("half")),
      ],
      requiredResourceSlots: ["denoiser", "textEncoder", "vaeDecoder"])
  }

  public static func makeCompositeNode(id: PipelineNodeID) -> PipelineNode {
    let resources: [String: PipelineResourceBinding] = [
      "denoiser": .unresolved(.init(
        kind: .coreAIModel, componentRole: "denoiser",
        sourceName: "flux-2-klein-4b.safetensors", sourceFormat: "safetensors",
        familyABI: familyABI)),
      "textEncoder": .unresolved(.init(
        kind: .coreAIModel, componentRole: "textEncoder",
        sourceName: "qwen_3_4b.safetensors", sourceFormat: "safetensors",
        familyABI: familyABI)),
      "vaeDecoder": .unresolved(.init(
        kind: .coreAIModel, componentRole: "vae",
        sourceName: "flux2-vae.safetensors", sourceFormat: "safetensors",
        familyABI: familyABI)),
    ]
    return PipelineNode(
      id: id,
      kind: compositeNodeKind,
      title: "FLUX.2 Klein Generate",
      parameters: [
        "width": .integer(1024), "height": .integer(1024),
        "steps": .integer(4), "guidance": .number(1),
      ],
      resources: resources)
  }

  public static func makeNodeExecutor(
    runner: FLUX2KleinPipelineRunner
  ) -> PipelineNodeExecutor {
    PipelineNodeExecutor(
      kind: compositeNodeKind,
      validate: compositeNodeDiagnostics
    ) { node, inputs, context in
      guard let prompt = inputs["prompt"]?.value(as: String.self) else {
        throw PipelineEngineError.invalidInvocation(
          "FLUX.2 node \(node.id.rawValue) needs a prompt.")
      }
      let negativePrompt = inputs["negativePrompt"]?.value(as: String.self) ?? ""
      let seed = inputs["seed"]?.value(as: UInt64.self) ?? 0
      let width = node.parameters["width"]?.integerValue ?? 1024
      let height = node.parameters["height"]?.integerValue ?? 1024
      let steps = node.parameters["steps"]?.integerValue ?? 4
      let guidance = node.parameters["guidance"]?.numberValue ?? 1
      let referenceImage = inputs["referenceImage"]?.value(as: PipelineImageInput.self)
      let referenceGridName = node.parameters["referenceGrid"]?.stringValue ?? "half"
      guard let referenceGrid = ReferenceGrid(rawValue: referenceGridName) else {
        throw PipelineEngineError.invalidInvocation(
          "FLUX.2 reference grid must be full, half, or quarter.")
      }
      if inputs["referenceImage"] != nil && referenceImage == nil {
        throw PipelineEngineError.invalidInvocation(
          "FLUX.2 referenceImage needs a raster image.")
      }
      guard let denoiser = node.resources["denoiser"]?.linkedReference,
        let textEncoder = node.resources["textEncoder"]?.linkedReference,
        let vaeDecoder = node.resources["vaeDecoder"]?.linkedReference,
        denoiser.packageID == textEncoder.packageID,
        denoiser.packageID == vaeDecoder.packageID
      else {
        throw PipelineEngineError.modelPackageUnavailable(
          "FLUX.2 node \(node.id.rawValue) needs three components from one linked package.")
      }
      let root = try context.packageRoot(for: denoiser)
      let document = PipelineDocument(
        id: PipelineID(rawValue: "flux-composite-\(node.id.rawValue)"),
        name: "FLUX.2 composite execution",
        mode: .textToImage,
        nodes: [node],
        connections: [],
        primaryOutputNodeIDs: [node.id])
      let requirements = node.resources.keys.sorted().compactMap { slot in
        node.resources[slot]?.linkedReference.map {
          PipelineLinkedResourceRequirement(nodeID: node.id, slot: slot, reference: $0)
        }
      }
      let prepared = PreparedPipeline(
        document: document,
        semanticSHA256: context.semanticSHA256,
        orderedNodeIDs: [node.id],
        requiredResources: requirements)
      let image = try await runner.executeTextToImage(
        prepared,
        packageRoot: root,
        invocation: FLUX2KleinTextToImageInvocation(
          prompt: prompt, negativePrompt: negativePrompt, seed: seed,
          width: width, height: height, steps: steps, guidance: Float(guidance),
          referenceImage: referenceImage, referenceGrid: referenceGrid),
        progress: { update in
          if update.stage != .completed { await context.progress(update) }
        })
      return PipelineNodeResult(outputs: [
        "image": PipelineNodeValue(image, type: .image)
      ])
    }
  }

  private static func compositeNodeDiagnostics(_ node: PipelineNode) -> [PipelineDiagnostic] {
    func problem(_ message: String) -> PipelineDiagnostic {
      PipelineDiagnostic(
        severity: .error, code: .invalidParameter,
        message: message, nodeID: node.id)
    }
    var diagnostics: [PipelineDiagnostic] = []
    if node.parameters["width"]?.integerValue != 1024
      || node.parameters["height"]?.integerValue != 1024
    {
      diagnostics.append(problem("FLUX.2 Klein requires 1024×1024 output."))
    }
    if let steps = node.parameters["steps"]?.integerValue, !(1...20).contains(steps) {
      diagnostics.append(problem("FLUX.2 Klein supports 1–20 steps."))
    }
    if node.parameters["guidance"]?.numberValue != 1 {
      diagnostics.append(problem("FLUX.2 Klein Distilled requires guidance 1."))
    }
    if let grid = node.parameters["referenceGrid"]?.stringValue,
      ReferenceGrid(rawValue: grid) == nil {
      diagnostics.append(problem("FLUX.2 reference grid must be full, half, or quarter."))
    }
    let references = ["denoiser", "textEncoder", "vaeDecoder"].compactMap {
      node.resources[$0]?.linkedReference
    }
    if references.count == 3,
      references.contains(where: {
        $0.packageID != packageID || $0.familyABI != familyABI
      })
    {
      diagnostics.append(.init(
        severity: .error, code: .invalidResource,
        message: "FLUX.2 node resources must use its reviewed package identity and ABI.",
        nodeID: node.id))
    }
    return diagnostics
  }

  public static func defaultPackageURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let configured = environment["PIXELTJE_FLUX2_KLEIN_MODEL_PATH"], !configured.isEmpty {
      return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return homeDirectory.appendingPathComponent(
      "coreai-models/exports/FLUX.2-klein-4B", isDirectory: true)
  }

  public static func inspectPackage(
    at packageRoot: URL,
    for document: PipelineDocument? = nil,
    requiresImageConditioning: Bool = false
  ) -> FLUX2KleinPackageInspection {
    let root = resourcesDirectory(in: packageRoot)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return FLUX2KleinPackageInspection(
        packageRoot: packageRoot,
        missingComponents: ["package directory"])
    }

    var missing: [String] = []
    var mismatched: [String] = []
    var componentHashes: [Component: String] = [:]
    var versionHasher = SHA256()
    let needsImage = requiresImageConditioning || graphNeedsImageComponents(document)
    let components = needsImage ? Component.allCases : Component.core

    for component in components {
      let relativePath = component.resolvedPath(in: root)
      let bundle = root.appendingPathComponent(relativePath, isDirectory: true)
      let compiled = relativePath.hasSuffix(".aimodelc")
      let payload = bundle.appendingPathComponent(
        compiled ? "main-\(AIModel.deviceArchitectureName).mlirb" : "main.mlirb")
      let hashURL = bundle.appendingPathComponent("main.hash")
      guard isMaterializedFile(payload, minimumSize: compiled ? 1 : 1024),
        let hashData = try? Data(contentsOf: hashURL),
        hashData.count == 32
      else {
        missing.append(relativePath + "/" + payload.lastPathComponent + " or main.hash")
        continue
      }
      if compiled {
        let delegates = bundle.appendingPathComponent(
          "main-\(AIModel.deviceArchitectureName)-delegates", isDirectory: true)
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: delegates.path, isDirectory: &isDirectory)
          || !isDirectory.boolValue
        {
          missing.append(relativePath + "/" + delegates.lastPathComponent)
          continue
        }
        let metadata = bundle.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadata),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sourceHash = object["sourceHash"] as? String,
          sourceHash.count == 64, sourceHash.allSatisfy(\.isHexDigit)
        else {
          missing.append(relativePath + "/metadata.json sourceHash")
          continue
        }
      }
      componentHashes[component] = normalizedHash(hashData)
      versionHasher.update(data: Data(relativePath.utf8))
      versionHasher.update(data: Data([0]))
      versionHasher.update(data: hashData)
      versionHasher.update(data: Data([0]))
    }

    for sidecar in requiredSidecars {
      let url = root.appendingPathComponent(sidecar)
      if !isMaterializedFile(url, minimumSize: 1) { missing.append(sidecar) }
    }

    var incompatible: [String] = []
    if let problem = packageMetadataProblem(at: root) {
      incompatible.append(problem)
    }
    if needsImage,
      let data = try? Data(contentsOf: root.appendingPathComponent("metadata.json")),
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let assets = metadata["assets"] as? [String: Any],
      assets["vae_encoder"] as? String != Component.vaeEncoder.relativePath {
      incompatible.append("metadata.json must name VAEEncoder.aimodel for image conditioning")
    }

    if let document {
      let references = document.nodes.flatMap { node in
        node.resources.values.compactMap(\.linkedReference)
      }.filter { $0.familyABI == familyABI }
      let packageVersion = "sha256." + Data(versionHasher.finalize()).hexadecimalString
      let packageIDs = Set(references.map(\.packageID))
      if packageIDs.count != 1 {
        mismatched.append("package identity")
      }

      for component in components {
        let componentReferences = references.filter { component.roles.contains($0.componentRole) }
        if componentReferences.isEmpty {
          mismatched.append(component.primaryRole)
          continue
        }
        guard let actualHash = componentHashes[component] else { continue }
        if componentReferences.contains(where: {
          $0.kind != .coreAIModel || $0.familyABI != familyABI || $0.functionName != "main"
            || normalizedHash($0.contentHash) != actualHash
            || $0.packageVersion != packageVersion
        }) {
          mismatched.append(component.primaryRole)
        }
      }
    }

    return FLUX2KleinPackageInspection(
      packageRoot: packageRoot,
      missingComponents: Array(Set(missing)).sorted(),
      mismatchedComponents: Array(Set(mismatched)).sorted(),
      incompatibleComponents: Array(Set(incompatible)).sorted())
  }

  /// Performs the lightweight identity checks and then reads the Core AI function
  /// descriptor without loading transformer weights. This must run before Apple's
  /// diffusion helper constructs NDArrays: Core AI traps, rather than throws, when
  /// `resolvingDynamicDimensions` receives a shape with the wrong rank.
  public static func inspectPackageForExecution(
    at packageRoot: URL,
    for document: PipelineDocument? = nil,
    requiresImageConditioning: Bool = false,
    referenceGrid: ReferenceGrid = .half
  ) async -> FLUX2KleinPackageInspection {
    var inspection = inspectPackage(
      at: packageRoot, for: document,
      requiresImageConditioning: requiresImageConditioning)
    guard inspection.isUsable else { return inspection }

    do {
      let root = resourcesDirectory(in: packageRoot)
      let transformerURL = root.appendingPathComponent(
        Component.denoiser.resolvedPath(in: root), isDirectory: true)
      let model = try await AIModel(contentsOf: transformerURL)
      guard let descriptor = model.functionDescriptor(for: "main") else {
        inspection.incompatibleComponents.append("Transformer.aimodel has no main function")
        return inspection
      }
      let actual = descriptor.inputNames.compactMap { name -> FLUX2KleinTensorDescriptor? in
        guard case .ndArray(let input) = descriptor.inputDescriptor(of: name) else { return nil }
        return FLUX2KleinTensorDescriptor(
          name: name,
          shape: input.shape,
          scalarType: scalarTypeName(input.scalarType))
      }
      if let problem = transformerABIProblem(actual) {
        inspection.incompatibleComponents.append(problem)
      }
      let needsImage = requiresImageConditioning || graphNeedsImageComponents(document)
      if needsImage {
        let gridName = document?.nodes.first(where: { $0.kind == compositeNodeKind })?
          .parameters["referenceGrid"]?.stringValue ?? referenceGrid.rawValue
        if model.functionDescriptor(for: "img2img_\(gridName)") == nil {
          inspection.incompatibleComponents.append(
            "Transformer.aimodel has no img2img_\(gridName) function; export the complete multifunction macOS package")
        }
      }
    } catch is CancellationError {
      inspection.incompatibleComponents.append("Transformer.aimodel inspection was cancelled")
    } catch {
      inspection.incompatibleComponents.append("Transformer.aimodel descriptor could not be read")
    }
    return inspection
  }

  static func transformerABIProblem(
    _ actual: [FLUX2KleinTensorDescriptor]
  ) -> String? {
    if Array(actual.map(\.name).suffix(2)) == ["rotary_emb_cos", "rotary_emb_sin"] {
      return
        "Transformer.aimodel uses the legacy precomputed-RoPE ABI; "
        + "re-export it with the pinned apple/coreai-models revision"
    }
    guard actual == expectedTransformerInputs else {
      let inputs = actual.map { "\($0.name) \($0.shape) \($0.scalarType)" }.joined(separator: ", ")
      return "Transformer.aimodel main inputs (\(inputs)) do not match \(familyABI)"
    }
    return nil
  }

  private static func graphNeedsImageComponents(_ document: PipelineDocument?) -> Bool {
    guard let document else { return false }
    let fluxNodes = document.nodes.filter { $0.kind == compositeNodeKind }
    return fluxNodes.contains { $0.resources["vaeEncoder"] != nil }
      || document.connections.contains { connection in
        connection.input.port == "referenceImage"
          && fluxNodes.contains { $0.id == connection.input.nodeID }
      }
  }

  static func resourcesDirectory(in root: URL) -> URL {
    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    return FileManager.default.fileExists(atPath: resources.path) ? resources : root
  }

  static func packageMetadataProblem(at root: URL) -> String? {
    let metadataURL = root.appendingPathComponent("metadata.json")
    guard let data = try? Data(contentsOf: metadataURL),
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let source = metadata["source"] as? [String: Any],
      let diffusion = metadata["diffusion"] as? [String: Any],
      let assets = metadata["assets"] as? [String: Any],
      source["hf_model_id"] as? String == "black-forest-labs/FLUX.2-klein-4B",
      diffusion["guidance_embeds"] as? Bool == false,
      (diffusion["default_steps"] as? NSNumber)?.intValue == 4,
      (diffusion["default_guidance_scale"] as? NSNumber)?.doubleValue == 1,
      assets["transformer"] as? String == "Transformer.aimodel"
    else {
      return
        "metadata.json does not identify the reviewed guidance-distilled FLUX.2 Klein 4B Transformer.aimodel"
    }
    return nil
  }

  struct ExecutionActivity: Equatable, Sendable {
    var loadingModels: Set<PipelineNodeID>
    var preparing: Set<PipelineNodeID>
    var denoising: Set<PipelineNodeID>
    var output: Set<PipelineNodeID>
  }

  private enum Component: CaseIterable, Hashable {
    case denoiser
    case textEncoder
    case vaeDecoder
    case vaeEncoder

    static let core: [Self] = [.denoiser, .textEncoder, .vaeDecoder]

    var relativePath: String {
      switch self {
      case .denoiser: "Transformer.aimodel"
      case .textEncoder: "TextEncoder.aimodel"
      case .vaeDecoder: "VAEDecoder.aimodel"
      case .vaeEncoder: "VAEEncoder.aimodel"
      }
    }

    var roles: Set<String> {
      switch self {
      case .denoiser: ["denoiser"]
      case .textEncoder: ["textEncoder"]
      case .vaeDecoder: ["vae", "vaeDecoder"]
      case .vaeEncoder: ["vaeEncoder"]
      }
    }

    var primaryRole: String { roles.sorted().first! }

    func resolvedPath(in root: URL) -> String {
      let source = root.appendingPathComponent(relativePath, isDirectory: true)
      return FileManager.default.fileExists(atPath: source.path)
        ? relativePath : relativePath + "c"
    }
  }

  private static let requiredSidecars = [
    "metadata.json",
    "tokenizer/tokenizer.json",
    "tokenizer/tokenizer_config.json",
    "vae_bn_mean.npy",
    "vae_bn_var.npy",
  ]

  struct PackageKey: Equatable {
    struct FileFingerprint: Equatable {
      var path: String
      var size: UInt64
      var modifiedAt: Date?
      var fileID: String
      var contentSHA256: String?
    }

    var canonicalRoot: URL
    var componentHashes: [String]
    var files: [FileFingerprint]
  }

  /// The linked component hashes identify the reviewed models. File revisions
  /// also catch a replaced model payload whose main.hash was not updated;
  /// content digests cover the small metadata, tokenizer, and VAE sidecars that
  /// the pipeline constructor reads into the reusable object.
  static func packageKey(at packageRoot: URL) throws -> PackageKey {
    let root = resourcesDirectory(in: packageRoot).standardizedFileURL.resolvingSymlinksInPath()
    let componentHashes = try Component.core.map { component in
      let hashURL = root.appendingPathComponent(component.resolvedPath(in: root) + "/main.hash")
      return normalizedHash(try Data(contentsOf: hashURL))
    }
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
      throw PipelineEngineError.modelPackageUnavailable("Cannot inspect the FLUX.2 package files.")
    }
    var files: [PackageKey.FileFingerprint] = []
    for case let url as URL in enumerator {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
      let path = String(url.path.dropFirst(root.path.count + 1))
      let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
      let contentSHA256: String?
      if size > 1_048_576 && !path.hasPrefix("tokenizer/") {
        // Source MLIR and compiled delegate weights can total multiple GB.
        // Their linked main.hash plus filesystem identity/revision keeps this
        // repeat-request check bounded.
        contentSHA256 = nil
      } else {
        contentSHA256 = Data(SHA256.hash(data: try Data(contentsOf: url))).hexadecimalString
      }
      files.append(
        .init(
          path: path,
          size: size,
          modifiedAt: attributes[.modificationDate] as? Date,
          fileID: String(describing: attributes[.systemFileNumber]),
          contentSHA256: contentSHA256))
    }
    return PackageKey(
      canonicalRoot: root,
      componentHashes: componentHashes,
      files: files.sorted { $0.path < $1.path })
  }

  private static let expectedTransformerInputs = [
    FLUX2KleinTensorDescriptor(
      name: "hidden_states", shape: [1, 4096, 128], scalarType: "float16"),
    FLUX2KleinTensorDescriptor(
      name: "encoder_hidden_states", shape: [1, 512, 7680], scalarType: "float16"),
    FLUX2KleinTensorDescriptor(name: "timestep", shape: [1], scalarType: "float16"),
    FLUX2KleinTensorDescriptor(name: "guidance", shape: [1], scalarType: "float16"),
    FLUX2KleinTensorDescriptor(name: "img_ids", shape: [1, 4096, 4], scalarType: "float32"),
    FLUX2KleinTensorDescriptor(name: "txt_ids", shape: [1, 512, 4], scalarType: "float32"),
  ]

  private static func scalarTypeName(_ scalarType: NDArray.ScalarType) -> String {
    switch scalarType {
    case .float16: "float16"
    case .float32: "float32"
    default: String(describing: scalarType)
    }
  }

  private static func isMaterializedFile(_ url: URL, minimumSize: UInt64 = 1024) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
      let size = attributes[.size] as? NSNumber
    else { return false }
    guard size.uint64Value >= minimumSize else { return false }
    // Compiled MLIR entrypoints may be smaller than a Git LFS pointer's usual
    // size threshold; do not mistake such a pointer for a compiled asset.
    if size.uint64Value < 1024,
      let data = try? Data(contentsOf: url),
      String(decoding: data.prefix(42), as: UTF8.self).hasPrefix(
        "version https://git-lfs.github.com/spec/v1")
    {
      return false
    }
    return true
  }

  private static func normalizedHash(_ data: Data) -> String {
    if let string = String(data: data, encoding: .utf8) {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) { return trimmed }
    }
    return data.hexadecimalString
  }

  private static func normalizedHash(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: "sha256:", with: "")
  }

}

public actor FLUX2KleinPipelineRunner {
  private struct CachedPipeline {
    var key: FLUX2KleinPipelineFamily.PackageKey
    var pipeline: Flux2Pipeline
    var hasLoadedTransformer: Bool
  }

  // Keep only the denoiser hot between nearby calls. The text encoder and VAEs
  // still load on demand, so image-conditioned runs do not retain every model.
  private static let minimumWarmMemoryBytes: UInt64 = 24 * 1024 * 1024 * 1024
  private static let warmIdleSeconds: TimeInterval = 120

  private var idlePipeline: CachedPipeline?
  private var idleEvictionTask: Task<Void, Never>?
  private var idlePipelineVersion = 0
  private var selectedPackageKey: FLUX2KleinPipelineFamily.PackageKey?
  private var selectedPackageRequest = 0
  private var requestSequence = 0
  private var cacheLeaseInFlight = false

  public init() {}

  isolated deinit {
    idleEvictionTask?.cancel()
  }

  private func scheduleIdleEviction() {
    idleEvictionTask?.cancel()
    idlePipelineVersion += 1
    let version = idlePipelineVersion
    idleEvictionTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(Self.warmIdleSeconds)) }
      catch { return }
      await self?.evictIdlePipeline(version: version)
    }
  }

  private func evictIdlePipeline(version: Int) async {
    guard idlePipelineVersion == version else { return }
    idleEvictionTask = nil
    let cached = idlePipeline
    idlePipeline = nil
    if let cached { await cached.pipeline.unloadResources() }
  }

  public func executeTextToImage(
    _ prepared: PreparedPipeline,
    packageRoot: URL,
    invocation: FLUX2KleinTextToImageInvocation,
    progress: @escaping PipelineExecutionProgressHandler = { _ in }
  ) async throws -> PipelineGeneratedImage {
    // Reserve the one cache slot before actor reentrancy is possible. Any
    // overlapping request builds a temporary pipeline instead of sharing one.
    idleEvictionTask?.cancel()
    idleEvictionTask = nil
    idlePipelineVersion += 1
    let reservedPipeline = idlePipeline
    idlePipeline = nil
    requestSequence += 1
    let requestID = requestSequence
    let ownsCacheSlot = !cacheLeaseInFlight
    if ownsCacheSlot { cacheLeaseInFlight = true }
    var acquiredPipeline: Flux2Pipeline?
    var resourcesUnloaded = false
    let timingID = UUID().uuidString

    do {
      try Task.checkCancellation()
      await progress(.init(stage: .validating, message: "Validating FLUX.2 pipeline and package…"))
      guard prepared.document.nodes.count == 1,
        let node = prepared.document.nodes.first,
        node.kind == FLUX2KleinPipelineFamily.compositeNodeKind,
        prepared.document.requirements.familyABIs.isEmpty
      else {
        throw PipelineEngineError.unsupportedPipeline(
          "FLUX.2 execution requires one native generation node.")
      }
      let active: Set<PipelineNodeID> = [node.id]
      let activity = FLUX2KleinPipelineFamily.ExecutionActivity(
        loadingModels: active, preparing: active,
        denoising: active, output: active)

      guard !invocation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PipelineEngineError.invalidInvocation("Enter a prompt before running the pipeline.")
      }
      guard invocation.width == 1024, invocation.height == 1024 else {
        throw PipelineEngineError.invalidInvocation(
          "The selected FLUX.2 Klein package supports 1024×1024 text-to-image output.")
      }
      guard (1...20).contains(invocation.steps) else {
        throw PipelineEngineError.invalidInvocation("FLUX.2 Klein supports 1–20 sampling steps.")
      }
      guard invocation.guidance == 1 else {
        throw PipelineEngineError.invalidInvocation(
          "The distilled FLUX.2 Klein path uses guidance 1.0.")
      }
      guard let seed = UInt32(exactly: invocation.seed) else {
        throw PipelineEngineError.invalidInvocation(
          "FLUX.2 Klein seeds must be between 0 and \(UInt32.max).")
      }
      if invocation.referenceImage != nil,
        node.resources["vaeEncoder"]?.linkedReference == nil {
        throw PipelineEngineError.modelPackageUnavailable(
          "Image-conditioned FLUX.2 needs a linked VAE encoder. Relink the image-edit-capable export.")
      }

      let inspectionStart = DispatchTime.now().uptimeNanoseconds
      let inspection = await FLUX2KleinPipelineFamily.inspectPackageForExecution(
        at: packageRoot, for: prepared.document,
        requiresImageConditioning: invocation.referenceImage != nil,
        referenceGrid: invocation.referenceGrid)
      try Task.checkCancellation()
      guard inspection.isUsable else {
        if requestID >= selectedPackageRequest {
          selectedPackageKey = nil
          selectedPackageRequest = requestID
          let stale = idlePipeline
          idlePipeline = nil
          if let stale { await stale.pipeline.unloadResources() }
        }
        throw PipelineEngineError.modelPackageUnavailable(inspection.summary)
      }
      let validatedKey: FLUX2KleinPipelineFamily.PackageKey
      do {
        validatedKey = try FLUX2KleinPipelineFamily.packageKey(at: packageRoot)
      } catch {
        if requestID >= selectedPackageRequest {
          selectedPackageKey = nil
          selectedPackageRequest = requestID
          let stale = idlePipeline
          idlePipeline = nil
          if let stale { await stale.pipeline.unloadResources() }
        }
        throw error
      }
      Self.recordTiming("package_inspection", since: inspectionStart, requestID: timingID)
      var stalePipeline: CachedPipeline?
      if requestID >= selectedPackageRequest {
        if selectedPackageKey != validatedKey {
          stalePipeline = idlePipeline
          idlePipeline = nil
        }
        selectedPackageKey = validatedKey
        selectedPackageRequest = requestID
      }
      if let stalePipeline { await stalePipeline.pipeline.unloadResources() }

      if let reservedPipeline, reservedPipeline.key != validatedKey {
        await reservedPipeline.pipeline.unloadResources()
      }

      let root = FLUX2KleinPipelineFamily.resourcesDirectory(in: packageRoot)
      await progress(
        .init(
          stage: .loadingModels,
          message: "Loading FLUX.2 Core AI functions…",
          activeNodeIDs: activity.loadingModels))
      let acquisitionStart = DispatchTime.now().uptimeNanoseconds
      let reused = reservedPipeline?.key == validatedKey
      let pipeline: Flux2Pipeline
      if reused, let reservedPipeline {
        pipeline = reservedPipeline.pipeline
      } else {
        pipeline = try await Flux2Pipeline(from: root, config: .auto, mode: .full)
      }
      acquiredPipeline = pipeline
      if invocation.referenceImage != nil {
        guard pipeline.supportsImageToImage,
          pipeline.img2imgRoutes[invocation.referenceGrid] != nil else {
          throw PipelineEngineError.modelPackageUnavailable(
            "This FLUX.2 export needs VAEEncoder and an img2img transformer for the \(invocation.referenceGrid.rawValue) reference grid.")
        }
      }
      Self.recordTiming(
        "pipeline_acquisition", since: acquisitionStart, requestID: timingID,
        detail: reused
          ? (reservedPipeline?.hasLoadedTransformer == true ? "reused_hot" : "reused_unloaded")
          : "constructed")
      try Task.checkCancellation()

      let usesSharedTransformer = invocation.referenceImage == nil
        || pipeline.img2imgRoutes[invocation.referenceGrid]?.function === pipeline.transformer
      let keepTransformerLoaded = ownsCacheSlot && usesSharedTransformer
        && ProcessInfo.processInfo.physicalMemory >= Self.minimumWarmMemoryBytes
        && ProcessInfo.processInfo.environment["PIXELTJE_FLUX2_KLEIN_DISABLE_WARM_CACHE"] != "1"

      let configuration = PipelineConfiguration(
        prompt: invocation.prompt,
        negativePrompt: invocation.negativePrompt,
        seed: seed,
        stepCount: invocation.steps,
        guidanceScale: invocation.guidance,
        schedulerType: .discreteFlow,
        startingImage: try invocation.referenceImage.map(Self.cgImage),
        referenceGrid: invocation.referenceGrid,
        guidanceMode: .distilled,
        decodeResolution: .full,
        // In the pinned CoreAIDiffusion runtime, false leaves each function
        // resident after first use. We release all but the transformer below.
        lazyModelLoading: !keepTransformerLoaded)
      await progress(
        .init(
          stage: .preparing,
          message: "Preparing FLUX.2 conditioning and latent inputs…",
          completedUnitCount: 0,
          totalUnitCount: invocation.steps,
          activeNodeIDs: activity.preparing))
      let progressHandler = progress
      let (progressUpdates, progressContinuation) = AsyncStream.makeStream(
        of: (PipelineExecutionProgress, DispatchSemaphore).self)
      let progressTask = Task.detached {
        for await (update, acknowledgment) in progressUpdates {
          await progressHandler(update)
          acknowledgment.signal()
        }
      }
      let generationStart = DispatchTime.now().uptimeNanoseconds
      let generation: GenerationResult
      do {
        generation = try await pipeline.generateImages(configuration: configuration) { update in
          let shouldContinue = !Task.isCancelled
          let acknowledgment = DispatchSemaphore(value: 0)
          let result = progressContinuation.yield((
            .init(
              stage: .denoising,
              message: "Denoising step \(update.step) of \(update.totalSteps)…",
              completedUnitCount: update.step,
              totalUnitCount: update.totalSteps,
              activeNodeIDs: activity.denoising), acknowledgment))
          guard case .terminated = result else {
            acknowledgment.wait()
            return shouldContinue && !Task.isCancelled
          }
          return false
        }
        progressContinuation.finish()
        await progressTask.value
      } catch {
        progressContinuation.finish()
        await progressTask.value
        throw error
      }
      Self.recordTiming("generation", since: generationStart, requestID: timingID)
      if keepTransformerLoaded {
        await pipeline.textEncoder.unloadResources()
        await pipeline.decoder.unloadResources()
        if let encoder = pipeline.encoder { await encoder.unloadResources() }
      } else {
        await pipeline.unloadResources()
        resourcesUnloaded = true
      }
      try Task.checkCancellation()
      guard let image = generation.images.first else {
        throw PipelineEngineError.planningFailed("FLUX.2 completed without returning an image.")
      }
      let conversionStart = DispatchTime.now().uptimeNanoseconds
      let planarRGB = try Self.planarRGB(from: image)
      let result = PipelineGeneratedImage(
        width: image.width,
        height: image.height,
        planarRGB: planarRGB,
        encoding: .sRGBMinusOneToOne,
        semanticPipelineSHA256: prepared.semanticSHA256)
      Self.recordTiming("output_conversion", since: conversionStart, requestID: timingID)
      await progress(
        .init(
          stage: .decoding,
          message: "Finalizing decoded image…",
          completedUnitCount: invocation.steps,
          totalUnitCount: invocation.steps,
          activeNodeIDs: activity.output))
      await progress(
        .init(
          stage: .completed,
          message: "Pipeline completed.",
          completedUnitCount: invocation.steps,
          totalUnitCount: invocation.steps,
          preview: result))
      let hasLoadedTransformer = keepTransformerLoaded
        && selectedPackageKey == validatedKey
      if !hasLoadedTransformer && !resourcesUnloaded {
        await pipeline.unloadResources()
        resourcesUnloaded = true
      }
      if ownsCacheSlot, selectedPackageKey == validatedKey {
        idlePipeline = CachedPipeline(
          key: validatedKey, pipeline: pipeline,
          hasLoadedTransformer: hasLoadedTransformer)
        if hasLoadedTransformer { scheduleIdleEviction() }
      }
      if ownsCacheSlot { cacheLeaseInFlight = false }
      return result
    } catch {
      if let acquiredPipeline, !resourcesUnloaded { await acquiredPipeline.unloadResources() }
      if acquiredPipeline == nil, let reservedPipeline {
        await reservedPipeline.pipeline.unloadResources()
      }
      if ownsCacheSlot { cacheLeaseInFlight = false }
      throw error
    }
  }

  private static func recordTiming(
    _ stage: String, since start: UInt64, requestID: String, detail: String? = nil
  ) {
    guard ProcessInfo.processInfo.environment["PIXELTJE_FLUX2_KLEIN_TIMINGS"] == "1" else {
      return
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    let suffix = detail.map { " \($0)" } ?? ""
    fputs(
      "FLUX2 timing \(requestID) \(stage) \(String(format: "%.6f", seconds))s\(suffix)\n", stderr)
  }

  private static func cgImage(from raster: PipelineImageInput) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: raster.rgba.count)
    for index in bytes.indices {
      bytes[index] = UInt8((min(max(raster.rgba[index], 0), 1) * 255).rounded())
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(
        width: raster.width, height: raster.height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else {
      throw PipelineEngineError.invalidInvocation("Cannot prepare the FLUX.2 reference image.")
    }
    return image
  }

  private static func planarRGB(from image: CGImage) throws -> [Float] {
    let width = image.width
    let height = image.height
    let pixelCount = width * height
    var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw PipelineEngineError.planningFailed("Core Graphics could not create sRGB.")
    }
    let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      throw PipelineEngineError.planningFailed("Core Graphics could not read the generated image.")
    }

    var result = [Float](repeating: 0, count: pixelCount * 3)
    for index in 0..<pixelCount {
      result[index] = Float(rgba[index * 4]) / 127.5 - 1
      result[pixelCount + index] = Float(rgba[index * 4 + 1]) / 127.5 - 1
      result[2 * pixelCount + index] = Float(rgba[index * 4 + 2]) / 127.5 - 1
    }
    return result
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

extension Data {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

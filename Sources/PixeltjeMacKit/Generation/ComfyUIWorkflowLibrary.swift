import Combine
import Foundation
import PixeltjeMacDomain

struct ComfyUIWorkflowBindings: Codable, Equatable, Sendable {
  var prompt: ComfyUIParameterAddress?
  var negativePrompt: ComfyUIParameterAddress?
  var seed: ComfyUIParameterAddress?
  var steps: ComfyUIParameterAddress?
  var guidance: ComfyUIParameterAddress?
  var width: ComfyUIParameterAddress?
  var height: ComfyUIParameterAddress?
  var strength: ComfyUIParameterAddress?
  var sourceImage: ComfyUIParameterAddress?
  var maskImage: ComfyUIParameterAddress?

  var roles: [ComfyUIWorkflowRole: ComfyUIParameterAddress] {
    var result: [ComfyUIWorkflowRole: ComfyUIParameterAddress] = [:]
    if let prompt { result[.prompt] = prompt }
    if let negativePrompt { result[.negativePrompt] = negativePrompt }
    if let seed { result[.seed] = seed }
    if let steps { result[.steps] = steps }
    if let guidance { result[.guidance] = guidance }
    if let width { result[.width] = width }
    if let height { result[.height] = height }
    if let strength { result[.strength] = strength }
    return result
  }

  var runtimeRoles: [ComfyUIWorkflowRuntimeRole: ComfyUIParameterAddress] {
    var result: [ComfyUIWorkflowRuntimeRole: ComfyUIParameterAddress] = [:]
    if let sourceImage { result[.sourceImage] = sourceImage }
    if let maskImage { result[.maskImage] = maskImage }
    return result
  }
}

struct ComfyUIUserWorkflowManifest: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var id: String
  var name: String
  var mode: GenerationMode
  var frontendFilename: String
  var apiFilename: String
  var bindings: ComfyUIWorkflowBindings
  var outputNodeIDs: [String]
  var imageAlignment: Int
}

struct ComfyUIUserWorkflowDefinition: Equatable, Sendable {
  var manifest: ComfyUIUserWorkflowManifest
  var directoryURL: URL
  var frontendData: Data
  var apiData: Data

  var template: ComfyUIWorkflowTemplate {
    ComfyUIWorkflowTemplate(
      id: manifest.id,
      name: manifest.name,
      mode: manifest.mode,
      isBuiltIn: false)
  }

  var frontendURL: URL {
    directoryURL.appendingPathComponent(manifest.frontendFilename, isDirectory: false)
  }

  var apiURL: URL {
    directoryURL.appendingPathComponent(manifest.apiFilename, isDirectory: false)
  }
}

struct ComfyUIWorkflowInputCandidate: Identifiable, Equatable, Sendable {
  var address: ComfyUIParameterAddress
  var nodeTitle: String
  var classType: String

  var id: ComfyUIParameterAddress { address }
  var title: String { "\(nodeTitle) — \(address.displayValue)" }
}

struct ComfyUIWorkflowOutputCandidate: Identifiable, Equatable, Sendable {
  var nodeID: String
  var title: String
  var classType: String

  var id: String { nodeID }
}

struct ComfyUIWorkflowImportDraft: Equatable, Sendable {
  var name: String
  var mode: GenerationMode
  var bindings: ComfyUIWorkflowBindings
  var outputNodeID: String?
  var imageAlignment: Int
  var inputCandidates: [ComfyUIWorkflowInputCandidate]
  var outputCandidates: [ComfyUIWorkflowOutputCandidate]
  var frontendData: Data
  var apiData: Data
}

struct ComfyUIWorkflowLoadFailure: Identifiable, Equatable, Sendable {
  var directoryURL: URL
  var message: String

  var id: String { "\(directoryURL.path)\u{1F}\(message)" }
  var name: String { directoryURL.lastPathComponent }
}

/// The app-level source of user-installed ComfyUI workflow packages.
///
/// The SwiftUI surfaces observe the published summaries. Execution code reads
/// immutable definitions through the lock-protected snapshot methods so the
/// backend actors never depend on main-actor UI state.
final class ComfyUIWorkflowLibrary: ObservableObject, @unchecked Sendable {
  private static let maximumWorkflowCount = 64
  private static let maximumLibraryBytes = 128 * 1_024 * 1_024
  private static let maximumDirectoryEntries = 256

  private typealias LoadResult = (
    definitions: [String: ComfyUIUserWorkflowDefinition],
    failures: [ComfyUIWorkflowLoadFailure],
    didReadRoot: Bool
  )

  private struct DirectoryListing {
    var entries: [URL]
    var exceededLimit: Bool
  }

  static let shared: ComfyUIWorkflowLibrary = {
    let library = ComfyUIWorkflowLibrary(loadImmediately: false)
    Task { @MainActor in
      await library.reloadAsync()
    }
    return library
  }()

  static var defaultDirectoryURL: URL {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("Pixeltje", isDirectory: true)
      .appendingPathComponent("ComfyUI", isDirectory: true)
      .appendingPathComponent("Workflows", isDirectory: true)
  }

  @Published private(set) var customTemplates: [ComfyUIWorkflowTemplate]
  @Published private(set) var loadFailures: [ComfyUIWorkflowLoadFailure]
  @Published private(set) var isLoaded: Bool
  @Published private(set) var revision = UUID()

  let directoryURL: URL

  private let fileManager: FileManager
  private let lock = NSLock()
  private var definitionsByID: [String: ComfyUIUserWorkflowDefinition]
  private var mutationInProgress = false
  private var storageMutationGeneration = 0

  init(
    directoryURL: URL = ComfyUIWorkflowLibrary.defaultDirectoryURL,
    fileManager: FileManager = .default,
    loadImmediately: Bool = true
  ) {
    self.directoryURL = directoryURL
    self.fileManager = fileManager
    let loaded =
      loadImmediately
      ? Self.loadDefinitions(from: directoryURL, fileManager: fileManager)
      : LoadResult(definitions: [:], failures: [], didReadRoot: false)
    self.definitionsByID = loaded.definitions
    self.customTemplates = Self.sortedTemplates(loaded.definitions.values.map(\.template))
    self.loadFailures = loaded.failures
    self.isLoaded = loadImmediately
  }

  func customTemplatesSnapshot() -> [ComfyUIWorkflowTemplate] {
    lock.withLock { Self.sortedTemplates(definitionsByID.values.map(\.template)) }
  }

  func definitionSnapshot(for id: String) -> ComfyUIUserWorkflowDefinition? {
    lock.withLock { definitionsByID[id] }
  }

  func resolvedWorkflow(for id: String) throws -> ComfyUIResolvedWorkflow {
    guard let definition = definitionSnapshot(for: id) else {
      throw PixeltjeMacError(
        "Workflow unavailable", "The selected ComfyUI workflow is not installed.")
    }
    return ComfyUIResolvedWorkflow(
      template: definition.template,
      apiData: definition.apiData,
      frontendData: definition.frontendData,
      roles: definition.manifest.bindings.roles,
      runtimeRoles: definition.manifest.bindings.runtimeRoles,
      outputNodeIDs: definition.manifest.outputNodeIDs,
      imageAlignment: definition.manifest.imageAlignment,
      resultScaleAddress: nil,
      resultScaleNativeValue: nil)
  }

  @MainActor
  func reload() {
    apply(Self.loadDefinitions(from: directoryURL, fileManager: fileManager))
  }

  @MainActor
  func reloadAsync() async {
    let startingMutationGeneration = storageMutationGeneration
    let loaded = await Task.detached(priority: .userInitiated) { [self] in
      Self.loadDefinitions(from: directoryURL, fileManager: fileManager)
    }.value
    guard startingMutationGeneration == storageMutationGeneration else { return }
    apply(loaded)
  }

  @MainActor
  private func apply(_ loaded: LoadResult) {
    if loaded.didReadRoot {
      lock.withLock { definitionsByID = loaded.definitions }
      customTemplates = Self.sortedTemplates(loaded.definitions.values.map(\.template))
    }
    loadFailures = loaded.failures
    isLoaded = true
    revision = UUID()
  }

  @MainActor
  func ensureDirectory() throws -> URL {
    try createDirectory()
  }

  func ensureDirectoryAsync() async throws -> URL {
    try await Task.detached(priority: .userInitiated) { [self] in
      try createDirectory()
    }.value
  }

  private func createDirectory() throws -> URL {
    try fileManager.createDirectory(
      at: directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return directoryURL
  }

  func prepareImport(from urls: [URL]) throws -> ComfyUIWorkflowImportDraft {
    guard urls.count == 2 else {
      throw PixeltjeMacError(
        "Workflow files required",
        "Select the regular ComfyUI workflow and its matching API-format export.")
    }

    let payloads = try urls.map { url -> (url: URL, data: Data, object: [String: Any]) in
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true else {
        throw PixeltjeMacError("Workflow unavailable", "\(url.lastPathComponent) is not a file.")
      }
      if let size = values.fileSize, size > 32 * 1_024 * 1_024 {
        throw PixeltjeMacError(
          "Workflow too large", "Each workflow JSON file must be 32 MiB or smaller.")
      }
      let data = try Data(contentsOf: url)
      guard data.count <= 32 * 1_024 * 1_024 else {
        throw PixeltjeMacError(
          "Workflow too large", "Each workflow JSON file must be 32 MiB or smaller.")
      }
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw PixeltjeMacError(
          "Workflow invalid", "\(url.lastPathComponent) is not a JSON object.")
      }
      return (url, data, object)
    }

    guard let api = payloads.first(where: { Self.isAPIWorkflow($0.object) }),
      let frontend = payloads.first(where: { Self.isFrontendWorkflow($0.object) }),
      api.url != frontend.url
    else {
      throw PixeltjeMacError(
        "Workflow pair invalid",
        "Select one regular ComfyUI workflow and one API-format workflow export.")
    }

    let inputs = Self.inputCandidates(in: api.object)
    let outputs = Self.outputCandidates(in: api.object)
    guard !outputs.isEmpty else {
      throw PixeltjeMacError(
        "Workflow output unavailable",
        "The API workflow needs a Save Image or Preview Image output node.")
    }

    var bindings = ComfyUIWorkflowBindings()
    bindings.prompt = Self.suggestedInput(
      in: inputs, inputNames: ["text", "prompt", "value"], excluding: ["negative"])
    bindings.negativePrompt = Self.suggestedInput(
      in: inputs, inputNames: ["text", "negative_prompt", "negative"], requiring: ["negative"])
    bindings.seed = Self.suggestedInput(
      in: inputs, inputNames: ["seed", "noise_seed"])
    bindings.steps = Self.suggestedInput(in: inputs, inputNames: ["steps"])
    bindings.guidance = Self.suggestedInput(
      in: inputs, inputNames: ["cfg", "guidance"])
    bindings.width = Self.suggestedInput(in: inputs, inputNames: ["width"])
    bindings.height = Self.suggestedInput(in: inputs, inputNames: ["height"])
    bindings.strength = Self.suggestedInput(
      in: inputs, inputNames: ["strength", "denoise"])

    let imageInputs = inputs.filter {
      $0.classType.localizedCaseInsensitiveContains("loadimage")
        || $0.address.inputName.localizedCaseInsensitiveContains("image")
    }
    bindings.maskImage =
      imageInputs.first(where: {
        ($0.nodeTitle + " " + $0.address.inputName).localizedCaseInsensitiveContains("mask")
      })?.address
    bindings.sourceImage = imageInputs.first(where: { $0.address != bindings.maskImage })?.address

    let stem = frontend.url.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: "-api", with: "")
      .replacingOccurrences(of: "_api", with: "")
    return ComfyUIWorkflowImportDraft(
      name: Self.humanized(stem),
      mode: .textToImage,
      bindings: bindings,
      outputNodeID: outputs.first?.nodeID,
      imageAlignment: 8,
      inputCandidates: inputs,
      outputCandidates: outputs,
      frontendData: frontend.data,
      apiData: api.data)
  }

  func prepareImportAsync(from urls: [URL]) async throws -> ComfyUIWorkflowImportDraft {
    try await Task.detached(priority: .userInitiated) { [self] in
      try prepareImport(from: urls)
    }.value
  }

  func editDraft(for id: String) throws -> ComfyUIWorkflowImportDraft {
    guard let definition = definitionSnapshot(for: id) else {
      throw PixeltjeMacError(
        "Workflow unavailable", "Only user-installed workflows can be edited.")
    }
    let frontendData = definition.frontendData
    let apiData = definition.apiData
    guard let api = try JSONSerialization.jsonObject(with: apiData) as? [String: Any],
      Self.isAPIWorkflow(api)
    else {
      throw PixeltjeMacError("Workflow invalid", "The installed API workflow is invalid.")
    }
    return ComfyUIWorkflowImportDraft(
      name: definition.manifest.name,
      mode: definition.manifest.mode,
      bindings: definition.manifest.bindings,
      outputNodeID: definition.manifest.outputNodeIDs.first,
      imageAlignment: definition.manifest.imageAlignment,
      inputCandidates: Self.inputCandidates(in: api),
      outputCandidates: Self.outputCandidates(in: api),
      frontendData: frontendData,
      apiData: apiData)
  }

  func editDraftAsync(for id: String) async throws -> ComfyUIWorkflowImportDraft {
    try await Task.detached(priority: .userInitiated) { [self] in
      try editDraft(for: id)
    }.value
  }

  @MainActor
  @discardableResult
  func install(_ draft: ComfyUIWorkflowImportDraft) throws -> String {
    try beginMutation()
    defer { endMutation() }
    let id = "user-\(UUID().uuidString.lowercased())"
    try validateCapacity(for: draft, replacingID: nil)
    try write(draft, id: id, replacing: false)
    return id
  }

  @MainActor
  @discardableResult
  func installAsync(_ draft: ComfyUIWorkflowImportDraft) async throws -> String {
    try beginMutation()
    defer { endMutation() }
    let id = "user-\(UUID().uuidString.lowercased())"
    try validateCapacity(for: draft, replacingID: nil)
    let definition = try await Task.detached(priority: .userInitiated) { [self] in
      try writePackage(draft, id: id, replacing: false)
    }.value
    publishInstalled(definition)
    return id
  }

  @MainActor
  func update(_ draft: ComfyUIWorkflowImportDraft, id: String) throws {
    try beginMutation()
    defer { endMutation() }
    guard definitionSnapshot(for: id) != nil else {
      throw PixeltjeMacError(
        "Workflow unavailable", "Only user-installed workflows can be edited.")
    }
    try validateCapacity(for: draft, replacingID: id)
    try write(draft, id: id, replacing: true)
  }

  @MainActor
  func updateAsync(_ draft: ComfyUIWorkflowImportDraft, id: String) async throws {
    try beginMutation()
    defer { endMutation() }
    guard definitionSnapshot(for: id) != nil else {
      throw PixeltjeMacError(
        "Workflow unavailable", "Only user-installed workflows can be edited.")
    }
    try validateCapacity(for: draft, replacingID: id)
    let definition = try await Task.detached(priority: .userInitiated) { [self] in
      try writePackage(draft, id: id, replacing: true)
    }.value
    publishInstalled(definition)
  }

  @MainActor
  private func write(
    _ draft: ComfyUIWorkflowImportDraft,
    id: String,
    replacing: Bool
  ) throws {
    publishInstalled(try writePackage(draft, id: id, replacing: replacing))
  }

  private func writePackage(
    _ draft: ComfyUIWorkflowImportDraft,
    id: String,
    replacing: Bool
  ) throws -> ComfyUIUserWorkflowDefinition {
    guard draft.frontendData.count <= 32 * 1_024 * 1_024,
      draft.apiData.count <= 32 * 1_024 * 1_024
    else {
      throw PixeltjeMacError(
        "Workflow too large", "Each workflow JSON file must be 32 MiB or smaller.")
    }
    var normalizedDraft = draft
    normalizedDraft.bindings = Self.normalizedBindings(draft.bindings, for: draft.mode)
    if normalizedDraft.mode != .inpainting {
      normalizedDraft.imageAlignment = 8
    }
    try Self.validate(normalizedDraft)
    let manifest = ComfyUIUserWorkflowManifest(
      schemaVersion: ComfyUIUserWorkflowManifest.currentSchemaVersion,
      id: id,
      name: normalizedDraft.name.trimmingCharacters(in: .whitespacesAndNewlines),
      mode: normalizedDraft.mode,
      frontendFilename: "workflow.json",
      apiFilename: "workflow-api.json",
      bindings: normalizedDraft.bindings,
      outputNodeIDs: [normalizedDraft.outputNodeID!],
      imageAlignment: normalizedDraft.mode == .inpainting ? normalizedDraft.imageAlignment : 8)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let manifestData = try encoder.encode(manifest)
    guard manifestData.count <= 1 * 1_024 * 1_024 else {
      throw PixeltjeMacError(
        "Workflow metadata too large", "The workflow name and node bindings are too large.")
    }

    try fileManager.createDirectory(
      at: directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if !replacing {
      let listing = try Self.boundedDirectoryEntries(
        at: directoryURL,
        fileManager: fileManager,
        limit: Self.maximumDirectoryEntries)
      guard !listing.exceededLimit,
        listing.entries.count < Self.maximumDirectoryEntries
      else {
        throw PixeltjeMacError(
          "Workflow folder full",
          "Remove an entry from the Workflows folder before adding another workflow.")
      }
    }
    let staging = directoryURL.appendingPathComponent(
      ".install-\(UUID().uuidString)", isDirectory: true)
    let destination = directoryURL.appendingPathComponent(id, isDirectory: true)
    do {
      try fileManager.createDirectory(
        at: staging, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try normalizedDraft.frontendData.write(
        to: staging.appendingPathComponent(manifest.frontendFilename), options: .atomic)
      try normalizedDraft.apiData.write(
        to: staging.appendingPathComponent(manifest.apiFilename), options: .atomic)
      try manifestData.write(
        to: staging.appendingPathComponent("manifest.json"), options: .atomic)
      if replacing {
        _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
      } else {
        try fileManager.moveItem(at: staging, to: destination)
      }
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
    return ComfyUIUserWorkflowDefinition(
      manifest: manifest,
      directoryURL: destination,
      frontendData: normalizedDraft.frontendData,
      apiData: normalizedDraft.apiData)
  }

  private func validateCapacity(
    for draft: ComfyUIWorkflowImportDraft,
    replacingID: String?
  ) throws {
    let definitions = lock.withLock { definitionsByID }
    let oldDefinition = replacingID.flatMap { definitions[$0] }
    let resultingCount = definitions.count + (oldDefinition == nil ? 1 : 0)
    guard resultingCount <= Self.maximumWorkflowCount else {
      throw PixeltjeMacError(
        "Workflow library full",
        "At most \(Self.maximumWorkflowCount) added workflows can be installed.")
    }
    let retainedBytes = definitions.values.reduce(into: 0) { total, definition in
      total += definition.apiData.count + definition.frontendData.count
    }
    let oldBytes = oldDefinition.map { $0.apiData.count + $0.frontendData.count } ?? 0
    let resultingBytes = retainedBytes - oldBytes + draft.apiData.count + draft.frontendData.count
    guard resultingBytes <= Self.maximumLibraryBytes else {
      throw PixeltjeMacError(
        "Workflow library too large",
        "Installed workflow JSON is limited to 128 MiB in total.")
    }
  }

  @MainActor
  private func beginMutation() throws {
    guard isLoaded else {
      throw PixeltjeMacError(
        "Workflow library loading", "Wait for the installed workflows to finish loading.")
    }
    guard !mutationInProgress else {
      throw PixeltjeMacError(
        "Workflow library busy", "Wait for the current workflow change to finish.")
    }
    mutationInProgress = true
  }

  @MainActor
  private func endMutation() {
    mutationInProgress = false
  }

  @MainActor
  private func publishInstalled(_ definition: ComfyUIUserWorkflowDefinition) {
    lock.withLock { definitionsByID[definition.manifest.id] = definition }
    customTemplates = customTemplatesSnapshot()
    loadFailures.removeAll {
      $0.directoryURL.standardizedFileURL == definition.directoryURL.standardizedFileURL
    }
    storageMutationGeneration += 1
    revision = UUID()
  }

  @MainActor
  private func publishRemoved(id: String, directoryURL: URL) {
    lock.withLock { definitionsByID[id] = nil }
    customTemplates = customTemplatesSnapshot()
    loadFailures.removeAll {
      $0.directoryURL.standardizedFileURL == directoryURL.standardizedFileURL
    }
    storageMutationGeneration += 1
    revision = UUID()
  }

  @MainActor
  func removeWorkflow(id: String) throws {
    try beginMutation()
    defer { endMutation() }
    guard let definition = definitionSnapshot(for: id) else {
      throw PixeltjeMacError(
        "Workflow unavailable", "Only user-installed workflows can be removed.")
    }
    var trashedURL: NSURL?
    try fileManager.trashItem(at: definition.directoryURL, resultingItemURL: &trashedURL)
    publishRemoved(id: id, directoryURL: definition.directoryURL)
  }

  @MainActor
  func removeWorkflowAsync(id: String) async throws {
    try beginMutation()
    defer { endMutation() }
    guard let definition = definitionSnapshot(for: id) else {
      throw PixeltjeMacError(
        "Workflow unavailable", "Only user-installed workflows can be removed.")
    }
    try await Task.detached(priority: .userInitiated) { [self] in
      var trashedURL: NSURL?
      try fileManager.trashItem(
        at: definition.directoryURL, resultingItemURL: &trashedURL)
    }.value
    publishRemoved(id: id, directoryURL: definition.directoryURL)
  }

  private static func validate(_ draft: ComfyUIWorkflowImportDraft) throws {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw PixeltjeMacError("Workflow name required", "Enter a name for this workflow.")
    }
    guard name.utf8.count <= 256 else {
      throw PixeltjeMacError(
        "Workflow name too long", "Keep the workflow name to 256 UTF-8 bytes or fewer.")
    }
    guard let output = draft.outputNodeID,
      draft.outputCandidates.contains(where: { $0.nodeID == output })
    else {
      throw PixeltjeMacError("Workflow output required", "Choose the output image node.")
    }
    guard let prompt = draft.bindings.prompt,
      draft.inputCandidates.contains(where: { $0.address == prompt })
    else {
      throw PixeltjeMacError("Prompt binding required", "Choose the workflow's prompt input.")
    }
    let everyBinding =
      Array(draft.bindings.roles.values)
      + Array(draft.bindings.runtimeRoles.values)
    guard Set(everyBinding).count == everyBinding.count else {
      throw PixeltjeMacError(
        "Workflow bindings overlap",
        "Each workflow role must use a different node ID and input name.")
    }
    guard
      everyBinding.allSatisfy({ address in
        draft.inputCandidates.contains(where: { $0.address == address })
      })
    else {
      throw PixeltjeMacError(
        "Workflow binding invalid",
        "Every node ID and input name must identify an editable input in the API workflow.")
    }
    guard let api = try JSONSerialization.jsonObject(with: draft.apiData) as? [String: Any],
      Self.rawInput(at: prompt, in: api) is String
    else {
      throw PixeltjeMacError(
        "Prompt binding invalid", "The prompt must be bound to a text input.")
    }
    if let address = draft.bindings.negativePrompt,
      !Self.isStringScalar(Self.rawInput(at: address, in: api))
    {
      throw PixeltjeMacError(
        "Negative prompt binding invalid", "The negative prompt must be bound to a text input.")
    }
    for (label, address) in [
      ("Seed", draft.bindings.seed),
      ("Steps", draft.bindings.steps),
      ("Width", draft.bindings.width),
      ("Height", draft.bindings.height),
    ] {
      guard let address else { continue }
      guard Self.isIntegerScalar(Self.rawInput(at: address, in: api)) else {
        throw PixeltjeMacError(
          "\(label) binding invalid", "The \(label.lowercased()) must be bound to an integer input."
        )
      }
    }
    for (label, address) in [
      ("Guidance", draft.bindings.guidance),
      ("Strength", draft.bindings.strength),
    ] {
      guard let address else { continue }
      guard Self.isNumericScalar(Self.rawInput(at: address, in: api)) else {
        throw PixeltjeMacError(
          "\(label) binding invalid", "The \(label.lowercased()) must be bound to a number input.")
      }
    }
    switch draft.mode {
    case .textToImage:
      guard draft.imageAlignment == 8 else {
        throw PixeltjeMacError(
          "Image alignment invalid", "Generation workflows must use 8-pixel alignment.")
      }
      guard draft.bindings.sourceImage == nil, draft.bindings.maskImage == nil else {
        throw PixeltjeMacError(
          "Workflow bindings invalid",
          "Generation workflows cannot include source-image or mask-image bindings.")
      }
    case .imageToImage, .selection:
      guard draft.imageAlignment == 8 else {
        throw PixeltjeMacError(
          "Image alignment invalid", "Edit and selection workflows must use 8-pixel alignment.")
      }
      guard draft.bindings.maskImage == nil else {
        throw PixeltjeMacError(
          "Workflow bindings invalid", "Edit and selection workflows cannot include a mask binding."
        )
      }
      guard let source = draft.bindings.sourceImage,
        draft.inputCandidates.contains(where: { $0.address == source }),
        Self.rawInput(at: source, in: api) is String
      else {
        throw PixeltjeMacError(
          "Source binding required", "Choose where Pixeltje should provide the source image.")
      }
    case .inpainting:
      guard let source = draft.bindings.sourceImage,
        draft.inputCandidates.contains(where: { $0.address == source }),
        Self.rawInput(at: source, in: api) is String,
        let mask = draft.bindings.maskImage,
        draft.inputCandidates.contains(where: { $0.address == mask }),
        Self.rawInput(at: mask, in: api) is String
      else {
        throw PixeltjeMacError(
          "Inpaint bindings required",
          "Choose where Pixeltje should provide both the source image and mask image.")
      }
      guard [8, 16, 32, 64].contains(draft.imageAlignment) else {
        throw PixeltjeMacError(
          "Image alignment invalid", "Choose an image alignment of 8, 16, 32, or 64 pixels.")
      }
    }
  }

  private static func normalizedBindings(
    _ bindings: ComfyUIWorkflowBindings,
    for mode: GenerationMode
  ) -> ComfyUIWorkflowBindings {
    var normalized = bindings
    switch mode {
    case .textToImage:
      normalized.sourceImage = nil
      normalized.maskImage = nil
    case .imageToImage, .selection:
      normalized.maskImage = nil
    case .inpainting:
      break
    }
    return normalized
  }

  private static func loadDefinitions(
    from root: URL,
    fileManager: FileManager
  ) -> LoadResult {
    let listing: DirectoryListing
    do {
      listing = try boundedDirectoryEntries(
        at: root, fileManager: fileManager, limit: maximumDirectoryEntries)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return ([:], [], true)
    } catch {
      return (
        [:],
        [ComfyUIWorkflowLoadFailure(directoryURL: root, message: error.userFacingMessage)],
        false
      )
    }

    var definitions: [String: ComfyUIUserWorkflowDefinition] = [:]
    var failures: [ComfyUIWorkflowLoadFailure] = []
    var retainedBytes = 0
    let sortedDirectories = listing.entries.sorted(by: {
      $0.lastPathComponent < $1.lastPathComponent
    })
    if listing.exceededLimit {
      failures.append(
        ComfyUIWorkflowLoadFailure(
          directoryURL: root,
          message:
            "Only the first \(maximumDirectoryEntries) workflow-folder entries were inspected."))
    }
    for directory in sortedDirectories {
      if definitions.count >= maximumWorkflowCount {
        failures.append(
          ComfyUIWorkflowLoadFailure(
            directoryURL: root,
            message: "At most \(maximumWorkflowCount) added workflows can be loaded."))
        break
      }
      do {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        let manifest = try JSONDecoder().decode(
          ComfyUIUserWorkflowManifest.self,
          from: try installedFileData(
            at: manifestURL, maximumSize: 1 * 1_024 * 1_024))
        guard manifest.schemaVersion == ComfyUIUserWorkflowManifest.currentSchemaVersion,
          manifest.id == directory.lastPathComponent,
          manifest.id.hasPrefix("user-"),
          UUID(uuidString: String(manifest.id.dropFirst("user-".count))) != nil,
          !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !manifest.outputNodeIDs.isEmpty,
          manifest.frontendFilename == "workflow.json",
          manifest.apiFilename == "workflow-api.json"
        else {
          throw PixeltjeMacError(
            "Workflow manifest invalid", "The installed workflow metadata is not valid.")
        }
        let frontendURL = directory.appendingPathComponent(
          manifest.frontendFilename, isDirectory: false)
        let apiURL = directory.appendingPathComponent(manifest.apiFilename, isDirectory: false)
        let apiData = try installedFileData(
          at: apiURL, maximumSize: 32 * 1_024 * 1_024)
        guard let api = try JSONSerialization.jsonObject(with: apiData) as? [String: Any],
          isAPIWorkflow(api)
        else {
          throw PixeltjeMacError(
            "Workflow invalid", "The installed API workflow is not executable ComfyUI JSON.")
        }
        let frontendData = try installedFileData(
          at: frontendURL, maximumSize: 32 * 1_024 * 1_024)
        let packageBytes = apiData.count + frontendData.count
        guard packageBytes <= maximumLibraryBytes - retainedBytes else {
          throw PixeltjeMacError(
            "Workflow library too large",
            "Installed workflow JSON is limited to 128 MiB in total.")
        }
        guard
          let frontend = try JSONSerialization.jsonObject(with: frontendData)
            as? [String: Any], isFrontendWorkflow(frontend)
        else {
          throw PixeltjeMacError(
            "Workflow invalid", "The installed frontend workflow is not ComfyUI workflow JSON.")
        }
        let inputs = inputCandidates(in: api)
        let outputs = outputCandidates(in: api)
        guard Set(manifest.outputNodeIDs).count == manifest.outputNodeIDs.count,
          manifest.outputNodeIDs.allSatisfy({ outputID in
            outputs.contains(where: { $0.nodeID == outputID })
          })
        else {
          throw PixeltjeMacError(
            "Workflow output invalid",
            "Every installed output ID must identify a Save Image or Preview Image node.")
        }
        try validate(
          ComfyUIWorkflowImportDraft(
            name: manifest.name,
            mode: manifest.mode,
            bindings: manifest.bindings,
            outputNodeID: manifest.outputNodeIDs.first,
            imageAlignment: manifest.imageAlignment,
            inputCandidates: inputs,
            outputCandidates: outputs,
            frontendData: frontendData,
            apiData: apiData))
        guard definitions[manifest.id] == nil else {
          throw PixeltjeMacError("Workflow duplicated", "The workflow ID is already installed.")
        }
        definitions[manifest.id] = ComfyUIUserWorkflowDefinition(
          manifest: manifest,
          directoryURL: directory,
          frontendData: frontendData,
          apiData: apiData)
        retainedBytes += packageBytes
      } catch {
        failures.append(
          ComfyUIWorkflowLoadFailure(
            directoryURL: directory, message: error.userFacingMessage))
      }
    }
    return (definitions, failures, true)
  }

  private static func boundedDirectoryEntries(
    at root: URL,
    fileManager: FileManager,
    limit: Int
  ) throws -> DirectoryListing {
    let attributes = try fileManager.attributesOfItem(atPath: root.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw PixeltjeMacError(
        "Workflow folder unavailable", "The configured workflow location is not a folder.")
    }

    var enumerationError: Error?
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw PixeltjeMacError(
        "Workflow folder unavailable", "The workflow folder could not be inspected.")
    }

    var entries: [URL] = []
    while let entry = enumerator.nextObject() as? URL {
      entries.append(entry)
      if entries.count > limit { break }
    }
    if let enumerationError { throw enumerationError }
    let exceededLimit = entries.count > limit
    if exceededLimit { entries.removeLast(entries.count - limit) }
    return DirectoryListing(entries: entries, exceededLimit: exceededLimit)
  }

  private static func installedFileData(
    at url: URL,
    maximumSize: Int
  ) throws -> Data {
    let values = try url.resourceValues(forKeys: [
      .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw PixeltjeMacError(
        "Workflow file invalid", "\(url.lastPathComponent) must be a regular package file.")
    }
    guard values.fileSize.map({ $0 <= maximumSize }) ?? false else {
      throw PixeltjeMacError(
        "Workflow too large", "\(url.lastPathComponent) exceeds the installed size limit.")
    }
    let data = try Data(contentsOf: url)
    guard data.count <= maximumSize else {
      throw PixeltjeMacError(
        "Workflow too large", "\(url.lastPathComponent) exceeds the installed size limit.")
    }
    return data
  }

  private static func isAPIWorkflow(_ object: [String: Any]) -> Bool {
    guard !object.isEmpty else { return false }
    return object.values.allSatisfy { value in
      guard let node = value as? [String: Any] else { return false }
      return node["class_type"] is String && node["inputs"] is [String: Any]
    }
  }

  private static func isFrontendWorkflow(_ object: [String: Any]) -> Bool {
    object["nodes"] is [[String: Any]]
  }

  private static func rawInput(
    at address: ComfyUIParameterAddress,
    in workflow: [String: Any]
  ) -> Any? {
    ((workflow[address.nodeID] as? [String: Any])?["inputs"] as? [String: Any])?[
      address.inputName]
  }

  private static func isStringScalar(_ value: Any?) -> Bool {
    guard let value, let scalar = ComfyUIParameterValue.workflowScalar(value) else {
      return false
    }
    if case .string = scalar { return true }
    return false
  }

  private static func isIntegerScalar(_ value: Any?) -> Bool {
    guard let value, let scalar = ComfyUIParameterValue.workflowScalar(value) else {
      return false
    }
    switch scalar {
    case .signedInteger, .unsignedInteger: return true
    default: return false
    }
  }

  private static func isNumericScalar(_ value: Any?) -> Bool {
    guard let value, let scalar = ComfyUIParameterValue.workflowScalar(value) else {
      return false
    }
    switch scalar {
    case .signedInteger, .unsignedInteger, .decimal: return true
    default: return false
    }
  }

  private static func inputCandidates(
    in workflow: [String: Any]
  ) -> [ComfyUIWorkflowInputCandidate] {
    var result: [ComfyUIWorkflowInputCandidate] = []
    for nodeID in workflow.keys.sorted(by: compareNodeIDs) {
      guard let node = workflow[nodeID] as? [String: Any],
        let classType = node["class_type"] as? String,
        let inputs = node["inputs"] as? [String: Any]
      else { continue }
      let title = (node["_meta"] as? [String: Any])?["title"] as? String ?? classType
      for inputName in inputs.keys.sorted() {
        guard let value = inputs[inputName], value is String || value is NSNumber else { continue }
        result.append(
          ComfyUIWorkflowInputCandidate(
            address: ComfyUIParameterAddress(nodeID: nodeID, inputName: inputName),
            nodeTitle: title,
            classType: classType))
      }
    }
    return result
  }

  private static func outputCandidates(
    in workflow: [String: Any]
  ) -> [ComfyUIWorkflowOutputCandidate] {
    workflow.compactMap { nodeID, value in
      guard let node = value as? [String: Any],
        let classType = node["class_type"] as? String
      else { return nil }
      let lower = classType.lowercased()
      guard lower.contains("saveimage") || lower.contains("previewimage") else { return nil }
      let title = (node["_meta"] as? [String: Any])?["title"] as? String ?? classType
      return ComfyUIWorkflowOutputCandidate(
        nodeID: nodeID, title: "\(title) — \(nodeID)", classType: classType)
    }
    .sorted { compareNodeIDs($0.nodeID, $1.nodeID) }
  }

  private static func suggestedInput(
    in candidates: [ComfyUIWorkflowInputCandidate],
    inputNames: [String],
    requiring requiredTerms: [String] = [],
    excluding excludedTerms: [String] = []
  ) -> ComfyUIParameterAddress? {
    candidates.first { candidate in
      let input = candidate.address.inputName.lowercased()
      let description = "\(candidate.nodeTitle) \(candidate.classType) \(input)".lowercased()
      return inputNames.contains(input)
        && requiredTerms.allSatisfy(description.contains)
        && excludedTerms.allSatisfy { !description.contains($0) }
    }?.address
  }

  private static func sortedTemplates(
    _ templates: [ComfyUIWorkflowTemplate]
  ) -> [ComfyUIWorkflowTemplate] {
    let modeOrder = Dictionary(
      uniqueKeysWithValues:
        ComfyUIWorkflowCatalog.modes.enumerated().map { ($0.element, $0.offset) })
    return templates.sorted {
      let left = modeOrder[$0.mode] ?? Int.max
      let right = modeOrder[$1.mode] ?? Int.max
      if left == right {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return left < right
    }
  }

  private static func humanized(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  private static func numericNodeID(_ value: String) -> Int {
    Int(value) ?? Int.max
  }

  private static func compareNodeIDs(_ lhs: String, _ rhs: String) -> Bool {
    let left = numericNodeID(lhs)
    let right = numericNodeID(rhs)
    if left == right { return lhs < rhs }
    return left < right
  }
}

import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func customComfyUIWorkflowImportPersistsExplicitImageBindings() throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }

  var draft = try fixture.library.prepareImport(
    from: [fixture.frontendURL, fixture.apiURL])
  draft.name = "Studio Inpaint"
  draft.mode = .inpainting
  draft.imageAlignment = 16
  draft.bindings.sourceImage = fixture.sourceAddress
  draft.bindings.maskImage = fixture.maskAddress

  let workflowID = try fixture.library.install(draft)
  let installedDirectory = fixture.libraryRoot.appendingPathComponent(
    workflowID, isDirectory: true)
  let manifestURL = installedDirectory.appendingPathComponent("manifest.json")
  let manifest = try JSONDecoder().decode(
    ComfyUIUserWorkflowManifest.self, from: Data(contentsOf: manifestURL))

  #expect(workflowID.hasPrefix("user-"))
  #expect(manifest.id == workflowID)
  #expect(manifest.name == "Studio Inpaint")
  #expect(manifest.mode == .inpainting)
  #expect(manifest.bindings.sourceImage == fixture.sourceAddress)
  #expect(manifest.bindings.maskImage == fixture.maskAddress)
  #expect(manifest.outputNodeIDs == [fixture.outputNodeID])
  #expect(manifest.imageAlignment == 16)
  #expect(FileManager.default.fileExists(atPath: installedDirectory.path))

  let reloaded = ComfyUIWorkflowLibrary(directoryURL: fixture.libraryRoot)
  let template = try #require(reloaded.customTemplatesSnapshot().only)
  let definition = try #require(reloaded.definitionSnapshot(for: workflowID))
  let editDraft = try reloaded.editDraft(for: workflowID)

  #expect(template.id == workflowID)
  #expect(template.name == "Studio Inpaint")
  #expect(template.mode == .inpainting)
  #expect(template.isBuiltIn == false)
  #expect(
    definition.directoryURL.resolvingSymlinksInPath()
      == installedDirectory.resolvingSymlinksInPath())
  #expect(editDraft.bindings.sourceImage == fixture.sourceAddress)
  #expect(editDraft.bindings.maskImage == fixture.maskAddress)
  #expect(reloaded.loadFailures.isEmpty)
}

@MainActor
@Test func deferredComfyUIWorkflowLibraryLoadsInstalledPackagesAsynchronously() async throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }
  let workflowID = try fixture.installInpaintingWorkflow()
  let deferred = ComfyUIWorkflowLibrary(
    directoryURL: fixture.libraryRoot, loadImmediately: false)

  #expect(deferred.isLoaded == false)
  #expect(deferred.customTemplatesSnapshot().isEmpty)
  #expect(deferred.definitionSnapshot(for: workflowID) == nil)

  await deferred.reloadAsync()

  let template = try #require(deferred.customTemplatesSnapshot().only)
  #expect(deferred.isLoaded)
  #expect(template.id == workflowID)
  #expect(template.name == "Studio Inpaint")
  #expect(deferred.definitionSnapshot(for: workflowID) != nil)
  #expect(deferred.loadFailures.isEmpty)
}

@MainActor
@Test func asyncWorkflowMutationsPublishImmediatelyWithoutReload() async throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }

  var installDraft = try fixture.inpaintingDraft()
  installDraft.name = "Async Inpaint"
  let initialRevision = fixture.library.revision
  let workflowID = try await fixture.library.installAsync(installDraft)
  let installedDirectory = fixture.libraryRoot.appendingPathComponent(
    workflowID, isDirectory: true)

  #expect(fixture.library.revision != initialRevision)
  #expect(fixture.library.customTemplatesSnapshot().map(\.id) == [workflowID])
  #expect(fixture.library.definitionSnapshot(for: workflowID)?.manifest.name == "Async Inpaint")
  #expect(FileManager.default.fileExists(atPath: installedDirectory.path))

  let installedRevision = fixture.library.revision
  var updateDraft = try await fixture.library.editDraftAsync(for: workflowID)
  updateDraft.name = "Async Inpaint Updated"
  try await fixture.library.updateAsync(updateDraft, id: workflowID)

  #expect(fixture.library.revision != installedRevision)
  #expect(
    fixture.library.customTemplatesSnapshot().only?.name
      == "Async Inpaint Updated")
  #expect(
    fixture.library.definitionSnapshot(for: workflowID)?.manifest.name
      == "Async Inpaint Updated")

  let updatedRevision = fixture.library.revision
  try await fixture.library.removeWorkflowAsync(id: workflowID)

  #expect(fixture.library.revision != updatedRevision)
  #expect(fixture.library.customTemplatesSnapshot().isEmpty)
  #expect(fixture.library.definitionSnapshot(for: workflowID) == nil)
  #expect(!FileManager.default.fileExists(atPath: installedDirectory.path))
}

@MainActor
@Test func overlappingAsyncInstallsPreserveWorkflowCapacityInvariant() async throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }
  for index in 0..<63 {
    try fixture.writeInstalledPackage(
      id: "user-\(UUID().uuidString.lowercased())",
      name: "Existing Workflow \(index)")
  }
  fixture.library.reload()

  var firstDraft = try fixture.inpaintingDraft()
  firstDraft.name = "Concurrent Workflow A"
  var secondDraft = try fixture.inpaintingDraft()
  secondDraft.name = "Concurrent Workflow B"

  let first = Task { @MainActor in
    try await fixture.library.installAsync(firstDraft)
  }
  let second = Task { @MainActor in
    try await fixture.library.installAsync(secondDraft)
  }
  let outcomes = [await first.result, await second.result]
  let installedIDs = outcomes.compactMap { try? $0.get() }
  let failureTitles = outcomes.compactMap { outcome -> String? in
    guard case .failure(let error) = outcome else { return nil }
    return (error as? PixeltjeMacError)?.title
  }

  #expect(installedIDs.count == 1)
  #expect(failureTitles.count == 1)
  #expect(
    failureTitles.allSatisfy {
      ["Workflow library busy", "Workflow library full"].contains($0)
    })
  let templates = fixture.library.customTemplatesSnapshot()
  #expect(templates.count == 64)
  #expect(installedIDs.allSatisfy { id in templates.contains(where: { $0.id == id }) })

  let packageIDs = try FileManager.default.contentsOfDirectory(
    at: fixture.libraryRoot,
    includingPropertiesForKeys: [.isDirectoryKey],
    options: []
  ).map(\.lastPathComponent)
  #expect(Set(packageIDs) == Set(templates.map(\.id)))
}

@MainActor
@Test func comfyUIWorkflowLibraryLoadsAtMostSixtyFourAddedWorkflows() throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }
  for index in 0..<65 {
    try fixture.writeInstalledPackage(
      id: "user-\(UUID().uuidString.lowercased())",
      name: "Workflow \(index)")
  }

  let library = ComfyUIWorkflowLibrary(directoryURL: fixture.libraryRoot)

  #expect(library.isLoaded)
  #expect(library.customTemplatesSnapshot().count == 64)
  #expect(library.loadFailures.contains { $0.message.contains("At most 64") })
}

@MainActor
@Test func customComfyUIWorkflowRequestUsesConfiguredRuntimeNodeIDs() throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }
  let workflowID = try fixture.installInpaintingWorkflow()
  let resolved = try fixture.library.resolvedWorkflow(for: workflowID)

  let request = try ComfyUIWorkflowCatalog.request(
    resolved: resolved,
    parameters: [:],
    prompt: "replace the window with stained glass",
    outputSize: CanvasRecipe(width: 640, height: 480),
    runtimeValues: [
      .sourceImage: "pixeltje/jobs/source.png",
      .maskImage: "pixeltje/jobs/mask.png",
    ])
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let promptInputs = try #require(
    (workflow[fixture.promptAddress.nodeID] as? [String: Any])?["inputs"] as? [String: Any])
  let sourceInputs = try #require(
    (workflow[fixture.sourceAddress.nodeID] as? [String: Any])?["inputs"] as? [String: Any])
  let maskInputs = try #require(
    (workflow[fixture.maskAddress.nodeID] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(resolved.runtimeRoles[.sourceImage] == fixture.sourceAddress)
  #expect(resolved.runtimeRoles[.maskImage] == fixture.maskAddress)
  #expect(resolved.imageAlignment == 16)
  #expect(request.templateID == workflowID)
  #expect(request.mode == .inpainting)
  #expect(request.outputNodeIDs == [fixture.outputNodeID])
  #expect(request.width == 640)
  #expect(request.height == 480)
  #expect(
    promptInputs[fixture.promptAddress.inputName] as? String
      == "replace the window with stained glass")
  #expect(
    sourceInputs[fixture.sourceAddress.inputName] as? String
      == "pixeltje/jobs/source.png")
  #expect(
    maskInputs[fixture.maskAddress.inputName] as? String
      == "pixeltje/jobs/mask.png")
  #expect(!request.parameters.contains { $0.address == fixture.sourceAddress })
  #expect(!request.parameters.contains { $0.address == fixture.maskAddress })
}

@MainActor
@Test func resolvedCustomWorkflowRemainsUsableAfterItsPackageIsRemoved() throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }
  let workflowID = try fixture.installInpaintingWorkflow()
  let resolved = try fixture.library.resolvedWorkflow(for: workflowID)
  let runtimeValues: [ComfyUIWorkflowRuntimeRole: ComfyUIRuntimeValue] = [
    .sourceImage: "pixeltje/frozen-source.png",
    .maskImage: "pixeltje/frozen-mask.png",
  ]
  let beforeRemoval = try ComfyUIWorkflowCatalog.request(
    resolved: resolved,
    parameters: [:],
    prompt: "frozen request",
    runtimeValues: runtimeValues)

  let installedDirectory = fixture.libraryRoot.appendingPathComponent(
    workflowID, isDirectory: true)
  try FileManager.default.removeItem(at: installedDirectory)
  fixture.library.reload()

  #expect(fixture.library.definitionSnapshot(for: workflowID) == nil)
  #expect(throws: PixeltjeMacError.self) {
    try fixture.library.resolvedWorkflow(for: workflowID)
  }

  let afterRemoval = try ComfyUIWorkflowCatalog.request(
    resolved: resolved,
    parameters: [:],
    prompt: "frozen request",
    runtimeValues: runtimeValues)
  #expect(afterRemoval.workflow == beforeRemoval.workflow)
  #expect(afterRemoval.templateRevision == beforeRemoval.templateRevision)
  #expect(afterRemoval.outputNodeIDs == beforeRemoval.outputNodeIDs)
}

@MainActor
@Test func customInpaintWorkflowRejectsMissingUnknownOrOverlappingRuntimeNodeIDs() throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }

  var missingMask = try fixture.inpaintingDraft()
  missingMask.bindings.maskImage = nil
  #expect(throws: PixeltjeMacError.self) {
    try fixture.library.install(missingMask)
  }

  var unknownSource = try fixture.inpaintingDraft()
  unknownSource.bindings.sourceImage = ComfyUIParameterAddress(
    nodeID: "404", inputName: "image")
  #expect(throws: PixeltjeMacError.self) {
    try fixture.library.install(unknownSource)
  }

  var overlappingInputs = try fixture.inpaintingDraft()
  overlappingInputs.bindings.maskImage = fixture.sourceAddress
  #expect(throws: PixeltjeMacError.self) {
    try fixture.library.install(overlappingInputs)
  }

  #expect(fixture.library.customTemplatesSnapshot().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: fixture.libraryRoot.path))
}

@MainActor
@Test func duplicateFrontendSubgraphIDsDoNotCrashCustomWorkflowFormConstruction() throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }
  let workflowID = try fixture.library.install(fixture.duplicateSubgraphDraft())
  let resolved = try fixture.library.resolvedWorkflow(for: workflowID)
  let objectInfo = Data(
    #"""
    {
      "CLIPTextEncode": {
        "input": {
          "required": {
            "text": ["STRING", {"multiline": true}]
          }
        },
        "input_order": {"required": ["text"]}
      }
    }
    """#.utf8)

  let form = try ComfyUIWorkflowCatalog.workflowForm(
    resolved: resolved,
    objectInfoByClass: ["CLIPTextEncode": objectInfo])
  let promptNode = try #require(form.nodes.first { $0.id == "7:1" })
  let prompt = try #require(promptNode.parameters.first)

  #expect(promptNode.title == "First Nested Prompt")
  #expect(prompt.label == "First Prompt Text")
  #expect(prompt.address == ComfyUIParameterAddress(nodeID: "7:1", inputName: "text"))
}

@MainActor
@Test func customWorkflowNormalizesRuntimeBindingsWheneverItsModeIsSaved() throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }

  var generationDraft = try fixture.inpaintingDraft()
  generationDraft.mode = .textToImage
  let workflowID = try fixture.library.install(generationDraft)
  var manifest = try fixture.manifest(for: workflowID)

  #expect(manifest.mode == .textToImage)
  #expect(manifest.bindings.sourceImage == nil)
  #expect(manifest.bindings.maskImage == nil)

  var editDraft = try fixture.library.editDraft(for: workflowID)
  editDraft.mode = .imageToImage
  editDraft.bindings.sourceImage = fixture.sourceAddress
  editDraft.bindings.maskImage = fixture.maskAddress
  try fixture.library.update(editDraft, id: workflowID)
  manifest = try fixture.manifest(for: workflowID)

  #expect(manifest.mode == .imageToImage)
  #expect(manifest.bindings.sourceImage == fixture.sourceAddress)
  #expect(manifest.bindings.maskImage == nil)

  var selectionDraft = try fixture.library.editDraft(for: workflowID)
  selectionDraft.mode = .selection
  selectionDraft.bindings.sourceImage = fixture.sourceAddress
  selectionDraft.bindings.maskImage = fixture.maskAddress
  try fixture.library.update(selectionDraft, id: workflowID)
  manifest = try fixture.manifest(for: workflowID)

  #expect(manifest.mode == .selection)
  #expect(manifest.bindings.sourceImage == fixture.sourceAddress)
  #expect(manifest.bindings.maskImage == nil)
}

@MainActor
@Test func customWorkflowValidatesEveryOptionalBindingTypeFamily() throws {
  let fixture = try ComfyUIWorkflowLibraryFixture()
  defer { fixture.cleanUp() }

  let validDraft = try fixture.semanticBindingsDraft()
  let workflowID = try fixture.library.install(validDraft)
  let manifest = try fixture.manifest(for: workflowID)
  #expect(manifest.bindings.negativePrompt == fixture.semanticAddress("negative"))
  #expect(manifest.bindings.seed == fixture.semanticAddress("seed"))
  #expect(manifest.bindings.steps == fixture.semanticAddress("steps"))
  #expect(manifest.bindings.width == fixture.semanticAddress("width"))
  #expect(manifest.bindings.height == fixture.semanticAddress("height"))
  #expect(manifest.bindings.guidance == fixture.semanticAddress("guidance"))
  #expect(manifest.bindings.strength == fixture.semanticAddress("strength"))

  let invalidCases:
    [(
      WritableKeyPath<ComfyUIWorkflowBindings, ComfyUIParameterAddress?>,
      ComfyUIParameterAddress
    )] = [
      (\.negativePrompt, fixture.semanticAddress("negative_number")),
      (\.seed, fixture.semanticAddress("seed_decimal")),
      (\.steps, fixture.semanticAddress("steps_text")),
      (\.width, fixture.semanticAddress("width_decimal")),
      (\.height, fixture.semanticAddress("height_text")),
      (\.guidance, fixture.semanticAddress("guidance_text")),
      (\.strength, fixture.semanticAddress("strength_text")),
    ]
  for (binding, invalidAddress) in invalidCases {
    var draft = try fixture.semanticBindingsDraft()
    draft.bindings[keyPath: binding] = invalidAddress
    #expect(throws: PixeltjeMacError.self) {
      try fixture.library.install(draft)
    }
  }

  #expect(fixture.library.customTemplatesSnapshot().map(\.id) == [workflowID])
}

@MainActor
private struct ComfyUIWorkflowLibraryFixture {
  let root: URL
  let importRoot: URL
  let libraryRoot: URL
  let frontendURL: URL
  let apiURL: URL
  let library: ComfyUIWorkflowLibrary

  let promptAddress = ComfyUIParameterAddress(nodeID: "10", inputName: "text")
  let sourceAddress = ComfyUIParameterAddress(nodeID: "42", inputName: "image")
  let maskAddress = ComfyUIParameterAddress(nodeID: "84", inputName: "image")
  let outputNodeID = "99"

  init() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ComfyUIWorkflowLibraryTests-\(UUID().uuidString)", isDirectory: true)
    let importRoot = root.appendingPathComponent("Import", isDirectory: true)
    let libraryRoot = root.appendingPathComponent("Installed", isDirectory: true)
    let frontendURL = importRoot.appendingPathComponent("studio-inpaint.json")
    let apiURL = importRoot.appendingPathComponent("studio-inpaint-api.json")
    self.root = root
    self.importRoot = importRoot
    self.libraryRoot = libraryRoot
    self.frontendURL = frontendURL
    self.apiURL = apiURL
    self.library = ComfyUIWorkflowLibrary(directoryURL: libraryRoot)

    try FileManager.default.createDirectory(
      at: importRoot, withIntermediateDirectories: true)
    try Data(Self.frontendJSON.utf8).write(to: frontendURL, options: .atomic)
    try Data(Self.apiJSON.utf8).write(to: apiURL, options: .atomic)
  }

  func inpaintingDraft() throws -> ComfyUIWorkflowImportDraft {
    var draft = try library.prepareImport(from: [frontendURL, apiURL])
    draft.name = "Studio Inpaint"
    draft.mode = .inpainting
    draft.imageAlignment = 16
    draft.bindings.prompt = promptAddress
    draft.bindings.sourceImage = sourceAddress
    draft.bindings.maskImage = maskAddress
    draft.outputNodeID = outputNodeID
    return draft
  }

  func installInpaintingWorkflow() throws -> String {
    try library.install(inpaintingDraft())
  }

  func writeInstalledPackage(id: String, name: String) throws {
    let packageURL = libraryRoot.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(
      at: packageURL, withIntermediateDirectories: true)
    let manifest = ComfyUIUserWorkflowManifest(
      schemaVersion: ComfyUIUserWorkflowManifest.currentSchemaVersion,
      id: id,
      name: name,
      mode: .inpainting,
      frontendFilename: "workflow.json",
      apiFilename: "workflow-api.json",
      bindings: ComfyUIWorkflowBindings(
        prompt: promptAddress,
        sourceImage: sourceAddress,
        maskImage: maskAddress),
      outputNodeIDs: [outputNodeID],
      imageAlignment: 16)
    try JSONEncoder().encode(manifest).write(
      to: packageURL.appendingPathComponent("manifest.json"), options: .atomic)
    try Data(Self.frontendJSON.utf8).write(
      to: packageURL.appendingPathComponent("workflow.json"), options: .atomic)
    try Data(Self.apiJSON.utf8).write(
      to: packageURL.appendingPathComponent("workflow-api.json"), options: .atomic)
  }

  func duplicateSubgraphDraft() throws -> ComfyUIWorkflowImportDraft {
    let frontendURL = importRoot.appendingPathComponent("duplicate-subgraphs.json")
    let apiURL = importRoot.appendingPathComponent("duplicate-subgraphs-api.json")
    try Data(Self.duplicateSubgraphFrontendJSON.utf8).write(
      to: frontendURL, options: .atomic)
    try Data(Self.duplicateSubgraphAPIJSON.utf8).write(to: apiURL, options: .atomic)

    var draft = try library.prepareImport(from: [frontendURL, apiURL])
    draft.name = "Duplicate Subgraph Inpaint"
    draft.mode = .inpainting
    draft.imageAlignment = 16
    draft.bindings.prompt = ComfyUIParameterAddress(nodeID: "7:1", inputName: "text")
    draft.bindings.sourceImage = sourceAddress
    draft.bindings.maskImage = maskAddress
    draft.outputNodeID = outputNodeID
    return draft
  }

  func semanticAddress(_ inputName: String) -> ComfyUIParameterAddress {
    ComfyUIParameterAddress(nodeID: "20", inputName: inputName)
  }

  func semanticBindingsDraft() throws -> ComfyUIWorkflowImportDraft {
    let apiURL = importRoot.appendingPathComponent("semantic-bindings-api.json")
    try Data(Self.semanticBindingsAPIJSON.utf8).write(to: apiURL, options: .atomic)

    var draft = try library.prepareImport(from: [frontendURL, apiURL])
    draft.name = "Semantic Bindings Inpaint"
    draft.mode = .inpainting
    draft.imageAlignment = 16
    draft.bindings.prompt = promptAddress
    draft.bindings.sourceImage = sourceAddress
    draft.bindings.maskImage = maskAddress
    draft.outputNodeID = outputNodeID
    return draft
  }

  func manifest(for workflowID: String) throws -> ComfyUIUserWorkflowManifest {
    let manifestURL =
      libraryRoot
      .appendingPathComponent(workflowID, isDirectory: true)
      .appendingPathComponent("manifest.json", isDirectory: false)
    return try JSONDecoder().decode(
      ComfyUIUserWorkflowManifest.self, from: Data(contentsOf: manifestURL))
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }

  private static let frontendJSON = #"""
    {
      "version": 0.4,
      "nodes": [
        {"id": 10, "type": "CLIPTextEncode", "title": "Positive Prompt"},
        {"id": 42, "type": "LoadImage", "title": "Source Image"},
        {"id": 84, "type": "LoadImage", "title": "Mask Image"},
        {"id": 99, "type": "SaveImage", "title": "Output"}
      ],
      "links": []
    }
    """#

  private static let apiJSON = #"""
    {
      "10": {
        "class_type": "CLIPTextEncode",
        "inputs": {"text": "original prompt"},
        "_meta": {"title": "Positive Prompt"}
      },
      "42": {
        "class_type": "LoadImage",
        "inputs": {"image": "source-placeholder.png"},
        "_meta": {"title": "Source Image"}
      },
      "84": {
        "class_type": "LoadImage",
        "inputs": {"image": "mask-placeholder.png"},
        "_meta": {"title": "Mask Image"}
      },
      "99": {
        "class_type": "SaveImage",
        "inputs": {
          "filename_prefix": "Pixeltje",
          "images": ["85", 0]
        },
        "_meta": {"title": "Output"}
      }
    }
    """#

  private static let duplicateSubgraphFrontendJSON = #"""
    {
      "version": 0.4,
      "nodes": [
        {"id": 7, "type": "shared-subgraph", "title": "Subgraph Host", "order": 0}
      ],
      "links": [],
      "definitions": {
        "subgraphs": [
          {
            "id": "shared-subgraph",
            "nodes": [
              {
                "id": 1,
                "type": "CLIPTextEncode",
                "title": "First Nested Prompt",
                "order": 0,
                "inputs": [
                  {"name": "text", "label": "First Prompt Text"}
                ]
              }
            ]
          },
          {
            "id": "shared-subgraph",
            "nodes": [
              {
                "id": 1,
                "type": "CLIPTextEncode",
                "title": "Duplicate Nested Prompt",
                "order": 0,
                "inputs": [
                  {"name": "text", "label": "Duplicate Prompt Text"}
                ]
              }
            ]
          }
        ]
      }
    }
    """#

  private static let duplicateSubgraphAPIJSON = #"""
    {
      "7:1": {
        "class_type": "CLIPTextEncode",
        "inputs": {"text": "original prompt"},
        "_meta": {"title": "API Prompt"}
      },
      "42": {
        "class_type": "LoadImage",
        "inputs": {"image": "source-placeholder.png"},
        "_meta": {"title": "Source Image"}
      },
      "84": {
        "class_type": "LoadImage",
        "inputs": {"image": "mask-placeholder.png"},
        "_meta": {"title": "Mask Image"}
      },
      "99": {
        "class_type": "SaveImage",
        "inputs": {
          "filename_prefix": "Pixeltje",
          "images": ["42", 0]
        },
        "_meta": {"title": "Output"}
      }
    }
    """#

  private static let semanticBindingsAPIJSON = #"""
    {
      "10": {
        "class_type": "CLIPTextEncode",
        "inputs": {"text": "original prompt"},
        "_meta": {"title": "Positive Prompt"}
      },
      "20": {
        "class_type": "SemanticSettings",
        "inputs": {
          "negative": "avoid blur",
          "seed": 42,
          "steps": 8,
          "width": 512,
          "height": 384,
          "guidance": 2.5,
          "strength": 1,
          "negative_number": 3,
          "seed_decimal": 1.5,
          "steps_text": "eight",
          "width_decimal": 511.5,
          "height_text": "384",
          "guidance_text": "high",
          "strength_text": "full"
        },
        "_meta": {"title": "Semantic Settings"}
      },
      "42": {
        "class_type": "LoadImage",
        "inputs": {"image": "source-placeholder.png"},
        "_meta": {"title": "Source Image"}
      },
      "84": {
        "class_type": "LoadImage",
        "inputs": {"image": "mask-placeholder.png"},
        "_meta": {"title": "Mask Image"}
      },
      "99": {
        "class_type": "SaveImage",
        "inputs": {
          "filename_prefix": "Pixeltje",
          "images": ["42", 0]
        },
        "_meta": {"title": "Output"}
      }
    }
    """#
}

extension Collection {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}

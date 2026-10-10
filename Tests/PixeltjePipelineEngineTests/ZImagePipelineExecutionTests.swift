import Foundation
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import Testing

@Test func missingZImagePackageIsReportedBeforeCoreAILoading() {
  let missing = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let inspection = ZImagePipelineFamily.inspectPackage(at: missing)

  #expect(!inspection.isUsable)
  #expect(!inspection.missingComponents.isEmpty)
  #expect(inspection.mismatchedComponents.isEmpty)
}

@Test func zImageCompatiblePackageIdentityDoesNotRequireAnEngineCodeChange() {
  let missing = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  var document = PipelineDocument(
    id: PipelineID(rawValue: "z-image-package-identity"),
    name: "Z-Image package identity", mode: .textToImage,
    nodes: [ZImageCompositeNode.makeNode(id: PipelineNodeID(rawValue: "generate"))],
    connections: [])
  for nodeIndex in document.nodes.indices {
    for (slot, binding) in document.nodes[nodeIndex].resources {
      guard case .linked(var reference) = binding else { continue }
      reference.packageID = "org.example.compatible-z-image-weights"
      reference.packageVersion = "2026.09"
      document.nodes[nodeIndex].resources[slot] = .linked(reference)
    }
  }

  let inspection = ZImagePipelineFamily.inspectPackage(at: missing, for: document)

  #expect(!inspection.isUsable)
  #expect(!inspection.missingComponents.isEmpty)
  #expect(inspection.mismatchedComponents.isEmpty)
}

@Test func installedZImagePackageMatchesTheExecutableTemplateWhenPresent() {
  let package = ZImagePipelineFamily.defaultPackageURL()
  let resources = package.appendingPathComponent("Resources", isDirectory: true)
  guard FileManager.default.fileExists(atPath: resources.path) else { return }

  let inspection = ZImagePipelineFamily.inspectPackage(at: package)
  #expect(inspection.isUsable, Comment(rawValue: inspection.summary))
}

@Test func installedZImagePackageExecutesOneStepWhenEnabled() async throws {
  guard ProcessInfo.processInfo.environment["PIXELTJE_RUN_COREAI_TESTS"] == "1" else { return }
  let package = ZImagePipelineFamily.defaultPackageURL()
  let inspection = ZImagePipelineFamily.inspectPackage(at: package)
  let usableInspection = try #require(inspection.isUsable ? inspection : nil)
  #expect(usableInspection.isUsable)

  let promptID = PipelineNodeID(rawValue: "prompt")
  let generateID = PipelineNodeID(rawValue: "generate")
  let outputID = PipelineNodeID(rawValue: "output")
  var generation = ZImageCompositeNode.makeNode(id: generateID)
  generation.parameters["steps"] = .integer(1)
  let document = PipelineDocument(
    id: PipelineID(rawValue: "z-image-one-step"), name: "Z-Image one step",
    mode: .textToImage,
    nodes: [
      PipelineNode(id: promptID, kind: .promptInput), generation,
      PipelineNode(id: outputID, kind: .imageOutput),
    ],
    connections: [
      PipelineConnection(
        output: .init(nodeID: promptID, port: "prompt"),
        input: .init(nodeID: generateID, port: "prompt")),
      PipelineConnection(
        output: .init(nodeID: generateID, port: "image"),
        input: .init(nodeID: outputID, port: "image")),
    ],
    primaryOutputNodeIDs: [outputID])
  let engine = try PixeltjePipelineEngine.makeDefault()
  let result = try await engine.execute(
    document,
    packageRootsByID: [ZImagePipelineFamily.packageID: package],
    invocation: PipelineInvocation(values: [
      PipelineInvocation.promptKey: .string(
        "A single red circle centered on a white background"),
      PipelineInvocation.negativePromptKey: .string("text, watermark"),
      PipelineInvocation.seedKey: .unsignedInteger(7),
    ]))
  let output = try #require(result.image)

  #expect(output.width == 512)
  #expect(output.height == 512)
  #expect(output.planarRGB.count == 3 * 512 * 512)
  #expect(output.planarRGB.allSatisfy { $0.isFinite })
  #expect(output.planarRGB.min() != output.planarRGB.max())
  #expect(output.semanticPipelineSHA256.count == 64)
}

@Test func convertedZImageExampleUsesTheSharedNodeScheduler() async throws {
  var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  root.deleteLastPathComponent()
  root.deleteLastPathComponent()
  let url = root.appendingPathComponent(
    "Examples/image_z_image_turbo-coreai.pixpipeline.json")
  let document = try PipelineJSON.decode(Data(contentsOf: url))
  let engine = makeHeadlessZImageTestEngine()
  let report = await engine.validate(document)
  let generation = try #require(document.nodes.first { $0.kind == .zImageGenerate })

  #expect(report.isValid)
  #expect(document.requirements.familyABIs.isEmpty)
  #expect(generation.parameters["width"] == .integer(1024))
  #expect(generation.parameters["height"] == .integer(1024))
  #expect(generation.parameters["steps"] == .integer(8))
  #expect(generation.resources.count == 9)
  #expect(document.nodes.first(where: { $0.kind == .promptInput })?
    .parameters["value"] != nil)
}

@Test func convertedZImageExamplePlansOneComposableBranch() async throws {
  var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  root.deleteLastPathComponent()
  root.deleteLastPathComponent()
  let document = try PipelineJSON.decode(Data(contentsOf: root.appendingPathComponent(
    "Examples/image_z_image_turbo-coreai.pixpipeline.json")))
  let engine = makeHeadlessZImageTestEngine()
  let prepared = try await engine.prepare(document)
  #expect(prepared.orderedNodeIDs.count == 4)
  #expect(prepared.orderedNodeIDs.last?.rawValue == "output")
}

@Test func zImageSimpleScheduleAndSamplersAreDeterministic() throws {
  let schedule = ZImageCoreAIPipeline.sigmaSchedule(
    steps: 8, scheduler: .simple, flowShift: 3)
  #expect(schedule.count == 9)
  #expect(abs(schedule[0] - 1) < 0.000_001)
  #expect(abs(schedule[1] - (2.625 / 2.75)) < 0.000_001)
  #expect(abs(schedule[7] - 0.3) < 0.000_001)
  #expect(schedule[8] == 0)

  let first = ZImageCoreAIPipeline.resMultistepStep(
    latent: [1, 2], denoised: [0, 1], oldDenoised: nil,
    sigma: 1, nextSigma: 0.5, previousSigma: nil, oldSigmaDown: nil)
  #expect(first == [0.5, 1.5])
  let final = ZImageCoreAIPipeline.resMultistepStep(
    latent: first, denoised: [0, 1], oldDenoised: [0, 1],
    sigma: 0.5, nextSigma: 0, previousSigma: 1, oldSigmaDown: 0.5)
  #expect(final == [0, 1])
}

@Test func installedConvertedZImageGraphExecutesOneStepWhenEnabled() async throws {
  guard ProcessInfo.processInfo.environment["PIXELTJE_RUN_COREAI_TESTS"] == "1" else { return }
  var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  root.deleteLastPathComponent()
  root.deleteLastPathComponent()
  var document = try PipelineJSON.decode(Data(contentsOf: root.appendingPathComponent(
    "Examples/image_z_image_turbo-coreai.pixpipeline.json")))
  let package = ZImagePipelineFamily.defaultPackageURL()
  let engine = try PixeltjePipelineEngine.makeDefault()
  let generationIndex = try #require(document.nodes.firstIndex { $0.kind == .zImageGenerate })
  document.nodes[generationIndex].parameters["steps"] = .integer(1)
  let inspection = ZImagePipelineFamily.inspectPackage(at: package, for: document)
  #expect(inspection.isUsable, Comment(rawValue: inspection.summary))

  let output = try await engine.execute(
    document,
    packageRootsByID: [ZImagePipelineFamily.packageID: package],
    invocation: PipelineInvocation(values: [
      PipelineInvocation.stepsKey: .integer(1),
      PipelineInvocation.seedKey: .unsignedInteger(7),
    ]))
  guard case .image(let image) = output else {
    Issue.record("Z-Image graph did not produce an image")
    return
  }
  #expect(image.width == 1024)
  #expect(image.height == 1024)
  #expect(image.planarRGB.count == 3 * 1024 * 1024)
  #expect(image.planarRGB.allSatisfy { $0.isFinite })
}

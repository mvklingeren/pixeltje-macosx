import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import Testing

@testable import PixeltjePipelineTextRuntime

private actor TextProgressRecorder {
  private(set) var updates: [PipelineExecutionProgress] = []

  func append(_ update: PipelineExecutionProgress) {
    updates.append(update)
  }
}

@Test func basicTextExampleMatchesTheInstalledTemplate() throws {
  var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  root.deleteLastPathComponent()
  root.deleteLastPathComponent()
  let example = root.appendingPathComponent(
    "Examples/basic-coreai-text-completion.pixpipeline.json")

  let decoded = try PipelineJSON.decode(Data(contentsOf: example))

  #expect(decoded == CoreAITextPipelineFamily.makeNativeTextCompletionDocument())
}

@Test func basicTextDocumentLinksASelectedBundleAndValidates() throws {
  let fixture = try makeLanguageBundleFixture()
  defer { try? FileManager.default.removeItem(at: fixture) }

  let unlinked = CoreAITextPipelineFamily.makeNativeTextCompletionDocument()
  let linked = try CoreAITextPipelineFamily.linkPackage(in: unlinked, at: fixture)
  let inspection = CoreAITextPipelineFamily.inspectPackage(at: fixture, for: linked)
  var registry = PipelineNodeRegistry.coreAIV1
  registry.register(CoreAITextPipelineFamily.makeCompositeNodeDescriptor())
  let report = PipelineGraphValidator.validate(
    linked,
    registry: registry,
    engineVersion: PixeltjePipelineEngine.currentEngineVersion)

  #expect(inspection.isUsable)
  #expect(report.isValid)
  #expect(linked.requirements.familyABIs.isEmpty)
  let model = try #require(linked.nodes.first {
    $0.kind == CoreAITextPipelineFamily.compositeNodeKind
  })
  #expect(model.resources["model"]?.linkedReference?.packageID == "coreai.qwen-qwen3-0-6b")
  #expect(model.resources["manifest"]?.linkedReference?.kind == .data)
  #expect(model.resources["tokenizer"]?.linkedReference?.kind == .tokenizer)
}

@Test func textGenerationAcceptsAConnectedSeedNode() throws {
  let fixture = try makeLanguageBundleFixture()
  defer { try? FileManager.default.removeItem(at: fixture) }
  var document = try CoreAITextPipelineFamily.linkPackage(
    in: CoreAITextPipelineFamily.makeNativeTextCompletionDocument(), at: fixture)
  let seedID = PipelineNodeID(rawValue: "seed")
  document.nodes.append(PipelineNode(
    id: seedID, kind: .seedInput, title: "Seed",
    parameters: ["mode": .string("random")]))
  document.connections.append(PipelineConnection(
    output: .init(nodeID: seedID, port: "seed"),
    input: .init(nodeID: PipelineNodeID(rawValue: "completion"), port: "seed")))
  var registry = PipelineNodeRegistry.coreAIV1
  registry.register(CoreAITextPipelineFamily.makeCompositeNodeDescriptor())

  let report = PipelineGraphValidator.validate(
    document, registry: registry,
    engineVersion: PixeltjePipelineEngine.currentEngineVersion)

  #expect(report.isValid)
}

@Test func packageInspectionRejectsChangedTokenizer() throws {
  let fixture = try makeLanguageBundleFixture()
  defer { try? FileManager.default.removeItem(at: fixture) }
  let linked = try CoreAITextPipelineFamily.linkPackage(
    in: CoreAITextPipelineFamily.makeNativeTextCompletionDocument(), at: fixture)

  try Data("changed".utf8).write(
    to: fixture.appendingPathComponent("tokenizer/tokenizer.json"), options: .atomic)
  let inspection = CoreAITextPipelineFamily.inspectPackage(at: fixture, for: linked)

  #expect(!inspection.isUsable)
  #expect(inspection.mismatchedComponents.contains("tokenizer"))
}

@Test func packageInspectionRequiresEmbeddedTokenizer() throws {
  let fixture = try makeLanguageBundleFixture(embeddedTokenizer: false)
  defer { try? FileManager.default.removeItem(at: fixture) }

  let inspection = CoreAITextPipelineFamily.inspectPackage(at: fixture)

  #expect(!inspection.isUsable)
  #expect(
    inspection.incompatibleComponents.contains {
      $0.contains("network tokenizer fallback is disabled")
    })
}

@Test func installedTextPackageStreamsWhenEnabled() async throws {
  guard ProcessInfo.processInfo.environment["PIXELTJE_RUN_COREAI_TEXT_TESTS"] == "1" else {
    return
  }
  let package = CoreAITextPipelineFamily.defaultPackageURL()
  let document = try CoreAITextPipelineFamily.linkPackage(
    in: CoreAITextPipelineFamily.makeNativeTextCompletionDocument(), at: package)
  let runner = CoreAITextPipelineRunner()
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeDescriptors: [CoreAITextPipelineFamily.makeCompositeNodeDescriptor()],
    additionalNodeExecutors: [CoreAITextPipelineFamily.makeNodeExecutor(runner: runner)])
  let recorder = TextProgressRecorder()

  let output = try await engine.execute(
    document,
    packageRootsByID: [document.nodes.last!.resources["model"]!.linkedReference!.packageID: package],
    invocation: PipelineInvocation(values: [
      PipelineInvocation.promptKey: .string("Reply with the single word ready."),
      PipelineInvocation.maximumResponseTokensKey: .integer(16),
      PipelineInvocation.temperatureKey: .number(0),
    ])
  ) { update in
    await recorder.append(update)
  }
  let text = try #require(output.text)
  let updates = await recorder.updates

  #expect(!text.text.isEmpty)
  #expect(updates.contains { $0.stage == .generating && $0.generatedText != nil })
  #expect(updates.last?.generatedText == text.text)
}

private func makeLanguageBundleFixture(
  embeddedTokenizer: Bool = true
) throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "PixeltjeTextRuntimeTests-\(UUID().uuidString)", isDirectory: true)
  let model = root.appendingPathComponent("Qwen3-0.6B.aimodel", isDirectory: true)
  let tokenizer = root.appendingPathComponent("tokenizer", isDirectory: true)
  try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
  try Data("model".utf8).write(to: model.appendingPathComponent("main.mlirb"))
  try Data(String(repeating: "a", count: 64).utf8).write(
    to: model.appendingPathComponent("main.hash"))
  try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
  try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer_config.json"))

  let metadata: [String: Any] = [
    "metadata_version": "0.2",
    "kind": "llm",
    "name": "Qwen3-0.6B-test",
    "assets": ["main": "Qwen3-0.6B.aimodel"],
    "language": [
      "tokenizer": "Qwen/Qwen3-0.6B",
      "vocab_size": 151_936,
      "max_context_length": 4096,
      "embedded_tokenizer": embeddedTokenizer,
      "function_map": ["main": ["main"]],
    ],
    "source": [
      "model_definition": "torch",
      "hf_model_id": "Qwen/Qwen3-0.6B",
    ],
  ]
  let metadataData = try JSONSerialization.data(
    withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
  try metadataData.write(to: root.appendingPathComponent("metadata.json"))
  return root
}

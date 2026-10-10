import Foundation
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import Testing

private actor PipelineProgressRecorder {
  private(set) var updates: [PipelineExecutionProgress] = []

  func append(_ update: PipelineExecutionProgress) {
    updates.append(update)
  }
}

private actor ExecutedNodes {
  private(set) var ids: [String] = []

  func append(_ id: String) { ids.append(id) }
}

@Test func outputKindComesFromTheConnectedSinkRatherThanSavedMode() async throws {
  let source = PipelineNodeID(rawValue: "source")
  let sink = PipelineNodeID(rawValue: "sink")
  let document = PipelineDocument(
    id: PipelineID(rawValue: "detected-text"), name: "Detected text",
    mode: .textToImage,
    nodes: [
      PipelineNode(id: source, kind: .promptInput),
      PipelineNode(id: sink, kind: .textOutput),
    ],
    connections: [PipelineConnection(
      output: .init(nodeID: source, port: "prompt"),
      input: .init(nodeID: sink, port: "text"))],
    primaryOutputNodeIDs: [sink])
  let engine = PixeltjePipelineEngine()

  #expect(await engine.executionProfile(for: document)?.outputKind == .text)
}

@Test func connectedControlLoopKeepsEachEnginePassExecutable() async throws {
  func id(_ value: String) -> PipelineNodeID { .init(rawValue: value) }
  let document = PipelineDocument(
    id: .init(rawValue: "control-loop-pass"), name: "Control loop pass", mode: .generic,
    nodes: [
      PipelineNode(id: id("start"), kind: .controlStart),
      PipelineNode(id: id("prompt"), kind: .promptInput,
        parameters: ["value": .string("hello")]),
      PipelineNode(id: id("output"), kind: .textOutput),
      PipelineNode(id: id("loop"), kind: .controlLoop),
    ],
    connections: [PipelineConnection(
      output: .init(nodeID: id("prompt"), port: "prompt"),
      input: .init(nodeID: id("output"), port: "text"))],
    controlConnections: [
      PipelineConnection(
        output: .init(nodeID: id("output"), port: PipelineControlPorts.completed),
        input: .init(nodeID: id("loop"), port: PipelineControlPorts.completed)),
      PipelineConnection(
        output: .init(nodeID: id("loop"), port: PipelineControlPorts.repeatPort),
        input: .init(nodeID: id("start"), port: PipelineControlPorts.again)),
    ],
    primaryOutputNodeIDs: [id("output")])
  let engine = PixeltjePipelineEngine()
  #expect(await engine.validate(document).isValid)
  let prepared = try await engine.prepare(document)
  #expect(prepared.orderedNodeIDs.count == 4)
  let result = try await engine.execute(document, packageRootsByID: [:],
    invocation: PipelineInvocation())
  guard case .plainText(let text) = result else {
    Issue.record("Expected one text result for one engine pass")
    return
  }
  #expect(text.text == "hello")
}

@Test func nativeGraphRunsWithoutAnOutcomeSink() async throws {
  let producerKind = PipelineNodeKind(rawValue: "test.producer")
  let consumerKind = PipelineNodeKind(rawValue: "test.consumer")
  let producerID = PipelineNodeID(rawValue: "producer")
  let consumerID = PipelineNodeID(rawValue: "consumer")
  let sinkID = PipelineNodeID(rawValue: "sink")
  let executed = ExecutedNodes()
  let document = PipelineDocument(
    id: PipelineID(rawValue: "no-outcome"), name: "No outcome", mode: .generic,
    nodes: [
      PipelineNode(id: producerID, kind: producerKind),
      PipelineNode(id: consumerID, kind: consumerKind),
      PipelineNode(id: sinkID, kind: .textOutput),
    ],
    connections: [PipelineConnection(
      output: .init(nodeID: producerID, port: "text"),
      input: .init(nodeID: consumerID, port: "text"))],
    primaryOutputNodeIDs: [sinkID])
  let engine = PixeltjePipelineEngine(
    additionalNodeDescriptors: [
      PipelineNodeDescriptor(
        kind: producerKind, displayName: "Producer", category: "Test",
        outputs: [.init(name: "text", type: .string)]),
      PipelineNodeDescriptor(
        kind: consumerKind, displayName: "Consumer", category: "Test",
        inputs: [.init(name: "text", type: .string)]),
    ],
    additionalNodeExecutors: [
      PipelineNodeExecutor(kind: producerKind) { node, _, _ in
        await executed.append(node.id.rawValue)
        return PipelineNodeResult(outputs: [
          "text": PipelineNodeValue("hello", type: .string)
        ])
      },
      PipelineNodeExecutor(kind: consumerKind) { node, inputs, _ in
        #expect(inputs["text"]?.value(as: String.self) == "hello")
        await executed.append(node.id.rawValue)
        return PipelineNodeResult()
      },
    ])

  #expect(await engine.validate(document).isValid)
  #expect(await engine.executionProfile(for: document)?.outputKind == PipelineExecutionOutputKind.none)
  let result = try await engine.execute(
    document, packageRootsByID: [:], invocation: PipelineInvocation())
  #expect(result == .none)
  #expect(await executed.ids == ["producer", "consumer"])
}

func makeHeadlessZImageTestEngine() -> PixeltjePipelineEngine {
  PixeltjePipelineEngine(additionalNodeExecutors: [
    PipelineNodeExecutor(kind: .zImageGenerate,
      validate: ZImageCompositeNode.diagnostics) { _, _, _ in
        throw PipelineEngineError.metalCommandQueueUnavailable
      }
  ])
}

@Test func engineRejectsWorkflowFamilyABIs() async throws {
  let document = PipelineDocument(
    id: PipelineID(rawValue: "obsolete-family-abi"),
    name: "Obsolete family ABI", mode: .textToImage,
    requirements: PipelineRequirements(
      minimumEngineVersion: PixeltjePipelineEngine.currentEngineVersion,
      familyABIs: ["z-image-coreai-graph@2"]),
    nodes: [PipelineNode(id: PipelineNodeID(rawValue: "prompt"), kind: .promptInput)],
    connections: [])
  let engine = PixeltjePipelineEngine()
  #expect(await engine.executionProfile(for: document) == nil)
  let report = await engine.validate(document)
  #expect(report.diagnostics.contains {
    $0.code == .unsupportedNodeImplementation
      && $0.message.contains("Workflow-family ABIs")
  })
  await #expect(throws: PipelineEngineError.self) {
    try await engine.execute(
      document, packageRootsByID: [:], invocation: PipelineInvocation())
  }
}

@Test func nativeNodeExecutorsComposeWithoutAFamilyAdapter() async throws {
  let decorate = PipelineNodeKind(rawValue: "test.decorate")
  let descriptor = PipelineNodeDescriptor(
    kind: decorate, displayName: "Decorate", category: "Tests",
    inputs: [.init(name: "text", type: .string)],
    outputs: [.init(name: "text", type: .string)])
  let operation = PipelineNodeExecutor(kind: decorate) { _, inputs, _ in
    guard let text = inputs["text"]?.value(as: String.self) else {
      throw PipelineEngineError.invalidInvocation("Missing text.")
    }
    return PipelineNodeResult(outputs: [
      "text": PipelineNodeValue("[\(text)]", type: .string)
    ])
  }
  func id(_ value: String) -> PipelineNodeID { PipelineNodeID(rawValue: value) }
  func link(_ source: String, _ destination: String) -> PipelineConnection {
    PipelineConnection(
      output: .init(nodeID: id(source), port: source == "prompt" ? "prompt" : "text"),
      input: .init(nodeID: id(destination), port: "text"))
  }
  let document = PipelineDocument(
    id: PipelineID(rawValue: "native-composition"), name: "Native composition",
    mode: .generic,
    nodes: [
      PipelineNode(id: id("prompt"), kind: .promptInput),
      PipelineNode(id: id("first"), kind: decorate),
      PipelineNode(id: id("second"), kind: decorate),
      PipelineNode(id: id("output"), kind: .textOutput),
    ],
    connections: [
      link("prompt", "first"), link("first", "second"),
      link("second", "output"),
    ],
    primaryOutputNodeIDs: [id("output")])
  let engine = PixeltjePipelineEngine(
        additionalNodeDescriptors: [descriptor],
    additionalNodeExecutors: [operation])
  let output = try await engine.execute(
    document, packageRootsByID: [:],
    invocation: PipelineInvocation(values: [
      PipelineInvocation.promptKey: .string("hello")
    ]))
  guard case .plainText(let text) = output else {
    Issue.record("Expected plain text output.")
    return
  }
  #expect(text.text == "[[hello]]")
  #expect(text.semanticPipelineSHA256.count == 64)

  let missing = PixeltjePipelineEngine(
    additionalNodeDescriptors: [descriptor])
  let report = await missing.validate(document)
  #expect(report.diagnostics.contains {
    $0.code == .unsupportedNodeImplementation && $0.nodeID == id("first")
  })
  #expect(report.diagnostics.contains {
    $0.code == .unsupportedNodeImplementation && $0.nodeID == id("second")
  })
}

@Test func zImageCompositeNodePlansWithoutAFamilyAdapter() async throws {
  let promptID = PipelineNodeID(rawValue: "prompt")
  let generationID = PipelineNodeID(rawValue: "generate")
  let outputID = PipelineNodeID(rawValue: "output")
  let document = PipelineDocument(
    id: PipelineID(rawValue: "native-z-image"),
    name: "Native Z-Image", mode: .textToImage,
    nodes: [
      PipelineNode(id: promptID, kind: .promptInput),
      ZImageCompositeNode.makeNode(id: generationID),
      PipelineNode(id: outputID, kind: .imageOutput),
    ],
    connections: [
      PipelineConnection(
        output: .init(nodeID: promptID, port: "prompt"),
        input: .init(nodeID: generationID, port: "prompt")),
      PipelineConnection(
        output: .init(nodeID: generationID, port: "image"),
        input: .init(nodeID: outputID, port: "image")),
    ],
    primaryOutputNodeIDs: [outputID])
  let engine = makeHeadlessZImageTestEngine()
  let report = await engine.validate(document)
  #expect(report.isValid)
  let prepared = try await engine.prepare(document)
  #expect(prepared.requiredResources.count == 9)
  var invalid = document
  invalid.nodes[1].parameters["steps"] = .integer(0)
  let invalidReport = await engine.validate(invalid)
  #expect(invalidReport.diagnostics.contains {
    $0.code == .invalidParameter && $0.nodeID == generationID
  })
  await #expect(throws: PipelineEngineError.self) {
    try await engine.execute(
      document,
      packageRootsByID: [
        ZImagePipelineFamily.packageID: URL(
          fileURLWithPath: "/private/tmp/pixeltje-missing-native-z-image", isDirectory: true)
      ],
      invocation: PipelineInvocation(values: [PipelineInvocation.promptKey: .string("sunrise")]))
  }
}

@Test func invocationValuesOverrideAdapterDefaults() async throws {
  let invocation = PipelineInvocation(values: [
    PipelineInvocation.stepsKey: .integer(12),
    PipelineInvocation.seedKey: .unsignedInteger(UInt64.max),
  ]).mergingDefaults([
    PipelineInvocation.stepsKey: .integer(4),
    PipelineInvocation.guidanceKey: .number(1),
  ])

  #expect(try invocation.integer(for: PipelineInvocation.stepsKey) == 12)
  #expect(try invocation.number(for: PipelineInvocation.guidanceKey) == 1)
  #expect(try invocation.unsignedInteger(for: PipelineInvocation.seedKey) == UInt64.max)
}

@Test func engineCarriesStreamingTextProgressAndTextOutput() async throws {
  let kind = PipelineNodeKind(rawValue: "test.streamingText")
  let descriptor = PipelineNodeDescriptor(
    kind: kind, displayName: "Streaming Text", category: "Tests",
    isTerminal: true)
  let executor = PipelineNodeExecutor(kind: kind) { _, _, context in
    await context.progress(.init(
      stage: .generating, message: "Generating…",
      completedUnitCount: 1, totalUnitCount: 2,
      generatedText: "Hello", textDelta: "Hello", outputTokenCount: 1))
    await context.progress(.init(
      stage: .generating, message: "Generating…",
      completedUnitCount: 2, totalUnitCount: 2,
      generatedText: "Hello world", textDelta: " world", outputTokenCount: 2))
    return PipelineNodeResult(terminalOutput: .text(PipelineGeneratedText(
      text: "Hello world", semanticPipelineSHA256: context.semanticSHA256,
      modelPackageID: "test.model", modelPackageVersion: "sha256.test",
      finishReason: .completed, inputTokenCount: 1, outputTokenCount: 2)))
  }
  let nodeID = PipelineNodeID(rawValue: "stream")
  let document = PipelineDocument(
    id: PipelineID(rawValue: "stream-test"), name: "Streaming text",
    mode: .generic, nodes: [PipelineNode(id: nodeID, kind: kind)],
    connections: [], primaryOutputNodeIDs: [nodeID])
  let engine = PixeltjePipelineEngine(
    additionalNodeDescriptors: [descriptor], additionalNodeExecutors: [executor])
  let recorder = PipelineProgressRecorder()
  let output = try await engine.execute(
    document, packageRootsByID: [:], invocation: PipelineInvocation()
  ) { update in
    await recorder.append(update)
  }
  let updates = await recorder.updates
  #expect(output.text?.text == "Hello world")
  #expect(output.text?.outputTokenCount == 2)
  #expect(updates.filter { $0.stage == .generating }.compactMap(\.generatedText)
    == ["Hello", "Hello world"])
  #expect(updates.filter { $0.stage == .generating }.compactMap(\.textDelta)
    == ["Hello", " world"])
}

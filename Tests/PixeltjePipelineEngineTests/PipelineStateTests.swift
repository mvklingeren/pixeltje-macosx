import Foundation
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import PixeltjePipelineSDXSRuntime
import PixeltjePipelineSegmentationRuntime
import PixeltjePipelineTextRuntime
import Testing

private func beeWorkflow() throws -> PipelineDocument {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return try PipelineJSON.decode(Data(contentsOf: root.appendingPathComponent(
    "Examples/bee-nectar-quest-sdxs-coreai.pixpipeline.json")))
}

private func beeTestEngine(
  failRender: Bool = false,
  expectedSubjects: [String] = ["red poppy flower", "yellow sunflower", "purple lavender flower"],
  expectedScene: String = "sunny nectar meadow",
  expectedBee: String = "one fluffy golden yellow bee with black stripes and translucent wings",
  directorPrompt: String = "Storybook illustration, sunny meadow, warm sunlight, flowers in a wide landscape."
) -> PixeltjePipelineEngine {
  PixeltjePipelineEngine(additionalNodeDescriptors: [
    SDXSPipelineFamily.descriptor(), SAM31PipelineFamily.descriptor(),
    CoreAITextPipelineFamily.makeCompositeNodeDescriptor(),
  ], additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors() + [
    PipelineNodeExecutor(kind: CoreAITextPipelineFamily.makeCompositeNodeDescriptor().kind) { _, inputs, _ in
      let prompt = try #require(inputs["prompt"]?.value(as: String.self))
      #expect(prompt.contains("\"score\":"))
      #expect(prompt.contains(expectedScene))
      return PipelineNodeResult(outputs: ["text": PipelineNodeValue(directorPrompt, type: .string)])
    },
    PipelineNodeExecutor(kind: SDXSPipelineFamily.nodeKind) { _, inputs, context in
      let prompt = try #require(inputs["prompt"]?.value(as: String.self))
      #expect(prompt.hasPrefix(expectedBee + " "))
      #expect(prompt.hasSuffix(", " + directorPrompt))
      if failRender { throw CancellationError() }
      let image = PipelineGeneratedImage(width: 4, height: 4,
        planarRGB: [Float](repeating: 0.5, count: 48), encoding: .sRGBZeroToOne,
        semanticPipelineSHA256: context.semanticSHA256)
      return PipelineNodeResult(outputs: ["image": PipelineNodeValue(image, type: .image)])
    },
    PipelineNodeExecutor(kind: SAM31PipelineFamily.nodeKind) { _, inputs, _ in
      let subjects = try #require(inputs["subjects"]?.value(as: [String].self))
      #expect(subjects == expectedSubjects)
      var poppy = [Float](repeating: 0, count: 16)
      var sunflower = poppy
      poppy[0] = 1; sunflower[15] = 1
      let masks = try [
        PipelineLabeledMask(label: subjects[0], mask: .init(width: 4, height: 4, coverage: poppy), score: 0.9),
        PipelineLabeledMask(label: subjects[1], mask: .init(width: 4, height: 4, coverage: sunflower), score: 0.9),
      ]
      return PipelineNodeResult(outputs: ["masks": PipelineNodeValue(masks, type: .labeledMasks)])
    },
  ])
}

@Test func beeWorkflowScoresOnlyFlowerActionsAndCarriesStateBetweenTurns() async throws {
  var document = try beeWorkflow()
  let hitIndex = try #require(document.nodes.firstIndex { $0.kind == .maskHitTest })
  document.nodes[hitIndex].parameters["radiusPixels"] = .integer(0)
  let engine = beeTestEngine()
  #expect(await engine.validate(document).isValid)
  let hash = try PipelineJSON.semanticSHA256(document)
  // Model executors are stubs; these roots satisfy linking without loading packages.
  let roots = Dictionary(uniqueKeysWithValues: Set(document.nodes.flatMap {
    $0.resources.values.compactMap(\.linkedReference).map(\.packageID)
  }).map { ($0, FileManager.default.temporaryDirectory) })
  var output = try #require(try await engine.execute(document, packageRootsByID: roots, invocation: .init()).image)
  #expect(output.interactionMasks.count == 2)
  var state = try #require(output.nextStateJSON)
  #expect(try PipelineStateJSON.read(state, key: "score") == .integer(0))
  #expect(try PipelineStateJSON.read(state, key: "turn") == .integer(0))
  for (index, action) in [(0.1, 0.1, 1, "poppy_1"), (0.5, 0.5, 1, "poppy_1"),
    (0.9, 0.9, 2, "sunflower_1"), (0.9, 0.9, 3, "sunflower_1")].enumerated() {
    let frame = try PipelineImageInput(width: 4, height: 4, rgba: [Float](repeating: 1, count: 64))
    output = try #require(try await engine.execute(document, packageRootsByID: roots, invocation: .init(values: [
      PipelineInvocation.stateKey: .string(state),
      PipelineInvocation.sourceImageKey: .image(frame),
      PipelineInvocation.interactionMasksKey: .labeledMasks(output.interactionMasks),
      PipelineInvocation.trackpadXKey: .number(action.0),
      PipelineInvocation.trackpadYKey: .number(action.1),
      PipelineInvocation.loopCallIndexKey: .integer(Int64(index + 1)),
    ])).image)
    state = try #require(output.nextStateJSON)
    #expect(try PipelineStateJSON.read(state, key: "score") == .integer(Int64(action.2)))
    #expect(try PipelineStateJSON.read(state, key: "turn") == .integer(Int64(index + 1)))
    #expect(try PipelineStateJSON.read(state, key: "lastFlower") == .string(action.3))
    let label = action.3 == "poppy_1" ? "red poppy flower" : "yellow sunflower"
    let beeAction = "collecting nectar from " + label
    #expect(try PipelineStateJSON.read(state, key: "/bee/action") == .string(beeAction))
    #expect(output.feedbackText?.hasPrefix(
      "one fluffy golden yellow bee with black stripes and translucent wings " + beeAction) == true)
  }
  #expect(try PipelineJSON.semanticSHA256(document) == hash)
  // Restoring a checkpoint recreates the view without consuming a click.
  let restored = try await engine.execute(document, packageRootsByID: roots, invocation: .init(values: [
    PipelineInvocation.stateKey: .string(state)
  ]))
  #expect(restored.image?.nextStateJSON == state)
  await #expect(throws: CancellationError.self) {
    try await beeTestEngine(failRender: true).execute(document, packageRootsByID: roots, invocation: .init(values: [
      PipelineInvocation.stateKey: .string(state)
    ]))
  }
  #expect(try PipelineStateJSON.read(state, key: "score") == .integer(3))
}

@Test func beeWorkflowRendersAndScoresAnAlternateSceneDefinedOnlyInState() async throws {
  var document = try beeWorkflow()
  let stateIndex = try #require(document.nodes.firstIndex { $0.kind == .stateInput })
  document.nodes[stateIndex].parameters["initialState"] = .string(#"""
    {"version":3,"turn":0,"score":0,"location":"moonlit rooftop garden",
      "visualStyle":"watercolor","lighting":"silver moonlight","lastFlower":"",
      "bee":{"id":"bee_1","description":"a pale blue bee with silver wings","action":"hovering over rooftop flowers"},
      "entities":{"daisy_7":{"label":"white daisy","nectar":true},
        "orchid_9":{"label":"pink orchid","nectar":true}},
      "subjects":["white daisy","pink orchid"],
      "entityIDsByLabel":{"label:":"","label:white daisy":"daisy_7","label:pink orchid":"orchid_9"}}
    """#)
  let hitIndex = try #require(document.nodes.firstIndex { $0.kind == .maskHitTest })
  document.nodes[hitIndex].parameters["radiusPixels"] = .integer(0)
  let prompt = "Watercolor moonlit rooftop garden with white daisies and pink orchids."
  let engine = beeTestEngine(expectedSubjects: ["white daisy", "pink orchid"],
    expectedScene: "moonlit rooftop garden", expectedBee: "a pale blue bee with silver wings",
    directorPrompt: prompt)
  #expect(await engine.validate(document).isValid)
  let roots = Dictionary(uniqueKeysWithValues: Set(document.nodes.flatMap {
    $0.resources.values.compactMap(\.linkedReference).map(\.packageID)
  }).map { ($0, FileManager.default.temporaryDirectory) })
  let opening = try #require(try await engine.execute(document,
    packageRootsByID: roots, invocation: .init()).image)
  #expect(opening.feedbackText == "a pale blue bee with silver wings hovering over rooftop flowers, " + prompt)
  let openingState = try #require(opening.nextStateJSON)
  let frame = try PipelineImageInput(width: 4, height: 4, rgba: [Float](repeating: 1, count: 64))
  let clicked = try #require(try await engine.execute(document,
    packageRootsByID: roots, invocation: .init(values: [
      PipelineInvocation.stateKey: .string(openingState),
      PipelineInvocation.sourceImageKey: .image(frame),
      PipelineInvocation.interactionMasksKey: .labeledMasks(opening.interactionMasks),
      PipelineInvocation.trackpadXKey: .number(0.1),
      PipelineInvocation.trackpadYKey: .number(0.1),
      PipelineInvocation.loopCallIndexKey: .integer(1),
    ])).image)
  let state = try #require(clicked.nextStateJSON)
  #expect(try PipelineStateJSON.read(state, key: "score") == .integer(1))
  #expect(try PipelineStateJSON.read(state, key: "lastFlower") == .string("daisy_7"))
  #expect(try PipelineStateJSON.read(state, key: "location") == .string("moonlit rooftop garden"))
  #expect(clicked.feedbackText == "a pale blue bee with silver wings collecting nectar from white daisy, " + prompt)
}

@Test func generatedImageConversionPreservesRowsEncodingAndPremultipliedAlpha() throws {
  let generated = PipelineGeneratedImage(width: 1, height: 2,
    planarRGB: [-1, 1, 0, -1, 1, 0], encoding: .sRGBMinusOneToOne,
    semanticPipelineSHA256: "conversion", alpha: [1, 0.5])
  let input = try PipelineImageInput(generatedImage: generated)
  #expect(input.width == 1 && input.height == 2)
  #expect(input.rgba == [0, 0.5, 1, 1, 0.5, 0, 0.25, 0.5])
  var invalid = generated
  invalid.alpha = [1]
  #expect(throws: (any Error).self) { try PipelineImageInput(generatedImage: invalid) }
  invalid = generated
  invalid.planarRGB[0] = .nan
  #expect(throws: (any Error).self) { try PipelineImageInput(generatedImage: invalid) }
}

@Test func realSAMExecutorAcceptsGeneratedImageInsteadOfSilentlyReturningNoMasks() async throws {
  let document = try beeWorkflow()
  let node = try #require(document.nodes.first { $0.kind == SAM31PipelineFamily.nodeKind })
  let image = PipelineGeneratedImage(width: 1, height: 1, planarRGB: [0.1, 0.2, 0.3],
    encoding: .sRGBZeroToOne, semanticPipelineSHA256: "sam-input")
  let context = PipelineNodeExecutionContext(semanticSHA256: "sam-input", invocation: .init(),
    sourceMediaRoot: nil, packageRootsByID: [:], nodeIndex: 0, nodeCount: 1, progress: { _ in })
  let executor = SAM31PipelineFamily.executor(runner: SAM31PipelineRunner())
  // No linked package: accepting either raster must reach resource resolution
  // and fail before model loading. The old guard silently returned zero masks.
  for value in [PipelineNodeValue(image, type: .image),
    PipelineNodeValue(try PipelineImageInput(generatedImage: image), type: .image)] {
    do {
      _ = try await executor.execute(node, inputs: ["image": value,
        "subjects": PipelineNodeValue(["flower"], type: .stringList)], context: context)
      Issue.record("SAM silently ignored a supplied image instead of resolving its model.")
    } catch PipelineEngineError.modelPackageUnavailable(let message) {
      #expect(message.contains(SAM31PipelineFamily.packageID))
    }
  }
}

@Test func stateInputRejectsMalformedDefaultsAndInvocation() async throws {
  let id = PipelineNodeID(rawValue: "state")
  var document = PipelineDocument(id: .init(rawValue: "json-state"), name: "JSON state", mode: .generic,
    nodes: [PipelineNode(id: id, kind: .stateInput, parameters: ["initialState": .string("[]")]),
      PipelineNode(id: .init(rawValue: "out"), kind: .textOutput)],
    connections: [.init(output: .init(nodeID: id, port: "state"),
      input: .init(nodeID: .init(rawValue: "out"), port: "text"))])
  let engine = PixeltjePipelineEngine()
  #expect(await engine.validate(document).isValid == false)
  document.nodes[0].parameters["initialState"] = .string(#"{"score":0}"#)
  #expect(await engine.validate(document).isValid)
  await #expect(throws: (any Error).self) {
    try await engine.execute(document, packageRootsByID: [:], invocation: .init(values: [
      PipelineInvocation.stateKey: .string("not json")
    ]))
  }
}

@Test func frameFeedbackRejectsMasksFromAnotherImage() throws {
  var image = PipelineGeneratedImage(width: 4, height: 4, planarRGB: [Float](repeating: 0, count: 48),
    encoding: .sRGBZeroToOne, semanticPipelineSHA256: "test")
  let mask = try PipelineLabeledMask(label: "flower", mask: .init(width: 1, height: 1, coverage: [1]), score: 1)
  #expect(throws: (any Error).self) { try image.setInteractionMasks([mask]) }
}

import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import PixeltjePipelineSegmentationRuntime
import Testing

@Test func subjectClickGraphUsesPreviousFrameAndTrackpad() async throws {
  func id(_ value: String) -> PipelineNodeID { .init(rawValue: value) }
  func link(_ source: String, _ output: String, _ target: String, _ input: String)
    -> PipelineConnection {
    .init(output: .init(nodeID: id(source), port: output),
      input: .init(nodeID: id(target), port: input))
  }
  let segmentKind = PipelineNodeKind(rawValue: "test.labeledSegments")
  let document = PipelineDocument(
    id: .init(rawValue: "subject-click"), name: "Subject click", mode: .generic,
    nodes: [
      PipelineNode(id: id("prompt"), kind: .promptInput,
        parameters: ["value": .string("opening brief")]),
      PipelineNode(id: id("frame"), kind: .previousFrameInput),
      PipelineNode(id: id("trackpad"), kind: .trackpad),
      PipelineNode(id: id("split"), kind: .textSplit),
      PipelineNode(id: id("segments"), kind: segmentKind),
      PipelineNode(id: id("hit"), kind: .maskHitTest,
        parameters: ["radiusPixels": .integer(0)]),
      PipelineNode(id: id("output"), kind: .textOutput),
    ],
    connections: [
      link("prompt", "prompt", "split", "text"),
      link("split", "items", "segments", "subjects"),
      link("frame", "image", "segments", "image"),
      link("segments", "masks", "hit", "masks"),
      link("trackpad", "x", "hit", "x"),
      link("trackpad", "y", "hit", "y"),
      link("hit", "label", "output", "text"),
    ], primaryOutputNodeIDs: [id("output")])
  let engine = PixeltjePipelineEngine(
    additionalNodeDescriptors: [
      .init(kind: segmentKind, displayName: "Test segments", category: "Test",
        inputs: [
          .init(name: "subjects", type: .stringList),
          .init(name: "image", type: .image, isRequired: false),
        ], outputs: [.init(name: "masks", type: .labeledMasks)]),
    ], additionalNodeExecutors: [
      PipelineNodeExecutor(kind: segmentKind) { _, inputs, _ in
        guard let image = inputs["image"]?.value(as: PipelineImageInput.self),
          let subjects = inputs["subjects"]?.value(as: [String].self) else {
          return PipelineNodeResult(outputs: [
            "masks": PipelineNodeValue([PipelineLabeledMask](), type: .labeledMasks)
          ])
        }
        var results: [PipelineLabeledMask] = []
        for subject in subjects {
          var coverage = [Float](repeating: 0, count: image.width * image.height)
          if subject == "gate" { coverage[0] = 1 }
          if subject == "bridge" { coverage[7] = 1 }
          results.append(try PipelineLabeledMask(label: subject,
            mask: PipelineMaskInput(width: image.width, height: image.height,
              coverage: coverage), score: 0.9))
        }
        return PipelineNodeResult(outputs: [
          "masks": PipelineNodeValue(results, type: .labeledMasks)
        ])
      },
    ])
  #expect(await engine.validate(document).isValid)
  let first = try await engine.execute(
    document, packageRootsByID: [:], invocation: .init())
  guard case .plainText(let initial) = first else {
    Issue.record("Expected initial text output")
    return
  }
  #expect(initial.text.isEmpty)

  let frame = try PipelineImageInput(
    width: 4, height: 4, rgba: [Float](repeating: 1, count: 4 * 4 * 4))
  let second = try await engine.execute(document, packageRootsByID: [:],
    invocation: .init(values: [
    PipelineInvocation.promptKey: .string("gate | bridge"),
    PipelineInvocation.sourceImageKey: .image(frame),
    PipelineInvocation.trackpadXKey: .number(0.875),
    PipelineInvocation.trackpadYKey: .number(0.375),
  ]))
  guard case .plainText(let clicked) = second else {
    Issue.record("Expected clicked text output")
    return
  }
  #expect(clicked.text == "bridge")
}

@Test func maskHitTestUsesHighestScoreAndRejectsEmptyPixels() throws {
  func segment(_ label: String, score: Float, covered: Int) throws -> PipelineLabeledMask {
    var coverage = [Float](repeating: 0, count: 9)
    coverage[covered] = 1
    return try PipelineLabeledMask(label: label,
      mask: PipelineMaskInput(width: 3, height: 3, coverage: coverage), score: score)
  }
  let lower = try segment("archway", score: 0.6, covered: 4)
  let higher = try segment("gate", score: 0.9, covered: 4)
  #expect(try PipelineMaskHitTest.pick(
    masks: [lower, higher], x: 0.5, y: 0.5, threshold: 0.5, radius: 0)?.label == "gate")
  #expect(try PipelineMaskHitTest.pick(
    masks: [lower, higher], x: 0, y: 0, threshold: 0.5, radius: 0) == nil)
}

@Test func imageOutputCarriesPreviousViewText() async throws {
  let promptID = PipelineNodeID(rawValue: "prompt")
  let imageID = PipelineNodeID(rawValue: "image")
  let previewID = PipelineNodeID(rawValue: "preview")
  let outputID = PipelineNodeID(rawValue: "output")
  let imageKind = PipelineNodeKind(rawValue: "test.constantImage")
  let document = PipelineDocument(
    id: .init(rawValue: "image-text-feedback"), name: "Image text feedback", mode: .generic,
    nodes: [
      PipelineNode(id: promptID, kind: .promptInput,
        parameters: ["value": .string("A bridge in mist.\n@@ bridge | gate")]),
      PipelineNode(id: imageID, kind: imageKind),
      PipelineNode(id: previewID, kind: .imagePreview),
      PipelineNode(id: outputID, kind: .imageOutput),
    ], connections: [
      .init(output: .init(nodeID: promptID, port: "prompt"),
        input: .init(nodeID: outputID, port: "feedbackText")),
      .init(output: .init(nodeID: imageID, port: "image"),
        input: .init(nodeID: previewID, port: "image")),
      .init(output: .init(nodeID: previewID, port: "image"),
        input: .init(nodeID: outputID, port: "image")),
    ], primaryOutputNodeIDs: [outputID])
  let engine = PixeltjePipelineEngine(
    additionalNodeDescriptors: [
      .init(kind: imageKind, displayName: "Constant image", category: "Test",
        outputs: [.init(name: "image", type: .image)]),
    ], additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors() + [
      PipelineNodeExecutor(kind: imageKind) { _, _, context in
        let image = PipelineGeneratedImage(width: 1, height: 1,
          planarRGB: [0, 0, 0], encoding: .sRGBZeroToOne,
          semanticPipelineSHA256: context.semanticSHA256)
        return PipelineNodeResult(outputs: [
          "image": PipelineNodeValue(image, type: .image)
        ])
      },
    ])
  #expect(await engine.validate(document).isValid)
  let result = try await engine.execute(
    document, packageRootsByID: [:], invocation: .init())
  #expect(result.image?.feedbackText == "A bridge in mist.\n@@ bridge | gate")
}

@Test func sam31HasNoMaskBeforeTheFirstRenderedFrame() async throws {
  let executor = SAM31PipelineFamily.executor(runner: SAM31PipelineRunner())
  let node = PipelineNode(id: .init(rawValue: "sam"), kind: SAM31PipelineFamily.nodeKind)
  let context = PipelineNodeExecutionContext(
    semanticSHA256: "", invocation: .init(), sourceMediaRoot: nil,
    packageRootsByID: [:], nodeIndex: 0, nodeCount: 1,
    progress: { _ in })
  let result = try await executor.execute(node, inputs: [
    "subjects": PipelineNodeValue(["gate"], type: .stringList)
  ], context: context)
  #expect(result.outputs["masks"]?.value(as: [PipelineLabeledMask].self)?.isEmpty == true)
}

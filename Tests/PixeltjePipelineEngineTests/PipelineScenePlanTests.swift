import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import Testing

@Test func scenePlanFeedbackUsesTrackpadToChooseTheNextTextBrief() async throws {
  func id(_ value: String) -> PipelineNodeID { .init(rawValue: value) }
  func link(_ source: String, _ output: String, _ target: String, _ input: String)
    -> PipelineConnection
  {
    .init(output: .init(nodeID: id(source), port: output),
      input: .init(nodeID: id(target), port: input))
  }

  let writerKind = PipelineNodeKind(rawValue: "test.sceneWriter")
  let imageKind = PipelineNodeKind(rawValue: "test.sceneImage")
  let document = PipelineDocument(
    id: .init(rawValue: "plan-a-feedback"), name: "Plan-A feedback", mode: .generic,
    nodes: [
      PipelineNode(id: id("brief"), kind: .promptInput,
        parameters: ["value": .string("An open fantasy road")]),
      PipelineNode(id: id("previous"), kind: .previousScenePlanInput),
      PipelineNode(id: id("previousFrame"), kind: .previousFrameInput),
      PipelineNode(id: id("trackpad"), kind: .trackpad,
        parameters: ["x": .number(0.5), "y": .number(0.5)]),
      PipelineNode(id: id("navigate"), kind: .sceneNavigate),
      PipelineNode(id: id("writer"), kind: writerKind),
      PipelineNode(id: id("parse"), kind: .scenePlanParse),
      PipelineNode(id: id("style"), kind: .primitiveString,
        parameters: ["value": .string("Persistent blue-cloaked mouse")]),
      PipelineNode(id: id("finalPrompt"), kind: .textConcatenate,
        parameters: ["delimiter": .string("\n\n")]),
      PipelineNode(id: id("crop"), kind: .sceneNavigationCrop),
      PipelineNode(id: id("image"), kind: imageKind),
      PipelineNode(id: id("output"), kind: .imageOutput),
    ],
    connections: [
      link("brief", "prompt", "navigate", "originalPrompt"),
      link("previous", "scenePlan", "navigate", "previousPlan"),
      link("trackpad", "x", "navigate", "x"),
      link("trackpad", "y", "navigate", "y"),
      link("navigate", "prompt", "writer", "prompt"),
      link("writer", "text", "parse", "text"),
      link("parse", "prompt", "finalPrompt", "stringA"),
      link("style", "value", "finalPrompt", "stringB"),
      link("finalPrompt", "value", "image", "prompt"),
      link("previousFrame", "image", "crop", "image"),
      link("previous", "scenePlan", "crop", "previousPlan"),
      link("trackpad", "x", "crop", "x"),
      link("trackpad", "y", "crop", "y"),
      link("crop", "image", "image", "referenceImage"),
      link("parse", "scenePlan", "output", "scenePlan"),
      link("image", "image", "output", "image"),
    ],
    primaryOutputNodeIDs: [id("output")])
  let engine = PixeltjePipelineEngine(
    additionalNodeDescriptors: [
      .init(kind: writerKind, displayName: "Scene Writer", category: "Test",
        inputs: [.init(name: "prompt", type: .prompt)],
        outputs: [.init(name: "text", type: .string)]),
      .init(kind: imageKind, displayName: "Scene Image", category: "Test",
        inputs: [.init(name: "prompt", type: .prompt),
          .init(name: "referenceImage", type: .image, isRequired: false)],
        outputs: [.init(name: "image", type: .image)]),
    ],
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors() + [
      PipelineNodeExecutor(kind: writerKind) { _, inputs, _ in
        let prompt = inputs["prompt"]?.value(as: String.self) ?? ""
        let plan = PipelineScenePlan(
          imagePrompt: prompt,
          defaultNextView: "Follow the open road",
          regions: [
            .init(id: "road", label: "Road", box: [0, 0, 1, 1],
              nextView: "Continue along the road"),
            .init(id: "castle", label: "Castle", box: [0.6, 0.1, 0.9, 0.7],
              nextView: "Approach the castle gate"),
          ])
        return PipelineNodeResult(outputs: [
          "text": PipelineNodeValue(try plan.encodedJSON(), type: .string)
        ])
      },
      PipelineNodeExecutor(kind: imageKind) { _, inputs, context in
        let prompt = inputs["prompt"]?.value(as: String.self) ?? ""
        let hasReference = inputs["referenceImage"]?.value(as: PipelineImageInput.self) != nil
        let image = PipelineGeneratedImage(width: 1, height: 1,
          planarRGB: [hasReference ? 1 : 0,
            prompt.hasSuffix("\n\nPersistent blue-cloaked mouse") ? 1 : 0, 0],
          encoding: .sRGBZeroToOne,
          semanticPipelineSHA256: context.semanticSHA256)
        return PipelineNodeResult(outputs: [
          "image": PipelineNodeValue(image, type: .image)
        ])
      },
    ])

  #expect(await engine.validate(document).isValid)
  #expect(await engine.executionProfile(for: document)?.outputKind == .image)
  let first = try await engine.execute(
    document, packageRootsByID: [:], invocation: .init())
  let firstJSON = try #require(first.image?.scenePlanJSON)
  #expect(try PipelineScenePlan.decode(firstJSON).imagePrompt == "An open fantasy road")
  #expect(first.image?.planarRGB.first == 0)
  #expect(first.image?.planarRGB[1] == 1)

  let previousPixels = try PipelineImageInput(
    width: 8, height: 8,
    rgba: (0..<64).flatMap { pixel in
      [pixel % 8 >= 4 ? Float(1) : 0, 0, 0, 1]
    })

  let castle = try await engine.execute(document, packageRootsByID: [:], invocation: .init(values: [
    PipelineInvocation.previousScenePlanKey: .string(firstJSON),
    PipelineInvocation.trackpadXKey: .number(0.75),
    PipelineInvocation.trackpadYKey: .number(0.5),
    PipelineInvocation.sourceImageKey: .image(previousPixels),
  ]))
  let castleJSON = try #require(castle.image?.scenePlanJSON)
  #expect(try PipelineScenePlan.decode(castleJSON).imagePrompt.contains("Approach the castle gate"))
  #expect(castle.image?.planarRGB.first == 1)
  #expect(castle.image?.planarRGB[1] == 1)

  let road = try await engine.execute(document, packageRootsByID: [:], invocation: .init(values: [
    PipelineInvocation.previousScenePlanKey: .string(firstJSON),
    PipelineInvocation.trackpadXKey: .number(0.1),
    PipelineInvocation.trackpadYKey: .number(0.5),
    PipelineInvocation.sourceImageKey: .image(previousPixels),
  ]))
  let roadJSON = try #require(road.image?.scenePlanJSON)
  #expect(try PipelineScenePlan.decode(roadJSON).imagePrompt.contains("Continue along the road"))
  #expect(road.image?.planarRGB.first == 1)
  #expect(road.image?.planarRGB[1] == 1)
}

@Test func navigationCropCentersTrackpadDestination() throws {
  let pixels = try PipelineImageInput(
    width: 8, height: 8,
    rgba: (0..<64).flatMap { pixel in
      [pixel % 8 >= 4 ? Float(1) : 0, 0, 0, 1]
    })
  let plan = PipelineScenePlan(
    imagePrompt: "A castle", defaultNextView: "Forward",
    regions: [.init(id: "gate", label: "Gate", box: [0.65, 0.3, 0.85, 0.7],
      nextView: "Enter the gate")])
  let crop = try PipelineNavigationCrop.make(
    image: pixels, plan: plan, x: 0.75, y: 0.5, size: 256)
  #expect(crop.width == 256)
  #expect(crop.rgba[(128 * 256 + 128) * 4] == 1)
  #expect(crop.rgba[(128 * 256) * 4] < 0.5)
}

@Test func scenePlanRepairsRegionIDsAndBoxesWithoutLosingTheView() throws {
  let imperfect = """
    {"imagePrompt":"Castle","defaultNextView":"Forward","regions":[
      {"id":"castle","label":"Castle","box":[1.2,0.8,0.4,0.2],"nextView":"Gate"},
      {"id":"castle","label":"Gate","box":[0.5,0.3,0.7,0.7]},
      {"id":"bad","label":"Bad","box":[0.5,0.5,0.5,0.5]},
      {"id":"missing","label":"Missing"}
    ]}
    """
  let plan = try PipelineScenePlan.decode(imperfect)
  #expect(plan.regions.map(\.id) == ["castle", "castle-2"])
  #expect(plan.regions[0].box == [0.4, 0.2, 1, 0.8])
  #expect(plan.regions[1].nextView.contains("Move closer to the Gate"))
}

@Test func scenePlanReportsWhenEveryRegionBoxIsUnusable() {
  let invalid = """
    {"imagePrompt":"Castle","regions":{"gate":{"label":"Gate","box":[0.5,0.5,0.5,0.5]}}}
    """
  #expect(throws: (any Error).self) { try PipelineScenePlan.decode(invalid) }
}

@Test func scenePlanAcceptsKeyedRegionsWithoutPerRegionContinuation() throws {
  let text = """
    {"imagePrompt":"A castle beyond a road", "regions": {
      "castle": {"id":"same", "label":"castle", "box":[0.5,0.3,0.7,0.9]},
      "gate": {"id":"same", "label":"gate", "box":[0.55,0.5,0.65,0.7]}
    }}
    """
  let plan = try PipelineScenePlan.decode(text)
  #expect(plan.region(atX: 0.6, y: 0.6)?.id == "gate")
  #expect(try plan.nextWriterPrompt(x: 0.6, y: 0.6)
    .contains("Show the gate huge in the center"))
}

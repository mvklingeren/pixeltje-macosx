import PixeltjePipelineDomain
import PixeltjePipelineEngine
import Testing

private func resource(
  _ kind: PipelineResourceKind,
  role: String
) -> PipelineResourceReference {
  PipelineResourceReference(
    kind: kind,
    packageID: "org.pixeltje.test",
    packageVersion: "1",
    contentHash: "sha256:test-\(role)",
    componentRole: role,
    functionName: kind == .coreAIModel ? "main" : nil,
    familyABI: "test@1")
}

@Test func builtInVocabularyValidatesATextToImageGraph() {
  let prompt = PipelineNodeID(rawValue: "prompt")
  let tokenizer = PipelineNodeID(rawValue: "tokenizer")
  let encoder = PipelineNodeID(rawValue: "encoder")
  let seed = PipelineNodeID(rawValue: "seed")
  let noise = PipelineNodeID(rawValue: "noise")
  let denoiser = PipelineNodeID(rawValue: "denoiser")
  let sampler = PipelineNodeID(rawValue: "sampler")
  let decoder = PipelineNodeID(rawValue: "decoder")
  let output = PipelineNodeID(rawValue: "output")
  let document = PipelineDocument(
    id: PipelineID(rawValue: "coreai-text-to-image"),
    name: "Core AI Text to Image",
    mode: .textToImage,
    requirements: PipelineRequirements(familyABIs: ["test@1"]),
    nodes: [
      PipelineNode(id: prompt, kind: .promptInput),
      PipelineNode(
        id: tokenizer,
        kind: .tokenizer,
        resources: ["tokenizer": .linked(resource(.tokenizer, role: "tokenizer"))]),
      PipelineNode(
        id: encoder,
        kind: .textEncoder,
        resources: ["model": .linked(resource(.coreAIModel, role: "textEncoder"))]),
      PipelineNode(id: seed, kind: .seedInput),
      PipelineNode(
        id: noise,
        kind: .seededNoise,
        parameters: [
          "width": .integer(64),
          "height": .integer(64),
          "channels": .integer(16),
        ]),
      PipelineNode(
        id: denoiser,
        kind: .denoiser,
        resources: ["model": .linked(resource(.coreAIModel, role: "denoiser"))]),
      PipelineNode(id: sampler, kind: .sampler),
      PipelineNode(
        id: decoder,
        kind: .vaeDecoder,
        resources: ["model": .linked(resource(.coreAIModel, role: "vaeDecoder"))]),
      PipelineNode(id: output, kind: .imageOutput),
    ],
    connections: [
      .init(output: .init(nodeID: prompt, port: "prompt"),
        input: .init(nodeID: tokenizer, port: "prompt")),
      .init(output: .init(nodeID: tokenizer, port: "tokens"),
        input: .init(nodeID: encoder, port: "tokens")),
      .init(output: .init(nodeID: seed, port: "seed"),
        input: .init(nodeID: noise, port: "seed")),
      .init(output: .init(nodeID: noise, port: "noise"),
        input: .init(nodeID: sampler, port: "noise")),
      .init(output: .init(nodeID: encoder, port: "conditioning"),
        input: .init(nodeID: sampler, port: "conditioning")),
      .init(output: .init(nodeID: denoiser, port: "function"),
        input: .init(nodeID: sampler, port: "denoiser")),
      .init(output: .init(nodeID: sampler, port: "latent"),
        input: .init(nodeID: decoder, port: "latent")),
      .init(output: .init(nodeID: decoder, port: "image"),
        input: .init(nodeID: output, port: "image")),
    ],
    exposedParameters: [
      PipelineExposedParameter(
        id: "steps",
        label: "Steps",
        valueType: .integer,
        target: PipelineParameterReference(nodeID: sampler, parameter: "steps"),
        defaultValue: .integer(8),
        minimum: 1,
        maximum: 100)
    ])

  let report = PipelineGraphValidator.validate(
    document,
    registry: .coreAIV1,
    engineVersion: PixeltjePipelineEngine.currentEngineVersion)
  let orderedNodeIDs = try? PipelineGraphTopology.orderedNodeIDs(in: document)

  #expect(report.isValid)
  #expect(orderedNodeIDs?.last == output)
}

@Test func builtInVocabularyIncludesPrimitiveLogicAndSchedulerNodes() throws {
  let registry = PipelineNodeRegistry.coreAIV1
  let primitiveKinds: [PipelineNodeKind] = [
    .primitiveString,
    .primitiveInt,
    .primitiveFloat,
    .primitiveBoolean,
  ]

  for kind in primitiveKinds {
    let descriptor = try #require(registry.descriptor(for: kind))
    #expect(descriptor.category == "Primitives")
    #expect(descriptor.input(named: "value")?.isRequired == false)
    #expect(descriptor.output(named: "value") != nil)
    #expect(descriptor.parameter(named: "value")?.defaultValue != nil)
  }

  let conditional = try #require(registry.descriptor(for: .ifElseSwitch))
  #expect(conditional.input(named: "condition")?.type == .boolean)
  #expect(conditional.input(named: "falseValue")?.typeVariable == "value")
  #expect(conditional.input(named: "trueValue")?.typeVariable == "value")
  #expect(conditional.output(named: "value")?.typeVariable == "value")

  let scheduler = try #require(registry.descriptor(for: .basicScheduler))
  #expect(scheduler.input(named: "denoiser")?.type == .modelFunction)
  #expect(scheduler.input(named: "steps")?.type == .integer)
  #expect(scheduler.input(named: "denoise")?.type == .number)
  #expect(scheduler.output(named: "schedule")?.type == .schedule)
  #expect(registry.descriptor(for: .sampler)?.input(named: "schedule")?.type == .schedule)
}

@Test func builtInVocabularyIncludesReferenceVideoNodes() throws {
  let registry = PipelineNodeRegistry.coreAIV1

  #expect(registry.descriptor(for: .resolutionSelector)?.output(named: "width")?.type == .integer)
  #expect(PipelineNodeKind.markdownNote.rawValue == "edit.markdownNote")
  #expect(registry.descriptor(for: .markdownNote)?.parameter(named: "text") != nil)
  #expect(registry.descriptor(for: .textEncoderModel)?.output(named: "function")?.type
    == .textEncoderFunction)
  #expect(registry.descriptor(for: .vaeModel)?.output(named: "function")?.type == .vaeFunction)
  #expect(registry.descriptor(for: .vaeImageDecoder)?.output(named: "image")?.type == .image)
  #expect(registry.descriptor(for: .vaeAudioDecoder)?.output(named: "audio")?.type == .audio)
  #expect(registry.descriptor(for: .randomNoise)?.output(named: "noise")?.type == .noise)
  #expect(registry.descriptor(for: .samplerSelector)?.output(named: "function")?.type
    == .samplerFunction)
  #expect(registry.descriptor(for: .basicGuider)?.output(named: "guider")?.type == .guider)
  #expect(registry.descriptor(for: .advancedSampler)?.input(named: "schedule")?.type
    == .schedule)

  let reference = try #require(registry.descriptor(for: .referenceToVideoConditioning))
  #expect(reference.input(named: "textEncoder")?.type == .textEncoderFunction)
  #expect(reference.input(named: "videoVAE")?.type == .vaeFunction)
  #expect(reference.input(named: "referenceImage1")?.isRequired == false)
  #expect(reference.output(named: "conditioning")?.type == .conditioning)
  #expect(reference.output(named: "latent")?.type == .latent)

  let createVideo = try #require(registry.descriptor(for: .createVideo))
  #expect(createVideo.input(named: "images")?.type == .image)
  #expect(createVideo.input(named: "audio")?.type == .audio)
  #expect(createVideo.output(named: "video")?.type == .video)
  #expect(registry.descriptor(for: .videoOutput)?.isTerminal == true)
}

@Test func builtInVocabularyIncludesFlux2ImageEditNodes() throws {
  let registry = PipelineNodeRegistry.coreAIV1

  let textEncode = try #require(registry.descriptor(for: .textConditioningEncoder))
  #expect(textEncode.input(named: "textEncoder")?.type == .textEncoderFunction)
  #expect(textEncode.output(named: "conditioning")?.type == .conditioning)

  let scheduler = try #require(registry.descriptor(for: .flux2Scheduler))
  #expect(scheduler.input(named: "width")?.type == .integer)
  #expect(scheduler.output(named: "schedule")?.type == .schedule)

  let guider = try #require(registry.descriptor(for: .cfgGuider))
  #expect(guider.input(named: "positive")?.type == .conditioning)
  #expect(guider.input(named: "negative")?.type == .conditioning)
  #expect(guider.output(named: "guider")?.type == .guider)

  let encoder = try #require(registry.descriptor(for: .vaeImageEncoder))
  #expect(encoder.input(named: "image")?.type == .image)
  #expect(encoder.input(named: "vae")?.type == .vaeFunction)
  #expect(encoder.output(named: "latent")?.type == .latent)

  #expect(registry.descriptor(for: .emptyFlux2LatentImage)?.output(named: "latent")?.type
    == .latent)
  #expect(registry.descriptor(for: .imageDimensions)?.output(named: "width")?.type
    == .integer)
  #expect(registry.descriptor(for: .referenceLatentConditioning)?.output(
    named: "conditioning")?.type == .conditioning)
  #expect(registry.descriptor(for: .imageScaleToTotalPixels)?.output(named: "image")?.type
    == .image)
}

@Test func builtInVocabularyIncludesZImageComfyUINodes() throws {
  let registry = PipelineNodeRegistry.coreAIV1

  let zero = try #require(registry.descriptor(for: .zeroConditioning))
  #expect(zero.input(named: "conditioning")?.type == .conditioning)
  #expect(zero.output(named: "conditioning")?.type == .conditioning)

  let latent = try #require(registry.descriptor(for: .emptyLatentImage))
  #expect(latent.parameter(named: "width")?.defaultValue == .integer(1024))
  #expect(latent.output(named: "latent")?.type == .latent)

  let sampling = try #require(registry.descriptor(for: .discreteFlowModelSampling))
  #expect(sampling.input(named: "model")?.type == .modelFunction)
  #expect(sampling.output(named: "model")?.type == .modelFunction)
  #expect(sampling.parameter(named: "shift")?.defaultValue == .number(3))

  let sampler = try #require(registry.descriptor(for: .kSampler))
  #expect(sampler.input(named: "positive")?.type == .conditioning)
  #expect(sampler.input(named: "negative")?.type == .conditioning)
  #expect(sampler.input(named: "latent")?.type == .latent)
  #expect(sampler.input(named: "seed")?.type == .seed)
  #expect(sampler.input(named: "steps")?.type == .integer)
  #expect(sampler.input(named: "guidance")?.type == .number)
  #expect(sampler.input(named: "steps")?.isRequired == false)
  #expect(sampler.input(named: "guidance")?.isRequired == false)
  #expect(sampler.parameter(named: "scheduler")?.defaultValue == .string("simple"))
}

@Test func ifElseRequiresBothBranchesAndItsOutputToShareAType() {
  let textFalse = PipelineNodeID(rawValue: "text-false")
  let textTrue = PipelineNodeID(rawValue: "text-true")
  let integerTrue = PipelineNodeID(rawValue: "integer-true")
  let condition = PipelineNodeID(rawValue: "condition")
  let conditional = PipelineNodeID(rawValue: "conditional")
  let output = PipelineNodeID(rawValue: "output")
  let textOutputKind = PipelineNodeKind(rawValue: "test.text-output")
  var registry = PipelineNodeRegistry.coreAIV1
  registry.register(PipelineNodeDescriptor(
    kind: textOutputKind,
    displayName: "Text Output",
    category: "Test",
    inputs: [.init(name: "value", type: .string)],
    isTerminal: true))

  func document(trueNode: PipelineNodeID, truePort: String) -> PipelineDocument {
    PipelineDocument(
      id: PipelineID(rawValue: "conditional"),
      name: "Conditional",
      mode: .generic,
      nodes: [
        PipelineNode(id: textFalse, kind: .primitiveString),
        PipelineNode(id: textTrue, kind: .primitiveString),
        PipelineNode(id: integerTrue, kind: .primitiveInt),
        PipelineNode(id: condition, kind: .primitiveBoolean),
        PipelineNode(id: conditional, kind: .ifElseSwitch),
        PipelineNode(id: output, kind: textOutputKind),
      ],
      connections: [
        .init(
          output: .init(nodeID: condition, port: "value"),
          input: .init(nodeID: conditional, port: "condition")),
        .init(
          output: .init(nodeID: textFalse, port: "value"),
          input: .init(nodeID: conditional, port: "falseValue")),
        .init(
          output: .init(nodeID: trueNode, port: truePort),
          input: .init(nodeID: conditional, port: "trueValue")),
        .init(
          output: .init(nodeID: conditional, port: "value"),
          input: .init(nodeID: output, port: "value")),
      ])
  }

  let valid = PipelineGraphValidator.validate(
    document(trueNode: textTrue, truePort: "value"), registry: registry)
  let invalid = PipelineGraphValidator.validate(
    document(trueNode: integerTrue, truePort: "value"), registry: registry)

  #expect(valid.isValid)
  #expect(invalid.errors.contains { $0.code == .incompatiblePorts })
}

@Test func primitivesConnectToPromptAndSeedSemanticPorts() {
  let text = PipelineNodeID(rawValue: "text")
  let integer = PipelineNodeID(rawValue: "integer")
  let output = PipelineNodeID(rawValue: "output")
  let outputKind = PipelineNodeKind(rawValue: "test.prompt-seed-output")
  var registry = PipelineNodeRegistry.coreAIV1
  registry.register(PipelineNodeDescriptor(
    kind: outputKind,
    displayName: "Prompt and Seed Output",
    category: "Test",
    inputs: [
      .init(name: "prompt", type: .prompt),
      .init(name: "seed", type: .seed),
    ],
    isTerminal: true))
  let document = PipelineDocument(
    id: PipelineID(rawValue: "scalar-aliases"),
    name: "Scalar Aliases",
    mode: .generic,
    nodes: [
      PipelineNode(id: text, kind: .primitiveString),
      PipelineNode(id: integer, kind: .primitiveInt),
      PipelineNode(id: output, kind: outputKind),
    ],
    connections: [
      .init(
        output: .init(nodeID: text, port: "value"),
        input: .init(nodeID: output, port: "prompt")),
      .init(
        output: .init(nodeID: integer, port: "value"),
        input: .init(nodeID: output, port: "seed")),
    ])

  #expect(PipelineGraphValidator.validate(document, registry: registry).isValid)
}

@Test func builtInVocabularyIncludesHiDreamO1AndQwenImageNodes() throws {
  let registry = PipelineNodeRegistry.coreAIV1
  let addedKinds: [PipelineNodeKind] = [
    .checkpoint,
    .emptyHiDreamO1LatentImage,
    .hiDreamO1ReferenceImages,
    .hiDreamO1SeamSmoothing,
    .modelNoiseScale,
    .customSampler,
    .lcmSamplerSelector,
    .qwenImage21TextEncoder,
    .textConcatenate,
    .textReplace,
    .textRegexReplace,
    .textJSONExtract,
    .textGenerate,
    .languageModel,
    .chatCompletion,
    .previewAny,
    .textOutput,
  ]

  for kind in addedKinds {
    #expect(registry.descriptor(for: kind) != nil)
  }

  let checkpoint = try #require(registry.descriptor(for: .checkpoint))
  #expect(checkpoint.outputs.map(\.name) == ["model", "textEncoder", "vae"])
  #expect(checkpoint.output(named: "textEncoder")?.type == .textEncoderFunction)
  #expect(checkpoint.requiredResourceSlots == ["model"])

  let references = try #require(registry.descriptor(for: .hiDreamO1ReferenceImages))
  #expect(references.inputs.filter(\.isRequired).map(\.name) == ["positive", "negative"])
  #expect(references.input(named: "referenceImage10")?.type == .image)
  #expect(references.outputs.map(\.name) == ["positive", "negative"])

  let customSampler = try #require(registry.descriptor(for: .customSampler))
  #expect(customSampler.input(named: "denoiser")?.type == .modelFunction)
  #expect(customSampler.input(named: "schedule")?.type == .schedule)
  #expect(customSampler.outputs.map(\.name) == ["latent", "denoisedLatent"])
  #expect(customSampler.parameter(named: "addNoise")?.valueType == .boolean)

  let qwenEncoder = try #require(registry.descriptor(for: .qwenImage21TextEncoder))
  #expect(qwenEncoder.input(named: "textEncoder")?.type == .textEncoderFunction)
  #expect(qwenEncoder.input(named: "vae")?.isRequired == false)
  #expect(qwenEncoder.input(named: "referenceImage8")?.type == .image)
  #expect(qwenEncoder.outputs.map(\.name) == ["positive", "negative", "latent"])

  let preview = try #require(registry.descriptor(for: .previewAny))
  #expect(preview.input(named: "value")?.type == .any)
  #expect(preview.output(named: "text")?.type == .string)

  let languageModel = try #require(registry.descriptor(for: .languageModel))
  #expect(languageModel.output(named: "model")?.type == .languageModelFunction)
  #expect(languageModel.requiredResourceSlots == ["manifest", "model", "tokenizer"])

  let completion = try #require(registry.descriptor(for: .chatCompletion))
  #expect(completion.input(named: "model")?.type == .languageModelFunction)
  #expect(completion.input(named: "prompt")?.type == .string)
  #expect(completion.output(named: "text")?.type == .string)
  #expect(completion.parameter(named: "maxTokens")?.defaultValue == .integer(256))

  let textOutput = try #require(registry.descriptor(for: .textOutput))
  #expect(textOutput.isTerminal)
  #expect(textOutput.input(named: "text")?.type == .string)

  // Save Image (Advanced) passes its image through, so the output node carries
  // both the generated result and the passthrough.
  let imageOutput = try #require(registry.descriptor(for: .imageOutput))
  #expect(imageOutput.outputs.map(\.name) == ["result", "image"])
  #expect(imageOutput.parameter(named: "filenamePrefix")?.valueType == .string)
}

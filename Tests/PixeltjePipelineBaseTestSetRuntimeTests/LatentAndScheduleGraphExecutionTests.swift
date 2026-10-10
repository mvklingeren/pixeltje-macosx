import Foundation
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import Testing

private func node(
  _ id: String, _ kind: String, _ parameters: [String: PipelineValue] = [:]
) -> PipelineNode {
  PipelineNode(
    id: PipelineNodeID(rawValue: id),
    kind: PipelineNodeKind(rawValue: kind),
    parameters: parameters)
}

private func link(
  _ source: String, _ output: String, _ destination: String, _ input: String
) -> PipelineConnection {
  PipelineConnection(
    output: PipelinePortReference(nodeID: PipelineNodeID(rawValue: source), port: output),
    input: PipelinePortReference(nodeID: PipelineNodeID(rawValue: destination), port: input))
}

private enum LatentGraphTestError: Error {
  case wrongOutputKind
}

/// Runs a graph whose final value reaches Text Output through Preview as Text.
private func preview(
  nodes: [PipelineNode], connections: [PipelineConnection], from source: (String, String)
) async throws -> String {
  let document = PipelineDocument(
    id: PipelineID(rawValue: "latent-schedule-graph-test"),
    name: "Latent and schedule graph test",
    mode: .generic,
    nodes: nodes + [node("preview", "utility.previewAny"), node("output", "output.text")],
    connections: connections + [
      link(source.0, source.1, "preview", "value"),
      link("preview", "text", "output", "text"),
    ],
    primaryOutputNodeIDs: [PipelineNodeID(rawValue: "output")])
  let engine = PixeltjePipelineEngine(
        additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  let result = try await engine.execute(
    document,
    packageRootsByID: [:],
    invocation: PipelineInvocation())
  guard case .plainText(let text) = result else { throw LatentGraphTestError.wrongOutputKind }
  return text.text
}

@Test func karrasScheduleCanBeSplitAndFlippedInAGraph() async throws {
  let result = try await preview(
    nodes: [
      node("karras", "diffusion.karrasScheduler", [
        "steps": .integer(4), "sigmaMax": .number(10), "sigmaMin": .number(1),
        "rho": .number(1),
      ]),
      node("split", "diffusion.splitSchedule", ["step": .integer(2)]),
      node("flip", "diffusion.flipSchedule"),
    ],
    connections: [
      link("karras", "schedule", "split", "schedule"),
      link("split", "low", "flip", "schedule"),
    ],
    from: ("flip", "schedule"))
  #expect(result == "[0.0001, 1, 4]")
}

@Test func truncatedScheduleCanBeForcedToFinishAtZero() async throws {
  let result = try await preview(
    nodes: [
      node("ays", "diffusion.alignYourStepsScheduler", [
        "modelType": .string("SD1"), "steps": .integer(10), "denoise": .number(1),
      ]),
      node("split", "diffusion.splitScheduleDenoise", ["denoise": .number(0.3)]),
      node("zero", "diffusion.forceFullDenoise"),
    ],
    connections: [
      link("ays", "schedule", "split", "schedule"),
      link("split", "high", "zero", "schedule"),
    ],
    from: ("zero", "schedule"))
  #expect(result == "[14.6146, 6.47458, 3.86367, 2.69462, 1.88419, 1.39438, 0.964258, 0]")
}

@Test func unknownAlignYourStepsModelFailsClearly() async throws {
  await #expect(throws: (any Error).self) {
    try await preview(
      nodes: [node("ays", "diffusion.alignYourStepsScheduler", ["modelType": .string("SD2")])],
      connections: [],
      from: ("ays", "schedule"))
  }
}

@Test func emptyVideoLatentsUseTheirFamilyCompression() async throws {
  let hunyuan = try await preview(
    nodes: [node("latent", "latent.emptyHunyuanVideo")],
    connections: [],
    from: ("latent", "latent"))
  #expect(hunyuan == "Latent [1, 16, 7, 60, 106]")

  let ltxv = try await preview(
    nodes: [
      node("length", "primitive.int", ["value": .integer(9)]),
      node("latent", "latent.emptyLTXVVideo", ["width": .integer(512), "height": .integer(256)]),
    ],
    connections: [link("length", "value", "latent", "length")],
    from: ("latent", "latent"))
  #expect(ltxv == "Latent [1, 128, 2, 8, 16]")
}

@Test func latentBatchAndScaleOperationsCompose() async throws {
  let result = try await preview(
    nodes: [
      node("width", "primitive.int", ["value": .integer(512)]),
      node("empty", "latent.emptyImage", ["height": .integer(768), "batchSize": .integer(2)]),
      node("select", "latent.fromBatch", ["batchIndex": .integer(1), "length": .integer(1)]),
      node("repeat", "latent.repeatBatch", ["amount": .integer(3)]),
      node("scale", "latent.upscaleBy", [
        "upscaleMethod": .string("bislerp"), "scaleBy": .number(1.5),
      ]),
      node("mask", "mask.solid", [
        "width": .integer(64), "height": .integer(64), "value": .number(1),
      ]),
      node("noiseMask", "latent.setNoiseMask"),
    ],
    connections: [
      link("width", "value", "empty", "width"),
      link("empty", "latent", "select", "latent"),
      link("select", "latent", "repeat", "latent"),
      link("repeat", "latent", "scale", "latent"),
      link("scale", "latent", "noiseMask", "latent"),
      link("mask", "mask", "noiseMask", "mask"),
    ],
    from: ("noiseMask", "latent"))
  #expect(result == "Latent [3, model channels, 144, 96] with noise mask")
}

@Test func upscaleLatentFollowsAspectRatioAtTheLatentScale() async throws {
  let result = try await preview(
    nodes: [
      node("empty", "latent.emptyFlux2Image", [
        "width": .integer(1024), "height": .integer(512),
      ]),
      node("scale", "latent.upscale", [
        "upscaleMethod": .string("bilinear"), "width": .integer(0), "height": .integer(1024),
      ]),
    ],
    connections: [link("empty", "latent", "scale", "latent")],
    from: ("scale", "latent"))
  #expect(result == "Latent [1, 128, 64, 128]")
}

@Test func noiseAndSamplerSelectorsProduceTypedValues() async throws {
  #expect(try await preview(
    nodes: [node("noise", "latent.disableNoise")], connections: [],
    from: ("noise", "noise")) == "Noise (disabled)")
  #expect(try await preview(
    nodes: [node("sampler", "diffusion.lcmSampler")], connections: [],
    from: ("sampler", "function")) == "Sampler lcm")
}

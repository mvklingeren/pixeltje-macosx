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

private enum ScalarGraphTestError: Error {
  case wrongOutputKind
}

private func executeText(
  nodes: [PipelineNode], connections: [PipelineConnection]
) async throws -> String {
  let document = PipelineDocument(
    id: PipelineID(rawValue: "scalar-graph-test"),
    name: "Scalar graph test",
    mode: .generic,
    nodes: nodes,
    connections: connections,
    primaryOutputNodeIDs: [PipelineNodeID(rawValue: "output")])
  let engine = PixeltjePipelineEngine(
        additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  let result = try await engine.execute(
    document,
    packageRootsByID: [:],
    invocation: PipelineInvocation())
  guard case .plainText(let text) = result else { throw ScalarGraphTestError.wrongOutputKind }
  return text.text
}

@Test func resolutionCanOverrideAnIntegerPrimitiveAndReachTextOutput() async throws {
  let result = try await executeText(
    nodes: [
      node("resolution", "input.resolution", [
        "aspectRatio": .string("1:1 (Square)"),
        "megapixels": .number(1),
        "multiple": .integer(8),
      ]),
      node("integer", "primitive.int", ["value": .integer(64)]),
      node("preview", "utility.previewAny"),
      node("output", "output.text"),
    ],
    connections: [
      link("resolution", "width", "integer", "value"),
      link("integer", "value", "preview", "value"),
      link("preview", "text", "output", "text"),
    ])
  #expect(result == "1024")
}

@Test func regexExtractionHonorsCaseAndMultilineOptionsInAGraph() async throws {
  let result = try await executeText(
    nodes: [
      node("source", "primitive.string", ["value": .string("foo\nBAR")]),
      node("extract", "text.regexExtract", [
        "pattern": .string("^bar$"),
        "mode": .string("First Match"),
        "caseInsensitive": .boolean(true),
        "multiline": .boolean(true),
      ]),
      node("output", "output.text"),
    ],
    connections: [
      link("source", "value", "extract", "string"),
      link("extract", "value", "output", "text"),
    ])
  #expect(result == "BAR")
}

@Test func substringUsesUnicodeCodePointsAndNegativeIndices() async throws {
  let result = try await executeText(
    nodes: [
      node("source", "primitive.string", ["value": .string("A😀B")]),
      node("slice", "text.substring", ["start": .integer(-2), "end": .integer(-1)]),
      node("output", "output.text"),
    ],
    connections: [
      link("source", "value", "slice", "string"),
      link("slice", "value", "output", "text"),
    ])
  #expect(result == "😀")
}

@Test func emptyFindInReplaceInsertsAtCodePointBoundaries() async throws {
  let result = try await executeText(
    nodes: [
      node("source", "primitive.string", ["value": .string("A😀")]),
      node("replace", "text.replace", [
        "find": .string(""), "replace": .string("|"),
      ]),
      node("output", "output.text"),
    ],
    connections: [
      link("source", "value", "replace", "string"),
      link("replace", "value", "output", "text"),
    ])
  #expect(result == "|A|😀|")
}

@Test func regexReplacementHonorsCaseAndMultilineOptions() async throws {
  let result = try await executeText(
    nodes: [
      node("source", "primitive.string", ["value": .string("foo\nBAR")]),
      node("replace", "text.regexReplace", [
        "pattern": .string("^bar$"),
        "replacement": .string("done"),
        "caseInsensitive": .boolean(true),
        "multiline": .boolean(true),
      ]),
      node("output", "output.text"),
    ],
    connections: [
      link("source", "value", "replace", "string"),
      link("replace", "value", "output", "text"),
    ])
  #expect(result == "foo\ndone")
}

@Test func baseOperationsRunThroughNativeNodeScheduling() async throws {
  let nodes = [
    node("source", "primitive.string", ["value": .string("  hello  ")]),
    node("trim", "text.trim", ["mode": .string("Both")]),
    node("output", "output.text"),
  ]
  let connections = [
    link("source", "value", "trim", "string"),
    link("trim", "value", "output", "text"),
  ]
  let document = PipelineDocument(
    id: PipelineID(rawValue: "native-base-operations"),
    name: "Native base operations", mode: .generic,
    nodes: nodes, connections: connections,
    primaryOutputNodeIDs: [PipelineNodeID(rawValue: "output")])
  let engine = PixeltjePipelineEngine(
        additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  let output = try await engine.execute(
    document, packageRootsByID: [:], invocation: PipelineInvocation())
  guard case .plainText(let text) = output else {
    Issue.record("Expected plain text output.")
    return
  }
  #expect(text.text == "hello")
}

@Test func generatedImageCanFlowIntoReusableImageScaleNode() async throws {
  let producerKind = PipelineNodeKind(rawValue: "test.generatedImage")
  let producerDescriptor = PipelineNodeDescriptor(
    kind: producerKind, displayName: "Generated Test Image", category: "Tests",
    outputs: [.init(name: "image", type: .image)])
  let producer = PipelineNodeExecutor(kind: producerKind) { _, _, context in
    let image = PipelineGeneratedImage(
      width: 2, height: 2,
      planarRGB: [Float](repeating: 1, count: 12),
      encoding: .sRGBMinusOneToOne,
      semanticPipelineSHA256: context.semanticSHA256)
    return PipelineNodeResult(outputs: [
      "image": PipelineNodeValue(image, type: .image)
    ])
  }
  let document = PipelineDocument(
    id: PipelineID(rawValue: "native-image-scale"),
    name: "Generated image scale", mode: .generic,
    nodes: [
      PipelineNode(id: PipelineNodeID(rawValue: "producer"), kind: producerKind),
      node("scale", "image.scale", [
        "width": .integer(4), "height": .integer(4),
        "upscaleMethod": .string("nearest-exact"),
      ]),
      node("output", "output.image"),
    ],
    connections: [
      link("producer", "image", "scale", "image"),
      link("scale", "image", "output", "image"),
    ],
    primaryOutputNodeIDs: [PipelineNodeID(rawValue: "output")])
  let engine = PixeltjePipelineEngine(
        additionalNodeDescriptors: [producerDescriptor],
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors() + [producer])
  let output = try await engine.execute(
    document, packageRootsByID: [:], invocation: PipelineInvocation())
  guard case .image(let image) = output else {
    Issue.record("Expected image output.")
    return
  }
  #expect(image.width == 4)
  #expect(image.height == 4)
  #expect(image.encoding == .sRGBZeroToOne)
  #expect(image.planarRGB.allSatisfy { $0 == 1 })
}

@Test func threePhaseSinusAdvancesAndWrapsTogether() async throws {
  let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let example = root.appendingPathComponent(
    "Examples/Artest/04-three-phase-sinus.pixpipeline.json")
  let document = try PipelineJSON.decode(Data(contentsOf: example))
  let engine = PixeltjePipelineEngine(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  let report = await engine.validate(document)
  #expect(report.isValid, "\(report.diagnostics)")

  func render(_ callIndex: Int64) async throws -> PipelineGeneratedImage {
    let output = try await engine.execute(
      document, packageRootsByID: [:], invocation: PipelineInvocation(values: [
        PipelineInvocation.loopCallIndexKey: .integer(callIndex)
      ]))
    guard case .image(let image) = output else {
      throw ScalarGraphTestError.wrongOutputKind
    }
    return image
  }

  let first = try await render(0)
  let shifted = try await render(1)
  let wrapped = try await render(30)
  let pixels = first.width * first.height
  for channel in 0..<3 {
    let range = channel * pixels..<(channel + 1) * pixels
    #expect(first.planarRGB[range] != shifted.planarRGB[range])
    #expect(first.planarRGB[range] == wrapped.planarRGB[range])
  }
}

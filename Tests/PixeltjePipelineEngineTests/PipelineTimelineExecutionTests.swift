import Foundation
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import Testing

@Test func timelinePreservesIntegerTypeBetweenProducerAndConsumer() async throws {
  let sourceKind = PipelineNodeKind(rawValue: "test.timelineIntegerSource")
  let sinkKind = PipelineNodeKind(rawValue: "test.timelineIntegerSink")
  func id(_ name: String) -> PipelineNodeID { .init(rawValue: name) }
  let settings = PipelineTimelineSettings(frameCount: 3, framesPerSecond: 30, tracks: [
    .init(path: "", interpolation: .linear, keyframes: [
      .init(frame: 0, value: .integer(2)),
      .init(frame: 2, value: .integer(9)),
    ]),
  ])
  let document = PipelineDocument(
    id: .init(rawValue: "timeline-integer"), name: "Timeline integer", mode: .generic,
    nodes: [
      PipelineNode(id: id("source"), kind: sourceKind),
      PipelineNode(id: id("timeline"), kind: .controlTimeline,
        parameters: settings.parameters),
      PipelineNode(id: id("sink"), kind: sinkKind),
      PipelineNode(id: id("start"), kind: .controlStart),
    ],
    connections: [
      .init(output: .init(nodeID: id("source"), port: "value"),
        input: .init(nodeID: id("timeline"), port: "value")),
      .init(output: .init(nodeID: id("timeline"), port: "value"),
        input: .init(nodeID: id("sink"), port: "value")),
    ],
    controlConnections: [
      .init(output: .init(nodeID: id("sink"), port: "completed"),
        input: .init(nodeID: id("timeline"), port: "completed")),
      .init(output: .init(nodeID: id("timeline"), port: "repeat"),
        input: .init(nodeID: id("start"), port: "again")),
    ],
    primaryOutputNodeIDs: [id("sink")])
  let engine = PixeltjePipelineEngine(additionalNodeDescriptors: [
    .init(kind: sourceKind, displayName: "Source", category: "Test",
      outputs: [.init(name: "value", type: .integer)]),
    .init(kind: sinkKind, displayName: "Sink", category: "Test",
      inputs: [.init(name: "value", type: .integer)],
      outputs: [.init(name: "completed", type: .control)], isTerminal: true),
  ], additionalNodeExecutors: [
    .init(kind: sourceKind) { _, _, _ in
      PipelineNodeResult(outputs: ["value": PipelineNodeValue(Int64(100), type: .integer)])
    },
    .init(kind: sinkKind) { _, inputs, context in
      guard let value = inputs["value"]?.value(as: Int64.self) else {
        throw PipelineEngineError.invalidInvocation("Expected integer Timeline output.")
      }
      return PipelineNodeResult(terminalOutput: .plainText(.init(
        text: String(value), semanticPipelineSHA256: context.semanticSHA256)))
    },
  ])
  #expect(await engine.validate(document).isValid)
  var registry = PipelineNodeRegistry.coreAIV1
  registry.register(.init(kind: sinkKind, displayName: "Sink", category: "Test",
    inputs: [.init(name: "value", type: .integer)],
    outputs: [.init(name: "completed", type: .control)], isTerminal: true))
  #expect(PipelineControlFlow.activeTimeline(
    in: document, registry: registry)?.settings.frameCount == 3)
  let result = try await engine.execute(document, packageRootsByID: [:],
    invocation: PipelineInvocation(values: [
      PipelineInvocation.loopCallIndexKey: .integer(1),
    ]))
  guard case .plainText(let text) = result else {
    Issue.record("Expected an integer result from the Timeline consumer.")
    return
  }
  #expect(text.text == "6")
  let pastEnd = try await engine.execute(document, packageRootsByID: [:],
    invocation: PipelineInvocation(values: [
      PipelineInvocation.loopCallIndexKey: .integer(5),
    ]))
  guard case .plainText(let held) = pastEnd else {
    Issue.record("Expected the final keyframe to hold after the Timeline ends.")
    return
  }
  #expect(held.text == "9")
  var passthrough = document
  let timelineIndex = try #require(passthrough.nodes.firstIndex(where: {
    $0.id == id("timeline")
  }))
  passthrough.nodes[timelineIndex].parameters["tracks"] = .array([])
  let unchanged = try await engine.execute(passthrough, packageRootsByID: [:],
    invocation: PipelineInvocation(values: [
      PipelineInvocation.loopCallIndexKey: .integer(1),
    ]))
  guard case .plainText(let original) = unchanged else {
    Issue.record("Expected the unkeyframed Timeline to pass through the integer.")
    return
  }
  #expect(original.text == "100")
}

@Test func timelineUpdatesJSONStateWithoutDroppingIncomingFields() async throws {
  func id(_ name: String) -> PipelineNodeID { .init(rawValue: name) }
  let settings = PipelineTimelineSettings(frameCount: 3, framesPerSecond: 30, tracks: [
    .init(path: "/camera/y", interpolation: .easeOut, keyframes: [
      .init(frame: 0, value: .number(0.2)),
      .init(frame: 2, value: .number(0.8)),
    ]),
  ])
  let document = PipelineDocument(
    id: .init(rawValue: "timeline-state"), name: "Timeline state", mode: .generic,
    nodes: [
      PipelineNode(id: id("state"), kind: .stateInput, parameters: [
        "initialState": .string("{\"camera\":{\"x\":0.4,\"y\":0.2},\"live\":true}")
      ]),
      PipelineNode(id: id("timeline"), kind: .controlTimeline,
        parameters: settings.parameters),
      PipelineNode(id: id("output"), kind: .textOutput),
    ],
    connections: [
      .init(output: .init(nodeID: id("state"), port: "state"),
        input: .init(nodeID: id("timeline"), port: "value")),
      .init(output: .init(nodeID: id("timeline"), port: "value"),
        input: .init(nodeID: id("output"), port: "text")),
    ],
    primaryOutputNodeIDs: [id("output")])
  let engine = PixeltjePipelineEngine()
  #expect(await engine.validate(document).isValid)
  let result = try await engine.execute(document, packageRootsByID: [:],
    invocation: PipelineInvocation(values: [
      PipelineInvocation.loopCallIndexKey: .integer(1),
    ]))
  guard case .plainText(let text) = result else {
    Issue.record("Expected animated state text.")
    return
  }
  #expect(try PipelineStateJSON.read(text.text, key: "/camera/x") == .number(0.4))
  guard case .number(let animatedY) = try PipelineStateJSON.read(text.text, key: "/camera/y") else {
    Issue.record("Expected an eased numeric state field.")
    return
  }
  #expect(animatedY > 0.6 && animatedY < 0.62)
  #expect(try PipelineStateJSON.read(text.text, key: "/live") == .boolean(true))
}

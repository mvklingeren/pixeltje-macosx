import Foundation
import PixeltjePipelineDomain
import Testing

@Test func stateJSONPreservesObjectsAndScalarTypes() throws {
  let source = #"{"score":0,"active":true,"bee":{"name":"Bée 🐝"},"subjects":["poppy","sunflower"]}"#
  let canonical = try PipelineStateJSON.canonicalObject(source)
  #expect(try PipelineStateJSON.read(canonical, key: "score") == .integer(0))
  #expect(try PipelineStateJSON.read(canonical, key: "active") == .boolean(true))
  #expect(try PipelineStateJSON.read(canonical, key: "/bee/name") == .string("Bée 🐝"))
  #expect(try PipelineStateJSON.read(canonical, key: "/subjects/1") == .string("sunflower"))
  let bee = try PipelineStateJSON.text(PipelineStateJSON.read(canonical, key: "bee"))
  #expect(try PipelineStateJSON.read(bee, key: "name") == .string("Bée 🐝"))
  let updated = try PipelineStateJSON.setting(canonical, key: "score", to: .integer(1))
  #expect(try PipelineStateJSON.read(updated, key: "score") == .integer(1))
  #expect(try PipelineStateJSON.read(updated, key: "bee") == PipelineStateJSON.read(canonical, key: "bee"))
  #expect(try PipelineStateJSON.read(canonical, key: "score") == .integer(0))
}

@Test func stateJSONUsesExplicitPointerEscapesAndRejectsMissingPaths() throws {
  let source = #"{"a/b":{"~key":5},"a.b":7}"#
  #expect(try PipelineStateJSON.read(source, key: "/a~1b/~0key") == .integer(5))
  #expect(try PipelineStateJSON.read(source, key: "a.b") == .integer(7))
  #expect(throws: (any Error).self) { try PipelineStateJSON.read(source, key: "/a~2b") }
  #expect(throws: (any Error).self) { try PipelineStateJSON.setting(source, key: "/missing/path", to: .integer(1)) }
  #expect(throws: (any Error).self) { try PipelineStateJSON.setting(source, key: "", to: .array([])) }
}

@Test func stateJSONRejectsInvalidUnboundedAndNonfiniteValues() throws {
  for invalid in ["{", "[]", "null", #"{"score":NaN}"#,
    #"{"text":""# + String(repeating: "x", count: PipelineStateJSON.maximumBytes) + #""}"#,
    String(repeating: #"{"child":"#, count: 34) + "{}" + String(repeating: "}", count: 34)] {
    #expect(throws: (any Error).self) { try PipelineStateJSON.canonicalObject(invalid) }
  }
  #expect(throws: (any Error).self) {
    try PipelineStateJSON.setting(#"{"score":0}"#, key: "score", to: .number(.infinity))
  }
}

@Test func stateFeedbackLoopSettingsRoundTrip() throws {
  let node = PipelineNode(id: .init(rawValue: "loop"), kind: .init(rawValue: "control.loop"),
    parameters: ["feedback": .string("stateAndImage"), "autoPause": .boolean(true)])
  let document = PipelineDocument(id: .init(rawValue: "state-loop"), name: "State loop",
    mode: .generic, nodes: [node], connections: [])
  let decoded = try PipelineJSON.decode(PipelineJSON.encode(document))
  #expect(PipelineLoopSettings(node: decoded.nodes[0])?.feedback == .stateAndImage)
  #expect(PipelineLoopSettings(node: decoded.nodes[0])?.autoPause == true)
}

import Foundation
import PixeltjePipelineDomain
import Testing

@Test func assetCacheSlotsAreDynamicAndIndependentlyTyped() {
  let cacheKind = PipelineNodeKind(rawValue: "cache.assets")
  let sourceKind = PipelineNodeKind(rawValue: "test.audioSource")
  let sinkKind = PipelineNodeKind(rawValue: "test.imageSink")
  let registry = PipelineNodeRegistry([
    .init(kind: cacheKind, displayName: "Asset Cache", category: "Utilities",
      outputs: [.init(name: "assets", type: .assetBundle)],
      parameters: [.init(name: "slotCount", valueType: .integer,
        defaultValue: .integer(1))]),
    .init(kind: sourceKind, displayName: "Audio", category: "Test",
      outputs: [.init(name: "audio", type: .audio)]),
    .init(kind: sinkKind, displayName: "Image", category: "Test",
      inputs: [.init(name: "image", type: .image)], isTerminal: true),
  ])
  let cache = PipelineNode(id: .init(rawValue: "cache"), kind: cacheKind,
    parameters: ["slotCount": .integer(2)])
  let descriptor = PipelineGraphEditing.descriptor(for: cache, registry: registry)
  #expect(descriptor?.inputs.map(\.name) == ["asset0", "asset1"])
  #expect(descriptor?.outputs.map(\.name) == ["assets", "asset0", "asset1"])

  func link(_ source: String, _ sourcePort: String,
    _ target: String, _ targetPort: String) -> PipelineConnection {
    .init(output: .init(nodeID: .init(rawValue: source), port: sourcePort),
      input: .init(nodeID: .init(rawValue: target), port: targetPort))
  }
  let document = PipelineDocument(id: .init(rawValue: "asset-cache-type-check"),
    name: "Asset cache type check", mode: .generic,
    nodes: [PipelineNode(id: .init(rawValue: "source"), kind: sourceKind), cache,
      PipelineNode(id: .init(rawValue: "sink"), kind: sinkKind)],
    connections: [link("source", "audio", "cache", "asset0"),
      link("source", "audio", "cache", "asset1"),
      link("cache", "asset1", "sink", "image")],
    primaryOutputNodeIDs: [.init(rawValue: "sink")])
  let report = PipelineGraphValidator.validate(document, registry: registry)
  #expect(report.errors.contains { $0.code == .incompatiblePorts })
  var invalidCount = document
  invalidCount.nodes[1].parameters["slotCount"] = .integer(0)
  #expect(PipelineGraphValidator.validate(invalidCount, registry: registry)
    .errors.contains { $0.code == .invalidParameter })
}

@Test func assetCacheFingerprintTracksOnlyItsInputBranch() throws {
  func id(_ value: String) -> PipelineNodeID { .init(rawValue: value) }
  let sourceKind = PipelineNodeKind(rawValue: "test.imageSource")
  let sinkKind = PipelineNodeKind(rawValue: "test.imageSink")
  var document = PipelineDocument(id: .init(rawValue: "asset-cache-fingerprint"),
    name: "Asset cache fingerprint", mode: .generic,
    nodes: [
      PipelineNode(id: id("source"), kind: sourceKind,
        parameters: ["seed": .integer(1)]),
      PipelineNode(id: id("cache"), kind: .init(rawValue: "cache.assets"),
        parameters: ["keepBetweenRuns": .boolean(true)]),
      PipelineNode(id: id("sink"), kind: sinkKind),
      PipelineNode(id: id("loop"), kind: .init(rawValue: "control.loop"),
        parameters: ["autoPause": .boolean(false)]),
    ], connections: [
      .init(output: .init(nodeID: id("source"), port: "image"),
        input: .init(nodeID: id("cache"), port: "asset0")),
      .init(output: .init(nodeID: id("cache"), port: "asset0"),
        input: .init(nodeID: id("sink"), port: "image")),
    ])
  let initial = try PipelineJSON.assetCacheSHA256(document, nodeID: id("cache"))
  document.nodes[2].title = "Renamed output"
  document.nodes[3].parameters["autoPause"] = .boolean(true)
  #expect(try PipelineJSON.assetCacheSHA256(document, nodeID: id("cache")) == initial)
  document.nodes[0].parameters["seed"] = .integer(2)
  #expect(try PipelineJSON.assetCacheSHA256(document, nodeID: id("cache")) != initial)
}

import PixeltjePipelineDomain
import Testing

@Test func sceneSwitchPortsFollowSceneCountAndRejectInvalidInitialScene() {
  let kind = PipelineNodeKind(rawValue: "control.sceneSwitch")
  let registry = PipelineNodeRegistry([
    .init(kind: kind, displayName: "Scene Switch", category: "Control",
      outputs: [.init(name: "image", type: .image),
        .init(name: "activeScene", type: .integer)],
      parameters: [
        .init(name: "sceneCount", valueType: .integer,
          defaultValue: .integer(2)),
        .init(name: "initialScene", valueType: .integer,
          defaultValue: .integer(0)),
      ]),
  ])
  let node = PipelineNode(id: .init(rawValue: "switch"), kind: kind,
    parameters: ["sceneCount": .integer(3), "initialScene": .integer(2)])
  let descriptor = PipelineGraphEditing.descriptor(for: node, registry: registry)
  #expect(descriptor?.input(named: "scene2")?.type == .image)
  #expect(descriptor?.input(named: "request2")?.type == .integer)
  #expect(descriptor?.input(named: "scene3") == nil)

  var invalid = node
  invalid.parameters["initialScene"] = .integer(3)
  let document = PipelineDocument(id: .init(rawValue: "bad-switch"),
    name: "Bad switch", mode: .textToImage, nodes: [invalid],
    connections: [])
  #expect(PipelineGraphValidator.validate(document, registry: registry).errors
    .contains { $0.code == .invalidParameter && $0.nodeID == node.id })
}

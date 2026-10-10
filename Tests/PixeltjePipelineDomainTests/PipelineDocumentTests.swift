import Foundation
import PixeltjePipelineDomain
import Testing

private let sourceKind = PipelineNodeKind(rawValue: "test.source")
private let outputKind = PipelineNodeKind(rawValue: "test.output")

private var testRegistry: PipelineNodeRegistry {
  PipelineNodeRegistry([
    PipelineNodeDescriptor(
      kind: sourceKind,
      displayName: "Source",
      category: "Test",
      outputs: [.init(name: "image", type: .image)]),
    PipelineNodeDescriptor(
      kind: outputKind,
      displayName: "Output",
      category: "Test",
      inputs: [.init(name: "image", type: .image)],
      isTerminal: true),
  ])
}

private func testDocument() -> PipelineDocument {
  PipelineDocument(
    id: PipelineID(rawValue: "test-pipeline"),
    name: "Test Pipeline",
    mode: .textToImage,
    nodes: [
      PipelineNode(id: PipelineNodeID(rawValue: "source"), kind: sourceKind),
      PipelineNode(id: PipelineNodeID(rawValue: "output"), kind: outputKind),
    ],
    connections: [
      PipelineConnection(
        output: PipelinePortReference(
          nodeID: PipelineNodeID(rawValue: "source"), port: "image"),
        input: PipelinePortReference(
          nodeID: PipelineNodeID(rawValue: "output"), port: "image"))
    ],
    presentation: PipelinePresentation(
      nodePositions: [
        "source": PipelinePoint(x: 20, y: 40),
        "output": PipelinePoint(x: 280, y: 40),
      ]))
}

@Test func pipelineJSONRoundTripsAsPlainData() throws {
  let original = testDocument()
  let data = try PipelineJSON.encode(original)
  let decoded = try PipelineJSON.decode(data)

  #expect(decoded == original)
  let json = String(decoding: data, as: UTF8.self)
  #expect(json.contains("\"schemaVersion\" : 2"))
  #expect(json.contains("\"test-pipeline\""))
}

@Test func pipelineJSONMigratesLegacyMultilineStringNodes() throws {
  var legacy = testDocument()
  legacy.nodes[0].kind = PipelineNodeKind(rawValue: "primitive.string.multiline")
  legacy.nodes[0].parameters["value"] = .string("first line\nsecond line")

  let decoded = try PipelineJSON.decode(PipelineJSON.encode(legacy))

  #expect(decoded.nodes[0].kind == PipelineNodeKind(rawValue: "primitive.string"))
  #expect(decoded.nodes[0].parameters["value"] == .string("first line\nsecond line"))
  #expect(!String(decoding: try PipelineJSON.encode(decoded), as: UTF8.self)
    .contains("primitive.string.multiline"))
}

@Test func controlLoopNeedsBothVisibleLinksAndPreservesAcyclicDataGraph() throws {
  let output = PipelineNodeID(rawValue: "output")
  let loop = PipelineNodeID(rawValue: "loop")
  let start = PipelineNodeID(rawValue: "start")
  var registry = testRegistry
  registry.register(PipelineNodeDescriptor(
    kind: outputKind, displayName: "Output", category: "Test",
    inputs: [.init(name: "image", type: .image)],
    outputs: [.init(name: PipelineControlPorts.completed, type: .control)],
    isTerminal: true))
  registry.register(PipelineNodeDescriptor(
    kind: PipelineControlFlow.loopKind, displayName: "Loop", category: "Control",
    inputs: [.init(name: PipelineControlPorts.completed, type: .control,
      isRequired: false)],
    outputs: [.init(name: PipelineControlPorts.repeatPort, type: .control)],
    parameters: [
      .init(name: "maxCalls", valueType: .integer),
      .init(name: "seedStrategy", valueType: .string),
    ]))
  registry.register(PipelineNodeDescriptor(
    kind: PipelineControlFlow.startKind, displayName: "Start", category: "Control",
    inputs: [.init(name: PipelineControlPorts.again, type: .control,
      isRequired: false)]))
  var document = testDocument()
  document.nodes += [
    PipelineNode(id: loop, kind: PipelineControlFlow.loopKind,
      parameters: ["maxCalls": .integer(3), "seedStrategy": .string("fixed")]),
    PipelineNode(id: start, kind: PipelineControlFlow.startKind),
  ]
  let completed = PipelineConnection(
    output: .init(nodeID: output, port: PipelineControlPorts.completed),
    input: .init(nodeID: loop, port: PipelineControlPorts.completed))
  let repeatLink = PipelineConnection(
    output: .init(nodeID: loop, port: PipelineControlPorts.repeatPort),
    input: .init(nodeID: start, port: PipelineControlPorts.again))
  #expect(PipelineControlFlow.activeLoop(in: document, registry: registry) == nil)
  #expect(PipelineGraphEditing.connectionDecision(
    in: document, output: completed.output, input: completed.input,
    registry: registry).isAllowed)
  document.controlConnections = [completed]
  #expect(PipelineGraphValidator.validate(document, registry: registry).isValid)
  #expect(PipelineControlFlow.activeLoop(in: document, registry: registry) == nil)
  document.controlConnections.append(repeatLink)
  #expect(PipelineGraphValidator.validate(document, registry: registry).isValid)
  #expect(PipelineControlFlow.activeLoop(in: document, registry: registry)?.settings.maxCalls == 3)
  #expect(try PipelineGraphTopology.orderedNodeIDs(in: document).count == 4)
  let decoded = try PipelineJSON.decode(PipelineJSON.encode(document))
  #expect(decoded.controlConnections.count == 2)
  var disconnected = document
  disconnected.controlConnections.removeLast()
  #expect(try PipelineJSON.semanticSHA256(document)
    != PipelineJSON.semanticSHA256(disconnected))
  document.connections.append(repeatLink)
  #expect(!PipelineGraphValidator.validate(document, registry: registry).isValid)
}

@Test func finiteLoopAutoRepeatResetsCallIndexAndRejectsInfiniteRepeat() throws {
  let loopID = PipelineNodeID(rawValue: "loop")
  var node = PipelineNode(id: loopID, kind: PipelineControlFlow.loopKind,
    parameters: ["maxCalls": .integer(3), "autoRepeat": .boolean(true)])
  let settings = try #require(PipelineLoopSettings(node: node))
  #expect(settings.autoRepeat)
  #expect((1...7).map { settings.callIndex(forRunCall: $0) } == [0, 1, 2, 0, 1, 2, 0])
  #expect(settings.continues(afterRunCall: 3))

  node.parameters["autoRepeat"] = .boolean(false)
  let finite = try #require(PipelineLoopSettings(node: node))
  #expect(!finite.continues(afterRunCall: 3))
  node.parameters["maxCalls"] = .integer(-1)
  #expect(PipelineLoopSettings(node: node)?.autoRepeat == false)
  node.parameters["autoRepeat"] = .boolean(true)
  #expect(PipelineLoopSettings(node: node) == nil)
}

@Test func incrementSeedRequiresLoopToSeedAndSeedToOutput() throws {
  let seed = PipelineNodeID(rawValue: "seed")
  let source = PipelineNodeID(rawValue: "source")
  let output = PipelineNodeID(rawValue: "output")
  let loop = PipelineNodeID(rawValue: "loop")
  let start = PipelineNodeID(rawValue: "start")
  let registry = PipelineNodeRegistry([
    PipelineNodeDescriptor(kind: PipelineControlFlow.seedKind,
      displayName: "Seed", category: "Test",
      inputs: [.init(name: PipelineControlPorts.increment, type: .control,
        isRequired: false)], outputs: [.init(name: "seed", type: .seed)]),
    PipelineNodeDescriptor(kind: sourceKind, displayName: "Source", category: "Test",
      inputs: [.init(name: "seed", type: .seed)],
      outputs: [.init(name: "image", type: .image)]),
    PipelineNodeDescriptor(kind: outputKind, displayName: "Output", category: "Test",
      inputs: [.init(name: "image", type: .image)],
      outputs: [.init(name: PipelineControlPorts.completed, type: .control)],
      isTerminal: true),
    PipelineNodeDescriptor(kind: PipelineControlFlow.loopKind,
      displayName: "Loop", category: "Test",
      inputs: [.init(name: PipelineControlPorts.completed, type: .control,
        isRequired: false)],
      outputs: [
        .init(name: PipelineControlPorts.repeatPort, type: .control),
        .init(name: PipelineControlPorts.incrementSeed, type: .control),
      ],
      parameters: [.init(name: "seedStrategy", valueType: .string)]),
    PipelineNodeDescriptor(kind: PipelineControlFlow.startKind,
      displayName: "Start", category: "Test",
      inputs: [.init(name: PipelineControlPorts.again, type: .control,
        isRequired: false)]),
  ])
  var document = PipelineDocument(
    id: .init(rawValue: "seeded-loop"), name: "Seeded Loop", mode: .textToImage,
    nodes: [
      PipelineNode(id: seed, kind: PipelineControlFlow.seedKind),
      PipelineNode(id: source, kind: sourceKind),
      PipelineNode(id: output, kind: outputKind),
      PipelineNode(id: loop, kind: PipelineControlFlow.loopKind,
        parameters: ["seedStrategy": .string("increment")]),
      PipelineNode(id: start, kind: PipelineControlFlow.startKind),
    ],
    connections: [
      .init(output: .init(nodeID: seed, port: "seed"),
        input: .init(nodeID: source, port: "seed")),
      .init(output: .init(nodeID: source, port: "image"),
        input: .init(nodeID: output, port: "image")),
    ],
    controlConnections: [
      .init(output: .init(nodeID: output, port: PipelineControlPorts.completed),
        input: .init(nodeID: loop, port: PipelineControlPorts.completed)),
      .init(output: .init(nodeID: loop, port: PipelineControlPorts.repeatPort),
        input: .init(nodeID: start, port: PipelineControlPorts.again)),
    ],
    primaryOutputNodeIDs: [output])

  var incompleteLoop = document
  incompleteLoop.controlConnections.removeAll()
  #expect(!PipelineGraphValidator.validate(incompleteLoop, registry: registry).isValid)
  #expect(!PipelineGraphValidator.validate(document, registry: registry).isValid)
  let increment = PipelineConnection(
    output: .init(nodeID: loop, port: PipelineControlPorts.incrementSeed),
    input: .init(nodeID: seed, port: PipelineControlPorts.increment))
  #expect(PipelineGraphEditing.connectionDecision(
    in: document, output: increment.output, input: increment.input,
    registry: registry).isAllowed)
  document.controlConnections.append(increment)
  #expect(PipelineGraphValidator.validate(document, registry: registry).isValid)
  let active = try #require(PipelineControlFlow.activeLoop(in: document, registry: registry))
  #expect(PipelineControlFlow.incrementSeedNodeID(in: document, loop: active) == seed)
  document.connections.removeFirst()
  #expect(PipelineControlFlow.incrementSeedNodeID(in: document, loop: active) == nil)
  #expect(!PipelineGraphValidator.validate(document, registry: registry).isValid)
}

@Test func schemaOneLinkedResourcesMigrateWithoutRelinking() throws {
  let legacy = #"""
    {
      "schemaVersion": 1,
      "id": "legacy",
      "name": "Legacy",
      "mode": "textToImage",
      "requirements": {"minimumEngineVersion": 1, "familyABIs": []},
      "nodes": [{
        "id": "source",
        "kind": "test.source",
        "parameters": {},
        "resources": {
          "model": {
            "kind": "coreAIModel",
            "packageID": "example.model",
            "packageVersion": "1",
            "contentHash": "abc",
            "componentRole": "denoiser"
          }
        }
      }],
      "connections": [],
      "exposedParameters": []
    }
    """#

  let decoded = try PipelineJSON.decode(Data(legacy.utf8))

  #expect(decoded.schemaVersion == PipelineDocument.currentSchemaVersion)
  #expect(decoded.nodes[0].resources["model"]?.linkedReference?.packageID == "example.model")
  #expect(decoded.nodes[0].executionState == .enabled)
}

@Test func unresolvedResourcesAreReportedOnlyDuringValidation() {
  let requirement = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "model.safetensors",
    sourceFormat: "safetensors")
  let document = PipelineDocument(
    id: PipelineID(rawValue: "unresolved"),
    name: "Unresolved",
    mode: .generic,
    nodes: [
      PipelineNode(
        id: PipelineNodeID(rawValue: "source"),
        kind: sourceKind,
        resources: ["model": .unresolved(requirement)])
    ],
    connections: [])

  let report = PipelineGraphValidator.validate(document, registry: testRegistry)

  #expect(report.errors.contains { $0.code == .unresolvedResource })
}

@Test func resourceGuidanceMatchesExactKnownNamesOnly() throws {
  let catalog = PipelineResourceGuidanceCatalog.builtIn
  let exact = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "./diffusion_models/flux-2-klein-4b.safetensors",
    sourceFormat: "SAFETENSORS")
  let windowsPath = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: #"diffusion_models\flux-2-klein-4b.safetensors"#,
    sourceFormat: "safetensors")
  let base = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "diffusion_models/flux-2-klein-base-4b.safetensors",
    sourceFormat: "safetensors")
  let unrelated = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "flux-2-klein-9b.safetensors",
    sourceFormat: "safetensors")
  let wrongRole = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "textEncoder",
    sourceName: "flux-2-klein-4b.safetensors",
    sourceFormat: "safetensors")
  let wrongFormat = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "flux-2-klein-4b.safetensors",
    sourceFormat: "gguf")
  let wrongKind = PipelineResourceRequirement(
    kind: .data,
    componentRole: "denoiser",
    sourceName: "flux-2-klein-4b.safetensors",
    sourceFormat: "safetensors")

  #expect(catalog.guide(for: exact)?.id == "public.coreai.flux2-klein-4b")
  #expect(catalog.guide(for: windowsPath)?.id == "public.coreai.flux2-klein-4b")
  #expect(catalog.guide(for: base)?.id == "public.coreai.flux2-klein-4b")
  #expect(catalog.guide(for: unrelated) == nil)
  #expect(catalog.guide(for: wrongRole) == nil)
  #expect(catalog.guide(for: wrongFormat) == nil)
  #expect(catalog.guide(for: wrongKind) == nil)
}

@Test func resourceGuidanceReturnsNoPreferredAmbiguousMatch() throws {
  let first = try PipelineResourceGuidanceEntry(
    id: "first",
    displayName: "First",
    componentRoles: ["denoiser"],
    sourceNames: ["large-model.safetensors"],
    sourceFormats: ["safetensors"],
    acquisitionURL: URL(string: "https://example.com/first")!,
    downloadMarkdown: "First guide")
  let second = try PipelineResourceGuidanceEntry(
    id: "second",
    displayName: "Second",
    componentRoles: ["denoiser"],
    sourceNames: ["large-model.safetensors"],
    sourceFormats: ["safetensors"],
    acquisitionURL: URL(string: "https://example.com/second")!,
    downloadMarkdown: "Second guide")
  let requirement = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "large-model.safetensors",
    sourceFormat: "safetensors")

  #expect(PipelineResourceGuidanceCatalog(entries: [first, second]).guide(for: requirement) == nil)
}

@Test func resourceGuidanceRejectsNonHTTPSURLs() {
  #expect(throws: PipelineResourceGuidanceError.self) {
    try PipelineResourceGuidanceEntry(
      id: "insecure",
      displayName: "Insecure",
      componentRoles: ["denoiser"],
      sourceNames: ["model.safetensors"],
      sourceFormats: ["safetensors"],
      acquisitionURL: URL(string: "http://example.com/model")!,
      downloadMarkdown: "Insecure guide")
  }
}

@Test func integerAndFloatingPointParametersRoundTripWithoutChangingType() throws {
  let values: [String: PipelineValue] = [
    "steps": .integer(8),
    "guidance": .number(1),
  ]
  let data = try JSONEncoder().encode(values)
  let decoded = try JSONDecoder().decode([String: PipelineValue].self, from: data)

  #expect(decoded == values)
}

@Test func editorLayoutDoesNotChangeSemanticHash() throws {
  let original = testDocument()
  var moved = original
  moved.presentation = PipelinePresentation(
    nodePositions: [
      "source": PipelinePoint(x: 900, y: -200),
      "output": PipelinePoint(x: 100, y: 800),
    ])

  #expect(try PipelineJSON.semanticSHA256(original) == PipelineJSON.semanticSHA256(moved))
}

@Test func connectionEditorIdentityDoesNotChangeSemanticHash() throws {
  let original = testDocument()
  var renamed = original
  renamed.connections[0].id = PipelineConnectionID(rawValue: "imported-link-42")

  #expect(try PipelineJSON.semanticSHA256(original) == PipelineJSON.semanticSHA256(renamed))
}

@Test func validatorAcceptsAConnectedTypedGraph() {
  let report = PipelineGraphValidator.validate(testDocument(), registry: testRegistry)

  #expect(report.isValid)
  #expect(report.diagnostics.isEmpty)
}

@Test func validatorDoesNotWarnForAnnotationOnlyNodes() {
  let noteKind = PipelineNodeKind(rawValue: "edit.markdownNote")
  var registry = testRegistry
  registry.register(
    PipelineNodeDescriptor(
      kind: noteKind,
      displayName: "Markdown Note",
      category: "Documentation",
      parameters: [
        .init(name: "text", valueType: .string, defaultValue: .string("A workflow note"))
      ]))
  var document = testDocument()
  document.nodes.append(
    PipelineNode(
      id: PipelineNodeID(rawValue: "note"),
      kind: noteKind,
      parameters: ["text": .string("A workflow note")]))
  document.nodes.append(
    PipelineNode(id: PipelineNodeID(rawValue: "unused-source"), kind: sourceKind))

  let report = PipelineGraphValidator.validate(document, registry: registry)

  #expect(report.isValid)
  #expect(report.warnings.count == 1)
  #expect(report.warnings.first?.code == .disconnectedNode)
  #expect(report.warnings.first?.nodeID == PipelineNodeID(rawValue: "unused-source"))
}

@Test func validatorRejectsCyclesAndMissingRequiredInputs() {
  let transformKind = PipelineNodeKind(rawValue: "test.transform")
  let registry = PipelineNodeRegistry([
    PipelineNodeDescriptor(
      kind: transformKind,
      displayName: "Transform",
      category: "Test",
      inputs: [.init(name: "image", type: .image)],
      outputs: [.init(name: "image", type: .image)]),
    PipelineNodeDescriptor(
      kind: outputKind,
      displayName: "Output",
      category: "Test",
      inputs: [.init(name: "image", type: .image)],
      isTerminal: true),
  ])
  let first = PipelineNodeID(rawValue: "first")
  let second = PipelineNodeID(rawValue: "second")
  let output = PipelineNodeID(rawValue: "output")
  let document = PipelineDocument(
    id: PipelineID(rawValue: "cycle"),
    name: "Cycle",
    mode: .textToImage,
    nodes: [
      PipelineNode(id: first, kind: transformKind),
      PipelineNode(id: second, kind: transformKind),
      PipelineNode(id: output, kind: outputKind),
    ],
    connections: [
      PipelineConnection(
        output: .init(nodeID: first, port: "image"),
        input: .init(nodeID: second, port: "image")),
      PipelineConnection(
        output: .init(nodeID: second, port: "image"),
        input: .init(nodeID: first, port: "image")),
      PipelineConnection(
        output: .init(nodeID: second, port: "image"),
        input: .init(nodeID: output, port: "image")),
    ])

  let report = PipelineGraphValidator.validate(document, registry: registry)

  #expect(!report.isValid)
  #expect(report.errors.contains { $0.code == .cycle })
}

@Test func validatorAllowsAWorkflowWithoutAConnectedOutput() {
  let source = PipelineNodeID(rawValue: "source")
  let sink = PipelineNodeID(rawValue: "sink")
  let document = PipelineDocument(
    id: PipelineID(rawValue: "no-outcome"), name: "No outcome", mode: .generic,
    nodes: [
      PipelineNode(id: source, kind: sourceKind),
      PipelineNode(id: sink, kind: outputKind),
    ], connections: [], primaryOutputNodeIDs: [sink])

  let report = PipelineGraphValidator.validate(document, registry: testRegistry)
  #expect(report.isValid)
  #expect(report.warnings.contains { $0.code == .missingOutput })
  #expect(PipelineGraphOutputs.selectedOutputNode(in: document, registry: testRegistry) == nil)
}

@Test func connectionEditingAcceptsOnlyCompatibleUnoccupiedInputs() {
  let source = PipelineNodeID(rawValue: "source")
  let secondSource = PipelineNodeID(rawValue: "second-source")
  let output = PipelineNodeID(rawValue: "output")
  var document = testDocument()
  document.nodes.insert(PipelineNode(id: secondSource, kind: sourceKind), at: 1)

  var unconnected = document
  unconnected.connections = []
  let allowed = PipelineGraphEditing.connectionDecision(
    in: unconnected,
    output: .init(nodeID: secondSource, port: "image"),
    input: .init(nodeID: output, port: "image"),
    registry: testRegistry)

  let compatible = PipelineGraphEditing.connectionDecision(
    in: document,
    output: .init(nodeID: secondSource, port: "image"),
    input: .init(nodeID: output, port: "image"),
    registry: testRegistry)
  let duplicate = PipelineGraphEditing.connectionDecision(
    in: document,
    output: .init(nodeID: source, port: "image"),
    input: .init(nodeID: output, port: "image"),
    registry: testRegistry)

  #expect(allowed.isAllowed)
  #expect(!compatible.isAllowed)
  #expect(compatible.rejection == .occupiedInput)
  #expect(duplicate.rejection == .duplicate)
}

@Test func connectionEditingRejectsIncompatibleSelfAndCyclicEdges() {
  let imageSource = PipelineNodeID(rawValue: "image-source")
  let textSource = PipelineNodeID(rawValue: "text-source")
  let first = PipelineNodeID(rawValue: "first")
  let second = PipelineNodeID(rawValue: "second")
  let imageSourceKind = PipelineNodeKind(rawValue: "test.image-source")
  let textSourceKind = PipelineNodeKind(rawValue: "test.text-source")
  let transformKind = PipelineNodeKind(rawValue: "test.transform")
  let registry = PipelineNodeRegistry([
    PipelineNodeDescriptor(
      kind: imageSourceKind, displayName: "Image", category: "Test",
      outputs: [.init(name: "value", type: .image)]),
    PipelineNodeDescriptor(
      kind: textSourceKind, displayName: "Text", category: "Test",
      outputs: [.init(name: "value", type: .string)]),
    PipelineNodeDescriptor(
      kind: transformKind, displayName: "Transform", category: "Test",
      inputs: [.init(name: "image", type: .image, allowsMultipleConnections: true)],
      outputs: [.init(name: "image", type: .image)]),
  ])
  let document = PipelineDocument(
    id: PipelineID(rawValue: "editing"),
    name: "Editing",
    mode: .generic,
    nodes: [
      PipelineNode(id: imageSource, kind: imageSourceKind),
      PipelineNode(id: textSource, kind: textSourceKind),
      PipelineNode(id: first, kind: transformKind),
      PipelineNode(id: second, kind: transformKind),
    ],
    connections: [
      PipelineConnection(
        output: .init(nodeID: imageSource, port: "value"),
        input: .init(nodeID: first, port: "image")),
      PipelineConnection(
        output: .init(nodeID: first, port: "image"),
        input: .init(nodeID: second, port: "image")),
    ])

  let incompatible = PipelineGraphEditing.connectionDecision(
    in: document,
    output: .init(nodeID: textSource, port: "value"),
    input: .init(nodeID: first, port: "image"),
    registry: registry)
  let selfEdge = PipelineGraphEditing.connectionDecision(
    in: document,
    output: .init(nodeID: first, port: "image"),
    input: .init(nodeID: first, port: "image"),
    registry: registry)
  let cycle = PipelineGraphEditing.connectionDecision(
    in: document,
    output: .init(nodeID: second, port: "image"),
    input: .init(nodeID: first, port: "image"),
    registry: registry)

  #expect(incompatible.rejection == .incompatibleTypes)
  #expect(selfEdge.rejection == .sameNode)
  #expect(cycle.rejection == .cycle)
}

@Test func connectionEditingRespectsExistingPolymorphicPortBindings() {
  let imageKind = PipelineNodeKind(rawValue: "test.image")
  let stringKind = PipelineNodeKind(rawValue: "test.string")
  let switchKind = PipelineNodeKind(rawValue: "test.switch")
  let image1 = PipelineNodeID(rawValue: "image-1")
  let image2 = PipelineNodeID(rawValue: "image-2")
  let string = PipelineNodeID(rawValue: "string")
  let conditional = PipelineNodeID(rawValue: "switch")
  let registry = PipelineNodeRegistry([
    PipelineNodeDescriptor(
      kind: imageKind, displayName: "Image", category: "Test",
      outputs: [.init(name: "value", type: .image)]),
    PipelineNodeDescriptor(
      kind: stringKind, displayName: "String", category: "Test",
      outputs: [.init(name: "value", type: .string)]),
    PipelineNodeDescriptor(
      kind: switchKind, displayName: "Switch", category: "Test",
      inputs: [
        .init(name: "false", type: .any, isRequired: false, typeVariable: "value"),
        .init(name: "true", type: .any, isRequired: false, typeVariable: "value"),
      ],
      outputs: [.init(name: "value", type: .any, typeVariable: "value")]),
  ])
  let document = PipelineDocument(
    id: PipelineID(rawValue: "polymorphic-editing"),
    name: "Polymorphic Editing",
    mode: .generic,
    nodes: [
      PipelineNode(id: image1, kind: imageKind),
      PipelineNode(id: image2, kind: imageKind),
      PipelineNode(id: string, kind: stringKind),
      PipelineNode(id: conditional, kind: switchKind),
    ],
    connections: [
      PipelineConnection(
        output: .init(nodeID: image1, port: "value"),
        input: .init(nodeID: conditional, port: "false"))
    ])

  let matching = PipelineGraphEditing.connectionDecision(
    in: document,
    output: .init(nodeID: image2, port: "value"),
    input: .init(nodeID: conditional, port: "true"),
    registry: registry)
  let conflicting = PipelineGraphEditing.connectionDecision(
    in: document,
    output: .init(nodeID: string, port: "value"),
    input: .init(nodeID: conditional, port: "true"),
    registry: registry)

  #expect(matching.isAllowed)
  #expect(conflicting.rejection == .incompatibleTypes)
}

@Test func resourceGuidanceCoversHiDreamO1AndQwenImage() throws {
  let catalog = PipelineResourceGuidanceCatalog.builtIn
  let hiDreamO1 = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "checkpoints/hidream_o1_image_bf16.safetensors",
    sourceFormat: "safetensors")
  let hiDreamO1Dev = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "hidream_o1_image_dev_fp8_scaled.safetensors",
    sourceFormat: "safetensors")
  let qwenImage = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "diffusion_models/qwen_image_fp8_e4m3fn.safetensors",
    sourceFormat: "safetensors")
  let qwenImage21 = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "denoiser",
    sourceName: "diffusion_models/qwen_image_2.1_int8_convrot.safetensors",
    sourceFormat: "safetensors")
  let qwenTextEncoder = PipelineResourceRequirement(
    kind: .coreAIModel,
    componentRole: "textEncoder",
    sourceName: "text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
    sourceFormat: "safetensors")

  #expect(catalog.guide(for: hiDreamO1)?.id == "public.hidream-o1-image")
  #expect(catalog.guide(for: hiDreamO1Dev)?.id == "public.hidream-o1-image")
  #expect(catalog.guide(for: qwenImage)?.id == "public.qwen-image")
  #expect(catalog.guide(for: qwenImage21)?.id == "public.qwen-image-2-1")
  #expect(catalog.guide(for: qwenTextEncoder) == nil)
  #expect(
    catalog.guides(for: [qwenImage, hiDreamO1]).map(\.id)
      == ["public.hidream-o1-image", "public.qwen-image"])

  let markdown = try #require(catalog.guide(for: hiDreamO1)?.markdownDescription)
  #expect(markdown.contains("<!-- pixeltje-resource-guide:public.hidream-o1-image -->"))
  #expect(markdown.contains("https://huggingface.co/Comfy-Org/HiDream-O1-Image"))
  #expect(markdown.contains("never downloads, converts, or hashes"))
}

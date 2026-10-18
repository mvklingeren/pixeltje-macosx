import Foundation

public enum PipelineDiagnosticSeverity: String, Codable, Sendable {
  case warning
  case error
}

public enum PipelineDiagnosticCode: String, Codable, Sendable {
  case unsupportedSchema
  case unsupportedEngine
  case invalidIdentity
  case duplicateNode
  case unknownNodeKind
  case unsupportedNodeImplementation
  case missingNode
  case missingPort
  case incompatiblePorts
  case duplicateConnection
  case missingInput
  case unknownParameter
  case missingParameter
  case invalidParameter
  case missingResource
  case invalidResource
  case unresolvedResource
  case invalidExposedParameter
  case missingOutput
  case multipleOutputs
  case invalidOutput
  case cycle
  case disconnectedNode
  case stalePresentation
  case invalidControlFlow
  case invalidShader
  case shaderNotChecked
}

public struct PipelineDiagnostic: Codable, Equatable, Identifiable, Sendable {
  public var severity: PipelineDiagnosticSeverity
  public var code: PipelineDiagnosticCode
  public var message: String
  public var nodeID: PipelineNodeID?
  public var connectionIndex: Int?

  public var id: String {
    "\(severity.rawValue):\(code.rawValue):\(nodeID?.rawValue ?? "-"):\(connectionIndex ?? -1):\(message)"
  }

  public init(
    severity: PipelineDiagnosticSeverity,
    code: PipelineDiagnosticCode,
    message: String,
    nodeID: PipelineNodeID? = nil,
    connectionIndex: Int? = nil
  ) {
    self.severity = severity
    self.code = code
    self.message = message
    self.nodeID = nodeID
    self.connectionIndex = connectionIndex
  }
}

public struct PipelineValidationReport: Codable, Equatable, Sendable {
  public var diagnostics: [PipelineDiagnostic]

  public init(diagnostics: [PipelineDiagnostic] = []) {
    self.diagnostics = diagnostics
  }

  public var isValid: Bool {
    !diagnostics.contains { $0.severity == .error }
  }

  public var errors: [PipelineDiagnostic] {
    diagnostics.filter { $0.severity == .error }
  }

  public var warnings: [PipelineDiagnostic] {
    diagnostics.filter { $0.severity == .warning }
  }
}

public enum PipelineGraphTopologyError: Error, Equatable, Sendable {
  case cycle
}

public enum PipelineGraphTopology {
  /// Stable topological ordering for deterministic planning and diagnostics.
  public static func orderedNodeIDs(in document: PipelineDocument) throws -> [PipelineNodeID] {
    let nodeIDs = Set(document.nodes.map(\.id))
    var indegree = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, 0) })
    var outgoing: [PipelineNodeID: Set<PipelineNodeID>] = [:]
    for connection in document.connections {
      let source = connection.output.nodeID
      let destination = connection.input.nodeID
      guard source != destination, nodeIDs.contains(source), nodeIDs.contains(destination) else {
        if source == destination { throw PipelineGraphTopologyError.cycle }
        continue
      }
      if outgoing[source, default: []].insert(destination).inserted {
        indegree[destination, default: 0] += 1
      }
    }

    var ready = indegree.filter { $0.value == 0 }.map(\.key)
      .sorted { $0.rawValue < $1.rawValue }
    var result: [PipelineNodeID] = []
    while let nodeID = ready.first {
      ready.removeFirst()
      result.append(nodeID)
      for destination in (outgoing[nodeID] ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
        indegree[destination, default: 0] -= 1
        if indegree[destination] == 0 {
          ready.append(destination)
          ready.sort { $0.rawValue < $1.rawValue }
        }
      }
    }
    guard result.count == nodeIDs.count else { throw PipelineGraphTopologyError.cycle }
    return result
  }
}

public enum PipelineGraphOutputs {
  /// An output sink contributes a result only when it has an incoming edge.
  /// A zero-input terminal can produce a result on its own.
  public static func connectedTerminalNodes(
    in document: PipelineDocument,
    registry: PipelineNodeRegistry
  ) -> [PipelineNode] {
    let connectedInputs = Set(document.connections.map(\.input.nodeID))
    return document.nodes.filter { node in
      guard node.executionState == .enabled,
        let descriptor = registry.descriptor(for: node.kind), descriptor.isTerminal
      else { return false }
      return descriptor.inputs.isEmpty || connectedInputs.contains(node.id)
    }
  }

  public static func selectedOutputNode(
    in document: PipelineDocument,
    registry: PipelineNodeRegistry
  ) -> PipelineNode? {
    let terminals = connectedTerminalNodes(in: document, registry: registry)
    if let selected = document.primaryOutputNodeIDs, !selected.isEmpty {
      return selected.lazy.compactMap { id in
        terminals.first { $0.id == id }
      }.first
    }
    return terminals.first
  }
}

public enum PipelineGraphValidator {
  public static func validate(
    _ document: PipelineDocument,
    registry: PipelineNodeRegistry,
    engineVersion: Int = 1
  ) -> PipelineValidationReport {
    var diagnostics: [PipelineDiagnostic] = []
    func add(
      _ severity: PipelineDiagnosticSeverity,
      _ code: PipelineDiagnosticCode,
      _ message: String,
      nodeID: PipelineNodeID? = nil,
      connectionIndex: Int? = nil
    ) {
      diagnostics.append(
        PipelineDiagnostic(
          severity: severity,
          code: code,
          message: message,
          nodeID: nodeID,
          connectionIndex: connectionIndex))
    }

    if document.schemaVersion != PipelineDocument.currentSchemaVersion {
      add(
        .error,
        .unsupportedSchema,
        "Pipeline schema \(document.schemaVersion) is not supported; this engine supports schema \(PipelineDocument.currentSchemaVersion).")
    }
    if document.requirements.minimumEngineVersion > engineVersion {
      add(
        .error,
        .unsupportedEngine,
        "This pipeline requires engine version \(document.requirements.minimumEngineVersion), but version \(engineVersion) is installed.")
    }
    if document.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      add(.error, .invalidIdentity, "A pipeline requires a non-empty ID and name.")
    }

    var nodesByID: [PipelineNodeID: PipelineNode] = [:]
    for node in document.nodes {
      if node.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        add(.error, .invalidIdentity, "A node has an empty ID.", nodeID: node.id)
      }
      if nodesByID.updateValue(node, forKey: node.id) != nil {
        add(
          .error, .duplicateNode, "Node ID \(node.id.rawValue) is used more than once.",
          nodeID: node.id)
      }
      guard let descriptor = descriptor(for: node, registry: registry) else {
        add(
          .error, .unknownNodeKind, "Node kind \(node.kind.rawValue) is not installed.",
          nodeID: node.id)
        continue
      }
      if registry.descriptor(for: node.kind) == nil, node.executionState == .enabled {
        add(
          .error, .unsupportedNodeImplementation,
          "Node kind \(node.kind.rawValue) has an imported interface but no installed Swift executor.",
          nodeID: node.id)
      }
      validate(node, descriptor: descriptor, add: add)
      if node.kind.rawValue == "cache.assets" {
        let slotCount: Int64 = if case .integer(let value)? = node.parameters["slotCount"] {
          value
        } else {
          1
        }
        if !(1...16).contains(slotCount) {
          add(.error, .invalidParameter, "Asset Cache needs 1–16 slots.",
            nodeID: node.id)
        }
      }
      if node.kind.rawValue == "control.sceneSwitch" {
        let count: Int64 = if case .integer(let value)? = node.parameters["sceneCount"] {
          value
        } else { 2 }
        let initial: Int64 = if case .integer(let value)? = node.parameters["initialScene"] {
          value
        } else { 0 }
        if !(2...8).contains(count) || !(0..<count).contains(initial) {
          add(.error, .invalidParameter,
            "Scene Switch needs 2–8 scenes and an initial scene in that range.",
            nodeID: node.id)
        }
      }
    }

    var incomingConnections: [PipelinePortReference: Int] = [:]
    var structurallyValidConnections: [PipelineConnection] = []
    var typeResolver = PipelinePortTypeResolver()
    for (index, connection) in document.connections.enumerated() {
      guard let outputNode = nodesByID[connection.output.nodeID] else {
        add(
          .error, .missingNode,
          "Connection output refers to missing node \(connection.output.nodeID.rawValue).",
          connectionIndex: index)
        continue
      }
      guard let inputNode = nodesByID[connection.input.nodeID] else {
        add(
          .error, .missingNode,
          "Connection input refers to missing node \(connection.input.nodeID.rawValue).",
          connectionIndex: index)
        continue
      }
      guard let outputDescriptor = descriptor(for: outputNode, registry: registry),
        let outputPort = outputDescriptor.output(named: connection.output.port)
      else {
        add(
          .error, .missingPort,
          "Node \(outputNode.id.rawValue) has no output named \(connection.output.port).",
          nodeID: outputNode.id, connectionIndex: index)
        continue
      }
      guard let inputDescriptor = descriptor(for: inputNode, registry: registry),
        let inputPort = inputDescriptor.input(named: connection.input.port)
      else {
        add(
          .error, .missingPort,
          "Node \(inputNode.id.rawValue) has no input named \(connection.input.port).",
          nodeID: inputNode.id, connectionIndex: index)
        continue
      }
      if inputNode.kind.rawValue == "cache.assets",
        outputPort.type != .image && outputPort.type != .audio
          && outputPort.type != .any {
        add(.error, .incompatiblePorts,
          "Asset Cache accepts image or audio values.",
          nodeID: inputNode.id, connectionIndex: index)
        continue
      }
      if outputPort.type == .control || inputPort.type == .control {
        add(.error, .invalidControlFlow,
          "Control links belong in controlConnections, not data connections.",
          connectionIndex: index)
        continue
      }
      let count = incomingConnections[connection.input, default: 0] + 1
      if count > 1 && !inputPort.allowsMultipleConnections {
        add(
          .error, .duplicateConnection,
          "Input \(connection.input.port) accepts only one connection.",
          nodeID: inputNode.id, connectionIndex: index)
        continue
      }
      let outputTerm = PipelinePortTypeTerm(
        type: outputPort.type,
        variable: outputPort.typeVariable.map {
          PipelinePortTypeVariable(nodeID: outputNode.id, name: $0)
        })
      let inputTerm = PipelinePortTypeTerm(
        type: inputPort.type,
        variable: inputPort.typeVariable.map {
          PipelinePortTypeVariable(nodeID: inputNode.id, name: $0)
        })
      var candidateTypeResolver = typeResolver
      if !candidateTypeResolver.connect(outputTerm, inputTerm) {
        let message = if outputPort.typeVariable != nil || inputPort.typeVariable != nil {
          "Cannot connect \(outputPort.type.rawValue) to \(inputPort.type.rawValue); polymorphic ports on one node must resolve to one concrete type."
        } else {
          "Cannot connect \(outputPort.type.rawValue) to \(inputPort.type.rawValue)."
        }
        add(
          .error, .incompatiblePorts,
          message,
          nodeID: inputNode.id, connectionIndex: index)
        continue
      }
      typeResolver = candidateTypeResolver
      incomingConnections[connection.input] = count
      structurallyValidConnections.append(connection)
    }

    for preview in document.nodes where preview.kind.rawValue == "output.videoPreview"
      && preview.executionState == .enabled {
      let hasVideo = incomingConnections[.init(nodeID: preview.id, port: "video")] != nil
      let hasImage = incomingConnections[.init(nodeID: preview.id, port: "image")] != nil
      if !hasVideo && !hasImage {
        add(.error, .missingInput,
          "Video Preview needs a Video or Image connection.", nodeID: preview.id)
      } else if hasVideo && hasImage {
        add(.error, .duplicateConnection,
          "Video Preview accepts either Video or Image, not both.", nodeID: preview.id)
      }
    }

    for loop in document.nodes where loop.kind == PipelineControlFlow.loopKind
      && loop.executionState == .enabled && PipelineLoopSettings(node: loop) == nil {
      add(.error, .invalidControlFlow,
        "Loop parameters must specify 1–10,000 calls or Infinite, a 0–60,000 ms delay, a 0–240 Hz limit, Boolean Auto repeat and Auto pause settings, and supported seed and feedback options. Auto repeat requires finite Max calls.",
        nodeID: loop.id)
    }
    for timeline in document.nodes where timeline.kind == PipelineControlFlow.timelineKind
      && timeline.executionState == .enabled
      && PipelineTimelineSettings(node: timeline) == nil {
      add(.error, .invalidControlFlow,
        "Timeline needs 1–3,600 frames, 1–120 fps, and ordered, valid keyframes starting at frame zero.",
        nodeID: timeline.id)
    }
    let controlEdges = document.controlConnections
    if controlEdges.count > 3 {
      add(.error, .invalidControlFlow,
        "A workflow supports one output → Loop or Timeline → Start path and an optional Loop → Seed link.")
    }
    var controlInputs: Set<PipelinePortReference> = []
    for edge in controlEdges {
      if !PipelineControlFlow.isAllowedControlEdge(
        output: edge.output, input: edge.input,
        in: document, registry: registry) {
        add(.error, .invalidControlFlow,
          "Control links must connect the selected output to Loop or Timeline, then Start, or Loop to Seed.")
      }
      if !controlInputs.insert(edge.input).inserted {
        add(.error, .invalidControlFlow,
          "A control input accepts only one link.")
      }
    }
    if controlEdges.count == 1 {
      add(.warning, .invalidControlFlow,
        "Playback is inactive until the output → Loop or Timeline → Start path is complete.")
    } else if controlEdges.count >= 2,
      PipelineControlFlow.activeLoop(in: document, registry: registry) == nil
        && PipelineControlFlow.activeTimeline(in: document, registry: registry) == nil {
      add(.error, .invalidControlFlow,
        "The output → Loop or Timeline → Start control path is incomplete or ambiguous.")
    }
    if PipelineControlFlow.activeTimeline(in: document, registry: registry) != nil,
      controlEdges.count != 2 {
      add(.error, .invalidControlFlow,
        "Timeline playback uses only output → Timeline → Start control links.")
    }
    let selectedOutputID = PipelineGraphOutputs.selectedOutputNode(
      in: document, registry: registry)?.id
    for loop in document.nodes where loop.kind == PipelineControlFlow.loopKind
      && loop.executionState == .enabled
      && PipelineLoopSettings(node: loop)?.seedStrategy == .increment {
      guard let selectedOutputID,
        PipelineControlFlow.incrementSeedNodeID(
          in: document, loopNodeID: loop.id, outputNodeID: selectedOutputID) != nil
      else {
        add(.error, .invalidControlFlow,
          "Increment seed needs Loop → Seed and a Seed output connected to the selected result.",
          nodeID: loop.id)
        continue
      }
    }

    let disconnectedTerminals = Set(document.nodes.compactMap { node -> PipelineNodeID? in
      guard node.executionState == .enabled,
        let descriptor = descriptor(for: node, registry: registry), descriptor.isTerminal,
        !descriptor.inputs.isEmpty,
        !document.connections.contains(where: { $0.input.nodeID == node.id })
      else { return nil }
      return node.id
    })
    for node in document.nodes where node.executionState == .enabled
      && !disconnectedTerminals.contains(node.id) {
      guard let descriptor = descriptor(for: node, registry: registry) else { continue }
      for input in descriptor.inputs where input.isRequired {
        let reference = PipelinePortReference(nodeID: node.id, port: input.name)
        if incomingConnections[reference, default: 0] == 0 {
          add(
            .error, .missingInput, "Required input \(input.name) is not connected.",
            nodeID: node.id)
        }
      }
    }

    let connectedTerminals = PipelineGraphOutputs.connectedTerminalNodes(
      in: document, registry: registry)
    let terminalNodes: [PipelineNode]
    if let primaryOutputNodeIDs = document.primaryOutputNodeIDs, !primaryOutputNodeIDs.isEmpty {
      terminalNodes = primaryOutputNodeIDs.compactMap { selected in
        connectedTerminals.first { $0.id == selected }
      }
      for nodeID in primaryOutputNodeIDs where nodesByID[nodeID] == nil {
        add(
          .error, .invalidOutput,
          "Primary output refers to missing node \(nodeID.rawValue).", nodeID: nodeID)
      }
    } else {
      terminalNodes = connectedTerminals
    }
    if terminalNodes.isEmpty {
      add(.warning, .missingOutput, "The pipeline has no connected output; it can run without an outcome.")
    } else if terminalNodes.count > 1 {
      add(.error, .multipleOutputs, "The pipeline must have exactly one output node.")
    }

    var topologyDocument = document
    topologyDocument.connections = structurallyValidConnections
    if (try? PipelineGraphTopology.orderedNodeIDs(in: topologyDocument)) == nil {
      add(.error, .cycle, "Pipeline connections contain a cycle.")
    }

    if let terminalID = terminalNodes.first?.id {
      func string(_ value: PipelineValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
      }
      var connected = reverseReachable(
        from: terminalID, connections: structurallyValidConnections)
      for preview in document.nodes where preview.kind.rawValue == "output.preview"
        && preview.executionState == .enabled {
        connected.formUnion(reverseReachable(
          from: preview.id, connections: structurallyValidConnections))
      }
      let cacheKeys = Set(document.nodes.filter {
        $0.kind.rawValue == "cache.image" && connected.contains($0.id)
      }.compactMap { string($0.parameters["key"]) })
      for writer in document.nodes where writer.kind.rawValue == "cache.image"
        && writer.executionState == .enabled
        && (string(writer.parameters["mode"]) ?? "store") == "store"
        && cacheKeys.contains(string(writer.parameters["key"]) ?? "") {
        connected.formUnion(reverseReachable(
          from: writer.id, connections: structurallyValidConnections))
      }
      for node in document.nodes
      where node.executionState == .enabled && !connected.contains(node.id)
      {
        if node.kind == PipelineControlFlow.startKind
          || node.kind == PipelineControlFlow.loopKind { continue }
        // Annotation-only nodes, such as edit.markdownNote, intentionally have
        // no outputs and therefore cannot participate in output reachability.
        guard descriptor(for: node, registry: registry)?.outputs.isEmpty != true else { continue }
        add(
          .warning, .disconnectedNode,
          "Node \(node.id.rawValue) does not contribute to the pipeline output.",
          nodeID: node.id)
      }
    }

    validateExposedParameters(
      document.exposedParameters,
      nodesByID: nodesByID,
      registry: registry,
      add: add)

    if let presentation = document.presentation {
      for rawNodeID in presentation.nodePositions.keys {
        let nodeID = PipelineNodeID(rawValue: rawNodeID)
        guard nodesByID[nodeID] == nil else { continue }
        add(
          .warning, .stalePresentation,
          "Presentation data refers to missing node \(nodeID.rawValue).", nodeID: nodeID)
      }
      for rawNodeID in presentation.nodeSizes.keys {
        let nodeID = PipelineNodeID(rawValue: rawNodeID)
        guard nodesByID[nodeID] == nil else { continue }
        add(
          .warning, .stalePresentation,
          "Presentation size refers to missing node \(nodeID.rawValue).", nodeID: nodeID)
      }
    }

    return PipelineValidationReport(diagnostics: diagnostics)
  }

  private static func validate(
    _ node: PipelineNode,
    descriptor: PipelineNodeDescriptor,
    add: (
      PipelineDiagnosticSeverity, PipelineDiagnosticCode, String, PipelineNodeID?, Int?
    ) -> Void
  ) {
    for (slot, binding) in node.resources {
      switch binding {
      case .linked(let resource):
        if resource.packageID.isEmpty || resource.packageVersion.isEmpty
          || resource.contentHash.isEmpty || resource.componentRole.isEmpty
        {
          add(
            .error, .invalidResource,
            "Resource \(slot) requires package identity, version, content hash, and component role.",
            node.id, nil)
        }
      case .unresolved(let requirement):
        if requirement.componentRole.isEmpty || requirement.sourceName.isEmpty {
          add(
            .error, .invalidResource,
            "Unresolved resource \(slot) requires a component role and source name.", node.id, nil)
        } else {
          let format = requirement.sourceFormat.map { " (\($0))" } ?? ""
          let inactive = node.executionState == .enabled
            ? ""
            : " The node is currently \(node.executionState.rawValue)."
          add(
            node.executionState == .enabled ? .error : .warning, .unresolvedResource,
            "Resource \(slot) is not linked: \(requirement.sourceName)\(format).\(inactive)",
            node.id, nil)
        }
      }
    }
    guard node.executionState == .enabled else { return }
    for (name, value) in node.parameters {
      guard let parameter = descriptor.parameter(named: name) else {
        add(
          .error, .unknownParameter, "Parameter \(name) is not defined for this node.",
          node.id, nil)
        continue
      }
      if !value.matches(parameter.valueType) {
        add(
          .error, .invalidParameter,
          "Parameter \(name) is not a \(parameter.valueType.rawValue) value.", node.id, nil)
      }
    }
    for parameter in descriptor.parameters
    where parameter.isRequired && node.parameters[parameter.name] == nil
      && parameter.defaultValue == nil
    {
      add(
        .error, .missingParameter, "Required parameter \(parameter.name) is missing.",
        node.id, nil)
    }
    for slot in descriptor.requiredResourceSlots where node.resources[slot] == nil {
      add(.error, .missingResource, "Required resource \(slot) is missing.", node.id, nil)
    }
  }

  private static func validateExposedParameters(
    _ exposed: [PipelineExposedParameter],
    nodesByID: [PipelineNodeID: PipelineNode],
    registry: PipelineNodeRegistry,
    add: (
      PipelineDiagnosticSeverity, PipelineDiagnosticCode, String, PipelineNodeID?, Int?
    ) -> Void
  ) {
    var ids: Set<String> = []
    for parameter in exposed {
      guard !parameter.id.isEmpty, ids.insert(parameter.id).inserted else {
        add(
          .error, .invalidExposedParameter,
          "Exposed parameter IDs must be non-empty and unique.", parameter.target.nodeID, nil)
        continue
      }
      guard let node = nodesByID[parameter.target.nodeID],
        let descriptor = descriptor(for: node, registry: registry),
        let target = descriptor.parameter(named: parameter.target.parameter)
      else {
        add(
          .error, .invalidExposedParameter,
          "Exposed parameter \(parameter.id) has no valid node parameter target.",
          parameter.target.nodeID, nil)
        continue
      }
      if target.valueType != parameter.valueType
        || !(parameter.defaultValue?.matches(parameter.valueType) ?? true)
      {
        add(
          .error, .invalidExposedParameter,
          "Exposed parameter \(parameter.id) does not match its target type.",
          parameter.target.nodeID, nil)
      }
      if let minimum = parameter.minimum, let maximum = parameter.maximum, minimum > maximum {
        add(
          .error, .invalidExposedParameter,
          "Exposed parameter \(parameter.id) has an inverted range.",
          parameter.target.nodeID, nil)
      }
    }
  }

  private static func descriptor(
    for node: PipelineNode,
    registry: PipelineNodeRegistry
  ) -> PipelineNodeDescriptor? {
    PipelineGraphEditing.descriptor(for: node, registry: registry)
  }

  private static func reverseReachable(
    from terminal: PipelineNodeID,
    connections: [PipelineConnection]
  ) -> Set<PipelineNodeID> {
    var incoming: [PipelineNodeID: Set<PipelineNodeID>] = [:]
    for connection in connections {
      incoming[connection.input.nodeID, default: []].insert(connection.output.nodeID)
    }
    var result: Set<PipelineNodeID> = [terminal]
    var pending = [terminal]
    while let nodeID = pending.popLast() {
      for source in incoming[nodeID] ?? [] where result.insert(source).inserted {
        pending.append(source)
      }
    }
    return result
  }
}

private struct PipelinePortTypeVariable: Hashable {
  var nodeID: PipelineNodeID
  var name: String
}

private struct PipelinePortTypeTerm {
  var type: PipelinePortType
  var variable: PipelinePortTypeVariable?
}

/// Resolves descriptor-local polymorphic port groups while connections are
/// checked. Copying the resolver before each attempted connection keeps a
/// rejected edge from changing the constraints used by later diagnostics.
private struct PipelinePortTypeResolver {
  private var parents: [PipelinePortTypeVariable: PipelinePortTypeVariable] = [:]
  private var concreteTypes: [PipelinePortTypeVariable: PipelinePortType] = [:]

  mutating func connect(_ output: PipelinePortTypeTerm, _ input: PipelinePortTypeTerm) -> Bool {
    guard constrain(output), constrain(input) else { return false }

    switch (output.variable, input.variable) {
    case let (outputVariable?, inputVariable?):
      return merge(outputVariable, inputVariable)
    case let (outputVariable?, nil):
      return bind(outputVariable, to: input.type)
    case let (nil, inputVariable?):
      return bind(inputVariable, to: output.type)
    case (nil, nil):
      return Self.areCompatible(output.type, input.type)
    }
  }

  private mutating func constrain(_ term: PipelinePortTypeTerm) -> Bool {
    guard let variable = term.variable else { return true }
    return bind(variable, to: term.type)
  }

  private mutating func bind(
    _ variable: PipelinePortTypeVariable,
    to type: PipelinePortType
  ) -> Bool {
    guard type != .any else { return true }
    let root = root(of: variable)
    guard let existing = concreteTypes[root] else {
      concreteTypes[root] = type
      return true
    }
    return Self.areCompatible(existing, type)
  }

  private mutating func merge(
    _ first: PipelinePortTypeVariable,
    _ second: PipelinePortTypeVariable
  ) -> Bool {
    let firstRoot = root(of: first)
    let secondRoot = root(of: second)
    guard firstRoot != secondRoot else { return true }
    let firstType = concreteTypes[firstRoot]
    let secondType = concreteTypes[secondRoot]
    if let firstType, let secondType, !Self.areCompatible(firstType, secondType) {
      return false
    }
    parents[secondRoot] = firstRoot
    concreteTypes[firstRoot] = firstType ?? secondType
    concreteTypes.removeValue(forKey: secondRoot)
    return true
  }

  private mutating func root(
    of variable: PipelinePortTypeVariable
  ) -> PipelinePortTypeVariable {
    guard let parent = parents[variable] else {
      parents[variable] = variable
      return variable
    }
    guard parent != variable else { return variable }
    let resolved = root(of: parent)
    parents[variable] = resolved
    return resolved
  }

  private static func areCompatible(
    _ output: PipelinePortType,
    _ input: PipelinePortType
  ) -> Bool {
    if output == input || output == .any || input == .any { return true }
    let pair = Set([output, input])
    return pair == Set([.string, .prompt]) || pair == Set([.integer, .seed])
  }
}

extension PipelineValue {
  fileprivate func matches(_ type: PipelineParameterValueType) -> Bool {
    switch (self, type) {
    case (_, .any): true
    case (.boolean, .boolean), (.integer, .integer), (.string, .string): true
    case (.integer, .number), (.number, .number): true
    case (.array, .array), (.object, .object): true
    default: false
    }
  }
}

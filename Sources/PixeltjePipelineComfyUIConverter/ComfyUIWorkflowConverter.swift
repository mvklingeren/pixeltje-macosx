import CoreFoundation
import Foundation
import PixeltjePipelineDomain

public struct ComfyUIConversionOptions: Equatable, Sendable {
  public var mapNodes: Bool
  public var includeResourceGuidance: Bool
  public var projectedOutputSourceNodeID: String?

  public init(
    mapNodes: Bool = false,
    includeResourceGuidance: Bool = true,
    projectedOutputSourceNodeID: String? = nil
  ) {
    self.mapNodes = mapNodes
    self.includeResourceGuidance = includeResourceGuidance
    self.projectedOutputSourceNodeID = projectedOutputSourceNodeID
  }
}

public enum ComfyUIConversionDiagnosticSeverity: String, Codable, Sendable {
  case warning
  case information
}

public struct ComfyUIConversionDiagnostic: Codable, Equatable, Sendable {
  public var severity: ComfyUIConversionDiagnosticSeverity
  public var message: String
  public var sourceNodeID: String?

  public init(
    severity: ComfyUIConversionDiagnosticSeverity,
    message: String,
    sourceNodeID: String? = nil
  ) {
    self.severity = severity
    self.message = message
    self.sourceNodeID = sourceNodeID
  }
}

public struct ComfyUIConversionSummary: Equatable, Sendable {
  public var sourceNodeCount: Int
  public var connectionCount: Int
  public var mappedNodeCount: Int
  public var placeholderNodeCount: Int
  public var unresolvedResourceCount: Int

  public init(
    sourceNodeCount: Int,
    connectionCount: Int,
    mappedNodeCount: Int,
    placeholderNodeCount: Int,
    unresolvedResourceCount: Int
  ) {
    self.sourceNodeCount = sourceNodeCount
    self.connectionCount = connectionCount
    self.mappedNodeCount = mappedNodeCount
    self.placeholderNodeCount = placeholderNodeCount
    self.unresolvedResourceCount = unresolvedResourceCount
  }
}

public struct ComfyUIConversionResult: Sendable {
  public var document: PipelineDocument
  public var summary: ComfyUIConversionSummary
  public var diagnostics: [ComfyUIConversionDiagnostic]

  public init(
    document: PipelineDocument,
    summary: ComfyUIConversionSummary,
    diagnostics: [ComfyUIConversionDiagnostic]
  ) {
    self.document = document
    self.summary = summary
    self.diagnostics = diagnostics
  }
}

public enum ComfyUIConversionError: Error, LocalizedError, Sendable {
  case invalidJSON
  case unsupportedFormat
  case invalidNode(String)
  case duplicateNode(String)
  case missingProjectedOutput(String)

  public var errorDescription: String? {
    switch self {
    case .invalidJSON:
      "The selected file is not a JSON object."
    case .unsupportedFormat:
      "The selected JSON is not a regular ComfyUI frontend workflow with nodes and links."
    case .invalidNode(let message):
      "The ComfyUI workflow contains an invalid node: \(message)"
    case .duplicateNode(let id):
      "The ComfyUI workflow uses node ID \(id) more than once."
    case .missingProjectedOutput(let id):
      "The ComfyUI workflow has no top-level output node with ID \(id)."
    }
  }
}

/// Pure, offline conversion from regular ComfyUI frontend workflow JSON into
/// Pixeltje's portable graph. It never resolves, opens, hashes, or downloads a
/// model resource. `mapNodes` only applies conservative semantic rewrites.
public enum ComfyUIWorkflowConverter {
  /// The native port type an imported ComfyUI socket type becomes.
  public static func portType(forComfyUIType type: String) -> PipelinePortType {
    pipelinePortType(type)
  }

  public static func convert(
    _ data: Data,
    sourceName: String = "Imported ComfyUI Workflow",
    options: ComfyUIConversionOptions = ComfyUIConversionOptions()
  ) throws -> ComfyUIConversionResult {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ComfyUIConversionError.invalidJSON
    }
    guard let rawNodes = root["nodes"] as? [Any], let rawLinks = root["links"] as? [Any] else {
      throw ComfyUIConversionError.unsupportedFormat
    }

    var diagnostics: [ComfyUIConversionDiagnostic] = []
    var topLevelNodes = try rawNodes.map(SourceNode.init)
    var topLevelLinks = rawLinks.compactMap(SourceLink.init)
    if topLevelLinks.count != rawLinks.count {
      diagnostics.append(.init(
        severity: .warning,
        message: "Ignored \(rawLinks.count - topLevelLinks.count) malformed ComfyUI links."))
    }
    if let outputID = options.projectedOutputSourceNodeID {
      let projection = try projectTopLevelWorkflow(
        nodes: topLevelNodes,
        links: topLevelLinks,
        toOutput: outputID)
      topLevelNodes = projection.nodes
      topLevelLinks = projection.links
      diagnostics.append(.init(
        severity: .information,
        message: "Projected ComfyUI output \(outputID) into one enabled branch.",
        sourceNodeID: outputID))
    }
    let expanded = expandSubgraphs(
      root: root,
      nodes: topLevelNodes,
      links: topLevelLinks,
      diagnostics: &diagnostics)
    let sourceNodes = expanded.nodes
    let uniqueIDs = Set(sourceNodes.map(\.id))
    guard uniqueIDs.count == sourceNodes.count else {
      let duplicate = Dictionary(grouping: sourceNodes, by: \.id)
        .first(where: { $0.value.count > 1 })?.key ?? "unknown"
      throw ComfyUIConversionError.duplicateNode(duplicate)
    }

    let sourceLinks = activeInputLinks(
      expanded.links,
      nodes: sourceNodes,
      diagnostics: &diagnostics)

    let primarySourceID = choosePrimaryOutput(in: sourceNodes)
    var convertedBySourceID: [String: ConvertedNode] = [:]
    var nodes: [PipelineNode] = []
    var subgraphConnections: [PipelineConnection] = []
    var mappedNodeCount = 0
    var linkedInputSlots: [String: Set<Int>] = [:]
    var linkedOutputSlots: [String: Set<Int>] = [:]
    for link in sourceLinks {
      linkedInputSlots[link.inputNodeID, default: []].insert(link.inputSlot)
      linkedOutputSlots[link.outputNodeID, default: []].insert(link.outputSlot)
    }
    for source in sourceNodes {
      var converted = convertNode(
        source,
        isPrimaryOutput: source.id == primarySourceID,
        mapNodes: options.mapNodes)
      let linkedSamplerWidget = source.type == "KSamplerAdvanced"
        && (linkedInputSlots[source.id] ?? []).contains { slot in
          source.inputs.indices.contains(slot)
            && (expandedNodeWidgets[source.type] ?? []).contains(source.inputs[slot].name)
        }
      if converted.wasMapped && (linkedSamplerWidget
        || (linkedInputSlots[source.id] ?? []).contains { converted.inputTargets($0).isEmpty }
          || (linkedOutputSlots[source.id] ?? []).contains {
            converted.outputSource($0) == nil
          }
      ) {
        diagnostics.append(.init(
          severity: .warning,
          message: linkedSamplerWidget
            ? "Node \(source.id) stays a placeholder because its sampler topology depends on a connected widget."
            : "Node \(source.id) stays a placeholder because its mapping omits a connected port.",
          sourceNodeID: source.id))
        converted = convertNode(
          source,
          isPrimaryOutput: source.id == primarySourceID,
          mapNodes: false)
      }
      nodes.append(contentsOf: converted.allNodes)
      subgraphConnections.append(contentsOf: converted.expansion?.connections ?? [])
      convertedBySourceID[source.id] = converted
      if converted.wasMapped { mappedNodeCount += 1 }
    }

    var connections: [PipelineConnection] = []
    for link in sourceLinks {
      guard let outputNode = convertedBySourceID[link.outputNodeID],
        let inputNode = convertedBySourceID[link.inputNodeID],
        let output = outputNode.outputSource(link.outputSlot)
      else {
        diagnostics.append(.init(
          severity: .warning,
          message: "Link \(link.id) refers to a port omitted by conservative node mapping."))
        continue
      }
      let targets = inputNode.inputTargets(link.inputSlot)
      if targets.isEmpty {
        diagnostics.append(.init(
          severity: .warning,
          message: "Link \(link.id) refers to a port omitted by conservative node mapping."))
      }
      for (index, target) in targets.enumerated() {
        let suffix = index == 0 ? "" : "-\(index + 1)"
        connections.append(PipelineConnection(
          id: PipelineConnectionID(rawValue: "comfyui-link-\(link.id)\(suffix)"),
          output: output,
          input: target))
      }
    }
    connections.append(contentsOf: subgraphConnections)

    var presentation = makePresentation(root: root, nodes: sourceNodes)
    for source in sourceNodes {
      guard let converted = convertedBySourceID[source.id], converted.expansion != nil else {
        continue
      }
      layOutSubgraph(converted, source: source, presentation: &presentation)
    }
    if options.includeResourceGuidance {
      appendResourceGuidance(
        to: &nodes,
        presentation: &presentation,
        diagnostics: &diagnostics)
    }
    let primaryOutputNodeIDs = primarySourceID.flatMap { convertedBySourceID[$0]?.node.id }
      .map { [$0] }
    let unresolvedResourceCount = nodes.reduce(0) { count, node in
      count + node.resources.values.filter { $0.unresolvedRequirement != nil }.count
    }
    let displayName = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
    let sourceWorkflowID = scalarString(root["id"])
      ?? (displayName.isEmpty ? "imported-workflow" : displayName)
    let projectedIdentity = options.projectedOutputSourceNodeID.map {
      ".output-" + portableIdentityComponent($0)
    } ?? ""
    let document = PipelineDocument(
      id: PipelineID(rawValue: "comfyui.\(sourceWorkflowID)\(projectedIdentity)"),
      name: displayName.isEmpty ? "Imported ComfyUI Workflow" : displayName,
      mode: inferMode(from: sourceNodes),
      requirements: PipelineRequirements(),
      nodes: nodes,
      connections: connections,
      primaryOutputNodeIDs: primaryOutputNodeIDs,
      presentation: presentation)
    let summary = ComfyUIConversionSummary(
      sourceNodeCount: sourceNodes.count,
      connectionCount: connections.count,
      mappedNodeCount: mappedNodeCount,
      placeholderNodeCount: sourceNodes.count - mappedNodeCount,
      unresolvedResourceCount: unresolvedResourceCount)
    return ComfyUIConversionResult(
      document: document,
      summary: summary,
      diagnostics: diagnostics)
  }
}

private func projectTopLevelWorkflow(
  nodes: [SourceNode],
  links: [SourceLink],
  toOutput outputID: String
) throws -> (nodes: [SourceNode], links: [SourceLink]) {
  guard let output = nodes.first(where: { $0.id == outputID }), output.outputs.isEmpty else {
    throw ComfyUIConversionError.missingProjectedOutput(outputID)
  }

  var incoming: [String: Set<String>] = [:]
  for link in links {
    incoming[link.inputNodeID, default: []].insert(link.outputNodeID)
  }
  var retainedIDs: Set<String> = [outputID]
  var pending = [outputID]
  while let nodeID = pending.popLast() {
    for sourceID in incoming[nodeID] ?? [] where retainedIDs.insert(sourceID).inserted {
      pending.append(sourceID)
    }
  }

  let projectedNodes = nodes.compactMap { node -> SourceNode? in
    guard retainedIDs.contains(node.id) else { return nil }
    var projected = node
    projected.executionState = .enabled
    return projected
  }
  let projectedLinks = links.filter {
    retainedIDs.contains($0.outputNodeID) && retainedIDs.contains($0.inputNodeID)
  }
  return (projectedNodes, projectedLinks)
}

private func portableIdentityComponent(_ value: String) -> String {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
  return String(value.unicodeScalars.map {
    allowed.contains($0) ? Character(String($0)) : Character("-")
  })
}

private func appendResourceGuidance(
  to nodes: inout [PipelineNode],
  presentation: inout PipelinePresentation,
  diagnostics: inout [ComfyUIConversionDiagnostic]
) {
  let requirements = nodes.flatMap { node in
    node.resources.values.compactMap(\.unresolvedRequirement)
  }
  let guides = PipelineResourceGuidanceCatalog.builtIn.guides(for: requirements)
  guard !guides.isEmpty else { return }

  let existingMarkdown = nodes.compactMap { node -> String? in
    guard case .string(let value) = node.parameters["text"] else { return nil }
    return value
  }
  let rightEdge = presentation.nodePositions.reduce(80.0) { edge, item in
    let width = presentation.nodeSizes[item.key]?.width ?? 220
    return max(edge, item.value.x + width)
  }
  let topEdge = presentation.nodePositions.values.map(\.y).min() ?? 80
  let guidanceX = rightEdge + 80

  for (index, guide) in guides.enumerated() {
    let marker = "<!-- pixeltje-resource-guide:\(guide.id) -->"
    guard !existingMarkdown.contains(where: { $0.contains(marker) }) else { continue }

    let nodeID = PipelineNodeID(rawValue: resourceGuideNodeID(guide.id))
    nodes.append(PipelineNode(
      id: nodeID,
      kind: PipelineNodeKind(rawValue: "edit.markdownNote"),
      title: "Tips & Tricks: \(guide.displayName)",
      parameters: ["text": .string(guide.markdownDescription)],
      executionState: .disabled,
      origin: PipelineNodeOrigin(
        system: "pixeltje.resource-guidance",
        sourceNodeID: guide.id,
        sourceType: "ResourceGuidance")))
    presentation.nodePositions[nodeID.rawValue] = PipelinePoint(
      x: guidanceX,
      y: topEdge + Double(index * 250))
    presentation.nodeSizes[nodeID.rawValue] = PipelineSize(width: 380, height: 220)
    diagnostics.append(ComfyUIConversionDiagnostic(
      severity: .information,
      message: "Added acquisition tips for \(guide.displayName)."))
  }
  presentation.viewportOrigin = PipelinePoint(
    x: max(0, guidanceX - 40),
    y: max(0, topEdge - 40))
}

private func resourceGuideNodeID(_ guideID: String) -> String {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
  let sanitized = guideID.unicodeScalars.map {
    allowed.contains($0) ? Character(String($0)) : Character("-")
  }
  return "pixeltje-resource-guide-" + String(sanitized)
}

struct SourcePort {
  var name: String
  var type: String
  var hasWidget: Bool
  var linkID: String?
}

struct SourceNode {
  var id: String
  var type: String
  var title: String?
  var executionState: PipelineNodeExecutionState
  var inputs: [SourcePort]
  var outputs: [SourcePort]
  var widgets: [Any]
  var namedWidgets: [String: Any]
  var properties: [String: Any]
  var position: PipelinePoint
  var size: PipelineSize

  init(_ value: Any) throws {
    guard let object = value as? [String: Any],
      let id = scalarString(object["id"]),
      let type = object["type"] as? String
    else {
      throw ComfyUIConversionError.invalidNode("Every node requires an ID and type.")
    }
    self.id = id
    self.type = type
    title = object["title"] as? String
    let mode = integer(object["mode"]) ?? 0
    executionState = switch mode {
    case 2: .disabled
    case 4: .bypassed
    default: .enabled
    }
    inputs = Self.ports(object["inputs"])
    outputs = Self.ports(object["outputs"])
    widgets = object["widgets_values"] as? [Any] ?? []
    namedWidgets = object["widgets_values_named"] as? [String: Any] ?? [:]
    properties = object["properties"] as? [String: Any] ?? [:]
    position = Self.point(object["pos"]) ?? PipelinePoint(x: 0, y: 0)
    size = Self.size(object["size"]) ?? PipelineSize(width: 220, height: 100)
  }

  private static func ports(_ value: Any?) -> [SourcePort] {
    guard let values = value as? [Any] else { return [] }
    var usedNames: Set<String> = []
    return values.enumerated().map { index, value in
      let object = value as? [String: Any] ?? [:]
      let proposedName = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces)
      let baseName = proposedName?.isEmpty == false ? proposedName! : "port-\(index)"
      var name = baseName
      if !usedNames.insert(name).inserted {
        name = "\(baseName)-\(index)"
        usedNames.insert(name)
      }
      return SourcePort(
        name: name,
        type: typeString(object["type"]),
        hasWidget: object["widget"] != nil,
        linkID: scalarString(object["link"]))
    }
  }

  private static func point(_ value: Any?) -> PipelinePoint? {
    guard let values = value as? [Any], values.count >= 2,
      let x = double(values[0]), let y = double(values[1])
    else { return nil }
    return PipelinePoint(x: x, y: y)
  }

  private static func size(_ value: Any?) -> PipelineSize? {
    guard let values = value as? [Any], values.count >= 2,
      let width = double(values[0]), let height = double(values[1])
    else { return nil }
    return PipelineSize(width: width, height: height)
  }
}

private struct SourceLink {
  var id: String
  var outputNodeID: String
  var outputSlot: Int
  var inputNodeID: String
  var inputSlot: Int

  init(
    id: String,
    outputNodeID: String,
    outputSlot: Int,
    inputNodeID: String,
    inputSlot: Int
  ) {
    self.id = id
    self.outputNodeID = outputNodeID
    self.outputSlot = outputSlot
    self.inputNodeID = inputNodeID
    self.inputSlot = inputSlot
  }

  init?(_ value: Any) {
    if let values = value as? [Any], values.count >= 5,
      let id = scalarString(values[0]),
      let outputNodeID = scalarString(values[1]),
      let outputSlot = integer(values[2]),
      let inputNodeID = scalarString(values[3]),
      let inputSlot = integer(values[4])
    {
      self.id = id
      self.outputNodeID = outputNodeID
      self.outputSlot = outputSlot
      self.inputNodeID = inputNodeID
      self.inputSlot = inputSlot
      return
    }
    guard let object = value as? [String: Any],
      let id = scalarString(object["id"]),
      let outputNodeID = scalarString(object["origin_id"]),
      let outputSlot = integer(object["origin_slot"]),
      let inputNodeID = scalarString(object["target_id"]),
      let inputSlot = integer(object["target_slot"])
    else { return nil }
    self.id = id
    self.outputNodeID = outputNodeID
    self.outputSlot = outputSlot
    self.inputNodeID = inputNodeID
    self.inputSlot = inputSlot
  }
}

private struct SourceInputEndpoint: Hashable {
  var nodeID: String
  var slot: Int
}

/// ComfyUI frontend files can retain obsolete links after a connectable widget
/// is rewired. When more than one link targets the same input, the input's
/// current `link` value is authoritative. Preserve ambiguous cases rather than
/// guessing so validation can report the duplicate connection.
private func activeInputLinks(
  _ links: [SourceLink],
  nodes: [SourceNode],
  diagnostics: inout [ComfyUIConversionDiagnostic]
) -> [SourceLink] {
  let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  let linksByInput = Dictionary(grouping: links) {
    SourceInputEndpoint(nodeID: $0.inputNodeID, slot: $0.inputSlot)
  }
  var result: [SourceLink] = []
  for link in links {
    let endpoint = SourceInputEndpoint(nodeID: link.inputNodeID, slot: link.inputSlot)
    guard let candidates = linksByInput[endpoint], candidates.count > 1,
      let node = nodesByID[link.inputNodeID], node.inputs.indices.contains(link.inputSlot),
      let declaredLinkID = node.inputs[link.inputSlot].linkID
    else {
      result.append(link)
      continue
    }
    let declaredCandidates = candidates.filter {
      $0.id == declaredLinkID || $0.id.hasSuffix(":\(declaredLinkID)")
    }
    guard declaredCandidates.count == 1 else {
      result.append(link)
      continue
    }
    guard declaredCandidates[0].id != link.id else {
      result.append(link)
      continue
    }
    diagnostics.append(.init(
      severity: .warning,
      message:
        "Ignored stale ComfyUI link \(link.id); input \(link.inputNodeID):\(link.inputSlot) declares link \(declaredCandidates[0].id)."))
  }
  return result
}

private struct SourceEndpoint {
  var nodeID: String
  var slot: Int
}

private struct SourceSubgraphDefinition {
  var id: String
  var name: String
  var inputs: [String]
  var outputs: [String]
  var nodes: [SourceNode]
  var links: [SourceLink]

  init?(_ value: Any) {
    guard let object = value as? [String: Any],
      let id = object["id"] as? String,
      let rawNodes = object["nodes"] as? [Any],
      let rawLinks = object["links"] as? [Any],
      let nodes = try? rawNodes.map(SourceNode.init),
      Set(nodes.map(\.id)).count == nodes.count,
      rawLinks.allSatisfy({ SourceLink($0) != nil })
    else { return nil }
    self.id = id
    name = object["name"] as? String ?? id
    inputs = Self.portNames(object["inputs"])
    outputs = Self.portNames(object["outputs"])
    self.nodes = nodes
    links = rawLinks.compactMap(SourceLink.init)
  }

  private static func portNames(_ value: Any?) -> [String] {
    guard let values = value as? [Any] else { return [] }
    return values.enumerated().map { index, value in
      let object = value as? [String: Any]
      return object?["name"] as? String ?? "port-\(index)"
    }
  }
}

private struct ExpandedSubgraphInstance {
  var inputTargets: [Int: [SourceEndpoint]]
  var outputSources: [Int: [SourceEndpoint]]
}

private func expandSubgraphs(
  root: [String: Any],
  nodes originalNodes: [SourceNode],
  links originalLinks: [SourceLink],
  diagnostics: inout [ComfyUIConversionDiagnostic]
) -> (nodes: [SourceNode], links: [SourceLink]) {
  guard let definitionsObject = root["definitions"] as? [String: Any],
    let rawDefinitions = definitionsObject["subgraphs"] as? [Any]
  else { return (originalNodes, originalLinks) }

  var definitions: [String: SourceSubgraphDefinition] = [:]
  for value in rawDefinitions {
    guard let definition = SourceSubgraphDefinition(value), definitions[definition.id] == nil
    else { continue }
    definitions[definition.id] = definition
  }
  guard !definitions.isEmpty else { return (originalNodes, originalLinks) }

  var nodes = originalNodes
  var links = originalLinks
  var depth = 0
  while nodes.contains(where: { definitions[$0.type] != nil }), depth < 16 {
    depth += 1
    let result = expandOneSubgraphLevel(
      nodes: nodes,
      links: links,
      definitions: definitions,
      diagnostics: &diagnostics)
    nodes = result.nodes
    links = result.links
  }
  if nodes.contains(where: { definitions[$0.type] != nil }) {
    diagnostics.append(.init(
      severity: .warning,
      message: "Stopped expanding nested ComfyUI subgraphs after 16 levels."))
  }
  return (nodes, links)
}

private func expandOneSubgraphLevel(
  nodes: [SourceNode],
  links: [SourceLink],
  definitions: [String: SourceSubgraphDefinition],
  diagnostics: inout [ComfyUIConversionDiagnostic]
) -> (nodes: [SourceNode], links: [SourceLink]) {
  var resultNodes: [SourceNode] = []
  var resultLinks: [SourceLink] = []
  var expansions: [String: ExpandedSubgraphInstance] = [:]

  for node in nodes {
    guard let definition = definitions[node.type] else {
      resultNodes.append(node)
      continue
    }
    let expansion = expandSubgraphInstance(node, definition: definition)
    resultNodes.append(contentsOf: expansion.nodes)
    resultLinks.append(contentsOf: expansion.links)
    expansions[node.id] = expansion.boundary
    diagnostics.append(.init(
      severity: .information,
      message: "Expanded ComfyUI subgraph \(definition.name) into \(expansion.nodes.count) nodes.",
      sourceNodeID: node.id))
  }

  for link in links {
    let sources: [SourceEndpoint]
    if let expansion = expansions[link.outputNodeID] {
      sources = expansion.outputSources[link.outputSlot] ?? []
    } else {
      sources = [SourceEndpoint(nodeID: link.outputNodeID, slot: link.outputSlot)]
    }
    let targets: [SourceEndpoint]
    if let expansion = expansions[link.inputNodeID] {
      targets = expansion.inputTargets[link.inputSlot] ?? []
    } else {
      targets = [SourceEndpoint(nodeID: link.inputNodeID, slot: link.inputSlot)]
    }
    guard !sources.isEmpty, !targets.isEmpty else {
      diagnostics.append(.init(
        severity: .warning,
        message: "Link \(link.id) refers to an unbound ComfyUI subgraph port."))
      continue
    }
    for (sourceIndex, source) in sources.enumerated() {
      for (targetIndex, target) in targets.enumerated() {
        resultLinks.append(SourceLink(
          id: "\(link.id):\(sourceIndex):\(targetIndex)",
          outputNodeID: source.nodeID,
          outputSlot: source.slot,
          inputNodeID: target.nodeID,
          inputSlot: target.slot))
      }
    }
  }
  return (resultNodes, resultLinks)
}

private func expandSubgraphInstance(
  _ instance: SourceNode,
  definition: SourceSubgraphDefinition
) -> (
  nodes: [SourceNode],
  links: [SourceLink],
  boundary: ExpandedSubgraphInstance
) {
  let minimumX = definition.nodes.map(\.position.x).min() ?? 0
  let minimumY = definition.nodes.map(\.position.y).min() ?? 0
  let prefixedID = Dictionary(uniqueKeysWithValues: definition.nodes.map {
    ($0.id, "\(instance.id):\($0.id)")
  })
  var expandedNodes = definition.nodes.map { node in
    var expanded = node
    expanded.id = prefixedID[node.id] ?? "\(instance.id):\(node.id)"
    expanded.position = PipelinePoint(
      x: instance.position.x + node.position.x - minimumX,
      y: instance.position.y + node.position.y - minimumY)
    if instance.executionState != .enabled {
      expanded.executionState = instance.executionState
    }
    return expanded
  }

  var internalLinks: [SourceLink] = []
  var definitionInputTargets: [Int: [SourceEndpoint]] = [:]
  var definitionOutputSources: [Int: [SourceEndpoint]] = [:]
  for link in definition.links {
    if link.outputNodeID == "-10", let targetID = prefixedID[link.inputNodeID] {
      definitionInputTargets[link.outputSlot, default: []].append(
        SourceEndpoint(nodeID: targetID, slot: link.inputSlot))
    } else if link.inputNodeID == "-20", let sourceID = prefixedID[link.outputNodeID] {
      definitionOutputSources[link.inputSlot, default: []].append(
        SourceEndpoint(nodeID: sourceID, slot: link.outputSlot))
    } else if let sourceID = prefixedID[link.outputNodeID],
      let targetID = prefixedID[link.inputNodeID]
    {
      internalLinks.append(SourceLink(
        id: "\(instance.id):\(link.id)",
        outputNodeID: sourceID,
        outputSlot: link.outputSlot,
        inputNodeID: targetID,
        inputSlot: link.inputSlot))
    }
  }

  applySubgraphWidgetValues(
    instance.widgets,
    namedValues: instance.namedWidgets,
    inputNames: definition.inputs,
    definitionInputTargets: definitionInputTargets,
    nodes: &expandedNodes)

  var definitionInputIndex: [String: Int] = [:]
  for (index, name) in definition.inputs.enumerated() where definitionInputIndex[name] == nil {
    definitionInputIndex[name] = index
  }
  var definitionOutputIndex: [String: Int] = [:]
  for (index, name) in definition.outputs.enumerated() where definitionOutputIndex[name] == nil {
    definitionOutputIndex[name] = index
  }
  var inputTargets: [Int: [SourceEndpoint]] = [:]
  for (slot, input) in instance.inputs.enumerated() {
    let definitionSlot = definitionInputIndex[input.name] ?? slot
    inputTargets[slot] = definitionInputTargets[definitionSlot] ?? []
  }
  var outputSources: [Int: [SourceEndpoint]] = [:]
  for (slot, output) in instance.outputs.enumerated() {
    let definitionSlot = definitionOutputIndex[output.name] ?? slot
    outputSources[slot] = definitionOutputSources[definitionSlot] ?? []
  }
  return (
    expandedNodes,
    internalLinks,
    ExpandedSubgraphInstance(inputTargets: inputTargets, outputSources: outputSources))
}

private func applySubgraphWidgetValues(
  _ widgetValues: [Any],
  namedValues: [String: Any],
  inputNames: [String],
  definitionInputTargets: [Int: [SourceEndpoint]],
  nodes: inout [SourceNode]
) {
  var widgetValueIndex = 0
  for definitionInputIndex in definitionInputTargets.keys.sorted() {
    let targets = definitionInputTargets[definitionInputIndex] ?? []
    let widgetInputs = targets.compactMap { target -> (nodeIndex: Int, inputName: String)? in
      guard let nodeIndex = nodes.firstIndex(where: { $0.id == target.nodeID }),
        nodes[nodeIndex].inputs.indices.contains(target.slot),
        nodes[nodeIndex].inputs[target.slot].hasWidget
      else { return nil }
      return (nodeIndex, nodes[nodeIndex].inputs[target.slot].name)
    }
    guard !widgetInputs.isEmpty else { continue }
    // An unfamiliar widget still occupies a serialized position. Skipping it
    // must not assign its value to every subsequent promoted control.
    let positionalValue = widgetValues.indices.contains(widgetValueIndex)
      ? widgetValues[widgetValueIndex] : nil
    let namedValue = inputNames.indices.contains(definitionInputIndex)
      ? namedValues[inputNames[definitionInputIndex]] : nil
    widgetValueIndex += 1
    guard let value = namedValue ?? positionalValue else { continue }
    for target in widgetInputs {
      // A target may itself be a subgraph. Keep its named representation in
      // sync so recursive expansion cannot restore an older saved value.
      nodes[target.nodeIndex].namedWidgets[target.inputName] = value
      guard let widgetIndex = sourceWidgetIndex(
        inputName: target.inputName, node: nodes[target.nodeIndex]),
        nodes[target.nodeIndex].widgets.indices.contains(widgetIndex)
      else { continue }
      nodes[target.nodeIndex].widgets[widgetIndex] = value
    }
  }
}

private func sourceWidgetIndex(inputName: String, node: SourceNode) -> Int? {
  let alias: String = switch (node.type, inputName) {
  case ("UNETLoader", "unet_name"), ("UnetLoaderGGUF", "unet_name"):
    "modelName"
  case ("CLIPLoader", "clip_name"), ("VAELoader", "vae_name"):
    "modelName"
  case ("RandomNoise", "noise_seed"):
    "seed"
  case ("KSampler", "cfg"):
    "guidance"
  case ("KSampler", "sampler_name"):
    "sampler"
  default:
    inputName
  }
  return widgetNames(for: node).firstIndex(of: alias)
}

struct ConvertedNode {
  var node: PipelineNode
  var inputNames: [String?]
  var outputNames: [String?]
  var wasMapped: Bool
  /// Set when an all-in-one source node imports as a subgraph. `node` is then
  /// the subgraph node that keeps the source node's ID.
  var expansion: ConvertedExpansion? = nil

  var allNodes: [PipelineNode] {
    [node] + (expansion?.nodes ?? [])
  }

  func outputSource(_ slot: Int) -> PipelinePortReference? {
    if let expansion {
      return expansion.outputSources.indices.contains(slot) ? expansion.outputSources[slot] : nil
    }
    guard outputNames.indices.contains(slot), let name = outputNames[slot] else { return nil }
    return PipelinePortReference(nodeID: node.id, port: name)
  }

  func inputTargets(_ slot: Int) -> [PipelinePortReference] {
    if let expansion {
      return expansion.inputTargets.indices.contains(slot) ? expansion.inputTargets[slot] : []
    }
    guard inputNames.indices.contains(slot), let name = inputNames[slot] else { return [] }
    return [PipelinePortReference(nodeID: node.id, port: name)]
  }
}

/// The native subgraph an all-in-one ComfyUI node imports as.
struct ConvertedExpansion {
  /// Subgraph nodes other than the one that keeps the source node's ID.
  var nodes: [PipelineNode]
  var connections: [PipelineConnection]
  /// Native inputs each ComfyUI input slot feeds; one input may feed several.
  var inputTargets: [[PipelinePortReference]]
  var outputSources: [PipelinePortReference?]
}

private func convertNode(
  _ source: SourceNode,
  isPrimaryOutput: Bool,
  mapNodes: Bool
) -> ConvertedNode {
  let nodeID = PipelineNodeID(rawValue: "comfyui-node-\(source.id)")
  let resources = extractResources(from: source)
  let origin = PipelineNodeOrigin(
    system: "comfyui.frontend",
    sourceNodeID: source.id,
    sourceType: source.type,
    metadata: [
      "widgets": .array(source.widgets.map(pipelineValue)),
      "properties": .object(source.properties.mapValues(pipelineValue)),
    ])

  if mapNodes, let mapped = mapNode(
    source,
    nodeID: nodeID,
    resources: resources,
    origin: origin,
    isPrimaryOutput: isPrimaryOutput)
  {
    return mapped
  }

  let inputNames = source.inputs.map { Optional($0.name) }
  let outputNames = source.outputs.map { Optional($0.name) }
  let parameters = widgetParameters(for: source)
  let parameterDescriptors = parameters.map { name, value in
    PipelineParameterDescriptor(
      name: name,
      valueType: parameterType(value),
      defaultValue: value)
  }.sorted { $0.name < $1.name }
  let descriptor = PipelineNodeDescriptor(
    kind: importedKind(source.type),
    displayName: source.title ?? source.type,
    category: "Imported ComfyUI",
    inputs: source.inputs.map {
      PipelinePortDescriptor(
        name: $0.name, type: pipelinePortType($0.type), isRequired: false)
    },
    outputs: source.outputs.map {
      PipelinePortDescriptor(name: $0.name, type: pipelinePortType($0.type))
    },
    parameters: parameterDescriptors,
    requiredResourceSlots: Set(resources.keys),
    isTerminal: isPrimaryOutput)
  return ConvertedNode(
    node: PipelineNode(
      id: nodeID,
      kind: descriptor.kind,
      title: source.title ?? source.type,
      parameters: parameters,
      resources: resources,
      importedDescriptor: descriptor,
      executionState: source.executionState,
      origin: origin),
    inputNames: inputNames,
    outputNames: outputNames,
    wasMapped: false)
}

private func mapNode(
  _ source: SourceNode,
  nodeID: PipelineNodeID,
  resources: [String: PipelineResourceBinding],
  origin: PipelineNodeOrigin,
  isPrimaryOutput: Bool
) -> ConvertedNode? {
  switch source.type {
  case "SaveVideo":
    // ComfyUI's dynamic format/codec controls can serialize nested settings.
    // The native output only represents the three simple string controls.
    guard source.widgets.count <= 3,
      source.widgets.allSatisfy({ $0 is String })
    else { return nil }
    guard let videoInput = source.inputs.firstIndex(where: {
      normalizedType($0.type) == "VIDEO"
    }), let videoOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "VIDEO"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[videoInput] = "video"
    outputNames[videoOutput] = "video"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "output.video"),
        title: source.title ?? "Video Output",
        parameters: mappedWidgetParameters(for: source, names: [
          "filename_prefix": "filenamePrefix", "format": "format", "codec": "codec",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "ResolutionSelector":
    guard let widthOutput = source.outputs.firstIndex(where: {
      $0.name == "width" && normalizedType($0.type) == "INT"
    }), let heightOutput = source.outputs.firstIndex(where: {
      $0.name == "height" && normalizedType($0.type) == "INT"
    }) else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[widthOutput] = "width"
    outputNames[heightOutput] = "height"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "input.resolution"),
        title: source.title ?? "Resolution",
        parameters: mappedWidgetParameters(for: source, names: [
          "aspect_ratio": "aspectRatio", "megapixels": "megapixels", "multiple": "multiple",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "MarkdownNote", "Note":
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "edit.markdownNote"),
        title: source.title ?? (source.type == "Note" ? "Note" : "Markdown Note"),
        parameters: mappedWidgetParameters(for: source, names: ["text": "text"]),
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: [String?](repeating: nil, count: source.outputs.count),
      wasMapped: true)

  case "VAELoader":
    guard let functionOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "VAE"
    }), let model = resources.values.first else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[functionOutput] = "function"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "coreai.vaeModel"),
        title: source.title ?? "VAE Model",
        parameters: mappedWidgetParameters(for: source, names: ["modelName": "modelName"]),
        resources: ["model": model],
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "VAEDecode", "VAEDecodeAudio":
    guard let latentInput = source.inputs.firstIndex(where: {
      $0.name == "samples" && normalizedType($0.type) == "LATENT"
    }), let vaeInput = source.inputs.firstIndex(where: {
      $0.name == "vae" && normalizedType($0.type) == "VAE"
    }) else { return nil }
    let isAudio = source.type == "VAEDecodeAudio"
    let resultType = isAudio ? "AUDIO" : "IMAGE"
    guard let resultOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == resultType
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[latentInput] = "latent"
    inputNames[vaeInput] = "vae"
    outputNames[resultOutput] = isAudio ? "audio" : "image"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID,
        kind: PipelineNodeKind(
          rawValue: isAudio ? "coreai.vaeAudioDecoder" : "coreai.vaeImageDecoder"),
        title: source.title ?? (isAudio ? "VAE Audio Decoder" : "VAE Image Decoder"),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "KSamplerSelect":
    guard let samplerOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "SAMPLER"
    }) else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[samplerOutput] = "function"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.samplerSelector"),
        title: source.title ?? "Sampler Selector",
        parameters: mappedWidgetParameters(
          for: source, names: ["sampler_name": "samplerName"]),
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "PrimitiveString":
    return mapPrimitive(
      source, nodeID: nodeID, kind: "primitive.string", sourceType: "STRING",
      title: "Text", origin: origin)

  case "PrimitiveStringMultiline":
    return mapPrimitive(
      source, nodeID: nodeID, kind: "primitive.string", sourceType: "STRING",
      title: "Text", origin: origin)

  case "PrimitiveInt":
    return mapPrimitive(
      source, nodeID: nodeID, kind: "primitive.int", sourceType: "INT",
      title: "Integer", origin: origin)

  case "PrimitiveFloat":
    return mapPrimitive(
      source, nodeID: nodeID, kind: "primitive.float", sourceType: "FLOAT",
      title: "Number", origin: origin)

  case "PrimitiveBoolean":
    return mapPrimitive(
      source, nodeID: nodeID, kind: "primitive.boolean", sourceType: "BOOLEAN",
      title: "Boolean", origin: origin)

  case "ComfySwitchNode":
    guard let conditionInput = source.inputs.firstIndex(where: {
      $0.name == "switch" && normalizedType($0.type) == "BOOLEAN"
    }), let falseInput = source.inputs.firstIndex(where: { $0.name == "on_false" }),
      let trueInput = source.inputs.firstIndex(where: { $0.name == "on_true" }),
      let valueOutput = source.outputs.indices.first
    else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[conditionInput] = "condition"
    inputNames[falseInput] = "falseValue"
    inputNames[trueInput] = "trueValue"
    outputNames[valueOutput] = "value"
    let parameters = source.widgets.first.map {
      ["condition": pipelineValue($0)]
    } ?? [:]
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "logic.ifElse"),
        title: source.title ?? "If/Else", parameters: parameters,
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "BasicScheduler":
    guard let modelInput = source.inputs.firstIndex(where: {
      $0.name == "model" && normalizedType($0.type) == "MODEL"
    }), let scheduleOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "SIGMAS"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[modelInput] = "denoiser"
    for name in ["scheduler", "steps", "denoise"] {
      if let index = source.inputs.firstIndex(where: { $0.name == name }) {
        inputNames[index] = name
      }
    }
    outputNames[scheduleOutput] = "schedule"
    let parameters = widgetParameters(for: source).filter {
      ["scheduler", "steps", "denoise"].contains($0.key)
    }
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.basicScheduler"),
        title: source.title ?? "Basic Scheduler", parameters: parameters,
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "Flux2Scheduler":
    guard let scheduleOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "SIGMAS"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    for name in ["width", "height"] {
      if let index = source.inputs.firstIndex(where: { $0.name == name }) {
        inputNames[index] = name
      }
    }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[scheduleOutput] = "schedule"
    let parameters = widgetParameters(for: source).filter {
      ["steps", "width", "height"].contains($0.key)
    }
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.flux2Scheduler"),
        title: source.title ?? "FLUX.2 Scheduler", parameters: parameters,
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "SamplerCustomAdvanced":
    let requiredInputs = [
      "noise": (type: "NOISE", name: "noise"),
      "guider": (type: "GUIDER", name: "guider"),
      "sampler": (type: "SAMPLER", name: "sampler"),
      "sigmas": (type: "SIGMAS", name: "schedule"),
      "latent_image": (type: "LATENT", name: "sourceLatent"),
    ]
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    for (sourceName, expected) in requiredInputs {
      guard let index = source.inputs.firstIndex(where: {
        $0.name == sourceName && normalizedType($0.type) == expected.type
      }) else { return nil }
      inputNames[index] = expected.name
    }
    guard let latentOutput = source.outputs.firstIndex(where: { $0.name == "output" }),
      let denoisedOutput = source.outputs.firstIndex(where: { $0.name == "denoised_output" })
    else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[latentOutput] = "latent"
    outputNames[denoisedOutput] = "denoisedLatent"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.advancedSampler"),
        title: source.title ?? "Advanced Sampler",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "BasicGuider":
    guard let modelInput = source.inputs.firstIndex(where: {
      $0.name == "model" && normalizedType($0.type) == "MODEL"
    }), let conditioningInput = source.inputs.firstIndex(where: {
      $0.name == "conditioning" && normalizedType($0.type) == "CONDITIONING"
    }), let guiderOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "GUIDER"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[modelInput] = "denoiser"
    inputNames[conditioningInput] = "conditioning"
    outputNames[guiderOutput] = "guider"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.basicGuider"),
        title: source.title ?? "Basic Guider",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "CFGGuider":
    let inputMap = [
      "model": "denoiser",
      "positive": "positive",
      "negative": "negative",
    ]
    guard inputMap.keys.allSatisfy({ name in source.inputs.contains { $0.name == name } }),
      let guiderOutput = source.outputs.firstIndex(where: {
        normalizedType($0.type) == "GUIDER"
      })
    else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[guiderOutput] = "guider"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.cfgGuider"),
        title: source.title ?? "CFG Guider",
        parameters: mappedWidgetParameters(for: source, names: ["cfg": "guidance"]),
        executionState: source.executionState, origin: origin),
      inputNames: source.inputs.map { inputMap[$0.name] },
      outputNames: outputNames,
      wasMapped: true)

  case "CLIPTextEncode":
    guard let encoderInput = source.inputs.firstIndex(where: {
      $0.name == "clip" && normalizedType($0.type) == "CLIP"
    }), let conditioningOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "CONDITIONING"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[encoderInput] = "textEncoder"
    if let textInput = source.inputs.firstIndex(where: { $0.name == "text" }) {
      inputNames[textInput] = "text"
    }
    outputNames[conditioningOutput] = "conditioning"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "conditioning.textEncode"),
        title: source.title ?? "Text Conditioning Encoder",
        parameters: mappedWidgetParameters(for: source, names: ["text": "text"]),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "ConditioningZeroOut":
    guard let conditioningInput = source.inputs.firstIndex(where: {
      $0.name == "conditioning" && normalizedType($0.type) == "CONDITIONING"
    }), let conditioningOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "CONDITIONING"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[conditioningInput] = "conditioning"
    outputNames[conditioningOutput] = "conditioning"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "conditioning.zero"),
        title: source.title ?? "Zero Conditioning",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "VAEEncode":
    guard let imageInput = source.inputs.firstIndex(where: {
      $0.name == "pixels" && normalizedType($0.type) == "IMAGE"
    }), let vaeInput = source.inputs.firstIndex(where: {
      $0.name == "vae" && normalizedType($0.type) == "VAE"
    }), let latentOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "LATENT"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[imageInput] = "image"
    inputNames[vaeInput] = "vae"
    outputNames[latentOutput] = "latent"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "coreai.vaeImageEncoder"),
        title: source.title ?? "VAE Image Encoder",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "EmptyFlux2LatentImage":
    guard let latentOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "LATENT"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    for name in ["width", "height"] {
      if let index = source.inputs.firstIndex(where: { $0.name == name }) {
        inputNames[index] = name
      }
    }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[latentOutput] = "latent"
    let parameters = widgetParameters(for: source).filter {
      ["width", "height", "batchSize"].contains($0.key)
    }
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "latent.emptyFlux2Image"),
        title: source.title ?? "Empty FLUX.2 Latent Image", parameters: parameters,
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "EmptySD3LatentImage", "EmptyLatentImage":
    guard let latentOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "LATENT"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    for name in ["width", "height"] {
      if let index = source.inputs.firstIndex(where: { $0.name == name }) {
        inputNames[index] = name
      }
    }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[latentOutput] = "latent"
    let parameters = widgetParameters(for: source).filter {
      ["width", "height", "batchSize"].contains($0.key)
    }
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "latent.emptyImage"),
        title: source.title ?? "Empty Latent Image", parameters: parameters,
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "ModelSamplingAuraFlow":
    guard let modelInput = source.inputs.firstIndex(where: {
      $0.name == "model" && normalizedType($0.type) == "MODEL"
    }), let modelOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "MODEL"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[modelInput] = "model"
    outputNames[modelOutput] = "model"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID,
        kind: PipelineNodeKind(rawValue: "diffusion.modelSamplingDiscreteFlow"),
        title: source.title ?? "Discrete Flow Model Sampling",
        parameters: mappedWidgetParameters(
          for: source, names: ["shift": "shift", "sampling": "sampling"]),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "KSampler":
    let requiredNames = ["model", "positive", "negative", "latent_image"]
    let inputMap = [
      "model": "model",
      "positive": "positive",
      "negative": "negative",
      "latent_image": "latent",
      "seed": "seed",
      "steps": "steps",
      "cfg": "guidance",
      "sampler_name": "sampler",
      "scheduler": "scheduler",
      "denoise": "denoise",
    ]
    guard requiredNames.allSatisfy({ name in source.inputs.contains { $0.name == name } }),
      let latentOutput = source.outputs.firstIndex(where: {
        normalizedType($0.type) == "LATENT"
      })
    else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[latentOutput] = "latent"
    let parameters = widgetParameters(for: source).filter {
      ["seed", "seedControl", "steps", "guidance", "sampler", "scheduler", "denoise"]
        .contains($0.key)
    }
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.kSampler"),
        title: source.title ?? "KSampler", parameters: parameters,
        executionState: source.executionState, origin: origin),
      inputNames: source.inputs.map { inputMap[$0.name] },
      outputNames: outputNames,
      wasMapped: true)

  case "GetImageSize":
    guard let imageInput = source.inputs.firstIndex(where: {
      normalizedType($0.type) == "IMAGE"
    }) else { return nil }
    let outputMap = ["width": "width", "height": "height", "batch_size": "batchSize"]
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    inputNames[imageInput] = "image"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "image.dimensions"),
        title: source.title ?? "Image Dimensions",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: source.outputs.map { outputMap[$0.name] },
      wasMapped: true)

  case "ReferenceLatent":
    guard let conditioningInput = source.inputs.firstIndex(where: {
      $0.name == "conditioning" && normalizedType($0.type) == "CONDITIONING"
    }), let latentInput = source.inputs.firstIndex(where: {
      $0.name == "latent" && normalizedType($0.type) == "LATENT"
    }), let conditioningOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "CONDITIONING"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[conditioningInput] = "conditioning"
    inputNames[latentInput] = "latent"
    outputNames[conditioningOutput] = "conditioning"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "conditioning.referenceLatent"),
        title: source.title ?? "Reference Latent Conditioning",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "ImageScaleToTotalPixels":
    guard let imageInput = source.inputs.firstIndex(where: {
      normalizedType($0.type) == "IMAGE"
    }), let imageOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "IMAGE"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[imageInput] = "image"
    outputNames[imageOutput] = "image"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "image.scaleToTotalPixels"),
        title: source.title ?? "Scale Image to Total Pixels",
        parameters: widgetParameters(for: source),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "LoadImage":
    guard source.inputs.allSatisfy(\.hasWidget),
      let imageOutput = source.outputs.firstIndex(where: { normalizedType($0.type) == "IMAGE" })
    else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[imageOutput] = "image"
    if let maskOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "MASK"
    }) {
      outputNames[maskOutput] = "mask"
    }
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "input.image"),
        title: source.title ?? "Source Image",
        parameters: mappedWidgetParameters(for: source, names: [
          "image": "sourceName", "upload": "uploadMode",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "Reroute":
    guard source.inputs.count == 1, let valueOutput = source.outputs.indices.first else {
      return nil
    }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[valueOutput] = "value"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "utility.reroute"),
        title: source.title ?? "Reroute",
        executionState: source.executionState, origin: origin),
      inputNames: ["value"],
      outputNames: outputNames,
      wasMapped: true)

  case "PreviewImage" where !isPrimaryOutput:
    // A secondary preview is a side output; only the primary output keeps
    // the terminal image kind that family adapters look for.
    guard let imageInput = source.inputs.firstIndex(where: {
      normalizedType($0.type) == "IMAGE"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    inputNames[imageInput] = "image"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "output.preview"),
        title: source.title ?? "Image Preview",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: [String?](repeating: nil, count: source.outputs.count),
      wasMapped: true)

  case "SaveImage", "SaveImageAdvanced", "PreviewImage":
    // SaveImageAdvanced's dynamic format may include CRF and animation options
    // that the native output has no parameters for.
    if source.type == "SaveImageAdvanced" {
      guard source.widgets.count <= 4,
        source.widgets.allSatisfy({ $0 is String })
      else { return nil }
    }
    guard let imageInput = source.inputs.firstIndex(where: {
      normalizedType($0.type) == "IMAGE"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[imageInput] = "image"
    if let imageOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "IMAGE"
    }) {
      outputNames[imageOutput] = "image"
    }
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "output.image"),
        title: source.title ?? "Image Output",
        parameters: mappedWidgetParameters(for: source, names: [
          "filename_prefix": "filenamePrefix", "format": "format",
          "bit_depth": "bitDepth", "input_color_space": "colorSpace",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "UNETLoader", "UnetLoaderGGUF":
    guard let modelOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "MODEL"
    }), let model = resources.values.first else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[modelOutput] = "function"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "coreai.denoiser"),
        title: source.title ?? "Denoiser",
        parameters: mappedWidgetParameters(for: source, names: [
          "modelName": "modelName", "weightType": "weightType",
        ]),
        resources: ["model": model],
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "CLIPLoader":
    guard let functionOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "CLIP"
    }), let model = resources.values.first else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[functionOutput] = "function"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "coreai.textEncoderModel"),
        title: source.title ?? "Text Encoder Model",
        parameters: mappedWidgetParameters(for: source, names: [
          "modelName": "modelName", "clipType": "encoderType", "device": "device",
        ]),
        resources: ["model": model],
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "RandomNoise":
    guard let noiseOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "NOISE"
    }) else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[noiseOutput] = "noise"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "latent.randomNoise"),
        title: source.title ?? "Random Noise",
        parameters: mappedWidgetParameters(for: source, names: [
          "seed": "seed", "seedControl": "seedControl",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "CreateVideo":
    guard source.widgets.count <= 4 else { return nil }
    guard let imagesInput = source.inputs.firstIndex(where: {
      $0.name == "images" && normalizedType($0.type) == "IMAGE"
    }), let videoOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "VIDEO"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[imagesInput] = "images"
    if let audioInput = source.inputs.firstIndex(where: {
      $0.name == "audio" && normalizedType($0.type) == "AUDIO"
    }) {
      inputNames[audioInput] = "audio"
    }
    outputNames[videoOutput] = "video"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "media.createVideo"),
        title: source.title ?? "Create Video",
        parameters: mappedWidgetParameters(for: source, names: [
          "fps": "framesPerSecond", "bit_depth": "bitDepth",
          "color_space": "colorSpace", "codec": "codec",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "ComfyMathExpression":
    guard let valueA = source.inputs.firstIndex(where: { $0.name == "values.a" }),
      let numberOutput = source.outputs.firstIndex(where: {
        normalizedType($0.type) == "FLOAT"
      }), let integerOutput = source.outputs.firstIndex(where: {
        normalizedType($0.type) == "INT"
      }), let booleanOutput = source.outputs.firstIndex(where: {
        normalizedType($0.type) == "BOOLEAN"
      })
    else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[valueA] = "a"
    if let valueB = source.inputs.firstIndex(where: { $0.name == "values.b" }) {
      inputNames[valueB] = "b"
    }
    outputNames[numberOutput] = "number"
    outputNames[integerOutput] = "integer"
    outputNames[booleanOutput] = "boolean"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "math.expression"),
        title: source.title ?? "Math Expression",
        parameters: mappedWidgetParameters(
          for: source, names: ["expression": "expression"]),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "MiniMaxH3ReferenceToVideo":
    let inputMap = [
      "clip": "textEncoder",
      "vae": "videoVAE",
      "audio_vae": "audioVAE",
      "ref_images.ref_image_0": "referenceImage1",
      "ref_images.ref_image_1": "referenceImage2",
      "ref_images.ref_image_2": "referenceImage3",
      "ref_videos.ref_video_0": "referenceVideo",
      "ref_video_audios.ref_video_audio_0": "referenceVideoAudio",
      "ref_audios.ref_audio_0": "referenceAudio",
      "prompt": "prompt",
      "width": "width",
      "height": "height",
      "length": "length",
    ]
    let requiredNames = ["clip", "vae", "audio_vae", "prompt", "width", "height", "length"]
    guard requiredNames.allSatisfy({ name in source.inputs.contains { $0.name == name } }),
      let conditioningOutput = source.outputs.firstIndex(where: {
        normalizedType($0.type) == "CONDITIONING"
      }), let latentOutput = source.outputs.firstIndex(where: {
        normalizedType($0.type) == "LATENT"
      })
    else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[conditioningOutput] = "conditioning"
    outputNames[latentOutput] = "latent"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID,
        kind: PipelineNodeKind(rawValue: "conditioning.referenceToVideo"),
        title: source.title ?? "Reference-to-Video Conditioning",
        parameters: mappedWidgetParameters(
          for: source, names: ["ref_image_size": "referenceImageSize"]),
        executionState: source.executionState, origin: origin),
      inputNames: source.inputs.map { inputMap[$0.name] },
      outputNames: outputNames,
      wasMapped: true)

  case "CheckpointLoaderSimple":
    guard let modelOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "MODEL"
    }), let encoderOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "CLIP"
    }), let vaeOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "VAE"
    }), let model = resources.values.first else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[modelOutput] = "model"
    outputNames[encoderOutput] = "textEncoder"
    outputNames[vaeOutput] = "vae"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "coreai.checkpoint"),
        title: source.title ?? "Checkpoint",
        parameters: mappedWidgetParameters(for: source, names: ["modelName": "modelName"]),
        resources: ["model": model],
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "EmptyHiDreamO1LatentImage":
    guard let latentOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "LATENT"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    for name in ["width", "height"] {
      if let index = source.inputs.firstIndex(where: { $0.name == name }) {
        inputNames[index] = name
      }
    }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[latentOutput] = "latent"
    let parameters = widgetParameters(for: source).filter {
      ["width", "height", "batchSize"].contains($0.key)
    }
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "latent.emptyHiDreamO1Image"),
        title: source.title ?? "Empty HiDream-O1 Latent Image", parameters: parameters,
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "HiDreamO1ReferenceImages":
    guard let positiveInput = source.inputs.firstIndex(where: {
      $0.name == "positive" && normalizedType($0.type) == "CONDITIONING"
    }), let negativeInput = source.inputs.firstIndex(where: {
      $0.name == "negative" && normalizedType($0.type) == "CONDITIONING"
    }), let positiveOutput = source.outputs.firstIndex(where: { $0.name == "positive" }),
      let negativeOutput = source.outputs.firstIndex(where: { $0.name == "negative" })
    else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    inputNames[positiveInput] = "positive"
    inputNames[negativeInput] = "negative"
    for slot in 1...referenceImageSlotLimit {
      guard let index = source.inputs.firstIndex(where: {
        $0.name == "images.image_\(slot)"
      }) else { continue }
      inputNames[index] = "referenceImage\(slot)"
    }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[positiveOutput] = "positive"
    outputNames[negativeOutput] = "negative"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID,
        kind: PipelineNodeKind(rawValue: "conditioning.hiDreamO1ReferenceImages"),
        title: source.title ?? "HiDream-O1 Reference Images",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "HiDreamO1PatchSeamSmoothing":
    guard let modelInput = source.inputs.firstIndex(where: {
      $0.name == "model" && normalizedType($0.type) == "MODEL"
    }), let modelOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "MODEL"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[modelInput] = "model"
    outputNames[modelOutput] = "model"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID,
        kind: PipelineNodeKind(rawValue: "diffusion.hiDreamO1SeamSmoothing"),
        title: source.title ?? "HiDream-O1 Patch Seam Smoothing",
        parameters: mappedWidgetParameters(for: source, names: [
          "start_percent": "startPercent", "end_percent": "endPercent",
          "pattern": "pattern", "passes": "passes", "blend": "blend",
          "strength": "strength",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "ModelNoiseScale":
    guard let modelInput = source.inputs.firstIndex(where: {
      $0.name == "model" && normalizedType($0.type) == "MODEL"
    }), let modelOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "MODEL"
    }) else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[modelInput] = "model"
    outputNames[modelOutput] = "model"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.modelNoiseScale"),
        title: source.title ?? "Model Noise Scale",
        parameters: mappedWidgetParameters(
          for: source, names: ["noise_scale": "noiseScale"]),
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "SamplerCustom":
    let inputMap = [
      "model": "denoiser",
      "positive": "positive",
      "negative": "negative",
      "sampler": "sampler",
      "sigmas": "schedule",
      "latent_image": "sourceLatent",
    ]
    guard inputMap.keys.allSatisfy({ name in source.inputs.contains { $0.name == name } }),
      let latentOutput = source.outputs.firstIndex(where: { $0.name == "output" }),
      let denoisedOutput = source.outputs.firstIndex(where: { $0.name == "denoised_output" })
    else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[latentOutput] = "latent"
    outputNames[denoisedOutput] = "denoisedLatent"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.customSampler"),
        title: source.title ?? "Custom Sampler",
        parameters: mappedWidgetParameters(for: source, names: [
          "add_noise": "addNoise", "seed": "seed", "seedControl": "seedControl",
          "cfg": "guidance",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: source.inputs.map { inputMap[$0.name] },
      outputNames: outputNames,
      wasMapped: true)

  case "SamplerLCM":
    guard let samplerOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "SAMPLER"
    }) else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[samplerOutput] = "function"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "diffusion.lcmSampler"),
        title: source.title ?? "LCM Sampler",
        parameters: mappedWidgetParameters(for: source, names: [
          "s_noise": "stepNoise", "s_noise_end": "endStepNoise",
          "noise_clip_std": "noiseClipStandardDeviations",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: outputNames,
      wasMapped: true)

  case "TextEncodeQwenImage21":
    var inputMap = [
      "clip": "textEncoder",
      "vae": "vae",
      "prompt": "prompt",
      "negative_prompt": "negativePrompt",
    ]
    for slot in 1...qwenReferenceImageSlotLimit {
      inputMap["images.image_\(slot)"] = "referenceImage\(slot)"
    }
    guard source.inputs.contains(where: { $0.name == "clip" }),
      let positiveOutput = source.outputs.firstIndex(where: { $0.name == "positive" }),
      let negativeOutput = source.outputs.firstIndex(where: { $0.name == "negative" }),
      let latentOutput = source.outputs.firstIndex(where: { $0.name == "latent" })
    else { return nil }
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[positiveOutput] = "positive"
    outputNames[negativeOutput] = "negative"
    outputNames[latentOutput] = "latent"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID,
        kind: PipelineNodeKind(rawValue: "conditioning.qwenImage21TextEncode"),
        title: source.title ?? "Qwen-Image 2.1 Text Encoder",
        parameters: mappedWidgetParameters(for: source, names: [
          "prompt": "prompt", "negative_prompt": "negativePrompt",
          "resolution": "resolution",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: source.inputs.map { inputMap[$0.name] },
      outputNames: outputNames,
      wasMapped: true)

  case "StringConcatenate":
    return mapTextNode(
      source, nodeID: nodeID, kind: "text.concatenate", title: "Concatenate Text",
      inputMap: ["string_a": "stringA", "string_b": "stringB", "delimiter": "delimiter"],
      parameterMap: [
        "string_a": "stringA", "string_b": "stringB", "delimiter": "delimiter",
      ],
      origin: origin)

  case "StringReplace":
    return mapTextNode(
      source, nodeID: nodeID, kind: "text.replace", title: "Replace Text",
      inputMap: ["string": "string", "find": "find", "replace": "replace"],
      parameterMap: ["string": "string", "find": "find", "replace": "replace"],
      origin: origin)

  case "RegexReplace":
    return mapTextNode(
      source, nodeID: nodeID, kind: "text.regexReplace", title: "Replace Text (Regex)",
      inputMap: [
        "string": "string", "regex_pattern": "pattern", "replace": "replacement",
        "case_insensitive": "caseInsensitive", "multiline": "multiline",
        "dotall": "dotAll", "count": "count",
      ],
      parameterMap: [
        "string": "string", "regex_pattern": "pattern", "replace": "replacement",
        "case_insensitive": "caseInsensitive", "multiline": "multiline",
        "dotall": "dotAll", "count": "count",
      ],
      origin: origin)

  case "JsonExtractString":
    return mapTextNode(
      source, nodeID: nodeID, kind: "text.jsonExtract", title: "Extract Text from JSON",
      inputMap: ["json_string": "json", "key": "key"],
      parameterMap: ["json_string": "json", "key": "key"],
      origin: origin)

  case "TextGenerate":
    // The current native node cannot represent ComfyUI's second output or
    // the dynamic sampling, thinking, and template controls.
    guard source.outputs.count == 1, source.widgets.count <= 3,
      source.widgets.allSatisfy({ !($0 is [String: Any]) })
    else { return nil }
    guard source.inputs.contains(where: {
      $0.name == "clip" && normalizedType($0.type) == "CLIP"
    }), let textOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "STRING"
    }) else { return nil }
    let inputMap = [
      "clip": "textEncoder",
      "prompt": "prompt",
      "image": "image",
      "video": "video",
      "audio": "audio",
    ]
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    outputNames[textOutput] = "text"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "text.generate"),
        title: source.title ?? "Generate Text",
        // Only the three widgets that precede ComfyUI's dynamic sampling group
        // hold a stable position; the rest stay in the origin metadata.
        parameters: mappedWidgetParameters(for: source, names: [
          "prompt": "prompt", "max_length": "maxLength",
          "sampling_mode": "samplingMode",
        ]),
        executionState: source.executionState, origin: origin),
      inputNames: source.inputs.map { inputMap[$0.name] },
      outputNames: outputNames,
      wasMapped: true)

  case "PreviewAny":
    guard let valueInput = source.inputs.indices.first,
      let textOutput = source.outputs.firstIndex(where: {
        normalizedType($0.type) == "STRING"
      })
    else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[valueInput] = "value"
    outputNames[textOutput] = "text"
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "utility.previewAny"),
        title: source.title ?? "Preview as Text",
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  case "LoraLoaderModelOnly":
    guard let baseInput = source.inputs.firstIndex(where: {
      normalizedType($0.type) == "MODEL"
    }), let modelOutput = source.outputs.firstIndex(where: {
      normalizedType($0.type) == "MODEL"
    }), let adapter = resources.values.first else { return nil }
    var inputNames = [String?](repeating: nil, count: source.inputs.count)
    var outputNames = [String?](repeating: nil, count: source.outputs.count)
    inputNames[baseInput] = "base"
    outputNames[modelOutput] = "function"
    let weight = source.widgets.dropFirst().first.flatMap(double) ?? 1
    return ConvertedNode(
      node: PipelineNode(
        id: nodeID, kind: PipelineNodeKind(rawValue: "coreai.adapter"),
        title: source.title ?? "LoRA Adapter",
        parameters: [
          "modelName": source.widgets.first.map(pipelineValue) ?? .string(""),
          "weight": .number(weight),
        ],
        resources: ["adapter": adapter],
        executionState: source.executionState, origin: origin),
      inputNames: inputNames,
      outputNames: outputNames,
      wasMapped: true)

  default:
    if let expanded = expandNode(
      source, nodeID: nodeID, resources: resources, origin: origin)
    {
      return expanded
    }
    guard let mapping = ComfyUIWorkflowConverter.nodeMappings[source.type] else { return nil }
    return mapDeclaredNode(
      source, mapping: mapping, nodeID: nodeID, resources: resources, origin: origin)
  }
}

private func mapDeclaredNode(
  _ source: SourceNode,
  mapping: ComfyUINodeMapping,
  nodeID: PipelineNodeID,
  resources: [String: PipelineResourceBinding],
  origin: PipelineNodeOrigin
) -> ConvertedNode? {
  guard mapping.requiredInputs.allSatisfy({ name in source.inputs.contains { $0.name == name } }),
    source.outputs.count == mapping.outputs.count,
    (mapping.allowsAdditionalWidgets || source.widgets.count <= mapping.widgets.count)
  else { return nil }
  var outputNames = [String?](repeating: nil, count: source.outputs.count)
  for (index, output) in mapping.outputs.enumerated() {
    guard output.type == "*" || normalizedType(source.outputs[index].type) == output.type
    else { return nil }
    outputNames[index] = output.name
  }
  var boundResources: [String: PipelineResourceBinding] = [:]
  for (sourceSlot, nativeSlot) in mapping.resources {
    guard let resource = resources[sourceSlot] else { return nil }
    boundResources[nativeSlot] = resource
  }
  return ConvertedNode(
    node: PipelineNode(
      id: nodeID, kind: PipelineNodeKind(rawValue: mapping.kind),
      title: source.title ?? mapping.title,
      parameters: mappedWidgetParameters(for: source, names: mapping.parameters),
      resources: boundResources,
      executionState: source.executionState, origin: origin),
    inputNames: source.inputs.map { mapping.inputs[$0.name] },
    outputNames: outputNames,
    wasMapped: true)
}

private func mapPrimitive(
  _ source: SourceNode,
  nodeID: PipelineNodeID,
  kind: String,
  sourceType: String,
  title: String,
  origin: PipelineNodeOrigin
) -> ConvertedNode? {
  guard let valueOutput = source.outputs.firstIndex(where: {
    normalizedType($0.type) == sourceType
  }) else { return nil }
  var inputNames = [String?](repeating: nil, count: source.inputs.count)
  var outputNames = [String?](repeating: nil, count: source.outputs.count)
  if let valueInput = source.inputs.firstIndex(where: {
    $0.name == "value" && normalizedType($0.type) == sourceType
  }) {
    inputNames[valueInput] = "value"
  }
  outputNames[valueOutput] = "value"
  let parameters = source.widgets.first.map { ["value": pipelineValue($0)] } ?? [:]
  return ConvertedNode(
    node: PipelineNode(
      id: nodeID,
      kind: PipelineNodeKind(rawValue: kind),
      title: source.title ?? title,
      parameters: parameters,
      executionState: source.executionState,
      origin: origin),
    inputNames: inputNames,
    outputNames: outputNames,
    wasMapped: true)
}

/// HiDream-O1 exposes an autogrowing reference-image socket list. ComfyUI
/// declares 100 sockets; its model card documents ten reference images as the
/// practical maximum, which is what the installed descriptor carries.
private let referenceImageSlotLimit = 10

/// Qwen-Image 2.1 exposes sixteen reference-image sockets. Eight cover the
/// published templates and keep the installed descriptor readable.
private let qwenReferenceImageSlotLimit = 8

/// Shared shape for ComfyUI's string utility nodes: named string inputs and
/// widgets in, one string out.
private func mapTextNode(
  _ source: SourceNode,
  nodeID: PipelineNodeID,
  kind: String,
  title: String,
  inputMap: [String: String],
  parameterMap: [String: String],
  origin: PipelineNodeOrigin
) -> ConvertedNode? {
  guard let valueOutput = source.outputs.firstIndex(where: {
    normalizedType($0.type) == "STRING"
  }) else { return nil }
  var outputNames = [String?](repeating: nil, count: source.outputs.count)
  outputNames[valueOutput] = "value"
  return ConvertedNode(
    node: PipelineNode(
      id: nodeID,
      kind: PipelineNodeKind(rawValue: kind),
      title: source.title ?? title,
      parameters: mappedWidgetParameters(for: source, names: parameterMap),
      executionState: source.executionState,
      origin: origin),
    inputNames: source.inputs.map { inputMap[$0.name] },
    outputNames: outputNames,
    wasMapped: true)
}

func mappedWidgetParameters(
  for source: SourceNode,
  names: [String: String]
) -> [String: PipelineValue] {
  let sourceParameters = widgetParameters(for: source)
  return Dictionary(uniqueKeysWithValues: names.compactMap { sourceName, destinationName in
    sourceParameters[sourceName].map { (destinationName, $0) }
  })
}

private func extractResources(from node: SourceNode) -> [String: PipelineResourceBinding] {
  var requirements: [(role: String, kind: PipelineResourceKind, name: String, url: String?)] = []
  if let models = node.properties["models"] as? [Any] {
    for value in models {
      guard let model = value as? [String: Any], let name = model["name"] as? String else {
        continue
      }
      let directory = model["directory"] as? String
      requirements.append((
        role: resourceRole(nodeType: node.type, directory: directory),
        kind: resourceKind(nodeType: node.type, directory: directory),
        name: directory.map { "\($0)/\(name)" } ?? name,
        url: model["url"] as? String))
    }
  }
  if requirements.isEmpty, isResourceLoader(node.type) {
    // Loaders name their models in their leading widgets.
    for value in node.widgets.prefix(resourceWidgetCount(node.type)) {
      guard let name = value as? String else { break }
      requirements.append((
        role: resourceRole(nodeType: node.type, directory: nil),
        kind: resourceKind(nodeType: node.type, directory: nil),
        name: name,
        url: nil))
    }
  }

  var resources: [String: PipelineResourceBinding] = [:]
  var roleCounts: [String: Int] = [:]
  for requirement in requirements {
    let count = roleCounts[requirement.role, default: 0]
    roleCounts[requirement.role] = count + 1
    let slot = count == 0 ? requirement.role : "\(requirement.role)-\(count + 1)"
    let pathExtension = URL(fileURLWithPath: requirement.name).pathExtension
    resources[slot] = .unresolved(PipelineResourceRequirement(
      kind: requirement.kind,
      componentRole: requirement.role,
      sourceName: requirement.name,
      sourceFormat: pathExtension.isEmpty ? nil : pathExtension.lowercased(),
      sourceURL: requirement.url))
  }
  return resources
}

private func isResourceLoader(_ type: String) -> Bool {
  switch type {
  case "UNETLoader", "UnetLoaderGGUF", "CLIPLoader", "VAELoader", "LoraLoader",
    "LoraLoaderModelOnly", "CheckpointLoaderSimple", "UpscaleModelLoader",
    "DownloadAndLoadFlorence2Model", "DualCLIPLoader", "TripleCLIPLoader", "ControlNetLoader",
    "CLIPVisionLoader", "StyleModelLoader":
    true
  default:
    false
  }
}

private func resourceWidgetCount(_ type: String) -> Int {
  switch type {
  case "DualCLIPLoader": 2
  case "TripleCLIPLoader": 3
  default: 1
  }
}

private func resourceRole(nodeType: String, directory: String?) -> String {
  let directory = directory?.lowercased() ?? ""
  if nodeType.localizedCaseInsensitiveContains("lora") || directory.contains("lora") {
    return "adapter"
  }
  if nodeType.localizedCaseInsensitiveContains("controlnet") || directory.contains("controlnet") {
    return "controlNet"
  }
  // Checked before the text-encoder rule, which also matches "CLIP".
  if nodeType.localizedCaseInsensitiveContains("clipvision") || directory.contains("clip_vision") {
    return "visionEncoder"
  }
  if nodeType.localizedCaseInsensitiveContains("stylemodel") || directory.contains("style_model") {
    return "styleModel"
  }
  if nodeType.localizedCaseInsensitiveContains("clip") || directory.contains("text_encoder") {
    return "textEncoder"
  }
  if nodeType.localizedCaseInsensitiveContains("vae") || directory.contains("vae") {
    return "vae"
  }
  if nodeType.localizedCaseInsensitiveContains("upscale") || directory.contains("upscale") {
    return "upscaler"
  }
  if nodeType.localizedCaseInsensitiveContains("florence") { return "visionModel" }
  return "denoiser"
}

private func resourceKind(nodeType: String, directory: String?) -> PipelineResourceKind {
  resourceRole(nodeType: nodeType, directory: directory) == "adapter" ? .adapter : .coreAIModel
}

func widgetParameters(for node: SourceNode) -> [String: PipelineValue] {
  let names = widgetNames(for: node)
  return Dictionary(uniqueKeysWithValues: node.widgets.enumerated().map { index, value in
    (names[index], pipelineValue(value))
  })
}

private func widgetNames(for node: SourceNode) -> [String] {
  let known: [String]
  switch node.type {
  case "SaveVideo": known = ["filename_prefix", "format", "codec"]
  case "ResolutionSelector": known = ["aspect_ratio", "megapixels", "multiple"]
  case "MarkdownNote", "Note": known = ["text"]
  case "EmptyLatentImage", "EmptySD3LatentImage": known = ["width", "height", "batchSize"]
  case "KSampler":
    known = ["seed", "seedControl", "steps", "guidance", "sampler", "scheduler", "denoise"]
  case "UNETLoader", "UnetLoaderGGUF": known = ["modelName", "weightType"]
  case "CLIPLoader": known = ["modelName", "clipType", "device"]
  case "VAELoader": known = ["modelName"]
  case "LoraLoaderModelOnly": known = ["modelName", "weight"]
  case "CLIPTextEncode": known = ["text"]
  case "LoadImage": known = ["image", "upload"]
  case "RandomNoise": known = ["seed", "seedControl"]
  case "Flux2Scheduler": known = ["steps", "width", "height"]
  case "CFGGuider": known = ["cfg"]
  case "EmptyFlux2LatentImage": known = ["width", "height", "batchSize"]
  case "ModelSamplingAuraFlow": known = ["shift", "sampling"]
  case "ImageScaleToTotalPixels": known = ["upscaleMethod", "megapixels", "resolution"]
  case "KSamplerSelect": known = ["sampler_name"]
  case "CreateVideo": known = ["fps", "bit_depth", "color_space", "codec"]
  case "ComfyMathExpression": known = ["expression"]
  case "MiniMaxH3ReferenceToVideo":
    known = ["prompt", "width", "height", "length", "ref_image_size"]
  case "PrimitiveString", "PrimitiveStringMultiline", "PrimitiveInt", "PrimitiveFloat",
    "PrimitiveBoolean": known = ["value"]
  case "ComfySwitchNode": known = ["switch"]
  case "BasicScheduler": known = ["scheduler", "steps", "denoise"]
  case "CheckpointLoaderSimple": known = ["modelName"]
  case "EmptyHiDreamO1LatentImage": known = ["width", "height", "batchSize"]
  case "HiDreamO1PatchSeamSmoothing":
    known = ["start_percent", "end_percent", "pattern", "passes", "blend", "strength"]
  case "ModelNoiseScale": known = ["noise_scale"]
  case "SamplerCustom": known = ["add_noise", "seed", "seedControl", "cfg"]
  case "SamplerLCM": known = ["s_noise", "s_noise_end", "noise_clip_std"]
  case "TextEncodeQwenImage21": known = ["prompt", "negative_prompt", "resolution"]
  case "StringConcatenate": known = ["string_a", "string_b", "delimiter"]
  case "StringReplace": known = ["string", "find", "replace"]
  case "RegexReplace":
    known = [
      "string", "regex_pattern", "replace", "case_insensitive", "multiline", "dotall",
      "count",
    ]
  case "JsonExtractString": known = ["json_string", "key"]
  // ComfyUI expands the sampling-mode group inline, so only the three leading
  // widgets keep a stable position.
  case "TextGenerate": known = ["prompt", "max_length", "sampling_mode"]
  case "SaveImage", "PreviewImage": known = ["filename_prefix"]
  case "SaveImageAdvanced":
    known = ["filename_prefix", "format", "bit_depth", "input_color_space"]
  default:
    known = ComfyUIWorkflowConverter.nodeMappings[node.type]?.widgets
      ?? expandedNodeWidgets[node.type]
      ?? node.inputs.filter(\.hasWidget).map(\.name)
  }
  var used: Set<String> = []
  return node.widgets.indices.map { index in
    let proposed = known.indices.contains(index) ? known[index] : "widget-\(index)"
    if used.insert(proposed).inserted { return proposed }
    let unique = "\(proposed)-\(index)"
    used.insert(unique)
    return unique
  }
}

/// Lays a subgraph out as a grid at the source node's position and frames it
/// with a group named after the source node.
private func layOutSubgraph(
  _ converted: ConvertedNode,
  source: SourceNode,
  presentation: inout PipelinePresentation
) {
  // Subgraph nodes are built from inputs to result; the result lands last.
  let nodes = (converted.expansion?.nodes ?? []) + [converted.node]
  guard let origin = presentation.nodePositions[converted.node.id.rawValue] else { return }
  let nodeSize = PipelineSize(width: 220, height: 120)
  let columns = min(nodes.count, 3)
  let rows = (nodes.count + columns - 1) / columns
  for (index, node) in nodes.enumerated() {
    presentation.nodePositions[node.id.rawValue] = PipelinePoint(
      x: origin.x + Double(index % columns) * 260,
      y: origin.y + Double(index / columns) * 180)
    presentation.nodeSizes[node.id.rawValue] = nodeSize
  }
  presentation.groups.append(PipelinePresentationGroup(
    id: "comfyui-subgraph-\(source.id)",
    title: source.title ?? source.type,
    origin: PipelinePoint(x: origin.x - 20, y: origin.y - 50),
    size: PipelineSize(
      width: Double(columns - 1) * 260 + nodeSize.width + 40,
      height: Double(rows - 1) * 180 + nodeSize.height + 70),
    metadata: [
      "sourceNodeID": .string(source.id),
      "sourceType": .string(source.type),
      "nodeIDs": .array(nodes.map { .string($0.id.rawValue) }),
    ]))
}

private func makePresentation(
  root: [String: Any],
  nodes: [SourceNode]
) -> PipelinePresentation {
  let minimumX = nodes.map(\.position.x).min() ?? 0
  let minimumY = nodes.map(\.position.y).min() ?? 0
  let shiftX = minimumX < 80 ? 80 - minimumX : 0
  let shiftY = minimumY < 80 ? 80 - minimumY : 0
  let positions = Dictionary(uniqueKeysWithValues: nodes.map {
    ("comfyui-node-\($0.id)", PipelinePoint(
      x: $0.position.x + shiftX,
      y: $0.position.y + shiftY))
  })
  let sizes = Dictionary(uniqueKeysWithValues: nodes.map {
    ("comfyui-node-\($0.id)", $0.size)
  })
  let rawGroups = root["groups"] as? [Any] ?? []
  let groups = rawGroups.enumerated().compactMap { index, value -> PipelinePresentationGroup? in
    guard let object = value as? [String: Any],
      let bounds = object["bounding"] as? [Any], bounds.count >= 4,
      let x = double(bounds[0]), let y = double(bounds[1]),
      let width = double(bounds[2]), let height = double(bounds[3])
    else { return nil }
    return PipelinePresentationGroup(
      id: scalarString(object["id"]) ?? "comfyui-group-\(index)",
      title: object["title"] as? String ?? "Group \(index + 1)",
      origin: PipelinePoint(x: x + shiftX, y: y + shiftY),
      size: PipelineSize(width: width, height: height),
      color: object["color"] as? String,
      metadata: object.compactMapValues { pipelineValue($0) })
  }
  let ds = (root["extra"] as? [String: Any])?["ds"] as? [String: Any]
  let scale = ds.flatMap { double($0["scale"]) }
  return PipelinePresentation(
    nodePositions: positions,
    nodeSizes: sizes,
    groups: groups,
    viewportOrigin: PipelinePoint(x: 0, y: 0),
    viewportScale: scale)
}

private func choosePrimaryOutput(in nodes: [SourceNode]) -> String? {
  let priorities = [
    "SaveImage", "SaveImageAdvanced", "PreviewImage", "SaveVideo", "CreateVideo", "SaveAudio",
  ]
  for type in priorities {
    if let node = nodes.first(where: { $0.executionState == .enabled && $0.type == type }) {
      return node.id
    }
  }
  return nodes.first(where: { $0.executionState == .enabled && $0.outputs.isEmpty })?.id
}

private func inferMode(from nodes: [SourceNode]) -> PipelineMode {
  let activeTypes = nodes.filter { $0.executionState == .enabled }.map(\.type)
  if activeTypes.contains("SaveVideo") || activeTypes.contains("CreateVideo") { return .generic }
  let inpaintingTypes = ["VAEEncodeForInpaint", "InpaintModelConditioning", "SetLatentNoiseMask"]
  if activeTypes.contains(where: { inpaintingTypes.contains($0) }) { return .inpainting }
  if activeTypes.contains("LoadImage") || activeTypes.contains("VAEEncode") { return .imageToImage }
  if activeTypes.contains("SaveImage") || activeTypes.contains("SaveImageAdvanced")
    || activeTypes.contains("PreviewImage")
  {
    return .textToImage
  }
  return .generic
}

private func importedKind(_ type: String) -> PipelineNodeKind {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
  let sanitized = type.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
  return PipelineNodeKind(rawValue: "comfyui." + String(sanitized))
}

private func pipelinePortType(_ source: String) -> PipelinePortType {
  switch normalizedType(source) {
  case "IMAGE": .image
  case "MASK": .mask
  case "VIDEO": .video
  case "AUDIO": .audio
  case "LATENT": .latent
  case "CONDITIONING": .conditioning
  case "MODEL": .modelFunction
  case "CLIP": .textEncoderFunction
  case "VAE": .vaeFunction
  case "SAMPLER": .samplerFunction
  case "UPSCALE_MODEL": .upscaleModelFunction
  case "CONTROL_NET": .controlNetFunction
  case "CLIP_VISION": .visionEncoderFunction
  case "CLIP_VISION_OUTPUT": .visionEmbedding
  case "STYLE_MODEL": .styleModelFunction
  case "GUIDER": .guider
  case "NOISE": .noise
  case "SEED": .seed
  case "BOOLEAN": .boolean
  case "INT": .integer
  case "FLOAT": .number
  case "STRING", "COMBO": .string
  case "SIGMAS": .schedule
  case "ANY", "*", "FLOAT,INT,BOOLEAN", "FLOAT|INT|BOOLEAN": .any
  default: PipelinePortType(rawValue: "comfyui.\(normalizedType(source))")
  }
}

func normalizedType(_ source: String) -> String {
  source.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

private func parameterType(_ value: PipelineValue) -> PipelineParameterValueType {
  switch value {
  case .boolean: .boolean
  case .integer: .integer
  case .number: .number
  case .string: .string
  case .array: .array
  case .object: .object
  case .null: .any
  }
}

private func pipelineValue(_ value: Any) -> PipelineValue {
  if value is NSNull { return .null }
  if let value = value as? String { return .string(value) }
  if let value = value as? NSNumber {
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return .boolean(value.boolValue) }
    let number = value.doubleValue
    if number.rounded() == number, number >= Double(Int64.min), number <= Double(Int64.max) {
      return .integer(value.int64Value)
    }
    return .number(number)
  }
  if let value = value as? [Any] { return .array(value.map(pipelineValue)) }
  if let value = value as? [String: Any] { return .object(value.mapValues(pipelineValue)) }
  return .string(String(describing: value))
}

private func typeString(_ value: Any?) -> String {
  if let value = value as? String { return value }
  if let values = value as? [Any] {
    return values.compactMap { $0 as? String }.joined(separator: "|")
  }
  return "ANY"
}

private func scalarString(_ value: Any?) -> String? {
  if let value = value as? String { return value }
  if let value = value as? NSNumber { return value.stringValue }
  return nil
}

private func integer(_ value: Any?) -> Int? {
  if let value = value as? NSNumber { return value.intValue }
  if let value = value as? String { return Int(value) }
  return nil
}

private func double(_ value: Any?) -> Double? {
  if let value = value as? NSNumber { return value.doubleValue }
  if let value = value as? String { return Double(value) }
  return nil
}

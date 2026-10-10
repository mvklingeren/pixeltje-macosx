import CryptoKit
import Foundation

public enum PipelineJSON {
  public static func decode(_ data: Data) throws -> PipelineDocument {
    var document = try JSONDecoder().decode(PipelineDocument.self, from: data)
    if document.schemaVersion == 1 {
      document.schemaVersion = PipelineDocument.currentSchemaVersion
    }
    // The former multiline kind used the same ports and executor as Text.
    // Canonicalize saved graphs so old workflows use the single string node.
    for index in document.nodes.indices where
      document.nodes[index].kind.rawValue == "primitive.string.multiline" {
      document.nodes[index].kind = PipelineNodeKind(rawValue: "primitive.string")
    }
    return document
  }

  public static func encode(
    _ document: PipelineDocument,
    prettyPrinted: Bool = true
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return try encoder.encode(document)
  }

  /// Digest of execution semantics. Editor layout is intentionally excluded.
  public static func semanticSHA256(_ document: PipelineDocument) throws -> String {
    var semanticDocument = document
    semanticDocument.presentation = nil
    semanticDocument.connections = semanticDocument.connections.map {
      PipelineConnection(output: $0.output, input: $0.input)
    }
    semanticDocument.controlConnections = semanticDocument.controlConnections.map {
      PipelineConnection(output: $0.output, input: $0.input)
    }
    let digest = SHA256.hash(data: try encode(semanticDocument, prettyPrinted: false))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// The inputs that can fill one Asset Cache. Loop controls and consumers
  /// outside this branch do not change the cached bundle.
  public static func assetCacheSHA256(
    _ document: PipelineDocument, nodeID: PipelineNodeID
  ) throws -> String {
    var upstream: Set<PipelineNodeID> = [nodeID]
    var pending = [nodeID]
    while let current = pending.popLast() {
      for connection in document.connections where connection.input.nodeID == current {
        if upstream.insert(connection.output.nodeID).inserted {
          pending.append(connection.output.nodeID)
        }
      }
    }
    var branch = document
    branch.nodes = document.nodes.filter { upstream.contains($0.id) }
    branch.connections = document.connections.filter {
      upstream.contains($0.output.nodeID) && upstream.contains($0.input.nodeID)
    }
    branch.controlConnections = document.controlConnections.filter {
      upstream.contains($0.output.nodeID) && upstream.contains($0.input.nodeID)
    }
    branch.primaryOutputNodeIDs = [nodeID]
    return try semanticSHA256(branch)
  }
}

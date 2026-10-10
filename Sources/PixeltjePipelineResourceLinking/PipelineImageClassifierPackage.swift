import Foundation
import PixeltjePipelineDomain

/// Link-only identity for a single Core AI image classifier package.
public enum PipelineImageClassifierPackage {
  public static let nodeKind = PipelineNodeKind(rawValue: "coreai.imageClassifier")
  public static let unlinkedPackageID = "coreai.classifier.unlinked"

  public static var unresolved: PipelineResourceBinding {
    .unresolved(.init(kind: .coreAIModel, componentRole: "classifier",
      sourceName: "Choose a trained image classifier .aimodel",
      sourceFormat: "aimodel"))
  }

  public static func mnistWorkflow() -> PipelineDocument {
    let imageID = PipelineNodeID(rawValue: "digit-image")
    let classifierID = PipelineNodeID(rawValue: "digit-classifier")
    let outputID = PipelineNodeID(rawValue: "digit-output")
    return PipelineDocument(id: .init(rawValue: UUID().uuidString.lowercased()),
      name: "Recognize MNIST Digit", mode: .generic,
      nodes: [
        PipelineNode(id: imageID, kind: .init(rawValue: "input.image"),
          title: "Digit Image", parameters: ["sourceName": .string("")]),
        PipelineNode(id: classifierID, kind: nodeKind,
          title: "Core AI Image Classifier",
          parameters: [
            "inputName": .string("image"), "outputName": .string("scores"),
            "width": .integer(28), "height": .integer(28),
            "channels": .integer(1), "classLabels": .string(""),
          ], resources: ["model": unresolved]),
        PipelineNode(id: outputID, kind: .init(rawValue: "output.text"),
          title: "Recognized Number"),
      ],
      connections: [
        .init(output: .init(nodeID: imageID, port: "image"),
          input: .init(nodeID: classifierID, port: "image")),
        .init(output: .init(nodeID: classifierID, port: "prediction"),
          input: .init(nodeID: outputID, port: "text")),
      ],
      primaryOutputNodeIDs: [outputID],
      presentation: .init(nodePositions: [
        imageID.rawValue: .init(x: 60, y: 170),
        classifierID.rawValue: .init(x: 350, y: 170),
        outputID.rawValue: .init(x: 670, y: 170),
      ]))
  }

  public static func link(_ document: PipelineDocument, at selectedURL: URL,
    replacingPackageID: String, nodeID: PipelineNodeID? = nil
  ) throws -> (document: PipelineDocument, packageID: String) {
    let hash = try contentHash(at: selectedURL)
    let packageID = "coreai.classifier.\(hash.prefix(16))"
    let reference = PipelineResourceReference(kind: .coreAIModel,
      packageID: packageID, packageVersion: "sha256.\(hash)",
      contentHash: hash, componentRole: "classifier", functionName: "main")
    var linked = document
    var count = 0
    for index in linked.nodes.indices where linked.nodes[index].kind == nodeKind {
      if let nodeID, linked.nodes[index].id != nodeID { continue }
      let binding = linked.nodes[index].resources["model"]
      let currentID = binding?.linkedReference?.packageID ?? unlinkedPackageID
      guard currentID == replacingPackageID else { continue }
      linked.nodes[index].resources["model"] = .linked(reference)
      count += 1
    }
    guard count > 0 else { throw PipelineResourceRelinkError.noCompatibleRequirements }
    return (linked, packageID)
  }

  public static func inspect(_ document: PipelineDocument, at url: URL,
    packageID: String) -> String? {
    do {
      let hash = try contentHash(at: url)
      let classifiers = document.nodes.filter { $0.kind == nodeKind }
      guard !classifiers.isEmpty, classifiers.allSatisfy({ node in
        guard let reference = node.resources["model"]?.linkedReference else { return false }
        return reference.packageID == packageID
          && reference.packageID == "coreai.classifier.\(hash.prefix(16))"
          && reference.packageVersion == "sha256.\(hash)"
          && reference.contentHash == hash
          && reference.kind == .coreAIModel
          && reference.componentRole == "classifier"
          && reference.functionName == "main"
      }) else { return "The classifier package does not match the workflow link; relink it." }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  public static func contentHash(at selectedURL: URL) throws -> String {
    let root = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard ["aimodel", "aimodelc"].contains(root.pathExtension.lowercased()) else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "choose the trained .aimodel directory itself")
    }
    guard
      FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
      throw PipelineResourceRelinkError.packageIsNotDirectory(root.path)
    }
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("main.mlirb").path),
      let hash = try? Data(contentsOf: root.appendingPathComponent("main.hash")) else {
      throw PipelineResourceRelinkError.missingComponentIdentity(root.path)
    }
    if hash.count == 32 {
      return hash.map { String(format: "%02x", $0) }.joined()
    }
    if let text = String(data: hash, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      text.count == 64, text.allSatisfy(\.isHexDigit) {
      return text
    }
    throw PipelineResourceRelinkError.missingComponentIdentity(root.path)
  }
}

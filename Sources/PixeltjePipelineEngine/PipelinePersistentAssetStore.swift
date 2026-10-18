import CryptoKit
import Foundation
import PixeltjePipelineDomain

/// Local, disposable snapshots for Asset Cache nodes. Pipeline documents keep
/// only their graph and resource identities; cached media lives beside the app.
struct PipelinePersistentAssetStore {
  let root: URL

  private struct Manifest: Codable {
    let version: Int
    let fingerprint: String
    let slots: [Slot]
  }

  private struct Slot: Codable {
    let name: String
    let kind: String
    let width: Int?
    let height: Int?
    let extensionName: String?
    let generatedSHA256: String?
  }

  func save(_ bundle: PipelineAssetBundle, documentID: String,
    nodeID: PipelineNodeID, fingerprint: String) {
    let destination = directory(documentID: documentID, nodeID: nodeID)
    let staging = root.appendingPathComponent("staging-\(UUID().uuidString)",
      isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: staging,
        withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: staging) }
      var slots: [Slot] = []
      for index in 0..<bundle.values.count {
        let name = "asset\(index)"
        guard let value = bundle.values[name] else { return }
        switch value.type {
        case .image:
          guard let image = value.value(as: PipelineImageInput.self) else { return }
          let bytes = image.rgba.withUnsafeBytes { Data($0) }
          try bytes.write(to: staging.appendingPathComponent("slot-\(index).rgba"))
          slots.append(Slot(name: name, kind: "image", width: image.width,
            height: image.height, extensionName: nil, generatedSHA256: nil))
        case .audio:
          let generated = value.value(as: PipelineGeneratedAudio.self)
          guard let source = generated?.fileURL ?? value.value(as: URL.self) else { return }
          let originalExtension = source.pathExtension.lowercased()
          let ext = originalExtension.count <= 12 && originalExtension.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber)
          }) ? originalExtension : ""
          try FileManager.default.copyItem(at: source,
            to: staging.appendingPathComponent(fileName(index: index, ext: ext)))
          slots.append(Slot(name: name, kind: "audio", width: nil,
            height: nil, extensionName: ext,
            generatedSHA256: generated?.semanticPipelineSHA256))
        default:
          return
        }
      }
      let manifest = Manifest(version: 1, fingerprint: fingerprint, slots: slots)
      try JSONEncoder().encode(manifest).write(
        to: staging.appendingPathComponent("manifest.json"))
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: staging, to: destination)
    } catch {
      // A failed cache write must not discard a successfully generated bundle.
    }
  }

  func load(documentID: String, nodeID: PipelineNodeID,
    fingerprint: String) -> (bundle: PipelineAssetBundle, bytes: Int)? {
    let directory = directory(documentID: documentID, nodeID: nodeID)
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
      manifest.version == 1, manifest.fingerprint == fingerprint,
      (1...16).contains(manifest.slots.count),
      Set(manifest.slots.map(\.name)).count == manifest.slots.count else {
      return nil
    }
    var values: [String: PipelineNodeValue] = [:]
    var bytes = 0
    for (index, slot) in manifest.slots.enumerated() {
      guard slot.name == "asset\(index)" else { return nil }
      switch slot.kind {
      case "image":
        guard let width = slot.width, let height = slot.height,
          width > 0, height > 0,
          let pixelCount = product(width, height, 4),
          let size = product(pixelCount, MemoryLayout<Float>.stride),
          size <= 134_217_728 - bytes,
          let data = try? Data(contentsOf: directory.appendingPathComponent("slot-\(index).rgba")),
          data.count == size else { return nil }
        var rgba = [Float](repeating: 0, count: pixelCount)
        _ = rgba.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        guard let image = try? PipelineImageInput(width: width,
          height: height, rgba: rgba) else { return nil }
        values[slot.name] = PipelineNodeValue(image, type: .image)
        bytes += size
      case "audio":
        guard let ext = slot.extensionName, ext.count <= 12,
          ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
          return nil
        }
        let url = directory.appendingPathComponent(fileName(index: index, ext: ext))
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size <= 134_217_728 - bytes else { return nil }
        if let sha = slot.generatedSHA256 {
          values[slot.name] = PipelineNodeValue(PipelineGeneratedAudio(
            fileURL: url, semanticPipelineSHA256: sha), type: .audio)
        } else {
          values[slot.name] = PipelineNodeValue(url, type: .audio)
        }
        bytes += size
      default:
        return nil
      }
    }
    return (PipelineAssetBundle(values: values), bytes)
  }

  func clear(documentID: String, nodeID: PipelineNodeID) {
    try? FileManager.default.removeItem(at: directory(
      documentID: documentID, nodeID: nodeID))
  }

  func clear(documentID: String) {
    try? FileManager.default.removeItem(at: root.appendingPathComponent(
      digest(documentID), isDirectory: true))
  }

  private func directory(documentID: String, nodeID: PipelineNodeID) -> URL {
    root.appendingPathComponent(digest(documentID), isDirectory: true)
      .appendingPathComponent(digest(nodeID.rawValue), isDirectory: true)
  }

  private func fileName(index: Int, ext: String) -> String {
    ext.isEmpty ? "slot-\(index)" : "slot-\(index).\(ext)"
  }

  private func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  private func product(_ lhs: Int, _ rhs: Int, _ third: Int = 1) -> Int? {
    let (first, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else { return nil }
    let (result, secondOverflow) = first.multipliedReportingOverflow(by: third)
    return secondOverflow ? nil : result
  }
}

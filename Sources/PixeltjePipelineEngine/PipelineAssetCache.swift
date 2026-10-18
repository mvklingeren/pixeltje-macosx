import Foundation
import PixeltjePipelineDomain

/// An immutable, typed group of values carried by one graph edge. Slot names
/// belong to the producer, not to the cache service or a particular consumer.
public struct PipelineAssetBundle: Sendable {
  /// Stable across copies of one immutable bundle, including later Loop calls.
  public let id: UUID
  public let values: [String: PipelineNodeValue]

  public init(values: [String: PipelineNodeValue]) {
    self.id = UUID()
    self.values = values
  }

  public subscript(_ name: String) -> PipelineNodeValue? { values[name] }
}

/// Run-scoped snapshots, optionally retained for later runs of the same graph.
/// File-backed audio is copied so a changed source file cannot silently change
/// a cached value.
actor PipelineAssetCache {
  private let persistentStore: PipelinePersistentAssetStore?
  private var documentID: String?
  private var runID: UUID?
  private var fingerprintsByNodeID: [PipelineNodeID: String] = [:]
  private var retainedNodeIDs: Set<PipelineNodeID> = []
  private var bundles: [PipelineNodeID: PipelineAssetBundle] = [:]
  private var bundleFingerprints: [PipelineNodeID: String] = [:]
  private var bundleBytes: [PipelineNodeID: Int] = [:]
  private var copiedAudio: [PipelineNodeID: [URL]] = [:]
  private var byteCount = 0
  private var temporaryDirectory: URL?
  private var restoredNodeIDs: Set<PipelineNodeID> = []

  init(persistentDirectory: URL? = nil) {
    persistentStore = persistentDirectory.map(PipelinePersistentAssetStore.init(root:))
  }

  deinit {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  func begin(runID: UUID, documentID: String,
    fingerprintsByNodeID: [PipelineNodeID: String],
    retainedNodeIDs: Set<PipelineNodeID>) {
    guard self.runID != runID || self.documentID != documentID
      || self.fingerprintsByNodeID != fingerprintsByNodeID
      || self.retainedNodeIDs != retainedNodeIDs else { return }
    let kept = Set(bundles.keys).intersection(retainedNodeIDs).filter {
      self.documentID == documentID &&
      bundleFingerprints[$0] == fingerprintsByNodeID[$0]
    }
    removeBundles(except: Set(kept))
    restoredNodeIDs.removeAll()
    if let persistentStore {
      for nodeID in retainedNodeIDs.subtracting(kept) {
        guard let fingerprint = fingerprintsByNodeID[nodeID],
          let restored = persistentStore.load(documentID: documentID,
            nodeID: nodeID, fingerprint: fingerprint) else { continue }
        guard byteCount + restored.bytes <= 134_217_728 else { continue }
        bundles[nodeID] = restored.bundle
        bundleFingerprints[nodeID] = fingerprint
        bundleBytes[nodeID] = restored.bytes
        byteCount += restored.bytes
        restoredNodeIDs.insert(nodeID)
      }
    }
    self.documentID = documentID
    self.runID = runID
    self.fingerprintsByNodeID = fingerprintsByNodeID
    self.retainedNodeIDs = retainedNodeIDs
  }

  func end(runID: UUID) {
    guard self.runID == runID else { return }
    removeBundles(except: retainedNodeIDs)
    self.runID = nil
  }

  func contains(_ nodeID: PipelineNodeID) -> Bool { bundles[nodeID] != nil }

  func takeRestoredPreviewFlag(_ nodeID: PipelineNodeID) -> Bool {
    restoredNodeIDs.remove(nodeID) != nil
  }

  func clear(_ nodeID: PipelineNodeID, documentID: String? = nil) {
    removeBundles(except: Set(bundles.keys).subtracting([nodeID]))
    restoredNodeIDs.remove(nodeID)
    if let documentID = documentID ?? self.documentID {
      persistentStore?.clear(documentID: documentID, nodeID: nodeID)
    }
  }

  func clearAll() {
    if let documentID { persistentStore?.clear(documentID: documentID) }
    clearInMemory()
  }

  func clearInMemory() { clearInMemoryState() }

  static func preview(nodeID: PipelineNodeID, slot: String,
    value: PipelineNodeValue, graphSHA256: String) -> PipelineAssetPreview? {
    if value.type == .audio {
      let url = value.value(as: URL.self)
        ?? value.value(as: PipelineGeneratedAudio.self)?.fileURL
      return url.map { PipelineAssetPreview(nodeID: nodeID, slot: slot, audioURL: $0) }
    }
    guard value.type == .image else { return nil }
    let raster: PipelineImageInput
    if let image = value.value(as: PipelineImageInput.self) {
      raster = image
    } else if let image = value.value(as: PipelineGeneratedImage.self),
      let converted = try? PipelineImageInput(generatedImage: image) {
      raster = converted
    } else {
      return nil
    }
    let scale = max(1, Double(max(raster.width, raster.height)) / 256)
    let width = max(1, Int(Double(raster.width) / scale))
    let height = max(1, Int(Double(raster.height) / scale))
    let pixels = width * height
    var planar = [Float](repeating: 0, count: pixels * 3)
    var alpha = [Float](repeating: 0, count: pixels)
    for y in 0..<height {
      for x in 0..<width {
        let sourceX = min(raster.width - 1, Int(Double(x) * scale))
        let sourceY = min(raster.height - 1, Int(Double(y) * scale))
        let source = (sourceY * raster.width + sourceX) * 4
        let target = y * width + x
        let coverage = raster.rgba[source + 3]
        alpha[target] = coverage
        for channel in 0..<3 {
          planar[channel * pixels + target] = coverage > 0
            ? raster.rgba[source + channel] / coverage : 0
        }
      }
    }
    return PipelineAssetPreview(nodeID: nodeID, slot: slot,
      image: PipelineGeneratedImage(width: width, height: height,
        planarRGB: planar, encoding: .sRGBZeroToOne,
        semanticPipelineSHA256: graphSHA256, alpha: alpha))
  }

  private func clearInMemoryState() {
    bundles.removeAll()
    bundleFingerprints.removeAll()
    bundleBytes.removeAll()
    copiedAudio.removeAll()
    byteCount = 0
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    temporaryDirectory = nil
    runID = nil
    fingerprintsByNodeID = [:]
    retainedNodeIDs.removeAll()
    restoredNodeIDs.removeAll()
    documentID = nil
  }

  private func removeBundles(except kept: Set<PipelineNodeID>) {
    for nodeID in bundles.keys.filter({ !kept.contains($0) }) {
      bundles[nodeID] = nil
      bundleFingerprints[nodeID] = nil
      byteCount -= bundleBytes.removeValue(forKey: nodeID) ?? 0
      for url in copiedAudio.removeValue(forKey: nodeID) ?? [] {
        try? FileManager.default.removeItem(at: url)
      }
    }
    if copiedAudio.isEmpty, let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
      self.temporaryDirectory = nil
    }
  }

  static func executor(cache: PipelineAssetCache) -> PipelineNodeExecutor {
    .init(kind: .assetCache, validate: { node in
      let count = node.parameters["slotCount"]?.integerValue ?? 1
      guard (1...16).contains(count) else {
        return [.init(severity: .error, code: .invalidParameter,
          message: "Asset Cache needs 1–16 slots.", nodeID: node.id)]
      }
      return []
    }) { node, inputs, _ in
      let count = Int(node.parameters["slotCount"]?.integerValue ?? 1)
      let bundle: PipelineAssetBundle
      if inputs.isEmpty {
        bundle = try await cache.load(node.id)
      } else {
        guard inputs.count == count else {
          throw PipelineEngineError.invalidInvocation(
            "Asset Cache needs all \(count) connected assets.")
        }
        bundle = try await cache.store(inputs, for: node.id)
      }
      var outputs = bundle.values
      outputs["assets"] = PipelineNodeValue(bundle, type: .assetBundle)
      return .init(outputs: outputs)
    }
  }

  private func store(_ inputs: [String: PipelineNodeValue],
    for nodeID: PipelineNodeID) throws -> PipelineAssetBundle {
    if let cached = bundles[nodeID] { return cached }
    var values: [String: PipelineNodeValue] = [:]
    var bytes = 0
    var copies: [URL] = []
    var committed = false
    defer {
      if !committed {
        for url in copies { try? FileManager.default.removeItem(at: url) }
      }
    }
    for (name, value) in inputs.sorted(by: { $0.key < $1.key }) {
      switch value.type {
      case .image:
        let image: PipelineImageInput
        if let raster = value.value(as: PipelineImageInput.self) {
          image = raster
        } else if let generated = value.value(as: PipelineGeneratedImage.self) {
          image = try PipelineImageInput(generatedImage: generated)
        } else {
          throw PipelineEngineError.invalidInvocation(
            "Asset Cache \(name) needs image pixels.")
        }
        bytes += image.rgba.count * MemoryLayout<Float>.stride
        values[name] = PipelineNodeValue(image, type: .image)
      case .audio:
        let source: URL
        let generated: PipelineGeneratedAudio?
        if let audio = value.value(as: PipelineGeneratedAudio.self) {
          source = audio.fileURL
          generated = audio
        } else if let url = value.value(as: URL.self) {
          source = url
          generated = nil
        } else {
          throw PipelineEngineError.invalidInvocation(
            "Asset Cache \(name) needs a file-backed audio value.")
        }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        bytes += size
        guard byteCount + bytes <= 134_217_728 else {
          throw PipelineEngineError.invalidInvocation("Asset Cache exceeds 128 MiB.")
        }
        let directory = try audioDirectory()
        let copy = directory.appendingPathComponent(UUID().uuidString)
          .appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: copy)
        copies.append(copy)
        if let generated {
          values[name] = PipelineNodeValue(PipelineGeneratedAudio(
            fileURL: copy, semanticPipelineSHA256: generated.semanticPipelineSHA256),
            type: .audio)
        } else {
          values[name] = PipelineNodeValue(copy, type: .audio)
        }
      default:
        throw PipelineEngineError.invalidInvocation(
          "Asset Cache supports image and audio slots; \(name) is \(value.type.rawValue).")
      }
      guard byteCount + bytes <= 134_217_728 else {
        throw PipelineEngineError.invalidInvocation("Asset Cache exceeds 128 MiB.")
      }
    }
    let bundle = PipelineAssetBundle(values: values)
    bundles[nodeID] = bundle
    bundleFingerprints[nodeID] = fingerprintsByNodeID[nodeID]
    bundleBytes[nodeID] = bytes
    if !copies.isEmpty { copiedAudio[nodeID] = copies }
    byteCount += bytes
    if retainedNodeIDs.contains(nodeID), let documentID,
      let fingerprint = fingerprintsByNodeID[nodeID] {
      persistentStore?.save(bundle, documentID: documentID,
        nodeID: nodeID, fingerprint: fingerprint)
    }
    committed = true
    return bundle
  }

  private func load(_ nodeID: PipelineNodeID) throws -> PipelineAssetBundle {
    guard let bundle = bundles[nodeID] else {
      throw PipelineEngineError.invalidInvocation(
        "Asset Cache \(nodeID.rawValue) has not been filled in this run.")
    }
    return bundle
  }

  private func audioDirectory() throws -> URL {
    if let temporaryDirectory { return temporaryDirectory }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pixeltje-asset-cache-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(at: directory,
      withIntermediateDirectories: true)
    temporaryDirectory = directory
    return directory
  }
}

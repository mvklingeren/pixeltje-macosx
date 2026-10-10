import Foundation
import PixeltjePipelineDomain

/// Run-scoped immutable images. A new run always starts with an empty cache.
actor PipelineImageCache {
  private var runID: UUID?
  private var graphSHA256 = ""
  private var images: [String: PipelineImageInput] = [:]
  private var byteCount = 0

  func begin(runID: UUID, graphSHA256: String) {
    guard self.runID != runID || self.graphSHA256 != graphSHA256 else { return }
    self.runID = runID
    self.graphSHA256 = graphSHA256
    images.removeAll()
    byteCount = 0
  }

  func end(runID: UUID) {
    guard self.runID == runID else { return }
    self.runID = nil
    images.removeAll()
    byteCount = 0
  }

  func contains(_ key: String) -> Bool { images[key] != nil }

  static func executor(cache: PipelineImageCache) -> PipelineNodeExecutor {
    .init(kind: .imageCache, validate: { node in
      let key = node.parameters["key"]?.stringValue ?? ""
      let mode = node.parameters["mode"]?.stringValue ?? "store"
      guard !key.isEmpty, key.utf8.count <= 128,
        key.utf8.allSatisfy({ (32...126).contains($0) }),
        ["store", "load"].contains(mode) else {
        return [.init(severity: .error, code: .invalidParameter,
          message: "Image Cache needs a printable key (1–128 bytes) and store or load mode.",
          nodeID: node.id)]
      }
      return []
    }) { node, inputs, _ in
      guard let key = node.parameters["key"]?.stringValue else {
        throw PipelineEngineError.invalidInvocation("Image Cache needs a key.")
      }
      let mode = node.parameters["mode"]?.stringValue ?? "store"
      let image: PipelineImageInput
      if mode == "store" {
        if let input = inputs["image"] {
          if let raster = input.value(as: PipelineImageInput.self) {
            image = raster
          } else if let generated = input.value(as: PipelineGeneratedImage.self) {
            image = try PipelineImageInput(generatedImage: generated)
          } else {
            throw PipelineEngineError.invalidInvocation("Image Cache \(key) needs image pixels.")
          }
          try await cache.store(image, for: key)
        } else {
          image = try await cache.load(key)
        }
      } else {
        guard inputs["image"] == nil else {
          throw PipelineEngineError.invalidInvocation("Image Cache load \(key) cannot take an image input.")
        }
        image = try await cache.load(key)
      }
      return .init(outputs: ["image": PipelineNodeValue(image, type: .image)])
    }
  }

  private func store(_ image: PipelineImageInput, for key: String) throws {
    if images[key] != nil { return }
    let bytes = image.rgba.count * MemoryLayout<Float>.stride
    guard images.count < 16, byteCount + bytes <= 134_217_728 else {
      throw PipelineEngineError.invalidInvocation("Image Cache exceeds 16 images or 128 MiB.")
    }
    images[key] = image
    byteCount += bytes
  }

  private func load(_ key: String) throws -> PipelineImageInput {
    guard let image = images[key] else {
      throw PipelineEngineError.invalidInvocation("Image Cache has no image for \(key).")
    }
    return image
  }
}

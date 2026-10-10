import CoreAIImageSegmenter
import CoreGraphics
import CryptoKit
import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine

public struct SAM31PackageInspection: Sendable {
  public let isUsable: Bool
  public let summary: String
}

/// Text-guided image selection using the image detector from Meta SAM 3.1.
/// The model and tokenizer stay in the user's linked Core AI library.
public enum SAM31PipelineFamily {
  public static let packageID = "coreai.meta.sam3.1-image-selection"
  public static let nodeKind = PipelineNodeKind(rawValue: "coreai.sam31Select")
  public static let modelName = "sam31_detector_float16.aimodel"

  public static func defaultPackageURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pixeltje/models/\(packageID)", isDirectory: true)
  }

  public static func descriptor() -> PipelineNodeDescriptor {
    PipelineNodeDescriptor(
      kind: nodeKind,
      displayName: "SAM 3.1 Select",
      category: "Selection",
      inputs: [
        .init(name: "image", type: .image, isRequired: false),
        .init(name: "prompt", type: .prompt, isRequired: false),
        .init(name: "subjects", type: .stringList, isRequired: false),
      ],
      outputs: [
        .init(name: "mask", type: .mask),
        .init(name: "masks", type: .labeledMasks),
      ],
      parameters: [
        .init(name: "scoreThreshold", valueType: .number, defaultValue: .number(0.5)),
        .init(name: "maskThreshold", valueType: .number, defaultValue: .number(0.5)),
        .init(name: "maxSegments", valueType: .integer, defaultValue: .integer(32)),
      ],
      requiredResourceSlots: ["model", "tokenizer"])
  }

  public static func inspectPackage(at root: URL, for document: PipelineDocument) -> SAM31PackageInspection {
    let digests: (model: String, tokenizer: String)
    do {
      digests = try packageDigests(at: root)
    } catch {
      return .init(isUsable: false, summary: error.localizedDescription)
    }
    for node in document.nodes where node.kind == nodeKind {
      guard let model = node.resources["model"]?.linkedReference,
        let tokens = node.resources["tokenizer"]?.linkedReference,
        model.packageID == packageID, tokens.packageID == packageID,
        model.kind == .coreAIModel, tokens.kind == .tokenizer,
        model.componentRole == "detector", tokens.componentRole == "tokenizer",
        model.contentHash.lowercased() == digests.model,
        tokens.contentHash.lowercased() == digests.tokenizer
      else {
        return .init(isUsable: false,
          summary: "SAM 3.1 model or tokenizer identity changed. Relink the workflow.")
      }
    }
    return .init(isUsable: true, summary: "SAM 3.1 Core AI package is ready.")
  }

  public static func linkPackage(in document: PipelineDocument, at root: URL) throws -> PipelineDocument {
    let digests = try packageDigests(at: root)
    let version = "sha256.\(digests.model)"
    var linked = document
    for index in linked.nodes.indices where linked.nodes[index].kind == nodeKind {
      linked.nodes[index].resources["model"] = .linked(.init(
        kind: .coreAIModel, packageID: packageID, packageVersion: version,
        contentHash: digests.model, componentRole: "detector"))
      linked.nodes[index].resources["tokenizer"] = .linked(.init(
        kind: .tokenizer, packageID: packageID, packageVersion: version,
        contentHash: digests.tokenizer, componentRole: "tokenizer"))
    }
    return linked
  }

  private static func packageDigests(at root: URL) throws -> (model: String, tokenizer: String) {
    let modelURL = root.appendingPathComponent(modelName, isDirectory: true)
    let modelHashURL = modelURL.appendingPathComponent("main.hash")
    let tokenizerURL = root.appendingPathComponent("tokenizer/tokenizer.json")
    let metadataURL = root.appendingPathComponent("metadata.json")
    guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("main.mlirb").path),
      let modelHash = try? Data(contentsOf: modelHashURL), modelHash.count == 32,
      let tokenizer = try? Data(contentsOf: tokenizerURL), !tokenizer.isEmpty,
      let metadata = try? Data(contentsOf: metadataURL),
      let object = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
      object["kind"] as? String == "segmenter",
      object["source"] as? String == "facebook/sam3.1",
      (object["assets"] as? [String: String])?["main"] == modelName
    else {
      throw PipelineEngineError.modelPackageUnavailable(
        "SAM 3.1 needs the linked detector .aimodel, tokenizer, and segmenter metadata.")
    }
    let modelDigest = modelHash.map { String(format: "%02x", $0) }.joined()
    let tokenizerDigest = SHA256.hash(data: tokenizer).map { String(format: "%02x", $0) }.joined()
    return (modelDigest, tokenizerDigest)
  }

  public static func executor(runner: SAM31PipelineRunner) -> PipelineNodeExecutor {
    PipelineNodeExecutor(kind: nodeKind) { node, inputs, context in
      let subjects: [String]
      if let supplied = inputs["subjects"]?.value(as: [String].self) {
        subjects = supplied
      } else if let prompt = inputs["prompt"]?.value(as: String.self) {
        subjects = [prompt]
      } else {
        subjects = []
      }
      var seen: Set<String> = []
      let names = subjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
      guard names.count <= 16 else {
        throw PipelineEngineError.invalidInvocation("SAM 3.1 accepts at most 16 subjects.")
      }
      let score: Double = if case .number(let value)? = node.parameters["scoreThreshold"] {
        value
      } else { 0.5 }
      let mask: Double = if case .number(let value)? = node.parameters["maskThreshold"] {
        value
      } else { 0.5 }
      let maxSegments: Int = if case .integer(let value)? = node.parameters["maxSegments"] {
        Int(value)
      } else { 32 }
      guard (0...1).contains(score), (0...1).contains(mask),
        (1...200).contains(maxSegments) else {
        throw PipelineEngineError.invalidInvocation(
          "SAM 3.1 thresholds must be 0–1 and max segments must be 1–200.")
      }
      guard let suppliedImage = inputs["image"], !names.isEmpty else {
        return PipelineNodeResult(outputs: [
          "masks": PipelineNodeValue([PipelineLabeledMask](), type: .labeledMasks)
        ])
      }
      let image: PipelineImageInput
      if let raster = suppliedImage.value(as: PipelineImageInput.self) {
        image = raster
      } else if let generated = suppliedImage.value(as: PipelineGeneratedImage.self) {
        image = try PipelineImageInput(generatedImage: generated)
      } else {
        throw PipelineEngineError.invalidInvocation("SAM 3.1 needs a host or generated image raster.")
      }
      guard let model = node.resources["model"]?.linkedReference else {
        throw PipelineEngineError.invalidInvocation("SAM 3.1 needs a linked model.")
      }
      let root = try context.packageRoot(for: model)
      let segments = try await runner.segmentLabeled(
        image: image, subjects: names, packageRoot: root,
        scoreThreshold: Float(score), maskThreshold: Float(mask),
        maxSegments: maxSegments)
      var coverage = [Float](repeating: 0, count: image.width * image.height)
      for segment in segments {
        for index in coverage.indices where segment.mask.coverage[index] > 0 {
          coverage[index] = 1
        }
      }
      let selection = try PipelineMaskInput(
        width: image.width, height: image.height, coverage: coverage)
      return PipelineNodeResult(outputs: [
        "mask": PipelineNodeValue(selection, type: .mask),
        "masks": PipelineNodeValue(segments, type: .labeledMasks),
      ])
    }
  }
}

public actor SAM31PipelineRunner {
  public init() {}

  public func select(
    image: PipelineImageInput,
    prompt: String,
    packageRoot: URL,
    scoreThreshold: Float,
    maskThreshold: Float,
    maxSegments: Int
  ) async throws -> PipelineMaskInput {
    let segments = try await segmentLabeled(
      image: image, subjects: [prompt], packageRoot: packageRoot,
      scoreThreshold: scoreThreshold, maskThreshold: maskThreshold,
      maxSegments: maxSegments)
    var coverage = [Float](repeating: 0, count: image.width * image.height)
    for segment in segments {
      for index in coverage.indices where segment.mask.coverage[index] > 0 {
        coverage[index] = 1
      }
    }
    return try PipelineMaskInput(width: image.width, height: image.height, coverage: coverage)
  }

  public func segmentLabeled(
    image: PipelineImageInput,
    subjects: [String],
    packageRoot: URL,
    scoreThreshold: Float,
    maskThreshold: Float,
    maxSegments: Int
  ) async throws -> [PipelineLabeledMask] {
    let segmenter = try await ImageSegmenter(resourcesAt: packageRoot.standardizedFileURL.path)
    let cgImage = try makeImage(image)
    var results: [PipelineLabeledMask] = []
    for subject in subjects {
      try Task.checkCancellation()
      let response = try await segmenter.segment(
        image: cgImage, prompt: subject,
        parameters: SegmentationParameters(
          maskThreshold: maskThreshold,
          maxSegments: maxSegments,
          tokenizerContextLength: 32))
      for segment in response.segments where segment.score >= scoreThreshold {
        guard segment.maskWidth == image.width, segment.maskHeight == image.height,
          segment.mask.count == image.width * image.height else {
          throw PipelineEngineError.invalidInvocation("SAM 3.1 returned a mask with unexpected dimensions.")
        }
        let coverage = segment.mask.map { $0 ? Float(1) : Float(0) }
        let instance = try PipelineMaskInput(
          width: image.width, height: image.height, coverage: coverage)
        results.append(try PipelineLabeledMask(
          label: subject, mask: instance,
          score: min(max(segment.score, 0), 1)))
      }
    }
    return results
  }

  private func makeImage(_ image: PipelineImageInput) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    for pixel in 0..<(image.width * image.height) {
      let offset = pixel * 4
      let alpha = min(max(image.rgba[offset + 3], 0), 1)
      for channel in 0..<3 {
        let premultiplied = min(max(image.rgba[offset + channel], 0), alpha)
        bytes[offset + channel] = UInt8((premultiplied * 255).rounded())
      }
      bytes[offset + 3] = UInt8((alpha * 255).rounded())
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let cgImage = CGImage(
        width: image.width, height: image.height,
        bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: image.width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
    else {
      throw PipelineEngineError.invalidInvocation("Could not prepare the source image for SAM 3.1.")
    }
    return cgImage
  }
}

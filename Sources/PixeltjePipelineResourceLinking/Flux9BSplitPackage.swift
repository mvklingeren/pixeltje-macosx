import CryptoKit
import Foundation
import PixeltjePipelineDomain

/// One link-only directory containing the split denoiser, split Qwen encoder,
/// and shared VAE. Each model is still a Core AI package loaded in place.
public struct Flux9BSplitPackage: Sendable {
  public static let packageID = "coreai.black-forest-labs.flux2-klein-9b-fp8"
  public static let familyABI = "flux2-klein-9b-split-coreai@1"
  public static let nodeKind = PipelineNodeKind(rawValue: "coreai.flux2Klein9BSplitGenerate")

  public static let denoiserComponents =
    ["Head.aimodel"]
    + (0..<8).map { String(format: "DoubleBlock%02d.aimodel", $0) }
    + (0..<24).map { String(format: "SingleBlock%02d.aimodel", $0) }
    + ["Tail.aimodel"]
  public static let encoderComponents =
    ["Embedding.aimodel"]
    + (0..<27).map { String(format: "Layer%02d.aimodel", $0) }

  public let root: URL
  public let version: String
  public let denoiserHash: String
  public let encoderHash: String
  public let vaeHash: String
  public let adapterSHA256: String?

  public init(at selectedURL: URL) throws {
    let root = selectedURL.standardizedFileURL
    guard FileManager.default.fileExists(atPath: root.path) else {
      throw PipelineResourceRelinkError.packageIsNotDirectory(root.path)
    }
    let manifest = try Self.json(at: root.appendingPathComponent("manifest.json"))
    guard manifest["status"] as? String == "experimental-denoiser-only",
      manifest["source_model"] as? String == "black-forest-labs/FLUX.2-klein-9b-fp8",
      manifest["image_size"] as? Int == 1024,
      manifest["image_tokens"] as? Int == 4096,
      manifest["text_tokens"] as? Int == 512,
      manifest["preferred_compute"] as? String == "gpu",
      manifest["components"] as? [String] == Self.denoiserComponents
    else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "the denoiser manifest does not describe the fixed 1024-pixel FP8 Klein 9B split")
    }
    let encoderRoot = root.appendingPathComponent("TextEncoder", isDirectory: true)
    let encoderManifest = try Self.json(at: encoderRoot.appendingPathComponent("manifest.json"))
    guard encoderManifest["status"] as? String == "experimental-split-text-encoder",
      encoderManifest["source_model"] as? String == "Qwen/Qwen3-8B-FP8",
      encoderManifest["components"] as? [String] == Self.encoderComponents,
      encoderManifest["output_layers"] as? [Int] == [9, 18, 27],
      encoderManifest["output_shape"] as? [Int] == [1, 512, 12288],
      encoderManifest["preferred_compute"] as? String == "gpu"
    else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "TextEncoder is not the Qwen3-8B FP8 split encoder for Klein 9B")
    }
    let denoiserHashes = try Self.hashes(in: root, components: Self.denoiserComponents)
    let encoderHashes = try Self.hashes(in: encoderRoot, components: Self.encoderComponents)
    let vaeHash = try Self.hash(
      at: root.appendingPathComponent("VAEDecoder.aimodel/main.hash"))
    for sidecar in [
      "TextEncoder/tokenizer/tokenizer.json",
      "TextEncoder/tokenizer/tokenizer_config.json",
      "vae_bn_mean.npy", "vae_bn_var.npy",
    ] {
      let url = root.appendingPathComponent(sidecar)
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0
      else { throw PipelineResourceRelinkError.missingComponent(sidecar) }
    }
    self.root = root
    self.denoiserHash = Self.digest(denoiserHashes)
    self.encoderHash = Self.digest(encoderHashes)
    self.vaeHash = vaeHash
    self.adapterSHA256 = (manifest["adapter"] as? [String: Any])?["sha256"] as? String
    let identity = [denoiserHash, encoderHash, vaeHash,
      Self.digest([
        try Self.fileDigest(at: root.appendingPathComponent("vae_bn_mean.npy")),
        try Self.fileDigest(at: root.appendingPathComponent("vae_bn_var.npy")),
        try Self.fileDigest(at: encoderRoot.appendingPathComponent("tokenizer/tokenizer.json")),
        try Self.fileDigest(at: encoderRoot.appendingPathComponent("tokenizer/tokenizer_config.json")),
      ])]
    self.version = "sha256." + Self.digest(identity)
  }

  public func reference(for slot: String) throws -> PipelineResourceReference {
    let (hash, role): (String, String)
    switch slot {
    case "denoiser": (hash, role) = (denoiserHash, "denoiser")
    case "textEncoder": (hash, role) = (encoderHash, "textEncoder")
    case "vaeDecoder": (hash, role) = (vaeHash, "vae")
    default:
      throw PipelineResourceRelinkError.incompatiblePackage("unknown 9B resource slot \(slot)")
    }
    return PipelineResourceReference(
      kind: .coreAIModel, packageID: Self.packageID, packageVersion: version,
      contentHash: hash, componentRole: role, functionName: "main",
      familyABI: Self.familyABI)
  }

  public func validateLinks(in node: PipelineNode) throws {
    let declaredAdapter: String?
    if case .string(let value)? = node.origin?.metadata["adapterSHA256"] {
      declaredAdapter = value
    } else {
      declaredAdapter = nil
    }
    if let declaredAdapter, declaredAdapter != adapterSHA256 {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "the workflow requires Real HD 2K adapter \(declaredAdapter)")
    }
    if node.origin?.metadata["adapterFusion"] == .string("none"), adapterSHA256 != nil {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "the base workflow requires the unfused Klein 9B denoiser")
    }
    for slot in ["denoiser", "textEncoder", "vaeDecoder"] {
      guard let actual = node.resources[slot]?.linkedReference,
        actual == (try reference(for: slot))
      else {
        throw PipelineResourceRelinkError.incompatiblePackage(
          "the \(slot) link changed; select the package again")
      }
    }
  }

  private static func json(at url: URL) throws -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw PipelineResourceRelinkError.missingComponent(url.path) }
    return object
  }

  private static func hashes(in root: URL, components: [String]) throws -> [String] {
    try components.map { component in
      let bundle = root.appendingPathComponent(component, isDirectory: true)
      let payload = bundle.appendingPathComponent("main.mlirb")
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: payload.path),
        (attributes[.size] as? NSNumber)?.intValue ?? 0 > 1024
      else { throw PipelineResourceRelinkError.missingComponent(component + "/main.mlirb") }
      return component + ":" + (try hash(at: bundle.appendingPathComponent("main.hash")))
    }
  }

  private static func hash(at url: URL) throws -> String {
    guard let data = try? Data(contentsOf: url), data.count == 32 else {
      throw PipelineResourceRelinkError.missingComponentIdentity(url.path)
    }
    return data.map { String(format: "%02x", $0) }.joined()
  }

  private static func fileDigest(at url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func digest(_ values: [String]) -> String {
    let data = Data(values.joined(separator: "\n").utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

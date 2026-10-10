import CryptoKit
import Foundation
import PixeltjePipelineDomain

/// The publisher's one-step SDXS-512-DreamShaper export, linked in place.
public struct SDXSPackage: Sendable {
  public static let packageID = "coreai.idkiro.sdxs-512-dreamshaper"
  public static let familyABI = "sdxs-512-dreamshaper-coreai@1"
  public static let nodeKind = PipelineNodeKind(rawValue: "coreai.sdxsGenerate")

  private static let assets: [(slot: String, role: String, filename: String)] = [
    ("textEncoder", "textEncoder", "TextEncoder.aimodel"),
    ("denoiser", "denoiser", "Unet.aimodel"),
    ("vaeDecoder", "vae", "VAEDecoder.aimodel"),
  ]

  public let root: URL
  public let version: String
  private let componentHashes: [String: String]

  public init(at selectedURL: URL) throws {
    let root = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw PipelineResourceRelinkError.packageIsNotDirectory(root.path) }

    let manifestURL = root.appendingPathComponent("metadata.json")
    guard let data = try? Data(contentsOf: manifestURL),
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let source = metadata["source"] as? [String: Any],
      let diffusion = metadata["diffusion"] as? [String: Any],
      let scheduler = diffusion["scheduler"] as? [String: Any],
      let assets = metadata["assets"] as? [String: String],
      source["hf_model_id"] as? String == "IDKiro/sdxs-512-dreamshaper",
      source["revision"] as? String == "76f720262bb051da75666b22c902a78c8e16c763",
      (diffusion["image_size"] as? NSNumber)?.intValue == 512,
      (diffusion["default_steps"] as? NSNumber)?.intValue == 1,
      (diffusion["default_guidance_scale"] as? NSNumber)?.doubleValue == 0,
      (diffusion["decoder_scale_factor"] as? NSNumber)?.doubleValue == 1,
      scheduler["type"] as? String == "euler-discrete",
      scheduler["timestep_spacing"] as? String == "trailing",
      assets["text_encoder"] == "TextEncoder.aimodel",
      assets["unet"] == "Unet.aimodel",
      assets["vae_decoder"] == "VAEDecoder.aimodel"
    else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "metadata.json is not the reviewed one-step SDXS-512-DreamShaper export")
    }

    var hashes: [String: String] = [:]
    var identities: [String] = []
    for asset in Self.assets {
      let path = root.appendingPathComponent(asset.filename, isDirectory: true)
      let payload = path.appendingPathComponent("main.mlirb")
      guard let size = (try? FileManager.default.attributesOfItem(atPath: payload.path))?[.size]
        as? NSNumber, size.intValue > 1024
      else { throw PipelineResourceRelinkError.missingComponent(asset.filename + "/main.mlirb") }
      let hash = try Self.hash(at: path.appendingPathComponent("main.hash"))
      hashes[asset.slot] = hash
      identities.append(asset.filename + ":" + hash)
    }
    for filename in [
      "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json",
      "tokenizer/special_tokens_map.json", "tokenizer/vocab.json", "tokenizer/merges.txt",
    ] {
      let url = root.appendingPathComponent(filename)
      guard let fileData = try? Data(contentsOf: url), !fileData.isEmpty else {
        throw PipelineResourceRelinkError.missingComponent(filename)
      }
      identities.append(filename + ":" + Self.digest(fileData))
    }
    identities.append("metadata.json:" + Self.digest(data))
    self.root = root
    self.version = "sha256." + Self.digest(Data(identities.joined(separator: "\n").utf8))
    componentHashes = hashes
  }

  public func reference(for slot: String) throws -> PipelineResourceReference {
    guard let asset = Self.assets.first(where: { $0.slot == slot }),
      let hash = componentHashes[slot]
    else { throw PipelineResourceRelinkError.incompatiblePackage("unknown SDXS slot \(slot)") }
    return PipelineResourceReference(
      kind: .coreAIModel, packageID: Self.packageID, packageVersion: version,
      contentHash: hash, componentRole: asset.role, functionName: "main",
      familyABI: Self.familyABI)
  }

  public func validateLinks(in node: PipelineNode) throws {
    for asset in Self.assets {
      guard node.resources[asset.slot]?.linkedReference == (try reference(for: asset.slot)) else {
        throw PipelineResourceRelinkError.incompatiblePackage(
          "the SDXS \(asset.slot) link changed; select its package again")
      }
    }
  }

  private static func hash(at url: URL) throws -> String {
    guard let data = try? Data(contentsOf: url), data.count == 32 else {
      throw PipelineResourceRelinkError.missingComponentIdentity(url.path)
    }
    return data.map { String(format: "%02x", $0) }.joined()
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

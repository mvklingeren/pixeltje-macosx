import CryptoKit
import Foundation
import PixeltjePipelineDomain

/// Link-only identity for the independently exported Stability AI SFX model.
public struct StableAudio3Package: Sendable {
  public static let packageID = "coreai.stabilityai.stable-audio-3-small-sfx"
  public static let familyABI = "stable-audio-3-small-sfx-coreai@1"
  public static let nodeKind = PipelineNodeKind(rawValue: "coreai.audioDiffusionGenerate")
  public static let slots: [(name: String, role: String, filename: String)] = [
    ("textEncoder", "textEncoder", "TextEncoder.aimodel"),
    ("durationEncoder", "durationEncoder", "DurationEncoder.aimodel"),
    ("denoiser", "denoiser", "Denoiser.aimodel"),
    ("audioDecoder", "audioDecoder", "AudioDecoder.aimodel"),
    ("tokenizer", "tokenizer", "tokenizer/tokenizer.json"),
  ]

  public let root: URL
  public let version: String
  private let hashes: [String: String]

  public init(at selectedURL: URL) throws {
    let root = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
      directory.boolValue else {
      throw PipelineResourceRelinkError.packageIsNotDirectory(root.path)
    }
    let metadataURL = root.appendingPathComponent("metadata.json")
    guard let metadata = try? Data(contentsOf: metadataURL),
      let json = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
      json["format"] as? String == "pixeltje-stable-audio-3-small-sfx-coreai@1",
      let source = json["source"] as? [String: Any],
      source["hf_model_id"] as? String == "stabilityai/stable-audio-3-small-sfx",
      source["revision"] as? String == "05ca3857881c94a2b84026b1111c537d78f5f9f0",
      (json["sample_rate"] as? NSNumber)?.intValue == 44_100,
      (json["latent_frames"] as? NSNumber)?.intValue == 88,
      (json["token_length"] as? NSNumber)?.intValue == 256
    else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "metadata.json is not the reviewed Stable Audio 3 Small SFX export")
    }
    var hashes: [String: String] = [:]
    var identities: [String] = []
    for slot in Self.slots {
      let url = root.appendingPathComponent(slot.filename)
      let digest: String
      if slot.name == "tokenizer" {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
          throw PipelineResourceRelinkError.missingComponent(slot.filename)
        }
        digest = Self.hash(data)
      } else {
        let payload = url.appendingPathComponent("main.mlirb")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: payload.path))?[.size]
          as? NSNumber, size.intValue > 1_024,
          let data = try? Data(contentsOf: url.appendingPathComponent("main.hash")),
          data.count == 32 else {
          throw PipelineResourceRelinkError.missingComponent(slot.filename)
        }
        digest = data.map { String(format: "%02x", $0) }.joined()
      }
      hashes[slot.name] = digest
      identities.append("\(slot.filename):\(digest)")
    }
    for filename in ["tokenizer/tokenizer_config.json", "tokenizer/special_tokens_map.json"] {
      let url = root.appendingPathComponent(filename)
      guard let data = try? Data(contentsOf: url), !data.isEmpty else {
        throw PipelineResourceRelinkError.missingComponent(filename)
      }
      identities.append("\(filename):\(Self.hash(data))")
    }
    identities.append("metadata.json:\(Self.hash(metadata))")
    self.root = root
    version = "sha256." + Self.hash(Data(identities.joined(separator: "\n").utf8))
    self.hashes = hashes
  }

  public func reference(for slot: String) throws -> PipelineResourceReference {
    guard let asset = Self.slots.first(where: { $0.name == slot }),
      let hash = hashes[slot] else {
      throw PipelineResourceRelinkError.incompatiblePackage("unknown Stable Audio slot \(slot)")
    }
    return PipelineResourceReference(
      kind: slot == "tokenizer" ? .tokenizer : .coreAIModel,
      packageID: Self.packageID, packageVersion: version, contentHash: hash,
      componentRole: asset.role,
      functionName: slot == "tokenizer" ? nil : "main", familyABI: Self.familyABI)
  }

  public func validateLinks(in node: PipelineNode) throws {
    for slot in Self.slots {
      guard node.resources[slot.name]?.linkedReference == (try reference(for: slot.name)) else {
        throw PipelineResourceRelinkError.incompatiblePackage(
          "the Stable Audio \(slot.name) link changed; select its package again")
      }
    }
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

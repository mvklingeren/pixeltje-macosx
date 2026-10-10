import CryptoKit
import Foundation
import PixeltjeMacDomain
import PixeltjePipelineDomain

public struct ZImagePackageInspection: Equatable, Sendable {
  public var packageRoot: URL
  public var missingComponents: [String]
  public var mismatchedComponents: [String]

  public init(
    packageRoot: URL,
    missingComponents: [String] = [],
    mismatchedComponents: [String] = []
  ) {
    self.packageRoot = packageRoot
    self.missingComponents = missingComponents
    self.mismatchedComponents = mismatchedComponents
  }

  public var isUsable: Bool {
    missingComponents.isEmpty && mismatchedComponents.isEmpty
  }

  public var summary: String {
    if isUsable { return "Z-Image Core AI package is ready." }
    let problems = (missingComponents.map { "missing \($0)" }
      + mismatchedComponents.map { "changed \($0)" }).joined(separator: ", ")
    return "Z-Image Core AI package cannot be used: \(problems)."
  }
}

/// Shared Z-Image package identity and inspection used by the native generation node.
public enum ZImagePipelineFamily {
  public static let packageID = "coreai.z-image.z-image-turbo"
  public static let packageVersion = "839407f40a752102e63e1e22ff235a8d091b09f6"
  public static let familyABI = "z-image-coreai-seq64@1"

  public static func defaultPackageURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let configured = environment["PIXELTJE_ZIMAGE_MODEL_PATH"], !configured.isEmpty {
      return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return homeDirectory
      .appendingPathComponent(".pixeltje/models/z-image-turbo-coreai", isDirectory: true)
  }

  public static func inspectPackage(
    at packageRoot: URL,
    for document: PipelineDocument? = nil
  ) -> ZImagePackageInspection {
    let document = document ?? PipelineDocument(
      id: PipelineID(rawValue: "z-image-package-inspection"),
      name: "Z-Image package inspection", mode: .textToImage,
      nodes: [ZImageCompositeNode.makeNode(id: PipelineNodeID(rawValue: "generate"))],
      connections: [])
    let resources = resourcesDirectory(in: packageRoot)
    let allReferences = document.nodes.flatMap {
      $0.resources.values.compactMap(\.linkedReference)
    }
    let references = Dictionary(
      allReferences.map { ($0.componentRole, $0) },
      uniquingKeysWith: { first, _ in first })
    let generation = document.nodes.first { $0.kind == .zImageGenerate }
    let width = Int(generation?.parameters["width"]?.integerValue ?? 512)
    let height = Int(generation?.parameters["height"]?.integerValue ?? 512)
    var missing: [String] = []
    var mismatched: [String] = []

    let packageIdentities = Set(allReferences.map {
      "\($0.packageID)\u{0}\($0.packageVersion)"
    })
    if packageIdentities.count != 1 {
      mismatched.append("package identity")
    }

    for role in references.keys.sorted() {
      guard let reference = references[role],
        let artifact = artifact(for: role, width: width, height: height),
        reference.familyABI == familyABI,
        reference.kind == artifact.kind,
        reference.functionName == (reference.kind == .coreAIModel ? "main" : nil),
        allReferences.filter({ $0.componentRole == role }).allSatisfy({ $0 == reference })
      else {
        mismatched.append(role)
        continue
      }
      let url = resources.appendingPathComponent(artifact.relativePath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        missing.append(artifact.relativePath)
        continue
      }
      do {
        let actualHash: String
        if artifact.isModelBundle {
          let payload = url.appendingPathComponent("main.mlirb")
          let storedHash = url.appendingPathComponent("main.hash")
          guard FileManager.default.fileExists(atPath: payload.path),
            FileManager.default.fileExists(atPath: storedHash.path)
          else {
            missing.append(artifact.relativePath + "/main.mlirb or main.hash")
            continue
          }
          actualHash = try Data(contentsOf: storedHash).hexadecimalString
        } else {
          actualHash = try SHA256.hash(data: Data(contentsOf: url)).hexadecimalString
        }
        if normalizedHash(reference.contentHash) != actualHash {
          mismatched.append(role)
        }
      } catch {
        mismatched.append(role)
      }
    }
    return ZImagePackageInspection(
      packageRoot: packageRoot,
      missingComponents: missing,
      mismatchedComponents: mismatched)
  }

  private struct Artifact {
    var kind: PipelineResourceKind
    var relativePath: String
    var isModelBundle: Bool
  }

  private static func artifact(
    for role: String, width: Int = 512, height: Int = 512
  ) -> Artifact? {
    switch role {
    case "tokenizer": .init(
      kind: .tokenizer, relativePath: "tokenizer/tokenizer.json", isModelBundle: false)
    case "promptEncoder": .init(
      kind: .coreAIModel,
      relativePath: "zimage_encoder_seq64_full_bf16_ids_iofp32.aimodel", isModelBundle: true)
    case "denoiser": .init(
      kind: .coreAIModel,
      relativePath: "zimage_dit_512_cap32_full_native_bf16_dyncap_dynimg_iofp32.aimodel",
      isModelBundle: true)
    case "timestepEmbedder": .init(
      kind: .coreAIModel,
      relativePath: "glue/zimage_t_embedder_fp32/zimage_t_embedder_fp32.aimodel",
      isModelBundle: true)
    case "ropeMetadata": .init(
      kind: .data, relativePath: "glue/rope_meta.json", isModelBundle: false)
    case "ropeAxis0": .init(
      kind: .data, relativePath: "glue/rope_axis0.f32", isModelBundle: false)
    case "ropeAxis1": .init(
      kind: .data, relativePath: "glue/rope_axis1.f32", isModelBundle: false)
    case "ropeAxis2": .init(
      kind: .data, relativePath: "glue/rope_axis2.f32", isModelBundle: false)
    case "vaeDecoder": .init(
      kind: .coreAIModel,
      relativePath: "zimage_vae_\(width == height ? String(width) : "\(width)x\(height)")_fp32.aimodel",
      isModelBundle: true)
    default: nil
    }
  }

  private static func resourcesDirectory(in root: URL) -> URL {
    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    return FileManager.default.fileExists(atPath: resources.path) ? resources : root
  }

  private static func normalizedHash(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: "sha256:", with: "")
  }
}

private extension Data {
  var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

private extension Digest {
  var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

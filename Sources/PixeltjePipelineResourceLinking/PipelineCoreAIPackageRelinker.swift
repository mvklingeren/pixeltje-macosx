import CryptoKit
import Foundation
import PixeltjePipelineDomain

public struct PipelineResourceRelinkNotice: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case information
  }

  public var kind: Kind
  public var message: String

  public init(kind: Kind, message: String) {
    self.kind = kind
    self.message = message
  }
}

public struct PipelineResourceRelinkResult: Sendable {
  public var document: PipelineDocument
  public var packageID: String
  public var packageVersion: String
  public var linkedResourceCount: Int
  public var remainingUnresolvedResourceCount: Int
  public var notices: [PipelineResourceRelinkNotice]
}

public enum PipelineResourceRelinkError: Error, LocalizedError, Sendable {
  case packageIsNotDirectory(String)
  case missingComponent(String)
  case missingComponentIdentity(String)
  case incompatiblePackage(String)
  case noCompatibleRequirements

  public var errorDescription: String? {
    switch self {
    case .packageIsNotDirectory(let path):
      "The Core AI package is not an accessible directory: \(path)"
    case .missingComponent(let path):
      "The selected Core AI package does not contain \(path)."
    case .missingComponentIdentity(let path):
      "The selected Core AI component does not contain a usable \(path)/main.hash."
    case .incompatiblePackage(let message):
      "The selected Core AI package is incompatible: \(message)"
    case .noCompatibleRequirements:
      "The converted workflow has no supported resources that match the selected Core AI package."
    }
  }
}

/// Performs explicit, name-based relinking against a user-supplied Core AI
/// directory. The caller is responsible for supplying the intended package;
/// this operation does not audit or load the model payloads.
public enum PipelineCoreAIPackageRelinker {
  public static let flux2KleinPackageID = "coreai.black-forest-labs.flux2-klein-4b"
  public static let flux2KleinFamilyABI = "flux2-klein-4b-coreai@2"
  public static let zImagePackageID = "coreai.z-image.z-image-turbo"
  public static let zImageCompositeABI = "z-image-coreai-seq64@1"

  public static func relinkNativeSDXS(
    in document: PipelineDocument,
    toPackageAt selectedURL: URL
  ) throws -> PipelineResourceRelinkResult {
    guard document.requirements.familyABIs.isEmpty else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "workflow-family ABIs were removed; convert this workflow to native nodes")
    }
    let package = try SDXSPackage(at: selectedURL)
    var linked = document
    var count = 0
    for index in linked.nodes.indices where linked.nodes[index].kind == SDXSPackage.nodeKind {
      let node = linked.nodes[index]
      for slot in ["denoiser", "textEncoder", "vaeDecoder"] {
        guard let binding = node.resources[slot] else {
          throw PipelineResourceRelinkError.incompatiblePackage(
            "the SDXS node is missing its \(slot) resource slot")
        }
        if let requirement = binding.unresolvedRequirement {
          guard requirement.familyABI == SDXSPackage.familyABI,
            requirement.kind == .coreAIModel
          else { throw PipelineResourceRelinkError.incompatiblePackage(
            "the SDXS \(slot) requirement has an incompatible ABI") }
        } else if let reference = binding.linkedReference {
          guard reference.packageID == SDXSPackage.packageID,
            reference.familyABI == SDXSPackage.familyABI
          else { throw PipelineResourceRelinkError.incompatiblePackage(
            "the SDXS \(slot) link has an incompatible ABI") }
        }
        linked.nodes[index].resources[slot] = .linked(try package.reference(for: slot))
        count += 1
      }
    }
    guard count > 0 else { throw PipelineResourceRelinkError.noCompatibleRequirements }
    return PipelineResourceRelinkResult(
      document: linked, packageID: SDXSPackage.packageID,
      packageVersion: package.version, linkedResourceCount: count,
      remainingUnresolvedResourceCount: linked.nodes.reduce(0) { result, node in
        result + node.resources.values.filter { $0.unresolvedRequirement != nil }.count
      },
      notices: [.init(kind: .information,
        message: "Linked the SDXS text encoder, UNet, and VAE.")])
  }

  public static func relinkNativeFlux9BSplit(
    in document: PipelineDocument,
    toPackageAt selectedURL: URL
  ) throws -> PipelineResourceRelinkResult {
    guard document.requirements.familyABIs.isEmpty else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "workflow-family ABIs were removed; convert this workflow to native nodes")
    }
    let package = try Flux9BSplitPackage(at: selectedURL)
    var linked = document
    var count = 0
    for index in linked.nodes.indices where linked.nodes[index].kind == Flux9BSplitPackage.nodeKind {
      let node = linked.nodes[index]
      let adapter: String?
      if case .string(let value)? = node.origin?.metadata["adapterSHA256"] {
        adapter = value
      } else {
        adapter = nil
      }
      guard adapter == package.adapterSHA256 else {
        throw PipelineResourceRelinkError.incompatiblePackage(
          "this workflow needs a different Klein 9B denoiser variant")
      }
      for slot in ["denoiser", "textEncoder", "vaeDecoder"] {
        guard let binding = node.resources[slot] else {
          throw PipelineResourceRelinkError.incompatiblePackage(
            "the Klein 9B node is missing its \(slot) resource slot")
        }
        if let requirement = binding.unresolvedRequirement {
          guard requirement.familyABI == Flux9BSplitPackage.familyABI,
            requirement.kind == .coreAIModel
          else {
            throw PipelineResourceRelinkError.incompatiblePackage(
              "the Klein 9B \(slot) requirement has an incompatible ABI")
          }
        } else if let reference = binding.linkedReference {
          guard reference.packageID == Flux9BSplitPackage.packageID,
            reference.familyABI == Flux9BSplitPackage.familyABI
          else {
            throw PipelineResourceRelinkError.incompatiblePackage(
              "the Klein 9B \(slot) link has an incompatible ABI")
          }
        }
        linked.nodes[index].resources[slot] = .linked(try package.reference(for: slot))
        count += 1
      }
    }
    guard count > 0 else { throw PipelineResourceRelinkError.noCompatibleRequirements }
    return PipelineResourceRelinkResult(
      document: linked, packageID: Flux9BSplitPackage.packageID,
      packageVersion: package.version, linkedResourceCount: count,
      remainingUnresolvedResourceCount: linked.nodes.reduce(0) { result, node in
        result + node.resources.values.filter { $0.unresolvedRequirement != nil }.count
      },
      notices: [.init(kind: .information,
        message: "Linked the Klein 9B split encoder, denoiser, and VAE.")])
  }

  public static func relinkNativeZImageComposite(
    in document: PipelineDocument,
    toPackageAt selectedURL: URL
  ) throws -> PipelineResourceRelinkResult {
    guard document.requirements.familyABIs.isEmpty else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "workflow-family ABIs were removed; convert this workflow to native nodes")
    }
    var linked = document
    var linkedCount = 0
    var packageVersion: String?
    for index in linked.nodes.indices
    where linked.nodes[index].kind.rawValue == "coreai.zImageGenerate" {
      let node = linked.nodes[index]
      func dimension(_ key: String) -> Int {
        if case .integer(let value)? = node.parameters[key] { return Int(value) }
        return 512
      }
      let resolution = ZImageResolution(
        width: dimension("width"), height: dimension("height"))
      let package = try ZImageCoreAIPackage(at: selectedURL, resolution: resolution)
      packageVersion = package.version
      let slots: [(String, ZImageComponent)] = [
        ("tokenizer", .tokenizer), ("promptEncoder", .promptEncoder),
        ("denoiser", .denoiser), ("timestepEmbedder", .timestepEmbedder),
        ("ropeMetadata", .ropeMetadata), ("ropeAxis0", .ropeAxis0),
        ("ropeAxis1", .ropeAxis1), ("ropeAxis2", .ropeAxis2),
        ("vaeDecoder", .vaeDecoder(resolution)),
      ]
      for (slot, component) in slots {
        guard node.resources[slot] != nil else {
          throw PipelineResourceRelinkError.incompatiblePackage(
            "native Z-Image node is missing its \(slot) resource slot")
        }
        linked.nodes[index].resources[slot] = .linked(
          package.reference(for: component, familyABI: zImageCompositeABI))
        linkedCount += 1
      }
    }
    guard linkedCount > 0, let packageVersion else {
      throw PipelineResourceRelinkError.noCompatibleRequirements
    }
    return PipelineResourceRelinkResult(
      document: linked, packageID: zImagePackageID,
      packageVersion: packageVersion, linkedResourceCount: linkedCount,
      remainingUnresolvedResourceCount: linked.nodes.reduce(0) { count, node in
        count + node.resources.values.filter { $0.unresolvedRequirement != nil }.count
      },
      notices: [.init(kind: .information,
        message: "Linked native Z-Image nodes to the selected package.")])
  }

  /// Explicitly bind every native FLUX generation node to the selected export.
  /// A second selection replaces the old package identity in the recipe.
  public static func relinkNativeFluxComposite(
    in document: PipelineDocument,
    toPackageAt selectedURL: URL
  ) throws -> PipelineResourceRelinkResult {
    guard document.requirements.familyABIs.isEmpty else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "workflow-family ABIs were removed; convert this workflow to native nodes")
    }
    let imageConditionedNodeIDs = Set(document.connections.filter {
      $0.input.port == "referenceImage"
    }.map(\.input.nodeID))
    let needsEncoder = document.nodes.contains {
      $0.kind.rawValue == "coreai.flux2KleinGenerate"
        && ($0.resources["vaeEncoder"] != nil || imageConditionedNodeIDs.contains($0.id))
    }
    let required = Set(ResourceMatch.Component.core)
      .union(needsEncoder ? [.vaeEncoder] : [])
    let package = try CoreAIPackage(at: selectedURL, requiredComponents: required)
    let baseSlots: [(String, ResourceMatch.Component, String)] = [
      ("denoiser", .denoiser, "denoiser"),
      ("textEncoder", .textEncoder, "textEncoder"),
      ("vaeDecoder", .vaeDecoder, "vae"),
    ]
    var linkedDocument = document
    var linkedCount = 0
    for index in linkedDocument.nodes.indices
    where linkedDocument.nodes[index].kind.rawValue == "coreai.flux2KleinGenerate" {
      let imageConditioned = linkedDocument.nodes[index].resources["vaeEncoder"] != nil
        || imageConditionedNodeIDs.contains(linkedDocument.nodes[index].id)
      let slots = baseSlots + (imageConditioned
        ? [("vaeEncoder", .vaeEncoder, "vaeEncoder")] : [])
      for (slot, component, role) in slots {
        guard let binding = linkedDocument.nodes[index].resources[slot] else {
          if slot == "vaeEncoder" {
            let asset = package.components[component]!
            linkedDocument.nodes[index].resources[slot] = .linked(
              PipelineResourceReference(
                kind: .coreAIModel, packageID: flux2KleinPackageID,
                packageVersion: package.version, contentHash: asset.contentHash,
                componentRole: role, functionName: "main",
                familyABI: flux2KleinFamilyABI))
            linkedCount += 1
            continue
          }
          throw PipelineResourceRelinkError.incompatiblePackage(
            "native FLUX node is missing its \(slot) resource slot")
        }
        if let requirement = binding.unresolvedRequirement {
          guard ResourceMatch(requirement)?.component == component else {
            throw PipelineResourceRelinkError.incompatiblePackage(
              "native FLUX node has an unrecognized \(slot) requirement")
          }
        } else if let reference = binding.linkedReference {
          guard reference.packageID == flux2KleinPackageID,
            reference.familyABI == flux2KleinFamilyABI,
            reference.componentRole == role,
            reference.kind == .coreAIModel,
            reference.functionName == "main"
          else {
            throw PipelineResourceRelinkError.incompatiblePackage(
              "native FLUX node has an incompatible \(slot) link")
          }
        } else {
          throw PipelineResourceRelinkError.incompatiblePackage(
            "native FLUX node has an invalid \(slot) binding")
        }
        let asset = package.components[component]!
        linkedDocument.nodes[index].resources[slot] = .linked(
          PipelineResourceReference(
            kind: .coreAIModel,
            packageID: flux2KleinPackageID,
            packageVersion: package.version,
            contentHash: asset.contentHash,
            componentRole: role,
            functionName: "main",
            familyABI: flux2KleinFamilyABI))
        linkedCount += 1
      }
    }
    guard linkedCount > 0 else { throw PipelineResourceRelinkError.noCompatibleRequirements }
    let remaining = linkedDocument.nodes.reduce(0) { count, node in
      count + node.resources.values.filter { $0.unresolvedRequirement != nil }.count
    }
    return PipelineResourceRelinkResult(
      document: linkedDocument,
      packageID: flux2KleinPackageID,
      packageVersion: package.version,
      linkedResourceCount: linkedCount,
      remainingUnresolvedResourceCount: remaining,
      notices: [.init(kind: .information,
        message: "Linked native FLUX.2 Klein nodes to the selected export.")])
  }

  /// Retired whole-graph entry point. Callers receive a migration error.
  public static func relinkFlux2ToCompiledPackage(
    in document: PipelineDocument,
    at selectedURL: URL
  ) throws -> PipelineResourceRelinkResult {
    throw PipelineResourceRelinkError.incompatiblePackage(
      "whole-graph FLUX.2 relinking was removed; relink a native FLUX.2 generation node")
  }

  public static func relinkCompatibleResources(
    in document: PipelineDocument,
    toPackageAt selectedURL: URL
  ) throws -> PipelineResourceRelinkResult {
    guard document.requirements.familyABIs.isEmpty else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "workflow-family ABIs were removed; convert this workflow to native nodes")
    }
    let hasZImage = document.nodes.contains { $0.kind.rawValue == "coreai.zImageGenerate" }
    let hasFlux = document.nodes.contains { $0.kind.rawValue == "coreai.flux2KleinGenerate" }
    let hasFlux9B = document.nodes.contains { $0.kind == Flux9BSplitPackage.nodeKind }
    let hasSDXS = document.nodes.contains { $0.kind == SDXSPackage.nodeKind }
    guard [hasZImage, hasFlux, hasFlux9B, hasSDXS].filter({ $0 }).count <= 1 else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "this graph contains multiple generation families; relink each package explicitly")
    }
    if hasFlux9B {
      return try relinkNativeFlux9BSplit(in: document, toPackageAt: selectedURL)
    }
    if hasSDXS {
      return try relinkNativeSDXS(in: document, toPackageAt: selectedURL)
    }
    if hasZImage {
      return try relinkNativeZImageComposite(in: document, toPackageAt: selectedURL)
    }
    if hasFlux {
      return try relinkNativeFluxComposite(in: document, toPackageAt: selectedURL)
    }
    throw PipelineResourceRelinkError.incompatiblePackage(
      "no native Core AI generation node is available to relink")
  }


}

private struct ZImageResolution: Hashable {
  var width: Int
  var height: Int

  var suffix: String { width == height ? String(width) : "\(width)x\(height)" }
}

private enum ZImageComponent: Hashable {
  case denoiser
  case promptEncoder
  case vaeDecoder(ZImageResolution)
  case timestepEmbedder
  case tokenizer
  case ropeMetadata
  case ropeAxis0
  case ropeAxis1
  case ropeAxis2

  var kind: PipelineResourceKind {
    switch self {
    case .tokenizer: .tokenizer
    case .ropeMetadata, .ropeAxis0, .ropeAxis1, .ropeAxis2: .data
    default: .coreAIModel
    }
  }

  var role: String {
    switch self {
    case .denoiser: "denoiser"
    case .promptEncoder: "promptEncoder"
    case .vaeDecoder: "vaeDecoder"
    case .timestepEmbedder: "timestepEmbedder"
    case .tokenizer: "tokenizer"
    case .ropeMetadata: "ropeMetadata"
    case .ropeAxis0: "ropeAxis0"
    case .ropeAxis1: "ropeAxis1"
    case .ropeAxis2: "ropeAxis2"
    }
  }

  var relativePath: String {
    switch self {
    case .denoiser:
      "zimage_dit_512_cap32_full_native_bf16_dyncap_dynimg_iofp32.aimodel"
    case .promptEncoder:
      "zimage_encoder_seq64_full_bf16_ids_iofp32.aimodel"
    case .vaeDecoder(let resolution):
      "zimage_vae_\(resolution.suffix)_fp32.aimodel"
    case .timestepEmbedder:
      "glue/zimage_t_embedder_fp32/zimage_t_embedder_fp32.aimodel"
    case .tokenizer:
      "tokenizer/tokenizer.json"
    case .ropeMetadata:
      "glue/rope_meta.json"
    case .ropeAxis0:
      "glue/rope_axis0.f32"
    case .ropeAxis1:
      "glue/rope_axis1.f32"
    case .ropeAxis2:
      "glue/rope_axis2.f32"
    }
  }

  var isModel: Bool { kind == .coreAIModel }
}

private struct ZImageCoreAIPackage {
  var version: String
  private var hashes: [ZImageComponent: String]

  init(at selectedURL: URL, resolution: ZImageResolution) throws {
    let root = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw PipelineResourceRelinkError.packageIsNotDirectory(root.path) }
    let nested = root.appendingPathComponent("Resources", isDirectory: true)
    let resources = FileManager.default.fileExists(atPath: nested.path) ? nested : root
    let components: [ZImageComponent] = [
      .denoiser, .promptEncoder, .vaeDecoder(resolution), .timestepEmbedder,
      .tokenizer, .ropeMetadata, .ropeAxis0, .ropeAxis1, .ropeAxis2,
    ]
    var hashes: [ZImageComponent: String] = [:]
    var versionHasher = SHA256()
    for component in components {
      let url = resources.appendingPathComponent(
        component.relativePath, isDirectory: component.isModel)
      var componentIsDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &componentIsDirectory),
        component.isModel == componentIsDirectory.boolValue
      else { throw PipelineResourceRelinkError.missingComponent(component.relativePath) }

      let identityData: Data
      if component.isModel {
        let hashURL = url.appendingPathComponent("main.hash")
        guard let data = try? Data(contentsOf: hashURL), !data.isEmpty else {
          throw PipelineResourceRelinkError.missingComponentIdentity(component.relativePath)
        }
        identityData = data
      } else {
        identityData = Data(SHA256.hash(data: try Data(contentsOf: url)))
      }
      let contentHash = Self.normalizedHash(identityData)
      hashes[component] = contentHash
      versionHasher.update(data: Data(component.relativePath.utf8))
      versionHasher.update(data: Data([0]))
      versionHasher.update(data: identityData)
      versionHasher.update(data: Data([0]))
    }
    version = "sha256." + Data(versionHasher.finalize()).hexadecimalString
    self.hashes = hashes
  }

  func reference(
    for component: ZImageComponent,
    familyABI: String
  ) -> PipelineResourceReference {
    PipelineResourceReference(
      kind: component.kind,
      packageID: PipelineCoreAIPackageRelinker.zImagePackageID,
      packageVersion: version,
      contentHash: hashes[component]!,
      componentRole: component.role,
      functionName: component.isModel ? "main" : nil,
      familyABI: familyABI)
  }

  private static func normalizedHash(_ data: Data) -> String {
    if let string = String(data: data, encoding: .utf8) {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) { return trimmed }
    }
    return data.hexadecimalString
  }
}

private struct ResourceMatch {
  enum Component: String, CaseIterable, Hashable {
    case denoiser
    case textEncoder
    case vaeDecoder
    case vaeEncoder

    static let core: [Self] = [.denoiser, .textEncoder, .vaeDecoder]

    var relativePath: String {
      switch self {
      case .denoiser: "Transformer.aimodel"
      case .textEncoder: "TextEncoder.aimodel"
      case .vaeDecoder: "VAEDecoder.aimodel"
      case .vaeEncoder: "VAEEncoder.aimodel"
      }
    }
  }

  var component: Component

  init?(_ requirement: PipelineResourceRequirement) {
    guard requirement.kind == .coreAIModel,
      requirement.sourceFormat?.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() == "safetensors"
    else { return nil }

    let sourceName = Self.normalizedSourceName(requirement.sourceName)
    let basename = sourceName.split(separator: "/").last.map(String.init) ?? sourceName
    switch requirement.componentRole.lowercased() {
    case "denoiser":
      guard
        Self.distilledDenoisers.contains(sourceName)
          || Self.distilledDenoisers.contains(basename)
      else { return nil }
      component = .denoiser
    case "textencoder":
      guard Self.textEncoders.contains(sourceName) || Self.textEncoders.contains(basename)
      else { return nil }
      component = .textEncoder
    case "vae":
      guard Self.vaeDecoders.contains(sourceName) || Self.vaeDecoders.contains(basename)
      else { return nil }
      component = .vaeDecoder
    case "vaeencoder":
      guard Self.vaeDecoders.contains(sourceName) || Self.vaeDecoders.contains(basename)
      else { return nil }
      component = .vaeEncoder
    default:
      return nil
    }
  }

  private static let distilledDenoisers: Set<String> = [
    "diffusion_models/flux-2-klein-4b.safetensors", "flux-2-klein-4b.safetensors",
  ]
  private static let textEncoders: Set<String> = [
    "text_encoders/qwen_3_4b.safetensors", "qwen_3_4b.safetensors",
  ]
  private static let vaeDecoders: Set<String> = [
    "vae/flux2-vae.safetensors", "flux2-vae.safetensors",
  ]

  private static func normalizedSourceName(_ value: String) -> String {
    var normalized = value.replacingOccurrences(of: "\\", with: "/")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasPrefix("./") { normalized.removeFirst(2) }
    return normalized.lowercased()
  }
}

private struct CoreAIPackage {
  struct ComponentRecord {
    var contentHash: String
    var sourceHash: String?
  }

  var version: String
  var components: [ResourceMatch.Component: ComponentRecord]

  init(at selectedURL: URL, requiredComponents: Set<ResourceMatch.Component>) throws {
    let root = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw PipelineResourceRelinkError.packageIsNotDirectory(root.path)
    }

    let metadataURL = root.appendingPathComponent("metadata.json")
    guard let metadataData = try? Data(contentsOf: metadataURL),
      let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
      let source = metadata["source"] as? [String: Any],
      let diffusion = metadata["diffusion"] as? [String: Any],
      let assets = metadata["assets"] as? [String: Any],
      source["hf_model_id"] as? String == "black-forest-labs/FLUX.2-klein-4B",
      diffusion["guidance_embeds"] as? Bool == false,
      (diffusion["default_steps"] as? NSNumber)?.intValue == 4,
      (diffusion["default_guidance_scale"] as? NSNumber)?.doubleValue == 1,
      assets["transformer"] as? String == "Transformer.aimodel"
    else {
      throw PipelineResourceRelinkError.incompatiblePackage(
        "metadata.json must identify the guidance-distilled black-forest-labs/FLUX.2-klein-4B export and its Transformer.aimodel asset."
      )
    }

    var components: [ResourceMatch.Component: ComponentRecord] = [:]
    var versionHasher = SHA256()
    for component in ResourceMatch.Component.allCases where requiredComponents.contains(component) {
      // The pinned Apple runtime resolves a missing .aimodel to .aimodelc.
      // Hash the asset it will actually load, so compiled packages require an
      // explicit relink instead of silently inheriting the source identity.
      let sourceURL = root.appendingPathComponent(component.relativePath, isDirectory: true)
      let relativePath = FileManager.default.fileExists(atPath: sourceURL.path)
        ? component.relativePath : component.relativePath + "c"
      let componentURL = root.appendingPathComponent(relativePath, isDirectory: true)
      var componentIsDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(
        atPath: componentURL.path, isDirectory: &componentIsDirectory)
      if requiredComponents.contains(component), !exists || !componentIsDirectory.boolValue {
        throw PipelineResourceRelinkError.missingComponent(component.relativePath)
      }
      guard exists, componentIsDirectory.boolValue else { continue }

      let hashURL = componentURL.appendingPathComponent("main.hash")
      guard let hashData = try? Data(contentsOf: hashURL), !hashData.isEmpty else {
        if requiredComponents.contains(component) {
          throw PipelineResourceRelinkError.missingComponentIdentity(component.relativePath)
        }
        continue
      }
      let contentHash = Self.normalizedHash(hashData)
      let sourceHash: String?
      if relativePath.hasSuffix(".aimodelc") {
        let metadataURL = componentURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
          let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hash = metadata["sourceHash"] as? String,
          hash.count == 64, hash.allSatisfy(\.isHexDigit)
        else {
          throw PipelineResourceRelinkError.missingComponentIdentity(relativePath)
        }
        sourceHash = hash.lowercased()
      } else {
        sourceHash = nil
      }
      components[component] = ComponentRecord(contentHash: contentHash, sourceHash: sourceHash)
      versionHasher.update(data: Data(relativePath.utf8))
      versionHasher.update(data: Data([0]))
      versionHasher.update(data: hashData)
      versionHasher.update(data: Data([0]))
    }
    version = "sha256." + Data(versionHasher.finalize()).hexadecimalString
    self.components = components
  }

  private static func normalizedHash(_ data: Data) -> String {
    if let string = String(data: data, encoding: .utf8) {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if trimmed.count == 64, trimmed.allSatisfy({ $0.isHexDigit }) { return trimmed }
    }
    return data.hexadecimalString
  }

  static func normalizedHashString(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

extension Data {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

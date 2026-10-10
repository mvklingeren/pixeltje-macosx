import CoreAI
import CryptoKit
import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import Testing

@testable import PixeltjePipelineFLUX2Runtime

@Test func flux2CompositeNodeRejectsUnsupportedSettingsBeforeExecution() {
  let executor = FLUX2KleinPipelineFamily.makeNodeExecutor(
    runner: FLUX2KleinPipelineRunner())
  var node = FLUX2KleinPipelineFamily.makeCompositeNode(
    id: PipelineNodeID(rawValue: "flux"))
  #expect(executor.validate(node).isEmpty)
  node.parameters["guidance"] = .number(2)
  #expect(executor.validate(node).contains {
    $0.code == .invalidParameter && $0.nodeID == node.id
  })
}

@Test func flux2KleinInspectionRejectsGitLFSPointersAndAcceptsMaterializedComponents() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  for component in ["Transformer.aimodel", "TextEncoder.aimodel", "VAEDecoder.aimodel"] {
    let bundle = root.appendingPathComponent(component, isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data("version https://git-lfs.github.com/spec/v1".utf8)
      .write(to: bundle.appendingPathComponent("main.mlirb"))
    try Data(repeating: 7, count: 32).write(to: bundle.appendingPathComponent("main.hash"))
  }
  try writeSidecars(to: root)

  let pointerInspection = FLUX2KleinPipelineFamily.inspectPackage(at: root)
  #expect(!pointerInspection.isUsable)
  #expect(
    pointerInspection.missingComponents.contains {
      $0.contains("Transformer.aimodel/main.mlirb")
    })

  for component in ["Transformer.aimodel", "TextEncoder.aimodel", "VAEDecoder.aimodel"] {
    try Data(repeating: 1, count: 1024)
      .write(to: root.appendingPathComponent(component + "/main.mlirb"))
  }
  let materializedInspection = FLUX2KleinPipelineFamily.inspectPackage(at: root)
  #expect(materializedInspection.isUsable, Comment(rawValue: materializedInspection.summary))

  let originalKey = try FLUX2KleinPipelineFamily.packageKey(at: root)
  let alias = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
  defer { try? FileManager.default.removeItem(at: alias) }
  #expect(try FLUX2KleinPipelineFamily.packageKey(at: alias) == originalKey)

  let tokenizerConfig = root.appendingPathComponent("tokenizer/tokenizer_config.json")
  try Data("{\"changed\":true}".utf8).write(to: tokenizerConfig)
  let sidecarKey = try FLUX2KleinPipelineFamily.packageKey(at: root)
  #expect(sidecarKey != originalKey)

  let payload = root.appendingPathComponent("Transformer.aimodel/main.mlirb")
  try Data(repeating: 2, count: 1025).write(to: payload)
  let payloadKey = try FLUX2KleinPipelineFamily.packageKey(at: root)
  #expect(payloadKey != sidecarKey)

  let componentHash = root.appendingPathComponent("Transformer.aimodel/main.hash")
  try Data(repeating: 8, count: 32).write(to: componentHash)
  let componentKey = try FLUX2KleinPipelineFamily.packageKey(at: root)
  #expect(componentKey != payloadKey)

  try Data("{}".utf8).write(to: root.appendingPathComponent("metadata.json"))
  let wrongMetadataInspection = FLUX2KleinPipelineFamily.inspectPackage(at: root)
  #expect(!wrongMetadataInspection.isUsable)
  #expect(wrongMetadataInspection.incompatibleComponents.contains {
    $0.contains("guidance-distilled FLUX.2 Klein 4B")
  })
}

@Test func flux2KleinInspectionAcceptsCompiledOnlyAssetsForCurrentArchitecture() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let architecture = AIModel.deviceArchitectureName
  for component in ["Transformer", "TextEncoder", "VAEDecoder"] {
    let bundle = root.appendingPathComponent(component + ".aimodelc", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 1024).write(
      to: bundle.appendingPathComponent("main-\(architecture).mlirb"))
    try Data(repeating: 7, count: 32).write(to: bundle.appendingPathComponent("main.hash"))
    try Data("{\"sourceHash\":\"\(String(repeating: "a", count: 64))\"}".utf8)
      .write(to: bundle.appendingPathComponent("metadata.json"))
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("main-\(architecture)-delegates"),
      withIntermediateDirectories: true)
  }
  try writeSidecars(to: root)
  let inspection = FLUX2KleinPipelineFamily.inspectPackage(at: root)
  #expect(inspection.isUsable, Comment(rawValue: inspection.summary))
  let transformerPayload = root.appendingPathComponent(
    "Transformer.aimodelc/main-\(architecture).mlirb")
  try Data("version https://git-lfs.github.com/spec/v1".utf8).write(to: transformerPayload)
  #expect(!FLUX2KleinPipelineFamily.inspectPackage(at: root).isUsable)
  try Data(repeating: 1, count: 1024).write(to: transformerPayload)
  try FileManager.default.removeItem(
    at: transformerPayload)
  #expect(!FLUX2KleinPipelineFamily.inspectPackage(at: root).isUsable)
}

@Test func flux2ImageConditionedPackageKeepsItsIdentityOnFirstTextOnlyCall() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let components: [(slot: String, role: String, path: String, byte: UInt8)] = [
    ("denoiser", "denoiser", "Transformer.aimodel", 1),
    ("textEncoder", "textEncoder", "TextEncoder.aimodel", 2),
    ("vaeDecoder", "vae", "VAEDecoder.aimodel", 3),
    ("vaeEncoder", "vaeEncoder", "VAEEncoder.aimodel", 4),
  ]
  var versionHasher = SHA256()
  for component in components {
    let bundle = root.appendingPathComponent(component.path, isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data(repeating: component.byte, count: 1024)
      .write(to: bundle.appendingPathComponent("main.mlirb"))
    let hash = Data(repeating: component.byte, count: 32)
    try hash.write(to: bundle.appendingPathComponent("main.hash"))
    versionHasher.update(data: Data(component.path.utf8))
    versionHasher.update(data: Data([0]))
    versionHasher.update(data: hash)
    versionHasher.update(data: Data([0]))
  }
  try writeSidecars(to: root, includesVAEEncoder: true)

  let version = "sha256." + Data(versionHasher.finalize())
    .map { String(format: "%02x", $0) }.joined()
  var node = FLUX2KleinPipelineFamily.makeCompositeNode(
    id: PipelineNodeID(rawValue: "generate"))
  for component in components {
    node.resources[component.slot] = .linked(PipelineResourceReference(
      kind: .coreAIModel,
      packageID: FLUX2KleinPipelineFamily.packageID,
      packageVersion: version,
      contentHash: Data(repeating: component.byte, count: 32)
        .map { String(format: "%02x", $0) }.joined(),
      componentRole: component.role,
      functionName: "main",
      familyABI: FLUX2KleinPipelineFamily.familyABI))
  }
  let document = PipelineDocument(
    id: PipelineID(rawValue: "image-conditioned-first-call"),
    name: "Image-conditioned first call", mode: .textToImage,
    nodes: [node], connections: [])

  let inspection = FLUX2KleinPipelineFamily.inspectPackage(at: root, for: document)
  #expect(inspection.isUsable, Comment(rawValue: inspection.summary))
}

@Test func flux2KleinTransformerABIRequiresInGraphRoPEPositionIDs() {
  let current = [
    FLUX2KleinTensorDescriptor(
      name: "hidden_states", shape: [1, 4096, 128], scalarType: "float16"),
    FLUX2KleinTensorDescriptor(
      name: "encoder_hidden_states", shape: [1, 512, 7680], scalarType: "float16"),
    FLUX2KleinTensorDescriptor(name: "timestep", shape: [1], scalarType: "float16"),
    FLUX2KleinTensorDescriptor(name: "guidance", shape: [1], scalarType: "float16"),
    FLUX2KleinTensorDescriptor(
      name: "img_ids", shape: [1, 4096, 4], scalarType: "float32"),
    FLUX2KleinTensorDescriptor(
      name: "txt_ids", shape: [1, 512, 4], scalarType: "float32"),
  ]
  #expect(FLUX2KleinPipelineFamily.transformerABIProblem(current) == nil)

  var legacy = current
  legacy[4] = FLUX2KleinTensorDescriptor(
    name: "rotary_emb_cos", shape: [4608, 128], scalarType: "float32")
  legacy[5] = FLUX2KleinTensorDescriptor(
    name: "rotary_emb_sin", shape: [4608, 128], scalarType: "float32")
  #expect(
    FLUX2KleinPipelineFamily.transformerABIProblem(legacy)?.contains("legacy precomputed-RoPE")
      == true)

  var wrongRank = current
  wrongRank[4].shape = [4096, 4]
  #expect(FLUX2KleinPipelineFamily.transformerABIProblem(wrongRank) != nil)
}

private func writeSidecars(to root: URL, includesVAEEncoder: Bool = false) throws {
  let tokenizer = root.appendingPathComponent("tokenizer", isDirectory: true)
  try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
  var assets = ["transformer": "Transformer.aimodel"]
  if includesVAEEncoder { assets["vae_encoder"] = "VAEEncoder.aimodel" }
  let metadata: [String: Any] = [
    "assets": assets,
    "diffusion": [
      "guidance_embeds": false,
      "default_guidance_scale": 1,
      "default_steps": 4,
    ],
    "source": ["hf_model_id": "black-forest-labs/FLUX.2-klein-4B"],
  ]
  try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    .write(to: root.appendingPathComponent("metadata.json"))
  for path in [
    "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json",
    "vae_bn_mean.npy", "vae_bn_var.npy",
  ] {
    try Data("{}".utf8).write(to: root.appendingPathComponent(path))
  }
}

import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineResourceLinking
import Testing

@Test func convertedFluxGraphCannotInstallAFamilyExecutor() throws {
  let packageURL = try makeFluxPackageFixture()
  defer { try? FileManager.default.removeItem(at: packageURL) }
  #expect(throws: PipelineResourceRelinkError.self) {
    try PipelineCoreAIPackageRelinker.relinkCompatibleResources(
      in: makeFluxDocument(), toPackageAt: packageURL)
  }
}

@Test func nativeFluxNodeKeepsNodeSchedulingAfterPackageLink() throws {
  let packageURL = try makeFluxPackageFixture()
  defer { try? FileManager.default.removeItem(at: packageURL) }
  let imported = makeFluxDocument()
  let resources: [String: PipelineResourceBinding] = [
    "denoiser": imported.nodes[0].resources["model"]!,
    "textEncoder": imported.nodes[1].resources["model"]!,
    "vaeDecoder": imported.nodes[2].resources["model"]!,
  ]
  let document = PipelineDocument(
    id: PipelineID(rawValue: "native-flux-link"),
    name: "Native FLUX link", mode: .textToImage,
    nodes: [PipelineNode(
      id: PipelineNodeID(rawValue: "generate"),
      kind: PipelineNodeKind(rawValue: "coreai.flux2KleinGenerate"),
      resources: resources)],
    connections: [])
  let result = try PipelineCoreAIPackageRelinker.relinkNativeFluxComposite(
    in: document, toPackageAt: packageURL)
  #expect(result.linkedResourceCount == 3)
  #expect(result.document.requirements.familyABIs.isEmpty)
  #expect(result.document.nodes[0].resources.values.allSatisfy {
    $0.linkedReference?.packageID == PipelineCoreAIPackageRelinker.flux2KleinPackageID
  })
  let secondPackage = try makeFluxPackageFixture()
  defer { try? FileManager.default.removeItem(at: secondPackage) }
  try Data(repeating: 4, count: 32).write(to: secondPackage
    .appendingPathComponent("Transformer.aimodel/main.hash"))
  let rebound = try PipelineCoreAIPackageRelinker.relinkNativeFluxComposite(
    in: result.document, toPackageAt: secondPackage)
  #expect(rebound.packageVersion != result.packageVersion)
  #expect(rebound.document.requirements.familyABIs.isEmpty)
  #expect(rebound.document.nodes[0].resources.values.allSatisfy {
    $0.linkedReference?.packageVersion == rebound.packageVersion
  })
}

@Test func oldCompiledFluxRelinkerFailsClearly() throws {
  let packageURL = try makeFluxPackageFixture()
  defer { try? FileManager.default.removeItem(at: packageURL) }
  #expect(throws: PipelineResourceRelinkError.self) {
    try PipelineCoreAIPackageRelinker.relinkFlux2ToCompiledPackage(
      in: makeFluxDocument(), at: packageURL)
  }
}

@Test func convertedZImageGraphCannotInstallAFamilyExecutor() throws {
  let packageURL = try makeZImagePackageFixture(resolution: "1024")
  defer { try? FileManager.default.removeItem(at: packageURL) }
  #expect(throws: PipelineResourceRelinkError.self) {
    try PipelineCoreAIPackageRelinker.relinkCompatibleResources(
      in: makeZImageDocument(), toPackageAt: packageURL)
  }
}

@Test func nativeZImageNodeLinksEveryComponentWithoutAFamilyABI() throws {
  let packageURL = try makeZImagePackageFixture(resolution: "1024")
  defer { try? FileManager.default.removeItem(at: packageURL) }
  let slots = [
    "denoiser", "promptEncoder", "vaeDecoder", "timestepEmbedder", "tokenizer",
    "ropeMetadata", "ropeAxis0", "ropeAxis1", "ropeAxis2",
  ]
  let resources = Dictionary(uniqueKeysWithValues: slots.map { slot in
    (slot, PipelineResourceBinding.unresolved(.init(
      kind: .data, componentRole: slot, sourceName: slot)))
  })
  let document = PipelineDocument(
    id: PipelineID(rawValue: "native-z-image-link"), name: "Native Z-Image link",
    mode: .textToImage,
    nodes: [PipelineNode(
      id: PipelineNodeID(rawValue: "generate"),
      kind: PipelineNodeKind(rawValue: "coreai.zImageGenerate"),
      parameters: ["width": .integer(1024), "height": .integer(1024)],
      resources: resources)],
    connections: [])
  let result = try PipelineCoreAIPackageRelinker.relinkCompatibleResources(
    in: document, toPackageAt: packageURL)
  #expect(result.linkedResourceCount == 9)
  #expect(result.document.requirements.familyABIs.isEmpty)
  #expect(result.document.nodes[0].resources.values.allSatisfy {
    $0.linkedReference?.familyABI == PipelineCoreAIPackageRelinker.zImageCompositeABI
  })
}

private func makeFluxDocument(
  denoiserName: String = "diffusion_models/flux-2-klein-4b.safetensors",
  denoiserState: PipelineNodeExecutionState = .enabled
) -> PipelineDocument {
  let denoiserID = PipelineNodeID(rawValue: "denoiser")
  let encoderID = PipelineNodeID(rawValue: "encoder")
  let vaeID = PipelineNodeID(rawValue: "vae")
  let decoderID = PipelineNodeID(rawValue: "decoder")
  return PipelineDocument(
    id: PipelineID(rawValue: "flux2-base-import"),
    name: "FLUX.2 Base import",
    mode: .textToImage,
    nodes: [
      PipelineNode(
        id: denoiserID,
        kind: PipelineNodeKind(rawValue: "coreai.denoiser"),
        resources: [
          "model": .unresolved(
            PipelineResourceRequirement(
              kind: .coreAIModel,
              componentRole: "denoiser",
              sourceName: denoiserName,
              sourceFormat: "safetensors"))
        ],
        executionState: denoiserState),
      PipelineNode(
        id: encoderID,
        kind: PipelineNodeKind(rawValue: "coreai.textEncoderModel"),
        resources: [
          "model": .unresolved(
            PipelineResourceRequirement(
              kind: .coreAIModel,
              componentRole: "textEncoder",
              sourceName: "text_encoders/qwen_3_4b.safetensors",
              sourceFormat: "safetensors"))
        ]),
      PipelineNode(
        id: vaeID,
        kind: PipelineNodeKind(rawValue: "coreai.vaeModel"),
        resources: [
          "model": .unresolved(
            PipelineResourceRequirement(
              kind: .coreAIModel,
              componentRole: "vae",
              sourceName: "vae/flux2-vae.safetensors",
              sourceFormat: "safetensors"))
        ]),
      PipelineNode(
        id: decoderID,
        kind: PipelineNodeKind(rawValue: "coreai.vaeImageDecoder")),
    ],
    connections: [
      PipelineConnection(
        output: PipelinePortReference(nodeID: vaeID, port: "vae"),
        input: PipelinePortReference(nodeID: decoderID, port: "vae"))
    ])
}

private func makeZImageDocument() -> PipelineDocument {
  func requirement(_ role: String, _ name: String) -> PipelineResourceBinding {
    .unresolved(.init(
      kind: .coreAIModel,
      componentRole: role,
      sourceName: name,
      sourceFormat: "safetensors"))
  }
  return PipelineDocument(
    id: .init(rawValue: "z-image-import"),
    name: "Z-Image import",
    mode: .textToImage,
    nodes: [
      PipelineNode(
        id: .init(rawValue: "denoiser"),
        kind: .init(rawValue: "coreai.denoiser"),
        resources: ["model": requirement(
          "denoiser", "diffusion_models/z_image_turbo_bf16.safetensors")]),
      PipelineNode(
        id: .init(rawValue: "encoder"),
        kind: .init(rawValue: "coreai.textEncoderModel"),
        resources: ["model": requirement(
          "textEncoder", "text_encoders/qwen_3_4b.safetensors")]),
      PipelineNode(
        id: .init(rawValue: "vae"),
        kind: .init(rawValue: "coreai.vaeModel"),
        resources: ["model": requirement("vae", "vae/ae.safetensors")]),
      PipelineNode(
        id: .init(rawValue: "latent"),
        kind: .init(rawValue: "latent.emptyImage"),
        parameters: ["width": .integer(1024), "height": .integer(1024)]),
    ],
    connections: [])
}

private func makeFluxPackageFixture() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-flux-link-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let metadata: [String: Any] = [
    "assets": ["transformer": "Transformer.aimodel"],
    "diffusion": [
      "guidance_embeds": false,
      "default_guidance_scale": 1,
      "default_steps": 4,
    ],
    "source": ["hf_model_id": "black-forest-labs/FLUX.2-klein-4B"],
  ]
  try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    .write(to: root.appendingPathComponent("metadata.json"))
  let components = [
    ("Transformer.aimodel", UInt8(1)),
    ("TextEncoder.aimodel", UInt8(2)),
    ("VAEDecoder.aimodel", UInt8(3)),
  ]
  for (name, byte) in components {
    let component = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    try Data(repeating: byte, count: 32).write(
      to: component.appendingPathComponent("main.hash"))
  }
  return root
}

private func makeZImagePackageFixture(resolution: String) throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-zimage-link-tests-\(UUID().uuidString)", isDirectory: true)
  let resources = root.appendingPathComponent("Resources", isDirectory: true)
  try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
  let models = [
    "zimage_dit_512_cap32_full_native_bf16_dyncap_dynimg_iofp32.aimodel",
    "zimage_encoder_seq64_full_bf16_ids_iofp32.aimodel",
    "zimage_vae_\(resolution)_fp32.aimodel",
    "glue/zimage_t_embedder_fp32/zimage_t_embedder_fp32.aimodel",
  ]
  for (index, path) in models.enumerated() {
    let component = resources.appendingPathComponent(path, isDirectory: true)
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    try Data(repeating: UInt8(index + 1), count: 32).write(
      to: component.appendingPathComponent("main.hash"))
  }
  let files = [
    "tokenizer/tokenizer.json", "glue/rope_meta.json", "glue/rope_axis0.f32",
    "glue/rope_axis1.f32", "glue/rope_axis2.f32",
  ]
  for (index, path) in files.enumerated() {
    let url = resources.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture-\(index)".utf8).write(to: url)
  }
  return root
}

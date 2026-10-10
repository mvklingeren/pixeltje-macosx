import CoreAIDiffusionPipeline
import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineResourceLinking

/// One-step SDXS text-to-image execution. All learned work remains in Core AI.
public enum SDXSPipelineFamily {
  public static let nodeKind = SDXSPackage.nodeKind
  public static let packageID = SDXSPackage.packageID

  public static func descriptor() -> PipelineNodeDescriptor {
    PipelineNodeDescriptor(
      kind: nodeKind, displayName: "SDXS 512 Generate", category: "Generation",
      inputs: [
        .init(name: "prompt", type: .prompt),
        .init(name: "seed", type: .seed, isRequired: false),
      ],
      outputs: [.init(name: "image", type: .image)],
      parameters: [
        .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
        .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
        .init(name: "steps", valueType: .integer, defaultValue: .integer(1)),
        .init(name: "guidance", valueType: .number, defaultValue: .number(0)),
      ],
      requiredResourceSlots: ["denoiser", "textEncoder", "vaeDecoder"])
  }

  public static func makeNode(id: PipelineNodeID) -> PipelineNode {
    let slots: [(String, String, String)] = [
      ("denoiser", "denoiser", "unet/diffusion_pytorch_model.safetensors"),
      ("textEncoder", "textEncoder", "text_encoder/model.safetensors"),
      ("vaeDecoder", "vae", "vae/diffusion_pytorch_model.safetensors"),
    ]
    let resources = Dictionary(uniqueKeysWithValues: slots.map { slot, role, source in
      (slot, PipelineResourceBinding.unresolved(.init(
        kind: .coreAIModel, componentRole: role, sourceName: source,
        sourceFormat: "safetensors", familyABI: SDXSPackage.familyABI)))
    })
    return PipelineNode(
      id: id, kind: nodeKind, title: "SDXS 512 Generate",
      parameters: [
        "width": .integer(512), "height": .integer(512),
        "steps": .integer(1), "guidance": .number(0),
      ], resources: resources)
  }

  public static func executor(runner: SDXSPipelineRunner) -> PipelineNodeExecutor {
    PipelineNodeExecutor(kind: nodeKind, validate: diagnostics) { node, inputs, context in
      guard let prompt = inputs["prompt"]?.value(as: String.self),
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw PipelineEngineError.invalidInvocation("Enter an SDXS prompt.") }
      let seed: UInt64
      if let supplied = inputs["seed"] {
        if let unsigned = supplied.value(as: UInt64.self) { seed = unsigned }
        else if let signed = supplied.value(as: Int64.self), signed >= 0 {
          seed = UInt64(signed)
        } else if let signed = supplied.value(as: Int.self), signed >= 0 {
          seed = UInt64(signed)
        } else {
          throw PipelineEngineError.invalidInvocation("SDXS seed must be non-negative.")
        }
      } else { seed = 0 }
      guard let exactSeed = UInt32(exactly: seed) else {
        throw PipelineEngineError.invalidInvocation("SDXS seed exceeds 32 bits.")
      }
      guard let reference = node.resources["denoiser"]?.linkedReference else {
        throw PipelineEngineError.modelPackageUnavailable("Link an SDXS package first.")
      }
      let root = try context.packageRoot(for: reference)
      let image = try await runner.generate(
        at: root, node: node, prompt: prompt, seed: exactSeed,
        semanticSHA256: context.semanticSHA256)
      return PipelineNodeResult(outputs: ["image": PipelineNodeValue(image, type: .image)])
    }
  }

  private static func diagnostics(_ node: PipelineNode) -> [PipelineDiagnostic] {
    func invalid(_ message: String) -> PipelineDiagnostic {
      .init(severity: .error, code: .invalidParameter, message: message, nodeID: node.id)
    }
    guard node.parameters["width"] == .integer(512),
      node.parameters["height"] == .integer(512),
      node.parameters["steps"] == .integer(1),
      node.parameters["guidance"] == .number(0)
    else { return [invalid("SDXS requires 512×512, one step, and guidance 0.")] }
    return []
  }

  public static func defaultPackageURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "coreai-models/exports/SDXS-512-DreamShaper", isDirectory: true)
  }

  public static func inspectPackage(at url: URL, for document: PipelineDocument) -> String? {
    do {
      let package = try SDXSPackage(at: url)
      for node in document.nodes where node.kind == nodeKind {
        try package.validateLinks(in: node)
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}

public actor SDXSPipelineRunner {
  private struct Loaded: Sendable {
    let version: String
    let tokenizer: SDXSCLIPTokenizer
    let textEncoder: CoreAIDiffusionModelFunction
    let denoiser: CoreAIDiffusionModelFunction
    let vaeDecoder: CoreAIDiffusionModelFunction
  }

  private var loaded: Loaded?
  // EulerDiscreteScheduler with the publisher's scaled-linear beta schedule,
  // trailing one-step spacing, and timestep 999. Verified against Diffusers.
  private let sigma: Float = 14.614646911621094

  public init() {}

  public func generate(
    at root: URL, node: PipelineNode, prompt: String, seed: UInt32,
    semanticSHA256: String
  ) async throws -> PipelineGeneratedImage {
    let package = try SDXSPackage(at: root)
    try package.validateLinks(in: node)
    try Task.checkCancellation()
    let components: Loaded
    if let loaded, loaded.version == package.version {
      components = loaded
    } else {
      let tokenizer = try SDXSCLIPTokenizer(
        directory: package.root.appendingPathComponent("tokenizer", isDirectory: true))
      let new = Loaded(
        version: package.version, tokenizer: tokenizer,
        textEncoder: CoreAIDiffusionModelFunction(modelURL: package.root
          .appendingPathComponent("TextEncoder.aimodel", isDirectory: true)),
        denoiser: CoreAIDiffusionModelFunction(modelURL: package.root
          .appendingPathComponent("Unet.aimodel", isDirectory: true)),
        vaeDecoder: CoreAIDiffusionModelFunction(modelURL: package.root
          .appendingPathComponent("VAEDecoder.aimodel", isDirectory: true)))
      loaded = new
      components = new
    }

    let tokenIDs = components.tokenizer.encode(prompt, length: 77)
    let text = try await components.textEncoder.run(intInputs: [(tokenIDs, [1, 77])])
    guard text.count == 77 * 768, text.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("SDXS text encoder returned invalid conditioning.")
    }
    try Task.checkCancellation()

    let count = 4 * 64 * 64
    let noise = generateNoise(count: count, seed: seed, sourceType: .torch)
    let scale = sigma / sqrt(sigma * sigma + 1)
    let modelInput = noise.map { $0 * scale }
    let prediction = try await components.denoiser.run(floatInputs: [
      (modelInput, [1, 4, 64, 64]),
      ([999], [1]),
      (text, [1, 77, 768]),
    ])
    guard prediction.count == count, prediction.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("SDXS UNet returned invalid latents.")
    }
    try Task.checkCancellation()

    // With one Euler step, sigma_next is zero and epsilon prediction gives
    // x_0 = sigma * noise - sigma * predicted_epsilon.
    let denoised = zip(noise, prediction).map { (sample, epsilon) in
      (sample - epsilon) * sigma
    }
    let pixels = try await components.vaeDecoder.run(floatInputs: [
      (denoised, [1, 4, 64, 64])
    ])
    guard pixels.count == 3 * 512 * 512, pixels.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("SDXS VAE returned invalid pixels.")
    }
    return PipelineGeneratedImage(
      width: 512, height: 512, planarRGB: pixels,
      encoding: .sRGBMinusOneToOne, semanticPipelineSHA256: semanticSHA256)
  }
}

import Foundation
import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let zImageGenerate = PipelineNodeKind(rawValue: "coreai.zImageGenerate")
}

public enum ZImageCompositeNode {
  public static func descriptor() -> PipelineNodeDescriptor {
    PipelineNodeDescriptor(
      kind: .zImageGenerate,
      displayName: "Z-Image Generate",
      category: "Generation",
      inputs: [
        .init(name: "prompt", type: .prompt),
        .init(name: "negativePrompt", type: .prompt, isRequired: false),
        .init(name: "seed", type: .seed, isRequired: false),
      ],
      outputs: [.init(name: "image", type: .image)],
      parameters: [
        .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
        .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
        .init(name: "steps", valueType: .integer, defaultValue: .integer(8)),
        .init(name: "guidance", valueType: .number, defaultValue: .number(1)),
      ],
      requiredResourceSlots: [
        "tokenizer", "promptEncoder", "denoiser", "timestepEmbedder",
        "ropeMetadata", "ropeAxis0", "ropeAxis1", "ropeAxis2", "vaeDecoder",
      ])
  }

  /// Starter node linked to the reviewed 512-pixel package identities.
  public static func makeNode(id: PipelineNodeID) -> PipelineNode {
    func linked(
      _ kind: PipelineResourceKind, _ role: String, _ hash: String
    ) -> PipelineResourceBinding {
      .linked(.init(
        kind: kind,
        packageID: ZImagePipelineFamily.packageID,
        packageVersion: ZImagePipelineFamily.packageVersion,
        contentHash: hash,
        componentRole: role,
        functionName: kind == .coreAIModel ? "main" : nil,
        familyABI: ZImagePipelineFamily.familyABI))
    }
    return PipelineNode(
      id: id, kind: .zImageGenerate, title: "Z-Image Generate",
      parameters: [
        "width": .integer(512), "height": .integer(512),
        "steps": .integer(8), "guidance": .number(1),
      ],
      resources: [
        "tokenizer": linked(.tokenizer, "tokenizer",
          "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        "promptEncoder": linked(.coreAIModel, "promptEncoder",
          "0ac88fa5d25b77875d005015e955df4b5cd259c9bf6c0554aac8aad32dae8b34"),
        "denoiser": linked(.coreAIModel, "denoiser",
          "cfbb51aee0c244541dcc4e7b6cb3cc5a0701a664a178807dd97af5b8acfaedf9"),
        "timestepEmbedder": linked(.coreAIModel, "timestepEmbedder",
          "cedac6488d1a7b2279242d47619068bd98a758a629c4d51b506976b988089c46"),
        "ropeMetadata": linked(.data, "ropeMetadata",
          "b622a59d3f75350b4f770ef8e995b0e7028091302d7afb46a45434549b62ae57"),
        "ropeAxis0": linked(.data, "ropeAxis0",
          "feb4fd655388475535e64815df25227b6d62cfe7580f246cc9b41f763fa59779"),
        "ropeAxis1": linked(.data, "ropeAxis1",
          "718fc0a99da0c1d3ffaf3da2dd4daf0781b54ccd6428a1b44cbd4fd8308780a3"),
        "ropeAxis2": linked(.data, "ropeAxis2",
          "718fc0a99da0c1d3ffaf3da2dd4daf0781b54ccd6428a1b44cbd4fd8308780a3"),
        "vaeDecoder": linked(.coreAIModel, "vaeDecoder",
          "1b0d9b9e05adcf2d1a6d0cc1321f38e62b322bb1973f30c6e1cee826cb8a387d"),
      ])
  }

  static func executor(pipeline: ZImageCoreAIPipeline) -> PipelineNodeExecutor {
    PipelineNodeExecutor(
      kind: .zImageGenerate,
      validate: diagnostics
    ) { node, inputs, context in
      guard let prompt = inputs["prompt"]?.value(as: String.self),
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw PipelineEngineError.invalidInvocation(
          "Z-Image node \(node.id.rawValue) needs a prompt.")
      }
      let negativePrompt = inputs["negativePrompt"]?.value(as: String.self) ?? ""
      let seed = inputs["seed"]?.value(as: UInt64.self) ?? 0
      let steps: Int
      if case .integer(let saved)? = node.parameters["steps"],
        let value = Int(exactly: saved)
      { steps = value } else { steps = 8 }
      let guidance: Float
      switch node.parameters["guidance"] {
      case .number(let saved): guidance = Float(saved)
      case .integer(let saved): guidance = Float(saved)
      default: guidance = 1
      }
      guard (1...20).contains(steps), guidance.isFinite, guidance >= 0 else {
        throw PipelineEngineError.invalidInvocation(
          "Z-Image needs 1–20 steps and finite non-negative guidance.")
      }
      guard let reference = node.resources["denoiser"]?.linkedReference else {
        throw PipelineEngineError.modelPackageUnavailable(
          "Z-Image node \(node.id.rawValue) has no linked denoiser.")
      }
      let root = try context.packageRoot(for: reference)
      let document = PipelineDocument(
        id: PipelineID(rawValue: "z-image-composite-\(node.id.rawValue)"),
        name: "Z-Image composite execution",
        mode: .textToImage,
        nodes: [node], connections: [],
        primaryOutputNodeIDs: [node.id])
      let inspection = ZImagePipelineFamily.inspectPackage(at: root, for: document)
      guard inspection.isUsable else {
        throw PipelineEngineError.modelPackageUnavailable(inspection.summary)
      }
      guard let resolution = ZImageCoreAIPipeline.ModelResolution(
        width: Int(node.parameters["width"]?.integerValue ?? 512),
        height: Int(node.parameters["height"]?.integerValue ?? 512))
      else {
        throw PipelineEngineError.invalidInvocation(
          "Z-Image dimensions must be 512–2048 pixels and multiples of 16.")
      }
      await context.progress(.init(
        stage: .loadingModels, message: "Loading Z-Image Core AI functions…",
        activeNodeIDs: [node.id]))
      _ = try await pipeline.load(from: root, resolution: resolution, mode: .textToImage)
      let pixels = try await pipeline.textToImage(
        prompt: prompt, negativePrompt: negativePrompt,
        seed: seed, steps: steps, guidance: guidance,
        resolution: resolution
      ) { step in
        try Task.checkCancellation()
        await context.progress(.init(
          stage: .denoising,
          message: "Denoising step \(step.step) of \(step.totalSteps)…",
          completedUnitCount: step.step,
          totalUnitCount: step.totalSteps,
          preview: PipelineGeneratedImage(
            width: step.width, height: step.height,
            planarRGB: step.decodedRGB,
            encoding: .sRGBMinusOneToOne,
            semanticPipelineSHA256: context.semanticSHA256),
          activeNodeIDs: [node.id]))
      }
      let image = PipelineGeneratedImage(
        width: resolution.width, height: resolution.height,
        planarRGB: pixels, encoding: .sRGBMinusOneToOne,
        semanticPipelineSHA256: context.semanticSHA256)
      return PipelineNodeResult(outputs: [
        "image": PipelineNodeValue(image, type: .image)
      ])
    }
  }

  static func diagnostics(_ node: PipelineNode) -> [PipelineDiagnostic] {
    var diagnostics: [PipelineDiagnostic] = []
    if ZImageCoreAIPipeline.ModelResolution(
      width: Int(node.parameters["width"]?.integerValue ?? 512),
      height: Int(node.parameters["height"]?.integerValue ?? 512)) == nil {
      diagnostics.append(.init(
        severity: .error, code: .invalidParameter,
        message: "Z-Image dimensions must be 512–2048 pixels and multiples of 16.",
        nodeID: node.id))
    }
    if case .integer(let steps)? = node.parameters["steps"],
      !(1...20).contains(steps)
    {
      diagnostics.append(.init(
        severity: .error, code: .invalidParameter,
        message: "Z-Image supports 1–20 steps.", nodeID: node.id))
    }
    let guidance: Double?
    switch node.parameters["guidance"] {
    case .number(let value): guidance = value
    case .integer(let value): guidance = Double(value)
    default: guidance = nil
    }
    if let guidance, !guidance.isFinite || guidance < 0 {
      diagnostics.append(.init(
        severity: .error, code: .invalidParameter,
        message: "Z-Image guidance must be finite and non-negative.", nodeID: node.id))
    }
    let references = node.resources.values.compactMap(\.linkedReference)
    if !references.isEmpty,
      references.contains(where: {
        $0.packageID != ZImagePipelineFamily.packageID
          || $0.familyABI != ZImagePipelineFamily.familyABI
          || $0.packageVersion != references[0].packageVersion
      })
    {
      diagnostics.append(.init(
        severity: .error, code: .invalidResource,
        message: "Z-Image resources must share its reviewed package identity and ABI.",
        nodeID: node.id))
    }
    return diagnostics
  }
}

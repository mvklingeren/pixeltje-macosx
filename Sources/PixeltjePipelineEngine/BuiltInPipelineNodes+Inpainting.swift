import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let maskImageInput = PipelineNodeKind(rawValue: "input.maskImage")
  public static let latentNoiseMask = PipelineNodeKind(rawValue: "latent.setNoiseMask")
  public static let imageFillMasked = PipelineNodeKind(rawValue: "image.fillMasked")
  public static let concatLatentConditioning = PipelineNodeKind(
    rawValue: "conditioning.concatLatent")
  public static let textEncoderAdapter = PipelineNodeKind(rawValue: "coreai.textEncoderAdapter")
  public static let upscaleModel = PipelineNodeKind(rawValue: "coreai.upscaleModel")
  public static let imageUpscaleWithModel = PipelineNodeKind(rawValue: "image.upscaleWithModel")
  public static let imagePreview = PipelineNodeKind(rawValue: "output.preview")
}

extension PipelineNodeRegistry {
  /// Inpainting, LoRA and model-upscaling vocabulary used by ComfyUI's common
  /// edit templates. ComfyUI's all-in-one inpaint encoders import as
  /// subgraphs of these nodes rather than as single composite nodes.
  static var inpaintingAndUpscalingDescriptors: [PipelineNodeDescriptor] {
    [
      PipelineNodeDescriptor(
        kind: .maskImageInput,
        displayName: "Mask Image",
        category: "Inputs",
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "sourceName", valueType: .string),
          .init(name: "channel", valueType: .string, defaultValue: .string("alpha")),
          .init(name: "uploadMode", valueType: .string),
        ]),
      PipelineNodeDescriptor(
        kind: .latentNoiseMask,
        displayName: "Set Latent Noise Mask",
        category: "Inpainting",
        inputs: [
          .init(name: "latent", type: .latent),
          .init(name: "mask", type: .mask),
        ],
        outputs: [.init(name: "latent", type: .latent)]),
      // Replaces pixels where the mask is set with a flat value, so the VAE
      // encodes no trace of the content being inpainted.
      PipelineNodeDescriptor(
        kind: .imageFillMasked,
        displayName: "Fill Masked Pixels",
        category: "Inpainting",
        inputs: [
          .init(name: "image", type: .image),
          .init(name: "mask", type: .mask),
        ],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "value", valueType: .number, defaultValue: .number(0.5))
        ]),
      // Attaches a latent, and optionally its mask, that the denoiser
      // receives as extra input channels: inpainting and instruction-edit
      // models read their source image this way.
      PipelineNodeDescriptor(
        kind: .concatLatentConditioning,
        displayName: "Concat Latent Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioning", type: .conditioning),
          .init(name: "latent", type: .latent),
          .init(name: "mask", type: .mask, isRequired: false),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)]),
      PipelineNodeDescriptor(
        kind: .textEncoderAdapter,
        displayName: "Core AI Text Encoder Adapter",
        category: "Models",
        inputs: [.init(name: "textEncoder", type: .textEncoderFunction)],
        outputs: [.init(name: "textEncoder", type: .textEncoderFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string),
          .init(name: "weight", valueType: .number, defaultValue: .number(1)),
        ],
        requiredResourceSlots: ["adapter"]),
      PipelineNodeDescriptor(
        kind: .upscaleModel,
        displayName: "Core AI Upscale Model",
        category: "Models",
        outputs: [.init(name: "function", type: .upscaleModelFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string)
        ],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .imageUpscaleWithModel,
        displayName: "Upscale Image with Model",
        category: "Image",
        inputs: [
          .init(name: "upscaler", type: .upscaleModelFunction),
          .init(name: "image", type: .image),
        ],
        outputs: [.init(name: "image", type: .image)]),
      // A preview remains a nonterminal side output while passing its image
      // on to downstream nodes.
      PipelineNodeDescriptor(
        kind: .imagePreview,
        displayName: "Image Preview",
        category: "Outputs",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "image", type: .image)]),
    ]
  }
}

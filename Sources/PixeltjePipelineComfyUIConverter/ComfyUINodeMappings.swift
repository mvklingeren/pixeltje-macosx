/// A one-for-one ComfyUI to native node rewrite. Nodes whose ports translate by
/// name, whose outputs keep a fixed slot order, and whose widgets become
/// parameters are declared here; nodes with conditional structure keep a
/// hand-written case in the converter.
public struct ComfyUINodeMapping: Equatable, Sendable {
  public struct Output: Equatable, Sendable {
    /// Normalized ComfyUI type the slot must carry, or `*` for any type.
    public var type: String
    public var name: String

    public init(_ type: String, _ name: String) {
      self.type = type
      self.name = name
    }
  }

  public var kind: String
  public var title: String
  /// ComfyUI input name to native input port.
  public var inputs: [String: String]
  /// ComfyUI inputs that must exist for the rewrite to apply.
  public var requiredInputs: [String]
  /// ComfyUI outputs in slot order, each checked against its declared type.
  public var outputs: [Output]
  /// Serialized widget order from the ComfyUI node schema, including the
  /// frontend's `control_after_generate` companion after a seed widget.
  public var widgets: [String]
  /// Some frontend controls have no stable serialized shape across versions.
  public var allowsAdditionalWidgets: Bool
  /// ComfyUI widget name to native parameter.
  public var parameters: [String: String]
  /// Extracted resource slot to native resource slot. Every listed resource
  /// must be present for the rewrite to apply.
  public var resources: [String: String]

  /// Link-only inputs are required unless listed in `optionalInputs`.
  /// Parameters default to the camel-cased widget names.
  public init(
    kind: String,
    title: String,
    inputs: [String: String] = [:],
    optionalInputs: Set<String> = [],
    outputs: [Output] = [],
    widgets: [String] = [],
    allowsAdditionalWidgets: Bool = false,
    parameters: [String: String]? = nil,
    resources: [String: String] = [:]
  ) {
    self.kind = kind
    self.title = title
    self.inputs = inputs
    requiredInputs = inputs.keys.filter {
      !widgets.contains($0) && !optionalInputs.contains($0)
    }.sorted()
    self.outputs = outputs
    self.widgets = widgets
    self.allowsAdditionalWidgets = allowsAdditionalWidgets
    self.parameters = parameters ?? Dictionary(
      uniqueKeysWithValues: widgets.map { ($0, nativeParameterName($0)) })
    self.resources = resources
  }
}

private func nativeParameterName(_ widget: String) -> String {
  if widget == "control_after_generate" { return "seedControl" }
  let parts = widget.split(separator: "_")
  guard let first = parts.first else { return widget }
  return parts.dropFirst().reduce(String(first)) { name, part in
    name + part.prefix(1).uppercased() + String(part.dropFirst())
  }
}

extension ComfyUIWorkflowConverter {
  /// Declarative rewrites applied in mapping mode, keyed by ComfyUI node type.
  public static let nodeMappings: [String: ComfyUINodeMapping] = {
    var mappings: [String: ComfyUINodeMapping] = [:]
    for group in [
      ComfyUIWorkflowConverter.inpaintingAndUpscalingMappings,
      ComfyUIWorkflowConverter.imageEditingMappings,
      ComfyUIWorkflowConverter.conditioningMappings,
      ComfyUIWorkflowConverter.guidanceMappings,
      ComfyUIWorkflowConverter.samplingMappings,
      ComfyUIWorkflowConverter.mediaMappings,
      ComfyUIWorkflowConverter.textMappings,
    ] {
      mappings.merge(group) { existing, _ in existing }
    }
    return mappings
  }()

  static let inpaintingAndUpscalingMappings: [String: ComfyUINodeMapping] = [
    "SetLatentNoiseMask": ComfyUINodeMapping(
      kind: "latent.setNoiseMask", title: "Set Latent Noise Mask",
      inputs: ["samples": "latent", "mask": "mask"],
      outputs: [.init("LATENT", "latent")]),
    "UpscaleModelLoader": ComfyUINodeMapping(
      kind: "coreai.upscaleModel", title: "Upscale Model",
      outputs: [.init("UPSCALE_MODEL", "function")],
      widgets: ["model_name"],
      resources: ["upscaler": "model"]),
    "ImageUpscaleWithModel": ComfyUINodeMapping(
      kind: "image.upscaleWithModel", title: "Upscale Image with Model",
      inputs: ["upscale_model": "upscaler", "image": "image"],
      outputs: [.init("IMAGE", "image")]),
    "LoadImageMask": ComfyUINodeMapping(
      kind: "input.maskImage", title: "Mask Image",
      outputs: [.init("MASK", "mask")],
      // The frontend appends the upload control after the schema widgets.
      widgets: ["image", "channel", "upload"],
      parameters: ["image": "sourceName", "channel": "channel", "upload": "uploadMode"]),
  ]

  static let imageEditingMappings: [String: ComfyUINodeMapping] = [
    "LatentUpscale": ComfyUINodeMapping(
      kind: "latent.upscale", title: "Upscale Latent",
      inputs: ["samples": "latent", "width": "width", "height": "height"],
      outputs: [.init("LATENT", "latent")],
      widgets: ["upscale_method", "width", "height", "crop"]),
    "LatentUpscaleBy": ComfyUINodeMapping(
      kind: "latent.upscaleBy", title: "Upscale Latent By",
      inputs: ["samples": "latent"],
      outputs: [.init("LATENT", "latent")],
      widgets: ["upscale_method", "scale_by"]),
    "RepeatLatentBatch": ComfyUINodeMapping(
      kind: "latent.repeatBatch", title: "Repeat Latent Batch",
      inputs: ["samples": "latent"],
      outputs: [.init("LATENT", "latent")],
      widgets: ["amount"]),
    "LatentFromBatch": ComfyUINodeMapping(
      kind: "latent.fromBatch", title: "Latent from Batch",
      inputs: ["samples": "latent"],
      outputs: [.init("LATENT", "latent")],
      widgets: ["batch_index", "length"]),
    "ImageScale": ComfyUINodeMapping(
      kind: "image.scale", title: "Scale Image",
      inputs: ["image": "image", "width": "width", "height": "height"],
      outputs: [.init("IMAGE", "image")],
      widgets: ["upscale_method", "width", "height", "crop"]),
    "ImageScaleBy": ComfyUINodeMapping(
      kind: "image.scaleBy", title: "Scale Image By",
      inputs: ["image": "image"],
      outputs: [.init("IMAGE", "image")],
      widgets: ["upscale_method", "scale_by"]),
    "ImageCrop": ComfyUINodeMapping(
      kind: "image.crop", title: "Crop Image",
      inputs: ["image": "image"],
      outputs: [.init("IMAGE", "image")],
      widgets: ["width", "height", "x", "y"]),
    "ImagePadForOutpaint": ComfyUINodeMapping(
      kind: "image.padForOutpaint", title: "Pad Image for Outpainting",
      inputs: ["image": "image"],
      outputs: [.init("IMAGE", "image"), .init("MASK", "mask")],
      widgets: ["left", "top", "right", "bottom", "feathering"]),
    "ImageInvert": ComfyUINodeMapping(
      kind: "image.invert", title: "Invert Image",
      inputs: ["image": "image"],
      outputs: [.init("IMAGE", "image")]),
    "ImageBlend": ComfyUINodeMapping(
      kind: "image.blend", title: "Blend Images",
      inputs: ["image1": "imageA", "image2": "imageB"],
      outputs: [.init("IMAGE", "image")],
      widgets: ["blend_factor", "blend_mode"]),
    "ImageCompositeMasked": ComfyUINodeMapping(
      kind: "image.compositeMasked", title: "Composite Image (Masked)",
      inputs: ["destination": "destination", "source": "source", "mask": "mask"],
      optionalInputs: ["mask"],
      outputs: [.init("IMAGE", "image")],
      widgets: ["x", "y", "resize_source"]),
    "ImageBatch": ComfyUINodeMapping(
      kind: "image.batch", title: "Batch Images",
      inputs: ["image1": "imageA", "image2": "imageB"],
      outputs: [.init("IMAGE", "image")]),
    "ImageFromBatch": ComfyUINodeMapping(
      kind: "image.fromBatch", title: "Image from Batch",
      inputs: ["image": "image"],
      outputs: [.init("IMAGE", "image")],
      widgets: ["batch_index", "length"]),
    "InvertMask": ComfyUINodeMapping(
      kind: "mask.invert", title: "Invert Mask",
      inputs: ["mask": "mask"],
      outputs: [.init("MASK", "mask")]),
    "GrowMask": ComfyUINodeMapping(
      kind: "mask.grow", title: "Grow Mask",
      inputs: ["mask": "mask"],
      outputs: [.init("MASK", "mask")],
      widgets: ["expand", "tapered_corners"]),
    "FeatherMask": ComfyUINodeMapping(
      kind: "mask.feather", title: "Feather Mask",
      inputs: ["mask": "mask"],
      outputs: [.init("MASK", "mask")],
      widgets: ["left", "top", "right", "bottom"]),
    "MaskComposite": ComfyUINodeMapping(
      kind: "mask.composite", title: "Composite Mask",
      inputs: ["destination": "destination", "source": "source"],
      outputs: [.init("MASK", "mask")],
      widgets: ["x", "y", "operation"]),
    "SolidMask": ComfyUINodeMapping(
      kind: "mask.solid", title: "Solid Mask",
      outputs: [.init("MASK", "mask")],
      widgets: ["value", "width", "height"]),
    "ImageToMask": ComfyUINodeMapping(
      kind: "mask.fromImage", title: "Mask from Image Channel",
      inputs: ["image": "image"],
      outputs: [.init("MASK", "mask")],
      widgets: ["channel"]),
    "MaskToImage": ComfyUINodeMapping(
      kind: "mask.toImage", title: "Mask to Image",
      inputs: ["mask": "mask"],
      outputs: [.init("IMAGE", "image")]),
    "ThresholdMask": ComfyUINodeMapping(
      kind: "mask.threshold", title: "Threshold Mask",
      inputs: ["mask": "mask"],
      outputs: [.init("MASK", "mask")],
      widgets: ["value"]),
    "CropMask": ComfyUINodeMapping(
      kind: "mask.crop", title: "Crop Mask",
      inputs: ["mask": "mask"],
      outputs: [.init("MASK", "mask")],
      widgets: ["x", "y", "width", "height"]),
    "VAEEncodeTiled": ComfyUINodeMapping(
      kind: "coreai.vaeTiledImageEncoder", title: "VAE Tiled Image Encoder",
      inputs: ["pixels": "image", "vae": "vae"],
      outputs: [.init("LATENT", "latent")],
      widgets: ["tile_size", "overlap", "temporal_size", "temporal_overlap"]),
    "VAEDecodeTiled": ComfyUINodeMapping(
      kind: "coreai.vaeTiledImageDecoder", title: "VAE Tiled Image Decoder",
      inputs: ["samples": "latent", "vae": "vae"],
      outputs: [.init("IMAGE", "image")],
      widgets: ["tile_size", "overlap", "temporal_size", "temporal_overlap"]),
  ]

  static let conditioningMappings: [String: ComfyUINodeMapping] = [
    "ConditioningCombine": ComfyUINodeMapping(
      kind: "conditioning.combine", title: "Combine Conditioning",
      inputs: ["conditioning_1": "conditioningA", "conditioning_2": "conditioningB"],
      outputs: [.init("CONDITIONING", "conditioning")]),
    "ConditioningConcat": ComfyUINodeMapping(
      kind: "conditioning.concat", title: "Concatenate Conditioning",
      inputs: ["conditioning_to": "conditioningTo", "conditioning_from": "conditioningFrom"],
      outputs: [.init("CONDITIONING", "conditioning")]),
    "ConditioningAverage": ComfyUINodeMapping(
      kind: "conditioning.average", title: "Average Conditioning",
      inputs: ["conditioning_to": "conditioningTo", "conditioning_from": "conditioningFrom"],
      outputs: [.init("CONDITIONING", "conditioning")],
      widgets: ["conditioning_to_strength"]),
    "ConditioningSetArea": ComfyUINodeMapping(
      kind: "conditioning.setArea", title: "Set Conditioning Area",
      inputs: ["conditioning": "conditioning"],
      outputs: [.init("CONDITIONING", "conditioning")],
      widgets: ["width", "height", "x", "y", "strength"]),
    "ConditioningSetAreaPercentage": ComfyUINodeMapping(
      kind: "conditioning.setAreaPercentage", title: "Set Conditioning Area (Percentage)",
      inputs: ["conditioning": "conditioning"],
      outputs: [.init("CONDITIONING", "conditioning")],
      widgets: ["width", "height", "x", "y", "strength"]),
    "ConditioningSetMask": ComfyUINodeMapping(
      kind: "conditioning.setMask", title: "Set Conditioning Mask",
      inputs: ["conditioning": "conditioning", "mask": "mask"],
      outputs: [.init("CONDITIONING", "conditioning")],
      widgets: ["strength", "set_cond_area"],
      parameters: ["strength": "strength", "set_cond_area": "conditionArea"]),
    "ConditioningSetTimestepRange": ComfyUINodeMapping(
      kind: "conditioning.setTimestepRange", title: "Set Conditioning Timestep Range",
      inputs: ["conditioning": "conditioning"],
      outputs: [.init("CONDITIONING", "conditioning")],
      widgets: ["start", "end"]),
    "FluxGuidance": ComfyUINodeMapping(
      kind: "conditioning.fluxGuidance", title: "FLUX Guidance",
      inputs: ["conditioning": "conditioning"],
      outputs: [.init("CONDITIONING", "conditioning")],
      widgets: ["guidance"]),
    "CLIPSetLastLayer": ComfyUINodeMapping(
      kind: "coreai.textEncoderLastLayer", title: "Text Encoder Last Layer",
      inputs: ["clip": "textEncoder"],
      outputs: [.init("CLIP", "textEncoder")],
      widgets: ["stop_at_clip_layer"]),
    "DualCLIPLoader": ComfyUINodeMapping(
      kind: "coreai.dualTextEncoderModel", title: "Dual Text Encoder Model",
      outputs: [.init("CLIP", "function")],
      widgets: ["clip_name1", "clip_name2", "type", "device"],
      parameters: [
        "clip_name1": "modelName", "clip_name2": "secondaryModelName",
        "type": "encoderType", "device": "device",
      ],
      resources: ["textEncoder": "model", "textEncoder-2": "secondaryModel"]),
    "TripleCLIPLoader": ComfyUINodeMapping(
      kind: "coreai.tripleTextEncoderModel", title: "Triple Text Encoder Model",
      outputs: [.init("CLIP", "function")],
      widgets: ["clip_name1", "clip_name2", "clip_name3"],
      parameters: [
        "clip_name1": "modelName", "clip_name2": "secondaryModelName",
        "clip_name3": "tertiaryModelName",
      ],
      resources: [
        "textEncoder": "model", "textEncoder-2": "secondaryModel",
        "textEncoder-3": "tertiaryModel",
      ]),
  ]

  static let guidanceMappings: [String: ComfyUINodeMapping] = [
    "ControlNetLoader": ComfyUINodeMapping(
      kind: "coreai.controlNetModel", title: "ControlNet Model",
      outputs: [.init("CONTROL_NET", "function")],
      widgets: ["control_net_name"],
      parameters: ["control_net_name": "modelName"],
      resources: ["controlNet": "model"]),
    "SetUnionControlNetType": ComfyUINodeMapping(
      kind: "coreai.controlNetUnionType", title: "Set Union ControlNet Type",
      inputs: ["control_net": "controlNet"],
      outputs: [.init("CONTROL_NET", "controlNet")],
      widgets: ["type"],
      parameters: ["type": "unionType"]),
    "ControlNetApplyAdvanced": ComfyUINodeMapping(
      kind: "conditioning.controlNetApply", title: "Apply ControlNet",
      inputs: [
        "positive": "positive", "negative": "negative", "control_net": "controlNet",
        "image": "image", "vae": "vae",
      ],
      optionalInputs: ["vae"],
      outputs: [.init("CONDITIONING", "positive"), .init("CONDITIONING", "negative")],
      widgets: ["strength", "start_percent", "end_percent"]),
    "ControlNetApplySD3": ComfyUINodeMapping(
      kind: "conditioning.controlNetApply", title: "Apply ControlNet",
      inputs: [
        "positive": "positive", "negative": "negative", "control_net": "controlNet",
        "vae": "vae", "image": "image",
      ],
      outputs: [.init("CONDITIONING", "positive"), .init("CONDITIONING", "negative")],
      widgets: ["strength", "start_percent", "end_percent"]),
    "Canny": ComfyUINodeMapping(
      kind: "image.canny", title: "Canny Edges",
      inputs: ["image": "image"],
      outputs: [.init("IMAGE", "image")],
      widgets: ["low_threshold", "high_threshold"]),
    "CLIPVisionLoader": ComfyUINodeMapping(
      kind: "coreai.visionEncoderModel", title: "Vision Encoder Model",
      outputs: [.init("CLIP_VISION", "function")],
      widgets: ["clip_name"],
      parameters: ["clip_name": "modelName"],
      resources: ["visionEncoder": "model"]),
    "CLIPVisionEncode": ComfyUINodeMapping(
      kind: "conditioning.visionEncode", title: "Vision Encode",
      inputs: ["clip_vision": "visionEncoder", "image": "image"],
      outputs: [.init("CLIP_VISION_OUTPUT", "embedding")],
      widgets: ["crop"]),
    "unCLIPConditioning": ComfyUINodeMapping(
      kind: "conditioning.unCLIP", title: "unCLIP Conditioning",
      inputs: ["conditioning": "conditioning", "clip_vision_output": "embedding"],
      outputs: [.init("CONDITIONING", "conditioning")],
      widgets: ["strength", "noise_augmentation"]),
    "StyleModelLoader": ComfyUINodeMapping(
      kind: "coreai.styleModel", title: "Style Model",
      outputs: [.init("STYLE_MODEL", "function")],
      widgets: ["style_model_name"],
      parameters: ["style_model_name": "modelName"],
      resources: ["styleModel": "model"]),
    "StyleModelApply": ComfyUINodeMapping(
      kind: "conditioning.styleModelApply", title: "Apply Style Model",
      inputs: [
        "conditioning": "conditioning", "style_model": "styleModel",
        "clip_vision_output": "embedding",
      ],
      outputs: [.init("CONDITIONING", "conditioning")],
      widgets: ["strength", "strength_type"]),
  ]

  static let samplingMappings: [String: ComfyUINodeMapping] = [
    "KarrasScheduler": ComfyUINodeMapping(
      kind: "diffusion.karrasScheduler", title: "Karras Scheduler",
      outputs: [.init("SIGMAS", "schedule")],
      widgets: ["steps", "sigma_max", "sigma_min", "rho"]),
    "ExponentialScheduler": ComfyUINodeMapping(
      kind: "diffusion.exponentialScheduler", title: "Exponential Scheduler",
      outputs: [.init("SIGMAS", "schedule")],
      widgets: ["steps", "sigma_max", "sigma_min"]),
    "BetaSamplingScheduler": ComfyUINodeMapping(
      kind: "diffusion.betaScheduler", title: "Beta Sampling Scheduler",
      inputs: ["model": "denoiser"],
      outputs: [.init("SIGMAS", "schedule")],
      widgets: ["steps", "alpha", "beta"]),
    "AlignYourStepsScheduler": ComfyUINodeMapping(
      kind: "diffusion.alignYourStepsScheduler", title: "Align Your Steps Scheduler",
      outputs: [.init("SIGMAS", "schedule")],
      widgets: ["model_type", "steps", "denoise"]),
    "SplitSigmas": ComfyUINodeMapping(
      kind: "diffusion.splitSchedule", title: "Split Schedule",
      inputs: ["sigmas": "schedule"],
      outputs: [.init("SIGMAS", "high"), .init("SIGMAS", "low")],
      widgets: ["step"]),
    "SplitSigmasDenoise": ComfyUINodeMapping(
      kind: "diffusion.splitScheduleDenoise", title: "Split Schedule by Denoise",
      inputs: ["sigmas": "schedule"],
      outputs: [.init("SIGMAS", "high"), .init("SIGMAS", "low")],
      widgets: ["denoise"]),
    "FlipSigmas": ComfyUINodeMapping(
      kind: "diffusion.flipSchedule", title: "Flip Schedule",
      inputs: ["sigmas": "schedule"],
      outputs: [.init("SIGMAS", "schedule")]),
    "DisableNoise": ComfyUINodeMapping(
      kind: "latent.disableNoise", title: "Disable Noise",
      outputs: [.init("NOISE", "noise")]),
    "AddNoise": ComfyUINodeMapping(
      kind: "latent.addNoise", title: "Add Noise",
      inputs: [
        "model": "denoiser", "noise": "noise", "sigmas": "schedule", "latent_image": "latent",
      ],
      outputs: [.init("LATENT", "latent")]),
    "ModelSamplingSD3": ComfyUINodeMapping(
      kind: "diffusion.modelSamplingSD3", title: "SD3 Model Sampling",
      inputs: ["model": "model"],
      outputs: [.init("MODEL", "model")],
      widgets: ["shift"]),
    "ModelSamplingFlux": ComfyUINodeMapping(
      kind: "diffusion.modelSamplingFlux", title: "FLUX Model Sampling",
      inputs: ["model": "model"],
      outputs: [.init("MODEL", "model")],
      widgets: ["max_shift", "base_shift", "width", "height"]),
    "ModelSamplingDiscrete": ComfyUINodeMapping(
      kind: "diffusion.modelSamplingDiscrete", title: "Discrete Model Sampling",
      inputs: ["model": "model"],
      outputs: [.init("MODEL", "model")],
      widgets: ["sampling", "zsnr"],
      parameters: ["sampling": "sampling", "zsnr": "zeroTerminalSNR"]),
    "PerturbedAttentionGuidance": ComfyUINodeMapping(
      kind: "diffusion.perturbedAttentionGuidance", title: "Perturbed Attention Guidance",
      inputs: ["model": "model"],
      outputs: [.init("MODEL", "model")],
      widgets: ["scale"]),
    "DualCFGGuider": ComfyUINodeMapping(
      kind: "diffusion.dualCFGGuider", title: "Dual CFG Guider",
      inputs: [
        "model": "denoiser", "cond1": "positive", "cond2": "secondaryPositive",
        "negative": "negative",
      ],
      outputs: [.init("GUIDER", "guider")],
      widgets: ["cfg_conds", "cfg_cond2_negative", "style"],
      parameters: [
        "cfg_conds": "guidance", "cfg_cond2_negative": "secondaryGuidance", "style": "style",
      ]),
    "RescaleCFG": ComfyUINodeMapping(
      kind: "diffusion.rescaleCFG", title: "Rescale CFG",
      inputs: ["model": "model"],
      outputs: [.init("MODEL", "model")],
      widgets: ["multiplier"]),
    "CFGNorm": ComfyUINodeMapping(
      kind: "diffusion.cfgNorm", title: "CFG Norm",
      inputs: ["model": "model", "pre_cfg": "preCfg"],
      outputs: [.init("MODEL", "model")],
      widgets: ["strength", "pre_cfg"]),
  ]

  static let mediaMappings: [String: ComfyUINodeMapping] = [
    "LoadVideo": ComfyUINodeMapping(
      kind: "input.video", title: "Source Video",
      outputs: [.init("VIDEO", "video")],
      widgets: ["file", "upload"],
      parameters: ["file": "sourceName", "upload": "uploadMode"]),
    "GetVideoComponents": ComfyUINodeMapping(
      kind: "media.videoComponents", title: "Video Components",
      inputs: ["video": "video"],
      outputs: [
        .init("IMAGE", "images"), .init("AUDIO", "audio"), .init("FLOAT", "framesPerSecond"),
        .init("COMBO", "bitDepth"), .init("COMBO", "colorSpace"),
      ]),
    "EmptyHunyuanLatentVideo": ComfyUINodeMapping(
      kind: "latent.emptyHunyuanVideo", title: "Empty Hunyuan Latent Video",
      inputs: ["width": "width", "height": "height", "length": "length"],
      outputs: [.init("LATENT", "latent")],
      widgets: ["width", "height", "length", "batch_size"]),
    "EmptyLTXVLatentVideo": ComfyUINodeMapping(
      kind: "latent.emptyLTXVVideo", title: "Empty LTXV Latent Video",
      inputs: ["width": "width", "height": "height", "length": "length"],
      outputs: [.init("LATENT", "latent")],
      widgets: ["width", "height", "length", "batch_size"]),
    "WanImageToVideo": ComfyUINodeMapping(
      kind: "conditioning.wanImageToVideo", title: "Wan Image-to-Video Conditioning",
      inputs: [
        "positive": "positive", "negative": "negative", "vae": "vae",
        "clip_vision_output": "visionEmbedding", "start_image": "startImage",
        "width": "width", "height": "height", "length": "length",
      ],
      optionalInputs: ["clip_vision_output", "start_image"],
      outputs: [
        .init("CONDITIONING", "positive"), .init("CONDITIONING", "negative"),
        .init("LATENT", "latent"),
      ],
      widgets: ["width", "height", "length", "batch_size"]),
    "LoadAudio": ComfyUINodeMapping(
      kind: "input.audio", title: "Source Audio",
      outputs: [.init("AUDIO", "audio")],
      // Only the file name holds a stable position; the upload and player
      // controls that follow vary between frontend versions.
      widgets: ["audio"],
      allowsAdditionalWidgets: true,
      parameters: ["audio": "sourceName"]),
    "VAEEncodeAudio": ComfyUINodeMapping(
      kind: "coreai.vaeAudioEncoder", title: "VAE Audio Encoder",
      inputs: ["audio": "audio", "vae": "vae"],
      outputs: [.init("LATENT", "latent")]),
    "SaveAudio": ComfyUINodeMapping(
      kind: "output.audio", title: "Audio Output",
      inputs: ["audio": "audio"],
      outputs: [.init("AUDIO", "audio")],
      widgets: ["filename_prefix"]),
  ]

  /// ComfyUI's core string nodes. Every widget can be converted to a linked
  /// input, so each operand maps to both an optional input and a parameter.
  static let textMappings: [String: ComfyUINodeMapping] = [
    "StringLength": ComfyUINodeMapping(
      kind: "text.length", title: "Text Length",
      inputs: ["string": "string"],
      outputs: [.init("INT", "length")],
      widgets: ["string"]),
    "StringContains": ComfyUINodeMapping(
      kind: "text.contains", title: "Text Contains",
      inputs: ["string": "string", "substring": "substring", "case_sensitive": "caseSensitive"],
      outputs: [.init("BOOLEAN", "result")],
      widgets: ["string", "substring", "case_sensitive"]),
    "StringSubstring": ComfyUINodeMapping(
      kind: "text.substring", title: "Substring",
      inputs: ["string": "string", "start": "start", "end": "end"],
      outputs: [.init("STRING", "value")],
      widgets: ["string", "start", "end"]),
    "StringCompare": ComfyUINodeMapping(
      kind: "text.compare", title: "Compare Text",
      inputs: ["string_a": "stringA", "string_b": "stringB", "case_sensitive": "caseSensitive"],
      outputs: [.init("BOOLEAN", "result")],
      widgets: ["string_a", "string_b", "mode", "case_sensitive"]),
    "StringTrim": ComfyUINodeMapping(
      kind: "text.trim", title: "Trim Text",
      inputs: ["string": "string"],
      outputs: [.init("STRING", "value")],
      widgets: ["string", "mode"]),
    "CaseConverter": ComfyUINodeMapping(
      kind: "text.changeCase", title: "Change Text Case",
      inputs: ["string": "string"],
      outputs: [.init("STRING", "value")],
      widgets: ["string", "mode"]),
    "RegexMatch": ComfyUINodeMapping(
      kind: "text.regexMatch", title: "Match Text (Regex)",
      inputs: [
        "string": "string", "regex_pattern": "pattern", "case_insensitive": "caseInsensitive",
        "multiline": "multiline", "dotall": "dotAll",
      ],
      outputs: [.init("BOOLEAN", "result")],
      widgets: ["string", "regex_pattern", "case_insensitive", "multiline", "dotall"],
      parameters: [
        "string": "string", "regex_pattern": "pattern", "case_insensitive": "caseInsensitive",
        "multiline": "multiline", "dotall": "dotAll",
      ]),
    "RegexExtract": ComfyUINodeMapping(
      kind: "text.regexExtract", title: "Extract Text (Regex)",
      inputs: [
        "string": "string", "regex_pattern": "pattern", "case_insensitive": "caseInsensitive",
        "multiline": "multiline", "dotall": "dotAll", "group_index": "groupIndex",
      ],
      outputs: [.init("STRING", "value")],
      widgets: [
        "string", "regex_pattern", "mode", "case_insensitive", "multiline", "dotall",
        "group_index",
      ],
      parameters: [
        "string": "string", "regex_pattern": "pattern", "mode": "mode",
        "case_insensitive": "caseInsensitive", "multiline": "multiline", "dotall": "dotAll",
        "group_index": "groupIndex",
      ]),
  ]
}

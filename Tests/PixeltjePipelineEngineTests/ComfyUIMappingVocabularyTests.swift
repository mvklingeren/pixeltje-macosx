import Foundation
import PixeltjePipelineComfyUIConverter
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import Testing

@Test func everyDeclaredComfyUIMappingTargetsTheInstalledVocabulary() throws {
  let registry = PipelineNodeRegistry.coreAIV1
  let mappings = ComfyUIWorkflowConverter.nodeMappings.sorted { $0.key < $1.key }
  #expect(!mappings.isEmpty)
  for (sourceType, mapping) in mappings {
    let descriptor = try #require(
      registry.descriptor(for: PipelineNodeKind(rawValue: mapping.kind)),
      "\(sourceType) maps to uninstalled kind \(mapping.kind)")
    for (sourceInput, nativeInput) in mapping.inputs {
      #expect(
        descriptor.input(named: nativeInput) != nil,
        "\(sourceType).\(sourceInput) maps to missing input \(nativeInput)")
    }
    #expect(Set(mapping.outputs.map(\.name)).count == mapping.outputs.count)
    for output in mapping.outputs {
      let port = descriptor.output(named: output.name)
      #expect(port != nil, "\(sourceType) maps to missing output \(output.name)")
      if output.type != "*" {
        #expect(
          port?.type == ComfyUIWorkflowConverter.portType(forComfyUIType: output.type),
          "\(sourceType) output \(output.name) changes type")
      }
    }
    #expect(Set(mapping.widgets).count == mapping.widgets.count)
    #expect(Set(mapping.parameters.values).count == mapping.parameters.count)
    for (widget, parameter) in mapping.parameters {
      #expect(mapping.widgets.contains(widget), "\(sourceType) maps unknown widget \(widget)")
      #expect(
        descriptor.parameter(named: parameter) != nil,
        "\(sourceType).\(widget) maps to missing parameter \(parameter)")
    }
    for slot in mapping.resources.values {
      #expect(descriptor.requiredResourceSlots.contains(slot))
    }
    for input in descriptor.inputs where input.isRequired {
      #expect(
        mapping.inputs.values.contains(input.name),
        "\(sourceType) cannot connect required input \(input.name)")
    }
  }
}

@Test func inpaintingLoRAAndUpscalingWorkflowMapsToNativeNodes() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "LoadImage", outputs: [port("IMAGE", "IMAGE"), port("MASK", "MASK")],
      widgets: ["photo.png", "image"]),
    comfyNode(2, "CheckpointLoaderSimple",
      outputs: [port("MODEL", "MODEL"), port("CLIP", "CLIP"), port("VAE", "VAE")],
      widgets: ["sd-inpainting.safetensors"]),
    comfyNode(3, "LoraLoader",
      inputs: [port("model", "MODEL"), port("clip", "CLIP")],
      outputs: [port("MODEL", "MODEL"), port("CLIP", "CLIP")],
      widgets: ["style.safetensors", 0.8, 0.5]),
    comfyNode(4, "CLIPTextEncode", inputs: [port("clip", "CLIP")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: ["a red door"]),
    comfyNode(5, "CLIPTextEncode", inputs: [port("clip", "CLIP")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [""]),
    comfyNode(6, "InpaintModelConditioning",
      inputs: [port("positive", "CONDITIONING"), port("negative", "CONDITIONING"),
        port("vae", "VAE"), port("pixels", "IMAGE"), port("mask", "MASK")],
      outputs: [port("positive", "CONDITIONING"), port("negative", "CONDITIONING"),
        port("latent", "LATENT")],
      widgets: [true]),
    comfyNode(7, "KSampler",
      inputs: [port("model", "MODEL"), port("positive", "CONDITIONING"),
        port("negative", "CONDITIONING"), port("latent_image", "LATENT")],
      outputs: [port("LATENT", "LATENT")],
      widgets: [7, "fixed", 20, 5, "euler", "normal", 1]),
    comfyNode(8, "VAEDecode", inputs: [port("samples", "LATENT"), port("vae", "VAE")],
      outputs: [port("IMAGE", "IMAGE")]),
    comfyNode(9, "UpscaleModelLoader", outputs: [port("UPSCALE_MODEL", "UPSCALE_MODEL")],
      widgets: ["4x-ultrasharp.pth"]),
    comfyNode(10, "ImageUpscaleWithModel",
      inputs: [port("upscale_model", "UPSCALE_MODEL"), port("image", "IMAGE")],
      outputs: [port("IMAGE", "IMAGE")]),
    comfyNode(11, "SaveImage", inputs: [port("images", "IMAGE")], widgets: ["inpaint"]),
    comfyNode(12, "PreviewImage", inputs: [port("images", "IMAGE")]),
    comfyNode(13, "LoadImageMask", outputs: [port("MASK", "MASK")],
      widgets: ["mask.png", "red", "image"]),
    comfyNode(14, "VAEEncodeForInpaint",
      inputs: [port("pixels", "IMAGE"), port("vae", "VAE"), port("mask", "MASK")],
      outputs: [port("LATENT", "LATENT")], widgets: [12]),
    comfyNode(15, "SetLatentNoiseMask",
      inputs: [port("samples", "LATENT"), port("mask", "MASK")],
      outputs: [port("LATENT", "LATENT")]),
  ]
  let links: [[Any]] = [
    [1, 2, 0, 3, 0, "MODEL"],
    [2, 2, 1, 3, 1, "CLIP"],
    [3, 3, 1, 4, 0, "CLIP"],
    [4, 3, 1, 5, 0, "CLIP"],
    [5, 4, 0, 6, 0, "CONDITIONING"],
    [6, 5, 0, 6, 1, "CONDITIONING"],
    [7, 2, 2, 6, 2, "VAE"],
    [8, 1, 0, 6, 3, "IMAGE"],
    [9, 1, 1, 6, 4, "MASK"],
    [10, 3, 0, 7, 0, "MODEL"],
    [11, 6, 0, 7, 1, "CONDITIONING"],
    [12, 6, 1, 7, 2, "CONDITIONING"],
    [13, 6, 2, 7, 3, "LATENT"],
    [14, 7, 0, 8, 0, "LATENT"],
    [15, 2, 2, 8, 1, "VAE"],
    [16, 9, 0, 10, 0, "UPSCALE_MODEL"],
    [17, 8, 0, 10, 1, "IMAGE"],
    [18, 10, 0, 11, 0, "IMAGE"],
    [19, 8, 0, 12, 0, "IMAGE"],
    [20, 1, 0, 14, 0, "IMAGE"],
    [21, 2, 2, 14, 1, "VAE"],
    [22, 13, 0, 14, 2, "MASK"],
    [23, 14, 0, 15, 0, "LATENT"],
    [24, 13, 0, 15, 1, "MASK"],
  ]

  let result = try convertMapped(nodes, links: links)

  #expect(result.summary.placeholderNodeCount == 2)
  #expect(droppedLinks(result).isEmpty)
  #expect(result.document.mode == .inpainting)
  #expect(kind(9, in: result) == "coreai.upscaleModel")
  #expect(kind(10, in: result) == "image.upscaleWithModel")
  #expect(kind(11, in: result) == "output.image")
  #expect(kind(12, in: result) == "output.preview")
  #expect(kind(13, in: result) == "input.maskImage")
  #expect(node(9, in: result)?.resources["model"] != nil)
  #expect(node(13, in: result)?.parameters["channel"] == .string("red"))

  // LoraLoader imports as separate denoiser and text-encoder adapters that
  // share the LoRA file.
  let lora = try #require(node(3, in: result))
  #expect(lora.kind == .adapter)
  #expect(lora.parameters["modelName"] == .string("style.safetensors"))
  #expect(lora.parameters["weight"] == .number(0.8))
  #expect(lora.resources["adapter"]?.unresolvedRequirement?.sourceName == "style.safetensors")
  let loraEncoder = try #require(node(3, "textEncoder", in: result))
  #expect(loraEncoder.kind == .textEncoderAdapter)
  #expect(loraEncoder.parameters["weight"] == .number(0.5))
  #expect(loraEncoder.resources["adapter"] == lora.resources["adapter"])
  #expect(isConnected(
    from: (3, "textEncoder", "textEncoder"), to: (4, nil, "textEncoder"), in: result))

  // These nodes crop to VAE dimensions and handle the original and rounded
  // masks differently. Keep their source descriptors until those semantics
  // have a reviewed native implementation.
  #expect(kind(6, in: result) == "comfyui.InpaintModelConditioning")
  #expect(kind(14, in: result) == "comfyui.VAEEncodeForInpaint")
  #expect(isConnected(from: (6, nil, "positive"), to: (7, nil, "positive"), in: result))
  #expect(isConnected(from: (14, nil, "LATENT"), to: (15, nil, "latent"), in: result))
  #expect(kind(15, in: result) == "latent.setNoiseMask")
  #expect(structuralErrors(result.document).allSatisfy {
    $0.code == .unsupportedNodeImplementation
  })
}

@Test func inpaintModelConditioningWithoutNoiseMaskStaysInspectable() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "InpaintModelConditioning",
      inputs: [port("positive", "CONDITIONING"), port("negative", "CONDITIONING"),
        port("vae", "VAE"), port("pixels", "IMAGE"), port("mask", "MASK")],
      outputs: [port("positive", "CONDITIONING"), port("negative", "CONDITIONING"),
        port("latent", "LATENT")],
      widgets: [false]),
  ]
  let result = try convertMapped(nodes, links: [])
  #expect(kind(1, in: result) == "comfyui.InpaintModelConditioning")
  #expect(result.document.nodes.count == 1)
}

@Test func primaryPreviewImageKeepsTheTerminalImageKind() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "LoadImage", outputs: [port("IMAGE", "IMAGE"), port("MASK", "MASK")],
      widgets: ["photo.png", "image"]),
    comfyNode(2, "PreviewImage", inputs: [port("images", "IMAGE")]),
  ]
  let result = try convertMapped(nodes, links: [[1, 1, 0, 2, 0, "IMAGE"]])
  #expect(kind(2, in: result) == "output.image")
}

@Test func imageMaskLatentAndTiledVAEWorkflowMapsToNativeNodes() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "LoadImage", outputs: [port("IMAGE", "IMAGE"), port("MASK", "MASK")],
      widgets: ["photo.png", "image"]),
    comfyNode(2, "VAELoader", outputs: [port("VAE", "VAE")], widgets: ["ae.safetensors"]),
    comfyNode(3, "GetImageSize", inputs: [port("image", "IMAGE")],
      outputs: [port("width", "INT"), port("height", "INT"), port("batch_size", "INT")]),
    comfyNode(4, "ImageScale",
      inputs: [port("image", "IMAGE"), port("width", "INT", widget: true),
        port("height", "INT", widget: true)],
      outputs: [port("IMAGE", "IMAGE")], widgets: ["lanczos", 1024, 768, "center"]),
    comfyNode(5, "ImagePadForOutpaint", inputs: [port("image", "IMAGE")],
      outputs: [port("IMAGE", "IMAGE"), port("MASK", "MASK")], widgets: [0, 0, 256, 0, 40]),
    comfyNode(6, "GrowMask", inputs: [port("mask", "MASK")], outputs: [port("MASK", "MASK")],
      widgets: [8, true]),
    comfyNode(7, "FeatherMask", inputs: [port("mask", "MASK")],
      outputs: [port("MASK", "MASK")], widgets: [4, 4, 4, 4]),
    comfyNode(8, "VAEEncodeTiled", inputs: [port("pixels", "IMAGE"), port("vae", "VAE")],
      outputs: [port("LATENT", "LATENT")], widgets: [512, 64, 64, 8]),
    comfyNode(9, "SetLatentNoiseMask", inputs: [port("samples", "LATENT"), port("mask", "MASK")],
      outputs: [port("LATENT", "LATENT")]),
    comfyNode(10, "RepeatLatentBatch", inputs: [port("samples", "LATENT")],
      outputs: [port("LATENT", "LATENT")], widgets: [2]),
    comfyNode(11, "LatentFromBatch", inputs: [port("samples", "LATENT")],
      outputs: [port("LATENT", "LATENT")], widgets: [1, 1]),
    comfyNode(12, "LatentUpscaleBy", inputs: [port("samples", "LATENT")],
      outputs: [port("LATENT", "LATENT")], widgets: ["bislerp", 1.5]),
    comfyNode(13, "VAEDecodeTiled", inputs: [port("samples", "LATENT"), port("vae", "VAE")],
      outputs: [port("IMAGE", "IMAGE")], widgets: [768, 96, 64, 8]),
    comfyNode(14, "ImageCompositeMasked",
      inputs: [port("destination", "IMAGE"), port("source", "IMAGE"), port("mask", "MASK")],
      outputs: [port("IMAGE", "IMAGE")], widgets: [0, 0, false]),
    comfyNode(15, "ImageBlend", inputs: [port("image1", "IMAGE"), port("image2", "IMAGE")],
      outputs: [port("IMAGE", "IMAGE")], widgets: [0.25, "multiply"]),
    comfyNode(16, "SaveImage", inputs: [port("images", "IMAGE")], widgets: ["outpaint"]),
    comfyNode(17, "SolidMask", outputs: [port("MASK", "MASK")], widgets: [1, 512, 512]),
    comfyNode(18, "MaskComposite",
      inputs: [port("destination", "MASK"), port("source", "MASK")],
      outputs: [port("MASK", "MASK")], widgets: [0, 0, "add"]),
    comfyNode(19, "MaskToImage", inputs: [port("mask", "MASK")],
      outputs: [port("IMAGE", "IMAGE")]),
    comfyNode(20, "ImageToMask", inputs: [port("image", "IMAGE")],
      outputs: [port("MASK", "MASK")], widgets: ["green"]),
    comfyNode(21, "ThresholdMask", inputs: [port("mask", "MASK")],
      outputs: [port("MASK", "MASK")], widgets: [0.5]),
    comfyNode(22, "CropMask", inputs: [port("mask", "MASK")],
      outputs: [port("MASK", "MASK")], widgets: [0, 0, 256, 256]),
    comfyNode(23, "InvertMask", inputs: [port("mask", "MASK")],
      outputs: [port("MASK", "MASK")]),
    comfyNode(24, "ImageInvert", inputs: [port("image", "IMAGE")],
      outputs: [port("IMAGE", "IMAGE")]),
    comfyNode(25, "ImageScaleBy", inputs: [port("image", "IMAGE")],
      outputs: [port("IMAGE", "IMAGE")], widgets: ["area", 0.5]),
    comfyNode(26, "ImageCrop", inputs: [port("image", "IMAGE")],
      outputs: [port("IMAGE", "IMAGE")], widgets: [256, 256, 0, 0]),
    comfyNode(27, "ImageBatch", inputs: [port("image1", "IMAGE"), port("image2", "IMAGE")],
      outputs: [port("IMAGE", "IMAGE")]),
    comfyNode(28, "ImageFromBatch", inputs: [port("image", "IMAGE")],
      outputs: [port("IMAGE", "IMAGE")], widgets: [0, 1]),
    comfyNode(29, "LatentUpscale", inputs: [port("samples", "LATENT")],
      outputs: [port("LATENT", "LATENT")], widgets: ["nearest-exact", 512, 512, "disabled"]),
  ]
  let links: [[Any]] = [
    [1, 1, 0, 3, 0, "IMAGE"],
    [2, 1, 0, 4, 0, "IMAGE"],
    [3, 3, 0, 4, 1, "INT"],
    [4, 3, 1, 4, 2, "INT"],
    [5, 4, 0, 5, 0, "IMAGE"],
    [6, 5, 1, 6, 0, "MASK"],
    [7, 6, 0, 7, 0, "MASK"],
    [8, 5, 0, 8, 0, "IMAGE"],
    [9, 2, 0, 8, 1, "VAE"],
    [10, 8, 0, 9, 0, "LATENT"],
    [11, 7, 0, 9, 1, "MASK"],
    [12, 9, 0, 10, 0, "LATENT"],
    [13, 10, 0, 11, 0, "LATENT"],
    [14, 11, 0, 12, 0, "LATENT"],
    [15, 12, 0, 13, 0, "LATENT"],
    [16, 2, 0, 13, 1, "VAE"],
    [17, 13, 0, 14, 0, "IMAGE"],
    [18, 1, 0, 14, 1, "IMAGE"],
    [19, 1, 1, 14, 2, "MASK"],
    [20, 14, 0, 15, 0, "IMAGE"],
    [21, 5, 0, 15, 1, "IMAGE"],
    [22, 15, 0, 16, 0, "IMAGE"],
    [23, 17, 0, 18, 0, "MASK"],
    [24, 7, 0, 18, 1, "MASK"],
    [25, 18, 0, 19, 0, "MASK"],
    [26, 19, 0, 20, 0, "IMAGE"],
    [27, 20, 0, 21, 0, "MASK"],
    [28, 21, 0, 22, 0, "MASK"],
    [29, 22, 0, 23, 0, "MASK"],
    [30, 1, 0, 24, 0, "IMAGE"],
    [31, 24, 0, 25, 0, "IMAGE"],
    [32, 25, 0, 26, 0, "IMAGE"],
    [33, 26, 0, 27, 0, "IMAGE"],
    [34, 26, 0, 27, 1, "IMAGE"],
    [35, 27, 0, 28, 0, "IMAGE"],
    [36, 8, 0, 29, 0, "LATENT"],
  ]

  let result = try convertMapped(nodes, links: links)

  #expect(result.summary.placeholderNodeCount == 0)
  #expect(result.summary.connectionCount == links.count)
  #expect(result.document.mode == .inpainting)
  let scale = try #require(node(4, in: result))
  #expect(scale.kind == .imageScale)
  #expect(scale.parameters["upscaleMethod"] == .string("lanczos"))
  #expect(scale.parameters["crop"] == .string("center"))
  #expect(result.document.connections.contains {
    $0.input == PipelinePortReference(nodeID: scale.id, port: "width")
  })
  #expect(node(5, in: result)?.parameters["right"] == .integer(256))
  #expect(node(6, in: result)?.parameters["taperedCorners"] == .boolean(true))
  #expect(kind(8, in: result) == "coreai.vaeTiledImageEncoder")
  #expect(node(13, in: result)?.parameters["tileSize"] == .integer(768))
  #expect(node(13, in: result)?.parameters["temporalOverlap"] == .integer(8))
  #expect(node(11, in: result)?.parameters["batchIndex"] == .integer(1))
  #expect(node(12, in: result)?.parameters["scaleBy"] == .number(1.5))
  #expect(node(15, in: result)?.parameters["blendMode"] == .string("multiply"))
  #expect(node(18, in: result)?.parameters["operation"] == .string("add"))
  #expect(kind(20, in: result) == "mask.fromImage")
  #expect(kind(27, in: result) == "image.batch")
  #expect(kind(29, in: result) == "latent.upscale")
  #expect(structuralErrors(result.document).isEmpty)
}

@Test func conditioningAndMultiEncoderWorkflowMapsToNativeNodes() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "DualCLIPLoader", outputs: [port("CLIP", "CLIP")],
      widgets: ["clip_l.safetensors", "t5xxl_fp16.safetensors", "flux", "default"]),
    comfyNode(2, "CLIPSetLastLayer", inputs: [port("clip", "CLIP")],
      outputs: [port("CLIP", "CLIP")], widgets: [-2]),
    comfyNode(3, "CLIPTextEncodeFlux", inputs: [port("clip", "CLIP")],
      outputs: [port("CONDITIONING", "CONDITIONING")],
      widgets: ["a cat", "a cat on a mat", 3.5]),
    comfyNode(4, "CLIPTextEncodeSDXL",
      inputs: [port("clip", "CLIP"), port("text_g", "STRING", widget: true),
        port("text_l", "STRING", widget: true)],
      outputs: [port("CONDITIONING", "CONDITIONING")],
      widgets: [1024, 1024, 0, 0, 1024, 1024, "global", "local"]),
    comfyNode(5, "PrimitiveStringMultiline", outputs: [port("STRING", "STRING")],
      widgets: ["linked global"]),
    comfyNode(6, "ConditioningCombine",
      inputs: [port("conditioning_1", "CONDITIONING"), port("conditioning_2", "CONDITIONING")],
      outputs: [port("CONDITIONING", "CONDITIONING")]),
    comfyNode(7, "ConditioningConcat",
      inputs: [port("conditioning_to", "CONDITIONING"),
        port("conditioning_from", "CONDITIONING")],
      outputs: [port("CONDITIONING", "CONDITIONING")]),
    comfyNode(8, "ConditioningAverage",
      inputs: [port("conditioning_to", "CONDITIONING"),
        port("conditioning_from", "CONDITIONING")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [0.7]),
    comfyNode(9, "ConditioningSetArea", inputs: [port("conditioning", "CONDITIONING")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [512, 512, 0, 0, 1]),
    comfyNode(10, "ConditioningSetAreaPercentage",
      inputs: [port("conditioning", "CONDITIONING")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [0.5, 0.5, 0.5, 0, 1]),
    comfyNode(11, "SolidMask", outputs: [port("MASK", "MASK")], widgets: [1, 64, 64]),
    comfyNode(12, "ConditioningSetMask",
      inputs: [port("conditioning", "CONDITIONING"), port("mask", "MASK")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [0.8, "mask bounds"]),
    comfyNode(13, "ConditioningSetTimestepRange",
      inputs: [port("conditioning", "CONDITIONING")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [0, 0.5]),
    comfyNode(14, "FluxGuidance", inputs: [port("conditioning", "CONDITIONING")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [4]),
    comfyNode(15, "TripleCLIPLoader", outputs: [port("CLIP", "CLIP")],
      widgets: ["clip_g.safetensors", "clip_l.safetensors", "t5xxl.safetensors"]),
    comfyNode(16, "UNETLoader", outputs: [port("MODEL", "MODEL")],
      widgets: ["flux1-dev.safetensors", "default"]),
    comfyNode(17, "EmptyLatentImage", outputs: [port("LATENT", "LATENT")],
      widgets: [1024, 1024, 1]),
    comfyNode(18, "KSampler",
      inputs: [port("model", "MODEL"), port("positive", "CONDITIONING"),
        port("negative", "CONDITIONING"), port("latent_image", "LATENT")],
      outputs: [port("LATENT", "LATENT")],
      widgets: [0, "fixed", 20, 1, "euler", "simple", 1]),
    comfyNode(19, "VAELoader", outputs: [port("VAE", "VAE")], widgets: ["ae.safetensors"]),
    comfyNode(20, "VAEDecode", inputs: [port("samples", "LATENT"), port("vae", "VAE")],
      outputs: [port("IMAGE", "IMAGE")]),
    comfyNode(21, "SaveImage", inputs: [port("images", "IMAGE")], widgets: ["regional"]),
  ]
  let links: [[Any]] = [
    [1, 1, 0, 2, 0, "CLIP"],
    [2, 2, 0, 3, 0, "CLIP"],
    [3, 2, 0, 4, 0, "CLIP"],
    [4, 5, 0, 4, 1, "STRING"],
    [5, 3, 0, 6, 0, "CONDITIONING"],
    [6, 4, 0, 6, 1, "CONDITIONING"],
    [7, 6, 0, 7, 0, "CONDITIONING"],
    [8, 3, 0, 7, 1, "CONDITIONING"],
    [9, 7, 0, 8, 0, "CONDITIONING"],
    [10, 4, 0, 8, 1, "CONDITIONING"],
    [11, 8, 0, 9, 0, "CONDITIONING"],
    [12, 9, 0, 10, 0, "CONDITIONING"],
    [13, 10, 0, 12, 0, "CONDITIONING"],
    [14, 11, 0, 12, 1, "MASK"],
    [15, 12, 0, 13, 0, "CONDITIONING"],
    [16, 13, 0, 14, 0, "CONDITIONING"],
    [17, 16, 0, 18, 0, "MODEL"],
    [18, 14, 0, 18, 1, "CONDITIONING"],
    [19, 3, 0, 18, 2, "CONDITIONING"],
    [20, 17, 0, 18, 3, "LATENT"],
    [21, 18, 0, 20, 0, "LATENT"],
    [22, 19, 0, 20, 1, "VAE"],
    [23, 20, 0, 21, 0, "IMAGE"],
  ]

  let result = try convertMapped(nodes, links: links)

  #expect(result.summary.placeholderNodeCount == 0)
  #expect(droppedLinks(result).isEmpty)
  let dual = try #require(node(1, in: result))
  #expect(dual.kind == .dualTextEncoderModel)
  #expect(dual.resources["model"]?.unresolvedRequirement?.sourceName == "clip_l.safetensors")
  #expect(
    dual.resources["secondaryModel"]?.unresolvedRequirement?.sourceName
      == "t5xxl_fp16.safetensors")
  #expect(dual.parameters["encoderType"] == .string("flux"))
  #expect(node(2, in: result)?.parameters["stopAtClipLayer"] == .integer(-2))
  // CLIPTextEncodeFlux imports as a text encoder followed by FLUX guidance.
  #expect(node(3, "encode", in: result)?.parameters["t5xxl"] == .string("a cat on a mat"))
  #expect(node(3, "encode", in: result)?.parameters["guidance"] == nil)
  #expect(node(3, in: result)?.kind == .fluxGuidance)
  #expect(node(3, in: result)?.parameters["guidance"] == .number(3.5))
  #expect(isConnected(
    from: (3, "encode", "conditioning"), to: (3, nil, "conditioning"), in: result))
  // CLIPTextEncodeSDXL imports as a text encoder followed by size conditioning.
  let sdxlEncoder = try #require(node(4, "encode", in: result))
  #expect(sdxlEncoder.kind == .sdxlTextConditioningEncoder)
  #expect(sdxlEncoder.parameters["textL"] == .string("local"))
  let sdxlSize = try #require(node(4, in: result))
  #expect(sdxlSize.kind == .sdxlSizeConditioning)
  #expect(sdxlSize.parameters["targetWidth"] == .integer(1024))
  #expect(isConnected(from: (5, nil, "value"), to: (4, "encode", "textG"), in: result))
  #expect(isConnected(from: (4, nil, "conditioning"), to: (6, nil, "conditioningB"), in: result))
  #expect(node(8, in: result)?.parameters["conditioningToStrength"] == .number(0.7))
  #expect(node(12, in: result)?.parameters["conditionArea"] == .string("mask bounds"))
  #expect(kind(13, in: result) == "conditioning.setTimestepRange")
  #expect(node(14, in: result)?.parameters["guidance"] == .integer(4))
  #expect(node(15, in: result)?.resources.count == 3)
  #expect(structuralErrors(result.document).isEmpty)
}

@Test func controlNetVisionAndStyleWorkflowMapsToNativeNodes() throws {
  let conditioningPair = [port("positive", "CONDITIONING"), port("negative", "CONDITIONING")]
  let nodes: [[String: Any]] = [
    comfyNode(1, "CheckpointLoaderSimple",
      outputs: [port("MODEL", "MODEL"), port("CLIP", "CLIP"), port("VAE", "VAE")],
      widgets: ["sd15.safetensors"]),
    comfyNode(2, "CLIPTextEncode", inputs: [port("clip", "CLIP")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: ["a lighthouse"]),
    comfyNode(3, "CLIPTextEncode", inputs: [port("clip", "CLIP")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: ["blurry"]),
    comfyNode(4, "LoadImage", outputs: [port("IMAGE", "IMAGE"), port("MASK", "MASK")],
      widgets: ["sketch.png", "image"]),
    comfyNode(5, "Canny", inputs: [port("image", "IMAGE")], outputs: [port("IMAGE", "IMAGE")],
      widgets: [0.3, 0.7]),
    comfyNode(6, "ControlNetLoader", outputs: [port("CONTROL_NET", "CONTROL_NET")],
      widgets: ["union.safetensors"]),
    comfyNode(7, "SetUnionControlNetType", inputs: [port("control_net", "CONTROL_NET")],
      outputs: [port("CONTROL_NET", "CONTROL_NET")], widgets: ["canny/lineart/mlsd"]),
    comfyNode(8, "ControlNetApplyAdvanced",
      inputs: conditioningPair + [port("control_net", "CONTROL_NET"), port("image", "IMAGE"),
        port("vae", "VAE")],
      outputs: conditioningPair, widgets: [0.8, 0, 0.9]),
    comfyNode(9, "CLIPVisionLoader", outputs: [port("CLIP_VISION", "CLIP_VISION")],
      widgets: ["sigclip_vision.safetensors"]),
    comfyNode(10, "CLIPVisionEncode",
      inputs: [port("clip_vision", "CLIP_VISION"), port("image", "IMAGE")],
      outputs: [port("CLIP_VISION_OUTPUT", "CLIP_VISION_OUTPUT")], widgets: ["none"]),
    comfyNode(11, "StyleModelLoader", outputs: [port("STYLE_MODEL", "STYLE_MODEL")],
      widgets: ["redux.safetensors"]),
    comfyNode(12, "StyleModelApply",
      inputs: [port("conditioning", "CONDITIONING"), port("style_model", "STYLE_MODEL"),
        port("clip_vision_output", "CLIP_VISION_OUTPUT")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [1, "attn_bias"]),
    comfyNode(13, "unCLIPConditioning",
      inputs: [port("conditioning", "CONDITIONING"),
        port("clip_vision_output", "CLIP_VISION_OUTPUT")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [1, 0.1]),
    comfyNode(14, "InstructPixToPixConditioning",
      inputs: conditioningPair + [port("vae", "VAE"), port("pixels", "IMAGE")],
      outputs: conditioningPair + [port("latent", "LATENT")]),
    comfyNode(15, "KSampler",
      inputs: [port("model", "MODEL")] + conditioningPair + [port("latent_image", "LATENT")],
      outputs: [port("LATENT", "LATENT")],
      widgets: [0, "fixed", 20, 7, "euler", "normal", 1]),
    comfyNode(16, "VAEDecode", inputs: [port("samples", "LATENT"), port("vae", "VAE")],
      outputs: [port("IMAGE", "IMAGE")]),
    comfyNode(17, "SaveImage", inputs: [port("images", "IMAGE")], widgets: ["guided"]),
    comfyNode(18, "ControlNetApplySD3",
      inputs: conditioningPair + [port("control_net", "CONTROL_NET"), port("vae", "VAE"),
        port("image", "IMAGE")],
      outputs: conditioningPair, widgets: [0.5, 0, 1]),
  ]
  let links: [[Any]] = [
    [1, 1, 1, 2, 0, "CLIP"],
    [2, 1, 1, 3, 0, "CLIP"],
    [3, 4, 0, 5, 0, "IMAGE"],
    [4, 6, 0, 7, 0, "CONTROL_NET"],
    [5, 2, 0, 8, 0, "CONDITIONING"],
    [6, 3, 0, 8, 1, "CONDITIONING"],
    [7, 7, 0, 8, 2, "CONTROL_NET"],
    [8, 5, 0, 8, 3, "IMAGE"],
    [9, 1, 2, 8, 4, "VAE"],
    [10, 9, 0, 10, 0, "CLIP_VISION"],
    [11, 4, 0, 10, 1, "IMAGE"],
    [12, 8, 0, 12, 0, "CONDITIONING"],
    [13, 11, 0, 12, 1, "STYLE_MODEL"],
    [14, 10, 0, 12, 2, "CLIP_VISION_OUTPUT"],
    [15, 12, 0, 13, 0, "CONDITIONING"],
    [16, 10, 0, 13, 1, "CLIP_VISION_OUTPUT"],
    [17, 13, 0, 14, 0, "CONDITIONING"],
    [18, 8, 1, 14, 1, "CONDITIONING"],
    [19, 1, 2, 14, 2, "VAE"],
    [20, 4, 0, 14, 3, "IMAGE"],
    [21, 1, 0, 15, 0, "MODEL"],
    [22, 14, 0, 15, 1, "CONDITIONING"],
    [23, 14, 1, 15, 2, "CONDITIONING"],
    [24, 14, 2, 15, 3, "LATENT"],
    [25, 15, 0, 16, 0, "LATENT"],
    [26, 1, 2, 16, 1, "VAE"],
    [27, 16, 0, 17, 0, "IMAGE"],
    [28, 2, 0, 18, 0, "CONDITIONING"],
    [29, 3, 0, 18, 1, "CONDITIONING"],
    [30, 6, 0, 18, 2, "CONTROL_NET"],
    [31, 1, 2, 18, 3, "VAE"],
    [32, 5, 0, 18, 4, "IMAGE"],
  ]

  let result = try convertMapped(nodes, links: links)

  #expect(result.summary.placeholderNodeCount == 1)
  #expect(droppedLinks(result).isEmpty)
  #expect(node(5, in: result)?.parameters["lowThreshold"] == .number(0.3))
  let controlNet = try #require(node(6, in: result))
  #expect(controlNet.kind == .controlNetModel)
  #expect(controlNet.resources["model"]?.unresolvedRequirement?.componentRole == "controlNet")
  #expect(node(7, in: result)?.parameters["unionType"] == .string("canny/lineart/mlsd"))
  let apply = try #require(node(8, in: result))
  #expect(apply.kind == .controlNetApply)
  #expect(apply.parameters["endPercent"] == .number(0.9))
  #expect(
    node(9, in: result)?.resources["model"]?.unresolvedRequirement?.componentRole
      == "visionEncoder")
  #expect(node(10, in: result)?.parameters["crop"] == .string("none"))
  #expect(
    node(11, in: result)?.resources["model"]?.unresolvedRequirement?.componentRole
      == "styleModel")
  #expect(node(12, in: result)?.parameters["strengthType"] == .string("attn_bias"))
  #expect(node(13, in: result)?.parameters["noiseAugmentation"] == .number(0.1))
  // ComfyUI center-crops before encoding, so the imported node remains intact.
  #expect(kind(14, in: result) == "comfyui.InstructPixToPixConditioning")
  #expect(isConnected(from: (14, nil, "negative"), to: (15, nil, "negative"), in: result))
  #expect(isConnected(from: (14, nil, "latent"), to: (15, nil, "latent"), in: result))
  #expect(isConnected(from: (4, nil, "image"), to: (14, nil, "pixels"), in: result))
  #expect(kind(18, in: result) == "conditioning.controlNetApply")
  #expect(structuralErrors(result.document).allSatisfy {
    $0.code == .unsupportedNodeImplementation
  })
}

@Test func stagedSamplingAndModelPatchWorkflowMapsToNativeNodes() throws {
  let modelPatch = { (id: Int, type: String, widgets: [Any]) -> [String: Any] in
    comfyNode(id, type, inputs: [port("model", "MODEL")], outputs: [port("MODEL", "MODEL")],
      widgets: widgets)
  }
  let encode = { (id: Int, text: String) -> [String: Any] in
    comfyNode(id, "CLIPTextEncode", inputs: [port("clip", "CLIP")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: [text])
  }
  let nodes: [[String: Any]] = [
    comfyNode(1, "UNETLoader", outputs: [port("MODEL", "MODEL")],
      widgets: ["base.safetensors", "default"]),
    modelPatch(2, "ModelSamplingFlux", [1.15, 0.5, 1024, 1024]),
    modelPatch(3, "ModelSamplingSD3", [3]),
    modelPatch(4, "ModelSamplingDiscrete", ["v_prediction", true]),
    modelPatch(5, "PerturbedAttentionGuidance", [3]),
    modelPatch(6, "RescaleCFG", [0.7]),
    comfyNode(7, "CFGNorm",
      inputs: [port("model", "MODEL"), port("pre_cfg", "BOOLEAN", widget: true)],
      outputs: [port("MODEL", "MODEL")], widgets: [1, true]),
    comfyNode(8, "CLIPLoader", outputs: [port("CLIP", "CLIP")],
      widgets: ["t5.safetensors", "sd3", "default"]),
    encode(9, "a harbour at dawn"),
    encode(10, "low quality"),
    encode(11, "oil painting"),
    comfyNode(12, "EmptyLatentImage", outputs: [port("LATENT", "LATENT")],
      widgets: [1024, 1024, 1]),
    comfyNode(13, "KSamplerAdvanced",
      inputs: [port("model", "MODEL"), port("positive", "CONDITIONING"),
        port("negative", "CONDITIONING"), port("latent_image", "LATENT")],
      outputs: [port("LATENT", "LATENT")],
      widgets: ["enable", 42, "fixed", 30, 7.5, "dpmpp_2m", "karras", 0, 20, "enable"]),
    comfyNode(14, "KarrasScheduler", outputs: [port("SIGMAS", "SIGMAS")],
      widgets: [30, 14.6, 0.03, 7]),
    comfyNode(15, "SplitSigmas", inputs: [port("sigmas", "SIGMAS")],
      outputs: [port("high_sigmas", "SIGMAS"), port("low_sigmas", "SIGMAS")], widgets: [20]),
    comfyNode(16, "FlipSigmas", inputs: [port("sigmas", "SIGMAS")],
      outputs: [port("SIGMAS", "SIGMAS")]),
    comfyNode(17, "SplitSigmasDenoise", inputs: [port("sigmas", "SIGMAS")],
      outputs: [port("high_sigmas", "SIGMAS"), port("low_sigmas", "SIGMAS")], widgets: [0.5]),
    comfyNode(18, "ExponentialScheduler", outputs: [port("SIGMAS", "SIGMAS")],
      widgets: [20, 14.6, 0.03]),
    comfyNode(19, "BetaSamplingScheduler", inputs: [port("model", "MODEL")],
      outputs: [port("SIGMAS", "SIGMAS")], widgets: [20, 0.6, 0.6]),
    comfyNode(20, "AlignYourStepsScheduler", outputs: [port("SIGMAS", "SIGMAS")],
      widgets: ["SD1", 10, 1]),
    comfyNode(21, "DisableNoise", outputs: [port("NOISE", "NOISE")]),
    comfyNode(22, "DualCFGGuider",
      inputs: [port("model", "MODEL"), port("cond1", "CONDITIONING"),
        port("cond2", "CONDITIONING"), port("negative", "CONDITIONING")],
      outputs: [port("GUIDER", "GUIDER")], widgets: [5, 3, "nested"]),
    comfyNode(23, "KSamplerSelect", outputs: [port("SAMPLER", "SAMPLER")],
      widgets: ["euler"]),
    comfyNode(24, "SamplerCustomAdvanced",
      inputs: [port("noise", "NOISE"), port("guider", "GUIDER"), port("sampler", "SAMPLER"),
        port("sigmas", "SIGMAS"), port("latent_image", "LATENT")],
      outputs: [port("output", "LATENT"), port("denoised_output", "LATENT")]),
    comfyNode(25, "AddNoise",
      inputs: [port("model", "MODEL"), port("noise", "NOISE"), port("sigmas", "SIGMAS"),
        port("latent_image", "LATENT")],
      outputs: [port("LATENT", "LATENT")]),
    comfyNode(26, "VAELoader", outputs: [port("VAE", "VAE")], widgets: ["ae.safetensors"]),
    comfyNode(27, "VAEDecode", inputs: [port("samples", "LATENT"), port("vae", "VAE")],
      outputs: [port("IMAGE", "IMAGE")]),
    comfyNode(28, "SaveImage", inputs: [port("images", "IMAGE")], widgets: ["refined"]),
  ]
  let links: [[Any]] = [
    [1, 1, 0, 2, 0, "MODEL"],
    [2, 2, 0, 3, 0, "MODEL"],
    [3, 3, 0, 4, 0, "MODEL"],
    [4, 4, 0, 5, 0, "MODEL"],
    [5, 5, 0, 6, 0, "MODEL"],
    [6, 6, 0, 7, 0, "MODEL"],
    [7, 8, 0, 9, 0, "CLIP"],
    [8, 8, 0, 10, 0, "CLIP"],
    [9, 8, 0, 11, 0, "CLIP"],
    [10, 7, 0, 13, 0, "MODEL"],
    [11, 9, 0, 13, 1, "CONDITIONING"],
    [12, 10, 0, 13, 2, "CONDITIONING"],
    [13, 12, 0, 13, 3, "LATENT"],
    [14, 14, 0, 15, 0, "SIGMAS"],
    [15, 15, 1, 16, 0, "SIGMAS"],
    [16, 14, 0, 17, 0, "SIGMAS"],
    [17, 7, 0, 19, 0, "MODEL"],
    [18, 7, 0, 22, 0, "MODEL"],
    [19, 9, 0, 22, 1, "CONDITIONING"],
    [20, 11, 0, 22, 2, "CONDITIONING"],
    [21, 10, 0, 22, 3, "CONDITIONING"],
    [22, 21, 0, 24, 0, "NOISE"],
    [23, 22, 0, 24, 1, "GUIDER"],
    [24, 23, 0, 24, 2, "SAMPLER"],
    [25, 15, 1, 24, 3, "SIGMAS"],
    [26, 13, 0, 24, 4, "LATENT"],
    [27, 7, 0, 25, 0, "MODEL"],
    [28, 21, 0, 25, 1, "NOISE"],
    [29, 17, 0, 25, 2, "SIGMAS"],
    [30, 24, 0, 25, 3, "LATENT"],
    [31, 25, 0, 27, 0, "LATENT"],
    [32, 26, 0, 27, 1, "VAE"],
    [33, 27, 0, 28, 0, "IMAGE"],
  ]

  let result = try convertMapped(nodes, links: links)

  #expect(result.summary.placeholderNodeCount == 0)
  #expect(droppedLinks(result).isEmpty)
  #expect(node(2, in: result)?.parameters["maxShift"] == .number(1.15))
  #expect(kind(3, in: result) == "diffusion.modelSamplingSD3")
  #expect(node(4, in: result)?.parameters["zeroTerminalSNR"] == .boolean(true))
  #expect(node(7, in: result)?.parameters["preCfg"] == .boolean(true))
  // KSamplerAdvanced imports as ComfyUI's custom-sampling steps. It stops at
  // step 20 of 30 and returns the leftover noise.
  #expect(kind(13, in: result) == "diffusion.advancedSampler")
  #expect(node(13, "noise", in: result)?.parameters["seed"] == .integer(42))
  #expect(node(13, "guider", in: result)?.parameters["guidance"] == .number(7.5))
  #expect(node(13, "sampler", in: result)?.parameters["samplerName"] == .string("dpmpp_2m"))
  let scheduler = try #require(node(13, "schedule", in: result))
  #expect(scheduler.parameters["scheduler"] == .string("karras"))
  #expect(scheduler.parameters["steps"] == .integer(30))
  #expect(node(13, "endAtStep", in: result)?.parameters["step"] == .integer(20))
  #expect(node(13, "denoiseToZero", in: result) == nil)
  #expect(node(13, "startAtStep", in: result) == nil)
  #expect(isConnected(from: (13, "endAtStep", "high"), to: (13, nil, "schedule"), in: result))
  #expect(isConnected(from: (7, nil, "model"), to: (13, "schedule", "denoiser"), in: result))
  #expect(isConnected(from: (13, nil, "latent"), to: (24, nil, "sourceLatent"), in: result))
  let split = try #require(node(15, in: result))
  #expect(result.document.connections.contains {
    $0.output == PipelinePortReference(nodeID: split.id, port: "low")
  })
  #expect(node(14, in: result)?.parameters["sigmaMin"] == .number(0.03))
  #expect(node(20, in: result)?.parameters["modelType"] == .string("SD1"))
  #expect(node(22, in: result)?.parameters["secondaryGuidance"] == .integer(3))
  #expect(kind(21, in: result) == "latent.disableNoise")
  #expect(kind(25, in: result) == "latent.addNoise")
  #expect(structuralErrors(result.document).isEmpty)
}

@Test func videoAndAudioWorkflowMapsToNativeNodes() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "LoadVideo", outputs: [port("VIDEO", "VIDEO")],
      widgets: ["clip.mp4", "image"]),
    comfyNode(2, "GetVideoComponents", inputs: [port("video", "VIDEO")],
      outputs: [port("images", "IMAGE"), port("audio", "AUDIO"), port("fps", "FLOAT"),
        port("bit_depth", "COMBO"), port("color_space", "COMBO")]),
    comfyNode(3, "VAELoader", outputs: [port("VAE", "VAE")],
      widgets: ["wan_vae.safetensors"]),
    comfyNode(4, "VAEEncodeAudio", inputs: [port("audio", "AUDIO"), port("vae", "VAE")],
      outputs: [port("LATENT", "LATENT")]),
    comfyNode(5, "CLIPLoader", outputs: [port("CLIP", "CLIP")],
      widgets: ["umt5.safetensors", "wan", "default"]),
    comfyNode(6, "CLIPTextEncode", inputs: [port("clip", "CLIP")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: ["waves rolling in"]),
    comfyNode(7, "CLIPTextEncode", inputs: [port("clip", "CLIP")],
      outputs: [port("CONDITIONING", "CONDITIONING")], widgets: ["static"]),
    comfyNode(8, "CLIPVisionLoader", outputs: [port("CLIP_VISION", "CLIP_VISION")],
      widgets: ["clip_vision_h.safetensors"]),
    comfyNode(9, "CLIPVisionEncode",
      inputs: [port("clip_vision", "CLIP_VISION"), port("image", "IMAGE")],
      outputs: [port("CLIP_VISION_OUTPUT", "CLIP_VISION_OUTPUT")], widgets: ["none"]),
    comfyNode(10, "GetImageSize", inputs: [port("image", "IMAGE")],
      outputs: [port("width", "INT"), port("height", "INT"), port("batch_size", "INT")]),
    comfyNode(11, "WanImageToVideo",
      inputs: [port("positive", "CONDITIONING"), port("negative", "CONDITIONING"),
        port("vae", "VAE"), port("width", "INT", widget: true),
        port("height", "INT", widget: true), port("length", "INT", widget: true),
        port("batch_size", "INT", widget: true),
        port("clip_vision_output", "CLIP_VISION_OUTPUT"), port("start_image", "IMAGE")],
      outputs: [port("positive", "CONDITIONING"), port("negative", "CONDITIONING"),
        port("latent", "LATENT")],
      widgets: [832, 480, 81, 1]),
    comfyNode(12, "EmptyHunyuanLatentVideo", outputs: [port("LATENT", "LATENT")],
      widgets: [848, 480, 73, 1]),
    comfyNode(13, "EmptyLTXVLatentVideo", outputs: [port("LATENT", "LATENT")],
      widgets: [768, 512, 97, 1]),
    comfyNode(14, "LoadAudio", outputs: [port("AUDIO", "AUDIO")], widgets: ["music.wav"]),
    comfyNode(15, "SaveAudio", inputs: [port("audio", "AUDIO")],
      outputs: [port("audio", "AUDIO")], widgets: ["audio/wan"]),
  ]
  let links: [[Any]] = [
    [1, 1, 0, 2, 0, "VIDEO"],
    [2, 2, 1, 4, 0, "AUDIO"],
    [3, 3, 0, 4, 1, "VAE"],
    [4, 5, 0, 6, 0, "CLIP"],
    [5, 5, 0, 7, 0, "CLIP"],
    [6, 8, 0, 9, 0, "CLIP_VISION"],
    [7, 2, 0, 9, 1, "IMAGE"],
    [8, 2, 0, 10, 0, "IMAGE"],
    [9, 6, 0, 11, 0, "CONDITIONING"],
    [10, 7, 0, 11, 1, "CONDITIONING"],
    [11, 3, 0, 11, 2, "VAE"],
    [12, 10, 0, 11, 3, "INT"],
    [13, 9, 0, 11, 7, "CLIP_VISION_OUTPUT"],
    [14, 2, 0, 11, 8, "IMAGE"],
    [15, 14, 0, 15, 0, "AUDIO"],
  ]

  let result = try convertMapped(nodes, links: links)

  #expect(result.summary.placeholderNodeCount == 0)
  #expect(result.summary.connectionCount == links.count)
  #expect(node(1, in: result)?.parameters["sourceName"] == .string("clip.mp4"))
  let components = try #require(node(2, in: result))
  #expect(components.kind == .videoComponents)
  #expect(PipelineNodeRegistry.coreAIV1.descriptor(for: components.kind)?
    .output(named: "bitDepth")?.type == .string)
  #expect(PipelineNodeRegistry.coreAIV1.descriptor(for: components.kind)?
    .output(named: "colorSpace")?.type == .string)
  #expect(result.document.connections.contains {
    $0.output == PipelinePortReference(nodeID: components.id, port: "audio")
  })
  #expect(kind(4, in: result) == "coreai.vaeAudioEncoder")
  let wan = try #require(node(11, in: result))
  #expect(wan.kind == .wanImageToVideoConditioning)
  #expect(wan.parameters["length"] == .integer(81))
  #expect(wan.parameters["batchSize"] == .integer(1))
  #expect(result.document.connections.contains {
    $0.input == PipelinePortReference(nodeID: wan.id, port: "visionEmbedding")
  })
  #expect(node(12, in: result)?.parameters["length"] == .integer(73))
  #expect(kind(13, in: result) == "latent.emptyLTXVVideo")
  #expect(node(14, in: result)?.parameters["sourceName"] == .string("music.wav"))
  let output = try #require(node(15, in: result))
  #expect(output.kind == .audioOutput)
  #expect(result.document.primaryOutputNodeIDs == [output.id])
  #expect(structuralErrors(result.document).isEmpty)
}

@Test func rerouteAndStringWorkflowKeepsCommunitySetGetNodes() throws {
  let text = { (id: Int, type: String, widgets: [Any], output: String) -> [String: Any] in
    comfyNode(id, type, inputs: [port("string", "STRING", widget: true)],
      outputs: [port(output, output)], widgets: widgets)
  }
  let nodes: [[String: Any]] = [
    comfyNode(1, "LoadImage", outputs: [port("IMAGE", "IMAGE"), port("MASK", "MASK")],
      widgets: ["photo.png", "image"]),
    comfyNode(2, "Reroute", inputs: [port("", "*")], outputs: [port("", "IMAGE")]),
    comfyNode(3, "SetNode", inputs: [port("IMAGE", "IMAGE")], outputs: [port("*", "*")],
      widgets: ["photo"]),
    comfyNode(4, "GetNode", outputs: [port("IMAGE", "IMAGE")], widgets: ["photo"]),
    comfyNode(5, "SaveImage", inputs: [port("images", "IMAGE")], widgets: ["routed"]),
    comfyNode(6, "PrimitiveString", outputs: [port("STRING", "STRING")],
      widgets: ["  Hello World  "]),
    text(7, "StringTrim", ["", "Both"], "STRING"),
    text(8, "CaseConverter", ["", "lowercase"], "STRING"),
    text(9, "StringLength", [""], "INT"),
    comfyNode(10, "StringSubstring",
      inputs: [port("string", "STRING", widget: true), port("start", "INT", widget: true),
        port("end", "INT", widget: true)],
      outputs: [port("STRING", "STRING")], widgets: ["", 0, 5]),
    text(11, "StringContains", ["", "hello", false], "BOOLEAN"),
    comfyNode(12, "StringCompare",
      inputs: [port("string_a", "STRING", widget: true),
        port("string_b", "STRING", widget: true),
        port("mode", "COMBO", widget: true),
        port("case_sensitive", "BOOLEAN", widget: true)],
      outputs: [port("BOOLEAN", "BOOLEAN")],
      widgets: ["", "hello", "Starts With", true]),
    text(13, "RegexMatch", ["", "h.*d", true, false, false], "BOOLEAN"),
    text(14, "RegexExtract", ["", "(w\\w+)", "First Group", true, false, false, 1], "STRING"),
  ]
  let links: [[Any]] = [
    [1, 1, 0, 2, 0, "IMAGE"],
    [2, 2, 0, 3, 0, "IMAGE"],
    [3, 4, 0, 5, 0, "IMAGE"],
    [4, 6, 0, 7, 0, "STRING"],
    [5, 7, 0, 8, 0, "STRING"],
    [6, 8, 0, 9, 0, "STRING"],
    [7, 8, 0, 10, 0, "STRING"],
    [8, 9, 0, 10, 2, "INT"],
    [9, 10, 0, 11, 0, "STRING"],
    [10, 10, 0, 12, 0, "STRING"],
    [11, 8, 0, 13, 0, "STRING"],
    [12, 8, 0, 14, 0, "STRING"],
  ]

  let result = try convertMapped(nodes, links: links)

  #expect(result.summary.placeholderNodeCount == 2)
  #expect(kind(3, in: result) == "comfyui.SetNode")
  #expect(kind(4, in: result) == "comfyui.GetNode")
  #expect(result.summary.connectionCount == links.count)
  let reroute = try #require(node(2, in: result))
  let get = try #require(node(4, in: result))
  #expect(reroute.kind == .reroute)
  let save = try #require(node(5, in: result))
  #expect(result.document.connections.contains {
    $0.output == PipelinePortReference(nodeID: get.id, port: "IMAGE")
      && $0.input == PipelinePortReference(nodeID: save.id, port: "image")
  })
  #expect(isConnected(from: (2, nil, "value"), to: (3, nil, "IMAGE"), in: result))
  #expect(node(7, in: result)?.parameters["mode"] == .string("Both"))
  #expect(node(8, in: result)?.kind == .textChangeCase)
  #expect(kind(9, in: result) == "text.length")
  let substring = try #require(node(10, in: result))
  #expect(result.document.connections.contains {
    $0.input == PipelinePortReference(nodeID: substring.id, port: "end")
  })
  #expect(node(11, in: result)?.parameters["caseSensitive"] == .boolean(false))
  #expect(node(12, in: result)?.parameters["mode"] == .string("Starts With"))
  #expect(node(13, in: result)?.parameters["pattern"] == .string("h.*d"))
  #expect(node(14, in: result)?.parameters["groupIndex"] == .integer(1))
  #expect(structuralErrors(result.document).allSatisfy {
    $0.code == .unsupportedNodeImplementation
  })
}

@Test func unmatchedGetNodeStaysAPlaceholder() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "GetNode", outputs: [port("IMAGE", "IMAGE")], widgets: ["ghost"]),
    comfyNode(2, "PreviewImage", inputs: [port("images", "IMAGE")]),
  ]
  let links: [[Any]] = [[1, 1, 0, 2, 0, "IMAGE"]]

  let mapped = try convertMapped(nodes, links: links)
  #expect(kind(1, in: mapped) == "comfyui.GetNode")
  #expect(mapped.document.connections.count == 1)

  // Lossless import never rewrites the graph.
  let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": links])
  let lossless = try ComfyUIWorkflowConverter.convert(data)
  #expect(lossless.document.nodes.count == 2)
  #expect(!lossless.diagnostics.contains { $0.message.contains("Set/Get") })
}

@Test func kSamplerAdvancedStepRangeBecomesScheduleSurgery() throws {
  func sampler(_ id: Int, _ widgets: [Any]) -> [String: Any] {
    comfyNode(id, "KSamplerAdvanced",
      inputs: [port("model", "MODEL"), port("positive", "CONDITIONING"),
        port("negative", "CONDITIONING"), port("latent_image", "LATENT")],
      outputs: [port("LATENT", "LATENT")], widgets: widgets)
  }
  let nodes = [
    // Base pass: stop at step 12 of 30 without leftover noise.
    sampler(1, ["enable", 7, "fixed", 30, 6, "euler", "normal", 0, 12, "disable"]),
    // Refiner pass: continue from step 12 without adding noise.
    sampler(2, ["disable", 7, "fixed", 30, 6, "euler", "normal", 12, 10000, "disable"]),
  ]
  let result = try convertMapped(nodes, links: [[1, 1, 0, 2, 3, "LATENT"]])

  #expect(kind(1, "noise", in: result) == "latent.randomNoise")
  #expect(node(1, "endAtStep", in: result)?.parameters["step"] == .integer(12))
  #expect(kind(1, "denoiseToZero", in: result) == "diffusion.forceFullDenoise")
  #expect(isConnected(
    from: (1, "endAtStep", "high"), to: (1, "denoiseToZero", "schedule"), in: result))
  #expect(isConnected(from: (1, "denoiseToZero", "schedule"), to: (1, nil, "schedule"), in: result))

  #expect(kind(2, "noise", in: result) == "latent.disableNoise")
  #expect(node(2, "endAtStep", in: result) == nil)
  #expect(node(2, "startAtStep", in: result)?.parameters["step"] == .integer(12))
  #expect(isConnected(from: (2, "startAtStep", "low"), to: (2, nil, "schedule"), in: result))
  #expect(isConnected(from: (1, nil, "latent"), to: (2, nil, "sourceLatent"), in: result))
  #expect(result.document.presentation?.groups.map(\.id).sorted()
    == ["comfyui-subgraph-1", "comfyui-subgraph-2"])
}

@Test func kSamplerAdvancedEarlyReturnStaysAPlaceholder() throws {
  let nodes = [
    comfyNode(1, "KSamplerAdvanced",
      inputs: [port("model", "MODEL"), port("positive", "CONDITIONING"),
        port("negative", "CONDITIONING"), port("latent_image", "LATENT")],
      outputs: [port("LATENT", "LATENT")],
      widgets: ["disable", 7, "fixed", 30, 6, "euler", "normal", 12, 12, "disable"]),
  ]
  let result = try convertMapped(nodes, links: [])

  #expect(kind(1, in: result) == "comfyui.KSamplerAdvanced")
  #expect(result.document.nodes.count == 1)
}

@Test func createVideoKeepsOptionalMediaSettingsAndAutoBitDepth() throws {
  let nodes = [
    comfyNode(1, "CreateVideo", inputs: [port("images", "IMAGE")],
      outputs: [port("VIDEO", "VIDEO")],
      widgets: [30, "auto", "HDR PQ", "av1"]),
  ]
  let result = try convertMapped(nodes, links: [])

  #expect(kind(1, in: result) == "media.createVideo")
  #expect(node(1, in: result)?.parameters["bitDepth"] == .string("auto"))
  #expect(node(1, in: result)?.parameters["colorSpace"] == .string("HDR PQ"))
  #expect(node(1, in: result)?.parameters["codec"] == .string("av1"))
  let descriptor = try #require(PipelineNodeRegistry.coreAIV1.descriptor(for:
    PipelineNodeKind(rawValue: "media.createVideo")))
  #expect(descriptor.inputs.first(where: { $0.name == "audio" })?.isRequired == false)
  #expect(descriptor.parameters.first(where: { $0.name == "bitDepth" })?.valueType == .any)
}

@Test func dynamicSaveSettingsStayWithSourceNodes() throws {
  let nodes = [
    comfyNode(1, "SaveImageAdvanced", inputs: [port("images", "IMAGE")],
      outputs: [port("images", "IMAGE")],
      widgets: ["ComfyUI", "avif", "10-bit YUV420", "HDR", 18]),
    comfyNode(2, "SaveVideo", inputs: [port("video", "VIDEO")],
      outputs: [port("video", "VIDEO")],
      widgets: ["video/ComfyUI", ["format": "mp4", "codec": "h264"]]),
  ]
  let result = try convertMapped(nodes, links: [])

  #expect(kind(1, in: result) == "comfyui.SaveImageAdvanced")
  #expect(kind(2, in: result) == "comfyui.SaveVideo")
  #expect(node(1, in: result)?.origin?.metadata["widgets"] != nil)
  #expect(node(2, in: result)?.origin?.metadata["widgets"] != nil)
}

@Test func linkedWidgetWithoutNativePortKeepsTheOriginalNodeAndLink() throws {
  let nodes = [
    comfyNode(1, "SourceText", outputs: [port("value", "STRING")]),
    comfyNode(2, "StringTrim",
      inputs: [port("string", "STRING", widget: true),
        port("mode", "COMBO", widget: true)],
      outputs: [port("value", "STRING")], widgets: [" padded ", "Both"]),
  ]
  let result = try convertMapped(nodes, links: [[1, 1, 0, 2, 1, "STRING"]])

  #expect(kind(2, in: result) == "comfyui.StringTrim")
  #expect(result.summary.placeholderNodeCount == 2)
  #expect(result.document.connections.count == 1)
  #expect(isConnected(from: (1, nil, "value"), to: (2, nil, "mode"), in: result))
  #expect(result.diagnostics.contains {
    $0.sourceNodeID == "2" && $0.message.contains("omits a connected port")
  })
}

@Test func changedComfyUIOutputShapeStaysInspectable() throws {
  let nodes = [
    comfyNode(1, "GetVideoComponents", inputs: [port("video", "VIDEO")],
      outputs: [port("images", "IMAGE"), port("audio", "AUDIO"),
        port("fps", "FLOAT"), port("bit_depth", "COMBO"),
        port("color_space", "COMBO"), port("future", "STRING")]),
  ]
  let result = try convertMapped(nodes, links: [])

  #expect(kind(1, in: result) == "comfyui.GetVideoComponents")
  #expect(node(1, in: result)?.importedDescriptor?.outputs.count == 6)
}

@Test func unknownComfyUIWidgetStaysInspectable() throws {
  let nodes = [
    comfyNode(1, "CFGNorm", inputs: [port("model", "MODEL")],
      outputs: [port("MODEL", "MODEL")], widgets: [1, false, "new-option"]),
  ]
  let result = try convertMapped(nodes, links: [])

  #expect(kind(1, in: result) == "comfyui.CFGNorm")
  #expect(node(1, in: result)?.origin?.metadata["widgets"]
    == .array([.integer(1), .boolean(false), .string("new-option")]))
}

// MARK: - Helpers

private func port(_ name: String, _ type: String, widget: Bool = false) -> [String: Any] {
  var result: [String: Any] = ["name": name, "type": type]
  if widget { result["widget"] = ["name": name] }
  return result
}

private func comfyNode(
  _ id: Int,
  _ type: String,
  inputs: [[String: Any]] = [],
  outputs: [[String: Any]] = [],
  widgets: [Any] = []
) -> [String: Any] {
  [
    "id": id, "type": type, "inputs": inputs, "outputs": outputs,
    "properties": [String: Any](), "widgets_values": widgets,
  ]
}

private func convertMapped(
  _ nodes: [[String: Any]],
  links: [[Any]]
) throws -> ComfyUIConversionResult {
  let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": links])
  return try ComfyUIWorkflowConverter.convert(
    data, options: ComfyUIConversionOptions(mapNodes: true, includeResourceGuidance: false))
}

private func node(_ id: Int, in result: ComfyUIConversionResult) -> PipelineNode? {
  result.document.nodes.first { $0.id.rawValue == "comfyui-node-\(id)" }
}

private func kind(_ id: Int, in result: ComfyUIConversionResult) -> String? {
  node(id, in: result)?.kind.rawValue
}

/// A node of the subgraph an all-in-one ComfyUI node imports as.
private func node(_ id: Int, _ role: String, in result: ComfyUIConversionResult) -> PipelineNode? {
  result.document.nodes.first { $0.id.rawValue == "comfyui-node-\(id)-\(role)" }
}

private func kind(_ id: Int, _ role: String, in result: ComfyUIConversionResult) -> String? {
  node(id, role, in: result)?.kind.rawValue
}

/// Whether a connection joins two ports, each named by ComfyUI node ID, an
/// optional subgraph role, and the native port.
private func isConnected(
  from output: (id: Int, role: String?, port: String),
  to input: (id: Int, role: String?, port: String),
  in result: ComfyUIConversionResult
) -> Bool {
  func reference(_ id: Int, _ role: String?, _ port: String) -> PipelinePortReference {
    let suffix = role.map { "-\($0)" } ?? ""
    return PipelinePortReference(
      nodeID: PipelineNodeID(rawValue: "comfyui-node-\(id)\(suffix)"), port: port)
  }
  let outputReference = reference(output.id, output.role, output.port)
  let inputReference = reference(input.id, input.role, input.port)
  return result.document.connections.contains {
    $0.output == outputReference && $0.input == inputReference
  }
}

private func droppedLinks(_ result: ComfyUIConversionResult) -> [ComfyUIConversionDiagnostic] {
  result.diagnostics.filter { $0.message.contains("omitted by conservative node mapping") }
}

/// Errors a mapping could introduce. Unlinked model resources are expected
/// for an imported graph and are not structural.
private func structuralErrors(_ document: PipelineDocument) -> [PipelineDiagnostic] {
  PipelineGraphValidator.validate(document, registry: .coreAIV1).errors.filter {
    $0.code != .unresolvedResource
  }
}

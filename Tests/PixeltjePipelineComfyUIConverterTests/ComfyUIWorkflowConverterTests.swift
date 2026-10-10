import Foundation
import PixeltjePipelineComfyUIConverter
import PixeltjePipelineDomain
import Testing

private let workflow = #"""
  {
    "nodes": [
      {
        "id": 1,
        "type": "UNETLoader",
        "pos": [10, 20],
        "size": [200, 100],
        "mode": 0,
        "inputs": [],
        "outputs": [{"name": "MODEL", "type": "MODEL", "links": [1]}],
        "properties": {},
        "widgets_values": ["flux2.safetensors", "default"]
      },
      {
        "id": 2,
        "type": "SaveImage",
        "pos": [300, 20],
        "size": [200, 100],
        "mode": 2,
        "inputs": [{"name": "images", "type": "IMAGE", "link": 2}],
        "outputs": [],
        "properties": {},
        "widgets_values": ["ComfyUI"]
      },
      {
        "id": 3,
        "type": "CustomNode",
        "pos": [30, 180],
        "size": [180, 90],
        "mode": 4,
        "inputs": [{"name": "model", "type": "MODEL", "link": 1}],
        "outputs": [{"name": "image", "type": "IMAGE", "links": [2]}],
        "properties": {},
        "widgets_values": [42]
      }
    ],
    "links": [
      [1, 1, 0, 3, 0, "MODEL"],
      [2, 3, 0, 2, 0, "IMAGE"]
    ],
    "groups": [
      {"id": 1, "title": "Models", "bounding": [0, 0, 600, 400], "color": "#ffffff"}
    ],
    "extra": {"ds": {"scale": 0.75}}
  }
  """#

@Test func losslessImportPreservesGraphAndUnresolvedResources() throws {
  let result = try ComfyUIWorkflowConverter.convert(
    Data(workflow.utf8), sourceName: "example.json")

  #expect(result.summary.sourceNodeCount == 3)
  #expect(result.summary.connectionCount == 2)
  #expect(result.summary.mappedNodeCount == 0)
  #expect(result.summary.unresolvedResourceCount == 1)
  #expect(result.document.schemaVersion == 2)
  #expect(result.document.presentation?.groups.count == 1)
  #expect(result.document.presentation?.viewportScale == 0.75)
  #expect(result.document.nodes.first?.origin?.sourceType == "UNETLoader")
  #expect(result.document.nodes[1].executionState == .disabled)
  #expect(result.document.nodes[2].executionState == .bypassed)

  let resource = result.document.nodes[0].resources["denoiser"]?.unresolvedRequirement
  #expect(resource?.sourceName == "flux2.safetensors")
  #expect(resource?.sourceFormat == "safetensors")

  let roundTrip = try PipelineJSON.decode(PipelineJSON.encode(result.document))
  #expect(roundTrip == result.document)
}

@Test func mappedImportOnlyRewritesRecognizedNodes() throws {
  let result = try ComfyUIWorkflowConverter.convert(
    Data(workflow.utf8),
    options: ComfyUIConversionOptions(mapNodes: true))

  #expect(result.summary.mappedNodeCount == 2)
  #expect(result.summary.placeholderNodeCount == 1)
  #expect(result.document.nodes[0].kind.rawValue == "coreai.denoiser")
  #expect(result.document.nodes[1].kind.rawValue == "output.image")
  #expect(result.document.nodes[2].kind.rawValue == "comfyui.CustomNode")
  #expect(result.document.connections.map(\.id.rawValue) == ["comfyui-link-1", "comfyui-link-2"])
}

@Test func zImageTurboSamplingNodesMapOneForOne() throws {
  func port(_ name: String, _ type: String, widget: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["name": name, "type": type]
    if widget { result["widget"] = ["name": name] }
    return result
  }
  let nodes: [[String: Any]] = [
    [
      "id": 1, "type": "ConditioningZeroOut", "inputs": [port("conditioning", "CONDITIONING")],
      "outputs": [port("CONDITIONING", "CONDITIONING")], "properties": [:],
      "widgets_values": [],
    ],
    [
      "id": 2, "type": "EmptySD3LatentImage",
      "inputs": [port("width", "INT", widget: true), port("height", "INT", widget: true),
        port("batch_size", "INT", widget: true)],
      "outputs": [port("LATENT", "LATENT")], "properties": [:],
      "widgets_values": [1024, 768, 1],
    ],
    [
      "id": 3, "type": "ModelSamplingAuraFlow",
      "inputs": [port("model", "MODEL"), port("shift", "FLOAT", widget: true)],
      "outputs": [port("MODEL", "MODEL")], "properties": [:], "widgets_values": [3],
    ],
    [
      "id": 4, "type": "KSampler",
      "inputs": [port("model", "MODEL"), port("positive", "CONDITIONING"),
        port("negative", "CONDITIONING"), port("latent_image", "LATENT"),
        port("seed", "INT", widget: true), port("control_after_generate", "COMBO", widget: true),
        port("steps", "INT", widget: true), port("cfg", "FLOAT", widget: true),
        port("sampler_name", "COMBO", widget: true),
        port("scheduler", "COMBO", widget: true), port("denoise", "FLOAT", widget: true)],
      "outputs": [port("LATENT", "LATENT")], "properties": [:],
      "widgets_values": [0, "randomize", 8, 1, "res_multistep", "simple", 1],
    ],
  ]
  let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": [
    [1, 3, 0, 4, 0, "MODEL"],
    [2, 1, 0, 4, 2, "CONDITIONING"],
    [3, 2, 0, 4, 3, "LATENT"],
  ]])

  let result = try ComfyUIWorkflowConverter.convert(
    data,
    options: ComfyUIConversionOptions(mapNodes: true, includeResourceGuidance: false))
  let kinds = Dictionary(uniqueKeysWithValues: result.document.nodes.map {
    ($0.origin?.sourceType ?? "", $0.kind.rawValue)
  })

  #expect(result.summary.mappedNodeCount == 4)
  #expect(result.summary.placeholderNodeCount == 0)
  #expect(kinds["ConditioningZeroOut"] == "conditioning.zero")
  #expect(kinds["EmptySD3LatentImage"] == "latent.emptyImage")
  #expect(kinds["ModelSamplingAuraFlow"] == "diffusion.modelSamplingDiscreteFlow")
  #expect(kinds["KSampler"] == "diffusion.kSampler")
  let empty = try #require(result.document.nodes.first { $0.kind.rawValue == "latent.emptyImage" })
  #expect(empty.parameters["width"] == .integer(1024))
  #expect(empty.parameters["height"] == .integer(768))
  #expect(empty.parameters["batchSize"] == .integer(1))
  let sampler = try #require(result.document.nodes.first { $0.kind.rawValue == "diffusion.kSampler" })
  #expect(sampler.parameters["sampler"] == .string("res_multistep"))
  #expect(sampler.parameters["scheduler"] == .string("simple"))
  #expect(result.document.connections.contains {
    $0.input.nodeID == sampler.id && $0.input.port == "latent"
  })
}

@Test func knownLargeModelAddsGenericResourceGuidanceNode() throws {
  let workflow: [String: Any] = [
    "nodes": [[
      "id": 77,
      "type": "UNETLoader",
      "pos": [20, 40],
      "size": [220, 100],
      "mode": 0,
      "inputs": [],
      "outputs": [["name": "MODEL", "type": "MODEL", "links": []]],
      "properties": [
        "models": [[
          "name": "flux-2-klein-4b.safetensors",
          "directory": "diffusion_models",
          "url": "https://example.invalid/original-model",
        ], [
          "name": "flux-2-klein-4b.safetensors",
          "directory": "diffusion_models",
          "url": "https://example.invalid/original-model",
        ]]
      ],
      "widgets_values": ["flux-2-klein-4b.safetensors", "default"],
    ]],
    "links": [],
  ]
  let data = try JSONSerialization.data(withJSONObject: workflow)

  let result = try ComfyUIWorkflowConverter.convert(data)
  let tip = try #require(result.document.nodes.first {
    $0.origin?.system == "pixeltje.resource-guidance"
  })
  let markdownValue = try #require(tip.parameters["text"])
  let extractedMarkdown: String? = if case .string(let value) = markdownValue { value } else { nil }
  let markdown = try #require(extractedMarkdown)

  #expect(result.summary.sourceNodeCount == 1)
  #expect(result.summary.placeholderNodeCount == 1)
  #expect(result.summary.unresolvedResourceCount == 2)
  #expect(result.document.nodes.count == 2)
  #expect(tip.kind.rawValue == "edit.markdownNote")
  #expect(tip.executionState == .disabled)
  #expect(markdown.contains("git clone https://github.com/apple/coreai-models.git"))
  #expect(markdown.contains("3f109efd54273391f9fd9f5f5b3d8c6e99836d55"))
  #expect(markdown.contains("coreai.diffusion.export flux2-klein-4b --platform macOS"))
  #expect(markdown.contains("does not run the export, download or copy"))
  #expect(result.diagnostics.contains { $0.message.contains("FLUX.2 Klein 4B") })
  #expect(result.document.presentation?.nodePositions[tip.id.rawValue]?.x == 380)
  #expect(result.document.presentation?.viewportOrigin?.x == 340)
}

@Test func resourceGuidanceCanBeDisabled() throws {
  let workflow: [String: Any] = [
    "nodes": [[
      "id": 1,
      "type": "UNETLoader",
      "inputs": [],
      "outputs": [["name": "MODEL", "type": "MODEL", "links": []]],
      "properties": [
        "models": [[
          "name": "flux-2-klein-4b.safetensors",
          "directory": "diffusion_models",
        ]]
      ],
      "widgets_values": ["flux-2-klein-4b.safetensors", "default"],
    ]],
    "links": [],
  ]
  let data = try JSONSerialization.data(withJSONObject: workflow)

  let result = try ComfyUIWorkflowConverter.convert(
    data,
    options: ComfyUIConversionOptions(includeResourceGuidance: false))

  #expect(result.document.nodes.count == 1)
  #expect(result.document.nodes.allSatisfy { $0.origin?.system != "pixeltje.resource-guidance" })
}

@Test func miniMaxReferenceVideoNodesMapToNativeKinds() throws {
  func port(_ name: String, _ type: Any, widget: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["name": name, "type": type]
    if widget { result["widget"] = ["name": name] }
    return result
  }
  func node(
    _ id: Int,
    _ type: String,
    inputs: [[String: Any]] = [],
    outputs: [[String: Any]] = [],
    widgets: [Any] = []
  ) -> [String: Any] {
    [
      "id": id,
      "type": type,
      "inputs": inputs,
      "outputs": outputs,
      "widgets_values": widgets,
      "properties": [String: Any](),
    ]
  }

  let nodes: [[String: Any]] = [
    node(1, "SaveVideo",
      inputs: [port("video", "VIDEO"), port("filename_prefix", "STRING", widget: true),
        port("format", "COMBO", widget: true), port("codec", "COMFY_DYNAMICCOMBO_V3", widget: true)],
      outputs: [port("video", "VIDEO")], widgets: ["video/Test", "auto", "auto"]),
    node(2, "ResolutionSelector",
      inputs: [port("aspect_ratio", "COMBO", widget: true),
        port("megapixels", "FLOAT", widget: true), port("multiple", "INT", widget: true)],
      outputs: [port("width", "INT"), port("height", "INT")],
      widgets: ["16:9", 0.4, 32]),
    node(3, "MarkdownNote", widgets: ["Reference workflow"]),
    node(4, "VAELoader", inputs: [port("vae_name", "COMBO", widget: true)],
      outputs: [port("VAE", "VAE")], widgets: ["video-vae.safetensors"]),
    node(5, "VAEDecodeAudio",
      inputs: [port("samples", "LATENT"), port("vae", "VAE")],
      outputs: [port("AUDIO", "AUDIO")]),
    node(6, "VAEDecode",
      inputs: [port("samples", "LATENT"), port("vae", "VAE")],
      outputs: [port("IMAGE", "IMAGE")]),
    node(7, "KSamplerSelect", inputs: [port("sampler_name", "COMBO", widget: true)],
      outputs: [port("SAMPLER", "SAMPLER")], widgets: ["res_multistep"]),
    node(8, "BasicScheduler",
      inputs: [port("model", "MODEL"), port("scheduler", "COMBO", widget: true),
        port("steps", "INT", widget: true), port("denoise", "FLOAT", widget: true)],
      outputs: [port("SIGMAS", "SIGMAS")], widgets: ["simple", 20, 1]),
    node(9, "SamplerCustomAdvanced",
      inputs: [port("noise", "NOISE"), port("guider", "GUIDER"),
        port("sampler", "SAMPLER"), port("sigmas", "SIGMAS"),
        port("latent_image", "LATENT")],
      outputs: [port("output", "LATENT"), port("denoised_output", "LATENT")]),
    node(10, "BasicGuider",
      inputs: [port("model", "MODEL"), port("conditioning", "CONDITIONING")],
      outputs: [port("GUIDER", "GUIDER")]),
    node(11, "UNETLoader",
      inputs: [port("unet_name", "COMBO", widget: true),
        port("weight_dtype", "COMBO", widget: true)],
      outputs: [port("MODEL", "MODEL")], widgets: ["model.safetensors", "default"]),
    node(12, "CLIPLoader",
      inputs: [port("clip_name", "COMBO", widget: true),
        port("type", "COMBO", widget: true), port("device", "COMBO", widget: true)],
      outputs: [port("CLIP", "CLIP")], widgets: ["encoder.safetensors", "minimax", "default"]),
    node(13, "RandomNoise", inputs: [port("noise_seed", "INT", widget: true)],
      outputs: [port("NOISE", "NOISE")], widgets: [7, "fixed"]),
    node(14, "CreateVideo",
      inputs: [port("images", "IMAGE"), port("audio", "AUDIO"),
        port("fps", "FLOAT", widget: true), port("bit_depth", "INT", widget: true)],
      outputs: [port("VIDEO", "VIDEO")], widgets: [24, 8]),
    node(15, "ComfyMathExpression",
      inputs: [port("values.a", ["FLOAT", "INT", "BOOLEAN"]),
        port("values.b", ["FLOAT", "INT", "BOOLEAN"]),
        port("expression", "STRING", widget: true)],
      outputs: [port("FLOAT", "FLOAT"), port("INT", "INT"), port("BOOL", "BOOLEAN")],
      widgets: ["round(a)"]),
    node(16, "PrimitiveFloat", inputs: [port("value", "FLOAT", widget: true)],
      outputs: [port("FLOAT", "FLOAT")], widgets: [5]),
    node(17, "MiniMaxH3ReferenceToVideo",
      inputs: [port("clip", "CLIP"), port("vae", "VAE"), port("audio_vae", "VAE"),
        port("ref_images.ref_image_0", "IMAGE"), port("ref_images.ref_image_1", "IMAGE"),
        port("ref_images.ref_image_2", "IMAGE"), port("ref_videos.ref_video_0", "IMAGE"),
        port("ref_video_audios.ref_video_audio_0", "AUDIO"),
        port("ref_audios.ref_audio_0", "AUDIO"), port("prompt", "STRING", widget: true),
        port("width", "INT", widget: true), port("height", "INT", widget: true),
        port("length", "INT", widget: true), port("ref_image_size", "COMBO", widget: true)],
      outputs: [port("positive", "CONDITIONING"), port("LATENT", "LATENT")],
      widgets: ["prompt", 864, 480, 124, "match"]),
    node(18, "LoadImage",
      inputs: [port("image", "COMBO", widget: true),
        port("upload", "IMAGEUPLOAD", widget: true)],
      outputs: [port("IMAGE", "IMAGE"), port("MASK", "MASK")],
      widgets: ["reference.png", "image"]),
    node(19, "PrimitiveStringMultiline",
      inputs: [port("value", "STRING", widget: true)], outputs: [port("STRING", "STRING")],
      widgets: ["prompt"]),
    node(20, "ComfySwitchNode",
      inputs: [port("on_false", "MODEL"), port("on_true", "MODEL"),
        port("switch", "BOOLEAN", widget: true)], outputs: [port("output", "MODEL")],
      widgets: [false]),
    node(21, "PrimitiveInt", inputs: [port("value", "INT", widget: true)],
      outputs: [port("INT", "INT")], widgets: [20, "fixed"]),
    node(22, "LoraLoaderModelOnly",
      inputs: [port("model", "MODEL"), port("lora_name", "COMBO", widget: true),
        port("strength_model", "FLOAT", widget: true)], outputs: [port("MODEL", "MODEL")],
      widgets: ["adapter.safetensors", 1]),
    node(23, "PrimitiveBoolean", inputs: [port("value", "BOOLEAN", widget: true)],
      outputs: [port("BOOLEAN", "BOOLEAN")], widgets: [false]),
  ]
  let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": []])

  let result = try ComfyUIWorkflowConverter.convert(
    data, options: ComfyUIConversionOptions(mapNodes: true))
  let kindsBySourceType = Dictionary(uniqueKeysWithValues: result.document.nodes.map {
    ($0.origin?.sourceType ?? "", $0.kind.rawValue)
  })

  #expect(result.summary.mappedNodeCount == nodes.count)
  #expect(result.summary.placeholderNodeCount == 0)
  #expect(result.document.nodes.allSatisfy { !$0.kind.rawValue.hasPrefix("comfyui.") })
  #expect(kindsBySourceType["SaveVideo"] == "output.video")
  #expect(kindsBySourceType["MarkdownNote"] == "edit.markdownNote")
  #expect(kindsBySourceType["VAELoader"] == "coreai.vaeModel")
  #expect(kindsBySourceType["VAEDecodeAudio"] == "coreai.vaeAudioDecoder")
  #expect(kindsBySourceType["SamplerCustomAdvanced"] == "diffusion.advancedSampler")
  #expect(kindsBySourceType["MiniMaxH3ReferenceToVideo"] == "conditioning.referenceToVideo")
  #expect(kindsBySourceType["ComfySwitchNode"] == "logic.ifElse")
}

private let utilityWorkflow = #"""
  {
    "nodes": [
      {
        "id": 1, "type": "PrimitiveString", "pos": [0, 0], "size": [180, 70],
        "inputs": [{"name": "value", "type": "STRING", "widget": {"name": "value"}}],
        "outputs": [{"name": "STRING", "type": "STRING", "links": [2]}],
        "properties": {}, "widgets_values": ["false branch"]
      },
      {
        "id": 2, "type": "PrimitiveStringMultiline", "pos": [0, 100], "size": [180, 90],
        "inputs": [{"name": "value", "type": "STRING", "widget": {"name": "value"}}],
        "outputs": [{"name": "STRING", "type": "STRING", "links": [3]}],
        "properties": {}, "widgets_values": ["true\nbranch"]
      },
      {
        "id": 3, "type": "PrimitiveInt", "pos": [0, 220], "size": [180, 70],
        "inputs": [{"name": "value", "type": "INT", "widget": {"name": "value"}}],
        "outputs": [{"name": "INT", "type": "INT", "links": [5]}],
        "properties": {}, "widgets_values": [24]
      },
      {
        "id": 4, "type": "PrimitiveFloat", "pos": [0, 320], "size": [180, 70],
        "inputs": [{"name": "value", "type": "FLOAT", "widget": {"name": "value"}}],
        "outputs": [{"name": "FLOAT", "type": "FLOAT", "links": [6]}],
        "properties": {}, "widgets_values": [0.75]
      },
      {
        "id": 5, "type": "PrimitiveBoolean", "pos": [0, 420], "size": [180, 70],
        "inputs": [{"name": "value", "type": "BOOLEAN", "widget": {"name": "value"}}],
        "outputs": [{"name": "BOOLEAN", "type": "BOOLEAN", "links": [1]}],
        "properties": {}, "widgets_values": [true]
      },
      {
        "id": 6, "type": "ComfySwitchNode", "pos": [260, 80], "size": [220, 120],
        "inputs": [
          {"name": "switch", "type": "BOOLEAN", "link": 1, "widget": {"name": "switch"}},
          {"name": "on_false", "type": "*", "link": 2},
          {"name": "on_true", "type": "*", "link": 3}
        ],
        "outputs": [{"name": "output", "type": "*", "links": []}],
        "properties": {}, "widgets_values": [false]
      },
      {
        "id": 7, "type": "BasicScheduler", "pos": [260, 280], "size": [220, 130],
        "inputs": [
          {"name": "model", "type": "MODEL", "link": null},
          {"name": "scheduler", "type": "COMBO", "widget": {"name": "scheduler"}},
          {"name": "steps", "type": "INT", "link": 5, "widget": {"name": "steps"}},
          {"name": "denoise", "type": "FLOAT", "link": 6, "widget": {"name": "denoise"}}
        ],
        "outputs": [{"name": "SIGMAS", "type": "SIGMAS", "links": []}],
        "properties": {}, "widgets_values": ["normal", 20, 1.0]
      }
    ],
    "links": [
      [1, 5, 0, 6, 0, "BOOLEAN"],
      [2, 1, 0, 6, 1, "STRING"],
      [3, 2, 0, 6, 2, "STRING"],
      [5, 3, 0, 7, 2, "INT"],
      [6, 4, 0, 7, 3, "FLOAT"]
    ]
  }
  """#

@Test func mappedImportUsesNativePrimitiveLogicAndSchedulerNodes() throws {
  let result = try ComfyUIWorkflowConverter.convert(
    Data(utilityWorkflow.utf8),
    options: ComfyUIConversionOptions(mapNodes: true))

  #expect(result.summary.mappedNodeCount == 7)
  #expect(result.summary.placeholderNodeCount == 0)
  #expect(result.document.nodes.map(\.kind.rawValue) == [
    "primitive.string",
    "primitive.string",
    "primitive.int",
    "primitive.float",
    "primitive.boolean",
    "logic.ifElse",
    "diffusion.basicScheduler",
  ])
  #expect(result.document.nodes[2].parameters["value"] == .integer(24))
  #expect(result.document.nodes[3].parameters["value"] == .number(0.75))
  #expect(result.document.nodes[4].parameters["value"] == .boolean(true))
  #expect(result.document.nodes[5].parameters["condition"] == .boolean(false))
  #expect(result.document.nodes[6].parameters["scheduler"] == .string("normal"))
  #expect(result.document.nodes[6].parameters["steps"] == .integer(20))
  #expect(result.document.connections[0].input.port == "condition")
  #expect(result.document.connections[1].input.port == "falseValue")
  #expect(result.document.connections[2].input.port == "trueValue")
  #expect(result.document.connections[3].input.port == "steps")
  #expect(result.document.connections[4].input.port == "denoise")
}

@Test func losslessImportRecognizesStandardComfyUIScalarPortTypes() throws {
  let result = try ComfyUIWorkflowConverter.convert(Data(utilityWorkflow.utf8))
  let nodes = Dictionary(uniqueKeysWithValues: result.document.nodes.map { ($0.id.rawValue, $0) })

  #expect(nodes["comfyui-node-3"]?.importedDescriptor?.output(named: "INT")?.type == .integer)
  #expect(nodes["comfyui-node-4"]?.importedDescriptor?.output(named: "FLOAT")?.type == .number)
  #expect(nodes["comfyui-node-5"]?.importedDescriptor?.output(named: "BOOLEAN")?.type == .boolean)
  #expect(nodes["comfyui-node-7"]?.importedDescriptor?.output(named: "SIGMAS")?.type == .schedule)
}

@Test func mappedImportExpandsComfyUISubgraphsAndMapsTheirModelLoaders() throws {
  let subgraphWorkflow = #"""
    {
      "nodes": [
        {
          "id": 1, "type": "LoadImage", "pos": [0, 0], "size": [180, 90],
          "inputs": [],
          "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [1]}],
          "properties": {}, "widgets_values": ["source.png", "image"]
        },
        {
          "id": 75, "type": "7b34ab90-36f9-45ba-a665-71d418f0df18",
          "pos": [240, 0], "size": [300, 180],
          "inputs": [{"name": "image", "type": "IMAGE", "link": 1}],
          "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [2]}],
          "properties": {}, "widgets_values": ["qwen_3_4b.safetensors"]
        },
        {
          "id": 9, "type": "SaveImage", "pos": [600, 0], "size": [180, 90],
          "inputs": [{"name": "images", "type": "IMAGE", "link": 2}],
          "outputs": [], "properties": {}, "widgets_values": ["result"]
        }
      ],
      "links": [
        [1, 1, 0, 75, 0, "IMAGE"],
        [2, 75, 0, 9, 0, "IMAGE"]
      ],
      "definitions": {
        "subgraphs": [{
          "id": "7b34ab90-36f9-45ba-a665-71d418f0df18",
          "name": "Image Edit (Flux.2 Klein 4B)",
          "inputs": [
            {"name": "clip_name", "type": "COMBO"},
            {"name": "image", "type": "IMAGE"}
          ],
          "outputs": [{"name": "IMAGE", "type": "IMAGE"}],
          "nodes": [
            {
              "id": 71, "type": "CLIPLoader", "pos": [0, 0], "size": [180, 90],
              "inputs": [{"name": "clip_name", "type": "COMBO", "widget": {"name": "clip_name"}}],
              "outputs": [{"name": "CLIP", "type": "CLIP", "links": []}],
              "properties": {"models": [{
                "name": "qwen_3_4b.safetensors", "directory": "text_encoders"
              }]},
              "widgets_values": ["default.safetensors", "flux2", "default"]
            },
            {
              "id": 80, "type": "ImageScaleToTotalPixels", "pos": [240, 0], "size": [180, 90],
              "inputs": [{"name": "image", "type": "IMAGE", "link": 11}],
              "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [12]}],
              "properties": {}, "widgets_values": ["nearest-exact", 1, 1]
            }
          ],
          "links": [
            {"id": 10, "origin_id": -10, "origin_slot": 0, "target_id": 71, "target_slot": 0, "type": "COMBO"},
            {"id": 11, "origin_id": -10, "origin_slot": 1, "target_id": 80, "target_slot": 0, "type": "IMAGE"},
            {"id": 12, "origin_id": 80, "origin_slot": 0, "target_id": -20, "target_slot": 0, "type": "IMAGE"}
          ]
        }]
      }
    }
    """#

  let result = try ComfyUIWorkflowConverter.convert(
    Data(subgraphWorkflow.utf8),
    options: ComfyUIConversionOptions(mapNodes: true))
  let nodes = Dictionary(uniqueKeysWithValues: result.document.nodes.map { ($0.id.rawValue, $0) })

  #expect(result.summary.sourceNodeCount == 4)
  #expect(result.summary.mappedNodeCount == 4)
  #expect(result.summary.placeholderNodeCount == 0)
  #expect(nodes["comfyui-node-75"] == nil)
  #expect(nodes["comfyui-node-75:71"]?.kind.rawValue == "coreai.textEncoderModel")
  #expect(nodes["comfyui-node-75:71"]?.parameters["modelName"]
    == .string("qwen_3_4b.safetensors"))
  #expect(nodes["comfyui-node-75:71"]?.resources["model"]?.unresolvedRequirement?.sourceName
    == "text_encoders/qwen_3_4b.safetensors")
  #expect(nodes["comfyui-node-75:80"]?.kind.rawValue == "image.scaleToTotalPixels")
  #expect(result.document.connections.contains {
    $0.output.nodeID.rawValue == "comfyui-node-1"
      && $0.input.nodeID.rawValue == "comfyui-node-75:80"
  })
  #expect(result.document.connections.contains {
    $0.output.nodeID.rawValue == "comfyui-node-75:80"
      && $0.input.nodeID.rawValue == "comfyui-node-9"
  })
}

@Test(arguments: [false, true])
func qwenImage21SubgraphPreservesPromotedWidgetValues(namedOnly: Bool) throws {
  let promoted: [(name: String, node: Int, slot: Int, value: Any)] = [
    ("prompt", 2, 0, "a portrait"), ("negative_prompt", 2, 1, "blur"),
    ("cfg", 6, 0, 1), ("steps", 6, 1, 25),
    ("width", 5, 0, 1024), ("height", 5, 1, 1024),
    ("scheduler", 6, 2, "euler"), ("scheduler_1", 6, 3, "simple"),
    ("seed", 6, 4, 593103825222985),
    ("unet_name", 1, 0, "qwen_image_2.1_int8_convrot.safetensors"),
    ("clip_name", 3, 0, "qwen3vl_8b_bf16.safetensors"),
    ("vae_name", 4, 0, "qwen_image_2.1_vae_bf16.safetensors"),
  ]
  let innerNodes = [
    comfyNode(1, "UNETLoader", inputs: [comfyPort("unet_name", "COMBO", widget: true)],
      outputs: [comfyPort("MODEL", "MODEL")],
      widgets: ["default.safetensors", "default"]),
    comfyNode(2, "TextEncodeQwenImage21",
      inputs: [comfyPort("prompt", "STRING", widget: true),
        comfyPort("negative_prompt", "STRING", widget: true), comfyPort("clip", "CLIP")],
      outputs: [comfyPort("positive", "CONDITIONING"),
        comfyPort("negative", "CONDITIONING"), comfyPort("latent", "LATENT")],
      widgets: ["", "", 1024]),
    comfyNode(3, "CLIPLoader", inputs: [comfyPort("clip_name", "COMBO", widget: true)],
      outputs: [comfyPort("CLIP", "CLIP")],
      widgets: ["default.safetensors", "qwen_image", "default"]),
    comfyNode(4, "VAELoader", inputs: [comfyPort("vae_name", "COMBO", widget: true)],
      outputs: [comfyPort("VAE", "VAE")],
      widgets: ["default.safetensors"]),
    comfyNode(5, "EmptyLatentImage",
      inputs: [comfyPort("width", "INT", widget: true),
        comfyPort("height", "INT", widget: true)],
      outputs: [comfyPort("LATENT", "LATENT")], widgets: [512, 512, 1]),
    comfyNode(6, "KSampler",
      inputs: [comfyPort("cfg", "FLOAT", widget: true),
        comfyPort("steps", "INT", widget: true),
        comfyPort("sampler_name", "COMBO", widget: true),
        comfyPort("scheduler", "COMBO", widget: true),
        comfyPort("seed", "INT", widget: true), comfyPort("model", "MODEL"),
        comfyPort("positive", "CONDITIONING"), comfyPort("negative", "CONDITIONING"),
        comfyPort("latent_image", "LATENT")],
      outputs: [comfyPort("LATENT", "LATENT")],
      widgets: [0, "fixed", 20, 8, "heun", "normal", 1]),
  ]
  var instance = comfyNode(459, "qwen-subgraph",
    // The instance exposes only some of the definition's promoted inputs.
    inputs: [comfyPort("prompt", "STRING", widget: true),
      comfyPort("width", "INT", widget: true), comfyPort("height", "INT", widget: true)],
    widgets: namedOnly ? [] : promoted.map(\.value))
  if namedOnly {
    instance["widgets_values_named"] = Dictionary(uniqueKeysWithValues: promoted.map {
      ($0.name, $0.value)
    })
  }
  let data = try JSONSerialization.data(withJSONObject: [
    "nodes": [
      comfyNode(13, "ResolutionSelector",
        outputs: [comfyPort("width", "INT"), comfyPort("height", "INT")],
        widgets: ["1:1 (Square)", 1, 8]),
      instance,
    ],
    "links": [[670, 13, 0, 459, 1, "INT"], [671, 13, 1, 459, 2, "INT"]],
    "definitions": ["subgraphs": [[
      "id": "qwen-subgraph", "name": "Qwen Image 2.1",
      "inputs": promoted.map { ["name": $0.name] }, "outputs": [], "nodes": innerNodes,
      "links": promoted.enumerated().map { index, widget in
        ["id": index, "origin_id": -10, "origin_slot": index,
          "target_id": widget.node, "target_slot": widget.slot]
      },
    ]]],
  ])
  let result = try ComfyUIWorkflowConverter.convert(
    data, options: ComfyUIConversionOptions(mapNodes: true, includeResourceGuidance: false))
  let nodes = convertedNodesBySourceID(result.document)
  #expect(result.summary.placeholderNodeCount == 0)
  #expect(nodes["comfyui-node-459:2"]?.parameters["prompt"] == .string("a portrait"))
  #expect(nodes["comfyui-node-459:2"]?.parameters["negativePrompt"] == .string("blur"))
  #expect(nodes["comfyui-node-459:6"]?.parameters["guidance"] == .integer(1))
  #expect(nodes["comfyui-node-459:6"]?.parameters["steps"] == .integer(25))
  #expect(nodes["comfyui-node-459:6"]?.parameters["sampler"] == .string("euler"))
  #expect(nodes["comfyui-node-459:6"]?.parameters["scheduler"] == .string("simple"))
  #expect(nodes["comfyui-node-459:6"]?.parameters["seed"] == .integer(593103825222985))
  #expect(nodes["comfyui-node-459:5"]?.parameters["width"] == .integer(1024))
  #expect(nodes["comfyui-node-459:5"]?.parameters["height"] == .integer(1024))
  for widget in promoted.suffix(3) {
    #expect(nodes["comfyui-node-459:\(widget.node)"]?.parameters["modelName"]
      == .string(widget.value as! String))
  }
  #expect(connectedInputPorts(result.document, node: "comfyui-node-459:5") == ["width", "height"])
}

@Test func unrecognizedPromotedWidgetDoesNotShiftLaterSubgraphValues() throws {
  let data = try JSONSerialization.data(withJSONObject: [
    "nodes": [comfyNode(1, "subgraph", widgets: ["unknown", "selected.safetensors"])],
    "links": [],
    "definitions": ["subgraphs": [[
      "id": "subgraph", "inputs": [["name": "future"], ["name": "vae_name"]],
      "outputs": [],
      "nodes": [comfyNode(2, "VAELoader",
        inputs: [comfyPort("future", "STRING", widget: true),
          comfyPort("vae_name", "COMBO", widget: true)],
        outputs: [comfyPort("VAE", "VAE")], widgets: ["default.safetensors"])],
      "links": [
        ["id": 1, "origin_id": -10, "origin_slot": 0, "target_id": 2, "target_slot": 0],
        ["id": 2, "origin_id": -10, "origin_slot": 1, "target_id": 2, "target_slot": 1],
      ],
    ]]],
  ])
  let result = try ComfyUIWorkflowConverter.convert(
    data, options: ComfyUIConversionOptions(mapNodes: true, includeResourceGuidance: false))
  #expect(result.document.nodes.first?.parameters["modelName"] == .string("selected.safetensors"))
}

@Test func projectedOutputKeepsAndEnablesOnlyTheSelectedTopLevelBranch() throws {
  let combinedWorkflow = #"""
    {
      "id": "combined-flux",
      "nodes": [
        {
          "id": 76, "type": "PrimitiveStringMultiline", "mode": 0,
          "inputs": [],
          "outputs": [{"name": "STRING", "type": "STRING", "links": [155, 157]}],
          "properties": {}, "widgets_values": ["prompt"]
        },
        {
          "id": 75, "type": "BaseBranch", "mode": 0,
          "inputs": [{"name": "text", "type": "STRING", "link": 155}],
          "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [154]}],
          "properties": {}, "widgets_values": []
        },
        {
          "id": 9, "type": "SaveImage", "mode": 0,
          "inputs": [{"name": "images", "type": "IMAGE", "link": 154}],
          "outputs": [], "properties": {}, "widgets_values": ["base"]
        },
        {
          "id": 77, "type": "distilled-subgraph", "mode": 4,
          "inputs": [{"name": "text", "type": "STRING", "link": 157}],
          "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [156]}],
          "properties": {}, "widgets_values": []
        },
        {
          "id": 78, "type": "SaveImage", "mode": 4,
          "inputs": [{"name": "images", "type": "IMAGE", "link": 156}],
          "outputs": [], "properties": {}, "widgets_values": ["distilled"]
        }
      ],
      "links": [
        [154, 75, 0, 9, 0, "IMAGE"],
        [155, 76, 0, 75, 0, "STRING"],
        [156, 77, 0, 78, 0, "IMAGE"],
        [157, 76, 0, 77, 0, "STRING"]
      ],
      "definitions": {
        "subgraphs": [{
          "id": "distilled-subgraph", "name": "Distilled",
          "inputs": [{"name": "text", "type": "STRING"}],
          "outputs": [{"name": "IMAGE", "type": "IMAGE"}],
          "nodes": [{
            "id": 1, "type": "DistilledBranch", "mode": 0,
            "inputs": [{"name": "text", "type": "STRING"}],
            "outputs": [{"name": "IMAGE", "type": "IMAGE"}],
            "properties": {}, "widgets_values": []
          }],
          "links": [
            {"id": 1, "origin_id": -10, "origin_slot": 0, "target_id": 1, "target_slot": 0, "type": "STRING"},
            {"id": 2, "origin_id": 1, "origin_slot": 0, "target_id": -20, "target_slot": 0, "type": "IMAGE"}
          ]
        }]
      }
    }
    """#

  let result = try ComfyUIWorkflowConverter.convert(
    Data(combinedWorkflow.utf8),
    options: ComfyUIConversionOptions(projectedOutputSourceNodeID: "78"))

  #expect(result.document.id.rawValue == "comfyui.combined-flux.output-78")
  #expect(
    result.document.nodes.map(\.id.rawValue) == [
      "comfyui-node-76", "comfyui-node-77:1", "comfyui-node-78",
    ])
  #expect(result.document.nodes.allSatisfy { $0.executionState == .enabled })
  #expect(result.document.primaryOutputNodeIDs == [PipelineNodeID(rawValue: "comfyui-node-78")])
  #expect(result.document.connections.count == 2)
  #expect(result.diagnostics.contains { $0.message.contains("Projected ComfyUI output 78") })
}

private func comfyPort(
  _ name: String,
  _ type: Any,
  widget: Bool = false,
  link: Int? = nil
) -> [String: Any] {
  var result: [String: Any] = ["name": name, "type": type]
  if widget { result["widget"] = ["name": name] }
  if let link { result["link"] = link }
  return result
}

private func comfyNode(
  _ id: Int,
  _ type: String,
  inputs: [[String: Any]] = [],
  outputs: [[String: Any]] = [],
  widgets: [Any] = [],
  models: [[String: Any]] = []
) -> [String: Any] {
  let properties: [String: Any] = models.isEmpty ? [:] : ["models": models]
  return [
    "id": id,
    "type": type,
    "inputs": inputs,
    "outputs": outputs,
    "widgets_values": widgets,
    "properties": properties,
  ]
}

private func convertedNodesBySourceID(
  _ document: PipelineDocument
) -> [String: PipelineNode] {
  Dictionary(
    document.nodes.map { ($0.id.rawValue, $0) },
    uniquingKeysWith: { first, _ in first })
}

private func connectedInputPorts(
  _ document: PipelineDocument,
  node id: String
) -> Set<String> {
  Set(
    document.connections
      .filter { $0.input.nodeID.rawValue == id }
      .map(\.input.port))
}

@Test func kSamplerKeepsActiveConnectedControlsAndDropsOnlyStaleDuplicates() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "PrimitiveInt", outputs: [comfyPort("INT", "INT")], widgets: [20]),
    comfyNode(2, "PrimitiveInt", outputs: [comfyPort("INT", "INT")], widgets: [4]),
    comfyNode(3, "PrimitiveFloat", outputs: [comfyPort("FLOAT", "FLOAT")], widgets: [1]),
    comfyNode(4, "KSampler",
      inputs: [
        comfyPort("model", "MODEL"), comfyPort("positive", "CONDITIONING"),
        comfyPort("negative", "CONDITIONING"), comfyPort("latent_image", "LATENT"),
        comfyPort("steps", "INT", widget: true, link: 12),
        comfyPort("cfg", "FLOAT", widget: true, link: 13),
      ],
      outputs: [comfyPort("LATENT", "LATENT")],
      widgets: [0, "fixed", 20, 1, "euler", "simple", 1]),
    comfyNode(5, "Note", widgets: ["Frontend annotation"]),
  ]
  let links: [[Any]] = [
    [11, 1, 0, 4, 4, "INT"],
    [12, 2, 0, 4, 4, "INT"],
    [13, 3, 0, 4, 5, "FLOAT"],
  ]
  let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": links])

  let result = try ComfyUIWorkflowConverter.convert(
    data,
    options: ComfyUIConversionOptions(mapNodes: true, includeResourceGuidance: false))
  let sampler = try #require(result.document.nodes.first { $0.id.rawValue == "comfyui-node-4" })
  let note = try #require(result.document.nodes.first { $0.id.rawValue == "comfyui-node-5" })
  let samplerConnections = result.document.connections.filter { $0.input.nodeID == sampler.id }

  #expect(result.summary.mappedNodeCount == nodes.count)
  #expect(result.summary.placeholderNodeCount == 0)
  #expect(samplerConnections.count == 2)
  #expect(Set(samplerConnections.map(\.input.port)) == ["steps", "guidance"])
  #expect(samplerConnections.first { $0.input.port == "steps" }?.output.nodeID.rawValue
    == "comfyui-node-2")
  #expect(note.kind.rawValue == "edit.markdownNote")
  #expect(note.parameters["text"] == .string("Frontend annotation"))
  #expect(result.diagnostics.contains { $0.message.contains("Ignored stale ComfyUI link 11") })
}

@Test func hiDreamO1WorkflowMapsEveryNodeToNativeKinds() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "CheckpointLoaderSimple",
      inputs: [comfyPort("ckpt_name", "COMBO", widget: true)],
      outputs: [comfyPort("MODEL", "MODEL"), comfyPort("CLIP", "CLIP"),
        comfyPort("VAE", "VAE")],
      widgets: ["hidream_o1_image_bf16.safetensors"],
      models: [[
        "name": "hidream_o1_image_bf16.safetensors", "directory": "checkpoints",
      ]]),
    comfyNode(2, "ModelNoiseScale",
      inputs: [comfyPort("model", "MODEL")], outputs: [comfyPort("MODEL", "MODEL")],
      widgets: [8]),
    comfyNode(3, "HiDreamO1PatchSeamSmoothing",
      inputs: [comfyPort("model", "MODEL")], outputs: [comfyPort("MODEL", "MODEL")],
      widgets: [0.8, 1, "single_shift", "ramp_2_4", "median", 1]),
    comfyNode(4, "CLIPTextEncode",
      inputs: [comfyPort("clip", "CLIP"), comfyPort("text", "STRING", widget: true)],
      outputs: [comfyPort("CONDITIONING", "CONDITIONING")], widgets: ["a portrait"]),
    comfyNode(5, "CLIPTextEncode",
      inputs: [comfyPort("clip", "CLIP"), comfyPort("text", "STRING", widget: true)],
      outputs: [comfyPort("CONDITIONING", "CONDITIONING")], widgets: [""]),
    comfyNode(6, "HiDreamO1ReferenceImages",
      inputs: [comfyPort("positive", "CONDITIONING"), comfyPort("negative", "CONDITIONING"),
        comfyPort("images.image_1", "IMAGE")],
      outputs: [comfyPort("positive", "CONDITIONING"),
        comfyPort("negative", "CONDITIONING")]),
    comfyNode(7, "EmptyHiDreamO1LatentImage",
      inputs: [comfyPort("width", "INT", widget: true),
        comfyPort("height", "INT", widget: true)],
      outputs: [comfyPort("LATENT", "LATENT")], widgets: [2048, 2048, 1]),
    comfyNode(8, "BasicScheduler",
      inputs: [comfyPort("model", "MODEL")], outputs: [comfyPort("SIGMAS", "SIGMAS")],
      widgets: ["normal", 40, 1]),
    comfyNode(9, "KSamplerSelect", outputs: [comfyPort("SAMPLER", "SAMPLER")],
      widgets: ["dpmpp_2m_sde_gpu"]),
    comfyNode(10, "SamplerLCM", outputs: [comfyPort("SAMPLER", "SAMPLER")],
      widgets: [1, 1, 2.5]),
    comfyNode(11, "SamplerCustom",
      inputs: [comfyPort("model", "MODEL"), comfyPort("positive", "CONDITIONING"),
        comfyPort("negative", "CONDITIONING"), comfyPort("sampler", "SAMPLER"),
        comfyPort("sigmas", "SIGMAS"), comfyPort("latent_image", "LATENT")],
      outputs: [comfyPort("output", "LATENT"), comfyPort("denoised_output", "LATENT")],
      widgets: [true, 4242, "randomize", 5]),
    comfyNode(12, "VAEDecode",
      inputs: [comfyPort("samples", "LATENT"), comfyPort("vae", "VAE")],
      outputs: [comfyPort("IMAGE", "IMAGE")]),
    comfyNode(13, "SaveImage", inputs: [comfyPort("images", "IMAGE")],
      widgets: ["hidream_o1"]),
    comfyNode(14, "LoadImage",
      outputs: [comfyPort("IMAGE", "IMAGE"), comfyPort("MASK", "MASK")],
      widgets: ["reference.png", "image"]),
  ]
  let links: [[Any]] = [
    [1, 1, 0, 2, 0, "MODEL"],
    [2, 2, 0, 3, 0, "MODEL"],
    [3, 3, 0, 11, 0, "MODEL"],
    [4, 1, 1, 4, 0, "CLIP"],
    [5, 1, 1, 5, 0, "CLIP"],
    [6, 4, 0, 6, 0, "CONDITIONING"],
    [7, 5, 0, 6, 1, "CONDITIONING"],
    [8, 14, 0, 6, 2, "IMAGE"],
    [9, 6, 0, 11, 1, "CONDITIONING"],
    [10, 6, 1, 11, 2, "CONDITIONING"],
    [11, 9, 0, 11, 3, "SAMPLER"],
    [12, 8, 0, 11, 4, "SIGMAS"],
    [13, 7, 0, 11, 5, "LATENT"],
    [14, 11, 0, 12, 0, "LATENT"],
    [15, 1, 2, 12, 1, "VAE"],
    [16, 12, 0, 13, 0, "IMAGE"],
    [17, 3, 0, 8, 0, "MODEL"],
  ]
  let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": links])

  let result = try ComfyUIWorkflowConverter.convert(
    data,
    options: ComfyUIConversionOptions(mapNodes: true, includeResourceGuidance: false))
  let converted = convertedNodesBySourceID(result.document)

  #expect(result.summary.mappedNodeCount == nodes.count)
  #expect(result.summary.placeholderNodeCount == 0)
  #expect(result.summary.connectionCount == links.count)
  #expect(result.summary.unresolvedResourceCount == 1)
  #expect(result.document.nodes.allSatisfy { !$0.kind.rawValue.hasPrefix("comfyui.") })
  #expect(converted["comfyui-node-1"]?.kind.rawValue == "coreai.checkpoint")
  #expect(converted["comfyui-node-2"]?.kind.rawValue == "diffusion.modelNoiseScale")
  #expect(converted["comfyui-node-3"]?.kind.rawValue == "diffusion.hiDreamO1SeamSmoothing")
  #expect(
    converted["comfyui-node-6"]?.kind.rawValue == "conditioning.hiDreamO1ReferenceImages")
  #expect(converted["comfyui-node-7"]?.kind.rawValue == "latent.emptyHiDreamO1Image")
  #expect(converted["comfyui-node-10"]?.kind.rawValue == "diffusion.lcmSampler")
  #expect(converted["comfyui-node-11"]?.kind.rawValue == "diffusion.customSampler")

  let checkpoint = try #require(converted["comfyui-node-1"])
  #expect(checkpoint.parameters["modelName"] == .string("hidream_o1_image_bf16.safetensors"))
  #expect(
    checkpoint.resources["model"]?.unresolvedRequirement?.sourceName
      == "checkpoints/hidream_o1_image_bf16.safetensors")
  #expect(converted["comfyui-node-2"]?.parameters["noiseScale"] == .integer(8))
  #expect(converted["comfyui-node-3"]?.parameters["startPercent"] == .number(0.8))
  #expect(converted["comfyui-node-3"]?.parameters["blend"] == .string("median"))
  #expect(converted["comfyui-node-7"]?.parameters["width"] == .integer(2048))
  #expect(converted["comfyui-node-7"]?.parameters["batchSize"] == .integer(1))
  #expect(converted["comfyui-node-10"]?.parameters["stepNoise"] == .integer(1))
  #expect(
    converted["comfyui-node-10"]?.parameters["noiseClipStandardDeviations"] == .number(2.5))
  #expect(converted["comfyui-node-11"]?.parameters["addNoise"] == .boolean(true))
  #expect(converted["comfyui-node-11"]?.parameters["seed"] == .integer(4242))
  #expect(converted["comfyui-node-11"]?.parameters["seedControl"] == .string("randomize"))
  #expect(converted["comfyui-node-11"]?.parameters["guidance"] == .integer(5))
  #expect(converted["comfyui-node-13"]?.parameters["filenamePrefix"] == .string("hidream_o1"))

  #expect(
    connectedInputPorts(result.document, node: "comfyui-node-6")
      == ["positive", "negative", "referenceImage1"])
  #expect(
    connectedInputPorts(result.document, node: "comfyui-node-11")
      == ["denoiser", "positive", "negative", "sampler", "schedule", "sourceLatent"])
  #expect(connectedInputPorts(result.document, node: "comfyui-node-8") == ["denoiser"])
}

@Test func qwenImage21NodesMapToNativeKinds() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "UNETLoader",
      inputs: [comfyPort("unet_name", "COMBO", widget: true)],
      outputs: [comfyPort("MODEL", "MODEL")],
      widgets: ["qwen_image_2.1_int8_convrot.safetensors", "default"],
      models: [[
        "name": "qwen_image_2.1_int8_convrot.safetensors", "directory": "diffusion_models",
      ]]),
    comfyNode(2, "CLIPLoader",
      inputs: [comfyPort("clip_name", "COMBO", widget: true)],
      outputs: [comfyPort("CLIP", "CLIP")],
      widgets: ["qwen3vl_8b_int8_convrot.safetensors", "qwen_image", "default"],
      models: [[
        "name": "qwen3vl_8b_int8_convrot.safetensors", "directory": "text_encoders",
      ]]),
    comfyNode(3, "VAELoader",
      inputs: [comfyPort("vae_name", "COMBO", widget: true)],
      outputs: [comfyPort("VAE", "VAE")],
      widgets: ["qwen_image_2.1_vae_bf16.safetensors"],
      models: [["name": "qwen_image_2.1_vae_bf16.safetensors", "directory": "vae"]]),
    comfyNode(4, "TextEncodeQwenImage21",
      inputs: [comfyPort("clip", "CLIP"), comfyPort("images.image_1", "IMAGE"),
        comfyPort("vae", "VAE"), comfyPort("prompt", "STRING", widget: true),
        comfyPort("negative_prompt", "STRING", widget: true)],
      outputs: [comfyPort("positive", "CONDITIONING"),
        comfyPort("negative", "CONDITIONING"), comfyPort("latent", "LATENT")],
      widgets: ["a greyscale portrait", "", 1024]),
    comfyNode(5, "EmptyLatentImage",
      inputs: [comfyPort("width", "INT", widget: true),
        comfyPort("height", "INT", widget: true)],
      outputs: [comfyPort("LATENT", "LATENT")], widgets: [1024, 1024, 1]),
    comfyNode(6, "KSampler",
      inputs: [comfyPort("model", "MODEL"), comfyPort("positive", "CONDITIONING"),
        comfyPort("negative", "CONDITIONING"), comfyPort("latent_image", "LATENT")],
      outputs: [comfyPort("LATENT", "LATENT")],
      widgets: [0, "fixed", 25, 1, "euler", "simple", 1]),
    comfyNode(7, "VAEDecode",
      inputs: [comfyPort("samples", "LATENT"), comfyPort("vae", "VAE")],
      outputs: [comfyPort("IMAGE", "IMAGE")]),
    comfyNode(8, "SaveImageAdvanced",
      inputs: [comfyPort("images", "IMAGE")], outputs: [comfyPort("images", "IMAGE")],
      widgets: ["Qwen_image_2.1", "png", "8-bit", "sRGB"]),
    comfyNode(9, "LoadImage",
      outputs: [comfyPort("IMAGE", "IMAGE"), comfyPort("MASK", "MASK")],
      widgets: ["reference.png", "image"]),
  ]
  let links: [[Any]] = [
    [1, 2, 0, 4, 0, "CLIP"],
    [2, 9, 0, 4, 1, "IMAGE"],
    [3, 3, 0, 4, 2, "VAE"],
    [4, 1, 0, 6, 0, "MODEL"],
    [5, 4, 0, 6, 1, "CONDITIONING"],
    [6, 4, 1, 6, 2, "CONDITIONING"],
    [7, 5, 0, 6, 3, "LATENT"],
    [8, 6, 0, 7, 0, "LATENT"],
    [9, 3, 0, 7, 1, "VAE"],
    [10, 7, 0, 8, 0, "IMAGE"],
  ]
  let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": links])

  let result = try ComfyUIWorkflowConverter.convert(
    data,
    options: ComfyUIConversionOptions(mapNodes: true, includeResourceGuidance: false))
  let converted = convertedNodesBySourceID(result.document)

  #expect(result.summary.mappedNodeCount == nodes.count)
  #expect(result.summary.placeholderNodeCount == 0)
  #expect(result.summary.connectionCount == links.count)
  #expect(converted["comfyui-node-4"]?.kind.rawValue == "conditioning.qwenImage21TextEncode")
  #expect(converted["comfyui-node-5"]?.kind.rawValue == "latent.emptyImage")
  #expect(converted["comfyui-node-8"]?.kind.rawValue == "output.image")
  #expect(
    converted["comfyui-node-4"]?.parameters["prompt"] == .string("a greyscale portrait"))
  #expect(converted["comfyui-node-4"]?.parameters["resolution"] == .integer(1024))
  #expect(
    converted["comfyui-node-8"]?.parameters["filenamePrefix"] == .string("Qwen_image_2.1"))
  #expect(converted["comfyui-node-8"]?.parameters["format"] == .string("png"))
  #expect(converted["comfyui-node-8"]?.parameters["bitDepth"] == .string("8-bit"))
  #expect(converted["comfyui-node-8"]?.parameters["colorSpace"] == .string("sRGB"))
  #expect(result.document.mode == .imageToImage)
  #expect(result.document.primaryOutputNodeIDs?.map(\.rawValue) == ["comfyui-node-8"])
  #expect(
    connectedInputPorts(result.document, node: "comfyui-node-4")
      == ["textEncoder", "vae", "referenceImage1"])
}

@Test func comfyUITextUtilityNodesMapToNativeTextKinds() throws {
  let nodes: [[String: Any]] = [
    comfyNode(1, "CLIPLoader",
      inputs: [comfyPort("clip_name", "COMBO", widget: true)],
      outputs: [comfyPort("CLIP", "CLIP")],
      widgets: ["gemma4_e4b_it_fp8_scaled.safetensors", "stable_diffusion", "default"],
      models: [[
        "name": "gemma4_e4b_it_fp8_scaled.safetensors", "directory": "text_encoders",
      ]]),
    comfyNode(2, "StringReplace",
      inputs: [comfyPort("replace", "STRING", widget: true)],
      outputs: [comfyPort("STRING", "STRING")],
      widgets: ["a {token} prompt", "{token}", "detailed"]),
    comfyNode(3, "StringConcatenate",
      inputs: [comfyPort("string_a", "STRING", widget: true),
        comfyPort("string_b", "STRING", widget: true)],
      outputs: [comfyPort("STRING", "STRING")], widgets: ["", "", " "]),
    comfyNode(4, "TextGenerate",
      inputs: [comfyPort("clip", "CLIP"), comfyPort("image", "IMAGE"),
        comfyPort("prompt", "STRING", widget: true)],
      outputs: [comfyPort("generated_text", "STRING")],
      widgets: ["", 2048, "on", 0.7, 64, 0.95, 0.05, 1.05, 0, 0, false, false]),
    comfyNode(5, "RegexReplace",
      inputs: [comfyPort("string", "STRING", widget: true)],
      outputs: [comfyPort("STRING", "STRING")],
      widgets: ["", "^```(?:json)?", "", false, false, false, 1]),
    comfyNode(6, "JsonExtractString",
      inputs: [comfyPort("json_string", "STRING", widget: true)],
      outputs: [comfyPort("STRING", "STRING")], widgets: ["", "prompt"]),
    comfyNode(7, "PreviewAny", inputs: [comfyPort("source", "*")],
      outputs: [comfyPort("STRING", "STRING")]),
  ]
  let links: [[Any]] = [
    [1, 1, 0, 4, 0, "CLIP"],
    [2, 2, 0, 3, 0, "STRING"],
    [3, 3, 0, 4, 2, "STRING"],
    [4, 4, 0, 5, 0, "STRING"],
    [5, 5, 0, 6, 0, "STRING"],
    [6, 6, 0, 7, 0, "STRING"],
  ]
  let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "links": links])

  let result = try ComfyUIWorkflowConverter.convert(
    data,
    options: ComfyUIConversionOptions(mapNodes: true, includeResourceGuidance: false))
  let converted = convertedNodesBySourceID(result.document)

  #expect(result.summary.mappedNodeCount == nodes.count - 1)
  #expect(result.summary.placeholderNodeCount == 1)
  #expect(result.summary.connectionCount == links.count)
  #expect(converted["comfyui-node-2"]?.kind.rawValue == "text.replace")
  #expect(converted["comfyui-node-3"]?.kind.rawValue == "text.concatenate")
  #expect(converted["comfyui-node-4"]?.kind.rawValue == "comfyui.TextGenerate")
  #expect(converted["comfyui-node-5"]?.kind.rawValue == "text.regexReplace")
  #expect(converted["comfyui-node-6"]?.kind.rawValue == "text.jsonExtract")
  #expect(converted["comfyui-node-7"]?.kind.rawValue == "utility.previewAny")
  #expect(converted["comfyui-node-2"]?.parameters["find"] == .string("{token}"))
  #expect(converted["comfyui-node-3"]?.parameters["delimiter"] == .string(" "))
  #expect(converted["comfyui-node-4"]?.parameters["max_length"] == .integer(2048))
  #expect(converted["comfyui-node-4"]?.parameters["sampling_mode"] == .string("on"))
  // Keep all dynamic sampling widgets with the source node.
  #expect(converted["comfyui-node-4"]?.parameters.count == 12)
  #expect(converted["comfyui-node-5"]?.parameters["count"] == .integer(1))
  #expect(converted["comfyui-node-6"]?.parameters["key"] == .string("prompt"))
  #expect(converted["comfyui-node-7"]?.parameters.isEmpty == true)
  #expect(
    connectedInputPorts(result.document, node: "comfyui-node-4")
      == ["clip", "prompt"])
}

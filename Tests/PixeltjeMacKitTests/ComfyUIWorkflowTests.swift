import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@Test func samSelectionWorkflowBindsTheObjectPromptAndPublishesOnlyTheMask() throws {
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: ComfyUIWorkflowCatalog.defaultSelectionTemplateID,
    parameters: [
      .init(nodeID: "99:75", inputName: "threshold"): .decimal(0.4)
    ],
    prompt: "red clock",
    outputSize: CanvasRecipe(width: 1024, height: 1024),
    runtimeValues: [.sourceImage: "pixeltje/source.png"])
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let source = try #require(
    (workflow["79"] as? [String: Any])?["inputs"] as? [String: Any])
  let text = try #require(
    (workflow["99:78"] as? [String: Any])?["inputs"] as? [String: Any])
  let detector = try #require(
    (workflow["99:75"] as? [String: Any])?["inputs"] as? [String: Any])
  let image = try #require(
    (workflow["112"] as? [String: Any])?["inputs"] as? [String: Any])
  let save = try #require(
    (workflow["113"] as? [String: Any])?["inputs"] as? [String: Any])
  #expect(request.mode == .selection)
  #expect(source["image"] as? String == "pixeltje/source.png")
  #expect(text["text"] as? String == "red clock")
  #expect((detector["threshold"] as? NSNumber)?.doubleValue == 0.4)
  #expect((image["mask"] as? [Any])?[0] as? String == "99:75")
  #expect((save["images"] as? [Any])?[0] as? String == "112")
  #expect(request.outputNodeIDs == ["113"])
  #expect(request.width == 1024)
  #expect(request.height == 1024)
}

@Test func samSelectionWorkflowUsesTheProvidedFrontendSubgraphForSettings() throws {
  let form = try ComfyUIWorkflowCatalog.workflowForm(
    templateID: ComfyUIWorkflowCatalog.defaultSelectionTemplateID,
    objectInfoByClass: [:])
  #expect(form.nodes.contains { $0.id == "99:75" && $0.title == "SAM3 Detect" })
  #expect(form.nodes.contains { $0.id == "99:78" })
  #expect(form.nodes.contains { $0.id == "79" })
}

@Test func zImageAPIWorkflowBindsThePromptAndGenerationSettings() throws {
  let parameters: [ComfyUIParameterAddress: ComfyUIParameterValue] = [
    .init(nodeID: "71", inputName: "text"): .string("flat lighting"),
    .init(nodeID: "68", inputName: "width"): .signedInteger(768),
    .init(nodeID: "68", inputName: "height"): .signedInteger(1024),
    .init(nodeID: "70", inputName: "seed"): .unsignedInteger(987),
    .init(nodeID: "70", inputName: "steps"): .signedInteger(12),
    .init(nodeID: "70", inputName: "cfg"): .decimal(2.5),
  ]
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "z-image",
    parameters: parameters,
    prompt: "a lighthouse in a storm")
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])

  let positive = try #require(workflow["67"] as? [String: Any])
  let positiveInputs = try #require(positive["inputs"] as? [String: Any])
  #expect(positiveInputs["text"] as? String == "a lighthouse in a storm")

  let negative = try #require(workflow["71"] as? [String: Any])
  let negativeInputs = try #require(negative["inputs"] as? [String: Any])
  #expect(negativeInputs["text"] as? String == "flat lighting")

  let latent = try #require(workflow["68"] as? [String: Any])
  let latentInputs = try #require(latent["inputs"] as? [String: Any])
  #expect(latentInputs["width"] as? Int == 768)
  #expect(latentInputs["height"] as? Int == 1024)

  let sampler = try #require(workflow["70"] as? [String: Any])
  let samplerInputs = try #require(sampler["inputs"] as? [String: Any])
  #expect((samplerInputs["seed"] as? NSNumber)?.uint64Value == 987)
  #expect(samplerInputs["steps"] as? Int == 12)
  #expect((samplerInputs["cfg"] as? NSNumber)?.doubleValue == 2.5)
  #expect(request.templateRevision.count == 64)
  #expect(request.parameters.contains {
    $0.address == ComfyUIParameterAddress(nodeID: "70", inputName: "steps")
      && $0.value == .signedInteger(12)
  })
  #expect(request.mode == .textToImage)
  #expect(request.outputNodeIDs == ["9"])
}

@Test func zImageUpscaledWorkflowPublishesTheModelUpscaledImage() throws {
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "z-image-upscaled",
    parameters: [
      .init(nodeID: "68", inputName: "width"): .signedInteger(512),
      .init(nodeID: "68", inputName: "height"): .signedInteger(512),
      .init(nodeID: "74", inputName: "scale_by"): .signedInteger(2),
    ],
    prompt: "a lighthouse in a storm")
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])

  let loaderInputs = try #require(
    (workflow["72"] as? [String: Any])?["inputs"] as? [String: Any])
  let upscaleInputs = try #require(
    (workflow["73"] as? [String: Any])?["inputs"] as? [String: Any])
  let resultScaleInputs = try #require(
    (workflow["74"] as? [String: Any])?["inputs"] as? [String: Any])
  let saveInputs = try #require(
    (workflow["9"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(loaderInputs["model_name"] as? String == "4x-ESRGAN.pth")
  #expect((upscaleInputs["image"] as? [Any])?[0] as? String == "65")
  #expect((upscaleInputs["upscale_model"] as? [Any])?[0] as? String == "72")
  #expect((resultScaleInputs["image"] as? [Any])?[0] as? String == "73")
  #expect(resultScaleInputs["upscale_method"] as? String == "lanczos")
  #expect((resultScaleInputs["scale_by"] as? NSNumber)?.doubleValue == 0.5)
  #expect((saveInputs["images"] as? [Any])?[0] as? String == "74")
  #expect(
    request.parameters.contains {
      $0.address == ComfyUIParameterAddress(nodeID: "72", inputName: "model_name")
        && $0.value == .string("4x-ESRGAN.pth")
    })
  #expect(
    request.parameters.contains {
      $0.address == ComfyUIParameterAddress(nodeID: "74", inputName: "scale_by")
        && $0.value == .signedInteger(2)
    })
  #expect(request.width == 512)
  #expect(request.height == 512)
  #expect(request.outputNodeIDs == ["9"])
  #expect(
    ComfyUIWorkflowCatalog.templates.contains {
      $0.id == "z-image-upscaled" && $0.name == "Z-Image Turbo Upscaled"
    })
}

@Test func flux2KleinTextToImageBindsNestedWorkflowRoles() throws {
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "flux2-klein-text-to-image",
    parameters: [
      .init(nodeID: "75:67", inputName: "text"): .string("blurry"),
      .init(nodeID: "75:68", inputName: "value"): .signedInteger(768),
      .init(nodeID: "75:69", inputName: "value"): .signedInteger(512),
      .init(nodeID: "75:73", inputName: "noise_seed"): .unsignedInteger(991),
      .init(nodeID: "75:62", inputName: "steps"): .signedInteger(17),
      .init(nodeID: "75:63", inputName: "cfg"): .decimal(4.5),
    ],
    prompt: "a glass greenhouse in winter")
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])

  let prompt = try #require(
    (workflow["76"] as? [String: Any])?["inputs"] as? [String: Any])
  let negative = try #require(
    (workflow["75:67"] as? [String: Any])?["inputs"] as? [String: Any])
  let width = try #require(
    (workflow["75:68"] as? [String: Any])?["inputs"] as? [String: Any])
  let height = try #require(
    (workflow["75:69"] as? [String: Any])?["inputs"] as? [String: Any])
  let noise = try #require(
    (workflow["75:73"] as? [String: Any])?["inputs"] as? [String: Any])
  let scheduler = try #require(
    (workflow["75:62"] as? [String: Any])?["inputs"] as? [String: Any])
  let guider = try #require(
    (workflow["75:63"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(prompt["value"] as? String == "a glass greenhouse in winter")
  #expect(negative["text"] as? String == "blurry")
  #expect(width["value"] as? Int == 768)
  #expect(height["value"] as? Int == 512)
  #expect((noise["noise_seed"] as? NSNumber)?.uint64Value == 991)
  #expect(scheduler["steps"] as? Int == 17)
  #expect((guider["cfg"] as? NSNumber)?.doubleValue == 4.5)
  #expect(request.mode == .textToImage)
  #expect(request.width == 768)
  #expect(request.height == 512)
  #expect(request.outputNodeIDs == ["9"])
}

@Test func flux2Klein9BBaseGeneratesWithoutASourceImage() throws {
  let templateID = "flux2-klein-text-to-image-9b-base"
  #expect(ComfyUIWorkflowCatalog.address(for: .sourceImage, templateID: templateID) == nil)
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: templateID,
    parameters: [
      .init(nodeID: "75:67", inputName: "text"): .string("blurry"),
      .init(nodeID: "75:68", inputName: "value"): .signedInteger(768),
      .init(nodeID: "75:69", inputName: "value"): .signedInteger(512),
      .init(nodeID: "75:73", inputName: "noise_seed"): .unsignedInteger(991),
      .init(nodeID: "75:62", inputName: "steps"): .signedInteger(18),
      .init(nodeID: "75:63", inputName: "cfg"): .decimal(4.5),
    ],
    prompt: "a glass greenhouse in winter")
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let model = try #require(
    (workflow["75:70"] as? [String: Any])?["inputs"] as? [String: Any])
  let textEncoder = try #require(
    (workflow["75:71"] as? [String: Any])?["inputs"] as? [String: Any])
  let prompt = try #require(
    (workflow["76"] as? [String: Any])?["inputs"] as? [String: Any])
  let classTypes = Set(workflow.values.compactMap {
    ($0 as? [String: Any])?["class_type"] as? String
  })

  #expect(model["unet_name"] as? String == "flux-2-klein-base-9b-fp8.safetensors")
  #expect(textEncoder["clip_name"] as? String == "qwen_3_8b_fp8mixed.safetensors")
  #expect(prompt["value"] as? String == "a glass greenhouse in winter")
  #expect(!classTypes.contains("LoadImage"))
  #expect(!classTypes.contains("VAEEncode"))
  #expect(!classTypes.contains("ReferenceLatent"))
  #expect(request.mode == .textToImage)
  #expect(request.width == 768)
  #expect(request.height == 512)
  #expect(request.outputNodeIDs == ["9"])
}

@Test func flux2Klein9BDistilledGeneratesWithZeroedNegativeConditioning() throws {
  let templateID = "flux2-klein-text-to-image-9b-distilled"
  #expect(ComfyUIWorkflowCatalog.address(for: .sourceImage, templateID: templateID) == nil)
  #expect(ComfyUIWorkflowCatalog.address(for: .negativePrompt, templateID: templateID) == nil)
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: templateID,
    parameters: [
      .init(nodeID: "75:68", inputName: "value"): .signedInteger(1024),
      .init(nodeID: "75:69", inputName: "value"): .signedInteger(768),
      .init(nodeID: "75:73", inputName: "noise_seed"): .unsignedInteger(456),
      .init(nodeID: "75:62", inputName: "steps"): .signedInteger(4),
      .init(nodeID: "75:63", inputName: "cfg"): .decimal(1),
    ],
    prompt: "a lighthouse on a black beach")
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let model = try #require(
    (workflow["75:70"] as? [String: Any])?["inputs"] as? [String: Any])
  let prompt = try #require(
    (workflow["76"] as? [String: Any])?["inputs"] as? [String: Any])
  let zero = try #require(
    (workflow["75:76"] as? [String: Any])?["inputs"] as? [String: Any])
  let guider = try #require(
    (workflow["75:63"] as? [String: Any])?["inputs"] as? [String: Any])
  let classTypes = Set(workflow.values.compactMap {
    ($0 as? [String: Any])?["class_type"] as? String
  })

  #expect(model["unet_name"] as? String == "flux-2-klein-9b-fp8.safetensors")
  #expect(prompt["value"] as? String == "a lighthouse on a black beach")
  #expect((zero["conditioning"] as? [Any])?.first as? String == "75:74")
  #expect((guider["negative"] as? [Any])?.first as? String == "75:76")
  #expect(!classTypes.contains("LoadImage"))
  #expect(!classTypes.contains("VAEEncode"))
  #expect(!classTypes.contains("ReferenceLatent"))
  #expect(request.mode == .textToImage)
  #expect(request.negativePrompt.isEmpty)
  #expect(request.width == 1024)
  #expect(request.height == 768)
}

@Test func flux2KleinUpscaledWorkflowPublishesTheModelUpscaledImage() throws {
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "flux2-klein-text-to-image-upscaled",
    parameters: [
      .init(nodeID: "75:68", inputName: "value"): .signedInteger(512),
      .init(nodeID: "75:69", inputName: "value"): .signedInteger(512),
      .init(nodeID: "82", inputName: "scale_by"): .signedInteger(2),
    ],
    prompt: "a glass greenhouse in winter")
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])

  let loaderInputs = try #require(
    (workflow["80"] as? [String: Any])?["inputs"] as? [String: Any])
  let upscaleInputs = try #require(
    (workflow["81"] as? [String: Any])?["inputs"] as? [String: Any])
  let resultScaleInputs = try #require(
    (workflow["82"] as? [String: Any])?["inputs"] as? [String: Any])
  let saveInputs = try #require(
    (workflow["9"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(loaderInputs["model_name"] as? String == "4x-ESRGAN.pth")
  #expect((upscaleInputs["image"] as? [Any])?[0] as? String == "75:65")
  #expect((upscaleInputs["upscale_model"] as? [Any])?[0] as? String == "80")
  #expect((resultScaleInputs["image"] as? [Any])?[0] as? String == "81")
  #expect(resultScaleInputs["upscale_method"] as? String == "lanczos")
  #expect((resultScaleInputs["scale_by"] as? NSNumber)?.doubleValue == 0.5)
  #expect((saveInputs["images"] as? [Any])?[0] as? String == "82")
  #expect(
    request.parameters.contains {
      $0.address == ComfyUIParameterAddress(nodeID: "80", inputName: "model_name")
        && $0.value == .string("4x-ESRGAN.pth")
    })
  #expect(
    request.parameters.contains {
      $0.address == ComfyUIParameterAddress(nodeID: "82", inputName: "scale_by")
        && $0.value == .signedInteger(2)
    })
  #expect(request.width == 512)
  #expect(request.height == 512)
  #expect(request.outputNodeIDs == ["9"])
  #expect(
    ComfyUIWorkflowCatalog.templates.contains {
      $0.id == "flux2-klein-text-to-image-upscaled"
        && $0.name == "FLUX.2 Klein 4B Base Upscaled"
    })
}

@Test func upscaledFrontendWorkflowsOrderUpscalingBeforeTheirPublishedOutput() throws {
  for templateID in ["z-image-upscaled", "flux2-klein-text-to-image-upscaled"] {
    let form = try ComfyUIWorkflowCatalog.workflowForm(
      templateID: templateID, objectInfoByClass: [:])
    let upscaleIndex = try #require(
      form.nodes.firstIndex(where: { $0.classType == "ImageUpscaleWithModel" }))
    let resultScaleIndex = try #require(
      form.nodes.firstIndex(where: { $0.classType == "ImageScaleBy" }))
    let outputIndex = try #require(form.nodes.firstIndex(where: { $0.id == "9" }))
    #expect(upscaleIndex < resultScaleIndex)
    #expect(resultScaleIndex < outputIndex)
  }
}

@Test func upscaledWorkflowSettingsShowTheModelPickerWithoutEmptyUpscaleNode() throws {
  let objectInfo: [String: Data] = [
    "UpscaleModelLoader": try objectInfoData(
      classType: "UpscaleModelLoader",
      required: ["model_name": [["4x-ESRGAN.pth"]]],
      order: ["model_name"]),
    "ImageUpscaleWithModel": try objectInfoData(
      classType: "ImageUpscaleWithModel",
      required: [
        "upscale_model": ["UPSCALE_MODEL"],
        "image": ["IMAGE"],
      ],
      order: ["upscale_model", "image"]),
    "ImageScaleBy": try objectInfoData(
      classType: "ImageScaleBy",
      required: [
        "image": ["IMAGE"],
        "upscale_method": [["nearest-exact", "bilinear", "area", "bicubic", "lanczos"]],
        "scale_by": ["FLOAT", ["default": 1.0, "min": 0.01, "max": 8.0, "step": 0.01]],
      ],
      order: ["image", "upscale_method", "scale_by"]),
  ]

  for templateID in ["z-image-upscaled", "flux2-klein-text-to-image-upscaled"] {
    let form = try ComfyUIWorkflowCatalog.workflowForm(
      templateID: templateID, objectInfoByClass: objectInfo)

    #expect(form.nodes.contains { $0.classType == "ImageUpscaleWithModel" })
    #expect(!form.settingsNodes.contains { $0.classType == "ImageUpscaleWithModel" })
    let loader = try #require(
      form.settingsNodes.first { $0.classType == "UpscaleModelLoader" })
    #expect(loader.parameters.map(\.address.inputName) == ["model_name"])
    #expect(loader.parameters.first?.templateValue == .string("4x-ESRGAN.pth"))
    let resultScale = try #require(
      form.settingsNodes.first { $0.classType == "ImageScaleBy" })
    #expect(resultScale.title == "Result Scale")
    #expect(resultScale.parameters.map(\.address.inputName) == ["scale_by"])
    #expect(resultScale.parameters.first?.label == "Result Scale")
    #expect(resultScale.parameters.first?.control == .integer(isUnsigned: false))
    #expect(resultScale.parameters.first?.templateValue == .signedInteger(4))
    #expect(resultScale.parameters.first?.minimum == .signedInteger(1))
    #expect(resultScale.parameters.first?.maximum == .signedInteger(4))
    #expect(resultScale.parameters.first?.step == .signedInteger(1))
  }
}

@Test func flux2KleinFrontendSubgraphKeepsAuthoredNodeOrder() throws {
  let form = try ComfyUIWorkflowCatalog.workflowForm(
    templateID: "flux2-klein-text-to-image", objectInfoByClass: [:])
  let promptIndex = try #require(form.nodes.firstIndex(where: { $0.id == "76" }))
  let samplerIndex = try #require(form.nodes.firstIndex(where: { $0.id == "75:61" }))
  let outputIndex = try #require(form.nodes.firstIndex(where: { $0.id == "9" }))

  #expect(promptIndex < samplerIndex)
  #expect(samplerIndex < outputIndex)
}

@Test func flux2Klein9BFrontendsMatchTheirOfficialGenerationBranches() throws {
  let base = try ComfyUIWorkflowCatalog.workflowForm(
    templateID: "flux2-klein-text-to-image-9b-base", objectInfoByClass: [:])
  #expect(base.nodes.contains { $0.id == "75:67" && $0.classType == "CLIPTextEncode" })
  #expect(!base.nodes.contains { $0.classType == "ConditioningZeroOut" })

  let distilled = try ComfyUIWorkflowCatalog.workflowForm(
    templateID: "flux2-klein-text-to-image-9b-distilled", objectInfoByClass: [:])
  #expect(distilled.nodes.contains {
    $0.id == "75:76" && $0.classType == "ConditioningZeroOut"
  })
  #expect(!distilled.nodes.contains { $0.id == "75:67" })
}

@Test func imageConditioningFitsTheWholeSourceInsideTheGenerationBox() {
  #expect(
    RenderEngine.imageConditioningOutputSize(
      source: CanvasRecipe(width: 6_000, height: 4_000),
      maximum: CanvasRecipe(width: 1_024, height: 1_024))
      == CanvasRecipe(width: 1_024, height: 672))
  #expect(
    RenderEngine.imageConditioningOutputSize(
      source: CanvasRecipe(width: 4_000, height: 6_000),
      maximum: CanvasRecipe(width: 1_024, height: 1_024))
      == CanvasRecipe(width: 672, height: 1_024))
  #expect(
    RenderEngine.imageConditioningOutputSize(
      source: CanvasRecipe(width: 840, height: 1_016),
      maximum: CanvasRecipe(width: 840, height: 1_016))
      == CanvasRecipe(width: 832, height: 1_008))
}

@Test func comfyUIImageConditioningResizesTheWholeCompositeAndKeepsItsPlacement() async throws {
  guard let engine = try? RenderEngine() else { return }
  let documentID = UUID()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 32)
  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 9,
      input: nil,
      recipe: recipe,
      quality: .full))
  let conditioning = ComfyUIImageConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 9,
      capture: .composite),
    transparentPixelBackground: .white)

  let preparation = try await engine.prepareComfyUIImageConditioning(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 32,
    outputHeight: 16)
  #expect(preparation.sourcePNG.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  #expect(preparation.width == 32)
  #expect(preparation.height == 16)
  #expect(preparation.placementFrame == LayerFrame(x: 0, y: 0, width: 64, height: 32))

  let result = try await engine.finishComfyUIImageConditioning(
    imageData: preparation.sourcePNG,
    preparation: preparation)
  #expect(result.raster.reference.width == 32)
  #expect(result.raster.reference.height == 16)
  #expect(result.placementFrame == preparation.placementFrame)
}

@Test func comfyUIImageConditioningSendsOnlyTheSelectedRegionAndKeepsItsPlacement() async throws {
  guard let engine = try? RenderEngine() else { return }
  let documentID = UUID()
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 32)
  let frame = try await engine.render(
    RenderRequest(
      documentID: documentID,
      revision: 0,
      contentRevision: 10,
      input: nil,
      recipe: recipe,
      quality: .full))
  let selectedRegion = LayerFrame(x: 8, y: 4, width: 16, height: 8)
  let conditioning = ComfyUIImageConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: documentID.uuidString,
      contentRevision: 10,
      capture: .composite),
    sourceRegion: selectedRegion,
    transparentPixelBackground: .white)

  let preparation = try await engine.prepareComfyUIImageConditioning(
    sourceFrame: frame,
    conditioning: conditioning,
    outputWidth: 32,
    outputHeight: 16)

  #expect(preparation.sourcePNG.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  #expect(preparation.width == 32)
  #expect(preparation.height == 16)
  #expect(preparation.placementFrame == selectedRegion)

  let result = try await engine.finishComfyUIImageConditioning(
    imageData: preparation.sourcePNG,
    preparation: preparation)
  #expect(result.raster.reference.width == 32)
  #expect(result.raster.reference.height == 16)
  #expect(result.placementFrame == selectedRegion)
}

@Test func flux2KleinImageEditBindsOnlyTheFrozenSourceUpload() throws {
  let sourceAddress = try #require(
    ComfyUIWorkflowCatalog.address(
      for: .sourceImage, templateID: "flux2-klein-image-edit-base"))
  #expect(
    ComfyUIWorkflowCatalog.address(
      for: .maskImage, templateID: "flux2-klein-image-edit-base") == nil)
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "flux2-klein-image-edit-base",
    parameters: [
      .init(nodeID: "75:67", inputName: "text"): .string("artifacts"),
      .init(nodeID: "75:73", inputName: "noise_seed"): .unsignedInteger(123),
      .init(nodeID: "75:62", inputName: "steps"): .signedInteger(12),
      .init(nodeID: "75:63", inputName: "cfg"): .decimal(3),
    ],
    prompt: "turn the room into a library",
    outputSize: CanvasRecipe(width: 768, height: 512),
    runtimeValues: [.sourceImage: "pixeltje/job/source.png [temp]"])
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let source = try #require(
    (workflow[sourceAddress.nodeID] as? [String: Any])?["inputs"] as? [String: Any])
  let size = try #require(
    (workflow["75:100"] as? [String: Any])?["inputs"] as? [String: Any])
  let encoder = try #require(
    (workflow["75:123"] as? [String: Any])?["inputs"] as? [String: Any])
  let model = try #require(
    (workflow["75:70"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(model["unet_name"] as? String == "flux-2-klein-base-4b.safetensors")
  #expect(source[sourceAddress.inputName] as? String == "pixeltje/job/source.png [temp]")
  #expect((size["image"] as? [Any])?.first as? String == "76")
  #expect((encoder["pixels"] as? [Any])?.first as? String == "76")
  #expect(workflow["75:80"] == nil)
  #expect(workflow["81"] == nil)
  #expect(request.mode == .imageToImage)
  #expect(request.width == 768)
  #expect(request.height == 512)
  #expect(!request.parameters.contains { $0.address == sourceAddress })
}

@Test func flux2Klein9BBaseEditBindsThePromptBoxAndOnlyTheFrozenSourceUpload() throws {
  let templateID = "flux2-klein-image-edit-9b-base"
  let sourceAddress = try #require(
    ComfyUIWorkflowCatalog.address(for: .sourceImage, templateID: templateID))
  #expect(ComfyUIWorkflowCatalog.address(for: .maskImage, templateID: templateID) == nil)
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: templateID,
    parameters: [
      .init(nodeID: "92:87", inputName: "text"): .string("artifacts"),
      .init(nodeID: "92:105", inputName: "noise_seed"): .unsignedInteger(789),
      .init(nodeID: "92:115", inputName: "steps"): .signedInteger(18),
      .init(nodeID: "92:114", inputName: "cfg"): .decimal(4.5),
    ],
    prompt: "turn the room into a library",
    outputSize: CanvasRecipe(width: 768, height: 512),
    runtimeValues: [.sourceImage: "pixeltje/job/source.png [temp]"])
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let source = try #require(
    (workflow[sourceAddress.nodeID] as? [String: Any])?["inputs"] as? [String: Any])
  let size = try #require(
    (workflow["92:108"] as? [String: Any])?["inputs"] as? [String: Any])
  let encoder = try #require(
    (workflow["92:112:117"] as? [String: Any])?["inputs"] as? [String: Any])
  let prompt = try #require(
    (workflow["92:113"] as? [String: Any])?["inputs"] as? [String: Any])
  let guider = try #require(
    (workflow["92:114"] as? [String: Any])?["inputs"] as? [String: Any])
  let model = try #require(
    (workflow["92:106"] as? [String: Any])?["inputs"] as? [String: Any])
  let textEncoder = try #require(
    (workflow["92:111"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(model["unet_name"] as? String == "flux-2-klein-base-9b-fp8.safetensors")
  #expect(textEncoder["clip_name"] as? String == "qwen_3_8b_fp8mixed.safetensors")
  #expect(source[sourceAddress.inputName] as? String == "pixeltje/job/source.png [temp]")
  #expect((size["image"] as? [Any])?.first as? String == "76")
  #expect((encoder["pixels"] as? [Any])?.first as? String == "76")
  #expect(prompt["text"] as? String == "turn the room into a library")
  #expect((guider["positive"] as? [Any])?.first as? String == "92:112:118")
  #expect((guider["negative"] as? [Any])?.first as? String == "92:112:116")
  #expect(workflow["81"] == nil)
  #expect(workflow["92:85"] == nil)
  #expect(workflow["92:110"] == nil)
  #expect(workflow["92:84:120"] == nil)
  #expect(request.mode == .imageToImage)
  #expect(request.width == 768)
  #expect(request.height == 512)
  #expect(request.outputNodeIDs == ["94"])
  #expect(!request.parameters.contains { $0.address == sourceAddress })
}

@Test func flux2KleinDistilledEditHasNoMisleadingNegativePromptRole() throws {
  #expect(
    ComfyUIWorkflowCatalog.address(
      for: .negativePrompt, templateID: "flux2-klein-image-edit-distilled") == nil)
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "flux2-klein-image-edit-distilled",
    parameters: [
      .init(nodeID: "75:73", inputName: "noise_seed"): .unsignedInteger(456),
      .init(nodeID: "75:62", inputName: "steps"): .signedInteger(4),
      .init(nodeID: "75:63", inputName: "cfg"): .decimal(1),
    ],
    prompt: "make the bag blue",
    outputSize: CanvasRecipe(width: 1024, height: 1024),
    runtimeValues: [.sourceImage: "pixeltje/job/source.png [temp]"])
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let model = try #require(
    (workflow["75:70"] as? [String: Any])?["inputs"] as? [String: Any])
  let prompt = try #require(
    (workflow["75:74"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(model["unet_name"] as? String == "flux-2-klein-4b.safetensors")
  #expect(prompt["text"] as? String == "make the bag blue")
  #expect(workflow["75:80"] == nil)
  #expect(workflow["81"] == nil)
  #expect(request.mode == .imageToImage)
  #expect(request.negativePrompt.isEmpty)
}

@Test func flux2Klein9BDistilledEditRepairsAndBindsTheSingleSourceGraph() throws {
  let templateID = "flux2-klein-image-edit-9b-distilled"
  let sourceAddress = try #require(
    ComfyUIWorkflowCatalog.address(for: .sourceImage, templateID: templateID))
  #expect(ComfyUIWorkflowCatalog.address(for: .negativePrompt, templateID: templateID) == nil)
  #expect(ComfyUIWorkflowCatalog.address(for: .maskImage, templateID: templateID) == nil)
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: templateID,
    parameters: [
      .init(nodeID: "75:73", inputName: "noise_seed"): .unsignedInteger(456),
      .init(nodeID: "75:62", inputName: "steps"): .signedInteger(4),
      .init(nodeID: "75:63", inputName: "cfg"): .decimal(1),
    ],
    prompt: "make the bag blue",
    outputSize: CanvasRecipe(width: 1024, height: 768),
    runtimeValues: [.sourceImage: "pixeltje/job/source.png [temp]"])
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let source = try #require(
    (workflow[sourceAddress.nodeID] as? [String: Any])?["inputs"] as? [String: Any])
  let size = try #require(
    (workflow["75:99"] as? [String: Any])?["inputs"] as? [String: Any])
  let encoder = try #require(
    (workflow["75:79:78"] as? [String: Any])?["inputs"] as? [String: Any])
  let positiveReference = try #require(
    (workflow["75:79:77"] as? [String: Any])?["inputs"] as? [String: Any])
  let negativeReference = try #require(
    (workflow["75:79:100"] as? [String: Any])?["inputs"] as? [String: Any])
  let prompt = try #require(
    (workflow["75:74"] as? [String: Any])?["inputs"] as? [String: Any])
  let model = try #require(
    (workflow["75:70"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(model["unet_name"] as? String == "flux-2-klein-9b-fp8.safetensors")
  #expect(source[sourceAddress.inputName] as? String == "pixeltje/job/source.png [temp]")
  #expect((size["image"] as? [Any])?.first as? String == "76")
  #expect((encoder["pixels"] as? [Any])?.first as? String == "76")
  #expect((encoder["vae"] as? [Any])?.first as? String == "75:72")
  #expect((positiveReference["conditioning"] as? [Any])?.first as? String == "75:74")
  #expect((negativeReference["conditioning"] as? [Any])?.first as? String == "75:82")
  #expect(prompt["text"] as? String == "make the bag blue")
  #expect(workflow["75:80"] == nil)
  #expect(workflow["121"] == nil)
  #expect(request.mode == .imageToImage)
  #expect(request.width == 1024)
  #expect(request.height == 768)
  #expect(request.outputNodeIDs == ["9"])
  #expect(request.negativePrompt.isEmpty)
  #expect(!request.parameters.contains { $0.address == sourceAddress })
}

@Test func blankInpaintPromptIsSentWithoutSubstitution() throws {
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "flux2-klein-inpaint-base",
    parameters: [:],
    prompt: "",
    outputSize: CanvasRecipe(width: 1024, height: 1024))
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let positiveInputs = try #require(
    (workflow["74"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(request.prompt.isEmpty)
  #expect(positiveInputs["text"] as? String == "")
}

@Test(arguments: ["flux2-klein-inpaint-base", "flux2-klein-inpaint-distilled"])
func flux2KleinInpaintWorkflowsUseTheSharedSourceAndMaskPath(templateID: String) throws {
  let sourceAddress = try #require(
    ComfyUIWorkflowCatalog.address(for: .sourceImage, templateID: templateID))
  let maskAddress = try #require(
    ComfyUIWorkflowCatalog.address(for: .maskImage, templateID: templateID))
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: templateID,
    parameters: [
      .init(nodeID: "73", inputName: "noise_seed"): .unsignedInteger(456),
      .init(nodeID: "62", inputName: "steps"): .signedInteger(8),
    ],
    prompt: "replace the hand with flowers",
    outputSize: CanvasRecipe(width: 768, height: 512),
    runtimeValues: [
      .sourceImage: "pixeltje/job/source.png [temp]",
      .maskImage: "pixeltje/job/mask.png [temp]",
    ])
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  func inputs(_ nodeID: String) throws -> [String: Any] {
    try #require((workflow[nodeID] as? [String: Any])?["inputs"] as? [String: Any])
  }
  func source(_ value: Any?) -> String? {
    (value as? [Any])?.first as? String
  }

  let conditioning = try inputs("78")
  let guider = try inputs("63")
  let sampler = try inputs("64")
  let reference = try inputs(templateID == "flux2-klein-inpaint-base" ? "124" : "123")

  #expect(request.mode == .inpainting)
  #expect(ComfyUIWorkflowCatalog.inpaintingImageAlignment(templateID: templateID) == 16)
  #expect(request.width == 768 && request.height == 512)
  #expect(request.outputNodeIDs == ["9"])
  #expect(try inputs(sourceAddress.nodeID)[sourceAddress.inputName] as? String
    == "pixeltje/job/source.png [temp]")
  #expect(try inputs(maskAddress.nodeID)[maskAddress.inputName] as? String
    == "pixeltje/job/mask.png [temp]")
  #expect((workflow["78"] as? [String: Any])?["class_type"] as? String
    == "InpaintModelConditioning")
  #expect(source(conditioning["pixels"]) == "76")
  #expect(source(conditioning["mask"]) == "77")
  #expect((conditioning["mask"] as? [Any])?[1] as? Int == 1)
  #expect(source(conditioning["vae"]) == "72")
  #expect(conditioning["noise_mask"] as? Bool == true)
  #expect(source(guider["positive"]) == "78")
  #expect(source(guider["negative"]) == "78")
  #expect(source(sampler["latent_image"]) == "78")
  #expect((sampler["latent_image"] as? [Any])?[1] as? Int == 2)
  #expect(source(reference["latent"]) == (templateID == "flux2-klein-inpaint-base" ? "123" : "122"))
  #expect(workflow["66"] == nil)
  #expect(request.parameters.allSatisfy {
    $0.address != sourceAddress && $0.address != maskAddress
  })
}

@Test(arguments: ["flux2-klein-inpaint-base", "flux2-klein-inpaint-distilled"])
func flux2KleinInpaintFormHidesTemporaryUploadPaths(templateID: String) throws {
  let objectInfo: [String: Data] = [
    "LoadImage": try objectInfoData(
      classType: "LoadImage",
      required: ["image": [["source.png", "mask.png"]]],
      order: ["image"]),
    "InpaintModelConditioning": try objectInfoData(
      classType: "InpaintModelConditioning",
      required: [
        "positive": ["CONDITIONING"], "negative": ["CONDITIONING"],
        "vae": ["VAE"], "pixels": ["IMAGE"], "mask": ["MASK"],
        "noise_mask": ["BOOLEAN"],
      ],
      order: ["positive", "negative", "vae", "pixels", "mask", "noise_mask"]),
  ]
  let form = try ComfyUIWorkflowCatalog.workflowForm(
    templateID: templateID, objectInfoByClass: objectInfo)
  #expect(form.nodes.first(where: { $0.id == "76" })?.parameters.isEmpty == true)
  #expect(form.nodes.first(where: { $0.id == "77" })?.parameters.isEmpty == true)
  #expect(form.nodes.first(where: { $0.id == "78" })?.parameters.map(\.address.inputName)
    == ["noise_mask"])
  #expect(form.templateValues[.init(nodeID: "76", inputName: "image")] == nil)
  #expect(form.templateValues[.init(nodeID: "77", inputName: "image")] == nil)
}

@Test func comfyUIMultipartUploadKeepsBinaryPNGAndTemporaryFields() {
  let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
  let body = ComfyUIClient.multipartBody(
    png: png,
    filename: "mask.png",
    subfolder: "pixeltje/job",
    boundary: "Boundary")

  #expect(body.range(of: png) != nil)
  let text = String(decoding: body, as: UTF8.self)
  #expect(text.contains("name=\"image\"; filename=\"mask.png\""))
  #expect(text.contains("name=\"type\"\r\n\r\ntemp"))
  #expect(text.contains("name=\"subfolder\"\r\n\r\npixeltje/job"))
  #expect(text.hasSuffix("--Boundary--\r\n"))
  #expect(
    ComfyUIUploadedImage(name: "source.png", subfolder: "pixeltje/job", type: "temp")
      .workflowValue == "pixeltje/job/source.png [temp]")
}

@MainActor @Test func newInpaintWorkflowKeepsItsNormalUseDefaults() {
  let steps = ComfyUIParameterAddress(nodeID: "62", inputName: "steps")
  let guidance = ComfyUIParameterAddress(nodeID: "63", inputName: "cfg")
  let seed = ComfyUIParameterAddress(nodeID: "73", inputName: "noise_seed")
  let form = ComfyUIWorkflowForm(
    templateID: "flux2-klein-inpaint-base",
    templateRevision: "base-revision",
    nodes: [],
    templateValues: [
      steps: .signedInteger(20),
      guidance: .decimal(5),
      seed: .unsignedInteger(42),
    ])
  let model = EditorModel()
  model.selectComfyUIWorkflow("flux2-klein-inpaint-base")

  model.setComfyUIWorkflowForm(form)

  #expect(model.comfyUIParameterValues[steps] == .signedInteger(20))
  #expect(model.comfyUIParameterValues[guidance] == .decimal(5))
  #expect(model.comfyUIParameterValues[seed] == .unsignedInteger(42))
}

@Test func workflowFormUsesLiveNodeSchemasForControlsAndRanges() throws {
  let objectInfo: [String: Data] = [
    "CLIPTextEncode": try objectInfoData(
      classType: "CLIPTextEncode",
      required: [
        "text": ["STRING", ["multiline": true, "tooltip": "The text to encode."]],
        "clip": ["CLIP"],
      ],
      order: ["text", "clip"]),
    "EmptySD3LatentImage": try objectInfoData(
      classType: "EmptySD3LatentImage",
      required: [
        "width": ["INT", ["min": 16, "max": 8192, "step": 16]],
        "height": ["INT", ["min": 16, "max": 8192, "step": 16]],
        "batch_size": ["INT", ["min": 1, "max": 64]],
      ],
      order: ["width", "height", "batch_size"]),
    "KSampler": try objectInfoData(
      classType: "KSampler",
      required: [
        "seed": ["INT", ["min": 0, "max": Int64.max]],
        "steps": ["INT", ["min": 1, "max": 10_000]],
        "cfg": ["FLOAT", ["min": 0, "max": 100, "step": 0.1]],
        "sampler_name": [["euler", "res_multistep"]],
        "scheduler": [["simple", "normal"]],
        "denoise": ["FLOAT", ["min": 0, "max": 1, "step": 0.01]],
        "model": ["MODEL"],
        "positive": ["CONDITIONING"],
        "negative": ["CONDITIONING"],
        "latent_image": ["LATENT"],
      ],
      order: [
        "seed", "steps", "cfg", "sampler_name", "scheduler", "denoise",
        "model", "positive", "negative", "latent_image",
      ]),
  ]

  let form = try ComfyUIWorkflowCatalog.workflowForm(
    templateID: "z-image", objectInfoByClass: objectInfo)
  let sampler = try #require(form.nodes.first(where: { $0.id == "70" }))
  #expect(sampler.title == "KSampler")
  #expect(sampler.parameters.map(\.address.inputName) == [
    "seed", "steps", "cfg", "sampler_name", "scheduler", "denoise",
  ])
  #expect(sampler.parameters.first(where: { $0.address.inputName == "steps" })?.maximum
    == .signedInteger(10_000))
  #expect(sampler.parameters.first(where: { $0.address.inputName == "sampler_name" })?.control
    == .choice([.string("euler"), .string("res_multistep")]))
  #expect(form.templateValues[.init(nodeID: "68", inputName: "width")]
    == .signedInteger(1024))
  #expect(form.templateValues[.init(nodeID: "70", inputName: "cfg")]
    == .decimal(1))

  let positive = try #require(form.nodes.first(where: { $0.id == "67" }))
  #expect(positive.parameters.first(where: { $0.address.inputName == "text" })?.control
    == .text(multiline: true))
  #expect(!positive.parameters.contains(where: { $0.address.inputName == "clip" }))
}

@MainActor @Test func workflowDraftNormalizesValuesAndSurvivesLegacyControlChanges() {
  let steps = ComfyUIParameterAddress(nodeID: "70", inputName: "steps")
  let width = ComfyUIParameterAddress(nodeID: "68", inputName: "width")
  let form = ComfyUIWorkflowForm(
    templateID: "z-image",
    templateRevision: "revision",
    nodes: [
      ComfyUIWorkflowNodeDefinition(
        id: "68",
        title: "Latent",
        classType: "EmptySD3LatentImage",
        order: 0,
        parameters: [
          ComfyUIParameterDefinition(
            address: width,
            label: "width",
            control: .integer(isUnsigned: false),
            templateValue: .signedInteger(1024),
            minimum: .signedInteger(16),
            maximum: .signedInteger(8192),
            step: .signedInteger(16),
            tooltip: nil,
            isAdvanced: false,
            isConnected: false)
        ]),
      ComfyUIWorkflowNodeDefinition(
        id: "70",
        title: "Sampler",
        classType: "KSampler",
        order: 1,
        parameters: [
          ComfyUIParameterDefinition(
            address: steps,
            label: "steps",
            control: .integer(isUnsigned: false),
            templateValue: .signedInteger(8),
            minimum: .signedInteger(1),
            maximum: .signedInteger(100),
            step: .signedInteger(1),
            tooltip: nil,
            isAdvanced: false,
            isConnected: false)
        ]),
    ],
    templateValues: [width: .signedInteger(1024), steps: .signedInteger(8)])
  let model = EditorModel()
  model.setComfyUIWorkflowForm(form)

  model.setComfyUIParameter(steps, value: .signedInteger(500))
  #expect(model.comfyUIParameterValues[steps] == .signedInteger(100))
  // The old compact control only displays up to 20, but changing width there
  // must not erase the richer workflow draft's sampler value.
  var legacy = model.inpaintingTool
  legacy.outputSize = CanvasRecipe(width: 768, height: 768)
  model.setInpaintingTool(legacy)
  #expect(model.comfyUIParameterValues[steps] == .signedInteger(100))
  #expect(model.comfyUIParameterValues[width] == .signedInteger(768))

  model.resetComfyUINode("70")
  #expect(model.comfyUIParameterValues[steps] == .signedInteger(8))
}

@Test func comfyUIGenerationRecipeRoundTripsOnARasterLayer() throws {
  let generation = ComfyUIGenerationRecipe(
    templateID: "z-image",
    templateRevision: "abc123",
    promptID: "server-job",
    prompt: "subject",
    negativePrompt: "artifact",
    seed: 42,
    steps: 8,
    guidance: 1,
    outputWidth: 1024,
    outputHeight: 1024,
    parameters: [
      ComfyUIParameterRecord(
        address: .init(nodeID: "70", inputName: "seed"),
        value: .unsignedInteger(42))
    ])
  let raster = RasterLayerRecipe(
    asset: RasterAssetReference(
      id: RasterAssetID(rawValue: "pixels"),
      width: 1024,
      height: 1024,
      uncompressedByteCount: 1024 * 1024 * 8),
    frame: LayerFrame(x: 0, y: 0, width: 1024, height: 1024),
    comfyUIGeneration: generation)

  let encoded = try JSONEncoder().encode(raster)
  let decoded = try JSONDecoder().decode(RasterLayerRecipe.self, from: encoded)

  #expect(decoded.comfyUIGeneration == generation)
  #expect(decoded.generation == nil)
}

@Test func comfyUIInpaintingConditioningRoundTripsWithoutTemporaryUploadPaths() throws {
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: "document", contentRevision: 19, activeLayerID: .rawBackground),
    mask: .single(
      .rectangle(
        ShapeMask(origin: VectorPoint(x: 0.2, y: 0.3), width: 0.4, height: 0.5))),
    strength: 0.7,
    maskFeatherPixels: 9,
    transparentPixelBackground: .gray,
    usesFullOutputMask: false)
  let generation = ComfyUIGenerationRecipe(
    templateID: "flux2-klein-inpaint-base",
    templateRevision: "revision",
    promptID: "server-job",
    prompt: "replace the flower",
    negativePrompt: "artifacts",
    seed: 91,
    steps: 8,
    guidance: 1,
    outputWidth: 768,
    outputHeight: 512,
    mode: .inpainting,
    inpainting: conditioning)

  let data = try JSONEncoder().encode(generation)
  let decoded = try JSONDecoder().decode(ComfyUIGenerationRecipe.self, from: data)
  let json = String(decoding: data, as: UTF8.self)

  #expect(decoded == generation)
  #expect(decoded.effectiveMode == .inpainting)
  #expect(!json.contains("source.png"))
  #expect(!json.contains("mask.png"))
}

@Test func comfyUIImageConditioningRoundTripsWithoutTemporaryUploadPaths() throws {
  let conditioning = ComfyUIImageConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: "document", contentRevision: 27, activeLayerID: .rawBackground),
    sourceRegion: LayerFrame(x: 128, y: 64, width: 512, height: 256),
    transparentPixelBackground: .white)
  let generation = ComfyUIGenerationRecipe(
    templateID: "flux2-klein-image-edit-base",
    templateRevision: "revision",
    promptID: "server-job",
    prompt: "replace the room",
    negativePrompt: "artifacts",
    seed: 91,
    steps: 20,
    guidance: 5,
    outputWidth: 768,
    outputHeight: 512,
    mode: .imageToImage,
    imageConditioning: conditioning)

  let data = try JSONEncoder().encode(generation)
  let decoded = try JSONDecoder().decode(ComfyUIGenerationRecipe.self, from: data)
  let json = String(decoding: data, as: UTF8.self)

  #expect(decoded == generation)
  #expect(decoded.effectiveMode == .imageToImage)
  #expect(decoded.imageConditioning == conditioning)
  #expect(decoded.imageConditioning?.sourceRegion == conditioning.sourceRegion)
  #expect(decoded.inpainting == nil)
  #expect(!json.contains("source.png"))
}

@Test func legacyComfyUIGenerationRecipeDecodesWithoutDynamicParameters() throws {
  let json = """
    {
      "templateID":"z-image","templateRevision":"old","promptID":"job",
      "prompt":"subject","negativePrompt":"","seed":7,"steps":8,"guidance":1,
      "outputWidth":512,"outputHeight":512
    }
    """
  let decoded = try JSONDecoder().decode(
    ComfyUIGenerationRecipe.self, from: Data(json.utf8))
  #expect(decoded.parameters.isEmpty)
  #expect(decoded.effectiveMode == .textToImage)
}

@Test func everyBundledWorkflowDownloadListMatchesItsSelectedModels() throws {
  let gatedModelsByTemplateID: [String: Set<String>] = [
    "flux2-klein-text-to-image-9b-base": [
      "diffusion_models/flux-2-klein-base-9b-fp8.safetensors",
      "text_encoders/qwen_3_8b_fp8mixed.safetensors",
      "vae/flux2-vae.safetensors",
    ],
    "flux2-klein-text-to-image-9b-distilled": [
      "diffusion_models/flux-2-klein-9b-fp8.safetensors",
      "text_encoders/qwen_3_8b_fp8mixed.safetensors",
      "vae/flux2-vae.safetensors",
    ],
    "flux2-klein-image-edit-9b-base": [
      "diffusion_models/flux-2-klein-base-9b-fp8.safetensors",
      "text_encoders/qwen_3_8b_fp8mixed.safetensors",
      "vae/flux2-vae.safetensors",
    ],
    "flux2-klein-image-edit-9b-distilled": [
      "diffusion_models/flux-2-klein-9b-fp8.safetensors",
      "text_encoders/qwen_3_8b_fp8mixed.safetensors",
      "vae/flux2-vae.safetensors",
    ],
  ]
  for template in ComfyUIWorkflowCatalog.templates {
    let request = try ComfyUIWorkflowCatalog.request(
      templateID: template.id, parameters: [:], prompt: "resource check")
    let selected = Set(try ComfyUIResourceCatalog.requiredModels(in: request.workflow)
      .map(\.relativePath))
    if let expected = gatedModelsByTemplateID[template.id] {
      #expect(selected == expected)
      #expect(throws: PixeltjeMacError.self) {
        try ComfyUIResourceCatalog.downloadableResources(templateID: template.id)
      }
      continue
    }
    let downloadable = try ComfyUIResourceCatalog.downloadableResources(
      templateID: template.id)
    #expect(selected == Set(downloadable.keys), "Resource list differs for \(template.id)")
    #expect(downloadable.values.allSatisfy { !$0.sizeLabel.isEmpty })
  }
}

@Test func customModelSelectionIsDistinctFromTheBundledDownloadList() throws {
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "flux2-klein-inpaint-base",
    parameters: [
      .init(nodeID: "70", inputName: "unet_name"): .string("my-model.safetensors")
    ],
    prompt: "resource check")
  let selected = Set(try ComfyUIResourceCatalog.requiredModels(in: request.workflow)
    .map(\.relativePath))
  let downloadable = try ComfyUIResourceCatalog.downloadableResources(
    templateID: request.templateID)
  #expect(selected.contains("diffusion_models/my-model.safetensors"))
  #expect(selected != Set(downloadable.keys))
}

@Test func upscaledModelPreflightUsesTheServerModelInventory() async throws {
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: "z-image-upscaled", parameters: [:], prompt: "resource check")
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ComfyUIModelInventoryURLProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }

  let installed = ComfyUIClient(
    baseURL: URL(string: "http://installed.example")!, session: session)
  #expect(try await installed.missingModels(in: request).isEmpty)

  let missing = ComfyUIClient(
    baseURL: URL(string: "http://missing.example")!, session: session)
  let unavailable = try await missing.missingModels(in: request)
  #expect(unavailable.map(\.relativePath) == ["upscale_models/4x-ESRGAN.pth"])

  let unknown = ComfyUIClient(
    baseURL: URL(string: "http://unavailable.example")!, session: session)
  #expect(try await unknown.missingModels(in: request).isEmpty)
}

@Test func concurrentLocalCancellationsRemainPromptScoped() async {
  let host = "prompt-cancel.example"
  ComfyUICancellationURLProtocol.clear(host: host)
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ComfyUICancellationURLProtocol.self]
  let firstSession = URLSession(configuration: configuration)
  let secondSession = URLSession(configuration: configuration)
  defer {
    firstSession.invalidateAndCancel()
    secondSession.invalidateAndCancel()
  }
  let first = ComfyUIClient(
    baseURL: URL(string: "http://\(host)")!, session: firstSession)
  let second = ComfyUIClient(
    baseURL: URL(string: "http://\(host)")!, session: secondSession)

  async let firstCancellation: Void = first.cancel(promptID: "document-a")
  async let secondCancellation: Void = second.cancel(promptID: "document-b")
  _ = await (firstCancellation, secondCancellation)

  let requests = ComfyUICancellationURLProtocol.requests(host: host)
  #expect(requests.count == 2)
  #expect(Set(requests.map(\.path)) == [
    "/api/jobs/document-a/cancel",
    "/api/jobs/document-b/cancel",
  ])
  #expect(requests.allSatisfy { $0.method == "POST" })
  #expect(requests.allSatisfy { !$0.path.contains("interrupt") })
}

@Test func legacyLocalCancellationNeverUsesProcessWideInterrupt() async throws {
  let host = "legacy-cancel.example"
  ComfyUICancellationURLProtocol.clear(host: host)
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ComfyUICancellationURLProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  let client = ComfyUIClient(
    baseURL: URL(string: "http://\(host)")!, session: session)

  await client.cancel(promptID: "legacy-document")

  let requests = ComfyUICancellationURLProtocol.requests(host: host)
  #expect(requests.map(\.path) == [
    "/api/jobs/legacy-document/cancel",
    "/queue",
  ])
  #expect(requests.allSatisfy { !$0.path.contains("interrupt") })
  let queueRequest = try #require(requests.last)
  let body = try #require(queueRequest.body)
  let json = try #require(
    JSONSerialization.jsonObject(with: body) as? [String: Any])
  #expect(json["delete"] as? [String] == ["legacy-document"])
}

private struct CapturedComfyUICancellationRequest: Sendable {
  var host: String
  var method: String
  var path: String
  var body: Data?
}

private final class ComfyUICancellationURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var capturedRequests:
    [CapturedComfyUICancellationRequest] = []

  static func clear(host: String) {
    lock.withLock {
      capturedRequests.removeAll { $0.host == host }
    }
  }

  static func requests(host: String) -> [CapturedComfyUICancellationRequest] {
    lock.withLock {
      capturedRequests.filter { $0.host == host }
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let host = url.host else { return }
    Self.lock.withLock {
      Self.capturedRequests.append(
        CapturedComfyUICancellationRequest(
          host: host,
          method: request.httpMethod ?? "GET",
          path: url.path,
          body: comfyUIRequestBodyData(request)))
    }

    let statusCode: Int
    if host == "prompt-cancel.example",
      url.path.hasPrefix("/api/jobs/"), url.path.hasSuffix("/cancel")
    {
      statusCode = 200
    } else if host == "legacy-cancel.example",
      url.path == "/api/jobs/legacy-document/cancel"
    {
      statusCode = 404
    } else if host == "legacy-cancel.example", url.path == "/queue" {
      statusCode = 200
    } else {
      statusCode = 500
    }

    let response = HTTPURLResponse(
      url: url, statusCode: statusCode, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    let data = try! JSONSerialization.data(withJSONObject: ["ok": statusCode < 300])
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func comfyUIRequestBodyData(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
  while true {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { return nil }
    if count == 0 { return data }
    data.append(buffer, count: count)
  }
}

private final class ComfyUIModelInventoryURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    if url.host == "unavailable.example", url.path == "/models/upscale_models" {
      let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    let names: [String]
    switch url.path {
    case "/models/diffusion_models": names = ["z_image_turbo_bf16.safetensors"]
    case "/models/text_encoders": names = ["qwen_3_4b.safetensors"]
    case "/models/vae": names = ["ae.safetensors"]
    case "/models/upscale_models":
      names = url.host == "installed.example" ? ["4x-ESRGAN.pth"] : []
    default:
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(names))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func objectInfoData(
  classType: String,
  required: [String: Any],
  order: [String]
) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    classType: [
      "input": ["required": required],
      "input_order": ["required": order],
    ]
  ])
}

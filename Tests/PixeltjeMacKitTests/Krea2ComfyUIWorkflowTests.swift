import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@Test func krea2TurboWorkflowBindsPromptAndSamplingRoles() throws {
  let templateID = "krea2-turbo-text-to-image"
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: templateID,
    parameters: [
      .init(nodeID: "30:3", inputName: "seed"): .unsignedInteger(912),
      .init(nodeID: "30:3", inputName: "steps"): .signedInteger(6),
      .init(nodeID: "30:3", inputName: "cfg"): .decimal(1.25),
      .init(nodeID: "49", inputName: "aspect_ratio"): .string("3:2 (Landscape)"),
    ],
    prompt: "a glass observatory above the clouds")
  let workflow = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let prompt = try #require(
    (workflow["30:19"] as? [String: Any])?["inputs"] as? [String: Any])
  let sampler = try #require(
    (workflow["30:3"] as? [String: Any])?["inputs"] as? [String: Any])
  let resolution = try #require(
    (workflow["49"] as? [String: Any])?["inputs"] as? [String: Any])

  #expect(prompt["value"] as? String == "a glass observatory above the clouds")
  #expect((sampler["seed"] as? NSNumber)?.uint64Value == 912)
  #expect(sampler["steps"] as? Int == 6)
  #expect((sampler["cfg"] as? NSNumber)?.doubleValue == 1.25)
  #expect(resolution["aspect_ratio"] as? String == "3:2 (Landscape)")
  #expect(request.mode == .textToImage)
  #expect(request.outputNodeIDs == ["29"])
  #expect(request.templateRevision.count == 64)
  #expect(
    ComfyUIWorkflowCatalog.address(for: .prompt, templateID: templateID)
      == ComfyUIParameterAddress(nodeID: "30:19", inputName: "value"))
  #expect(ComfyUIWorkflowCatalog.address(for: .width, templateID: templateID) == nil)
  #expect(ComfyUIWorkflowCatalog.address(for: .height, templateID: templateID) == nil)
  #expect(
    ComfyUIWorkflowCatalog.templates.contains {
      $0.id == templateID && $0.name == "Krea-2 Turbo" && $0.mode == .textToImage
    })
}

@Test func krea2TurboFrontendDescribesItsNestedPromptAndSampler() throws {
  let form = try ComfyUIWorkflowCatalog.workflowForm(
    templateID: "krea2-turbo-text-to-image",
    objectInfoByClass: [
      "PrimitiveStringMultiline": try krea2ObjectInfo(
        classType: "PrimitiveStringMultiline",
        required: [
          "value": ["STRING", ["multiline": true]]
        ],
        order: ["value"]),
      "KSampler": try krea2ObjectInfo(
        classType: "KSampler",
        required: [
          "seed": ["INT", ["min": 0, "max": Int64.max]],
          "steps": ["INT", ["min": 1, "max": 100]],
          "cfg": ["FLOAT", ["min": 0, "max": 100, "step": 0.1]],
        ],
        order: ["seed", "steps", "cfg"]),
    ])

  #expect(
    form.nodes.contains {
      $0.id == "30:19" && $0.title == "Text String (User Prompt)"
    })
  let sampler = try #require(form.nodes.first { $0.id == "30:3" })
  #expect(sampler.classType == "KSampler")
  #expect(sampler.parameters.map(\.address.inputName) == ["seed", "steps", "cfg"])
  #expect(sampler.parameters.first?.control == .integer(isUnsigned: true))
}

@Test func krea2TurboDownloadListMatchesItsRequiredModels() throws {
  let templateID = "krea2-turbo-text-to-image"
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: templateID, parameters: [:], prompt: "resource check")
  let selected = Set(
    try ComfyUIResourceCatalog.requiredModels(in: request.workflow)
      .map(\.relativePath))
  let downloadable = try ComfyUIResourceCatalog.downloadableResources(
    templateID: templateID)

  #expect(
    selected == [
      "diffusion_models/krea2_turbo_fp8_scaled.safetensors",
      "text_encoders/qwen3vl_4b_fp8_scaled.safetensors",
      "vae/qwen_image_vae.safetensors",
    ])
  #expect(selected == Set(downloadable.keys))
}

private func krea2ObjectInfo(
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

import CryptoKit
import Foundation
import PixeltjeMacDomain

struct ComfyUIWorkflowRequest: Sendable {
  var templateID: String
  var mode: GenerationMode
  var workflow: Data
  var templateRevision: String
  var prompt: String
  var negativePrompt: String
  var seed: UInt64
  var steps: Int
  var guidance: Double
  var width: Int
  var height: Int
  var outputNodeIDs: [String]
  var parameters: [ComfyUIParameterRecord]
}

/// One immutable workflow package captured before asynchronous preparation or
/// upload begins. User-installed files can be removed from Settings while a
/// job is running; the job must continue with the exact bytes and bindings it
/// validated at preflight.
struct ComfyUIResolvedWorkflow: Sendable {
  var template: ComfyUIWorkflowTemplate
  var apiData: Data
  var frontendData: Data?
  var roles: [ComfyUIWorkflowRole: ComfyUIParameterAddress]
  var runtimeRoles: [ComfyUIWorkflowRuntimeRole: ComfyUIParameterAddress]
  var outputNodeIDs: [String]
  var imageAlignment: Int
  var resultScaleAddress: ComfyUIParameterAddress?
  var resultScaleNativeValue: Int?
}

enum ComfyUIWorkflowRole: CaseIterable, Hashable, Sendable {
  case prompt
  case negativePrompt
  case seed
  case steps
  case guidance
  case width
  case height
  case strength
}

enum ComfyUIWorkflowRuntimeRole: CaseIterable, Hashable, Sendable {
  case sourceImage
  case maskImage

  var label: String {
    switch self {
    case .sourceImage: "source image"
    case .maskImage: "mask image"
    }
  }
}

enum ComfyUIRuntimeValue: Sendable, ExpressibleByStringLiteral {
  case path(String)
  case cloudAsset(id: String, hash: String?, filePath: String)

  init(stringLiteral value: String) { self = .path(value) }

  var isValid: Bool {
    switch self {
    case .path(let path): !path.isEmpty
    case .cloudAsset(let id, _, _): UUID(uuidString: id) != nil
    }
  }

  var jsonObject: Any {
    switch self {
    case .path(let path): return path
    case .cloudAsset(let id, let hash, let filePath):
      var info: [String: String] = ["id": id, "file_path": filePath]
      if let hash { info["hash"] = hash }
      return ["__type": "core/ASSET", "info": info]
    }
  }

  var debugDescription: String {
    switch self {
    case .path(let path): path
    case .cloudAsset(let id, _, _): "Cloud asset \(id)"
    }
  }
}

enum ComfyUIWorkflowCatalog {
  static var workflowBundle: Bundle {
    if let resourcesURL = Bundle.main.resourceURL,
      let bundled = Bundle(
        url: resourcesURL.appendingPathComponent("PixeltjeMacApp_PixeltjeMacKit.bundle"))
    {
      return bundled
    }
    return Bundle.module
  }

  static let modes: [GenerationMode] = [
    .textToImage, .imageToImage, .inpainting, .selection,
  ]

  static let bundledTemplates = [
    ComfyUIWorkflowTemplate(id: "z-image", name: "Z-Image Turbo", mode: .textToImage),
    ComfyUIWorkflowTemplate(
      id: "z-image-upscaled", name: "Z-Image Turbo Upscaled", mode: .textToImage),
    ComfyUIWorkflowTemplate(
      id: "krea2-turbo-text-to-image", name: "Krea-2 Turbo", mode: .textToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-text-to-image", name: "FLUX.2 Klein 4B Base", mode: .textToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-text-to-image-upscaled", name: "FLUX.2 Klein 4B Base Upscaled",
      mode: .textToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-text-to-image-9b-base", name: "FLUX.2 Klein 9B Base",
      mode: .textToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-text-to-image-9b-distilled", name: "FLUX.2 Klein 9B Distilled",
      mode: .textToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-image-edit-base", name: "FLUX.2 Klein 4B Base Edit (no mask)",
      mode: .imageToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-image-edit-9b-base", name: "FLUX.2 Klein 9B Base Edit (no mask)",
      mode: .imageToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-image-edit-distilled", name: "FLUX.2 Klein 4B Distilled Edit (no mask)",
      mode: .imageToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-image-edit-9b-distilled",
      name: "FLUX.2 Klein 9B Distilled Edit (no mask)",
      mode: .imageToImage),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-inpaint-base", name: "FLUX.2 Klein 4B Base Inpaint (selection mask)",
      mode: .inpainting),
    ComfyUIWorkflowTemplate(
      id: "flux2-klein-inpaint-distilled",
      name: "FLUX.2 Klein 4B Distilled Inpaint (selection mask)",
      mode: .inpainting),
    ComfyUIWorkflowTemplate(
      id: "sam3-selection", name: "SAM 3.1 Select Object", mode: .selection),
  ]
  static var templates: [ComfyUIWorkflowTemplate] {
    bundledTemplates + ComfyUIWorkflowLibrary.shared.customTemplatesSnapshot()
  }
  static let defaultTemplateID = "z-image"
  static let defaultEditingTemplateID = "flux2-klein-image-edit-base"
  static let defaultInpaintingTemplateID = "flux2-klein-inpaint-base"
  static let defaultSelectionTemplateID = "sam3-selection"

  static func fallbackTemplateID(for mode: GenerationMode) -> String {
    switch mode {
    case .textToImage: defaultTemplateID
    case .imageToImage: defaultEditingTemplateID
    case .inpainting: defaultInpaintingTemplateID
    case .selection: defaultSelectionTemplateID
    }
  }

  private struct TemplateResources {
    var apiName: String
    var frontendName: String
    var roles: [ComfyUIWorkflowRole: ComfyUIParameterAddress]
    var runtimeRoles: [ComfyUIWorkflowRuntimeRole: ComfyUIParameterAddress]
    var outputNodeIDs: [String]
    var resultScale: ResultScaleBinding? = nil
    var imageAlignment = 8
  }

  private struct ResultScaleBinding {
    var address: ComfyUIParameterAddress
    var nativeScale: Int
  }

  private struct NodePresentation {
    var title: String?
    var order: Int
    var inputLabels: [String: String]
  }

  private struct InputSchema {
    var name: String
    var type: String
    var options: [ComfyUIParameterValue]
    var details: [String: Any]
  }

  private static let bundledResources: [String: TemplateResources] = [
    "sam3-selection": TemplateResources(
      apiName: "sam3-selection-api",
      frontendName: "sam3-selection",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "99:78", inputName: "text")
      ],
      runtimeRoles: [
        .sourceImage: ComfyUIParameterAddress(nodeID: "79", inputName: "image")
      ],
      outputNodeIDs: ["113"]),
    "z-image": TemplateResources(
      apiName: "z-image-api",
      frontendName: "z-image",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "67", inputName: "text"),
        .negativePrompt: ComfyUIParameterAddress(nodeID: "71", inputName: "text"),
        .width: ComfyUIParameterAddress(nodeID: "68", inputName: "width"),
        .height: ComfyUIParameterAddress(nodeID: "68", inputName: "height"),
        .seed: ComfyUIParameterAddress(nodeID: "70", inputName: "seed"),
        .steps: ComfyUIParameterAddress(nodeID: "70", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "70", inputName: "cfg"),
      ],
      runtimeRoles: [:],
      outputNodeIDs: ["9"]),
    "z-image-upscaled": TemplateResources(
      apiName: "z-image-upscaled-api",
      frontendName: "z-image-upscaled",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "67", inputName: "text"),
        .negativePrompt: ComfyUIParameterAddress(nodeID: "71", inputName: "text"),
        .width: ComfyUIParameterAddress(nodeID: "68", inputName: "width"),
        .height: ComfyUIParameterAddress(nodeID: "68", inputName: "height"),
        .seed: ComfyUIParameterAddress(nodeID: "70", inputName: "seed"),
        .steps: ComfyUIParameterAddress(nodeID: "70", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "70", inputName: "cfg"),
      ],
      runtimeRoles: [:],
      outputNodeIDs: ["9"],
      resultScale: ResultScaleBinding(
        address: ComfyUIParameterAddress(nodeID: "74", inputName: "scale_by"),
        nativeScale: 4)),
    "krea2-turbo-text-to-image": TemplateResources(
      apiName: "image_krea2_turbo_t2i-api",
      frontendName: "image_krea2_turbo_t2i",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "30:19", inputName: "value"),
        .seed: ComfyUIParameterAddress(nodeID: "30:3", inputName: "seed"),
        .steps: ComfyUIParameterAddress(nodeID: "30:3", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "30:3", inputName: "cfg"),
      ],
      runtimeRoles: [:],
      outputNodeIDs: ["29"]),
    "flux2-klein-text-to-image": TemplateResources(
      apiName: "flux2-klein-text-to-image-api",
      frontendName: "flux2-klein-text-to-image",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "76", inputName: "value"),
        .negativePrompt: ComfyUIParameterAddress(nodeID: "75:67", inputName: "text"),
        .width: ComfyUIParameterAddress(nodeID: "75:68", inputName: "value"),
        .height: ComfyUIParameterAddress(nodeID: "75:69", inputName: "value"),
        .seed: ComfyUIParameterAddress(nodeID: "75:73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "75:62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "75:63", inputName: "cfg"),
      ],
      runtimeRoles: [:],
      outputNodeIDs: ["9"]),
    "flux2-klein-text-to-image-upscaled": TemplateResources(
      apiName: "flux2-klein-text-to-image-upscaled-api",
      frontendName: "flux2-klein-text-to-image-upscaled",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "76", inputName: "value"),
        .negativePrompt: ComfyUIParameterAddress(nodeID: "75:67", inputName: "text"),
        .width: ComfyUIParameterAddress(nodeID: "75:68", inputName: "value"),
        .height: ComfyUIParameterAddress(nodeID: "75:69", inputName: "value"),
        .seed: ComfyUIParameterAddress(nodeID: "75:73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "75:62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "75:63", inputName: "cfg"),
      ],
      runtimeRoles: [:],
      outputNodeIDs: ["9"],
      resultScale: ResultScaleBinding(
        address: ComfyUIParameterAddress(nodeID: "82", inputName: "scale_by"),
        nativeScale: 4)),
    "flux2-klein-text-to-image-9b-base": TemplateResources(
      apiName: "image_flux2_klein_text_to_image_9b_base_api",
      frontendName: "image_flux2_klein_text_to_image_9b_base",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "76", inputName: "value"),
        .negativePrompt: ComfyUIParameterAddress(nodeID: "75:67", inputName: "text"),
        .width: ComfyUIParameterAddress(nodeID: "75:68", inputName: "value"),
        .height: ComfyUIParameterAddress(nodeID: "75:69", inputName: "value"),
        .seed: ComfyUIParameterAddress(nodeID: "75:73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "75:62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "75:63", inputName: "cfg"),
      ],
      runtimeRoles: [:],
      outputNodeIDs: ["9"]),
    "flux2-klein-text-to-image-9b-distilled": TemplateResources(
      apiName: "image_flux2_klein_text_to_image_9b_distilled_api",
      frontendName: "image_flux2_klein_text_to_image_9b_distilled",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "76", inputName: "value"),
        .width: ComfyUIParameterAddress(nodeID: "75:68", inputName: "value"),
        .height: ComfyUIParameterAddress(nodeID: "75:69", inputName: "value"),
        .seed: ComfyUIParameterAddress(nodeID: "75:73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "75:62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "75:63", inputName: "cfg"),
      ],
      runtimeRoles: [:],
      outputNodeIDs: ["9"]),
    "flux2-klein-image-edit-base": TemplateResources(
      apiName: "flux2-klein-image-edit-base-api",
      frontendName: "flux2-klein-image-edit-base",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "75:74", inputName: "text"),
        .negativePrompt: ComfyUIParameterAddress(nodeID: "75:67", inputName: "text"),
        .seed: ComfyUIParameterAddress(nodeID: "75:73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "75:62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "75:63", inputName: "cfg"),
      ],
      runtimeRoles: [
        .sourceImage: ComfyUIParameterAddress(nodeID: "76", inputName: "image")
      ],
      outputNodeIDs: ["9"]),
    "flux2-klein-image-edit-9b-base": TemplateResources(
      apiName: "image_flux2_klein_image_edit_9b_base_api",
      frontendName: "image_flux2_klein_image_edit_9b_base",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "92:113", inputName: "text"),
        .negativePrompt: ComfyUIParameterAddress(nodeID: "92:87", inputName: "text"),
        .seed: ComfyUIParameterAddress(nodeID: "92:105", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "92:115", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "92:114", inputName: "cfg"),
      ],
      runtimeRoles: [
        .sourceImage: ComfyUIParameterAddress(nodeID: "76", inputName: "image")
      ],
      outputNodeIDs: ["94"]),
    "flux2-klein-image-edit-distilled": TemplateResources(
      apiName: "flux2-klein-image-edit-distilled-api",
      frontendName: "flux2-klein-image-edit-distilled",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "75:74", inputName: "text"),
        .seed: ComfyUIParameterAddress(nodeID: "75:73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "75:62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "75:63", inputName: "cfg"),
      ],
      runtimeRoles: [
        .sourceImage: ComfyUIParameterAddress(nodeID: "76", inputName: "image")
      ],
      outputNodeIDs: ["9"]),
    "flux2-klein-image-edit-9b-distilled": TemplateResources(
      apiName: "image_flux2_klein_image_edit_9b_distilled_api",
      frontendName: "image_flux2_klein_image_edit_9b_distilled",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "75:74", inputName: "text"),
        .seed: ComfyUIParameterAddress(nodeID: "75:73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "75:62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "75:63", inputName: "cfg"),
      ],
      runtimeRoles: [
        .sourceImage: ComfyUIParameterAddress(nodeID: "76", inputName: "image")
      ],
      outputNodeIDs: ["9"]),
    "flux2-klein-inpaint-base": TemplateResources(
      apiName: "flux2-klein-inpaint-base-api",
      frontendName: "flux2-klein-inpaint-base",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "74", inputName: "text"),
        .negativePrompt: ComfyUIParameterAddress(nodeID: "67", inputName: "text"),
        .seed: ComfyUIParameterAddress(nodeID: "73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "63", inputName: "cfg"),
      ],
      runtimeRoles: [
        .sourceImage: ComfyUIParameterAddress(nodeID: "76", inputName: "image"),
        .maskImage: ComfyUIParameterAddress(nodeID: "77", inputName: "image"),
      ],
      outputNodeIDs: ["9"],
      imageAlignment: 16),
    "flux2-klein-inpaint-distilled": TemplateResources(
      apiName: "flux2-klein-inpaint-distilled-api",
      frontendName: "flux2-klein-inpaint-distilled",
      roles: [
        .prompt: ComfyUIParameterAddress(nodeID: "74", inputName: "text"),
        .seed: ComfyUIParameterAddress(nodeID: "73", inputName: "noise_seed"),
        .steps: ComfyUIParameterAddress(nodeID: "62", inputName: "steps"),
        .guidance: ComfyUIParameterAddress(nodeID: "63", inputName: "cfg"),
      ],
      runtimeRoles: [
        .sourceImage: ComfyUIParameterAddress(nodeID: "76", inputName: "image"),
        .maskImage: ComfyUIParameterAddress(nodeID: "77", inputName: "image"),
      ],
      outputNodeIDs: ["9"],
      imageAlignment: 16),
  ]

  static func mode(templateID: String) -> GenerationMode? {
    templates.first(where: { $0.id == templateID })?.mode
  }

  static func inpaintingImageAlignment(templateID: String) -> Int {
    templateResources(templateID: templateID)?.imageAlignment ?? 8
  }

  static func address(for role: ComfyUIWorkflowRole, templateID: String)
    -> ComfyUIParameterAddress?
  {
    templateResources(templateID: templateID)?.roles[role]
  }

  static func address(for role: ComfyUIWorkflowRuntimeRole, templateID: String)
    -> ComfyUIParameterAddress?
  {
    templateResources(templateID: templateID)?.runtimeRoles[role]
  }

  static func resolve(templateID: String) throws -> ComfyUIResolvedWorkflow {
    if bundledResources[templateID] == nil {
      return try ComfyUIWorkflowLibrary.shared.resolvedWorkflow(for: templateID)
    }
    guard let template = templates.first(where: { $0.id == templateID }),
      let resource = templateResources(templateID: templateID)
    else {
      throw PixeltjeMacError(
        "Workflow unavailable", "The selected ComfyUI workflow is not installed.")
    }
    let apiData = try apiData(templateID: templateID)
    let frontendData = try optionalFrontendData(templateID: templateID)
    return ComfyUIResolvedWorkflow(
      template: template,
      apiData: apiData,
      frontendData: frontendData,
      roles: resource.roles,
      runtimeRoles: resource.runtimeRoles,
      outputNodeIDs: resource.outputNodeIDs,
      imageAlignment: resource.imageAlignment,
      resultScaleAddress: resource.resultScale?.address,
      resultScaleNativeValue: resource.resultScale?.nativeScale)
  }

  static func nodeClassTypes(templateID: String) throws -> [String] {
    try nodeClassTypes(in: resolve(templateID: templateID))
  }

  static func nodeClassTypes(in resolved: ComfyUIResolvedWorkflow) throws -> [String] {
    let workflow = try apiWorkflow(from: resolved.apiData)
    return Array(
      Set(workflow.values.compactMap { ($0 as? [String: Any])?["class_type"] as? String })
    ).sorted()
  }

  /// Combines the API template's current values with the selected server's
  /// live node schemas. The server is authoritative for installed custom nodes,
  /// model choices, numeric ranges, and widget capabilities.
  static func workflowForm(
    templateID: String,
    objectInfoByClass: [String: Data]
  ) throws -> ComfyUIWorkflowForm {
    try workflowForm(
      resolved: resolve(templateID: templateID), objectInfoByClass: objectInfoByClass)
  }

  static func workflowForm(
    resolved: ComfyUIResolvedWorkflow,
    objectInfoByClass: [String: Data]
  ) throws -> ComfyUIWorkflowForm {
    let templateID = resolved.template.id
    let templateData = resolved.apiData
    let workflow = try apiWorkflow(from: templateData)
    let presentation = try frontendPresentation(resolved: resolved)
    let runtimeAddresses = Set(resolved.runtimeRoles.values)
    let resultScale = resultScaleBinding(in: resolved)
    var definitionsByClass: [String: [InputSchema]] = [:]
    for (classType, data) in objectInfoByClass {
      definitionsByClass[classType] = try inputSchemas(classType: classType, data: data)
    }

    var nodes: [ComfyUIWorkflowNodeDefinition] = []
    var templateValues: [ComfyUIParameterAddress: ComfyUIParameterValue] = [:]
    for nodeID in workflow.keys.sorted(by: compareNodeIDs) {
      guard let node = workflow[nodeID] as? [String: Any],
        let classType = node["class_type"] as? String,
        let inputs = node["inputs"] as? [String: Any]
      else { continue }

      let nodePresentation = presentation[nodeID]
      let metadataTitle = (node["_meta"] as? [String: Any])?["title"] as? String
      let schemas = definitionsByClass[classType] ?? []
      var parameters: [ComfyUIParameterDefinition] = []
      for schema in schemas {
        guard let rawValue = inputs[schema.name] else { continue }
        let address = ComfyUIParameterAddress(nodeID: nodeID, inputName: schema.name)
        guard !runtimeAddresses.contains(address) else { continue }
        let connected = isConnection(rawValue)
        let primitiveWidget = isPrimitiveWidget(schema)
        guard !connected || primitiveWidget else { continue }

        if let resultScale, nodeID == resultScale.address.nodeID {
          guard address == resultScale.address else { continue }
          let value = ComfyUIParameterValue.signedInteger(Int64(resultScale.nativeScale))
          templateValues[address] = value
          parameters.append(
            ComfyUIParameterDefinition(
              address: address,
              label: nodePresentation?.inputLabels[schema.name] ?? "Result Scale",
              control: .integer(isUnsigned: false),
              templateValue: value,
              minimum: .signedInteger(1),
              maximum: .signedInteger(Int64(resultScale.nativeScale)),
              step: .signedInteger(1),
              tooltip: "Final output multiplier relative to the generated width and height.",
              isAdvanced: false,
              isConnected: false))
          continue
        }

        let control = parameterControl(
          schema: schema,
          address: address,
          seedAddress: resolved.roles[.seed],
          rawValue: rawValue)
        let prefersUnsigned: Bool
        if case .integer(let isUnsigned) = control {
          prefersUnsigned = isUnsigned
        } else {
          prefersUnsigned = false
        }
        let value = connected ? nil : parameterValue(rawValue, for: control)
        if let value { templateValues[address] = value }

        parameters.append(
          ComfyUIParameterDefinition(
            address: address,
            label: nodePresentation?.inputLabels[schema.name] ?? humanized(schema.name),
            control: control,
            templateValue: value,
            minimum: scalarOption("min", in: schema.details, preferUnsigned: prefersUnsigned),
            maximum: scalarOption("max", in: schema.details, preferUnsigned: prefersUnsigned),
            step: scalarOption("step", in: schema.details, preferUnsigned: prefersUnsigned),
            tooltip: schema.details["tooltip"] as? String,
            isAdvanced: schema.details["advanced"] as? Bool == true,
            isConnected: connected))
      }

      nodes.append(
        ComfyUIWorkflowNodeDefinition(
          id: nodeID,
          title: nodePresentation?.title ?? metadataTitle ?? classType,
          classType: classType,
          order: nodePresentation?.order ?? numericNodeID(nodeID),
          parameters: parameters))
    }
    nodes.sort {
      if $0.order == $1.order { return compareNodeIDs($0.id, $1.id) }
      return $0.order < $1.order
    }

    return ComfyUIWorkflowForm(
      templateID: templateID,
      templateRevision: digest(templateData),
      nodes: nodes,
      templateValues: templateValues)
  }

  /// Applies a sparse parameter draft to a fresh copy of the API template.
  /// No caller can mutate the bundled template or address a missing input.
  static func defaultParameterValues(
    templateID: String
  ) throws -> [ComfyUIParameterAddress: ComfyUIParameterValue] {
    try defaultParameterValues(in: resolve(templateID: templateID))
  }

  static func defaultParameterValues(
    in resolved: ComfyUIResolvedWorkflow
  ) throws -> [ComfyUIParameterAddress: ComfyUIParameterValue] {
    let workflow = try apiWorkflow(from: resolved.apiData)
    let runtimeAddresses = Set(resolved.runtimeRoles.values)
    var values = scalarValues(
      in: workflow, seedAddress: resolved.roles[.seed]
    ).filter { !runtimeAddresses.contains($0.key) }
    if let resultScale = resultScaleBinding(in: resolved) {
      values[resultScale.address] = .signedInteger(Int64(resultScale.nativeScale))
    }
    return values
  }

  static func request(
    templateID: String,
    parameters: [ComfyUIParameterAddress: ComfyUIParameterValue],
    prompt: String,
    outputSize: CanvasRecipe? = nil,
    runtimeValues: [ComfyUIWorkflowRuntimeRole: ComfyUIRuntimeValue]? = nil
  ) throws -> ComfyUIWorkflowRequest {
    try request(
      resolved: resolve(templateID: templateID),
      parameters: parameters,
      prompt: prompt,
      outputSize: outputSize,
      runtimeValues: runtimeValues)
  }

  static func request(
    resolved definition: ComfyUIResolvedWorkflow,
    parameters: [ComfyUIParameterAddress: ComfyUIParameterValue],
    prompt: String,
    outputSize: CanvasRecipe? = nil,
    runtimeValues: [ComfyUIWorkflowRuntimeRole: ComfyUIRuntimeValue]? = nil
  ) throws -> ComfyUIWorkflowRequest {
    let templateID = definition.template.id
    let mode = definition.template.mode
    let template = definition.apiData
    let resultScale = resultScaleBinding(in: definition)
    var workflow = try apiWorkflow(from: template)
    for (address, value) in parameters {
      let workflowValue = try workflowValue(
        value, at: address, resultScale: resultScale)
      try set(workflowValue.jsonObject, address: address, in: &workflow)
    }
    if let promptAddress = definition.roles[.prompt] {
      try set(prompt, address: promptAddress, in: &workflow)
    }

    let runtimeAddresses = Set(definition.runtimeRoles.values)
    let resolvedValues = scalarValues(
      in: workflow, seedAddress: definition.roles[.seed]
    ).filter { !runtimeAddresses.contains($0.key) }
    if let runtimeValues {
      for (role, address) in definition.runtimeRoles {
        guard let value = runtimeValues[role], value.isValid else {
          throw PixeltjeMacError(
            "Workflow input unavailable", "The \(role.label) upload was not prepared.")
        }
        try set(value.jsonObject, address: address, in: &workflow)
      }
    } else if !runtimeAddresses.isEmpty {
      // A nil runtime map is a deliberate local preflight. The bundled
      // placeholder values validate the graph, but this request must be frozen
      // again with server-returned upload references before submission.
    }
    let rendered = try JSONSerialization.data(withJSONObject: workflow, options: [.sortedKeys])
    var recorded = resolvedValues
    if let resultScale {
      let value =
        parameters[resultScale.address]
        ?? .signedInteger(Int64(resultScale.nativeScale))
      recorded[resultScale.address] = try normalizedResultScale(
        value, binding: resultScale)
    }
    let records = recorded.map { ComfyUIParameterRecord(address: $0.key, value: $0.value) }
      .sorted {
        if $0.address.nodeID == $1.address.nodeID {
          return $0.address.inputName < $1.address.inputName
        }
        return compareNodeIDs($0.address.nodeID, $1.address.nodeID)
      }
    return ComfyUIWorkflowRequest(
      templateID: templateID,
      mode: mode,
      workflow: rendered,
      templateRevision: digest(template),
      prompt: prompt,
      negativePrompt: value(
        for: .negativePrompt, in: resolvedValues, roles: definition.roles)?.stringValue
        ?? "",
      seed: value(for: .seed, in: resolvedValues, roles: definition.roles)?.unsignedIntegerValue
        ?? 0,
      steps: max(
        Int(
          value(for: .steps, in: resolvedValues, roles: definition.roles)?.signedIntegerValue
            ?? 1),
        1),
      guidance: value(for: .guidance, in: resolvedValues, roles: definition.roles)?.doubleValue
        ?? 0,
      width: max(
        Int(
          value(for: .width, in: resolvedValues, roles: definition.roles)?.signedIntegerValue
            ?? Int64(outputSize?.width ?? 1)),
        1),
      height: max(
        Int(
          value(for: .height, in: resolvedValues, roles: definition.roles)?.signedIntegerValue
            ?? Int64(outputSize?.height ?? 1)),
        1),
      outputNodeIDs: definition.outputNodeIDs,
      parameters: records)
  }

  private static func workflowValue(
    _ value: ComfyUIParameterValue,
    at address: ComfyUIParameterAddress,
    resultScale: ResultScaleBinding?
  ) throws -> ComfyUIParameterValue {
    guard let resultScale, address == resultScale.address else { return value }
    let normalized = try normalizedResultScale(value, binding: resultScale)
    return .decimal(
      Double(normalized.signedIntegerValue ?? Int64(resultScale.nativeScale))
        / Double(resultScale.nativeScale))
  }

  private static func normalizedResultScale(
    _ value: ComfyUIParameterValue,
    binding: ResultScaleBinding
  ) throws -> ComfyUIParameterValue {
    guard let scale = value.signedIntegerValue,
      scale >= 1, scale <= Int64(binding.nativeScale)
    else {
      throw PixeltjeMacError(
        "Workflow setting invalid",
        "Result Scale must be a whole number from 1× through \(binding.nativeScale)×.")
    }
    return .signedInteger(scale)
  }

  private static func value(
    for role: ComfyUIWorkflowRole,
    in values: [ComfyUIParameterAddress: ComfyUIParameterValue],
    roles: [ComfyUIWorkflowRole: ComfyUIParameterAddress]
  ) -> ComfyUIParameterValue? {
    roles[role].flatMap { values[$0] }
  }

  private static func resultScaleBinding(
    in resolved: ComfyUIResolvedWorkflow
  ) -> ResultScaleBinding? {
    guard let address = resolved.resultScaleAddress,
      let nativeScale = resolved.resultScaleNativeValue
    else { return nil }
    return ResultScaleBinding(address: address, nativeScale: nativeScale)
  }

  private static func templateResources(templateID: String) -> TemplateResources? {
    if let bundled = bundledResources[templateID] { return bundled }
    guard let custom = ComfyUIWorkflowLibrary.shared.definitionSnapshot(for: templateID) else {
      return nil
    }
    return TemplateResources(
      apiName: custom.manifest.apiFilename,
      frontendName: custom.manifest.frontendFilename,
      roles: custom.manifest.bindings.roles,
      runtimeRoles: custom.manifest.bindings.runtimeRoles,
      outputNodeIDs: custom.manifest.outputNodeIDs,
      imageAlignment: custom.manifest.imageAlignment)
  }

  private static func apiData(templateID: String) throws -> Data {
    if let custom = ComfyUIWorkflowLibrary.shared.definitionSnapshot(for: templateID) {
      return custom.apiData
    }
    guard let resource = bundledResources[templateID] else {
      throw PixeltjeMacError(
        "Workflow unavailable", "The selected ComfyUI workflow is not installed.")
    }
    guard
      let url = workflowBundle.url(
        forResource: resource.apiName, withExtension: "json", subdirectory: "ComfyUI")
    else {
      throw PixeltjeMacError(
        "Workflow unavailable", "The bundled \(templateID) API workflow is missing.")
    }
    return try Data(contentsOf: url)
  }

  private static func optionalFrontendData(templateID: String) throws -> Data? {
    if let custom = ComfyUIWorkflowLibrary.shared.definitionSnapshot(for: templateID) {
      return custom.frontendData
    }
    guard let resource = bundledResources[templateID],
      let url = workflowBundle.url(
        forResource: resource.frontendName, withExtension: "json", subdirectory: "ComfyUI")
    else { return nil }
    return try Data(contentsOf: url)
  }

  private static func apiWorkflow(from data: Data) throws -> [String: Any] {
    guard let workflow = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PixeltjeMacError(
        "Workflow invalid", "The bundled ComfyUI API workflow is not a JSON object.")
    }
    return workflow
  }

  private static func frontendPresentation(resolved: ComfyUIResolvedWorkflow) throws
    -> [String: NodePresentation]
  {
    guard let data = resolved.frontendData else { return [:] }
    guard let workflow = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawNodes = workflow["nodes"] as? [[String: Any]]
    else { return [:] }

    let definitions = workflow["definitions"] as? [String: Any]
    let subgraphs = definitions?["subgraphs"] as? [[String: Any]] ?? []
    var subgraphsByID: [String: [[String: Any]]] = [:]
    for subgraph in subgraphs {
      guard let id = stringID(subgraph["id"]),
        let nodes = subgraph["nodes"] as? [[String: Any]],
        subgraphsByID[id] == nil
      else { continue }
      subgraphsByID[id] = nodes
    }
    let usesSubgraphs = !subgraphsByID.isEmpty
    let orderStride = 10_000
    var result: [String: NodePresentation] = [:]
    func add(_ node: [String: Any], nodeID: String, order: Int) {
      var inputLabels: [String: String] = [:]
      for input in node["inputs"] as? [[String: Any]] ?? [] {
        guard let name = input["name"] as? String else { continue }
        if let label = input["localized_name"] as? String, !label.isEmpty {
          inputLabels[name] = label
        } else if let label = input["label"] as? String, !label.isEmpty {
          inputLabels[name] = label
        }
      }
      result[nodeID] = NodePresentation(
        title: (node["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
        order: order,
        inputLabels: inputLabels)
    }
    for (nodeIndex, node) in rawNodes.enumerated() {
      guard let nodeID = stringID(node["id"]) else { continue }
      let topLevelOrder = (node["order"] as? NSNumber)?.intValue ?? nodeIndex
      add(
        node,
        nodeID: nodeID,
        order: usesSubgraphs ? topLevelOrder * orderStride : topLevelOrder)
      guard let subgraphID = node["type"] as? String,
        let nestedNodes = subgraphsByID[subgraphID]
      else { continue }
      for (nestedIndex, nested) in nestedNodes.enumerated() {
        guard let nestedID = stringID(nested["id"]) else { continue }
        let nestedOrder = (nested["order"] as? NSNumber)?.intValue ?? nestedIndex
        add(
          nested,
          nodeID: "\(nodeID):\(nestedID)",
          order: topLevelOrder * orderStride + nestedOrder)
      }
    }
    return result
  }

  private static func inputSchemas(classType: String, data: Data) throws -> [InputSchema] {
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let definition = envelope[classType] as? [String: Any]
    else { return [] }
    let input = definition["input"] as? [String: Any] ?? [:]
    let inputOrder = definition["input_order"] as? [String: Any] ?? [:]
    var result: [InputSchema] = []

    for category in ["required", "optional"] {
      let rawSpecs = input[category] as? [String: Any] ?? [:]
      let explicitOrder = inputOrder[category] as? [String] ?? []
      let orderedNames =
        explicitOrder
        + rawSpecs.keys.filter { !explicitOrder.contains($0) }.sorted()
      for name in orderedNames {
        guard let rawSpec = rawSpecs[name] as? [Any], let first = rawSpec.first else { continue }
        let details = rawSpec.count > 1 ? rawSpec[1] as? [String: Any] ?? [:] : [:]
        if let options = first as? [Any] {
          result.append(
            InputSchema(
              name: name,
              type: "COMBO",
              options: options.compactMap { ComfyUIParameterValue.workflowScalar($0) },
              details: details))
        } else if let type = first as? String {
          let rawOptions = details["options"] as? [Any] ?? []
          result.append(
            InputSchema(
              name: name,
              type: type,
              options: rawOptions.compactMap { ComfyUIParameterValue.workflowScalar($0) },
              details: details))
        }
      }
    }
    return result
  }

  private static func parameterControl(
    schema: InputSchema,
    address: ComfyUIParameterAddress,
    seedAddress: ComfyUIParameterAddress?,
    rawValue: Any
  ) -> ComfyUIParameterControl {
    switch schema.type.uppercased() {
    case "INT":
      let rawMaximum = schema.details["max"] as? NSNumber
      let unsigned =
        address == seedAddress
        || (rawMaximum.map { $0.doubleValue > Double(Int64.max) } ?? false)
      return .integer(isUnsigned: unsigned)
    case "FLOAT":
      return .decimal
    case "BOOLEAN":
      return .boolean
    case "STRING":
      return .text(multiline: schema.details["multiline"] as? Bool == true)
    case "COMBO":
      return .choice(schema.options)
    default:
      let description =
        ComfyUIParameterValue.workflowScalar(rawValue)?.displayValue
        ?? "A custom ComfyUI widget is required."
      return .unsupported(description)
    }
  }

  private static func isPrimitiveWidget(_ schema: InputSchema) -> Bool {
    ["INT", "FLOAT", "BOOLEAN", "STRING", "COMBO"].contains(schema.type.uppercased())
      || !schema.options.isEmpty
  }

  private static func parameterValue(
    _ rawValue: Any,
    for control: ComfyUIParameterControl
  ) -> ComfyUIParameterValue? {
    switch control {
    case .integer(let isUnsigned):
      let scalar = ComfyUIParameterValue.workflowScalar(
        rawValue, preferUnsigned: isUnsigned)
      if isUnsigned, let value = scalar?.unsignedIntegerValue {
        return .unsignedInteger(value)
      }
      if let value = scalar?.signedIntegerValue {
        return .signedInteger(value)
      }
      return nil
    case .decimal:
      return ComfyUIParameterValue.workflowScalar(rawValue)?.doubleValue.map {
        .decimal($0)
      }
    case .boolean:
      return ComfyUIParameterValue.workflowScalar(rawValue)?.booleanValue.map {
        .boolean($0)
      }
    case .text:
      return ComfyUIParameterValue.workflowScalar(rawValue)?.stringValue.map {
        .string($0)
      }
    case .choice(let options):
      let scalar = ComfyUIParameterValue.workflowScalar(rawValue)
      return scalar.flatMap { options.contains($0) ? $0 : nil }
    case .unsupported:
      return ComfyUIParameterValue.workflowScalar(rawValue)
    }
  }

  private static func scalarOption(
    _ name: String,
    in details: [String: Any],
    preferUnsigned: Bool
  ) -> ComfyUIParameterValue? {
    details[name].flatMap {
      ComfyUIParameterValue.workflowScalar($0, preferUnsigned: preferUnsigned)
    }
  }

  private static func scalarValues(
    in workflow: [String: Any],
    seedAddress: ComfyUIParameterAddress?
  )
    -> [ComfyUIParameterAddress: ComfyUIParameterValue]
  {
    var values: [ComfyUIParameterAddress: ComfyUIParameterValue] = [:]
    for (nodeID, rawNode) in workflow {
      guard let inputs = (rawNode as? [String: Any])?["inputs"] as? [String: Any] else {
        continue
      }
      for (inputName, rawValue) in inputs {
        let address = ComfyUIParameterAddress(nodeID: nodeID, inputName: inputName)
        if let value = ComfyUIParameterValue.workflowScalar(
          rawValue, preferUnsigned: seedAddress == address)
        {
          values[address] = value
        }
      }
    }
    return values
  }

  private static func set(
    _ value: Any,
    address: ComfyUIParameterAddress,
    in workflow: inout [String: Any]
  ) throws {
    guard var node = workflow[address.nodeID] as? [String: Any],
      var inputs = node["inputs"] as? [String: Any],
      inputs[address.inputName] != nil
    else {
      throw PixeltjeMacError(
        "Workflow changed",
        "The workflow no longer has input \(address.inputName) on node \(address.nodeID).")
    }
    if let current = inputs[address.inputName], isConnection(current) {
      throw PixeltjeMacError(
        "Workflow input is connected",
        "\(address.displayValue) is driven by another node and cannot accept a scalar value.")
    }
    inputs[address.inputName] = value
    node["inputs"] = inputs
    workflow[address.nodeID] = node
  }

  private static func isConnection(_ value: Any) -> Bool {
    guard let values = value as? [Any], values.count == 2,
      values[0] is String, values[1] is NSNumber
    else { return false }
    return true
  }

  private static func humanized(_ name: String) -> String {
    name.replacingOccurrences(of: "_", with: " ")
  }

  private static func stringID(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private static func numericNodeID(_ value: String) -> Int {
    Int(value) ?? Int.max
  }

  private static func compareNodeIDs(_ lhs: String, _ rhs: String) -> Bool {
    let left = numericNodeID(lhs)
    let right = numericNodeID(rhs)
    if left == right { return lhs < rhs }
    return left < right
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension GenerationMode {
  var comfyUIDisplayName: String {
    switch self {
    case .textToImage: "Generating"
    case .imageToImage: "Editing"
    case .inpainting: "Inpainting"
    case .selection: "Selection"
    }
  }
}

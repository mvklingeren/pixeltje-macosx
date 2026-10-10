import PixeltjePipelineDomain

/// Serialized widget order of the ComfyUI nodes that import as subgraphs.
let expandedNodeWidgets: [String: [String]] = [
  "LoraLoader": ["lora_name", "strength_model", "strength_clip"],
  "CLIPTextEncodeSDXL": [
    "width", "height", "crop_w", "crop_h", "target_width", "target_height", "text_g", "text_l",
  ],
  "CLIPTextEncodeFlux": ["clip_l", "t5xxl", "guidance"],
  "KSamplerAdvanced": [
    "add_noise", "noise_seed", "control_after_generate", "steps", "cfg", "sampler_name",
    "scheduler", "start_at_step", "end_at_step", "return_with_leftover_noise",
  ],
]

/// Imports an all-in-one ComfyUI node as a subgraph of separate native nodes
/// instead of one composite node, so each step stays visible, editable and
/// reusable. The node that produces the primary result keeps the source node's
/// ID; the others append their role to it.
func expandNode(
  _ source: SourceNode,
  nodeID: PipelineNodeID,
  resources: [String: PipelineResourceBinding],
  origin: PipelineNodeOrigin
) -> ConvertedNode? {
  guard let knownWidgets = expandedNodeWidgets[source.type],
    source.widgets.count <= knownWidgets.count
  else { return nil }
  var b = SubgraphBuilder(source: source, nodeID: nodeID, origin: origin)
  let widgets = widgetParameters(for: source)
  switch source.type {
  case "LoraLoader":
    // One LoRA file patches the denoiser and the text encoder independently.
    guard source.hasInputs("model", "clip"), let adapter = resources["adapter"] else {
      return nil
    }
    let model = b.add(
      nil, "coreai.adapter", "LoRA Adapter",
      parameters: mappedWidgetParameters(
        for: source, names: ["lora_name": "modelName", "strength_model": "weight"]),
      resources: ["adapter": adapter])
    let encoder = b.add(
      "textEncoder", "coreai.textEncoderAdapter", "LoRA Text Encoder Adapter",
      parameters: mappedWidgetParameters(
        for: source, names: ["lora_name": "modelName", "strength_clip": "weight"]),
      resources: ["adapter": adapter])
    b.route("model", model, "base")
    b.route("clip", encoder, "textEncoder")
    b.expose(0, "MODEL", model, "function")
    b.expose(1, "CLIP", encoder, "textEncoder")

  case "CLIPTextEncodeSDXL":
    guard source.hasInputs("clip") else { return nil }
    let encode = b.add(
      "encode", "conditioning.textEncodeSDXL", "SDXL Text Conditioning Encoder",
      parameters: mappedWidgetParameters(
        for: source, names: ["text_g": "textG", "text_l": "textL"]))
    let size = b.add(
      nil, "conditioning.sdxlSize", "SDXL Size Conditioning",
      parameters: mappedWidgetParameters(for: source, names: [
        "width": "width", "height": "height", "crop_w": "cropW", "crop_h": "cropH",
        "target_width": "targetWidth", "target_height": "targetHeight",
      ]))
    b.route("clip", encode, "textEncoder")
    b.route("text_g", encode, "textG")
    b.route("text_l", encode, "textL")
    b.route("width", size, "width")
    b.route("height", size, "height")
    b.connect(encode, "conditioning", size, "conditioning")
    b.expose(0, "CONDITIONING", size, "conditioning")

  case "CLIPTextEncodeFlux":
    guard source.hasInputs("clip") else { return nil }
    let encode = b.add(
      "encode", "conditioning.textEncodeFlux", "FLUX Text Conditioning Encoder",
      parameters: mappedWidgetParameters(
        for: source, names: ["clip_l": "clipL", "t5xxl": "t5xxl"]))
    let guidance = b.add(
      nil, "conditioning.fluxGuidance", "FLUX Guidance",
      parameters: mappedWidgetParameters(for: source, names: ["guidance": "guidance"]))
    b.route("clip", encode, "textEncoder")
    b.route("clip_l", encode, "clipL")
    b.route("t5xxl", encode, "t5xxl")
    b.connect(encode, "conditioning", guidance, "conditioning")
    b.expose(0, "CONDITIONING", guidance, "conditioning")

  case "KSamplerAdvanced":
    // ComfyUI's own custom-sampling nodes express the same operation: noise,
    // a CFG guider, a sampler, a schedule truncated at `end_at_step` (its last
    // sigma forced to zero unless leftover noise is returned), then trimmed to
    // start at `start_at_step`.
    guard source.hasInputs("model", "positive", "negative", "latent_image") else { return nil }
    let steps = widgets["steps"]?.integerValue ?? 20
    let startStep = widgets["start_at_step"]?.integerValue ?? 0
    let endStep = widgets["end_at_step"]?.integerValue ?? 10000
    let addNoise = widgets["add_noise"]?.stringValue ?? "enable"
    let leftoverNoise = widgets["return_with_leftover_noise"]?.stringValue ?? "disable"
    // ComfyUI returns the input latent without sampling when the start step
    // reaches the end of the truncated schedule. The subgraph has no matching
    // early-return operator, so keep that source node intact.
    guard steps > 0, startStep >= 0, endStep >= 0,
      startStep < min(endStep, steps),
      ["enable", "disable"].contains(addNoise),
      ["enable", "disable"].contains(leftoverNoise)
    else { return nil }
    let noise =
      addNoise == "disable"
      ? b.add("noise", "latent.disableNoise", "Disable Noise")
      : b.add(
        "noise", "latent.randomNoise", "Random Noise",
        parameters: mappedWidgetParameters(
          for: source, names: ["noise_seed": "seed", "control_after_generate": "seedControl"]))
    let guider = b.add(
      "guider", "diffusion.cfgGuider", "CFG Guider",
      parameters: mappedWidgetParameters(for: source, names: ["cfg": "guidance"]))
    let sampler = b.add(
      "sampler", "diffusion.samplerSelector", "Sampler Selector",
      parameters: mappedWidgetParameters(for: source, names: ["sampler_name": "samplerName"]))
    let scheduler = b.add(
      "schedule", "diffusion.basicScheduler", "Basic Scheduler",
      parameters: mappedWidgetParameters(
        for: source, names: ["scheduler": "scheduler", "steps": "steps"]
      ).merging(["denoise": .number(1)]) { current, _ in current })
    var schedule = (node: scheduler, port: "schedule")
    if endStep < steps {
      let stop = b.add(
        "endAtStep", "diffusion.splitSchedule", "Stop at Step",
        parameters: ["step": .integer(endStep)])
      b.connect(schedule.node, schedule.port, stop, "schedule")
      schedule = (stop, "high")
      if leftoverNoise != "enable" {
        let denoiseToZero = b.add("denoiseToZero", "diffusion.forceFullDenoise", "Denoise to Zero")
        b.connect(schedule.node, schedule.port, denoiseToZero, "schedule")
        schedule = (denoiseToZero, "schedule")
      }
    }
    if startStep > 0 {
      let start = b.add(
        "startAtStep", "diffusion.splitSchedule", "Start at Step",
        parameters: ["step": .integer(startStep)])
      b.connect(schedule.node, schedule.port, start, "schedule")
      schedule = (start, "low")
    }
    let sample = b.add(nil, "diffusion.advancedSampler", "Advanced Sampler")
    b.route("model", guider, "denoiser")
    b.route("model", scheduler, "denoiser")
    b.route("positive", guider, "positive")
    b.route("negative", guider, "negative")
    b.route("steps", scheduler, "steps")
    b.route("scheduler", scheduler, "scheduler")
    b.route("latent_image", sample, "sourceLatent")
    b.connect(noise, "noise", sample, "noise")
    b.connect(guider, "guider", sample, "guider")
    b.connect(sampler, "function", sample, "sampler")
    b.connect(schedule.node, schedule.port, sample, "schedule")
    b.expose(0, "LATENT", sample, "latent")

  default:
    return nil
  }
  return b.build()
}

struct SubgraphBuilder {
  private let source: SourceNode
  private let baseID: String
  private let origin: PipelineNodeOrigin
  private var nodes: [PipelineNode] = []
  private var connections: [PipelineConnection] = []
  private var inputTargets: [String: [PipelinePortReference]] = [:]
  private var outputSources: [Int: (type: String, reference: PipelinePortReference)] = [:]

  init(source: SourceNode, nodeID: PipelineNodeID, origin: PipelineNodeOrigin) {
    self.source = source
    baseID = nodeID.rawValue
    self.origin = origin
  }

  /// Adds a subgraph node. A `nil` role marks the node that keeps the source
  /// node's ID.
  mutating func add(
    _ role: String?,
    _ kind: String,
    _ title: String,
    parameters: [String: PipelineValue] = [:],
    resources: [String: PipelineResourceBinding] = [:]
  ) -> PipelineNodeID {
    let id = PipelineNodeID(rawValue: role.map { "\(baseID)-\($0)" } ?? baseID)
    nodes.append(PipelineNode(
      id: id, kind: PipelineNodeKind(rawValue: kind), title: title,
      parameters: parameters, resources: resources,
      executionState: source.executionState, origin: origin))
    return id
  }

  mutating func connect(
    _ outputNode: PipelineNodeID,
    _ outputPort: String,
    _ inputNode: PipelineNodeID,
    _ inputPort: String
  ) {
    connections.append(PipelineConnection(
      id: PipelineConnectionID(rawValue: "\(baseID)-internal-\(connections.count + 1)"),
      output: PipelinePortReference(nodeID: outputNode, port: outputPort),
      input: PipelinePortReference(nodeID: inputNode, port: inputPort)))
  }

  /// Feeds a ComfyUI input, linked or promoted from a widget, to a native
  /// input. One ComfyUI input may feed several subgraph nodes.
  mutating func route(_ sourceInput: String, _ node: PipelineNodeID, _ port: String) {
    inputTargets[sourceInput, default: []].append(
      PipelinePortReference(nodeID: node, port: port))
  }

  /// Exposes a native output as the ComfyUI output in `slot`, which must
  /// carry `type`.
  mutating func expose(_ slot: Int, _ type: String, _ node: PipelineNodeID, _ port: String) {
    outputSources[slot] = (type, PipelinePortReference(nodeID: node, port: port))
  }

  func build() -> ConvertedNode? {
    guard let anchor = nodes.first(where: { $0.id.rawValue == baseID }) else { return nil }
    var sources = [PipelinePortReference?](repeating: nil, count: source.outputs.count)
    for (slot, exposed) in outputSources {
      guard source.outputs.indices.contains(slot),
        normalizedType(source.outputs[slot].type) == exposed.type
      else { return nil }
      sources[slot] = exposed.reference
    }
    return ConvertedNode(
      node: anchor,
      inputNames: [String?](repeating: nil, count: source.inputs.count),
      outputNames: [String?](repeating: nil, count: source.outputs.count),
      wasMapped: true,
      expansion: ConvertedExpansion(
        nodes: nodes.filter { $0.id != anchor.id },
        connections: connections,
        inputTargets: source.inputs.map { inputTargets[$0.name] ?? [] },
        outputSources: sources))
  }
}

extension SourceNode {
  fileprivate func hasInputs(_ names: String...) -> Bool {
    names.allSatisfy { name in inputs.contains { $0.name == name } }
  }
}

extension PipelineValue {
  fileprivate var integerValue: Int64? {
    switch self {
    case .integer(let value): value
    case .number(let value) where value.rounded() == value: Int64(exactly: value)
    default: nil
    }
  }

  fileprivate var booleanValue: Bool? {
    guard case .boolean(let value) = self else { return nil }
    return value
  }

  fileprivate var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}

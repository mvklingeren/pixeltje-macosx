import CoreAI
import Foundation
import Metal
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineResourceLinking
import Tokenizers

/// Fixed 1024 × 1024 Klein 9B FP8 path. The graph has one generation node,
/// while each learned split component is loaded and released per call.
public enum FLUX2Klein9BSplitFamily {
  public static let packageID = Flux9BSplitPackage.packageID
  public static let nodeKind = Flux9BSplitPackage.nodeKind

  public static func descriptor() -> PipelineNodeDescriptor {
    PipelineNodeDescriptor(
      kind: nodeKind,
      displayName: "FLUX.2 Klein 9B FP8 Generate",
      category: "Generation",
      inputs: [
        .init(name: "prompt", type: .prompt),
        .init(name: "seed", type: .seed, isRequired: false),
      ],
      outputs: [.init(name: "image", type: .image)],
      parameters: [
        .init(name: "width", valueType: .integer, defaultValue: .integer(1024)),
        .init(name: "height", valueType: .integer, defaultValue: .integer(1024)),
        .init(name: "steps", valueType: .integer, defaultValue: .integer(4)),
        .init(name: "guidance", valueType: .number, defaultValue: .number(1)),
      ],
      requiredResourceSlots: ["denoiser", "textEncoder", "vaeDecoder"])
  }

  public static func makeNode(id: PipelineNodeID) -> PipelineNode {
    let sources = [
      "denoiser": ("denoiser", "FLUX.2-klein-9B-fp8-1024-experimental"),
      "textEncoder": ("textEncoder", "Qwen3-8B-FP8-flux2-encoder-experimental"),
      "vaeDecoder": ("vae", "FLUX.2-klein-4B/VAEDecoder.aimodel"),
    ]
    let resources = sources.mapValues { role, name in
      PipelineResourceBinding.unresolved(.init(
        kind: .coreAIModel, componentRole: role,
        sourceName: name, sourceFormat: "split-aimodel",
        familyABI: Flux9BSplitPackage.familyABI))
    }
    return PipelineNode(
      id: id, kind: nodeKind, title: "FLUX.2 Klein 9B FP8 Generate",
      parameters: ["width": .integer(1024), "height": .integer(1024),
        "steps": .integer(4), "guidance": .number(1)],
      resources: resources)
  }

  public static func defaultPackageURL(
    adapted: Bool = false,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    homeDirectory.appendingPathComponent(
      adapted
        ? ".pixeltje/models/FLUX.2-klein-9B-fp8-1024-real-hd-2k"
        : ".pixeltje/models/FLUX.2-klein-9B-fp8-1024",
      isDirectory: true)
  }

  public static func inspectPackage(
    at url: URL,
    for document: PipelineDocument? = nil
  ) -> FLUX2KleinPackageInspection {
    do {
      let package = try Flux9BSplitPackage(at: url)
      for node in document?.nodes.filter({ $0.kind == nodeKind }) ?? [] {
        try package.validateLinks(in: node)
      }
      return .init(packageRoot: url)
    } catch {
      return .init(packageRoot: url, incompatibleComponents: [error.localizedDescription])
    }
  }

  public static func executor(runner: FLUX2Klein9BSplitRunner) -> PipelineNodeExecutor {
    PipelineNodeExecutor(kind: nodeKind, validate: diagnostics) { node, inputs, context in
      guard let prompt = inputs["prompt"]?.value(as: String.self),
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw PipelineEngineError.invalidInvocation("Enter a Klein 9B prompt.") }
      guard let reference = node.resources["denoiser"]?.linkedReference else {
        throw PipelineEngineError.modelPackageUnavailable("Link a Klein 9B package first.")
      }
      let packageRoot = try context.packageRoot(for: reference)
      let package = try Flux9BSplitPackage(at: packageRoot)
      try package.validateLinks(in: node)
      let steps = integer(node.parameters["steps"]) ?? 4
      let seed = inputs["seed"]?.value(as: UInt64.self) ?? 0
      let image = try await runner.generate(
        package: package, prompt: prompt, seed: seed, steps: steps,
        semanticSHA256: context.semanticSHA256, nodeID: node.id,
        progress: context.progress)
      return PipelineNodeResult(outputs: ["image": PipelineNodeValue(image, type: .image)])
    }
  }

  private static func diagnostics(_ node: PipelineNode) -> [PipelineDiagnostic] {
    var messages: [String] = []
    if integer(node.parameters["width"]) != 1024
      || integer(node.parameters["height"]) != 1024 {
      messages.append("Klein 9B split export requires 1024×1024 output.")
    }
    if let steps = integer(node.parameters["steps"]), !(1...20).contains(steps) {
      messages.append("Klein 9B supports 1–20 steps.")
    }
    if number(node.parameters["guidance"]) != 1 {
      messages.append("Klein 9B Distilled requires guidance 1.")
    }
    return messages.map {
      PipelineDiagnostic(severity: .error, code: .invalidParameter,
        message: $0, nodeID: node.id)
    }
  }

  private static func integer(_ value: PipelineValue?) -> Int? {
    if case .integer(let raw)? = value { return Int(exactly: raw) }
    return nil
  }

  private static func number(_ value: PipelineValue?) -> Double? {
    switch value {
    case .number(let raw): raw
    case .integer(let raw): Double(raw)
    default: nil
    }
  }
}

public actor FLUX2Klein9BSplitRunner {
  private let stream: ComputeStream?

  public init() {
    if let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() {
      stream = ComputeStream(commandQueue: queue)
    } else {
      stream = nil
    }
  }

  public func generate(
    package: Flux9BSplitPackage,
    prompt: String,
    seed: UInt64,
    steps: Int,
    semanticSHA256: String,
    nodeID: PipelineNodeID,
    progress: @escaping PipelineExecutionProgressHandler
  ) async throws -> PipelineGeneratedImage {
    guard stream != nil else { throw PipelineEngineError.metalCommandQueueUnavailable }
    guard (1...20).contains(steps) else {
      throw PipelineEngineError.invalidInvocation("Klein 9B supports 1–20 steps.")
    }
    try Task.checkCancellation()
    await progress(.init(stage: .loadingModels, message: "Encoding prompt with Qwen3-8B…",
      activeNodeIDs: [nodeID]))
    let text = try await encode(prompt: prompt, root: package.root)
    try Task.checkCancellation()
    var latent = Self.noise(seed: seed, count: 4096 * 128)
    let sigmas = Self.schedule(steps: steps)
    let imageIDs = try Self.array(Self.imageIDs(), shape: [4096, 4])
    let textIDs = try Self.array(Self.textIDs(), shape: [512, 4])
    let textArray = try Self.array(text.map(Float16.init), shape: [1, 512, 12288])
    for step in 0..<steps {
      try Task.checkCancellation()
      await progress(.init(stage: .denoising,
        message: "Denoising Klein 9B step \(step + 1) of \(steps)…",
        completedUnitCount: step, totalUnitCount: steps, activeNodeIDs: [nodeID]))
      let timestep = Float16(Float(Int(sigmas[step] * 1000)) / 1000)
      let head = try await invoke(
        package.root.appendingPathComponent("Head.aimodel"),
        inputs: [
          "image": try Self.array(latent.map(Float16.init), shape: [1, 4096, 128]),
          "text": textArray,
          "timestep": try Self.array([timestep], shape: [1]),
          "image_ids": imageIDs,
          "text_ids": textIDs,
        ],
        outputs: ["image_out", "text_out", "image_mod", "text_mod",
          "single_mod", "temb", "cos", "sin"])
      var image = try Self.require(head, "image_out")
      var textState = try Self.require(head, "text_out")
      let imageMod = try Self.require(head, "image_mod")
      let textMod = try Self.require(head, "text_mod")
      let singleMod = try Self.require(head, "single_mod")
      let temb = try Self.require(head, "temb")
      let cos = try Self.require(head, "cos")
      let sin = try Self.require(head, "sin")
      for component in Flux9BSplitPackage.denoiserComponents.dropFirst().dropLast() {
        try Task.checkCancellation()
        let isDouble = component.hasPrefix("Double")
        let result = try await invoke(
          package.root.appendingPathComponent(component),
          inputs: [
            "image": image, "text": textState,
            "image_mod": isDouble ? imageMod : singleMod,
            "text_mod": isDouble ? textMod : singleMod,
            "cos": cos, "sin": sin,
          ],
          outputs: ["image_out", "text_out"])
        image = try Self.require(result, "image_out")
        textState = try Self.require(result, "text_out")
      }
      let tail = try await invoke(
        package.root.appendingPathComponent("Tail.aimodel"),
        inputs: ["image": image, "temb": temb], outputs: ["output"])
      let velocity = try Self.floats(Self.require(tail, "output"))
      guard velocity.count == latent.count else {
        throw PipelineEngineError.planningFailed("Klein 9B returned the wrong latent shape.")
      }
      let delta = sigmas[step + 1] - sigmas[step]
      for i in latent.indices {
        latent[i] += delta * velocity[i]
      }
      guard latent.allSatisfy(\.isFinite) else {
        throw PipelineEngineError.planningFailed("Klein 9B returned non-finite latents.")
      }
    }
    try Task.checkCancellation()
    await progress(.init(stage: .decoding, message: "Decoding 1024×1024 image…",
      completedUnitCount: steps, totalUnitCount: steps, activeNodeIDs: [nodeID]))
    let vaeLatent = try Self.vaeLatent(latent, root: package.root)
    let decoded = try await invoke(
      package.root.appendingPathComponent("VAEDecoder.aimodel"),
      inputs: ["z": try Self.array(vaeLatent.map(Float16.init),
        shape: [1, 32, 128, 128])],
      outputs: ["image"])
    let pixels = try Self.floats(Self.require(decoded, "image"))
    guard pixels.count == 3 * 1024 * 1024, pixels.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("The Klein 9B VAE returned invalid pixels.")
    }
    return PipelineGeneratedImage(
      width: 1024, height: 1024, planarRGB: pixels,
      encoding: .sRGBMinusOneToOne, semanticPipelineSHA256: semanticSHA256)
  }

  private func encode(prompt: String, root: URL) async throws -> [Float] {
    let encoderRoot = root.appendingPathComponent("TextEncoder", isDirectory: true)
    let tokenizer = try await AutoTokenizer.from(
      modelFolder: encoderRoot.appendingPathComponent("tokenizer", isDirectory: true))
    let unpadded = try tokenizer.applyChatTemplate(
      messages: [["role": "user", "content": prompt]],
      chatTemplate: nil, addGenerationPrompt: true, truncation: true, maxLength: 512,
      tools: nil,
      additionalContext: ["enable_thinking": false])
    let count = min(unpadded.count, 512)
    let pad = tokenizer.convertTokenToId("<|endoftext|>") ?? 151643
    var ids = Array(unpadded.prefix(512)).map(Int32.init)
    ids += Array(repeating: Int32(pad), count: 512 - ids.count)
    let mask = Self.attentionMask(validTokens: count)
    let (cos, sin) = Self.qwenRoPE()
    var hidden = try Self.require(
      await invoke(
        encoderRoot.appendingPathComponent("Embedding.aimodel"),
        inputs: ["input_ids": try Self.array(ids, shape: [1, 512])],
        outputs: ["hidden_out"]), "hidden_out")
    let maskArray = try Self.array(mask, shape: [1, 1, 512, 512])
    let cosArray = try Self.array(cos, shape: [1, 512, 128])
    let sinArray = try Self.array(sin, shape: [1, 512, 128])
    var layers: [[Float]] = []
    for index in 0..<27 {
      try Task.checkCancellation()
      let name = String(format: "Layer%02d.aimodel", index)
      hidden = try Self.require(
        await invoke(encoderRoot.appendingPathComponent(name),
          inputs: ["hidden": hidden, "attention_mask": maskArray,
            "cos": cosArray, "sin": sinArray], outputs: ["hidden_out"]),
        "hidden_out")
      if [8, 17, 26].contains(index) { layers.append(try Self.floats(hidden)) }
    }
    guard layers.count == 3 else {
      throw PipelineEngineError.planningFailed("Qwen3-8B did not return three hidden states.")
    }
    var combined = [Float](repeating: 0, count: 512 * 12288)
    for token in 0..<512 {
      for layer in 0..<3 {
        let source = token * 4096
        let target = token * 12288 + layer * 4096
        combined[target..<(target + 4096)] = layers[layer][source..<(source + 4096)]
      }
    }
    guard combined.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("Qwen3-8B returned non-finite text embeddings.")
    }
    return combined
  }

  private func invoke(
    _ url: URL, inputs: [String: NDArray], outputs names: [String]
  ) async throws -> [String: NDArray] {
    guard let stream else { throw PipelineEngineError.metalCommandQueueUnavailable }
    let options = SpecializationOptions(preferredComputeUnitKind: .gpu)
    let model = try await AIModel(contentsOf: url.resolvingSymlinksInPath(), options: options)
    guard let function = try model.loadFunction(named: "main") else {
      throw PipelineEngineError.modelPackageUnavailable("\(url.lastPathComponent) has no main function.")
    }
    let arguments = inputs.mapValues(InferenceFunction.AsyncValue.init)
    let pending = try function.encode(inputs: arguments, to: stream)
    var result: [String: NDArray] = [:]
    for name in names {
      guard let value = pending[name], let array = try await value.ndArray else {
        throw PipelineEngineError.planningFailed("\(url.lastPathComponent) returned no \(name).")
      }
      result[name] = array
    }
    try Task.checkCancellation()
    return result
  }

  private static func require(_ values: [String: NDArray], _ name: String) throws -> NDArray {
    guard let value = values[name] else {
      throw PipelineEngineError.planningFailed("Core AI returned no \(name).")
    }
    return value
  }

  private static func array<T: BitwiseCopyable>(
    _ values: [T], shape: [Int]
  ) throws -> NDArray {
    guard shape.reduce(1, *) == values.count else {
      throw PipelineEngineError.invalidInvocation("Klein 9B tensor shape mismatch.")
    }
    let scalar: NDArray.ScalarType
    if T.self == Float16.self { scalar = .float16 }
    else if T.self == Float.self { scalar = .float32 }
    else if T.self == Int32.self { scalar = .int32 }
    else { throw PipelineEngineError.invalidInvocation("Unsupported Klein 9B tensor type.") }
    var array = NDArray(shape: shape, scalarType: scalar)
    var view = array.mutableView(as: T.self)
    view.copyElements(fromContentsOf: values)
    return array
  }

  private static func floats(_ array: NDArray) throws -> [Float] {
    let count = array.shape.reduce(1, *)
    switch array.scalarType {
    case .float32:
      return array.view(as: Float.self).withUnsafePointer { pointer, _, _ in
        Array(UnsafeBufferPointer(start: pointer, count: count))
      }
    case .float16:
      return array.view(as: Float16.self).withUnsafePointer { pointer, _, _ in
        (0..<count).map { Float(pointer[$0]) }
      }
    default:
      throw PipelineEngineError.planningFailed("Klein 9B returned unsupported tensor type.")
    }
  }

  private static func attentionMask(validTokens: Int) -> [Float16] {
    var mask = [Float16](repeating: 0, count: 512 * 512)
    for row in 0..<512 {
      for column in 0..<512 where column > row || column >= validTokens {
        mask[row * 512 + column] = -65504
      }
    }
    return mask
  }

  private static func qwenRoPE() -> ([Float16], [Float16]) {
    var cos = [Float16](repeating: 0, count: 512 * 128)
    var sin = cos
    for position in 0..<512 {
      for frequency in 0..<64 {
        let angle = Double(position) * pow(1_000_000, -Double(frequency) / 64)
        let c = Float16(cosine(angle))
        let s = Float16(sine(angle))
        for half in 0..<2 {
          let offset = position * 128 + half * 64 + frequency
          cos[offset] = c
          sin[offset] = s
        }
      }
    }
    return (cos, sin)
  }

  private static func cosine(_ x: Double) -> Double { Foundation.cos(x) }
  private static func sine(_ x: Double) -> Double { Foundation.sin(x) }

  private static func imageIDs() -> [Float] {
    var values = [Float](repeating: 0, count: 4096 * 4)
    for token in 0..<4096 {
      values[token * 4 + 1] = Float(token / 64)
      values[token * 4 + 2] = Float(token % 64)
    }
    return values
  }

  private static func textIDs() -> [Float] {
    var values = [Float](repeating: 0, count: 512 * 4)
    for token in 0..<512 { values[token * 4 + 3] = Float(token) }
    return values
  }

  private static func schedule(steps: Int) -> [Float] {
    let sequence = 4096.0
    let m200 = 0.00016927 * sequence + 0.45666666
    let m10 = 8.73809524e-05 * sequence + 1.89833333
    let a = (m200 - m10) / 190
    let mu = a * Double(steps) + (m200 - 200 * a)
    let exponential = Float(exp(mu))
    return (0..<steps).map { index in
      let raw = Float(steps - index) / Float(steps)
      return exponential / (exponential + (1 / raw - 1))
    } + [0]
  }

  private static func noise(seed: UInt64, count: Int) -> [Float] {
    // Stable host-side Gaussian seed; Core AI handles all learned computation.
    var state = seed &+ 0x9e3779b97f4a7c15
    func uniform() -> Double {
      state &+= 0x9e3779b97f4a7c15
      var value = state
      value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
      value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
      value ^= value >> 31
      return Double((value >> 11) | 1) / Double(1 << 53)
    }
    var result: [Float] = []
    result.reserveCapacity(count)
    while result.count < count {
      let radius = sqrt(-2 * log(uniform()))
      let angle = 2 * Double.pi * uniform()
      result.append(Float(radius * cos(angle)))
      if result.count < count { result.append(Float(radius * sin(angle))) }
    }
    return result
  }

  private static func vaeLatent(_ tokens: [Float], root: URL) throws -> [Float] {
    let mean = try npyFloat32(at: root.appendingPathComponent("vae_bn_mean.npy"))
    let variance = try npyFloat32(at: root.appendingPathComponent("vae_bn_var.npy"))
    guard tokens.count == 4096 * 128, mean.count == 128, variance.count == 128 else {
      throw PipelineEngineError.modelPackageUnavailable("Klein 9B VAE normalization is invalid.")
    }
    var latent = [Float](repeating: 0, count: 32 * 128 * 128)
    for row in 0..<64 {
      for column in 0..<64 {
        let tokenOffset = (row * 64 + column) * 128
        for channel in 0..<32 {
          for subRow in 0..<2 {
            for subColumn in 0..<2 {
              let sourceChannel = channel * 4 + subRow * 2 + subColumn
              let target = channel * 128 * 128 + (row * 2 + subRow) * 128
                + (column * 2 + subColumn)
              latent[target] = tokens[tokenOffset + sourceChannel]
                * sqrt(variance[sourceChannel] + 0.0001) + mean[sourceChannel]
            }
          }
        }
      }
    }
    return latent
  }

  private static func npyFloat32(at url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 10, data.prefix(6) == Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59]),
      data[6] == 1
    else { throw PipelineEngineError.modelPackageUnavailable("Invalid VAE .npy header.") }
    let headerLength = Int(data[8]) | (Int(data[9]) << 8)
    let start = 10 + headerLength
    guard start <= data.count, (data.count - start).isMultiple(of: 4),
      let header = String(data: data[10..<start], encoding: .ascii),
      header.contains("'<f4'"), header.contains("(128,)")
    else { throw PipelineEngineError.modelPackageUnavailable("Invalid VAE .npy shape or dtype.") }
    return Swift.stride(from: start, to: data.count, by: 4).map { offset in
      let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
      return Float(bitPattern: bits)
    }
  }
}

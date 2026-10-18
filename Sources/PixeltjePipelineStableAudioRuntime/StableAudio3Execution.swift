import CoreAIDiffusionPipeline
import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineResourceLinking
import Tokenizers

/// Short sound-effect generation with Stable Audio 3 Small SFX.
public enum StableAudio3Family {
  public static let nodeKind = StableAudio3Package.nodeKind
  public static let packageID = StableAudio3Package.packageID

  public static func descriptor() -> PipelineNodeDescriptor {
    PipelineNodeDescriptor(
      kind: nodeKind, displayName: "Audio Diffusion Generate", category: "Generation",
      inputs: [
        .init(name: "prompt", type: .prompt),
        .init(name: "negativePrompt", type: .prompt, isRequired: false),
        .init(name: "seed", type: .seed, isRequired: false),
      ],
      outputs: [.init(name: "audio", type: .audio)],
      parameters: [
        .init(name: "duration", valueType: .number, defaultValue: .number(2)),
        .init(name: "steps", valueType: .integer, defaultValue: .integer(8)),
        .init(name: "guidance", valueType: .number, defaultValue: .number(1)),
      ],
      requiredResourceSlots: Set(StableAudio3Package.slots.map(\.name)))
  }

  public static func makeNode(id: PipelineNodeID) -> PipelineNode {
    let resources = Dictionary(uniqueKeysWithValues: StableAudio3Package.slots.map { slot in
      let kind: PipelineResourceKind = slot.name == "tokenizer" ? .tokenizer : .coreAIModel
      let sourceName = switch slot.name {
      case "textEncoder": "t5gemma-b-b-ul2/model.safetensors"
      case "tokenizer": "t5gemma-b-b-ul2/tokenizer.json"
      default: "model.safetensors"
      }
      return (slot.name, PipelineResourceBinding.unresolved(.init(
        kind: kind, componentRole: slot.role, sourceName: sourceName,
        sourceFormat: kind == .tokenizer ? "json" : "safetensors",
        familyABI: StableAudio3Package.familyABI)))
    })
    return PipelineNode(id: id, kind: nodeKind, title: "Audio Diffusion Generate",
      parameters: ["duration": .number(2), "steps": .integer(8), "guidance": .number(1)],
      resources: resources)
  }

  public static func executor(runner: StableAudio3Runner) -> PipelineNodeExecutor {
    PipelineNodeExecutor(kind: nodeKind, validate: diagnostics) { node, inputs, context in
      guard let prompt = inputs["prompt"]?.value(as: String.self),
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PipelineEngineError.invalidInvocation("Enter a sound-effect prompt.")
      }
      let negative = inputs["negativePrompt"]?.value(as: String.self)
      let seed: UInt64
      if let input = inputs["seed"] {
        if let value = input.value(as: UInt64.self) { seed = value }
        else if let value = input.value(as: Int64.self), value >= 0 { seed = UInt64(value) }
        else if let value = input.value(as: Int.self), value >= 0 { seed = UInt64(value) }
        else { throw PipelineEngineError.invalidInvocation("Audio seed must be non-negative.") }
      } else { seed = 0 }
      guard let reference = node.resources["denoiser"]?.linkedReference else {
        throw PipelineEngineError.modelPackageUnavailable("Link a Stable Audio 3 package first.")
      }
      let audio = try await runner.generate(
        at: context.packageRoot(for: reference), node: node, prompt: prompt,
        negativePrompt: negative, seed: seed, semanticSHA256: context.semanticSHA256)
      return PipelineNodeResult(outputs: ["audio": PipelineNodeValue(audio, type: .audio)])
    }
  }

  private static func diagnostics(_ node: PipelineNode) -> [PipelineDiagnostic] {
    func invalid(_ message: String) -> PipelineDiagnostic {
      .init(severity: .error, code: .invalidParameter, message: message, nodeID: node.id)
    }
    guard case .number(let duration)? = node.parameters["duration"],
      duration.isFinite, (0.25...2).contains(duration) else {
      return [invalid("Audio duration must be between 0.25 and 2 seconds for this export.")]
    }
    guard case .integer(let steps)? = node.parameters["steps"], (1...40).contains(steps) else {
      return [invalid("Audio diffusion steps must be between 1 and 40.")]
    }
    guard case .number(let guidance)? = node.parameters["guidance"],
      guidance.isFinite, (1...10).contains(guidance) else {
      return [invalid("Audio guidance must be between 1 and 10.")]
    }
    return []
  }

  public static func defaultPackageURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "coreai-models/exports/Stable-Audio-3-Small-SFX", isDirectory: true)
  }

  public static func inspectPackage(at url: URL, for document: PipelineDocument) -> String? {
    do {
      let package = try StableAudio3Package(at: url)
      for node in document.nodes where node.kind == nodeKind {
        try package.validateLinks(in: node)
      }
      return nil
    } catch { return error.localizedDescription }
  }
}

public actor StableAudio3Runner {
  private let sampleRate = 44_100
  private let latentFrames = 88
  private let latentChannels = 256

  public init() {}

  public func generate(
    at root: URL, node: PipelineNode, prompt: String, negativePrompt: String?,
    seed: UInt64, semanticSHA256: String
  ) async throws -> PipelineGeneratedAudio {
    let package = try StableAudio3Package(at: root)
    try package.validateLinks(in: node)
    guard case .number(let duration)? = node.parameters["duration"],
      case .integer(let steps)? = node.parameters["steps"],
      case .number(let guidance)? = node.parameters["guidance"] else {
      throw PipelineEngineError.invalidInvocation("Audio generation settings are incomplete.")
    }
    try Task.checkCancellation()

    let tokenizer = try await AutoTokenizer.from(
      modelFolder: package.root.appendingPathComponent("tokenizer", isDirectory: true))
    let textModel = CoreAIDiffusionModelFunction(modelURL: package.root
      .appendingPathComponent("TextEncoder.aimodel", isDirectory: true))
    let positive = try await encode(prompt, tokenizer: tokenizer, model: textModel)
    let negative: [Float]?
    if guidance > 1, let negativePrompt, !negativePrompt.isEmpty {
      negative = try await encode(negativePrompt, tokenizer: tokenizer, model: textModel)
    } else { negative = nil }
    await textModel.unloadResources()
    try Task.checkCancellation()

    let durationModel = CoreAIDiffusionModelFunction(modelURL: package.root
      .appendingPathComponent("DurationEncoder.aimodel", isDirectory: true))
    let durationEmbedding = try await durationModel.run(floatInputs: [
      ([Float(duration)], [1])])
    await durationModel.unloadResources()
    guard durationEmbedding.count == 768, durationEmbedding.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("Audio duration encoder returned invalid data.")
    }
    let conditioning = positive + durationEmbedding
    let negativeConditioning = negative.map { $0 + durationEmbedding }
    let denoiser = CoreAIDiffusionModelFunction(modelURL: package.root
      .appendingPathComponent("Denoiser.aimodel", isDirectory: true))
    let count = latentChannels * latentFrames
    var random = GaussianNoise(seed: seed)
    var latents = (0..<count).map { _ in random.next() }
    let schedule = Self.schedule(steps: Int(steps))
    for index in 0..<Int(steps) {
      try Task.checkCancellation()
      let sigma = schedule[index]
      let next = schedule[index + 1]
      let velocity = try await predict(denoiser, latents: latents, sigma: sigma,
        conditioning: conditioning, global: durationEmbedding)
      var prediction = velocity
      if guidance > 1 {
        let unconditioned = try await predict(denoiser, latents: latents, sigma: sigma,
          conditioning: negativeConditioning ?? Array(repeating: 0, count: 257 * 768),
          global: durationEmbedding)
        // The publisher uses orthogonal APG for classifier-free guidance.
        let denoised = zip(latents, velocity).map { $0 - sigma * $1 }
        let norm = max(sqrt(denoised.reduce(0.0) { $0 + Double($1 * $1) }), 1e-8)
        var projection = 0.0
        for i in 0..<count {
          projection += Double(velocity[i] - unconditioned[i]) * Double(denoised[i]) / norm
        }
        let scale = Float(projection / norm)
        for i in 0..<count {
          let orthogonal = velocity[i] - unconditioned[i] - scale * denoised[i]
          prediction[i] += Float(guidance - 1) * orthogonal
        }
      }
      for i in 0..<count {
        let denoised = latents[i] - sigma * prediction[i]
        latents[i] = (1 - next) * denoised + next * random.next()
      }
    }
    await denoiser.unloadResources()
    try Task.checkCancellation()

    let decoder = CoreAIDiffusionModelFunction(modelURL: package.root
      .appendingPathComponent("AudioDecoder.aimodel", isDirectory: true))
    let samples = try await decoder.run(floatInputs: [(latents, [1, latentChannels, latentFrames])])
    await decoder.unloadResources()
    guard samples.count == 2 * latentFrames * 4_096, samples.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("Audio decoder returned invalid samples.")
    }
    let frames = Int((duration * Double(sampleRate)).rounded())
    let outputDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PixeltjePipelineAudio", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let output = outputDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try Self.writeWAV(samples, frames: frames, sampleRate: sampleRate, to: output)
    return PipelineGeneratedAudio(fileURL: output, semanticPipelineSHA256: semanticSHA256)
  }

  private func encode(
    _ prompt: String, tokenizer: any Tokenizer, model: CoreAIDiffusionModelFunction
  ) async throws -> [Float] {
    var ids = Array(tokenizer.encode(text: prompt).prefix(256)).map(Int32.init)
    let valid = ids.count
    let pad = Int32(tokenizer.convertTokenToId("<pad>") ?? 0)
    ids += Array(repeating: pad, count: 256 - valid)
    let mask = (0..<256).map { $0 < valid ? Int32(1) : 0 }
    let result = try await model.run(intInputs: [(ids, [1, 256]), (mask, [1, 256])])
    guard result.count == 256 * 768, result.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("Audio text encoder returned invalid conditioning.")
    }
    return result
  }

  private func predict(
    _ model: CoreAIDiffusionModelFunction, latents: [Float], sigma: Float,
    conditioning: [Float], global: [Float]
  ) async throws -> [Float] {
    let velocity = try await model.run(floatInputs: [
      (latents, [1, latentChannels, latentFrames]),
      ([sigma], [1]),
      (conditioning, [1, 257, 768]),
      (global, [1, 768]),
    ])
    guard velocity.count == latents.count, velocity.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed("Audio denoiser returned invalid latents.")
    }
    return velocity
  }

  private static func schedule(steps: Int) -> [Float] {
    (0...steps).map { index in
      if index == 0 { return 1 }
      if index == steps { return 0 }
      let t = 1 - Double(index) / Double(steps)
      return Float(1 / (1 + exp(2 - t * 8.2)))
    }
  }

  private static func writeWAV(_ samples: [Float], frames: Int, sampleRate: Int, to url: URL) throws {
    let channelFrames = samples.count / 2
    var data = Data(capacity: 44 + frames * 4)
    func word(_ value: UInt16) {
      data.append(UInt8(truncatingIfNeeded: value))
      data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    func dword(_ value: UInt32) {
      word(UInt16(truncatingIfNeeded: value))
      word(UInt16(truncatingIfNeeded: value >> 16))
    }
    data.append(contentsOf: "RIFF".utf8)
    dword(UInt32(36 + frames * 4))
    data.append(contentsOf: "WAVEfmt ".utf8)
    dword(16)
    word(1)
    word(2)
    dword(UInt32(sampleRate))
    dword(UInt32(sampleRate * 4))
    word(4)
    word(16)
    data.append(contentsOf: "data".utf8)
    dword(UInt32(frames * 4))
    for frame in 0..<frames {
      for channel in 0..<2 {
        let sample = max(-1, min(1, samples[channel * channelFrames + frame]))
        let pcm = Int16((sample * 32_767).rounded())
        word(UInt16(bitPattern: pcm))
      }
    }
    try data.write(to: url, options: .atomic)
  }
}

private struct GaussianNoise {
  private var state: UInt64
  private var spare: Float?

  init(seed: UInt64) { state = seed }

  private mutating func uniform() -> Double {
    state &+= 0x9E3779B97F4A7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
    value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
    value ^= value >> 31
    return Double((value >> 11) + 1) / Double(1 << 53)
  }

  mutating func next() -> Float {
    if let spare { self.spare = nil; return spare }
    let radius = sqrt(-2 * log(uniform()))
    let angle = 2 * Double.pi * uniform()
    spare = Float(radius * sin(angle))
    return Float(radius * cos(angle))
  }
}

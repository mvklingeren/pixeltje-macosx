import CoreAI
import Foundation
import Metal
import OSLog
import PixeltjeMacDomain
import Tokenizers

/// Host-side Z-Image Turbo scheduler and Core AI function coordinator.
///
/// Learned computation never leaves Core AI. Swift owns only token/mask
/// preparation, RoPE lookup, patch layout, seeded noise, and sampling.
public actor ZImageCoreAIPipeline {
  public enum SamplerAlgorithm: String, Equatable, Sendable {
    case euler
    case resMultistep = "res_multistep"
  }

  public enum SchedulerAlgorithm: String, Equatable, Sendable {
    case flowMatch
    case simple
  }

  public enum NegativeConditioning: Equatable, Sendable {
    case prompt(String)
    case zero
  }

  public enum GuidanceFormula: Equatable, Sendable {
    /// The formula retained by the original dedicated Z-Image adapter.
    case zImageDifference
    /// ComfyUI KSampler CFG: negative + scale * (positive - negative).
    case classifierFree
  }

  public enum LoadDisposition: Equatable, Sendable {
    case loaded
    case reused
  }

  public struct StepOutput: Sendable {
    public var step: Int
    public var totalSteps: Int
    public var width: Int
    public var height: Int
    /// Decoder output in planar RGB, publisher range -1...1.
    public var decodedRGB: [Float]
  }

  public struct ModelResolution: Hashable, Sendable {
    public static let supportedPixels = 512...2048
    public static let pixelMultiple = 16

    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
      guard Self.supportedPixels.contains(width), Self.supportedPixels.contains(height),
        width.isMultiple(of: Self.pixelMultiple), height.isMultiple(of: Self.pixelMultiple)
      else { return nil }
      self.width = width
      self.height = height
    }

    public static let square512 = ModelResolution(width: 512, height: 512)!

    public var latentWidth: Int { width / 8 }
    public var latentHeight: Int { height / 8 }
    public var tokenWidth: Int { width / 16 }
    public var tokenHeight: Int { height / 16 }
    public var imageTokenCount: Int { tokenWidth * tokenHeight }
    public var componentSuffix: String { width == height ? String(width) : "\(width)x\(height)" }
  }

  public typealias Preview = @Sendable (StepOutput) async throws -> Void

  public static let modelIdentity = CoreAIModelPackageIdentity(
    provider: "coreai.z-image",
    model: "z-image-turbo",
    modelRevision: "f332072aa78be7aecdf3ee76d5c247082da564a6",
    hostPipelineRevision: "native-resolution-512-2048-v2",
    functions: [
      .init(
        role: "promptEncoder",
        packageName: "zimage_encoder_seq64_full_bf16_ids_iofp32.aimodel",
        declaredContentHash: "0ac88fa5d25b77875d005015e955df4b5cd259c9bf6c0554aac8aad32dae8b34"),
      .init(
        role: "denoiser",
        packageName: "zimage_dit_512_cap32_full_native_bf16_dyncap_dynimg_iofp32.aimodel",
        declaredContentHash: "cfbb51aee0c244541dcc4e7b6cb3cc5a0701a664a178807dd97af5b8acfaedf9"),
      .init(
        role: "timestepEmbedder",
        packageName: "glue/zimage_t_embedder_fp32/zimage_t_embedder_fp32.aimodel",
        declaredContentHash: "cedac6488d1a7b2279242d47619068bd98a758a629c4d51b506976b988089c46"),
      .init(
        role: "vaeEncoder",
        packageName: "zimage_vae_encoder_dynamic_512-2048_fp32.aimodel"),
      .init(
        role: "vaeDecoder",
        packageName: "zimage_vae_512_fp32.aimodel",
        declaredContentHash: "1b0d9b9e05adcf2d1a6d0cc1321f38e62b322bb1973f30c6e1cee826cb8a387d"),
    ]
  )

  public static func modelIdentity(
    for mode: GenerationMode,
    resolution: ModelResolution = .square512
  ) -> CoreAIModelPackageIdentity {
    var identity = modelIdentity
    identity.functions.removeAll { $0.role == "vaeDecoder" }
    identity.functions.append(Self.vaeDecoderIdentity(for: resolution))
    if resolution.imageTokenCount > 4096 {
      identity.functions.removeAll { $0.role == "denoiser" }
      identity.functions.append(Self.denoiserIdentity(for: resolution))
    }
    guard mode == .textToImage else { return identity }
    identity.functions.removeAll { $0.role == "vaeEncoder" }
    return identity
  }

  public static func modelResolution(outputWidth: Int, outputHeight: Int) -> ModelResolution? {
    ModelResolution(width: outputWidth, height: outputHeight)
  }

  public static func vaeDecoderIdentity(
    for resolution: ModelResolution
  ) -> CoreAIModelPackageIdentity.Function {
    let knownHash: String? = switch (resolution.width, resolution.height) {
    case (512, 512): "1b0d9b9e05adcf2d1a6d0cc1321f38e62b322bb1973f30c6e1cee826cb8a387d"
    case (1024, 1024): "7e46df0aa524108720a7c5bdae4561f3a5b12fc1956e16fc46c41d363f6c5e92"
    default: nil
    }
    return .init(
      role: "vaeDecoder",
      packageName: "zimage_vae_\(resolution.componentSuffix)_fp32.aimodel",
      declaredContentHash: knownHash)
  }

  public static func denoiserIdentity(
    for resolution: ModelResolution
  ) -> CoreAIModelPackageIdentity.Function {
    if resolution.imageTokenCount <= 4096 {
      return modelIdentity.functions.first { $0.role == "denoiser" }!
    }
    return .init(
      role: "denoiser",
      packageName: "zimage_dit_2048_cap32_full_native_bf16_dyncap_dynimg_iofp32.aimodel")
  }

  private struct LoadedFunction {
    /// Keep the package object alive for exactly as long as its loaded
    /// function. This makes the Core AI residency contract explicit instead
    /// of relying on the function retaining its originating model internally.
    var model: AIModel
    var function: InferenceFunction
    var descriptor: InferenceFunctionDescriptor
  }

  private let stream: ComputeStream
  private let logger = Logger(
    subsystem: "org.pixeltje.PixeltjeMacApp", category: "z-image-coreai")
  private var modelDirectory: URL?
  private var denoisers: [String: LoadedFunction] = [:]
  private var promptEncoder: LoadedFunction?
  private var timestepEmbedder: LoadedFunction?
  private var vaeEncoder: LoadedFunction?
  private var vaeDecoders: [ModelResolution: LoadedFunction] = [:]
  private var tokenizer: (any Tokenizer)?
  /// rope[axis][row][frequency] = (cos, sin)
  private var rope: [[[SIMD2<Float>]]] = []

  private let latentChannels = 16
  private let encoderLength = 64
  private let captionMultiple = 32
  private let ropeFrequencyCount = 64

  public init(commandQueue: any MTLCommandQueue) {
    stream = ComputeStream(commandQueue: commandQueue)
  }

  public func isLoaded(
    from packageRoot: URL,
    resolution: ModelResolution = .square512,
    mode: GenerationMode = .inpainting
  ) -> Bool {
    let resources = Self.resourcesDirectory(in: packageRoot)
    let denoiserName = Self.denoiserIdentity(for: resolution).packageName
    return modelDirectory?.standardizedFileURL == resources.standardizedFileURL
      && denoisers[denoiserName] != nil && promptEncoder != nil && timestepEmbedder != nil
      && (mode == .textToImage || vaeEncoder != nil)
      && vaeDecoders[resolution] != nil && tokenizer != nil && !rope.isEmpty
  }

  @discardableResult
  public func load(
    from packageRoot: URL,
    resolution: ModelResolution = .square512,
    mode: GenerationMode = .inpainting
  ) async throws -> LoadDisposition {
    let resources = Self.resourcesDirectory(in: packageRoot)
    if isLoaded(from: packageRoot, resolution: resolution, mode: mode) {
      logger.debug("Reusing loaded Z-Image Core AI functions")
      return .reused
    }
    if modelDirectory?.standardizedFileURL != resources.standardizedFileURL {
      denoisers = [:]
      promptEncoder = nil
      timestepEmbedder = nil
      vaeEncoder = nil
      vaeDecoders = [:]
      tokenizer = nil
      rope = []
      modelDirectory = resources
    }
    let startedAt = Date()
    logger.info("Loading Z-Image Core AI functions and tokenizer")
    do {
      let denoiserName = Self.denoiserIdentity(for: resolution).packageName
      if denoisers[denoiserName] == nil {
        denoisers[denoiserName] = try await Self.loadFunction(
          resources.appendingPathComponent(denoiserName))
        logger.debug("Loaded Z-Image denoiser")
      }
      if promptEncoder == nil {
        promptEncoder = try await Self.loadFunction(
          resources.appendingPathComponent(
            "zimage_encoder_seq64_full_bf16_ids_iofp32.aimodel"))
        logger.debug("Loaded Z-Image prompt encoder")
      }
      if timestepEmbedder == nil {
        timestepEmbedder = try await Self.loadFunction(
          resources.appendingPathComponent(
            "glue/zimage_t_embedder_fp32/zimage_t_embedder_fp32.aimodel"))
        logger.debug("Loaded Z-Image timestep embedder")
      }
      if mode != .textToImage, vaeEncoder == nil {
        vaeEncoder = try await Self.loadFunction(
          resources.appendingPathComponent(
            "zimage_vae_encoder_dynamic_512-2048_fp32.aimodel"))
        logger.debug("Loaded Z-Image VAE encoder")
      }
      if vaeDecoders[resolution] == nil {
        let decoderName = Self.vaeDecoderIdentity(for: resolution).packageName
        vaeDecoders[resolution] = try await Self.loadFunction(
          resources.appendingPathComponent(decoderName))
        logger.debug(
          "Loaded Z-Image \(resolution.width, privacy: .public)x\(resolution.height, privacy: .public) VAE decoder"
        )
      }
      if tokenizer == nil {
        tokenizer = try await AutoTokenizer.from(
          modelFolder: resources.appendingPathComponent("tokenizer"))
      }
      if rope.isEmpty {
        rope = try Self.loadRope(from: resources.appendingPathComponent("glue"))
      }
      logger.info(
        "Loaded Z-Image Core AI pipeline in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3)) seconds"
      )
      return .loaded
    } catch {
      logger.error("Failed to load Z-Image Core AI pipeline: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  /// Generates from seeded noise without constructing or encoding a source
  /// image. This is the blank-canvas path.
  public func textToImage(
    prompt: String,
    negativePrompt: String,
    seed: UInt64,
    steps: Int,
    guidance: Float,
    resolution: ModelResolution = .square512,
    sampler: SamplerAlgorithm = .euler,
    scheduler: SchedulerAlgorithm = .flowMatch,
    flowShift: Float = 3,
    negativeConditioning: NegativeConditioning? = nil,
    guidanceFormula: GuidanceFormula = .zImageDifference,
    preview: Preview
  ) async throws -> [Float] {
    try Task.checkCancellation()
    guard vaeDecoders[resolution] != nil else {
      throw Self.error(
        "The Core AI package has no \(resolution.width)x\(resolution.height) VAE decoder loaded."
      )
    }
    let totalSteps = min(max(steps, 1), 20)
    let noise = Self.noise(
      count: latentChannels * resolution.latentWidth * resolution.latentHeight,
      seed: seed)
    let conditioned = try await encodePrompt(prompt)
    let resolvedNegative = negativeConditioning ?? .prompt(negativePrompt)
    let unconditioned: [[Float]] = switch resolvedNegative {
    case .prompt(let text): try await encodePrompt(text)
    case .zero: conditioned.map { [Float](repeating: 0, count: $0.count) }
    }
    logger.info(
      "Starting Z-Image text-to-image seed=\(seed, privacy: .public) steps=\(totalSteps, privacy: .public) guidance=\(guidance, privacy: .public) promptCharacters=\(prompt.count, privacy: .public) negativePromptCharacters=\(negativePrompt.count, privacy: .public)"
    )
    return try await denoise(
      initialLatent: noise,
      sourceLatent: nil,
      noise: noise,
      latentMask: nil,
      conditioned: conditioned,
      unconditioned: unconditioned,
      firstStep: 0,
      totalSteps: totalSteps,
      guidance: guidance,
      resolution: resolution,
      sampler: sampler,
      scheduler: scheduler,
      flowShift: flowShift,
      guidanceFormula: guidanceFormula,
      preview: preview)
  }

  /// Runs genuine image-conditioned masked latent denoising.
  ///
  /// `sourceRGB` is planar RGB in the VAE's -1...1 range. `mask` is coverage
  /// in row-major model-image order. After each Euler update, unselected latent
  /// cells are restored from the source latent at the next scheduler sigma.
  public func inpaint(
    sourceRGB: [Float],
    mask: [Float],
    prompt: String,
    negativePrompt: String,
    seed: UInt64,
    steps: Int,
    guidance: Float,
    strength: Float,
    resolution: ModelResolution = .square512,
    preview: Preview
  ) async throws -> [Float] {
    try Task.checkCancellation()
    guard sourceRGB.count == 3 * resolution.width * resolution.height,
      mask.count == resolution.width * resolution.height
    else {
      throw Self.error(
        "The prepared source or mask has the wrong \(resolution.width)x\(resolution.height) shape."
      )
    }
    guard let vaeEncoder else { throw Self.error("The Core AI VAE encoder is not loaded.") }

    let sourceLatent = try await run(
      vaeEncoder,
      inputs: [
        "image": try array(
          sourceRGB,
          shape: [1, 3, resolution.height, resolution.width],
          scalarType: .float32)
      ],
      output: "z")
    let latentCount = latentChannels * resolution.latentWidth * resolution.latentHeight
    guard sourceLatent.count == latentCount else {
      throw Self.error("The Core AI VAE encoder returned an unexpected latent shape.")
    }

    let latentMask = Self.downsampleMask(
      mask,
      sourceWidth: resolution.width,
      sourceHeight: resolution.height,
      destinationWidth: resolution.latentWidth,
      destinationHeight: resolution.latentHeight)
    let noise = Self.noise(count: latentCount, seed: seed)
    let conditioned = try await encodePrompt(prompt)
    let unconditioned = try await encodePrompt(negativePrompt)
    let totalSteps = min(max(steps, 1), 20)
    let activeCount = max(1, Int((Float(totalSteps) * min(max(strength, 0), 1)).rounded()))
    let firstStep = totalSteps - activeCount
    let initialSigma = Self.sigma(firstStep, totalSteps)
    let latent = zip(sourceLatent, noise).map {
      (1 - initialSigma) * $0.0 + initialSigma * $0.1
    }
    logger.info(
      "Starting Z-Image denoise seed=\(seed, privacy: .public) requestedSteps=\(totalSteps, privacy: .public) activeSteps=\(activeCount, privacy: .public) guidance=\(guidance, privacy: .public) strength=\(strength, privacy: .public) promptCharacters=\(prompt.count, privacy: .public) negativePromptCharacters=\(negativePrompt.count, privacy: .public)"
    )

    return try await denoise(
      initialLatent: latent,
      sourceLatent: sourceLatent,
      noise: noise,
      latentMask: latentMask,
      conditioned: conditioned,
      unconditioned: unconditioned,
      firstStep: firstStep,
      totalSteps: totalSteps,
      guidance: guidance,
      resolution: resolution,
      sampler: .euler,
      scheduler: .flowMatch,
      flowShift: 3,
      guidanceFormula: .zImageDifference,
      preview: preview)
  }

  private func denoise(
    initialLatent: [Float],
    sourceLatent: [Float]?,
    noise: [Float],
    latentMask: [Float]?,
    conditioned: [[Float]],
    unconditioned: [[Float]],
    firstStep: Int,
    totalSteps: Int,
    guidance: Float,
    resolution: ModelResolution,
    sampler: SamplerAlgorithm,
    scheduler: SchedulerAlgorithm,
    flowShift: Float,
    guidanceFormula: GuidanceFormula,
    preview: Preview
  ) async throws -> [Float] {
    var latent = initialLatent
    let latentPlane = resolution.latentWidth * resolution.latentHeight
    let activeCount = totalSteps - firstStep
    let sigmas = Self.sigmaSchedule(
      steps: totalSteps, scheduler: scheduler, flowShift: flowShift)
    var oldDenoised: [Float]?
    var oldSigmaDown: Float?
    for step in firstStep..<totalSteps {
      try Task.checkCancellation()
      let sigma = sigmas[step]
      let nextSigma = sigmas[step + 1]
      let adaln = try await embedTimestep(1 - sigma)
      let imageTokens = Self.patchify(
        latent, width: resolution.latentWidth, height: resolution.latentHeight)
      let positive = try await velocity(
        imageTokens: imageTokens,
        tokenWidth: resolution.tokenWidth,
        tokenHeight: resolution.tokenHeight,
        caption: conditioned,
        adaln: adaln,
        resolution: resolution)
      var prediction = positive
      let needsNegative = switch guidanceFormula {
      case .zImageDifference: guidance > 0
      case .classifierFree: guidance != 1
      }
      if needsNegative {
        let negative = try await velocity(
          imageTokens: imageTokens,
          tokenWidth: resolution.tokenWidth,
          tokenHeight: resolution.tokenHeight,
          caption: unconditioned,
          adaln: adaln,
          resolution: resolution)
        for index in prediction.indices {
          switch guidanceFormula {
          case .zImageDifference:
            prediction[index] = positive[index] + guidance * (positive[index] - negative[index])
          case .classifierFree:
            prediction[index] = negative[index] + guidance * (positive[index] - negative[index])
          }
        }
      }
      let velocity = Self.unpatchify(
        prediction, width: resolution.latentWidth, height: resolution.latentHeight)
      let denoised = zip(latent, velocity).map { $0 + sigma * $1 }
      switch sampler {
      case .euler:
        latent = Self.eulerStep(
          latent: latent, denoised: denoised, sigma: sigma, nextSigma: nextSigma)
      case .resMultistep:
        latent = Self.resMultistepStep(
          latent: latent,
          denoised: denoised,
          oldDenoised: oldDenoised,
          sigma: sigma,
          nextSigma: nextSigma,
          previousSigma: step > 0 ? sigmas[step - 1] : nil,
          oldSigmaDown: oldSigmaDown)
      }
      oldDenoised = denoised
      oldSigmaDown = nextSigma
      for index in latent.indices {
        if let sourceLatent, let latentMask {
          let sourceAtNextSigma =
            (1 - nextSigma) * sourceLatent[index] + nextSigma * noise[index]
          let coverage = latentMask[index % latentPlane]
          latent[index] = coverage * latent[index] + (1 - coverage) * sourceAtNextSigma
        }
      }

      let decoded = try await decode(latent, resolution: resolution)
      try await preview(
        StepOutput(
          step: step - firstStep + 1,
          totalSteps: activeCount,
          width: resolution.width,
          height: resolution.height,
          decodedRGB: decoded
        ))
      logger.debug(
        "Completed Z-Image denoise step \(step - firstStep + 1, privacy: .public) of \(activeCount, privacy: .public)"
      )
    }
    let output = try await decode(latent, resolution: resolution)
    logger.info("Finished Z-Image denoise and final VAE decode")
    return output
  }

  private func encodePrompt(_ text: String) async throws -> [[Float]] {
    guard let promptEncoder, let tokenizer else {
      throw Self.error("The Core AI prompt encoder is not loaded.")
    }
    var ids = try tokenizer.applyChatTemplate(
      messages: [["role": "user", "content": text]],
      chatTemplate: nil,
      addGenerationPrompt: true,
      truncation: false,
      maxLength: nil,
      tools: nil
    )
    guard ids.count <= encoderLength else {
      throw Self.error(
        "The prompt is \(ids.count) tokens; this Core AI encoder supports \(encoderLength).")
    }
    let validCount = ids.count
    ids += Array(repeating: tokenizer.unknownTokenId ?? 0, count: encoderLength - ids.count)
    let negativeInfinity = -Float.greatestFiniteMagnitude / 2
    var attentionMask = [Float](repeating: 0, count: encoderLength * encoderLength)
    for query in 0..<encoderLength {
      for key in 0..<encoderLength where key > query || key >= validCount {
        attentionMask[query * encoderLength + key] = negativeInfinity
      }
    }
    let hidden = try await run(
      promptEncoder,
      inputs: [
        "input_ids": try array(
          ids.map(Int32.init), shape: [1, encoderLength], scalarType: .int32),
        "mask": try array(
          attentionMask, shape: [1, 1, encoderLength, encoderLength], scalarType: .float32),
      ],
      output: "penultimate")
    return (0..<validCount).map { row in
      Array(hidden[(row * 2560)..<((row + 1) * 2560)])
    }
  }

  private func embedTimestep(_ timestep: Float) async throws -> [Float] {
    guard let timestepEmbedder else {
      throw Self.error("The Core AI timestep embedder is not loaded.")
    }
    return try await run(
      timestepEmbedder,
      inputs: [
        "timestep": try array([timestep], shape: [1], scalarType: .float32)
      ],
      output: "adaln")
  }

  private func velocity(
    imageTokens: [Float],
    tokenWidth: Int,
    tokenHeight: Int,
    caption: [[Float]],
    adaln: [Float],
    resolution: ModelResolution
  ) async throws -> [Float] {
    let denoiserName = Self.denoiserIdentity(for: resolution).packageName
    guard let denoiser = denoisers[denoiserName] else {
      throw Self.error("The Core AI denoiser is not loaded.")
    }
    let imageCount = tokenWidth * tokenHeight
    guard tokenWidth == resolution.tokenWidth,
      tokenHeight == resolution.tokenHeight,
      imageTokens.count == imageCount * 64
    else {
      throw Self.error("The prepared image-token sequence has an unexpected shape.")
    }
    let validCaptionCount = caption.count
    let captionCount = max(
      captionMultiple,
      ((validCaptionCount + captionMultiple - 1) / captionMultiple) * captionMultiple)
    var captionValues = [Float](repeating: 0, count: captionCount * 2560)
    for row in 0..<validCaptionCount {
      captionValues.replaceSubrange(row * 2560..<(row + 1) * 2560, with: caption[row])
    }
    var captionPadding = [Float](repeating: 0, count: captionCount)
    if validCaptionCount < captionCount {
      for index in validCaptionCount..<captionCount { captionPadding[index] = 1 }
    }

    var captionCos: [Float] = []
    var captionSin: [Float] = []
    captionCos.reserveCapacity(captionCount * ropeFrequencyCount)
    captionSin.reserveCapacity(captionCount * ropeFrequencyCount)
    for index in 0..<captionCount {
      appendRope(cos: &captionCos, sin: &captionSin, time: index + 1, row: 0, column: 0)
    }
    var imageCos: [Float] = []
    var imageSin: [Float] = []
    imageCos.reserveCapacity(imageCount * ropeFrequencyCount)
    imageSin.reserveCapacity(imageCount * ropeFrequencyCount)
    for row in 0..<tokenHeight {
      for column in 0..<tokenWidth {
        appendRope(
          cos: &imageCos,
          sin: &imageSin,
          time: captionCount + 1,
          row: row,
          column: column)
      }
    }

    let output = try await run(
      denoiser,
      inputs: [
        "img_tokens": try array(
          imageTokens, shape: [1, imageCount, 64], scalarType: .float32),
        "cap_feats": try array(
          captionValues, shape: [1, captionCount, 2560], scalarType: .float32),
        "adaln": try array(adaln, shape: [1, 256], scalarType: .float32),
        "x_cos": try array(
          imageCos, shape: [1, imageCount, ropeFrequencyCount], scalarType: .float32),
        "x_sin": try array(
          imageSin, shape: [1, imageCount, ropeFrequencyCount], scalarType: .float32),
        "cap_cos": try array(
          captionCos, shape: [1, captionCount, ropeFrequencyCount], scalarType: .float32),
        "cap_sin": try array(
          captionSin, shape: [1, captionCount, ropeFrequencyCount], scalarType: .float32),
        "x_pad_mask": try array(
          [Float](repeating: 0, count: imageCount),
          shape: [1, imageCount, 1], scalarType: .float32),
        "cap_pad_mask": try array(
          captionPadding, shape: [1, captionCount, 1], scalarType: .float32),
      ],
      output: "velocity")
    return Array(output.prefix(imageCount * 64))
  }

  private func decode(
    _ latent: [Float],
    resolution: ModelResolution
  ) async throws -> [Float] {
    guard let vaeDecoder = vaeDecoders[resolution] else {
      throw Self.error(
        "The Core AI \(resolution.width)x\(resolution.height) VAE decoder is not loaded.")
    }
    return try await run(
      vaeDecoder,
      inputs: [
        "z": try array(
          latent,
          shape: [1, latentChannels, resolution.latentHeight, resolution.latentWidth],
          scalarType: .float32)
      ],
      output: "image")
  }

  /// Schedules a learned function onto the render engine's ComputeStream and
  /// reads the named result only after Core AI signals that value is ready.
  private func run<T: BitwiseCopyable>(
    _ loaded: LoadedFunction,
    inputs: [String: (values: [T], shape: [Int], scalarType: NDArray.ScalarType)],
    output: String
  ) async throws -> [Float] {
    var arrays: [String: NDArray] = [:]
    for (name, value) in inputs {
      arrays[name] = try array(value.values, shape: value.shape, scalarType: value.scalarType)
    }
    return try await run(loaded, inputs: arrays, output: output)
  }

  private func run(
    _ loaded: LoadedFunction,
    inputs: [String: NDArray],
    output: String
  ) async throws -> [Float] {
    var values: [String: InferenceFunction.AsyncValue] = [:]
    for (name, array) in inputs {
      values[name] = InferenceFunction.AsyncValue(array)
    }
    let outputs = try loaded.function.encode(inputs: values, to: stream)
    guard let asyncOutput = outputs[output], let result = try await asyncOutput.ndArray else {
      throw Self.error("Core AI did not return \(output).")
    }
    try Task.checkCancellation()
    return try Self.floats(result)
  }

  private func array<T: BitwiseCopyable>(
    _ values: [T],
    shape: [Int],
    scalarType: NDArray.ScalarType
  ) throws -> NDArray {
    guard shape.reduce(1, *) == values.count else {
      throw Self.error("Core AI input data does not match its declared shape.")
    }
    var result = NDArray(shape: shape, scalarType: scalarType)
    var view = result.mutableView(as: T.self)
    view.copyElements(fromContentsOf: values)
    return result
  }

  private func appendRope(
    cos: inout [Float],
    sin: inout [Float],
    time: Int,
    row: Int,
    column: Int
  ) {
    for (axis, index) in [(0, time), (1, row), (2, column)] {
      for pair in rope[axis][index] {
        cos.append(pair.x)
        sin.append(pair.y)
      }
    }
  }

  private static func resourcesDirectory(in root: URL) -> URL {
    let resources = root.appendingPathComponent("Resources", isDirectory: true)
    return FileManager.default.fileExists(atPath: resources.path) ? resources : root
  }

  private static func loadFunction(_ url: URL) async throws -> LoadedFunction {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw error("The linked Core AI package is missing \(url.lastPathComponent).")
    }
    let model = try await AIModel(
      contentsOf: url.resolvingSymlinksInPath(), options: .default)
    guard let descriptor = model.functionDescriptor(for: "main") else {
      throw error("The Core AI package \(url.lastPathComponent) has no main function.")
    }
    try validateDescriptor(descriptor, modelURL: url)
    guard let function = try model.loadFunction(named: "main") else {
      throw error("The Core AI package \(url.lastPathComponent) could not load its main function.")
    }
    return LoadedFunction(model: model, function: function, descriptor: descriptor)
  }

  private static func validateDescriptor(
    _ descriptor: InferenceFunctionDescriptor,
    modelURL: URL
  ) throws {
    let name = modelURL.lastPathComponent
    let expectedRanks: [String: Int]
    if name.hasPrefix("zimage_dit_") {
      expectedRanks = [
        "img_tokens": 3, "cap_feats": 3, "adaln": 2,
        "x_cos": 3, "x_sin": 3, "cap_cos": 3, "cap_sin": 3,
        "x_pad_mask": 3, "cap_pad_mask": 3,
      ]
    } else if name.hasPrefix("zimage_encoder_") {
      expectedRanks = ["input_ids": 2, "mask": 4]
    } else if name.hasPrefix("zimage_t_embedder_") {
      expectedRanks = ["timestep": 1]
    } else if name.hasPrefix("zimage_vae_") {
      expectedRanks = [name.contains("encoder") ? "image" : "z": 4]
    } else {
      return
    }
    guard Set(descriptor.inputNames) == Set(expectedRanks.keys) else {
      throw error(
        "Core AI model \(name) has main inputs \(descriptor.inputNames.sorted()); expected \(expectedRanks.keys.sorted())."
      )
    }
    for (inputName, expectedRank) in expectedRanks {
      guard case .ndArray(let input) = descriptor.inputDescriptor(of: inputName) else {
        throw error("Core AI model \(name) input \(inputName) is not an NDArray.")
      }
      guard input.shape.count == expectedRank else {
        throw error(
          "Core AI model \(name) input \(inputName) has rank \(input.shape.count); expected rank \(expectedRank)."
        )
      }
    }
  }

  private static func loadRope(from directory: URL) throws -> [[[SIMD2<Float>]]] {
    struct Axis: Decodable {
      var rows: Int
      var freqs: Int
    }
    struct Metadata: Decodable { var axes: [Axis] }
    let metadata = try JSONDecoder().decode(
      Metadata.self,
      from: Data(contentsOf: directory.appendingPathComponent("rope_meta.json")))
    return try metadata.axes.enumerated().map { axisIndex, axis in
      let data = try Data(
        contentsOf: directory.appendingPathComponent("rope_axis\(axisIndex).f32"))
      let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
      guard values.count == axis.rows * axis.freqs * 2 else {
        throw error("The linked Z-Image RoPE table has an invalid shape.")
      }
      return (0..<axis.rows).map { row in
        (0..<axis.freqs).map { frequency in
          let offset = (row * axis.freqs + frequency) * 2
          return SIMD2(values[offset], values[offset + 1])
        }
      }
    }
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
      throw error("Core AI returned unsupported scalar type \(array.scalarType).")
    }
  }

  public static func sigma(_ index: Int, _ count: Int) -> Float {
    if index >= count { return 0 }
    let t = Float(index) / Float(max(count, 1))
    return 3 * (1 - t) / (3 * (1 - t) + t)
  }

  public static func sigmaSchedule(
    steps: Int,
    scheduler: SchedulerAlgorithm,
    flowShift: Float = 3
  ) -> [Float] {
    let steps = max(steps, 1)
    let shift = max(flowShift, Float.leastNonzeroMagnitude)
    let values: [Float] = (0..<steps).map { index in
      switch scheduler {
      case .flowMatch:
        let t = Float(index) / Float(steps)
        return shift * (1 - t) / (shift * (1 - t) + t)
      case .simple:
        let tableIndex = 999 - Int(Float(index) * 1000 / Float(steps))
        let base = Float(max(tableIndex + 1, 1)) / 1000
        return shift * base / (1 + (shift - 1) * base)
      }
    }
    return values + [0]
  }

  public static func eulerStep(
    latent: [Float],
    denoised: [Float],
    sigma: Float,
    nextSigma: Float
  ) -> [Float] {
    guard sigma > 0, latent.count == denoised.count else { return latent }
    let delta = nextSigma - sigma
    return zip(latent, denoised).map { value, clean in
      value + ((value - clean) / sigma) * delta
    }
  }

  public static func resMultistepStep(
    latent: [Float],
    denoised: [Float],
    oldDenoised: [Float]?,
    sigma: Float,
    nextSigma: Float,
    previousSigma: Float?,
    oldSigmaDown: Float?
  ) -> [Float] {
    guard sigma > 0, latent.count == denoised.count else { return latent }
    guard nextSigma > 0,
      let oldDenoised,
      oldDenoised.count == latent.count,
      let previousSigma,
      previousSigma > 0,
      let oldSigmaDown,
      oldSigmaDown > 0
    else {
      return eulerStep(
        latent: latent, denoised: denoised, sigma: sigma, nextSigma: nextSigma)
    }

    let t = -log(sigma)
    let tOld = -log(oldSigmaDown)
    let tNext = -log(nextSigma)
    let tPrevious = -log(previousSigma)
    let h = tNext - t
    guard h.isFinite, abs(h) > Float.ulpOfOne else { return latent }
    let c2 = (tPrevious - tOld) / h
    guard c2.isFinite, abs(c2) > Float.ulpOfOne else {
      return eulerStep(
        latent: latent, denoised: denoised, sigma: sigma, nextSigma: nextSigma)
    }
    func phi1(_ value: Float) -> Float { expm1(value) / value }
    func phi2(_ value: Float) -> Float { (phi1(value) - 1) / value }
    let p1 = phi1(-h)
    let p2 = phi2(-h)
    let b1 = p1 - p2 / c2
    let b2 = p2 / c2
    let decay = exp(-h)
    return latent.indices.map { index in
      decay * latent[index]
        + h * (b1 * denoised[index] + b2 * oldDenoised[index])
    }
  }

  public static func patchify(_ latent: [Float], width: Int, height: Int) -> [Float] {
    precondition(width.isMultiple(of: 2) && height.isMultiple(of: 2))
    precondition(latent.count == 16 * width * height)
    let tokenWidth = width / 2
    let tokenHeight = height / 2
    let plane = width * height
    var result = [Float](repeating: 0, count: tokenWidth * tokenHeight * 64)
    for row in 0..<tokenHeight {
      for column in 0..<tokenWidth {
        let token = row * tokenWidth + column
        for deltaRow in 0..<2 {
          for deltaColumn in 0..<2 {
            let feature = (deltaRow * 2 + deltaColumn) * 16
            let y = 2 * row + deltaRow
            let x = 2 * column + deltaColumn
            for channel in 0..<16 {
              result[token * 64 + feature + channel] =
                latent[channel * plane + y * width + x]
            }
          }
        }
      }
    }
    return result
  }

  public static func patchify(_ latent: [Float], side: Int) -> [Float] {
    patchify(latent, width: side, height: side)
  }

  public static func unpatchify(_ tokens: [Float], width: Int, height: Int) -> [Float] {
    precondition(width.isMultiple(of: 2) && height.isMultiple(of: 2))
    let tokenWidth = width / 2
    let tokenHeight = height / 2
    precondition(tokens.count == tokenWidth * tokenHeight * 64)
    let plane = width * height
    var result = [Float](repeating: 0, count: 16 * plane)
    for row in 0..<tokenHeight {
      for column in 0..<tokenWidth {
        let token = row * tokenWidth + column
        for deltaRow in 0..<2 {
          for deltaColumn in 0..<2 {
            let feature = (deltaRow * 2 + deltaColumn) * 16
            let y = 2 * row + deltaRow
            let x = 2 * column + deltaColumn
            for channel in 0..<16 {
              result[channel * plane + y * width + x] =
                tokens[token * 64 + feature + channel]
            }
          }
        }
      }
    }
    return result
  }

  public static func unpatchify(_ tokens: [Float], side: Int) -> [Float] {
    unpatchify(tokens, width: side, height: side)
  }

  public static func downsampleMask(
    _ mask: [Float],
    sourceWidth: Int,
    sourceHeight: Int,
    destinationWidth: Int,
    destinationHeight: Int
  ) -> [Float] {
    precondition(sourceWidth.isMultiple(of: destinationWidth))
    precondition(sourceHeight.isMultiple(of: destinationHeight))
    precondition(mask.count == sourceWidth * sourceHeight)
    let scaleX = sourceWidth / destinationWidth
    let scaleY = sourceHeight / destinationHeight
    var result = [Float](repeating: 0, count: destinationWidth * destinationHeight)
    for row in 0..<destinationHeight {
      for column in 0..<destinationWidth {
        var total: Float = 0
        for y in 0..<scaleY {
          for x in 0..<scaleX {
            total += mask[(row * scaleY + y) * sourceWidth + column * scaleX + x]
          }
        }
        result[row * destinationWidth + column] = total / Float(scaleX * scaleY)
      }
    }
    return result
  }

  public static func downsampleMask(
    _ mask: [Float], sourceSide: Int, destinationSide: Int
  ) -> [Float] {
    downsampleMask(
      mask,
      sourceWidth: sourceSide,
      sourceHeight: sourceSide,
      destinationWidth: destinationSide,
      destinationHeight: destinationSide)
  }

  /// Deterministic SplitMix64 plus Box-Muller standard normal noise.
  public static func noise(count: Int, seed: UInt64) -> [Float] {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    func next() -> Double {
      state &+= 0x9E37_79B9_7F4A_7C15
      var value = state
      value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
      value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
      value ^= value >> 31
      return Double(value >> 11) / 9_007_199_254_740_992
    }
    var result: [Float] = []
    result.reserveCapacity(count)
    while result.count < count {
      let first = max(next(), 1e-12)
      let second = next()
      let radius = sqrt(-2 * log(first))
      let angle = 2 * Double.pi * second
      result.append(Float(radius * cos(angle)))
      if result.count < count { result.append(Float(radius * sin(angle))) }
    }
    return result
  }

  private static func error(_ message: String) -> NSError {
    NSError(
      domain: "org.pixeltje.coreai.zimage",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}

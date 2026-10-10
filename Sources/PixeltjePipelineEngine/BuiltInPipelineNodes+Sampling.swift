import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let karrasScheduler = PipelineNodeKind(rawValue: "diffusion.karrasScheduler")
  public static let exponentialScheduler = PipelineNodeKind(
    rawValue: "diffusion.exponentialScheduler")
  public static let betaScheduler = PipelineNodeKind(rawValue: "diffusion.betaScheduler")
  public static let alignYourStepsScheduler = PipelineNodeKind(
    rawValue: "diffusion.alignYourStepsScheduler")
  public static let splitSchedule = PipelineNodeKind(rawValue: "diffusion.splitSchedule")
  public static let splitScheduleDenoise = PipelineNodeKind(
    rawValue: "diffusion.splitScheduleDenoise")
  public static let flipSchedule = PipelineNodeKind(rawValue: "diffusion.flipSchedule")
  public static let forceFullDenoise = PipelineNodeKind(rawValue: "diffusion.forceFullDenoise")
  public static let latentZerosLike = PipelineNodeKind(rawValue: "latent.zerosLike")
  public static let disableNoise = PipelineNodeKind(rawValue: "latent.disableNoise")
  public static let addNoise = PipelineNodeKind(rawValue: "latent.addNoise")
  public static let sd3ModelSampling = PipelineNodeKind(rawValue: "diffusion.modelSamplingSD3")
  public static let fluxModelSampling = PipelineNodeKind(rawValue: "diffusion.modelSamplingFlux")
  public static let discreteModelSampling = PipelineNodeKind(
    rawValue: "diffusion.modelSamplingDiscrete")
  public static let perturbedAttentionGuidance = PipelineNodeKind(
    rawValue: "diffusion.perturbedAttentionGuidance")
  public static let dualCFGGuider = PipelineNodeKind(rawValue: "diffusion.dualCFGGuider")
  public static let rescaleCFG = PipelineNodeKind(rawValue: "diffusion.rescaleCFG")
  public static let cfgNorm = PipelineNodeKind(rawValue: "diffusion.cfgNorm")
}

extension PipelineNodeRegistry {
  /// Schedulers, schedule surgery, noise primitives and model patches used by
  /// refiner and multi-stage workflows. ComfyUI's KSamplerAdvanced imports as
  /// a subgraph of these and the custom-sampling nodes.
  static var samplingDescriptors: [PipelineNodeDescriptor] {
    [
      PipelineNodeDescriptor(
        kind: .karrasScheduler,
        displayName: "Karras Scheduler",
        category: "Diffusion",
        outputs: [.init(name: "schedule", type: .schedule)],
        parameters: [
          .init(name: "steps", valueType: .integer, defaultValue: .integer(20)),
          .init(name: "sigmaMax", valueType: .number, defaultValue: .number(14.614642)),
          .init(name: "sigmaMin", valueType: .number, defaultValue: .number(0.0291675)),
          .init(name: "rho", valueType: .number, defaultValue: .number(7)),
        ]),
      PipelineNodeDescriptor(
        kind: .exponentialScheduler,
        displayName: "Exponential Scheduler",
        category: "Diffusion",
        outputs: [.init(name: "schedule", type: .schedule)],
        parameters: [
          .init(name: "steps", valueType: .integer, defaultValue: .integer(20)),
          .init(name: "sigmaMax", valueType: .number, defaultValue: .number(14.614642)),
          .init(name: "sigmaMin", valueType: .number, defaultValue: .number(0.0291675)),
        ]),
      PipelineNodeDescriptor(
        kind: .betaScheduler,
        displayName: "Beta Sampling Scheduler",
        category: "Diffusion",
        inputs: [.init(name: "denoiser", type: .modelFunction)],
        outputs: [.init(name: "schedule", type: .schedule)],
        parameters: [
          .init(name: "steps", valueType: .integer, defaultValue: .integer(20)),
          .init(name: "alpha", valueType: .number, defaultValue: .number(0.6)),
          .init(name: "beta", valueType: .number, defaultValue: .number(0.6)),
        ]),
      PipelineNodeDescriptor(
        kind: .alignYourStepsScheduler,
        displayName: "Align Your Steps Scheduler",
        category: "Diffusion",
        outputs: [.init(name: "schedule", type: .schedule)],
        parameters: [
          .init(name: "modelType", valueType: .string, defaultValue: .string("SDXL")),
          .init(name: "steps", valueType: .integer, defaultValue: .integer(10)),
          .init(name: "denoise", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .splitSchedule,
        displayName: "Split Schedule",
        category: "Diffusion",
        inputs: [.init(name: "schedule", type: .schedule)],
        outputs: [
          .init(name: "high", type: .schedule),
          .init(name: "low", type: .schedule),
        ],
        parameters: [
          .init(name: "step", valueType: .integer, defaultValue: .integer(0))
        ]),
      PipelineNodeDescriptor(
        kind: .splitScheduleDenoise,
        displayName: "Split Schedule by Denoise",
        category: "Diffusion",
        inputs: [.init(name: "schedule", type: .schedule)],
        outputs: [
          .init(name: "high", type: .schedule),
          .init(name: "low", type: .schedule),
        ],
        parameters: [
          .init(name: "denoise", valueType: .number, defaultValue: .number(1))
        ]),
      PipelineNodeDescriptor(
        kind: .flipSchedule,
        displayName: "Flip Schedule",
        category: "Diffusion",
        inputs: [.init(name: "schedule", type: .schedule)],
        outputs: [.init(name: "schedule", type: .schedule)]),
      // Sets the final sigma of a truncated schedule to zero, so sampling
      // that stops early still returns a fully denoised latent.
      PipelineNodeDescriptor(
        kind: .forceFullDenoise,
        displayName: "Denoise to Zero",
        category: "Diffusion",
        inputs: [.init(name: "schedule", type: .schedule)],
        outputs: [.init(name: "schedule", type: .schedule)]),
      PipelineNodeDescriptor(
        kind: .latentZerosLike,
        displayName: "Empty Latent Like",
        category: "Latent",
        inputs: [.init(name: "latent", type: .latent)],
        outputs: [.init(name: "latent", type: .latent)]),
      PipelineNodeDescriptor(
        kind: .disableNoise,
        displayName: "Disable Noise",
        category: "Diffusion",
        outputs: [.init(name: "noise", type: .noise)]),
      PipelineNodeDescriptor(
        kind: .addNoise,
        displayName: "Add Noise",
        category: "Diffusion",
        inputs: [
          .init(name: "denoiser", type: .modelFunction),
          .init(name: "noise", type: .noise),
          .init(name: "schedule", type: .schedule),
          .init(name: "latent", type: .latent),
        ],
        outputs: [.init(name: "latent", type: .latent)]),
      PipelineNodeDescriptor(
        kind: .sd3ModelSampling,
        displayName: "SD3 Model Sampling",
        category: "Diffusion",
        inputs: [.init(name: "model", type: .modelFunction)],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "shift", valueType: .number, defaultValue: .number(3))
        ]),
      PipelineNodeDescriptor(
        kind: .fluxModelSampling,
        displayName: "FLUX Model Sampling",
        category: "Diffusion",
        inputs: [.init(name: "model", type: .modelFunction)],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "maxShift", valueType: .number, defaultValue: .number(1.15)),
          .init(name: "baseShift", valueType: .number, defaultValue: .number(0.5)),
          .init(name: "width", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(1024)),
        ]),
      PipelineNodeDescriptor(
        kind: .discreteModelSampling,
        displayName: "Discrete Model Sampling",
        category: "Diffusion",
        inputs: [.init(name: "model", type: .modelFunction)],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "sampling", valueType: .string, defaultValue: .string("eps")),
          .init(name: "zeroTerminalSNR", valueType: .boolean, defaultValue: .boolean(false)),
        ]),
      PipelineNodeDescriptor(
        kind: .perturbedAttentionGuidance,
        displayName: "Perturbed Attention Guidance",
        category: "Diffusion",
        inputs: [.init(name: "model", type: .modelFunction)],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "scale", valueType: .number, defaultValue: .number(3))
        ]),
      PipelineNodeDescriptor(
        kind: .dualCFGGuider,
        displayName: "Dual CFG Guider",
        category: "Diffusion",
        inputs: [
          .init(name: "denoiser", type: .modelFunction),
          .init(name: "positive", type: .conditioning),
          .init(name: "secondaryPositive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
        ],
        outputs: [.init(name: "guider", type: .guider)],
        parameters: [
          .init(name: "guidance", valueType: .number, defaultValue: .number(8)),
          .init(name: "secondaryGuidance", valueType: .number, defaultValue: .number(8)),
          .init(name: "style", valueType: .string, defaultValue: .string("regular")),
        ]),
      PipelineNodeDescriptor(
        kind: .rescaleCFG,
        displayName: "Rescale CFG",
        category: "Diffusion",
        inputs: [.init(name: "model", type: .modelFunction)],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "multiplier", valueType: .number, defaultValue: .number(0.7))
        ]),
      PipelineNodeDescriptor(
        kind: .cfgNorm,
        displayName: "CFG Norm",
        category: "Diffusion",
        inputs: [
          .init(name: "model", type: .modelFunction),
          .init(name: "preCfg", type: .boolean, isRequired: false),
        ],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
          .init(name: "preCfg", valueType: .boolean, defaultValue: .boolean(false)),
        ]),
    ]
  }
}

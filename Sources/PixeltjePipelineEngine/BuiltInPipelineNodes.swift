import Foundation
import PixeltjeModelDesign
import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let controlStart = PipelineNodeKind(rawValue: "control.start")
  public static let controlLoop = PipelineNodeKind(rawValue: "control.loop")
  public static let controlTimeline = PipelineNodeKind(rawValue: "control.timeline")
  public static let promptInput = PipelineNodeKind(rawValue: "input.prompt")
  public static let negativePromptInput = PipelineNodeKind(rawValue: "input.negativePrompt")
  public static let seedInput = PipelineNodeKind(rawValue: "input.seed")
  public static let imageInput = PipelineNodeKind(rawValue: "input.image")
  public static let imageCache = PipelineNodeKind(rawValue: "cache.image")
  public static let assetCache = PipelineNodeKind(rawValue: "cache.assets")
  public static let maskInput = PipelineNodeKind(rawValue: "input.mask")
  public static let resolutionSelector = PipelineNodeKind(rawValue: "input.resolution")
  public static let primitiveString = PipelineNodeKind(rawValue: "primitive.string")
  public static let primitiveFilePath = PipelineNodeKind(rawValue: "primitive.filePath")
  public static let primitiveInt = PipelineNodeKind(rawValue: "primitive.int")
  public static let primitiveFloat = PipelineNodeKind(rawValue: "primitive.float")
  public static let trackpad = PipelineNodeKind(rawValue: "input.trackpad")
  public static let previousScenePlanInput = PipelineNodeKind(rawValue: "input.previousScenePlan")
  public static let stateInput = PipelineNodeKind(rawValue: "input.state")
  public static let previousFrameInput = PipelineNodeKind(rawValue: "input.previousFrame")
  public static let sceneNavigate = PipelineNodeKind(rawValue: "scene.navigate")
  public static let sceneNavigationCrop = PipelineNodeKind(rawValue: "scene.navigationCrop")
  public static let scenePlanParse = PipelineNodeKind(rawValue: "scene.parsePlan")
  public static let primitiveBoolean = PipelineNodeKind(rawValue: "primitive.boolean")
  public static let ifElseSwitch = PipelineNodeKind(rawValue: "logic.ifElse")
  public static let mathExpression = PipelineNodeKind(rawValue: "math.expression")
  public static let markdownNote = PipelineNodeKind(rawValue: "edit.markdownNote")
  public static let tokenizer = PipelineNodeKind(rawValue: "text.tokenizer")
  public static let textEncoder = PipelineNodeKind(rawValue: "coreai.textEncoder")
  public static let textEncoderModel = PipelineNodeKind(rawValue: "coreai.textEncoderModel")
  public static let textConditioningEncoder = PipelineNodeKind(
    rawValue: "conditioning.textEncode")
  public static let zeroConditioning = PipelineNodeKind(rawValue: "conditioning.zero")
  public static let denoiser = PipelineNodeKind(rawValue: "coreai.denoiser")
  public static let adapter = PipelineNodeKind(rawValue: "coreai.adapter")
  public static let vaeModel = PipelineNodeKind(rawValue: "coreai.vaeModel")
  public static let vaeEncoder = PipelineNodeKind(rawValue: "coreai.vaeEncoder")
  public static let vaeImageEncoder = PipelineNodeKind(rawValue: "coreai.vaeImageEncoder")
  public static let vaeDecoder = PipelineNodeKind(rawValue: "coreai.vaeDecoder")
  public static let vaeImageDecoder = PipelineNodeKind(rawValue: "coreai.vaeImageDecoder")
  public static let vaeAudioDecoder = PipelineNodeKind(rawValue: "coreai.vaeAudioDecoder")
  public static let seededNoise = PipelineNodeKind(rawValue: "latent.seededNoise")
  public static let randomNoise = PipelineNodeKind(rawValue: "latent.randomNoise")
  public static let emptyFlux2LatentImage = PipelineNodeKind(rawValue: "latent.emptyFlux2Image")
  public static let emptyLatentImage = PipelineNodeKind(rawValue: "latent.emptyImage")
  public static let discreteFlowModelSampling = PipelineNodeKind(
    rawValue: "diffusion.modelSamplingDiscreteFlow")
  public static let basicScheduler = PipelineNodeKind(rawValue: "diffusion.basicScheduler")
  public static let flux2Scheduler = PipelineNodeKind(rawValue: "diffusion.flux2Scheduler")
  public static let samplerSelector = PipelineNodeKind(rawValue: "diffusion.samplerSelector")
  public static let basicGuider = PipelineNodeKind(rawValue: "diffusion.basicGuider")
  public static let cfgGuider = PipelineNodeKind(rawValue: "diffusion.cfgGuider")
  public static let advancedSampler = PipelineNodeKind(rawValue: "diffusion.advancedSampler")
  public static let sampler = PipelineNodeKind(rawValue: "diffusion.sampler")
  public static let kSampler = PipelineNodeKind(rawValue: "diffusion.kSampler")
  public static let referenceToVideoConditioning = PipelineNodeKind(
    rawValue: "conditioning.referenceToVideo")
  public static let referenceLatentConditioning = PipelineNodeKind(
    rawValue: "conditioning.referenceLatent")
  public static let imageDimensions = PipelineNodeKind(rawValue: "image.dimensions")
  public static let imageScaleToTotalPixels = PipelineNodeKind(
    rawValue: "image.scaleToTotalPixels")
  public static let createVideo = PipelineNodeKind(rawValue: "media.createVideo")
  public static let imageOutput = PipelineNodeKind(rawValue: "output.image")
  public static let videoOutput = PipelineNodeKind(rawValue: "output.video")
  public static let checkpoint = PipelineNodeKind(rawValue: "coreai.checkpoint")
  public static let emptyHiDreamO1LatentImage = PipelineNodeKind(
    rawValue: "latent.emptyHiDreamO1Image")
  public static let hiDreamO1ReferenceImages = PipelineNodeKind(
    rawValue: "conditioning.hiDreamO1ReferenceImages")
  public static let hiDreamO1SeamSmoothing = PipelineNodeKind(
    rawValue: "diffusion.hiDreamO1SeamSmoothing")
  public static let modelNoiseScale = PipelineNodeKind(rawValue: "diffusion.modelNoiseScale")
  public static let customSampler = PipelineNodeKind(rawValue: "diffusion.customSampler")
  public static let lcmSamplerSelector = PipelineNodeKind(rawValue: "diffusion.lcmSampler")
  public static let qwenImage21TextEncoder = PipelineNodeKind(
    rawValue: "conditioning.qwenImage21TextEncode")
  public static let textConcatenate = PipelineNodeKind(rawValue: "text.concatenate")
  public static let textSplit = PipelineNodeKind(rawValue: "text.split")
  public static let textReplace = PipelineNodeKind(rawValue: "text.replace")
  public static let textRegexReplace = PipelineNodeKind(rawValue: "text.regexReplace")
  public static let textJSONExtract = PipelineNodeKind(rawValue: "text.jsonExtract")
  public static let maskHitTest = PipelineNodeKind(rawValue: "mask.hitTest")
  public static let textGenerate = PipelineNodeKind(rawValue: "text.generate")
  public static let languageModel = PipelineNodeKind(rawValue: "coreai.languageModel")
  public static let chatCompletion = PipelineNodeKind(rawValue: "language.chatCompletion")
  public static let previewAny = PipelineNodeKind(rawValue: "utility.previewAny")
  public static let textOutput = PipelineNodeKind(rawValue: "output.text")
  public static let coreAIImageClassifier = PipelineNodeKind(rawValue: "coreai.imageClassifier")
}

extension PipelineNodeRegistry {
  /// Version-one node vocabulary shared by Pixeltje and Pipeline Editor.
  public static var coreAIV1: PipelineNodeRegistry {
    var descriptors: [PipelineNodeDescriptor] = [
      PipelineNodeDescriptor(
        kind: .controlStart, displayName: "Start / Next Pass",
        category: "Control",
        inputs: [.init(name: PipelineControlPorts.again, type: .control,
          isRequired: false)]),
      PipelineNodeDescriptor(
        kind: .controlLoop, displayName: "Loop",
        category: "Control",
        inputs: [.init(name: PipelineControlPorts.completed, type: .control,
          isRequired: false)],
        outputs: [
          .init(name: PipelineControlPorts.repeatPort, type: .control),
          .init(name: PipelineControlPorts.incrementSeed, type: .control),
          .init(name: "callIndex", type: .number),
        ],
        parameters: [
          .init(name: "maxCalls", valueType: .integer,
            defaultValue: .integer(3)),
          .init(name: "delayMilliseconds", valueType: .integer,
            defaultValue: .integer(1_000)),
          .init(name: "limitHz", valueType: .integer,
            defaultValue: .integer(0)),
          .init(name: "autoRepeat", valueType: .boolean,
            defaultValue: .boolean(false)),
          .init(name: "autoPause", valueType: .boolean,
            defaultValue: .boolean(false)),
          .init(name: "seedStrategy", valueType: .string,
            defaultValue: .string("fixed")),
          .init(name: "feedback", valueType: .string,
            defaultValue: .string("none")),
        ]),
      PipelineNodeDescriptor(
        kind: .controlTimeline, displayName: "Timeline", category: "Control",
        inputs: [
          .init(name: "value", type: .any, typeVariable: "animatedValue"),
          .init(name: PipelineControlPorts.completed, type: .control, isRequired: false),
        ],
        outputs: [
          .init(name: "value", type: .any, typeVariable: "animatedValue"),
          .init(name: "frameIndex", type: .integer),
          .init(name: "timeSeconds", type: .number),
          .init(name: "progress", type: .number),
          .init(name: "framesPerSecond", type: .number),
          .init(name: PipelineControlPorts.repeatPort, type: .control),
        ],
        parameters: [
          .init(name: "frameCount", valueType: .integer, defaultValue: .integer(120)),
          .init(name: "framesPerSecond", valueType: .number, defaultValue: .number(30)),
          .init(name: "tracks", valueType: .array, defaultValue: .array([])),
        ]),
      PipelineNodeDescriptor(
        kind: .promptInput,
        displayName: "Prompt",
        category: "Inputs",
        outputs: [.init(name: "prompt", type: .prompt)],
        parameters: [
          .init(name: "value", valueType: .string, defaultValue: .string(""))
        ]),
      PipelineNodeDescriptor(
        kind: .negativePromptInput,
        displayName: "Negative Prompt",
        category: "Inputs",
        outputs: [.init(name: "prompt", type: .prompt)],
        parameters: [
          .init(name: "value", valueType: .string, defaultValue: .string(""))
        ]),
      PipelineNodeDescriptor(
        kind: .seedInput,
        displayName: "Seed",
        category: "Inputs",
        inputs: [.init(name: PipelineControlPorts.increment, type: .control,
          isRequired: false)],
        outputs: [.init(name: "seed", type: .seed)],
        parameters: [
          .init(name: "mode", valueType: .string, defaultValue: .string("fixed")),
          .init(name: "value", valueType: .integer, defaultValue: .integer(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageInput,
        displayName: "Source Image",
        category: "Inputs",
        outputs: [
          .init(name: "image", type: .image),
          .init(name: "mask", type: .mask),
        ],
        parameters: [
          .init(name: "sourceName", valueType: .string),
          .init(name: "uploadMode", valueType: .string),
        ]),
      PipelineNodeDescriptor(
        kind: .imageCache, displayName: "Image Cache", category: "Utilities",
        inputs: [.init(name: "image", type: .image, isRequired: false)],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "key", valueType: .string),
          .init(name: "mode", valueType: .string, defaultValue: .string("store")),
        ]),
      PipelineNodeDescriptor(
        kind: .assetCache, displayName: "Asset Cache", category: "Utilities",
        outputs: [.init(name: "assets", type: .assetBundle)],
        parameters: [
          .init(name: "slotCount", valueType: .integer,
            defaultValue: .integer(1)),
          .init(name: "keepBetweenRuns", valueType: .boolean,
            defaultValue: .boolean(false)),
        ]),
      PipelineNodeDescriptor(
        kind: .maskInput,
        displayName: "Selection Mask",
        category: "Inputs",
        outputs: [.init(name: "mask", type: .mask)]),
      PipelineNodeDescriptor(
        kind: .resolutionSelector,
        displayName: "Resolution",
        category: "Inputs",
        outputs: [
          .init(name: "width", type: .integer),
          .init(name: "height", type: .integer),
        ],
        parameters: [
          .init(name: "aspectRatio", valueType: .string),
          .init(name: "megapixels", valueType: .number),
          .init(name: "multiple", valueType: .integer),
        ]),
      PipelineNodeDescriptor(
        kind: .primitiveString,
        displayName: "Text",
        category: "Primitives",
        inputs: [.init(name: "value", type: .string, isRequired: false)],
        outputs: [.init(name: "value", type: .string)],
        parameters: [
          .init(name: "value", valueType: .string, defaultValue: .string(""))
        ]),
      PipelineNodeDescriptor(
        kind: .primitiveFilePath,
        displayName: "File Path",
        category: "Primitives",
        outputs: [
          .init(name: "value", type: .string),
          .init(name: "contents", type: .string),
        ],
        parameters: [
          .init(name: "path", valueType: .string, defaultValue: .string("")),
          .init(name: "mode", valueType: .string, defaultValue: .string("relative")),
        ]),
      PipelineNodeDescriptor(
        kind: .primitiveInt,
        displayName: "Integer",
        category: "Primitives",
        inputs: [.init(name: "value", type: .integer, isRequired: false)],
        outputs: [.init(name: "value", type: .integer)],
        parameters: [
          .init(name: "value", valueType: .integer, defaultValue: .integer(0))
        ]),
      PipelineNodeDescriptor(
        kind: .primitiveFloat,
        displayName: "Number",
        category: "Primitives",
        inputs: [.init(name: "value", type: .number, isRequired: false)],
        outputs: [.init(name: "value", type: .number)],
        parameters: [
          .init(name: "value", valueType: .number, defaultValue: .number(0))
        ]),
      PipelineNodeDescriptor(
        kind: .trackpad,
        displayName: "Trackpad",
        category: "Inputs",
        outputs: [
          .init(name: "x", type: .number),
          .init(name: "y", type: .number),
          .init(name: "engaged", type: .boolean),
          .init(name: "engagedAtCall", type: .number),
          .init(name: "actionCount", type: .number),
        ],
        parameters: [
          .init(name: "x", valueType: .number, defaultValue: .number(0.5)),
          .init(name: "y", valueType: .number, defaultValue: .number(0.5)),
          .init(name: "engaged", valueType: .boolean, defaultValue: .boolean(false)),
          .init(name: "engagedAtCall", valueType: .integer, defaultValue: .integer(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .maskHitTest,
        displayName: "Mask Hit Test",
        category: "Mask",
        inputs: [
          .init(name: "masks", type: .labeledMasks),
          .init(name: "x", type: .number),
          .init(name: "y", type: .number),
        ],
        outputs: [
          .init(name: "found", type: .boolean),
          .init(name: "label", type: .string),
          .init(name: "mask", type: .mask),
          .init(name: "score", type: .number),
        ],
        parameters: [
          .init(name: "coverageThreshold", valueType: .number,
            defaultValue: .number(0.5)),
          .init(name: "radiusPixels", valueType: .integer,
            defaultValue: .integer(2)),
        ]),
      PipelineNodeDescriptor(
        kind: .previousScenePlanInput,
        displayName: "Previous Scene Plan",
        category: "Inputs",
        outputs: [.init(name: "scenePlan", type: .string)]),
      PipelineNodeDescriptor(
        kind: .stateInput, displayName: "JSON State", category: "Inputs",
        outputs: [.init(name: "state", type: .string)],
        parameters: [.init(name: "initialState", valueType: .string, defaultValue: .string("{}"))]),
      PipelineNodeDescriptor(
        kind: .previousFrameInput,
        displayName: "Previous Frame",
        category: "Inputs",
        outputs: [.init(name: "image", type: .image),
          .init(name: "masks", type: .labeledMasks)]),
      PipelineNodeDescriptor(
        kind: .sceneNavigate,
        displayName: "Next View Brief",
        category: "Scene",
        inputs: [
          .init(name: "originalPrompt", type: .prompt),
          .init(name: "previousPlan", type: .string),
          .init(name: "x", type: .number),
          .init(name: "y", type: .number),
        ],
        outputs: [.init(name: "prompt", type: .prompt)]),
      PipelineNodeDescriptor(
        kind: .scenePlanParse,
        displayName: "Parse Scene Plan",
        category: "Scene",
        inputs: [.init(name: "text", type: .string)],
        outputs: [
          .init(name: "prompt", type: .prompt),
          .init(name: "scenePlan", type: .string),
        ]),
      PipelineNodeDescriptor(
        kind: .sceneNavigationCrop,
        displayName: "Navigation Crop",
        category: "Scene",
        inputs: [
          .init(name: "image", type: .image, isRequired: false),
          .init(name: "previousPlan", type: .string),
          .init(name: "x", type: .number),
          .init(name: "y", type: .number),
        ],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "size", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "margin", valueType: .number, defaultValue: .number(1.5)),
        ]),
      PipelineNodeDescriptor(
        kind: .primitiveBoolean,
        displayName: "Boolean",
        category: "Primitives",
        inputs: [.init(name: "value", type: .boolean, isRequired: false)],
        outputs: [.init(name: "value", type: .boolean)],
        parameters: [
          .init(name: "value", valueType: .boolean, defaultValue: .boolean(false))
        ]),
      PipelineNodeDescriptor(
        kind: .ifElseSwitch,
        displayName: "If/Else",
        category: "Logic",
        inputs: [
          .init(name: "condition", type: .boolean, isRequired: false),
          .init(name: "falseValue", type: .any, isRequired: false, typeVariable: "value"),
          .init(name: "trueValue", type: .any, isRequired: false, typeVariable: "value"),
        ],
        outputs: [
          .init(name: "value", type: .any, typeVariable: "value")
        ],
        parameters: [
          .init(name: "condition", valueType: .boolean, defaultValue: .boolean(false))
        ]),
      PipelineNodeDescriptor(
        kind: .mathExpression,
        displayName: "Math Expression",
        category: "Logic",
        inputs: [
          .init(name: "a", type: .any),
          .init(name: "b", type: .any, isRequired: false),
        ],
        outputs: [
          .init(name: "number", type: .number),
          .init(name: "integer", type: .integer),
          .init(name: "boolean", type: .boolean),
        ],
        parameters: [
          .init(name: "expression", valueType: .string, isRequired: true)
        ]),
      PipelineNodeDescriptor(
        kind: .markdownNote,
        displayName: "Markdown Note",
        category: "Documentation",
        parameters: [
          .init(name: "text", valueType: .string, defaultValue: .string(""))
        ]),
      PipelineNodeDescriptor(
        kind: .tokenizer,
        displayName: "Tokenizer",
        category: "Conditioning",
        inputs: [.init(name: "prompt", type: .prompt)],
        outputs: [.init(name: "tokens", type: .tokens)],
        requiredResourceSlots: ["tokenizer"]),
      PipelineNodeDescriptor(
        kind: .textEncoder,
        displayName: "Core AI Text Encoder",
        category: "Models",
        inputs: [.init(name: "tokens", type: .tokens)],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .textEncoderModel,
        displayName: "Core AI Text Encoder Model",
        category: "Models",
        outputs: [.init(name: "function", type: .textEncoderFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string),
          .init(name: "encoderType", valueType: .string),
          .init(name: "device", valueType: .string),
        ],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .textConditioningEncoder,
        displayName: "Text Conditioning Encoder",
        category: "Conditioning",
        inputs: [
          .init(name: "textEncoder", type: .textEncoderFunction),
          .init(name: "text", type: .string, isRequired: false),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "text", valueType: .string, defaultValue: .string(""))
        ]),
      PipelineNodeDescriptor(
        kind: .zeroConditioning,
        displayName: "Zero Conditioning",
        category: "Conditioning",
        inputs: [.init(name: "conditioning", type: .conditioning)],
        outputs: [.init(name: "conditioning", type: .conditioning)]),
      PipelineNodeDescriptor(
        kind: .denoiser,
        displayName: "Core AI Denoiser",
        category: "Models",
        outputs: [.init(name: "function", type: .modelFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string),
          .init(name: "weightType", valueType: .string),
        ],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .adapter,
        displayName: "Core AI Adapter",
        category: "Models",
        inputs: [.init(name: "base", type: .modelFunction)],
        outputs: [.init(name: "function", type: .modelFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string),
          .init(name: "weight", valueType: .number, defaultValue: .number(1))
        ],
        requiredResourceSlots: ["adapter"]),
      PipelineNodeDescriptor(
        kind: .vaeModel,
        displayName: "Core AI VAE Model",
        category: "Models",
        outputs: [.init(name: "function", type: .vaeFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string)
        ],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .vaeEncoder,
        displayName: "Core AI VAE Encoder",
        category: "Models",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "latent", type: .latent)],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .vaeImageEncoder,
        displayName: "VAE Image Encoder",
        category: "Models",
        inputs: [
          .init(name: "image", type: .image),
          .init(name: "vae", type: .vaeFunction),
        ],
        outputs: [.init(name: "latent", type: .latent)]),
      PipelineNodeDescriptor(
        kind: .vaeDecoder,
        displayName: "Core AI VAE Decoder",
        category: "Models",
        inputs: [.init(name: "latent", type: .latent)],
        outputs: [.init(name: "image", type: .image)],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .vaeImageDecoder,
        displayName: "VAE Image Decoder",
        category: "Models",
        inputs: [
          .init(name: "latent", type: .latent),
          .init(name: "vae", type: .vaeFunction),
        ],
        outputs: [.init(name: "image", type: .image)]),
      PipelineNodeDescriptor(
        kind: .vaeAudioDecoder,
        displayName: "VAE Audio Decoder",
        category: "Models",
        inputs: [
          .init(name: "latent", type: .latent),
          .init(name: "vae", type: .vaeFunction),
        ],
        outputs: [.init(name: "audio", type: .audio)]),
      PipelineNodeDescriptor(
        kind: .seededNoise,
        displayName: "Seeded Noise",
        category: "Diffusion",
        inputs: [.init(name: "seed", type: .seed)],
        outputs: [.init(name: "noise", type: .noise)],
        parameters: [
          .init(name: "width", valueType: .integer, isRequired: true),
          .init(name: "height", valueType: .integer, isRequired: true),
          .init(name: "channels", valueType: .integer, isRequired: true),
        ]),
      PipelineNodeDescriptor(
        kind: .randomNoise,
        displayName: "Random Noise",
        category: "Diffusion",
        outputs: [.init(name: "noise", type: .noise)],
        parameters: [
          .init(name: "seed", valueType: .integer, isRequired: true),
          .init(name: "seedControl", valueType: .string),
        ]),
      PipelineNodeDescriptor(
        kind: .emptyFlux2LatentImage,
        displayName: "Empty FLUX.2 Latent Image",
        category: "Diffusion",
        inputs: [
          .init(name: "width", type: .integer, isRequired: false),
          .init(name: "height", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "batchSize", valueType: .integer, defaultValue: .integer(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .emptyLatentImage,
        displayName: "Empty Latent Image",
        category: "Diffusion",
        inputs: [
          .init(name: "width", type: .integer, isRequired: false),
          .init(name: "height", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "batchSize", valueType: .integer, defaultValue: .integer(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .discreteFlowModelSampling,
        displayName: "Discrete Flow Model Sampling",
        category: "Diffusion",
        inputs: [.init(name: "model", type: .modelFunction)],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "shift", valueType: .number, defaultValue: .number(3)),
          .init(name: "sampling", valueType: .string, defaultValue: .string("constant")),
        ]),
      PipelineNodeDescriptor(
        kind: .basicScheduler,
        displayName: "Basic Scheduler",
        category: "Diffusion",
        inputs: [
          .init(name: "denoiser", type: .modelFunction),
          .init(name: "scheduler", type: .string, isRequired: false),
          .init(name: "steps", type: .integer, isRequired: false),
          .init(name: "denoise", type: .number, isRequired: false),
        ],
        outputs: [.init(name: "schedule", type: .schedule)],
        parameters: [
          .init(name: "scheduler", valueType: .string, defaultValue: .string("normal")),
          .init(name: "steps", valueType: .integer, defaultValue: .integer(20)),
          .init(name: "denoise", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .flux2Scheduler,
        displayName: "FLUX.2 Scheduler",
        category: "Diffusion",
        inputs: [
          .init(name: "width", type: .integer, isRequired: false),
          .init(name: "height", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "schedule", type: .schedule)],
        parameters: [
          .init(name: "steps", valueType: .integer, defaultValue: .integer(20)),
          .init(name: "width", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(1024)),
        ]),
      PipelineNodeDescriptor(
        kind: .samplerSelector,
        displayName: "Sampler Selector",
        category: "Diffusion",
        outputs: [.init(name: "function", type: .samplerFunction)],
        parameters: [
          .init(name: "samplerName", valueType: .string, isRequired: true)
        ]),
      PipelineNodeDescriptor(
        kind: .basicGuider,
        displayName: "Basic Guider",
        category: "Diffusion",
        inputs: [
          .init(name: "denoiser", type: .modelFunction),
          .init(name: "conditioning", type: .conditioning),
        ],
        outputs: [.init(name: "guider", type: .guider)]),
      PipelineNodeDescriptor(
        kind: .cfgGuider,
        displayName: "CFG Guider",
        category: "Diffusion",
        inputs: [
          .init(name: "denoiser", type: .modelFunction),
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
        ],
        outputs: [.init(name: "guider", type: .guider)],
        parameters: [
          .init(name: "guidance", valueType: .number, defaultValue: .number(1))
        ]),
      PipelineNodeDescriptor(
        kind: .advancedSampler,
        displayName: "Advanced Sampler",
        category: "Diffusion",
        inputs: [
          .init(name: "noise", type: .noise),
          .init(name: "guider", type: .guider),
          .init(name: "sampler", type: .samplerFunction),
          .init(name: "schedule", type: .schedule),
          .init(name: "sourceLatent", type: .latent),
        ],
        outputs: [
          .init(name: "latent", type: .latent),
          .init(name: "denoisedLatent", type: .latent),
        ]),
      PipelineNodeDescriptor(
        kind: .sampler,
        displayName: "Sampler",
        category: "Diffusion",
        inputs: [
          .init(name: "noise", type: .noise),
          .init(name: "conditioning", type: .conditioning),
          .init(name: "negativeConditioning", type: .conditioning, isRequired: false),
          .init(name: "sourceLatent", type: .latent, isRequired: false),
          .init(name: "mask", type: .mask, isRequired: false),
          .init(name: "denoiser", type: .modelFunction),
          .init(name: "schedule", type: .schedule, isRequired: false),
        ],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "steps", valueType: .integer, defaultValue: .integer(8)),
          .init(name: "guidance", valueType: .number, defaultValue: .number(1)),
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
          .init(name: "sampler", valueType: .string, defaultValue: .string("euler")),
          .init(
            name: "scheduler", valueType: .string, defaultValue: .string("flowMatch")),
        ]),
      PipelineNodeDescriptor(
        kind: .kSampler,
        displayName: "KSampler",
        category: "Diffusion",
        inputs: [
          .init(name: "model", type: .modelFunction),
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
          .init(name: "latent", type: .latent),
          .init(name: "seed", type: .seed, isRequired: false),
          .init(name: "steps", type: .integer, isRequired: false),
          .init(name: "guidance", type: .number, isRequired: false),
          .init(name: "sampler", type: .string, isRequired: false),
          .init(name: "scheduler", type: .string, isRequired: false),
          .init(name: "denoise", type: .number, isRequired: false),
        ],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "seed", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "seedControl", valueType: .string, defaultValue: .string("fixed")),
          .init(name: "steps", valueType: .integer, defaultValue: .integer(8)),
          .init(name: "guidance", valueType: .number, defaultValue: .number(1)),
          .init(name: "sampler", valueType: .string, defaultValue: .string("euler")),
          .init(name: "scheduler", valueType: .string, defaultValue: .string("simple")),
          .init(name: "denoise", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .referenceToVideoConditioning,
        displayName: "Reference-to-Video Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "textEncoder", type: .textEncoderFunction),
          .init(name: "videoVAE", type: .vaeFunction),
          .init(name: "audioVAE", type: .vaeFunction),
          .init(name: "referenceImage1", type: .image, isRequired: false),
          .init(name: "referenceImage2", type: .image, isRequired: false),
          .init(name: "referenceImage3", type: .image, isRequired: false),
          .init(name: "referenceVideo", type: .image, isRequired: false),
          .init(name: "referenceVideoAudio", type: .audio, isRequired: false),
          .init(name: "referenceAudio", type: .audio, isRequired: false),
          .init(name: "prompt", type: .string),
          .init(name: "width", type: .integer),
          .init(name: "height", type: .integer),
          .init(name: "length", type: .integer),
        ],
        outputs: [
          .init(name: "conditioning", type: .conditioning),
          .init(name: "latent", type: .latent),
        ],
        parameters: [
          .init(name: "referenceImageSize", valueType: .string)
        ]),
      PipelineNodeDescriptor(
        kind: .referenceLatentConditioning,
        displayName: "Reference Latent Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioning", type: .conditioning),
          .init(name: "latent", type: .latent),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)]),
      PipelineNodeDescriptor(
        kind: .imageDimensions,
        displayName: "Image Dimensions",
        category: "Image",
        inputs: [.init(name: "image", type: .image)],
        outputs: [
          .init(name: "width", type: .integer),
          .init(name: "height", type: .integer),
          .init(name: "batchSize", type: .integer),
        ]),
      PipelineNodeDescriptor(
        kind: .imageScaleToTotalPixels,
        displayName: "Scale Image to Total Pixels",
        category: "Image",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "upscaleMethod", valueType: .string),
          .init(name: "megapixels", valueType: .number),
          .init(name: "resolution", valueType: .number),
        ]),
      PipelineNodeDescriptor(
        kind: .createVideo,
        displayName: "Create Video",
        category: "Media",
        inputs: [
          .init(name: "images", type: .image),
          .init(name: "audio", type: .audio, isRequired: false),
        ],
        outputs: [.init(name: "video", type: .video)],
        parameters: [
          .init(name: "framesPerSecond", valueType: .number, defaultValue: .number(30)),
          // ComfyUI uses "auto" as well as numeric 8 and 10 bit values.
          .init(name: "bitDepth", valueType: .any, defaultValue: .string("auto")),
          .init(name: "colorSpace", valueType: .string, defaultValue: .string("sRGB")),
          .init(name: "codec", valueType: .string, defaultValue: .string("none")),
        ]),
      PipelineNodeDescriptor(
        kind: .imageOutput,
        displayName: "Generated Image",
        category: "Outputs",
        inputs: [
          .init(name: "image", type: .image),
          .init(name: "scenePlan", type: .string, isRequired: false),
          .init(name: "feedbackText", type: .string, isRequired: false),
          .init(name: "nextState", type: .string, isRequired: false),
          .init(name: "interactionMasks", type: .labeledMasks, isRequired: false),
        ],
        outputs: [
          .init(name: "result", type: .generatedImage),
          // ComfyUI's Save Image (Advanced) passes its input through.
          .init(name: "image", type: .image),
        ],
        parameters: [
          .init(name: "filenamePrefix", valueType: .string),
          .init(name: "format", valueType: .string),
          .init(name: "bitDepth", valueType: .string),
          .init(name: "colorSpace", valueType: .string),
        ],
        isTerminal: true),
      PipelineNodeDescriptor(
        kind: .checkpoint,
        displayName: "Core AI Checkpoint",
        category: "Models",
        outputs: [
          .init(name: "model", type: .modelFunction),
          .init(name: "textEncoder", type: .textEncoderFunction),
          .init(name: "vae", type: .vaeFunction),
        ],
        parameters: [
          .init(name: "modelName", valueType: .string)
        ],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .emptyHiDreamO1LatentImage,
        displayName: "Empty HiDream-O1 Latent Image",
        category: "Diffusion",
        inputs: [
          .init(name: "width", type: .integer, isRequired: false),
          .init(name: "height", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(2048)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(2048)),
          .init(name: "batchSize", valueType: .integer, defaultValue: .integer(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .hiDreamO1ReferenceImages,
        displayName: "HiDream-O1 Reference Images",
        category: "Conditioning",
        inputs: [
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
          .init(name: "referenceImage1", type: .image, isRequired: false),
          .init(name: "referenceImage2", type: .image, isRequired: false),
          .init(name: "referenceImage3", type: .image, isRequired: false),
          .init(name: "referenceImage4", type: .image, isRequired: false),
          .init(name: "referenceImage5", type: .image, isRequired: false),
          .init(name: "referenceImage6", type: .image, isRequired: false),
          .init(name: "referenceImage7", type: .image, isRequired: false),
          .init(name: "referenceImage8", type: .image, isRequired: false),
          .init(name: "referenceImage9", type: .image, isRequired: false),
          .init(name: "referenceImage10", type: .image, isRequired: false),
        ],
        outputs: [
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
        ]),
      PipelineNodeDescriptor(
        kind: .hiDreamO1SeamSmoothing,
        displayName: "HiDream-O1 Patch Seam Smoothing",
        category: "Diffusion",
        inputs: [.init(name: "model", type: .modelFunction)],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "startPercent", valueType: .number, defaultValue: .number(0.8)),
          .init(name: "endPercent", valueType: .number, defaultValue: .number(1)),
          .init(name: "pattern", valueType: .string, defaultValue: .string("single_shift")),
          .init(name: "passes", valueType: .string, defaultValue: .string("2")),
          .init(name: "blend", valueType: .string, defaultValue: .string("average")),
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .modelNoiseScale,
        displayName: "Model Noise Scale",
        category: "Diffusion",
        inputs: [.init(name: "model", type: .modelFunction)],
        outputs: [.init(name: "model", type: .modelFunction)],
        parameters: [
          .init(name: "noiseScale", valueType: .number, defaultValue: .number(1))
        ]),
      PipelineNodeDescriptor(
        kind: .customSampler,
        displayName: "Custom Sampler",
        category: "Diffusion",
        inputs: [
          .init(name: "denoiser", type: .modelFunction),
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
          .init(name: "sampler", type: .samplerFunction),
          .init(name: "schedule", type: .schedule),
          .init(name: "sourceLatent", type: .latent),
        ],
        outputs: [
          .init(name: "latent", type: .latent),
          .init(name: "denoisedLatent", type: .latent),
        ],
        parameters: [
          .init(name: "addNoise", valueType: .boolean, defaultValue: .boolean(true)),
          .init(name: "seed", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "seedControl", valueType: .string, defaultValue: .string("fixed")),
          .init(name: "guidance", valueType: .number, defaultValue: .number(8)),
        ]),
      PipelineNodeDescriptor(
        kind: .lcmSamplerSelector,
        displayName: "LCM Sampler",
        category: "Diffusion",
        outputs: [.init(name: "function", type: .samplerFunction)],
        parameters: [
          .init(name: "stepNoise", valueType: .number, defaultValue: .number(1)),
          .init(name: "endStepNoise", valueType: .number, defaultValue: .number(1)),
          .init(
            name: "noiseClipStandardDeviations", valueType: .number, defaultValue: .number(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .qwenImage21TextEncoder,
        displayName: "Qwen-Image 2.1 Text Encoder",
        category: "Conditioning",
        inputs: [
          .init(name: "textEncoder", type: .textEncoderFunction),
          .init(name: "vae", type: .vaeFunction, isRequired: false),
          .init(name: "prompt", type: .string, isRequired: false),
          .init(name: "negativePrompt", type: .string, isRequired: false),
          .init(name: "referenceImage1", type: .image, isRequired: false),
          .init(name: "referenceImage2", type: .image, isRequired: false),
          .init(name: "referenceImage3", type: .image, isRequired: false),
          .init(name: "referenceImage4", type: .image, isRequired: false),
          .init(name: "referenceImage5", type: .image, isRequired: false),
          .init(name: "referenceImage6", type: .image, isRequired: false),
          .init(name: "referenceImage7", type: .image, isRequired: false),
          .init(name: "referenceImage8", type: .image, isRequired: false),
          .init(name: "referenceImage9", type: .image, isRequired: false),
          .init(name: "referenceImage10", type: .image, isRequired: false),
        ],
        outputs: [
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
          .init(name: "latent", type: .latent),
        ],
        parameters: [
          .init(name: "prompt", valueType: .string, defaultValue: .string("")),
          .init(name: "negativePrompt", valueType: .string, defaultValue: .string("")),
          .init(name: "resolution", valueType: .integer, defaultValue: .integer(1024)),
        ]),
      PipelineNodeDescriptor(
        kind: .textSplit,
        displayName: "Split Text",
        category: "Text",
        inputs: [.init(name: "text", type: .string)],
        outputs: [.init(name: "items", type: .stringList)],
        parameters: [
          .init(name: "separator", valueType: .string, defaultValue: .string("|")),
          .init(name: "trimItems", valueType: .boolean, defaultValue: .boolean(true)),
          .init(name: "omitEmpty", valueType: .boolean, defaultValue: .boolean(true)),
          .init(name: "maxItems", valueType: .integer, defaultValue: .integer(8)),
        ]),
      PipelineNodeDescriptor(
        kind: .textConcatenate,
        displayName: "Concatenate Text",
        category: "Text",
        inputs: [
          .init(name: "stringA", type: .string, isRequired: false),
          .init(name: "stringB", type: .string, isRequired: false),
          .init(name: "delimiter", type: .string, isRequired: false),
        ],
        outputs: [.init(name: "value", type: .string)],
        parameters: [
          .init(name: "stringA", valueType: .string, defaultValue: .string("")),
          .init(name: "stringB", valueType: .string, defaultValue: .string("")),
          .init(name: "delimiter", valueType: .string, defaultValue: .string("")),
        ]),
      PipelineNodeDescriptor(
        kind: .textReplace,
        displayName: "Replace Text",
        category: "Text",
        inputs: [
          .init(name: "string", type: .string, isRequired: false),
          .init(name: "find", type: .string, isRequired: false),
          .init(name: "replace", type: .string, isRequired: false),
        ],
        outputs: [.init(name: "value", type: .string)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string("")),
          .init(name: "find", valueType: .string, defaultValue: .string("")),
          .init(name: "replace", valueType: .string, defaultValue: .string("")),
        ]),
      PipelineNodeDescriptor(
        kind: .textRegexReplace,
        displayName: "Replace Text (Regex)",
        category: "Text",
        inputs: [
          .init(name: "string", type: .string, isRequired: false),
          .init(name: "pattern", type: .string, isRequired: false),
          .init(name: "replacement", type: .string, isRequired: false),
          .init(name: "caseInsensitive", type: .boolean, isRequired: false),
          .init(name: "multiline", type: .boolean, isRequired: false),
          .init(name: "dotAll", type: .boolean, isRequired: false),
          .init(name: "count", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "value", type: .string)],
        parameters: [
          .init(name: "string", valueType: .string, defaultValue: .string("")),
          .init(name: "pattern", valueType: .string, defaultValue: .string("")),
          .init(name: "replacement", valueType: .string, defaultValue: .string("")),
          .init(name: "caseInsensitive", valueType: .boolean, defaultValue: .boolean(true)),
          .init(name: "multiline", valueType: .boolean, defaultValue: .boolean(false)),
          .init(name: "dotAll", valueType: .boolean, defaultValue: .boolean(false)),
          .init(name: "count", valueType: .integer, defaultValue: .integer(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .textJSONExtract,
        displayName: "JSON Value",
        category: "Text",
        inputs: [
          .init(name: "json", type: .string, isRequired: false),
          .init(name: "key", type: .string, isRequired: false),
          .init(name: "setValue", type: .any, isRequired: false),
        ],
        outputs: [
          .init(name: "value", type: .string),
          .init(name: "json", type: .string),
          .init(name: "number", type: .number),
          .init(name: "boolean", type: .boolean),
          .init(name: "items", type: .stringList),
        ],
        parameters: [
          .init(name: "json", valueType: .string, defaultValue: .string("")),
          .init(name: "key", valueType: .string, defaultValue: .string("")),
        ]),
      PipelineNodeDescriptor(
        kind: .textGenerate,
        displayName: "Generate Text",
        category: "Text",
        inputs: [
          .init(name: "textEncoder", type: .textEncoderFunction),
          .init(name: "prompt", type: .string, isRequired: false),
          .init(name: "image", type: .image, isRequired: false),
          .init(name: "video", type: .image, isRequired: false),
          .init(name: "audio", type: .audio, isRequired: false),
        ],
        outputs: [.init(name: "text", type: .string)],
        parameters: [
          .init(name: "prompt", valueType: .string, defaultValue: .string("")),
          .init(name: "maxLength", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "samplingMode", valueType: .string, defaultValue: .string("on")),
        ]),
      PipelineNodeDescriptor(
        kind: .languageModel,
        displayName: "Core AI Language Model",
        category: "Models",
        outputs: [.init(name: "model", type: .languageModelFunction)],
        requiredResourceSlots: ["manifest", "model", "tokenizer"]),
      PipelineNodeDescriptor(
        kind: .chatCompletion,
        displayName: "Chat Completion",
        category: "Text",
        inputs: [
          .init(name: "model", type: .languageModelFunction),
          .init(name: "prompt", type: .string),
        ],
        outputs: [.init(name: "text", type: .string)],
        parameters: [
          .init(name: "systemPrompt", valueType: .string, defaultValue: .string("")),
          .init(name: "maxTokens", valueType: .integer, defaultValue: .integer(256)),
          .init(name: "temperature", valueType: .number, defaultValue: .number(0.7)),
          .init(name: "topK", valueType: .integer, defaultValue: .integer(40)),
          .init(name: "seed", valueType: .integer, defaultValue: .integer(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .previewAny,
        displayName: "Preview as Text",
        category: "Utilities",
        inputs: [.init(name: "value", type: .any, isRequired: false)],
        outputs: [.init(name: "text", type: .string)]),
      PipelineNodeDescriptor(
        kind: .textOutput,
        displayName: "Text Output",
        category: "Outputs",
        inputs: [.init(name: "text", type: .string)],
        outputs: [.init(name: "text", type: .string)],
        isTerminal: true),
      PipelineNodeDescriptor(
        kind: .videoOutput,
        displayName: "Video Output",
        category: "Outputs",
        inputs: [
          .init(name: "video", type: .video, isRequired: false),
          .init(name: "image", type: .image, isRequired: false),
          .init(name: "framesPerSecond", type: .number, isRequired: false),
        ],
        outputs: [.init(name: "video", type: .video)],
        parameters: [
          .init(name: "filenamePrefix", valueType: .string),
          .init(name: "format", valueType: .string),
          .init(name: "codec", valueType: .string),
          .init(name: "framesPerSecond", valueType: .number,
            defaultValue: .number(30)),
        ],
        isTerminal: true),
    ]
    descriptors += extendedCoreAIV1Descriptors
    descriptors += modelDesignDescriptors
    descriptors.append(PipelineNodeDescriptor(
      kind: .coreAIImageClassifier,
      displayName: "Core AI Image Classifier",
      category: "Models",
      inputs: [.init(name: "image", type: .image)],
      outputs: [
        .init(name: "prediction", type: .string),
        .init(name: "classIndex", type: .integer),
        .init(name: "scores", type: .string),
      ],
      parameters: [
        .init(name: "inputName", valueType: .string, defaultValue: .string("image")),
        .init(name: "outputName", valueType: .string, defaultValue: .string("scores")),
        .init(name: "width", valueType: .integer, defaultValue: .integer(28)),
        .init(name: "height", valueType: .integer, defaultValue: .integer(28)),
        .init(name: "channels", valueType: .integer, defaultValue: .integer(1)),
        .init(name: "classLabels", valueType: .string, defaultValue: .string("")),
      ],
      requiredResourceSlots: ["model"]))
    return PipelineNodeRegistry(descriptors)
  }

  /// Descriptors added after the first family integrations, grouped by the
  /// ComfyUI capability area they cover.
  static var extendedCoreAIV1Descriptors: [PipelineNodeDescriptor] {
    [
      inpaintingAndUpscalingDescriptors,
      imageEditingDescriptors,
      geometryDescriptors,
      conditioningDescriptors,
      guidanceDescriptors,
      samplingDescriptors,
      mediaDescriptors,
      utilityDescriptors,
    ].flatMap { $0 }
  }
}

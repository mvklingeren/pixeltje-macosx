import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let controlNetModel = PipelineNodeKind(rawValue: "coreai.controlNetModel")
  public static let controlNetUnionType = PipelineNodeKind(
    rawValue: "coreai.controlNetUnionType")
  public static let controlNetApply = PipelineNodeKind(rawValue: "conditioning.controlNetApply")
  public static let imageCanny = PipelineNodeKind(rawValue: "image.canny")
  public static let visionEncoderModel = PipelineNodeKind(rawValue: "coreai.visionEncoderModel")
  public static let visionEncode = PipelineNodeKind(rawValue: "conditioning.visionEncode")
  public static let unCLIPConditioning = PipelineNodeKind(rawValue: "conditioning.unCLIP")
  public static let styleModel = PipelineNodeKind(rawValue: "coreai.styleModel")
  public static let styleModelApply = PipelineNodeKind(rawValue: "conditioning.styleModelApply")
}

extension PipelineNodeRegistry {
  /// Structural and image-prompt guidance: ControlNet, edge preprocessing,
  /// vision-encoder embeddings and style models.
  static var guidanceDescriptors: [PipelineNodeDescriptor] {
    [
      PipelineNodeDescriptor(
        kind: .controlNetModel,
        displayName: "Core AI ControlNet Model",
        category: "Models",
        outputs: [.init(name: "function", type: .controlNetFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string)
        ],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .controlNetUnionType,
        displayName: "Set Union ControlNet Type",
        category: "Models",
        inputs: [.init(name: "controlNet", type: .controlNetFunction)],
        outputs: [.init(name: "controlNet", type: .controlNetFunction)],
        parameters: [
          .init(name: "unionType", valueType: .string, defaultValue: .string("auto"))
        ]),
      PipelineNodeDescriptor(
        kind: .controlNetApply,
        displayName: "Apply ControlNet",
        category: "Conditioning",
        inputs: [
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
          .init(name: "controlNet", type: .controlNetFunction),
          .init(name: "image", type: .image),
          // Required by ControlNets that consume latents, such as SD3's.
          .init(name: "vae", type: .vaeFunction, isRequired: false),
        ],
        outputs: [
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
        ],
        parameters: [
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
          .init(name: "startPercent", valueType: .number, defaultValue: .number(0)),
          .init(name: "endPercent", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageCanny,
        displayName: "Canny Edges",
        category: "Image",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "lowThreshold", valueType: .number, defaultValue: .number(0.4)),
          .init(name: "highThreshold", valueType: .number, defaultValue: .number(0.8)),
        ]),
      PipelineNodeDescriptor(
        kind: .visionEncoderModel,
        displayName: "Core AI Vision Encoder Model",
        category: "Models",
        outputs: [.init(name: "function", type: .visionEncoderFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string)
        ],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .visionEncode,
        displayName: "Vision Encode",
        category: "Conditioning",
        inputs: [
          .init(name: "visionEncoder", type: .visionEncoderFunction),
          .init(name: "image", type: .image),
        ],
        outputs: [.init(name: "embedding", type: .visionEmbedding)],
        parameters: [
          .init(name: "crop", valueType: .string, defaultValue: .string("center"))
        ]),
      PipelineNodeDescriptor(
        kind: .unCLIPConditioning,
        displayName: "unCLIP Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioning", type: .conditioning),
          .init(name: "embedding", type: .visionEmbedding),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
          .init(name: "noiseAugmentation", valueType: .number, defaultValue: .number(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .styleModel,
        displayName: "Core AI Style Model",
        category: "Models",
        outputs: [.init(name: "function", type: .styleModelFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string)
        ],
        requiredResourceSlots: ["model"]),
      PipelineNodeDescriptor(
        kind: .styleModelApply,
        displayName: "Apply Style Model",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioning", type: .conditioning),
          .init(name: "styleModel", type: .styleModelFunction),
          .init(name: "embedding", type: .visionEmbedding),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
          .init(name: "strengthType", valueType: .string, defaultValue: .string("multiply")),
        ]),
    ]
  }
}

import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let conditioningCombine = PipelineNodeKind(rawValue: "conditioning.combine")
  public static let conditioningConcat = PipelineNodeKind(rawValue: "conditioning.concat")
  public static let conditioningAverage = PipelineNodeKind(rawValue: "conditioning.average")
  public static let conditioningSetArea = PipelineNodeKind(rawValue: "conditioning.setArea")
  public static let conditioningSetAreaPercentage = PipelineNodeKind(
    rawValue: "conditioning.setAreaPercentage")
  public static let conditioningSetMask = PipelineNodeKind(rawValue: "conditioning.setMask")
  public static let conditioningSetTimestepRange = PipelineNodeKind(
    rawValue: "conditioning.setTimestepRange")
  public static let fluxGuidance = PipelineNodeKind(rawValue: "conditioning.fluxGuidance")
  public static let sdxlTextConditioningEncoder = PipelineNodeKind(
    rawValue: "conditioning.textEncodeSDXL")
  public static let fluxTextConditioningEncoder = PipelineNodeKind(
    rawValue: "conditioning.textEncodeFlux")
  public static let sdxlSizeConditioning = PipelineNodeKind(rawValue: "conditioning.sdxlSize")
  public static let textEncoderLastLayer = PipelineNodeKind(
    rawValue: "coreai.textEncoderLastLayer")
  public static let dualTextEncoderModel = PipelineNodeKind(
    rawValue: "coreai.dualTextEncoderModel")
  public static let tripleTextEncoderModel = PipelineNodeKind(
    rawValue: "coreai.tripleTextEncoderModel")
}

extension PipelineNodeRegistry {
  /// Prompt blending, regional prompting and multi-encoder text conditioning.
  static var conditioningDescriptors: [PipelineNodeDescriptor] {
    [
      PipelineNodeDescriptor(
        kind: .conditioningCombine,
        displayName: "Combine Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioningA", type: .conditioning),
          .init(name: "conditioningB", type: .conditioning),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)]),
      PipelineNodeDescriptor(
        kind: .conditioningConcat,
        displayName: "Concatenate Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioningTo", type: .conditioning),
          .init(name: "conditioningFrom", type: .conditioning),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)]),
      PipelineNodeDescriptor(
        kind: .conditioningAverage,
        displayName: "Average Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioningTo", type: .conditioning),
          .init(name: "conditioningFrom", type: .conditioning),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "conditioningToStrength", valueType: .number, defaultValue: .number(1))
        ]),
      PipelineNodeDescriptor(
        kind: .conditioningSetArea,
        displayName: "Set Conditioning Area",
        category: "Conditioning",
        inputs: [.init(name: "conditioning", type: .conditioning)],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(64)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(64)),
          .init(name: "x", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "y", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .conditioningSetAreaPercentage,
        displayName: "Set Conditioning Area (Percentage)",
        category: "Conditioning",
        inputs: [.init(name: "conditioning", type: .conditioning)],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "width", valueType: .number, defaultValue: .number(1)),
          .init(name: "height", valueType: .number, defaultValue: .number(1)),
          .init(name: "x", valueType: .number, defaultValue: .number(0)),
          .init(name: "y", valueType: .number, defaultValue: .number(0)),
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .conditioningSetMask,
        displayName: "Set Conditioning Mask",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioning", type: .conditioning),
          .init(name: "mask", type: .mask),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "strength", valueType: .number, defaultValue: .number(1)),
          .init(name: "conditionArea", valueType: .string, defaultValue: .string("default")),
        ]),
      PipelineNodeDescriptor(
        kind: .conditioningSetTimestepRange,
        displayName: "Set Conditioning Timestep Range",
        category: "Conditioning",
        inputs: [.init(name: "conditioning", type: .conditioning)],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "start", valueType: .number, defaultValue: .number(0)),
          .init(name: "end", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .fluxGuidance,
        displayName: "FLUX Guidance",
        category: "Conditioning",
        inputs: [.init(name: "conditioning", type: .conditioning)],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "guidance", valueType: .number, defaultValue: .number(3.5))
        ]),
      PipelineNodeDescriptor(
        kind: .sdxlTextConditioningEncoder,
        displayName: "SDXL Text Conditioning Encoder",
        category: "Conditioning",
        inputs: [
          .init(name: "textEncoder", type: .textEncoderFunction),
          .init(name: "textG", type: .string, isRequired: false),
          .init(name: "textL", type: .string, isRequired: false),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "textG", valueType: .string, defaultValue: .string("")),
          .init(name: "textL", valueType: .string, defaultValue: .string("")),
        ]),
      // SDXL's micro-conditioning: the original size, crop and target size
      // the model is told the image has.
      PipelineNodeDescriptor(
        kind: .sdxlSizeConditioning,
        displayName: "SDXL Size Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "conditioning", type: .conditioning),
          .init(name: "width", type: .integer, isRequired: false),
          .init(name: "height", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "cropW", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "cropH", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "targetWidth", valueType: .integer, defaultValue: .integer(1024)),
          .init(name: "targetHeight", valueType: .integer, defaultValue: .integer(1024)),
        ]),
      PipelineNodeDescriptor(
        kind: .fluxTextConditioningEncoder,
        displayName: "FLUX Text Conditioning Encoder",
        category: "Conditioning",
        inputs: [
          .init(name: "textEncoder", type: .textEncoderFunction),
          .init(name: "clipL", type: .string, isRequired: false),
          .init(name: "t5xxl", type: .string, isRequired: false),
        ],
        outputs: [.init(name: "conditioning", type: .conditioning)],
        parameters: [
          .init(name: "clipL", valueType: .string, defaultValue: .string("")),
          .init(name: "t5xxl", valueType: .string, defaultValue: .string("")),
        ]),
      PipelineNodeDescriptor(
        kind: .textEncoderLastLayer,
        displayName: "Text Encoder Last Layer",
        category: "Models",
        inputs: [.init(name: "textEncoder", type: .textEncoderFunction)],
        outputs: [.init(name: "textEncoder", type: .textEncoderFunction)],
        parameters: [
          // Negative values count back from the final layer: -1 uses all of
          // them, -2 skips the last one.
          .init(name: "stopAtClipLayer", valueType: .integer, defaultValue: .integer(-1))
        ]),
      PipelineNodeDescriptor(
        kind: .dualTextEncoderModel,
        displayName: "Core AI Dual Text Encoder Model",
        category: "Models",
        outputs: [.init(name: "function", type: .textEncoderFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string),
          .init(name: "secondaryModelName", valueType: .string),
          .init(name: "encoderType", valueType: .string),
          .init(name: "device", valueType: .string),
        ],
        requiredResourceSlots: ["model", "secondaryModel"]),
      PipelineNodeDescriptor(
        kind: .tripleTextEncoderModel,
        displayName: "Core AI Triple Text Encoder Model",
        category: "Models",
        outputs: [.init(name: "function", type: .textEncoderFunction)],
        parameters: [
          .init(name: "modelName", valueType: .string),
          .init(name: "secondaryModelName", valueType: .string),
          .init(name: "tertiaryModelName", valueType: .string),
        ],
        requiredResourceSlots: ["model", "secondaryModel", "tertiaryModel"]),
    ]
  }
}

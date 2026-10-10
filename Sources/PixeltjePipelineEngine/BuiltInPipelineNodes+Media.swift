import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let videoInput = PipelineNodeKind(rawValue: "input.video")
  public static let audioInput = PipelineNodeKind(rawValue: "input.audio")
  public static let videoComponents = PipelineNodeKind(rawValue: "media.videoComponents")
  public static let videoPreview = PipelineNodeKind(rawValue: "output.videoPreview")
  public static let emptyHunyuanLatentVideo = PipelineNodeKind(
    rawValue: "latent.emptyHunyuanVideo")
  public static let emptyLTXVLatentVideo = PipelineNodeKind(rawValue: "latent.emptyLTXVVideo")
  public static let wanImageToVideoConditioning = PipelineNodeKind(
    rawValue: "conditioning.wanImageToVideo")
  public static let vaeAudioEncoder = PipelineNodeKind(rawValue: "coreai.vaeAudioEncoder")
  public static let audioOutput = PipelineNodeKind(rawValue: "output.audio")
}

extension PipelineNodeRegistry {
  /// Video and audio inputs, video-model latents and conditioning, and the
  /// audio output.
  static var mediaDescriptors: [PipelineNodeDescriptor] {
    [
      PipelineNodeDescriptor(
        kind: .videoInput,
        displayName: "Source Video",
        category: "Inputs",
        outputs: [.init(name: "video", type: .video)],
        parameters: [
          .init(name: "sourceName", valueType: .string),
          .init(name: "uploadMode", valueType: .string),
        ]),
      PipelineNodeDescriptor(
        kind: .audioInput,
        displayName: "Source Audio",
        category: "Inputs",
        outputs: [.init(name: "audio", type: .audio)],
        parameters: [
          .init(name: "sourceName", valueType: .string)
        ]),
      PipelineNodeDescriptor(
        kind: .videoComponents,
        displayName: "Video Components",
        category: "Media",
        inputs: [.init(name: "video", type: .video)],
        outputs: [
          .init(name: "images", type: .image),
          .init(name: "audio", type: .audio),
          .init(name: "framesPerSecond", type: .number),
          .init(name: "bitDepth", type: .string),
          .init(name: "colorSpace", type: .string),
        ]),
      PipelineNodeDescriptor(
        kind: .videoPreview,
        displayName: "Video Preview",
        category: "Outputs",
        inputs: [
          .init(name: "video", type: .video, isRequired: false),
          .init(name: "image", type: .image, isRequired: false),
          .init(name: "frameIndex", type: .number, isRequired: false),
        ],
        outputs: [
          .init(name: "video", type: .video),
          .init(name: "image", type: .image),
        ],
        parameters: [
          .init(name: "framesPerSecond", valueType: .number,
            defaultValue: .number(30)),
        ]),
      PipelineNodeDescriptor(
        kind: .emptyHunyuanLatentVideo,
        displayName: "Empty Hunyuan Latent Video",
        category: "Latent",
        inputs: videoLatentSizeInputs,
        outputs: [.init(name: "latent", type: .latent)],
        parameters: videoLatentSizeParameters(width: 848, height: 480, length: 25)),
      PipelineNodeDescriptor(
        kind: .emptyLTXVLatentVideo,
        displayName: "Empty LTXV Latent Video",
        category: "Latent",
        inputs: videoLatentSizeInputs,
        outputs: [.init(name: "latent", type: .latent)],
        parameters: videoLatentSizeParameters(width: 768, height: 512, length: 97)),
      PipelineNodeDescriptor(
        kind: .wanImageToVideoConditioning,
        displayName: "Wan Image-to-Video Conditioning",
        category: "Conditioning",
        inputs: [
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
          .init(name: "vae", type: .vaeFunction),
          .init(name: "visionEmbedding", type: .visionEmbedding, isRequired: false),
          .init(name: "startImage", type: .image, isRequired: false),
          .init(name: "width", type: .integer, isRequired: false),
          .init(name: "height", type: .integer, isRequired: false),
          .init(name: "length", type: .integer, isRequired: false),
        ],
        outputs: [
          .init(name: "positive", type: .conditioning),
          .init(name: "negative", type: .conditioning),
          .init(name: "latent", type: .latent),
        ],
        parameters: videoLatentSizeParameters(width: 832, height: 480, length: 81)),
      PipelineNodeDescriptor(
        kind: .vaeAudioEncoder,
        displayName: "VAE Audio Encoder",
        category: "Models",
        inputs: [
          .init(name: "audio", type: .audio),
          .init(name: "vae", type: .vaeFunction),
        ],
        outputs: [.init(name: "latent", type: .latent)]),
      PipelineNodeDescriptor(
        kind: .audioOutput,
        displayName: "Audio Output",
        category: "Outputs",
        inputs: [.init(name: "audio", type: .audio)],
        outputs: [.init(name: "audio", type: .audio)],
        parameters: [
          .init(name: "filenamePrefix", valueType: .string)
        ],
        isTerminal: true),
    ]
  }

  private static var videoLatentSizeInputs: [PipelinePortDescriptor] {
    [
      .init(name: "width", type: .integer, isRequired: false),
      .init(name: "height", type: .integer, isRequired: false),
      .init(name: "length", type: .integer, isRequired: false),
    ]
  }

  private static func videoLatentSizeParameters(
    width: Int64,
    height: Int64,
    length: Int64
  ) -> [PipelineParameterDescriptor] {
    [
      .init(name: "width", valueType: .integer, defaultValue: .integer(width)),
      .init(name: "height", valueType: .integer, defaultValue: .integer(height)),
      .init(name: "length", valueType: .integer, defaultValue: .integer(length)),
      .init(name: "batchSize", valueType: .integer, defaultValue: .integer(1)),
    ]
  }
}

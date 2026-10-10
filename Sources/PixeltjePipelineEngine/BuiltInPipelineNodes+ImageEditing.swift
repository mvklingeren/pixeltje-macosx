import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let latentUpscale = PipelineNodeKind(rawValue: "latent.upscale")
  public static let latentUpscaleBy = PipelineNodeKind(rawValue: "latent.upscaleBy")
  public static let latentRepeatBatch = PipelineNodeKind(rawValue: "latent.repeatBatch")
  public static let latentFromBatch = PipelineNodeKind(rawValue: "latent.fromBatch")
  public static let imageScale = PipelineNodeKind(rawValue: "image.scale")
  public static let imageScaleBy = PipelineNodeKind(rawValue: "image.scaleBy")
  public static let imageCrop = PipelineNodeKind(rawValue: "image.crop")
  public static let imagePadForOutpaint = PipelineNodeKind(rawValue: "image.padForOutpaint")
  public static let imageInvert = PipelineNodeKind(rawValue: "image.invert")
  public static let imageBlend = PipelineNodeKind(rawValue: "image.blend")
  public static let imageProceduralNoise = PipelineNodeKind(rawValue: "image.proceduralNoise")
  public static let imageSinusoid = PipelineNodeKind(rawValue: "image.sinusoid")
  public static let signalSinusoid = PipelineNodeKind(rawValue: "signal.sinusoid")
  public static let imageDrawCurve = PipelineNodeKind(rawValue: "image.drawCurve")
  public static let imageTranslate = PipelineNodeKind(rawValue: "image.translate")
  public static let imageCompositeMasked = PipelineNodeKind(rawValue: "image.compositeMasked")
  public static let imageBatch = PipelineNodeKind(rawValue: "image.batch")
  public static let imageFromBatch = PipelineNodeKind(rawValue: "image.fromBatch")
  public static let maskInvert = PipelineNodeKind(rawValue: "mask.invert")
  public static let maskGrow = PipelineNodeKind(rawValue: "mask.grow")
  public static let maskFeather = PipelineNodeKind(rawValue: "mask.feather")
  public static let maskComposite = PipelineNodeKind(rawValue: "mask.composite")
  public static let maskSolid = PipelineNodeKind(rawValue: "mask.solid")
  public static let maskRadial = PipelineNodeKind(rawValue: "mask.radial")
  public static let maskStripes = PipelineNodeKind(rawValue: "mask.stripes")
  public static let maskFromImage = PipelineNodeKind(rawValue: "mask.fromImage")
  public static let maskToImage = PipelineNodeKind(rawValue: "mask.toImage")
  public static let maskThreshold = PipelineNodeKind(rawValue: "mask.threshold")
  public static let maskCrop = PipelineNodeKind(rawValue: "mask.crop")
  public static let vaeTiledImageEncoder = PipelineNodeKind(
    rawValue: "coreai.vaeTiledImageEncoder")
  public static let vaeTiledImageDecoder = PipelineNodeKind(
    rawValue: "coreai.vaeTiledImageDecoder")
}

extension PipelineNodeRegistry {
  /// Pixel, mask and latent operations used by img2img, hires-fix, outpaint
  /// and compositing workflows. None of them runs a learned model except the
  /// tiled VAE nodes, which bound peak memory for large images.
  static var imageEditingDescriptors: [PipelineNodeDescriptor] {
    [
      PipelineNodeDescriptor(
        kind: .latentUpscale,
        displayName: "Upscale Latent",
        category: "Latent",
        inputs: [
          .init(name: "latent", type: .latent),
          .init(name: "width", type: .integer, isRequired: false),
          .init(name: "height", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "upscaleMethod", valueType: .string, defaultValue: .string("nearest-exact")),
          .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "crop", valueType: .string, defaultValue: .string("disabled")),
        ]),
      PipelineNodeDescriptor(
        kind: .latentUpscaleBy,
        displayName: "Upscale Latent By",
        category: "Latent",
        inputs: [.init(name: "latent", type: .latent)],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "upscaleMethod", valueType: .string, defaultValue: .string("nearest-exact")),
          .init(name: "scaleBy", valueType: .number, defaultValue: .number(1.5)),
        ]),
      PipelineNodeDescriptor(
        kind: .latentRepeatBatch,
        displayName: "Repeat Latent Batch",
        category: "Latent",
        inputs: [.init(name: "latent", type: .latent)],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "amount", valueType: .integer, defaultValue: .integer(1))
        ]),
      PipelineNodeDescriptor(
        kind: .latentFromBatch,
        displayName: "Latent from Batch",
        category: "Latent",
        inputs: [.init(name: "latent", type: .latent)],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: [
          .init(name: "batchIndex", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "length", valueType: .integer, defaultValue: .integer(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageScale,
        displayName: "Scale Image",
        category: "Image",
        inputs: [
          .init(name: "image", type: .image),
          .init(name: "width", type: .integer, isRequired: false),
          .init(name: "height", type: .integer, isRequired: false),
        ],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "upscaleMethod", valueType: .string, defaultValue: .string("nearest-exact")),
          .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "crop", valueType: .string, defaultValue: .string("disabled")),
        ]),
      PipelineNodeDescriptor(
        kind: .imageScaleBy,
        displayName: "Scale Image By",
        category: "Image",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "upscaleMethod", valueType: .string, defaultValue: .string("nearest-exact")),
          .init(name: "scaleBy", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageCrop,
        displayName: "Crop Image",
        category: "Image",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "x", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "y", valueType: .integer, defaultValue: .integer(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .imagePadForOutpaint,
        displayName: "Pad Image for Outpainting",
        category: "Image",
        inputs: [.init(name: "image", type: .image)],
        outputs: [
          .init(name: "image", type: .image),
          .init(name: "mask", type: .mask),
        ],
        parameters: [
          .init(name: "left", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "top", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "right", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "bottom", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "feathering", valueType: .integer, defaultValue: .integer(40)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageInvert,
        displayName: "Invert Image",
        category: "Image",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "image", type: .image)]),
      PipelineNodeDescriptor(
        kind: .imageProceduralNoise,
        displayName: "Procedural Noise Image",
        category: "Image",
        inputs: [.init(name: "seed", type: .seed)],
        outputs: [
          .init(name: "image", type: .image),
          .init(name: "height", type: .mask),
        ],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "scale", valueType: .number, defaultValue: .number(6)),
          .init(name: "octaves", valueType: .integer, defaultValue: .integer(4)),
          .init(name: "salt", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "pattern", valueType: .string, defaultValue: .string("smooth")),
          .init(name: "palette", valueType: .string, defaultValue: .string("aurora")),
        ]),
      PipelineNodeDescriptor(
        kind: .imageSinusoid,
        displayName: "Sinus Generator (Legacy)",
        category: "Image",
        inputs: [
          .init(name: "frequencyControl", type: .number, isRequired: false),
          .init(name: "amplitudeControl", type: .number, isRequired: false),
        ],
        outputs: [
          .init(name: "image", type: .image),
          .init(name: "mask", type: .mask),
        ],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(960)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(600)),
          .init(name: "cycles", valueType: .number, defaultValue: .number(3)),
          .init(name: "amplitude", valueType: .number, defaultValue: .number(0.25)),
          .init(name: "phaseDegrees", valueType: .number, defaultValue: .number(0)),
          .init(name: "centerY", valueType: .number, defaultValue: .number(0.5)),
          .init(name: "strokeWidth", valueType: .number, defaultValue: .number(3)),
          .init(name: "color", valueType: .string, defaultValue: .string("red")),
        ]),
      PipelineNodeDescriptor(
        kind: .signalSinusoid,
        displayName: "Sinusoid",
        category: "Signal",
        inputs: [
          .init(name: "frequencyControl", type: .number, isRequired: false),
          .init(name: "amplitudeControl", type: .number, isRequired: false),
          .init(name: "phaseShiftDegrees", type: .number, isRequired: false),
        ],
        outputs: [.init(name: "curve", type: .curve1D)],
        parameters: [
          .init(name: "cycles", valueType: .number, defaultValue: .number(4)),
          .init(name: "amplitude", valueType: .number, defaultValue: .number(0.25)),
          .init(name: "phaseDegrees", valueType: .number, defaultValue: .number(0)),
          .init(name: "centerY", valueType: .number, defaultValue: .number(0.5)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageDrawCurve,
        displayName: "Draw Curve",
        category: "Image",
        inputs: [
          .init(name: "curve", type: .curve1D),
          .init(name: "background", type: .image, isRequired: false),
        ],
        outputs: [
          .init(name: "image", type: .image),
          .init(name: "mask", type: .mask),
        ],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(960)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(600)),
          .init(name: "strokeWidth", valueType: .number, defaultValue: .number(3)),
          .init(name: "color", valueType: .string, defaultValue: .string("red")),
          .init(name: "opacity", valueType: .number, defaultValue: .number(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageTranslate,
        displayName: "Translate Image",
        category: "Image",
        inputs: [
          .init(name: "image", type: .image),
          .init(name: "x", type: .integer, isRequired: false),
          .init(name: "y", type: .integer, isRequired: false),
          .init(name: "normalizedX", type: .number, isRequired: false),
          .init(name: "normalizedY", type: .number, isRequired: false),
        ],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "x", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "y", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "wrap", valueType: .boolean, defaultValue: .boolean(true)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageBlend,
        displayName: "Blend Images",
        category: "Image",
        inputs: [
          .init(name: "imageA", type: .image),
          .init(name: "imageB", type: .image),
          .init(name: "blendFactor", type: .number, isRequired: false),
        ],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "blendFactor", valueType: .number, defaultValue: .number(0.5)),
          .init(name: "blendMode", valueType: .string, defaultValue: .string("normal")),
        ]),
      PipelineNodeDescriptor(
        kind: .imageCompositeMasked,
        displayName: "Composite Image (Masked)",
        category: "Image",
        inputs: [
          .init(name: "destination", type: .image),
          .init(name: "source", type: .image),
          .init(name: "mask", type: .mask, isRequired: false),
        ],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "x", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "y", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "resizeSource", valueType: .boolean, defaultValue: .boolean(false)),
        ]),
      PipelineNodeDescriptor(
        kind: .imageBatch,
        displayName: "Batch Images",
        category: "Image",
        inputs: [
          .init(name: "imageA", type: .image),
          .init(name: "imageB", type: .image),
        ],
        outputs: [.init(name: "image", type: .image)]),
      PipelineNodeDescriptor(
        kind: .imageFromBatch,
        displayName: "Image from Batch",
        category: "Image",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "image", type: .image)],
        parameters: [
          .init(name: "batchIndex", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "length", valueType: .integer, defaultValue: .integer(1)),
        ]),
      PipelineNodeDescriptor(
        kind: .maskInvert,
        displayName: "Invert Mask",
        category: "Mask",
        inputs: [.init(name: "mask", type: .mask)],
        outputs: [.init(name: "mask", type: .mask)]),
      PipelineNodeDescriptor(
        kind: .maskGrow,
        displayName: "Grow Mask",
        category: "Mask",
        inputs: [.init(name: "mask", type: .mask)],
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "expand", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "taperedCorners", valueType: .boolean, defaultValue: .boolean(true)),
        ]),
      PipelineNodeDescriptor(
        kind: .maskFeather,
        displayName: "Feather Mask",
        category: "Mask",
        inputs: [.init(name: "mask", type: .mask)],
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "left", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "top", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "right", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "bottom", valueType: .integer, defaultValue: .integer(0)),
        ]),
      PipelineNodeDescriptor(
        kind: .maskComposite,
        displayName: "Composite Mask",
        category: "Mask",
        inputs: [
          .init(name: "destination", type: .mask),
          .init(name: "source", type: .mask),
        ],
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "x", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "y", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "operation", valueType: .string, defaultValue: .string("multiply")),
        ]),
      PipelineNodeDescriptor(
        kind: .maskSolid,
        displayName: "Solid Mask",
        category: "Mask",
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "value", valueType: .number, defaultValue: .number(1)),
          .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
        ]),
      PipelineNodeDescriptor(
        kind: .maskRadial,
        displayName: "Radial Mask",
        category: "Mask",
        inputs: [
          .init(name: "centerX", type: .number, isRequired: false),
          .init(name: "centerY", type: .number, isRequired: false),
        ],
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "centerX", valueType: .number, defaultValue: .number(0.5)),
          .init(name: "centerY", valueType: .number, defaultValue: .number(0.5)),
          .init(name: "radius", valueType: .number, defaultValue: .number(0.3)),
          .init(name: "softness", valueType: .number, defaultValue: .number(0.15)),
        ]),
      PipelineNodeDescriptor(
        kind: .maskStripes,
        displayName: "Stripe Mask",
        category: "Mask",
        inputs: [.init(name: "phase", type: .number, isRequired: false)],
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "count", valueType: .integer, defaultValue: .integer(12)),
          .init(name: "duty", valueType: .number, defaultValue: .number(0.35)),
          .init(name: "phase", valueType: .number, defaultValue: .number(0)),
          .init(name: "orientation", valueType: .string, defaultValue: .string("horizontal")),
        ]),
      PipelineNodeDescriptor(
        kind: .maskFromImage,
        displayName: "Mask from Image Channel",
        category: "Mask",
        inputs: [.init(name: "image", type: .image)],
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "channel", valueType: .string, defaultValue: .string("red"))
        ]),
      PipelineNodeDescriptor(
        kind: .maskToImage,
        displayName: "Mask to Image",
        category: "Mask",
        inputs: [.init(name: "mask", type: .mask)],
        outputs: [.init(name: "image", type: .image)]),
      PipelineNodeDescriptor(
        kind: .maskThreshold,
        displayName: "Threshold Mask",
        category: "Mask",
        inputs: [
          .init(name: "mask", type: .mask),
          .init(name: "value", type: .number, isRequired: false),
        ],
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "value", valueType: .number, defaultValue: .number(0.5))
        ]),
      PipelineNodeDescriptor(
        kind: .maskCrop,
        displayName: "Crop Mask",
        category: "Mask",
        inputs: [.init(name: "mask", type: .mask)],
        outputs: [.init(name: "mask", type: .mask)],
        parameters: [
          .init(name: "x", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "y", valueType: .integer, defaultValue: .integer(0)),
          .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
        ]),
      PipelineNodeDescriptor(
        kind: .vaeTiledImageEncoder,
        displayName: "VAE Tiled Image Encoder",
        category: "Models",
        inputs: [
          .init(name: "image", type: .image),
          .init(name: "vae", type: .vaeFunction),
        ],
        outputs: [.init(name: "latent", type: .latent)],
        parameters: tiledVAEParameters),
      PipelineNodeDescriptor(
        kind: .vaeTiledImageDecoder,
        displayName: "VAE Tiled Image Decoder",
        category: "Models",
        inputs: [
          .init(name: "latent", type: .latent),
          .init(name: "vae", type: .vaeFunction),
        ],
        outputs: [.init(name: "image", type: .image)],
        parameters: tiledVAEParameters),
    ]
  }

  /// Spatial tile size and overlap in pixels; temporal size and overlap in
  /// frames for video VAEs.
  private static var tiledVAEParameters: [PipelineParameterDescriptor] {
    [
      .init(name: "tileSize", valueType: .integer, defaultValue: .integer(512)),
      .init(name: "overlap", valueType: .integer, defaultValue: .integer(64)),
      .init(name: "temporalSize", valueType: .integer, defaultValue: .integer(64)),
      .init(name: "temporalOverlap", valueType: .integer, defaultValue: .integer(8)),
    ]
  }
}

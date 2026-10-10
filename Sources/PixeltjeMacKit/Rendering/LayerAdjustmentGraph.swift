import CoreGraphics
import CoreImage
import Foundation
import PixeltjeMacDomain

/// The post-RAW adjustment graph of one layer.
///
/// Every stage here is an explicit user edit. A neutral recipe adds no filter
/// at all, so the developed RAW passes through untouched and nothing is ever
/// applied on top of `CIRAWFilter` by default.
///
/// Color: images arrive in the Extended Linear Display P3 working space and
/// leave in it. Stages marked *linear* operate on those values directly. The
/// tone LUT stage (blacks, whites, contrast) operates in the Display P3
/// transfer encoding — the sRGB curve over P3 primaries — because tone shaping
/// is designed against perceptual values. That conversion is explicit:
/// `CILinearToSRGBToneCurve` before the LUT and `CISRGBToneCurveToLinear`
/// after it. The LUT covers the display-referred 0…1 range; while a LUT stage
/// is active, values above 1.0 clip to 1.0.
///
/// Scale: local operations take their radii from the image being processed, as
/// a fraction of its long edge, so a proxy and a full-resolution render of the
/// same recipe agree. Sharpening, whose radius is stated in canvas pixels, is
/// the exception and is scaled through `pixelScale`.
enum LayerAdjustmentGraph {
  /// Runs the layer's adjustments over `image`.
  ///
  /// - Parameter pixelScale: image pixels per canvas pixel. A 2048-wide proxy
  ///   of a 6000-wide canvas has a scale of about 0.34.
  static func apply(
    _ adjustments: LayerAdjustments,
    to image: CIImage,
    pixelScale: Double
  ) -> CIImage {
    guard !adjustments.isNeutral, !image.extent.isEmpty, !image.extent.isInfinite else {
      return image
    }
    // Order: noise reduction cleans the image before tone shaping amplifies
    // what is in it, and sharpening comes last so it acts on the tones the
    // user is actually looking at.
    var output = image
    output = applyNoiseReduction(adjustments.detail, to: output, pixelScale: pixelScale)
    output = applyBasicTone(adjustments.basicTone, to: output)
    output = applyToneCurve(adjustments.toneCurve, to: output)
    output = applyColorMixer(adjustments.colorMixer, to: output)
    output = applyColorGrading(adjustments.colorGrading, to: output)
    output = applySharpening(adjustments.detail, to: output, pixelScale: pixelScale)
    return output
  }

  /// Applies the recipe carried by an adjustment layer or a mask.
  ///
  /// This is deliberately the same graph used by per-layer adjustments, so
  /// group scope and mask coverage change *where* an edit acts, never its math
  /// or color-space contract.
  static func apply(_ adjustment: AdjustmentRecipe, to image: CIImage) -> CIImage {
    switch adjustment {
    case .exposure(let ev):
      guard ev != 0 else { return image }
      return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
    case .colorControls(let brightness, let contrast, let saturation):
      guard brightness != 0 || contrast != 1 || saturation != 1 else { return image }
      return image.applyingFilter(
        "CIColorControls",
        parameters: [
          kCIInputBrightnessKey: brightness,
          kCIInputContrastKey: contrast,
          kCIInputSaturationKey: saturation,
        ])
    case .curves(let curve):
      return applyToneCurve(curve, to: image)
    case .levels(let levels):
      return applyLevels(levels, to: image)
    case .hueSaturation(let adjustment):
      return applyHueSaturation(adjustment, to: image)
    case .blackAndWhite(let adjustment):
      return applyBlackAndWhite(adjustment, to: image)
    case .colorLookup(let adjustment):
      return applyColorLookup(adjustment, to: image)
    case .gradientMap(let adjustment):
      return applyGradientMap(adjustment, to: image)
    case .invert:
      return image.applyingFilter("CIColorInvert")
    }
  }

  // MARK: - Color mixer and grading

  /// HSL-style mixer in the downstream linear working graph.
  ///
  /// Each band is selected by an opponent-color hue mask. Hue moves at most
  /// 30 degrees, saturation scales 0…2, and luminance moves by one stop. Masks
  /// are always measured from the unedited input, so changing one band cannot
  /// make pixels jump into another band during a rapid slider gesture.
  static func applyColorMixer(_ mixer: ColorMixerRecipe, to image: CIImage) -> CIImage {
    guard !mixer.isNeutral else { return image }
    var output = image
    for channel in ColorMixerChannel.allCases {
      let edit = mixer[channel]
      guard !edit.isNeutral else { continue }
      let radians = channel.centerDegrees * .pi / 180
      let mask = hueBandMask(image, center: radians)
      var changed = output
      if edit.hue != 0 {
        changed = changed.applyingFilter(
          "CIHueAdjust",
          parameters: [kCIInputAngleKey: clamp(edit.hue, -100, 100) / 100 * .pi / 6])
      }
      if edit.saturation != 0 {
        changed = changed.applyingFilter(
          "CIColorControls",
          parameters: [
            kCIInputSaturationKey: clamp(1 + edit.saturation / 100, 0, 2)
          ])
      }
      if edit.luminance != 0 {
        changed = changed.applyingFilter(
          "CIExposureAdjust",
          parameters: [kCIInputEVKey: clamp(edit.luminance / 100, -1, 1)])
      }
      output = blend(changed, over: output, mask: mask)
    }
    return output.cropped(to: image.extent)
  }

  /// A current-Core-Image-only hue band mask: project RGB chroma onto the
  /// selected opponent-color direction, then soften and clamp that scalar.
  /// Neutral gray projects to zero, adjacent named bands overlap smoothly,
  /// and no runtime kernel language or private filter is involved.
  private static func hueBandMask(_ image: CIImage, center: Double) -> CIImage {
    let cosine = cos(center)
    let sine = sin(center)
    let red = cosine
    let green = -0.5 * cosine + 0.8660254037844386 * sine
    let blue = -0.5 * cosine - 0.8660254037844386 * sine
    let projection = CIVector(x: red, y: green, z: blue, w: 0)
    let gray = image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": projection,
        "inputGVector": projection,
        "inputBVector": projection,
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ])
    return smoothStep(gray, from: 0.01, to: 0.25, inverted: false)
  }

  /// Three overlapping slope/offset grades in Extended Linear Display P3.
  ///
  /// Hue and saturation produce channel slopes centred on 1, luminance an
  /// equal RGB offset, and power is fixed at 1. This is deterministic ASC CDL
  /// math without a display-referred detour. Blending controls transition
  /// width; balance moves both split points. Midtones are the overlap left by
  /// the inverted shadow and highlight weights.
  static func applyColorGrading(_ grading: ColorGradingRecipe, to image: CIImage) -> CIImage {
    guard !grading.isNeutral else { return image }
    let luminance = linearLuminance(image)
    let balance = clamp(grading.balance, -100, 100) / 100 * 0.18
    let width = 0.06 + clamp(grading.blending, 0, 100) / 100 * 0.28
    let shadowSplit = clamp(0.34 + balance, 0.12, 0.58)
    let highlightSplit = clamp(0.66 + balance, 0.42, 0.88)
    let shadowMask = smoothStep(
      luminance, from: shadowSplit - width / 2, to: shadowSplit + width / 2, inverted: true)
    let highlightMask = smoothStep(
      luminance, from: highlightSplit - width / 2, to: highlightSplit + width / 2,
      inverted: false)
    let midtoneMask =
      shadowMask
      .applyingFilter(
        "CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: highlightMask]
      )
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
          "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])

    var output = image
    for (wheel, mask) in [
      (grading.shadows, shadowMask),
      (grading.midtones, midtoneMask),
      (grading.highlights, highlightMask),
    ] where !wheel.isNeutral {
      output = blend(applyCDL(wheel, to: output), over: output, mask: mask)
    }
    return output.cropped(to: image.extent)
  }

  private static func applyCDL(_ wheel: ColorGradingWheel, to image: CIImage) -> CIImage {
    let angle = wheel.hue * .pi / 180
    let strength = clamp(wheel.saturation, 0, 100) / 100 * 0.28
    let red = 1 + cos(angle) * strength
    let green = 1 + cos(angle - 2 * .pi / 3) * strength
    let blue = 1 + cos(angle + 2 * .pi / 3) * strength
    let offset = clamp(wheel.luminance, -100, 100) / 100 * 0.25
    return image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0),
        "inputBiasVector": CIVector(x: offset, y: offset, z: offset, w: 0),
      ])
  }

  /// Display P3 luminance without a transfer-curve conversion. Color-grading
  /// range masks use this so both their selection and their CDL operation stay
  /// in the linear working space.
  private static func linearLuminance(_ image: CIImage) -> CIImage {
    let weights = CIVector(x: 0.2290, y: 0.6917, z: 0.0793, w: 0)
    return image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": weights,
        "inputGVector": weights,
        "inputBVector": weights,
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ])
  }

  // MARK: - Adjustment layers

  static func applyLevels(_ levels: LevelsAdjustment, to image: CIImage) -> CIImage {
    guard !levels.isNeutral else { return image }
    let black = clamp(levels.blackPoint, 0, 0.99)
    let white = clamp(levels.whitePoint, black + 0.01, 1)
    let gamma = clamp(levels.gamma, 0.1, 10)
    let count = ToneLookupTable.defaultSampleCount
    var table: [Float] = []
    table.reserveCapacity(count * 3)
    for index in 0..<count {
      let input = Double(index) / Double(count - 1)
      let value = pow(clamp((input - black) / (white - black), 0, 1), 1 / gamma)
      table.append(contentsOf: [Float(value), Float(value), Float(value)])
    }
    return applyLookupTable(table, to: image)
  }

  static func applyHueSaturation(
    _ adjustment: HueSaturationAdjustment, to image: CIImage
  ) -> CIImage {
    guard !adjustment.isNeutral else { return image }
    var output = image
    if adjustment.hue != 0 {
      output = output.applyingFilter(
        "CIHueAdjust",
        parameters: [kCIInputAngleKey: clamp(adjustment.hue, -180, 180) * .pi / 180])
    }
    if adjustment.saturation != 0 {
      output = output.applyingFilter(
        "CIColorControls",
        parameters: [kCIInputSaturationKey: clamp(1 + adjustment.saturation / 100, 0, 2)])
    }
    if adjustment.lightness != 0 {
      output = output.applyingFilter(
        "CIExposureAdjust",
        parameters: [kCIInputEVKey: clamp(adjustment.lightness / 100, -1, 1)])
    }
    return output.cropped(to: image.extent)
  }

  static func applyBlackAndWhite(
    _ adjustment: BlackAndWhiteAdjustment, to image: CIImage
  ) -> CIImage {
    guard !adjustment.isNeutral else { return image }
    let sum = max(adjustment.redWeight + adjustment.greenWeight + adjustment.blueWeight, 0.001)
    let weights = CIVector(
      x: adjustment.redWeight / sum,
      y: adjustment.greenWeight / sum,
      z: adjustment.blueWeight / sum,
      w: 0)
    let monochrome = image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": weights,
        "inputGVector": weights,
        "inputBVector": weights,
      ])
    return mix(image, toward: monochrome, amount: adjustment.amount)
  }

  static func applyColorLookup(_ lookup: ColorLookupAdjustment, to image: CIImage) -> CIImage {
    guard !lookup.isNeutral else { return image }
    let transformed: CIImage
    switch lookup.style {
    case .cinematic:
      transformed = colorMatrix(
        image, red: (0.95, 0.02, 0.03), green: (0.02, 0.98, 0), blue: (0.08, 0.04, 0.88))
    case .warm:
      transformed = colorMatrix(
        image, red: (1.08, 0.02, 0), green: (0.01, 1, 0), blue: (0, 0.02, 0.92))
    case .cool:
      transformed = colorMatrix(
        image, red: (0.94, 0.02, 0.04), green: (0, 1, 0), blue: (0, 0.02, 1.08))
    case .faded:
      transformed = image.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0.82, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0.82, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0.82, w: 0),
          "inputBiasVector": CIVector(x: 0.06, y: 0.055, z: 0.05, w: 0),
        ])
    }
    return mix(image, toward: transformed, amount: lookup.amount)
  }

  static func applyGradientMap(_ map: GradientMapAdjustment, to image: CIImage) -> CIImage {
    guard !map.isNeutral else { return image }
    var (low, high): ((Double, Double, Double), (Double, Double, Double))
    switch map.style {
    case .blackAndWhite: (low, high) = ((0, 0, 0), (1, 1, 1))
    case .sepia: (low, high) = ((0.04, 0.015, 0.005), (1, 0.78, 0.42))
    case .blueOrange: (low, high) = ((0.015, 0.04, 0.16), (1, 0.46, 0.08))
    }
    if map.reversed { swap(&low, &high) }
    let weights = (0.2290, 0.6917, 0.0793)
    func vector(_ range: Double) -> CIVector {
      CIVector(x: weights.0 * range, y: weights.1 * range, z: weights.2 * range, w: 0)
    }
    let mapped = image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": vector(high.0 - low.0),
        "inputGVector": vector(high.1 - low.1),
        "inputBVector": vector(high.2 - low.2),
        "inputBiasVector": CIVector(x: low.0, y: low.1, z: low.2, w: 0),
      ])
    return mix(image, toward: mapped, amount: map.amount)
  }

  private static func colorMatrix(
    _ image: CIImage,
    red: (Double, Double, Double),
    green: (Double, Double, Double),
    blue: (Double, Double, Double)
  ) -> CIImage {
    image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: red.0, y: red.1, z: red.2, w: 0),
        "inputGVector": CIVector(x: green.0, y: green.1, z: green.2, w: 0),
        "inputBVector": CIVector(x: blue.0, y: blue.1, z: blue.2, w: 0),
      ])
  }

  // MARK: - Detail

  /// Luminance and color noise reduction, both linear.
  ///
  /// Luminance noise goes through `CINoiseReduction`, whose noise level is the
  /// threshold below which a difference is treated as noise. Color noise is a
  /// chroma-only blur: because blurring is linear, keeping the original
  /// luminance and taking the chroma from a blurred copy is exactly
  /// `luminanceOf(image) + chromaOf(blur(image))`, and each half is one
  /// `CIColorMatrix`. Both halves are doubled and averaged with `CIMix`, which
  /// is how two images are summed without an unclamped add. The amount then
  /// blends the result back toward the original.
  ///
  /// On a developed RAW layer, Apple's own noise reduction is a separate,
  /// capability-driven `CIRAWFilter` control; this is an explicit extra edit
  /// and is neutral until the user asks for it.
  static func applyNoiseReduction(
    _ detail: DetailRecipe, to image: CIImage, pixelScale: Double
  ) -> CIImage {
    var output = image
    let extent = image.extent
    if detail.luminanceNoise > 0 {
      let amount = clamp(detail.luminanceNoise / 100, 0, 1)
      output =
        output.clampedToExtent()
        .applyingFilter(
          "CINoiseReduction",
          parameters: [
            "inputNoiseLevel": 0.005 + amount * 0.055,
            "inputSharpness": 0.4,
          ]
        )
        .cropped(to: extent)
    }
    if detail.colorNoise > 0 {
      let amount = clamp(detail.colorNoise / 100, 0, 1)
      // Radius is stated in canvas pixels so a proxy matches a full render.
      let radius = max(0.8, 6 * amount * max(pixelScale, 0.05))
      output = chromaDenoise(output, amount: amount, radius: radius)
    }
    return output
  }

  private static func chromaDenoise(
    _ image: CIImage, amount: Double, radius: Double
  ) -> CIImage {
    let extent = image.extent
    // Display P3 luminance weights, doubled for the averaging mix below.
    let (wr, wg, wb) = (0.2290, 0.6917, 0.0793)
    let luminance = image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 2 * wr, y: 2 * wg, z: 2 * wb, w: 0),
        "inputGVector": CIVector(x: 2 * wr, y: 2 * wg, z: 2 * wb, w: 0),
        "inputBVector": CIVector(x: 2 * wr, y: 2 * wg, z: 2 * wb, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 2),
      ]
    )
    // Identity minus the luminance broadcast: what is left is chroma only.
    // Alpha is dropped here so the averaged alpha comes from the luminance
    // half alone and stays exactly the original alpha.
    let chroma = lowPass(image, radius: radius).applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 2 - 2 * wr, y: -2 * wg, z: -2 * wb, w: 0),
        "inputGVector": CIVector(x: -2 * wr, y: 2 - 2 * wg, z: -2 * wb, w: 0),
        "inputBVector": CIVector(x: -2 * wr, y: -2 * wg, z: 2 - 2 * wb, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      ]
    )
    let denoised =
      chroma
      .applyingFilter(
        "CIMix",
        parameters: [kCIInputBackgroundImageKey: luminance, kCIInputAmountKey: 0.5]
      )
      .cropped(to: extent)
    return mix(image, toward: denoised, amount: amount)
  }

  /// Sharpening, linear, with an edge mask.
  ///
  /// Amount and radius are one `CIUnsharpMask`; detail is a second, finer pass
  /// on top of it. Masking builds an edge mask from the unsharpened image and
  /// blends the sharpened result through it, so flat areas keep their noise
  /// unamplified. Radius is stated in canvas pixels and converted here, which
  /// is the one place `pixelScale` is needed.
  static func applySharpening(
    _ detail: DetailRecipe, to image: CIImage, pixelScale: Double
  ) -> CIImage {
    guard detail.sharpens else { return image }
    let extent = image.extent
    let radius = max(0.4, detail.sharpenRadius * max(pixelScale, 0.05))
    let amount = clamp(detail.sharpenAmount / 100, 0, 1)
    var sharpened =
      image.clampedToExtent()
      .applyingFilter(
        "CIUnsharpMask",
        parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: amount * 1.2]
      )
      .cropped(to: extent)
    if detail.sharpenDetail > 0 {
      let fine = clamp(detail.sharpenDetail / 100, 0, 1)
      sharpened =
        sharpened.clampedToExtent()
        .applyingFilter(
          "CIUnsharpMask",
          parameters: [
            kCIInputRadiusKey: max(0.4, radius * 0.4),
            kCIInputIntensityKey: amount * fine * 0.6,
          ]
        )
        .cropped(to: extent)
    }
    guard detail.sharpenMasking > 0 else { return sharpened }
    let mask = edgeMask(
      image,
      strength: clamp(detail.sharpenMasking / 100, 0, 1),
      radius: max(1, radius)
    )
    return blend(sharpened, over: image, mask: mask)
  }

  /// A white-on-edges mask. `strength` raises the threshold an edge must clear,
  /// so 0 passes nearly everything and 1 keeps only the strongest edges.
  static func edgeMask(_ image: CIImage, strength: Double, radius: Double) -> CIImage {
    let extent = image.extent
    let edges = image.clampedToExtent()
      .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4.0])
      .cropped(to: extent)
    // Perceptual luminance of the edge magnitude, blurred so the mask covers
    // the neighbourhood the unsharp mask reads rather than single pixels.
    let magnitude = perceptualLuminance(edges, blurRadius: radius)
    let lower = strength * 0.55
    let upper = lower + max(0.06, 0.3 * (1 - strength))
    return smoothStep(magnitude, from: lower, to: upper, inverted: false)
  }

  // MARK: - Tone curve

  /// The parametric, point and per-channel curves of the layer, composed into
  /// one lookup table.
  ///
  /// Display P3 transfer encoding: a tone curve is drawn against perceptual
  /// values — the diagonal in the editor is the identity in that encoding, not
  /// in linear light — so the whole recipe is sampled over the encoded 0…1
  /// domain and `applyLookupTable` performs the conversion explicitly.
  static func applyToneCurve(_ curve: ToneCurveRecipe, to image: CIImage) -> CIImage {
    guard !curve.isNeutral else { return image }
    return applyLookupTable(curve.lookupTable(), to: image)
  }

  // MARK: - Basic tone

  /// Order: exposure, texture, clarity, dehaze, highlights, shadows, the tone
  /// LUT (blacks, whites, contrast), vibrance, saturation.
  static func applyBasicTone(_ tone: BasicToneRecipe, to image: CIImage) -> CIImage {
    guard !tone.isNeutral else { return image }
    let extent = image.extent
    let longEdge = Double(max(extent.width, extent.height))
    var output = image

    // Linear: a post-RAW exposure in stops. RAW layers bind their exposure
    // control to CIRAWFilter instead and keep this at zero.
    if tone.exposure != 0 {
      output = output.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: tone.exposure])
    }

    // Linear: texture is mid-frequency local contrast, clarity is the same
    // operation at a much larger radius. Both are unsharp masks when positive
    // and a blend toward the low-pass image when negative.
    if tone.texture != 0 {
      output = localContrast(
        output, radius: max(0.6, longEdge * 0.0008), amount: tone.texture / 100 * 0.8)
    }
    if tone.clarity != 0 {
      output = localContrast(
        output, radius: max(2, longEdge * 0.03), amount: tone.clarity / 100 * 0.5)
    }

    // Linear, documented approximation: the veil is a very low-pass copy of the
    // image, standing in for the ambient light of a dark-channel dehaze.
    // Positive dehaze subtracts a fraction of the veil and renormalizes;
    // negative dehaze blends toward a lightened veil.
    if tone.dehaze != 0 {
      output = dehaze(output, amount: tone.dehaze / 100 * 0.5, longEdge: longEdge)
    }

    // Linear: highlights and shadows are exposure shifts of up to one stop,
    // limited by a smooth luminance mask. The mask is computed from perceptual
    // luminance blurred over about 2% of the long edge so it follows regions
    // rather than pixels.
    if tone.highlights != 0 || tone.shadows != 0 {
      let luminance = perceptualLuminance(output, blurRadius: max(1, longEdge * 0.02))
      if tone.highlights != 0 {
        let mask = smoothStep(luminance, from: 0.35, to: 0.85, inverted: false)
        output = maskedExposure(output, stops: tone.highlights / 100, mask: mask)
      }
      if tone.shadows != 0 {
        let mask = smoothStep(luminance, from: 0.15, to: 0.65, inverted: true)
        output = maskedExposure(output, stops: tone.shadows / 100, mask: mask)
      }
    }

    // Display P3 transfer encoding: blacks and whites are endpoint remaps,
    // contrast is a fixed-endpoint S curve around middle gray.
    if tone.blacks != 0 || tone.whites != 0 || tone.contrast != 0 {
      let table = ToneLookupTable.basicTone(
        blacks: tone.blacks, whites: tone.whites, contrast: tone.contrast)
      output = applyLookupTable(table, to: output)
    }

    // Linear: vibrance and saturation.
    if tone.vibrance != 0 {
      output = output.applyingFilter(
        "CIVibrance", parameters: [kCIInputAmountKey: clamp(tone.vibrance / 100, -1, 1)])
    }
    if tone.saturation != 0 {
      output = output.applyingFilter(
        "CIColorControls",
        parameters: [kCIInputSaturationKey: clamp(1 + tone.saturation / 100, 0, 2)])
    }
    return output.cropped(to: extent)
  }

  // MARK: - Lookup tables

  /// Applies a 1D RGB lookup table in the Display P3 transfer encoding and
  /// returns to the linear working space.
  ///
  /// `CIColorCurves` would otherwise convert its input into its own
  /// `inputColorSpace`, which defaults to sRGB. That would be a second,
  /// implicit encoding change on top of the explicit `CILinearToSRGBToneCurve`
  /// above, so the parameter is pinned to the working space and the filter
  /// converts nothing.
  static func applyLookupTable(_ table: [Float], to image: CIImage) -> CIImage {
    guard table.count >= 6, table.count.isMultiple(of: 3) else { return image }
    let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
    var parameters: [String: Any] = [
      "inputCurvesData": data,
      "inputCurvesDomain": CIVector(x: 0, y: 1),
    ]
    if let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
      parameters["inputColorSpace"] = workingSpace
    }
    return
      image
      .applyingFilter("CILinearToSRGBToneCurve")
      .applyingFilter("CIColorCurves", parameters: parameters)
      .applyingFilter("CISRGBToneCurveToLinear")
  }

  // MARK: - Local operations

  /// Unsharp mask for a positive amount, a blend toward the low-pass image for
  /// a negative one. Radius in pixels of `image`.
  private static func localContrast(_ image: CIImage, radius: Double, amount: Double) -> CIImage {
    let extent = image.extent
    if amount > 0 {
      return image.clampedToExtent()
        .applyingFilter(
          "CIUnsharpMask",
          parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: min(amount, 1)]
        )
        .cropped(to: extent)
    }
    let softened = lowPass(image, radius: radius)
    return mix(image, toward: softened, amount: min(-amount, 1))
  }

  private static func dehaze(_ image: CIImage, amount: Double, longEdge: Double) -> CIImage {
    let extent = image.extent
    let veil = lowPass(image, radius: max(4, longEdge * 0.1))
    if amount > 0 {
      let subtracted = veil.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: -amount, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: -amount, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: -amount, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
      )
      let gain = 1 / (1 - amount)
      return
        subtracted
        .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
        .applyingFilter(
          "CIColorMatrix",
          parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
          ]
        )
        .applyingFilter(
          "CIColorClamp",
          parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 65504, y: 65504, z: 65504, w: 1),
          ]
        )
        .cropped(to: extent)
    }
    let haze = veil.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0),
        "inputBiasVector": CIVector(x: 0.4, y: 0.4, z: 0.4, w: 0),
      ]
    )
    return mix(image, toward: haze, amount: min(-amount, 1))
  }

  /// A Gaussian low-pass of `image` with the edges clamped so borders do not
  /// darken. Large radii run on a reduced copy: the result is a blur either
  /// way, and this keeps a 3% or 10% of-the-long-edge radius affordable at
  /// full resolution.
  static func lowPass(_ image: CIImage, radius: Double) -> CIImage {
    let extent = image.extent
    let maximumDirectRadius = 12.0
    guard radius > maximumDirectRadius else {
      return image.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: extent)
    }
    let scale = maximumDirectRadius / radius
    let padded = image.clampedToExtent().cropped(to: extent.insetBy(dx: -radius, dy: -radius))
    return
      padded
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: maximumDirectRadius])
      .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
      .cropped(to: extent)
  }

  /// Linear interpolation from `image` toward `target` by `amount` in 0…1.
  static func mix(_ image: CIImage, toward target: CIImage, amount: Double) -> CIImage {
    target
      .applyingFilter(
        "CIMix",
        parameters: [kCIInputBackgroundImageKey: image, kCIInputAmountKey: clamp(amount, 0, 1)]
      )
      .cropped(to: image.extent)
  }

  /// A gray image of perceptual luminance: linear Display P3 luminance run
  /// through the sRGB transfer curve, then blurred.
  static func perceptualLuminance(_ image: CIImage, blurRadius: Double) -> CIImage {
    // Display P3 luminance weights.
    let weights = CIVector(x: 0.2290, y: 0.6917, z: 0.0793, w: 0)
    let luminance = image.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": weights,
        "inputGVector": weights,
        "inputBVector": weights,
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ]
    )
    .applyingFilter("CILinearToSRGBToneCurve")
    return lowPass(luminance, radius: blurRadius)
  }

  /// Hermite smoothstep of a gray image between two thresholds, optionally
  /// inverted so that 1 is below `from` and 0 above `to`.
  static func smoothStep(
    _ gray: CIImage, from lower: Double, to upper: Double, inverted: Bool
  ) -> CIImage {
    let scale = 1 / max(upper - lower, 0.0001)
    let bias = -lower * scale
    var stepped =
      gray
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
          "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]
      )
      .applyingFilter(
        "CIColorClamp",
        parameters: [
          "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
      )
      .applyingFilter(
        "CIColorPolynomial",
        parameters: [
          "inputRedCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
          "inputGreenCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
          "inputBlueCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
        ]
      )
    if inverted {
      stepped = stepped.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
          "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ]
      )
    }
    return stepped
  }

  /// Shifts exposure by `stops` where `mask` is white and leaves the image
  /// where it is black.
  private static func maskedExposure(_ image: CIImage, stops: Double, mask: CIImage) -> CIImage {
    let shifted = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: stops])
    return blend(shifted, over: image, mask: mask)
  }

  /// `image` where `mask` is white, `background` where it is black.
  static func blend(_ image: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
    image
      .applyingFilter(
        "CIBlendWithMask",
        parameters: [
          kCIInputBackgroundImageKey: background,
          kCIInputMaskImageKey: mask,
        ]
      )
      .cropped(to: background.extent)
  }

  static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
  }
}

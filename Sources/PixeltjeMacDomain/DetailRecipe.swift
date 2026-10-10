import Foundation

/// The post-RAW detail controls of one layer: sharpening with masking, and
/// luminance and color noise reduction.
///
/// These are explicit user edits layered on top of whatever the decoder already
/// did. On a developed RAW layer, Apple's own sharpness, detail, moiré,
/// despeckle and noise-reduction properties live in `RawParameters` and are
/// shown separately and capability-driven; nothing here is a stand-in for a
/// `CIRAWFilter` property that the installed RAW system supports.
///
/// Units: `sharpenRadius` is in canvas pixels, everything else is a 0…100
/// amount. Neutral is a pixel no-op — the render graph adds no filter for it.
public struct DetailRecipe: Codable, Equatable, Sendable {
  /// The default sharpening radius, in canvas pixels.
  public static let defaultSharpenRadius = 1.0

  /// Sharpening strength. Zero applies no sharpening at all.
  public var sharpenAmount: Double
  /// The radius of the unsharp mask, in canvas pixels. Scaled to the rendered
  /// image so a proxy and a full render agree.
  public var sharpenRadius: Double
  /// A finer second sharpening pass that brings out small texture.
  public var sharpenDetail: Double
  /// Limits sharpening to edges. Zero sharpens everywhere; higher values keep
  /// flat areas — skies, skin, shadow noise — untouched.
  public var sharpenMasking: Double
  /// Luminance noise reduction strength.
  public var luminanceNoise: Double
  /// Color noise reduction strength.
  public var colorNoise: Double

  public init(
    sharpenAmount: Double = 0,
    sharpenRadius: Double = DetailRecipe.defaultSharpenRadius,
    sharpenDetail: Double = 0,
    sharpenMasking: Double = 0,
    luminanceNoise: Double = 0,
    colorNoise: Double = 0
  ) {
    self.sharpenAmount = sharpenAmount
    self.sharpenRadius = sharpenRadius
    self.sharpenDetail = sharpenDetail
    self.sharpenMasking = sharpenMasking
    self.luminanceNoise = luminanceNoise
    self.colorNoise = colorNoise
  }

  public static let neutral = DetailRecipe()

  /// Whether this recipe changes any pixel.
  ///
  /// Radius, detail and masking only shape a sharpening pass; with the amount
  /// at zero there is no pass to shape, so a recipe that only moved them is
  /// still a no-op.
  public var isNeutral: Bool {
    sharpenAmount == 0 && luminanceNoise == 0 && colorNoise == 0
  }

  /// Whether sharpening runs at all.
  public var sharpens: Bool { sharpenAmount > 0 }

  /// The controls of the detail panel, in panel order.
  public enum Control: String, CaseIterable, Codable, Sendable {
    case sharpenAmount
    case sharpenRadius
    case sharpenDetail
    case sharpenMasking
    case luminanceNoise
    case colorNoise

    /// The value the control resets to.
    public var defaultValue: Double {
      switch self {
      case .sharpenRadius: DetailRecipe.defaultSharpenRadius
      default: 0
      }
    }
  }

  public subscript(control: Control) -> Double {
    get {
      switch control {
      case .sharpenAmount: sharpenAmount
      case .sharpenRadius: sharpenRadius
      case .sharpenDetail: sharpenDetail
      case .sharpenMasking: sharpenMasking
      case .luminanceNoise: luminanceNoise
      case .colorNoise: colorNoise
      }
    }
    set {
      switch control {
      case .sharpenAmount: sharpenAmount = newValue
      case .sharpenRadius: sharpenRadius = newValue
      case .sharpenDetail: sharpenDetail = newValue
      case .sharpenMasking: sharpenMasking = newValue
      case .luminanceNoise: luminanceNoise = newValue
      case .colorNoise: colorNoise = newValue
      }
    }
  }

  /// Missing keys decode as the control's default, so a project written before
  /// a control existed loads neutral rather than failing.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Control.self)
    self.init()
    for control in Control.allCases {
      self[control] =
        try container.decodeIfPresent(Double.self, forKey: control) ?? control.defaultValue
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Control.self)
    for control in Control.allCases {
      try container.encode(self[control], forKey: control)
    }
  }
}

extension DetailRecipe.Control: CodingKey {
  public var stringValue: String { rawValue }
  public var intValue: Int? { nil }
  public init?(stringValue: String) { self.init(rawValue: stringValue) }
  public init?(intValue: Int) { nil }
}

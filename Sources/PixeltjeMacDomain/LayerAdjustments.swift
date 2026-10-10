import Foundation

/// The basic tone controls of one layer.
///
/// Every value is an explicit user edit with a neutral default of zero, and a
/// neutral recipe is a pixel no-op: the renderer adds no filter for it. On a
/// RAW layer the exposure control binds to Apple's `CIRAWFilter` exposure
/// instead of this recipe, so `exposure` stays zero there; on every other layer
/// it is a post-RAW exposure in stops.
///
/// Units: `exposure` is in stops; every other control is a Lightroom-style
/// -100…100 amount. Where each control is applied, and in which encoding, is
/// documented on the render graph that consumes it.
public struct BasicToneRecipe: Codable, Equatable, Sendable {
  public var exposure: Double
  public var contrast: Double
  public var highlights: Double
  public var shadows: Double
  public var whites: Double
  public var blacks: Double
  public var texture: Double
  public var clarity: Double
  public var dehaze: Double
  public var vibrance: Double
  public var saturation: Double

  public init(
    exposure: Double = 0,
    contrast: Double = 0,
    highlights: Double = 0,
    shadows: Double = 0,
    whites: Double = 0,
    blacks: Double = 0,
    texture: Double = 0,
    clarity: Double = 0,
    dehaze: Double = 0,
    vibrance: Double = 0,
    saturation: Double = 0
  ) {
    self.exposure = exposure
    self.contrast = contrast
    self.highlights = highlights
    self.shadows = shadows
    self.whites = whites
    self.blacks = blacks
    self.texture = texture
    self.clarity = clarity
    self.dehaze = dehaze
    self.vibrance = vibrance
    self.saturation = saturation
  }

  public static let neutral = BasicToneRecipe()

  public var isNeutral: Bool { self == .neutral }

  /// The controls of the basic tone panel, in panel order.
  public enum Control: String, CaseIterable, Codable, Sendable {
    case exposure
    case contrast
    case highlights
    case shadows
    case whites
    case blacks
    case texture
    case clarity
    case dehaze
    case vibrance
    case saturation
  }

  public subscript(control: Control) -> Double {
    get {
      switch control {
      case .exposure: exposure
      case .contrast: contrast
      case .highlights: highlights
      case .shadows: shadows
      case .whites: whites
      case .blacks: blacks
      case .texture: texture
      case .clarity: clarity
      case .dehaze: dehaze
      case .vibrance: vibrance
      case .saturation: saturation
      }
    }
    set {
      switch control {
      case .exposure: exposure = newValue
      case .contrast: contrast = newValue
      case .highlights: highlights = newValue
      case .shadows: shadows = newValue
      case .whites: whites = newValue
      case .blacks: blacks = newValue
      case .texture: texture = newValue
      case .clarity: clarity = newValue
      case .dehaze: dehaze = newValue
      case .vibrance: vibrance = newValue
      case .saturation: saturation = newValue
      }
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Control.self)
    self.init()
    for control in Control.allCases {
      self[control] = try container.decodeIfPresent(Double.self, forKey: control) ?? 0
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Control.self)
    for control in Control.allCases {
      try container.encode(self[control], forKey: control)
    }
  }
}

extension BasicToneRecipe.Control: CodingKey {
  public var stringValue: String { rawValue }
  public var intValue: Int? { nil }
  public init?(stringValue: String) { self.init(rawValue: stringValue) }
  public init?(intValue: Int) { nil }
}

/// The post-RAW adjustments of one layer.
///
/// Adjustments belong to the layer they act on. A RAW layer's Apple RAW values
/// live in the project's `RawDevelopmentRecipe`; everything here is applied
/// after RAW development, or to a placed image, as an explicit edit. The
/// neutral recipe is the layer's default and renders nothing.
///
/// Missing keys decode as neutral, so a project written before a control
/// existed loads with that control at its default.
public struct LayerAdjustments: Codable, Equatable, Sendable {
  public var basicTone: BasicToneRecipe
  public var toneCurve: ToneCurveRecipe
  public var detail: DetailRecipe
  public var colorMixer: ColorMixerRecipe
  public var colorGrading: ColorGradingRecipe

  public init(
    basicTone: BasicToneRecipe = .neutral,
    toneCurve: ToneCurveRecipe = .neutral,
    detail: DetailRecipe = .neutral,
    colorMixer: ColorMixerRecipe = .neutral,
    colorGrading: ColorGradingRecipe = .neutral
  ) {
    self.basicTone = basicTone
    self.toneCurve = toneCurve
    self.detail = detail
    self.colorMixer = colorMixer
    self.colorGrading = colorGrading
  }

  public static let neutral = LayerAdjustments()

  public var isNeutral: Bool {
    basicTone.isNeutral && toneCurve.isNeutral && detail.isNeutral
      && colorMixer.isNeutral && colorGrading.isNeutral
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    basicTone =
      try container.decodeIfPresent(BasicToneRecipe.self, forKey: .basicTone) ?? .neutral
    toneCurve =
      try container.decodeIfPresent(ToneCurveRecipe.self, forKey: .toneCurve) ?? .neutral
    detail =
      try container.decodeIfPresent(DetailRecipe.self, forKey: .detail) ?? .neutral
    colorMixer =
      try container.decodeIfPresent(ColorMixerRecipe.self, forKey: .colorMixer) ?? .neutral
    colorGrading =
      try container.decodeIfPresent(ColorGradingRecipe.self, forKey: .colorGrading) ?? .neutral
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(basicTone, forKey: .basicTone)
    try container.encode(toneCurve, forKey: .toneCurve)
    try container.encode(detail, forKey: .detail)
    // Keep old and neutral projects compact. Missing keys are the documented
    // neutral migration path, so there is no value in serializing eight empty
    // mixer bands and three empty wheels onto every layer.
    if !colorMixer.isNeutral { try container.encode(colorMixer, forKey: .colorMixer) }
    if !colorGrading.isNeutral { try container.encode(colorGrading, forKey: .colorGrading) }
  }

  private enum CodingKeys: String, CodingKey {
    case basicTone
    case toneCurve
    case detail
    case colorMixer
    case colorGrading
  }
}

import Foundation

/// The eight perceptual hue bands shown by the Color Mixer.
public enum ColorMixerChannel: String, Codable, CaseIterable, Sendable {
  case red, orange, yellow, green, aqua, blue, purple, magenta

  public var label: String { rawValue.capitalized }

  /// Centre of the band in degrees, with red at zero.
  public var centerDegrees: Double {
    switch self {
    case .red: 0
    case .orange: 30
    case .yellow: 60
    case .green: 120
    case .aqua: 180
    case .blue: 240
    case .purple: 275
    case .magenta: 315
    }
  }
}

/// Hue, saturation, and luminance changes for one mixer band.
///
/// Values use the panel's -100…100 scale. The renderer clamps only while
/// evaluating so malformed files remain finite without rewriting their recipe.
public struct ColorMixerChannelAdjustment: Codable, Equatable, Sendable {
  public var hue: Double
  public var saturation: Double
  public var luminance: Double

  public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
    self.hue = hue
    self.saturation = saturation
    self.luminance = luminance
  }

  public static let neutral = ColorMixerChannelAdjustment()
  public var isNeutral: Bool { self == .neutral }
}

/// Selective HSL edits attached to one pixel layer.
///
/// The array is always normalized to the eight channels in `allCases` order.
/// An array makes the JSON stable and lets future builds append a band without
/// changing the meaning of existing keys.
public struct ColorMixerRecipe: Codable, Equatable, Sendable {
  private var bands: [ColorMixerChannelAdjustment]

  public init() {
    bands = Array(repeating: .neutral, count: ColorMixerChannel.allCases.count)
  }

  public static let neutral = ColorMixerRecipe()
  public var isNeutral: Bool { bands.allSatisfy(\.isNeutral) }

  public subscript(channel: ColorMixerChannel) -> ColorMixerChannelAdjustment {
    get { bands[Self.index(of: channel)] }
    set { bands[Self.index(of: channel)] = newValue }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decoded =
      try container.decodeIfPresent([ColorMixerChannelAdjustment].self, forKey: .bands) ?? []
    bands = Array(decoded.prefix(ColorMixerChannel.allCases.count))
    if bands.count < ColorMixerChannel.allCases.count {
      bands.append(
        contentsOf: repeatElement(
          .neutral, count: ColorMixerChannel.allCases.count - bands.count))
    }
  }

  private static func index(of channel: ColorMixerChannel) -> Int {
    ColorMixerChannel.allCases.firstIndex(of: channel) ?? 0
  }

  private enum CodingKeys: String, CodingKey { case bands }
}

/// One wheel of the three-way color grader.
///
/// Hue is in degrees, saturation and luminance use 0…100 and -100…100. The
/// renderer turns hue/saturation into an RGB slope and luminance into an
/// offset: the slope/offset legs of ASC CDL with power fixed at 1.
public struct ColorGradingWheel: Codable, Equatable, Sendable {
  public var hue: Double
  public var saturation: Double
  public var luminance: Double

  public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
    self.hue = hue
    self.saturation = saturation
    self.luminance = luminance
  }

  public static let neutral = ColorGradingWheel()
  public var isNeutral: Bool { saturation == 0 && luminance == 0 }
}

/// Three luminance-weighted ASC-CDL grades in the linear Display P3 graph.
public struct ColorGradingRecipe: Codable, Equatable, Sendable {
  public var shadows: ColorGradingWheel
  public var midtones: ColorGradingWheel
  public var highlights: ColorGradingWheel
  /// Width of the overlap between tonal ranges, 0…100.
  public var blending: Double
  /// Moves the shadow/highlight split together, -100…100.
  public var balance: Double

  public init(
    shadows: ColorGradingWheel = .neutral,
    midtones: ColorGradingWheel = .neutral,
    highlights: ColorGradingWheel = .neutral,
    blending: Double = 50,
    balance: Double = 0
  ) {
    self.shadows = shadows
    self.midtones = midtones
    self.highlights = highlights
    self.blending = blending
    self.balance = balance
  }

  public static let neutral = ColorGradingRecipe()
  public var isNeutral: Bool {
    shadows.isNeutral && midtones.isNeutral && highlights.isNeutral
  }

  public enum Range: String, Codable, CaseIterable, Sendable {
    case shadows, midtones, highlights
    public var label: String { rawValue.capitalized }
  }

  public subscript(range: Range) -> ColorGradingWheel {
    get {
      switch range {
      case .shadows: shadows
      case .midtones: midtones
      case .highlights: highlights
      }
    }
    set {
      switch range {
      case .shadows: shadows = newValue
      case .midtones: midtones = newValue
      case .highlights: highlights = newValue
      }
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    shadows = try container.decodeIfPresent(ColorGradingWheel.self, forKey: .shadows) ?? .neutral
    midtones = try container.decodeIfPresent(ColorGradingWheel.self, forKey: .midtones) ?? .neutral
    highlights =
      try container.decodeIfPresent(ColorGradingWheel.self, forKey: .highlights) ?? .neutral
    blending = try container.decodeIfPresent(Double.self, forKey: .blending) ?? 50
    balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0
  }

  private enum CodingKeys: String, CodingKey {
    case shadows, midtones, highlights, blending, balance
  }
}

public struct LevelsAdjustment: Codable, Equatable, Sendable {
  public var blackPoint: Double
  public var whitePoint: Double
  public var gamma: Double

  public init(blackPoint: Double = 0, whitePoint: Double = 1, gamma: Double = 1) {
    self.blackPoint = blackPoint
    self.whitePoint = whitePoint
    self.gamma = gamma
  }

  public static let neutral = LevelsAdjustment()
  public var isNeutral: Bool { self == .neutral }
}

public struct HueSaturationAdjustment: Codable, Equatable, Sendable {
  public var hue: Double
  public var saturation: Double
  public var lightness: Double

  public init(hue: Double = 0, saturation: Double = 0, lightness: Double = 0) {
    self.hue = hue
    self.saturation = saturation
    self.lightness = lightness
  }

  public static let neutral = HueSaturationAdjustment()
  public var isNeutral: Bool { self == .neutral }
}

public struct BlackAndWhiteAdjustment: Codable, Equatable, Sendable {
  public var redWeight: Double
  public var greenWeight: Double
  public var blueWeight: Double
  public var amount: Double

  public init(
    redWeight: Double = 0.229,
    greenWeight: Double = 0.6917,
    blueWeight: Double = 0.0793,
    amount: Double = 0
  ) {
    self.redWeight = redWeight
    self.greenWeight = greenWeight
    self.blueWeight = blueWeight
    self.amount = amount
  }

  public static let neutral = BlackAndWhiteAdjustment()
  public var isNeutral: Bool { amount == 0 }
}

public enum ColorLookupStyle: String, Codable, CaseIterable, Sendable {
  case cinematic, warm, cool, faded
  public var label: String { rawValue.capitalized }
}

public struct ColorLookupAdjustment: Codable, Equatable, Sendable {
  public var style: ColorLookupStyle
  public var amount: Double

  public init(style: ColorLookupStyle = .cinematic, amount: Double = 0) {
    self.style = style
    self.amount = amount
  }

  public static let neutral = ColorLookupAdjustment()
  public var isNeutral: Bool { amount == 0 }
}

public enum GradientMapStyle: String, Codable, CaseIterable, Sendable {
  case blackAndWhite, sepia, blueOrange

  public var label: String {
    switch self {
    case .blackAndWhite: "Black & White"
    case .sepia: "Sepia"
    case .blueOrange: "Blue & Orange"
    }
  }
}

public struct GradientMapAdjustment: Codable, Equatable, Sendable {
  public var style: GradientMapStyle
  public var amount: Double
  public var reversed: Bool

  public init(style: GradientMapStyle = .blackAndWhite, amount: Double = 0, reversed: Bool = false)
  {
    self.style = style
    self.amount = amount
    self.reversed = reversed
  }

  public static let neutral = GradientMapAdjustment()
  public var isNeutral: Bool { amount == 0 }
}

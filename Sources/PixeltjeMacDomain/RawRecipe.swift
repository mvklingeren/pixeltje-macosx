import Foundation

/// The addressable float knobs of Apple's RAW decoder.
///
/// The raw values are a persistence contract: a saved `RawPreset` stores the
/// parameters it names by these strings, so renaming a case orphans presets
/// people have saved.
public enum RawFloatParameter: String, CaseIterable, Codable, Sendable {
  case exposure
  case baselineExposure
  case shadowBias
  case boostAmount
  case boostShadowAmount
  case luminanceNoiseReduction
  case colorNoiseReduction
  case sharpness
  case contrast
  case detail
  case moireReduction
  case despeckle
  case localToneMap
  case extendedDynamicRange
  case neutralTemperature
  case neutralTint
}

/// The addressable switches of Apple's RAW decoder. Their raw values are a
/// persistence contract for the same reason `RawFloatParameter`'s are.
public enum RawBoolParameter: String, CaseIterable, Codable, Sendable {
  case highlightRecovery
  case gamutMapping
  case lensCorrection
}

public struct RawParameters: Codable, Equatable, Sendable {
  public var exposure: Double
  public var baselineExposure: Double
  public var shadowBias: Double
  public var boostAmount: Double
  public var boostShadowAmount: Double
  public var luminanceNoiseReduction: Double
  public var colorNoiseReduction: Double
  public var sharpness: Double
  public var contrast: Double
  public var detail: Double
  public var moireReduction: Double
  public var despeckle: Double
  public var localToneMap: Double
  public var extendedDynamicRange: Double
  public var neutralTemperature: Double
  public var neutralTint: Double
  public var highlightRecovery: Bool
  public var gamutMapping: Bool
  public var lensCorrection: Bool

  public init(
    exposure: Double = 0,
    baselineExposure: Double = 0,
    shadowBias: Double = 0,
    boostAmount: Double = 1,
    boostShadowAmount: Double = 1,
    luminanceNoiseReduction: Double = 0,
    colorNoiseReduction: Double = 0,
    sharpness: Double = 0,
    contrast: Double = 0,
    detail: Double = 0,
    moireReduction: Double = 0,
    despeckle: Double = 0,
    localToneMap: Double = 0,
    extendedDynamicRange: Double = 0,
    neutralTemperature: Double = 6500,
    neutralTint: Double = 0,
    highlightRecovery: Bool = true,
    gamutMapping: Bool = true,
    lensCorrection: Bool = true
  ) {
    self.exposure = exposure
    self.baselineExposure = baselineExposure
    self.shadowBias = shadowBias
    self.boostAmount = boostAmount
    self.boostShadowAmount = boostShadowAmount
    self.luminanceNoiseReduction = luminanceNoiseReduction
    self.colorNoiseReduction = colorNoiseReduction
    self.sharpness = sharpness
    self.contrast = contrast
    self.detail = detail
    self.moireReduction = moireReduction
    self.despeckle = despeckle
    self.localToneMap = localToneMap
    self.extendedDynamicRange = extendedDynamicRange
    self.neutralTemperature = neutralTemperature
    self.neutralTint = neutralTint
    self.highlightRecovery = highlightRecovery
    self.gamutMapping = gamutMapping
    self.lensCorrection = lensCorrection
  }

  public subscript(parameter: RawFloatParameter) -> Double {
    get {
      switch parameter {
      case .exposure: exposure
      case .baselineExposure: baselineExposure
      case .shadowBias: shadowBias
      case .boostAmount: boostAmount
      case .boostShadowAmount: boostShadowAmount
      case .luminanceNoiseReduction: luminanceNoiseReduction
      case .colorNoiseReduction: colorNoiseReduction
      case .sharpness: sharpness
      case .contrast: contrast
      case .detail: detail
      case .moireReduction: moireReduction
      case .despeckle: despeckle
      case .localToneMap: localToneMap
      case .extendedDynamicRange: extendedDynamicRange
      case .neutralTemperature: neutralTemperature
      case .neutralTint: neutralTint
      }
    }
    set {
      switch parameter {
      case .exposure: exposure = newValue
      case .baselineExposure: baselineExposure = newValue
      case .shadowBias: shadowBias = newValue
      case .boostAmount: boostAmount = newValue
      case .boostShadowAmount: boostShadowAmount = newValue
      case .luminanceNoiseReduction: luminanceNoiseReduction = newValue
      case .colorNoiseReduction: colorNoiseReduction = newValue
      case .sharpness: sharpness = newValue
      case .contrast: contrast = newValue
      case .detail: detail = newValue
      case .moireReduction: moireReduction = newValue
      case .despeckle: despeckle = newValue
      case .localToneMap: localToneMap = newValue
      case .extendedDynamicRange: extendedDynamicRange = newValue
      case .neutralTemperature: neutralTemperature = newValue
      case .neutralTint: neutralTint = newValue
      }
    }
  }

  public subscript(parameter: RawBoolParameter) -> Bool {
    get {
      switch parameter {
      case .highlightRecovery: highlightRecovery
      case .gamutMapping: gamutMapping
      case .lensCorrection: lensCorrection
      }
    }
    set {
      switch parameter {
      case .highlightRecovery: highlightRecovery = newValue
      case .gamutMapping: gamutMapping = newValue
      case .lensCorrection: lensCorrection = newValue
      }
    }
  }
}

extension RawFloatParameter {
  /// The inspector's own wording for this parameter, so a preset summary and a
  /// slider never disagree about what a setting is called.
  public var label: String {
    switch self {
    case .exposure: "Exposure"
    case .baselineExposure: "Baseline exposure"
    case .shadowBias: "Shadow bias"
    case .boostAmount: "Tone boost"
    case .boostShadowAmount: "Shadow boost"
    case .luminanceNoiseReduction: "Luminance noise"
    case .colorNoiseReduction: "Color noise"
    case .sharpness: "Sharpness"
    case .contrast: "Local contrast"
    case .detail: "Detail"
    case .moireReduction: "Moiré"
    case .despeckle: "Despeckle"
    case .localToneMap: "Local tone map"
    case .extendedDynamicRange: "EDR"
    case .neutralTemperature: "White balance"
    case .neutralTint: "Tint"
    }
  }
}

extension RawBoolParameter {
  public var label: String {
    switch self {
    case .highlightRecovery: "Highlight recovery"
    case .gamutMapping: "Gamut mapping"
    case .lensCorrection: "Lens correction"
    }
  }
}

public struct RawCapabilities: Codable, Equatable, Sendable {
  public var luminanceNoiseReduction: Bool
  public var colorNoiseReduction: Bool
  public var sharpness: Bool
  public var contrast: Bool
  public var detail: Bool
  public var moireReduction: Bool
  public var despeckle: Bool
  public var localToneMap: Bool
  public var highlightRecovery: Bool
  public var lensCorrection: Bool

  public init(
    luminanceNoiseReduction: Bool = false,
    colorNoiseReduction: Bool = false,
    sharpness: Bool = false,
    contrast: Bool = false,
    detail: Bool = false,
    moireReduction: Bool = false,
    despeckle: Bool = false,
    localToneMap: Bool = false,
    highlightRecovery: Bool = false,
    lensCorrection: Bool = false
  ) {
    self.luminanceNoiseReduction = luminanceNoiseReduction
    self.colorNoiseReduction = colorNoiseReduction
    self.sharpness = sharpness
    self.contrast = contrast
    self.detail = detail
    self.moireReduction = moireReduction
    self.despeckle = despeckle
    self.localToneMap = localToneMap
    self.highlightRecovery = highlightRecovery
    self.lensCorrection = lensCorrection
  }

  public func supports(_ parameter: RawFloatParameter) -> Bool {
    switch parameter {
    case .luminanceNoiseReduction: luminanceNoiseReduction
    case .colorNoiseReduction: colorNoiseReduction
    case .sharpness: sharpness
    case .contrast: contrast
    case .detail: detail
    case .moireReduction: moireReduction
    case .despeckle: despeckle
    case .localToneMap: localToneMap
    default: true
    }
  }

  public func supports(_ parameter: RawBoolParameter) -> Bool {
    switch parameter {
    case .highlightRecovery: highlightRecovery
    case .lensCorrection: lensCorrection
    case .gamutMapping: true
    }
  }
}

public struct RawDevelopmentRecipe: Codable, Equatable, Sendable {
  public var decoderVersion: String?
  public var supportedDecoderVersions: [String]
  public var parameters: RawParameters?
  public var capturedDefaults: RawParameters?
  public var capabilities: RawCapabilities?

  public init(
    decoderVersion: String? = nil,
    supportedDecoderVersions: [String] = [],
    parameters: RawParameters? = nil,
    capturedDefaults: RawParameters? = nil,
    capabilities: RawCapabilities? = nil
  ) {
    self.decoderVersion = decoderVersion
    self.supportedDecoderVersions = supportedDecoderVersions
    self.parameters = parameters
    self.capturedDefaults = capturedDefaults
    self.capabilities = capabilities
  }
}

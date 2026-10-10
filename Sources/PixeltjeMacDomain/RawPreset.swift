import Foundation

/// A named set of RAW develop settings, carrying only the parameters it names.
///
/// Sparseness is the whole point. A preset that stored a complete
/// `RawParameters` would carry a white balance and an exposure with it, so
/// applying a look would silently discard the as-shot neutral of every file it
/// touched. What a preset does not name, it does not change.
public struct RawPreset: Equatable, Sendable, Identifiable, Codable {
  public var id: UUID
  public var name: String
  public var floats: [RawFloatParameter: Double]
  public var bools: [RawBoolParameter: Bool]
  /// Built-ins ship compiled into the application, are the same on every
  /// machine, and are never edited in place.
  public var isBuiltIn: Bool

  public init(
    id: UUID = UUID(),
    name: String,
    floats: [RawFloatParameter: Double] = [:],
    bools: [RawBoolParameter: Bool] = [:],
    isBuiltIn: Bool = false
  ) {
    self.id = id
    self.name = name
    self.floats = floats
    self.bools = bools
    self.isBuiltIn = isBuiltIn
  }

  /// The float parameters this preset writes for this camera, in slider order.
  ///
  /// A parameter the installed RAW support does not offer for this file is
  /// skipped rather than written, matching how the inspector hides a control it
  /// cannot honour. Absent capabilities mean "not yet inspected" and support
  /// everything, the same `!= false` reading the inspector uses.
  ///
  /// The walk is over `allCases` rather than the dictionary so the order is
  /// stable between runs: the merge does not care, but `summary` does.
  public func effectiveFloats(_ capabilities: RawCapabilities?) -> [(RawFloatParameter, Double)] {
    RawFloatParameter.allCases.compactMap { parameter in
      guard let value = floats[parameter],
        capabilities?.supports(parameter) != false
      else { return nil }
      return (parameter, value)
    }
  }

  public func effectiveBools(_ capabilities: RawCapabilities?) -> [(RawBoolParameter, Bool)] {
    RawBoolParameter.allCases.compactMap { parameter in
      guard let value = bools[parameter],
        capabilities?.supports(parameter) != false
      else { return nil }
      return (parameter, value)
    }
  }

  /// The parameters this preset produces from `parameters`.
  public func applied(
    to parameters: RawParameters,
    capabilities: RawCapabilities?
  ) -> RawParameters {
    var result = parameters
    for (parameter, value) in effectiveFloats(capabilities) {
      result[parameter] = value
    }
    for (parameter, value) in effectiveBools(capabilities) {
      result[parameter] = value
    }
    return result
  }

  /// Whether `parameters` already holds everything this preset would write.
  ///
  /// This is what the check mark in the picker means: not "this preset is
  /// selected" — nothing stores a selection — but "these are the numbers this
  /// preset puts here". The comparison is exact, with no tolerance, because
  /// these are values this code wrote and never read back through the decoder.
  public func matches(_ parameters: RawParameters, capabilities: RawCapabilities?) -> Bool {
    let floats = effectiveFloats(capabilities)
    let bools = effectiveBools(capabilities)
    guard !floats.isEmpty || !bools.isEmpty else { return false }
    return floats.allSatisfy { parameters[$0.0] == $0.1 }
      && bools.allSatisfy { parameters[$0.0] == $0.1 }
  }

  /// A one-line description for the picker's tooltip.
  public var summary: String {
    let parts =
      effectiveFloats(nil).map {
        "\($0.0.label) \($0.1.formatted(.number.precision(.fractionLength(2))))"
      }
      + effectiveBools(nil).map { "\($0.0.label) \($0.1 ? "on" : "off")" }
    return parts.isEmpty ? "Changes nothing" : parts.joined(separator: " · ")
  }

  /// How many settings this preset writes for this camera.
  public func settingCount(_ capabilities: RawCapabilities?) -> Int {
    effectiveFloats(capabilities).count + effectiveBools(capabilities).count
  }

  /// A copy of this preset that the user owns.
  public func duplicated(named name: String) -> RawPreset {
    var copy = self
    copy.id = UUID()
    copy.name = name
    copy.isBuiltIn = false
    return copy
  }

  /// The parameters a saved preset leaves out unless it is asked for them.
  ///
  /// White balance and tint are as shot, and exposure is set per frame. A look
  /// preset that carried them would fight every file it was applied to, so they
  /// are opt-in rather than captured by default.
  public static let perFrameFloats: Set<RawFloatParameter> = [
    .exposure, .baselineExposure, .neutralTemperature, .neutralTint,
  ]

  /// A preset built from what the current settings changed.
  ///
  /// Everything that differs from the camera's own defaults is captured, which
  /// is exactly the sparse set a preset wants: the settings the photographer
  /// moved, and nothing else. Without captured defaults — a project opened
  /// before the file was inspected — a fresh `RawParameters` stands in.
  public static func capturing(
    _ parameters: RawParameters,
    against defaults: RawParameters?,
    named name: String,
    includingWhiteBalanceAndExposure: Bool
  ) -> RawPreset {
    let reference = defaults ?? RawParameters()
    var floats: [RawFloatParameter: Double] = [:]
    for parameter in RawFloatParameter.allCases {
      if !includingWhiteBalanceAndExposure, perFrameFloats.contains(parameter) { continue }
      guard parameters[parameter] != reference[parameter] else { continue }
      floats[parameter] = parameters[parameter]
    }
    var bools: [RawBoolParameter: Bool] = [:]
    for parameter in RawBoolParameter.allCases where parameters[parameter] != reference[parameter] {
      bools[parameter] = parameters[parameter]
    }
    return RawPreset(name: name, floats: floats, bools: bools)
  }

  // MARK: Codable
  //
  // Written by hand so an unrecognised parameter name is dropped rather than
  // thrown on: a preset saved by a later build must not make the whole stored
  // library unreadable. `CodingKeyRepresentable` on the parameter enums would
  // give the same wire shape but that failure mode, and would silently change
  // how every future dictionary keyed by one of them encodes.

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case floats
    case bools
    case isBuiltIn
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    let storedFloats = try container.decodeIfPresent([String: Double].self, forKey: .floats) ?? [:]
    floats = storedFloats.reduce(into: [:]) { result, entry in
      guard let parameter = RawFloatParameter(rawValue: entry.key) else { return }
      result[parameter] = entry.value
    }
    let storedBools = try container.decodeIfPresent([String: Bool].self, forKey: .bools) ?? [:]
    bools = storedBools.reduce(into: [:]) { result, entry in
      guard let parameter = RawBoolParameter(rawValue: entry.key) else { return }
      result[parameter] = entry.value
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(isBuiltIn, forKey: .isBuiltIn)
    try container.encode(
      Dictionary(uniqueKeysWithValues: floats.map { ($0.key.rawValue, $0.value) }),
      forKey: .floats
    )
    try container.encode(
      Dictionary(uniqueKeysWithValues: bools.map { ($0.key.rawValue, $0.value) }),
      forKey: .bools
    )
  }
}

/// The develop presets shipped with the application.
public enum RawPresetCatalog {
  private static func fixedID(_ string: String) -> UUID {
    UUID(uuidString: string) ?? UUID()
  }

  /// A punchier default look.
  ///
  /// Four tone settings and nothing else. What it deliberately leaves alone is
  /// as much a part of the preset as what it sets:
  ///
  /// - exposure and baseline exposure, because brightness is the photographer's
  ///   call per frame and a look that moved it would fight every file;
  /// - white balance and tint, because they are as shot;
  /// - sharpness, detail, moiré, despeckle and the noise reductions, because
  ///   detail rendering follows the sensor and the ISO rather than the look,
  ///   and the detail panel already owns post-RAW sharpening;
  /// - extended dynamic range, because it changes headroom rather than look and
  ///   reads flatter on an SDR display, the opposite of the intent;
  /// - shadow bias, highlight recovery, gamut mapping and lens correction,
  ///   because those are correctness switches, not taste.
  ///
  /// The identifiers are fixed, as `ExportPreset.builtIns` has them, so a user
  /// copy can never collide with a shipped preset.
  public static let boost = RawPreset(
    id: fixedID("7A0C51D2-0000-4000-A000-000000000001"),
    name: "Boost",
    floats: [
      // Apple's own tone boost, fully on. Usually already the file's default,
      // so usually a no-op — it is named so a file that decodes flat still gets
      // the curve the preset promises.
      .boostAmount: 1.0,
      // A modest lift above the neutral 1.0, so the added contrast below reads
      // as depth rather than blocked blacks.
      .boostShadowAmount: 1.20,
      // The main source of the punch, visible without halos.
      .contrast: 0.35,
      // Midtone separation without a global S-curve; highlight rolloff stays.
      .localToneMap: 0.25,
    ],
    isBuiltIn: true
  )

  public static let builtIns: [RawPreset] = [boost]

  public static func preset(id: UUID) -> RawPreset? {
    builtIns.first { $0.id == id }
  }
}

/// The develop presets available to every document.
///
/// Presets are not part of a project: the same look is wanted on the next file,
/// so the library lives in app settings and the project records only the
/// parameters a preset produced.
public struct RawPresetLibrary: Codable, Equatable, Sendable {
  public var userPresets: [RawPreset]

  public init(userPresets: [RawPreset] = []) {
    self.userPresets = userPresets
  }

  public var all: [RawPreset] { RawPresetCatalog.builtIns + userPresets }

  public func preset(id: UUID) -> RawPreset? {
    all.first { $0.id == id }
  }

  /// Adds a user preset, or replaces the one with the same identifier.
  ///
  /// A built-in is never overwritten: saving over one stores a user copy, so
  /// the shipped preset stays available.
  public mutating func save(_ preset: RawPreset) {
    var stored = preset
    stored.isBuiltIn = false
    if RawPresetCatalog.builtIns.contains(where: { $0.id == stored.id }) {
      stored.id = UUID()
    }
    if let index = userPresets.firstIndex(where: { $0.id == stored.id }) {
      userPresets[index] = stored
    } else {
      userPresets.append(stored)
    }
  }

  public mutating func remove(id: UUID) {
    userPresets.removeAll { $0.id == id }
  }
}

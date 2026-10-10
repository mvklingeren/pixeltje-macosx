import Foundation
import PixeltjeMacDomain
import Testing

private func rawProject(
  parameters: RawParameters?,
  defaults: RawParameters? = RawParameters(),
  capabilities: RawCapabilities? = nil
) -> ProjectRecipe {
  ProjectRecipe(
    rawDevelopment: RawDevelopmentRecipe(
      decoderVersion: "9",
      parameters: parameters,
      capturedDefaults: defaults,
      capabilities: capabilities
    )
  )
}

/// A camera that supports everything the boost preset names.
private let fullCapabilities = RawCapabilities(
  luminanceNoiseReduction: true,
  colorNoiseReduction: true,
  sharpness: true,
  contrast: true,
  detail: true,
  moireReduction: true,
  despeckle: true,
  localToneMap: true,
  highlightRecovery: true,
  lensCorrection: true
)

@Test func presetChangesOnlyTheParametersItNames() {
  var parameters = RawParameters()
  parameters.neutralTemperature = 5230
  parameters.neutralTint = -12
  parameters.exposure = 1.25
  parameters.sharpness = 0.4

  let project = rawProject(parameters: parameters, capabilities: fullCapabilities)
  let applied = project.applying(.applyRawPreset(RawPresetCatalog.boost))
    .rawDevelopment.parameters

  // Untouched: as shot, and what the photographer set.
  #expect(applied?.neutralTemperature == 5230)
  #expect(applied?.neutralTint == -12)
  #expect(applied?.exposure == 1.25)
  #expect(applied?.sharpness == 0.4)
  // Written: what the preset names.
  #expect(applied?.boostAmount == 1.0)
  #expect(applied?.boostShadowAmount == 1.20)
  #expect(applied?.contrast == 0.35)
  #expect(applied?.localToneMap == 0.25)
}

@Test func presetSkipsParametersThisCameraDoesNotSupport() {
  var capabilities = fullCapabilities
  capabilities.contrast = false
  capabilities.localToneMap = false

  let project = rawProject(parameters: RawParameters(), capabilities: capabilities)
  let applied = project.applying(.applyRawPreset(RawPresetCatalog.boost))
    .rawDevelopment.parameters

  #expect(applied?.contrast == 0)
  #expect(applied?.localToneMap == 0)
  #expect(applied?.boostShadowAmount == 1.20)
}

@Test func presetTreatsUninspectedCapabilitiesAsSupported() {
  let project = rawProject(parameters: RawParameters(), capabilities: nil)
  let applied = project.applying(.applyRawPreset(RawPresetCatalog.boost))
    .rawDevelopment.parameters

  #expect(applied?.contrast == 0.35)
  #expect(applied?.localToneMap == 0.25)
}

@Test func presetDoesNothingWithoutRawParameters() {
  let project = rawProject(parameters: nil, defaults: nil)

  #expect(project.applying(.applyRawPreset(RawPresetCatalog.boost)) == project)
}

@Test func resetAfterAPresetRestoresCapturedAppleDefaults() {
  var defaults = RawParameters()
  defaults.contrast = 0.6
  defaults.localToneMap = 0.1

  let project = rawProject(
    parameters: defaults,
    defaults: defaults,
    capabilities: fullCapabilities
  )
  let boosted = project.applying(.applyRawPreset(RawPresetCatalog.boost))

  #expect(boosted.rawDevelopment.parameters?.contrast == 0.35)
  #expect(boosted.applying(.resetRaw).rawDevelopment.parameters == defaults)
}

@Test func builtInPresetsHaveStableIdentifiersAndUniqueNames() {
  let builtIns = RawPresetCatalog.builtIns

  #expect(Set(builtIns.map(\.id)).count == builtIns.count)
  #expect(Set(builtIns.map(\.name)).count == builtIns.count)
  #expect(builtIns.filter(\.isBuiltIn).count == builtIns.count)
  #expect(
    RawPresetCatalog.boost.id == UUID(uuidString: "7A0C51D2-0000-4000-A000-000000000001")
  )
}

@Test func presetMatchesOnlyTheParametersItProduced() {
  let boost = RawPresetCatalog.boost
  let parameters = RawParameters()

  #expect(!boost.matches(parameters, capabilities: fullCapabilities))

  var applied = boost.applied(to: parameters, capabilities: fullCapabilities)
  #expect(boost.matches(applied, capabilities: fullCapabilities))

  // A parameter the preset says nothing about does not unmatch it.
  applied.exposure = 2
  #expect(boost.matches(applied, capabilities: fullCapabilities))

  // One it does name, does.
  applied.contrast = 0.1
  #expect(!boost.matches(applied, capabilities: fullCapabilities))
}

@Test func capturingBuildsASparsePresetFromWhatDiffersFromTheCameraDefault() {
  var defaults = RawParameters()
  defaults.contrast = 0.2

  var parameters = defaults
  parameters.contrast = 0.7
  parameters.exposure = 1.5
  parameters.neutralTemperature = 3200
  parameters.lensCorrection = false

  let look = RawPreset.capturing(
    parameters,
    against: defaults,
    named: "Look",
    includingWhiteBalanceAndExposure: false
  )
  #expect(look.floats == [.contrast: 0.7])
  #expect(look.bools == [.lensCorrection: false])
  #expect(!look.isBuiltIn)

  let everything = RawPreset.capturing(
    parameters,
    against: defaults,
    named: "Look",
    includingWhiteBalanceAndExposure: true
  )
  #expect(everything.floats[.exposure] == 1.5)
  #expect(everything.floats[.neutralTemperature] == 3200)
}

@Test func capturingWithoutCapturedDefaultsComparesAgainstAFreshParameterSet() {
  var parameters = RawParameters()
  parameters.contrast = 0.7

  let look = RawPreset.capturing(
    parameters,
    against: nil,
    named: "Look",
    includingWhiteBalanceAndExposure: false
  )

  #expect(look.floats == [.contrast: 0.7])
}

@Test func rawPresetRoundTripsThroughJSON() throws {
  let preset = RawPreset(
    name: "Look",
    floats: [.contrast: 0.35, .boostShadowAmount: 1.2],
    bools: [.lensCorrection: false]
  )

  let data = try JSONEncoder().encode(preset)
  let restored = try JSONDecoder().decode(RawPreset.self, from: data)

  #expect(restored == preset)
}

@Test func decodingAPresetDropsParameterNamesThisBuildDoesNotKnow() throws {
  let json = """
    {
      "id": "7A0C51D2-0000-4000-A000-0000000000FF",
      "name": "From the future",
      "floats": { "contrast": 0.35, "notAParameter": 3 },
      "bools": { "lensCorrection": false, "alsoNotAParameter": true },
      "isBuiltIn": false
    }
    """
  let preset = try JSONDecoder().decode(RawPreset.self, from: Data(json.utf8))

  #expect(preset.floats == [.contrast: 0.35])
  #expect(preset.bools == [.lensCorrection: false])
}

@Test func savingOverABuiltInStoresAUserCopy() {
  var library = RawPresetLibrary()
  var edited = RawPresetCatalog.boost
  edited.floats[.contrast] = 0.9

  library.save(edited)

  #expect(library.userPresets.count == 1)
  #expect(library.userPresets[0].id != RawPresetCatalog.boost.id)
  #expect(!library.userPresets[0].isBuiltIn)
  // The shipped preset is still there, unchanged.
  #expect(library.preset(id: RawPresetCatalog.boost.id) == RawPresetCatalog.boost)
  #expect(library.all.count == RawPresetCatalog.builtIns.count + 1)
}

@Test func savingAUserPresetTwiceReplacesItRatherThanAddingIt() {
  var library = RawPresetLibrary()
  var look = RawPreset(name: "Look", floats: [.contrast: 0.5])
  library.save(look)

  look.floats[.contrast] = 0.6
  library.save(look)

  #expect(library.userPresets.count == 1)
  #expect(library.userPresets[0].floats == [.contrast: 0.6])

  library.remove(id: look.id)
  #expect(library.userPresets.isEmpty)
}

import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func aFreshStoreOffersTheBuiltInPresetsAndNothingElse() throws {
  let suite = try #require(UserDefaults(suiteName: "PixeltjeMacKitTests.\(UUID().uuidString)"))
  defer { suite.removePersistentDomain(forName: suite.description) }

  let store = RawPresetStore(preferences: suite)

  #expect(store.library.userPresets.isEmpty)
  #expect(store.presets == RawPresetCatalog.builtIns)
  #expect(store.preset(id: RawPresetCatalog.boost.id) == RawPresetCatalog.boost)
}

@MainActor
@Test func aSavedPresetSurvivesIntoTheNextStore() throws {
  let suite = try #require(UserDefaults(suiteName: "PixeltjeMacKitTests.\(UUID().uuidString)"))
  defer { suite.removePersistentDomain(forName: suite.description) }

  let store = RawPresetStore(preferences: suite)
  let saved = store.save(RawPreset(name: "Look", floats: [.contrast: 0.5]))

  let reopened = RawPresetStore(preferences: suite)
  #expect(reopened.library.userPresets == [saved])
  #expect(reopened.preset(id: saved.id)?.floats == [.contrast: 0.5])

  reopened.delete(id: saved.id)
  #expect(RawPresetStore(preferences: suite).library.userPresets.isEmpty)
}

/// A library written by some other version is not an error worth stopping for:
/// the shipped presets alone are a complete, working set.
@MainActor
@Test func anUnreadableLibraryFallsBackToTheBuiltInsAlone() throws {
  let suite = try #require(UserDefaults(suiteName: "PixeltjeMacKitTests.\(UUID().uuidString)"))
  defer { suite.removePersistentDomain(forName: suite.description) }
  suite.set(Data("not a preset library".utf8), forKey: "PixeltjeMac.rawPresetLibrary")

  let store = RawPresetStore(preferences: suite)

  #expect(store.library.userPresets.isEmpty)
  #expect(store.presets == RawPresetCatalog.builtIns)
}

@MainActor
@Test func savingOverAShippedPresetKeepsTheShippedOne() throws {
  let suite = try #require(UserDefaults(suiteName: "PixeltjeMacKitTests.\(UUID().uuidString)"))
  defer { suite.removePersistentDomain(forName: suite.description) }

  let store = RawPresetStore(preferences: suite)
  var edited = RawPresetCatalog.boost
  edited.floats[.contrast] = 0.9
  store.save(edited)

  #expect(store.preset(id: RawPresetCatalog.boost.id) == RawPresetCatalog.boost)
  #expect(store.library.userPresets.count == 1)
  #expect(store.library.userPresets[0].id != RawPresetCatalog.boost.id)
}

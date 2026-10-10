import Combine
import Foundation
import PixeltjeMacDomain

/// The RAW develop presets, shared by every document.
///
/// A look belongs to the person, not to one project: the same "Boost" is wanted
/// on the next file opened. Presets therefore live beside the other preferences
/// in `UserDefaults` rather than in `project.json`, and one store instance
/// serves every window so a preset saved in one document appears in the next.
@MainActor
public final class RawPresetStore: ObservableObject {
  private static let libraryKey = "PixeltjeMac.rawPresetLibrary"

  public static let shared = RawPresetStore()

  @Published public private(set) var library: RawPresetLibrary

  private let preferences: UserDefaults

  public init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
    self.library = Self.storedLibrary(in: preferences)
  }

  public var presets: [RawPreset] { library.all }

  public func preset(id: UUID) -> RawPreset? { library.preset(id: id) }

  @discardableResult
  public func save(_ preset: RawPreset) -> RawPreset {
    var updated = library
    updated.save(preset)
    library = updated
    persist()
    // `save` may have re-identified a preset copied from a built-in.
    return library.userPresets.last { $0.name == preset.name } ?? preset
  }

  public func delete(id: UUID) {
    guard library.userPresets.contains(where: { $0.id == id }) else { return }
    var updated = library
    updated.remove(id: id)
    library = updated
    persist()
  }

  private func persist() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(library) else { return }
    preferences.set(data, forKey: Self.libraryKey)
  }

  private static func storedLibrary(in preferences: UserDefaults) -> RawPresetLibrary {
    guard let data = preferences.data(forKey: libraryKey),
      let library = try? JSONDecoder().decode(RawPresetLibrary.self, from: data)
    else {
      // An absent or unreadable library is not an error: the built-ins alone
      // are a complete, working set.
      return RawPresetLibrary()
    }
    return library
  }
}

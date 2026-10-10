import Combine
import Foundation
import PixeltjeMacDomain

/// The export presets, shared by every document.
///
/// Presets belong to the person, not to one project: the same "Web JPEG" is
/// wanted in every document a photographer opens. They therefore live beside
/// the other preferences in `UserDefaults` rather than in `project.json`, and
/// one store instance serves every window so a preset saved in one document
/// appears in the next.
@MainActor
public final class ExportPresetStore: ObservableObject {
  private static let libraryKey = "PixeltjeMac.exportPresetLibrary"
  private static let lastPresetKey = "PixeltjeMac.lastExportPresetID"
  private static let lastDestinationKey = "PixeltjeMac.lastExportDestination"
  private static let sequenceKey = "PixeltjeMac.exportSequenceNumber"

  public static let shared = ExportPresetStore()

  @Published public private(set) var library: ExportPresetLibrary

  private let preferences: UserDefaults

  public init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
    self.library = Self.storedLibrary(in: preferences)
  }

  public var presets: [ExportPreset] { library.all }

  public func preset(id: UUID) -> ExportPreset? { library.preset(id: id) }

  /// The preset the popup opens on: the last one used, or the first built-in.
  public var lastUsedPreset: ExportPreset {
    if let stored = preferences.string(forKey: Self.lastPresetKey),
      let id = UUID(uuidString: stored),
      let preset = library.preset(id: id)
    {
      return preset
    }
    return ExportPreset.defaultPreset
  }

  public func rememberLastUsed(_ preset: ExportPreset) {
    preferences.set(preset.id.uuidString, forKey: Self.lastPresetKey)
  }

  /// The folder the last export was written to, when it still exists.
  public var lastDestination: URL? {
    guard let path = preferences.string(forKey: Self.lastDestinationKey) else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  public func rememberDestination(_ url: URL) {
    preferences.set(url.standardizedFileURL.path, forKey: Self.lastDestinationKey)
  }

  /// The value `{sequence}` would take next, without consuming it.
  ///
  /// The popup shows a file-name preview before the user commits, so it needs
  /// to look at the counter without advancing it.
  public var upcomingSequenceNumber: Int {
    max(0, preferences.integer(forKey: Self.sequenceKey)) + 1
  }

  /// The next value for a naming template's `{sequence}` token.
  ///
  /// The counter is shared across documents, so a batch of exports numbers
  /// consecutively however many windows produced it.
  public func nextSequenceNumber() -> Int {
    let next = max(0, preferences.integer(forKey: Self.sequenceKey)) + 1
    preferences.set(next, forKey: Self.sequenceKey)
    return next
  }

  @discardableResult
  public func save(_ preset: ExportPreset) -> ExportPreset {
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

  private static func storedLibrary(in preferences: UserDefaults) -> ExportPresetLibrary {
    guard let data = preferences.data(forKey: libraryKey),
      let library = try? JSONDecoder().decode(ExportPresetLibrary.self, from: data)
    else {
      // An absent or unreadable library is not an error: the built-ins alone
      // are a complete, working set.
      return ExportPresetLibrary()
    }
    return library
  }
}

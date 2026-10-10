import Foundation

/// Shared interaction preferences. These affect canvas controls and overlays,
/// never the document recipe or rendered pixels.
enum InteractionPreferences {
  static let invertPanDirectionKey = "PixeltjeMac.invertPanDirection"
  static let disableHintsKey = "PixeltjeMac.disableHints"

  static var invertsPanDirection: Bool {
    UserDefaults.standard.bool(forKey: invertPanDirectionKey)
  }

  static var disablesHints: Bool {
    UserDefaults.standard.bool(forKey: disableHintsKey)
  }
}

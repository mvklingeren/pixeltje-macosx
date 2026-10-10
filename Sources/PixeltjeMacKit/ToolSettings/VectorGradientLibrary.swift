import Foundation
import PixeltjeMacDomain

/// The gradients the fill editor offers: a small built-in set, plus the ones
/// this user reached for most recently.
///
/// Recents are a user preference rather than document state, so they live in
/// `UserDefaults` and never enter a recipe, history, or an exported file.
@MainActor
final class VectorGradientLibrary: ObservableObject {
  static let shared = VectorGradientLibrary()

  private static let recentsKey = "VectorGradientRecents"
  private static let recentsLimit = 8

  @Published private(set) var recents: [VectorGradient] = []

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    recents = Self.decodeRecents(from: defaults)
  }

  /// The built-in set: enough to start from, not a catalog to browse.
  static let presets: [(name: String, gradient: VectorGradient)] = [
    (
      "Black to White",
      VectorGradient(stops: [
        VectorGradientStop(color: .black, position: 0),
        VectorGradientStop(color: .white, position: 1),
      ])
    ),
    (
      "White to Transparent",
      VectorGradient(stops: [
        VectorGradientStop(color: .white, position: 0),
        VectorGradientStop(
          color: VectorColor(red: 1, green: 1, blue: 1, alpha: 0), position: 1),
      ])
    ),
    (
      "Sunrise",
      VectorGradient(stops: [
        VectorGradientStop(
          color: VectorColor(red: 0.98, green: 0.42, blue: 0.24), position: 0),
        VectorGradientStop(
          color: VectorColor(red: 0.99, green: 0.82, blue: 0.36), position: 1),
      ])
    ),
    (
      "Deep Sea",
      VectorGradient(stops: [
        VectorGradientStop(
          color: VectorColor(red: 0.04, green: 0.12, blue: 0.31), position: 0),
        VectorGradientStop(
          color: VectorColor(red: 0.16, green: 0.62, blue: 0.72), position: 1),
      ])
    ),
    (
      "Spotlight",
      VectorGradient(
        kind: .radial,
        stops: [
          VectorGradientStop(color: .white, position: 0),
          VectorGradientStop(
            color: VectorColor(red: 0, green: 0, blue: 0, alpha: 0), position: 1),
        ],
        start: VectorPoint(x: 0.5, y: 0.5),
        end: VectorPoint(x: 1, y: 0.5)
      )
    ),
  ]

  /// Records a gradient the user just applied.
  ///
  /// Only the ramp identifies a recent: two gradients that differ solely in
  /// where their handles sit are the same choice, so matching on stops and kind
  /// keeps the list from filling with near-duplicates.
  func remember(_ gradient: VectorGradient) {
    var next = recents.filter { !isSameRamp($0, gradient) }
    next.insert(gradient, at: 0)
    recents = Array(next.prefix(Self.recentsLimit))
    if let data = try? JSONEncoder().encode(recents) {
      defaults.set(data, forKey: Self.recentsKey)
    }
  }

  func clearRecents() {
    recents = []
    defaults.removeObject(forKey: Self.recentsKey)
  }

  private func isSameRamp(_ first: VectorGradient, _ second: VectorGradient) -> Bool {
    guard first.kind == second.kind, first.stops.count == second.stops.count else { return false }
    return zip(first.stops, second.stops).allSatisfy { left, right in
      left.color == right.color && abs(left.position - right.position) < 0.001
        && abs(left.midpoint - right.midpoint) < 0.001
    }
  }

  private static func decodeRecents(from defaults: UserDefaults) -> [VectorGradient] {
    guard let data = defaults.data(forKey: recentsKey),
      let stored = try? JSONDecoder().decode([VectorGradient].self, from: data)
    else { return [] }
    return Array(stored.prefix(recentsLimit))
  }
}

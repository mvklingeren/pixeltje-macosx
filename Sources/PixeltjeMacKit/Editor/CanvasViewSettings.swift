import AppKit
import Combine
import Foundation
import SwiftUI

/// A canvas overlay that can be switched on and off.
///
/// These are working preferences, not part of the composition: hiding the
/// rulers changes nothing about what a project renders or exports. They are
/// therefore user defaults rather than recipe state, and the same switch is
/// reachable from the View menu and from the right panel's Canvas section.
public enum CanvasViewOption: Int, CaseIterable, Sendable {
  case rulers
  case guides
  case lockGuides
  case grid
  case snap

  public var title: String {
    switch self {
    case .rulers: "Show Rulers"
    case .guides: "Show Guides"
    case .lockGuides: "Lock Guides"
    case .grid: "Show Grid"
    case .snap: "Snap"
    }
  }

  /// The label the inspector uses, where the surrounding section already says
  /// these are canvas overlays.
  public var panelTitle: String {
    switch self {
    case .rulers: "Rulers"
    case .guides: "Guides"
    case .lockGuides: "Lock guides"
    case .grid: "Grid"
    case .snap: "Snap"
    }
  }

  public var keyEquivalent: String {
    switch self {
    case .rulers: "r"
    case .guides: ";"
    case .lockGuides: ";"
    case .grid: "'"
    case .snap: ";"
    }
  }

  public var keyEquivalentModifiers: NSEvent.ModifierFlags {
    switch self {
    case .rulers, .guides, .grid: [.command]
    case .lockGuides: [.command, .option]
    case .snap: [.command, .shift]
    }
  }

  fileprivate var defaultsKey: String {
    switch self {
    case .rulers: "PixeltjeMac.showsRulers"
    case .guides: "PixeltjeMac.showsGuides"
    case .lockGuides: "PixeltjeMac.locksGuides"
    case .grid: "PixeltjeMac.showsGrid"
    case .snap: "PixeltjeMac.snaps"
    }
  }

  /// What a fresh install starts with. Rulers, guides and snapping are on
  /// because they are how the canvas is worked on; the grid is off because it
  /// covers the image.
  fileprivate var defaultValue: Bool {
    switch self {
    case .rulers, .guides, .snap: true
    case .lockGuides, .grid: false
    }
  }
}

/// The canvas view toggles, shared by every document window.
///
/// One object rather than one per document: the View menu is application-wide,
/// and turning the rulers off is a statement about how the user works, not
/// about one project.
@MainActor
public final class CanvasViewSettings: ObservableObject {
  public static let shared = CanvasViewSettings()

  @Published public private(set) var values: [CanvasViewOption: Bool]

  private let preferences: UserDefaults

  public init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
    var values: [CanvasViewOption: Bool] = [:]
    for option in CanvasViewOption.allCases {
      values[option] =
        preferences.object(forKey: option.defaultsKey) as? Bool ?? option.defaultValue
    }
    self.values = values
  }

  public func isOn(_ option: CanvasViewOption) -> Bool {
    values[option] ?? option.defaultValue
  }

  public func set(_ option: CanvasViewOption, to isOn: Bool) {
    guard values[option] != isOn else { return }
    values[option] = isOn
    preferences.set(isOn, forKey: option.defaultsKey)
  }

  public func toggle(_ option: CanvasViewOption) {
    set(option, to: !isOn(option))
  }

  /// A SwiftUI binding for the inspector's mirror of a View-menu toggle.
  public func binding(_ option: CanvasViewOption) -> Binding<Bool> {
    Binding(
      get: { [weak self] in self?.isOn(option) ?? option.defaultValue },
      set: { [weak self] isOn in self?.set(option, to: isOn) }
    )
  }

  /// Whether guides can be grabbed on the canvas: they have to be visible to be
  /// pointed at, and unlocked to be moved.
  public var guidesAreEditable: Bool {
    isOn(.guides) && !isOn(.lockGuides)
  }
}

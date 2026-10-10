import AppKit

/// The picker the shared color panel opens on.
///
/// `NSColorPanel` remembers its last picker under `NSColorPanelMode` and reads
/// an absent key as 0 — which is `NSColorPanel.Mode.gray`. An app that has
/// never had the panel opened therefore starts every color well on the Gray
/// Scale sliders, where a paint color, a stroke and a fill all have exactly one
/// channel to set.
///
/// Writing that default is not enough on its own: an install whose panel has
/// been opened even once already has a value stored, and a seed that only
/// writes when the key is absent then has nothing left to do. So the mode is
/// applied rather than suggested — `setPickerMode(_:)` is the documented way to
/// choose the picker before the panel is shown — and it is given exactly one
/// job: replace Gray Scale. Every other remembered picker, the wheel and the
/// palettes and the pencils included, is left as the person left it.
enum ColorPanelPreferences {
  static let modeKey = "NSColorPanelMode"

  /// RGB sliders rather than the wheel: an image editor is a place where a
  /// color is often a value to be typed exactly, and this tab carries the
  /// numeric fields and the hex entry.
  static let replacementMode = NSColorPanel.Mode.RGB

  /// Every picker worth reopening on: the full set minus Gray Scale and minus
  /// `.none`, which is what the panel reports when it is showing no picker at
  /// all. Matching against the list rather than `Mode(rawValue:)` also throws
  /// out a stored number no picker answers to, which that initializer accepts.
  static let reopenableModes: [NSColorPanel.Mode] = [
    .RGB, .CMYK, .HSB, .customPalette, .colorList, .wheel, .crayon,
  ]

  /// The picker to open on, given the raw value the panel last stored.
  static func openingMode(storedMode: Int?) -> NSColorPanel.Mode {
    guard let storedMode, let mode = reopenableModes.first(where: { $0.rawValue == storedMode })
    else { return replacementMode }
    return mode
  }

  /// Applies the opening mode to the shared color panel.
  ///
  /// Both halves matter. `setPickerMode(_:)` is the public way to choose the
  /// picker, and writing the mode back covers the panel's own restore path —
  /// whichever of the two the panel consults on the launch it is first shown,
  /// they now agree.
  @MainActor
  static func applyOpeningMode(in defaults: UserDefaults = .standard) {
    let mode = openingMode(storedMode: defaults.object(forKey: modeKey) as? Int)
    defaults.set(mode.rawValue, forKey: modeKey)
    NSColorPanel.setPickerMode(mode)
  }
}

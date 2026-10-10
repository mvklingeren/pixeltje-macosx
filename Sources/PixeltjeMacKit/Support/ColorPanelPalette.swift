import AppKit

/// The swatches Pixeltje puts in the color panel's Palettes tab.
///
/// One list, always under the same name, holding one of two things: the colors
/// the frame on screen is actually made of, or a fixed default set. Sampling is
/// the useful one — painting into an image usually means painting with colors
/// that are already in it — but it makes the palette move under the person
/// using it, so `Use sampled colors for the color picker` in Settings turns it
/// off and pins the defaults instead.
///
/// The list is rebuilt rather than edited. `NSColorPanel` reads a color list
/// when it is attached, so replacing the swatches means detaching the old list
/// and attaching a new one.
@MainActor
final class ColorPanelPalette {
  static let shared = ColorPanelPalette()

  /// The name the panel shows in its palette popup.
  static let listName = "Pixeltje"

  /// How often the attached list may be rebuilt. The canvas renders a frame
  /// every 35 ms through a slider drag, and each rebuild is a detach, an
  /// attach and a redraw of the panel's swatch grid — the palette has to
  /// follow the image without being torn down thirty times a second.
  private static let minimumInterval = Duration.milliseconds(750)

  private var usesSampledColors = true
  private var sampledColors: [PaletteColor] = []
  private var attachedList: NSColorList?
  private var lastAttachment: ContinuousClock.Instant?
  private var scheduledAttachment: Task<Void, Never>?

  private init() {}

  /// Turning the setting over is a direct answer to something the person just
  /// did, so it swaps the palette immediately rather than waiting out the
  /// interval a stream of renders is subject to.
  func setUsesSampledColors(_ uses: Bool) {
    guard uses != usesSampledColors else { return }
    usesSampledColors = uses
    attachCurrentColors()
  }

  /// Takes the colors of the frame that was just rendered.
  ///
  /// An empty sample — a document that has not rendered yet, or one whose
  /// canvas is entirely transparent — leaves the palette alone rather than
  /// emptying it, so the swatches do not vanish between documents.
  func setSampledColors(_ colors: [PaletteColor]) {
    guard !colors.isEmpty, colors != sampledColors else { return }
    sampledColors = colors
    guard usesSampledColors else { return }
    scheduleAttachment()
  }

  /// Attaches now, or once the interval is up.
  ///
  /// A rebuild already waiting is left to run: it will pick up whatever the
  /// colors are by the time it fires, so a burst of renders costs one rebuild
  /// and ends on the newest palette rather than a stale one.
  private func scheduleAttachment() {
    guard scheduledAttachment == nil else { return }
    let elapsed = lastAttachment.map { ContinuousClock.now - $0 }
    guard let elapsed, elapsed < Self.minimumInterval else {
      attachCurrentColors()
      return
    }
    let remaining = Self.minimumInterval - elapsed
    scheduledAttachment = Task { [weak self] in
      try? await Task.sleep(for: remaining)
      guard let self else { return }
      self.scheduledAttachment = nil
      self.attachCurrentColors()
    }
  }

  /// Builds and attaches the list the current setting calls for. Called once at
  /// launch so the Palettes tab is never empty of ours, and again whenever the
  /// colors or the setting change.
  func attachCurrentColors() {
    let colors = usesSampledColors && !sampledColors.isEmpty ? sampledColors : Self.defaultColors
    let list = NSColorList(name: Self.listName)
    // A hex name is unique per color, so a repeat would silently overwrite the
    // earlier swatch. Keeping the first occurrence keeps the ordering intact.
    var used: Set<String> = []
    for color in colors where used.insert(color.hexName).inserted {
      list.setColor(color.nsColor, forKey: color.hexName)
    }
    let panel = NSColorPanel.shared
    if let attachedList { panel.detachColorList(attachedList) }
    panel.attachColorList(list)
    attachedList = list
    lastAttachment = ContinuousClock.now
  }

  /// The set to fall back on: a neutral ramp, then twelve hues at a shadow, a
  /// full and a tinted value each. Enough to paint with on a document that has
  /// nothing in it yet, and a deliberate answer for anyone who would rather
  /// their palette held still.
  nonisolated static let defaultColors: [PaletteColor] = {
    // Stepped over integers: a floating-point stride through 1.0 can stop one
    // ulp short of it and leave the ramp without its white.
    var colors = (0...5).map { PaletteColor(hue: 0, saturation: 0, brightness: Double($0) / 5) }
    for step in 0..<12 {
      let hue = Double(step) / 12
      colors.append(PaletteColor(hue: hue, saturation: 1, brightness: 0.55))
      colors.append(PaletteColor(hue: hue, saturation: 1, brightness: 1))
      colors.append(PaletteColor(hue: hue, saturation: 0.4, brightness: 1))
    }
    return colors
  }()
}

extension PaletteColor {
  /// The swatch as something the color panel can hold.
  ///
  /// Display P3, because that is the space the entries are measured and
  /// specified in — see the note on `PaletteColor`.
  var nsColor: NSColor {
    NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1)
  }

  /// A color given by hue, saturation and brightness on 0...1.
  ///
  /// Converted here rather than through `NSColor(hue:saturation:brightness:)`,
  /// which specifies its color in the calibrated RGB space: the numbers below
  /// are then Display P3 coordinates exactly as written.
  init(hue: Double, saturation: Double, brightness: Double) {
    let sector = (hue - hue.rounded(.down)) * 6
    let offset = sector - sector.rounded(.down)
    let low = brightness * (1 - saturation)
    let falling = brightness * (1 - saturation * offset)
    let rising = brightness * (1 - saturation * (1 - offset))
    switch Int(sector) % 6 {
    case 0: self.init(red: brightness, green: rising, blue: low)
    case 1: self.init(red: falling, green: brightness, blue: low)
    case 2: self.init(red: low, green: brightness, blue: rising)
    case 3: self.init(red: low, green: falling, blue: brightness)
    case 4: self.init(red: rising, green: low, blue: brightness)
    default: self.init(red: brightness, green: low, blue: falling)
    }
  }
}

import AppKit

/// AppKit images for the left tool strip. Magnet Selection uses a fixed-size
/// canvas so its native wand symbol aligns with the other toolbar icons.
@MainActor
enum EditorToolIcon {
  static func image(for tool: EditorTool) -> NSImage {
    if tool == .magnetSelection { return magnetSelection }
    return NSImage(
      systemSymbolName: tool.symbolName,
      accessibilityDescription: "\(tool.label) Tool"
    ) ?? fallback
  }

  private static let magnetSelection: NSImage = {
    let size = NSSize(width: 18, height: 18)
    guard let symbol = NSImage(
      systemSymbolName: "wand.and.stars",
      accessibilityDescription: "Magnet Selection Tool"
    ) else { return fallback }
    let image = NSImage(size: size, flipped: false) { bounds in
      symbol.draw(in: bounds)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Magnet Selection Tool"
    return image
  }()

  private static let fallback =
    NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: "Tool")
      ?? NSImage(size: NSSize(width: 18, height: 18))
}

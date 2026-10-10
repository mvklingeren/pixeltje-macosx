import AppKit

final class BrowserCollectionView: NSCollectionView {
  var openItem: ((IndexPath) -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    guard event.clickCount == 2 else { return }
    let location = convert(event.locationInWindow, from: nil)
    if let indexPath = indexPathForItem(at: location) {
      openItem?(indexPath)
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}",
      let selected = selectionIndexPaths.sorted().first
    {
      openItem?(selected)
      return
    }
    super.keyDown(with: event)
  }
}

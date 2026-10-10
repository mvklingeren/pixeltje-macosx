import AppKit
import SwiftUI

/// Hosts one side panel's SwiftUI content inside the document window's split
/// view.
///
/// The window controller owns one of these and hands its `model` to every
/// feature that wants a section, so a feature never has to touch the split view
/// or AppKit at all.
@MainActor
final class PanelViewController: NSViewController {
  let model: PanelModel

  private let host: NSHostingController<PanelView>

  init(model: PanelModel, emptyDescription: String) {
    self.model = model
    self.host = NSHostingController(
      rootView: PanelView(model: model, emptyDescription: emptyDescription)
    )
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("PanelViewController is created programmatically")
  }

  override func loadView() {
    view = NSView()
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}

import AppKit
import Combine
import SwiftUI

enum SettingsDestination: Hashable {
  case comfyUIWorkflows
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
  @Published var destination: SettingsDestination? = nil
}

@MainActor
final class SettingsWindowController: NSWindowController {
  private let navigation: SettingsNavigationModel

  init(settings: AppSettings) {
    let navigation = SettingsNavigationModel()
    self.navigation = navigation
    let hosting = NSHostingController(
      rootView: SettingsView(settings: settings, navigation: navigation))
    let window = NSWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable]
    window.title = "Settings"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.setFrameAutosaveName("PixeltjeMacSettingsWindow")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsWindowController is created programmatically")
  }

  func show(destination: SettingsDestination? = nil) {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    guard let destination else { return }
    navigation.destination = nil
    DispatchQueue.main.async { [weak self] in
      self?.navigation.destination = destination
    }
  }
}

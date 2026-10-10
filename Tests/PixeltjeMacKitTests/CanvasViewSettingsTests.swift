import AppKit
import Combine
import Foundation
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func rulerVisibilityTracksTheCurrentViewSetting() throws {
  let suiteName = "CanvasViewSettingsTests.rulers.\(UUID().uuidString)"
  let suite = try #require(UserDefaults(suiteName: suiteName))
  defer { suite.removePersistentDomain(forName: suiteName) }

  let settings = CanvasViewSettings(preferences: suite)
  let controller = CanvasViewController(
    model: EditorModel(),
    viewSettings: settings
  ) { _ in }
  let rulers = controller.view.subviews.compactMap { $0 as? CanvasRulerView }

  #expect(rulers.count == 2)
  #expect(rulers.allSatisfy { !$0.isHidden })

  settings.set(.rulers, to: false)
  #expect(rulers.allSatisfy { $0.isHidden })

  settings.set(.rulers, to: true)
  #expect(rulers.allSatisfy { !$0.isHidden })
}

@MainActor
@Test func viewMenuCheckmarkTracksTheRightPanelSetting() throws {
  let suiteName = "CanvasViewSettingsTests.menu.\(UUID().uuidString)"
  let suite = try #require(UserDefaults(suiteName: suiteName))
  defer { suite.removePersistentDomain(forName: suiteName) }

  let application = NSApplication.shared
  let previousMenu = application.mainMenu
  defer { application.mainMenu = previousMenu }

  let settings = CanvasViewSettings(preferences: suite)
  let delegate = PixeltjeMacAppDelegate()
  let observation = MainMenu.install(delegate: delegate, canvasViewSettings: settings)
  defer { observation.cancel() }

  let viewMenu = try #require(
    application.mainMenu?.items.compactMap(\.submenu).first { $0.title == "View" })
  let rulerItem = try #require(
    viewMenu.items.first {
      $0.action == #selector(PixeltjeMacAppDelegate.toggleCanvasViewOption(_:))
        && $0.tag == CanvasViewOption.rulers.rawValue
    })

  #expect(rulerItem.state == .on)

  // This is the path used by the right-panel binding.
  settings.set(.rulers, to: false)
  #expect(rulerItem.state == .off)

  settings.set(.rulers, to: true)
  #expect(rulerItem.state == .on)
}

@MainActor
@Test func panelShortcutsUseCommandNumberKeys() throws {
  let suiteName = "CanvasViewSettingsTests.panelShortcuts.\(UUID().uuidString)"
  let suite = try #require(UserDefaults(suiteName: suiteName))
  defer { suite.removePersistentDomain(forName: suiteName) }

  let application = NSApplication.shared
  let previousMenu = application.mainMenu
  defer { application.mainMenu = previousMenu }

  let settings = CanvasViewSettings(preferences: suite)
  let observation = MainMenu.install(
    delegate: PixeltjeMacAppDelegate(),
    canvasViewSettings: settings
  )
  defer { observation.cancel() }

  let viewMenu = try #require(
    application.mainMenu?.items.compactMap(\.submenu).first { $0.title == "View" })
  let expected: [(Selector, String)] = [
    (#selector(ProjectWindowController.toggleLeftPanel(_:)), "1"),
    (#selector(ProjectWindowController.toggleRightPanel(_:)), "2"),
    (#selector(ProjectWindowController.toggleDevelopPanel(_:)), "3"),
    (#selector(ProjectWindowController.toggleAssistancePanel(_:)), "5"),
  ]

  for (action, key) in expected {
    let item = try #require(viewMenu.items.first { $0.action == action })
    #expect(item.keyEquivalent == key)
    #expect(item.keyEquivalentModifierMask == [.command])
  }
}

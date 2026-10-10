import AppKit
import Foundation

@main
struct PixeltjePipelineEditorApplication {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    let delegate = PipelineEditorApplicationDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

@MainActor
private final class PipelineEditorApplicationDelegate: NSObject, NSApplicationDelegate {
  private var windowController: PipelineEditorWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = PipelineEditorWindowController()
    windowController = controller
    NSApp.mainMenu = makeMainMenu(controller: controller)

    if let path = CommandLine.arguments.dropFirst().first, !path.hasPrefix("-") {
      controller.open(URL(fileURLWithPath: path))
    }
    controller.show()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    guard let first = filenames.first else {
      sender.reply(toOpenOrPrint: .failure)
      return
    }
    windowController?.open(URL(fileURLWithPath: first))
    windowController?.show()
    sender.reply(toOpenOrPrint: .success)
  }

  private func makeMainMenu(controller: PipelineEditorWindowController) -> NSMenu {
    let menu = NSMenu()

    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "About Pixeltje Pipeline",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(menuItem(
      "Settings…", key: ",", action: #selector(controller.showSettings(_:)),
      target: controller))
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      withTitle: "Quit Pixeltje Pipeline",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    applicationItem.submenu = applicationMenu
    menu.addItem(applicationItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(menuItem("New Workflow", key: "n",
      action: #selector(controller.newDocument(_:)), target: controller))
    fileMenu.addItem(menuItem("Open…", key: "o", action: #selector(controller.openDocument(_:)),
      target: controller))
    fileMenu.addItem(menuItem("Show Example Workflows", key: "",
      action: #selector(controller.showExampleWorkflows(_:)), target: controller))
    fileMenu.addItem(
      menuItem(
        "Import ComfyUI Workflow…", key: "", action: #selector(controller.importComfyUIWorkflow(_:)),
        target: controller))
    fileMenu.addItem(.separator())
    fileMenu.addItem(menuItem("Save", key: "s", action: #selector(controller.saveDocument(_:)),
      target: controller))
    let saveAs = menuItem(
      "Save As…", key: "S", action: #selector(controller.saveDocumentAs(_:)), target: controller)
    saveAs.keyEquivalentModifierMask = [.command, .shift]
    fileMenu.addItem(saveAs)
    fileMenu.addItem(menuItem("Export Model Python…", key: "",
      action: #selector(controller.exportModelPython(_:)), target: controller))
    fileMenu.addItem(.separator())
    fileMenu.addItem(
      menuItem("Close", key: "w", action: #selector(NSWindow.performClose(_:)), target: nil))
    fileItem.submenu = fileMenu
    menu.addItem(fileItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(
      menuItem(
        "Undo", key: "z", action: #selector(controller.undoGraphEdit(_:)),
        target: controller))
    let redo = menuItem(
      "Redo", key: "z", action: #selector(controller.redoGraphEdit(_:)), target: controller)
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redo)
    editMenu.addItem(.separator())
    // Leave text commands untargeted so the focused field or selectable text
    // receives them through AppKit's responder chain.
    editMenu.addItem(menuItem("Cut", key: "x", action: #selector(NSText.cut(_:)), target: nil))
    editMenu.addItem(menuItem("Copy", key: "c", action: #selector(NSText.copy(_:)), target: nil))
    editMenu.addItem(menuItem("Paste", key: "v", action: #selector(NSText.paste(_:)), target: nil))
    editMenu.addItem(
      menuItem("Select All", key: "a", action: #selector(NSText.selectAll(_:)), target: nil))
    editMenu.addItem(.separator())
    editMenu.addItem(
      menuItem(
        "Delete Selection", key: "", action: #selector(controller.deleteGraphSelection(_:)),
        target: controller))
    editItem.submenu = editMenu
    menu.addItem(editItem)

    let pipelineItem = NSMenuItem()
    let pipelineMenu = NSMenu(title: "Pipeline")
    let run = menuItem(
      "Run Pipeline", key: "\r", action: #selector(controller.runPipeline(_:)),
      target: controller)
    run.keyEquivalentModifierMask = [.command]
    pipelineMenu.addItem(run)
    pipelineMenu.addItem(
      menuItem(
        "Cancel Pipeline", key: ".", action: #selector(controller.cancelPipeline(_:)),
        target: controller))
    pipelineMenu.addItem(.separator())
    pipelineMenu.addItem(
      menuItem(
        "Validate", key: "r", action: #selector(controller.validateDocument(_:)),
        target: controller))
    pipelineMenu.addItem(menuItem("Choose Training Python…", key: "",
      action: #selector(controller.chooseTrainingPython(_:)), target: controller))
    pipelineItem.submenu = pipelineMenu
    menu.addItem(pipelineItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    let toggleNodeLibrary = menuItem(
      "Hide Node Library", key: "l", action: #selector(controller.toggleNodeLibrary(_:)),
      target: controller)
    toggleNodeLibrary.keyEquivalentModifierMask = [.command, .option]
    viewMenu.addItem(toggleNodeLibrary)
    let toggleInspector = menuItem(
      "Hide Inspector", key: "i", action: #selector(controller.toggleInspector(_:)),
      target: controller)
    toggleInspector.keyEquivalentModifierMask = [.command, .option]
    viewMenu.addItem(toggleInspector)
    viewMenu.addItem(.separator())
    let arrangeItem = NSMenuItem(title: "Arrange Nodes", action: nil, keyEquivalent: "")
    let arrangeMenu = NSMenu(title: "Arrange Nodes")
    arrangeMenu.addItem(menuItem("Smart Flow", key: "",
      action: #selector(controller.arrangeNodesInSmartFlow(_:)), target: controller))
    arrangeMenu.addItem(.separator())
    arrangeMenu.addItem(menuItem("Left to Right", key: "",
      action: #selector(controller.arrangeNodesLeftToRight(_:)), target: controller))
    arrangeMenu.addItem(menuItem("Top to Bottom", key: "",
      action: #selector(controller.arrangeNodesTopToBottom(_:)), target: controller))
    arrangeMenu.addItem(menuItem("Compact Grid", key: "",
      action: #selector(controller.arrangeNodesInGrid(_:)), target: controller))
    arrangeItem.submenu = arrangeMenu
    viewMenu.addItem(arrangeItem)
    viewMenu.addItem(menuItem("Fit Workflow", key: "0",
      action: #selector(controller.fitWorkflow(_:)), target: controller))
    viewItem.submenu = viewMenu
    menu.addItem(viewItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(menuItem("Execution Log", key: "", action:
      #selector(controller.showExecutionLog(_:)), target: controller))
    windowMenu.addItem(.separator())
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    menu.addItem(windowItem)
    NSApp.windowsMenu = windowMenu

    let helpItem = NSMenuItem()
    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(menuItem("Set Up FLUX.2 Klein 9B Models…", key: "",
      action: #selector(controller.openKlein9BModelSetupGuide(_:)), target: controller))
    helpItem.submenu = helpMenu
    menu.addItem(helpItem)

    return menu
  }

  private func menuItem(
    _ title: String,
    key: String,
    action: Selector,
    target: AnyObject?
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = target
    return item
  }
}

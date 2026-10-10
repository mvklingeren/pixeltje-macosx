import AppKit
import Combine

@MainActor
enum MainMenu {
  /// Installs the application menu and keeps its canvas-overlay checkmarks in
  /// step with the same settings object used by the right panel.
  ///
  /// The caller retains the returned observation for as long as the menu is
  /// installed. Reading the values delivered by `@Published` is deliberate:
  /// rereading the settings object here would still see the previous value
  /// during its `willSet` notification.
  static func install(
    delegate: PixeltjeMacAppDelegate,
    canvasViewSettings: CanvasViewSettings = .shared
  ) -> AnyCancellable {
    let main = NSMenu(title: "Main Menu")
    main.addItem(appMenu(delegate: delegate))
    main.addItem(fileMenu(delegate: delegate))
    main.addItem(editMenu())
    main.addItem(toolsMenu())
    main.addItem(selectMenu())
    let installedViewMenu = viewMenu(delegate: delegate)
    main.addItem(installedViewMenu.root)
    main.addItem(windowMenu())
    NSApp.mainMenu = main

    return canvasViewSettings.$values.sink { values in
      for (option, item) in installedViewMenu.canvasViewItems {
        guard let isOn = values[option] else { continue }
        item.state = isOn ? .on : .off
      }
      if let lockGuides = installedViewMenu.canvasViewItems[.lockGuides],
        let showsGuides = values[.guides]
      {
        lockGuides.isEnabled = showsGuides
      }
    }
  }

  private struct InstalledViewMenu {
    let root: NSMenuItem
    let canvasViewItems: [CanvasViewOption: NSMenuItem]
  }

  private static func appMenu(delegate: PixeltjeMacAppDelegate) -> NSMenuItem {
    let root = NSMenuItem()
    let menu = NSMenu(title: "Pixeltje Mac")
    root.submenu = menu

    menu.addItem(
      item(
        "About Pixeltje Mac", #selector(PixeltjeMacAppDelegate.showAboutPanel(_:)), target: delegate
      ))
    menu.addItem(.separator())
    menu.addItem(
      item(
        "Settings…", #selector(PixeltjeMacAppDelegate.showSettings(_:)), key: ",", target: delegate
      ))
    menu.addItem(.separator())

    let servicesRoot = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    let services = NSMenu(title: "Services")
    servicesRoot.submenu = services
    menu.addItem(servicesRoot)
    NSApp.servicesMenu = services

    menu.addItem(.separator())
    menu.addItem(
      item("Hide Pixeltje Mac", #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
    let hideOthers = item(
      "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", target: NSApp)
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(hideOthers)
    menu.addItem(
      item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
    menu.addItem(.separator())
    menu.addItem(
      item("Quit Pixeltje Mac", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    return root
  }

  private static func fileMenu(delegate: PixeltjeMacAppDelegate) -> NSMenuItem {
    let root = NSMenuItem()
    let menu = NSMenu(title: "File")
    root.submenu = menu
    menu.addItem(
      item("New", #selector(PixeltjeMacAppDelegate.newDocument(_:)), key: "n", target: delegate))
    let newFromClipboard = item(
      "New from Clipboard",
      #selector(PixeltjeMacAppDelegate.newDocumentFromClipboard(_:)),
      key: "n",
      target: delegate
    )
    newFromClipboard.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(newFromClipboard)
    menu.addItem(
      item("Open…", #selector(PixeltjeMacAppDelegate.openDocument(_:)), key: "o", target: delegate))
    let browseFolder = item(
      "Browse Folder…",
      #selector(PixeltjeMacAppDelegate.browseFolder(_:)),
      key: "o",
      target: delegate
    )
    browseFolder.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(browseFolder)
    menu.addItem(.separator())
    menu.addItem(
      item("Run Script…", #selector(PixeltjeMacAppDelegate.runScript(_:)), target: delegate))
    menu.addItem(
      item(
        "Cancel Running Scripts",
        #selector(PixeltjeMacAppDelegate.cancelRunningScripts(_:)),
        target: delegate
      ))
    menu.addItem(.separator())
    menu.addItem(item("Save", #selector(NSDocument.save(_:)), key: "s"))
    let saveAs = item("Save As…", #selector(NSDocument.saveAs(_:)), key: "s")
    saveAs.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(saveAs)
    menu.addItem(item("Export…", #selector(ProjectWindowController.exportDocument(_:)), key: "e"))
    menu.addItem(.separator())
    menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
    return root
  }

  private static func editMenu() -> NSMenuItem {
    let root = NSMenuItem()
    let menu = NSMenu(title: "Edit")
    root.submenu = menu
    menu.addItem(item("Undo", Selector(("undo:")), key: "z"))
    let redo = item("Redo", Selector(("redo:")), key: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(redo)
    menu.addItem(.separator())
    menu.addItem(item("Free Transform", #selector(ProjectWindowController.activateTransformTool(_:)), key: "t"))
    menu.addItem(.separator())
    // Snapshots pin a state the linear history may later discard, so the
    // command that makes one belongs next to undo and redo.
    menu.addItem(
      item("Take Snapshot", #selector(ProjectWindowController.takeSnapshot(_:))))
    menu.addItem(.separator())
    // These act on the pixels a selection encloses. They travel the responder
    // chain like Select All below them, so a text field that has the keyboard
    // still answers ⌘X, ⌘C and ⌘V for its own text; validation on the window
    // controller stands the canvas commands down while it does.
    menu.addItem(item("Cut", #selector(ProjectWindowController.cut(_:)), key: "x"))
    menu.addItem(item("Copy", #selector(ProjectWindowController.copy(_:)), key: "c"))
    let copyMerged = item("Copy Merged", #selector(ProjectWindowController.copyMerged(_:)), key: "c")
    copyMerged.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(copyMerged)
    menu.addItem(item("Paste", #selector(ProjectWindowController.paste(_:)), key: "v"))
    // Backspace, with no modifier, the way every image editor deletes what is
    // selected. A disabled menu item does not consume its key equivalent, so
    // the pen tool and text fields keep their own ⌫ when this stands down.
    let clear = item("Delete", #selector(ProjectWindowController.delete(_:)), key: "\u{8}")
    clear.keyEquivalentModifierMask = []
    menu.addItem(clear)
    menu.addItem(.separator())
    menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
    return root
  }

  private static func viewMenu(delegate: PixeltjeMacAppDelegate) -> InstalledViewMenu {
    let root = NSMenuItem()
    let menu = NSMenu(title: "View")
    root.submenu = menu
    var canvasViewItems: [CanvasViewOption: NSMenuItem] = [:]
    menu.addItem(item("Zoom In", #selector(ProjectWindowController.zoomIn(_:)), key: "+"))
    menu.addItem(item("Zoom Out", #selector(ProjectWindowController.zoomOut(_:)), key: "-"))
    menu.addItem(
      item("Actual Size", #selector(ProjectWindowController.zoomToActualSize(_:)), key: "0"))
    menu.addItem(item("Zoom to Fit", #selector(ProjectWindowController.zoomToFit(_:)), key: "9"))
    menu.addItem(.separator())
    let leftPanel = item(
      "Left Panel", #selector(ProjectWindowController.toggleLeftPanel(_:)), key: "1")
    leftPanel.keyEquivalentModifierMask = [.command]
    menu.addItem(leftPanel)
    let rightPanel = item(
      "Right Panel", #selector(ProjectWindowController.toggleRightPanel(_:)), key: "2")
    rightPanel.keyEquivalentModifierMask = [.command]
    menu.addItem(rightPanel)
    let developPanel = item(
      "Develop Panel", #selector(ProjectWindowController.toggleDevelopPanel(_:)), key: "3")
    developPanel.keyEquivalentModifierMask = [.command]
    menu.addItem(developPanel)
    let assistancePanel = item(
      "Editing Assistance", #selector(ProjectWindowController.toggleAssistancePanel(_:)), key: "5")
    assistancePanel.keyEquivalentModifierMask = [.command]
    menu.addItem(assistancePanel)
    let promptBox = item(
      "Prompt Box", #selector(ProjectWindowController.togglePromptBox(_:)), key: "k")
    promptBox.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(promptBox)
    // J remains the conventional Healing Brush shortcut. Clipping has direct
    // controls beneath the histogram, so it does not compete for that key.
    menu.addItem(
      item(
        "Clipping Indicators",
        #selector(ProjectWindowController.toggleClippingIndicators(_:))
      ))
    // Before / After belongs to the displayed image rather than to a document
    // command. Menu validation stands its bare key down while a text field has
    // the keyboard.
    let beforeAfter = item(
      "Before / After",
      #selector(ProjectWindowController.toggleBeforeAfter(_:)),
      key: "\\"
    )
    beforeAfter.keyEquivalentModifierMask = []
    menu.addItem(beforeAfter)
    // The picture on its own, on the whole screen. ⌃⌘F below still takes the
    // document window fullscreen, apparatus and all; this shows only the image.
    let fullscreenPreview = item(
      "Fullscreen Preview",
      #selector(ProjectWindowController.toggleFullscreenPreview(_:)),
      key: "f"
    )
    fullscreenPreview.keyEquivalentModifierMask = []
    menu.addItem(fullscreenPreview)
    menu.addItem(.separator())

    // The canvas overlays. These are view state shared by every window, so they
    // are handled by the application delegate rather than travelling the
    // responder chain to one document. Each item carries its option as its tag,
    // and validation puts the checkmark on; the same switches appear in the
    // right panel's Canvas section.
    for option in CanvasViewOption.allCases {
      let toggle = item(
        option.title,
        #selector(PixeltjeMacAppDelegate.toggleCanvasViewOption(_:)),
        key: option.keyEquivalent,
        target: delegate
      )
      toggle.keyEquivalentModifierMask = option.keyEquivalentModifiers
      toggle.tag = option.rawValue
      menu.addItem(toggle)
      canvasViewItems[option] = toggle
    }
    menu.addItem(.separator())

    let clearGuides = item(
      "Clear Guides", #selector(ProjectWindowController.clearGuides(_:)))
    menu.addItem(clearGuides)
    menu.addItem(.separator())

    let fullScreen = item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f")
    fullScreen.keyEquivalentModifierMask = [.control, .command]
    menu.addItem(fullScreen)
    return InstalledViewMenu(root: root, canvasViewItems: canvasViewItems)
  }

  private static func toolsMenu() -> NSMenuItem {
    let root = NSMenuItem()
    let menu = NSMenu(title: "Tools")
    root.submenu = menu

    menu.addItem(item("Navigate Tool", #selector(ProjectWindowController.activateNavigateTool(_:))))
    // Bare keys, the way an image editor's tools are switched. Menu validation
    // stands them down while a text field has the keyboard.
    let move = item("Select/Move Tool", #selector(ProjectWindowController.activateMoveTool(_:)), key: "v")
    move.keyEquivalentModifierMask = []
    menu.addItem(move)
    // Mirror Edit > Free Transform's Command-T here so the shortcut remains
    // discoverable where the other tool shortcuts are listed. Both items send
    // the same responder-chain action.
    menu.addItem(
      item(
        "Free Transform",
        #selector(ProjectWindowController.activateTransformTool(_:)),
        key: "t"
      ))
    let marquee = item(
      "Marquee Tool", #selector(ProjectWindowController.activateMarqueeTool(_:)), key: "m")
    marquee.keyEquivalentModifierMask = []
    menu.addItem(marquee)
    let lasso = item(
      "Lasso Tool", #selector(ProjectWindowController.activateLassoTool(_:)), key: "l")
    lasso.keyEquivalentModifierMask = []
    menu.addItem(lasso)
    let magnetSelection = item(
      "Magnet Selection Tool",
      #selector(ProjectWindowController.activateMagnetSelectionTool(_:)),
      key: "m")
    magnetSelection.keyEquivalentModifierMask = [.shift]
    menu.addItem(magnetSelection)
    menu.addItem(
      item(
        "Selection Brush Tool",
        #selector(ProjectWindowController.activateSelectionBrushTool(_:))
      ))
    let crop = item("Crop Tool", #selector(ProjectWindowController.activateCropTool(_:)), key: "c")
    crop.keyEquivalentModifierMask = []
    menu.addItem(crop)
    let brush = item(
      "Brush Tool", #selector(ProjectWindowController.activateBrushTool(_:)), key: "b")
    brush.keyEquivalentModifierMask = []
    menu.addItem(brush)
    let eraser = item(
      "Eraser Tool", #selector(ProjectWindowController.activateEraserTool(_:)), key: "e")
    eraser.keyEquivalentModifierMask = []
    menu.addItem(eraser)
    let smallerBrush = item(
      "Decrease Brush Size", #selector(ProjectWindowController.decreaseBrushSize(_:)), key: "[")
    smallerBrush.keyEquivalentModifierMask = []
    menu.addItem(smallerBrush)
    let largerBrush = item(
      "Increase Brush Size", #selector(ProjectWindowController.increaseBrushSize(_:)), key: "]")
    largerBrush.keyEquivalentModifierMask = []
    menu.addItem(largerBrush)
    let heal = item(
      "Healing Brush Tool", #selector(ProjectWindowController.activateHealTool(_:)), key: "j")
    heal.keyEquivalentModifierMask = []
    menu.addItem(heal)
    let pen = item("Pen Tool", #selector(ProjectWindowController.activatePenTool(_:)), key: "p")
    pen.keyEquivalentModifierMask = []
    menu.addItem(pen)
    let shape = item("Shape Tool", #selector(ProjectWindowController.activateShapeTool(_:)), key: "u")
    shape.keyEquivalentModifierMask = []
    menu.addItem(shape)
    let gradient = item("Gradient Tool", #selector(ProjectWindowController.activateGradientTool(_:)), key: "g")
    gradient.keyEquivalentModifierMask = []
    menu.addItem(gradient)
    // Gradient and Fill follow the familiar G / Shift-G tool family. Bare F
    // remains the View menu's Fullscreen Preview shortcut.
    let fill = item("Fill Tool", #selector(ProjectWindowController.activateFillTool(_:)), key: "g")
    fill.keyEquivalentModifierMask = [.shift]
    menu.addItem(fill)
    let text = item("Text Tool", #selector(ProjectWindowController.activateTextTool(_:)), key: "t")
    text.keyEquivalentModifierMask = []
    menu.addItem(text)
    let whiteBalance = item(
      "Pick White Balance",
      #selector(ProjectWindowController.pickWhiteBalance(_:)),
      key: "i"
    )
    whiteBalance.keyEquivalentModifierMask = []
    menu.addItem(whiteBalance)
    menu.addItem(
      item(
        "As Shot White Balance",
        #selector(ProjectWindowController.resetWhiteBalanceToAsShot(_:))
      ))
    // M and L belong to the marquee and the lasso, as they do in every other
    // image editor. Masks held M before those tools existed and moved to K.
    let masks = item("Masks Tool", #selector(ProjectWindowController.activateMasksTool(_:)), key: "k")
    masks.keyEquivalentModifierMask = []
    menu.addItem(masks)
    menu.addItem(.separator())

    let swapColors = item(
      "Swap Foreground and Background Colors",
      #selector(ProjectWindowController.swapForegroundAndBackgroundColors(_:)),
      key: "x"
    )
    swapColors.keyEquivalentModifierMask = []
    menu.addItem(swapColors)
    let resetColors = item(
      "Reset Foreground and Background Colors",
      #selector(ProjectWindowController.resetForegroundAndBackgroundColors(_:)),
      key: "d"
    )
    resetColors.keyEquivalentModifierMask = []
    menu.addItem(resetColors)
    menu.addItem(
      item(
        "Sample Foreground Color",
        #selector(ProjectWindowController.pickForegroundColor(_:))
      ))
    menu.addItem(.separator())

    let convertRoot = NSMenuItem(title: "Convert Anchor", action: nil, keyEquivalent: "")
    let convert = NSMenu(title: "Convert Anchor")
    convert.addItem(
      item("Corner", #selector(ProjectWindowController.convertAnchorToCorner(_:))))
    convert.addItem(
      item("Smooth", #selector(ProjectWindowController.convertAnchorToSmooth(_:))))
    convert.addItem(
      item("Symmetric", #selector(ProjectWindowController.convertAnchorToSymmetric(_:))))
    convertRoot.submenu = convert
    menu.addItem(convertRoot)

    // Arranging vector objects is also in the left tool settings, where it is
    // reachable mid-selection. These items add keyboard access and make the
    // commands discoverable where the other object commands live.
    let objectRoot = NSMenuItem(title: "Arrange Objects", action: nil, keyEquivalent: "")
    let object = NSMenu(title: "Arrange Objects")
    let front = item(
      "Bring to Front", #selector(ProjectWindowController.bringVectorObjectsToFront(_:)),
      key: "]")
    front.keyEquivalentModifierMask = [.command, .shift]
    object.addItem(front)
    let forward = item(
      "Bring Forward", #selector(ProjectWindowController.bringVectorObjectsForward(_:)),
      key: "]")
    object.addItem(forward)
    let backward = item(
      "Send Backward", #selector(ProjectWindowController.sendVectorObjectsBackward(_:)),
      key: "[")
    object.addItem(backward)
    let back = item(
      "Send to Back", #selector(ProjectWindowController.sendVectorObjectsToBack(_:)),
      key: "[")
    back.keyEquivalentModifierMask = [.command, .shift]
    object.addItem(back)
    object.addItem(.separator())
    object.addItem(
      item("Align Left", #selector(ProjectWindowController.alignVectorObjectsLeft(_:))))
    object.addItem(
      item(
        "Align Center",
        #selector(ProjectWindowController.alignVectorObjectsHorizontalCenter(_:))))
    object.addItem(
      item("Align Right", #selector(ProjectWindowController.alignVectorObjectsRight(_:))))
    object.addItem(
      item("Align Top", #selector(ProjectWindowController.alignVectorObjectsTop(_:))))
    object.addItem(
      item(
        "Align Middle",
        #selector(ProjectWindowController.alignVectorObjectsVerticalMiddle(_:))))
    object.addItem(
      item("Align Bottom", #selector(ProjectWindowController.alignVectorObjectsBottom(_:))))
    object.addItem(.separator())
    object.addItem(
      item(
        "Distribute Horizontally",
        #selector(ProjectWindowController.distributeVectorObjectsHorizontally(_:))))
    object.addItem(
      item(
        "Distribute Vertically",
        #selector(ProjectWindowController.distributeVectorObjectsVertically(_:))))
    object.addItem(.separator())
    object.addItem(
      item(
        "Reflect Horizontally",
        #selector(ProjectWindowController.reflectVectorObjectsHorizontally(_:))))
    object.addItem(
      item(
        "Reflect Vertically",
        #selector(ProjectWindowController.reflectVectorObjectsVertically(_:))))
    object.addItem(.separator())
    // No key equivalent: Shift-Command-D is already Select ▸ Reselect, and the
    // ordering commands are the ones that earn a shortcut here.
    object.addItem(
      item(
        "Duplicate in Place",
        #selector(ProjectWindowController.duplicateVectorObjectsInPlace(_:))))
    object.addItem(
      item(
        "Move Selection to New Vector Layer",
        #selector(ProjectWindowController.moveVectorObjectsToNewLayer(_:))))
    objectRoot.submenu = object
    menu.addItem(objectRoot)

    // Boolean operations are destructive and produce an editable compound path.
    // Release is the way back out, so it sits with them rather than elsewhere.
    let booleanRoot = NSMenuItem(title: "Combine Objects", action: nil, keyEquivalent: "")
    let boolean = NSMenu(title: "Combine Objects")
    boolean.addItem(
      item("Union", #selector(ProjectWindowController.unionVectorObjects(_:))))
    boolean.addItem(
      item("Subtract", #selector(ProjectWindowController.subtractVectorObjects(_:))))
    boolean.addItem(
      item("Intersect", #selector(ProjectWindowController.intersectVectorObjects(_:))))
    boolean.addItem(
      item("Exclude Overlap", #selector(ProjectWindowController.excludeVectorObjects(_:))))
    boolean.addItem(.separator())
    boolean.addItem(
      item(
        "Release Compound Path",
        #selector(ProjectWindowController.releaseCompoundPath(_:))))
    booleanRoot.submenu = boolean
    menu.addItem(booleanRoot)
    return root
  }

  /// Commands that act on the active selection.
  ///
  /// Select All deliberately shares `NSText.selectAll(_:)` and its ⌘A, so a
  /// text field still selects its own text while it has the keyboard and the
  /// canvas answers otherwise. Edit ▸ Select All and this item are the same
  /// command reaching different responders.
  private static func selectMenu() -> NSMenuItem {
    let root = NSMenuItem()
    let menu = NSMenu(title: "Select")
    root.submenu = menu

    menu.addItem(item("All", #selector(NSText.selectAll(_:)), key: "a"))
    menu.addItem(item("Deselect", #selector(ProjectWindowController.deselect(_:)), key: "d"))
    let reselect = item("Reselect", #selector(ProjectWindowController.reselect(_:)), key: "d")
    reselect.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(reselect)
    let invert = item("Inverse", #selector(ProjectWindowController.invertSelection(_:)), key: "i")
    invert.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(invert)
    menu.addItem(.separator())
    // The shared mask model is what makes this a copy rather than a conversion.
    menu.addItem(
      item(
        "Save Selection as Mask",
        #selector(ProjectWindowController.saveSelectionAsMask(_:))
      ))
    return root
  }

  private static func windowMenu() -> NSMenuItem {
    let root = NSMenuItem()
    let menu = NSMenu(title: "Window")
    root.submenu = menu
    menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
    menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
    menu.addItem(.separator())
    menu.addItem(
      item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
    NSApp.windowsMenu = menu
    return root
  }

  private static func item(
    _ title: String,
    _ action: Selector?,
    key: String = "",
    target: AnyObject? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = target
    return item
  }
}

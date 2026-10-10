import AppKit
import PixeltjeMacDomain
import SwiftUI
import Testing

@testable import PixeltjeMacKit

/// A color well is only honest if what it hands back is what it was given.
/// Both document color types go through a named color space, so a round trip
/// is a conversion there and back rather than the identity, and it is checked
/// at a tolerance a 16-bit component can hold.
private func expectClose(_ value: Double, _ expected: Double, _ label: String) {
  #expect(abs(value - expected) < 0.0005, "\(label): \(value) is not \(expected)")
}

@Test func vectorColorsSurviveARoundTripThroughTheColorPicker() {
  for color in [
    VectorColor.black,
    VectorColor.white,
    VectorColor(red: 0.82, green: 0.17, blue: 0.44, alpha: 0.6),
  ] {
    let returned = VectorColor(color.swiftUIColor)
    expectClose(returned.red, color.red, "red")
    expectClose(returned.green, color.green, "green")
    expectClose(returned.blue, color.blue, "blue")
    expectClose(returned.alpha, color.alpha, "alpha")
  }
}

@Test func paintColorsSurviveARoundTripThroughTheColorPicker() {
  for color in [
    LinearRGBAColor.black,
    LinearRGBAColor.white,
    LinearRGBAColor(red: 0.21, green: 0.66, blue: 0.09, alpha: 0.75),
  ] {
    let returned = LinearRGBAColor(color.swiftUIColor)
    expectClose(returned.red, color.red, "red")
    expectClose(returned.green, color.green, "green")
    expectClose(returned.blue, color.blue, "blue")
    expectClose(returned.alpha, color.alpha, "alpha")
  }
}

/// The two color types name different spaces, so a mid-tone must not survive
/// being read as the other one. This is what makes a single shared color type
/// the wrong simplification.
@Test func theLinearAndGammaColorSpacesAreNotInterchangeable() {
  let midGray = LinearRGBAColor(red: 0.5, green: 0.5, blue: 0.5)
  let asVector = VectorColor(midGray.swiftUIColor)
  #expect(asVector.red > 0.6)
}

@MainActor
@Test func theTextToolStyleSetsThePlacedLayerAndKeepsTheCanvasSizeUntilAsked() {
  let canvas = CanvasRecipe(width: 1_200, height: 1_200)
  let placed = TextLayer.placing("Text", in: canvas)

  var style = TextToolStyle()
  style.fontName = "Times New Roman"
  style.color = VectorColor(red: 1, green: 0.25, blue: 0, alpha: 1)
  style.alignment = .leading

  // No size chosen yet, so the canvas-derived size stands.
  #expect(style.resolvedFontSize(in: canvas) == placed.fontSize)
  let styled = style.applied(to: placed)
  #expect(styled.fontName == "Times New Roman")
  #expect(styled.color == style.color)
  #expect(styled.alignment == .leading)
  #expect(styled.fontSize == placed.fontSize)
  #expect(styled.frame == placed.frame)

  style.fontSize = 72
  #expect(style.resolvedFontSize(in: canvas) == 72)
  #expect(style.applied(to: placed).fontSize == 72)
}

@MainActor
@Test func theTextToolStyleIsToolStateAndNotUndoable() {
  let document = ProjectDocument()
  let baseline = document.editorModel.recipe
  let steps = document.editorModel.history.steps.count

  var style = document.editorModel.textToolStyle
  style.fontName = "Menlo"
  document.editorModel.setTextToolStyle(style)

  #expect(document.editorModel.textToolStyle.fontName == "Menlo")
  #expect(document.editorModel.recipe == baseline)
  #expect(document.editorModel.history.steps.count == steps)
}

@MainActor
@Test func onlyEditingToolsOpenTheLeftPanelToolSettings() {
  #expect(EditorTool.pen.hasToolSettings)
  #expect(EditorTool.text.hasToolSettings)
  #expect(!EditorTool.navigate.hasToolSettings)
  #expect(!EditorTool.move.hasToolSettings)
  #expect(!EditorTool.generate.hasToolSettings)
}

/// The masks tool used to own a permanent section of its own, which meant its
/// settings showed while another tool was active and choosing it opened no
/// panel. It goes through the tool settings slot like every other tool now.
@MainActor
@Test func theMasksToolSettingsBelongToTheToolSlotAndNotToASectionOfTheirOwn() {
  #expect(EditorTool.masks.hasToolSettings)

  let model = PanelModel()
  model.install(
    PanelSection(id: .toolSettings, title: "Tool Settings", order: PanelOrder.toolSettings) {
      EmptyView()
    }
  )
  #expect(!model.contains(PanelSectionID("masks")))
}

/// An absent `NSColorPanelMode` reads as 0, which is Gray Scale, so every
/// color well in a fresh install opened on a single-channel picker. A stored
/// Gray Scale is the same dead end reached the other way round, so both
/// resolve to the RGB sliders; every other remembered tab is the user's own
/// choice and survives untouched.
@Test func theColorPanelOpensOnRGBWheneverTheStoredPickerIsGrayScale() {
  #expect(ColorPanelPreferences.openingMode(storedMode: nil) == .RGB)
  #expect(ColorPanelPreferences.openingMode(storedMode: NSColorPanel.Mode.gray.rawValue) == .RGB)
  #expect(
    ColorPanelPreferences.openingMode(storedMode: NSColorPanel.Mode.none.rawValue) == .RGB)
  #expect(ColorPanelPreferences.openingMode(storedMode: 99) == .RGB)

  for mode: NSColorPanel.Mode in [.RGB, .CMYK, .HSB, .customPalette, .colorList, .wheel, .crayon] {
    #expect(ColorPanelPreferences.openingMode(storedMode: mode.rawValue) == mode)
  }
}

/// The panel registries answer three separate questions: what the tool is set
/// to, which RAW layer is being developed, and how the work is going. The left
/// panel holds only the first, so tool settings are never pushed down by a
/// record or a queue.
@MainActor
@Test func theRecordAndTheQueuesLiveInTheAssistancePanelNotTheLeftOne() {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  _ = controller.window

  #expect(controller.leftPanelModel.sections.map(\.id) == [.toolSettings])
  #expect(controller.developPanelModel.sections.map(\.id) == [.development])
  #expect(controller.assistancePanelModel.sections.map(\.id) == [.history, .snapshots, .exportQueue])
  // Each panel now holds only sections that belong to it, so nothing has to
  // start collapsed to keep something else in view.
  let sections = controller.leftPanelModel.sections + controller.developPanelModel.sections
    + controller.assistancePanelModel.sections
  #expect(sections.filter { !$0.startsExpanded }.isEmpty)
}

/// RAW development remains immediately left of the right-hand Layers panel,
/// while assistance stays outside both. The optional panels start collapsed so
/// a new window gives the canvas useful room.
@MainActor
@Test func theDevelopAndAssistancePanelsStartCollapsed() throws {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  let window = try #require(controller.window)
  window.layoutIfNeeded()
  let split = try #require(controller.contentViewController as? NSSplitViewController)
  let develop = split.splitViewItems[3]
  let rightPanel = split.splitViewItems[4]
  let assistance = try #require(split.splitViewItems.last)

  #expect(split.splitViewItems.count == 6)
  for item in [split.splitViewItems[1], develop, rightPanel, assistance] {
    #expect(item.collapseBehavior == .preferResizingSiblingsWithFixedSplitView)
  }
  #expect(develop.isCollapsed)
  #expect(develop.canCollapse)
  #expect(develop.minimumThickness == 300)
  #expect(assistance.isCollapsed)
  #expect(assistance.canCollapse)

  let developMenuItem = NSMenuItem(
    title: "Develop Panel",
    action: #selector(ProjectWindowController.toggleDevelopPanel(_:)),
    keyEquivalent: "3"
  )
  #expect(controller.validateMenuItem(developMenuItem))
  #expect(developMenuItem.state == .off)

  let menuItem = NSMenuItem(
    title: "Editing Assistance",
    action: #selector(ProjectWindowController.toggleAssistancePanel(_:)),
    keyEquivalent: "5"
  )
  #expect(controller.validateMenuItem(menuItem))
  #expect(menuItem.state == .off)
}

/// The Develop panel is a first-class document column, so its discoverable
/// header control sits directly left of the right-panel control, matching the
/// document columns.
@MainActor
@Test func theDevelopPanelHasAnAdjacentToolbarToggle() throws {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  let toolbar = NSToolbar(identifier: "DevelopPanelToolbarTest")
  let rightPanelID = NSToolbarItem.Identifier("PixeltjeMac.RightPanel")
  let developPanelID = NSToolbarItem.Identifier("PixeltjeMac.DevelopPanel")
  let identifiers = controller.toolbarDefaultItemIdentifiers(toolbar)
  let developPanelIndex = try #require(identifiers.firstIndex(of: developPanelID))

  #expect(identifiers.index(after: developPanelIndex) < identifiers.endIndex)
  #expect(identifiers[identifiers.index(after: developPanelIndex)] == rightPanelID)
  #expect(controller.toolbarAllowedItemIdentifiers(toolbar).contains(developPanelID))

  let item = try #require(
    controller.toolbar(
      toolbar,
      itemForItemIdentifier: developPanelID,
      willBeInsertedIntoToolbar: true
    )
  )
  #expect(item.label == "Develop Panel")
  #expect(item.paletteLabel == "Develop Panel")
  #expect(item.toolTip == "Show or hide develop panel (⌘3)")

  let container = try #require(item.view as? NSGlassEffectView)
  let button = try #require(container.contentView?.subviews.first as? NSButton)
  container.layoutSubtreeIfNeeded()
  #expect(button.toolTip == item.toolTip)
  #expect(button.frame == container.contentView?.bounds)
}

/// The left panel (tool settings) starts collapsed while the navigate tool is
/// selected at startup, rather than opening an empty placeholder pane.
@MainActor
@Test func theLeftPanelStartsCollapsedWhileTheNavigateToolIsSelected() throws {
  let document = ProjectDocument()
  let controller = ProjectWindowController(projectDocument: document)
  let window = try #require(controller.window)
  window.layoutIfNeeded()
  let split = try #require(controller.contentViewController as? NSSplitViewController)
  let leftPanel = try #require(split.splitViewItems.dropFirst().first)

  #expect(document.editorModel.activeTool == .navigate)
  #expect(leftPanel.isCollapsed)
  #expect(leftPanel.canCollapse)
  #expect(leftPanel.minimumThickness == 266)

  let menuItem = NSMenuItem(
    title: "Left Panel",
    action: #selector(ProjectWindowController.toggleLeftPanel(_:)),
    keyEquivalent: "1"
  )
  #expect(controller.validateMenuItem(menuItem))
  #expect(menuItem.state == .off)

  controller.activateBrushTool(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  #expect(!leftPanel.isCollapsed)
  #expect(leftPanel.viewController.view.frame.width == 266)
  #expect(controller.validateMenuItem(menuItem))
  #expect(menuItem.state == .on)
}

@MainActor
@Test func reselectingTheBrushByButtonOrShortcutTogglesItsPanel() throws {
  let document = ProjectDocument()
  let controller = ProjectWindowController(projectDocument: document)
  let window = try #require(controller.window)
  window.layoutIfNeeded()
  let split = try #require(controller.contentViewController as? NSSplitViewController)
  let leftPanel = split.splitViewItems[1]
  let toolbox = try #require(split.splitViewItems[0].viewController as? ToolboxViewController)
  let scrollView = try #require(toolbox.view.subviews.compactMap { $0 as? NSScrollView }.first)
  let stack = try #require(scrollView.documentView as? NSStackView)
  let brushTag = try #require(EditorTool.allCases.firstIndex(of: .brush))
  let brushButton = try #require(
    stack.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.tag == brushTag })

  brushButton.performClick(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  #expect(document.editorModel.activeTool == .brush)
  #expect(!leftPanel.isCollapsed)

  brushButton.performClick(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  #expect(document.editorModel.activeTool == .brush)
  #expect(leftPanel.isCollapsed)
  #expect(brushButton.state == .on)

  // The B shortcut and Brush menu command use this same action.
  controller.activateBrushTool(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  #expect(!leftPanel.isCollapsed)
  #expect(document.editorModel.activeTool == .brush)

  controller.activateBrushTool(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  #expect(leftPanel.isCollapsed)

  brushButton.performClick(nil)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  #expect(!leftPanel.isCollapsed)
  #expect(brushButton.state == .on)
}

@MainActor
@Test func theToolboxRemainsScrollableInAShortWindow() throws {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  let window = try #require(controller.window)
  window.setFrame(
    NSRect(x: window.frame.minX, y: window.frame.maxY - 600, width: window.frame.width, height: 600),
    display: false
  )
  window.layoutIfNeeded()

  let split = try #require(controller.contentViewController as? NSSplitViewController)
  let toolbox = try #require(split.splitViewItems[0].viewController as? ToolboxViewController)
  let scrollView = try #require(toolbox.view.subviews.compactMap { $0 as? NSScrollView }.first)
  let content = try #require(scrollView.documentView)

  #expect(scrollView.contentView.bounds.height > 0)
  #expect(content.frame.height > scrollView.contentView.bounds.height)
  #expect(scrollView.hasVerticalScroller)
}

/// A tall SwiftUI form belongs inside the Develop panel's scroll view. Its
/// ideal height must not become the document window's minimum height.
@MainActor
@Test func theDevelopPanelDoesNotPreventTheWindowFromShrinkingVertically() throws {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  let window = try #require(controller.window)
  window.layoutIfNeeded()

  window.setFrame(
    NSRect(x: window.frame.minX, y: window.frame.maxY - 700, width: window.frame.width, height: 700),
    display: false
  )
  window.layoutIfNeeded()
  #expect(window.frame.height == 700)

  window.setFrame(
    NSRect(x: window.frame.minX, y: window.frame.maxY - 600, width: window.frame.width, height: 600),
    display: false
  )
  window.layoutIfNeeded()

  #expect(window.frame.height == 600)
}

@MainActor
@Test func documentWindowStartsMaximized() throws {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  let window = try #require(controller.window)
  defer { window.orderOut(nil) }

  controller.showWindow(nil)
  #expect(window.isZoomed)
}

/// The Develop panel reads the layer-stack selection rather than retaining a
/// second SwiftUI selection that could name the wrong target. RAW, linked-image,
/// and paint layers are developable there; structural canvas state is not.
@MainActor
@Test func activeLayerTracksTheSelectionThatDrivesTheDevelopPanel() {
  let raw = ProjectLayer.rawBase()
  let image = ProjectLayer.image(
    ImageLayer(
      source: SourceReference(
        originalFilename: "Placed.tiff",
        linkedPath: "/tmp/Placed.tiff",
        securityScopedBookmark: nil,
        fingerprint: .init(byteLength: 0, modificationDate: nil)
      ),
      frame: LayerFrame(x: 0, y: 0, width: 100, height: 100),
      naturalWidth: 100,
      naturalHeight: 100
    )
  )
  let paint = ProjectLayer.paint(PaintLayerRecipe())
  var stack = LayerStackRecipe(layers: [paint, image, raw], activeLayerID: raw.id)
  let model = EditorModel(recipe: ProjectRecipe(layerStack: stack))

  #expect(model.activeLayer?.id == raw.id)
  #expect(model.activeLayer?.isDevelopedRaw == true)
  #expect(model.activeLayer?.supportsDevelopPanel == true)

  stack.activeLayerID = image.id
  model.updateRecipeInPlace(ProjectRecipe(layerStack: stack))
  #expect(model.activeLayer?.id == image.id)
  #expect(model.activeLayer?.isDevelopedRaw == false)
  #expect(model.activeLayer?.supportsDevelopPanel == true)

  stack.activeLayerID = paint.id
  model.updateRecipeInPlace(ProjectRecipe(layerStack: stack))
  #expect(model.activeLayer?.id == paint.id)
  #expect(model.activeLayer?.isPaintLayer == true)
  #expect(model.activeLayer?.supportsDevelopPanel == true)

  stack.activeLayerID = .canvas
  model.updateRecipeInPlace(ProjectRecipe(layerStack: stack))
  #expect(model.activeLayer?.id == .canvas)
  #expect(model.activeLayer?.supportsDevelopPanel == false)
}

/// The fullscreen preview shows `RenderedFrame.surface`, so on a document that
/// has never rendered there is nothing to show: F and the toolbar button stand
/// down rather than opening an empty black screen.
@MainActor
@Test func fullscreenPreviewIsUnavailableUntilSomethingHasBeenRendered() {
  let controller = ProjectWindowController(projectDocument: ProjectDocument())
  _ = controller.window

  let menuItem = NSMenuItem(
    title: "Fullscreen Preview",
    action: #selector(ProjectWindowController.toggleFullscreenPreview(_:)),
    keyEquivalent: "f"
  )
  #expect(!controller.validateMenuItem(menuItem))
  #expect(menuItem.state == .off)
}

@MainActor
@Test func vectorClipboardMenuValidationFollowsVectorObjectState() {
  VectorObjectClipboard.shared.clear()
  defer { VectorObjectClipboard.shared.clear() }

  let path = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.1, y: 0.1)),
      VectorAnchor(position: VectorPoint(x: 0.9, y: 0.9)),
    ],
    stroke: VectorStrokeStyle(color: .black, width: 2))
  let layer = ProjectLayer(
    name: "Vector Layer",
    content: .vector(VectorLayer(objects: [.path(path)])))
  var recipe = ProjectRecipe()
  recipe.layerStack = LayerStackRecipe(
    layers: [layer, .canvasBase(CanvasRecipe(width: 100, height: 100))],
    activeLayerID: layer.id)

  let document = ProjectDocument()
  document.editorModel.updateRecipeInPlace(recipe)
  document.editorModel.setActiveTool(.move)
  document.editorModel.setSelectedVectorObjects([path.id])
  let controller = ProjectWindowController(projectDocument: document)
  _ = controller.window

  let copyItem = NSMenuItem(
    title: "Copy", action: #selector(ProjectWindowController.copy(_:)), keyEquivalent: "c")
  let cutItem = NSMenuItem(
    title: "Cut", action: #selector(ProjectWindowController.cut(_:)), keyEquivalent: "x")
  let pasteItem = NSMenuItem(
    title: "Paste", action: #selector(ProjectWindowController.paste(_:)), keyEquivalent: "v")

  #expect(controller.validateMenuItem(copyItem))
  #expect(controller.validateMenuItem(cutItem))
  #expect(!controller.validateMenuItem(pasteItem))

  controller.copy(nil)
  #expect(controller.validateMenuItem(pasteItem))

  var lockedRecipe = document.editorModel.recipe
  lockedRecipe.layerStack.updateLayer(id: layer.id) { $0.isLocked = true }
  document.editorModel.updateRecipeInPlace(lockedRecipe)
  #expect(controller.validateMenuItem(copyItem))
  #expect(!controller.validateMenuItem(cutItem))
}

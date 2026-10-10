import AppKit
import Combine
import PixeltjeMacDomain

@MainActor
final class ToolboxViewController: NSViewController {
  private let model: EditorModel
  private let selectTool: (EditorTool) -> Void
  private let pickForegroundColor: () -> Void
  /// The wells here are the same two colors the tool panels show, so they go
  /// through the document for the same reason those do: a color set while a
  /// vector tool has objects selected recolors those objects.
  private let colorSend: (ColorWorkflowIntent) -> Void
  private var buttons: [EditorTool: NSButton] = [:]
  private let foregroundWell = NSColorWell()
  private let backgroundWell = NSColorWell()
  private let colorSampleButton = NSButton()
  private var subscriptions: Set<AnyCancellable> = []

  init(
    model: EditorModel,
    selectTool: @escaping (EditorTool) -> Void,
    pickForegroundColor: @escaping () -> Void,
    colorSend: @escaping (ColorWorkflowIntent) -> Void
  ) {
    self.model = model
    self.selectTool = selectTool
    self.pickForegroundColor = pickForegroundColor
    self.colorSend = colorSend
    super.init(nibName: nil, bundle: nil)

    model.$activeTool
      .receive(on: RunLoop.main)
      .sink { [weak self] tool in self?.updateSelection(tool) }
      .store(in: &subscriptions)
    model.$pendingSample
      .receive(on: RunLoop.main)
      .sink { [weak self] request in self?.updateColorSampleButton(request) }
      .store(in: &subscriptions)
    model.$colorTool
      .receive(on: RunLoop.main)
      .sink { [weak self] state in self?.updateColorWells(state) }
      .store(in: &subscriptions)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("ToolboxViewController is created programmatically")
  }

  override func loadView() {
    let background = NSVisualEffectView()
    background.material = .sidebar
    background.blendingMode = .behindWindow

    let stack = ToolboxStackView()
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)

    for tool in EditorTool.allCases {
      let button = ToolboxButton()
      button.setButtonType(.toggle)
      button.isBordered = false
      button.imagePosition = .imageOnly
      button.image = EditorToolIcon.image(for: tool)
      button.toolTip = tool.toolTip
      button.setAccessibilityLabel("\(tool.label) Tool")
      button.setAccessibilityHelp(button.toolTip)
      button.tag = EditorTool.allCases.firstIndex(of: tool) ?? 0
      button.target = self
      button.action = #selector(toolPressed(_:))
      button.widthAnchor.constraint(equalToConstant: 38).isActive = true
      button.heightAnchor.constraint(equalToConstant: 32).isActive = true
      buttons[tool] = button
      stack.addArrangedSubview(button)
    }

    let colorSeparator = NSBox()
    colorSeparator.boxType = .separator
    stack.addArrangedSubview(colorSeparator)
    colorSeparator.widthAnchor.constraint(equalToConstant: 26).isActive = true

    for (well, label) in [
      (foregroundWell, "Foreground color \u{2014} brush, type, flood fill, and vector stroke"),
      (backgroundWell, "Background color \u{2014} vector fill and the far end of a gradient"),
    ] {
      well.setAccessibilityLabel(label)
      well.toolTip = label
      well.target = self
      well.action = #selector(colorWellChanged(_:))
      well.widthAnchor.constraint(equalToConstant: 28).isActive = true
      well.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    let swapButton = smallButton(
      symbol: "arrow.triangle.2.circlepath",
      label: "Swap foreground and background colors (X)",
      action: #selector(swapColors(_:)),
      width: 14,
      height: 13)
    swapButton.isBordered = false
    swapButton.imageScaling = .scaleProportionallyDown
    swapButton.image = swapButton.image?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
    stack.addArrangedSubview(foregroundWell)
    stack.addArrangedSubview(swapButton)
    stack.addArrangedSubview(backgroundWell)
    stack.setCustomSpacing(2, after: foregroundWell)
    stack.setCustomSpacing(2, after: swapButton)
    let resetButton = smallButton(
      symbol: "arrow.counterclockwise",
      label: "Reset colors to black and white (D)",
      action: #selector(resetColors(_:)),
      width: 14,
      height: 13)
    resetButton.isBordered = false
    resetButton.imageScaling = .scaleProportionallyDown
    resetButton.image = resetButton.image?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
    stack.addArrangedSubview(resetButton)
    configureSmallButton(
      colorSampleButton,
      symbol: "eyedropper",
      label: "Sample foreground color",
      action: #selector(sampleForeground(_:)))
    colorSampleButton.setButtonType(.toggle)
    stack.addArrangedSubview(colorSampleButton)

    // The toolbox is wider than its buttons but taller than a short window.
    // Give the scroll view a content-sized document so the split view can
    // shrink without clipping the lower tools and color controls.
    stack.frame = NSRect(x: 0, y: 0, width: 48, height: ceil(stack.fittingSize.height))
    let scrollView = NSScrollView()
    scrollView.documentView = stack
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: background.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    view = background
    updateSelection(model.activeTool)
    updateColorSampleButton(model.pendingSample)
    updateColorWells(model.colorTool)
  }

  @objc private func toolPressed(_ sender: NSButton) {
    let cases = EditorTool.allCases
    guard cases.indices.contains(sender.tag) else { return }
    selectTool(cases[sender.tag])
    // A reselected tool stays highlighted while its settings panel toggles.
    updateSelection(model.activeTool)
  }

  @objc private func colorWellChanged(_ sender: NSColorWell) {
    let color = LinearRGBAColor(sender.color)
    colorSend(sender === foregroundWell ? .setForeground(color) : .setBackground(color))
  }

  @objc private func swapColors(_ sender: Any?) {
    colorSend(.swap)
  }

  @objc private func resetColors(_ sender: Any?) {
    colorSend(.reset)
  }

  @objc private func sampleForeground(_ sender: Any?) {
    pickForegroundColor()
  }

  private func smallButton(
    symbol: String,
    label: String,
    action: Selector,
    width: CGFloat = 28,
    height: CGFloat = 26
  ) -> NSButton {
    let button = NSButton()
    configureSmallButton(
      button, symbol: symbol, label: label, action: action, width: width, height: height)
    return button
  }

  private func configureSmallButton(
    _ button: NSButton,
    symbol: String,
    label: String,
    action: Selector,
    width: CGFloat = 28,
    height: CGFloat = 26
  ) {
    button.bezelStyle = .toolbar
    button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.target = self
    button.action = action
    button.widthAnchor.constraint(equalToConstant: width).isActive = true
    button.heightAnchor.constraint(equalToConstant: height).isActive = true
  }

  private func updateColorWells(_ state: ColorToolState) {
    guard isViewLoaded else { return }
    foregroundWell.color = state.foreground.nsColor
    backgroundWell.color = state.background.nsColor
    foregroundWell.setAccessibilityValue("Foreground")
    backgroundWell.setAccessibilityValue("Background")
  }

  private func updateSelection(_ selected: EditorTool) {
    for (tool, button) in buttons {
      button.state = tool == selected ? .on : .off
      button.contentTintColor = tool == selected ? .controlAccentColor : .labelColor
      button.setAccessibilityValue(tool == selected ? "Selected" : "Not selected")
    }
    // Shortcuts and menu commands can select a tool outside the visible part
    // of the strip. Reveal its button without changing the user's selection.
    if let button = buttons[selected] {
      button.superview?.layoutSubtreeIfNeeded()
      button.scrollToVisible(button.bounds)
    }
  }

  private func updateColorSampleButton(_ request: PixelSampleRequest?) {
    guard isViewLoaded else { return }
    let armed = request?.purpose == .foregroundColor
    colorSampleButton.state = armed ? .on : .off
    colorSampleButton.contentTintColor = armed ? .controlAccentColor : .labelColor
    colorSampleButton.setAccessibilityValue(armed ? "Picker armed" : "Picker not armed")
  }

}

private final class ToolboxStackView: NSStackView {
  override var isFlipped: Bool { true }
}

/// AppKit's toolbar bezel hugs an image-only button's icon even when Auto
/// Layout gives the control a larger frame. Draw the interaction surface
/// explicitly so the visible button fills its complete layout frame.
private final class ToolboxButton: NSButton {
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet {
      if isHovered != oldValue { needsDisplay = true }
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let hoverTrackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(hoverTrackingArea)
    self.hoverTrackingArea = hoverTrackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
  }

  override func draw(_ dirtyRect: NSRect) {
    let isPressed = cell?.isHighlighted == true
    if state == .on || isHovered || isPressed {
      let shape = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
        xRadius: 8.25,
        yRadius: 8.25)
      let color: NSColor
      if state == .on {
        color = .controlAccentColor.withAlphaComponent(isPressed ? 0.28 : 0.18)
      } else {
        color = .labelColor.withAlphaComponent(isPressed ? 0.14 : 0.08)
      }
      color.setFill()
      shape.fill()
      if state == .on {
        NSColor.controlAccentColor.setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
      }
    }
    super.draw(dirtyRect)
  }
}

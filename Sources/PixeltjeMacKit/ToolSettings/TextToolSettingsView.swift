import AppKit
import PixeltjeMacDomain
import SwiftUI

/// What the Text tool's settings ask for.
///
/// The panel edits two different things and says which: the tool's own style,
/// which is not undoable, and the selected text layer, which is.
enum TextToolIntent {
  case setStyle(TextToolStyle)
  case setTextLayer(ProjectLayerID, TextLayer, interactive: Bool)
  /// Opens and closes a drag, so a slider lands as one undoable step rather
  /// than one per tick. Same contract the right panel's sliders use.
  case beginGesture
  case endGesture(String)
}

/// The Text tool's settings, per the placement rule, in the left panel.
///
/// One panel covers both halves of the tool's job. With a text layer selected
/// it edits that layer, so the type on the canvas is changed where the tool
/// lives rather than in the layers inspector. With nothing selected it sets
/// what the next click will place. Style edits go to both, so the settings
/// carry over to the next text block instead of resetting.
struct TextToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let send: (TextToolIntent) -> Void
  let colorSend: (ColorWorkflowIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      ColorWorkflowView(
        model: model,
        send: colorSend,
        foregroundLabel: "Text",
        showsWells: false)
      Divider()
      if let layer = activeTextLayer {
        contentField(for: layer)
      }
      fontPicker
      sizeSlider
      alignmentPicker
      ColorPicker("Foreground", selection: colorBinding, supportsOpacity: true)
        .help("The window's foreground color. Type is set in it, and so is a brush stroke and a vector outline.")
      footnote
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: EditorTool.text.symbolName)
      Text(EditorTool.text.label)
        .font(.headline)
      Spacer()
    }
  }

  private func contentField(for layer: (id: ProjectLayerID, text: TextLayer)) -> some View {
    TextField(
      "Text",
      text: Binding(
        get: { layer.text.text },
        set: { value in
          var next = layer.text
          next.text = value
          send(.setTextLayer(layer.id, next, interactive: false))
        }
      ),
      axis: .vertical
    )
    .lineLimit(2...5)
    .textFieldStyle(.roundedBorder)
    .accessibilityLabel("Text contents")
  }

  private var fontPicker: some View {
    Picker("Font", selection: fontBinding) {
      ForEach(fontFamilies, id: \.self) { family in
        Text(family).tag(family)
      }
    }
    .pickerStyle(.menu)
  }

  private var sizeSlider: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Size")
        Spacer()
        Text(sizeLabel)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: sizeBinding, in: 4...512, onEditingChanged: sizeGestureChanged)
        .accessibilityLabel("Size")
        .accessibilityValue(sizeLabel)
    }
  }

  private var alignmentPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Alignment")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("Alignment", selection: alignmentBinding) {
        ForEach(TextLayerAlignment.allCases, id: \.self) { alignment in
          Text(alignment.label).tag(alignment)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  @ViewBuilder
  private var footnote: some View {
    if activeTextLayer == nil {
      Text("Click the canvas to place text with these settings.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    Text(
      "Text is set with Core Text at the render resolution and enters the linear working space "
        + "through a color-managed conversion, so a proxy render sets smaller type rather than "
        + "scaling a full-size raster."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The selected layer when it holds text, which is what decides whether this
  /// panel is editing a layer or only the tool's defaults.
  private var activeTextLayer: (id: ProjectLayerID, text: TextLayer)? {
    guard let id = model.recipe.layerStack.activeLayerID,
      let layer = model.recipe.layerStack.layer(id: id),
      case .text(let text) = layer.content
    else { return nil }
    return (id, text)
  }

  /// The installed font families, with the edited layer's own font kept in the
  /// list even when the machine no longer has it, so opening an old project
  /// never silently retargets the text to another face.
  private var fontFamilies: [String] {
    var families = NSFontManager.shared.availableFontFamilies
    let current = activeTextLayer?.text.fontName ?? model.textToolStyle.fontName
    if !families.contains(current) {
      families.insert(current, at: 0)
    }
    return families
  }

  private var sizeLabel: String {
    resolvedSize.formatted(.number.precision(.fractionLength(0))) + " px"
  }

  private var resolvedSize: Double {
    activeTextLayer?.text.fontSize
      ?? model.textToolStyle.resolvedFontSize(in: model.recipe.layerStack.canvas)
  }

  private var fontBinding: Binding<String> {
    Binding(
      get: { activeTextLayer?.text.fontName ?? model.textToolStyle.fontName },
      set: { name in
        apply(
          toStyle: { $0.fontName = name },
          toLayer: { $0.fontName = name }
        )
      }
    )
  }

  private var sizeBinding: Binding<Double> {
    Binding(
      get: { resolvedSize },
      set: { size in
        apply(
          toStyle: { $0.fontSize = size },
          toLayer: { $0.fontSize = size },
          interactive: true
        )
      }
    )
  }

  private var alignmentBinding: Binding<TextLayerAlignment> {
    Binding(
      get: { activeTextLayer?.text.alignment ?? model.textToolStyle.alignment },
      set: { alignment in
        apply(
          toStyle: { $0.alignment = alignment },
          toLayer: { $0.alignment = alignment }
        )
      }
    )
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { (activeTextLayer?.text.color ?? model.textToolStyle.color).swiftUIColor },
      set: { color in
        let picked = VectorColor(color)
        apply(
          toStyle: { $0.color = picked },
          toLayer: { $0.color = picked }
        )
      }
    )
  }

  /// A size drag is one step, not one per tick. Nothing happens when there is
  /// no layer to edit: the tool's own style is not undoable, so it needs no
  /// gesture around it.
  private func sizeGestureChanged(_ editing: Bool) {
    guard activeTextLayer != nil else { return }
    send(editing ? .beginGesture : .endGesture("Change Text Size"))
  }

  /// Every style change lands on the tool, and on the selected layer when
  /// there is one, so the next text block is set the way the last one was.
  private func apply(
    toStyle changeStyle: (inout TextToolStyle) -> Void,
    toLayer changeLayer: (inout TextLayer) -> Void,
    interactive: Bool = false
  ) {
    var style = model.textToolStyle
    changeStyle(&style)
    send(.setStyle(style))

    guard let layer = activeTextLayer else { return }
    var next = layer.text
    changeLayer(&next)
    send(.setTextLayer(layer.id, next, interactive: interactive))
  }
}

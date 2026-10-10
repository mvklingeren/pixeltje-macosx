import PixeltjeMacDomain
import SwiftUI

/// The one left-panel slot reserved for whichever tool is active.
struct ToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let cropSend: (CropToolIntent) -> Void
  let selectionSend: (SelectionIntent) -> Void
  let transformSend: (TransformToolIntent) -> Void
  let colorSend: (ColorWorkflowIntent) -> Void
  let vectorSend: (VectorToolIntent) -> Void
  let penSend: (PenToolIntent) -> Void
  let shapeSend: (ShapeToolIntent) -> Void
  let textSend: (TextToolIntent) -> Void
  let maskSend: (MaskIntent) -> Void

  @ViewBuilder
  var body: some View {
    switch model.activeTool {
    case .crop:
      CropToolSettingsView(model: model, send: cropSend)
    case .transform:
      TransformToolSettingsView(model: model, send: transformSend)
    case .brush, .eraser:
      BrushToolSettingsView(model: model, colorSend: colorSend)
    case .heal:
      HealToolSettingsView(model: model)
    case .marquee, .lasso:
      SelectionToolSettingsView(model: model, send: selectionSend)
    case .magnetSelection:
      MagnetSelectionToolSettingsView(model: model, send: selectionSend)
    case .selectionBrush:
      SelectionBrushToolSettingsView(model: model, send: selectionSend)
    case .pen:
      PenToolSettingsView(
        model: model, send: penSend, vectorSend: vectorSend, colorSend: colorSend)
    case .shape:
      ShapeToolSettingsView(
        model: model, send: shapeSend, vectorSend: vectorSend, colorSend: colorSend)
    case .gradient:
      GradientToolSettingsView(model: model, colorSend: colorSend)
    case .fill:
      FillToolSettingsView(model: model, colorSend: colorSend)
    case .text:
      TextToolSettingsView(model: model, send: textSend, colorSend: colorSend)
    case .masks:
      MaskToolPanelView(model: model, send: maskSend)
    case .navigate, .move, .generate:
      Text("Choose a tool with settings to edit its controls here.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
    }
  }
}

struct GenerationOptionsView: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.comfyUIGenerationMode == .inpainting {
        Picker(
          "Mask source",
          selection: Binding(
            get: { model.generationMaskSource },
            set: { model.setGenerationMaskSource($0) })
        ) {
          ForEach(model.generationMaskSourceOptions) { option in
            Text(option.label)
              .tag(option.source)
              .disabled(!option.isAvailable)
          }
        }
        .pickerStyle(.menu)
        .help(model.generationMaskSourcePresentation.help)
        .accessibilityIdentifier("generationOptions.maskSource")

        if ComfyUIWorkflowCatalog.address(
          for: .strength, templateID: model.selectedComfyUIWorkflowID) != nil
        {
          LabeledContent("Strength") {
            Slider(
              value: binding(\.strength),
              in: 0...1
            )
            .frame(width: 130)
          }
        }
        LabeledContent("Mask blur") {
          HStack {
            Slider(value: binding(\.maskBlur), in: 0...64)
            Text("\(model.inpaintingTool.maskBlur, specifier: "%.0f") px")
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
          .frame(width: 190)
        }
      }
      if model.comfyUIGenerationMode != .selection {
        Stepper("Steps: \(model.inpaintingTool.steps)", value: binding(\.steps), in: 1...20)
        LabeledContent("Guidance") {
          Slider(value: binding(\.guidance), in: 0...8)
            .frame(width: 130)
        }
        LabeledContent("Seed") {
          HStack {
            TextField("Seed", value: seedBinding, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 120)
            Toggle("Random", isOn: binding(\.randomizeSeed))
              .toggleStyle(.checkbox)
          }
        }
      }
      if model.comfyUIGenerationMode != .textToImage {
        Picker(
          "Transparent base",
          selection: binding(\.transparentPixelBackground)
        ) {
          ForEach(GenerationBackground.allCases, id: \.self) { background in
            Text(background.label).tag(background)
          }
        }
        .pickerStyle(.menu)
        .help("The color supplied to ComfyUI behind transparent source pixels.")
      }
      if ComfyUIWorkflowCatalog.address(
        for: .negativePrompt, templateID: model.selectedComfyUIWorkflowID) != nil
      {
        TextField("Negative prompt", text: binding(\.negativePrompt))
          .textFieldStyle(.roundedBorder)
      }
    }
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<InpaintingToolState, Value>)
    -> Binding<Value>
  {
    Binding(
      get: { model.inpaintingTool[keyPath: keyPath] },
      set: { value in
        var next = model.inpaintingTool
        next[keyPath: keyPath] = value
        model.setInpaintingTool(next)
      })
  }

  private var seedBinding: Binding<UInt64> {
    Binding(
      get: { model.inpaintingTool.seed },
      set: { seed in
        var next = model.inpaintingTool
        next.seed = seed
        next.randomizeSeed = false
        model.setInpaintingTool(next)
      })
  }
}

struct BrushToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let colorSend: (ColorWorkflowIntent) -> Void
  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias ExpandedState = SwiftUI.State<Set<String>>
  @ExpandedState private var expandedCategories: Set<String> = [BrushCategory.painting.rawValue]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(
        model.activeTool == .eraser ? "Eraser" : "Brush",
        systemImage: model.activeTool == .eraser ? "eraser" : "paintbrush.pointed"
      )
      .font(.headline)

      HStack(spacing: 6) {
        Text(BrushCatalog.preset(model.activeBrushPresetID).name)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        if model.activeBrushIsModified {
          Text("Modified")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Modified from the preset defaults")
        }
      }

      // The eraser removes coverage rather than laying down a color, so a
      // color well there would promise something the stroke does not do.
      if model.activeTool == .brush {
        ColorWorkflowView(model: model, send: colorSend, foregroundLabel: "Paint")
        Divider()
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Brushes")
          .font(.subheadline.weight(.semibold))
        ForEach(BrushCategory.allCases, id: \.rawValue) { category in
          let presets = BrushCatalog.presets(in: category)
          DisclosureGroup(
            isExpanded: Binding(
              get: { expandedCategories.contains(category.rawValue) },
              set: { expanded in
                if expanded { expandedCategories.insert(category.rawValue) }
                else { expandedCategories.remove(category.rawValue) }
              }
            )
          ) {
            VStack(spacing: 2) {
              ForEach(presets, id: \.id) { preset in
                Button { model.selectBrushPreset(preset.id) } label: {
                  HStack(spacing: 8) {
                    BrushPresetSwatch(image: model.brushPresetPreviews[preset.id])
                      .frame(width: 46, height: 18)
                    Text(preset.name)
                    Spacer(minLength: 0)
                    if model.activeBrushPresetID == preset.id {
                      Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                    }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(model.activeBrushPresetID == preset.id ? .isSelected : [])
              }
            }
            .padding(.leading, 4)
          } label: {
            Text(category.label)
              .font(.subheadline)
          }
        }
      }

      control("Size", value: binding(\.size), range: 0.25...2_048, suffix: "px", decimals: 1)
      if model.activeBrushDefinition.tipShape != .roundedRectangle {
        control("Hardness", value: binding(\.hardness), range: 0...1, suffix: "%")
      }
      control("Opacity", value: binding(\.opacity), range: 0...1, suffix: "%")
      control("Flow", value: binding(\.flow), range: 0...1, suffix: "%")
      control(
        "Pressure response",
        value: binding(\.pressureResponse),
        range: 0...1,
        suffix: "%"
      )

      Text(
        model.activeTool == .eraser
          ? "Pressure changes the eraser diameter and coverage. A mouse uses full pressure."
          : "Pressure changes brush diameter and coverage. A mouse uses full pressure."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Button(model.activeTool == .eraser ? "Reset Eraser" : "Reset Brush") {
        model.resetActiveBrush()
      }
      .disabled(!model.activeBrushIsModified)
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func control(
    _ label: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    suffix: String,
    decimals: Int = 0
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
        Spacer()
        Text(formatted(value.wrappedValue, suffix: suffix, decimals: decimals))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
        .accessibilityLabel(label)
        .accessibilityValue(formatted(value.wrappedValue, suffix: suffix, decimals: decimals))
    }
  }

  private func binding(_ keyPath: WritableKeyPath<BrushSettings, Double>) -> Binding<Double> {
    Binding(
      get: { model.activeBrushSettings[keyPath: keyPath] },
      set: { value in
        var settings = model.activeBrushSettings
        settings[keyPath: keyPath] = value
        model.setBrushSettings(settings)
      }
    )
  }

  private func formatted(_ value: Double, suffix: String, decimals: Int) -> String {
    let displayed = suffix == "%" ? value * 100 : value
    return displayed.formatted(.number.precision(.fractionLength(decimals))) + suffix
  }
}

/// Shows a stroke the render engine drew. A row stays usable before its
/// preview arrives or if one fails, because the name is what identifies a
/// brush and the preview only supplements it.
private struct BrushPresetSwatch: View {
  let image: CGImage?

  var body: some View {
    ZStack {
      // One dark neutral ground keeps yellow, pastel, grain and translucent
      // washes readable in both system appearances.
      RoundedRectangle(cornerRadius: 3)
        .fill(Color(.displayP3, red: 0.14, green: 0.15, blue: 0.17))
      if let image {
        Image(decorative: image, scale: 1)
          .renderingMode(.original)
          .resizable()
          .aspectRatio(contentMode: .fit)
      }
    }
    .accessibilityHidden(true)
  }
}

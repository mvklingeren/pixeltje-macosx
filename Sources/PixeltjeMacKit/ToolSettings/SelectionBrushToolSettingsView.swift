import PixeltjeMacDomain
import SwiftUI

/// Controls for literal painted selection coverage and edge-aware Quick Select
/// hints. Both modes capture the same high-fidelity pointer stroke; only what
/// the document makes from it on release differs.
struct SelectionBrushToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let send: (SelectionIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(EditorTool.selectionBrush.label, systemImage: EditorTool.selectionBrush.symbolName)
        .font(.headline)

      Picker("Brush Mode", selection: binding(\.mode)) {
        ForEach(SelectionBrushMode.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      SelectionCombinePicker(
        combine: model.selectionBrushTool.combine,
        gestureHelp: "Hold Shift while painting to add, Option to subtract, or both to intersect."
      ) { operation in
        var state = model.selectionBrushTool
        state.combine = operation
        send(.setSelectionBrushTool(state))
      }

      brushSlider("Size", path: \.size, range: 0.25...2_048, suffix: " px", decimals: 1)

      switch model.selectionBrushTool.mode {
      case .paint:
        brushSlider("Hardness", path: \.hardness, range: 0...1, percentage: true)
        brushSlider("Opacity", path: \.opacity, range: 0...1, percentage: true)
        brushSlider("Flow", path: \.flow, range: 0...1, percentage: true)
        brushSlider(
          "Pressure response", path: \.pressureResponse, range: 0...1,
          percentage: true)
        Text("Paint selection coverage directly. Tablet pressure changes diameter and coverage.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      case .quickSelect:
        Picker("Sample", selection: binding(\.sampleSource)) {
          ForEach(FillSampleSource.allCases, id: \.self) { source in
            Text(source.label).tag(source)
          }
        }
        statePercentageSlider("Tolerance", path: \.tolerance)
        statePercentageSlider("Edge Sensitivity", path: \.edgeSensitivity)
        statePercentageSlider("Smoothness", path: \.smoothness)
        Text(
          "Paint over the subject. Quick Select expands from those hints through similar connected pixels and stops at strong edges."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      SelectionFeatherSlider(feather: model.selectionBrushTool.feather) { value in
        var state = model.selectionBrushTool
        state.feather = value
        send(.setSelectionBrushTool(state))
      }

      CurrentSelectionControls(
        selection: model.recipe.selection,
        emptyMessage: model.selectionBrushTool.mode == .paint
          ? "No selection. Paint on the canvas to create one."
          : "No selection. Paint over the subject to analyse it.",
        send: send
      )
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func binding<Value>(
    _ path: WritableKeyPath<SelectionBrushToolState, Value>
  ) -> Binding<Value> {
    Binding(
      get: { model.selectionBrushTool[keyPath: path] },
      set: { value in
        var state = model.selectionBrushTool
        state[keyPath: path] = value
        send(.setSelectionBrushTool(state))
      })
  }

  private func brushSlider(
    _ title: String,
    path: WritableKeyPath<BrushSettings, Double>,
    range: ClosedRange<Double>,
    suffix: String = "",
    decimals: Int = 0,
    percentage: Bool = false
  ) -> some View {
    let value = model.selectionBrushTool.brushSettings[keyPath: path]
    let shown = percentage ? value * 100 : value
    let label = shown.formatted(.number.precision(.fractionLength(decimals)))
      + (percentage ? "%" : suffix)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(label).monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(
        value: Binding(
          get: { model.selectionBrushTool.brushSettings[keyPath: path] },
          set: { value in
            var state = model.selectionBrushTool
            state.brushSettings[keyPath: path] = value
            send(.setSelectionBrushTool(state))
          }),
        in: range
      )
      .accessibilityLabel(title)
      .accessibilityValue(label)
    }
  }

  private func statePercentageSlider(
    _ title: String,
    path: WritableKeyPath<SelectionBrushToolState, Double>
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(
          model.selectionBrushTool[keyPath: path]
            .formatted(.percent.precision(.fractionLength(0)))
        )
        .monospacedDigit()
        .foregroundStyle(.secondary)
      }
      Slider(value: binding(path), in: 0...1)
        .accessibilityLabel(title)
    }
  }
}

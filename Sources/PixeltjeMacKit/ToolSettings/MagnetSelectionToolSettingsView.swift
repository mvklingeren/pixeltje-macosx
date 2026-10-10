import PixeltjeMacDomain
import SwiftUI

/// Controls for the click-driven selection tool. Both modes sample one canvas
/// pixel; Contiguous follows connected neighbours while Color Range gathers
/// matching pixels across the complete sample source.
struct MagnetSelectionToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let send: (SelectionIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        Image(nsImage: EditorToolIcon.image(for: .magnetSelection))
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
        Text(EditorTool.magnetSelection.label)
          .font(.headline)
      }

      Picker("Selection", selection: binding(\.mode)) {
        ForEach(MagnetSelectionMode.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      Picker("Sample", selection: binding(\.sampleSource)) {
        ForEach(FillSampleSource.allCases, id: \.self) { source in
          Text(source.label).tag(source)
        }
      }

      SelectionCombinePicker(
        combine: model.magnetSelectionTool.combine,
        gestureHelp: "Hold Shift while clicking to add, Option to subtract, or both to intersect."
      ) { operation in
        var state = model.magnetSelectionTool
        state.combine = operation
        send(.setMagnetSelectionTool(state))
      }
      percentageSlider("Tolerance", path: \.tolerance)
      percentageSlider("Smoothness", path: \.smoothness)
      SelectionFeatherSlider(feather: model.magnetSelectionTool.feather) { value in
        var state = model.magnetSelectionTool
        state.feather = value
        send(.setMagnetSelectionTool(state))
      }

      Text(modeHelp)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text("The clicked image pixel is the reference color; the foreground color is not used.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      CurrentSelectionControls(
        selection: model.recipe.selection,
        emptyMessage: "No selection. Click the canvas to sample a color.",
        send: send
      )
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func percentageSlider(
    _ title: String,
    path: WritableKeyPath<MagnetSelectionToolState, Double>
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(
          model.magnetSelectionTool[keyPath: path]
            .formatted(.percent.precision(.fractionLength(0)))
        )
        .monospacedDigit()
        .foregroundStyle(.secondary)
      }
      Slider(value: binding(path), in: 0...1)
        .accessibilityLabel(title)
    }
  }

  private var modeHelp: String {
    switch model.magnetSelectionTool.mode {
    case .contiguous:
      "Click a connected region of similar color. Smoothness softens membership near the tolerance limit."
    case .colorRange:
      "Click a color to select matching pixels throughout the image, including disconnected areas."
    }
  }

  private func binding<Value>(
    _ path: WritableKeyPath<MagnetSelectionToolState, Value>
  ) -> Binding<Value> {
    Binding(
      get: { model.magnetSelectionTool[keyPath: path] },
      set: { value in
        var state = model.magnetSelectionTool
        state[keyPath: path] = value
        send(.setMagnetSelectionTool(state))
      })
  }

}

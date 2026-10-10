import PixeltjeMacDomain
import SwiftUI

enum PenToolIntent {
  case setEditMode(VectorEditMode)
}

/// The Pen tool contributes path-specific interaction controls, then uses the
/// same appearance and object controls as every other vector creator.
struct PenToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let send: (PenToolIntent) -> Void
  let vectorSend: (VectorToolIntent) -> Void
  let colorSend: (ColorWorkflowIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(EditorTool.pen.label, systemImage: EditorTool.pen.symbolName)
        .font(.headline)

      modePicker

      Divider()

      VectorToolControlsView(
        model: model,
        nextObject: .path,
        send: vectorSend,
        colorSend: colorSend)
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Drawing and anchor editing are the two Pen modes. Select/Move (V) handles
  /// whole paths and shapes without adding another selector inside the Pen.
  private var modePicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker("Mode", selection: modeBinding) {
        ForEach(VectorEditMode.allCases, id: \.self) { mode in
          Label(mode.label, systemImage: mode.symbolName).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Vector editing mode")
      Text(model.vectorEditMode.help)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var modeBinding: Binding<VectorEditMode> {
    Binding(get: { model.vectorEditMode }, set: { send(.setEditMode($0)) })
  }
}

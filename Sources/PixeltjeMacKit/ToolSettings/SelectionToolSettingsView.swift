import PixeltjeMacDomain
import SwiftUI

/// What the selection surfaces ask for. Views state the intent; the window
/// controller routes it to the document or to the editor model.
enum SelectionIntent {
  /// Replaces the selection tools' settings. Tool state, not document state.
  case setSelectionTool(SelectionToolState)
  /// Replaces the color-driven selection tool's window-local settings.
  case setMagnetSelectionTool(MagnetSelectionToolState)
  /// Replaces the Selection Brush's window-local settings.
  case setSelectionBrushTool(SelectionBrushToolState)
  /// Flips the active document selection as one named, undoable step.
  case invertSelection
  /// Replaces the active selection as one named, undoable step.
  case setSelection(MaskRecipe?, actionName: String)
}

/// The document-selection status and commands shared by every selection tool.
///
/// Keeping these commands outside any one tool's settings makes them ready for
/// the combined selection-tool panel without putting document state into either
/// tool's window-local configuration.
struct CurrentSelectionControls: View {
  let selection: MaskRecipe?
  let emptyMessage: String
  let send: (SelectionIntent) -> Void

  var body: some View {
    Divider()
    if let selection {
      VStack(alignment: .leading, spacing: 6) {
        Text(selection.selectsNothing ? "Nothing selected" : selection.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button("Inverse Selection") {
            send(.invertSelection)
          }
          Button("Deselect") {
            send(.setSelection(nil, actionName: "Deselect"))
          }
        }
        .controlSize(.small)
      }
    } else {
      Text(emptyMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// New/Add/Subtract/Intersect shared by every selection-producing tool.
struct SelectionCombinePicker: View {
  let combine: MaskCombineOperation?
  let gestureHelp: String
  let onChange: (MaskCombineOperation?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Mode")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker(
        "Mode",
        selection: Binding(
          get: { combine?.rawValue ?? SelectionToolState.newSelectionTag },
          set: { onChange(MaskCombineOperation(rawValue: $0)) }
        )
      ) {
        Label("New", systemImage: "square.dashed")
          .tag(SelectionToolState.newSelectionTag)
        ForEach(MaskCombineOperation.allCases, id: \.self) { operation in
          Label(operation.label, systemImage: operation.symbolName).tag(operation.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Text(gestureHelp)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Component-level edge softening shared by the selection tools.
struct SelectionFeatherSlider: View {
  let feather: Double
  let onChange: (Double) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Feather")
        Spacer()
        Text(feather.formatted(.number.precision(.fractionLength(0))) + " px")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(
        value: Binding(get: { feather }, set: { value in onChange(value) }),
        in: 0...250
      )
      .accessibilityLabel("Feather")
      .accessibilityValue(
        feather.formatted(.number.precision(.fractionLength(0))) + " px")
    }
  }
}

/// The marquee and lasso settings, per the placement rule, in the left panel.
///
/// Both tools share this panel because they differ only in the geometry their
/// gesture produces: how a gesture joins what is already selected, and how soft
/// its edge is, mean the same thing for either one.
struct SelectionToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let send: (SelectionIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if model.activeTool == .marquee {
        shapePicker
      } else {
        Text("Drag to draw a freehand outline. It closes itself when you let go.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      SelectionCombinePicker(
        combine: model.selectionTool.combine,
        gestureHelp: "Hold Shift while dragging to add, Option to subtract, or both to intersect."
      ) { operation in
        var state = model.selectionTool
        state.combine = operation
        send(.setSelectionTool(state))
      }
      SelectionFeatherSlider(feather: model.selectionTool.feather) { value in
        var state = model.selectionTool
        state.feather = value
        send(.setSelectionTool(state))
      }
      if isRoundable {
        cornerRadiusSlider
      }
      CurrentSelectionControls(
        selection: model.recipe.selection,
        emptyMessage: "No selection. Editing affects the whole canvas.",
        send: send
      )
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: model.activeTool.symbolName)
      Text(model.activeTool.label)
        .font(.headline)
      Spacer()
    }
  }

  private var shapePicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Shape")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("Shape", selection: shapeBinding) {
        ForEach(SelectionToolState.Shape.allCases, id: \.self) { shape in
          Label(shape.label, systemImage: shape.symbolName).tag(shape)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  /// Only a rectangle has corners to round. The lasso draws a polygon and the
  /// ellipse is already all curve, so neither offers the control.
  private var isRoundable: Bool {
    model.activeTool == .marquee && model.selectionTool.shape == .rectangle
  }

  private var cornerRadiusSlider: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Corner Radius")
        Spacer()
        Text(cornerRadiusLabel)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: cornerRadiusBinding, in: 0...512)
        .accessibilityLabel("Corner Radius")
        .accessibilityValue(cornerRadiusLabel)
    }
  }

  private var cornerRadiusLabel: String {
    model.selectionTool.cornerRadius.formatted(.number.precision(.fractionLength(0))) + " px"
  }

  private var shapeBinding: Binding<SelectionToolState.Shape> {
    Binding(
      get: { model.selectionTool.shape },
      set: { shape in
        var state = model.selectionTool
        state.shape = shape
        send(.setSelectionTool(state))
      }
    )
  }

  private var cornerRadiusBinding: Binding<Double> {
    Binding(
      get: { model.selectionTool.cornerRadius },
      set: { value in
        var state = model.selectionTool
        state.cornerRadius = value
        send(.setSelectionTool(state))
      }
    )
  }
}

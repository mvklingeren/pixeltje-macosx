import PixeltjeMacDomain
import SwiftUI

enum ShapeToolIntent {
  case setState(ShapeToolState)
}

/// The gradient a drag lays down runs from the shared foreground to the shared
/// background, so this panel shows that one pair under the names its two ends
/// go by here rather than carrying two more colors of its own.
struct GradientToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let colorSend: (ColorWorkflowIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Gradient", systemImage: EditorTool.gradient.symbolName).font(.headline)
      Picker("Mode", selection: binding(\.kind)) {
        ForEach(PaintGradientKind.allCases, id: \.self) { Text($0.label).tag($0) }
      }.pickerStyle(.segmented)
      ColorWorkflowView(
        model: model,
        send: colorSend,
        foregroundLabel: "Start",
        backgroundLabel: "End")
      Text("Drag the two canvas handles to set direction and length. Colors interpolate in linear Display P3 and stop at the end handles.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
  }

  private func binding<Value>(_ path: WritableKeyPath<GradientToolState, Value>) -> Binding<Value> {
    Binding(get: { model.gradientTool[keyPath: path] }, set: { value in
      var next = model.gradientTool; next[keyPath: path] = value; model.setGradientTool(next)
    })
  }
}

/// A flood fill lays down the shared foreground, the same color the brush
/// paints with, so the panel shows that control rather than a color of its own.
struct FillToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let colorSend: (ColorWorkflowIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Fill", systemImage: EditorTool.fill.symbolName).font(.headline)
      Picker("Region", selection: binding(\.mode)) {
        ForEach(FillRegionMode.allCases, id: \.self) { Text($0.label).tag($0) }
      }.pickerStyle(.segmented)
      ColorWorkflowView(model: model, send: colorSend, foregroundLabel: "Fill")
      if model.fillTool.mode == .contiguous {
        Picker("Sample", selection: binding(\.sampleSource)) {
          ForEach(FillSampleSource.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Tolerance")
            Spacer()
            Text(model.fillTool.tolerance.formatted(.percent.precision(.fractionLength(0))))
              .monospacedDigit().foregroundStyle(.secondary)
          }
          Slider(value: binding(\.tolerance), in: 0...1)
        }
        Text("Click a connected area. The captured region is saved with the fill, so later edits do not change its boundary.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        Text(
          model.recipe.selection == nil
            ? "No selection: the complete canvas will be filled."
            : "The current selection is captured with this fill.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
  }

  private func binding<Value>(_ path: WritableKeyPath<FillToolState, Value>) -> Binding<Value> {
    Binding(get: { model.fillTool[keyPath: path] }, set: { value in
      var next = model.fillTool; next[keyPath: path] = value; model.setFillTool(next)
    })
  }
}

/// Shape contributes only its parametric creation controls. Appearance and
/// object operations are the same controls Pen uses, backed by the same state.
struct ShapeToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let send: (ShapeToolIntent) -> Void
  let vectorSend: (VectorToolIntent) -> Void
  let colorSend: (ColorWorkflowIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(EditorTool.shape.label, systemImage: EditorTool.shape.symbolName)
        .font(.headline)

      Picker("Shape", selection: binding(\.kind)) {
        ForEach(ShapeToolState.Kind.allCases, id: \.self) { kind in
          Text(kind.label).tag(kind)
        }
      }

      if model.shapeTool.kind == .rectangle {
        cornerRadiusSlider
      }
      if model.shapeTool.kind == .polygon {
        Stepper(
          "Sides: \(model.shapeTool.polygonSides)",
          value: binding(\.polygonSides),
          in: VectorShapeKind.minimumSides...VectorShapeKind.maximumSides)
      }
      if model.shapeTool.kind == .star {
        Stepper(
          "Points: \(model.shapeTool.starPoints)",
          value: binding(\.starPoints),
          in: VectorShapeKind.minimumSides...VectorShapeKind.maximumSides)
        innerRadiusSlider
      }

      numeric(
        "Rotation", value: binding(\.rotationDegrees), range: -360...360, suffix: "°")
      Toggle("Draw from center", isOn: binding(\.drawsFromCenter))
        .help("Option inverts this for one drag.")

      Text("These geometry controls describe the next shape. Existing shape geometry remains editable in the Layers inspector. Shift keeps width and height equal on screen, and Option draws from the center.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      VectorToolControlsView(
        model: model,
        nextObject: .shape(isClosed: model.shapeTool.kind != .line),
        send: vectorSend,
        colorSend: colorSend)
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var cornerRadiusSlider: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("Corner radius").font(.caption)
        Spacer()
        Text(percentage(model.shapeTool.cornerRadius))
          .font(.caption).monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(value: binding(\.cornerRadius), in: 0...0.5)
        .accessibilityLabel("Corner radius")
        .accessibilityValue(percentage(model.shapeTool.cornerRadius))
    }
  }

  private var innerRadiusSlider: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("Inner radius").font(.caption)
        Spacer()
        Text(percentage(model.shapeTool.starInnerRatio))
          .font(.caption).monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(value: binding(\.starInnerRatio), in: 0.05...0.95)
        .accessibilityLabel("Star inner radius")
        .accessibilityValue(percentage(model.shapeTool.starInnerRatio))
    }
  }

  private func percentage(_ value: Double) -> String {
    (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
  }

  private func numeric(
    _ label: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    suffix: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
        Spacer()
        Text(
          value.wrappedValue.formatted(.number.precision(.fractionLength(1))) + suffix)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
    }
  }

  private func binding<Value>(_ path: WritableKeyPath<ShapeToolState, Value>) -> Binding<Value> {
    Binding(get: { model.shapeTool[keyPath: path] }, set: { value in
      var next = model.shapeTool
      next[keyPath: path] = value
      send(.setState(next))
    })
  }
}

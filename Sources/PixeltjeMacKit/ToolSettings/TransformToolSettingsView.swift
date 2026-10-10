import PixeltjeMacDomain
import SwiftUI

enum TransformToolIntent {
  case begin
  case update(LayerTransform)
  case commit
  case cancel
}

struct TransformToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let send: (TransformToolIntent) -> Void
  @FocusState private var focusedField: TransformField?
  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias BoolState = SwiftUI.State<Bool>
  @BoolState private var constrainsScale = true

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Free Transform", systemImage: "arrow.up.left.and.arrow.down.right")
        .font(.headline)
      if let draft = model.transformDraft {
        fields(draft.transform)
        HStack {
          Button("Cancel") { send(.cancel) }
          Spacer()
          Button("Apply") { send(.commit) }
            .keyboardShortcut(.return, modifiers: [])
        }
        Text("Position is measured in the parent’s pixels. Scale is before distortion.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Select an image, text, paint layer, or eligible group.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear(perform: beginTransformIfPossible)
    .onChange(of: model.recipe.layerStack.activeLayerID) { _, _ in
      beginTransformIfPossible()
    }
  }

  private func fields(_ transform: LayerTransform) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        sectionLabel("Position")
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
          row(.x, "X", value: transform.position.x) { $0.position.x = $1 }
          row(.y, "Y", value: transform.position.y) { $0.position.y = $1 }
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          sectionLabel("Scale")
          Spacer(minLength: 0)
          proportionsButton
        }
        scaleControl(
          .scaleX,
          label: "Width",
          percentage: transform.scaleX * 100,
          axis: .x
        )
        scaleControl(
          .scaleY,
          label: "Height",
          percentage: transform.scaleY * 100,
          axis: .y
        )
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        sectionLabel("Distort")
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
          row(.rotation, "Rotate", value: transform.rotationDegrees) {
            $0.rotationDegrees = $1
          }
          row(.shear, "Shear", value: transform.shearX) { $0.shearX = $1 }
        }
      }
    }
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
  }

  private var proportionsButton: some View {
    Button {
      constrainsScale.toggle()
    } label: {
      Label(
        "Proportions",
        systemImage: constrainsScale ? "lock.fill" : "lock.open"
      )
      .font(.caption)
      .foregroundStyle(constrainsScale ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.borderless)
    .help(constrainsScale ? "Unlock width and height" : "Keep width and height proportional")
    .accessibilityLabel("Constrain proportions")
    .accessibilityValue(constrainsScale ? "On" : "Off")
  }

  private func scaleControl(
    _ field: TransformField,
    label: String,
    percentage: Double,
    axis: TransformScaleAxis
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(label)
        Spacer(minLength: 8)
        TransformValueField(
          field: field,
          label: "\(label) scale",
          value: percentage,
          focusedField: $focusedField
        ) { newValue in
          updateScale(axis, percentage: newValue)
        }
        .labelsHidden()
        .frame(width: 76)
        .textFieldStyle(.roundedBorder)
        Text("%")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }

      Slider(
        value: scaleSliderBinding(axis, percentage: percentage),
        in: transformScaleSliderRange,
        step: 1
      )
      .accessibilityLabel("\(label) scale")
      .accessibilityValue(scalePercentageLabel(percentage))
      .help("Drag from 10% to 400%, or enter another value in the field.")
    }
  }

  private func row(
    _ field: TransformField,
    _ label: String,
    value: Double,
    apply: @escaping (inout LayerTransform, Double) -> Void
  ) -> some View {
    GridRow {
      Text(label)
      TransformValueField(
        field: field,
        label: label,
        value: value,
        focusedField: $focusedField
      ) { newValue in
        guard var transform = model.transformDraft?.transform else { return }
        apply(&transform, newValue)
        if transform.isValid { send(.update(transform)) }
      }
      .labelsHidden().frame(width: 90).textFieldStyle(.roundedBorder)
    }
  }

  private func scaleSliderBinding(
    _ axis: TransformScaleAxis,
    percentage: Double
  ) -> Binding<Double> {
    Binding(
      get: { clampedTransformScaleSliderValue(percentage) },
      set: { updateScale(axis, percentage: $0) }
    )
  }

  private func updateScale(_ axis: TransformScaleAxis, percentage: Double) {
    guard let transform = model.transformDraft?.transform else { return }
    let updated = settingScale(
      transform,
      axis: axis,
      percentage: percentage,
      constrained: constrainsScale
    )
    if updated.isValid { send(.update(updated)) }
  }

  private func scalePercentageLabel(_ percentage: Double) -> String {
    percentage.formatted(.number.precision(.fractionLength(0))) + "%"
  }

  private func beginTransformIfPossible() {
    let layerID = model.recipe.layerStack.activeLayerID
    if let draft = model.transformDraft, draft.targetID != layerID {
      // Preserve the transform already previewed before following the newly
      // selected layer. Committing resumes a fresh draft on that selection.
      send(.commit)
    }
    guard model.transformDraft == nil, let layerID else { return }
    // A vector layer takes no layer transform, but its selected objects can be
    // transformed, so the session opens for either case.
    guard model.recipe.layerStack.canTransform(layerID) || canTransformVectorObjects(layerID)
    else { return }
    send(.begin)
  }

  private func canTransformVectorObjects(_ layerID: ProjectLayerID) -> Bool {
    guard let layer = model.recipe.layerStack.layer(id: layerID), !layer.isLocked,
      case .vector(let vector) = layer.content
    else { return false }
    return !model.selectedVectorObjectIDs.intersection(Set(vector.objects.map(\.id))).isEmpty
  }
}

enum TransformField: Int, CaseIterable {
  case x
  case y
  case scaleX
  case scaleY
  case rotation
  case shear

  func adjacent(backward: Bool) -> TransformField {
    let fields = Self.allCases
    let offset = backward ? fields.count - 1 : 1
    return fields[(rawValue + offset) % fields.count]
  }
}

enum TransformScaleAxis {
  case x
  case y
}

let transformScaleSliderRange = 10.0...400.0

/// The precise fields accept any valid transform scale. Only the slider thumb
/// is clamped so an existing value outside its convenient range remains
/// editable without placing the control in an invalid visual state.
func clampedTransformScaleSliderValue(_ percentage: Double) -> Double {
  min(max(percentage, transformScaleSliderRange.lowerBound), transformScaleSliderRange.upperBound)
}

/// Changes one displayed scale percentage and, when linked, preserves the
/// existing ratio between both scale axes.
func settingScale(
  _ transform: LayerTransform,
  axis: TransformScaleAxis,
  percentage: Double,
  constrained: Bool
) -> LayerTransform {
  var updated = transform
  let scale = percentage / 100
  switch axis {
  case .x:
    updated.scaleX = scale
    if constrained {
      updated.scaleY *= scale / transform.scaleX
    }
  case .y:
    updated.scaleY = scale
    if constrained {
      updated.scaleX *= scale / transform.scaleY
    }
  }
  return updated
}

/// Keeps the text being typed separate from the value driving the live canvas.
///
/// A formatted numeric `TextField` writes every parsed keystroke through its
/// binding. The resulting transform render publishes that number back into the
/// field, which formats it to two decimal places and moves the insertion point.
/// This field still previews every complete number, but only normalizes its
/// displayed text after editing ends.
private struct TransformValueField: View {
  let field: TransformField
  let label: String
  let value: Double
  let focusedField: FocusState<TransformField?>.Binding
  let onChange: (Double) -> Void

  @Environment(\.locale) private var locale
  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias TextState = SwiftUI.State<String>
  @TextState private var text: String

  init(
    field: TransformField,
    label: String,
    value: Double,
    focusedField: FocusState<TransformField?>.Binding,
    onChange: @escaping (Double) -> Void
  ) {
    self.field = field
    self.label = label
    self.value = value
    self.focusedField = focusedField
    self.onChange = onChange
    _text = SwiftUI.State(
      initialValue: value.formatted(.number.precision(.fractionLength(2)))
    )
  }

  var body: some View {
    TextField(label, text: $text)
      .focused(focusedField, equals: field)
      .onKeyPress(.tab, phases: .down) { press in
        focusedField.wrappedValue = field.adjacent(
          backward: press.modifiers.contains(.shift)
        )
        return .handled
      }
      .onAppear { synchronizeText() }
      .onChange(of: text) { _, newText in
        guard isFocused,
          let parsed = try? numberFormat.parseStrategy.parse(newText),
          parsed.isFinite,
          parsed != value
        else { return }
        onChange(parsed)
      }
      .onChange(of: value) { _, _ in synchronizeText() }
      .onChange(of: locale) { _, _ in synchronizeText() }
      .onChange(of: isFocused) { _, focused in
        if !focused { synchronizeText() }
      }
  }

  private var isFocused: Bool {
    focusedField.wrappedValue == field
  }

  private var numberFormat: FloatingPointFormatStyle<Double> {
    .number
      .locale(locale)
      .precision(.fractionLength(2))
  }

  private func synchronizeText() {
    guard !isFocused else { return }
    text = numberFormat.format(value)
  }
}

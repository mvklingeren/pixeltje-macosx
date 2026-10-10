import PixeltjeMacDomain
import SwiftUI

/// The shared develop controls for one pixel layer: basic tone, tone curve,
/// and detail, each in its own section view.
///
/// The Develop panel hosts this for RAW, linked-image, and paint layers. Other
/// feature-specific inspectors can reuse it for their own pixel layers.
/// The sections decide per control whether they bind to an Apple RAW property
/// or to the layer's post-source adjustments.
struct DevelopSectionsView: View {
  @ObservedObject var model: EditorModel
  let layer: ProjectLayer
  let send: (InspectorIntent) -> Void

  var body: some View {
    if layer.supportsAdjustments {
      VStack(alignment: .leading, spacing: 14) {
        BasicToneSection(model: model, layer: layer, send: send)
        ToneCurveSection(model: model, layer: layer, send: send)
        if layer.isDevelopedRaw {
          ColorMixerSection(model: model, layer: layer, send: send)
          ColorGradingSection(model: model, layer: layer, send: send)
        }
        DetailSection(model: model, layer: layer, send: send)
      }
    }
  }
}

/// Reads and writes the develop adjustments of one layer.
///
/// Every section edits the layer's adjustments the same way: take the value the
/// document holds right now, change one field, and send it back as a named
/// undoable action. Reading through the model rather than the captured `layer`
/// keeps a slider that is being dragged in step with the document.
@MainActor
struct LayerAdjustmentEditor {
  let model: EditorModel
  let layer: ProjectLayer

  var current: LayerAdjustments {
    model.recipe.layerStack.layer(id: layer.id)?.adjustments ?? layer.adjustments
  }

  func action(_ name: String, _ change: (inout LayerAdjustments) -> Void) -> EditorAction {
    var adjustments = current
    change(&adjustments)
    return .setLayerAdjustments(layer.id, adjustments, actionName: name)
  }
}

/// One develop slider.
///
/// Dragging updates the proxy on every change and coalesces into one undo step
/// named `actionName` on release. Double-clicking the label row resets the
/// control to its default as its own undo step.
struct AdjustmentSlider: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  var defaultValue: Double = 0
  var decimals: Int = 0
  let actionName: String
  let send: (InspectorIntent) -> Void
  /// Builds the action that sets this control to a value.
  let action: (Double) -> EditorAction

  var body: some View {
    VStack(spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(value.formatted(.number.precision(.fractionLength(decimals))))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2, perform: reset)
      .help("Double-click to reset \(title.lowercased())")
      Slider(
        value: Binding(
          get: { value },
          set: { send(.change(action($0), interactive: true)) }
        ),
        in: range,
        onEditingChanged: { editing in
          if editing {
            send(.beginGesture)
          } else {
            send(.endGesture(actionName))
          }
        }
      )
      .simultaneousGesture(TapGesture(count: 2).onEnded(reset))
      .accessibilityLabel(title)
    }
    .font(.caption)
  }

  private func reset() {
    guard value != defaultValue else { return }
    send(.change(action(defaultValue), interactive: false))
  }
}

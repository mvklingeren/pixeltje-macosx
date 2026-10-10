import PixeltjeMacDomain
import SwiftUI

/// Selective HSL controls for the selected developed RAW layer.
struct ColorMixerSection: View {
  @ObservedObject var model: EditorModel
  let layer: ProjectLayer
  let send: (InspectorIntent) -> Void

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias ChannelState = SwiftUI.State<ColorMixerChannel>
  @ChannelState private var channel = ColorMixerChannel.red

  private var editor: LayerAdjustmentEditor {
    LayerAdjustmentEditor(model: model, layer: layer)
  }

  private var band: ColorMixerChannelAdjustment {
    editor.current.colorMixer[channel]
  }

  var body: some View {
    GroupBox("Color mixer") {
      VStack(alignment: .leading, spacing: 11) {
        Picker("Color", selection: $channel) {
          ForEach(ColorMixerChannel.allCases, id: \.self) { channel in
            Text(channel.label).tag(channel)
          }
        }
        .labelsHidden()

        slider("Hue", value: band.hue, keyPath: \.hue)
        slider("Saturation", value: band.saturation, keyPath: \.saturation)
        slider("Luminance", value: band.luminance, keyPath: \.luminance)
      }
      .padding(.vertical, 2)
    }
  }

  private func slider(
    _ title: String,
    value: Double,
    keyPath: WritableKeyPath<ColorMixerChannelAdjustment, Double>
  ) -> some View {
    AdjustmentSlider(
      title: title,
      value: value,
      range: -100...100,
      actionName: "Adjust \(channel.label) \(title)",
      send: send
    ) { newValue in
      let selected = channel
      return editor.action("Adjust \(selected.label) \(title)") { adjustments in
        var band = adjustments.colorMixer[selected]
        band[keyPath: keyPath] = newValue
        adjustments.colorMixer[selected] = band
      }
    }
  }
}

/// Three luminance ranges plus the overlap and split controls that scope them.
struct ColorGradingSection: View {
  @ObservedObject var model: EditorModel
  let layer: ProjectLayer
  let send: (InspectorIntent) -> Void

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias RangeState = SwiftUI.State<ColorGradingRecipe.Range>
  @RangeState private var range = ColorGradingRecipe.Range.midtones

  private var editor: LayerAdjustmentEditor {
    LayerAdjustmentEditor(model: model, layer: layer)
  }

  private var grading: ColorGradingRecipe { editor.current.colorGrading }
  private var wheel: ColorGradingWheel { grading[range] }

  var body: some View {
    GroupBox("Color grading") {
      VStack(alignment: .leading, spacing: 11) {
        Picker("Range", selection: $range) {
          ForEach(ColorGradingRecipe.Range.allCases, id: \.self) { range in
            Text(range.label).tag(range)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        wheelSlider("Hue", value: wheel.hue, keyPath: \.hue, range: 0...360, decimals: 0)
        wheelSlider(
          "Saturation", value: wheel.saturation, keyPath: \.saturation, range: 0...100,
          decimals: 0)
        wheelSlider(
          "Luminance", value: wheel.luminance, keyPath: \.luminance, range: -100...100,
          decimals: 0)

        Divider()

        AdjustmentSlider(
          title: "Blending",
          value: grading.blending,
          range: 0...100,
          defaultValue: 50,
          actionName: "Adjust Color Grading Blending",
          send: send
        ) { value in
          editor.action("Adjust Color Grading Blending") { $0.colorGrading.blending = value }
        }
        AdjustmentSlider(
          title: "Balance",
          value: grading.balance,
          range: -100...100,
          actionName: "Adjust Color Grading Balance",
          send: send
        ) { value in
          editor.action("Adjust Color Grading Balance") { $0.colorGrading.balance = value }
        }
      }
      .padding(.vertical, 2)
    }
  }

  private func wheelSlider(
    _ title: String,
    value: Double,
    keyPath: WritableKeyPath<ColorGradingWheel, Double>,
    range valueRange: ClosedRange<Double>,
    decimals: Int
  ) -> some View {
    AdjustmentSlider(
      title: title,
      value: value,
      range: valueRange,
      decimals: decimals,
      actionName: "Adjust \(range.label) \(title)",
      send: send
    ) { newValue in
      let selected = range
      return editor.action("Adjust \(selected.label) \(title)") { adjustments in
        var wheel = adjustments.colorGrading[selected]
        wheel[keyPath: keyPath] = newValue
        adjustments.colorGrading[selected] = wheel
      }
    }
  }
}

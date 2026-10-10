import PixeltjeMacDomain
import SwiftUI

/// Detail: sharpening with masking, and luminance and color noise reduction.
///
/// The panel has two halves and is explicit about which is which.
///
/// On a developed RAW layer the first half is Apple's own detail processing:
/// sharpness, detail, moiré, despeckle and the two noise-reduction amounts,
/// each bound straight to the matching public `CIRAWFilter` property and shown
/// only when the installed RAW system reports it as supported. Nothing is
/// substituted for an unsupported property.
///
/// The second half is the post-RAW sharpening and noise reduction of this
/// layer: `CIUnsharpMask` with an edge mask, and `CINoiseReduction` plus a
/// chroma blur. `CIRAWFilter` has no radius or masking property, so those two
/// controls only exist here. Every control in this half defaults to neutral and
/// renders nothing until the user moves it, so no second sharpening or denoise
/// is ever applied on top of Apple's by default.
struct DetailSection: View {
  @ObservedObject var model: EditorModel
  let layer: ProjectLayer
  let send: (InspectorIntent) -> Void

  private var editor: LayerAdjustmentEditor {
    LayerAdjustmentEditor(model: model, layer: layer)
  }

  private var detail: DetailRecipe { editor.current.detail }

  var body: some View {
    GroupBox("Detail") {
      VStack(alignment: .leading, spacing: 11) {
        if let raw = currentRawLayer ?? layer.developedRawLayer,
          let parameters = raw.rawDevelopment.parameters
        {
          rawDetail(parameters)
          Divider()
          Text("Extra detail edits applied after RAW development.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        sharpening
        Divider()
        noiseReduction
      }
      .padding(.vertical, 2)
    }
  }

  // MARK: - Apple RAW detail

  @ViewBuilder
  private func rawDetail(_ parameters: RawParameters) -> some View {
    rawSlider("Sharpness", .sharpness, parameters, 0...1)
    rawSlider("Detail", .detail, parameters, 0...3)
    rawSlider("Moiré", .moireReduction, parameters, 0...1)
    rawSlider("Despeckle", .despeckle, parameters, 0...1)
    rawSlider("Luminance noise", .luminanceNoiseReduction, parameters, 0...1)
    rawSlider("Color noise", .colorNoiseReduction, parameters, 0...1)
  }

  /// One Apple RAW slider, shown only when the decoder supports the property.
  @ViewBuilder
  private func rawSlider(
    _ title: String,
    _ parameter: RawFloatParameter,
    _ parameters: RawParameters,
    _ range: ClosedRange<Double>
  ) -> some View {
    if currentRawLayer?.rawDevelopment.capabilities?.supports(parameter) != false {
      AdjustmentSlider(
        title: title,
        value: parameters[parameter],
        range: range,
        defaultValue: currentRawLayer?.rawDevelopment.capturedDefaults?[parameter] ?? 0,
        decimals: 2,
        actionName: "Adjust \(title)",
        send: send
      ) { .setRawLayerFloat(layer.id, parameter, $0) }
    }
  }

  private var currentRawLayer: DevelopedRawLayer? {
    model.recipe.layerStack.layer(id: layer.id)?.developedRawLayer
  }

  // MARK: - Post-RAW sharpening

  private var sharpening: some View {
    VStack(alignment: .leading, spacing: 11) {
      Text("Sharpening")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      detailSlider("Amount", .sharpenAmount, range: 0...100, actionName: "Adjust Sharpening")
      detailSlider(
        "Radius", .sharpenRadius, range: 0.5...3, decimals: 1,
        actionName: "Adjust Sharpening Radius")
      detailSlider(
        "Detail", .sharpenDetail, range: 0...100, actionName: "Adjust Sharpening Detail")
      detailSlider("Masking", .sharpenMasking, range: 0...100, actionName: "Adjust Masking")
      Text("Masking keeps sharpening on edges and leaves flat areas alone.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Post-RAW noise reduction

  private var noiseReduction: some View {
    VStack(alignment: .leading, spacing: 11) {
      Text("Noise reduction")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      detailSlider(
        "Luminance", .luminanceNoise, range: 0...100,
        actionName: "Adjust Luminance Noise Reduction")
      detailSlider(
        "Color", .colorNoise, range: 0...100, actionName: "Adjust Color Noise Reduction")
      Button("Reset Detail") {
        send(.change(resetAction(), interactive: false))
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .disabled(detail == .neutral)
    }
  }

  private func detailSlider(
    _ title: String,
    _ control: DetailRecipe.Control,
    range: ClosedRange<Double>,
    decimals: Int = 0,
    actionName: String
  ) -> some View {
    AdjustmentSlider(
      title: title,
      value: detail[control],
      range: range,
      defaultValue: control.defaultValue,
      decimals: decimals,
      actionName: actionName,
      send: send
    ) { value in
      editor.action(actionName) { $0.detail[control] = value }
    }
  }

  private func resetAction() -> EditorAction {
    editor.action("Reset Detail") { $0.detail = .neutral }
  }
}

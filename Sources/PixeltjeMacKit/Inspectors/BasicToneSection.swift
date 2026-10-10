import PixeltjeMacDomain
import SwiftUI

/// Basic tone: exposure, contrast, highlights, shadows, whites, blacks,
/// texture, clarity, dehaze, vibrance, saturation.
///
/// On a RAW layer the exposure slider is Apple's `CIRAWFilter` exposure, the
/// same value the Apple RAW group used to show; every other control is a
/// post-RAW edit of the layer. On a placed image every control, exposure
/// included, is post-RAW.
struct BasicToneSection: View {
  @ObservedObject var model: EditorModel
  let layer: ProjectLayer
  let send: (InspectorIntent) -> Void

  var body: some View {
    GroupBox("Basic tone") {
      VStack(spacing: 11) {
        exposureSlider
        toneSlider("Contrast", .contrast)
        toneSlider("Highlights", .highlights)
        toneSlider("Shadows", .shadows)
        toneSlider("Whites", .whites)
        toneSlider("Blacks", .blacks)
        Divider()
        toneSlider("Texture", .texture)
        toneSlider("Clarity", .clarity)
        toneSlider("Dehaze", .dehaze)
        Divider()
        toneSlider("Vibrance", .vibrance)
        toneSlider("Saturation", .saturation)
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder
  private var exposureSlider: some View {
    if let raw = layer.developedRawLayer {
      if let parameters = currentRawLayer?.rawDevelopment.parameters ?? raw.rawDevelopment.parameters {
        AdjustmentSlider(
          title: "Exposure",
          value: parameters.exposure,
          range: -5...5,
          defaultValue: (currentRawLayer ?? raw).rawDevelopment.capturedDefaults?.exposure ?? 0,
          decimals: 2,
          actionName: "Adjust Exposure",
          send: send
        ) { .setRawLayerFloat(layer.id, .exposure, $0) }
      }
    } else {
      AdjustmentSlider(
        title: "Exposure",
        value: tone.exposure,
        range: -5...5,
        decimals: 2,
        actionName: "Adjust Exposure",
        send: send
      ) { setting(.exposure, $0) }
    }
  }

  private func toneSlider(_ title: String, _ control: BasicToneRecipe.Control) -> some View {
    AdjustmentSlider(
      title: title,
      value: tone[control],
      range: -100...100,
      actionName: "Adjust \(title)",
      send: send
    ) { setting(control, $0) }
  }

  private var tone: BasicToneRecipe {
    model.recipe.layerStack.layer(id: layer.id)?.adjustments.basicTone ?? layer.adjustments.basicTone
  }

  private var currentRawLayer: DevelopedRawLayer? {
    model.recipe.layerStack.layer(id: layer.id)?.developedRawLayer
  }

  private func setting(_ control: BasicToneRecipe.Control, _ value: Double) -> EditorAction {
    var adjustments =
      model.recipe.layerStack.layer(id: layer.id)?.adjustments ?? layer.adjustments
    adjustments.basicTone[control] = value
    return .setLayerAdjustments(
      layer.id, adjustments, actionName: "Adjust \(control.rawValue.capitalized)")
  }
}

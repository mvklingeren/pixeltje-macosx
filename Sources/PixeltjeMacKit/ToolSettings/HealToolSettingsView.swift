import PixeltjeMacDomain
import SwiftUI

/// The Healing Brush's controls.
///
/// No color well and no brush library: a heal takes its pixels from the image
/// rather than from the foreground color, and a tip shape or a grain would
/// change the coverage of a patch without changing the patch. What is left is
/// the shape of the region, where its replacement comes from, and how the two
/// are fitted together.
struct HealToolSettingsView: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Healing Brush", systemImage: EditorTool.heal.symbolName).font(.headline)

      Picker("Source", selection: binding(\.mode)) {
        ForEach(HealSourceMode.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)

      if model.healTool.mode == .sourcePoint {
        sourceAnchorRow
      }

      VStack(alignment: .leading, spacing: 8) {
        slider("Size", value: binding(\.settings.size), in: 1...512, unit: " px")
        slider("Hardness", value: binding(\.settings.hardness), in: 0...1, percent: true)
        slider("Spacing", value: binding(\.settings.spacing), in: 0.02...1, percent: true)
        slider(
          "Pressure", value: binding(\.settings.pressureResponse), in: 0...1, percent: true)
      }

      Divider()

      Picker("Sample", selection: binding(\.sampleSource)) {
        ForEach(HealSampleSource.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      // Colour matching needs a source to take its detail from, so it is not
      // offered in spot mode, where it would silently do nothing.
      if model.healTool.mode == .sourcePoint {
        Picker("Blend", selection: binding(\.blend)) {
          ForEach(HealBlendMethod.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
      }
      if model.healTool.mode == .spot || model.healTool.blend == .seamless {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Refinement")
            Spacer()
            Text("\(model.healTool.solverIterations)")
              .monospacedDigit().foregroundStyle(.secondary)
          }
          Slider(
            value: Binding(
              get: { Double(model.healTool.solverIterations) },
              set: { value in
                var next = model.healTool
                next.solverIterations = Int(value.rounded())
                model.setHealTool(next)
              }
            ),
            in: Double(HealLimits.minimumSolverIterations)...Double(HealLimits.maximumSolverIterations)
          )
        }
      }

      Text(explanation)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var sourceAnchorRow: some View {
    HStack {
      if model.healTool.sourceAnchor != nil {
        Text(sourceAnchorDescription)
          .font(.caption)
          .monospacedDigit()
      } else {
        Label("Option-click to set a source", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button("Clear") { model.setHealSourceAnchor(nil) }
        .disabled(model.healTool.sourceAnchor == nil)
        .accessibilityLabel("Clear the heal source anchor")
    }
  }

  private var sourceAnchorDescription: String {
    guard let anchor = model.healTool.sourceAnchor else { return "No source set" }
    let x = (anchor.x * 100).formatted(.number.precision(.fractionLength(1)))
    let y = (anchor.y * 100).formatted(.number.precision(.fractionLength(1)))
    return "Source at \(x)%, \(y)%"
  }

  private var explanation: String {
    switch model.healTool.mode {
    case .spot:
      "Paint over a blemish. It is rebuilt from the pixels around what you"
        + " painted, so nothing needs to be chosen as a source. The result is"
        + " solved once, on release, and stored as pixels on a healing layer"
        + " above the image."
    case .sourcePoint:
      "Option-click to anchor a source, then paint. Texture is copied from the"
        + " anchor, carried by the same distance your stroke travels, and"
        + " re-fitted to the colour and brightness it lands on."
    }
  }

  private func slider(
    _ title: String,
    value: Binding<Double>,
    in range: ClosedRange<Double>,
    unit: String = "",
    percent: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(
          percent
            ? value.wrappedValue.formatted(.percent.precision(.fractionLength(0)))
            : "\(value.wrappedValue.formatted(.number.precision(.fractionLength(0))))\(unit)"
        )
        .monospacedDigit()
        .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range)
    }
  }

  private func binding<Value>(_ path: WritableKeyPath<HealToolState, Value>) -> Binding<Value> {
    Binding(
      get: { model.healTool[keyPath: path] },
      set: { value in
        var next = model.healTool
        next[keyPath: path] = value
        model.setHealTool(next)
      }
    )
  }
}

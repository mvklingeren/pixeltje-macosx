import PixeltjeMacDomain
import SwiftUI

/// The dedicated home for RAW, linked-image, and paint-layer development.
///
/// The layer inspector owns selection. This view reflects that selection rather
/// than retaining another copy of it, so its label and controls always point at
/// the same layer as the canvas and the layer list. RAW-only controls remain
/// conditional inside the panel content.
struct DevelopPanelView: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var panelModel: PanelModel

  var body: some View {
    if selectedDevelopLayer != nil || panelModel.contains(.comfyUI) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: headerSymbol)
            .foregroundStyle(.secondary)
          if let layer = selectedDevelopLayer {
            Text("Developing:")
              .font(.subheadline.weight(.semibold))
            Text(layer.name)
              .font(.subheadline)
              .lineLimit(1)
              .truncationMode(.middle)
          } else {
            Text("Generate with ComfyUI")
              .font(.subheadline.weight(.semibold))
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerAccessibilityLabel)

        Divider()

        PanelView(
          model: panelModel,
          emptyDescription: "Development controls for the selected layer appear here."
        )
      }
    } else {
      ContentUnavailableView(
        "Development Unavailable",
        systemImage: "slider.horizontal.3",
        description: Text(
          "Select a RAW, linked image, or paint layer in the Layers panel to edit its development settings."
        )
      )
      .padding(24)
    }
  }

  private var selectedDevelopLayer: ProjectLayer? {
    guard let layer = model.activeLayer, layer.supportsDevelopPanel else { return nil }
    return layer
  }

  private var headerSymbol: String {
    guard let layer = selectedDevelopLayer else { return "sparkles" }
    if layer.isDevelopedRaw { return "camera.aperture" }
    if layer.isPaintLayer { return "paintbrush" }
    return "photo"
  }

  private var headerAccessibilityLabel: String {
    selectedDevelopLayer.map { "Developing \($0.name)" } ?? "Generate with ComfyUI"
  }
}

extension ProjectLayer {
  /// The pixel-layer types whose non-destructive development controls live in
  /// the Develop panel. Other adjustable layer types keep their existing
  /// feature-specific inspector until their product placement is decided.
  var supportsDevelopPanel: Bool {
    isDevelopedRaw || isImageLayer || isPaintLayer
  }
}

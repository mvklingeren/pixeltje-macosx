import AppKit
import PixeltjeMacDomain
import SwiftUI

/// What the color controls ask the document to do.
///
/// These go through `ProjectDocument` rather than straight to `EditorModel`,
/// because the shared colors reach the selected vector objects as well as the
/// defaults for the next one, and only the document can edit a layer.
enum ColorWorkflowIntent {
  case setForeground(LinearRGBAColor)
  case setBackground(LinearRGBAColor)
  case swap
  case reset
}

/// The shared window-local foreground/background controls used by every tool
/// that creates colored artwork.
///
/// There is one pair of colors in a document window and this is the control for
/// it. A tool that appears to have a color of its own — the brush's paint, the
/// text color, the flood fill, a gradient's two ends, a vector stroke and fill —
/// is showing one of these two, so `foregroundLabel` and `backgroundLabel` name
/// the role the active tool puts them to rather than repeating "Foreground"
/// everywhere and leaving the reader to guess what it drives.
///
/// A panel that shows the pair somewhere better placed — the Pen and Shape
/// panels put them in the Stroke and Fill sections they belong to — passes
/// `showsWells: false` and keeps only the sampling, swapping and saved colors.
struct ColorWorkflowView: View {
  @ObservedObject var model: EditorModel
  let send: (ColorWorkflowIntent) -> Void
  var foregroundLabel = "Foreground"
  var backgroundLabel = "Background"
  var showsWells = true

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        if showsWells {
          VStack(alignment: .leading, spacing: 3) {
            Text(foregroundLabel).font(.caption).foregroundStyle(.secondary)
            ColorPicker(foregroundLabel, selection: foreground, supportsOpacity: true)
              .labelsHidden()
              .accessibilityLabel("\(foregroundLabel) color")
          }
          VStack(alignment: .leading, spacing: 3) {
            Text(backgroundLabel).font(.caption).foregroundStyle(.secondary)
            ColorPicker(backgroundLabel, selection: background, supportsOpacity: true)
              .labelsHidden()
              .accessibilityLabel("\(backgroundLabel) color")
          }
        }
        Spacer(minLength: 0)
        Button { send(.swap) } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .help("Swap \(foregroundLabel.lowercased()) and \(backgroundLabel.lowercased()) (X)")
        .accessibilityLabel("Swap foreground and background colors")
        Button { send(.reset) } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .help("Reset colors to black and white (D)")
        .accessibilityLabel("Reset foreground and background colors")
      }

      HStack {
        Button {
          NSApp.sendAction(
            #selector(ProjectWindowController.pickForegroundColor(_:)),
            to: nil,
            from: nil
          )
        } label: {
          Label("Sample Color", systemImage: "eyedropper")
        }
        .disabled(
          model.renderedFrame == nil && model.recipe.layerStack.vectorArtwork.isEmpty)
        Spacer(minLength: 0)
        Button {
          model.togglePinnedColor(model.colorTool.foreground)
        } label: {
          Image(systemName: model.colorTool.pinnedColors.contains(model.colorTool.foreground)
            ? "pin.fill" : "pin")
        }
        .help("Pin or unpin the \(foregroundLabel.lowercased()) color")
        .accessibilityLabel("Pin or unpin foreground color")
      }

      Picker("Sample", selection: sampleSource) {
        ForEach(ColorSampleSource.allCases, id: \.self) { source in
          Text(source.label).tag(source)
        }
      }
      .pickerStyle(.segmented)
      Picker("Average", selection: sampleSize) {
        ForEach(ColorSampleSize.allCases, id: \.self) { size in
          Text(size.label).tag(size)
        }
      }
      .pickerStyle(.menu)

      if !model.colorTool.pinnedColors.isEmpty {
        swatches("Pinned", colors: model.colorTool.pinnedColors)
      }
      if !model.colorTool.recentColors.isEmpty {
        swatches("Recent", colors: model.colorTool.recentColors)
      }
      Text("Option-click with the Brush to sample temporarily. Samples use image pixels, independent of zoom.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var foreground: Binding<Color> {
    Binding(
      get: { model.colorTool.foreground.swiftUIColor },
      set: { send(.setForeground(LinearRGBAColor($0))) }
    )
  }

  private var background: Binding<Color> {
    Binding(
      get: { model.colorTool.background.swiftUIColor },
      set: { send(.setBackground(LinearRGBAColor($0))) }
    )
  }

  private var sampleSource: Binding<ColorSampleSource> {
    Binding(get: { model.colorTool.sampleSource }, set: model.setColorSampleSource)
  }

  private var sampleSize: Binding<ColorSampleSize> {
    Binding(get: { model.colorTool.sampleSize }, set: model.setColorSampleSize)
  }

  private func swatches(_ title: String, colors: [LinearRGBAColor]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 5) {
        ForEach(Array(colors.prefix(8).enumerated()), id: \.offset) { _, color in
          Button { send(.setForeground(color)) } label: {
            Circle()
              .fill(color.swiftUIColor)
              .overlay(Circle().stroke(.primary.opacity(0.25), lineWidth: 1))
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Use saved color as \(foregroundLabel.lowercased())")
        }
      }
    }
  }
}

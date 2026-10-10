import Foundation
import PixeltjeMacDomain
import SwiftUI

/// What the export popup asks for.
///
/// Choosing a folder and starting the work are the window controller's to do:
/// the popup only decides what the export should be.
enum ExportPopupIntent {
  case chooseDestination
  case export(preset: ExportPreset, destination: URL)
  case cancel
}

/// The destination the popup is currently pointing at.
///
/// The folder is chosen with an AppKit open panel, which the window controller
/// runs; this small model is how its answer reaches the popup without the view
/// touching the file system itself.
@MainActor
final class ExportPopupModel: ObservableObject {
  @Published var destination: URL?

  init(destination: URL?) {
    self.destination = destination
  }
}

/// The export popup: pick a preset, override anything in it, choose where the
/// file goes, and hand the job to the background queue.
///
/// The preset picked here is a starting point. Everything below it edits a
/// working copy, so an override applies to this export without changing the
/// preset — saving it back is a deliberate, separate action.
struct ExportPopupView: View {
  @ObservedObject var store: ExportPresetStore
  @ObservedObject var popup: ExportPopupModel
  /// The source file name a naming template expands `{name}` from.
  let originalName: String
  /// The sequence number this export would take, shown in the preview.
  let previewSequence: Int
  let send: (ExportPopupIntent) -> Void

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias PresetState = SwiftUI.State<ExportPreset>
  private typealias IDState = SwiftUI.State<UUID>
  private typealias NameState = SwiftUI.State<String>

  @PresetState private var draft: ExportPreset
  @IDState private var selectedPresetID: UUID
  @NameState private var newPresetName: String

  init(
    store: ExportPresetStore,
    popup: ExportPopupModel,
    originalName: String,
    previewSequence: Int,
    send: @escaping (ExportPopupIntent) -> Void
  ) {
    self.store = store
    self.popup = popup
    self.originalName = originalName
    self.previewSequence = previewSequence
    self.send = send
    let preset = store.lastUsedPreset
    _draft = PresetState(initialValue: preset)
    _selectedPresetID = IDState(initialValue: preset.id)
    _newPresetName = NameState(initialValue: "")
  }

  private var resolvedFilename: String {
    draft.naming.filename(
      originalName: originalName,
      sequence: previewSequence,
      presetName: draft.name,
      format: draft.format
    )
  }

  private var selectedIsUserPreset: Bool {
    store.library.userPresets.contains { $0.id == selectedPresetID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          formatSection
          resizeSection
          sharpeningSection
          watermarkSection
          namingSection
          metadataSection
          presetSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(width: 520, height: 660)
    .accessibilityLabel("Export")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Export")
        .font(.headline)
      Picker("Preset", selection: $selectedPresetID) {
        Section("Built-in") {
          ForEach(ExportPreset.builtIns) { preset in
            Text(preset.name).tag(preset.id)
          }
        }
        if !store.library.userPresets.isEmpty {
          Section("My Presets") {
            ForEach(store.library.userPresets) { preset in
              Text(preset.name).tag(preset.id)
            }
          }
        }
      }
      .onChange(of: selectedPresetID) { _, id in
        guard let preset = store.preset(id: id) else { return }
        draft = preset
      }
      Text(draft.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
  }

  private var formatSection: some View {
    section("Format") {
      Picker("File format", selection: $draft.format) {
        ForEach(ExportFormat.allCases, id: \.self) { format in
          Text(format.displayName).tag(format)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if draft.format.usesQuality {
        HStack {
          Text("Quality")
          Slider(value: $draft.quality, in: 0.05...1)
          Text("\(Int((draft.clampedQuality * 100).rounded()))")
            .monospacedDigit()
            .frame(width: 34, alignment: .trailing)
        }
      }
      if draft.format.usesBitDepth {
        Picker("Bit depth", selection: $draft.bitDepth) {
          ForEach(ExportBitDepth.allCases, id: \.self) { depth in
            Text(depth.displayName).tag(depth)
          }
        }
      }
      Picker("Color profile", selection: $draft.colorSpace) {
        Text("sRGB").tag(ExportColorSpace.sRGB)
        Text("Display P3").tag(ExportColorSpace.displayP3)
      }
      Text("The chosen ICC profile is embedded in the exported file.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var resizeSection: some View {
    section("Resize") {
      Picker("Resize", selection: $draft.resize.mode) {
        ForEach(ExportResizeMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      switch draft.resize.mode {
      case .none:
        EmptyView()
      case .longEdge:
        pixelField("Long edge", value: $draft.resize.longEdge)
      case .shortEdge:
        pixelField("Short edge", value: $draft.resize.shortEdge)
      case .exactDimensions:
        HStack {
          Text("Fit within")
          TextField("Width", value: $draft.resize.width, format: .number)
            .frame(width: 72)
          Text("×")
          TextField("Height", value: $draft.resize.height, format: .number)
            .frame(width: 72)
          Text("px").foregroundStyle(.secondary)
        }
        .labelsHidden()
      case .percentage:
        HStack {
          Text("Scale")
          Slider(value: $draft.resize.percentage, in: 1...400)
          Text("\(Int(draft.resize.percentage.rounded()))%")
            .monospacedDigit()
            .frame(width: 48, alignment: .trailing)
        }
      }
      if draft.resize.mode != .none {
        Toggle("Allow enlarging", isOn: $draft.resize.allowsUpscaling)
        Text("The aspect ratio is always kept; exact dimensions fit inside the box.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var sharpeningSection: some View {
    section("Output Sharpening") {
      Picker("Sharpening", selection: $draft.sharpening.mode) {
        ForEach(ExportSharpeningMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      if draft.sharpening.mode != .off {
        HStack {
          Text("Amount")
          Slider(value: $draft.sharpening.amount, in: 0...1)
          Text("\(Int((draft.sharpening.amount * 100).rounded()))")
            .monospacedDigit()
            .frame(width: 34, alignment: .trailing)
        }
        Text("Applied after the resize, in output pixels.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var watermarkSection: some View {
    section("Watermark") {
      Toggle("Add a text watermark", isOn: $draft.watermark.isEnabled)
      if draft.watermark.isEnabled {
        TextField("Text", text: $draft.watermark.text)
        Picker("Position", selection: $draft.watermark.position) {
          ForEach(WatermarkPosition.allCases, id: \.self) { position in
            Text(position.displayName).tag(position)
          }
        }
        HStack {
          Text("Opacity")
          Slider(value: $draft.watermark.opacity, in: 0.05...1)
          Text("\(Int((draft.watermark.opacity * 100).rounded()))")
            .monospacedDigit()
            .frame(width: 34, alignment: .trailing)
        }
        HStack {
          Text("Size")
          Slider(value: $draft.watermark.sizePercent, in: 0.5...15)
          Text("\(draft.watermark.sizePercent, format: .number.precision(.fractionLength(1)))%")
            .monospacedDigit()
            .frame(width: 48, alignment: .trailing)
        }
        Text("Size and inset are percentages of the exported image's long edge.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var namingSection: some View {
    section("File Name") {
      TextField("Template", text: $draft.naming.template)
      Text(verbatim: resolvedFilename)
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        ForEach(ExportNaming.tokens) { token in
          HStack(spacing: 6) {
            Text(token.token)
              .font(.caption.monospaced())
            Text(token.explanation)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var metadataSection: some View {
    section("Metadata") {
      Toggle("Embed generation metadata", isOn: $draft.embedsGenerationMetadata)
      Text(
        "Records the wish. Generation is not implemented yet, so nothing is written for it "
          + "rather than a made-up format a real implementation would have to migrate."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var presetSection: some View {
    section("Presets") {
      HStack(spacing: 8) {
        TextField("New preset name", text: $newPresetName)
        Button("Save") {
          var preset = draft.duplicated(named: newPresetName)
          preset.isBuiltIn = false
          store.save(preset)
          selectedPresetID = preset.id
          draft = preset
          newPresetName = ""
        }
        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if selectedIsUserPreset {
        HStack(spacing: 8) {
          Button("Update “\(draft.name)”") {
            store.save(draft)
          }
          Button("Delete", role: .destructive) {
            store.delete(id: selectedPresetID)
            let fallback = ExportPreset.defaultPreset
            selectedPresetID = fallback.id
            draft = fallback
          }
        }
      }
      Text("Presets are shared by every document, alongside the other settings.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
        Text(popup.destination?.path ?? "Choose a destination folder")
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.head)
          .foregroundStyle(popup.destination == nil ? Color.secondary : Color.primary)
        Spacer(minLength: 4)
        Button("Choose…") { send(.chooseDestination) }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { send(.cancel) }
          .keyboardShortcut(.cancelAction)
        Button("Export") {
          guard let destination = popup.destination else { return }
          store.rememberLastUsed(draft)
          send(.export(preset: draft, destination: destination))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(popup.destination == nil)
      }
    }
    .padding(16)
  }

  private func pixelField(_ label: String, value: Binding<Int>) -> some View {
    HStack {
      Text(label)
      Spacer(minLength: 8)
      TextField(label, value: value, format: .number)
        .frame(width: 90)
        .labelsHidden()
      Text("px").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func section<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

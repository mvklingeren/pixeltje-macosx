import PixeltjeMacDomain
import SwiftUI

/// The develop preset picker, near the top of the RAW Develop panel.
///
/// A preset carries only the parameters it names, so applying one leaves the
/// as-shot white balance and the exposure alone. Applying is a single
/// `applyRawPreset` action and therefore a single undo step and a single
/// render, rather than a bracketed run of slider changes.
///
/// The control is a menu rather than a picker because "which preset is
/// selected" is derived, not stored: one nudge of any slider and no preset is
/// selected any more. A picker's binding would have to lie about that or invent
/// an empty row; a check mark beside the presets whose values currently stand
/// says the honest thing.
struct RawPresetPicker: View {
  @ObservedObject var store: RawPresetStore
  let layerID: ProjectLayerID
  let parameters: RawParameters
  let capturedDefaults: RawParameters?
  let capabilities: RawCapabilities?
  let send: (InspectorIntent) -> Void

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias FlagState = SwiftUI.State<Bool>
  private typealias TextState = SwiftUI.State<String>
  @FlagState private var isSaving = false
  @TextState private var newPresetName = ""
  @FlagState private var includesWhiteBalanceAndExposure = false

  var body: some View {
    GroupBox("Preset") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          menu
          Spacer()
          Button(isSaving ? "Cancel" : "Save Current Settings…") {
            isSaving.toggle()
            newPresetName = ""
          }
          .controlSize(.small)
        }
        if isSaving {
          saveRow
        } else {
          Text(
            "A preset changes only the settings it names. White balance, tint and exposure are "
              + "left as shot."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 2)
    }
  }

  private var menu: some View {
    Menu("Apply Preset") {
      Section("Built-in") {
        ForEach(RawPresetCatalog.builtIns) { preset in
          presetButton(preset)
        }
      }
      if !store.library.userPresets.isEmpty {
        Section("My Presets") {
          ForEach(store.library.userPresets) { preset in
            presetButton(preset)
          }
        }
        // Deleting lives in its own submenu rather than beside each preset, so
        // the destructive item is never the neighbour of the one being applied.
        Section {
          Menu("Delete Preset") {
            ForEach(store.library.userPresets) { preset in
              Button(preset.name, role: .destructive) {
                store.delete(id: preset.id)
              }
            }
          }
        }
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private func presetButton(_ preset: RawPreset) -> some View {
    Button {
      send(.change(.applyRawLayerPreset(layerID, preset), interactive: false))
    } label: {
      if preset.matches(parameters, capabilities: capabilities) {
        Label(preset.name, systemImage: "checkmark")
      } else {
        Text(preset.name)
      }
    }
    .help(preset.summary)
  }

  /// What "Save Current Settings" would capture: everything that differs from
  /// the camera's own defaults, which is exactly the sparse set a preset wants.
  private var captured: RawPreset {
    RawPreset.capturing(
      parameters,
      against: capturedDefaults,
      named: newPresetName.trimmingCharacters(in: .whitespaces),
      includingWhiteBalanceAndExposure: includesWhiteBalanceAndExposure
    )
  }

  private var saveRow: some View {
    let captured = captured
    let count = captured.settingCount(capabilities)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        TextField("New preset name", text: $newPresetName)
        Button("Save") {
          store.save(captured)
          isSaving = false
          newPresetName = ""
        }
        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty || count == 0)
      }
      Toggle("Include white balance and exposure", isOn: $includesWhiteBalanceAndExposure)
        .controlSize(.small)
      Text(
        count == 0
          ? "Nothing differs from the camera default yet, so there is nothing to save."
          : "Captures \(count) setting\(count == 1 ? "" : "s") that differ from the camera "
            + "default: \(captured.summary)."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

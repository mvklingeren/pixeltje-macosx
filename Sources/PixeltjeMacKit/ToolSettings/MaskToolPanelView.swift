import PixeltjeMacDomain
import SwiftUI

/// What the mask surfaces ask for. Views state the intent; the window
/// controller routes it to the document or to the editor model.
enum MaskIntent {
  case beginGesture
  case change(EditorAction, interactive: Bool)
  case endGesture(String)
  /// Replaces the masks tool's settings. Tool state, not document state.
  case setMaskTool(MaskToolState)
  /// Points the masks tool at one mask on one layer.
  case activateMask(MaskID?, on: ProjectLayerID?)
}

/// The masks tool's settings: mask type and combine mode, per the placement
/// rule, in the left panel.
///
/// The masks themselves belong to a layer and are listed with it in the right
/// panel. What is set here is what the next gesture will make, which is why it
/// sits in the tool settings slot with every other tool's controls rather than
/// in a section of its own.
///
/// The view observes `EditorModel` rather than capturing anything, because the
/// left panel builds its content once at install time.
struct MaskToolPanelView: View {
  @ObservedObject var model: EditorModel
  let send: (MaskIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if targetLayer == nil {
        Text("Select a layer in the layers inspector to mask it.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        selectionMask
        maskTypePicker
        combinePicker
        featherSlider
        availabilityNotice
        placement
        activeMaskSummary
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: EditorTool.masks.symbolName)
      Text("Masks")
        .font(.headline)
      Spacer()
    }
  }

  private var selectionMask: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Selection")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Apply", action: applySelectionAsMask)
          .controlSize(.small)
          .disabled(model.recipe.selection == nil)
          .help("Use the current selection as a mask on the selected layer")
          .accessibilityLabel("Apply Selection as Mask")
      }
      Text(selectionSummary)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var maskTypePicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Mask Type")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("Mask Type", selection: kindBinding) {
        ForEach(
          MaskGeneratorKind.allCases.filter {
            $0 != .raster && $0 != .placedRaster && $0 != .strokeSurface
          },
          id: \.self
        ) { kind in
          Label(kind.label, systemImage: kind.symbolName)
            .tag(kind)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
    }
  }

  private var combinePicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Combine")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("Combine", selection: combineBinding) {
        ForEach(MaskCombineOperation.allCases, id: \.self) { operation in
          Text(operation.label).tag(operation)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      Text(
        "The first component of a mask starts its coverage. Every later one is added to, "
          + "subtracted from, or intersected with what is already there."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var featherSlider: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Feather")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(model.maskTool.feather.formatted(.number.precision(.fractionLength(0))) + " px")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(
        value: Binding(
          get: { model.maskTool.feather },
          set: { value in
            var next = model.maskTool
            next.feather = value
            send(.setMaskTool(next))
          }
        ),
        in: 0...400
      )
    }
  }

  @ViewBuilder
  private var availabilityNotice: some View {
    let availability = model.maskTool.generatorKind.availability
    if !availability.isAvailable, let reason = availability.unavailableReason {
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var placement: some View {
    let kind = model.maskTool.generatorKind
    if kind.needsCanvasPlacement {
      Text(placementHint(for: kind))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      Button {
        addGeneratedComponent(kind)
      } label: {
        Label("Create \(kind.label) Mask", systemImage: kind.symbolName)
          .frame(maxWidth: .infinity)
      }
      .controlSize(.regular)
      .disabled(!kind.availability.isAvailable)
      .help(
        kind.availability.unavailableReason
          ?? "Analyse the selected layer and add the result to the mask"
      )
    }
  }

  private func placementHint(for kind: MaskGeneratorKind) -> String {
    switch kind {
    case .linearGradient:
      return "Drag on the canvas from where the mask is solid to where it fades out."
    case .radialGradient:
      return "Drag on the canvas from the center of the mask outward to set its radius."
    case .luminanceRange:
      return "Click the canvas to sample a brightness, then tune the range in the mask list."
    case .colorRange:
      return "Click the canvas to sample a color, then tune the tolerance in the mask list."
    case .brush:
      return
        "Brush strokes are stored as geometry in the mask recipe. Painting arrives with the "
        + "brush tool; until then a brush component can be created but not painted into."
    case .raster:
      return "Captured by the Fill tool."
    case .placedRaster:
      return "Produced by a selection workflow."
    case .strokeSurface:
      return "Select the layer-mask thumbnail, then use Brush or Eraser."
    default:
      return ""
    }
  }

  @ViewBuilder
  private var activeMaskSummary: some View {
    if let mask = model.maskTool.activeMask(in: model.recipe.layerStack) {
      VStack(alignment: .leading, spacing: 4) {
        Divider()
        Text("Editing \(mask.name)")
          .font(.caption)
        Text(mask.summary)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Button("Start a New Mask") {
          send(.activateMask(nil, on: targetLayer?.id))
        }
        .controlSize(.small)
      }
    } else {
      Text("The next placement starts a new mask on the selected layer.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - State

  private var targetLayer: ProjectLayer? {
    guard let id = model.recipe.layerStack.activeLayerID,
      let layer = model.recipe.layerStack.layer(id: id),
      !layer.isCanvasLayer
    else { return nil }
    return layer
  }

  private var kindBinding: Binding<MaskGeneratorKind> {
    Binding(
      get: { model.maskTool.generatorKind },
      set: { kind in
        var next = model.maskTool
        next.generatorKind = kind
        send(.setMaskTool(next))
      }
    )
  }

  private var combineBinding: Binding<MaskCombineOperation> {
    Binding(
      get: { model.maskTool.combine },
      set: { operation in
        var next = model.maskTool
        next.combine = operation
        send(.setMaskTool(next))
      }
    )
  }

  /// Copies the standing document selection into the selected layer, then
  /// points the masks tool at the new mask so its components can be edited.
  private func applySelectionAsMask() {
    guard model.recipe.selection != nil, let layer = targetLayer else { return }
    let maskID = MaskID()
    send(.change(.saveSelectionAsMask(layer.id, maskID), interactive: false))
    send(.activateMask(maskID, on: layer.id))
  }

  private var selectionSummary: String {
    guard let selection = model.recipe.selection else {
      return "Make a selection first, then apply it as a mask."
    }
    return selection.selectsNothing ? "Nothing is selected." : selection.summary
  }

  /// Adds a component that needs no canvas gesture: subject, person or
  /// background. One named undoable step either way, whether it starts a new
  /// mask or joins the active one.
  private func addGeneratedComponent(_ kind: MaskGeneratorKind) {
    guard let layer = targetLayer, kind.availability.isAvailable else { return }
    let component = MaskComponent(
      generator: kind.defaultGenerator(),
      combine: model.maskTool.combine,
      feather: model.maskTool.feather
    )
    if let existing = model.maskTool.activeMask(in: model.recipe.layerStack),
      model.maskTool.activeLayerID == layer.id
    {
      send(
        .change(
          .setMask(layer.id, existing.adding(component), actionName: "Add \(kind.label) to Mask"),
          interactive: false
        ))
      return
    }
    let mask = MaskRecipe(
      name: layer.availableMaskName(kind.label),
      components: [component]
    )
    send(.change(.addMask(layer.id, mask), interactive: false))
    send(.activateMask(mask.id, on: layer.id))
  }
}

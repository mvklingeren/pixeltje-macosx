import PixeltjeMacDomain
import SwiftUI

/// What the crop tool's settings ask of the document.
///
/// The settings never mutate the recipe themselves. While the tool is open they
/// edit the uncommitted draft; `commit` is the single point where the crop
/// becomes one named undoable step, exactly as Return on the canvas does.
enum CropToolIntent: Equatable {
  case begin
  case setTarget(CropTarget)
  case updateDraft(CropRecipe, interactive: Bool)
  case commit
  case cancel
}

/// The Crop tool's settings, for the left panel.
///
/// Self-contained on purpose: it takes the editor model and one closure, and
/// knows nothing about the panel that hosts it, the split view it sits in, or
/// the canvas that draws the same draft.
struct CropToolSettingsView: View {
  @ObservedObject var model: EditorModel
  let send: (CropToolIntent) -> Void

  /// The custom ratio's own fields, so typing a half-finished ratio does not
  /// disturb the crop until both numbers are usable.
  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias DoubleState = SwiftUI.State<Double>
  @DoubleState private var customWidth = 3.0
  @DoubleState private var customHeight = 2.0

  private static let customSelection = "Custom"

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Crop & Straighten", systemImage: "crop")
        .font(.headline)

      if let draft = model.cropDraft {
        targetSection(draft.target)
        let crop = draft.recipe
        aspectSection(crop)
        angleSection(crop, enabled: supportsStraighten(draft.target))
        overlaySection(crop)
        resultSection(crop)
        buttons(crop)
      } else {
        Text(
          "Choose the Crop tool from the toolbox, or press C while the canvas is active, "
            + "to place a crop rectangle on the image."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      if model.cropDraft == nil { send(.begin) }
    }
  }

  private func targetSection(_ target: CropTarget) -> some View {
    GroupBox("Target") {
      Picker("Target", selection: Binding(
        get: { target },
        set: { send(.setTarget($0)) }
      )) {
        if let id = model.recipe.layerStack.activeLayerID,
          model.recipe.layerStack.canCropLayer(id),
          let layer = model.recipe.layerStack.layer(id: id)
        {
          Text("Selected Layer — \(layer.name)").tag(CropTarget.layer(id))
        }
        Text("Canvas — All Layers").tag(CropTarget.canvas)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Aspect ratio

  private func aspectSection(_ crop: CropRecipe) -> some View {
    GroupBox("Aspect ratio") {
      VStack(alignment: .leading, spacing: 8) {
        Picker("Ratio", selection: aspectSelection(crop)) {
          ForEach(CropAspectRatio.presets) { preset in
            Text(preset.name).tag(preset.name)
          }
          Text(Self.customSelection).tag(Self.customSelection)
        }
        .labelsHidden()
        .pickerStyle(.menu)

        if crop.aspectRatio.presetName == nil {
          HStack(spacing: 6) {
            TextField("Width", value: $customWidth, format: .number)
              .frame(width: 58)
            Text(":")
            TextField("Height", value: $customHeight, format: .number)
              .frame(width: 58)
            Button("Set") { apply(aspect: customAspect, to: crop) }
          }
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
        }

        Button {
          apply(aspect: swappedAspect(crop), to: crop)
        } label: {
          Label("Swap orientation", systemImage: "rotate.right")
        }
        .controlSize(.small)
        .disabled(isFreeAspect(crop))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func aspectSelection(_ crop: CropRecipe) -> Binding<String> {
    Binding(
      get: { crop.aspectRatio.presetName ?? Self.customSelection },
      set: { name in
        if name == Self.customSelection {
          apply(aspect: customAspect, to: crop)
        } else if let preset = CropAspectRatio.presets.first(where: { $0.name == name }) {
          apply(aspect: preset.aspect, to: crop)
        }
      }
    )
  }

  private var customAspect: CropAspectRatio {
    guard customWidth > 0, customHeight > 0 else { return .free }
    return .ratio(width: customWidth, height: customHeight)
  }

  private func isFreeAspect(_ crop: CropRecipe) -> Bool {
    crop.aspectRatio == .free
  }

  private func swappedAspect(_ crop: CropRecipe) -> CropAspectRatio {
    let size = imageSize
    return crop.aspectRatio.swapped(imageWidth: size.width, imageHeight: size.height)
  }

  private func apply(aspect: CropAspectRatio, to crop: CropRecipe) {
    let size = imageSize
    let updated = CropGeometry.settingAspect(
      aspect,
      on: crop,
      imageWidth: size.width,
      imageHeight: size.height
    )
    send(.updateDraft(updated, interactive: false))
  }

  // MARK: - Straighten

  private func angleSection(_ crop: CropRecipe, enabled: Bool) -> some View {
    GroupBox("Straighten") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Angle")
          Spacer()
          TextField(
            "Angle",
            value: Binding(
              get: { crop.angleDegrees },
              set: { apply(angle: $0, to: crop, interactive: false) }
            ),
            format: .number.precision(.fractionLength(2))
          )
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(width: 72)
          Text("°")
            .foregroundStyle(.secondary)
        }
        .font(.caption)

        Slider(
          value: Binding(
            get: { crop.angleDegrees },
            set: { apply(angle: $0, to: crop, interactive: true) }
          ),
          in: -CropRecipe.maximumAngleDegrees...CropRecipe.maximumAngleDegrees
        )

        Button("Level") { apply(angle: 0, to: crop, interactive: false) }
          .controlSize(.small)
          .disabled(crop.angleDegrees == 0)

        Text("The image turns underneath the rectangle, which shrinks to keep real pixels.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !enabled {
          Text("Choose a pixel layer or a RAW canvas to straighten.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .disabled(!enabled)
  }

  private func apply(angle: Double, to crop: CropRecipe, interactive: Bool) {
    let size = imageSize
    let updated = CropGeometry.settingAngle(
      angle,
      on: crop,
      imageWidth: size.width,
      imageHeight: size.height
    )
    guard updated != crop else { return }
    send(.updateDraft(updated, interactive: interactive))
  }

  // MARK: - Overlay

  private func overlaySection(_ crop: CropRecipe) -> some View {
    GroupBox("Overlay") {
      Picker("Overlay", selection: overlaySelection(crop)) {
        ForEach(CropOverlay.allCases, id: \.self) { overlay in
          Text(overlay.label).tag(overlay)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func overlaySelection(_ crop: CropRecipe) -> Binding<CropOverlay> {
    Binding(
      get: { crop.overlay },
      set: { overlay in
        var updated = crop
        updated.overlay = overlay
        send(.updateDraft(updated, interactive: false))
      }
    )
  }

  // MARK: - Result and commands

  private func resultSection(_ crop: CropRecipe) -> some View {
    let size = imageSize
    let cropped = CropGeometry.croppedPixelSize(
      crop,
      imageWidth: size.width,
      imageHeight: size.height
    )
    return VStack(alignment: .leading, spacing: 2) {
      LabeledContent("Result", value: "\(cropped.width) × \(cropped.height) px")
      if let ratio = CropGeometry.pixelAspect(
        crop, imageWidth: size.width, imageHeight: size.height)
      {
        LabeledContent(
          "Ratio", value: ratio.formatted(.number.precision(.fractionLength(3))) + " : 1")
      }
    }
    .font(.caption)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func buttons(_ crop: CropRecipe) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        // No keyboard shortcuts here: Return and Escape belong to the canvas,
        // which has them while the image has focus.
        Button("Apply") { send(.commit) }
        Button("Cancel") { send(.cancel) }
        Spacer()
        Button("Reset") { reset(crop) }
      }
      .controlSize(.small)

      Text("Return applies the crop as one undoable step. Escape leaves the image as it was.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("Drag to draw a new crop. Option-drag inside the outline to move it.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Back to the largest crop the current lock allows, with the straighten
  /// levelled. A free lock therefore resets to the whole frame.
  private func reset(_ crop: CropRecipe) {
    let size = imageSize
    let updated = CropGeometry.maximumCrop(
      aspect: crop.aspectRatio,
      angleDegrees: 0,
      imageWidth: size.width,
      imageHeight: size.height,
      overlay: crop.overlay
    )
    send(.updateDraft(updated, interactive: false))
  }

  /// The oriented image the crop is measured against. Unit space is 1×1 before
  /// a render has reported a size, which keeps every ratio well defined.
  private var imageSize: (width: Double, height: Double) {
    model.cropDraft.flatMap { model.cropReferenceSize(for: $0.target) }
      ?? (width: 1, height: 1)
  }

  private func supportsStraighten(_ target: CropTarget) -> Bool {
    switch target {
    case .layer:
      true
    case .canvas:
      model.recipe.layerStack.layer(id: .rawBackground)?.isDevelopedRaw == true
    }
  }
}

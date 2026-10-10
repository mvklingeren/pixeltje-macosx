import PixeltjeMacDomain
import SwiftUI

enum InspectorIntent {
  case beginGesture
  case change(EditorAction, interactive: Bool)
  case endGesture(String)
  /// Asks for the file chooser. Views state the intent; the window controller
  /// owns the panel and the document owns the file.
  case addImage
  /// Arms or clears the clipping overlay. Display state, not an edit: it goes
  /// nowhere near the recipe or the undo stack, which is why it is its own
  /// intent rather than an `EditorAction`.
  case setClipping(ClippingIndicators)
  case setDifferencePreview(ProjectLayerID?)
  /// Asks for the opt-in RAW-only chooser. The window controller owns the
  /// preference gate, file panel, and document mutation.
  case addRaw
  /// Anything the mask list asks for. Masks are edited from both panels, so
  /// the one mask intent is forwarded from either side.
  case mask(MaskIntent)
  /// Selects the layer thumbnail or its mask thumbnail as the next paint
  /// destination. Targeting is tool state, not an undoable recipe change.
  case setPaintTarget(PaintTarget?)
  /// Layer-list selection is session state; Command-click extends it without
  /// changing the first-selected primary layer.
  case selectLayers(Set<ProjectLayerID>)
  case rasterizeLayer(ProjectLayerID)
  case mergeLayers(Set<ProjectLayerID>)
  case cancelLayerOperation
  /// Arms the white-balance picker over whatever tool is active. Tool state,
  /// not an edit: the recipe changes only when the resulting click lands.
  case pickWhiteBalance
  /// Returns temperature and tint to the captured defaults, as one step.
  case resetWhiteBalanceToAsShot
  /// Shows the captured RAW defaults instead of the current recipe. Display
  /// state, like `setClipping`: the recipe and the dirty flag are untouched.
  case toggleBefore
  /// Which objects inside the active vector layer are selected. Transient tool
  /// state shared with the canvas, exactly like a layer-list selection.
  case selectVectorObjects(Set<UUID>)
}

struct InspectorView: View {
  @ObservedObject var model: EditorModel
  let send: (InspectorIntent) -> Void

  // Right-panel disclosures are view state. Folding either section does not
  // alter the document or participate in undo.
  private typealias ExpandedState = SwiftUI.State<Bool>
  @ExpandedState private var isHistogramExpanded = true
  @ExpandedState private var isLayersExpanded = true

  private static let layerCompositionHelp =
    "Layers are composited from bottom to top with their blend mode, opacity and fill. "
    + "A group is composited on its own before it joins the layers beneath it, so an "
    + "adjustment layer changes only what sits below it inside its own group. Vector "
    + "artwork above the highest visible RAW layer remains resolution independent until "
    + "display or export."

  var body: some View {
    // Histogram at the top of the right panel, above the layer stack, so the
    // measurement of the frame stays visible while any layer is being edited.
    VStack(spacing: 0) {
      PanelDisclosureHeader(
        title: "Histogram",
        systemImage: "chart.bar.xaxis",
        isExpanded: isHistogramExpanded,
        helpText: "Composite histogram for the displayed image. "
          + "The triangles toggle shadow and highlight clipping."
      ) {
        withAnimation(.easeInOut(duration: 0.16)) { isHistogramExpanded.toggle() }
      }
      if isHistogramExpanded {
        HistogramView(model: model, send: send)
      }
      Divider()
      PanelDisclosureHeader(
        title: "Layers",
        systemImage: "square.3.layers.3d",
        isExpanded: isLayersExpanded,
        helpText: Self.layerCompositionHelp
      ) {
        withAnimation(.easeInOut(duration: 0.16)) { isLayersExpanded.toggle() }
      }
      if isLayersExpanded {
        LayersInspectorView(model: model, send: send)
      }
    }
    .frame(minWidth: 280, idealWidth: 330, maxHeight: .infinity, alignment: .top)
  }
}

/// Development controls for the selected RAW, linked-image, or paint layer.
///
/// Linked images and paint layers receive the shared post-source controls. RAW
/// layers add their decoder-specific source, preset, Apple RAW, lens, and upright
/// controls around that same shared stack.
struct DevelopLayerInspectorView: View {
  @ObservedObject var model: EditorModel
  let send: (InspectorIntent) -> Void

  // Source details are useful for diagnostics but take up substantial room in
  // the everyday develop workflow. Keep their disclosure state local to the
  // inspector and start with the details out of the way.
  private typealias ExpandedState = SwiftUI.State<Bool>
  @ExpandedState private var isSourceExpanded = false

  var body: some View {
    if let layer = selectedDevelopLayer {
      VStack(alignment: .leading, spacing: 14) {
        if let raw = currentRawLayer {
          source
          if let parameters = raw.rawDevelopment.parameters {
            RawPresetPicker(
              store: .shared,
              layerID: layer.id,
              parameters: parameters,
              capturedDefaults: raw.rawDevelopment.capturedDefaults,
              capabilities: raw.rawDevelopment.capabilities,
              send: send
            )
            DevelopSectionsView(model: model, layer: layer, send: send)
            rawControls(parameters, raw: raw, layerID: layer.id)
            lensAndUpright(parameters, raw: raw, layerID: layer.id)
            // Brightness, contrast and saturation from before the develop sections
            // existed. Shown only while a project still carries a non-neutral value,
            // so it can be reset; new edits go through the basic tone panel.
            if layer.id == .rawBackground,
              model.recipe.postProcessing != PostProcessingRecipe()
            {
              postControls
            }
          }
        } else {
          DevelopSectionsView(model: model, layer: layer, send: send)
        }
      }
    }
  }

  private var selectedDevelopLayer: ProjectLayer? {
    guard let layer = model.activeLayer, layer.supportsDevelopPanel else { return nil }
    return layer
  }

  /// Re-read this layer from the recipe on every body update. The selected
  /// `ProjectLayer` is a snapshot from the list; sliders must follow decoder
  /// metadata and edits as they arrive for this exact RAW layer.
  private var currentRawLayer: DevelopedRawLayer? {
    selectedDevelopLayer.flatMap { model.recipe.layerStack.layer(id: $0.id)?.developedRawLayer }
  }

  private var source: some View {
    GroupBox {
      DisclosureGroup(isExpanded: $isSourceExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          Text(currentRawLayer?.source?.originalFilename ?? "No RAW source")
            .lineLimit(2)
          if let decoder = currentRawLayer?.rawDevelopment.decoderVersion {
            LabeledContent("Apple decoder", value: decoder)
            LabeledContent(
              "Available",
              value: currentRawLayer?.rawDevelopment.supportedDecoderVersions.joined(separator: ", ") ?? ""
            )
          }
          if let linkedPath = currentRawLayer?.source?.linkedPath {
            LabeledContent("Linked file", value: linkedPath)
              .lineLimit(3)
              .truncationMode(.middle)
              .help(linkedPath)
          }
          Text(
            "The project links to this file and never copies it. Saving stores the recipe only, "
              + "so the original stays the single source of truth."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Text("Source")
          .font(.headline)
      }
      .accessibilityValue(isSourceExpanded ? "Expanded" : "Collapsed")
    }
  }

  private func rawControls(
    _ parameters: RawParameters,
    raw: DevelopedRawLayer,
    layerID: ProjectLayerID
  ) -> some View {
    GroupBox("Apple RAW") {
      VStack(spacing: 11) {
        // Exposure lives in the basic tone panel above, bound to this same
        // Apple RAW property.
        whiteBalanceRow
        slider("White balance", .neutralTemperature, parameters, raw: raw, layerID: layerID, range: 2_000...50_000, decimals: 0)
        slider("Tint", .neutralTint, parameters, raw: raw, layerID: layerID, range: -150...150, decimals: 0)
        slider("Shadow bias", .shadowBias, parameters, raw: raw, layerID: layerID, range: -1...1)
        // Apple's own boost. Renamed from "Tone curve" so it is not confused
        // with the tone curve panel, which is a post-RAW edit. The recipe key
        // stays `boostAmount`, so saved projects are unaffected.
        slider("Tone boost", .boostAmount, parameters, raw: raw, layerID: layerID, range: 0...1)
        slider("Shadow boost", .boostShadowAmount, parameters, raw: raw, layerID: layerID, range: 0...2)
        // Sharpness, detail, moiré, despeckle and the two noise-reduction
        // amounts live in the detail panel above, bound to these same Apple
        // RAW properties and gated by the same capabilities.
        sliderIfSupported("Local contrast", .contrast, parameters, raw: raw, layerID: layerID, range: 0...1)
        sliderIfSupported("Local tone map", .localToneMap, parameters, raw: raw, layerID: layerID, range: 0...1)
        slider("EDR", .extendedDynamicRange, parameters, raw: raw, layerID: layerID, range: 0...2)

        toggleIfSupported("Highlight recovery", .highlightRecovery, parameters, raw: raw, layerID: layerID)
        // Lens correction lives in its own section below, beside upright.
        rawToggle("Gamut mapping", .gamutMapping, parameters, layerID: layerID)

        Button("Reset Apple RAW") {
          send(.change(.resetRawLayer(layerID), interactive: false))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .padding(.vertical, 2)
    }
  }

  /// The eyedropper and As Shot, above the two sliders they write.
  ///
  /// They live here rather than in the tool strip because that is what they
  /// act on: the picker sets temperature and tint, and As Shot puts those two
  /// back. In the strip the eyedropper was a second identical icon next to the
  /// foreground-colour sampler, and As Shot had no slider beside it to explain
  /// what it reset. Neither is a tool — the picker arms a one-shot request over
  /// whichever tool is active.
  private var whiteBalanceRow: some View {
    HStack(spacing: 6) {
      Button {
        send(.pickWhiteBalance)
      } label: {
        Label("Pick White Balance", systemImage: "eyedropper")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(!model.canPickWhiteBalance)
      .background(pickerIsArmed ? Color.accentColor.opacity(0.25) : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      .help(
        model.canPickWhiteBalance
          ? "Click a grey or white part of the image to neutralize it (I) · ⌥ click keeps picking"
          : "The white-balance picker needs a RAW whose white balance the decoder has reported."
      )
      .accessibilityLabel("Pick white balance")
      .accessibilityValue(pickerIsArmed ? "Armed" : "Not armed")

      Button("As Shot") {
        send(.resetWhiteBalanceToAsShot)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(!model.whiteBalanceDiffersFromAsShot)
      .help(
        model.whiteBalanceDiffersFromAsShot
          ? "Return temperature and tint to the values the file was shot with"
          : "White balance already matches the camera's captured settings."
      )

      Spacer(minLength: 0)

      if let preview = model.pendingSample?.preview,
        model.pendingSample?.purpose == .whiteBalance
      {
        // The hovered pixel's result, so two candidate patches can be compared
        // here as well as on the canvas.
        Text(preview.summary)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption)
  }

  private var pickerIsArmed: Bool {
    model.pendingSample?.purpose == .whiteBalance
  }

  /// Lens correction and upright, the two geometry corrections of the develop
  /// panel.
  ///
  /// Lens correction is Apple's own: it is the supported public `CIRAWFilter`
  /// lens-correction property and nothing else, so when the installed RAW
  /// system does not support it for this camera the switch is shown disabled
  /// with the reason rather than replaced by a guessed equivalent.
  ///
  /// Upright is manual. It is a post-RAW perspective transform the user sets,
  /// with no automatic mode: Apple's public frameworks expose no deterministic
  /// perspective estimator, and guessing one is exactly what the RAW contract
  /// forbids.
  private func lensAndUpright(
    _ parameters: RawParameters,
    raw: DevelopedRawLayer,
    layerID: ProjectLayerID
  ) -> some View {
    let supportsLens =
      raw.rawDevelopment.capabilities?.supports(RawBoolParameter.lensCorrection) != false
    let upright = raw.upright
    return GroupBox("Lens & Upright") {
      VStack(alignment: .leading, spacing: 11) {
        rawToggle("Lens correction", .lensCorrection, parameters, layerID: layerID)
          .disabled(!supportsLens)
        Text(
          supportsLens
            ? "Apple's own distortion and vignette correction for this camera and lens, applied "
              + "inside the RAW decode."
            : "The installed macOS RAW support offers no lens correction for this file. Nothing "
              + "is substituted for it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Divider()

        Text("Upright")
          .font(.caption.weight(.semibold))
        uprightSlider("Vertical", value: upright.vertical, layerID: layerID) {
          var next = upright
          next.vertical = $0
          return next
        }
        uprightSlider("Horizontal", value: upright.horizontal, layerID: layerID) {
          var next = upright
          next.horizontal = $0
          return next
        }
        HStack {
          Text("Manual perspective correction. Crop away the empty wedges it leaves.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button("Reset") {
            send(.change(.setRawLayerUpright(layerID, UprightRecipe()), interactive: false))
          }
          .controlSize(.small)
          .disabled(!upright.isActive)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 2)
    }
  }

  private func uprightSlider(
    _ title: String,
    value: Double,
    layerID: ProjectLayerID,
    update: @escaping (Double) -> UprightRecipe
  ) -> some View {
    VStack(spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(value.formatted(.number.precision(.fractionLength(2))))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(
        value: Binding(
          get: { value },
          set: { send(.change(.setRawLayerUpright(layerID, update($0)), interactive: true)) }
        ),
        in: -1...1,
        onEditingChanged: { editing in
          if editing {
            send(.beginGesture)
          } else {
            send(.endGesture("Adjust Upright"))
          }
        }
      )
    }
    .font(.caption)
  }

  private var postControls: some View {
    let post = model.recipe.postProcessing
    return GroupBox("Legacy color controls") {
      VStack(spacing: 11) {
        Text("Older project values. Use the basic tone panel for new edits.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        postSlider("Brightness", value: post.brightness, range: -1...1) {
          var next = post
          next.brightness = $0
          return next
        }
        postSlider("Contrast", value: post.contrast, range: 0.25...4) {
          var next = post
          next.contrast = $0
          return next
        }
        postSlider("Saturation", value: post.saturation, range: 0...2) {
          var next = post
          next.saturation = $0
          return next
        }
        Button("Reset legacy controls") {
          send(.change(.setPostProcessing(PostProcessingRecipe()), interactive: false))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .padding(.vertical, 2)
    }
  }

  private func sliderIfSupported(
    _ title: String,
    _ parameter: RawFloatParameter,
    _ values: RawParameters,
    raw: DevelopedRawLayer,
    layerID: ProjectLayerID,
    range: ClosedRange<Double>
  ) -> AnyView {
    guard raw.rawDevelopment.capabilities?.supports(parameter) != false else {
      return AnyView(EmptyView())
    }
    return AnyView(slider(title, parameter, values, raw: raw, layerID: layerID, range: range))
  }

  /// One Apple RAW slider.
  ///
  /// Double-clicking the label row returns the control to the value the file
  /// was captured with, as its own undoable step — the same gesture every
  /// develop slider offers through `AdjustmentSlider`. These sliders were the
  /// exception for no reason other than age, which left the as-shot white
  /// balance reachable only through Reset Apple RAW, an all-or-nothing reset
  /// that costs the exposure and the tone settings to undo one pick.
  private func slider(
    _ title: String,
    _ parameter: RawFloatParameter,
    _ values: RawParameters,
    raw: DevelopedRawLayer,
    layerID: ProjectLayerID,
    range: ClosedRange<Double>,
    decimals: Int = 2
  ) -> some View {
    let captured = raw.rawDevelopment.capturedDefaults?[parameter]
    return VStack(spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(values[parameter].formatted(.number.precision(.fractionLength(decimals))))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2) { resetToCaptured(parameter, values, captured, layerID: layerID) }
      .help(
        captured == nil
          ? "\(title). No captured default to reset to."
          : "Double-click to reset \(title.lowercased()) to as shot"
      )
      Slider(
        value: Binding(
          get: { values[parameter] },
          set: { send(.change(.setRawLayerFloat(layerID, parameter, $0), interactive: true)) }
        ),
        in: range,
        onEditingChanged: { gestureChanged($0, named: title) }
      )
      .simultaneousGesture(
        TapGesture(count: 2).onEnded { resetToCaptured(parameter, values, captured, layerID: layerID) })
    }
    .font(.caption)
  }

  /// Puts one Apple RAW parameter back to its captured default.
  ///
  /// Silent when there is no captured default to return to, or when the value
  /// is already there: a double-click that changes nothing should not spend an
  /// undo step.
  private func resetToCaptured(
    _ parameter: RawFloatParameter,
    _ values: RawParameters,
    _ captured: Double?,
    layerID: ProjectLayerID
  ) {
    guard let captured, values[parameter] != captured else { return }
    send(.change(.setRawLayerFloat(layerID, parameter, captured), interactive: false))
  }

  private func rawToggle(
    _ title: String,
    _ parameter: RawBoolParameter,
    _ values: RawParameters,
    layerID: ProjectLayerID
  ) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { values[parameter] },
        set: { send(.change(.setRawLayerBool(layerID, parameter, $0), interactive: false)) }
      )
    )
  }

  @ViewBuilder
  private func toggleIfSupported(
    _ title: String,
    _ parameter: RawBoolParameter,
    _ values: RawParameters,
    raw: DevelopedRawLayer,
    layerID: ProjectLayerID
  ) -> some View {
    if raw.rawDevelopment.capabilities?.supports(parameter) != false {
      rawToggle(title, parameter, values, layerID: layerID)
    }
  }

  private func postSlider(
    _ title: String,
    value: Double,
    range: ClosedRange<Double>,
    update: @escaping (Double) -> PostProcessingRecipe
  ) -> some View {
    VStack(spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(value.formatted(.number.precision(.fractionLength(2))))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(
        value: Binding(
          get: { value },
          set: { send(.change(.setPostProcessing(update($0)), interactive: true)) }
        ),
        in: range,
        onEditingChanged: { gestureChanged($0, named: title) }
      )
    }
    .font(.caption)
  }

  /// One drag is one named history step: the control's own label, so the
  /// history panel reads as a list of what was changed.
  private func gestureChanged(_ editing: Bool, named name: String) {
    if editing {
      send(.beginGesture)
    } else {
      send(.endGesture(name))
    }
  }
}

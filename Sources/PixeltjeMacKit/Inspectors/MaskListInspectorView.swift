import PixeltjeMacDomain
import SwiftUI

/// The mask list for one layer, with each mask's components and its own
/// adjustment.
///
/// The placement rule puts this in the right panel, under the layer it belongs
/// to: masks are part of the layer, not of the project, so they are shown where
/// the layer is.
struct MaskListInspectorView: View {
  let layer: ProjectLayer
  let activeMaskID: MaskID?
  let send: (MaskIntent) -> Void

  var body: some View {
    RightPanelDisclosureSection(
      "Masks",
      id: "masks",
      systemImage: "square.dashed"
    ) {
      VStack(alignment: .leading, spacing: 10) {
        if layer.masks.isEmpty {
          Text(
            "No masks. Choose the Masks tool, pick a mask type in the left panel, and drag or "
              + "click on the canvas."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        } else {
          ForEach(layer.masks) { mask in
            MaskRowView(
              layerID: layer.id,
              mask: mask,
              isActive: mask.id == activeMaskID,
              send: send
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } accessory: {
      Text(layer.masks.count, format: .number)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

/// One mask: what it is made of, whether it is on, its per-mask adjustment.
private struct MaskRowView: View {
  let layerID: ProjectLayerID
  let mask: MaskRecipe
  let isActive: Bool
  let send: (MaskIntent) -> Void

  private typealias ExpandedState = SwiftUI.State<Bool>
  @ExpandedState private var isExpanded: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if isExpanded {
        components
        Divider()
        maskControls
        adjustmentSection
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : .clear)
    )
    .contentShape(Rectangle())
    .onTapGesture { send(.activateMask(mask.id, on: layerID)) }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Button {
        isExpanded.toggle()
      } label: {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption2)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "Collapse \(mask.name)" : "Expand \(mask.name)")

      Button {
        send(.change(.setMaskEnabled(layerID, mask.id, !mask.isEnabled), interactive: false))
      } label: {
        Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .foregroundStyle(mask.isEnabled ? Color.primary : Color.secondary)
      .accessibilityLabel(mask.isEnabled ? "Hide \(mask.name)" : "Show \(mask.name)")

      VStack(alignment: .leading, spacing: 1) {
        Text(mask.name)
          .font(.callout)
          .lineLimit(1)
        Text(mask.summary)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if mask.adjustment != nil {
        Image(systemName: "circle.lefthalf.filled")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .help("This mask carries its own adjustment")
      }
      Button {
        send(.change(.removeMask(layerID, mask.id), interactive: false))
      } label: {
        Image(systemName: "trash")
          .font(.caption2)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Delete \(mask.name)")
    }
  }

  private var components: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(mask.components) { component in
        MaskComponentRowView(
          layerID: layerID,
          mask: mask,
          component: component,
          isFirst: component.id == mask.components.first?.id,
          send: send
        )
      }
    }
  }

  private var maskControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        "Invert mask",
        isOn: Binding(
          get: { mask.isInverted },
          set: { value in
            var next = mask
            next.isInverted = value
            commit(next, "Invert Mask")
          }
        )
      )
      .font(.caption)
      .toggleStyle(.checkbox)

      MaskSlider(
        title: "Feather",
        value: mask.feather,
        range: 0...400,
        decimals: 0,
        onChange: { value, interactive in
          var next = mask
          next.feather = value
          commit(next, "Feather Mask", interactive: interactive)
        },
        send: send,
        gestureName: "Feather Mask"
      )
    }
  }

  @ViewBuilder
  private var adjustmentSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Adjustment")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Menu {
          Button("None") {
            send(.change(.setMaskAdjustment(layerID, mask.id, nil), interactive: false))
          }
          Divider()
          // Rich adjustment layers have dedicated editors in the Layers
          // inspector. A mask can still carry and render any serialized
          // adjustment recipe, but this compact menu offers the three kinds
          // whose complete controls fit here.
          ForEach(
            [AdjustmentKind.exposure, .colorControls, .invert], id: \.self
          ) { kind in
            Button(kind.label) {
              send(
                .change(
                  .setMaskAdjustment(layerID, mask.id, kind.defaultRecipe),
                  interactive: false
                ))
            }
          }
        } label: {
          Text(mask.adjustment?.label ?? "None")
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }

      if let adjustment = mask.adjustment {
        MaskAdjustmentControls(
          layerID: layerID,
          maskID: mask.id,
          adjustment: adjustment,
          send: send
        )
        Text("Applied only where this mask is opaque.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func commit(_ mask: MaskRecipe, _ actionName: String, interactive: Bool = false) {
    send(.change(.setMask(layerID, mask, actionName: actionName), interactive: interactive))
  }
}

/// One generator inside a mask, with its combine operation and its own
/// parameters.
private struct MaskComponentRowView: View {
  let layerID: ProjectLayerID
  let mask: MaskRecipe
  let component: MaskComponent
  let isFirst: Bool
  let send: (MaskIntent) -> Void

  private typealias ExpandedState = SwiftUI.State<Bool>
  @ExpandedState private var isExpanded: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Button {
          isExpanded.toggle()
        } label: {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
        }
        .buttonStyle(.plain)

        Image(systemName: component.kind.symbolName)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(component.name)
          .font(.caption)
          .lineLimit(1)
        Spacer()
        if isFirst {
          Text("base")
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
          Picker("Combine", selection: combineBinding) {
            ForEach(MaskCombineOperation.allCases, id: \.self) { operation in
              Image(systemName: operation.symbolName).tag(operation)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 96)
          .controlSize(.mini)
        }
        Button {
          commit(mask.removing(component.id), "Delete Mask Component")
        } label: {
          Image(systemName: "minus.circle")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete \(component.name)")
      }

      if let reason = component.availability.unavailableReason {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      if isExpanded {
        parameters
      }
    }
  }

  @ViewBuilder
  private var parameters: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        "Invert component",
        isOn: Binding(
          get: { component.isInverted },
          set: { value in update("Invert Mask Component") { $0.isInverted = value } }
        )
      )
      .font(.caption2)
      .toggleStyle(.checkbox)

      slider("Density", component.density, 0...1, decimals: 2, "Change Mask Density") {
        value, target in target.density = value
      }
      slider("Feather", component.feather, 0...400, decimals: 0, "Feather Mask Component") {
        value, target in target.feather = value
      }

      switch component.generator {
      case .radialGradient(let gradient):
        slider("Radius", gradient.radius, 0.01...1.5, decimals: 2, "Resize Radial Mask") {
          value, target in
          target.generator = .radialGradient(
            RadialGradientMask(
              center: gradient.center,
              radius: value,
              softness: gradient.softness,
              coversInside: gradient.coversInside
            ))
        }
        slider("Softness", gradient.softness, 0...1, decimals: 2, "Soften Radial Mask") {
          value, target in
          target.generator = .radialGradient(
            RadialGradientMask(
              center: gradient.center,
              radius: gradient.radius,
              softness: value,
              coversInside: gradient.coversInside
            ))
        }
      case .luminanceRange(let range):
        slider("Low", range.lowerBound, -1...4, decimals: 2, "Change Luminance Range") {
          value, target in
          target.generator = .luminanceRange(
            LuminanceRangeMask(
              lowerBound: value,
              upperBound: max(range.upperBound, value),
              lowerFalloff: range.lowerFalloff,
              upperFalloff: range.upperFalloff
            ))
        }
        slider("High", range.upperBound, -1...8, decimals: 2, "Change Luminance Range") {
          value, target in
          target.generator = .luminanceRange(
            LuminanceRangeMask(
              lowerBound: min(range.lowerBound, value),
              upperBound: value,
              lowerFalloff: range.lowerFalloff,
              upperFalloff: range.upperFalloff
            ))
        }
      case .colorRange(let range):
        slider("Tolerance", range.tolerance, 0.01...1, decimals: 2, "Change Color Range") {
          value, target in
          target.generator = .colorRange(
            ColorRangeMask(sample: range.sample, tolerance: value, smoothness: range.smoothness))
        }
        slider("Smoothness", range.smoothness, 0...1, decimals: 2, "Change Color Range") {
          value, target in
          target.generator = .colorRange(
            ColorRangeMask(
              sample: range.sample, tolerance: range.tolerance, smoothness: value))
        }
      case .brush(let strokes):
        Text(
          strokes.strokes.count == 1
            ? "1 stroke stored as geometry."
            : "\(strokes.strokes.count) strokes stored as geometry."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      case .strokeSurface(let surface):
        Text(
          surface.strokes.count == 1
            ? "1 deterministic Metal brush stroke."
            : "\(surface.strokes.count) deterministic Metal brush strokes."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      case .rectangle(let shape), .ellipse(let shape):
        Text(
          "\(shape.width.formatted(.number.precision(.fractionLength(2))))"
            + " × \(shape.height.formatted(.number.precision(.fractionLength(2))))"
            + " of the canvas."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      case .polygon(let polygon):
        Text(
          polygon.points.count == 1
            ? "1 point stored as geometry."
            : "\(polygon.points.count) points stored as geometry."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      case .raster(let raster):
        Text("\(raster.runs.count) captured contiguous runs at \(raster.width) × \(raster.height).")
          .font(.caption2)
          .foregroundStyle(.secondary)
      case .placedRaster(let placed):
        Text("\(placed.raster.runs.count) selection runs at \(placed.raster.width) × \(placed.raster.height).")
          .font(.caption2)
          .foregroundStyle(.secondary)
      case .linearGradient, .subject, .person, .background, .sky:
        EmptyView()
      }
    }
    .padding(.leading, 18)
  }

  private func slider(
    _ title: String,
    _ value: Double,
    _ range: ClosedRange<Double>,
    decimals: Int,
    _ actionName: String,
    _ update: @escaping (Double, inout MaskComponent) -> Void
  ) -> some View {
    MaskSlider(
      title: title,
      value: value,
      range: range,
      decimals: decimals,
      onChange: { newValue, interactive in
        commit(
          mask.updatingComponent(component.id) { update(newValue, &$0) },
          actionName,
          interactive: interactive
        )
      },
      send: send,
      gestureName: actionName
    )
  }

  private var combineBinding: Binding<MaskCombineOperation> {
    Binding(
      get: { component.combine },
      set: { operation in
        update("Change Mask Combine Mode") { $0.combine = operation }
      }
    )
  }

  private func update(_ actionName: String, _ mutate: @escaping (inout MaskComponent) -> Void) {
    commit(mask.updatingComponent(component.id, mutate), actionName)
  }

  private func commit(_ mask: MaskRecipe, _ actionName: String, interactive: Bool = false) {
    send(.change(.setMask(layerID, mask, actionName: actionName), interactive: interactive))
  }
}

/// The parameters of a mask's own adjustment.
private struct MaskAdjustmentControls: View {
  let layerID: ProjectLayerID
  let maskID: MaskID
  let adjustment: AdjustmentRecipe
  let send: (MaskIntent) -> Void

  var body: some View {
    switch adjustment {
    case .exposure(let ev):
      MaskSlider(
        title: "Exposure",
        value: ev,
        range: -5...5,
        decimals: 2,
        onChange: { value, interactive in
          commit(.exposure(ev: value), interactive: interactive)
        },
        send: send,
        gestureName: "Adjust Mask"
      )
    case .colorControls(let brightness, let contrast, let saturation):
      VStack(alignment: .leading, spacing: 6) {
        MaskSlider(
          title: "Brightness", value: brightness, range: -1...1, decimals: 2,
          onChange: { value, interactive in
            commit(
              .colorControls(brightness: value, contrast: contrast, saturation: saturation),
              interactive: interactive)
          },
          send: send, gestureName: "Adjust Mask")
        MaskSlider(
          title: "Contrast", value: contrast, range: 0.25...4, decimals: 2,
          onChange: { value, interactive in
            commit(
              .colorControls(brightness: brightness, contrast: value, saturation: saturation),
              interactive: interactive)
          },
          send: send, gestureName: "Adjust Mask")
        MaskSlider(
          title: "Saturation", value: saturation, range: 0...2, decimals: 2,
          onChange: { value, interactive in
            commit(
              .colorControls(brightness: brightness, contrast: contrast, saturation: value),
              interactive: interactive)
          },
          send: send, gestureName: "Adjust Mask")
      }
    case .curves:
      Text("This mask carries a Curves recipe.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    case .levels:
      Text("This mask carries a Levels recipe.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    case .hueSaturation:
      Text("This mask carries a Hue & Saturation recipe.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    case .blackAndWhite:
      Text("This mask carries a Black & White recipe.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    case .colorLookup:
      Text("This mask carries a Color Lookup recipe.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    case .gradientMap:
      Text("This mask carries a Gradient Map recipe.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    case .invert:
      Text("Inverts the pixels this mask selects.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func commit(_ adjustment: AdjustmentRecipe, interactive: Bool) {
    send(.change(.setMaskAdjustment(layerID, maskID, adjustment), interactive: interactive))
  }
}

/// A labelled slider that brackets its drag in one undoable step.
private struct MaskSlider: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  var decimals: Int = 2
  let onChange: (Double, Bool) -> Void
  let send: (MaskIntent) -> Void
  let gestureName: String

  var body: some View {
    VStack(spacing: 2) {
      HStack {
        Text(title)
        Spacer()
        Text(value.formatted(.number.precision(.fractionLength(decimals))))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(
        value: Binding(
          get: { min(max(value, range.lowerBound), range.upperBound) },
          set: { onChange($0, true) }
        ),
        in: range,
        onEditingChanged: { editing in
          if editing {
            send(.beginGesture)
          } else {
            send(.endGesture(gestureName))
          }
        }
      )
    }
    .font(.caption2)
  }
}

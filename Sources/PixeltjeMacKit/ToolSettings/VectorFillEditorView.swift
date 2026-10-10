import PixeltjeMacDomain
import SwiftUI

/// What a vector object's fill is, and how to change it.
///
/// One editor serves the selected objects and the tool's default for the next
/// object, so a gradient is built the same way whether or not anything is
/// selected. Every change is reported as a complete replacement fill; the
/// caller decides where it lands and what the history step is called.
struct VectorFillEditorView: View {
  /// The fill being edited, or nil for no fill.
  let fill: VectorFillStyle?
  /// Whether the selection disagrees about its fill.
  let isMixed: Bool
  /// The canvas extent, so angles and lengths can be reported in pixels rather
  /// than in the anisotropic normalized space the geometry is stored in.
  let canvasWidth: Double
  let canvasHeight: Double
  /// The color to switch a fill back on with, when the objects have none. It
  /// is the shared background, so turning a fill off and on again returns the
  /// color it was filled with rather than a stock white.
  let colorWhenEnabled: VectorColor
  let isEnabled: Bool
  /// Replaces the fill. `interactive` marks a value still being dragged.
  let apply: (VectorFillStyle?, _ actionName: String, _ interactive: Bool) -> Void
  /// Brackets a drag so it collapses into one undo step.
  let gesture: (_ isEditing: Bool, _ actionName: String) -> Void

  @ObservedObject private var library = VectorGradientLibrary.shared

  private typealias SelectionState = SwiftUI.State<UUID?>
  @SelectionState private var selectedStopID: UUID?

  private enum FillMode: String, CaseIterable, Identifiable {
    case none
    case solid
    case linear
    case radial

    var id: String { rawValue }

    var label: String {
      switch self {
      case .none: "None"
      case .solid: "Solid"
      case .linear: "Linear"
      case .radial: "Radial"
      }
    }

    var symbolName: String {
      switch self {
      case .none: "slash.circle"
      case .solid: "square.fill"
      case .linear: "square.righthalf.filled"
      case .radial: "circle.righthalf.filled"
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Fill").font(.subheadline).bold()
        Spacer()
        if isMixed {
          Text("Mixed").font(.caption2).foregroundStyle(.secondary)
        }
      }

      Picker("Fill type", selection: modeBinding) {
        ForEach(FillMode.allCases) { mode in
          Label(mode.label, systemImage: mode.symbolName).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Fill type")

      switch mode {
      case .none:
        Text("This object is not filled. Its stroke, if it has one, still draws.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      case .solid:
        solidControls
      case .linear, .radial:
        gradientControls
      }
    }
    .disabled(!isEnabled)
  }

  // MARK: - Solid

  private var solidControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      ColorPicker("Background", selection: solidColorBinding, supportsOpacity: true)
        .help("The window's background color, which a solid fill and the far end of a gradient share.")
      opacitySlider
    }
  }

  private var solidColorBinding: Binding<Color> {
    Binding(
      get: { (fill?.color ?? .white).swiftUIColor },
      set: { color in
        var next = fill ?? VectorFillStyle(color: .white)
        next.color = VectorColor(color)
        apply(next, "Change Vector Fill", false)
      }
    )
  }

  // MARK: - Gradient

  @ViewBuilder
  private var gradientControls: some View {
    if let gradient {
      VStack(alignment: .leading, spacing: 8) {
        GradientRampView(gradient: gradient, selectedStopID: selectedStopID)
          .frame(height: 26)
          .accessibilityLabel("Gradient preview")
          .accessibilityValue(rampDescription(gradient))

        stopList(gradient)
        stopActions(gradient)
        Divider()
        if let stop = selectedStop(in: gradient) {
          stopControls(gradient, stop: stop)
          Divider()
        }
        geometryControls(gradient)
        opacitySlider
        Divider()
        presetRow
      }
    }
  }

  private func stopList(_ gradient: VectorGradient) -> some View {
    VStack(spacing: 2) {
      ForEach(gradient.stops) { stop in
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 3)
            .fill(stop.color.swiftUIColor)
            .frame(width: 16, height: 16)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.5)))
          Text(percentage(stop.position))
            .font(.caption)
            .monospacedDigit()
          Spacer()
          if stop.id == selectedStopID {
            Image(systemName: "checkmark")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(stop.id == selectedStopID
              ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.05))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(stop.id == selectedStopID ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedStopID = stop.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(stop.id == selectedStopID ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Stop at \(percentage(stop.position))")
      }
    }
  }

  private func stopActions(_ gradient: VectorGradient) -> some View {
    HStack(spacing: 6) {
      Button {
        // A new stop lands in the widest gap, which is where there is room for
        // it and where the user is most likely to want one.
        let position = widestGapCenter(gradient)
        let updated = gradient.addingStop(at: position)
        selectedStopID = updated.stops.first { abs($0.position - position) < 0.000_1 }?.id
        applyGradient(updated, "Add Gradient Stop")
      } label: {
        Image(systemName: "plus")
      }
      .help("Add Stop")
      .accessibilityLabel("Add stop")

      Button {
        guard let id = selectedStopID else { return }
        applyGradient(gradient.removingStop(id: id), "Remove Gradient Stop")
        selectedStopID = nil
      } label: {
        Image(systemName: "minus")
      }
      .help("Remove Stop")
      .accessibilityLabel("Remove stop")
      .disabled(selectedStopID == nil || gradient.stops.count <= 2)

      Button {
        guard let id = selectedStopID else { return }
        applyGradient(gradient.duplicatingStop(id: id), "Duplicate Gradient Stop")
      } label: {
        Image(systemName: "plus.square.on.square")
      }
      .help("Duplicate Stop")
      .accessibilityLabel("Duplicate stop")
      .disabled(selectedStopID == nil)

      Divider().frame(height: 14)

      Button {
        applyGradient(gradient.reversingStops(), "Reverse Gradient")
      } label: {
        Image(systemName: "arrow.left.arrow.right")
      }
      .help("Reverse")
      .accessibilityLabel("Reverse gradient")

      Button {
        applyGradient(gradient.distributingStopsEvenly(), "Distribute Gradient Stops")
      } label: {
        Image(systemName: "equal")
      }
      .help("Distribute Evenly")
      .accessibilityLabel("Distribute stops evenly")
      .disabled(gradient.stops.count <= 2)

      Spacer()
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func stopControls(_ gradient: VectorGradient, stop: VectorGradientStop) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ColorPicker(
        "Stop color",
        selection: Binding(
          get: { stop.color.swiftUIColor },
          set: { color in
            applyGradient(
              gradient.updatingStop(id: stop.id) { $0.color = VectorColor(color) },
              "Change Gradient Stop")
          }),
        supportsOpacity: true)

      labeledSlider(
        "Position",
        value: stop.position,
        format: percentage(stop.position),
        actionName: "Move Gradient Stop"
      ) { value in
        applyGradient(
          gradient.updatingStop(id: stop.id) { $0.position = value },
          "Move Gradient Stop", interactive: true)
      }

      labeledSlider(
        "Midpoint",
        value: stop.midpoint,
        format: percentage(stop.midpoint),
        actionName: "Change Gradient Midpoint"
      ) { value in
        applyGradient(
          gradient.updatingStop(id: stop.id) { $0.midpoint = value },
          "Change Gradient Midpoint", interactive: true)
      }
      .disabled(stop.id == gradient.stops.last?.id)
    }
  }

  @ViewBuilder
  private func geometryControls(_ gradient: VectorGradient) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent("Angle") {
        HStack(spacing: 4) {
          TextField(
            "Angle",
            value: Binding(
              get: { angleDegrees(gradient) },
              set: { applyGradient(settingAngle($0, on: gradient), "Rotate Gradient") }),
            format: .number.precision(.fractionLength(1))
          )
          .frame(width: 62)
          .multilineTextAlignment(.trailing)
          Text("°").foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel("Gradient angle in degrees")

      LabeledContent(gradient.kind == .radial ? "Radius" : "Length") {
        HStack(spacing: 4) {
          TextField(
            "Length",
            value: Binding(
              get: { lengthInPixels(gradient) },
              set: { applyGradient(settingLength($0, on: gradient), "Resize Gradient") }),
            format: .number.precision(.fractionLength(0))
          )
          .frame(width: 62)
          .multilineTextAlignment(.trailing)
          Text("px").foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel(gradient.kind == .radial ? "Gradient radius" : "Gradient length")

      LabeledContent(gradient.kind == .radial ? "Center" : "Start") {
        HStack(spacing: 4) {
          pointField(gradient.start.x * canvasWidth, label: "X") { value in
            var updated = gradient
            updated.start.x = canvasWidth > 0 ? value / canvasWidth : updated.start.x
            applyGradient(updated, "Move Gradient")
          }
          pointField(gradient.start.y * canvasHeight, label: "Y") { value in
            var updated = gradient
            updated.start.y = canvasHeight > 0 ? value / canvasHeight : updated.start.y
            applyGradient(updated, "Move Gradient")
          }
        }
      }

      if gradient.kind == .radial {
        labeledSlider(
          "Ellipse",
          value: (gradient.aspectRatio - 0.1) / 2.9,
          format: gradient.aspectRatio.formatted(.number.precision(.fractionLength(2))),
          actionName: "Reshape Gradient"
        ) { value in
          var updated = gradient
          updated.aspectRatio = 0.1 + value * 2.9
          applyGradient(updated, "Reshape Gradient", interactive: true)
        }

        Toggle(
          "Offset center",
          isOn: Binding(
            get: { gradient.focal != nil },
            set: { isOn in
              var updated = gradient
              updated.focal = isOn ? gradient.start : nil
              applyGradient(updated, "Change Gradient Focus")
            })
        )
        .help("Moves where the first stop sits, so the highlight is off center.")
      }
    }
  }

  private func pointField(
    _ value: Double, label: String, set: @escaping (Double) -> Void
  ) -> some View {
    HStack(spacing: 2) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      TextField(label, value: Binding(get: { value }, set: set),
        format: .number.precision(.fractionLength(0)))
        .frame(width: 54)
        .multilineTextAlignment(.trailing)
        .accessibilityLabel("Gradient \(label)")
    }
  }

  private var presetRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Presets").font(.caption).foregroundStyle(.secondary)
      swatchRow(VectorGradientLibrary.presets.map { ($0.name, $0.gradient) })
      if !library.recents.isEmpty {
        HStack {
          Text("Recent").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Clear") { library.clearRecents() }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        swatchRow(library.recents.enumerated().map { ("Recent \($0.offset + 1)", $0.element) })
      }
    }
  }

  private func swatchRow(_ entries: [(String, VectorGradient)]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
          Button {
            applyPreset(entry.1)
          } label: {
            GradientRampView(gradient: entry.1, selectedStopID: nil)
              .frame(width: 46, height: 20)
              .clipShape(RoundedRectangle(cornerRadius: 4))
              .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
          }
          .buttonStyle(.plain)
          .help(entry.0)
          .accessibilityLabel(entry.0)
        }
      }
      .padding(.vertical, 1)
    }
  }

  // MARK: - Shared controls

  private var opacitySlider: some View {
    labeledSlider(
      "Fill opacity",
      value: fill?.opacity ?? 1,
      format: percentage(fill?.opacity ?? 1),
      actionName: "Change Fill Opacity"
    ) { value in
      var next = fill ?? VectorFillStyle(color: .white)
      next.opacity = value
      apply(next, "Change Fill Opacity", true)
    }
  }

  private func labeledSlider(
    _ title: String,
    value: Double,
    format: String,
    actionName: String,
    set: @escaping (Double) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title).font(.caption)
        Spacer()
        Text(format).font(.caption).monospacedDigit().foregroundStyle(.secondary)
      }
      Slider(
        value: Binding(get: { value }, set: set),
        in: 0...1,
        onEditingChanged: { editing in gesture(editing, actionName) }
      )
      .accessibilityLabel(title)
      .accessibilityValue(format)
    }
  }

  // MARK: - Reading and writing

  private var gradient: VectorGradient? { fill?.gradient }

  private var mode: FillMode {
    guard let fill else { return .none }
    switch fill.content {
    case .solid: return .solid
    case .gradient(let gradient): return gradient.kind == .linear ? .linear : .radial
    }
  }

  private var modeBinding: Binding<FillMode> {
    Binding(get: { mode }, set: setMode)
  }

  private func setMode(_ next: FillMode) {
    guard next != mode else { return }
    switch next {
    case .none:
      apply(nil, "Remove Vector Fill", false)
    case .solid:
      apply(
        VectorFillStyle(
          color: fill?.color ?? colorWhenEnabled, opacity: fill?.opacity ?? 1),
        "Use Solid Fill", false)
    case .linear, .radial:
      let kind: VectorGradientKind = next == .linear ? .linear : .radial
      var updated = gradient ?? defaultGradient(for: fill?.color ?? colorWhenEnabled)
      updated.kind = kind
      updated.opacity = fill?.opacity ?? 1
      selectedStopID = updated.stops.first?.id
      applyGradient(updated, kind == .linear ? "Use Linear Gradient" : "Use Radial Gradient")
    }
  }

  /// A first gradient built from whatever color the object already had, so
  /// switching to a gradient never discards the user's choice.
  private func defaultGradient(for color: VectorColor?) -> VectorGradient {
    let base = color ?? .white
    var transparent = base
    transparent.alpha = 0
    return VectorGradient(
      stops: [
        VectorGradientStop(color: base, position: 0),
        VectorGradientStop(color: transparent, position: 1),
      ],
      start: VectorPoint(x: 0.25, y: 0.5),
      end: VectorPoint(x: 0.75, y: 0.5)
    )
  }

  private func applyPreset(_ preset: VectorGradient) {
    var updated = preset
    // A preset supplies the ramp; where it sits stays where the object had it.
    if let existing = gradient {
      updated.start = existing.start
      updated.end = existing.end
      updated.focal = existing.focal
      updated.aspectRatio = existing.aspectRatio
    }
    updated.opacity = fill?.opacity ?? 1
    selectedStopID = updated.stops.first?.id
    applyGradient(updated, "Apply Gradient Preset")
  }

  private func applyGradient(
    _ gradient: VectorGradient, _ actionName: String, interactive: Bool = false
  ) {
    apply(VectorFillStyle(gradient: gradient), actionName, interactive)
    if !interactive { library.remember(gradient) }
  }

  private func selectedStop(in gradient: VectorGradient) -> VectorGradientStop? {
    gradient.stops.first { $0.id == selectedStopID } ?? gradient.stops.first
  }

  private func widestGapCenter(_ gradient: VectorGradient) -> Double {
    var best = 0.5
    var widest = 0.0
    for index in 0..<(gradient.stops.count - 1) {
      let lower = gradient.stops[index].position
      let upper = gradient.stops[index + 1].position
      if upper - lower > widest {
        widest = upper - lower
        best = (lower + upper) / 2
      }
    }
    return best
  }

  /// The gradient direction as it reads on screen.
  ///
  /// Geometry is normalized to the image extent, so the angle has to be
  /// measured after scaling back into pixels or a 45° ramp would not look like
  /// one on a non-square canvas.
  private func angleDegrees(_ gradient: VectorGradient) -> Double {
    let dx = (gradient.end.x - gradient.start.x) * canvasWidth
    let dy = (gradient.end.y - gradient.start.y) * canvasHeight
    guard dx != 0 || dy != 0 else { return 0 }
    return atan2(dy, dx) * 180 / .pi
  }

  private func lengthInPixels(_ gradient: VectorGradient) -> Double {
    hypot(
      (gradient.end.x - gradient.start.x) * canvasWidth,
      (gradient.end.y - gradient.start.y) * canvasHeight)
  }

  private func settingAngle(_ degrees: Double, on gradient: VectorGradient) -> VectorGradient {
    endpoint(gradient, degrees: degrees, length: lengthInPixels(gradient))
  }

  private func settingLength(_ pixels: Double, on gradient: VectorGradient) -> VectorGradient {
    endpoint(gradient, degrees: angleDegrees(gradient), length: max(pixels, 1))
  }

  private func endpoint(
    _ gradient: VectorGradient, degrees: Double, length: Double
  ) -> VectorGradient {
    guard canvasWidth > 0, canvasHeight > 0 else { return gradient }
    let radians = degrees * .pi / 180
    var updated = gradient
    updated.end = VectorPoint(
      x: gradient.start.x + cos(radians) * length / canvasWidth,
      y: gradient.start.y + sin(radians) * length / canvasHeight
    )
    return updated
  }

  private func percentage(_ value: Double) -> String {
    (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
  }

  private func rampDescription(_ gradient: VectorGradient) -> String {
    let count = gradient.stops.count
    return "\(gradient.kind.label) gradient, \(count) stops, "
      + "\(percentage(gradient.opacity)) opacity"
  }
}

/// A gradient's ramp, drawn with the same easing the renderer applies.
///
/// Sampling `VectorGradient.color(at:)` rather than handing SwiftUI a
/// `LinearGradient` means the swatch shows midpoints and per-stop alpha the way
/// the canvas will.
struct GradientRampView: View {
  let gradient: VectorGradient
  var selectedStopID: UUID?

  private static let sampleCount = 48

  var body: some View {
    ZStack(alignment: .leading) {
      CheckerboardBackground()
      LinearGradient(
        stops: (0...Self.sampleCount).map { step in
          let t = Double(step) / Double(Self.sampleCount)
          return Gradient.Stop(color: gradient.color(at: t).swiftUIColor, location: t)
        },
        startPoint: .leading,
        endPoint: .trailing
      )
      GeometryReader { proxy in
        ForEach(gradient.stops) { stop in
          Rectangle()
            .fill(stop.id == selectedStopID ? Color.accentColor : Color.primary.opacity(0.55))
            .frame(width: stop.id == selectedStopID ? 3 : 1)
            .position(x: proxy.size.width * stop.position, y: proxy.size.height / 2)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
  }
}

/// Transparency behind a ramp, so a stop's alpha is visible rather than
/// blending into the panel.
struct CheckerboardBackground: View {
  var body: some View {
    Canvas { context, size in
      let square = 6.0
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
      var y = 0.0
      var row = 0
      while y < size.height {
        var x = row.isMultiple(of: 2) ? square : 0
        while x < size.width {
          context.fill(
            Path(CGRect(x: x, y: y, width: square, height: square)),
            with: .color(.gray.opacity(0.35)))
          x += square * 2
        }
        y += square
        row += 1
      }
    }
  }
}

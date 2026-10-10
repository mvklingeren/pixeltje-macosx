import PixeltjeMacDomain
import SwiftUI

/// The complete stroke model, in one editor.
///
/// The recipe has carried width, cap, join, and dash lengths since the Pen tool
/// existed; the rest of the model had no controls. Everything the renderer can
/// draw is editable here, and nothing here is a value the renderer ignores.
struct VectorStrokeEditorView: View {
  /// The stroke being edited, or nil when the objects have none.
  let stroke: VectorStrokeStyle?
  /// Whether the selection disagrees about its stroke.
  let isMixed: Bool
  /// Whether the objects being styled enclose an area. Alignment only means
  /// something for a closed outline, and arrowheads only for an open one.
  let hasClosedObjects: Bool
  let hasOpenObjects: Bool
  /// The stroke to switch back on with, when the objects have none. It carries
  /// the shared foreground color, so turning a stroke off and on again returns
  /// the color it was drawn in rather than a stock black.
  let strokeWhenEnabled: VectorStrokeStyle
  let isEnabled: Bool
  /// Replaces the stroke. `interactive` marks a value still being dragged.
  let apply: (VectorStrokeStyle?, _ actionName: String, _ interactive: Bool) -> Void
  let gesture: (_ isEditing: Bool, _ actionName: String) -> Void

  private typealias ExpandedState = SwiftUI.State<Bool>
  @ExpandedState private var showsAdvanced = false

  private var current: VectorStrokeStyle {
    stroke ?? VectorStrokeStyle()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Stroke").font(.subheadline).bold()
        Spacer()
        if isMixed {
          Text("Mixed").font(.caption2).foregroundStyle(.secondary)
        }
        Toggle("", isOn: enabledBinding)
          .labelsHidden()
          .accessibilityLabel("Stroke enabled")
      }

      if stroke != nil {
        ColorPicker("Foreground", selection: colorBinding, supportsOpacity: true)
          .help("The window's foreground color. A vector outline is drawn in it, and so is a brush stroke and type.")
        widthField
        opacitySlider

        HStack(spacing: 8) {
          capPicker
          joinPicker
        }

        if hasClosedObjects {
          Picker("Alignment", selection: alignmentBinding) {
            ForEach(VectorStrokeAlignment.allCases, id: \.self) { value in
              Text(value.label).tag(value)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityLabel("Stroke alignment")
          .help("Where the stroke sits relative to the outline. An open path is always centered.")
        }

        DisclosureGroup("Dashes and ends", isExpanded: $showsAdvanced) {
          VStack(alignment: .leading, spacing: 8) {
            dashControls
            if current.lineJoin == .miter { miterLimitField }
            if hasOpenObjects { arrowheadControls }
          }
          .padding(.top, 6)
        }
        .font(.caption)
      } else {
        Text("These objects have no stroke. Turn one on to give them an outline.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .disabled(!isEnabled)
  }

  // MARK: - Basics

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { stroke != nil },
      set: { isOn in
        apply(isOn ? (stroke ?? strokeWhenEnabled) : nil, "Change Vector Stroke", false)
      })
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { current.color.swiftUIColor },
      set: { color in
        var next = current
        next.color = VectorColor(color)
        apply(next, "Change Vector Stroke", false)
      })
  }

  private var widthField: some View {
    LabeledContent("Width") {
      HStack(spacing: 4) {
        TextField(
          "Width",
          value: Binding(
            get: { current.width },
            set: { value in
              var next = current
              next.width = max(value, 0)
              apply(next, "Change Vector Stroke Width", false)
            }),
          format: .number.precision(.fractionLength(1))
        )
        .frame(width: 62)
        .multilineTextAlignment(.trailing)
        Text("px").foregroundStyle(.secondary)
      }
    }
    .accessibilityLabel("Stroke width in pixels")
  }

  private var opacitySlider: some View {
    slider(
      "Stroke opacity",
      value: current.opacity,
      range: 0...1,
      format: percentage(current.opacity),
      actionName: "Change Stroke Opacity"
    ) { value in
      var next = current
      next.opacity = value
      apply(next, "Change Stroke Opacity", true)
    }
  }

  private var capPicker: some View {
    Picker("Cap", selection: capBinding) {
      Image(systemName: "capsule.portrait").tag(VectorLineCap.butt)
      Image(systemName: "capsule").tag(VectorLineCap.round)
      Image(systemName: "rectangle").tag(VectorLineCap.square)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel("Line cap")
    .accessibilityValue(capLabel)
    .help("Line cap: \(capLabel)")
  }

  private var joinPicker: some View {
    Picker("Join", selection: joinBinding) {
      Image(systemName: "arrow.turn.right.up").tag(VectorLineJoin.miter)
      Image(systemName: "arrow.turn.right.up.circle").tag(VectorLineJoin.round)
      Image(systemName: "arrow.turn.right.up.square").tag(VectorLineJoin.bevel)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel("Line join")
    .accessibilityValue(joinLabel)
    .help("Line join: \(joinLabel)")
  }

  private var capLabel: String {
    switch current.lineCap {
    case .butt: "Butt"
    case .round: "Round"
    case .square: "Square"
    }
  }

  private var joinLabel: String {
    switch current.lineJoin {
    case .miter: "Miter"
    case .round: "Round"
    case .bevel: "Bevel"
    }
  }

  private var capBinding: Binding<VectorLineCap> {
    Binding(
      get: { current.lineCap },
      set: { value in
        var next = current
        next.lineCap = value
        apply(next, "Change Line Cap", false)
      })
  }

  private var joinBinding: Binding<VectorLineJoin> {
    Binding(
      get: { current.lineJoin },
      set: { value in
        var next = current
        next.lineJoin = value
        apply(next, "Change Line Join", false)
      })
  }

  private var alignmentBinding: Binding<VectorStrokeAlignment> {
    Binding(
      get: { current.alignment },
      set: { value in
        var next = current
        next.alignment = value
        apply(next, "Change Stroke Alignment", false)
      })
  }

  // MARK: - Dashes, miter, arrowheads

  private var dashControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent("Dash") {
        TextField(
          "Dash pattern",
          text: Binding(get: { dashText }, set: setDashText)
        )
        .frame(width: 120)
        .multilineTextAlignment(.trailing)
        .accessibilityLabel("Dash and gap lengths in pixels")
        .help("Alternating dash and gap lengths in pixels, for example \"12 6\". Leave empty for a solid stroke.")
      }
      LabeledContent("Phase") {
        HStack(spacing: 4) {
          TextField(
            "Phase",
            value: Binding(
              get: { current.dashPhase },
              set: { value in
                var next = current
                next.dashPhase = value
                apply(next, "Change Dash Phase", false)
              }),
            format: .number.precision(.fractionLength(1))
          )
          .frame(width: 62)
          .multilineTextAlignment(.trailing)
          Text("px").foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel("Dash phase in pixels")
      .disabled(current.usableDashPattern == nil)
    }
  }

  private var dashText: String {
    current.dashPattern
      .map { $0.formatted(.number.precision(.fractionLength(0...2))) }
      .joined(separator: " ")
  }

  /// A dash pattern typed as plain numbers. Anything that is not a number is
  /// dropped rather than rejected, so a half-typed value never clears the
  /// field mid-edit.
  private func setDashText(_ text: String) {
    let lengths = text
      .split(whereSeparator: { $0 == " " || $0 == "," })
      .compactMap { Double($0) }
      .filter { $0 >= 0 }
    var next = current
    next.dashPattern = lengths
    apply(next, "Change Dash Pattern", false)
  }

  private var miterLimitField: some View {
    LabeledContent("Miter limit") {
      TextField(
        "Miter limit",
        value: Binding(
          get: { current.miterLimit },
          set: { value in
            var next = current
            next.miterLimit = value
            apply(next, "Change Miter Limit", false)
          }),
        format: .number.precision(.fractionLength(1))
      )
      .frame(width: 62)
      .multilineTextAlignment(.trailing)
    }
    .accessibilityLabel("Miter limit")
    .help("How far a sharp corner may extend, as a multiple of the width, before it is beveled.")
  }

  private var arrowheadControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      arrowheadPicker("Start", head: current.startArrowhead) { head in
        var next = current
        next.startArrowhead = head
        apply(next, "Change Arrowhead", false)
      }
      arrowheadPicker("End", head: current.endArrowhead) { head in
        var next = current
        next.endArrowhead = head
        apply(next, "Change Arrowhead", false)
      }
      if current.startArrowhead != nil || current.endArrowhead != nil {
        slider(
          "Arrowhead size",
          value: arrowScale,
          range: 0.5...10,
          format: arrowScale.formatted(.number.precision(.fractionLength(1))) + "×",
          actionName: "Resize Arrowhead"
        ) { value in
          var next = current
          if var head = next.startArrowhead {
            head.scale = value
            next.startArrowhead = head
          }
          if var head = next.endArrowhead {
            head.scale = value
            next.endArrowhead = head
          }
          apply(next, "Resize Arrowhead", true)
        }
      }
    }
  }

  private var arrowScale: Double {
    current.startArrowhead?.scale ?? current.endArrowhead?.scale ?? 3
  }

  private func arrowheadPicker(
    _ title: String,
    head: VectorArrowhead?,
    set: @escaping (VectorArrowhead?) -> Void
  ) -> some View {
    LabeledContent(title) {
      Picker(
        title,
        selection: Binding(
          get: { head?.style },
          set: { style in
            set(style.map { VectorArrowhead(style: $0, scale: arrowScale) })
          })
      ) {
        Text("None").tag(VectorArrowhead.Style?.none)
        ForEach(VectorArrowhead.Style.allCases, id: \.self) { style in
          Text(style.label).tag(VectorArrowhead.Style?.some(style))
        }
      }
      .labelsHidden()
      .frame(width: 120)
      .accessibilityLabel("\(title) arrowhead")
    }
  }

  // MARK: - Small controls

  private func slider(
    _ title: String,
    value: Double,
    range: ClosedRange<Double>,
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
        in: range,
        onEditingChanged: { editing in gesture(editing, actionName) }
      )
      .accessibilityLabel(title)
      .accessibilityValue(format)
    }
  }

  private func percentage(_ value: Double) -> String {
    (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
  }
}

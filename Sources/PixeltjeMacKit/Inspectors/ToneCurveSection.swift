import PixeltjeMacDomain
import SwiftUI

/// The tone curve panel: parametric, point and per-channel RGB in one editor.
///
/// The mode picker chooses between the parametric editor and the point editor;
/// in point mode the channel tabs choose which curve the graph edits, RGB being
/// the composite one applied to every channel. Mode and channel are view state,
/// not recipe state, so switching tabs is not an undoable edit.
///
/// The curve is a post-RAW edit of this layer. Apple's own RAW tone behaviour
/// stays where it is, in the Apple RAW group's "Tone boost".
struct ToneCurveSection: View {
  @ObservedObject var model: EditorModel
  let layer: ProjectLayer
  let send: (InspectorIntent) -> Void

  @StateObject private var state = ToneCurveEditorState()

  private var mode: ToneCurveRecipe.Mode { state.mode }
  private var channel: ToneCurveRecipe.Channel { state.channel }

  private var editor: LayerAdjustmentEditor {
    LayerAdjustmentEditor(model: model, layer: layer)
  }

  private var curve: ToneCurveRecipe { editor.current.toneCurve }

  var body: some View {
    GroupBox("Tone curve") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Mode", selection: $state.mode) {
          ForEach(ToneCurveRecipe.Mode.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if mode == .point {
          Picker("Channel", selection: $state.channel) {
            ForEach(ToneCurveRecipe.Channel.allCases, id: \.self) { channel in
              Text(channel.label).tag(channel)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }

        ToneCurveGraph(
          state: state,
          curve: curve,
          update: updatePointCurve,
          beginGesture: { send(.beginGesture) },
          endGesture: { send(.endGesture("Edit Tone Curve")) }
        )
        .frame(height: 190)
        .accessibilityLabel("Tone curve editor")

        if mode == .parametric {
          parametricControls
        } else {
          pointHint
        }

        Button(mode == .parametric ? "Reset Parametric Curve" : "Reset \(channel.label) Curve") {
          send(.change(resetAction(), interactive: false))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .disabled(isResetDisabled)
      }
      .padding(.vertical, 2)
    }
  }

  // MARK: - Parametric

  private var parametricControls: some View {
    VStack(spacing: 11) {
      regionSlider("Highlights", .highlights)
      regionSlider("Lights", .lights)
      regionSlider("Darks", .darks)
      regionSlider("Shadows", .shadows)
      Divider()
      Text("Region split points")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      splitSlider("Shadow split", .shadowSplit, defaultValue: 0.25)
      splitSlider("Midtone split", .midtoneSplit, defaultValue: 0.5)
      splitSlider("Highlight split", .highlightSplit, defaultValue: 0.75)
    }
  }

  private func regionSlider(
    _ title: String, _ region: ParametricToneCurve.Region
  ) -> some View {
    AdjustmentSlider(
      title: title,
      value: curve.parametric[region],
      range: -100...100,
      actionName: "Adjust Curve \(title)",
      send: send
    ) { value in
      editor.action("Adjust Curve \(title)") { $0.toneCurve.parametric[region] = value }
    }
  }

  private func splitSlider(
    _ title: String, _ split: ParametricToneCurve.Split, defaultValue: Double
  ) -> some View {
    AdjustmentSlider(
      title: title,
      value: curve.parametric[split],
      range: 0.05...0.95,
      defaultValue: defaultValue,
      decimals: 2,
      actionName: "Adjust \(title)",
      send: send
    ) { value in
      editor.action("Adjust \(title)") { $0.toneCurve.parametric[split] = value }
    }
  }

  // MARK: - Point

  private var pointHint: some View {
    Text("Click to add a point, drag to move it, drag it off the graph to delete it.")
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func updatePointCurve(_ points: PointToneCurve, interactive: Bool) {
    let channel = channel
    send(
      .change(
        editor.action("Edit Tone Curve") { $0.toneCurve[channel] = points },
        interactive: interactive
      )
    )
  }

  // MARK: - Reset

  private var isResetDisabled: Bool {
    mode == .parametric ? curve.parametric.isNeutral : curve[channel].isIdentity
  }

  private func resetAction() -> EditorAction {
    let mode = mode
    let channel = channel
    return editor.action("Reset Tone Curve") { adjustments in
      switch mode {
      case .parametric:
        // The split points are part of the parametric editor, so a reset puts
        // them back where they started too.
        adjustments.toneCurve.parametric = .neutral
      case .point:
        adjustments.toneCurve[channel] = .identity
      }
    }
  }
}

/// The tone curve panel's view state: which editor is showing, which channel
/// tab is selected, and the drag in flight.
///
/// None of this is recipe state. It lives here rather than in the document so
/// that switching tabs is not an edit, and so the panel keeps its place while
/// the document renders.
///
/// The drag also keeps its own copy of the curve it is editing. The graph reads
/// the curve from the document, and that copy does not refresh until the view
/// rebuilds, which is later than the next event of the same drag: a drag that
/// read it back would undo the edit it had just made. Every step of a drag
/// therefore reads and writes `dragCurve`, and the document is the destination
/// only.
///
/// Drag steps are in curve space — x and y both 0…1 — so the view converts from
/// view points before calling in, and the state stays testable on its own.
@MainActor
final class ToneCurveEditorState: ObservableObject {
  @Published var mode: ToneCurveRecipe.Mode = .parametric
  @Published var channel: ToneCurveRecipe.Channel = .rgb

  /// The point the current drag is moving, or `nil` when the drag has already
  /// dropped its point off the graph.
  private(set) var dragIndex: Int?
  /// The curve the drag is editing, or `nil` when no drag is in flight.
  private(set) var dragCurve: PointToneCurve?

  /// Whether a drag is in flight, including after its point was deleted.
  var isDragging: Bool { dragCurve != nil }

  /// Starts a drag on `curve`: it grabs the point within `hitRadius` of
  /// `point`, in curve space, or adds one there.
  ///
  /// The return value is the curve to publish, which is non-nil only when a
  /// point was added — grabbing an existing point changes nothing yet.
  func beginDrag(
    on curve: PointToneCurve, at point: ToneCurvePoint, hitRadius: Double
  ) -> PointToneCurve? {
    dragCurve = curve
    if let index = curve.index(near: point.x, y: point.y, within: hitRadius) {
      dragIndex = index
      return nil
    }
    guard let added = curve.adding(point) else {
      dragIndex = nil
      return nil
    }
    dragIndex = added.index
    dragCurve = added.curve
    return added.curve
  }

  /// Continues the drag, either moving its point to `point` or, when `delete`
  /// is set and the point may be removed, dropping it.
  ///
  /// The return value is the curve to publish and whether the edit is still
  /// interactive; it is nil when the drag has nothing left to move.
  func continueDrag(
    to point: ToneCurvePoint, delete: Bool
  ) -> (curve: PointToneCurve, interactive: Bool)? {
    guard let index = dragIndex, let curve = dragCurve else { return nil }
    if delete, curve.points.count > 2, index > 0, index < curve.points.count - 1 {
      let updated = curve.removing(index)
      dragCurve = updated
      dragIndex = nil
      return (updated, false)
    }
    let updated = curve.moving(index, to: point)
    dragCurve = updated
    return (updated, true)
  }

  func endDrag() {
    dragIndex = nil
    dragCurve = nil
  }
}

/// The interactive curve graph.
///
/// The graph draws in curve space: x is the input value from 0 at the left to 1
/// at the right, y is the output value from 0 at the bottom to 1 at the top.
/// The dashed diagonal is the identity, so a curve on the diagonal is a
/// pixel no-op.
struct ToneCurveGraph: View {
  @ObservedObject var state: ToneCurveEditorState
  let curve: ToneCurveRecipe
  /// Replaces the point curve of the active channel.
  let update: (PointToneCurve, _ interactive: Bool) -> Void
  let beginGesture: () -> Void
  let endGesture: () -> Void

  private var mode: ToneCurveRecipe.Mode { state.mode }
  private var channel: ToneCurveRecipe.Channel { state.channel }
  private var isEditable: Bool { state.mode == .point }

  /// How far, in view points, a click may land from a point and still grab it.
  private let hitRadius = 11.0
  /// How far a drag must leave the plot before the point is deleted.
  private let deleteMargin = 26.0

  var body: some View {
    GeometryReader { geometry in
      let plot = plotRect(in: geometry.size)
      Canvas { context, _ in draw(in: &context, plot: plot) }
        .contentShape(Rectangle())
        .gesture(dragGesture(in: plot), isEnabled: isEditable)
    }
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
  }

  private func plotRect(in size: CGSize) -> CGRect {
    CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
  }

  // MARK: - Drawing

  private func draw(in context: inout GraphicsContext, plot: CGRect) {
    guard plot.width > 1, plot.height > 1 else { return }

    // Grid at the quarter points, plus the identity diagonal.
    var grid = Path()
    for step in 1..<4 {
      let fraction = Double(step) / 4
      let x = plot.minX + plot.width * fraction
      let y = plot.minY + plot.height * fraction
      grid.move(to: CGPoint(x: x, y: plot.minY))
      grid.addLine(to: CGPoint(x: x, y: plot.maxY))
      grid.move(to: CGPoint(x: plot.minX, y: y))
      grid.addLine(to: CGPoint(x: plot.maxX, y: y))
    }
    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

    var diagonal = Path()
    diagonal.move(to: CGPoint(x: plot.minX, y: plot.maxY))
    diagonal.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
    context.stroke(
      diagonal,
      with: .color(.secondary.opacity(0.4)),
      style: StrokeStyle(lineWidth: 1, dash: [3, 3])
    )

    // In parametric mode the region boundaries are what the sliders act on, so
    // the graph shows where they sit.
    if mode == .parametric {
      var splits = Path()
      for split in ParametricToneCurve.Split.allCases {
        let x = plot.minX + plot.width * curve.parametric[split]
        splits.move(to: CGPoint(x: x, y: plot.minY))
        splits.addLine(to: CGPoint(x: x, y: plot.maxY))
      }
      context.stroke(
        splits,
        with: .color(.secondary.opacity(0.5)),
        style: StrokeStyle(lineWidth: 1, dash: [2, 4])
      )
    }

    context.stroke(curvePath(in: plot), with: .color(strokeColor), lineWidth: 1.8)

    guard isEditable else { return }
    for point in curve[channel].points {
      let centre = viewPoint(point, in: plot)
      let dot = Path(
        ellipseIn: CGRect(x: centre.x - 3.5, y: centre.y - 3.5, width: 7, height: 7))
      context.fill(dot, with: .color(strokeColor))
      context.stroke(dot, with: .color(.white.opacity(0.85)), lineWidth: 1)
    }
  }

  /// The curve the graph shows. Parametric mode shows the composed result;
  /// point mode shows the curve of the active tab on its own, which is what the
  /// points on screen belong to.
  private func curvePath(in plot: CGRect) -> Path {
    let samples = max(Int(plot.width), 32)
    var path = Path()
    let pointCurve = curve[channel]
    for step in 0...samples {
      let x = Double(step) / Double(samples)
      let y =
        mode == .parametric
        ? curve.parametric.value(at: x)
        : min(max(pointCurve.value(at: x), 0), 1)
      let location = viewPoint(ToneCurvePoint(x: x, y: y), in: plot)
      if step == 0 { path.move(to: location) } else { path.addLine(to: location) }
    }
    return path
  }

  private var strokeColor: Color {
    guard mode == .point else { return .accentColor }
    switch channel {
    case .rgb: return .accentColor
    case .red: return .red
    case .green: return .green
    case .blue: return .blue
    }
  }

  // MARK: - Coordinates

  private func viewPoint(_ point: ToneCurvePoint, in plot: CGRect) -> CGPoint {
    CGPoint(
      x: plot.minX + plot.width * point.x,
      y: plot.maxY - plot.height * point.y
    )
  }

  private func curvePoint(_ location: CGPoint, in plot: CGRect) -> ToneCurvePoint {
    ToneCurvePoint(
      x: (location.x - plot.minX) / plot.width,
      y: (plot.maxY - location.y) / plot.height
    )
  }

  // MARK: - Editing

  private func dragGesture(in plot: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        // The press itself either grabs a point or adds one; only later events
        // of the same drag move it. Doing both on the first event would drag a
        // freshly added point before the user has moved the mouse.
        if !state.isDragging {
          beginGesture()
          let added = state.beginDrag(
            on: curve[channel],
            at: curvePoint(value.startLocation, in: plot),
            hitRadius: hitRadius / min(plot.width, plot.height)
          )
          if let added { update(added, true) }
          return
        }
        guard
          let step = state.continueDrag(
            to: curvePoint(value.location, in: plot),
            delete: shouldDelete(value.location, in: plot)
          )
        else { return }
        update(step.curve, step.interactive)
      }
      .onEnded { _ in
        state.endDrag()
        endGesture()
      }
  }

  private func shouldDelete(_ location: CGPoint, in plot: CGRect) -> Bool {
    !plot.insetBy(dx: -deleteMargin, dy: -deleteMargin).contains(location)
  }
}

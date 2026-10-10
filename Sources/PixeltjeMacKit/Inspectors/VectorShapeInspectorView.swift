import PixeltjeMacDomain
import SwiftUI

/// The stroke and fill copied from one object, ready to paste onto another.
///
/// Session tool state rather than document state: copying an appearance changes
/// no pixels and belongs in no history step.
@MainActor
final class VectorAppearanceClipboard: ObservableObject {
  static let shared = VectorAppearanceClipboard()

  @Published private(set) var stroke: VectorStrokeStyle?
  @Published private(set) var fill: VectorFillStyle?
  @Published private(set) var hasContent = false

  func copy(from object: VectorObject) {
    stroke = object.stroke
    fill = object.fill
    hasContent = true
  }

  /// Applies the copied appearance to the named objects. An object that
  /// encloses no area keeps no fill, so pasting onto a line cannot give it one
  /// that would never draw.
  func pasted(onto layer: VectorLayer, ids: Set<UUID>) -> VectorLayer {
    guard hasContent else { return layer }
    return layer.updatingObjects(ids: ids) { object in
      object.stroke = stroke
      object.fill = object.isClosed ? fill : nil
    }
  }
}

/// Vector objects copied from one layer, ready to paste into another.
///
/// Session state, like the appearance clipboard: objects reach the recipe only
/// when they are pasted, and pasting re-identifies them so the same copy can be
/// placed more than once.
@MainActor
final class VectorObjectClipboard: ObservableObject {
  static let shared = VectorObjectClipboard()

  @Published private(set) var objects: [VectorObject] = []

  var isEmpty: Bool { objects.isEmpty }

  func copy(_ objects: [VectorObject]) {
    guard !objects.isEmpty else { return }
    self.objects = objects
  }

  func clear() {
    objects = []
  }
}

/// The parameters of the selected shape, under the object list.
///
/// A shape stays what it was drawn as, so these controls edit a side count or a
/// corner radius rather than the anchors those happen to produce. Convert Shape
/// to Path is the deliberate one-way door to anchor editing.
struct VectorShapeInspectorView: View {
  let layerID: ProjectLayerID
  let vector: VectorLayer
  let isLocked: Bool
  let selectedObjectIDs: Set<UUID>
  /// The canvas extent, so positions and sizes read in pixels.
  let canvasWidth: Double
  let canvasHeight: Double
  let send: (InspectorIntent) -> Void

  @ObservedObject private var clipboard = VectorAppearanceClipboard.shared

  var body: some View {
    if !selectedObjectIDs.isEmpty {
      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          header
          if let shape {
            geometry(shape)
            Divider()
            parameters(shape)
            Divider()
          }
          appearanceActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .disabled(isLocked)
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: shape?.kind.symbolName ?? "scribble")
      Text(shape?.kind.label ?? "Selection")
        .font(.headline)
      Spacer()
      if shape != nil {
        Button("Convert to Path") { convertToPath() }
          .controlSize(.small)
          .help("Replaces the shape with editable anchors. This cannot be undone by re-editing the parameters, only by Undo.")
      }
    }
  }

  @ViewBuilder
  private func geometry(_ shape: VectorShape) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        field("X", value: shape.frame.minX * canvasWidth) { value in
          apply(movingFrame(shape, toX: value / max(canvasWidth, 1)), "Move Shape")
        }
        field("Y", value: shape.frame.minY * canvasHeight) { value in
          apply(movingFrame(shape, toY: value / max(canvasHeight, 1)), "Move Shape")
        }
      }
      HStack(spacing: 6) {
        field("W", value: shape.frame.width * canvasWidth) { value in
          apply(resizing(shape, width: value / max(canvasWidth, 1)), "Resize Shape")
        }
        field("H", value: shape.frame.height * canvasHeight) { value in
          apply(resizing(shape, height: value / max(canvasHeight, 1)), "Resize Shape")
        }
      }
      LabeledContent("Rotation") {
        HStack(spacing: 4) {
          TextField(
            "Rotation",
            value: Binding(
              get: { shape.rotationDegrees },
              set: { degrees in
                var updated = shape
                updated.rotationDegrees = degrees
                apply(updated, "Rotate Shape")
              }),
            format: .number.precision(.fractionLength(1))
          )
          .frame(width: 62)
          .multilineTextAlignment(.trailing)
          Text("°").foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel("Shape rotation in degrees")
    }
  }

  @ViewBuilder
  private func parameters(_ shape: VectorShape) -> some View {
    switch shape.kind {
    case .rectangle(let corners):
      cornerControls(shape, corners: corners)
    case .polygon(let sides):
      Stepper(value: sidesBinding(shape, sides: sides), in: 3...64) {
        LabeledContent("Sides", value: "\(sides)")
      }
      .accessibilityLabel("Polygon sides")
      .accessibilityValue("\(sides)")
    case .star(let points, let innerRatio):
      Stepper(value: pointsBinding(shape, points: points), in: 3...64) {
        LabeledContent("Points", value: "\(points)")
      }
      .accessibilityLabel("Star points")
      .accessibilityValue("\(points)")
      slider(
        "Inner radius",
        value: innerRatio,
        range: 0.05...0.95,
        format: percentage(innerRatio),
        actionName: "Reshape Star"
      ) { value in
        var updated = shape
        updated.kind = .star(points: points, innerRatio: value)
        apply(updated, "Reshape Star", interactive: true)
      }
    case .ellipse, .line:
      Text(
        shape.kind == .line
          ? "A line has no fill. Its stroke controls are in the Pen tool settings."
          : "Arc and pie controls arrive with the next shape increment."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func cornerControls(
    _ shape: VectorShape, corners: VectorCornerRadii
  ) -> some View {
    slider(
      "Corner radius",
      value: corners.uniformValue ?? corners.largest,
      range: 0...0.5,
      format: cornerLabel(corners),
      actionName: "Round Corners"
    ) { value in
      var updated = shape
      updated.kind = .rectangle(corners: VectorCornerRadii(uniform: value))
      apply(updated, "Round Corners", interactive: true)
    }

    DisclosureGroup("Individual corners") {
      VStack(alignment: .leading, spacing: 4) {
        cornerField("Bottom left", value: corners.bottomLeft) { value in
          var next = corners
          next.bottomLeft = value
          applyCorners(shape, next)
        }
        cornerField("Bottom right", value: corners.bottomRight) { value in
          var next = corners
          next.bottomRight = value
          applyCorners(shape, next)
        }
        cornerField("Top right", value: corners.topRight) { value in
          var next = corners
          next.topRight = value
          applyCorners(shape, next)
        }
        cornerField("Top left", value: corners.topLeft) { value in
          var next = corners
          next.topLeft = value
          applyCorners(shape, next)
        }
      }
      .padding(.top, 4)
    }
    .font(.caption)
  }

  private var appearanceActions: some View {
    HStack(spacing: 6) {
      Button("Copy Appearance") {
        guard let first = selectedObjects.first else { return }
        clipboard.copy(from: first)
      }
      .disabled(selectedObjects.isEmpty)
      .help("Copies the stroke and fill of the selected object.")

      Button("Paste Appearance") {
        let updated = clipboard.pasted(onto: vector, ids: selectedObjectIDs)
        guard updated != vector else { return }
        send(
          .change(
            .setVectorLayer(layerID, updated, actionName: "Paste Vector Appearance"),
            interactive: false))
      }
      .disabled(!clipboard.hasContent)
      .help("Gives the selected objects the copied stroke and fill.")
      Spacer()
    }
    .controlSize(.small)
  }

  // MARK: - Reading

  private var selectedObjects: [VectorObject] {
    vector.objectsInDrawOrder.filter { selectedObjectIDs.contains($0.id) }
  }

  /// The shape these controls edit: the one selected shape, or nil when the
  /// selection is a path, several objects, or a mixture.
  private var shape: VectorShape? {
    guard selectedObjects.count == 1 else { return nil }
    return selectedObjects.first?.shape
  }

  private var aspect: Double {
    canvasHeight > 0 ? canvasWidth / canvasHeight : 1
  }

  // MARK: - Writing

  private func apply(
    _ shape: VectorShape, _ actionName: String, interactive: Bool = false
  ) {
    let updated = vector.updatingObjects(ids: [shape.id]) { $0.shape = shape }
    guard updated != vector else { return }
    send(
      .change(
        .setVectorLayer(layerID, updated, actionName: actionName), interactive: interactive))
  }

  private func applyCorners(_ shape: VectorShape, _ corners: VectorCornerRadii) {
    var updated = shape
    updated.kind = .rectangle(corners: corners)
    apply(updated, "Round Corners")
  }

  private func convertToPath() {
    let updated = vector.convertingShapesToPaths(ids: selectedObjectIDs, aspect: aspect)
    guard updated != vector else { return }
    send(
      .change(
        .setVectorLayer(layerID, updated, actionName: "Convert Shape to Path"),
        interactive: false))
  }

  private func movingFrame(_ shape: VectorShape, toX x: Double) -> VectorShape {
    var updated = shape
    updated.frame = VectorBounds(
      minX: x, minY: shape.frame.minY,
      maxX: x + shape.frame.width, maxY: shape.frame.maxY)
    return updated
  }

  private func movingFrame(_ shape: VectorShape, toY y: Double) -> VectorShape {
    var updated = shape
    updated.frame = VectorBounds(
      minX: shape.frame.minX, minY: y,
      maxX: shape.frame.maxX, maxY: y + shape.frame.height)
    return updated
  }

  private func resizing(
    _ shape: VectorShape, width: Double? = nil, height: Double? = nil
  ) -> VectorShape {
    var updated = shape
    // Resizing keeps the shape's origin, which is what typing into a size field
    // means; the transform tool is what scales about the center.
    let newWidth = max(width ?? shape.frame.width, 0.000_1)
    let newHeight = max(height ?? shape.frame.height, 0.000_1)
    updated.frame = VectorBounds(
      minX: shape.frame.minX,
      minY: shape.frame.minY,
      maxX: shape.frame.minX + newWidth,
      maxY: shape.frame.minY + newHeight
    )
    return updated
  }

  private func sidesBinding(_ shape: VectorShape, sides: Int) -> Binding<Int> {
    Binding(
      get: { sides },
      set: { value in
        var updated = shape
        updated.kind = .polygon(sides: value)
        apply(updated, "Change Polygon Sides")
      })
  }

  private func pointsBinding(_ shape: VectorShape, points: Int) -> Binding<Int> {
    Binding(
      get: { points },
      set: { value in
        var updated = shape
        guard case .star(_, let innerRatio) = shape.kind else { return }
        updated.kind = .star(points: value, innerRatio: innerRatio)
        apply(updated, "Change Star Points")
      })
  }

  // MARK: - Small controls

  private func field(
    _ label: String, value: Double, set: @escaping (Double) -> Void
  ) -> some View {
    HStack(spacing: 3) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      TextField(
        label,
        value: Binding(get: { value }, set: set),
        format: .number.precision(.fractionLength(0))
      )
      .frame(width: 56)
      .multilineTextAlignment(.trailing)
      .accessibilityLabel("Shape \(label) in pixels")
    }
  }

  private func cornerField(
    _ label: String, value: Double, set: @escaping (Double) -> Void
  ) -> some View {
    LabeledContent(label) {
      TextField(
        label,
        value: Binding(get: { value }, set: set),
        format: .number.precision(.fractionLength(2))
      )
      .frame(width: 56)
      .multilineTextAlignment(.trailing)
      .accessibilityLabel("\(label) corner radius")
    }
  }

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
        onEditingChanged: { editing in
          send(editing ? .beginGesture : .endGesture(actionName))
        }
      )
      .accessibilityLabel(title)
      .accessibilityValue(format)
    }
  }

  private func cornerLabel(_ corners: VectorCornerRadii) -> String {
    corners.isUniform ? percentage(corners.bottomLeft) : "Mixed"
  }

  private func percentage(_ value: Double) -> String {
    (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
  }
}

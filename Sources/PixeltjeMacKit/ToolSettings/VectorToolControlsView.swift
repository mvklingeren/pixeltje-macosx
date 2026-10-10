import PixeltjeMacDomain
import SwiftUI

/// Mutations shared by vector-creation tools. Defaults remain transient;
/// selected-object changes travel through the document and its undo manager.
enum VectorToolIntent {
  case setStyle(VectorToolStyle)
  case setVectorLayer(ProjectLayerID, VectorLayer, actionName: String, interactive: Bool)
  case beginGesture
  case endGesture(String)
  case arrange(VectorArrangeCommand)
}

/// What the arrange controls and the Object menu ask for.
enum VectorArrangeCommand: Equatable {
  case align(VectorAlignment, VectorAlignmentReference)
  case distribute(VectorDistributionAxis)
  case reflect(horizontally: Bool)
  case order(VectorOrderPlacement)
  case duplicateInPlace
  case moveToNewLayer
  case boolean(VectorBooleanOperation)
  case releaseCompoundPath
  case setFillRule(VectorFillRule)

  var actionName: String {
    switch self {
    case .align(let alignment, _): alignment.label
    case .distribute(let axis): axis.label
    case .reflect(let horizontally):
      horizontally ? "Reflect Horizontally" : "Reflect Vertically"
    case .order(let placement): placement.actionName
    case .duplicateInPlace: "Duplicate in Place"
    case .moveToNewLayer: "Move Selection to New Vector Layer"
    case .boolean(let operation): operation.label
    case .releaseCompoundPath: "Release Compound Path"
    case .setFillRule(let rule): "Use \(rule.label) Fill Rule"
    }
  }
}

/// Capabilities of the object a vector tool will create when there is no
/// selection. A Pen path may become open or closed; a Shape knows which it is.
enum VectorNextObject {
  case path
  case shape(isClosed: Bool)

  var hasClosedGeometry: Bool {
    switch self {
    case .path: true
    case .shape(let isClosed): isClosed
    }
  }

  var hasOpenGeometry: Bool {
    switch self {
    case .path: true
    case .shape(let isClosed): !isClosed
    }
  }

  var label: String {
    switch self {
    case .path: "path"
    case .shape: "shape"
    }
  }
}

/// Complete vector appearance and object controls shared by Pen and Shape.
///
/// With no object selection these edit only the next-object defaults. With a
/// selection they edit exactly those objects and update the same defaults, so
/// switching vector tools never loses a chosen gradient, dash, cap, or fill.
struct VectorToolControlsView: View {
  @ObservedObject var model: EditorModel
  let nextObject: VectorNextObject
  let send: (VectorToolIntent) -> Void
  let colorSend: (ColorWorkflowIntent) -> Void

  @AppStorage("PenNudgeDistance") private var nudgeDistance = 1.0
  @AppStorage("PenLargeNudgeDistance") private var largeNudgeDistance = 10.0

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // The pair itself is drawn by the Stroke and Fill sections below, where
      // each half is next to the width, dashes or gradient it applies to. What
      // is left here is everything that acts on both: sampling, swapping,
      // resetting, and the pinned and recent colors.
      ColorWorkflowView(
        model: model,
        send: colorSend,
        foregroundLabel: "Stroke",
        backgroundLabel: "Fill",
        showsWells: false)
      Divider()

      if let target = styleTarget {
        Text(target.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VectorStrokeEditorView(
        stroke: displayedStroke,
        isMixed: strokeIsMixed,
        hasClosedObjects: targetObjects.isEmpty
          ? nextObject.hasClosedGeometry : targetObjects.contains { $0.isClosed },
        hasOpenObjects: targetObjects.isEmpty
          ? nextObject.hasOpenGeometry : targetObjects.contains { !$0.isClosed },
        strokeWhenEnabled: model.vectorToolStyle.stroke,
        isEnabled: !selectionIsLocked,
        apply: applyStroke,
        gesture: handleGesture)
        .disabled(selectionIsLocked)

      VectorFillEditorView(
        fill: displayedFill,
        isMixed: fillIsMixed,
        canvasWidth: Double(model.recipe.layerStack.canvas.width),
        canvasHeight: Double(model.recipe.layerStack.canvas.height),
        colorWhenEnabled: model.vectorToolStyle.fillColor,
        isEnabled: fillIsEnabled,
        apply: applyFill,
        gesture: handleGesture)
        .disabled(!fillIsEnabled)

      Text(help)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      VectorArrangeControlsView(
        selectionCount: targetObjects.count,
        isLocked: isLocked,
        selectedCompoundFillRule: selectedCompoundFillRule,
        send: { send(.arrange($0)) })

      Divider()

      Stepper(value: $nudgeDistance, in: 0.1...100, step: 0.5) {
        LabeledContent(
          "Arrow nudge",
          value: "\(nudgeDistance.formatted(.number.precision(.fractionLength(1)))) px")
      }
      Stepper(value: $largeNudgeDistance, in: 1...1_000, step: 1) {
        LabeledContent(
          "Shift-arrow nudge",
          value: "\(largeNudgeDistance.formatted(.number.precision(.fractionLength(0)))) px")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var styleTarget: (
    id: ProjectLayerID, vector: VectorLayer, objectIDs: Set<UUID>, summary: String
  )? {
    guard let active = model.activeVectorLayer, !active.vector.objects.isEmpty else { return nil }
    let selected = model.selectedVectorObjectIDs.intersection(
      Set(active.vector.objects.map(\.id)))
    guard !selected.isEmpty else { return nil }
    let summary = selected.count == 1
      ? "Editing 1 selected object."
      : "Editing \(selected.count) selected objects."
    return (active.id, active.vector, selected, summary)
  }

  private var targetObjects: [VectorObject] {
    guard let target = styleTarget else { return [] }
    return target.vector.objectsInDrawOrder.filter { target.objectIDs.contains($0.id) }
  }

  private var isLocked: Bool { model.activeVectorLayer?.isLocked == true }

  /// A locked selected object cannot change, but a merely active locked layer
  /// must not prevent the user from choosing defaults for a new vector object.
  private var selectionIsLocked: Bool { styleTarget != nil && isLocked }

  private var displayedStroke: VectorStrokeStyle? {
    guard styleTarget != nil else { return model.vectorToolStyle.fullStroke }
    return targetObjects.first?.stroke
  }

  private var displayedFill: VectorFillStyle? {
    guard styleTarget != nil else { return model.vectorToolStyle.fill }
    return targetObjects.first?.fill
  }

  private var strokeIsMixed: Bool { valuesDiffer(targetObjects.map(\.stroke)) }
  private var fillIsMixed: Bool { valuesDiffer(targetObjects.map(\.fill)) }

  private var fillIsEnabled: Bool {
    !selectionIsLocked && (styleTarget != nil || nextObject.hasClosedGeometry)
  }

  private var selectedCompoundFillRule: VectorFillRule? {
    let rules = Set(targetObjects.compactMap { $0.compound?.fillRule })
    return rules.count == 1 ? rules.first : nil
  }

  private var help: String {
    if styleTarget != nil {
      return "Stroke and fill edit the selected objects and also become defaults for the next \(nextObject.label). Fill is stored on open paths and appears when they are closed."
    }
    if !nextObject.hasClosedGeometry {
      return "Stroke describes the next \(nextObject.label). An open shape has no visible fill and can take arrowheads."
    }
    return "Stroke and fill describe the next \(nextObject.label). Closed geometry can use inside, centered, or outside strokes; arrowheads apply only to open geometry."
  }

  private func applyStroke(
    _ stroke: VectorStrokeStyle?, actionName: String, interactive: Bool
  ) {
    var style = model.vectorToolStyle
    style.setStroke(stroke)
    send(.setStyle(style))
    guard let target = styleTarget, !isLocked else { return }
    let updated = target.vector.updatingObjects(ids: target.objectIDs) { $0.stroke = stroke }
    send(.setVectorLayer(
      target.id, updated, actionName: actionName, interactive: interactive))
  }

  private func applyFill(
    _ fill: VectorFillStyle?, actionName: String, interactive: Bool
  ) {
    var style = model.vectorToolStyle
    style.setFill(fill)
    send(.setStyle(style))
    guard let target = styleTarget, !isLocked else { return }
    let updated = target.vector.updatingObjects(ids: target.objectIDs) { $0.fill = fill }
    send(.setVectorLayer(
      target.id, updated, actionName: actionName, interactive: interactive))
  }

  private func handleGesture(_ editing: Bool, _ actionName: String) {
    guard styleTarget != nil else { return }
    send(editing ? .beginGesture : .endGesture(actionName))
  }

  private func valuesDiffer<Value: Equatable>(_ values: [Value]) -> Bool {
    guard let first = values.first else { return false }
    return values.dropFirst().contains { $0 != first }
  }
}

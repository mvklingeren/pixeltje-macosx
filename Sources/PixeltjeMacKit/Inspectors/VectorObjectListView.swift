import PixeltjeMacDomain
import SwiftUI

/// The objects inside one vector layer, under the layer they belong to.
///
/// The placement rule puts this in the right panel beneath the selected vector
/// layer: paths and shapes are part of the layer, not of the project. Selection
/// is transient tool state shared with the canvas; renaming, duplicating,
/// deleting, and reordering are ordinary undoable recipe edits.
///
/// Visibility and locking stay at layer level for now, and nesting is left to
/// ordinary layer groups rather than a second hierarchy inside the layer.
struct VectorObjectListView: View {
  let layerID: ProjectLayerID
  let vector: VectorLayer
  let isLocked: Bool
  let selectedObjectIDs: Set<UUID>
  let send: (InspectorIntent) -> Void

  private typealias ExpandedState = SwiftUI.State<Bool>
  @ExpandedState private var isExpanded: Bool = true

  /// Topmost first, matching the layer list above it.
  private var rows: [VectorObject] {
    vector.objectsInDrawOrder.reversed()
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        header
        if isExpanded {
          if rows.isEmpty {
            Text(
              "No objects. Choose the Pen or Shape tool and draw on the canvas."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          } else {
            ForEach(rows) { object in
              VectorObjectRowView(
                object: object,
                isSelected: selectedObjectIDs.contains(object.id),
                isLocked: isLocked,
                onSelect: { extending in select(object.id, extending: extending) },
                onRename: { rename(object.id, to: $0) }
              )
            }
            actions
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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
      .accessibilityLabel(isExpanded ? "Collapse objects" : "Expand objects")

      Text("Objects")
        .font(.headline)
      Spacer()
      Text(rows.count, format: .number)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private var actions: some View {
    HStack(spacing: 6) {
      Button {
        reorder(.forward)
      } label: {
        Image(systemName: "arrow.up")
      }
      .help("Bring Forward")
      .accessibilityLabel("Bring forward")

      Button {
        reorder(.backward)
      } label: {
        Image(systemName: "arrow.down")
      }
      .help("Send Backward")
      .accessibilityLabel("Send backward")

      Button {
        reorder(.front)
      } label: {
        Image(systemName: "square.3.layers.3d.top.filled")
      }
      .help("Bring to Front")
      .accessibilityLabel("Bring to front")

      Button {
        reorder(.back)
      } label: {
        Image(systemName: "square.3.layers.3d.bottom.filled")
      }
      .help("Send to Back")
      .accessibilityLabel("Send to back")

      Divider().frame(height: 16)

      Button {
        duplicate()
      } label: {
        Image(systemName: "plus.square.on.square")
      }
      .help("Duplicate")
      .accessibilityLabel("Duplicate objects")

      Button(role: .destructive) {
        delete()
      } label: {
        Image(systemName: "trash")
      }
      .help("Delete")
      .accessibilityLabel("Delete objects")

      Spacer()
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isLocked || selectedObjectIDs.isEmpty)
  }

  // MARK: - Commands

  private func select(_ id: UUID, extending: Bool) {
    var next = selectedObjectIDs
    if extending {
      if next.contains(id) { next.remove(id) } else { next.insert(id) }
    } else {
      next = [id]
    }
    send(.selectVectorObjects(next))
  }

  private func rename(_ id: UUID, to name: String) {
    let renamed = vector.renaming(id: id, to: name)
    guard renamed != vector else { return }
    apply(renamed, actionName: "Rename Vector Object")
  }

  private func reorder(_ placement: VectorOrderPlacement) {
    let reordered = vector.reordering(ids: selectedObjectIDs, placement: placement)
    guard reordered != vector else { return }
    apply(reordered, actionName: placement.actionName)
  }

  private func duplicate() {
    let result = vector.duplicating(ids: selectedObjectIDs)
    guard !result.newIDs.isEmpty else { return }
    apply(result.layer, actionName: "Duplicate Vector Objects")
    // The copies are what the user is now working with, exactly as duplicating
    // a layer leaves the copy selected.
    send(.selectVectorObjects(Set(result.newIDs)))
  }

  private func delete() {
    let remaining = vector.removing(ids: selectedObjectIDs)
    guard remaining != vector else { return }
    send(.selectVectorObjects([]))
    apply(remaining, actionName: "Delete Vector Objects")
  }

  private func apply(_ updated: VectorLayer, actionName: String) {
    send(.change(.setVectorLayer(layerID, updated, actionName: actionName), interactive: false))
  }
}

/// One object row: what it looks like, what it is called, and whether it is
/// part of the current selection.
private struct VectorObjectRowView: View {
  let object: VectorObject
  let isSelected: Bool
  let isLocked: Bool
  let onSelect: (_ extending: Bool) -> Void
  let onRename: (String) -> Void

  private typealias NameState = SwiftUI.State<String>
  private typealias EditingState = SwiftUI.State<Bool>
  @NameState private var draftName: String = ""
  @EditingState private var isEditingName = false

  private var path: VectorPath? { object.path }
  private var shape: VectorShape? { object.shape }

  var body: some View {
    HStack(spacing: 8) {
      swatch
      if isEditingName {
        TextField("Name", text: $draftName)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .onSubmit(commitName)
          .accessibilityLabel("Object name")
      } else {
        VStack(alignment: .leading, spacing: 1) {
          Text(object.name)
            .font(.callout)
            .lineLimit(1)
          Text(summary)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      if !isLocked {
        Button {
          draftName = object.name
          isEditingName.toggle()
          if !isEditingName { commitName() }
        } label: {
          Image(systemName: "pencil")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isEditingName ? "Finish renaming" : "Rename \(object.name)")
      }
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
    )
    .overlay(
      // A border as well as a tint, so selection never rests on color alone.
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
    )
    .contentShape(Rectangle())
    .onTapGesture { onSelect(NSEvent.modifierFlags.contains(.shift)) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel("\(object.name), \(summary)")
    .accessibilityHint("Selects this object for styling and transforms.")
  }

  /// A miniature of the object's own fill and stroke, so the row is
  /// identifiable without reading the name. A gradient shows its ramp rather
  /// than one of its stops, which would misdescribe the object.
  @ViewBuilder
  private var swatch: some View {
    Group {
      if let gradient = object.fill?.gradient {
        GradientRampView(gradient: gradient)
      } else {
        RoundedRectangle(cornerRadius: 3)
          .fill(object.fill.map(\.color.swiftUIColor) ?? Color.clear)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 3)
        .strokeBorder(
          object.stroke.map(\.color.swiftUIColor) ?? Color.secondary, lineWidth: 1.5)
    )
    .frame(width: 18, height: 18)
  }

  /// What the row says the object is: a shape describes its parameters, a path
  /// describes its anchors.
  private var summary: String {
    if let shape {
      switch shape.kind {
      case .rectangle(let corners):
        return corners.isZero ? "rectangle" : "rounded rectangle"
      case .ellipse: return "ellipse"
      case .line: return "line"
      case .polygon(let sides): return "polygon, \(sides) sides"
      case .star(let points, _): return "star, \(points) points"
      }
    }
    guard let path else { return "object" }
    let closure = path.isClosed ? "closed" : "open"
    let anchors = path.anchors.count == 1 ? "1 anchor" : "\(path.anchors.count) anchors"
    return "\(closure), \(anchors)"
  }

  private func commitName() {
    isEditingName = false
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != object.name else { return }
    onRename(trimmed)
  }
}

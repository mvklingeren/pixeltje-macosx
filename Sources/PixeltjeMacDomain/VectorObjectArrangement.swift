import Foundation

/// Which edge or axis an alignment command lines objects up on.
public enum VectorAlignment: String, CaseIterable, Sendable {
  case left
  case horizontalCenter
  case right
  case top
  case verticalMiddle
  case bottom

  public var label: String {
    switch self {
    case .left: "Align Left"
    case .horizontalCenter: "Align Center"
    case .right: "Align Right"
    case .top: "Align Top"
    case .verticalMiddle: "Align Middle"
    case .bottom: "Align Bottom"
    }
  }

  public var symbolName: String {
    switch self {
    case .left: "align.horizontal.left"
    case .horizontalCenter: "align.horizontal.center"
    case .right: "align.horizontal.right"
    // Vector coordinates put y = 0 at the bottom, so Top is the high edge.
    case .top: "align.vertical.top"
    case .verticalMiddle: "align.vertical.center"
    case .bottom: "align.vertical.bottom"
    }
  }

  public var isHorizontal: Bool {
    switch self {
    case .left, .horizontalCenter, .right: true
    case .top, .verticalMiddle, .bottom: false
    }
  }
}

/// What alignment lines objects up against.
public enum VectorAlignmentReference: String, CaseIterable, Sendable {
  /// The combined extent of the objects being aligned. Aligning one object to
  /// itself does nothing, which is why a single selection normally uses the
  /// canvas instead.
  case selection
  /// The whole canvas.
  case canvas

  public var label: String {
    switch self {
    case .selection: "Selection"
    case .canvas: "Canvas"
    }
  }
}

public enum VectorDistributionAxis: String, CaseIterable, Sendable {
  case horizontal
  case vertical

  public var label: String {
    switch self {
    case .horizontal: "Distribute Horizontally"
    case .vertical: "Distribute Vertically"
    }
  }

  public var symbolName: String {
    switch self {
    case .horizontal: "distribute.horizontal.center"
    case .vertical: "distribute.vertical.center"
    }
  }
}

extension VectorLayer {
  /// The whole canvas, in the normalized coordinates objects live in.
  public static let canvasBounds = VectorBounds(minX: 0, minY: 0, maxX: 1, maxY: 1)

  /// Lines the named objects up on one edge or axis.
  ///
  /// Every object keeps its size and only moves, which is what alignment means:
  /// a command that resized artwork to fit an edge would be a different tool.
  public func aligning(
    ids: Set<UUID>,
    to alignment: VectorAlignment,
    reference: VectorAlignmentReference,
    pixelWidth: Double,
    pixelHeight: Double
  ) -> VectorLayer {
    guard !ids.isEmpty else { return self }
    let target: VectorBounds
    switch reference {
    case .canvas: target = Self.canvasBounds
    case .selection:
      guard let selection = bounds(of: ids, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      else { return self }
      target = selection
    }

    let aspect = pixelHeight > 0 ? pixelWidth / pixelHeight : 1
    var copy = self
    copy.objects = objects.map { object in
      guard ids.contains(object.id),
        let box = object.boundingBox(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      else { return object }
      let delta = offset(aligning: box, to: target, alignment: alignment)
      guard delta != .zero else { return object }
      return object.transformed(
        by: .translation(x: delta.x, y: delta.y), aspect: aspect)
    }
    return copy
  }

  private func offset(
    aligning box: VectorBounds, to target: VectorBounds, alignment: VectorAlignment
  ) -> VectorPoint {
    switch alignment {
    case .left: VectorPoint(x: target.minX - box.minX, y: 0)
    case .right: VectorPoint(x: target.maxX - box.maxX, y: 0)
    case .horizontalCenter: VectorPoint(x: target.center.x - box.center.x, y: 0)
    case .bottom: VectorPoint(x: 0, y: target.minY - box.minY)
    case .top: VectorPoint(x: 0, y: target.maxY - box.maxY)
    case .verticalMiddle: VectorPoint(x: 0, y: target.center.y - box.center.y)
    }
  }

  /// Spaces the named objects evenly between the outermost two.
  ///
  /// Centers are distributed rather than gaps: with objects of different sizes,
  /// even centers is what reads as evenly spaced, and it is what the outermost
  /// two staying put implies. Fewer than three objects have nothing to
  /// distribute.
  public func distributing(
    ids: Set<UUID>,
    axis: VectorDistributionAxis,
    pixelWidth: Double,
    pixelHeight: Double
  ) -> VectorLayer {
    guard ids.count >= 3 else { return self }
    let boxes: [(id: UUID, box: VectorBounds)] = objects.compactMap { object in
      guard ids.contains(object.id),
        let box = object.boundingBox(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      else { return nil }
      return (object.id, box)
    }
    guard boxes.count >= 3 else { return self }

    let sorted = boxes.sorted { first, second in
      axis == .horizontal
        ? first.box.center.x < second.box.center.x : first.box.center.y < second.box.center.y
    }
    guard let first = sorted.first, let last = sorted.last else { return self }
    let start = axis == .horizontal ? first.box.center.x : first.box.center.y
    let end = axis == .horizontal ? last.box.center.x : last.box.center.y
    let span = end - start
    guard abs(span) > 0 else { return self }

    let step = span / Double(sorted.count - 1)
    var deltas: [UUID: VectorPoint] = [:]
    for (index, entry) in sorted.enumerated() {
      let wanted = start + step * Double(index)
      let current = axis == .horizontal ? entry.box.center.x : entry.box.center.y
      let shift = wanted - current
      guard shift != 0 else { continue }
      deltas[entry.id] =
        axis == .horizontal ? VectorPoint(x: shift, y: 0) : VectorPoint(x: 0, y: shift)
    }

    let aspect = pixelHeight > 0 ? pixelWidth / pixelHeight : 1
    var copy = self
    copy.objects = objects.map { object in
      guard let delta = deltas[object.id] else { return object }
      return object.transformed(by: .translation(x: delta.x, y: delta.y), aspect: aspect)
    }
    return copy
  }

  /// Mirrors the named objects about the center of what is selected.
  ///
  /// Reflecting about the selection rather than each object's own center is
  /// what makes reflecting a group of objects rearrange them, which is the
  /// point of the command.
  public func reflecting(
    ids: Set<UUID>,
    horizontally: Bool,
    pixelWidth: Double,
    pixelHeight: Double
  ) -> VectorLayer {
    guard !ids.isEmpty,
      let box = bounds(of: ids, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    else { return self }
    let aspect = pixelHeight > 0 ? pixelWidth / pixelHeight : 1
    return transformingObjects(
      ids: ids,
      by: .reflection(horizontally: horizontally, about: box.center),
      aspect: aspect
    )
  }

  /// The named objects, lifted out of this layer.
  ///
  /// Used by Move Selection to New Vector Layer and by copying between layers,
  /// so both share one definition of what "these objects" means.
  public func extracting(ids: Set<UUID>) -> (remaining: VectorLayer, taken: [VectorObject]) {
    let taken = objectsInDrawOrder.filter { ids.contains($0.id) }
    guard !taken.isEmpty else { return (self, []) }
    return (removing(ids: ids), taken)
  }

  /// Adds objects on top, re-identifying them so pasting into the same layer
  /// twice cannot produce two objects that share an identity.
  public func adding(_ incoming: [VectorObject], reidentifying: Bool = true) -> (
    layer: VectorLayer, newIDs: [UUID]
  ) {
    guard !incoming.isEmpty else { return (self, []) }
    var copy = normalizingZOrder()
    var added: [VectorObject] = []
    for object in incoming {
      var next = object
      if reidentifying { next = Self.reidentified(object) }
      var names: [String] = []
      for existing in copy.objects { names.append(existing.name) }
      for existing in added { names.append(existing.name) }
      if names.contains(next.name) {
        next.name = Self.copyName(for: next.name, existing: names)
      }
      added.append(next)
    }
    var order = copy.objectIDsInDrawOrder
    order.append(contentsOf: added.map(\.id))
    copy.objects.append(contentsOf: added)
    return (copy.applying(order: order), added.map(\.id))
  }

  static func reidentified(_ object: VectorObject) -> VectorObject {
    switch object {
    case .path(var path):
      path.id = UUID()
      path.anchors = path.anchors.map { anchor in
        var fresh = anchor
        fresh.id = UUID()
        return fresh
      }
      return .path(path)
    case .shape(var shape):
      shape.id = UUID()
      return .shape(shape)
    case .compound(var compound):
      compound.id = UUID()
      compound.contours = compound.contours.map { contour in
        var fresh = contour
        fresh.id = UUID()
        fresh.anchors = contour.anchors.map { anchor in
          var anchor = anchor
          anchor.id = UUID()
          return anchor
        }
        return fresh
      }
      return .compound(compound)
    }
  }
}

extension LayerStackRecipe {
  /// The image aspect vector geometry is resolved against, or 1 before the
  /// canvas has a size.
  public var vectorAspect: Double {
    canvas.isResolved && canvas.height > 0
      ? Double(canvas.width) / Double(canvas.height) : 1
  }

  /// Moves the named objects out of their layer and into a new vector layer
  /// directly above it, which becomes active.
  ///
  /// Returns the new layer's identity so the caller can keep the same objects
  /// selected, or nil when there was nothing to move.
  public mutating func movingVectorObjectsToNewLayer(
    ids: Set<UUID>, from layerID: ProjectLayerID, name: String = "Vector Layer"
  ) -> (layerID: ProjectLayerID, objectIDs: [UUID])? {
    guard let source = layer(id: layerID), case .vector(let vector) = source.content,
      !source.isLocked
    else { return nil }
    let split = vector.extracting(ids: ids)
    guard !split.taken.isEmpty, !split.remaining.objects.isEmpty || !split.taken.isEmpty
    else { return nil }

    updateLayer(id: layerID) { $0.content = .vector(split.remaining) }
    // The objects keep their identity: they are the same artwork, moved, so
    // the selection that asked for the move still points at them.
    let moved = VectorLayer(objects: split.taken).normalizingZOrder()
    let created = ProjectLayer(
      name: name,
      isEnabled: true,
      isLocked: false,
      zOrder: source.zOrder,
      content: .vector(moved)
    )
    self = adding(created)
    activeLayerID = created.id
    return (created.id, moved.objectIDsInDrawOrder)
  }

  /// Copies objects into an existing vector layer, on top of what is there.
  public mutating func addingVectorObjects(
    _ incoming: [VectorObject], to layerID: ProjectLayerID
  ) -> [UUID] {
    guard let target = layer(id: layerID), case .vector(let vector) = target.content,
      !target.isLocked
    else { return [] }
    let result = vector.adding(incoming)
    updateLayer(id: layerID) { $0.content = .vector(result.layer) }
    return result.newIDs
  }
}

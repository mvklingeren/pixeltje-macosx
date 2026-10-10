import Foundation

/// Where a reordering command puts the objects it moves.
public enum VectorOrderPlacement: String, CaseIterable, Sendable {
  case front
  case forward
  case backward
  case back

  public var actionName: String {
    switch self {
    case .front: "Bring to Front"
    case .forward: "Bring Forward"
    case .backward: "Send Backward"
    case .back: "Send to Back"
    }
  }
}

extension VectorLayer {
  /// Objects bottom to top, the order the renderer draws them in.
  public var objectsInDrawOrder: [VectorObject] {
    objects.sorted { $0.zOrder < $1.zOrder }
  }

  /// Object identifiers bottom to top.
  public var objectIDsInDrawOrder: [UUID] {
    objectsInDrawOrder.map(\.id)
  }

  public func object(id: UUID) -> VectorObject? {
    objects.first { $0.id == id }
  }

  /// The gradient owned by any vector object kind.
  public func gradient(for id: UUID) -> VectorGradient? {
    object(id: id)?.fill?.gradient
  }

  /// Replaces an existing gradient without changing the object's concrete
  /// kind. Gradient handles edit paths, parametric shapes, and compound paths
  /// through this common appearance boundary.
  public func settingGradient(_ gradient: VectorGradient, for id: UUID) -> VectorLayer {
    guard self.gradient(for: id) != nil else { return self }
    return updatingObjects(ids: [id]) { object in
      var fill = object.fill
      fill?.gradient = gradient
      object.fill = fill
    }
  }

  /// Applies an edit to the named objects, or to every object when `ids` is
  /// nil. Objects the caller did not name are returned untouched, so a style
  /// change reaches exactly the current selection.
  public func updatingObjects(
    ids: Set<UUID>?, _ edit: (inout VectorObject) -> Void
  ) -> VectorLayer {
    var copy = self
    copy.objects = objects.map { object in
      guard ids?.contains(object.id) ?? true else { return object }
      var updated = object
      edit(&updated)
      return updated
    }
    return copy
  }

  /// The same, restricted to objects that are stored paths. Anchor editing has
  /// no meaning for a parametric shape, which is converted first.
  public func updatingPaths(
    ids: Set<UUID>?, _ edit: (inout VectorPath) -> Void
  ) -> VectorLayer {
    updatingObjects(ids: ids) { object in
      guard case .path(var path) = object else { return }
      edit(&path)
      object = .path(path)
    }
  }

  // MARK: - Ordering

  /// Rewrites `zOrder` to a dense 0-based sequence in the current draw order.
  ///
  /// Reordering commands work on positions rather than on the stored integers,
  /// so normalizing first keeps duplicates and gaps from making a move
  /// ambiguous.
  public func normalizingZOrder() -> VectorLayer {
    applying(order: objectIDsInDrawOrder)
  }

  /// Moves the named objects within the draw order, keeping their relative
  /// order among themselves.
  public func reordering(
    ids: Set<UUID>, placement: VectorOrderPlacement
  ) -> VectorLayer {
    guard !ids.isEmpty else { return self }
    var order = objectIDsInDrawOrder
    let moving = order.filter { ids.contains($0) }
    guard !moving.isEmpty, moving.count < order.count else { return self }

    switch placement {
    case .front:
      order.removeAll { ids.contains($0) }
      order.append(contentsOf: moving)
    case .back:
      order.removeAll { ids.contains($0) }
      order.insert(contentsOf: moving, at: 0)
    case .forward:
      // Walk from the top so a run of selected objects slides as a block
      // instead of the topmost one repeatedly swapping with the next.
      for index in stride(from: order.count - 2, through: 0, by: -1)
      where ids.contains(order[index]) && !ids.contains(order[index + 1]) {
        order.swapAt(index, index + 1)
      }
    case .backward:
      for index in 1..<max(order.count, 1) where ids.contains(order[index])
        && !ids.contains(order[index - 1])
      {
        order.swapAt(index, index - 1)
      }
    }

    return applying(order: order)
  }

  /// Puts one object at an absolute position in the draw order, which is what a
  /// drag in the object list asks for.
  public func moving(id: UUID, toDrawIndex index: Int) -> VectorLayer {
    var order = objectIDsInDrawOrder
    guard let current = order.firstIndex(of: id) else { return self }
    order.remove(at: current)
    order.insert(id, at: min(max(index, 0), order.count))
    return applying(order: order)
  }

  /// Rewrites `zOrder` so it matches the given bottom-to-top sequence.
  public func applying(order: [UUID]) -> VectorLayer {
    var copy = self
    copy.objects = objects.map { object in
      guard let index = order.firstIndex(of: object.id) else { return object }
      var updated = object
      updated.zOrder = index
      return updated
    }
    return copy
  }

  // MARK: - Object lifecycle

  /// Duplicates the named objects directly above the topmost of them, with
  /// fresh identity so the copies are independently selectable and undoable.
  ///
  /// Returns the layer and the new identifiers so the caller can select what it
  /// just made.
  public func duplicating(ids: Set<UUID>) -> (layer: VectorLayer, newIDs: [UUID]) {
    let originals = objectsInDrawOrder.filter { ids.contains($0.id) }
    guard !originals.isEmpty else { return (self, []) }

    var copy = normalizingZOrder()
    var copies: [VectorObject] = []
    for object in originals {
      // Identity is re-minted all the way down, so editing the copy cannot move
      // the original through a shared anchor or contour.
      var duplicate = Self.reidentified(object)
      var existingNames: [String] = []
      for existing in copy.objects { existingNames.append(existing.name) }
      for existing in copies { existingNames.append(existing.name) }
      duplicate.name = Self.copyName(for: object.name, existing: existingNames)
      copies.append(duplicate)
    }

    var order = copy.objectIDsInDrawOrder
    let insertionIndex = (order.lastIndex(where: { ids.contains($0) }) ?? order.endIndex - 1) + 1
    order.insert(contentsOf: copies.map(\.id), at: insertionIndex)
    copy.objects.append(contentsOf: copies)
    return (copy.applying(order: order), copies.map(\.id))
  }

  public func removing(ids: Set<UUID>) -> VectorLayer {
    var copy = self
    copy.objects.removeAll { ids.contains($0.id) }
    return copy.normalizingZOrder()
  }

  public func renaming(id: UUID, to name: String) -> VectorLayer {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return self }
    return updatingObjects(ids: [id]) { $0.name = trimmed }
  }

  static func copyName(for name: String, existing: [String]) -> String {
    let base = name.hasSuffix(" copy") ? name : "\(name) copy"
    guard existing.contains(base) else { return base }
    var index = 2
    while existing.contains("\(base) \(index)") { index += 1 }
    return "\(base) \(index)"
  }

  // MARK: - Hit testing and selection

  /// The topmost object under a click, or nil when the click missed.
  public func topmostObjectID(
    at point: VectorPoint, pixelWidth: Double, pixelHeight: Double, tolerance: Double
  ) -> UUID? {
    objectsInDrawOrder.reversed().first {
      $0.hitTest(
        point, pixelWidth: pixelWidth, pixelHeight: pixelHeight, tolerance: tolerance)
    }?.id
  }

  /// Every object whose rendered extent meets a marquee.
  public func objectIDs(
    intersecting box: VectorBounds, pixelWidth: Double, pixelHeight: Double
  ) -> Set<UUID> {
    var result: Set<UUID> = []
    for object in objects {
      guard let bounds = object.boundingBox(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
        bounds.intersects(box)
      else { continue }
      result.insert(object.id)
    }
    return result
  }

  /// The combined extent of the named objects, for selection handles and
  /// alignment.
  public func bounds(
    of ids: Set<UUID>, pixelWidth: Double, pixelHeight: Double
  ) -> VectorBounds? {
    objects
      .filter { ids.contains($0.id) }
      .compactMap { $0.boundingBox(pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
      .reduce(nil) { partial, box in partial?.union(box) ?? box }
  }

  // MARK: - Transforms

  /// Transforms the named objects, leaving the rest of the layer alone.
  ///
  /// `aspect` is the image's width divided by its height. A shape needs it to
  /// tell a rotation from a shear, and so to know whether it can stay
  /// parametric.
  public func transformingObjects(
    ids: Set<UUID>, by transform: VectorAffineTransform, aspect: Double = 1
  ) -> VectorLayer {
    guard !ids.isEmpty, !transform.isIdentity else { return self }
    var copy = self
    copy.objects = objects.map { object in
      ids.contains(object.id) ? object.transformed(by: transform, aspect: aspect) : object
    }
    return copy
  }

  /// Replaces the named shapes with the anchors they resolve to, keeping their
  /// identity, name, ordering, and appearance.
  public func convertingShapesToPaths(ids: Set<UUID>, aspect: Double = 1) -> VectorLayer {
    var copy = self
    copy.objects = objects.map { object in
      guard ids.contains(object.id), case .shape(let shape) = object else { return object }
      return .path(shape.convertedToPath(aspect: aspect))
    }
    return copy
  }

  /// Whether any of the named objects is still a parametric shape.
  public func containsShapes(ids: Set<UUID>) -> Bool {
    objects.contains { ids.contains($0.id) && $0.shape != nil }
  }
}

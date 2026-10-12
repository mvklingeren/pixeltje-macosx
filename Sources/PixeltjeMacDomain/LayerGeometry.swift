import Foundation

extension LayerFrame {
  /// The same rectangle, moved across the canvas by a delta in canvas pixels.
  public func translated(byX deltaX: Double, y deltaY: Double) -> LayerFrame {
    LayerFrame(x: x + deltaX, y: y + deltaY, width: width, height: height)
  }

  /// The smallest rectangle containing both.
  public func union(_ other: LayerFrame) -> LayerFrame {
    let minX = min(x, other.x)
    let minY = min(y, other.y)
    let maxX = max(x + width, other.x + other.width)
    let maxY = max(y + height, other.y + other.height)
    return LayerFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

extension LayerStackRecipe {
  /// The untransformed pixel bounds authored by one layer, before its own crop.
  ///
  /// A layer crop is stored as unit fractions of this rectangle, so the
  /// renderer measures the crop against it.
  public func cropFrame(of id: ProjectLayerID) -> LayerFrame? {
    guard let layer = layer(id: id) else { return nil }
    return frame(of: layer)
  }

  /// Whether the Crop tool can represent this layer with its rectangular
  /// overlay. Axis-aligned positive transforms preserve the recipe's unit
  /// rectangle; rotated, sheared, perspective and warped layers require a
  /// quadrilateral crop UI and are left for that dedicated path.
  public func canCropLayer(_ id: ProjectLayerID) -> Bool {
    guard let entry = entry(id: id), entry.layer.supportsLayerCrop,
      (!entry.layer.isLocked || id == .rawBackground),
      cropFrame(of: id)?.isEmpty == false
    else { return false }
    return ([entry.id] + entry.ancestorIDs).allSatisfy { layerID in
      guard let transform = layer(id: layerID)?.transform else { return true }
      return transform.supportsAxisAlignedCrop
    }
  }

  /// The rectangle a layer occupies on the canvas, in canvas pixels.
  ///
  /// This is what the Move tool outlines, so every layer kind answers in the
  /// one coordinate space the canvas extent is written in. A layer with no
  /// geometry yet — an empty vector layer, an empty group, or anything on a
  /// canvas whose size is still unresolved — has no rectangle rather than an
  /// arbitrary one.
  ///
  /// A cropped layer occupies only its crop rectangle. The pixels outside it
  /// are hidden, not deleted, so `uncroppedFrame(of:)` still reaches them.
  public func frame(of id: ProjectLayerID) -> LayerFrame? {
    guard let entry = entry(id: id), let visible = visibleFrame(of: entry.layer) else {
      return nil
    }
    return transformed(visible, for: entry)
  }

  /// The rectangle a layer would occupy on the canvas without its own crop.
  ///
  /// The Crop tool measures its rectangle against this, so an applied crop
  /// stays editable: the hidden pixels are still there to widen it over.
  public func uncroppedFrame(of id: ProjectLayerID) -> LayerFrame? {
    guard let entry = entry(id: id), let authored = frame(of: entry.layer) else { return nil }
    return transformed(authored, for: entry)
  }

  private func transformed(_ frame: LayerFrame, for entry: LayerStackEntry) -> LayerFrame {
    var result = frame
    // A child is first mapped by itself, then by its nearest parent outward.
    for layerID in [entry.id] + entry.ancestorIDs.reversed() {
      if let transform = layer(id: layerID)?.transform {
        result = transform.affineBounds(of: result)
      }
    }
    return result
  }

  /// What a layer shows before any transform: its authored bounds trimmed to
  /// its own crop. The crop is applied ahead of the transform, exactly as the
  /// renderer applies it, so a moved or scaled layer keeps the same window.
  private func visibleFrame(of layer: ProjectLayer) -> LayerFrame? {
    guard let frame = frame(of: layer) else { return nil }
    guard let crop = layer.crop, !crop.isFullFrame else { return frame }
    let rect = CropGeometry.pixelRect(crop, imageWidth: frame.width, imageHeight: frame.height)
    return LayerFrame(
      x: frame.x + rect.x,
      y: frame.y + rect.y,
      width: rect.width,
      height: rect.height
    )
  }

  private func frame(of layer: ProjectLayer) -> LayerFrame? {
    switch layer.content {
    case .image(let image):
      return image.frame
    case .raster(let raster):
      return raster.frame
    case .generatedInpaint(let inpaint):
      return inpaint.frame
    case .text(let text):
      return text.frame
    case .paint(let paint):
      // Interpolated points lie on the segments between captured samples, and
      // their pressure cannot exceed either endpoint. Unioning endpoint discs
      // therefore gives a conservative bound without replaying historical
      // stamps on the main actor whenever an overlay asks for layer geometry.
      var result: LayerFrame?
      for stroke in paint.surface.strokes {
        for sample in stroke.samples {
          let diameter = stroke.settings.size
            * max(stroke.settings.mappedPressure(sample.pressure), 0.05)
          let radius = diameter / 2
          let frame = LayerFrame(
            x: sample.x - radius,
            y: sample.y - radius,
            width: diameter,
            height: diameter
          )
          result = result.map { $0.union(frame) } ?? frame
        }
      }
      // A healed patch already knows exactly where its pixels are, so unlike a
      // stroke it needs no conservative estimate.
      for heal in paint.heals where heal.isRenderable {
        result = result.map { $0.union(heal.frame) } ?? heal.frame
      }
      if (!paint.fills.isEmpty || !paint.gradients.isEmpty), let canvasFrame {
        result = result.map { $0.union(canvasFrame) } ?? canvasFrame
      }
      return result
    case .vector(let vectorLayer):
      return frame(ofVector: vectorLayer)
    case .group(let group):
      // A group is wherever its children are visible.
      return group.children.compactMap { child in
        visibleFrame(of: child).map { child.transform?.affineBounds(of: $0) ?? $0 }
      }.reduce(nil) { union, frame in
        union.map { $0.union(frame) } ?? frame
      }
    case .adjustment:
      // An adjustment has no pixels of its own to outline.
      return nil
    case .developedRaw(let raw):
      // The original RAW background establishes the document extent. A
      // second RAW has an ordinary placement frame and is therefore outlined,
      // moved, and transformed like a placed image.
      return raw.frame ?? canvasFrame
    case .canvas:
      return canvasFrame
    }
  }

  /// Moves a layer's content across the canvas by a delta in canvas pixels.
  ///
  /// The delta composes, so a drag can send the pixels it has travelled since
  /// the last event and an undo can send the same distance back. Moving a
  /// group moves everything inside it that can move.
  public func translating(
    _ id: ProjectLayerID,
    byX deltaX: Double,
    y deltaY: Double
  ) -> LayerStackRecipe {
    guard deltaX != 0 || deltaY != 0, let layer = layer(id: id)
    else { return self }

    // Vector artwork is still a legacy canvas overlay. Its separately gated
    // compositor migration is what makes it a transform target; preserve its
    // existing normalized-coordinate Move behaviour in the meantime.
    if case .vector = layer.content {
      guard !layer.isLocked, let moved = translated(layer, byX: deltaX, y: deltaY) else { return self }
      var copy = self
      copy.updateLayer(id: id) { $0 = moved }
      return copy
    }
    guard canTransform(id), let reference = visibleFrame(of: layer) else { return self }

    // Translation is now part of the shared placement model. Old recipes retain
    // their legacy geometry until the first move, when the stable reference is
    // captured atomically with the edit. Like Free Transform's, the reference
    // is what the layer shows, so a cropped layer pivots on its visible center.
    var moved = layer
    var transform = layer.transform ?? .identity(for: reference)
    transform.position.x += deltaX
    transform.position.y += deltaY
    moved.transform = transform.isIdentity ? nil : transform

    var copy = self
    copy.updateLayer(id: id) { $0 = moved }
    return copy
  }

  /// Whether an edit can give this layer a transform. The check walks every
  /// ancestor, and groups are rejected when their full subtree contains content
  /// that still has a fixed/legacy composition path.
  public func canTransform(_ id: ProjectLayerID) -> Bool {
    guard let entry = entry(id: id), !entry.layer.isLocked,
      !entry.ancestorIDs.contains(where: { layer(id: $0)?.isLocked == true })
    else { return false }
    switch entry.layer.content {
    case .image, .raster, .generatedInpaint, .paint, .text: return true
    case .developedRaw(let raw): return raw.frame != nil
    case .group:
      return !subtree(of: entry.layer).contains { layer in
        if case .developedRaw(let raw) = layer.content, raw.frame == nil { return true }
        if case .vector = layer.content { return true }
        return false
      }
    case .vector, .canvas, .adjustment: return false
    }
  }

  /// Sets a transform only when it is finite, eligible, and preserves the
  /// group invariant. This is used for UI actions, hierarchy mutations and
  /// decoded projects alike, so unsupported descendants never slip in later.
  public func settingTransform(_ transform: LayerTransform?, for id: ProjectLayerID) -> LayerStackRecipe {
    guard canTransform(id), transform?.isValid ?? true else { return self }
    var copy = self
    copy.updateLayer(id: id) { $0.transform = transform?.isIdentity == true ? nil : transform }
    return copy.isTransformHierarchyValid ? copy : self
  }

  /// Validates the stored transform graph. It is intentionally public so file
  /// loading can report malformed projects instead of treating them as identity.
  public var isTransformHierarchyValid: Bool {
    func valid(_ layer: ProjectLayer, ancestors: [ProjectLayer]) -> Bool {
      guard layer.transform?.isValid ?? true else { return false }
      if case .developedRaw(let raw) = layer.content,
        raw.frame == nil,
        layer.transform?.isIdentity == false
      {
        // Only the base RAW owns document geometry. It cannot acquire a
        // per-layer transform through a malformed project recipe.
        return false
      }
      if let transform = layer.transform, !transform.isIdentity,
        case .group = layer.content,
        subtree(of: layer).dropFirst().contains(where: { child in
          if case .developedRaw(let raw) = child.content, raw.frame == nil { return true }
          if case .vector = child.content { return true }
          return false
        }) { return false }
      if case .group(let group) = layer.content, let warp = layer.transform?.warp {
        // A fixed mesh domain is not silently expanded by text reflow, source
        // replacement, a nested transform, or an inserted child. Every direct
        // child must remain fully authorable through the parent's mesh,
        // including pixels its crop hides, since that crop can be widened.
        for child in group.children {
          guard let rawBounds = frame(of: child) else { continue }
          let bounds = child.transform?.affineBounds(of: rawBounds) ?? rawBounds
          let maxX = bounds.x + bounds.width
          let maxY = bounds.y + bounds.height
          guard bounds.x >= warp.domain.x, bounds.y >= warp.domain.y,
            maxX <= warp.domain.x + warp.domain.width,
            maxY <= warp.domain.y + warp.domain.height
          else { return false }
        }
      }
      if ancestors.contains(where: { ancestor in
        guard let transform = ancestor.transform, !transform.isIdentity else { return false }
        if case .developedRaw(let raw) = layer.content, raw.frame == nil { return true }
        if case .vector = layer.content { return true }
        return false
      }) { return false }
      if case .group(let group) = layer.content {
        return group.children.allSatisfy { valid($0, ancestors: ancestors + [layer]) }
      }
      return true
    }
    return layers.allSatisfy { valid($0, ancestors: []) }
  }

  private func subtree(of layer: ProjectLayer) -> [ProjectLayer] {
    [layer] + {
      guard case .group(let group) = layer.content else { return [] }
      return group.children.flatMap(subtree)
    }()
  }

  /// The layer moved by a delta, or `nil` when nothing about it can move.
  private func translated(
    _ layer: ProjectLayer,
    byX deltaX: Double,
    y deltaY: Double
  ) -> ProjectLayer? {
    var copy = layer
    switch layer.content {
    case .image(var image):
      image.frame = image.frame.translated(byX: deltaX, y: deltaY)
      copy.content = .image(image)
    case .raster(var raster):
      raster.frame = raster.frame.translated(byX: deltaX, y: deltaY)
      copy.content = .raster(raster)
    case .generatedInpaint(var inpaint):
      inpaint.frame = inpaint.frame.translated(byX: deltaX, y: deltaY)
      copy.content = .generatedInpaint(inpaint)
    case .text(var text):
      text.frame = text.frame.translated(byX: deltaX, y: deltaY)
      copy.content = .text(text)
    case .paint(let paint):
      copy.content = .paint(paint.translated(byX: deltaX, y: deltaY))
    case .vector(var vectorLayer):
      // Vector geometry is normalized to the canvas extent, so a move measured
      // in canvas pixels becomes the fraction of the canvas it crosses.
      guard canvas.isResolved else { return nil }
      let delta = VectorPoint(
        x: deltaX / Double(canvas.width),
        y: deltaY / Double(canvas.height)
      )
      vectorLayer.objects = vectorLayer.objects.map { object -> VectorObject in
        guard case .path(var path) = object else { return object }
        path.anchors = path.anchors.map { $0.translated(by: delta) }
        return .path(path)
      }
      copy.content = .vector(vectorLayer)
    case .group(var group):
      // Locked children, such as a RAW background dragged into a group, stay
      // where they are; everything else in the group travels together.
      var movedAny = false
      group.children = group.children.map { child in
        guard !child.isLocked, let moved = translated(child, byX: deltaX, y: deltaY) else {
          return child
        }
        movedAny = true
        return moved
      }
      guard movedAny else { return nil }
      copy.content = .group(group)
    case .developedRaw(let raw):
      guard var frame = raw.frame else { return nil }
      frame = frame.translated(byX: deltaX, y: deltaY)
      var placed = raw
      placed.frame = frame
      copy.content = .developedRaw(placed)
    case .adjustment, .canvas:
      // An adjustment has no position and the canvas is the document extent.
      return nil
    }
    let offset = CanvasOffset(x: deltaX, y: deltaY)
    copy.masks = copy.masks.map { $0.resizingCanvas(from: canvas, to: canvas, offset: offset) }
    copy.layerMask = copy.layerMask?.resizingCanvas(from: canvas, to: canvas, offset: offset)
    return copy
  }

  private var canvasFrame: LayerFrame? {
    guard canvas.isResolved else { return nil }
    return LayerFrame(
      x: 0,
      y: 0,
      width: Double(canvas.width),
      height: Double(canvas.height)
    )
  }

  /// The canvas-pixel bounds of a vector layer's control points.
  ///
  /// Handles are included because the control polygon always contains the curve
  /// it draws: the box can be a little generous, but it never clips the
  /// artwork. Stroke width is not part of it; this is the geometry's extent,
  /// not the ink's.
  private func frame(ofVector layer: VectorLayer) -> LayerFrame? {
    guard canvas.isResolved else { return nil }
    var points: [VectorPoint] = []
    let aspect = Double(canvas.width) / Double(canvas.height)
    for path in layer.resolvedPaths(aspect: aspect) {
      for anchor in path.anchors {
        points.append(anchor.position)
        if let incoming = anchor.incomingHandle { points.append(incoming) }
        if let outgoing = anchor.outgoingHandle { points.append(outgoing) }
      }
    }
    guard let first = points.first else { return nil }

    var minimum = first
    var maximum = first
    for point in points.dropFirst() {
      minimum = VectorPoint(x: min(minimum.x, point.x), y: min(minimum.y, point.y))
      maximum = VectorPoint(x: max(maximum.x, point.x), y: max(maximum.y, point.y))
    }
    let width = Double(canvas.width)
    let height = Double(canvas.height)
    return LayerFrame(
      x: minimum.x * width,
      y: minimum.y * height,
      width: (maximum.x - minimum.x) * width,
      height: (maximum.y - minimum.y) * height
    )
  }
}

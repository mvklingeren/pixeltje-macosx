import Foundation
import PixeltjeMacDomain

/// Finds the frontmost visible vector object under a canvas point. Layer
/// transforms are undone before asking the vector layer to hit-test its own
/// geometry, so a transformed layer can still be selected with V.
enum VectorObjectPicker {
  static func pick(
    in stack: LayerStackRecipe,
    at point: VectorPoint,
    pixelWidth: Double,
    pixelHeight: Double,
    tolerance: Double
  ) -> (layerID: ProjectLayerID, objectID: UUID)? {
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    for entry in stack.flattenedLayers where entry.isEffectivelyEnabled
      && entry.effectiveOpacity > 0
    {
      guard case .vector(let vector) = entry.layer.content else { continue }
      guard let localPoint = localPoint(
        in: stack, layerID: entry.id, at: point,
        pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      else { continue }
      if let objectID = vector.topmostObjectID(
        at: localPoint,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        tolerance: tolerance)
      {
        return (entry.id, objectID)
      }
    }
    return nil
  }

  static func localPoint(
    in stack: LayerStackRecipe,
    layerID: ProjectLayerID,
    at point: VectorPoint,
    pixelWidth: Double,
    pixelHeight: Double
  ) -> VectorPoint? {
    guard pixelWidth > 0, pixelHeight > 0,
      let entry = stack.entry(id: layerID) else { return nil }
    var local = PixelPoint(x: point.x * pixelWidth, y: point.y * pixelHeight)
    // `ancestorIDs` runs from the outermost group to the nearest parent.
    // Inverse mappings therefore run in that order, then through the layer.
    for id in entry.ancestorIDs + [entry.id] {
      guard let transform = stack.layer(id: id)?.transform else { continue }
      // The renderer applies perspective, then affine. Undo them in reverse.
      // Mesh data is currently stored but not evaluated by the renderer.
      guard let affineLocal = transform.inverseAffine(local) else {
        return nil
      }
      if transform.perspective?.isIdentity == false {
        guard let perspective = PerspectiveMap(transform),
          let source = perspective.inverse(affineLocal)
        else { return nil }
        local = source
      } else {
        local = affineLocal
      }
    }
    return VectorPoint(x: local.x / pixelWidth, y: local.y / pixelHeight)
  }

  static func canvasBounds(
    _ bounds: VectorBounds,
    in stack: LayerStackRecipe,
    layerID: ProjectLayerID,
    pixelWidth: Double,
    pixelHeight: Double
  ) -> VectorBounds? {
    guard pixelWidth > 0, pixelHeight > 0,
      let entry = stack.entry(id: layerID) else { return nil }
    var frame = LayerFrame(
      x: bounds.minX * pixelWidth,
      y: bounds.minY * pixelHeight,
      width: bounds.width * pixelWidth,
      height: bounds.height * pixelHeight)
    for id in [entry.id] + entry.ancestorIDs.reversed() {
      guard let transform = stack.layer(id: id)?.transform else { continue }
      if transform.perspective?.isIdentity == false {
        guard let perspective = PerspectiveMap(transform) else { return nil }
        let corners = [
          PixelPoint(x: frame.x, y: frame.y),
          PixelPoint(x: frame.x + frame.width, y: frame.y),
          PixelPoint(x: frame.x + frame.width, y: frame.y + frame.height),
          PixelPoint(x: frame.x, y: frame.y + frame.height),
        ]
        let mapped = corners.compactMap { perspective.forward($0) }
        guard mapped.count == 4 else { return nil }
        let affine = mapped.map(transform.applyingAffine)
        guard let minX = affine.map(\.x).min(), let maxX = affine.map(\.x).max(),
          let minY = affine.map(\.y).min(), let maxY = affine.map(\.y).max()
        else { return nil }
        frame = LayerFrame(
          x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      } else {
        frame = transform.affineBounds(of: frame)
      }
    }
    return VectorBounds(
      minX: frame.x / pixelWidth,
      minY: frame.y / pixelHeight,
      maxX: (frame.x + frame.width) / pixelWidth,
      maxY: (frame.y + frame.height) / pixelHeight)
  }

  /// Maps an authored path anchor to the same canvas position as its layer's
  /// rendered geometry, including transforms on parent groups.
  static func canvasPoint(
    _ point: VectorPoint,
    in stack: LayerStackRecipe,
    layerID: ProjectLayerID,
    pixelWidth: Double,
    pixelHeight: Double
  ) -> VectorPoint? {
    guard pixelWidth > 0, pixelHeight > 0,
      let entry = stack.entry(id: layerID) else { return nil }
    var canvas = PixelPoint(x: point.x * pixelWidth, y: point.y * pixelHeight)
    for id in [entry.id] + entry.ancestorIDs.reversed() {
      guard let transform = stack.layer(id: id)?.transform else { continue }
      if transform.perspective?.isIdentity == false {
        guard let perspective = PerspectiveMap(transform),
          let mapped = perspective.forward(canvas)
        else { return nil }
        canvas = mapped
      }
      canvas = transform.applyingAffine(to: canvas)
    }
    return VectorPoint(x: canvas.x / pixelWidth, y: canvas.y / pixelHeight)
  }
}

/// The homography used by Core Image's perspective stage, expressed in the
/// document's bottom-left pixel coordinates. The four destination corners
/// come from the same reference rectangle and offsets as RenderEngine.
private struct PerspectiveMap {
  let reference: LayerFrame
  let a: Double
  let b: Double
  let c: Double
  let d: Double
  let e: Double
  let f: Double
  let g: Double
  let h: Double

  init?(_ transform: LayerTransform) {
    guard let corners = transform.perspective, !corners.isIdentity else { return nil }
    let rect = transform.referenceRect
    guard !rect.isEmpty else { return nil }
    reference = rect
    let p00 = PixelPoint(
      x: rect.x + corners.bottomLeft.x * rect.width,
      y: rect.y + corners.bottomLeft.y * rect.height)
    let p10 = PixelPoint(
      x: rect.x + rect.width + corners.bottomRight.x * rect.width,
      y: rect.y + corners.bottomRight.y * rect.height)
    let p11 = PixelPoint(
      x: rect.x + rect.width + corners.topRight.x * rect.width,
      y: rect.y + rect.height + corners.topRight.y * rect.height)
    let p01 = PixelPoint(
      x: rect.x + corners.topLeft.x * rect.width,
      y: rect.y + rect.height + corners.topLeft.y * rect.height)
    let dx1 = p10.x - p11.x
    let dx2 = p01.x - p11.x
    let dx3 = p00.x - p10.x + p11.x - p01.x
    let dy1 = p10.y - p11.y
    let dy2 = p01.y - p11.y
    let dy3 = p00.y - p10.y + p11.y - p01.y
    let projectiveG: Double
    let projectiveH: Double
    if abs(dx3) + abs(dy3) < 0.000_000_001 {
      projectiveG = 0
      projectiveH = 0
    } else {
      let determinant = dx1 * dy2 - dx2 * dy1
      guard abs(determinant) > 0.000_000_001 else { return nil }
      projectiveG = (dx3 * dy2 - dx2 * dy3) / determinant
      projectiveH = (dx1 * dy3 - dx3 * dy1) / determinant
    }
    g = projectiveG
    h = projectiveH
    a = p10.x - p00.x + projectiveG * p10.x
    b = p01.x - p00.x + projectiveH * p01.x
    c = p00.x
    d = p10.y - p00.y + projectiveG * p10.y
    e = p01.y - p00.y + projectiveH * p01.y
    f = p00.y
  }

  func forward(_ point: PixelPoint) -> PixelPoint? {
    let u = (point.x - reference.x) / reference.width
    let v = (point.y - reference.y) / reference.height
    let denominator = g * u + h * v + 1
    guard abs(denominator) > 0.000_000_001 else { return nil }
    return PixelPoint(
      x: (a * u + b * v + c) / denominator,
      y: (d * u + e * v + f) / denominator)
  }

  func inverse(_ point: PixelPoint) -> PixelPoint? {
    let m11 = point.x * g - a
    let m12 = point.x * h - b
    let m21 = point.y * g - d
    let m22 = point.y * h - e
    let rhsX = c - point.x
    let rhsY = f - point.y
    let determinant = m11 * m22 - m12 * m21
    guard abs(determinant) > 0.000_000_001 else { return nil }
    let u = (rhsX * m22 - m12 * rhsY) / determinant
    let v = (m11 * rhsY - rhsX * m21) / determinant
    return PixelPoint(
      x: reference.x + u * reference.width,
      y: reference.y + v * reference.height)
  }
}

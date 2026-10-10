import Foundation

/// A distance across the canvas, in canvas pixels.
public struct CanvasOffset: Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  public static let zero = CanvasOffset(x: 0, y: 0)
}

/// Which point of the old canvas stays where it is when the canvas is resized.
///
/// The nine points of a canvas-size dialog. Content is placed relative to the
/// chosen point: with `.topLeft` the top-left corner of the old canvas is the
/// top-left corner of the new one, so existing layers keep their distance from
/// it; with `.center` they stay centered.
public enum CanvasAnchor: String, Codable, CaseIterable, Sendable {
  case topLeft
  case top
  case topRight
  case left
  case center
  case right
  case bottomLeft
  case bottom
  case bottomRight

  /// The share of a width change that lands on the left of existing content:
  /// 0 keeps the left edge in place, 1 the right edge.
  public var horizontalFraction: Double {
    switch self {
    case .topLeft, .left, .bottomLeft: 0
    case .top, .center, .bottom: 0.5
    case .topRight, .right, .bottomRight: 1
    }
  }

  /// The share of a height change that lands below existing content, in the
  /// canonical bottom-left, y-up canvas space: 0 keeps the bottom edge in
  /// place, 1 the top edge.
  public var verticalFraction: Double {
    switch self {
    case .bottomLeft, .bottom, .bottomRight: 0
    case .left, .center, .right: 0.5
    case .topLeft, .top, .topRight: 1
    }
  }

  /// How far existing content moves when the canvas changes from `old` to
  /// `new`, in whole canvas pixels.
  ///
  /// Placement is stored in whole pixels, so an odd change centered on the
  /// canvas rounds rather than leaving layers on half pixels.
  public func contentOffset(from old: CanvasRecipe, to new: CanvasRecipe) -> CanvasOffset {
    CanvasOffset(
      x: (Double(new.width - old.width) * horizontalFraction).rounded(),
      y: (Double(new.height - old.height) * verticalFraction).rounded()
    )
  }

  /// The rows of the nine-point picker, top row first.
  public static let rows: [[CanvasAnchor]] = [
    [.topLeft, .top, .topRight],
    [.left, .center, .right],
    [.bottomLeft, .bottom, .bottomRight],
  ]

  public var label: String {
    switch self {
    case .topLeft: "Top Left"
    case .top: "Top"
    case .topRight: "Top Right"
    case .left: "Left"
    case .center: "Center"
    case .right: "Right"
    case .bottomLeft: "Bottom Left"
    case .bottom: "Bottom"
    case .bottomRight: "Bottom Right"
    }
  }
}

extension LayerStackRecipe {
  /// The stack on a canvas of a new size, with every layer placed by `anchor`.
  ///
  /// Image frames move by the anchor's offset. Vector geometry is normalized to
  /// the canvas extent, so it is measured in the old canvas's pixels, moved by
  /// the same offset, and normalized again to the new extent: the artwork
  /// keeps its pixel size and its distance from the anchored edge, exactly as
  /// a placed image does. Locked layers move too; the lock guards against the
  /// Move tool, not against the canvas changing underneath them.
  public func resizingCanvas(to size: CanvasRecipe, anchor: CanvasAnchor) -> LayerStackRecipe {
    guard size.isResolved, size != canvas else { return self }
    let old = canvas
    let offset = anchor.contentOffset(from: old, to: size)
    return resizingCanvas(to: size, offset: offset)
  }

  /// The same resize with an explicit content translation. Crop uses this to
  /// make an arbitrary source rectangle—not only a nine-point anchor—the new
  /// canvas origin.
  public func resizingCanvas(to size: CanvasRecipe, offset: CanvasOffset) -> LayerStackRecipe {
    guard size.isResolved, size != canvas else { return self }
    let old = canvas
    var copy = self
    copy.canvas = size
    guard old.isResolved else { return copy }

    let oldWidth = Double(old.width)
    let oldHeight = Double(old.height)
    let newWidth = Double(size.width)
    let newHeight = Double(size.height)
    let renormalize = { (point: VectorPoint) -> VectorPoint in
      VectorPoint(
        x: (point.x * oldWidth + offset.x) / newWidth,
        y: (point.y * oldHeight + offset.y) / newHeight
      )
    }

    func movingContent(in layer: ProjectLayer) -> ProjectLayer {
      var moved = layer
      // A transform owns this layer's placement. Moving its destination once
      // preserves its frozen authoring/reference geometry; for a group, the
      // parent move naturally carries every descendant with it.
      if var transform = moved.transform {
        transform.position.x += offset.x
        transform.position.y += offset.y
        moved.transform = transform
        return moved
      }
      moved.masks = moved.masks.map { $0.resizingCanvas(from: old, to: size, offset: offset) }
      moved.layerMask = moved.layerMask?.resizingCanvas(from: old, to: size, offset: offset)
      switch layer.content {
      case .image(var image):
        image.frame = image.frame.translated(byX: offset.x, y: offset.y)
        moved.content = .image(image)
      case .raster(var raster):
        raster.frame = raster.frame.translated(byX: offset.x, y: offset.y)
        moved.content = .raster(raster)
      case .generatedInpaint(var inpaint):
        inpaint.frame = inpaint.frame.translated(byX: offset.x, y: offset.y)
        moved.content = .generatedInpaint(inpaint)
      case .text(var text):
        text.frame = text.frame.translated(byX: offset.x, y: offset.y)
        moved.content = .text(text)
      case .paint(let paint):
        moved.content = .paint(paint.translated(byX: offset.x, y: offset.y))
      case .vector(var vectorLayer):
        vectorLayer.objects = vectorLayer.objects.map { object -> VectorObject in
          guard case .path(var path) = object else { return object }
          path.anchors = path.anchors.map { anchor in
            var moved = anchor
            moved.position = renormalize(anchor.position)
            moved.incomingHandle = anchor.incomingHandle.map(renormalize)
            moved.outgoingHandle = anchor.outgoingHandle.map(renormalize)
            return moved
          }
          return .path(path)
        }
        moved.content = .vector(vectorLayer)
      case .group(var group):
        group.children = group.children.map(movingContent)
        moved.content = .group(group)
      case .developedRaw(var raw):
        if let frame = raw.frame {
          raw.frame = frame.translated(byX: offset.x, y: offset.y)
          moved.content = .developedRaw(raw)
        }
      case .adjustment, .canvas:
        // The background RAW and canvas define document geometry; adjustment
        // layers are structural. None has a placement to move.
        break
      }
      return moved
    }
    copy.layers = copy.layers.map(movingContent)
    return copy
  }
}

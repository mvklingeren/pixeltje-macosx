import Foundation
import PixeltjeMacDomain

/// A readout for the geometry being drawn, measured against the document
/// canvas rather than the zoomed view or a proxy render. It describes the new
/// gesture, not an existing selection it may be added to or subtracted from.
enum SelectionMeasurement: Equatable {
  case dimensions(width: Int, height: Int)
  case area(squarePixels: Int)

  static func measure(_ generator: MaskGenerator, in canvas: CanvasRecipe) -> Self? {
    guard canvas.isResolved else { return nil }
    switch generator {
    case .rectangle(let shape):
      guard !shape.isEmpty else { return nil }
      let width = clippedLength(shape.origin.x, shape.maxX) * Double(canvas.width)
      let height = clippedLength(shape.origin.y, shape.maxY) * Double(canvas.height)
      guard width > 0, height > 0 else { return nil }
      return .dimensions(
        width: max(1, roundedPixels(width)), height: max(1, roundedPixels(height)))
    case .ellipse(let shape):
      guard !shape.isEmpty else { return nil }
      let center = shape.center
      let outline = (0..<128).map { index in
        let angle = Double(index) * 2 * .pi / 128
        return VectorPoint(
          x: center.x + cos(angle) * shape.width / 2,
          y: center.y + sin(angle) * shape.height / 2)
      }
      return measuredArea(of: outline, in: canvas)
    case .polygon(let polygon):
      guard !polygon.isEmpty else { return nil }
      return measuredArea(of: polygon.points, in: canvas)
    default:
      return nil
    }
  }

  var label: String {
    switch self {
    case .dimensions(let width, let height):
      return "\(width.formatted()) × \(height.formatted()) px"
    case .area(let squarePixels):
      // The vector area need not equal a count of partly covered or feathered
      // raster pixels, so the approximation sign is part of the unit readout.
      return "Area ≈ \(squarePixels.formatted()) px²"
    }
  }

  private static func clippedLength(_ first: Double, _ last: Double) -> Double {
    max(0, min(1, last) - max(0, first))
  }

  private static func measuredArea(
    of points: [VectorPoint], in canvas: CanvasRecipe
  ) -> Self? {
    let clipped = clipToCanvas(points)
    guard clipped.count >= 3 else { return nil }
    var twiceArea = 0.0
    for index in clipped.indices {
      let current = clipped[index]
      let next = clipped[(index + 1) % clipped.count]
      twiceArea += current.x * next.y - next.x * current.y
    }
    let pixels = abs(twiceArea) / 2 * Double(canvas.width) * Double(canvas.height)
    guard pixels.isFinite, pixels > 0 else { return nil }
    return .area(squarePixels: roundedPixels(pixels))
  }

  private static func roundedPixels(_ value: Double) -> Int {
    let rounded = value.rounded()
    return rounded >= Double(Int.max) ? Int.max : Int(rounded)
  }

  /// A lasso may leave the canvas while the pointer is held. Clip its polygon
  /// before measuring so the number describes selectable image area.
  private static func clipToCanvas(_ points: [VectorPoint]) -> [VectorPoint] {
    var result = points
    for edge in 0..<4 {
      let input = result
      result = []
      guard let last = input.last else { break }
      var previous = last
      for current in input {
        let previousInside = isInside(previous, edge: edge)
        let currentInside = isInside(current, edge: edge)
        if previousInside != currentInside {
          result.append(intersection(from: previous, to: current, edge: edge))
        }
        if currentInside { result.append(current) }
        previous = current
      }
    }
    return result
  }

  private static func isInside(_ point: VectorPoint, edge: Int) -> Bool {
    switch edge {
    case 0: point.x >= 0
    case 1: point.x <= 1
    case 2: point.y >= 0
    default: point.y <= 1
    }
  }

  private static func intersection(
    from start: VectorPoint, to end: VectorPoint, edge: Int
  ) -> VectorPoint {
    let vertical = edge < 2
    let boundary = edge.isMultiple(of: 2) ? 0.0 : 1.0
    let first = vertical ? start.x : start.y
    let second = vertical ? end.x : end.y
    let fraction = (boundary - first) / (second - first)
    return VectorPoint(
      x: start.x + (end.x - start.x) * fraction,
      y: start.y + (end.y - start.y) * fraction
    )
  }
}

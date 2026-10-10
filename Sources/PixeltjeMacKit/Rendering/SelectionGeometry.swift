import CoreGraphics
import PixeltjeMacDomain

/// Resolves the geometric part of a selection to the exact path its component
/// operations describe. The canvas uses this for marching ants; raster
/// consumers continue to use `MaskRenderer` so feather and density remain
/// coverage operations rather than vector approximations.
enum SelectionGeometry {
  static func path(for selection: MaskRecipe, in canvasRect: CGRect) -> CGPath? {
    guard selection.isEnabled, !canvasRect.isEmpty else { return nil }
    let canvas = CGPath(rect: canvasRect, transform: nil)
    var result: CGPath?

    for component in selection.components
    where component.isEnabled && component.availability.isAvailable && component.density > 0
    {
      guard var componentPath = path(for: component.generator, in: canvasRect) else { continue }
      if component.isInverted {
        componentPath = canvas.subtracting(componentPath)
      }
      guard let existing = result else {
        result = componentPath
        continue
      }
      switch component.combine {
      case .add:
        result = existing.union(componentPath)
      case .subtract:
        result = existing.subtracting(componentPath)
      case .intersect:
        result = existing.intersection(componentPath)
      }
    }

    if selection.isInverted {
      result = result.map { canvas.subtracting($0) } ?? canvas
    }
    guard let result, !result.isEmpty else { return nil }
    let containsCapturedRaster = selection.components.contains { component in
      switch component.generator {
      case .raster, .placedRaster: true
      default: false
      }
    }
    // Captured rasters are already emitted as non-overlapping closed contours.
    // Re-normalizing those contours on the main thread repeats expensive
    // boolean work without changing their geometry.
    return containsCapturedRaster ? result : result.normalized()
  }

  static func path(for generator: MaskGenerator, in canvasRect: CGRect) -> CGPath? {
    switch generator {
    case .rectangle(let shape):
      guard !shape.isEmpty else { return nil }
      let bounds = rect(for: shape, in: canvasRect)
      // The radius is a fraction of the shorter canvas edge, and the view rect
      // is the canvas drawn to scale, so its shorter edge is the same measure.
      // `MaskRenderer` reads it the same way, which is what keeps the ants on
      // the coverage they outline.
      let cornerRadius = min(
        shape.cornerRadius * min(canvasRect.width, canvasRect.height),
        min(bounds.width, bounds.height) / 2)
      guard cornerRadius > 0 else { return CGPath(rect: bounds, transform: nil) }
      return CGPath(
        roundedRect: bounds,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil)
    case .ellipse(let shape):
      guard !shape.isEmpty else { return nil }
      return CGPath(ellipseIn: rect(for: shape, in: canvasRect), transform: nil)
    case .polygon(let polygon):
      guard !polygon.isEmpty else { return nil }
      let path = CGMutablePath()
      path.move(to: point(polygon.points[0], in: canvasRect))
      for vertex in polygon.points.dropFirst() {
        path.addLine(to: point(vertex, in: canvasRect))
      }
      path.closeSubpath()
      return path
    case .raster(let raster):
      return rasterPath(raster, frame: .full, in: canvasRect)
    case .placedRaster(let placed):
      return rasterPath(placed.raster, frame: placed.frame, in: canvasRect)
    case .strokeSurface(let surface):
      return strokeSurfacePath(surface, in: canvasRect)
    default:
      return nil
    }
  }

  /// A deterministic vector fallback for marching ants around a painted mask.
  /// Rendering still uses the exact tiled stroke surface (including hardness,
  /// opacity and flow); this path is only the interactive outline. A stroked
  /// centreline per input stroke keeps the main-thread cost proportional to
  /// captured samples rather than to every interpolated stamp or canvas pixel.
  private static func strokeSurfacePath(
    _ surface: StrokeSurfaceRecipe,
    in canvasRect: CGRect
  ) -> CGPath? {
    guard surface.kind == .mask else { return nil }
    let canvas = CGPath(rect: canvasRect, transform: nil)
    var result: CGPath? = surface.initialCoverage > 0 ? canvas : nil
    for stroke in surface.strokes {
      guard stroke.settings.opacity > 0, stroke.settings.flow > 0,
        let first = stroke.samples.first
      else { continue }
      let line = CGMutablePath()
      line.move(to: CGPoint(
        x: canvasRect.minX + CGFloat(first.x),
        y: canvasRect.minY + CGFloat(first.y)))
      for sample in stroke.samples.dropFirst() {
        line.addLine(to: CGPoint(
          x: canvasRect.minX + CGFloat(sample.x),
          y: canvasRect.minY + CGFloat(sample.y)))
      }
      let diameter = stroke.samples.reduce(0.0) { partial, sample in
        max(
          partial,
          stroke.settings.size
            * max(stroke.settings.mappedPressure(sample.pressure), 0.05))
      }
      guard diameter > 0 else { continue }
      let displayDiameter = CGFloat(diameter)
      let coverage: CGPath
      if stroke.samples.count == 1 {
        coverage = CGPath(
          ellipseIn: CGRect(
            x: canvasRect.minX + CGFloat(first.x) - displayDiameter / 2,
            y: canvasRect.minY + CGFloat(first.y) - displayDiameter / 2,
            width: displayDiameter,
            height: displayDiameter),
          transform: nil)
      } else {
        coverage = line.copy(
          strokingWithWidth: displayDiameter,
          lineCap: .round,
          lineJoin: .round,
          miterLimit: 1)
      }
      switch stroke.mode {
      case .paint:
        result = result.map { $0.union(coverage) } ?? coverage
      case .erase:
        result = result?.subtracting(coverage)
      }
    }
    guard let result else { return nil }
    let clipped = result.intersection(canvas)
    return clipped.isEmpty ? nil : clipped
  }

  /// The occupied cells of a raster selection, without constructing its
  /// potentially enormous outline. Copy only needs this rectangle; the mask
  /// renderer still decides which pixels inside it have coverage.
  static func rasterBounds(for generator: MaskGenerator, in canvasRect: CGRect) -> CGRect? {
    switch generator {
    case .raster(let raster):
      return rasterBounds(raster, frame: .full, in: canvasRect)
    case .placedRaster(let placed):
      return rasterBounds(placed.raster, frame: placed.frame, in: canvasRect)
    default:
      return nil
    }
  }

  /// The same rectangle with its edges on whole canvas pixels.
  ///
  /// A selection encloses pixels, not continuous space. A pointer moves
  /// continuously, so a marquee left as drawn has edges that fall *between*
  /// pixels, and `MaskRenderer` covers those boundary pixels only partially.
  /// That partial coverage is indistinguishable from a feather nobody asked
  /// for, and it does not stop at the screen: a copy crops outward to whole
  /// pixels, so the soft edge travels onto the pasteboard and turns up as a
  /// halo around the result of File ▸ New from Clipboard.
  ///
  /// Only the rectangular marquee needs this. An ellipse is a curve that
  /// antialiases wherever it lands, so a whole-pixel bounding box would buy it
  /// nothing, and a lasso has no rectangle to snap in the first place.
  static func pixelSnapped(_ shape: ShapeMask, in canvas: CanvasRecipe) -> ShapeMask {
    guard canvas.isResolved, canvas.width > 0, canvas.height > 0 else { return shape }
    let (minX, maxX) = snap(from: shape.origin.x, to: shape.maxX, over: canvas.width)
    let (minY, maxY) = snap(from: shape.origin.y, to: shape.maxY, over: canvas.height)
    return ShapeMask(
      from: VectorPoint(x: minX, y: minY),
      to: VectorPoint(x: maxX, y: maxY),
      cornerRadius: shape.cornerRadius
    )
  }

  /// One axis, in normalized coordinates, put back on the pixel grid.
  private static func snap(
    from lower: Double,
    to upper: Double,
    over pixels: Int
  ) -> (Double, Double) {
    let count = Double(pixels)
    var low = (lower * count).rounded()
    var high = (upper * count).rounded()
    // A drag that crossed part of a pixel still meant to select one. Rounding
    // both edges onto the same boundary would quietly turn it into a click, and
    // a click is what deselects — so widen it, away from the canvas edge it
    // would otherwise fall off.
    if high == low, upper > lower {
      if high < count { high = low + 1 } else { low = high - 1 }
    }
    return (low / count, high / count)
  }

  private static func rect(for shape: ShapeMask, in canvasRect: CGRect) -> CGRect {
    let origin = point(shape.origin, in: canvasRect)
    let opposite = point(VectorPoint(x: shape.maxX, y: shape.maxY), in: canvasRect)
    return CGRect(
      x: min(origin.x, opposite.x),
      y: min(origin.y, opposite.y),
      width: abs(opposite.x - origin.x),
      height: abs(opposite.y - origin.y)
    )
  }

  private static func point(_ point: VectorPoint, in canvasRect: CGRect) -> CGPoint {
    CGPoint(
      x: canvasRect.minX + CGFloat(point.x) * canvasRect.width,
      y: canvasRect.minY + CGFloat(point.y) * canvasRect.height
    )
  }

  private static func rasterPath(
    _ raster: RasterMask, frame: ShapeMask, in canvasRect: CGRect
  ) -> CGPath? {
    guard !raster.isEmpty, !frame.isEmpty else { return nil }
    let origin = point(frame.origin, in: canvasRect)
    let cellWidth = canvasRect.width * CGFloat(frame.width) / CGFloat(raster.width)
    let cellHeight = canvasRect.height * CGFloat(frame.height) / CGFloat(raster.height)
    let width = raster.width
    let height = raster.height
    var occupied = [UInt8](repeating: 0, count: width * height)
    for run in raster.runs {
      let row = run.y * width
      for x in run.startX..<(run.startX + run.length) {
        occupied[row + x] = 1
      }
    }

    // Bits are directed cell edges with selected coverage on their left:
    // bottom→right, right→up, top→left, left→down. Shared interior edges are
    // omitted before any Core Graphics path is built, so photographic masks no
    // longer ask Quartz to boolean-normalize hundreds of thousands of run
    // rectangles on the main thread.
    var boundary = [UInt8](repeating: 0, count: occupied.count)
    for y in 0..<height {
      for x in 0..<width {
        let index = y * width + x
        guard occupied[index] != 0 else { continue }
        if y == 0 || occupied[index - width] == 0 { boundary[index] |= 1 << 0 }
        if x + 1 == width || occupied[index + 1] == 0 { boundary[index] |= 1 << 1 }
        if y + 1 == height || occupied[index + width] == 0 { boundary[index] |= 1 << 2 }
        if x == 0 || occupied[index - 1] == 0 { boundary[index] |= 1 << 3 }
      }
    }

    struct Edge {
      var cell: Int
      var bit: UInt8
      var startX: Int
      var startY: Int
      var direction: Int
    }

    var visited = [UInt8](repeating: 0, count: boundary.count)
    func edge(startX: Int, startY: Int, direction: Int) -> Edge? {
      let cellX: Int
      let cellY: Int
      switch direction {
      case 0: (cellX, cellY) = (startX, startY)
      case 1: (cellX, cellY) = (startX - 1, startY)
      case 2: (cellX, cellY) = (startX - 1, startY - 1)
      default: (cellX, cellY) = (startX, startY - 1)
      }
      guard (0..<width).contains(cellX), (0..<height).contains(cellY) else { return nil }
      let cell = cellY * width + cellX
      let bit = UInt8(1 << direction)
      guard boundary[cell] & bit != 0, visited[cell] & bit == 0 else { return nil }
      return Edge(
        cell: cell, bit: bit, startX: startX, startY: startY, direction: direction)
    }

    func startVertex(x: Int, y: Int, direction: Int) -> (x: Int, y: Int) {
      switch direction {
      case 0: (x, y)
      case 1: (x + 1, y)
      case 2: (x + 1, y + 1)
      default: (x, y + 1)
      }
    }

    func endVertex(of edge: Edge) -> (x: Int, y: Int) {
      switch edge.direction {
      case 0: (edge.startX + 1, edge.startY)
      case 1: (edge.startX, edge.startY + 1)
      case 2: (edge.startX - 1, edge.startY)
      default: (edge.startX, edge.startY - 1)
      }
    }

    func canvasPoint(x: Int, y: Int) -> CGPoint {
      CGPoint(
        x: origin.x + CGFloat(x) * cellWidth,
        y: origin.y + CGFloat(y) * cellHeight)
    }

    let path = CGMutablePath()
    let boundaryEdgeCount = boundary.reduce(0) { $0 + $1.nonzeroBitCount }
    for y in 0..<height {
      for x in 0..<width where boundary[y * width + x] != 0 {
        for direction in 0..<4 {
          let vertex = startVertex(x: x, y: y, direction: direction)
          guard var current = edge(
            startX: vertex.x, startY: vertex.y, direction: direction)
          else { continue }
          let first = (x: current.startX, y: current.startY)
          path.move(to: canvasPoint(x: first.x, y: first.y))
          var traversed = 0

          while traversed <= boundaryEdgeCount {
            visited[current.cell] |= current.bit
            traversed += 1
            let end = endVertex(of: current)
            if end == first {
              path.addLine(to: canvasPoint(x: end.x, y: end.y))
              path.closeSubpath()
              break
            }

            // At a diagonal touch two contours share one vertex. Prefer the
            // left turn, which keeps each four-connected selected region on
            // the left side of its own contour instead of splicing them.
            let candidates = [
              (current.direction + 1) % 4,
              current.direction,
              (current.direction + 3) % 4,
              (current.direction + 2) % 4,
            ]
            guard let next = candidates.lazy.compactMap({ direction in
              edge(startX: end.x, startY: end.y, direction: direction)
            }).first else {
              path.addLine(to: canvasPoint(x: end.x, y: end.y))
              path.closeSubpath()
              break
            }
            if next.direction != current.direction {
              path.addLine(to: canvasPoint(x: end.x, y: end.y))
            }
            current = next
          }
        }
      }
    }
    return path.isEmpty ? nil : path
  }

  private static func rasterBounds(
    _ raster: RasterMask, frame: ShapeMask, in canvasRect: CGRect
  ) -> CGRect? {
    guard !raster.isEmpty, !frame.isEmpty else { return nil }
    var minX = raster.width
    var minY = raster.height
    var maxX = 0
    var maxY = 0
    for run in raster.runs {
      minX = min(minX, run.startX)
      minY = min(minY, run.y)
      maxX = max(maxX, run.startX + run.length)
      maxY = max(maxY, run.y + 1)
    }
    let origin = point(frame.origin, in: canvasRect)
    let cellWidth = canvasRect.width * CGFloat(frame.width) / CGFloat(raster.width)
    let cellHeight = canvasRect.height * CGFloat(frame.height) / CGFloat(raster.height)
    return CGRect(
      x: origin.x + CGFloat(minX) * cellWidth,
      y: origin.y + CGFloat(minY) * cellHeight,
      width: CGFloat(maxX - minX) * cellWidth,
      height: CGFloat(maxY - minY) * cellHeight)
  }
}

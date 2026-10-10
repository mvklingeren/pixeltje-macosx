import CoreGraphics
import CoreImage
import Foundation
import PixeltjeMacDomain

enum VectorArtworkRenderer {
  /// Renders one vector layer at full opacity. Layer masks, transforms, blend
  /// mode, fill and opacity are applied by `RenderEngine` after this source has
  /// joined the same recursive compositor as every other layer type.
  static func makeImage(
    vectorLayer: VectorLayer,
    width: Int,
    height: Int,
    workingColorSpace: CGColorSpace,
    region: CGRect? = nil
  ) throws -> CIImage? {
    let layer = ProjectLayer(
      name: "Vector Source",
      isEnabled: true,
      isLocked: false,
      zOrder: 1,
      content: .vector(vectorLayer))
    return try makeImage(
      layerStack: LayerStackRecipe(layers: [layer], activeLayerID: layer.id),
      width: width,
      height: height,
      workingColorSpace: workingColorSpace,
      region: region)
  }

  static func makeImage(
    layerStack: LayerStack,
    width: Int,
    height: Int,
    workingColorSpace: CGColorSpace,
    region: CGRect? = nil
  ) throws -> CIImage? {
    guard
      let cgImage = try makeCGImage(
        layerStack: layerStack,
        width: width,
        height: height,
        workingColorSpace: workingColorSpace,
        region: region
      )
    else { return nil }
    return CIImage(cgImage: cgImage)
  }

  static func makeCGImage(
    layerStack: LayerStack,
    width: Int,
    height: Int,
    workingColorSpace: CGColorSpace,
    region: CGRect? = nil
  ) throws -> CGImage? {
    let vectorLayers = layerStack.vectorArtwork
    guard !vectorLayers.isEmpty, width > 0, height > 0 else { return nil }

    let canvasBounds = CGRect(x: 0, y: 0, width: width, height: height)
    let renderBounds = (region?.integral ?? canvasBounds).intersection(canvasBounds)
    guard !renderBounds.isNull, renderBounds.width >= 1, renderBounds.height >= 1 else {
      return nil
    }

    guard
      let context = makeContext(
        width: Int(renderBounds.width),
        height: Int(renderBounds.height),
        fallback: workingColorSpace)
    else {
      throw PixeltjeMacError(
        "Vector rendering failed",
        "Could not allocate the transparent vector artwork surface."
      )
    }

    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.setBlendMode(.normal)

    for entry in vectorLayers where entry.effectiveOpacity > 0 {
      // A layer's opacity applies to the layer as a whole, not to each path:
      // overlapping paths inside one layer must not show through each other.
      let fades = entry.effectiveOpacity < 1
      if fades {
        context.saveGState()
        context.setAlpha(entry.effectiveOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
      }
      // Shapes and compound paths resolve to geometry here, so the renderer
      // never has to know which case it is drawing.
      let aspect = Double(width) / Double(height)
      let mapping: (VectorPoint) -> CGPoint = {
        let canvasPoint = cgPoint($0, width: Double(width), height: Double(height))
        return CGPoint(
          x: canvasPoint.x - renderBounds.minX,
          y: canvasPoint.y - renderBounds.minY)
      }
      for object in entry.vectorLayer.objectsInDrawOrder {
        draw(object, aspect: aspect, in: context, mapping: mapping)
      }
      if fades {
        context.endTransparencyLayer()
        context.restoreGState()
      }
    }

    guard let cgImage = context.makeImage() else {
      throw PixeltjeMacError(
        "Vector rendering failed",
        "Core Graphics did not produce vector artwork pixels."
      )
    }
    return cgImage
  }

  /// Draws one object: every contour it has, filled as a whole under its fill
  /// rule and then stroked.
  ///
  /// A compound path's contours must be filled together or a hole would come
  /// out solid, which is why the fill takes the combined path rather than one
  /// contour at a time.
  static func draw(
    _ object: VectorObject,
    aspect: Double,
    in context: CGContext,
    mapping: (VectorPoint) -> CGPoint
  ) {
    let contours = object.resolvedContours(aspect: aspect).filter { $0.anchors.count >= 2 }
    guard !contours.isEmpty else { return }

    let combined = CGMutablePath()
    for contour in contours { combined.addPath(makePath(contour, mapping: mapping)) }

    if object.isClosed, let fill = object.fill {
      applyFill(
        fill, to: combined, in: context, fillRule: object.fillRule, mapping: mapping)
    }
    if let stroke = object.stroke {
      applyStroke(
        stroke,
        contours: contours,
        cgPath: combined,
        isClosed: object.isClosed,
        in: context,
        mapping: mapping)
    }
  }

  /// The one fill evaluator: the canvas overlay, thumbnails, rasterization, and
  /// export all paint a fill through this function, so none of them can
  /// disagree about what a recipe means.
  ///
  /// The path is filled in place; the caller supplies a context already set up
  /// in the working space.
  static func applyFill(
    _ fill: VectorFillStyle,
    to cgPath: CGPath,
    in context: CGContext,
    fillRule: VectorFillRule = .nonZero,
    mapping point: (VectorPoint) -> CGPoint
  ) {
    let rule: CGPathFillRule = fillRule == .evenOdd ? .evenOdd : .winding
    switch fill.content {
    case .solid(let color):
      guard fill.opacity > 0, color.alpha > 0 else { return }
      context.addPath(cgPath)
      context.setFillColor(cgColor(color, opacity: fill.opacity))
      context.fillPath(using: rule)
    case .gradient(let gradient):
      guard gradient.opacity > 0 else { return }
      context.saveGState()
      context.addPath(cgPath)
      context.clip(using: rule)
      drawGradient(
        gradient, in: context, bounds: cgPath.boundingBoxOfPath, mapping: point)
      context.restoreGState()
    }
  }

  /// The one stroke evaluator: alignment, dashes, joins, and arrowheads, drawn
  /// the same way for the canvas overlay and for export.
  ///
  /// `contours` supply the geometry the arrowheads need to orient themselves;
  /// `cgPath` is that same geometry already mapped into the context.
  static func applyStroke(
    _ stroke: VectorStrokeStyle,
    contours: [VectorPath],
    cgPath: CGPath,
    isClosed: Bool,
    in context: CGContext,
    mapping point: (VectorPoint) -> CGPoint
  ) {
    guard stroke.isVisible else { return }
    context.saveGState()
    context.setStrokeColor(cgColor(stroke.effectiveColor))
    context.setLineCap(cgLineCap(stroke.lineCap))
    context.setLineJoin(cgLineJoin(stroke.lineJoin))
    context.setMiterLimit(CGFloat(stroke.miterLimit))
    if let dashes = stroke.usableDashPattern {
      context.setLineDash(
        phase: CGFloat(stroke.dashPhase), lengths: dashes.map { CGFloat($0) })
    } else {
      context.setLineDash(phase: 0, lengths: [])
    }

    // Core Graphics only strokes on the center line. Inside and outside are the
    // familiar trick: stroke twice as wide and clip away the half that should
    // not show. Only a closed outline has an inside, so an open path is always
    // centered whatever the recipe says.
    let alignment = isClosed ? stroke.alignment : .center
    switch alignment {
    case .center:
      context.setLineWidth(stroke.width)
      context.addPath(cgPath)
      context.strokePath()
    case .inside:
      context.addPath(cgPath)
      context.clip(using: .evenOdd)
      context.setLineWidth(stroke.width * 2)
      context.addPath(cgPath)
      context.strokePath()
    case .outside:
      // Everything except the shape's interior: the surface plus the shape,
      // clipped even-odd, is the complement.
      let complement = CGMutablePath()
      complement.addRect(
        CGRect(x: 0, y: 0, width: context.width, height: context.height)
          .insetBy(dx: -CGFloat(stroke.width) * 4, dy: -CGFloat(stroke.width) * 4))
      complement.addPath(cgPath)
      context.addPath(complement)
      context.clip(using: .evenOdd)
      context.setLineWidth(stroke.width * 2)
      context.addPath(cgPath)
      context.strokePath()
    }
    context.restoreGState()

    for contour in contours where !contour.isClosed {
      drawArrowheads(stroke, on: contour, in: context, mapping: point)
    }
  }

  /// Heads at the ends of an open stroke, pointing the way the path runs.
  ///
  /// A closed path has no ends, so it gets none. The head is filled with the
  /// stroke's own color and sized from its width, so it stays in proportion.
  private static func drawArrowheads(
    _ stroke: VectorStrokeStyle,
    on path: VectorPath,
    in context: CGContext,
    mapping point: (VectorPoint) -> CGPoint
  ) {
    guard !path.isClosed, path.anchors.count >= 2 else { return }
    guard stroke.startArrowhead != nil || stroke.endArrowhead != nil else { return }
    let outline = path.flattened().map(point)
    guard outline.count >= 2 else { return }

    if let head = stroke.startArrowhead {
      // The start points backwards along the path, which is what an arrow at
      // the beginning means.
      draw(
        head, at: outline[0], towards: outline[0], from: outline[1],
        stroke: stroke, in: context)
    }
    if let head = stroke.endArrowhead {
      let last = outline.count - 1
      draw(
        head, at: outline[last], towards: outline[last], from: outline[last - 1],
        stroke: stroke, in: context)
    }
  }

  private static func draw(
    _ head: VectorArrowhead,
    at tip: CGPoint,
    towards: CGPoint,
    from previous: CGPoint,
    stroke: VectorStrokeStyle,
    in context: CGContext
  ) {
    let dx = towards.x - previous.x
    let dy = towards.y - previous.y
    let length = hypot(dx, dy)
    guard length > 0 else { return }
    let ux = dx / length
    let uy = dy / length
    let size = CGFloat(stroke.width * head.scale)
    let half = size / 2

    context.saveGState()
    context.setFillColor(cgColor(stroke.effectiveColor))
    context.setStrokeColor(cgColor(stroke.effectiveColor))
    context.setLineWidth(stroke.width)
    context.setLineCap(cgLineCap(stroke.lineCap))
    context.setLineJoin(cgLineJoin(stroke.lineJoin))
    context.setLineDash(phase: 0, lengths: [])

    let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
    let left = CGPoint(x: base.x - uy * half, y: base.y + ux * half)
    let right = CGPoint(x: base.x + uy * half, y: base.y - ux * half)

    let shape = CGMutablePath()
    switch head.style {
    case .triangle:
      shape.move(to: tip)
      shape.addLine(to: left)
      shape.addLine(to: right)
      shape.closeSubpath()
      context.addPath(shape)
      context.fillPath()
    case .openTriangle:
      shape.move(to: left)
      shape.addLine(to: tip)
      shape.addLine(to: right)
      context.addPath(shape)
      context.strokePath()
    case .circle:
      let radius = half
      context.addPath(
        CGPath(
          ellipseIn: CGRect(
            x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2),
          transform: nil))
      context.fillPath()
    case .square:
      let side = half
      shape.move(to: CGPoint(x: tip.x - ux * side - uy * side, y: tip.y - uy * side + ux * side))
      shape.addLine(to: CGPoint(x: tip.x + ux * side - uy * side, y: tip.y + uy * side + ux * side))
      shape.addLine(to: CGPoint(x: tip.x + ux * side + uy * side, y: tip.y + uy * side - ux * side))
      shape.addLine(to: CGPoint(x: tip.x - ux * side + uy * side, y: tip.y - uy * side - ux * side))
      shape.closeSubpath()
      context.addPath(shape)
      context.fillPath()
    case .bar:
      shape.move(to: CGPoint(x: tip.x - uy * half, y: tip.y + ux * half))
      shape.addLine(to: CGPoint(x: tip.x + uy * half, y: tip.y - ux * half))
      context.addPath(shape)
      context.strokePath()
    }
    context.restoreGState()
  }

  /// Paints a gradient across the current clip.
  ///
  /// Core Graphics interpolates in the gradient's own color space, so the ramp
  /// is built in extended linear Display P3 — the working space — rather than
  /// in the encoded space the stops are authored in. That is what keeps the
  /// blend physically even and free of the banding an 8-bit sRGB ramp shows.
  private static func drawGradient(
    _ gradient: VectorGradient,
    in context: CGContext,
    bounds: CGRect,
    mapping point: (VectorPoint) -> CGPoint
  ) {
    let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    let space =
      linearSpace
      ?? CGColorSpace(name: CGColorSpace.displayP3)
      ?? CGColorSpaceCreateDeviceRGB()
    guard
      let ramp = makeCGGradient(
        gradient,
        opacity: gradient.opacity,
        in: space,
        usesLinearComponents: linearSpace != nil)
    else { return }

    let start = point(gradient.start)
    let end = point(gradient.end)
    // Padding beyond both ends is the first release's only spread mode; repeat
    // and reflect arrive with the second.
    let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

    switch gradient.kind {
    case .linear:
      guard start != end else {
        // A zero-length gradient has no direction; fill flat with its last stop
        // rather than drawing nothing.
        context.setFillColor(cgColor(gradient.color(at: 1), opacity: gradient.opacity))
        context.fill(bounds)
        return
      }
      context.drawLinearGradient(ramp, start: start, end: end, options: options)
    case .radial:
      let radius = hypot(end.x - start.x, end.y - start.y)
      guard radius > 0 else {
        context.setFillColor(cgColor(gradient.color(at: 1), opacity: gradient.opacity))
        context.fill(bounds)
        return
      }
      let focal = gradient.focal.map(point) ?? start
      context.saveGState()
      // An ellipse is a circle drawn under a scale about the center, rotated so
      // the primary radius still points at the end handle.
      if gradient.aspectRatio != 1 {
        let angle = atan2(end.y - start.y, end.x - start.x)
        context.translateBy(x: start.x, y: start.y)
        context.rotate(by: angle)
        context.scaleBy(x: 1, y: CGFloat(gradient.aspectRatio))
        context.rotate(by: -angle)
        context.translateBy(x: -start.x, y: -start.y)
      }
      context.drawRadialGradient(
        ramp,
        startCenter: focal,
        startRadius: 0,
        endCenter: start,
        endRadius: radius,
        options: options
      )
      context.restoreGState()
    }
  }

  /// The gradient as Core Graphics wants it: colors and locations, with each
  /// non-neutral midpoint expanded into intermediate samples.
  ///
  /// `CGGradient` blends linearly between adjacent stops and has no notion of a
  /// midpoint, so a span whose midpoint is not centered is subdivided finely
  /// enough that the eased curve is indistinguishable from the intended one.
  private static func makeCGGradient(
    _ gradient: VectorGradient,
    opacity: Double,
    in space: CGColorSpace,
    usesLinearComponents: Bool
  ) -> CGGradient? {
    var colors: [CGColor] = []
    var locations: [CGFloat] = []

    func append(at position: Double) {
      // Core Graphics requires strictly non-decreasing locations.
      let location = CGFloat(min(max(position, 0), 1))
      if let last = locations.last, location < last { return }
      let color = usesLinearComponents
        ? gradient.linearColor(at: position)
        : gradient.color(at: position)
      let alpha = color.alpha * min(max(opacity, 0), 1)
      colors.append(
        CGColor(
          colorSpace: space,
          components: [color.red, color.green, color.blue, alpha])
          ?? cgColor(gradient.color(at: position), opacity: opacity))
      locations.append(location)
    }

    let stops = gradient.stops
    guard stops.count >= 2 else { return nil }
    append(at: stops[0].position)
    for index in 0..<(stops.count - 1) {
      let lower = stops[index]
      let upper = stops[index + 1]
      let span = upper.position - lower.position
      if span > 0, abs(lower.midpoint - 0.5) > 0.000_1 {
        let steps = 16
        for step in 1..<steps {
          let t = Double(step) / Double(steps)
          append(at: lower.position + span * t)
        }
      }
      append(at: upper.position)
    }

    return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
  }

  /// The surface vector artwork is materialized into.
  ///
  /// Extended linear Display P3 at 16-bit float is the application's working
  /// space. Materializing there rather than through an 8-bit intermediate is
  /// what keeps gradients free of banding and lets artwork carry EDR values;
  /// it also means the canvas, thumbnails, rasterization, and export all read
  /// the same numbers.
  ///
  /// Some configurations refuse the float context. Falling back to 8-bit
  /// Display P3 keeps ordinary solid artwork rendering rather than failing the
  /// whole frame.
  static func makeContext(
    width: Int, height: Int, fallback: CGColorSpace
  ) -> CGContext? {
    if let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
      let info =
        CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
      if let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 16,
        bytesPerRow: width * 8,
        space: space,
        bitmapInfo: info
      ) {
        return context
      }
    }

    let space = CGColorSpace(name: CGColorSpace.displayP3) ?? fallback
    return CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: space,
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    )
  }

  static func makePath(_ path: VectorPath, width: Double, height: Double) -> CGPath {
    makePath(path) { cgPoint($0, width: width, height: height) }
  }

  /// The one place a `VectorPath` becomes a `CGPath`.
  ///
  /// The canvas overlay maps into view points while the render path maps into
  /// image pixels, but which segments exist, which are straight, and whether
  /// the subpath closes must not differ between them. Only the mapping is a
  /// parameter, so the canvas cannot drift from what export draws.
  static func makePath(
    _ path: VectorPath, mapping point: (VectorPoint) -> CGPoint
  ) -> CGPath {
    let result = CGMutablePath()
    guard let first = path.anchors.first else { return result }
    result.move(to: point(first.position))

    let segmentCount = path.isClosed ? path.anchors.count : max(path.anchors.count - 1, 0)
    for index in 0..<segmentCount {
      guard let cubic = path.segment(startingAt: index) else { continue }
      let isStraight = cubic.control1 == cubic.start && cubic.control2 == cubic.end
      if isStraight {
        result.addLine(to: point(cubic.end))
      } else {
        result.addCurve(
          to: point(cubic.end),
          control1: point(cubic.control1),
          control2: point(cubic.control2)
        )
      }
    }
    if path.isClosed { result.closeSubpath() }
    return result
  }

  private static func cgPoint(_ point: VectorPoint, width: Double, height: Double) -> CGPoint {
    CGPoint(x: point.x * width, y: point.y * height)
  }

  /// A vector color as authored: `VectorColor` components are Display P3, the
  /// space the color wells write. Core Graphics converts them into whatever
  /// space the context uses, so the same recipe means the same color whether
  /// the surface is linear float or 8-bit.
  private static func cgColor(_ color: VectorColor, opacity: Double = 1) -> CGColor {
    let alpha = color.alpha * min(max(opacity, 0), 1)
    let space = CGColorSpace(name: CGColorSpace.displayP3)
    return space.flatMap {
      CGColor(colorSpace: $0, components: [color.red, color.green, color.blue, alpha])
    } ?? CGColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
  }

  private static func cgLineCap(_ cap: VectorLineCap) -> CGLineCap {
    switch cap {
    case .butt: .butt
    case .round: .round
    case .square: .square
    }
  }

  private static func cgLineJoin(_ join: VectorLineJoin) -> CGLineJoin {
    switch join {
    case .miter: .miter
    case .round: .round
    case .bevel: .bevel
    }
  }
}

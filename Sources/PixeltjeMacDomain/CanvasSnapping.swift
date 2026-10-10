import Foundation

/// One line a drag can snap to, in canvas pixels.
public struct CanvasSnapLine: Equatable, Sendable {
  public var axis: GuideAxis
  public var position: Double
  public var kind: CanvasSnapTargetKind

  public init(axis: GuideAxis, position: Double, kind: CanvasSnapTargetKind) {
    self.axis = axis
    self.position = position
    self.kind = kind
  }

  public var label: String {
    switch kind {
    case .guides: "Guide"
    case .grid: "Grid"
    case .canvasEdges: "Edge"
    case .canvasCenter: "Center"
    }
  }
}

/// What a snap did: how far it moved the drag, and the lines it landed on.
public struct CanvasSnapResult: Equatable, Sendable {
  public var offset: CanvasOffset
  /// The line the x axis landed on, when it snapped at all.
  public var verticalLine: CanvasSnapLine?
  /// The line the y axis landed on, when it snapped at all.
  public var horizontalLine: CanvasSnapLine?

  public init(
    offset: CanvasOffset = .zero,
    verticalLine: CanvasSnapLine? = nil,
    horizontalLine: CanvasSnapLine? = nil
  ) {
    self.offset = offset
    self.verticalLine = verticalLine
    self.horizontalLine = horizontalLine
  }

  public var isEmpty: Bool { verticalLine == nil && horizontalLine == nil }
}

/// Snapping for the canvas: pure math over canvas pixels, with no view, no
/// zoom, and no gesture state.
///
/// The caller converts its screen-space threshold into canvas pixels before
/// asking, which is the only place zoom enters. That keeps the rule "the pull
/// feels the same at every zoom" in the view, and the geometry here testable.
public enum CanvasSnapping {
  /// Every line of one axis a drag could land on.
  ///
  /// Grid lines are unbounded rather than clipped to the canvas: content can be
  /// dragged past the edge, and the grid it aligns to should not stop there.
  /// They are generated around `near` for that reason.
  public static func lines(
    axis: GuideAxis,
    near: Double,
    canvas: CanvasRecipe,
    settings: CanvasSettingsRecipe,
    includesGrid: Bool
  ) -> [CanvasSnapLine] {
    var result: [CanvasSnapLine] = []
    let extent = axis == .vertical ? Double(canvas.width) : Double(canvas.height)

    if canvas.isResolved, settings.snapping.contains(.canvasEdges) {
      result.append(CanvasSnapLine(axis: axis, position: 0, kind: .canvasEdges))
      result.append(CanvasSnapLine(axis: axis, position: extent, kind: .canvasEdges))
    }
    if canvas.isResolved, settings.snapping.contains(.canvasCenter) {
      result.append(CanvasSnapLine(axis: axis, position: extent / 2, kind: .canvasCenter))
    }
    if settings.snapping.contains(.guides) {
      result.append(
        contentsOf: settings.guides(on: axis).map {
          CanvasSnapLine(axis: axis, position: $0.position, kind: .guides)
        })
    }
    if includesGrid, settings.snapping.contains(.grid) {
      let step = settings.grid.subdivisionSpacing
      if step > 0 {
        // The two grid lines around the point are enough: anything further away
        // is further than the nearest one, so it can never win.
        let lower = (near / step).rounded(.down) * step
        result.append(CanvasSnapLine(axis: axis, position: lower, kind: .grid))
        result.append(CanvasSnapLine(axis: axis, position: lower + step, kind: .grid))
      }
    }
    return result
  }

  /// Snaps one coordinate, which is what dragging a guide needs.
  ///
  /// Returns the line it landed on, or `nil` when nothing was close enough.
  public static func snap(
    position: Double,
    axis: GuideAxis,
    canvas: CanvasRecipe,
    settings: CanvasSettingsRecipe,
    excludingGuide excluded: UUID? = nil,
    thresholdInCanvasPixels threshold: Double,
    includesGrid: Bool = true
  ) -> CanvasSnapLine? {
    guard threshold > 0 else { return nil }
    var settings = settings
    if let excluded {
      // A guide never snaps to itself, and dragging it should not be held in
      // place by the line it is leaving.
      settings = settings.removing(excluded)
    }
    let candidates = lines(
      axis: axis,
      near: position,
      canvas: canvas,
      settings: settings,
      includesGrid: includesGrid
    )
    return closest(to: position, among: candidates, within: threshold)
  }

  /// Snaps a moving rectangle, which is what the Move tool needs.
  ///
  /// Each axis considers the rectangle's leading edge, center, and trailing
  /// edge, and takes whichever of the three comes closest to a line. Both axes
  /// are decided independently, so a drag can snap horizontally without being
  /// pulled vertically.
  public static func snapOffset(
    for frame: LayerFrame,
    canvas: CanvasRecipe,
    settings: CanvasSettingsRecipe,
    thresholdInCanvasPixels threshold: Double
  ) -> CanvasSnapResult {
    guard threshold > 0, !frame.isEmpty else { return CanvasSnapResult() }

    let horizontal = bestSnap(
      edges: [frame.x, frame.x + frame.width / 2, frame.x + frame.width],
      axis: .vertical,
      canvas: canvas,
      settings: settings,
      threshold: threshold
    )
    let vertical = bestSnap(
      edges: [frame.y, frame.y + frame.height / 2, frame.y + frame.height],
      axis: .horizontal,
      canvas: canvas,
      settings: settings,
      threshold: threshold
    )
    return CanvasSnapResult(
      offset: CanvasOffset(x: horizontal?.delta ?? 0, y: vertical?.delta ?? 0),
      verticalLine: horizontal?.line,
      horizontalLine: vertical?.line
    )
  }

  private static func bestSnap(
    edges: [Double],
    axis: GuideAxis,
    canvas: CanvasRecipe,
    settings: CanvasSettingsRecipe,
    threshold: Double
  ) -> (delta: Double, line: CanvasSnapLine)? {
    var best: (delta: Double, line: CanvasSnapLine)?
    for edge in edges {
      let candidates = lines(
        axis: axis,
        near: edge,
        canvas: canvas,
        settings: settings,
        includesGrid: true
      )
      guard let line = closest(to: edge, among: candidates, within: threshold) else { continue }
      let delta = line.position - edge
      if best == nil || abs(delta) < abs(best!.delta) {
        best = (delta, line)
      }
    }
    return best
  }

  private static func closest(
    to position: Double,
    among candidates: [CanvasSnapLine],
    within threshold: Double
  ) -> CanvasSnapLine? {
    var best: CanvasSnapLine?
    var bestDistance = threshold
    for candidate in candidates {
      let distance = abs(candidate.position - position)
      // Strictly closer keeps the order of `lines` as the tie-breaker, so an
      // edge or a guide wins over a grid line that happens to coincide.
      guard distance <= bestDistance else { continue }
      if best != nil && distance == bestDistance { continue }
      best = candidate
      bestDistance = distance
    }
    return best
  }
}

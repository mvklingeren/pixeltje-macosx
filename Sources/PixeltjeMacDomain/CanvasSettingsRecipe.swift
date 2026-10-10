import Foundation

/// Which way a guide runs across the canvas.
///
/// A guide is one line, so it needs one number. `vertical` names a line of
/// constant x, `horizontal` a line of constant y, both measured in canvas
/// pixels from the canvas's bottom-left origin.
public enum GuideAxis: String, Codable, CaseIterable, Sendable {
  case vertical
  case horizontal

  public var label: String {
    switch self {
    case .vertical: "Vertical"
    case .horizontal: "Horizontal"
    }
  }
}

/// A ruler guide, stored with the project.
///
/// Guides are document state rather than view state: they belong to the
/// composition the way the canvas extent does, so they travel with the project
/// and every change to them is an undoable step.
public struct CanvasGuide: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var axis: GuideAxis
  /// x for a vertical guide, y for a horizontal one, in canvas pixels.
  public var position: Double

  public init(id: UUID = UUID(), axis: GuideAxis, position: Double) {
    self.id = id
    self.axis = axis
    self.position = position
  }
}

/// The grid drawn over the canvas.
///
/// Spacing is the distance between the heavy lines; subdivisions cut each of
/// those cells into that many lighter ones, so 100 px with 4 subdivisions draws
/// a fine 25 px grid under a heavy 100 px one.
public struct CanvasGridRecipe: Codable, Equatable, Sendable {
  public var spacing: Double
  public var subdivisions: Int

  public init(spacing: Double = 100, subdivisions: Int = 4) {
    self.spacing = max(spacing, 1)
    self.subdivisions = max(subdivisions, 1)
  }

  /// The distance between the finest lines the grid draws, in canvas pixels.
  public var subdivisionSpacing: Double {
    spacing / Double(max(subdivisions, 1))
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      spacing: try container.decodeIfPresent(Double.self, forKey: .spacing) ?? 100,
      subdivisions: try container.decodeIfPresent(Int.self, forKey: .subdivisions) ?? 4
    )
  }

  private enum CodingKeys: String, CodingKey {
    case spacing
    case subdivisions
  }
}

/// What a drag can snap to.
///
/// Which of these are live is a project setting, edited in the right panel's
/// Canvas section. Whether snapping happens at all is a view toggle in the View
/// menu, because that is a working preference rather than part of the document.
public enum CanvasSnapTargetKind: String, Codable, CaseIterable, Sendable {
  case guides
  case grid
  case canvasEdges
  case canvasCenter

  public var label: String {
    switch self {
    case .guides: "Guides"
    case .grid: "Grid"
    case .canvasEdges: "Canvas Edges"
    case .canvasCenter: "Canvas Center"
    }
  }
}

public struct CanvasSnapRecipe: Codable, Equatable, Sendable {
  public var targets: Set<CanvasSnapTargetKind>
  /// How close a drag has to come before it snaps, measured on screen so the
  /// pull feels the same at every zoom level.
  public var thresholdInScreenPoints: Double

  public init(
    targets: Set<CanvasSnapTargetKind> = [.guides, .canvasEdges, .canvasCenter],
    thresholdInScreenPoints: Double = 8
  ) {
    self.targets = targets
    self.thresholdInScreenPoints = max(thresholdInScreenPoints, 0)
  }

  public func contains(_ kind: CanvasSnapTargetKind) -> Bool {
    targets.contains(kind)
  }

  public func setting(_ kind: CanvasSnapTargetKind, enabled: Bool) -> CanvasSnapRecipe {
    var copy = self
    if enabled {
      copy.targets.insert(kind)
    } else {
      copy.targets.remove(kind)
    }
    return copy
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      targets: try container.decodeIfPresent(Set<CanvasSnapTargetKind>.self, forKey: .targets)
        ?? [.guides, .canvasEdges, .canvasCenter],
      thresholdInScreenPoints: try container.decodeIfPresent(
        Double.self, forKey: .thresholdInScreenPoints) ?? 8
    )
  }

  private enum CodingKeys: String, CodingKey {
    case targets
    case thresholdInScreenPoints
  }
}

/// The canvas settings a project carries: its guides, its grid, and what a drag
/// snaps to.
///
/// The canvas extent lives on the canvas layer, because a layer stack is what a
/// document renders. Everything here is about working on that extent rather
/// than about its pixels, so it sits beside the stack instead of inside it.
public struct CanvasSettingsRecipe: Codable, Equatable, Sendable {
  public var guides: [CanvasGuide]
  public var grid: CanvasGridRecipe
  public var snapping: CanvasSnapRecipe

  public init(
    guides: [CanvasGuide] = [],
    grid: CanvasGridRecipe = CanvasGridRecipe(),
    snapping: CanvasSnapRecipe = CanvasSnapRecipe()
  ) {
    self.guides = guides
    self.grid = grid
    self.snapping = snapping
  }

  public func guides(on axis: GuideAxis) -> [CanvasGuide] {
    guides.filter { $0.axis == axis }
  }

  public func adding(_ guide: CanvasGuide) -> CanvasSettingsRecipe {
    guard !guides.contains(where: { $0.id == guide.id }) else { return self }
    var copy = self
    copy.guides.append(guide)
    return copy
  }

  public func moving(_ id: UUID, to position: Double) -> CanvasSettingsRecipe {
    guard let index = guides.firstIndex(where: { $0.id == id }) else { return self }
    var copy = self
    copy.guides[index].position = position
    return copy
  }

  public func removing(_ id: UUID) -> CanvasSettingsRecipe {
    guard guides.contains(where: { $0.id == id }) else { return self }
    var copy = self
    copy.guides.removeAll { $0.id == id }
    return copy
  }

  public func removingAllGuides() -> CanvasSettingsRecipe {
    guard !guides.isEmpty else { return self }
    var copy = self
    copy.guides = []
    return copy
  }

  /// The settings on a canvas of a new size, with guides placed by `anchor`.
  ///
  /// A guide marks a place on the composition, so it moves with the content the
  /// resize moves rather than staying at its old number. Guides pushed off the
  /// new extent are kept: undoing the resize has to bring them back where they
  /// were, and clamping would quietly collapse them onto an edge.
  public func resizingCanvas(
    from old: CanvasRecipe,
    to new: CanvasRecipe,
    anchor: CanvasAnchor
  ) -> CanvasSettingsRecipe {
    guard old.isResolved, new.isResolved, old != new else { return self }
    let offset = anchor.contentOffset(from: old, to: new)
    return resizingCanvas(from: old, to: new, offset: offset)
  }

  /// Repositions guides by an explicit content translation, used by an
  /// arbitrary crop rectangle rather than the resize panel's nine anchors.
  public func resizingCanvas(
    from old: CanvasRecipe,
    to new: CanvasRecipe,
    offset: CanvasOffset
  ) -> CanvasSettingsRecipe {
    guard old.isResolved, new.isResolved, old != new else { return self }
    var copy = self
    for index in copy.guides.indices {
      switch copy.guides[index].axis {
      case .vertical: copy.guides[index].position += offset.x
      case .horizontal: copy.guides[index].position += offset.y
      }
    }
    return copy
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      guides: try container.decodeIfPresent([CanvasGuide].self, forKey: .guides) ?? [],
      grid: try container.decodeIfPresent(CanvasGridRecipe.self, forKey: .grid)
        ?? CanvasGridRecipe(),
      snapping: try container.decodeIfPresent(CanvasSnapRecipe.self, forKey: .snapping)
        ?? CanvasSnapRecipe()
    )
  }

  private enum CodingKeys: String, CodingKey {
    case guides
    case grid
    case snapping
  }
}

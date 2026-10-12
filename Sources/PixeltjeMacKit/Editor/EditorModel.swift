import Combine
import CoreGraphics
import Foundation
import PixeltjeMacDomain

/// Prefer the generated suggestion when the two sources name
/// the same subject. Tokenizing also matches Vision's underscored identifiers
/// with ordinary phrases, independent of case, punctuation, and articles.
private func mergedImageContentTags(
  generated: [ImageContentTag], vision: [ImageContentTag]
) -> [ImageContentTag] {
  var seen = Set<String>()
  return (generated + vision).filter { tag in
    var words = tag.label
      .folding(options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX"))
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    if let first = words.first, ["a", "an", "the"].contains(first) {
      words.removeFirst()
    }
    let key = words.joined(separator: " ")
    return !key.isEmpty && seen.insert(key).inserted
  }
}

public enum RenderStatus: Equatable, Sendable {
  case idle
  case preparing(String)
  case ready(String)
  case exporting(String)
  case failed(String)

  public var message: String {
    switch self {
    case .idle: "Open a RAW file to begin."
    case .preparing(let message): message
    case .ready(let message): message
    case .exporting(let message): message
    case .failed(let message): message
    }
  }

  public var isBusy: Bool {
    switch self {
    case .preparing, .exporting: true
    default: false
    }
  }
}

public enum EditorTool: String, CaseIterable, Equatable, Sendable {
  case generate
  case navigate
  case move
  case transform
  case marquee
  case lasso
  case magnetSelection
  case selectionBrush
  case crop
  case brush
  case eraser
  case heal
  case pen
  case shape
  case gradient
  case fill
  case text
  case masks

  public var label: String {
    switch self {
    case .navigate: "Navigate"
    case .move: "Select/Move"
    case .transform: "Free Transform"
    case .marquee: "Marquee"
    case .lasso: "Lasso"
    case .magnetSelection: "Magnet Selection"
    case .selectionBrush: "Selection Brush"
    case .crop: "Crop"
    case .brush: "Brush"
    case .eraser: "Eraser"
    case .heal: "Healing Brush"
    case .pen: "Pen"
    case .shape: "Shape"
    case .gradient: "Gradient"
    case .fill: "Fill"
    case .text: "Text"
    case .masks: "Masks"
    case .generate: "Generate"
    }
  }

  public var symbolName: String {
    switch self {
    case .navigate: "hand.draw"
    case .move: "arrow.up.left.square"
    case .transform: "arrow.up.left.and.arrow.down.right"
    case .marquee: "rectangle.dashed"
    case .lasso: "lasso"
    case .magnetSelection: "wand.and.stars"
    case .selectionBrush: "paintbrush.pointed.fill"
    case .crop: "crop"
    case .brush: "paintbrush.pointed"
    case .eraser: "eraser"
    case .heal: "bandage.fill"
    case .pen: "pencil.tip"
    case .shape: "square.on.circle"
    // A split light/dark swatch reads as a gradient, unlike the previous
    // overlapping-squares symbol, which looked like Duplicate or Copy.
    case .gradient: "square.righthalf.filled"
    // AppKit does not vend a `paintbucket` system image on macOS 27. A filled
    // drop keeps the tool recognizable without leaving an empty toolbar slot.
    case .fill: "drop.fill"
    case .text: "character.cursor.ibeam"
    case .masks: "circle.dashed.inset.filled"
    case .generate: "sparkles"
    }
  }

  /// Whether this tool captures its gesture through the shared brush input
  /// path: coalescing disabled, tablet pressure, tilt and rotation recorded,
  /// and a provisional stroke surface presented while the pointer is down.
  ///
  /// What the captured stroke becomes differs — paint, erased coverage, or the
  /// coverage of a healed patch — but none of that changes how it is captured.
  public var usesBrushStrokeCapture: Bool {
    self == .brush || self == .eraser || self == .heal || self == .selectionBrush
  }

  /// Whether this tool creates or changes the document's pixel selection.
  public var isSelectionTool: Bool {
    self == .marquee || self == .lasso || self == .magnetSelection || self == .selectionBrush
  }

  /// Whether this selection tool describes geometry with a pointer drag. The
  /// Magnet Selection analyses pixels from a click instead.
  public var drawsSelectionGeometry: Bool { self == .marquee || self == .lasso }

  /// Whether this tool has settings for the left panel.
  public var hasToolSettings: Bool {
    switch self {
    case .crop, .transform, .marquee, .lasso, .magnetSelection, .selectionBrush,
      .brush, .eraser, .heal,
      .pen, .shape,
      .gradient, .fill, .text, .masks: true
    case .navigate, .move, .generate: false
    }
  }

  /// The unmodified key that activates the tool while the canvas has focus.
  ///
  /// Modified command shortcuts such as Transform's Command-T and Fill's
  /// Shift-G are described separately by their menu item and `toolTip`.
  public var activationKey: String? {
    switch self {
    case .navigate: nil
    case .move: "v"
    case .transform: nil
    case .marquee: "m"
    case .lasso: "l"
    case .magnetSelection: nil
    case .selectionBrush: nil
    case .crop: "c"
    case .brush: "b"
    case .eraser: "e"
    // J is where every other editor puts the healing brush.
    case .heal: "j"
    case .pen: "p"
    case .shape: "u"
    case .gradient: "g"
    // Fill shares the conventional G tool family with Gradient. It uses
    // Shift-G so bare F remains available for Fullscreen Preview.
    case .fill: nil
    case .text: "t"
    // M and L belong to the marquee and the lasso, as they do in every other
    // image editor. Masks took M before those tools existed and moved here.
    case .masks: "k"
    case .generate: nil
    }
  }

  public var toolTip: String {
    let shortcut = switch self {
    // Free Transform is a command rather than a bare tool key because T is
    // already the Text tool. Edit > Free Transform owns the Command-T item.
    case .transform: "⌘T"
    case .fill: "⇧G"
    case .magnetSelection: "⇧M"
    default: activationKey?.uppercased()
    }
    guard let shortcut else { return "\(label) Tool" }
    return "\(label) Tool (\(shortcut))"
  }

  /// The tool a letter key press asks for, or `nil` when it is not a shortcut.
  /// Shift-G selects Fill and Shift-M selects Magnet Selection; other shifted
  /// letters retain their bare-key tool.
  public static func activated(by characters: String?, shifted: Bool = false) -> EditorTool? {
    guard let characters = characters?.lowercased() else { return nil }
    if shifted {
      if characters == "g" { return .fill }
      if characters == "m" { return .magnetSelection }
    }
    return allCases.first { $0.activationKey == characters }
  }
}

struct GradientToolState: Equatable, Sendable {
  var kind: PaintGradientKind = .linear
  var startColor: LinearRGBAColor = .black
  var endColor: LinearRGBAColor = .white
}

struct FillToolState: Equatable, Sendable {
  var mode: FillRegionMode = .contiguous
  var color: LinearRGBAColor = .black
  var tolerance = 0.1
  var sampleSource: FillSampleSource = .composite
}

/// What the Healing Brush will do next.
///
/// The stroke settings are its own rather than the Brush's: a heal tip needs
/// size, hardness, spacing and pressure, and nothing the brush library offers
/// beyond that — a tip shape or a grain would change the coverage of a patch
/// without changing the patch, which is not a control anybody wants.
struct HealToolState: Equatable, Sendable {
  var mode: HealSourceMode = .spot
  var sampleSource: HealSampleSource = .composite
  var blend: HealBlendMethod = .seamless
  /// Softer and more closely spaced than the default brush: a heal's coverage
  /// is a region to replace, and a hard edge on it shows as a seam.
  var settings = BrushSettings(
    size: 60, hardness: 0.7, opacity: 1, flow: 1, spacing: 0.05, pressureResponse: 0.35)
  var solverIterations = HealLimits.defaultSolverIterations
  /// The anchor an Option-click set, normalized to the canvas with the origin
  /// at the bottom left, or `nil` when no source has been chosen.
  ///
  /// Normalized because that is what the canvas reports for a click and what
  /// the overlay converts back; the offset in canvas pixels is derived once,
  /// when a stroke begins and the canvas size is known.
  var sourceAnchor: VectorPoint?

  /// Whether a stroke can be solved right now. Source-point mode without an
  /// anchor has nothing to copy from, and says so before the drag rather than
  /// after it.
  var isReadyToPaint: Bool {
    mode == .spot || sourceAnchor != nil
  }
}

/// What the Shape tool will draw next.
///
/// A shape stays parametric once drawn, so these are the parameters the new
/// object carries rather than a recipe for one-off anchors.
struct ShapeToolState: Equatable, Sendable {
  enum Kind: String, CaseIterable, Equatable, Sendable {
    case rectangle
    case ellipse
    case line
    case polygon
    case star

    var label: String {
      switch self {
      case .rectangle: "Rectangle"
      case .ellipse: "Ellipse"
      case .line: "Line"
      case .polygon: "Polygon"
      case .star: "Star"
      }
    }
  }

  var kind: Kind = .rectangle
  /// Corner radius as a fraction of the shape's shorter side, matching
  /// `VectorCornerRadii`.
  var cornerRadius = 0.0
  var polygonSides = 5
  var starPoints = 5
  var starInnerRatio = 0.5
  var rotationDegrees = 0.0
  /// Whether a drag grows the shape from its center rather than from the
  /// corner the press landed on. Option inverts it for one gesture.
  var drawsFromCenter = false

  var vectorKind: VectorShapeKind {
    switch kind {
    case .rectangle: .rectangle(corners: VectorCornerRadii(uniform: cornerRadius))
    case .ellipse: .ellipse
    case .line: .line
    case .polygon: .polygon(sides: polygonSides)
    case .star: .star(points: starPoints, innerRatio: starInnerRatio)
    }
  }

  /// The shape a drag from `start` to `end` describes.
  ///
  /// The canvas preview and the committed object are built here, so what the
  /// user sees while dragging is exactly what lands in the recipe.
  func makeShape(
    from start: VectorPoint,
    to end: VectorPoint,
    fromCenter: Bool,
    constrained: Bool,
    aspect: Double,
    stroke: VectorStrokeStyle?,
    fill: VectorFillStyle?
  ) -> VectorShape {
    var corner = end
    if constrained {
      // Equal extents on screen, so a square is square rather than as wide as
      // the image is tall.
      let extentX = abs(corner.x - start.x) * aspect
      let extentY = abs(corner.y - start.y)
      let extent = min(extentX, extentY)
      corner.x = start.x + (corner.x < start.x ? -1 : 1) * extent / max(aspect, 0.000_1)
      corner.y = start.y + (corner.y < start.y ? -1 : 1) * extent
    }

    let frame: VectorBounds
    if fromCenter {
      let dx = abs(corner.x - start.x)
      let dy = abs(corner.y - start.y)
      frame = VectorBounds(
        minX: start.x - dx, minY: start.y - dy, maxX: start.x + dx, maxY: start.y + dy)
    } else {
      frame = VectorBounds(
        minX: start.x, minY: start.y, maxX: corner.x, maxY: corner.y)
    }

    let resolved = vectorKind
    return VectorShape(
      kind: resolved,
      frame: frame,
      rotationDegrees: rotationDegrees,
      stroke: stroke,
      fill: resolved.isClosed ? fill : nil
    )
  }
}

/// Uncommitted Free Transform state. It is deliberately outside the recipe so
/// autosave, snapshots and history only ever contain an applied transform.
public struct TransformDraft: Equatable, Sendable {
  public var targetID: ProjectLayerID
  public var transform: LayerTransform
  /// When non-empty, the transform reshapes these vector objects rather than
  /// the layer as a whole.
  ///
  /// Free Transform is reused for objects instead of adding a second transform
  /// tool. An object transform is baked into the geometry on commit, so the
  /// result stays exact vector artwork rather than a transform stacked beside
  /// it.
  public var objectIDs: Set<UUID>

  public init(
    targetID: ProjectLayerID, transform: LayerTransform, objectIDs: Set<UUID> = []
  ) {
    self.targetID = targetID
    self.transform = transform
    self.objectIDs = objectIDs
  }
}

/// How a pointer press is read while a vector layer is being edited.
///
/// The Pen draws paths or edits their anchors. Whole-object selection belongs
/// to the primary Select/Move tool, shared by paths and parametric shapes.
public enum VectorEditMode: String, CaseIterable, Equatable, Sendable {
  case draw
  case direct

  public var label: String {
    switch self {
    case .draw: "Draw"
    case .direct: "Direct"
    }
  }

  public var symbolName: String {
    switch self {
    case .draw: "pencil.tip"
    case .direct: "arrow.up.left.and.arrow.down.right.square"
    }
  }

  public var help: String {
    switch self {
    case .draw: "Place anchors to draw a new path."
    case .direct: "Click an anchor or handle to reshape a path."
    }
  }
}

/// The complete appearance every vector-creation tool gives its next object.
///
/// This is tool state rather than document state: the colors enter the recipe
/// when a path or shape is created, and the resulting vector styles are then
/// saved and restored with that object.
///
/// Whether the next object is stroked or filled lives in `hasStroke` and
/// `fillMode`, never in an alpha of zero. `strokeColor` and `fillColor` are the
/// window's shared foreground and background, so a transparent color standing
/// for "off" would have turned the brush and the text tool invisible the moment
/// someone switched a vector stroke off.
struct VectorToolStyle: Equatable, Sendable {
  /// What the next object's fill is made of. The solid color and the gradient
  /// both survive while the other one is showing, so switching the fill type
  /// back and forth restores what the user last chose.
  enum FillMode: Equatable, Sendable {
    case none
    case solid
    case gradient
  }

  /// Whether the next object gets an outline at all.
  var hasStroke = true
  var strokeColor = VectorColor.white
  var fillMode = FillMode.none
  var fillColor = VectorColor(red: 0, green: 0, blue: 0, alpha: 0)
  /// The gradient used while `fillMode` is `.gradient`, and remembered while it
  /// is not, so choosing a background color cannot destroy it.
  var fillGradient: VectorGradient?
  /// Fill opacity for the next object, separate from object and layer opacity.
  var fillOpacity = 1.0
  /// Outline width in canonical image pixels, matching `VectorStrokeStyle`.
  var strokeWidth = 8.0

  /// The rest of the stroke model, kept so a cap, dash, or arrowhead the user
  /// chose describes the next object too.
  var strokeDetails = VectorStrokeStyle()

  var stroke: VectorStrokeStyle {
    var result = strokeDetails
    result.color = strokeColor
    result.width = strokeWidth
    return result
  }

  /// The stroke as the editor shows it, or nil when the next object gets none.
  var fullStroke: VectorStrokeStyle? {
    hasStroke && strokeWidth > 0 ? stroke : nil
  }

  /// Rewrites the default from a complete stroke, which is what the stroke
  /// editor produces whether or not anything is selected. Turning the stroke
  /// off keeps its color: that color is the shared foreground, and the brush
  /// and the text tool are still using it.
  mutating func setStroke(_ stroke: VectorStrokeStyle?) {
    guard let stroke else {
      hasStroke = false
      return
    }
    hasStroke = true
    strokeDetails = stroke
    strokeColor = stroke.color
    strokeWidth = stroke.width
  }

  var fill: VectorFillStyle? {
    switch fillMode {
    case .none:
      return nil
    case .solid:
      return VectorFillStyle(color: fillColor, opacity: fillOpacity)
    case .gradient:
      guard let fillGradient else { return nil }
      var resolved = fillGradient
      resolved.opacity = fillOpacity
      return VectorFillStyle(gradient: resolved)
    }
  }

  /// Rewrites the default from a complete fill, which is what the fill editor
  /// produces whether or not anything is selected. As with the stroke, turning
  /// the fill off keeps the shared background color it was using.
  mutating func setFill(_ fill: VectorFillStyle?) {
    guard let fill else {
      fillMode = .none
      return
    }
    fillOpacity = fill.opacity
    switch fill.content {
    case .solid(let color):
      fillMode = .solid
      fillColor = color
    case .gradient(let gradient):
      fillMode = .gradient
      fillGradient = gradient
    }
  }
}

/// The type the Text tool gives a newly placed text layer.
///
/// Tool state on the same terms as `VectorToolStyle`: it says how the next click
/// on the canvas will set its text, and becomes document state once that layer
/// exists. A nil `fontSize` means the canvas-derived size `TextLayer.placing`
/// computes, so type stays proportional to the canvas until someone asks for a
/// specific size.
struct TextToolStyle: Equatable, Sendable {
  var fontName = TextLayer.defaultFontName
  var color = VectorColor.white
  var alignment = TextLayerAlignment.center
  var fontSize: Double?

  /// The size a layer placed right now would use, given the canvas.
  func resolvedFontSize(in canvas: CanvasRecipe) -> Double {
    fontSize ?? TextLayer.placing("", in: canvas).fontSize
  }

  /// Stamps this style onto a freshly placed layer, keeping the frame that
  /// `TextLayer.placing` sized and centered.
  func applied(to layer: TextLayer) -> TextLayer {
    var styled = layer
    styled.fontName = fontName
    styled.color = color
    styled.alignment = alignment
    if let fontSize { styled.fontSize = fontSize }
    return styled
  }
}

/// What the masks tool is set to, and which mask it is working on.
///
/// This is tool state, not document state: it says what the next canvas gesture
/// will make, not what the project contains. It is therefore not part of the
/// recipe and not undoable, exactly like the active tool itself. The brush,
/// selection and generate tools will read `activeMask` to know which mask their
/// gesture should paint into.
public struct MaskToolState: Equatable, Sendable {
  /// The generator the next placement produces.
  public var generatorKind: MaskGeneratorKind
  /// How that generator joins the components already in the mask.
  public var combine: MaskCombineOperation
  /// Edge softening, in canvas pixels, given to the component it creates.
  public var feather: Double
  /// The layer whose mask is being edited, and the mask itself.
  public var activeLayerID: ProjectLayerID?
  public var activeMaskID: MaskID?

  public init(
    generatorKind: MaskGeneratorKind = .linearGradient,
    combine: MaskCombineOperation = .add,
    feather: Double = 0,
    activeLayerID: ProjectLayerID? = nil,
    activeMaskID: MaskID? = nil
  ) {
    self.generatorKind = generatorKind
    self.combine = combine
    self.feather = max(feather, 0)
    self.activeLayerID = activeLayerID
    self.activeMaskID = activeMaskID
  }

  /// The mask this state points at, if it still exists in the stack.
  public func activeMask(in layerStack: LayerStackRecipe) -> MaskRecipe? {
    guard let activeLayerID, let activeMaskID else { return nil }
    return layerStack.mask(activeMaskID, on: activeLayerID)
  }
}

/// Which document mask Prompt Box inpainting should use.
///
/// This is editor-session state rather than part of `InpaintingToolState`:
/// concrete layer and mask identifiers belong to one open project and must
/// never leak into global ComfyUI history or preferences.
public enum GenerationMaskSourceChoice: Hashable, Sendable {
  /// Prefer the document selection, then the active layer's singular layer
  /// mask, and finally transparent pixels in the composite.
  case automatic
  case documentSelection
  case layerMask(ProjectLayerID, MaskID)
  /// A named per-layer mask from `ProjectLayer.masks`. These masks normally
  /// carry local adjustments, but their coverage can also be chosen
  /// explicitly for generation.
  case localMask(ProjectLayerID, MaskID)
  /// Derive editable coverage from one minus the frozen composite alpha.
  case transparentPixels
  case entireOutput
  /// Compatibility behavior for restored jobs created before mask-source
  /// selection existed: use a document selection when present, otherwise the
  /// complete output. This value is not offered by the picker.
  case legacySelectionOrEntireOutput
}

public struct GenerationMaskSourceOption: Identifiable, Equatable, Sendable {
  public var source: GenerationMaskSourceChoice
  public var label: String
  public var isAvailable: Bool
  public var unavailableReason: String?

  public var id: GenerationMaskSourceChoice { source }
}

public struct GenerationMaskSourcePresentation: Equatable, Sendable {
  public var requested: GenerationMaskSourceChoice
  public var requestedLabel: String
  public var resolved: GenerationMaskSourceChoice?
  public var resolvedLabel: String?
  public var unavailableReason: String?

  public var compactLabel: String {
    if requested == .automatic, let resolvedLabel {
      return "Automatic → \(resolvedLabel)"
    }
    return requestedLabel
  }

  public var help: String {
    if let unavailableReason { return unavailableReason }
    if requested == .automatic, let resolvedLabel {
      return "Automatic will use \(resolvedLabel) for this inpaint."
    }
    return "This inpaint will use \(resolvedLabel ?? requestedLabel)."
  }
}

/// What Brush/Eraser will change. It is window-local targeting state: the
/// recipe owns both destinations, while selecting a thumbnail merely chooses
/// which one receives the next stroke.
public enum PaintTarget: Equatable, Sendable {
  case layerPixels(ProjectLayerID)
  case layerMask(ProjectLayerID, MaskID)

  public var layerID: ProjectLayerID {
    switch self {
    case .layerPixels(let id), .layerMask(let id, _): id
    }
  }
}

/// What the selection tools are set to.
///
/// Tool state, not document state: it says what the next canvas gesture will
/// make, not what the document contains, so it is neither undoable nor saved —
/// exactly like `MaskToolState` and the active tool itself.
public struct SelectionToolState: Equatable, Sendable {
  /// Which shape the marquee draws. The lasso ignores this and always produces
  /// a polygon, so the two tools can share one settings panel.
  public enum Shape: String, CaseIterable, Equatable, Sendable {
    case rectangle
    case ellipse

    public var label: String {
      switch self {
      case .rectangle: "Rectangle"
      case .ellipse: "Ellipse"
      }
    }

    public var symbolName: String {
      switch self {
      case .rectangle: "rectangle.dashed"
      case .ellipse: "circle.dashed"
      }
    }

    public var generatorKind: MaskGeneratorKind {
      switch self {
      case .rectangle: .rectangle
      case .ellipse: .ellipse
      }
    }
  }

  /// The picker tag standing in for "New", which is the absence of a combine
  /// operation rather than one of its cases.
  public static let newSelectionTag = "new"

  /// How the next gesture joins what is already selected. `nil` is "New": the
  /// gesture replaces the selection rather than combining with it.
  public var combine: MaskCombineOperation?
  public var shape: Shape
  /// Edge softening in canvas pixels, given to the component the gesture makes.
  public var feather: Double
  /// How far the corners of a rectangular marquee are rounded, in canvas
  /// pixels. Pixels are what the panel shows and what the user thinks in; the
  /// gesture normalizes it against the canvas before it reaches the recipe.
  /// The ellipse and the lasso have no corners and ignore it.
  public var cornerRadius: Double

  public init(
    combine: MaskCombineOperation? = nil,
    shape: Shape = .rectangle,
    feather: Double = 0,
    cornerRadius: Double = 0
  ) {
    self.combine = combine
    self.shape = shape
    self.feather = Self.clamped(feather, upTo: 250)
    self.cornerRadius = Self.clamped(cornerRadius, upTo: 2_048)
  }

  static func clamped(_ value: Double, upTo limit: Double) -> Double {
    value.isFinite ? min(max(value, 0), limit) : 0
  }

  /// The generator kind the named tool produces under these settings.
  public func generatorKind(for tool: EditorTool) -> MaskGeneratorKind {
    tool == .lasso ? .polygon : shape.generatorKind
  }
}

/// The two color-driven ways Magnet Selection can turn one click into the
/// document's active selection.
public enum MagnetSelectionMode: String, CaseIterable, Equatable, Sendable {
  case contiguous
  case colorRange

  public var label: String {
    switch self {
    case .contiguous: "Contiguous"
    case .colorRange: "Color Range"
    }
  }
}

/// Session state for the Magnet Selection tool. The resulting pixels are
/// captured into the document selection; these controls only describe the next
/// click and therefore remain window-local and non-undoable.
public struct MagnetSelectionToolState: Equatable, Sendable {
  public static let newSelectionTag = "new"

  public var mode: MagnetSelectionMode
  public var combine: MaskCombineOperation?
  public var tolerance: Double
  public var smoothness: Double
  public var sampleSource: FillSampleSource
  public var feather: Double

  public init(
    mode: MagnetSelectionMode = .contiguous,
    combine: MaskCombineOperation? = nil,
    tolerance: Double = 0.1,
    smoothness: Double = 0.5,
    sampleSource: FillSampleSource = .composite,
    feather: Double = 0
  ) {
    self.mode = mode
    self.combine = combine
    self.tolerance = Self.unit(tolerance, fallback: 0.1)
    self.smoothness = Self.unit(smoothness, fallback: 0.5)
    self.sampleSource = sampleSource
    self.feather = SelectionToolState.clamped(feather, upTo: 250)
  }

  static func unit(_ value: Double, fallback: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : fallback
  }
}

/// Whether the Selection Brush paints coverage literally or uses the stroke as
/// a set of foreground hints for edge-aware expansion.
public enum SelectionBrushMode: String, CaseIterable, Equatable, Sendable {
  case paint
  case quickSelect

  public var label: String {
    switch self {
    case .paint: "Paint"
    case .quickSelect: "Quick Select"
    }
  }
}

/// Window-local controls for the Selection Brush.
///
/// The size is shared by both modes so switching between literal painting and
/// Quick Select does not make the cursor jump. Paint uses the remaining brush
/// settings; Quick Select treats its stroke as an opaque hint and uses the
/// analysis controls instead.
public struct SelectionBrushToolState: Equatable, Sendable {
  public static let newSelectionTag = "new"

  public var mode: SelectionBrushMode
  public var combine: MaskCombineOperation?
  public var brushSettings: BrushSettings
  public var sampleSource: FillSampleSource
  public var tolerance: Double
  public var edgeSensitivity: Double
  public var smoothness: Double
  public var feather: Double

  public init(
    mode: SelectionBrushMode = .paint,
    combine: MaskCombineOperation? = nil,
    brushSettings: BrushSettings = BrushSettings(
      size: 40, hardness: 0.8, opacity: 1, flow: 1, spacing: 0.12,
      pressureResponse: 0.75),
    sampleSource: FillSampleSource = .composite,
    tolerance: Double = 0.12,
    edgeSensitivity: Double = 0.55,
    smoothness: Double = 0.35,
    feather: Double = 0
  ) {
    self.mode = mode
    self.combine = combine
    self.brushSettings = brushSettings.validated
    self.sampleSource = sampleSource
    self.tolerance = MagnetSelectionToolState.unit(tolerance, fallback: 0.12)
    self.edgeSensitivity = MagnetSelectionToolState.unit(edgeSensitivity, fallback: 0.55)
    self.smoothness = MagnetSelectionToolState.unit(smoothness, fallback: 0.35)
    self.feather = SelectionToolState.clamped(feather, upTo: 250)
  }

  /// The same round, pressure-sized tip is used for Quick Select hints, but
  /// hint strength is binary rather than paint opacity.
  public var quickHintSettings: BrushSettings {
    BrushSettings(
      size: brushSettings.size,
      hardness: 1,
      opacity: 1,
      flow: 1,
      spacing: brushSettings.spacing,
      pressureResponse: brushSettings.pressureResponse)
  }
}

public struct BrushPreview: Sendable {
  public let frame: StrokeSurfaceFrame
  public let baseContentRevision: UInt64
  /// A paint or layer-mask destination when the preview will be committed to a
  /// layer. Selection-brush coverage lives in canonical canvas space and has
  /// no layer destination.
  public let target: PaintTarget?
  public let strokeMode: BrushStrokeMode
  /// Whether this coverage is a heal region rather than paint or mask
  /// coverage.
  ///
  /// A heal cannot be previewed as its result: the patch is solved once, on
  /// release, because solving it per pointer event is not affordable. So the
  /// drag shows where the heal will land, and the canvas tints it differently
  /// from painting a mask so the two are not mistaken for each other.
  public let isHealCoverage: Bool

  public init(
    frame: StrokeSurfaceFrame,
    baseContentRevision: UInt64,
    target: PaintTarget? = nil,
    strokeMode: BrushStrokeMode,
    isHealCoverage: Bool = false
  ) {
    self.frame = frame
    self.baseContentRevision = baseContentRevision
    self.target = target
    self.strokeMode = strokeMode
    self.isHealCoverage = isHealCoverage
  }
}

/// Foreground/background color state owned by one document window.
///
/// These colors are defaults only. A brush stroke, vector path or text layer
/// copies its color into the recipe when it is created, so changing a chip
/// never recolors existing artwork and never dirties the document.
public struct ColorToolState: Equatable, Sendable {
  public var foreground: LinearRGBAColor
  public var background: LinearRGBAColor
  public var sampleSource: ColorSampleSource
  public var sampleSize: ColorSampleSize
  public var recentColors: [LinearRGBAColor]
  public var pinnedColors: [LinearRGBAColor]

  public init(
    foreground: LinearRGBAColor = .black,
    background: LinearRGBAColor = .white,
    sampleSource: ColorSampleSource = .composite,
    sampleSize: ColorSampleSize = .fiveByFive,
    recentColors: [LinearRGBAColor] = [],
    pinnedColors: [LinearRGBAColor] = []
  ) {
    self.foreground = foreground
    self.background = background
    self.sampleSource = sampleSource
    self.sampleSize = sampleSize
    self.recentColors = Array(recentColors.prefix(12))
    self.pinnedColors = Array(pinnedColors.prefix(12))
  }
}

public enum LayerOperationStatus: Equatable, Sendable {
  case idle
  case rasterizing
  case merging(Int)
  case copying
  case pasting
  /// A heal is being solved. It runs once, on release, and a large patch takes
  /// long enough that saying nothing would read as a dropped gesture.
  case healing
  case failed(String)

  public var isRunning: Bool {
    switch self {
    case .rasterizing, .merging, .copying, .pasting, .healing: true
    case .idle, .failed: false
    }
  }
}

@MainActor
public final class EditorModel: ObservableObject {
  @Published public private(set) var recipe: ProjectRecipe
  @Published public private(set) var history: EditHistory
  @Published public private(set) var renderedFrame: RenderedFrame?
  @Published public private(set) var renderStatus: RenderStatus = .idle
  @Published public private(set) var differencePreviewLayerID: ProjectLayerID?
  /// Layer-list selection is session state. The first-selected layer remains
  /// primary while Command-click extends the set, so Develop and tool targets
  /// do not jump as a multi-selection is assembled.
  @Published public private(set) var selectedLayerIDs: Set<ProjectLayerID> = []
  @Published public private(set) var layerOperationStatus: LayerOperationStatus = .idle
  private var layerSelectionOrder: [ProjectLayerID] = []
  @Published public private(set) var activeTool: EditorTool = .navigate
  /// Appearance defaults shared by every vector-creation tool. A style chosen
  /// in Pen remains the style of the next Shape and vice versa.
  @Published private(set) var vectorToolStyle = VectorToolStyle(
    strokeColor: .black, fillMode: .solid, fillColor: .white)
  @Published private(set) var vectorEditMode: VectorEditMode = .draw
  /// Which objects inside the active vector layer the style, transform, and
  /// arrangement controls act on.
  ///
  /// Transient session state, deliberately outside the recipe: a selection
  /// changes no pixels, so it must not cost a revision, a render, or a history
  /// step. Only the edits it targets become document state.
  @Published private(set) var selectedVectorObjectIDs: Set<UUID> = []
  @Published private(set) var gradientTool = GradientToolState()
  @Published private(set) var fillTool = FillToolState()
  @Published private(set) var healTool = HealToolState()
  @Published private(set) var shapeTool = ShapeToolState()
  @Published private(set) var textToolStyle = TextToolStyle(color: .black)
  @Published public private(set) var colorTool = ColorToolState()
  /// Brush controls are window-local tool state until a stroke snapshots them.
  @Published public private(set) var brushSettings = BrushCatalog.preset(.hardRound).settings
  @Published public private(set) var brushPresetID: BrushPresetID = .hardRound
  @Published public private(set) var brushDefinition = BrushCatalog.preset(.hardRound).definition
  @Published public private(set) var eraserSettings = BrushCatalog.preset(.hardRound).settings
  @Published public private(set) var eraserPresetID: BrushPresetID = .hardRound
  @Published public private(set) var eraserDefinition = BrushCatalog.preset(.hardRound).definition
  /// Edits made to a preset, kept per preset and per tool for this session so
  /// that browsing the library and coming back does not throw them away.
  /// Reset Brush drops the entry, which is what makes Reset different from
  /// selecting the same preset again.
  @Published private(set) var brushOverrides: [BrushPresetID: BrushSettings] = [:]
  @Published private(set) var eraserOverrides: [BrushPresetID: BrushSettings] = [:]
  /// Preview strokes rendered by `RenderEngine`, keyed by preset. SwiftUI only
  /// displays them; it never renders a brush itself.
  @Published private(set) var brushPresetPreviews: [BrushPresetID: CGImage] = [:]
  public var brushColor: LinearRGBAColor { colorTool.foreground }
  /// Tiled Metal output for the in-flight stroke only.
  @Published public private(set) var brushPreview: BrushPreview?
  /// Selected by the layer or mask thumbnail. Reads go through
  /// `resolvedPaintTarget`, so undo/deletion cannot leave an orphan target.
  @Published public private(set) var paintTarget: PaintTarget?
  /// The distribution of the frame on screen. Analysis is revision-tagged and
  /// accepted only while that exact frame remains presented.
  @Published public private(set) var histogram: ImageHistogram?
  /// Whether the separately scheduled analysis of the presented frame is in
  /// progress. Rendering can already be ready while this remains true.
  @Published public private(set) var isAnalyzingRenderedFrame = false
  /// The colors of the frame on screen, for the color panel's palette.
  @Published public private(set) var sampledPalette: [PaletteColor] = []
  /// Distinct Vision and generated suggestions for the displayed composite.
  @Published public private(set) var imageContentTags: [ImageContentTag] = []
  private var visionContentTags: [ImageContentTag] = []
  private var generatedContentTags: [ImageContentTag] = []
  @Published public private(set) var comfyUISelectionPreview: MaskRecipe?
  @Published public private(set) var clipping = ClippingIndicators()
  /// Whether the canvas is showing the captured RAW defaults instead of the
  /// current recipe. View state: the recipe and the document's dirty state are
  /// untouched while it is on.
  @Published public private(set) var isShowingBefore = false
  /// The pixel the canvas has been asked for, while the request stands.
  ///
  /// Tool state, and deliberately not a tool: it overlays whatever tool is
  /// active rather than replacing it. Nothing here is undoable or saved — the
  /// edit happens when the click lands, and the preview it carries meanwhile
  /// never reaches the recipe.
  @Published public private(set) var pendingSample: PixelSampleRequest?
  /// The Crop tool's session state while it is open.
  ///
  /// Before Apply, this carries uncommitted edit intent. After Apply it remains
  /// only to keep the target, controls and outline alive while the committed
  /// recipe is rendered. The canvas draws it and the left panel edits it, which
  /// is why it is published here rather than held privately by either.
  @Published public private(set) var cropDraft: CropDraft?
  @Published public private(set) var transformDraft: TransformDraft?
  /// The background export queue, as values the panel can render.
  ///
  /// The queue itself runs beside the document; what it publishes here is a
  /// snapshot, so the export section observes this model like every other view
  /// instead of reaching into the machinery that does the work.
  @Published public private(set) var exportJobs: [ExportJob] = []
  @Published public private(set) var maskTool = MaskToolState()
  @Published public private(set) var selectionTool = SelectionToolState()
  @Published public private(set) var magnetSelectionTool = MagnetSelectionToolState()
  @Published public private(set) var selectionBrushTool = SelectionBrushToolState()
  /// The selection the tool is dragging, while the pointer is still down.
  ///
  /// Like `cropDraft`, this is edit intent that has not been committed: nothing
  /// here is undoable, saved, or visible to the document until mouse-up sends
  /// one `.setSelection`. Unlike a gradient drag it never enters the recipe
  /// mid-gesture, because a selection changes no pixels and so should not cost
  /// a render or a revision on every pointer event.
  @Published public private(set) var selectionDraft: MaskRecipe?
  /// Prompt-generation tool controls and the document-owned queue snapshot.
  @Published public private(set) var inpaintingTool = InpaintingToolState()
  /// The mask requested for the next Prompt Box inpaint. Kept separate from
  /// `inpaintingTool` because that value is copied into global ComfyUI history,
  /// while concrete layer and mask IDs are meaningful only in this document.
  @Published public private(set) var generationMaskSource: GenerationMaskSourceChoice = .automatic
  @Published public private(set) var generationJobs: [GenerationJob] = []
  @Published public private(set) var comfyUIConnection: ComfyUIConnectionState = .disconnected(nil)
  @Published public private(set) var comfyUIExecutionTarget: ComfyUIExecutionTarget = .local
  @Published public private(set) var hasComfyCloudAPIKey = false
  /// Session-only generation details shown in the Prompt Box. Collection is
  /// continuous even while Details is collapsed, deliberately excluded from
  /// the project recipe, and bounded independently of job history.
  @Published private(set) var comfyUIDebugEvents: [ComfyUIDebugEvent] = []
  @Published private(set) var comfyUIDebugImages: [ComfyUIDebugImage] = []
  @Published private(set) var comfyUIDebugDiskLoggingState: ComfyUIDebugDiskLoggingState =
    .disabled
  @Published public private(set) var selectedComfyUIWorkflowID: String
  @Published private(set) var selectedComfyUIWorkflowMode: GenerationMode
  private(set) var unresolvedComfyUIWorkflowMode: GenerationMode?
  @Published private(set) var comfyUIWorkflowFormState: ComfyUIWorkflowFormState = .unavailable
  @Published private(set) var comfyUIParameterValues:
    [ComfyUIParameterAddress: ComfyUIParameterValue] = [:]
  private var comfyUIWorkflowDrafts:
    [String: [ComfyUIParameterAddress: ComfyUIParameterValue]] = [:]
  @Published private(set) var comfyUIHistoryRestoreNotice: String?
  private struct PendingComfyUIHistoryRestore {
    var templateID: String
    var templateRevision: String
    var parameters: [ComfyUIParameterRecord]
    var warning: String?
  }
  private var pendingComfyUIHistoryRestore: PendingComfyUIHistoryRestore?
  /// A decoded denoising step shown by the canvas but never saved or undone.
  @Published public private(set) var generationPreview: RenderedFrame?

  public init(recipe: ProjectRecipe = ProjectRecipe()) {
    self.recipe = recipe
    self.history = EditHistory(initial: recipe)
    let initialWorkflowID = AppSettings.storedDefaultComfyUIWorkflowID(for: .textToImage)
    self.selectedComfyUIWorkflowID = initialWorkflowID
    let initialWorkflowMode = ComfyUIWorkflowCatalog.mode(templateID: initialWorkflowID)
    self.selectedComfyUIWorkflowMode = initialWorkflowMode ?? .textToImage
    self.unresolvedComfyUIWorkflowMode = initialWorkflowMode == nil ? .textToImage : nil
    self.paintTarget = recipe.layerStack.activeLayerID.flatMap { id in
      recipe.layerStack.layer(id: id)?.isCanvasLayer == false ? .layerPixels(id) : nil
    }
    resetLayerSelection(to: recipe.layerStack.activeLayerID)
  }

  /// The layer selected in the layers inspector.
  ///
  /// The primary layer remains recipe state because the canvas and inspectors
  /// must agree on their target. The wider Command-click set is session state
  /// in `selectedLayerIDs` and does not enter history or persistence.
  public var activeLayer: ProjectLayer? {
    recipe.layerStack.activeLayerID.flatMap { recipe.layerStack.layer(id: $0) }
  }

  public var generationMode: GenerationMode {
    let hasSourcePixels = recipe.layerStack.flattenedLayers.contains {
      $0.isEffectivelyEnabled && !$0.layer.isGroupLayer && $0.layer.isRasterContent
    }
    return hasSourcePixels ? .inpainting : .textToImage
  }

  /// The selected external workflow decides which conditioning inputs exist.
  /// The first z-image graph is text-to-image even when this document already
  /// contains pixels; later inpaint templates can declare that mode explicitly.
  public var comfyUIGenerationMode: GenerationMode {
    ComfyUIWorkflowCatalog.templates.first(where: { $0.id == selectedComfyUIWorkflowID })?.mode
      ?? selectedComfyUIWorkflowMode
  }

  /// Sources offered by the inpaint mask picker for the current primary layer.
  /// Disabled masks remain visible so the picker explains why they cannot be
  /// chosen instead of silently making them disappear.
  public var generationMaskSourceOptions: [GenerationMaskSourceOption] {
    var options = [
      GenerationMaskSourceOption(
        source: .automatic,
        label: "Automatic",
        isAvailable: true,
        unavailableReason: nil),
    ]
    // A restored app-level history entry intentionally carries no document
    // mask IDs. Keep its compatibility choice representable in the Picker
    // until the user selects a modern source, rather than leaving the Picker
    // bound to a value for which it has no row.
    if generationMaskSource == .legacySelectionOrEntireOutput {
      options.append(
        GenerationMaskSourceOption(
          source: .legacySelectionOrEntireOutput,
          label: "Selection or Entire Output (Restored)",
          isAvailable: true,
          unavailableReason: nil))
    }
    options.append(optionForDocumentSelection())

    if let layerID = recipe.layerStack.activeLayerID,
      let layer = recipe.layerStack.layer(id: layerID)
    {
      let layerIsEffective = recipe.layerStack.flattenedLayers.first(where: { $0.id == layerID })?
        .isEffectivelyEnabled == true
      if let mask = layer.layerMask {
        options.append(
          option(
            for: .layerMask(layerID, mask.id),
            label: "Layer Mask — \(layer.name)",
            mask: mask,
            owningLayerIsEnabled: layerIsEffective))
      }
      options.append(contentsOf: layer.masks.map { mask in
        option(
          for: .localMask(layerID, mask.id),
          label: "\(mask.name) — \(layer.name)",
          mask: mask,
          owningLayerIsEnabled: layerIsEffective)
      })
    }

    options.append(
      GenerationMaskSourceOption(
        source: .transparentPixels,
        label: "Transparent Pixels",
        isAvailable: true,
        unavailableReason: nil))
    options.append(
      GenerationMaskSourceOption(
        source: .entireOutput,
        label: "Entire Output",
        isAvailable: true,
        unavailableReason: nil))
    return options
  }

  /// The source Automatic would choose now, or the available explicit source.
  /// Pixel-level emptiness is deliberately left to generation preparation;
  /// structural inspection cannot prove the result of combined or
  /// image-dependent masks.
  public var resolvedGenerationMaskSource: GenerationMaskSourceChoice? {
    resolveGenerationMaskSource(generationMaskSource, in: recipe)
  }

  private func resolveGenerationMaskSource(
    _ source: GenerationMaskSourceChoice,
    in candidateRecipe: ProjectRecipe
  ) -> GenerationMaskSourceChoice? {
    switch source {
    case .automatic:
      // A present-but-invalid selection is still authoritative: generation
      // must report that specific problem instead of unexpectedly widening to
      // another source.
      if candidateRecipe.selection != nil { return .documentSelection }
      if let layerID = candidateRecipe.layerStack.activeLayerID,
        candidateRecipe.layerStack.flattenedLayers.first(where: { $0.id == layerID })?
          .isEffectivelyEnabled == true,
        let mask = candidateRecipe.layerStack.layer(id: layerID)?.layerMask,
        isUsableGenerationMask(mask)
      {
        return .layerMask(layerID, mask.id)
      }
      return .transparentPixels
    case .documentSelection:
      return isUsableGenerationMask(candidateRecipe.selection) ? .documentSelection : nil
    case .layerMask(let layerID, let maskID):
      guard candidateRecipe.layerStack.activeLayerID == layerID,
        candidateRecipe.layerStack.flattenedLayers.first(where: { $0.id == layerID })?
          .isEffectivelyEnabled == true,
        let mask = candidateRecipe.layerStack.layer(id: layerID)?.layerMask,
        mask.id == maskID,
        isUsableGenerationMask(mask)
      else { return nil }
      return source
    case .localMask(let layerID, let maskID):
      guard candidateRecipe.layerStack.activeLayerID == layerID,
        candidateRecipe.layerStack.flattenedLayers.first(where: { $0.id == layerID })?
          .isEffectivelyEnabled == true,
        let mask = candidateRecipe.layerStack.layer(id: layerID)?.mask(id: maskID),
        isUsableGenerationMask(mask)
      else { return nil }
      return source
    case .transparentPixels:
      return .transparentPixels
    case .entireOutput:
      return .entireOutput
    case .legacySelectionOrEntireOutput:
      return candidateRecipe.selection == nil ? .entireOutput : .documentSelection
    }
  }

  public var generationMaskSourcePresentation: GenerationMaskSourcePresentation {
    generationMaskSourcePresentation(for: generationMaskSource, in: recipe)
  }

  public func generationMaskSourcePresentation(
    for source: GenerationMaskSourceChoice,
    in candidateRecipe: ProjectRecipe
  ) -> GenerationMaskSourcePresentation {
    let requestedLabel = generationMaskSourceLabel(source, in: candidateRecipe)
    let resolved = resolveGenerationMaskSource(source, in: candidateRecipe)
    let unavailableReason = generationMaskSourceUnavailableReason(
      source, resolved: resolved, in: candidateRecipe)
    return GenerationMaskSourcePresentation(
      requested: source,
      requestedLabel: requestedLabel,
      resolved: resolved,
      resolvedLabel: resolved.map { generationMaskSourceLabel($0, in: candidateRecipe) },
      unavailableReason: unavailableReason)
  }

  public func setGenerationMaskSource(_ source: GenerationMaskSourceChoice) {
    guard source != generationMaskSource else { return }
    generationMaskSource = source
    reconcileGenerationMaskSource(with: recipe)
  }

  /// Restored pre-mask-source history keeps its original selection-or-output
  /// behavior without placing document identifiers in `InpaintingToolState`.
  public func useLegacyGenerationMaskSourceForRestoredHistory() {
    setGenerationMaskSource(.legacySelectionOrEntireOutput)
  }

  private func optionForDocumentSelection() -> GenerationMaskSourceOption {
    guard let selection = recipe.selection else {
      return GenerationMaskSourceOption(
        source: .documentSelection,
        label: "Document Selection",
        isAvailable: false,
        unavailableReason: "Create a document selection before choosing it as the inpaint mask.")
    }
    return option(
      for: .documentSelection,
      label: "Document Selection",
      mask: selection)
  }

  private func option(
    for source: GenerationMaskSourceChoice,
    label: String,
    mask: MaskRecipe,
    owningLayerIsEnabled: Bool = true
  ) -> GenerationMaskSourceOption {
    let reason: String? = if !owningLayerIsEnabled {
      "The mask's layer is hidden or inside a hidden group."
    } else if !mask.isEnabled {
      "\(label) is disabled."
    } else if !mask.isEvaluable {
      "\(label) has no available mask components."
    } else if hasEnabledUnavailableComponents(mask) {
      "\(label) contains mask components that are unavailable on this Mac."
    } else {
      nil
    }
    return GenerationMaskSourceOption(
      source: source,
      label: label,
      isAvailable: reason == nil,
      unavailableReason: reason)
  }

  private func isUsableGenerationMask(_ mask: MaskRecipe?) -> Bool {
    guard let mask else { return false }
    return mask.isEnabled && mask.isEvaluable && !hasEnabledUnavailableComponents(mask)
  }

  private func hasEnabledUnavailableComponents(_ mask: MaskRecipe) -> Bool {
    mask.components.contains { $0.isEnabled && !$0.availability.isAvailable }
  }

  private func generationMaskSourceUnavailableReason(
    _ source: GenerationMaskSourceChoice,
    resolved: GenerationMaskSourceChoice?,
    in candidateRecipe: ProjectRecipe
  ) -> String? {
    let effectiveSource = source == .automatic ? resolved : source
    switch effectiveSource {
    case .documentSelection:
      guard let selection = candidateRecipe.selection else {
        return "Create a document selection before choosing it as the inpaint mask."
      }
      return unavailableReason(
        for: selection, label: "Document Selection")
    case .layerMask(let layerID, let maskID):
      guard let layer = candidateRecipe.layerStack.layer(id: layerID),
        let mask = layer.layerMask, mask.id == maskID
      else { return "The requested layer mask is no longer available on the active layer." }
      if candidateRecipe.layerStack.flattenedLayers.first(where: { $0.id == layerID })?
        .isEffectivelyEnabled != true
      {
        return "The mask's layer is hidden or inside a hidden group."
      }
      return unavailableReason(for: mask, label: "Layer Mask — \(layer.name)")
    case .localMask(let layerID, let maskID):
      guard let layer = candidateRecipe.layerStack.layer(id: layerID),
        let mask = layer.mask(id: maskID)
      else { return "The requested local mask is no longer available on the active layer." }
      if candidateRecipe.layerStack.flattenedLayers.first(where: { $0.id == layerID })?
        .isEffectivelyEnabled != true
      {
        return "The mask's layer is hidden or inside a hidden group."
      }
      return unavailableReason(for: mask, label: "\(mask.name) — \(layer.name)")
    case .none:
      return "The requested mask is no longer available on the active layer."
    case .automatic, .transparentPixels, .entireOutput, .legacySelectionOrEntireOutput:
      return nil
    }
  }

  private func unavailableReason(for mask: MaskRecipe, label: String) -> String? {
    if !mask.isEnabled { return "\(label) is disabled." }
    if !mask.isEvaluable { return "\(label) has no available mask components." }
    if hasEnabledUnavailableComponents(mask) {
      return "\(label) contains mask components that are unavailable on this Mac."
    }
    return nil
  }

  private func generationMaskSourceLabel(
    _ source: GenerationMaskSourceChoice,
    in candidateRecipe: ProjectRecipe
  ) -> String {
    switch source {
    case .automatic: return "Automatic"
    case .documentSelection: return "Document Selection"
    case .layerMask(let layerID, _):
      return candidateRecipe.layerStack.layer(id: layerID).map { "Layer Mask — \($0.name)" }
        ?? "Layer Mask"
    case .localMask(let layerID, let maskID):
      let layer = candidateRecipe.layerStack.layer(id: layerID)
      return layer?.mask(id: maskID).map { "\($0.name) — \(layer?.name ?? "Layer")" }
        ?? "Local Mask"
    case .transparentPixels: return "Transparent Pixels"
    case .entireOutput: return "Entire Output"
    case .legacySelectionOrEntireOutput: return "Selection or Entire Output (Legacy)"
    }
  }

  /// Applies a List multi-selection without recording history or dirtying the
  /// document. Adding IDs preserves the original primary; removing that
  /// primary promotes the earliest still-selected ID.
  func setLayerSelection(_ requested: Set<ProjectLayerID>) {
    let valid = Set(recipe.layerStack.allLayers.map(\.id))
    let next = requested.intersection(valid)
    let previous = selectedLayerIDs
    let oldPrimary = recipe.layerStack.activeLayerID
    let selectionChanged = next != previous

    layerSelectionOrder.removeAll { !next.contains($0) }
    let additions = next.subtracting(previous)
    for id in recipe.layerStack.flattenedLayers.map(\.id) where additions.contains(id) {
      layerSelectionOrder.append(id)
    }

    let primary: ProjectLayerID?
    if next.count == 1 {
      primary = next.first
    } else if let oldPrimary, next.contains(oldPrimary) {
      primary = oldPrimary
    } else {
      primary = layerSelectionOrder.first ?? next.first
    }

    selectedLayerIDs = next
    var updated = recipe
    updated.layerStack.activeLayerID = primary
    recipe = updated
    history.updateCurrent(updated)
    if let primary, updated.layerStack.layer(id: primary)?.isCanvasLayer == false,
      next.count == 1,
      selectionChanged || primary != oldPrimary
    {
      paintTarget = .layerPixels(primary)
    }

    if primary != oldPrimary { selectedVectorObjectIDs = [] }
    reconcileGenerationMaskSource(with: updated)
    reconcileVectorObjectSelection()
  }

  func setLayerOperationStatus(_ status: LayerOperationStatus) {
    guard layerOperationStatus != status else { return }
    layerOperationStatus = status
  }

  // MARK: - Vector object selection

  /// The vector layer the object controls act on, when the active layer is one.
  var activeVectorLayer: (id: ProjectLayerID, vector: VectorLayer, isLocked: Bool)? {
    guard let id = recipe.layerStack.activeLayerID,
      let layer = recipe.layerStack.layer(id: id),
      case .vector(let vector) = layer.content
    else { return nil }
    return (id, vector, layer.isLocked)
  }

  /// The selected objects, restricted to those that still exist.
  var selectedVectorObjects: [VectorObject] {
    guard let vector = activeVectorLayer?.vector else { return [] }
    return vector.objectsInDrawOrder.filter { selectedVectorObjectIDs.contains($0.id) }
  }

  func setVectorEditMode(_ mode: VectorEditMode) {
    guard vectorEditMode != mode else { return }
    vectorEditMode = mode
  }

  func setSelectedVectorObjects(_ ids: Set<UUID>) {
    let valid = Set(activeVectorLayer?.vector.objects.map(\.id) ?? [])
    let next = ids.intersection(valid)
    guard selectedVectorObjectIDs != next else { return }
    selectedVectorObjectIDs = next
  }

  func toggleVectorObject(_ id: UUID) {
    var next = selectedVectorObjectIDs
    if next.contains(id) { next.remove(id) } else { next.insert(id) }
    setSelectedVectorObjects(next)
  }

  func clearVectorObjectSelection() {
    guard !selectedVectorObjectIDs.isEmpty else { return }
    selectedVectorObjectIDs = []
  }

  /// Drops objects that undo, deletion, or a layer change has taken away.
  private func reconcileVectorObjectSelection() {
    guard !selectedVectorObjectIDs.isEmpty else { return }
    let valid = Set(activeVectorLayer?.vector.objects.map(\.id) ?? [])
    let surviving = selectedVectorObjectIDs.intersection(valid)
    if surviving != selectedVectorObjectIDs { selectedVectorObjectIDs = surviving }
  }

  private func resetLayerSelection(to id: ProjectLayerID?) {
    selectedLayerIDs = id.map { [$0] } ?? []
    layerSelectionOrder = id.map { [$0] } ?? []
  }

  private func reconcileLayerSelection(with recipe: ProjectRecipe) {
    defer {
      reconcileGenerationMaskSource(with: recipe)
      reconcileVectorObjectSelection()
    }
    let valid = Set(recipe.layerStack.allLayers.map(\.id))
    let surviving = selectedLayerIDs.intersection(valid)
    layerSelectionOrder.removeAll { !surviving.contains($0) }
    if surviving.isEmpty {
      resetLayerSelection(to: recipe.layerStack.activeLayerID)
    } else {
      selectedLayerIDs = surviving
      if let active = recipe.layerStack.activeLayerID, !surviving.contains(active) {
        resetLayerSelection(to: active)
      }
    }
  }

  /// Concrete mask choices are intentionally scoped to the primary layer.
  /// Moving to another layer or deleting the referenced mask returns to the
  /// safe dynamic default; disabled masks remain selected so execution can
  /// explain that exact problem rather than broadening the mask silently.
  private func reconcileGenerationMaskSource(with recipe: ProjectRecipe) {
    let isStale: Bool
    switch generationMaskSource {
    case .layerMask(let layerID, let maskID):
      isStale = recipe.layerStack.activeLayerID != layerID
        || recipe.layerStack.layer(id: layerID)?.layerMask?.id != maskID
    case .localMask(let layerID, let maskID):
      isStale = recipe.layerStack.activeLayerID != layerID
        || recipe.layerStack.layer(id: layerID)?.mask(id: maskID) == nil
    case .automatic, .documentSelection, .transparentPixels, .entireOutput,
      .legacySelectionOrEntireOutput:
      isStale = false
    }
    if isStale { generationMaskSource = .automatic }
  }

  public var resolvedPaintTarget: PaintTarget? {
    guard let paintTarget,
      recipe.layerStack.activeLayerID == paintTarget.layerID,
      let layer = recipe.layerStack.layer(id: paintTarget.layerID),
      !layer.isCanvasLayer
    else {
      return recipe.layerStack.activeLayerID.flatMap { id in
        guard recipe.layerStack.layer(id: id)?.isCanvasLayer == false else { return nil }
        return .layerPixels(id)
      }
    }
    if case .layerMask(_, let maskID) = paintTarget,
      layer.layerMask?.id != maskID
    {
      return .layerPixels(layer.id)
    }
    return paintTarget
  }

  /// Whether this document has a white balance the picker could neutralize.
  ///
  /// The picker needs a RAW layer whose neutral values the decoder has already
  /// reported; a canvas or placed-image document has no white balance to set,
  /// and neither does a RAW whose capabilities have not come back yet. It used
  /// to also refuse while Before was on, because both were toggles in the tool
  /// strip and either could be left on top of the other. Arming a sample simply
  /// turns Before off now, so the conflict has nowhere left to arise.
  public var canPickWhiteBalance: Bool {
    activeLayer?.developedRawLayer?.rawDevelopment.parameters != nil
  }

  /// Why the picker is unavailable, for menus and toolbar help.
  ///
  /// Before is deliberately not a reason: arming the picker leaves that
  /// presentation state behind and returns to the editable rendering first.
  public var whiteBalancePickerUnavailableReason: String? {
    guard let raw = activeLayer?.developedRawLayer else {
      return "Select a RAW layer to use the white-balance picker."
    }
    if raw.rawDevelopment.parameters == nil {
      return "The RAW decoder has not reported this file's white balance yet."
    }
    return nil
  }

  /// The as-shot white balance the decoder reported, when there is one to
  /// return to.
  public var asShotWhiteBalance: (temperature: Double, tint: Double)? {
    guard let defaults = activeLayer?.developedRawLayer?.rawDevelopment.capturedDefaults else {
      return nil
    }
    return (defaults.neutralTemperature, defaults.neutralTint)
  }

  /// Whether the white balance now differs from the one the file was shot with.
  ///
  /// What the As Shot button is offered on: with nothing to put back, the
  /// button would promise a change it cannot make.
  public var whiteBalanceDiffersFromAsShot: Bool {
    guard let parameters = activeLayer?.developedRawLayer?.rawDevelopment.parameters,
      let asShot = asShotWhiteBalance
    else { return false }
    return parameters.neutralTemperature != asShot.temperature
      || parameters.neutralTint != asShot.tint
  }

  /// Whether there is a captured set of RAW defaults to compare against.
  public var canShowBefore: Bool {
    activeLayer?.developedRawLayer?.rawDevelopment.capturedDefaults != nil
  }

  /// Replaces the recipe and starts a fresh history at it.
  ///
  /// This is how a document begins an editing session: File ▸ New, importing a
  /// RAW, and opening a saved project each start from one baseline step rather
  /// than continuing the previous document's history.
  func replaceRecipe(_ recipe: ProjectRecipe, historyName: String = "Open") {
    self.recipe = recipe
    history.reset(to: recipe, name: historyName)
    paintTarget = recipe.layerStack.activeLayerID.flatMap { id in
      recipe.layerStack.layer(id: id)?.isCanvasLayer == false ? .layerPixels(id) : nil
    }
    resetLayerSelection(to: recipe.layerStack.activeLayerID)
    generationMaskSource = .automatic
  }

  /// Replaces the recipe without recording a step, keeping the current step in
  /// step with it.
  ///
  /// Used for changes the user did not make: decoder metadata merged in after a
  /// render, and the source hash that finishes computing in the background.
  /// Returning to the current step later must restore these too.
  func updateRecipeInPlace(_ recipe: ProjectRecipe) {
    self.recipe = recipe
    history.updateCurrent(recipe)
    reconcileLayerSelection(with: recipe)
  }

  /// The recipe the render engine is asked for right now.
  ///
  /// While a crop is being adjusted the render shows the whole target with the
  /// straighten applied, so the user can see what the rectangle moves over.
  /// After Apply the draft remains for the controls but no longer opens the
  /// target, so the committed crop is what the canvas shows.
  public var renderRecipe: ProjectRecipe {
    var effective = recipe
    if let cropDraft, cropDraft.revealsFullTarget {
      switch cropDraft.target {
      case .canvas:
        effective.crop = cropDraft.recipe.openedToFullFrame
      case .layer(let id):
        effective.layerStack.updateLayer(id: id) {
          $0.crop = cropDraft.recipe.openedToFullFrame
        }
      }
    }
    if let transformDraft {
      if let objects = transformedVectorLayer(for: transformDraft, in: effective.layerStack) {
        effective.layerStack.updateLayer(id: transformDraft.targetID) { layer in
          guard case .vector = layer.content else { return }
          layer.content = .vector(objects)
        }
      } else {
        effective.layerStack = effective.layerStack.settingTransform(
          transformDraft.transform, for: transformDraft.targetID)
      }
    }
    return effective
  }

  /// The vector layer an object-level transform draft produces, or nil when the
  /// draft targets a whole layer.
  ///
  /// The same function serves the live preview and the commit, so what the user
  /// sees during the drag is exactly what the recipe records.
  func transformedVectorLayer(
    for draft: TransformDraft, in stack: LayerStackRecipe
  ) -> VectorLayer? {
    guard !draft.objectIDs.isEmpty,
      let layer = stack.layer(id: draft.targetID),
      case .vector(let vector) = layer.content,
      !layer.isLocked,
      stack.canvas.isResolved,
      let transform = draft.transform.vectorTransform(
        canvasWidth: Double(stack.canvas.width),
        canvasHeight: Double(stack.canvas.height)
      )
    else { return nil }
    return vector.transformingObjects(
      ids: draft.objectIDs,
      by: transform,
      aspect: Double(stack.canvas.width) / Double(stack.canvas.height))
  }

  /// The oriented image size the crop is measured against, once a render has
  /// reported one.
  ///
  /// Crop geometry is unit-based, but aspect locks and straighten limits are
  /// about pixels, so the tool needs the real shape of the image. Before the
  /// first render, the canvas extent stands in.
  public func cropReferenceSize(for target: CropTarget) -> (width: Double, height: Double)? {
    switch target {
    case .canvas:
      if recipe.layerStack.layer(id: .rawBackground)?.isDevelopedRaw == true,
        let inspection = renderedFrame?.rawInspections[.rawBackground] ?? renderedFrame?.inspection
      {
        let size = inspection.orientedSize
        if size.width > 0, size.height > 0 { return size }
      }
      let canvas = recipe.layerStack.canvas
      guard canvas.isResolved else { return nil }
      return (width: Double(canvas.width), height: Double(canvas.height))
    case .layer(let id):
      // The whole layer, not its applied crop: the crop is measured in it.
      guard recipe.layerStack.canCropLayer(id),
        let frame = recipe.layerStack.uncroppedFrame(of: id),
        !frame.isEmpty
      else { return nil }
      return (width: frame.width, height: frame.height)
    }
  }

  public var defaultCropTarget: CropTarget {
    if let id = recipe.layerStack.activeLayerID, recipe.layerStack.canCropLayer(id) {
      return .layer(id)
    }
    return .canvas
  }

  func setCropDraft(_ draft: CropDraft?) {
    guard cropDraft != draft else { return }
    cropDraft = draft
  }

  func setTransformDraft(_ draft: TransformDraft?) {
    guard transformDraft != draft else { return }
    transformDraft = draft
  }

  /// Replaces the recipe for the duration of a continuous gesture.
  ///
  /// A drag produces many intermediate recipes and exactly one history step, so
  /// nothing is recorded until the gesture ends.
  func setTransientRecipe(_ recipe: ProjectRecipe) {
    self.recipe = recipe
    reconcileLayerSelection(with: recipe)
  }

  /// Records one named, undoable edit and makes it current.
  func recordEdit(_ recipe: ProjectRecipe, name: String) {
    history.record(recipe, name: name)
    self.recipe = recipe
    reconcileLayerSelection(with: recipe)
  }

  /// Returns the document to an existing step, or `nil` when that step is gone.
  @discardableResult
  func moveHistory(toStep id: HistoryStepID) -> ProjectRecipe? {
    guard let restored = history.move(to: id) else { return nil }
    recipe = restored
    reconcileLayerSelection(with: restored)
    return restored
  }

  @discardableResult
  func addSnapshot(name: String) -> HistorySnapshotID {
    history.addSnapshot(name: name, recipe: recipe)
  }

  func removeSnapshot(_ id: HistorySnapshotID) {
    history.removeSnapshot(id)
  }

  func renameSnapshot(_ id: HistorySnapshotID, to name: String) {
    history.renameSnapshot(id, to: name)
    // An undo that removes the mask the tool is aimed at must not leave the
    // canvas editing something that is no longer in the document.
    if let layerID = maskTool.activeLayerID, let maskID = maskTool.activeMaskID,
      recipe.layerStack.mask(maskID, on: layerID) == nil
    {
      maskTool.activeMaskID = nil
    }
  }

  /// Merges what each decoder reported, into the RAW layer that owns it.
  ///
  /// A multi-RAW render can finish several independent decoder sessions at
  /// once. Their capabilities and captured defaults must never bleed between
  /// layers merely because they shared one canvas render.
  func merge(_ inspections: [ProjectLayerID: RawInspection]) {
    for (layerID, inspection) in inspections {
      mergeInspection(inspection, for: layerID)
    }
  }

  /// Compatibility entry point for existing callers that only know about the
  /// original RAW background.
  func merge(_ inspection: RawInspection?) {
    guard let inspection else { return }
    mergeInspection(inspection, for: .rawBackground)
  }

  func mergeInspection(_ inspection: RawInspection) {
    mergeInspection(inspection, for: .rawBackground)
  }

  func mergeInspection(_ inspection: RawInspection, for layerID: ProjectLayerID) {
    var updated = recipe
    guard let layer = updated.layerStack.layer(id: layerID), var raw = layer.developedRawLayer else {
      return
    }
    raw.rawDevelopment.decoderVersion = inspection.selectedDecoderVersion
    raw.rawDevelopment.supportedDecoderVersions = inspection.supportedDecoderVersions
    raw.rawDevelopment.capabilities = inspection.capabilities
    if raw.rawDevelopment.capturedDefaults == nil {
      raw.rawDevelopment.capturedDefaults = inspection.defaults
    }
    if raw.rawDevelopment.parameters == nil {
      raw.rawDevelopment.parameters = inspection.defaults
    }
    if raw.needsInitialPlacement == true {
      let size = inspection.orientedSize
      raw.frame = LayerFrame.placing(
        naturalWidth: max(Int(size.width.rounded()), 1),
        naturalHeight: max(Int(size.height.rounded()), 1),
        in: updated.layerStack.canvas
      )
      raw.needsInitialPlacement = nil
    }
    updated.layerStack.updateLayer(id: layerID) { $0.content = .developedRaw(raw) }

    // The document-scoped fields remain the compatibility record for the
    // original background RAW. A placed RAW must not overwrite them, nor set
    // the canvas size from its own source dimensions.
    guard layerID == .rawBackground else {
      updateRecipeInPlace(updated)
      return
    }
    updated.rawDevelopment = raw.rawDevelopment
    updated.upright = raw.upright
    // A RAW-backed document mirrors its developed, oriented, cropped extent.
    // Sizing the canvas independently of the image needs per-layer transforms,
    // which layers do not have yet, so the canvas records that extent instead of
    // competing with it.
    // The extent that was actually rendered, which is the opened frame while
    // the crop tool is holding the document's crop aside. Committing or
    // cancelling the tool renders again and puts the real extent back.
    let renderedCrop: CropRecipe
    if let cropDraft, cropDraft.target == .canvas, cropDraft.revealsFullTarget {
      renderedCrop = cropDraft.recipe.openedToFullFrame
    } else {
      renderedCrop = updated.crop
    }
    updated.layerStack.canvas = inspection.canvasRecipe(crop: renderedCrop)
    updateRecipeInPlace(updated)
  }

  func clearRenderedFrame() {
    renderedFrame = nil
    histogram = nil
    sampledPalette = []
    imageContentTags = []
    visionContentTags = []
    generatedContentTags = []
    isAnalyzingRenderedFrame = false
  }

  func present(_ frame: RenderedFrame) {
    renderedFrame = frame
    histogram = nil
    if !frame.isProxy { sampledPalette = [] }
    imageContentTags = []
    visionContentTags = []
    generatedContentTags = []
    isAnalyzingRenderedFrame = true
    if let preview = brushPreview, frame.contentRevision > preview.baseContentRevision {
      brushPreview = nil
    }
    // Every presented frame is the full-resolution render, so arriving at one is
    // the end of the work rather than a step towards a sharper one.
    renderStatus = .ready(
      "\(frame.width) × \(frame.height) • \(frame.elapsedSeconds.formatted(.number.precision(.fractionLength(2)))) s"
    )
  }

  /// Publishes analysis only when the canvas is still showing its source
  /// frame. This is the asynchronous counterpart of presenting both together.
  func present(_ analysis: RenderedFrameAnalysis) {
    guard matchesPresentedFrame(
      documentID: analysis.documentID,
      revision: analysis.revision,
      contentRevision: analysis.contentRevision
    ) else { return }
    histogram = analysis.histogram
    if !analysis.isProxy {
      sampledPalette = analysis.palette
      visionContentTags = analysis.contentTags
      imageContentTags = mergedImageContentTags(
        generated: generatedContentTags, vision: visionContentTags)
    }
    isAnalyzingRenderedFrame = false
  }

  /// Keep both sources for the same frame regardless of which finishes first.
  /// Results from an older revision are rejected by the shared frame check.
  func presentGeneratedContentTags(_ tags: [ImageContentTag], for frame: RenderedFrame) {
    guard matchesPresentedFrame(
      documentID: frame.documentID,
      revision: frame.revision,
      contentRevision: frame.contentRevision
    ) else { return }
    generatedContentTags = tags
    imageContentTags = mergedImageContentTags(
      generated: generatedContentTags, vision: visionContentTags)
  }

  func setComfyUISelectionPreview(_ selection: MaskRecipe?) {
    comfyUISelectionPreview = selection
    selectionDraft = selection
  }

  func finishAnalysis(
    documentID: UUID,
    revision: UInt64,
    contentRevision: UInt64
  ) {
    guard matchesPresentedFrame(
      documentID: documentID,
      revision: revision,
      contentRevision: contentRevision
    ) else { return }
    isAnalyzingRenderedFrame = false
  }

  private func matchesPresentedFrame(
    documentID: UUID,
    revision: UInt64,
    contentRevision: UInt64
  ) -> Bool {
    guard let renderedFrame else { return false }
    return renderedFrame.documentID == documentID
      && renderedFrame.revision == revision
      && renderedFrame.contentRevision == contentRevision
  }

  func setRenderStatus(_ status: RenderStatus) {
    renderStatus = status
  }

  func setActiveTool(_ tool: EditorTool) {
    activeTool = tool
    // A sample is armed over a tool, so changing the tool underneath it
    // withdraws the request rather than leaving it pointing at a gesture the
    // user has moved on from.
    pendingSample = nil
  }

  /// Arms a request for one pixel, replacing any request already standing.
  func armSample(_ request: PixelSampleRequest) {
    pendingSample = request
  }

  /// Records what the pixel under the pointer would produce, for the readout.
  ///
  /// Dropped when no request stands, so a preview that arrives after the click
  /// that fulfilled it cannot re-arm anything.
  func setSamplePreview(_ preview: PixelSamplePreview?) {
    guard var pending = pendingSample, pending.preview != preview else { return }
    pending.preview = preview
    pendingSample = pending
  }

  func clearPendingSample() {
    pendingSample = nil
  }

  func setVectorToolStyle(_ style: VectorToolStyle) {
    setForegroundColor(LinearRGBAColor(style.strokeColor))
    setBackgroundColor(LinearRGBAColor(style.fillColor))
    // Keep the exact Display P3 values the color well supplied. Synchronizing
    // the other tools crosses color spaces, but the originating tool need not
    // pay that round-trip precision cost.
    vectorToolStyle = style
  }

  /// The gradient tool's two ends are the window's shared foreground and
  /// background, so this takes everything in the state except its colors. The
  /// color controls are the only writers of those.
  func setGradientTool(_ state: GradientToolState) {
    var next = state
    next.startColor = colorTool.foreground
    next.endColor = colorTool.background
    gradientTool = next
  }

  /// As with the gradient tool, the color a flood fill lays down is the shared
  /// foreground rather than a fourth color of its own.
  func setFillTool(_ state: FillToolState) {
    var next = state
    next.color = colorTool.foreground
    next.tolerance = next.tolerance.isFinite ? min(max(next.tolerance, 0), 1) : 0.1
    fillTool = next
  }

  func setHealTool(_ state: HealToolState) {
    var next = state
    next.settings = next.settings.validated
    next.solverIterations = min(
      max(next.solverIterations, HealLimits.minimumSolverIterations),
      HealLimits.maximumSolverIterations)
    healTool = next
  }

  /// Anchors the source region, in canvas-normalized coordinates.
  ///
  /// Setting an anchor also switches the tool into source-point mode: taking
  /// the trouble to Option-click says which mode was wanted, and leaving it in
  /// Spot would silently ignore the click.
  func setHealSourceAnchor(_ anchor: VectorPoint?) {
    healTool.sourceAnchor = anchor
    if anchor != nil { healTool.mode = .sourcePoint }
  }

  func setShapeTool(_ state: ShapeToolState) {
    var next = state
    next.cornerRadius = next.cornerRadius.isFinite ? min(max(next.cornerRadius, 0), 2_048) : 0
    next.polygonSides = min(max(next.polygonSides, PaintOperationLimits.minimumPolygonSides), PaintOperationLimits.maximumPolygonSides)
    shapeTool = next
  }

  func setTextToolStyle(_ style: TextToolStyle) {
    setForegroundColor(LinearRGBAColor(style.color))
    textToolStyle = style
  }

  func setBrushSettings(_ settings: BrushSettings) {
    let validated = settings.validated
    switch activeTool {
    case .eraser:
      eraserSettings = validated
      eraserOverrides[eraserPresetID] = validated
    // The Healing Brush has no preset library, so there is no override entry
    // to keep and nothing to reset back to.
    case .heal:
      healTool.settings = validated
    case .selectionBrush:
      var next = selectionBrushTool
      next.brushSettings = validated
      setSelectionBrushTool(next)
    default:
      brushSettings = validated
      brushOverrides[brushPresetID] = validated
    }
  }

  /// Bracket keys resize the selected brush or eraser by a proportional step,
  /// so one press remains useful at both small and large canvas sizes.
  func adjustActiveBrushSize(increasing: Bool) {
    guard activeTool == .brush || activeTool == .eraser || activeTool == .selectionBrush
    else { return }
    var settings = activeBrushSettings
    let scale = increasing ? 1.1 : 1 / 1.1
    let size = min(
      max(settings.size * scale, BrushLimits.minimumSize), BrushLimits.maximumSize)
    guard size != settings.size else { return }
    settings.size = size
    setBrushSettings(settings)
  }

  /// Whether the active preset is showing edited values rather than its
  /// shipped defaults.
  var activeBrushIsModified: Bool {
    activeBrushSettings != BrushCatalog.preset(activeBrushPresetID).settings
  }

  var activeBrushSettings: BrushSettings {
    switch activeTool {
    case .eraser: eraserSettings
    case .heal: healTool.settings
    case .selectionBrush: selectionBrushTool.brushSettings
    default: brushSettings
    }
  }

  var activeBrushDefinition: BrushDefinition {
    switch activeTool {
    case .eraser: eraserDefinition
    case .heal: BrushDefinition.healCoverage
    case .selectionBrush: BrushCatalog.hardRound.definition
    default: brushDefinition
    }
  }

  var activeBrushPresetID: BrushPresetID {
    activeTool == .eraser ? eraserPresetID : brushPresetID
  }

  func selectBrushPreset(_ id: BrushPresetID) {
    let preset = BrushCatalog.preset(id)
    if activeTool == .eraser {
      eraserPresetID = id
      eraserDefinition = preset.definition
      eraserSettings = eraserOverrides[id] ?? preset.settings
    } else {
      brushPresetID = id
      brushDefinition = preset.definition
      brushSettings = brushOverrides[id] ?? preset.settings
    }
  }

  /// Restores the selected preset's shipped defaults. The paint color is tool
  /// state of its own and is deliberately left alone.
  func resetActiveBrush() {
    let id = activeBrushPresetID
    if activeTool == .eraser {
      eraserOverrides.removeValue(forKey: id)
    } else {
      brushOverrides.removeValue(forKey: id)
    }
    selectBrushPreset(id)
  }

  func setBrushPresetPreview(_ image: CGImage, for id: BrushPresetID) {
    brushPresetPreviews[id] = image
  }

  func setBrushColor(_ color: LinearRGBAColor) {
    setForegroundColor(color)
  }

  /// Sets the one color the brush paints with, the text tool types in, the
  /// flood fill lays down, a gradient starts from, and a vector object is
  /// stroked with. Every control that shows "foreground" shows this.
  ///
  /// It sets colors and nothing else: whether a vector object is stroked at all
  /// is `hasStroke`, which only the stroke editor writes.
  func setForegroundColor(_ color: LinearRGBAColor, remembering: Bool = true) {
    guard colorTool.foreground != color else { return }
    colorTool.foreground = color
    let vectorColor = VectorColor(color)
    vectorToolStyle.strokeColor = vectorColor
    textToolStyle.color = vectorColor
    fillTool.color = color
    gradientTool.startColor = color
    if remembering { rememberColor(color) }
  }

  /// The other half of the shared pair: a vector object's fill and the far end
  /// of a gradient.
  ///
  /// A gradient fill default is left standing rather than cleared. The fill
  /// type control says whether the next object is solid or gradient, and it is
  /// the only thing that changes that answer — picking a color here while a
  /// gradient is showing sets the solid color waiting behind it.
  func setBackgroundColor(_ color: LinearRGBAColor, remembering: Bool = true) {
    guard colorTool.background != color else { return }
    colorTool.background = color
    vectorToolStyle.fillColor = VectorColor(color)
    gradientTool.endColor = color
    if remembering { rememberColor(color) }
  }

  func swapForegroundAndBackgroundColors() {
    let foreground = colorTool.foreground
    setForegroundColor(colorTool.background, remembering: false)
    setBackgroundColor(foreground, remembering: false)
  }

  func resetForegroundAndBackgroundColors() {
    setForegroundColor(.black, remembering: false)
    setBackgroundColor(.white, remembering: false)
  }

  func setColorSampleSource(_ source: ColorSampleSource) {
    colorTool.sampleSource = source
    if pendingSample?.purpose == .foregroundColor {
      pendingSample?.source = source
      pendingSample?.preview = nil
    }
  }

  func setColorSampleSize(_ size: ColorSampleSize) {
    colorTool.sampleSize = size
    if pendingSample?.purpose == .foregroundColor {
      pendingSample?.sampleSize = size
      pendingSample?.preview = nil
    }
  }

  func togglePinnedColor(_ color: LinearRGBAColor) {
    if let index = colorTool.pinnedColors.firstIndex(of: color) {
      colorTool.pinnedColors.remove(at: index)
    } else {
      colorTool.pinnedColors.removeAll { $0 == color }
      colorTool.pinnedColors.insert(color, at: 0)
      colorTool.pinnedColors = Array(colorTool.pinnedColors.prefix(12))
    }
  }

  private func rememberColor(_ color: LinearRGBAColor) {
    colorTool.recentColors.removeAll { $0 == color }
    colorTool.recentColors.insert(color, at: 0)
    colorTool.recentColors = Array(colorTool.recentColors.prefix(12))
  }

  func setBrushPreview(_ preview: BrushPreview?) {
    brushPreview = preview
  }

  public func setPaintTarget(_ target: PaintTarget?) {
    guard paintTarget != target else { return }
    paintTarget = target
  }

  func setClipping(_ indicators: ClippingIndicators) {
    clipping = indicators
  }

  func setDifferencePreviewLayerID(_ layerID: ProjectLayerID?) {
    differencePreviewLayerID = layerID
  }

  func setShowingBefore(_ showing: Bool) {
    isShowingBefore = showing
  }

  func setExportJobs(_ jobs: [ExportJob]) {
    exportJobs = jobs
  }

  public func setInpaintingTool(_ state: InpaintingToolState) {
    let previous = inpaintingTool
    let next = state.clamped
    inpaintingTool = next
    if previous.outputSize != next.outputSize {
      setComfyUIRole(.width, value: .signedInteger(Int64(next.outputSize.width)))
      setComfyUIRole(.height, value: .signedInteger(Int64(next.outputSize.height)))
    }
    if previous.negativePrompt != next.negativePrompt {
      setComfyUIRole(.negativePrompt, value: .string(next.negativePrompt))
    }
    if previous.steps != next.steps {
      setComfyUIRole(.steps, value: .signedInteger(Int64(next.steps)))
    }
    if previous.guidance != next.guidance {
      setComfyUIRole(.guidance, value: .decimal(next.guidance))
    }
    if previous.seed != next.seed {
      setComfyUIRole(.seed, value: .unsignedInteger(next.seed))
    }
    if previous.strength != next.strength {
      setComfyUIRole(.strength, value: .decimal(next.strength))
    }
  }

  func setGenerationJobs(_ jobs: [GenerationJob]) {
    generationJobs = jobs
  }

  func appendComfyUIDebugEvent(_ event: ComfyUIDebugEvent) {
    let maximumMessageCharacters = 32_000
    var event = event
    if event.message.count > maximumMessageCharacters {
      event.message = String(event.message.prefix(maximumMessageCharacters))
        + "\n…event truncated by Pixeltje"
    }
    comfyUIDebugEvents.append(event)

    let maximumEvents = 500
    let maximumCharacters = 256_000
    var characterCount = comfyUIDebugEvents.reduce(0) { $0 + $1.message.count }
    while comfyUIDebugEvents.count > maximumEvents || characterCount > maximumCharacters {
      guard !comfyUIDebugEvents.isEmpty else { break }
      characterCount -= comfyUIDebugEvents.removeFirst().message.count
    }
  }

  func clearComfyUIDebugEvents() {
    comfyUIDebugEvents = []
    comfyUIDebugImages = []
  }

  func appendComfyUIDebugImage(_ image: ComfyUIDebugImage) {
    comfyUIDebugImages.append(image)

    let maximumImages = 12
    let maximumBytes = 48 * 1_024 * 1_024
    var byteCount = comfyUIDebugImages.reduce(0) { $0 + $1.imageData.count }
    while comfyUIDebugImages.count > maximumImages || byteCount > maximumBytes {
      guard !comfyUIDebugImages.isEmpty else { break }
      byteCount -= comfyUIDebugImages.removeFirst().imageData.count
    }
  }

  func setComfyUIDebugDiskLoggingState(_ state: ComfyUIDebugDiskLoggingState) {
    comfyUIDebugDiskLoggingState = state
  }

  func setComfyUIConnection(_ state: ComfyUIConnectionState) {
    comfyUIConnection = state
  }

  func setComfyCloudAPIKeyAvailable(_ available: Bool) {
    hasComfyCloudAPIKey = available
    if !available { setComfyUIExecutionTarget(.local) }
  }

  func setComfyUIExecutionTarget(_ target: ComfyUIExecutionTarget) {
    guard target == .local || hasComfyCloudAPIKey,
      target != comfyUIExecutionTarget
    else { return }
    pendingComfyUIHistoryRestore = nil
    comfyUIHistoryRestoreNotice = nil
    comfyUIExecutionTarget = target
    comfyUIParameterValues = comfyUIWorkflowDrafts[
      comfyUIWorkflowDraftKey(for: selectedComfyUIWorkflowID)] ?? [:]
    comfyUIWorkflowFormState = .loading
  }

  private func comfyUIWorkflowDraftKey(for templateID: String) -> String {
    "\(comfyUIExecutionTarget.rawValue):\(templateID)"
  }

  func selectComfyUIWorkflow(_ id: String, expectedMode: GenerationMode? = nil) {
    if let template = ComfyUIWorkflowCatalog.templates.first(where: { $0.id == id }) {
      selectedComfyUIWorkflowMode = template.mode
      unresolvedComfyUIWorkflowMode = nil
    } else {
      guard let expectedMode,
        !ComfyUIWorkflowLibrary.shared.isLoaded,
        id.hasPrefix("user-"),
        UUID(uuidString: String(id.dropFirst("user-".count))) != nil
      else { return }
      selectedComfyUIWorkflowMode = expectedMode
      unresolvedComfyUIWorkflowMode = expectedMode
    }
    guard selectedComfyUIWorkflowID != id else { return }
    pendingComfyUIHistoryRestore = nil
    comfyUIHistoryRestoreNotice = nil
    selectedComfyUIWorkflowID = id
    comfyUIParameterValues = comfyUIWorkflowDrafts[comfyUIWorkflowDraftKey(for: id)] ?? [:]
    comfyUIWorkflowFormState = .loading
  }

  func setComfyUIWorkflowFormLoading() {
    comfyUIWorkflowFormState = .loading
  }

  func setComfyUIWorkflowFormFailure(_ message: String) {
    comfyUIWorkflowFormState = .failed(message)
  }

  func setComfyUIWorkflowForm(_ form: ComfyUIWorkflowForm) {
    var values = form.templateValues
    let isRestoringHistory = pendingComfyUIHistoryRestore?.templateID == form.templateID
    if !isRestoringHistory,
      let existing = comfyUIWorkflowDrafts[comfyUIWorkflowDraftKey(for: form.templateID)]
    {
      for (address, value) in existing {
        guard let definition = form.parameter(at: address),
          let normalized = definition.normalized(value), !definition.isConnected
        else { continue }
        values[address] = normalized
      }
    } else if form.templateID == ComfyUIWorkflowCatalog.defaultTemplateID {
      values = applyingLegacyGenerationSettings(to: values, templateID: form.templateID)
    }
    comfyUIParameterValues = values
    comfyUIWorkflowDrafts[comfyUIWorkflowDraftKey(for: form.templateID)] = values
    comfyUIWorkflowFormState = .ready(form)
    synchronizeLegacyGenerationSettings(from: values, templateID: form.templateID)
    applyPendingComfyUIHistoryRestoreIfPossible()
  }

  func restoreComfyUIHistoryDraft(
    _ entry: ComfyUIHistoryEntry,
    executionTarget: ComfyUIExecutionTarget,
    warning: String? = nil
  ) {
    if executionTarget != comfyUIExecutionTarget {
      setComfyUIExecutionTarget(executionTarget)
    }
    if entry.templateID != selectedComfyUIWorkflowID {
      selectComfyUIWorkflow(entry.templateID)
    }

    var settings = entry.generationSettings.clamped
    // History restoration is reproducible: Execute reuses the seed recorded for
    // the run instead of immediately replacing it with another random value.
    settings.randomizeSeed = false
    setInpaintingTool(settings)
    pendingComfyUIHistoryRestore = PendingComfyUIHistoryRestore(
      templateID: entry.templateID,
      templateRevision: entry.templateRevision,
      parameters: entry.modifiedParameters,
      warning: warning)
    comfyUIHistoryRestoreNotice = "Restoring history…"
    applyPendingComfyUIHistoryRestoreIfPossible()
  }

  private func applyPendingComfyUIHistoryRestoreIfPossible() {
    guard let pending = pendingComfyUIHistoryRestore,
      pending.templateID == selectedComfyUIWorkflowID,
      let form = comfyUIWorkflowFormState.form,
      form.templateID == pending.templateID
    else { return }

    var values = form.templateValues
    var restoredCount = 0
    var skippedCount = 0
    for record in pending.parameters {
      guard let definition = form.parameter(at: record.address),
        !definition.isConnected,
        let normalized = definition.normalized(record.value)
      else {
        skippedCount += 1
        continue
      }
      values[record.address] = normalized
      restoredCount += 1
    }

    comfyUIParameterValues = values
    comfyUIWorkflowDrafts[comfyUIWorkflowDraftKey(for: pending.templateID)] = values
    synchronizeLegacyGenerationSettings(from: values, templateID: pending.templateID)
    pendingComfyUIHistoryRestore = nil

    var details: [String] = []
    if pending.templateRevision != form.templateRevision {
      details.append("the bundled workflow has changed")
    }
    if skippedCount > 0 {
      details.append("\(skippedCount) unavailable setting\(skippedCount == 1 ? " was" : "s were") skipped")
    }
    if let warning = pending.warning { details.append(warning) }

    let countLabel = "\(restoredCount) modified node setting\(restoredCount == 1 ? "" : "s")"
    comfyUIHistoryRestoreNotice = details.isEmpty
      ? "Restored this prompt and \(countLabel)."
      : "Restored this prompt and \(countLabel); \(details.joined(separator: "; "))."
  }

  func setComfyUIParameter(
    _ address: ComfyUIParameterAddress,
    value proposed: ComfyUIParameterValue
  ) {
    guard let definition = comfyUIWorkflowFormState.form?.parameter(at: address),
      !definition.isConnected,
      let value = definition.normalized(proposed)
    else { return }
    comfyUIParameterValues[address] = value
    comfyUIWorkflowDrafts[comfyUIWorkflowDraftKey(for: selectedComfyUIWorkflowID)] = comfyUIParameterValues
    synchronizeLegacyGenerationSettings(
      from: comfyUIParameterValues, templateID: selectedComfyUIWorkflowID)
  }

  func resetComfyUIParameter(_ address: ComfyUIParameterAddress) {
    guard let value = comfyUIWorkflowFormState.form?.parameter(at: address)?.templateValue else {
      return
    }
    setComfyUIParameter(address, value: value)
  }

  func resetComfyUINode(_ nodeID: String) {
    guard let node = comfyUIWorkflowFormState.form?.nodes.first(where: { $0.id == nodeID })
    else { return }
    for parameter in node.parameters where !parameter.isConnected {
      if let value = parameter.templateValue {
        comfyUIParameterValues[parameter.address] = value
      }
    }
    comfyUIWorkflowDrafts[comfyUIWorkflowDraftKey(for: selectedComfyUIWorkflowID)] = comfyUIParameterValues
    synchronizeLegacyGenerationSettings(
      from: comfyUIParameterValues, templateID: selectedComfyUIWorkflowID)
  }

  private func setComfyUIRole(
    _ role: ComfyUIWorkflowRole,
    value: ComfyUIParameterValue
  ) {
    guard let address = ComfyUIWorkflowCatalog.address(
      for: role, templateID: selectedComfyUIWorkflowID)
    else { return }
    comfyUIParameterValues[address] = value
    comfyUIWorkflowDrafts[comfyUIWorkflowDraftKey(for: selectedComfyUIWorkflowID)] = comfyUIParameterValues
  }

  private func applyingLegacyGenerationSettings(
    to values: [ComfyUIParameterAddress: ComfyUIParameterValue],
    templateID: String
  ) -> [ComfyUIParameterAddress: ComfyUIParameterValue] {
    var result = values
    func set(_ role: ComfyUIWorkflowRole, _ value: ComfyUIParameterValue) {
      if let address = ComfyUIWorkflowCatalog.address(for: role, templateID: templateID),
        result[address] != nil
      {
        result[address] = value
      }
    }
    set(.negativePrompt, .string(inpaintingTool.negativePrompt))
    set(.width, .signedInteger(Int64(inpaintingTool.outputSize.width)))
    set(.height, .signedInteger(Int64(inpaintingTool.outputSize.height)))
    set(.steps, .signedInteger(Int64(inpaintingTool.steps)))
    set(.guidance, .decimal(inpaintingTool.guidance))
    set(.seed, .unsignedInteger(inpaintingTool.seed))
    set(.strength, .decimal(inpaintingTool.strength))
    return result
  }

  private func synchronizeLegacyGenerationSettings(
    from values: [ComfyUIParameterAddress: ComfyUIParameterValue],
    templateID: String
  ) {
    func value(_ role: ComfyUIWorkflowRole) -> ComfyUIParameterValue? {
      ComfyUIWorkflowCatalog.address(for: role, templateID: templateID).flatMap { values[$0] }
    }
    var settings = inpaintingTool
    if let width = value(.width)?.signedIntegerValue,
      let height = value(.height)?.signedIntegerValue,
      width > 0, height > 0,
      width <= Int64(Int.max), height <= Int64(Int.max)
    {
      settings.outputSize = CanvasRecipe(width: Int(width), height: Int(height))
    }
    if let negativePrompt = value(.negativePrompt)?.stringValue {
      settings.negativePrompt = negativePrompt
    }
    if let steps = value(.steps)?.signedIntegerValue,
      steps > 0, steps <= Int64(Int.max)
    {
      settings.steps = Int(steps)
    }
    if let guidance = value(.guidance)?.doubleValue {
      settings.guidance = guidance
    }
    if let seed = value(.seed)?.unsignedIntegerValue {
      if settings.seed != seed { settings.randomizeSeed = false }
      settings.seed = seed
    }
    if let strength = value(.strength)?.doubleValue {
      settings.strength = strength
    }
    inpaintingTool = settings.clamped
  }

  func setGenerationPreview(_ frame: RenderedFrame?) {
    generationPreview = frame
  }
  /// Replaces the masks tool's settings.
  ///
  /// Tool state is not undoable, so this bypasses the document entirely. The
  /// active mask is dropped when it no longer exists, so deleting a mask
  /// cannot leave a gesture aimed at nothing.
  public func setMaskTool(_ state: MaskToolState) {
    var next = state
    if let layerID = next.activeLayerID, let maskID = next.activeMaskID,
      recipe.layerStack.mask(maskID, on: layerID) == nil
    {
      next.activeMaskID = nil
    }
    guard next != maskTool else { return }
    maskTool = next
  }

  public func setSelectionTool(_ state: SelectionToolState) {
    // The panel edits a copy of the struct field by field and sends it back, so
    // the initializer's clamps are bypassed on that path. Re-clamp here, the
    // way `setShapeTool` does.
    var next = state
    next.feather = SelectionToolState.clamped(next.feather, upTo: 250)
    next.cornerRadius = SelectionToolState.clamped(next.cornerRadius, upTo: 2_048)
    guard next != selectionTool else { return }
    selectionTool = next
  }

  public func setMagnetSelectionTool(_ state: MagnetSelectionToolState) {
    var next = state
    next.tolerance = MagnetSelectionToolState.unit(next.tolerance, fallback: 0.1)
    next.smoothness = MagnetSelectionToolState.unit(next.smoothness, fallback: 0.5)
    next.feather = SelectionToolState.clamped(next.feather, upTo: 250)
    guard next != magnetSelectionTool else { return }
    magnetSelectionTool = next
  }

  public func setSelectionBrushTool(_ state: SelectionBrushToolState) {
    var next = state
    next.brushSettings = next.brushSettings.validated
    next.tolerance = MagnetSelectionToolState.unit(next.tolerance, fallback: 0.12)
    next.edgeSensitivity = MagnetSelectionToolState.unit(
      next.edgeSensitivity, fallback: 0.55)
    next.smoothness = MagnetSelectionToolState.unit(next.smoothness, fallback: 0.35)
    next.feather = SelectionToolState.clamped(next.feather, upTo: 250)
    guard next != selectionBrushTool else { return }
    selectionBrushTool = next
  }

  func setSelectionDraft(_ draft: MaskRecipe?) {
    guard selectionDraft != draft else { return }
    selectionDraft = draft
  }

  /// Points the masks tool at one mask on one layer.
  public func activateMask(_ maskID: MaskID?, on layerID: ProjectLayerID?) {
    var next = maskTool
    next.activeLayerID = layerID ?? recipe.layerStack.activeLayerID
    next.activeMaskID = maskID
    setMaskTool(next)
  }
}

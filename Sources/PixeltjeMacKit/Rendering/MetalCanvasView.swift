import AppKit
import CoreImage
import IOSurface
import Metal
import MetalKit
import PixeltjeMacDomain
import QuartzCore

/// Transient canvas geometry for Shape and Gradient drags. Keeping the pointer
/// update independent of AppKit events makes the live-preview contract directly
/// testable without driving the application UI.
struct CreativeDragState: Equatable {
  var start: VectorPoint
  var end: VectorPoint
  var editingLayerID: ProjectLayerID?
  /// Nil creates or resizes the whole gesture. A value edits one gradient
  /// handle without moving the other.
  var movingStartHandle: Bool?

  mutating func update(to point: VectorPoint) {
    if movingStartHandle == true {
      start = point
    } else {
      end = point
    }
  }
}

@MainActor
final class MetalCanvasView: MTKView, MTKViewDelegate {
  private struct PresentedBrushTile {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var texture: any MTLTexture
  }

  private enum HandleSide: Equatable {
    case incoming
    case outgoing
  }

  private enum Selection: Equatable {
    case anchor(pathID: UUID, anchorID: UUID)
    case handle(pathID: UUID, anchorID: UUID, side: HandleSide)

    var pathID: UUID {
      switch self {
      case .anchor(let pathID, _), .handle(let pathID, _, _): pathID
      }
    }

    var anchorID: UUID {
      switch self {
      case .anchor(_, let anchorID), .handle(_, let anchorID, _): anchorID
      }
    }
  }

  private enum HitTarget: Equatable {
    case close(pathID: UUID, anchorID: UUID)
    case anchor(pathID: UUID, anchorID: UUID)
    case handle(pathID: UUID, anchorID: UUID, side: HandleSide)
    case endpoint(pathID: UUID, anchorID: UUID, isFirst: Bool)
    case segment(pathID: UUID, startIndex: Int, t: Double)
  }

  private struct ProvisionalPlacement {
    var rawDownDocument: VectorPoint
    var anchor: VectorAnchor
    var mouseDownInView: CGPoint
    var lastPointerInView: CGPoint
    var crossedDragThreshold = false
    var frozenIncomingHandle: VectorPoint?
  }

  private struct DirectEdit {
    var selection: Selection
    var startDocumentPoint: VectorPoint
    var originalStack: LayerStack
  }

  /// Selected vector objects being moved by a drag.
  ///
  /// The layer as it stood when the press landed is kept, so every pointer move
  /// re-derives the whole translation from the original geometry instead of
  /// accumulating rounding, and one gesture collapses into one undo step.
  private struct VectorObjectDrag {
    var layerID: ProjectLayerID
    var objectIDs: Set<UUID>
    var originalLayer: VectorLayer
    var startDocument: VectorPoint
    var startPointerInView: CGPoint
    var didBeginGesture = false
  }

  /// What a cached gradient tile was rendered for. The path carries its own
  /// fill, so any recipe change makes a new key rather than reusing a stale
  /// image.
  private struct GradientTileKey: Hashable {
    var object: VectorObject
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    /// The backing scale, in hundredths, so the key stays hashable.
    var scale: Int
  }

  private struct CachedGradientTile {
    var image: CGImage
    var byteCost: Int
    var lastAccess: UInt64
  }

  /// Which part of a gradient a drag is moving.
  private enum GradientHandle: Equatable {
    /// Linear: where the ramp begins. Radial: the center.
    case start
    /// Linear: where the ramp ends. Radial: the primary radius, and with it the
    /// ellipse's rotation.
    case end
    /// Radial: where the first stop sits, when it is offset from the center.
    case focal
  }

  /// A gradient handle being dragged on the canvas.
  private struct GradientHandleDrag {
    var layerID: ProjectLayerID
    var objectID: UUID
    var handle: GradientHandle
    var originalLayer: VectorLayer
    var didBeginGesture = false
  }

  /// A rubber band selecting vector objects. Nothing here reaches the document:
  /// object selection is tool state.
  private struct VectorObjectMarquee {
    var start: VectorPoint
    var current: VectorPoint
    /// What was selected before the band started, for a Shift-drag that adds.
    var base: Set<UUID>
    /// The complete selection before the press, restored when the gesture is
    /// cancelled rather than leaving a half-finished marquee selection behind.
    var selectionAtStart: Set<UUID>
    var isAdditive: Bool
  }

  /// A layer being dragged across the canvas by the Move tool.
  private struct LayerDrag {
    var layerID: ProjectLayerID
    var startPointerInView: CGPoint
    /// How far the layer has already been moved, in canvas pixels.
    var appliedOffset: CGPoint
  }

  private struct TransformDrag {
    var targetID: ProjectLayerID
    var startPointerInView: CGPoint
    var startTransform: LayerTransform
  }

  /// A guide being dragged: pulled out of a ruler, or moved on the canvas.
  private struct GuideDrag {
    var guide: CanvasGuide
    /// A guide dragged out of a ruler is not in the recipe until the pointer
    /// reaches the canvas, so a click on the ruler adds nothing.
    var isNew: Bool
    var hasBeenAdded: Bool
  }

  /// A crop rectangle being dragged by the Crop tool.
  private struct CropDrag {
    enum Mode {
      case resize(CropHandle)
      case move
      case create(startX: Double, startY: Double)
    }

    var mode: Mode
    var startPointerInView: CGPoint
    var startCrop: CropRecipe
  }
  /// A mask component being placed by a drag.
  ///
  /// The mask as it stood when the drag began is kept, so every pointer move
  /// rewrites the same component instead of piling up new ones. The whole drag
  /// is bracketed by one gesture, so it collapses into a single undo step.
  private struct MaskDrag {
    var layerID: ProjectLayerID
    var kind: MaskGeneratorKind
    /// The mask before the component was attached. Nil means this gesture
    /// created the mask and cancellation must remove it again.
    var maskBeforeGesture: MaskRecipe?
    var maskAtGestureStart: MaskRecipe
    var componentID: MaskComponentID
    var startDocument: VectorPoint
    /// Freehand only: every point captured so far, the first included.
    var points: [VectorPoint] = []
  }

  /// One in-flight selection gesture.
  ///
  /// The drag carries the selection it started from so that abandoning it, or
  /// re-deriving it from a moved pointer, never has to reconstruct what was
  /// there. Nothing here reaches the document until the pointer is released.
  private struct SelectionDrag {
    /// What the document had selected when the press landed, restored on
    /// Escape and combined onto when the mode is not New.
    var selectionAtStart: MaskRecipe?
    /// How this gesture joins `selectionAtStart`, or `nil` to replace it.
    var combine: MaskCombineOperation?
    /// Shift and Option held before the press choose the combine operation.
    /// They are consumed for that purpose so they do not also reshape the
    /// marquee. Modifiers pressed after the drag starts still constrain it.
    var consumedCombineModifiers: NSEvent.ModifierFlags
    var kind: MaskGeneratorKind
    var startDocument: VectorPoint
    /// Freehand only: every point captured so far, the first included.
    var points: [VectorPoint]
  }

  private struct BrushGesture {
    var originInView: CGPoint
  }

  private struct PanGesture {
    var originInView: CGPoint
    var panAtStart: CGPoint
  }

  /// Exactly one pointer gesture may own the canvas at a time.
  ///
  /// Keeping this as one enum, instead of a collection of independent optional
  /// properties, makes impossible combinations unrepresentable and gives every
  /// completion path one state to commit or cancel.
  private enum ActiveCanvasGesture {
    case brush(BrushGesture)
    case creative(CreativeDragState)
    case crop(CropDrag)
    case directEdit(DirectEdit)
    case gradientHandle(GradientHandleDrag)
    case guide(GuideDrag)
    case layer(LayerDrag)
    case mask(MaskDrag)
    case pan(PanGesture)
    case penClick(HitTarget)
    case provisional(ProvisionalPlacement)
    case selection(SelectionDrag)
    case transform(TransformDrag)
    case vectorMarquee(VectorObjectMarquee)
    case vectorObjects(VectorObjectDrag)

    enum Kind {
      case brush, creative, crop, directEdit, gradientHandle, guide, layer, mask, pan
      case penClick, provisional, selection, transform, vectorMarquee, vectorObjects
    }

    var kind: Kind {
      switch self {
      case .brush: .brush
      case .creative: .creative
      case .crop: .crop
      case .directEdit: .directEdit
      case .gradientHandle: .gradientHandle
      case .guide: .guide
      case .layer: .layer
      case .mask: .mask
      case .pan: .pan
      case .penClick: .penClick
      case .provisional: .provisional
      case .selection: .selection
      case .transform: .transform
      case .vectorMarquee: .vectorMarquee
      case .vectorObjects: .vectorObjects
      }
    }
  }

  private let send: (CanvasIntent) -> Void
  private let viewSettings: CanvasViewSettings
  /// Reports where the canvas extent landed so the rulers can follow pan and
  /// zoom. Presentation only: nothing here reaches the document.
  var onViewportChange: ((CanvasViewportInfo) -> Void)?
  private lazy var displayColorSpace: CGColorSpace = {
    CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
  }()
  private lazy var imageContext: CIContext = {
    CIContext(
      mtlDevice: device!,
      options: [
        .workingColorSpace: CGColorSpace(
          name: CGColorSpace.extendedLinearDisplayP3
        ) as Any,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: true,
      ]
    )
  }()
  private lazy var commandQueue = device?.makeCommandQueue()

  private let canvasBorderLayer = CALayer()
  /// The marching ants, as two persistent layers rather than overlay sublayers.
  ///
  /// `rebuildOverlays()` clears `interactionLayer` on nearly every pointer
  /// event, which would restart the dash animation each time and leave it
  /// visibly stuttering. These live beside the canvas border instead: the
  /// animation is installed once and only the path and visibility change.
  private let selectionAntsUnderlayLayer = CAShapeLayer()
  private let selectionAntsLayer = CAShapeLayer()
  private let selectionMeasurementLayer = CATextLayer()
  private let artworkLayer = CALayer()
  private let interactionLayer = CALayer()
  private var frameImage: CIImage?
  private var contentImage: CIImage?
  private var isDifferencePreview = false
  private var frameSize: CGSize = .zero
  private var canonicalImageSize: CGSize = .zero
  private var canvasSize: CGSize = .zero
  private var recipe = ProjectRecipe()
  private var activeTool: EditorTool = .navigate
  private var activeGesture: ActiveCanvasGesture?
  private var hasOpenEditGesture = false
  /// The standing request for a pixel, when one is armed. Not a tool: it sits
  /// over `activeTool` and takes only the cursor and the next click.
  private var pendingSample: PixelSampleRequest?
  private var vectorToolStyle = VectorToolStyle()
  private var shapeTool = ShapeToolState()
  private var textToolStyle = TextToolStyle()
  private var brushSettings = BrushSettings()
  private var healTool = HealToolState()
  private var brushPreview: StrokeSurfaceFrame?
  private var brushPreviewMode: BrushStrokeMode = .paint
  private var brushPreviewIsHealCoverage = false
  private var brushPreviewTarget: PaintTarget?
  private var brushPreviewTiles: [PresentedBrushTile] = []
  private var brushStartTimestamp: TimeInterval = 0
  private var brushSequence: UInt64 = 0
  private var previousMouseCoalescingState: Bool?
  private var clipping = ClippingIndicators()
  private var zoomMultiplier: CGFloat = 1
  private var panInPixels: CGPoint = .zero
  private var activePathID: UUID?
  private var selected: Selection?
  private var vectorEditMode: VectorEditMode = .draw
  private var selectedVectorObjectIDs: Set<UUID> = []
  /// Rendered gradient fills, keyed by the recipe and the on-screen rectangle
  /// that produced them.
  private var gradientTiles: [GradientTileKey: CachedGradientTile] = [:]
  private var gradientTileByteCost = 0
  private var gradientTileAccess: UInt64 = 0
  /// The overlay is disposable display state. Keeping it below a modest fixed
  /// cost prevents a long gradient or stroke drag from retaining one complete
  /// float bitmap for every pointer event.
  private let gradientTileByteLimit = 64 * 1_024 * 1_024
  /// Large on-screen objects are divided before their backing scale is applied,
  /// so one allocation can never silently become a multi-gigabyte bitmap.
  private let gradientTileMaximumPixelEdge = 2_048
  private var hoveredTarget: HitTarget?
  private var transformDraft: TransformDraft?
  private var cropDraft: CropDraft?
  private var hoveredCropHandle: CropHandle?
  private var maskTool = MaskToolState()
  private var selectionTool = SelectionToolState()
  private var magnetSelectionTool = MagnetSelectionToolState()
  private var selectionBrushTool = SelectionBrushToolState()
  /// The document's uncommitted selection while a gesture holds, mirrored here
  /// the way `cropDraft` is: the canvas emits the intent, the document owns the
  /// value, and the canvas draws what comes back.
  private var selectionDraft: MaskRecipe?
  /// Raster selections can contain many contours. Cache their canonical-canvas
  /// path so brush hover, overlay rebuilds, pan and zoom only transform it
  /// instead of retracing the captured mask on every pointer event.
  private var cachedSelectionOutline: (
    selection: MaskRecipe,
    canvasSize: CGSize,
    path: CGPath
  )?
  private var lastMouseInView: CGPoint = .zero
  private var currentModifiers: NSEvent.ModifierFlags = []
  private var isSpacePressed = false
  private var activeSnapTarget: SnapTarget?
  /// The lines the current layer drag landed on, drawn while it holds.
  private var canvasSnap: CanvasSnapResult?
  private var pointerIsInside = false
  private var tracking: NSTrackingArea?
  private var resignKeyObserver: NSObjectProtocol?

  private let snapSettings = PenSnapSettings()
  private let dragThresholdInPoints: CGFloat = 3
  private let anchorHitRadiusInPoints: CGFloat = 10
  private let handleHitRadiusInPoints: CGFloat = 8
  private let segmentHitRadiusInPoints: CGFloat = 6
  private let layerGrabToleranceInPoints: CGFloat = 4
  private let guideGrabToleranceInPoints: CGFloat = 4
  private let cropHandleHitRadiusInPoints: CGFloat = 12
  private let cropHandleLengthInPoints: CGFloat = 22
  private let layerNudgeInCanvasPixels: Double = 1
  private let largeLayerNudgeInCanvasPixels: Double = 10
  private var nudgeDistanceInImagePixels: Double {
    let value = UserDefaults.standard.double(forKey: "PenNudgeDistance")
    return value > 0 ? value : 1
  }
  private var largeNudgeDistanceInImagePixels: Double {
    let value = UserDefaults.standard.double(forKey: "PenLargeNudgeDistance")
    return value > 0 ? value : 10
  }

  var hasActiveGesture: Bool { activeGesture != nil }

  private func setActiveGesture(
    _ gesture: ActiveCanvasGesture?,
    kind: ActiveCanvasGesture.Kind
  ) {
    if let gesture {
      precondition(
        activeGesture == nil || activeGesture?.kind == kind,
        "A canvas gesture cannot replace a different active gesture"
      )
      activeGesture = gesture
    } else if activeGesture?.kind == kind {
      activeGesture = nil
    }
  }

  private var brushGesture: BrushGesture? {
    get { if case .brush(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.brush), kind: .brush) }
  }

  private var creativeDrag: CreativeDragState? {
    get { if case .creative(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.creative), kind: .creative) }
  }

  private var cropDrag: CropDrag? {
    get { if case .crop(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.crop), kind: .crop) }
  }

  private var directEdit: DirectEdit? {
    get { if case .directEdit(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.directEdit), kind: .directEdit) }
  }

  private var gradientHandleDrag: GradientHandleDrag? {
    get { if case .gradientHandle(let value) = activeGesture { value } else { nil } }
    set {
      setActiveGesture(newValue.map(ActiveCanvasGesture.gradientHandle), kind: .gradientHandle)
    }
  }

  private var guideDrag: GuideDrag? {
    get { if case .guide(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.guide), kind: .guide) }
  }

  private var layerDrag: LayerDrag? {
    get { if case .layer(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.layer), kind: .layer) }
  }

  private var maskDrag: MaskDrag? {
    get { if case .mask(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.mask), kind: .mask) }
  }

  private var panGesture: PanGesture? {
    get { if case .pan(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.pan), kind: .pan) }
  }

  private var pendingClickTarget: HitTarget? {
    get { if case .penClick(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.penClick), kind: .penClick) }
  }

  private var provisional: ProvisionalPlacement? {
    get { if case .provisional(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.provisional), kind: .provisional) }
  }

  private var selectionDrag: SelectionDrag? {
    get { if case .selection(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.selection), kind: .selection) }
  }

  private var transformDrag: TransformDrag? {
    get { if case .transform(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.transform), kind: .transform) }
  }

  private var vectorObjectMarquee: VectorObjectMarquee? {
    get { if case .vectorMarquee(let value) = activeGesture { value } else { nil } }
    set {
      setActiveGesture(newValue.map(ActiveCanvasGesture.vectorMarquee), kind: .vectorMarquee)
    }
  }

  private var vectorObjectDrag: VectorObjectDrag? {
    get { if case .vectorObjects(let value) = activeGesture { value } else { nil } }
    set { setActiveGesture(newValue.map(ActiveCanvasGesture.vectorObjects), kind: .vectorObjects) }
  }

  init(viewSettings: CanvasViewSettings, send: @escaping (CanvasIntent) -> Void) {
    self.send = send
    self.viewSettings = viewSettings
    super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
    delegate = self
    framebufferOnly = false
    colorPixelFormat = .rgba16Float
    // Only visible during live resize; matched to the outside checkerboard so a
    // drag does not flash a different dark.
    let clear = CanvasCheckerboard.linear(
      (CanvasCheckerboard.outside.light + CanvasCheckerboard.outside.dark) / 2)
    clearColor = MTLClearColorMake(clear, clear, clear, 1)
    isPaused = true
    enableSetNeedsDisplay = true
    preferredFramesPerSecond = 60
    colorspace = displayColorSpace
    layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.wantsExtendedDynamicRangeContent = true
      metalLayer.colorspace = displayColorSpace
    }
    canvasBorderLayer.zPosition = 5
    canvasBorderLayer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
    canvasBorderLayer.isHidden = true
    canvasBorderLayer.actions = [
      "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(),
    ]
    configureSelectionAnts()
    configureSelectionMeasurement()
    artworkLayer.zPosition = 10
    interactionLayer.zPosition = 20
    layer?.addSublayer(canvasBorderLayer)
    layer?.addSublayer(selectionAntsUnderlayLayer)
    layer?.addSublayer(selectionAntsLayer)
    layer?.addSublayer(selectionMeasurementLayer)
    layer?.addSublayer(artworkLayer)
    layer?.addSublayer(interactionLayer)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Image canvas")
    setAccessibilityHelp(
      "Use Brush or Eraser to paint in canvas pixels, Move to position a layer, or Pen to edit "
        + "vector paths."
    )
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("MetalCanvasView is created programmatically")
  }

  override var acceptsFirstResponder: Bool { true }

  var hasSelectedAnchor: Bool { selected != nil }

  func updateRecipe(_ recipe: ProjectRecipe) {
    self.recipe = recipe
    let canvas = recipe.layerStack.canvas
    let updatedCanvasSize =
      canvas.isResolved ? CGSize(width: canvas.width, height: canvas.height) : .zero
    if updatedCanvasSize != canvasSize {
      canvasSize = updatedCanvasSize
      if frameImage == nil { canonicalImageSize = canvasSize }
      needsDisplay = true
    }
    normalizeTransientState()
    rebuildOverlays()
  }

  /// Turns the clipping overlay on or off. Nothing is re-rendered: the marks are
  /// added in this view's own display pass.
  func setClipping(_ indicators: ClippingIndicators) {
    guard clipping != indicators else { return }
    clipping = indicators
    needsDisplay = true
  }

  /// The crop the tool is dragging, or `nil` when the tool is closed.
  func setCropDraft(_ draft: CropDraft?) {
    guard cropDraft != draft else { return }
    cropDraft = draft
    if draft == nil {
      cropDrag = nil
      hoveredCropHandle = nil
    }
    rebuildOverlays()
  }

  func setTransformDraft(_ draft: TransformDraft?) {
    guard transformDraft != draft else { return }
    transformDraft = draft
    if draft == nil { transformDrag = nil }
    rebuildOverlays()
  }
  func setMaskTool(_ state: MaskToolState) {
    guard maskTool != state else { return }
    maskTool = state
    if activeTool == .masks { rebuildOverlays() }
  }

  func setSelectionTool(_ state: SelectionToolState) {
    guard selectionTool != state else { return }
    selectionTool = state
  }

  func setMagnetSelectionTool(_ state: MagnetSelectionToolState) {
    guard magnetSelectionTool != state else { return }
    magnetSelectionTool = state
  }

  func setSelectionBrushTool(_ state: SelectionBrushToolState) {
    guard selectionBrushTool != state else { return }
    selectionBrushTool = state
    if activeTool == .selectionBrush {
      setBrushSettings(state.brushSettings)
    }
  }

  /// The selection a gesture is drawing, or `nil` when none is in flight.
  func setSelectionDraft(_ draft: MaskRecipe?) {
    guard selectionDraft != draft else { return }
    selectionDraft = draft
    refreshSelectionAnts()
  }

  /// Arms or withdraws the pixel request the canvas answers.
  ///
  /// Only the cursor changes: the tool underneath keeps its overlays, its
  /// drags and its settings, so arming the picker in the middle of a brush
  /// session costs nothing.
  func setPendingSample(_ request: PixelSampleRequest?) {
    let wasArmed = pendingSample != nil
    let changed = pendingSample != request
    pendingSample = request
    if wasArmed != (request != nil) {
      window?.invalidateCursorRects(for: self)
      if request != nil {
        window?.makeFirstResponder(self)
        toolCursor.set()
      }
    }
    if changed { rebuildOverlays() }
  }

  func setTool(_ tool: EditorTool) {
    guard activeTool != tool else { return }
    cancelActiveGesture()
    if activeTool == .pen, tool == .move,
      let pathID = activePathID ?? selected?.pathID,
      recipe.layerStack.path(id: pathID)?.layerID == recipe.layerStack.activeLayerID
    {
      // The Pen's anchor focus is local to the canvas. Carry its path into
      // shared object selection so V immediately shows the path it just drew.
      selectedVectorObjectIDs = [pathID]
      send(.setVectorObjectSelection([pathID]))
    }
    if activeTool == .pen, tool != .pen {
      activePathID = nil
      activeSnapTarget = nil
    }
    activeTool = tool
    hoveredTarget = nil
    activeSnapTarget = nil
    if tool == .move || tool == .pen || tool == .shape || tool == .brush || tool == .eraser
      || tool == .selectionBrush
    {
      window?.makeFirstResponder(self)
    }
    window?.invalidateCursorRects(for: self)
    rebuildOverlays()
  }

  func setVectorToolStyle(_ style: VectorToolStyle) {
    vectorToolStyle = style
  }

  func setVectorEditMode(_ mode: VectorEditMode) {
    guard vectorEditMode != mode else { return }
    cancelActiveGesture()
    vectorEditMode = mode
    // The three modes hit-test different things, so nothing a previous mode
    // was pointing at survives the switch.
    hoveredTarget = nil
    window?.invalidateCursorRects(for: self)
    rebuildOverlays()
  }

  func setSelectedVectorObjects(_ ids: Set<UUID>) {
    guard selectedVectorObjectIDs != ids else { return }
    selectedVectorObjectIDs = ids
    rebuildOverlays()
  }

  func setShapeTool(_ state: ShapeToolState) { shapeTool = state; rebuildOverlays() }

  func setTextToolStyle(_ style: TextToolStyle) {
    textToolStyle = style
  }

  func setBrushSettings(_ settings: BrushSettings) {
    brushSettings = settings.validated
    if activeTool.usesBrushStrokeCapture { rebuildOverlays() }
  }

  func setHealTool(_ state: HealToolState) {
    healTool = state
    if activeTool == .heal { rebuildOverlays() }
  }

  /// The stroke settings the cursor ring and the overlay measure, which are
  /// the Healing Brush's own while it is active.
  private var displayedStrokeSettings: BrushSettings {
    activeTool == .heal ? healTool.settings : brushSettings
  }

  func presentBrushPreview(_ preview: BrushPreview?) {
    let frame = preview?.frame
    brushPreview = frame
    brushPreviewMode = preview?.strokeMode ?? .paint
    brushPreviewIsHealCoverage = preview?.isHealCoverage ?? false
    brushPreviewTarget = preview?.target
    brushPreviewTiles = frame?.tiles.compactMap { tile in
      guard let device else { return nil }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: frame?.kind == .mask ? .r16Float : .rgba16Float,
        width: BrushMetalRenderer.tileSize,
        height: BrushMetalRenderer.tileSize,
        mipmapped: false
      )
      descriptor.usage = .shaderRead
      descriptor.storageMode = .shared
      guard let texture = device.makeTexture(
        descriptor: descriptor, iosurface: tile.surface, plane: 0)
      else { return nil }
      return PresentedBrushTile(
        x: tile.x,
        y: tile.y,
        width: tile.width,
        height: tile.height,
        texture: texture
      )
    } ?? []
    needsDisplay = true
  }

  func present(_ frame: RenderedFrame) {
    contentImage = CIImage(
      ioSurface: frame.surface,
      options: [
        .colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any
      ]
    )
    isDifferencePreview = frame.differencePreviewSurface != nil
    frameImage = frame.differencePreviewSurface.map {
      CIImage(ioSurface: $0,
        options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any])
    } ?? contentImage
    frameSize = CGSize(width: frame.width, height: frame.height)
    // A proxy stands in for a larger developed RAW, so the canonical size comes
    // from what the decoder reported. Every other frame is already full size.
    if frame.isProxy, let inspection = frame.inspection {
      var width = Double(inspection.nativeWidth)
      var height = Double(inspection.nativeHeight)
      if [5, 6, 7, 8].contains(Int(inspection.exifOrientation)) {
        swap(&width, &height)
      }
      let crop = recipe.crop.clamped
      canonicalImageSize = CGSize(
        width: width * (crop.right - crop.left),
        height: height * (crop.top - crop.bottom)
      )
    } else {
      canonicalImageSize = frameSize
    }
    needsDisplay = true
    rebuildOverlays()
  }

  /// Drops the rendered image while keeping the document's extent.
  ///
  /// A project with no RAW source never produces a frame, so the canvas shows
  /// its checkerboard and vector artwork alone.
  func clearFrame() {
    frameImage = nil
    contentImage = nil
    isDifferencePreview = false
    frameSize = .zero
    canonicalImageSize = canvasSize
    needsDisplay = true
    rebuildOverlays()
  }

  func zoomToFit() {
    zoomMultiplier = 1
    panInPixels = .zero
    needsDisplay = true
    rebuildOverlays()
  }

  func zoomToActualSize() {
    guard referenceSize.width > 0, drawableSize.width > 0 else { return }
    let fit = fitScale()
    zoomMultiplier = fit > 0 ? 1 / fit : 1
    panInPixels = .zero
    needsDisplay = true
    rebuildOverlays()
  }

  func zoomIn() {
    setZoom(zoomMultiplier * 1.25, anchoredAt: nil)
  }

  func zoomOut() {
    setZoom(zoomMultiplier / 1.25, anchoredAt: nil)
  }

  func convertSelectedAnchor(to kind: VectorAnchorKind) {
    guard let selected,
      let located = recipe.layerStack.path(id: selected.pathID),
      let index = located.path.anchors.firstIndex(where: { $0.id == selected.anchorID })
    else { return }
    var stack = recipe.layerStack
    stack.updatePath(id: selected.pathID) { path in
      path.anchors[index] = converted(path.anchors[index], in: path, index: index, to: kind)
    }
    apply(stack, actionName: "Convert Anchor")
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      cancelActiveGesture()
      restoreMouseCoalescingState()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let resignKeyObserver {
      NotificationCenter.default.removeObserver(resignKeyObserver)
    }
    resignKeyObserver = nil
    guard let window else { return }
    resignKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.cancelActiveGesture() }
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let tracking = NSTrackingArea(
      rect: bounds,
      options: [
        .activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
      ],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(tracking)
    self.tracking = tracking
  }

  override func layout() {
    super.layout()
    artworkLayer.frame = bounds
    interactionLayer.frame = bounds
    rebuildOverlays()
  }

  func draw(in view: MTKView) {
    guard
      let drawable = currentDrawable,
      let commandBuffer = commandQueue?.makeCommandBuffer()
    else { return }

    let destination = CGRect(origin: .zero, size: drawableSize)
    let canvasRect = canvasRectInDrawable()

    // Outside the canvas is a darker checkerboard than inside it, so the document
    // extent reads without a frame or a border to mark it. Both grids share a
    // phase anchored at the drawable origin, which keeps them still while the
    // canvas moves across them.
    var output = checkerboard(
      light: CanvasCheckerboard.outside.light,
      dark: CanvasCheckerboard.outside.dark
    ).cropped(to: destination)

    if !canvasRect.isEmpty {
      output = checkerboard(
        light: CanvasCheckerboard.inside.light,
        dark: CanvasCheckerboard.inside.dark
      )
      .cropped(to: canvasRect.intersection(destination))
      .composited(over: output)
    }

    if let frameImage, frameSize.width > 0, frameSize.height > 0 {
      // A proxy frame carries fewer pixels than the canvas it represents, so map
      // its own size onto the canvas rectangle rather than assuming they match.
      let target = canvasRect.isEmpty ? destination : canvasRect
      let transform = CGAffineTransform(
        a: target.width / frameSize.width,
        b: 0,
        c: 0,
        d: target.height / frameSize.height,
        tx: target.minX,
        ty: target.minY
      )
      // Clipping is marked on the frame's own pixels, before it is scaled to the
      // viewport, so zooming never invents or hides a clipped pixel.
      let marked = isDifferencePreview
        ? frameImage : ClippingOverlay.apply(to: frameImage, indicators: clipping)
      // Scaling samples across the frame's boundary, and outside it there is
      // only transparent black to read. Left alone, that fades the document's
      // outermost pixels into the checkerboard over as much as a source pixel's
      // worth of viewport — a soft alpha border that is nowhere in the pixels
      // and does not survive a copy or an export, which is what makes it so
      // confusing to look at. Clamping gives the filter real edge colour to
      // sample instead, and the crop puts the document's own bounds back, so
      // the only softness left is the canvas edge's own coverage.
      // Source-over, so transparent pixels reveal the checkerboard beneath.
      output = marked
        .clampedToExtent()
        .transformed(by: transform)
        .cropped(to: target)
        .composited(over: output)
    }

    if let brushPreview, !canvasRect.isEmpty {
      let scaleX = canvasRect.width / CGFloat(brushPreview.width)
      let scaleY = canvasRect.height / CGFloat(brushPreview.height)
      for tile in brushPreviewTiles {
        guard let tileImage = CIImage(
          mtlTexture: tile.texture,
          options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any]
        ) else { continue }
        let presented: CIImage
        if brushPreview.kind == .mask {
          // Blue for a heal region: it is neither adding nor removing
          // coverage, so neither the mask brush's green nor its red would say
          // the right thing about what release is going to do.
          let color: (CGFloat, CGFloat, CGFloat) = if brushPreviewIsHealCoverage {
            (0.25, 0.55, 1)
          } else if brushPreviewMode == .erase {
            (1, 0.18, 0.12)
          } else {
            (0.12, 0.85, 0.35)
          }
          presented = tileImage.applyingFilter(
            "CIColorMatrix",
            parameters: [
              "inputRVector": CIVector(x: color.0, y: 0, z: 0, w: 0),
              "inputGVector": CIVector(x: color.1, y: 0, z: 0, w: 0),
              "inputBVector": CIVector(x: color.2, y: 0, z: 0, w: 0),
              "inputAVector": CIVector(x: 0.45, y: 0, z: 0, w: 0),
            ])
        } else {
          presented = tileImage
        }
        let tileExtent = CGRect(x: 0, y: 0, width: tile.width, height: tile.height)
        let transform = CGAffineTransform(
          a: scaleX, b: 0, c: 0, d: scaleY,
          tx: canvasRect.minX + CGFloat(tile.x) * scaleX,
          ty: canvasRect.minY + CGFloat(tile.y) * scaleY
        )
        // Neighboring tiles must share one drawable-pixel edge. A fractional
        // crop softens both sides independently and leaves a checkerboard gap.
        let minX = (canvasRect.minX + CGFloat(tile.x) * scaleX).rounded()
        let minY = (canvasRect.minY + CGFloat(tile.y) * scaleY).rounded()
        let maxX = (canvasRect.minX + CGFloat(tile.x + tile.width) * scaleX).rounded()
        let maxY = (canvasRect.minY + CGFloat(tile.y + tile.height) * scaleY).rounded()
        let destinationExtent = CGRect(
          x: minX, y: minY, width: maxX - minX, height: maxY - minY
        )
        // Core Image samples beyond a cropped tile when zoom is fractional.
        // Clamp those reads to the tile's edge before scaling, then restore the
        // tile's destination bounds so the clamped pixels cannot cover a neighbor.
        var placed = presented
          .cropped(to: tileExtent)
          .clampedToExtent()
          .transformed(by: transform)
          .cropped(to: destinationExtent)
        if brushPreview.kind == .mask,
          case .layerMask(let layerID, _) = brushPreviewTarget,
          let entry = recipe.layerStack.entry(id: layerID)
        {
          let transformIDs = [layerID] + entry.ancestorIDs.reversed()
          for id in transformIDs {
            guard let transform = recipe.layerStack.layer(id: id)?.transform,
              !transform.isIdentity
            else { continue }
            placed = placed.transformed(by: viewTransform(transform, canvasRect: canvasRect))
          }
        }
        output = placed.composited(over: output)
      }
      output = output.cropped(to: destination)
    }

    imageContext.render(
      output,
      to: drawable.texture,
      commandBuffer: commandBuffer,
      bounds: destination,
      colorSpace: displayColorSpace
    )
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func viewTransform(_ transform: LayerTransform, canvasRect: CGRect) -> CGAffineTransform {
    let radians = transform.rotationDegrees * .pi / 180
    let cosine = cos(radians)
    let sine = sin(radians)
    let a = cosine * transform.scaleX
    let b = sine * transform.scaleX
    let c = (cosine * transform.shearX - sine) * transform.scaleY
    let d = (sine * transform.shearX + cosine) * transform.scaleY
    let tx = transform.position.x - a * transform.anchor.x - c * transform.anchor.y
    let ty = transform.position.y - b * transform.anchor.x - d * transform.anchor.y
    let sx = canvasSize.width > 0 ? canvasRect.width / canvasSize.width : 1
    let sy = canvasSize.height > 0 ? canvasRect.height / canvasSize.height : 1
    let viewC = c * sx / sy
    let viewB = b * sy / sx
    return CGAffineTransform(
      a: a,
      b: viewB,
      c: viewC,
      d: d,
      tx: canvasRect.minX + tx * sx - a * canvasRect.minX - viewC * canvasRect.minY,
      ty: canvasRect.minY + ty * sy - viewB * canvasRect.minX - d * canvasRect.minY)
  }

  private func checkerboard(light: CGFloat, dark: CGFloat) -> CIImage {
    let backingScale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
    return CanvasCheckerboard.image(
      light: light,
      dark: dark,
      squareSize: CanvasCheckerboard.squareSizeInPoints * backingScale
    )
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    needsDisplay = true
    rebuildOverlays()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: toolCursor)
  }

  override func cursorUpdate(with event: NSEvent) {
    toolCursor.set()
  }

  private var toolCursor: NSCursor {
    // A standing sample request owns the pointer whatever tool is underneath:
    // the next click reads a pixel, so the cursor says so.
    if pendingSample != nil { return .crosshair }
    switch activeTool {
    case .crop, .brush, .eraser, .heal, .pen, .shape, .gradient, .fill, .masks, .marquee,
      .lasso, .magnetSelection, .selectionBrush:
      return .crosshair
    case .text:
      return .iBeam
    case .move:
      return .arrow
    case .navigate, .transform, .generate:
      return .openHand
    }
  }

  override func mouseEntered(with event: NSEvent) {
    pointerIsInside = true
    lastMouseInView = convert(event.locationInWindow, from: nil)
    publishViewport()
  }

  override func mouseExited(with event: NSEvent) {
    pointerIsInside = false
    if pendingSample != nil { send(.previewSample(x: nil, y: nil)) }
    publishViewport()
  }

  override func mouseMoved(with event: NSEvent) {
    lastMouseInView = convert(event.locationInWindow, from: nil)
    currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    pointerIsInside = true
    publishViewport()
    if guidesAreGrabbable {
      // A guide under the pointer says so with the cursor, the way a window
      // edge does, so an invisible four-point band is discoverable.
      if let hovered = guide(near: lastMouseInView) {
        (hovered.axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
      } else if activeTool == .navigate || activeTool == .move {
        NSCursor.openHand.set()
      }
    }
    // While a sample is armed the pointer reports what the pixel under it would
    // produce, so two candidate patches can be compared before either is
    // committed. The document coalesces these; the canvas just says where.
    if pendingSample != nil {
      NSCursor.crosshair.set()
      if imageRectInView().contains(lastMouseInView) {
        let point = documentPoint(fromView: lastMouseInView)
        send(.previewSample(x: point.x, y: point.y))
      } else {
        send(.previewSample(x: nil, y: nil))
      }
    }
    if activeTool == .pen {
      hoveredTarget = hitTest(lastMouseInView, commandDirectSelect: isDirectSelecting)
      updateAccessibilityValue()
      NSCursor.crosshair.set()
      rebuildOverlays()
    } else if activeTool == .crop {
      updateHoveredCropHandle()
      rebuildOverlays()
    } else if activeTool.usesBrushStrokeCapture {
      rebuildOverlays()
    }
  }

  override func magnify(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    setZoom(zoomMultiplier * (1 + event.magnification), anchoredAt: point)
  }

  override func scrollWheel(with event: NSEvent) {
    let backingScale = window?.backingScaleFactor ?? 1
    if event.modifierFlags.contains(.command) {
      let factor = exp(-event.scrollingDeltaY * 0.01)
      let point = convert(event.locationInWindow, from: nil)
      setZoom(zoomMultiplier * factor, anchoredAt: point)
      return
    } else {
      let direction: CGFloat = InteractionPreferences.invertsPanDirection ? -1 : 1
      panInPixels.x += event.scrollingDeltaX * backingScale * direction
      panInPixels.y -= event.scrollingDeltaY * backingScale * direction
    }
    needsDisplay = true
    rebuildOverlays()
  }

  private func setZoom(_ proposedZoom: CGFloat, anchoredAt viewPoint: CGPoint?) {
    let newZoom = min(max(proposedZoom, 0.05), 64)
    if let anchoredPan = coordinateTransform.anchoredPanInDrawablePixels(
      forViewPoint: viewPoint,
      atZoom: newZoom
    )
    {
      panInPixels = anchoredPan
    }
    zoomMultiplier = newZoom
    needsDisplay = true
    rebuildOverlays()
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if activeGesture != nil { cancelActiveGesture() }
    lastMouseInView = convert(event.locationInWindow, from: nil)
    // A standing sample request is answered before any tool sees the click, so
    // the pixel can be read without leaving the tool the user is working in.
    // Outside the image there is nothing to read and the request is withdrawn
    // rather than half-answered.
    if let pendingSample {
      if imageRectInView().contains(lastMouseInView) {
        let point = documentPoint(fromView: lastMouseInView)
        switch pendingSample.purpose {
        case .whiteBalance:
          send(.sampleWhiteBalance(
            x: point.x,
            y: point.y,
            keepArmed: event.modifierFlags.contains(.option)
          ))
        case .foregroundColor:
          send(.sampleForegroundColor(
            x: point.x,
            y: point.y,
            keepArmed: event.modifierFlags.contains(.option)
          ))
        }
      } else {
        send(.cancelSample)
      }
      return
    }
    currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    // Option temporarily borrows one click from the Brush for a color sample.
    // No tool switch or standing request is created, so releasing Option
    // returns immediately to painting with size, opacity and flow untouched.
    if activeTool == .brush, currentModifiers.contains(.option) {
      guard imageRectInView().contains(lastMouseInView) else { return }
      let point = documentPoint(fromView: lastMouseInView)
      send(.sampleForegroundColor(x: point.x, y: point.y, keepArmed: false))
      return
    }

    // Option means something different here than it does for the Brush above:
    // under the Healing Brush it anchors the source region rather than
    // sampling a colour, which is the convention every other editor uses and
    // the only gesture the source-point mode needs.
    if activeTool == .heal, currentModifiers.contains(.option) {
      guard imageRectInView().contains(lastMouseInView) else { return }
      let point = documentPoint(fromView: lastMouseInView)
      send(.setHealSource(x: point.x, y: point.y))
      return
    }

    // A guide is grabbed before any tool sees the press: it sits above the
    // image, and the four-point band is narrow enough not to swallow much.
    if beginGuideDrag(at: lastMouseInView) { return }

    if activeTool.usesBrushStrokeCapture {
      guard imageRectInView().contains(lastMouseInView) else { return }
      brushGesture = BrushGesture(originInView: lastMouseInView)
      beginHighFidelityBrushInput()
      brushStartTimestamp = event.timestamp
      brushSequence = 0
      if let sample = brushSample(from: event) {
        if activeTool == .selectionBrush {
          send(.beginSelectionBrushStroke(
            sample,
            combine: effectiveSelectionCombine(sticky: selectionBrushTool.combine)))
        } else {
          send(.beginBrushStroke(sample))
        }
      }
      rebuildOverlays()
      return
    }

    if activeTool == .text {
      if imageRectInView().contains(lastMouseInView) {
        placeText(at: lastMouseInView)
      }
      return
    }


    if activeTool == .fill {
      guard imageRectInView().contains(lastMouseInView) else { return }
      send(.applyFill(at: documentPoint(fromView: lastMouseInView)))
      return
    }

    if activeTool == .magnetSelection {
      guard imageRectInView().contains(lastMouseInView) else { return }
      send(.applyMagnetSelection(
        at: documentPoint(fromView: lastMouseInView),
        combine: magnetSelectionCombine()))
      return
    }

    if activeTool == .gradient || activeTool == .shape {
      guard imageRectInView().contains(lastMouseInView) else { return }
      let point = documentPoint(fromView: lastMouseInView)
      if activeTool == .gradient,
        let layerID = recipe.layerStack.activeLayerID,
        let gradient = recipe.layerStack.layer(id: layerID)?.paintLayer?.gradients.first,
        recipe.layerStack.layer(id: layerID)?.paintLayer?.gradients.count == 1
      {
        let startDistance = hypot(
          viewPoint(fromDocument: gradient.start).x - lastMouseInView.x,
          viewPoint(fromDocument: gradient.start).y - lastMouseInView.y)
        let endDistance = hypot(
          viewPoint(fromDocument: gradient.end).x - lastMouseInView.x,
          viewPoint(fromDocument: gradient.end).y - lastMouseInView.y)
        if min(startDistance, endDistance) <= 12 {
          creativeDrag = CreativeDragState(
            start: gradient.start, end: gradient.end, editingLayerID: layerID,
            movingStartHandle: startDistance <= endDistance)
        } else {
          creativeDrag = CreativeDragState(
            start: point, end: point, editingLayerID: nil, movingStartHandle: nil)
        }
      } else {
        creativeDrag = CreativeDragState(
          start: point, end: point, editingLayerID: nil, movingStartHandle: nil)
      }
      rebuildOverlays()
      return
    }

    guard activeTool == .pen else {
      if activeTool == .move {
        if beginVectorObjectGesture(at: lastMouseInView) { return }
        if beginLayerDrag(at: lastMouseInView) { return }
      }
      if activeTool == .transform, beginTransformDrag(at: lastMouseInView) { return }
      if activeTool == .crop, beginCropDrag(at: lastMouseInView) { return }
      if activeTool == .masks, beginMaskPlacement(at: lastMouseInView) { return }
      if beginSelectionGesture(at: lastMouseInView) { return }
      panGesture = PanGesture(originInView: lastMouseInView, panAtStart: panInPixels)
      NSCursor.closedHand.set()
      return
    }
    guard imageRectInView().contains(lastMouseInView) else { return }

    let target = hitTest(
      lastMouseInView, commandDirectSelect: isDirectSelecting)
    hoveredTarget = target
    if isDirectSelecting, let selection = selection(for: target) {
      selected = selection
      directEdit = DirectEdit(
        selection: selection,
        startDocumentPoint: documentPoint(fromView: lastMouseInView),
        originalStack: recipe.layerStack
      )
      beginEditGesture()
      rebuildOverlays()
      return
    }

    if let target {
      pendingClickTarget = target
      return
    }

    let raw = documentPoint(fromView: lastMouseInView)
    let position = snappedPlacementPoint(raw, previousAnchor: activePath?.anchors.last?.position)
    provisional = ProvisionalPlacement(
      rawDownDocument: raw,
      anchor: VectorAnchor(position: position),
      mouseDownInView: lastMouseInView,
      lastPointerInView: lastMouseInView
    )
    rebuildOverlays()
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    lastMouseInView = point
    currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if guideDrag != nil {
      updateGuideDrag(pointerInView: point)
      return
    }

    if activeTool.usesBrushStrokeCapture, brushGesture != nil {
      let samples = brushSamples(from: event)
      if !samples.isEmpty { send(.appendBrushSamples(samples)) }
      rebuildOverlays()
      return
    }

    // Shape geometry and gradient handles are transient until mouseUp, but the
    // overlay follows every drag event so the user sees the exact recipe that
    // will be committed before releasing the pointer.
    if var creativeDrag {
      creativeDrag.update(to: documentPoint(fromView: point))
      self.creativeDrag = creativeDrag
      rebuildOverlays()
      return
    }

    if let gradientHandleDrag {
      updateGradientHandleDrag(gradientHandleDrag, pointer: point)
      return
    }
    if let vectorObjectDrag {
      updateVectorObjectDrag(vectorObjectDrag, pointer: point)
      return
    }
    if vectorObjectMarquee != nil {
      updateVectorObjectMarquee(pointer: point)
      return
    }

    guard activeTool == .pen else {
      if let layerDrag {
        updateLayerDrag(layerDrag, pointer: point)
        return
      }
      if let transformDrag {
        updateTransformDrag(transformDrag, pointer: point)
        return
      }
      if let cropDrag {
        updateCropDrag(cropDrag, pointer: point)
        return
      }
      if let maskDrag {
        updateMaskPlacement(maskDrag, pointer: point)
        return
      }
      if let selectionDrag {
        updateSelectionGesture(selectionDrag, pointer: point)
        return
      }
      guard let panGesture else { return }
      let backingScale = window?.backingScaleFactor ?? 1
      let direction: CGFloat = InteractionPreferences.invertsPanDirection ? -1 : 1
      panInPixels = CGPoint(
        x: panGesture.panAtStart.x
          + (point.x - panGesture.originInView.x) * backingScale * direction,
        y: panGesture.panAtStart.y
          + (point.y - panGesture.originInView.y) * backingScale * direction
      )
      needsDisplay = true
      rebuildOverlays()
      return
    }

    if let directEdit {
      updateDirectEdit(directEdit, pointer: point)
    } else if provisional != nil {
      updateProvisional(pointer: point)
    }
    pendingClickTarget = nil
    rebuildOverlays()
  }

  override func mouseUp(with event: NSEvent) {
    lastMouseInView = convert(event.locationInWindow, from: nil)
    currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if guideDrag != nil {
      finishGuideDrag(pointerInView: lastMouseInView)
      return
    }
    if activeTool.usesBrushStrokeCapture {
      guard brushGesture != nil else { return }
      if let sample = brushSample(from: event) {
        send(.appendBrushSamples([sample]))
      }
      brushGesture = nil
      restoreMouseCoalescingState()
      // The captured stroke is the same either way; only what the document
      // makes of it differs, and a heal has to solve before it can commit.
      if activeTool == .heal {
        send(.commitHeal)
      } else if activeTool == .selectionBrush {
        send(.commitSelectionBrushStroke)
      } else {
        send(.commitBrushStroke)
      }
      rebuildOverlays()
      return
    }
    if let gradientHandleDrag {
      self.gradientHandleDrag = nil
      if gradientHandleDrag.didBeginGesture { endEditGesture("Move Gradient") }
      rebuildOverlays()
      return
    }
    if let vectorObjectDrag {
      self.vectorObjectDrag = nil
      canvasSnap = nil
      if vectorObjectDrag.didBeginGesture { endEditGesture("Move Vector Objects") }
      rebuildOverlays()
      return
    }
    if vectorObjectMarquee != nil {
      finishVectorObjectMarquee(pointer: lastMouseInView)
      return
    }
    if activeTool != .pen {
      if var creativeDrag {
        creativeDrag.update(to: documentPoint(fromView: lastMouseInView))
        self.creativeDrag = nil
        if creativeDrag.start.distance(to: creativeDrag.end) > 0.000_001 {
          if activeTool == .gradient {
            send(.commitGradient(
              layerID: creativeDrag.editingLayerID,
              start: creativeDrag.start, end: creativeDrag.end))
          } else if activeTool == .shape {
            send(.commitShape(
              start: creativeDrag.start, end: creativeDrag.end,
              constrained: currentModifiers.contains(.shift),
              fromCenter: currentModifiers.contains(.option)))
          }
        }
        rebuildOverlays()
        return
      }
      if layerDrag != nil {
        layerDrag = nil
        canvasSnap = nil
        endEditGesture("Move Layer")
        rebuildOverlays()
      }
      if transformDrag != nil {
        transformDrag = nil
        rebuildOverlays()
      }
      if cropDrag != nil {
        // The draft is not the document's crop yet, so there is no gesture to
        // close here: Return commits the whole session, Escape abandons it.
        cropDrag = nil
        updateHoveredCropHandle()
        rebuildOverlays()
      }
      if let maskDrag {
        updateMaskPlacement(maskDrag, pointer: lastMouseInView)
        self.maskDrag = nil
        endEditGesture("Place \(maskDrag.kind.label) Mask")
        rebuildOverlays()
      }
      if let selectionDrag {
        finishSelectionGesture(selectionDrag, pointer: lastMouseInView)
      }
      panGesture = nil
      toolCursor.set()
      return
    }

    if directEdit != nil {
      directEdit = nil
      endEditGesture("Move Anchor or Handle")
    } else if provisional != nil {
      updateProvisional(pointer: lastMouseInView)
      commitProvisional()
    } else if let pendingClickTarget {
      performClick(pendingClickTarget)
    }
    pendingClickTarget = nil
    hoveredTarget = hitTest(lastMouseInView, commandDirectSelect: isDirectSelecting)
    rebuildOverlays()
  }

  override func flagsChanged(with event: NSEvent) {
    let oldModifiers = currentModifiers
    currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if let layerDrag {
      updateLayerDrag(layerDrag, pointer: lastMouseInView)
    }
    if let transformDrag {
      updateTransformDrag(transformDrag, pointer: lastMouseInView)
    }
    // Shift and Option reshape a marquee that is still being dragged, so the
    // rectangle has to follow the modifier without waiting for a mouse move.
    if let selectionDrag {
      updateSelectionGesture(selectionDrag, pointer: lastMouseInView)
    }
    if var provisional {
      if currentModifiers.contains(.option), !oldModifiers.contains(.option),
        provisional.crossedDragThreshold
      {
        provisional.frozenIncomingHandle = provisional.anchor.incomingHandle
        self.provisional = provisional
      }
      updateProvisional(pointer: lastMouseInView)
    }
    if activeTool == .pen {
      hoveredTarget = hitTest(lastMouseInView, commandDirectSelect: isDirectSelecting)
      rebuildOverlays()
    }
  }

  override func keyDown(with event: NSEvent) {
    // Escape keeps each tool's normal cancellation behavior, then also clears
    // a standing pixel selection. Keeping this at the keyboard boundary makes
    // deselection independent of whichever tool happens to be active.
    let deselectsPixelSelection = event.keyCode == 53 && recipe.selection != nil
    defer {
      if deselectsPixelSelection {
        send(.commitSelection(nil, actionName: "Deselect"))
      }
    }

    if event.keyCode == 49, provisional != nil {
      isSpacePressed = true
      return
    }
    // Escape withdraws a standing sample request first: the request is the
    // nearest thing to cancel, and the tool underneath still has its own
    // Escape once the crosshair is gone.
    if event.keyCode == 53, pendingSample != nil {
      send(.cancelSample)
      return
    }
    // Match the typed character before tool letters: some keyboard layouts
    // need Option to produce a bracket from a key that otherwise types a letter.
    if (activeTool == .brush || activeTool == .eraser || activeTool == .selectionBrush),
      !event.modifierFlags.contains(.command),
      !event.modifierFlags.contains(.control)
    {
      switch event.characters {
      case "[":
        send(.adjustBrushSize(increasing: false))
        return
      case "]":
        send(.adjustBrushSize(increasing: true))
        return
      default:
        break
      }
    }

    // A bare letter selects a tool; repeating an editing tool toggles its settings.
    // The Command variants belong to the menus and are left alone.
    if !event.modifierFlags.contains(.command),
      let tool = EditorTool.activated(
        by: event.charactersIgnoringModifiers,
        shifted: event.modifierFlags.contains(.shift)
      )
    {
      sendToolActivationThroughResponderChain(tool)
      return
    }

    switch activeTool {
    case .pen:
      penKeyDown(event)
    case .move:
      if recipe.selection == nil, !selectedVectorObjectIDs.isEmpty,
        activeVectorLayer != nil,
        handleVectorObjectKey(event) { return }
      moveKeyDown(event)
    case .transform:
      if event.keyCode == 53 { send(.cancelTransform) }
      else if event.keyCode == 36 || event.keyCode == 76 { send(.commitTransform) }
      else { super.keyDown(with: event) }
    case .crop:
      cropKeyDown(event)
    case .masks:
      if event.keyCode == 53 {
        cancelMaskDrag()
      } else {
        super.keyDown(with: event)
      }
    case .brush, .eraser, .heal, .selectionBrush:
      if event.keyCode == 53 {
        cancelBrushGesture()
      } else {
        super.keyDown(with: event)
      }
    case .marquee, .lasso:
      // Escape abandons the in-flight shape before the common keyboard path
      // above clears the standing selection.
      if event.keyCode == 53 {
        cancelSelectionGesture()
      } else {
        super.keyDown(with: event)
      }
    case .gradient:
      if event.keyCode == 53 {
        creativeDrag = nil
        rebuildOverlays()
      } else {
        super.keyDown(with: event)
      }
    case .shape:
      if creativeDrag != nil, event.keyCode == 53 {
        creativeDrag = nil
        rebuildOverlays()
      } else {
        super.keyDown(with: event)
      }
    case .navigate, .text, .fill, .magnetSelection, .generate:
      super.keyDown(with: event)
    }
  }

  private func cropKeyDown(_ event: NSEvent) {
    switch event.keyCode {
    case 36, 76:
      cropDrag = nil
      send(.commitCrop)
    case 53:
      cropDrag = nil
      send(.cancelCrop)
    case 123, 124, 125, 126:
      nudgeCrop(keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
    default:
      super.keyDown(with: event)
    }
  }

  private func penKeyDown(_ event: NSEvent) {
    switch event.keyCode {
    case 36, 76:
      finishOpenPath()
    case 53:
      if provisional != nil || directEdit != nil {
        cancelProvisionalGesture()
      } else {
        finishOpenPath()
      }
    case 51, 117:
      deleteNewestAnchor()
    case 123, 124, 125, 126:
      nudgeSelection(keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
    default:
      super.keyDown(with: event)
    }
  }

  /// Keyboard equivalents for whole-object selection in Select/Move.
  private func handleVectorObjectKey(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 53:
      if gradientHandleDrag != nil {
        cancelGradientHandleDrag()
      } else if vectorObjectDrag != nil || vectorObjectMarquee != nil {
        cancelVectorObjectGesture()
      } else if !selectedVectorObjectIDs.isEmpty {
        selectedVectorObjectIDs = []
        send(.setVectorObjectSelection([]))
        rebuildOverlays()
      }
      return true
    case 51, 117:
      send(.deleteVectorObjects)
      return true
    case 123, 124, 125, 126:
      nudgeSelectedVectorObjects(
        keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
      return true
    default:
      return false
    }
  }

  private func nudgeSelectedVectorObjects(keyCode: UInt16, large: Bool) {
    guard let active = activeVectorLayer, !selectedVectorObjectIDs.isEmpty,
      recipe.layerStack.layer(id: active.id)?.isLocked != true
    else { return }
    let width = Double(vectorPixelSize.width)
    let height = Double(vectorPixelSize.height)
    guard width > 0, height > 0 else { return }
    let distance = large ? largeNudgeDistanceInImagePixels : nudgeDistanceInImagePixels
    let delta: VectorPoint =
      switch keyCode {
      case 123: VectorPoint(x: -distance / width, y: 0)
      case 124: VectorPoint(x: distance / width, y: 0)
      case 125: VectorPoint(x: 0, y: -distance / height)
      default: VectorPoint(x: 0, y: distance / height)
      }
    let moved = active.vector.transformingObjects(
      ids: selectedVectorObjectIDs,
      by: .translation(x: delta.x, y: delta.y),
      aspect: vectorAspect)
    var stack = recipe.layerStack
    stack.updateLayer(id: active.id) { $0.content = .vector(moved) }
    apply(stack, actionName: "Nudge Vector Objects")
  }

  private func moveKeyDown(_ event: NSEvent) {
    switch event.keyCode {
    case 53:
      cancelLayerDrag()
    case 123, 124, 125, 126:
      nudgeSelectedLayer(keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
    default:
      super.keyDown(with: event)
    }
  }

  override func keyUp(with event: NSEvent) {
    if event.keyCode == 49 {
      isSpacePressed = false
      return
    }
    super.keyUp(with: event)
  }

  override func resignFirstResponder() -> Bool {
    cancelActiveGesture()
    return super.resignFirstResponder()
  }

  private func sendToolActivationThroughResponderChain(_ tool: EditorTool) {
    let selector: Selector =
      switch tool {
      case .navigate: #selector(ProjectWindowController.activateNavigateTool(_:))
      case .move: #selector(ProjectWindowController.activateMoveTool(_:))
      case .transform: #selector(ProjectWindowController.activateTransformTool(_:))
      case .marquee: #selector(ProjectWindowController.activateMarqueeTool(_:))
      case .lasso: #selector(ProjectWindowController.activateLassoTool(_:))
      case .magnetSelection: #selector(ProjectWindowController.activateMagnetSelectionTool(_:))
      case .selectionBrush: #selector(ProjectWindowController.activateSelectionBrushTool(_:))
      case .crop: #selector(ProjectWindowController.activateCropTool(_:))
      case .brush: #selector(ProjectWindowController.activateBrushTool(_:))
      case .eraser: #selector(ProjectWindowController.activateEraserTool(_:))
      case .heal: #selector(ProjectWindowController.activateHealTool(_:))
      case .pen: #selector(ProjectWindowController.activatePenTool(_:))
      case .shape: #selector(ProjectWindowController.activateShapeTool(_:))
      case .gradient: #selector(ProjectWindowController.activateGradientTool(_:))
      case .fill: #selector(ProjectWindowController.activateFillTool(_:))
      case .text: #selector(ProjectWindowController.activateTextTool(_:))
      case .masks: #selector(ProjectWindowController.activateMasksTool(_:))
      case .generate: #selector(ProjectWindowController.activateGenerateTool(_:))
      }
    NSApp.sendAction(selector, to: nil, from: self)
  }

  /// Places a text layer where the Text tool was clicked, set the way the
  /// tool's settings say. The layer becomes active through `addLayer`, so the
  /// same panel then edits what was just placed.
  private func placeText(at point: CGPoint) {
    let placed = TextLayer.placing(
      "Text",
      in: recipe.layerStack.canvas,
      centeredAt: documentPoint(fromView: point)
    )
    let text = textToolStyle.applied(to: placed)
    send(.change(.addLayer(ProjectLayer.text(text)), interactive: false))
  }

  private var activePath: VectorPath? {
    guard let activePathID else { return nil }
    return recipe.layerStack.path(id: activePathID)?.path
  }

  private func updateProvisional(pointer: CGPoint) {
    guard var provisional else { return }
    let movement = hypot(
      pointer.x - provisional.mouseDownInView.x,
      pointer.y - provisional.mouseDownInView.y
    )

    if isSpacePressed {
      let previous = documentPoint(fromView: provisional.lastPointerInView)
      let current = documentPoint(fromView: pointer)
      let proposedPosition = provisional.anchor.position + (current - previous)
      let snappedPosition = snappedPlacementPoint(
        proposedPosition,
        previousAnchor: activePath?.anchors.last?.position
      )
      let appliedDelta = snappedPosition - provisional.anchor.position
      provisional.anchor = provisional.anchor.translated(by: appliedDelta)
      provisional.rawDownDocument = provisional.rawDownDocument + appliedDelta
      provisional.mouseDownInView.x += pointer.x - provisional.lastPointerInView.x
      provisional.mouseDownInView.y += pointer.y - provisional.lastPointerInView.y
      provisional.lastPointerInView = pointer
      self.provisional = provisional
      return
    }

    provisional.lastPointerInView = pointer
    if movement < dragThresholdInPoints, !provisional.crossedDragThreshold {
      provisional.anchor.position = snappedPlacementPoint(
        provisional.rawDownDocument,
        previousAnchor: activePath?.anchors.last?.position
      )
      self.provisional = provisional
      return
    }

    provisional.crossedDragThreshold = true
    var handlePointInView = pointer
    let anchorInView = viewPoint(fromDocument: provisional.anchor.position)
    if currentModifiers.contains(.shift) {
      handlePointInView = constrainedViewPoint(pointer, relativeTo: anchorInView)
    }
    let outgoing = documentPoint(fromView: handlePointInView)
    let delta = outgoing - provisional.anchor.position

    if currentModifiers.contains(.option) {
      if provisional.frozenIncomingHandle == nil {
        provisional.frozenIncomingHandle =
          provisional.anchor.incomingHandle
          ?? provisional.anchor.position - delta
      }
      provisional.anchor.outgoingHandle = collapsedHandle(
        outgoing, anchor: provisional.anchor.position)
      provisional.anchor.incomingHandle = provisional.frozenIncomingHandle
      provisional.anchor.kind = .corner
    } else {
      provisional.frozenIncomingHandle = nil
      provisional.anchor.outgoingHandle = collapsedHandle(
        outgoing, anchor: provisional.anchor.position)
      provisional.anchor.incomingHandle = collapsedHandle(
        provisional.anchor.position - delta,
        anchor: provisional.anchor.position
      )
      provisional.anchor.kind = .symmetric
    }
    self.provisional = provisional
  }

  private func commitProvisional() {
    guard let provisional else { return }
    var stack = recipe.layerStack
    let pathID: UUID
    if let activePathID, stack.path(id: activePathID) != nil {
      pathID = activePathID
      stack.updatePath(id: pathID) { path in
        path.anchors.append(provisional.anchor)
      }
    } else {
      let layerID = stack.ensureActiveVectorLayer()
      let existingCount =
        stack.layer(id: layerID).flatMap { layer -> Int? in
          guard case .vector(let vectorLayer) = layer.content else { return nil }
          return vectorLayer.objects.count
        } ?? 0
      let path = VectorPath(
        name: "Path \(existingCount + 1)",
        zOrder: existingCount,
        anchors: [provisional.anchor],
        stroke: vectorToolStyle.fullStroke,
        fill: vectorToolStyle.fill
      )
      pathID = path.id
      stack.appendPath(path, to: layerID)
    }

    self.provisional = nil
    activePathID = pathID
    selected = .anchor(pathID: pathID, anchorID: provisional.anchor.id)
    apply(
      stack,
      actionName: provisional.crossedDragThreshold ? "Add Smooth Anchor" : "Add Anchor"
    )
  }

  private func updateDirectEdit(_ edit: DirectEdit, pointer: CGPoint) {
    let current = documentPoint(fromView: pointer)
    let delta = current - edit.startDocumentPoint
    var stack = edit.originalStack
    stack.updatePath(id: edit.selection.pathID) { path in
      guard let index = path.anchors.firstIndex(where: { $0.id == edit.selection.anchorID }) else {
        return
      }
      switch edit.selection {
      case .anchor:
        path.anchors[index] = path.anchors[index].translated(by: delta)
      case .handle(_, _, let side):
        let original = path.anchors[index]
        let handle =
          (side == .incoming ? original.incomingHandle : original.outgoingHandle)
          ?? original.position
        let moved = collapsedHandle(handle + delta, anchor: original.position)
        path.anchors[index] = movedHandle(
          original,
          side: side,
          to: moved,
          breakPairing: currentModifiers.contains(.option)
        )
      }
    }
    recipe.layerStack = stack
    send(.change(.setLayerStack(stack, actionName: "Move Anchor or Handle"), interactive: true))
  }

  private func performClick(_ target: HitTarget) {
    switch target {
    case .close(let pathID, _):
      var stack = recipe.layerStack
      stack.updatePath(id: pathID) { $0.isClosed = true }
      activePathID = nil
      activeSnapTarget = nil
      apply(stack, actionName: "Close Path")

    case .anchor(let pathID, let anchorID):
      if currentModifiers.contains(.option) {
        toggleAnchorConversion(pathID: pathID, anchorID: anchorID)
      } else {
        removeAnchor(pathID: pathID, anchorID: anchorID)
      }

    case .handle:
      break

    case .endpoint(let pathID, let anchorID, let isFirst):
      if let activePathID, activePathID != pathID {
        join(activePathID: activePathID, otherPathID: pathID, otherIsFirst: isFirst)
      } else if self.activePathID == nil {
        resume(pathID: pathID, anchorID: anchorID, fromFirst: isFirst)
      }

    case .segment(let pathID, let startIndex, let t):
      var stack = recipe.layerStack
      var insertedID: UUID?
      stack.updatePath(id: pathID) { path in
        insertedID = path.insertAnchor(onSegmentStartingAt: startIndex, t: t)
      }
      if let insertedID {
        selected = .anchor(pathID: pathID, anchorID: insertedID)
        apply(stack, actionName: "Insert Anchor")
      }
    }
  }

  private func removeAnchor(pathID: UUID, anchorID: UUID) {
    var stack = recipe.layerStack
    var shouldRemovePath = false
    stack.updatePath(id: pathID) { path in
      path.anchors.removeAll { $0.id == anchorID }
      if path.anchors.count < 3 { path.isClosed = false }
      shouldRemovePath = path.anchors.isEmpty
    }
    if shouldRemovePath {
      stack.removePath(id: pathID)
      if activePathID == pathID { activePathID = nil }
      selected = nil
    } else if selected?.anchorID == anchorID {
      selected = nil
    }
    apply(stack, actionName: "Remove Anchor")
  }

  private func resume(pathID: UUID, anchorID: UUID, fromFirst: Bool) {
    var stack = recipe.layerStack
    if fromFirst {
      stack.updatePath(id: pathID) { $0 = $0.reversed() }
      apply(stack, actionName: "Reverse Path Direction")
    }
    activePathID = pathID
    selected = .anchor(pathID: pathID, anchorID: anchorID)
  }

  private func join(activePathID: UUID, otherPathID: UUID, otherIsFirst: Bool) {
    guard let active = recipe.layerStack.path(id: activePathID)?.path,
      let other = recipe.layerStack.path(id: otherPathID)?.path,
      !active.isClosed,
      !other.isClosed
    else { return }
    let orderedOther = otherIsFirst ? other : other.reversed()
    var stack = recipe.layerStack
    stack.updatePath(id: activePathID) { path in
      path.anchors.append(contentsOf: orderedOther.anchors)
    }
    stack.removePath(id: otherPathID)
    selected = orderedOther.anchors.last.map {
      .anchor(pathID: activePathID, anchorID: $0.id)
    }
    apply(stack, actionName: "Join Paths")
  }

  private func toggleAnchorConversion(pathID: UUID, anchorID: UUID) {
    guard let path = recipe.layerStack.path(id: pathID)?.path,
      let index = path.anchors.firstIndex(where: { $0.id == anchorID })
    else { return }
    var stack = recipe.layerStack
    stack.updatePath(id: pathID) { path in
      let anchor = path.anchors[index]
      if anchor.incomingHandle == nil && anchor.outgoingHandle == nil {
        path.anchors[index] = converted(anchor, in: path, index: index, to: .symmetric)
      } else {
        var corner = anchor
        corner.kind = .corner
        corner.incomingHandle = nil
        corner.outgoingHandle = nil
        path.anchors[index] = corner
      }
    }
    selected = .anchor(pathID: pathID, anchorID: anchorID)
    apply(stack, actionName: "Convert Anchor")
  }

  private func finishOpenPath() {
    provisional = nil
    activePathID = nil
    activeSnapTarget = nil
    rebuildOverlays()
  }

  private func deleteNewestAnchor() {
    guard let activePathID,
      let path = recipe.layerStack.path(id: activePathID)?.path,
      let newest = path.anchors.last
    else { return }
    removeAnchor(pathID: activePathID, anchorID: newest.id)
    if let remaining = recipe.layerStack.path(id: activePathID)?.path.anchors.last {
      selected = .anchor(pathID: activePathID, anchorID: remaining.id)
    }
  }

  private func nudgeSelection(keyCode: UInt16, large: Bool) {
    guard let selected else { return }
    let pixelDistance = large ? largeNudgeDistanceInImagePixels : nudgeDistanceInImagePixels
    let width = max(Double(canonicalImageSize.width), 1)
    let height = max(Double(canonicalImageSize.height), 1)
    let delta: VectorPoint =
      switch keyCode {
      case 123: VectorPoint(x: -pixelDistance / width, y: 0)
      case 124: VectorPoint(x: pixelDistance / width, y: 0)
      case 125: VectorPoint(x: 0, y: -pixelDistance / height)
      default: VectorPoint(x: 0, y: pixelDistance / height)
      }

    var stack = recipe.layerStack
    stack.updatePath(id: selected.pathID) { path in
      guard let index = path.anchors.firstIndex(where: { $0.id == selected.anchorID }) else {
        return
      }
      switch selected {
      case .anchor:
        path.anchors[index] = path.anchors[index].translated(by: delta)
      case .handle(_, _, let side):
        let anchor = path.anchors[index]
        let current =
          (side == .incoming ? anchor.incomingHandle : anchor.outgoingHandle)
          ?? anchor.position
        path.anchors[index] = movedHandle(
          anchor,
          side: side,
          to: current + delta,
          breakPairing: currentModifiers.contains(.option)
        )
      }
    }
    apply(stack, actionName: large ? "Nudge Anchor 10 Pixels" : "Nudge Anchor")
  }

  /// The layer the layers inspector has selected, when it is one the Move tool
  /// can outline.
  ///
  /// The canvas layer is the document extent rather than content, and the
  /// canvas already draws its own edge, so it is not outlined.
  private var selectedLayer: ProjectLayer? {
    guard let id = recipe.layerStack.activeLayerID,
      let layer = recipe.layerStack.layer(id: id),
      !layer.isCanvasLayer
    else { return nil }
    return layer
  }

  /// The selected layer, when its content can actually be moved.
  ///
  /// A locked layer — the RAW background, which is the extent the canvas took
  /// its size from — is outlined but stays put.
  private var movableLayer: ProjectLayer? {
    guard let layer = selectedLayer, !layer.isLocked else { return nil }
    return layer
  }

  private func selectedLayerRectInView() -> CGRect? {
    // An object transform reshapes part of a vector layer, so the box follows
    // the draft's own reference rectangle rather than the whole layer's frame.
    if let draft = transformDraft, !draft.objectIDs.isEmpty,
      draft.targetID == recipe.layerStack.activeLayerID
    {
      let frame = draft.transform.affineBounds(of: draft.transform.referenceRect)
      guard !frame.isEmpty else { return nil }
      let rect = viewRect(fromCanvas: frame)
      return rect.isEmpty ? nil : rect
    }
    guard let layer = selectedLayer,
      let frame = recipe.layerStack.frame(of: layer.id),
      !frame.isEmpty
    else { return nil }
    let rect = viewRect(fromCanvas: frame)
    return rect.isEmpty ? nil : rect
  }

  /// Selects the frontmost ordinary layer under the pointer and moves it when
  /// it is unlocked. Vector objects are handled before this method is called.
  ///
  /// Returns whether the press found a layer. A miss can still pan the viewport.
  private func beginLayerDrag(at point: CGPoint) -> Bool {
    guard let target = topmostNonVectorLayer(at: point) else { return false }
    if target.layer.id != recipe.layerStack.activeLayerID {
      recipe.layerStack.activeLayerID = target.layer.id
      selectedVectorObjectIDs = []
      send(.selectLayer(target.layer.id))
    }
    guard let layer = movableLayer, let rect = selectedLayerRectInView() else { return true }
    guard rect.insetBy(
      dx: -layerGrabToleranceInPoints,
      dy: -layerGrabToleranceInPoints).contains(point) else { return true }

    layerDrag = LayerDrag(layerID: layer.id, startPointerInView: point, appliedOffset: .zero)
    beginEditGesture()
    NSCursor.closedHand.set()
    rebuildOverlays()
    return true
  }

  /// Frame picking is the existing Move contract for image, paint, text, and
  /// RAW layers. Children receive clicks before their groups; adjustments do
  /// not have a directly grabbable surface.
  private func topmostNonVectorLayer(at point: CGPoint)
    -> (layer: ProjectLayer, index: Int)?
  {
    let canvasPoint = documentPoint(fromView: point)
    let x = canvasPoint.x * Double(vectorPixelSize.width)
    let y = canvasPoint.y * Double(vectorPixelSize.height)
    for (index, entry) in recipe.layerStack.flattenedLayers.enumerated()
    where entry.isEffectivelyEnabled && entry.effectiveOpacity > 0
    {
      let layer = entry.layer
      if layer.isCanvasLayer || layer.isVectorLayer || layer.isGroupLayer
        || layer.isAdjustmentLayer { continue }
      guard let frame = recipe.layerStack.frame(of: layer.id),
        x >= frame.x, x <= frame.x + frame.width,
        y >= frame.y, y <= frame.y + frame.height
      else { continue }
      return (layer, index)
    }
    return nil
  }

  /// The inside-drag transform handle. Scale, rotation, shear and perspective
  /// are available in the shared numeric draft; this gesture changes only the
  /// placement stage and never mutates the recipe until Apply.
  private func beginTransformDrag(at point: CGPoint) -> Bool {
    guard let draft = transformDraft, let rect = selectedLayerRectInView(),
      draft.targetID == recipe.layerStack.activeLayerID,
      rect.insetBy(dx: -layerGrabToleranceInPoints, dy: -layerGrabToleranceInPoints).contains(point)
    else { return false }
    transformDrag = TransformDrag(
      targetID: draft.targetID, startPointerInView: point, startTransform: draft.transform
    )
    NSCursor.closedHand.set()
    return true
  }

  private func updateTransformDrag(_ drag: TransformDrag, pointer: CGPoint) {
    guard let canvasPixels = canvasPixelsPerViewPoint() else { return }
    var transform = drag.startTransform
    var dx = Double((pointer.x - drag.startPointerInView.x) * canvasPixels.width)
    var dy = Double((pointer.y - drag.startPointerInView.y) * canvasPixels.height)
    if currentModifiers.contains(.shift) {
      if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
    }
    transform.position.x += dx
    transform.position.y += dy
    guard transform.isValid else { return }
    send(.updateTransformDraft(transform))
  }

  private func updateLayerDrag(_ drag: LayerDrag, pointer: CGPoint) {
    guard let canvasPixels = canvasPixelsPerViewPoint() else { return }
    var deltaX = (pointer.x - drag.startPointerInView.x) * canvasPixels.width
    var deltaY = (pointer.y - drag.startPointerInView.y) * canvasPixels.height
    // Shift keeps the move on one axis, the way it constrains a pen handle.
    var allowsHorizontalSnap = true
    var allowsVerticalSnap = true
    if currentModifiers.contains(.shift) {
      if abs(deltaX) >= abs(deltaY) {
        deltaY = 0
        allowsVerticalSnap = false
      } else {
        deltaX = 0
        allowsHorizontalSnap = false
      }
    }

    // Placement is stored in whole canvas pixels. Rounding the offset measured
    // from the press, rather than each step, keeps a slow drag from losing
    // fractions of a pixel on every event.
    var offset = CGPoint(x: deltaX.rounded(), y: deltaY.rounded())
    let previousSnap = canvasSnap
    canvasSnap = nil
    // Snapping is measured against where the layer would land unsnapped, so a
    // drag that leaves a guide behind is released rather than dragging the
    // snap along with it.
    if let threshold = snapThresholdInCanvasPixels,
      let frame = recipe.layerStack.frame(of: drag.layerID)
    {
      let proposed = frame.translated(
        byX: Double(offset.x - drag.appliedOffset.x),
        y: Double(offset.y - drag.appliedOffset.y)
      )
      var result = CanvasSnapping.snapOffset(
        for: proposed,
        canvas: recipe.layerStack.canvas,
        settings: recipe.canvasSettings,
        thresholdInCanvasPixels: threshold
      )
      if !allowsHorizontalSnap {
        result.offset.x = 0
        result.verticalLine = nil
      }
      if !allowsVerticalSnap {
        result.offset.y = 0
        result.horizontalLine = nil
      }
      offset.x += CGFloat(result.offset.x.rounded())
      offset.y += CGFloat(result.offset.y.rounded())
      canvasSnap = result.isEmpty ? nil : result
    }

    guard offset != drag.appliedOffset else {
      if canvasSnap != previousSnap { rebuildOverlays() }
      return
    }
    let step = CGPoint(
      x: offset.x - drag.appliedOffset.x,
      y: offset.y - drag.appliedOffset.y
    )
    layerDrag?.appliedOffset = offset
    send(
      .change(
        .translateLayer(drag.layerID, byX: Double(step.x), y: Double(step.y)),
        interactive: true
      ))
  }

  /// Puts the layer back where the drag started and ends the gesture.
  ///
  /// The document records one gesture, so returning the layer by the distance
  /// it travelled leaves nothing to undo.
  private func cancelLayerDrag() {
    guard let drag = layerDrag else { return }
    layerDrag = nil
    canvasSnap = nil
    if drag.appliedOffset != .zero {
      send(
        .change(
          .translateLayer(
            drag.layerID,
            byX: Double(-drag.appliedOffset.x),
            y: Double(-drag.appliedOffset.y)
          ),
          interactive: false
        ))
    }
    endEditGesture("Move Layer")
    NSCursor.openHand.set()
    rebuildOverlays()
  }

  /// Arrow keys move the selected layer by whole canvas pixels.
  private func nudgeSelectedLayer(keyCode: UInt16, large: Bool) {
    guard let layer = movableLayer else { return }
    let distance = large ? largeLayerNudgeInCanvasPixels : layerNudgeInCanvasPixels
    var deltaX = 0.0
    var deltaY = 0.0
    switch keyCode {
    case 123: deltaX = -distance
    case 124: deltaX = distance
    case 125: deltaY = -distance
    default: deltaY = distance
    }
    send(
      .change(
        .translateLayer(layer.id, byX: deltaX, y: deltaY),
        interactive: false
      ))
  }

  // MARK: - Rulers, guides, grid and snapping

  /// Tells the rulers where the canvas extent landed and where the pointer is.
  private func publishViewport() {
    guard let onViewportChange else { return }
    var pointer: CGPoint?
    if pointerIsInside, let point = canvasPoint(fromView: lastMouseInView) {
      pointer = point
    }
    onViewportChange(
      CanvasViewportInfo(
        canvasRectInView: imageRectInView(),
        canvasSize: referenceSize,
        pointerInCanvasPixels: pointer
      ))
  }

  /// Redraws the overlays after a view toggle changed what belongs on them.
  func refreshOverlays() {
    rebuildOverlays()
  }

  /// A point in the view, in canvas pixels, or `nil` before the canvas has an
  /// extent to measure against.
  private func canvasPoint(fromView point: CGPoint) -> CGPoint? {
    let rect = imageRectInView()
    let size = referenceSize
    guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return nil }
    return CGPoint(
      x: (point.x - rect.minX) / rect.width * size.width,
      y: (point.y - rect.minY) / rect.height * size.height
    )
  }

  /// Where a guide's line sits in the view, along the axis it crosses.
  private func viewPosition(ofGuideAt position: Double, axis: GuideAxis) -> CGFloat? {
    let rect = imageRectInView()
    let size = referenceSize
    guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return nil }
    switch axis {
    case .vertical: return rect.minX + CGFloat(position) / size.width * rect.width
    case .horizontal: return rect.minY + CGFloat(position) / size.height * rect.height
    }
  }

  /// How far a snap reaches, converted from screen points into canvas pixels so
  /// the pull feels the same at every zoom level.
  private var snapThresholdInCanvasPixels: Double? {
    guard viewSettings.isOn(.snap), let canvasPixels = canvasPixelsPerViewPoint() else {
      return nil
    }
    let threshold = recipe.canvasSettings.snapping.thresholdInScreenPoints
    guard threshold > 0 else { return nil }
    return threshold * Double(canvasPixels.width)
  }

  private var guidesAreGrabbable: Bool {
    viewSettings.guidesAreEditable && recipe.layerStack.canvas.isResolved
  }

  private func guide(near point: CGPoint) -> CanvasGuide? {
    guard guidesAreGrabbable else { return nil }
    var best: (guide: CanvasGuide, distance: CGFloat)?
    for guide in recipe.canvasSettings.guides {
      guard let position = viewPosition(ofGuideAt: guide.position, axis: guide.axis) else {
        continue
      }
      let distance = abs((guide.axis == .vertical ? point.x : point.y) - position)
      guard distance <= guideGrabToleranceInPoints else { continue }
      if best == nil || distance < best!.distance { best = (guide, distance) }
    }
    return best?.guide
  }

  private func beginGuideDrag(at point: CGPoint) -> Bool {
    guard let guide = guide(near: point) else { return false }
    guideDrag = GuideDrag(guide: guide, isNew: false, hasBeenAdded: true)
    beginEditGesture()
    return true
  }

  /// Starts pulling a new guide out of a ruler.
  ///
  /// The ruler forwards the raw event: canvas pixels, snapping and editor
  /// intents all live here, so the ruler stays a drawing.
  func beginGuideCreation(axis: GuideAxis, windowPoint: CGPoint) {
    guard viewSettings.guidesAreEditable, recipe.layerStack.canvas.isResolved else { return }
    cancelActiveGesture()
    let point = convert(windowPoint, from: nil)
    let position = canvasPoint(fromView: point) ?? .zero
    let guide = CanvasGuide(
      axis: axis,
      position: (axis == .vertical ? Double(position.x) : Double(position.y)).rounded()
    )
    guideDrag = GuideDrag(guide: guide, isNew: true, hasBeenAdded: false)
    beginEditGesture()
  }

  func updateGuideGesture(windowPoint: CGPoint) {
    guard guideDrag != nil else { return }
    updateGuideDrag(pointerInView: convert(windowPoint, from: nil))
  }

  func endGuideGesture(windowPoint: CGPoint) {
    guard guideDrag != nil else { return }
    finishGuideDrag(pointerInView: convert(windowPoint, from: nil))
  }

  private func updateGuideDrag(pointerInView point: CGPoint) {
    guard var drag = guideDrag, let canvasPoint = canvasPoint(fromView: point) else { return }
    lastMouseInView = point
    var position = drag.guide.axis == .vertical ? Double(canvasPoint.x) : Double(canvasPoint.y)
    if let threshold = snapThresholdInCanvasPixels,
      let line = CanvasSnapping.snap(
        position: position,
        axis: drag.guide.axis,
        canvas: recipe.layerStack.canvas,
        settings: recipe.canvasSettings,
        excludingGuide: drag.guide.id,
        thresholdInCanvasPixels: threshold
      )
    {
      position = line.position
    }
    position = position.rounded()
    guard position != drag.guide.position || !drag.hasBeenAdded else {
      publishViewport()
      return
    }
    drag.guide.position = position

    var settings = recipe.canvasSettings
    if drag.hasBeenAdded {
      settings = settings.moving(drag.guide.id, to: position)
    } else {
      settings = settings.adding(drag.guide)
      drag.hasBeenAdded = true
    }
    guideDrag = drag
    send(
      .change(
        .setCanvasSettings(settings, actionName: drag.isNew ? "Add Guide" : "Move Guide"),
        interactive: false
      ))
    publishViewport()
  }

  /// Ends a guide drag, deleting the guide when it was dropped off the canvas.
  ///
  /// Dragging a guide back past the edge is how it is thrown away, which is
  /// also what dropping it on the ruler it came from does.
  private func finishGuideDrag(pointerInView point: CGPoint) {
    guard let drag = guideDrag else { return }
    guideDrag = nil
    guard drag.hasBeenAdded else {
      // A click on a ruler that never reached the canvas adds nothing.
      endEditGesture("Add Guide")
      return
    }

    let extent =
      drag.guide.axis == .vertical
      ? Double(recipe.layerStack.canvas.width) : Double(recipe.layerStack.canvas.height)
    let isDropped = drag.guide.position < 0 || drag.guide.position > extent
    if isDropped {
      send(
        .change(
          .setCanvasSettings(
            recipe.canvasSettings.removing(drag.guide.id),
            actionName: "Delete Guide"
          ),
          interactive: false
        ))
    }
    let name =
      if drag.isNew {
        "Add Guide"
      } else if isDropped {
        "Delete Guide"
      } else {
        "Move Guide"
      }
    endEditGesture(name)
    rebuildOverlays()
    publishViewport()
  }

  /// The grid, drawn over the canvas in the extent's own pixels.
  private func drawGrid() {
    guard viewSettings.isOn(.grid) else { return }
    let rect = imageRectInView()
    let size = referenceSize
    guard rect.width > 0, size.width > 0, size.height > 0 else { return }
    let grid = recipe.canvasSettings.grid
    let contentsScale = window?.backingScaleFactor ?? 2

    for (step, alpha) in [(grid.subdivisionSpacing, 0.16), (grid.spacing, 0.34)] {
      guard step > 0 else { continue }
      // Below two points apart the lines merge into a wash; skip that level
      // rather than painting the canvas grey.
      guard CGFloat(step) / size.width * rect.width >= 2 else { continue }
      let path = CGMutablePath()
      var x = step
      while x < size.width {
        let position = (rect.minX + CGFloat(x) / size.width * rect.width).rounded() + 0.5
        path.move(to: CGPoint(x: position, y: rect.minY))
        path.addLine(to: CGPoint(x: position, y: rect.maxY))
        x += step
      }
      var y = step
      while y < size.height {
        let position = (rect.minY + CGFloat(y) / size.height * rect.height).rounded() + 0.5
        path.move(to: CGPoint(x: rect.minX, y: position))
        path.addLine(to: CGPoint(x: rect.maxX, y: position))
        y += step
      }
      let shape = CAShapeLayer()
      shape.path = path
      shape.fillColor = nil
      shape.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
      shape.lineWidth = 1
      shape.contentsScale = contentsScale
      interactionLayer.addSublayer(shape)
    }
  }

  private func drawGuides() {
    guard viewSettings.isOn(.guides), !recipe.canvasSettings.guides.isEmpty else { return }
    let locked = viewSettings.isOn(.lockGuides)
    let path = CGMutablePath()
    for guide in recipe.canvasSettings.guides {
      guard let position = viewPosition(ofGuideAt: guide.position, axis: guide.axis) else {
        continue
      }
      appendLine(at: position, axis: guide.axis, to: path)
    }
    let shape = CAShapeLayer()
    shape.path = path
    shape.fillColor = nil
    shape.strokeColor =
      (locked ? NSColor.systemTeal : NSColor.systemCyan).withAlphaComponent(0.9).cgColor
    shape.lineWidth = 1
    // A locked guide is dashed, so it looks like something that will not move.
    shape.lineDashPattern = locked ? [NSNumber(value: 5), NSNumber(value: 4)] : nil
    shape.contentsScale = window?.backingScaleFactor ?? 2
    interactionLayer.addSublayer(shape)
  }

  /// Marks the lines a layer drag snapped to, so the alignment is visible while
  /// it holds.
  private func drawCanvasSnapLines() {
    guard let canvasSnap else { return }
    let path = CGMutablePath()
    for line in [canvasSnap.verticalLine, canvasSnap.horizontalLine].compactMap({ $0 }) {
      guard let position = viewPosition(ofGuideAt: line.position, axis: line.axis) else {
        continue
      }
      appendLine(at: position, axis: line.axis, to: path)
    }
    let shape = CAShapeLayer()
    shape.path = path
    shape.fillColor = nil
    shape.strokeColor = NSColor.systemYellow.cgColor
    shape.lineWidth = 1
    shape.contentsScale = window?.backingScaleFactor ?? 2
    interactionLayer.addSublayer(shape)
  }

  private func appendLine(at position: CGFloat, axis: GuideAxis, to path: CGMutablePath) {
    let aligned = position.rounded() + 0.5
    switch axis {
    case .vertical:
      path.move(to: CGPoint(x: aligned, y: bounds.minY))
      path.addLine(to: CGPoint(x: aligned, y: bounds.maxY))
    case .horizontal:
      path.move(to: CGPoint(x: bounds.minX, y: aligned))
      path.addLine(to: CGPoint(x: bounds.maxX, y: aligned))
    }
  }

  // MARK: - Crop tool
  //
  // While the crop tool is open the render engine is showing the whole oriented
  // frame with the straighten applied, so `imageRectInView()` is that frame and
  // the draft's unit coordinates map straight onto it. Every crop calculation
  // below therefore works in unit space and crosses into view points through
  // the two adapters at the end of this file, exactly like the pen's document
  // points do.

  /// The oriented image size the crop's aspect locks and straighten limits are
  /// measured against, in pixels.
  private var cropImageSize: CGSize? {
    let size: CGSize
    switch cropDraft?.target {
    case .layer(let id):
      guard let frame = recipe.layerStack.frame(of: id) else { return nil }
      size = CGSize(width: frame.width, height: frame.height)
    case .canvas, nil:
      if let visible = committedRawCanvasCropBounds,
        visible.unitWidth > 0, visible.unitHeight > 0
      {
        size = CGSize(
          width: referenceSize.width / visible.unitWidth,
          height: referenceSize.height / visible.unitHeight)
      } else {
        size = referenceSize
      }
    }
    guard size.width > 0, size.height > 0 else { return nil }
    return size
  }

  /// The full bounds of the current crop target in view points.
  private var cropReferenceRectInView: CGRect {
    switch cropDraft?.target {
    case .layer(let id):
      guard let frame = recipe.layerStack.frame(of: id) else { return .zero }
      return viewRect(fromCanvas: frame)
    case .canvas, nil:
      return imageRectInView()
    }
  }

  /// The crop rectangle in view coordinates.
  private func cropRectInView(_ crop: CropRecipe) -> CGRect {
    let rect = cropReferenceRectInView
    guard rect.width > 0, rect.height > 0 else { return .zero }
    let visible = committedRawCanvasCropBounds ?? .identity
    guard visible.unitWidth > 0, visible.unitHeight > 0 else { return .zero }
    return CGRect(
      x: rect.minX + CGFloat((crop.left - visible.left) / visible.unitWidth) * rect.width,
      y: rect.minY + CGFloat((crop.bottom - visible.bottom) / visible.unitHeight) * rect.height,
      width: CGFloat(crop.unitWidth / visible.unitWidth) * rect.width,
      height: CGFloat(crop.unitHeight / visible.unitHeight) * rect.height
    )
  }

  /// A view point as a unit position in the oriented image.
  private func cropUnitPoint(fromView point: CGPoint) -> (x: Double, y: Double)? {
    let rect = cropReferenceRectInView
    guard rect.width > 0, rect.height > 0 else { return nil }
    let visible = committedRawCanvasCropBounds ?? .identity
    return (
      x: visible.left
        + Double((point.x - rect.minX) / rect.width) * visible.unitWidth,
      y: visible.bottom
        + Double((point.y - rect.minY) / rect.height) * visible.unitHeight
    )
  }

  /// How large the handle hit radius is in unit coordinates on each axis.
  private func cropHitTolerance() -> (x: Double, y: Double)? {
    let rect = cropReferenceRectInView
    guard rect.width > 0, rect.height > 0 else { return nil }
    let visible = committedRawCanvasCropBounds ?? .identity
    return (
      x: Double(cropHandleHitRadiusInPoints / rect.width) * visible.unitWidth,
      y: Double(cropHandleHitRadiusInPoints / rect.height) * visible.unitHeight
    )
  }

  /// A committed RAW crop is already the displayed canvas. Treat its stored
  /// source-space rectangle as the visible 0...1 bounds until the next edit
  /// reopens the full RAW; that keeps the idle outline around the applied
  /// result instead of nesting it inside itself.
  private var committedRawCanvasCropBounds: CropRecipe? {
    guard let draft = cropDraft, !draft.revealsFullTarget,
      draft.target == .canvas,
      recipe.layerStack.layer(id: .rawBackground)?.isDevelopedRaw == true
    else { return nil }
    return draft.recipe
  }

  private func updateHoveredCropHandle() {
    guard activeTool == .crop, let crop = cropDraft?.recipe,
      let point = cropUnitPoint(fromView: lastMouseInView),
      let tolerance = cropHitTolerance()
    else {
      hoveredCropHandle = nil
      return
    }
    hoveredCropHandle = CropGeometry.handle(
      at: point.x,
      unitY: point.y,
      in: crop,
      toleranceX: tolerance.x,
      toleranceY: tolerance.y
    )
  }

  /// A handle refines the current crop. Any other drag on the target draws a
  /// replacement rectangle; Option-drag inside the crop moves it instead.
  private func beginCropDrag(at point: CGPoint) -> Bool {
    guard let draft = cropDraft else { return false }
    let crop = draft.recipe
    if committedRawCanvasCropBounds != nil {
      // The displayed RAW is currently the committed crop. First reveal its
      // complete source so a drag can expand as well as tighten the rectangle;
      // the following drag edits it in stable source coordinates.
      cropDraft = CropDraft(target: draft.target, recipe: crop, revealsFullTarget: true)
      send(.updateCropDraft(crop, interactive: false))
      rebuildOverlays()
      return true
    }
    guard
      let unit = cropUnitPoint(fromView: point),
      let tolerance = cropHitTolerance(),
      unit.x >= 0, unit.x <= 1, unit.y >= 0, unit.y <= 1
    else { return false }

    let handle = CropGeometry.handle(
      at: unit.x,
      unitY: unit.y,
      in: crop,
      toleranceX: tolerance.x,
      toleranceY: tolerance.y
    )
    let insideRectangle =
      unit.x >= crop.left && unit.x <= crop.right && unit.y >= crop.bottom && unit.y <= crop.top
    let mode: CropDrag.Mode
    if let handle {
      mode = .resize(handle)
    } else if insideRectangle, currentModifiers.contains(.option) {
      mode = .move
    } else {
      mode = .create(startX: unit.x, startY: unit.y)
    }
    cropDrag = CropDrag(mode: mode, startPointerInView: point, startCrop: crop)
    hoveredCropHandle = handle
    (insideRectangle && currentModifiers.contains(.option) ? NSCursor.closedHand : NSCursor.crosshair)
      .set()
    return true
  }
  // MARK: - Selection
  //
  // The canvas draws the selection and produces the geometry a gesture
  // describes; it never decides what a selection means. A drag stays entirely
  // in `selectionDrag` and the draft until the pointer comes up, so moving the
  // mouse costs an overlay path and nothing else — no revision, no render, and
  // no history entry until there is something worth undoing.

  /// The smallest pointer movement, in canvas pixels, that adds a freehand
  /// point. Anything finer is pointer noise the polygon does not need, and
  /// dropping it is what keeps a slow careful outline inside the point cap.
  private let freehandPointSpacingInCanvasPixels = 2.0

  /// Starts a marquee or freehand gesture.
  ///
  /// Returns `false` when the press is not a selection placement, so the caller
  /// falls through to panning and the viewport stays reachable.
  private func beginSelectionGesture(at point: CGPoint) -> Bool {
    guard activeTool.drawsSelectionGeometry, imageRectInView().contains(point) else { return false }
    let document = documentPoint(fromView: point)
    let kind = selectionTool.generatorKind(for: activeTool)
    let combination = gestureCombine()
    selectionDrag = SelectionDrag(
      selectionAtStart: recipe.selection,
      combine: combination.operation,
      consumedCombineModifiers: combination.consumedModifiers,
      kind: kind,
      startDocument: document,
      points: [document]
    )
    // A press with no drag behind it selects nothing yet, so the draft starts
    // as whatever was already there rather than flashing an empty selection.
    send(.updateSelectionDraft(recipe.selection))
    return true
  }

  /// Which combine operation this gesture uses.
  ///
  /// The panel holds the sticky setting; shift and option override it for one
  /// drag, the way they do in every other editor. With nothing selected there
  /// is nothing to combine with, so the first gesture always starts fresh.
  private func gestureCombine() -> (
    operation: MaskCombineOperation?, consumedModifiers: NSEvent.ModifierFlags
  ) {
    guard recipe.selection != nil else { return (nil, []) }
    let quickModifiers = currentModifiers.intersection([.shift, .option])
    if quickModifiers.contains([.shift, .option]) {
      return (.intersect, [.shift, .option])
    }
    if quickModifiers.contains(.shift) { return (.add, [.shift]) }
    if quickModifiers.contains(.option) { return (.subtract, [.option]) }
    return (selectionTool.combine, [])
  }

  /// Resolves the sticky Magnet Selection operation and the familiar one-click
  /// Shift/Option overrides. With no existing selection every click starts a
  /// new one regardless of the sticky setting.
  private func magnetSelectionCombine() -> MaskCombineOperation? {
    effectiveSelectionCombine(sticky: magnetSelectionTool.combine)
  }

  /// Resolves a selection tool's sticky operation and the conventional
  /// Shift/Option one-gesture override.
  private func effectiveSelectionCombine(
    sticky: MaskCombineOperation?
  ) -> MaskCombineOperation? {
    guard recipe.selection != nil else { return nil }
    let modifiers = currentModifiers.intersection([.shift, .option])
    if modifiers.contains([.shift, .option]) { return .intersect }
    if modifiers.contains(.shift) { return .add }
    if modifiers.contains(.option) { return .subtract }
    return sticky
  }

  /// Rewrites the gesture's geometry from where the pointer is now.
  private func updateSelectionGesture(_ drag: SelectionDrag, pointer: CGPoint) {
    var updated = drag
    let current = documentPoint(fromView: pointer)
    if drag.kind == .polygon {
      // Only meaningful movement is recorded, so a paused pointer does not
      // spend the polygon's point budget standing still.
      let spacing = freehandPointSpacingInCanvasPixels
      if let last = updated.points.last, canvasDistance(from: last, to: current) < spacing {
        return
      }
      guard updated.points.count < MaskLimits.maximumPolygonPoints else { return }
      updated.points.append(current)
    }
    selectionDrag = updated
    // The draft comes straight back through the document and repaints the ants,
    // so there is nothing to redraw here.
    send(.updateSelectionDraft(selection(for: updated, pointer: pointer)))
  }

  /// The selection the gesture describes right now: its new component joined
  /// onto whatever it started from.
  private func selection(for drag: SelectionDrag, pointer: CGPoint) -> MaskRecipe? {
    guard let generator = generator(for: drag, pointer: pointer) else {
      return drag.selectionAtStart
    }
    guard let existing = drag.selectionAtStart, let combine = drag.combine else {
      return .selecting(generator, feather: selectionTool.feather)
    }
    return existing.combining(generator, using: combine, feather: selectionTool.feather)
  }

  /// The geometry the gesture has drawn, or `nil` when it has drawn nothing
  /// worth keeping yet.
  private func generator(for drag: SelectionDrag, pointer: CGPoint) -> MaskGenerator? {
    switch drag.kind {
    case .polygon:
      let polygon = PolygonMask(points: drag.points)
      return polygon.isEmpty ? nil : .polygon(polygon)
    case .rectangle, .ellipse:
      let geometryModifiers = currentModifiers.subtracting(drag.consumedCombineModifiers)
      let drawn = marqueeShape(
        from: drag.startDocument,
        to: documentPoint(fromView: pointer),
        modifiers: geometryModifiers
      )
      if drag.kind == .ellipse {
        return drawn.isEmpty ? nil : .ellipse(drawn)
      }
      // Snapped before the emptiness check, so a drag that covered no whole
      // pixel is the click it looks like and deselects.
      let snapped = SelectionGeometry.pixelSnapped(drawn, in: recipe.layerStack.canvas)
      return snapped.isEmpty ? nil : .rectangle(snapped)
    default:
      return nil
    }
  }

  /// The rectangle a marquee drag describes, with the modifier behaviour every
  /// editor shares: shift makes it square, option grows it from its anchor
  /// rather than from a corner.
  ///
  /// Squareness is measured in canvas pixels, not in normalized coordinates,
  /// so a square on a non-square canvas actually looks square.
  private func marqueeShape(
    from start: VectorPoint,
    to end: VectorPoint,
    modifiers: NSEvent.ModifierFlags
  ) -> ShapeMask {
    var deltaX = end.x - start.x
    var deltaY = end.y - start.y
    if modifiers.contains(.shift) {
      let width = max(abs(deltaX) * aspectWidthWeight, abs(deltaY) * aspectHeightWeight)
      deltaX = (deltaX < 0 ? -1 : 1) * width / aspectWidthWeight
      deltaY = (deltaY < 0 ? -1 : 1) * width / aspectHeightWeight
    }
    // Option grows the rectangle from its anchor, so the press point becomes
    // the center and the drag reaches equally far the other way.
    let anchor =
      modifiers.contains(.option)
      ? VectorPoint(x: start.x - deltaX, y: start.y - deltaY)
      : start
    return ShapeMask(
      from: anchor,
      to: VectorPoint(x: start.x + deltaX, y: start.y + deltaY),
      cornerRadius: normalizedSelectionCornerRadius
    )
  }

  /// The marquee's corner radius as the recipe stores it: a fraction of the
  /// shorter canvas edge. The panel holds canvas pixels because that is what a
  /// user measures in, and this is the one place the two meet — the same
  /// conversion the shape tool makes for its own corner radius.
  private var normalizedSelectionCornerRadius: Double {
    guard selectionTool.shape == .rectangle else { return 0 }
    let canvas = recipe.layerStack.canvas
    guard canvas.isResolved else { return 0 }
    return selectionTool.cornerRadius / Double(min(canvas.width, canvas.height))
  }

  /// Ends the gesture as one undoable step.
  ///
  /// A new drag that enclosed nothing is a click on the canvas and deselects.
  /// An empty add, subtract or intersect gesture leaves the existing selection
  /// untouched.
  private func finishSelectionGesture(_ drag: SelectionDrag, pointer: CGPoint) {
    selectionDrag = nil
    var completed = drag
    if completed.kind == .polygon,
      completed.points.count < MaskLimits.maximumPolygonPoints
    {
      let release = documentPoint(fromView: pointer)
      if let last = completed.points.last,
        canvasDistance(from: last, to: release) >= freehandPointSpacingInCanvasPixels
      {
        completed.points.append(release)
      }
    }
    guard let generator = generator(for: completed, pointer: pointer) else {
      if drag.selectionAtStart != nil, drag.combine != nil {
        send(.cancelSelectionDraft)
        return
      }
      send(.commitSelection(nil, actionName: "Deselect"))
      return
    }
    let committed = selection(for: completed, pointer: pointer)
    send(.commitSelection(committed, actionName: selectionActionName(completed, generator)))
  }

  private func selectionActionName(
    _ drag: SelectionDrag,
    _ generator: MaskGenerator
  ) -> String {
    guard drag.selectionAtStart != nil, let combine = drag.combine else {
      return "\(generator.label) Selection"
    }
    switch combine {
    case .add: return "Add to Selection"
    case .subtract: return "Subtract from Selection"
    case .intersect: return "Intersect Selection"
    }
  }

  private func cancelSelectionGesture() {
    guard selectionDrag != nil else { return }
    selectionDrag = nil
    send(.cancelSelectionDraft)
  }

  private func canvasDistance(from first: VectorPoint, to second: VectorPoint) -> Double {
    let size = referenceSize
    return hypot(
      (second.x - first.x) * Double(size.width),
      (second.y - first.y) * Double(size.height)
    )
  }

  // MARK: Marching ants

  private func configureSelectionAnts() {
    for shape in [selectionAntsUnderlayLayer, selectionAntsLayer] {
      shape.fillColor = nil
      shape.zPosition = 6
      shape.isHidden = true
      // Implicit animation would tween the path between two unrelated outlines
      // on every pointer event, which reads as the selection sliding around.
      shape.actions = [
        "path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull(),
        "lineDashPhase": NSNull(),
      ]
    }
    selectionAntsUnderlayLayer.strokeColor = NSColor.black.withAlphaComponent(0.7).cgColor
    selectionAntsLayer.strokeColor = NSColor.white.cgColor
    selectionAntsLayer.lineDashPattern = [NSNumber(value: 4), NSNumber(value: 4)]

    // One animation, installed once and left running for the life of the view.
    // It is a two-property change on a layer that is usually hidden, so it
    // costs nothing when there is no selection and never touches the recipe.
    let march = CABasicAnimation(keyPath: "lineDashPhase")
    march.fromValue = 0
    march.toValue = 8
    march.duration = 0.5
    march.repeatCount = .infinity
    march.isRemovedOnCompletion = false
    selectionAntsLayer.add(march, forKey: "marchingAnts")
  }

  private func configureSelectionMeasurement() {
    selectionMeasurementLayer.zPosition = 21
    selectionMeasurementLayer.isHidden = true
    selectionMeasurementLayer.alignmentMode = .center
    selectionMeasurementLayer.font = NSFont.monospacedDigitSystemFont(
      ofSize: 12, weight: .semibold)
    selectionMeasurementLayer.fontSize = 12
    selectionMeasurementLayer.foregroundColor = NSColor.labelColor.cgColor
    selectionMeasurementLayer.backgroundColor = NSColor.windowBackgroundColor
      .withAlphaComponent(0.92).cgColor
    selectionMeasurementLayer.cornerRadius = 5
    selectionMeasurementLayer.actions = [
      "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "string": NSNull(),
    ]
  }

  /// The measurement follows the pointer during a selection gesture only. A
  /// combined draft may contain older components, so read the current drag's
  /// generator rather than measuring the entire selection outline.
  private func refreshSelectionMeasurement() {
    guard let selectionDrag,
      let generator = generator(for: selectionDrag, pointer: lastMouseInView),
      let measurement = SelectionMeasurement.measure(
        generator, in: recipe.layerStack.canvas)
    else {
      selectionMeasurementLayer.isHidden = true
      return
    }

    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    let label = measurement.label
    let textSize = (label as NSString).size(withAttributes: [.font: font])
    let width = ceil(textSize.width) + 16
    let height = ceil(textSize.height) + 7
    let margin: CGFloat = 8
    let preferredX = lastMouseInView.x + 14
    let x = preferredX + width + margin <= bounds.maxX
      ? preferredX : max(bounds.minX + margin, lastMouseInView.x - width - 14)
    let preferredY = lastMouseInView.y - height - 14
    let y = preferredY >= bounds.minY + margin
      ? preferredY : min(bounds.maxY - height - margin, lastMouseInView.y + 14)
    selectionMeasurementLayer.string = label
    selectionMeasurementLayer.foregroundColor = NSColor.labelColor.cgColor
    selectionMeasurementLayer.backgroundColor = NSColor.windowBackgroundColor
      .withAlphaComponent(0.92).cgColor
    selectionMeasurementLayer.contentsScale = window?.backingScaleFactor ?? 2
    selectionMeasurementLayer.frame = CGRect(x: x, y: y, width: width, height: height)
    selectionMeasurementLayer.isHidden = false
  }

  /// Points the ants at the current selection and redraws their outline.
  ///
  /// Called whenever the selection or the viewport changes. It never triggers a
  /// render: the selection is an overlay over the frame already on screen.
  private func refreshSelectionAnts() {
    refreshSelectionMeasurement()
    // The draft wins while a gesture holds; otherwise the document's selection
    // is what is outlined, so the ants stay up after switching tools.
    guard let selection = selectionDraft ?? recipe.selection,
      let path = selectionOutline(selection)
    else {
      selectionAntsLayer.isHidden = true
      selectionAntsUnderlayLayer.isHidden = true
      return
    }
    let hairline = 1 / (window?.backingScaleFactor ?? 2)
    for shape in [selectionAntsUnderlayLayer, selectionAntsLayer] {
      shape.frame = bounds
      shape.path = path
      // A hairline in view points, so the outline stays the same weight at any
      // zoom instead of thickening with the image.
      shape.lineWidth = max(hairline, 1)
      shape.contentsScale = window?.backingScaleFactor ?? 2
      shape.isHidden = false
    }
  }

  /// Resolves add, subtract, intersect, component inversion and whole-selection
  /// inversion before drawing, so the ants describe the area that will be used.
  private func selectionOutline(_ selection: MaskRecipe) -> CGPath? {
    let size = referenceSize
    guard size.width > 0, size.height > 0 else { return nil }
    let canonicalPath: CGPath
    if let cachedSelectionOutline,
      cachedSelectionOutline.selection == selection,
      cachedSelectionOutline.canvasSize == size
    {
      canonicalPath = cachedSelectionOutline.path
    } else {
      guard let path = SelectionGeometry.path(
        for: selection,
        in: CGRect(origin: .zero, size: size))
      else { return nil }
      cachedSelectionOutline = (selection, size, path)
      canonicalPath = path
    }

    let destination = imageRectInView()
    var transform = CGAffineTransform(
      a: destination.width / size.width,
      b: 0,
      c: 0,
      d: destination.height / size.height,
      tx: destination.minX,
      ty: destination.minY)
    return canonicalPath.copy(using: &transform)
  }

  private func outline(for generator: MaskGenerator) -> CGPath? {
    switch generator {
    case .rectangle(let shape):
      guard !shape.isEmpty else { return nil }
      return SelectionGeometry.path(for: generator, in: imageRectInView())
    case .ellipse(let shape):
      guard !shape.isEmpty else { return nil }
      return SelectionGeometry.path(for: generator, in: imageRectInView())
    case .polygon(let polygon):
      guard !polygon.isEmpty else { return nil }
      return SelectionGeometry.path(for: generator, in: imageRectInView())
    default:
      return nil
    }
  }

  private func viewRect(fromDocument shape: ShapeMask) -> CGRect {
    let origin = viewPoint(fromDocument: shape.origin)
    let opposite = viewPoint(fromDocument: VectorPoint(x: shape.maxX, y: shape.maxY))
    return CGRect(
      x: min(origin.x, opposite.x),
      y: min(origin.y, opposite.y),
      width: abs(opposite.x - origin.x),
      height: abs(opposite.y - origin.y)
    )
  }

  // MARK: - Masks
  //
  // The canvas places mask components; it never decides what a mask means. It
  // reads the masks tool's settings, builds the `MaskRecipe` the gesture asks
  // for, and sends it as a typed action. Everything about how that mask is
  // evaluated lives in the domain model and the render engine.

  /// The layer a new mask would be attached to: the selected one, unless that
  /// is the canvas, which carries the document extent rather than pixels.
  private var maskTargetLayer: ProjectLayer? {
    guard let id = recipe.layerStack.activeLayerID,
      let layer = recipe.layerStack.layer(id: id),
      !layer.isCanvasLayer
    else { return nil }
    return layer
  }

  /// Starts placing a mask component, or samples one outright.
  ///
  /// Returns `false` when the press is not a mask placement, so the caller
  /// falls through to panning and the viewport stays reachable.
  private func beginMaskPlacement(at point: CGPoint) -> Bool {
    guard imageRectInView().contains(point), let layer = maskTargetLayer else { return false }
    let kind = maskTool.generatorKind
    guard kind.availability.isAvailable, kind.needsCanvasPlacement else { return false }

    let document = documentPoint(fromView: point)
    switch kind {
    case .luminanceRange, .colorRange:
      // A range is sampled from the pixel under the pointer in one step; there
      // is nothing to drag.
      return sampleRange(kind, at: point, document: document, on: layer)
    case .linearGradient, .radialGradient, .brush, .rectangle, .ellipse, .polygon:
      break
    default:
      return false
    }

    let component = MaskComponent(
      generator: kind.defaultGenerator(at: document),
      combine: maskTool.combine,
      feather: maskTool.feather
    )
    let maskBeforeGesture: MaskRecipe? = if maskTool.activeLayerID == layer.id,
      let maskID = maskTool.activeMaskID
    {
      layer.mask(id: maskID)
    } else {
      nil
    }
    beginEditGesture()
    let mask = attachComponent(component, to: layer, kind: kind)
    maskDrag = MaskDrag(
      layerID: layer.id,
      kind: kind,
      maskBeforeGesture: maskBeforeGesture,
      maskAtGestureStart: mask,
      componentID: component.id,
      startDocument: document,
      points: [document]
    )
    rebuildOverlays()
    return true
  }

  /// Rewrites the component being dragged from the gesture's starting point to
  /// where the pointer is now.
  private func updateMaskPlacement(_ drag: MaskDrag, pointer: CGPoint) {
    var drag = drag
    let current = documentPoint(fromView: pointer)
    let generator: MaskGenerator
    switch drag.kind {
    // Rectangles, ellipses and freehand outlines are drawn the same way here as
    // by the selection tools; only where the result is stored differs.
    case .rectangle, .ellipse:
      let shape = marqueeShape(
        from: drag.startDocument,
        to: current,
        modifiers: currentModifiers
      )
      generator = drag.kind == .ellipse ? .ellipse(shape) : .rectangle(shape)
    case .polygon:
      let spacing = freehandPointSpacingInCanvasPixels
      if drag.points.count < MaskLimits.maximumPolygonPoints,
        let last = drag.points.last, canvasDistance(from: last, to: current) >= spacing
      {
        drag.points.append(current)
      }
      maskDrag = drag
      generator = .polygon(PolygonMask(points: drag.points))
    case .linearGradient:
      generator = .linearGradient(
        LinearGradientMask(start: drag.startDocument, end: current))
    case .radialGradient:
      // The drag distance is the radius, measured against the shorter canvas
      // edge so it means the same thing as the stored fraction.
      let dx = (current.x - drag.startDocument.x) * aspectWidthWeight
      let dy = (current.y - drag.startDocument.y) * aspectHeightWeight
      generator = .radialGradient(
        RadialGradientMask(
          center: drag.startDocument,
          radius: max(hypot(dx, dy), 0.01)
        ))
    default:
      return
    }
    let mask = drag.maskAtGestureStart.updatingComponent(drag.componentID) {
      $0.generator = generator
    }
    recipe.layerStack = recipe.layerStack.settingMask(mask, on: drag.layerID)
    send(
      .change(
        .setMask(drag.layerID, mask, actionName: "Place \(drag.kind.label) Mask"),
        interactive: true
      ))
    rebuildOverlays()
  }

  /// Normalized document coordinates are relative to each axis, so a radius
  /// measured against the shorter edge needs the axes weighted back to square.
  private var aspectWidthWeight: Double {
    let size = referenceSize
    guard size.width > 0, size.height > 0 else { return 1 }
    return Double(size.width / min(size.width, size.height))
  }

  private var aspectHeightWeight: Double {
    let size = referenceSize
    guard size.width > 0, size.height > 0 else { return 1 }
    return Double(size.height / min(size.width, size.height))
  }

  /// Samples the pixel under the pointer and adds a luminance or color range
  /// centered on it. One click, one undoable step.
  private func sampleRange(
    _ kind: MaskGeneratorKind,
    at point: CGPoint,
    document: VectorPoint,
    on layer: ProjectLayer
  ) -> Bool {
    guard let sample = sampledPixel(atView: point) else { return false }
    let generator: MaskGenerator =
      kind == .luminanceRange
      ? .luminanceRange(.sampling(sample.luminance))
      : .colorRange(ColorRangeMask(sample: sample.color))
    let component = MaskComponent(
      generator: generator,
      combine: maskTool.combine,
      feather: maskTool.feather
    )
    beginEditGesture()
    _ = attachComponent(component, to: layer, kind: kind)
    endEditGesture("Sample \(kind.label) Mask")
    rebuildOverlays()
    return true
  }

  private func updateCropDrag(_ drag: CropDrag, pointer: CGPoint) {
    guard let size = cropImageSize, let unit = cropUnitPoint(fromView: pointer) else { return }
    let width = Double(size.width)
    let height = Double(size.height)

    let updated: CropRecipe
    switch drag.mode {
    case .resize(let handle):
      updated = CropGeometry.resized(
        drag.startCrop,
        handle: handle,
        toUnitX: unit.x,
        unitY: unit.y,
        imageWidth: width,
        imageHeight: height
      )
    case .move:
      guard let start = cropUnitPoint(fromView: drag.startPointerInView) else { return }
      updated = CropGeometry.moved(
        drag.startCrop,
        byUnitX: unit.x - start.x,
        unitY: unit.y - start.y,
        imageWidth: width,
        imageHeight: height
      )
    case .create(let startX, let startY):
      updated = CropGeometry.created(
        fromUnitX: startX,
        unitY: startY,
        toUnitX: unit.x,
        unitY: unit.y,
        like: drag.startCrop,
        imageWidth: width,
        imageHeight: height
      )
    }
    guard let current = cropDraft, updated != current.recipe else { return }
    cropDraft = CropDraft(target: current.target, recipe: updated, revealsFullTarget: true)
    send(.updateCropDraft(updated, interactive: true))
    rebuildOverlays()
  }

  /// Arrow keys move the crop rectangle by whole image pixels.
  private func nudgeCrop(keyCode: UInt16, large: Bool) {
    guard let draft = cropDraft, let size = cropImageSize else { return }
    let crop = draft.recipe
    let width = Double(size.width)
    let height = Double(size.height)
    let distance = large ? largeLayerNudgeInCanvasPixels : layerNudgeInCanvasPixels
    var deltaX = 0.0
    var deltaY = 0.0
    switch keyCode {
    case 123: deltaX = -distance / width
    case 124: deltaX = distance / width
    case 125: deltaY = -distance / height
    default: deltaY = distance / height
    }
    let updated = CropGeometry.moved(
      crop,
      byUnitX: deltaX,
      unitY: deltaY,
      imageWidth: width,
      imageHeight: height
    )
    guard updated != crop else { return }
    cropDraft = CropDraft(target: draft.target, recipe: updated, revealsFullTarget: true)
    send(.updateCropDraft(updated, interactive: false))
    rebuildOverlays()
  }

  // MARK: - Crop overlay
  //
  // Drawn into the interaction layer, like every other tool's furniture: the
  // area outside the rectangle is dimmed, the rectangle is outlined, its eight
  // handles are drawn as corner brackets and edge bars, and the chosen guide
  // overlay is ruled inside it. Nothing here mutates the draft.

  private func drawCropOverlay(_ crop: CropRecipe) {
    let imageRect = imageRectInView()
    guard !imageRect.isEmpty else { return }
    let rect = cropRectInView(crop)
    guard !rect.isEmpty else { return }
    let contentsScale = window?.backingScaleFactor ?? 2

    // The dim is one even-odd path: the whole view with the crop punched out,
    // so the kept area reads at full brightness against a darkened surround.
    let shade = CGMutablePath()
    shade.addRect(bounds)
    shade.addRect(rect)
    let dim = CAShapeLayer()
    dim.path = shade
    dim.fillRule = .evenOdd
    dim.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
    dim.strokeColor = nil
    dim.contentsScale = contentsScale
    interactionLayer.addSublayer(dim)

    drawCropGuides(crop, in: rect, contentsScale: contentsScale)

    let outline = CAShapeLayer()
    outline.path = CGPath(rect: rect, transform: nil)
    outline.fillColor = nil
    outline.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
    outline.lineWidth = 1
    outline.contentsScale = contentsScale
    interactionLayer.addSublayer(outline)

    for handle in CropHandle.allCases {
      drawCropHandle(handle, in: rect, contentsScale: contentsScale)
    }
  }

  private func drawCropGuides(_ crop: CropRecipe, in rect: CGRect, contentsScale: CGFloat) {
    let fractions = cropGuideFractions(crop.overlay)
    guard !fractions.horizontal.isEmpty || !fractions.vertical.isEmpty else { return }
    let path = CGMutablePath()
    for fraction in fractions.vertical {
      let x = rect.minX + rect.width * CGFloat(fraction)
      path.move(to: CGPoint(x: x, y: rect.minY))
      path.addLine(to: CGPoint(x: x, y: rect.maxY))
    }
    for fraction in fractions.horizontal {
      let y = rect.minY + rect.height * CGFloat(fraction)
      path.move(to: CGPoint(x: rect.minX, y: y))
      path.addLine(to: CGPoint(x: rect.maxX, y: y))
    }
    let guides = CAShapeLayer()
    guides.path = path
    guides.fillColor = nil
    guides.strokeColor = NSColor.white.withAlphaComponent(0.4).cgColor
    guides.lineWidth = 1
    guides.contentsScale = contentsScale
    interactionLayer.addSublayer(guides)
  }

  /// Where the chosen overlay rules its lines, as fractions of the rectangle.
  private func cropGuideFractions(
    _ overlay: CropOverlay
  ) -> (vertical: [Double], horizontal: [Double]) {
    switch overlay {
    case .none:
      return ([], [])
    case .thirds:
      return ([1.0 / 3, 2.0 / 3], [1.0 / 3, 2.0 / 3])
    case .grid:
      let steps = stride(from: 0.125, to: 1.0, by: 0.125).map { $0 }
      return (steps, steps)
    case .golden:
      // The golden section, 1/φ ≈ 0.618, and its mirror.
      let phi = 1 - 1 / 1.618_033_988_749_895
      return ([phi, 1 - phi], [phi, 1 - phi])
    }
  }

  private func drawCropHandle(_ handle: CropHandle, in rect: CGRect, contentsScale: CGFloat) {
    let length = cropHandleLengthInPoints
    let thickness: CGFloat = 3
    let path = CGMutablePath()

    switch handle {
    case .left, .right:
      let x = handle == .left ? rect.minX : rect.maxX
      let height = min(length, rect.height)
      path.addRect(
        CGRect(
          x: x - thickness / 2, y: rect.midY - height / 2, width: thickness, height: height))
    case .bottom, .top:
      let y = handle == .bottom ? rect.minY : rect.maxY
      let width = min(length, rect.width)
      path.addRect(
        CGRect(x: rect.midX - width / 2, y: y - thickness / 2, width: width, height: thickness))
    default:
      // A corner is an L of two bars pointing along the two edges it holds.
      let x = handle.movesLeftEdge ? rect.minX : rect.maxX
      let y = handle.movesBottomEdge ? rect.minY : rect.maxY
      let horizontalWidth = min(length, rect.width)
      let verticalHeight = min(length, rect.height)
      let horizontalX =
        handle.movesLeftEdge ? x - thickness / 2 : x - horizontalWidth + thickness / 2
      let verticalY =
        handle.movesBottomEdge ? y - thickness / 2 : y - verticalHeight + thickness / 2
      path.addRect(
        CGRect(x: horizontalX, y: y - thickness / 2, width: horizontalWidth, height: thickness))
      path.addRect(
        CGRect(x: x - thickness / 2, y: verticalY, width: thickness, height: verticalHeight))
    }

    let shape = CAShapeLayer()
    shape.path = path
    let draggedHandle: CropHandle? = {
      guard let cropDrag, case .resize(let handle) = cropDrag.mode else { return nil }
      return handle
    }()
    let isActive = draggedHandle == handle || (cropDrag == nil && hoveredCropHandle == handle)
    shape.fillColor =
      isActive ? NSColor.controlAccentColor.cgColor : NSColor.white.withAlphaComponent(0.95).cgColor
    shape.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
    shape.lineWidth = 0.5
    shape.contentsScale = contentsScale
    interactionLayer.addSublayer(shape)
  }
  /// Puts a component into the mask the tool is aimed at, or starts a new mask
  /// when it is aimed at none. Returns the mask as it now stands.
  private func attachComponent(
    _ component: MaskComponent,
    to layer: ProjectLayer,
    kind: MaskGeneratorKind
  ) -> MaskRecipe {
    if maskTool.activeLayerID == layer.id, let maskID = maskTool.activeMaskID,
      let existing = layer.mask(id: maskID)
    {
      let mask = existing.adding(component)
      recipe.layerStack = recipe.layerStack.settingMask(mask, on: layer.id)
      send(
        .change(
          .setMask(layer.id, mask, actionName: "Add \(kind.label) to Mask"),
          interactive: false
        ))
      return mask
    }
    let mask = MaskRecipe(
      name: layer.availableMaskName(kind.label),
      components: [component]
    )
    recipe.layerStack = recipe.layerStack.addingMask(mask, to: layer.id)
    send(.change(.addMask(layer.id, mask), interactive: false))
    send(.activateMask(mask.id, on: layer.id))
    return mask
  }

  private func cancelMaskDrag() {
    guard let maskDrag else { return }
    self.maskDrag = nil
    if let original = maskDrag.maskBeforeGesture {
      recipe.layerStack = recipe.layerStack.settingMask(original, on: maskDrag.layerID)
      send(
        .change(
          .setMask(
            maskDrag.layerID,
            original,
            actionName: "Place \(maskDrag.kind.label) Mask"
          ),
          interactive: false
        ))
    } else {
      recipe.layerStack = recipe.layerStack.removingMask(
        maskDrag.maskAtGestureStart.id,
        from: maskDrag.layerID
      )
      send(
        .change(
          .removeMask(maskDrag.layerID, maskDrag.maskAtGestureStart.id),
          interactive: false
        ))
      send(.activateMask(nil, on: maskDrag.layerID))
    }
    endEditGesture("Place \(maskDrag.kind.label) Mask")
    rebuildOverlays()
  }

  /// The pixel under the pointer, as a Display P3 color and as a linear
  /// working-space luminance.
  ///
  /// Two one-pixel renders: `VectorColor` is written in Display P3 like every
  /// other stored color, while a luminance range's bounds are in the linear
  /// working space, so each is read in the space it belongs to.
  private func sampledPixel(atView point: CGPoint) -> (color: VectorColor, luminance: Double)? {
    guard let frameImage = contentImage else { return nil }
    let rect = imageRectInView()
    guard rect.width > 0, rect.height > 0 else { return nil }
    let u = (point.x - rect.minX) / rect.width
    let v = (point.y - rect.minY) / rect.height
    guard (0...1).contains(u), (0...1).contains(v) else { return nil }
    let extent = frameImage.extent
    guard !extent.isEmpty else { return nil }
    let pixel = CGRect(
      x: (extent.minX + u * extent.width).rounded(.down),
      y: (extent.minY + v * extent.height).rounded(.down),
      width: 1,
      height: 1
    ).intersection(extent)
    guard !pixel.isEmpty else { return nil }

    var display = [Float](repeating: 0, count: 4)
    imageContext.render(
      frameImage,
      toBitmap: &display,
      rowBytes: 16,
      bounds: pixel,
      format: .RGBAf,
      colorSpace: displayColorSpace
    )
    var linear = [Float](repeating: 0, count: 4)
    imageContext.render(
      frameImage,
      toBitmap: &linear,
      rowBytes: 16,
      bounds: pixel,
      format: .RGBAf,
      colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    )
    let luminance =
      0.2126 * Double(linear[0]) + 0.7152 * Double(linear[1]) + 0.0722 * Double(linear[2])
    return (
      VectorColor(
        red: Double(display[0]),
        green: Double(display[1]),
        blue: Double(display[2])
      ),
      luminance
    )
  }

  /// Outlines the active mask's gradient geometry, so a placed gradient can be
  /// seen and re-dragged rather than only inferred from the pixels.
  private func drawMaskGuides() {
    guard let layerID = maskTool.activeLayerID, let maskID = maskTool.activeMaskID,
      let mask = recipe.layerStack.mask(maskID, on: layerID), mask.isEnabled
    else { return }
    let contentsScale = window?.backingScaleFactor ?? 2
    for component in mask.components where component.isEnabled {
      let path = CGMutablePath()
      switch component.generator {
      case .linearGradient(let gradient):
        let start = viewPoint(fromDocument: gradient.start)
        let end = viewPoint(fromDocument: gradient.end)
        path.move(to: start)
        path.addLine(to: end)
        path.addEllipse(in: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8))
        path.addEllipse(in: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
      case .radialGradient(let gradient):
        let center = viewPoint(fromDocument: gradient.center)
        let rect = imageRectInView()
        let radius = CGFloat(gradient.radius) * min(rect.width, rect.height)
        path.addEllipse(
          in: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        path.addEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
      case .rectangle, .ellipse, .polygon:
        // Drawn geometry has a boundary, so the guide is that boundary. The
        // selection tools trace the same shapes through the same helper.
        guard let shape = outline(for: component.generator) else { continue }
        path.addPath(shape)
      default:
        continue
      }
      let underlay = CAShapeLayer()
      underlay.path = path
      underlay.fillColor = nil
      underlay.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
      underlay.lineWidth = 2
      underlay.contentsScale = contentsScale
      interactionLayer.addSublayer(underlay)

      let outline = CAShapeLayer()
      outline.path = path
      outline.fillColor = nil
      outline.strokeColor = NSColor.controlAccentColor.cgColor
      outline.lineWidth = 1
      outline.lineDashPattern = [NSNumber(value: 4), NSNumber(value: 3)]
      outline.contentsScale = contentsScale
      interactionLayer.addSublayer(outline)
    }
  }

  /// Abandons whatever gesture is in flight, whichever tool started it.
  private func beginEditGesture() {
    precondition(!hasOpenEditGesture, "Canvas edit gestures must not overlap")
    hasOpenEditGesture = true
    send(.beginGesture)
  }

  private func endEditGesture(_ actionName: String) {
    precondition(hasOpenEditGesture, "A canvas edit gesture must begin before it ends")
    hasOpenEditGesture = false
    send(.endGesture(actionName))
  }

  private func cancelActiveGesture() {
    guard let activeGesture else {
      restoreMouseCoalescingState()
      precondition(!hasOpenEditGesture, "An edit gesture cannot outlive its canvas gesture")
      return
    }
    switch activeGesture {
    case .gradientHandle:
      cancelGradientHandleDrag()
    case .vectorObjects, .vectorMarquee:
      cancelVectorObjectGesture()
    case .guide:
      cancelGuideDrag()
    case .layer:
      cancelLayerDrag()
    case .mask:
      cancelMaskDrag()
    case .selection:
      cancelSelectionGesture()
    case .brush:
      cancelBrushGesture()
    case .provisional, .directEdit, .penClick:
      cancelProvisionalGesture()
    case .creative, .crop, .pan, .transform:
      self.activeGesture = nil
      rebuildOverlays()
    }
    precondition(self.activeGesture == nil, "Cancelling must leave the canvas idle")
    precondition(!hasOpenEditGesture, "Cancelling must close the canvas edit gesture")
  }

  /// Puts back the geometry a move was dragging and drops the rubber band.
  private func cancelVectorObjectGesture() {
    if let marquee = vectorObjectMarquee,
      selectedVectorObjectIDs != marquee.selectionAtStart
    {
      selectedVectorObjectIDs = marquee.selectionAtStart
      send(.setVectorObjectSelection(marquee.selectionAtStart))
    }
    vectorObjectMarquee = nil
    canvasSnap = nil
    guard let drag = vectorObjectDrag else { return }
    vectorObjectDrag = nil
    guard drag.didBeginGesture else { return }
    var stack = recipe.layerStack
    stack.updateLayer(id: drag.layerID) { layer in
      guard case .vector = layer.content else { return }
      layer.content = .vector(drag.originalLayer)
    }
    recipe.layerStack = stack
    send(.change(.setLayerStack(stack, actionName: "Move Vector Objects"), interactive: false))
    endEditGesture("Move Vector Objects")
    rebuildOverlays()
  }

  private func cancelBrushGesture() {
    guard brushGesture != nil else { return }
    brushGesture = nil
    brushSequence = 0
    restoreMouseCoalescingState()
    send(.cancelBrushStroke)
    rebuildOverlays()
  }

  private func beginHighFidelityBrushInput() {
    guard previousMouseCoalescingState == nil else { return }
    // Unlike UIKit, AppKit does not expose the individual events folded into a
    // coalesced mouse event. Temporarily ask it to deliver every available
    // drag/tablet point, then restore the app's prior policy at gesture end.
    previousMouseCoalescingState = NSEvent.isMouseCoalescingEnabled
    NSEvent.isMouseCoalescingEnabled = false
  }

  private func restoreMouseCoalescingState() {
    guard let previousMouseCoalescingState else { return }
    NSEvent.isMouseCoalescingEnabled = previousMouseCoalescingState
    self.previousMouseCoalescingState = nil
  }

  private func brushSamples(from event: NSEvent) -> [BrushSample] {
    // Tablet points arrive through the mouse-drag stream; the deterministic
    // interpolator still fills distance gaps between delivered events.
    [event].compactMap { brushSample(from: $0) }
  }

  private func brushSample(from event: NSEvent) -> BrushSample? {
    let pointInView = convert(event.locationInWindow, from: nil)
    guard let point = coordinateTransform.canvasPoint(fromView: pointInView) else { return nil }
    let tablet = event.type == .tabletPoint || event.subtype == .tabletPoint
    let tilt = tablet ? event.tilt : .zero
    let pressure = tablet ? Double(event.pressure) : 1
    let sample = BrushSample(
      x: point.x,
      y: point.y,
      pressure: pressure,
      tiltX: Double(tilt.x),
      tiltY: Double(tilt.y),
      rotationDegrees: tablet ? Double(event.rotation) : 0,
      reportsRotation: tablet,
      elapsedTime: max(event.timestamp - brushStartTimestamp, 0),
      sequence: brushSequence
    )
    brushSequence &+= 1
    return sample
  }

  /// Ends a guide drag without keeping what it was making.
  ///
  /// A guide pulled out of a ruler is taken back, because it was never
  /// anywhere the user could see it as finished; one that was already on the
  /// canvas simply stays where the drag left it.
  private func cancelGuideDrag() {
    guard let drag = guideDrag else { return }
    guideDrag = nil
    if drag.isNew, drag.hasBeenAdded {
      send(
        .change(
          .setCanvasSettings(
            recipe.canvasSettings.removing(drag.guide.id),
            actionName: "Add Guide"
          ),
          interactive: false
        ))
    }
    endEditGesture(drag.isNew ? "Add Guide" : "Move Guide")
    rebuildOverlays()
  }

  private func cancelProvisionalGesture() {
    provisional = nil
    pendingClickTarget = nil
    isSpacePressed = false
    activeSnapTarget = nil
    if let directEdit {
      recipe.layerStack = directEdit.originalStack
      send(
        .change(
          .setLayerStack(directEdit.originalStack, actionName: "Move Anchor or Handle"),
          interactive: false
        ))
      endEditGesture("Move Anchor or Handle")
      self.directEdit = nil
    }
    currentModifiers = []
    rebuildOverlays()
  }

  private func apply(_ stack: LayerStack, actionName: String) {
    guard stack != recipe.layerStack else { return }
    recipe.layerStack = stack
    send(.change(.setLayerStack(stack, actionName: actionName), interactive: false))
    rebuildOverlays()
  }

  private func normalizeTransientState() {
    // A drag cannot outlive the layer it moves. The layer is gone, so there is
    // nothing to put back: end the gesture and let the document keep what the
    // drag already recorded.
    if let layerDrag, recipe.layerStack.layer(id: layerDrag.layerID) == nil {
      self.layerDrag = nil
      endEditGesture("Move Layer")
    }
    // The same holds for a mask being dragged onto a layer that has just gone
    // away, or a mask an undo has removed from under the gesture.
    if let maskDrag,
      recipe.layerStack.mask(maskDrag.maskAtGestureStart.id, on: maskDrag.layerID) == nil
    {
      self.maskDrag = nil
      endEditGesture("Place \(maskDrag.kind.label) Mask")
    }
    if let activePathID, recipe.layerStack.path(id: activePathID) == nil {
      self.activePathID = nil
    }
    if let selected,
      recipe.layerStack.path(id: selected.pathID)?.path.anchors.contains(where: {
        $0.id == selected.anchorID
      }) != true
    {
      self.selected = nil
    }
  }

  // MARK: - Vector object selection

  /// Whether an anchor-and-handle press is what the pointer means right now.
  ///
  /// Direct Selection is a mode, and Command remains the transient shortcut for
  /// it while drawing, so a path can be reshaped without leaving the Pen.
  private var isDirectSelecting: Bool {
    vectorEditMode == .direct || currentModifiers.contains(.command)
  }

  /// The image's width divided by its height, which a parametric shape needs to
  /// resolve its rotation and corner radii as they read on screen.
  private var vectorAspect: Double {
    let size = vectorPixelSize
    return size.height > 0 ? Double(size.width / size.height) : 1
  }

  /// Vector geometry is normalized to the document canvas. Prefer its stored
  /// extent, which can differ from the source image after a canvas resize.
  private var vectorPixelSize: CGSize {
    let canvas = recipe.layerStack.canvas
    if canvas.isResolved {
      return CGSize(width: canvas.width, height: canvas.height)
    }
    return canonicalImageSize.width > 0 && canonicalImageSize.height > 0
      ? canonicalImageSize : referenceSize
  }

  /// The vector layer object selection acts on: the active one, as the object
  /// list shows it.
  private var activeVectorLayer: (id: ProjectLayerID, vector: VectorLayer)? {
    guard let id = recipe.layerStack.activeLayerID,
      let layer = recipe.layerStack.layer(id: id),
      case .vector(let vector) = layer.content
    else { return nil }
    return (id, vector)
  }

  /// A screen-sized grab radius expressed in the canonical pixels the vector
  /// geometry uses, so the target stays the same size at every zoom.
  private func vectorHitTolerance() -> Double {
    let rect = imageRectInView()
    guard rect.width > 0, vectorPixelSize.width > 0 else { return 0 }
    let pixelsPerPoint = Double(vectorPixelSize.width / rect.width)
    return Double(segmentHitRadiusInPoints) * pixelsPerPoint
  }

  /// Select/Move borrows the vector layer's existing object gesture. A hit on
  /// another vector layer activates it first; an empty press on the active
  /// vector layer begins a marquee instead of moving the whole layer.
  private func beginVectorObjectGesture(at point: CGPoint) -> Bool {
    guard imageRectInView().contains(point) else { return false }
    let document = documentPoint(fromView: point)
    let picked = VectorObjectPicker.pick(
      in: recipe.layerStack,
      at: document,
      pixelWidth: Double(vectorPixelSize.width),
      pixelHeight: Double(vectorPixelSize.height),
      tolerance: vectorHitTolerance()
    )
    // A non-vector layer above the vector artwork owns a click in its frame.
    let covering = topmostNonVectorLayer(at: point)
    if let covering {
      guard let vectorLayerID = picked?.layerID ?? activeVectorLayer?.id,
        let vectorIndex = recipe.layerStack.flattenedLayers.firstIndex(where: {
          $0.id == vectorLayerID
        }), covering.index > vectorIndex
      else { return false }
    }
    // A gradient handle sits on top of its own vector object. It cannot take
    // a click through a non-vector layer higher in the visual stack.
    if let active = activeVectorLayer,
      let activeIndex = recipe.layerStack.flattenedLayers.firstIndex(where: {
        $0.id == active.id
      }),
      covering.map({ $0.index > activeIndex }) ?? true,
      beginGradientHandleDrag(at: point, in: active)
    { return true }
    if let picked, picked.layerID != recipe.layerStack.activeLayerID {
      selectedVectorObjectIDs = []
      recipe.layerStack.activeLayerID = picked.layerID
      send(.selectLayer(picked.layerID))
    }
    guard let active = activeVectorLayer,
      let activeEntry = recipe.layerStack.entry(id: active.id),
      activeEntry.isEffectivelyEnabled, activeEntry.effectiveOpacity > 0,
      let local = VectorObjectPicker.localPoint(
        in: recipe.layerStack, layerID: active.id, at: document,
        pixelWidth: Double(vectorPixelSize.width),
        pixelHeight: Double(vectorPixelSize.height))
    else { return false }
    let extends = currentModifiers.contains(.shift)

    guard let hit = picked?.objectID else {
      // A press on empty canvas starts a marquee. Shift keeps what is already
      // selected so a band can add to it.
      vectorObjectMarquee = VectorObjectMarquee(
        start: local,
        current: local,
        base: extends ? selectedVectorObjectIDs : [],
        selectionAtStart: selectedVectorObjectIDs,
        isAdditive: extends
      )
      if !extends, !selectedVectorObjectIDs.isEmpty {
        selectedVectorObjectIDs = []
        send(.setVectorObjectSelection([]))
      }
      rebuildOverlays()
      return true
    }

    var next = selectedVectorObjectIDs
    if extends {
      if next.contains(hit) { next.remove(hit) } else { next.insert(hit) }
    } else if !next.contains(hit) {
      next = [hit]
    }
    if next != selectedVectorObjectIDs {
      selectedVectorObjectIDs = next
      send(.setVectorObjectSelection(next))
    }

    // A locked layer still selects, so its objects can be inspected; it just
    // does not move.
    if !next.isEmpty, recipe.layerStack.layer(id: active.id)?.isLocked != true {
      vectorObjectDrag = VectorObjectDrag(
        layerID: active.id,
        objectIDs: next,
        originalLayer: active.vector,
        startDocument: local,
        startPointerInView: point
      )
    }
    rebuildOverlays()
    return true
  }

  private func updateVectorObjectDrag(_ drag: VectorObjectDrag, pointer: CGPoint) {
    var drag = drag
    // Wait for a real drag so a plain selecting click never records an edit.
    guard drag.didBeginGesture
      || screenDistance(pointer, drag.startPointerInView) > dragThresholdInPoints
    else { return }
    if !drag.didBeginGesture {
      drag.didBeginGesture = true
      beginEditGesture()
    }

    var canvasPointer = documentPoint(fromView: pointer)
    if currentModifiers.contains(.shift) {
      // Constrain in visible canvas axes before undoing a layer transform.
      // Constraining the layer-local delta would rotate the Shift direction.
      let start = documentPoint(fromView: drag.startPointerInView)
      let dx = (canvasPointer.x - start.x) * Double(vectorPixelSize.width)
      let dy = (canvasPointer.y - start.y) * Double(vectorPixelSize.height)
      if abs(dx) >= abs(dy) { canvasPointer.y = start.y }
      else { canvasPointer.x = start.x }
    }
    guard let local = VectorObjectPicker.localPoint(
      in: recipe.layerStack, layerID: drag.layerID,
      at: canvasPointer,
      pixelWidth: Double(vectorPixelSize.width),
      pixelHeight: Double(vectorPixelSize.height))
    else { return }
    var delta = local - drag.startDocument
    delta = snappedObjectDelta(drag, delta: delta)
    vectorObjectDrag = drag

    let moved = drag.originalLayer.transformingObjects(
      ids: drag.objectIDs,
      by: .translation(x: delta.x, y: delta.y),
      aspect: vectorAspect
    )
    var stack = recipe.layerStack
    stack.updateLayer(id: drag.layerID) { layer in
      guard case .vector = layer.content else { return }
      layer.content = .vector(moved)
    }
    guard stack != recipe.layerStack else { return }
    recipe.layerStack = stack
    send(.change(.setLayerStack(stack, actionName: "Move Vector Objects"), interactive: true))
    rebuildOverlays()
  }

  /// Pulls a moving selection onto guides, the grid, the canvas edges, and the
  /// canvas center, exactly as the Move tool pulls a layer.
  ///
  /// Snapping is measured against where the objects would land unsnapped, so a
  /// drag that leaves a guide behind is released rather than dragging the snap
  /// along with it.
  private func snappedObjectDelta(
    _ drag: VectorObjectDrag, delta: VectorPoint
  ) -> VectorPoint {
    let previousSnap = canvasSnap
    canvasSnap = nil
    defer { if canvasSnap != previousSnap { rebuildOverlays() } }

    // The bounding box below is authored in the vector layer's space. Until
    // snapping maps transformed bounds, keep a transformed drag precise rather
    // than snapping it to a guide in the wrong coordinate space.
    if let entry = recipe.layerStack.entry(id: drag.layerID),
      ([entry.id] + entry.ancestorIDs).contains(where: {
        recipe.layerStack.layer(id: $0)?.transform?.isIdentity == false
      })
    { return delta }

    guard let threshold = snapThresholdInCanvasPixels,
      recipe.layerStack.canvas.isResolved,
      let box = drag.originalLayer.bounds(
        of: drag.objectIDs,
        pixelWidth: Double(vectorPixelSize.width),
        pixelHeight: Double(vectorPixelSize.height))
    else { return delta }

    let width = Double(recipe.layerStack.canvas.width)
    let height = Double(recipe.layerStack.canvas.height)
    let proposed = LayerFrame(
      x: (box.minX + delta.x) * width,
      y: (box.minY + delta.y) * height,
      width: box.width * width,
      height: box.height * height
    )
    var result = CanvasSnapping.snapOffset(
      for: proposed,
      canvas: recipe.layerStack.canvas,
      settings: recipe.canvasSettings,
      thresholdInCanvasPixels: threshold
    )
    // A Shift-constrained drag must not be pulled off its axis.
    if currentModifiers.contains(.shift) {
      if delta.x == 0 {
        result.offset.x = 0
        result.verticalLine = nil
      } else {
        result.offset.y = 0
        result.horizontalLine = nil
      }
    }
    canvasSnap = result.isEmpty ? nil : result
    return VectorPoint(
      x: delta.x + (width > 0 ? result.offset.x / width : 0),
      y: delta.y + (height > 0 ? result.offset.y / height : 0)
    )
  }

  private func updateVectorObjectMarquee(pointer: CGPoint) {
    guard var marquee = vectorObjectMarquee, let active = activeVectorLayer else { return }
    guard let local = VectorObjectPicker.localPoint(
      in: recipe.layerStack, layerID: active.id,
      at: documentPoint(fromView: pointer),
      pixelWidth: Double(vectorPixelSize.width),
      pixelHeight: Double(vectorPixelSize.height))
    else { return }
    marquee.current = local
    vectorObjectMarquee = marquee
    let hits = active.vector.objectIDs(
      intersecting: marqueeBounds(marquee),
      pixelWidth: Double(vectorPixelSize.width),
      pixelHeight: Double(vectorPixelSize.height)
    )
    let next = marquee.isAdditive ? marquee.base.union(hits) : hits
    if next != selectedVectorObjectIDs {
      selectedVectorObjectIDs = next
      send(.setVectorObjectSelection(next))
    }
    rebuildOverlays()
  }

  private func finishVectorObjectMarquee(pointer: CGPoint) {
    updateVectorObjectMarquee(pointer: pointer)
    vectorObjectMarquee = nil
    rebuildOverlays()
  }

  private func marqueeBounds(_ marquee: VectorObjectMarquee) -> VectorBounds {
    VectorBounds(
      minX: marquee.start.x,
      minY: marquee.start.y,
      maxX: marquee.current.x,
      maxY: marquee.current.y
    )
  }

  // MARK: - Gradient handles

  /// The one gradient the canvas shows handles for: a single selected object
  /// with a gradient fill. Two selections would need two sets of handles with
  /// no way to tell them apart, so the handles appear only when the answer is
  /// unambiguous.
  private func editableGradient() -> (
    layerID: ProjectLayerID, objectID: UUID, gradient: VectorGradient
  )? {
    guard activeTool == .move,
      selectedVectorObjectIDs.count == 1,
      let id = selectedVectorObjectIDs.first,
      let active = activeVectorLayer,
      let gradient = active.vector.gradient(for: id)
    else { return nil }
    return (active.id, id, gradient)
  }

  private func gradientHandlePoints(_ gradient: VectorGradient) -> [(GradientHandle, CGPoint)] {
    var points: [(GradientHandle, CGPoint)] = [
      (.start, viewPoint(fromDocument: gradient.start)),
      (.end, viewPoint(fromDocument: gradient.end)),
    ]
    if let focal = gradient.focal, gradient.kind == .radial {
      points.append((.focal, viewPoint(fromDocument: focal)))
    }
    return points
  }

  private func beginGradientHandleDrag(
    at point: CGPoint, in active: (id: ProjectLayerID, vector: VectorLayer)
  ) -> Bool {
    guard let editable = editableGradient(),
      recipe.layerStack.layer(id: active.id)?.isLocked != true
    else { return false }
    // The focal point sits inside the center handle until it is moved, so it is
    // tested first and cannot become unreachable.
    let candidates = gradientHandlePoints(editable.gradient).reversed()
    guard let hit = candidates.first(where: {
      screenDistance(point, $0.1) <= handleHitRadiusInPoints
    }) else { return false }

    gradientHandleDrag = GradientHandleDrag(
      layerID: active.id,
      objectID: editable.objectID,
      handle: hit.0,
      originalLayer: active.vector
    )
    return true
  }

  private func updateGradientHandleDrag(_ drag: GradientHandleDrag, pointer: CGPoint) {
    var drag = drag
    if !drag.didBeginGesture {
      drag.didBeginGesture = true
      beginEditGesture()
    }
    gradientHandleDrag = drag

    guard var gradient = drag.originalLayer.gradient(for: drag.objectID) else { return }
    var target = documentPoint(fromView: pointer)
    if currentModifiers.contains(.shift), drag.handle == .end {
      // Constrain the direction the way a pen handle is constrained, measured
      // in pixels so the increment reads the same on a non-square image.
      target = constrainedInPixels(target, around: gradient.start)
    }

    switch drag.handle {
    case .start:
      // Moving the origin takes the rest of the gradient with it: the ramp
      // keeps its direction and length, which is what dragging a center means.
      let delta = target - gradient.start
      gradient.start = target
      gradient.end = gradient.end + delta
      if let focal = gradient.focal { gradient.focal = focal + delta }
    case .end:
      gradient.end = target
    case .focal:
      gradient.focal = target
    }

    let updated = drag.originalLayer.settingGradient(gradient, for: drag.objectID)
    var stack = recipe.layerStack
    stack.updateLayer(id: drag.layerID) { layer in
      guard case .vector = layer.content else { return }
      layer.content = .vector(updated)
    }
    guard stack != recipe.layerStack else { return }
    recipe.layerStack = stack
    send(.change(.setLayerStack(stack, actionName: "Move Gradient"), interactive: true))
    rebuildOverlays()
  }

  /// Snaps a direction to the pen's angle increment, measured in image pixels
  /// rather than in the anisotropic normalized space.
  private func constrainedInPixels(
    _ point: VectorPoint, around origin: VectorPoint
  ) -> VectorPoint {
    let width = Double(vectorPixelSize.width)
    let height = Double(vectorPixelSize.height)
    guard width > 0, height > 0 else { return point }
    let pixel = PenGeometry.constrained(
      VectorPoint(x: point.x * width, y: point.y * height),
      relativeTo: VectorPoint(x: origin.x * width, y: origin.y * height),
      incrementDegrees: snapSettings.angleIncrementDegrees
    )
    return VectorPoint(x: pixel.x / width, y: pixel.y / height)
  }

  private func cancelGradientHandleDrag() {
    guard let drag = gradientHandleDrag else { return }
    gradientHandleDrag = nil
    guard drag.didBeginGesture else { return }
    var stack = recipe.layerStack
    stack.updateLayer(id: drag.layerID) { layer in
      guard case .vector = layer.content else { return }
      layer.content = .vector(drag.originalLayer)
    }
    recipe.layerStack = stack
    send(.change(.setLayerStack(stack, actionName: "Move Gradient"), interactive: false))
    endEditGesture("Move Gradient")
    rebuildOverlays()
  }

  /// Direction, length, center, radius, and focal point, on the object itself.
  private func drawGradientHandles() {
    guard let editable = editableGradient() else { return }
    let gradient = editable.gradient
    let points = gradientHandlePoints(gradient)
    guard let start = points.first(where: { $0.0 == .start })?.1,
      let end = points.first(where: { $0.0 == .end })?.1
    else { return }

    let axis = CGMutablePath()
    axis.move(to: start)
    axis.addLine(to: end)
    let line = CAShapeLayer()
    line.path = axis
    line.strokeColor = NSColor.controlAccentColor.cgColor
    line.lineWidth = 1.5
    line.contentsScale = window?.backingScaleFactor ?? 2
    interactionLayer.addSublayer(line)

    if gradient.kind == .radial {
      // The circle the primary radius sweeps, so the extent is visible before
      // the ellipse ratio is applied.
      let radius = screenDistance(start, end)
      let ring = CAShapeLayer()
      ring.path = CGPath(
        ellipseIn: CGRect(
          x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2),
        transform: nil)
      ring.fillColor = NSColor.clear.cgColor
      ring.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
      ring.lineWidth = 1
      ring.lineDashPattern = [4, 3]
      ring.contentsScale = window?.backingScaleFactor ?? 2
      interactionLayer.addSublayer(ring)
    }

    for (handle, center) in points {
      // Shape as well as color distinguishes the handles: the origin is a
      // square, the ramp end a circle, and the focal point a small diamond.
      let size: CGFloat = handle == .focal ? 7 : 9
      let frame = CGRect(
        x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
      let dot = CAShapeLayer()
      switch handle {
      case .start: dot.path = CGPath(rect: frame, transform: nil)
      case .end: dot.path = CGPath(ellipseIn: frame, transform: nil)
      case .focal:
        let diamond = CGMutablePath()
        diamond.move(to: CGPoint(x: frame.midX, y: frame.minY))
        diamond.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
        diamond.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
        diamond.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
        diamond.closeSubpath()
        dot.path = diamond
      }
      dot.fillColor = NSColor.windowBackgroundColor.cgColor
      dot.strokeColor = NSColor.controlAccentColor.cgColor
      dot.lineWidth = 2
      dot.contentsScale = window?.backingScaleFactor ?? 2
      interactionLayer.addSublayer(dot)
    }
  }

  /// The selected objects and the current marquee, shown while Select/Move
  /// acts on them and when a shape was just created.
  private func drawVectorObjectSelection() {
    guard let active = activeVectorLayer,
      let entry = recipe.layerStack.entry(id: active.id),
      entry.isEffectivelyEnabled, entry.effectiveOpacity > 0
    else { return }
    let pixelWidth = Double(vectorPixelSize.width)
    let pixelHeight = Double(vectorPixelSize.height)

    for id in selectedVectorObjectIDs {
      guard let object = active.vector.object(id: id) else { continue }
      if let localBox = object.boundingBox(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
        let box = VectorObjectPicker.canvasBounds(
          localBox, in: recipe.layerStack, layerID: active.id,
          pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      {
        let outline = CAShapeLayer()
        outline.path = CGPath(rect: viewRect(from: box), transform: nil)
        outline.fillColor = NSColor.clear.cgColor
        outline.strokeColor = NSColor.controlAccentColor.cgColor
        outline.lineWidth = 1.5
        // A dash as well as a color, so selection never depends on hue alone.
        outline.lineDashPattern = [5, 3]
        outline.contentsScale = window?.backingScaleFactor ?? 2
        interactionLayer.addSublayer(outline)
      }
      if activeTool == .move, let path = object.path {
        drawSelectedPathVertices(
          path, layerID: active.id, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      }
    }

    drawGradientHandles()

    if let marquee = vectorObjectMarquee {
      let band = CAShapeLayer()
      if let box = VectorObjectPicker.canvasBounds(
        marqueeBounds(marquee), in: recipe.layerStack, layerID: active.id,
        pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      {
        band.path = CGPath(rect: viewRect(from: box), transform: nil)
      }
      band.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
      band.strokeColor = NSColor.controlAccentColor.cgColor
      band.lineWidth = 1
      band.lineDashPattern = [4, 3]
      band.contentsScale = window?.backingScaleFactor ?? 2
      interactionLayer.addSublayer(band)
    }

    let count = selectedVectorObjectIDs.count
    setAccessibilityValue(
      count == 0
        ? "No vector object selected"
        : "\(count) vector object\(count == 1 ? "" : "s") selected")
  }

  /// V selects whole objects, but a selected Pen path still reveals its stored
  /// vertices. The handles remain exclusive to Pen's Direct mode.
  private func drawSelectedPathVertices(
    _ path: VectorPath, layerID: ProjectLayerID,
    pixelWidth: Double, pixelHeight: Double
  ) {
    for anchor in path.anchors {
      guard let canvasPoint = VectorObjectPicker.canvasPoint(
        anchor.position, in: recipe.layerStack, layerID: layerID,
        pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      else { continue }
      let center = viewPoint(fromDocument: canvasPoint)
      let marker = CAShapeLayer()
      marker.path = CGPath(
        rect: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8),
        transform: nil)
      marker.fillColor = NSColor.windowBackgroundColor.cgColor
      marker.strokeColor = NSColor.controlAccentColor.cgColor
      marker.lineWidth = 1.5
      marker.contentsScale = window?.backingScaleFactor ?? 2
      interactionLayer.addSublayer(marker)
    }
  }

  private func viewRect(from box: VectorBounds) -> CGRect {
    let origin = viewPoint(fromDocument: VectorPoint(x: box.minX, y: box.minY))
    let opposite = viewPoint(fromDocument: VectorPoint(x: box.maxX, y: box.maxY))
    return CGRect(
      x: min(origin.x, opposite.x),
      y: min(origin.y, opposite.y),
      width: abs(opposite.x - origin.x),
      height: abs(opposite.y - origin.y)
    )
  }

  private func selection(for target: HitTarget?) -> Selection? {
    switch target {
    case .anchor(let pathID, let anchorID), .close(let pathID, let anchorID),
      .endpoint(let pathID, let anchorID, _):
      .anchor(pathID: pathID, anchorID: anchorID)
    case .handle(let pathID, let anchorID, let side):
      .handle(pathID: pathID, anchorID: anchorID, side: side)
    default:
      nil
    }
  }

  private func hitTest(_ point: CGPoint, commandDirectSelect: Bool) -> HitTarget? {
    let paths = visiblePaths()

    if let activePath, activePath.anchors.count >= 2, let first = activePath.anchors.first,
      screenDistance(point, viewPoint(fromDocument: first.position))
        <= CGFloat(snapSettings.closeRadiusInScreenPoints)
    {
      return .close(pathID: activePath.id, anchorID: first.id)
    }

    let selectedPathIDs = Set([activePathID, selected?.pathID].compactMap { $0 })
    for path in paths.reversed() where commandDirectSelect || selectedPathIDs.contains(path.id) {
      for anchor in path.anchors.reversed() {
        if let outgoing = anchor.outgoingHandle,
          screenDistance(point, viewPoint(fromDocument: outgoing)) <= handleHitRadiusInPoints
        {
          return .handle(pathID: path.id, anchorID: anchor.id, side: .outgoing)
        }
        if let incoming = anchor.incomingHandle,
          screenDistance(point, viewPoint(fromDocument: incoming)) <= handleHitRadiusInPoints
        {
          return .handle(pathID: path.id, anchorID: anchor.id, side: .incoming)
        }
      }
    }

    for path in paths.reversed() {
      for (index, anchor) in path.anchors.enumerated().reversed() {
        guard
          screenDistance(point, viewPoint(fromDocument: anchor.position))
            <= anchorHitRadiusInPoints
        else { continue }
        let isFirst = index == 0
        let isLast = index == path.anchors.count - 1
        if !path.isClosed, isFirst || isLast, activePathID != path.id {
          return .endpoint(pathID: path.id, anchorID: anchor.id, isFirst: isFirst)
        }
        guard commandDirectSelect || selectedPathIDs.contains(path.id) else { continue }
        return .anchor(pathID: path.id, anchorID: anchor.id)
      }
    }

    for path in paths.reversed() where selectedPathIDs.contains(path.id) {
      let segmentCount = path.isClosed ? path.anchors.count : max(path.anchors.count - 1, 0)
      for index in 0..<segmentCount {
        guard let cubic = path.segment(startingAt: index) else { continue }
        let result = closestParameter(to: point, on: cubic)
        if result.distance <= segmentHitRadiusInPoints {
          return .segment(pathID: path.id, startIndex: index, t: result.t)
        }
      }
    }
    return nil
  }

  private func closestParameter(to point: CGPoint, on cubic: CubicBezier) -> (
    t: Double, distance: CGFloat
  ) {
    var bestT = 0.0
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for step in 0...48 {
      let t = Double(step) / 48
      let candidate = viewPoint(fromDocument: cubic.point(at: t))
      let distance = screenDistance(point, candidate)
      if distance < bestDistance {
        bestT = t
        bestDistance = distance
      }
    }
    var span = 1.0 / 48
    for _ in 0..<5 {
      for t in [max(0, bestT - span), bestT, min(1, bestT + span)] {
        let distance = screenDistance(point, viewPoint(fromDocument: cubic.point(at: t)))
        if distance < bestDistance {
          bestT = t
          bestDistance = distance
        }
      }
      span /= 2
    }
    return (bestT, bestDistance)
  }

  /// The paths whose anchors the Pen can edit.
  ///
  /// Stored paths only: a shape is edited through its parameters and a compound
  /// path through Release, so offering their resolved anchors to a direct-select
  /// drag would promise an edit that goes nowhere.
  private func visiblePaths() -> [VectorPath] {
    recipe.layerStack.vectorArtwork.flatMap(\.vectorLayer.paths)
  }

  /// Every visible object with the opacity of the layer that owns it, for the
  /// artwork overlay.
  private func visibleArtwork() -> [(object: VectorObject, opacity: Double)] {
    recipe.layerStack.vectorArtwork.flatMap { entry in
      entry.vectorLayer.objectsInDrawOrder.map {
        (object: $0, opacity: entry.effectiveOpacity)
      }
    }
  }

  private func snappedPlacementPoint(
    _ raw: VectorPoint,
    previousAnchor: VectorPoint?
  ) -> VectorPoint {
    var candidates = snapCandidates()
    if let spacing = snapSettings.gridSpacing,
      snapSettings.enabledTargetKinds.contains(.grid),
      spacing.x > 0,
      spacing.y > 0
    {
      let grid = VectorPoint(
        x: (raw.x / spacing.x).rounded() * spacing.x,
        y: (raw.y / spacing.y).rounded() * spacing.y
      )
      candidates.append(SnapTarget(position: grid, kind: .grid, label: "Grid"))
    }
    if snapSettings.enabledTargetKinds.contains(.guide) {
      candidates.append(
        contentsOf: snapSettings.guidePositions.map {
          SnapTarget(position: $0, kind: .guide, label: "Guide")
        })
    }

    if currentModifiers.contains(.shift), let previousAnchor {
      let constrainedView = constrainedViewPoint(
        viewPoint(fromDocument: raw),
        relativeTo: viewPoint(fromDocument: previousAnchor)
      )
      candidates.append(
        SnapTarget(
          position: documentPoint(fromView: constrainedView),
          kind: .angleConstraint,
          label: "45°"
        ))
    }

    let rawInView = viewPoint(fromDocument: raw)
    let allowedRadius = CGFloat(snapSettings.radiusInScreenPoints)
    let hysteresisRadius = allowedRadius + CGFloat(snapSettings.hysteresisInScreenPoints)
    if let activeSnapTarget,
      let retained = candidates.first(where: {
        $0.kind == activeSnapTarget.kind && $0.sourceID == activeSnapTarget.sourceID
      }),
      screenDistance(rawInView, viewPoint(fromDocument: retained.position)) <= hysteresisRadius
    {
      self.activeSnapTarget = retained
      return retained.position
    }

    let closest =
      candidates
      .map { ($0, screenDistance(rawInView, viewPoint(fromDocument: $0.position))) }
      .filter { $0.1 <= allowedRadius || $0.0.kind == .angleConstraint }
      .min { $0.1 < $1.1 }
    activeSnapTarget = closest?.0
    return closest?.0.position ?? raw
  }

  private func snapCandidates() -> [SnapTarget] {
    visiblePaths().flatMap { path in
      path.anchors.enumerated().compactMap { index, anchor -> SnapTarget? in
        if activePathID == path.id, index == path.anchors.count - 1 { return nil }
        let isEndpoint = !path.isClosed && (index == 0 || index == path.anchors.count - 1)
        let kind: SnapTargetKind = isEndpoint ? .endpoint : .anchor
        guard snapSettings.enabledTargetKinds.contains(kind) else { return nil }
        return SnapTarget(
          position: anchor.position,
          kind: kind,
          label: isEndpoint ? "Endpoint" : "Anchor",
          sourceID: anchor.id
        )
      }
    }
  }

  private func converted(
    _ anchor: VectorAnchor,
    in path: VectorPath,
    index: Int,
    to kind: VectorAnchorKind
  ) -> VectorAnchor {
    var converted = anchor
    converted.kind = kind
    guard kind != .corner else { return converted }

    let direction = defaultHandleDirection(for: path, index: index)
    let incomingLength = anchor.incomingHandle?.distance(to: anchor.position) ?? 0.025
    let outgoingLength = anchor.outgoingHandle?.distance(to: anchor.position) ?? 0.025
    let resolvedIncomingLength: Double
    let resolvedOutgoingLength: Double
    if kind == .symmetric {
      let average = (incomingLength + outgoingLength) / 2
      resolvedIncomingLength = average
      resolvedOutgoingLength = average
    } else {
      resolvedIncomingLength = incomingLength
      resolvedOutgoingLength = outgoingLength
    }
    converted.incomingHandle = anchor.position - direction * resolvedIncomingLength
    converted.outgoingHandle = anchor.position + direction * resolvedOutgoingLength
    return converted
  }

  private func defaultHandleDirection(for path: VectorPath, index: Int) -> VectorPoint {
    let position = path.anchors[index].position
    let previous = index > 0 ? path.anchors[index - 1].position : path.anchors.last?.position
    let next =
      index + 1 < path.anchors.count
      ? path.anchors[index + 1].position : path.anchors.first?.position
    let vector: VectorPoint
    if let previous, let next, path.isClosed || (index > 0 && index + 1 < path.anchors.count) {
      vector = next - previous
    } else if let next {
      vector = next - position
    } else if let previous {
      vector = position - previous
    } else {
      vector = VectorPoint(x: 1, y: 0)
    }
    let length = max(hypot(vector.x, vector.y), .leastNonzeroMagnitude)
    return VectorPoint(x: vector.x / length, y: vector.y / length)
  }

  private func movedHandle(
    _ anchor: VectorAnchor,
    side: HandleSide,
    to point: VectorPoint?,
    breakPairing: Bool
  ) -> VectorAnchor {
    var moved = anchor
    if side == .incoming {
      moved.incomingHandle = point
    } else {
      moved.outgoingHandle = point
    }

    guard !breakPairing, anchor.kind != .corner, let point else {
      moved.kind = .corner
      return moved
    }
    let vector = point - anchor.position
    let length = max(hypot(vector.x, vector.y), .leastNonzeroMagnitude)
    let oppositeDirection = VectorPoint(x: -vector.x / length, y: -vector.y / length)
    let oppositeLength: Double
    if anchor.kind == .symmetric {
      oppositeLength = length
    } else {
      let opposite = side == .incoming ? anchor.outgoingHandle : anchor.incomingHandle
      oppositeLength = opposite?.distance(to: anchor.position) ?? length
    }
    let opposite = anchor.position + oppositeDirection * oppositeLength
    if side == .incoming {
      moved.outgoingHandle = opposite
    } else {
      moved.incomingHandle = opposite
    }
    return moved
  }

  private func collapsedHandle(_ handle: VectorPoint, anchor: VectorPoint) -> VectorPoint? {
    let screenHandle = viewPoint(fromDocument: handle)
    let screenAnchor = viewPoint(fromDocument: anchor)
    return screenDistance(screenHandle, screenAnchor) <= 2 ? nil : handle
  }

  private func constrainedViewPoint(_ point: CGPoint, relativeTo origin: CGPoint) -> CGPoint {
    let deltaX = point.x - origin.x
    let deltaY = point.y - origin.y
    let length = hypot(deltaX, deltaY)
    guard length > 0 else { return point }
    let increment = snapSettings.angleIncrementDegrees * .pi / 180
    let angle = atan2(deltaY, deltaX)
    let constrained = (angle / increment).rounded() * increment
    return CGPoint(x: origin.x + cos(constrained) * length, y: origin.y + sin(constrained) * length)
  }

  private func rebuildOverlays() {
    guard layer != nil else { return }
    artworkLayer.sublayers = nil
    interactionLayer.sublayers = nil
    artworkLayer.frame = bounds
    interactionLayer.frame = bounds

    // A hairline keeps the canvas edge legible where dark artwork meets the
    // outside checkerboard.
    let canvasRect = imageRectInView()
    canvasBorderLayer.isHidden = canvasRect.isEmpty
    canvasBorderLayer.frame = canvasRect
    canvasBorderLayer.borderWidth = 1 / (window?.backingScaleFactor ?? 2)

    // The ants live outside `interactionLayer` so their animation survives, but
    // their outline still has to follow pan, zoom and resize.
    refreshSelectionAnts()

    // Before the first render completes, the lightweight overlay avoids an
    // empty flash. Once a frame exists it already contains vectors in their
    // authoritative layer-stack position, so drawing them again would double
    // their alpha and incorrectly place them above every raster layer.
    if frameImage == nil {
      for (object, opacity) in visibleArtwork() {
        // Anything the renderer draws differently from a shape layer — a
        // gradient, an inside or outside stroke, an arrowhead — is painted by
        // the renderer itself into a tile. Everything else stays vector-crisp.
        if needsRendererTile(object), let tile = rendererTileLayer(for: object) {
          tile.opacity = Float(opacity)
          artworkLayer.addSublayer(tile)
          continue
        }
        guard let path = makeViewPath(object) else { continue }
        let shape = CAShapeLayer()
        shape.opacity = Float(opacity)
        shape.path = path
        // A compound path's contours are one shape: without the fill rule a
        // hole would come out solid.
        shape.fillRule = object.fillRule == .evenOdd ? .evenOdd : .nonZero
        shape.fillColor = solidFillColor(object)
        let stroke = object.stroke
        shape.strokeColor = stroke.map { nsColor($0.effectiveColor).cgColor }
          ?? NSColor.clear.cgColor
        shape.lineWidth = displayedStrokeWidth(stroke?.width ?? 0)
        shape.lineCap = caLineCap(stroke?.lineCap ?? .round)
        shape.lineJoin = caLineJoin(stroke?.lineJoin ?? .round)
        shape.miterLimit = CGFloat(stroke?.miterLimit ?? 10)
        shape.lineDashPattern = stroke?.usableDashPattern.map { pattern in
          pattern.map { NSNumber(value: displayedStrokeLength($0)) }
        }
        shape.lineDashPhase = CGFloat(displayedStrokeLength(stroke?.dashPhase ?? 0))
        shape.contentsScale = window?.backingScaleFactor ?? 2
        artworkLayer.addSublayer(shape)
      }
    }

    drawGrid()
    drawGuides()
    drawCanvasSnapLines()
    if (activeTool == .move && selectedVectorObjectIDs.isEmpty) || activeTool == .transform {
      drawSelectedLayerBoundingBox()
    }
    if activeTool == .crop, let cropDraft { drawCropOverlay(cropDraft.recipe) }
    if activeTool.usesBrushStrokeCapture { drawBrushCursor() }
    drawColorSampleLoupe()
    publishViewport()
    if activeTool == .masks { drawMaskGuides() }
    if activeTool == .gradient || activeTool == .shape { drawCreativeToolGuides() }

    guard activeTool == .pen || activeTool == .shape || activeTool == .move else {
      setAccessibilityChildren([])
      return
    }

    // Shape remains a creation tool, but its newly created object keeps a
    // visible selection. Select/Move shows the same outline while editing it.
    if activeTool == .shape || activeTool == .move {
      drawVectorObjectSelection()
      setAccessibilityChildren([])
      return
    }

    drawRubberBand()
    drawSelectedPathControls()
    drawSnapTarget()
    drawCursorBadge()
    rebuildAccessibilityElements()
  }

  private func drawBrushCursor() {
    guard pointerIsInside, imageRectInView().contains(lastMouseInView), referenceSize.width > 0
    else {
      setAccessibilityValue(nil)
      return
    }
    let canvasPixelsPerPoint = referenceSize.width / imageRectInView().width
    let settings = displayedStrokeSettings
    let diameter = max(CGFloat(settings.size) / canvasPixelsPerPoint, 2)
    let outline = CAShapeLayer()
    outline.path = CGPath(
      ellipseIn: CGRect(
        x: lastMouseInView.x - diameter / 2,
        y: lastMouseInView.y - diameter / 2,
        width: diameter,
        height: diameter
      ),
      transform: nil
    )
    outline.fillColor = NSColor.clear.cgColor
    outline.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
    outline.shadowColor = NSColor.black.cgColor
    outline.shadowOpacity = 0.9
    outline.shadowRadius = 1
    outline.lineWidth = 1
    outline.lineDashPattern = activeTool == .eraser ? [4, 3] : nil
    outline.contentsScale = window?.backingScaleFactor ?? 2
    interactionLayer.addSublayer(outline)
    let label = switch activeTool {
    case .eraser: "Eraser"
    case .heal: "Healing Brush"
    case .selectionBrush:
      selectionBrushTool.mode == .paint ? "Selection Brush" : "Quick Select"
    default: "Brush"
    }
    if activeTool == .heal {
      drawHealSourceGuides(tipDiameter: diameter)
      let source = switch (healTool.mode, healTool.sourceAnchor) {
      case (.spot, _): "spot"
      case (.sourcePoint, .some): "source point set"
      case (.sourcePoint, .none): "source point not set"
      }
      setAccessibilityValue(
        "\(label), \(settings.size.formatted()) pixel size, \(source)")
      return
    }
    setAccessibilityValue("\(label), \(settings.size.formatted()) pixel size")
  }

  /// The anchor an Option-click set, and where the stroke is currently reading
  /// from.
  ///
  /// Two crosshairs: the anchor itself, and — while the pointer is down — the
  /// anchor carried by the same delta the stroke has travelled, which is the
  /// point whose pixels are actually being copied. Without the second one the
  /// user can see where they aimed but not what they are picking up.
  private func drawHealSourceGuides(tipDiameter: CGFloat) {
    guard healTool.mode == .sourcePoint, let anchor = healTool.sourceAnchor else { return }
    let anchorInView = viewPoint(fromDocument: anchor)
    addHealCrosshair(at: anchorInView, diameter: tipDiameter, isLive: false)
    guard let origin = brushGesture?.originInView else { return }
    let live = CGPoint(
      x: anchorInView.x + (lastMouseInView.x - origin.x),
      y: anchorInView.y + (lastMouseInView.y - origin.y)
    )
    addHealCrosshair(at: live, diameter: tipDiameter, isLive: true)
  }

  private func addHealCrosshair(at point: CGPoint, diameter: CGFloat, isLive: Bool) {
    let radius = max(diameter / 2, 4)
    let path = CGMutablePath()
    path.addEllipse(
      in: CGRect(
        x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    let arm = radius + 4
    path.move(to: CGPoint(x: point.x - arm, y: point.y))
    path.addLine(to: CGPoint(x: point.x + arm, y: point.y))
    path.move(to: CGPoint(x: point.x, y: point.y - arm))
    path.addLine(to: CGPoint(x: point.x, y: point.y + arm))
    let layer = CAShapeLayer()
    layer.path = path
    layer.fillColor = NSColor.clear.cgColor
    layer.strokeColor = NSColor.white.withAlphaComponent(isLive ? 0.95 : 0.6).cgColor
    layer.lineWidth = 1
    layer.lineDashPattern = isLive ? nil : [3, 3]
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = 0.9
    layer.shadowRadius = 1
    layer.contentsScale = window?.backingScaleFactor ?? 2
    interactionLayer.addSublayer(layer)
  }

  private func drawCreativeToolGuides() {
    if activeTool == .shape, let drag = creativeDrag {
      // The preview is the shape the commit will make, resolved through the
      // same conversion, so what is dragged is exactly what lands.
      let preview = shapeTool.makeShape(
        from: drag.start,
        to: drag.end,
        fromCenter: currentModifiers.contains(.option) != shapeTool.drawsFromCenter,
        constrained: currentModifiers.contains(.shift),
        aspect: vectorAspect,
        stroke: vectorToolStyle.fullStroke,
        fill: vectorToolStyle.fill
      ).resolvedPath(aspect: vectorAspect)
      let shape = CAShapeLayer()
      shape.path = makeViewPath(preview)
      shape.fillColor = nsColor(preview.fill?.color).withAlphaComponent(0.55).cgColor
      shape.strokeColor = nsColor(preview.stroke?.color ?? .white).cgColor
      shape.lineWidth = displayedStrokeWidth(preview.stroke?.width ?? 0)
      shape.lineCap = caLineCap(preview.stroke?.lineCap ?? .round)
      shape.lineJoin = caLineJoin(preview.stroke?.lineJoin ?? .round)
      shape.contentsScale = window?.backingScaleFactor ?? 2
      interactionLayer.addSublayer(shape)
      setAccessibilityValue("\(shapeTool.kind.label) preview")
      return
    }
    let storedGradient: PaintGradientRecipe? = {
      guard activeTool == .gradient,
        let id = recipe.layerStack.activeLayerID,
        let paint = recipe.layerStack.layer(id: id)?.paintLayer
      else { return nil }
      return paint.gradients.first
    }()
    guard let start = creativeDrag?.start ?? storedGradient?.start,
      let end = creativeDrag?.end ?? storedGradient?.end
    else { return }
    let path = CGMutablePath()
    path.move(to: viewPoint(fromDocument: start))
    path.addLine(to: viewPoint(fromDocument: end))
    let line = CAShapeLayer()
    line.path = path
    line.strokeColor = NSColor.controlAccentColor.cgColor
    line.lineWidth = 1.5
    line.lineDashPattern = [4, 3]
    interactionLayer.addSublayer(line)
    for point in [start, end] {
      let center = viewPoint(fromDocument: point)
      let handle = CAShapeLayer()
      handle.path = CGPath(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10), transform: nil)
      handle.fillColor = NSColor.windowBackgroundColor.cgColor
      handle.strokeColor = NSColor.controlAccentColor.cgColor
      handle.lineWidth = 2
      interactionLayer.addSublayer(handle)
    }
    setAccessibilityValue(activeTool == .gradient ? "Gradient handles" : "Shape bounds")
  }

  /// A compact old/new loupe beside the pointer. The status line carries the
  /// accessible numeric readout; this gives the visual comparison without
  /// obscuring the pixel being targeted.
  private func drawColorSampleLoupe() {
    guard pointerIsInside,
      imageRectInView().contains(lastMouseInView),
      case .color(let preview)? = pendingSample?.preview
    else { return }

    let diameter: CGFloat = 46
    var origin = CGPoint(x: lastMouseInView.x + 18, y: lastMouseInView.y + 18)
    if origin.x + diameter > bounds.maxX { origin.x = lastMouseInView.x - diameter - 18 }
    if origin.y + diameter > bounds.maxY { origin.y = lastMouseInView.y - diameter - 18 }
    let frame = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
    let circle = CGPath(ellipseIn: frame, transform: nil)

    let old = CAShapeLayer()
    let oldPath = CGMutablePath()
    oldPath.addRect(CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height))
    old.path = oldPath
    old.fillColor = nsColor(preview.oldColor).cgColor
    old.mask = shapeMask(circle)
    interactionLayer.addSublayer(old)

    let new = CAShapeLayer()
    let newPath = CGMutablePath()
    newPath.addRect(CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height))
    new.path = newPath
    new.fillColor = nsColor(preview.newColor).cgColor
    new.mask = shapeMask(circle)
    interactionLayer.addSublayer(new)

    let outline = CAShapeLayer()
    outline.path = circle
    outline.fillColor = nil
    outline.strokeColor = NSColor.white.cgColor
    outline.shadowColor = NSColor.black.cgColor
    outline.shadowOpacity = 0.8
    outline.shadowRadius = 2
    outline.lineWidth = 2
    interactionLayer.addSublayer(outline)
  }

  private func shapeMask(_ path: CGPath) -> CAShapeLayer {
    let mask = CAShapeLayer()
    mask.path = path
    mask.fillColor = NSColor.white.cgColor
    return mask
  }

  /// The overlay's copy of a path, through the renderer's own geometry so the
  /// canvas and the export agree on every segment.
  private func makeViewPath(_ path: VectorPath) -> CGPath {
    VectorArtworkRenderer.makePath(path) { viewPoint(fromDocument: $0) }
  }

  /// The overlay's copy of a whole object: every contour it has, in one path.
  private func makeViewPath(_ object: VectorObject) -> CGPath? {
    let contours = object.resolvedContours(aspect: vectorAspect)
      .filter { $0.anchors.count >= 2 }
    guard !contours.isEmpty else { return nil }
    let combined = CGMutablePath()
    for contour in contours { combined.addPath(makeViewPath(contour)) }
    return combined
  }

  /// The flat color a shape layer paints, or clear when the fill is a gradient
  /// or absent. A gradient is drawn as a tile above, not by the shape layer.
  private func solidFillColor(_ object: VectorObject) -> CGColor {
    guard object.isClosed, let fill = object.fill, case .solid(let color) = fill.content
    else { return NSColor.clear.cgColor }
    return nsColor(color).withAlphaComponent(
      CGFloat(color.alpha * fill.opacity)).cgColor
  }

  /// Whether a shape layer can draw this object faithfully.
  ///
  /// A `CAShapeLayer` knows nothing about gradient fills, inside and outside
  /// strokes, or arrowheads. Rather than approximate them on the canvas and
  /// have the export disagree, those objects go through the renderer.
  private func needsRendererTile(_ object: VectorObject) -> Bool {
    if object.isClosed, object.fill?.isGradient == true { return true }
    guard let stroke = object.stroke, stroke.isVisible else { return false }
    if object.isClosed, stroke.alignment != .center { return true }
    if !object.isClosed, stroke.startArrowhead != nil || stroke.endArrowhead != nil {
      return true
    }
    return false
  }

  /// One object, rendered by the shared evaluator into a tile the size it
  /// occupies on screen.
  ///
  /// Rebuilding overlays happens on nearly every pointer event, so the tile is
  /// cached against the recipe and the on-screen rectangle that produced it: a
  /// mouse move changes neither and costs nothing.
  private func rendererTileLayer(for object: VectorObject) -> CALayer? {
    guard let viewPath = makeViewPath(object) else { return nil }
    // The tile has to hold what the stroke paints, not just the outline: an
    // outside stroke and an arrowhead both reach past it.
    let reach = strokeReachInViewPoints(object)
    let objectRect = viewPath.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach).integral
    // Pixels outside the view cannot be presented. Clipping here prevents a
    // zoomed or mostly off-screen object from allocating for its full extent.
    let rect = objectRect.intersection(bounds).integral
    guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
    let scale = window?.backingScaleFactor ?? 2
    let container = CALayer()
    container.frame = bounds
    for tileRect in rendererTileRects(in: rect, scale: scale) {
      let key = GradientTileKey(
        object: object,
        x: Int(tileRect.minX),
        y: Int(tileRect.minY),
        width: Int(tileRect.width),
        height: Int(tileRect.height),
        scale: Int(scale * 100)
      )
      guard let image = cachedRendererTile(for: key) ?? renderAndCacheTile(
        object: object, key: key, rect: tileRect, scale: scale)
      else { return nil }

      let layer = CALayer()
      layer.frame = tileRect
      layer.contents = image
      layer.contentsGravity = .resize
      layer.contentsScale = scale
      container.addSublayer(layer)
    }
    return container
  }

  private func rendererTileRects(in rect: CGRect, scale: CGFloat) -> [CGRect] {
    let maximumPointEdge = max(
      1, floor(CGFloat(gradientTileMaximumPixelEdge) / max(scale, 1)))
    var result: [CGRect] = []
    var y = rect.minY
    while y < rect.maxY {
      let height = min(maximumPointEdge, rect.maxY - y)
      var x = rect.minX
      while x < rect.maxX {
        let width = min(maximumPointEdge, rect.maxX - x)
        result.append(CGRect(x: x, y: y, width: width, height: height))
        x += width
      }
      y += height
    }
    return result
  }

  private func cachedRendererTile(for key: GradientTileKey) -> CGImage? {
    guard var cached = gradientTiles[key] else { return nil }
    gradientTileAccess &+= 1
    cached.lastAccess = gradientTileAccess
    gradientTiles[key] = cached
    return cached.image
  }

  private func renderAndCacheTile(
    object: VectorObject,
    key: GradientTileKey,
    rect: CGRect,
    scale: CGFloat
  ) -> CGImage? {
    guard let image = renderTile(object: object, rect: rect, scale: scale) else { return nil }
    let byteCost = image.bytesPerRow * image.height
    guard byteCost <= gradientTileByteLimit else { return image }

    while gradientTileByteCost + byteCost > gradientTileByteLimit,
      let oldest = gradientTiles.min(by: { $0.value.lastAccess < $1.value.lastAccess })
    {
      gradientTileByteCost -= oldest.value.byteCost
      gradientTiles.removeValue(forKey: oldest.key)
    }
    gradientTileAccess &+= 1
    gradientTiles[key] = CachedGradientTile(
      image: image, byteCost: byteCost, lastAccess: gradientTileAccess)
    gradientTileByteCost += byteCost
    return image
  }

  /// How far past its outline an object's stroke reaches, in view points.
  private func strokeReachInViewPoints(_ object: VectorObject) -> CGFloat {
    guard let stroke = object.stroke, stroke.isVisible else { return 2 }
    let width = displayedStrokeWidth(stroke.width)
    let arrow = max(
      stroke.startArrowhead?.scale ?? 0, stroke.endArrowhead?.scale ?? 0)
    // An outside stroke reaches a full width past the outline; an arrowhead
    // reaches its own length. Two points of slack keeps antialiasing inside.
    return width * CGFloat(max(arrow, 1)) + 2
  }

  private func renderTile(
    object: VectorObject, rect: CGRect, scale: CGFloat
  ) -> CGImage? {
    let pixelWidth = Int(rect.width * scale)
    let pixelHeight = Int(rect.height * scale)
    guard pixelWidth > 0, pixelHeight > 0,
      let context = VectorArtworkRenderer.makeContext(
        width: pixelWidth, height: pixelHeight, fallback: displayColorSpace)
    else { return nil }
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let mapping: (VectorPoint) -> CGPoint = { [weak self] point in
      guard let self else { return .zero }
      let view = self.viewPoint(fromDocument: point)
      return CGPoint(x: (view.x - rect.minX) * scale, y: (view.y - rect.minY) * scale)
    }
    VectorArtworkRenderer.draw(
      object, aspect: vectorAspect, in: context, mapping: mapping)
    return context.makeImage()
  }

  private func drawRubberBand() {
    guard let path = activePath, let last = path.anchors.last, !path.isClosed else {
      if let provisional { drawProvisionalHandles(provisional.anchor) }
      return
    }

    let destination: VectorPoint
    let incoming: VectorPoint
    if let provisional {
      destination = provisional.anchor.position
      incoming = provisional.anchor.incomingHandle ?? destination
    } else {
      let raw = documentPoint(fromView: lastMouseInView)
      destination = snappedPlacementPoint(raw, previousAnchor: last.position)
      incoming = destination
    }
    let preview = CGMutablePath()
    preview.move(to: viewPoint(fromDocument: last.position))
    let outgoing = last.outgoingHandle ?? last.position
    if outgoing == last.position && incoming == destination {
      preview.addLine(to: viewPoint(fromDocument: destination))
    } else {
      preview.addCurve(
        to: viewPoint(fromDocument: destination),
        control1: viewPoint(fromDocument: outgoing),
        control2: viewPoint(fromDocument: incoming)
      )
    }
    let shape = CAShapeLayer()
    shape.path = preview
    shape.fillColor = nil
    shape.strokeColor = nsColor(path.stroke?.color ?? .white).cgColor
    shape.lineWidth = max(displayedStrokeWidth(path.stroke?.width ?? 0), 1)
    shape.opacity = 0.82
    shape.contentsScale = window?.backingScaleFactor ?? 2
    interactionLayer.addSublayer(shape)
    if let provisional { drawProvisionalHandles(provisional.anchor) }
  }

  private func drawSelectedPathControls() {
    let controlledPathID = selected?.pathID ?? activePathID
    guard let controlledPathID,
      let path = recipe.layerStack.path(id: controlledPathID)?.path
    else { return }

    for (index, anchor) in path.anchors.enumerated() {
      drawHandle(
        anchor.incomingHandle, from: anchor.position, selected: isSelectedHandle(anchor, .incoming))
      drawHandle(
        anchor.outgoingHandle, from: anchor.position, selected: isSelectedHandle(anchor, .outgoing))

      let center = viewPoint(fromDocument: anchor.position)
      let isActive =
        selected?.anchorID == anchor.id
        || (activePathID == path.id && index == path.anchors.count - 1)
      let isHovered = hoveredTargetReferences(anchor.id)
      let radius: CGFloat = isHovered ? 5 : 4
      let marker = CAShapeLayer()
      marker.path = CGPath(
        ellipseIn: CGRect(
          x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
        transform: nil
      )
      marker.fillColor =
        isActive ? NSColor.controlAccentColor.cgColor : NSColor.windowBackgroundColor.cgColor
      marker.strokeColor = NSColor.controlAccentColor.cgColor
      marker.lineWidth = 1.5
      marker.contentsScale = window?.backingScaleFactor ?? 2
      interactionLayer.addSublayer(marker)
    }
  }

  private func drawProvisionalHandles(_ anchor: VectorAnchor) {
    drawHandle(anchor.incomingHandle, from: anchor.position, selected: false)
    drawHandle(anchor.outgoingHandle, from: anchor.position, selected: false)
    let center = viewPoint(fromDocument: anchor.position)
    let marker = CAShapeLayer()
    marker.path = CGPath(
      rect: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8),
      transform: nil
    )
    marker.fillColor = NSColor.controlAccentColor.cgColor
    marker.strokeColor = NSColor.white.cgColor
    marker.lineWidth = 1
    interactionLayer.addSublayer(marker)
  }

  private func drawHandle(_ handle: VectorPoint?, from anchor: VectorPoint, selected: Bool) {
    guard let handle else { return }
    let start = viewPoint(fromDocument: anchor)
    let end = viewPoint(fromDocument: handle)
    let linePath = CGMutablePath()
    linePath.move(to: start)
    linePath.addLine(to: end)
    let line = CAShapeLayer()
    line.path = linePath
    line.strokeColor = NSColor.controlAccentColor.cgColor
    line.fillColor = nil
    line.lineWidth = 1
    interactionLayer.addSublayer(line)

    let radius: CGFloat = selected ? 4 : 3
    let knob = CAShapeLayer()
    knob.path = CGPath(
      ellipseIn: CGRect(
        x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2),
      transform: nil
    )
    knob.fillColor =
      selected ? NSColor.controlAccentColor.cgColor : NSColor.windowBackgroundColor.cgColor
    knob.strokeColor = NSColor.controlAccentColor.cgColor
    knob.lineWidth = 1
    interactionLayer.addSublayer(knob)
  }

  /// A simple box around the selected layer, so the Move tool shows what it
  /// will move before anything moves.
  ///
  /// Two coincident strokes: a dark solid line under a light dashed one, which
  /// stays readable over both bright and dark artwork without animating.
  private func drawSelectedLayerBoundingBox() {
    guard let rect = selectedLayerRectInView() else { return }
    let box = CGPath(rect: rect.insetBy(dx: -0.5, dy: -0.5), transform: nil)
    let contentsScale = window?.backingScaleFactor ?? 2

    let underlay = CAShapeLayer()
    underlay.path = box
    underlay.fillColor = nil
    underlay.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
    underlay.lineWidth = 1
    underlay.contentsScale = contentsScale
    interactionLayer.addSublayer(underlay)

    let outline = CAShapeLayer()
    outline.path = box
    outline.fillColor = nil
    outline.strokeColor = NSColor.controlAccentColor.cgColor
    outline.lineWidth = 1
    outline.lineDashPattern = [NSNumber(value: 4), NSNumber(value: 3)]
    outline.contentsScale = contentsScale
    interactionLayer.addSublayer(outline)
  }

  private func drawSnapTarget() {
    guard let activeSnapTarget else { return }
    let center = viewPoint(fromDocument: activeSnapTarget.position)
    let marker = CAShapeLayer()
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: center.y + 6))
    path.addLine(to: CGPoint(x: center.x + 6, y: center.y))
    path.addLine(to: CGPoint(x: center.x, y: center.y - 6))
    path.addLine(to: CGPoint(x: center.x - 6, y: center.y))
    path.closeSubpath()
    marker.path = path
    marker.fillColor = NSColor.clear.cgColor
    marker.strokeColor = NSColor.systemYellow.cgColor
    marker.lineWidth = 2
    interactionLayer.addSublayer(marker)

    addText(activeSnapTarget.label, at: CGPoint(x: center.x + 9, y: center.y + 5), fontSize: 10)
  }

  private func drawCursorBadge() {
    let state = cursorState(for: hoveredTarget)
    addText(
      state.badge, at: CGPoint(x: lastMouseInView.x + 10, y: lastMouseInView.y - 18), fontSize: 13)
  }

  private func addText(_ text: String, at point: CGPoint, fontSize: CGFloat) {
    let textLayer = CATextLayer()
    textLayer.string = text
    textLayer.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    textLayer.fontSize = fontSize
    textLayer.foregroundColor = NSColor.labelColor.cgColor
    textLayer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
    textLayer.cornerRadius = 4
    textLayer.alignmentMode = .center
    textLayer.contentsScale = window?.backingScaleFactor ?? 2
    let width = max(CGFloat(text.count) * fontSize * 0.72 + 8, 20)
    textLayer.frame = CGRect(x: point.x, y: point.y, width: width, height: fontSize + 7)
    interactionLayer.addSublayer(textLayer)
  }

  private func cursorState(for target: HitTarget?) -> PenCursorState {
    if currentModifiers.contains(.command) { return .directSelect }
    return switch target {
    case .close: .closePath
    case .anchor: currentModifiers.contains(.option) ? .convertAnchor : .removeAnchor
    case .endpoint: activePathID == nil ? .continuePath : .joinPath
    case .segment: .addAnchor
    case .handle: .convertAnchor
    case nil: .create
    }
  }

  private func updateAccessibilityValue() {
    let state = cursorState(for: hoveredTarget)
    setAccessibilityValue(state.accessibilityLabel)
  }

  private func rebuildAccessibilityElements() {
    guard let window else { return }
    var elements: [NSAccessibilityElement] = []
    for path in visiblePaths() {
      for anchor in path.anchors {
        let point = viewPoint(fromDocument: anchor.position)
        let viewRect = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
        let windowRect = convert(viewRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let element = NSAccessibilityElement()
        element.setAccessibilityFrame(screenRect)
        element.setAccessibilityRole(.button)
        element.setAccessibilityParent(self)
        element.setAccessibilityLabel(anchor.accessibilityDescription)
        element.setAccessibilityHelp("Hold Command and drag to move this anchor.")
        elements.append(element)
      }
    }
    setAccessibilityChildren(elements)
  }

  private func isSelectedHandle(_ anchor: VectorAnchor, _ side: HandleSide) -> Bool {
    guard case .handle(_, let anchorID, let selectedSide) = selected else { return false }
    return anchor.id == anchorID && side == selectedSide
  }

  private func hoveredTargetReferences(_ anchorID: UUID) -> Bool {
    switch hoveredTarget {
    case .anchor(_, let id), .close(_, let id), .endpoint(_, let id, _), .handle(_, let id, _):
      id == anchorID
    default:
      false
    }
  }

  /// The geometry every viewport calculation is expressed against.
  ///
  /// The canvas owns it. A proxy frame is a lower-resolution rendering of that
  /// same extent, so falling back to `frameSize` only matters before the canvas
  /// has resolved, where the two agree anyway.
  private var referenceSize: CGSize {
    canvasSize.width > 0 && canvasSize.height > 0 ? canvasSize : frameSize
  }

  private var coordinateTransform: CanvasCoordinateTransform {
    CanvasCoordinateTransform(
      viewSize: bounds.size,
      drawableSize: drawableSize,
      canvasSize: referenceSize,
      backingScale: window?.backingScaleFactor ?? 1,
      zoom: zoomMultiplier,
      panInDrawablePixels: panInPixels
    )
  }

  private func imageRectInView() -> CGRect {
    coordinateTransform.canvasRectInView
  }

  /// The canvas rectangle in drawable pixels.
  private func canvasRectInDrawable() -> CGRect {
    coordinateTransform.canvasRectInDrawablePixels
  }

  /// A rectangle in canvas pixels, mapped into the view.
  private func viewRect(fromCanvas frame: LayerFrame) -> CGRect {
    let rect = imageRectInView()
    let size = referenceSize
    guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return .zero }
    let scaleX = rect.width / size.width
    let scaleY = rect.height / size.height
    return CGRect(
      x: rect.minX + CGFloat(frame.x) * scaleX,
      y: rect.minY + CGFloat(frame.y) * scaleY,
      width: CGFloat(frame.width) * scaleX,
      height: CGFloat(frame.height) * scaleY
    )
  }

  /// How many canvas pixels the pointer crosses per view point, which is what
  /// turns a drag into a layer offset.
  private func canvasPixelsPerViewPoint() -> CGSize? {
    let rect = imageRectInView()
    let size = referenceSize
    guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return nil }
    return CGSize(width: size.width / rect.width, height: size.height / rect.height)
  }

  private func documentPoint(fromView point: CGPoint) -> VectorPoint {
    let rect = imageRectInView()
    guard rect.width > 0, rect.height > 0 else { return .zero }
    return VectorPoint(
      x: (point.x - rect.minX) / rect.width,
      y: (point.y - rect.minY) / rect.height
    )
  }

  private func viewPoint(fromDocument point: VectorPoint) -> CGPoint {
    let rect = imageRectInView()
    return CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
  }

  private func screenDistance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
    hypot(first.x - second.x, first.y - second.y)
  }

  /// A length authored in canonical image pixels, as it measures on screen.
  private func displayedStrokeLength(_ imagePixels: Double) -> Double {
    guard canonicalImageSize.width > 0 else { return imagePixels }
    return imagePixels * Double(imageRectInView().width / canonicalImageSize.width)
  }

  private func displayedStrokeWidth(_ imagePixels: Double) -> CGFloat {
    guard canonicalImageSize.width > 0 else { return 1 }
    let scale = imageRectInView().width / canonicalImageSize.width
    return max(CGFloat(imagePixels) * scale, 0.5)
  }

  private func nsColor(_ color: VectorColor?) -> NSColor {
    guard let color else { return .clear }
    return NSColor(
      calibratedRed: color.red,
      green: color.green,
      blue: color.blue,
      alpha: color.alpha
    )
  }

  private func nsColor(_ color: LinearRGBAColor) -> NSColor {
    let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
      ?? CGColorSpaceCreateDeviceRGB()
    let cgColor = CGColor(
      colorSpace: space,
      components: [color.red, color.green, color.blue, color.alpha]
    ) ?? CGColor(gray: 0, alpha: 1)
    return NSColor(cgColor: cgColor) ?? .black
  }

  private func caLineCap(_ cap: VectorLineCap) -> CAShapeLayerLineCap {
    switch cap {
    case .butt: .butt
    case .round: .round
    case .square: .square
    }
  }

  private func caLineJoin(_ join: VectorLineJoin) -> CAShapeLayerLineJoin {
    switch join {
    case .miter: .miter
    case .round: .round
    case .bevel: .bevel
    }
  }

  private func fitScale() -> CGFloat {
    let size = referenceSize
    guard size.width > 0, size.height > 0 else { return 1 }
    return min(drawableSize.width / size.width, drawableSize.height / size.height)
  }
}

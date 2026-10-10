import Foundation

public struct ProjectLayerID: Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String = UUID().uuidString) {
    self.rawValue = rawValue
  }

  public init(_ uuid: UUID) {
    self.rawValue = uuid.uuidString
  }

  public static let rawBackground = ProjectLayerID(rawValue: "raw-background")
  public static let canvas = ProjectLayerID(rawValue: "canvas")

  public init(from decoder: any Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self) {
      rawValue = value
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rawValue = try container.decode(String.self, forKey: .rawValue)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rawValue, forKey: .rawValue)
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }
}

public enum ProjectLayerContent: Codable, Equatable, Sendable {
  case developedRaw(DevelopedRawLayer)
  case image(ImageLayer)
  case raster(RasterLayerRecipe)
  case generatedInpaint(GeneratedInpaintLayerRecipe)
  case paint(PaintLayerRecipe)
  case vector(VectorLayer)
  case canvas(CanvasRecipe)
  case text(TextLayer)
  case group(GroupLayer)
  case adjustment(AdjustmentRecipe)

  public init(from decoder: any Decoder) throws {
    if let legacy = try? decoder.singleValueContainer().decode(String.self) {
      guard legacy == "developedRaw" || legacy == "rawImage" else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "Unknown layer content."))
      }
      self = .developedRaw(DevelopedRawLayer())
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.developedRaw) || container.contains(.rawImage) {
      let raw =
        (try? container.decode(DevelopedRawLayer.self, forKey: .developedRaw))
        ?? (try? container.decode(DevelopedRawLayer.self, forKey: .rawImage))
        ?? DevelopedRawLayer()
      self = .developedRaw(raw)
      return
    }
    if container.contains(.image) {
      if let image = try? container.decode(ImageLayer.self, forKey: .image) {
        self = .image(image)
        return
      }
      let associated = try container.nestedContainer(
        keyedBy: CodingKeys.self,
        forKey: .image
      )
      self = .image(try associated.decode(ImageLayer.self, forKey: .associatedValue))
      return
    }
    if container.contains(.raster) {
      self = .raster(try container.decode(RasterLayerRecipe.self, forKey: .raster))
      return
    }
    if container.contains(.generatedInpaint) {
      self = .generatedInpaint(try container.decode(
        GeneratedInpaintLayerRecipe.self, forKey: .generatedInpaint))
      return
    }
    if container.contains(.paint) {
      if let paint = try? container.decode(PaintLayerRecipe.self, forKey: .paint) {
        self = .paint(paint)
        return
      }
      let associated = try container.nestedContainer(
        keyedBy: CodingKeys.self,
        forKey: .paint
      )
      self = .paint(try associated.decode(PaintLayerRecipe.self, forKey: .associatedValue))
      return
    }
    if container.contains(.vector) {
      if let vector = try? container.decode(VectorLayer.self, forKey: .vector) {
        self = .vector(vector)
        return
      }
      let associated = try container.nestedContainer(
        keyedBy: CodingKeys.self,
        forKey: .vector
      )
      self = .vector(try associated.decode(VectorLayer.self, forKey: .associatedValue))
      return
    }
    if container.contains(.canvas) {
      if let canvas = try? container.decode(CanvasRecipe.self, forKey: .canvas) {
        self = .canvas(canvas)
        return
      }
      let associated = try container.nestedContainer(
        keyedBy: CodingKeys.self,
        forKey: .canvas
      )
      self = .canvas(try associated.decode(CanvasRecipe.self, forKey: .associatedValue))
      return
    }

    switch try container.decode(Kind.self, forKey: .type) {
    case .developedRaw, .rawImage:
      let raw =
        (try? container.decode(DevelopedRawLayer.self, forKey: .developedRaw))
        ?? (try? container.decode(DevelopedRawLayer.self, forKey: .rawImage))
        ?? DevelopedRawLayer()
      self = .developedRaw(raw)
    case .image:
      self = .image(try container.decode(ImageLayer.self, forKey: .image))
    case .raster:
      self = .raster(try container.decode(RasterLayerRecipe.self, forKey: .raster))
    case .generatedInpaint:
      self = .generatedInpaint(try container.decode(
        GeneratedInpaintLayerRecipe.self, forKey: .generatedInpaint))
    case .paint:
      self = .paint(try container.decode(PaintLayerRecipe.self, forKey: .paint))
    case .vector:
      self = .vector(try container.decode(VectorLayer.self, forKey: .vector))
    case .canvas:
      self = .canvas(try container.decode(CanvasRecipe.self, forKey: .canvas))
    case .text:
      self = .text(try container.decode(TextLayer.self, forKey: .text))
    case .group:
      self = .group(try container.decode(GroupLayer.self, forKey: .group))
    case .adjustment:
      self = .adjustment(try container.decode(AdjustmentRecipe.self, forKey: .adjustment))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .developedRaw(let raw):
      try container.encode(Kind.developedRaw, forKey: .type)
      try container.encode(raw, forKey: .developedRaw)
    case .image(let image):
      try container.encode(Kind.image, forKey: .type)
      try container.encode(image, forKey: .image)
    case .raster(let raster):
      try container.encode(Kind.raster, forKey: .type)
      try container.encode(raster, forKey: .raster)
    case .generatedInpaint(let inpaint):
      try container.encode(Kind.generatedInpaint, forKey: .type)
      try container.encode(inpaint, forKey: .generatedInpaint)
    case .paint(let paint):
      try container.encode(Kind.paint, forKey: .type)
      try container.encode(paint, forKey: .paint)
    case .vector(let vector):
      try container.encode(Kind.vector, forKey: .type)
      try container.encode(vector, forKey: .vector)
    case .canvas(let canvas):
      try container.encode(Kind.canvas, forKey: .type)
      try container.encode(canvas, forKey: .canvas)
    case .text(let text):
      try container.encode(Kind.text, forKey: .type)
      try container.encode(text, forKey: .text)
    case .group(let group):
      try container.encode(Kind.group, forKey: .type)
      try container.encode(group, forKey: .group)
    case .adjustment(let adjustment):
      try container.encode(Kind.adjustment, forKey: .type)
      try container.encode(adjustment, forKey: .adjustment)
    }
  }

  private enum Kind: String, Codable {
    case developedRaw
    case rawImage
    case image
    case raster
    case generatedInpaint
    case paint
    case vector
    case canvas
    case text
    case group
    case adjustment
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case developedRaw
    case rawImage
    case image
    case raster
    case generatedInpaint
    case paint
    case vector
    case canvas
    case text
    case group
    case adjustment
    case associatedValue = "_0"
  }
}

public struct ProjectLayer: Codable, Identifiable, Equatable, Sendable {
  public var id: ProjectLayerID
  public var name: String
  public var isEnabled: Bool
  public var isLocked: Bool
  public var zOrder: Int
  public var content: ProjectLayerContent
  /// Blend mode, opacity and fill. Projects written before these existed
  /// decode as plain source-over at full strength.
  public var compositing: LayerCompositing
  /// The post-RAW develop adjustments of this layer. Neutral by default.
  public var adjustments: LayerAdjustments
  /// The masks attached to this layer, bottom-most first.
  ///
  /// Adjustments belong to the layer they act on, so a mask that carries one
  /// travels with the layer through grouping, reordering and duplication. This
  /// is the shared mask model: the same `MaskRecipe` type serves local
  /// adjustments here, layer masks, saved selections and inpaint masks.
  public var masks: [MaskRecipe]
  /// The mask that gates the layer's complete contribution. Local-adjustment
  /// masks stay in `masks`; this one is deliberately singular and is shown
  /// beside the layer thumbnail as an explicit paint target.
  public var layerMask: MaskRecipe?
  /// Non-destructive placement in the parent's authoring space. `nil` is the
  /// identity for projects written before Free Transform existed.
  public var transform: LayerTransform?
  /// A non-destructive rectangular clip in this layer's own pixel bounds.
  /// `nil` means the complete layer is visible.
  public var crop: CropRecipe?

  public init(
    id: ProjectLayerID = ProjectLayerID(),
    name: String,
    isEnabled: Bool = true,
    isLocked: Bool = false,
    zOrder: Int = 0,
    content: ProjectLayerContent,
    compositing: LayerCompositing = .normal,
    adjustments: LayerAdjustments = .neutral,
    masks: [MaskRecipe] = [],
    layerMask: MaskRecipe? = nil,
    transform: LayerTransform? = nil,
    crop: CropRecipe? = nil
  ) {
    self.id = id
    self.name = name
    self.isEnabled = isEnabled
    self.isLocked = isLocked
    self.zOrder = zOrder
    self.content = content
    self.compositing = compositing
    self.adjustments = adjustments
    self.masks = masks
    self.layerMask = layerMask
    self.transform = transform
    self.crop = crop
  }

  /// Whether develop adjustments act on this layer's pixels.
  ///
  /// The developed RAW, placed images and rendered text carry pixels the
  /// adjustment graph runs on. Vector artwork is drawn as an overlay, the
  /// canvas has no pixels, and groups and adjustment layers are structural,
  /// so none of those take adjustments of their own.
  public var supportsAdjustments: Bool {
    switch content {
    case .developedRaw, .image, .raster, .generatedInpaint, .paint, .text: true
    case .vector, .canvas, .group, .adjustment: false
    }
  }

  public var isVisible: Bool {
    get { isEnabled }
    set { isEnabled = newValue }
  }

  public var blendMode: LayerBlendMode {
    get { compositing.blendMode }
    set { compositing.blendMode = newValue }
  }

  public var opacity: Double {
    get { compositing.opacity }
    set { compositing.opacity = LayerCompositing.clamped(newValue) }
  }

  public var fill: Double {
    get { compositing.fill }
    set { compositing.fill = LayerCompositing.clamped(newValue) }
  }

  public var differenceCutoff: Double { compositing.differenceCutoff }
  public var differenceSoftness: Double { compositing.differenceSoftness }
  public var differenceRadius: Double { compositing.differenceRadius }
  public var differenceFineDetail: Double { compositing.differenceFineDetail }
  public var differenceStructure: Double { compositing.differenceStructure }
  public var differenceDrift: Double { compositing.differenceDrift }
  public var differenceGrow: Double { compositing.differenceGrow }
  public var differenceFeather: Double { compositing.differenceFeather }

  public var isVectorLayer: Bool {
    if case .vector = content { true } else { false }
  }

  public var isImageLayer: Bool {
    if case .image = content { true } else { false }
  }

  public var isRasterLayer: Bool {
    if case .raster = content { true } else { false }
  }

  public var isDevelopedRaw: Bool {
    if case .developedRaw = content { true } else { false }
  }

  public var developedRawLayer: DevelopedRawLayer? {
    if case .developedRaw(let raw) = content { raw } else { nil }
  }

  public var imageLayer: ImageLayer? {
    if case .image(let image) = content { image } else { nil }
  }

  public var rasterLayer: RasterLayerRecipe? {
    if case .raster(let raster) = content { raster } else { nil }
  }

  public var generatedInpaintLayer: GeneratedInpaintLayerRecipe? {
    if case .generatedInpaint(let inpaint) = content { inpaint } else { nil }
  }

  public var rasterAssetReferences: [RasterAssetReference] {
    switch content {
    case .raster(let raster): raster.differenceSource.map { [raster.asset, $0] } ?? [raster.asset]
    case .generatedInpaint(let inpaint): inpaint.assetReferences
    // Healed patches are baked pixels living inside a paint layer, so the
    // document has to know about them or saving would write a recipe that
    // references assets the package does not contain.
    case .paint(let paint): paint.heals.map(\.patch)
    default: []
    }
  }

  public var isPaintLayer: Bool {
    if case .paint = content { true } else { false }
  }

  public var paintLayer: PaintLayerRecipe? {
    if case .paint(let paint) = content { paint } else { nil }
  }

  public var isCanvasLayer: Bool {
    if case .canvas = content { true } else { false }
  }

  public var canvasRecipe: CanvasRecipe? {
    if case .canvas(let canvas) = content { canvas } else { nil }
  }

  public var isTextLayer: Bool {
    if case .text = content { true } else { false }
  }

  public var textLayer: TextLayer? {
    if case .text(let text) = content { text } else { nil }
  }

  public var isGroupLayer: Bool {
    if case .group = content { true } else { false }
  }

  public var groupLayer: GroupLayer? {
    if case .group(let group) = content { group } else { nil }
  }

  public var isAdjustmentLayer: Bool {
    if case .adjustment = content { true } else { false }
  }

  public var adjustment: AdjustmentRecipe? {
    if case .adjustment(let adjustment) = content { adjustment } else { nil }
  }

  /// Whether this layer contributes pixels the render engine composites.
  ///
  /// Vector artwork is drawn by the canvas as an overlay, the canvas layer is
  /// an extent, and an adjustment only changes pixels that are already there.
  public var isRasterContent: Bool {
    switch content {
    case .developedRaw, .image, .raster, .generatedInpaint, .paint, .text: true
    case .group(let group): group.children.contains { $0.isEnabled && $0.isRasterContent }
    case .vector, .canvas, .adjustment: false
    }
  }

  /// Layer crop deliberately starts with complete pixel sources. The primary
  /// RAW uses the canvas as its frame even though it is not a placed layer;
  /// canvas-backed paint, text, vectors and structural layers need different
  /// bounds rules.
  public var supportsLayerCrop: Bool {
    switch content {
    case .developedRaw, .image, .raster, .generatedInpaint:
      true
    case .paint, .text, .vector, .canvas, .group, .adjustment:
      false
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(ProjectLayerID.self, forKey: .id) ?? ProjectLayerID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Layer"
    isEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
      ?? container.decodeIfPresent(Bool.self, forKey: .isVisible)
      ?? true
    isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    zOrder = try container.decodeIfPresent(Int.self, forKey: .zOrder) ?? 0
    content = try container.decode(ProjectLayerContent.self, forKey: .content)
    compositing = LayerCompositing(
      blendMode: try container.decodeIfPresent(LayerBlendMode.self, forKey: .blendMode) ?? .normal,
      opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
      fill: try container.decodeIfPresent(Double.self, forKey: .fill) ?? 1,
      differenceCutoff: try container.decodeIfPresent(Double.self, forKey: .differenceCutoff) ?? 8,
      differenceSoftness: try container.decodeIfPresent(Double.self, forKey: .differenceSoftness) ?? 4,
      differenceRadius: try container.decodeIfPresent(Double.self, forKey: .differenceRadius) ?? 3,
      differenceFineDetail: try container.decodeIfPresent(Double.self,
        forKey: .differenceFineDetail) ?? 65,
      differenceStructure: try container.decodeIfPresent(Double.self, forKey: .differenceStructure) ?? 25,
      differenceDrift: try container.decodeIfPresent(Double.self, forKey: .differenceDrift) ?? 0,
      differenceGrow: try container.decodeIfPresent(Double.self, forKey: .differenceGrow) ?? 1.5,
      differenceFeather: try container.decodeIfPresent(Double.self, forKey: .differenceFeather) ?? 1.5,
      differenceReference: try container.decodeIfPresent(DifferenceKeyReference.self,
        forKey: .differenceReference) ?? .currentBackdrop,
      differenceRevealMask: try container.decodeIfPresent(MaskRecipe.self,
        forKey: .differenceRevealMask),
      differenceProtectMask: try container.decodeIfPresent(MaskRecipe.self,
        forKey: .differenceProtectMask)
    )
    // Projects written before layers carried adjustments load as neutral.
    adjustments =
      try container.decodeIfPresent(LayerAdjustments.self, forKey: .adjustments) ?? .neutral
    masks = try container.decodeIfPresent([MaskRecipe].self, forKey: .masks) ?? []
    layerMask = try container.decodeIfPresent(MaskRecipe.self, forKey: .layerMask)
    transform = try container.decodeIfPresent(LayerTransform.self, forKey: .transform)
    crop = try container.decodeIfPresent(CropRecipe.self, forKey: .crop)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(isLocked, forKey: .isLocked)
    try container.encode(zOrder, forKey: .zOrder)
    try container.encode(content, forKey: .content)
    try container.encode(compositing.blendMode, forKey: .blendMode)
    try container.encode(compositing.opacity, forKey: .opacity)
    try container.encode(compositing.fill, forKey: .fill)
    try container.encode(compositing.differenceCutoff, forKey: .differenceCutoff)
    try container.encode(compositing.differenceSoftness, forKey: .differenceSoftness)
    try container.encode(compositing.differenceRadius, forKey: .differenceRadius)
    try container.encode(compositing.differenceFineDetail, forKey: .differenceFineDetail)
    try container.encode(compositing.differenceStructure, forKey: .differenceStructure)
    try container.encode(compositing.differenceDrift, forKey: .differenceDrift)
    try container.encode(compositing.differenceGrow, forKey: .differenceGrow)
    try container.encode(compositing.differenceFeather, forKey: .differenceFeather)
    try container.encode(compositing.differenceReference, forKey: .differenceReference)
    try container.encodeIfPresent(compositing.differenceRevealMask, forKey: .differenceRevealMask)
    try container.encodeIfPresent(compositing.differenceProtectMask, forKey: .differenceProtectMask)
    try container.encode(adjustments, forKey: .adjustments)
    if !masks.isEmpty { try container.encode(masks, forKey: .masks) }
    try container.encodeIfPresent(layerMask, forKey: .layerMask)
    try container.encodeIfPresent(transform, forKey: .transform)
    try container.encodeIfPresent(crop, forKey: .crop)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case isEnabled
    case isVisible
    case isLocked
    case zOrder
    case content
    case blendMode
    case opacity
    case fill
    case differenceCutoff
    case differenceSoftness
    case differenceRadius
    case differenceFineDetail
    case differenceStructure
    case differenceDrift
    case differenceGrow
    case differenceFeather
    case differenceReference
    case differenceRevealMask
    case differenceProtectMask
    case adjustments
    case masks
    case layerMask
    case transform
    case crop
  }
}

public enum LayerMoveDirection: Equatable, Sendable {
  case up
  case down
}

/// One layer as the layers list shows it: with its depth in the group tree and
/// what it inherits from the groups above it.
public struct LayerStackEntry: Identifiable, Equatable, Sendable {
  public var layer: ProjectLayer
  public var depth: Int
  public var parentID: ProjectLayerID?
  /// Every enclosing group, outermost first.
  public var ancestorIDs: [ProjectLayerID]
  /// Whether the layer and every group around it are enabled.
  public var isEffectivelyEnabled: Bool
  /// The layer's own opacity and fill multiplied by those of every enclosing
  /// group. This is what a canvas overlay applies, since the overlay is drawn
  /// outside the group compositing the render engine does.
  public var effectiveOpacity: Double

  public var id: ProjectLayerID { layer.id }
}

public struct LayerStackRecipe: Codable, Equatable, Sendable {
  /// Layers are stored in visual stacking order, with the topmost layer first.
  ///
  /// Only the top level lives here; a group carries its own children in the
  /// same order. `flattenedLayers` walks the whole tree.
  public var layers: [ProjectLayer]
  public var activeLayerID: ProjectLayerID?

  public init(layers: [ProjectLayer] = [], activeLayerID: ProjectLayerID? = nil) {
    var ordered: [ProjectLayer]
    if Set(layers.map(\.zOrder)).count > 1 {
      ordered = layers.sorted { $0.zOrder > $1.zOrder }
    } else {
      ordered = layers
    }
    // A stack always ends in exactly one canvas layer. Rebuilding it here rather
    // than trusting the caller means no code path, including decoding an older
    // project, can produce a stack without a document extent.
    let canvas = ordered.first(where: \.isCanvasLayer)?.canvasRecipe ?? .unresolved
    ordered.removeAll(where: \.isCanvasLayer)
    ordered.append(.canvasBase(canvas))
    self.layers = ordered
    self.activeLayerID =
      activeLayerID.flatMap { candidate in
        self.layers.containsLayer(id: candidate) ? candidate : nil
      } ?? self.layers.first?.id
    normalizeZOrders()
  }

  public static let empty = LayerStackRecipe()

  public static func initialRawBackground(
    _ raw: DevelopedRawLayer = DevelopedRawLayer()
  ) -> LayerStackRecipe {
    LayerStackRecipe(layers: [.rawBase(raw)], activeLayerID: .rawBackground)
  }

  public static func migratedDefault() -> LayerStackRecipe {
    initialRawBackground()
  }

  /// Every top-level layer except the canvas, in visual stacking order.
  ///
  /// The canvas carries the document extent, not content, so anything asking
  /// "what is in this document?" asks this rather than `layers`.
  public var contentLayers: [ProjectLayer] {
    layers.filter { !$0.isCanvasLayer }
  }

  /// Every layer in the tree, groups' children included, in visual order with
  /// the topmost first. The canvas comes last.
  public var flattenedLayers: [LayerStackEntry] {
    var entries: [LayerStackEntry] = []
    layers.appendFlattened(
      to: &entries, depth: 0, ancestors: [], enabled: true, opacity: 1)
    return entries
  }

  /// Every layer in the tree, in the same order as `flattenedLayers`.
  public var allLayers: [ProjectLayer] {
    flattenedLayers.map(\.layer)
  }

  public var canvas: CanvasRecipe {
    get { layers.first(where: \.isCanvasLayer)?.canvasRecipe ?? .unresolved }
    set {
      guard let index = layers.firstIndex(where: \.isCanvasLayer) else { return }
      layers[index].content = .canvas(newValue)
    }
  }

  public var topmostEnabledLayer: ProjectLayer? {
    contentLayers.first(where: \.isEnabled)
  }

  public var topmostEnabledRawLayer: ProjectLayer? {
    flattenedLayers.first { entry in
      guard entry.isEffectivelyEnabled else { return false }
      if case .developedRaw = entry.layer.content { return true }
      return false
    }?.layer
  }

  public func layer(id: ProjectLayerID) -> ProjectLayer? {
    layers.firstLayer(id: id)
  }

  public func entry(id: ProjectLayerID) -> LayerStackEntry? {
    flattenedLayers.first { $0.id == id }
  }

  /// The group directly enclosing a layer, or `nil` at the top level.
  public func parentID(of id: ProjectLayerID) -> ProjectLayerID? {
    entry(id: id)?.parentID
  }

  /// Every group layer, outermost first, in visual order.
  public var groupLayers: [ProjectLayer] {
    allLayers.filter(\.isGroupLayer)
  }

  /// Whether `id` is `groupID` itself or sits anywhere inside it.
  public func layer(_ id: ProjectLayerID, isWithin groupID: ProjectLayerID) -> Bool {
    guard let entry = entry(id: id) else { return false }
    return entry.id == groupID || entry.ancestorIDs.contains(groupID)
  }

  /// The layers an adjustment layer changes: the enabled siblings below it in
  /// its own group, with everything inside them. A group is composited on its
  /// own before it joins the layers beneath it, so the adjustment stops at the
  /// group's edge; at the top level, "its group" is the whole stack.
  public func layersAffected(by adjustmentID: ProjectLayerID) -> [ProjectLayerID] {
    guard let entry = entry(id: adjustmentID), entry.layer.isAdjustmentLayer else { return [] }
    let siblings: [ProjectLayer] =
      if let parentID = entry.parentID {
        layer(id: parentID)?.groupLayer?.children ?? []
      } else {
        contentLayers
      }
    guard let index = siblings.firstIndex(where: { $0.id == adjustmentID }) else { return [] }
    var affected: [ProjectLayerID] = []
    for sibling in siblings[(index + 1)...] where sibling.isEnabled {
      affected.append(sibling.id)
      if let group = sibling.groupLayer {
        var nested: [LayerStackEntry] = []
        group.children.appendFlattened(
          to: &nested, depth: 0, ancestors: [], enabled: true, opacity: 1)
        affected.append(contentsOf: nested.filter(\.isEffectivelyEnabled).map(\.id))
      }
    }
    return affected
  }

  public mutating func updateLayer(
    id: ProjectLayerID,
    _ update: (inout ProjectLayer) -> Void
  ) {
    _ = layers.updateLayer(id: id, update)
  }

  public func settingEnabled(_ enabled: Bool, for id: ProjectLayerID) -> LayerStackRecipe {
    guard let layer = layer(id: id), !layer.isCanvasLayer else { return self }
    var copy = self
    copy.updateLayer(id: id) { $0.isEnabled = enabled }
    return copy.isTransformHierarchyValid ? copy : self
  }

  /// Replaces the develop adjustments of one layer.
  ///
  /// Only layers with pixels take adjustments; asking for any other layer
  /// leaves the stack unchanged.
  public func settingAdjustments(
    _ adjustments: LayerAdjustments,
    for id: ProjectLayerID
  ) -> LayerStackRecipe {
    guard let layer = layer(id: id), layer.supportsAdjustments else { return self }
    var copy = self
    copy.updateLayer(id: id) { $0.adjustments = adjustments }
    return copy
  }

  /// Replaces the decoder recipe for one RAW layer. The document may contain
  /// several independent RAW sources, so this never reaches a sibling.
  public func settingRawDevelopment(
    _ rawDevelopment: RawDevelopmentRecipe,
    for id: ProjectLayerID
  ) -> LayerStackRecipe {
    guard layer(id: id)?.isDevelopedRaw == true else { return self }
    var copy = self
    copy.updateLayer(id: id) { layer in
      guard case .developedRaw(var raw) = layer.content else { return }
      raw.rawDevelopment = rawDevelopment
      layer.content = .developedRaw(raw)
    }
    return copy
  }

  /// Replaces the upright recipe for one RAW layer.
  public func settingRawUpright(
    _ upright: UprightRecipe,
    for id: ProjectLayerID
  ) -> LayerStackRecipe {
    guard layer(id: id)?.isDevelopedRaw == true else { return self }
    var copy = self
    copy.updateLayer(id: id) { layer in
      guard case .developedRaw(var raw) = layer.content else { return }
      raw.upright = upright.clamped
      layer.content = .developedRaw(raw)
    }
    return copy
  }

  public func settingBlendMode(_ mode: LayerBlendMode, for id: ProjectLayerID)
    -> LayerStackRecipe
  {
    settingCompositing(for: id) { $0.blendMode = mode }
  }

  public func settingOpacity(_ opacity: Double, for id: ProjectLayerID) -> LayerStackRecipe {
    settingCompositing(for: id) { $0.opacity = LayerCompositing.clamped(opacity) }
  }

  public func settingFill(_ fill: Double, for id: ProjectLayerID) -> LayerStackRecipe {
    settingCompositing(for: id) { $0.fill = LayerCompositing.clamped(fill) }
  }

  public func settingDifferenceCutoff(_ cutoff: Double, for id: ProjectLayerID) -> LayerStackRecipe {
    settingCompositing(for: id) {
      $0.differenceCutoff = LayerCompositing.clampedPercentage(cutoff, fallback: 8)
    }
  }

  public func settingDifferenceSoftness(_ softness: Double, for id: ProjectLayerID)
    -> LayerStackRecipe
  {
    settingCompositing(for: id) {
      $0.differenceSoftness = LayerCompositing.clampedPercentage(softness, fallback: 4)
    }
  }

  public func settingDifferenceRadius(_ radius: Double, for id: ProjectLayerID) -> LayerStackRecipe {
    settingCompositing(for: id) { $0.differenceRadius = LayerCompositing.clampedRadius(radius) }
  }

  public func settingDifferenceOptions(
    _ options: LayerCompositing, for id: ProjectLayerID
  ) -> LayerStackRecipe {
    settingCompositing(for: id) { current in
      current.differenceStructure = LayerCompositing.clampedPercentage(
        options.differenceStructure, fallback: 25)
      current.differenceFineDetail = LayerCompositing.clampedPercentage(
        options.differenceFineDetail, fallback: 65)
      current.differenceDrift = LayerCompositing.clampedPercentage(
        options.differenceDrift, fallback: 0)
      current.differenceGrow = LayerCompositing.clampedSignedRadius(options.differenceGrow)
      current.differenceFeather = LayerCompositing.clampedRadius(options.differenceFeather)
      current.differenceReference = options.differenceReference
      current.differenceRevealMask = options.differenceRevealMask
      current.differenceProtectMask = options.differenceProtectMask
    }
  }

  private func settingCompositing(
    for id: ProjectLayerID,
    _ update: (inout LayerCompositing) -> Void
  ) -> LayerStackRecipe {
    guard let layer = layer(id: id), !layer.isCanvasLayer else { return self }
    var copy = self
    copy.updateLayer(id: id) { update(&$0.compositing) }
    return copy
  }

  public func settingText(_ text: TextLayer, for id: ProjectLayerID) -> LayerStackRecipe {
    guard layer(id: id)?.isTextLayer == true else { return self }
    var copy = self
    copy.updateLayer(id: id) { $0.content = .text(text) }
    return copy
  }

  /// Appends a completed stroke to an existing paint layer.
  ///
  /// The whole append is one value change. Pointer events never call this;
  /// `ProjectDocument` invokes it once when the gesture commits.
  public func appending(_ stroke: PaintStroke, toPaintLayer id: ProjectLayerID)
    -> LayerStackRecipe
  {
    guard let layer = layer(id: id), var paint = layer.paintLayer, !layer.isLocked else {
      return self
    }
    paint.append(stroke)
    var copy = self
    copy.updateLayer(id: id) { $0.content = .paint(paint) }
    copy.activeLayerID = id
    return copy
  }

  public func appending(_ heal: PaintHealRecipe, toPaintLayer id: ProjectLayerID)
    -> LayerStackRecipe
  {
    guard let layer = layer(id: id), var paint = layer.paintLayer, !layer.isLocked,
      paint.acceptsHeals
    else {
      return self
    }
    paint.append(heal)
    var copy = self
    copy.updateLayer(id: id) { $0.content = .paint(paint) }
    copy.activeLayerID = id
    return copy
  }

  public func settingAdjustment(_ adjustment: AdjustmentRecipe, for id: ProjectLayerID)
    -> LayerStackRecipe
  {
    guard layer(id: id)?.isAdjustmentLayer == true else { return self }
    var copy = self
    copy.updateLayer(id: id) { $0.content = .adjustment(adjustment) }
    return copy
  }

  /// Puts a new content layer directly above the active layer, inside the
  /// same group, and selects it.
  ///
  /// New content lands where the user is working, the way an image editor
  /// inserts above the selection. With nothing selected, or the canvas
  /// selected, it lands on top of the stack.
  public func adding(_ layer: ProjectLayer) -> LayerStackRecipe {
    guard !layer.isCanvasLayer, !layers.containsLayer(id: layer.id) else { return self }
    var copy = self
    var insertedBesideSelection = false
    if let activeLayerID, activeLayerID != .canvas {
      insertedBesideSelection = copy.layers.insert(layer, above: activeLayerID)
    }
    if !insertedBesideSelection {
      copy.layers.insert(layer, at: 0)
    }
    copy.activeLayerID = layer.id
    copy.normalizeZOrders()
    return copy.isTransformHierarchyValid ? copy : self
  }

  public func duplicating(_ id: ProjectLayerID, as duplicateID: ProjectLayerID)
    -> LayerStackRecipe
  {
    guard
      !layers.containsLayer(id: duplicateID),
      let original = layer(id: id),
      !original.isCanvasLayer
    else { return self }

    var copy = self
    var duplicate = original.withFreshDescendantIDs()
    duplicate.id = duplicateID
    duplicate.name = availableDuplicateName(for: duplicate.name)
    guard copy.layers.insert(duplicate, above: id) else { return self }
    copy.activeLayerID = duplicateID
    copy.normalizeZOrders()
    return copy.isTransformHierarchyValid ? copy : self
  }

  /// Validates a multi-layer selection for a lossless source-over merge.
  ///
  /// The selected range must be self-contained. Normal blend modes compose
  /// associatively over transparency; direct adjustment layers and non-normal
  /// modes depend on an outside backdrop and are refused rather than changing
  /// the document while appearing to succeed.
  public func mergePlan(for selectedIDs: Set<ProjectLayerID>) -> LayerMergePlan? {
    guard selectedIDs.count >= 2 else { return nil }
    let selectedEntries = selectedIDs.compactMap(entry(id:))
    guard selectedEntries.count == selectedIDs.count,
      let firstEntry = selectedEntries.first
    else { return nil }
    let parentID = firstEntry.parentID
    guard selectedEntries.allSatisfy({ $0.parentID == parentID }) else { return nil }

    let siblings: [ProjectLayer]
    if let parentID {
      guard let group = layer(id: parentID)?.groupLayer else { return nil }
      siblings = group.children
    } else {
      siblings = contentLayers
    }
    let indexes = siblings.indices.filter { selectedIDs.contains(siblings[$0].id) }
    guard let first = indexes.first, let last = indexes.last,
      indexes.count == last - first + 1
    else { return nil }
    let selected = Array(siblings[first...last])
    func containsLockedLayer(_ layer: ProjectLayer) -> Bool {
      if layer.isLocked { return true }
      guard let group = layer.groupLayer else { return false }
      return group.children.contains(where: containsLockedLayer)
    }
    func containsUnsupportedVectorEffects(_ layer: ProjectLayer) -> Bool {
      if layer.isVectorLayer {
        return layer.compositing.blendMode != .normal || !layer.masks.isEmpty
          || layer.layerMask != nil || layer.transform != nil
      }
      guard let group = layer.groupLayer else { return false }
      return group.children.contains(where: containsUnsupportedVectorEffects)
    }
    guard
      selected.allSatisfy({ layer in
        !layer.isCanvasLayer && !containsLockedLayer(layer) && layer.isEnabled
          && layer.compositing.blendMode == .normal && !layer.isAdjustmentLayer
          && !containsUnsupportedVectorEffects(layer)
      })
    else { return nil }
    return LayerMergePlan(layerIDs: selected.map(\.id), parentID: parentID)
  }

  /// Replaces one validated sibling range with its authored raster result.
  public func merging(_ plan: LayerMergePlan, into merged: ProjectLayer) -> LayerStackRecipe {
    guard !merged.isCanvasLayer, mergePlan(for: Set(plan.layerIDs)) == plan else { return self }
    var copy = self
    let selected = Set(plan.layerIDs)
    if let parentID = plan.parentID {
      copy.updateLayer(id: parentID) { parent in
        guard var group = parent.groupLayer,
          let first = group.children.firstIndex(where: { selected.contains($0.id) })
        else { return }
        group.children.removeAll { selected.contains($0.id) }
        group.children.insert(merged, at: first)
        parent.content = .group(group)
      }
    } else {
      guard let first = copy.layers.firstIndex(where: { selected.contains($0.id) }) else {
        return self
      }
      copy.layers.removeAll { selected.contains($0.id) }
      copy.layers.insert(merged, at: first)
    }
    copy.activeLayerID = merged.id
    copy.normalizeZOrders()
    return copy.isTransformHierarchyValid ? copy : self
  }

  /// Replaces editable vector content without disturbing the layer's outer
  /// masks, compositing, transform, name, identity, or stack position.
  public func rasterizing(_ id: ProjectLayerID, as raster: RasterLayerRecipe) -> LayerStackRecipe {
    guard let layer = layer(id: id), layer.isVectorLayer, !layer.isLocked else { return self }
    var copy = self
    copy.updateLayer(id: id) { $0.content = .raster(raster) }
    copy.activeLayerID = id
    return copy
  }

  /// Takes a layer out of the stack, wherever it sits.
  ///
  /// The selection moves to the layer that takes its slot, then to the one
  /// above, then to the enclosing group, so the inspector never ends up with
  /// nothing selected while there is still something to select.
  public func removing(_ id: ProjectLayerID) -> LayerStackRecipe {
    guard let entry = entry(id: id), !entry.layer.isCanvasLayer else { return self }
    let visible = flattenedLayers
    let index = visible.firstIndex { $0.id == id } ?? 0
    var copy = self
    guard copy.layers.removeLayer(id: id) != nil else { return self }
    let activeSurvives = activeLayerID.map { copy.layer(id: $0) != nil } ?? false
    if !activeSurvives {
      let remaining = copy.flattenedLayers
      let successor = visible[(index + 1)...].first { candidate in
        !candidate.ancestorIDs.contains(id) && remaining.contains { $0.id == candidate.id }
      }
      let predecessor = visible[..<index].last { candidate in
        remaining.contains { $0.id == candidate.id }
      }
      copy.activeLayerID = successor?.id ?? predecessor?.id ?? remaining.first?.id
    }
    copy.normalizeZOrders()
    return copy
  }

  /// Swaps a layer with its neighbour among its siblings.
  ///
  /// A layer stays in its group: reaching the edge of a group stops rather
  /// than climbing out, which is what `movingToGroup` is for.
  public func moving(_ id: ProjectLayerID, _ direction: LayerMoveDirection) -> LayerStackRecipe {
    guard let entry = entry(id: id), !entry.layer.isCanvasLayer else { return self }
    var copy = self
    let moved: Bool
    if let parentID = entry.parentID {
      var swapped = false
      copy.updateLayer(id: parentID) { parent in
        guard var group = parent.groupLayer else { return }
        swapped = group.children.swapNeighbour(of: id, direction, limit: group.children.count)
        parent.content = .group(group)
      }
      moved = swapped
    } else {
      // The canvas is always the last element, so content layers stay above it.
      moved = copy.layers.swapNeighbour(of: id, direction, limit: contentLayers.count)
    }
    guard moved else { return self }
    copy.normalizeZOrders()
    return copy
  }

  /// Wraps a layer in a new group that takes its place in the stack.
  public func grouping(
    _ id: ProjectLayerID,
    into groupID: ProjectLayerID,
    name: String = "Group"
  ) -> LayerStackRecipe {
    guard let layer = layer(id: id), !layer.isCanvasLayer, !layers.containsLayer(id: groupID)
    else { return self }
    var copy = self
    let group = ProjectLayer(
      id: groupID,
      name: availableGroupName(name),
      content: .group(GroupLayer(children: [layer]))
    )
    guard copy.layers.replaceLayer(id: id, with: group) else { return self }
    copy.activeLayerID = groupID
    copy.normalizeZOrders()
    return copy.isTransformHierarchyValid ? copy : self
  }

  /// Dissolves a group, leaving its children in its place.
  public func ungrouping(_ groupID: ProjectLayerID) -> LayerStackRecipe {
    guard let group = layer(id: groupID)?.groupLayer else { return self }
    // A non-identity mapping would have to be absorbed into each child. The
    // model intentionally refuses this for now rather than baking pixels or
    // silently altering geometry.
    guard layer(id: groupID)?.transform?.isIdentity ?? true else { return self }
    var copy = self
    guard copy.layers.replaceLayer(id: groupID, with: group.children) else { return self }
    if activeLayerID == groupID {
      copy.activeLayerID = group.children.first?.id ?? copy.layers.first?.id
    }
    copy.normalizeZOrders()
    return copy.isTransformHierarchyValid ? copy : self
  }

  /// Moves a layer to the top of a group, or to the top of the stack when
  /// `groupID` is `nil`.
  ///
  /// A group cannot be moved into itself or into one of its own descendants,
  /// and a layer that is already a direct child of the target stays put.
  public func movingToGroup(_ id: ProjectLayerID, _ groupID: ProjectLayerID?) -> LayerStackRecipe {
    guard let entry = entry(id: id), !entry.layer.isCanvasLayer, entry.parentID != groupID
    else { return self }
    if let groupID {
      guard layer(id: groupID)?.isGroupLayer == true, !layer(groupID, isWithin: id) else {
        return self
      }
    }
    var copy = self
    guard let moved = copy.layers.removeLayer(id: id) else { return self }
    if let groupID {
      var inserted = false
      copy.updateLayer(id: groupID) { parent in
        guard var group = parent.groupLayer else { return }
        group.children.insert(moved, at: 0)
        parent.content = .group(group)
        inserted = true
      }
      guard inserted else { return self }
    } else {
      copy.layers.insert(moved, at: 0)
    }
    copy.normalizeZOrders()
    return copy.isTransformHierarchyValid ? copy : self
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedLayers = try container.decodeIfPresent([ProjectLayer].self, forKey: .layers) ?? []
    let activeLayerID = try container.decodeIfPresent(ProjectLayerID.self, forKey: .activeLayerID)
    self.init(layers: decodedLayers, activeLayerID: activeLayerID)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(layers, forKey: .layers)
    try container.encodeIfPresent(activeLayerID, forKey: .activeLayerID)
  }

  /// Numbers every layer in the tree from the canvas upward, so a layer's
  /// `zOrder` orders it against any other layer in the document, whichever
  /// group either of them is in. A group's number sits above its children's.
  private mutating func normalizeZOrders() {
    var next = 0
    layers.assignZOrders(next: &next)
  }

  private func availableDuplicateName(for name: String) -> String {
    let existing = Set(allLayers.map(\.name))
    let firstCandidate = "\(name) Copy"
    guard existing.contains(firstCandidate) else { return firstCandidate }
    var number = 2
    while existing.contains("\(firstCandidate) \(number)") {
      number += 1
    }
    return "\(firstCandidate) \(number)"
  }

  private func availableGroupName(_ name: String) -> String {
    let existing = Set(allLayers.map(\.name))
    guard existing.contains(name) else { return name }
    var number = 2
    while existing.contains("\(name) \(number)") {
      number += 1
    }
    return "\(name) \(number)"
  }

  private enum CodingKeys: String, CodingKey {
    case layers
    case activeLayerID
  }
}

public typealias LayerStack = LayerStackRecipe

extension ProjectLayer {
  public static func canvasBase(_ canvas: CanvasRecipe = .unresolved) -> ProjectLayer {
    ProjectLayer(
      id: .canvas,
      name: "Canvas",
      isEnabled: true,
      isLocked: true,
      zOrder: 0,
      content: .canvas(canvas)
    )
  }

  public static func image(
    _ image: ImageLayer,
    id: ProjectLayerID = ProjectLayerID(),
    name: String? = nil
  ) -> ProjectLayer {
    ProjectLayer(
      id: id,
      name: name ?? image.source.originalFilename,
      isEnabled: true,
      isLocked: false,
      zOrder: 0,
      content: .image(image)
    )
  }

  public static func raster(
    _ raster: RasterLayerRecipe,
    id: ProjectLayerID = ProjectLayerID(),
    name: String = "Raster Layer"
  ) -> ProjectLayer {
    ProjectLayer(id: id, name: name, content: .raster(raster))
  }

  public static func paint(
    _ paint: PaintLayerRecipe = PaintLayerRecipe(),
    id: ProjectLayerID = ProjectLayerID(),
    name: String = "Paint Layer"
  ) -> ProjectLayer {
    ProjectLayer(
      id: id,
      name: name,
      isEnabled: true,
      isLocked: false,
      zOrder: 0,
      content: .paint(paint)
    )
  }

  public static func rawBase(
    _ raw: DevelopedRawLayer = DevelopedRawLayer(),
    id: ProjectLayerID = .rawBackground
  ) -> ProjectLayer {
    ProjectLayer(
      id: id,
      name: "RAW Background",
      isEnabled: true,
      isLocked: true,
      zOrder: 0,
      content: .developedRaw(raw)
    )
  }

  /// A second RAW developed independently and then placed on this canvas.
  /// Unlike `rawBase`, it is not locked and its non-nil frame prevents it from
  /// defining the document extent.
  public static func placedRaw(
    _ raw: DevelopedRawLayer,
    id: ProjectLayerID = ProjectLayerID(),
    name: String? = nil
  ) -> ProjectLayer {
    ProjectLayer(
      id: id,
      name: name ?? raw.source?.originalFilename ?? "RAW Layer",
      isEnabled: true,
      isLocked: false,
      zOrder: 0,
      content: .developedRaw(raw)
    )
  }

  public static func text(
    _ text: TextLayer,
    id: ProjectLayerID = ProjectLayerID(),
    name: String? = nil
  ) -> ProjectLayer {
    let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return ProjectLayer(
      id: id,
      name: name ?? (trimmed.isEmpty ? "Text" : String(trimmed.prefix(24))),
      content: .text(text)
    )
  }

  public static func group(
    _ children: [ProjectLayer] = [],
    id: ProjectLayerID = ProjectLayerID(),
    name: String = "Group"
  ) -> ProjectLayer {
    ProjectLayer(id: id, name: name, content: .group(GroupLayer(children: children)))
  }

  public static func adjustment(
    _ adjustment: AdjustmentRecipe,
    id: ProjectLayerID = ProjectLayerID(),
    name: String? = nil
  ) -> ProjectLayer {
    ProjectLayer(id: id, name: name ?? adjustment.label, content: .adjustment(adjustment))
  }

  /// A copy whose nested layers all carry new identifiers, so duplicating a
  /// group never puts two layers with one id in the document.
  fileprivate func withFreshDescendantIDs() -> ProjectLayer {
    guard var group = groupLayer else { return self }
    group.children = group.children.map { child in
      var fresh = child.withFreshDescendantIDs()
      fresh.id = ProjectLayerID()
      return fresh
    }
    var copy = self
    copy.content = .group(group)
    return copy
  }
}

extension Array where Element == ProjectLayer {
  func containsLayer(id: ProjectLayerID) -> Bool {
    firstLayer(id: id) != nil
  }

  func firstLayer(id: ProjectLayerID) -> ProjectLayer? {
    for layer in self {
      if layer.id == id { return layer }
      if let group = layer.groupLayer, let nested = group.children.firstLayer(id: id) {
        return nested
      }
    }
    return nil
  }

  @discardableResult
  mutating func updateLayer(
    id: ProjectLayerID,
    _ update: (inout ProjectLayer) -> Void
  ) -> Bool {
    for index in indices {
      if self[index].id == id {
        update(&self[index])
        return true
      }
      guard var group = self[index].groupLayer else { continue }
      if group.children.updateLayer(id: id, update) {
        self[index].content = .group(group)
        return true
      }
    }
    return false
  }

  mutating func removeLayer(id: ProjectLayerID) -> ProjectLayer? {
    for index in indices {
      if self[index].id == id {
        return remove(at: index)
      }
      guard var group = self[index].groupLayer else { continue }
      if let removed = group.children.removeLayer(id: id) {
        self[index].content = .group(group)
        return removed
      }
    }
    return nil
  }

  /// Inserts directly above the named layer, in that layer's own group.
  mutating func insert(_ layer: ProjectLayer, above id: ProjectLayerID) -> Bool {
    replaceLayer(id: id) { existing in [layer, existing] }
  }

  mutating func replaceLayer(id: ProjectLayerID, with replacement: ProjectLayer) -> Bool {
    replaceLayer(id: id) { _ in [replacement] }
  }

  mutating func replaceLayer(id: ProjectLayerID, with replacements: [ProjectLayer]) -> Bool {
    replaceLayer(id: id) { _ in replacements }
  }

  private mutating func replaceLayer(
    id: ProjectLayerID,
    _ replacements: (ProjectLayer) -> [ProjectLayer]
  ) -> Bool {
    for index in indices {
      if self[index].id == id {
        replaceSubrange(index...index, with: replacements(self[index]))
        return true
      }
      guard var group = self[index].groupLayer else { continue }
      if group.children.replaceLayer(id: id, replacements) {
        self[index].content = .group(group)
        return true
      }
    }
    return false
  }

  /// Swaps a direct member with its neighbour, staying within the first
  /// `limit` elements so a trailing canvas keeps its slot.
  mutating func swapNeighbour(
    of id: ProjectLayerID,
    _ direction: LayerMoveDirection,
    limit: Int
  ) -> Bool {
    guard let index = firstIndex(where: { $0.id == id }) else { return false }
    let destination =
      switch direction {
      case .up: index - 1
      case .down: index + 1
      }
    guard destination >= 0, destination < limit else { return false }
    swapAt(index, destination)
    return true
  }

  func appendFlattened(
    to entries: inout [LayerStackEntry],
    depth: Int,
    ancestors: [ProjectLayerID],
    enabled: Bool,
    opacity: Double
  ) {
    for layer in self {
      let isEnabled = enabled && layer.isEnabled
      let effectiveOpacity = opacity * layer.opacity * layer.fill
      entries.append(
        LayerStackEntry(
          layer: layer,
          depth: depth,
          parentID: ancestors.last,
          ancestorIDs: ancestors,
          isEffectivelyEnabled: isEnabled,
          effectiveOpacity: effectiveOpacity
        ))
      if let group = layer.groupLayer {
        group.children.appendFlattened(
          to: &entries,
          depth: depth + 1,
          ancestors: ancestors + [layer.id],
          enabled: isEnabled,
          opacity: effectiveOpacity
        )
      }
    }
  }

  mutating func assignZOrders(next: inout Int) {
    for index in indices.reversed() {
      if var group = self[index].groupLayer {
        group.children.assignZOrders(next: &next)
        self[index].content = .group(group)
      }
      self[index].zOrder = next
      next += 1
    }
  }
}

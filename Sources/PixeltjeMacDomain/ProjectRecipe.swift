import Foundation

public struct SourceFingerprint: Codable, Equatable, Sendable {
  public var byteLength: UInt64
  public var modificationDate: Date?
  public var sha256: String?

  public init(byteLength: UInt64, modificationDate: Date?, sha256: String? = nil) {
    self.byteLength = byteLength
    self.modificationDate = modificationDate
    self.sha256 = sha256
  }
}

/// A link to an image file that stays outside the project.
///
/// A project records where its pixels live and how to recognize that file
/// again; it never stores a copy of them. Saving is therefore small and fast,
/// and the original file remains the single source of truth for both the RAW
/// background and every placed image layer.
public struct SourceReference: Codable, Equatable, Sendable {
  public var originalFilename: String
  public var linkedPath: String?
  public var securityScopedBookmark: Data?
  public var fingerprint: SourceFingerprint

  public init(
    originalFilename: String,
    linkedPath: String?,
    securityScopedBookmark: Data?,
    fingerprint: SourceFingerprint
  ) {
    self.originalFilename = originalFilename
    self.linkedPath = linkedPath
    self.securityScopedBookmark = securityScopedBookmark
    self.fingerprint = fingerprint
  }
}

public struct PostProcessingRecipe: Codable, Equatable, Sendable {
  public var brightness: Double
  public var contrast: Double
  public var saturation: Double

  public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
    self.brightness = brightness
    self.contrast = contrast
    self.saturation = saturation
  }
}

public enum ExportColorSpace: String, Codable, CaseIterable, Sendable {
  case sRGB
  case displayP3
}

public struct ColorRecipe: Codable, Equatable, Sendable {
  public var workingColorSpace: String
  public var exportColorSpace: ExportColorSpace

  public init(
    workingColorSpace: String = "extendedLinearDisplayP3",
    exportColorSpace: ExportColorSpace = .displayP3
  ) {
    self.workingColorSpace = workingColorSpace
    self.exportColorSpace = exportColorSpace
  }
}

public struct ProjectRecipe: Codable, Equatable, Sendable {
  /// Schema 21 adds compound vector paths: several contours drawn and filled as
  /// one object, with a non-zero or even-odd fill rule, which is what holes and
  /// Boolean results need. A schema 20 project holds only paths and shapes and
  /// decodes unchanged.
  /// Schema 20 completes the vector stroke model: miter limit, dash phase,
  /// inside/center/outside alignment, stroke opacity, and start and end
  /// arrowheads. A schema 19 stroke carries only color, width, cap, join, and
  /// dash lengths, and decodes with the defaults it was drawn with.
  /// Schema 19 adds parametric vector shapes: a rectangle with per-corner
  /// radii, an ellipse, a line, a polygon, and a star keep their parameters
  /// instead of being flattened into anchors when drawn. A schema 18 project
  /// holds only path objects and decodes unchanged.
  /// Schema 18 makes a vector fill a tagged recipe with its own opacity, so an
  /// object can carry a linear or radial gradient instead of one solid color. A
  /// schema 17 fill holds only a color and decodes as a fully opaque solid fill,
  /// so older projects reopen unchanged.
  /// Schema 16 adds project-local RGBA16F raster assets produced by Rasterize
  /// Layer and Merge Layers. Schema 15 adds deterministic gradient and fill paint recipes, including
  /// bounded captured contiguous-region masks. Schema 14 adds an optional
  /// paintable layer mask to every layer. Schema 13 moves each RAW source,
  /// decoder choice, and development recipe onto its own layer, so a project
  /// can opt into composing several RAWs.
  /// Schema 12 adds versioned brush-definition snapshots to paint strokes.
  /// Schema 10 captures the active selection on every paint stroke so replay
  /// remains clipped after the document selection changes.
  /// Schema 17 adds the corner radius a rectangular mask or selection rounds
  /// its corners by. Schema 9 adds the document-level active selection.
  /// Schema 8 added deterministic paint layers and their stroke surfaces.
  /// Schema 6 added text, group and adjustment layers, per-layer blend mode,
  /// opacity and fill, per-layer develop adjustments, the widened crop recipe,
  /// and upright perspective correction. Schema 7 added the shared mask model:
  /// every layer may carry `masks`, each an ordered list of generator
  /// components with a combine operation and an optional per-mask adjustment.
  /// Earlier projects decode with neutral defaults, no masks, no paint
  /// layers, and no selection, so no explicit migration step is needed.
  /// Schema 22 records prompt-driven inpainting provenance on generated raster
  /// layers while keeping the linked Core AI packages outside the project.
  /// Schema 23 records the source identity and shared mask supplied to an
  /// external ComfyUI inpainting workflow without persisting transport files.
  /// Schema 24 records source identity and transparency treatment for external
  /// image-to-image workflows without persisting temporary server uploads.
  /// Schema 25 records the selected canvas region supplied to an external
  /// image-to-image workflow so the generated layer can reproduce its crop.
  /// Schema 26 allows a model-produced raster selection to retain its native
  /// resolution and placement on the canvas. Schema 27 adds editable
  /// generated-inpaint layers with project-local frozen inputs.
  /// Schema 28 adds healed patches to paint layers: project-local baked pixels
  /// with their painted coverage and the provenance they were solved from. A
  /// schema 27 paint layer has no `heals` key and decodes with none.
  /// Schema 29 adds non-destructive crop recipes to placed pixel layers.
  /// Schema 31 records both the requested and resolved generation mask source
  /// for ComfyUI inpainting, including its owning layer and mask identities.
  /// Schema 33 adds a spatial Difference Key blend mode and its saved controls.
  /// Schema 34 separates Difference Key detection/refinement controls and
  /// optionally links its generated layer to a frozen comparison source.
  public static let currentSchemaVersion = 34

  public var schemaVersion: Int
  public var source: SourceReference?
  public var rawDevelopment: RawDevelopmentRecipe
  public var crop: CropRecipe
  public var upright: UprightRecipe
  public var postProcessing: PostProcessingRecipe
  public var layerStack: LayerStackRecipe
  /// The active selection, or `nil` when nothing is selected.
  ///
  /// Every other mask belongs to the layer it acts on. A selection does not: it
  /// spans the canvas, survives selecting a different layer, and is what the
  /// brush, the adjustments and inpainting will each ask "may I change this
  /// pixel?". That makes it the third document-level thing beside the canvas
  /// extent and the crop, so it lives here rather than on a layer.
  ///
  /// It is in the recipe, not in tool state, because Deselect, Inverse and
  /// Refine are edits a user expects to take back with ⌘Z, and because a
  /// selection must still be there after a save and reopen.
  ///
  /// The two empty states mean different things and must not be conflated:
  /// `nil` is *no selection*, where editing is unrestricted; a mask whose
  /// components select nothing is an *empty selection*, where no pixel may be
  /// changed at all.
  public var selection: MaskRecipe?
  /// Guides, grid, and snap targets for the canvas the layer stack renders on.
  public var canvasSettings: CanvasSettingsRecipe
  public var color: ColorRecipe
  public var capturedOperatingSystemVersion: String

  public init(
    schemaVersion: Int = currentSchemaVersion,
    source: SourceReference? = nil,
    rawDevelopment: RawDevelopmentRecipe = RawDevelopmentRecipe(),
    crop: CropRecipe = CropRecipe(),
    upright: UprightRecipe = UprightRecipe(),
    postProcessing: PostProcessingRecipe = PostProcessingRecipe(),
    layerStack: LayerStackRecipe? = nil,
    selection: MaskRecipe? = nil,
    canvasSettings: CanvasSettingsRecipe = CanvasSettingsRecipe(),
    color: ColorRecipe = ColorRecipe(),
    capturedOperatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
  ) {
    self.schemaVersion = schemaVersion
    self.source = source
    self.rawDevelopment = rawDevelopment
    self.crop = crop
    self.upright = upright
    self.postProcessing = postProcessing
    self.layerStack = Self.layerStack(
      for: source,
      rawDevelopment: rawDevelopment,
      upright: upright,
      stored: layerStack,
      migratesLegacyRawPayload: schemaVersion <= 12
    )
    self.selection = selection
    self.canvasSettings = canvasSettings
    self.color = color
    self.capturedOperatingSystemVersion = capturedOperatingSystemVersion
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard storedSchemaVersion <= Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription:
          "This project uses a newer transform format that this version cannot render safely."
      )
    }
    schemaVersion = Self.currentSchemaVersion
    source = try container.decodeIfPresent(SourceReference.self, forKey: .source)
    rawDevelopment =
      try container.decodeIfPresent(RawDevelopmentRecipe.self, forKey: .rawDevelopment)
      ?? RawDevelopmentRecipe()
    crop = try container.decodeIfPresent(CropRecipe.self, forKey: .crop) ?? CropRecipe()
    upright = try container.decodeIfPresent(UprightRecipe.self, forKey: .upright) ?? UprightRecipe()
    postProcessing =
      try container.decodeIfPresent(PostProcessingRecipe.self, forKey: .postProcessing)
      ?? PostProcessingRecipe()
    let storedLayers = try container.decodeIfPresent(LayerStackRecipe.self, forKey: .layerStack)
    if storedLayers == nil, storedSchemaVersion <= 1 {
      layerStack = .migratedDefault()
    } else {
      layerStack = Self.layerStack(
        for: source,
        rawDevelopment: rawDevelopment,
        upright: upright,
        stored: storedLayers,
        migratesLegacyRawPayload: storedSchemaVersion <= 12
      )
    }
    guard layerStack.isTransformHierarchyValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .layerStack,
        in: container,
        debugDescription: "The project contains an invalid or unsupported layer transform."
      )
    }
    // Projects written before selections existed simply have none, which is
    // exactly "no selection" and needs no migration.
    selection = try container.decodeIfPresent(MaskRecipe.self, forKey: .selection)
    // Projects written before guides existed simply have none.
    canvasSettings =
      try container.decodeIfPresent(CanvasSettingsRecipe.self, forKey: .canvasSettings)
      ?? CanvasSettingsRecipe()
    color = try container.decodeIfPresent(ColorRecipe.self, forKey: .color) ?? ColorRecipe()
    capturedOperatingSystemVersion =
      try container.decodeIfPresent(String.self, forKey: .capturedOperatingSystemVersion)
      ?? ProcessInfo.processInfo.operatingSystemVersionString
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encodeIfPresent(source, forKey: .source)
    try container.encode(rawDevelopment, forKey: .rawDevelopment)
    try container.encode(crop, forKey: .crop)
    try container.encode(upright, forKey: .upright)
    try container.encode(postProcessing, forKey: .postProcessing)
    try container.encode(layerStack, forKey: .layerStack)
    try container.encodeIfPresent(selection, forKey: .selection)
    try container.encode(canvasSettings, forKey: .canvasSettings)
    try container.encode(color, forKey: .color)
    try container.encode(capturedOperatingSystemVersion, forKey: .capturedOperatingSystemVersion)
  }

  private static func layerStack(
    for source: SourceReference?,
    rawDevelopment: RawDevelopmentRecipe,
    upright: UprightRecipe,
    stored: LayerStackRecipe?,
    migratesLegacyRawPayload: Bool
  ) -> LayerStackRecipe {
    // Every stack now carries a canvas layer, so emptiness is a question about
    // content rather than about `layers`.
    if var stored, !stored.contentLayers.isEmpty {
      // Schema 12 and earlier stored the only RAW source and its settings on
      // the document. Give every legacy RAW reference its own equivalent
      // payload so duplicated legacy backgrounds retain their exact pixels.
      if migratesLegacyRawPayload, let source {
        for entry in stored.flattenedLayers {
          guard case .developedRaw = entry.layer.content else { continue }
          stored.updateLayer(id: entry.id) { layer in
            guard case .developedRaw(var raw) = layer.content else { return }
            if raw.source == nil { raw.source = source }
            if raw.rawDevelopment == RawDevelopmentRecipe() { raw.rawDevelopment = rawDevelopment }
            if raw.upright == UprightRecipe() { raw.upright = upright }
            layer.content = .developedRaw(raw)
          }
        }
      }
      return stored
    }
    var stack =
      source == nil
      ? LayerStackRecipe.empty
      : .initialRawBackground(
        DevelopedRawLayer(
          source: source,
          rawDevelopment: rawDevelopment,
          upright: upright
        )
      )
    // A stored extent outlives a stack that has lost its content layers.
    if let stored { stack.canvas = stored.canvas }
    return stack
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case source
    case rawDevelopment
    case crop
    case upright
    case postProcessing
    case layerStack
    case selection
    case canvasSettings
    case color
    case capturedOperatingSystemVersion
  }
}

public enum EditorAction: Equatable, Sendable {
  case setRawFloat(RawFloatParameter, Double)
  case setRawBool(RawBoolParameter, Bool)
  case resetRaw
  /// Applies a named preset's develop settings. Only the parameters the preset
  /// names change, so the as-shot white balance and the exposure survive it.
  case applyRawPreset(RawPreset)
  /// Per-layer RAW actions are the normal path. The original document-scoped
  /// cases above remain decodable and route to the active RAW for old callers.
  case setRawLayerFloat(ProjectLayerID, RawFloatParameter, Double)
  case setRawLayerBool(ProjectLayerID, RawBoolParameter, Bool)
  case resetRawLayer(ProjectLayerID)
  case applyRawLayerPreset(ProjectLayerID, RawPreset)
  case setRawLayerUpright(ProjectLayerID, UprightRecipe)
  case setPostProcessing(PostProcessingRecipe)
  case setLayerEnabled(ProjectLayerID, Bool)
  case addImageLayer(ProjectLayer)
  /// Adds a text, group or adjustment layer above the active layer.
  case addLayer(ProjectLayer)
  /// Adds the completed generated layer as one undoable step.
  case addGeneratedLayer(ProjectLayer)
  case removeLayer(ProjectLayerID)
  case duplicateLayer(ProjectLayerID, duplicateID: ProjectLayerID)
  case rasterizeLayer(ProjectLayerID, RasterLayerRecipe)
  case mergeLayers(LayerMergePlan, ProjectLayer)
  case moveLayer(ProjectLayerID, LayerMoveDirection)
  /// Wraps a layer in a new group that takes its place.
  case groupLayer(ProjectLayerID, groupID: ProjectLayerID)
  case ungroupLayer(ProjectLayerID)
  /// Moves a layer to the top of a group, or to the top level with `nil`.
  case moveLayerToGroup(ProjectLayerID, groupID: ProjectLayerID?)
  case setLayerBlendMode(ProjectLayerID, LayerBlendMode)
  case setLayerOpacity(ProjectLayerID, Double)
  case setLayerFill(ProjectLayerID, Double)
  case setLayerDifferenceCutoff(ProjectLayerID, Double)
  case setLayerDifferenceSoftness(ProjectLayerID, Double)
  case setLayerDifferenceRadius(ProjectLayerID, Double)
  case setLayerDifferenceOptions(ProjectLayerID, LayerCompositing, actionName: String)
  case setGeneratedInpaintThreshold(ProjectLayerID, Double)
  case setTextLayer(ProjectLayerID, TextLayer)
  case setPaintLayer(ProjectLayerID, PaintLayerRecipe, actionName: String)
  case setVectorLayer(ProjectLayerID, VectorLayer, actionName: String)
  case setAdjustment(ProjectLayerID, AdjustmentRecipe)
  /// Replaces an adjustment layer with an explicit History label. This is
  /// used by discrete controls such as lookup pickers and curve resets; slider
  /// gestures receive their label from `endEditGesture` instead.
  case setNamedAdjustment(ProjectLayerID, AdjustmentRecipe, actionName: String)
  /// Appends one completed brush or eraser stroke. If the named destination is
  /// not an editable paint layer, a new paint layer is inserted with `newLayerID`.
  case commitBrushStroke(
    PaintStroke,
    toPaintLayer: ProjectLayerID?,
    newLayerID: ProjectLayerID
  )
  /// Appends one solved heal patch. Heals accumulate on a paint layer that
  /// holds nothing else, so a retouching session is one layer rather than one
  /// layer per dab; when the named destination cannot take another, a new
  /// paint layer is inserted with `newLayerID`.
  case commitHeal(
    PaintHealRecipe,
    toPaintLayer: ProjectLayerID?,
    newLayerID: ProjectLayerID
  )
  /// Creates or removes the one mask that gates a layer's complete output.
  /// Most callers use the derived Add/Delete Layer Mask history label; a
  /// command such as Backspace may supply the user action that produced it.
  case setLayerMask(ProjectLayerID, MaskRecipe?, actionName: String? = nil)
  case setLayerMaskEnabled(ProjectLayerID, Bool)
  case setLayerMaskInverted(ProjectLayerID, Bool)
  /// Appends one deterministic brush/eraser stroke to the layer mask.
  case commitLayerMaskStroke(ProjectLayerID, MaskID, PaintStroke)
  /// Erases an image through its mask, creating a reveal-all mask if needed.
  case commitImageEraserStroke(ProjectLayerID, MaskID, PaintStroke)
  /// Moves a layer's content across the canvas, in canvas pixels.
  case translateLayer(ProjectLayerID, byX: Double, y: Double)
  /// Replaces the complete non-destructive transform as one undoable change.
  case setLayerTransform(ProjectLayerID, LayerTransform?)
  case setLayerStack(LayerStackRecipe, actionName: String)
  /// Sets the extent without touching what is on it. The canvas layer follows
  /// the developed RAW through this, and it is what an undo restores to.
  case setCanvasSize(CanvasRecipe)
  /// Replaces one layer's develop adjustments. The action name labels the
  /// undo step, for example "Adjust Contrast".
  case setLayerAdjustments(ProjectLayerID, LayerAdjustments, actionName: String)
  /// Resizes the canvas and places existing layers by the nine-point anchor.
  case resizeCanvas(CanvasRecipe, anchor: CanvasAnchor)
  /// Guides, grid, and snap targets, as one named undoable step.
  case setCanvasSettings(CanvasSettingsRecipe, actionName: String)
  /// Commits the crop tool. The name travels with it because the same action
  /// commits a crop, a straighten, or both, and the history should say which.
  case setCrop(CropRecipe, actionName: String)
  /// Commits a non-destructive crop to one placed pixel layer.
  case setLayerCrop(ProjectLayerID, CropRecipe?, actionName: String)
  /// Makes an arbitrary rectangle the new extent of a non-RAW canvas.
  case cropCanvas(CropRecipe, actionName: String)
  case setUpright(UprightRecipe)

  // MARK: Masks
  //
  // Every mask edit is one named undoable step. A canvas gesture — dragging a
  // gradient, painting a stroke — brackets a run of `setMask` changes between
  // `beginEditGesture` and `endEditGesture`, so the whole drag collapses into
  // the single step the gesture names.

  /// Attaches a new mask to a layer.
  case addMask(ProjectLayerID, MaskRecipe)
  case removeMask(ProjectLayerID, MaskID)
  case setMaskEnabled(ProjectLayerID, MaskID, Bool)
  /// Replaces a mask outright. This is the workhorse: a component added,
  /// removed, retuned or dragged is expressed as the mask the caller wants,
  /// with the undo step it should be called.
  case setMask(ProjectLayerID, MaskRecipe, actionName: String)
  /// Sets, changes or clears the adjustment a mask applies where it is opaque.
  case setMaskAdjustment(ProjectLayerID, MaskID, AdjustmentRecipe?)

  // MARK: Selection
  //
  // The active selection is document-level, so it is set outright rather than
  // through a layer. One action covers every way it changes — a completed
  // marquee or freehand drag, Select All, Deselect, Inverse — because in each
  // case the caller has already worked out the selection it wants and only
  // needs to say what the undo step should be called.

  case setSelection(MaskRecipe?, actionName: String)
  /// Copies the active selection onto a layer as an ordinary mask, leaving the
  /// selection itself in place. This is the one point where the shared mask
  /// model pays off directly: nothing is converted.
  case saveSelectionAsMask(ProjectLayerID, MaskID)
}

extension ProjectRecipe {
  public func applying(_ action: EditorAction) -> ProjectRecipe {
    var copy = self
    switch action {
    case .setRawFloat(let parameter, let value):
      guard var parameters = copy.rawDevelopment.parameters else { return self }
      parameters[parameter] = value
      copy.rawDevelopment.parameters = parameters
      copy.updateLegacyRawLayer { raw in
        guard var layerParameters = raw.rawDevelopment.parameters else { return }
        layerParameters[parameter] = value
        raw.rawDevelopment.parameters = layerParameters
      }
    case .setRawBool(let parameter, let value):
      guard var parameters = copy.rawDevelopment.parameters else { return self }
      parameters[parameter] = value
      copy.rawDevelopment.parameters = parameters
      copy.updateLegacyRawLayer { raw in
        guard var layerParameters = raw.rawDevelopment.parameters else { return }
        layerParameters[parameter] = value
        raw.rawDevelopment.parameters = layerParameters
      }
    case .resetRaw:
      guard let defaults = copy.rawDevelopment.capturedDefaults else { return self }
      copy.rawDevelopment.parameters = defaults
      copy.updateLegacyRawLayer { $0.rawDevelopment.parameters = defaults }
    case .applyRawPreset(let preset):
      guard let parameters = copy.rawDevelopment.parameters else { return self }
      copy.rawDevelopment.parameters = preset.applied(
        to: parameters,
        capabilities: copy.rawDevelopment.capabilities
      )
      copy.updateLegacyRawLayer { raw in
        guard let layerParameters = raw.rawDevelopment.parameters else { return }
        raw.rawDevelopment.parameters = preset.applied(
          to: layerParameters,
          capabilities: raw.rawDevelopment.capabilities
        )
      }
    case .setRawLayerFloat(let id, let parameter, let value):
      copy.updateRawLayer(id) { raw in
        guard var parameters = raw.rawDevelopment.parameters else { return }
        parameters[parameter] = value
        raw.rawDevelopment.parameters = parameters
      }
    case .setRawLayerBool(let id, let parameter, let value):
      copy.updateRawLayer(id) { raw in
        guard var parameters = raw.rawDevelopment.parameters else { return }
        parameters[parameter] = value
        raw.rawDevelopment.parameters = parameters
      }
    case .resetRawLayer(let id):
      copy.updateRawLayer(id) { raw in
        guard let defaults = raw.rawDevelopment.capturedDefaults else { return }
        raw.rawDevelopment.parameters = defaults
      }
    case .applyRawLayerPreset(let id, let preset):
      copy.updateRawLayer(id) { raw in
        guard let parameters = raw.rawDevelopment.parameters else { return }
        raw.rawDevelopment.parameters = preset.applied(
          to: parameters,
          capabilities: raw.rawDevelopment.capabilities
        )
      }
    case .setPostProcessing(let recipe):
      copy.postProcessing = recipe
    case .setLayerEnabled(let id, let enabled):
      copy.layerStack = copy.layerStack.settingEnabled(enabled, for: id)
    case .addImageLayer(let layer), .addLayer(let layer), .addGeneratedLayer(let layer):
      copy.layerStack = copy.layerStack.adding(layer)
    case .removeLayer(let id):
      copy.layerStack = copy.layerStack.removing(id)
    case .duplicateLayer(let id, let duplicateID):
      copy.layerStack = copy.layerStack.duplicating(id, as: duplicateID)
    case .rasterizeLayer(let id, let raster):
      copy.layerStack = copy.layerStack.rasterizing(id, as: raster)
    case .mergeLayers(let plan, let merged):
      copy.layerStack = copy.layerStack.merging(plan, into: merged)
    case .moveLayer(let id, let direction):
      copy.layerStack = copy.layerStack.moving(id, direction)
    case .groupLayer(let id, let groupID):
      copy.layerStack = copy.layerStack.grouping(id, into: groupID)
    case .ungroupLayer(let id):
      copy.layerStack = copy.layerStack.ungrouping(id)
    case .moveLayerToGroup(let id, let groupID):
      copy.layerStack = copy.layerStack.movingToGroup(id, groupID)
    case .setLayerBlendMode(let id, let mode):
      copy.layerStack = copy.layerStack.settingBlendMode(mode, for: id)
    case .setLayerOpacity(let id, let opacity):
      copy.layerStack = copy.layerStack.settingOpacity(opacity, for: id)
    case .setLayerFill(let id, let fill):
      copy.layerStack = copy.layerStack.settingFill(fill, for: id)
    case .setLayerDifferenceCutoff(let id, let cutoff):
      copy.layerStack = copy.layerStack.settingDifferenceCutoff(cutoff, for: id)
    case .setLayerDifferenceSoftness(let id, let softness):
      copy.layerStack = copy.layerStack.settingDifferenceSoftness(softness, for: id)
    case .setLayerDifferenceRadius(let id, let radius):
      copy.layerStack = copy.layerStack.settingDifferenceRadius(radius, for: id)
    case .setLayerDifferenceOptions(let id, let options, _):
      copy.layerStack = copy.layerStack.settingDifferenceOptions(options, for: id)
    case .setGeneratedInpaintThreshold(let id, let threshold):
      copy.layerStack.updateLayer(id: id) { layer in
        guard !layer.isLocked, case .generatedInpaint(var inpaint) = layer.content else { return }
        inpaint.changeThreshold = min(max(threshold, 0), 100)
        layer.content = .generatedInpaint(inpaint)
      }
    case .setTextLayer(let id, let text):
      copy.layerStack = copy.layerStack.settingText(text, for: id)
    case .setPaintLayer(let id, let paint, _):
      copy.layerStack.updateLayer(id: id) { layer in
        guard layer.isPaintLayer, !layer.isLocked else { return }
        layer.content = .paint(paint)
      }
    case .setVectorLayer(let id, let vector, _):
      copy.layerStack.updateLayer(id: id) { layer in
        guard layer.isVectorLayer, !layer.isLocked else { return }
        layer.content = .vector(vector)
      }
    case .setAdjustment(let id, let adjustment):
      copy.layerStack = copy.layerStack.settingAdjustment(adjustment, for: id)
    case .setNamedAdjustment(let id, let adjustment, _):
      copy.layerStack = copy.layerStack.settingAdjustment(adjustment, for: id)
    case .commitBrushStroke(let stroke, let targetID, let newLayerID):
      guard !stroke.samples.isEmpty else { return self }
      if let targetID {
        let appended = copy.layerStack.appending(stroke, toPaintLayer: targetID)
        if appended != copy.layerStack {
          copy.layerStack = appended
          break
        }
      }
      copy.layerStack = copy.layerStack.adding(
        .paint(PaintLayerRecipe(strokes: [stroke]), id: newLayerID)
      )
    case .commitHeal(let heal, let targetID, let newLayerID):
      guard heal.isRenderable else { return self }
      if let targetID {
        let appended = copy.layerStack.appending(heal, toPaintLayer: targetID)
        if appended != copy.layerStack {
          copy.layerStack = appended
          break
        }
      }
      copy.layerStack = copy.layerStack.adding(
        .paint(PaintLayerRecipe(heals: [heal]), id: newLayerID, name: "Healing")
      )
    case .setLayerMask(let id, let mask, _):
      guard let layer = copy.layerStack.layer(id: id), !layer.isCanvasLayer else { return self }
      copy.layerStack.updateLayer(id: id) { $0.layerMask = mask }
    case .setLayerMaskEnabled(let id, let enabled):
      guard var mask = copy.layerStack.layer(id: id)?.layerMask,
        mask.isEnabled != enabled
      else { return self }
      mask.isEnabled = enabled
      copy.layerStack.updateLayer(id: id) { $0.layerMask = mask }
    case .setLayerMaskInverted(let id, let inverted):
      guard var mask = copy.layerStack.layer(id: id)?.layerMask,
        mask.isInverted != inverted
      else { return self }
      mask.isInverted = inverted
      copy.layerStack.updateLayer(id: id) { $0.layerMask = mask }
    case .commitLayerMaskStroke(let id, let maskID, let stroke):
      guard !stroke.samples.isEmpty,
        let layer = copy.layerStack.layer(id: id), !layer.isLocked,
        let mask = layer.layerMask, mask.id == maskID, mask.isEnabled
      else { return self }
      let updated = mask.appendingLayerMaskStroke(stroke)
      guard updated != mask else { return self }
      copy.layerStack.updateLayer(id: id) { $0.layerMask = updated }
    case .commitImageEraserStroke(let id, let maskID, let stroke):
      guard !stroke.samples.isEmpty, stroke.mode == .erase,
        let layer = copy.layerStack.layer(id: id), layer.isImageLayer,
        !layer.isLocked
      else { return self }
      let mask: MaskRecipe
      if let existing = layer.layerMask {
        guard existing.id == maskID, existing.isEnabled, existing.strokeSurface != nil
        else { return self }
        mask = existing
      } else {
        mask = MaskRecipe.layerMask(revealsLayer: true, id: maskID)
      }
      var appliedStroke = stroke
      // Inverting the mask also reverses which paint value hides the image.
      if mask.isInverted { appliedStroke.mode = .paint }
      copy.layerStack.updateLayer(id: id) {
        $0.layerMask = mask.appendingLayerMaskStroke(appliedStroke)
      }
    case .translateLayer(let id, let deltaX, let deltaY):
      copy.layerStack = copy.layerStack.translating(id, byX: deltaX, y: deltaY)
    case .setLayerTransform(let id, let transform):
      copy.layerStack = copy.layerStack.settingTransform(transform, for: id)
    case .setLayerStack(let layerStack, _):
      guard layerStack.isTransformHierarchyValid else { return self }
      copy.layerStack = layerStack
    case .setCanvasSize(let canvas):
      copy.layerStack.canvas = canvas
    case .setLayerAdjustments(let id, let adjustments, _):
      copy.layerStack = copy.layerStack.settingAdjustments(adjustments, for: id)
    case .resizeCanvas(let canvas, let anchor):
      guard canvas.isResolved, canvas != copy.layerStack.canvas else { return self }
      let old = copy.layerStack.canvas
      copy.layerStack = copy.layerStack.resizingCanvas(to: canvas, anchor: anchor)
      copy.canvasSettings = copy.canvasSettings.resizingCanvas(
        from: old, to: canvas, anchor: anchor)
    case .setCanvasSettings(let settings, _):
      copy.canvasSettings = settings
    case .setCrop(let crop, _):
      copy.crop = crop.clamped
    case .setLayerCrop(let id, let crop, _):
      guard let layer = copy.layerStack.layer(id: id), layer.supportsLayerCrop,
        !layer.isLocked || id == .rawBackground
      else { return self }
      copy.layerStack.updateLayer(id: id) { $0.crop = crop?.clamped }
    case .cropCanvas(let crop, _):
      let oldCanvas = copy.layerStack.canvas
      guard oldCanvas.isResolved, crop.angleDegrees == 0 else { return self }
      let rectangle = CropGeometry.pixelRect(
        crop,
        imageWidth: Double(oldCanvas.width),
        imageHeight: Double(oldCanvas.height)
      )
      let newCanvas = CanvasRecipe(
        width: max(Int(rectangle.width.rounded()), 1),
        height: max(Int(rectangle.height.rounded()), 1)
      )
      let offset = CanvasOffset(x: -rectangle.x.rounded(), y: -rectangle.y.rounded())
      copy.layerStack = copy.layerStack.resizingCanvas(to: newCanvas, offset: offset)
      copy.canvasSettings = copy.canvasSettings.resizingCanvas(
        from: oldCanvas, to: newCanvas, offset: offset)
      copy.selection = copy.selection?.resizingCanvas(
        from: oldCanvas, to: newCanvas, offset: offset)
      // The selected rectangle is now the canvas itself. Retain Crop tool
      // preferences without clipping the already-cropped canvas a second time.
      copy.crop = CropRecipe(aspectRatio: crop.aspectRatio, overlay: crop.overlay)
    case .setUpright(let upright):
      copy.upright = upright.clamped
      copy.updateLegacyRawLayer { $0.upright = upright.clamped }
    case .setRawLayerUpright(let id, let upright):
      copy.updateRawLayer(id) { $0.upright = upright.clamped }
    case .addMask(let layerID, let mask):
      copy.layerStack = copy.layerStack.addingMask(mask, to: layerID)
    case .removeMask(let layerID, let maskID):
      copy.layerStack = copy.layerStack.removingMask(maskID, from: layerID)
    case .setMaskEnabled(let layerID, let maskID, let enabled):
      copy.layerStack = copy.layerStack.settingMaskEnabled(enabled, maskID, on: layerID)
    case .setMask(let layerID, let mask, _):
      copy.layerStack = copy.layerStack.settingMask(mask, on: layerID)
    case .setMaskAdjustment(let layerID, let maskID, let adjustment):
      copy.layerStack = copy.layerStack.settingMaskAdjustment(adjustment, maskID, on: layerID)
    case .setSelection(let selection, _):
      copy.selection = selection
    case .saveSelectionAsMask(let layerID, let maskID):
      guard let selection = copy.selection else { return self }
      var saved = selection
      saved.id = maskID
      saved.name =
        copy.layerStack.layer(id: layerID)?
        .availableMaskName(MaskRecipe.selectionName) ?? MaskRecipe.selectionName
      copy.layerStack = copy.layerStack.addingMask(saved, to: layerID)
    }
    return copy
  }
}

extension ProjectRecipe {
  /// Applies an edit only to one RAW layer. Mutating through the stack keeps
  /// nested RAW layers addressable without exposing the tree representation to
  /// every action case.
  fileprivate mutating func updateRawLayer(
    _ id: ProjectLayerID,
    _ update: (inout DevelopedRawLayer) -> Void
  ) {
    guard layerStack.layer(id: id)?.isDevelopedRaw == true else { return }
    layerStack.updateLayer(id: id) { layer in
      guard case .developedRaw(var raw) = layer.content else { return }
      update(&raw)
      layer.content = .developedRaw(raw)
    }
    // Keep the original document fields as an exact compatibility mirror of
    // the base RAW. Placed RAW layers deliberately have no document-scoped
    // counterpart: their sources and recipes live only on their own layer.
    if id == .rawBackground, let raw = layerStack.layer(id: id)?.developedRawLayer {
      source = raw.source
      rawDevelopment = raw.rawDevelopment
      upright = raw.upright
    }
  }

  /// Compatibility routing for document-scoped actions written by older UI
  /// code and tests. New controls always name their RAW layer explicitly.
  fileprivate mutating func updateLegacyRawLayer(_ update: (inout DevelopedRawLayer) -> Void) {
    let selected = layerStack.activeLayerID
    let target =
      selected.flatMap { layerStack.layer(id: $0)?.isDevelopedRaw == true ? $0 : nil }
      ?? layerStack.allLayers.first(where: \.isDevelopedRaw)?.id
    guard let target else { return }
    updateRawLayer(target, update)
  }
}

extension ProjectRecipe {
  /// Whether the document has an active selection at all.
  ///
  /// This says nothing about whether that selection covers any pixels: an empty
  /// selection is still a selection, and still restricts editing.
  public var hasSelection: Bool { selection != nil }
}

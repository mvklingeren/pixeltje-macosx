import Foundation

/// Guardrails for healed patches. A patch is baked pixels, so the cost of a
/// malformed or runaway one is memory and package size rather than a slow
/// render, and the bounds belong beside the other paint-operation limits.
public enum HealLimits {
  /// The largest patch a single heal may bake. A stroke whose coverage exceeds
  /// this is refused rather than solved: the solve is iterative and runs once
  /// per commit, and a patch this size already costs a visible pause. It is
  /// also far larger than any blemish; a heal covering four megapixels is
  /// asking for a different tool.
  public static let maximumPatchPixels = 4_194_304
  public static let maximumPatchAxis = 16_384
  public static let maximumHealsPerLayer = 256
  /// Solver sweeps per pyramid level. Enough for a blemish-sized patch to
  /// converge; the pyramid is what carries low-frequency information, not the
  /// sweep count.
  public static let minimumSolverIterations = 1
  public static let maximumSolverIterations = 512
  public static let defaultSolverIterations = 64
}

/// Where a heal takes its texture from.
public enum HealSourceMode: String, Codable, CaseIterable, Equatable, Sendable {
  /// Reconstructed from the ring of pixels surrounding the painted coverage.
  /// No source click: the covered area is replaced by the smoothest surface
  /// that meets its own surroundings, which is what lifts a blemish off skin
  /// or a dust spot off sky.
  case spot
  /// Texture copied from an anchor-relative region and re-fitted to the
  /// destination's color and brightness. This is the mode that can reproduce
  /// detail the destination never had.
  case sourcePoint

  public var label: String {
    switch self {
    case .spot: "Spot"
    case .sourcePoint: "Source Point"
    }
  }
}

/// Which pixels a heal reads.
///
/// Deliberately the same two choices, with the same meanings, as
/// `ColorSampleSource` and `FillSampleSource`: the composite as displayed, or
/// the active layer isolated against transparency.
public enum HealSampleSource: String, Codable, CaseIterable, Equatable, Sendable {
  case composite
  case activeLayer

  public var label: String {
    switch self {
    case .composite: "All Layers"
    case .activeLayer: "Current Layer"
    }
  }
}

/// How source pixels were re-fitted to their destination.
///
/// Recorded on the patch for the same reason `BrushEngineVersion` is recorded
/// on a stroke: a later, better method must not change the appearance of a
/// patch that has already been committed.
public enum HealBlendMethod: String, Codable, CaseIterable, Equatable, Sendable {
  /// `source + blur(destination - source)`. One separable blur, no solve. It
  /// carries the destination's low frequencies and the source's detail, which
  /// is enough for blemish work and cheap enough to feel instant.
  case colorMatched
  /// A gradient-domain solve: the source's gradients with the destination's
  /// boundary values. Slower, and the only method that holds up across a
  /// brightness gradient or near a strong edge.
  case seamless

  public var label: String {
    switch self {
    case .colorMatched: "Color Matched"
    case .seamless: "Seamless"
    }
  }
}

/// How a patch was produced, kept beside the pixels it produced.
///
/// The patch itself is baked, so none of this is needed to render it. It is
/// here so History can name the step, the inspector can explain an existing
/// patch, and a later "heal again" command has everything it needs to
/// recompute one without the user re-painting it.
public struct HealProvenance: Codable, Equatable, Sendable {
  public var mode: HealSourceMode
  /// Source offset in canonical canvas pixels, and meaningful only for
  /// `.sourcePoint`. Stored rather than an absolute anchor because the offset
  /// is what the stroke actually used at every sample along its length.
  public var sourceOffsetX: Double
  public var sourceOffsetY: Double
  public var sampleSource: HealSampleSource
  public var blend: HealBlendMethod
  public var solverIterations: Int
  /// The content revision the source pixels were read at. A patch solved
  /// against a stale frame is never committed, and keeping the number makes
  /// that checkable after the fact.
  public var baseContentRevision: UInt64

  public init(
    mode: HealSourceMode = .spot,
    sourceOffsetX: Double = 0,
    sourceOffsetY: Double = 0,
    sampleSource: HealSampleSource = .composite,
    blend: HealBlendMethod = .seamless,
    solverIterations: Int = HealLimits.defaultSolverIterations,
    baseContentRevision: UInt64 = 0
  ) {
    self.mode = mode
    self.sourceOffsetX = Self.offset(sourceOffsetX)
    self.sourceOffsetY = Self.offset(sourceOffsetY)
    self.sampleSource = sampleSource
    self.blend = blend
    self.solverIterations = min(
      max(solverIterations, HealLimits.minimumSolverIterations),
      HealLimits.maximumSolverIterations)
    self.baseContentRevision = baseContentRevision
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      mode: try values.decodeIfPresent(HealSourceMode.self, forKey: .mode) ?? .spot,
      sourceOffsetX: try values.decodeIfPresent(Double.self, forKey: .sourceOffsetX) ?? 0,
      sourceOffsetY: try values.decodeIfPresent(Double.self, forKey: .sourceOffsetY) ?? 0,
      sampleSource: try values.decodeIfPresent(HealSampleSource.self, forKey: .sampleSource)
        ?? .composite,
      blend: try values.decodeIfPresent(HealBlendMethod.self, forKey: .blend) ?? .seamless,
      solverIterations: try values.decodeIfPresent(Int.self, forKey: .solverIterations)
        ?? HealLimits.defaultSolverIterations,
      baseContentRevision: try values.decodeIfPresent(UInt64.self, forKey: .baseContentRevision)
        ?? 0
    )
  }

  private static func offset(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    let limit = Double(BrushLimits.maximumCanvasAxis)
    return min(max(value, -limit), limit)
  }

  private enum CodingKeys: String, CodingKey {
    case mode, sourceOffsetX, sourceOffsetY, sampleSource, blend, solverIterations
    case baseContentRevision
  }
}

/// One committed heal: corrected pixels, where they land, and what shape of
/// them is visible.
///
/// The pixels are baked at commit time rather than re-solved at render time.
/// A heal reads the composite it becomes part of, so re-deriving it would feed
/// a patch its own output; and a patch that re-solved against whatever happens
/// to be beneath it would change silently when an earlier edit was undone.
/// `PaintFillRecipe` freezes its captured coverage for the same reason.
///
/// Geometry lives in `frame`, never in the pixels: the patch keeps the
/// resolution it was authored at and the renderer scales it into the frame the
/// way it scales any other placed raster. A translate or a canvas resize is
/// therefore a pure value transform that never has to resample.
public struct PaintHealRecipe: Codable, Equatable, Sendable {
  /// The baked patch, cropped to the coverage bounds.
  public var patch: RasterAssetReference
  /// Where the patch lands, in canonical canvas pixels.
  public var frame: LayerFrame
  /// What was painted, as one `MaskGenerator.strokeSurface` of
  /// `StrokeSurfaceKind.mask`: hardness, pressure, spacing and the selection
  /// clip all come from the same brush engine that renders paintable layer
  /// masks, so the region is described exactly once and by the engine that
  /// already knows how.
  ///
  /// This is provenance rather than an ingredient of the render. The coverage
  /// is premultiplied into the patch's alpha when the patch is solved — a
  /// committed shape can never change, and evaluating it again on every frame
  /// would cost a canvas-sized mask render per patch. It is kept because it is
  /// the only record of what the user actually painted, which is what a later
  /// re-heal, or an inspector explaining an existing patch, would need.
  public var coverage: MaskRecipe
  public var provenance: HealProvenance

  public init(
    patch: RasterAssetReference,
    frame: LayerFrame,
    coverage: MaskRecipe,
    provenance: HealProvenance = HealProvenance()
  ) {
    self.patch = patch
    self.frame = frame
    self.coverage = coverage
    self.provenance = provenance
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      patch: try values.decode(RasterAssetReference.self, forKey: .patch),
      frame: try values.decode(LayerFrame.self, forKey: .frame),
      coverage: try values.decode(MaskRecipe.self, forKey: .coverage),
      provenance: try values.decodeIfPresent(HealProvenance.self, forKey: .provenance)
        ?? HealProvenance()
    )
  }

  /// Whether the patch is a usable size. A zero-area frame or an oversized
  /// asset renders nothing, so decoding keeps it and the render path skips it
  /// rather than failing an otherwise good project.
  public var isRenderable: Bool {
    patch.width > 0 && patch.height > 0
      && patch.width <= HealLimits.maximumPatchAxis
      && patch.height <= HealLimits.maximumPatchAxis
      && patch.width * patch.height <= HealLimits.maximumPatchPixels
      && !frame.isEmpty
  }

  /// Moves the patch and its coverage together. Doing one without the other
  /// would leave the pixels behind while their visible shape moved.
  public func translated(byX deltaX: Double, y deltaY: Double) -> PaintHealRecipe {
    PaintHealRecipe(
      patch: patch,
      frame: frame.translated(byX: deltaX, y: deltaY),
      coverage: coverage.translatedPaint(byX: deltaX, y: deltaY),
      provenance: provenance
    )
  }

  private enum CodingKeys: String, CodingKey {
    case patch, frame, coverage, provenance
  }
}

extension BrushDefinition {
  /// The tip a heal stroke lays its coverage down with.
  ///
  /// Round, and restrained so that a stroke crossing itself does not raise
  /// coverage twice: what is being painted is a region to replace, and a dab
  /// that overlapped its own path would otherwise read as two strengths of
  /// heal. Pressure sizes the tip, as it would any brush, but does not thin
  /// the coverage — a patch applied at half strength is not what a lighter
  /// touch is asking for.
  ///
  /// The preset identity is nominal: the Healing Brush has no library, and
  /// replay reads this definition rather than looking the preset back up.
  public static let healCoverage = BrushDefinition(
    presetID: .hardRound,
    tipShape: .round,
    deposition: .restrained,
    pressureAffectsSize: true,
    pressureAffectsOpacity: false
  )
}

extension MaskRecipe {
  /// The coverage shape of one heal stroke.
  ///
  /// A mask-kind stroke surface starting at zero coverage: the stroke raises
  /// it toward one exactly as painting a layer mask does, so the patch shows
  /// through where the user painted and nowhere else.
  public static func healCoverage(_ stroke: PaintStroke, id: MaskID = MaskID()) -> MaskRecipe {
    var covering = stroke
    // Coverage, not color. A heal stroke's paint color is never read, and an
    // erase-mode stroke would lower coverage it has not yet laid down.
    covering.mode = .paint
    return MaskRecipe.single(
      .strokeSurface(
        StrokeSurfaceRecipe(kind: .mask, initialCoverage: 0, strokes: [covering])),
      id: id,
      name: "Heal Coverage"
    )
  }
}

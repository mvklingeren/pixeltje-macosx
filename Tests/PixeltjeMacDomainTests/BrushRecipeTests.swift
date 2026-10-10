import Foundation
import PixeltjeMacDomain
import Testing

@Test func builtInBrushPreviewsHaveDistinctSemanticColors() {
  let presets = BrushCatalog.presets
  let colors = Set(presets.map {
    "\($0.previewColor.red),\($0.previewColor.green),\($0.previewColor.blue)"
  })

  #expect(colors.count == presets.count)

  let highlighter = BrushCatalog.preset(.chiselHighlighter).previewColor
  #expect(highlighter.red > highlighter.blue)
  #expect(highlighter.green > highlighter.blue)

  let watercolor = BrushCatalog.preset(.watercolorWash).previewColor
  #expect(watercolor.green > watercolor.red)
  #expect(watercolor.blue > watercolor.red)
}

private func sample(
  _ x: Double,
  _ y: Double,
  pressure: Double = 1,
  sequence: UInt64 = 0
) -> BrushSample {
  BrushSample(x: x, y: y, pressure: pressure, elapsedTime: Double(sequence) / 120, sequence: sequence)
}

@Test func brushRecipeRoundTripsEveryDeterministicInput() throws {
  let stroke = PaintStroke(
    engineVersion: .current,
    seed: 42,
    mode: .erase,
    settings: BrushSettings(
      size: 73.5,
      hardness: 0.36,
      opacity: 0.72,
      flow: 0.41,
      spacing: 0.09,
      pressureResponse: 0.88
    ),
    color: LinearRGBAColor(red: 0.25, green: 0.5, blue: 1.25, alpha: 0.8),
    selectionClip: .selecting(
      .rectangle(ShapeMask(origin: .zero, width: 0.5, height: 1)),
      feather: 3
    ),
    samples: [
      BrushSample(
        x: 12.5,
        y: 19.25,
        pressure: 0.35,
        tiltX: -0.4,
        tiltY: 0.7,
        rotationDegrees: 275,
        elapsedTime: 0.0125,
        sequence: 7
      )
    ]
  )
  let paint = PaintLayerRecipe(strokes: [stroke])

  let data = try JSONEncoder().encode(paint)
  #expect(try JSONDecoder().decode(PaintLayerRecipe.self, from: data) == paint)
}

@Test func malformedPersistedBrushValuesAreClamped() throws {
  let json = Data(
    """
    {
      "engineVersion": 0,
      "seed": 9,
      "mode": "paint",
      "settings": {
        "size": -30,
        "hardness": 4,
        "opacity": -2,
        "flow": 8,
        "spacing": 0,
        "pressureResponse": 3
      },
      "color": {"red": 90, "green": -3, "blue": 0.5, "alpha": 5},
      "samples": [{
        "x": 99999999,
        "y": -99999999,
        "pressure": 4,
        "tiltX": -8,
        "tiltY": 9,
        "rotationDegrees": -45,
        "elapsedTime": -2,
        "sequence": 1
      }]
    }
    """.utf8
  )
  let stroke = try JSONDecoder().decode(PaintStroke.self, from: json)

  #expect(stroke.engineVersion == BrushEngineVersion.version1)
  #expect(stroke.settings.size == BrushLimits.minimumSize)
  #expect(stroke.settings.hardness == 1)
  #expect(stroke.settings.opacity == 0)
  #expect(stroke.settings.flow == 1)
  #expect(stroke.settings.spacing == BrushLimits.minimumSpacing)
  #expect(stroke.settings.pressureResponse == 1)
  #expect(stroke.color.red == 16)
  #expect(stroke.color.green == -0.5)
  #expect(stroke.color.alpha == 1)
  #expect(stroke.samples[0].pressure == 1)
  #expect(stroke.samples[0].tiltX == -1)
  #expect(stroke.samples[0].tiltY == 1)
  #expect(stroke.samples[0].rotationDegrees == 315)
  #expect(stroke.samples[0].elapsedTime == 0)
}

@Test func builtInBrushesHaveStableDefinitionsAndNewStrokesCaptureThem() throws {
  #expect(BrushCatalog.presets.count == 14)
  #expect(Set(BrushCatalog.presets.map(\.id)).count == BrushCatalog.presets.count)
  #expect(BrushCatalog.presets(in: .pencils).map(\.id) == [.hbPencil, .sixBPencil])
  #expect(BrushCatalog.presets(in: .charcoalAndPastel).map(\.id) == [.charcoal, .softPastel])

  let preset = BrushCatalog.preset(.chiselHighlighter)
  let stroke = PaintStroke(settings: preset.settings, brush: preset.definition, samples: [sample(3, 4)])
  let reopened = try JSONDecoder().decode(PaintStroke.self, from: JSONEncoder().encode(stroke))
  #expect(reopened.engineVersion == .current)
  #expect(reopened.brush == preset.definition)
  #expect(reopened.brush?.deposition == .restrained)
}

@Test func versionOneStrokesKeepRoundStampSampling() {
  let old = PaintStroke(
    engineVersion: .version1,
    settings: BrushSettings(size: 20, opacity: 0.8, flow: 0.5, spacing: 0.25, pressureResponse: 1),
    samples: [sample(0, 0, pressure: 0.5), sample(20, 0, pressure: 1, sequence: 1)]
  )
  let stamps = old.interpolatedStamps()
  #expect(old.brush == nil)
  #expect(stamps[0].shape == .round)
  #expect(stamps[0].aspectRatio == 1)
  #expect(stamps.map(\.x) == [0, 5, 10, 15, 20])
}

@Test func pressureMappingAndDistanceInterpolationAreStable() {
  let settings = BrushSettings(
    size: 20,
    hardness: 1,
    opacity: 0.8,
    flow: 0.5,
    spacing: 0.25,
    pressureResponse: 1
  )
  let stroke = PaintStroke(
    settings: settings,
    samples: [sample(0, 0, pressure: 0.5), sample(20, 0, pressure: 1, sequence: 1)]
  )
  let stamps = stroke.interpolatedStamps()

  #expect(stamps.map(\.x) == [0, 5, 10, 15, 20])
  #expect(stamps[0].diameter == 10)
  #expect(abs(stamps[0].opacity - 0.2) < 0.000_001)
  #expect(stamps.last?.diameter == 20)
  #expect(abs((stamps.last?.opacity ?? 0) - 0.4) < 0.000_001)
}

@Test func oneSampleStrokeAlwaysProducesOneDot() {
  let stroke = PaintStroke(
    settings: BrushSettings(size: 12, spacing: 1),
    samples: [sample(8, 9, pressure: 0.4)]
  )
  let stamps = stroke.interpolatedStamps()
  #expect(stamps.count == 1)
  #expect(stamps[0].x == 8)
  #expect(stamps[0].y == 9)
}

@Test func committingStrokesCreatesThenReusesAPaintLayer() throws {
  let paintID = ProjectLayerID(rawValue: "paint")
  let first = PaintStroke(samples: [sample(10, 10)])
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 64, height: 64)
  recipe = recipe.applying(
    .commitBrushStroke(first, toPaintLayer: nil, newLayerID: paintID)
  )

  let created = try #require(recipe.layerStack.layer(id: paintID)?.paintLayer)
  #expect(created.surface.kind == .colorRGBA)
  #expect(created.surface.strokes == [first])
  #expect(recipe.layerStack.activeLayerID == paintID)

  let erase = PaintStroke(mode: .erase, samples: [sample(10, 10)])
  recipe = recipe.applying(
    .commitBrushStroke(erase, toPaintLayer: paintID, newLayerID: ProjectLayerID(rawValue: "unused"))
  )
  #expect(recipe.layerStack.layer(id: paintID)?.paintLayer?.surface.strokes == [first, erase])

  let data = try JSONEncoder().encode(recipe)
  let reopened = try JSONDecoder().decode(ProjectRecipe.self, from: data)
  #expect(reopened == recipe)
  #expect(reopened.schemaVersion == ProjectRecipe.currentSchemaVersion)
}

@Test func schemaSixWithoutPaintStillMigratesUnchanged() throws {
  var legacy = ProjectRecipe()
  legacy.schemaVersion = 6
  let data = try JSONEncoder().encode(legacy)
  let decoded = try JSONDecoder().decode(ProjectRecipe.self, from: data)
  #expect(decoded.schemaVersion == ProjectRecipe.currentSchemaVersion)
  #expect(decoded.layerStack.contentLayers.isEmpty)
}

@Test func strokesWrittenBeforeSelectionClippingDecodeAsUnrestricted() throws {
  let stroke = PaintStroke(
    selectionClip: .selecting(.rectangle(.full)),
    samples: [sample(4, 5)]
  )
  let encoded = try JSONEncoder().encode(stroke)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object.removeValue(forKey: "selectionClip")

  let legacyData = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(PaintStroke.self, from: legacyData)

  #expect(decoded.selectionClip == nil)
  #expect(decoded.samples == [sample(4, 5)])
}

@Test func everyBrushIdentityResolvesToItsOwnPreset() {
  // The lookup falls back to Hard Round, so a missing entry would otherwise
  // masquerade as a working brush instead of failing here.
  for id in BrushPresetID.allCases {
    #expect(BrushCatalog.preset(id).id == id)
  }
  #expect(BrushCatalog.hardRound.id == .hardRound)
}

@Test func tiltBroadensShadingInsteadOfNarrowingIt() {
  let preset = BrushCatalog.preset(.sixBPencil)
  func stamp(tiltX: Double) -> BrushStamp {
    PaintStroke(
      settings: preset.settings,
      brush: preset.definition,
      samples: [BrushSample(x: 40, y: 40, pressure: 1, tiltX: tiltX)]
    ).interpolatedStamps()[0]
  }
  let upright = stamp(tiltX: 0)
  let leaning = stamp(tiltX: 1)

  // Upright is a round point; leaning is a longer, no wider, lighter mark.
  #expect(upright.aspectRatio == 1)
  #expect(leaning.diameter > upright.diameter * 2)
  #expect(leaning.aspectRatio < 0.45)
  let uprightWidth = upright.diameter * upright.aspectRatio
  let leaningWidth = leaning.diameter * leaning.aspectRatio
  #expect(abs(leaningWidth - uprightWidth) < 0.001)
  #expect(leaning.opacity < upright.opacity)
  // The long axis follows the lean rather than a fixed screen axis.
  #expect(abs(leaning.angleRadians) < 0.001)
  #expect(abs(stamp(tiltX: -1).angleRadians - .pi) < 0.001)
}

@Test func aShapedTipIsOrientedOnItsOpeningStampToo() {
  let preset = BrushCatalog.preset(.flatBrush)
  let stamps = PaintStroke(
    settings: preset.settings,
    brush: preset.definition,
    samples: [
      BrushSample(x: 10, y: 10, sequence: 0),
      BrushSample(x: 10, y: 90, sequence: 1),
    ]
  ).interpolatedStamps()
  // Straight up: every stamp including the first faces the stroke, not zero.
  #expect(stamps.count > 1)
  for stamp in stamps { #expect(abs(stamp.angleRadians - .pi / 2) < 0.001) }
}

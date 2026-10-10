import Foundation
import PixeltjeMacDomain
import Testing

@Test func layerAdjustmentsDefaultToNeutral() {
  let adjustments = LayerAdjustments()
  #expect(adjustments.isNeutral)
  #expect(adjustments == .neutral)
  #expect(adjustments.basicTone == .neutral)
  #expect(adjustments.colorMixer == .neutral)
  #expect(adjustments.colorGrading == .neutral)
  for control in BasicToneRecipe.Control.allCases {
    #expect(adjustments.basicTone[control] == 0)
  }
  #expect(ProjectLayer.rawBase().adjustments == .neutral)
}

@Test func colorMixerAndGradingRoundTripAndIgnoreInactiveViewSettings() throws {
  var mixer = ColorMixerRecipe()
  mixer[.orange] = ColorMixerChannelAdjustment(hue: -12, saturation: 34, luminance: 8)
  mixer[.blue] = ColorMixerChannelAdjustment(hue: 20, saturation: -15, luminance: -6)
  var grading = ColorGradingRecipe()
  grading.shadows = ColorGradingWheel(hue: 220, saturation: 28, luminance: -4)
  grading.highlights = ColorGradingWheel(hue: 42, saturation: 18, luminance: 7)
  grading.blending = 72
  grading.balance = -11

  let original = LayerAdjustments(colorMixer: mixer, colorGrading: grading)
  #expect(!original.isNeutral)
  let restored = try JSONDecoder().decode(
    LayerAdjustments.self, from: JSONEncoder().encode(original))
  #expect(restored == original)

  // Hue has no effect without saturation. Blending and balance only scope a
  // visible wheel, so changing them alone remains a truly filter-free recipe.
  var neutral = ColorGradingRecipe()
  neutral.midtones.hue = 180
  neutral.blending = 0
  neutral.balance = 100
  #expect(neutral.isNeutral)
}

@Test func oldLayerAdjustmentsDecodeNewColorSectionsAsNeutral() throws {
  let json = """
    {"basicTone":{"contrast":12},"toneCurve":{},"detail":{}}
    """
  let decoded = try JSONDecoder().decode(LayerAdjustments.self, from: Data(json.utf8))
  #expect(decoded.basicTone.contrast == 12)
  #expect(decoded.colorMixer == .neutral)
  #expect(decoded.colorGrading == .neutral)
}

@Test func basicToneRoundTripsThroughJSON() throws {
  var tone = BasicToneRecipe()
  tone.exposure = 1.5
  tone.contrast = 25
  tone.highlights = -40
  tone.shadows = 30
  tone.whites = 10
  tone.blacks = -12
  tone.texture = 5
  tone.clarity = 15
  tone.dehaze = -8
  tone.vibrance = 20
  tone.saturation = -5
  let adjustments = LayerAdjustments(basicTone: tone)
  #expect(!adjustments.isNeutral)

  let data = try JSONEncoder().encode(adjustments)
  let restored = try JSONDecoder().decode(LayerAdjustments.self, from: data)
  #expect(restored == adjustments)
}

@Test func missingAdjustmentKeysDecodeAsNeutral() throws {
  // A layer written before adjustments existed, and a partial recipe from a
  // build that only knew some controls, both load with defaults.
  let legacyLayer = """
    {"id":"raw-background","name":"RAW Background","isEnabled":true,"isLocked":true,
     "zOrder":1,"content":{"type":"developedRaw"}}
    """
  let layer = try JSONDecoder().decode(ProjectLayer.self, from: Data(legacyLayer.utf8))
  #expect(layer.adjustments == .neutral)

  let partial = """
    {"basicTone":{"contrast":40}}
    """
  let adjustments = try JSONDecoder().decode(LayerAdjustments.self, from: Data(partial.utf8))
  #expect(adjustments.basicTone.contrast == 40)
  #expect(adjustments.basicTone.exposure == 0)
  #expect(adjustments.basicTone.saturation == 0)
}

@Test func schemaFiveProjectLoadsWithNeutralAdjustments() throws {
  let encoded = try JSONEncoder().encode(ProjectRecipe(source: sampleSource()))
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object["schemaVersion"] = 5
  var stack = try #require(object["layerStack"] as? [String: Any])
  var layers = try #require(stack["layers"] as? [[String: Any]])
  for index in layers.indices { layers[index].removeValue(forKey: "adjustments") }
  stack["layers"] = layers
  object["layerStack"] = stack

  let restored = try JSONDecoder().decode(
    ProjectRecipe.self, from: try JSONSerialization.data(withJSONObject: object))
  #expect(restored.schemaVersion == ProjectRecipe.currentSchemaVersion)
  #expect(restored.layerStack.layers.allSatisfy { $0.adjustments == .neutral })
}

@Test func adjustmentsBelongToTheLayerTheyActOn() {
  let project = ProjectRecipe(source: sampleSource())
  var adjustments = LayerAdjustments()
  adjustments.basicTone.contrast = 30

  let edited = project.applying(
    .setLayerAdjustments(.rawBackground, adjustments, actionName: "Adjust Contrast"))
  #expect(edited.layerStack.layer(id: .rawBackground)?.adjustments == adjustments)
  #expect(edited.layerStack.canvas == project.layerStack.canvas)

  // The canvas has no pixels and takes no adjustments.
  let canvasEdit = project.applying(
    .setLayerAdjustments(.canvas, adjustments, actionName: "Adjust Contrast"))
  #expect(canvasEdit == project)

  // Restoring neutral is the exact inverse, which is what undo relies on.
  #expect(
    edited.applying(.setLayerAdjustments(.rawBackground, .neutral, actionName: "Reset")) == project
  )

  // A duplicate carries its source layer's adjustments with it.
  let duplicateID = ProjectLayerID(rawValue: "duplicate")
  let duplicated = edited.applying(.duplicateLayer(.rawBackground, duplicateID: duplicateID))
  #expect(duplicated.layerStack.layer(id: duplicateID)?.adjustments == adjustments)
}

@Test func editedAdjustmentsSurviveProjectRoundTrip() throws {
  var adjustments = LayerAdjustments()
  adjustments.basicTone.highlights = -55
  adjustments.basicTone.exposure = 0.3
  let project = ProjectRecipe(source: sampleSource()).applying(
    .setLayerAdjustments(.rawBackground, adjustments, actionName: "Adjust Highlights"))

  let data = try JSONEncoder().encode(project)
  let restored = try JSONDecoder().decode(ProjectRecipe.self, from: data)
  #expect(restored == project)
  #expect(restored.layerStack.layer(id: .rawBackground)?.adjustments == adjustments)
}

@Test func colorEditsTargetOneRawLayerAcrossSelectionAndReopen() throws {
  let placedID = ProjectLayerID(rawValue: "placed-color-raw")
  let placedSource = SourceReference(
    originalFilename: "second.dng",
    linkedPath: "/Pictures/second.dng",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 84, modificationDate: nil)
  )
  let placed = ProjectLayer.placedRaw(
    DevelopedRawLayer(
      source: placedSource,
      frame: LayerFrame(x: 0, y: 0, width: 640, height: 480)),
    id: placedID)
  var project = ProjectRecipe(source: sampleSource()).applying(.addLayer(placed))
  var backgroundColor = LayerAdjustments.neutral
  backgroundColor.colorGrading.shadows = ColorGradingWheel(
    hue: 220, saturation: 20, luminance: -5)
  project = project.applying(
    .setLayerAdjustments(.rawBackground, backgroundColor, actionName: "Grade Shadows"))

  // Selecting the sibling changes the Develop panel target, not either
  // layer's attached recipe.
  var selectedStack = project.layerStack
  selectedStack.activeLayerID = placedID
  project = project.applying(.setLayerStack(selectedStack, actionName: "Select Layer"))
  #expect(project.layerStack.layer(id: .rawBackground)?.adjustments == backgroundColor)
  #expect(project.layerStack.layer(id: placedID)?.adjustments == .neutral)

  let restored = try JSONDecoder().decode(
    ProjectRecipe.self, from: JSONEncoder().encode(project))
  #expect(restored.layerStack.activeLayerID == placedID)
  #expect(restored.layerStack.layer(id: .rawBackground)?.adjustments == backgroundColor)
  #expect(restored.layerStack.layer(id: placedID)?.adjustments == .neutral)
}

@Test func basicToneLookupTableIsIdentityAtNeutralAndMonotone() {
  let identity = ToneLookupTable.identity()
  #expect(ToneLookupTable.basicTone(blacks: 0, whites: 0, contrast: 0) == identity)
  #expect(identity.count == ToneLookupTable.defaultSampleCount * 3)
  #expect(identity.first == 0)
  #expect(identity.last == 1)

  for (blacks, whites, contrast) in [(100.0, 0.0, 0.0), (-100, 100, 100), (0, -100, -100)] {
    let table = ToneLookupTable.basicTone(blacks: blacks, whites: whites, contrast: contrast)
    #expect(table != identity)
    for channel in 0..<3 {
      let samples = stride(from: channel, to: table.count, by: 3).map { table[$0] }
      #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    }
  }

  // Contrast pushes tones away from middle gray without moving the endpoints.
  let contrasty = ToneLookupTable.basicTone(blacks: 0, whites: 0, contrast: 60)
  #expect(contrasty[0] == 0 && contrasty[contrasty.count - 1] == 1)
  #expect(contrasty[64 * 3] < identity[64 * 3])
  #expect(contrasty[192 * 3] > identity[192 * 3])

  // Positive blacks lift the black point; positive whites brighten the top.
  #expect(ToneLookupTable.basicTone(blacks: 100, whites: 0, contrast: 0)[0] > 0)
  #expect(ToneLookupTable.basicTone(blacks: 0, whites: 100, contrast: 0)[192 * 3] == 1)
  #expect(ToneLookupTable.basicTone(blacks: 0, whites: -100, contrast: 0).last! < 1)
}

private func sampleSource() -> SourceReference {
  SourceReference(
    originalFilename: "portrait.raf",
    linkedPath: "/Pictures/portrait.raf",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil)
  )
}

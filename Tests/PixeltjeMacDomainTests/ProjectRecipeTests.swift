import Foundation
import PixeltjeMacDomain
import Testing

@Test func rawParametersRoundTripWithoutLosingValues() throws {
  var parameters = RawParameters()
  parameters[.exposure] = 1.25
  parameters[.neutralTemperature] = 5230
  parameters[.neutralTint] = -12
  parameters[.lensCorrection] = false

  let data = try JSONEncoder().encode(parameters)
  let restored = try JSONDecoder().decode(RawParameters.self, from: data)

  #expect(restored == parameters)
}

@Test func resetRestoresCapturedAppleDefaults() {
  var defaults = RawParameters()
  defaults.exposure = -0.25
  defaults.luminanceNoiseReduction = 0.48

  var changed = defaults
  changed.exposure = 2

  let project = ProjectRecipe(
    rawDevelopment: RawDevelopmentRecipe(
      decoderVersion: "9",
      parameters: changed,
      capturedDefaults: defaults
    )
  )

  #expect(project.applying(.resetRaw).rawDevelopment.parameters == defaults)
}

@Test func cropClampingKeepsAnOrderedUnitRectangle() {
  let crop = CropRecipe(left: -1, bottom: 0.2, right: 2, top: 0.1).clamped
  #expect(crop.left == 0)
  #expect(crop.bottom == 0.2)
  #expect(crop.right == 1)
  #expect(crop.top == 0.2)
}

@Test func projectRecipeIsVersionedAndCodable() throws {
  let source = SourceReference(
    originalFilename: "capture.raf",
    linkedPath: "/Pictures/capture.raf",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil, sha256: "abc")
  )
  let project = ProjectRecipe(source: source)

  let data = try JSONEncoder().encode(project)
  let restored = try JSONDecoder().decode(ProjectRecipe.self, from: data)

  #expect(restored == project)
  #expect(restored.schemaVersion == ProjectRecipe.currentSchemaVersion)
  #expect(ProjectRecipe.currentSchemaVersion == 34)
}

@Test func rawSourceCreatesAnInitialBackgroundLayer() {
  let project = ProjectRecipe(source: sampleSource())

  #expect(project.layerStack.contentLayers.count == 1)
  #expect(project.layerStack.contentLayers.first?.id == .rawBackground)
  #expect(project.layerStack.contentLayers.first?.name == "RAW Background")
  #expect(project.layerStack.contentLayers.first?.isDevelopedRaw == true)
  #expect(project.layerStack.contentLayers.first?.isEnabled == true)
}

@Test func projectWithoutRawSourceHasNoContentLayers() {
  #expect(ProjectRecipe().layerStack.contentLayers.isEmpty)
}

@Test func everyStackEndsInExactlyOneCanvasLayer() {
  for stack in [
    ProjectRecipe().layerStack,
    ProjectRecipe(source: sampleSource()).layerStack,
    LayerStackRecipe(layers: [.canvasBase(), .canvasBase(), .rawBase()]),
  ] {
    #expect(stack.layers.filter(\.isCanvasLayer).count == 1)
    #expect(stack.layers.last?.id == .canvas)
    #expect(stack.layers.last?.zOrder == 0)
  }
}

@Test func canvasLayerResistsMoveDuplicateAndHide() {
  let project = ProjectRecipe(source: sampleSource())
  let ids = project.layerStack.layers.map(\.id)

  #expect(project.applying(.moveLayer(.canvas, .up)).layerStack.layers.map(\.id) == ids)
  #expect(project.applying(.setLayerEnabled(.canvas, false)).layerStack == project.layerStack)
  #expect(
    project.applying(.duplicateLayer(.canvas, duplicateID: ProjectLayerID(rawValue: "copy")))
      .layerStack.layers.map(\.id) == ids
  )
  // A content layer cannot sink below the canvas either.
  #expect(project.applying(.moveLayer(.rawBackground, .down)).layerStack.layers.map(\.id) == ids)
}

@Test func canvasSizeIsTypedUndoReadyAndSurvivesRoundTrip() throws {
  let project = ProjectRecipe(source: sampleSource())
  #expect(project.layerStack.canvas == .unresolved)

  let resized = project.applying(.setCanvasSize(CanvasRecipe(width: 4000, height: 3000)))
  #expect(resized.layerStack.canvas == CanvasRecipe(width: 4000, height: 3000))
  #expect(resized.applying(.setCanvasSize(.unresolved)) == project)

  let data = try JSONEncoder().encode(resized)
  let restored = try JSONDecoder().decode(ProjectRecipe.self, from: data)
  #expect(restored == resized)
  #expect(restored.layerStack.canvas == CanvasRecipe(width: 4000, height: 3000))
}

@Test func canvasPresetsOfferTheSizesTheInspectorLists() {
  let hd = CanvasRecipe(width: 1920, height: 1080)
  #expect(CanvasRecipe.aspectPresets.map(\.name) == [
    "1:1", "4:5", "5:4", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16",
    "2:1", "1:2", "8:5", "5:8", "9:5", "5:9", "7:4", "4:7", "9:7", "7:9",
    "19:13", "13:19",
  ])
  #expect(CanvasRecipe.presets.count == 64)
  #expect(Set(CanvasRecipe.presets.map(\.id)).count == 64)
  let menuPixelCounts = CanvasRecipe.presets.map { $0.canvas.width * $0.canvas.height }
  #expect(menuPixelCounts == menuPixelCounts.sorted())
  for aspect in CanvasRecipe.aspectPresets {
    let pixelCounts = aspect.sizes.map { $0.canvas.width * $0.canvas.height }
    #expect(pixelCounts == pixelCounts.sorted())
    for size in aspect.sizes {
      #expect(aspect.matches(size.canvas))
      #expect(size.canvas.aspectPreset == aspect)
      #expect(size.canvas.sizePreset == size)
    }
  }
  #expect(CanvasRecipe.presets.contains { $0.canvas == hd })
  #expect(CanvasRecipe.presets.contains {
    $0.canvas == CanvasRecipe(width: 320, height: 640)
  })
  #expect(CanvasRecipe.presets.contains {
    $0.canvas == CanvasRecipe(width: 1216, height: 832)
  })
  #expect(CanvasRecipe.aspectPresets.first { $0.name == "4:5" }?.closestSize(to: hd)?.canvas
    == CanvasRecipe(width: 1280, height: 1600))
  #expect(CanvasRecipe.aspectPresets.first { $0.name == "2:1" }?.closestSize(to: hd)?.canvas
    == CanvasRecipe(width: 2048, height: 1024))
  #expect(hd.presetName == "HD 1080p")
  let custom = CanvasRecipe(width: 4000, height: 5000)
  #expect(custom.aspectPreset?.name == "4:5")
  #expect(custom.sizePreset == nil)
  #expect(custom.presetName == nil)
  #expect(CanvasRecipe(width: 512, height: 512).presetName == "1:1")
  #expect(CanvasRecipe(width: 1200, height: 810).aspectPreset == nil)

  // Choosing a preset is the same typed, undoable edit as any other resize.
  #expect(ProjectRecipe().applying(.setCanvasSize(hd)).layerStack.canvas == hd)
}

@Test func layerVisibilityIsTypedAndUndoReady() {
  let project = ProjectRecipe(source: sampleSource())
  let disabled = project.applying(.setLayerEnabled(.rawBackground, false))

  #expect(disabled.layerStack.layers.first?.isEnabled == false)
  #expect(disabled.applying(.setLayerEnabled(.rawBackground, true)) == project)
}

@Test func duplicateCreatesAUniqueLayerAboveTheSource() {
  let duplicateID = ProjectLayerID(rawValue: "duplicate")
  let project = ProjectRecipe(source: sampleSource())
  let duplicated = project.applying(
    .duplicateLayer(.rawBackground, duplicateID: duplicateID)
  )

  #expect(duplicated.layerStack.contentLayers.map(\.id) == [duplicateID, .rawBackground])
  #expect(duplicated.layerStack.contentLayers.first?.name == "RAW Background Copy")
  #expect(duplicated.layerStack.contentLayers.first?.isDevelopedRaw == true)
}

@Test func eachRawLayerKeepsItsOwnSourceAndDevelopmentRecipe() throws {
  var backgroundParameters = RawParameters()
  backgroundParameters.exposure = -0.5
  let backgroundRecipe = RawDevelopmentRecipe(
    decoderVersion: "CIRAWDecoderVersion9",
    parameters: backgroundParameters,
    capturedDefaults: backgroundParameters
  )
  let placedSource = SourceReference(
    originalFilename: "second.raf",
    linkedPath: "/Pictures/second.raf",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 84, modificationDate: nil)
  )
  var placedParameters = RawParameters()
  placedParameters.exposure = 1.25
  let placedID = ProjectLayerID(rawValue: "placed-raw")
  let placed = ProjectLayer.placedRaw(
    DevelopedRawLayer(
      source: placedSource,
      rawDevelopment: RawDevelopmentRecipe(
        decoderVersion: "CIRAWDecoderVersion9DNG",
        parameters: placedParameters,
        capturedDefaults: placedParameters
      ),
      frame: LayerFrame(x: 20, y: 30, width: 400, height: 300)
    ),
    id: placedID
  )
  let project = ProjectRecipe(source: sampleSource(), rawDevelopment: backgroundRecipe)
    .applying(.addLayer(placed))
  let adjusted = project.applying(.setRawLayerFloat(placedID, .exposure, 2))

  #expect(adjusted.source == sampleSource())
  #expect(adjusted.rawDevelopment.parameters?.exposure == -0.5)
  #expect(
    adjusted.layerStack.layer(id: .rawBackground)?.developedRawLayer?.rawDevelopment.parameters?
      .exposure == -0.5
  )
  #expect(adjusted.layerStack.layer(id: placedID)?.developedRawLayer?.source == placedSource)
  #expect(
    adjusted.layerStack.layer(id: placedID)?.developedRawLayer?.rawDevelopment.parameters?.exposure
      == 2
  )

  let restored = try JSONDecoder().decode(
    ProjectRecipe.self,
    from: JSONEncoder().encode(adjusted)
  )
  #expect(restored == adjusted)
}

@Test func legacyRawLayerPayloadIsFilledFromTheDocumentRecipe() throws {
  var parameters = RawParameters()
  parameters.exposure = 0.75
  let legacy = ProjectRecipe(
    source: sampleSource(),
    rawDevelopment: RawDevelopmentRecipe(parameters: parameters),
    layerStack: LayerStackRecipe.initialRawBackground()
  )
  var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
  object["schemaVersion"] = 12

  let restored = try JSONDecoder().decode(
    ProjectRecipe.self,
    from: JSONSerialization.data(withJSONObject: object)
  )
  let raw = try #require(restored.layerStack.layer(id: .rawBackground)?.developedRawLayer)
  #expect(raw.source == sampleSource())
  #expect(raw.rawDevelopment.parameters?.exposure == 0.75)
}

@Test func placedRawUsesItsOwnFrameForTransformAndCanvasResize() {
  let rawID = ProjectLayerID(rawValue: "placed-raw-frame")
  let placed = ProjectLayer.placedRaw(
    DevelopedRawLayer(
      source: sampleSource(),
      frame: LayerFrame(x: 20, y: 30, width: 400, height: 300)
    ),
    id: rawID
  )
  var stack = LayerStackRecipe(layers: [placed])
  stack.canvas = CanvasRecipe(width: 800, height: 600)

  #expect(stack.frame(of: rawID) == LayerFrame(x: 20, y: 30, width: 400, height: 300))
  #expect(stack.canTransform(rawID))

  let resized = stack.resizingCanvas(
    to: CanvasRecipe(width: 1_000, height: 800),
    anchor: .center
  )
  #expect(
    resized.layer(id: rawID)?.developedRawLayer?.frame
      == LayerFrame(x: 120, y: 130, width: 400, height: 300)
  )
}

@Test func schemaThirteenMultiRawProjectDoesNotMigrateBackgroundValuesOntoPlacedRaw() throws {
  var backgroundParameters = RawParameters()
  backgroundParameters.exposure = -1
  let placedID = ProjectLayerID(rawValue: "placed-default-raw")
  let project = ProjectRecipe(
    source: sampleSource(),
    rawDevelopment: RawDevelopmentRecipe(parameters: backgroundParameters)
  )
  .applying(
    .addLayer(
      .placedRaw(
        DevelopedRawLayer(
          source: SourceReference(
            originalFilename: "default.dng",
            linkedPath: "/Pictures/default.dng",
            securityScopedBookmark: nil,
            fingerprint: SourceFingerprint(byteLength: 84, modificationDate: nil)
          ),
          frame: LayerFrame(x: 0, y: 0, width: 100, height: 100)
        ),
        id: placedID
      )
    )
  )

  var encodedObject = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
  )
  encodedObject["schemaVersion"] = 13
  let restored = try JSONDecoder().decode(
    ProjectRecipe.self,
    from: JSONSerialization.data(withJSONObject: encodedObject)
  )
  #expect(restored.rawDevelopment.parameters?.exposure == -1)
  #expect(
    restored.layerStack.layer(id: placedID)?.developedRawLayer?.rawDevelopment
      == RawDevelopmentRecipe()
  )
}

@Test func layersMoveInTopToBottomVisualOrder() {
  let duplicateID = ProjectLayerID(rawValue: "duplicate")
  let project = ProjectRecipe(source: sampleSource()).applying(
    .duplicateLayer(.rawBackground, duplicateID: duplicateID)
  )

  let movedDown = project.applying(.moveLayer(duplicateID, .down))
  #expect(movedDown.layerStack.contentLayers.map(\.id) == [.rawBackground, duplicateID])
  #expect(movedDown.layerStack.topmostEnabledLayer?.id == .rawBackground)

  let movedBackUp = movedDown.applying(.moveLayer(duplicateID, .up))
  #expect(movedBackUp.layerStack.contentLayers.map(\.id) == [duplicateID, .rawBackground])
}

@Test func disabledTopLayerFallsThroughWithoutBlendingDuplicatePixels() {
  let duplicateID = ProjectLayerID(rawValue: "duplicate")
  let project = ProjectRecipe(source: sampleSource())
    .applying(.duplicateLayer(.rawBackground, duplicateID: duplicateID))

  #expect(project.layerStack.topmostEnabledLayer?.id == duplicateID)

  let topDisabled = project.applying(.setLayerEnabled(duplicateID, false))
  #expect(topDisabled.layerStack.topmostEnabledLayer?.id == .rawBackground)

  let allDisabled = topDisabled.applying(.setLayerEnabled(.rawBackground, false))
  #expect(allDisabled.layerStack.topmostEnabledLayer == nil)
}

@Test func editedLayerStackSurvivesProjectRoundTrip() throws {
  let duplicateID = ProjectLayerID(rawValue: "duplicate")
  let project = ProjectRecipe(source: sampleSource())
    .applying(.duplicateLayer(.rawBackground, duplicateID: duplicateID))
    .applying(.setLayerEnabled(.rawBackground, false))
    .applying(.moveLayer(duplicateID, .down))

  let data = try JSONEncoder().encode(project)
  let restored = try JSONDecoder().decode(ProjectRecipe.self, from: data)

  #expect(restored == project)
  #expect(restored.layerStack.contentLayers.map(\.id) == [.rawBackground, duplicateID])
  #expect(restored.layerStack.contentLayers.first?.isEnabled == false)
}

@Test func schemaOneProjectMigratesToAnInitialLayer() throws {
  let encoded = try JSONEncoder().encode(ProjectRecipe(source: sampleSource()))
  var legacyObject = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  legacyObject["schemaVersion"] = 1
  legacyObject.removeValue(forKey: "layerStack")

  let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
  let restored = try JSONDecoder().decode(ProjectRecipe.self, from: legacyData)

  #expect(restored.schemaVersion == ProjectRecipe.currentSchemaVersion)
  #expect(restored.layerStack.contentLayers.map(\.id) == [.rawBackground])
}

private func sampleSource() -> SourceReference {
  SourceReference(
    originalFilename: "portrait.raf",
    linkedPath: "/Pictures/portrait.raf",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil)
  )
}

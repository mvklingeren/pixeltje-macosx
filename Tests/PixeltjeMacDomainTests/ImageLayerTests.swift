import Foundation
import PixeltjeMacDomain
import Testing

private func imageSource(_ filename: String = "sky.png") -> SourceReference {
  SourceReference(
    originalFilename: filename,
    linkedPath: "/Pictures/\(filename)",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 1024, modificationDate: nil)
  )
}

@Test func placedImagesFitTheCanvasAndStayCentered() {
  let canvas = CanvasRecipe(width: 1920, height: 1080)

  // A camera-sized photo shrinks until it fits, keeping its aspect ratio.
  let large = LayerFrame.placing(naturalWidth: 6000, naturalHeight: 4000, in: canvas)
  #expect(large.height == 1080)
  #expect(large.width == 1620)
  #expect(large.x == 150)
  #expect(large.y == 0)

  // A smaller image keeps its own pixels rather than being blown up to fill.
  let small = LayerFrame.placing(naturalWidth: 640, naturalHeight: 480, in: canvas)
  #expect(small.width == 640)
  #expect(small.height == 480)
  #expect(small.x == 640)
  #expect(small.y == 300)

  // With no canvas size yet there is nothing to fit into, so pixels are kept.
  let unresolved = LayerFrame.placing(naturalWidth: 800, naturalHeight: 600, in: .unresolved)
  #expect(unresolved == LayerFrame(x: 0, y: 0, width: 800, height: 600))
}

@Test func addedImageLayerLandsOnTopSelectedAndAboveTheCanvas() {
  let project = ProjectRecipe(source: sampleImageProjectSource())
  let image = ImageLayer(
    source: imageSource(),
    frame: LayerFrame(x: 0, y: 0, width: 640, height: 480),
    naturalWidth: 640,
    naturalHeight: 480
  )
  let layer = ProjectLayer.image(image)

  let placed = project.applying(.addImageLayer(layer))

  #expect(placed.layerStack.layers.first?.id == layer.id)
  #expect(placed.layerStack.activeLayerID == layer.id)
  #expect(placed.layerStack.layers.last?.isCanvasLayer == true)
  #expect(placed.layerStack.contentLayers.map(\.id) == [layer.id, .rawBackground])
  // The layer names itself after the file, which is what the layer row shows.
  #expect(placed.layerStack.layers.first?.name == "sky.png")

  // Adding the same layer twice is refused rather than duplicating an id.
  #expect(placed.applying(.addImageLayer(layer)) == placed)
}

@Test func imageLayersRoundTripAsLinksWithTheirPlacement() throws {
  let image = ImageLayer(
    source: imageSource("mountain.jpg"),
    frame: LayerFrame(x: 12, y: 34, width: 800, height: 600),
    naturalWidth: 4000,
    naturalHeight: 3000
  )
  let project = ProjectRecipe(source: sampleImageProjectSource())
    .applying(.addImageLayer(.image(image)))

  let data = try JSONEncoder().encode(project)
  let restored = try JSONDecoder().decode(ProjectRecipe.self, from: data)

  #expect(restored == project)
  let restoredImage = try #require(restored.layerStack.layers.first?.imageLayer)
  #expect(restoredImage == image)
  #expect(restoredImage.source.linkedPath == "/Pictures/mountain.jpg")

  // The recipe records where the pixels live, never the pixels themselves, so a
  // project referencing a 4000 × 3000 photo stays a few hundred bytes.
  let json = try #require(String(data: data, encoding: .utf8))
  #expect(json.contains("mountain.jpg"))
  #expect(data.count < 4096)
}

@Test func legacyEmbeddedSourceKeysDecodeAsAPlainLink() throws {
  let encoded = try JSONEncoder().encode(ProjectRecipe(source: sampleImageProjectSource()))
  var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  var legacySource = try #require(legacyObject["source"] as? [String: Any])
  legacySource["storageMode"] = "embedded"
  legacySource["embeddedRelativePath"] = "Sources/portrait.raf"
  legacyObject["source"] = legacySource
  legacyObject["schemaVersion"] = 4

  let restored = try JSONDecoder().decode(
    ProjectRecipe.self,
    from: try JSONSerialization.data(withJSONObject: legacyObject)
  )

  // Sources are links now. The old embedding keys are dropped, and the link the
  // project already carried is what it renders from.
  #expect(restored.source?.linkedPath == "/Pictures/portrait.raf")
  #expect(restored.schemaVersion == ProjectRecipe.currentSchemaVersion)
}

private func sampleImageProjectSource() -> SourceReference {
  SourceReference(
    originalFilename: "portrait.raf",
    linkedPath: "/Pictures/portrait.raf",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil)
  )
}

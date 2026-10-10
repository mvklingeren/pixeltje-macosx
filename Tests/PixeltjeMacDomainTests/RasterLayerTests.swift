import Foundation
import PixeltjeMacDomain
import Testing

private func rasterReference(_ name: String = "asset") -> RasterAssetReference {
  RasterAssetReference(
    id: RasterAssetID(rawValue: name),
    width: 16,
    height: 12,
    uncompressedByteCount: 16 * 12 * 8
  )
}

private func vectorLayer(
  _ name: String,
  id: String,
  enabled: Bool = true,
  locked: Bool = false,
  blendMode: LayerBlendMode = .normal
) -> ProjectLayer {
  ProjectLayer(
    id: ProjectLayerID(rawValue: id),
    name: name,
    isEnabled: enabled,
    isLocked: locked,
    content: .vector(VectorLayer()),
    compositing: LayerCompositing(blendMode: blendMode)
  )
}

@Test func mergePlanRequiresAdjacentEnabledUnlockedNormalSiblings() throws {
  let top = vectorLayer("Top", id: "top")
  let middle = vectorLayer("Middle", id: "middle")
  let bottom = vectorLayer("Bottom", id: "bottom")
  var stack = LayerStackRecipe(layers: [top, middle, bottom], activeLayerID: top.id)

  let plan = try #require(stack.mergePlan(for: [top.id, middle.id]))
  #expect(plan.layerIDs == [top.id, middle.id])
  #expect(plan.parentID == nil)
  #expect(stack.mergePlan(for: [top.id, bottom.id]) == nil)

  stack.updateLayer(id: middle.id) { $0.isLocked = true }
  #expect(stack.mergePlan(for: [top.id, middle.id]) == nil)
  stack.updateLayer(id: middle.id) {
    $0.isLocked = false
    $0.isEnabled = false
  }
  #expect(stack.mergePlan(for: [top.id, middle.id]) == nil)
  stack.updateLayer(id: middle.id) {
    $0.isEnabled = true
    $0.compositing.blendMode = .multiply
  }
  #expect(stack.mergePlan(for: [top.id, middle.id]) == nil)

  stack.updateLayer(id: middle.id) {
    $0.compositing.blendMode = .normal
    $0.layerMask = .layerMask(revealsLayer: true)
  }
  #expect(stack.mergePlan(for: [top.id, middle.id]) == nil)
}

@Test func mergePlanDoesNotCrossGroupBoundariesAndReplacementKeepsPosition() throws {
  let childA = vectorLayer("A", id: "a")
  let childB = vectorLayer("B", id: "b")
  let sibling = vectorLayer("Sibling", id: "sibling")
  let group = ProjectLayer.group(
    [childA, childB], id: ProjectLayerID(rawValue: "group"), name: "Group")
  let stack = LayerStackRecipe(layers: [sibling, group], activeLayerID: childA.id)

  #expect(stack.mergePlan(for: [childA.id, sibling.id]) == nil)
  let plan = try #require(stack.mergePlan(for: [childA.id, childB.id]))
  let raster = RasterLayerRecipe(
    asset: rasterReference(),
    frame: LayerFrame(x: 0, y: 0, width: 16, height: 12))
  let merged = ProjectLayer.raster(
    raster, id: ProjectLayerID(rawValue: "merged"), name: "Merged Layers")
  let result = stack.merging(plan, into: merged)

  #expect(result.layer(id: group.id)?.groupLayer?.children.map(\.id) == [merged.id])
  #expect(result.contentLayers.map(\.id) == [sibling.id, group.id])
  #expect(result.activeLayerID == merged.id)
}

@Test func rasterizingVectorPreservesItsOuterLayerProperties() throws {
  let id = ProjectLayerID(rawValue: "vector")
  let mask = MaskRecipe.layerMask(revealsLayer: true)
  let transform = LayerTransform.identity(
    for: LayerFrame(x: 0, y: 0, width: 16, height: 12))
  var source = vectorLayer("Logo", id: id.rawValue)
  source.compositing.opacity = 0.4
  source.layerMask = mask
  source.transform = transform
  let stack = LayerStackRecipe(layers: [source], activeLayerID: id)
  let raster = RasterLayerRecipe(
    asset: rasterReference(),
    frame: LayerFrame(x: 0, y: 0, width: 16, height: 12))

  let result = stack.rasterizing(id, as: raster)
  let layer = try #require(result.layer(id: id))
  #expect(layer.rasterLayer == raster)
  #expect(layer.name == "Logo")
  #expect(layer.compositing.opacity == 0.4)
  #expect(layer.layerMask == mask)
  #expect(layer.transform == transform)
}

@Test func rasterLayerRoundTripsThroughProjectRecipe() throws {
  let raster = RasterLayerRecipe(
    asset: rasterReference("012345"),
    frame: LayerFrame(x: 2, y: 3, width: 16, height: 12))
  var recipe = ProjectRecipe()
  recipe.layerStack = recipe.layerStack.adding(.raster(raster, name: "Baked"))

  let restored = try JSONDecoder().decode(
    ProjectRecipe.self, from: JSONEncoder().encode(recipe))
  #expect(restored == recipe)
  #expect(restored.schemaVersion == ProjectRecipe.currentSchemaVersion)
}

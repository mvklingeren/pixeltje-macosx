import Foundation
import PixeltjeMacDomain
import Testing

private func makeText(_ string: String = "Hello") -> TextLayer {
  TextLayer(
    text: string,
    fontName: "Helvetica Neue",
    fontSize: 64,
    color: VectorColor(red: 1, green: 0.5, blue: 0, alpha: 1),
    alignment: .center,
    frame: LayerFrame(x: 10, y: 20, width: 400, height: 120)
  )
}

private func stack(_ layers: [ProjectLayer], active: ProjectLayerID? = nil) -> LayerStackRecipe {
  var recipe = LayerStackRecipe(layers: layers, activeLayerID: active)
  recipe.canvas = CanvasRecipe(width: 1920, height: 1080)
  return recipe
}

@Test func textPlacementFollowsTheCanvasPointAndStaysInsideTheCanvas() {
  let canvas = CanvasRecipe(width: 1000, height: 500)
  let placed = TextLayer.placing(
    "Text", in: canvas, centeredAt: VectorPoint(x: 0.55, y: 0.25))
  #expect(placed.frame == LayerFrame(x: 150, y: 75, width: 800, height: 101))

  let nearEdge = TextLayer.placing(
    "Text", in: canvas, centeredAt: VectorPoint(x: 0.05, y: 0.95))
  #expect(nearEdge.frame == LayerFrame(x: 0, y: 399, width: 800, height: 101))
}

// MARK: - Codable

@Test func textGroupAndAdjustmentLayersRoundTrip() throws {
  let text = ProjectLayer.text(makeText())
  let adjustment = ProjectLayer.adjustment(
    .colorControls(brightness: 0.2, contrast: 1.4, saturation: 0.75))
  var group = ProjectLayer.group([text, adjustment], name: "Titles")
  group.compositing = LayerCompositing(blendMode: .softLight, opacity: 0.4, fill: 0.6)

  let original = stack([group])
  let data = try JSONEncoder().encode(original)
  let restored = try JSONDecoder().decode(LayerStackRecipe.self, from: data)

  #expect(restored == original)
  let restoredGroup = try #require(restored.layer(id: group.id))
  #expect(restoredGroup.blendMode == .softLight)
  #expect(restoredGroup.opacity == 0.4)
  #expect(restoredGroup.fill == 0.6)
  #expect(restoredGroup.groupLayer?.children.count == 2)
  #expect(restored.layer(id: text.id)?.textLayer == makeText())
  #expect(
    restored.layer(id: adjustment.id)?.adjustment
      == .colorControls(brightness: 0.2, contrast: 1.4, saturation: 0.75))
}

@Test func everyBlendModeRoundTrips() throws {
  for mode in LayerBlendMode.allCases {
    let compositing = LayerCompositing(blendMode: mode, opacity: 0.5, fill: 0.25)
    let data = try JSONEncoder().encode(compositing)
    #expect(try JSONDecoder().decode(LayerCompositing.self, from: data) == compositing)
  }
}

@Test func differenceKeyControlsPersistAndOldLayersUseDefaults() throws {
  let layer = ProjectLayer.text(makeText())
  let recipe = ProjectRecipe(layerStack: stack([layer]))
    .applying(.setLayerBlendMode(layer.id, .differenceKey))
    .applying(.setLayerDifferenceCutoff(layer.id, 23))
    .applying(.setLayerDifferenceSoftness(layer.id, 7))
    .applying(.setLayerDifferenceRadius(layer.id, 6))
  let restored = try JSONDecoder().decode(
    ProjectRecipe.self, from: JSONEncoder().encode(recipe))
  let keyed = try #require(restored.layerStack.layer(id: layer.id))
  #expect(keyed.blendMode == .differenceKey)
  #expect(keyed.differenceCutoff == 23)
  #expect(keyed.differenceSoftness == 7)
  #expect(keyed.differenceRadius == 6)

  var oldLayer = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(layer)) as? [String: Any])
  oldLayer.removeValue(forKey: "differenceCutoff")
  oldLayer.removeValue(forKey: "differenceSoftness")
  oldLayer.removeValue(forKey: "differenceRadius")
  let decoded = try JSONDecoder().decode(
    ProjectLayer.self, from: JSONSerialization.data(withJSONObject: oldLayer))
  #expect(decoded.differenceCutoff == 8)
  #expect(decoded.differenceSoftness == 4)
  #expect(decoded.differenceRadius == 3)
}

@Test func opacityAndFillAreClampedAndKeptDistinct() {
  var layer = ProjectLayer.text(makeText())
  layer.opacity = 3
  layer.fill = -1
  #expect(layer.opacity == 1)
  #expect(layer.fill == 0)

  let recipe = stack([layer])
    .settingOpacity(0.25, for: layer.id)
    .settingFill(0.75, for: layer.id)
  #expect(recipe.layer(id: layer.id)?.opacity == 0.25)
  #expect(recipe.layer(id: layer.id)?.fill == 0.75)
}

@Test func projectsWrittenBeforeCompositingStillLoad() throws {
  // A schema 5 recipe: layers with no blendMode, opacity or fill, and no
  // canvas layer of their own.
  let json = """
    {
      "schemaVersion": 5,
      "layerStack": {
        "activeLayerID": { "rawValue": "raw-background" },
        "layers": [
          {
            "id": { "rawValue": "raw-background" },
            "name": "RAW Background",
            "isEnabled": true,
            "isLocked": true,
            "zOrder": 0,
            "content": { "type": "developedRaw" }
          }
        ]
      }
    }
    """
  let recipe = try JSONDecoder().decode(ProjectRecipe.self, from: Data(json.utf8))
  let layer = try #require(recipe.layerStack.layer(id: .rawBackground))

  #expect(recipe.schemaVersion == ProjectRecipe.currentSchemaVersion)
  #expect(layer.blendMode == .normal)
  #expect(layer.opacity == 1)
  #expect(layer.fill == 1)
  #expect(recipe.layerStack.canvas == .unresolved)
}

// MARK: - Group operations

@Test func groupingWrapsALayerAndUngroupingRestoresIt() {
  let text = ProjectLayer.text(makeText())
  let image = ProjectLayer.text(makeText("Second"))
  let original = stack([text, image], active: text.id)
  let groupID = ProjectLayerID()

  let grouped = original.grouping(text.id, into: groupID)
  #expect(grouped.contentLayers.map(\.id) == [groupID, image.id])
  #expect(grouped.layer(id: groupID)?.groupLayer?.children.map(\.id) == [text.id])
  #expect(grouped.parentID(of: text.id) == groupID)
  #expect(grouped.activeLayerID == groupID)

  let ungrouped = grouped.ungrouping(groupID)
  #expect(ungrouped.contentLayers.map(\.id) == [text.id, image.id])
  #expect(ungrouped.parentID(of: text.id) == nil)
}

@Test func layersMoveIntoAndOutOfGroups() {
  let text = ProjectLayer.text(makeText())
  let group = ProjectLayer.group(name: "Titles")
  let original = stack([group, text])

  let moved = original.movingToGroup(text.id, group.id)
  #expect(moved.parentID(of: text.id) == group.id)
  #expect(moved.contentLayers.map(\.id) == [group.id])
  #expect(moved.layer(id: text.id)?.textLayer == makeText())

  let back = moved.movingToGroup(text.id, nil)
  #expect(back.parentID(of: text.id) == nil)
  #expect(back.contentLayers.map(\.id) == [text.id, group.id])
}

@Test func aGroupCannotBeMovedIntoItself() {
  let inner = ProjectLayer.group(name: "Inner")
  let outer = ProjectLayer.group([inner], name: "Outer")
  let original = stack([outer])

  #expect(original.movingToGroup(outer.id, inner.id) == original)
  #expect(original.movingToGroup(outer.id, outer.id) == original)
  #expect(original.layer(outer.id, isWithin: outer.id))
  #expect(original.layer(inner.id, isWithin: outer.id))
  #expect(!original.layer(outer.id, isWithin: inner.id))
}

@Test func reorderingStaysInsideTheGroup() {
  let top = ProjectLayer.text(makeText("Top"))
  let bottom = ProjectLayer.text(makeText("Bottom"))
  let group = ProjectLayer.group([top, bottom], name: "Titles")
  let outside = ProjectLayer.text(makeText("Outside"))
  let original = stack([group, outside])

  let swapped = original.moving(top.id, .down)
  #expect(swapped.layer(id: group.id)?.groupLayer?.children.map(\.id) == [bottom.id, top.id])

  // The bottom child cannot climb out of the group by moving further down.
  #expect(swapped.moving(top.id, .down) == swapped)
  #expect(original.moving(top.id, .up) == original)
}

@Test func duplicatingAGroupGivesItsChildrenNewIdentifiers() throws {
  let child = ProjectLayer.text(makeText())
  let group = ProjectLayer.group([child], name: "Titles")
  let duplicateID = ProjectLayerID()

  let duplicated = stack([group]).duplicating(group.id, as: duplicateID)
  let copy = try #require(duplicated.layer(id: duplicateID)?.groupLayer)
  let copiedChild = try #require(copy.children.first)

  #expect(duplicated.activeLayerID == duplicateID)
  #expect(copiedChild.id != child.id)
  #expect(copiedChild.textLayer == makeText())
  // The original child is still there, exactly once.
  #expect(duplicated.allLayers.filter { $0.id == child.id }.count == 1)
}

@Test func removingAGroupRemovesEverythingInsideIt() {
  let child = ProjectLayer.text(makeText())
  let group = ProjectLayer.group([child], name: "Titles")
  let keeper = ProjectLayer.text(makeText("Keeper"))

  let removed = stack([group, keeper]).removing(group.id)
  #expect(removed.layer(id: child.id) == nil)
  #expect(removed.layer(id: keeper.id) != nil)
  #expect(removed.activeLayerID == keeper.id)
}

// MARK: - Adjustment scope and effective opacity

@Test func anAdjustmentReachesTheEnabledSiblingsBelowItInItsGroup() {
  let above = ProjectLayer.text(makeText("Above"))
  let adjustment = ProjectLayer.adjustment(.exposure(ev: 1))
  let below = ProjectLayer.text(makeText("Below"))
  var hidden = ProjectLayer.text(makeText("Hidden"))
  hidden.isEnabled = false
  let nestedChild = ProjectLayer.text(makeText("Nested"))
  let nestedGroup = ProjectLayer.group([nestedChild], name: "Nested")

  let recipe = stack([above, adjustment, below, hidden, nestedGroup])
  let affected = recipe.layersAffected(by: adjustment.id)

  #expect(affected.contains(below.id))
  #expect(affected.contains(nestedGroup.id))
  #expect(affected.contains(nestedChild.id))
  #expect(!affected.contains(above.id))
  #expect(!affected.contains(hidden.id))
  #expect(!affected.contains(adjustment.id))
}

@Test func anAdjustmentInsideAGroupStopsAtTheGroupEdge() {
  let outsideBelow = ProjectLayer.text(makeText("Outside"))
  let adjustment = ProjectLayer.adjustment(.invert)
  let insideBelow = ProjectLayer.text(makeText("Inside"))
  let group = ProjectLayer.group([adjustment, insideBelow], name: "Titles")

  let recipe = stack([group, outsideBelow])
  let affected = recipe.layersAffected(by: adjustment.id)

  #expect(affected == [insideBelow.id])
}

@Test func groupOpacityMultipliesIntoItsChildren() throws {
  var child = ProjectLayer.text(makeText())
  child.opacity = 0.5
  child.fill = 0.5
  var group = ProjectLayer.group([child], name: "Titles")
  group.opacity = 0.5
  group.isEnabled = false

  let recipe = stack([group])
  let entry = try #require(recipe.entry(id: child.id))

  #expect(entry.depth == 1)
  #expect(entry.parentID == group.id)
  #expect(entry.ancestorIDs == [group.id])
  #expect(entry.isEffectivelyEnabled == false)
  #expect(entry.effectiveOpacity == 0.125)
}

@Test func adjustmentKindsCarryTheirOwnDefaults() {
  for kind in AdjustmentKind.allCases {
    #expect(kind.defaultRecipe.kind == kind)
    #expect(!kind.label.isEmpty)
  }
  #expect(AdjustmentKind.exposure.defaultRecipe == .exposure(ev: 0))
  #expect(
    AdjustmentKind.colorControls.defaultRecipe
      == .colorControls(brightness: 0, contrast: 1, saturation: 1))
  #expect(AdjustmentKind.curves.defaultRecipe == .curves(.neutral))
  #expect(AdjustmentKind.levels.defaultRecipe == .levels(.neutral))
  #expect(AdjustmentKind.hueSaturation.defaultRecipe == .hueSaturation(.neutral))
  #expect(AdjustmentKind.blackAndWhite.defaultRecipe == .blackAndWhite(.neutral))
  #expect(AdjustmentKind.colorLookup.defaultRecipe == .colorLookup(.neutral))
  #expect(AdjustmentKind.gradientMap.defaultRecipe == .gradientMap(.neutral))
}

@Test func strongerAdjustmentLayersAndMaskedRecipesRoundTrip() throws {
  var curve = ToneCurveRecipe.neutral
  curve.red = PointToneCurve(points: [
    ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.62),
    ToneCurvePoint(x: 1, y: 1),
  ])
  let recipes: [AdjustmentRecipe] = [
    .curves(curve),
    .levels(LevelsAdjustment(blackPoint: 0.04, whitePoint: 0.93, gamma: 1.2)),
    .hueSaturation(HueSaturationAdjustment(hue: 14, saturation: 22, lightness: -3)),
    .blackAndWhite(BlackAndWhiteAdjustment(amount: 0.8)),
    .colorLookup(ColorLookupAdjustment(style: .warm, amount: 0.6)),
    .gradientMap(GradientMapAdjustment(style: .blueOrange, amount: 0.35, reversed: true)),
  ]

  for adjustment in recipes {
    let mask = MaskRecipe(
      name: "Local color",
      components: [MaskComponent(generator: .rectangle(.full))],
      adjustment: adjustment)
    let layer = ProjectLayer(
      name: adjustment.label,
      content: .text(makeText()),
      masks: [mask])
    let adjustmentLayer = ProjectLayer.adjustment(adjustment)
    let original = stack([adjustmentLayer, layer])
    let restored = try JSONDecoder().decode(
      LayerStackRecipe.self, from: JSONEncoder().encode(original))
    #expect(restored == original)
    #expect(restored.layersAffected(by: adjustmentLayer.id).contains(layer.id))
    #expect(restored.layer(id: layer.id)?.masks.first?.adjustment == adjustment)
  }
}

// MARK: - Editor actions

@Test func layerActionsRunThroughTheProjectRecipe() {
  let text = ProjectLayer.text(makeText())
  var recipe = ProjectRecipe()
  recipe.layerStack.canvas = CanvasRecipe(width: 1920, height: 1080)

  recipe = recipe.applying(.addLayer(text))
  #expect(recipe.layerStack.layer(id: text.id) != nil)
  #expect(recipe.layerStack.activeLayerID == text.id)

  recipe = recipe.applying(.setLayerBlendMode(text.id, .multiply))
  recipe = recipe.applying(.setLayerOpacity(text.id, 0.3))
  recipe = recipe.applying(.setLayerFill(text.id, 0.7))
  #expect(recipe.layerStack.layer(id: text.id)?.blendMode == .multiply)
  #expect(recipe.layerStack.layer(id: text.id)?.opacity == 0.3)
  #expect(recipe.layerStack.layer(id: text.id)?.fill == 0.7)

  var edited = makeText()
  edited.text = "Edited"
  recipe = recipe.applying(.setTextLayer(text.id, edited))
  #expect(recipe.layerStack.layer(id: text.id)?.textLayer?.text == "Edited")

  let groupID = ProjectLayerID()
  recipe = recipe.applying(.groupLayer(text.id, groupID: groupID))
  #expect(recipe.layerStack.parentID(of: text.id) == groupID)

  recipe = recipe.applying(.moveLayerToGroup(text.id, groupID: nil))
  #expect(recipe.layerStack.parentID(of: text.id) == nil)

  recipe = recipe.applying(.removeLayer(text.id))
  #expect(recipe.layerStack.layer(id: text.id) == nil)
}

@Test func theCanvasLayerNeverTakesCompositingChanges() {
  let recipe = stack([ProjectLayer.text(makeText())])
  #expect(recipe.settingOpacity(0.2, for: .canvas) == recipe)
  #expect(recipe.settingFill(0.2, for: .canvas) == recipe)
  #expect(recipe.settingBlendMode(.multiply, for: .canvas) == recipe)
  #expect(recipe.removing(.canvas) == recipe)
}

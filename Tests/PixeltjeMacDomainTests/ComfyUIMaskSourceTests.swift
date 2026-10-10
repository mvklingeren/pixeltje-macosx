import Foundation
import PixeltjeMacDomain
import Testing

@Test func comfyUIMaskSourceProvenanceRoundTrips() throws {
  let layerID = ProjectLayerID(rawValue: "subject-layer")
  let maskID = MaskID(rawValue: "subject-mask")
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(
      documentID: "document", contentRevision: 19, activeLayerID: layerID),
    mask: .single(
      .rectangle(
        ShapeMask(origin: VectorPoint(x: 0.2, y: 0.3), width: 0.4, height: 0.5))),
    strength: 0.7,
    maskFeatherPixels: 9,
    transparentPixelBackground: .gray,
    expandMaskForComfyUI: true,
    usesFullOutputMask: false,
    requestedMaskSource: GenerationMaskSource(kind: .automatic),
    resolvedMaskSource: GenerationMaskSource(
      kind: .layerMask, layerID: layerID, maskID: maskID))

  let data = try JSONEncoder().encode(conditioning)
  let decoded = try JSONDecoder().decode(
    ComfyUIInpaintingConditioningRecipe.self, from: data)

  #expect(decoded == conditioning)
  #expect(decoded.requestedMaskSource.kind == .automatic)
  #expect(decoded.resolvedMaskSource.kind == .layerMask)
  #expect(decoded.resolvedMaskSource.layerID == layerID)
  #expect(decoded.resolvedMaskSource.maskID == maskID)
  #expect(decoded.resolvedMaskSource.isResolved)
  #expect(decoded.expandMaskForComfyUI)
}

@Test func legacyComfyUIConditioningInfersItsMaskSourceProvenance() throws {
  for usesFullOutputMask in [false, true] {
    let conditioning = ComfyUIInpaintingConditioningRecipe(
      source: GenerationSourceIdentity(documentID: "document", contentRevision: 3),
      mask: .selectingAll,
      strength: 0.8,
      maskFeatherPixels: 4,
      transparentPixelBackground: .white,
      usesFullOutputMask: usesFullOutputMask)
    let saved = try JSONEncoder().encode(conditioning)
    var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    object.removeValue(forKey: "requestedMaskSource")
    object.removeValue(forKey: "resolvedMaskSource")
    object.removeValue(forKey: "expandMaskForComfyUI")

    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(
      ComfyUIInpaintingConditioningRecipe.self, from: legacy)

    #expect(decoded.requestedMaskSource.kind == .legacySelectionOrEntireOutput)
    #expect(
      decoded.resolvedMaskSource.kind
        == (usesFullOutputMask ? .entireOutput : .documentSelection))
    #expect(decoded.resolvedMaskSource.isResolved)
    #expect(!decoded.expandMaskForComfyUI)
  }
}

@Test func unresolvedStoredComfyUIMaskSourceIsRejected() throws {
  let conditioning = ComfyUIInpaintingConditioningRecipe(
    source: GenerationSourceIdentity(documentID: "document", contentRevision: 3),
    mask: .selectingAll,
    strength: 0.8,
    maskFeatherPixels: 4,
    transparentPixelBackground: .white,
    usesFullOutputMask: false)
  let saved = try JSONEncoder().encode(conditioning)
  var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
  object["resolvedMaskSource"] = ["kind": "automatic"]
  let invalid = try JSONSerialization.data(withJSONObject: object)

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(ComfyUIInpaintingConditioningRecipe.self, from: invalid)
  }
}

@Test func transparentPixelsIsAConcreteMaskSourceWithoutDocumentIDs() {
  let source = GenerationMaskSource(kind: .transparentPixels)

  #expect(source.isResolved)
  #expect(source.layerID == nil)
  #expect(source.maskID == nil)
}

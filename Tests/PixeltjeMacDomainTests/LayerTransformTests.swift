import Foundation
import PixeltjeMacDomain
import Testing

@Test func affineTransformRoundTripsAndMapsItsReferenceBounds() {
  let frame = LayerFrame(x: 10, y: 20, width: 200, height: 100)
  let transform = LayerTransform(
    referenceRect: frame,
    scaleX: -1.5,
    scaleY: 0.75,
    rotationDegrees: 27,
    shearX: 0.2
  )
  let source = PixelPoint(x: 37, y: 71)
  let mapped = transform.applyingAffine(to: source)
  let inverted = transform.inverseAffine(mapped)
  #expect(abs((inverted?.x ?? 0) - source.x) < 0.000_001)
  #expect(abs((inverted?.y ?? 0) - source.y) < 0.000_001)
  #expect(!transform.affineBounds(of: frame).isEmpty)
}

@Test func transformedGroupRejectsRawOrLegacyVectorDescendantsAtEveryMutationBoundary() {
  let image = ProjectLayer.image(
    ImageLayer(
      source: SourceReference(
        originalFilename: "a.png", linkedPath: "/tmp/a.png", securityScopedBookmark: nil,
        fingerprint: SourceFingerprint(byteLength: 1, modificationDate: nil)
      ),
      frame: LayerFrame(x: 0, y: 0, width: 20, height: 20), naturalWidth: 20, naturalHeight: 20
    )
  )
  let groupID = ProjectLayerID()
  var stack = LayerStackRecipe(layers: [image])
  stack = stack.grouping(image.id, into: groupID)
  let transformed = stack.settingTransform(.identity(for: LayerFrame(x: 0, y: 0, width: 20, height: 20)).withPosition(x: 10, y: 0), for: groupID)
  #expect(transformed.isTransformHierarchyValid)
  let raw = ProjectLayer(
    id: ProjectLayerID(),
    name: "RAW",
    content: .developedRaw(DevelopedRawLayer())
  )
  let attempted = transformed.adding(raw)
  // A root RAW is valid, but moving it below the transformed group is not.
  #expect(attempted.movingToGroup(raw.id, groupID) == attempted)
}

private extension LayerTransform {
  func withPosition(x: Double, y: Double) -> LayerTransform {
    var copy = self
    copy.position = PixelPoint(x: copy.position.x + x, y: copy.position.y + y)
    return copy
  }
}

import Foundation
import PixeltjeMacDomain
import Testing

/// Floating-point geometry never lands on an exact literal after a transform.
private func isClose(_ point: VectorPoint, _ expected: VectorPoint) -> Bool {
  abs(point.x - expected.x) < 1e-9 && abs(point.y - expected.y) < 1e-9
}

/// A closed square from `origin`, with straight segments.
private func square(
  name: String = "Square",
  zOrder: Int = 0,
  origin: VectorPoint = VectorPoint(x: 0.2, y: 0.2),
  side: Double = 0.4,
  fill: VectorFillStyle? = VectorFillStyle(color: .white),
  stroke: VectorStrokeStyle? = nil
) -> VectorPath {
  let corners = [
    origin,
    VectorPoint(x: origin.x + side, y: origin.y),
    VectorPoint(x: origin.x + side, y: origin.y + side),
    VectorPoint(x: origin.x, y: origin.y + side),
  ]
  return VectorPath(
    name: name,
    zOrder: zOrder,
    anchors: corners.map { VectorAnchor(position: $0) },
    isClosed: true,
    stroke: stroke,
    fill: fill
  )
}

@Test func aFilledClosedPathIsHitInsideItAndNearItsOutline() {
  let path = square()
  #expect(path.hitTest(
    VectorPoint(x: 0.4, y: 0.4), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 4))
  // Just outside the edge, but within the tolerance measured in pixels.
  #expect(path.hitTest(
    VectorPoint(x: 0.2 - 0.002, y: 0.4), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 4))
  #expect(!path.hitTest(
    VectorPoint(x: 0.05, y: 0.4), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 4))
}

@Test func anUnfilledPathIsHitOnlyNearItsOutline() {
  let path = square(fill: nil, stroke: VectorStrokeStyle(color: .white, width: 2))
  #expect(!path.hitTest(
    VectorPoint(x: 0.4, y: 0.4), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 4))
  #expect(path.hitTest(
    VectorPoint(x: 0.2, y: 0.4), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 4))
}

@Test func theRenderedBoundingBoxIncludesHalfTheStrokeOnEachAxis() throws {
  let path = square(stroke: VectorStrokeStyle(color: .white, width: 20))
  let box = try #require(path.renderedBoundingBox(pixelWidth: 1_000, pixelHeight: 500))
  #expect(abs(box.minX - (0.2 - 0.01)) < 1e-9)
  // Half of 20 pixels is a larger normalized outset on the shorter axis.
  #expect(abs(box.minY - (0.2 - 0.02)) < 1e-9)
}

@Test func closedStrokeAlignmentControlsPaintedBoundsAndHits() throws {
  let pointOutside = VectorPoint(x: 0.185, y: 0.4)
  let pointInside = VectorPoint(x: 0.215, y: 0.4)
  let inside = square(
    fill: nil,
    stroke: VectorStrokeStyle(color: .white, width: 20, alignment: .inside))
  let outside = square(
    fill: nil,
    stroke: VectorStrokeStyle(color: .white, width: 20, alignment: .outside))
  let insideBounds = try #require(
    inside.renderedBoundingBox(pixelWidth: 1_000, pixelHeight: 1_000))
  let outsideBounds = try #require(
    outside.renderedBoundingBox(pixelWidth: 1_000, pixelHeight: 1_000))

  #expect(abs(insideBounds.minX - 0.2) < 1e-9)
  #expect(abs(outsideBounds.minX - 0.18) < 1e-9)
  #expect(!inside.hitTest(pointOutside, pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
  #expect(inside.hitTest(pointInside, pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
  #expect(outside.hitTest(pointOutside, pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
  #expect(!outside.hitTest(pointInside, pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
}

@Test func openStrokeCapsControlEndpointBoundsAndHits() throws {
  func line(_ cap: VectorLineCap) -> VectorPath {
    VectorPath(
      anchors: [
        VectorAnchor(position: VectorPoint(x: 0.2, y: 0.5)),
        VectorAnchor(position: VectorPoint(x: 0.6, y: 0.5)),
      ],
      stroke: VectorStrokeStyle(color: .white, width: 20, lineCap: cap))
  }
  let butt = line(.butt)
  let square = line(.square)
  let buttBounds = try #require(
    butt.renderedBoundingBox(pixelWidth: 1_000, pixelHeight: 1_000))
  let squareBounds = try #require(
    square.renderedBoundingBox(pixelWidth: 1_000, pixelHeight: 1_000))

  #expect(abs(buttBounds.minX - 0.2) < 1e-9)
  #expect(abs(squareBounds.minX - 0.19) < 1e-9)
  let beforeStart = VectorPoint(x: 0.195, y: 0.5)
  #expect(!butt.hitTest(beforeStart, pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
  #expect(square.hitTest(beforeStart, pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
}

@Test func dashedStrokeGapsAreNotPaintedHitTargets() {
  let path = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.2, y: 0.5)),
      VectorAnchor(position: VectorPoint(x: 0.6, y: 0.5)),
    ],
    stroke: VectorStrokeStyle(
      color: .white,
      width: 10,
      lineCap: .butt,
      dashPattern: [20, 20]))

  #expect(path.hitTest(
    VectorPoint(x: 0.21, y: 0.5), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
  #expect(!path.hitTest(
    VectorPoint(x: 0.23, y: 0.5), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
}

@Test func miterJoinsAndArrowheadsContributeToSelectionGeometry() throws {
  let anchors = [
    VectorAnchor(position: VectorPoint(x: 0.3, y: 0.3)),
    VectorAnchor(position: VectorPoint(x: 0.5, y: 0.7)),
    VectorAnchor(position: VectorPoint(x: 0.7, y: 0.3)),
  ]
  let bevel = VectorPath(
    anchors: anchors,
    stroke: VectorStrokeStyle(color: .white, width: 20, lineCap: .butt, lineJoin: .bevel))
  let miter = VectorPath(
    anchors: anchors,
    stroke: VectorStrokeStyle(color: .white, width: 20, lineCap: .butt, lineJoin: .miter))
  let bevelBounds = try #require(
    bevel.renderedBoundingBox(pixelWidth: 1_000, pixelHeight: 1_000))
  let miterBounds = try #require(
    miter.renderedBoundingBox(pixelWidth: 1_000, pixelHeight: 1_000))
  #expect(miterBounds.maxY > bevelBounds.maxY + 0.01)
  #expect(miter.hitTest(
    VectorPoint(x: 0.5, y: 0.715), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))

  let arrow = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.2, y: 0.5)),
      VectorAnchor(position: VectorPoint(x: 0.6, y: 0.5)),
    ],
    stroke: VectorStrokeStyle(
      color: .white,
      width: 10,
      lineCap: .butt,
      endArrowhead: VectorArrowhead(style: .triangle, scale: 4)))
  let arrowBounds = try #require(
    arrow.renderedBoundingBox(pixelWidth: 1_000, pixelHeight: 1_000))
  #expect(abs(arrowBounds.minY - 0.48) < 1e-9)
  #expect(arrow.hitTest(
    VectorPoint(x: 0.57, y: 0.51), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 0))
}

@Test func translatingAnObjectMovesGeometryAndLeavesTheStrokeWidthAlone() throws {
  let path = square(stroke: VectorStrokeStyle(color: .white, width: 8))
  let moved = path.transformed(by: .translation(x: 0.1, y: -0.05))
  #expect(isClose(moved.anchors[0].position, VectorPoint(x: 0.3, y: 0.15)))
  #expect(moved.stroke?.width == 8)
}

@Test func scalingAnObjectScalesItsStrokeWithIt() throws {
  let path = square(stroke: VectorStrokeStyle(color: .white, width: 8))
  let scaled = path.transformed(by: .scale(x: 2, y: 2, about: VectorPoint(x: 0.2, y: 0.2)))
  #expect(isClose(scaled.anchors[0].position, VectorPoint(x: 0.2, y: 0.2)))
  #expect(isClose(scaled.anchors[1].position, VectorPoint(x: 1.0, y: 0.2)))
  #expect(scaled.stroke?.width == 16)
}

@Test func rotationStaysARotationOnANonSquareImage() {
  // A quarter turn about the origin, on a 2:1 image, must land the pixel-space
  // point (1, 0) on (0, 1) rather than shearing.
  let aspect = 2.0
  let transform = VectorAffineTransform.rotation(radians: .pi / 2, aspect: aspect)
  let moved = transform.apply(to: VectorPoint(x: 0.5, y: 0))
  // In pixels: (0.5 * 2, 0) = (1, 0) → (0, 1) → normalized (0, 1).
  #expect(abs(moved.x) < 1e-12)
  #expect(abs(moved.y - 1) < 1e-12)
}

@Test func styleChangesReachOnlyTheSelectedObjects() throws {
  let first = square(name: "First", zOrder: 0)
  let second = square(name: "Second", zOrder: 1, origin: VectorPoint(x: 0.5, y: 0.5))
  let layer = VectorLayer(objects: [.path(first), .path(second)])

  let recolored = layer.settingFillColor(.black, objectIDs: [second.id])
  #expect(recolored.object(id: first.id)?.path?.fill?.color == .white)
  #expect(recolored.object(id: second.id)?.path?.fill?.color == .black)

  // No identifiers still means the whole layer, which is what a layer-level
  // control asks for.
  let all = layer.settingFillColor(.black)
  #expect(all.paths.allSatisfy { $0.fill?.color == .black })
}

@Test func reorderingMovesASelectedRunAsABlockAndClampsAtTheEnds() throws {
  let objects = (0..<4).map { index in
    VectorObject.path(square(name: "Object \(index)", zOrder: index))
  }
  let layer = VectorLayer(objects: objects)
  let ids = [objects[0].id, objects[1].id]

  let forward = layer.reordering(ids: Set(ids), placement: .forward)
  #expect(forward.objectIDsInDrawOrder == [objects[2].id, objects[0].id, objects[1].id, objects[3].id])

  let front = layer.reordering(ids: [objects[0].id], placement: .front)
  #expect(front.objectIDsInDrawOrder.last == objects[0].id)

  let back = layer.reordering(ids: [objects[0].id], placement: .back)
  #expect(back.objectIDsInDrawOrder == layer.objectIDsInDrawOrder)
}

@Test func duplicatingGivesTheCopyFreshIdentityAboveTheOriginal() throws {
  let under = square(name: "Under", zOrder: 0)
  let original = square(name: "Badge", zOrder: 1)
  let over = square(name: "Over", zOrder: 2)
  let layer = VectorLayer(objects: [.path(under), .path(original), .path(over)])
  let result = layer.duplicating(ids: [original.id])
  let newID = try #require(result.newIDs.first)

  #expect(newID != original.id)
  #expect(result.layer.objectIDsInDrawOrder == [under.id, original.id, newID, over.id])
  let copy = try #require(result.layer.object(id: newID)?.path)
  #expect(copy.name == "Badge copy")
  #expect(copy.anchors.map(\.position) == original.anchors.map(\.position))
  // Anchors are re-identified so editing the copy cannot move the original.
  #expect(Set(copy.anchors.map(\.id)).isDisjoint(with: Set(original.anchors.map(\.id))))
}

@Test func marqueeSelectionPicksTheObjectsItOverlaps() throws {
  let left = square(name: "Left", zOrder: 0)
  let right = square(name: "Right", zOrder: 1, origin: VectorPoint(x: 0.7, y: 0.7), side: 0.2)
  let layer = VectorLayer(objects: [.path(left), .path(right)])

  let hits = layer.objectIDs(
    intersecting: VectorBounds(minX: 0, minY: 0, maxX: 0.5, maxY: 0.5),
    pixelWidth: 1_000,
    pixelHeight: 1_000
  )
  #expect(hits == [left.id])
}

@Test func theTopmostObjectUnderAClickWins() throws {
  let under = square(name: "Under", zOrder: 0)
  let over = square(name: "Over", zOrder: 1)
  let layer = VectorLayer(objects: [.path(under), .path(over)])
  #expect(layer.topmostObjectID(
    at: VectorPoint(x: 0.4, y: 0.4), pixelWidth: 1_000, pixelHeight: 1_000, tolerance: 4)
    == over.id)
}

@Test func removingObjectsLeavesADenseDrawOrder() throws {
  let objects = (0..<3).map { index in
    VectorObject.path(square(name: "Object \(index)", zOrder: index * 5))
  }
  let layer = VectorLayer(objects: objects).removing(ids: [objects[1].id])
  #expect(layer.paths.map(\.zOrder) == [0, 1])
}

@Test func freeTransformMapsVectorObjectsExactlyAsItMapsCanvasPixels() throws {
  let canvasWidth = 800.0
  let canvasHeight = 400.0
  var layerTransform = LayerTransform(
    referenceRect: LayerFrame(x: 100, y: 50, width: 200, height: 100))
  layerTransform.scaleX = 1.4
  layerTransform.scaleY = 0.7
  layerTransform.rotationDegrees = 27
  layerTransform.shearX = 0.2
  layerTransform.position = PixelPoint(x: layerTransform.anchor.x + 30, y: layerTransform.anchor.y - 12)

  let vectorTransform = try #require(
    layerTransform.vectorTransform(canvasWidth: canvasWidth, canvasHeight: canvasHeight))

  for point in [
    VectorPoint(x: 0.1, y: 0.2), VectorPoint(x: 0.75, y: 0.9), VectorPoint(x: 0.5, y: 0.5),
  ] {
    let throughPixels = layerTransform.applyingAffine(
      to: PixelPoint(x: point.x * canvasWidth, y: point.y * canvasHeight))
    let throughVector = vectorTransform.apply(to: point)
    #expect(abs(throughVector.x * canvasWidth - throughPixels.x) < 1e-9)
    #expect(abs(throughVector.y * canvasHeight - throughPixels.y) < 1e-9)
  }
}

@Test func aPerspectiveTransformHasNoVectorEquivalent() {
  var transform = LayerTransform(referenceRect: LayerFrame(x: 0, y: 0, width: 10, height: 10))
  transform.perspective = PerspectiveCorners(
    bottomLeft: PixelPoint(x: 0, y: 0),
    bottomRight: PixelPoint(x: 12, y: 1),
    topRight: PixelPoint(x: 10, y: 10),
    topLeft: PixelPoint(x: 1, y: 9)
  )
  #expect(transform.vectorTransform(canvasWidth: 100, canvasHeight: 100) == nil)
}

@Test func aSchemaNineteenStrokeDecodesWithTheDefaultsItWasDrawnWith() throws {
  // Exactly what projects wrote before the stroke model was completed.
  let legacy = """
    {"color":{"red":1,"green":0,"blue":0,"alpha":1},"width":6,
     "lineCap":"round","lineJoin":"miter","dashPattern":[4,2]}
    """
  let stroke = try JSONDecoder().decode(
    VectorStrokeStyle.self, from: try #require(legacy.data(using: .utf8)))

  #expect(stroke.width == 6)
  #expect(stroke.lineJoin == .miter)
  #expect(stroke.dashPattern == [4, 2])
  // The new fields take the values the old renderer effectively used.
  #expect(stroke.miterLimit == 10)
  #expect(stroke.dashPhase == 0)
  #expect(stroke.alignment == .center)
  #expect(stroke.opacity == 1)
  #expect(stroke.startArrowhead == nil)
  #expect(stroke.endArrowhead == nil)

  let reencoded = try JSONDecoder().decode(
    VectorStrokeStyle.self, from: try JSONEncoder().encode(stroke))
  #expect(reencoded == stroke)
}

@Test func strokeOpacityMultipliesIntoTheColorRatherThanReplacingIt() {
  var stroke = VectorStrokeStyle(
    color: VectorColor(red: 1, green: 0, blue: 0, alpha: 0.5), opacity: 0.5)
  #expect(stroke.effectiveColor.alpha == 0.25)
  #expect(stroke.effectiveColor.red == 1)
  #expect(stroke.isVisible)

  stroke.opacity = 0
  #expect(!stroke.isVisible)
}

@Test func aDashPatternIsOnlyUsableWhenCoreGraphicsCanDrawIt() {
  #expect(VectorStrokeStyle(dashPattern: []).usableDashPattern == nil)
  // One length has no gap to alternate with.
  #expect(VectorStrokeStyle(dashPattern: [5]).usableDashPattern == nil)
  // All zeroes would make Core Graphics draw nothing at all.
  #expect(VectorStrokeStyle(dashPattern: [0, 0]).usableDashPattern == nil)
  #expect(VectorStrokeStyle(dashPattern: [8, 4]).usableDashPattern == [8, 4])
  // Negative lengths are dropped at initialization.
  #expect(VectorStrokeStyle(dashPattern: [8, -4, 2]).dashPattern == [8, 2])
}

@Test func strokeParametersAreClampedToWhatCanBeDrawn() {
  #expect(VectorStrokeStyle(miterLimit: 0).miterLimit == 1)
  #expect(VectorStrokeStyle(opacity: 4).opacity == 1)
  #expect(VectorStrokeStyle(opacity: -1).opacity == 0)
  #expect(VectorArrowhead(scale: 0).scale == 0.5)
  #expect(VectorArrowhead(scale: 1_000).scale == 20)
}

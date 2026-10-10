import Foundation
import PixeltjeMacDomain
import Testing

private let unitFrame = VectorBounds(minX: 0.2, minY: 0.2, maxX: 0.8, maxY: 0.6)

@Test func aRectangleResolvesToFourCornersAndAnEllipseToFourSmoothAnchors() {
  let rectangle = VectorShape(kind: .rectangle(corners: .none), frame: unitFrame)
  let path = rectangle.resolvedPath()
  #expect(path.anchors.count == 4)
  #expect(path.isClosed)
  #expect(path.anchors.allSatisfy { $0.incomingHandle == nil && $0.outgoingHandle == nil })

  let ellipse = VectorShape(kind: .ellipse, frame: unitFrame).resolvedPath()
  #expect(ellipse.anchors.count == 4)
  #expect(ellipse.anchors.allSatisfy { $0.kind == .smooth })
  #expect(ellipse.anchors.allSatisfy { $0.incomingHandle != nil && $0.outgoingHandle != nil })
}

@Test func aRoundedRectangleTurnsEachCornerIntoTwoAnchorsWithHandles() throws {
  let shape = VectorShape(
    kind: .rectangle(corners: VectorCornerRadii(uniform: 0.25)), frame: unitFrame)
  let path = shape.resolvedPath()
  #expect(path.anchors.count == 8)
  #expect(path.anchors.contains { $0.outgoingHandle != nil })
  #expect(path.anchors.contains { $0.incomingHandle != nil })

  // A corner that is not rounded stays a single anchor.
  let mixed = VectorShape(
    kind: .rectangle(corners: VectorCornerRadii(bottomLeft: 0.2)), frame: unitFrame)
  #expect(mixed.resolvedPath().anchors.count == 5)
}

@Test func aCornerRadiusIsCircularOnANonSquareImage() throws {
  // A radius is a fraction of the shorter side measured on screen, so its two
  // normalized offsets have to differ by exactly the image aspect.
  let frame = VectorBounds(minX: 0, minY: 0, maxX: 0.5, maxY: 0.5)
  let shape = VectorShape(
    kind: .rectangle(corners: VectorCornerRadii(uniform: 0.2)), frame: frame)
  let path = shape.resolvedPath(aspect: 2)
  let bottomLeft = try #require(path.anchors.first)
  // The first anchor leaves the bottom-left corner along the left edge.
  let offsetY = bottomLeft.position.y
  let second = path.anchors[1]
  let offsetX = second.position.x
  #expect(offsetY > 0)
  #expect(abs(offsetX * 2 - offsetY) < 1e-9)
}

@Test func aPolygonAndAStarUseTheirVertexCounts() {
  let polygon = VectorShape(kind: .polygon(sides: 7), frame: unitFrame).resolvedPath()
  #expect(polygon.anchors.count == 7)
  #expect(polygon.isClosed)

  let star = VectorShape(kind: .star(points: 5, innerRatio: 0.4), frame: unitFrame)
    .resolvedPath()
  #expect(star.anchors.count == 10)

  // Alternating vertices sit on the inner radius.
  let center = unitFrame.center
  let outer = star.anchors[0].position.distance(to: center)
  let inner = star.anchors[1].position.distance(to: center)
  #expect(inner < outer)
}

@Test func shapeParametersAreClampedToWhatCanBeDrawn() {
  #expect(VectorShapeKind.polygon(sides: 1).validated == .polygon(sides: 3))
  #expect(VectorShapeKind.polygon(sides: 500).validated == .polygon(sides: 64))
  if case .star(let points, let ratio) = VectorShapeKind.star(points: 2, innerRatio: 9).validated {
    #expect(points == 3)
    #expect(ratio == 0.95)
  } else {
    Issue.record("A star must stay a star after validation.")
  }
}

@Test func decodedAndMutatedShapesCannotBypassGeometryLimits() throws {
  let original = VectorShape(
    kind: .star(points: 5, innerRatio: 0.4),
    frame: VectorBounds(minX: 0.2, minY: 0.1, maxX: 0.8, maxY: 0.9))
  var json = try #require(
    JSONSerialization.jsonObject(with: try JSONEncoder().encode(original))
      as? [String: Any])
  var kind = try #require(json["kind"] as? [String: Any])
  var star = try #require(kind["star"] as? [String: Any])
  star["points"] = Int.max
  star["innerRatio"] = 9
  kind["star"] = star
  json["kind"] = kind
  json["frame"] = ["minX": 0.8, "minY": 0.9, "maxX": 0.2, "maxY": 0.1]

  let decoded = try JSONDecoder().decode(
    VectorShape.self, from: JSONSerialization.data(withJSONObject: json))
  #expect(decoded.kind == .star(points: 64, innerRatio: 0.95))
  #expect(decoded.frame == VectorBounds(minX: 0.2, minY: 0.1, maxX: 0.8, maxY: 0.9))
  #expect(decoded.resolvedPath().anchors.count == 128)

  // The kind is intentionally editable without a setter API. Resolution is
  // still an allocation boundary and must defend itself from direct mutation.
  var mutated = decoded
  mutated.kind = .star(points: Int.max, innerRatio: -10)
  #expect(mutated.resolvedPath().anchors.count == 128)
}

@Test func aLineIsNeverClosedAndNeverFilled() {
  let line = VectorShape(
    kind: .line, frame: unitFrame, fill: VectorFillStyle(color: .white))
  #expect(line.fill == nil)
  let path = line.resolvedPath()
  #expect(!path.isClosed)
  #expect(path.anchors.count == 2)
}

@Test func rotationTurnsTheShapeWithoutShearingItOnANonSquareImage() throws {
  // A square shape on a 2:1 image, turned a quarter: its resolved geometry must
  // still measure the same on screen, only swapped between the axes.
  let frame = VectorBounds(minX: 0.25, minY: 0, maxX: 0.75, maxY: 1)
  let upright = VectorShape(kind: .rectangle(corners: .none), frame: frame)
  let turned = VectorShape(
    kind: .rectangle(corners: .none), frame: frame, rotationDegrees: 90)

  let uprightBox = try #require(upright.resolvedPath(aspect: 2).boundingBox)
  let turnedBox = try #require(turned.resolvedPath(aspect: 2).boundingBox)
  // In pixels, on a 2:1 image: upright is 0.5 * 2 = 1 wide and 1 tall.
  #expect(abs(uprightBox.width * 2 - 1) < 1e-9)
  #expect(abs(uprightBox.height - 1) < 1e-9)
  // Turned, the same square measures the same both ways.
  #expect(abs(turnedBox.width * 2 - 1) < 1e-9)
  #expect(abs(turnedBox.height - 1) < 1e-9)
}

@Test func aShapeStaysParametricThroughAMoveScaleAndRotation() throws {
  let shape = VectorShape(kind: .polygon(sides: 6), frame: unitFrame)

  let moved = try #require(shape.transformed(by: .translation(x: 0.1, y: 0)))
  #expect(moved.kind == .polygon(sides: 6))
  #expect(abs(moved.frame.minX - 0.3) < 1e-9)

  let scaled = try #require(
    shape.transformed(by: .scale(x: 2, y: 2, about: shape.center)))
  #expect(abs(scaled.frame.width - unitFrame.width * 2) < 1e-9)

  let turned = try #require(
    shape.transformed(by: .rotation(radians: .pi / 4, about: shape.center)))
  #expect(abs(turned.rotationDegrees - 45) < 1e-6)
}

@Test func aShearedShapeBecomesAPathBecauseNoParameterDescribesIt() {
  let shape = VectorShape(kind: .rectangle(corners: .none), frame: unitFrame)
  let shear = VectorAffineTransform(a: 1, b: 0, c: 0.4, d: 1, tx: 0, ty: 0)
  #expect(shape.transformed(by: shear) == nil)

  let object = VectorObject.shape(shape).transformed(by: shear)
  #expect(object.shape == nil)
  #expect(object.path != nil)
  #expect(object.path?.anchors.count == 4)
}

@Test func nonuniformCanvasScaleConvertsAnAlreadyRotatedShapeToAPath() throws {
  let shape = VectorShape(
    kind: .rectangle(corners: .none), frame: unitFrame, rotationDegrees: 35)
  let transform = VectorAffineTransform.scale(x: 1.8, y: 0.7, about: shape.center)
  let transformed = VectorObject.shape(shape).transformed(by: transform)
  let path = try #require(transformed.path)
  let expected = shape.resolvedPath().transformed(by: transform)

  #expect(transformed.shape == nil)
  #expect(path.anchors.map(\.position) == expected.anchors.map(\.position))
}

@Test func reflectingARotatedSymmetricShapeKeepsItsExactParametricGeometry() throws {
  let shape = VectorShape(
    kind: .rectangle(corners: .none), frame: unitFrame, rotationDegrees: 31)
  let transform = VectorAffineTransform.reflection(
    horizontally: true, about: shape.center)
  let transformed = try #require(shape.transformed(by: transform))
  let expected = shape.resolvedPath().transformed(by: transform)
  let actual = transformed.resolvedPath()

  #expect(actual.anchors.count == expected.anchors.count)
  for expectedAnchor in expected.anchors {
    #expect(actual.anchors.contains { anchor in
      abs(anchor.position.x - expectedAnchor.position.x) < 1e-9
        && abs(anchor.position.y - expectedAnchor.position.y) < 1e-9
    })
  }
}

@Test func anisotropicScalingConvertsRoundedCornersInsteadOfChangingTheirShape() {
  let shape = VectorShape(
    kind: .rectangle(corners: VectorCornerRadii(uniform: 0.2)), frame: unitFrame)
  let transformed = VectorObject.shape(shape).transformed(
    by: .scale(x: 2, y: 1, about: shape.center))
  #expect(transformed.path != nil)
  #expect(transformed.shape == nil)
}

@Test func convertToPathKeepsIdentityOrderNameAndAppearance() throws {
  let shape = VectorShape(
    id: UUID(),
    name: "Badge",
    zOrder: 3,
    kind: .star(points: 6, innerRatio: 0.4),
    frame: unitFrame,
    rotationDegrees: 15,
    stroke: VectorStrokeStyle(color: .black, width: 6),
    fill: VectorFillStyle(color: .white)
  )
  let layer = VectorLayer(objects: [.shape(shape)])
  #expect(layer.containsShapes(ids: [shape.id]))

  let converted = layer.convertingShapesToPaths(ids: [shape.id])
  let path = try #require(converted.object(id: shape.id)?.path)
  #expect(path.id == shape.id)
  #expect(path.name == "Badge")
  #expect(path.zOrder == 3)
  #expect(path.stroke == shape.stroke)
  #expect(path.fill == shape.fill)
  #expect(path.anchors.count == 12)
  #expect(!converted.containsShapes(ids: [shape.id]))
  // The anchors are exactly what the shape was drawing.
  #expect(path.anchors.map(\.position) == shape.resolvedPath().anchors.map(\.position))
}

@Test func aShapeRoundTripsThroughAProjectBesideAPath() throws {
  let shape = VectorShape(
    kind: .rectangle(corners: VectorCornerRadii(bottomLeft: 0.1, topRight: 0.3)),
    frame: unitFrame,
    rotationDegrees: 22.5,
    fill: VectorFillStyle(gradient: VectorGradient())
  )
  let path = VectorPath(
    name: "Drawn",
    zOrder: 1,
    anchors: [VectorAnchor(position: .zero), VectorAnchor(position: VectorPoint(x: 1, y: 1))]
  )
  var project = ProjectRecipe()
  project.layerStack.canvas = CanvasRecipe(width: 64, height: 32)
  project = project.applying(
    .addLayer(
      ProjectLayer(
        name: "Vector Layer",
        isEnabled: true,
        isLocked: false,
        zOrder: 1,
        content: .vector(VectorLayer(objects: [.shape(shape), .path(path)])))))

  let reopened = try JSONDecoder().decode(
    ProjectRecipe.self, from: try JSONEncoder().encode(project))
  let stored = try #require(
    reopened.layerStack.allLayers.compactMap(\.content.vectorValue).first)
  #expect(stored.object(id: shape.id)?.shape == shape)
  #expect(stored.object(id: path.id)?.path == path)
  // Both kinds resolve to geometry, so a renderer sees two objects either way.
  #expect(stored.resolvedPaths(aspect: 2).count == 2)
}

@Test func stylingAndOrderingReachShapesTheSameWayTheyReachPaths() throws {
  let shape = VectorShape(zOrder: 0, kind: .ellipse, frame: unitFrame)
  let path = VectorPath(name: "Drawn", zOrder: 1, isClosed: true)
  let layer = VectorLayer(objects: [.shape(shape), .path(path)])

  let filled = layer.settingFillColor(.black)
  #expect(filled.object(id: shape.id)?.fill?.color == .black)
  #expect(filled.object(id: path.id)?.fill?.color == .black)

  let reordered = layer.reordering(ids: [shape.id], placement: .front)
  #expect(reordered.objectIDsInDrawOrder.last == shape.id)

  let duplicated = layer.duplicating(ids: [shape.id])
  let newID = try #require(duplicated.newIDs.first)
  #expect(newID != shape.id)
  #expect(duplicated.layer.object(id: newID)?.shape?.kind == .ellipse)
  #expect(duplicated.layer.object(id: newID)?.name == "Ellipse copy")
}

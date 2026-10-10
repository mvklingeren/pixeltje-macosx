import Foundation
import PixeltjeMacDomain
import Testing

@Test func aSchemaSeventeenSolidFillDecodesUnchanged() throws {
  // Exactly what older projects wrote: a fill was one color and nothing else.
  let legacy = """
    {"color":{"red":0.25,"green":0.5,"blue":0.75,"alpha":0.8}}
    """
  let fill = try JSONDecoder().decode(
    VectorFillStyle.self, from: try #require(legacy.data(using: .utf8)))

  #expect(fill.content == .solid(VectorColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.8)))
  #expect(fill.opacity == 1)
  #expect(!fill.isGradient)
  // Re-encoding writes the current shape, which round-trips to the same value.
  let reencoded = try JSONDecoder().decode(
    VectorFillStyle.self, from: try JSONEncoder().encode(fill))
  #expect(reencoded == fill)
}

@Test func aGradientFillRoundTripsThroughAProject() throws {
  let gradient = VectorGradient(
    kind: .radial,
    stops: [
      VectorGradientStop(color: .black, position: 0, midpoint: 0.3),
      VectorGradientStop(color: VectorColor(red: 1, green: 0.5, blue: 0), position: 0.4),
      VectorGradientStop(
        color: VectorColor(red: 1, green: 1, blue: 1, alpha: 0), position: 1),
    ],
    start: VectorPoint(x: 0.3, y: 0.4),
    end: VectorPoint(x: 0.8, y: 0.55),
    focal: VectorPoint(x: 0.32, y: 0.42),
    aspectRatio: 0.6,
    opacity: 0.75
  )
  let path = VectorPath(
    name: "Filled",
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0, y: 0)),
      VectorAnchor(position: VectorPoint(x: 1, y: 0)),
      VectorAnchor(position: VectorPoint(x: 1, y: 1)),
    ],
    isClosed: true,
    fill: VectorFillStyle(gradient: gradient)
  )
  var project = ProjectRecipe()
  project.layerStack.canvas = CanvasRecipe(width: 40, height: 20)
  project = project.applying(
    .addLayer(
      ProjectLayer(
        name: "Vector Layer",
        isEnabled: true,
        isLocked: false,
        zOrder: 1,
        content: .vector(VectorLayer(objects: [.path(path)])))))

  let reopened = try JSONDecoder().decode(
    ProjectRecipe.self, from: try JSONEncoder().encode(project))
  let stored = try #require(
    reopened.layerStack.allLayers.compactMap(\.content.vectorValue).first?.paths.first)
  #expect(stored.fill?.gradient == gradient)
  #expect(stored.fill?.opacity == 0.75)
}

@Test func decodedVectorStylesUseTheirConstructionLimits() throws {
  let original = VectorGradient(stops: [
    VectorGradientStop(color: .black, position: 0),
    VectorGradientStop(color: .white, position: 1),
  ])
  var json = try #require(
    JSONSerialization.jsonObject(with: try JSONEncoder().encode(original))
      as? [String: Any])
  var stops = try #require(json["stops"] as? [[String: Any]])
  stops = [stops[0]]
  stops[0]["position"] = -4
  stops[0]["midpoint"] = 4
  json["stops"] = stops
  json["aspectRatio"] = 500
  json["opacity"] = -2

  let decoded = try JSONDecoder().decode(
    VectorGradient.self, from: JSONSerialization.data(withJSONObject: json))
  #expect(decoded.stops.count == 2)
  #expect(decoded.stops.map(\.position) == [0, 1])
  #expect(decoded.stops[0].midpoint == 0.95)
  #expect(decoded.aspectRatio == 100)
  #expect(decoded.opacity == 0)

  let arrow = try JSONDecoder().decode(
    VectorArrowhead.self,
    from: try #require(
      #"{"style":"triangle","scale":1000}"#.data(using: .utf8)))
  #expect(arrow.scale == 20)

  let fill = try JSONDecoder().decode(
    VectorFillStyle.self,
    from: try #require(
      """
      {"content":{"kind":"solid","color":{"red":1,"green":1,"blue":1,"alpha":1}},"opacity":10}
      """.data(using: .utf8)))
  #expect(fill.opacity == 1)
}

@Test func aMidpointMovesWhereTheBlendIsHalfDone() {
  var centered = VectorGradient(stops: [
    VectorGradientStop(color: .black, position: 0),
    VectorGradientStop(color: .white, position: 1),
  ])
  #expect(abs(centered.linearColor(at: 0.5).red - 0.5) < 1e-9)
  #expect(abs(centered.color(at: 0.5).red - 0.735_356_983) < 1e-6)

  // A midpoint at a quarter makes the blend half done a quarter of the way in.
  centered = centered.updatingStop(id: centered.stops[0].id) { $0.midpoint = 0.25 }
  #expect(abs(centered.linearColor(at: 0.25).red - 0.5) < 1e-9)
  #expect(centered.linearColor(at: 0.5).red > 0.5)
}

@Test func gradientEndpointsAndAlphaAreHonoredExactly() {
  let gradient = VectorGradient(stops: [
    VectorGradientStop(color: VectorColor(red: 1, green: 0, blue: 0, alpha: 1), position: 0.2),
    VectorGradientStop(color: VectorColor(red: 0, green: 0, blue: 1, alpha: 0), position: 0.8),
  ])
  // Before the first and after the last stop the gradient pads.
  #expect(gradient.color(at: 0) == gradient.stops[0].color)
  #expect(gradient.color(at: 1) == gradient.stops[1].color)
  let middle = gradient.color(at: 0.5)
  #expect(abs(middle.alpha - 0.5) < 1e-9)
}

@Test func stopEditingKeepsAGradientWithSomethingToBlend() throws {
  var gradient = VectorGradient()
  #expect(gradient.stops.count == 2)

  gradient = gradient.addingStop(at: 0.5)
  #expect(gradient.stops.count == 3)
  #expect(gradient.stops.map(\.position) == [0, 0.5, 1])

  let middleID = gradient.stops[1].id
  gradient = gradient.duplicatingStop(id: middleID)
  #expect(gradient.stops.count == 4)

  gradient = gradient.removingStop(id: middleID)
  #expect(gradient.stops.count == 3)

  // The last two stops cannot be removed: there would be no blend left.
  var minimal = VectorGradient()
  minimal = minimal.removingStop(id: minimal.stops[0].id)
  #expect(minimal.stops.count == 2)
}

@Test func distributingSpreadsStopsEvenlyBetweenTheEnds() {
  var gradient = VectorGradient()
    .addingStop(at: 0.1)
    .addingStop(at: 0.15)
  gradient = gradient.distributingStopsEvenly()
  let positions = gradient.stops.map(\.position)
  #expect(positions.count == 4)
  for index in positions.indices {
    #expect(abs(positions[index] - Double(index) / 3) < 1e-9)
  }
}

@Test func reversingMirrorsTheRampAndItsMidpoints() throws {
  var gradient = VectorGradient(stops: [
    VectorGradientStop(color: .black, position: 0, midpoint: 0.25),
    VectorGradientStop(color: .white, position: 1),
  ])
  gradient = gradient.reversingStops()

  #expect(gradient.stops.map(\.color) == [.white, .black])
  #expect(gradient.stops.map(\.position) == [0, 1])
  // A blend that was fast at the start is now fast at the end.
  #expect(abs(gradient.stops[0].midpoint - 0.75) < 1e-9)
}

@Test func aTransformedObjectCarriesItsGradientCoordinates() throws {
  let gradient = VectorGradient(
    kind: .radial,
    start: VectorPoint(x: 0.2, y: 0.2),
    end: VectorPoint(x: 0.4, y: 0.2),
    focal: VectorPoint(x: 0.25, y: 0.22)
  )
  let path = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.2, y: 0.2)),
      VectorAnchor(position: VectorPoint(x: 0.6, y: 0.2)),
      VectorAnchor(position: VectorPoint(x: 0.6, y: 0.6)),
    ],
    isClosed: true,
    fill: VectorFillStyle(gradient: gradient)
  )

  let moved = path.transformed(by: .translation(x: 0.1, y: 0.05))
  let movedGradient = try #require(moved.fill?.gradient)
  #expect(abs(movedGradient.start.x - 0.3) < 1e-9)
  #expect(abs(movedGradient.end.x - 0.5) < 1e-9)
  #expect(abs((movedGradient.focal?.y ?? 0) - 0.27) < 1e-9)

  // Scaling the object scales the gradient with it, so the fill keeps its
  // proportions inside the shape.
  let scaled = path.transformed(by: .scale(x: 2, y: 2, about: VectorPoint(x: 0.2, y: 0.2)))
  let scaledGradient = try #require(scaled.fill?.gradient)
  #expect(abs(scaledGradient.end.x - 0.6) < 1e-9)
}

@Test func gradientHandleEditsReachEveryVectorObjectKind() throws {
  let original = VectorGradient(
    start: VectorPoint(x: 0.2, y: 0.3),
    end: VectorPoint(x: 0.7, y: 0.8))
  let replacement = VectorGradient(
    kind: .radial,
    start: VectorPoint(x: 0.4, y: 0.5),
    end: VectorPoint(x: 0.9, y: 0.5))
  let path = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.1, y: 0.1)),
      VectorAnchor(position: VectorPoint(x: 0.9, y: 0.9)),
    ],
    isClosed: true,
    fill: VectorFillStyle(gradient: original))
  let shape = VectorShape(
    kind: .rectangle(corners: .none),
    frame: VectorBounds(minX: 0.1, minY: 0.1, maxX: 0.9, maxY: 0.9),
    fill: VectorFillStyle(gradient: original))
  let compound = VectorCompoundPath(
    contours: [VectorContour(path)],
    fill: VectorFillStyle(gradient: original))
  let layer = VectorLayer(objects: [.path(path), .shape(shape), .compound(compound)])

  for object in layer.objects {
    #expect(layer.gradient(for: object.id) == original)
    let updated = layer.settingGradient(replacement, for: object.id)
    #expect(updated.gradient(for: object.id) == replacement)
    #expect(updated.object(id: object.id)?.id == object.id)
    #expect(updated.object(id: object.id)?.name == object.name)
  }

  #expect(layer.objects.allSatisfy { $0.fill?.gradient == original })
}

@Test func affineTransformsRecomputeARadialGradientsEllipse() {
  let gradient = VectorGradient(
    kind: .radial,
    start: VectorPoint(x: 0.2, y: 0.5),
    end: VectorPoint(x: 0.4, y: 0.5),
    aspectRatio: 0.5)
  let transformed = gradient.transformed(
    by: .scale(x: 2, y: 3), aspect: 2)

  #expect(abs(transformed.start.x - 0.4) < 1e-9)
  #expect(abs(transformed.end.x - 0.8) < 1e-9)
  #expect(abs(transformed.end.y - 1.5) < 1e-9)
  // The primary radius doubled and the secondary radius tripled, so a 1:2
  // ellipse becomes 3:4 rather than retaining its stale 1:2 ratio.
  #expect(abs(transformed.aspectRatio - 0.75) < 1e-9)
}

@Test func writingASolidColorReplacesAGradientFill() {
  var fill = VectorFillStyle(gradient: VectorGradient())
  #expect(fill.isGradient)
  fill.color = VectorColor(red: 1, green: 0, blue: 0)
  #expect(!fill.isGradient)
  #expect(fill.color == VectorColor(red: 1, green: 0, blue: 0))
}

@Test func fillOpacityIsKeptWhicheverContentTheFillHolds() {
  var solid = VectorFillStyle(color: .white)
  solid.opacity = 0.4
  #expect(solid.opacity == 0.4)

  var gradient = VectorFillStyle(gradient: VectorGradient())
  gradient.opacity = 0.6
  #expect(gradient.opacity == 0.6)
  #expect(gradient.gradient?.opacity == 0.6)
}

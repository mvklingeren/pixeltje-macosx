import Foundation
import PixeltjeMacDomain
import Testing

@Test func repeatedClicksProducePurelyStraightPath() {
  let path = VectorPath(anchors: [
    VectorAnchor(position: VectorPoint(x: 0.1, y: 0.1)),
    VectorAnchor(position: VectorPoint(x: 0.5, y: 0.4)),
    VectorAnchor(position: VectorPoint(x: 0.9, y: 0.2)),
  ])

  #expect(path.anchors.allSatisfy { $0.incomingHandle == nil && $0.outgoingHandle == nil })
  #expect(path.segment(startingAt: 0)?.control1 == path.anchors[0].position)
  #expect(path.segment(startingAt: 1)?.control2 == path.anchors[2].position)
}

@Test func clickDragProducesSmoothTwoSidedHandles() {
  var placement = PenPlacementState(position: VectorPoint(x: 0.5, y: 0.5))
  placement.update(
    pointer: VectorPoint(x: 0.52, y: 0.51),
    screenDistanceFromStart: 2.9,
    modifiers: []
  )
  #expect(placement.anchor.incomingHandle == nil)
  #expect(placement.anchor.outgoingHandle == nil)
  placement.update(
    pointer: VectorPoint(x: 0.7, y: 0.6),
    screenDistanceFromStart: 12,
    modifiers: []
  )

  #expect(placement.anchor.kind == .symmetric)
  #expect(placement.anchor.outgoingHandle == VectorPoint(x: 0.7, y: 0.6))
  #expect(placement.anchor.incomingHandle!.distance(to: VectorPoint(x: 0.3, y: 0.4)) < 1e-12)
}

@Test func snapDefaultsExposeSupportedTargetsAndDisableUnavailableSources() {
  let settings = PenSnapSettings()
  #expect(settings.radiusInScreenPoints == 6)
  #expect(settings.closeRadiusInScreenPoints == 8)
  #expect(settings.hysteresisInScreenPoints == 2)
  #expect(settings.angleIncrementDegrees == 45)
  #expect(settings.enabledTargetKinds.contains(.anchor))
  #expect(settings.enabledTargetKinds.contains(.endpoint))
  #expect(settings.enabledTargetKinds.contains(.angleConstraint))
  #expect(settings.enabledTargetKinds.contains(.intersection) == false)
  #expect(settings.enabledTargetKinds.contains(.objectEdge) == false)
  #expect(settings.enabledTargetKinds.contains(.objectCenter) == false)
  #expect(settings.gridSpacing == nil)
  #expect(settings.guidePositions.isEmpty)
  #expect(Set(SnapTargetKind.allCases).count == 8)
}

@Test func cancellingPlacementDropsUncommittedHandles() {
  let position = VectorPoint(x: 0.25, y: 0.75)
  var placement = PenPlacementState(position: position)
  placement.update(
    pointer: VectorPoint(x: 0.6, y: 0.4),
    screenDistanceFromStart: 20,
    modifiers: []
  )
  placement.cancel()
  #expect(placement.anchor.position == position)
  #expect(placement.anchor.incomingHandle == nil)
  #expect(placement.anchor.outgoingHandle == nil)
  #expect(placement.crossedDragThreshold == false)
}

@Test func shiftConstrainsSegmentsAndHandleAngles() {
  let origin = VectorPoint(x: 0, y: 0)
  let constrainedSegment = PenGeometry.constrained(VectorPoint(x: 0.8, y: 0.31), relativeTo: origin)
  #expect(abs(constrainedSegment.y) < 0.000_000_000_001)

  var placement = PenPlacementState(position: origin)
  placement.update(
    pointer: VectorPoint(x: 0.8, y: 0.6),
    screenDistanceFromStart: 20,
    modifiers: [.constrain]
  )
  #expect(placement.anchor.outgoingHandle != nil)
  let handle = placement.anchor.outgoingHandle ?? .zero
  #expect(abs(abs(handle.x) - abs(handle.y)) < 0.000_000_000_001)
}

@Test func optionSeparatesHandlesWithoutMovingAnchor() {
  let origin = VectorPoint(x: 0.5, y: 0.5)
  var placement = PenPlacementState(position: origin)
  placement.update(
    pointer: VectorPoint(x: 0.65, y: 0.5),
    screenDistanceFromStart: 10,
    modifiers: []
  )
  let incomingBefore = placement.anchor.incomingHandle
  placement.update(
    pointer: VectorPoint(x: 0.5, y: 0.8),
    screenDistanceFromStart: 20,
    modifiers: [.splitHandles]
  )

  #expect(placement.anchor.position == origin)
  #expect(placement.anchor.incomingHandle == incomingBefore)
  #expect(placement.anchor.outgoingHandle == VectorPoint(x: 0.5, y: 0.8))
  #expect(placement.anchor.kind == .corner)
}

@Test func spaceMoveRetainsProvisionalCurve() {
  var placement = PenPlacementState(position: VectorPoint(x: 0.3, y: 0.3))
  placement.update(
    pointer: VectorPoint(x: 0.5, y: 0.4),
    screenDistanceFromStart: 12,
    modifiers: []
  )
  let incomingOffset = placement.anchor.incomingHandle! - placement.anchor.position
  let outgoingOffset = placement.anchor.outgoingHandle! - placement.anchor.position
  placement.moveProvisionalAnchor(by: VectorPoint(x: 0.17, y: -0.09))

  #expect(
    (placement.anchor.incomingHandle! - placement.anchor.position).distance(to: incomingOffset)
      < 1e-12
  )
  #expect(
    (placement.anchor.outgoingHandle! - placement.anchor.position).distance(to: outgoingOffset)
      < 1e-12
  )
}

@Test func deCasteljauInsertionPreservesCurveExactly() throws {
  var path = VectorPath(anchors: [
    VectorAnchor(
      position: VectorPoint(x: 0.1, y: 0.2),
      outgoingHandle: VectorPoint(x: 0.3, y: 0.9),
      kind: .corner
    ),
    VectorAnchor(
      position: VectorPoint(x: 0.9, y: 0.7),
      incomingHandle: VectorPoint(x: 0.75, y: 0.05),
      kind: .corner
    ),
  ])
  let original = try #require(path.segment(startingAt: 0))
  _ = path.insertAnchor(onSegmentStartingAt: 0, t: 0.37)
  let left = try #require(path.segment(startingAt: 0))
  let right = try #require(path.segment(startingAt: 1))

  for step in 0...100 {
    let t = Double(step) / 100
    let preserved: VectorPoint
    if t <= 0.37 {
      preserved = left.point(at: t / 0.37)
    } else {
      preserved = right.point(at: (t - 0.37) / 0.63)
    }
    let expected = original.point(at: t)
    #expect(preserved.distance(to: expected) < 0.000_000_000_001)
  }
}

@Test func closingPathPreservesStartingIncomingHandle() {
  let incoming = VectorPoint(x: 0.08, y: 0.4)
  var path = VectorPath(anchors: [
    VectorAnchor(
      position: VectorPoint(x: 0.2, y: 0.2),
      incomingHandle: incoming,
      outgoingHandle: VectorPoint(x: 0.4, y: 0.1),
      kind: .corner
    ),
    VectorAnchor(position: VectorPoint(x: 0.8, y: 0.2)),
    VectorAnchor(position: VectorPoint(x: 0.5, y: 0.8)),
  ])
  path.isClosed = true

  #expect(path.anchors[0].incomingHandle == incoming)
  #expect(path.segment(startingAt: 2)?.control2 == incoming)
}

@Test func vectorStateCanBeRestoredExactlyForUndo() {
  let initial = ProjectRecipe()
  var editedStack = initial.layerStack
  let layerID = editedStack.ensureActiveVectorLayer()
  editedStack.appendPath(
    VectorPath(anchors: [VectorAnchor(position: VectorPoint(x: 0.123_456_789, y: 0.9))]),
    to: layerID
  )
  let edited = initial.applying(.setLayerStack(editedStack, actionName: "Add Anchor"))
  let restored = edited.applying(.setLayerStack(initial.layerStack, actionName: "Undo"))

  #expect(restored == initial)
}

@Test func modifierChangesTakeEffectDuringPointerDown() {
  var placement = PenPlacementState(position: .zero)
  placement.update(
    pointer: VectorPoint(x: 0.8, y: 0.3),
    screenDistanceFromStart: 12,
    modifiers: []
  )
  let unconstrained = placement.anchor.outgoingHandle
  placement.update(
    pointer: VectorPoint(x: 0.8, y: 0.3),
    screenDistanceFromStart: 12,
    modifiers: [.constrain]
  )

  #expect(placement.anchor.outgoingHandle != unconstrained)
  #expect(abs(placement.anchor.outgoingHandle!.y) < 0.000_000_000_001)
}

@Test func cursorStatesAreUnderstandableWithoutColor() {
  let badges = PenCursorState.allCases.map(\.badge)
  let labels = PenCursorState.allCases.map(\.accessibilityLabel)
  #expect(badges.allSatisfy { !$0.isEmpty })
  #expect(labels.allSatisfy { !$0.isEmpty })
  #expect(Set(badges).count == badges.count)
  #expect(Set(labels).count == labels.count)
}

@Test func schemaOneRecipeMigratesToPersistentLayerStack() throws {
  let json = """
    {
      "schemaVersion": 1,
      "rawDevelopment": { "supportedDecoderVersions": [] },
      "crop": { "left": 0, "bottom": 0, "right": 1, "top": 1 },
      "postProcessing": { "brightness": 0, "contrast": 1, "saturation": 1 },
      "color": { "workingColorSpace": "extendedLinearDisplayP3", "exportColorSpace": "displayP3" },
      "capturedOperatingSystemVersion": "macOS"
    }
    """
  let restored = try JSONDecoder().decode(ProjectRecipe.self, from: Data(json.utf8))

  #expect(restored.schemaVersion == ProjectRecipe.currentSchemaVersion)
  #expect(restored.layerStack.contentLayers.count == 1)
  #expect(restored.layerStack.contentLayers[0].isVectorLayer == false)
}

@Test func vectorLayerRoundTripsWithStableIdentitiesAndPrecision() throws {
  var project = ProjectRecipe()
  var stack = project.layerStack
  let layerID = stack.ensureActiveVectorLayer()
  let anchorID = UUID()
  let pathID = UUID()
  stack.appendPath(
    VectorPath(
      id: pathID,
      anchors: [
        VectorAnchor(
          id: anchorID,
          position: VectorPoint(x: 0.123_456_789_012_345, y: 0.987_654_321_098_765),
          incomingHandle: VectorPoint(x: 0.1, y: 0.9),
          outgoingHandle: VectorPoint(x: 0.2, y: 0.8),
          kind: .smooth
        )
      ]
    ),
    to: layerID
  )
  project.layerStack = stack

  let data = try JSONEncoder().encode(project)
  let restored = try JSONDecoder().decode(ProjectRecipe.self, from: data)
  let path = try #require(restored.layerStack.path(id: pathID)?.path)
  #expect(path.anchors[0].id == anchorID)
  #expect(path.anchors[0].position.x == 0.123_456_789_012_345)
  #expect(restored == project)
}

@Test func penCreatesVectorLayerAboveRawWhenNoneIsSelected() {
  var stack = LayerStack.migratedDefault()
  let rawZ = stack.layers[0].zOrder
  let vectorID = stack.ensureActiveVectorLayer()
  let vector = stack.layer(id: vectorID)

  #expect(vector?.isVectorLayer == true)
  #expect(vector?.zOrder == rawZ + 1)
  #expect(stack.activeLayerID == vectorID)
}

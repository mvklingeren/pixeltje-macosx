import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

/// The point editor's drag, exercised the way the graph drives it: a press,
/// then the moves of the same drag, then the release.
///
/// The drag keeps its own copy of the curve because the graph's copy comes from
/// the document and lags a step behind. These tests are what says the drag
/// reads that copy and not a stale one — the failure mode was a click that
/// added a point and then immediately dragged the white point over it, so no
/// point ever appeared.

@MainActor
@Test func aClickAddsAPointAndKeepsIt() {
  let state = ToneCurveEditorState()
  let target = ToneCurvePoint(x: 0.5, y: 0.7)

  let added = state.beginDrag(on: .identity, at: target, hitRadius: 0.06)
  #expect(added?.points.count == 3)

  // A click delivers a move at the press location before the release; it must
  // move the new point, not undo it.
  let step = state.continueDrag(to: target, delete: false)
  #expect(step?.curve.points.count == 3)
  #expect(step?.curve.points[1] == target)
  #expect(step?.interactive == true)

  state.endDrag()
  #expect(state.isDragging == false)
  #expect(state.dragCurve == nil)
}

@MainActor
@Test func aDragMovesTheAddedPointAcrossSeveralEvents() {
  let state = ToneCurveEditorState()
  _ = state.beginDrag(on: .identity, at: ToneCurvePoint(x: 0.4, y: 0.4), hitRadius: 0.06)

  var last: PointToneCurve?
  for y in [0.5, 0.6, 0.75] {
    last = state.continueDrag(to: ToneCurvePoint(x: 0.4, y: y), delete: false)?.curve
  }
  #expect(last?.points.count == 3)
  #expect(last?.points[1].y == 0.75)
}

@MainActor
@Test func aPressGrabsAnExistingPointWithoutChangingTheCurve() {
  let state = ToneCurveEditorState()
  let curve = PointToneCurve.identity.adding(ToneCurvePoint(x: 0.5, y: 0.5))!.curve

  let added = state.beginDrag(on: curve, at: ToneCurvePoint(x: 0.52, y: 0.48), hitRadius: 0.06)
  #expect(added == nil)
  #expect(state.isDragging)

  let moved = state.continueDrag(to: ToneCurvePoint(x: 0.6, y: 0.3), delete: false)?.curve
  #expect(moved?.points.count == 3)
  #expect(moved?.points[1] == ToneCurvePoint(x: 0.6, y: 0.3))
}

@MainActor
@Test func draggingAPointOffTheGraphDeletesItOnce() {
  let state = ToneCurveEditorState()
  _ = state.beginDrag(on: .identity, at: ToneCurvePoint(x: 0.5, y: 0.5), hitRadius: 0.06)

  let deleted = state.continueDrag(to: ToneCurvePoint(x: 0.5, y: 2), delete: true)
  #expect(deleted?.curve.isIdentity == true)
  // The edit that removes a point is not interactive: it is the final value.
  #expect(deleted?.interactive == false)
  // Nothing is left to move, so the rest of the drag does nothing.
  #expect(state.continueDrag(to: ToneCurvePoint(x: 0.5, y: 0.5), delete: false) == nil)
}

@MainActor
@Test func aPressTooCloseToAnEdgeAddsNothing() {
  let state = ToneCurveEditorState()
  let added = state.beginDrag(on: .identity, at: ToneCurvePoint(x: 0.002, y: 0.9), hitRadius: 0.001)
  #expect(added == nil)
  #expect(state.continueDrag(to: ToneCurvePoint(x: 0.002, y: 0.9), delete: false) == nil)
}

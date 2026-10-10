import Foundation

public struct CubicBezier: Equatable, Sendable {
  public var start: VectorPoint
  public var control1: VectorPoint
  public var control2: VectorPoint
  public var end: VectorPoint

  public init(
    start: VectorPoint,
    control1: VectorPoint,
    control2: VectorPoint,
    end: VectorPoint
  ) {
    self.start = start
    self.control1 = control1
    self.control2 = control2
    self.end = end
  }

  public func point(at t: Double) -> VectorPoint {
    let oneMinusT = 1 - t
    return start * (oneMinusT * oneMinusT * oneMinusT)
      + control1 * (3 * oneMinusT * oneMinusT * t)
      + control2 * (3 * oneMinusT * t * t)
      + end * (t * t * t)
  }

  public func split(at rawT: Double) -> (CubicBezier, CubicBezier) {
    let t = min(max(rawT, 0), 1)
    let q0 = start.interpolated(to: control1, t: t)
    let q1 = control1.interpolated(to: control2, t: t)
    let q2 = control2.interpolated(to: end, t: t)
    let r0 = q0.interpolated(to: q1, t: t)
    let r1 = q1.interpolated(to: q2, t: t)
    let split = r0.interpolated(to: r1, t: t)
    return (
      CubicBezier(start: start, control1: q0, control2: r0, end: split),
      CubicBezier(start: split, control1: r1, control2: q2, end: end)
    )
  }
}

extension VectorPath {
  public func segment(startingAt index: Int) -> CubicBezier? {
    guard anchors.count >= 2, anchors.indices.contains(index) else { return nil }
    let nextIndex = index + 1
    let resolvedNext: Int
    if anchors.indices.contains(nextIndex) {
      resolvedNext = nextIndex
    } else if isClosed {
      resolvedNext = 0
    } else {
      return nil
    }

    let first = anchors[index]
    let second = anchors[resolvedNext]
    return CubicBezier(
      start: first.position,
      control1: first.outgoingHandle ?? first.position,
      control2: second.incomingHandle ?? second.position,
      end: second.position
    )
  }

  /// Inserts an anchor with exact de Casteljau subdivision. The two resulting
  /// cubics evaluate to the same curve as the original segment.
  public mutating func insertAnchor(onSegmentStartingAt index: Int, t: Double) -> UUID? {
    guard let original = segment(startingAt: index) else { return nil }
    let (left, right) = original.split(at: t)
    let nextIndex = (index + 1) % anchors.count
    anchors[index].outgoingHandle = left.control1
    anchors[nextIndex].incomingHandle = right.control2

    let anchor = VectorAnchor(
      position: left.end,
      incomingHandle: left.control2,
      outgoingHandle: right.control1,
      kind: .smooth
    )
    anchors.insert(anchor, at: index + 1)
    return anchor.id
  }
}

public enum PenCursorState: String, CaseIterable, Codable, Sendable {
  case create
  case addAnchor
  case removeAnchor
  case continuePath
  case closePath
  case joinPath
  case convertAnchor
  case directSelect

  public var badge: String {
    switch self {
    case .create: "✒"
    case .addAnchor: "+"
    case .removeAnchor: "−"
    case .continuePath: "↪"
    case .closePath: "○"
    case .joinPath: "⇥"
    case .convertAnchor: "◇"
    case .directSelect: "◆"
    }
  }

  public var accessibilityLabel: String {
    switch self {
    case .create: "Create anchor"
    case .addAnchor: "Insert anchor"
    case .removeAnchor: "Remove anchor"
    case .continuePath: "Continue open path"
    case .closePath: "Close path"
    case .joinPath: "Join open paths"
    case .convertAnchor: "Convert anchor"
    case .directSelect: "Direct-select anchor or handle"
    }
  }
}

public enum SnapTargetKind: String, CaseIterable, Codable, Sendable {
  case anchor
  case endpoint
  case intersection
  case grid
  case guide
  case objectEdge
  case objectCenter
  case angleConstraint
}

public struct SnapTarget: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var position: VectorPoint
  public var kind: SnapTargetKind
  public var label: String
  public var sourceID: UUID?

  public init(
    id: UUID = UUID(),
    position: VectorPoint,
    kind: SnapTargetKind,
    label: String,
    sourceID: UUID? = nil
  ) {
    self.id = id
    self.position = position
    self.kind = kind
    self.label = label
    self.sourceID = sourceID
  }
}

public struct PenSnapSettings: Codable, Equatable, Sendable {
  public var radiusInScreenPoints: Double
  public var closeRadiusInScreenPoints: Double
  public var hysteresisInScreenPoints: Double
  public var angleIncrementDegrees: Double
  public var enabledTargetKinds: Set<SnapTargetKind>
  public var gridSpacing: VectorPoint?
  public var guidePositions: [VectorPoint]

  public init(
    radiusInScreenPoints: Double = 6,
    closeRadiusInScreenPoints: Double = 8,
    hysteresisInScreenPoints: Double = 2,
    angleIncrementDegrees: Double = 45,
    enabledTargetKinds: Set<SnapTargetKind> = [.anchor, .endpoint, .angleConstraint],
    gridSpacing: VectorPoint? = nil,
    guidePositions: [VectorPoint] = []
  ) {
    self.radiusInScreenPoints = radiusInScreenPoints
    self.closeRadiusInScreenPoints = closeRadiusInScreenPoints
    self.hysteresisInScreenPoints = hysteresisInScreenPoints
    self.angleIncrementDegrees = angleIncrementDegrees
    self.enabledTargetKinds = enabledTargetKinds
    self.gridSpacing = gridSpacing
    self.guidePositions = guidePositions
  }
}

public enum PenGeometry {
  public static func constrained(
    _ point: VectorPoint,
    relativeTo origin: VectorPoint,
    incrementDegrees: Double = 45
  ) -> VectorPoint {
    let delta = point - origin
    let length = hypot(delta.x, delta.y)
    guard length > 0, incrementDegrees > 0 else { return point }
    let increment = incrementDegrees * .pi / 180
    let angle = atan2(delta.y, delta.x)
    let snappedAngle = (angle / increment).rounded() * increment
    return VectorPoint(
      x: origin.x + cos(snappedAngle) * length,
      y: origin.y + sin(snappedAngle) * length
    )
  }

  public static func symmetricAnchor(
    at position: VectorPoint,
    draggedTo outgoing: VectorPoint
  ) -> VectorAnchor {
    let delta = outgoing - position
    return VectorAnchor(
      position: position,
      incomingHandle: position - delta,
      outgoingHandle: outgoing,
      kind: .symmetric
    )
  }
}

public struct PenGestureModifiers: OptionSet, Equatable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let constrain = PenGestureModifiers(rawValue: 1 << 0)
  public static let splitHandles = PenGestureModifiers(rawValue: 1 << 1)
}

/// Framework-light placement state used by tests and non-AppKit interaction
/// clients. The canvas supplies screen-space threshold distances and performs
/// its screen/document coordinate conversion before calling this state.
public struct PenPlacementState: Equatable, Sendable {
  public var anchor: VectorAnchor
  public var crossedDragThreshold: Bool
  public var frozenIncomingHandle: VectorPoint?

  public init(position: VectorPoint) {
    anchor = VectorAnchor(position: position)
    crossedDragThreshold = false
    frozenIncomingHandle = nil
  }

  public mutating func update(
    pointer: VectorPoint,
    screenDistanceFromStart: Double,
    modifiers: PenGestureModifiers,
    dragThresholdInScreenPoints: Double = 3,
    angleIncrementDegrees: Double = 45
  ) {
    guard screenDistanceFromStart >= dragThresholdInScreenPoints || crossedDragThreshold else {
      return
    }
    crossedDragThreshold = true
    let outgoing =
      modifiers.contains(.constrain)
      ? PenGeometry.constrained(
        pointer,
        relativeTo: anchor.position,
        incrementDegrees: angleIncrementDegrees
      )
      : pointer
    let delta = outgoing - anchor.position

    if modifiers.contains(.splitHandles) {
      if frozenIncomingHandle == nil {
        frozenIncomingHandle = anchor.incomingHandle ?? anchor.position - delta
      }
      anchor.incomingHandle = frozenIncomingHandle
      anchor.outgoingHandle = outgoing == anchor.position ? nil : outgoing
      anchor.kind = .corner
    } else {
      frozenIncomingHandle = nil
      anchor.incomingHandle = outgoing == anchor.position ? nil : anchor.position - delta
      anchor.outgoingHandle = outgoing == anchor.position ? nil : outgoing
      anchor.kind = .symmetric
    }
  }

  public mutating func moveProvisionalAnchor(by delta: VectorPoint) {
    anchor = anchor.translated(by: delta)
    if let frozenIncomingHandle {
      self.frozenIncomingHandle = frozenIncomingHandle + delta
    }
  }

  public mutating func cancel() {
    self = PenPlacementState(position: anchor.position)
  }
}

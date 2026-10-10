import Foundation

public struct AutomationDevelopPatch: Codable, Equatable, Sendable {
  public var documentID: String
  public var layerID: String
  public var expectedRevision: UInt64
  public var idempotencyKey: String
  public var rawFloats: [String: Double]
  public var rawBooleans: [String: Bool]
  public var basicTone: [String: Double]

  public init(
    documentID: String,
    layerID: String,
    expectedRevision: UInt64,
    idempotencyKey: String,
    rawFloats: [String: Double] = [:],
    rawBooleans: [String: Bool] = [:],
    basicTone: [String: Double] = [:]
  ) {
    self.documentID = documentID
    self.layerID = layerID
    self.expectedRevision = expectedRevision
    self.idempotencyKey = idempotencyKey
    self.rawFloats = rawFloats
    self.rawBooleans = rawBooleans
    self.basicTone = basicTone
  }
}

public struct AutomationLayerPatch: Codable, Equatable, Sendable {
  public var documentID: String
  public var layerID: String
  public var expectedRevision: UInt64
  public var idempotencyKey: String
  public var isEnabled: Bool?
  public var blendMode: String?
  public var opacity: Double?
  public var fill: Double?

  public init(
    documentID: String,
    layerID: String,
    expectedRevision: UInt64,
    idempotencyKey: String,
    isEnabled: Bool? = nil,
    blendMode: String? = nil,
    opacity: Double? = nil,
    fill: Double? = nil
  ) {
    self.documentID = documentID
    self.layerID = layerID
    self.expectedRevision = expectedRevision
    self.idempotencyKey = idempotencyKey
    self.isEnabled = isEnabled
    self.blendMode = blendMode
    self.opacity = opacity
    self.fill = fill
  }
}

public enum AutomationLayerMoveDirection: String, Codable, Sendable {
  case up
  case down
}

public struct AutomationMoveLayerCommand: Codable, Equatable, Sendable {
  public var documentID: String
  public var layerID: String
  public var direction: AutomationLayerMoveDirection
  public var expectedRevision: UInt64
  public var idempotencyKey: String

  public init(
    documentID: String,
    layerID: String,
    direction: AutomationLayerMoveDirection,
    expectedRevision: UInt64,
    idempotencyKey: String
  ) {
    self.documentID = documentID
    self.layerID = layerID
    self.direction = direction
    self.expectedRevision = expectedRevision
    self.idempotencyKey = idempotencyKey
  }
}

public struct AutomationCropCommand: Codable, Equatable, Sendable {
  public var documentID: String
  public var expectedRevision: UInt64
  public var idempotencyKey: String
  public var left: Double
  public var bottom: Double
  public var right: Double
  public var top: Double
  public var angleDegrees: Double

  public init(
    documentID: String,
    expectedRevision: UInt64,
    idempotencyKey: String,
    left: Double,
    bottom: Double,
    right: Double,
    top: Double,
    angleDegrees: Double
  ) {
    self.documentID = documentID
    self.expectedRevision = expectedRevision
    self.idempotencyKey = idempotencyKey
    self.left = left
    self.bottom = bottom
    self.right = right
    self.top = top
    self.angleDegrees = angleDegrees
  }
}

public struct AutomationResizeCanvasCommand: Codable, Equatable, Sendable {
  public var documentID: String
  public var expectedRevision: UInt64
  public var idempotencyKey: String
  public var width: Int
  public var height: Int
  public var anchor: String

  public init(
    documentID: String,
    expectedRevision: UInt64,
    idempotencyKey: String,
    width: Int,
    height: Int,
    anchor: String
  ) {
    self.documentID = documentID
    self.expectedRevision = expectedRevision
    self.idempotencyKey = idempotencyKey
    self.width = width
    self.height = height
    self.anchor = anchor
  }
}

public struct AutomationCreateSnapshotCommand: Codable, Equatable, Sendable {
  public var documentID: String
  public var expectedRevision: UInt64
  public var idempotencyKey: String
  public var name: String?

  public init(
    documentID: String,
    expectedRevision: UInt64,
    idempotencyKey: String,
    name: String? = nil
  ) {
    self.documentID = documentID
    self.expectedRevision = expectedRevision
    self.idempotencyKey = idempotencyKey
    self.name = name
  }
}

public struct AutomationRestoreSnapshotCommand: Codable, Equatable, Sendable {
  public var documentID: String
  public var snapshotID: String
  public var expectedRevision: UInt64
  public var idempotencyKey: String

  public init(
    documentID: String,
    snapshotID: String,
    expectedRevision: UInt64,
    idempotencyKey: String
  ) {
    self.documentID = documentID
    self.snapshotID = snapshotID
    self.expectedRevision = expectedRevision
    self.idempotencyKey = idempotencyKey
  }
}

public struct AutomationCancelJobCommand: Codable, Equatable, Sendable {
  public var documentID: String
  public var jobID: String
  public var idempotencyKey: String

  public init(documentID: String, jobID: String, idempotencyKey: String) {
    self.documentID = documentID
    self.jobID = jobID
    self.idempotencyKey = idempotencyKey
  }
}

/// Selects the shared mask Pixeltje should freeze for one automated inpaint.
///
/// Omission from `AutomationStartInpaintingCommand` deliberately retains the
/// original automation behavior: use the document selection when one exists,
/// otherwise use the entire output.
public struct AutomationInpaintingMaskSource: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
    case automatic
    case documentSelection
    case activeLayerMask
    case layerMask
    case localMask
    case transparentPixels
    case entireOutput
  }

  public var kind: Kind
  public var layerID: String?
  public var maskID: String?

  public init(kind: Kind, layerID: String? = nil, maskID: String? = nil) {
    self.kind = kind
    self.layerID = layerID
    self.maskID = maskID
  }
}

/// Starts one prompt-driven inpainting job against the document's frozen
/// composite and requested shared mask source.
public struct AutomationStartInpaintingCommand: Codable, Equatable, Sendable {
  public var documentID: String
  public var expectedRevision: UInt64
  public var idempotencyKey: String
  public var prompt: String
  public var negativePrompt: String
  public var seed: UInt64
  public var strength: Double
  public var maskBlur: Double
  public var steps: Int
  public var guidance: Double
  public var maskSource: AutomationInpaintingMaskSource?

  public init(
    documentID: String,
    expectedRevision: UInt64,
    idempotencyKey: String,
    prompt: String,
    negativePrompt: String = "",
    seed: UInt64 = 1,
    strength: Double = 0.85,
    maskBlur: Double = 0,
    steps: Int = 8,
    guidance: Double = 1,
    maskSource: AutomationInpaintingMaskSource? = nil
  ) {
    self.documentID = documentID
    self.expectedRevision = expectedRevision
    self.idempotencyKey = idempotencyKey
    self.prompt = prompt
    self.negativePrompt = negativePrompt
    self.seed = seed
    self.strength = strength
    self.maskBlur = maskBlur
    self.steps = steps
    self.guidance = guidance
    self.maskSource = maskSource
  }
}

public enum AutomationCommand: Codable, Equatable, Sendable {
  case updateDevelop(AutomationDevelopPatch)
  case updateLayer(AutomationLayerPatch)
  case moveLayer(AutomationMoveLayerCommand)
  case setCrop(AutomationCropCommand)
  case resizeCanvas(AutomationResizeCanvasCommand)
  case createSnapshot(AutomationCreateSnapshotCommand)
  case restoreSnapshot(AutomationRestoreSnapshotCommand)
  case cancelJob(AutomationCancelJobCommand)
  case startInpainting(AutomationStartInpaintingCommand)

  public var idempotencyKey: String {
    switch self {
    case .updateDevelop(let command): command.idempotencyKey
    case .updateLayer(let command): command.idempotencyKey
    case .moveLayer(let command): command.idempotencyKey
    case .setCrop(let command): command.idempotencyKey
    case .resizeCanvas(let command): command.idempotencyKey
    case .createSnapshot(let command): command.idempotencyKey
    case .restoreSnapshot(let command): command.idempotencyKey
    case .cancelJob(let command): command.idempotencyKey
    case .startInpainting(let command): command.idempotencyKey
    }
  }
}

import Foundation

/// Capabilities granted to one automation client.
///
/// The automation core knows nothing about MCP, Shortcuts, or scripts. Each
/// adapter translates its own authorization model into these protocol-neutral
/// scopes before calling the service.
public enum AutomationScope: String, Codable, CaseIterable, Hashable, Sendable {
  case read
  case edit
  case jobs
}

public struct AutomationRequestContext: Codable, Equatable, Sendable {
  public var clientID: String
  public var scopes: Set<AutomationScope>

  public init(clientID: String, scopes: Set<AutomationScope>) {
    self.clientID = clientID
    self.scopes = scopes
  }
}

public enum AutomationErrorCode: String, Codable, Sendable {
  case accessDenied
  case documentNotFound
  case layerNotFound
  case snapshotNotFound
  case jobNotFound
  case invalidArgument
  case unsupportedOperation
  case staleRevision
  case documentBusy
  case internalError
}

public struct AutomationServiceError: Error, LocalizedError, Sendable {
  public var code: AutomationErrorCode
  public var message: String
  public var details: [String: String]

  public init(
    _ code: AutomationErrorCode,
    _ message: String,
    details: [String: String] = [:]
  ) {
    self.code = code
    self.message = message
    self.details = details
  }

  public var errorDescription: String? { message }
}

public struct AutomationCanvasSnapshot: Codable, Equatable, Sendable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

public struct AutomationRenderSnapshot: Codable, Equatable, Sendable {
  public var state: String
  public var message: String
  public var isBusy: Bool

  public init(state: String, message: String, isBusy: Bool) {
    self.state = state
    self.message = message
    self.isBusy = isBusy
  }
}

public struct AutomationDocumentSummary: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var isEdited: Bool
  public var contentRevision: UInt64
  public var canvas: AutomationCanvasSnapshot

  public init(
    id: String,
    name: String,
    isEdited: Bool,
    contentRevision: UInt64,
    canvas: AutomationCanvasSnapshot
  ) {
    self.id = id
    self.name = name
    self.isEdited = isEdited
    self.contentRevision = contentRevision
    self.canvas = canvas
  }
}

public struct AutomationDocumentSnapshot: Codable, Equatable, Sendable {
  public var document: AutomationDocumentSummary
  public var activeLayerID: String?
  public var layerCount: Int
  public var hasSelection: Bool
  public var workingColorSpace: String
  public var render: AutomationRenderSnapshot

  public init(
    document: AutomationDocumentSummary,
    activeLayerID: String?,
    layerCount: Int,
    hasSelection: Bool,
    workingColorSpace: String,
    render: AutomationRenderSnapshot
  ) {
    self.document = document
    self.activeLayerID = activeLayerID
    self.layerCount = layerCount
    self.hasSelection = hasSelection
    self.workingColorSpace = workingColorSpace
    self.render = render
  }
}

public struct AutomationLayerFrame: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct AutomationLayerSnapshot: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var kind: String
  public var parentID: String?
  public var depth: Int
  public var isEnabled: Bool
  public var isEffectivelyEnabled: Bool
  public var isLocked: Bool
  public var zOrder: Int
  public var blendMode: String
  public var opacity: Double
  public var fill: Double
  public var frame: AutomationLayerFrame?
  public var sourceFilename: String?
  public var supportsDevelop: Bool
  public var adjustmentMaskCount: Int
  public var hasLayerMask: Bool

  public init(
    id: String,
    name: String,
    kind: String,
    parentID: String?,
    depth: Int,
    isEnabled: Bool,
    isEffectivelyEnabled: Bool,
    isLocked: Bool,
    zOrder: Int,
    blendMode: String,
    opacity: Double,
    fill: Double,
    frame: AutomationLayerFrame?,
    sourceFilename: String?,
    supportsDevelop: Bool,
    adjustmentMaskCount: Int,
    hasLayerMask: Bool
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.parentID = parentID
    self.depth = depth
    self.isEnabled = isEnabled
    self.isEffectivelyEnabled = isEffectivelyEnabled
    self.isLocked = isLocked
    self.zOrder = zOrder
    self.blendMode = blendMode
    self.opacity = opacity
    self.fill = fill
    self.frame = frame
    self.sourceFilename = sourceFilename
    self.supportsDevelop = supportsDevelop
    self.adjustmentMaskCount = adjustmentMaskCount
    self.hasLayerMask = hasLayerMask
  }
}

public struct AutomationDevelopSnapshot: Codable, Equatable, Sendable {
  public var documentID: String
  public var layerID: String
  public var contentRevision: UInt64
  public var layerKind: String
  public var rawFloats: [String: Double]
  public var rawBooleans: [String: Bool]
  public var supportedRawFloats: [String]
  public var supportedRawBooleans: [String]
  public var basicTone: [String: Double]

  public init(
    documentID: String,
    layerID: String,
    contentRevision: UInt64,
    layerKind: String,
    rawFloats: [String: Double],
    rawBooleans: [String: Bool],
    supportedRawFloats: [String],
    supportedRawBooleans: [String],
    basicTone: [String: Double]
  ) {
    self.documentID = documentID
    self.layerID = layerID
    self.contentRevision = contentRevision
    self.layerKind = layerKind
    self.rawFloats = rawFloats
    self.rawBooleans = rawBooleans
    self.supportedRawFloats = supportedRawFloats
    self.supportedRawBooleans = supportedRawBooleans
    self.basicTone = basicTone
  }
}

public struct AutomationHistoryItem: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var date: Date
  public var isCurrent: Bool

  public init(id: String, name: String, date: Date, isCurrent: Bool) {
    self.id = id
    self.name = name
    self.date = date
    self.isCurrent = isCurrent
  }
}

public struct AutomationHistorySnapshot: Codable, Equatable, Sendable {
  public var documentID: String
  public var contentRevision: UInt64
  public var canUndo: Bool
  public var canRedo: Bool
  public var steps: [AutomationHistoryItem]
  public var snapshots: [AutomationHistoryItem]

  public init(
    documentID: String,
    contentRevision: UInt64,
    canUndo: Bool,
    canRedo: Bool,
    steps: [AutomationHistoryItem],
    snapshots: [AutomationHistoryItem]
  ) {
    self.documentID = documentID
    self.contentRevision = contentRevision
    self.canUndo = canUndo
    self.canRedo = canRedo
    self.steps = steps
    self.snapshots = snapshots
  }
}

public struct AutomationHistogramSnapshot: Codable, Equatable, Sendable {
  public var documentID: String
  public var contentRevision: UInt64
  public var isAvailable: Bool
  public var isAnalyzing: Bool
  public var sampleCount: Int
  public var red: [Int]
  public var green: [Int]
  public var blue: [Int]
  public var luminance: [Int]
  public var clippedHighlights: Int
  public var clippedShadows: Int

  public init(
    documentID: String,
    contentRevision: UInt64,
    isAvailable: Bool,
    isAnalyzing: Bool,
    sampleCount: Int = 0,
    red: [Int] = [],
    green: [Int] = [],
    blue: [Int] = [],
    luminance: [Int] = [],
    clippedHighlights: Int = 0,
    clippedShadows: Int = 0
  ) {
    self.documentID = documentID
    self.contentRevision = contentRevision
    self.isAvailable = isAvailable
    self.isAnalyzing = isAnalyzing
    self.sampleCount = sampleCount
    self.red = red
    self.green = green
    self.blue = blue
    self.luminance = luminance
    self.clippedHighlights = clippedHighlights
    self.clippedShadows = clippedShadows
  }
}

public struct AutomationJobSnapshot: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var filename: String
  public var presetName: String
  public var summary: String
  public var queuedAt: Date
  public var state: String
  public var progress: Double
  public var message: String
  public var sourceContentRevision: UInt64?

  public init(
    id: String,
    kind: String = "export",
    filename: String,
    presetName: String,
    summary: String,
    queuedAt: Date,
    state: String,
    progress: Double,
    message: String,
    sourceContentRevision: UInt64? = nil
  ) {
    self.id = id
    self.kind = kind
    self.filename = filename
    self.presetName = presetName
    self.summary = summary
    self.queuedAt = queuedAt
    self.state = state
    self.progress = progress
    self.message = message
    self.sourceContentRevision = sourceContentRevision
  }
}

public struct AutomationMutationReceipt: Codable, Equatable, Sendable {
  public var documentID: String
  public var beforeRevision: UInt64
  public var afterRevision: UInt64
  public var historyStepID: String?
  public var createdResourceID: String?
  public var changed: Bool

  public init(
    documentID: String,
    beforeRevision: UInt64,
    afterRevision: UInt64,
    historyStepID: String?,
    createdResourceID: String? = nil,
    changed: Bool
  ) {
    self.documentID = documentID
    self.beforeRevision = beforeRevision
    self.afterRevision = afterRevision
    self.historyStepID = historyStepID
    self.createdResourceID = createdResourceID
    self.changed = changed
  }
}

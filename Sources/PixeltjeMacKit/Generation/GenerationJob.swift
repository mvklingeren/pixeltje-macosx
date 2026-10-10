import Foundation
import PixeltjeMacDomain

struct ComfyUIDebugEvent: Identifiable, Equatable, Sendable {
  var id: UUID
  var timestamp: Date
  var stage: String
  var message: String

  init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    stage: String,
    message: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.stage = stage
    self.message = message
  }

  var transcriptText: String {
    "\(timestamp.ISO8601Format()) [\(stage)]\n\(message)"
  }
}

struct ComfyUIDebugImage: Identifiable, Equatable, Sendable {
  var id: UUID
  var timestamp: Date
  var label: String
  var imageData: Data

  init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    label: String,
    imageData: Data
  ) {
    self.id = id
    self.timestamp = timestamp
    self.label = label
    self.imageData = imageData
  }
}

enum ComfyUIDebugDiskLoggingState: Equatable, Sendable {
  case disabled
  case starting
  case enabled(URL)
  case failed(String)

  var isRequested: Bool {
    switch self {
    case .starting, .enabled: true
    case .disabled, .failed: false
    }
  }

  var directoryURL: URL? {
    guard case .enabled(let url) = self else { return nil }
    return url
  }
}

typealias ComfyUIDebugSink = @MainActor @Sendable (ComfyUIDebugEvent) -> Void

extension ComfyUIExecutionTarget {
  var label: String {
    switch self {
    case .local: "Local"
    case .cloud: "Cloud"
    }
  }
}

public enum GenerationJobState: Equatable, Sendable {
  case queued
  case preparing
  case uploading
  case loadingModel
  case denoising(step: Int, total: Int)
  case finalizing
  case succeeded
  case cancelled
  case failed(String)

  public var isActive: Bool {
    switch self {
    case .queued, .preparing, .uploading, .loadingModel, .denoising, .finalizing: true
    case .succeeded, .cancelled, .failed: false
    }
  }

  public var label: String {
    switch self {
    case .queued: "Queued"
    case .preparing: "Preparing generation"
    case .uploading: "Uploading to ComfyUI"
    case .loadingModel: "Loading model"
    case .denoising(let step, let total): "Denoising \(step) of \(total)"
    case .finalizing: "Finalizing"
    case .succeeded: "Complete"
    case .cancelled: "Cancelled"
    case .failed(let message): message
    }
  }
}

public struct GenerationJob: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var prompt: String
  public var queuedAt: Date
  public var sourceContentRevision: UInt64
  public var state: GenerationJobState
  public var progress: Double
  /// The ComfyUI prompt identifier, once the server has accepted the job.
  public var backendID: String?
  public var executionTarget: ComfyUIExecutionTarget
  public var templateID: String?
  /// A completed result retained after the document revision diverged. The
  /// Prompt Box can explicitly commit it as a new layer on the current recipe.
  public var canApplyAnyway: Bool

  public init(
    id: UUID = UUID(),
    prompt: String,
    queuedAt: Date = Date(),
    sourceContentRevision: UInt64,
    state: GenerationJobState = .queued,
    progress: Double = 0,
    backendID: String? = nil,
    executionTarget: ComfyUIExecutionTarget = .local,
    templateID: String? = nil,
    canApplyAnyway: Bool = false
  ) {
    self.id = id
    self.prompt = prompt
    self.queuedAt = queuedAt
    self.sourceContentRevision = sourceContentRevision
    self.state = state
    self.progress = min(max(progress, 0), 1)
    self.backendID = backendID
    self.executionTarget = executionTarget
    self.templateID = templateID
    self.canApplyAnyway = canApplyAnyway
  }
}

public enum ComfyUIConnectionState: Equatable, Sendable {
  case checking
  case connected
  case disconnected(String?)

  public var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }

  public var label: String {
    switch self {
    case .checking: "Checking…"
    case .connected: "Connected"
    case .disconnected: "Disconnected"
    }
  }
}

public struct ComfyUIWorkflowTemplate: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var mode: GenerationMode
  public var isBuiltIn: Bool

  public init(id: String, name: String, mode: GenerationMode, isBuiltIn: Bool = true) {
    self.id = id
    self.name = name
    self.mode = mode
    self.isBuiltIn = isBuiltIn
  }
}

public struct InpaintingToolState: Codable, Equatable, Sendable {
  /// Pixel dimensions of the generated raster layer. This is deliberately
  /// independent of the document canvas extent.
  public var outputSize = CanvasRecipe(width: 1024, height: 1024)
  public var negativePrompt = ""
  public var strength = 0.85
  public var maskBlur = 0.0
  public var steps = 8
  public var guidance = 1.0
  public var seed: UInt64 = 1
  public var randomizeSeed = true
  public var transparentPixelBackground: GenerationBackground = .white
  /// Sends a slightly larger mask to ComfyUI so its latent boundary lies
  /// outside the original mask that clips the returned generated layer.
  public var expandMaskForComfyUI = true

  public init() {}

  private enum CodingKeys: String, CodingKey {
    case outputSize, negativePrompt, strength, maskBlur, steps, guidance
    case seed, randomizeSeed, transparentPixelBackground, expandMaskForComfyUI
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    outputSize = try values.decode(CanvasRecipe.self, forKey: .outputSize)
    negativePrompt = try values.decode(String.self, forKey: .negativePrompt)
    strength = try values.decode(Double.self, forKey: .strength)
    maskBlur = try values.decode(Double.self, forKey: .maskBlur)
    steps = try values.decode(Int.self, forKey: .steps)
    guidance = try values.decode(Double.self, forKey: .guidance)
    seed = try values.decode(UInt64.self, forKey: .seed)
    randomizeSeed = try values.decode(Bool.self, forKey: .randomizeSeed)
    transparentPixelBackground = try values.decode(
      GenerationBackground.self, forKey: .transparentPixelBackground)
    expandMaskForComfyUI = try values.decodeIfPresent(
      Bool.self, forKey: .expandMaskForComfyUI) ?? true
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(outputSize, forKey: .outputSize)
    try values.encode(negativePrompt, forKey: .negativePrompt)
    try values.encode(strength, forKey: .strength)
    try values.encode(maskBlur, forKey: .maskBlur)
    try values.encode(steps, forKey: .steps)
    try values.encode(guidance, forKey: .guidance)
    try values.encode(seed, forKey: .seed)
    try values.encode(randomizeSeed, forKey: .randomizeSeed)
    try values.encode(transparentPixelBackground, forKey: .transparentPixelBackground)
    try values.encode(expandMaskForComfyUI, forKey: .expandMaskForComfyUI)
  }

  public var clamped: InpaintingToolState {
    var copy = self
    if !copy.outputSize.isResolved {
      copy.outputSize = CanvasRecipe(width: 1024, height: 1024)
    }
    copy.strength = min(max(copy.strength, 0), 1)
    copy.maskBlur = min(max(copy.maskBlur, 0), 250)
    copy.steps = min(max(copy.steps, 1), 20)
    copy.guidance = min(max(copy.guidance, 0), 20)
    return copy
  }
}

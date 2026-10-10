import AppKit
import Foundation
import PixeltjeAutomation
import PixeltjeMacDomain

/// Adapts live `NSDocument` state to the protocol-neutral automation surface.
///
/// All calls stay on the main actor because `NSDocument`, `UndoManager`, and
/// the observable editor model are main-actor state. Heavy rendering remains
/// owned by `RenderEngine` exactly as it is for UI-originated actions.
@MainActor
public final class ProjectAutomationController: PixeltjeAutomationService {
  public typealias DocumentsProvider = @MainActor () -> [ProjectDocument]

  private struct CachedMutation {
    var fingerprint: Data
    var receipt: AutomationMutationReceipt
  }

  private let documentsProvider: DocumentsProvider
  private var cachedMutations: [String: CachedMutation] = [:]
  private var cachedMutationOrder: [String] = []
  private let maximumCachedMutations = 256

  public init(
    documentsProvider: @escaping DocumentsProvider = {
      NSDocumentController.shared.documents.compactMap { $0 as? ProjectDocument }
    }
  ) {
    self.documentsProvider = documentsProvider
  }

  public func listDocuments(
    context: AutomationRequestContext
  ) throws -> [AutomationDocumentSummary] {
    try context.require(.read)
    return documentsProvider().map(summary)
  }

  public func getDocument(
    id: String,
    context: AutomationRequestContext
  ) throws -> AutomationDocumentSnapshot {
    try context.require(.read)
    let document = try document(id)
    let recipe = document.editorModel.recipe
    return AutomationDocumentSnapshot(
      document: summary(document),
      activeLayerID: recipe.layerStack.activeLayerID?.rawValue,
      layerCount: recipe.layerStack.flattenedLayers.count,
      hasSelection: recipe.hasSelection,
      workingColorSpace: "Extended Linear Display P3",
      render: renderSnapshot(document.editorModel.renderStatus)
    )
  }

  public func listLayers(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> [AutomationLayerSnapshot] {
    try context.require(.read)
    return try document(documentID).editorModel.recipe.layerStack.flattenedLayers.map {
      entry in
      let layer = entry.layer
      return AutomationLayerSnapshot(
        id: layer.id.rawValue,
        name: layer.name,
        kind: kind(of: layer.content),
        parentID: entry.parentID?.rawValue,
        depth: entry.depth,
        isEnabled: layer.isEnabled,
        isEffectivelyEnabled: entry.isEffectivelyEnabled,
        isLocked: layer.isLocked,
        zOrder: layer.zOrder,
        blendMode: layer.blendMode.rawValue,
        opacity: layer.opacity,
        fill: layer.fill,
        frame: frame(of: layer.content).map(automationFrame),
        sourceFilename: sourceFilename(of: layer.content),
        supportsDevelop: layer.supportsAdjustments,
        adjustmentMaskCount: layer.masks.count,
        hasLayerMask: layer.layerMask != nil
      )
    }
  }

  public func getDevelopSettings(
    documentID: String,
    layerID: String,
    context: AutomationRequestContext
  ) throws -> AutomationDevelopSnapshot {
    try context.require(.read)
    let document = try document(documentID)
    let layer = try layer(layerID, in: document)
    guard layer.supportsAdjustments else {
      throw AutomationServiceError(
        .unsupportedOperation,
        "The \(kind(of: layer.content)) layer does not support develop adjustments."
      )
    }

    var rawFloats: [String: Double] = [:]
    var rawBooleans: [String: Bool] = [:]
    var supportedRawFloats: [String] = []
    var supportedRawBooleans: [String] = []
    if let raw = layer.developedRawLayer,
      let parameters = raw.rawDevelopment.parameters
    {
      for parameter in RawFloatParameter.allCases {
        rawFloats[parameter.rawValue] = parameters[parameter]
        if raw.rawDevelopment.capabilities?.supports(parameter) != false {
          supportedRawFloats.append(parameter.rawValue)
        }
      }
      for parameter in RawBoolParameter.allCases {
        rawBooleans[parameter.rawValue] = parameters[parameter]
        if raw.rawDevelopment.capabilities?.supports(parameter) != false {
          supportedRawBooleans.append(parameter.rawValue)
        }
      }
    }
    var tone: [String: Double] = [:]
    for control in BasicToneRecipe.Control.allCases {
      tone[control.rawValue] = layer.adjustments.basicTone[control]
    }
    return AutomationDevelopSnapshot(
      documentID: document.projectID.uuidString,
      layerID: layer.id.rawValue,
      contentRevision: document.automationContentRevision,
      layerKind: kind(of: layer.content),
      rawFloats: rawFloats,
      rawBooleans: rawBooleans,
      supportedRawFloats: supportedRawFloats.sorted(),
      supportedRawBooleans: supportedRawBooleans.sorted(),
      basicTone: tone
    )
  }

  public func getHistory(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> AutomationHistorySnapshot {
    try context.require(.read)
    let document = try document(documentID)
    let history = document.editorModel.history
    return AutomationHistorySnapshot(
      documentID: document.projectID.uuidString,
      contentRevision: document.automationContentRevision,
      canUndo: history.canUndo,
      canRedo: history.canRedo,
      steps: history.steps.map {
        AutomationHistoryItem(
          id: $0.id.rawValue,
          name: $0.name,
          date: $0.date,
          isCurrent: $0.id == history.currentStepID
        )
      },
      snapshots: history.snapshots.map {
        AutomationHistoryItem(
          id: $0.id.rawValue,
          name: $0.name,
          date: $0.date,
          isCurrent: false
        )
      }
    )
  }

  public func getHistogram(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> AutomationHistogramSnapshot {
    try context.require(.read)
    let document = try document(documentID)
    guard let histogram = document.editorModel.histogram else {
      return AutomationHistogramSnapshot(
        documentID: document.projectID.uuidString,
        contentRevision: document.automationContentRevision,
        isAvailable: false,
        isAnalyzing: document.editorModel.isAnalyzingRenderedFrame
      )
    }
    return AutomationHistogramSnapshot(
      documentID: document.projectID.uuidString,
      contentRevision: document.automationContentRevision,
      isAvailable: true,
      isAnalyzing: document.editorModel.isAnalyzingRenderedFrame,
      sampleCount: histogram.sampleCount,
      red: histogram.red,
      green: histogram.green,
      blue: histogram.blue,
      luminance: histogram.luminance,
      clippedHighlights: histogram.clippedHighlights,
      clippedShadows: histogram.clippedShadows
    )
  }

  public func listJobs(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> [AutomationJobSnapshot] {
    try context.require(.read)
    let document = try document(documentID)
    let exports = document.editorModel.exportJobs.map { job in
      AutomationJobSnapshot(
        id: job.id.uuidString,
        filename: job.filename,
        presetName: job.presetName,
        summary: job.summary,
        queuedAt: job.queuedAt,
        state: jobState(job.state),
        progress: job.progress,
        message: job.statusText
      )
    }
    let generations = document.editorModel.generationJobs.map { job in
      AutomationJobSnapshot(
        id: job.id.uuidString,
        kind: "inpainting",
        filename: "",
        presetName: "Z-Image Turbo",
        summary: job.prompt,
        queuedAt: job.queuedAt,
        state: generationJobState(job.state),
        progress: job.progress,
        message: job.state.label,
        sourceContentRevision: job.sourceContentRevision)
    }
    return (exports + generations).sorted { $0.queuedAt < $1.queuedAt }
  }

  public func execute(
    _ command: AutomationCommand,
    context: AutomationRequestContext
  ) throws -> AutomationMutationReceipt {
    guard !command.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AutomationServiceError(.invalidArgument, "idempotencyKey must not be empty.")
    }
    let cacheKey = "\(context.clientID):\(command.idempotencyKey)"
    let fingerprint = try fingerprint(command)
    if let cached = cachedMutations[cacheKey] {
      guard cached.fingerprint == fingerprint else {
        throw AutomationServiceError(
          .invalidArgument,
          "The idempotency key was already used for a different command."
        )
      }
      return cached.receipt
    }

    let receipt: AutomationMutationReceipt
    switch command {
    case .updateDevelop(let patch):
      try context.require(.edit)
      receipt = try updateDevelop(patch)
    case .updateLayer(let patch):
      try context.require(.edit)
      receipt = try updateLayer(patch)
    case .moveLayer(let move):
      try context.require(.edit)
      receipt = try moveLayer(move)
    case .setCrop(let crop):
      try context.require(.edit)
      receipt = try setCrop(crop)
    case .resizeCanvas(let resize):
      try context.require(.edit)
      receipt = try resizeCanvas(resize)
    case .createSnapshot(let create):
      try context.require(.edit)
      receipt = try createSnapshot(create)
    case .restoreSnapshot(let restore):
      try context.require(.edit)
      receipt = try restoreSnapshot(restore)
    case .cancelJob(let cancel):
      try context.require(.jobs)
      receipt = try cancelJob(cancel)
    case .startInpainting(let start):
      try context.require(.edit)
      try context.require(.jobs)
      receipt = try startInpainting(start)
    }
    cache(receipt, fingerprint: fingerprint, for: cacheKey)
    return receipt
  }

  // MARK: - Mutations

  private func updateDevelop(
    _ patch: AutomationDevelopPatch
  ) throws -> AutomationMutationReceipt {
    let document = try document(patch.documentID)
    let target = try layer(patch.layerID, in: document)
    guard target.supportsAdjustments else {
      throw AutomationServiceError(
        .unsupportedOperation,
        "The target layer does not support develop adjustments."
      )
    }

    var actions: [EditorAction] = []
    if !patch.rawFloats.isEmpty || !patch.rawBooleans.isEmpty {
      guard let raw = target.developedRawLayer,
        raw.rawDevelopment.parameters != nil
      else {
        throw AutomationServiceError(
          .unsupportedOperation,
          "Apple RAW settings can only be changed on an initialized developed RAW layer."
        )
      }
      for (name, value) in patch.rawFloats.sorted(by: { $0.key < $1.key }) {
        guard let parameter = RawFloatParameter(rawValue: name) else {
          throw AutomationServiceError(.invalidArgument, "Unknown RAW float parameter: \(name).")
        }
        guard raw.rawDevelopment.capabilities?.supports(parameter) != false else {
          throw AutomationServiceError(
            .unsupportedOperation,
            "The selected Apple RAW decoder does not support \(name)."
          )
        }
        try validateRaw(value, for: parameter)
        actions.append(.setRawLayerFloat(target.id, parameter, value))
      }
      for (name, value) in patch.rawBooleans.sorted(by: { $0.key < $1.key }) {
        guard let parameter = RawBoolParameter(rawValue: name) else {
          throw AutomationServiceError(.invalidArgument, "Unknown RAW boolean parameter: \(name).")
        }
        guard raw.rawDevelopment.capabilities?.supports(parameter) != false else {
          throw AutomationServiceError(
            .unsupportedOperation,
            "The selected Apple RAW decoder does not support \(name)."
          )
        }
        actions.append(.setRawLayerBool(target.id, parameter, value))
      }
    }

    var adjustments = target.adjustments
    var changedTone = false
    for (name, value) in patch.basicTone.sorted(by: { $0.key < $1.key }) {
      guard let control = BasicToneRecipe.Control(rawValue: name) else {
        throw AutomationServiceError(.invalidArgument, "Unknown basic tone control: \(name).")
      }
      let range: ClosedRange<Double> = control == .exposure ? -5...5 : -100...100
      try validate(value, in: range, name: name)
      if control == .exposure, target.isDevelopedRaw {
        guard target.developedRawLayer?.rawDevelopment.parameters != nil else {
          throw AutomationServiceError(
            .unsupportedOperation,
            "RAW exposure is unavailable until Apple RAW initialization completes."
          )
        }
        actions.append(.setRawLayerFloat(target.id, .exposure, value))
      } else {
        adjustments.basicTone[control] = value
        changedTone = true
      }
    }
    if changedTone {
      actions.append(
        .setLayerAdjustments(target.id, adjustments, actionName: "Automation: Develop")
      )
    }
    return try document.performAutomationActions(
      actions,
      expectedRevision: patch.expectedRevision,
      actionName: "Automation: Develop"
    )
  }

  private func updateLayer(
    _ patch: AutomationLayerPatch
  ) throws -> AutomationMutationReceipt {
    let document = try document(patch.documentID)
    let target = try layer(patch.layerID, in: document)
    guard !target.isCanvasLayer else {
      throw AutomationServiceError(.unsupportedOperation, "The canvas layer is structural.")
    }
    var actions: [EditorAction] = []
    if let enabled = patch.isEnabled { actions.append(.setLayerEnabled(target.id, enabled)) }
    if let name = patch.blendMode {
      guard let mode = LayerBlendMode(rawValue: name) else {
        throw AutomationServiceError(
          .invalidArgument,
          "Unknown blend mode: \(name).",
          details: ["allowed": LayerBlendMode.allCases.map(\.rawValue).joined(separator: ",")]
        )
      }
      actions.append(.setLayerBlendMode(target.id, mode))
    }
    if let opacity = patch.opacity {
      try validate(opacity, in: 0...1, name: "opacity")
      actions.append(.setLayerOpacity(target.id, opacity))
    }
    if let fill = patch.fill {
      try validate(fill, in: 0...1, name: "fill")
      actions.append(.setLayerFill(target.id, fill))
    }
    return try document.performAutomationActions(
      actions,
      expectedRevision: patch.expectedRevision,
      actionName: "Automation: Layer Properties"
    )
  }

  private func moveLayer(
    _ command: AutomationMoveLayerCommand
  ) throws -> AutomationMutationReceipt {
    let document = try document(command.documentID)
    let target = try layer(command.layerID, in: document)
    guard !target.isCanvasLayer else {
      throw AutomationServiceError(.unsupportedOperation, "The canvas layer cannot be moved.")
    }
    let direction: LayerMoveDirection = command.direction == .up ? .up : .down
    return try document.performAutomationActions(
      [.moveLayer(target.id, direction)],
      expectedRevision: command.expectedRevision,
      actionName: command.direction == .up
        ? "Automation: Move Layer Up" : "Automation: Move Layer Down"
    )
  }

  private func setCrop(
    _ command: AutomationCropCommand
  ) throws -> AutomationMutationReceipt {
    let values = [command.left, command.bottom, command.right, command.top, command.angleDegrees]
    guard values.allSatisfy(\.isFinite) else {
      throw AutomationServiceError(.invalidArgument, "Crop values must be finite numbers.")
    }
    guard command.left >= 0, command.bottom >= 0, command.right <= 1, command.top <= 1,
      command.right - command.left >= CropRecipe.minimumUnitSize,
      command.top - command.bottom >= CropRecipe.minimumUnitSize,
      abs(command.angleDegrees) <= CropRecipe.maximumAngleDegrees
    else {
      throw AutomationServiceError(
        .invalidArgument,
        "Crop edges must form a non-empty unit rectangle and angleDegrees must be between -45 and 45."
      )
    }
    let document = try document(command.documentID)
    let hasRawCanvas =
      document.editorModel.recipe.layerStack.layer(id: .rawBackground)?.isDevelopedRaw == true
    if !hasRawCanvas, command.angleDegrees != 0 {
      throw AutomationServiceError(
        .unsupportedOperation,
        "Canvas straighten requires a base RAW document. Crop a selected pixel layer in the editor instead."
      )
    }
    let current = document.editorModel.recipe.crop
    let crop = CropRecipe(
      left: command.left,
      bottom: command.bottom,
      right: command.right,
      top: command.top,
      angleDegrees: command.angleDegrees,
      aspectRatio: current.aspectRatio,
      overlay: current.overlay
    )
    let action: EditorAction =
      hasRawCanvas
      ? .setCrop(crop, actionName: "Automation: Crop")
      : .cropCanvas(crop, actionName: "Automation: Crop")
    return try document.performAutomationActions(
      [action],
      expectedRevision: command.expectedRevision,
      actionName: "Automation: Crop"
    )
  }

  private func resizeCanvas(
    _ command: AutomationResizeCanvasCommand
  ) throws -> AutomationMutationReceipt {
    guard (1...32_768).contains(command.width), (1...32_768).contains(command.height) else {
      throw AutomationServiceError(
        .invalidArgument,
        "Canvas width and height must each be between 1 and 32768 pixels."
      )
    }
    guard let anchor = CanvasAnchor(rawValue: command.anchor) else {
      throw AutomationServiceError(
        .invalidArgument,
        "Unknown canvas anchor: \(command.anchor).",
        details: ["allowed": CanvasAnchor.allCases.map(\.rawValue).joined(separator: ",")]
      )
    }
    let document = try document(command.documentID)
    return try document.performAutomationActions(
      [.resizeCanvas(CanvasRecipe(width: command.width, height: command.height), anchor: anchor)],
      expectedRevision: command.expectedRevision,
      actionName: "Automation: Resize Canvas"
    )
  }

  private func createSnapshot(
    _ command: AutomationCreateSnapshotCommand
  ) throws -> AutomationMutationReceipt {
    let document = try document(command.documentID)
    try validateMutationState(document, expectedRevision: command.expectedRevision)
    if let name = command.name {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed.count <= 200 else {
        throw AutomationServiceError(
          .invalidArgument,
          "Snapshot name must contain 1 to 200 characters."
        )
      }
    }
    let before = document.automationContentRevision
    let id = document.takeSnapshot(
      named: command.name?.trimmingCharacters(in: .whitespacesAndNewlines))
    return AutomationMutationReceipt(
      documentID: document.projectID.uuidString,
      beforeRevision: before,
      afterRevision: before,
      historyStepID: document.editorModel.history.currentStepID.rawValue,
      createdResourceID: id.rawValue,
      changed: true
    )
  }

  private func restoreSnapshot(
    _ command: AutomationRestoreSnapshotCommand
  ) throws -> AutomationMutationReceipt {
    let document = try document(command.documentID)
    try validateMutationState(document, expectedRevision: command.expectedRevision)
    let snapshotID = HistorySnapshotID(rawValue: command.snapshotID)
    guard document.editorModel.history.snapshot(snapshotID) != nil else {
      throw AutomationServiceError(.snapshotNotFound, "No snapshot has ID \(command.snapshotID).")
    }
    let before = document.automationContentRevision
    document.restoreSnapshot(snapshotID)
    return AutomationMutationReceipt(
      documentID: document.projectID.uuidString,
      beforeRevision: before,
      afterRevision: document.automationContentRevision,
      historyStepID: document.editorModel.history.currentStepID.rawValue,
      changed: document.automationContentRevision != before
    )
  }

  private func cancelJob(
    _ command: AutomationCancelJobCommand
  ) throws -> AutomationMutationReceipt {
    let document = try document(command.documentID)
    guard let id = UUID(uuidString: command.jobID) else {
      throw AutomationServiceError(.jobNotFound, "No export job has ID \(command.jobID).")
    }
    let wasActive: Bool
    if let generation = document.editorModel.generationJobs.first(where: { $0.id == id }) {
      wasActive = generation.state.isActive
      if wasActive { _ = document.cancelGeneration(id) }
    } else if let job = document.editorModel.exportJobs.first(where: { $0.id == id }) {
      wasActive = job.state.isActive
      if wasActive { document.cancelExport(id) }
    } else {
      throw AutomationServiceError(.jobNotFound, "No job has ID \(command.jobID).")
    }
    return AutomationMutationReceipt(
      documentID: document.projectID.uuidString,
      beforeRevision: document.automationContentRevision,
      afterRevision: document.automationContentRevision,
      historyStepID: document.editorModel.history.currentStepID.rawValue,
      changed: wasActive
    )
  }

  private func startInpainting(
    _ command: AutomationStartInpaintingCommand
  ) throws -> AutomationMutationReceipt {
    let document = try document(command.documentID)
    try validateMutationState(document, expectedRevision: command.expectedRevision)
    guard (0...1).contains(command.strength), command.maskBlur >= 0,
      (1...20).contains(command.steps), command.guidance >= 0
    else {
      throw AutomationServiceError(
        .invalidArgument,
        "strength must be 0...1, maskBlur and guidance non-negative, and steps 1...20.")
    }
    var settings = InpaintingToolState()
    // The automation contract does not expose an output-size field yet. Keep
    // its established full-canvas behavior while the prompt box is free to
    // choose an independent generated-layer size.
    settings.outputSize = document.editorModel.recipe.layerStack.canvas
    settings.strength = command.strength
    settings.maskBlur = command.maskBlur
    settings.steps = command.steps
    settings.guidance = command.guidance
    settings.seed = command.seed
    let id = try document.startInpainting(
      prompt: command.prompt,
      negativePrompt: command.negativePrompt,
      settings: settings,
      maskSource: command.maskSource,
      expectedRevision: command.expectedRevision)
    return AutomationMutationReceipt(
      documentID: document.projectID.uuidString,
      beforeRevision: document.automationContentRevision,
      afterRevision: document.automationContentRevision,
      historyStepID: document.editorModel.history.currentStepID.rawValue,
      createdResourceID: id.uuidString,
      changed: true)
  }

  // MARK: - Validation and mapping

  private func document(_ id: String) throws -> ProjectDocument {
    guard let requested = UUID(uuidString: id),
      let document = documentsProvider().first(where: { $0.projectID == requested })
    else {
      throw AutomationServiceError(.documentNotFound, "No open document has ID \(id).")
    }
    return document
  }

  private func layer(_ id: String, in document: ProjectDocument) throws -> ProjectLayer {
    guard let layer = document.editorModel.recipe.layerStack.layer(id: ProjectLayerID(rawValue: id))
    else {
      throw AutomationServiceError(.layerNotFound, "No layer has ID \(id).")
    }
    return layer
  }

  private func validateMutationState(
    _ document: ProjectDocument,
    expectedRevision: UInt64
  ) throws {
    guard document.automationContentRevision == expectedRevision else {
      throw AutomationServiceError(
        .staleRevision,
        "The document changed after the automation client read it.",
        details: [
          "expectedRevision": String(expectedRevision),
          "currentRevision": String(document.automationContentRevision),
        ]
      )
    }
    guard !document.isBusyForAutomation else {
      throw AutomationServiceError(
        .documentBusy,
        "The document has an in-progress interactive edit. Retry after it finishes."
      )
    }
  }

  private func validateRaw(_ value: Double, for parameter: RawFloatParameter) throws {
    let range: ClosedRange<Double>
    switch parameter {
    case .exposure: range = -5...5
    case .baselineExposure:
      throw AutomationServiceError(
        .unsupportedOperation,
        "baselineExposure is captured decoder state and is not a user-facing Pixeltje control."
      )
    case .shadowBias: range = -1...1
    case .boostAmount: range = 0...1
    case .boostShadowAmount: range = 0...2
    case .luminanceNoiseReduction, .colorNoiseReduction, .sharpness, .contrast,
      .moireReduction, .despeckle, .localToneMap:
      range = 0...1
    case .detail: range = 0...3
    case .extendedDynamicRange: range = 0...2
    case .neutralTemperature: range = 2_000...50_000
    case .neutralTint: range = -150...150
    }
    try validate(value, in: range, name: parameter.rawValue)
  }

  private func validate(
    _ value: Double,
    in range: ClosedRange<Double>,
    name: String
  ) throws {
    guard value.isFinite, range.contains(value) else {
      throw AutomationServiceError(
        .invalidArgument,
        "\(name) must be between \(range.lowerBound) and \(range.upperBound)."
      )
    }
  }

  private func fingerprint(_ command: AutomationCommand) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(command)
  }

  private func cache(
    _ receipt: AutomationMutationReceipt,
    fingerprint: Data,
    for key: String
  ) {
    cachedMutations[key] = CachedMutation(fingerprint: fingerprint, receipt: receipt)
    cachedMutationOrder.append(key)
    if cachedMutationOrder.count > maximumCachedMutations {
      let expired = cachedMutationOrder.removeFirst()
      cachedMutations.removeValue(forKey: expired)
    }
  }

  private func summary(_ document: ProjectDocument) -> AutomationDocumentSummary {
    let canvas = document.editorModel.recipe.layerStack.canvas
    return AutomationDocumentSummary(
      id: document.projectID.uuidString,
      name: document.displayName.isEmpty ? "Untitled" : document.displayName,
      isEdited: document.isDocumentEdited,
      contentRevision: document.automationContentRevision,
      canvas: AutomationCanvasSnapshot(width: canvas.width, height: canvas.height)
    )
  }

  private func renderSnapshot(_ status: RenderStatus) -> AutomationRenderSnapshot {
    let state: String
    switch status {
    case .idle: state = "idle"
    case .preparing: state = "preparing"
    case .ready: state = "ready"
    case .exporting: state = "exporting"
    case .failed: state = "failed"
    }
    return AutomationRenderSnapshot(state: state, message: status.message, isBusy: status.isBusy)
  }

  private func kind(of content: ProjectLayerContent) -> String {
    switch content {
    case .developedRaw: "developedRaw"
    case .image: "image"
    case .raster: "raster"
    case .generatedInpaint: "generatedInpaint"
    case .paint: "paint"
    case .vector: "vector"
    case .canvas: "canvas"
    case .text: "text"
    case .group: "group"
    case .adjustment: "adjustment"
    }
  }

  private func frame(of content: ProjectLayerContent) -> LayerFrame? {
    switch content {
    case .developedRaw(let raw): raw.frame
    case .image(let image): image.frame
    case .raster(let raster): raster.frame
    case .generatedInpaint(let inpaint): inpaint.frame
    case .text(let text): text.frame
    case .paint, .vector, .canvas, .group, .adjustment: nil
    }
  }

  private func sourceFilename(of content: ProjectLayerContent) -> String? {
    switch content {
    case .developedRaw(let raw): raw.source?.originalFilename
    case .image(let image): image.source.originalFilename
    case .raster, .generatedInpaint, .paint, .vector, .canvas, .text, .group, .adjustment: nil
    }
  }

  private func automationFrame(_ frame: LayerFrame) -> AutomationLayerFrame {
    AutomationLayerFrame(
      x: frame.x,
      y: frame.y,
      width: frame.width,
      height: frame.height
    )
  }

  private func jobState(_ state: ExportJob.State) -> String {
    switch state {
    case .waiting: "waiting"
    case .running: "running"
    case .finished: "finished"
    case .failed: "failed"
    case .cancelled: "cancelled"
    }
  }

  private func generationJobState(_ state: GenerationJobState) -> String {
    switch state {
    case .queued: "waiting"
    case .preparing: "preparing"
    case .uploading: "uploading"
    case .loadingModel: "loadingModel"
    case .denoising: "running"
    case .finalizing: "finalizing"
    case .succeeded: "finished"
    case .failed: "failed"
    case .cancelled: "cancelled"
    }
  }
}

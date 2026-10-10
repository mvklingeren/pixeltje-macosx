import AppKit
import Combine
import PixeltjeMacDomain
import SwiftUI

struct GenerationSizePreset: Identifiable, Equatable, Sendable {
  let outputSize: CanvasRecipe

  var id: String { "\(outputSize.width)x\(outputSize.height)" }
  var label: String { "\(outputSize.width) × \(outputSize.height)" }

  static let compatible: [GenerationSizePreset] = [
    GenerationSizePreset(outputSize: CanvasRecipe(width: 512, height: 512)),
    GenerationSizePreset(outputSize: CanvasRecipe(width: 768, height: 768)),
    GenerationSizePreset(outputSize: CanvasRecipe(width: 1024, height: 1024)),
  ]
}

extension GenerationBackground {
  var label: String {
    switch self {
    case .white: "White"
    case .gray: "Gray"
    case .black: "Black"
    }
  }
}

/// Presentation state for the canvas prompt box.
///
/// The model intentionally owns only the draft and what the surface displays.
/// Validation, Core AI work, revision checks, cancellation, and recipe mutation
/// stay behind the callbacks supplied by the document window controller.
@MainActor
final class PromptBoxModel: ObservableObject {
  @Published var prompt = "" {
    didSet {
      promptDrafts[generationMode] = prompt
      if activeJob == nil {
        validationMessage = nil
        terminalJobMessage = nil
        terminalFailure = nil
        isFailureExpanded = false
      }
    }
  }
  @Published private(set) var activeJob: GenerationJob?
  @Published private(set) var validationMessage: String?
  @Published private(set) var terminalJobMessage: String?
  @Published private(set) var terminalFailure: PromptBoxFailure?
  @Published private(set) var isFailureExpanded = false
  @Published private(set) var focusRequest = 0
  @Published private(set) var generationSettings: InpaintingToolState
  @Published private(set) var generationMode: GenerationMode
  @Published private(set) var generationMaskSourcePresentation:
    GenerationMaskSourcePresentation
  @Published private(set) var generationMaskSourceOptions: [GenerationMaskSourceOption]
  @Published private(set) var contentTags: [ImageContentTag] = []
  @Published private(set) var selectionPreview: MaskRecipe?
  @Published private(set) var isDetailsExpanded = false
  @Published private(set) var comfyUIDebugEvents: [ComfyUIDebugEvent] = []
  @Published private(set) var comfyUIDebugImages: [ComfyUIDebugImage] = []
  @Published private(set) var comfyUIDebugDiskLoggingState: ComfyUIDebugDiskLoggingState
  @Published private(set) var executionTarget: ComfyUIExecutionTarget = .local
  @Published private(set) var hasComfyCloudAPIKey = false

  var onMove: (CGPoint) -> Void = { _ in }
  var onResize: (CGSize) -> Void = { _ in }
  var onClose: () -> Void = {}
  var onSubmit: (String) -> Void
  var onCancelGeneration: () -> Void
  var onUpdateGenerationSettings: (InpaintingToolState) -> Void
  var onClearComfyUIDebugEvents: () -> Void
  var onSetComfyUIDebugDiskLoggingEnabled: (Bool) -> Void
  var onRevealComfyUIDebugLog: () -> Void
  var onApplyComfyUIResultAnyway: (UUID) -> Void
  var onSelectGenerationMode: (GenerationMode) -> Void
  var onSelectGenerationMaskSource: (GenerationMaskSourceChoice) -> Void
  var onSelectExecutionTarget: (ComfyUIExecutionTarget) -> Void
  var onSelectTag: (String) -> Void
  var onApplySelectionPreview: () -> Void
  var onDiscardSelectionPreview: () -> Void
  private let onPromptRequired: () -> Void
  private var promptDrafts: [GenerationMode: String] = [:]

  var hasUnsubmittedPrompt: Bool {
    promptDrafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  init(
    generationSettings: InpaintingToolState = InpaintingToolState(),
    generationMode: GenerationMode = .textToImage,
    comfyUIDebugDiskLoggingState: ComfyUIDebugDiskLoggingState = .disabled,
    generationMaskSourcePresentation: GenerationMaskSourcePresentation =
      GenerationMaskSourcePresentation(
        requested: .automatic,
        requestedLabel: "Automatic",
        resolved: .transparentPixels,
        resolvedLabel: "Transparent Pixels",
        unavailableReason: nil),
    generationMaskSourceOptions: [GenerationMaskSourceOption] = [
      GenerationMaskSourceOption(
        source: .automatic,
        label: "Automatic",
        isAvailable: true,
        unavailableReason: nil),
      GenerationMaskSourceOption(
        source: .transparentPixels,
        label: "Transparent Pixels",
        isAvailable: true,
        unavailableReason: nil),
      GenerationMaskSourceOption(
        source: .entireOutput,
        label: "Entire Output",
        isAvailable: true,
        unavailableReason: nil),
    ],
    onSubmit: @escaping (String) -> Void = { _ in },
    onCancelGeneration: @escaping () -> Void = {},
    onUpdateGenerationSettings: @escaping (InpaintingToolState) -> Void = { _ in },
    onClearComfyUIDebugEvents: @escaping () -> Void = {},
    onSetComfyUIDebugDiskLoggingEnabled: @escaping (Bool) -> Void = { _ in },
    onRevealComfyUIDebugLog: @escaping () -> Void = {},
    onApplyComfyUIResultAnyway: @escaping (UUID) -> Void = { _ in },
    onSelectGenerationMode: @escaping (GenerationMode) -> Void = { _ in },
    onSelectGenerationMaskSource: @escaping (GenerationMaskSourceChoice) -> Void = { _ in },
    onSelectExecutionTarget: @escaping (ComfyUIExecutionTarget) -> Void = { _ in },
    onSelectTag: @escaping (String) -> Void = { _ in },
    onApplySelectionPreview: @escaping () -> Void = {},
    onDiscardSelectionPreview: @escaping () -> Void = {},
    onPromptRequired: @escaping () -> Void = { NSSound.beep() }
  ) {
    self.generationSettings = generationSettings
    self.generationMode = generationMode
    self.comfyUIDebugDiskLoggingState = comfyUIDebugDiskLoggingState
    self.generationMaskSourcePresentation = generationMaskSourcePresentation
    self.generationMaskSourceOptions = generationMaskSourceOptions
    self.onSubmit = onSubmit
    self.onCancelGeneration = onCancelGeneration
    self.onUpdateGenerationSettings = onUpdateGenerationSettings
    self.onClearComfyUIDebugEvents = onClearComfyUIDebugEvents
    self.onSetComfyUIDebugDiskLoggingEnabled = onSetComfyUIDebugDiskLoggingEnabled
    self.onRevealComfyUIDebugLog = onRevealComfyUIDebugLog
    self.onApplyComfyUIResultAnyway = onApplyComfyUIResultAnyway
    self.onSelectGenerationMode = onSelectGenerationMode
    self.onSelectGenerationMaskSource = onSelectGenerationMaskSource
    self.onSelectExecutionTarget = onSelectExecutionTarget
    self.onSelectTag = onSelectTag
    self.onApplySelectionPreview = onApplySelectionPreview
    self.onDiscardSelectionPreview = onDiscardSelectionPreview
    self.onPromptRequired = onPromptRequired
  }

  var statusText: String? {
    if selectionPreview != nil { return "Selection ready to review" }
    return activeJob?.state.label ?? validationMessage
      ?? (terminalFailure == nil ? terminalJobMessage : "Workflow failed")
  }

  var progress: Double? {
    activeJob?.progress
  }

  var primaryActionTitle: String {
    activeJob == nil ? "Execute" : "Stop"
  }

  var primaryActionSymbol: String {
    activeJob == nil ? "sparkles" : "stop.fill"
  }

  var primaryActionHelp: String {
    guard activeJob == nil else { return "Cancel the active generation job." }
    switch generationMode {
    case .textToImage:
      return "Generate a new raster layer from the prompt and seeded noise."
    case .imageToImage:
      return "Edit the current composite without a selection mask. Choose an Inpaint workflow to use the selection mask."
    case .inpainting:
      if let unavailableReason = generationMaskSourcePresentation.unavailableReason {
        return "Cannot inpaint: \(unavailableReason)"
      }
      return "Inpaint using \(generationMaskSourcePresentation.compactLabel) and preserve pixels outside it."
    case .selection:
      return "Run the selected workflow to make an object selection from the prompt."
    }
  }

  var workflowModeTitle: String {
    "Mode: \(generationMode.comfyUIDisplayName)"
  }

  var resolutionTitle: String {
    let outputSize = generationSettings.outputSize
    guard outputSize.isResolved else { return "Size" }
    return "\(outputSize.width) × \(outputSize.height)"
  }

  var seedTitle: String {
    generationSettings.randomizeSeed ? "Seed: Random" : "Seed: \(generationSettings.seed)"
  }

  var backgroundTitle: String {
    "Base: \(generationSettings.transparentPixelBackground.label)"
  }

  var maskSourceTitle: String {
    "Mask: \(generationMaskSourcePresentation.compactLabel)"
  }

  var maskSourceHelp: String {
    generationMaskSourcePresentation.help
  }

  /// Execute deliberately remains enabled while idle. Non-inpainting modes
  /// report an empty draft locally; inpainting intentionally accepts it.
  var isPrimaryActionEnabled: Bool {
    selectionPreview == nil || activeJob != nil
  }

  var visibleContentTags: [ImageContentTag] {
    let vision = contentTags.filter { $0.source == .vision }
    let recommendedVision = vision.filter(\.isRecommended)
    let visibleVision = recommendedVision.isEmpty ? vision : recommendedVision
    let generated = contentTags.filter { $0.source == .foundationModel }
    var tags: [ImageContentTag] = []
    var visionIndex = 0
    var generatedIndex = 0
    while tags.count < 32 && (visionIndex < visibleVision.count || generatedIndex < generated.count) {
      if visionIndex < visibleVision.count {
        tags.append(visibleVision[visionIndex])
        visionIndex += 1
      }
      if tags.count < 32 && generatedIndex < generated.count {
        tags.append(generated[generatedIndex])
        generatedIndex += 1
      }
    }
    return tags
  }

  var moreContentTags: [ImageContentTag] {
    let visibleIDs = Set(visibleContentTags.map(\.id))
    return contentTags.filter { !visibleIDs.contains($0.id) }
  }

  func setContentTags(_ tags: [ImageContentTag]) {
    contentTags = tags
  }

  func chooseContentTag(_ tag: ImageContentTag) {
    onSelectTag(tag.label)
    prompt = tag.label
    requestFocus()
  }

  func setSelectionPreview(_ selection: MaskRecipe?) {
    selectionPreview = selection
  }

  func setGenerationJobs(_ jobs: [GenerationJob]) {
    activeJob = jobs.last(where: { $0.state.isActive })
    let previousFailure = terminalFailure
    if activeJob != nil {
      terminalJobMessage = nil
      terminalFailure = nil
    } else if let job = jobs.last(where: { $0.canApplyAnyway }),
      case .failed(let message) = job.state
    {
      terminalJobMessage = nil
      terminalFailure = PromptBoxFailure(job: job, message: message)
    } else if let job = jobs.last, case .failed(let message) = job.state {
      terminalJobMessage = nil
      terminalFailure = PromptBoxFailure(job: job, message: message)
    } else {
      terminalJobMessage = jobs.last?.state.label
      terminalFailure = nil
    }
    if terminalFailure != previousFailure {
      isFailureExpanded = false
    }
    validationMessage = nil
  }

  func toggleFailureDetails() {
    guard terminalFailure != nil else { return }
    isFailureExpanded.toggle()
  }

  func copyFailureDetails() {
    guard let details = terminalFailure?.copyText else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(details, forType: .string)
  }

  func applyComfyUIResultAnyway() {
    guard let failure = terminalFailure, failure.canApplyAnyway else { return }
    onApplyComfyUIResultAnyway(failure.jobID)
  }

  func setGenerationSettings(_ settings: InpaintingToolState) {
    generationSettings = settings
  }

  func setGenerationMode(_ mode: GenerationMode) {
    guard mode != generationMode else { return }
    promptDrafts[generationMode] = prompt
    generationMode = mode
    prompt = promptDrafts[mode] ?? ""
  }

  func setGenerationMaskSources(
    presentation: GenerationMaskSourcePresentation,
    options: [GenerationMaskSourceOption]
  ) {
    generationMaskSourcePresentation = presentation
    generationMaskSourceOptions = options
  }

  func restorePrompt(_ restoredPrompt: String) {
    prompt = restoredPrompt
    requestFocus()
  }

  func setExecutionTarget(_ target: ComfyUIExecutionTarget) {
    executionTarget = target
  }

  func setComfyCloudAPIKeyAvailable(_ available: Bool) {
    hasComfyCloudAPIKey = available
  }

  func selectExecutionTarget(_ target: ComfyUIExecutionTarget) {
    guard activeJob == nil, (target == .local || hasComfyCloudAPIKey) else { return }
    onSelectExecutionTarget(target)
  }

  func selectGenerationMode(_ mode: GenerationMode) {
    guard mode != generationMode, activeJob == nil, selectionPreview == nil else { return }
    onSelectGenerationMode(mode)
  }

  func selectGenerationMaskSource(_ source: GenerationMaskSourceChoice) {
    guard activeJob == nil, selectionPreview == nil,
      generationMaskSourceOptions.contains(where: { $0.source == source && $0.isAvailable })
    else { return }
    onSelectGenerationMaskSource(source)
  }

  func applySelectionPreview() { onApplySelectionPreview() }

  func discardSelectionPreview() { onDiscardSelectionPreview() }

  func toggleDetails() {
    isDetailsExpanded.toggle()
  }

  func setComfyUIDebugEvents(_ events: [ComfyUIDebugEvent]) {
    comfyUIDebugEvents = events
  }

  func setComfyUIDebugImages(_ images: [ComfyUIDebugImage]) {
    comfyUIDebugImages = images
  }

  func setComfyUIDebugDiskLoggingState(_ state: ComfyUIDebugDiskLoggingState) {
    comfyUIDebugDiskLoggingState = state
  }

  func setComfyUIDebugDiskLoggingEnabled(_ enabled: Bool) {
    onSetComfyUIDebugDiskLoggingEnabled(enabled)
  }

  func revealComfyUIDebugLog() {
    onRevealComfyUIDebugLog()
  }

  var comfyUIDebugDiskLoggingStatus: String? {
    switch comfyUIDebugDiskLoggingState {
    case .disabled:
      nil
    case .starting:
      "Creating debug folder…"
    case .enabled(let directory):
      "Saving request.log and images to \(directory.path(percentEncoded: false))"
    case .failed(let message):
      "Disk logging stopped: \(message)"
    }
  }

  func clearComfyUIDebugEvents() {
    onClearComfyUIDebugEvents()
  }

  var comfyUIDebugTranscript: String {
    comfyUIDebugEvents.map(\.transcriptText).joined(separator: "\n\n")
  }

  func copyComfyUIDebugTranscript() {
    guard !comfyUIDebugEvents.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(comfyUIDebugTranscript, forType: .string)
  }

  func selectResolution(_ outputSize: CanvasRecipe) {
    guard activeJob == nil, outputSize.isResolved,
      outputSize != generationSettings.outputSize
    else { return }
    var settings = generationSettings
    settings.outputSize = outputSize
    updateGenerationSettings(settings)
  }

  func setRandomizeSeed(_ enabled: Bool) {
    var settings = generationSettings
    settings.randomizeSeed = enabled
    updateGenerationSettings(settings)
  }

  /// Keeps the seed most recently shown in the menu. When randomization has
  /// already produced a job, this is that job's seed.
  func reuseCurrentSeed() {
    var settings = generationSettings
    settings.randomizeSeed = false
    updateGenerationSettings(settings)
  }

  func chooseNewFixedSeed() {
    var settings = generationSettings
    settings.seed = UInt64.random(in: UInt64.min...UInt64.max)
    settings.randomizeSeed = false
    updateGenerationSettings(settings)
  }

  func setBackground(_ background: GenerationBackground) {
    var settings = generationSettings
    settings.transparentPixelBackground = background
    updateGenerationSettings(settings)
  }

  func setExpandMaskForComfyUI(_ enabled: Bool) {
    var settings = generationSettings
    settings.expandMaskForComfyUI = enabled
    updateGenerationSettings(settings)
  }

  func requestFocus() {
    focusRequest &+= 1
  }

  func performPrimaryAction() {
    if activeJob != nil {
      onCancelGeneration()
      return
    }

    let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanPrompt.isEmpty || generationMode == .inpainting else {
      validationMessage = "Enter a prompt"
      onPromptRequired()
      return
    }
    onSubmit(cleanPrompt)
  }

  private func updateGenerationSettings(_ settings: InpaintingToolState) {
    generationSettings = settings.clamped
    onUpdateGenerationSettings(generationSettings)
  }
}

struct PromptBoxFailure: Equatable {
  let message: String
  let jobID: UUID
  let backendID: String?
  let executionTarget: ComfyUIExecutionTarget
  let templateID: String?
  let canApplyAnyway: Bool

  init(job: GenerationJob, message: String) {
    self.message = message
    self.jobID = job.id
    self.backendID = job.backendID
    self.executionTarget = job.executionTarget
    self.templateID = job.templateID
    self.canApplyAnyway = job.canApplyAnyway
  }

  var copyText: String {
    var lines = ["Workflow failed", "", message, "", "Local job: \(jobID.uuidString)"]
    if let templateID { lines.append("Workflow: \(templateID)") }
    if let backendID {
      lines.append("\(executionTarget == .cloud ? "Comfy Cloud job" : "ComfyUI prompt"): \(backendID)")
    }
    if canApplyAnyway { lines.append("The completed output is available to apply anyway.") }
    return lines.joined(separator: "\n")
  }
}

/// A stable AppKit drag surface for a SwiftUI panel whose hosting view moves
/// while the pointer is down. Window coordinates do not move with the prompt
/// box, and accepting first mouse lets the same click activate and drag it.
@MainActor
final class PromptBoxDragTrackingView: NSView {
  var onMove: (CGPoint) -> Void = { _ in }
  private var previousLocationInWindow: CGPoint?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    previousLocationInWindow = event.locationInWindow
    NSCursor.closedHand.set()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let previousLocationInWindow else { return }
    let location = event.locationInWindow
    let delta = CGPoint(
      x: location.x - previousLocationInWindow.x,
      // AppKit event coordinates grow upward, while this hosted bottom-anchor
      // constraint grows downward. Convert into the constraint's direction.
      y: previousLocationInWindow.y - location.y)
    self.previousLocationInWindow = location
    if delta != .zero {
      onMove(delta)
    }
  }

  override func mouseUp(with event: NSEvent) {
    previousLocationInWindow = nil
    NSCursor.openHand.set()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .openHand)
  }
}

private struct PromptBoxDragSurface: NSViewRepresentable {
  var onMove: (CGPoint) -> Void

  func makeNSView(context: Context) -> PromptBoxDragTrackingView {
    let view = PromptBoxDragTrackingView()
    view.onMove = onMove
    return view
  }

  func updateNSView(_ view: PromptBoxDragTrackingView, context: Context) {
    view.onMove = onMove
  }
}

/// A stable bottom-trailing resize surface. Deltas use visual size directions:
/// right grows the width and down grows the height, independent of AppKit's
/// upward-growing window coordinates.
@MainActor
final class PromptBoxResizeTrackingView: NSView {
  var onResize: (CGSize) -> Void = { _ in }
  private var previousLocationInWindow: CGPoint?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    previousLocationInWindow = event.locationInWindow
    NSCursor.crosshair.set()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let previousLocationInWindow else { return }
    let location = event.locationInWindow
    let delta = CGSize(
      width: location.x - previousLocationInWindow.x,
      height: previousLocationInWindow.y - location.y)
    self.previousLocationInWindow = location
    if delta != .zero {
      onResize(delta)
    }
  }

  override func mouseUp(with event: NSEvent) {
    previousLocationInWindow = nil
    NSCursor.arrow.set()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .crosshair)
  }
}

private struct PromptBoxResizeSurface: NSViewRepresentable {
  var onResize: (CGSize) -> Void

  func makeNSView(context: Context) -> PromptBoxResizeTrackingView {
    let view = PromptBoxResizeTrackingView()
    view.onResize = onResize
    return view
  }

  func updateNSView(_ view: PromptBoxResizeTrackingView, context: Context) {
    view.onResize = onResize
  }
}

/// SwiftUI intentionally lets fully transparent regions fall through hit
/// testing. Route the prompt box's native drag and resize surfaces explicitly,
/// preserve ordinary SwiftUI control hits, and claim every remaining point in
/// the overlay as another drag surface instead of letting it reach the canvas.
@MainActor
final class PromptBoxHostingView: NSHostingView<PromptBoxView> {
  var onMove: (CGPoint) -> Void = { _ in }
  private var previousLocationInWindow: CGPoint?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // AppKit supplies `point` in the superview's coordinates. The drag and
    // resize descendants, and our bounds, must be tested in local coordinates.
    let localPoint = convert(point, from: superview)
    guard bounds.contains(localPoint) else { return nil }
    if let resizeSurface = resizeSurfaceDescendant(in: self) {
      let pointInResizeSurface = resizeSurface.convert(localPoint, from: self)
      if resizeSurface.bounds.contains(pointInResizeSurface) {
        return resizeSurface
      }
    }
    if let dragSurface = dragSurfaceDescendant(in: self) {
      let pointInDragSurface = dragSurface.convert(localPoint, from: self)
      if dragSurface.bounds.contains(pointInDragSurface) {
        return dragSurface
      }
    }
    if let hit = super.hitTest(point) {
      return hit
    }
    // A glass surface contains visually transparent pixels. They still belong
    // to the prompt box and must never start a canvas gesture underneath it.
    return self
  }

  override func mouseDown(with event: NSEvent) {
    previousLocationInWindow = event.locationInWindow
    NSCursor.closedHand.set()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let previousLocationInWindow else { return }
    let location = event.locationInWindow
    let delta = CGPoint(
      x: location.x - previousLocationInWindow.x,
      y: previousLocationInWindow.y - location.y)
    self.previousLocationInWindow = location
    if delta != .zero {
      onMove(delta)
    }
  }

  override func mouseUp(with event: NSEvent) {
    previousLocationInWindow = nil
    NSCursor.arrow.set()
  }

  private func dragSurfaceDescendant(in view: NSView) -> PromptBoxDragTrackingView? {
    for subview in view.subviews {
      if let dragSurface = subview as? PromptBoxDragTrackingView {
        return dragSurface
      }
      if let dragSurface = dragSurfaceDescendant(in: subview) {
        return dragSurface
      }
    }
    return nil
  }

  private func resizeSurfaceDescendant(in view: NSView) -> PromptBoxResizeTrackingView? {
    for subview in view.subviews {
      if let resizeSurface = subview as? PromptBoxResizeTrackingView {
        return resizeSurface
      }
      if let resizeSurface = resizeSurfaceDescendant(in: subview) {
        return resizeSurface
      }
    }
    return nil
  }
}

/// The native SwiftUI prompt entry surface hosted over the AppKit canvas.
///
/// It emits presentation intents only; the owning document remains the sole
/// authority for generation and revision-safe recipe changes.
@MainActor
struct PromptBoxView: View {
  @ObservedObject var model: PromptBoxModel
  @FocusState private var promptIsFocused: Bool

  var body: some View {
    VStack(spacing: 8) {
      header
        .frame(height: 24)

      contentTagRow
        .frame(height: 28)

      TextField(
        promptPlaceholder,
        text: $model.prompt)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused($promptIsFocused)
        .onSubmit { model.performPrimaryAction() }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .accessibilityLabel("Workflow prompt")
        .accessibilityHint(
          model.generationMode == .inpainting
            ? "Optionally describe what should replace the inpainted area."
            : "Describe an image, an edit, or an object to select for the active workflow."
        )
        .accessibilityIdentifier("promptBox.prompt")

      controls
        .frame(height: 32)

      if model.isFailureExpanded, let failure = model.terminalFailure {
        failureDetails(failure)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }

      if model.isDetailsExpanded {
        generationDetails
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.init(top: 10, leading: 14, bottom: 12, trailing: 14))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .glassEffect(
      .regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
    .shadow(color: .black.opacity(0.24), radius: 14, x: 0, y: 3)
    .overlay(alignment: .bottomTrailing) { resizeHandle }
    .animation(.easeInOut(duration: 0.16), value: model.isFailureExpanded)
    .animation(.easeInOut(duration: 0.16), value: model.isDetailsExpanded)
    .onAppear { honorFocusRequest() }
    .onChange(of: model.focusRequest) { _, _ in honorFocusRequest() }
  }

  private var promptPlaceholder: String {
    switch model.generationMode {
    case .selection:
      "Describe what to select…"
    case .inpainting:
      "Optional: describe what should fill the mask…"
    case .textToImage, .imageToImage:
      "Describe what the workflow should make…"
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      ZStack {
        PromptBoxDragSurface(onMove: model.onMove)
        HStack(spacing: 6) {
          Image(systemName: "minus")
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 12)
          Text("Workflow")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Move prompt box")
      .accessibilityHint("Drag to move the prompt box around the canvas")
      .accessibilityIdentifier("promptBox.dragHandle")

      if model.hasComfyCloudAPIKey {
        Picker(
          "Run on",
          selection: Binding(
            get: { model.executionTarget },
            set: { model.selectExecutionTarget($0) })
        ) {
          ForEach(ComfyUIExecutionTarget.allCases, id: \.self) { target in
            Text(target.label).tag(target)
          }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .disabled(model.activeJob != nil)
        .help("Choose whether this workflow runs on your ComfyUI server or Comfy Cloud")
        .accessibilityIdentifier("promptBox.executionTarget")
      }

      Button(action: model.toggleDetails) {
        HStack(spacing: 5) {
          Text("Details")
          Image(systemName: model.isDetailsExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
        }
      }
      .buttonStyle(.glass)
      .controlSize(.small)
      .help(model.isDetailsExpanded ? "Hide generation details" : "Show generation details")
      .accessibilityLabel("Generation details")
      .accessibilityHint(
        model.isDetailsExpanded ? "Collapse the generation log" : "Expand the generation log")
      .accessibilityIdentifier("promptBox.detailsDisclosure")

      Button(action: { model.onClose() }) {
        Image(systemName: "xmark")
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.glass)
      .help("Close Prompt Box (⌥⌘K)")
      .accessibilityLabel("Close prompt box")
      .accessibilityIdentifier("promptBox.close")
    }
  }

  private var resizeHandle: some View {
    ZStack {
      PromptBoxResizeSurface(onResize: model.onResize)
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
        .allowsHitTesting(false)
    }
    .frame(width: 24, height: 24)
    .padding(3)
    .help("Drag to resize the prompt box")
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Resize prompt box")
    .accessibilityHint("Drag to change the width and height")
    .accessibilityIdentifier("promptBox.resizeHandle")
  }

  private var contentTagRow: some View {
    HStack(spacing: 7) {
      Text("Image tags")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
      if model.contentTags.isEmpty {
        Text("Appear when the image is ready")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      } else {
        ScrollView(.horizontal) {
          HStack(spacing: 5) {
            ForEach(model.visibleContentTags) { tag in
              Button(tag.label) { model.chooseContentTag(tag) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(tag.source == .foundationModel
                  ? "Suggested subject: \(tag.label). Check the image before selecting."
                  : "Select \(tag.label) with the object selection workflow")
            }
          }
        }
        .scrollIndicators(.hidden)
        if !model.moreContentTags.isEmpty {
          Menu("More") {
            ForEach(model.moreContentTags) { tag in
              Button(tag.label) { model.chooseContentTag(tag) }
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("More image tags")
        }
      }
    }
    .accessibilityIdentifier("promptBox.imageTags")
  }

  private var controls: some View {
    HStack(spacing: 8) {
      HStack(spacing: 2) {
        Text("Mode:")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
        Picker(
          "Mode",
          selection: Binding(
            get: { model.generationMode },
            set: { model.selectGenerationMode($0) })
        ) {
          ForEach(ComfyUIWorkflowCatalog.modes, id: \.self) { mode in
            Text(mode.comfyUIDisplayName).tag(mode)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(model.activeJob != nil || model.selectionPreview != nil)
        .accessibilityIdentifier("promptBox.modePicker")
      }
      .help(model.primaryActionHelp)
      if model.generationMode == .inpainting {
        HStack(spacing: 2) {
          Text("Mask:")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
          Picker(
            "Mask",
            selection: Binding(
              get: { model.generationMaskSourcePresentation.requested },
              set: { model.selectGenerationMaskSource($0) })
          ) {
            ForEach(model.generationMaskSourceOptions) { option in
              Text(
                option.source == model.generationMaskSourcePresentation.requested
                  ? model.generationMaskSourcePresentation.compactLabel
                  : option.label
              )
              .tag(option.source)
              .disabled(!option.isAvailable)
              .help(option.unavailableReason ?? "Use \(option.label) for inpainting.")
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .controlSize(.small)
          .fixedSize()
          .tint(
            model.generationMaskSourcePresentation.unavailableReason == nil
              ? nil : .red)
          .disabled(model.activeJob != nil || model.selectionPreview != nil)
          .accessibilityIdentifier("promptBox.maskSource")
        }
        .help(model.maskSourceHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Inpaint mask source")
        .accessibilityValue(model.generationMaskSourcePresentation.compactLabel)

        Toggle(
          "Slightly expand mask",
          isOn: Binding(
            get: { model.generationSettings.expandMaskForComfyUI },
            set: { model.setExpandMaskForComfyUI($0) })
        )
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .fixedSize()
        .disabled(model.activeJob != nil || model.selectionPreview != nil)
        .help(
          "Slightly expand the mask sent to ComfyUI to prevent edge halos. The original mask still clips the returned layer."
        )
        .accessibilityIdentifier("promptBox.expandInpaintMask")
      }
      if model.generationMode != .selection {
        resolutionMenu
        seedMenu
        if model.generationMode != .textToImage {
          backgroundMenu
        }
      }

      if model.selectionPreview != nil {
        Button("Apply Selection", action: model.applySelectionPreview)
          .buttonStyle(.glassProminent)
          .controlSize(.small)
          .accessibilityIdentifier("promptBox.applySelection")
        Button("Discard", action: model.discardSelectionPreview)
          .buttonStyle(.glass)
          .controlSize(.small)
          .accessibilityIdentifier("promptBox.discardSelection")
      }

      if model.terminalFailure != nil, model.activeJob == nil {
        Button(action: model.toggleFailureDetails) {
          HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Workflow failed")
            Image(systemName: model.isFailureExpanded ? "chevron.up" : "chevron.down")
              .font(.system(size: 9, weight: .semibold))
          }
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help(model.isFailureExpanded ? "Hide failure details" : "Show failure details")
        .accessibilityLabel("Workflow failed")
        .accessibilityHint(
          model.isFailureExpanded ? "Collapse the error details" : "Expand the error details")
        .accessibilityIdentifier("promptBox.failureDisclosure")
      } else if let statusText = model.statusText {
        Text(statusText)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityLabel("Workflow status")
          .accessibilityValue(statusText)
      }

      if model.terminalFailure?.canApplyAnyway == true, model.activeJob == nil {
        Button("Apply Anyway", action: model.applyComfyUIResultAnyway)
          .buttonStyle(.glassProminent)
          .controlSize(.small)
          .help("Add the completed ComfyUI result as a new layer despite document changes")
          .accessibilityHint(
            "Commits the retained result as a new layer on the current document")
          .accessibilityIdentifier("promptBox.applyComfyUIResultAnyway")
      }

      if let progress = model.progress {
        ProgressView(value: progress)
          .frame(minWidth: 80)
          .accessibilityLabel("Workflow progress")
          .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
      }

      Spacer(minLength: 0)

      Button(action: model.performPrimaryAction) {
        Label(model.primaryActionTitle, systemImage: model.primaryActionSymbol)
      }
      .buttonStyle(.glassProminent)
      .disabled(!model.isPrimaryActionEnabled)
      .help(model.primaryActionHelp)
      .accessibilityHint(model.primaryActionHelp)
      .accessibilityIdentifier("promptBox.primaryAction")
    }
  }

  private func failureDetails(_ failure: PromptBoxFailure) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("ComfyUI details", systemImage: "exclamationmark.circle.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.red)
        Spacer()
        Button("Copy Details", action: model.copyFailureDetails)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .accessibilityIdentifier("promptBox.copyFailureDetails")
      }

      ScrollView {
        Text(failure.copyText)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 92)
    }
    .padding(10)
    .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(.red.opacity(0.35), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("ComfyUI generation failure details")
  }

  private var generationDetails: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Label("Workflow Log", systemImage: "list.bullet.rectangle")
          .font(.system(size: 12, weight: .semibold))
        Text("\(model.comfyUIDebugEvents.count) events")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
        Spacer()
        Button("Clear", action: model.clearComfyUIDebugEvents)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(model.comfyUIDebugEvents.isEmpty)
          .accessibilityIdentifier("promptBox.clearComfyUIDebugLog")
        Button("Copy", action: model.copyComfyUIDebugTranscript)
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(model.comfyUIDebugEvents.isEmpty)
          .accessibilityIdentifier("promptBox.copyComfyUIDebugLog")
      }

      HStack(spacing: 8) {
        Toggle(
          "Enable Comfy debugging",
          isOn: Binding(
            get: { model.comfyUIDebugDiskLoggingState.isRequested },
            set: { model.setComfyUIDebugDiskLoggingEnabled($0) }))
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(model.comfyUIDebugDiskLoggingState == .starting)
          .help(
            "Continuously save the ComfyUI transcript and source, mask, and returned images to disk")
          .accessibilityIdentifier("promptBox.enableComfyUIDebugDiskLogging")
        Spacer()
        if model.comfyUIDebugDiskLoggingState.directoryURL != nil {
          Button("Reveal", action: model.revealComfyUIDebugLog)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityIdentifier("promptBox.revealComfyUIDebugLog")
        }
      }

      if let status = model.comfyUIDebugDiskLoggingStatus {
        Text(status)
          .font(.system(size: 9))
          .foregroundStyle(
            model.comfyUIDebugDiskLoggingState.isRequested ? Color.secondary : Color.red)
          .lineLimit(2)
          .textSelection(.enabled)
          .accessibilityIdentifier("promptBox.comfyUIDebugDiskLoggingStatus")
      }

      ScrollViewReader { proxy in
        ScrollView {
          Text(
            model.comfyUIDebugEvents.isEmpty
              ? "Waiting for ComfyUI activity…"
              : model.comfyUIDebugTranscript
          )
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(model.comfyUIDebugEvents.isEmpty ? .secondary : .primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .id(model.comfyUIDebugEvents.last?.id)
        }
        .onChange(of: model.comfyUIDebugEvents.count) { _, _ in
          if let id = model.comfyUIDebugEvents.last?.id {
            proxy.scrollTo(id, anchor: .bottom)
          }
        }
      }
      .frame(minHeight: 72, maxHeight: .infinity)

      HStack(spacing: 5) {
        Image(systemName: "photo.on.rectangle.angled")
        Text("Sent / Returned Images")
        Spacer()
        Text("\(model.comfyUIDebugImages.count) previews")
          .foregroundStyle(.tertiary)
      }
      .font(.system(size: 10, weight: .semibold))

      if model.comfyUIDebugImages.isEmpty {
        ContentUnavailableView(
          "No image previews yet",
          systemImage: "photo",
          description: Text(
            "The uploaded source, when present, and the returned image will appear here."))
          .frame(maxWidth: .infinity)
          .frame(minHeight: 80, idealHeight: 142, maxHeight: 142)
          .accessibilityIdentifier("promptBox.comfyUIDebugImagesEmpty")
      } else {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(Array(model.comfyUIDebugImages.reversed())) { artifact in
              comfyUIDebugThumbnail(artifact)
            }
          }
        }
        .scrollIndicators(.visible)
        .frame(minHeight: 80, idealHeight: 142, maxHeight: 142)
        .accessibilityLabel("Images sent to and returned by ComfyUI, newest first")
        .accessibilityIdentifier("promptBox.comfyUIDebugImages")
      }
    }
    .padding(10)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(.secondary.opacity(0.30), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Generation log")
  }

  @ViewBuilder
  private func comfyUIDebugThumbnail(_ artifact: ComfyUIDebugImage) -> some View {
    if let image = NSImage(data: artifact.imageData) {
      VStack(alignment: .leading, spacing: 4) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 208, height: 108)
          .background(.black.opacity(0.16))
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        Text(artifact.label)
          .font(.system(size: 10, weight: .semibold))
          .lineLimit(1)
          .frame(width: 208, alignment: .leading)
        Text(
          ByteCountFormatter.string(
            fromByteCount: Int64(artifact.imageData.count), countStyle: .file)
        )
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
      }
      .help(artifact.label)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(artifact.label)
      .accessibilityValue("\(artifact.imageData.count) bytes")
    } else {
      VStack(spacing: 5) {
        Image(systemName: "exclamationmark.triangle")
        Text("Preview unavailable")
          .font(.system(size: 10, weight: .semibold))
        Text(artifact.label)
          .font(.system(size: 9))
          .lineLimit(2)
      }
      .foregroundStyle(.secondary)
      .frame(width: 208, height: 132)
      .background(.black.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .help("\(artifact.label) — \(artifact.imageData.count) bytes")
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(artifact.label), preview unavailable")
    }
  }

  private var resolutionMenu: some View {
    Menu {
      ForEach(GenerationSizePreset.compatible) { preset in
        Button {
          model.selectResolution(preset.outputSize)
        } label: {
          if preset.outputSize == model.generationSettings.outputSize {
            Label(preset.label, systemImage: "checkmark")
          } else {
            Text(preset.label)
          }
        }
      }
    } label: {
      Label(model.resolutionTitle, systemImage: "aspectratio")
    }
    .menuStyle(.button)
    .buttonStyle(.glass)
    .disabled(model.activeJob != nil)
    .help("Choose the pixel size of the new Z-Image raster layer.")
    .accessibilityLabel("Generation output size")
    .accessibilityValue(model.resolutionTitle)
  }

  private var seedMenu: some View {
    Menu {
      Toggle(
        "Randomize each generation",
        isOn: Binding(
          get: { model.generationSettings.randomizeSeed },
          set: { model.setRandomizeSeed($0) }))
      Button {
        model.reuseCurrentSeed()
      } label: {
        if model.generationSettings.randomizeSeed {
          Text("Reuse current seed")
        } else {
          Label("Reuse current seed", systemImage: "checkmark")
        }
      }
      Button("New fixed seed") { model.chooseNewFixedSeed() }
      Divider()
      Text("Current seed: \(model.generationSettings.seed)")
    } label: {
      Label(model.seedTitle, systemImage: "dice")
    }
    .menuStyle(.button)
    .buttonStyle(.glass)
    .disabled(model.activeJob != nil)
    .help("The seed controls the starting noise. Reuse a fixed seed for repeatable output.")
    .accessibilityLabel("Generation seed")
    .accessibilityValue(model.seedTitle)
  }

  private var backgroundMenu: some View {
    Menu {
      ForEach(GenerationBackground.allCases, id: \.self) { background in
        Button {
          model.setBackground(background)
        } label: {
          if background == model.generationSettings.transparentPixelBackground {
            Label(background.label, systemImage: "checkmark")
          } else {
            Text(background.label)
          }
        }
      }
    } label: {
      Label(model.backgroundTitle, systemImage: "circle.lefthalf.filled")
    }
    .menuStyle(.button)
    .buttonStyle(.glass)
    .disabled(model.activeJob != nil)
    .help("Choose the color supplied to Z-Image behind transparent canvas pixels.")
    .accessibilityLabel("Transparent canvas base color")
    .accessibilityValue(model.generationSettings.transparentPixelBackground.label)
  }

  private func honorFocusRequest() {
    guard model.focusRequest > 0 else { return }
    promptIsFocused = true
  }
}

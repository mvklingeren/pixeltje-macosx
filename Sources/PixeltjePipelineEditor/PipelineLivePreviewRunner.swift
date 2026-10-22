import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import QuartzCore
import Synchronization

/// Editor inputs that a live preview reads at the start of each call. The
/// editor replaces the snapshot whenever they change; the runner never waits
/// for the main actor to read them.
final class PipelineLiveRunControls: Sendable {
  struct Trackpad: Equatable, Sendable {
    var x: Double
    var y: Double
    var engaged: Bool
    var engagedAtCall: Int64
    var engagedAtRunIndex: Int?
    var actionCount: Int
    var secondaryActionCount: Int
  }

  struct DirectionPad: Equatable, Sendable {
    var x: Double
    var y: Double
    var keys = 0
  }

  struct Snapshot: Equatable, Sendable {
    var continueRepeating = true
    /// False while pausing or paused; per-refresh rendering waits meanwhile.
    var isRunning = true
    var autoPause = false
    var autoPausedLoopNodeID: PipelineNodeID?
    var fullScreenPreviewNodeID: PipelineNodeID?
    var trackpad: Trackpad?
    var directionPad: DirectionPad?
    var metalPreviewSize: PipelinePixelSize?
  }

  private struct State {
    var snapshot = Snapshot()
    var failure: String?
  }

  private let state = Mutex(State())

  var snapshot: Snapshot { state.withLock { $0.snapshot } }

  func update(_ snapshot: Snapshot) {
    state.withLock { $0.snapshot = snapshot }
  }

  /// Records the first preview failure; the runner stops at its next check.
  func fail(_ message: String) {
    state.withLock { state in
      if state.failure == nil { state.failure = message }
    }
  }

  func checkFailure() throws {
    if let failure = state.withLock({ $0.failure }) {
      throw PipelineEngineError.invalidInvocation(failure)
    }
  }
}

/// The runner's latest call, which the editor samples at its own rate.
final class PipelineLiveRunTelemetry: Sendable {
  struct Snapshot: Equatable, Sendable {
    var call = 0
    var seed: UInt64?
    var completedCall = 0
    var completedCallSeconds = 0.0
  }

  private let state = Mutex(Snapshot())

  var snapshot: Snapshot { state.withLock { $0 } }

  func update(_ body: (inout Snapshot) -> Void) {
    state.withLock { body(&$0) }
  }
}

/// Drives a direct Metal Render or GPU Program preview Loop away from the main
/// actor. The runner owns every per-call value and exchanges only snapshots and
/// finished surfaces with the editor, so no frame waits for a SwiftUI update.
actor PipelineLivePreviewRunner {
  /// An unlimited Loop would otherwise run as fast as the engine allows.
  /// Shader-state previews already interpolate as if calls arrive at 60 Hz.
  static let unlimitedRateHz = 60
  /// Refresh timing older than this means no visible view paces the run.
  private static let refreshTimingMaximumAge: CFTimeInterval = 0.25

  struct Configuration: Sendable {
    let engine: PixeltjePipelineEngine
    let pipeline: PipelineDocument
    let executionID: UUID
    let liveNodeID: PipelineNodeID
    let isGPUProgram: Bool
    let shaderMetalRenderID: PipelineNodeID?
    let shaderTimeline: PipelineTimelineSettings?
    let loopNodeID: PipelineNodeID
    let settings: PipelineLoopSettings
    let sourceMediaRoot: URL?
    let packageRoots: [String: URL]
    let usesSavedInputs: Bool
    let runPrompt: String
    let baseSeed: UInt64?
    let resumeState: String?
    let outputSize: PipelinePixelSize?
    let usesLiveProceduralTrackpad: Bool
    let repeatLength: Int?
    let containsGPUProgram: Bool
    let performanceLog: PipelineEditorPerformanceLog?
    let highlightingEnabled: Bool
    let nodeSpeedLabelsEnabled: Bool
  }

  /// Editor transitions the runner must wait for. None of them occurs per frame.
  struct Host: Sendable {
    let markPaused: @Sendable () async -> Void
    let beginAutoPause: @Sendable (_ call: Int) async -> Void
    let endAutoPause: @Sendable () async -> Void
    /// Reports the pixel size of the first frame and of any resized frame.
    let frameSizeChanged: @Sendable (CGSize) async -> Void
    let playAudioEvent: @Sendable (URL) async -> Void
    /// The looping voices one call left; calls arrive in order but their
    /// updates may not, so the receiver keeps the newest.
    let updateAudioVoices: @Sendable (_ call: Int, [PipelineGPUAudioVoice]) async -> Void
  }

  private let configuration: Configuration
  private let host: Host
  private let controls: PipelineLiveRunControls
  private let telemetry: PipelineLiveRunTelemetry
  private let progressBuffer: PipelineEditorProgressBuffer
  private let source: PipelineLivePreviewSource
  private let pauseGate: PipelineExecutionPauseGate
  private let videoPreviewRecorder: PipelineVideoPreviewRecorder

  init(configuration: Configuration, host: Host,
    controls: PipelineLiveRunControls, telemetry: PipelineLiveRunTelemetry,
    progressBuffer: PipelineEditorProgressBuffer, source: PipelineLivePreviewSource,
    pauseGate: PipelineExecutionPauseGate,
    videoPreviewRecorder: PipelineVideoPreviewRecorder) {
    self.configuration = configuration
    self.host = host
    self.controls = controls
    self.telemetry = telemetry
    self.progressBuffer = progressBuffer
    self.source = source
    self.pauseGate = pauseGate
    self.videoPreviewRecorder = videoPreviewRecorder
  }

  func run() async throws {
    let renderPump = configuration.isGPUProgram ? nil : startRenderPump()
    defer { renderPump?.cancel() }
    let configuration = configuration
    let settings = configuration.settings
    let clock = ContinuousClock()
    let callInterval = Duration.seconds(
      1 / Double(settings.limitHz ?? Self.unlimitedRateHz))
    let delay = Duration.milliseconds(settings.delayMilliseconds)
    var scheduledStart: ContinuousClock.Instant?
    var previousCallStartedAt: UInt64?
    var previousLogEnqueueSeconds: Double?
    var previousRequestedWaitSeconds: Double?
    var previousActualWaitSeconds: Double?
    var previousReadyAt: UInt64?
    var call = 1
    var hadAudioVoices = false
    while true {
      try controls.checkFailure()
      try await checkpoint()
      let inputs = controls.snapshot
      let cycleIndex = settings.callIndex(forRunCall: call)
      let callStart = clock.now
      let callStartedAt = DispatchTime.now().uptimeNanoseconds
      let frameInterval = previousCallStartedAt.map {
        PipelineEditorCallbackTimings.seconds(since: $0, until: callStartedAt)
      }
      let previousReadyToStartSeconds = previousReadyAt.map {
        PipelineEditorCallbackTimings.seconds(since: $0, until: callStartedAt)
      }
      previousCallStartedAt = callStartedAt
      let seed = configuration.baseSeed.map { base in
        settings.seedStrategy == .increment ? base &+ UInt64(cycleIndex) : base
      }
      telemetry.update {
        $0.call = call
        $0.seed = seed
      }
      let invocation = makeInvocation(
        call: call, cycleIndex: cycleIndex, seed: seed, inputs: inputs)
      let callbackTimings = configuration.performanceLog.map { _ in
        PipelineEditorCallbackTimings()
      }
      let engineStartedAt = DispatchTime.now().uptimeNanoseconds
      _ = try await configuration.engine.updateLiveMetalPreviewState(
        configuration.pipeline, runID: configuration.executionID,
        nodeID: configuration.liveNodeID,
        sourceMediaRoot: configuration.sourceMediaRoot,
        packageRootsByID: configuration.packageRoots, invocation: invocation,
        progress: progressHandler(timings: callbackTimings))
      for url in await configuration.engine.takeLiveMetalAudioEvents(
        runID: configuration.executionID) {
        let playAudioEvent = host.playAudioEvent
        Task { await playAudioEvent(url) }
      }
      let audioVoices = await configuration.engine.takeLiveMetalAudioVoices(
        runID: configuration.executionID)
      if hadAudioVoices || !audioVoices.isEmpty {
        let updateAudioVoices = host.updateAudioVoices
        let voiceCall = call
        Task { await updateAudioVoices(voiceCall, audioVoices) }
      }
      hadAudioVoices = !audioVoices.isEmpty
      let engineCompletedAt = DispatchTime.now().uptimeNanoseconds
      // A GPU Program completes its surface within the call. Shader-state
      // previews are drawn per display refresh by the render pump instead,
      // which needs one unpaced render to show a first frame.
      if configuration.isGPUProgram {
        if let frame = try await configuration.engine.liveMetalPreview(
          runID: configuration.executionID) {
          publish(frame)
        }
      } else if !source.frames.hasFrame {
        source.refresh.kick()
      }
      let publicationStartedAt = DispatchTime.now().uptimeNanoseconds
      try await videoPreviewRecorder.check()
      try Task.checkCancellation()
      let completedAt = DispatchTime.now().uptimeNanoseconds
      let callSeconds = PipelineEditorCallbackTimings.seconds(
        since: callStartedAt, until: completedAt)
      telemetry.update {
        $0.completedCall = call
        $0.completedCallSeconds = callSeconds
      }
      if let performanceLog = configuration.performanceLog, let callbackTimings {
        let logStartedAt = DispatchTime.now().uptimeNanoseconds
        let record = PipelineEditorPerformanceLog.Frame(
          runID: configuration.executionID, call: call,
          configuration: PipelineEditorPerformanceLog.configuration,
          executable: Bundle.main.executableURL?.path,
          inputPreparationSeconds: PipelineEditorCallbackTimings.seconds(
            since: callStartedAt, until: engineStartedAt),
          engineSeconds: PipelineEditorCallbackTimings.seconds(
            since: engineStartedAt, until: engineCompletedAt),
          outputSavingSeconds: PipelineEditorCallbackTimings.seconds(
            since: engineCompletedAt, until: publicationStartedAt),
          progressFlushSeconds: 0,
          outputWriterSeconds: 0,
          gpuCommitSeconds: 0,
          publicationSeconds: PipelineEditorCallbackTimings.seconds(
            since: publicationStartedAt, until: completedAt),
          callSeconds: callSeconds,
          frameIntervalSeconds: frameInterval,
          configuredDelayMilliseconds: settings.delayMilliseconds,
          configuredLimitHz: settings.limitHz,
          directMetalPreview: true,
          saveGeneratedImagesToDisk: false,
          previewClockAvailable: source.refresh.timing(
            maximumAge: Self.refreshTimingMaximumAge) != nil,
          gpuProgram: configuration.engine.takeGPUProgramPerformance(
            runID: configuration.executionID),
          previousLogEnqueueSeconds: previousLogEnqueueSeconds,
          previousRequestedWaitSeconds: previousRequestedWaitSeconds,
          previousActualWaitSeconds: previousActualWaitSeconds,
          previousReadyToStartSeconds: previousReadyToStartSeconds,
          debugCaptureEnabled: false,
          highlightingEnabled: configuration.highlightingEnabled,
          nodeSpeedLabelsEnabled: configuration.nodeSpeedLabelsEnabled,
          callbacks: callbackTimings.snapshot())
        Task.detached(priority: .utility) {
          await performanceLog.record(record)
        }
        previousLogEnqueueSeconds = PipelineEditorCallbackTimings.seconds(
          since: logStartedAt)
      }
      try controls.checkFailure()
      guard controls.snapshot.continueRepeating,
        settings.continues(afterRunCall: call) else { break }
      // Pace to absolute start times, so wake-up latency does not accumulate.
      // A call that runs late by less than one interval is caught up; a
      // larger gap restarts the schedule instead of bursting.
      let now = clock.now
      var ideal = (scheduledStart ?? callStart) + callInterval
      if ideal < now - callInterval { ideal = now }
      let target = max(ideal, now + delay)
      scheduledStart = target
      let nextStart = configuration.isGPUProgram
        ? alignedToRefresh(target, now: now, callInterval: callInterval) : target
      previousRequestedWaitSeconds = nextStart > now ? Self.seconds(nextStart - now) : 0
      let waitStartedAt = DispatchTime.now().uptimeNanoseconds
      while clock.now < nextStart, controls.snapshot.continueRepeating {
        try await checkpoint()
        try await Task.sleep(until: min(nextStart, clock.now + .milliseconds(100)),
          tolerance: .microseconds(500), clock: clock)
      }
      previousActualWaitSeconds = PipelineEditorCallbackTimings.seconds(
        since: waitStartedAt)
      previousReadyAt = DispatchTime.now().uptimeNanoseconds
      guard controls.snapshot.continueRepeating else { break }
      if controls.snapshot.autoPause {
        guard try await autoPause(afterCall: call) else { break }
      }
      call += 1
    }
  }

  /// Waits at a Loop's auto pause. Returns false when the Loop stops instead.
  private func autoPause(afterCall call: Int) async throws -> Bool {
    await host.beginAutoPause(call)
    await pauseGate.pause()
    let inputs = controls.snapshot
    guard inputs.continueRepeating else {
      await pauseGate.resume()
      return false
    }
    if inputs.autoPausedLoopNodeID == configuration.loopNodeID, inputs.autoPause {
      try await checkpoint()
    } else {
      await pauseGate.resume()
      await host.endAutoPause()
    }
    return controls.snapshot.continueRepeating
  }

  private func checkpoint() async throws {
    try await pauseGate.checkpoint(onPaused: host.markPaused)
  }

  private func progressHandler(
    timings: PipelineEditorCallbackTimings?
  ) -> PipelineExecutionProgressHandler {
    let pauseGate = pauseGate
    let recorder = videoPreviewRecorder
    let buffer = progressBuffer
    let markPaused = host.markPaused
    return { update in
      let started = timings.map { _ in DispatchTime.now().uptimeNanoseconds }
      do {
        try await pauseGate.checkpoint(onPaused: markPaused)
        await recorder.record(update)
        buffer.submit(update)
      } catch { return }
      if let started { timings?.recordProgress(since: started) }
    }
  }

  private func publish(_ frame: PipelineMetalPreviewFrame) {
    guard source.publish(frame) else { return }
    let size = CGSize(width: frame.width, height: frame.height)
    let frameSizeChanged = host.frameSizeChanged
    Task { await frameSizeChanged(size) }
  }

  /// Moves a GPU Program call start onto the pacing view's refresh grid. A
  /// frame is shown on the first refresh after it completes, so aligned
  /// starts keep every frame on screen equally long. Without a visible view,
  /// or when refreshes are coarser than calls, the start stays unchanged.
  private func alignedToRefresh(_ target: ContinuousClock.Instant,
    now: ContinuousClock.Instant, callInterval: Duration) -> ContinuousClock.Instant {
    guard target > now,
      let timing = source.refresh.timing(maximumAge: Self.refreshTimingMaximumAge),
      timing.interval > 0,
      timing.interval <= Self.seconds(callInterval) * 1.01 else { return target }
    let hostNow = CACurrentMediaTime()
    let hostTarget = hostNow + Self.seconds(target - now)
    // A start just past a refresh moves back to it rather than a whole interval.
    let refreshes = ((hostTarget - timing.timestamp) / timing.interval - 0.1).rounded(.up)
    let aligned = timing.timestamp + refreshes * timing.interval
    return now + .seconds(max(0, aligned - hostNow))
  }

  /// Renders shader-state previews once per display refresh. The refresh
  /// stream keeps only the newest refresh, so a slow render skips refreshes.
  private func startRenderPump() -> Task<Void, Never> {
    let engine = configuration.engine
    let runID = configuration.executionID
    let source = source
    let controls = controls
    let frameSizeChanged = host.frameSizeChanged
    return Task.detached(priority: .userInitiated) {
      do {
        for await _ in source.refresh.stream {
          try Task.checkCancellation()
          guard controls.snapshot.isRunning,
            let frame = try await engine.liveMetalPreview(runID: runID) else { continue }
          if source.publish(frame) {
            await frameSizeChanged(CGSize(width: frame.width, height: frame.height))
          }
        }
      } catch is CancellationError {
        return
      } catch {
        controls.fail(error.localizedDescription)
      }
    }
  }

  private func makeInvocation(call: Int, cycleIndex: Int, seed: UInt64?,
    inputs: PipelineLiveRunControls.Snapshot) -> PipelineInvocation {
    let configuration = configuration
    let settings = configuration.settings
    var values: [String: PipelineInvocationValue] = configuration.usesSavedInputs ? [:] : [
      PipelineInvocation.promptKey: .string(configuration.runPrompt)
    ]
    values[PipelineInvocation.loopCallIndexKey] = .integer(Int64(cycleIndex))
    if configuration.containsGPUProgram {
      values[PipelineInvocation.gpuProgramDeferredCommitKey] = .boolean(true)
    }
    if let renderID = configuration.shaderMetalRenderID {
      if let size = inputs.metalPreviewSize {
        values[PipelineInvocation.metalPreviewWidthKey] = .integer(Int64(size.width))
        values[PipelineInvocation.metalPreviewHeightKey] = .integer(Int64(size.height))
      }
      values[PipelineInvocation.metalPreviewOnlyKey] = .boolean(
        configuration.liveNodeID == renderID && inputs.fullScreenPreviewNodeID != renderID)
      // Shader state is drawn per display refresh, interpolated toward the
      // next call's time.
      let minimumInterval = settings.limitHz.map { 1 / Double($0) } ?? 1 / 60
      let delayInterval = Double(settings.delayMilliseconds) / 1_000
      values[PipelineInvocation.metalPreviewCallIntervalKey] =
        .number(max(minimumInterval, delayInterval))
      if let timeline = configuration.shaderTimeline,
        let timeTrack = timeline.tracks.first(where: { $0.path == "/timeSeconds" }) {
        func number(_ value: PipelineValue) -> Double? {
          switch value {
          case .number(let number): number
          case .integer(let integer): Double(integer)
          default: nil
          }
        }
        let nextFrame = min(cycleIndex + 1, timeline.frameCount - 1)
        if let current = number(timeTrack.value(at: cycleIndex)),
          let next = number(timeTrack.value(at: nextFrame)) {
          values[PipelineInvocation.metalPreviewTimeStepKey] = .number(next - current)
        }
      }
    }
    if let resumeState = configuration.resumeState {
      values[PipelineInvocation.stateKey] = .string(resumeState)
    }
    if let outputSize = configuration.outputSize {
      values[PipelineInvocation.widthKey] = .integer(Int64(outputSize.width))
      values[PipelineInvocation.heightKey] = .integer(Int64(outputSize.height))
    }
    if let seed, settings.seedStrategy == .increment || !configuration.usesSavedInputs {
      values[PipelineInvocation.seedKey] = .unsignedInteger(seed)
    }
    if configuration.usesLiveProceduralTrackpad, let trackpad = inputs.trackpad {
      values[PipelineInvocation.trackpadXKey] = .number(trackpad.x)
      values[PipelineInvocation.trackpadYKey] = .number(trackpad.y)
      values[PipelineInvocation.trackpadEngagedKey] = .boolean(trackpad.engaged)
      let cycleEngagedAtCall: Int64
      if let repeatLength = configuration.repeatLength, trackpad.engaged {
        let engagedRunIndex = trackpad.engagedAtRunIndex ?? 0
        cycleEngagedAtCall = engagedRunIndex / repeatLength == (call - 1) / repeatLength
          ? Int64(engagedRunIndex % repeatLength) : 0
      } else {
        cycleEngagedAtCall = trackpad.engagedAtCall
      }
      values[PipelineInvocation.trackpadEngagedAtCallKey] = .integer(cycleEngagedAtCall)
      values[PipelineInvocation.trackpadActionCountKey] = .integer(Int64(trackpad.actionCount))
      values[PipelineInvocation.trackpadSecondaryActionCountKey] =
        .integer(Int64(trackpad.secondaryActionCount))
    }
    if let directionPad = inputs.directionPad {
      values[PipelineInvocation.directionPadXKey] = .number(directionPad.x)
      values[PipelineInvocation.directionPadYKey] = .number(directionPad.y)
      values[PipelineInvocation.directionPadKeysKey] = .integer(Int64(directionPad.keys))
    }
    return PipelineInvocation(values: values)
  }

  private static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

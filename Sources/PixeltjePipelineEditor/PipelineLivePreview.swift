import AppKit
import PixeltjePipelineEngine
import QuartzCore
import Synchronization

/// The newest completed live preview surface. A runner publishes it away from
/// the main actor and preview renderers collect it on their display refresh.
/// Only the newest frame is kept, so a slow display skips frames instead of
/// queuing them.
final class PipelineLiveFrameMailbox: Sendable {
  struct Entry: Sendable {
    let revision: UInt64
    let frame: PipelineMetalPreviewFrame
    /// Uptime nanoseconds at publication, for presentation latency.
    let publishedAt: UInt64
  }

  private struct Slot {
    var revision: UInt64 = 0
    var frame: PipelineMetalPreviewFrame?
    var publishedAt: UInt64 = 0
  }

  private let slot = Mutex(Slot())

  /// Publishes a frame and reports whether its size differs from the
  /// previously published frame.
  @discardableResult
  func publish(_ frame: PipelineMetalPreviewFrame) -> Bool {
    let publishedAt = DispatchTime.now().uptimeNanoseconds
    return slot.withLock { slot in
      let resized = slot.frame.map {
        $0.width != frame.width || $0.height != frame.height
      } ?? true
      slot.revision &+= 1
      slot.frame = frame
      slot.publishedAt = publishedAt
      return resized
    }
  }

  var hasFrame: Bool { slot.withLock { $0.frame != nil } }

  /// The newest frame, when it is not the one published at `revision`.
  func frame(after revision: UInt64) -> Entry? {
    slot.withLock { slot in
      guard slot.revision != revision, let frame = slot.frame else { return nil }
      return Entry(revision: slot.revision, frame: frame, publishedAt: slot.publishedAt)
    }
  }
}

/// Display refresh timing from the view that paces a live run. Its renderer
/// publishes it on the render thread; the runner and the shader-state render
/// pump read it without involving the main actor.
final class PipelineLiveRefreshTicks: Sendable {
  struct Timing: Sendable {
    /// Host time (`CACurrentMediaTime`) of the latest refresh callback.
    let timestamp: CFTimeInterval
    /// Seconds between the pacing view's refreshes.
    let interval: CFTimeInterval
  }

  /// Refresh timestamps, newest only.
  let stream: AsyncStream<CFTimeInterval>
  private let continuation: AsyncStream<CFTimeInterval>.Continuation
  private let latest = Mutex<Timing?>(nil)

  init() {
    let pair = AsyncStream.makeStream(
      of: CFTimeInterval.self, bufferingPolicy: .bufferingNewest(1))
    stream = pair.stream
    continuation = pair.continuation
  }

  func tick(_ timing: Timing) {
    latest.withLock { $0 = timing }
    continuation.yield(timing.timestamp)
  }

  /// Requests one render without a refresh, so a preview produces its first
  /// frame before any view exists to pace it.
  func kick() {
    continuation.yield(CACurrentMediaTime())
  }

  /// The latest refresh timing, when one arrived within `maximumAge` seconds.
  func timing(maximumAge: CFTimeInterval) -> Timing? {
    guard let timing = latest.withLock({ $0 }),
      CACurrentMediaTime() - timing.timestamp <= maximumAge else { return nil }
    return timing
  }

  func finish() {
    continuation.finish()
  }
}

/// Counts completed preview frames of one run, independent of which views are
/// currently drawing them.
final class PipelineLiveFrameRate: Sendable {
  private struct State {
    var times: [CFTimeInterval] = []
  }

  private let state = Mutex(State())

  func record(at time: CFTimeInterval) {
    state.withLock { state in
      state.times.removeAll { $0 < time - 1 }
      state.times.append(time)
    }
  }

  /// Completed preview frames per second over the last second.
  var framesPerSecond: Int {
    let now = CACurrentMediaTime()
    return state.withLock { state in
      let recent = state.times.filter { $0 >= now - 1 }
      guard let first = recent.first, let last = recent.last,
        recent.count > 1, last > first else { return 0 }
      return Int((Double(recent.count - 1) / (last - first)).rounded())
    }
  }
}

/// One live run's frames and display timing, shared by its runner and the
/// preview renderers on the render thread.
final class PipelineLivePreviewSource: Sendable {
  let runID: UUID
  let frames = PipelineLiveFrameMailbox()
  let refresh = PipelineLiveRefreshTicks()
  let frameRate = PipelineLiveFrameRate()
  /// The refresh rate preview views request; nil uses the display's maximum.
  let preferredFramesPerSecond: Int?
  let performanceLog: PipelineEditorPerformanceLog?
  private let active = Mutex(true)

  init(runID: UUID, preferredFramesPerSecond: Int?,
    performanceLog: PipelineEditorPerformanceLog?) {
    self.runID = runID
    self.preferredFramesPerSecond = preferredFramesPerSecond
    self.performanceLog = performanceLog
  }

  /// Reports each completed frame once, even when several views display it.
  @discardableResult
  func publish(_ frame: PipelineMetalPreviewFrame) -> Bool {
    let resized = frames.publish(frame)
    frameRate.record(at: CACurrentMediaTime())
    return resized
  }

  /// False once the run ends; views then draw its last frame and idle.
  var isActive: Bool { active.withLock { $0 } }

  func finish() {
    active.withLock { $0 = false }
    refresh.finish()
  }
}

/// Connects preview views to the current live run. The views draw on the
/// preview render thread; this registry only hands them the run's source and
/// chooses which visible view paces the run.
@MainActor
final class PipelineLivePreviewPresenter {
  private final class WeakView {
    weak var view: PipelineMetalPreviewLayerView?
    init(_ view: PipelineMetalPreviewLayerView) { self.view = view }
  }

  /// Attached views, oldest first.
  private var attached: [WeakView] = []
  private var source: PipelineLivePreviewSource?
  private weak var pacingView: PipelineMetalPreviewLayerView?

  private var views: [PipelineMetalPreviewLayerView] { attached.compactMap(\.view) }

  /// Completed preview frames per second of the current or last run.
  var framesPerSecond: Int { source?.frameRate.framesPerSecond ?? 0 }

  func begin(_ source: PipelineLivePreviewSource) {
    clear()
    self.source = source
    for view in views { view.renderer.setSource(source) }
    choosePacingView()
  }

  /// Ends a run. Its last frame stays visible until `clear()`.
  func finish(runID: UUID) {
    guard let source, source.runID == runID else { return }
    source.finish()
    for view in views { view.renderer.sourceDidFinish() }
  }

  func clear() {
    source?.finish()
    source = nil
    for view in views { view.renderer.setSource(nil) }
  }

  func attach(_ view: PipelineMetalPreviewLayerView) {
    attached.removeAll { $0.view == nil || $0.view === view }
    attached.append(WeakView(view))
    view.renderer.setSource(source)
    choosePacingView()
  }

  func detach(_ view: PipelineMetalPreviewLayerView) {
    attached.removeAll { $0.view == nil || $0.view === view }
    view.renderer.setPacing(false)
    view.renderer.setSource(nil)
    choosePacingView()
  }

  func visibilityDidChange(_ view: PipelineMetalPreviewLayerView) {
    choosePacingView()
  }

  /// The newest visible view paces the run; it is usually the one being
  /// watched, such as a full-screen preview opened over its card.
  private func choosePacingView() {
    let views = views
    let next = views.last(where: \.isPreviewVisible)
    guard next !== pacingView else { return }
    pacingView = next
    for view in views { view.renderer.setPacing(view === next) }
  }
}

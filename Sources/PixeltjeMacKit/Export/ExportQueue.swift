import Foundation
import PixeltjeMacDomain

/// One queued export, as the panel sees it.
///
/// A job is a value: the queue publishes an array of these into `EditorModel`,
/// so the panel observes the same model as every other view and never holds a
/// reference to the machinery that runs the work.
public struct ExportJob: Identifiable, Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case waiting
    case running(Double)
    case finished
    case failed(String)
    case cancelled

    public var isActive: Bool {
      switch self {
      case .waiting, .running: true
      case .finished, .failed, .cancelled: false
      }
    }
  }

  public let id: UUID
  public let filename: String
  public let destination: URL
  public let presetName: String
  public let summary: String
  public let queuedAt: Date
  public var state: State

  public init(
    id: UUID = UUID(),
    filename: String,
    destination: URL,
    presetName: String,
    summary: String,
    queuedAt: Date = Date(),
    state: State = .waiting
  ) {
    self.id = id
    self.filename = filename
    self.destination = destination
    self.presetName = presetName
    self.summary = summary
    self.queuedAt = queuedAt
    self.state = state
  }

  public var progress: Double {
    switch state {
    case .waiting: 0
    case .running(let value): value
    case .finished: 1
    case .failed, .cancelled: 0
    }
  }

  public var statusText: String {
    switch state {
    case .waiting: "Waiting"
    case .running(let value): "Exporting \(Int((value * 100).rounded()))%"
    case .finished: "Exported"
    case .failed(let message): message
    case .cancelled: "Cancelled"
    }
  }
}

/// Runs exports behind the document while the user keeps editing.
///
/// Each job carries the recipe as it stood when it was queued, so later edits
/// neither change nor invalidate a queued export: it writes what the user asked
/// for. A cancelled job stops at the next checkpoint and never publishes a
/// file, because the render engine writes to a temporary path and moves it into
/// place only after a final cancellation check.
@MainActor
public final class ExportQueue {
  /// How many exports render at once.
  ///
  /// More than one keeps a small batch moving while a large RAW develops;
  /// many more would fight the interactive render for the same GPU.
  public static let maximumConcurrentExports = 2

  private struct QueuedExport {
    var job: ExportJob
    var request: RenderRequest
    var preset: ExportPreset
  }

  private let renderEngine: RenderEngine?
  private let onChange: @MainActor ([ExportJob]) -> Void
  private var queue: [QueuedExport] = []
  private var tasks: [UUID: Task<Void, Never>] = [:]

  public init(
    renderEngine: RenderEngine?,
    onChange: @escaping @MainActor ([ExportJob]) -> Void
  ) {
    self.renderEngine = renderEngine
    self.onChange = onChange
  }

  public var jobs: [ExportJob] { queue.map(\.job) }

  public var hasActiveJobs: Bool { queue.contains { $0.job.state.isActive } }

  /// Adds one export and starts it as soon as a slot is free.
  @discardableResult
  public func enqueue(
    request: RenderRequest,
    preset: ExportPreset,
    destination: URL
  ) -> ExportJob {
    let job = ExportJob(
      filename: destination.lastPathComponent,
      destination: destination,
      presetName: preset.name,
      summary: preset.summary
    )
    queue.append(QueuedExport(job: job, request: request, preset: preset))
    publish()
    startEligibleJobs()
    return job
  }

  /// Stops a job, whether it is waiting or already rendering.
  public func cancel(_ id: UUID) {
    guard let index = queue.firstIndex(where: { $0.job.id == id }),
      queue[index].job.state.isActive
    else { return }
    tasks[id]?.cancel()
    tasks[id] = nil
    queue[index].job.state = .cancelled
    publish()
    startEligibleJobs()
  }

  public func cancelAll() {
    for job in queue where job.job.state.isActive { cancel(job.job.id) }
  }

  /// Removes one finished, failed or cancelled row.
  public func remove(_ id: UUID) {
    guard let index = queue.firstIndex(where: { $0.job.id == id }) else { return }
    guard !queue[index].job.state.isActive else { return }
    queue.remove(at: index)
    publish()
  }

  public func clearCompleted() {
    queue.removeAll { !$0.job.state.isActive }
    publish()
  }

  private func startEligibleJobs() {
    while tasks.count < Self.maximumConcurrentExports,
      let index = queue.firstIndex(where: { $0.job.state == .waiting })
    {
      start(at: index)
    }
  }

  private func start(at index: Int) {
    let item = queue[index]
    let id = item.job.id
    queue[index].job.state = .running(0)
    publish()

    guard let renderEngine else {
      finish(id, with: .failed("Metal rendering is unavailable."))
      return
    }
    let request = item.request
    let preset = item.preset
    let destination = item.job.destination
    // The render actor calls this from its own executor, so the update hops
    // back to the main actor before it touches the queue.
    let report: @Sendable (Double) -> Void = { [weak self] fraction in
      Task { @MainActor in self?.report(id, progress: fraction) }
    }
    tasks[id] = Task { [weak self] in
      do {
        // The heavy work happens inside the render actor, off the main actor:
        // this task only awaits it and reports what comes back.
        try await renderEngine.export(
          request, preset: preset, to: destination, progress: report)
        self?.finish(id, with: .finished)
      } catch is CancellationError {
        self?.finish(id, with: .cancelled)
      } catch {
        self?.finish(id, with: .failed(error.userFacingMessage))
      }
    }
  }

  private func report(_ id: UUID, progress: Double) {
    guard let index = queue.firstIndex(where: { $0.job.id == id }) else { return }
    guard case .running(let current) = queue[index].job.state else { return }
    let clamped = max(0, min(1, progress))
    // Progress only moves forward, so a late callback cannot rewind the bar.
    guard clamped > current else { return }
    queue[index].job.state = .running(clamped)
    publish()
  }

  private func finish(_ id: UUID, with state: ExportJob.State) {
    tasks[id] = nil
    if let index = queue.firstIndex(where: { $0.job.id == id }) {
      // A job cancelled while its task was already unwinding keeps that answer:
      // the file was never published, so "cancelled" is what happened.
      if queue[index].job.state.isActive {
        queue[index].job.state = state
      }
    }
    publish()
    startEligibleJobs()
  }

  private func publish() {
    onChange(jobs)
  }
}

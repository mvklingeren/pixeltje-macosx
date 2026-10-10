import Combine
import Foundation
import PixeltjeMacDomain

enum ComfyUIHistoryStatus: String, Codable, Equatable, Sendable {
  case queued
  case running
  case succeeded
  case cancelled
  case failed
  case interrupted

  var label: String {
    switch self {
    case .queued: "Queued"
    case .running: "Running"
    case .succeeded: "Complete"
    case .cancelled: "Cancelled"
    case .failed: "Failed"
    case .interrupted: "Interrupted"
    }
  }

  var isTerminal: Bool {
    switch self {
    case .queued, .running: false
    case .succeeded, .cancelled, .failed, .interrupted: true
    }
  }
}

/// One app-level record of a validated ComfyUI task.
///
/// History deliberately contains only the reusable editor intent. Source
/// pixels, masks, debug logs, server URLs, credentials, and temporary upload
/// names remain outside it.
struct ComfyUIHistoryEntry: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var queuedAt: Date
  var finishedAt: Date?
  var status: ComfyUIHistoryStatus
  var statusDetail: String?
  var backendID: String?
  var executionTarget: ComfyUIExecutionTarget
  var templateID: String
  var templateRevision: String
  var mode: GenerationMode
  var prompt: String
  var generationSettings: InpaintingToolState
  /// Only inputs that differed from the bundled workflow defaults when the
  /// request was frozen. The positive prompt is stored separately above.
  var modifiedParameters: [ComfyUIParameterRecord]

  var workflowName: String {
    ComfyUIWorkflowCatalog.templates.first(where: { $0.id == templateID })?.name
      ?? templateID
  }

  /// Wall-clock time from submission until the job reached a terminal state.
  ///
  /// `queuedAt` is also the start timestamp: ComfyUI history only accepts one
  /// active generation, and its task starts as soon as the entry is recorded.
  var elapsedSeconds: TimeInterval? {
    guard let finishedAt else { return nil }
    return max(finishedAt.timeIntervalSince(queuedAt), 0)
  }
}

/// Generation history shared by every document and persisted outside projects.
///
/// Active ComfyUI jobs remain document-session state. The store records their
/// reusable intent and terminal outcome, but it never reconnects or resumes a
/// job after launch.
@MainActor
final class ComfyUIHistoryStore: ObservableObject {
  private struct Archive: Codable {
    var version: Int
    var entries: [ComfyUIHistoryEntry]
  }

  static let shared = ComfyUIHistoryStore()

  @Published private(set) var entries: [ComfyUIHistoryEntry]
  @Published private(set) var persistenceError: String?

  private let fileURL: URL
  private let preferences: UserDefaults
  private let fileManager: FileManager

  init(
    fileURL: URL = ComfyUIHistoryStore.defaultStorageURL,
    preferences: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.preferences = preferences
    self.fileManager = fileManager

    do {
      let data = try Data(contentsOf: fileURL)
      let archive = try JSONDecoder().decode(Archive.self, from: data)
      guard archive.version == 1 else {
        throw CocoaError(.fileReadCorruptFile)
      }
      self.entries = archive.entries.sorted { $0.queuedAt > $1.queuedAt }
      self.persistenceError = nil
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      self.entries = []
      self.persistenceError = nil
    } catch {
      self.entries = []
      self.persistenceError = "Generation history could not be read: \(error.localizedDescription)"
    }

    let interruptedAt = Date()
    var changed = false
    for index in entries.indices where !entries[index].status.isTerminal {
      entries[index].status = .interrupted
      entries[index].statusDetail = "Pixeltje closed before this task reached a terminal state."
      entries[index].finishedAt = interruptedAt
      changed = true
    }
    if changed { persist() }
  }

  func record(_ entry: ComfyUIHistoryEntry) {
    guard !AppSettings.storedDisablesComfyUIHistory(in: preferences) else { return }
    entries.removeAll { $0.id == entry.id }
    entries.insert(entry, at: 0)
    persist()
  }

  func update(jobID: UUID, state: GenerationJobState) {
    guard let index = entries.firstIndex(where: { $0.id == jobID }) else { return }
    var updated = entries[index]
    switch state {
    case .queued:
      updated.status = .queued
      updated.statusDetail = nil
      updated.finishedAt = nil
    case .preparing, .uploading, .loadingModel, .denoising, .finalizing:
      updated.status = .running
      updated.statusDetail = nil
      updated.finishedAt = nil
    case .succeeded:
      updated.finishedAt = updated.status == .succeeded ? updated.finishedAt : Date()
      updated.status = .succeeded
      updated.statusDetail = nil
    case .cancelled:
      updated.finishedAt = updated.status == .cancelled ? updated.finishedAt : Date()
      updated.status = .cancelled
      updated.statusDetail = nil
    case .failed(let message):
      updated.finishedAt = updated.status == .failed ? updated.finishedAt : Date()
      updated.status = .failed
      updated.statusDetail = message
    }
    guard updated != entries[index] else { return }
    entries[index] = updated
    persist()
  }

  func setBackendID(_ backendID: String, for jobID: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == jobID }) else { return }
    guard entries[index].backendID != backendID else { return }
    entries[index].backendID = backendID
    persist()
  }

  func clear() {
    let previousEntries = entries
    do {
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.removeItem(at: fileURL)
      }
      entries = []
      persistenceError = nil
    } catch {
      entries = previousEntries
      persistenceError = "Generation history could not be cleared: \(error.localizedDescription)"
    }
  }

  private func persist() {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(Archive(version: 1, entries: entries))
      try data.write(to: fileURL, options: .atomic)
      persistenceError = nil
    } catch {
      persistenceError = "Generation history could not be saved: \(error.localizedDescription)"
    }
  }

  private static var defaultStorageURL: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("Pixeltje", isDirectory: true)
      .appendingPathComponent("comfyui-history.json", isDirectory: false)
  }
}

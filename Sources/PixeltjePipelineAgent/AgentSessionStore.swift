import Darwin
import Foundation
import FoundationModels

struct StoredAgentSession: Codable {
  let version: Int
  let sessionID: String
  let cwd: String
  let modelID: String?
  let packageID: String?
  let packageVersion: String?
  let modelWorkflowCalls: Bool?
  let directImageWorkflow: String?
  let transcript: Transcript?
  let replayUpdates: [Data]
  let pendingWorkflowResult: String?
}

/// ACP session state is private user data. Keep it outside the project and
/// write complete turns atomically so an interrupted generation cannot replace
/// the last usable transcript.
struct AgentSessionStore {
  let directory: URL

  init(directory: URL) throws {
    self.directory = directory.standardizedFileURL
    try FileManager.default.createDirectory(
      at: self.directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
  }

  func load(id: String) throws -> StoredAgentSession {
    let url = try fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AgentError.invalidRequest(
        "No saved ACP session exists for this chat. Start a new conversation.")
    }
    let saved = try JSONDecoder().decode(
      StoredAgentSession.self, from: Data(contentsOf: url))
    guard saved.version == 1, saved.sessionID == id else {
      throw AgentError.invalidRequest("The saved ACP session is incompatible or changed.")
    }
    return saved
  }

  func save(_ session: StoredAgentSession) throws {
    let destination = try fileURL(for: session.sessionID)
    let data = try JSONEncoder().encode(session)
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    var isOpen = true
    do {
      try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
          let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
          guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
          offset += count
        }
      }
      guard fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      guard close(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      isOpen = false
      guard rename(temporary.path, destination.path) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
    } catch {
      if isOpen { _ = close(descriptor) }
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private func fileURL(for id: String) throws -> URL {
    guard UUID(uuidString: id) != nil else {
      throw AgentError.invalidRequest("Invalid ACP session ID.")
    }
    return directory.appendingPathComponent("\(id).json")
  }
}

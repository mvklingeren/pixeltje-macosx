import Foundation

/// Failure-only diagnostics for local Core AI text generation. Prompt and
/// partial output are kept out of the unified system log.
struct CoreAITextFailureLog {
  struct Record: Encodable {
    let formatVersion = 1
    let recordedAt: Date
    let modelPackageID: String
    let modelPackageVersion: String
    let attempt: Int
    let willRetry: Bool
    let requestedSeed: UInt64
    let effectiveSeed: UInt64
    let temperature: Double
    let topK: Int
    let maximumResponseTokens: Int
    let prompt: String
    let systemPrompt: String
    let previousPrompt: String?
    let previousResponse: String?
    let partialGeneratedText: String
    let inputTokenCount: Int?
    let outputTokenCount: Int?
    let errorType: String
    let errorDescription: String
    let errorDebugDescription: String
    let errorDomain: String
    let errorCode: Int
    let underlyingErrorDescription: String?
    let underlyingErrorDomain: String?
    let underlyingErrorCode: Int?
  }

  static var directory: URL {
    let library = FileManager.default.urls(
      for: .libraryDirectory, in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
    return library
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Pixeltje", isDirectory: true)
      .appendingPathComponent("CoreAIText", isDirectory: true)
  }

  static func write(_ record: Record) throws -> URL {
    let fileManager = FileManager.default
    let directory = Self.directory
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let url = directory.appendingPathComponent(
      "failure-\(UUID().uuidString.lowercased()).json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

    // Keep a bounded set of failure records without touching other log files.
    let files = (try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let failures = files
      .filter { $0.lastPathComponent.hasPrefix("failure-") && $0.pathExtension == "json" }
      .sorted {
        let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        return (lhs ?? .distantPast) > (rhs ?? .distantPast)
      }
    for oldFile in failures.dropFirst(20) {
      try? fileManager.removeItem(at: oldFile)
    }
    return url
  }
}

import Foundation

/// An opt-in, session-scoped copy of the Prompt Box's ComfyUI diagnostics.
///
/// The editor model remains the bounded presentation store. This actor owns
/// persistent diagnostic I/O so SwiftUI never writes files and transport
/// callbacks never block the main actor.
actor ComfyUIDebugDiskLogger {
  private struct Manifest: Codable {
    var formatVersion = 1
    var createdAt: Date
    var documentID: UUID
    var transcript = "request.log"
    var imagesDirectory = "images"
  }

  private let documentID: UUID
  private let createdAt: Date
  private let rootDirectory: URL
  private var sessionDirectory: URL?
  private var pendingEvents: [ComfyUIDebugEvent] = []
  private var pendingImages: [ComfyUIDebugImage] = []
  private var imageSequence = 0

  init(
    documentID: UUID,
    createdAt: Date = Date(),
    rootDirectory: URL = ComfyUIDebugDiskLogger.defaultRootDirectory
  ) {
    self.documentID = documentID
    self.createdAt = createdAt
    self.rootDirectory = rootDirectory
  }

  func start(
    existingEvents: [ComfyUIDebugEvent],
    existingImages: [ComfyUIDebugImage]
  ) throws -> URL {
    if let sessionDirectory { return sessionDirectory }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: rootDirectory, withIntermediateDirectories: true)
    let directory = rootDirectory.appendingPathComponent(
      Self.sessionName(createdAt: createdAt, documentID: documentID),
      isDirectory: true)
    let imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
    try fileManager.createDirectory(
      at: imagesDirectory, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(
      Manifest(createdAt: createdAt, documentID: documentID)
    ).write(
      to: directory.appendingPathComponent("manifest.json"),
      options: .atomic)

    let allEvents = existingEvents + pendingEvents
    let transcript = allEvents.map(\.transcriptText).joined(separator: "\n\n")
    let initialText = transcript.isEmpty ? "" : transcript + "\n\n"
    try Data(initialText.utf8).write(
      to: directory.appendingPathComponent("request.log"),
      options: .atomic)

    sessionDirectory = directory
    pendingEvents.removeAll()
    let allImages = existingImages + pendingImages
    pendingImages.removeAll()
    for image in allImages {
      try write(image, to: imagesDirectory)
    }
    return directory
  }

  func append(_ event: ComfyUIDebugEvent) throws {
    guard let sessionDirectory else {
      pendingEvents.append(event)
      return
    }
    let url = sessionDirectory.appendingPathComponent("request.log")
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((event.transcriptText + "\n\n").utf8))
  }

  func append(_ image: ComfyUIDebugImage) throws {
    guard let sessionDirectory else {
      pendingImages.append(image)
      return
    }
    try write(
      image,
      to: sessionDirectory.appendingPathComponent("images", isDirectory: true))
  }

  nonisolated static var defaultRootDirectory: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("Pixeltje", isDirectory: true)
      .appendingPathComponent("ComfyUI Debug Logs", isDirectory: true)
  }

  private func write(_ image: ComfyUIDebugImage, to directory: URL) throws {
    imageSequence += 1
    let sequence = String(format: "%03d", imageSequence)
    let label = Self.safeFilenameComponent(image.label)
    let filename = "\(sequence)-\(label).\(Self.imageExtension(for: image.imageData))"
    try image.imageData.write(
      to: directory.appendingPathComponent(filename),
      options: .atomic)
  }

  private nonisolated static func sessionName(createdAt: Date, documentID: UUID) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
    return "\(formatter.string(from: createdAt))-\(documentID.uuidString.prefix(8).lowercased())"
  }

  private nonisolated static func safeFilenameComponent(_ value: String) -> String {
    let lowered = value.folding(
      options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
    var result = ""
    var previousWasSeparator = false
    for scalar in lowered.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        result.unicodeScalars.append(scalar)
        previousWasSeparator = false
      } else if !previousWasSeparator, !result.isEmpty {
        result.append("-")
        previousWasSeparator = true
      }
    }
    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String((trimmed.isEmpty ? "image" : trimmed).prefix(80))
  }

  private nonisolated static func imageExtension(for data: Data) -> String {
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if bytes.count >= 12,
      Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],
      Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
    {
      return "webp"
    }
    return "bin"
  }
}

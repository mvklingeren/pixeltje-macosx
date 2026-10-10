import Foundation
import Testing

@testable import PixeltjeMacKit

@Test func comfyUIDebugDiskLoggerWritesTranscriptManifestAndImages() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "Pixeltje-ComfyUI-Debug-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
  let logger = ComfyUIDebugDiskLogger(
    documentID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    createdAt: timestamp,
    rootDirectory: root)
  let existing = ComfyUIDebugEvent(
    timestamp: timestamp,
    stage: "Preflight",
    message: "Existing request details")
  let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

  let directory = try await logger.start(
    existingEvents: [existing],
    existingImages: [
      ComfyUIDebugImage(
        timestamp: timestamp,
        label: "Sent to ComfyUI — source",
        imageData: png)
    ])
  try await logger.append(
    ComfyUIDebugEvent(
      timestamp: timestamp,
      stage: "Submission",
      message: "POST /prompt"))
  try await logger.append(
    ComfyUIDebugImage(
      timestamp: timestamp,
      label: "Returned by ComfyUI — raw output",
      imageData: png))

  let transcript = try String(
    contentsOf: directory.appendingPathComponent("request.log"),
    encoding: .utf8)
  #expect(transcript.contains("[Preflight]"))
  #expect(transcript.contains("Existing request details"))
  #expect(transcript.contains("[Submission]"))
  #expect(transcript.contains("POST /prompt"))
  #expect(
    FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("manifest.json").path))

  let imageNames = try FileManager.default.contentsOfDirectory(
    at: directory.appendingPathComponent("images", isDirectory: true),
    includingPropertiesForKeys: nil
  ).map(\.lastPathComponent).sorted()
  #expect(imageNames.count == 2)
  #expect(imageNames[0].hasSuffix("sent-to-comfyui-source.png"))
  #expect(imageNames[1].hasSuffix("returned-by-comfyui-raw-output.png"))
}

@MainActor
@Test func promptBoxCanEnableAndDescribeComfyUIDiskLogging() {
  var requested: [Bool] = []
  let model = PromptBoxModel(
    onSetComfyUIDebugDiskLoggingEnabled: { requested.append($0) })

  model.setComfyUIDebugDiskLoggingEnabled(true)
  #expect(requested == [true])

  let directory = URL(fileURLWithPath: "/tmp/Pixeltje Debug")
  model.setComfyUIDebugDiskLoggingState(.enabled(directory))
  #expect(model.comfyUIDebugDiskLoggingState.isRequested)
  #expect(model.comfyUIDebugDiskLoggingStatus?.contains("request.log") == true)
  #expect(model.comfyUIDebugDiskLoggingStatus?.contains("/tmp/Pixeltje Debug") == true)
}

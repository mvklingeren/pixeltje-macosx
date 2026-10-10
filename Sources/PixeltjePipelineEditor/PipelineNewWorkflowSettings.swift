import AppKit
import Combine
import Foundation
import PixeltjePipelineDomain
import SwiftUI

@MainActor
final class PipelineNewWorkflowSettings: ObservableObject {
  private static let bookmarkKey = "PipelineEditor.newWorkflowBookmark"
  private static let debugModeKey = "PipelineEditor.debugModeEnabled"
  private static let saveGeneratedImagesKey = "PipelineEditor.saveGeneratedImagesToDisk"
  private static let highlightNodesKey = "PipelineEditor.highlightNodesOnExecution"
  private static let showExecutionSpeedKey = "PipelineEditor.showExecutionSpeedPerNode"
  private static let defaultFilename = "default.pixpipeline.json"

  @Published private(set) var bookmarkData: Data?
  @Published var debugModeEnabled: Bool {
    didSet { preferences.set(debugModeEnabled, forKey: Self.debugModeKey) }
  }
  @Published var saveGeneratedImagesToDisk: Bool {
    didSet { preferences.set(saveGeneratedImagesToDisk, forKey: Self.saveGeneratedImagesKey) }
  }
  @Published var highlightNodesOnExecution: Bool {
    didSet { preferences.set(highlightNodesOnExecution, forKey: Self.highlightNodesKey) }
  }
  @Published var showExecutionSpeedPerNode: Bool {
    didSet { preferences.set(showExecutionSpeedPerNode, forKey: Self.showExecutionSpeedKey) }
  }
  private let preferences: UserDefaults

  init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
    bookmarkData = preferences.data(forKey: Self.bookmarkKey)
    debugModeEnabled = preferences.bool(forKey: Self.debugModeKey)
    saveGeneratedImagesToDisk = preferences.bool(forKey: Self.saveGeneratedImagesKey)
    highlightNodesOnExecution = preferences.object(forKey: Self.highlightNodesKey) as? Bool ?? true
    showExecutionSpeedPerNode = preferences.object(forKey: Self.showExecutionSpeedKey) as? Bool ?? true
  }

  var selectedName: String {
    guard bookmarkData != nil else { return "default" }
    guard let url = try? customURL() else { return "Unavailable workflow" }
    return url.lastPathComponent.replacingOccurrences(of: ".pixpipeline.json", with: "")
  }

  var selectedLocation: String {
    guard bookmarkData != nil else { return "Examples/\(Self.defaultFilename)" }
    return (try? customURL().path) ?? "The selected workflow is unavailable."
  }

  var usesDefault: Bool { bookmarkData == nil }

  func select(_ url: URL) throws {
    guard url.lastPathComponent.hasSuffix(".pixpipeline.json") else {
      throw NewWorkflowError.invalidFilename
    }
    _ = try load(url)
    let bookmark = try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    preferences.set(bookmark, forKey: Self.bookmarkKey)
    bookmarkData = bookmark
  }

  func useDefault() {
    preferences.removeObject(forKey: Self.bookmarkKey)
    bookmarkData = nil
  }

  func makeNewDocument() throws -> PipelineDocument {
    let url = try selectedWorkflowURL()
    var document = try load(url)
    document.id = PipelineID(rawValue: UUID().uuidString)
    return document
  }

  func selectedWorkflowURL() throws -> URL {
    try bookmarkData == nil ? bundledDefaultURL() : customURL()
  }

  func makeBundledNewDocument() throws -> PipelineDocument {
    var document = try load(bundledDefaultURL())
    document.id = PipelineID(rawValue: UUID().uuidString)
    return document
  }

  private func customURL() throws -> URL {
    guard let bookmarkData else { throw NewWorkflowError.unavailable }
    var stale = false
    return try URL(
      resolvingBookmarkData: bookmarkData, options: .withSecurityScope,
      relativeTo: nil, bookmarkDataIsStale: &stale)
  }

  private func bundledDefaultURL() throws -> URL {
    let bundleURL = Bundle.main.resourceURL?
      .appendingPathComponent("Examples", isDirectory: true)
      .appendingPathComponent(Self.defaultFilename)
    if let bundleURL, FileManager.default.fileExists(atPath: bundleURL.path) {
      return bundleURL
    }
    // `swift run` does not make the app bundle; use this source tree's Examples.
    let sourceTreeURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Examples", isDirectory: true)
      .appendingPathComponent(Self.defaultFilename)
    guard FileManager.default.fileExists(atPath: sourceTreeURL.path) else {
      throw NewWorkflowError.missingDefault
    }
    return sourceTreeURL
  }

  private func load(_ url: URL) throws -> PipelineDocument {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let document = try PipelineJSON.decode(Data(contentsOf: url))
    guard document.schemaVersion == PipelineDocument.currentSchemaVersion else {
      throw NewWorkflowError.unsupportedSchema
    }
    return document
  }
}

private enum NewWorkflowError: LocalizedError {
  case invalidFilename
  case unavailable
  case missingDefault
  case unsupportedSchema

  var errorDescription: String? {
    switch self {
    case .invalidFilename: "Choose a .pixpipeline.json workflow."
    case .unavailable: "The selected New workflow is unavailable. Choose another in Settings."
    case .missingDefault: "Examples/default.pixpipeline.json is missing."
    case .unsupportedSchema: "This workflow uses an unsupported pipeline schema."
    }
  }
}

struct PipelineNewWorkflowSettingsView: View {
  @ObservedObject var settings: PipelineNewWorkflowSettings
  let chooseWorkflow: () -> Void

  var body: some View {
    Form {
      LabeledContent("New workflow") {
        Text(settings.selectedName)
      }
      Text(settings.selectedLocation)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      HStack {
        Button("Choose Workflow…", action: chooseWorkflow)
        Button("Use Default") { settings.useDefault() }
          .disabled(settings.usesDefault)
      }
      Toggle("Capture node inputs and outputs during execution", isOn: $settings.debugModeEnabled)
      Text("Debug logs can contain prompts and image previews. The setting applies to the next run.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Toggle("Always save generated images to disk", isOn: $settings.saveGeneratedImagesToDisk)
      Text("When off, completed images are previewed in memory. Applies to the next run.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Toggle("Highlight nodes on execution", isOn: $settings.highlightNodesOnExecution)
      Toggle("Show execution speed per node", isOn: $settings.showExecutionSpeedPerNode)
    }
    .formStyle(.grouped)
    .frame(width: 500, height: 390)
  }
}

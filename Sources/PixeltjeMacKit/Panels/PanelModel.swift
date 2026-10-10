import Combine
import SwiftUI

/// Names one section of a side panel.
///
/// Identifiers are declared here so that two features cannot claim the same
/// section by accident, and so the intended order of the panels is readable in
/// one place. Which panel a section is installed into is the window
/// controller's decision, not the identifier's.
public struct PanelSectionID: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  // Left panel: settings for the active tool sit closest to the toolbar that
  // selected it, with the settings for what is being generated below them.
  public static let toolSettings = PanelSectionID("tool-settings")
  public static let cropSettings = PanelSectionID("crop-settings")
  public static let generationSettings = PanelSectionID("generation-settings")
  public static let presets = PanelSectionID("presets")
  // Assistance panel: how the work is going rather than what the document is.
  public static let history = PanelSectionID("history")
  public static let snapshots = PanelSectionID("snapshots")
  public static let exportQueue = PanelSectionID("export-queue")
  public static let generationQueue = PanelSectionID("generation-queue")
  // Develop panel: settings for the selected RAW, linked-image, or paint layer.
  // It is a separate home from the document inspector and assistance panel.
  public static let comfyUI = PanelSectionID("comfy-ui")
  public static let development = PanelSectionID("development")
}

/// Where a section sits within its panel.
///
/// Sections are installed independently and sorted by this number, so a feature
/// can add its own without knowing which other sections exist. Leave gaps. The
/// numbers run across both panels, so a section can be moved from one to the
/// other without renumbering anything.
public enum PanelOrder {
  public static let toolSettings = 100
  public static let cropSettings = 150
  public static let generationSettings = 200
  public static let presets = 300
  public static let history = 400
  public static let snapshots = 410
  public static let exportQueue = 500
  public static let generationQueue = 510
  public static let comfyUI = 600
  public static let development = 650
}

/// One collapsible section of a side panel.
///
/// The section owns nothing but its own SwiftUI content. It cannot reach the
/// document: like every other view here it is handed a view model and emits
/// typed actions through whatever closure its content captured.
public struct PanelSection: Identifiable {
  public let id: PanelSectionID
  public let title: String
  public let systemImage: String?
  public let order: Int
  public let startsExpanded: Bool
  public let content: AnyView

  public init<Content: View>(
    id: PanelSectionID,
    title: String,
    systemImage: String? = nil,
    order: Int,
    startsExpanded: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.order = order
    self.startsExpanded = startsExpanded
    self.content = AnyView(content())
  }
}

/// The contents of one side panel in one window.
///
/// Features install their own section and forget about the host. The model
/// keeps the list sorted by `order`, so installation order does not matter and
/// two features never have to agree about who runs first.
@MainActor
public final class PanelModel: ObservableObject {
  @Published public private(set) var sections: [PanelSection] = []

  public init() {}

  /// Adds a section, or replaces the one already registered under its ID.
  public func install(_ section: PanelSection) {
    if let index = sections.firstIndex(where: { $0.id == section.id }) {
      sections[index] = section
    } else {
      sections.append(section)
    }
    sections.sort { $0.order < $1.order }
  }

  public func remove(_ id: PanelSectionID) {
    sections.removeAll { $0.id == id }
  }

  public func contains(_ id: PanelSectionID) -> Bool {
    sections.contains { $0.id == id }
  }
}

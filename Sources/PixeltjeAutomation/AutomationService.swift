import Foundation

/// The protocol-neutral automation surface of the editor.
///
/// Implementations own live application state. MCP, Shortcuts and future
/// script adapters are deliberately only clients of this interface.
@MainActor
public protocol PixeltjeAutomationService: AnyObject {
  func listDocuments(context: AutomationRequestContext) throws -> [AutomationDocumentSummary]
  func getDocument(
    id: String,
    context: AutomationRequestContext
  ) throws -> AutomationDocumentSnapshot
  func listLayers(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> [AutomationLayerSnapshot]
  func getDevelopSettings(
    documentID: String,
    layerID: String,
    context: AutomationRequestContext
  ) throws -> AutomationDevelopSnapshot
  func getHistory(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> AutomationHistorySnapshot
  func getHistogram(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> AutomationHistogramSnapshot
  func listJobs(
    documentID: String,
    context: AutomationRequestContext
  ) throws -> [AutomationJobSnapshot]
  func execute(
    _ command: AutomationCommand,
    context: AutomationRequestContext
  ) throws -> AutomationMutationReceipt
}

extension AutomationRequestContext {
  public func require(_ scope: AutomationScope) throws {
    guard scopes.contains(scope) else {
      throw AutomationServiceError(
        .accessDenied,
        "The automation client does not have the \(scope.rawValue) scope."
      )
    }
  }
}

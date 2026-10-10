import Foundation
import PixeltjeAutomation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func automationLayerPatchIsOneRevisionAndOneUndoStep() throws {
  let document = ProjectDocument()
  let layerID = ProjectLayerID(rawValue: "automation-layer")
  document.perform(.addLayer(.group(id: layerID, name: "Automated Group")), interactive: false)
  let controller = ProjectAutomationController(documentsProvider: { [document] })
  let context = AutomationRequestContext(clientID: "test", scopes: [.read, .edit])
  let before = try controller.getDocument(id: document.projectID.uuidString, context: context)
  let historyCount = document.editorModel.history.steps.count

  let command = AutomationCommand.updateLayer(
    AutomationLayerPatch(
      documentID: document.projectID.uuidString,
      layerID: layerID.rawValue,
      expectedRevision: before.document.contentRevision,
      idempotencyKey: "layer-patch-1",
      isEnabled: false,
      blendMode: "multiply",
      opacity: 0.4,
      fill: 0.75
    )
  )
  let receipt = try controller.execute(command, context: context)

  #expect(receipt.changed)
  #expect(receipt.afterRevision == receipt.beforeRevision + 1)
  #expect(document.editorModel.history.steps.count == historyCount + 1)
  let changed = try #require(document.editorModel.recipe.layerStack.layer(id: layerID))
  #expect(changed.isEnabled == false)
  #expect(changed.blendMode == .multiply)
  #expect(changed.opacity == 0.4)
  #expect(changed.fill == 0.75)

  let retry = try controller.execute(command, context: context)
  #expect(retry == receipt)
  #expect(document.editorModel.history.steps.count == historyCount + 1)
}

@MainActor
@Test func automationRejectsStaleRevisionWithoutChangingRecipe() throws {
  let document = ProjectDocument()
  let layerID = ProjectLayerID(rawValue: "stale-layer")
  document.perform(.addLayer(.group(id: layerID)), interactive: false)
  let controller = ProjectAutomationController(documentsProvider: { [document] })
  let context = AutomationRequestContext(clientID: "test", scopes: [.edit])
  let before = document.editorModel.recipe

  do {
    _ = try controller.execute(
      .updateLayer(
        AutomationLayerPatch(
          documentID: document.projectID.uuidString,
          layerID: layerID.rawValue,
          expectedRevision: 0,
          idempotencyKey: "stale-1",
          opacity: 0.5
        )
      ),
      context: context
    )
    Issue.record("Expected a stale revision failure")
  } catch let error as AutomationServiceError {
    #expect(error.code == .staleRevision)
  }
  #expect(document.editorModel.recipe == before)
}

@MainActor
@Test func automationSnapshotReturnsStableIDAndCanBeRestored() throws {
  let document = ProjectDocument()
  let layerID = ProjectLayerID(rawValue: "snapshot-layer")
  document.perform(.addLayer(.group(id: layerID)), interactive: false)
  let controller = ProjectAutomationController(documentsProvider: { [document] })
  let context = AutomationRequestContext(clientID: "test", scopes: [.read, .edit])
  let revision = try controller.getDocument(
    id: document.projectID.uuidString, context: context
  ).document.contentRevision
  let receipt = try controller.execute(
    .createSnapshot(
      AutomationCreateSnapshotCommand(
        documentID: document.projectID.uuidString,
        expectedRevision: revision,
        idempotencyKey: "snapshot-1",
        name: "Automation checkpoint"
      )
    ),
    context: context
  )

  #expect(receipt.createdResourceID != nil)
  let history = try controller.getHistory(
    documentID: document.projectID.uuidString, context: context)
  #expect(history.snapshots.contains { $0.id == receipt.createdResourceID })
}

@MainActor
@Test func automationReadResultsDoNotIncludeLinkedPaths() throws {
  let document = ProjectDocument()
  let controller = ProjectAutomationController(documentsProvider: { [document] })
  let context = AutomationRequestContext(clientID: "reader", scopes: [.read])

  let encoded = try JSONEncoder().encode(
    controller.getDocument(id: document.projectID.uuidString, context: context)
  )
  let text = try #require(String(data: encoded, encoding: .utf8))
  #expect(text.contains("linkedPath") == false)
  #expect(text.contains("bookmark") == false)
}

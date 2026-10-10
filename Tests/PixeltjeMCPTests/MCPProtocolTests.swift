import Foundation
import PixeltjeAutomation
import Testing

@testable import PixeltjeMCP

@MainActor
private final class MCPStubService: PixeltjeAutomationService {
  private(set) var executedCommand: AutomationCommand?

  func listDocuments(context: AutomationRequestContext) throws -> [AutomationDocumentSummary] {
    try context.require(.read)
    return [
      AutomationDocumentSummary(
        id: "00000000-0000-0000-0000-000000000001",
        name: "Test document",
        isEdited: false,
        contentRevision: 3,
        canvas: AutomationCanvasSnapshot(width: 1920, height: 1080)
      )
    ]
  }

  func getDocument(id: String, context: AutomationRequestContext) throws
    -> AutomationDocumentSnapshot
  { throw unused() }
  func listLayers(documentID: String, context: AutomationRequestContext) throws
    -> [AutomationLayerSnapshot]
  { throw unused() }
  func getDevelopSettings(
    documentID: String, layerID: String, context: AutomationRequestContext
  ) throws -> AutomationDevelopSnapshot { throw unused() }
  func getHistory(documentID: String, context: AutomationRequestContext) throws
    -> AutomationHistorySnapshot
  { throw unused() }
  func getHistogram(documentID: String, context: AutomationRequestContext) throws
    -> AutomationHistogramSnapshot
  { throw unused() }
  func listJobs(documentID: String, context: AutomationRequestContext) throws
    -> [AutomationJobSnapshot]
  { throw unused() }

  func execute(
    _ command: AutomationCommand,
    context: AutomationRequestContext
  ) throws -> AutomationMutationReceipt {
    try context.require(.edit)
    executedCommand = command
    return AutomationMutationReceipt(
      documentID: "document",
      beforeRevision: 3,
      afterRevision: 4,
      historyStepID: "step",
      changed: true
    )
  }

  private func unused() -> AutomationServiceError {
    AutomationServiceError(.unsupportedOperation, "Unused by this protocol test.")
  }
}

@MainActor
@Test func mcpAdvertisesSemanticToolsWithSafetyAnnotations() throws {
  let server = PixeltjeMCPServer(
    service: MCPStubService(),
    accessToken: "token",
    scopes: [.read, .edit, .jobs]
  )
  let response = server.handleJSONRPCForTesting(
    try request(id: 1, method: "tools/list")
  )

  #expect(response.0 == 200)
  let root = try dictionary(response.1)
  let result = try #require(root["result"] as? [String: Any])
  let tools = try #require(result["tools"] as? [[String: Any]])
  #expect(tools.contains { ($0["name"] as? String) == "pixeltje_update_develop" })
  #expect(tools.contains { ($0["name"] as? String) == "pixeltje_start_inpainting" })
  #expect(tools.allSatisfy { $0["annotations"] != nil })
  #expect(
    tools.allSatisfy { tool in
      (tool["inputSchema"] as? [String: Any])?["additionalProperties"] as? Bool == false
    })
  let inpaintingTool = try #require(
    tools.first { ($0["name"] as? String) == "pixeltje_start_inpainting" })
  let inputSchema = try #require(inpaintingTool["inputSchema"] as? [String: Any])
  let properties = try #require(inputSchema["properties"] as? [String: Any])
  let maskSource = try #require(properties["maskSource"] as? [String: Any])
  let maskProperties = try #require(maskSource["properties"] as? [String: Any])
  let kind = try #require(maskProperties["kind"] as? [String: Any])
  let kinds = try #require(kind["enum"] as? [String])
  let required = try #require(inputSchema["required"] as? [String])
  #expect(kinds.contains("automatic"))
  #expect(kinds.contains("layerMask"))
  #expect(kinds.contains("localMask"))
  #expect(kinds.contains("transparentPixels"))
  #expect(required.contains("maskSource") == false)
}

@MainActor
@Test func mcpDecodesExplicitInpaintingMaskSource() throws {
  let service = MCPStubService()
  let server = PixeltjeMCPServer(
    service: service,
    accessToken: "token",
    scopes: [.read, .edit, .jobs]
  )
  let response = server.handleJSONRPCForTesting(
    try request(
      id: "inpaint",
      method: "tools/call",
      params: [
        "name": "pixeltje_start_inpainting",
        "arguments": [
          "documentID": "document",
          "expectedRevision": 3,
          "idempotencyKey": "generation-1",
          "prompt": "replace the chair",
          "negativePrompt": "text",
          "seed": 123,
          "strength": 0.75,
          "maskBlur": 6,
          "steps": 8,
          "guidance": 1,
          "maskSource": [
            "kind": "localMask", "layerID": "layer", "maskID": "mask",
          ],
        ],
      ]
    ))

  #expect(response.0 == 200)
  let executedCommand = try #require(service.executedCommand)
  guard case .startInpainting(let command) = executedCommand else {
    Issue.record("Expected the MCP call to decode a start-inpainting command.")
    return
  }
  #expect(command.maskSource?.kind == .localMask)
  #expect(command.maskSource?.layerID == "layer")
  #expect(command.maskSource?.maskID == "mask")
}

@MainActor
@Test func mcpReturnsStructuredDocumentResults() throws {
  let server = PixeltjeMCPServer(service: MCPStubService(), accessToken: "token")
  let response = server.handleJSONRPCForTesting(
    try request(
      id: "call-1",
      method: "tools/call",
      params: ["name": "pixeltje_list_documents", "arguments": [:]]
    )
  )

  let root = try dictionary(response.1)
  let result = try #require(root["result"] as? [String: Any])
  #expect(result["isError"] as? Bool == false)
  let structured = try #require(result["structuredContent"] as? [String: Any])
  let documents = try #require(structured["documents"] as? [[String: Any]])
  #expect(documents.first?["name"] as? String == "Test document")
  #expect(documents.first?["contentRevision"] as? Int == 3)
}

@MainActor
@Test func readOnlyMCPPermissionRejectsMutationTools() throws {
  let server = PixeltjeMCPServer(
    service: MCPStubService(),
    accessToken: "token",
    scopes: [.read]
  )
  let listed = server.handleJSONRPCForTesting(try request(id: 1, method: "tools/list"))
  let listedRoot = try dictionary(listed.1)
  let listedResult = try #require(listedRoot["result"] as? [String: Any])
  let tools = try #require(listedResult["tools"] as? [[String: Any]])
  #expect(tools.contains { ($0["name"] as? String) == "pixeltje_update_layer" } == false)
  #expect(tools.contains { ($0["name"] as? String) == "pixeltje_start_inpainting" } == false)

  let response = server.handleJSONRPCForTesting(
    try request(
      id: 2,
      method: "tools/call",
      params: [
        "name": "pixeltje_update_layer",
        "arguments": [
          "documentID": "document",
          "layerID": "layer",
          "expectedRevision": 3,
          "idempotencyKey": "mutation-1",
          "opacity": 0.5,
        ],
      ]
    )
  )

  let root = try dictionary(response.1)
  let result = try #require(root["result"] as? [String: Any])
  #expect(result["isError"] as? Bool == true)
  let structured = try #require(result["structuredContent"] as? [String: Any])
  let error = try #require(structured["error"] as? [String: Any])
  #expect(error["code"] as? String == "accessDenied")
}

@Test func browserOriginsAreRestrictedToExplicitLoopbackHosts() {
  #expect(MCPRequestSecurity.isAllowedOrigin("http://127.0.0.1:8000"))
  #expect(MCPRequestSecurity.isAllowedOrigin("https://localhost"))
  #expect(MCPRequestSecurity.isAllowedOrigin("http://[::1]:9000") == false)
  #expect(MCPRequestSecurity.isAllowedOrigin("https://example.com") == false)
  #expect(MCPRequestSecurity.isAllowedOrigin("null") == false)
}

private func request(
  id: Any,
  method: String,
  params: [String: Any] = [:]
) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0", "id": id, "method": method, "params": params,
  ])
}

private func dictionary(_ data: Data) throws -> [String: Any] {
  try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

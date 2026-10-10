import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@Test func generationRecipeRemembersCloudAndDefaultsOldProjectsToLocal() throws {
  let recipe = ComfyUIGenerationRecipe(
    templateID: "z-image", templateRevision: "revision", promptID: "job",
    executionTarget: .cloud, prompt: "a lighthouse", negativePrompt: "",
    seed: 1, steps: 4, guidance: 1, outputWidth: 512, outputHeight: 512)
  let encoded = try JSONEncoder().encode(recipe)
  #expect(try JSONDecoder().decode(ComfyUIGenerationRecipe.self, from: encoded)
    .executionTarget == .cloud)

  var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  legacy.removeValue(forKey: "executionTarget")
  let legacyData = try JSONSerialization.data(withJSONObject: legacy)
  #expect(try JSONDecoder().decode(ComfyUIGenerationRecipe.self, from: legacyData)
    .executionTarget == .local)
}

@Test func cloudAssetReferenceBindsToTheRuntimeImageInput() async throws {
  let session = cloudMockSession()
  defer { session.invalidateAndCancel() }
  let client = ComfyCloudClient(apiKey: "test-cloud-key", session: session)
  let asset = try await client.uploadPNG(
    Data([0x89, 0x50, 0x4E, 0x47]), filename: "source.png",
    subfolder: "pixeltje/test-job")
  let request = try ComfyUIWorkflowCatalog.request(
    templateID: ComfyUIWorkflowCatalog.defaultSelectionTemplateID,
    parameters: [:], prompt: "red clock",
    runtimeValues: [.sourceImage: asset.runtimeValue])
  let graph = try #require(
    JSONSerialization.jsonObject(with: request.workflow) as? [String: Any])
  let node = try #require(graph["79"] as? [String: Any])
  let inputs = try #require(node["inputs"] as? [String: Any])
  let reference = try #require(inputs["image"] as? [String: Any])
  let info = try #require(reference["info"] as? [String: Any])
  #expect(reference["__type"] as? String == "core/ASSET")
  #expect(info["id"] as? String == "11111111-1111-4111-8111-111111111111")
  #expect(info["file_path"] as? String == "pixeltje/test-job/source.png")
}

@Test func cloudJobSubmitsWithBearerKeyAndDownloadsTheImage() async throws {
  let session = cloudMockSession()
  defer { session.invalidateAndCancel() }
  let client = ComfyCloudClient(apiKey: "test-cloud-key", session: session)
  #expect(await client.checkConnection())
  let workflow = try ComfyUIWorkflowCatalog.request(
    templateID: "z-image", parameters: [:], prompt: "a lighthouse")
  let result = try await client.run(
    workflow, onAccepted: { _ in }, onState: { _, _ in })
  #expect(result.promptID == "22222222-2222-4222-8222-222222222222")
  #expect(result.imageData == Data([0x89, 0x50, 0x4E, 0x47]))
  #expect(try await client.status(jobID: result.promptID) == .succeeded)
  await client.cancel(jobID: result.promptID)
}

@Test func cloudModelPreflightRecognizesRepositoryStyleManagedModels() async throws {
  let session = cloudMockSession()
  defer { session.invalidateAndCancel() }
  let client = ComfyCloudClient(apiKey: "test-cloud-key", session: session)
  let workflow = try ComfyUIWorkflowCatalog.request(
    templateID: "flux2-klein-text-to-image-9b-distilled", parameters: [:],
    prompt: "a lighthouse")

  #expect(try await client.missingModels(in: workflow).isEmpty)
  #expect(ComfyCloudClient.cloudModelName(
    "black-forest-labs/FLUX.2-klein-9B-fp8",
    matches: "flux-2-klein-9b-fp8.safetensors"))
  #expect(!ComfyCloudClient.cloudModelName(
    "black-forest-labs/FLUX.2-klein-base-9B-fp8",
    matches: "flux-2-klein-9b-fp8.safetensors"))
}

@Test func cloudModelPreflightDefersAnIncompleteInventoryToJobSubmission() async throws {
  let session = cloudMockSession()
  defer { session.invalidateAndCancel() }
  let client = ComfyCloudClient(apiKey: "test-cloud-key", session: session)
  let workflow = try ComfyUIWorkflowCatalog.request(
    templateID: "flux2-klein-text-to-image-9b-base", parameters: [:],
    prompt: "a lighthouse")

  // The mock catalogue contains only the Distilled model. Cloud discovery is
  // advisory because its managed models need not appear in this inventory.
  #expect(try await client.missingModels(in: workflow).isEmpty)
}

private func cloudMockSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ComfyCloudURLProtocol.self]
  return URLSession(configuration: configuration)
}

private final class ComfyCloudURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let isV2 = url.path.hasPrefix("/api/v2/")
    let credential = isV2
      ? request.value(forHTTPHeaderField: "Authorization") == "Bearer test-cloud-key"
      : request.value(forHTTPHeaderField: "X-API-Key") == "test-cloud-key"
    if url.host == "cloud.comfy.org", !credential {
      respond(status: 401, json: ["error": ["message": "Wrong authentication header"]])
      return
    }
    switch (request.httpMethod ?? "GET", url.path) {
    case ("GET", "/api/user"):
      respond(status: 200, json: ["id": "test"])
    case ("GET", "/api/experiment/models/diffusion_models"):
      respond(status: 200, json: [[
        "name": "black-forest-labs/FLUX.2-klein-9B-fp8", "pathIndex": 0,
      ]])
    case ("GET", "/api/experiment/models/text_encoders"):
      respond(status: 200, json: [[
        "name": "Comfy-Org/flux2-klein-9B - qwen_3_8b_fp8mixed", "pathIndex": 0,
      ]])
    case ("GET", "/api/experiment/models/vae"):
      respond(status: 200, json: [[
        "name": "Comfy-Org/flux2-dev - flux2-vae", "pathIndex": 0,
      ]])
    case ("POST", "/api/v2/assets"):
      let body = String(decoding: requestBodyData(request) ?? Data(), as: UTF8.self)
      let contentType = body.range(of: "name=\"content_type\"")
      let filePath = body.range(of: "name=\"file_path\"")
      let file = body.range(of: "name=\"file\"; filename=\"source.png\"")
      guard let contentType, let filePath, let file,
        contentType.lowerBound < file.lowerBound,
        filePath.lowerBound < file.lowerBound,
        body.contains("pixeltje/test-job/source.png")
      else {
        respond(status: 422, json: ["error": ["message": "Invalid upload"]])
        return
      }
      respond(status: 201, json: [
        "id": "11111111-1111-4111-8111-111111111111",
        "hash": "blake3:abc",
        "file_path": "pixeltje/test-job/source.png",
      ])
    case ("POST", "/api/v2/jobs"):
      guard let body = requestBodyData(request),
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
        envelope["workflow"] is [String: Any]
      else {
        respond(status: 422, json: ["error": ["message": "Missing workflow"]])
        return
      }
      respond(status: 201, json: [
        "id": "22222222-2222-4222-8222-222222222222",
        "status": "queued",
        "outputs": [],
      ])
    case ("GET", "/api/v2/jobs/22222222-2222-4222-8222-222222222222"),
      ("POST", "/api/v2/jobs/22222222-2222-4222-8222-222222222222/cancel"):
      respond(status: 200, json: completedJob)
    case ("GET", "/api/v2/assets/33333333-3333-4333-8333-333333333333"):
      respond(status: 200, json: ["url": "https://assets.example/output.png"])
    case ("GET", "/output.png") where url.host == "assets.example":
      respond(status: 200, data: Data([0x89, 0x50, 0x4E, 0x47]))
    default:
      respond(status: 404, json: ["error": ["message": "Unexpected route"]])
    }
  }

  override func stopLoading() {}

  private var completedJob: [String: Any] {
    [
      "id": "22222222-2222-4222-8222-222222222222",
      "status": "succeeded",
      "outputs": [[
        "type": "image", "node_id": "9",
        "id": "33333333-3333-4333-8333-333333333333",
      ]],
    ]
  }

  private func respond(status: Int, json: Any) {
    respond(status: status, data: try! JSONSerialization.data(withJSONObject: json))
  }

  private func respond(status: Int, data: Data) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
  while true {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { return nil }
    if count == 0 { return data }
    data.append(buffer, count: count)
  }
}

import Foundation
import PixeltjeAutomation
import Testing

@Test func mutationCommandsRoundTripWithoutTransportKnowledge() throws {
  let command = AutomationCommand.updateDevelop(
    AutomationDevelopPatch(
      documentID: "document",
      layerID: "layer",
      expectedRevision: 7,
      idempotencyKey: "request-1",
      rawFloats: ["exposure": 1.25],
      basicTone: ["contrast": 12]
    )
  )

  let encoded = try JSONEncoder().encode(command)
  let decoded = try JSONDecoder().decode(AutomationCommand.self, from: encoded)

  #expect(decoded == command)
  #expect(decoded.idempotencyKey == "request-1")
}

@Test func startInpaintingCommandRoundTripsWithRevisionAndIdempotency() throws {
  let command = AutomationCommand.startInpainting(
    AutomationStartInpaintingCommand(
      documentID: "document",
      expectedRevision: 17,
      idempotencyKey: "generation-1",
      prompt: "turn the selected chair into a velvet chair",
      negativePrompt: "text",
      seed: 123,
      strength: 0.75,
      maskBlur: 6,
      steps: 8,
      guidance: 1,
      maskSource: AutomationInpaintingMaskSource(
        kind: .layerMask, layerID: "layer", maskID: "mask")))

  let encoded = try JSONEncoder().encode(command)
  let decoded = try JSONDecoder().decode(AutomationCommand.self, from: encoded)

  #expect(decoded == command)
  #expect(decoded.idempotencyKey == "generation-1")
}

@Test func omittedAutomationMaskSourcePreservesLegacyBehavior() throws {
  let command = AutomationStartInpaintingCommand(
    documentID: "document",
    expectedRevision: 17,
    idempotencyKey: "generation-legacy",
    prompt: "replace the selected chair")
  let encoded = try JSONEncoder().encode(command)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object.removeValue(forKey: "maskSource")

  let legacy = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(AutomationStartInpaintingCommand.self, from: legacy)

  #expect(decoded.maskSource == nil)
}

@Test func scopesAreExplicitAndDenyMissingCapabilities() throws {
  let context = AutomationRequestContext(clientID: "test", scopes: [.read])
  try context.require(.read)

  #expect(throws: AutomationServiceError.self) {
    try context.require(.edit)
  }
}

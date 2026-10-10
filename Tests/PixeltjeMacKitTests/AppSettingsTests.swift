import Foundation
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func openDialogOnStartIsDisabledUntilItIsTurnedOn() throws {
  let suite = try #require(UserDefaults(suiteName: "PixeltjeMacKitTests.\(UUID().uuidString)"))
  defer { suite.removePersistentDomain(forName: suite.description) }

  let settings = AppSettings(preferences: suite)
  #expect(settings.showsOpenDialogOnStart == false)

  settings.setShowsOpenDialogOnStart(true)
  #expect(settings.showsOpenDialogOnStart)
  #expect(AppSettings(preferences: suite).showsOpenDialogOnStart)

  settings.setShowsOpenDialogOnStart(false)
  #expect(AppSettings(preferences: suite).showsOpenDialogOnStart == false)
}

@MainActor
@Test func closingUnusedUntitledDocumentsDefaultsOnAndCanBeTurnedOff() throws {
  let suiteName = "AppSettingsTests.untitled.\(UUID().uuidString)"
  let suite = try #require(UserDefaults(suiteName: suiteName))
  defer { suite.removePersistentDomain(forName: suiteName) }

  let settings = AppSettings(preferences: suite)
  #expect(settings.closesUnusedUntitledOnImageOpen)

  settings.setClosesUnusedUntitledOnImageOpen(false)
  #expect(AppSettings(preferences: suite).closesUnusedUntitledOnImageOpen == false)

  settings.setClosesUnusedUntitledOnImageOpen(true)
  #expect(AppSettings(preferences: suite).closesUnusedUntitledOnImageOpen)
}

@MainActor
@Test func automationIsOptInAndPersistsWithoutStoringRuntimeCredentials() {
  let suiteName = "AppSettingsTests.automation.\(UUID().uuidString)"
  let suite = UserDefaults(suiteName: suiteName)!
  defer { suite.removePersistentDomain(forName: suiteName) }

  let settings = AppSettings(preferences: suite)
  #expect(settings.enablesAutomation == false)
  #expect(settings.automationScopes == [.read])
  #expect(settings.automationAccessToken == nil)

  settings.setEnablesAutomation(true)
  settings.setAllowsAutomationEdits(true)
  settings.setAutomationRuntime(
    endpoint: "http://127.0.0.1:46372/mcp",
    accessToken: "secret",
    status: "Running"
  )
  #expect(AppSettings(preferences: suite).enablesAutomation)
  #expect(AppSettings(preferences: suite).automationScopes == [.read, .edit])
  #expect(AppSettings(preferences: suite).automationAccessToken == nil)
  #expect(suite.dictionaryRepresentation().values.contains { ($0 as? String) == "secret" } == false)
}

/// Sampling the open image is the point of the palette, so it is on until it is
/// turned off — the reverse of the open-dialog setting above.
@MainActor
@Test func sampledPaletteColorsAreOnUntilTheyAreTurnedOff() throws {
  let suite = try #require(UserDefaults(suiteName: "PixeltjeMacKitTests.\(UUID().uuidString)"))
  defer { suite.removePersistentDomain(forName: suite.description) }

  let settings = AppSettings(preferences: suite)
  #expect(settings.usesSampledPaletteColors)

  settings.setUsesSampledPaletteColors(false)
  #expect(settings.usesSampledPaletteColors == false)
  #expect(AppSettings(preferences: suite).usesSampledPaletteColors == false)

  settings.setUsesSampledPaletteColors(true)
  #expect(AppSettings(preferences: suite).usesSampledPaletteColors)
}

@MainActor
@Test func multipleRawLayersStayOptIn() throws {
  let suite = try #require(UserDefaults(suiteName: "PixeltjeMacKitTests.\(UUID().uuidString)"))
  defer { suite.removePersistentDomain(forName: suite.description) }

  let settings = AppSettings(preferences: suite)
  #expect(settings.allowsMultipleRawLayers == false)
  #expect(AppSettings.storedAllowsMultipleRawLayers(in: suite) == false)

  settings.setAllowsMultipleRawLayers(true)
  #expect(settings.allowsMultipleRawLayers)
  #expect(AppSettings(preferences: suite).allowsMultipleRawLayers)

  settings.setAllowsMultipleRawLayers(false)
  #expect(AppSettings(preferences: suite).allowsMultipleRawLayers == false)
}

@MainActor
@Test func defaultComfyUIWorkflowsPersistPerModeAndRejectOtherModes() throws {
  let suiteName = "AppSettingsTests.comfyUI.\(UUID().uuidString)"
  let suite = try #require(UserDefaults(suiteName: suiteName))
  defer { suite.removePersistentDomain(forName: suiteName) }

  let settings = AppSettings(preferences: suite)
  for mode in ComfyUIWorkflowCatalog.modes {
    #expect(settings.defaultComfyUIWorkflowID(for: mode)
      == ComfyUIWorkflowCatalog.fallbackTemplateID(for: mode))
  }

  settings.setDefaultComfyUIWorkflowID("z-image-upscaled", for: .textToImage)
  settings.setDefaultComfyUIWorkflowID("flux2-klein-image-edit-distilled", for: .imageToImage)
  settings.setDefaultComfyUIWorkflowID("flux2-klein-inpaint-base", for: .inpainting)
  settings.setDefaultComfyUIWorkflowID("sam3-selection", for: .selection)
  settings.setDefaultComfyUIWorkflowID("z-image", for: .inpainting)
  settings.setDefaultComfyUIWorkflowID("missing-workflow", for: .selection)

  let reloaded = AppSettings(preferences: suite)
  #expect(reloaded.defaultComfyUIWorkflowID(for: .textToImage) == "z-image-upscaled")
  #expect(reloaded.defaultComfyUIWorkflowID(for: .imageToImage)
    == "flux2-klein-image-edit-distilled")
  #expect(reloaded.defaultComfyUIWorkflowID(for: .inpainting) == "flux2-klein-inpaint-base")
  #expect(reloaded.defaultComfyUIWorkflowID(for: .selection) == "sam3-selection")

  suite.set("z-image", forKey: "PixeltjeMac.defaultComfyUIWorkflow.imageToImage")
  #expect(AppSettings.storedDefaultComfyUIWorkflowID(for: .imageToImage, in: suite)
    == ComfyUIWorkflowCatalog.defaultEditingTemplateID)
}

@MainActor
@Test func comfyUIHistoryRecordingDefaultsOnAndCanBeDisabled() throws {
  let suiteName = "AppSettingsTests.comfyUIHistory.\(UUID().uuidString)"
  let suite = try #require(UserDefaults(suiteName: suiteName))
  defer { suite.removePersistentDomain(forName: suiteName) }

  let settings = AppSettings(preferences: suite)
  #expect(settings.disablesComfyUIHistory == false)
  #expect(AppSettings.storedDisablesComfyUIHistory(in: suite) == false)

  settings.setDisablesComfyUIHistory(true)
  #expect(AppSettings(preferences: suite).disablesComfyUIHistory)

  settings.setDisablesComfyUIHistory(false)
  #expect(AppSettings(preferences: suite).disablesComfyUIHistory == false)
}

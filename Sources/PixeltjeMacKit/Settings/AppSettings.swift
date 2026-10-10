import Combine
import Foundation
import PixeltjeAutomation
import PixeltjeMacDomain

@MainActor
public final class AppSettings: ObservableObject {
  private static let showsOpenDialogOnStartKey = "PixeltjeMac.showOpenDialogOnStart"
  private static let closesUnusedUntitledOnImageOpenKey =
    "PixeltjeMac.closesUnusedUntitledOnImageOpen"
  private static let defaultCanvasWidthKey = "PixeltjeMac.defaultCanvasWidth"
  private static let defaultCanvasHeightKey = "PixeltjeMac.defaultCanvasHeight"
  private static let usesSampledPaletteColorsKey = "PixeltjeMac.usesSampledPaletteColors"
  private static let defaultComfyUIWorkflowKeyPrefix = "PixeltjeMac.defaultComfyUIWorkflow."
  private static let disablesComfyUIHistoryKey = "PixeltjeMac.disablesComfyUIHistory"
  private static let enablesAutomationKey = "PixeltjeMac.enablesAutomation"
  private static let allowsAutomationEditsKey = "PixeltjeMac.allowsAutomationEdits"
  private static let allowsAutomationJobControlKey = "PixeltjeMac.allowsAutomationJobControl"
  static let allowsMultipleRawLayersKey = "PixeltjeMac.allowsMultipleRawLayers"
  private static let fallbackCanvas = CanvasRecipe(width: 1920, height: 1080)

  @Published public private(set) var showsOpenDialogOnStart: Bool
  @Published public private(set) var closesUnusedUntitledOnImageOpen: Bool
  @Published public private(set) var defaultCanvas: CanvasRecipe
  @Published public private(set) var usesSampledPaletteColors: Bool
  @Published public private(set) var defaultComfyUIWorkflowIDs: [GenerationMode: String]
  @Published public private(set) var disablesComfyUIHistory: Bool
  @Published public private(set) var hasComfyCloudAPIKey: Bool
  @Published public private(set) var comfyCloudKeyError: String?
  /// An advanced opt-in. RAW is normally developed into an output image before
  /// it is composited with other layers, but independent RAW layers are useful
  /// for the occasional composite that genuinely needs them.
  @Published public private(set) var allowsMultipleRawLayers: Bool
  /// Starts the authenticated loopback MCP endpoint while the app is running.
  /// Off by default: installing or launching Pixeltje never silently opens an
  /// automation surface.
  @Published public private(set) var enablesAutomation: Bool
  @Published public private(set) var allowsAutomationEdits: Bool
  @Published public private(set) var allowsAutomationJobControl: Bool
  @Published public private(set) var automationEndpoint: String?
  @Published public private(set) var automationAccessToken: String?
  @Published public private(set) var automationStatus: String

  var automationEnabledDidChange: (@MainActor (Bool) -> Void)?
  var automationTokenRotationRequested: (@MainActor () -> Void)?

  private let preferences: UserDefaults

  public init(preferences: UserDefaults = .standard) {
    _ = ComfyUIWorkflowLibrary.shared
    self.preferences = preferences
    self.showsOpenDialogOnStart = Self.storedShowsOpenDialogOnStart(in: preferences)
    self.closesUnusedUntitledOnImageOpen =
      Self.storedClosesUnusedUntitledOnImageOpen(in: preferences)
    self.defaultCanvas = Self.storedDefaultCanvas(in: preferences)
    self.usesSampledPaletteColors = Self.storedUsesSampledPaletteColors(in: preferences)
    self.defaultComfyUIWorkflowIDs = Dictionary(
      uniqueKeysWithValues: ComfyUIWorkflowCatalog.modes.map { mode in
        let key = Self.defaultComfyUIWorkflowKeyPrefix + mode.rawValue
        let stored = preferences.string(forKey: key)
        return (mode, stored ?? ComfyUIWorkflowCatalog.fallbackTemplateID(for: mode))
      })
    self.disablesComfyUIHistory = Self.storedDisablesComfyUIHistory(in: preferences)
    self.hasComfyCloudAPIKey = (try? ComfyCloudCredentialStore.load()) != nil
    self.comfyCloudKeyError = nil
    self.allowsMultipleRawLayers = Self.storedAllowsMultipleRawLayers(in: preferences)
    let enablesAutomation = Self.storedEnablesAutomation(in: preferences)
    self.enablesAutomation = enablesAutomation
    self.allowsAutomationEdits = preferences.bool(forKey: Self.allowsAutomationEditsKey)
    self.allowsAutomationJobControl = preferences.bool(
      forKey: Self.allowsAutomationJobControlKey)
    self.automationEndpoint = nil
    self.automationAccessToken = nil
    self.automationStatus = enablesAutomation ? "Starting…" : "Disabled"
  }

  /// Absent preference means enabled: sampling the open image is the point of
  /// the palette, and the fixed default set is the opt-out.
  public static func storedUsesSampledPaletteColors(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: usesSampledPaletteColorsKey) as? Bool ?? true
  }

  public static func storedDefaultComfyUIWorkflowID(
    for mode: GenerationMode,
    in defaults: UserDefaults = .standard
  ) -> String {
    let stored = defaults.string(forKey: defaultComfyUIWorkflowKeyPrefix + mode.rawValue)
    if let stored,
      stored.hasPrefix("user-"),
      UUID(uuidString: String(stored.dropFirst("user-".count))) != nil,
      !ComfyUIWorkflowLibrary.shared.isLoaded
    {
      return stored
    }
    guard let stored,
      ComfyUIWorkflowCatalog.templates.contains(where: { $0.id == stored && $0.mode == mode })
    else { return ComfyUIWorkflowCatalog.fallbackTemplateID(for: mode) }
    return stored
  }

  public func defaultComfyUIWorkflowID(for mode: GenerationMode) -> String {
    guard let stored = defaultComfyUIWorkflowIDs[mode],
      ComfyUIWorkflowCatalog.templates.contains(where: { $0.id == stored && $0.mode == mode })
    else { return ComfyUIWorkflowCatalog.fallbackTemplateID(for: mode) }
    return stored
  }

  public func setDefaultComfyUIWorkflowID(_ id: String, for mode: GenerationMode) {
    guard ComfyUIWorkflowCatalog.templates.contains(where: { $0.id == id && $0.mode == mode }),
      defaultComfyUIWorkflowID(for: mode) != id
    else { return }
    defaultComfyUIWorkflowIDs[mode] = id
    preferences.set(id, forKey: Self.defaultComfyUIWorkflowKeyPrefix + mode.rawValue)
  }

  /// Absent preference means recording is enabled. History contains prompt and
  /// workflow settings, so people who do not want that app-level record can opt
  /// out without changing the metadata saved with generated project layers.
  public static func storedDisablesComfyUIHistory(
    in defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.bool(forKey: disablesComfyUIHistoryKey)
  }

  public func setDisablesComfyUIHistory(_ disables: Bool) {
    guard disables != disablesComfyUIHistory else { return }
    disablesComfyUIHistory = disables
    preferences.set(disables, forKey: Self.disablesComfyUIHistoryKey)
  }

  public func saveComfyCloudAPIKey(_ key: String) {
    do {
      try ComfyCloudCredentialStore.save(key)
      hasComfyCloudAPIKey = true
      comfyCloudKeyError = nil
    } catch {
      comfyCloudKeyError = error.localizedDescription
    }
  }

  public func removeComfyCloudAPIKey() {
    do {
      try ComfyCloudCredentialStore.remove()
      hasComfyCloudAPIKey = false
      comfyCloudKeyError = nil
    } catch {
      comfyCloudKeyError = error.localizedDescription
    }
  }

  /// Absent preference means disabled: new documents guide photographers to
  /// develop a RAW and place the resulting JPEG, TIFF, or PNG when compositing.
  public static func storedAllowsMultipleRawLayers(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: allowsMultipleRawLayersKey)
  }

  /// Absent preference means disabled. Automation must always be an explicit
  /// local opt-in.
  public static func storedEnablesAutomation(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: enablesAutomationKey)
  }

  // Absent preference means disabled: a fresh install starts without a file dialog.
  public static func storedShowsOpenDialogOnStart(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: showsOpenDialogOnStartKey)
  }

  /// Keep a blank startup document available until an image successfully opens.
  /// The preference is on by default so that opening that image leaves one tab.
  public static func storedClosesUnusedUntitledOnImageOpen(
    in defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.object(forKey: closesUnusedUntitledOnImageOpenKey) as? Bool ?? true
  }

  /// The extent a document with no RAW source starts at.
  ///
  /// Absent or nonsensical preferences fall back to 1920 × 1080 rather than to
  /// an unresolved canvas, which would leave a new document with no extent.
  public static func storedDefaultCanvas(in defaults: UserDefaults = .standard) -> CanvasRecipe {
    let stored = CanvasRecipe(
      width: defaults.integer(forKey: defaultCanvasWidthKey),
      height: defaults.integer(forKey: defaultCanvasHeightKey)
    )
    return stored.isResolved ? stored : fallbackCanvas
  }

  public func setDefaultCanvas(_ canvas: CanvasRecipe) {
    guard canvas.isResolved, canvas != defaultCanvas else { return }
    defaultCanvas = canvas
    preferences.set(canvas.width, forKey: Self.defaultCanvasWidthKey)
    preferences.set(canvas.height, forKey: Self.defaultCanvasHeightKey)
  }

  public func setUsesSampledPaletteColors(_ uses: Bool) {
    guard uses != usesSampledPaletteColors else { return }
    usesSampledPaletteColors = uses
    preferences.set(uses, forKey: Self.usesSampledPaletteColorsKey)
    ColorPanelPalette.shared.setUsesSampledColors(uses)
  }

  public func setAllowsMultipleRawLayers(_ allows: Bool) {
    guard allows != allowsMultipleRawLayers else { return }
    allowsMultipleRawLayers = allows
    preferences.set(allows, forKey: Self.allowsMultipleRawLayersKey)
  }

  public func setEnablesAutomation(_ enables: Bool) {
    guard enables != enablesAutomation else { return }
    enablesAutomation = enables
    preferences.set(enables, forKey: Self.enablesAutomationKey)
    automationStatus = enables ? "Starting…" : "Disabled"
    if !enables {
      automationEndpoint = nil
      automationAccessToken = nil
    }
    automationEnabledDidChange?(enables)
  }

  public func setAllowsAutomationEdits(_ allows: Bool) {
    guard allows != allowsAutomationEdits else { return }
    allowsAutomationEdits = allows
    preferences.set(allows, forKey: Self.allowsAutomationEditsKey)
    if enablesAutomation { automationEnabledDidChange?(true) }
  }

  public func setAllowsAutomationJobControl(_ allows: Bool) {
    guard allows != allowsAutomationJobControl else { return }
    allowsAutomationJobControl = allows
    preferences.set(allows, forKey: Self.allowsAutomationJobControlKey)
    if enablesAutomation { automationEnabledDidChange?(true) }
  }

  public var automationScopes: Set<AutomationScope> {
    var scopes: Set<AutomationScope> = [.read]
    if allowsAutomationEdits { scopes.insert(.edit) }
    if allowsAutomationJobControl { scopes.insert(.jobs) }
    return scopes
  }

  public func rotateAutomationAccessToken() {
    guard enablesAutomation else { return }
    automationTokenRotationRequested?()
  }

  func setAutomationRuntime(
    endpoint: String?,
    accessToken: String?,
    status: String
  ) {
    automationEndpoint = endpoint
    automationAccessToken = accessToken
    automationStatus = status
  }

  public func setShowsOpenDialogOnStart(_ shows: Bool) {
    guard shows != showsOpenDialogOnStart else { return }
    showsOpenDialogOnStart = shows
    preferences.set(shows, forKey: Self.showsOpenDialogOnStartKey)
  }

  public func setClosesUnusedUntitledOnImageOpen(_ closes: Bool) {
    guard closes != closesUnusedUntitledOnImageOpen else { return }
    closesUnusedUntitledOnImageOpen = closes
    preferences.set(closes, forKey: Self.closesUnusedUntitledOnImageOpenKey)
  }
}

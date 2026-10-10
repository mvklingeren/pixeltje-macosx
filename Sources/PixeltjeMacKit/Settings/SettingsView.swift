import AppKit
import PixeltjeMacDomain
import SwiftUI

struct SettingsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var navigation: SettingsNavigationModel
  @ObservedObject private var workflowLibrary = ComfyUIWorkflowLibrary.shared

  private typealias FieldState = SwiftUI.State<Int>
  private typealias AspectState = SwiftUI.State<String?>
  @FieldState private var defaultCanvasWidth = 0
  @FieldState private var defaultCanvasHeight = 0
  @AspectState private var selectedCanvasAspectID: String? = nil
  @SwiftUI.State private var comfyCloudKeyDraft = ""

  @AppStorage(BrowserPreferences.scansSubfoldersKey) private var scansSubfolders = true
  @AppStorage(BrowserPreferences.marginKey) private var margin = 10.0
  @AppStorage(BrowserPreferences.preloadCountKey) private var preloadCount = BrowserPreferences
    .defaultPreloadCount
  @AppStorage(InteractionPreferences.invertPanDirectionKey) private var invertsPanDirection = false
  @AppStorage(InteractionPreferences.disableHintsKey) private var disablesHints = false

  private var showsOpenDialogOnStart: Binding<Bool> {
    Binding(
      get: { settings.showsOpenDialogOnStart },
      set: settings.setShowsOpenDialogOnStart
    )
  }

  private var closesUnusedUntitledOnImageOpen: Binding<Bool> {
    Binding(
      get: { settings.closesUnusedUntitledOnImageOpen },
      set: settings.setClosesUnusedUntitledOnImageOpen
    )
  }

  private var usesSampledPaletteColors: Binding<Bool> {
    Binding(
      get: { settings.usesSampledPaletteColors },
      set: settings.setUsesSampledPaletteColors
    )
  }

  private var allowsMultipleRawLayers: Binding<Bool> {
    Binding(
      get: { settings.allowsMultipleRawLayers },
      set: settings.setAllowsMultipleRawLayers
    )
  }

  private var disablesComfyUIHistory: Binding<Bool> {
    Binding(
      get: { settings.disablesComfyUIHistory },
      set: settings.setDisablesComfyUIHistory
    )
  }

  private var enablesAutomation: Binding<Bool> {
    Binding(
      get: { settings.enablesAutomation },
      set: settings.setEnablesAutomation
    )
  }

  private var allowsAutomationEdits: Binding<Bool> {
    Binding(
      get: { settings.allowsAutomationEdits },
      set: settings.setAllowsAutomationEdits
    )
  }

  private var allowsAutomationJobControl: Binding<Bool> {
    Binding(
      get: { settings.allowsAutomationJobControl },
      set: settings.setAllowsAutomationJobControl
    )
  }

  private var preloadCountSlider: Binding<Double> {
    Binding(
      get: { Double(preloadCount) },
      set: { preloadCount = Int($0.rounded()) }
    )
  }

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section("Startup") {
          Toggle("Show open dialog on start", isOn: showsOpenDialogOnStart)

          Text(
            "Opens the RAW or project chooser as soon as Pixeltje Mac launches. When it is off, "
              + "the app starts with a new document at the default canvas size instead."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          Text(
            "Files opened from Finder or passed on the command line always open directly, whatever "
              + "this setting says."
          )
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)

          Toggle(
            "Close unchanged untitled documents when opening an image",
            isOn: closesUnusedUntitledOnImageOpen
          )

          Text(
            "After an image opens, closes any empty, unsaved document that has not been edited. "
              + "Documents with edits or pending work stay open."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Section("New Documents") {
          Picker("Aspect", selection: defaultCanvasAspectSelection) {
            Text("Any").tag(nil as String?)
            Divider()
            ForEach(CanvasRecipe.aspectPresets) { aspect in
              Text("\(aspect.name)  \(aspect.description)").tag(aspect.id as String?)
            }
          }
          .pickerStyle(.menu)

          Picker("Preset", selection: defaultCanvasSizeSelection) {
            Text("Custom").tag(nil as String?)
            Divider()
            ForEach(visibleCanvasSizePresets) { preset in
              Text(canvasPresetTitle(preset)).tag(preset.id as String?)
            }
          }
          .pickerStyle(.menu)

          HStack {
            Text("Default canvas")
            Spacer()
            TextField("Width", value: $defaultCanvasWidth, format: .number)
              .frame(width: 76)
              .onSubmit(commitDefaultCanvas)
            Text("×")
              .foregroundStyle(.secondary)
            TextField("Height", value: $defaultCanvasHeight, format: .number)
              .frame(width: 76)
              .onSubmit(commitDefaultCanvas)
            Text("px")
              .foregroundStyle(.secondary)
          }
          .labelsHidden()

          Text(
            "The size a document created with File ▸ New, or opened at launch, starts at. A "
              + "document opened from a RAW file takes its canvas from the developed image instead."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Section("ComfyUI Workflows") {
          ComfyUIWorkflowSettingsView(library: .shared)
        }
        .id(SettingsDestination.comfyUIWorkflows)

        Section("Default Workflows") {
          Text("Choose the ComfyUI workflow used when you switch to each prompt mode.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if workflowLibrary.isLoaded {
            ForEach(ComfyUIWorkflowCatalog.modes, id: \.self) { mode in
              Picker(
                mode.comfyUIDisplayName,
                selection: Binding(
                  get: { settings.defaultComfyUIWorkflowID(for: mode) },
                  set: { settings.setDefaultComfyUIWorkflowID($0, for: mode) })
              ) {
                ForEach(availableWorkflowTemplates.filter { $0.mode == mode }) { template in
                  Text(template.name).tag(template.id)
                }
              }
              .pickerStyle(.menu)
            }
          } else {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Loading installed workflows…")
                .foregroundStyle(.secondary)
            }
          }
        }

        Section("Generation History") {
          Toggle("Disable recording in history", isOn: disablesComfyUIHistory)

          Text(
            "Stops future ComfyUI tasks from being added to the app-wide History tab. Existing history and generation metadata saved in project layers are not removed."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Section("Comfy Cloud") {
          SecureField(
            settings.hasComfyCloudAPIKey ? "Replace saved API key" : "Comfy Cloud API key",
            text: $comfyCloudKeyDraft
          )
          .textContentType(.password)
          .onSubmit(saveComfyCloudKey)
          HStack {
            Button(settings.hasComfyCloudAPIKey ? "Replace Key" : "Save Key") {
              saveComfyCloudKey()
            }
            .disabled(comfyCloudKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if settings.hasComfyCloudAPIKey {
              Button("Remove Key") { settings.removeComfyCloudAPIKey() }
              Text("Key saved in Keychain")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          if let error = settings.comfyCloudKeyError {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
          }
          Text(
            "When a key is saved, the prompt box offers Local and Cloud execution. Cloud runs may use account credits and upload any source image and mask needed by the workflow."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Link(
            "Get a Comfy Cloud API key",
            destination: URL(string: "https://platform.comfy.org/profile/api-keys")!
          )
          .font(.caption)
        }

        Section("Advanced compositing") {
          Toggle("Allow multiple RAW layers", isOn: allowsMultipleRawLayers)

          Text(
            "Normally, develop a RAW first and add its JPEG, TIFF, or PNG output as a layer. Turn this on only when a composite genuinely needs independent RAW development for more than one source."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Section("Automation") {
          Toggle("Enable local MCP automation", isOn: enablesAutomation)
          Toggle("Allow document edits", isOn: allowsAutomationEdits)
            .disabled(!settings.enablesAutomation)
          Toggle("Allow export job cancellation", isOn: allowsAutomationJobControl)
            .disabled(!settings.enablesAutomation)

          Text(
            "Runs only while Pixeltje Mac is open, listens on this Mac's loopback interface, and requires a per-install bearer token. Automation edits use the same recipe, undo history, validation, and render path as the interface."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          LabeledContent("Status", value: settings.automationStatus)
          if let endpoint = settings.automationEndpoint {
            LabeledContent("Endpoint", value: endpoint)
              .textSelection(.enabled)
          }
          if let token = settings.automationAccessToken {
            HStack {
              Button("Copy MCP Access Token") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
              }
              .help("Copies the bearer token from the Keychain. Treat it like a password.")
              Button("Rotate Token") {
                settings.rotateAutomationAccessToken()
              }
              .help("Revokes the current token and creates a new one.")
            }
          }
        }

        Section("Colors") {
          Toggle("Use sampled colors for the color picker", isOn: usesSampledPaletteColors)

          Text(
            "Fills the Pixeltje palette in the color panel with the colors the open image is "
              + "actually made of, re-read every time the canvas finishes rendering. When it is "
              + "off, that palette holds a fixed set of neutrals and hues instead."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Section("Interaction") {
          Toggle("Invert pan direction", isOn: $invertsPanDirection)

          Text(
            "Changes the direction used to pan images with a trackpad, mouse wheel, or drag in "
              + "the canvas and fullscreen previews."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          Toggle("Disable hints", isOn: $disablesHints)

          Text("Hides tool and picker hints over the canvas. Render errors still appear.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Section("Browser") {
          Toggle("Include images in subfolders", isOn: $scansSubfolders)

          HStack {
            Text("Thumbnail margin")
            Slider(value: $margin, in: 0...40, step: 1)
            Text("\(Int(margin)) pt")
              .monospacedDigit()
              .frame(width: 44, alignment: .trailing)
          }

          HStack {
            Text("Preload ahead")
            Slider(value: preloadCountSlider, in: 0...60, step: 1)
            Text("\(preloadCount) images")
              .monospacedDigit()
              .frame(width: 72, alignment: .trailing)
          }

          Text("Keeps upcoming thumbnails ready while you scroll. Set to 0 to turn preloading off.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .frame(width: 560, height: 780)
      .onAppear {
        syncDefaultCanvas()
        navigate(to: navigation.destination, with: proxy)
      }
      .onChange(of: settings.defaultCanvas) { _, _ in syncDefaultCanvas() }
      .onChange(of: navigation.destination) { _, destination in
        navigate(to: destination, with: proxy)
      }
    }
  }

  private func navigate(to destination: SettingsDestination?, with proxy: ScrollViewProxy) {
    guard let destination else { return }
    withAnimation { proxy.scrollTo(destination, anchor: .top) }
    navigation.destination = nil
  }

  private var availableWorkflowTemplates: [ComfyUIWorkflowTemplate] {
    ComfyUIWorkflowCatalog.bundledTemplates + workflowLibrary.customTemplates
  }

  private func syncDefaultCanvas() {
    defaultCanvasWidth = settings.defaultCanvas.width
    defaultCanvasHeight = settings.defaultCanvas.height
  }

  private func saveComfyCloudKey() {
    settings.saveComfyCloudAPIKey(comfyCloudKeyDraft)
    if settings.comfyCloudKeyError == nil { comfyCloudKeyDraft = "" }
  }

  private var draftCanvas: CanvasRecipe {
    CanvasRecipe(width: defaultCanvasWidth, height: defaultCanvasHeight)
  }

  private var defaultCanvasAspectSelection: Binding<String?> {
    Binding(
      get: { selectedCanvasAspectID },
      set: { id in
        guard id != selectedCanvasAspectID else { return }
        selectedCanvasAspectID = id
        guard let aspect = CanvasRecipe.aspectPresets.first(where: { $0.id == id }),
          let preset = aspect.closestSize(to: draftCanvas)
        else { return }
        setDefaultCanvas(to: preset.canvas)
      }
    )
  }

  private var visibleCanvasSizePresets: [CanvasSizePreset] {
    guard let selectedCanvasAspectID,
      let aspect = CanvasRecipe.aspectPresets.first(where: { $0.id == selectedCanvasAspectID })
    else { return CanvasRecipe.presets }
    return aspect.sizes
  }

  private var defaultCanvasSizeSelection: Binding<String?> {
    Binding(
      get: { visibleCanvasSizePresets.first(where: { $0.canvas == draftCanvas })?.id },
      set: { id in
        guard let preset = visibleCanvasSizePresets.first(where: { $0.id == id }) else { return }
        setDefaultCanvas(to: preset.canvas)
      }
    )
  }

  private func canvasPresetTitle(_ preset: CanvasSizePreset) -> String {
    let size = "\(preset.canvas.width) × \(preset.canvas.height)"
    guard selectedCanvasAspectID == nil, let name = preset.canvas.aspectPreset?.name else {
      return size
    }
    return "\(size)  (\(name))"
  }

  private func setDefaultCanvas(to canvas: CanvasRecipe) {
    defaultCanvasWidth = canvas.width
    defaultCanvasHeight = canvas.height
    settings.setDefaultCanvas(canvas)
  }

  private func commitDefaultCanvas() {
    settings.setDefaultCanvas(
      CanvasRecipe(width: defaultCanvasWidth, height: defaultCanvasHeight)
    )
  }
}

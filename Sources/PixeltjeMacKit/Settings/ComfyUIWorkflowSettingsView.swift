import AppKit
import PixeltjeMacDomain
import SwiftUI
import UniformTypeIdentifiers

struct ComfyUIWorkflowSettingsView: View {
  @ObservedObject var library: ComfyUIWorkflowLibrary

  @SwiftUI.State private var importDraft: ComfyUIWorkflowImportDraft?
  @SwiftUI.State private var editingWorkflowID: String?
  @SwiftUI.State private var errorMessage: String?
  @SwiftUI.State private var pendingRemoval: ComfyUIWorkflowTemplate?
  @SwiftUI.State private var isWorking = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "Built-in workflows are included with Pixeltje. Added workflows are copied into Pixeltje's Application Support folder and become available immediately in the Develop panel."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 0) {
        ForEach(availableTemplates) { template in
          workflowRow(template)
          if template.id != availableTemplates.last?.id {
            Divider()
          }
        }
      }
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

      ForEach(library.loadFailures) { failure in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(failure.name).font(.callout.weight(.medium))
            Text(failure.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      HStack {
        Button("Add Workflow…", action: chooseWorkflowFiles)
        Button("Show Workflows Folder", action: revealWorkflowsFolder)
        Spacer()
        if isWorking || !library.isLoaded {
          ProgressView()
            .controlSize(.small)
        }
      }
      .disabled(isWorking || !library.isLoaded)

      Text(library.directoryURL.path)
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
        .lineLimit(2)
        .textSelection(.enabled)
    }
    .sheet(
      isPresented: Binding(
        get: { importDraft != nil },
        set: {
          if !$0 {
            importDraft = nil
            editingWorkflowID = nil
          }
        }
      )
    ) {
      if let importDraft {
        ComfyUIWorkflowImportView(
          draft: importDraft,
          actionTitle: editingWorkflowID == nil ? "Add Workflow" : "Save Changes",
          isSaving: isWorking,
          cancel: {
            self.importDraft = nil
            self.editingWorkflowID = nil
          },
          save: save
        )
        .interactiveDismissDisabled(isWorking)
      }
    }
    .alert(
      "ComfyUI Workflow",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
    .confirmationDialog(
      "Remove \(pendingRemoval?.name ?? "workflow")?",
      isPresented: Binding(
        get: { pendingRemoval != nil },
        set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      if let workflow = pendingRemoval {
        Button("Move to Trash", role: .destructive) { remove(workflow) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The workflow will disappear from Settings and the Develop panel. Existing generated layers and history remain unchanged."
      )
    }
  }

  private var availableTemplates: [ComfyUIWorkflowTemplate] {
    ComfyUIWorkflowCatalog.bundledTemplates + library.customTemplates
  }

  private func workflowRow(_ template: ComfyUIWorkflowTemplate) -> some View {
    HStack(spacing: 10) {
      Image(systemName: template.isBuiltIn ? "shippingbox.fill" : "doc.badge.gearshape")
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(template.name)
          .lineLimit(1)
        HStack(spacing: 5) {
          Text(template.mode.comfyUIWorkflowTypeName)
          Text("·")
          Text(template.isBuiltIn ? "Built-in" : "Added")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      Spacer()
      if !template.isBuiltIn {
        Button {
          edit(template)
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Edit this workflow's name, type, and node bindings")
        Button {
          chooseWorkflowFiles(replacing: template)
        } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderless)
        .help("Replace this workflow's JSON files")
        Button {
          reveal(template)
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Show this workflow in Finder")
        Button(role: .destructive) {
          pendingRemoval = template
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Remove this workflow")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .disabled(isWorking || !library.isLoaded)
  }

  private func chooseWorkflowFiles() {
    editingWorkflowID = nil
    chooseWorkflowFiles(replacing: nil)
  }

  private func chooseWorkflowFiles(replacing template: ComfyUIWorkflowTemplate?) {
    let panel = NSOpenPanel()
    panel.title = template == nil ? "Add ComfyUI Workflow" : "Replace ComfyUI Workflow"
    panel.message = "Select the regular workflow JSON and its matching API-format export."
    panel.prompt = "Continue"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.resolvesAliases = true
    panel.allowedContentTypes = [.json]
    panel.begin { response in
      guard response == .OK else { return }
      let urls = panel.urls
      isWorking = true
      Task { @MainActor in
        defer { isWorking = false }
        do {
          var draft = try await library.prepareImportAsync(from: urls)
          if let template {
            draft.name = template.name
            draft.mode = template.mode
            draft.imageAlignment =
              library.definitionSnapshot(for: template.id)?.manifest
              .imageAlignment ?? draft.imageAlignment
            editingWorkflowID = template.id
          }
          importDraft = draft
        } catch {
          errorMessage = error.userFacingMessage
        }
      }
    }
  }

  private func save(_ draft: ComfyUIWorkflowImportDraft) {
    guard !isWorking else { return }
    let workflowID = editingWorkflowID
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      do {
        if let workflowID {
          try await library.updateAsync(draft, id: workflowID)
        } else {
          _ = try await library.installAsync(draft)
        }
        importDraft = nil
        editingWorkflowID = nil
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }

  private func edit(_ template: ComfyUIWorkflowTemplate) {
    guard !isWorking else { return }
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      do {
        let draft = try await library.editDraftAsync(for: template.id)
        editingWorkflowID = template.id
        importDraft = draft
      } catch {
        editingWorkflowID = nil
        errorMessage = error.userFacingMessage
      }
    }
  }

  private func remove(_ template: ComfyUIWorkflowTemplate) {
    pendingRemoval = nil
    guard !isWorking else { return }
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      do {
        try await library.removeWorkflowAsync(id: template.id)
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }

  private func reveal(_ template: ComfyUIWorkflowTemplate) {
    guard let definition = library.definitionSnapshot(for: template.id) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([definition.directoryURL])
  }

  private func revealWorkflowsFolder() {
    guard !isWorking else { return }
    isWorking = true
    Task { @MainActor in
      defer { isWorking = false }
      do {
        let url = try await library.ensureDirectoryAsync()
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }
}

private struct ComfyUIWorkflowImportView: View {
  @SwiftUI.State private var draft: ComfyUIWorkflowImportDraft
  let actionTitle: String
  let isSaving: Bool
  let cancel: () -> Void
  let save: (ComfyUIWorkflowImportDraft) -> Void

  init(
    draft: ComfyUIWorkflowImportDraft,
    actionTitle: String,
    isSaving: Bool,
    cancel: @escaping () -> Void,
    save: @escaping (ComfyUIWorkflowImportDraft) -> Void
  ) {
    _draft = SwiftUI.State(initialValue: draft)
    self.actionTitle = actionTitle
    self.isSaving = isSaving
    self.cancel = cancel
    self.save = save
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Workflow") {
          TextField("Name", text: $draft.name)
          Picker("Type", selection: $draft.mode) {
            ForEach(ComfyUIWorkflowCatalog.modes, id: \.self) { mode in
              Text(mode.comfyUIWorkflowTypeName).tag(mode)
            }
          }
          .pickerStyle(.menu)
          if draft.mode == .inpainting {
            Picker("Image alignment", selection: $draft.imageAlignment) {
              ForEach([8, 16, 32, 64], id: \.self) { value in
                Text("\(value) px").tag(value)
              }
            }
            .pickerStyle(.menu)
          }
        }

        Section("Required bindings") {
          WorkflowAddressEditor(
            title: "Prompt",
            address: $draft.bindings.prompt,
            candidates: draft.inputCandidates)

          if draft.mode != .textToImage {
            WorkflowAddressEditor(
              title: "Source image",
              address: $draft.bindings.sourceImage,
              candidates: draft.inputCandidates)
          }
          if draft.mode == .inpainting {
            WorkflowAddressEditor(
              title: "Mask image",
              address: $draft.bindings.maskImage,
              candidates: draft.inputCandidates)
          }

          WorkflowOutputEditor(
            nodeID: $draft.outputNodeID,
            candidates: draft.outputCandidates)
        }

        Section("Optional parameter bindings") {
          WorkflowAddressEditor(
            title: "Negative prompt", address: $draft.bindings.negativePrompt,
            candidates: draft.inputCandidates, optional: true)
          WorkflowAddressEditor(
            title: "Seed", address: $draft.bindings.seed,
            candidates: draft.inputCandidates, optional: true)
          WorkflowAddressEditor(
            title: "Steps", address: $draft.bindings.steps,
            candidates: draft.inputCandidates, optional: true)
          WorkflowAddressEditor(
            title: "Guidance", address: $draft.bindings.guidance,
            candidates: draft.inputCandidates, optional: true)
          WorkflowAddressEditor(
            title: "Width", address: $draft.bindings.width,
            candidates: draft.inputCandidates, optional: true)
          WorkflowAddressEditor(
            title: "Height", address: $draft.bindings.height,
            candidates: draft.inputCandidates, optional: true)
          WorkflowAddressEditor(
            title: "Strength", address: $draft.bindings.strength,
            candidates: draft.inputCandidates, optional: true)
        }
      }
      .formStyle(.grouped)
      .disabled(isSaving)

      Divider()
      HStack {
        Text(
          "Node IDs and input names are validated against the API workflow before it is installed."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        if isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Button(actionTitle) { save(draft) }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving)
      }
      .padding()
    }
    .frame(width: 620, height: 700)
  }
}

private struct WorkflowAddressEditor: View {
  var title: String
  @Binding var address: ComfyUIParameterAddress?
  var candidates: [ComfyUIWorkflowInputCandidate]
  var optional = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
        Spacer()
        Picker(
          "Detected input",
          selection: Binding(
            get: { address },
            set: { address = $0 })
        ) {
          if optional {
            Text("Not bound").tag(nil as ComfyUIParameterAddress?)
            Divider()
          } else if address == nil {
            Text("Choose…").tag(nil as ComfyUIParameterAddress?)
            Divider()
          }
          ForEach(candidates) { candidate in
            Text(candidate.title).tag(candidate.address as ComfyUIParameterAddress?)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 310)
      }
      HStack {
        TextField("Node ID", text: nodeID)
          .textFieldStyle(.roundedBorder)
        TextField("Input name", text: inputName)
          .textFieldStyle(.roundedBorder)
      }
      .font(.caption)
    }
  }

  private var nodeID: Binding<String> {
    Binding(
      get: { address?.nodeID ?? "" },
      set: { value in
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = address?.inputName ?? ""
        address =
          clean.isEmpty && input.isEmpty
          ? nil : ComfyUIParameterAddress(nodeID: clean, inputName: input)
      })
  }

  private var inputName: Binding<String> {
    Binding(
      get: { address?.inputName ?? "" },
      set: { value in
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = address?.nodeID ?? ""
        address =
          clean.isEmpty && node.isEmpty
          ? nil : ComfyUIParameterAddress(nodeID: node, inputName: clean)
      })
  }
}

private struct WorkflowOutputEditor: View {
  @Binding var nodeID: String?
  var candidates: [ComfyUIWorkflowOutputCandidate]

  var body: some View {
    HStack {
      Text("Output image")
      Spacer()
      Picker("Output image", selection: $nodeID) {
        if nodeID == nil {
          Text("Choose…").tag(nil as String?)
          Divider()
        }
        ForEach(candidates) { candidate in
          Text(candidate.title).tag(candidate.nodeID as String?)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(maxWidth: 310)
      TextField(
        "Node ID",
        text: Binding(
          get: { nodeID ?? "" },
          set: {
            let clean = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            nodeID = clean.isEmpty ? nil : clean
          })
      )
      .textFieldStyle(.roundedBorder)
      .frame(width: 90)
    }
  }
}

extension GenerationMode {
  var comfyUIWorkflowTypeName: String {
    switch self {
    case .textToImage: "Generation"
    case .imageToImage: "Edit"
    case .inpainting: "Inpaint"
    case .selection: "Selection"
    }
  }
}

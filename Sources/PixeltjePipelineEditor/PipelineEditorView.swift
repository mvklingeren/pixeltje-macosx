import AppKit
import PixeltjeModelDesign
import AVKit
import ImageIO
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineFLUX2Runtime
import PixeltjePipelineTextRuntime
import SwiftUI

struct PipelineEditorView: View {
  // Keep the live status views available, but avoid their frequent on-screen updates.
  private static let showsLiveExecutionStatus = false

  @ObservedObject var model: PipelineEditorModel
  private typealias ExpandedCategoriesState = SwiftUI.State<Set<String>>
  @ExpandedCategoriesState private var expandedNodeCategories: Set<String> = []
  @State private var nodeLibrarySearchText = ""
  @State private var collapsedSearchCategories: Set<String> = []
  @State private var diagnosticsScrollRequest = 0
  @State private var areModelPackagesExpanded = false

  let newDocument: () -> Void
  let openDocument: () -> Void
  let saveDocument: () -> Void
  let chooseModelPackage: (PipelineNodeID?) -> Void
  let chooseImageFile: (PipelineNodeID) -> Void
  let chooseVideoFile: (PipelineNodeID) -> Void
  let chooseFilePath: (PipelineNodeID) -> Void
  let showOutputDirectory: () -> Void
  let openGeneratedOutput: (URL) -> Void
  let showPreviewFullScreen: (PipelineNodeID) -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HSplitView {
        if model.isNodeLibraryVisible {
          nodeLibrary
            .frame(minWidth: 152, idealWidth: 176, maxWidth: 224)
        }
        PipelineGraphView(
          model: model,
          settings: model.newWorkflowSettings,
          chooseImageFile: chooseImageFile,
          chooseVideoFile: chooseVideoFile,
          chooseFilePath: chooseFilePath,
          openGeneratedOutput: openGeneratedOutput,
          showPreviewFullScreen: showPreviewFullScreen)
          .frame(minWidth: 480)
        if model.isInspectorVisible {
          inspector
            .frame(minWidth: 240, idealWidth: 285, maxWidth: 380)
        }
      }
      if let selectedNode, selectedNode.kind == .controlTimeline {
        Divider()
        PipelineTimelineEditorView(model: model, node: selectedNode)
          .id(selectedNode.id)
      }
      if Self.showsLiveExecutionStatus {
        Divider()
        statusBar
      }
    }
    .frame(minWidth: 940, minHeight: 620)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Button(action: model.toggleNodeLibrary) {
        Image(systemName: "sidebar.leading")
      }
      .help(model.isNodeLibraryVisible ? "Hide Node Library" : "Show Node Library")
      .accessibilityLabel(
        model.isNodeLibraryVisible ? "Hide Node Library" : "Show Node Library")
      Divider().frame(height: 20)
      Button(action: newDocument) {
        Label("New", systemImage: "doc.badge.plus")
      }
      Button(action: openDocument) {
        Label("Open", systemImage: "folder")
      }
      Button(action: saveDocument) {
        Label("Save", systemImage: "square.and.arrow.down")
      }
      Divider().frame(height: 20)
      Button(action: model.undo) {
        Image(systemName: "arrow.uturn.backward")
      }
      .disabled(!model.canUndo)
      .help(model.undoActionName.isEmpty ? "Undo" : "Undo \(model.undoActionName)")
      Button(action: model.redo) {
        Image(systemName: "arrow.uturn.forward")
      }
      .disabled(!model.canRedo)
      .help(model.redoActionName.isEmpty ? "Redo" : "Redo \(model.redoActionName)")
      Divider().frame(height: 20)
      Menu {
        ForEach(PipelineNodeArrangement.allCases, id: \.title) { arrangement in
          Button(arrangement.title) { model.arrangeNodes(arrangement) }
        }
      } label: {
        Label("Arrange", systemImage: "square.grid.3x3")
      }
      .disabled(!model.canArrangeNodes)
      .help("Arrange workflow nodes")
      Divider().frame(height: 20)
      Spacer()
      Button(action: model.primaryExecutionAction) {
        Label(model.primaryExecutionTitle, systemImage: model.primaryExecutionSymbol)
      }
      .keyboardShortcut(.return, modifiers: [.command])
      .disabled(!model.canUsePrimaryExecutionAction)
      .help(model.isRunning ? model.primaryExecutionTitle : model.runUnavailableReason ?? "Run pipeline")
      if model.isRunning {
        if let loop = model.activeLoop {
          Button("Stop Loop", action: model.stopLoopAfterCurrentCall)
            .disabled(!model.canStopLoop(loop.loopNodeID))
            .help("Finish the current call and save the video if recording")
        }
        Button("Cancel", action: model.cancelExecution)
          .disabled(model.executionState == .cancelling)
      }
      Button(action: model.validate) {
        Label("Validate", systemImage: "checkmark.circle")
      }
      .keyboardShortcut("r", modifiers: [.command])
      if !model.validationReport.isValid {
        Button {
          if !model.isInspectorVisible { model.toggleInspector() }
          diagnosticsScrollRequest += 1
        } label: {
          Label("Show errors", systemImage: "exclamationmark.circle")
        }
        .help("Show validation errors in Diagnostics")
      }
      Divider().frame(height: 20)
      Button(action: model.toggleInspector) {
        Image(systemName: "sidebar.trailing")
      }
      .help(model.isInspectorVisible ? "Hide Inspector" : "Show Inspector")
      .accessibilityLabel(model.isInspectorVisible ? "Hide Inspector" : "Show Inspector")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .padding(10)
  }

  private var nodeLibrary: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Node Library")
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.top, 12)
      Text("Drag a node onto the canvas to add it to the pipeline.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
      TextField("Search nodes", text: $nodeLibrarySearchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Search Node Library")
        .padding(.horizontal, 12)
        .onChange(of: nodeLibrarySearchText) { _, _ in
          collapsedSearchCategories.removeAll()
        }
      List {
        if matchingNodeCategories.isEmpty {
          Text("No matching nodes")
            .foregroundStyle(.secondary)
        }
        ForEach(matchingNodeCategories, id: \.name) { category in
          DisclosureGroup(isExpanded: Binding(
            get: {
              if isSearchingNodeLibrary {
                return !collapsedSearchCategories.contains(category.name)
              }
              return expandedNodeCategories.contains(category.name)
            },
            set: { isExpanded in
              if isSearchingNodeLibrary {
                if isExpanded {
                  collapsedSearchCategories.remove(category.name)
                } else {
                  collapsedSearchCategories.insert(category.name)
                }
              } else {
                if isExpanded {
                  expandedNodeCategories.insert(category.name)
                } else {
                  expandedNodeCategories.remove(category.name)
                }
              }
            }
          )) {
            ForEach(category.nodes, id: \.kind) { descriptor in
              VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                Text(descriptor.kind.rawValue)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
              }
              .padding(.vertical, 2)
              .draggable(PipelineNodeDragPayload.encode(descriptor.kind))
            }
          } label: {
            Text(category.name)
          }
        }
      }
      .listStyle(.sidebar)
    }
  }

  private var inspector: some View {
    ScrollViewReader { proxy in
      inspectorContent
        .task(id: diagnosticsScrollRequest) {
          guard diagnosticsScrollRequest > 0 else { return }
          await Task.yield()
          guard !Task.isCancelled else { return }
          withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo("diagnostics", anchor: .top)
          }
          diagnosticsScrollRequest = 0
        }
    }
  }

  private var inspectorContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        PipelineTitleEditor(model: model)
        if let selectedNode,
          selectedNode.id == PipelineGraphOutputs.selectedOutputNode(
            in: model.document, registry: .pipelineEditor)?.id {
          resultsInspector
        }
        if model.document.nodes.contains(where: { $0.kind == .stateInput }) {
          Divider()
          Text("JSON State").font(.headline)
          ForEach(model.stateScalars.keys.sorted(), id: \.self) { key in
            LabeledContent(key.capitalized, value: model.stateScalars[key] ?? "")
              .monospacedDigit()
          }
          if model.currentStateJSON != nil {
            LabeledContent("Detected subjects", value: model.detectedInteractionSubjects.isEmpty
              ? "None" : model.detectedInteractionSubjects.joined(separator: ", "))
            if model.detectedInteractionSubjects.isEmpty {
              Text("No subjects were detected in this frame. A click advances the turn without changing the score.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          ScrollView {
            Text(model.currentStateJSON ?? model.initialStateJSON)
              .font(.caption.monospaced()).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 160)
          HStack {
            Button("Load State…", action: model.loadState)
            Button("Reset State", action: model.resetState)
          }.disabled(model.isRunning)
          Text("With automatic image saving enabled, each completed image also saves a .state.json checkpoint and .turn.json journal. Select a subject on the Trackpad to commit a turn.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        executionControls
        Divider()
        if let node = selectedNode {
          PipelineNodeTitleEditor(model: model, node: node)
            .id(node.id)
          LabeledContent("ID", value: node.id.rawValue)
          LabeledContent("Kind", value: node.kind.rawValue)
          if node.kind == .trackpad, let focus = model.plannedFocus(for: node.id) {
            LabeledContent(model.hasStateFeedbackPath ? "Selected subject" : "Planned focus", value: focus)
              .help("Subject under the Trackpad point in the latest prompt-derived scene plan.")
          }
          Divider()
          if node.kind == .controlTimeline {
            Text("Keyframes")
              .font(.subheadline.weight(.semibold))
            Text("Edit this node's tracks in the timeline below the graph. The Value input and output keep the same type.")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if node.kind == .controlLoop {
            loopNodeControls(node)
          } else {
            Text("Parameters").font(.subheadline.weight(.semibold))
            let descriptor = PipelineGraphEditing.descriptor(for: node, registry: .pipelineEditor)
            let parameterNames = Set(node.parameters.keys)
              .union(descriptor?.parameters.map(\.name) ?? [])
              .sorted()
            if parameterNames.isEmpty {
              Text("No parameters")
                .foregroundStyle(.secondary)
            } else {
              ForEach(parameterNames, id: \.self) { name in
                let seedIsConnected = node.kind == CoreAITextPipelineFamily.compositeNodeKind
                  && name == "seed"
                  && model.document.connections.contains {
                    $0.input.nodeID == node.id && $0.input.port == "seed"
                  }
                if node.kind == .seedInput, name == "mode" {
                  Picker("Seed", selection: Binding(
                    get: {
                      if case .string(let mode)? = node.parameters["mode"] { return mode }
                      return "fixed"
                    },
                    set: { model.setParameter(.string($0), named: "mode", for: node.id) })) {
                    Text("Fixed").tag("fixed")
                    Text("Random each run").tag("random")
                  }
                  .disabled(model.isRunning)
                } else if node.kind == .modelTrain, name == "task" {
                  Picker("Training task", selection: Binding(
                    get: { node.parameters["task"]?.stringValue ?? "pairedImages" },
                    set: { model.setParameter(.string($0), named: "task", for: node.id) })) {
                    Text("Paired image").tag("pairedImages")
                    Text("Classification").tag("classification")
                  }
                  .disabled(model.isRunning)
                } else if node.kind == .modelTrain, name == "datasetPreset" {
                  Picker("Dataset", selection: Binding(
                    get: { node.parameters["datasetPreset"]?.stringValue ?? "none" },
                    set: { model.setParameter(.string($0), named: "datasetPreset", for: node.id) })) {
                    Text("Connected dataset").tag("none")
                    Text("MNIST digits").tag("mnist")
                  }
                  .disabled(model.isRunning)
                } else if node.kind == .modelLayer, name == "operation" {
                  Picker("Operation", selection: Binding(
                    get: { node.parameters["operation"]?.stringValue ?? "conv2d" },
                    set: { model.setParameter(.string($0), named: "operation", for: node.id) })) {
                    Text("Conv2D").tag("conv2d")
                    Text("ReLU").tag("relu")
                    Text("Dense").tag("dense")
                    Text("Flatten").tag("flatten")
                  }
                  .disabled(model.isRunning)
                } else if node.kind == .modelMerge, name == "operation" {
                  Picker("Operation", selection: Binding(
                    get: { node.parameters["operation"]?.stringValue ?? "add" },
                    set: { model.setParameter(.string($0), named: "operation", for: node.id) })) {
                    Text("Add").tag("add")
                    Text("Concatenate").tag("concatenate")
                  }
                  .disabled(model.isRunning)
                } else if node.kind == .modelInput, name == "dtype" {
                  LabeledContent("dtype", value: "float32")
                } else if node.kind == .primitiveFilePath, name == "mode" {
                  Picker("Path", selection: Binding(
                    get: {
                      if case .string(let mode)? = node.parameters["mode"] { return mode }
                      return "relative"
                    },
                    set: { model.setParameter(.string($0), named: "mode", for: node.id) })) {
                    Text("Relative to source folder").tag("relative")
                    Text("Absolute").tag("absolute")
                  }
                  .disabled(model.isRunning)
                } else if node.kind == .seedInput, name == "value",
                  node.parameters["mode"] == .string("random") {
                  EmptyView()
                } else if node.kind == FLUX2Klein9BSplitFamily.nodeKind,
                  name == "steps" {
                  LabeledContent(name) {
                    Stepper(
                      value: Binding(
                        get: { model.klein9BSteps(for: node.id) },
                        set: { model.setKlein9BSteps($0, for: node.id) }),
                      in: 1...20
                    ) {
                      Text("\(model.klein9BSteps(for: node.id))")
                        .monospacedDigit()
                    }
                    .fixedSize()
                    .disabled(model.isRunning)
                    .help("Set 1–20 denoising steps for this Klein 9B workflow.")
                  }
                } else if let parameter = descriptor?.parameter(named: name) {
                  PipelineParameterField(
                    name: name,
                    value: node.parameters[name] ?? parameter.defaultValue,
                    valueType: parameter.valueType,
                    isEnabled: !model.isRunning && !seedIsConnected,
                    beginEditing: { model.beginParameterEdit(named: name, for: node.id) },
                    setValue: { model.setParameter($0, named: name, for: node.id) },
                    endEditing: { model.endParameterEdit(named: name, for: node.id) })
                    .id("\(node.id.rawValue):\(name)")
                    .help(seedIsConnected
                      ? "The connected Seed node supplies this value."
                      : "")
                  if seedIsConnected {
                    Text("Controlled by the connected Seed node")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                } else {
                  LabeledContent(name, value: node.parameters[name]?.displayValue ?? "")
                }
              }
              if node.kind == .primitiveFilePath {
                Button("Choose File…") { chooseFilePath(node.id) }
                  .disabled(model.isRunning)
              }
            }
          }
          Text("Resources").font(.subheadline.weight(.semibold))
          if model.packageID(for: node) != nil {
            Button("Choose Package for This Node…") {
              chooseModelPackage(node.id)
            }
            .disabled(model.isRunning)
          }
          if node.resources.isEmpty {
            Text("No linked resources")
              .foregroundStyle(.secondary)
          } else {
            ForEach(node.resources.keys.sorted(), id: \.self) { slot in
              VStack(alignment: .leading, spacing: 2) {
                Text(slot).font(.caption.weight(.semibold))
                Text(node.resources[slot]?.displayValue ?? "")
                  .font(.caption.monospaced())
              }
            }
          }
          if node.kind == .imageOutput || node.kind == .videoOutput {
            Divider()
            outputFileInspector
          }
          Button("Delete Node", role: .destructive) {
            model.deleteNode(node.id)
          }
        } else if let connection = selectedConnection {
          LabeledContent("Connection", value: connection.id.rawValue)
          LabeledContent(
            "Output",
            value: "\(connection.output.nodeID.rawValue).\(connection.output.port)")
          LabeledContent(
            "Input",
            value: "\(connection.input.nodeID.rawValue).\(connection.input.port)")
          Button("Delete Connection", role: .destructive) {
            model.deleteConnection(connection.id)
          }
        } else {
          Text("Select a node to inspect its parameters and linked resources.")
            .foregroundStyle(.secondary)
        }
        Divider()
        HStack {
          Text("Diagnostics").font(.headline)
          Spacer()
          Button(action: copyDiagnostics) {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .controlSize(.small)
          .disabled(model.validationReport.diagnostics.isEmpty)
          .help("Copy diagnostics")
        }
        .id("diagnostics")
        if model.shaderValidationPending {
          Label("Checking Metal shader…", systemImage: "hourglass")
            .foregroundStyle(.secondary)
        } else if model.validationReport.diagnostics.isEmpty {
          Label("No validation issues", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          ForEach(model.validationReport.diagnostics) { diagnostic in
            VStack(alignment: .leading, spacing: 3) {
              Label(
                diagnostic.severity == .error ? "Error" : "Warning",
                systemImage: diagnostic.severity == .error
                  ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                .font(.caption.weight(.semibold))
              Text(diagnostic.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func copyDiagnostics() {
    let text = model.validationReport.diagnostics.map { diagnostic in
      let severity = diagnostic.severity == .error ? "Error" : "Warning"
      return "\(severity): \(diagnostic.message)"
    }
    .joined(separator: "\n")
    guard !text.isEmpty else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private var outputFileInspector: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Generated Output").font(.subheadline.weight(.semibold))
      Text(model.executionProfile?.outputKind == .video
        ? "The completed MP4 is saved in the temporary output folder when the loop ends."
        : model.isModelTraining
          ? "Training runs save checkpoints and verified .aimodel packages in Documents/Pixeltje/Model Runs."
        : model.newWorkflowSettings.saveGeneratedImagesToDisk
          ? "Completed images are stored as PNG files in a temporary folder."
          : "Completed images are previewed in memory. Enable automatic image saving in Settings to keep PNG files.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if model.isModelTraining || model.newWorkflowSettings.saveGeneratedImagesToDisk
        || model.generatedOutputURL != nil {
        Button(action: showOutputDirectory) {
          Text(model.currentOutputDirectoryURL.path)
            .font(.caption2.monospaced())
            .foregroundColor(.accentColor)
            .underline()
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .help("Open the temporary output folder in Finder")
        Button(action: copyOutputDirectoryPath) {
          Label("Copy Path", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
      }
      if let outputURL = model.generatedOutputURL {
        VStack(alignment: .leading, spacing: 2) {
          Text("Latest").foregroundStyle(.secondary)
          Text(outputURL.lastPathComponent)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          openGeneratedOutput(outputURL)
        } label: {
          Label(
            outputURL.pathExtension.lowercased() == "mp4" ? "Open Video"
              : outputURL.pathExtension.lowercased() == "aimodel" ? "Reveal Model"
              : model.isTextExecution ? "Open Output" : "Open in Preview",
            systemImage: "arrow.up.forward.app")
        }
        .controlSize(.small)
      } else if model.generatedPreview != nil {
        Text("Latest image is available in Results.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("No completed output in this editor session.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func copyOutputDirectoryPath() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(model.currentOutputDirectoryURL.path, forType: .string)
  }

  private var executionControls: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("Execution").font(.headline)
      if model.isBaseTestSetExecution {
        Text("Runs the saved graph with local source media.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if model.isNativeNodeExecution {
        Text("Set saved input values on their graph nodes.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        TextField("Prompt", text: $model.prompt, axis: .vertical)
          .lineLimit(2...5)
          .textFieldStyle(.roundedBorder)
      }
      if model.isTextExecution && model.isNativeNodeExecution {
        Text("Text generation settings are set on the model node.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if model.isTextExecution && !model.isBaseTestSetExecution {
        TextField("System instructions", text: $model.systemPrompt, axis: .vertical)
          .lineLimit(2...5)
          .textFieldStyle(.roundedBorder)
        TextField("Seed", text: $model.seedText)
          .textFieldStyle(.roundedBorder)
        HStack {
          Text("Response tokens")
          Spacer()
          TextField(
            "Response tokens",
            value: Binding(
              get: { model.maximumResponseTokens },
              set: { model.maximumResponseTokens = min(max($0, 1), 4096) }),
            format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
            .help("Enter 1–4096. The prompt and response share the model's context limit.")
        }
        HStack {
          Text("Temperature")
          Slider(value: $model.temperature, in: 0...2, step: 0.05)
          Text(model.temperature.formatted(.number.precision(.fractionLength(2))))
            .monospacedDigit()
            .frame(width: 34, alignment: .trailing)
        }
        Stepper("Top K: \(model.topK)", value: $model.topK, in: 1...1000)
      } else if model.isNativeNodeExecution {
        Text("Negative prompt, seed, steps, and guidance are set on graph nodes.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if !model.isBaseTestSetExecution {
        TextField("Negative prompt", text: $model.negativePrompt, axis: .vertical)
          .lineLimit(1...3)
          .textFieldStyle(.roundedBorder)
        HStack {
          TextField("Seed", text: $model.seedText)
            .textFieldStyle(.roundedBorder)
          Stepper("Steps: \(model.steps)", value: $model.steps, in: 1...20)
            .fixedSize()
        }
        HStack {
          Text("Guidance")
          Slider(value: $model.guidance, in: 0...10, step: 0.1)
            .disabled(!model.canEditGuidance)
          Text(model.guidance.formatted(.number.precision(.fractionLength(1))))
            .monospacedDigit()
            .frame(width: 30, alignment: .trailing)
        }
      }
      LabeledContent("Outcome", value: model.outcomeLabel)
      if model.executionProfile?.outputKind == .image {
        LabeledContent("Output size", value: model.outputSizeLabel)
      }
      if model.activeTimeline != nil {
        LabeledContent("Timeline", value: "Output → Timeline → Start")
      } else if model.activeLoop != nil {
        LabeledContent("Loop", value: "Output → Loop → Start")
      } else {
        Text("Runs once unless the selected output connects through Loop or Timeline to Start.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 8) {
        if model.modelPackageNodes.isEmpty {
          Text(model.isBaseTestSetExecution ? "Source Media Folder" : "Core AI package")
            .font(.caption.weight(.semibold))
          Text(model.modelPackageURL.path)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(model.modelPackageURL.path)
          Button(model.isBaseTestSetExecution ? "Choose Source Media Folder…" : "Choose…") {
            chooseModelPackage(nil)
          }
        } else {
          DisclosureGroup(isExpanded: $areModelPackagesExpanded) {
            ForEach(model.modelPackageNodes, id: \.id) { node in
              VStack(alignment: .leading, spacing: 3) {
                Text(node.title ?? model.displayName(
                  forPackageID: model.packageID(for: node) ?? ""))
                  .font(.caption.weight(.medium))
                if let packageURL = model.packageURL(for: node) {
                  Text(packageURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(packageURL.path)
                }
                Button("Choose…") { chooseModelPackage(node.id) }
                  .disabled(model.isRunning)
              }
            }
          } label: {
            Text("Model packages").font(.caption.weight(.semibold))
          }
        }
        HStack {
          Button("Recheck", action: model.inspectModelPackage)
          Spacer()
          if let inspection = model.packageInspection {
            Image(systemName: inspection.isUsable ? "checkmark.circle.fill" : "xmark.circle.fill")
              .foregroundStyle(inspection.isUsable ? .green : .red)
              .help(inspection.summary)
          }
        }
        if model.isBaseTestSetExecution,
          let inspection = model.packageInspection,
          !inspection.isUsable {
          Text(inspection.missingComponents.isEmpty
            ? inspection.summary
            : "Missing source media: \(inspection.missingComponents.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if Self.showsLiveExecutionStatus {
        executionStatus
      }
      HStack {
        Button(action: model.primaryExecutionAction) {
          Label(model.primaryExecutionTitle, systemImage: model.primaryExecutionSymbol)
        }
        .disabled(!model.canUsePrimaryExecutionAction)
        .help(model.isRunning ? model.primaryExecutionTitle : model.runUnavailableReason ?? "Run pipeline")
        if model.isRunning {
          Button("Cancel", action: model.cancelExecution)
            .disabled(model.executionState == .cancelling)
          if let loop = model.activeLoop {
            Button("Stop Loop", action: model.stopLoopAfterCurrentCall)
              .disabled(!model.canStopLoop(loop.loopNodeID))
          }
        }
        Button("Clear Output", action: model.clearOutput)
          .disabled(!model.canClearOutput)
          .help("Clear the displayed result. Saved files stay on disk.")
      }
    }
  }

  private var executionStatus: some View {
    let progress = model.executionProgress
    let totalUnits = progress?.totalUnitCount ?? 0
    let message = model.executionState == .paused ? "Paused"
      : model.isRunning ? progress?.message ?? "Starting pipeline…" : model.statusMessage

    return VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Call", value: model.currentCall > 0
        ? model.activeCallProgressLabel : "—")
        .lineLimit(1)
      LabeledContent("Seed", value: model.currentSeed.map(String.init) ?? "—")
        .lineLimit(1)
      HStack(spacing: 8) {
        ProgressView(
          value: Double(progress?.completedUnitCount ?? 0),
          total: Double(max(totalUnits, 1)))
        ZStack {
          if model.isRunning && totalUnits == 0 {
            ProgressView().controlSize(.small)
          }
        }
        .frame(width: 16, height: 16)
      }
      .frame(height: 16)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(message)
    }
  }

  private var resultsInspector: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Results").font(.headline)
        Spacer()
        if model.selectedResultCall != nil {
          Button("Follow Latest") {
            model.selectCompletedResult(call: nil)
          }
          .controlSize(.small)
        }
      }
      if model.completedResults.isEmpty {
        Text(model.isRunning ? "Waiting for the first completed call…" : "No completed calls yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(model.completedResults.reversed()) { result in
              Button {
                model.selectCompletedResult(call: result.call)
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 7) {
                    Text("Call \(result.call)")
                      .font(.caption.weight(.semibold))
                    if let seed = result.seed {
                      Text("Seed \(seed)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    Text(result.durationLabel)
                      .font(.caption2.monospacedDigit())
                      .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if model.selectedCompletedResult?.call == result.call {
                      Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    }
                  }
                  Text(result.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                  model.selectedCompletedResult?.call == result.call
                    ? Color.accentColor.opacity(0.12) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 6))
              }
              .buttonStyle(.plain)
            }
          }
        }
        .frame(height: min(CGFloat(model.completedResults.count) * 46, 210))
        if let result = model.selectedCompletedResult {
          HStack {
            Text("Call \(result.call) output")
              .font(.subheadline.weight(.semibold))
            Spacer()
            if let text = result.text, !text.isEmpty {
              Button {
                copyGeneratedText(text)
              } label: {
                Label("Copy", systemImage: "doc.on.doc")
              }
              .controlSize(.small)
              .labelStyle(.iconOnly)
              .help("Copy this call’s text")
            }
            if let url = result.outputURL {
              Button {
                openGeneratedOutput(url)
              } label: {
                Label("Open File", systemImage: "arrow.up.forward.app")
              }
              .controlSize(.small)
              .labelStyle(.iconOnly)
              .help("Open this call’s saved output")
            }
          }
          if let text = result.text {
            ScrollView {
              Text(text.isEmpty ? "This call returned empty text." : text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(minHeight: 80, maxHeight: 240)
            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
          } else if let image = model.selectedCompletedPreview {
            Image(nsImage: image)
              .resizable()
              .interpolation(.high)
              .aspectRatio(contentMode: .fit)
              .frame(maxWidth: .infinity, maxHeight: 260)
              .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
          } else if let url = result.outputURL {
            Text(url.lastPathComponent)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          } else {
            Text("This call produced no output.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        if model.completedResults.first?.call != 1 {
          Text("Showing the latest 100 calls. Earlier output files remain in the output folder.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if model.isRunning,
        model.currentCall > (model.completedResults.last?.call ?? 0) {
        if !model.generatedText.isEmpty {
          Text("Call \(model.currentCall) streaming")
            .font(.subheadline.weight(.semibold))
          ScrollView {
            Text(model.generatedText)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
          }
          .frame(minHeight: 80, maxHeight: 180)
          .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        } else if let preview = model.generatedPreview {
          Text("Call \(model.currentCall) preview")
            .font(.subheadline.weight(.semibold))
          Image(nsImage: preview)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 260)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }

  private func copyGeneratedText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private var statusBar: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(model.engineSnapshot == nil ? Color.orange : Color.green)
        .frame(width: 7, height: 7)
      Text(model.isRunning ? model.statusMessage : model.runUnavailableReason ?? model.statusMessage)
        .help(model.isRunning ? model.statusMessage : model.runUnavailableReason ?? model.statusMessage)
      Spacer()
      if let snapshot = model.engineSnapshot {
        Text("Engine v\(snapshot.engineVersion) · \(snapshot.deviceName)")
      }
      Text("\(model.document.nodes.count) nodes")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .frame(height: 28)
  }

  private var selectedNode: PipelineNode? {
    guard case .node(let selectedNodeID) = model.selection else { return nil }
    return model.document.nodes.first { $0.id == selectedNodeID }
  }

  private var selectedConnection: PipelineConnection? {
    guard case .connection(let connectionID) = model.selection else { return nil }
    return (model.document.connections + model.document.controlConnections)
      .first { $0.id == connectionID }
  }

  @ViewBuilder
  private func loopNodeControls(_ node: PipelineNode) -> some View {
    if let settings = model.loopSettings(for: node.id) {
      Text("Loop").font(.subheadline.weight(.semibold))
      Text("Connect the selected output’s completed port here, then connect repeat to Start’s again port.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("For Increment Seed, also connect Loop’s incrementSeed port to the Seed node that feeds the selected output.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Text("Max calls")
        TextField("Calls", value: Binding(
          get: { settings.maxCalls ?? 100 },
          set: { model.setLoopMaxCalls(min(max($0, 1), 10_000), for: node.id) }),
          format: .number)
          .frame(width: 74)
          .disabled(model.isRunning || settings.maxCalls == nil)
        Toggle("Infinite", isOn: Binding(
          get: { settings.maxCalls == nil },
          set: { model.setLoopMaxCalls($0 ? nil : 100, for: node.id) }))
          .disabled(model.isRunning)
      }
      Toggle("Auto repeat", isOn: Binding(
        get: { settings.autoRepeat },
        set: { model.setLoopAutoRepeat($0, for: node.id) }))
        .disabled(model.isRunning || settings.maxCalls == nil)
        .help("After the finite call count, restart at call index zero until Stop Loop or Cancel.")
      PipelineLoopDelayControl(
        milliseconds: settings.delayMilliseconds,
        isEnabled: !model.isRunning,
        setMilliseconds: { model.setLoopDelay($0, for: node.id) })
        .id(node.id)
      HStack {
        Text("Limit Hz")
        TextField("Hz", value: Binding(
          get: { settings.limitHz ?? 0 },
          set: { model.setLoopLimitHz($0 == 0 ? nil : min(max($0, 1), 240), for: node.id) }),
          format: .number)
          .frame(width: 74)
          .disabled(model.isRunning)
        Text("0 = unlimited")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .help("Caps whole-graph call starts at 1–240 Hz; longer calls remain slower.")
      Toggle("Auto pause before next call", isOn: Binding(
        get: { settings.autoPause },
        set: { model.setLoopAutoPause($0, for: node.id) }))
        .disabled(model.executionState == .cancelling
          || (settings.feedback == .stateAndImage && settings.autoPause))
      Picker("Seed", selection: Binding(
        get: { settings.seedStrategy },
        set: { model.setLoopSeedStrategy($0, for: node.id) })) {
          Text("Use graph seed").tag(PipelineLoopSettings.SeedStrategy.fixed)
          Text("Increment connected Seed").tag(PipelineLoopSettings.SeedStrategy.increment)
        }
        .disabled(model.isRunning)
      Picker("Previous output", selection: Binding(
        get: { settings.feedback },
        set: { model.setLoopFeedback($0, for: node.id) })) {
          Text("Do not feed back").tag(Optional<PipelineLoopSettings.Feedback>.none)
          if model.availableFeedback.contains(.textToPrompt) {
            Text("Text → Prompt").tag(PipelineLoopSettings.Feedback.textToPrompt as PipelineLoopSettings.Feedback?)
          }
          if model.availableFeedback.contains(.imageToSourceImage) {
            Text("Image → Source Image").tag(PipelineLoopSettings.Feedback.imageToSourceImage as PipelineLoopSettings.Feedback?)
          }
          if model.availableFeedback.contains(.scenePlanToNextView) {
            Text("Scene Plan → Next View").tag(
              PipelineLoopSettings.Feedback.scenePlanToNextView as PipelineLoopSettings.Feedback?)
          }
          if model.availableFeedback.contains(.scenePlanAndImageToNextView) {
            Text("Scene Plan + Image → Next View").tag(
              PipelineLoopSettings.Feedback.scenePlanAndImageToNextView as PipelineLoopSettings.Feedback?)
          }
          if model.availableFeedback.contains(.stateAndImage) {
            Text("State + Image → Next Turn").tag(
              PipelineLoopSettings.Feedback.stateAndImage as PipelineLoopSettings.Feedback?)
          }
          if model.availableFeedback.contains(.imageAndTextToNextView) {
            Text("Image + Text → Next View").tag(
              PipelineLoopSettings.Feedback.imageAndTextToNextView as PipelineLoopSettings.Feedback?)
          }
        }
        .disabled(model.isRunning)
      if let issue = model.loopIssue {
        Text(issue).font(.caption).foregroundStyle(.red)
      }
    } else {
      Text("Loop settings are invalid.").foregroundStyle(.red)
    }
  }

  private var nodeCategories: [(name: String, nodes: [PipelineNodeDescriptor])] {
    Dictionary(grouping: PipelineNodeRegistry.pipelineEditor.allDescriptors, by: \.category)
      .map { (name: $0.key, nodes: $0.value) }
      .sorted { $0.name < $1.name }
  }

  private var nodeLibrarySearchQuery: String {
    nodeLibrarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearchingNodeLibrary: Bool {
    !nodeLibrarySearchQuery.isEmpty
  }

  private var matchingNodeCategories: [(name: String, nodes: [PipelineNodeDescriptor])] {
    let query = nodeLibrarySearchQuery
    guard !query.isEmpty else { return nodeCategories }
    return nodeCategories.compactMap { category in
      let nodes = category.name.localizedCaseInsensitiveContains(query)
        ? category.nodes
        : category.nodes.filter {
          $0.displayName.localizedCaseInsensitiveContains(query)
            || $0.kind.rawValue.localizedCaseInsensitiveContains(query)
        }
      return nodes.isEmpty ? nil : (name: category.name, nodes: nodes)
    }
  }
}

private struct PipelineLoopDelayControl: View {
  let milliseconds: Int
  let isEnabled: Bool
  let setMilliseconds: (Int) -> Void

  @State private var draftMilliseconds: String
  @FocusState private var isFieldFocused: Bool

  init(milliseconds: Int, isEnabled: Bool, setMilliseconds: @escaping (Int) -> Void) {
    self.milliseconds = milliseconds
    self.isEnabled = isEnabled
    self.setMilliseconds = setMilliseconds
    _draftMilliseconds = State(initialValue: String(milliseconds))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Delay")
      HStack(alignment: .top) {
        VStack(spacing: 2) {
          Slider(value: Binding(
            get: { Self.sliderPosition(for: milliseconds) },
            set: { setMilliseconds(Self.milliseconds(for: $0)) }),
            in: 0...190, step: 1)
            .disabled(!isEnabled)
            .accessibilityLabel("Delay")
            .help("0–1 s in 10 ms steps; 1–10 s in 100 ms steps")
          HStack {
            Text("0 ms")
            Spacer()
            Text("1 s")
            Spacer()
            Text("10 s")
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        TextField("Delay", text: $draftMilliseconds)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 66)
          .focused($isFieldFocused)
          .disabled(!isEnabled)
          .help("Enter 0–60,000 ms")
          .onSubmit { isFieldFocused = false }
        Text("ms")
      }
    }
    .onChange(of: milliseconds) { _, value in
      if !isFieldFocused { draftMilliseconds = String(value) }
    }
    .onChange(of: isFieldFocused) { _, focused in
      if !focused { commitDraft() }
    }
  }

  private func commitDraft() {
    let text = draftMilliseconds.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int(text), (0...60_000).contains(value) else {
      draftMilliseconds = String(milliseconds)
      return
    }
    setMilliseconds(value)
    draftMilliseconds = String(value)
  }

  private static func sliderPosition(for milliseconds: Int) -> Double {
    let value = min(max(milliseconds, 0), 10_000)
    return value <= 1_000 ? Double(value) / 10 : 100 + Double(value - 1_000) / 100
  }

  private static func milliseconds(for sliderPosition: Double) -> Int {
    let position = min(max(Int(sliderPosition.rounded()), 0), 190)
    return position <= 100 ? position * 10 : 1_000 + (position - 100) * 100
  }
}

private struct PipelineTitleEditor: View {
  @ObservedObject var model: PipelineEditorModel
  @State private var draftTitle = ""
  @State private var isEditing = false
  @FocusState private var isTitleFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Workflow")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        if isEditing {
          TextField("Workflow title", text: $draftTitle)
            .textFieldStyle(.roundedBorder)
            .focused($isTitleFocused)
            .onSubmit { finishEditing(save: true) }
            .onExitCommand { finishEditing(save: false) }
            .onChange(of: isTitleFocused) { _, focused in
              if !focused { finishEditing(save: true) }
            }
          Button(action: { finishEditing(save: true) }) {
            Image(systemName: "checkmark")
          }
          .help("Save workflow title")
          .accessibilityLabel("Save workflow title")
        } else {
          Text(model.document.name)
            .font(.headline)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button(action: beginEditing) {
            Image(systemName: "pencil")
          }
          .help("Rename workflow")
          .accessibilityLabel("Rename workflow")
        }
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
    .onChange(of: model.document.id) { _, _ in
      isEditing = false
      isTitleFocused = false
    }
  }

  private func beginEditing() {
    draftTitle = model.document.name
    isEditing = true
    isTitleFocused = true
  }

  private func finishEditing(save: Bool) {
    guard isEditing else { return }
    isEditing = false
    isTitleFocused = false
    if save {
      let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty { model.setDocumentName(title) }
    }
  }
}

private struct PipelineNodeTitleEditor: View {
  @ObservedObject var model: PipelineEditorModel
  let node: PipelineNode

  @State private var draftTitle = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    LabeledContent("Title") {
      TextField("Node title", text: $draftTitle)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .disabled(model.isRunning)
        .onSubmit { isFocused = false }
        .onChange(of: isFocused) { _, focused in
          if !focused { saveTitle() }
        }
        .onChange(of: node.title) { _, title in
          if !isFocused { draftTitle = title ?? "" }
        }
        .onDisappear(perform: saveTitle)
    }
    .onAppear { draftTitle = node.title ?? "" }
  }

  private func saveTitle() {
    model.setNodeTitle(draftTitle, for: node.id)
  }
}

private enum PipelineNodeDragPayload {
  private static let prefix = "org.pixeltje.pipeline-node:"

  static func encode(_ kind: PipelineNodeKind) -> String {
    prefix + kind.rawValue
  }

  static func decode(_ value: String) -> PipelineNodeKind? {
    guard value.hasPrefix(prefix) else { return nil }
    return PipelineNodeKind(rawValue: String(value.dropFirst(prefix.count)))
  }
}

struct PipelineGraphMetrics {
  static let standardWidth: CGFloat = 220
  static let previewWidth: CGFloat = 300
  static let previewHeight: CGFloat = 280
  static let metalRenderWidth: CGFloat = 340
  static let metalRenderHeight: CGFloat = 430
  static let resizableMinWidth: CGFloat = 200
  static let resizableMinHeight: CGFloat = 160
  static let resizableMaxWidth: CGFloat = 900
  static let resizableMaxHeight: CGFloat = 700
  static let trackpadAspectRatio: CGFloat = 200.0 / 116.0
  static let headerHeight: CGFloat = 50
  static let portRowHeight: CGFloat = 24
  static let bottomPadding: CGFloat = 8

  static func descriptor(
    for node: PipelineNode
  ) -> PipelineNodeDescriptor? {
    PipelineGraphEditing.descriptor(for: node, registry: .pipelineEditor)
  }

  static func contentHeight(for node: PipelineNode) -> CGFloat {
    switch node.kind {
    case .imageInput:
      if case .string(let name)? = node.parameters["sourceName"], !name.isEmpty {
        return 176
      }
      return 76
    case .videoInput: return 76
    case .primitiveFilePath: return 96
    case .primitiveString: return 156
    case .stateInput: return 116
    case .primitiveInt, .primitiveFloat, .primitiveBoolean: return 56
    case .videoOutput: return 90
    case .assetCache: return 180
    case .trackpad: return 194
    case .controlLoop: return 72
    case .markdownNote: return 156
    default: return 0
    }
  }

  static func size(for node: PipelineNode, in document: PipelineDocument) -> CGSize {
    let requiredHeight = minimumNodeHeight(for: node)
    let stored = document.presentation?.nodeSizes[node.id.rawValue]
    if node.kind == .imagePreview || node.kind == .videoPreview
      || node.kind == .renderMetal || node.kind == .gpuProgram
      || node.kind == .assetCache
      || node.kind == .markdownNote || node.kind == .trackpad
      || node.kind == .primitiveString {
      let defaultWidth: CGFloat = switch node.kind {
      case .imagePreview, .videoPreview: previewWidth
      case .renderMetal, .gpuProgram: metalRenderWidth
      case .assetCache: metalRenderWidth
      case .markdownNote, .primitiveString: 270
      default: standardWidth
      }
      let defaultHeight: CGFloat = switch node.kind {
      case .imagePreview, .videoPreview: previewHeight
      case .renderMetal, .gpuProgram: metalRenderHeight
      case .assetCache: metalRenderHeight
      default: requiredHeight
      }
      let minimum = minimumResizableSize(for: node)
      return CGSize(
        width: min(max(CGFloat(stored?.width ?? Double(defaultWidth)), minimum.width),
          resizableMaxWidth),
        height: min(max(CGFloat(stored?.height ?? Double(defaultHeight)), minimum.height),
          resizableMaxHeight))
    }
    return CGSize(
      width: min(max(stored?.width ?? standardWidth, 200), 420),
      height: min(max(stored?.height ?? requiredHeight, requiredHeight), 420))
  }

  static func minimumResizableSize(for node: PipelineNode) -> CGSize {
    if node.kind == .trackpad {
      return CGSize(width: standardWidth, height: minimumNodeHeight(for: node))
    }
    return CGSize(width: resizableMinWidth, height: resizableMinHeight)
  }

  static func contentHeight(for node: PipelineNode, in size: CGSize) -> CGFloat {
    if node.kind == .primitiveString {
      let rowCount = max(descriptor(for: node)?.inputs.count ?? 0,
        descriptor(for: node)?.outputs.count ?? 0)
      return max(64, size.height - headerHeight
        - CGFloat(rowCount) * portRowHeight - bottomPadding)
    }
    guard node.kind == .trackpad || node.kind == .assetCache else {
      return contentHeight(for: node)
    }
    return max(contentHeight(for: node), size.height - minimumNodeHeight(for: node)
      + contentHeight(for: node))
  }

  static func bottomPadding(for node: PipelineNode) -> CGFloat {
    node.kind == .trackpad ? 32 : bottomPadding
  }

  static func metalPreviewPixelSize(for node: PipelineNode, in document: PipelineDocument)
    -> (width: Int, height: Int) {
    let size = size(for: node, in: document)
    let descriptor = descriptor(for: node)
    let rowCount = max(descriptor?.inputs.count ?? 0, descriptor?.outputs.count ?? 0)
    // Match the card's image area: eight points on each side and twelve below.
    let width = max(1, Int((size.width - 16).rounded()))
    let height = max(1, Int((size.height - headerHeight
      - CGFloat(rowCount) * portRowHeight - 12).rounded()))
    return (width, height)
  }

  static func portY(for node: PipelineNode, index: Int, in size: CGSize) -> CGFloat {
    headerHeight + contentHeight(for: node, in: size) + CGFloat(index) * portRowHeight
      + portRowHeight / 2
  }

  private static func minimumNodeHeight(for node: PipelineNode) -> CGFloat {
    let descriptor = descriptor(for: node)
    let rowCount = max(descriptor?.inputs.count ?? 0, descriptor?.outputs.count ?? 0)
    return headerHeight + contentHeight(for: node)
      + CGFloat(rowCount) * portRowHeight + bottomPadding(for: node)
  }
}

private struct PipelineConnectionDrag {
  var output: PipelinePortReference
  var location: CGPoint
}

private struct PipelineNodeMove {
  var nodeID: PipelineNodeID
  var origin: PipelinePoint
}

private struct PipelineNodeResize {
  var nodeID: PipelineNodeID
  var size: CGSize
}

private struct PipelineConnectionCurve: Shape {
  var start: CGPoint
  var end: CGPoint

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: start)
    let offset = max(60, abs(end.x - start.x) * 0.45)
    path.addCurve(
      to: end,
      control1: CGPoint(x: start.x + offset, y: start.y),
      control2: CGPoint(x: end.x - offset, y: end.y))
    return path
  }
}

private struct PipelineGraphView: View {
  @ObservedObject var model: PipelineEditorModel
  @ObservedObject var settings: PipelineNewWorkflowSettings
  let chooseImageFile: (PipelineNodeID) -> Void
  let chooseVideoFile: (PipelineNodeID) -> Void
  let chooseFilePath: (PipelineNodeID) -> Void
  let openGeneratedOutput: (URL) -> Void
  let showPreviewFullScreen: (PipelineNodeID) -> Void

  @SwiftUI.State private var connectionDrag: PipelineConnectionDrag?
  @SwiftUI.State private var compatibleInputs: Set<PipelinePortReference> = []
  @SwiftUI.State private var nodeMove: PipelineNodeMove?
  @SwiftUI.State private var nodeResize: PipelineNodeResize?
  @SwiftUI.State private var viewportDragOrigin: PipelinePoint?
  @SwiftUI.State private var magnificationStart: Double?
  @SwiftUI.State private var isDropTargeted = false
  @SwiftUI.State private var isPointerOverMultilineEditor = false
  @FocusState private var isGraphFocused: Bool

  private let viewportCoordinateSpace = "pipelineViewport"

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        Color(nsColor: .underPageBackgroundColor)
          .contentShape(Rectangle())
          .onTapGesture {
            isGraphFocused = true
            model.clearSelection()
          }
          .gesture(viewportPanGesture)

        worldLayer(viewportSize: geometry.size)
          .scaleEffect(model.viewportScale, anchor: .topLeading)
          .offset(
            x: -model.viewportOrigin.x * model.viewportScale,
            y: -model.viewportOrigin.y * model.viewportScale)

        PipelineCanvasScrollMonitor(
          shouldCaptureScroll: { !isPointerOverMultilineEditor },
          onScroll: { delta in
            isGraphFocused = true
            model.scrollViewport(
              deltaX: Double(delta.width),
              deltaY: Double(delta.height))
          })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)

        if let connectionDrag,
          let start = outputScreenPoint(connectionDrag.output)
        {
          PipelineConnectionCurve(start: start, end: connectionDrag.location)
            .stroke(
              Color.accentColor,
              style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .allowsHitTesting(false)
        }

        zoomControls
          .padding(10)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

        if isDropTargeted {
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
            .padding(8)
            .allowsHitTesting(false)
        }
      }
      .coordinateSpace(name: viewportCoordinateSpace)
      .clipped()
      .contentShape(Rectangle())
      .focusable()
      .focused($isGraphFocused)
      .dropDestination(for: String.self) { items, location in
        guard let kind = items.compactMap(PipelineNodeDragPayload.decode).first else {
          return false
        }
        isGraphFocused = true
        let point = screenToWorld(location)
        _ = model.addNode(
          kind: kind,
          at: PipelinePoint(x: max(20, point.x), y: max(20, point.y)))
        return true
      } isTargeted: { targeted in
        isDropTargeted = targeted
      }
      .simultaneousGesture(magnificationGesture)
      .onDeleteCommand(perform: model.deleteSelection)
      .onAppear { model.setGraphViewportSize(geometry.size) }
      .onChange(of: geometry.size) { _, size in model.setGraphViewportSize(size) }
    }
  }

  private func worldLayer(viewportSize: CGSize) -> some View {
    let visibleWorld = CGRect(
      x: model.viewportOrigin.x,
      y: model.viewportOrigin.y,
      width: viewportSize.width / CGFloat(model.viewportScale),
      height: viewportSize.height / CGFloat(model.viewportScale))
      .insetBy(dx: -32, dy: -32)
    let visibleNodes = Array(model.document.nodes.enumerated()).filter { _, node in
      let origin = position(for: node.id)
      let size = PipelineGraphMetrics.size(for: node, in: model.document)
      return CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        .intersects(visibleWorld)
    }
    return ZStack(alignment: .topLeading) {
      grid
      ForEach(model.document.connections + model.document.controlConnections) { connection in
        if let start = outputWorldPoint(connection.output),
          let end = inputWorldPoint(connection.input)
        {
          let inactive = isInactive(connection)
          let isControl = model.document.controlConnections.contains { $0.id == connection.id }
          let curve = PipelineConnectionCurve(start: start, end: end)
          curve
            .stroke(
              isSelected(connection)
                ? Color.orange
                : (isControl ? Color.teal : Color.accentColor)
                  .opacity(inactive ? 0.24 : 0.78),
              style: StrokeStyle(
                lineWidth: (isSelected(connection) ? 3 : 2) / model.viewportScale,
                dash: isControl || inactive ? [6, 4] : []))
            .contentShape(curve.stroke(lineWidth: 14 / model.viewportScale))
            .onTapGesture {
              isGraphFocused = true
              model.selectConnection(connection.id)
            }
        }
      }
      ForEach(visibleNodes, id: \.element.id) { index, node in
        let descriptor = PipelineGraphMetrics.descriptor(for: node)
        let size = PipelineGraphMetrics.size(for: node, in: model.document)
        PipelineNodeCard(
          node: node,
          descriptor: descriptor,
          diagnostics: model.validationReport.diagnostics.filter { $0.nodeID == node.id },
          isSelected: model.selection == .node(node.id),
          isActive: settings.highlightNodesOnExecution && model.activeNodeIDs.contains(node.id),
          isGlowing: settings.highlightNodesOnExecution && model.glowingNodeIDs.contains(node.id),
          wasActivated: settings.highlightNodesOnExecution && model.activatedNodeIDs.contains(node.id),
          lastExecutionSeconds: settings.showExecutionSpeedPerNode
            ? model.lastNodeExecutionSeconds[node.id] : nil,
          isEditable: !model.isRunning,
          canEditTrackpad: model.canEditTrackpad,
          trackpadOverlay: model.trackpadMaskPreview,
          canEditLoopAutoPause: model.executionState != .cancelling
            && !(PipelineLoopSettings(node: node)?.feedback == .stateAndImage
              && PipelineLoopSettings(node: node)?.autoPause == true),
          isWaitingToProceed: model.canProceedLoop(node.id),
          canStopLoop: model.canStopLoop(node.id),
          imageFileURL: model.imageFileURL(for: node),
          videoFileURL: model.videoFileURL(for: node),
          videoPreviewURL: model.nodeVideoPreviewURLs[node.id],
          videoOutputURL: node.kind == .videoOutput
            && PipelineGraphOutputs.selectedOutputNode(
              in: model.document, registry: .pipelineEditor)?.id == node.id
            && model.generatedOutputURL?.pathExtension.lowercased() == "mp4"
            ? model.generatedOutputURL : nil,
          openGeneratedOutput: openGeneratedOutput,
          previewImage: model.isGPUProgramTrackpad(node.id)
            ? nil : model.nodeImagePreviews[node.id],
          cacheAssetImages: model.cacheAssetImages[node.id] ?? [:],
          cacheAssetAudioURLs: model.cacheAssetAudioURLs[node.id] ?? [:],
          setAssetSlotCount: { model.setParameter(.integer(Int64($0)),
            named: "slotCount", for: node.id) },
          setKeepAssetsBetweenRuns: { model.setParameter(.boolean($0),
            named: "keepBetweenRuns", for: node.id) },
          clearCachedAssets: { model.clearCachedAssets(for: node.id) },
          livePreview: model.liveMetalPreviewNodeID == node.id
            && model.liveMetalPreviewSize != nil ? model.livePreview : nil,
          previewPixelSize: model.nodeImageDimensions[node.id],
          receivedText: model.nodeTextValues[node.id],
          hasConnectedTextInput: node.kind == .primitiveString
            && model.document.connections.contains(where: {
              $0.input.nodeID == node.id && $0.input.port == "value"
            }),
          showPreviewFullScreen: { showPreviewFullScreen(node.id) },
          cardSize: size,
          inputCompatibility: { port in inputCompatibility(node: node, port: port) },
          chooseImageFile: { chooseImageFile(node.id) },
          chooseVideoFile: { chooseVideoFile(node.id) },
          chooseFilePath: { chooseFilePath(node.id) },
          beginMultilineStringEdit: { model.beginMultilineStringEdit(node.id) },
          setMultilineString: { model.setMultilineString($0, for: node.id) },
          endMultilineStringEdit: { model.endMultilineStringEdit(node.id) },
          multilineEditorHoverChanged: { isPointerOverMultilineEditor = $0 },
          beginPrimitiveValueEdit: { model.beginParameterEdit(named: "value", for: node.id) },
          setPrimitiveValue: { model.setParameter($0, named: "value", for: node.id) },
          endPrimitiveValueEdit: { model.endParameterEdit(named: "value", for: node.id) },
          beginTrackpadEdit: { model.beginTrackpadEdit(for: node.id) },
          setTrackpadPosition: { x, y in
            model.setTrackpadPosition(x: x, y: y, for: node.id)
          },
          endTrackpadEdit: { model.endTrackpadEdit(for: node.id) },
          resetTrackpad: { model.resetTrackpad(for: node.id) },
          canTriggerTrackpadAction: model.canTriggerTrackpadAction(for: node.id),
          triggerTrackpadAction: { model.triggerTrackpadAction(for: node.id) },
          setLoopAutoPause: { model.setLoopAutoPause($0, for: node.id) },
          proceedLoop: { model.proceedLoop(node.id) },
          stopLoop: model.stopLoopAfterCurrentCall,
          moveChanged: { value in moveNode(node, value: value) },
          moveEnded: { _ in endMovingNode(node) },
          resizeChanged: { value in resizeNode(node, value: value) },
          resizeEnded: { _ in endResizingNode(node) },
          outputDragChanged: { port, value in
            updateConnectionDrag(
              output: PipelinePortReference(nodeID: node.id, port: port.name),
              location: value.location)
          },
          outputDragEnded: { port, value in
            finishConnection(
              output: PipelinePortReference(nodeID: node.id, port: port.name),
              location: value.location)
          })
          .frame(width: size.width, height: size.height)
          .position(cardCenter(for: node, fallbackIndex: index))
          .onTapGesture {
            isGraphFocused = true
            model.selectNode(node.id)
          }
      }
    }
    .frame(
      width: worldSize(viewportSize: viewportSize).width,
      height: worldSize(viewportSize: viewportSize).height,
      alignment: .topLeading)
  }

  private func isInactive(_ connection: PipelineConnection) -> Bool {
    let source = model.document.nodes.first { $0.id == connection.output.nodeID }
    let destination = model.document.nodes.first { $0.id == connection.input.nodeID }
    return source?.executionState != .enabled || destination?.executionState != .enabled
  }

  private var grid: some View {
    Canvas { context, size in
      let spacing: CGFloat = 24
      var path = Path()
      stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
      }
      stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
      }
      context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
    }
    .allowsHitTesting(false)
  }

  private var zoomControls: some View {
    HStack(spacing: 4) {
      Button {
        model.setViewportScale(model.viewportScale - 0.1)
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      Text("\(Int((model.viewportScale * 100).rounded()))%")
        .font(.caption.monospacedDigit())
        .frame(width: 48)
      Button {
        model.setViewportScale(model.viewportScale + 0.1)
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      Button(action: model.resetViewport) {
        Image(systemName: "scope")
      }
      .help("Reset canvas view")
      Button(action: model.fitWorkflow) {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
      }
      .disabled(!model.canFitWorkflow)
      .help("Fit workflow in canvas")
      .accessibilityLabel("Fit Workflow")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .padding(5)
    .background(.regularMaterial, in: Capsule())
  }

  private var viewportPanGesture: some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .named(viewportCoordinateSpace))
      .onChanged { value in
        if viewportDragOrigin == nil {
          isGraphFocused = true
          viewportDragOrigin = model.viewportOrigin
          model.beginViewportChange()
        }
        guard let start = viewportDragOrigin else { return }
        model.setViewport(
          origin: PipelinePoint(
            x: start.x - value.translation.width / model.viewportScale,
            y: start.y - value.translation.height / model.viewportScale),
          scale: model.viewportScale)
      }
      .onEnded { _ in
        viewportDragOrigin = nil
        model.endViewportChange()
      }
  }

  private var magnificationGesture: some Gesture {
    MagnificationGesture()
      .onChanged { value in
        if magnificationStart == nil {
          magnificationStart = model.viewportScale
          model.beginViewportChange()
        }
        guard let start = magnificationStart else { return }
        model.setViewport(
          origin: model.viewportOrigin,
          scale: start * Double(value))
      }
      .onEnded { _ in
        magnificationStart = nil
        model.endViewportChange()
      }
  }

  private func moveNode(_ node: PipelineNode, value: DragGesture.Value) {
    if nodeMove?.nodeID != node.id {
      isGraphFocused = true
      nodeMove = PipelineNodeMove(nodeID: node.id, origin: position(for: node.id))
      model.beginNodeMove(node.id)
    }
    guard let move = nodeMove, move.nodeID == node.id else { return }
    model.moveNode(
      node.id,
      to: PipelinePoint(
        x: max(0, move.origin.x + value.translation.width / model.viewportScale),
        y: max(0, move.origin.y + value.translation.height / model.viewportScale)))
  }

  private func endMovingNode(_ node: PipelineNode) {
    guard nodeMove?.nodeID == node.id else { return }
    nodeMove = nil
    model.endNodeMove(node.id)
  }

  private func resizeNode(_ node: PipelineNode, value: DragGesture.Value) {
    if nodeResize?.nodeID != node.id {
      isGraphFocused = true
      nodeResize = PipelineNodeResize(
        nodeID: node.id,
        size: PipelineGraphMetrics.size(for: node, in: model.document))
      model.beginNodeResize(node.id)
    }
    guard let resize = nodeResize, resize.nodeID == node.id else { return }
    let minimum = PipelineGraphMetrics.minimumResizableSize(for: node)
    model.resizeNode(node.id, to: PipelineSize(
      width: Double(min(max(resize.size.width + value.translation.width / model.viewportScale,
        minimum.width), PipelineGraphMetrics.resizableMaxWidth)),
      height: Double(min(max(resize.size.height + value.translation.height / model.viewportScale,
        minimum.height), PipelineGraphMetrics.resizableMaxHeight))))
  }

  private func endResizingNode(_ node: PipelineNode) {
    guard nodeResize?.nodeID == node.id else { return }
    nodeResize = nil
    model.endNodeResize(node.id)
  }

  private func finishConnection(output: PipelinePortReference, location: CGPoint) {
    defer {
      connectionDrag = nil
      compatibleInputs = []
    }
    guard let input = closestInput(to: location) else { return }
    _ = model.addConnection(output: output, input: input)
  }

  private func closestInput(to screenPoint: CGPoint) -> PipelinePortReference? {
    var closest: (distance: CGFloat, reference: PipelinePortReference)?
    for node in model.document.nodes {
      guard let descriptor = PipelineGraphMetrics.descriptor(for: node) else { continue }
      for port in descriptor.inputs {
        let reference = PipelinePortReference(nodeID: node.id, port: port.name)
        guard let point = inputScreenPoint(reference) else { continue }
        let distance = hypot(point.x - screenPoint.x, point.y - screenPoint.y)
        if distance <= 18, closest == nil || distance < closest!.distance {
          closest = (distance, reference)
        }
      }
    }
    return closest?.reference
  }

  private func inputCompatibility(
    node: PipelineNode,
    port: PipelinePortDescriptor
  ) -> Bool? {
    guard connectionDrag != nil else { return nil }
    return compatibleInputs.contains(PipelinePortReference(nodeID: node.id, port: port.name))
  }

  private func updateConnectionDrag(output: PipelinePortReference, location: CGPoint) {
    if connectionDrag?.output != output {
      isGraphFocused = true
      compatibleInputs = Set(model.document.nodes.flatMap { node -> [PipelinePortReference] in
        guard let descriptor = PipelineGraphMetrics.descriptor(for: node) else { return [] }
        return descriptor.inputs.compactMap { port in
          let input = PipelinePortReference(nodeID: node.id, port: port.name)
          return model.connectionDecision(output: output, input: input).isAllowed ? input : nil
        }
      })
    }
    connectionDrag = PipelineConnectionDrag(output: output, location: location)
  }

  private func isSelected(_ connection: PipelineConnection) -> Bool {
    model.selection == .connection(connection.id)
  }

  private func position(for nodeID: PipelineNodeID) -> PipelinePoint {
    if let stored = model.document.presentation?.nodePositions[nodeID.rawValue] {
      return stored
    }
    let index = model.document.nodes.firstIndex(where: { $0.id == nodeID }) ?? 0
    return PipelinePoint(
      x: 100 + Double(index % 4) * 270,
      y: 100 + Double(index / 4) * 180)
  }

  private func cardCenter(for node: PipelineNode, fallbackIndex: Int) -> CGPoint {
    let origin = model.document.presentation?.nodePositions[node.id.rawValue]
      ?? PipelinePoint(
        x: 100 + Double(fallbackIndex % 4) * 270,
        y: 100 + Double(fallbackIndex / 4) * 180)
    let size = PipelineGraphMetrics.size(for: node, in: model.document)
    return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
  }

  private func outputWorldPoint(_ reference: PipelinePortReference) -> CGPoint? {
    guard let node = model.document.nodes.first(where: { $0.id == reference.nodeID }),
      let descriptor = PipelineGraphMetrics.descriptor(for: node),
      let index = descriptor.outputs.firstIndex(where: { $0.name == reference.port })
    else { return nil }
    let origin = position(for: node.id)
    let size = PipelineGraphMetrics.size(for: node, in: model.document)
    return CGPoint(
      x: origin.x + size.width,
      y: origin.y + PipelineGraphMetrics.portY(for: node, index: index, in: size))
  }

  private func inputWorldPoint(_ reference: PipelinePortReference) -> CGPoint? {
    guard let node = model.document.nodes.first(where: { $0.id == reference.nodeID }),
      let descriptor = PipelineGraphMetrics.descriptor(for: node),
      let index = descriptor.inputs.firstIndex(where: { $0.name == reference.port })
    else { return nil }
    let origin = position(for: node.id)
    let size = PipelineGraphMetrics.size(for: node, in: model.document)
    return CGPoint(
      x: origin.x,
      y: origin.y + PipelineGraphMetrics.portY(for: node, index: index, in: size))
  }

  private func outputScreenPoint(_ reference: PipelinePortReference) -> CGPoint? {
    outputWorldPoint(reference).map(worldToScreen)
  }

  private func inputScreenPoint(_ reference: PipelinePortReference) -> CGPoint? {
    inputWorldPoint(reference).map(worldToScreen)
  }

  private func worldToScreen(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: (point.x - model.viewportOrigin.x) * model.viewportScale,
      y: (point.y - model.viewportOrigin.y) * model.viewportScale)
  }

  private func screenToWorld(_ point: CGPoint) -> PipelinePoint {
    PipelinePoint(
      x: model.viewportOrigin.x + point.x / model.viewportScale,
      y: model.viewportOrigin.y + point.y / model.viewportScale)
  }

  private func worldSize(viewportSize: CGSize) -> CGSize {
    let nodeBounds = model.document.nodes.enumerated().map { index, node -> CGPoint in
      let origin = model.document.presentation?.nodePositions[node.id.rawValue]
        ?? PipelinePoint(
          x: 100 + Double(index % 4) * 270,
          y: 100 + Double(index / 4) * 180)
      let size = PipelineGraphMetrics.size(for: node, in: model.document)
      return CGPoint(x: origin.x + size.width, y: origin.y + size.height)
    }
    return CGSize(
      width: max(
        4_000,
        (nodeBounds.map(\.x).max() ?? 0) + 800,
        model.viewportOrigin.x + viewportSize.width / model.viewportScale + 800),
      height: max(
        3_000,
        (nodeBounds.map(\.y).max() ?? 0) + 800,
        model.viewportOrigin.y + viewportSize.height / model.viewportScale + 800))
  }
}

private struct PipelineCanvasScrollMonitor: NSViewRepresentable {
  let shouldCaptureScroll: () -> Bool
  let onScroll: (CGSize) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(shouldCaptureScroll: shouldCaptureScroll, onScroll: onScroll)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(for: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.shouldCaptureScroll = shouldCaptureScroll
    context.coordinator.onScroll = onScroll
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator {
    var shouldCaptureScroll: () -> Bool
    var onScroll: (CGSize) -> Void

    private weak var view: NSView?
    private var eventMonitor: Any?

    init(shouldCaptureScroll: @escaping () -> Bool, onScroll: @escaping (CGSize) -> Void) {
      self.shouldCaptureScroll = shouldCaptureScroll
      self.onScroll = onScroll
    }

    func install(for view: NSView) {
      self.view = view
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        self?.handle(event) ?? event
      }
    }

    func uninstall() {
      if let eventMonitor {
        NSEvent.removeMonitor(eventMonitor)
      }
      eventMonitor = nil
      view = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard let view,
        let window = view.window,
        event.window === window
      else { return event }

      let location = view.convert(event.locationInWindow, from: nil)
      guard view.bounds.contains(location), shouldCaptureScroll(),
        !isInsideNestedScrollView(event, window: window)
      else { return event }

      let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
      guard delta != .zero else { return event }
      onScroll(delta)
      return nil
    }

    private func isInsideNestedScrollView(_ event: NSEvent, window: NSWindow) -> Bool {
      guard let contentView = window.contentView else { return false }
      let location = contentView.convert(event.locationInWindow, from: nil)
      var hitView = contentView.hitTest(location)
      while let current = hitView {
        if current is NSScrollView { return true }
        if current === contentView { break }
        hitView = current.superview
      }
      return false
    }

    isolated deinit {
      if let eventMonitor {
        NSEvent.removeMonitor(eventMonitor)
      }
    }
  }
}

private struct PipelineNodeCard: View {
  let node: PipelineNode
  let descriptor: PipelineNodeDescriptor?
  let diagnostics: [PipelineDiagnostic]
  let isSelected: Bool
  let isActive: Bool
  let isGlowing: Bool
  let wasActivated: Bool
  let lastExecutionSeconds: TimeInterval?
  let isEditable: Bool
  let canEditTrackpad: Bool
  let trackpadOverlay: NSImage?
  let canEditLoopAutoPause: Bool
  let isWaitingToProceed: Bool
  let canStopLoop: Bool
  let imageFileURL: URL?
  let videoFileURL: URL?
  let videoPreviewURL: URL?
  let videoOutputURL: URL?
  let openGeneratedOutput: (URL) -> Void
  let previewImage: NSImage?
  let cacheAssetImages: [String: NSImage]
  let cacheAssetAudioURLs: [String: URL]
  let setAssetSlotCount: @MainActor @Sendable (Int) -> Void
  let setKeepAssetsBetweenRuns: @MainActor @Sendable (Bool) -> Void
  let clearCachedAssets: () -> Void
  let livePreview: PipelineLivePreviewPresenter?
  let previewPixelSize: CGSize?
  let receivedText: String?
  let hasConnectedTextInput: Bool
  let showPreviewFullScreen: () -> Void
  let cardSize: CGSize
  let inputCompatibility: (PipelinePortDescriptor) -> Bool?
  let chooseImageFile: () -> Void
  let chooseVideoFile: () -> Void
  let chooseFilePath: () -> Void
  let beginMultilineStringEdit: () -> Void
  let setMultilineString: @MainActor @Sendable (String) -> Void
  let endMultilineStringEdit: () -> Void
  let multilineEditorHoverChanged: (Bool) -> Void
  let beginPrimitiveValueEdit: () -> Void
  let setPrimitiveValue: (PipelineValue) -> Void
  let endPrimitiveValueEdit: () -> Void
  let beginTrackpadEdit: () -> Void
  let setTrackpadPosition: (Double, Double) -> Void
  let endTrackpadEdit: () -> Void
  let resetTrackpad: () -> Void
  let canTriggerTrackpadAction: Bool
  let triggerTrackpadAction: () -> Void
  let setLoopAutoPause: @MainActor @Sendable (Bool) -> Void
  let proceedLoop: () -> Void
  let stopLoop: () -> Void
  let moveChanged: (DragGesture.Value) -> Void
  let moveEnded: (DragGesture.Value) -> Void
  let resizeChanged: (DragGesture.Value) -> Void
  let resizeEnded: (DragGesture.Value) -> Void
  let outputDragChanged: (PipelinePortDescriptor, DragGesture.Value) -> Void
  let outputDragEnded: (PipelinePortDescriptor, DragGesture.Value) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      header
      specialContent
      portRows
      if node.kind == .imagePreview || node.kind == .renderMetal
        || node.kind == .gpuProgram {
        imagePreviewContent
      } else if node.kind == .videoPreview {
        videoPreviewContent
      } else if node.kind != .markdownNote {
        Spacer(minLength: PipelineGraphMetrics.bottomPadding(for: node))
      }
    }
    .background {
      RoundedRectangle(cornerRadius: 10)
        .fill(.regularMaterial)
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .fill(executionColor.opacity(executionTintOpacity))
        }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
          lineWidth: isSelected ? 2 : 1)
        .allowsHitTesting(false)
    }
    .overlay {
      if executionBorderOpacity > 0 {
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            executionColor.opacity(executionBorderOpacity),
            lineWidth: executionBorderWidth)
          .shadow(
            color: executionColor.opacity(executionGlowOpacity),
            radius: executionGlowRadius)
          .allowsHitTesting(false)
      }
    }
    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    .overlay(alignment: .bottomTrailing) {
      if node.kind == .imagePreview || node.kind == .videoPreview
        || node.kind == .renderMetal || node.kind == .gpuProgram
        || node.kind == .assetCache
        || node.kind == .markdownNote || node.kind == .trackpad
        || node.kind == .primitiveString {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("pipelineViewport"))
              .onChanged(resizeChanged)
              .onEnded(resizeEnded))
          .help(resizeLabel)
          .accessibilityLabel(resizeLabel)
      }
    }
    .opacity(node.executionState == .enabled ? 1 : 0.52)
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.9),
      value: isActive)
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.9),
      value: isGlowing)
    .accessibilityValue(executionAccessibilityValue)
  }

  private var executionColor: Color { .cyan }

  private var resizeLabel: String {
    switch node.kind {
    case .markdownNote: "Resize Markdown note"
    case .primitiveString: "Resize text editor"
    case .trackpad: "Resize Trackpad"
    case .renderMetal: "Resize Metal render preview"
    case .gpuProgram: "Resize GPU program preview"
    default: "Resize image preview"
    }
  }

  private var executionTintOpacity: Double {
    if isActive { return 0.18 }
    if isGlowing { return 0.09 }
    if wasActivated { return 0.035 }
    return 0
  }

  private var executionBorderOpacity: Double {
    if isActive { return 1 }
    if isGlowing { return 0.72 }
    if wasActivated { return 0.28 }
    return 0
  }

  private var executionBorderWidth: CGFloat {
    if isActive { return 3 }
    if isGlowing { return 2 }
    return 1.25
  }

  private var executionGlowOpacity: Double {
    if isActive { return 0.65 }
    if isGlowing { return 0.32 }
    return 0
  }

  private var executionGlowRadius: CGFloat {
    if isActive { return 12 }
    if isGlowing { return 7 }
    return 0
  }

  private var executionAccessibilityValue: Text {
    if isActive { return Text("Running") }
    if isGlowing { return Text("Recently active") }
    if wasActivated { return Text("Activated during this run") }
    return Text("")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(node.title ?? descriptor?.displayName ?? node.kind.rawValue)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        if let lastExecutionSeconds {
          Text("(\(Self.executionTimeLabel(lastExecutionSeconds)))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Last execution \(Self.executionTimeLabel(lastExecutionSeconds))")
        }
        Spacer(minLength: 4)
        if node.executionState != .enabled {
          Text(node.executionState.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        if diagnostics.contains(where: { $0.severity == .error }) {
          Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else if !diagnostics.isEmpty {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
      Text(node.kind.rawValue)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .frame(height: PipelineGraphMetrics.headerHeight)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 2, coordinateSpace: .named("pipelineViewport"))
        .onChanged(moveChanged)
        .onEnded(moveEnded))
  }

  private static func executionTimeLabel(_ seconds: TimeInterval) -> String {
    if seconds < 0.001 { return "<1ms" }
    if seconds < 0.9995 { return "\(Int((seconds * 1_000).rounded()))ms" }
    if seconds < 10 {
      return "\(seconds.formatted(.number.precision(.fractionLength(1))))s"
    }
    return "\(Int(seconds.rounded()))s"
  }

  private var assetSlotCount: Int {
    if case .integer(let count)? = node.parameters["slotCount"] {
      return Int(min(max(count, 1), 16))
    }
    return 1
  }

  private var keepAssetsBetweenRuns: Bool {
    node.parameters["keepBetweenRuns"] == .boolean(true)
  }

  @ViewBuilder
  private var specialContent: some View {
    if node.kind == .assetCache {
      VStack(alignment: .leading, spacing: 4) {
        Stepper("Slots: \(assetSlotCount)", value: Binding(
          get: { assetSlotCount }, set: setAssetSlotCount), in: 1...16)
          .font(.caption)
          .disabled(!isEditable)
        HStack {
          Toggle("Keep between runs", isOn: Binding(
            get: { keepAssetsBetweenRuns }, set: setKeepAssetsBetweenRuns))
            .font(.caption)
            .disabled(!isEditable)
          Spacer(minLength: 4)
          Button("Clear", action: clearCachedAssets)
            .controlSize(.small)
            .disabled(!isEditable)
            .help("Clear cached assets and regenerate them on the next run")
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<assetSlotCount, id: \.self) { index in
              let slot = "asset\(index)"
              HStack(spacing: 8) {
                if let image = cacheAssetImages[slot] {
                  Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 48)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                } else if let url = cacheAssetAudioURLs[slot] {
                  Button { openGeneratedOutput(url) } label: {
                    Label("Play", systemImage: "waveform")
                  }
                  .buttonStyle(.bordered)
                  .controlSize(.small)
                } else {
                  Image(systemName: "square.dashed")
                    .frame(width: 64, height: 48)
                    .foregroundStyle(.secondary)
                }
                Text(slot).font(.caption.monospaced())
                Spacer(minLength: 0)
              }
            }
          }
          .padding(8)
        }
      }
      .padding(.horizontal, 8)
      .frame(height: PipelineGraphMetrics.contentHeight(for: node, in: cardSize))
    } else if node.kind == .markdownNote {
      PipelineMarkdownView(markdown: markdownText)
        .padding(.horizontal, 9)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Markdown note")
    } else if node.kind == .imageInput {
      VStack(spacing: 6) {
        if imageSourceName != nil {
          PipelineImageThumbnailView(url: imageFileURL)
            .frame(height: 94)
        }
        Text(imageSourceName ?? "No image selected")
          .font(.caption)
          .foregroundStyle(imageSourceName == nil ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(imageFileURL?.path ?? imageSourceName ?? "No image selected")
        Button(action: chooseImageFile) {
          Label(imageSourceName == nil ? "Choose Image…" : "Replace Image…", systemImage: "photo")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .padding(.horizontal, 10)
      .frame(height: PipelineGraphMetrics.contentHeight(for: node))
    } else if node.kind == .videoInput {
      VStack(spacing: 6) {
        Text(videoSourceName ?? "No video selected")
          .font(.caption)
          .foregroundStyle(videoSourceName == nil ? .secondary : .primary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(videoFileURL?.path ?? videoSourceName ?? "No video selected")
        Button(action: chooseVideoFile) {
          Label(videoSourceName == nil ? "Choose Video…" : "Replace Video…",
            systemImage: "film")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .padding(.horizontal, 10)
      .frame(height: PipelineGraphMetrics.contentHeight(for: node))
    } else if node.kind == .primitiveFilePath {
      VStack(alignment: .leading, spacing: 6) {
        Text(filePathMode == "absolute"
          ? "Absolute path" : "Relative to source folder")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(filePathText)
          .font(.caption.monospaced())
          .lineLimit(2)
          .truncationMode(.middle)
          .help(filePathText)
        Button(action: chooseFilePath) {
          Label("Choose File…", systemImage: "doc")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isEditable)
      }
      .padding(.horizontal, 10)
      .frame(height: PipelineGraphMetrics.contentHeight(for: node))
    } else if node.kind == .primitiveString || node.kind == .stateInput {
      VStack(alignment: .leading, spacing: 2) {
        if hasConnectedTextInput {
          Text(receivedText == nil ? "Run to show connected text" : "Last received text")
            .font(.caption2)
            .foregroundStyle(.secondary)
          PipelineReceivedTextView(text: receivedText ?? "")
            .padding(5)
            .background(Color(nsColor: .textBackgroundColor),
              in: RoundedRectangle(cornerRadius: 5))
            .overlay {
              RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            }
        } else {
          PipelineMultilineStringEditor(
            text: multilineString,
            isEditable: isEditable,
            beginEditing: beginMultilineStringEdit,
            setText: setMultilineString,
            endEditing: endMultilineStringEdit)
            .disabled(!isEditable)
        }
      }
      .padding(.horizontal, 9)
      .frame(height: PipelineGraphMetrics.contentHeight(for: node, in: cardSize))
      .onHover(perform: multilineEditorHoverChanged)
      .onDisappear { multilineEditorHoverChanged(false) }
    } else if node.kind == .primitiveInt || node.kind == .primitiveFloat
      || node.kind == .primitiveBoolean {
      if let parameter = descriptor?.parameter(named: "value") {
        PipelineParameterField(
          name: "Value",
          value: node.parameters["value"] ?? parameter.defaultValue,
          valueType: parameter.valueType,
          isEnabled: isEditable,
          beginEditing: beginPrimitiveValueEdit,
          setValue: setPrimitiveValue,
          endEditing: endPrimitiveValueEdit)
          .padding(.horizontal, 10)
          .frame(height: PipelineGraphMetrics.contentHeight(for: node))
      }
    } else if node.kind == .videoOutput {
      VStack(alignment: .leading, spacing: 4) {
        Text("Output file")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(videoOutputURL?.lastPathComponent ?? "No video saved yet")
          .font(.caption.monospaced())
          .foregroundStyle(videoOutputURL == nil ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          if let videoOutputURL { openGeneratedOutput(videoOutputURL) }
        } label: {
          Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(videoOutputURL == nil)
        .help(videoOutputURL == nil ? "Run the pipeline to save a video"
          : "Open the saved video in QuickTime Player")
      }
      .padding(.horizontal, 10)
      .frame(height: PipelineGraphMetrics.contentHeight(for: node), alignment: .topLeading)
    } else if node.kind == .trackpad {
      let contentHeight = PipelineGraphMetrics.contentHeight(for: node, in: cardSize)
      let livePixelSize = livePreview == nil ? nil : previewPixelSize
      let padAspect = livePixelSize.map { $0.width / max($0.height, 1) }
        ?? previewImage.map { $0.size.width / max($0.size.height, 1) }
        ?? PipelineGraphMetrics.trackpadAspectRatio
      let padWidth = min(cardSize.width - 20, (contentHeight - 84) * padAspect)
      VStack(spacing: 10) {
        PipelineTrackpadView(
          image: previewImage,
          livePreview: livePreview,
          overlay: trackpadOverlay,
          x: trackpadCoordinate("x"),
          y: trackpadCoordinate("y"),
          showsControls: true,
          isEnabled: canEditTrackpad,
          beginEditing: beginTrackpadEdit,
          setPosition: setTrackpadPosition,
          endEditing: endTrackpadEdit)
          .frame(width: padWidth,
            height: padWidth / padAspect)
        HStack(spacing: 8) {
          Button(action: resetTrackpad) {
            Text("Reset").frame(maxWidth: .infinity)
          }
          .disabled(!canEditTrackpad ||
            (trackpadCoordinate("x") == 0.5 && trackpadCoordinate("y") == 0.5))
          .accessibilityLabel("Reset trackpad position")
          .help("Center the trackpad")
          Button("Action", action: triggerTrackpadAction)
            .frame(maxWidth: .infinity)
            .disabled(!canTriggerTrackpadAction)
            .keyboardShortcut(.space, modifiers: [])
            .help("Press Space or click to trigger the connected action")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(width: padWidth, height: 24)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(10)
      .frame(height: contentHeight)
    } else if node.kind == .controlLoop {
      VStack(alignment: .leading, spacing: 6) {
        Toggle("Auto pause", isOn: Binding(
          get: { PipelineLoopSettings(node: node)?.autoPause ?? false },
          set: setLoopAutoPause))
          .disabled(!canEditLoopAutoPause)
        HStack(spacing: 6) {
          Button("Proceed", action: proceedLoop)
            .buttonStyle(.borderedProminent)
            .disabled(!isWaitingToProceed)
          Button("Stop Loop", action: stopLoop)
            .buttonStyle(.bordered)
            .disabled(!canStopLoop)
            .help("Finish the current call and save the video if recording")
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .frame(height: PipelineGraphMetrics.contentHeight(for: node))
    }
  }

  private var portRows: some View {
    let inputs = descriptor?.inputs ?? []
    let outputs = descriptor?.outputs ?? []
    let count = max(inputs.count, outputs.count)
    return VStack(spacing: 0) {
      ForEach(0..<count, id: \.self) { index in
        HStack(spacing: 5) {
          if inputs.indices.contains(index) {
            let input = inputs[index]
            PipelinePortDot(
              type: input.type,
              isCompatibleTarget: inputCompatibility(input))
              .offset(x: -5)
              .help("\(input.name): \(input.type.rawValue)")
            Text(input.name + (input.isRequired ? " *" : ""))
              .lineLimit(1)
          } else {
            Color.clear.frame(width: 5)
          }
          Spacer(minLength: 4)
          if outputs.indices.contains(index) {
            let output = outputs[index]
            Text(output.name)
              .lineLimit(1)
            PipelinePortDot(type: output.type, isCompatibleTarget: nil)
              .offset(x: 5)
              .help("\(output.name): \(output.type.rawValue)")
              .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("pipelineViewport"))
                  .onChanged { outputDragChanged(output, $0) }
                  .onEnded { outputDragEnded(output, $0) })
          } else {
            Color.clear.frame(width: 5)
          }
        }
        .font(.caption2)
        .padding(.horizontal, 0)
        .frame(height: PipelineGraphMetrics.portRowHeight)
      }
    }
  }

  private var imagePreviewContent: some View {
    GeometryReader { geometry in
      Group {
        if let livePreview {
          PipelineMetalPreviewSurfaceView(presenter: livePreview)
            .frame(width: geometry.size.width, height: geometry.size.height)
        } else if let previewImage {
          Image(nsImage: previewImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .accessibilityLabel("Image preview")
        } else {
          ContentUnavailableView("No preview yet", systemImage: "photo")
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(alignment: .topTrailing) {
      if livePreview != nil || previewImage != nil {
        Button(action: showPreviewFullScreen) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .padding(7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Show preview full screen")
        .accessibilityLabel("Show preview full screen")
        .padding(15)
      }
    }
    .overlay(alignment: .bottomLeading) {
      if node.kind == .renderMetal || node.kind == .gpuProgram,
        livePreview != nil || previewImage != nil,
        let previewPixelSize {
        Text("\(Int(previewPixelSize.width)) × \(Int(previewPixelSize.height))")
          .font(.caption2.monospacedDigit())
          .padding(6)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
          .help("Rendered pixel dimensions")
          .padding(15)
      }
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 12)
  }

  private var videoPreviewContent: some View {
    Group {
      if let videoPreviewURL {
        PipelineVideoPlayerView(url: videoPreviewURL)
      } else if let previewImage {
        Image(nsImage: previewImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        ContentUnavailableView("No video yet", systemImage: "film")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .padding(.horizontal, 8)
    .padding(.bottom, 12)
  }

  private var markdownText: String {
    guard case .string(let text) = node.parameters["text"] else { return "" }
    return text
  }

  private var multilineString: String {
    let key = node.kind == .stateInput ? "initialState" : "value"
    guard case .string(let text) = node.parameters[key] else { return "" }
    return text
  }

  private var filePathText: String {
    if case .string(let path)? = node.parameters["path"], !path.isEmpty { return path }
    return "No file selected"
  }

  private var filePathMode: String {
    if case .string(let mode)? = node.parameters["mode"] { return mode }
    return "relative"
  }

  private func trackpadCoordinate(_ name: String) -> Double {
    let value: Double
    switch node.parameters[name] {
    case .number(let number): value = number
    case .integer(let integer): value = Double(integer)
    default: value = 0.5
    }
    return value.isFinite ? min(max(value, 0), 1) : 0.5
  }

  private var imageSourceName: String? {
    if let imageFileURL { return imageFileURL.lastPathComponent }
    guard case .string(let sourceName) = node.parameters["sourceName"], !sourceName.isEmpty else {
      return nil
    }
    return sourceName
  }

  private var videoSourceName: String? {
    if let videoFileURL { return videoFileURL.lastPathComponent }
    guard case .string(let sourceName) = node.parameters["sourceName"],
      !sourceName.isEmpty else { return nil }
    return sourceName
  }
}

private struct PipelineVideoPlayerView: View {
  let url: URL
  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
      } else {
        ContentUnavailableView("Loading video…", systemImage: "film")
      }
    }
    .task(id: url) {
      player?.pause()
      player = AVPlayer(url: url)
    }
    .onDisappear { player?.pause() }
  }
}

struct PipelineTrackpadView: View {
  let image: NSImage?
  let livePreview: PipelineLivePreviewPresenter?
  let overlay: NSImage?
  let x: Double
  let y: Double
  let showsControls: Bool
  let isEnabled: Bool
  let beginEditing: () -> Void
  let setPosition: (Double, Double) -> Void
  let endEditing: () -> Void

  @SwiftUI.State private var isDragging = false

  var body: some View {
    GeometryReader { geometry in
      let point = CGPoint(
        x: geometry.size.width * x,
        y: geometry.size.height * y)
      ZStack {
        if showsControls {
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.07))
        }
        if let livePreview {
          PipelineMetalPreviewSurfaceView(presenter: livePreview)
            .allowsHitTesting(false)
        } else if let image {
          Image(nsImage: image).resizable().allowsHitTesting(false)
        }
        if let overlay {
          Image(nsImage: overlay).resizable().allowsHitTesting(false)
        }
        if showsControls {
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1)
          Path { path in
            path.move(to: CGPoint(x: point.x, y: 0))
            path.addLine(to: CGPoint(x: point.x, y: geometry.size.height))
            path.move(to: CGPoint(x: 0, y: point.y))
            path.addLine(to: CGPoint(x: geometry.size.width, y: point.y))
          }
          .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
          .allowsHitTesting(false)
          Circle()
            .fill(Color.accentColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.background, lineWidth: 2))
            .position(point)
            .allowsHitTesting(false)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: showsControls ? 8 : 0))
      .contentShape(RoundedRectangle(cornerRadius: showsControls ? 8 : 0))
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard isEnabled else { return }
            if !isDragging {
              isDragging = true
              beginEditing()
            }
            updatePosition(value.location, in: geometry.size)
          }
          .onEnded { value in
            guard isDragging else { return }
            updatePosition(value.location, in: geometry.size)
            isDragging = false
            endEditing()
          })
      .accessibilityLabel("Trackpad position")
      .accessibilityValue("X \(x.formatted(.number.precision(.fractionLength(2)))), Y \(y.formatted(.number.precision(.fractionLength(2))))")
    }
  }

  private func updatePosition(_ point: CGPoint, in size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    setPosition(
      min(max(Double(point.x / size.width), 0), 1),
      min(max(Double(point.y / size.height), 0), 1))
  }
}

private struct PipelineImageThumbnailView: View {
  let url: URL?
  @SwiftUI.State private var thumbnail: NSImage?
  @SwiftUI.State private var hasLoaded = false

  var body: some View {
    Group {
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .scaledToFit()
          .accessibilityLabel("Source image preview")
      } else {
        Text(url == nil || hasLoaded ? "Preview unavailable" : "Loading preview…")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .task(id: url) {
      thumbnail = nil
      hasLoaded = false
      guard let url else { return }
      let result = await Task.detached(priority: .utility) {
        PipelineImageThumbnail.load(at: url)
      }.value
      guard !Task.isCancelled else { return }
      if let result {
        thumbnail = NSImage(cgImage: result.image, size: .zero)
      }
      hasLoaded = true
    }
  }
}

private struct PipelineImageThumbnail: @unchecked Sendable {
  let image: CGImage

  static func load(at url: URL) -> Self? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
      return nil
    }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 256,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0, thumbnailOptions as CFDictionary)
    else { return nil }
    return Self(image: image)
  }
}

private struct PipelineParameterField: View {
  let name: String
  let value: PipelineValue?
  let valueType: PipelineParameterValueType
  let isEnabled: Bool
  let beginEditing: () -> Void
  let setValue: (PipelineValue) -> Void
  let endEditing: () -> Void

  private var scalarType: PipelineParameterValueType {
    guard valueType == .any else { return valueType }
    switch value {
    case .string: return .string
    case .boolean: return .boolean
    case .integer: return .integer
    case .number: return .number
    default: return .any
    }
  }

  @ViewBuilder var body: some View {
    switch scalarType {
    case .string:
      VStack(alignment: .leading, spacing: 4) {
        Text(name).font(.caption.weight(.medium))
        PipelineParameterTextField(
          value: value, valueType: .string, isEnabled: isEnabled,
          beginEditing: beginEditing, setValue: setValue, endEditing: endEditing)
      }
    case .integer, .number:
      LabeledContent(name) {
        PipelineParameterTextField(
          value: value, valueType: scalarType, isEnabled: isEnabled,
          beginEditing: beginEditing, setValue: setValue, endEditing: endEditing)
          .frame(width: 120)
      }
    case .boolean:
      Toggle(name, isOn: Binding(
        get: {
          guard case .boolean(let enabled)? = value else { return false }
          return enabled
        },
        set: { setValue(.boolean($0)) }))
        .disabled(!isEnabled)
    default:
      LabeledContent(name, value: value?.displayValue ?? "Not set")
    }
  }
}

private struct PipelineParameterTextField: View {
  let value: PipelineValue?
  let valueType: PipelineParameterValueType
  let isEnabled: Bool
  let beginEditing: () -> Void
  let setValue: (PipelineValue) -> Void
  let endEditing: () -> Void

  @State private var draft: String
  @FocusState private var isFocused: Bool

  init(
    value: PipelineValue?,
    valueType: PipelineParameterValueType,
    isEnabled: Bool,
    beginEditing: @escaping () -> Void,
    setValue: @escaping (PipelineValue) -> Void,
    endEditing: @escaping () -> Void
  ) {
    self.value = value
    self.valueType = valueType
    self.isEnabled = isEnabled
    self.beginEditing = beginEditing
    self.setValue = setValue
    self.endEditing = endEditing
    _draft = State(initialValue: Self.text(for: value))
  }

  var body: some View {
    Group {
      if valueType == .string {
        TextField("Value", text: $draft, axis: .vertical)
          .lineLimit(1...5)
      } else {
        TextField("Value", text: $draft)
          .multilineTextAlignment(.trailing)
      }
    }
    .textFieldStyle(.roundedBorder)
    .focused($isFocused)
    .disabled(!isEnabled)
    .onChange(of: draft) { _, text in
      guard isFocused else { return }
      beginEditing()
      if let parsed = parsedValue(text) { setValue(parsed) }
    }
    .onChange(of: value) { _, updated in
      guard !isFocused else { return }
      draft = Self.text(for: updated)
    }
    .onChange(of: isFocused) { _, focused in
      if focused {
        beginEditing()
      } else {
        finishEditing()
      }
    }
    .onSubmit { isFocused = false }
    .onDisappear(perform: endEditing)
  }

  private func finishEditing() {
    if let parsed = parsedValue(draft) {
      setValue(parsed)
    } else {
      draft = Self.text(for: value)
    }
    endEditing()
  }

  private func parsedValue(_ text: String) -> PipelineValue? {
    switch valueType {
    case .string:
      return .string(text)
    case .integer:
      guard let number = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
      }
      return .integer(number)
    case .number:
      guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        number.isFinite else { return nil }
      return .number(number)
    default:
      return nil
    }
  }

  private static func text(for value: PipelineValue?) -> String {
    switch value {
    case .string(let text): text
    case .integer(let number): String(number)
    case .number(let number): String(number)
    default: ""
    }
  }
}

private struct PipelineMultilineStringEditor: View {
  let text: String
  let isEditable: Bool
  let beginEditing: () -> Void
  let setText: @MainActor @Sendable (String) -> Void
  let endEditing: () -> Void

  @State private var draft: String
  @FocusState private var isFocused: Bool

  init(
    text: String,
    isEditable: Bool,
    beginEditing: @escaping () -> Void,
    setText: @escaping @MainActor @Sendable (String) -> Void,
    endEditing: @escaping () -> Void
  ) {
    self.text = text
    self.isEditable = isEditable
    self.beginEditing = beginEditing
    self.setText = setText
    self.endEditing = endEditing
    _draft = State(initialValue: text)
  }

  var body: some View {
    TextEditor(text: $draft)
      .font(.caption)
      .scrollContentBackground(.hidden)
      .padding(5)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1)
      }
      .focused($isFocused)
      .onChange(of: draft) { _, value in
        if isEditable && isFocused { setText(value) }
      }
      .onChange(of: text) { _, value in
        guard !isFocused, value != draft else { return }
        draft = value
      }
      .onChange(of: isFocused) { _, focused in
        if focused {
          beginEditing()
        } else {
          endEditing()
        }
      }
      .onDisappear(perform: endEditing)
      .accessibilityLabel("Multiline text value")
  }
}

private struct PipelineReceivedTextView: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = false
    scrollView.scrollerStyle = .legacy
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor

    let contentSize = scrollView.contentSize
    let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    textView.textColor = .labelColor
    textView.backgroundColor = .textBackgroundColor
    textView.textContainerInset = NSSize(width: 5, height: 5)
    textView.minSize = NSSize(width: 0, height: contentSize.height)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(width: contentSize.width,
      height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView,
      textView.string != text else { return }
    textView.string = text
    textView.sizeToFit()
  }
}

private struct PipelinePortDot: View {
  let type: PipelinePortType
  let isCompatibleTarget: Bool?

  var body: some View {
    Circle()
      .fill(fillColor)
      .frame(width: 10, height: 10)
      .overlay(Circle().stroke(Color.primary.opacity(0.55), lineWidth: 1))
      .shadow(color: highlightColor.opacity(0.8), radius: isCompatibleTarget == true ? 4 : 0)
  }

  private var fillColor: Color {
    if isCompatibleTarget == true { return .green }
    if isCompatibleTarget == false { return portColor.opacity(0.22) }
    return portColor
  }

  private var highlightColor: Color {
    isCompatibleTarget == true ? .green : .clear
  }

  private var portColor: Color {
    switch type {
    case .control: .teal
    case .image, .generatedImage: .blue
    case .mask: .white
    case .prompt, .string, .tokens: .yellow
    case .conditioning, .visionEmbedding: .purple
    case .seed, .integer, .number: .orange
    case .curve1D: .mint
    case .boolean: .pink
    case .latent, .noise: .cyan
    case .modelFunction, .textEncoderFunction, .vaeFunction, .samplerFunction,
      .upscaleModelFunction, .controlNetFunction, .visionEncoderFunction, .styleModelFunction:
      .red
    case .schedule, .guider: .mint
    case .video, .audio: .indigo
    default: .gray
    }
  }
}

private struct PipelineMarkdownView: View {
  let markdown: String

  var body: some View {
    ScrollView {
      Text(attributedMarkdown)
        .font(.caption)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
    }
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
    }
    .environment(\.openURL, OpenURLAction { url in
      guard url.scheme?.lowercased() == "https" else { return .discarded }
      NSWorkspace.shared.open(url)
      return .handled
    })
  }

  private var attributedMarkdown: AttributedString {
    (try? AttributedString(
      markdown: markdown,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)))
      ?? AttributedString(markdown)
  }
}

private extension PipelineResourceBinding {
  var displayValue: String {
    switch self {
    case .linked(let reference):
      reference.packageID
    case .unresolved(let requirement):
      "Unresolved: \(requirement.sourceName)"
    }
  }
}

private extension PipelineValue {
  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var displayValue: String {
    switch self {
    case .null: "null"
    case .boolean(let value): value ? "true" : "false"
    case .integer(let value): String(value)
    case .number(let value): value.formatted()
    case .string(let value): value
    case .array(let value): "[\(value.count) values]"
    case .object(let value): "{\(value.count) values}"
    }
  }
}

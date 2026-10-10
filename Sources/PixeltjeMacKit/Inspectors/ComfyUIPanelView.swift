import PixeltjeMacDomain
import SwiftUI

struct ComfyUIPanelView: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var historyStore: ComfyUIHistoryStore
  @ObservedObject private var workflowLibrary = ComfyUIWorkflowLibrary.shared
  var selectWorkflow: (String) -> Void
  var updateParameter: (ComfyUIParameterAddress, ComfyUIParameterValue) -> Void
  var resetParameter: (ComfyUIParameterAddress) -> Void
  var resetNode: (String) -> Void
  var refreshConnection: () -> Void
  var refreshJob: (UUID) -> Void
  var restoreHistory: (ComfyUIHistoryEntry) -> Void
  var clearHistory: () -> Void
  var manageWorkflows: () -> Void

  private enum ActivityTab: String, CaseIterable {
    case tasks = "Tasks"
    case history = "History"
  }

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper
  // types explicitly so Command Line Tools builds do not require it.
  private typealias SearchState = SwiftUI.State<String>
  private typealias ExpandedState = SwiftUI.State<Set<String>>
  private typealias DisclosureExpandedState = SwiftUI.State<Bool>
  private typealias ActivityState = SwiftUI.State<ActivityTab>
  private typealias ConfirmationState = SwiftUI.State<Bool>
  @SearchState private var searchText = ""
  @ExpandedState private var expandedNodes: Set<String> = []
  @DisclosureExpandedState private var isGenerationOptionsExpanded = true
  @DisclosureExpandedState private var isNodeListExpanded = false
  @ActivityState private var activityTab: ActivityTab = .tasks
  @ConfirmationState private var isConfirmingHistoryClear = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      connectionHeader

      Text(serverAddress)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(serverAddress)

      HStack(spacing: 6) {
        Picker(
          "Workflow",
          selection: Binding(
            get: { model.selectedComfyUIWorkflowID },
            set: { selectWorkflow($0) })
        ) {
          ForEach(availableWorkflowTemplates) { template in
            Text(template.name).tag(template.id)
          }
        }
        .pickerStyle(.menu)

        Button(action: manageWorkflows) {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Manage ComfyUI workflows in Settings")
        .accessibilityLabel("Manage ComfyUI workflows")
      }

      DisclosureGroup(isExpanded: $isGenerationOptionsExpanded) {
        GenerationOptionsView(model: model)
          .padding(.top, 8)
      } label: {
        Text("Generation options")
          .font(.subheadline.weight(.semibold))
      }

      Divider()
      activityTabs

      if let notice = model.comfyUIHistoryRestoreNotice {
        Text(notice)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()
      workflowSettings

      // Text("HTTP submits and retrieves results; WebSocket events update progress automatically.")
      //   .font(.caption2)
      //   .foregroundStyle(.secondary)
      //   .fixedSize(horizontal: false, vertical: true)

      if case .disconnected(let reason) = model.comfyUIConnection, let reason {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var availableWorkflowTemplates: [ComfyUIWorkflowTemplate] {
    ComfyUIWorkflowCatalog.bundledTemplates + workflowLibrary.customTemplates
  }

  private var serverAddress: String {
    model.comfyUIExecutionTarget == .cloud
      ? ComfyCloudClient.baseURL.absoluteString
      : ComfyUIClient.configuredBaseURL.absoluteString
  }

  private var connectionHeader: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(connectionColor)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(model.comfyUIConnection.label)
        .font(.subheadline.weight(.medium))
      Spacer()
      Button(action: refreshConnection) {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Check the ComfyUI connection and reload workflow settings")
    }
  }

  @ViewBuilder private var workflowSettings: some View {
    switch model.comfyUIWorkflowFormState {
    case .unavailable:
      Text("Connect to ComfyUI to inspect this workflow's settings.")
        .workflowMessageStyle()
    case .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading node settings…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .failed(let message):
      VStack(alignment: .leading, spacing: 4) {
        Text("Workflow settings unavailable")
          .font(.caption.weight(.semibold))
        Text(message).workflowMessageStyle()
      }
    case .ready(let form):
      DisclosureGroup(isExpanded: $isNodeListExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          TextField("Search node settings", text: $searchText)
            .textFieldStyle(.roundedBorder)

          let nodes = matchingNodes(in: form)
          if nodes.isEmpty {
            Text("No node settings match this search.")
              .workflowMessageStyle()
          } else {
            ForEach(nodes) { node in
              workflowNode(node, templateID: form.templateID)
            }
          }
        }
        .padding(.top, 8)
      } label: {
        HStack {
          Text("Nodes")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text("\(form.settingsNodes.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityValue(isNodeListExpanded ? "Expanded" : "Collapsed")
    }
  }

  private func workflowNode(
    _ node: ComfyUIWorkflowNodeDefinition,
    templateID: String
  ) -> some View {
    let parameters = matchingParameters(in: node)
    let modified = node.parameters.filter(isModified).count
    let isExpanded = Binding(
      get: {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || expandedNodes.contains(node.id)
      },
      set: { expanded in
        if expanded { expandedNodes.insert(node.id) } else { expandedNodes.remove(node.id) }
      })

    return GroupBox {
      DisclosureGroup(isExpanded: isExpanded) {
        VStack(alignment: .leading, spacing: 10) {
          if parameters.isEmpty {
            Text(
              node.parameters.isEmpty
                ? "This node has no editable scalar settings."
                : "No settings in this node match the search."
            )
            .workflowMessageStyle()
          } else {
            ForEach(parameters) { parameter in
              ComfyUIParameterEditor(
                parameter: parameter,
                value: model.comfyUIParameterValues[parameter.address],
                isPrompt: ComfyUIWorkflowCatalog.address(
                  for: .prompt, templateID: templateID) == parameter.address,
                update: { updateParameter(parameter.address, $0) },
                reset: { resetParameter(parameter.address) })
              if parameter.id != parameters.last?.id {
                Divider()
              }
            }
          }
        }
        .padding(.top, 8)
      } label: {
        HStack(spacing: 6) {
          VStack(alignment: .leading, spacing: 1) {
            Text(node.title)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
            Text(node.classType)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 4)
          if modified > 0 {
            Text("\(modified)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Button {
            resetNode(node.id)
          } label: {
            Image(systemName: "arrow.counterclockwise")
          }
          .buttonStyle(.borderless)
          .disabled(modified == 0)
          .help("Reset this node's settings")
        }
      }
    }
  }

  private var activityTabs: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Picker("ComfyUI activity", selection: $activityTab) {
          ForEach(ActivityTab.allCases, id: \.self) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if model.generationJobs.contains(where: { $0.state.isActive }) {
          ProgressView().controlSize(.small)
        }
      }

      switch activityTab {
      case .tasks:
        taskList
      case .history:
        historyList
      }
    }
    .confirmationDialog(
      "Clear all generation history?",
      isPresented: $isConfirmingHistoryClear,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive, action: clearHistory)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes app-wide ComfyUI history from every document. Generated layers are unchanged.")
    }
  }

  @ViewBuilder private var taskList: some View {
    if model.generationJobs.isEmpty {
      Text("No ComfyUI tasks yet in this document.")
        .workflowMessageStyle()
    } else {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(model.generationJobs.reversed()) { job in
            VStack(alignment: .leading, spacing: 4) {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(job.prompt.isEmpty ? "Generation" : job.prompt)
                    .font(.caption)
                    .lineLimit(1)
                  Text(job.state.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                  refreshJob(job.id)
                } label: {
                  Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Update this task from ComfyUI")
                .disabled(job.backendID == nil)
              }
              ProgressView(value: job.progress)
            }
            .padding(.trailing, 4)
          }
        }
      }
      .scrollIndicators(.visible)
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: 220)
    }
  }

  @ViewBuilder private var historyList: some View {
    VStack(alignment: .leading, spacing: 8) {
      if historyStore.entries.isEmpty {
        Text("No recorded ComfyUI history yet.")
          .workflowMessageStyle()
      } else {
        HStack {
          Text("All documents")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Clear History…", role: .destructive) {
            isConfirmingHistoryClear = true
          }
          .buttonStyle(.borderless)
        }

        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(historyStore.entries) { entry in
              historyRow(entry)
              if entry.id != historyStore.entries.last?.id { Divider() }
            }
          }
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 260)
      }

      if let error = historyStore.persistenceError {
        Text(error)
          .font(.caption2)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func historyRow(_ entry: ComfyUIHistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(entry.prompt)
          .font(.caption.weight(.medium))
          .lineLimit(2)
        Spacer(minLength: 4)
        Button("Restore") { restoreHistory(entry) }
          .controlSize(.small)
          .disabled(!canRestoreHistory(entry))
          .help(restoreHelp(entry))
      }

      Text("\(entry.workflowName) · \(entry.executionTarget.label)")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(historyTimingSummary(entry))
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      if let detail = entry.statusDetail, !detail.isEmpty {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.trailing, 4)
  }

  private func historyTimingSummary(_ entry: ComfyUIHistoryEntry) -> String {
    let start = entry.queuedAt.formatted(date: .abbreviated, time: .standard)
    var summary = "\(entry.status.label) · \(start)"

    if let finishedAt = entry.finishedAt, let elapsedSeconds = entry.elapsedSeconds {
      let end: String
      if Calendar.current.isDate(finishedAt, inSameDayAs: entry.queuedAt) {
        end = finishedAt.formatted(date: .omitted, time: .standard)
      } else {
        end = finishedAt.formatted(date: .abbreviated, time: .standard)
      }
      let duration = elapsedSeconds.formatted(
        .number.precision(.fractionLength(1)))
      summary += " → \(end) = \(duration) sec"
    }

    if !entry.modifiedParameters.isEmpty {
      summary += " · \(entry.modifiedParameters.count) modified"
    }
    return summary
  }

  private func canRestoreHistory(_ entry: ComfyUIHistoryEntry) -> Bool {
    !model.generationJobs.contains(where: { $0.state.isActive })
      && model.comfyUISelectionPreview == nil
      && ComfyUIWorkflowCatalog.templates.contains(where: { $0.id == entry.templateID })
  }

  private func restoreHelp(_ entry: ComfyUIHistoryEntry) -> String {
    if model.generationJobs.contains(where: { $0.state.isActive }) {
      return "Wait for the active task to finish before restoring history."
    }
    if model.comfyUISelectionPreview != nil {
      return "Apply or discard the selection preview before restoring history."
    }
    if !ComfyUIWorkflowCatalog.templates.contains(where: { $0.id == entry.templateID }) {
      return "This workflow is no longer installed."
    }
    return "Restore this prompt, workflow, generation options, and modified node settings."
  }

  private func matchingNodes(in form: ComfyUIWorkflowForm)
    -> [ComfyUIWorkflowNodeDefinition]
  {
    let query = normalizedSearch
    let settingsNodes = form.settingsNodes
    guard !query.isEmpty else { return settingsNodes }
    return settingsNodes.filter { node in
      node.title.localizedCaseInsensitiveContains(query)
        || node.classType.localizedCaseInsensitiveContains(query)
        || node.id.localizedCaseInsensitiveContains(query)
        || node.parameters.contains { matches($0, query: query) }
    }
  }

  private func matchingParameters(in node: ComfyUIWorkflowNodeDefinition)
    -> [ComfyUIParameterDefinition]
  {
    let query = normalizedSearch
    guard !query.isEmpty else { return node.parameters }
    if node.title.localizedCaseInsensitiveContains(query)
      || node.classType.localizedCaseInsensitiveContains(query)
      || node.id.localizedCaseInsensitiveContains(query)
    {
      return node.parameters
    }
    return node.parameters.filter { matches($0, query: query) }
  }

  private func matches(_ parameter: ComfyUIParameterDefinition, query: String) -> Bool {
    parameter.label.localizedCaseInsensitiveContains(query)
      || parameter.address.inputName.localizedCaseInsensitiveContains(query)
      || parameter.address.displayValue.localizedCaseInsensitiveContains(query)
      || (model.comfyUIParameterValues[parameter.address]?.displayValue
        .localizedCaseInsensitiveContains(query) ?? false)
  }

  private var normalizedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func isModified(_ parameter: ComfyUIParameterDefinition) -> Bool {
    guard !parameter.isConnected, !isPrompt(parameter) else { return false }
    return model.comfyUIParameterValues[parameter.address] != parameter.templateValue
  }

  private func isPrompt(_ parameter: ComfyUIParameterDefinition) -> Bool {
    ComfyUIWorkflowCatalog.address(
      for: .prompt, templateID: model.selectedComfyUIWorkflowID) == parameter.address
  }

  private var connectionColor: Color {
    switch model.comfyUIConnection {
    case .checking: .orange
    case .connected: .green
    case .disconnected: .red
    }
  }
}

private struct ComfyUIParameterEditor: View {
  let parameter: ComfyUIParameterDefinition
  let value: ComfyUIParameterValue?
  let isPrompt: Bool
  let update: (ComfyUIParameterValue) -> Void
  let reset: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(parameter.label)
          .font(.caption.weight(.medium))
        if parameter.isAdvanced {
          Text("Advanced")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isModified {
          Button(action: reset) {
            Image(systemName: "arrow.counterclockwise")
          }
          .buttonStyle(.borderless)
          .help("Reset \(parameter.label)")
        }
      }

      control

      HStack(spacing: 4) {
        Text(parameter.address.inputName)
        Text("·")
        Text("Node \(parameter.address.nodeID)")
      }
      .font(.caption2.monospaced())
      .foregroundStyle(.tertiary)

      if let tooltip = parameter.tooltip, !tooltip.isEmpty {
        Text(tooltip)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder private var control: some View {
    if parameter.isConnected {
      Label("Driven by another node", systemImage: "link")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if isPrompt {
      Label("Edited in the prompt box", systemImage: "text.bubble")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      switch parameter.control {
      case .integer(let isUnsigned):
        HStack(spacing: 6) {
          if isUnsigned {
            TextField("Value", value: unsignedBinding, format: .number)
              .textFieldStyle(.roundedBorder)
          } else {
            TextField("Value", value: signedBinding, format: .number)
              .textFieldStyle(.roundedBorder)
          }
          Stepper(
            onIncrement: { incrementInteger(unsigned: isUnsigned) },
            onDecrement: { decrementInteger(unsigned: isUnsigned) }
          ) {
            EmptyView()
          }
          .labelsHidden()
        }
      case .decimal:
        HStack(spacing: 6) {
          TextField("Value", value: decimalBinding, format: .number)
            .textFieldStyle(.roundedBorder)
          Stepper(onIncrement: incrementDecimal, onDecrement: decrementDecimal) {
            EmptyView()
          }
          .labelsHidden()
        }
      case .boolean:
        Toggle("Enabled", isOn: booleanBinding)
          .toggleStyle(.switch)
      case .text(let multiline):
        if multiline {
          TextField("Value", text: stringBinding, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...6)
        } else {
          TextField("Value", text: stringBinding)
            .textFieldStyle(.roundedBorder)
        }
      case .choice(let options):
        Picker("Value", selection: choiceBinding(options: options)) {
          ForEach(options, id: \.self) { option in
            Text(option.displayValue).tag(option)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      case .unsupported(let description):
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var currentValue: ComfyUIParameterValue? {
    value ?? parameter.templateValue
  }

  private var isModified: Bool {
    !parameter.isConnected && !isPrompt && value != parameter.templateValue
  }

  private var signedBinding: Binding<Int64> {
    Binding(
      get: { currentValue?.signedIntegerValue ?? 0 },
      set: { update(.signedInteger($0)) })
  }

  private var unsignedBinding: Binding<UInt64> {
    Binding(
      get: { currentValue?.unsignedIntegerValue ?? 0 },
      set: { update(.unsignedInteger($0)) })
  }

  private var decimalBinding: Binding<Double> {
    Binding(
      get: { currentValue?.doubleValue ?? 0 },
      set: { update(.decimal($0)) })
  }

  private var booleanBinding: Binding<Bool> {
    Binding(
      get: { currentValue?.booleanValue ?? false },
      set: { update(.boolean($0)) })
  }

  private var stringBinding: Binding<String> {
    Binding(
      get: { currentValue?.stringValue ?? "" },
      set: { update(.string($0)) })
  }

  private func choiceBinding(options: [ComfyUIParameterValue])
    -> Binding<ComfyUIParameterValue>
  {
    Binding(
      get: {
        currentValue.flatMap { options.contains($0) ? $0 : nil }
          ?? options.first ?? .string("")
      },
      set: { update($0) })
  }

  private func incrementInteger(unsigned: Bool) {
    if unsigned {
      let current = currentValue?.unsignedIntegerValue ?? 0
      let step = max(parameter.step?.unsignedIntegerValue ?? 1, 1)
      let (candidate, overflow) = current.addingReportingOverflow(step)
      update(.unsignedInteger(overflow ? UInt64.max : candidate))
    } else {
      let current = currentValue?.signedIntegerValue ?? 0
      let step = max(parameter.step?.signedIntegerValue ?? 1, 1)
      let (candidate, overflow) = current.addingReportingOverflow(step)
      update(.signedInteger(overflow ? Int64.max : candidate))
    }
  }

  private func decrementInteger(unsigned: Bool) {
    if unsigned {
      let current = currentValue?.unsignedIntegerValue ?? 0
      let step = max(parameter.step?.unsignedIntegerValue ?? 1, 1)
      update(.unsignedInteger(current >= step ? current - step : 0))
    } else {
      let current = currentValue?.signedIntegerValue ?? 0
      let step = max(parameter.step?.signedIntegerValue ?? 1, 1)
      let (candidate, overflow) = current.subtractingReportingOverflow(step)
      update(.signedInteger(overflow ? Int64.min : candidate))
    }
  }

  private func incrementDecimal() {
    update(.decimal((currentValue?.doubleValue ?? 0) + decimalStep))
  }

  private func decrementDecimal() {
    update(.decimal((currentValue?.doubleValue ?? 0) - decimalStep))
  }

  private var decimalStep: Double {
    max(parameter.step?.doubleValue ?? 0.1, Double.leastNonzeroMagnitude)
  }
}

private extension View {
  func workflowMessageStyle() -> some View {
    font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

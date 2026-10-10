import PixeltjeMacDomain
import SwiftUI

/// What the history and snapshot lists ask for.
///
/// The views name an intent; the window controller routes it and the document
/// decides what it means, records the step and registers the undo.
enum HistoryIntent {
  case returnToStep(HistoryStepID)
  case takeSnapshot
  case restoreSnapshot(HistorySnapshotID)
  case renameSnapshot(HistorySnapshotID, String)
  case deleteSnapshot(HistorySnapshotID)
}

/// The ordered list of edits, newest last, with the current position marked.
///
/// Steps ahead of the current position are shown dimmed: they are the branch
/// that the next edit discards, exactly as undo already implies.
struct HistoryPanelView: View {
  @ObservedObject var model: EditorModel
  let send: (HistoryIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(model.history.steps) { step in
        HistoryStepRow(
          step: step,
          isCurrent: step.id == model.history.currentStepID,
          isAhead: model.history.isAhead(step.id)
        ) {
          send(.returnToStep(step.id))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel("Edit history")
  }
}

private struct HistoryStepRow: View {
  let step: HistoryStep
  let isCurrent: Bool
  let isAhead: Bool
  let activate: () -> Void

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 7) {
        Image(systemName: isCurrent ? "smallcircle.filled.circle" : "circle")
          .font(.caption2)
          .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        Text(step.name)
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        Text(step.date, format: .dateTime.hour().minute())
          .font(.caption2)
          .monospacedDigit()
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(isCurrent ? Color.accentColor.opacity(0.14) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isAhead ? 0.45 : 1)
    .help(isAhead ? "\(step.name) — undone; the next edit discards it" : step.name)
    .accessibilityLabel(step.name)
    .accessibilityValue(isCurrent ? "Current state" : (isAhead ? "Undone" : "Earlier state"))
  }
}

/// Named states pinned out of the linear history.
///
/// A snapshot survives undo and truncation, so it is the way back to a state
/// whose branch has since been replaced.
struct SnapshotsPanelView: View {
  @ObservedObject var model: EditorModel
  let send: (HistoryIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.history.snapshots.isEmpty {
        Text("Pin the current state to come back to it after other edits.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(model.history.snapshots) { snapshot in
            SnapshotRow(snapshot: snapshot, send: send)
          }
        }
      }

      Button {
        send(.takeSnapshot)
      } label: {
        Label("New Snapshot", systemImage: "camera.aperture")
      }
      .controlSize(.small)
      .help("Pin the current state under a name")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel("Snapshots")
  }
}

private struct SnapshotRow: View {
  let snapshot: HistorySnapshot
  let send: (HistoryIntent) -> Void

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias NameState = SwiftUI.State<String>
  @NameState private var name: String

  init(snapshot: HistorySnapshot, send: @escaping (HistoryIntent) -> Void) {
    self.snapshot = snapshot
    self.send = send
    _name = NameState(initialValue: snapshot.name)
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "camera.aperture")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField(
        "Snapshot name",
        text: $name
      )
      .textFieldStyle(.plain)
      .font(.callout)
      .lineLimit(1)
      .onSubmit { send(.renameSnapshot(snapshot.id, name)) }
      Button {
        send(.restoreSnapshot(snapshot.id))
      } label: {
        Image(systemName: "arrow.uturn.backward.circle")
      }
      .buttonStyle(.borderless)
      .help("Return the document to this state")
      .accessibilityLabel("Restore \(snapshot.name)")
      Button {
        send(.deleteSnapshot(snapshot.id))
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Delete this snapshot")
      .accessibilityLabel("Delete \(snapshot.name)")
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .onChange(of: snapshot.name) { _, renamed in name = renamed }
  }
}

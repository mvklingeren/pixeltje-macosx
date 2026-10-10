import Foundation
import SwiftUI

/// What the export queue asks for.
///
/// The panel names an intent; the window controller routes it to the queue or
/// to the Finder. The view itself neither runs work nor touches the file
/// system.
enum ExportQueueIntent {
  case showExportPopup
  case cancel(UUID)
  case remove(UUID)
  case clearCompleted
  case reveal(URL)
}

/// The background export queue: what is waiting, what is rendering, and what
/// landed on disk.
///
/// It observes `EditorModel`, which the queue publishes into, so the rows keep
/// updating while the user goes on editing the document that produced them.
struct ExportQueuePanelView: View {
  @ObservedObject var model: EditorModel
  let send: (ExportQueueIntent) -> Void

  private var hasCompleted: Bool {
    model.exportJobs.contains { !$0.state.isActive }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.exportJobs.isEmpty {
        Text("Exports run in the background and appear here with their progress.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(model.exportJobs) { job in
            ExportJobRow(job: job, send: send)
          }
        }
      }

      HStack(spacing: 8) {
        Button {
          send(.showExportPopup)
        } label: {
          Label("Export…", systemImage: "square.and.arrow.up")
        }
        .controlSize(.small)
        .help("Choose an export preset and destination")

        if hasCompleted {
          Button("Clear Finished") { send(.clearCompleted) }
            .controlSize(.small)
            .help("Remove the exports that are no longer running")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel("Export queue")
  }
}

private struct ExportJobRow: View {
  let job: ExportJob
  let send: (ExportQueueIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: symbolName)
          .font(.caption)
          .foregroundStyle(symbolColor)
        VStack(alignment: .leading, spacing: 1) {
          Text(job.filename)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(job.statusText)
            .font(.caption2)
            .foregroundStyle(isFailed ? Color.red : Color.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 4)
        if job.state.isActive {
          Button {
            send(.cancel(job.id))
          } label: {
            Image(systemName: "xmark.circle")
          }
          .buttonStyle(.borderless)
          .help("Cancel this export")
          .accessibilityLabel("Cancel \(job.filename)")
        } else {
          if case .finished = job.state {
            Button {
              send(.reveal(job.destination))
            } label: {
              Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show the exported file in the Finder")
            .accessibilityLabel("Reveal \(job.filename)")
          }
          Button {
            send(.remove(job.id))
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.borderless)
          .help("Remove this row")
          .accessibilityLabel("Remove \(job.filename)")
        }
      }

      if job.state.isActive {
        ProgressView(value: job.progress)
          .progressViewStyle(.linear)
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(job.state.isActive ? Color.accentColor.opacity(0.10) : Color.clear)
    )
    .help("\(job.presetName) — \(job.summary)")
    .accessibilityElement(children: .combine)
    .accessibilityValue(job.statusText)
  }

  private var isFailed: Bool {
    if case .failed = job.state { return true }
    return false
  }

  private var symbolName: String {
    switch job.state {
    case .waiting: "clock"
    case .running: "arrow.triangle.2.circlepath"
    case .finished: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    case .cancelled: "slash.circle"
    }
  }

  private var symbolColor: Color {
    switch job.state {
    case .finished: .green
    case .failed: .red
    case .waiting, .running, .cancelled: .secondary
    }
  }
}

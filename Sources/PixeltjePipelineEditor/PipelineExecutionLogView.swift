import AppKit
import PixeltjePipelineEngine
import SwiftUI

struct PipelineExecutionLogView: View {
  @ObservedObject var model: PipelineEditorModel
  let openFile: () -> Void
  @State private var selectedKey: String?

  private func key(_ record: PipelineTraceRecord) -> String {
    "\(record.runID.uuidString):\(record.call):\(record.nodeID)"
  }

  private var displayRecords: [PipelineTraceRecord] {
    let finished = Set(model.traceRecords.filter { $0.phase != "started" }.map(key))
    return model.traceRecords.filter { $0.phase != "started" || !finished.contains(key($0)) }
  }

  private var selectedRecord: PipelineTraceRecord? {
    displayRecords.first(where: { key($0) == selectedKey }) ?? displayRecords.last
  }

  private var selectedStart: PipelineTraceRecord? {
    guard let selectedRecord else { return nil }
    return model.traceRecords.first {
      key($0) == key(selectedRecord) && $0.phase == "started"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Open Log…", action: openFile)
        if let url = model.traceLogURL {
          Text(url.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        } else {
          Text("Enable debug capture in Settings, then run a workflow.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(12)
      if let error = model.traceError {
        Text(error).foregroundStyle(.red).padding(.horizontal, 12)
      }
      Divider()
      HSplitView {
        List(displayRecords) { record in
          Button {
            selectedKey = key(record)
          } label: {
            HStack {
              VStack(alignment: .leading) {
                Text(record.nodeTitle).fontWeight(.medium)
                Text("Call \(record.call) · \(record.nodeID)")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(record.phase).font(.caption)
                .foregroundStyle(record.phase == "failed" ? Color.red : Color.secondary)
            }
            .padding(.vertical, 2)
          }
          .buttonStyle(.plain)
          .listRowBackground(selectedRecord.map(key) == key(record)
            ? Color.accentColor.opacity(0.15) : nil)
        }
        .frame(minWidth: 250, idealWidth: 300)
        ScrollView {
          if let record = selectedRecord {
            VStack(alignment: .leading, spacing: 14) {
              Text(record.nodeTitle).font(.title2)
              Text("\(record.workflow) · call \(record.call) · \(record.nodeID) · \(record.phase)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              if let duration = record.durationSeconds {
                Text("Duration: \(duration.formatted(.number.precision(.fractionLength(3)))) s")
              }
              if let error = record.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
              }
              values("Inputs", selectedStart?.inputs ?? record.inputs)
              values("Parameters", selectedStart?.parameters ?? record.parameters)
              values("Outputs", record.outputs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
          } else {
            ContentUnavailableView("No execution records", systemImage: "list.bullet.rectangle")
          }
        }
        .frame(minWidth: 300)
      }
    }
  }

  @ViewBuilder
  private func values(_ title: String, _ items: [String: PipelineTraceValue]?) -> some View {
    if let items, !items.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        ForEach(items.keys.sorted(), id: \.self) { name in
          if let value = items[name] {
            VStack(alignment: .leading, spacing: 5) {
              Text("\(name) · \(value.type)").fontWeight(.medium)
              Text(value.summary).foregroundStyle(.secondary)
              if let text = value.text {
                Text(text).font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
              }
              if let data = value.previewPNG, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                  .frame(maxWidth: 256, maxHeight: 256)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
  }
}

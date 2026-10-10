import Foundation
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import Testing

private actor TraceRecorder {
  var records: [PipelineTraceRecord] = []

  func append(_ record: PipelineTraceRecord) { records.append(record) }
}

@Test func traceCapturesResolvedInputsOutputsAndTerminalResult() async throws {
  let promptID = PipelineNodeID(rawValue: "prompt")
  let outputID = PipelineNodeID(rawValue: "output")
  let document = PipelineDocument(
    id: PipelineID(rawValue: "trace-text"), name: "Trace text", mode: .generic,
    nodes: [
      PipelineNode(id: promptID, kind: .promptInput,
        parameters: ["value": .string("hello trace")]),
      PipelineNode(id: outputID, kind: .textOutput),
    ],
    connections: [.init(
      output: .init(nodeID: promptID, port: "prompt"),
      input: .init(nodeID: outputID, port: "text"))],
    primaryOutputNodeIDs: [outputID])
  let recorder = TraceRecorder()
  let runID = UUID()
  let result = try await PixeltjePipelineEngine().execute(
    document, packageRootsByID: [:], invocation: PipelineInvocation(),
    trace: { record in await recorder.append(record) },
    traceRunID: runID, traceCall: 2)

  guard case .plainText(let text) = result else {
    Issue.record("Expected a plain text terminal result")
    return
  }
  #expect(text.text == "hello trace")
  let records = await recorder.records
  #expect(records.count == 4)
  #expect(records.allSatisfy { $0.runID == runID && $0.call == 2 })
  #expect(records.first { $0.nodeID == "prompt" && $0.phase == "started" }?
    .parameters?["value"]?.text == "hello trace")
  #expect(records.first { $0.nodeID == "output" && $0.phase == "started" }?
    .inputs?["text"]?.text == "hello trace")
  #expect(records.first { $0.nodeID == "output" && $0.phase == "completed" }?
    .outputs?["terminal"]?.text == "hello trace")
}

@Test func traceLogPreservesCompleteEventsAfterContentBudgetAndPartialWrite() async throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-trace-\(UUID().uuidString).jsonl")
  defer { try? FileManager.default.removeItem(at: url) }
  let log = try PipelineTraceLog(url: url, maximumBytes: 1)
  let node = PipelineNode(id: PipelineNodeID(rawValue: "source"), kind: .promptInput)
  let record = PipelineTraceRecord(
    runID: UUID(), call: 1, workflow: "Test", graphSHA256: "test",
    node: node, phase: "completed",
    outputs: ["prompt": .text("private debug text")])
  await log.record(record)
  try await log.close()
  let decoded = try PipelineTraceLog.read(url)
  #expect(decoded.count == 1)
  #expect(decoded[0].outputs?["prompt"]?.text == nil)
  #expect(decoded[0].outputs?["prompt"]?.summary.contains("omitted") == true)

  let handle = try FileHandle(forWritingTo: url)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("{\"unfinished\":".utf8))
  try handle.close()
  #expect(try PipelineTraceLog.read(url).count == 1)
}

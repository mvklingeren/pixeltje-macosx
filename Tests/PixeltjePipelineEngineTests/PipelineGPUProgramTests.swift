import Foundation
import IOSurface
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import Testing

@Test func flurryFilePathValidatesAgainstWorkflowFolder() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  let document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-flurry.pixpipeline.json")))
  let pathIndex = try #require(document.nodes.firstIndex {
    $0.id.rawValue == "shader-text"
  })
  #expect(document.nodes[pathIndex].kind == .primitiveFilePath)
  #expect(document.nodes[pathIndex].parameters["mode"] == .string("relative"))
  #expect(document.nodes[pathIndex].parameters["path"] == .string("FlurryProgram.metal"))
  let pathExecutor = try #require(BuiltInPipelineNodeExecutors.all.first {
    $0.kind == .primitiveFilePath
  })
  let context = PipelineNodeExecutionContext(
    semanticSHA256: "", invocation: .init(), sourceMediaRoot: examples,
    packageRootsByID: [:], nodeIndex: 0, nodeCount: 1,
    progress: { _ in }, requestedOutputPorts: ["value", "contents"])
  let output = try await pathExecutor.execute(document.nodes[pathIndex],
    inputs: [:], context: context)
  #expect(output.outputs["value"]?.value(as: String.self) == "FlurryProgram.metal")
  #expect(output.outputs["contents"]?.value(as: String.self)?
    .contains("kernel void initializeSmoke") == true)

  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  #expect((await engine.validate(document, sourceMediaRoot: examples)).isValid)

  var contentsSource = document
  contentsSource.connections.removeAll {
    $0.input.nodeID.rawValue == "render" &&
      ($0.input.port == "source" || $0.input.port == "sourceFile")
  }
  contentsSource.connections.append(.init(
    output: .init(nodeID: .init(rawValue: "shader-text"), port: "contents"),
    input: .init(nodeID: .init(rawValue: "render"), port: "source")))
  let contentsReport = await engine.validate(contentsSource, sourceMediaRoot: examples)
  #expect(contentsReport.isValid)
  #expect(!contentsReport.diagnostics.contains { $0.code == .shaderNotChecked })

  contentsSource.nodes[pathIndex].parameters["mode"] = .string("absolute")
  let wrongMode = await engine.validate(contentsSource)
  #expect(wrongMode.errors.contains {
    $0.code == .invalidParameter && $0.nodeID == contentsSource.nodes[pathIndex].id
  })

  contentsSource.nodes[pathIndex].parameters["path"] = .string("/tmp/FlurryProgram.metal")
  let outsideFolder = await engine.validate(contentsSource, sourceMediaRoot: examples)
  #expect(outsideFolder.errors.contains {
    $0.code == .invalidShader && $0.nodeID?.rawValue == "render"
  })
}

@Test func flurryGPUProgramPersistsOnlyPublishedFramesAndReplaysExactly() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  var document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-hearts.pixpipeline.json")))
  for index in document.nodes.indices {
    if document.nodes[index].id.rawValue == "primitive-int" {
      document.nodes[index].parameters["value"] = .integer(96)
    } else if document.nodes[index].id.rawValue == "primitive-int-2" {
      document.nodes[index].parameters["value"] = .integer(60)
    }
  }
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  let report = await engine.validate(document, sourceMediaRoot: examples)
  #expect(report.isValid)
  let runID = UUID()
  func frame(_ index: Int64) async throws -> PipelineGeneratedImage {
    let output = try await engine.execute(document, sourceMediaRoot: examples,
      packageRootsByID: [:], invocation: .init(values: [
        PipelineInvocation.loopCallIndexKey: .integer(index),
        PipelineInvocation.gpuProgramDeferredCommitKey: .boolean(true),
      ]), traceRunID: runID, traceCall: Int(index) + 1)
    return try #require(output.image)
  }
  let first = try await frame(0)
  #expect(first.width == 96 && first.height == 60)
  #expect(first.planarRGB.contains(where: { $0 > 0.001 }))
  await engine.commitGPUProgramFrame(runID: runID)
  let second = try await frame(1)
  #expect(second.planarRGB != first.planarRGB)
  await engine.discardGPUProgramFrame(runID: runID)
  let retried = try await frame(1)
  #expect(retried.planarRGB == second.planarRGB)
  await engine.commitGPUProgramFrame(runID: runID)
  let replayed = try await frame(0)
  #expect(replayed.planarRGB == first.planarRGB)

  let previewRunID = UUID()
  await engine.beginLiveMetalPreview(runID: previewRunID,
    nodeID: .init(rawValue: "render"))
  func bytes(_ frame: PipelineMetalPreviewFrame) throws -> Data {
    try #require(IOSurfaceLock(frame.surface, .readOnly, nil) == 0)
    defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
    return Data(bytes: IOSurfaceGetBaseAddress(frame.surface),
      count: IOSurfaceGetBytesPerRow(frame.surface) * frame.height)
  }
  var retainedFrame: PipelineMetalPreviewFrame?
  var retainedBytes: Data?
  for index in Int64(0)...1 {
    let output = try await engine.updateLiveMetalPreviewState(document,
      runID: previewRunID, nodeID: .init(rawValue: "render"),
      sourceMediaRoot: examples, packageRootsByID: [:],
      invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(index)]))
    #expect(output.image == nil)
    let preview = try #require(await engine.liveMetalPreview(runID: previewRunID))
    #expect(preview.width == 96 && preview.height == 60)
    if index == 0 {
      retainedFrame = preview
      retainedBytes = try bytes(preview)
    } else {
      #expect(try bytes(try #require(retainedFrame)) == retainedBytes)
    }
  }
  await engine.endLiveMetalPreview(runID: previewRunID)
}

@Test func flarefunTrackpadMovesSmokeWithoutResettingGPUHistory() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  var document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-flarefun.pixpipeline.json")))
  for index in document.nodes.indices {
    if document.nodes[index].id.rawValue == "primitive-int" {
      document.nodes[index].parameters["value"] = .integer(256)
    } else if document.nodes[index].id.rawValue == "primitive-int-2" {
      document.nodes[index].parameters["value"] = .integer(160)
    }
  }
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  #expect((await engine.validate(document, sourceMediaRoot: examples)).isValid)

  func frame(_ index: Int64, x: Double, runID: UUID) async throws -> PipelineGeneratedImage {
    let output = try await engine.execute(document, sourceMediaRoot: examples,
      packageRootsByID: [:], invocation: .init(values: [
        PipelineInvocation.loopCallIndexKey: .integer(index),
        PipelineInvocation.trackpadXKey: .number(x),
        PipelineInvocation.trackpadYKey: .number(0.5),
        PipelineInvocation.gpuProgramDeferredCommitKey: .boolean(true),
      ]), traceRunID: runID, traceCall: Int(index) + 1)
    return try #require(output.image)
  }

  let steeredRun = UUID()
  _ = try await frame(0, x: 0.5, runID: steeredRun)
  await engine.commitGPUProgramFrame(runID: steeredRun)
  let steered = try await frame(1, x: 0.9, runID: steeredRun)
  await engine.commitGPUProgramFrame(runID: steeredRun)

  let freshRun = UUID()
  _ = try await frame(0, x: 0.9, runID: freshRun)
  await engine.commitGPUProgramFrame(runID: freshRun)
  let fresh = try await frame(1, x: 0.9, runID: freshRun)
  #expect(steered.planarRGB != fresh.planarRGB)
}

@Test func liveGPUProgramUsesLatestPointerAfterInvocationWasCaptured() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  var document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-flarefun.pixpipeline.json")))
  for index in document.nodes.indices {
    if document.nodes[index].id.rawValue == "primitive-int" {
      document.nodes[index].parameters["value"] = .integer(256)
    } else if document.nodes[index].id.rawValue == "primitive-int-2" {
      document.nodes[index].parameters["value"] = .integer(160)
    }
  }
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  let nodeID = PipelineNodeID(rawValue: "render")

  func frameBytes(runID: UUID, index: Int64) async throws -> Data {
    _ = try await engine.updateLiveMetalPreviewState(document,
      runID: runID, nodeID: nodeID, sourceMediaRoot: examples,
      packageRootsByID: [:], invocation: .init(values: [
        PipelineInvocation.loopCallIndexKey: .integer(index),
        PipelineInvocation.trackpadXKey: .number(0.5),
        PipelineInvocation.trackpadYKey: .number(0.5),
      ]))
    let frame = try #require(await engine.liveMetalPreview(runID: runID))
    let surface = frame.surface
    try #require(IOSurfaceLock(surface, .readOnly, nil) == 0)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let base = IOSurfaceGetBaseAddress(surface)
    return Data(bytes: base, count: IOSurfaceGetBytesPerRow(surface) * frame.height)
  }

  let idleRun = UUID()
  await engine.beginLiveMetalPreview(runID: idleRun, nodeID: nodeID)
  _ = try await frameBytes(runID: idleRun, index: 0)
  let idle = try await frameBytes(runID: idleRun, index: 1)
  await engine.endLiveMetalPreview(runID: idleRun)

  let steeredRun = UUID()
  await engine.beginLiveMetalPreview(runID: steeredRun, nodeID: nodeID)
  _ = try await frameBytes(runID: steeredRun, index: 0)
  await engine.updateLiveGPUProgramPointer(runID: steeredRun, nodeID: nodeID,
    revision: 2, x: 0.9, y: 0.5, actionCount: 0)
  await engine.updateLiveGPUProgramPointer(runID: steeredRun, nodeID: nodeID,
    revision: 1, x: 0.5, y: 0.5, actionCount: 0)
  let steered = try await frameBytes(runID: steeredRun, index: 1)
  #expect(steered != idle)
  await engine.endLiveMetalPreview(runID: steeredRun)
}

@Test func liveGPUProgramSuppliesElapsedTimeWithoutChangingSavedFrames() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  var document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-hearts.pixpipeline.json")))
  let program = #"{"version":1,"resources":[{"name":"state","kind":"buffer","bytes":4},{"name":"display","kind":"texture"}],"initialize":[],"tick":[{"kind":"compute","function":"advance","threads":[1],"buffers":{"1":"state"}}],"present":[{"kind":"render","vertex":"vertexMain","fragment":"fragmentMain","target":"display","load":"clear","vertexCount":3,"fragmentBuffers":{"1":"state"}}],"swaps":[],"output":"display"}"#
  let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms {
      float4 resolutionTime;
      uint4 frameSeed;
      float4 parameters0;
      float4 parameters1;
      float4 parameters2;
      float4 parameters3;
      float4 pointer;
    };
    kernel void advance(constant Uniforms &u [[buffer(0)]],
      device float *state [[buffer(1)]], uint id [[thread_position_in_grid]]) {
      if (id == 0) state[0] += u.pointer.w;
    }
    struct Vertex { float4 position [[position]]; };
    vertex Vertex vertexMain(uint id [[vertex_id]]) {
      float2 p = float2((id << 1u) & 2u, id & 2u);
      return {float4(p * 2.0f - 1.0f, 0.0f, 1.0f)};
    }
    fragment float4 fragmentMain(device const float *state [[buffer(1)]]) {
      return float4(state[0], 0.0f, 0.0f, 1.0f);
    }
    """
  for index in document.nodes.indices {
    switch document.nodes[index].id.rawValue {
    case "shader-text": document.nodes[index].parameters["value"] = .string("LiveDelta.metal")
    case "program-text": document.nodes[index].parameters["value"] = .string(program)
    case "parameters-text": document.nodes[index].parameters["value"] = .string("{}")
    case "primitive-int", "primitive-int-2":
      document.nodes[index].parameters["value"] = .integer(2)
    default: break
    }
  }
  let folder = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-live-delta-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  try source.write(to: folder.appendingPathComponent("LiveDelta.metal"),
    atomically: true, encoding: .utf8)
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  let nodeID = PipelineNodeID(rawValue: "render")
  let runID = UUID()
  await engine.beginLiveMetalPreview(runID: runID, nodeID: nodeID)

  func liveValue(_ index: Int64) async throws -> Float {
    _ = try await engine.updateLiveMetalPreviewState(document,
      runID: runID, nodeID: nodeID, sourceMediaRoot: folder,
      packageRootsByID: [:], invocation: .init(values: [
        PipelineInvocation.loopCallIndexKey: .integer(index),
      ]))
    let frame = try #require(await engine.liveMetalPreview(runID: runID))
    try #require(IOSurfaceLock(frame.surface, .readOnly, nil) == 0)
    defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
    return Float(IOSurfaceGetBaseAddress(frame.surface)
      .assumingMemoryBound(to: Float16.self).pointee)
  }

  let first = try await liveValue(0)
  try await Task.sleep(for: .milliseconds(80))
  let second = try await liveValue(1)
  #expect(first > 0.01)
  #expect(second > first + 0.05)
  await engine.endLiveMetalPreview(runID: runID)

  let saved = try await engine.execute(document, sourceMediaRoot: folder,
    packageRootsByID: [:], invocation: .init(values: [
      PipelineInvocation.loopCallIndexKey: .integer(0),
    ]), traceRunID: UUID())
  #expect(try #require(saved.image).planarRGB[0] == 0)
}

@Test func ashenPathTrackpadClickChangesTheNextGameFrame() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  var document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-ashen-path.pixpipeline.json")))
  for index in document.nodes.indices {
    if document.nodes[index].id.rawValue == "primitive-int" {
      document.nodes[index].parameters["value"] = .integer(320)
    } else if document.nodes[index].id.rawValue == "primitive-int-2" {
      document.nodes[index].parameters["value"] = .integer(200)
    }
  }
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  #expect((await engine.validate(document, sourceMediaRoot: examples)).isValid)

  func frame(_ index: Int64, x: Double, y: Double, actionCount: Int64 = 0,
    runID: UUID) async throws -> PipelineGeneratedImage {
    let output = try await engine.execute(document, sourceMediaRoot: examples,
      packageRootsByID: [:], invocation: .init(values: [
        PipelineInvocation.loopCallIndexKey: .integer(index),
        PipelineInvocation.trackpadXKey: .number(x),
        PipelineInvocation.trackpadYKey: .number(y),
        PipelineInvocation.trackpadActionCountKey: .integer(actionCount),
        PipelineInvocation.gpuProgramDeferredCommitKey: .boolean(true),
      ]), traceRunID: runID, traceCall: Int(index) + 1)
    return try #require(output.image)
  }

  let clickedRun = UUID()
  _ = try await frame(0, x: 0.5, y: 0.5, runID: clickedRun)
  await engine.commitGPUProgramFrame(runID: clickedRun)
  let clicked = try await frame(1, x: 0.62, y: 0.60, runID: clickedRun)

  let idleRun = UUID()
  _ = try await frame(0, x: 0.5, y: 0.5, runID: idleRun)
  await engine.commitGPUProgramFrame(runID: idleRun)
  let idle = try await frame(1, x: 0.5, y: 0.5, runID: idleRun)
  #expect(clicked.planarRGB != idle.planarRGB)

  let attackRun = UUID()
  _ = try await frame(0, x: 0.5, y: 0.5, runID: attackRun)
  await engine.commitGPUProgramFrame(runID: attackRun)
  let attack = try await frame(1, x: 0.5, y: 0.5,
    actionCount: 1, runID: attackRun)
  #expect(attack.planarRGB != idle.planarRGB)
}

import Foundation
import IOSurface
import Metal
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import PixeltjePipelineFLUX2Runtime
import PixeltjePipelineStableAudioRuntime
import Testing

@Test func abyssalTreasureSystemFontCompilesAndPreparesOutlines() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  let document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-abyssal-treasure-3d.pixpipeline.json")))
  let program = try #require(document.nodes.first { $0.id.rawValue == "program-text" }?
    .parameters["value"]?.stringValue)
  let source = try String(contentsOf:
    examples.appendingPathComponent("AbyssalTreasureProgram.metal"), encoding: .utf8)
  let device = try #require(MTLCreateSystemDefaultDevice())
  let queue = try #require(device.makeCommandQueue())
  let runner = PipelineGPUProgram(commandQueue: queue)
  try await runner.validateLiteral(programJSON: program, source: source)

  let prepared = try PipelineSystemFont.prepare(design: "monospaced", weight: "medium",
    strings: ["LEVEL CLEAR", "OXYGEN EMPTY", "0", "8"])
  #expect(prepared.bytes.count > 100)
  #expect(prepared.fingerprint.contains(prepared.resolvedName))
  #expect(prepared.fingerprint == (try PipelineSystemFont.prepare(design: "monospaced",
    weight: "medium", strings: ["LEVEL CLEAR", "OXYGEN EMPTY", "0", "8"])).fingerprint)

  let image = try PipelineImageInput(width: 1, height: 1,
    rgba: [0.32, 0.48, 0.54, 1])
  let pixel = PipelineNodeValue(image, type: .image)
  let assets = PipelineAssetBundle(values: [
    "asset0": pixel, "asset1": pixel, "asset2": pixel,
    "asset3": pixel, "asset4": pixel,
  ])
  let inputs: [String: PipelineNodeValue] = [
    "program": .init(program, type: .string),
    "sourceFile": .init("AbyssalTreasureProgram.metal", type: .string),
    "assets": .init(assets, type: .assetBundle),
    "width": .init(Int64(320), type: .integer),
    "height": .init(Int64(200), type: .integer),
  ]
  let node = try #require(document.nodes.first { $0.id.rawValue == "render" })
  let savedRunID = UUID()
  let savedContext = PipelineNodeExecutionContext(semanticSHA256: "font-test",
    invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(0)]),
    sourceMediaRoot: examples, packageRootsByID: [:], nodeIndex: 0,
    nodeCount: 1, progress: { _ in }, runID: savedRunID)
  let executor = PipelineGPUProgram.executor(runner: runner)
  let savedOutput = try await executor.execute(node, inputs: inputs, context: savedContext)
  let saved = try #require(savedOutput.outputs["image"]?.value(as: PipelineImageInput.self))
  #expect(saved.width == 320 && saved.height == 200)

  let liveRunID = UUID()
  await runner.beginLivePreview(runID: liveRunID, nodeID: node.id)
  await runner.setPerformanceCapture(runID: liveRunID)
  let liveContext = PipelineNodeExecutionContext(semanticSHA256: "font-test",
    invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(0)]),
    sourceMediaRoot: examples, packageRootsByID: [:], nodeIndex: 0,
    nodeCount: 1, progress: { _ in }, runID: liveRunID)
  try await runner.captureLivePreview(node: node, inputs: inputs,
    context: liveContext)
  #expect(await runner.livePreview(runID: liveRunID) != nil)
  let performance = try #require(runner.takePerformance(runID: liveRunID))
  #expect(performance.previewCopySeconds == 0)
  await runner.endLivePreview(runID: liveRunID)
}

@Test func sceneSwitchRunsOnlyActiveGPUProgramAndCommitsRequests() async throws {
  func id(_ value: String) -> PipelineNodeID { .init(rawValue: value) }
  let source = """
  #include <metal_stdlib>
  using namespace metal;
  struct Uniforms {
    float4 resolutionTime; uint4 frameSeed;
    float4 parameters0; float4 parameters1; float4 parameters2; float4 parameters3;
    float4 pointer; float4 movement;
  };
  kernel void tick(constant Uniforms &u [[buffer(0)]],
    device uint *counter [[buffer(1)]], device uint *request [[buffer(2)]],
    uint index [[thread_position_in_grid]]) {
    if (index != 0) return;
    counter[0] += 1;
    if (counter[0] == 2) request[0] = uint(u.parameters0.x);
  }
  vertex float4 fullscreenVertex(uint index [[vertex_id]]) {
    float2 p = float2((index << 1u) & 2u, index & 2u);
    return float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
  }
  fragment float4 sceneFragment(float4 position [[position]],
    constant Uniforms &u [[buffer(0)]],
    device const uint *counter [[buffer(1)]]) {
    return float4(u.parameters0.y, float(counter[0]) * 0.1f, 0.0f, 1.0f);
  }
  """
  let program = """
  {"version":1,"resources":[{"name":"counter","kind":"buffer","bytes":4},
  {"name":"request","kind":"buffer","bytes":4},
  {"name":"display","kind":"texture"}],"initialize":[],
  "tick":[{"kind":"compute","function":"tick","threads":[1],
  "buffers":{"1":"counter","2":"request"}}],
  "present":[{"kind":"render","vertex":"fullscreenVertex",
  "fragment":"sceneFragment","target":"display","load":"clear",
  "vertexCount":3,"fragmentBuffers":{"1":"counter"}}],
  "swaps":[],"output":"display","sceneRequestBuffer":"request",
  "parameters":["target","tint"]}
  """
  func node(_ name: String, _ kind: PipelineNodeKind,
    _ parameters: [String: PipelineValue] = [:]) -> PipelineNode {
    .init(id: id(name), kind: kind, parameters: parameters)
  }
  func edge(_ source: String, _ output: String,
    _ target: String, _ input: String) -> PipelineConnection {
    .init(output: .init(nodeID: id(source), port: output),
      input: .init(nodeID: id(target), port: input))
  }
  let document = PipelineDocument(id: .init(rawValue: "scene-switch-test"),
    name: "Scene switch test", mode: .textToImage,
    nodes: [
      node("source", .primitiveString, ["value": .string(source)]),
      node("program", .primitiveString, ["value": .string(program)]),
      node("params0", .primitiveString,
        ["value": .string("{\"target\":1,\"tint\":0.8}")]),
      node("params1", .primitiveString,
        ["value": .string("{\"target\":0,\"tint\":0.2}")]),
      node("gpu0", .gpuProgram,
        ["width": .integer(4), "height": .integer(4)]),
      node("gpu1", .gpuProgram,
        ["width": .integer(4), "height": .integer(4)]),
      node("switch", .sceneSwitch,
        ["sceneCount": .integer(2), "initialScene": .integer(0)]),
      node("output", .imageOutput),
    ],
    connections: [
      edge("source", "value", "gpu0", "source"),
      edge("source", "value", "gpu1", "source"),
      edge("program", "value", "gpu0", "program"),
      edge("program", "value", "gpu1", "program"),
      edge("params0", "value", "gpu0", "parameters"),
      edge("params1", "value", "gpu1", "parameters"),
      edge("gpu0", "image", "switch", "scene0"),
      edge("gpu0", "sceneRequest", "switch", "request0"),
      edge("gpu1", "image", "switch", "scene1"),
      edge("gpu1", "sceneRequest", "switch", "request1"),
      edge("switch", "image", "output", "image"),
    ])
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  #expect((await engine.validate(document)).isValid)

  let runID = UUID()
  func frame(_ index: Int64) async throws -> PipelineGeneratedImage {
    let result = try await engine.execute(document, packageRootsByID: [:],
      invocation: .init(values: [
        PipelineInvocation.loopCallIndexKey: .integer(index),
        PipelineInvocation.gpuProgramDeferredCommitKey: .boolean(true),
      ]), traceRunID: runID)
    return try #require(result.image)
  }
  let first = try await frame(0)
  #expect(abs(first.planarRGB[0] - 0.8) < 0.02)
  await engine.commitGPUProgramFrame(runID: runID)
  let win = try await frame(1)
  #expect(abs(win.planarRGB[16] - 0.2) < 0.02)
  await engine.discardGPUProgramFrame(runID: runID)
  #expect(try await frame(1) == win)
  await engine.commitGPUProgramFrame(runID: runID)
  let secondScene = try await frame(2)
  #expect(abs(secondScene.planarRGB[0] - 0.2) < 0.02)
  #expect(abs(secondScene.planarRGB[16] - 0.1) < 0.02)
  await engine.commitGPUProgramFrame(runID: runID)
  _ = try await frame(3)
  await engine.commitGPUProgramFrame(runID: runID)
  let resumed = try await frame(4)
  #expect(abs(resumed.planarRGB[0] - 0.8) < 0.02)
  #expect(abs(resumed.planarRGB[16] - 0.3) < 0.02)

  let liveRunID = UUID()
  await engine.beginLiveMetalPreview(runID: liveRunID, nodeID: id("switch"))
  var firstSceneRed: Data?
  for index in Int64(0)...2 {
    let output = try await engine.updateLiveMetalPreviewState(document,
      runID: liveRunID, nodeID: id("switch"), packageRootsByID: [:],
      invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(index)]))
    #expect(output.image == nil)
    let preview = try #require(await engine.liveMetalPreview(runID: liveRunID))
    #expect(preview.width == 4 && preview.height == 4)
    #expect(IOSurfaceLock(preview.surface, .readOnly, nil) == 0)
    let red = Data(bytes: IOSurfaceGetBaseAddress(preview.surface), count: 2)
    IOSurfaceUnlock(preview.surface, .readOnly, nil)
    if index == 0 { firstSceneRed = red }
    if index == 2 { #expect(red != firstSceneRed) }
  }
  await engine.endLiveMetalPreview(runID: liveRunID)
}

@Test func signalRangeSceneSwitchExampleValidatesBothMetalPrograms() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  let document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-signal-range-fps.pixpipeline.json")))
  let fluxRunner = FLUX2KleinPipelineRunner()
  let audioRunner = StableAudio3Runner()
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeDescriptors: [FLUX2KleinPipelineFamily.makeCompositeNodeDescriptor(),
      StableAudio3Family.descriptor()],
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors()
      + [FLUX2KleinPipelineFamily.makeNodeExecutor(runner: fluxRunner),
        StableAudio3Family.executor(runner: audioRunner)])
  let report = await engine.validate(document, sourceMediaRoot: examples)
  #expect(report.isValid, "\(report.diagnostics)")
}

private let audioVoiceTestSource = """
  #include <metal_stdlib>
  using namespace metal;
  struct Uniforms {
    float4 resolutionTime; uint4 frameSeed;
    float4 parameters0; float4 parameters1; float4 parameters2; float4 parameters3;
    float4 pointer; float4 movement;
  };
  kernel void tick(constant Uniforms &u [[buffer(0)]],
    device uint *audio [[buffer(1)]], uint index [[thread_position_in_grid]]) {
    if (index != 0) return;
    audio[0] = 2u;
    device float *voice = (device float *)(audio + 4);
    voice[0] = 2.0f;
    voice[1] = 1.5f;
    voice[2] = -0.5f;
    voice[3] = 0.25f;
  }
  vertex float4 fullscreenVertex(uint index [[vertex_id]]) {
    float2 p = float2((index << 1u) & 2u, index & 2u);
    return float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
  }
  fragment float4 audioFragment(float4 position [[position]]) {
    return float4(0.2f, 0.3f, 0.4f, 1.0f);
  }
  """

private func audioVoiceTestProgram(bytes: Int = 32, eventWord: Int = 0,
  voiceWord: Int = 4) -> String {
  """
  {"version":1,"resources":[{"name":"audio","kind":"buffer","bytes":\(bytes)},
  {"name":"display","kind":"texture"}],"initialize":[],
  "tick":[{"kind":"compute","function":"tick","threads":[1],
  "buffers":{"1":"audio"}}],
  "present":[{"kind":"render","vertex":"fullscreenVertex",
  "fragment":"audioFragment","target":"display","load":"clear","vertexCount":3}],
  "swaps":[],"output":"display",
  "audioEvents":[{"buffer":"audio","word":\(eventWord),"asset":"sfx"}],
  "audioVoices":[{"buffer":"audio","word":\(voiceWord),"asset":"sfx"}]}
  """
}

@Test func gpuProgramAudioEventsAndVoicesShareWordsWithoutOverlap() async throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  let runner = PipelineGPUProgram(commandQueue: try #require(device.makeCommandQueue()))
  try await runner.validateLiteral(programJSON: audioVoiceTestProgram(),
    source: audioVoiceTestSource)
  // A voice needs four words of its own, inside a small buffer.
  for program in [audioVoiceTestProgram(voiceWord: 0),
    audioVoiceTestProgram(voiceWord: 5), audioVoiceTestProgram(bytes: 30),
    audioVoiceTestProgram(bytes: 512)] {
    await #expect(throws: PipelineEngineError.self) {
      try await runner.validateLiteral(programJSON: program,
        source: audioVoiceTestSource)
    }
  }
}

@Test func gpuProgramAudioVoicesLoopAnAssetOrPlayAValidSynth() async throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  let runner = PipelineGPUProgram(commandQueue: try #require(device.makeCommandQueue()))
  let asset = "\"asset\":\"sfx\""
  let rotor = "\"synth\":{\"kind\":\"rotor\",\"rotors\":4,\"blades\":2,\"hz\":105}"
  func program(_ voice: String) -> String {
    audioVoiceTestProgram().replacingOccurrences(of: "\"word\":4,\(asset)",
      with: "\"word\":4,\(voice)")
  }
  try await runner.validateLiteral(programJSON: program(rotor),
    source: audioVoiceTestSource)
  for voice in ["\(asset),\(rotor)", "\"label\":\"none\"",
    rotor.replacingOccurrences(of: "\"rotors\":4", with: "\"rotors\":9"),
    rotor.replacingOccurrences(of: "\"hz\":105", with: "\"hz\":4000"),
    rotor.replacingOccurrences(of: "rotor\"", with: "siren\"")] {
    await #expect(throws: (any Error).self) {
      try await runner.validateLiteral(programJSON: program(voice),
        source: audioVoiceTestSource)
    }
  }
}

@Test func liveGPUProgramReportsCommittedAudioVoices() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  let sound = examples.appendingPathComponent("BaseTestSet/two-tone.wav")
  let device = try #require(MTLCreateSystemDefaultDevice())
  let runner = PipelineGPUProgram(commandQueue: try #require(device.makeCommandQueue()))
  let node = PipelineNode(id: .init(rawValue: "voices"), kind: .gpuProgram)
  let inputs: [String: PipelineNodeValue] = [
    "program": .init(audioVoiceTestProgram(), type: .string),
    "source": .init(audioVoiceTestSource, type: .string),
    "assets": .init(PipelineAssetBundle(values: [
      "sfx": PipelineNodeValue(sound, type: .audio),
    ]), type: .assetBundle),
    "width": .init(Int64(4), type: .integer),
    "height": .init(Int64(4), type: .integer),
  ]
  let runID = UUID()
  let context = PipelineNodeExecutionContext(semanticSHA256: "audio-voice-test",
    invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(0)]),
    sourceMediaRoot: examples, packageRootsByID: [:], nodeIndex: 0,
    nodeCount: 1, progress: { _ in }, runID: runID)
  await runner.beginLivePreview(runID: runID, nodeID: node.id)
  _ = try await runner.captureLivePreview(node: node, inputs: inputs, context: context)
  #expect(await runner.takeLiveAudioVoices(runID: runID).isEmpty)
  await runner.commit(runID: runID)
  #expect(await runner.takeLiveAudioEvents(runID: runID) == [sound, sound])
  let voices = await runner.takeLiveAudioVoices(runID: runID)
  #expect(voices == [PipelineGPUAudioVoice(nodeID: node.id, slot: 0,
    source: .sound(sound), gain: 1, rate: 1.5, pan: -0.5, drive: 0.25)])
  #expect(await runner.takeLiveAudioVoices(runID: runID).isEmpty)
  await runner.endLivePreview(runID: runID)
}

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

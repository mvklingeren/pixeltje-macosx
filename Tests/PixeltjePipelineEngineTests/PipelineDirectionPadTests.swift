import Foundation
import Metal
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import Testing

@Test func directionPadUsesTransientHostAxesAndDefaultsToNeutral() async throws {
  let executor = try #require(BuiltInPipelineNodeExecutors.all.first {
    $0.kind == .directionPad
  })
  let node = PipelineNode(id: PipelineNodeID(rawValue: "movement"), kind: .directionPad)

  func axes(_ invocation: PipelineInvocation) async throws -> (Double, Double) {
    let context = PipelineNodeExecutionContext(semanticSHA256: "direction-pad-test",
      invocation: invocation, sourceMediaRoot: nil, packageRootsByID: [:],
      nodeIndex: 0, nodeCount: 1, progress: { _ in })
    let result = try await executor.execute(node, inputs: [:], context: context)
    return (
      try #require(result.outputs["x"]?.value(as: Double.self)),
      try #require(result.outputs["y"]?.value(as: Double.self)))
  }

  let neutral = try await axes(.init())
  #expect(neutral.0 == 0 && neutral.1 == 0)

  let moving = try await axes(.init(values: [
    PipelineInvocation.directionPadXKey: .number(-1),
    PipelineInvocation.directionPadYKey: .number(1),
  ]))
  #expect(moving.0 == -1 && moving.1 == 1)

  await #expect(throws: PipelineEngineError.self) {
    _ = try await axes(.init(values: [
      PipelineInvocation.directionPadXKey: .number(1.1),
    ]))
  }
}

@Test func trackpadSecondaryActionIsIndependentAndTransient() async throws {
  let executor = try #require(BuiltInPipelineNodeExecutors.all.first {
    $0.kind == .trackpad
  })
  let node = PipelineNode(id: PipelineNodeID(rawValue: "look"), kind: .trackpad)
  func counts(_ invocation: PipelineInvocation) async throws -> (Double, Double) {
    let context = PipelineNodeExecutionContext(semanticSHA256: "trackpad-actions-test",
      invocation: invocation, sourceMediaRoot: nil, packageRootsByID: [:],
      nodeIndex: 0, nodeCount: 1, progress: { _ in })
    let result = try await executor.execute(node, inputs: [:], context: context)
    return (
      try #require(result.outputs["actionCount"]?.value(as: Double.self)),
      try #require(result.outputs["secondaryActionCount"]?.value(as: Double.self)))
  }

  let idle = try await counts(.init())
  #expect(idle.0 == 0 && idle.1 == 0)
  let jumping = try await counts(.init(values: [
    PipelineInvocation.trackpadSecondaryActionCountKey: .integer(1),
  ]))
  #expect(jumping.0 == 0 && jumping.1 == 1)
  await #expect(throws: PipelineEngineError.self) {
    _ = try await counts(.init(values: [
      PipelineInvocation.trackpadSecondaryActionCountKey: .integer(-1),
    ]))
  }
}

@Test func signalRangeMovementChangesTheRenderedCamera() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  let document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-signal-range-fps.pixpipeline.json")))
  let node = try #require(document.nodes.first { $0.id.rawValue == "render" })
  let program = try #require(document.nodes.first { $0.id.rawValue == "program-text" }?
    .parameters["value"]?.stringValue)
  let device = try #require(MTLCreateSystemDefaultDevice())
  let queue = try #require(device.makeCommandQueue())
  let runner = PipelineGPUProgram(commandQueue: queue)
  let source = try PipelineMeshRenderer.shaderSource(supplied: nil,
    fileName: "SignalRangeFPSProgram.metal", sourceMediaRoot: examples)
  try await runner.validateLiteral(programJSON: program, source: source)
  let pixel = PipelineNodeValue(try PipelineImageInput(width: 1, height: 1,
    rgba: [0.5, 0.4, 0.3, 1]), type: .image)
  let assets = PipelineAssetBundle(values: [
    "asset0": pixel, "asset1": pixel, "asset2": pixel,
    "asset3": PipelineNodeValue(examples.appendingPathComponent(
      "BaseTestSet/two-tone.wav"), type: .audio),
    "asset4": PipelineNodeValue(examples.appendingPathComponent(
      "BaseTestSet/two-tone.wav"), type: .audio),
    "asset5": PipelineNodeValue(examples.appendingPathComponent(
      "BaseTestSet/two-tone.wav"), type: .audio),
    "asset6": PipelineNodeValue(examples.appendingPathComponent(
      "BaseTestSet/two-tone.wav"), type: .audio),
    "asset7": PipelineNodeValue(examples.appendingPathComponent(
      "BaseTestSet/two-tone.wav"), type: .audio),
    "asset8": PipelineNodeValue(examples.appendingPathComponent(
      "BaseTestSet/two-tone.wav"), type: .audio),
    "asset9": PipelineNodeValue(examples.appendingPathComponent(
      "BaseTestSet/two-tone.wav"), type: .audio),
  ])
  let executor = PipelineGPUProgram.executor(runner: runner)

  func frame(movingForward: Bool, jumping: Bool = false) async throws -> PipelineImageInput {
    let inputs: [String: PipelineNodeValue] = [
      "program": .init(program, type: .string),
      "sourceFile": .init("SignalRangeFPSProgram.metal", type: .string),
      "assets": .init(assets, type: .assetBundle),
      "width": .init(Int64(160), type: .integer),
      "height": .init(Int64(90), type: .integer),
      "moveY": .init(movingForward ? 1.0 : 0.0, type: .number),
      "secondaryActionCount": .init(jumping ? 1.0 : 0.0, type: .number),
    ]
    let context = PipelineNodeExecutionContext(semanticSHA256: "signal-range-actions-test",
      invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(0)]),
      sourceMediaRoot: examples, packageRootsByID: [:], nodeIndex: 0,
      nodeCount: 1, progress: { _ in }, runID: UUID())
    let result = try await executor.execute(node, inputs: inputs, context: context)
    return try #require(result.outputs["image"]?.value(as: PipelineImageInput.self))
  }
  let standing = try await frame(movingForward: false)
  let moving = try await frame(movingForward: true)
  #expect(standing.rgba != moving.rgba)
  let jumping = try await frame(movingForward: false, jumping: true)
  #expect(standing.rgba != jumping.rgba)
}

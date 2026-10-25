import Foundation
import Metal
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import simd
import Testing

/// A local Mixamo export; it cannot be committed, so the test skips without it.
private let joggingFBX = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Downloads/Jogging.fbx")

@Test func loadSkinnedModelPacksMixamoJogLoop() throws {
  guard FileManager.default.fileExists(atPath: joggingFBX.path) else { return }
  let model = try PipelineSkinnedModel.load(fbx: joggingFBX)
  #expect(model.vertexCount > 0 && model.vertexCount.isMultiple(of: 3))
  #expect((1...PipelineSkinnedModel.maximumBones).contains(model.boneCount))
  #expect(model.frameCount == 77)
  #expect(abs(model.boundsMin.y) < 1e-4)
  let height = model.boundsMax.y - model.boundsMin.y
  #expect((1.4...2.1).contains(height), "height \(height) m")
  #expect(model.bytes.count == PipelineSkinnedModel.headerBytes
    + model.vertexCount * PipelineSkinnedModel.vertexBytes
    + model.frameCount * model.boneCount * 64)

  model.bytes.withUnsafeBytes { raw in
    #expect(raw.load(fromByteOffset: 0, as: UInt32.self) == UInt32(model.vertexCount))
    let verticesOffset = Int(raw.load(fromByteOffset: 48, as: UInt32.self))
    for index in stride(from: 0, to: model.vertexCount, by: 997) {
      let base = verticesOffset + index * PipelineSkinnedModel.vertexBytes
      let joints = raw.load(fromByteOffset: base + 28, as: SIMD4<UInt8>.self)
      let weights = raw.loadUnaligned(fromByteOffset: base + 32, as: SIMD4<Float>.self)
      #expect(abs(weights.sum() - 1) < 1e-3)
      #expect(Int(joints.max()) < model.boneCount)
    }
  }
}

@Test func loadSkinnedModelNodeResolvesHomePaths() throws {
  let url = try PipelineSkinnedModelLoader.url(for: "~/Downloads/Jogging.fbx",
    sourceMediaRoot: nil)
  #expect(url == joggingFBX.standardizedFileURL)
  let relative = try PipelineSkinnedModelLoader.url(for: "Models/a.fbx",
    sourceMediaRoot: URL(fileURLWithPath: "/tmp/workflow"))
  #expect(relative.path == "/tmp/workflow/Models/a.fbx")
  #expect(throws: PipelineEngineError.self) {
    _ = try PipelineSkinnedModelLoader.url(for: "a.fbx", sourceMediaRoot: nil)
  }
}

/// One triangle with one bone, packed as the loader packs it.
private func triangleModel(z: Float) -> PipelineSkinnedModel {
  var data = Data()
  func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
  append(UInt32(3)); append(UInt32(1)); append(UInt32(1)); append(Float(30))
  append(SIMD4<Float>(-1, -1, z, 0)); append(SIMD4<Float>(1, 1, z, 0))
  append(UInt32(64)); append(UInt32(64 + 3 * 48)); append(SIMD2<UInt32>.zero)
  for corner in [SIMD2<Float>(-1, -1), SIMD2(3, -1), SIMD2(-1, 3)] {
    append(corner.x); append(corner.y); append(z)
    append(UInt32(0xFF00_00FF))
    append(Float(0)); append(Float(0)); append(Float(1))
    append(SIMD4<UInt8>.zero)
    append(SIMD4<Float>(1, 0, 0, 0))
  }
  append(matrix_identity_float4x4)
  return PipelineSkinnedModel(bytes: data, vertexCount: 3, boneCount: 1, frameCount: 1,
    framesPerSecond: 30, boundsMin: SIMD3(-1, -1, z), boundsMax: SIMD3(1, 1, z),
    fingerprint: "triangle-\(z)")
}

@Test func gpuProgramDrawsSkinnedModelWithDepth() async throws {
  let source = """
  #include <metal_stdlib>
  using namespace metal;
  struct Uniforms {
    float4 resolutionTime; uint4 frameSeed;
    float4 parameters0; float4 parameters1; float4 parameters2; float4 parameters3;
    float4 pointer; float4 movement;
  };
  struct Header { uint vertexCount, boneCount, frameCount; float fps;
    float4 boundsMin, boundsMax; uint verticesOffset, framesOffset; uint2 reserved; };
  struct SkinnedVertex { packed_float3 position; uint color; packed_float3 normal;
    uint joints; float4 weights; };
  struct Out { float4 position [[position]]; float4 color; };
  struct Back { float4 color [[color(0)]]; float depth [[depth(any)]]; };
  vertex float4 fullscreenVertex(uint index [[vertex_id]]) {
    float2 p = float2((index << 1u) & 2u, index & 2u);
    return float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
  }
  // The background claims depth 0.5, so only a nearer model shows.
  fragment Back backgroundFragment(float4 position [[position]]) {
    return { float4(0.0f, 0.0f, 1.0f, 1.0f), 0.5f };
  }
  vertex Out modelVertex(uint id [[vertex_id]], device const uchar *model [[buffer(1)]]) {
    device const Header &header = *(device const Header *)model;
    device const SkinnedVertex *vertices =
      (device const SkinnedVertex *)(model + header.verticesOffset);
    device const float4x4 *bones = (device const float4x4 *)(model + header.framesOffset);
    SkinnedVertex v = vertices[id];
    float4 p = bones[v.joints & 0xFFu] * float4(float3(v.position), 1.0f);
    return { float4(p.xy, p.z, 1.0f), unpack_unorm4x8_to_float(v.color) };
  }
  fragment float4 modelFragment(Out in [[stage_in]]) { return in.color; }
  """
  let program = """
  {"version":1,"resources":[{"name":"model","kind":"skinnedModel","input":"asset0"},
  {"name":"sceneDepth","kind":"depth"},{"name":"display","kind":"texture"},
  {"name":"unused","kind":"buffer","bytes":4}],"initialize":[],
  "tick":[{"kind":"compute","function":"noop","threads":[1],"buffers":{"1":"unused"}}],
  "present":[{"kind":"render","vertex":"fullscreenVertex","fragment":"backgroundFragment",
  "target":"display","load":"clear","vertexCount":3,"depth":"sceneDepth"},
  {"kind":"render","vertex":"modelVertex","fragment":"modelFragment","target":"display",
  "load":"load","vertexCountFrom":"model","depth":"sceneDepth",
  "vertexBuffers":{"1":"model"}}],"swaps":[],"output":"display"}
  """
  let fullSource = source + "\nkernel void noop(device uint *u [[buffer(1)]]) {}\n"
  let device = try #require(MTLCreateSystemDefaultDevice())
  let runner = PipelineGPUProgram(commandQueue: try #require(device.makeCommandQueue()))
  try await runner.validateLiteral(programJSON: program, source: fullSource)
  let node = PipelineNode(id: .init(rawValue: "render"), kind: .gpuProgram)
  let executor = PipelineGPUProgram.executor(runner: runner)

  func centre(z: Float) async throws -> [Float] {
    let assets = PipelineAssetBundle(values: [
      "asset0": .init(triangleModel(z: z), type: .skinnedModel),
    ])
    let context = PipelineNodeExecutionContext(semanticSHA256: "skinned-model-test",
      invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(0)]),
      sourceMediaRoot: nil, packageRootsByID: [:], nodeIndex: 0, nodeCount: 1,
      progress: { _ in }, runID: UUID())
    let output = try await executor.execute(node, inputs: [
      "program": .init(program, type: .string),
      "source": .init(fullSource, type: .string),
      "assets": .init(assets, type: .assetBundle),
      "width": .init(Int64(8), type: .integer),
      "height": .init(Int64(8), type: .integer),
    ], context: context)
    let image = try #require(output.outputs["image"]?.value(as: PipelineImageInput.self))
    let index = (4 * 8 + 4) * 4
    return Array(image.rgba[index..<(index + 3)])
  }
  #expect(try await centre(z: 0.25) == [1, 0, 0])
  #expect(try await centre(z: 0.75) == [0, 0, 1])
}

@Test func gpuProgramRejectsDepthThatAFrameDoesNotClear() async throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  let runner = PipelineGPUProgram(commandQueue: try #require(device.makeCommandQueue()))
  let program = """
  {"version":1,"resources":[{"name":"d","kind":"depth"},{"name":"display","kind":"texture"},
  {"name":"b","kind":"buffer","bytes":4}],"initialize":[],
  "tick":[{"kind":"compute","function":"noop","threads":[1],"buffers":{"1":"b"}}],
  "present":[{"kind":"render","vertex":"v","fragment":"f","target":"display",
  "load":"load","vertexCount":3,"depth":"d"}],"swaps":[],"output":"display"}
  """
  await #expect(throws: PipelineEngineError.self) {
    try await runner.validateLiteral(programJSON: program, source: "")
  }
  let both = program.replacingOccurrences(of: "\"load\":\"load\",\"vertexCount\":3",
    with: "\"load\":\"clear\",\"vertexCount\":3,\"vertexCountFrom\":\"b\"")
  await #expect(throws: PipelineEngineError.self) {
    try await runner.validateLiteral(programJSON: both, source: "")
  }
}

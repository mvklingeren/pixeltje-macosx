import Foundation
import Metal
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import Testing

private func radianceFixture() -> Data {
  var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 8\n".utf8)
  data.append(contentsOf: [2, 2, 0, 8])
  for value in [UInt8(128), 64, 32, 131] {
    data.append(contentsOf: [136, value])
  }
  return data
}

@Test func radianceHDRPreservesLinearValuesAboveDisplayWhite() throws {
  let image = try PipelineRadianceHDR.decode(radianceFixture())
  #expect(image.width == 8)
  #expect(image.height == 1)
  #expect(image.rgba[0] == 4)
  #expect(image.rgba[1] == 2)
  #expect(image.rgba[2] == 1)
  #expect(image.rgba[3] == 1)
  #expect(image.fingerprint.count == 64)
}

@Test func radianceHDRRejectsTruncatedRLEWithoutReadingPastInput() {
  var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 8\n".utf8)
  data.append(contentsOf: [2, 2, 0, 8, 136])
  #expect(throws: Error.self) { try PipelineRadianceHDR.decode(data) }
}

@Test func gpuProgramSamplesLinkedRadianceFileWithoutClampingHDR() async throws {
  let file = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-rgbe-\(UUID().uuidString).hdr")
  try radianceFixture().write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }

  let source = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void tick(uint id [[thread_position_in_grid]]) {}
  vertex float4 full(uint id [[vertex_id]]) {
    float2 p = float2((id << 1u) & 2u, id & 2u);
    return float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
  }
  fragment float4 sampleHDR(float4 p [[position]],
    texture2d<float> hdr [[texture(1)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    return float4(hdr.sample(s, float2(0.5f, 0.5f)).rgb * 0.1f, 1.0f);
  }
  """
  let program = """
  {"version":1,"resources":[{"name":"display","kind":"texture"},
  {"name":"hdr","kind":"fileTexture","input":"textureFile"}],
  "initialize":[],"tick":[{"kind":"compute","function":"tick","threads":[1]}],
  "present":[{"kind":"render","vertex":"full","fragment":"sampleHDR",
  "target":"display","load":"clear","vertexCount":3,
  "fragmentTextures":{"1":"hdr"}}],"swaps":[],"output":"display"}
  """
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  let document = try PipelineJSON.decode(Data(contentsOf:
    examples.appendingPathComponent("shader-physics-playground.pixpipeline.json")))
  let node = try #require(document.nodes.first { $0.id.rawValue == "render" })
  let device = try #require(MTLCreateSystemDefaultDevice())
  let queue = try #require(device.makeCommandQueue())
  let runner = PipelineGPUProgram(commandQueue: queue)
  let inputs: [String: PipelineNodeValue] = [
    "program": .init(program, type: .string),
    "source": .init(source, type: .string),
    "textureFile": .init(file.path, type: .string),
    "width": .init(Int64(8), type: .integer),
    "height": .init(Int64(8), type: .integer),
  ]
  let context = PipelineNodeExecutionContext(semanticSHA256: "rgbe-test",
    invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(0)]),
    sourceMediaRoot: examples, packageRootsByID: [:], nodeIndex: 0,
    nodeCount: 1, progress: { _ in }, runID: UUID())
  let output = try await PipelineGPUProgram.executor(runner: runner)
    .execute(node, inputs: inputs, context: context)
  let image = try #require(output.outputs["image"]?.value(as: PipelineImageInput.self))
  #expect(image.width == 8)
  #expect((0.39...0.41).contains(image.rgba[0]))
  #expect((0.19...0.21).contains(image.rgba[1]))
}

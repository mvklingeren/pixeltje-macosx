import Foundation
import Metal
@testable import PixeltjePipelineEngine
import Testing

@Test func optedInEasingLibraryCompilesForMetalPrograms() throws {
  let source = """
    // pixeltje:easing-v1
    #include <metal_stdlib>
    kernel void sampleEasing(device float *results [[buffer(0)]],
                             uint index [[thread_position_in_grid]]) {
      float t = float(index) / 8.0f;
      results[index] = pixeltje_easing::linear(t)
        + pixeltje_easing::easeIn(t)
        + pixeltje_easing::easeOut(t)
        + pixeltje_easing::easeInOut(t);
    }
    """
  let resolved = try PipelineMeshRenderer.shaderSource(
    supplied: source, fileName: nil, sourceMediaRoot: nil)
  #expect(resolved != source)
  #expect(PipelineMetalEasing.resolving("#include <metal_stdlib>\n")
    == "#include <metal_stdlib>\n")
  let device = try #require(MTLCreateSystemDefaultDevice())
  let library = try device.makeLibrary(source: resolved, options: nil)
  #expect(library.makeFunction(name: "sampleEasing") != nil)
}

@Test func stackedMetalLibrariesCompileAndKeepOptInLocal() throws {
  let source = """
    // pixeltje:3d-v1
    // pixeltje:easing-v1
    #include <metal_stdlib>
    kernel void sample3D(device float4 *results [[buffer(0)]],
                         uint index [[thread_position_in_grid]]) {
      float3 forward = pixeltje_3d::forward(0.0f, 0.0f);
      float3 ray = pixeltje_3d::cameraDirection(float2(0.5f),
        float2(160.0f, 90.0f), 0.0f, 0.0f, 1.0f);
      float3 normal;
      float hit = pixeltje_3d::rayBox(float3(0.0f, 0.0f, 2.0f), ray,
        float3(-1.0f), float3(1.0f), 0.01f, normal);
      results[index] = float4(forward.z, hit, normal.z,
        pixeltje_easing::easeInOut(0.5f));
    }
    """
  let resolved = PipelineMetalLibraries.resolving(source)
  #expect(resolved.contains("namespace pixeltje_3d"))
  #expect(resolved.contains("namespace pixeltje_easing"))
  #expect(PipelineMetalLibraries.resolving("#include <metal_stdlib>\n")
    == "#include <metal_stdlib>\n")
  let device = try #require(MTLCreateSystemDefaultDevice())
  let library = try device.makeLibrary(source: resolved, options: nil)
  #expect(library.makeFunction(name: "sample3D") != nil)
}

@Test func sourceFileRereadsOnlyAfterAFileChanges() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let main = root.appendingPathComponent("Main.metal")
  let part = root.appendingPathComponent("Part.metal")
  try "#include \"Part.metal\"\n".write(to: main, atomically: true, encoding: .utf8)
  try "constant float a = 1.0f;\n".write(to: part, atomically: true, encoding: .utf8)
  func load() throws -> String {
    try PipelineMeshRenderer.shaderSource(supplied: nil, fileName: "Main.metal",
      sourceMediaRoot: root)
  }
  #expect(try load().contains("a = 1.0f"))
  #expect(try load().contains("a = 1.0f"))
  // An include rewritten in place, as an editor saves it.
  try "constant float a = 2.0f;\n".write(to: part, atomically: true, encoding: .utf8)
  #expect(try load().contains("a = 2.0f"))
  try FileManager.default.removeItem(at: part)
  #expect(throws: PipelineEngineError.self) { try load() }
}

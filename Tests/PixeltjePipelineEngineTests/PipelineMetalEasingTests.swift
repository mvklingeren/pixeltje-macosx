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

@Test func recursiveIncludesPragmaOnceLineDirectivesAndCycleDetection() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let main = root.appendingPathComponent("Main.metal")
  let midA = root.appendingPathComponent("MidA.metal")
  let midB = root.appendingPathComponent("MidB.metal")
  let leaf = root.appendingPathComponent("Leaf.metal")

  try """
    // pixeltje:easing-v1
    #include <metal_stdlib>
    #include "MidA.metal"
    #include "MidB.metal"
    kernel void checkNested(device float *out [[buffer(0)]]) {
      out[0] = pixeltje_easing::linear(leafValue + midAValue + midBValue);
    }
    """.write(to: main, atomically: true, encoding: .utf8)

  try """
    #pragma once
    #include "Leaf.metal"
    constant float midAValue = leafValue + 1.0f;
    """.write(to: midA, atomically: true, encoding: .utf8)

  try """
    #pragma once
    #include "Leaf.metal"
    constant float midBValue = leafValue + 2.0f;
    """.write(to: midB, atomically: true, encoding: .utf8)

  try """
    #pragma once
    constant float leafValue = 3.0f;
    """.write(to: leaf, atomically: true, encoding: .utf8)

  let resolved = try PipelineMeshRenderer.shaderSource(
    supplied: nil, fileName: "Main.metal", sourceMediaRoot: root)
  #expect(resolved.contains("namespace pixeltje_easing"))
  #expect(resolved.contains("#line 1 \"Main.metal\""))
  #expect(resolved.contains("#line 1 \"MidA.metal\""))
  #expect(resolved.contains("#line 1 \"Leaf.metal\""))
  #expect(resolved.contains("#line 4 \"Main.metal\""))
  #expect(!resolved.contains("#pragma once"))
  #expect(resolved.components(separatedBy: "constant float leafValue").count - 1 == 1)

  let device = try #require(MTLCreateSystemDefaultDevice())
  let library = try device.makeLibrary(source: resolved, options: nil)
  #expect(library.makeFunction(name: "checkNested") != nil)

  // Editing a deeply nested file invalidates the cached source.
  try """
    #pragma once
    constant float leafValue = 9.0f;
    """.write(to: leaf, atomically: true, encoding: .utf8)
  let updated = try PipelineMeshRenderer.shaderSource(
    supplied: nil, fileName: "Main.metal", sourceMediaRoot: root)
  #expect(updated.contains("leafValue = 9.0f"))

  // Introducing an include cycle fails with a clear cycle diagnostic.
  try """
    #include "Main.metal"
    constant float leafValue = 9.0f;
    """.write(to: leaf, atomically: true, encoding: .utf8)
  #expect(throws: PipelineEngineError.self) {
    _ = try PipelineMeshRenderer.shaderSource(
      supplied: nil, fileName: "Main.metal", sourceMediaRoot: root)
  }
}

@Test func shaderSourceAllowsMultiMegabyteSourceUpToLimit() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let largeComment = "// " + String(repeating: "x", count: 1_500_000) + "\n"
  let part = root.appendingPathComponent("LargePart.metal")
  let main = root.appendingPathComponent("LargeMain.metal")
  try (largeComment + "constant float largePartValue = 1.0f;\n")
    .write(to: part, atomically: true, encoding: .utf8)
  try ("#include <metal_stdlib>\n#include \"LargePart.metal\"\n" + largeComment)
    .write(to: main, atomically: true, encoding: .utf8)

  let expanded = try PipelineMeshRenderer.shaderSource(
    supplied: nil, fileName: "LargeMain.metal", sourceMediaRoot: root)
  #expect(expanded.utf8.count > 3_000_000)
  #expect(expanded.contains("largePartValue = 1.0f"))
}

@Test func metalSourceFileNamesAreEscapedInLineDirectives() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let device = try #require(MTLCreateSystemDefaultDevice())
  let source = """
    #include <metal_stdlib>
    kernel void checkFileName(device float *out [[buffer(0)]]) { out[0] = 1.0f; }
    """
  for name in ["Quote\"Name.metal", "Line\nBreak.metal"] {
    try source.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    let resolved = try PipelineMeshRenderer.shaderSource(
      supplied: nil, fileName: name, sourceMediaRoot: root)
    #expect(resolved.contains(PipelineMetalLibraries.lineDirective(1, fileName: name)))
    let library = try device.makeLibrary(source: resolved, options: nil)
    #expect(library.makeFunction(name: "checkFileName") != nil)
  }
}

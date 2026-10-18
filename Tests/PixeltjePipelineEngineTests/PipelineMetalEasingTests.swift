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

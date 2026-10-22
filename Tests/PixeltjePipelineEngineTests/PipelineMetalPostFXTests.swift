import Foundation
import Metal
@testable import PixeltjePipelineEngine
import Testing

@Test func postFXLibraryBlursDefocusedLightAndPassesThroughWhenOff() throws {
  let source = """
    // pixeltje:3d-v1
    // pixeltje:postfx-v1
    #include <metal_stdlib>
    // Normalized coordinates of a texel centre in the 33 x 33 textures.
    float2 uv(float x, float y) { return (float2(x, y) + 0.5f) / 33.0f; }
    kernel void sampleEffects(metal::texture2d<float> checker [[texture(0)]],
                              metal::texture2d<float> spot [[texture(1)]],
                              device float *results [[buffer(0)]],
                              uint index [[thread_position_in_grid]]) {
      if (index != 0u) return;
      float2 resolution = float2(33.0f);
      // The checker lies on the focus plane at depth 10.
      float4 sharp = pixeltje_postfx::bokeh(checker, uv(5, 5), resolution,
        10.0f, 4.0f, 8.0f);
      results[0] = sharp.r - checker.read(uint2(5, 5)).r;
      results[1] = sharp.a;
      // The spot sits at depth 100 behind a focus distance of 1: about a
      // six-pixel blur.
      results[2] = pixeltje_postfx::bokeh(spot, uv(16, 16), resolution,
        1.0f, 6.0f, 8.0f).r;
      results[3] = pixeltje_postfx::bokeh(spot, uv(19, 16), resolution,
        1.0f, 6.0f, 8.0f).r;
      results[4] = pixeltje_postfx::bokeh(spot, uv(28, 16), resolution,
        1.0f, 6.0f, 8.0f).r;
      results[5] = pixeltje_postfx::bokeh(spot, uv(16, 16), resolution,
        1.0f, 0.0f, 8.0f).r;
      float2 across = float2(1.0f / 33.0f, 0.0f);
      results[6] = pixeltje_postfx::bloomBlur(spot, uv(16, 16), across, 0.75f).r;
      results[7] = pixeltje_postfx::bloomBlur(spot, uv(16, 16), across, 200.0f).r;
      results[8] = pixeltje_postfx::bloomBlur(spot, uv(16, 25), across, 0.0f).r;
      results[9] = pixeltje_postfx::chromaticAberration(spot, uv(16, 16), 0.0f).r;
      // At amount 1 blue samples the image centre, red the far edge.
      float3 fringe = pixeltje_postfx::chromaticAberration(spot, uv(20, 16), 1.0f);
      results[10] = fringe.b;
      results[11] = fringe.r;
      results[12] = pixeltje_3d::forward(0.0f, 0.0f).z;
      // Focused at 1000, the same lens leaves the spot at 100 nearly sharp:
      // blur follows inverse distance, so far focus keeps the distance clear.
      results[13] = pixeltje_postfx::bokeh(spot, uv(16, 16), resolution,
        1000.0f, 6.0f, 8.0f).r;
      results[14] = pixeltje_postfx::bokeh(spot, uv(19, 16), resolution,
        1000.0f, 6.0f, 8.0f).r;
      // Focus distance 0 is treated as very close rather than dividing by 0.
      results[15] = pixeltje_postfx::bokeh(spot, uv(16, 16), resolution,
        0.0f, 6.0f, 8.0f).r;
    }
    """
  let resolved = PipelineMetalLibraries.resolving(source)
  #expect(resolved.contains("namespace pixeltje_3d"))
  #expect(resolved.contains("namespace pixeltje_postfx"))
  #expect(!resolved.contains("namespace pixeltje_terrain"))
  let device = try #require(MTLCreateSystemDefaultDevice())
  let library = try device.makeLibrary(source: resolved, options: nil)
  let function = try #require(library.makeFunction(name: "sampleEffects"))
  let pipeline = try device.makeComputePipelineState(function: function)

  // A 0/1 checker at depth 10, and a 3 x 3 spot of light 100 at depth 100.
  func texture(_ pixel: (Int, Int) -> SIMD4<Float16>) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float, width: 33, height: 33, mipmapped: false)
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var rgba: [SIMD4<Float16>] = []
    for y in 0..<33 { for x in 0..<33 { rgba.append(pixel(x, y)) } }
    texture.replace(region: MTLRegionMake2D(0, 0, 33, 33), mipmapLevel: 0,
      withBytes: rgba, bytesPerRow: 33 * MemoryLayout<SIMD4<Float16>>.stride)
    return texture
  }
  let checker = try texture { x, y in
    let value: Float16 = (x + y) % 2 == 0 ? 1 : 0
    return SIMD4(value, value, value, 10)
  }
  let spot = try texture { x, y in
    let value: Float16 = abs(x - 16) <= 1 && abs(y - 16) <= 1 ? 100 : 0
    return SIMD4(value, value, value, 100)
  }

  let queue = try #require(device.makeCommandQueue())
  let buffer = try #require(device.makeBuffer(length: 16 * MemoryLayout<Float>.stride,
    options: .storageModeShared))
  let commands = try #require(queue.makeCommandBuffer())
  let encoder = try #require(commands.makeComputeCommandEncoder())
  encoder.setComputePipelineState(pipeline)
  encoder.setTexture(checker, index: 0)
  encoder.setTexture(spot, index: 1)
  encoder.setBuffer(buffer, offset: 0, index: 0)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding()
  commands.commit()
  commands.waitUntilCompleted()
  let results = Array(UnsafeBufferPointer(
    start: buffer.contents().assumingMemoryBound(to: Float.self), count: 16))

  // In focus, every tap is rejected and depth passes through.
  #expect(abs(results[0]) < 0.001)
  #expect(results[1] == 10)
  // Out of focus, the spot spreads into a disc that ends within the radius.
  #expect(results[2] > 0 && results[2] < 50)
  #expect(results[3] > 1)
  #expect(results[4] == 0)
  #expect(results[5] == 100)
  #expect(results[6] > 10)
  #expect(results[7] == 0)
  #expect(results[8] == 0)
  #expect(results[9] == 100)
  #expect(results[10] > 99)
  #expect(results[11] == 0)
  #expect(results[12] == -1)
  #expect(results[13] > 99)
  #expect(results[14] == 0)
  #expect(results[15] > 0 && results[15] < 50)
}

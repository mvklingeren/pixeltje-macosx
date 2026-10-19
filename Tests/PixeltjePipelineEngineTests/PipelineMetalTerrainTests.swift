import Foundation
import Metal
@testable import PixeltjePipelineEngine
import Testing

@Test func terrainLibraryTracesShadesAndStacksWithOtherLibraries() throws {
  let source = """
    // pixeltje:3d-v1
    // pixeltje:terrain-v1
    #include <metal_stdlib>
    struct Plain {
      float operator()(float2 p) const { return 2.0f; }
    };
    // A wall of terrain beyond z = 10 shadows everything before it.
    struct Ridge {
      float operator()(float2 p) const { return p.y > 10.0f ? 50.0f : 0.0f; }
    };
    kernel void sampleTerrain(device float *results [[buffer(0)]],
                              uint index [[thread_position_in_grid]]) {
      if (index != 0u) return;
      float3 down = metal::normalize(float3(0.0f, -1.0f, 1.0f));
      results[0] = pixeltje_terrain::trace(Plain{}, float3(0.0f, 10.0f, 0.0f),
        down, 0.0f, 100.0f, 2.0f, 128);
      results[1] = pixeltje_terrain::trace(Plain{}, float3(0.0f, 10.0f, 0.0f),
        -down, 0.0f, 100.0f, 2.0f, 128);
      results[2] = pixeltje_terrain::normal(Plain{}, float2(3.0f), 0.1f).y;
      float3 sun = metal::normalize(float3(0.0f, 0.3f, 1.0f));
      results[3] = pixeltje_terrain::softShadow(Plain{},
        float3(0.0f, 2.05f, 0.0f), sun, 0.1f, 200.0f, 2.0f, 8.0f, 48);
      results[4] = pixeltje_terrain::softShadow(Ridge{},
        float3(0.0f, 0.05f, 0.0f), sun, 0.1f, 200.0f, 50.0f, 8.0f, 48);
      // Every 40-unit cell holds a crater and a rock; sample 2 x 2 cells
      // densely. Rocks never dip below the ground or reach a cell edge.
      float lowest = 0.0f, highest = 0.0f, noise = 0.0f;
      float rockLow = 0.0f, rockHigh = 0.0f, rockEdge = 0.0f;
      for (int i = 0; i < 32; ++i) {
        for (int j = 0; j < 32; ++j) {
          float2 p = float2(float(i), float(j)) * 2.5f;
          float h = pixeltje_terrain::craters(p, 40.0f, 1.0f, 5.0f);
          lowest = metal::min(lowest, h);
          highest = metal::max(highest, h);
          noise = metal::max(noise,
            metal::abs(pixeltje_terrain::fbm(p * 0.3f, 6, 1.0f)));
          float rock = pixeltje_terrain::rocks(p, 40.0f, 1.0f, 9.0f);
          rockLow = metal::min(rockLow, rock);
          rockHigh = metal::max(rockHigh, rock);
          if (i % 16 == 0 || j % 16 == 0) rockEdge = metal::max(rockEdge, rock);
        }
      }
      results[5] = lowest;
      results[6] = highest;
      results[7] = noise;
      results[8] = pixeltje_3d::forward(0.0f, 0.0f).z;
      results[9] = rockLow;
      results[10] = rockHigh;
      results[11] = rockEdge;
    }
    """
  let resolved = PipelineMetalLibraries.resolving(source)
  #expect(resolved.contains("namespace pixeltje_3d"))
  #expect(resolved.contains("namespace pixeltje_terrain"))
  #expect(!resolved.contains("namespace pixeltje_easing"))
  let device = try #require(MTLCreateSystemDefaultDevice())
  let library = try device.makeLibrary(source: resolved, options: nil)
  let function = try #require(library.makeFunction(name: "sampleTerrain"))
  let pipeline = try device.makeComputePipelineState(function: function)
  let queue = try #require(device.makeCommandQueue())
  let buffer = try #require(device.makeBuffer(length: 12 * MemoryLayout<Float>.stride,
    options: .storageModeShared))
  let commands = try #require(queue.makeCommandBuffer())
  let encoder = try #require(commands.makeComputeCommandEncoder())
  encoder.setComputePipelineState(pipeline)
  encoder.setBuffer(buffer, offset: 0, index: 0)
  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
  encoder.endEncoding()
  commands.commit()
  commands.waitUntilCompleted()
  let results = Array(UnsafeBufferPointer(
    start: buffer.contents().assumingMemoryBound(to: Float.self), count: 12))

  #expect(abs(results[0] - 8 * Float(2).squareRoot()) < 0.05)
  #expect(results[1] == -1)
  #expect(abs(results[2] - 1) < 0.0001)
  #expect(results[3] > 0.99)
  #expect(results[4] < 0.01)
  // Radii span 0.12 to 0.23 of a 40-unit cell; bowls dip 0.35 of a radius
  // and rims rise 0.08 of one.
  #expect(results[5] < -1 && results[5] >= -0.35 * 0.23 * 40 - 0.01)
  #expect(results[6] > 0 && results[6] <= 0.08 * 0.23 * 40 + 0.01)
  #expect(results[7] > 0.1 && results[7] < 1)
  #expect(results[8] == -1)
  // Rocks rise at most 0.5 of a 0.25-cell radius and stay off cell edges.
  #expect(results[9] == 0)
  #expect(results[10] > 0.5 && results[10] <= 0.5 * 0.25 * 40 + 0.01)
  #expect(results[11] == 0)
}

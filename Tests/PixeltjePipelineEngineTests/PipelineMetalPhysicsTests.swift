import Foundation
import Metal
@testable import PixeltjePipelineEngine
import Testing

@Test func physicsLibraryIntegratesAndResolvesStaticContacts() throws {
  let source = """
    // pixeltje:3d-v1
    // pixeltje:physics-v1
    #include <metal_stdlib>
    kernel void samplePhysics(device float *results [[buffer(0)]],
                              uint index [[thread_position_in_grid]]) {
      if (index != 0u) return;
      pixeltje_physics::Body body = {
        float3(0.0f, 2.0f, 0.0f), float3(2.0f, 0.0f, 0.0f)};
      body = pixeltje_physics::integrate(body,
        float3(0.0f, -8.0f, 0.0f), 0.0f, 0.5f);
      results[0] = body.position.x;
      results[1] = body.position.y;
      results[2] = body.velocity.y;
      auto plane = pixeltje_physics::spherePlane(float3(0.0f, 0.2f, 0.0f),
        0.5f, float3(0.0f), float3(0.0f, 1.0f, 0.0f));
      results[3] = plane.depth;
      auto pair = pixeltje_physics::sphereSphere(float3(0.0f), 0.5f,
        float3(0.0f), 0.25f);
      results[4] = pair.depth;
      results[5] = pair.normal.x;
      auto outside = pixeltje_physics::sphereBox(
        float3(1.3f, 0.5f, 0.5f), 0.5f,
        float3(0.0f), float3(1.0f));
      results[6] = outside.depth;
      results[7] = outside.normal.x;
      auto inside = pixeltje_physics::sphereBox(
        float3(0.2f, 0.5f, 0.5f), 0.5f,
        float3(0.0f), float3(1.0f));
      results[8] = inside.depth;
      results[9] = inside.normal.x;
      pixeltje_physics::Body impact = {
        float3(0.0f, 0.2f, 0.0f), float3(2.0f, -4.0f, 0.0f)};
      impact = pixeltje_physics::resolve(impact, plane, 0.5f, 0.25f);
      results[10] = impact.position.y;
      results[11] = impact.velocity.x;
      results[12] = impact.velocity.y;
      results[13] = pixeltje_3d::forward(0.0f, 0.0f).z;
    }
    """
  let resolved = PipelineMetalLibraries.resolving(source)
  #expect(resolved.contains("namespace pixeltje_physics"))
  #expect(resolved.contains("namespace pixeltje_3d"))
  let device = try #require(MTLCreateSystemDefaultDevice())
  let library = try device.makeLibrary(source: resolved, options: nil)
  let function = try #require(library.makeFunction(name: "samplePhysics"))
  let pipeline = try device.makeComputePipelineState(function: function)
  let queue = try #require(device.makeCommandQueue())
  let buffer = try #require(device.makeBuffer(length: 14 * MemoryLayout<Float>.stride,
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
    start: buffer.contents().assumingMemoryBound(to: Float.self), count: 14))
  #expect(abs(results[0] - 1.0) < 0.0001)
  #expect(abs(results[1] - 0.0) < 0.0001)
  #expect(abs(results[2] + 4.0) < 0.0001)
  #expect(abs(results[3] - 0.3) < 0.0001)
  #expect(abs(results[4] - 0.75) < 0.0001)
  #expect(results[5] == 1.0)
  #expect(abs(results[6] - 0.2) < 0.0001)
  #expect(results[7] == 1.0)
  #expect(abs(results[8] - 0.7) < 0.0001)
  #expect(results[9] == -1.0)
  #expect(abs(results[10] - 0.5) < 0.0001)
  #expect(abs(results[11] - 0.5) < 0.0001)
  #expect(abs(results[12] - 2.0) < 0.0001)
  #expect(results[13] == -1.0)
}

@Test func physicsWorldResolvesOffCentreRigidBodyImpact() throws {
  let source = """
    // pixeltje:physics-v1
    #include <metal_stdlib>
    kernel void sampleWorld(device float *results [[buffer(0)]],
                            uint index [[thread_position_in_grid]]) {
      if (index != 0u) return;
      pixeltje_physics::World<2> world;
      world.bodies[0] = pixeltje_physics::makeRigidBody(
        float3(-0.35f, 0.5f, 0.0f), float3(0.5f),
        float4(0.0f, 0.0f, 0.0f, 1.0f),
        float3(2.0f, 0.0f, 0.0f), 1.0f, 0.2f, 0.7f);
      world.bodies[1] = pixeltje_physics::makeRigidBody(
        float3(0.4f, 0.0f, 0.0f), float3(0.5f),
        float4(0.0f, 0.0f, 0.0f, 1.0f),
        float3(0.0f), 0.0f, 0.1f, 0.7f);
      auto contact = pixeltje_physics::boxBox(
        world.bodies[0], world.bodies[1]);
      results[0] = contact.depth;
      results[1] = contact.normal.x;
      pixeltje_physics::solve(world.bodies[0], world.bodies[1], contact);
      results[2] = world.bodies[0].linearBounce.x;
      results[3] = world.bodies[0].angularFriction.z;
      results[4] = world.bodies[1].centreMass.x;
      pixeltje_physics::integrateRigid(world.bodies[0], float3(0.0f),
        0.0f, 0.0f, 0.1f);
      results[5] = world.bodies[0].orientation.z;
      auto separated = pixeltje_physics::boxBox(world.bodies[0],
        pixeltje_physics::makeRigidBody(float3(5.0f), float3(0.5f),
          float4(0.0f, 0.0f, 0.0f, 1.0f), float3(0.0f),
          0.0f, 0.1f, 0.7f));
      results[6] = separated.depth;
      auto pairA = pixeltje_physics::makeRigidBody(
        float3(-0.35f, 0.2f, 0.0f), float3(0.5f),
        float4(0.0f, 0.0f, 0.0f, 1.0f),
        float3(2.0f, 0.0f, 0.0f), 1.0f, 0.2f, 0.7f);
      auto pairB = pixeltje_physics::makeRigidBody(
        float3(0.4f, 0.0f, 0.0f), float3(0.5f),
        float4(0.0f, 0.0f, 0.0f, 1.0f),
        float3(-1.0f, 0.0f, 0.0f), 1.0f, 0.2f, 0.7f);
      pixeltje_physics::solve(pairA, pairB,
        pixeltje_physics::boxBox(pairA, pairB));
      results[7] = pairA.linearBounce.x;
      results[8] = pairB.linearBounce.x;
      auto shard = pixeltje_physics::makeRigidBody(
        float3(0.95f, 0.0f, 0.0f), float3(0.1f),
        float4(0.0f, 0.0f, 0.0f, 1.0f),
        float3(2.0f, 0.0f, 0.0f), 1.0f, 0.1f, 0.7f);
      auto wall = pixeltje_physics::makeRigidBody(
        float3(3.0f, 0.0f, 0.0f), float3(2.0f),
        float4(0.0f, 0.0f, 0.0f, 1.0f),
        float3(0.0f), 0.0f, 0.1f, 0.7f);
      auto shardContact = pixeltje_physics::boxBox(shard, wall);
      results[9] = shardContact.depth;
      results[10] = shardContact.point.x - shard.centreMass.x;
    }
    """
  let resolved = PipelineMetalLibraries.resolving(source)
  let device = try #require(MTLCreateSystemDefaultDevice())
  let library = try device.makeLibrary(source: resolved, options: nil)
  let function = try #require(library.makeFunction(name: "sampleWorld"))
  let pipeline = try device.makeComputePipelineState(function: function)
  let queue = try #require(device.makeCommandQueue())
  let buffer = try #require(device.makeBuffer(length: 11 * MemoryLayout<Float>.stride,
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
  let result = Array(UnsafeBufferPointer(
    start: buffer.contents().assumingMemoryBound(to: Float.self), count: 11))
  #expect(result[0] > 0.2 && result[0] < 0.3)
  #expect(result[1] == -1.0)
  #expect(result[2] < 2.0)
  #expect(abs(result[3]) > 0.01)
  #expect(result[4] == 0.4)
  #expect(abs(result[5]) > 0.001)
  #expect(result[6] == 0.0)
  #expect(result[7] < 2.0)
  #expect(result[8] > -1.0)
  #expect(result[9] > 0.0)
  #expect(abs(result[10]) <= 0.1001)
}

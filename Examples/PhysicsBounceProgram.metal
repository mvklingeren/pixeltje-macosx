// pixeltje:physics-v1
#include <metal_stdlib>
using namespace metal;

// A small GPU Program example: one dynamic sphere and two static colliders.
// The library owns no state; this program chooses the step and the scene.
struct ProgramUniforms {
    float4 resolutionTime;
    uint4 frameSeed;
    float4 parameters0;
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;
    float4 movement;
};

struct GameState {
    float4 positionRadius;
    float4 velocity;
};

constant float ballRadius = 0.23f;
constant float3 boxLower = float3(0.8f, 0.0f, -0.3f);
constant float3 boxUpper = float3(1.35f, 0.7f, 0.3f);

kernel void initializePhysics(device GameState *states [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    states[0].positionRadius = float4(-1.7f, 2.4f, 0.0f, ballRadius);
    states[0].velocity = float4(1.6f, 0.0f, 0.0f, 0.0f);
}

kernel void advancePhysics(constant ProgramUniforms &u [[buffer(0)]],
                           device GameState *states [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    pixeltje_physics::Body ball = {
        states[0].positionRadius.xyz, states[0].velocity.xyz};
    float dt = clamp(u.resolutionTime.w, 0.0f, 1.0f / 30.0f);
    ball = pixeltje_physics::integrate(ball, float3(0.0f, -8.0f, 0.0f),
                                       0.0f, dt);
    ball = pixeltje_physics::resolve(ball,
        pixeltje_physics::sphereBox(ball.position, ballRadius,
                                     boxLower, boxUpper), 0.75f, 0.04f);
    ball = pixeltje_physics::resolve(ball,
        pixeltje_physics::spherePlane(ball.position, ballRadius,
            float3(0.0f), float3(0.0f, 1.0f, 0.0f)),
        0.75f, 0.04f);
    states[0].positionRadius.xyz = ball.position;
    states[0].velocity.xyz = ball.velocity;
}

vertex float4 fullscreenVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
}

fragment float4 physicsFragment(float4 pixel [[position]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]]) {
    float2 resolution = u.resolutionTime.xy;
    float2 world = float2((pixel.x / resolution.x - 0.5f) * 5.4f,
        (1.0f - pixel.y / resolution.y) * 3.4f - 0.4f);
    float3 color = mix(float3(0.055f, 0.09f, 0.16f),
        float3(0.18f, 0.28f, 0.4f), clamp(world.y / 3.0f, 0.0f, 1.0f));
    float floorLine = 1.0f - smoothstep(-0.01f, 0.01f, world.y);
    color = mix(color, float3(0.2f, 0.27f, 0.32f), floorLine);
    float3 centre = states[0].positionRadius.xyz;
    float shadow = exp(-pow((world.x - centre.x) / 0.5f, 2.0f) * 2.0f)
        * (1.0f - smoothstep(0.0f, 0.05f, abs(world.y)))
        * (0.32f / (1.0f + centre.y));
    color *= 1.0f - shadow;
    float2 boxCentre = (boxLower.xy + boxUpper.xy) * 0.5f;
    float2 boxHalf = (boxUpper.xy - boxLower.xy) * 0.5f;
    float2 boxDelta = abs(world - boxCentre) - boxHalf;
    float boxDistance = length(max(boxDelta, float2(0.0f)))
        + min(max(boxDelta.x, boxDelta.y), 0.0f);
    float boxMask = 1.0f - smoothstep(0.0f, 0.012f, boxDistance);
    color = mix(color, float3(0.52f, 0.34f, 0.18f), boxMask);
    float2 offset = world - centre.xy;
    float radius = states[0].positionRadius.w;
    float sphereMask = 1.0f - smoothstep(radius - 0.012f,
                                          radius + 0.012f, length(offset));
    float light = clamp(0.68f - 0.42f * offset.x / radius
        + 0.35f * offset.y / radius, 0.25f, 1.25f);
    color = mix(color, float3(0.9f, 0.3f, 0.13f) * light, sphereMask);
    return float4(color, 1.0f);
}

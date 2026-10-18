#include <metal_stdlib>
using namespace metal;

// A second, independent GPU Program scene for the Signal Range workflow.
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

struct TriangleState {
    float elapsed;
    float lastAction;
    float2 reserved;
};

kernel void initializeTriangle(constant ProgramUniforms &u [[buffer(0)]],
    device TriangleState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id == 0u) states[0] = {0.0f, u.pointer.z, float2(0.0f)};
}

kernel void advanceTriangle(constant ProgramUniforms &u [[buffer(0)]],
    device TriangleState *states [[buffer(1)]],
    device uint *sceneRequest [[buffer(2)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    states[0].elapsed += clamp(u.pointer.w > 0.0f
        ? u.pointer.w : u.resolutionTime.w, 0.0f, 0.1f);
    if (u.pointer.z > states[0].lastAction) sceneRequest[0] = 0u;
    states[0].lastAction = u.pointer.z;
}

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1u) & 2u, vertexID & 2u);
    return {float4(p * 2.0f - 1.0f, 0.0f, 1.0f),
        float2(p.x, 1.0f - p.y)};
}

float cross2(float2 a, float2 b) {
    return a.x * b.y - a.y * b.x;
}

fragment float4 triangleFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const TriangleState *states [[buffer(1)]]) {
    float angle = states[0].elapsed * 1.6f;
    float sine = sin(angle), cosine = cos(angle);
    float2 p = (in.uv - 0.5f)
        * float2(u.resolutionTime.x / u.resolutionTime.y, 1.0f);
    float2 q = float2(cosine * p.x + sine * p.y,
        -sine * p.x + cosine * p.y);
    float2 a = float2(0.0f, -0.34f);
    float2 b = float2(0.37f, 0.28f);
    float2 c = float2(-0.37f, 0.28f);
    float edge = min(cross2(b - a, q - a) / length(b - a),
        min(cross2(c - b, q - b) / length(c - b),
            cross2(a - c, q - c) / length(a - c)));
    float antialias = 1.5f / u.resolutionTime.y;
    float coverage = smoothstep(-antialias, antialias, edge);
    float glow = exp(-max(-edge, 0.0f) * 22.0f) * 0.075f;
    float3 background = float3(0.015f, 0.025f, 0.055f)
        + glow * float3(0.18f, 0.42f, 0.80f);
    float3 face = mix(float3(0.07f, 0.55f, 0.95f),
        float3(0.93f, 0.31f, 0.65f),
        clamp((q.y + 0.34f) / 0.62f, 0.0f, 1.0f));
    float rim = 1.0f - smoothstep(0.0f, 0.018f, edge);
    face += rim * float3(0.45f, 0.55f, 0.65f);
    return float4(mix(background, face, coverage), 1.0f);
}

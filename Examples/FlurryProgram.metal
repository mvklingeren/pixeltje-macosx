#include <metal_stdlib>
using namespace metal;

// An independently authored Metal reconstruction of the particle and feedback
// approach in Calum Robinson's Flurry (https://github.com/calumr/flurry).
// The original Flurry source is BSD licensed; see the upstream repository.

struct ProgramUniforms {
    float4 resolutionTime; // width, height, time, fixed step
    uint4 frameSeed;       // frame, seed low, seed high, reserved
    float4 parameters0;   // trail persistence, brightness, incohesion, spread
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
};

struct Puff {
    float4 positionAge;       // XYZ, age; negative age is inactive
    float4 previousRadius;    // previous XYZ, random radius multiplier
    float4 velocityStream;    // XYZ, stream index
    float4 tint;              // linear RGB, opacity variation
};

struct RasterVertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float texturePhase;
};

uint flurryHash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

float random01(uint value) {
    return float(flurryHash(value) & 0x00ffffffu) * (1.0f / 16777216.0f);
}

float3 rotateXYZ(float3 p, float angle) {
    float c = cos(angle), s = sin(angle);
    float3 x = float3(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
    float3 y = float3(x.x * c - x.z * s, x.y, x.z * c + x.x * s);
    return float3(y.x, y.y * c - y.z * s, y.z * c + y.y * s);
}

float3 starPosition(float t) {
    // The emitter and field follow related slow, phase-shifted 3D curves.
    float a = t * (2.0f * M_PI_F * 12.0f / 16384.0f);
    float envelope = 0.75f + (cos(7.0f*a) + cos(3.0f*a)
        + cos(13.0f*a)) / 6.0f;
    float3 p = float3(250.0f * envelope * cos(11.0f * 3.0f*a),
                      250.0f * envelope * sin(12.0f * 4.0f*a),
                      250.0f * cos(23.0f * 12.0f*a));
    p = rotateXYZ(p, a * 0.501f);
    p.xy = float2(p.x * cos(a * 2.501f) - p.y * sin(a * 2.501f),
                  p.y * cos(a * 2.501f) + p.x * sin(a * 2.501f));
    p.z += 2000.0f;
    return p;
}

float3 sparkPosition(float t, uint stream, float spread) {
    float phase = 2.0f * M_PI_F * float(stream + 1u) / 13.0f;
    float a = t * (2.0f * M_PI_F * 12.0f / 16384.0f);
    float envelope = 2.0f + (cos(7.0f*a) + cos(3.0f*a)
        + cos(13.0f*a)) / 6.0f;
    float3 p = float3(1000.0f * envelope * cos(11.0f * (phase + 3.0f*a)),
                      1000.0f * envelope * sin(12.0f * (phase + 4.0f*a)),
                      1000.0f * cos(23.0f * (phase + 12.0f*a)));
    p = rotateXYZ(p * spread, a * 0.501f
        + 5.01f * float(stream + 1u) / 13.0f);
    float turn = a * 2.501f + 85.01f * float(stream + 1u) / 13.0f;
    p.xy = float2(p.x * cos(turn) - p.y * sin(turn),
                  p.y * cos(turn) + p.x * sin(turn));
    p.z += 2000.0f;
    return p;
}

float3 streamColor(float t, uint stream) {
    // A shared tiedye cycle keeps the streams in one color family.
    float cycle = t * (2.0f * M_PI_F / 4.5f);
    float phase = 2.0f * M_PI_F * float(stream + 1u) / 13.0f;
    float3 base = 0.109375f * (1.0f + cos(cycle + float3(
        0.0f, 2.0943951f, 4.1887902f)));
    float3 variation = 0.0625f * float3(
        0.5f + cos(15.0f * (phase + 3.0f*t*0.0046f))
            + sin(7.0f * (phase + t*0.0046f)),
        0.5f + sin(phase + t*0.0046f),
        0.5f + cos(37.0f * (phase + t*0.0046f)));
    return max(float3(0.0f), base + variation);
}

float2 project(float3 p, float2 resolution) {
    float depth = max(25.0f, p.z);
    return float2(0.5f * resolution.x + p.x * resolution.x / depth,
                  0.5f * resolution.y - p.y * resolution.x / depth);
}

kernel void initializeSmoke(device Puff *puffs [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id >= 3600u) return;
    puffs[id].positionAge = float4(0.0f, 0.0f, 0.0f, -1.0f);
    puffs[id].previousRadius = float4(0.0f);
    puffs[id].velocityStream = float4(0.0f);
    puffs[id].tint = float4(0.0f);
}

kernel void advanceSmoke(constant ProgramUniforms &u [[buffer(0)]],
    device Puff *puffs [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id >= 3600u) return;
    float t = u.resolutionTime.z;
    float dt = u.resolutionTime.w;
    uint stream = id % 5u;
    uint emission = (id + 3600u - (u.frameSeed.x * 10u) % 3600u) % 3600u;
    bool isNew = emission < 10u;
    uint randomSeed = id ^ u.frameSeed.y ^ (u.frameSeed.z * 2654435761u);
    float spread = max(0.2f, u.parameters0.w);
    if (isNew) {
        // Two emissions per stream per 60 Hz tick approximate the original
        // 121 Hz release rate while preserving a deterministic frame step.
        float birthTime = max(0.0f, t - (emission < 5u ? 0.5f*dt : 0.0f));
        float3 star = starPosition(birthTime);
        float3 oldStar = starPosition(max(0.0f, birthTime - dt));
        float3 spark = sparkPosition(birthTime, stream, spread);
        float3 direction = normalize(spark - star + float3(0.001f));
        float jitter = random01(randomSeed + u.frameSeed.x * 17u) * 2.0f - 1.0f;
        float coherence = max(0.0f, 1.0f + 0.25f * jitter
            * max(0.0f, u.parameters0.z));
        float3 velocity = (oldStar - star) * 5.0f
            + direction * (450.0f * coherence);
        puffs[id].positionAge = float4(star, 0.0f);
        puffs[id].previousRadius = float4(star, 0.9f + 0.2f * random01(randomSeed + 37u));
        puffs[id].velocityStream = float4(velocity, float(stream));
        puffs[id].tint = float4(streamColor(t, stream),
            0.78f + 0.14f * random01(randomSeed + 91u));
        return;
    }
    Puff p = puffs[id];
    if (p.positionAge.w < 0.0f) return;
    if (p.positionAge.w > 2.5f) {
        p.positionAge.w = -1.0f;
        puffs[id] = p;
        return;
    }
    float3 position = p.positionAge.xyz;
    float3 velocity = p.velocityStream.xyz;
    for (uint spark = 0u; spark < 5u; ++spark) {
        float3 displacement = sparkPosition(t, spark, spread) - position;
        float distanceSquared = max(dot(displacement, displacement), 900.0f);
        float invDistance = rsqrt(distanceSquared);
        float bias = spark == stream ? 8.0f : 1.0f;
        velocity += displacement * invDistance
            * (63750000.0f * bias / distanceSquared) * dt;
    }
    velocity *= pow(0.9965f, dt * 85.0f);
    float speed = length(velocity);
    if (speed >= 5000.0f) {
        p.positionAge.w = -1.0f;
        puffs[id] = p;
        return;
    }
    p.previousRadius.xyz = position;
    p.positionAge.xyz = position + velocity * dt;
    p.positionAge.w += dt;
    p.velocityStream.xyz = velocity;
    puffs[id] = p;
}

vertex RasterVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1u) & 2u, vertexID & 2u);
    RasterVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    out.color = float4(1.0f);
    out.texturePhase = 0.0f;
    return out;
}

constexpr sampler linearClamp(address::clamp_to_edge, filter::linear);

fragment float4 fadeFragment(RasterVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    texture2d<float> history [[texture(1)]]) {
    float persistence = clamp(u.parameters0.x, 0.0f, 0.999f);
    return history.sample(linearClamp, in.uv) * persistence;
}

vertex RasterVertex smokeVertex(uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]], constant ProgramUniforms &u [[buffer(0)]],
    device const Puff *puffs [[buffer(1)]]) {
    Puff p = puffs[instanceID];
    float2 corner[6] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                        float2(1,-1), float2(1,1), float2(-1,1)};
    float2 uv = corner[vertexID];
    float2 resolution = u.resolutionTime.xy;
    float2 current = project(p.positionAge.xyz, resolution);
    float2 previous = project(p.previousRadius.xyz, resolution);
    float2 movement = current - previous;
    float distance = length(movement);
    float2 axis = distance > 0.01f ? movement / distance : float2(1, 0);
    float2 normal = float2(-axis.y, axis.x);
    float age = max(0.0f, p.positionAge.w);
    float radius = (25000.0f + age * 100.0f)
        * (resolution.x / 1024.0f) / max(25.0f, p.positionAge.z);
    radius *= p.previousRadius.w;
    float halfLength = 0.5f * distance + radius;
    float2 center = 0.5f * (current + previous);
    float2 pixel = center + axis * (uv.x * halfLength) + normal * (uv.y * radius);
    RasterVertex out;
    out.position = float4(2.0f * pixel.x / resolution.x - 1.0f,
        1.0f - 2.0f * pixel.y / resolution.y, 0.0f, 1.0f);
    out.uv = uv;
    float life = max(0.0f, 1.375f
        - (25000.0f + age * 100.0f) / (25000.0f + 250.0f));
    bool visible = p.positionAge.w >= 0.0f && p.positionAge.z >= 25.0f
        && p.previousRadius.z >= 25.0f && distance < 120.0f;
    out.color = float4(p.tint.rgb, p.tint.a * life * (visible ? 1.0f : 0.0f));
    out.texturePhase = floor(age * 15.0f + random01(instanceID * 91u) * 64.0f);
    return out;
}

fragment float4 smokeFragment(RasterVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]]) {
    float radial = length(in.uv);
    float soft = radial < 1.0f ? cos(radial * M_PI_F * 0.5f) : 0.0f;
    soft *= soft;
    float2 cells = (in.uv * 0.5f + 0.5f) * 16.0f;
    float2 base = floor(cells);
    float2 blend = smoothstep(0.0f, 1.0f, fract(cells));
    uint phase = uint(in.texturePhase);
    float n00 = random01(uint(base.x) * 317u ^ uint(base.y) * 1867u ^ phase * 43u);
    float n10 = random01(uint(base.x + 1.0f) * 317u ^ uint(base.y) * 1867u ^ phase * 43u);
    float n01 = random01(uint(base.x) * 317u ^ uint(base.y + 1.0f) * 1867u ^ phase * 43u);
    float n11 = random01(uint(base.x + 1.0f) * 317u ^ uint(base.y + 1.0f) * 1867u ^ phase * 43u);
    float speckle = mix(mix(n00, n10, blend.x), mix(n01, n11, blend.x), blend.y);
    float intensity = 0.30f * soft * (0.78f + 0.22f * speckle)
        * in.color.a * max(0.0f, u.parameters0.y);
    return float4(in.color.rgb * intensity, 0.0f);
}

fragment float4 presentFragment(RasterVertex in [[stage_in]],
    texture2d<float> history [[texture(1)]]) {
    float3 linear = max(float3(0.0f), history.sample(linearClamp, in.uv).rgb);
    float3 mapped = 1.0f - exp(-linear * 1.4f);
    float3 srgb = select(1.055f * pow(mapped, float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

#include <metal_stdlib>
using namespace metal;

// A self-contained generative scene for the GPU Program example. Animated
// petal crowns, spiral filaments, and orbiting comets repeat down a tunnel.
// Forward camera travel projects each new crown from the vanishing point.

struct ProgramUniforms {
    float4 resolutionTime; // width, height, time, fixed step
    uint4 frameSeed;       // frame, seed low, seed high, reserved
    float4 parameters0;   // trail, sparkle, orbit speed, nebula
    float4 parameters1;   // travel speed
    float4 parameters2;
    float4 parameters3;
};

struct SceneVertex {
    float4 position [[position]];
    float2 uv;
    float3 color;
    float intensity;
};

constexpr sampler linearClamp(address::clamp_to_edge, filter::linear);

uint bloomHash(uint v) {
    v ^= v >> 16;
    v *= 0x7feb352du;
    v ^= v >> 15;
    v *= 0x846ca68bu;
    return v ^ (v >> 16);
}

float random01(uint v) {
    return float(bloomHash(v) & 0x00ffffffu) / 16777216.0f;
}

float2 rotate2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

float cameraTravel(float time, float speed) {
    // Hold the opening composition briefly, then ease into a steady flight.
    float elapsed = max(0.0f, time - 0.45f);
    return max(0.0f, speed) * 1.25f
        * (elapsed - (1.0f - exp(-2.8f * elapsed)) / 2.8f);
}

float3 orbitColor(uint family) {
    if (family == 0u) return float3(0.10f, 0.93f, 0.87f);
    if (family == 1u) return float3(0.96f, 0.22f, 0.67f);
    return float3(1.00f, 0.65f, 0.22f);
}

float2 orbitPoint(uint slice, float phase) {
    uint family = slice % 3u;
    float radius = family == 0u ? 0.315f : (family == 1u ? 0.405f : 0.515f);
    float tilt = family == 0u ? 0.31f : (family == 1u ? 0.68f : 0.82f);
    float turn = family == 0u ? 0.50f : (family == 1u ? -0.57f : 0.21f);
    float2 ellipse = float2(cos(phase), tilt * sin(phase)) * radius;
    return rotate2(ellipse, turn);
}

vertex SceneVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2((vertexID << 1u) & 2u, vertexID & 2u);
    SceneVertex out;
    out.position = float4(corner * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(corner.x, 1.0f - corner.y);
    out.color = float3(0.0f);
    out.intensity = 0.0f;
    return out;
}

fragment float4 fadeFragment(SceneVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    texture2d<float> history [[texture(1)]]) {
    float2 resolution = u.resolutionTime.xy;
    float2 p = float2((in.uv.x - 0.5f) * resolution.x / resolution.y,
        0.5f - in.uv.y);
    float r = length(p);
    float camera = cameraTravel(u.resolutionTime.z, u.parameters1.x);
    float previousCamera = cameraTravel(max(0.0f,
        u.resolutionTime.z - u.resolutionTime.w), u.parameters1.x);
    float zoom = clamp((camera - previousCamera) * 0.5f, 0.0f, 0.05f);
    float2 source = rotate2(p, -0.006f * (1.0f - smoothstep(0.12f, 0.65f, r)))
        * (1.0f - zoom);
    float2 sourceUV = float2(0.5f + source.x * resolution.y / resolution.x,
        0.5f - source.y);
    return history.sample(linearClamp, sourceUV)
        * clamp(u.parameters0.x, 0.0f, 0.995f);
}

fragment float4 bloomFragment(SceneVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]]) {
    float2 resolution = u.resolutionTime.xy;
    float2 p = float2((in.uv.x - 0.5f) * resolution.x / resolution.y,
        0.5f - in.uv.y);
    float r = length(p);
    if (r > 1.0f) return float4(0.0f);
    float a = atan2(p.y, p.x);
    float t = u.resolutionTime.z;
    float camera = cameraTravel(t, u.parameters1.x);
    float cycle = fract(camera);
    uint firstSlice = uint(floor(camera));
    float breathing = 0.86f + 0.14f * sin(t * 2.2f);
    float3 light = float3(0.0f);

    // Slices are fixed in the world. Their perspective scale grows as the
    // camera approaches; the farthest slice fades in at the vanishing point.
    for (uint layer = 0u; layer < 6u; ++layer) {
        uint slice = firstSlice + layer;
        float depth = (float(layer) + 1.0f - cycle) * 0.8f + 0.25f;
        float projection = 1.05f / depth;
        float localR = r / projection;
        float petals = 8.0f + 2.0f * float(slice % 4u);
        float direction = slice % 2u == 0u ? 1.0f : -1.0f;
        float turn = direction * t * 0.28f + float(slice) * 0.36f;
        float outerEdge = projection * (0.39f + 0.085f
            * cos(petals * (a + 0.50f * localR + turn)));
        float innerEdge = projection * (0.26f + 0.055f
            * cos((petals + 4.0f) * (a - 0.35f * localR - turn * 0.7f)));
        float width = max(1.3f / resolution.y, 0.0032f * projection);
        float outerDistance = (r - outerEdge) / width;
        float innerDistance = (r - innerEdge) / width;
        float outer = exp(-outerDistance * outerDistance);
        float inner = exp(-innerDistance * innerDistance);
        float spiral = 0.5f + 0.5f * cos((18.0f + petals) * a
            + 35.0f * localR - 2.6f * t + float(slice) * 1.3f);
        float filaments = pow(spiral, 18.0f)
            * smoothstep(0.15f, 0.25f, localR)
            * (1.0f - smoothstep(0.46f, 0.56f, localR));
        float interior = (1.0f - smoothstep(outerEdge - 0.025f * projection,
            outerEdge + 0.025f * projection, r))
            * smoothstep(0.13f, 0.22f, localR);
        float arrival = layer == 5u ? smoothstep(0.0f, 0.35f, cycle) : 1.0f;
        float attenuation = arrival
            / (1.0f + 0.23f * max(0.0f, float(layer) - cycle));
        float3 tint = orbitColor(slice % 3u);
        float3 companionTint = orbitColor((slice + 1u) % 3u);
        light += attenuation * (outer * tint * 0.085f
            + inner * companionTint * 0.055f
            + filaments * tint * 0.029f
            + interior * tint * (0.004f + 0.005f * spiral));
    }
    return float4(light * breathing * max(0.0f, u.parameters0.y), 0.0f);
}

vertex SceneVertex orbitVertex(uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]], constant ProgramUniforms &u [[buffer(0)]]) {
    uint family = instanceID % 3u;
    uint particle = instanceID / 3u;
    float camera = cameraTravel(u.resolutionTime.z, u.parameters1.x);
    uint slice = uint(floor(camera)) + family;
    float depth = (float(family) + 1.0f - fract(camera)) * 0.8f + 0.25f;
    float projection = 1.05f / depth;
    float seed = random01(particle * 17u + slice * 4099u + u.frameSeed.y);
    float phase = 2.0f * M_PI_F * (float(particle) + 0.35f * seed) / 1024.0f;
    float motion = u.resolutionTime.z * max(0.0f, u.parameters0.z);
    phase += motion * (0.13f + 0.025f * float(slice % 3u));
    // Bright heads travel much faster than the underlying particle field.
    // A wrapped angle gives each head a short, one-sided comet tail.
    float direction = slice % 3u == 1u ? -1.0f : 1.0f;
    float headPhase = float(slice) * 2.1f
        + direction * motion * (0.95f + 0.12f * float(slice % 3u));
    float separation = atan2(sin(phase - headPhase), cos(phase - headPhase))
        * direction;
    float head = exp(-separation * separation * 125.0f);
    float tail = separation < 0.0f ? exp(separation * 3.8f) : 0.0f;
    float companionSeparation = atan2(sin(phase - headPhase - M_PI_F),
        cos(phase - headPhase - M_PI_F));
    float companion = exp(-companionSeparation * companionSeparation * 95.0f);
    float2 center = orbitPoint(slice, phase) * projection;
    // A slightly wandering second thread gives the rings their woven edge.
    center += 0.0035f * projection * float2(
        sin(phase * 13.0f + float(slice) * 4.0f),
        cos(phase * 11.0f - float(slice) * 2.0f));
    float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                         float2(1,-1), float2(1,1), float2(-1,1)};
    float2 corner = corners[vertexID];
    float size = mix(1.2f, 3.6f, pow(random01(particle * 29u
        + slice * 6991u + 7u), 5.0f));
    size *= (1.0f + 1.8f * head + 0.7f * companion)
        * min(u.resolutionTime.y / 900.0f, 1.8f)
        * clamp(projection, 0.35f, 2.0f);
    float2 clip = float2(center.x * 2.0f * u.resolutionTime.y / u.resolutionTime.x,
        center.y * 2.0f);
    clip += corner * size * 2.0f / u.resolutionTime.xy;
    SceneVertex out;
    out.position = float4(clip, 0.0f, 1.0f);
    out.uv = corner;
    out.color = orbitColor(slice % 3u);
    float shimmer = 0.24f + 0.76f * pow(seed, 4.0f);
    out.intensity = (0.035f + shimmer * (0.75f * tail + 2.4f * head
        + 0.65f * companion)) * max(0.0f, u.parameters0.y)
        / (1.0f + 0.35f * max(0.0f, float(family) - fract(camera)));
    return out;
}

fragment float4 orbitFragment(SceneVertex in [[stage_in]]) {
    float radius = length(in.uv);
    float glow = exp(-4.0f * radius * radius)
        * (1.0f - smoothstep(0.15f, 1.45f, radius));
    return float4(in.color * glow * in.intensity, 0.0f);
}

float starField(float2 pixel, float time, uint seed) {
    float2 cell = floor(pixel / 43.0f);
    uint key = uint(cell.x + 4096.0f) * 73856093u
        ^ uint(cell.y + 4096.0f) * 19349663u ^ seed;
    float chance = random01(key);
    if (chance < 0.79f) return 0.0f;
    float2 center = (cell + float2(random01(key + 1u), random01(key + 2u))) * 43.0f;
    float2 delta = pixel - center;
    float d = length(delta);
    float twinkle = 0.70f + 0.30f * sin(time * (0.6f + chance) + chance * 71.0f);
    float core = exp(-d * d * 0.38f);
    float cross = exp(-abs(delta.x) * 0.55f - abs(delta.y) * 0.055f)
        + exp(-abs(delta.y) * 0.55f - abs(delta.x) * 0.055f);
    return (core + 0.10f * cross) * (0.13f + 0.45f * pow(chance, 5.0f)) * twinkle;
}

fragment float4 presentFragment(SceneVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    texture2d<float> history [[texture(1)]]) {
    float2 resolution = u.resolutionTime.xy;
    float2 p = float2((in.uv.x - 0.5f) * resolution.x / resolution.y,
        0.5f - in.uv.y);
    float r = length(p);
    float time = u.resolutionTime.z;
    float camera = cameraTravel(time, u.parameters1.x);

    float haze = 0.5f + 0.5f * sin(11.0f * p.x + 3.0f * sin(6.0f * p.y + time * 0.08f));
    haze *= 0.5f + 0.5f * sin(8.0f * p.y - 3.0f * p.x + time * 0.035f);
    float cloud = exp(-r * r * 5.0f) * haze * max(0.0f, u.parameters0.w);
    float3 linear = float3(0.003f, 0.007f, 0.023f);
    linear += cloud * float3(0.024f, 0.012f, 0.065f);
    linear += exp(-r * r * 35.0f) * float3(0.025f, 0.015f, 0.055f);
    float star = starField(in.uv * resolution, time, u.frameSeed.y);
    linear += star * float3(0.62f, 0.79f, 1.0f);

    float a = atan2(p.y, p.x);
    float beam = pow(0.5f + 0.5f * cos(32.0f * a
        + 3.0f * sin(6.0f * r - camera * 2.5f)), 24.0f);
    beam *= smoothstep(0.08f, 0.18f, r)
        * (1.0f - smoothstep(0.64f, 0.90f, r))
        * smoothstep(0.0f, 0.35f, camera);
    linear += beam * float3(0.009f, 0.017f, 0.037f);
    linear += max(float3(0.0f), history.sample(linearClamp, in.uv).rgb);

    // A small dark aperture hides the point where new slices appear.
    float disc = 1.0f - smoothstep(0.070f, 0.077f, r);
    float3 planet = float3(0.003f, 0.009f, 0.022f);
    planet += float3(0.020f, 0.060f, 0.091f)
        * smoothstep(-0.10f, 0.11f, p.x + 0.45f * p.y);
    planet += float3(0.009f, 0.016f, 0.035f)
        * (0.5f + 0.5f * sin(90.0f * p.y + 9.0f * sin(23.0f * p.x)));
    linear = mix(linear, planet, disc);
    float rimDistance = (r - 0.078f) * 170.0f;
    float haloDistance = (r - 0.082f) * 42.0f;
    float rim = exp(-rimDistance * rimDistance);
    float halo = exp(-haloDistance * haloDistance);
    linear += (rim * 0.62f + halo * 0.035f)
        * mix(float3(0.08f, 0.75f, 0.95f), float3(1.0f, 0.31f, 0.59f),
            smoothstep(-0.11f, 0.12f, p.x));

    float vignette = 1.0f - 0.55f * smoothstep(0.42f, 0.9f, r);
    linear *= vignette;
    float3 mapped = 1.0f - exp(-linear * 1.7f);
    float3 srgb = select(1.055f * pow(mapped, float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

// Reusable ceiling-mounted fluorescent light box for Signal Range.
// Add placements to ceilingTLBoxes to reuse the same geometry and flicker.

constant uint ceilingTLBoxCount = 1u;

struct CeilingTLBox {
    float3 centre;
    float3 halfSize;
    float3 tint;
    float phase;
};

// The first fixture hangs just below the northern room's ceiling.
constant CeilingTLBox ceilingTLBoxes[ceilingTLBoxCount] = {{
        float3(0.0f, 17.82f, -42.0f),
        float3(2.15f, 0.17f, 0.54f),
        float3(0.57f, 0.82f, 1.0f), 0.17f
    }};

CeilingTLBox ceilingTLBox(uint index) {
    return ceilingTLBoxes[index];
}

float tlBoxFlicker(float time, float phase) {
    float cycle = time * 3.1f + phase;
    float random = hashTile(float2(floor(cycle), phase));
    float dropout = step(0.72f, random)
        * (1.0f - smoothstep(0.02f, 0.22f, fract(cycle)));
    float buzz = 0.92f + 0.08f * sin(time * 74.0f + phase * 11.0f);
    return clamp(buzz * (1.0f - 0.80f * dropout), 0.16f, 1.0f);
}

void traceCeilingTLBox(thread SceneHit &hit, float3 origin,
    float3 direction, CeilingTLBox fixture, uint index) {
    float3 normal;
    float t = rayBox(origin, direction,
        fixture.centre - fixture.halfSize,
        fixture.centre + fixture.halfSize, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 22u, -1, index};

    // Two shallow diffusers hang below the metal housing. Their dimensions
    // follow the fixture so another placement can use the same geometry.
    for (uint tube = 0u; tube < 2u; ++tube) {
        float offset = (tube == 0u ? -0.42f : 0.42f)
            * fixture.halfSize.z;
        float3 centre = fixture.centre
            - float3(0.0f, fixture.halfSize.y + 0.025f, 0.0f)
            + float3(0.0f, 0.0f, offset);
        float3 halfSize = float3(fixture.halfSize.x * 0.84f,
            0.045f, fixture.halfSize.z * 0.17f);
        t = rayBox(origin, direction, centre - halfSize,
            centre + halfSize, normal);
        if (t > 0.0f && t < hit.distance)
            hit = {t, normal, origin + direction * t, 23u, -1, index};
    }
}

SurfaceMaterial tlBoxSurfaceMaterial(uint material,
    CeilingTLBox fixture, float time) {
    if (material == 22u) return {
        float3(0.12f, 0.15f, 0.17f), 0.42f, 0.55f,
        float3(0.0f)};
    float brightness = tlBoxFlicker(time, fixture.phase);
    return {float3(0.58f, 0.67f, 0.70f) * brightness,
        0.24f, 0.0f, fixture.tint * (3.2f * brightness)};
}

// Reusable ceiling lamp armatures for Signal Range: a pendant with an opaque
// dome shade and a flush bulkhead with a frosted glass dome. Add placements
// to ceilingLamps to reuse either type; lamp N is also room light N.

enum class CeilingLampType : uint { pendant, bulkhead };

constant uint ceilingLampCount = 3u;

struct CeilingLamp {
    CeilingLampType type;
    float3 centre;     // pendant bulb, or bulkhead glass dome centre
    float ceilingY;
    float radius;      // shade or glass dome radius
    float3 tint;
    float power;
};

// Two pendants hang over the starting arena; a bulkhead sits behind the start.
constant CeilingLamp ceilingLamps[ceilingLampCount] = {
    {CeilingLampType::pendant, float3(-9.0f, 4.75f, -8.0f), 5.5f, 0.30f,
        float3(1.0f, 0.79f, 0.58f), 420.0f},
    {CeilingLampType::pendant, float3(9.0f, 4.75f, -8.0f), 5.5f, 0.30f,
        float3(0.48f, 0.78f, 1.0f), 390.0f},
    {CeilingLampType::bulkhead, float3(0.0f, 5.44f, 10.0f), 5.5f, 0.24f,
        float3(1.0f, 0.53f, 0.35f), 320.0f}
};

float3 ceilingLampEmitter(CeilingLamp lamp) {
    return lamp.type == CeilingLampType::pendant ? lamp.centre
        : lamp.centre - float3(0.0f, 0.35f * lamp.radius, 0.0f);
}

// Hits the half of a sphere above (side 1) or below (side -1) its equator.
// The far wall answers when the near one is cut away, so an open shade shows
// its inside.
float rayHemisphere(float3 origin, float3 direction, float3 centre,
    float radius, float side, thread float3 &normal) {
    float3 offset = origin - centre;
    float b = dot(offset, direction);
    float discriminant = b * b - dot(offset, offset) + radius * radius;
    if (discriminant < 0.0f) return -1.0f;
    float root = sqrt(discriminant);
    for (uint i = 0u; i < 2u; ++i) {
        float t = i == 0u ? -b - root : -b + root;
        float3 p = origin + direction * t - centre;
        if (t > 0.01f && p.y * side >= 0.0f) {
            normal = (i == 0u ? p : -p) / radius;
            return t;
        }
    }
    return -1.0f;
}

void traceCeilingLamp(thread SceneHit &hit, float3 origin, float3 direction,
    CeilingLamp lamp, uint index) {
    float3 normal;
    float3 c = lamp.centre;
    float r = lamp.radius;
    float t;
    if (lamp.type == CeilingLampType::pendant) {
        // Ceiling cup and stem, then the dome shade around the bulb.
        t = rayBox(origin, direction,
            float3(c.x - 0.4f * r, lamp.ceilingY - 0.06f, c.z - 0.4f * r),
            float3(c.x + 0.4f * r, lamp.ceilingY, c.z + 0.4f * r), normal);
        if (t > 0.0f && t < hit.distance)
            hit = {t, normal, origin + direction * t, 31u, -1, index};
        t = rayBox(origin, direction,
            float3(c.x - 0.02f, c.y + 0.9f * r, c.z - 0.02f),
            float3(c.x + 0.02f, lamp.ceilingY, c.z + 0.02f), normal);
        if (t > 0.0f && t < hit.distance)
            hit = {t, normal, origin + direction * t, 31u, -1, index};
        t = rayHemisphere(origin, direction, c, r, 1.0f, normal);
        if (t > 0.0f && t < hit.distance)
            hit = {t, normal, origin + direction * t,
                normal.y < 0.0f ? 32u : 31u, -1, index};
        t = pixeltje_3d::raySphere(origin, direction, c, 0.24f * r, 0.01f);
        if (t > 0.0f && t < hit.distance)
            hit = {t, normalize(origin + direction * t - c),
                origin + direction * t, 33u, -1, index};
        return;
    }
    // Square back plate on the ceiling with the glass dome hanging below.
    t = rayBox(origin, direction,
        float3(c.x - 1.15f * r, c.y, c.z - 1.15f * r),
        float3(c.x + 1.15f * r, lamp.ceilingY, c.z + 1.15f * r), normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 31u, -1, index};
    t = rayHemisphere(origin, direction, c, r, -1.0f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 33u, -1, index};
}

SurfaceMaterial ceilingLampSurfaceMaterial(uint material, CeilingLamp lamp) {
    if (material == 31u) return {
        float3(0.40f, 0.42f, 0.41f), 0.40f, 0.0f, float3(0.0f)};
    // The shade's white inside glows with its bulb: the shaded point light
    // sends nothing upward to reach it.
    if (material == 32u) return {
        float3(0.80f, 0.80f, 0.78f), 0.50f, 0.0f, lamp.tint * 1.4f};
    return {float3(0.70f, 0.72f, 0.72f), 0.30f, 0.0f, lamp.tint * 3.2f};
}

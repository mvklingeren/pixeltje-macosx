// pixeltje:3d-v1
#include <metal_stdlib>
using namespace metal;

// Minimal first-person GPU Program. The tick owns game state; the fragment
// pass only reads it. The same traceScene function serves sight and shooting.
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
    float4 player; // XYZ position and yaw
    float4 view;   // pitch, last shot action, shot flash, target health
};

struct SceneHit {
    float distance;
    float3 normal;
    uint material; // 1 room, 2 crate, 3 target
};

SceneHit traceScene(float3 origin, float3 direction,
    device const GameState &game);

// The target is a glowing orb and the room's warm light until it is shot.
constant float3 orbCentre = float3(0.0f, 1.35f, -6.5f);
constant float orbRadius = 0.65f;
constant float3 orbRadiance = float3(0.85f, 0.27f, 0.10f) * 5.0f;
constant float3 crateLower = float3(1.5f, 0.0f, -4.9f);
constant float3 crateUpper = float3(3.5f, 2.2f, -2.5f);

kernel void initializeFPS(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    states[0].player = float4(0.0f, 1.6f, 5.0f, 0.0f);
    states[0].view = float4(0.0f, 0.0f, 0.0f, 1.0f);
}

bool walkable(float2 xz) {
    if (any(abs(xz) > float2(11.4f))) return false;
    return xz.x < 1.2f || xz.x > 3.8f
        || xz.y < -5.2f || xz.y > -2.2f;
}

kernel void advanceFPS(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.1f);
    game.player.w = (clamp(u.pointer.x, 0.0f, 1.0f) - 0.5f) * 6.2831853f;
    game.view.x = (0.5f - clamp(u.pointer.y, 0.0f, 1.0f)) * 1.9f;
    game.view.z = max(game.view.z - dt, 0.0f);

    float2 move = clamp(u.movement.xy, float2(-1.0f), float2(1.0f));
    if (length(move) > 1.0f) move = normalize(move);
    float yaw = game.player.w;
    float2 delta = (float2(cos(yaw), sin(yaw)) * move.x
        + float2(sin(yaw), -cos(yaw)) * move.y) * 4.0f * dt;
    float2 position = game.player.xz;
    if (walkable(position + float2(delta.x, 0.0f))) position.x += delta.x;
    if (walkable(position + float2(0.0f, delta.y))) position.y += delta.y;
    game.player.xz = position;

    uint action = uint(u.pointer.z);
    if (action > uint(game.view.y)) {
        float3 direction = pixeltje_3d::forward(yaw, game.view.x);
        SceneHit hit = traceScene(game.player.xyz, direction, game);
        if (hit.material == 3u) game.view.w = 0.0f;
        game.view.z = 0.15f;
    }
    game.view.y = float(action);
}

SceneHit traceScene(float3 origin, float3 direction,
    device const GameState &game) {
    SceneHit hit = {100.0f, float3(0.0f), 0u};
    float3 normal;
    // The player is inside this box. Reverse its outward normal for lighting.
    float t = pixeltje_3d::rayBox(origin, direction,
        float3(-12.0f, 0.0f, -12.0f), float3(12.0f, 5.0f, 12.0f),
        0.01f, normal);
    if (t > 0.0f) hit = {t, -normal, 1u};
    t = pixeltje_3d::rayBox(origin, direction, crateLower, crateUpper,
        0.01f, normal);
    if (t > 0.0f && t < hit.distance) hit = {t, normal, 2u};
    if (game.view.w > 0.0f) {
        t = pixeltje_3d::raySphere(origin, direction, orbCentre, orbRadius,
            0.01f);
        if (t > 0.0f && t < hit.distance) {
            float3 point = origin + direction * t;
            hit = {t, normalize(point - orbCentre), 3u};
        }
    }
    return hit;
}

float crateDistance(float3 p) {
    float3 q = abs(p - (crateLower + crateUpper) * 0.5f)
        - (crateUpper - crateLower) * 0.5f;
    return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f);
}

// Cone-traced soft shadow from the crate, the only possible occluder. The
// penumbra widens with the orb's angular size as seen from the point.
float orbVisibility(float3 point, float3 normal) {
    float3 origin = point + normal * 0.01f;
    float3 toOrb = orbCentre - origin;
    float distance = length(toOrb);
    float3 direction = toOrb / distance;
    float spread = orbRadius / distance;
    float lit = 1.0f;
    float t = 0.02f;
    for (int i = 0; i < 48 && t < distance - orbRadius; i++) {
        float h = crateDistance(origin + direction * t);
        lit = min(lit, h / (spread * t));
        if (lit < -1.0f) break;
        t += clamp(h, 0.01f, 0.5f);
    }
    lit = max(lit, -1.0f);
    return 0.25f * (1.0f + lit) * (1.0f + lit) * (2.0f - lit);
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

fragment float4 fpsFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]]) {
    device const GameState &game = states[0];
    float3 direction = pixeltje_3d::cameraDirection(in.uv,
        u.resolutionTime.xy, game.player.w, game.view.x, 1.1f);
    SceneHit hit = traceScene(game.player.xyz, direction, game);
    float3 point = game.player.xyz + direction * hit.distance;
    float3 base = float3(0.08f, 0.12f, 0.16f);
    if (hit.material == 1u) {
        base = hit.normal.y > 0.5f
            ? mix(float3(0.20f, 0.24f, 0.27f),
                float3(0.13f, 0.16f, 0.18f),
                fmod(floor(point.x) + floor(point.z) + 24.0f, 2.0f))
            : float3(0.22f, 0.29f, 0.34f);
    } else if (hit.material == 2u) {
        base = float3(0.42f, 0.24f, 0.11f);
    } else if (hit.material == 3u) {
        base = float3(0.85f, 0.27f, 0.10f);
    }
    float3 light = normalize(float3(-3.0f, 4.5f, 2.0f) - point);
    float diffuse = max(dot(hit.normal, light), 0.0f);
    // A dim, cool fill keeps the room readable without drowning the orb.
    float3 color = base * float3(0.80f, 0.90f, 1.15f)
        * (0.08f + 0.30f * diffuse);
    float3 emission = game.view.w > 0.0f ? orbRadiance : float3(0.0f);
    if (hit.material == 3u) {
        // Self-lit: the limb darkens and reddens, as it does on a star.
        color = emission * pow(max(dot(hit.normal, -direction), 0.0f),
            float3(0.15f, 0.4f, 0.7f));
    } else if (game.view.w > 0.0f) {
        // A sphere of radiance L lights a Lambert surface by L sin²α cosθ.
        float3 toOrb = orbCentre - point;
        float distance2 = dot(toOrb, toOrb);
        float facing = dot(hit.normal, toOrb) * rsqrt(distance2);
        if (facing > 0.0f) {
            color += base * emission * facing * orbRadius * orbRadius
                / distance2 * orbVisibility(point, hit.normal);
        }
    }
    // Faint haze scatters the orb's light toward the eye. Its 1/d² falloff
    // integrates in closed form along the ray up to the surface it hits.
    float3 offset = orbCentre - game.player.xyz;
    float along = dot(offset, direction);
    float miss = max(length(offset - direction * along), 0.01f);
    color += emission * 0.02f * orbRadius * orbRadius / miss
        * (atan((hit.distance - along) / miss) + atan(along / miss));
    color = pixeltje_3d::filmicToneMap(color * 1.7f);
    float2 pixel = in.uv * u.resolutionTime.xy;
    float2 centre = u.resolutionTime.xy * 0.5f;
    float2 cross = abs(pixel - centre);
    if ((cross.x < 1.3f && cross.y > 3.0f && cross.y < 10.0f)
        || (cross.y < 1.3f && cross.x > 3.0f && cross.x < 10.0f)) {
        float3 mark = game.view.w > 0.0f
            ? float3(0.90f, 1.0f, 0.91f) : float3(0.35f, 1.0f, 0.45f);
        // Darken over the glowing orb so the crosshair stays visible.
        color = dot(color, float3(0.3333f)) > 0.7f ? mark * 0.15f : mark;
    }
    color += game.view.z * float3(1.1f, 0.47f, 0.15f);
    return float4(clamp(pixeltje_3d::linearToSRGB(
        clamp(color, float3(0.0f), float3(1.0f))),
        float3(0.0f), float3(1.0f)), 1.0f);
}

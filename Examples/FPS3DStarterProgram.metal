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
    t = pixeltje_3d::rayBox(origin, direction,
        float3(1.5f, 0.0f, -4.9f), float3(3.5f, 2.2f, -2.5f),
        0.01f, normal);
    if (t > 0.0f && t < hit.distance) hit = {t, normal, 2u};
    if (game.view.w > 0.0f) {
        t = pixeltje_3d::raySphere(origin, direction,
            float3(0.0f, 1.35f, -6.5f), 0.65f, 0.01f);
        if (t > 0.0f && t < hit.distance) {
            float3 point = origin + direction * t;
            hit = {t, normalize(point - float3(0.0f, 1.35f, -6.5f)), 3u};
        }
    }
    return hit;
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
    float3 color = base * (0.26f + 0.95f * diffuse);
    if (hit.material == 3u) {
        color += base * 0.45f
            * pow(1.0f - max(dot(hit.normal, -direction), 0.0f), 3.0f);
    }
    color = pixeltje_3d::filmicToneMap(color * 1.7f);
    float2 pixel = in.uv * u.resolutionTime.xy;
    float2 centre = u.resolutionTime.xy * 0.5f;
    float2 cross = abs(pixel - centre);
    if ((cross.x < 1.3f && cross.y > 3.0f && cross.y < 10.0f)
        || (cross.y < 1.3f && cross.x > 3.0f && cross.x < 10.0f)) {
        color = game.view.w > 0.0f
            ? float3(0.90f, 1.0f, 0.91f) : float3(0.35f, 1.0f, 0.45f);
    }
    color += game.view.z * float3(1.1f, 0.47f, 0.15f);
    return float4(clamp(pixeltje_3d::linearToSRGB(
        clamp(color, float3(0.0f), float3(1.0f))),
        float3(0.0f), float3(1.0f)), 1.0f);
}

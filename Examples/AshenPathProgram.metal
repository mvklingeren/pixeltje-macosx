#include <metal_stdlib>
using namespace metal;

// Stateful isometric game for the generic GPU Program node. Pointer Z carries
// a press count; the game consumes each action once across repeated frames.

constant int mapWidth = 32;
constant int mapCells = mapWidth * mapWidth;
constant uint coinCount = 7u;

struct ProgramUniforms {
    float4 resolutionTime;
    uint4 frameSeed;
    float4 parameters0;
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;
};

struct GameState {
    float4 playerTarget;  // player XY, destination tile XY
    float4 cameraPointer; // camera XY, last Trackpad XY
    float4 enemy;         // creature XY, hit points, hit flash
    float4 combat;        // last action count, swing time, player HP, creature cooldown
    float4 motion;        // walking phase, facing angle, moving, reserved
    uint4 progress;       // collected bits, route length, next route index, game over
    int route[mapCells];
    uint explored[mapCells];
};

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

float fitScale(float2 resolution) {
    return min(resolution.x / 1280.0f, resolution.y / 800.0f);
}

float2 worldToScreen(float2 world, float2 camera, float2 resolution) {
    float scale = fitScale(resolution);
    return resolution * 0.5f
        + float2((world.x - camera.x - world.y + camera.y) * 46.0f,
                 (world.x - camera.x + world.y - camera.y) * 24.0f) * scale;
}

float2 screenToWorld(float2 pixel, float2 camera, float2 resolution) {
    float scale = fitScale(resolution);
    float2 diamond = (pixel - resolution * 0.5f)
        / (float2(46.0f, 24.0f) * scale);
    return camera + float2((diamond.x + diamond.y) * 0.5f,
                           (diamond.y - diamond.x) * 0.5f);
}

bool inMap(int2 tile) {
    return all(tile >= int2(-16)) && all(tile < int2(16));
}

int mapIndex(int2 tile) {
    return (tile.y + 16) * mapWidth + tile.x + 16;
}

int2 tileAt(int index) {
    return int2(index % mapWidth - 16, index / mapWidth - 16);
}

int planeAt(int2 tile) {
    if (abs(tile.x) <= 4 && abs(tile.y) <= 4) return 1;
    if (tile.x >= 8 && tile.x <= 14 && tile.y >= -4 && tile.y <= 3) return 2;
    if (tile.x >= -3 && tile.x <= 4 && tile.y >= -14 && tile.y <= -8) return 3;
    if (tile.x >= -14 && tile.x <= -8 && tile.y >= -2 && tile.y <= 5) return 4;
    if (tile.x >= 5 && tile.x <= 7 && tile.y == 0) return 5;
    if (tile.x == 0 && tile.y >= -7 && tile.y <= -5) return 5;
    if (tile.x >= -7 && tile.x <= -5 && tile.y == 2) return 5;
    return 0;
}

float2 coinPosition(uint index) {
    switch (index) {
        case 0u: return float2(3.0f, 2.0f);
        case 1u: return float2(-3.0f, -2.0f);
        case 2u: return float2(10.0f, -3.0f);
        case 3u: return float2(13.0f, 2.0f);
        case 4u: return float2(-2.0f, -12.0f);
        case 5u: return float2(3.0f, -10.0f);
        default: return float2(-12.0f, 4.0f);
    }
}

float2 torchPosition(uint index) {
    switch (index) {
        case 0u: return float2(-4.0f, -4.0f);
        case 1u: return float2( 4.0f, -4.0f);
        case 2u: return float2(-4.0f,  4.0f);
        default: return float2(4.0f, 4.0f);
    }
}

void revealAround(device GameState &game) {
    int2 center = int2(round(game.playerTarget.xy));
    for (int y = -6; y <= 6; ++y) {
        for (int x = -6; x <= 6; ++x) {
            int2 tile = center + int2(x, y);
            if (inMap(tile) && planeAt(tile) != 0
                && distance(float2(tile), game.playerTarget.xy) <= 5.2f) {
                game.explored[mapIndex(tile)] = 1u;
            }
        }
    }
}

void planRoute(device GameState &game, int2 goal) {
    if (!inMap(goal) || planeAt(goal) == 0) return;
    int2 start = int2(round(game.playerTarget.xy));
    if (!inMap(start) || planeAt(start) == 0) return;
    int parent[mapCells];
    int queue[mapCells];
    for (int i = 0; i < mapCells; ++i) parent[i] = -1;
    int startIndex = mapIndex(start);
    int goalIndex = mapIndex(goal);
    int read = 0;
    int write = 1;
    queue[0] = startIndex;
    parent[startIndex] = startIndex;
    while (read < write && parent[goalIndex] < 0) {
        int current = queue[read++];
        int2 tile = tileAt(current);
        for (int direction = 0; direction < 4; ++direction) {
            int2 neighbor = tile + (direction == 0 ? int2(1, 0)
                : direction == 1 ? int2(-1, 0)
                : direction == 2 ? int2(0, 1) : int2(0, -1));
            if (!inMap(neighbor) || planeAt(neighbor) == 0) continue;
            int next = mapIndex(neighbor);
            if (parent[next] >= 0) continue;
            parent[next] = current;
            queue[write++] = next;
        }
    }
    if (parent[goalIndex] < 0) return;
    int cursor = goalIndex;
    uint count = 0u;
    while (cursor != startIndex && count < uint(mapCells)) {
        game.route[count++] = cursor;
        cursor = parent[cursor];
    }
    game.progress.y = count;
    game.progress.z = 0u;
    game.playerTarget.zw = float2(goal);
}

kernel void initializeGame(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    game.playerTarget = float4(0.0f, 2.0f, 0.0f, 2.0f);
    game.cameraPointer = float4(0.0f, 2.0f, 0.5f, 0.5f);
    game.enemy = float4(11.0f, 0.0f, 3.0f, 0.0f);
    game.combat = float4(0.0f, 0.0f, 3.0f, 0.0f);
    game.motion = float4(0.0f);
    game.progress = uint4(0u);
    for (int i = 0; i < mapCells; ++i) {
        game.route[i] = 0;
        game.explored[i] = 0u;
    }
    revealAround(game);
}

kernel void advanceGame(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = min(u.resolutionTime.w, 0.05f);
    float2 pointer = u.pointer.xy;
    // The remembered pointer prevents camera motion from reissuing a click.
    if (distance(pointer, game.cameraPointer.zw) > 0.0001f) {
        game.cameraPointer.zw = pointer;
        int2 clicked = int2(round(screenToWorld(
            pointer * u.resolutionTime.xy, game.cameraPointer.xy,
            u.resolutionTime.xy)));
        if (inMap(clicked) && game.explored[mapIndex(clicked)] != 0u) {
            planRoute(game, clicked);
        }
    }

    game.motion.z = 0.0f;
    if (game.progress.w == 0u && game.progress.z < game.progress.y) {
        int next = game.route[game.progress.y - 1u - game.progress.z];
        float2 target = float2(tileAt(next));
        float2 delta = target - game.playerTarget.xy;
        float remaining = length(delta);
        float step = min(remaining, 3.25f * dt);
        if (remaining > 0.0001f) {
            game.playerTarget.xy += delta / remaining * step;
            game.motion.x += step * 12.0f;
            game.motion.y = atan2(delta.y, delta.x);
            game.motion.z = 1.0f;
        }
        if (remaining <= step + 0.0001f) {
            game.playerTarget.xy = target;
            game.progress.z += 1u;
        }
    }
    game.cameraPointer.xy = mix(game.cameraPointer.xy, game.playerTarget.xy,
        min(1.0f, dt * 5.0f));
    revealAround(game);

    for (uint index = 0u; index < coinCount; ++index) {
        uint bit = 1u << index;
        if ((game.progress.x & bit) == 0u &&
            distance(game.playerTarget.xy, coinPosition(index)) < 0.55f) {
            game.progress.x |= bit;
        }
    }
    game.combat.y = max(0.0f, game.combat.y - dt);
    game.combat.w = max(0.0f, game.combat.w - dt);
    game.enemy.w = max(0.0f, game.enemy.w - dt);
    if (u.pointer.z > game.combat.x) {
        game.combat.x = u.pointer.z;
        if (game.progress.w == 0u && game.combat.y <= 0.0f) {
            game.combat.y = 0.38f;
            if (game.enemy.z > 0.0f &&
                distance(game.playerTarget.xy, game.enemy.xy) < 1.85f) {
                game.enemy.z -= 1.0f;
                game.enemy.w = 0.35f;
            }
        }
    }
    if (game.enemy.z > 0.0f && game.progress.w == 0u) {
        float2 delta = game.playerTarget.xy - game.enemy.xy;
        float separation = length(delta);
        if (separation < 4.2f && separation > 0.8f) {
            float2 next = game.enemy.xy + delta / separation * 0.68f * dt;
            if (planeAt(int2(round(next))) == 2) game.enemy.xy = next;
        }
        if (separation < 0.85f && game.combat.w <= 0.0f) {
            game.combat.z -= 1.0f;
            game.combat.w = 1.5f;
            if (game.combat.z <= 0.0f) game.progress.w = 1u;
        }
    }
}

vertex ScreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1u) & 2u, vertexID & 2u);
    ScreenVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

float hashTile(float2 tile) {
    return fract(sin(dot(tile, float2(127.1f, 311.7f))) * 43758.5453f);
}

float ellipseMask(float2 p, float2 radius, float feather) {
    float distanceFromCenter = length(p / radius);
    return 1.0f - smoothstep(1.0f - feather, 1.0f + feather,
        distanceFromCenter);
}

float boxMask(float2 p, float2 center, float2 halfSize, float feather) {
    float2 outside = abs(p - center) - halfSize;
    return 1.0f - smoothstep(-feather, feather,
        max(outside.x, outside.y));
}

float segmentDistance(float2 p, float2 a, float2 b) {
    float2 segment = b - a;
    float t = clamp(dot(p - a, segment) / dot(segment, segment),
        0.0f, 1.0f);
    return length(p - a - t * segment);
}

fragment float4 gameFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 pixel = in.uv * resolution;
    float scale = fitScale(resolution);
    float2 camera = game.cameraPointer.xy;
    float2 world = screenToWorld(pixel, camera, resolution);
    int2 tile = int2(round(world));
    int plane = inMap(tile) ? planeAt(tile) : 0;
    bool discovered = plane != 0 && game.explored[mapIndex(tile)] != 0u;
    float time = u.resolutionTime.z;
    float3 color = float3(0.014f, 0.020f, 0.030f);
    color += float3(0.018f, 0.018f, 0.027f)
        * (1.0f - length(in.uv - 0.5f) * 1.15f);

    // The four floating planes and their three narrow bridges are all tiles
    // in one navigable grid. Unvisited tiles stay invisible in the void.
    if (discovered) {
        float2 local = world - float2(tile);
        float noise = hashTile(float2(tile));
        float3 stone = plane == 5
            ? float3(0.29f, 0.17f, 0.08f)
            : float3(0.112f, 0.134f, 0.151f)
                + (noise - 0.5f) * float3(0.052f, 0.052f, 0.055f);
        if (plane == 3) stone += float3(0.015f, 0.035f, 0.050f);
        if (plane == 4) stone += float3(0.030f, 0.016f, 0.0f);
        float grout = smoothstep(0.455f, 0.495f,
            max(abs(local.x), abs(local.y)));
        stone = mix(stone, float3(0.026f, 0.035f, 0.046f), grout);
        float crack = (1.0f - smoothstep(0.015f, 0.035f,
            abs(local.y + 0.36f * local.x - noise * 0.24f)))
            * step(0.78f, noise) * (1.0f - grout);
        stone *= 1.0f - 0.32f * crack;
        stone *= 1.0f - 0.30f * smoothstep(3.0f, 10.0f,
            distance(world, game.playerTarget.xy));
        if (plane == 5) {
            float plank = planeAt(tile) == 5 && tile.y == 0
                ? abs(local.x) : abs(local.y);
            stone *= 1.0f - 0.24f * smoothstep(0.34f, 0.47f, plank);
        }
        color = stone;
    }

    // Return here after collecting the coins and defeating the creature.
    uint collected = game.progress.x;
    bool complete = (collected & 127u) == 127u && game.enemy.z <= 0.0f;
    float2 portal = (pixel - worldToScreen(float2(0.0f), camera, resolution))
        / scale;
    float portalRadius = length(portal / float2(43.0f, 23.0f));
    float portalRing = 1.0f - smoothstep(0.045f, 0.13f,
        abs(portalRadius - 1.0f));
    color += float3(0.05f, 0.30f, 0.40f)
        * portalRing * float(discovered && plane == 1)
            * (complete ? 2.5f : 0.55f);
    if (complete) {
        color += float3(0.025f, 0.19f, 0.28f)
            * exp(-dot(portal, portal) / 1900.0f)
                * float(discovered && plane == 1);
    }

    // Seven gold coins are spread across all four planes.
    for (uint index = 0u; index < coinCount; ++index) {
        if ((collected & (1u << index)) != 0u) continue;
        float2 coinWorld = coinPosition(index);
        if (game.explored[mapIndex(int2(coinWorld))] == 0u) continue;
        float2 anchor = worldToScreen(coinWorld, camera, resolution);
        float2 rel = (pixel - anchor) / scale;
        rel.y += 16.0f + 2.5f * sin(time * 3.2f + float(index));
        float glow = exp(-dot(rel, rel) / 950.0f);
        color += float3(0.28f, 0.14f, 0.012f) * glow;
        float coin = ellipseMask(rel, float2(8.0f, 11.0f), 0.1f);
        color = mix(color, float3(1.2f, 0.72f, 0.12f), coin);
        color = mix(color, float3(0.47f, 0.25f, 0.04f),
            coin * ellipseMask(rel, float2(4.0f, 7.0f), 0.1f));
        float glint = ellipseMask(rel + float2(2.5f, 5.0f),
            float2(2.0f, 4.0f), 0.28f);
        color += float3(0.75f, 0.57f, 0.21f) * glint;
    }

    // Four iron braziers frame the courtyard and cast warm pools of light.
    for (uint index = 0u; index < 4u; ++index) {
        int2 torchTile = int2(torchPosition(index));
        if (game.explored[mapIndex(torchTile)] == 0u) continue;
        float2 anchor = worldToScreen(torchPosition(index), camera, resolution);
        float2 rel = (pixel - anchor) / scale;
        float flicker = 0.83f + 0.17f
            * sin(time * 8.0f + float(index) * 2.3f);
        float2 flameCenter = float2(0.0f, -51.0f);
        color += float3(0.33f, 0.095f, 0.017f) * flicker
            * exp(-dot(rel - flameCenter, rel - flameCenter) / 2300.0f);
        float foot = ellipseMask(rel, float2(17.0f, 6.0f), 0.1f);
        color = mix(color, float3(0.080f, 0.071f, 0.067f), foot);
        float stem = boxMask(rel, float2(0.0f, -25.0f),
            float2(4.0f, 24.0f), 1.0f);
        color = mix(color, float3(0.16f, 0.12f, 0.088f), stem);
        float cup = ellipseMask(rel - float2(0.0f, -43.0f),
            float2(10.0f, 4.0f), 0.2f);
        color = mix(color, float3(0.29f, 0.19f, 0.11f), cup);
        float flame = ellipseMask(rel - flameCenter,
            float2(5.0f, 12.0f + 2.0f * flicker), 0.18f);
        color = mix(color, float3(1.35f, 0.42f, 0.055f), flame);
        float core = ellipseMask(rel - flameCenter - float2(0.0f, 2.0f),
            float2(2.3f, 6.0f), 0.2f);
        color = mix(color, float3(1.65f, 1.00f, 0.35f), core);
    }

    // A horned creature guards the eastern plane. Its bar shows three hits.
    if (game.enemy.z > 0.0f &&
        game.explored[mapIndex(int2(round(game.enemy.xy)))] != 0u) {
        float2 beast = (pixel - worldToScreen(game.enemy.xy,
            camera, resolution)) / scale;
        float flash = game.enemy.w > 0.0f ? 0.48f : 0.0f;
        color = mix(color, color * 0.25f,
            ellipseMask(beast, float2(25.0f, 7.0f), 0.16f));
        float body = ellipseMask(beast - float2(0.0f, -29.0f),
            float2(22.0f, 24.0f), 0.13f);
        color = mix(color, float3(0.29f, 0.07f, 0.09f) + flash, body);
        float head = ellipseMask(beast - float2(0.0f, -53.0f),
            float2(17.0f, 15.0f), 0.12f);
        color = mix(color, float3(0.39f, 0.10f, 0.10f) + flash, head);
        for (int side = -1; side <= 1; side += 2) {
            float horn = 1.0f - smoothstep(2.0f, 4.0f,
                segmentDistance(beast, float2(float(side) * 10.0f, -58.0f),
                    float2(float(side) * 24.0f, -82.0f)));
            color = mix(color, float3(0.65f, 0.58f, 0.40f), horn);
            float eye = ellipseMask(beast - float2(float(side) * 7.0f, -55.0f),
                float2(2.7f, 2.4f), 0.1f);
            color = mix(color, float3(1.2f, 0.26f, 0.08f), eye);
        }
        float hp = boxMask(beast, float2(0.0f, -92.0f),
            float2(22.0f, 3.0f), 0.5f);
        color = mix(color, float3(0.06f, 0.04f, 0.04f), hp);
        float hpFill = boxMask(beast,
            float2(-22.0f + game.enemy.z / 3.0f * 22.0f, -92.0f),
            float2(22.0f * game.enemy.z / 3.0f, 2.0f), 0.3f);
        color = mix(color, float3(0.85f, 0.15f, 0.09f), hpFill);
    }

    // The destination is a floor marker, separate from the moving hero.
    if (game.progress.z < game.progress.y) {
        float2 marker = (pixel - worldToScreen(game.playerTarget.zw,
            camera, resolution)) / scale;
        float radius = length(marker / float2(19.0f, 9.0f));
        float ring = 1.0f - smoothstep(0.07f, 0.19f, abs(radius - 1.0f));
        color += float3(0.45f, 0.22f, 0.035f) * ring;
    }

    // A hooded adventurer, feet anchored to the same world space as the tiles.
    float2 feet = worldToScreen(game.playerTarget.xy, camera, resolution);
    float2 hero = (pixel - feet) / scale;
    float swing = sin(game.motion.x) * 3.3f * game.motion.z;
    float shadow = ellipseMask(hero, float2(22.0f, 7.0f), 0.24f);
    color = mix(color, color * 0.23f, shadow * 0.8f);
    float backCloak = boxMask(hero, float2(0.0f, -26.0f),
        float2(15.0f, 23.0f), 2.5f);
    color = mix(color, float3(0.047f, 0.070f, 0.13f), backCloak);
    float leftBoot = boxMask(hero, float2(-6.0f + swing, -8.0f),
        float2(4.4f, 10.0f), 1.2f);
    float rightBoot = boxMask(hero, float2(6.0f - swing, -8.0f),
        float2(4.4f, 10.0f), 1.2f);
    color = mix(color, float3(0.21f, 0.15f, 0.095f),
        max(leftBoot, rightBoot));
    float2 armorRel = hero - float2(0.0f, -33.0f);
    float armor = ellipseMask(armorRel, float2(12.0f, 17.0f), 0.13f);
    color = mix(color, float3(0.18f, 0.24f, 0.30f), armor);
    float trim = boxMask(hero, float2(0.0f, -28.0f),
        float2(2.1f, 13.0f), 0.7f);
    color = mix(color, float3(0.58f, 0.36f, 0.13f), trim * armor);
    float hood = ellipseMask(hero - float2(0.0f, -55.0f),
        float2(11.0f, 11.5f), 0.13f);
    color = mix(color, float3(0.052f, 0.070f, 0.13f), hood);
    float face = ellipseMask(hero - float2(0.0f, -54.0f),
        float2(6.5f, 7.0f), 0.12f);
    color = mix(color, float3(0.66f, 0.46f, 0.29f), face);
    float visor = boxMask(hero, float2(0.0f, -58.0f),
        float2(7.0f, 2.0f), 0.8f);
    color = mix(color, float3(0.07f, 0.09f, 0.13f), visor * face);
    float blade = 1.0f - smoothstep(1.2f, 2.5f,
        segmentDistance(hero, float2(14.0f, -27.0f),
            game.combat.y > 0.0f ? float2(58.0f, -39.0f)
                : float2(30.0f, -55.0f)));
    color = mix(color, float3(0.54f, 0.78f, 0.88f), blade);
    if (game.combat.y > 0.0f) {
        float arc = 1.0f - smoothstep(2.0f, 5.0f,
            abs(length(hero - float2(8.0f, -31.0f)) - 47.0f));
        color += float3(0.18f, 0.38f, 0.50f) * arc;
    }
    float hilt = 1.0f - smoothstep(1.5f, 3.0f,
        segmentDistance(hero, float2(11.0f, -23.0f),
            float2(18.0f, -34.0f)));
    color = mix(color, float3(0.69f, 0.42f, 0.15f), hilt);

    // Coins and hearts stay fixed on screen while the camera follows movement.
    for (uint index = 0u; index < coinCount; ++index) {
        float2 gem = (pixel - float2(40.0f + float(index) * 29.0f,
            37.0f) * scale) / scale;
        float shape = 1.0f - smoothstep(0.84f, 1.06f,
            abs(gem.x / 9.0f) + abs(gem.y / 12.0f));
        float lit = (collected & (1u << index)) != 0u ? 1.0f : 0.0f;
        color = mix(color,
            mix(float3(0.095f, 0.10f, 0.12f),
                float3(1.05f, 0.69f, 0.12f), lit), shape);
    }
    for (uint index = 0u; index < 3u; ++index) {
        float2 heart = (pixel - float2(resolution.x -
            (44.0f + float(index) * 28.0f) * scale,
            37.0f * scale)) / scale;
        float shape = ellipseMask(heart, float2(9.0f, 8.0f), 0.1f);
        color = mix(color, float(index) < game.combat.z
            ? float3(0.91f, 0.17f, 0.13f)
            : float3(0.13f, 0.07f, 0.07f), shape);
    }
    if (game.progress.w != 0u) {
        color = mix(color, float3(0.28f, 0.025f, 0.025f), 0.25f);
    }
    float vignette = 1.0f - 0.35f * smoothstep(0.28f, 0.76f,
        length(in.uv - 0.5f));
    float3 mapped = 1.0f - exp(-max(color * vignette,
        float3(0.0f)) * 1.45f);
    float3 srgb = select(1.055f * pow(mapped,
        float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

#include <metal_stdlib>
using namespace metal;

// Perspective 3D version of Ashen Path for the generic GPU Program node.
// Game state stays on the GPU; camera yaw and pitch are workflow parameters.

constant int mapWidth = 48;
constant int mapHalf = mapWidth / 2;
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
    float4 motion;        // walking phase, facing angle, moving, orbit yaw offset
    uint4 progress;       // collected bits, route length, next route index, game over
    int route[mapCells];
    uint explored[mapCells];
};

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

struct Ray { float3 origin; float3 direction; };

Ray cameraRay(float2 pixel, float2 camera, float2 resolution,
    float yawDegrees, float pitchDegrees) {
    float yaw = yawDegrees * 0.01745329252f;
    float pitch = clamp(pitchDegrees, 20.0f, 80.0f) * 0.01745329252f;
    float3 focus = float3(camera.x, 0.0f, camera.y);
    float3 eye = focus + 15.0f * float3(cos(pitch) * cos(yaw),
        sin(pitch), cos(pitch) * sin(yaw));
    float3 forward = normalize(focus - eye);
    float3 right = normalize(cross(forward, float3(0.0f, 1.0f, 0.0f)));
    float3 up = cross(right, forward);
    float2 screen = (pixel - 0.5f * resolution) / resolution.y;
    float focal = 0.5f / tan(55.0f * 0.01745329252f * 0.5f);
    return {eye, normalize(forward * focal + right * screen.x - up * screen.y)};
}

float2 screenToWorld(float2 pixel, float2 camera, float2 resolution,
    float yawDegrees, float pitchDegrees) {
    Ray ray = cameraRay(pixel, camera, resolution,
        yawDegrees, pitchDegrees);
    if (ray.direction.y >= -0.001f) return float2(1000.0f);
    float3 point = ray.origin - ray.direction * ray.origin.y / ray.direction.y;
    return point.xz;
}

bool inMap(int2 tile) {
    return all(tile >= int2(-mapHalf)) && all(tile < int2(mapHalf));
}

int mapIndex(int2 tile) {
    return (tile.y + mapHalf) * mapWidth + tile.x + mapHalf;
}

int2 tileAt(int index) {
    return int2(index % mapWidth - mapHalf, index / mapWidth - mapHalf);
}

float2 forestCenter(int index) {
    if (index == 0) return float2(-12.0f, 11.0f);
    if (index == 1) return float2(12.0f, -11.0f);
    return float2(17.0f, 15.0f);
}

float2 forestRadii(int index) {
    if (index == 0) return float2(6.0f, 7.0f);
    if (index == 1) return float2(7.0f, 6.0f);
    return float2(5.0f, 6.0f);
}

float2 rockCenter(int index) {
    return index == 0 ? float2(-12.0f, -10.0f) : float2(9.0f, 4.0f);
}

float2 rockRadii(int index) {
    return index == 0 ? float2(6.0f, 5.0f) : float2(4.0f, 6.0f);
}

bool insideWildArea(float2 point, float2 center, float2 radii) {
    float2 scaled = (point - center) / radii;
    float edge = 1.0f + 0.08f * sin(point.x * 1.17f + point.y * 0.73f);
    return dot(scaled, scaled) < edge;
}

int obstacleAt(int2 tile) {
    if (!inMap(tile)) return 3;
    for (int index = 0; index < 3; ++index) {
        if (insideWildArea(float2(tile), forestCenter(index),
            forestRadii(index))) return 1;
    }
    for (int index = 0; index < 2; ++index) {
        if (insideWildArea(float2(tile), rockCenter(index),
            rockRadii(index))) return 2;
    }
    return 0;
}

float2 coinPosition(uint index) {
    switch (index) {
        case 0u: return float2(-19.0f, 17.0f);
        case 1u: return float2(0.0f, 19.0f);
        case 2u: return float2(19.0f, 21.0f);
        case 3u: return float2(19.0f, 1.0f);
        case 4u: return float2(19.0f, -19.0f);
        case 5u: return float2(-2.0f, -19.0f);
        default: return float2(-19.0f, -16.0f);
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
    for (int y = -8; y <= 8; ++y) {
        for (int x = -8; x <= 8; ++x) {
            int2 tile = center + int2(x, y);
            if (inMap(tile)
                && distance(float2(tile), game.playerTarget.xy) <= 7.6f) {
                game.explored[mapIndex(tile)] = 1u;
            }
        }
    }
}

void planRoute(device GameState &game, int2 goal) {
    if (obstacleAt(goal) != 0) return;
    int2 start = int2(round(game.playerTarget.xy));
    if (obstacleAt(start) != 0) return;
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
            if (obstacleAt(neighbor) != 0) continue;
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

kernel void initializeGame(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    game.playerTarget = float4(0.0f, 2.0f, 0.0f, 2.0f);
    // Saved Trackpad coordinates are the starting pointer, not a move command.
    game.cameraPointer = float4(0.0f, 2.0f, u.pointer.xy);
    game.enemy = float4(17.0f, 1.0f, 3.0f, 0.0f);
    game.combat = float4(0.0f, 0.0f, 3.0f, 0.0f);
    // The hero model faces +Z before its first step.
    game.motion = float4(0.0f, 1.57079632679f, 0.0f, 0.0f);
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
            u.resolutionTime.xy,
            u.parameters0.x + game.motion.w, u.parameters0.y)));
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
        bool creatureInRange = game.enemy.z > 0.0f
            && distance(game.playerTarget.xy, game.enemy.xy) < 1.85f;
        if (creatureInRange) {
            if (game.progress.w == 0u && game.combat.y <= 0.0f) {
                game.combat.y = 0.38f;
                game.enemy.z -= 1.0f;
                game.enemy.w = 0.35f;
            }
        } else {
            game.motion.w += 45.0f;
            if (game.motion.w >= 360.0f) game.motion.w -= 360.0f;
        }
    }
    if (game.enemy.z > 0.0f && game.progress.w == 0u) {
        float2 delta = game.playerTarget.xy - game.enemy.xy;
        float separation = length(delta);
        if (separation < 4.2f && separation > 0.8f) {
            float2 next = game.enemy.xy + delta / separation * 0.68f * dt;
            if (obstacleAt(int2(round(next))) == 0) game.enemy.xy = next;
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

struct Hit {
    float distance;
    float3 normal;
    float3 color;
    int material; // 1 = stone, 2 = ordinary object, 3 = emissive
};

float hashTile(float2 tile) {
    return fract(sin(dot(tile, float2(127.1f, 311.7f))) * 43758.5453f);
}

bool boxIntersection(Ray ray, float3 lower, float3 upper,
    thread float &distance, thread float3 &normal) {
    float3 direction = select(ray.direction, float3(0.00001f),
        abs(ray.direction) < float3(0.00001f));
    float3 first = (lower - ray.origin) / direction;
    float3 second = (upper - ray.origin) / direction;
    float3 entry = min(first, second);
    float3 exit = max(first, second);
    float near = max(entry.x, max(entry.y, entry.z));
    float far = min(exit.x, min(exit.y, exit.z));
    if (far < max(near, 0.0f)) return false;
    distance = near > 0.0f ? near : far;
    if (distance <= 0.0f) return false;
    float3 point = ray.origin + distance * ray.direction;
    float3 center = 0.5f * (lower + upper);
    float3 edge = abs((point - center) / max(0.5f * (upper - lower), float3(0.001f)));
    normal = edge.x > edge.y && edge.x > edge.z
        ? float3(sign(point.x - center.x), 0.0f, 0.0f)
        : edge.y > edge.z
            ? float3(0.0f, sign(point.y - center.y), 0.0f)
            : float3(0.0f, 0.0f, sign(point.z - center.z));
    return true;
}

void addBox(thread Hit &hit, Ray ray, float3 lower, float3 upper,
    float3 color, int material) {
    float distance;
    float3 normal;
    if (boxIntersection(ray, lower, upper, distance, normal)
        && distance < hit.distance) {
        hit = {distance, normal, color, material};
    }
}

void addSphere(thread Hit &hit, Ray ray, float3 center, float radius,
    float3 color, int material) {
    float3 offset = ray.origin - center;
    float along = dot(offset, ray.direction);
    float discriminant = along * along - dot(offset, offset) + radius * radius;
    if (discriminant < 0.0f) return;
    float root = sqrt(discriminant);
    float distance = -along - root;
    if (distance <= 0.0f) distance = -along + root;
    if (distance > 0.0f && distance < hit.distance) {
        float3 point = ray.origin + distance * ray.direction;
        hit = {distance, normalize(point - center), color, material};
    }
}

void addCone(thread Hit &hit, Ray ray, float3 base, float height,
    float radius, float3 color) {
    float3 offset = ray.origin - base;
    float slopeSquared = (radius / height) * (radius / height);
    float a = dot(ray.direction.xz, ray.direction.xz)
        - slopeSquared * ray.direction.y * ray.direction.y;
    float b = 2.0f * (dot(offset.xz, ray.direction.xz)
        + slopeSquared * (height - offset.y) * ray.direction.y);
    float c = dot(offset.xz, offset.xz)
        - slopeSquared * (height - offset.y) * (height - offset.y);
    float discriminant = b * b - 4.0f * a * c;
    if (discriminant < 0.0f || abs(a) < 0.000001f) return;
    float root = sqrt(discriminant);
    for (int candidate = 0; candidate < 2; ++candidate) {
        float distance = (-b + (candidate == 0 ? -root : root))
            / (2.0f * a);
        float y = offset.y + distance * ray.direction.y;
        if (distance <= 0.0f || distance >= hit.distance
            || y < 0.0f || y > height) continue;
        float3 local = offset + distance * ray.direction;
        float3 normal = normalize(float3(local.x,
            slopeSquared * (height - y), local.z));
        hit = {distance, normal, color, 2};
    }
}

float exploredAt(device const GameState &game, int2 tile) {
    return inMap(tile) ? float(game.explored[mapIndex(tile)]) : 0.0f;
}

float explorationAt(device const GameState &game, float2 point) {
    int2 base = int2(floor(point));
    float2 blend = point - float2(base);
    blend = blend * blend * (3.0f - 2.0f * blend);
    float lower = mix(exploredAt(game, base),
        exploredAt(game, base + int2(1, 0)), blend.x);
    float upper = mix(exploredAt(game, base + int2(0, 1)),
        exploredAt(game, base + int2(1, 1)), blend.x);
    float nearPlayer = 1.0f - smoothstep(6.4f, 8.4f,
        distance(point, game.playerTarget.xy));
    return max(mix(lower, upper, blend.y), nearPlayer);
}

float areaBlend(float2 point, float2 center, float2 radii) {
    return 1.0f - smoothstep(0.83f, 1.10f,
        length((point - center) / radii));
}

float3 textureAlbedo(texture2d<float> image, float2 uv) {
    constexpr sampler materialSampler(coord::normalized,
        address::mirrored_repeat, filter::linear);
    float4 sample = image.sample(materialSampler, uv);
    float3 srgb = clamp(sample.rgb / max(sample.a, 0.001f),
        float3(0.0f), float3(1.0f));
    return select(pow((srgb + 0.055f) / 1.055f,
        float3(2.4f)), srgb / 12.92f, srgb <= 0.04045f);
}

void addTerrain(thread Hit &hit, Ray ray,
    texture2d<float> stoneTop, texture2d<float> bridgeTop,
    texture2d<float> slabSide) {
    float distance;
    float3 normal;
    if (!boxIntersection(ray, float3(-24.5f, -0.75f, -24.5f),
        float3(23.5f, 0.0f, 23.5f), distance, normal)
        || distance >= hit.distance) return;
    float3 point = ray.origin + distance * ray.direction;
    float3 stone;
    if (normal.y > 0.5f) {
        float2 ground = point.xz;
        stone = textureAlbedo(stoneTop, ground * 0.17f)
            * float3(0.57f, 0.63f, 0.61f);
        float mottling = sin(ground.x * 0.43f + ground.y * 0.17f)
            * sin(ground.y * 0.51f - ground.x * 0.13f);
        stone *= 0.90f + 0.10f * mottling;
        float eastTrail = 1.0f - smoothstep(1.2f, 3.0f,
            abs(ground.y - 1.3f * sin(ground.x * 0.12f)));
        float northTrail = 1.0f - smoothstep(1.0f, 2.8f,
            abs(ground.x + 1.1f * sin(ground.y * 0.14f)));
        stone *= mix(float3(0.72f, 0.78f, 0.70f),
            float3(1.03f, 0.93f, 0.77f), max(eastTrail, northTrail));
        float decking = (1.0f - smoothstep(1.0f, 1.55f,
            abs(ground.x + 2.0f)))
            * (1.0f - smoothstep(3.0f, 3.6f,
            abs(ground.y + 7.0f)));
        stone = mix(stone, textureAlbedo(bridgeTop, ground * 0.24f)
            * float3(0.76f, 0.59f, 0.40f), decking);
        for (int index = 0; index < 3; ++index) {
            float shade = areaBlend(ground, forestCenter(index),
                forestRadii(index));
            stone = mix(stone, stone * float3(0.28f, 0.55f, 0.43f),
                shade * 0.75f);
        }
        for (int index = 0; index < 2; ++index) {
            float shade = areaBlend(ground, rockCenter(index),
                rockRadii(index));
            stone = mix(stone, stone * float3(0.46f, 0.52f, 0.57f),
                shade * 0.72f);
        }
    } else {
        float horizontal = abs(normal.x) > 0.5f ? point.z : point.x;
        stone = textureAlbedo(slabSide,
            float2(horizontal * 0.19f, -point.y / 0.75f))
            * float3(0.35f, 0.39f, 0.43f);
    }
    hit = {distance, normal, stone, 1};
}

void addWildScenery(thread Hit &hit, Ray ray) {
    for (int region = 0; region < 3; ++region) {
        float2 center = forestCenter(region);
        float2 radii = forestRadii(region);
        float distance;
        float3 normal;
        if (!boxIntersection(ray,
            float3(center.x - radii.x - 1.5f, 0.0f,
                center.y - radii.y - 1.5f),
            float3(center.x + radii.x + 1.5f, 4.0f,
                center.y + radii.y + 1.5f), distance, normal)
            || distance >= hit.distance) continue;
        for (int index = 0; index < 18; ++index) {
            float angle = float(index) * 2.39996323f + float(region);
            float radius = sqrt((float(index) + 0.5f) / 18.0f) * 0.84f;
            float2 at = center + radii * radius
                * float2(cos(angle), sin(angle));
            float variation = hashTile(at);
            float height = 1.65f + 0.55f * variation;
            float crown = 1.04f + 0.20f * variation;
            addBox(hit, ray,
                float3(at.x - 0.13f, 0.0f, at.y - 0.13f),
                float3(at.x + 0.13f, height, at.y + 0.13f),
                float3(0.14f, 0.10f, 0.07f), 2);
            float3 needles = float3(0.035f, 0.12f, 0.085f)
                * (0.75f + 0.40f * variation);
            addCone(hit, ray, float3(at.x, 0.72f, at.y),
                1.83f + 0.38f * variation, crown, needles);
            addCone(hit, ray, float3(at.x, 1.48f, at.y),
                1.72f + 0.26f * variation, crown * 0.69f,
                needles * 1.15f);
        }
    }
    for (int region = 0; region < 2; ++region) {
        float2 center = rockCenter(region);
        float2 radii = rockRadii(region);
        float distance;
        float3 normal;
        if (!boxIntersection(ray,
            float3(center.x - radii.x - 1.5f, 0.0f,
                center.y - radii.y - 1.5f),
            float3(center.x + radii.x + 1.5f, 3.0f,
                center.y + radii.y + 1.5f), distance, normal)
            || distance >= hit.distance) continue;
        for (int index = 0; index < 11; ++index) {
            float angle = float(index) * 2.39996323f + float(region);
            float radius = sqrt((float(index) + 0.5f) / 11.0f) * 0.78f;
            float2 at = center + radii * radius
                * float2(cos(angle), sin(angle));
            float variation = hashTile(at);
            float size = 1.0f + 0.50f * variation;
            float3 granite = float3(0.20f, 0.23f, 0.26f)
                * (0.85f + 0.32f * variation);
            addSphere(hit, ray, float3(at.x, size * 0.53f, at.y),
                size, granite, 2);
            addSphere(hit, ray,
                float3(at.x + 0.46f * size, size * 0.42f,
                    at.y - 0.30f * size),
                size * 0.62f, granite * 0.85f, 2);
        }
    }
}

void addScenery(thread Hit &hit, Ray ray, device const GameState &game,
    float time) {
    for (uint index = 0u; index < coinCount; ++index) {
        if ((game.progress.x & (1u << index)) != 0u) continue;
        float2 at = coinPosition(index);
        float bob = 0.09f * sin(time * 3.2f + float(index));
        addSphere(hit, ray, float3(at.x, 0.43f + bob, at.y), 0.23f,
            float3(1.1f, 0.67f, 0.10f), 3);
    }
    for (uint index = 0u; index < 4u; ++index) {
        float2 at = torchPosition(index);
        addBox(hit, ray, float3(at.x - 0.09f, 0.0f, at.y - 0.09f),
            float3(at.x + 0.09f, 0.68f, at.y + 0.09f),
            float3(0.15f, 0.12f, 0.10f), 2);
        addSphere(hit, ray, float3(at.x, 0.69f, at.y), 0.20f,
            float3(0.36f, 0.22f, 0.12f), 2);
        float flame = 0.11f + 0.025f * sin(time * 8.0f + float(index));
        addSphere(hit, ray, float3(at.x, 0.87f, at.y), flame,
            float3(1.5f, 0.52f, 0.055f), 3);
    }
}

void addCreature(thread Hit &hit, Ray ray, device const GameState &game) {
    if (game.enemy.z <= 0.0f) return;
    float3 base = float3(game.enemy.x, 0.0f, game.enemy.y);
    float flash = game.enemy.w > 0.0f ? 0.45f : 0.0f;
    addSphere(hit, ray, base + float3(0.0f, 0.66f, 0.0f), 0.47f,
        float3(0.32f, 0.075f, 0.09f) + flash, 2);
    addSphere(hit, ray, base + float3(0.0f, 1.20f, 0.0f), 0.32f,
        float3(0.43f, 0.10f, 0.10f) + flash, 2);
    for (int side = -1; side <= 1; side += 2) {
        float x = float(side) * 0.28f;
        addBox(hit, ray, base + float3(x - 0.08f, 1.38f, -0.06f),
            base + float3(x + 0.08f, 1.80f, 0.06f),
            float3(0.73f, 0.64f, 0.44f), 2);
        addSphere(hit, ray, base + float3(float(side) * 0.15f,
            1.22f, 0.29f), 0.06f, float3(1.5f, 0.22f, 0.055f), 3);
    }
}

void addHero(thread Hit &hit, Ray ray, device const GameState &game) {
    float3 base = float3(game.playerTarget.x, 0.0f, game.playerTarget.y);
    // Trace the world ray through the hero's local space so every body part,
    // including the face and sword, follows the last walking direction.
    float2 forward = float2(cos(game.motion.y), sin(game.motion.y));
    float2 right = float2(forward.y, -forward.x);
    float2 relativeOrigin = ray.origin.xz - game.playerTarget.xy;
    Ray heroRay = {
        float3(base.x + dot(relativeOrigin, right), ray.origin.y,
            base.z + dot(relativeOrigin, forward)),
        float3(dot(ray.direction.xz, right), ray.direction.y,
            dot(ray.direction.xz, forward))
    };
    float previousDistance = hit.distance;
    float stride = 0.06f * sin(game.motion.x) * game.motion.z;
    addBox(hit, heroRay, base + float3(-0.25f + stride, 0.0f, -0.14f),
        base + float3(-0.04f + stride, 0.48f, 0.14f),
        float3(0.22f, 0.15f, 0.09f), 2);
    addBox(hit, heroRay, base + float3(0.04f - stride, 0.0f, -0.14f),
        base + float3(0.25f - stride, 0.48f, 0.14f),
        float3(0.22f, 0.15f, 0.09f), 2);
    addBox(hit, heroRay, base + float3(-0.38f, 0.40f, -0.24f),
        base + float3(0.38f, 1.18f, 0.25f),
        float3(0.07f, 0.10f, 0.17f), 2);
    addBox(hit, heroRay, base + float3(-0.27f, 0.62f, 0.16f),
        base + float3(0.27f, 1.09f, 0.32f),
        float3(0.23f, 0.30f, 0.37f), 2);
    addBox(hit, heroRay, base + float3(-0.035f, 0.56f, 0.32f),
        base + float3(0.035f, 1.06f, 0.345f),
        float3(0.67f, 0.41f, 0.15f), 2);
    addSphere(hit, heroRay, base + float3(0.0f, 1.29f, 0.02f), 0.31f,
        float3(0.055f, 0.08f, 0.15f), 2);
    addSphere(hit, heroRay, base + float3(0.0f, 1.27f, 0.25f), 0.18f,
        float3(0.70f, 0.50f, 0.32f), 2);
    addBox(hit, heroRay, base + float3(-0.23f, 1.31f, 0.32f),
        base + float3(0.23f, 1.38f, 0.37f),
        float3(0.08f, 0.10f, 0.14f), 2);
    float swing = game.combat.y > 0.0f ? 0.45f : 0.0f;
    addBox(hit, heroRay, base + float3(0.43f, 0.77f, -0.04f),
        base + float3(0.53f + swing, 1.58f, 0.05f),
        float3(0.61f, 0.82f, 0.90f), 2);
    addBox(hit, heroRay, base + float3(0.34f, 0.73f, -0.13f),
        base + float3(0.61f + swing, 0.80f, 0.13f),
        float3(0.72f, 0.43f, 0.16f), 2);
    if (hit.distance < previousDistance) {
        hit.normal.xz = right * hit.normal.x + forward * hit.normal.z;
    }
}

float3 shadeFloor(float3 color, float3 point,
    device const GameState &game, float time) {
    float2 ground = point.xz;
    float playerShadow = 1.0f - smoothstep(0.15f, 0.78f,
        distance(ground, game.playerTarget.xy));
    color *= 1.0f - 0.55f * playerShadow;
    if (game.enemy.z > 0.0f) {
        float enemyShadow = 1.0f - smoothstep(0.2f, 0.9f,
            distance(ground, game.enemy.xy));
        color *= 1.0f - 0.46f * enemyShadow;
    }
    for (uint index = 0u; index < 4u; ++index) {
        float2 at = torchPosition(index);
        float falloff = exp(-dot(ground - at, ground - at) / 5.0f);
        color += float3(0.33f, 0.10f, 0.015f) * falloff
            * (0.87f + 0.13f * sin(time * 8.0f + float(index)));
    }
    bool complete = (game.progress.x & 127u) == 127u
        && game.enemy.z <= 0.0f;
    float portalDistance = length(ground);
    float ring = 1.0f - smoothstep(0.055f, 0.12f,
        abs(portalDistance - 0.82f));
    color += float3(0.07f, 0.48f, 0.64f) * ring
        * (complete ? 2.0f : 0.50f);
    if (complete) color += float3(0.04f, 0.21f, 0.28f)
        * exp(-portalDistance * portalDistance / 1.3f);
    if (game.progress.z < game.progress.y) {
        float marker = 1.0f - smoothstep(0.035f, 0.095f,
            abs(distance(ground, game.playerTarget.zw) - 0.37f));
        color += float3(0.63f, 0.32f, 0.045f) * marker;
    }
    return color;
}

float uiScale(float2 resolution) {
    return min(resolution.x / 1280.0f, resolution.y / 800.0f);
}

float ellipseMask(float2 point, float2 radius) {
    return 1.0f - smoothstep(0.82f, 1.08f, length(point / radius));
}

fragment float4 gameFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> stoneTop [[texture(1)]],
    texture2d<float> bridgeTop [[texture(2)]],
    texture2d<float> slabSide [[texture(3)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 pixel = in.uv * resolution;
    float time = u.resolutionTime.z;
    Ray ray = cameraRay(pixel, game.cameraPointer.xy, resolution,
        u.parameters0.x + game.motion.w, u.parameters0.y);
    Hit hit = {100000.0f, float3(0.0f), float3(0.0f), 0};
    addTerrain(hit, ray, stoneTop, bridgeTop, slabSide);
    addWildScenery(hit, ray);
    addScenery(hit, ray, game, time);
    addCreature(hit, ray, game);
    addHero(hit, ray, game);

    float sky = clamp(0.5f + 0.5f * ray.direction.y, 0.0f, 1.0f);
    float3 background = mix(float3(0.012f, 0.018f, 0.030f),
        float3(0.042f, 0.060f, 0.082f), sky);
    float3 color = background;
    if (hit.material != 0) {
        float3 point = ray.origin + ray.direction * hit.distance;
        float3 light = normalize(float3(-0.46f, 0.86f, 0.58f));
        float diffuse = max(dot(hit.normal, light), 0.0f);
        color = hit.color * (0.28f + 0.78f * diffuse);
        if (hit.material == 1 && hit.normal.y > 0.5f) {
            color = shadeFloor(color, point, game, time);
        }
        if (hit.material == 3) color = hit.color;
        color = mix(color, background, smoothstep(19.0f, 40.0f,
            hit.distance) * 0.80f);
        color *= mix(0.11f, 1.0f, explorationAt(game, point.xz));
    }

    float scale = uiScale(resolution);
    for (uint index = 0u; index < coinCount; ++index) {
        float2 gem = (pixel - float2(40.0f + float(index) * 29.0f,
            37.0f) * scale) / scale;
        float shape = 1.0f - smoothstep(0.84f, 1.06f,
            abs(gem.x / 9.0f) + abs(gem.y / 12.0f));
        float lit = (game.progress.x & (1u << index)) != 0u ? 1.0f : 0.0f;
        color = mix(color, mix(float3(0.095f, 0.10f, 0.12f),
            float3(1.05f, 0.69f, 0.12f), lit), shape);
    }
    for (uint index = 0u; index < 3u; ++index) {
        float2 heart = (pixel - float2(resolution.x -
            (44.0f + float(index) * 28.0f) * scale,
            37.0f * scale)) / scale;
        float shape = ellipseMask(heart, float2(9.0f, 8.0f));
        color = mix(color, float(index) < game.combat.z
            ? float3(0.91f, 0.17f, 0.13f)
            : float3(0.13f, 0.07f, 0.07f), shape);
    }
    if (game.progress.w != 0u) {
        color = mix(color, float3(0.28f, 0.025f, 0.025f), 0.25f);
    }
    float vignette = 1.0f - 0.30f * smoothstep(0.28f, 0.76f,
        length(in.uv - 0.5f));
    float3 mapped = 1.0f - exp(-max(color * vignette,
        float3(0.0f)) * 1.45f);
    float3 srgb = select(1.055f * pow(mapped,
        float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

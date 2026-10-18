// pixeltje:3d-v1
#include <metal_stdlib>
using namespace metal;

// A small first-person underwater game for the existing gpu.program node.
// World coordinates are metres: +Y is up, the sea surface is Y=0, and the
// submarine starts facing -Z. The compute pass owns the voyage state; the
// fragment pass ray traces the same three-dimensional world for every pixel.

constant uint cacheCount = 5u;
constant uint levelCount = 3u;
constant uint allCachesMask = (1u << cacheCount) - 1u;
constant float3 homePosition = float3(0.0f, -1.0f, 4.0f);
// Each route visits a different mix of reefs, wreckage and trench floor.
constant float2 cacheXZ[15] = {
    float2(8.0f, -14.0f), float2(-17.0f, -22.0f),
    float2(14.0f, -36.0f), float2(-20.0f, -48.0f),
    float2(9.0f, -100.0f),
    float2(-12.0f, -18.0f), float2(24.0f, -37.0f),
    float2(-25.0f, -58.0f), float2(30.0f, -78.0f),
    float2(-16.0f, -97.0f),
    float2(20.0f, -25.0f), float2(-32.0f, -47.0f),
    float2(33.0f, -68.0f), float2(-39.0f, -92.0f),
    float2(18.0f, -116.0f)
};
constant float2 rockXZ[13] = {
    float2(-7.0f, -9.0f), float2(15.0f, -18.0f),
    float2(-12.0f, -28.0f), float2(2.0f, -27.0f),
    float2(21.0f, -42.0f), float2(-25.0f, -42.0f),
    float2(-3.0f, -53.0f), float2(18.0f, -64.0f),
    float2(-20.0f, -63.0f), float2(26.0f, -77.0f),
    float2(-29.0f, -86.0f), float2(6.0f, -101.0f),
    float2(27.0f, -112.0f)
};
constant float2 reefXZ[12] = {
    float2(-12.0f, -15.0f), float2(9.0f, -19.0f),
    float2(-21.0f, -34.0f), float2(18.0f, -36.0f),
    float2(-14.0f, -47.0f), float2(11.0f, -52.0f),
    float2(-23.0f, -62.0f), float2(21.0f, -61.0f),
    float2(-30.0f, -78.0f), float2(31.0f, -86.0f),
    float2(-18.0f, -104.0f), float2(24.0f, -114.0f)
};

struct ProgramUniforms {
    float4 resolutionTime;
    uint4 frameSeed;
    float4 parameters0;
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;
};

struct VoyageState {
    float4 positionYaw;  // submarine XYZ, heading
    float4 velocityPitch; // velocity XYZ, pitch
    float4 mission;      // battery, sonar seconds, elapsed seconds, collision flash
    uint4 progress;      // cache mask, last action count, phase, level index
    float4 survival;     // oxygen, notice seconds, transition seconds, surface latch
    uint4 stats;         // score, score at level start, surface stops, failure reason
    uint4 notice;        // transient message kind, reserved
};

constant uint phasePlaying = 0u;
constant uint phaseLevelClear = 1u;
constant uint phaseVictory = 2u;
constant uint phaseFailure = 3u;
constant uint noticeLevel = 1u;
constant uint noticeCoin = 2u;
constant uint noticeExit = 3u;
constant uint noticeOxygen = 4u;

float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
}

float floorHeight(float2 xz, uint level) {
    float broad = 2.2f * sin(xz.x * 0.115f) * cos(xz.y * 0.095f);
    float folds = 1.2f * sin(xz.x * 0.32f + xz.y * 0.23f);
    if (level == 0u) {
        // The first shelf is about four times deeper than the original
        // 24-metre seabed. The trench is ten times wider across X, while
        // its long approach descends toward a floor more than 300 metres down.
        float across = xz.x - (7.0f + 4.0f * sin(xz.y * 0.055f));
        float along = smoothstep(0.0f, 110.0f, -xz.y);
        float trench = -245.0f * exp(-across * across / 10500.0f)
            * along;
        float shoulder = 8.0f
            * exp(-pow((abs(across) - 170.0f) / 25.0f, 2.0f)) * along;
        return -96.0f + broad + folds + trench + shoulder;
    }
    float trenchX = xz.x + 5.0f * sin(xz.y * 0.065f);
    float trench = -7.0f * exp(-trenchX * trenchX / 84.0f);
    float distanceFromBuoy = clamp((-xz.y - 4.0f) / 110.0f, 0.0f, 1.0f);
    float extraDepth = level == 0u ? 0.0f
        : level == 1u ? 6.0f + 9.0f * distanceFromBuoy
        : 12.0f + 18.0f * distanceFromBuoy;
    return -24.0f + broad + folds + trench - extraDepth;
}

float3 cachePosition(uint level, uint index) {
    float2 xz = cacheXZ[level * cacheCount + index];
    return float3(xz.x, floorHeight(xz, level) + 1.4f, xz.y);
}

float3 submarineLampMount(device const VoyageState &game, float side) {
    float3 forward = pixeltje_3d::forward(game.positionYaw.w,
        game.velocityPitch.w);
    float3 right = normalize(cross(forward, float3(0.0f, 1.0f, 0.0f)));
    float3 up = normalize(cross(right, forward));
    return game.positionYaw.xyz + right * side * 1.00f
        + forward * 0.72f - up * 0.24f;
}

float3 submarineLampDirection(device const VoyageState &game, float side) {
    float3 forward = pixeltje_3d::forward(game.positionYaw.w,
        game.velocityPitch.w);
    float3 right = normalize(cross(forward, float3(0.0f, 1.0f, 0.0f)));
    float3 up = normalize(cross(right, forward));
    // Keep the optical axes outside the pilot's straight-ahead view.
    return normalize(forward + right * side * 0.20f - up * 0.035f);
}

bool pushOutOfBox(thread float3 &point, float3 lower, float3 upper) {
    if (any(point <= lower) || any(point >= upper)) return false;
    float3 fromLower = point - lower;
    float3 fromUpper = upper - point;
    float3 distanceToFace = min(fromLower, fromUpper);
    if (distanceToFace.x <= distanceToFace.y
        && distanceToFace.x <= distanceToFace.z) {
        point.x = fromLower.x < fromUpper.x ? lower.x : upper.x;
    } else if (distanceToFace.y <= distanceToFace.z) {
        point.y = fromLower.y < fromUpper.y ? lower.y : upper.y;
    } else {
        point.z = fromLower.z < fromUpper.z ? lower.z : upper.z;
    }
    return true;
}

void startLevel(device VoyageState &game, uint level, uint action) {
    // Start the first dive above its deep shelf so the nearby first cache is
    // reachable before automatic forward motion carries the submarine past it.
    game.positionYaw = float4(0.0f, level == 0u ? -88.0f : -5.5f,
        4.0f, 0.0f);
    game.velocityPitch = float4(0.0f, 0.0f, 0.0f, -0.17f);
    game.mission = float4(1.0f, 5.0f, 0.0f, 0.0f);
    game.progress = uint4(0u, action, phasePlaying, level);
    game.survival = float4(1.0f, 3.5f, 0.0f, 0.0f);
    game.stats.y = game.stats.x;
    game.stats.zw = uint2(0u);
    game.notice = uint4(noticeLevel, 0u, 0u, 0u);
}

void resetVoyage(device VoyageState &game) {
    game.stats = uint4(0u);
    startLevel(game, 0u, 0u);
}

kernel void initializeVoyage(device VoyageState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id == 0u) resetVoyage(states[0]);
}

kernel void advanceVoyage(constant ProgramUniforms &u [[buffer(0)]],
    device VoyageState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device VoyageState &game = states[0];
    float dt = u.pointer.w > 0.0f ? min(u.pointer.w, 0.10f)
        : min(u.resolutionTime.w, 0.10f);
    uint action = uint(u.pointer.z);
    if (game.progress.z == phaseLevelClear) {
        game.mission.z += dt;
        game.survival.z = max(0.0f, game.survival.z - dt);
        if (game.survival.z <= 0.0f) {
            startLevel(game, game.progress.w + 1u, action);
        }
        return;
    }
    if (action > game.progress.y) {
        if (game.progress.z == phaseVictory) {
            resetVoyage(game);
        } else if (game.progress.z == phaseFailure) {
            game.stats.x = game.stats.y;
            startLevel(game, game.progress.w, action);
        } else {
            game.mission.y = 5.0f;
        }
        game.progress.y = action;
    }
    if (game.progress.z != phasePlaying) return;

    // The Trackpad behaves as a virtual stick. Return it to centre to fly
    // straight. Space emits a sonar ping; cache pickup is automatic nearby.
    float2 stick = (u.pointer.xy - 0.5f) * 2.0f;
    stick = sign(stick) * max(abs(stick) - 0.10f, 0.0f) / 0.90f;
    float steering = clamp(u.parameters0.w, 0.4f, 2.0f);
    game.positionYaw.w += stick.x * 1.18f * steering * dt;
    game.velocityPitch.w = clamp(game.velocityPitch.w
        - stick.y * 0.76f * steering * dt,
        game.progress.w == 0u ? -1.32f : -0.82f,
        game.progress.w == 0u ? 1.32f : 0.72f);
    float3 forward = pixeltje_3d::forward(
        game.positionYaw.w, game.velocityPitch.w);
    float3 desired = forward * clamp(u.parameters0.x, 2.0f, 10.0f);
    game.velocityPitch.xyz = mix(game.velocityPitch.xyz, desired,
        min(1.0f, dt * 2.3f));
    float3 next = game.positionYaw.xyz + game.velocityPitch.xyz * dt;
    float floorLimit = floorHeight(next.xz, game.progress.w) + 1.25f;
    if (next.y < floorLimit) {
        next.y = floorLimit;
        game.velocityPitch.y = max(game.velocityPitch.y, 0.0f);
        game.mission.w = 0.45f;
    }
    if (next.y > -0.35f) {
        next.y = -0.35f;
        game.velocityPitch.y = min(game.velocityPitch.y, 0.0f);
    }
    for (uint i = 0u; i < 13u; ++i) {
        float2 xz = rockXZ[i];
        float h = 1.3f + 0.52f * float(i % 3u);
        float3 center = float3(xz.x,
            floorHeight(xz, game.progress.w) + h * 0.45f,
            xz.y);
        float3 radii = float3(1.5f + h * 0.38f, h,
            1.3f + h * 0.22f) + 0.5f;
        float3 offset = (next - center) / radii;
        float reach = length(offset);
        if (reach < 1.0f) {
            next = center + offset / max(reach, 0.001f) * radii;
            game.mission.w = 0.45f;
        }
    }
    float deck = floorHeight(float2(5.0f, -32.0f),
        game.progress.w) + 1.15f;
    bool struckWreck = false;
    struckWreck |= pushOutOfBox(next,
        float3(-0.55f, deck - 1.45f, -35.55f),
        float3(10.55f, deck + 1.35f, -28.45f));
    struckWreck |= pushOutOfBox(next,
        float3(1.75f, deck + 0.25f, -34.55f),
        float3(7.65f, deck + 3.35f, -30.45f));
    if (struckWreck) game.mission.w = 0.45f;
    next.y = clamp(next.y,
        floorHeight(next.xz, game.progress.w) + 1.25f, -0.35f);
    float mapHalfWidth = game.progress.w == 0u ? 220.0f : 62.0f;
    next.x = clamp(next.x, -mapHalfWidth, mapHalfWidth);
    next.z = clamp(next.z, -125.0f, 11.0f);
    game.positionYaw.xyz = next;
    float batterySeconds = clamp(u.parameters0.y, 90.0f, 900.0f)
        * (1.0f - 0.12f * float(game.progress.w));
    game.mission.x = max(0.0f,
        game.mission.x - dt / batterySeconds);
    game.mission.y = max(0.0f, game.mission.y - dt);
    game.mission.z += dt;
    game.mission.w = max(0.0f, game.mission.w - dt);
    game.survival.y = max(0.0f, game.survival.y - dt);
    float oxygenSeconds = clamp(u.parameters1.x, 90.0f, 1200.0f);
    if (next.y >= -0.65f) {
        if (game.survival.w == 0.0f && game.survival.x < 0.95f) {
            game.stats.z += 1u;
        }
        game.survival.w = 1.0f;
        float previousOxygen = game.survival.x;
        game.survival.x = min(1.0f, game.survival.x + dt / 4.0f);
        if (previousOxygen < 0.99f && game.survival.x >= 0.99f) {
            game.notice.x = noticeOxygen;
            game.survival.y = 2.4f;
        }
    } else {
        if (next.y < -1.5f) game.survival.w = 0.0f;
        game.survival.x = max(0.0f, game.survival.x - dt / oxygenSeconds);
    }
    float ascentSpeed = max(2.0f,
        clamp(u.parameters0.x, 2.0f, 10.0f) * 0.57f);
    float ascentTime = max(0.0f, -next.y - 0.65f) / ascentSpeed;
    game.notice.y = next.y < -0.65f
        && game.survival.x * oxygenSeconds <= ascentTime + 7.0f
        ? 1u : 0u;

    for (uint i = 0u; i < cacheCount; ++i) {
        if ((game.progress.x & (1u << i)) == 0u
            && distance(next, cachePosition(game.progress.w, i)) < 3.0f) {
            game.progress.x |= 1u << i;
            game.mission.y = 4.0f;
            game.mission.x = min(1.0f, game.mission.x + 0.035f);
            game.stats.x += 100u;
            game.notice.x = game.progress.x == allCachesMask
                ? noticeExit : noticeCoin;
            game.survival.y = game.progress.x == allCachesMask ? 5.0f : 2.0f;
        }
    }
    if (game.progress.x == allCachesMask
        && distance(next, homePosition) < 3.2f) {
        game.stats.x += 500u + uint(game.mission.x * 500.0f);
        if (game.progress.w + 1u == levelCount) {
            game.progress.z = phaseVictory;
        } else {
            game.progress.z = phaseLevelClear;
            game.survival.z = 3.0f;
        }
    }
    if (game.progress.z == phasePlaying
        && (game.survival.x <= 0.0f || game.mission.x <= 0.0f)) {
        game.progress.z = phaseFailure;
        game.stats.w = game.survival.x <= 0.0f ? 1u : 2u;
    }
}

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1u) & 2u, vertexID & 2u);
    ScreenVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

struct Ray {
    float3 origin;
    float3 direction;
};

struct Hit {
    float t;
    float3 normal;
    float3 albedo;
    float emission;
    uint material;
};

Ray cameraRay(float2 uv, float2 resolution, device const VoyageState &game) {
    Ray ray = {game.positionYaw.xyz,
        pixeltje_3d::cameraDirection(uv, resolution,
            game.positionYaw.w, game.velocityPitch.w, 1.02f)};
    return ray;
}

void addFloor(thread Hit &hit, Ray ray, uint level) {
    // Skip rays that cannot descend as far as the highest seabed. This keeps
    // the deeper first map inexpensive while looking across open water.
    float limit = min(hit.t, 200.0f);
    float highestFloor = level == 0u ? -85.0f : -18.0f;
    if (min(ray.origin.y, ray.origin.y + ray.direction.y * limit)
        > highestFloor) return;
    float t = 0.08f;
    for (uint step = 0u; step < 128u && t < limit; ++step) {
        float3 p = ray.origin + t * ray.direction;
        float gap = p.y - floorHeight(p.xz, level);
        if (gap < 0.035f) {
            float2 e = float2(0.08f, 0.0f);
            float3 normal = normalize(float3(
                floorHeight(p.xz - e.xy, level)
                    - floorHeight(p.xz + e.xy, level),
                0.16f,
                floorHeight(p.xz - e.yx, level)
                    - floorHeight(p.xz + e.yx, level)));
            float grain = hash21(floor(p.xz * 1.9f));
            float ridge = sin(p.x * 0.8f + sin(p.z * 0.4f)) * 0.5f + 0.5f;
            float3 sand = mix(float3(0.10f, 0.17f, 0.16f),
                float3(0.19f, 0.22f, 0.16f), ridge);
            sand *= 0.83f + 0.34f * grain;
            hit = {t, normal, sand, 0.0f, 1u};
            return;
        }
        t += clamp(gap * 0.54f, 0.10f, 2.2f);
    }
}

void addSphere(thread Hit &hit, Ray ray, float3 center, float3 radius,
    float3 albedo, float emission, uint material) {
    float3 normal;
    float t = pixeltje_3d::rayEllipsoid(ray.origin, ray.direction,
        center, radius, 0.02f, normal);
    if (t > 0.02f && t < hit.t) {
        hit = {t, normal, albedo, emission, material};
    }
}

void addBox(thread Hit &hit, Ray ray, float3 lower, float3 upper,
    float3 albedo, float emission, uint material) {
    float3 normal;
    float t = pixeltje_3d::rayBox(ray.origin, ray.direction,
        lower, upper, 0.02f, normal);
    if (t > 0.0f && t < hit.t)
        hit = {t, normal, albedo, emission, material};
}

void addCylinder(thread Hit &hit, Ray ray, float2 xz, float bottom,
    float top, float radius, float3 color) {
    float2 o = ray.origin.xz - xz;
    float2 d = ray.direction.xz;
    float a = dot(d, d);
    if (a < 0.00001f) return;
    float b = dot(o, d);
    float c = dot(o, o) - radius * radius;
    float disc = b * b - a * c;
    if (disc < 0.0f) return;
    float t = (-b - sqrt(disc)) / a;
    float y = ray.origin.y + t * ray.direction.y;
    if (t > 0.02f && t < hit.t && y >= bottom && y <= top) {
        float3 n = normalize(float3(o.x + t * d.x, 0.0f,
            o.y + t * d.y));
        hit = {t, n, color, 0.0f, 3u};
    }
}

// Cull detailed silhouettes before tracing their small constituent pieces.
bool rayNear(Ray ray, float3 center, float radius, float limit) {
    float along = dot(center - ray.origin, ray.direction);
    if (along < -radius || along > limit + radius) return false;
    return length(ray.origin + max(along, 0.0f) * ray.direction
        - center) < radius;
}

// The plant field is reconstructed from world cells, the saved program seed,
// and the level. It never depends on the current frame or camera position.
constant float plantCellSize = 6.0f;

void addPlantTriangle(thread Hit &hit, Ray ray, float3 a, float3 b,
    float3 c, float3 color, uint material) {
    float3 edge1 = b - a;
    float3 edge2 = c - a;
    float3 p = cross(ray.direction, edge2);
    float determinant = dot(edge1, p);
    if (abs(determinant) < 0.00001f) return;
    float inverse = 1.0f / determinant;
    float3 fromA = ray.origin - a;
    float u = dot(fromA, p) * inverse;
    if (u < 0.0f || u > 1.0f) return;
    float3 q = cross(fromA, edge1);
    float v = dot(ray.direction, q) * inverse;
    if (v < 0.0f || u + v > 1.0f) return;
    float t = dot(edge2, q) * inverse;
    if (t <= 0.02f || t >= hit.t) return;
    hit = {t, normalize(cross(edge1, edge2)), color, 0.0f, material};
}

void addPlantStem(thread Hit &hit, Ray ray, float3 a, float3 b,
    float radius, float3 color, uint material) {
    float3 axis = b - a;
    float3 origin = ray.origin - a;
    float axisLength2 = dot(axis, axis);
    float alongRay = dot(axis, ray.direction);
    float alongOrigin = dot(axis, origin);
    float A = axisLength2 - alongRay * alongRay;
    float B = axisLength2 * dot(origin, ray.direction)
        - alongOrigin * alongRay;
    float C = axisLength2 * dot(origin, origin)
        - alongOrigin * alongOrigin - radius * radius * axisLength2;
    float discriminant = B * B - A * C;
    if (A > 0.00001f && discriminant >= 0.0f) {
        float root = sqrt(discriminant);
        float t = (-B - root) / A;
        if (t <= 0.02f) t = (-B + root) / A;
        float projection = alongOrigin + t * alongRay;
        if (t > 0.02f && t < hit.t && projection > 0.0f
            && projection < axisLength2) {
            float3 point = ray.origin + t * ray.direction;
            float3 nearest = a + axis * (projection / axisLength2);
            hit = {t, normalize(point - nearest), color, 0.0f, material};
        }
    }
    addSphere(hit, ray, a, float3(radius), color, 0.0f, material);
    addSphere(hit, ray, b, float3(radius), color, 0.0f, material);
}

float3 plantRibbonPoint(float3 root, float height, float2 lean,
    float phase, float time, float fraction) {
    float bend = fraction * fraction;
    float2 current = float2(sin(time * 0.72f + phase + fraction),
        cos(time * 0.57f + phase * 1.3f + fraction));
    float2 horizontal = (lean + current * 0.24f) * bend;
    return root + float3(horizontal.x, height * fraction, horizontal.y);
}

void addPlantRibbon(thread Hit &hit, Ray ray, float3 root,
    float height, float width, float2 lean, float2 across,
    float phase, float time, float3 color, uint material) {
    for (uint segment = 0u; segment < 4u; ++segment) {
        float lower = float(segment) * 0.25f;
        float upper = lower + 0.25f;
        float3 a = plantRibbonPoint(root, height, lean, phase, time, lower);
        float3 b = plantRibbonPoint(root, height, lean, phase, time, upper);
        float lowerWidth = width * max(0.05f,
            sin(3.14159265f * lower));
        float upperWidth = width * max(0.05f,
            sin(3.14159265f * upper));
        float3 left0 = a - float3(across.x, 0.0f, across.y) * lowerWidth;
        float3 right0 = a + float3(across.x, 0.0f, across.y) * lowerWidth;
        float3 left1 = b - float3(across.x, 0.0f, across.y) * upperWidth;
        float3 right1 = b + float3(across.x, 0.0f, across.y) * upperWidth;
        addPlantTriangle(hit, ray, left0, right0, left1, color, material);
        addPlantTriangle(hit, ray, right0, right1, left1, color, material);
    }
}

void addPlantCell(thread Hit &hit, Ray ray, float2 cell, uint level,
    uint seed, float time, float density) {
    float cellReach = level == 0u ? 37.0f : 8.0f;
    if (cell.x < -cellReach || cell.x > cellReach || cell.y < -21.0f
        || cell.y > 1.0f) return;
    float2 key = cell + float2(float(seed & 0xffffu) * 0.013f,
        float(seed >> 16u) * 0.021f + float(level) * 23.7f);
    // Keep every frond inside its cell, so ray traversal cannot miss a leaf
    // belonging to a cell it has not entered yet.
    float2 xz = (cell + float2(0.43f + 0.14f * hash21(key + 1.0f),
        0.43f + 0.14f * hash21(key + 2.0f))) * plantCellSize;
    if (abs(xz.x) > (level == 0u ? 215.0f : 42.0f)
        || xz.y < -122.0f || xz.y > 3.0f) return;
    float bottom = floorHeight(xz, level);
    float depth = -bottom;
    float light = 1.0f - smoothstep(30.0f, 61.0f, depth);
    float chance = density * mix(0.28f, 0.72f, light);
    if (hash21(key + 3.0f) > min(chance, 0.88f)) return;

    // Decoration stays clear of objectives and the vessel silhouette.
    if (length(xz - homePosition.xz) < 7.0f
        || (xz.x > -3.0f && xz.x < 13.0f
            && xz.y > -40.0f && xz.y < -24.0f)) return;
    for (uint coin = 0u; coin < cacheCount; ++coin) {
        if (length(xz - cacheXZ[level * cacheCount + coin]) < 3.6f) return;
    }

    float choice = hash21(key + 4.0f);
    uint species = depth < 37.0f
        ? (choice < 0.25f ? 0u : choice < 0.64f ? 1u
            : choice < 0.84f ? 2u : 3u)
        : depth < 49.0f
            ? (choice < 0.10f ? 0u : choice < 0.40f ? 1u
                : choice < 0.62f ? 2u : 3u)
            : (choice < 0.17f ? 2u : 3u);
    float phase = hash21(key + 5.0f) * 6.2831853f;
    float size = 0.80f + 0.43f * hash21(key + 6.0f);
    float3 root = float3(xz.x, bottom + 0.03f, xz.y);
    float height = species == 0u ? 6.0f * size
        : species == 1u ? 1.65f * size
        : species == 2u ? 2.3f * size : 1.75f * size;
    if (!rayNear(ray, root + float3(0.0f, height * 0.5f, 0.0f),
        species == 0u ? 4.4f * size : 2.0f * size, hit.t)) return;

    if (species == 0u) {
        // Kelp has a flexible stipe and several wide side fronds.
        float2 drift = float2(sin(time * 0.72f + phase),
            cos(time * 0.57f + phase)) * 0.35f;
        float3 middle = root + float3(drift.x * 0.3f,
            height * 0.5f, drift.y * 0.3f);
        float3 tip = root + float3(drift.x, height, drift.y);
        float3 stem = float3(0.10f, 0.29f, 0.19f);
        addPlantStem(hit, ray, root, middle, 0.085f * size,
            stem, 3u);
        addPlantStem(hit, ray, middle, tip, 0.065f * size,
            stem, 3u);
        for (uint leaf = 0u; leaf < 5u; ++leaf) {
            float side = leaf % 2u == 0u ? -1.0f : 1.0f;
            float fraction = 0.19f + 0.15f * float(leaf);
            float3 attachment = mix(root, tip, fraction);
            float2 lean = float2(side * (1.10f + 0.075f * float(leaf)),
                0.24f * side);
            addPlantRibbon(hit, ray, attachment, 0.60f * size,
                0.25f * size, lean, float2(-lean.y, lean.x)
                    / length(lean), phase + float(leaf), time,
                float3(0.10f, 0.36f + 0.025f * float(leaf),
                    0.20f), 3u);
        }
    } else if (species == 1u) {
        // Eelgrass grows in a loose tuft of long, narrow blades.
        for (uint blade = 0u; blade < 5u; ++blade) {
            float angle = phase + float(blade) * 2.39996f;
            float2 out = float2(cos(angle), sin(angle));
            float3 bladeRoot = root + float3(out.x * 0.14f,
                0.0f, out.y * 0.14f);
            addPlantRibbon(hit, ray, bladeRoot,
                height * (0.76f + 0.08f * float(blade % 3u)),
                0.09f * size, out * (0.35f + 0.07f * float(blade)),
                float2(-out.y, out.x), phase + float(blade), time,
                float3(0.13f, 0.35f + 0.035f * float(blade % 3u),
                    0.19f), 3u);
        }
    } else if (species == 2u) {
        // Sea lettuce uses broad, slightly offset sheets.
        for (uint frond = 0u; frond < 3u; ++frond) {
            float angle = phase + float(frond) * 2.094f;
            float2 out = float2(cos(angle), sin(angle));
            addPlantRibbon(hit, ray, root + float3(out.x * 0.16f,
                0.0f, out.y * 0.16f),
                height * (0.84f + 0.08f * float(frond)),
                0.48f * size, out * 0.72f,
                float2(-out.y, out.x), phase + float(frond) * 1.8f,
                time, float3(0.21f, 0.47f, 0.23f), 3u);
        }
    } else {
        // Red algae branches from a low holdfast in the darker biomes.
        float3 red = float3(0.43f, 0.15f, 0.25f);
        for (uint branch = 0u; branch < 4u; ++branch) {
            float angle = phase + float(branch) * 1.5708f;
            float2 out = float2(cos(angle), sin(angle));
            float sway = sin(time * 0.55f + angle) * 0.14f;
            float3 end = root + float3(out.x * (0.40f + sway),
                height * (0.69f + 0.09f * float(branch % 3u)),
                out.y * (0.40f + sway));
            addPlantStem(hit, ray, root, end, 0.055f * size,
                red, 19u);
            addPlantRibbon(hit, ray, mix(root, end, 0.58f),
                0.48f * size, 0.16f * size, out * 0.53f,
                float2(-out.y, out.x), angle, time,
                float3(0.58f, 0.20f, 0.32f), 19u);
        }
    }
}

void addPlantField(thread Hit &hit, Ray ray, uint level, uint seed,
    float time, float density) {
    if (density <= 0.0f) return;
    float2 direction = ray.direction.xz;
    float2 cell = floor(ray.origin.xz / plantCellSize);
    for (uint visited = 0u; visited < 24u; ++visited) {
        addPlantCell(hit, ray, cell, level, seed, time, density);
        float nextX = (direction.x >= 0.0f ? cell.x + 1.0f : cell.x)
            * plantCellSize;
        float nextZ = (direction.y >= 0.0f ? cell.y + 1.0f : cell.y)
            * plantCellSize;
        float tx = abs(direction.x) > 0.00001f
            ? (nextX - ray.origin.x) / direction.x : 1.0e9f;
        float tz = abs(direction.y) > 0.00001f
            ? (nextZ - ray.origin.z) / direction.y : 1.0e9f;
        if (min(tx, tz) >= min(hit.t, 52.0f)) break;
        if (tx < tz) cell.x += direction.x >= 0.0f ? 1.0f : -1.0f;
        else cell.y += direction.y >= 0.0f ? 1.0f : -1.0f;
    }
}

float3 textureAlbedo(texture2d<float> image, float2 uv) {
    constexpr sampler materialSampler(coord::normalized,
        address::mirrored_repeat, filter::linear);
    float4 sample = image.sample(materialSampler, uv);
    float3 srgb = clamp(sample.rgb / max(sample.a, 0.001f),
        float3(0.0f), float3(1.0f));
    return pixeltje_3d::srgbToLinear(srgb);
}

void addSurface(thread Hit &hit, Ray ray, float time) {
    if (ray.direction.y <= 0.001f) return;
    float t = -ray.origin.y / ray.direction.y;
    if (t <= 0.02f || t >= hit.t) return;
    float3 p = ray.origin + ray.direction * t;
    float wave = sin(p.x * 0.55f + time * 0.8f)
        * cos(p.z * 0.42f - time * 0.7f);
    float3 normal = normalize(float3(-0.18f * cos(p.x * 0.55f),
        -1.0f, -0.14f * sin(p.z * 0.42f)));
    hit = {t, normal,
        float3(0.14f, 0.47f, 0.58f) + wave * 0.08f, 0.12f, 5u};
}

// Small details share the existing ray-traced scene. The near test keeps
// their constituent shapes off rays that cannot see them.
void addReefLife(thread Hit &hit, Ray ray, uint level, float time) {
    for (uint i = 0u; i < 20u; ++i) {
        float2 key = float2(float(i), float(level) * 7.0f);
        float2 xz = float2(-42.0f + 84.0f * hash21(key + 1.7f),
            -7.0f - 109.0f * hash21(key + 9.3f));
        float bottom = floorHeight(xz, level);
        float3 centre = float3(xz.x, bottom + 1.3f, xz.y);
        if (!rayNear(ray, centre, 3.0f, hit.t)) continue;
        uint variety = i % 2u;
        if (variety == 0u) {
            // Branching fan coral, with warm tips that catch the light.
            addSphere(hit, ray, float3(xz.x, bottom + 0.35f, xz.y),
                float3(0.34f, 0.45f, 0.28f),
                float3(0.36f, 0.16f, 0.20f), 0.0f, 8u);
            for (uint branch = 0u; branch < 5u; ++branch) {
                float side = float(branch) - 2.0f;
                float sway = sin(time * 0.7f + float(i)) * 0.09f;
                addSphere(hit, ray,
                    float3(xz.x + side * 0.33f + sway,
                        bottom + 1.0f + 0.22f * float(branch % 2u),
                        xz.y + 0.12f * side),
                    float3(0.16f, 0.82f, 0.17f),
                    float3(0.83f, 0.33f + 0.06f * side, 0.28f),
                    0.0f, 8u);
            }
        } else {
            // Sea anemone with a luminous centre and moving feelers.
            addSphere(hit, ray, float3(xz.x, bottom + 0.30f, xz.y),
                float3(0.65f, 0.28f, 0.65f),
                float3(0.38f, 0.18f, 0.43f), 0.0f, 8u);
            addSphere(hit, ray, float3(xz.x, bottom + 0.48f, xz.y),
                float3(0.28f, 0.13f, 0.28f),
                float3(0.84f, 0.51f, 0.76f), 0.22f, 10u);
            for (uint feeler = 0u; feeler < 6u; ++feeler) {
                float angle = float(feeler) * 1.047f;
                float sway = sin(time + float(feeler + i)) * 0.08f;
                addSphere(hit, ray,
                    float3(xz.x + cos(angle) * (0.38f + sway),
                        bottom + 0.92f, xz.y + sin(angle) * 0.38f),
                    float3(0.12f, 0.53f, 0.12f),
                    float3(0.72f, 0.39f, 0.59f), 0.0f, 10u);
            }
        }
    }

    for (uint i = 0u; i < 18u; ++i) {
        float2 key = float2(float(i) + 31.0f, float(level) * 5.0f);
        float2 xz = float2(-41.0f + 82.0f * hash21(key + 4.1f),
            -6.0f - 110.0f * hash21(key + 12.8f));
        float bottom = floorHeight(xz, level);
        if (!rayNear(ray, float3(xz.x, bottom + 0.3f, xz.y),
            1.8f, hit.t)) continue;
        // Pale scallops and spiral shells form small beds in the sand.
        for (uint shell = 0u; shell < 3u; ++shell) {
            float2 offset = float2(float(shell) * 0.48f - 0.5f,
                0.24f * float(shell % 2u));
            addSphere(hit, ray,
                float3(xz.x + offset.x, bottom + 0.12f, xz.y + offset.y),
                float3(0.37f, 0.13f, 0.28f),
                shell == 1u ? float3(0.92f, 0.70f, 0.57f)
                    : float3(0.73f, 0.78f, 0.66f), 0.0f, 11u);
        }
        if (i % 3u == 0u) {
            addSphere(hit, ray, float3(xz.x + 0.7f, bottom + 0.20f, xz.y),
                float3(0.26f), float3(0.23f, 0.16f, 0.29f),
                0.0f, 12u);
        }
    }

    for (uint i = 0u; i < 8u; ++i) {
        float phase = time * (0.5f + float(i) * 0.08f) + float(i) * 2.3f;
        float2 xz = float2(-29.0f + 58.0f
                * hash21(float2(float(i), 6.0f)) + sin(phase) * 1.2f,
            -16.0f - float(i) * 13.0f);
        float bottom = floorHeight(xz, level);
        float3 crab = float3(xz.x, bottom + 0.22f, xz.y);
        if (!rayNear(ray, crab, 1.7f, hit.t)) continue;
        float3 red = float3(0.66f, 0.23f, 0.16f);
        addSphere(hit, ray, crab, float3(0.52f, 0.23f, 0.42f),
            red, 0.0f, 13u);
        for (uint side = 0u; side < 2u; ++side) {
            float signSide = side == 0u ? -1.0f : 1.0f;
            addSphere(hit, ray, crab + float3(signSide * 0.70f, 0.04f,
                0.19f + sin(phase * 3.0f) * 0.08f),
                float3(0.25f, 0.16f, 0.28f), red * 1.14f,
                0.0f, 13u);
        }
    }

    for (uint i = 0u; i < 3u; ++i) {
        float phase = time * (0.23f + float(i) * 0.04f) + float(i) * 2.4f;
        float2 turtleXZ = float2((i == 0u ? -14.0f
                : i == 1u ? 14.0f : -26.0f)
                + sin(phase) * 5.0f,
            (i == 0u ? -38.0f : i == 1u ? -76.0f : -108.0f)
                + cos(phase) * 5.0f);
        float3 turtle = float3(turtleXZ.x,
            floorHeight(turtleXZ, level) + 12.0f
                + sin(phase * 1.2f), turtleXZ.y);
        if (!rayNear(ray, turtle, 2.5f, hit.t)) continue;
        float3 green = float3(0.24f, 0.43f, 0.29f);
        addSphere(hit, ray, turtle, float3(0.93f, 0.38f, 0.70f),
            green * 0.63f, 0.0f, 14u);
        addSphere(hit, ray, turtle + float3(0.82f, 0.04f, 0.0f),
            float3(0.32f), green, 0.0f, 14u);
        float flap = sin(time * 2.2f + float(i)) * 0.24f;
        for (uint side = 0u; side < 2u; ++side) {
            float signSide = side == 0u ? -1.0f : 1.0f;
            addSphere(hit, ray,
                turtle + float3(-0.10f, flap, signSide * 0.91f),
                float3(0.40f, 0.12f, 0.59f), green, 0.0f, 14u);
        }
    }

    for (uint i = 0u; i < 8u; ++i) {
        float2 xz = float2(-30.0f + float(i % 4u) * 18.0f,
            -11.0f - float(i) * 14.0f);
        float bottom = floorHeight(xz, level);
        if (!rayNear(ray, float3(xz.x, bottom + 0.8f, xz.y),
            2.0f, hit.t)) continue;
        if (i % 2u == 0u) {
            // Amphorae and pottery fragments near the wreck route.
            addSphere(hit, ray, float3(xz.x, bottom + 0.48f, xz.y),
                float3(0.43f, 0.58f, 0.43f),
                float3(0.43f, 0.27f, 0.17f), 0.0f, 15u);
            addCylinder(hit, ray, xz, bottom + 0.8f, bottom + 1.2f,
                0.19f, float3(0.54f, 0.31f, 0.18f));
        } else {
            addBox(hit, ray,
                float3(xz.x - 0.7f, bottom, xz.y - 0.2f),
                float3(xz.x + 0.7f, bottom + 0.32f, xz.y + 0.2f),
                float3(0.23f, 0.34f, 0.36f), 0.0f, 4u);
            addSphere(hit, ray, float3(xz.x, bottom + 0.42f, xz.y),
                float3(0.22f), float3(0.17f, 0.69f, 0.70f),
                0.65f, 6u);
        }
    }

    // Bubbles rise from vents along both the shallow and deep routes.
    for (uint vent = 0u; vent < 6u; ++vent) {
        float2 xz = float2(-24.0f + float(vent) * 10.0f,
            -18.0f - float(vent) * 18.0f);
        float bottom = floorHeight(xz, level);
        if (!rayNear(ray, float3(xz.x, bottom + 5.0f, xz.y),
            6.0f, hit.t)) continue;
        for (uint bubble = 0u; bubble < 5u; ++bubble) {
            float rise = fract(time * 0.22f + float(bubble) * 0.2f
                + float(vent) * 0.13f);
            float height = bottom + 0.4f + 9.0f * rise;
            float wobble = sin(time * 2.0f + float(bubble + vent)) * 0.24f;
            addSphere(hit, ray,
                float3(xz.x + wobble, height, xz.y + 0.2f * wobble),
                float3(0.08f + 0.05f * float(bubble % 3u)),
                float3(0.43f, 0.81f, 0.87f), 0.36f, 10u);
        }
    }
}

void addWorldObjects(thread Hit &hit, Ray ray, device const VoyageState &game,
    float time) {
    for (uint i = 0u; i < 13u; ++i) {
        float2 xz = rockXZ[i];
        float h = 1.3f + 0.52f * float(i % 3u);
        addSphere(hit, ray,
            float3(xz.x,
                floorHeight(xz, game.progress.w) + h * 0.45f, xz.y),
            float3(1.5f + h * 0.38f, h, 1.3f + h * 0.22f),
            float3(0.12f, 0.19f, 0.19f) + float(i % 3u) * 0.018f,
            0.0f, 2u);
    }
    // Reefs mark the route, with warm coral heads, blue anemones and pale
    // shell clusters at different heights above the sand.
    for (uint i = 0u; i < 12u; ++i) {
        float2 xz = reefXZ[i];
        float y = floorHeight(xz, game.progress.w);
        float3 center = float3(xz.x, y + 0.7f, xz.y);
        if (!rayNear(ray, center, 3.1f, hit.t)) continue;
        addSphere(hit, ray, center, float3(1.55f, 0.75f, 1.20f),
            float3(0.19f, 0.25f, 0.24f), 0.0f, 2u);
        for (uint branch = 0u; branch < 4u; ++branch) {
            float angle = float(branch) * 1.57f + float(i) * 0.8f;
            float2 offset = float2(cos(angle), sin(angle))
                * (0.42f + 0.14f * float(branch % 2u));
            float3 tip = center + float3(offset.x, 0.72f
                + 0.24f * float(branch % 3u), offset.y);
            float3 coral = branch % 2u == 0u
                ? float3(0.82f, 0.28f, 0.22f)
                : float3(0.76f, 0.46f, 0.28f);
            addSphere(hit, ray, tip, float3(0.35f, 0.48f, 0.35f),
                coral, 0.0f, 8u);
        }
        addSphere(hit, ray, center + float3(-0.7f, 0.66f, 0.3f),
            float3(0.47f, 0.17f, 0.47f),
            float3(0.22f, 0.66f, 0.72f), 0.12f, 8u);
        addSphere(hit, ray, center + float3(0.85f, 0.52f, 0.35f),
            float3(0.29f, 0.18f, 0.43f),
            float3(0.73f, 0.64f, 0.48f), 0.0f, 8u);
    }

    // A broken research vessel gives the middle of the map an unmistakable
    // navigational landmark, with a warm beacon above its opened deck.
    float2 wreckXZ = float2(5.0f, -32.0f);
    float deck = floorHeight(wreckXZ, game.progress.w) + 1.15f;
    addBox(hit, ray, float3(0.0f, deck - 0.9f, -35.0f),
        float3(10.0f, deck + 0.8f, -29.0f),
        float3(0.21f, 0.31f, 0.32f), 0.0f, 4u);
    addBox(hit, ray, float3(2.3f, deck + 0.8f, -34.0f),
        float3(7.1f, deck + 2.8f, -31.0f),
        float3(0.17f, 0.26f, 0.30f), 0.0f, 4u);
    addBox(hit, ray, float3(4.3f, deck + 2.8f, -33.0f),
        float3(4.65f, deck + 5.6f, -32.6f),
        float3(0.28f, 0.34f, 0.34f), 0.0f, 4u);
    addSphere(hit, ray, float3(4.48f, deck + 5.75f, -32.8f),
        float3(0.48f), float3(0.95f, 0.42f, 0.13f), 2.2f, 6u);
    for (uint i = 0u; i < 3u; ++i) {
        float x = 3.15f + float(i) * 1.45f;
        addSphere(hit, ray, float3(x, deck + 1.75f, -30.94f),
            float3(0.47f, 0.40f, 0.10f),
            float3(0.05f, 0.55f, 0.61f), 0.95f, 6u);
    }

    for (uint i = 0u; i < cacheCount; ++i) {
        if ((game.progress.x & (1u << i)) != 0u) continue;
        float3 p = cachePosition(game.progress.w, i);
        float bob = sin(time * 1.8f + float(i) * 2.0f) * 0.16f;
        addBox(hit, ray, p + float3(-0.75f, -0.7f, -0.47f),
            p + float3(0.75f, -0.05f, 0.47f),
            float3(0.35f, 0.22f, 0.10f), 0.0f, 4u);
        addSphere(hit, ray, p + float3(0.0f, 0.25f + bob, 0.0f),
            float3(0.55f, 0.44f, 0.55f),
            float3(0.92f, 0.58f, 0.16f), 0.0f, 17u);
        // A separate marker remains visible without making the gold emit.
        addSphere(hit, ray, p + float3(0.0f, 1.18f + bob, 0.0f),
            float3(0.12f), float3(1.0f, 0.77f, 0.31f), 2.2f, 6u);
        addCylinder(hit, ray, p.xz, p.y + 0.5f, p.y + 3.2f,
            0.055f, float3(0.78f, 0.50f, 0.18f));
    }

    // The home buoy becomes a conspicuous exit beacon after the fifth cache.
    addCylinder(hit, ray, float2(0.0f, 4.0f), -8.0f, -2.3f,
        0.10f, float3(0.21f, 0.34f, 0.39f));
    bool exitOpen = game.progress.x == allCachesMask;
    float beaconPulse = 0.7f + 0.3f * sin(time * 5.0f);
    addSphere(hit, ray, float3(0.0f, -2.1f, 4.0f),
        float3(exitOpen ? 1.1f : 0.62f),
        float3(0.18f, 0.86f, 0.87f),
        exitOpen ? 4.0f * beaconPulse : 2.0f, 6u);
    if (exitOpen) {
        for (uint i = 0u; i < 4u; ++i) {
            float angle = float(i) * 1.57f + time * 0.7f;
            addSphere(hit, ray,
                float3(cos(angle) * 1.65f, -2.1f, 4.0f + sin(angle) * 1.65f),
                float3(0.18f), float3(0.24f, 0.96f, 0.85f),
                3.0f, 6u);
        }
    }

    addReefLife(hit, ray, game.progress.w, time);

    // Several schools move through the middle depths. Fins, tails and eyes
    // turn the former single-ellipsoid markers into readable fish silhouettes.
    for (uint i = 0u; i < 24u; ++i) {
        float phase = time * (0.42f + float(i % 4u) * 0.08f)
            + float(i) * 2.17f;
        float school = float(i / 4u);
        float2 fishXZ = float2(-24.0f + school * 9.0f
                + sin(phase) * 3.8f + float(i % 4u) * 0.6f,
            -15.0f - school * 19.0f + cos(phase) * 2.0f);
        float3 fish = float3(fishXZ.x,
            floorHeight(fishXZ, game.progress.w) + 9.0f
                + sin(phase * 1.5f) * 0.5f, fishXZ.y);
        if (!rayNear(ray, fish, 1.3f, hit.t)) continue;
        float3 bodyColor = i % 3u == 0u
            ? float3(0.83f, 0.56f, 0.19f)
            : i % 3u == 1u ? float3(0.19f, 0.57f, 0.70f)
            : float3(0.55f, 0.71f, 0.52f);
        float tailBeat = sin(time * 7.0f + float(i)) * 0.13f;
        addSphere(hit, ray, fish, float3(0.55f, 0.23f, 0.26f),
            bodyColor, 0.0f, 7u);
        addSphere(hit, ray, fish + float3(-0.52f, 0.0f, tailBeat),
            float3(0.28f, 0.31f, 0.075f), bodyColor * 0.75f,
            0.0f, 7u);
        addSphere(hit, ray, fish + float3(-0.10f, 0.24f, 0.0f),
            float3(0.22f, 0.20f, 0.07f), bodyColor * 0.7f,
            0.0f, 7u);
        addSphere(hit, ray, fish + float3(0.31f, 0.08f, 0.22f),
            float3(0.065f), float3(0.015f, 0.027f, 0.03f),
            0.02f, 7u);
    }

    // Broad rays glide over the wreck and trench; a spotted back and
    // long tail make them distinct from the fish schools.
    for (uint i = 0u; i < 3u; ++i) {
        float phase = time * (0.31f + 0.07f * float(i))
            + float(i) * 2.4f;
        float2 rayXZ = float2((i == 0u ? -8.0f
                : i == 1u ? 15.0f : -19.0f)
                + sin(phase) * 5.0f,
            (i == 0u ? -27.0f : i == 1u ? -63.0f : -101.0f)
                + cos(phase) * 4.0f);
        float3 rayCenter = float3(rayXZ.x,
            floorHeight(rayXZ, game.progress.w) + 8.0f
                + sin(phase * 1.3f) * 0.65f, rayXZ.y);
        if (!rayNear(ray, rayCenter, 3.5f, hit.t)) continue;
        float wing = sin(time * 2.4f + float(i) * 1.7f) * 0.30f;
        float3 blue = float3(0.20f, 0.36f, 0.47f);
        addSphere(hit, ray, rayCenter,
            float3(0.75f, 0.20f, 1.10f), blue, 0.0f, 9u);
        for (uint side = 0u; side < 2u; ++side) {
            float signSide = side == 0u ? -1.0f : 1.0f;
            addSphere(hit, ray, rayCenter + float3(signSide * 1.05f,
                wing, -0.10f), float3(1.15f, 0.13f, 0.62f),
                blue * 0.84f, 0.0f, 9u);
        }
        addSphere(hit, ray, rayCenter + float3(0.0f, 0.0f, 1.50f),
            float3(0.055f, 0.055f, 1.05f), blue * 0.68f,
            0.0f, 9u);
    }

    // Bioluminescent jellies drift near the taller kelp stands.
    for (uint i = 0u; i < 6u; ++i) {
        float phase = time * 0.48f + float(i) * 1.9f;
        float2 jellyXZ = float2(-19.0f + float(i) * 8.0f
                + sin(phase) * 1.2f,
            -22.0f - float(i) * 17.0f);
        float3 jelly = float3(jellyXZ.x,
            floorHeight(jellyXZ, game.progress.w) + 14.0f
                - float(i % 2u) * 2.0f + sin(phase * 1.4f),
            jellyXZ.y);
        if (!rayNear(ray, jelly, 2.2f, hit.t)) continue;
        float3 glow = i % 2u == 0u
            ? float3(0.30f, 0.78f, 0.92f)
            : float3(0.80f, 0.42f, 0.84f);
        addSphere(hit, ray, jelly,
            float3(0.75f, 0.42f, 0.75f), glow, 0.50f, 10u);
        for (uint strand = 0u; strand < 5u; ++strand) {
            float angle = float(strand) * 1.26f;
            float2 offset = float2(cos(angle), sin(angle)) * 0.38f;
            float2 tentacle = jelly.xz + offset
                + float2(sin(phase * 2.0f + float(strand)) * 0.14f,
                    cos(phase * 1.7f + float(strand)) * 0.14f);
            addCylinder(hit, ray, tentacle, jelly.y - 1.65f,
                jelly.y - 0.15f, 0.035f, glow * 0.72f);
        }
    }

    {
        // The two forward-facing searchlights stay attached to the hull.
        float3 forward = pixeltje_3d::forward(game.positionYaw.w,
            game.velocityPitch.w);
        float3 right = normalize(cross(forward, float3(0.0f, 1.0f, 0.0f)));
        float3 up = normalize(cross(right, forward));
        for (uint side = 0u; side < 2u; ++side) {
            float signSide = side == 0u ? -1.0f : 1.0f;
            float3 mount = submarineLampMount(game, signSide);
            float3 strut = game.positionYaw.xyz
                + right * signSide * 0.74f
                + forward * 0.72f - up * 0.24f;
            addSphere(hit, ray, strut, float3(0.17f),
                float3(0.15f, 0.23f, 0.26f), 0.0f, 16u);
            addSphere(hit, ray, mount, float3(0.29f),
                float3(0.13f, 0.22f, 0.25f), 0.0f, 16u);
            float3 lensColor = side == 0u
                ? float3(1.0f, 0.68f, 0.37f)
                : float3(0.43f, 0.86f, 1.0f);
            addSphere(hit, ray,
                mount + submarineLampDirection(game, signSide) * 0.28f,
                float3(0.18f), lensColor, 2.8f, 18u);
        }
    }
}

// Roughness and metalness are material properties in linear light. Textures
// provide base color; they are decoded from sRGB before evaluating the BRDF.
float2 surfaceResponse(uint material) {
    switch (material) {
        case 1u: return float2(0.92f, 0.0f);  // sand
        case 2u: return float2(0.80f, 0.0f);  // stone
        case 3u: return float2(0.79f, 0.0f);  // plants
        case 4u: return float2(0.54f, 0.74f); // corroded metal
        case 5u: return float2(0.13f, 0.0f);  // water surface
        case 6u: return float2(0.28f, 0.0f);  // glowing glass
        case 7u: return float2(0.46f, 0.0f);  // fish
        case 8u: return float2(0.83f, 0.0f);  // coral
        case 9u: return float2(0.49f, 0.0f);  // ray
        case 10u: return float2(0.25f, 0.0f); // jellyfish
        case 11u: return float2(0.35f, 0.0f); // shells
        case 12u: return float2(0.82f, 0.0f); // urchin
        case 13u: return float2(0.47f, 0.0f); // crab
        case 14u: return float2(0.58f, 0.0f); // turtle
        case 15u: return float2(0.76f, 0.0f); // ceramic
        case 16u: return float2(0.40f, 0.75f); // lamp housing
        case 17u: return float2(0.24f, 0.98f); // gold coin
        case 18u: return float2(0.16f, 0.0f); // lamp lens
        case 19u: return float2(0.82f, 0.0f); // red algae
        default: return float2(0.80f, 0.0f);
    }
}

// Cook-Torrance microfacet reflection: GGX distribution and Smith masking,
// Schlick Fresnel, and an energy-conserving Lambert diffuse lobe.
float3 evaluateBRDF(float3 baseColor, float roughness, float metallic,
    float3 normal, float3 view, float3 light, float3 radiance) {
    float nDotL = max(dot(normal, light), 0.0f);
    float nDotV = max(dot(normal, view), 0.0f);
    if (nDotL <= 0.0f || nDotV <= 0.0f) return float3(0.0f);
    float3 halfVector = normalize(view + light);
    float nDotH = max(dot(normal, halfVector), 0.0f);
    float vDotH = max(dot(view, halfVector), 0.0f);
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float denominator = nDotH * nDotH * (alpha2 - 1.0f) + 1.0f;
    float distribution = alpha2
        / max(3.14159265f * denominator * denominator, 0.0001f);
    float maskingV = 2.0f * nDotV
        / (nDotV + sqrt(alpha2 + (1.0f - alpha2) * nDotV * nDotV));
    float maskingL = 2.0f * nDotL
        / (nDotL + sqrt(alpha2 + (1.0f - alpha2) * nDotL * nDotL));
    float geometry = maskingV * maskingL;
    float3 f0 = mix(float3(0.04f), baseColor, metallic);
    float3 fresnel = pixeltje_3d::fresnelSchlick(vDotH, f0);
    float3 specular = distribution * geometry * fresnel
        / max(4.0f * nDotV * nDotL, 0.0001f);
    float3 diffuse = (float3(1.0f) - fresnel)
        * (1.0f - metallic) * baseColor / 3.14159265f;
    return (diffuse + specular) * radiance * nDotL;
}

float3 pointLightBRDF(float3 position, float3 pointPosition,
    float3 pointColor, float power, float range,
    float visibility,
    float3 baseColor, float roughness, float metallic,
    float3 normal, float3 view) {
    float3 toLight = pointPosition - position;
    float distanceSquared = dot(toLight, toLight);
    float distance = sqrt(max(distanceSquared, 0.0001f));
    if (distance >= range) return float3(0.0f);
    // A finite emitter avoids a blown-out patch beside the submarine while
    // retaining inverse-square falloff over the useful reach of each lamp.
    float reach = 1.0f - smoothstep(range * 0.70f, range, distance);
    float attenuation = reach / (distanceSquared + 16.0f);
    float3 waterPath = exp(-distance * visibility
        * float3(0.028f, 0.015f, 0.010f));
    return evaluateBRDF(baseColor, roughness, metallic,
        normal, view, toLight / distance,
        pointColor * waterPath * power * attenuation);
}

// The beam opens from the lens at a fixed angle instead of illuminating a
// sphere around the hull. A soft outer edge keeps the projected spot natural.
float searchlightCone(float3 point, float3 mount, float3 forward) {
    float3 offset = point - mount;
    float along = dot(offset, forward);
    if (along <= 0.0f || along >= 52.0f) return 0.0f;
    float radius = 0.18f + along * 0.105f;
    float radial = length(offset - forward * along);
    return (1.0f - smoothstep(radius * 0.72f, radius, radial))
        * smoothstep(0.05f, 0.8f, along)
        * (1.0f - smoothstep(40.0f, 52.0f, along));
}

float3 shadeWorld(Hit hit, Ray ray, float time, float3 water,
    float visibility, device const VoyageState &game,
    texture2d<float> sandTexture,
    texture2d<float> reefTexture, texture2d<float> wreckTexture,
    texture2d<float> greenPlantTexture,
    texture2d<float> redPlantTexture) {
    if (hit.material == 0u) return water;
    float3 position = ray.origin + ray.direction * hit.t;
    float depthMetres = max(-position.y, 0.0f);
    float3 baseColor = hit.albedo;
    float3 materialSample = float3(0.5f);
    if (hit.material == 1u) {
        materialSample = textureAlbedo(sandTexture, position.xz * 0.075f);
        baseColor = mix(baseColor, materialSample, 0.62f);
    } else if (hit.material == 2u || hit.material == 8u) {
        materialSample = textureAlbedo(reefTexture,
            position.xz * 0.16f + position.y * 0.045f);
        baseColor = mix(baseColor, materialSample * (hit.material == 8u
            ? float3(1.10f, 0.65f, 0.72f) : float3(0.68f)),
            hit.material == 8u ? 0.28f : 0.55f);
    } else if (hit.material == 4u) {
        materialSample = textureAlbedo(wreckTexture,
            position.xz * 0.17f + position.y * 0.035f);
        baseColor = mix(baseColor,
            materialSample * float3(0.70f, 0.90f, 0.92f), 0.60f);
    } else if (hit.material == 3u || hit.material == 19u) {
        float2 plantUV = position.xz * 0.42f + position.y * 0.12f;
        float3 surface = hit.material == 3u
            ? textureAlbedo(greenPlantTexture, plantUV)
            : textureAlbedo(redPlantTexture, plantUV);
        baseColor = mix(baseColor, surface * 0.75f + baseColor * 0.25f,
            0.38f);
    }
    if (hit.material == 7u) {
        float stripe = 0.80f + 0.20f
            * smoothstep(-0.2f, 0.2f, sin(position.x * 19.0f));
        baseColor *= stripe;
    } else if (hit.material == 9u) {
        float spots = hash21(floor(position.xz * 4.5f));
        baseColor += float3(0.04f, 0.10f, 0.13f) * step(0.84f, spots);
    } else if (hit.material == 11u) {
        baseColor *= 0.80f + 0.20f
            * sin(position.x * 43.0f + position.z * 29.0f);
    } else if (hit.material == 13u || hit.material == 14u) {
        float mottling = hash21(floor(position.xz * 13.0f));
        baseColor *= 0.82f + 0.24f * mottling;
    }
    baseColor = max(baseColor, float3(0.0f));
    float2 response = surfaceResponse(hit.material);
    float roughness = response.x;
    float metallic = response.y;
    float3 normal = normalize(hit.normal);
    float grain = sin(position.x * 3.1f + position.y * 2.7f)
        * cos(position.z * 3.7f - position.y * 1.9f);
    float bumpStrength = 0.0f;
    if (hit.material == 1u) {
        roughness = clamp(roughness + grain * 0.055f, 0.80f, 0.98f);
        bumpStrength = 0.055f;
    } else if (hit.material == 2u || hit.material == 8u) {
        roughness = clamp(roughness + grain * 0.11f, 0.55f, 0.98f);
        bumpStrength = 0.14f;
    } else if (hit.material == 4u) {
        // Warm oxide in the generated hull albedo is rough dielectric;
        // exposed cool metal keeps a tighter, metallic reflection.
        float oxide = smoothstep(-0.04f, 0.15f,
            materialSample.r - max(materialSample.g, materialSample.b));
        metallic = mix(0.78f, 0.06f, oxide);
        roughness = clamp(mix(0.48f, 0.88f, oxide)
            + grain * 0.055f, 0.40f, 0.96f);
        bumpStrength = 0.10f;
    } else if (hit.material == 11u || hit.material == 15u) {
        roughness = clamp(roughness + grain * 0.07f, 0.25f, 0.96f);
        bumpStrength = 0.045f;
    } else if (hit.material == 17u) {
        roughness = clamp(roughness + grain * 0.025f, 0.16f, 0.34f);
        bumpStrength = 0.012f;
    }
    if (bumpStrength > 0.0f) {
        float3 detail = float3(
            sin(position.x * 8.1f + position.z * 2.3f),
            cos(position.y * 9.7f - position.x * 3.2f),
            sin(position.z * 8.8f + position.y * 2.6f));
        float3 tangentDetail = detail - normal * dot(detail, normal);
        float fade = 1.0f - smoothstep(18.0f, 70.0f, hit.t);
        normal = normalize(normal + tangentDetail * bumpStrength * fade);
    }
    float3 view = normalize(ray.origin - position);
    if (dot(normal, view) < 0.0f) normal = -normal;

    // Spectral attenuation removes red sunlight first as the sea deepens.
    float3 sunTransmittance = exp(-depthMetres
        * float3(0.080f, 0.037f, 0.023f));
    float3 sunRadiance = float3(2.8f, 2.7f, 2.4f)
        * sunTransmittance;
    if (hit.material == 1u || hit.material == 2u) {
        float caustic = sin(position.x * 2.1f + time * 1.9f
            + sin(position.z * 1.5f - time))
            * sin(position.z * 1.7f - time * 1.4f);
        sunRadiance += float3(0.04f, 0.12f, 0.14f)
            * max(caustic, 0.0f) * sunTransmittance;
    }
    float3 sunDirection = normalize(float3(0.38f, 0.88f, -0.26f));
    float3 color = evaluateBRDF(baseColor, roughness, metallic,
        normal, view, sunDirection, sunRadiance);

    // Approximate broad underwater irradiance, with a small lower-hemisphere
    // bounce. Both fade with depth; metal receives no diffuse ambient light.
    float hemisphere = clamp(normal.y * 0.5f + 0.5f, 0.0f, 1.0f);
    float3 ambient = mix(
        float3(0.025f, 0.038f, 0.048f)
            * exp(-depthMetres * 0.030f),
        float3(0.45f, 0.62f, 0.72f) * sunTransmittance,
        hemisphere);
    float3 f0 = mix(float3(0.04f), baseColor, metallic);
    float nDotV = max(dot(normal, view), 0.0f);
    float3 viewFresnel = f0 + (float3(1.0f) - f0)
        * pow(1.0f - nDotV, 5.0f);
    color += (float3(1.0f) - viewFresnel) * (1.0f - metallic)
        * baseColor * ambient / 3.14159265f;
    color += viewFresnel * water * pow(1.0f - roughness, 2.0f) * 0.18f;

    // A little local spill reveals the lamp housings; most of the light is
    // projected forward in the same cones that scatter through the water.
    float lampPower = 420.0f * (1.0f + 0.65f * smoothstep(90.0f,
        325.0f, max(-game.positionYaw.y, 0.0f)));
    for (uint side = 0u; side < 2u; ++side) {
        float signSide = side == 0u ? -1.0f : 1.0f;
        float3 mount = submarineLampMount(game, signSide);
        float3 lampColor = side == 0u
            ? float3(1.0f, 0.80f, 0.62f)
            : float3(0.68f, 0.86f, 1.0f);
        float cone = searchlightCone(position, mount,
            submarineLampDirection(game, signSide));
        color += pointLightBRDF(position, mount, lampColor,
            25.0f, 7.0f, visibility,
            baseColor, roughness, metallic,
            normal, view);
        if (cone > 0.001f) {
            color += pointLightBRDF(position, mount, lampColor,
                lampPower * cone, 52.0f, visibility,
                baseColor, roughness, metallic, normal, view);
        }
    }
    color += baseColor * hit.emission;

    // Keep long-distance underwater absorption without washing a translucent
    // veil over nearby materials and their point-light highlights.
    float3 transmittance = exp(-hit.t * visibility
        * float3(0.018f, 0.011f, 0.008f));
    if (hit.emission > 0.0f) {
        transmittance = mix(transmittance, float3(1.0f), 0.18f);
    }
    return color * transmittance
        + water * (float3(1.0f) - transmittance);
}

float3 searchlightHaze(Ray ray, float hitDistance, float visibility,
    float time, device const VoyageState &game) {
    float3 haze = float3(0.0f);
    for (uint side = 0u; side < 2u; ++side) {
        float signSide = side == 0u ? -1.0f : 1.0f;
        float3 mount = submarineLampMount(game, signSide);
        float3 forward = submarineLampDirection(game, signSide);
        float3 lampColor = side == 0u
            ? float3(0.040f, 0.058f, 0.056f)
            : float3(0.029f, 0.052f, 0.072f);
        for (uint sampleIndex = 0u; sampleIndex < 12u; ++sampleIndex) {
            float t = 1.75f + 3.5f * float(sampleIndex);
            if (t >= hitDistance) break;
            float3 samplePosition = ray.origin + ray.direction * t;
            float cone = searchlightCone(samplePosition, mount, forward);
            if (cone <= 0.0f) continue;
            // Slowly moving density breaks up the beam without a bright,
            // uniform veil across the entire image.
            float density = 0.85f + 0.15f * sin(samplePosition.x * 0.57f
                + samplePosition.y * 0.29f - samplePosition.z * 0.37f
                + time * 0.36f);
            float waterPath = exp(-visibility * (t * 0.035f
                + distance(samplePosition, mount) * 0.025f));
            haze += lampColor * cone * density * waterPath;
        }
    }
    return haze;
}

float ring(float2 p, float radius, float width) {
    return 1.0f - smoothstep(width * 0.35f, width,
        abs(length(p) - radius));
}

float disc(float2 p, float radius) {
    return 1.0f - smoothstep(radius - 1.0f, radius + 1.0f,
        length(p));
}

float3 overlay(float3 original, float3 paint, float alpha) {
    return mix(original, paint, clamp(alpha, 0.0f, 1.0f));
}

// Text strings are shaped by Core Text once per run. The buffer contains
// normalized font outlines, run positions, and line-segment contours.
constant uint textLevel = 0u;
constant uint textScore = 1u;
constant uint textBattery = 2u;
constant uint textOxygen = 3u;
constant uint textCoins = 4u;
constant uint textFindCoins = 5u;
constant uint textCoinFound = 6u;
constant uint textExitOpen = 7u;
constant uint textReturnBuoy = 8u;
constant uint textSurfaceOxygen = 9u;
constant uint textOxygenFull = 10u;
constant uint textLevelClear = 11u;
constant uint textNextLevel = 12u;
constant uint textVictory = 13u;
constant uint textOxygenEmpty = 14u;
constant uint textBatteryEmpty = 15u;
constant uint textRetry = 16u;
constant uint textPlayAgain = 17u;
constant uint textSonar = 18u;
constant uint textSlash = 19u;
constant uint textDepth = 20u;
constant uint textMetres = 21u;
constant uint textDigitZero = 22u;
constant uint hudCapacity = 256u;

struct HUDGlyph {
    float4 geometry; // glyph index, baseline x/y in UI units, font size
    float4 ink;      // display-referred sRGB and opacity
};

float4 fontRun(device const float4 *font, uint index) {
    return font[uint(font[0].y) + index];
}

float runWidth(device const float4 *font, uint index, float size) {
    return fontRun(font, index).z * size;
}

void addRun(device HUDGlyph *glyphs, thread uint &count,
    device const float4 *font, uint runID, float2 origin, float size,
    float3 ink, float opacity = 1.0f) {
    float4 run = fontRun(font, runID);
    uint start = uint(run.x);
    uint length = uint(run.y);
    for (uint i = 0u; i < length && count < hudCapacity; ++i) {
        float4 placement = font[uint(font[0].z) + start + i];
        glyphs[count].geometry = float4(placement.x,
            origin.x + placement.y * size,
            origin.y + (font[2].x - placement.z) * size, size);
        glyphs[count].ink = float4(ink, opacity);
        count += 1u;
    }
}

void addCentered(device HUDGlyph *glyphs, thread uint &count,
    device const float4 *font, uint runID, float centerX, float y,
    float size, float3 ink, float opacity = 1.0f) {
    addRun(glyphs, count, font, runID,
        float2(centerX - runWidth(font, runID, size) * 0.5f, y),
        size, ink, opacity);
}

void addNumber(device HUDGlyph *glyphs, thread uint &count,
    device const float4 *font, uint value, float2 origin,
    float size, float3 ink) {
    uint divisor = 1u;
    while (value / divisor >= 10u && divisor < 1000000000u) divisor *= 10u;
    while (divisor > 0u) {
        uint digit = (value / divisor) % 10u;
        uint run = textDigitZero + digit;
        addRun(glyphs, count, font, run, origin, size, ink);
        origin.x += runWidth(font, run, size);
        divisor /= 10u;
    }
}

kernel void buildHUDGlyphs(constant ProgramUniforms &u [[buffer(0)]],
    device const VoyageState *states [[buffer(1)]],
    device const float4 *font [[buffer(2)]],
    device HUDGlyph *glyphs [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    for (uint i = 0u; i < hudCapacity; ++i) {
        glyphs[i].geometry = float4(0.0f);
        glyphs[i].ink = float4(0.0f);
    }
    device const VoyageState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float scale = min(resolution.x / 960.0f, resolution.y / 600.0f);
    float2 uiSize = resolution / scale;
    uint count = 0u;
    const float3 ink = float3(0.82f, 0.96f, 0.93f);
    const float3 gold = float3(1.0f, 0.78f, 0.34f);
    const float3 cyan = float3(0.37f, 1.0f, 0.94f);
    const float3 warningInk = float3(1.0f, 0.36f, 0.23f);
    addRun(glyphs, count, font, textLevel, float2(44.0f, 18.0f), 12.6f, ink);
    addNumber(glyphs, count, font, game.progress.w + 1u,
        float2(115.0f, 18.0f), 12.6f, gold);
    addRun(glyphs, count, font, textSlash, float2(128.0f, 18.0f), 12.6f, ink);
    addNumber(glyphs, count, font, levelCount,
        float2(140.0f, 18.0f), 12.6f, ink);
    addRun(glyphs, count, font, textScore, float2(244.0f, 18.0f), 12.6f, ink);
    addNumber(glyphs, count, font, game.stats.x,
        float2(314.0f, 18.0f), 12.6f, gold);
    addRun(glyphs, count, font, textDepth, float2(450.0f, 18.0f), 12.6f, ink);
    uint depthMetres = uint(max(-game.positionYaw.y, 0.0f) + 0.5f);
    addNumber(glyphs, count, font, depthMetres,
        float2(521.0f, 18.0f), 12.6f, cyan);
    addRun(glyphs, count, font, textMetres, float2(552.0f, 18.0f), 12.6f, ink);
    uint foundCount = 0u;
    for (uint i = 0u; i < cacheCount; ++i) {
        if ((game.progress.x & (1u << i)) != 0u) foundCount++;
    }
    addRun(glyphs, count, font, textCoins, float2(44.0f, 78.0f), 10.5f, ink);
    addNumber(glyphs, count, font, foundCount,
        float2(100.0f, 78.0f), 10.5f, gold);
    addRun(glyphs, count, font, textSlash, float2(111.0f, 78.0f), 10.5f, ink);
    addNumber(glyphs, count, font, cacheCount,
        float2(122.0f, 78.0f), 10.5f, ink);
    addRun(glyphs, count, font, textBattery,
        float2(50.0f, uiSize.y - 99.0f), 11.2f, ink);
    addRun(glyphs, count, font, textOxygen,
        float2(50.0f, uiSize.y - 60.0f), 11.2f, ink);
    addRun(glyphs, count, font, textSonar,
        float2(uiSize.x - 117.0f, 111.0f), 10.5f, ink);
    if (game.progress.z == phasePlaying) {
        if (game.progress.x == allCachesMask) {
            addCentered(glyphs, count, font, textExitOpen,
                uiSize.x * 0.5f, 94.0f, 16.8f, cyan);
            addCentered(glyphs, count, font, textReturnBuoy,
                uiSize.x * 0.5f, 118.0f, 12.6f, ink);
            if (game.notice.y != 0u) {
                addCentered(glyphs, count, font, textSurfaceOxygen,
                    uiSize.x * 0.5f, 145.0f, 11.9f, warningInk);
            }
        } else if (game.notice.y != 0u) {
            float opacity = 0.65f + 0.35f * sin(game.mission.z * 8.0f);
            addCentered(glyphs, count, font, textSurfaceOxygen,
                uiSize.x * 0.5f, 98.0f, 14.7f, warningInk, opacity);
        } else if (game.survival.y > 0.0f && game.notice.x == noticeOxygen) {
            addCentered(glyphs, count, font, textOxygenFull,
                uiSize.x * 0.5f, 101.0f, 14.0f, cyan);
        } else if (game.survival.y > 0.0f && game.notice.x == noticeCoin) {
            addCentered(glyphs, count, font, textCoinFound,
                uiSize.x * 0.5f, 101.0f, 14.0f, gold);
        } else {
            addCentered(glyphs, count, font, textFindCoins,
                uiSize.x * 0.5f, 101.0f, 12.6f, ink);
        }
    } else if (game.progress.z == phaseLevelClear) {
        addCentered(glyphs, count, font, textLevelClear,
            uiSize.x * 0.5f, uiSize.y * 0.5f - 35.0f, 23.1f, cyan);
        addCentered(glyphs, count, font, textNextLevel,
            uiSize.x * 0.5f, uiSize.y * 0.5f + 16.0f, 14.0f, ink);
    } else if (game.progress.z == phaseVictory) {
        addCentered(glyphs, count, font, textVictory,
            uiSize.x * 0.5f, uiSize.y * 0.5f - 42.0f, 20.3f, gold);
        addCentered(glyphs, count, font, textPlayAgain,
            uiSize.x * 0.5f, uiSize.y * 0.5f + 18.0f, 12.6f, ink);
    } else {
        addCentered(glyphs, count, font,
            game.stats.w == 1u ? textOxygenEmpty : textBatteryEmpty,
            uiSize.x * 0.5f, uiSize.y * 0.5f - 42.0f, 21.0f, warningInk);
        addCentered(glyphs, count, font, textRetry,
            uiSize.x * 0.5f, uiSize.y * 0.5f + 18.0f, 12.6f, ink);
    }
    if (game.progress.z != phasePlaying) {
        addRun(glyphs, count, font, textScore,
            float2(uiSize.x * 0.5f - 65.0f,
                uiSize.y * 0.5f - 4.0f), 11.2f, ink);
        addNumber(glyphs, count, font, game.stats.x,
            float2(uiSize.x * 0.5f + 3.0f,
                uiSize.y * 0.5f - 4.0f), 11.2f, gold);
    }
}

struct HUDVertex {
    float4 position [[position]];
    float2 local;
    float4 ink;
    uint glyphIndex [[flat]];
    float pixelScale;
};

vertex HUDVertex hudVertex(uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const float4 *font [[buffer(1)]],
    device const HUDGlyph *glyphs [[buffer(2)]]) {
    HUDVertex result;
    HUDGlyph instance = glyphs[instanceID];
    uint glyph = uint(instance.geometry.x);
    float4 boundsA = font[uint(font[0].x) + glyph * 2u];
    float4 boundsB = font[uint(font[0].x) + glyph * 2u + 1u];
    float scale = min(u.resolutionTime.x / 960.0f,
        u.resolutionTime.y / 600.0f);
    float pixelScale = max(instance.geometry.w * scale, 1.0f);
    float pad = 1.0f / pixelScale;
    float2 lower = boundsA.zw - pad;
    float2 upper = boundsB.xy + pad;
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    float2 local = mix(lower, upper, corners[vertexID]);
    float2 pixel = float2(instance.geometry.y + local.x * instance.geometry.w,
        instance.geometry.z - local.y * instance.geometry.w) * scale;
    result.position = instance.ink.w > 0.0f && boundsA.y > 0.0f
        ? float4(pixel.x * 2.0f / u.resolutionTime.x - 1.0f,
            1.0f - pixel.y * 2.0f / u.resolutionTime.y, 0.0f, 1.0f)
        : float4(-2.0f, -2.0f, 0.0f, 1.0f);
    result.local = local;
    result.ink = instance.ink;
    result.glyphIndex = glyph;
    result.pixelScale = pixelScale;
    return result;
}

fragment float4 hudFragment(HUDVertex in [[stage_in]],
    device const float4 *font [[buffer(1)]]) {
    float4 record = font[uint(font[0].x) + in.glyphIndex * 2u];
    uint start = uint(record.x);
    uint count = uint(record.y);
    float nearest = 1000.0f;
    int winding = 0;
    for (uint i = 0u; i < count; ++i) {
        float4 segment = font[uint(font[0].w) + start + i];
        float2 a = segment.xy;
        float2 b = segment.zw;
        float2 edge = b - a;
        float t = clamp(dot(in.local - a, edge) /
            max(dot(edge, edge), 0.00000001f), 0.0f, 1.0f);
        nearest = min(nearest, length(in.local - (a + t * edge)));
        float crossValue = edge.x * (in.local.y - a.y)
            - edge.y * (in.local.x - a.x);
        if (a.y <= in.local.y && b.y > in.local.y && crossValue > 0.0f) {
            winding++;
        } else if (b.y <= in.local.y && a.y > in.local.y
            && crossValue < 0.0f) {
            winding--;
        }
    }
    float signedDistance = winding != 0 ? nearest : -nearest;
    float coverage = clamp(0.5f + signedDistance * in.pixelScale,
        0.0f, 1.0f);
    return float4(in.ink.rgb, coverage * in.ink.w);
}

float2 sonarTarget(device const VoyageState &game,
    thread float &distanceMetres) {
    float3 target = homePosition;
    float best = 10000.0f;
    if (game.progress.x != allCachesMask) {
        for (uint i = 0u; i < cacheCount; ++i) {
            if ((game.progress.x & (1u << i)) != 0u) continue;
            float3 p = cachePosition(game.progress.w, i);
            float d = distance(p, game.positionYaw.xyz);
            if (d < best) { best = d; target = p; }
        }
    } else {
        best = distance(target, game.positionYaw.xyz);
    }
    distanceMetres = best;
    float2 delta = target.xz - game.positionYaw.xz;
    float bearing = atan2(delta.x, -delta.y) - game.positionYaw.w;
    return float2(sin(bearing), -cos(bearing));
}

float3 drawHUD(float3 color, float2 uv, float2 resolution,
    device const VoyageState &game) {
    float2 p = uv * resolution;
    float scale = min(resolution.x / 960.0f, resolution.y / 600.0f);
    float2 ui = p / scale;
    float2 uiSize = resolution / scale;
    float2 center = resolution * 0.5f;
    float2 q = (p - center) / scale;
    float radius = min(uiSize.x * 0.57f, uiSize.y * 0.78f);
    float radial = length(q);
    float frame = 1.0f - smoothstep(radius - 16.0f, radius + 8.0f, radial);
    color = overlay(float3(0.014f, 0.032f, 0.038f), color, frame);
    float rim = ring(q, radius - 19.0f, 17.0f) * 0.78f;
    color = overlay(color, float3(0.17f, 0.27f, 0.28f), rim);
    float crossH = (1.0f - smoothstep(1.0f, 2.4f, abs(q.y)))
        * step(9.0f, abs(q.x)) * (1.0f - step(23.0f, abs(q.x)));
    float crossV = (1.0f - smoothstep(1.0f, 2.4f, abs(q.x)))
        * step(9.0f, abs(q.y)) * (1.0f - step(23.0f, abs(q.y)));
    color = overlay(color, float3(0.65f, 0.93f, 0.87f),
        (crossH + crossV + ring(q, 5.5f, 1.6f)) * 0.70f);

    const float3 gold = float3(1.0f, 0.74f, 0.30f);
    const float3 cyan = float3(0.25f, 1.0f, 0.91f);
    for (uint i = 0u; i < cacheCount; ++i) {
        float2 lamp = ui - float2(52.0f + 31.0f * float(i), 53.0f);
        bool found = (game.progress.x & (1u << i)) != 0u;
        color = overlay(color, found ? gold : float3(0.15f, 0.30f, 0.32f),
            disc(lamp, 9.0f) * (found ? 0.95f : 0.65f));
        color = overlay(color, float3(0.80f, 0.82f, 0.55f),
            ring(lamp, 10.5f, 2.0f) * 0.8f);
    }

    // Battery and oxygen are independent. Only surfacing replenishes oxygen.
    float2 battery = ui - float2(50.0f, uiSize.y - 72.0f);
    float2 oxygen = ui - float2(50.0f, uiSize.y - 33.0f);
    float batteryFrame = step(abs(battery.y), 8.0f)
        * step(0.0f, battery.x) * step(battery.x, 151.0f);
    float oxygenFrame = step(abs(oxygen.y), 8.0f)
        * step(0.0f, oxygen.x) * step(oxygen.x, 151.0f);
    color = overlay(color, float3(0.08f, 0.19f, 0.20f),
        batteryFrame + oxygenFrame);
    float batteryFill = step(abs(battery.y), 5.0f)
        * step(3.0f, battery.x)
        * step(battery.x, 147.0f * game.mission.x);
    float oxygenFill = step(abs(oxygen.y), 5.0f)
        * step(3.0f, oxygen.x)
        * step(oxygen.x, 147.0f * game.survival.x);
    color = overlay(color, game.mission.x < 0.2f
        ? float3(0.98f, 0.22f, 0.13f) : float3(0.25f, 0.93f, 0.71f),
        batteryFill);
    color = overlay(color, game.notice.y != 0u
        ? float3(1.0f, 0.27f, 0.17f) : float3(0.33f, 0.79f, 1.0f),
        oxygenFill);

    float2 sonar = ui - float2(uiSize.x - 65.0f, 65.0f);
    color = overlay(color, float3(0.18f, 0.39f, 0.39f),
        ring(sonar, 37.0f, 1.8f) + ring(sonar, 20.0f, 1.1f));
    float sonarStrength = game.progress.x == allCachesMask
        ? 1.0f : min(1.0f, game.mission.y);
    if (sonarStrength > 0.0f) {
        float range;
        float2 bearing = sonarTarget(game, range);
        float2 dotPosition = sonar - bearing
            * (7.0f + 27.0f * clamp(range / 125.0f, 0.0f, 1.0f));
        color = overlay(color, game.progress.x == allCachesMask ? cyan : gold,
            disc(dotPosition, 4.8f) * sonarStrength);
        if (game.mission.y > 0.0f) {
            float sweep = ring(sonar,
                37.0f * (1.0f - game.mission.y / 5.0f), 2.4f);
            color += float3(0.05f, 0.21f, 0.21f) * sweep;
        }
    }

    if (game.mission.w > 0.0f) {
        color += float3(0.25f, 0.10f, 0.01f) * game.mission.w;
    }
    if (game.progress.z != phasePlaying) {
        float panel = step(abs(q.x), 214.0f) * step(abs(q.y), 78.0f);
        float border = panel - step(abs(q.x), 209.0f)
            * step(abs(q.y), 73.0f);
        color = overlay(color, float3(0.015f, 0.055f, 0.068f),
            panel * 0.93f);
        color = overlay(color, game.progress.z == phaseFailure
            ? float3(0.96f, 0.28f, 0.16f) : cyan, border * 0.8f);
    }
    return color;
}

fragment float4 voyageFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const VoyageState *states [[buffer(1)]],
    texture2d<float> sandTexture [[texture(1)]],
    texture2d<float> reefTexture [[texture(2)]],
    texture2d<float> wreckTexture [[texture(3)]],
    texture2d<float> greenPlantTexture [[texture(4)]],
    texture2d<float> redPlantTexture [[texture(5)]]) {
    device const VoyageState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float time = game.mission.z;
    float waterDepth = max(-game.positionYaw.y, 0.0f);
    // Subtle refractive shimmer belongs to the scene ray, before the sharp
    // cockpit HUD is drawn. It fades with depth but never freezes entirely.
    float shimmer = 0.00055f + 0.0012f * exp(-waterDepth * 0.055f);
    float2 ripple = float2(
        sin(in.uv.y * 77.0f + time * 0.78f
            + sin(in.uv.x * 29.0f - time * 0.42f)),
        sin(in.uv.x * 63.0f - time * 0.61f
            + sin(in.uv.y * 31.0f + time * 0.37f)));
    Ray ray = cameraRay(in.uv + ripple * shimmer, resolution, game);
    float visibility = clamp(u.parameters0.z, 0.5f, 2.0f)
        * (1.0f + 0.10f * float(game.progress.w));
    float3 nearWater = game.progress.w == 0u
        ? float3(0.035f, 0.23f, 0.29f)
        : game.progress.w == 1u ? float3(0.025f, 0.14f, 0.27f)
        : float3(0.011f, 0.10f, 0.16f);
    float3 deepWater = game.progress.w == 0u
        ? float3(0.00006f, 0.00018f, 0.00060f)
        : game.progress.w == 1u ? float3(0.009f, 0.038f, 0.10f)
        : float3(0.003f, 0.012f, 0.035f);
    // Background scattering keeps fading toward black rather than settling
    // at a bright deep-water color. Local lamps still reveal nearby material.
    float3 water = deepWater + (nearWater - deepWater)
        * exp(-waterDepth * float3(0.041f, 0.027f, 0.020f));
    float sunlight = exp(-waterDepth
        * (0.025f + 0.018f * float(game.progress.w)));
    water += float3(0.03f, 0.11f, 0.12f)
        * max(ray.direction.y, 0.0f) * sunlight;
    float shaft = pow(max(dot(ray.direction,
        normalize(float3(0.23f, 0.88f, -0.42f))), 0.0f), 14.0f);
    water += float3(0.08f, 0.20f, 0.16f) * shaft * sunlight;

    Hit hit = {200.0f, float3(0.0f), float3(0.0f), 0.0f, 0u};
    addSurface(hit, ray, time);
    addFloor(hit, ray, game.progress.w);
    addPlantField(hit, ray, game.progress.w, u.frameSeed.y,
        time, clamp(u.parameters1.y, 0.0f, 2.0f));
    addWorldObjects(hit, ray, game, time);
    float3 color = shadeWorld(hit, ray, time, water, visibility, game,
        sandTexture, reefTexture, wreckTexture,
        greenPlantTexture, redPlantTexture);
    color += searchlightHaze(ray, hit.t, visibility, time, game);

    // Fixed exposure makes the descent visible across the entire scene,
    // while the HUD stays readable at the bottom of the first-map trench.
    color *= 1.0f - 0.55f * smoothstep(90.0f, 325.0f, waterDepth);
    color = drawHUD(color, in.uv, resolution, game);
    // Filmic mapping keeps bright point-light highlights while preserving
    // the much darker water in the deep map.
    float3 hdr = max(color, float3(0.0f)) * 1.15f;
    float3 mapped = pixeltje_3d::filmicToneMap(hdr);
    float3 srgb = pixeltje_3d::linearToSRGB(mapped);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

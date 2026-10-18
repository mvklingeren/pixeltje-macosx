// pixeltje:easing-v1
#include <metal_stdlib>
using namespace metal;

// Signal Range: a four-room first-person arena shooter for gpu.program.
// The compute pass owns all mutable game state. The fragment pass traces the
// same room and walking spider drones from the camera, then draws the HUD.

constant uint enemyCount = 3u;
constant uint targetKills = enemyCount;
constant uint impactCount = 12u;
constant uint phasePlaying = 0u;
constant uint phaseWon = 1u;
constant uint phaseLost = 2u;
constant float spiderScale = 0.7f;
constant float spiderBodyHeight = 0.52f * spiderScale;
constant float spiderAttackRange = 1.65f * spiderScale;
constant float spiderChaseSpeed = 1.8f;
constant float spiderFootprintRadius = 1.5f * spiderScale;
constant float mainRoomHalfExtent = 18.0f;
constant float outerRoomNear = 24.0f;
constant float outerRoomFar = 60.0f;
constant float passageHalfWidth = 3.5f;
constant float sceneRayLimit = 160.0f;
constant float chromeHalfSize = 0.75f;
constant float2 chromeGroundPosition = float2(0.0f, 3.5f);

struct ProgramUniforms {
    float4 resolutionTime;
    uint4 frameSeed;
    float4 parameters0;
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;   // Trackpad X/Y, Space action count, live time step
    float4 movement;  // WASD Pad X/Y, secondary action count, unused
};

struct ShotImpact {
    float4 muzzleTime;      // muzzle XYZ, elapsed time when fired
    float4 pointEnemy;      // world impact XYZ, enemy index + 1 or zero
    float4 normalMaterial;  // world normal XYZ, surface material
    float4 localPointYaw;   // enemy-local impact XYZ, yaw when fired
};

struct FallenSpider {
    float4 pose;           // chassis centre XYZ and yaw at the killing hit
    float4 motion;         // gait phase, movement blend, death time, body rise
};

struct GameState {
    float4 player;          // position XYZ, yaw
    float4 view;            // pitch, health, shot cooldown, muzzle flash
    float4 enemy[enemyCount]; // chassis centre XYZ, health
    float4 enemyClock[enemyCount]; // attack cooldown, reserved, hit flash, yaw
    float4 gait[enemyCount]; // distance-based cycle, movement blend, speed, turn rate
    float4 effects;         // elapsed, damage flash, last jump count, vertical speed
    float4 chromeRotation;  // local-to-world unit quaternion
    float4 chromeCentre;    // world XYZ, unused
    float4 sceneTransition; // time of victory in X, handoff sent in Y
    uint4 progress;         // kills, shots, last action count, phase
    ShotImpact impacts[impactCount];
    FallenSpider fallen[targetKills];
};

static_assert(sizeof(GameState) <= 1280,
    "The GPU Program game buffer must contain impacts and fallen spiders");

struct SceneHit {
    float distance;
    float3 normal;
    float3 position;
    uint material;
    int enemy;
};

struct ChromePose {
    float4 rotation;
    float3 centre;
};

void traceEnvironment(thread SceneHit &hit, float3 origin,
    float3 direction, ChromePose chrome);

constant float rangePi = 3.14159265f;

float4 multiplyQuaternions(float4 a, float4 b) {
    return float4(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz),
        a.w * b.w - dot(a.xyz, b.xyz));
}

float3 rotateByQuaternion(float4 rotation, float3 vector) {
    float3 t = 2.0f * cross(rotation.xyz, vector);
    return vector + rotation.w * t + cross(rotation.xyz, t);
}

void updateChromePose(device GameState &game) {
    // Ease each revolution in and out at the same angle.
    float cycle = fract(game.effects.x / 7.5f);
    float yaw = 2.0f * rangePi * pixeltje_easing::easeInOut(cycle);
    // At the base angles a body diagonal points straight down. The small
    // oscillations rock that diagonal while the lowest corner stays grounded.
    float tilt = 0.6154797f + 0.11f * sin(game.effects.x * 1.37f);
    float pitch = -0.7853982f
        + 0.09f * sin(game.effects.x * 1.91f + 0.8f);
    float4 spin = float4(0.0f, sin(yaw * 0.5f), 0.0f,
        cos(yaw * 0.5f));
    float4 lean = float4(0.0f, 0.0f, sin(tilt * 0.5f),
        cos(tilt * 0.5f));
    float4 rock = float4(sin(pitch * 0.5f), 0.0f, 0.0f,
        cos(pitch * 0.5f));
    float4 rotation = normalize(multiplyQuaternions(spin,
        multiplyQuaternions(lean, rock)));
    float support = chromeHalfSize * (
        abs(rotateByQuaternion(rotation, float3(1.0f, 0.0f, 0.0f)).y)
        + abs(rotateByQuaternion(rotation, float3(0.0f, 1.0f, 0.0f)).y)
        + abs(rotateByQuaternion(rotation, float3(0.0f, 0.0f, 1.0f)).y));
    game.chromeRotation = rotation;
    game.chromeCentre = float4(chromeGroundPosition.x, support,
        chromeGroundPosition.y, 0.0f);
}

float spiderBodyBob(float phase, float movementBlend) {
    return movementBlend * (0.048f * sin(phase * 4.0f * rangePi)
        + 0.012f * sin(phase * 2.0f * rangePi + 1.1f));
}

float spiderBodyRise(float time, uint slot) {
    return 0.014f * (float(slot) - 1.0f)
        + 0.013f * sin(time * 1.9f + float(slot) * 2.2f);
}

struct PointLight {
    float3 position;
    float3 color;
    float power;
};

PointLight roomLight(uint index) {
    if (index == 0u) return {
        float3(-9.0f, 5.05f, -8.0f), float3(1.0f, 0.79f, 0.58f), 420.0f};
    if (index == 1u) return {
        float3(9.0f, 5.05f, -8.0f), float3(0.48f, 0.78f, 1.0f), 390.0f};
    if (index == 2u) return {float3(0.0f, 5.05f, 10.0f),
        float3(1.0f, 0.53f, 0.35f), 320.0f};
    if (index == 3u) return {float3(0.0f, 6.25f, -42.0f),
        float3(0.57f, 0.82f, 1.0f), 560.0f};
    if (index == 4u) return {float3(42.0f, 5.95f, 0.0f),
        float3(1.0f, 0.75f, 0.45f), 540.0f};
    return {float3(-42.0f, 6.55f, 0.0f),
        float3(0.65f, 1.0f, 0.75f), 550.0f};
}

float3 forwardVector(float yaw, float pitch) {
    return float3(sin(yaw) * cos(pitch), sin(pitch),
        -cos(yaw) * cos(pitch));
}

float3 spawnPosition(uint slot) {
    float2 initial[3] = {
        float2(-9.5f, -8.0f), float2(9.0f, -10.0f),
        float2(0.0f, -14.0f)
    };
    float2 xz = initial[slot];
    return float3(xz.x, spiderBodyHeight, xz.y);
}

void resetGame(device GameState &game) {
    game.player = float4(0.0f, 1.55f, 12.0f, 0.0f);
    game.view = float4(0.0f, 100.0f, 0.0f, 0.0f);
    game.effects = float4(0.0f);
    game.sceneTransition = float4(0.0f);
    updateChromePose(game);
    game.progress = uint4(0u);
    for (uint i = 0u; i < impactCount; ++i) {
        game.impacts[i].muzzleTime = float4(0.0f, 0.0f, 0.0f, -100.0f);
        game.impacts[i].pointEnemy = float4(0.0f);
        game.impacts[i].normalMaterial = float4(0.0f);
        game.impacts[i].localPointYaw = float4(0.0f);
    }
    for (uint i = 0u; i < targetKills; ++i) {
        game.fallen[i].pose = float4(0.0f);
        game.fallen[i].motion = float4(0.0f);
    }
    for (uint i = 0u; i < enemyCount; ++i) {
        game.enemy[i] = float4(spawnPosition(i), 2.0f);
        float2 toPlayer = game.player.xz - game.enemy[i].xz;
        game.enemyClock[i] = float4(0.0f, 0.0f, 0.0f,
            atan2(toPlayer.x, -toPlayer.y));
        game.gait[i] = float4(0.07f + float(i) * 0.31f,
            0.0f, 0.0f, 0.0f);
    }
}

kernel void initializeRange(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id == 0u) resetGame(states[0]);
}

float raySphere(float3 origin, float3 direction, float3 center, float radius) {
    float3 offset = origin - center;
    float b = dot(offset, direction);
    float c = dot(offset, offset) - radius * radius;
    float discriminant = b * b - c;
    if (discriminant < 0.0f) return -1.0f;
    float root = sqrt(discriminant);
    float near = -b - root;
    float far = -b + root;
    return near > 0.01f ? near : (far > 0.01f ? far : -1.0f);
}

struct SpiderHit {
    float distance;
    float3 normal;
    uint material;
    float3 furPosition;
};

float smoothNoise(float2 p);

void acceptSpiderSphere(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 centre, float radius, uint material) {
    float t = raySphere(origin, direction, centre, radius);
    if (t > 0.0f && t < hit.distance) {
        hit = {t, normalize(origin + direction * t - centre),
            material, origin + direction * t - centre};
    }
}

void acceptSpiderEllipsoid(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 centre, float3 radii, uint material) {
    float3 o = (origin - centre) / radii;
    float3 d = direction / radii;
    float a = dot(d, d);
    float b = dot(o, d);
    float discriminant = b * b - a * (dot(o, o) - 1.0f);
    if (discriminant < 0.0f) return;
    float root = sqrt(discriminant);
    float near = (-b - root) / a;
    float far = (-b + root) / a;
    float t = near > 0.01f ? near : far;
    if (t > 0.01f && t < hit.distance) {
        float3 point = o + d * t;
        hit = {t, normalize(point / radii),
            material, origin + direction * t - centre};
    }
}

void acceptSpiderLeg(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 start, float3 end, float radius,
    uint material) {
    float3 axis = end - start;
    float3 offset = origin - start;
    float axisSquared = dot(axis, axis);
    float axisDirection = dot(axis, direction);
    float axisOffset = dot(axis, offset);
    float a = axisSquared - axisDirection * axisDirection;
    float b = axisSquared * dot(offset, direction)
        - axisOffset * axisDirection;
    float c = axisSquared * (dot(offset, offset) - radius * radius)
        - axisOffset * axisOffset;
    float discriminant = b * b - a * c;
    if (a > 0.00001f && discriminant >= 0.0f) {
        float t = (-b - sqrt(discriminant)) / a;
        float along = axisOffset + t * axisDirection;
        if (t > 0.01f && t < hit.distance
            && along > 0.0f && along < axisSquared) {
            float3 closest = start + axis * (along / axisSquared);
            hit = {t, normalize(origin + direction * t - closest),
                material, origin + direction * t - start};
        }
    }
    acceptSpiderSphere(hit, origin, direction, start, radius, material);
    acceptSpiderSphere(hit, origin, direction, end, radius, material);
}

void acceptSpiderPaw(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 foot) {
    // Test the small paw volume before tracing its separate furry toe lobes.
    float3 paw = foot + float3(0.0f, 0.045f, -0.035f);
    float bound = raySphere(origin, direction, paw, 0.34f);
    if (bound < 0.0f || (dot(origin - paw, origin - paw) > 0.1156f
        && bound >= hit.distance)) return;

    float previousDistance = hit.distance;
    acceptSpiderEllipsoid(hit, origin, direction, paw,
        float3(0.19f, 0.12f, 0.20f), 18u);
    for (uint toe = 0u; toe < 3u; ++toe) {
        float spread = (float(toe) - 1.0f) * 0.09f;
        acceptSpiderEllipsoid(hit, origin, direction,
            paw + float3(spread, -0.022f, -0.13f),
            float3(0.055f, 0.065f, 0.09f), 18u);
    }
    if (hit.distance < previousDistance)
        hit.furPosition = origin + direction * hit.distance - paw;
}

void acceptSpiderEyes(thread SpiderHit &hit, float3 origin,
    float3 direction) {
    float3 eyeRegion = float3(0.0f, 0.16f, -0.62f);
    float bound = raySphere(origin, direction, eyeRegion, 0.55f);
    if (bound < 0.0f || (dot(origin - eyeRegion, origin - eyeRegion)
        > 0.3025f && bound >= hit.distance)) return;

    // Eight differently sized corneas sit in recessed dark sockets.
    for (uint side = 0u; side < 2u; ++side) {
        float signX = side == 0u ? -1.0f : 1.0f;
        for (uint eye = 0u; eye < 4u; ++eye) {
            float3 centre;
            float radius;
            if (eye == 0u) {
                centre = float3(signX * 0.14f, 0.085f, -0.75f);
                radius = 0.082f;
            } else if (eye == 1u) {
                centre = float3(signX * 0.28f, 0.105f, -0.665f);
                radius = 0.055f;
            } else if (eye == 2u) {
                centre = float3(signX * 0.085f, 0.255f, -0.67f);
                radius = 0.047f;
            } else {
                centre = float3(signX * 0.245f, 0.225f, -0.605f);
                radius = 0.044f;
            }
            acceptSpiderSphere(hit, origin, direction,
                centre + float3(0.0f, 0.0f, radius * 0.85f),
                radius * 1.28f, 19u);
            acceptSpiderSphere(hit, origin, direction,
                centre, radius, 16u);
        }
    }
}

float3 rotateSpiderPitch(float3 point, float sine, float cosine) {
    return float3(point.x,
        cosine * point.y - sine * point.z,
        sine * point.y + cosine * point.z);
}

// A single articulated ray test serves both the camera and the gun. Local -Z
// is forward; the stored yaw turns the chassis toward the player.
SpiderHit traceSpider(float3 origin, float3 direction, float3 centre,
    float yaw, float gaitPhase, float movementBlend, float bodyRise,
    float collapse, float maxDistance) {
    float cosine = cos(yaw), sine = sin(yaw);
    // Keep the authored geometry in one local scale for both gun hits and
    // drawing; converting the final distance preserves world-space depth.
    float3 offset = (origin - centre) / spiderScale;
    float3 localOrigin = float3(cosine * offset.x + sine * offset.z,
        offset.y, -sine * offset.x + cosine * offset.z);
    float3 localDirection = float3(
        cosine * direction.x + sine * direction.z, direction.y,
        -sine * direction.x + cosine * direction.z);
    float localMaxDistance = maxDistance / spiderScale;
    SpiderHit hit = {localMaxDistance, float3(0.0f), 0u, float3(0.0f)};
    float bound = raySphere(localOrigin, localDirection,
        float3(0.0f), 2.15f);
    if (bound < 0.0f || (dot(localOrigin, localOrigin) > 4.6225f
        && bound >= localMaxDistance)) {
        hit.distance = maxDistance;
        return hit;
    }

    // The front lifts as a walk starts, then rocks gently with the steps.
    // Trace the pitched body separately so all six feet remain grounded.
    float startLift = sin(rangePi * clamp(movementBlend, 0.0f, 1.0f));
    float pitch = (0.23f * startLift + 0.12f * movementBlend
        * sin(gaitPhase * 2.0f * rangePi - 0.5f))
        * (1.0f - collapse) - 0.32f * collapse;
    float sinePitch = sin(pitch), cosinePitch = cos(pitch);
    float3 bodyOrigin = rotateSpiderPitch(
        localOrigin - float3(0.0f, bodyRise, 0.0f),
        -sinePitch, cosinePitch);
    float3 bodyDirection = rotateSpiderPitch(
        localDirection, -sinePitch, cosinePitch);
    SpiderHit bodyHit = {localMaxDistance,
        float3(0.0f), 0u, float3(0.0f)};

    acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, -0.02f, 0.29f), float3(0.55f, 0.32f, 0.61f), 5u);
    acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, 0.03f, -0.37f), float3(0.41f, 0.29f, 0.40f), 17u);
    acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, 0.20f, 0.28f), float3(0.44f, 0.15f, 0.45f), 17u);
    for (uint side = 0u; side < 2u; ++side) {
        float signX = side == 0u ? -1.0f : 1.0f;
        for (uint tuft = 0u; tuft < 4u; ++tuft) {
            acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
                float3(signX * 0.44f, 0.10f,
                    -0.05f + float(tuft) * 0.27f),
                float3(0.16f, 0.14f, 0.15f), 5u);
        }
        acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
            float3(signX * 0.32f, -0.02f, -0.50f),
            float3(0.16f, 0.15f, 0.19f), 17u);
    }
    acceptSpiderEyes(bodyHit, bodyOrigin, bodyDirection);
    if (bodyHit.material != 0u) {
        bodyHit.normal = rotateSpiderPitch(
            bodyHit.normal, sinePitch, cosinePitch);
        hit = bodyHit;
    }
    for (uint side = 0u; side < 2u; ++side) {
        float signX = side == 0u ? -1.0f : 1.0f;
        for (uint leg = 0u; leg < 3u; ++leg) {
            float z = -0.42f + float(leg) * 0.42f;
            // Alternating groups plant for 60% of a cycle. Both the planted
            // stroke and the lifted return stroke ease at their endpoints.
            float phase = fract(gaitPhase
                + (((leg + side) & 1u) != 0u ? 0.5f : 0.0f)
                + (float(leg) - 1.0f) * 0.055f
                + signX * 0.012f);
            float stride, lift = 0.0f;
            if (phase < 0.6f) {
                stride = -0.24f + 0.48f
                    * smoothstep(0.0f, 1.0f, phase / 0.6f);
            } else {
                float swing = (phase - 0.6f) / 0.4f;
                float eased = smoothstep(0.0f, 1.0f, swing);
                stride = 0.24f - 0.48f * eased;
                lift = 0.23f * sin(rangePi * eased);
            }
            stride *= movementBlend;
            lift *= movementBlend;
            float bob = spiderBodyBob(gaitPhase, movementBlend);
            float3 hip = rotateSpiderPitch(
                float3(signX * 0.33f, -0.08f, z),
                sinePitch, cosinePitch)
                + float3(0.0f, bodyRise, 0.0f);
            float3 knee = float3(signX * (0.83f + 0.15f * collapse),
                mix(0.11f, -0.10f, collapse) + lift * 0.35f,
                z + (float(leg) - 1.0f) * 0.13f + stride * 0.5f);
            float3 foot = float3(signX * (1.19f + 0.22f * collapse),
                mix(-0.45f - bob, -0.37f, collapse) + lift,
                z + (float(leg) - 1.0f) * 0.25f + stride);
            acceptSpiderLeg(hit, localOrigin, localDirection,
                hip, knee, 0.12f, 15u);
            acceptSpiderLeg(hit, localOrigin, localDirection,
                knee, foot, 0.095f, 15u);
            acceptSpiderSphere(hit, localOrigin, localDirection,
                knee, 0.14f, 17u);
            acceptSpiderEllipsoid(hit, localOrigin, localDirection,
                mix(knee, foot, 0.38f),
                float3(0.14f, 0.14f, 0.16f), 15u);
            acceptSpiderPaw(hit, localOrigin, localDirection, foot);
        }
    }
    float3 n = hit.normal;
    if (hit.material == 5u || hit.material == 15u
        || hit.material == 17u || hit.material == 18u) {
        // Stronger normal variation gives the enlarged coat visible depth.
        float3 fibers = float3(
            smoothNoise(hit.furPosition.yz * 79.0f),
            smoothNoise(hit.furPosition.xz * 73.0f),
            smoothNoise(hit.furPosition.xy * 83.0f)) - 0.5f;
        n = normalize(n + fibers * 0.34f);
    }
    hit.normal = float3(cosine * n.x - sine * n.z, n.y,
        sine * n.x + cosine * n.z);
    hit.distance *= spiderScale;
    return hit;
}

float rayBox(float3 origin, float3 direction, float3 lower, float3 upper,
    thread float3 &normal) {
    float3 safe = select(direction, float3(0.00001f),
        abs(direction) < float3(0.00001f));
    float3 a = (lower - origin) / safe;
    float3 b = (upper - origin) / safe;
    float3 entry = min(a, b);
    float3 exit = max(a, b);
    float near = max(entry.x, max(entry.y, entry.z));
    float far = min(exit.x, min(exit.y, exit.z));
    if (far < max(near, 0.01f)) return -1.0f;
    float t = near > 0.01f ? near : far;
    float3 p = origin + direction * t;
    float3 centre = (lower + upper) * 0.5f;
    float3 edge = abs((p - centre) / max((upper - lower) * 0.5f,
        float3(0.001f)));
    normal = edge.x > edge.y && edge.x > edge.z
        ? float3(sign(p.x - centre.x), 0.0f, 0.0f)
        : edge.y > edge.z
          ? float3(0.0f, sign(p.y - centre.y), 0.0f)
          : float3(0.0f, 0.0f, sign(p.z - centre.z));
    return t;
}

float rayChrome(float3 origin, float3 direction, ChromePose chrome,
    thread float3 &normal) {
    // The enclosing sphere avoids quaternion transforms for most view rays.
    if (raySphere(origin, direction, chrome.centre,
        chromeHalfSize * 1.732051f) < 0.0f) return -1.0f;
    float4 inverseRotation = float4(-chrome.rotation.xyz,
        chrome.rotation.w);
    float3 localOrigin = rotateByQuaternion(inverseRotation,
        origin - chrome.centre);
    float3 localDirection = rotateByQuaternion(inverseRotation, direction);
    float3 localNormal;
    float t = rayBox(localOrigin, localDirection,
        float3(-chromeHalfSize), float3(chromeHalfSize), localNormal);
    if (t > 0.0f)
        normal = rotateByQuaternion(chrome.rotation, localNormal);
    return t;
}

bool chromeBlocksLight(float3 origin, float3 direction,
    float lightDistance, ChromePose chrome) {
    float3 toChrome = chrome.centre - origin;
    float along = dot(toChrome, direction);
    if (along <= 0.0f || along >= lightDistance) return false;
    float separationSquared = dot(toChrome, toChrome) - along * along;
    if (separationSquared > 3.0f * chromeHalfSize * chromeHalfSize)
        return false;
    float3 normal;
    float t = rayChrome(origin, direction, chrome, normal);
    return t > 0.0f && t < lightDistance - 0.02f;
}

void pushOutOfObstacle(thread float2 &point, float2 lower, float2 upper) {
    float2 paddedLower = lower - 0.42f;
    float2 paddedUpper = upper + 0.42f;
    if (any(point <= paddedLower) || any(point >= paddedUpper)) return;
    float2 fromLower = point - paddedLower;
    float2 fromUpper = paddedUpper - point;
    float2 distanceToFace = min(fromLower, fromUpper);
    if (distanceToFace.x < distanceToFace.y) {
        point.x = fromLower.x < fromUpper.x ? paddedLower.x : paddedUpper.x;
    } else {
        point.y = fromLower.y < fromUpper.y ? paddedLower.y : paddedUpper.y;
    }
}

void pushOutOfChrome(thread float2 &point) {
    // A conservative circular footprint keeps the player clear throughout
    // the cube's changing orientation, including while jumping beside it.
    float2 offset = point - chromeGroundPosition;
    float distance = length(offset);
    const float safeRadius = 1.7f;
    if (distance < safeRadius)
        point = chromeGroundPosition
            + (distance > 0.0001f ? offset / distance : float2(0.0f, 1.0f))
                * safeRadius;
}

// The three stair connectors have six real steps. The same height function
// positions the camera and the collision surface, so stairs are walkable.
float stairHeight(float2 point) {
    if (abs(point.x) < passageHalfWidth
        && point.y < -mainRoomHalfExtent && point.y > -outerRoomNear)
        return (floor(clamp(-point.y - mainRoomHalfExtent,
            0.0f, 5.999f))
            + 1.0f) * 0.2f;
    if (abs(point.y) < passageHalfWidth
        && point.x > mainRoomHalfExtent && point.x < outerRoomNear)
        return (floor(clamp(point.x - mainRoomHalfExtent,
            0.0f, 5.999f))
            + 1.0f) * 0.15f;
    if (abs(point.y) < passageHalfWidth
        && point.x < -mainRoomHalfExtent && point.x > -outerRoomNear)
        return (floor(clamp(-point.x - mainRoomHalfExtent,
            0.0f, 5.999f))
            + 1.0f) * 0.25f;
    if (point.y <= -outerRoomNear) return 1.2f;
    if (point.x >= outerRoomNear) return 0.9f;
    if (point.x <= -outerRoomNear) return 1.5f;
    return 0.0f;
}

bool walkable(float2 point) {
    float x = point.x, z = point.y;
    const float roomLimit = mainRoomHalfExtent - 0.45f;
    const float outerLimit = outerRoomFar - 0.45f;
    const float passageLimit = passageHalfWidth - 0.42f;
    if (abs(x) <= roomLimit && abs(z) <= roomLimit) return true;
    if (abs(x) <= passageLimit
        && z >= -outerRoomNear && z <= -roomLimit) return true;
    if (abs(x) <= roomLimit
        && z >= -outerLimit && z <= -outerRoomNear) return true;
    if (x >= roomLimit && x <= outerRoomNear
        && abs(z) <= passageLimit) return true;
    if (x >= outerRoomNear && x <= outerLimit
        && abs(z) <= roomLimit) return true;
    if (x <= -roomLimit && x >= -outerRoomNear
        && abs(z) <= passageLimit) return true;
    return x <= -outerRoomNear && x >= -outerLimit
        && abs(z) <= roomLimit;
}

bool spiderPositionClear(float2 position, uint self,
    device const GameState &game) {
    if (!walkable(position)) return false;
    const float minimumSeparation = 2.0f * spiderFootprintRadius;
    for (uint other = 0u; other < enemyCount; ++other) {
        if (other == self || game.enemy[other].w <= 0.0f) continue;
        float2 offset = position - game.enemy[other].xz;
        if (dot(offset, offset) < minimumSeparation * minimumSeparation)
            return false;
    }
    return true;
}

float2 moveSpider(float2 position, float2 step, uint self,
    device const GameState &game) {
    float2 next = position + step;
    if (spiderPositionClear(next, self, game)) return next;

    // The rendered feet extend beyond the chassis. Use a circular ground
    // footprint and slide around the nearest living spider when blocked.
    uint blocker = enemyCount;
    const float minimumSeparation = 2.0f * spiderFootprintRadius;
    float closest = minimumSeparation * minimumSeparation;
    for (uint other = 0u; other < enemyCount; ++other) {
        if (other == self || game.enemy[other].w <= 0.0f) continue;
        float2 offset = next - game.enemy[other].xz;
        float distanceSquared = dot(offset, offset);
        if (distanceSquared < closest) {
            closest = distanceSquared;
            blocker = other;
        }
    }
    if (blocker == enemyCount) return position;

    float2 away = position - game.enemy[blocker].xz;
    float distanceSquared = dot(away, away);
    away = distanceSquared > 0.000001f
        ? away * rsqrt(distanceSquared) : float2(1.0f, 0.0f);
    float2 tangent = float2(-away.y, away.x);
    float sideways = dot(step, tangent);
    if (abs(sideways) < length(step) * 0.2f)
        sideways = (self & 1u) == 0u ? length(step) : -length(step);
    float2 slide = position + tangent * sideways;
    return spiderPositionClear(slide, self, game) ? slide : position;
}

kernel void advanceRange(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device uint *sceneRequest [[buffer(2)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.10f);
    uint action = uint(u.pointer.z);
    uint jumpAction = uint(u.movement.z);
    game.effects.x += dt;
    updateChromePose(game);
    game.effects.y = max(game.effects.y - dt, 0.0f);
    game.view.z = max(game.view.z - dt, 0.0f);
    game.view.w = max(game.view.w - dt, 0.0f);
    if (game.progress.w != phasePlaying) {
        if (game.progress.w == phaseLost && action > game.progress.z) {
            resetGame(game);
            game.progress.z = action;
            game.effects.z = float(jumpAction);
        } else if (game.progress.w == phaseWon
            && game.sceneTransition.y > 0.5f
            && action > game.progress.z) {
            // The triangle scene's click returned here. Keep clicks during
            // the victory pause from restarting the game before handoff.
            resetGame(game);
            game.progress.z = action;
            game.effects.z = float(jumpAction);
        } else if (game.progress.w == phaseWon
            && game.effects.x - game.sceneTransition.x >= 2.0f) {
            sceneRequest[0] = 1u;
            game.sceneTransition.y = 1.0f;
            game.progress.z = action;
        }
        return;
    }

    // Trackpad selects an orientation; it never changes player position.
    // Keeping it still must also keep the view still.
    float2 look = clamp(u.pointer.xy, float2(0.0f), float2(1.0f));
    game.player.w = (look.x - 0.5f) * 6.2831853f;
    game.view.x = (0.5f - look.y) * 1.9f;
    float2 move = clamp(u.movement.xy, float2(-1.0f), float2(1.0f));
    if (length(move) > 1.0f) move = normalize(move);
    float2 forward = float2(sin(game.player.w), -cos(game.player.w));
    float2 right = float2(cos(game.player.w), sin(game.player.w));
    float2 next = game.player.xz + (right * move.x + forward * move.y)
        * 4.6f * dt;
    // Resolve axes independently so a diagonal approach slides along a wall.
    float2 position = game.player.xz;
    if (walkable(float2(next.x, position.y))) position.x = next.x;
    if (walkable(float2(position.x, next.y))) position.y = next.y;
    next = position;
    pushOutOfObstacle(next, float2(-4.1f, -3.1f), float2(-1.8f, -0.7f));
    pushOutOfObstacle(next, float2(2.1f, -6.5f), float2(4.5f, -4.1f));
    pushOutOfChrome(next);
    game.player.xz = next;
    float groundY = 1.55f + stairHeight(next);
    bool grounded = game.player.y <= groundY + 0.001f;
    if (jumpAction > uint(game.effects.z)) {
        game.effects.z = float(jumpAction);
        if (grounded) game.effects.w = 5.2f;
    }
    if (!grounded || game.effects.w > 0.0f) {
        game.effects.w -= 13.0f * dt;
        game.player.y += game.effects.w * dt;
    }
    if (game.player.y <= groundY) {
        game.player.y = groundY;
        game.effects.w = 0.0f;
    }

    for (uint i = 0u; i < enemyCount; ++i) {
        game.enemyClock[i].x = max(game.enemyClock[i].x - dt, 0.0f);
        game.enemyClock[i].z = max(game.enemyClock[i].z - dt, 0.0f);
        if (game.enemy[i].w <= 0.0f) continue;
        float2 toPlayer = game.player.xz - game.enemy[i].xz;
        float distanceToPlayer = length(toPlayer);
        bool pursuing = distanceToPlayer > spiderAttackRange;
        if (pursuing) {
            float desiredYaw = atan2(toPlayer.x, -toPlayer.y);
            float delta = desiredYaw - game.enemyClock[i].w;
            float shortestTurn = atan2(sin(delta), cos(delta));
            float desiredTurnRate = clamp(shortestTurn * 4.0f,
                -2.4f, 2.4f);
            game.gait[i].w = mix(game.gait[i].w, desiredTurnRate,
                1.0f - exp(-dt * 6.0f));
            float turn = game.gait[i].w * dt;
            if (abs(turn) >= abs(shortestTurn)) {
                game.enemyClock[i].w = desiredYaw;
                game.gait[i].w = 0.0f;
            } else {
                game.enemyClock[i].w += turn;
            }
        } else {
            game.gait[i].w = 0.0f;
        }
        float2 oldPosition = game.enemy[i].xz;
        float walkBlend = mix(game.gait[i].y, pursuing ? 1.0f : 0.0f,
            1.0f - exp(-dt * 7.0f));
        if (pursuing) {
            // Two smooth, differently timed rhythms give each spider slow
            // approaches and brief rushes without a walk/pause switch.
            float slot = float(i);
            float slowPace = smoothNoise(float2(
                game.effects.x * 0.37f + slot * 2.17f,
                slot * 5.31f + 0.73f));
            float quickPace = smoothNoise(float2(
                game.effects.x * 1.07f + slot * 3.41f,
                slot * 7.19f + 2.13f));
            float targetSpeed = spiderChaseSpeed
                * (0.38f + 0.95f * slowPace + 0.22f * quickPace);
            float speedResponse = targetSpeed > game.gait[i].z
                ? 1.8f : 2.8f;
            game.gait[i].z = mix(game.gait[i].z, targetSpeed,
                1.0f - exp(-dt * speedResponse));
            float yaw = game.enemyClock[i].w;
            float2 nextEnemy = oldPosition
                + float2(sin(yaw), -cos(yaw))
                    * min(game.gait[i].z * walkBlend * dt,
                        distanceToPlayer - spiderAttackRange);
            game.enemy[i].xz = moveSpider(oldPosition,
                nextEnemy - oldPosition, i, game);
        } else {
            game.gait[i].z *= exp(-dt * 3.0f);
        }
        if (distanceToPlayer <= spiderAttackRange
            && game.enemyClock[i].x <= 0.0f) {
            game.view.y = max(game.view.y - 12.0f, 0.0f);
            game.effects.y = 0.35f;
            game.enemyClock[i].x = 1.2f;
        }
        float travel = length(game.enemy[i].xz - oldPosition);
        game.gait[i].x = fract(game.gait[i].x
            + travel / (0.8f * spiderScale));
        game.gait[i].y = pursuing && travel > 0.0001f
            ? walkBlend
            : mix(game.gait[i].y, 0.0f, 1.0f - exp(-dt * 7.0f));
        game.enemy[i].y = stairHeight(game.enemy[i].xz) + spiderBodyHeight
            + spiderScale * spiderBodyBob(
                game.gait[i].x, game.gait[i].y);
    }

    if (action > game.progress.z) {
        game.progress.z = action;
        if (game.view.z <= 0.0f) {
            game.view.z = 0.22f;
            game.view.w = 0.11f;
            game.progress.y += 1u;
            float3 shotDirection = forwardVector(game.player.w, game.view.x);
            float3 normal;
            float3 impactNormal = -shotDirection;
            uint impactMaterial = 0u;
            ChromePose chrome = {game.chromeRotation,
                game.chromeCentre.xyz};
            float block = sceneRayLimit;
            float t = rayBox(game.player.xyz, shotDirection,
                float3(-4.1f, 0.0f, -3.1f),
                float3(-1.8f, 2.5f, -0.7f), normal);
            if (t > 0.0f && t < block) {
                block = t;
                impactNormal = normal;
                impactMaterial = 14u;
            }
            t = rayBox(game.player.xyz, shotDirection,
                float3(2.1f, 0.0f, -6.5f),
                float3(4.5f, 2.5f, -4.1f), normal);
            if (t > 0.0f && t < block) {
                block = t;
                impactNormal = normal;
                impactMaterial = 4u;
            }
            t = rayChrome(game.player.xyz, shotDirection,
                chrome, normal);
            if (t > 0.0f && t < block) {
                block = t;
                impactNormal = normal;
                impactMaterial = 20u;
            }
            int target = -1;
            for (uint i = 0u; i < enemyCount; ++i) {
                if (game.enemy[i].w <= 0.0f) continue;
                SpiderHit spider = traceSpider(game.player.xyz, shotDirection,
                    game.enemy[i].xyz, game.enemyClock[i].w,
                    game.gait[i].x, game.gait[i].y,
                    spiderBodyRise(game.effects.x, i), 0.0f, block);
                if (spider.material != 0u) {
                    block = spider.distance;
                    target = int(i);
                    impactNormal = spider.normal;
                    impactMaterial = spider.material;
                }
            }
            float3 impactPoint = game.player.xyz + shotDirection * block;
            if (target < 0) {
                // Static scene lookup supplies a visible endpoint only. The
                // crate/spider ray above remains the gameplay hit test.
                SceneHit scene = {sceneRayLimit, float3(0.0f),
                    float3(0.0f), 0u, -1};
                traceEnvironment(scene, game.player.xyz,
                    shotDirection, chrome);
                if (scene.material != 0u) {
                    impactPoint = scene.position;
                    impactNormal = scene.normal;
                    impactMaterial = scene.material;
                } else {
                    impactPoint = game.player.xyz + shotDirection * 28.0f;
                    impactMaterial = 0u;
                }
            }
            float3 muzzleRight = normalize(cross(shotDirection,
                float3(0.0f, 1.0f, 0.0f)));
            float3 muzzleUp = cross(muzzleRight, shotDirection);
            ShotImpact shot;
            shot.muzzleTime = float4(game.player.xyz
                + shotDirection * 0.40f + muzzleRight * 0.20f
                - muzzleUp * 0.16f, game.effects.x);
            shot.pointEnemy = float4(impactPoint, float(target + 1));
            shot.normalMaterial = float4(impactNormal,
                float(impactMaterial));
            shot.localPointYaw = float4(0.0f);
            if (target >= 0) {
                float yaw = game.enemyClock[target].w;
                float cosine = cos(yaw), sine = sin(yaw);
                float3 relative = impactPoint - game.enemy[target].xyz;
                shot.localPointYaw = float4(
                    cosine * relative.x + sine * relative.z,
                    relative.y,
                    -sine * relative.x + cosine * relative.z,
                    yaw);
            }
            game.impacts[(game.progress.y - 1u) % impactCount] = shot;
            if (target >= 0) {
                game.enemy[target].w -= 1.0f;
                game.enemyClock[target].z = 0.24f;
                if (game.enemy[target].w <= 0.0f) {
                    uint fallenIndex = game.progress.x;
                    if (fallenIndex < targetKills) {
                        game.fallen[fallenIndex].pose = float4(
                            game.enemy[target].xyz,
                            game.enemyClock[target].w);
                        game.fallen[fallenIndex].motion = float4(
                            game.gait[target].x, game.gait[target].y,
                            game.effects.x,
                            spiderBodyRise(game.effects.x, uint(target)));
                    }
                    game.progress.x += 1u;
                }
            }
        }
    }
    if (game.progress.x >= targetKills) {
        game.progress.w = phaseWon;
        game.sceneTransition.x = game.effects.x;
    }
    else if (game.view.y <= 0.0f) game.progress.w = phaseLost;
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

void acceptPlane(thread SceneHit &hit, float3 origin, float3 direction,
    float t, float3 normal, uint material, float3 lower, float3 upper) {
    if (t <= 0.01f || t >= hit.distance) return;
    float3 p = origin + direction * t;
    // Reconstructed points can land just outside their own plane (for
    // example y = -0.0000001 for the floor). Exact bounds made those pixels
    // fall through to the background, producing dense apparent noise.
    float3 tolerance = float3(0.0001f);
    if (any(p < lower - tolerance) || any(p > upper + tolerance)) return;
    p = clamp(p, lower, upper);
    hit = {t, normal, p, material, -1};
}

bool doorway(uint room, uint wall, float3 point) {
    if (point.y > 3.5f) return false;
    if (room == 0u) {
        return (wall == 0u && abs(point.x) < passageHalfWidth)
            || ((wall == 1u || wall == 2u)
                && abs(point.z) < passageHalfWidth);
    }
    return (room == 1u && wall == 3u
            && abs(point.x) < passageHalfWidth)
        || (room == 2u && wall == 2u
            && abs(point.z) < passageHalfWidth)
        || (room == 3u && wall == 1u
            && abs(point.z) < passageHalfWidth);
}

void traceRoom(thread SceneHit &hit, float3 origin, float3 direction,
    uint room, float3 lower, float3 upper, uint floorMaterial,
    uint wallMaterial) {
    float3 boundsNormal;
    if (rayBox(origin, direction, lower, upper, boundsNormal) < 0.0f) return;
    if (direction.y < -0.0001f)
        acceptPlane(hit, origin, direction,
            (lower.y - origin.y) / direction.y,
            float3(0.0f, 1.0f, 0.0f), floorMaterial, lower, upper);
    if (direction.y > 0.0001f)
        acceptPlane(hit, origin, direction,
            (upper.y - origin.y) / direction.y,
            float3(0.0f, -1.0f, 0.0f), 3u, lower, upper);
    if (abs(direction.z) > 0.0001f) {
        float t = (lower.z - origin.z) / direction.z;
        if (!doorway(room, 0u, origin + direction * t))
            acceptPlane(hit, origin, direction, t,
                float3(0.0f, 0.0f, 1.0f), wallMaterial, lower, upper);
        t = (upper.z - origin.z) / direction.z;
        if (!doorway(room, 3u, origin + direction * t))
            acceptPlane(hit, origin, direction, t,
                float3(0.0f, 0.0f, -1.0f), wallMaterial, lower, upper);
    }
    if (abs(direction.x) > 0.0001f) {
        float t = (upper.x - origin.x) / direction.x;
        if (!doorway(room, 1u, origin + direction * t))
            acceptPlane(hit, origin, direction, t,
                float3(-1.0f, 0.0f, 0.0f), wallMaterial, lower, upper);
        t = (lower.x - origin.x) / direction.x;
        if (!doorway(room, 2u, origin + direction * t))
            acceptPlane(hit, origin, direction, t,
                float3(1.0f, 0.0f, 0.0f), wallMaterial, lower, upper);
    }
}

void traceStair(thread SceneHit &hit, float3 origin, float3 direction,
    float3 lower, float3 upper) {
    float3 normal;
    float t = rayBox(origin, direction, lower, upper, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 12u, -1};
}

void traceConnector(thread SceneHit &hit, float3 origin, float3 direction,
    float3 lower, float3 upper, uint axis, float rise) {
    // Axis 0 extends north in -Z, 1 east in +X, 2 west in -X.
    float3 boundsNormal;
    if (rayBox(origin, direction, lower, upper, boundsNormal) < 0.0f) return;
    float t;
    if (axis == 0u) {
        for (uint side = 0u; side < 2u; ++side) {
            float x = side == 0u ? lower.x : upper.x;
            if (abs(direction.x) < 0.0001f) continue;
            t = (x - origin.x) / direction.x;
            acceptPlane(hit, origin, direction, t,
                float3(side == 0u ? 1.0f : -1.0f, 0.0f, 0.0f),
                13u, lower, upper);
        }
    } else {
        for (uint side = 0u; side < 2u; ++side) {
            float z = side == 0u ? lower.z : upper.z;
            if (abs(direction.z) < 0.0001f) continue;
            t = (z - origin.z) / direction.z;
            acceptPlane(hit, origin, direction, t,
                float3(0.0f, 0.0f, side == 0u ? 1.0f : -1.0f),
                13u, lower, upper);
        }
    }
    if (direction.y < -0.0001f)
        acceptPlane(hit, origin, direction, -origin.y / direction.y,
            float3(0.0f, 1.0f, 0.0f), 12u, lower, upper);
    if (direction.y > 0.0001f)
        acceptPlane(hit, origin, direction,
            (upper.y - origin.y) / direction.y,
            float3(0.0f, -1.0f, 0.0f), 3u, lower, upper);
    for (uint step = 0u; step < 6u; ++step) {
        float3 stepLower = lower, stepUpper = upper;
        if (axis == 0u) {
            stepLower.z = -mainRoomHalfExtent - float(step + 1u);
            stepUpper.z = -mainRoomHalfExtent - float(step);
        } else if (axis == 1u) {
            stepLower.x = mainRoomHalfExtent + float(step);
            stepUpper.x = mainRoomHalfExtent + float(step + 1u);
        } else {
            stepLower.x = -mainRoomHalfExtent - float(step + 1u);
            stepUpper.x = -mainRoomHalfExtent - float(step);
        }
        stepUpper.y = float(step + 1u) * rise / 6.0f;
        traceStair(hit, origin, direction, stepLower, stepUpper);
    }
}

void traceEnvironment(thread SceneHit &hit, float3 origin,
    float3 direction, ChromePose chrome) {
    traceRoom(hit, origin, direction, 0u,
        float3(-mainRoomHalfExtent, 0.0f, -mainRoomHalfExtent),
        float3(mainRoomHalfExtent, 5.5f, mainRoomHalfExtent), 1u, 2u);
    traceRoom(hit, origin, direction, 1u,
        float3(-mainRoomHalfExtent, 1.2f, -outerRoomFar),
        float3(mainRoomHalfExtent, 6.7f, -outerRoomNear), 6u, 7u);
    traceRoom(hit, origin, direction, 2u,
        float3(outerRoomNear, 0.9f, -mainRoomHalfExtent),
        float3(outerRoomFar, 6.4f, mainRoomHalfExtent), 8u, 9u);
    traceRoom(hit, origin, direction, 3u,
        float3(-outerRoomFar, 1.5f, -mainRoomHalfExtent),
        float3(-outerRoomNear, 7.0f, mainRoomHalfExtent), 10u, 11u);
    traceConnector(hit, origin, direction,
        float3(-passageHalfWidth, 0.0f, -outerRoomNear),
        float3(passageHalfWidth, 6.7f, -mainRoomHalfExtent), 0u, 1.2f);
    traceConnector(hit, origin, direction,
        float3(mainRoomHalfExtent, 0.0f, -passageHalfWidth),
        float3(outerRoomNear, 6.4f, passageHalfWidth), 1u, 0.9f);
    traceConnector(hit, origin, direction,
        float3(-outerRoomNear, 0.0f, -passageHalfWidth),
        float3(-mainRoomHalfExtent, 7.0f, passageHalfWidth), 2u, 1.5f);

    float3 normal;
    float t = rayBox(origin, direction,
        float3(-4.1f, 0.0f, -3.1f),
        float3(-1.8f, 2.5f, -0.7f), normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 14u, -1};
    t = rayBox(origin, direction,
        float3(2.1f, 0.0f, -6.5f),
        float3(4.5f, 2.5f, -4.1f), normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 4u, -1};
    t = rayChrome(origin, direction, chrome, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 20u, -1};
}

struct SurfaceMaterial {
    float3 albedo;
    float roughness;
    float metallic;
    float3 emission;
};

float hashTile(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
}

float smoothNoise(float2 p) {
    float2 cell = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    return mix(mix(hashTile(cell), hashTile(cell + float2(1.0f, 0.0f)), f.x),
        mix(hashTile(cell + float2(0.0f, 1.0f)),
            hashTile(cell + float2(1.0f, 1.0f)), f.x), f.y);
}

float3 crateTexture(texture2d<float> image, SceneHit hit) {
    // Each generated image is a flat material panel, not a cube atlas. Map it
    // once onto each face in crate-local space so paint stays aligned to its
    // face and no face wraps partway into the next repetition.
    float3 lower = hit.material == 4u
        ? float3(2.1f, 0.0f, -6.5f)
        : float3(-4.1f, 0.0f, -3.1f);
    float3 upper = hit.material == 4u
        ? float3(4.5f, 2.5f, -4.1f)
        : float3(-1.8f, 2.5f, -0.7f);
    float3 local = clamp((hit.position - lower) / (upper - lower),
        float3(0.0f), float3(1.0f));
    float2 uv;
    if (abs(hit.normal.x) > 0.5f) {
        uv = float2(hit.normal.x > 0.0f ? 1.0f - local.z : local.z,
            1.0f - local.y);
    } else if (abs(hit.normal.z) > 0.5f) {
        uv = float2(hit.normal.z > 0.0f ? local.x : 1.0f - local.x,
            1.0f - local.y);
    } else {
        uv = float2(local.x,
            hit.normal.y > 0.0f ? local.z : 1.0f - local.z);
    }
    constexpr sampler materialSampler(coord::normalized,
        address::clamp_to_edge, filter::linear);
    // Crop away the source image's uncertain outer edge. The frame below is
    // built from exact face coordinates rather than asking the model to draw it.
    float4 texel = image.sample(materialSampler,
        float2(0.06f) + uv * 0.88f);
    float3 srgb = clamp(texel.rgb / max(texel.a, 0.001f),
        float3(0.0f), float3(1.0f));
    float3 paint = select(pow((srgb + 0.055f) / 1.055f, float3(2.4f)),
        srgb / 12.92f, srgb <= 0.04045f);
    float2 nearestEdge = min(uv, 1.0f - uv);
    float edgeDistance = min(nearestEdge.x, nearestEdge.y);
    float frame = 1.0f - smoothstep(0.075f, 0.095f, edgeDistance);
    float seam = 1.0f - smoothstep(0.018f, 0.032f, edgeDistance);
    float rivet = 1.0f - smoothstep(0.012f, 0.021f,
        length(nearestEdge - float2(0.055f)));
    paint = mix(paint, paint * 0.42f + float3(0.045f), frame);
    paint = mix(paint, float3(0.018f, 0.024f, 0.03f), seam);
    return mix(paint, float3(0.32f, 0.34f, 0.35f), rivet);
}

SurfaceMaterial surfaceMaterial(SceneHit hit,
    texture2d<float> crateA, texture2d<float> crateB,
    float3 furPosition) {
    if (hit.material == 1u) {
        float2 tile = hit.position.xz * 0.7f;
        float2 seam = abs(fract(tile) - 0.5f);
        float grout = smoothstep(0.465f, 0.49f, max(seam.x, seam.y));
        float variation = 0.82f + 0.27f * smoothNoise(tile * 0.7f);
        return {mix(float3(0.19f, 0.24f, 0.28f) * variation,
            float3(0.055f, 0.072f, 0.08f), grout),
            0.68f, 0.02f, float3(0.0f)};
    }
    if (hit.material == 2u) {
        float2 uv = abs(hit.normal.x) > 0.5f
            ? hit.position.zy : hit.position.xy;
        float panel = 1.0f - smoothstep(0.46f, 0.49f,
            max(abs(fract(uv.x * 0.21f) - 0.5f),
                abs(fract(uv.y * 0.33f) - 0.5f)));
        return {float3(0.15f, 0.19f, 0.22f)
            * (0.75f + 0.3f * smoothNoise(uv * 0.7f)) * panel,
            0.85f, 0.0f, float3(0.0f)};
    }
    if (hit.material == 3u) {
        float3 emission = float3(0.0f);
        for (uint i = 0u; i < 6u; ++i) {
            PointLight light = roomLight(i);
            float radius = length(hit.position.xz - light.position.xz);
            float core = 1.0f - smoothstep(0.27f, 0.38f, radius);
            float halo = 1.0f - smoothstep(0.38f, 0.70f, radius);
            emission += light.color * (3.5f * core + 0.13f * halo);
        }
        return {float3(0.19f, 0.21f, 0.23f),
            0.83f, 0.0f, emission};
    }
    if (hit.material == 4u || hit.material == 14u) return {
        crateTexture(hit.material == 4u ? crateA : crateB, hit),
        0.5f, 0.12f, float3(0.0f)};
    if (hit.material == 20u) return {
        float3(0.91f, 0.94f, 0.97f), 0.085f, 1.0f,
        float3(0.0f)};
    if (hit.material == 6u) {
        // Cool terrazzo with stable, cell-sized colored stone chips.
        float2 uv = hit.position.xz * 2.4f;
        float chip = hashTile(floor(uv));
        float fleck = 1.0f - smoothstep(0.06f, 0.23f,
            length(fract(uv) - 0.5f));
        float3 base = float3(0.24f, 0.29f, 0.32f)
            * (0.86f + 0.22f * smoothNoise(hit.position.xz));
        return {mix(base, mix(float3(0.09f, 0.32f, 0.36f),
            float3(0.52f, 0.56f, 0.54f), chip), fleck * 0.55f),
            0.72f, 0.0f, float3(0.0f)};
    }
    if (hit.material == 7u) {
        float2 uv = abs(hit.normal.x) > 0.5f
            ? hit.position.zy : hit.position.xy;
        float row = floor(uv.y * 1.8f);
        float2 brick = fract(float2(uv.x * 0.82f + fmod(row, 2.0f) * 0.5f,
            uv.y * 1.8f));
        float mortar = step(brick.x, 0.045f) + step(brick.y, 0.075f);
        return {mix(float3(0.36f, 0.15f, 0.105f)
            * (0.75f + 0.4f * hashTile(floor(uv * 0.8f))),
            float3(0.085f, 0.09f, 0.09f), min(mortar, 1.0f)),
            0.89f, 0.0f, float3(0.0f)};
    }
    if (hit.material == 8u) {
        float2 uv = floor(hit.position.xz * 0.85f);
        float alternate = fmod(uv.x + uv.y + 200.0f, 2.0f);
        float2 edge = abs(fract(hit.position.xz * 0.85f) - 0.5f);
        float grout = smoothstep(0.46f, 0.49f, max(edge.x, edge.y));
        return {mix(mix(float3(0.40f, 0.36f, 0.27f),
            float3(0.16f, 0.30f, 0.31f), alternate),
            float3(0.07f, 0.08f, 0.08f), grout),
            0.53f, 0.0f, float3(0.0f)};
    }
    if (hit.material == 9u) {
        float2 uv = abs(hit.normal.x) > 0.5f
            ? hit.position.zy : hit.position.xy;
        float plaster = smoothNoise(uv * 0.48f)
            + 0.25f * smoothNoise(uv * 2.1f);
        return {mix(float3(0.29f, 0.31f, 0.24f),
            float3(0.47f, 0.39f, 0.25f), clamp(plaster, 0.0f, 1.0f)),
            0.93f, 0.0f, float3(0.0f)};
    }
    if (hit.material == 10u) {
        float2 uv = hit.position.xz;
        float plank = floor(uv.x * 0.63f);
        float grain = sin(uv.y * 9.0f + smoothNoise(uv * 0.3f) * 6.0f);
        float seam = smoothstep(0.46f, 0.49f,
            abs(fract(uv.x * 0.63f) - 0.5f));
        return {mix(float3(0.27f, 0.17f, 0.085f)
            * (0.75f + 0.35f * hashTile(float2(plank, 8.0f))
                + 0.06f * grain), float3(0.045f, 0.029f, 0.018f), seam),
            0.62f, 0.0f, float3(0.0f)};
    }
    if (hit.material == 11u) {
        float2 uv = abs(hit.normal.x) > 0.5f
            ? hit.position.zy : hit.position.xy;
        float rib = pow(abs(sin(uv.x * 9.0f)), 12.0f);
        return {mix(float3(0.12f, 0.23f, 0.22f),
            float3(0.28f, 0.37f, 0.31f), rib),
            0.43f, 0.46f, float3(0.0f)};
    }
    if (hit.material == 12u) {
        float stripe = hit.normal.y > 0.5f
            ? 1.0f - smoothstep(0.02f, 0.1f,
                fract(abs(hit.position.x + hit.position.z) * 2.0f))
            : 0.0f;
        return {mix(float3(0.15f, 0.17f, 0.19f),
            float3(0.5f, 0.43f, 0.2f), stripe * 0.35f),
            0.75f, 0.04f, float3(0.0f)};
    }
    if (hit.material == 13u) return {
        float3(0.16f, 0.19f, 0.21f)
            * (0.75f + 0.3f * smoothNoise(hit.position.xz * 0.7f)),
        0.88f, 0.0f, float3(0.0f)};
    if (hit.material == 16u) return {
        float3(0.012f, 0.019f, 0.023f), 0.045f, 0.02f,
        float3(0.0f)};
    if (hit.material == 19u) return {
        float3(0.035f, 0.018f, 0.012f), 0.82f, 0.0f,
        float3(0.0f)};
    if (hit.material == 5u || hit.material == 15u
        || hit.material == 17u || hit.material == 18u) {
        // Body, legs, joints and paws all use primitive-local fur coordinates,
        // so the coat follows the spider's turns and articulated gait.
        float fibers = 0.5f * smoothNoise(
            furPosition.xy * 68.0f + furPosition.z * 13.0f)
            + 0.5f * smoothNoise(
                furPosition.zy * 74.0f + furPosition.x * 17.0f);
        float flecks = hashTile(floor(furPosition.xz * 95.0f)
            + floor(furPosition.y * 37.0f));
        float mottling = smoothNoise(
            furPosition.xy * 8.0f + furPosition.z * 2.0f);
        float3 root = float3(0.18f, 0.09f, 0.045f);
        float3 tip = float3(0.43f, 0.26f, 0.13f);
        if (hit.material == 5u) {
            root = float3(0.12f, 0.075f, 0.05f);
            tip = float3(0.34f, 0.23f, 0.15f);
        } else if (hit.material == 17u) {
            root = float3(0.24f, 0.12f, 0.055f);
            tip = float3(0.58f, 0.36f, 0.18f);
        } else if (hit.material == 18u) {
            root = float3(0.23f, 0.11f, 0.055f);
            tip = float3(0.56f, 0.33f, 0.17f);
        }
        float3 coat = mix(root, tip, fibers)
            * (0.84f + 0.25f * flecks)
            * (0.83f + 0.28f * mottling);
        return {coat, 0.94f, 0.0f, float3(0.0f)};
    }
    return {float3(0.0f),
        1.0f, 0.0f, float3(0.0f)};
}

bool crateBlocksLight(float3 origin, float3 direction, float lightDistance,
    float3 lower, float3 upper) {
    float3 safe = select(direction, float3(0.00001f),
        abs(direction) < float3(0.00001f));
    float3 a = (lower - origin) / safe;
    float3 b = (upper - origin) / safe;
    float3 entry = min(a, b);
    float3 exit = max(a, b);
    float near = max(entry.x, max(entry.y, entry.z));
    float far = min(exit.x, min(exit.y, exit.z));
    return far > max(near, 0.01f) && near < lightDistance - 0.02f;
}

float3 shadePointLight(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, PointLight light, ChromePose chrome) {
    float3 toLight = light.position - hit.position;
    float distanceSquared = max(dot(toLight, toLight), 0.04f);
    float lightDistance = sqrt(distanceSquared);
    float3 l = toLight / lightDistance;
    float nDotL = max(dot(hit.normal, l), 0.0f);
    if (nDotL <= 0.0f) return float3(0.0f);

    float3 shadowOrigin = hit.position + hit.normal * 0.012f;
    if (crateBlocksLight(shadowOrigin, l, lightDistance,
            float3(-4.1f, 0.0f, -3.1f), float3(-1.8f, 2.5f, -0.7f))
        || crateBlocksLight(shadowOrigin, l, lightDistance,
            float3(2.1f, 0.0f, -6.5f), float3(4.5f, 2.5f, -4.1f))
        || chromeBlocksLight(shadowOrigin, l, lightDistance, chrome)) {
        return float3(0.0f);
    }

    float3 h = normalize(l + viewDirection);
    float nDotV = max(dot(hit.normal, viewDirection), 0.001f);
    float nDotH = max(dot(hit.normal, h), 0.0f);
    float vDotH = max(dot(viewDirection, h), 0.0f);
    float alpha = material.roughness * material.roughness;
    float alphaSquared = alpha * alpha;
    float denominator = nDotH * nDotH * (alphaSquared - 1.0f) + 1.0f;
    float distribution = alphaSquared
        / (rangePi * denominator * denominator);
    float k = (material.roughness + 1.0f)
        * (material.roughness + 1.0f) * 0.125f;
    float geometryV = nDotV / (nDotV * (1.0f - k) + k);
    float geometryL = nDotL / (nDotL * (1.0f - k) + k);
    float3 f0 = mix(float3(0.04f), material.albedo, material.metallic);
    float3 fresnel = f0 + (1.0f - f0) * pow(1.0f - vDotH, 5.0f);
    float3 diffuse = (1.0f - fresnel) * (1.0f - material.metallic)
        * material.albedo / rangePi;
    float3 specular = distribution * geometryV * geometryL * fresnel
        / max(4.0f * nDotV * nDotL, 0.001f);
    float3 radiance = light.color * light.power
        / (4.0f * rangePi * distanceSquared);
    return (diffuse + specular) * radiance * nDotL;
}

void traceScene(thread SceneHit &hit, thread float3 &furPosition,
    float3 origin, float3 direction, ChromePose chrome,
    device const GameState &game) {
    traceEnvironment(hit, origin, direction, chrome);
    for (uint i = 0u; i < enemyCount; ++i) {
        if (game.enemy[i].w <= 0.0f) continue;
        SpiderHit spider = traceSpider(origin, direction, game.enemy[i].xyz,
            game.enemyClock[i].w, game.gait[i].x, game.gait[i].y,
            spiderBodyRise(game.effects.x, i), 0.0f,
            hit.distance);
        if (spider.material != 0u) {
            hit = {spider.distance, spider.normal,
                origin + direction * spider.distance, spider.material, int(i)};
            furPosition = spider.furPosition;
        }
    }
    for (uint i = 0u; i < min(game.progress.x, targetKills); ++i) {
        FallenSpider fallen = game.fallen[i];
        float collapse = smoothstep(0.0f, 0.65f,
            game.effects.x - fallen.motion.z);
        float3 centre = fallen.pose.xyz;
        centre.y = mix(centre.y,
            stairHeight(centre.xz) + spiderScale * 0.37f, collapse);
        SpiderHit spider = traceSpider(origin, direction, centre,
            fallen.pose.w, fallen.motion.x,
            fallen.motion.y * (1.0f - collapse),
            fallen.motion.w * (1.0f - collapse), collapse,
            hit.distance);
        if (spider.material != 0u) {
            hit = {spider.distance, spider.normal,
                origin + direction * spider.distance, spider.material, -1};
            furPosition = spider.furPosition;
        }
    }
}

float3 chromeReflection(SceneHit hit, float3 incoming,
    texture2d<float> crateA, texture2d<float> crateB,
    ChromePose chrome, device const GameState &game) {
    float3 reflectedDirection = reflect(incoming, hit.normal);
    SceneHit reflectedHit = {sceneRayLimit, float3(0.0f),
        float3(0.0f), 0u, -1};
    float3 reflectedFurPosition = float3(0.0f);
    traceScene(reflectedHit, reflectedFurPosition,
        hit.position + hit.normal * 0.025f, reflectedDirection,
        chrome, game);
    if (reflectedHit.material == 0u || reflectedHit.material == 20u)
        return float3(0.06f, 0.09f, 0.12f);
    SurfaceMaterial reflected = surfaceMaterial(reflectedHit,
        crateA, crateB, reflectedFurPosition);
    float3 color = reflected.albedo * 0.32f + reflected.emission;
    for (uint i = 0u; i < 6u; ++i)
        color += shadePointLight(reflectedHit, reflected,
            -reflectedDirection, roomLight(i), chrome);
    return color;
}

float3 filmicToneMap(float3 color) {
    return clamp((color * (2.51f * color + 0.03f))
        / (color * (2.43f * color + 0.59f) + 0.14f),
        float3(0.0f), float3(1.0f));
}

void resolvedImpact(device const GameState &game, ShotImpact shot,
    thread float3 &point, thread float3 &normal) {
    point = shot.pointEnemy.xyz;
    normal = shot.normalMaterial.xyz;
    if (shot.pointEnemy.w < 1.0f) return;
    uint enemy = uint(shot.pointEnemy.w) - 1u;
    float yaw = game.enemyClock[enemy].w;
    float cosine = cos(yaw), sine = sin(yaw);
    float3 local = shot.localPointYaw.xyz;
    point = game.enemy[enemy].xyz + float3(
        cosine * local.x - sine * local.z,
        local.y,
        sine * local.x + cosine * local.z);
    float turn = yaw - shot.localPointYaw.w;
    float turnCosine = cos(turn), turnSine = sin(turn);
    normal = float3(turnCosine * normal.x - turnSine * normal.z,
        normal.y, turnSine * normal.x + turnCosine * normal.z);
}

float3 shadeImpacts(float3 color, SceneHit hit,
    device const GameState &game, texture2d<float> impactTexture) {
    if (hit.material == 0u) return color;
    constexpr sampler impactSampler(coord::normalized,
        address::clamp_to_edge, filter::linear);
    for (uint i = 0u; i < impactCount; ++i) {
        ShotImpact shot = game.impacts[i];
        float age = game.effects.x - shot.muzzleTime.w;
        bool spider = shot.pointEnemy.w > 0.0f;
        bool movingSurface = spider || uint(shot.normalMaterial.w) == 20u;
        if (age < 0.0f || age >= (movingSurface ? 0.28f : 8.0f))
            continue;
        if (spider) {
            if (hit.enemy != int(shot.pointEnemy.w) - 1) continue;
        } else if (hit.enemy >= 0
            || hit.material != uint(shot.normalMaterial.w)) {
            continue;
        }
        float3 point, normal;
        resolvedImpact(game, shot, point, normal);
        float3 offset = hit.position - point;
        if (abs(dot(offset, normal)) > (spider ? 0.10f : 0.025f)
            || dot(hit.normal, normal) < (spider ? 0.42f : 0.94f)) {
            continue;
        }
        float3 reference = abs(normal.y) < 0.85f
            ? float3(0.0f, 1.0f, 0.0f)
            : float3(0.0f, 0.0f, 1.0f);
        float3 tangent = normalize(cross(reference, normal));
        float3 bitangent = cross(normal, tangent);
        float2 local = float2(dot(offset, tangent),
            dot(offset, bitangent));
        float radius = (spider ? 0.17f : 0.24f)
            * (0.85f + 0.3f * fract(float(i) * 0.618f));
        float radial = length(local) / radius;
        if (radial >= 1.0f) continue;
        float angle = float(i) * 2.4f;
        float cosine = cos(angle), sine = sin(angle);
        float2 rotated = float2(cosine * local.x - sine * local.y,
            sine * local.x + cosine * local.y);
        float2 uv = rotated / (radius * 2.0f) + 0.5f;
        float4 texel = impactTexture.sample(impactSampler, uv);
        float3 srgb = clamp(texel.rgb / max(texel.a, 0.001f),
            float3(0.0f), float3(1.0f));
        float3 linear = select(pow((srgb + 0.055f) / 1.055f,
            float3(2.4f)), srgb / 12.92f,
            srgb <= 0.04045f);
        float edge = 1.0f - smoothstep(0.67f, 1.0f, radial);
        float fade = movingSurface ? 1.0f - smoothstep(0.12f, 0.28f, age)
            : 1.0f - smoothstep(5.5f, 8.0f, age);
        float3 mark = color * (0.14f + 1.18f * linear);
        color = mix(color, mark, 0.88f * edge * fade);
    }
    return color;
}

float3 shadeShot(float3 color, float3 origin, float3 direction,
    float sceneDistance, device const GameState &game) {
    if (game.progress.y == 0u) return color;
    ShotImpact shot = game.impacts[(game.progress.y - 1u) % impactCount];
    float age = game.effects.x - shot.muzzleTime.w;
    if (age < 0.0f || age >= 0.18f) return color;
    float fade = 1.0f - smoothstep(0.035f, 0.18f, age);
    float3 impactPoint, impactNormal;
    resolvedImpact(game, shot, impactPoint, impactNormal);
    float3 start = shot.muzzleTime.xyz;
    float3 segment = impactPoint - start;
    float segmentLengthSquared = dot(segment, segment);
    if (segmentLengthSquared < 0.01f) return color;
    float3 fromStart = origin - start;
    float along = dot(direction, segment);
    float rayOffset = dot(direction, fromStart);
    float segmentOffset = dot(segment, fromStart);
    float fraction = clamp((segmentOffset - along * rayOffset)
        / max(segmentLengthSquared - along * along, 0.0001f),
        0.0f, 1.0f);
    float3 closest = start + segment * fraction;
    float rayDistance = dot(closest - origin, direction);
    if (rayDistance > 0.0f && rayDistance < sceneDistance - 0.02f) {
        float separation = length(origin + direction * rayDistance
            - closest);
        float width = 0.012f + rayDistance * 0.0015f;
        float core = 1.0f - smoothstep(width * 0.35f,
            width, separation);
        float halo = 1.0f - smoothstep(width,
            width * 4.0f, separation);
        float ends = smoothstep(0.0f, 0.07f, fraction)
            * (1.0f - smoothstep(0.88f, 1.0f, fraction));
        color += (float3(2.7f, 1.8f, 0.95f) * core
            + float3(0.7f, 0.20f, 0.045f) * halo)
            * ends * fade;
    }
    if (shot.normalMaterial.w > 0.0f) {
        float3 flashPoint = impactPoint + impactNormal * 0.025f;
        float flashDistance = dot(flashPoint - origin, direction);
        if (flashDistance > 0.0f
            && flashDistance < sceneDistance + 0.05f) {
            float separation = length(origin + direction * flashDistance
                - flashPoint);
            float flash = 1.0f - smoothstep(0.015f,
                0.16f, separation);
            color += float3(2.0f, 0.76f, 0.18f) * flash
                * (1.0f - smoothstep(0.0f, 0.12f, age));
        }
    }
    return color;
}

float3 shadeSpiderParticles(float3 color, float3 origin,
    float3 direction, float sceneDistance, device const GameState &game) {
    for (uint i = 0u; i < impactCount; ++i) {
        ShotImpact shot = game.impacts[i];
        if (shot.pointEnemy.w < 1.0f) continue;
        float age = game.effects.x - shot.muzzleTime.w;
        if (age < 0.0f || age >= 0.65f) continue;
        float3 impact = shot.pointEnemy.xyz;
        float impactDepth = dot(impact - origin, direction);
        if (impactDepth <= 0.0f
            || length(origin + direction * impactDepth - impact) > 2.8f)
            continue;
        for (uint particle = 0u; particle < 14u; ++particle) {
            float key = float(i * 17u + particle * 31u + 1u);
            float phase = fract(sin(key * 12.9898f) * 43758.5453f);
            float spread = fract(sin(key * 78.233f) * 12345.6789f);
            float life = 0.38f + 0.27f * phase;
            if (age >= life) continue;
            float angle = 2.0f * rangePi * phase;
            float3 spray = normalize(float3(cos(angle),
                0.25f + 0.75f * spread, sin(angle))
                + shot.normalMaterial.xyz * 0.65f);
            float speed = 0.8f + 2.2f * spread;
            float3 centre = impact + shot.normalMaterial.xyz * 0.04f
                + spray * speed * age
                - float3(0.0f, 2.2f * age * age, 0.0f);
            float depth = dot(centre - origin, direction);
            if (depth <= 0.0f || depth >= sceneDistance - 0.01f)
                continue;
            float radius = 0.018f + 0.018f
                * fract(sin(key * 39.346f) * 28675.433f);
            float separation = length(origin + direction * depth
                - centre);
            if (separation >= radius * 3.0f) continue;
            float core = 1.0f - smoothstep(radius * 0.35f,
                radius, separation);
            float halo = 1.0f - smoothstep(radius,
                radius * 3.0f, separation);
            float fade = 1.0f - smoothstep(0.15f, life, age);
            float3 particleColor = mix(float3(1.8f, 2.3f, 0.13f),
                float3(0.65f, 1.9f, 0.08f), spread);
            color += particleColor * (core + 0.22f * halo) * fade;
        }
    }
    return color;
}

fragment float4 rangeFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> crateA [[texture(1)]],
    texture2d<float> crateB [[texture(2)]],
    texture2d<float> impactTexture [[texture(3)]]) {
    device const GameState &game = states[0];
    float2 screen = (in.uv - 0.5f) * u.resolutionTime.xy / u.resolutionTime.y;
    float3 forward = forwardVector(game.player.w, game.view.x);
    float3 right = normalize(cross(forward, float3(0.0f, 1.0f, 0.0f)));
    float3 up = cross(right, forward);
    float3 direction = normalize(forward * 1.1f
        + right * screen.x - up * screen.y);
    float3 origin = game.player.xyz;
    ChromePose chrome = {game.chromeRotation, game.chromeCentre.xyz};
    float3 furPosition = float3(0.0f);
    SceneHit hit = {sceneRayLimit,
        float3(0.0f), float3(0.0f), 0u, -1};
    traceScene(hit, furPosition, origin, direction, chrome, game);

    SurfaceMaterial material = surfaceMaterial(hit, crateA, crateB,
        furPosition);
    float3 color = material.emission
        + material.albedo * (1.0f - material.metallic)
            * float3(0.030f, 0.038f, 0.046f);
    for (uint i = 0u; i < 6u; ++i) {
        color += shadePointLight(hit, material, -direction,
            roomLight(i), chrome);
    }
    if (hit.material == 20u) {
        float facing = max(dot(hit.normal, -direction), 0.0f);
        float fresnel = 0.91f + 0.09f * pow(1.0f - facing, 5.0f);
        color += chromeReflection(hit, direction, crateA, crateB,
            chrome, game)
            * fresnel;
    }
    if (hit.material == 5u || hit.material == 15u
        || hit.material == 17u || hit.material == 18u) {
        float rim = 1.0f - max(dot(hit.normal, -direction), 0.0f);
        color += material.albedo * 0.32f * rim * rim;
    }
    if (hit.material == 16u) {
        // A soft reflected ceiling light follows the curved cornea as the
        // spider turns, rather than glowing from inside the eye.
        float3 reflected = reflect(direction, hit.normal);
        float glint = pow(max(dot(reflected,
            normalize(float3(-0.3f, 0.85f, -0.4f))), 0.0f), 56.0f);
        color += float3(0.65f, 0.78f, 0.84f) * glint;
        float fresnel = 1.0f - max(dot(hit.normal, -direction), 0.0f);
        color += float3(0.055f, 0.075f, 0.082f)
            * fresnel * fresnel * fresnel;
    }
    if (hit.enemy >= 0) {
        if (game.enemyClock[hit.enemy].z > 0.0f) color += float3(0.9f, 0.5f, 0.2f);
    }
    color = shadeImpacts(color, hit, game, impactTexture);
    color = mix(color, float3(0.0f),
        1.0f - exp(-hit.distance * 0.008f));
    color = shadeShot(color, origin, direction, hit.distance, game);
    color = shadeSpiderParticles(color, origin, direction,
        hit.distance, game);
    color = filmicToneMap(color * 1.6f);

    // Crosshair, health bar, target pips, and damage/muzzle feedback.
    float2 pixel = in.uv * u.resolutionTime.xy;
    float2 centre = u.resolutionTime.xy * 0.5f;
    float2 d = abs(pixel - centre);
    bool crosshair = (d.x < 1.4f && d.y > 4.0f && d.y < 12.0f)
        || (d.y < 1.4f && d.x > 4.0f && d.x < 12.0f);
    if (crosshair) color = float3(0.9f, 1.0f, 0.95f);
    if (pixel.x > 24.0f && pixel.x < 224.0f
        && pixel.y > 23.0f && pixel.y < 36.0f) {
        color = pixel.x < 24.0f + game.view.y * 2.0f
            ? float3(0.2f, 0.95f, 0.51f) : float3(0.08f, 0.18f, 0.18f);
    }
    for (uint i = 0u; i < targetKills; ++i) {
        float left = u.resolutionTime.x - 25.0f - float(targetKills - i) * 23.0f;
        if (pixel.x > left && pixel.x < left + 16.0f
            && pixel.y > 23.0f && pixel.y < 39.0f) {
            color = i < game.progress.x ? float3(0.98f, 0.71f, 0.19f)
                : float3(0.10f, 0.20f, 0.22f);
        }
    }
    if (game.view.w > 0.0f) {
        float2 muzzlePixel = centre + u.resolutionTime.y
            * float2(0.55f, 0.44f);
        float bloom = 1.0f - smoothstep(0.0f, 80.0f,
            length(pixel - muzzlePixel));
        color += float3(1.0f, 0.57f, 0.20f)
            * bloom * game.view.w * 2.4f;
    }
    color += float3(0.45f, 0.025f, 0.015f) * game.effects.y;
    if (game.progress.w != phasePlaying) {
        bool panel = abs(pixel.x - centre.x) < 180.0f
            && abs(pixel.y - centre.y) < 72.0f;
        if (panel) {
            float3 banner = game.progress.w == phaseWon
                ? float3(0.13f, 0.58f, 0.40f)
                : float3(0.67f, 0.16f, 0.12f);
            color = mix(color, banner, 0.82f);
            float2 mark = abs(pixel - centre);
            if (game.progress.w == phaseWon
                ? (mark.x < 70.0f && mark.y < 8.0f)
                : abs(mark.x - mark.y) < 5.0f && mark.x < 48.0f) {
                color = float3(1.0f);
            }
        }
    }
    color = clamp(color, float3(0.0f), float3(1.0f));
    float3 srgb = select(1.055f * pow(color, float3(1.0f / 2.4f))
        - 0.055f, 12.92f * color, color <= 0.0031308f);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

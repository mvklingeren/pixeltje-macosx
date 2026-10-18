// pixeltje:easing-v1
// pixeltje:3d-v1
#include <metal_stdlib>
using namespace metal;

// Signal Range: a five-room first-person arena shooter for gpu.program.
// The compute pass owns all mutable game state. The fragment pass traces the
// same room and walking spider drones from the camera, then draws the HUD.

constant uint enemyCount = 4u;
constant uint ordinaryEnemyCount = 3u;
constant uint bossSlot = 3u;
constant uint targetKills = enemyCount;
constant uint impactCount = 12u;
constant uint webCount = 4u;
constant uint phasePlaying = 0u;
constant uint phaseWon = 1u;
constant uint phaseLost = 2u;
constant float mainRoomHalfExtent = 18.0f;
constant float outerRoomNear = 24.0f;
constant float outerRoomFar = 60.0f;
constant float passageHalfWidth = 3.5f;
constant float sceneRayLimit = 160.0f;
constant float chromeHalfSize = 0.75f;
constant float2 chromeGroundPosition = float2(0.0f, 3.5f);
constant uint jumpPadCount = 2u;
constant float jumpPadRadius = 1.65f;
constant float northernCeilingY = 18.0f;
constant float jumpPadHeight = 0.035f;
constant float jumpPadLaunchSpeed = 18.5f;
constant float3 glassBoxLower = float3(2.4f, 0.0f, 1.9f);
constant float3 glassBoxUpper = float3(4.8f, 2.4f, 4.3f);
constant float bossRoomSouth = -70.0f;
constant float bossRoomNorth = -110.0f;
constant float bossDoorNorth = -110.0f;
constant float bossCeilingY = 13.0f;
constant uint ambushSlot = 2u;
constant uint magazineSize = 12u;
constant float reloadDuration = 1.6f;
constant float biteWindup = 0.45f;

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
    uint4 appearance;      // spider variant, reserved
};

struct WebCloth {
    float4 startTime;      // launch position XYZ and launch time
    float4 targetExpiry;   // landing position XYZ and expiry time
};

struct GameState {
    float4 player;          // position XYZ, yaw
    float4 view;            // pitch, health, shot cooldown, muzzle flash
    float4 enemy[enemyCount]; // chassis centre XYZ, health
    float4 enemyClock[enemyCount]; // attack cooldown, jump clock, hit flash, yaw
    float4 gait[enemyCount]; // distance-based cycle, movement blend, speed, turn rate
    float4 effects;         // elapsed, damage flash, last jump count, vertical speed
    float4 chromeRotation;  // local-to-world unit quaternion
    float4 chromeCentre;    // world XYZ, unused
    float4 sceneTransition; // time of victory in X, handoff sent in Y
    float4 bossScene;       // encounter time; -1 before entry, slow timer
    float4 bossAttack;      // rush clock, cooldown, fixed heading X/Z
    float4 bossWeb;         // throw cooldown and rotating cloth slot
    uint4 roomTriggers;     // northern room scare latched in X
    uint4 progress;         // kills, shots, last action count, phase
    ShotImpact impacts[impactCount];
    FallenSpider fallen[targetKills];
    WebCloth webs[webCount];
    float4 motion;          // ground velocity XZ, head-bob phase, head-bob blend
    float4 look;            // last pointer yaw/pitch, smoothed turn rates
    float4 recoil;          // camera pitch/yaw kick, weapon kick, camera shake
    float4 weapon;          // rounds loaded, reload time left, hit marker time/kind
    float4 hurt;            // attacker XZ, damage indicator, landing dip
    float4 ambush;          // drop start time (-1 before trigger), fall speed, landed
    float4 senses[enemyCount];   // last known player XZ, awareness, bite clock
    float4 reaction[enemyCount]; // flinch time, knockback XZ, startle time
};

static_assert(sizeof(GameState) <= 1792,
    "The GPU Program game buffer must contain player feel and spider senses");

struct SceneHit {
    float distance;
    float3 normal;
    float3 position;
    uint material;
    int enemy;
    uint variant;            // spider appearance or fixture placement index
    float4 fur;              // spider strand tangent and height; zero elsewhere
};

struct ChromePose {
    float4 rotation;
    float3 centre;
};

void traceEnvironment(thread SceneHit &hit, float3 origin,
    float3 direction, ChromePose chrome, device const GameState &game);

constant float rangePi = 3.14159265f;

struct SurfaceMaterial {
    float3 albedo;
    float roughness;
    float metallic;
    float3 emission;
};

float rayBox(float3 origin, float3 direction, float3 lower, float3 upper,
    thread float3 &normal);
float hashTile(float2 p);

#include "SignalRangeTLBox.metal"
#include "SignalRangeCeilingLamps.metal"

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

struct PointLight {
    float3 position;
    float3 color;
    float power;
    bool shadedAbove;   // an opaque dome shade keeps this light below it
};

PointLight roomLight(uint index, float time) {
    if (index < ceilingLampCount) {
        CeilingLamp lamp = ceilingLamps[index];
        return {ceilingLampEmitter(lamp), lamp.tint, lamp.power,
            lamp.type == CeilingLampType::pendant};
    }
    if (index == 3u) {
        CeilingTLBox fixture = ceilingTLBox(0u);
        return {fixture.centre - float3(0.0f, 0.36f, 0.0f),
            fixture.tint, 600.0f * tlBoxFlicker(time, fixture.phase)};
    }
    if (index == 4u) return {float3(42.0f, 5.95f, 0.0f),
        float3(1.0f, 0.75f, 0.45f), 540.0f};
    if (index == 5u) return {float3(-42.0f, 6.55f, 0.0f),
        float3(0.65f, 1.0f, 0.75f), 550.0f};
    if (index == 6u) return {float3(-12.0f, 10.0f, -90.0f),
        float3(0.90f, 0.11f, 0.08f), 1500.0f};
    return {float3(12.0f, 10.0f, -90.0f),
        float3(0.44f, 0.68f, 0.90f), 1400.0f};
}

float stairHeight(float2 point);
bool walkable(float2 point);

void damagePlayer(device GameState &game, float amount, float2 source,
    float flash) {
    game.view.y = max(game.view.y - amount, 0.0f);
    game.effects.y = flash;
    game.hurt.xyz = float3(source, 1.0f);
    game.recoil.w = max(game.recoil.w, 0.6f + amount * 0.015f);
}

// Head bob and landing dip move the eye, never the collision position.
float3 eyeOffset(device const GameState &game) {
    float side = 0.022f * game.motion.w * sin(game.motion.z);
    return float3(cos(game.player.w) * side,
        0.034f * game.motion.w * sin(2.0f * game.motion.z) - game.hurt.w,
        sin(game.player.w) * side);
}

// The held pistol has its own frame: X right, Y up, Z along the barrel, origin
// where the grip meets the frame. The pose places it in view space (X right,
// Y up, Z forward from the eye), so drawing and tracers share one muzzle.
struct GunPose {
    float3 pivot;
    float3x3 basis;
    float slide;            // slide travel toward the shooter after a shot
};

constant float3 gunMuzzle = float3(0.0f, 0.032f, 0.168f);

GunPose gunPose(device const GameState &game) {
    float reload = game.weapon.y > 0.0f
        ? sin(rangePi * (1.0f - game.weapon.y / reloadDuration)) : 0.0f;
    float kick = game.recoil.z;
    float bob = game.motion.w, phase = game.motion.z;
    float2 sway = game.look.zw;
    // The gun lags behind turns, bobs with steps, kicks back on each shot
    // and dips out of view while the magazine is changed.
    float3 pivot = float3(0.17f, -0.17f, 0.36f) + float3(
        0.010f * bob * sin(phase) - 0.006f * sway.x,
        -0.007f * bob * abs(cos(phase)) - 0.006f * sway.y
            + 0.010f * kick - 0.12f * reload - 0.5f * game.hurt.w,
        -0.045f * kick);
    float pitch = 0.17f * kick - 0.5f * reload - 0.02f * sway.y;
    float yaw = -0.03f * sway.x;
    float roll = 0.55f * reload;
    float3 f = float3(sin(yaw) * cos(pitch), sin(pitch),
        cos(yaw) * cos(pitch));
    float3 r = normalize(float3(f.z, 0.0f, -f.x));
    float3 up = cross(f, r);
    return {pivot, float3x3(r * cos(roll) + up * sin(roll),
        up * cos(roll) - r * sin(roll), f),
        0.028f * saturate((kick - 0.55f) / 0.45f)};
}

#include "SignalRangeSpider.metal"

void resetGame(device GameState &game) {
    game.player = float4(0.0f, 1.55f, 12.0f, 0.0f);
    game.view = float4(0.0f, 100.0f, 0.0f, 0.0f);
    game.effects = float4(0.0f);
    game.sceneTransition = float4(0.0f);
    game.bossScene = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    game.bossAttack = float4(0.0f, 2.0f, 0.0f, 1.0f);
    game.bossWeb = float4(2.1f, 0.0f, 0.0f, 0.0f);
    game.roomTriggers = uint4(0u);
    updateChromePose(game);
    game.progress = uint4(0u);
    game.motion = float4(0.0f);
    // A yaw outside the pointer range marks the first tick, so it has no sway.
    game.look = float4(100.0f, 0.0f, 0.0f, 0.0f);
    game.recoil = float4(0.0f);
    game.weapon = float4(float(magazineSize), 0.0f, 0.0f, 0.0f);
    game.hurt = float4(0.0f);
    game.ambush = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    for (uint i = 0u; i < impactCount; ++i) {
        game.impacts[i].muzzleTime = float4(0.0f, 0.0f, 0.0f, -100.0f);
        game.impacts[i].pointEnemy = float4(0.0f);
        game.impacts[i].normalMaterial = float4(0.0f);
        game.impacts[i].localPointYaw = float4(0.0f);
    }
    for (uint i = 0u; i < targetKills; ++i) {
        game.fallen[i].pose = float4(0.0f);
        game.fallen[i].motion = float4(0.0f);
        game.fallen[i].appearance = uint4(0u);
    }
    for (uint i = 0u; i < webCount; ++i) {
        game.webs[i].startTime = float4(0.0f, 0.0f, 0.0f, -100.0f);
        game.webs[i].targetExpiry = float4(0.0f);
    }
    for (uint i = 0u; i < enemyCount; ++i) {
        game.enemy[i] = float4(spawnPosition(i), i == bossSlot ? 14.0f : 2.0f);
        float2 toPlayer = game.player.xz - game.enemy[i].xz;
        game.enemyClock[i] = float4(0.0f, -0.55f, 0.0f,
            i == bossSlot ? atan2(toPlayer.x, -toPlayer.y) : idleYaw(i));
        // Range spiders start unaware; the ambush spider is not yet present.
        game.senses[i] = float4(game.enemy[i].xz,
            i == bossSlot ? 1.0f : (i == ambushSlot ? -1.0f : 0.0f), -1.0f);
        game.reaction[i] = float4(0.0f);
        game.gait[i] = float4(0.07f + float(i) * 0.31f,
            0.0f, 0.0f, 0.0f);
    }
}

kernel void initializeRange(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id == 0u) resetGame(states[0]);
}

float rayBox(float3 origin, float3 direction, float3 lower, float3 upper,
    thread float3 &normal) {
    return pixeltje_3d::rayBox(origin, direction, lower, upper,
        0.01f, normal);
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
    if (abs(x) <= 4.6f && z >= bossRoomSouth && z <= -outerLimit)
        return true;
    if (abs(x) <= 21.5f && z >= bossRoomNorth + 0.45f
        && z <= bossRoomSouth) return true;
    if (x >= roomLimit && x <= outerRoomNear
        && abs(z) <= passageLimit) return true;
    if (x >= outerRoomNear && x <= outerLimit
        && abs(z) <= roomLimit) return true;
    if (x <= -roomLimit && x >= -outerRoomNear
        && abs(z) <= passageLimit) return true;
    return x <= -outerRoomNear && x >= -outerLimit
        && abs(z) <= roomLimit;
}

float entranceDoorBottom(device const GameState &game) {
    return game.bossScene.x < 0.0f ? 9.0f
        : mix(9.0f, 1.2f, smoothstep(0.0f, 0.85f, game.bossScene.x));
}

float rearDoorBottom(device const GameState &game) {
    if (game.bossScene.x < 0.0f) return 1.2f;
    float open = smoothstep(0.85f, 1.45f, game.bossScene.x)
        * (1.0f - smoothstep(4.2f, 4.85f, game.bossScene.x));
    return mix(1.2f, 11.0f, open);
}

bool insideNorthernEntryTrigger(float2 position) {
    // An invisible strip spans the entire room width, including the doorway.
    // Position.y is the player's world Z coordinate.
    return abs(position.x) <= mainRoomHalfExtent
        && position.y <= -outerRoomNear
        && position.y >= -outerRoomNear - 3.0f;
}

float2 jumpPadCentre(uint index) {
    return float2(index == 0u ? -8.0f : 8.0f, -43.0f);
}

bool onJumpPad(float2 position) {
    for (uint i = 0u; i < jumpPadCount; ++i) {
        float2 offset = position - jumpPadCentre(i);
        if (dot(offset, offset) <= jumpPadRadius * jumpPadRadius)
            return true;
    }
    return false;
}

kernel void advanceRange(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device uint *sceneRequest [[buffer(2)]],
    device uint *shotAudioEvent [[buffer(3)]],
    device uint *scareAudioEvent [[buffer(4)]],
    device uint *launchAudioEvent [[buffer(5)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.10f);
    uint action = uint(u.pointer.z);
    uint jumpAction = uint(u.movement.z);
    game.effects.x += dt;
    if (game.bossScene.x >= 0.0f) game.bossScene.x += dt;
    game.bossScene.y = max(game.bossScene.y - dt, 0.0f);
    updateChromePose(game);
    game.effects.y = max(game.effects.y - dt, 0.0f);
    game.view.z = max(game.view.z - dt, 0.0f);
    game.view.w = max(game.view.w - dt, 0.0f);
    game.recoil.xy *= exp(-dt * 9.0f);
    game.recoil.z *= exp(-dt * 14.0f);
    game.recoil.w = max(game.recoil.w - dt * 1.8f, 0.0f);
    game.hurt.z = max(game.hurt.z - dt / 1.2f, 0.0f);
    game.hurt.w *= exp(-dt * 7.0f);
    game.weapon.z = max(game.weapon.z - dt, 0.0f);
    if (game.weapon.y > 0.0f) {
        game.weapon.y = max(game.weapon.y - dt, 0.0f);
        if (game.weapon.y <= 0.0f) game.weapon.x = float(magazineSize);
    }
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
    // Recoil is added on top and recovers by itself.
    float2 look = clamp(u.pointer.xy, float2(0.0f), float2(1.0f));
    float baseYaw = (look.x - 0.5f) * 6.2831853f;
    float basePitch = (0.5f - look.y) * 1.9f;
    if (game.look.x > 50.0f) game.look.xy = float2(baseYaw, basePitch);
    float2 turn = float2(atan2(sin(baseYaw - game.look.x),
        cos(baseYaw - game.look.x)), basePitch - game.look.y);
    game.look.xy = float2(baseYaw, basePitch);
    game.look.zw = mix(game.look.zw,
        dt > 0.0f ? clamp(turn / dt, float2(-4.0f), float2(4.0f)) : float2(0.0f),
        1.0f - exp(-dt * 10.0f));
    game.player.w = baseYaw + game.recoil.y;
    game.view.x = basePitch + game.recoil.x;
    float2 move = clamp(u.movement.xy, float2(-1.0f), float2(1.0f));
    if (game.bossScene.x >= 0.0f && game.bossScene.x < 5.0f)
        move = float2(0.0f);
    if (length(move) > 1.0f) move = normalize(move);
    float2 forward = float2(sin(game.player.w), -cos(game.player.w));
    float2 right = float2(cos(game.player.w), sin(game.player.w));
    for (uint i = 0u; i < webCount; ++i) {
        WebCloth web = game.webs[i];
        float age = game.effects.x - web.startTime.w;
        if (age < 0.62f || game.effects.x > web.targetExpiry.w) continue;
        if (length(game.player.xz - web.targetExpiry.xz) < 2.3f)
            game.bossScene.y = 1.0f;
    }
    float speed = game.bossScene.y > 0.0f ? 1.75f : 4.6f;
    float2 previousPosition = game.player.xz;
    bool wasGrounded = game.player.y <= 1.55f + stairHeight(previousPosition)
        + (onJumpPad(previousPosition) ? jumpPadHeight : 0.0f) + 0.001f;
    // Feet accelerate and brake quickly; in the air the body keeps momentum.
    game.motion.xy = mix(game.motion.xy,
        (right * move.x + forward * move.y) * speed,
        1.0f - exp(-dt * (wasGrounded ? 11.0f : 2.2f)));
    float2 next = previousPosition + game.motion.xy * dt;
    // Resolve axes independently so a diagonal approach slides along a wall.
    float2 position = previousPosition;
    if (walkable(float2(next.x, position.y))) position.x = next.x;
    else game.motion.x = 0.0f;
    if (walkable(float2(position.x, next.y))) position.y = next.y;
    else game.motion.y = 0.0f;
    next = position;
    if (game.progress.x < ordinaryEnemyCount
        && previousPosition.y >= -outerRoomFar + 0.3f)
        next.y = max(next.y, -outerRoomFar + 0.3f);
    if (game.bossScene.x >= 0.0f
        && previousPosition.y < bossRoomSouth - 0.35f)
        next.y = min(next.y, bossRoomSouth - 0.35f);
    pushOutOfObstacle(next, float2(-4.1f, -3.1f), float2(-1.8f, -0.7f));
    pushOutOfObstacle(next, float2(2.1f, -6.5f), float2(4.5f, -4.1f));
    pushOutOfObstacle(next, glassBoxLower.xz, glassBoxUpper.xz);
    pushOutOfChrome(next);
    game.player.xz = next;
    // Head bob follows the distance actually walked on the ground.
    float walked = length(next - previousPosition);
    game.motion.z = fmod(game.motion.z + walked * 1.85f, 2.0f * rangePi);
    game.motion.w = mix(game.motion.w, wasGrounded
            ? saturate(walked / max(dt * 4.6f, 0.00001f)) : 0.0f,
        1.0f - exp(-dt * 8.0f));
    if (game.bossScene.x < 0.0f
        && game.progress.x >= ordinaryEnemyCount
        && next.y < bossRoomSouth - 2.6f) {
        game.bossScene.x = 0.0f;
    }
    if (next.y >= -outerRoomNear + 0.5f) {
        game.roomTriggers.x = 0u;
    } else if (game.roomTriggers.x == 0u
        && (insideNorthernEntryTrigger(next)
            || (previousPosition.y >= -outerRoomNear
                && next.y < -outerRoomNear))) {
        scareAudioEvent[0] = 1u;
        game.roomTriggers.x = 1u;
        if (game.roomTriggers.y == 0u) {
            game.roomTriggers.y = 1u;
            startAmbush(game);
        }
    }
    bool overJumpPad = onJumpPad(next);
    float groundY = 1.55f + stairHeight(next)
        + (overJumpPad ? jumpPadHeight : 0.0f);
    bool grounded = game.player.y <= groundY + 0.001f;
    if (jumpAction > uint(game.effects.z)) {
        game.effects.z = float(jumpAction);
        if (grounded && (game.bossScene.x < 0.0f
            || game.bossScene.x >= 5.0f)) game.effects.w = 5.2f;
    }
    if (grounded && overJumpPad) {
        game.effects.w = jumpPadLaunchSpeed;
        launchAudioEvent[0] = 1u;
    }
    if (!grounded || game.effects.w > 0.0f) {
        game.effects.w -= 13.0f * dt;
        game.player.y += game.effects.w * dt;
    }
    if (game.player.y <= groundY) {
        if (game.effects.w < -3.0f)
            game.hurt.w = max(game.hurt.w, min(-game.effects.w * 0.012f, 0.16f));
        game.player.y = groundY;
        game.effects.w = 0.0f;
    }
    if (next.y < -outerRoomNear && game.player.y > northernCeilingY - 0.35f) {
        game.player.y = northernCeilingY - 0.35f;
        game.effects.w = min(game.effects.w, 0.0f);
    }

    advanceSpiders(game, dt);
    advanceBoss(game, dt);

    if (action > game.progress.z) {
        game.progress.z = action;
        if (game.view.z <= 0.0f && game.weapon.x >= 1.0f
            && (game.bossScene.x < 0.0f || game.bossScene.x >= 5.0f)) {
            game.view.z = 0.22f;
            game.view.w = 0.11f;
            game.progress.y += 1u;
            game.weapon.x -= 1.0f;
            // An empty magazine reloads by itself; there is no reload key.
            if (game.weapon.x < 1.0f) game.weapon.y = reloadDuration;
            shotAudioEvent[0] = 1u;
            hearGunshot(game);
            float3 eye = game.player.xyz + eyeOffset(game);
            float3 shotDirection = pixeltje_3d::forward(
                game.player.w, game.view.x);
            float3 normal;
            float3 impactNormal = -shotDirection;
            uint impactMaterial = 0u;
            ChromePose chrome = {game.chromeRotation,
                game.chromeCentre.xyz};
            SceneHit environment = {sceneRayLimit, float3(0.0f),
                float3(0.0f), 0u, -1, 0u};
            traceEnvironment(environment, eye,
                shotDirection, chrome, game);
            float block = environment.material != 0u
                ? environment.distance : sceneRayLimit;
            if (environment.material != 0u) {
                impactNormal = environment.normal;
                impactMaterial = environment.material;
            }
            float t = rayBox(eye, shotDirection,
                float3(-4.1f, 0.0f, -3.1f),
                float3(-1.8f, 2.5f, -0.7f), normal);
            if (t > 0.0f && t < block) {
                block = t;
                impactNormal = normal;
                impactMaterial = 14u;
            }
            t = rayBox(eye, shotDirection,
                float3(2.1f, 0.0f, -6.5f),
                float3(4.5f, 2.5f, -4.1f), normal);
            if (t > 0.0f && t < block) {
                block = t;
                impactNormal = normal;
                impactMaterial = 4u;
            }
            t = rayChrome(eye, shotDirection,
                chrome, normal);
            if (t > 0.0f && t < block) {
                block = t;
                impactNormal = normal;
                impactMaterial = 20u;
            }
            int target = -1;
            for (uint i = 0u; i < enemyCount; ++i) {
                if (!spiderActive(game, i)) continue;
                SpiderHit spider = traceSpider(eye, shotDirection,
                    game.enemy[i].xyz, spiderVariantForSlot(i),
                    game.enemyClock[i].w,
                    game.gait[i].x, game.gait[i].y,
                    spiderBodyRise(game.effects.x, i), 0.0f,
                    spiderRear(game, i), block);
                if (spider.material != 0u) {
                    block = spider.distance;
                    target = int(i);
                    impactNormal = spider.normal;
                    impactMaterial = spider.material;
                }
            }
            float3 impactPoint = eye + shotDirection * block;
            if (target < 0) {
                if (environment.material == 0u) {
                    impactPoint = eye + shotDirection * 28.0f;
                    impactMaterial = 0u;
                }
            }
            float3 muzzleRight = normalize(cross(shotDirection,
                float3(0.0f, 1.0f, 0.0f)));
            float3 muzzleUp = cross(muzzleRight, shotDirection);
            GunPose gun = gunPose(game);
            float3 muzzle = gun.pivot + gun.basis * gunMuzzle;
            ShotImpact shot;
            shot.muzzleTime = float4(eye + muzzleRight * muzzle.x
                + muzzleUp * muzzle.y + shotDirection * muzzle.z,
                game.effects.x);
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
            // The kick lands after the shot, so the first round goes where
            // the crosshair was; follow-ups climb until the recoil recovers.
            game.recoil.x += 0.032f;
            game.recoil.y += 0.024f
                * (hashTile(float2(float(game.progress.y), 7.3f)) - 0.5f);
            game.recoil.z = 1.0f;
            if (target >= 0) {
                uint slot = uint(target);
                SpiderTraits traits = spiderTraits(spiderVariantForSlot(slot));
                // Head and eyes sit at the front of the chassis (-Z local).
                float3 head = shot.localPointYaw.xyz / traits.scale
                    - float3(0.0f, 0.05f, -0.45f);
                bool headshot = length(head / float3(0.48f, 0.38f, 0.50f))
                    < 1.0f;
                game.enemy[slot].w -= headshot ? 2.0f : 1.0f;
                game.enemyClock[slot].z = 0.24f;
                game.weapon.zw = headshot ? float2(0.30f, 2.0f)
                    : float2(0.22f, 1.0f);
                if (slot == bossSlot) {
                    game.reaction[slot].x = 0.12f;
                } else {
                    float2 push = shotDirection.xz;
                    game.reaction[slot].xyz = float3(0.32f,
                        length(push) > 0.01f ? normalize(push) * 2.6f
                            : float2(0.0f));
                    game.senses[slot].w = -1.0f;   // a hit interrupts a bite
                    wakeSpider(game, slot, game.player.xz);
                }
                if (game.enemy[target].w <= 0.0f) {
                    game.weapon.zw = float2(0.40f, 3.0f);
                    uint fallenIndex = game.progress.x;
                    if (fallenIndex < targetKills) {
                        game.fallen[fallenIndex].pose = float4(
                            game.enemy[target].xyz,
                            game.enemyClock[target].w);
                        game.fallen[fallenIndex].motion = float4(
                            game.gait[target].x, game.gait[target].y,
                            game.effects.x,
                            spiderBodyRise(game.effects.x, uint(target)));
                        game.fallen[fallenIndex].appearance = uint4(
                            uint(spiderVariantForSlot(uint(target))), 0u, 0u, 0u);
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
    hit = {t, normal, p, material, -1, 0u};
}

bool doorway(uint room, uint wall, float3 point) {
    float height = ((room == 4u && wall == 0u)
        || (room == 5u && wall == 3u)) ? 11.0f
        : ((room >= 4u || (room == 1u && wall == 0u)) ? 9.0f : 3.5f);
    if (point.y > height) return false;
    if (room == 0u) {
        return (wall == 0u && abs(point.x) < passageHalfWidth)
            || ((wall == 1u || wall == 2u)
                && abs(point.z) < passageHalfWidth);
    }
    return (room == 1u && wall == 3u
            && abs(point.x) < passageHalfWidth)
        || (room == 1u && wall == 0u
            && abs(point.x) < 5.0f)
        || (room == 2u && wall == 2u
            && abs(point.z) < passageHalfWidth)
        || (room == 3u && wall == 1u
            && abs(point.z) < passageHalfWidth)
        || (room == 4u && wall == 3u && abs(point.x) < 5.0f)
        || (room == 4u && wall == 0u && abs(point.x) < 10.5f)
        || (room == 5u && wall == 3u && abs(point.x) < 10.5f)
        || (room == 6u && (wall == 0u || wall == 3u)
            && abs(point.x) < 5.0f);
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
        hit = {t, normal, origin + direction * t, 12u, -1, 0u};
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

void traceJumpPad(thread SceneHit &hit, float3 origin, float3 direction,
    uint index) {
    float2 centre = jumpPadCentre(index);
    float2 offset = origin.xz - centre;
    float top = 1.2f + jumpPadHeight;
    float radiusSquared = jumpPadRadius * jumpPadRadius;
    if (direction.y < -0.0001f) {
        float t = (top - origin.y) / direction.y;
        float2 point = offset + direction.xz * t;
        if (t > 0.01f && t < hit.distance
            && dot(point, point) <= radiusSquared)
            hit = {t, float3(0.0f, 1.0f, 0.0f),
                origin + direction * t, 25u, -1, index};
    }

    // The shallow cylindrical edge is visible at grazing angles without
    // making the pad stand proud of the floor.
    float a = dot(direction.xz, direction.xz);
    if (a < 0.000001f) return;
    float b = dot(offset, direction.xz);
    float discriminant = b * b - a * (dot(offset, offset) - radiusSquared);
    if (discriminant < 0.0f) return;
    float root = sqrt(discriminant);
    float t = (-b - root) / a;
    if (t <= 0.01f) t = (-b + root) / a;
    float y = origin.y + direction.y * t;
    if (t > 0.01f && t < hit.distance
        && y >= 1.2f && y <= top) {
        float3 position = origin + direction * t;
        hit = {t, normalize(float3(position.x - centre.x, 0.0f,
            position.z - centre.y)), position, 25u, -1, index};
    }
}

void traceSlidingDoor(thread SceneHit &hit, float3 origin,
    float3 direction, float halfWidth, float z, float bottom,
    float top, uint variant) {
    if (bottom >= top - 0.01f) return;
    float3 normal;
    float t = rayBox(origin, direction,
        float3(-halfWidth, bottom, z - 0.20f),
        float3(halfWidth, top, z + 0.20f), normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 27u, -1, variant};
}

void traceEnvironment(thread SceneHit &hit, float3 origin,
    float3 direction, ChromePose chrome, device const GameState &game) {
    traceRoom(hit, origin, direction, 0u,
        float3(-mainRoomHalfExtent, 0.0f, -mainRoomHalfExtent),
        float3(mainRoomHalfExtent, 5.5f, mainRoomHalfExtent), 1u, 2u);
    traceRoom(hit, origin, direction, 1u,
        float3(-mainRoomHalfExtent, 1.2f, -outerRoomFar),
        float3(mainRoomHalfExtent, northernCeilingY, -outerRoomNear), 6u, 7u);
    traceRoom(hit, origin, direction, 2u,
        float3(outerRoomNear, 0.9f, -mainRoomHalfExtent),
        float3(outerRoomFar, 6.4f, mainRoomHalfExtent), 8u, 9u);
    traceRoom(hit, origin, direction, 3u,
        float3(-outerRoomFar, 1.5f, -mainRoomHalfExtent),
        float3(-outerRoomNear, 7.0f, mainRoomHalfExtent), 10u, 11u);
    traceRoom(hit, origin, direction, 6u,
        float3(-5.0f, 1.2f, bossRoomSouth),
        float3(5.0f, 9.0f, -outerRoomFar), 12u, 13u);
    traceRoom(hit, origin, direction, 4u,
        float3(-22.0f, 1.2f, bossRoomNorth),
        float3(22.0f, bossCeilingY, bossRoomSouth), 28u, 29u);
    traceRoom(hit, origin, direction, 5u,
        float3(-11.0f, 1.2f, -130.0f),
        float3(11.0f, bossCeilingY, bossRoomNorth), 28u, 29u);
    traceConnector(hit, origin, direction,
        float3(-passageHalfWidth, 0.0f, -outerRoomNear),
        float3(passageHalfWidth, 6.7f, -mainRoomHalfExtent), 0u, 1.2f);
    traceConnector(hit, origin, direction,
        float3(mainRoomHalfExtent, 0.0f, -passageHalfWidth),
        float3(outerRoomNear, 6.4f, passageHalfWidth), 1u, 0.9f);
    traceConnector(hit, origin, direction,
        float3(-outerRoomNear, 0.0f, -passageHalfWidth),
        float3(-mainRoomHalfExtent, 7.0f, passageHalfWidth), 2u, 1.5f);

    // The first gate unlocks after the range is clear. The arena gate drops
    // behind the player; the far gate admits the boss and then seals.
    traceSlidingDoor(hit, origin, direction, 5.0f, -outerRoomFar,
        game.progress.x >= ordinaryEnemyCount ? 9.0f : 1.2f,
        9.0f, 0u);
    traceSlidingDoor(hit, origin, direction, 5.0f, bossRoomSouth,
        entranceDoorBottom(game), 9.0f, 1u);
    traceSlidingDoor(hit, origin, direction, 10.5f, bossDoorNorth,
        rearDoorBottom(game), 11.0f, 2u);

    for (uint i = 0u; i < jumpPadCount; ++i)
        traceJumpPad(hit, origin, direction, i);

    float3 normal;
    float t = rayBox(origin, direction,
        float3(-4.1f, 0.0f, -3.1f),
        float3(-1.8f, 2.5f, -0.7f), normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 14u, -1, 0u};
    t = rayBox(origin, direction,
        float3(2.1f, 0.0f, -6.5f),
        float3(4.5f, 2.5f, -4.1f), normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 4u, -1, 0u};
    t = rayChrome(origin, direction, chrome, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, 20u, -1, 0u};
    for (uint i = 0u; i < ceilingTLBoxCount; ++i)
        traceCeilingTLBox(hit, origin, direction, ceilingTLBox(i), i);
    for (uint i = 0u; i < ceilingLampCount; ++i)
        traceCeilingLamp(hit, origin, direction, ceilingLamps[i], i);
}

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
    float3 furPosition, float time) {
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
        // The arena lamps show their own armatures instead of a glow spot.
        float3 emission = float3(0.0f);
        for (uint i = ceilingLampCount; i < 8u; ++i) {
            PointLight light = roomLight(i, time);
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
    if (hit.material == 22u || hit.material == 23u)
        return tlBoxSurfaceMaterial(hit.material,
            ceilingTLBox(hit.variant), time);
    if (hit.material >= 31u && hit.material <= 33u)
        return ceilingLampSurfaceMaterial(hit.material,
            ceilingLamps[hit.variant]);
    if (hit.material == 25u) {
        if (hit.normal.y < 0.5f) return {
            float3(0.21f, 0.24f, 0.26f), 0.38f, 0.86f,
            float3(0.0f)};
        float2 local = hit.position.xz - jumpPadCentre(hit.variant);
        float radius = length(local);
        float brushed = 0.92f + 0.08f * smoothNoise(local * 14.0f);
        float groove = 1.0f - smoothstep(0.018f, 0.055f,
            abs(radius - 1.33f));
        float rim = smoothstep(1.47f, 1.62f, radius);
        float chevron = abs(abs(local.x) - (0.28f + abs(local.y) * 0.55f));
        float arrow = (1.0f - smoothstep(0.07f, 0.16f, chevron))
            * step(-0.92f, local.y) * step(local.y, 0.92f);
        float3 steel = float3(0.37f, 0.40f, 0.42f) * brushed;
        steel = mix(steel, float3(0.12f, 0.15f, 0.17f), groove);
        steel = mix(steel, float3(0.61f, 0.64f, 0.65f), arrow * 0.76f);
        steel = mix(steel, float3(0.52f, 0.55f, 0.57f), rim);
        return {steel, 0.29f, 0.84f, float3(0.0f)};
    }
    if (hit.material == 27u) {
        float rib = 1.0f - smoothstep(0.04f, 0.12f,
            abs(fract(hit.position.y * 0.8f) - 0.5f));
        float warning = 1.0f - smoothstep(0.0f, 0.35f,
            abs(hit.position.x) / (hit.variant == 2u ? 10.5f : 5.0f));
        return {mix(float3(0.09f, 0.11f, 0.13f),
            float3(0.34f, 0.37f, 0.39f), rib * 0.55f)
            + float3(0.20f, 0.018f, 0.012f) * warning,
            0.34f, 0.74f, float3(0.0f)};
    }
    if (hit.material == 28u) {
        float2 grid = abs(fract(hit.position.xz * 0.35f) - 0.5f);
        float seam = smoothstep(0.46f, 0.49f, max(grid.x, grid.y));
        return {mix(float3(0.115f, 0.13f, 0.15f),
            float3(0.025f, 0.03f, 0.035f), seam),
            0.68f, 0.11f, float3(0.0f)};
    }
    if (hit.material == 29u) {
        float2 uv = abs(hit.normal.x) > 0.5f
            ? hit.position.zy : hit.position.xy;
        float panel = 1.0f - smoothstep(0.45f, 0.49f,
            abs(fract(uv.x * 0.18f) - 0.5f));
        return {float3(0.12f, 0.14f, 0.16f) * panel,
            0.75f, 0.18f, float3(0.0f)};
    }
    if (hit.material == 26u) return {
        float3(0.31f, 0.43f, 0.46f), 0.39f, 0.06f,
        float3(0.035f, 0.075f, 0.082f)};
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
    if (hit.material == 5u || hit.material == 15u
        || hit.material == 16u || hit.material == 17u
        || hit.material == 18u || hit.material == 19u)
        return spiderSurfaceMaterial(hit.material, furPosition,
            hit.fur, SpiderVariant(hit.variant));
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
    // The northern fixture is shaded by its housing above the diffusers.
    // Keep its light inside the room and off the nearby ceiling surface.
    if (light.position.z <= bossRoomSouth
        && hit.position.z > bossRoomSouth) return float3(0.0f);
    if (light.position.z < -outerRoomNear
        && light.position.z > bossRoomSouth
        && (hit.position.z > -mainRoomHalfExtent
            || abs(hit.position.x) > mainRoomHalfExtent
            || (hit.material == 3u && hit.position.z < -outerRoomNear)))
        return float3(0.0f);
    float3 toLight = light.position - hit.position;
    float distanceSquared = max(dot(toLight, toLight), 0.04f);
    float lightDistance = sqrt(distanceSquared);
    float3 l = toLight / lightDistance;
    float nDotL = max(dot(hit.normal, l), 0.0f);
    float shade = light.shadedAbove ? smoothstep(-0.04f, 0.08f, l.y) : 1.0f;
    if (nDotL <= 0.0f || shade <= 0.0f) return float3(0.0f);

    float3 shadowOrigin = hit.position + hit.normal * 0.012f;
    if (crateBlocksLight(shadowOrigin, l, lightDistance,
            float3(-4.1f, 0.0f, -3.1f), float3(-1.8f, 2.5f, -0.7f))
        || crateBlocksLight(shadowOrigin, l, lightDistance,
            float3(2.1f, 0.0f, -6.5f), float3(4.5f, 2.5f, -4.1f))
        || chromeBlocksLight(shadowOrigin, l, lightDistance, chrome)) {
        return float3(0.0f);
    }

    float3 radiance = light.color * light.power * shade
        / (4.0f * rangePi * distanceSquared);
    if (dot(hit.fur.xyz, hit.fur.xyz) > 0.0f)
        return spiderFurReflectance(material.albedo, hit.fur, hit.normal,
            l, viewDirection) * radiance;
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
    float3 fresnel = pixeltje_3d::fresnelSchlick(vDotH, f0);
    float3 diffuse = (1.0f - fresnel) * (1.0f - material.metallic)
        * material.albedo / rangePi;
    float3 specular = distribution * geometryV * geometryL * fresnel
        / max(4.0f * nDotV * nDotL, 0.001f);
    return (diffuse + specular) * radiance * nDotL;
}

void traceScene(thread SceneHit &hit, thread float3 &furPosition,
    float3 origin, float3 direction, ChromePose chrome,
    device const GameState &game) {
    traceEnvironment(hit, origin, direction, chrome, game);
    for (uint i = 0u; i < enemyCount; ++i) {
        if (!spiderActive(game, i)) continue;
        SpiderHit spider = traceSpider(origin, direction, game.enemy[i].xyz,
            spiderVariantForSlot(i), game.enemyClock[i].w,
            game.gait[i].x, game.gait[i].y,
            spiderBodyRise(game.effects.x, i), 0.0f,
            spiderRear(game, i), hit.distance);
        if (spider.material != 0u) {
            hit = {spider.distance, spider.normal,
                origin + direction * spider.distance, spider.material,
                int(i), uint(spiderVariantForSlot(i)), spider.fur};
            furPosition = spider.furPosition;
        }
    }
    for (uint i = 0u; i < min(game.progress.x, targetKills); ++i) {
        FallenSpider fallen = game.fallen[i];
        SpiderVariant variant = SpiderVariant(fallen.appearance.x);
        SpiderTraits traits = spiderTraits(variant);
        float collapse = smoothstep(0.0f, 0.65f,
            game.effects.x - fallen.motion.z);
        float3 centre = fallen.pose.xyz;
        centre.y = mix(centre.y,
            stairHeight(centre.xz) + traits.scale * 0.37f, collapse);
        SpiderHit spider = traceSpider(origin, direction, centre,
            variant, fallen.pose.w, fallen.motion.x,
            fallen.motion.y * (1.0f - collapse),
            fallen.motion.w * (1.0f - collapse), collapse, 0.0f,
            hit.distance);
        if (spider.material != 0u) {
            hit = {spider.distance, spider.normal,
                origin + direction * spider.distance, spider.material,
                -1, fallen.appearance.x, spider.fur};
            furPosition = spider.furPosition;
        }
    }
    for (uint i = 0u; i < webCount; ++i) {
        WebCloth web = game.webs[i];
        float age = game.effects.x - web.startTime.w;
        if (age < 0.0f || game.effects.x > web.targetExpiry.w
            || abs(direction.y) < 0.0001f) continue;
        float flight = smoothstep(0.0f, 0.62f, age);
        float3 centre = mix(web.startTime.xyz,
            web.targetExpiry.xyz, flight);
        float t = (centre.y - origin.y) / direction.y;
        if (t <= 0.01f || t >= hit.distance) continue;
        float2 offset = origin.xz + direction.xz * t - centre.xz;
        float radius = 2.65f * mix(0.34f, 1.0f, flight);
        float distance = length(offset);
        float angle = atan2(offset.y, offset.x);
        float rim = radius * (0.88f + 0.12f * sin(angle * 7.0f));
        float spokes = abs(sin(angle * 9.0f));
        float rings = abs(fract(distance * 1.85f) - 0.5f);
        if (distance > rim || (spokes > 0.12f && rings > 0.085f))
            continue;
        hit = {t, float3(0.0f, direction.y < 0.0f ? 1.0f : -1.0f,
            0.0f), origin + direction * t, 26u, -1, i};
    }
}

float3 chromeReflection(SceneHit hit, float3 incoming,
    texture2d<float> crateA, texture2d<float> crateB,
    ChromePose chrome, device const GameState &game) {
    float3 reflectedDirection = reflect(incoming, hit.normal);
    SceneHit reflectedHit = {sceneRayLimit, float3(0.0f),
        float3(0.0f), 0u, -1, 0u};
    float3 reflectedFurPosition = float3(0.0f);
    traceScene(reflectedHit, reflectedFurPosition,
        hit.position + hit.normal * 0.025f, reflectedDirection,
        chrome, game);
    if (reflectedHit.material == 0u || reflectedHit.material == 20u)
        return float3(0.06f, 0.09f, 0.12f);
    SurfaceMaterial reflected = surfaceMaterial(reflectedHit,
        crateA, crateB, reflectedFurPosition, game.effects.x);
    float3 color = reflected.albedo * 0.32f + reflected.emission;
    for (uint i = 0u; i < 8u; ++i)
        color += shadePointLight(reflectedHit, reflected,
            -reflectedDirection, roomLight(i, game.effects.x), chrome);
    return color;
}

float3 shadeGlassBox(float3 background, float3 origin, float3 direction,
    float opaqueDistance, texture2d<float> crateA,
    texture2d<float> crateB, ChromePose chrome,
    device const GameState &game) {
    float3 normal;
    float distance = rayBox(origin, direction,
        glassBoxLower, glassBoxUpper, normal);
    if (distance <= 0.0f || distance >= opaqueDistance)
        return background;

    // Trace the opaque room first, then layer this glass surface over it so
    // the floor, enemies, and other objects remain visible through the box.
    SceneHit glass = {distance, normal,
        origin + direction * distance, 21u, -1, 0u};
    float facing = max(dot(normal, -direction), 0.0f);
    float grazing = pow(1.0f - facing, 5.0f);

    SurfaceMaterial material = {float3(0.04f),
        0.075f, 0.0f, float3(0.0f)};
    float3 highlights = float3(0.0f);
    for (uint i = 0u; i < 8u; ++i)
        highlights += shadePointLight(glass, material,
            -direction, roomLight(i, game.effects.x), chrome);
    float3 reflection = chromeReflection(glass, direction,
        crateA, crateB, chrome, game);
    // Clear glass transmits the scene without a colored fill or drawn edge.
    // Neutral reflections and light glints provide the glossy appearance.
    float reflectionLight = dot(reflection,
        float3(0.2126f, 0.7152f, 0.0722f));
    float highlightLight = dot(highlights,
        float3(0.2126f, 0.7152f, 0.0722f));
    float transmission = 0.88f - 0.18f * grazing;
    return background * transmission
        + float3(reflectionLight) * (0.08f + 0.24f * grazing)
        + float3(highlightLight) * 0.55f;
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
        float3 linear = pixeltje_3d::srgbToLinear(srgb);
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

struct GunHit {
    float distance;
    float3 normal;          // gun frame
    uint part;              // 1 slide, 2 polymer, 3 dark steel, 4 glove, 5 sleeve
    float3 local;
};

void gunBox(thread GunHit &hit, float3 origin, float3 direction,
    float3 lower, float3 upper, uint part) {
    float3 normal;
    float t = pixeltje_3d::rayBox(origin, direction, lower, upper,
        0.001f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, part, origin + direction * t};
}

void gunCapsule(thread GunHit &hit, float3 origin, float3 direction,
    float3 start, float3 end, float radius, uint part) {
    SpiderHit capsule = {hit.distance, float3(0.0f), 0u, float3(0.0f)};
    acceptSpiderLeg(capsule, origin, direction, start, end, radius, part);
    if (capsule.material != 0u)
        hit = {capsule.distance, capsule.normal, part,
            origin + direction * capsule.distance};
}

GunHit traceGun(float3 origin, float3 direction, float slide) {
    GunHit hit = {1.0e6f, float3(0.0f), 0u, float3(0.0f)};
    if (raySphere(origin, direction, float3(0.0f, -0.1f, -0.05f), 0.40f)
        < 0.0f) return hit;
    float3 back = float3(0.0f, 0.0f, -slide);
    gunBox(hit, origin, direction, float3(-0.016f, 0.018f, -0.075f) + back,
        float3(0.016f, 0.050f, 0.150f) + back, 1u);
    gunBox(hit, origin, direction, float3(-0.0025f, 0.050f, 0.128f) + back,
        float3(0.0025f, 0.057f, 0.140f) + back, 3u);
    for (uint side = 0u; side < 2u; ++side) {
        float x = side == 0u ? -0.014f : 0.004f;
        gunBox(hit, origin, direction, float3(x, 0.050f, -0.068f) + back,
            float3(x + 0.010f, 0.058f, -0.058f) + back, 3u);
    }
    gunBox(hit, origin, direction, float3(-0.008f, 0.024f, 0.120f),
        float3(0.008f, 0.040f, gunMuzzle.z), 3u);
    gunBox(hit, origin, direction, float3(-0.014f, -0.004f, -0.060f),
        float3(0.014f, 0.020f, 0.140f), 2u);
    gunBox(hit, origin, direction, float3(-0.005f, -0.030f, 0.005f),
        float3(0.005f, -0.024f, 0.075f), 2u);
    gunBox(hit, origin, direction, float3(-0.005f, -0.030f, 0.068f),
        float3(0.005f, -0.004f, 0.075f), 2u);
    // The grip rakes back 17 degrees from where it meets the frame.
    float c = cos(0.30f), s = sin(0.30f);
    GunHit grip = {hit.distance, float3(0.0f), 0u, float3(0.0f)};
    gunBox(grip, rotateSpiderPitch(origin - float3(0.0f, 0.0f, -0.012f), -s, c),
        rotateSpiderPitch(direction, -s, c),
        float3(-0.015f, -0.115f, -0.026f), float3(0.015f, 0.0f, 0.018f), 2u);
    if (grip.part != 0u)
        hit = {grip.distance, rotateSpiderPitch(grip.normal, s, c), 2u,
            origin + direction * grip.distance};
    float3 normal;
    float t = pixeltje_3d::rayEllipsoid(origin, direction,
        float3(0.0f, -0.050f, -0.030f), float3(0.036f, 0.048f, 0.042f),
        0.001f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, 4u, origin + direction * t};
    gunCapsule(hit, origin, direction, float3(-0.024f, -0.010f, -0.045f),
        float3(-0.021f, 0.006f, 0.020f), 0.0115f, 4u);
    for (uint finger = 0u; finger < 3u; ++finger) {
        float y = -0.030f - 0.021f * float(finger);
        gunCapsule(hit, origin, direction, float3(0.020f, y, 0.006f + y * 0.31f),
            float3(-0.020f, y, 0.006f + y * 0.31f), 0.0105f, 4u);
    }
    gunCapsule(hit, origin, direction, float3(0.002f, -0.080f, -0.055f),
        float3(0.035f, -0.30f, -0.32f), 0.044f, 5u);
    return hit;
}

SurfaceMaterial gunMaterial(GunHit hit) {
    float3 p = hit.local;
    if (hit.part == 1u) {
        // Rear cocking serrations on the slide flanks.
        float serration = abs(hit.normal.x) > 0.5f && p.z < -0.035f
            ? step(0.5f, fract(p.z * 230.0f)) : 0.0f;
        return {float3(0.20f, 0.21f, 0.22f) * (1.0f - 0.55f * serration),
            0.32f + 0.25f * serration, 0.9f, float3(0.0f)};
    }
    if (hit.part == 3u) {
        bool bore = p.z > gunMuzzle.z - 0.002f
            && length(p.xy - gunMuzzle.xy) < 0.0045f;
        return {bore ? float3(0.005f) : float3(0.09f, 0.09f, 0.095f),
            0.40f, bore ? 0.0f : 0.85f, float3(0.0f)};
    }
    if (hit.part == 2u) return {
        float3(0.035f, 0.037f, 0.040f)
            * (0.85f + 0.3f * smoothNoise(p.yz * 900.0f)),
        0.62f, 0.0f, float3(0.0f)};
    if (hit.part == 4u) return {float3(0.045f, 0.043f, 0.040f),
        0.85f, 0.0f, float3(0.0f)};
    return {float3(0.085f, 0.090f, 0.060f)
        * (0.8f + 0.4f * smoothNoise(p.xy * 260.0f)),
        0.95f, 0.0f, float3(0.0f)};
}

// The viewmodel is lit by the same room lights as the scene it moves through.
float3 shadeGun(GunHit gun, GunPose pose, float3 eye, float3 right,
    float3 up, float3 front, float3 direction, ChromePose chrome,
    device const GameState &game) {
    float3 viewPoint = pose.pivot + pose.basis * gun.local;
    float3 viewNormal = pose.basis * gun.normal;
    SceneHit hit = {length(viewPoint), normalize(right * viewNormal.x
            + up * viewNormal.y + front * viewNormal.z),
        eye + right * viewPoint.x + up * viewPoint.y + front * viewPoint.z,
        30u, -1, 0u};
    SurfaceMaterial material = gunMaterial(gun);
    float3 color = material.albedo * (1.0f - material.metallic)
            * float3(0.030f, 0.038f, 0.046f)
        + material.albedo * material.metallic
            * (0.05f + 0.07f * saturate(hit.normal.y));
    for (uint i = 0u; i < 8u; ++i)
        color += shadePointLight(hit, material, -direction,
            roomLight(i, game.effects.x), chrome);
    if (game.view.w > 0.0f) {
        float3 muzzle = pose.pivot + pose.basis
            * (gunMuzzle + float3(0.0f, 0.0f, 0.012f));
        PointLight flash = {eye + right * muzzle.x + up * muzzle.y
            + front * muzzle.z, float3(1.0f, 0.62f, 0.26f),
            3.0f * game.view.w / 0.11f};
        color += shadePointLight(hit, material, -direction, flash, chrome);
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
    // Shake is visual only: shots keep following the steady crosshair.
    float shake = game.recoil.w * game.recoil.w * 0.03f;
    float jitter = game.effects.x * 31.0f;
    float viewYaw = game.player.w
        + shake * (sin(jitter) + 0.5f * sin(jitter * 2.3f + 1.0f));
    float viewPitch = game.view.x
        + shake * (sin(jitter * 1.7f + 2.0f) + 0.5f * sin(jitter * 3.1f));
    float3 direction = pixeltje_3d::cameraDirection(in.uv,
        u.resolutionTime.xy, viewYaw, viewPitch, 1.1f);
    float3 eye = game.player.xyz + eyeOffset(game);
    float3 origin = eye;
    float reveal = 0.0f;
    if (game.bossScene.x >= 0.0f && game.bossScene.x < 5.0f) {
        float time = game.bossScene.x;
        reveal = smoothstep(1.05f, 1.55f, time)
            * (1.0f - smoothstep(4.35f, 4.95f, time));
        float3 closeOrigin = float3(6.5f, 3.65f, -88.0f);
        float3 toBoss = game.enemy[bossSlot].xyz
            + float3(0.0f, 0.9f, 0.0f) - closeOrigin;
        float closeYaw = atan2(toBoss.x, -toBoss.z);
        float closePitch = atan2(toBoss.y, length(toBoss.xz));
        float3 closeDirection = pixeltje_3d::cameraDirection(in.uv,
            u.resolutionTime.xy, closeYaw, closePitch, 1.45f);
        origin = mix(origin, closeOrigin, reveal);
        direction = normalize(mix(direction, closeDirection, reveal));
    }
    ChromePose chrome = {game.chromeRotation, game.chromeCentre.xyz};
    float3 furPosition = float3(0.0f);
    SceneHit hit = {sceneRayLimit,
        float3(0.0f), float3(0.0f), 0u, -1, 0u};
    traceScene(hit, furPosition, origin, direction, chrome, game);

    SurfaceMaterial material = surfaceMaterial(hit, crateA, crateB,
        furPosition, game.effects.x);
    float3 color = material.emission
        + material.albedo * (1.0f - material.metallic)
            * float3(0.030f, 0.038f, 0.046f);
    for (uint i = 0u; i < 8u; ++i) {
        color += shadePointLight(hit, material, -direction,
            roomLight(i, game.effects.x), chrome);
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
        bool redEyes = hit.variant != uint(SpiderVariant::brown);
        float3 reflected = reflect(direction, hit.normal);
        float glint = pow(max(dot(reflected,
            normalize(float3(-0.3f, 0.85f, -0.4f))), 0.0f), 56.0f);
        color += (redEyes ? float3(1.0f, 0.13f, 0.09f)
            : float3(0.65f, 0.78f, 0.84f)) * glint;
        float fresnel = 1.0f - max(dot(hit.normal, -direction), 0.0f);
        color += (redEyes ? float3(0.16f, 0.012f, 0.014f)
            : float3(0.055f, 0.075f, 0.082f))
            * fresnel * fresnel * fresnel;
        // An enraged boss's eyes burn from within.
        if (hit.enemy == int(bossSlot) && bossEnraged(game))
            color += float3(0.9f, 0.05f, 0.03f)
                * (0.6f + 0.4f * sin(game.effects.x * 9.0f));
    }
    if (hit.enemy >= 0) {
        if (game.enemyClock[hit.enemy].z > 0.0f) color += float3(0.9f, 0.5f, 0.2f);
        if (hit.enemy == int(bossSlot) && game.bossAttack.x > 0.0f
            && game.bossAttack.x < bossWindup(game))
            color += float3(0.18f, 0.008f, 0.006f)
                * (0.6f + 0.4f * sin(game.effects.x * 32.0f));
    }
    color = shadeImpacts(color, hit, game, impactTexture);
    color = mix(color, float3(0.0f),
        1.0f - exp(-hit.distance * 0.008f));
    color = shadeGlassBox(color, origin, direction, hit.distance,
        crateA, crateB, chrome, game);
    color = shadeShot(color, origin, direction, hit.distance, game);
    color = shadeSpiderParticles(color, origin, direction,
        hit.distance, game);

    // The held pistol is drawn over the world, as in any shooter, so a wall
    // in front of the face never swallows it.
    bool holdingGun = reveal <= 0.0f && game.progress.w != phaseLost;
    GunPose gun = gunPose(game);
    float3 viewFront = pixeltje_3d::forward(viewYaw, viewPitch);
    float3 viewRight = normalize(cross(viewFront, float3(0.0f, 1.0f, 0.0f)));
    float3 viewUp = cross(viewRight, viewFront);
    if (holdingGun) {
        float3 viewDirection = float3(dot(direction, viewRight),
            dot(direction, viewUp), dot(direction, viewFront));
        float3x3 toGun = transpose(gun.basis);
        GunHit gunHit = traceGun(toGun * -gun.pivot, toGun * viewDirection,
            gun.slide);
        if (gunHit.part != 0u)
            color = shadeGun(gunHit, gun, eye, viewRight, viewUp, viewFront,
                direction, chrome, game);
    }
    color = pixeltje_3d::filmicToneMap(color * 1.6f);

    // Crosshair, health bar, target pips, and damage/muzzle feedback.
    float2 pixel = in.uv * u.resolutionTime.xy;
    float2 centre = u.resolutionTime.xy * 0.5f;
    float2 d = abs(pixel - centre);
    if (holdingGun && game.view.w > 0.0f) {
        float3 muzzle = gun.pivot + gun.basis
            * (gunMuzzle + float3(0.0f, 0.0f, 0.012f));
        float2 muzzlePixel = centre + float2(muzzle.x, -muzzle.y)
            / muzzle.z * 1.1f * u.resolutionTime.y;
        float2 offset = pixel - muzzlePixel;
        float radius = length(offset) / u.resolutionTime.y;
        float angle = atan2(offset.y, offset.x) + float(game.progress.y) * 1.7f;
        float spikes = pow(abs(cos(angle * 2.5f)), 6.0f);
        float flash = (1.0f - smoothstep(0.0f, 0.022f, radius))
            + 0.8f * spikes * (1.0f - smoothstep(0.0f, 0.075f, radius))
            + 0.25f * (1.0f - smoothstep(0.0f, 0.12f, radius));
        color += float3(1.0f, 0.62f, 0.24f) * flash
            * (game.view.w / 0.11f) * 1.6f;
    }
    // Damage reddens the screen edges; low health pulses there.
    float hurtTint = min(game.effects.y * 2.4f, 0.8f);
    if (game.view.y < 35.0f && game.progress.w == phasePlaying)
        hurtTint = max(hurtTint, (1.0f - game.view.y / 35.0f)
            * (0.28f + 0.17f * sin(game.effects.x * 5.5f)));
    color = mix(color, float3(0.42f, 0.015f, 0.01f), hurtTint
        * smoothstep(0.30f, 0.95f, length(pixel - centre)
            / u.resolutionTime.y));
    // A red arc around the crosshair points toward the last attacker.
    if (game.hurt.z > 0.0f) {
        float2 toSource = game.hurt.xy - game.player.xz;
        float bearing = atan2(toSource.x, -toSource.y) - game.player.w;
        float screenAngle = atan2(pixel.x - centre.x, centre.y - pixel.y);
        float apart = abs(atan2(sin(screenAngle - bearing),
            cos(screenAngle - bearing)));
        float ring = abs(length(pixel - centre) / u.resolutionTime.y - 0.15f);
        color = mix(color, float3(0.95f, 0.12f, 0.08f),
            0.9f * saturate(game.hurt.z)
                * (1.0f - smoothstep(0.22f, 0.36f, apart))
                * (1.0f - smoothstep(0.012f, 0.02f, ring)));
    }
    bool crosshair = (d.x < 1.4f && d.y > 4.0f && d.y < 12.0f)
        || (d.y < 1.4f && d.x > 4.0f && d.x < 12.0f);
    if (crosshair && (game.bossScene.x < 0.0f
        || game.bossScene.x >= 5.0f))
        color = float3(0.9f, 1.0f, 0.95f);
    // Hit marker: white for a body hit, orange for the head, red for a kill.
    float markerRadius = length(d);
    if (game.weapon.z > 0.0f && abs(d.x - d.y) < 1.3f && markerRadius > 7.0f
        && markerRadius < (game.weapon.w > 1.5f ? 19.0f : 15.0f)) {
        color = mix(color, game.weapon.w > 2.5f ? float3(1.0f, 0.18f, 0.12f)
            : (game.weapon.w > 1.5f ? float3(1.0f, 0.62f, 0.18f)
                : float3(1.0f)), saturate(game.weapon.z / 0.12f));
    }
    // Magazine rounds at the bottom right, with a bar while reloading.
    if (game.progress.w == phasePlaying) {
        float2 corner = u.resolutionTime.xy - float2(28.0f, 28.0f);
        for (uint i = 0u; i < magazineSize; ++i) {
            float right = corner.x - float(i) * 9.0f;
            if (pixel.x > right - 5.0f && pixel.x < right
                && pixel.y > corner.y - 18.0f && pixel.y < corner.y) {
                color = float(i) < game.weapon.x ? float3(0.95f, 0.82f, 0.45f)
                    : float3(0.10f, 0.13f, 0.14f);
            }
        }
        float barWidth = float(magazineSize) * 9.0f - 4.0f;
        if (game.weapon.y > 0.0f && pixel.y > corner.y + 5.0f
            && pixel.y < corner.y + 8.0f && pixel.x < corner.x
            && pixel.x > corner.x - barWidth) {
            color = corner.x - pixel.x > barWidth
                    * (game.weapon.y / reloadDuration)
                ? float3(0.95f, 0.82f, 0.45f) : float3(0.10f, 0.13f, 0.14f);
        }
    }
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
    if (game.bossScene.x >= 5.0f && game.enemy[bossSlot].w > 0.0f
        && pixel.y > 53.0f && pixel.y < 63.0f
        && abs(pixel.x - centre.x) < 230.0f) {
        float fill = clamp(game.enemy[bossSlot].w / 14.0f, 0.0f, 1.0f);
        color = pixel.x < centre.x - 230.0f + 460.0f * fill
            ? float3(0.72f, 0.075f, 0.055f)
            : float3(0.12f, 0.12f, 0.14f);
    }
    if (game.bossScene.y > 0.0f)
        color = mix(color, float3(0.43f, 0.66f, 0.70f), 0.16f);
    if (reveal > 0.0f) {
        float bar = min(pixel.y, u.resolutionTime.y - pixel.y);
        if (bar < 64.0f * reveal) color = float3(0.006f, 0.009f, 0.013f);
    }
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
    float3 srgb = pixeltje_3d::linearToSRGB(color);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

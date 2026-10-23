// pixeltje:easing-v1
// pixeltje:3d-v1
// pixeltje:terrain-v1
// pixeltje:postfx-v1
#include <metal_stdlib>
using namespace metal;

// Haunted House: Signal Range at lunar night, for gpu.program.
// The compute pass owns all mutable game state. The fragment pass traces the
// same room and walking spider drones from the camera, then draws the HUD.
// An exit door in the starting arena's south wall leads onto the moon, where
// quadcopter drones hover and fire back with laser rifles once shot at. The
// sun has set: a full Earth lights the plain, and a flagstone path leads
// from the exit to a procedurally built Victorian haunted house whose ground
// floor is open. An asphalt street lit by lantern posts crosses the path,
// with copies of the cottage, barn and shed along it, each standing a few
// degrees off square with the road. The player
// starts outside on that path, facing the house.
// The hand, pistol, double-barrel shotgun and launcher are on keys 1 to 4
// everywhere; the hand punches, and knocks on doors. enableDrones and
// renderBase below switch the drones and the drawn base off for now. With
// enableDayNightTransition, the sun crosses the sky from noon to this night
// over twenty minutes, and the timeOfDay parameter picks where on that path a
// match starts; the house sleeps through the bright half of the afternoon
// and wakes to shots only once it is getting dark.

// Spider slots: two brown range spiders, the ambush spider, seven dark brown
// hoppers, then the boss. Every slot before the boss runs the same AI.
constant uint enemyCount = 11u;
constant uint ordinaryEnemyCount = 10u;
constant uint hopperStart = 3u;
constant uint bossSlot = 10u;
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
constant float sceneRayLimit = 1800.0f;   // reaches the lunar horizon
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
constant float biteWindup = 0.30f;
constant float exitHalfWidth = 2.5f;
constant float exitDoorTop = 3.5f;
constant float exitDoorZ = 18.15f;
// The base's exterior shell. Its footprint separates the rooms from the moon.
constant float hullHalfWidth = 60.3f;
constant float hullSouth = 18.3f;
constant float hullNorth = -130.3f;
constant float3 hullFrontLower = float3(-60.3f, -2.0f, -24.0f);
constant float3 hullFrontUpper = float3(60.3f, 7.3f, 18.3f);
constant float3 hullRearLower = float3(-60.3f, -2.0f, -130.3f);
constant float3 hullRearUpper = float3(60.3f, 18.6f, -23.9f);
constant float moonCeiling = 110.0f;      // above the highest lunar terrain
constant float moonWalkRadius = 1500.0f;
constant int moonTraceDetail = 4;         // ray, shadow and footing octaves
constant int moonShadeDetail = 7;         // normal octaves
// Lunar night: the sun is below the horizon and a full Earth hangs low
// beside the haunted house's spire as you walk out to it, lighting the
// plain with cool earthshine. It is dimmer than the sun was, so the lit
// windows and lanterns carry the scene.
constant float3 earthDirection = float3(-0.4019f, 0.309f, 0.8619f);
constant float earthPower = 1.76e9f;      // irradiance 1.4 from 10 km away
constant float3 earthColor = float3(0.78f, 0.86f, 1.0f);
constant float earthRadius = 0.028f;      // drawn 1.6°, larger than life
// Day into night. With enableDayNightTransition the sun stands high behind
// the path at lunar noon, lights the plain and the houses and outshines the
// stars, then sinks toward the plain left of the house and sets just before
// dayNightDuration seconds after noon, leaving the earthlit night above. A
// match starts timeOfDay seconds after noon (parameters0.x): 0 starts at
// noon, about 1090 puts the sun's centre on the horizon, 1106 starts just
// after its disc has gone under, and 1200 or more starts in the night. Set
// enableDayNightTransition false to keep the night from the start.
constant bool enableDayNightTransition = true;
// With the transition on, an Earth-like atmosphere hangs over the moon until
// night: a soft blue sky, skylight in the shadows, haze over the distance, a
// sun that reddens as it sets and a twilight that fades to black. Set it
// false for the airless black sky of the real moon.
constant bool enableAtmosphere = true;
constant float dayNightDuration = 1200.0f; // noon to night, in seconds
// The sun's path is a great circle from its highest point, 68° up, to the
// horizon point where it sets, 18° left of the house seen from the start.
// The two directions are perpendicular.
constant float3 sunNoonDirection = float3(0.3487f, 0.9303f, -0.1134f);
constant float3 sunsetDirection = float3(0.309f, 0.0f, 0.951f);
constant float sunIrradiance = 3.2f;
constant float sunPower = 4.02e9f;        // sunIrradiance from 10 km away
constant float3 sunColor = float3(1.0f, 0.97f, 0.92f);
constant float sunRadius = 0.012f;        // drawn 1.4°, larger than life
constant uint droneCount = 3u;
constant uint laserCount = 6u;
// Two flocks of bats, each six to fifteen strong, come out once the sun
// has set; see HauntedBats.metal.
constant uint batFlockCount = 2u;
constant uint batFlockSize = 15u;
constant uint batCount = batFlockCount * batFlockSize;
// Switched off for now: the drones neither fly, sound, shoot nor show, and
// nothing can hit or lock onto them. Set true to bring them back.
constant bool enableDrones = false;
// Whether the view draws the base: its rooms, corridors, props, exit and
// outer shell. Off for now, so the moon runs on across its footprint. It
// only changes what is drawn; shots, sight lines, lasers and the walker
// still meet the base, and the spiders, sentries and pickups inside it
// still show.
constant bool renderBase = false;
// The player starts outside on the flagstone path, a few metres south of
// the exit door, facing the haunted house. The trackpad's centre looks
// along spawnYaw; a yaw of 0 would look north at the base.
constant float2 spawnGround = float2(0.0f, 26.0f);
constant float spawnYaw = 3.14159265f;

// A Javelin-style launcher joins the hand, the pistol and the shotgun. Keys
// 1 to 4 pick the hand, pistol, shotgun and launcher; X swaps back to the
// one held before.
constant float launcherReloadDuration = 2.4f;
constant float rocketReserveStart = 4.0f;
constant uint rocketLimit = 7u;            // loaded plus reserve
constant float lockDuration = 1.0f;
constant float blastRadius = 4.5f;
constant uint trailCount = 12u;
constant float trailInterval = 0.15f;
constant float dodgeSpeed = 11.0f;
constant float dodgeCooldown = 0.85f;
// Held action keys from the WASD Pad arrive as a bitmask in movement.w.
constant uint keyQ = 1u;
constant uint keyE = 2u;
constant uint keyR = 4u;
constant uint keyV = 16u;
constant uint keyX = 32u;
constant uint keyDigit1 = 128u;
constant uint keyDigit2 = 256u;
constant uint keyDigit3 = 512u;
constant uint keyDigit4 = 1024u;
constant uint keyDigit7 = 8192u;
// Keys 7, 8 and 9 switch off bokeh, bloom and lens fringing; controls.w
// holds the bits of the effects switched off.
constant uint effectBokeh = 1u;
constant uint effectBloom = 2u;
constant uint effectAberration = 4u;
// Depth of field at 900 pixels tall: a point 1 m away blurs by
// `lensAperture` pixels with the lens focused at infinity, and no blur grows
// past `lensMaxBlur`. Autofocus eases toward the crosshair at `lensFocusRate`
// per second, measured in inverse distance as a focus ring turns.
constant float lensAperture = 60.0f;
constant float lensMaxBlur = 10.0f;
constant float lensFocusRate = 8.0f;
// Sentry turrets guard the east, west and north rooms. Each stands on a
// tripod and first watches its room's entrance.
constant uint sentryCount = 3u;
constant float sentryHealth = 6.0f;
constant float sentryCharge = 0.75f;
constant float sentryBoltSpeed = 21.0f;
constant float sentryBoltDamage = 9.0f;
constant uint boltCount = 6u;
constant float2 sentryGround[sentryCount] = {
    float2(50.0f, -9.0f), float2(-50.0f, 9.0f), float2(13.0f, -55.0f)};
constant float2 sentryWatch[sentryCount] = {
    float2(24.0f, 0.0f), float2(-24.0f, 0.0f), float2(0.0f, -24.0f)};
// Two rocket caches (east room, boss corridor) and two medkits (west room,
// north room). Positions are on the floor.
constant uint pickupCount = 4u;
constant uint pickupMedkitStart = 2u;
constant float3 pickupGround[pickupCount] = {
    float3(52.0f, 0.9f, 10.0f), float3(3.2f, 1.2f, -66.0f),
    float3(-52.0f, 1.5f, -10.0f), float3(-14.0f, 1.2f, -56.0f)};
constant float3 pickupHalfSize = float3(0.34f, 0.2f, 0.24f);
// Scene materials of the sentries, pickups and missile.
constant uint sentryArmourMaterial = 60u;
constant uint sentryMetalMaterial = 61u;
constant uint sentrySensorMaterial = 62u;
constant uint sentryWreckMaterial = 63u;
constant uint pickupMaterialID = 64u;
constant uint missileMaterial = 65u;

#include "NPCPathNetwork.metal"

struct ProgramUniforms {
    float4 resolutionTime;
    uint4 frameSeed;
    float4 parameters0;   // timeOfDay, seconds after noon a match starts
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;   // Trackpad X/Y, Space action count, live time step
    float4 movement;  // WASD Pad X/Y, secondary action count, held keys
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

struct Drone {
    float4 pose;           // centre XYZ, health (zero once shot down)
    float4 velocity;       // world velocity XYZ, heading yaw
    float4 attitude;       // tilt tangent along world X and Z, hit flash, thrust
    float4 brain;          // hostile flag, fire cooldown, health the bar
                           // shows (drains toward pose.w), time shot down
    float4 wander;         // station XZ, hover height, loiter phase;
                           // the spark burst XYZ once shot down
};

// Where advanceBats puts each bat this frame; the view only reads it.
struct Bat {
    float4 pose;           // centre XYZ, size (0 while it is not out)
    float4 heading;        // unit forward XYZ, wingbeat phase in radians
    float4 lift;           // unit up XYZ, wingbeat amplitude 0–1
};

struct LaserBolt {
    float4 startTime;      // muzzle XYZ and firing time
    float4 endHit;         // stop point XYZ; 1 on a surface, 2 on the player
};

// The audio buffer the engine reads after each frame. Event words count
// one-shot sounds and are cleared before every tick; each drone voice is the
// gain, playback rate and pan of its looping hover sound, the two wind
// voices layer the wind loop at different rates for the night, and the
// haunt voice plays it as the gale that blows while the house is haunted.
// The ghost voice loops the ghost's moan from wherever the ghost flies.
// Each knuckle rap on a door and each punch that lands is one event, and
// so is each door a knock swings open: the cottage's creaks, the house's
// big pair groans.
struct RangeAudio {
    uint shot;
    uint scare;
    uint launch;
    uint shotgun;
    uint laser;
    uint droneDown;
    uint knock;
    uint punch;
    float4 droneVoice[droneCount];
    float4 windVoice[2];
    float4 hauntWind;
    float4 ghostVoice;
    uint cottageDoor;
    uint houseDoors;
    uint2 unused;
};

static_assert(sizeof(RangeAudio) == 160,
    "The audio words must match the program's audioEvents and audioVoices");

constant uint hudCapacity = 96u;

struct HUDGlyph {
    float4 geometry;        // glyph index, top-left x/y in pixels, font size
    float4 ink;             // display-referred sRGB and opacity
};

// The haunted house and the buildings around it are a list of convex parts
// that HauntedBuildings.metal generates once in the initialize pass. Each
// part is a world box cut by up to four more half-spaces, which makes
// gables, hips, spires and tapers. Timber and logs reuse the window fields
// for their frame, and a clad wall, which has no cutting planes, keeps the
// gaps its loose boards left in them. Clapboards and battens are traced in
// relief on the walls' faces.
struct HousePart {
    float4 lower;           // world box corner, style
    float4 upper;           // world box corner, number of cutting planes
    float4 planes[4];       // outward unit normal, offset; inside where
                            // dot(normal, p) <= offset
    float4 windows;         // count across ±z faces, count across ±x faces,
                            // width, height
    float4 rows;            // first sill above lower.y, rows, row pitch, glow
};

// Parts are traced group by group, and a ray tests a group's parts only when
// it enters the group's bounds. A building site's first group bounds the
// whole site, so a ray that misses it skips to the site's last group.
struct HouseGroup {
    float4 lower;           // bounds, first part
    float4 upper;           // bounds, end part
    uint4 last;             // the last group these bounds enclose, unused
};

constant uint houseCapacity = 1536u;
constant uint houseGroupCapacity = 72u;
constant uint buildingSiteCapacity = 8u;

constant uint houseCandleCapacity = 4u;

struct HouseModel {
    uint4 counts;           // parts, groups, candle lights, sites
    // A shot through a window wakes the house. Start time (negative while
    // it is quiet) and the ghost's centre; its velocity and the time it
    // began to vanish (negative until then). Ahead of the arrays, so these
    // offsets stay put when a capacity changes.
    float4 haunt;
    float4 hauntMotion;
    // The doors a knock opens: when the house's pair and the cottage's door
    // begin to swing open (negative while shut), and 1 in z and w once
    // each has sounded. Then the parts that hold the house's west and east
    // leaves, the cottage's door and the pressure plate under the house's
    // pair, which buildingsHangDoors rehangs.
    float4 doors;
    uint4 doorParts;
    float4 candles[houseCandleCapacity];  // flame XYZ, room
    uint4 sites[buildingSiteCapacity];    // first and end group, first and
                                          // end part; site 0 is the house
    HouseGroup groups[houseGroupCapacity];
    HousePart parts[houseCapacity];
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
    float4 pathFollow[enemyCount]; // NPC path follower for each spider
    NPCPathNetwork paths;   // generated waypoint graph and route to the player
    // Rebuilt from the state above by every present pass. It shares this
    // buffer because GPU Program resource slots are scarce.
    HUDGlyph hud[hudCapacity];
    // The moon's state follows the HUD, so earlier offsets stay where
    // preview views write them.
    Drone drones[droneCount];
    LaserBolt lasers[laserCount];
    float4 arms;            // held weapon (0 pistol, 1 shotgun, 2 launcher,
                            // 3 hand), raised 0–1, shells loaded, shell
                            // reload left
    uint4 burst;            // pellets in the latest discharge, bolts fired
    // The launcher, dodge and sentries follow too.
    float4 arsenal;         // weapon chosen and the one before it, as in
                            // arms.x; reserve rockets, rocket loaded
    float4 launcher;        // lock target ID, lock progress, reload time left, launch kick
    float4 controls;        // previous action keys, flight cam on, dodge cooldown, effects off
    float4 dodge;           // dodge velocity XZ, pickup notice time, unused
    float4 missile;         // nose XYZ, launch time; W < 0 while none flies
    float4 missileVelocity; // velocity XYZ, locked target ID (0 flies straight)
    float4 missileAim;      // last known target point XYZ, diving
    float4 blast;           // detonation XYZ, time
    float4 trail[trailCount];          // smoke puffs: XYZ, emission time
    float sentryFloor[sentryCount];    // ground height under each sentry
    float4 sentryAim[sentryCount];     // yaw, pitch, alert, charge clock (-1 idle)
    float4 sentryState[sentryCount];   // health, hit flash, death time, cooldown
    float4 boltPosition[boltCount];    // XYZ, fire time (-100 unused)
    float4 boltVelocity[boltCount];    // velocity XYZ, burst time (-1 in flight)
    uint4 pickups;          // taken bits, last pickup kind, sentries destroyed, bolts fired
    uint sightLines[enemyCount]; // per ordinary spider: 1 when its view of
                                 // the player is clear
    float spiderBar[enemyCount]; // health fraction each ordinary spider's bar
                                 // shows, draining toward its real health
    // Last, so every Signal Range offset stays where preview views write it.
    HouseModel house;
    float4 lens;            // autofocus distance (0 until the first frame),
                            // elapsed time it was last pulled; unused
    float4 hand;            // the hand's swing; see SignalRangeHand.metal
    float4 sky;             // seconds after noon the match started at
                            // (timeOfDay), unused
    // The house's front doors swing shut once nobody has stood on the
    // pressure plate under them for a while: when they began to swing shut
    // (negative while they are not), how far open they stood then, when
    // the plate was last pressed, and 1 while it is pressed.
    float4 frontDoors;
    Bat bats[batCount];     // the bats out tonight
};

static_assert(sizeof(GameState) <= 262144,
    "The GPU Program game buffer must contain game state, the HUD glyphs "
    "and the buildings");

// Seconds after lunar noon right now: the time of day the match started at
// plus the time it has run.
float dayClock(device const GameState &game) {
    return game.sky.x + game.effects.x;
}

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
float smoothNoise(float2 p);
float shellLines(float coord, float spacing, float width, float blur);

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

#include "HauntedBuildingKit.metal"
#include "HauntedHouse.metal"
#include "HauntedMausoleum.metal"
#include "HauntedShed.metal"
#include "HauntedCottage.metal"
#include "HauntedStreet.metal"
#include "HauntedBuildings.metal"

float stairHeight(float2 point);
bool walkable(float2 point);
bool outdoors(float2 point, float pad);
float droneHearing(float2 point);

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
    // Lowered out of view while the shotgun is swapped in or out.
    float lowered = 1.0f - smoothstep(0.0f, 1.0f, game.arms.y);
    // The gun lags behind turns, bobs with steps, kicks back on each shot
    // and dips out of view while the magazine is changed.
    float3 pivot = float3(0.17f, -0.17f, 0.36f) + float3(
        0.010f * bob * sin(phase) - 0.006f * sway.x,
        -0.007f * bob * abs(cos(phase)) - 0.006f * sway.y
            + 0.010f * kick - 0.12f * reload - 0.34f * lowered
            - 0.5f * game.hurt.w,
        -0.045f * kick);
    float pitch = 0.17f * kick - 0.5f * reload - 0.9f * lowered
        - 0.02f * sway.y;
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

// The launcher's frame: origin on the tube axis at the grip, Z forward.
constant float3 launcherMuzzle = float3(0.0f, 0.0f, 0.86f);

// The launcher rides on the right shoulder. It sways and bobs like the
// pistol, shoves back on launch and tips down to take a new round.
GunPose launcherPose(device const GameState &game) {
    float reload = game.launcher.z > 0.0f
        ? sin(rangePi * (1.0f - game.launcher.z / launcherReloadDuration))
        : 0.0f;
    float kick = game.launcher.w;
    float bob = game.motion.w, phase = game.motion.z;
    float2 sway = game.look.zw;
    float lowered = 1.0f - smoothstep(0.0f, 1.0f, game.arms.y);
    float3 pivot = float3(0.23f, -0.15f, 0.12f) + float3(
        0.012f * bob * sin(phase) - 0.008f * sway.x,
        -0.010f * bob * abs(cos(phase)) - 0.008f * sway.y
            - 0.10f * reload - 0.5f * game.hurt.w - 0.34f * lowered,
        -0.09f * kick);
    float pitch = 0.07f * kick - 0.3f * reload - 0.02f * sway.y
        - 0.9f * lowered;
    float yaw = -0.04f * sway.x;
    float roll = 0.25f * reload;
    float3 f = float3(sin(yaw) * cos(pitch), sin(pitch),
        cos(yaw) * cos(pitch));
    float3 r = normalize(float3(f.z, 0.0f, -f.x));
    float3 up = cross(f, r);
    return {pivot, float3x3(r * cos(roll) + up * sin(roll),
        up * cos(roll) - r * sin(roll), f), 0.0f};
}

// The spiders' path network: the four rooms and the moon outside, joined by
// a portal node in each doorway. Jitter stays within 2.5 m, so the nodes
// facing each doorway keep a straight walk to its portal. Moon grid points
// inside the base's shell are dropped by generation, which leaves a ring
// around its south half; range spiders never go farther north than the
// northern room.
constant uint pathAreaArena = 0u;
constant uint pathAreaNorth = 1u;
constant uint pathAreaEast = 2u;
constant uint pathAreaWest = 3u;
constant uint pathAreaMoon = 9u;
constant uint pathAreaCount = 10u;
constant NPCPathArea rangePathAreas[pathAreaCount] = {
    {float2(-16.5f, -16.5f), float2(16.5f, 16.5f), uint2(5u, 5u), 0.3f},  // arena
    {float2(-16.5f, -58.5f), float2(16.5f, -25.5f), uint2(5u, 5u), 0.3f}, // north
    {float2(25.5f, -16.5f), float2(58.5f, 16.5f), uint2(3u, 3u), 0.15f},  // east
    {float2(-58.5f, -16.5f), float2(-25.5f, 16.5f), uint2(3u, 3u), 0.15f}, // west
    {float2(0.0f, -21.0f), float2(0.0f, -21.0f), uint2(1u, 1u), 0.0f},    // north stairs
    {float2(21.0f, 0.0f), float2(21.0f, 0.0f), uint2(1u, 1u), 0.0f},      // east stairs
    {float2(-21.0f, 0.0f), float2(-21.0f, 0.0f), uint2(1u, 1u), 0.0f},    // west stairs
    {float2(0.0f, 18.0f), float2(0.0f, 18.0f), uint2(1u, 1u), 0.0f},      // exit door
    {float2(0.0f, 21.0f), float2(0.0f, 21.0f), uint2(1u, 1u), 0.0f},      // outside it
    {float2(-68.0f, -56.0f), float2(68.0f, 26.0f), uint2(5u, 3u), 0.06f}  // the moon
};
constant uint pathJoinCount = 9u;
constant uint2 rangePathJoins[pathJoinCount] = {
    uint2(0u, 4u), uint2(4u, 1u), uint2(0u, 5u), uint2(5u, 2u),
    uint2(0u, 6u), uint2(6u, 3u), uint2(0u, 7u), uint2(7u, 8u),
    uint2(8u, 9u)
};

struct GunHit {
    float distance;
    float3 normal;          // gun frame
    uint part;              // 1 chrome, 2 polymer, 3 dark steel, 4 glove,
                            // 5 sleeve, 6 blued barrel, 7 walnut,
                            // 10 launch tube, 11 composite, 12 display,
                            // 13 hand leather, 14 hand strap, 15 hand sleeve
    float3 local;
    float cavity;           // the hand's crease shading: 0 open, 1 shut in
};

void gunBox(thread GunHit &hit, float3 origin, float3 direction,
    float3 lower, float3 upper, uint part);
void gunCapsule(thread GunHit &hit, float3 origin, float3 direction,
    float3 start, float3 end, float radius, uint part);

#include "SignalRangeSpider.metal"
#include "SignalRangeDoppler.metal"
#include "SignalRangeShotgun.metal"
#include "SignalRangeHand.metal"
#include "SignalRangeDrone.metal"
#include "SignalRangeArsenal.metal"

void resetGame(device GameState &game, uint seed) {
    game.player = float4(spawnGround.x, 1.55f + stairHeight(spawnGround),
        spawnGround.y, spawnYaw);
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
        game.enemy[i] = float4(spawnPosition(i),
            spiderTraits(spiderVariantForSlot(i)).health);
        game.spiderBar[i] = 1.0f;
        float2 toPlayer = game.player.xz - game.enemy[i].xz;
        game.enemyClock[i] = float4(0.0f, -0.55f, 0.0f,
            i == bossSlot ? atan2(toPlayer.x, -toPlayer.y) : idleYaw(i));
        // Range spiders start unaware; the ambush spider is not yet present.
        game.senses[i] = float4(game.enemy[i].xz,
            i == bossSlot ? 1.0f : (i == ambushSlot ? -1.0f : 0.0f), -1.0f);
        game.reaction[i] = float4(0.0f);
        game.gait[i] = float4(0.07f + float(i) * 0.31f,
            0.0f, 0.0f, 0.0f);
        // Range spiders hold their opening pose for a moment, then patrol.
        game.pathFollow[i] = npcPathFollower(2.2f + 0.9f * float(i));
    }
    // Every match generates a fresh network over the same rooms.
    npcPathGenerate(game.paths, rangePathAreas, pathAreaCount,
        rangePathJoins, pathJoinCount, npcPathHash(seed));
    resetArms(game);
    resetDrones(game);
    // The previous keys, the flight-cam option and effect switches survive a
    // restart. The pistol is in hand; X swaps to the launcher.
    game.arsenal = float4(heldPistol, heldLauncher, rocketReserveStart, 1.0f);
    game.hand = float4(-100.0f, 0.0f, 0.0f, 0.0f);
    game.launcher = float4(0.0f);
    game.controls.z = 0.0f;
    game.dodge = float4(0.0f, 0.0f, -100.0f, 0.0f);
    game.missile = float4(0.0f, 0.0f, 0.0f, -1.0f);
    game.missileVelocity = float4(0.0f, 0.0f, -1.0f, 0.0f);
    game.missileAim = float4(0.0f);
    game.blast = float4(0.0f, 0.0f, 0.0f, -100.0f);
    for (uint i = 0u; i < trailCount; ++i)
        game.trail[i] = float4(0.0f, 0.0f, 0.0f, -100.0f);
    for (uint i = 0u; i < sentryCount; ++i) {
        game.sentryFloor[i] = stairHeight(sentryGround[i]);
        game.sentryAim[i] = float4(sentryRestYaw(i), 0.0f, 0.0f, -1.0f);
        game.sentryState[i] = float4(sentryHealth, 0.0f, -100.0f, 0.0f);
    }
    for (uint i = 0u; i < boltCount; ++i) {
        game.boltPosition[i] = float4(0.0f, 0.0f, 0.0f, -100.0f);
        game.boltVelocity[i] = float4(0.0f, 0.0f, 0.0f, -100.0f);
    }
    game.pickups = uint4(0u);
    houseQuiet(game);
    buildingsShutDoors(game);
}

kernel void initializeRange(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device RangeAudio *audio [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    // The haunted buildings are generated once; restarts keep them.
    buildBuildings(states[0].house);
    // The missile flight cam starts on; V toggles it.
    states[0].controls = float4(0.0f, 1.0f, 0.0f, 0.0f);
    resetGame(states[0], u.frameSeed.y ^ u.frameSeed.z);
    states[0].sky = float4(max(0.0f, u.parameters0.x), 0.0f, 0.0f, 0.0f);
    // Voice words persist between frames; start every hover sound silent.
    for (uint i = 0u; i < droneCount; ++i) audio[0].droneVoice[i] = float4(0.0f);
    for (uint i = 0u; i < 2u; ++i) audio[0].windVoice[i] = float4(0.0f, 1.0f, 0.0f, 0.0f);
    audio[0].hauntWind = float4(0.0f, 0.86f, 0.0f, 0.0f);
    audio[0].ghostVoice = float4(0.0f, 1.0f, 0.0f, 0.0f);
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

// Each sentry's tripod is a solid circle; wrecks stay solid too.
void pushOutOfSentries(thread float2 &point) {
    for (uint i = 0u; i < sentryCount; ++i) {
        float2 offset = point - sentryGround[i];
        float distance = length(offset);
        const float safeRadius = 1.05f;
        if (distance < safeRadius)
            point = sentryGround[i]
                + (distance > 0.0001f ? offset / distance : float2(0.0f, 1.0f))
                    * safeRadius;
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

// True outside the base footprint grown by pad. Position.y is world Z.
bool outdoors(float2 point, float pad) {
    return point.x <= -hullHalfWidth - pad || point.x >= hullHalfWidth + pad
        || point.y <= hullNorth - pad || point.y >= hullSouth + pad;
}

// How much of the drones' rotor sound reaches a player standing at point.
// The house's walls and roof shut the rotors out entirely. Outside they sit
// under the night wind rather than over it, and inside the base the walls
// muffle them further, less so toward the open south doorway.
float droneHearing(float2 point) {
    if (houseUnderRoof(point)) return 0.0f;
    float walls = outdoors(point, 0.0f) ? 1.0f
        : 0.35f * (1.0f - smoothstep(0.0f, 30.0f, hullSouth - point.y));
    return 0.45f * walls;
}

// The moon flattens to level ground beside the base walls.
float moonApron(float2 p) {
    float2 wall = clamp(p, float2(-hullHalfWidth, hullNorth),
        float2(hullHalfWidth, hullSouth));
    return smoothstep(6.0f, 60.0f, distance(p, wall));
}

// Boulders about 2 m tall and scattered stones gather in patchy fields
// between bare plains.
float moonRocks(float2 p) {
    // A narrow edge keeps few boulders flattened into slabs.
    float field = smoothstep(0.5f, 0.58f,
        pixeltje_terrain::valueNoise(p / 90.0f, 91.0f));
    if (field <= 0.0f) return 0.0f;
    return field * (pixeltje_terrain::rocks(p, 12.0f, 0.35f, 92.0f)
        + pixeltje_terrain::rocks(p, 3.5f, 0.3f, 93.0f));
}

// Lunar surface around the base: rolling regolith, three crater sizes,
// boulder fields and a ring of distant highlands.
float moonHeight(float2 p, int detail) {
    float h = 7.0f * pixeltje_terrain::fbm(p / 160.0f, detail, 11.0f)
        + pixeltje_terrain::craters(p, 260.0f, 0.55f, 21.0f)
        + pixeltje_terrain::craters(p, 70.0f, 0.6f, 31.0f)
        + pixeltje_terrain::craters(p, 17.0f, 0.5f, 41.0f)
        + moonRocks(p);
    if (detail > moonTraceDetail)
        h += pixeltje_terrain::craters(p, 4.5f, 0.5f, 51.0f);
    h *= moonApron(p);
    // The buildings' lots are levelled and blend into the plain.
    h = buildingsGround(p, h);
    float radius = length(p);
    if (radius > 500.0f)
        h += 95.0f * smoothstep(500.0f, 1300.0f, radius)
            * (0.6f + 0.4f * pixeltje_terrain::fbm(p / 500.0f, 3, 61.0f));
    return h;
}

// Relief under a couple of metres: craterlets, pebbles and rippled dust. It
// only bends shading normals, so traces, shadows and footing skip it.
float moonGrain(float2 p) {
    return pixeltje_terrain::craters(p, 1.8f, 0.3f, 52.0f)
        + pixeltje_terrain::rocks(p, 0.6f, 0.1f, 94.0f)
        + 0.06f * pixeltje_terrain::fbm(p / 1.5f, 3, 95.0f);
}

struct MoonSurface {
    int detail;
    float grain;  // weight of moonGrain; 0 when left out
    float operator()(float2 p) const {
        float h = moonHeight(p, detail);
        return grain > 0.0f ? h + grain * moonGrain(p) : h;
    }
};

// ------------------------------------------------------------ terrain maps

// The terrain never changes, so initialize bakes what the views ask of it
// most often. The bound map holds the highest point of the trace field over
// each cell, so a ray can skip through clear air with one read per step and
// evaluate the field only near the ground. The shadow maps hold, for the
// Earth and the sun, the height below which each column of the plain lies
// in the terrain's shadow. A fine level covers the settlement and a coarse
// one the walkable plain; outside both, the field answers as before.
struct TerrainLevel {
    float2 origin;  // world x and z of the level's first corner
    float cell;     // metres per texel
    uint size;      // texels per side
    uint offset;    // first texel in the maps
};

constant TerrainLevel terrainLevels[2] = {
    {float2(-384.0f, -304.0f), 1.0f, 768u, 0u},
    {float2(-2048.0f, -2048.0f), 8.0f, 512u, 589824u}};
constant uint terrainMapTexels = 851968u;   // both levels
constant uint terrainMapRow = 1024u;        // texels per row of a bake grid
// The sun's map refreshes one band per tick, all of it every 16 ticks.
constant uint sunShadowBands = 16u;
constant uint sunShadowBandTexels = terrainMapTexels / sunShadowBands;

// The highest point of the trace field over the cell under p, or infinity
// where no level covers p.
float terrainBound(device const float *bounds, float2 p) {
    for (uint l = 0u; l < 2u; ++l) {
        TerrainLevel level = terrainLevels[l];
        float2 q = (p - level.origin) / level.cell;
        if (all(q >= 0.0f) && all(q < float(level.size)))
            return bounds[level.offset + uint(q.y) * level.size + uint(q.x)];
    }
    return INFINITY;
}

// pixeltje_terrain::trace over MoonSurface{moonTraceDetail}, finding the
// same surface. While the ray clears the bound by half a metre, and by more
// with distance, the true gap is at least that clearance, so the step takes
// it without the field. Bounded steps are shorter than exact ones, so the
// march may take more of them than the field's own 160; each costs one read.
float traceTerrainBounded(device const float *bounds, float3 origin,
    float3 direction, float near, float far) {
    MoonSurface field = {moonTraceDetail};
    float t = near, previousT = near, previousGap = 0.0f;
    bool previousExact = false;
    for (int i = 0; i < 480; ++i) {
        float3 p = origin + direction * t;
        float clearance = p.y - terrainBound(bounds, p.xz);
        bool exact = clearance < 0.5f + 0.01f * t;
        float gap = clearance;
        if (exact) {
            gap = p.y - field(p.xz);
            if (gap < 0.0f) {
                if (i == 0) return t;
                if (!previousExact) {
                    float3 q = origin + direction * previousT;
                    previousGap = q.y - field(q.xz);
                }
                return mix(previousT, t, previousGap / (previousGap - gap));
            }
            if (gap < 0.001f * t) return t;
        }
        if (t >= far || (p.y > moonCeiling && direction.y >= 0.0f))
            return -1.0f;
        previousT = t;
        previousGap = gap;
        previousExact = exact;
        t = min(t + max(gap * 0.45f, 0.002f + 0.004f * t), far);
    }
    return previousExact && previousGap < 0.03f * previousT
        ? previousT : -1.0f;
}

// The terrain's soft shadow at p toward a baked light, 0 to 1 like
// pixeltje_terrain::softShadow, or -1 where no level covers p.
float terrainMapShadow(device const float2 *map, float3 p) {
    for (uint l = 0u; l < 2u; ++l) {
        TerrainLevel level = terrainLevels[l];
        float2 q = (p.xz - level.origin) / level.cell - 0.5f;
        if (any(q < 0.0f) || any(q > float(level.size - 1u))) continue;
        uint2 i = min(uint2(q), uint2(level.size - 2u));
        float2 f = q - float2(i);
        uint at = level.offset + i.y * level.size + i.x;
        float2 column = mix(mix(map[at], map[at + 1u], f.x),
            mix(map[at + level.size], map[at + level.size + 1u], f.x), f.y);
        return smoothstep(0.0f, 1.0f,
            saturate(10.0f * (p.y - column.x) / max(column.y, 0.1f)));
    }
    return -1.0f;
}

// The three stair connectors have six real steps. The same height function
// positions the camera and the collision surface, so stairs, the moon and
// the haunted house's porch, floor and stairs are walkable.
float stairHeight(float2 point) {
    if (outdoors(point, 0.0f))
        return buildingsStand(point, moonHeight(point, moonTraceDetail));
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
    if (abs(x) <= exitHalfWidth - 0.42f && z >= roomLimit
        && z <= hullSouth + 0.45f) return true;
    if (outdoors(point, 0.45f))
        return dot(point, point) < moonWalkRadius * moonWalkRadius
            && !buildingsBlocked(point);
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

// The player alone climbs the haunted house's upper floors: inside its body
// their footing and walls depend on how high their feet are, at foot.
float playerGround(float2 point, float foot) {
    if (!houseBodyHolds(point)) return stairHeight(point);
    return buildingsStandFrom(point, moonHeight(point, moonTraceDetail), foot);
}

bool playerWalkable(float2 point, float foot) {
    if (!houseBodyHolds(point)) return walkable(point);
    return !buildingsBlockedFrom(point, foot);
}

// Where a spider body may stand: the walkable floor clear of the props. The
// pad is the larger of the two range spiders' prop clearances.
bool npcPathPointClear(float2 point) {
    return walkable(point) && point.y > -outerRoomFar
        && !insideProp(point, 0.6f);
}

// Moon nodes stay outside the shell, clear of its walls.
bool npcPathNodeAllowed(float2 point, uint area) {
    return area != pathAreaMoon || outdoors(point, 2.0f);
}

float entranceDoorBottom(device const GameState &game) {
    return game.bossScene.x < 0.0f ? 9.0f
        : mix(9.0f, 1.2f, smoothstep(0.0f, 0.85f, game.bossScene.x));
}

// The exit door rises while the player or a spider is near, so it needs no
// state and is fully open before anyone reaches it.
float exitDoorBottom(device const GameState &game) {
    float2 door = float2(0.0f, exitDoorZ);
    float nearest = distance(game.player.xz, door);
    for (uint i = 0u; i < enemyCount; ++i)
        if (spiderActive(game, i))
            nearest = min(nearest, distance(game.enemy[i].xz, door));
    return exitDoorTop * (1.0f - smoothstep(3.0f, 6.0f, nearest));
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

// A click after defeat restarts. After victory, the triangle scene's click
// returned here; clicks during the victory pause must not restart the game
// before handoff.
bool restartRequested(device const GameState &game, uint action) {
    return game.progress.w != phasePlaying && action > game.progress.z
        && (game.progress.w == phaseLost
            || (game.progress.w == phaseWon && game.sceneTransition.y > 0.5f));
}

// Restarting regenerates the path network, so it is a tick pass of its own
// after advanceRange: inlined into advanceRange, the generator's loop nests
// made that kernel take minutes to compile cold.
kernel void restartRange(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    uint action = uint(u.pointer.z);
    if (!restartRequested(game, action)) return;
    resetGame(game, u.frameSeed.y ^ npcPathHash(action + u.frameSeed.x));
    game.sky = float4(max(0.0f, u.parameters0.x), 0.0f, 0.0f, 0.0f);
    game.progress.z = action;
    game.effects.z = float(uint(u.movement.z));
}

// Night wind moans over the moon. Two voices play the wind loop at
// different, slowly drifting rates and pans under shared gusts, which hides
// its repeat. Walls muffle it: the house's rooms let a little through, and
// the base only near its open exit.
//
// When the house wakes, a gale rises in the dark after its lamps die and
// blows until the house settles. The haunt voice plays the same loop
// slower and deeper, fading in and out with houseHauntWind, from the
// house's side and loudest near it; the night wind ducks under it. Through
// the broken windows it fills the rooms too.
void updateWindVoices(device GameState &game, device RangeAudio &audio,
    float dt) {
    float time = game.effects.x;
    bool base = !houseUnderRoof(game.player.xz)
        && !outdoors(game.player.xz, 0.0f);
    float doorway = 0.25f * (1.0f - smoothstep(0.0f, 25.0f,
        hullSouth - game.player.z));
    float shelter = houseUnderRoof(game.player.xz) ? 0.4f
        : (base ? doorway : 1.0f);
    float haunt = houseHauntWind(game);
    float gust = 0.55f + 0.45f * (0.5f + 0.5f * sin(time * 0.37f))
        * (0.5f + 0.5f * sin(time * 0.93f + 1.3f));
    const float baseRate[2] = {1.0f, 0.78f};
    for (uint i = 0u; i < 2u; ++i) {
        float phase = float(i) * 2.1f;
        float4 voice = float4(
            (i == 0u ? 0.5f : 0.38f) * gust * shelter * (1.0f - 0.6f * haunt),
            baseRate[i] * (1.0f + 0.07f * sin(time * 0.17f + phase)
                + 0.04f * gust),
            (i == 0u ? 0.45f : -0.45f) * sin(time * 0.11f + phase), 0.0f);
        // Ease toward the target so walking through a door fades the wind.
        audio.windVoice[i] = mix(audio.windVoice[i], voice,
            1.0f - exp(-dt * 3.0f));
    }
    float2 toHouse = houseWorld(float3(0.0f)).xz - game.player.xz;
    float span = length(toHouse);
    float2 right = float2(cos(game.player.w), sin(game.player.w));
    float near = 1.0f - 0.6f * smoothstep(30.0f, 220.0f, span);
    float howl = 0.8f + 0.2f * sin(time * 1.3f) * sin(time * 0.41f + 0.7f);
    float4 gale = float4(0.95f * haunt * howl * near * (base ? doorway : 1.0f),
        0.86f * (1.0f + 0.05f * sin(time * 0.29f)),
        0.5f * dot(toHouse, right) / max(span, 1.0f)
            + 0.15f * sin(time * 0.23f), 0.0f);
    audio.hauntWind = mix(audio.hauntWind, gale, 1.0f - exp(-dt * 3.0f));
}

// The ghost moans on a loop from the moment it emerges until it has
// vanished, as solid as it looks. It is a point source like a drone: its
// level falls with distance, it pans between the ears, and its pitch rises
// as it rushes at the player. Walls between them muffle it.
void updateGhostVoice(device GameState &game, device RangeAudio &audio,
    float dt) {
    DopplerListener listener = {game.player.xyz,
        float3(game.motion.x, game.effects.w, game.motion.y),
        float3(cos(game.player.w), 0.0f, sin(game.player.w))};
    float3 ghost = game.house.haunt.yzw;
    bool base = !houseUnderRoof(game.player.xz)
        && !outdoors(game.player.xz, 0.0f);
    float doorway = 0.25f * (1.0f - smoothstep(0.0f, 25.0f,
        hullSouth - game.player.z));
    float walls = base ? doorway
        : (houseInteriorPoint(ghost) != houseUnderRoof(game.player.xz)
            ? 0.6f : 1.0f);
    float time = game.effects.x;
    DopplerSource source = {ghost, game.house.hauntMotion.xyz,
        houseGhostFade(game) * walls, 5.0f,
        1.0f + 0.03f * sin(time * 0.31f)};
    audio.ghostVoice = smoothVoice(audio.ghostVoice,
        dopplerVoice(listener, source), dt);
}

kernel void advanceRange(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device uint *sceneRequest [[buffer(2)]],
    device RangeAudio *audio [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.10f);
    uint action = uint(u.pointer.z);
    // Action keys act on the tick they go down.
    uint keys = uint(u.movement.w);
    uint pressed = keys & ~uint(game.controls.x);
    if ((pressed & keyV) != 0u)
        game.controls.y = game.controls.y > 0.5f ? 0.0f : 1.0f;
    // Keys 7, 8 and 9 are consecutive bits, in the order of the effect bits.
    game.controls.w = float(uint(game.controls.w) ^ ((pressed / keyDigit7) & 7u));
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
    game.controls.z = max(game.controls.z - dt, 0.0f);
    // The haunted house's ghost flies, and its wind blows, even after the
    // match ends.
    advanceHaunt(game, audio[0], dt);
    updateWindVoices(game, audio[0], dt);
    updateGhostVoice(game, audio[0], dt);
    game.launcher.w *= exp(-dt * 6.0f);
    game.dodge.xy *= exp(-dt * 6.5f);
    if (game.launcher.z > 0.0f) {
        game.launcher.z = max(game.launcher.z - dt, 0.0f);
        if (game.launcher.z <= 0.0f && game.arsenal.z >= 1.0f) {
            game.arsenal.z -= 1.0f;
            game.arsenal.w = 1.0f;
        }
    }
    if (game.progress.w != phasePlaying) {
        game.controls.x = float(keys);
        // A requested restart happens in the restartRange tick pass.
        if (!restartRequested(game, action) && game.progress.w == phaseWon
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
    game.player.w = baseYaw + spawnYaw + game.recoil.y;
    game.view.x = basePitch + game.recoil.x;
    bool cutscene = bossCutscene(game);

    // 1 picks the hand, 2 the pistol, 3 the shotgun and 4 the launcher,
    // indoors and out; X swaps back to the one held before. switchArms
    // lowers one weapon and raises the other.
    float chosen = game.arsenal.x;
    if ((pressed & keyDigit1) != 0u) chosen = heldHand;
    if ((pressed & keyDigit2) != 0u) chosen = heldPistol;
    if ((pressed & keyDigit3) != 0u) chosen = heldShotgun;
    if ((pressed & keyDigit4) != 0u) chosen = heldLauncher;
    if ((pressed & keyX) != 0u) chosen = game.arsenal.y;
    if (chosen != game.arsenal.x) game.arsenal.xy = float2(chosen, game.arsenal.x);
    // R reloads the weapon in hand early.
    if ((pressed & keyR) != 0u && armsReady(game)) {
        if (holdingLauncher(game)) {
            if (game.arsenal.w < 0.5f && game.launcher.z <= 0.0f
                && game.arsenal.z >= 1.0f)
                game.launcher.z = launcherReloadDuration;
        } else if (holdingShotgun(game)) {
            if (game.arms.w <= 0.0f && game.arms.z < shotgunShells)
                game.arms.w = shotgunReloadDuration;
        } else if (!holdingHand(game) && game.weapon.y <= 0.0f
            && game.weapon.x < float(magazineSize)) {
            game.weapon.y = reloadDuration;
        }
    }
}

// Movement and footing run after the controls and clocks update, and before
// enemies sense the player. Keeping the house's storey-aware collision out
// of advanceRange lets each tick pass compile independently.
kernel void advancePlayer(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device RangeAudio *audio [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.progress.w != phasePlaying) return;
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.10f);
    uint jumpAction = uint(u.movement.z);
    uint keys = uint(u.movement.w);
    uint pressed = keys & ~uint(game.controls.x);
    game.controls.x = float(keys);
    bool cutscene = bossCutscene(game);

    float2 move = clamp(u.movement.xy, float2(-1.0f), float2(1.0f));
    if (cutscene) move = float2(0.0f);
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
    float foot = game.player.y - 1.55f;
    bool wasGrounded = game.player.y
        <= 1.55f + playerGround(previousPosition, foot)
        + (onJumpPad(previousPosition) ? jumpPadHeight : 0.0f) + 0.001f;
    // Q and E dodge sideways in a quick burst on top of walking.
    uint dodgeKeys = pressed & (keyQ | keyE);
    if ((dodgeKeys == keyQ || dodgeKeys == keyE) && wasGrounded && !cutscene
        && game.controls.z <= 0.0f) {
        game.dodge.xy = right * (dodgeKeys == keyE ? dodgeSpeed : -dodgeSpeed);
        game.controls.z = dodgeCooldown;
        game.hurt.w = max(game.hurt.w, 0.045f);
    }
    // Feet accelerate and brake quickly; in the air the body keeps momentum.
    game.motion.xy = mix(game.motion.xy,
        (right * move.x + forward * move.y) * speed,
        1.0f - exp(-dt * (wasGrounded ? 11.0f : 2.2f)));
    float2 next = previousPosition + (game.motion.xy + game.dodge.xy) * dt;
    // Resolve axes independently so a diagonal approach slides along a wall.
    float2 position = previousPosition;
    if (playerWalkable(float2(next.x, position.y), foot)
        && !buildingsDoorsBar(game, float2(next.x, position.y))) {
        position.x = next.x;
    } else {
        game.motion.x = 0.0f;
        game.dodge.x = 0.0f;
    }
    if (playerWalkable(float2(position.x, next.y), foot)
        && !buildingsDoorsBar(game, float2(position.x, next.y))) {
        position.y = next.y;
    } else {
        game.motion.y = 0.0f;
        game.dodge.y = 0.0f;
    }
    next = position;
    // Walking around the outside of the base must not trip the room rules.
    bool outside = outdoors(next, 0.0f);
    if (!rangeCleared(game) && !outside
        && previousPosition.y >= -outerRoomFar + 0.3f)
        next.y = max(next.y, -outerRoomFar + 0.3f);
    if (game.bossScene.x >= 0.0f
        && previousPosition.y < bossRoomSouth - 0.35f)
        next.y = min(next.y, bossRoomSouth - 0.35f);
    pushOutOfObstacle(next, float2(-4.1f, -3.1f), float2(-1.8f, -0.7f));
    pushOutOfObstacle(next, float2(2.1f, -6.5f), float2(4.5f, -4.1f));
    pushOutOfObstacle(next, glassBoxLower.xz, glassBoxUpper.xz);
    pushOutOfChrome(next);
    pushOutOfSentries(next);
    game.player.xz = next;
    // Head bob follows the distance actually walked on the ground.
    float walked = length(next - previousPosition);
    game.motion.z = fmod(game.motion.z + walked * 1.85f, 2.0f * rangePi);
    game.motion.w = mix(game.motion.w, wasGrounded
            ? saturate(walked / max(dt * 4.6f, 0.00001f)) : 0.0f,
        1.0f - exp(-dt * 8.0f));
    if (game.bossScene.x < 0.0f && !outside
        && rangeCleared(game)
        && next.y < bossRoomSouth - 2.6f) {
        game.bossScene.x = 0.0f;
    }
    if (next.y >= -outerRoomNear + 0.5f || outside) {
        game.roomTriggers.x = 0u;
    } else if (game.roomTriggers.x == 0u
        && (insideNorthernEntryTrigger(next)
            || (previousPosition.y >= -outerRoomNear
                && next.y < -outerRoomNear))) {
        audio[0].scare = 1u;
        game.roomTriggers.x = 1u;
        if (game.roomTriggers.y == 0u) {
            game.roomTriggers.y = 1u;
            startAmbush(game);
        }
    }
    bool overJumpPad = onJumpPad(next);
    float groundY = 1.55f + playerGround(next, foot)
        + (overJumpPad ? jumpPadHeight : 0.0f);
    // On the moon, feet follow the ground downhill instead of skipping off it.
    if (outside && wasGrounded && game.effects.w <= 0.0f
        && game.player.y - groundY < 0.35f) game.player.y = groundY;
    bool grounded = game.player.y <= groundY + 0.001f;
    if (jumpAction > uint(game.effects.z)) {
        game.effects.z = float(jumpAction);
        if (grounded && !cutscene) game.effects.w = 5.2f;
    }
    if (grounded && overJumpPad) {
        game.effects.w = jumpPadLaunchSpeed;
        audio[0].launch = 1u;
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
    if (next.y < -outerRoomNear && !outside
        && game.player.y > northernCeilingY - 0.35f) {
        game.player.y = northernCeilingY - 0.35f;
        game.effects.w = min(game.effects.w, 0.0f);
    }
    // A jump in the haunted house meets the ceiling, floor or flight over
    // the player.
    float houseHeadroom = buildingsCeilingOver(next, foot) - 0.25f;
    if (game.player.y > houseHeadroom) {
        game.player.y = houseHeadroom;
        game.effects.w = min(game.effects.w, 0.0f);
    }
    collectPickups(game);

    switchArms(game, game.arsenal.x, dt);
}

// Each range spider's sight line to the player, traced in the tick pass
// between advanceRange and advanceEnemies. In the same kernel as the spiders'
// route following, this scene trace made their AI take a minute to compile
// cold. A spider moves only itself, so these are the positions each check saw.
kernel void senseSpiders(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.progress.w != phasePlaying) return;
    for (uint i = 0u; i < ordinaryEnemyCount; ++i) {
        float scale = spiderTraits(spiderVariantForSlot(i)).scale;
        game.sightLines[i] = spiderSeesPoint(game, game.enemy[i].xyz
            + float3(0.0f, 0.3f * scale + 0.1f, 0.0f), game.player.xyz)
            ? 1u : 0u;
    }
}

// Spider and boss AI is the tick pass after senseSpiders. Apart from the
// player's movement and the sight traces, each kernel compiles in seconds.
kernel void advanceEnemies(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.progress.w != phasePlaying) return;
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.10f);
    advanceSpiders(game, dt);
    advanceBoss(game, dt);
}

// What a shot from the eye strikes first: the rooms and props (the crates and
// chrome cube are part of the environment), a spider, or a flying drone.
struct ShotTrace {
    float distance;
    float3 normal;
    uint material;
    int spider;
    int drone;
    int sentry;
    bool surface;           // the environment stopped the ray
};

ShotTrace traceShot(device const GameState &game, float3 eye,
    float3 shotDirection) {
    ShotTrace shot = {sceneRayLimit, -shotDirection, 0u, -1, -1, -1, false};
    ChromePose chrome = {game.chromeRotation, game.chromeCentre.xyz};
    SceneHit environment = {sceneRayLimit, float3(0.0f),
        float3(0.0f), 0u, -1, 0u};
    traceEnvironment(environment, eye, shotDirection, chrome, game);
    if (environment.material != 0u) {
        shot.distance = environment.distance;
        shot.normal = environment.normal;
        shot.material = environment.material;
        shot.surface = true;
    }
    for (uint i = 0u; i < enemyCount; ++i) {
        if (!spiderActive(game, i)) continue;
        SpiderHit spider = traceSpider(eye, shotDirection,
            game.enemy[i].xyz, spiderVariantForSlot(i),
            game.enemyClock[i].w,
            game.gait[i].x, game.gait[i].y,
            spiderBodyRise(game.effects.x, i), 0.0f,
            spiderRear(game, i), spiderStrike(game, i), shot.distance);
        if (spider.material != 0u) {
            shot.distance = spider.distance;
            shot.spider = int(i);
            shot.normal = spider.normal;
            shot.material = spider.material;
        }
    }
    float limit = shot.distance;
    float3 normal = float3(0.0f);
    uint material = 0u;
    int drone = traceDroneShot(eye, shotDirection, game, limit, normal,
        material);
    if (drone >= 0) {
        shot.distance = limit;
        shot.normal = normal;
        shot.material = material;
        shot.spider = -1;
        shot.drone = drone;
    }
    for (uint i = 0u; i < sentryCount; ++i) {
        SpiderHit sentry = traceSentry(eye, shotDirection, game, i,
            shot.distance);
        if (sentry.material == 0u) continue;
        shot.distance = sentry.distance;
        shot.normal = sentry.normal;
        shot.material = sentry.material;
        shot.spider = -1;
        shot.drone = -1;
        shot.sentry = int(i);
    }
    return shot;
}

// One pistol round or one shotgun pellet: record its tracer and impact, and
// damage what it struck.
void fireRound(device GameState &game, float3 eye, float3 shotDirection,
    float3 muzzle, device RangeAudio &audio) {
    ShotTrace trace = traceShot(game, eye, shotDirection);
    // A shot through one of the house's windows wakes it.
    if (game.house.haunt.x < 0.0f && trace.spider < 0 && trace.drone < 0
        && trace.sentry < 0 && houseShotHitsWindow(game, eye, shotDirection,
            trace.distance))
        houseWake(game);
    int target = trace.spider;
    float3 impactPoint = eye + shotDirection * trace.distance;
    uint impactMaterial = trace.material;
    if (target < 0 && trace.drone < 0 && trace.sentry < 0 && !trace.surface) {
        impactPoint = eye + shotDirection * 28.0f;
        impactMaterial = 0u;
    }
    game.progress.y += 1u;
    ShotImpact shot;
    shot.muzzleTime = float4(muzzle, game.effects.x);
    shot.pointEnemy = float4(impactPoint, float(target + 1));
    shot.normalMaterial = float4(trace.normal, float(impactMaterial));
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
    if (trace.drone >= 0)
        damageDrone(game, uint(trace.drone), shotDirection,
            holdingShotgun(game) ? dronePelletDamage : 1.0f, audio);
    if (trace.sentry >= 0) {
        // Armour takes one point; the sensor eye takes three.
        bool sensor = trace.material == sentrySensorMaterial;
        bool destroyed = damageSentry(game, uint(trace.sentry),
            sensor ? 3.0f : 1.0f);
        game.weapon.zw = destroyed ? float2(0.40f, 3.0f)
            : (sensor ? float2(0.30f, 2.0f) : float2(0.22f, 1.0f));
    }
    if (target < 0) return;
    uint slot = uint(target);
    SpiderTraits traits = spiderTraits(spiderVariantForSlot(slot));
    // Head and eyes sit at the front of the chassis (-Z local).
    float3 head = shot.localPointYaw.xyz / traits.scale
        - float3(0.0f, 0.05f, -0.45f);
    bool headshot = length(head / float3(0.48f, 0.38f, 0.50f)) < 1.0f;
    float2 push = shotDirection.xz;
    bool killed = damageSpider(game, slot, headshot ? 2.0f : 1.0f,
        length(push) > 0.01f ? normalize(push) * 2.6f : float2(0.0f));
    game.weapon.zw = killed ? float2(0.40f, 3.0f)
        : (headshot ? float2(0.30f, 2.0f) : float2(0.22f, 1.0f));
}

// Shooting is a separate tick pass that runs after advanceRange. A shot traces
// the scene and the furred spiders; in one kernel with the spider AI, Metal
// took minutes to compile the tick cold, while each pass alone compiles in
// seconds. The pistol fires one round and the shotgun one barrel of pellets
// through the same loop, so the trace is compiled once.
kernel void fireRange(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device RangeAudio *audio [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.progress.w != phasePlaying) return;
    uint action = uint(u.pointer.z);
    // With the hand out, clicks are swingHand's.
    if (action > game.progress.z && !holdingHand(game)) {
        game.progress.z = action;
        bool shotgun = holdingShotgun(game);
        bool loaded = shotgun
            ? game.arms.z >= 1.0f && game.arms.w <= 0.0f
            : game.weapon.x >= 1.0f && game.weapon.y <= 0.0f;
        if (holdingLauncher(game)) {
            // One missile flies at a time; the launch uses the jump-pad whoosh.
            if (armsReady(game) && !bossCutscene(game)
                && game.arsenal.w > 0.5f && game.missile.w < 0.0f) {
                float3 eye = game.player.xyz + eyeOffset(game);
                float3 aim = pixeltje_3d::forward(game.player.w, game.view.x);
                float3 aimRight = normalize(cross(aim,
                    float3(0.0f, 1.0f, 0.0f)));
                float3 aimUp = cross(aimRight, aim);
                float3 muzzle = heldMuzzle(game);
                launchMissile(game, eye + aimRight * muzzle.x
                    + aimUp * muzzle.y + aim * muzzle.z, aim);
                audio[0].launch = 1u;
            }
        } else if (game.view.z <= 0.0f && loaded && armsReady(game)
            && (game.bossScene.x < 0.0f || game.bossScene.x >= 5.0f)) {
            uint pellets = 1u;
            if (shotgun) {
                game.view.z = 0.32f;
                game.view.w = 0.14f;
                game.arms.z -= 1.0f;
                // Both barrels spent: it breaks open and reloads by itself.
                if (game.arms.z < 1.0f) game.arms.w = shotgunReloadDuration;
                audio[0].shotgun = 1u;
                pellets = shotgunPellets;
            } else {
                game.view.z = 0.22f;
                game.view.w = 0.11f;
                game.weapon.x -= 1.0f;
                // An empty magazine reloads by itself; R reloads early.
                if (game.weapon.x < 1.0f) game.weapon.y = reloadDuration;
                audio[0].shot = 1u;
            }
            hearGunshot(game);
            float3 eye = game.player.xyz + eyeOffset(game);
            float3 aim = pixeltje_3d::forward(game.player.w, game.view.x);
            float3 aimRight = normalize(cross(aim, float3(0.0f, 1.0f, 0.0f)));
            float3 aimUp = cross(aimRight, aim);
            // Tracers leave the barrel that just fired.
            float3 muzzleView = heldMuzzle(game);
            float3 muzzle = eye + aimRight * muzzleView.x
                + aimUp * muzzleView.y + aim * muzzleView.z;
            for (uint pellet = 0u; pellet < pellets; ++pellet) {
                float3 direction = aim;
                if (shotgun) {
                    // Pellets fill the cone evenly, in a new pattern each shot.
                    float2 key = float2(float(game.progress.y),
                        3.7f * float(pellet) + 1.0f);
                    float radius = shotgunSpread * sqrt(hashTile(key));
                    float angle = 2.0f * rangePi
                        * hashTile(key + float2(17.0f, 5.0f));
                    direction = normalize(aim
                        + aimRight * (radius * cos(angle))
                        + aimUp * (radius * sin(angle)));
                }
                fireRound(game, eye, direction, muzzle, audio[0]);
            }
            game.burst.x = pellets;
            // The kick lands after the shot, so the first round goes where
            // the crosshair was; follow-ups climb until the recoil recovers.
            // The shotgun throws the view up and shakes it.
            game.recoil.x += shotgun ? 0.085f : 0.032f;
            game.recoil.y += (shotgun ? 0.05f : 0.024f)
                * (hashTile(float2(float(game.progress.y), 7.3f)) - 0.5f);
            game.recoil.z = 1.0f;
            if (shotgun) game.recoil.w = max(game.recoil.w, 0.45f);
        }
    }
    if (game.enemy[bossSlot].w <= 0.0f) {
        game.progress.w = phaseWon;
        game.sceneTransition.x = game.effects.x;
    }
    else if (game.view.y <= 0.0f) game.progress.w = phaseLost;
}

// What a punch strikes within reach when the fist arrives. A pane of the
// house, or its sash, curtain or boards, wakes it as a shot would; a
// spider, sentry or drone takes a blow like a pistol round's, and a spider
// is shoved back out of its bite. Returns true when the punch landed.
bool landPunch(device GameState &game, ShotTrace trace, float3 eye,
    float3 aim, device RangeAudio &audio) {
    if (houseShotHitsWindow(game, eye, aim,
            min(trace.distance, handPunchReach))) {
        if (game.house.haunt.x < 0.0f) houseWake(game);
        audio.punch += 1u;
        return true;
    }
    if (trace.distance > handPunchReach) return false;
    audio.punch += 1u;
    game.recoil.w = max(game.recoil.w, 0.3f);
    if (trace.drone >= 0)
        damageDrone(game, uint(trace.drone), aim, handPunchDamage, audio);
    if (trace.sentry >= 0) {
        bool sensor = trace.material == sentrySensorMaterial;
        bool destroyed = damageSentry(game, uint(trace.sentry),
            sensor ? 3.0f : handPunchDamage);
        game.weapon.zw = destroyed ? float2(0.40f, 3.0f)
            : (sensor ? float2(0.30f, 2.0f) : float2(0.22f, 1.0f));
    }
    if (trace.spider >= 0) {
        float2 push = aim.xz;
        bool killed = damageSpider(game, uint(trace.spider), handPunchDamage,
            length(push) > 0.01f ? normalize(push) * handPunchShove
                : float2(0.0f));
        game.weapon.zw = killed ? float2(0.40f, 3.0f) : float2(0.22f, 1.0f);
    }
    return true;
}

// True while the walker stands on the pressure plate under the house's
// front doors, not while in the air over it, or a spider does.
bool frontDoorPlatePressed(device const GameState &game) {
    if (houseOnDoorPlate(game.player.xyz - float3(0.0f, 1.55f, 0.0f),
            housePlayerPad))
        return true;
    float floorY = houseWorld(float3(0.0f, houseFloorY, 0.0f)).y;
    for (uint i = 0u; i < enemyCount; ++i)
        if (spiderActive(game, i) && houseOnDoorPlate(
                float3(game.enemy[i].x, floorY, game.enemy[i].z), 0.5f))
            return true;
    return false;
}

// The house's front doors, once open, stay open while anyone stands on the
// pressure plate under them, and the ghost holds them from when the green
// glow snaps on until it is out past the plate: they burst open for it if
// nobody knocked them open first. When the plate has been empty for
// buildingsHouseDoorsHold seconds they swing shut with the same groan, and
// a step onto the plate or a knock while they close swings them back.
// Shut, they wait for a knock again.
void swingFrontDoors(device GameState &game, device RangeAudio &audio) {
    float time = game.effects.x;
    float3 ghost = game.house.haunt.yzw;
    float floorY = houseWorld(float3(0.0f, houseFloorY, 0.0f)).y;
    bool ghostHolds = houseHauntAge(game) >= houseGreenOn
        && game.house.hauntMotion.w < 0.0f && (houseInteriorPoint(ghost)
            || houseOnDoorPlate(float3(ghost.x, floorY, ghost.z), 0.6f));
    bool pressed = frontDoorPlatePressed(game);
    game.frontDoors.w = pressed ? 1.0f : 0.0f;
    bool held = pressed || ghostHolds;
    if (held) game.frontDoors.z = time;
    float opened = game.house.doors.x;
    if (opened < 0.0f) {
        if (ghostHolds) game.house.doors.x = time;
        return;
    }
    if (game.frontDoors.x >= 0.0f) {
        if (held) {
            buildingsReopenFrontDoors(game);
        } else if (buildingsDoorOpen(game, 0u) <= 0.0f) {
            // Shut against each other: the latch catches again.
            game.house.doors.xz = float2(-100.0f, 0.0f);
            game.frontDoors.x = -100.0f;
        }
        return;
    }
    float open = opened + buildingsHouseDoorsSwing;
    if (time >= open
        && time - max(game.frontDoors.z, open) >= buildingsHouseDoorsHold) {
        game.frontDoors.xy = float2(time, buildingsDoorOpen(game, 0u));
        audio.houseDoors += 1u;
    }
}

// The doors a knock opens swing on their own time, each sounding as it
// starts to move: the cottage's creaks, the house's pair groans.
void swingDoors(device GameState &game, device RangeAudio &audio) {
    float time = game.effects.x;
    swingFrontDoors(game, audio);
    float4 doors = game.house.doors;
    if (doors.x >= 0.0f && time >= doors.x && doors.z < 0.5f) {
        audio.houseDoors += 1u;
        game.house.doors.z = 1.0f;
    }
    if (doors.y >= 0.0f && time >= doors.y && doors.w < 0.5f) {
        audio.cottageDoor += 1u;
        game.house.doors.w = 1.0f;
    }
    buildingsHangDoors(game);
}

// The hand swings in its own tick pass after fireRange, for the compile-time
// reason fireRange gives: its reach is traced like a shot. A click while a
// door is the nearest thing within knocking reach knocks: three raps; the
// first on the house's front doors wakes it, and the last opens the
// house's or the cottage's door. Any other click punches, and the punch
// strikes when the fist arrives. Clicks while the hand is lowered, raised
// or mid-swing are spent, as a gun spends them. The doors swing here too,
// whatever is held.
kernel void swingHand(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device RangeAudio *audio [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.progress.w != phasePlaying) return;
    swingDoors(game, audio[0]);
    if (!holdingHand(game) || game.arsenal.x != heldHand) {
        game.hand = float4(-100.0f, 0.0f, 0.0f, 0.0f);
        return;
    }
    float3 eye = game.player.xyz + eyeOffset(game);
    float3 aim = pixeltje_3d::forward(game.player.w, game.view.x);
    uint door;
    float doorDistance = buildingsDoorCrossing(game.house, eye, aim,
        handKnockReach, door);
    float age = handSwingAge(game);
    // While idle, w names the door in reach for the HUD's prompt.
    if (age < 0.0f) game.hand.w = armsReady(game) ? float(door) : 0.0f;
    bool click = false;
    uint action = uint(u.pointer.z);
    if (action > game.progress.z) {
        game.progress.z = action;
        click = age < 0.0f && armsReady(game) && !bossCutscene(game);
    }
    bool contact = age >= handPunchContact && !handKnocking(game)
        && game.hand.z < 0.5f;
    if (click || contact) {
        ShotTrace trace = traceShot(game, eye, aim);
        if (click) {
            // The door must be what the hand meets first.
            bool knock = door != 0u && doorDistance <= trace.distance + 0.1f;
            game.hand = float4(game.effects.x, knock ? 1.0f : 0.0f, 0.0f,
                knock ? float(door) : 0.0f);
        } else {
            game.hand.z = landPunch(game, trace, eye, aim, audio[0])
                ? 2.0f : 1.0f;
        }
    }
    age = handSwingAge(game);
    uint struck = uint(game.hand.z);
    if (age >= 0.0f && handKnocking(game) && struck < handRaps
        && age >= handRapTime(struck)) {
        game.hand.z = float(struck + 1u);
        audio[0].knock += 1u;
        if (struck == 0u && uint(game.hand.w) == doorOfHouse
            && game.house.haunt.x < 0.0f)
            houseWake(game);
        if (struck + 1u == handRaps)
            buildingsOpenDoor(game, uint(game.hand.w));
    }
}

// The seeker and the missile run in their own tick pass after shooting, for
// the same compile-time reason as fireRange. A blast uses the shotgun's boom.
kernel void advanceOrdnance(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device RangeAudio *audio [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.progress.w != phasePlaying) return;
    float dt = tickStep(u);
    updateSeeker(game, dt);
    if (game.missile.w >= 0.0f) {
        ChromePose chrome = {game.chromeRotation, game.chromeCentre.xyz};
        if (flyMissile(game, dt, chrome, audio[0])) audio[0].shotgun += 1u;
    }
}

// Sentries aim and fire, then their bolts fly. A sentry shot uses the
// drones' laser sound.
kernel void advanceSentries(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device RangeAudio *audio [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.progress.w != phasePlaying) return;
    float dt = tickStep(u);
    for (uint i = 0u; i < sentryCount; ++i)
        if (advanceSentry(game, i, dt)) audio[0].laser = 1u;
    ChromePose chrome = {game.chromeRotation, game.chromeCentre.xyz};
    for (uint b = 0u; b < boltCount; ++b)
        advanceBolt(game, b, dt, chrome);
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
            || (wall == 3u && abs(point.x) < exitHalfWidth)
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

void traceBox(thread SceneHit &hit, float3 origin, float3 direction,
    float3 lower, float3 upper, uint material) {
    float3 normal;
    float t = rayBox(origin, direction, lower, upper, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, origin + direction * t, material, -1, 0u};
}

// Jambs, lintel and a raised sill line the exit opening through the shell,
// with a green exit light above it inside the arena.
void traceExit(thread SceneHit &hit, float3 origin, float3 direction,
    device const GameState &game) {
    float3 normal;
    if (rayBox(origin, direction, float3(-2.9f, -0.3f, 17.9f),
        float3(2.9f, 4.4f, 18.5f), normal) < 0.0f) return;
    traceBox(hit, origin, direction, float3(-2.9f, -0.3f, 17.98f),
        float3(-exitHalfWidth, 3.9f, 18.5f), 41u);
    traceBox(hit, origin, direction, float3(exitHalfWidth, -0.3f, 17.98f),
        float3(2.9f, 3.9f, 18.5f), 41u);
    traceBox(hit, origin, direction, float3(-2.9f, exitDoorTop, 17.98f),
        float3(2.9f, 3.9f, 18.5f), 41u);
    traceBox(hit, origin, direction, float3(-exitHalfWidth, -0.3f, 17.98f),
        float3(exitHalfWidth, 0.02f, 18.5f), 41u);
    traceBox(hit, origin, direction, float3(-1.0f, 4.0f, 17.9f),
        float3(1.0f, 4.4f, 17.98f), 42u);
    traceSlidingDoor(hit, origin, direction, exitHalfWidth, exitDoorZ,
        exitDoorBottom(game), exitDoorTop, 3u);
}

// Ray distances where a ray enters and leaves the base footprint; entry
// beyond exit means it misses.
float2 footprintSpan(float3 origin, float3 direction) {
    float2 safe = select(direction.xz, float2(0.00001f),
        abs(direction.xz) < float2(0.00001f));
    float2 a = (float2(-hullHalfWidth, hullNorth) - origin.xz) / safe;
    float2 b = (float2(hullHalfWidth, hullSouth) - origin.xz) / safe;
    float2 entry = min(a, b), exit = max(a, b);
    return float2(max(entry.x, entry.y), min(exit.x, exit.y));
}

// From outside, the shell hides the rooms except through the exit opening,
// and the moon is traced up to the shell. From inside, a ray reaches the
// moon only through the exit, so the terrain march starts where it leaves.
// Without the base, the moon is traced across its footprint as well.
void traceOutside(thread SceneHit &hit, float3 origin, float3 direction,
    bool base, device const float *bounds = nullptr) {
    bool inside = base && !outdoors(origin.xz, 0.0f);
    float2 span = footprintSpan(origin, direction);
    if (base && !inside) {
        for (uint block = 0u; block < 2u; ++block) {
            float3 normal;
            float t = rayBox(origin, direction,
                block == 0u ? hullFrontLower : hullRearLower,
                block == 0u ? hullFrontUpper : hullRearUpper, normal);
            if (t <= 0.0f || t >= hit.distance) continue;
            float3 p = origin + direction * t;
            if (normal.z > 0.5f && abs(p.x) < exitHalfWidth
                && p.y < exitDoorTop) continue;
            hit = {t, normal, p, 41u, -1, 0u};
        }
    }
    float near = inside ? span.y : 0.0f;
    float far = base && !inside && span.x > 0.0f && span.x <= span.y
        ? min(hit.distance, span.x) : hit.distance;
    if (near >= far) return;
    float t = bounds
        ? traceTerrainBounded(bounds, origin, direction, near, far)
        : pixeltje_terrain::trace(MoonSurface{moonTraceDetail}, origin,
            direction, near, far, moonCeiling, 160);
    if (t < 0.0f) return;
    float3 p = origin + direction * t;
    float epsilon = 0.02f + 0.002f * t;
    // Fine relief fades out before it shrinks below a pixel and aliases,
    // and stays off the street's asphalt.
    float grain = (1.0f - smoothstep(0.06f, 0.2f, epsilon))
        * (1.0f - buildingsPaved(p.xz));
    hit = {t, pixeltje_terrain::normal(MoonSurface{moonShadeDetail, grain},
        p.xz, epsilon), p, 40u, -1, 0u};
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
        rangeCleared(game) ? 9.0f : 1.2f,
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
    traceExit(hit, origin, direction, game);
    traceBuildings(hit, origin, direction, game);
    // Last, so the terrain march stops at the nearest other surface.
    traceOutside(hit, origin, direction, true);
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

// One pixel's footprint on a surface, as world-space axes across and along
// the view direction. Sampling with gradients from these keeps mip level and
// anisotropy right at silhouettes and in reflections, where screen-space
// derivatives of ray-cast coordinates are meaningless.
struct PixelFootprint {
    float3 across;
    float3 along;
};

PixelFootprint pixelFootprint(float3 direction, float3 normal, float width) {
    float3 across = cross(direction, normal);
    float sine = length(across);
    across = sine > 1.0e-4f ? across / sine
        : normalize(cross(normal, abs(normal.y) < 0.9f
            ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f)));
    float facing = max(abs(dot(direction, normal)), 0.05f);
    return {across * width, cross(normal, across) * (width / facing)};
}

float2 crateFaceUV(float3 local, float3 normal) {
    if (abs(normal.x) > 0.5f)
        return float2(normal.x > 0.0f ? 1.0f - local.z : local.z,
            1.0f - local.y);
    if (abs(normal.z) > 0.5f)
        return float2(normal.z > 0.0f ? local.x : 1.0f - local.x,
            1.0f - local.y);
    return float2(local.x, normal.y > 0.0f ? local.z : 1.0f - local.z);
}

float3 crateTexture(texture2d<float> image, SceneHit hit, float3 direction,
    float pixelWidth) {
    // Each generated image is a flat material panel, not a cube atlas. Map it
    // once onto each face in crate-local space so paint stays aligned to its
    // face and no face wraps partway into the next repetition.
    float3 lower = hit.material == 4u
        ? float3(2.1f, 0.0f, -6.5f)
        : float3(-4.1f, 0.0f, -3.1f);
    float3 upper = hit.material == 4u
        ? float3(4.5f, 2.5f, -4.1f)
        : float3(-1.8f, 2.5f, -0.7f);
    float3 size = upper - lower;
    float3 local = clamp((hit.position - lower) / size,
        float3(0.0f), float3(1.0f));
    float2 uv = crateFaceUV(local, hit.normal);
    PixelFootprint footprint = pixelFootprint(direction, hit.normal, pixelWidth);
    constexpr sampler materialSampler(coord::normalized,
        address::clamp_to_edge, filter::linear, mip_filter::linear,
        max_anisotropy(16));
    // Crop away the source image's uncertain outer edge. The frame below is
    // built from exact face coordinates rather than asking the model to draw it.
    float4 texel = image.sample(materialSampler,
        float2(0.06f) + uv * 0.88f, gradient2d(
            (crateFaceUV(local + footprint.across / size, hit.normal) - uv) * 0.88f,
            (crateFaceUV(local + footprint.along / size, hit.normal) - uv) * 0.88f));
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

// Coverage of seam lines of half-width `width` every `spacing` metres along
// coord. Lines narrower than a pixel fade to their average coverage.
float shellLines(float coord, float spacing, float width, float blur) {
    float d = (0.5f - abs(fract(coord / spacing) - 0.5f)) * spacing;
    float line = 1.0f - smoothstep(width - blur, width + blur, d);
    return mix(line, min(2.0f * width / spacing, 1.0f),
        saturate(2.0f * blur / spacing));
}

// The base's outer shell, built like a surface station: a dark concrete
// plinth, grey cladding panels of slightly varied tone between steel ribs,
// ribbon windows lit from inside, a burnt-orange band under a steel coping,
// steel corner columns and hazard stripes around the exit. The cladding stays
// near the highlands' albedo so the low sun leaves it mid grey, and regolith
// dusts the lowest metre.
SurfaceMaterial shellMaterial(SceneHit hit, float pixelWidth) {
    float3 p = hit.position;
    float3 n = hit.normal;
    float blur = max(pixelWidth, 0.004f);
    const float3 steel = float3(0.105f, 0.11f, 0.118f);
    const float3 regolith = float3(0.15f, 0.142f, 0.132f);
    float dustNoise = smoothNoise(p.xz * 1.7f + p.y * 0.6f);
    float dust = (1.0f - smoothstep(0.1f, 1.2f + 0.6f * dustNoise, p.y))
        * 0.75f;

    if (n.y > 0.5f) {
        if (p.y < 1.0f) return {mix(steel, regolith, 0.5f), 0.5f, 0.4f,
            float3(0.0f)};
        // Roof: a dark membrane laid in bays, with drifted regolith.
        float joint = max(shellLines(p.x, 6.0f, 0.06f, blur),
            shellLines(p.z, 6.0f, 0.06f, blur));
        float3 membrane = float3(0.075f, 0.074f, 0.072f)
            * (0.85f + 0.3f * smoothNoise(p.xz * 0.35f));
        membrane = mix(membrane, steel * 0.8f, joint);
        return {mix(membrane, regolith,
            0.35f * smoothNoise(p.xz * 0.08f + 3.0f)), 0.75f, 0.05f,
            float3(0.0f)};
    }

    bool alongX = abs(n.z) > 0.5f;
    float s = alongX ? p.x : p.z;
    bool southFace = n.z > 0.5f && p.z > hullSouth - 0.4f;
    // The exit's jambs and lintel stand proud of the shell; their inner
    // faces and the faces turned into the arena are bare steel.
    if (p.z > hullSouth - 0.4f && abs(p.x) < 2.95f && p.y < 3.95f
        && !southFace)
        return {steel, 0.45f, 0.55f, float3(0.0f)};
    if (southFace && abs(p.x) < 3.5f && p.y < 4.5f) {
        float stripe = step(0.5f, fract((p.x * sign(p.x) + p.y) / 0.6f));
        stripe = mix(stripe, 0.5f, saturate(2.0f * blur / 0.6f));
        float3 hazard = mix(float3(0.03f, 0.028f, 0.025f),
            float3(0.42f, 0.30f, 0.035f), stripe);
        return {mix(hazard, regolith, dust * 0.6f), 0.55f, 0.0f,
            float3(0.0f)};
    }

    float top = p.z > hullRearUpper.z + 0.05f
        ? hullFrontUpper.y : hullRearUpper.y;
    float corner = alongX ? hullHalfWidth - abs(p.x)
        : min(hullSouth - p.z, p.z - hullNorth);
    // The tall block steps up behind the low one.
    if (!alongX && p.y > hullFrontUpper.y)
        corner = min(corner, abs(p.z - hullRearUpper.z));
    if (corner < 0.7f || p.y > top - 0.45f) {
        float bolts = shellLines(p.y, 0.9f, 0.05f, blur);
        return {mix(steel, steel * 0.6f, bolts * 0.5f), 0.7f, 0.6f,
            float3(0.0f)};
    }
    if (p.y < 0.9f) {
        float3 concrete = float3(0.105f, 0.101f, 0.096f)
            * (0.8f + 0.35f * smoothNoise(float2(s, p.y) * 2.3f));
        return {mix(concrete, regolith, dust), 0.9f, 0.0f, float3(0.0f)};
    }
    // Steel ribs every 12 m, offset so none crosses the exit.
    float rib = shellLines(s + 6.0f, 12.0f, 0.22f, blur);
    if (rib > 0.5f) return {mix(steel, regolith, dust), 0.7f, 0.6f,
        float3(0.0f)};
    if (p.y > top - 1.65f && p.y < top - 1.2f)
        return {mix(float3(0.30f, 0.105f, 0.035f), regolith, dust),
            0.85f, 0.0f, float3(0.0f)};

    // Ribbon windows: three per bay, one row on the low block and two on
    // the tall one, clear of the exit.
    float row = p.y - 3.4f;
    float rowIndex = floor(row / 7.0f);
    float rowLocal = row - rowIndex * 7.0f;
    float bayLocal = fract((s + 6.0f) / 4.0f) * 4.0f;
    bool window = row >= 0.0f && rowLocal < 1.0f && p.y < top - 2.2f
        && bayLocal > 0.45f && bayLocal < 3.55f
        && !(southFace && abs(p.x) < 6.5f);
    if (window) {
        float2 inset = float2(min(bayLocal - 0.45f, 3.55f - bayLocal),
            min(rowLocal, 1.0f - rowLocal));
        float frame = 1.0f - smoothstep(0.07f - blur, 0.07f + blur,
            min(inset.x, inset.y));
        float face = alongX ? (n.z > 0.0f ? 1.0f : 2.0f)
            : (n.x > 0.0f ? 3.0f : 4.0f);
        float pick = hashTile(float2(floor((s + 6.0f) / 4.0f),
            rowIndex + 17.0f * face));
        float3 glow = pick < 0.35f ? float3(1.0f, 0.72f, 0.42f) * 0.32f
            : (pick < 0.5f ? float3(0.62f, 0.8f, 1.0f) * 0.22f : float3(0.0f));
        // Blinds and room depth vary the glow across the pane.
        glow *= 0.7f + 0.3f * smoothNoise(float2(s * 1.3f, rowLocal * 3.0f));
        return {mix(float3(0.018f, 0.022f, 0.028f), steel * 0.7f, frame),
            mix(0.08f, 0.7f, frame), mix(0.0f, 0.6f, frame),
            glow * (1.0f - frame)};
    }

    // Cladding: 3 m by 1.5 m panels of slightly varied tone, darker seams,
    // and faint dust stains running down from the window sills.
    float2 panelCell = floor(float2(s / 3.0f, p.y / 1.5f));
    float tone = 0.86f + 0.24f * hashTile(panelCell
        + float2(alongX ? 0.0f : 53.0f, 0.0f));
    float3 cladding = float3(0.17f, 0.17f, 0.165f) * tone;
    float seam = max(shellLines(s, 3.0f, 0.025f, blur),
        shellLines(p.y, 1.5f, 0.025f, blur));
    float below = row < 0.0f ? -row : 7.0f - rowLocal;
    bool underWindow = p.y + below < top - 2.2f
        && bayLocal > 0.45f && bayLocal < 3.55f;
    float streak = underWindow && below < 2.2f
        ? (1.0f - below / 2.2f) * smoothstep(0.55f, 0.9f,
            smoothNoise(float2(s * 2.5f, 0.0f)))
        : 0.0f;
    cladding *= 1.0f - 0.28f * streak;
    cladding = mix(cladding, cladding * 0.35f, seam);
    // Matte, so walls seen toward the sun do not sheen to white.
    return {mix(cladding, regolith, dust), 0.85f, 0.0f, float3(0.0f)};
}

SurfaceMaterial surfaceMaterial(SceneHit hit,
    texture2d<float> crateA, texture2d<float> crateB,
    float3 furPosition, float time, float3 direction, float pixelWidth) {
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
        crateTexture(hit.material == 4u ? crateA : crateB, hit, direction,
            pixelWidth),
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
        bool exit = hit.variant == 3u;
        float warning = 1.0f - smoothstep(0.0f, 0.35f,
            abs(hit.position.x) / (hit.variant == 2u ? 10.5f
                : (exit ? exitHalfWidth : 5.0f)));
        return {mix(float3(0.09f, 0.11f, 0.13f),
            float3(0.34f, 0.37f, 0.39f), rib * 0.55f)
            + (exit ? float3(0.02f, 0.16f, 0.06f)
                : float3(0.20f, 0.018f, 0.012f)) * warning,
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
    if (hit.material == 40u) {
        // Regolith: dark basalt maria, ochre-brown or slate-blue with their
        // titanium, between pale highlands that also cap the distant ring.
        // Steep crater walls shed dust and show fresher, brighter soil.
        float2 p = hit.position.xz;
        float highland = smoothstep(0.38f, 0.62f, 0.5f + hit.position.y / 120.0f
            + 0.5f * pixeltje_terrain::fbm(p / 260.0f, 3, 81.0f));
        float3 mare = mix(float3(0.084f, 0.068f, 0.05f),
            float3(0.052f, 0.061f, 0.08f), smoothstep(0.3f, 0.7f, 0.5f
                + 0.6f * pixeltje_terrain::fbm(p / 160.0f, 3, 82.0f)));
        float3 upland = mix(float3(0.20f, 0.196f, 0.188f),
            float3(0.25f, 0.218f, 0.175f),
            pixeltje_terrain::valueNoise(p / 60.0f, 83.0f));
        float3 soil = mix(mare, upland, highland)
            * (0.75f + 0.5f * pixeltje_terrain::valueNoise(p / 9.0f, 84.0f))
            * (0.85f + 0.3f * pixeltje_terrain::valueNoise(p * 2.3f, 85.0f));
        // Pebbly grain fades to its mean once it is finer than a pixel.
        soil *= 1.0f + 0.4f * (1.0f - smoothstep(0.02f, 0.08f, pixelWidth))
            * (pixeltje_terrain::valueNoise(p * 9.0f, 88.0f) - 0.5f);
        soil = mix(soil, soil * 1.35f + 0.015f,
            smoothstep(0.1f, 0.4f, 1.0f - hit.normal.y));
        // Boulders are dark basalt or paler breccia, grainy and dusted on
        // their tops; soil skirts their feet.
        float rock = smoothstep(0.0f, 0.06f,
            moonRocks(p) * moonApron(p) * buildingsGroundBlend(p));
        float3 stone = mix(float3(0.035f, 0.034f, 0.033f),
            float3(0.13f, 0.122f, 0.11f),
            pixeltje_terrain::valueNoise(p / 7.0f, 86.0f))
            * (0.7f + 0.6f * pixeltje_terrain::valueNoise(p * 4.0f, 87.0f));
        stone = mix(stone, soil, 0.45f * smoothstep(0.85f, 0.98f, hit.normal.y));
        float3 ground = mix(soil, stone, rock);
        // Pale flagstones lead from the exit to the haunted house, dusted
        // and set in dark regolith.
        // Dug earth over the graves, sunk and lumpy.
        float plot = houseGraveSoil(p);
        if (plot > 0.0f) {
            ground = mix(ground, float3(0.045f, 0.04f, 0.035f)
                * (0.6f + 0.6f * pixeltje_terrain::valueNoise(p * 6.0f, 89.0f)),
                plot);
            rock = 0.0f;
        }
        float3 path = buildingsPath(p, pixelWidth);
        if (path.x > 0.0f) {
            float3 flag = float3(0.2f, 0.193f, 0.18f)
                * (0.75f + 0.5f * path.z);
            ground = mix(soil * 0.8f, flag, path.y);
            rock = 0.0f;
        }
        // The street's asphalt, over the flagstones where the road crosses
        // the path, and dusted with soil at its edges.
        float4 paving = buildingsPaving(p, pixelWidth);
        if (paving.w > 0.0f) {
            ground = mix(ground, paving.xyz, paving.w);
            rock *= 1.0f - paving.w;
        }
        return {ground, mix(0.97f, 0.8f, rock), 0.0f, float3(0.0f)};
    }
    if (hit.material == 41u) return shellMaterial(hit, pixelWidth);
    if (hit.material == 42u) return {
        float3(0.05f), 0.4f, 0.0f, float3(0.10f, 1.6f, 0.45f)};
    if (hit.material == sentryArmourMaterial
        || hit.material == sentryWreckMaterial) {
        // Sand-painted armour, mottled; wrecks are scorched.
        float3 paint = float3(0.30f, 0.27f, 0.19f)
            * (0.85f + 0.3f * smoothNoise(hit.position.xz * 9.0f
                + hit.position.y * 5.0f));
        if (hit.material == sentryWreckMaterial)
            paint = mix(float3(0.03f, 0.028f, 0.026f), paint * 0.4f,
                smoothNoise(hit.position.xz * 14.0f));
        return {paint, 0.55f, 0.25f, float3(0.0f)};
    }
    if (hit.material == sentryMetalMaterial) return {
        float3(0.10f, 0.105f, 0.11f), 0.38f, 0.6f, float3(0.0f)};
    if (hit.material == sentrySensorMaterial) return {
        float3(0.12f, 0.01f, 0.01f), 0.08f, 0.0f, float3(0.5f, 0.02f, 0.012f)};
    if (hit.material == pickupMaterialID) return pickupMaterial(hit, time);
    if (hit.material == missileMaterial) return {
        float3(0.11f, 0.13f, 0.07f), 0.6f, 0.1f, float3(0.0f)};
    if (hit.material == 5u || hit.material == 15u
        || hit.material == 16u || hit.material == 17u
        || hit.material == 18u || hit.material == 19u)
        return spiderSurfaceMaterial(hit.material, furPosition,
            hit.fur, SpiderVariant(hit.variant));
    if (droneMaterial(hit.material))
        return droneSurfaceMaterial(hit.material, false);
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

// Soft sphere occlusion (after Inigo Quilez): 1 is fully lit. Spheres beyond
// the light or behind the surface never shade it.
float sphereSoftShadow(float3 origin, float3 direction, float lightDistance,
    float4 sphere) {
    float3 offset = origin - sphere.xyz;
    float b = dot(offset, direction);
    float c = dot(offset, offset) - sphere.w * sphere.w;
    if (c <= 0.0f || b >= 0.0f || -b > lightDistance) return 1.0f;
    float h = b * b - c;
    float d = sqrt(max(sphere.w * sphere.w - h, 0.0f)) - sphere.w;
    float t = -b - sqrt(max(h, 0.0f));
    return t < 0.0f ? 1.0f : smoothstep(0.0f, 1.0f, 2.5f * 8.0f * d / t);
}

// Each living or fallen spider casts a soft shadow from a sphere around its
// body. Its legs cast none.
float spiderShadow(float3 origin, float3 direction, float lightDistance,
    device const GameState &game) {
    float lit = 1.0f;
    for (uint i = 0u; i < enemyCount; ++i) {
        if (!spiderActive(game, i)) continue;
        float scale = spiderTraits(spiderVariantForSlot(i)).scale;
        lit *= sphereSoftShadow(origin, direction, lightDistance,
            float4(game.enemy[i].xyz + float3(0.0f, 0.05f * scale,
                0.15f * scale), 0.58f * scale));
    }
    for (uint i = 0u; i < min(game.progress.x, targetKills); ++i) {
        FallenSpider fallen = game.fallen[i];
        float scale = spiderTraits(SpiderVariant(fallen.appearance.x)).scale;
        float collapse = smoothstep(0.0f, 0.65f,
            game.effects.x - fallen.motion.z);
        float3 centre = fallen.pose.xyz;
        centre.y = mix(centre.y, stairHeight(centre.xz) + scale * 0.37f,
            collapse);
        lit *= sphereSoftShadow(origin, direction, lightDistance,
            float4(centre, 0.52f * scale));
    }
    return lit;
}

// Sentry heads cast a soft shadow; tripods and barrels cast none.
float sentryShadow(float3 origin, float3 direction, float lightDistance,
    device const GameState &game) {
    float lit = 1.0f;
    for (uint i = 0u; i < sentryCount; ++i)
        lit *= sphereSoftShadow(origin, direction, lightDistance,
            float4(sentryBase(game, i) + float3(0.0f, 1.3f, 0.0f), 0.4f));
    return lit;
}

float3 shadePointLight(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, PointLight light, ChromePose chrome,
    device const GameState &game) {
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
    float lit = spiderShadow(shadowOrigin, l, lightDistance, game)
        * sentryShadow(shadowOrigin, l, lightDistance, game);
    if (lit <= 0.0f) return float3(0.0f);

    float3 radiance = light.color * light.power * shade * lit
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

// Regolith is a dark, porous powder that scatters light back toward the sun:
// Hapke's single-scattering term with a backward Henyey–Greenstein lobe and
// the shadow-hiding opposition surge. Unlike glossy Lambert it never sheens
// when you look into the sun, and it does not darken toward grazing view, so
// the plain reads as lit dust. Its single-scattering albedo exceeds the
// diffuse albedo; 1.6 times keeps a side-lit plain about as bright as before.
// The lobe and surge are milder than measured lunar values, so the plain
// with the sun behind you is not blown out to white.
float3 regolithReflectance(float3 normal, float3 viewDirection,
    float3 albedo, float3 lightDirection) {
    float mu0 = max(dot(normal, lightDirection), 0.0f);
    float mu = max(dot(normal, viewDirection), 0.0f);
    float cosPhase = clamp(dot(lightDirection, viewDirection), -1.0f, 1.0f);
    const float asymmetry = 0.2f;
    float lobe = (1.0f - asymmetry * asymmetry) / pow(1.0f
        + asymmetry * asymmetry - 2.0f * asymmetry * cosPhase, 1.5f);
    float halfTangent = sqrt((1.0f - cosPhase) / (1.0f + cosPhase + 1.0e-4f));
    float surge = 0.5f / (1.0f + halfTangent / 0.06f);
    return albedo * 1.6f / (4.0f * rangePi) * mu0 / max(mu0 + mu, 1.0e-4f)
        * lobe * (1.0f + surge);
}

// Where the sun stands `afterNoon` seconds after lunar noon; dayClock gives
// that for the current moment of a match. Strength is 1 while its disc is
// clear of the horizon and fades to 0 as it sets; it is 0 throughout when
// the day-night transition is off.
struct Daylight {
    float3 direction;
    float strength;
};

Daylight daylight(float afterNoon) {
    if (!enableDayNightTransition) return {sunsetDirection, 0.0f};
    // Noon is a quarter turn above the sunset point. The sun's height, and
    // so the light it puts on level ground, falls evenly over the duration
    // and runs a little past the horizon, so the disc is fully down at the
    // end.
    float angle = asin(mix(1.0f, -0.1f,
        saturate(afterNoon / dayNightDuration)));
    float3 direction = cos(angle) * sunsetDirection
        + sin(angle) * sunNoonDirection;
    return {direction, smoothstep(-sunRadius, sunRadius, direction.y)};
}

bool atmosphereOn() {
    return enableDayNightTransition && enableAtmosphere;
}

// How much daylight the air still scatters: 1 by day, falling through
// twilight to 0 when the sun is about 5° below the horizon.
float atmosphereDay(Daylight sun) {
    return atmosphereOn() ? smoothstep(-0.09f, 0.12f, sun.direction.y) : 0.0f;
}

// The sunlight left after its path through the air: white overhead, gold
// and then red as the sun nears the horizon and its path lengthens.
float3 sunTransmittance(Daylight sun) {
    if (!atmosphereOn()) return float3(1.0f);
    float airMass = 1.0f / (max(sun.direction.y, 0.0f) + 0.06f);
    return exp(-float3(0.02f, 0.06f, 0.16f) * max(airMass - 1.0f, 0.0f));
}

// The sky's colour in `direction`: deep blue overhead, paler toward the
// horizon and bright around the sun. As the sun gets low the horizon on its
// side warms to orange, and after it sets the sky deepens to black.
float3 atmosphereSky(float3 direction, Daylight sun) {
    float day = atmosphereDay(sun);
    if (day <= 0.0f) return float3(0.0f);
    float height = sun.direction.y;
    float horizon = pow(1.0f - saturate(direction.y), 3.0f);
    float3 sky = mix(float3(0.045f, 0.12f, 0.36f),
        float3(0.26f, 0.38f, 0.58f), horizon);
    float facing = dot(direction, sun.direction);
    float side = pow(saturate(0.5f + 0.5f * facing), 3.0f);
    float low = 1.0f - smoothstep(-0.02f, 0.3f, height);
    sky = mix(sky, float3(0.95f, 0.42f, 0.14f),
        low * horizon * (0.25f + 0.75f * side));
    // Light scattered forward around the sun, coloured by its path.
    sky += sunColor * sunTransmittance(sun) * sun.strength
        * (0.5f * pow(saturate(facing), 48.0f)
            + 0.12f * pow(saturate(facing), 6.0f));
    // Twilight fades the sky away from the sun first.
    return sky * day * day * mix(1.0f, 0.4f + 0.6f * side, low);
}

// The light the whole sky sheds on a surface facing straight up.
float3 atmosphereSkyLight(Daylight sun) {
    return atmosphereSky(normalize(float3(0.0f, 0.6f, 0.8f)), sun);
}

// How brightly the plain lights what faces it, in units of the earthshine
// it bounces at night. The sun's share follows its irradiance on level
// ground, relative to the Earth's.
float3 regolithBounce(Daylight sun) {
    float sunShare = sunIrradiance * saturate(sun.direction.y) * sun.strength
        / (1.4f * earthDirection.y);
    return earthColor + sunColor * sunTransmittance(sun) * sunShare;
}

// The Earth and the sun are point lights 10 km away, so room-light shading
// serves them. The shell, the haunted buildings and the terrain cast their
// shadows.
float3 shadeDistantLight(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, ChromePose chrome, device const GameState &game,
    float3 lightDirection, float3 lightColor, float power,
    device const float2 *shadowMap = nullptr) {
    if (dot(hit.normal, lightDirection) <= 0.0f) return float3(0.0f);
    float3 origin = hit.position + hit.normal * 0.05f;
    if ((renderBase && (crateBlocksLight(origin, lightDirection, 1.0e4f,
            hullFrontLower, hullFrontUpper)
        || crateBlocksLight(origin, lightDirection, 1.0e4f,
            hullRearLower, hullRearUpper)))
        || buildingsBlockLight(origin, lightDirection, 1.0e4f, game))
        return float3(0.0f);
    float terrainLit = shadowMap ? terrainMapShadow(shadowMap, origin) : -1.0f;
    if (terrainLit < 0.0f)
        terrainLit = pixeltje_terrain::softShadow(MoonSurface{moonTraceDetail},
            origin, lightDirection, 0.1f, 600.0f, moonCeiling, 10.0f, 48);
    float lit = terrainLit * droneShadow(origin, lightDirection, 1.0e4f, game);
    if (lit <= 0.0f) return float3(0.0f);
    PointLight light = {hit.position + lightDirection * 1.0e4f,
        lightColor, power, false};
    if (hit.material == 40u) {
        float3 irradiance = lightColor * power / (4.0f * rangePi * 1.0e8f);
        return lit * irradiance * regolithReflectance(hit.normal,
            viewDirection, material.albedo, lightDirection);
    }
    return lit * shadePointLight(hit, material, viewDirection, light, chrome,
        game);
}

float3 shadeDistantLights(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, ChromePose chrome, device const GameState &game,
    device const float2 *earthShadow = nullptr,
    device const float2 *sunShadow = nullptr) {
    float3 color = shadeDistantLight(hit, material, viewDirection, chrome,
        game, earthDirection, earthColor, earthPower, earthShadow);
    Daylight sun = daylight(dayClock(game));
    if (sun.strength > 0.0f)
        color += shadeDistantLight(hit, material, viewDirection, chrome, game,
            sun.direction, sunColor * sunTransmittance(sun),
            sunPower * sun.strength, sunShadow);
    return color;
}

// ------------------------------------------------------- terrain map baking

// The level and world x and z of texel index of the terrain maps.
uint terrainTexel(uint index, thread float2 &corner) {
    uint l = index < terrainLevels[1].offset ? 0u : 1u;
    TerrainLevel level = terrainLevels[l];
    uint local = index - level.offset;
    corner = level.origin + float2(float(local % level.size),
        float(local / level.size)) * level.cell;
    return l;
}

// One column's shadow toward light: the height below which the column is in
// shadow, and the distance that sets the penumbra. A point at height y is
// lit by 10 (y - height) / distance, which matches the soft shadow march at
// the ground and reaches 0 at the hard shadow's edge.
float2 terrainShadowColumn(float2 centre, float3 light) {
    MoonSurface field = {moonTraceDetail};
    float ground = field(centre) + 0.05f;
    float highest = -INFINITY, highestAt = 600.0f, lit = 1.0f;
    float t = 0.1f;
    for (int i = 0; i < 48 && t < 600.0f; ++i) {
        float3 p = float3(centre.x, ground, centre.y) + light * t;
        if (p.y > moonCeiling && light.y >= 0.0f) break;
        float h = field(p.xz);
        float gap = p.y - h;
        float shadowHeight = h - light.y * t;
        if (shadowHeight > highest) {
            highest = shadowHeight;
            highestAt = t;
        }
        lit = min(lit, 10.0f * gap / t);
        t += max(gap * 0.5f, 0.05f + 0.02f * t);
    }
    if (highest == -INFINITY) return float2(-1.0e6f, 600.0f);
    float distance = lit > 0.0f ? 10.0f * (ground - highest) / lit : highestAt;
    return float2(highest, max(distance, 0.1f));
}

kernel void bakeTerrainBounds(device float *bounds [[buffer(1)]],
    uint2 id [[thread_position_in_grid]]) {
    uint index = id.y * terrainMapRow + id.x;
    if (index >= terrainMapTexels) return;
    float2 corner;
    uint l = terrainTexel(index, corner);
    // Samples every quarter metre in the fine level and every metre in the
    // coarse one. Between samples the field rises at most 2.5 per metre.
    uint samples = l == 0u ? 5u : 9u;
    float spacing = terrainLevels[l].cell / float(samples - 1u);
    MoonSurface field = {moonTraceDetail};
    float highest = -INFINITY;
    for (uint y = 0u; y < samples; ++y)
        for (uint x = 0u; x < samples; ++x)
            highest = max(highest,
                field(corner + float2(float(x), float(y)) * spacing));
    bounds[index] = highest + 2.5f * spacing * 0.7072f + 0.02f;
}

kernel void bakeEarthShadows(device float2 *shadows [[buffer(1)]],
    uint2 id [[thread_position_in_grid]]) {
    uint index = id.y * terrainMapRow + id.x;
    if (index >= terrainMapTexels) return;
    float2 corner;
    uint l = terrainTexel(index, corner);
    shadows[index] = terrainShadowColumn(
        corner + 0.5f * terrainLevels[l].cell, earthDirection);
}

void bakeSunShadow(uint index, device const GameState &game,
    device float2 *shadows) {
    if (index >= terrainMapTexels) return;
    Daylight sun = daylight(dayClock(game));
    if (sun.strength <= 0.0f) return;
    float2 corner;
    uint l = terrainTexel(index, corner);
    shadows[index] = terrainShadowColumn(
        corner + 0.5f * terrainLevels[l].cell, sun.direction);
}

kernel void bakeSunShadows(device const GameState *states [[buffer(1)]],
    device float2 *shadows [[buffer(2)]],
    uint2 id [[thread_position_in_grid]]) {
    bakeSunShadow(id.y * terrainMapRow + id.x, states[0], shadows);
}

// The sun moves a quarter turn in twenty minutes, so one band per tick keeps
// its shadows current.
kernel void refreshSunShadows(constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    device float2 *shadows [[buffer(2)]],
    uint2 id [[thread_position_in_grid]]) {
    uint band = u.frameSeed.x % sunShadowBands;
    bakeSunShadow(band * sunShadowBandTexels + id.y * terrainMapRow + id.x,
        states[0], shadows);
}

// The ghost's green light reaches surfaces on its own side of the house's
// walls, near it.
float3 houseGhostLighting(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, ChromePose chrome, device const GameState &game,
    bool indoors) {
    PointLight ghost;
    if (!houseGhostLight(game, indoors, ghost)
        || distance(ghost.position, hit.position) > 24.0f) return float3(0.0f);
    return shadePointLight(hit, material, viewDirection, ghost, chrome, game);
}

// The haunted buildings' lanterns and the street lamps light what is near
// them outside. They cast no shadows; the house's own walls face away from
// them.
float3 houseOutdoorLighting(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, ChromePose chrome, device const GameState &game) {
    float3 color = float3(0.0f);
    for (uint i = 0u; i < buildingsOutdoorLightCount; ++i) {
        PointLight light = buildingsOutdoorLight(i, game);
        float reach = distance(light.position, hit.position)
            / (16.0f * houseScale);
        if (reach >= 1.0f) continue;
        float window = 1.0f - reach * reach * reach * reach;
        light.power *= window * window;
        color += shadePointLight(hit, material, viewDirection, light, chrome,
            game);
    }
    uint2 lamps = buildingsStreetLampsNear(hit.position);
    float dim = lamps.y > lamps.x ? houseHaunting(game).dim : 0.0f;
    for (uint i = lamps.x; i < lamps.y; ++i) {
        PointLight light = buildingsStreetLamp(i, game, dim);
        float reach = distance(light.position, hit.position)
            / buildingsStreetLampReach;
        if (reach >= 1.0f) continue;
        float window = 1.0f - reach * reach * reach * reach;
        light.power *= window * window;
        color += shadePointLight(hit, material, viewDirection, light, chrome,
            game);
    }
    color += houseGhostLighting(hit, material, viewDirection, chrome, game,
        false);
    return color;
}

// Each room of the house is lit by its own lamps; the doorways let a little
// of the neighbouring rooms' light through, and the stairwell joins the
// halls of the storeys.
float3 houseIndoorLighting(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, ChromePose chrome, device const GameState &game) {
    float3 color = float3(0.0f);
    uint room = houseRoom(hit.position);
    float3 local = houseLocal(hit.position);
    for (uint i = 0u; i < houseIndoorLightCount; ++i) {
        uint lightRoom;
        PointLight light = houseHauntedIndoorLight(i, game, lightRoom);
        float share = houseLightShare(lightRoom, room, local);
        if (share <= 0.0f) continue;
        light.power *= share;
        color += shadePointLight(hit, material, viewDirection, light, chrome,
            game);
    }
    // The sill candles light their own rooms softly.
    for (uint i = 0u; i < min(game.house.counts.z, houseCandleCapacity); ++i) {
        float4 candle = game.house.candles[i];
        if (uint(candle.w) != room) continue;
        PointLight light = {candle.xyz, float3(1.0f, 0.6f, 0.26f),
            9.0f * houseFlicker(game.effects.x, candle.x * 7.0f, 0.25f)
                * houseHaunting(game).dim, false};
        color += shadePointLight(hit, material, viewDirection, light, chrome,
            game);
    }
    color += houseGhostLighting(hit, material, viewDirection, chrome, game,
        true);
    return color;
}

// A full Earth: oceans, continents and drifting cloud bands under a thin
// blue limb, with a sliver of night on one edge. Coverage hides the stars.
float3 earthDisc(float3 direction, float pixelAngle, thread float &coverage) {
    coverage = 0.0f;
    float facing = dot(direction, earthDirection);
    if (facing < cos(earthRadius * 1.6f)) return float3(0.0f);
    float3 east = normalize(cross(float3(0.0f, 1.0f, 0.0f), earthDirection));
    float3 north = cross(earthDirection, east);
    float2 q = float2(dot(direction, east), dot(direction, north))
        / earthRadius;
    float r = length(q);
    float edge = max(pixelAngle / earthRadius, 0.01f);
    coverage = 1.0f - smoothstep(1.0f - edge, 1.0f + edge, r);
    float3 halo = float3(0.25f, 0.45f, 1.0f) * 0.18f
        * exp(-max(r - 1.0f, 0.0f) * 14.0f) * (1.0f - coverage);
    if (coverage <= 0.0f) return halo;
    float3 sphere = float3(q, sqrt(max(1.0f - dot(q, q), 0.0f)));
    float2 globe = float2(atan2(sphere.x, sphere.z) + 0.8f,
        asin(clamp(sphere.y, -1.0f, 1.0f)));
    float land = smoothstep(0.04f, 0.12f,
        pixeltje_terrain::fbm(globe * 2.3f, 5, 141.0f));
    float3 surface = mix(float3(0.02f, 0.07f, 0.2f),
        mix(float3(0.13f, 0.1f, 0.06f), float3(0.05f, 0.09f, 0.04f),
            pixeltje_terrain::valueNoise(globe * 6.0f, 142.0f)), land);
    surface = mix(surface, float3(0.75f, 0.78f, 0.82f),
        smoothstep(1.15f, 1.3f, abs(globe.y)));
    float clouds = smoothstep(0.0f, 0.4f, pixeltje_terrain::fbm(
        float2(globe.x * 1.4f, globe.y * 3.2f) * 1.8f, 5, 151.0f));
    surface = mix(surface, float3(0.85f, 0.87f, 0.9f), 0.85f * clouds);
    float light = saturate(dot(sphere, normalize(float3(-0.35f, 0.1f, 1.0f))));
    float3 color = surface * (0.04f + light) * 2.8f;
    color += float3(0.25f, 0.45f, 1.0f) * 0.9f * pow(1.0f - sphere.z, 3.0f)
        * light;
    return color * coverage + halo;
}

// The sun's disc and the glare it leaves on the lens. Terrain in
// front of it hides it as it sets; coverage hides the stars behind it.
float3 sunDisc(float3 direction, float pixelAngle, Daylight sun,
    thread float &coverage) {
    coverage = 0.0f;
    if (sun.strength <= 0.0f) return float3(0.0f);
    // Measured from the chord, which stays precise at small angles.
    float angle = 2.0f * asin(min(0.5f * distance(direction, sun.direction),
        1.0f));
    float edge = max(pixelAngle, 0.002f);
    coverage = 1.0f - smoothstep(sunRadius - edge, sunRadius + edge, angle);
    float glare = 0.5f * exp(-angle / 0.025f) + 0.015f * exp(-angle / 0.15f);
    return sunColor * sunTransmittance(sun)
        * (30.0f * coverage + glare * sun.strength);
}

// An airless black sky with fixed stars. Stars are point sources, so each
// is drawn about one pixel (pixelAngle radians) wide. In daylight the lit
// plain outshines them: visibility fades them out.
float3 spaceSky(float3 direction, float pixelAngle, float visibility) {
    float3 color = float3(0.0f);
    // Stars sit in equal-angle cells on the six faces of a cube, which has
    // no pole or seam to stretch them. Each face-local frame is a signed axis
    // permutation, so distances measured in it are angles on the sky.
    float3 a = abs(direction);
    float3 local;
    float face;
    if (a.x >= a.y && a.x >= a.z) {
        local = float3(direction.yz, a.x);
        face = direction.x > 0.0f ? 0.0f : 1.0f;
    } else if (a.y >= a.z) {
        local = float3(direction.xz, a.y);
        face = direction.y > 0.0f ? 2.0f : 3.0f;
    } else {
        local = float3(direction.xy, a.z);
        face = direction.z > 0.0f ? 4.0f : 5.0f;
    }
    const float cells = 96.0f;  // per face edge, about 0.94° each
    float cellAngle = M_PI_2_F / cells;
    float2 cell = floor(atan(local.xy / local.z) / cellAngle);
    float2 key = cell + float2(face * 2.0f * cells, 0.0f);
    // Equal-angle cells still cover 0.71–1× the solid angle of a face-centre
    // cell; scaling the odds by it keeps the stars evenly spread.
    float2 t = tan((cell + 0.5f) * cellAngle);
    float solidAngle = (1.0f + t.x * t.x) * (1.0f + t.y * t.y)
        * pow(1.0f + dot(t, t), -1.5f);
    if (visibility <= 0.0f
        || pixeltje_terrain::hash(key, 71.0f) > 0.14f * solidAngle)
        return color;
    // Centres stay a quarter cell from the edges, and the width is capped so
    // four sigma fits there even in the narrowest (0.71×) cells: no star is
    // ever cut by its cell or by a cube seam.
    float2 centre = (cell + 0.25f + 0.5f * float2(
        pixeltje_terrain::hash(key, 72.0f),
        pixeltje_terrain::hash(key, 73.0f))) * cellAngle;
    float3 star = normalize(float3(tan(centre), 1.0f));
    float sigma = min(0.7f * pixelAngle, 0.25f * 0.71f * cellAngle / 4.0f);
    float d = distance(local, star);
    // Counts follow N(>F) ~ F^-1.5: a few bright stars over many faint ones.
    float flux = 0.025f * pow(max(pixeltje_terrain::hash(key, 74.0f), 1e-4f),
        -2.0f / 3.0f);
    float temperature = pixeltje_terrain::hash(key, 75.0f);
    float3 tint = temperature < 0.5f
        ? mix(float3(1.0f, 0.78f, 0.56f), float3(1.0f, 0.96f, 0.90f),
            temperature * 2.0f)
        : mix(float3(1.0f, 0.96f, 0.90f), float3(0.74f, 0.84f, 1.0f),
            temperature * 2.0f - 1.0f);
    return color + visibility * tint * flux
        * exp(-0.5f * d * d / (sigma * sigma));
}

// The latest shot lights the room twice: from the muzzle while the flash
// lasts and briefly from the spark where it struck.
// shortcut: walls cast no shadows, so a shot beside a wall leaks a little
// light through it; the 9 m reach keeps that leak inside the next room.
float3 shadeShotLights(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, ChromePose chrome, device const GameState &game) {
    if (game.progress.y == 0u) return float3(0.0f);
    ShotImpact shot = game.impacts[(game.progress.y - 1u) % impactCount];
    float age = game.effects.x - shot.muzzleTime.w;
    float3 color = float3(0.0f);
    for (uint k = 0u; k < 2u; ++k) {
        float strength = k == 0u ? game.view.w / 0.11f
            : (shot.normalMaterial.w > 0.0f
                ? 1.0f - smoothstep(0.0f, 0.14f, age) : 0.0f);
        if (strength <= 0.0f || age < 0.0f) continue;
        float3 position = k == 0u ? shot.muzzleTime.xyz
            : shot.pointEnemy.xyz + shot.normalMaterial.xyz * 0.12f;
        float reach = length(position - hit.position) / 9.0f;
        if (reach >= 1.0f) continue;
        float window = 1.0f - reach * reach * reach * reach;
        PointLight light = {position, k == 0u ? float3(1.0f, 0.62f, 0.26f)
            : float3(1.0f, 0.78f, 0.45f),
            (k == 0u ? 75.0f : 22.0f) * strength * window * window};
        color += shadePointLight(hit, material, viewDirection, light, chrome,
            game);
    }
    return color;
}

// A blast floods its surroundings with orange light for a moment, and a lit
// motor lights what the missile passes.
float3 shadeOrdnanceLights(SceneHit hit, SurfaceMaterial material,
    float3 viewDirection, ChromePose chrome, device const GameState &game) {
    float3 color = float3(0.0f);
    float age = game.effects.x - game.blast.w;
    if (game.blast.w >= 0.0f && age >= 0.0f && age < 0.6f) {
        float3 position = game.blast.xyz + float3(0.0f, 0.6f, 0.0f);
        float reach = length(position - hit.position) / 16.0f;
        if (reach < 1.0f) {
            float window = 1.0f - reach * reach * reach * reach;
            PointLight light = {position, float3(1.0f, 0.55f, 0.2f),
                900.0f * (1.0f - smoothstep(0.0f, 0.6f, age))
                    * window * window};
            color += shadePointLight(hit, material, viewDirection, light,
                chrome, game);
        }
    }
    if (game.missile.w >= 0.0f && game.effects.x - game.missile.w > 0.2f) {
        float3 flame = game.missile.xyz
            - normalize(game.missileVelocity.xyz) * 1.15f;
        float reach = length(flame - hit.position) / 9.0f;
        if (reach < 1.0f) {
            float window = 1.0f - reach * reach * reach * reach;
            PointLight light = {flame, float3(1.0f, 0.6f, 0.25f),
                60.0f * window * window};
            color += shadePointLight(hit, material, viewDirection, light,
                chrome, game);
        }
    }
    return color;
}

// Room interiors are axis-aligned boxes, so the distance to each face gives
// cheap occlusion where floors meet walls and in corners. Props and spiders
// darken the floor around their footprints.
float ambientOcclusion(SceneHit hit, device const GameState &game) {
    bool roomSurface = hit.material <= 13u || hit.material == 28u
        || hit.material == 29u;
    if (hit.enemy >= 0 || hit.material == 0u || hit.material == 5u
        || !roomSurface) return 1.0f;
    const float3 lower[9] = {
        float3(-18.0f, 0.0f, -18.0f), float3(-18.0f, 1.2f, -60.0f),
        float3(24.0f, 0.9f, -18.0f), float3(-60.0f, 1.5f, -18.0f),
        float3(-3.5f, 0.0f, -24.0f), float3(18.0f, 0.0f, -3.5f),
        float3(-24.0f, 0.0f, -3.5f), float3(-5.0f, 1.2f, -70.0f),
        float3(-22.0f, 1.2f, -110.0f)};
    const float3 upper[9] = {
        float3(18.0f, 5.5f, 18.0f), float3(18.0f, 18.0f, -24.0f),
        float3(60.0f, 6.4f, 18.0f), float3(-24.0f, 7.0f, 18.0f),
        float3(3.5f, 6.7f, -18.0f), float3(24.0f, 6.4f, 3.5f),
        float3(-18.0f, 7.0f, 3.5f), float3(5.0f, 9.0f, -60.0f),
        float3(22.0f, 13.0f, -70.0f)};
    float occlusion = 1.0f;
    float3 p = hit.position;
    for (uint room = 0u; room < 9u; ++room) {
        if (any(p < lower[room] - 0.05f) || any(p > upper[room] + 0.05f))
            continue;
        float3 below = p - lower[room], above = upper[room] - p;
        float faces[6] = {below.x, above.x, below.y, above.y,
            below.z, above.z};
        for (uint face = 0u; face < 6u; ++face) {
            // Skip the face this point lies on.
            if (faces[face] < 0.03f) continue;
            occlusion *= 1.0f - 0.42f * exp(-faces[face] / 0.55f);
        }
        break;
    }
    if (hit.normal.y > 0.5f) {
        const float2 propLower[3] = {float2(-4.1f, -3.1f),
            float2(2.1f, -6.5f), glassBoxLower.xz};
        const float2 propUpper[3] = {float2(-1.8f, -0.7f),
            float2(4.5f, -4.1f), glassBoxUpper.xz};
        for (uint prop = 0u; prop < 3u; ++prop) {
            float2 outside = max(max(propLower[prop] - p.xz,
                p.xz - propUpper[prop]), float2(0.0f));
            occlusion *= 1.0f - 0.45f * exp(-length(outside) / 0.4f);
        }
        occlusion *= 1.0f - 0.4f * exp(-max(
            distance(p.xz, chromeGroundPosition) - 0.6f, 0.0f) / 0.35f);
        for (uint i = 0u; i < sentryCount; ++i)
            occlusion *= 1.0f - 0.35f * exp(-max(
                distance(p.xz, sentryGround[i]) - 0.3f, 0.0f) / 0.45f);
        for (uint i = 0u; i < enemyCount; ++i) {
            if (!spiderActive(game, i)) continue;
            float scale = spiderTraits(spiderVariantForSlot(i)).scale;
            float lift = max(game.enemy[i].y - p.y - 0.4f * scale, 0.0f);
            float2 offset = (p.xz - game.enemy[i].xz) / (1.1f * scale);
            occlusion *= 1.0f - 0.5f * exp(-dot(offset, offset) - lift * 2.0f);
        }
    }
    return occlusion;
}

void traceScene(thread SceneHit &hit, thread float3 &furPosition,
    float3 origin, float3 direction, ChromePose chrome,
    device const GameState &game, device const float *bounds = nullptr) {
    // Shots and sight lines always meet the base through traceEnvironment;
    // renderBase only decides whether the view draws it.
    if (renderBase) {
        traceEnvironment(hit, origin, direction, chrome, game);
    } else {
        traceBuildings(hit, origin, direction, game);
        traceOutside(hit, origin, direction, false, bounds);
    }
    for (uint i = 0u; i < enemyCount; ++i) {
        if (!spiderActive(game, i)) continue;
        SpiderHit spider = traceSpider(origin, direction, game.enemy[i].xyz,
            spiderVariantForSlot(i), game.enemyClock[i].w,
            game.gait[i].x, game.gait[i].y,
            spiderBodyRise(game.effects.x, i), 0.0f,
            spiderRear(game, i), spiderStrike(game, i), hit.distance);
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
            fallen.motion.w * (1.0f - collapse), collapse, 0.0f, 0.0f,
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
    traceDrones(hit, origin, direction, game);
    for (uint i = 0u; i < sentryCount; ++i) {
        SpiderHit sentry = traceSentry(origin, direction, game, i,
            hit.distance);
        if (sentry.material != 0u)
            hit = {sentry.distance, sentry.normal,
                origin + direction * sentry.distance, sentry.material, -1, i};
    }
    tracePickups(hit, origin, direction, game);
    traceMissile(hit, origin, direction, game);
}

float3 chromeReflection(SceneHit hit, float3 incoming,
    texture2d<float> crateA, texture2d<float> crateB,
    ChromePose chrome, device const GameState &game, float pixelSpread) {
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
        crateA, crateB, reflectedFurPosition, game.effects.x,
        reflectedDirection,
        pixelSpread * (hit.distance + reflectedHit.distance));
    float3 color = reflected.albedo * 0.32f + reflected.emission;
    for (uint i = 0u; i < 8u; ++i)
        color += shadePointLight(reflectedHit, reflected,
            -reflectedDirection, roomLight(i, game.effects.x), chrome, game);
    return color;
}

float3 shadeGlassBox(float3 background, float3 origin, float3 direction,
    float opaqueDistance, texture2d<float> crateA,
    texture2d<float> crateB, ChromePose chrome,
    device const GameState &game, float pixelSpread) {
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
            -direction, roomLight(i, game.effects.x), chrome, game);
    float3 reflection = chromeReflection(glass, direction,
        crateA, crateB, chrome, game, pixelSpread);
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
    device const GameState &game, texture2d<float> impactTexture,
    float3 direction, float pixelWidth) {
    if (hit.material == 0u) return color;
    constexpr sampler impactSampler(coord::normalized,
        address::clamp_to_edge, filter::linear, mip_filter::linear,
        max_anisotropy(16));
    PixelFootprint footprint = pixelFootprint(direction, hit.normal, pixelWidth);
    for (uint i = 0u; i < impactCount; ++i) {
        ShotImpact shot = game.impacts[i];
        float age = game.effects.x - shot.muzzleTime.w;
        bool spider = shot.pointEnemy.w > 0.0f;
        bool movingSurface = spider || uint(shot.normalMaterial.w) == 20u
            || droneMaterial(uint(shot.normalMaterial.w))
            || sentryMaterial(uint(shot.normalMaterial.w));
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
        float2x2 turn = float2x2(float2(cosine, sine), float2(-sine, cosine))
            / (radius * 2.0f);
        float4 texel = impactTexture.sample(impactSampler, uv, gradient2d(
            turn * float2(dot(footprint.across, tangent),
                dot(footprint.across, bitangent)),
            turn * float2(dot(footprint.along, tangent),
                dot(footprint.along, bitangent))));
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

// Tracers and impact flashes of the latest discharge: one pistol round or
// every pellet of a shotgun barrel.
float3 shadeShot(float3 color, float3 origin, float3 direction,
    float sceneDistance, device const GameState &game) {
    if (game.progress.y == 0u) return color;
    uint tracers = clamp(game.burst.x, 1u, min(game.progress.y, impactCount));
    for (uint k = 0u; k < tracers; ++k) {
        ShotImpact shot = game.impacts[(game.progress.y - 1u - k) % impactCount];
        float age = game.effects.x - shot.muzzleTime.w;
        if (age < 0.0f || age >= 0.18f) continue;
        float fade = 1.0f - smoothstep(0.035f, 0.18f, age);
        float3 impactPoint, impactNormal;
        resolvedImpact(game, shot, impactPoint, impactNormal);
        float3 start = shot.muzzleTime.xyz;
        float3 segment = impactPoint - start;
        float segmentLengthSquared = dot(segment, segment);
        if (segmentLengthSquared < 0.01f) continue;
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

// A box with rounded edges: rounding.x rounds the edges that run along Z,
// rounding.y every edge of the two faces across Z.
float roundedBoxDistance(float3 p, float3 lower, float3 upper,
    float2 rounding) {
    float3 extent = (upper - lower) * 0.5f;
    float3 q = abs(p - (lower + upper) * 0.5f);
    float2 side = q.xy - extent.xy + rounding.x;
    float2 w = float2(length(max(side, 0.0f))
        + min(max(side.x, side.y), 0.0f) - rounding.x, q.z - extent.z)
        + rounding.y;
    return length(max(w, 0.0f)) + min(max(w.x, w.y), 0.0f) - rounding.y;
}

// Sphere-traces a rounded box from where the ray enters its bounds.
void gunRoundedBox(thread GunHit &hit, float3 origin, float3 direction,
    float3 lower, float3 upper, float2 rounding, uint part) {
    float3 normal;
    float t = pixeltje_3d::rayBox(origin, direction, lower, upper,
        0.001f, normal);
    if (t <= 0.0f || t >= hit.distance) return;
    float limit = min(hit.distance, t + length(upper - lower));
    for (uint step = 0u; step < 32u && t < limit; ++step) {
        float3 p = origin + direction * t;
        float d = roundedBoxDistance(p, lower, upper, rounding);
        if (d < 2.0e-5f) {
            const float2 e = float2(1.0e-4f, -1.0e-4f);
            normal = normalize(
                e.xyy * roundedBoxDistance(p + e.xyy, lower, upper, rounding)
                + e.yyx * roundedBoxDistance(p + e.yyx, lower, upper, rounding)
                + e.yxy * roundedBoxDistance(p + e.yxy, lower, upper, rounding)
                + e.xxx * roundedBoxDistance(p + e.xxx, lower, upper, rounding));
            hit = {t, normal, part, p};
            return;
        }
        t += d;
    }
}

struct PistolPart {
    float3 lower;
    float3 upper;
    float2 rounding;        // see roundedBoxDistance
    uint part;
    bool slides;            // rides back with the slide after a shot
};

constant uint pistolPartCount = 6u;
constant PistolPart pistolParts[pistolPartCount] = {
    // Slide, front sight post and the two blocks of the rear sight notch.
    {float3(-0.016f, 0.018f, -0.075f), float3(0.016f, 0.050f, 0.166f),
        float2(0.0065f, 0.005f), 1u, true},
    {float3(-0.0025f, 0.046f, 0.128f), float3(0.0025f, 0.057f, 0.140f),
        float2(0.0015f), 3u, true},
    {float3(-0.014f, 0.045f, -0.068f), float3(-0.004f, 0.058f, -0.058f),
        float2(0.0025f, 0.002f), 3u, true},
    {float3(0.004f, 0.045f, -0.068f), float3(0.014f, 0.058f, -0.058f),
        float2(0.0025f, 0.002f), 3u, true},
    // Round barrel, crowned just proud of the slide's nose; a shot bares it.
    {float3(-0.0075f, 0.0245f, 0.100f), float3(0.0075f, 0.0395f, gunMuzzle.z),
        float2(0.0075f, 0.001f), 1u, false},
    // Frame and dust cover.
    {float3(-0.014f, -0.004f, -0.060f), float3(0.014f, 0.020f, 0.140f),
        float2(0.004f, 0.005f), 2u, false}
};

// The trigger guard is a round bar bent up into the dust cover.
constant float3 triggerGuard[4] = {
    float3(0.0f, -0.0265f, 0.006f), float3(0.0f, -0.0265f, 0.056f),
    float3(0.0f, -0.019f, 0.0715f), float3(0.0f, -0.002f, 0.0715f)
};

GunHit traceGun(float3 origin, float3 direction, float slide) {
    GunHit hit = {1.0e6f, float3(0.0f), 0u, float3(0.0f)};
    if (raySphere(origin, direction, float3(0.0f, -0.1f, -0.05f), 0.40f)
        < 0.0f) return hit;
    for (uint i = 0u; i < pistolPartCount; ++i) {
        PistolPart piece = pistolParts[i];
        float3 back = float3(0.0f, 0.0f, piece.slides ? -slide : 0.0f);
        gunRoundedBox(hit, origin, direction, piece.lower + back,
            piece.upper + back, piece.rounding, piece.part);
    }
    for (uint k = 0u; k < 3u; ++k)
        gunCapsule(hit, origin, direction, triggerGuard[k],
            triggerGuard[k + 1u], 0.0042f, 2u);
    // The grip rakes back 17 degrees from where it meets the frame.
    float c = cos(0.30f), s = sin(0.30f);
    GunHit grip = {hit.distance, float3(0.0f), 0u, float3(0.0f)};
    gunRoundedBox(grip,
        rotateSpiderPitch(origin - float3(0.0f, 0.0f, -0.012f), -s, c),
        rotateSpiderPitch(direction, -s, c), float3(-0.015f, -0.115f, -0.026f),
        float3(0.015f, 0.010f, 0.018f), float2(0.008f, 0.009f), 2u);
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

// The launcher in its own frame: the tube runs along Z past the shoulder to
// the muzzle; the command unit sits on its left with its display facing the
// eye, and the battery, grip and glove hang below.
GunHit traceLauncher(float3 origin, float3 direction) {
    GunHit hit = {1.0e6f, float3(0.0f), 0u, float3(0.0f)};
    if (raySphere(origin, direction, float3(-0.03f, -0.08f, 0.2f), 0.8f)
        < 0.0f) return hit;
    gunCapsule(hit, origin, direction, float3(0.0f, 0.0f, -0.45f),
        float3(0.0f, 0.0f, 0.78f), 0.068f, 10u);
    gunCapsule(hit, origin, direction, float3(0.0f, 0.0f, 0.78f),
        float3(0.0f, 0.0f, 0.84f), 0.078f, 11u);
    gunCapsule(hit, origin, direction, float3(0.0f, 0.0f, -0.5f),
        float3(0.0f, 0.0f, -0.42f), 0.078f, 11u);
    gunBox(hit, origin, direction, float3(-0.045f, -0.12f, 0.02f),
        float3(0.045f, -0.06f, 0.16f), 11u);
    gunBox(hit, origin, direction, float3(-0.022f, -0.21f, 0.06f),
        float3(0.022f, -0.11f, 0.11f), 11u);
    gunBox(hit, origin, direction, float3(-0.13f, -0.035f, 0.46f),
        float3(-0.072f, 0.04f, 0.64f), 11u);
    gunBox(hit, origin, direction, float3(-0.12f, -0.024f, 0.452f),
        float3(-0.082f, 0.03f, 0.46f), 12u);
    gunBox(hit, origin, direction, float3(-0.075f, -0.015f, 0.50f),
        float3(-0.03f, 0.015f, 0.60f), 11u);
    float3 normal;
    float t = pixeltje_3d::rayEllipsoid(origin, direction,
        float3(0.0f, -0.17f, 0.085f), float3(0.04f, 0.052f, 0.046f),
        0.001f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, 4u, origin + direction * t};
    gunCapsule(hit, origin, direction, float3(0.01f, -0.2f, 0.06f),
        float3(0.06f, -0.42f, -0.22f), 0.046f, 5u);
    return hit;
}

SurfaceMaterial launcherMaterial(GunHit hit) {
    float3 p = hit.local;
    if (hit.part == 10u) {
        // Olive drab tube with a yellow band near the muzzle.
        float band = 1.0f - step(0.02f, abs(p.z - 0.64f));
        return {mix(float3(0.075f, 0.085f, 0.05f)
                * (0.85f + 0.3f * smoothNoise(p.xz * 140.0f)),
            float3(0.36f, 0.30f, 0.07f), band), 0.72f, 0.0f, float3(0.0f)};
    }
    if (hit.part == 11u) return {
        float3(0.035f, 0.038f, 0.04f)
            * (0.85f + 0.3f * smoothNoise(p.xy * 500.0f)),
        0.55f, 0.1f, float3(0.0f)};
    return {float3(0.01f, 0.015f, 0.015f), 0.1f, 0.0f, float3(0.0f)};
}

SurfaceMaterial gunMaterial(GunHit hit) {
    float3 p = hit.local;
    if (hit.part == 1u) {
        bool bore = p.z > gunMuzzle.z - 0.002f
            && length(p.xy - gunMuzzle.xy) < 0.0045f;
        // Polished chrome, with cocking serrations at the rear and the nose
        // of the slide flanks.
        float serration = abs(hit.normal.x) > 0.5f
            && (p.z < -0.035f || (p.z > 0.100f && p.z < 0.124f))
            ? step(0.5f, fract(p.z * 230.0f)) : 0.0f;
        return {bore ? float3(0.005f)
                : float3(0.72f, 0.73f, 0.75f) * (1.0f - 0.5f * serration),
            bore ? 0.40f : 0.14f + 0.3f * serration, bore ? 0.0f : 1.0f,
            float3(0.0f)};
    }
    if (hit.part == 3u) return {float3(0.09f, 0.09f, 0.095f), 0.40f, 0.85f,
        float3(0.0f)};
    if (hit.part == 2u) return {
        float3(0.035f, 0.037f, 0.040f)
            * (0.85f + 0.3f * smoothNoise(p.yz * 900.0f)),
        0.34f, 0.0f, float3(0.0f)};
    if (hit.part == 4u) return {float3(0.045f, 0.043f, 0.040f),
        0.85f, 0.0f, float3(0.0f)};
    return {float3(0.085f, 0.090f, 0.060f)
        * (0.8f + 0.4f * smoothNoise(p.xy * 260.0f)),
        0.95f, 0.0f, float3(0.0f)};
}

// What the pistol mirrors from `origin`: indoors the tiled floor below, dark
// walls around the horizon and a dim ceiling; on the moon earthlit regolith
// under a black sky, brighter by day and under the blue sky while there is
// one. Lamps, the Earth and the sun add their own highlights. `detail` is 0
// on curved edges, where the grout would alias.
// shortcut: the floor is the plane y = 0, so stairs mirror as flat tiles.
float3 pistolSurroundings(float3 origin, float3 direction, bool outside,
    float detail, Daylight sun) {
    if (outside) return regolithBounce(sun) * 0.08f
            * smoothstep(0.04f, -0.04f, direction.y)
        + atmosphereSky(direction, sun)
            * smoothstep(-0.04f, 0.04f, direction.y);
    float3 wall = float3(0.035f, 0.04f, 0.048f);
    if (direction.y >= 0.0f) return mix(wall, float3(0.014f, 0.016f, 0.02f),
        smoothstep(0.0f, 0.5f, direction.y));
    // The floor's grout lines, fading out before they alias.
    float reach = origin.y / -direction.y;
    float2 seam = abs(fract((origin.xz + direction.xz * reach) * 0.7f) - 0.5f);
    float grout = smoothstep(0.465f, 0.49f, max(seam.x, seam.y))
        * (1.0f - smoothstep(4.0f, 9.0f, reach)) * detail;
    return mix(wall, float3(0.15f, 0.135f, 0.125f) * (1.0f - 0.7f * grout),
        smoothstep(-0.02f, -0.25f, direction.y));
}

// The viewmodel is lit by the same lights as the scene it moves through: the
// room lights in the base, the lamps in the haunted house, and the Earth,
// the sun and the lanterns on the moon.
float3 shadeGun(GunHit gun, GunPose pose, float3 muzzleLocal, float3 eye,
    float3 right, float3 up, float3 front, float3 direction,
    ChromePose chrome, device const GameState &game,
    device const float2 *earthShadow, device const float2 *sunShadow) {
    float3 viewPoint = pose.pivot + pose.basis * gun.local;
    float3 viewNormal = pose.basis * gun.normal;
    SceneHit hit = {length(viewPoint), normalize(right * viewNormal.x
            + up * viewNormal.y + front * viewNormal.z),
        eye + right * viewPoint.x + up * viewPoint.y + front * viewPoint.z,
        30u, -1, 0u};
    SurfaceMaterial material = gun.part >= 13u ? handMaterial(gun)
        : (gun.part >= 10u ? launcherMaterial(gun)
            : (gun.part >= 6u ? shotgunMaterial(gun) : gunMaterial(gun)));
    bool inHouse = houseInteriorPoint(eye);
    bool outside = outdoors(eye.xz, 0.0f) && !inHouse;
    Daylight sun = daylight(dayClock(game));
    float3 bounce = regolithBounce(sun);
    float3 color = material.albedo * (1.0f - material.metallic)
            * float3(0.030f, 0.038f, 0.046f)
        + material.albedo * material.metallic
            * (0.05f + 0.07f * saturate(hit.normal.y));
    // The pistol's chrome and glossy polymer mirror their surroundings and
    // a soft glow around each lamp; rougher finishes mirror less.
    bool glossy = gun.part <= 2u;
    float3 mirrored = reflect(direction, hit.normal);
    float3 f0 = mix(float3(0.04f), material.albedo, material.metallic);
    float3 sheen = f0 + (max(float3(1.0f - material.roughness), f0) - f0)
        * pow(1.0f - saturate(dot(hit.normal, -direction)), 5.0f);
    if (glossy)
        color = material.albedo * (1.0f - material.metallic)
                * float3(0.030f, 0.038f, 0.046f)
            + sheen * pistolSurroundings(hit.position, mirrored, outside,
                smoothstep(0.97f, 0.995f, max(abs(gun.normal.x),
                    max(abs(gun.normal.y), abs(gun.normal.z)))), sun);
    if (outside) {
        // Regolith bounces earthshine and sunlight up onto the underside.
        color += material.albedo * bounce * 0.02f
            * saturate(-hit.normal.y);
        color += material.albedo * (1.0f - material.metallic)
            * atmosphereSkyLight(sun) * 0.5f
            * saturate(0.5f + 0.5f * hit.normal.y);
        // The Earth is a broad disc, not a point: its glint on the polished
        // slide spreads instead of burning a white spot. The sun's glint
        // spreads the same way.
        SurfaceMaterial broad = material;
        broad.roughness = max(material.roughness, 0.45f);
        color += shadeDistantLights(hit, broad, -direction, chrome, game,
            earthShadow, sunShadow);
        color += houseOutdoorLighting(hit, material, -direction, chrome, game);
    } else for (uint i = 0u; i < (inHouse ? houseIndoorLightCount : 8u);
        ++i) {
        uint lightRoom = 0u;
        PointLight light = inHouse
            ? houseHauntedIndoorLight(i, game, lightRoom)
            : roomLight(i, game.effects.x);
        if (inHouse)
            light.power *= houseLightShare(lightRoom, houseRoom(eye),
                houseLocal(eye));
        color += shadePointLight(hit, material, -direction, light, chrome,
            game);
        if (glossy) {
            float3 toLight = light.position - hit.position;
            float distanceSquared = dot(toLight, toLight);
            color += sheen * light.color * light.power * 0.25f
                / (4.0f * rangePi * distanceSquared) * exp(16.0f
                    * (dot(mirrored, toLight) * rsqrt(distanceSquared) - 1.0f));
        }
    }
    // The command unit's display glows green while locking and red when
    // the lock is complete.
    if (gun.part == 12u && game.arsenal.w > 0.5f)
        color += seekerLocked(game) ? float3(0.7f, 0.06f, 0.035f)
            : float3(0.05f, 0.32f, 0.08f) * (0.35f + 0.65f * game.launcher.y);
    if (game.view.w > 0.0f) {
        float3 muzzle = pose.pivot + pose.basis
            * (muzzleLocal + float3(0.0f, 0.0f, 0.012f));
        PointLight flash = {eye + right * muzzle.x + up * muzzle.y
            + front * muzzle.z, float3(1.0f, 0.62f, 0.26f),
            3.0f * game.view.w / 0.11f};
        color += shadePointLight(hit, material, -direction, flash, chrome,
            game);
    }
    return color;
}

#include "HauntedBats.metal"

fragment float4 rangeFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    device const float *terrainBounds [[buffer(2)]],
    device const float2 *earthShadow [[buffer(3)]],
    device const float2 *sunShadow [[buffer(4)]],
    device const float4 *signFont [[buffer(5)]],
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
    float focal = 1.1f;
    float3 direction = pixeltje_3d::cameraDirection(in.uv,
        u.resolutionTime.xy, viewYaw, viewPitch, focal);
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
    // The missile's seeker feed cuts in with a narrower lens.
    bool flightCam = flightCamActive(game);
    float lensFocal = flightCam ? 1.6f : mix(focal, 1.45f, reveal);
    if (flightCam) {
        float3 camFront;
        flightCamera(game, origin, camFront);
        direction = pixeltje_3d::cameraDirection(in.uv, u.resolutionTime.xy,
            atan2(camFront.x, -camFront.z),
            asin(clamp(camFront.y, -1.0f, 1.0f)), lensFocal);
    }
    // World width of one pixel per unit of ray distance, for texture filtering.
    float pixelSpread = 1.0f / (u.resolutionTime.y * lensFocal);
    ChromePose chrome = {game.chromeRotation, game.chromeCentre.xyz};
    float3 furPosition = float3(0.0f);
    SceneHit hit = {sceneRayLimit,
        float3(0.0f), float3(0.0f), 0u, -1, 0u};
    traceScene(hit, furPosition, origin, direction, chrome, game,
        terrainBounds);
    traceBats(hit, origin, direction, game);
    float depth = hit.distance;

    SurfaceMaterial material = surfaceMaterial(hit, crateA, crateB,
        furPosition, game.effects.x, direction, pixelSpread * hit.distance);
    bool drone = droneMaterial(hit.material);
    if (drone)
        material = droneSurfaceMaterial(hit.material,
            !droneFlying(game, hit.variant));
    bool bat = batMaterial(hit.material);
    if (bat) material = batSurfaceMaterial(hit.material);
    bool house = houseMaterial(hit.material);
    if (house)
        material = houseSurfaceMaterial(hit, game, game.effects.x,
            pixelSpread * hit.distance, direction, signFont);
    // Room lights stay in the base and the house's lamps in its rooms; the
    // Earth and the lanterns light the shell, the moon, the drones over it,
    // the bats and the outside of the house.
    bool houseIndoors = house && houseInteriorPoint(hit.position);
    bool exterior = hit.material == 40u || hit.material == 41u || drone
        || bat || (house && !houseIndoors);
    // The airless moon has no sky light, only earthshine and sunlight
    // bounced off the plain, which reach slopes, boulder sides and walls more
    // than ground or roofs facing the sky. While there is an atmosphere, its
    // blue sky lights what faces it too, most of all ground and roofs. The
    // house's rooms keep a warm glow.
    Daylight sun = daylight(dayClock(game));
    float3 ambient = exterior
        ? regolithBounce(sun) * (0.004f + 0.045f * (1.0f - hit.normal.y))
            + atmosphereSkyLight(sun) * 0.5f
                * saturate(0.5f + 0.5f * hit.normal.y)
        : (houseIndoors ? float3(0.014f, 0.01f, 0.007f)
            : float3(0.030f, 0.038f, 0.046f));
    float3 color = material.emission
        + material.albedo * (1.0f - material.metallic) * ambient;
    if (drone) color += droneEmission(hit, game);
    if (bat) color += batTranslucency(hit, direction, game);
    if (exterior) {
        color += shadeDistantLights(hit, material, -direction, chrome, game,
            earthShadow, sunShadow);
        color += houseOutdoorLighting(hit, material, -direction, chrome,
            game);
    } else if (houseIndoors) {
        color += houseIndoorLighting(hit, material, -direction, chrome, game);
    } else for (uint i = 0u; i < 8u; ++i) {
        color += shadePointLight(hit, material, -direction,
            roomLight(i, game.effects.x), chrome, game);
    }
    if (hit.material == 0u) {
        float pixelAngle = 1.0f / (lensFocal * u.resolutionTime.y);
        float earth;
        float3 disc = earthDisc(direction, pixelAngle, earth);
        float sunCover;
        disc += sunDisc(direction, pixelAngle, sun, sunCover);
        // Daylight outshines the stars; a sky outshines them until night.
        float daylit = atmosphereOn()
            ? smoothstep(0.0f, 0.1f, atmosphereDay(sun))
            : sun.strength * smoothstep(-0.02f, 0.15f, sun.direction.y);
        float stars = (1.0f - earth) * (1.0f - sunCover) * (1.0f - daylit);
        color = spaceSky(direction, pixelAngle, stars) + disc
            + atmosphereSky(direction, sun);
    }
    color += shadeShotLights(hit, material, -direction, chrome, game);
    color += shadeOrdnanceLights(hit, material, -direction, chrome, game);
    color *= mix(1.0f, houseIndoors ? houseAmbientOcclusion(hit.position)
        : ambientOcclusion(hit, game), 0.85f);
    if (hit.material == 20u) {
        float facing = max(dot(hit.normal, -direction), 0.0f);
        float fresnel = 0.91f + 0.09f * pow(1.0f - facing, 5.0f);
        color += chromeReflection(hit, direction, crateA, crateB,
            chrome, game, pixelSpread)
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
        bool redEyes = blackSpider(SpiderVariant(hit.variant));
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
    if (sentryMaterial(hit.material)) {
        uint sentry = hit.variant;
        color += float3(0.9f, 0.5f, 0.2f)
            * saturate(game.sentryState[sentry].y / 0.2f);
        // An alert sensor burns brighter and pulses while it charges a shot.
        if (hit.material == sentrySensorMaterial)
            color += float3(1.4f, 0.05f, 0.03f)
                * (game.sentryAim[sentry].z > 0.5f ? 1.0f : 0.2f)
                * (game.sentryAim[sentry].w >= 0.0f
                    ? 1.6f + sin(game.effects.x * 40.0f) : 1.0f);
    }
    color = shadeImpacts(color, hit, game, impactTexture, direction,
        pixelSpread * hit.distance);
    color = shadeScorch(color, hit, game);
    // In the white-hot seeker feed, living spiders, active sentries and
    // flying drones glow.
    if (flightCam && (hit.enemy >= 0 || hit.material == sentryArmourMaterial
        || hit.material == sentrySensorMaterial
        || (drone && droneFlying(game, hit.variant))))
        color += float3(0.6f) * max(dot(hit.normal, -direction), 0.25f);
    // There is no haze in vacuum. With an atmosphere, the distance outside
    // fades toward the sky behind it, less as the daylight goes.
    if (!exterior && hit.material != 0u)
        color = mix(color, float3(0.0f), 1.0f - exp(-hit.distance * 0.008f));
    else if (exterior && atmosphereOn())
        color = mix(color, atmosphereSky(normalize(float3(direction.x,
                max(direction.y, 0.02f), direction.z)), sun),
            (1.0f - exp(-hit.distance / 2200.0f)) * atmosphereDay(sun));
    // The house's room windows are real glass: what lies beyond was traced
    // through them, and the pane tints, smears and reflects it.
    float3 paneNormal;
    HouseWindow pane;
    float paneDistance = buildingsGlassCrossing(origin, direction,
        hit.distance, game, paneNormal, pane);
    if (paneDistance > 0.0f)
        color = houseThroughGlass(color, pane, paneNormal, direction,
            origin + direction * paneDistance, houseInteriorPoint(origin));
    color = houseGhostOverlay(color, origin, direction, hit.distance, game);
    // Chimney smoke catches the Earth's and the sun's light, the sky's, and
    // what the plain bounces up.
    float3 smokeLight = (earthColor * 1.4f + sunColor * sunTransmittance(sun)
            * sunIrradiance * sun.strength) / rangePi
        + atmosphereSkyLight(sun) * 0.5f + regolithBounce(sun) * 0.03f;
    color = buildingsSmoke(color, origin, direction, hit.distance, game,
        smokeLight);
    color = shadeGlassBox(color, origin, direction, hit.distance,
        crateA, crateB, chrome, game, pixelSpread);
    color = shadeShot(color, origin, direction, hit.distance, game);
    color = shadeSpiderParticles(color, origin, direction,
        hit.distance, game);
    color = shadeSentryEffects(color, origin, direction, hit.distance, game);
    color = shadeOrdnance(color, origin, direction, hit.distance, game);
    float pixelAngle = 1.0f / (lensFocal * u.resolutionTime.y);
    color = shadeDroneRotors(color, origin, direction, hit.distance, game);
    color = shadeLasers(color, origin, direction, hit.distance, pixelAngle,
        game);
    color = shadeDroneLights(color, origin, direction, hit.distance,
        pixelAngle, game);
    color = shadeDroneSparks(color, origin, direction, hit.distance, game);

    // The held weapon or the hand is drawn over the world, as in any
    // shooter, so a wall in front of the face never swallows it.
    bool holdingGun = reveal <= 0.0f && game.progress.w != phaseLost
        && !flightCam;
    bool shotgun = holdingShotgun(game);
    bool launcher = holdingLauncher(game);
    bool hand = holdingHand(game);
    GunPose gun = heldPose(game);
    float3 elbow = float3(0.0f);
    if (hand) {
        HandPose arm = handPose(game);
        gun = arm.fist;
        elbow = arm.elbow;
    }
    float3 muzzleLocal = launcher ? launcherMuzzle
        : (shotgun ? shotgunLastMuzzle(game) : gunMuzzle);
    float3 viewFront = pixeltje_3d::forward(viewYaw, viewPitch);
    float3 viewRight = normalize(cross(viewFront, float3(0.0f, 1.0f, 0.0f)));
    float3 viewUp = cross(viewRight, viewFront);
    if (holdingGun) {
        float3 viewDirection = float3(dot(direction, viewRight),
            dot(direction, viewUp), dot(direction, viewFront));
        float3x3 toGun = transpose(gun.basis);
        GunHit gunHit = hand
            ? traceHand(toGun * -gun.pivot, toGun * viewDirection, elbow)
            : (launcher
                ? traceLauncher(toGun * -gun.pivot, toGun * viewDirection)
                : (shotgun
                    ? traceShotgun(toGun * -gun.pivot, toGun * viewDirection)
                    : traceGun(toGun * -gun.pivot, toGun * viewDirection,
                        gun.slide)));
        if (gunHit.part != 0u) {
            float3 behind = color;
            color = shadeGun(gunHit, gun, muzzleLocal, eye, viewRight, viewUp,
                viewFront, direction, chrome, game, earthShadow, sunShadow);
            if (hand) color += handSheen(gunHit, gun.basis, viewDirection,
                behind);
            depth = 0.0f;  // the bokeh pass keeps depth 0 sharp
        }
    }
    if (holdingGun && !launcher && !hand && game.view.w > 0.0f) {
        // The flash is drawn in scene light so the bloom pass spreads it.
        float2 pixel = in.uv * u.resolutionTime.xy;
        float2 centre = u.resolutionTime.xy * 0.5f;
        float3 muzzle = gun.pivot + gun.basis
            * (muzzleLocal + float3(0.0f, 0.0f, 0.012f));
        float2 muzzlePixel = centre + float2(muzzle.x, -muzzle.y)
            / muzzle.z * 1.1f * u.resolutionTime.y;
        float2 offset = pixel - muzzlePixel;
        float radius = length(offset) / u.resolutionTime.y;
        float angle = atan2(offset.y, offset.x) + float(game.progress.y) * 1.7f;
        float spikes = pow(abs(cos(angle * 2.5f)), 6.0f);
        // A shotgun barrel throws a wider, longer flash.
        float size = shotgun ? 1.7f : 1.0f;
        float flash = (1.0f - smoothstep(0.0f, 0.022f * size, radius))
            + 0.8f * spikes * (1.0f - smoothstep(0.0f, 0.075f * size, radius))
            + 0.25f * (1.0f - smoothstep(0.0f, 0.12f * size, radius));
        color += float3(1.0f, 0.62f, 0.24f) * flash
            * saturate(game.view.w / (shotgun ? 0.14f : 0.11f)) * 2.5f;
    }
    // Linear scene light before exposure, which the composite pass tone
    // maps, and view distance for the bokeh pass.
    return float4(color, depth);
}

constexpr sampler postSampler(coord::normalized, address::clamp_to_edge,
    filter::linear);

bool effectOn(device const GameState &game, uint effect) {
    return (uint(game.controls.w) & effect) == 0u;
}

// The crosshair pixel and its four neighbours, in steps of 1/300 of the
// frame height: close enough to stay on the aimed-at object, far enough to
// straddle an edge running through the crosshair.
constant int2 focusTaps[5] = {
    int2(0, 0), int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1)};

// Autofocus for the bokeh pass. The lens pulls toward whatever sits under
// the crosshair instead of jumping, so a change of subject reads as a focus
// pull. The nearest of the five taps wins, so an edge under the crosshair
// settles on the nearer object instead of flickering between two, and the
// held weapon (depth 0) never takes focus. The first frame, a restart and
// a long gap focus at once.
kernel void focusLens(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    texture2d<float> scene [[texture(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    int2 size = int2(u.resolutionTime.xy);
    int reach = max(size.y / 300, 1);
    float target = 0.0f;
    for (uint i = 0u; i < 5u; ++i) {
        int2 pixel = clamp(size / 2 + focusTaps[i] * reach, int2(0), size - 1);
        float depth = scene.read(uint2(pixel)).a;
        if (depth > 0.0f && (target <= 0.0f || depth < target)) target = depth;
    }
    if (target <= 0.0f) target = game.lens.x > 0.0f ? game.lens.x : sceneRayLimit;
    float step = game.effects.x - game.lens.y;
    if (game.lens.x <= 0.0f || step < 0.0f || step > 0.5f) {
        game.lens.x = target;
    } else {
        float pull = 1.0f - exp(-step * lensFocusRate);
        game.lens.x = 1.0f / mix(1.0f / game.lens.x, 1.0f / target, pull);
    }
    game.lens.y = game.effects.x;
}

// Depth of field at the distance the autofocus pass left the lens, scaled
// with the frame so card previews match the full-screen view.
fragment float4 bokehFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> scene [[texture(1)]]) {
    float scale = u.resolutionTime.y / 900.0f;
    float aperture = effectOn(states[0], effectBokeh)
        ? lensAperture * scale : 0.0f;
    return pixeltje_postfx::bokeh(scene, in.uv, u.resolutionTime.xy,
        states[0].lens.x, aperture, lensMaxBlur * scale);
}

// Horizontal half of a separable Gaussian over the scene's brightest light.
fragment float4 bloomFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    texture2d<float> scene [[texture(1)]]) {
    float stride = (u.resolutionTime.y / 220.0f) / u.resolutionTime.x;
    return float4(pixeltje_postfx::bloomBlur(scene, in.uv,
        float2(stride, 0.0f), 0.75f), 1.0f);
}

// Edge luma on a soft roll-off of linear light, so edge detection follows
// what the tone-mapped image will show rather than raw HDR brightness.
float antialiasLuma(texture2d<float> scene, float2 uv) {
    float light = dot(scene.sample(postSampler, uv).rgb,
        float3(0.2126f, 0.7152f, 0.0722f));
    return sqrt(light / (1.0f + light));
}

// FXAA-style edge smoothing. The scene is ray-cast once per pixel, so
// geometry edges alias; this finds each edge, walks along it to estimate
// where the pixel sits on the stair step, and resamples across it.
fragment float4 antialiasFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    texture2d<float> scene [[texture(1)]]) {
    float2 texel = 1.0f / u.resolutionTime.xy;
    float4 centre = scene.sample(postSampler, in.uv);
    float lumaM = antialiasLuma(scene, in.uv);
    float lumaN = antialiasLuma(scene, in.uv + float2(0.0f, -texel.y));
    float lumaS = antialiasLuma(scene, in.uv + float2(0.0f, texel.y));
    float lumaW = antialiasLuma(scene, in.uv + float2(-texel.x, 0.0f));
    float lumaE = antialiasLuma(scene, in.uv + float2(texel.x, 0.0f));
    float lumaMax = max(lumaM, max(max(lumaN, lumaS), max(lumaW, lumaE)));
    float range = lumaMax - min(lumaM, min(min(lumaN, lumaS), min(lumaW, lumaE)));
    if (range < max(0.0312f, lumaMax * 0.125f)) return centre;

    float lumaNW = antialiasLuma(scene, in.uv + float2(-texel.x, -texel.y));
    float lumaNE = antialiasLuma(scene, in.uv + float2(texel.x, -texel.y));
    float lumaSW = antialiasLuma(scene, in.uv + float2(-texel.x, texel.y));
    float lumaSE = antialiasLuma(scene, in.uv + float2(texel.x, texel.y));
    bool horizontal = abs(lumaNW + lumaSW - 2.0f * lumaW)
            + 2.0f * abs(lumaN + lumaS - 2.0f * lumaM)
            + abs(lumaNE + lumaSE - 2.0f * lumaE)
        >= abs(lumaNW + lumaNE - 2.0f * lumaN)
            + 2.0f * abs(lumaW + lumaE - 2.0f * lumaM)
            + abs(lumaSW + lumaSE - 2.0f * lumaS);

    // Step toward the neighbour across the edge with the steeper gradient.
    float lumaNegative = horizontal ? lumaN : lumaW;
    float lumaPositive = horizontal ? lumaS : lumaE;
    bool negativeSteeper = abs(lumaNegative - lumaM) >= abs(lumaPositive - lumaM);
    float threshold = 0.25f * max(abs(lumaNegative - lumaM),
        abs(lumaPositive - lumaM));
    float stepLength = horizontal ? texel.y : texel.x;
    float edgeLuma = 0.5f * (lumaM + (negativeSteeper ? lumaNegative : lumaPositive));
    if (negativeSteeper) stepLength = -stepLength;

    // Walk both ways along the edge until its luma departs from the average.
    float2 edgeUV = in.uv + (horizontal ? float2(0.0f, 0.5f * stepLength)
        : float2(0.5f * stepLength, 0.0f));
    float2 along = horizontal ? float2(texel.x, 0.0f) : float2(0.0f, texel.y);
    constexpr float strides[8] = {1.0f, 1.5f, 2.0f, 2.0f, 2.0f, 2.0f, 4.0f, 8.0f};
    float2 uvBack = edgeUV, uvForward = edgeUV;
    float endBack = 0.0f, endForward = 0.0f;
    bool doneBack = false, doneForward = false;
    for (int i = 0; i < 8 && !(doneBack && doneForward); ++i) {
        if (!doneBack) {
            uvBack -= along * strides[i];
            endBack = antialiasLuma(scene, uvBack) - edgeLuma;
            doneBack = abs(endBack) >= threshold;
        }
        if (!doneForward) {
            uvForward += along * strides[i];
            endForward = antialiasLuma(scene, uvForward) - edgeLuma;
            doneForward = abs(endForward) >= threshold;
        }
    }
    float distanceBack = horizontal ? in.uv.x - uvBack.x : in.uv.y - uvBack.y;
    float distanceForward = horizontal ? uvForward.x - in.uv.x
        : uvForward.y - in.uv.y;
    bool backNearer = distanceBack < distanceForward;
    // Only blend when the nearer end turns the same way as this pixel.
    bool matches = ((backNearer ? endBack : endForward) < 0.0f)
        != (lumaM < edgeLuma);
    float edgeOffset = matches ? 0.5f - min(distanceBack, distanceForward)
        / (distanceBack + distanceForward) : 0.0f;

    // Thin features shorter than the walk still get a sub-pixel blend.
    float average = (2.0f * (lumaN + lumaS + lumaW + lumaE)
        + lumaNW + lumaNE + lumaSW + lumaSE) / 12.0f;
    float subpixel = saturate(abs(average - lumaM) / range);
    subpixel = (-2.0f * subpixel + 3.0f) * subpixel * subpixel;
    float offset = max(edgeOffset, 0.75f * subpixel * subpixel);
    float2 resolved = in.uv + (horizontal ? float2(0.0f, offset * stepLength)
        : float2(offset * stepLength, 0.0f));
    return float4(scene.sample(postSampler, resolved).rgb, centre.a);
}

float bossReveal(device const GameState &game) {
    float time = game.bossScene.x;
    return time >= 0.0f && time < 5.0f
        ? smoothstep(1.05f, 1.55f, time) * (1.0f - smoothstep(4.35f, 4.95f, time))
        : 0.0f;
}

// Screen pixel of a world point in the player's steady view; Z is its depth
// along the view and is negative behind the eye.
float3 projectToScreen(device const GameState &game, float2 resolution,
    float3 point) {
    float3 front = pixeltje_3d::forward(game.player.w, game.view.x);
    float3 right = normalize(cross(front, float3(0.0f, 1.0f, 0.0f)));
    float3 up = cross(right, front);
    float3 offset = point - (game.player.xyz + eyeOffset(game));
    float depth = dot(offset, front);
    float2 screen = float2(dot(offset, right), -dot(offset, up))
        / max(depth, 0.001f) * 1.1f * resolution.y;
    return float3(resolution * 0.5f + screen, depth);
}

// A small power bar above a drone or spider: wide and green when full,
// shrinking and reddening as it runs down to nothing. Height is the world
// distance from the centre to the top of the body.
float3 powerBar(float3 color, float2 pixel, device const GameState &game,
    float2 resolution, float3 centre, float height, float power) {
    float3 projected = projectToScreen(game, resolution, centre);
    if (projected.z < 0.5f) return color;
    float lift = height / projected.z * 1.1f * resolution.y + 9.0f;
    float2 q = pixel - projected.xy + float2(20.0f, lift);
    if (q.x < 0.0f || q.x > 40.0f || abs(q.y) > 2.5f) return color;
    return q.x < 40.0f * power
        ? float3(saturate(2.0f - 2.0f * power), saturate(2.0f * power), 0.12f)
        : float3(0.08f, 0.10f, 0.11f);
}

// Bloom, damage fringing, lens vignette and film grain, then the pixel HUD.
fragment float4 compositeFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> scene [[texture(1)]],
    texture2d<float> bloom [[texture(2)]]) {
    device const GameState &game = states[0];
    float reveal = bossReveal(game);
    bool flightCam = flightCamActive(game);
    float hurtFlash = saturate(game.effects.y / 0.35f);
    float lowHealth = game.progress.w == phasePlaying
        ? saturate(1.0f - game.view.y / 35.0f) : 0.0f;
    // Damage fringing stays when the lens fringe is switched off.
    float fringe = 0.007f * hurtFlash + 0.002f * lowHealth
        + (effectOn(game, effectAberration) ? 0.012f : 0.0f);
    float3 color = pixeltje_postfx::chromaticAberration(scene, in.uv, fringe);
    float3 glow = effectOn(game, effectBloom)
        ? pixeltje_postfx::bloomBlur(bloom, in.uv,
            float2(0.0f, 1.0f / 220.0f), 0.0f)
        : float3(0.0f);
    color = pixeltje_3d::filmicToneMap((color + 0.55f * glow) * 1.6f);
    float2 lens = (in.uv - 0.5f) * float2(u.resolutionTime.x / u.resolutionTime.y, 1.0f);
    color *= 1.0f - 0.32f * smoothstep(0.35f, 1.0f, length(lens));
    float2 pixel = in.uv * u.resolutionTime.xy;
    float frame = float(u.frameSeed.x % 3600u);
    float grain = hashTile(floor(pixel) + float2(fmod(frame * 37.3f, 911.0f),
        fmod(frame * 11.7f, 577.0f))) - 0.5f;
    color *= 1.0f + 0.12f * grain;

    // Crosshair, health bar, target pips, and damage feedback.
    float2 centre = u.resolutionTime.xy * 0.5f;
    float2 d = abs(pixel - centre);
    if (flightCam) {
        // White-hot seeker video with scan lines, a centre cross and a
        // track gate.
        float heat = dot(color, float3(0.2126f, 0.7152f, 0.0722f));
        float scan = 0.86f + 0.14f * step(0.5f, fract(pixel.y * 0.5f));
        color = float3(0.80f, 1.0f, 0.84f) * 0.9f * pow(heat, 1.2f) * scan;
        float gate = 0.09f * u.resolutionTime.y;
        bool centreCross = (d.x < 1.0f && d.y > 10.0f && d.y < 34.0f)
            || (d.y < 1.0f && d.x > 10.0f && d.x < 34.0f);
        bool gateLine = (abs(d.x - gate) < 1.2f && d.y > gate * 0.6f
                && d.y < gate + 1.2f)
            || (abs(d.y - gate) < 1.2f && d.x > gate * 0.6f
                && d.x < gate + 1.2f);
        if (centreCross || gateLine) color = float3(0.92f, 1.0f, 0.94f);
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
    if (crosshair && !bossCutscene(game) && !flightCam)
        color = float3(0.9f, 1.0f, 0.95f);
    // With the launcher raised: the seeker's field as corner marks, and
    // brackets that close on the tracked target until the lock completes.
    if (holdingLauncher(game) && armsReady(game) && !flightCam
        && reveal <= 0.0f && game.progress.w == phasePlaying) {
        float field = 0.116f * u.resolutionTime.y;
        bool fieldMark = (abs(d.x - field) < 1.0f && d.y > field * 0.6f
                && d.y < field + 1.0f)
            || (abs(d.y - field) < 1.0f && d.x > field * 0.6f
                && d.x < field + 1.0f);
        if (fieldMark) color = mix(color, float3(0.75f, 0.95f, 0.8f), 0.5f);
        uint target = uint(game.launcher.x);
        if (target != 0u && targetAlive(game, target)) {
            float3 projected = projectToScreen(game, u.resolutionTime.xy,
                targetPoint(game, target));
            if (projected.z > 0.1f) {
                float apparent = targetRadius(game, target) / projected.z
                    * 1.1f * u.resolutionTime.y;
                float size = max(apparent * 1.3f, 16.0f)
                    + 44.0f * (1.0f - game.launcher.y);
                float2 q = abs(pixel - projected.xy);
                float arm = size * 0.45f;
                bool bracket = (abs(q.x - size) < 1.3f && q.y > size - arm
                        && q.y < size + 1.3f)
                    || (abs(q.y - size) < 1.3f && q.x > size - arm
                        && q.x < size + 1.3f);
                if (bracket)
                    color = seekerLocked(game) ? float3(1.0f, 0.2f, 0.12f)
                        : float3(0.9f, 1.0f, 0.92f);
            }
        }
    }
    // Damaged drones and range spiders show a power bar above them. Drones
    // fly outside, so theirs show only there; a spider's shows while it has
    // a clear line to the player. The boss keeps its bar at the top.
    // shortcut: drone bars have no depth test, so one shows through a
    // crater rim; test against the scene depth if that reads wrong.
    if (game.progress.w == phasePlaying && !flightCam && reveal <= 0.0f) {
        if (outdoors(game.player.xz, 0.0f)) {
            for (uint i = 0u; i < droneCount; ++i) {
                float power = game.drones[i].brain.z / droneHealth;
                if (power > 0.0f && power < 1.0f)
                    color = powerBar(color, pixel, game, u.resolutionTime.xy,
                        game.drones[i].pose.xyz, 0.3f, power);
            }
        }
        for (uint i = 0u; i < ordinaryEnemyCount; ++i) {
            float power = game.spiderBar[i];
            if (power <= 0.0f || power >= 1.0f || game.sightLines[i] == 0u)
                continue;
            float scale = spiderTraits(spiderVariantForSlot(i)).scale;
            color = powerBar(color, pixel, game, u.resolutionTime.xy,
                game.enemy[i].xyz, 0.6f * scale, power);
        }
    }
    // Hit marker: white for a body hit, orange for the head, red for a kill.
    float markerRadius = length(d);
    if (game.weapon.z > 0.0f && abs(d.x - d.y) < 1.3f && markerRadius > 7.0f
        && markerRadius < (game.weapon.w > 1.5f ? 19.0f : 15.0f)) {
        color = mix(color, game.weapon.w > 2.5f ? float3(1.0f, 0.18f, 0.12f)
            : (game.weapon.w > 1.5f ? float3(1.0f, 0.62f, 0.18f)
                : float3(1.0f)), saturate(game.weapon.z / 0.12f));
    }
    // Magazine rounds, shotgun shells or rockets at the bottom right, with a
    // bar while reloading. The hand has none.
    if (game.progress.w == phasePlaying && holdingLauncher(game)) {
        float2 corner = u.resolutionTime.xy - float2(28.0f, 28.0f);
        uint rockets = uint(game.arsenal.w + game.arsenal.z + 0.5f);
        for (uint i = 0u; i < rocketLimit; ++i) {
            float right = corner.x - float(i) * 13.0f;
            if (pixel.x > right - 8.0f && pixel.x < right
                && pixel.y > corner.y - 22.0f && pixel.y < corner.y) {
                color = i >= rockets ? float3(0.10f, 0.13f, 0.14f)
                    : (i == 0u && game.arsenal.w > 0.5f
                        ? float3(1.0f, 0.55f, 0.15f)
                        : float3(0.62f, 0.52f, 0.32f));
            }
        }
        float barWidth = float(rocketLimit) * 13.0f - 5.0f;
        if (game.launcher.z > 0.0f && pixel.y > corner.y + 5.0f
            && pixel.y < corner.y + 8.0f && pixel.x < corner.x
            && pixel.x > corner.x - barWidth) {
            color = corner.x - pixel.x > barWidth
                    * (game.launcher.z / launcherReloadDuration)
                ? float3(1.0f, 0.55f, 0.15f) : float3(0.10f, 0.13f, 0.14f);
        }
    } else if (game.progress.w == phasePlaying && holdingShotgun(game)) {
        float2 corner = u.resolutionTime.xy - float2(28.0f, 28.0f);
        for (uint i = 0u; i < 2u; ++i) {
            float right = corner.x - float(i) * 16.0f;
            if (pixel.x > right - 10.0f && pixel.x < right
                && pixel.y > corner.y - 24.0f && pixel.y < corner.y) {
                bool brass = pixel.y > corner.y - 6.0f;
                color = float(i) < game.arms.z
                    ? (brass ? float3(0.85f, 0.66f, 0.30f)
                        : float3(0.78f, 0.10f, 0.06f))
                    : float3(0.10f, 0.13f, 0.14f);
            }
        }
        float barWidth = 26.0f;
        if (game.arms.w > 0.0f && pixel.y > corner.y + 5.0f
            && pixel.y < corner.y + 8.0f && pixel.x < corner.x
            && pixel.x > corner.x - barWidth) {
            color = corner.x - pixel.x > barWidth
                    * (game.arms.w / shotgunReloadDuration)
                ? float3(0.95f, 0.82f, 0.45f) : float3(0.10f, 0.13f, 0.14f);
        }
    } else if (game.progress.w == phasePlaying && !holdingHand(game)) {
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
    for (uint i = 0u; i < sentryCount; ++i) {
        float left = u.resolutionTime.x - 25.0f - float(sentryCount - i) * 23.0f;
        if (pixel.x > left + 2.0f && pixel.x < left + 14.0f
            && pixel.y > 68.0f && pixel.y < 80.0f) {
            color = i < game.pickups.z ? float3(0.98f, 0.71f, 0.19f)
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
        }
    }
    color = clamp(color, float3(0.0f), float3(1.0f));
    float3 srgb = pixeltje_3d::linearToSRGB(color);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

// Text HUD, after Abyssal Treasure: a compute pass lays out shaped runs from
// the system-font buffer, and an instanced pass fills each glyph's outline.
constant uint textHealth = 0u;
constant uint textSpiders = 1u;
constant uint textBossName = 2u;
constant uint textEnraged = 3u;
constant uint textReloading = 4u;
constant uint textGateOpen = 5u;
constant uint textVictory = 6u;
constant uint textRangeClear = 7u;
constant uint textDied = 8u;
constant uint textRestart = 9u;
constant uint textDigitZero = 10u;
constant uint textPistol = 20u;
constant uint textShotgun = 21u;
constant uint textJavelin = 22u;
constant uint textLocking = 23u;
constant uint textLocked = 24u;
constant uint textFlightCam = 25u;
constant uint textTopAttack = 26u;
constant uint textDirect = 27u;
constant uint textSentries = 28u;
constant uint textMedkit = 29u;
constant uint textRockets = 30u;
constant uint textHand = 31u;
constant uint textKnock = 32u;

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
    for (uint i = 0u; i < uint(run.y) && count < hudCapacity; ++i) {
        float4 placement = font[uint(font[0].z) + start + i];
        glyphs[count].geometry = float4(placement.x,
            origin.x + placement.y * size,
            origin.y + (font[2].x - placement.z) * size, size);
        glyphs[count].ink = float4(ink, opacity);
        count += 1u;
    }
}

void addCentered(device HUDGlyph *glyphs, thread uint &count,
    device const float4 *font, uint runID, float centreX, float y,
    float size, float3 ink, float opacity = 1.0f) {
    addRun(glyphs, count, font, runID,
        float2(centreX - runWidth(font, runID, size) * 0.5f, y),
        size, ink, opacity);
}

float numberWidth(device const float4 *font, uint value, float size) {
    float width = 0.0f;
    do {
        width += runWidth(font, textDigitZero + value % 10u, size);
        value /= 10u;
    } while (value > 0u);
    return width;
}

void addNumber(device HUDGlyph *glyphs, thread uint &count,
    device const float4 *font, uint value, float2 origin,
    float size, float3 ink) {
    uint divisor = 1u;
    while (value / divisor >= 10u && divisor < 1000000000u) divisor *= 10u;
    while (divisor > 0u) {
        uint run = textDigitZero + (value / divisor) % 10u;
        addRun(glyphs, count, font, run, origin, size, ink);
        origin.x += runWidth(font, run, size);
        divisor /= 10u;
    }
}

kernel void buildRangeHUD(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device const float4 *font [[buffer(2)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    device HUDGlyph *glyphs = game.hud;
    for (uint i = 0u; i < hudCapacity; ++i) {
        glyphs[i].geometry = float4(0.0f);
        glyphs[i].ink = float4(0.0f);
    }
    if (bossReveal(game) > 0.0f) return;
    float2 size = u.resolutionTime.xy;
    float centreX = size.x * 0.5f;
    uint count = 0u;
    const float3 ink = float3(0.82f, 0.96f, 0.93f);
    const float3 gold = float3(1.0f, 0.78f, 0.34f);
    const float3 danger = float3(1.0f, 0.32f, 0.24f);
    float pulse = 0.65f + 0.35f * sin(game.effects.x * 8.0f);
    uint health = uint(max(game.view.y, 0.0f) + 0.5f);
    addNumber(glyphs, count, font, health, float2(234.0f, 19.0f), 15.0f,
        health < 35u ? danger : ink);
    addRun(glyphs, count, font, textHealth, float2(24.0f, 42.0f), 11.0f, ink);
    addRun(glyphs, count, font, textSpiders,
        float2(size.x - 25.0f - runWidth(font, textSpiders, 11.0f), 45.0f),
        11.0f, ink);
    addRun(glyphs, count, font, textSentries,
        float2(size.x - 25.0f - runWidth(font, textSentries, 11.0f), 86.0f),
        11.0f, ink);
    float centreY = size.y * 0.5f;
    bool flightCam = flightCamActive(game);
    if (game.progress.w == phasePlaying) {
        bool shotgun = holdingShotgun(game);
        bool launcher = holdingLauncher(game);
        bool hand = holdingHand(game);
        uint weaponName = hand ? textHand : (launcher ? textJavelin
            : (shotgun ? textShotgun : textPistol));
        addRun(glyphs, count, font, weaponName,
            float2(size.x - 28.0f - runWidth(font, weaponName, 11.0f),
                size.y - 104.0f), 11.0f, ink, 0.4f + 0.6f * game.arms.y);
        bool reloading = !hand && (launcher ? game.launcher.z > 0.0f
            : (shotgun ? game.arms.w > 0.0f : game.weapon.y > 0.0f));
        if (hand) {
            // A door within reach invites a knock.
            if (game.hand.w > 0.5f && handSwingAge(game) < 0.0f)
                addCentered(glyphs, count, font, textKnock, centreX,
                    centreY + 0.09f * size.y, 12.0f, ink, 0.85f);
        } else if (reloading) {
            addRun(glyphs, count, font, textReloading,
                float2(size.x - 28.0f - runWidth(font, textReloading, 13.0f),
                    size.y - 70.0f), 13.0f, gold, pulse);
        } else {
            uint rounds = launcher
                ? uint(game.arsenal.w + game.arsenal.z + 0.5f)
                : uint(shotgun ? game.arms.z : game.weapon.x);
            addNumber(glyphs, count, font, rounds,
                float2(size.x - 28.0f - numberWidth(font, rounds, 30.0f),
                    size.y - 86.0f), 30.0f,
                rounds <= (launcher || shotgun ? 1u : 3u) ? danger : gold);
        }
        if (launcher) {
            // The flight-cam option, dimmed while it is off.
            addRun(glyphs, count, font, textFlightCam,
                float2(size.x - 28.0f - runWidth(font, textFlightCam, 10.0f),
                    size.y - 120.0f), 10.0f, ink,
                game.controls.y > 0.5f ? 0.85f : 0.3f);
            if (game.launcher.x > 0.5f && !flightCam)
                addCentered(glyphs, count, font,
                    seekerLocked(game) ? textLocked : textLocking, centreX,
                    centreY + 0.13f * size.y, 12.0f,
                    seekerLocked(game) ? danger : ink,
                    seekerLocked(game) ? 1.0f : pulse);
        }
        if (flightCam) {
            addCentered(glyphs, count, font, textFlightCam, centreX, 70.0f,
                14.0f, float3(0.9f, 1.0f, 0.92f));
            addCentered(glyphs, count, font,
                game.missileVelocity.w > 0.5f ? textTopAttack : textDirect,
                centreX, 92.0f, 11.0f, float3(0.9f, 1.0f, 0.92f), 0.8f);
        }
        float sincePickup = game.effects.x - game.dodge.z;
        if (sincePickup >= 0.0f && sincePickup < 1.6f && game.pickups.y > 0u)
            addCentered(glyphs, count, font,
                game.pickups.y == 2u ? textMedkit : textRockets, centreX,
                centreY + 0.2f * size.y, 15.0f,
                game.pickups.y == 2u ? float3(0.5f, 1.0f, 0.6f) : gold,
                1.0f - smoothstep(1.0f, 1.6f, sincePickup));
        // The north gate prompt follows the last range kill.
        float clearedAt = rangeClearedTime(game);
        float sinceGate = clearedAt >= 0.0f ? game.effects.x - clearedAt
            : -1.0f;
        if (sinceGate >= 0.0f && sinceGate < 4.0f && game.bossScene.x < 0.0f)
            addCentered(glyphs, count, font, textGateOpen, centreX, 118.0f,
                18.0f, gold, 1.0f - smoothstep(3.2f, 4.0f, sinceGate));
    }
    if (game.bossScene.x >= 5.0f && game.enemy[bossSlot].w > 0.0f) {
        addCentered(glyphs, count, font, textBossName, centreX, 30.0f,
            14.0f, ink);
        if (bossEnraged(game))
            addCentered(glyphs, count, font, textEnraged, centreX, 70.0f,
                11.0f, danger, pulse);
    }
    if (game.progress.w == phaseWon) {
        addCentered(glyphs, count, font, textVictory, centreX,
            centreY - 52.0f, 34.0f, float3(1.0f));
        addCentered(glyphs, count, font, textRangeClear, centreX,
            centreY + 16.0f, 13.0f, float3(1.0f));
    } else if (game.progress.w == phaseLost) {
        addCentered(glyphs, count, font, textDied, centreX,
            centreY - 52.0f, 34.0f, float3(1.0f));
        addCentered(glyphs, count, font, textRestart, centreX,
            centreY + 16.0f, 13.0f, float3(1.0f), pulse);
    }
}

struct HUDVertex {
    float4 position [[position]];
    float2 local;
    float4 ink;
    uint glyphIndex [[flat]];
    float pixelScale;
};

vertex HUDVertex rangeHUDVertex(uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const float4 *font [[buffer(1)]],
    device const GameState *states [[buffer(2)]]) {
    HUDGlyph instance = states[0].hud[instanceID];
    uint glyph = uint(instance.geometry.x);
    float4 boundsA = font[uint(font[0].x) + glyph * 2u];
    float4 boundsB = font[uint(font[0].x) + glyph * 2u + 1u];
    float pixelScale = max(instance.geometry.w, 1.0f);
    float pad = 1.0f / pixelScale;
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    float2 local = mix(boundsA.zw - pad, boundsB.xy + pad, corners[vertexID]);
    float2 pixel = float2(instance.geometry.y + local.x * instance.geometry.w,
        instance.geometry.z - local.y * instance.geometry.w);
    HUDVertex result;
    // Unused slots and glyphs without outlines, such as spaces, are culled.
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

fragment float4 rangeHUDFragment(HUDVertex in [[stage_in]],
    device const float4 *font [[buffer(1)]]) {
    float4 record = font[uint(font[0].x) + in.glyphIndex * 2u];
    uint start = uint(record.x);
    float nearest = 1000.0f;
    int winding = 0;
    for (uint i = 0u; i < uint(record.y); ++i) {
        float4 segment = font[uint(font[0].w) + start + i];
        float2 a = segment.xy, b = segment.zw, edge = b - a;
        float t = clamp(dot(in.local - a, edge)
            / max(dot(edge, edge), 0.00000001f), 0.0f, 1.0f);
        nearest = min(nearest, length(in.local - (a + t * edge)));
        float crossValue = edge.x * (in.local.y - a.y)
            - edge.y * (in.local.x - a.x);
        if (a.y <= in.local.y && b.y > in.local.y && crossValue > 0.0f)
            winding++;
        else if (b.y <= in.local.y && a.y > in.local.y && crossValue < 0.0f)
            winding--;
    }
    float coverage = clamp(0.5f + (winding != 0 ? nearest : -nearest)
        * in.pixelScale, 0.0f, 1.0f);
    return float4(in.ink.rgb, coverage * in.ink.w);
}

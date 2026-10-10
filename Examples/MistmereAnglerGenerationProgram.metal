#include <metal_stdlib>
using namespace metal;

// Mistmere Angler: a first-person fishing game for the generic GPU Program node.
//
// You stand at the end of a wooden jetty on a misty mountain lake and fish
// through three days (morning, afternoon and the evening rise). Fish swim
// under the surface as dark shapes and give themselves away with rise rings.
// Drag the Trackpad crosshair onto the water to aim, press Action (Space) to
// cast, watch the float and press Action when a fish pulls it under. The
// hooked fish then fights: drag the crosshair up to reel and down to stop
// reeling (the drag lets line out safely), keep the line tight when the fish
// swims towards you, never reel while it runs hard, and hold the rod to the
// side opposite its run to tire it faster. Bring a tired fish to the jetty
// and press Action to net it. Each day has a weight target before dusk.
//
// Passes: initializeLake and advanceLake (one thread: rules, fish, fight,
// camera and the screen-space rod and line), then a single clear-and-replace
// present pass (lakeFragment) that ray-casts the lake, the jetty and the
// generated panorama and draws the HUD. The program needs no swap pair, so
// the engine can encode the present pass together with the tick.
//
// Time: the live preview supplies the wall time between ticks in pointer.w;
// saved and replayed frames use the fixed program step, so they stay
// reproducible. All rates are per second.

constant int fishSlots = 10;
constant int ringSlots = 16;
constant int linePointCount = 12;

// Game phases (flow.x).
constant uint phaseTitle = 0u;
constant uint phaseBriefing = 1u;
constant uint phasePlay = 2u;
constant uint phaseDayDone = 3u;
constant uint phaseDayFailed = 4u;
constant uint phaseVictory = 5u;

// Angler modes during play (flow.z).
constant uint modeAim = 0u;
constant uint modeCast = 1u;
constant uint modeWait = 2u;
constant uint modeFight = 3u;
constant uint modeRetrieve = 4u;
constant uint modeCard = 5u;

// Fish modes (Fish.mind.x).
constant float fishRoam = 0.0f;
constant float fishApproach = 1.0f;
constant float fishNibble = 2.0f;
constant float fishTake = 3.0f;
constant float fishFlee = 4.0f;
constant float fishHooked = 5.0f;
constant float fishGone = 6.0f;

// Fight behaviours (fight1.x).
constant float fightRest = 0.0f;
constant float fightRun = 1.0f;

// Scene geometry in metres: x to the right, y up, z out over the lake.
constant float3 cameraPosition = float3(0.0f, 2.5f, -2.6f);
constant float cameraPitch = -0.12f;      // radians, looking slightly down
constant float tanHalfFov = 0.3839f;      // tan(21 degrees): 42 degree vertical field of view
constant float deckTop = 0.9f;
constant float deckEnd = 0.8f;            // z of the jetty's end beam
constant float deckHalfWidth = 1.1f;
constant float castNear = 4.0f;           // nearest cast target (z)
constant float castFar = 40.0f;           // farthest cast target (z)
constant float maxLine = 75.0f;           // metres of line on the reel
constant float reelSpeed = 2.4f;          // metres per second at full reel
constant float dragLimit = 0.97f;         // tension the drag holds before it slips
constant float panoramaSpan = 1.92f;      // radians of yaw covered by the panorama width
constant float panoramaTop = 0.96f;       // radians of elevation covered above its horizon

struct ProgramUniforms {
    float4 resolutionTime; // width, height, time, fixed step
    uint4 frameSeed;       // frame, seed low, seed high, reserved
    float4 parameters0;    // daySeconds, firstDay, fishPower, horizonLine
    float4 parameters1;    // biteRate, unused, unused, unused
    float4 parameters2;
    float4 parameters3;
    float4 pointer;        // normalized Trackpad X/Y, action count, live frame interval
};

// Seconds simulated by this tick (see the note on time above).
float tickSeconds(constant ProgramUniforms &u) {
    return min(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w, 0.1f);
}

struct Fish {
    float4 pos;   // x, z (metres), heading (radians, 0 = straight out from the jetty), depth (m)
    float4 body;  // species, weight (kg), length (m), tail phase
    float4 mind;  // mode, mode timer (s), goal heading, swim speed (m/s)
    float4 aux;   // wary (s), nibbles left, seconds to next rise, size fraction 0..1
};

// Size: 26 float4/uint4 members (416 bytes) + 6 float4 line points (96 bytes)
// + 16 float4 rings (256 bytes) + 10 Fish of 4 float4 (640 bytes)
// = 1,408 bytes. Every member is 16-byte aligned, so there is no padding.
// The program declares the buffer with 4,096 bytes.
struct GameState {
    uint4 flow;         // phase, day (0-based), angler mode, ticks in the phase
    uint4 counters;     // random state, fish today, fish total, hooked slot (fishSlots = none)
    float4 clock;       // day seconds left, phase seconds, last action count, animation clock
    float4 dayInfo;     // target kg, start hour, end hour, day length (s)
    float4 settings;    // day seconds, first day (0-based), fish power, horizon line
    float4 settings2;   // bite rate, unused, unused, unused
    float4 today;       // kg today, score today, biggest kg today, seconds in mode
    float4 totals;      // kg, score, biggest fish kg, biggest fish species
    float4 dayStart;    // totals when the day began (restored by a retry)
    float4 camera;      // yaw (radians), unused, unused, unused
    float4 aim;         // target x, z, distance (m), valid
    float4 lure;        // x, z, float dip 0..1, state (0 on the rod, 1 flying, 2 in the water)
    float4 flight;      // from x, z, to x, z
    float4 flightInfo;  // progress 0..1, duration (s), arc height (m), baited
    float4 bite;        // owner slot (-1 none), dip target, dip timer (s), unused
    float4 fight0;      // line length (m), tension, stamina 0..1, effort 0..1
    float4 fight1;      // behaviour, behaviour timer, overload seconds, slack seconds
    float4 fight2;      // rod side -1..1, reel rate 0..1, side strain -1..1, net ready
    float4 fight3;      // run heading, shake timer, grace timer, jump progress (-1 none)
    float4 rodTip;      // world x, y, z, bend 0..1
    float4 rodScreen;   // tip uv, butt uv
    float4 bobber;      // uv x, y, radius (px), visible
    float4 lineBox;     // uv bounds of the line: min x, min y, max x, max y
    float4 catchInfo;   // species, weight, points, flags (1 trophy, 2 best of the run)
    float4 message;     // text id (or -1), seconds left, value, priority
    float4 splash;      // x, z, age (s), size
    float4 linePoints[linePointCount / 2]; // fishing line in uv, two points per entry
    float4 rings[ringSlots];               // x, z, age (s), strength
    Fish fish[fishSlots];
};

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

// ---------------------------------------------------------------------------
// Species and days. Index order: perch, trout, carp, pike.

constant float speciesMinKg[4] = {0.15f, 0.5f, 1.8f, 2.5f};
constant float speciesMaxKg[4] = {0.9f, 2.8f, 9.0f, 14.0f};
constant float speciesLengthK[4] = {0.39f, 0.36f, 0.32f, 0.42f};   // length = k * kg^(1/3)
constant float speciesWidth[4] = {0.17f, 0.12f, 0.16f, 0.085f};    // half width / length
constant float speciesPowerMin[4] = {0.32f, 0.45f, 0.55f, 0.60f};
constant float speciesPowerMax[4] = {0.52f, 0.72f, 0.80f, 0.92f};
constant float speciesSpeed[4] = {1.5f, 2.6f, 1.3f, 2.9f};
constant float speciesEnduranceMin[4] = {5.0f, 8.0f, 16.0f, 12.0f};
constant float speciesEnduranceMax[4] = {9.0f, 14.0f, 30.0f, 26.0f};
constant float speciesWindow[4] = {1.1f, 0.9f, 1.4f, 0.8f};       // strike window (s)
constant float speciesNibbles[4] = {2.0f, 1.0f, 4.0f, 0.0f};       // most nibbles before the take
constant float speciesZoneNear[4] = {4.0f, 8.0f, 6.0f, 15.0f};
constant float speciesZoneFar[4] = {17.0f, 30.0f, 30.0f, 40.0f};
constant float speciesSense[4] = {6.0f, 8.0f, 7.0f, 10.0f};        // metres
constant float speciesDepth[4] = {0.5f, 0.6f, 1.2f, 0.9f};
constant float speciesJump[4] = {0.0f, 0.45f, 0.0f, 0.18f};
constant float speciesShake[4] = {0.0f, 0.0f, 0.0f, 0.4f};
constant float speciesCharge[4] = {0.05f, 0.18f, 0.06f, 0.15f};
constant float speciesPointsPerKg[4] = {120.0f, 150.0f, 80.0f, 110.0f};
constant float speciesRise[4] = {18.0f, 7.0f, 26.0f, 30.0f};       // mean seconds between rises

constant float daySpecies[12] = {
    0.62f, 0.38f, 0.0f, 0.0f,   // day 1: misty morning
    0.30f, 0.30f, 0.40f, 0.0f,  // day 2: afternoon calm
    0.18f, 0.30f, 0.20f, 0.32f, // day 3: evening rise
};
constant float dayTarget[3] = {2.5f, 7.0f, 13.0f};
constant float dayStartHour[3] = {6.0f, 11.5f, 16.5f};
constant float dayEndHour[3] = {10.0f, 16.0f, 21.0f};

// ---------------------------------------------------------------------------
// Hashing and random numbers

uint hashUint(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

float hash01(uint x) {
    return float(hashUint(x) >> 8) * (1.0f / 16777216.0f);
}

float hash2(int2 cell, uint seed) {
    uint h = uint(cell.x) * 73856093u ^ uint(cell.y) * 19349663u ^ (seed * 83492791u);
    return hash01(h);
}

float valueNoise(float2 p, uint seed) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 w = f * f * (3.0f - 2.0f * f);
    int2 c = int2(i);
    float a = hash2(c, seed);
    float b = hash2(c + int2(1, 0), seed);
    float c0 = hash2(c + int2(0, 1), seed);
    float d = hash2(c + int2(1, 1), seed);
    return mix(mix(a, b, w.x), mix(c0, d, w.x), w.y);
}

uint nextRandom(thread uint &state) {
    state = state * 1664525u + 1013904223u;
    return hashUint(state);
}

float random01(thread uint &state) {
    return float(nextRandom(state) >> 8) * (1.0f / 16777216.0f);
}

float randomRange(thread uint &state, float low, float high) {
    return low + (high - low) * random01(state);
}

// ---------------------------------------------------------------------------
// Small math helpers

float wrapAngle(float a) {
    float twoPi = 6.2831853f;
    return a - twoPi * floor((a + 3.14159265f) / twoPi);
}

// Turns `from` towards `to` by at most `step` radians.
float turnTowards(float from, float to, float maxStep) {
    float delta = wrapAngle(to - from);
    return from + clamp(delta, -maxStep, maxStep);
}

float2 headingVector(float heading) {
    return float2(sin(heading), cos(heading));
}

float headingOf(float2 v) {
    return atan2(v.x, v.y);
}

float segmentDistance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float len2 = dot(ab, ab);
    float t = len2 > 0.000001f ? clamp(dot(p - a, ab) / len2, 0.0f, 1.0f) : 0.0f;
    return length(p - (a + ab * t));
}

float sdBox(float2 q, float2 halfSize) {
    float2 d = abs(q) - halfSize;
    return length(max(d, float2(0.0f))) + min(max(d.x, d.y), 0.0f);
}

float sdRoundBox(float2 q, float2 halfSize, float radius) {
    return sdBox(q, halfSize - float2(radius)) - radius;
}

// Lateral half-width of the fishable water at distance z from the jetty.
float lakeHalfWidth(float z) {
    return 4.0f + 0.5f * z;
}

// ---------------------------------------------------------------------------
// Camera (shared by the simulation, which projects the rod and line, and the
// present pass, which casts one ray per pixel). Screen uv runs from (0, 0) at
// the top left to (1, 1) at the bottom right, like the Trackpad.

float3 cameraToWorldDirection(float3 c, float yaw) {
    float cp = cos(cameraPitch);
    float sp = sin(cameraPitch);
    float3 d1 = float3(c.x, c.y * cp + c.z * sp, -c.y * sp + c.z * cp);
    float cy = cos(yaw);
    float sy = sin(yaw);
    return float3(d1.x * cy + d1.z * sy, d1.y, -d1.x * sy + d1.z * cy);
}

float3 worldToCamera(float3 world, float yaw) {
    float3 v = world - cameraPosition;
    float cy = cos(yaw);
    float sy = sin(yaw);
    float3 v1 = float3(v.x * cy - v.z * sy, v.y, v.x * sy + v.z * cy);
    float cp = cos(cameraPitch);
    float sp = sin(cameraPitch);
    return float3(v1.x, v1.y * cp - v1.z * sp, v1.y * sp + v1.z * cp);
}

float3 cameraRay(float2 uv, float aspect, float yaw) {
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    float3 c = normalize(float3(ndc.x * aspect * tanHalfFov, ndc.y * tanHalfFov, 1.0f));
    return cameraToWorldDirection(c, yaw);
}

// Camera-space point to screen uv; z must be positive.
float2 cameraToUV(float3 c, float aspect) {
    float z = max(c.z, 0.05f);
    float2 ndc = float2(c.x / (z * aspect * tanHalfFov), c.y / (z * tanHalfFov));
    return float2(0.5f + 0.5f * ndc.x, 0.5f - 0.5f * ndc.y);
}

float2 projectToUV(float3 world, float yaw, float aspect) {
    return cameraToUV(worldToCamera(world, yaw), aspect);
}

// Pixels per metre at camera depth z.
float pixelsPerMetre(float z, float height) {
    return 0.5f * height / (tanHalfFov * max(z, 0.05f));
}

// ---------------------------------------------------------------------------
// Time of day

// Light tint (linear multiplier) for an hour between 5 and 21.
constant float tintHours[7] = {5.5f, 6.6f, 9.0f, 13.0f, 17.0f, 19.6f, 21.0f};
constant float tintR[7] = {0.50f, 1.06f, 1.00f, 1.04f, 1.06f, 1.02f, 0.30f};
constant float tintG[7] = {0.48f, 0.84f, 0.97f, 1.02f, 0.93f, 0.66f, 0.30f};
constant float tintB[7] = {0.62f, 0.70f, 0.92f, 0.99f, 0.78f, 0.48f, 0.46f};

float3 lightTint(float hour) {
    float3 tint = float3(tintR[0], tintG[0], tintB[0]);
    for (int i = 0; i < 6; ++i) {
        float a = tintHours[i];
        float b = tintHours[i + 1];
        if (hour >= a) {
            float t = clamp((hour - a) / (b - a), 0.0f, 1.0f);
            t = t * t * (3.0f - 2.0f * t);
            tint = mix(float3(tintR[i], tintG[i], tintB[i]),
                float3(tintR[i + 1], tintG[i + 1], tintB[i + 1]), t);
        }
    }
    return tint;
}

float mistAmount(float hour) {
    float morning = 1.0f - smoothstep(5.5f, 10.5f, hour);
    float evening = smoothstep(18.0f, 21.0f, hour);
    return 0.15f + 0.6f * morning + 0.3f * evening;
}

// Fish feed most at dawn and in the evening rise.
float fishActivity(float hour) {
    float dawn = exp(-(hour - 6.5f) * (hour - 6.5f) / 4.0f);
    float rise = exp(-(hour - 19.5f) * (hour - 19.5f) / 4.0f);
    return 0.8f + 0.6f * dawn + 0.7f * rise;
}

float currentHour(device const GameState &game) {
    float span = max(game.dayInfo.w, 1.0f);
    float progress = clamp(1.0f - game.clock.x / span, 0.0f, 1.0f);
    return mix(game.dayInfo.y, game.dayInfo.z, progress);
}

// ---------------------------------------------------------------------------
// Text

// 5 x 7 dot font for ASCII 32 (space) to 90 (Z); bit 4 is the leftmost dot.
constant uchar fontRows[413] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ' '
    0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04,  // '!'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '"'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '#'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '$'
    0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03,  // '%'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '&'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // "'"
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '('
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ')'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '*'
    0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00,  // '+'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ','
    0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00,  // '-'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C,  // '.'
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x00,  // '/'
    0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E,  // '0'
    0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E,  // '1'
    0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F,  // '2'
    0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E,  // '3'
    0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02,  // '4'
    0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E,  // '5'
    0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E,  // '6'
    0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08,  // '7'
    0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E,  // '8'
    0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C,  // '9'
    0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00,  // ':'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ';'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '<'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '='
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '>'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '?'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '@'
    0x0E, 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11,  // 'A'
    0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E,  // 'B'
    0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E,  // 'C'
    0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C,  // 'D'
    0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F,  // 'E'
    0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10,  // 'F'
    0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F,  // 'G'
    0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11,  // 'H'
    0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E,  // 'I'
    0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C,  // 'J'
    0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11,  // 'K'
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F,  // 'L'
    0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11,  // 'M'
    0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11,  // 'N'
    0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E,  // 'O'
    0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10,  // 'P'
    0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D,  // 'Q'
    0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11,  // 'R'
    0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E,  // 'S'
    0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,  // 'T'
    0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E,  // 'U'
    0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04,  // 'V'
    0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A,  // 'W'
    0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11,  // 'X'
    0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04,  // 'Y'
    0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F,  // 'Z'
};

// Every on-screen message as ASCII codes; textRanges holds start, length.
constant uchar textPool[1437] = {
    77, 73, 83, 84, 77, 69, 82, 69, 32, 65, 78, 71, 76, 69, 82, 84,
    72, 82, 69, 69, 32, 68, 65, 89, 83, 32, 79, 78, 32, 65, 32, 77,
    73, 83, 84, 89, 32, 77, 79, 85, 78, 84, 65, 73, 78, 32, 76, 65,
    75, 69, 68, 82, 65, 71, 32, 79, 78, 84, 79, 32, 84, 72, 69, 32,
    87, 65, 84, 69, 82, 32, 84, 79, 32, 65, 73, 77, 32, 45, 32, 83,
    80, 65, 67, 69, 32, 84, 79, 32, 67, 65, 83, 84, 83, 84, 82, 73,
    75, 69, 32, 87, 73, 84, 72, 32, 83, 80, 65, 67, 69, 32, 87, 72,
    69, 78, 32, 84, 72, 69, 32, 70, 76, 79, 65, 84, 32, 71, 79, 69,
    83, 32, 85, 78, 68, 69, 82, 68, 82, 65, 71, 32, 85, 80, 32, 84,
    79, 32, 82, 69, 69, 76, 32, 45, 32, 68, 82, 65, 71, 32, 68, 79,
    87, 78, 32, 84, 79, 32, 72, 79, 76, 68, 78, 69, 86, 69, 82, 32,
    82, 69, 69, 76, 32, 87, 72, 73, 76, 69, 32, 84, 72, 69, 32, 70,
    73, 83, 72, 32, 82, 85, 78, 83, 32, 72, 65, 82, 68, 82, 69, 69,
    76, 32, 73, 78, 32, 84, 72, 69, 32, 83, 76, 65, 67, 75, 32, 87,
    72, 69, 78, 32, 73, 84, 32, 83, 87, 73, 77, 83, 32, 84, 79, 87,
    65, 82, 68, 83, 32, 89, 79, 85, 72, 79, 76, 68, 32, 84, 72, 69,
    32, 82, 79, 68, 32, 65, 87, 65, 89, 32, 70, 82, 79, 77, 32, 73,
    84, 83, 32, 82, 85, 78, 32, 84, 79, 32, 84, 73, 82, 69, 32, 73,
    84, 78, 69, 84, 32, 65, 32, 84, 73, 82, 69, 68, 32, 70, 73, 83,
    72, 32, 65, 84, 32, 84, 72, 69, 32, 74, 69, 84, 84, 89, 32, 87,
    73, 84, 72, 32, 83, 80, 65, 67, 69, 80, 82, 69, 83, 83, 32, 83,
    80, 65, 67, 69, 32, 84, 79, 32, 83, 84, 65, 82, 84, 68, 65, 89,
    77, 73, 83, 84, 89, 32, 77, 79, 82, 78, 73, 78, 71, 65, 70, 84,
    69, 82, 78, 79, 79, 78, 32, 67, 65, 76, 77, 84, 72, 69, 32, 69,
    86, 69, 78, 73, 78, 71, 32, 82, 73, 83, 69, 80, 69, 82, 67, 72,
    32, 65, 78, 68, 32, 84, 82, 79, 85, 84, 32, 70, 69, 69, 68, 32,
    73, 78, 32, 84, 72, 69, 32, 68, 65, 87, 78, 32, 77, 73, 83, 84,
    66, 73, 71, 32, 67, 65, 82, 80, 32, 67, 82, 85, 73, 83, 69, 32,
    84, 72, 82, 79, 85, 71, 72, 32, 84, 72, 69, 32, 87, 65, 82, 77,
    32, 87, 65, 84, 69, 82, 80, 73, 75, 69, 32, 72, 85, 78, 84, 32,
    70, 65, 82, 32, 79, 85, 84, 32, 65, 83, 32, 84, 72, 69, 32, 83,
    85, 78, 32, 71, 79, 69, 83, 32, 68, 79, 87, 78, 76, 65, 78, 68,
    75, 71, 32, 79, 70, 32, 70, 73, 83, 72, 32, 66, 69, 70, 79, 82,
    69, 73, 78, 32, 84, 72, 69, 32, 76, 65, 75, 69, 58, 80, 82, 69,
    83, 83, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 83, 84, 65, 82,
    84, 32, 70, 73, 83, 72, 73, 78, 71, 80, 69, 82, 67, 72, 66, 82,
    79, 87, 78, 32, 84, 82, 79, 85, 84, 67, 79, 77, 77, 79, 78, 32,
    67, 65, 82, 80, 78, 79, 82, 84, 72, 69, 82, 78, 32, 80, 73, 75,
    69, 67, 65, 84, 67, 72, 75, 71, 83, 67, 79, 82, 69, 70, 73, 83,
    72, 84, 69, 78, 83, 73, 79, 78, 70, 73, 83, 72, 32, 83, 84, 82,
    69, 78, 71, 84, 72, 76, 73, 78, 69, 77, 82, 69, 69, 76, 72, 79,
    76, 68, 83, 73, 68, 69, 32, 83, 84, 82, 65, 73, 78, 33, 69, 65,
    83, 69, 32, 79, 70, 70, 33, 68, 82, 65, 71, 32, 84, 79, 32, 65,
    73, 77, 32, 45, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 67, 65,
    83, 84, 87, 65, 84, 67, 72, 32, 84, 72, 69, 32, 70, 76, 79, 65,
    84, 32, 45, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 83, 84, 82,
    73, 75, 69, 32, 79, 82, 32, 82, 69, 69, 76, 32, 73, 78, 68, 82,
    65, 71, 32, 85, 80, 32, 84, 79, 32, 82, 69, 69, 76, 32, 45, 32,
    68, 79, 87, 78, 32, 84, 79, 32, 72, 79, 76, 68, 32, 45, 32, 83,
    73, 68, 69, 87, 65, 89, 83, 32, 84, 79, 32, 83, 84, 69, 69, 82,
    32, 84, 72, 69, 32, 82, 79, 68, 80, 82, 69, 83, 83, 32, 83, 80,
    65, 67, 69, 32, 84, 79, 32, 78, 69, 84, 32, 84, 72, 69, 32, 70,
    73, 83, 72, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 84,
    79, 32, 75, 69, 69, 80, 32, 70, 73, 83, 72, 73, 78, 71, 70, 73,
    83, 72, 32, 79, 78, 33, 84, 79, 79, 32, 69, 65, 82, 76, 89, 32,
    45, 32, 89, 79, 85, 32, 83, 80, 79, 79, 75, 69, 68, 32, 73, 84,
    84, 79, 79, 32, 76, 65, 84, 69, 32, 45, 32, 73, 84, 32, 76, 69,
    84, 32, 71, 79, 66, 65, 73, 84, 32, 83, 84, 79, 76, 69, 78, 32,
    45, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 82, 69, 69, 76, 32,
    73, 78, 84, 72, 69, 32, 76, 73, 78, 69, 32, 83, 78, 65, 80, 80,
    69, 68, 33, 83, 76, 65, 67, 75, 32, 76, 73, 78, 69, 32, 45, 32,
    84, 72, 69, 32, 72, 79, 79, 75, 32, 67, 65, 77, 69, 32, 76, 79,
    79, 83, 69, 73, 84, 32, 84, 79, 79, 75, 32, 65, 76, 76, 32, 89,
    79, 85, 82, 32, 76, 73, 78, 69, 33, 84, 79, 79, 32, 76, 73, 86,
    69, 76, 89, 32, 45, 32, 84, 73, 82, 69, 32, 73, 84, 32, 79, 85,
    84, 32, 70, 73, 82, 83, 84, 66, 82, 73, 78, 71, 32, 73, 84, 32,
    67, 76, 79, 83, 69, 82, 32, 84, 79, 32, 84, 72, 69, 32, 74, 69,
    84, 84, 89, 84, 65, 82, 71, 69, 84, 32, 82, 69, 65, 67, 72, 69,
    68, 32, 45, 32, 70, 73, 83, 72, 32, 79, 78, 32, 70, 79, 82, 32,
    80, 79, 73, 78, 84, 83, 76, 65, 83, 84, 32, 67, 65, 83, 84, 83,
    32, 79, 70, 32, 84, 72, 69, 32, 68, 65, 89, 84, 82, 79, 80, 72,
    89, 32, 70, 73, 83, 72, 33, 66, 73, 71, 71, 69, 83, 84, 32, 79,
    70, 32, 84, 72, 69, 32, 84, 82, 73, 80, 80, 79, 73, 78, 84, 83,
    43, 68, 65, 89, 32, 67, 79, 77, 80, 76, 69, 84, 69, 84, 72, 69,
    32, 68, 65, 89, 32, 73, 83, 32, 79, 86, 69, 82, 70, 73, 83, 72,
    32, 67, 65, 85, 71, 72, 84, 87, 69, 73, 71, 72, 84, 66, 73, 71,
    71, 69, 83, 84, 32, 70, 73, 83, 72, 89, 79, 85, 32, 78, 69, 69,
    68, 69, 68, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 70,
    79, 82, 32, 84, 72, 69, 32, 78, 69, 88, 84, 32, 68, 65, 89, 80,
    82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 84, 82,
    89, 32, 84, 72, 69, 32, 68, 65, 89, 32, 65, 71, 65, 73, 78, 87,
    72, 65, 84, 32, 65, 32, 70, 73, 83, 72, 73, 78, 71, 32, 84, 82,
    73, 80, 33, 70, 73, 78, 65, 76, 32, 83, 67, 79, 82, 69, 84, 82,
    73, 80, 32, 87, 69, 73, 71, 72, 84, 82, 65, 78, 75, 87, 69, 69,
    75, 69, 78, 68, 32, 65, 78, 71, 76, 69, 82, 83, 69, 65, 83, 79,
    78, 69, 68, 32, 65, 78, 71, 76, 69, 82, 76, 65, 75, 69, 32, 76,
    69, 71, 69, 78, 68, 77, 65, 83, 84, 69, 82, 32, 79, 70, 32, 77,
    73, 83, 84, 77, 69, 82, 69, 80, 82, 69, 83, 83, 32, 83, 80, 65,
    67, 69, 32, 84, 79, 32, 70, 73, 83, 72, 32, 65, 71, 65, 73, 78,
    78, 79, 78, 69, 79, 70, 78, 69, 84, 32, 73, 84, 33,
};
constant int textRanges[154] = {
    0, 15,  // MISTMERE ANGLER
    15, 35,  // THREE DAYS ON A MISTY MOUNTAIN LAKE
    50, 42,  // DRAG ONTO THE WATER TO AIM - SPACE TO CAST
    92, 43,  // STRIKE WITH SPACE WHEN THE FLOAT GOES UNDER
    135, 35,  // DRAG UP TO REEL - DRAG DOWN TO HOLD
    170, 35,  // NEVER REEL WHILE THE FISH RUNS HARD
    205, 43,  // REEL IN THE SLACK WHEN IT SWIMS TOWARDS YOU
    248, 41,  // HOLD THE ROD AWAY FROM ITS RUN TO TIRE IT
    289, 40,  // NET A TIRED FISH AT THE JETTY WITH SPACE
    329, 20,  // PRESS SPACE TO START
    349, 3,  // DAY
    352, 13,  // MISTY MORNING
    365, 14,  // AFTERNOON CALM
    379, 16,  // THE EVENING RISE
    395, 37,  // PERCH AND TROUT FEED IN THE DAWN MIST
    432, 38,  // BIG CARP CRUISE THROUGH THE WARM WATER
    470, 38,  // PIKE HUNT FAR OUT AS THE SUN GOES DOWN
    508, 4,  // LAND
    512, 17,  // KG OF FISH BEFORE
    529, 12,  // IN THE LAKE:
    541, 28,  // PRESS SPACE TO START FISHING
    569, 5,  // PERCH
    574, 11,  // BROWN TROUT
    585, 11,  // COMMON CARP
    596, 13,  // NORTHERN PIKE
    609, 5,  // CATCH
    614, 2,  // KG
    616, 5,  // SCORE
    621, 4,  // FISH
    625, 7,  // TENSION
    632, 13,  // FISH STRENGTH
    645, 4,  // LINE
    649, 1,  // M
    650, 4,  // REEL
    654, 4,  // HOLD
    658, 12,  // SIDE STRAIN!
    670, 9,  // EASE OFF!
    679, 27,  // DRAG TO AIM - SPACE TO CAST
    706, 44,  // WATCH THE FLOAT - SPACE TO STRIKE OR REEL IN
    750, 58,  // DRAG UP TO REEL - DOWN TO HOLD - SIDEWAYS TO STEER THE ROD
    808, 27,  // PRESS SPACE TO NET THE FISH
    835, 27,  // PRESS SPACE TO KEEP FISHING
    862, 8,  // FISH ON!
    870, 26,  // TOO EARLY - YOU SPOOKED IT
    896, 20,  // TOO LATE - IT LET GO
    916, 30,  // BAIT STOLEN - SPACE TO REEL IN
    946, 17,  // THE LINE SNAPPED!
    963, 32,  // SLACK LINE - THE HOOK CAME LOOSE
    995, 22,  // IT TOOK ALL YOUR LINE!
    1017, 30,  // TOO LIVELY - TIRE IT OUT FIRST
    1047, 28,  // BRING IT CLOSER TO THE JETTY
    1075, 35,  // TARGET REACHED - FISH ON FOR POINTS
    1110, 21,  // LAST CASTS OF THE DAY
    1131, 12,  // TROPHY FISH!
    1143, 19,  // BIGGEST OF THE TRIP
    1162, 6,  // POINTS
    1168, 1,  // +
    1169, 12,  // DAY COMPLETE
    1181, 15,  // THE DAY IS OVER
    1196, 11,  // FISH CAUGHT
    1207, 6,  // WEIGHT
    1213, 12,  // BIGGEST FISH
    1225, 10,  // YOU NEEDED
    1235, 28,  // PRESS SPACE FOR THE NEXT DAY
    1263, 32,  // PRESS SPACE TO TRY THE DAY AGAIN
    1295, 20,  // WHAT A FISHING TRIP!
    1315, 11,  // FINAL SCORE
    1326, 11,  // TRIP WEIGHT
    1337, 4,  // RANK
    1341, 14,  // WEEKEND ANGLER
    1355, 15,  // SEASONED ANGLER
    1370, 11,  // LAKE LEGEND
    1381, 18,  // MASTER OF MISTMERE
    1399, 25,  // PRESS SPACE TO FISH AGAIN
    1424, 4,  // NONE
    1428, 2,  // OF
    1430, 7,  // NET IT!
};
constant int textTitle = 0;
constant int textSubtitle = 1;
constant int textHow1 = 2;
constant int textHow2 = 3;
constant int textHow3 = 4;
constant int textHow4 = 5;
constant int textHow5 = 6;
constant int textHow6 = 7;
constant int textHow7 = 8;
constant int textPressStart = 9;
constant int textDay = 10;
constant int textDay1 = 11;
constant int textDay2 = 12;
constant int textDay3 = 13;
constant int textBrief1 = 14;
constant int textBrief2 = 15;
constant int textBrief3 = 16;
constant int textLand = 17;
constant int textKgBefore = 18;
constant int textInLake = 19;
constant int textPressFish = 20;
constant int textPerch = 21;
constant int textTrout = 22;
constant int textCarp = 23;
constant int textPike = 24;
constant int textCatch = 25;
constant int textKg = 26;
constant int textScore = 27;
constant int textFish = 28;
constant int textTension = 29;
constant int textStrength = 30;
constant int textLine = 31;
constant int textM = 32;
constant int textReel = 33;
constant int textHold = 34;
constant int textSideStrain = 35;
constant int textEaseOff = 36;
constant int textHintAim = 37;
constant int textHintWait = 38;
constant int textHintFight = 39;
constant int textHintNet = 40;
constant int textHintCard = 41;
constant int textFishOn = 42;
constant int textTooEarly = 43;
constant int textMissed = 44;
constant int textBaitStolen = 45;
constant int textSnapped = 46;
constant int textLoose = 47;
constant int textSpooled = 48;
constant int textTooLively = 49;
constant int textCloser = 50;
constant int textTargetReached = 51;
constant int textLastCasts = 52;
constant int textTrophy = 53;
constant int textBest = 54;
constant int textPoints = 55;
constant int textPlus = 56;
constant int textDayComplete = 57;
constant int textDayOver = 58;
constant int textFishCaught = 59;
constant int textWeight = 60;
constant int textBiggest = 61;
constant int textNeeded = 62;
constant int textNextDay = 63;
constant int textRetry = 64;
constant int textVictory = 65;
constant int textFinalScore = 66;
constant int textTripWeight = 67;
constant int textRank = 68;
constant int textRank1 = 69;
constant int textRank2 = 70;
constant int textRank3 = 71;
constant int textRank4 = 72;
constant int textAgain = 73;
constant int textNone = 74;
constant int textOf = 75;
constant int textNet = 76;

// ---------------------------------------------------------------------------
// Rules: settings, days, fish, casting, bites and the fight

float4 readSettings(constant ProgramUniforms &u) {
    float daySeconds = u.parameters0.x > 0.0f ? clamp(u.parameters0.x, 45.0f, 900.0f) : 180.0f;
    float firstDay = u.parameters0.y > 0.0f ? clamp(floor(u.parameters0.y + 0.5f), 1.0f, 3.0f) - 1.0f : 0.0f;
    float fishPower = u.parameters0.z > 0.0f ? clamp(u.parameters0.z, 0.5f, 1.5f) : 1.0f;
    float horizon = u.parameters0.w > 0.0f ? clamp(u.parameters0.w, 0.25f, 0.8f) : 0.5f;
    return float4(daySeconds, firstDay, fishPower, horizon);
}

float4 readSettings2(constant ProgramUniforms &u) {
    float biteRate = u.parameters1.x > 0.0f ? clamp(u.parameters1.x, 0.3f, 3.0f) : 1.0f;
    return float4(biteRate, 0.0f, 0.0f, 0.0f);
}

void setMessage(device GameState &game, int text, float seconds, float value, float priority) {
    if (game.message.y > 0.0f && game.message.w > priority) return;
    game.message = float4(float(text), seconds, value, priority);
}

void addRing(device GameState &game, float2 at, float strength) {
    int slot = 0;
    float oldest = -1.0f;
    for (int i = 0; i < ringSlots; ++i) {
        if (game.rings[i].z > oldest) {
            oldest = game.rings[i].z;
            slot = i;
        }
    }
    game.rings[slot] = float4(at, 0.0f, strength);
}

int pickSpecies(uint day, thread uint &rng) {
    float r = random01(rng);
    float total = 0.0f;
    for (int s = 0; s < 4; ++s) {
        total += daySpecies[day * 4u + uint(s)];
        if (r < total) return s;
    }
    return 0;
}

void spawnFish(device Fish &f, int species, thread uint &rng, float2 avoid) {
    float sizeFrac = pow(random01(rng), 1.6f);
    float kg = mix(speciesMinKg[species], speciesMaxKg[species], sizeFrac);
    kg = floor(kg * 100.0f + 0.5f) / 100.0f;
    float2 p = float2(0.0f);
    for (int attempt = 0; attempt < 4; ++attempt) {
        float z = randomRange(rng, speciesZoneNear[species], speciesZoneFar[species]);
        p = float2(randomRange(rng, -0.9f, 0.9f) * lakeHalfWidth(z), z);
        if (distance(p, avoid) > 7.0f) break;
    }
    float heading = randomRange(rng, -3.14159f, 3.14159f);
    f.pos = float4(p, heading, speciesDepth[species]);
    f.body = float4(float(species), kg, speciesLengthK[species] * pow(kg, 1.0f / 3.0f),
        randomRange(rng, 0.0f, 6.28f));
    f.mind = float4(fishRoam, randomRange(rng, 1.0f, 4.0f), heading, randomRange(rng, 0.2f, 0.5f));
    f.aux = float4(0.0f, 0.0f, speciesRise[species] * randomRange(rng, 0.2f, 1.0f), sizeFrac);
}

void resetFight(device GameState &game) {
    game.fight0 = float4(0.0f, 0.0f, 1.0f, 0.0f);
    game.fight1 = float4(fightRest, 0.0f, 0.0f, 0.0f);
    game.fight2 = float4(0.0f, 0.0f, 0.0f, 0.0f);
    game.fight3 = float4(0.0f, 0.0f, 0.0f, -1.0f);
    game.counters.w = uint(fishSlots);
}

void startDay(device GameState &game, uint day, thread uint &rng) {
    day = min(day, 2u);
    game.flow = uint4(phaseBriefing, day, modeAim, 0u);
    game.dayInfo = float4(dayTarget[day], dayStartHour[day], dayEndHour[day], game.settings.x);
    game.clock.x = game.settings.x;
    game.clock.y = 0.0f;
    game.today = float4(0.0f);
    game.dayStart = game.totals;
    game.counters.y = 0u;
    game.aim = float4(0.0f, 14.0f, 14.0f, 0.0f);
    game.lure = float4(0.0f, 1.0f, 0.0f, 0.0f);
    game.flightInfo = float4(0.0f, 1.0f, 0.0f, 1.0f);
    game.bite = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    game.catchInfo = float4(0.0f);
    game.message = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    game.splash = float4(0.0f, 0.0f, 99.0f, 0.0f);
    resetFight(game);
    for (int i = 0; i < ringSlots; ++i) game.rings[i] = float4(0.0f, 0.0f, 99.0f, 0.0f);
    for (int i = 0; i < fishSlots; ++i) {
        spawnFish(game.fish[i], pickSpecies(day, rng), rng, float2(0.0f, -50.0f));
    }
}

void setPhase(device GameState &game, uint phase) {
    game.flow.x = phase;
    game.flow.w = 0u;
    game.clock.y = 0.0f;
}

void setMode(device GameState &game, uint mode) {
    game.flow.z = mode;
    game.today.w = 0.0f;
}

// Cast target on the water under the pointer (x, z, distance from the rod tip, valid).
float4 aimFromPointer(float2 pointer, float aspect, float yaw, float2 tip) {
    float3 d = cameraRay(pointer, aspect, yaw);
    float2 origin = float2(cameraPosition.x, cameraPosition.z);
    float2 target;
    if (d.y < -0.001f) {
        float t = -cameraPosition.y / d.y;
        target = origin + float2(d.x, d.z) * t;
    } else {
        target = origin + normalize(float2(d.x, d.z) + float2(0.0f, 0.0001f)) * 200.0f;
    }
    float2 offset = target - origin;
    if (target.y > castFar) target = origin + offset * ((castFar - origin.y) / max(offset.y, 0.001f));
    offset = target - origin;
    if (target.y < castNear) target = origin + offset * ((castNear - origin.y) / max(offset.y, 0.001f));
    float halfWidth = lakeHalfWidth(target.y);
    target.x = clamp(target.x, -halfWidth, halfWidth);
    return float4(target, distance(target, tip), 1.0f);
}

void startCast(device GameState &game, thread uint &rng) {
    float2 tip = game.rodTip.xz;
    float2 target = game.aim.xy;
    float dist = distance(target, tip);
    float scatter = 0.035f * dist;
    float angle = randomRange(rng, 0.0f, 6.2831853f);
    target += float2(cos(angle), sin(angle)) * scatter * sqrt(random01(rng));
    target.y = clamp(target.y, castNear - 0.5f, castFar + 1.0f);
    game.flight = float4(tip, target);
    game.flightInfo = float4(0.0f, 0.45f + dist / 45.0f, 1.2f + dist * 0.16f, 1.0f);
    game.lure = float4(tip, 0.0f, 1.0f);
    game.bite = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    setMode(game, modeCast);
}

void landLure(device GameState &game, thread uint &rng) {
    float2 at = game.flight.zw;
    game.lure = float4(at, 0.0f, 2.0f);
    addRing(game, at, 1.0f);
    game.splash = float4(at, 0.0f, 0.8f);
    for (int i = 0; i < fishSlots; ++i) {
        device Fish &f = game.fish[i];
        if (f.mind.x == fishGone || f.mind.x == fishHooked) continue;
        float d = distance(f.pos.xy, at);
        if (d < 1.6f) {
            // A lure landing on a fish's head scares it.
            f.mind = float4(fishFlee, 1.5f, f.mind.z, 1.8f);
            f.aux.x = 4.0f;
        } else if (d < 5.0f && f.aux.x <= 0.0f && f.mind.x == fishRoam) {
            // Nearby fish turn to look at the splash.
            f.mind.z = headingOf(at - f.pos.xy);
            f.mind.y = randomRange(rng, 1.0f, 2.5f);
        }
    }
    setMode(game, modeWait);
}

void startRetrieve(device GameState &game) {
    int owner = int(game.bite.x);
    if (owner >= 0 && owner < fishSlots) {
        device Fish &f = game.fish[owner];
        if (f.mind.x == fishApproach || f.mind.x == fishNibble || f.mind.x == fishTake) {
            f.mind.x = fishRoam;
            f.mind.y = 1.0f;
        }
    }
    game.bite = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    game.lure.w = 2.0f;
    setMode(game, modeRetrieve);
}

void scareNear(device GameState &game, float2 at, float radius, float seconds) {
    for (int i = 0; i < fishSlots; ++i) {
        device Fish &f = game.fish[i];
        if (f.mind.x == fishGone || f.mind.x == fishHooked) continue;
        if (distance(f.pos.xy, at) < radius) f.aux.x = max(f.aux.x, seconds);
    }
}

void hookFish(device GameState &game, int slot, thread uint &rng) {
    device Fish &f = game.fish[slot];
    float2 tip = game.rodTip.xz;
    float2 rel = f.pos.xy - tip;
    float runHeading = headingOf(rel) + randomRange(rng, -0.9f, 0.9f);
    f.mind.x = fishHooked;
    f.pos.z = runHeading;
    f.pos.w = 0.35f;
    game.counters.w = uint(slot);
    game.fight0 = float4(length(rel) + 0.3f, 0.35f, 1.0f, 1.0f);
    game.fight1 = float4(fightRun, randomRange(rng, 1.2f, 2.2f), 0.0f, 0.0f);
    game.fight2.z = 0.0f;
    game.fight2.w = 0.0f;
    game.fight3 = float4(runHeading, 0.0f, 1.3f, -1.0f);
    game.bite = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    game.lure.z = 1.0f;
    addRing(game, f.pos.xy, 1.0f);
    game.splash = float4(f.pos.xy, 0.0f, 1.0f);
    setMessage(game, textFishOn, 1.6f, 0.0f, 2.0f);
    setMode(game, modeFight);
}

void loseFish(device GameState &game, int text, thread uint &rng) {
    uint slot = game.counters.w;
    if (slot < uint(fishSlots)) {
        device Fish &f = game.fish[slot];
        int species = int(f.body.x);
        game.lure = float4(f.pos.xy, 0.0f, 2.0f);
        f.mind = float4(fishFlee, 2.5f, f.pos.z, 2.2f);
        f.pos.w = speciesDepth[species];
        f.aux.x = 12.0f;
        addRing(game, f.pos.xy, 0.9f);
    }
    resetFight(game);
    game.bite = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    setMessage(game, text, 2.6f, 0.0f, 3.0f);
    setMode(game, modeRetrieve);
}

void landFish(device GameState &game, thread uint &rng) {
    uint slot = game.counters.w;
    if (slot >= uint(fishSlots)) return;
    device Fish &f = game.fish[slot];
    int species = int(f.body.x);
    float kg = f.body.y;
    bool trophy = f.aux.w > 0.8f;
    float points = floor((kg * speciesPointsPerKg[species] + 25.0f) * (trophy ? 1.5f : 1.0f) + 0.5f);
    float flags = trophy ? 1.0f : 0.0f;
    if (kg > game.totals.z) {
        flags += 2.0f;
        game.totals.z = kg;
        game.totals.w = float(species);
    }
    game.catchInfo = float4(float(species), kg, points, flags);
    game.today.x += kg;
    game.today.y += points;
    game.today.z = max(game.today.z, kg);
    game.totals.x += kg;
    game.totals.y += points;
    game.counters.y += 1u;
    game.counters.z += 1u;
    addRing(game, f.pos.xy, 1.0f);
    game.splash = float4(f.pos.xy, 0.0f, 0.7f);
    f.mind = float4(fishGone, randomRange(rng, 4.0f, 9.0f), 0.0f, 0.0f);
    f.pos.xy = float2(0.0f, -40.0f);
    resetFight(game);
    game.lure = float4(game.rodTip.xz, 0.0f, 0.0f);
    game.message = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    setMode(game, modeCard);
}

void endDay(device GameState &game) {
    // A fish still on the line when the day ends swims free.
    uint slot = game.counters.w;
    if (slot < uint(fishSlots)) {
        game.fish[slot].mind = float4(fishFlee, 2.0f, game.fish[slot].pos.z, 2.0f);
    }
    resetFight(game);
    game.bite = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    game.lure = float4(game.rodTip.xz, 0.0f, 0.0f);
    game.message = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    setMode(game, modeAim);
    if (game.today.x >= game.dayInfo.x - 0.0001f) setPhase(game, phaseDayDone);
    else setPhase(game, phaseDayFailed);
}

// ---------------------------------------------------------------------------
// Fish behaviour outside the fight

void updateFish(device GameState &game, float dt, thread uint &rng) {
    float hour = currentHour(game);
    float activity = fishActivity(hour);
    float biteRate = game.settings2.x;
    bool playing = game.flow.x == phasePlay;
    bool lureIn = playing && game.flow.z == modeWait && game.lure.w == 2.0f
        && game.flightInfo.w > 0.5f;
    float2 lure = game.lure.xy;
    int owner = int(game.bite.x);
    for (int i = 0; i < fishSlots; ++i) {
        device Fish &f = game.fish[i];
        float mode = f.mind.x;
        int species = int(f.body.x);
        f.body.w += dt * (2.0f + 6.0f * f.mind.w);
        if (mode == fishGone) {
            f.mind.y -= dt;
            if (f.mind.y <= 0.0f) spawnFish(f, pickSpecies(game.flow.y, rng), rng, lure);
            continue;
        }
        if (mode == fishHooked) continue;
        f.aux.x = max(0.0f, f.aux.x - dt);
        float2 p = f.pos.xy;
        float heading = f.pos.z;
        float goal = f.mind.z;
        float speed = f.mind.w;
        float turnRate = 1.6f;
        float toLure = distance(p, lure);
        bool mine = owner == i;
        if (mode == fishRoam) {
            f.mind.y -= dt;
            if (f.mind.y <= 0.0f) {
                goal = heading + randomRange(rng, -1.3f, 1.3f);
                f.mind.y = randomRange(rng, 2.0f, 5.0f);
                speed = randomRange(rng, 0.2f, 0.55f);
            }
            if (p.y < speciesZoneNear[species]) goal = 0.0f;
            if (p.y > speciesZoneFar[species]) goal = 3.14159f;
            if (abs(p.x) > 0.92f * lakeHalfWidth(p.y)) goal = p.x > 0.0f ? -1.5708f : 1.5708f;
            f.aux.z -= dt * activity;
            if (f.aux.z <= 0.0f) {
                addRing(game, p, species == 1 ? 0.55f : 0.4f);
                f.aux.z = speciesRise[species] * randomRange(rng, 0.5f, 1.5f);
            }
            if (lureIn && owner < 0 && f.aux.x <= 0.0f && game.today.w > 0.6f) {
                float sense = speciesSense[species] * sqrt(activity);
                if (toLure < sense && random01(rng) < dt * 0.3f * biteRate * activity) {
                    owner = i;
                    mine = true;
                    game.bite = float4(float(i), 0.0f, 0.0f, 0.0f);
                    f.mind.x = fishApproach;
                    mode = fishApproach;
                }
            }
        }
        if (mode == fishApproach) {
            if (!lureIn || !mine) {
                f.mind.x = fishRoam;
            } else {
                goal = headingOf(lure - p);
                speed = 0.75f;
                turnRate = 3.0f;
                if (toLure < 0.5f) {
                    f.mind.x = fishNibble;
                    f.mind.y = randomRange(rng, 0.5f, 1.2f);
                    f.aux.y = floor(random01(rng) * (speciesNibbles[species] + 0.999f));
                    speed = 0.05f;
                }
            }
        } else if (mode == fishNibble) {
            if (!lureIn || !mine) {
                f.mind.x = fishRoam;
            } else {
                goal = headingOf(lure - p);
                speed = toLure > 0.35f ? 0.3f : 0.02f;
                turnRate = 3.0f;
                f.mind.y -= dt;
                if (f.mind.y <= 0.0f) {
                    if (f.aux.y >= 1.0f) {
                        f.aux.y -= 1.0f;
                        game.bite.y = randomRange(rng, 0.3f, 0.55f);
                        game.bite.z = 0.22f;
                        f.mind.y = randomRange(rng, 0.6f, 1.5f);
                        addRing(game, lure, 0.25f);
                    } else {
                        float window = speciesWindow[species];
                        f.mind.x = fishTake;
                        f.mind.y = window;
                        game.bite.y = 1.0f;
                        game.bite.z = window + 0.3f;
                        addRing(game, lure, 0.8f);
                    }
                }
            }
        } else if (mode == fishTake) {
            if (!lureIn || !mine) {
                f.mind.x = fishRoam;
            } else {
                goal = heading;
                speed = 0.35f;
                game.lure.xy += headingVector(heading) * 0.25f * dt;
                f.mind.y -= dt;
                if (f.mind.y <= 0.0f) {
                    if (random01(rng) < 0.55f) {
                        game.flightInfo.w = 0.0f;
                        setMessage(game, textBaitStolen, 3.0f, 0.0f, 2.0f);
                    } else {
                        setMessage(game, textMissed, 2.4f, 0.0f, 2.0f);
                    }
                    f.mind = float4(fishFlee, 1.6f, heading, 1.6f);
                    f.aux.x = 6.0f;
                    game.bite = float4(-1.0f, 0.0f, 0.0f, 0.0f);
                    owner = -1;
                }
            }
        } else if (mode == fishFlee) {
            f.mind.y -= dt;
            goal = toLure > 0.01f ? headingOf(p - lure) : heading;
            speed = max(speed, 1.6f);
            turnRate = 4.0f;
            if (f.mind.y <= 0.0f) {
                f.mind.x = fishRoam;
                f.mind.y = randomRange(rng, 1.0f, 3.0f);
                speed = 0.4f;
                f.aux.x = max(f.aux.x, 5.0f);
            }
        }
        heading = turnTowards(heading, goal, dt * turnRate);
        p += headingVector(heading) * speed * dt;
        p.y = clamp(p.y, 2.0f, 48.0f);
        float halfWidth = lakeHalfWidth(p.y);
        p.x = clamp(p.x, -halfWidth, halfWidth);
        f.pos.xy = p;
        f.pos.z = wrapAngle(heading);
        f.mind.z = wrapAngle(goal);
        f.mind.w = speed;
    }
}

// ---------------------------------------------------------------------------
// The fight

void updateFight(device GameState &game, constant ProgramUniforms &u, float dt, bool pressed,
    thread uint &rng) {
    uint slot = game.counters.w;
    if (slot >= uint(fishSlots)) {
        setMode(game, modeRetrieve);
        return;
    }
    device Fish &f = game.fish[slot];
    int species = int(f.body.x);
    float sizeFrac = f.aux.w;
    float power = mix(speciesPowerMin[species], speciesPowerMax[species], sizeFrac) * game.settings.z;
    float endurance = mix(speciesEnduranceMin[species], speciesEnduranceMax[species], sizeFrac);
    float topSpeed = speciesSpeed[species] * (0.85f + 0.3f * sizeFrac);

    // Controls: crosshair X holds the rod to a side, Y sets the reel speed.
    float rodTarget = clamp((u.pointer.x - 0.5f) * 2.4f, -1.0f, 1.0f);
    game.fight2.x += (rodTarget - game.fight2.x) * min(1.0f, dt * 10.0f);
    float reelTarget = clamp((0.72f - u.pointer.y) / 0.52f, 0.0f, 1.0f);
    game.fight2.y += (reelTarget - game.fight2.y) * min(1.0f, dt * 12.0f);
    float reel = game.fight2.y;
    bool reeling = reel > 0.04f;

    float2 tip = game.rodTip.xz;
    float2 p = f.pos.xy;
    float2 rel = p - tip;
    float d = max(length(rel), 0.01f);
    float2 outward = rel / d;
    float stamina = game.fight0.z;

    // Choose the next run or rest.
    game.fight1.y -= dt;
    if (game.fight1.y <= 0.0f) {
        if (random01(rng) < 0.2f + 0.65f * stamina) {
            game.fight1.x = fightRun;
            game.fight0.w = randomRange(rng, 0.7f, 1.0f);
            game.fight1.y = randomRange(rng, 1.0f, 3.0f);
            if (random01(rng) < speciesCharge[species]) {
                game.fight3.x = headingOf(-outward) + randomRange(rng, -0.6f, 0.6f);
            } else {
                game.fight3.x = headingOf(outward) + randomRange(rng, -1.25f, 1.25f);
            }
            if (random01(rng) < speciesJump[species] * (0.4f + 0.6f * stamina)) game.fight3.w = 0.0f;
            if (random01(rng) < speciesShake[species]) game.fight3.y = 0.75f;
        } else {
            game.fight1.x = fightRest;
            game.fight0.w = randomRange(rng, 0.08f, 0.22f);
            game.fight1.y = randomRange(rng, 0.8f, 2.2f) + (1.0f - stamina) * 1.2f;
            game.fight3.x = f.pos.z + randomRange(rng, -0.8f, 0.8f);
        }
    }
    // Stay inside the lake.
    if (p.y > 55.0f || abs(p.x) > lakeHalfWidth(p.y) + 2.0f) {
        game.fight3.x = headingOf(float2(0.0f, 15.0f) - p);
    }
    bool running = game.fight1.x == fightRun;
    float heading = turnTowards(f.pos.z, game.fight3.x, dt * (running ? 2.4f : 0.8f));

    // Side strain: the rod held opposite the fish's sideways run turns and tires it.
    float2 swim = headingVector(heading);
    float2 right = float2(outward.y, -outward.x);
    float lateral = dot(swim, right);
    float strain = clamp(-game.fight2.x * lateral * 1.6f, -1.0f, 1.0f) * (running ? 1.0f : 0.3f);
    game.fight2.z += (strain - game.fight2.z) * min(1.0f, dt * 6.0f);
    if (strain > 0.0f) heading = turnTowards(heading, headingOf(-outward), dt * 1.2f * strain);
    swim = headingVector(heading);

    // Head shakes and jumps jolt the line.
    game.fight3.y = max(0.0f, game.fight3.y - dt);
    float spike = game.fight3.y > 0.0f ? 0.3f * (0.6f + 0.4f * sin(game.clock.w * 38.0f)) : 0.0f;
    if (game.fight3.w >= 0.0f) {
        float before = game.fight3.w;
        game.fight3.w += dt / 0.9f;
        if (before == 0.0f) {
            addRing(game, p, 0.9f);
            game.splash = float4(p, 0.0f, 0.9f);
        }
        if (game.fight3.w < 0.15f || game.fight3.w > 0.85f) spike += 0.22f;
        if (game.fight3.w >= 1.0f) {
            game.fight3.w = -1.0f;
            addRing(game, p + swim * 0.6f, 1.0f);
            game.splash = float4(p + swim * 0.6f, 0.0f, 1.0f);
        }
    }

    float effort = game.fight0.w;
    float stam = 0.3f + 0.7f * stamina;
    float force = power * effort * stam;
    float away = dot(swim, outward);
    float pull = force * (0.35f + 0.65f * max(away, 0.0f)) + 0.05f * sizeFrac;
    float slack = game.fight0.x - d;
    bool taut = slack < 0.3f;
    float tension;
    if (reeling) {
        tension = taut ? pull + reel * 0.6f + spike : 0.06f * reel;
    } else {
        tension = taut ? min(pull + spike, dragLimit) : 0.0f;
    }
    game.fight0.y += (tension - game.fight0.y) * min(1.0f, dt * 9.0f);

    // Reeling shortens the line, but a hard run stops the reel.
    if (reeling) {
        float resist = min(1.0f, force * max(away, 0.0f) / 0.7f);
        game.fight0.x -= reel * reelSpeed * dt * (1.0f - 0.85f * resist);
    }

    // The fish swims; the line holds it, or the drag lets line out.
    float speed = topSpeed * effort * stam;
    float2 freePos = p + swim * speed * dt;
    float freeDistance = length(freePos - tip);
    bool slip = !reeling && pull + spike > dragLimit - 0.02f;
    if (freeDistance > game.fight0.x) {
        if (slip) {
            game.fight0.x = freeDistance;
            p = freePos;
        } else {
            p = tip + (freePos - tip) / freeDistance * game.fight0.x;
        }
    } else {
        p = freePos;
    }
    float held = length(p - tip);
    if (held > game.fight0.x) p = tip + (p - tip) / held * game.fight0.x;
    p.y = max(p.y, deckEnd + 1.0f);
    game.fight0.x = clamp(game.fight0.x, 1.0f, maxLine);
    if (running && random01(rng) < dt * 3.0f) addRing(game, p, 0.35f);

    // Tension tires the fish.
    float drainScale = 1.0f + 1.4f * max(game.fight2.z, 0.0f) - 0.4f * max(-game.fight2.z, 0.0f);
    stamina -= dt * (0.2f * effort + 0.8f * game.fight0.y) * drainScale / endurance;
    if (!running && game.fight0.y < 0.15f) stamina += dt * 0.01f;
    game.fight0.z = clamp(stamina, 0.0f, 1.0f);
    f.pos.xy = p;
    f.pos.z = wrapAngle(heading);
    f.mind.w = speed;
    f.body.w += dt * (3.0f + 5.0f * speed);

    // Ways to lose the fish.
    game.fight3.z = max(0.0f, game.fight3.z - dt);
    if (reeling && game.fight0.y > 1.0f) game.fight1.z += dt;
    else game.fight1.z = max(0.0f, game.fight1.z - dt * 1.5f);
    float slackNow = game.fight0.x - length(p - tip);
    if (slackNow > 1.2f) game.fight1.w += dt;
    else game.fight1.w = max(0.0f, game.fight1.w - dt * 2.0f);
    if (game.fight3.z <= 0.0f) {
        if (game.fight1.z > 0.45f) {
            loseFish(game, textSnapped, rng);
            return;
        }
        if (game.fight1.w > 1.6f) {
            loseFish(game, textLoose, rng);
            return;
        }
        if (game.fight0.x >= maxLine - 0.01f && slip) {
            loseFish(game, textSpooled, rng);
            return;
        }
    }

    // Netting.
    bool ready = game.fight0.x < 3.3f && length(p - tip) < 3.8f;
    game.fight2.w = ready ? 1.0f : 0.0f;
    if (pressed) {
        if (ready && game.fight0.z < 0.42f) {
            landFish(game, rng);
            return;
        }
        if (ready) {
            game.fight1.x = fightRun;
            game.fight0.w = 1.0f;
            game.fight1.y = 1.6f;
            game.fight3.x = headingOf(outward) + randomRange(rng, -0.5f, 0.5f);
            game.fight3.y = 0.5f;
            game.fight0.z = max(0.0f, game.fight0.z - 0.04f);
            addRing(game, p, 1.0f);
            game.splash = float4(p, 0.0f, 0.9f);
            setMessage(game, textTooLively, 2.2f, 0.0f, 2.0f);
        } else {
            setMessage(game, textCloser, 1.8f, 0.0f, 1.0f);
        }
    }
}

// ---------------------------------------------------------------------------
// Rod, float and line in screen space for the present pass

void updateRodAndLine(device GameState &game, constant ProgramUniforms &u, float dt) {
    float2 resolution = u.resolutionTime.xy;
    float aspect = resolution.x / max(resolution.y, 1.0f);
    float yaw = game.camera.x;
    uint mode = game.flow.z;
    bool playing = game.flow.x == phasePlay;
    float side;
    float bend = 0.0f;
    float lift = 0.0f;
    if (playing && mode == modeFight) {
        side = game.fight2.x;
        bend = clamp(game.fight0.y, 0.0f, 1.2f);
    } else if (playing && mode == modeAim) {
        side = clamp((u.pointer.x - 0.5f) * 0.9f, -0.5f, 0.5f);
    } else {
        float3 lureCamera = worldToCamera(float3(game.lure.x, 0.0f, game.lure.y), yaw);
        side = clamp(lureCamera.x / max(lureCamera.z, 1.0f) * 1.2f, -0.6f, 0.6f);
        if (mode == modeWait) bend = 0.05f + 0.35f * game.lure.z;
        if (mode == modeCast) {
            float t = game.flightInfo.x;
            lift = 0.35f * sin(min(t * 5.0f, 3.14159f));
        }
    }
    game.rodTip.w += (side - game.rodTip.w) * min(1.0f, dt * 8.0f);
    float smoothSide = game.rodTip.w;
    float3 tipCamera = float3(0.5f + 0.9f * smoothSide, 0.32f - 0.3f * bend + lift, 3.6f - 0.4f * bend);
    float3 tip = cameraPosition + cameraToWorldDirection(tipCamera, yaw);
    game.rodTip.xyz = tip;
    game.rodScreen = float4(cameraToUV(tipCamera, aspect), 0.86f, 1.25f);

    // Line end and sag.
    float3 end;
    float sag = 0.0f;
    float lureState = game.lure.w;
    if (playing && mode == modeFight && game.counters.w < uint(fishSlots)) {
        float2 fishAt = game.fish[game.counters.w].pos.xy;
        end = float3(fishAt.x, 0.0f, fishAt.y);
        float slack = game.fight0.x - distance(fishAt, tip.xz);
        sag = slack > 0.3f ? min(slack * 0.35f, 2.0f) : 0.004f * game.fight0.x;
    } else if (playing && lureState == 1.0f) {
        float t = clamp(game.flightInfo.x, 0.0f, 1.0f);
        float2 at = mix(game.flight.xy, game.flight.zw, t);
        float height = mix(tip.y, 0.0f, t) + game.flightInfo.z * 4.0f * t * (1.0f - t);
        end = float3(at.x, height, at.y);
        sag = 0.0f;
    } else if (playing && lureState == 2.0f) {
        end = float3(game.lure.x, 0.0f, game.lure.y);
        sag = 0.012f * distance(game.lure.xy, tip.xz);
    } else {
        end = tip + float3(0.0f, -0.55f, 0.0f);
        sag = 0.0f;
    }
    float4 box = float4(2.0f, 2.0f, -2.0f, -2.0f);
    for (int i = 0; i < linePointCount; ++i) {
        float t = float(i) / float(linePointCount - 1);
        float3 q = mix(tip, end, t);
        q.y -= sag * 4.0f * t * (1.0f - t);
        q.y = max(q.y, 0.0f);
        float2 uv = projectToUV(q, yaw, aspect);
        if ((i & 1) == 0) game.linePoints[i / 2].xy = uv;
        else game.linePoints[i / 2].zw = uv;
        box.xy = min(box.xy, uv);
        box.zw = max(box.zw, uv);
    }
    game.lineBox = box;

    // The float (or the hanging lure) at the end of the line.
    float3 floatAt = end + float3(0.0f, 0.04f, 0.0f);
    float3 floatCamera = worldToCamera(floatAt, yaw);
    float floatSize = lureState == 2.0f ? 0.09f : 0.035f;
    float radius = max(floatSize * pixelsPerMetre(floatCamera.z, resolution.y), 2.6f);
    float visible = 0.0f;
    if (playing && mode != modeFight && mode != modeCard) visible = lureState == 2.0f ? 1.0f : 2.0f;
    game.bobber = float4(cameraToUV(floatCamera, aspect), radius, visible);
}

// ---------------------------------------------------------------------------
// Kernels

kernel void initializeLake(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    game.settings = readSettings(u);
    game.settings2 = readSettings2(u);
    uint rng = hashUint(u.frameSeed.y * 2654435761u + 977u) | 1u;
    game.totals = float4(0.0f);
    game.camera = float4(0.0f);
    game.rodTip = float4(0.5f, 2.4f, 0.9f, 0.0f);
    startDay(game, uint(game.settings.y), rng);
    setPhase(game, phaseTitle);
    // A stale action count from before the run is not a press.
    game.clock = float4(game.settings.x, 0.0f, u.pointer.z, 0.0f);
    game.counters = uint4(rng, 0u, 0u, uint(fishSlots));
    updateRodAndLine(game, u, 0.0f);
}

kernel void advanceLake(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = tickSeconds(u);
    uint rng = game.counters.x;
    float actions = u.pointer.z;
    bool pressed = actions > game.clock.z + 0.5f;
    game.clock.z = actions;
    game.clock.y += dt;
    game.clock.w += dt;
    game.flow.w += 1u;
    game.today.w += dt;
    game.message.y = max(0.0f, game.message.y - dt);
    game.splash.z += dt;
    for (int i = 0; i < ringSlots; ++i) game.rings[i].z += dt;
    // Presses on a result screen wait a moment so a double press is not lost.
    bool screenPress = pressed && game.clock.y > 0.35f;
    float2 resolution = u.resolutionTime.xy;
    float aspect = resolution.x / max(resolution.y, 1.0f);

    uint phase = game.flow.x;
    if (phase == phaseTitle) {
        if (screenPress) {
            game.totals = float4(0.0f);
            game.counters.z = 0u;
            startDay(game, uint(game.settings.y), rng);
        }
    } else if (phase == phaseBriefing) {
        if (screenPress) {
            setPhase(game, phasePlay);
            setMode(game, modeAim);
        }
    } else if (phase == phaseDayDone) {
        if (screenPress) {
            if (game.flow.y < 2u) startDay(game, game.flow.y + 1u, rng);
            else setPhase(game, phaseVictory);
        }
    } else if (phase == phaseDayFailed) {
        if (screenPress) {
            game.totals = game.dayStart;
            game.counters.z -= min(game.counters.z, game.counters.y);
            startDay(game, game.flow.y, rng);
        }
    } else if (phase == phaseVictory) {
        if (screenPress) {
            game.totals = float4(0.0f);
            game.counters.z = 0u;
            startDay(game, uint(game.settings.y), rng);
            setPhase(game, phaseTitle);
        }
    } else {
        uint mode = game.flow.z;
        float before = game.clock.x;
        if (mode != modeCard) game.clock.x = max(0.0f, game.clock.x - dt);
        bool dusk = game.clock.x <= 0.0f;
        if (before > 20.0f && game.clock.x <= 20.0f) {
            setMessage(game, textLastCasts, 3.0f, 0.0f, 1.0f);
        }
        if (mode == modeAim) {
            game.aim = aimFromPointer(u.pointer.xy, aspect, game.camera.x, game.rodTip.xz);
            game.lure = float4(game.rodTip.xz, 0.0f, 0.0f);
            if (dusk) endDay(game);
            else if (pressed) startCast(game, rng);
        } else if (mode == modeCast) {
            game.flightInfo.x += dt / max(game.flightInfo.y, 0.1f);
            game.lure.xy = mix(game.flight.xy, game.flight.zw, clamp(game.flightInfo.x, 0.0f, 1.0f));
            if (game.flightInfo.x >= 1.0f) landLure(game, rng);
        } else if (mode == modeWait) {
            float dipTarget = 0.0f;
            game.bite.z = max(0.0f, game.bite.z - dt);
            if (game.bite.z > 0.0f) dipTarget = game.bite.y;
            game.lure.z += (dipTarget - game.lure.z) * min(1.0f, dt * 14.0f);
            if (dusk) {
                endDay(game);
            } else if (pressed) {
                int owner = int(game.bite.x);
                float ownerMode = owner >= 0 && owner < fishSlots ? game.fish[owner].mind.x : -1.0f;
                if (ownerMode == fishTake) {
                    hookFish(game, owner, rng);
                } else if (ownerMode == fishNibble || (ownerMode == fishApproach
                    && distance(game.fish[owner].pos.xy, game.lure.xy) < 1.5f)) {
                    device Fish &f = game.fish[owner];
                    f.mind = float4(fishFlee, 1.6f, f.pos.z, 1.8f);
                    f.aux.x = 6.0f;
                    scareNear(game, game.lure.xy, 5.0f, 4.0f);
                    game.bite = float4(-1.0f, 0.0f, 0.0f, 0.0f);
                    addRing(game, game.lure.xy, 0.6f);
                    setMessage(game, textTooEarly, 2.4f, 0.0f, 2.0f);
                } else {
                    startRetrieve(game);
                }
            }
        } else if (mode == modeFight) {
            // After dusk a fish can still be played out, but not forever.
            if (dusk && game.today.w > 90.0f) loseFish(game, textLoose, rng);
            else updateFight(game, u, dt, pressed, rng);
        } else if (mode == modeRetrieve) {
            float2 tip = game.rodTip.xz;
            float2 toTip = tip - game.lure.xy;
            float gap = length(toTip);
            float stepLength = 11.0f * dt;
            game.lure.z = 0.0f;
            if (gap <= max(stepLength, 1.6f)) {
                game.lure = float4(tip, 0.0f, 0.0f);
                game.flightInfo.w = 1.0f;
                setMode(game, modeAim);
            } else {
                game.lure.xy += toTip / gap * stepLength;
            }
            if (dusk) endDay(game);
        } else if (mode == modeCard) {
            bool done = (pressed && game.today.w > 0.5f) || game.today.w > 9.0f;
            if (done) {
                setMode(game, modeAim);
                if (game.today.x >= game.dayInfo.x
                    && game.today.x - game.catchInfo.y < game.dayInfo.x) {
                    setMessage(game, textTargetReached, 3.5f, 0.0f, 2.0f);
                }
                if (dusk) endDay(game);
            }
        }
    }

    updateFish(game, dt, rng);

    // The camera turns gently towards the float or the fish.
    float yawTarget = 0.0f;
    if (game.flow.x == phasePlay) {
        uint mode = game.flow.z;
        if (mode == modeFight && game.counters.w < uint(fishSlots)) {
            float2 at = game.fish[game.counters.w].pos.xy;
            yawTarget = atan2(at.x, at.y - cameraPosition.z) * 0.6f;
        } else if (mode == modeWait || mode == modeCast || mode == modeRetrieve) {
            yawTarget = atan2(game.lure.x, game.lure.y - cameraPosition.z) * 0.4f;
        }
    }
    yawTarget = clamp(yawTarget, -0.4f, 0.4f);
    game.camera.x += (yawTarget - game.camera.x) * min(1.0f, dt * 2.5f);

    updateRodAndLine(game, u, dt);
    game.counters.x = rng;
}

// ---------------------------------------------------------------------------
// Presentation: the lake seen from the end of the jetty

vertex ScreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2(float((vertexID << 1u) & 2u), float(vertexID & 2u));
    ScreenVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, float3(2.4f)), c / 12.92f, c <= 0.04045f);
}

// Generated images are premultiplied display sRGB; returns linear colour.
float3 imageColor(texture2d<float> image, float2 uv) {
    constexpr sampler imageSampler(coord::normalized, address::mirrored_repeat, filter::linear);
    float4 texel = image.sample(imageSampler, uv);
    float3 srgb = clamp(texel.rgb / max(texel.a, 0.001f), float3(0.0f), float3(1.0f));
    return srgbToLinear(srgb);
}

float3 pictureColor(texture2d<float> image, float2 uv) {
    constexpr sampler pictureSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 texel = image.sample(pictureSampler, uv);
    float3 srgb = clamp(texel.rgb / max(texel.a, 0.001f), float3(0.0f), float3(1.0f));
    return srgbToLinear(srgb);
}

float3 mistColor(float3 tint) {
    return float3(0.60f, 0.65f, 0.70f) * tint;
}

float windiness(uint day) {
    if (day == 1u) return 1.0f;
    if (day == 2u) return 0.75f;
    return 0.55f;
}

// The generated panorama: its upper part (above horizonLine) is the far shore
// and sky, wrapped around the lake by yaw and elevation.
float3 panoramaColor(texture2d<float> panorama, float3 dir, float horizonLine, float3 tint,
    float mist) {
    float yaw = atan2(dir.x, dir.z);
    float elevation = atan2(dir.y, length(float2(dir.x, dir.z)));
    float u = 0.5f + yaw / panoramaSpan;
    float v = horizonLine * (1.0f - max(elevation, 0.0f) / panoramaTop);
    v = clamp(v, 0.002f, horizonLine - 0.002f);
    float3 color = imageColor(panorama, float2(u, v)) * tint;
    float band = mist * exp(-max(elevation, 0.0f) / 0.045f);
    return mix(color, mistColor(tint), clamp(band, 0.0f, 0.92f));
}

// Height gradient of the gentle lake swell (metres per metre), faded by the
// pixel footprint so distant water does not shimmer.
float2 waveGradient(float2 p, float time, float footprint, float wind) {
    float2 gradient = float2(0.0f);
    float2 dirs[5] = {float2(0.8f, 0.6f), float2(-0.5f, 0.866f), float2(0.196f, 0.98f),
        float2(0.96f, -0.28f), float2(-0.707f, 0.707f)};
    float lengths[5] = {2.8f, 1.7f, 1.1f, 0.6f, 0.35f};
    float amplitudes[5] = {0.010f, 0.0065f, 0.004f, 0.002f, 0.001f};
    for (int i = 0; i < 5; ++i) {
        float k = 6.2831853f / lengths[i];
        float fade = clamp(2.0f - footprint * k / 0.8f, 0.0f, 1.0f);
        if (fade <= 0.0f) continue;
        float omega = sqrt(9.8f * k);
        float phase = k * dot(dirs[i], p) - omega * time;
        gradient += dirs[i] * (amplitudes[i] * k * cos(phase) * fade);
    }
    return gradient * wind;
}

// Expanding rings from rises, the float and the fight. Returns the gradient in
// xy and a highlight in z.
float3 ringField(float2 p, float footprint, device const GameState &game) {
    float3 result = float3(0.0f);
    float wavelength = max(0.22f, 4.0f * footprint);
    float k = 6.2831853f / wavelength;
    for (int i = 0; i < ringSlots; ++i) {
        float4 ring = game.rings[i];
        float age = ring.z;
        if (age > 3.2f) continue;
        float radius = 0.08f + 0.5f * age;
        float2 rel = p - ring.xy;
        float r = length(rel);
        float x = r - radius;
        float width = max(0.12f, 2.0f * footprint) + 0.05f * age;
        if (abs(x) > 3.0f * width) continue;
        float strength = ring.w * exp(-age * 1.1f) * (1.0f - smoothstep(2.6f, 3.2f, age));
        float envelope = exp(-(x * x) / (width * width));
        float slope = 0.22f * strength * cos(k * x) * envelope;
        result.xy += rel / max(r, 0.001f) * slope;
        result.z += strength * envelope * 0.25f;
    }
    return result;
}

// Dark fish shapes under the surface (0 = none, 1 = black).
float fishShadows(float2 p, float footprint, float fresnel, device const GameState &game) {
    float darkness = 0.0f;
    for (int i = 0; i < fishSlots; ++i) {
        Fish f = game.fish[i];
        if (f.mind.x == fishGone) continue;
        // Refraction makes fish look larger; distant ones are exaggerated a
        // little more so they stay readable.
        float away = max(f.pos.y - cameraPosition.z, 0.0f);
        float len = f.body.z * 1.25f * (1.0f + 0.02f * away);
        float2 rel = p - f.pos.xy;
        float reach = 0.7f * len + 0.1f + f.pos.w * 0.1f + footprint;
        if (dot(rel, rel) > reach * reach) continue;
        float2 forward = headingVector(f.pos.z);
        float a = dot(rel, forward);
        float b = dot(rel, float2(forward.y, -forward.x));
        int species = int(f.body.x);
        float halfWidth = max(speciesWidth[species] * len, 1.5f * footprint);
        float behind = 1.0f - smoothstep(-0.5f * len, 0.1f * len, a);
        b += sin(f.body.w - a / len * 6.0f) * 0.08f * len * behind;
        float e = length(float2(a / (0.5f * len), b / halfWidth));
        float sdf = (e - 1.0f) * halfWidth;
        float tailX = -a - 0.42f * len;
        if (tailX > 0.0f && tailX < 0.2f * len) {
            sdf = min(sdf, abs(b) - tailX * 0.9f);
        }
        float depth = f.pos.w;
        float blur = 0.012f + depth * 0.04f + footprint * 0.6f;
        float shape = 1.0f - smoothstep(-blur, blur, sdf);
        // A soft dark halo makes small or distant fish easier to spot.
        float halo = 1.0f - smoothstep(-halfWidth, halfWidth * 2.5f + 2.0f * blur, sdf);
        shape = max(shape, 0.35f * halo);
        bool hooked = f.mind.x == fishHooked;
        float visibility = (1.0f - 0.75f * fresnel) * exp(-depth * 0.45f) * (hooked ? 1.0f : 0.9f);
        darkness = max(darkness, shape * visibility);
    }
    return darkness;
}

struct PostHit {
    float t;
    float3 normal;
    float y;
    float angle;
};

PostHit intersectPosts(float3 origin, float3 dir) {
    PostHit hit;
    hit.t = 1.0e9f;
    hit.normal = float3(0.0f, 1.0f, 0.0f);
    hit.y = 0.0f;
    hit.angle = 0.0f;
    float radius = 0.12f;
    for (int i = 0; i < 2; ++i) {
        float2 centre = float2(i == 0 ? -1.0f : 1.0f, deckEnd - 0.1f);
        float2 o = float2(origin.x, origin.z) - centre;
        float2 dd = float2(dir.x, dir.z);
        float a = dot(dd, dd);
        float b = dot(o, dd);
        float c = dot(o, o) - radius * radius;
        float disc = b * b - a * c;
        if (disc <= 0.0f || a < 1.0e-6f) continue;
        float t = (-b - sqrt(disc)) / a;
        float y = origin.y + dir.y * t;
        if (t > 0.0f && t < hit.t && y > 0.0f && y < 1.38f) {
            float2 n = (o + dd * t) / radius;
            hit.t = t;
            hit.normal = float3(n.x, 0.0f, n.y);
            hit.y = y;
            hit.angle = atan2(n.y, n.x);
        }
    }
    return hit;
}

float3 shadeScene(float2 uv, float2 resolution, device const GameState &game,
    texture2d<float> panorama, texture2d<float> wood, float time) {
    float aspect = resolution.x / resolution.y;
    float yaw = game.camera.x;
    float3 dir = cameraRay(uv, aspect, yaw);
    float hour = currentHour(game);
    float3 tint = lightTint(hour);
    float mist = mistAmount(hour);
    float horizonLine = game.settings.w;
    float pixelAngle = 2.0f * tanHalfFov / resolution.y;
    float3 origin = cameraPosition;

    float tWater = dir.y < -1.0e-4f ? -origin.y / dir.y : 1.0e9f;
    float tDeck = 1.0e9f;
    float3 deckPoint = float3(0.0f);
    if (dir.y < -1.0e-4f) {
        float t = (deckTop - origin.y) / dir.y;
        float3 q = origin + dir * t;
        if (abs(q.x) < deckHalfWidth && q.z < deckEnd) {
            tDeck = t;
            deckPoint = q;
        }
    }
    PostHit post = intersectPosts(origin, dir);

    if (post.t < tDeck && post.t < tWater) {
        float3 n = post.normal;
        float2 grain = float2(post.angle * 0.25f, post.y * 0.45f);
        float3 base = imageColor(wood, grain + float2(0.37f, 0.11f)) * 0.75f;
        float wet = 1.0f - smoothstep(0.05f, 0.45f, post.y);
        base = mix(base, base * float3(0.45f, 0.5f, 0.42f), wet);
        float light = 0.45f + 0.55f * clamp(dot(n, normalize(float3(-0.4f, 0.5f, -0.75f))), 0.0f, 1.0f);
        float cap = smoothstep(1.30f, 1.37f, post.y);
        return base * light * tint * (1.0f - 0.25f * cap);
    }
    if (tDeck < tWater) {
        float2 deckUV = float2(deckPoint.x, deckPoint.z) * 0.42f;
        float3 base = imageColor(wood, deckUV);
        float plank = fract(deckPoint.z / 0.17f);
        float gap = smoothstep(0.0f, 0.06f, plank) * (1.0f - smoothstep(0.94f, 1.0f, plank));
        float edge = 1.0f - smoothstep(deckHalfWidth - 0.04f, deckHalfWidth, abs(deckPoint.x));
        float endFade = 1.0f - smoothstep(deckEnd - 0.05f, deckEnd, deckPoint.z);
        return base * (0.25f + 0.65f * gap) * (0.6f + 0.4f * edge * endFade) * tint * 0.9f;
    }
    if (dir.y >= -1.0e-4f) {
        return panoramaColor(panorama, dir, horizonLine, tint, mist);
    }

    // Water.
    float3 p = origin + dir * tWater;
    float2 at = float2(p.x, p.z);
    float footprint = tWater * pixelAngle / max(-dir.y, 0.02f);
    float2 gradient = waveGradient(at, time, footprint, windiness(game.flow.y));
    float3 rings = ringField(at, footprint, game);
    gradient += rings.xy;
    float3 n = normalize(float3(-gradient.x, 1.0f, -gradient.y));
    float3 r = reflect(dir, n);
    r.y = max(r.y, 0.004f);
    r = normalize(r);
    float cosView = clamp(dot(-dir, n), 0.0f, 1.0f);
    float fresnel = 0.02f + 0.98f * pow(1.0f - cosView, 5.0f);
    float3 reflection = panoramaColor(panorama, r, horizonLine, tint, mist);

    // Sun glint: low on the left in the morning, on the right in the evening.
    float sunT = clamp((hour - 5.0f) / 16.0f, 0.0f, 1.0f);
    float sunAzimuth = mix(-1.1f, 1.1f, sunT);
    float sunElevation = 0.1f + 0.5f * sin(3.14159f * sunT);
    float3 sunDir = float3(sin(sunAzimuth) * cos(sunElevation), sin(sunElevation),
        cos(sunAzimuth) * cos(sunElevation));
    float glint = pow(max(dot(r, sunDir), 0.0f), 260.0f) * (1.0f - 0.6f * mist);
    reflection += glint * tint * float3(2.2f, 1.9f, 1.5f);

    float3 body = float3(0.045f, 0.088f, 0.072f) * tint;
    float shade = fishShadows(at, footprint, fresnel, game);
    float3 color = mix(body, reflection, fresnel);
    // Fish read as dark shapes through the surface.
    color *= 1.0f - 0.82f * shade;
    color += rings.z * mistColor(tint) * 0.35f;

    // Aim reticle on the water.
    if (game.flow.x == phasePlay && game.flow.z == modeAim && game.aim.w > 0.5f) {
        float d = length(at - game.aim.xy);
        float lineWidth = max(0.04f, 1.6f * footprint);
        float ringShape = 1.0f - smoothstep(lineWidth * 0.5f, lineWidth, abs(d - 0.75f));
        float pulse = 0.75f + 0.25f * sin(time * 5.0f);
        float centreDot = 1.0f - smoothstep(lineWidth * 0.6f, lineWidth * 1.2f, d);
        float2 rel = at - game.aim.xy;
        float ticks = (1.0f - smoothstep(lineWidth * 0.4f, lineWidth * 0.8f, min(abs(rel.x), abs(rel.y))))
            * step(0.95f, d) * (1.0f - step(1.35f, d));
        color = mix(color, float3(1.0f, 0.86f, 0.55f) * pulse,
            clamp(ringShape + centreDot + ticks, 0.0f, 1.0f) * 0.85f);
    }

    float fog = 1.0f - exp(-tWater * 0.0035f * (0.4f + mist));
    float horizonBand = mist * exp(-max(-atan2(dir.y, length(float2(dir.x, dir.z))), 0.0f) / 0.03f);
    color = mix(color, mistColor(tint), clamp(max(fog, horizonBand), 0.0f, 0.9f));
    return color;
}

// ---------------------------------------------------------------------------
// Screen-space overlays: rod, line, float, splashes and a leaping fish

float bezierDistance(float2 p, float2 a, float2 control, float2 b, thread float &along) {
    float best = 1.0e9f;
    float2 previous = a;
    along = 0.0f;
    for (int i = 1; i <= 12; ++i) {
        float t = float(i) / 12.0f;
        float2 q = mix(mix(a, control, t), mix(control, b, t), t);
        float2 ab = q - previous;
        float len2 = max(dot(ab, ab), 1.0e-6f);
        float s = clamp(dot(p - previous, ab) / len2, 0.0f, 1.0f);
        float dist = length(p - (previous + ab * s));
        if (dist < best) {
            best = dist;
            along = (float(i - 1) + s) / 12.0f;
        }
        previous = q;
    }
    return best;
}

void drawRod(thread float3 &color, float2 pixel, float2 resolution, device const GameState &game,
    float3 tint) {
    float2 tip = game.rodScreen.xy * resolution;
    float2 butt = game.rodScreen.zw * resolution;
    float scale = resolution.y / 600.0f;
    float tension = game.flow.z == modeFight ? clamp(game.fight0.y, 0.0f, 1.2f) : 0.0f;
    float2 mid = mix(butt, tip, 0.55f);
    float2 axis = normalize(tip - butt);
    float2 normal = float2(axis.y, -axis.x);
    // The tip bends towards the line (down and towards the fish).
    float2 lineDir = float2(0.0f, 1.0f);
    if (game.lineBox.z > game.lineBox.x) {
        float2 second = game.linePoints[1].xy * resolution;
        lineDir = normalize(second - tip + float2(0.0f, 0.001f));
    }
    float2 control = mid + normal * dot(normal, lineDir) * (14.0f + 90.0f * tension) * scale;
    float2 boxMin = min(min(tip, butt), control) - 12.0f * scale;
    float2 boxMax = max(max(tip, butt), control) + 12.0f * scale;
    if (pixel.x < boxMin.x || pixel.y < boxMin.y || pixel.x > boxMax.x || pixel.y > boxMax.y) return;
    float along = 0.0f;
    float d = bezierDistance(pixel, butt, control, tip, along);
    float width = mix(8.0f, 1.6f, along) * scale;
    float coverage = clamp(width - d + 0.5f, 0.0f, 1.0f);
    if (coverage <= 0.0f) return;
    float3 rodColor = mix(float3(0.035f, 0.025f, 0.02f), float3(0.12f, 0.05f, 0.03f), along);
    // Thread wraps at the guides.
    for (int i = 0; i < 4; ++i) {
        float guide = 0.42f + 0.16f * float(i);
        if (abs(along - guide) < 0.012f) rodColor = float3(0.55f, 0.42f, 0.12f);
    }
    float highlight = 1.0f - smoothstep(0.0f, width, d);
    rodColor += highlight * 0.06f;
    color = mix(color, rodColor * (0.5f + 0.5f * tint), coverage);
}

void drawLine(thread float3 &color, float2 pixel, float2 resolution, device const GameState &game,
    float3 tint) {
    float4 box = game.lineBox;
    float margin = 3.0f / resolution.y;
    float2 uv = pixel / resolution;
    if (uv.x < box.x - margin || uv.y < box.y - margin || uv.x > box.z + margin || uv.y > box.w + margin) return;
    float best = 1.0e9f;
    float2 previous = game.linePoints[0].xy * resolution;
    for (int i = 1; i < linePointCount; ++i) {
        float4 pair = game.linePoints[i / 2];
        float2 q = ((i & 1) == 0 ? pair.xy : pair.zw) * resolution;
        best = min(best, segmentDistance(pixel, previous, q));
        previous = q;
    }
    float coverage = clamp(1.1f - best, 0.0f, 1.0f) * 0.85f;
    float tension = game.flow.z == modeFight ? clamp(game.fight0.y, 0.0f, 1.2f) : 0.0f;
    float3 lineColor = mix(float3(0.85f, 0.86f, 0.82f), float3(1.0f, 0.45f, 0.3f),
        smoothstep(0.85f, 1.05f, tension));
    color = mix(color, lineColor * (0.4f + 0.6f * tint), coverage);
}

void drawFloat(thread float3 &color, float2 pixel, float2 resolution, device const GameState &game,
    float time) {
    float4 info = game.bobber;
    if (info.w < 0.5f) return;
    float2 centre = info.xy * resolution;
    float radius = info.z;
    float2 rel = pixel - centre;
    if (abs(rel.x) > radius * 3.0f + 20.0f || rel.y > radius * 3.0f + 4.0f || rel.y < -radius * 6.0f - 40.0f) return;
    bool inWater = info.w < 1.5f;
    float dip = inWater ? game.lure.z : 0.0f;
    float bob = inWater ? sin(time * 2.3f) * radius * 0.08f : 0.0f;
    float2 bodyCentre = centre + float2(0.0f, radius * 0.25f + dip * radius * 1.9f + bob);
    float waterline = centre.y + radius * 0.55f;
    float2 q = pixel - bodyCentre;
    float body = length(q / float2(1.0f, 1.25f)) - radius;
    float visible = inWater ? step(pixel.y, waterline) : 1.0f;
    float coverage = clamp(0.5f - body, 0.0f, 1.0f) * visible;
    float3 floatColor = q.y < 0.0f ? float3(0.85f, 0.08f, 0.04f) : float3(0.92f, 0.9f, 0.85f);
    float outline = clamp(1.0f - abs(body + 0.5f), 0.0f, 1.0f) * visible;
    // Antenna above the body.
    float antennaTop = bodyCentre.y - radius * 1.25f - max(radius * 1.6f, 5.0f);
    float antenna = (1.0f - smoothstep(0.6f, 1.3f, abs(q.x))) * step(antennaTop, pixel.y)
        * step(pixel.y, bodyCentre.y - radius) * visible;
    color = mix(color, floatColor, coverage);
    color = mix(color, float3(0.05f), outline * 0.6f);
    color = mix(color, float3(1.0f, 0.55f, 0.05f), antenna);

    // A marker above distant floats; a red "!" when the fish takes it.
    if (inWater) {
        // The marker bobs with every nibble so a bite can be anticipated.
        float2 marker = centre + float2(0.0f, -radius * 3.0f - 16.0f + 7.0f * dip);
        float2 m = pixel - marker;
        bool take = dip > 0.8f;
        if (take) {
            float pulse = 0.7f + 0.3f * sin(time * 18.0f);
            float bar = sdBox(m - float2(0.0f, -7.0f), float2(2.2f, 7.0f));
            float spot = length(m - float2(0.0f, 6.0f)) - 2.6f;
            float mark = clamp(0.5f - min(bar, spot), 0.0f, 1.0f);
            float halo = clamp(0.5f - (length(m - float2(0.0f, -2.0f)) - 13.0f), 0.0f, 1.0f);
            color = mix(color, float3(0.0f), halo * 0.35f);
            color = mix(color, float3(1.0f, 0.12f, 0.05f) * 1.4f * pulse, mark);
        } else {
            float tri = max(abs(m.x) * 0.9f + m.y * 0.5f - 4.0f, -m.y - 4.0f);
            float mark = clamp(0.5f - tri, 0.0f, 1.0f) * 0.75f;
            color = mix(color, mix(float3(1.0f, 0.92f, 0.7f), float3(1.0f, 0.55f, 0.2f),
                clamp(dip * 2.5f, 0.0f, 1.0f)), mark);
        }
    }
}

constant float3 speciesBack[4] = {float3(0.10f, 0.16f, 0.05f), float3(0.20f, 0.15f, 0.08f),
    float3(0.24f, 0.17f, 0.05f), float3(0.07f, 0.12f, 0.05f)};
constant float3 speciesBelly[4] = {float3(0.70f, 0.62f, 0.32f), float3(0.75f, 0.70f, 0.55f),
    float3(0.80f, 0.60f, 0.25f), float3(0.62f, 0.62f, 0.40f)};

void drawSplashAndLeap(thread float3 &color, float2 pixel, float2 resolution,
    device const GameState &game, float3 tint) {
    float aspect = resolution.x / resolution.y;
    float yaw = game.camera.x;
    // Spray from the last splash.
    float4 splash = game.splash;
    if (splash.z < 0.9f) {
        float3 base = float3(splash.x, 0.0f, splash.y);
        float3 c = worldToCamera(base, yaw);
        if (c.z > 0.5f) {
            float2 centre = cameraToUV(c, aspect) * resolution;
            float ppm = pixelsPerMetre(c.z, resolution.y);
            float reach = ppm * 1.2f * splash.w + 6.0f;
            float2 rel = pixel - centre;
            if (abs(rel.x) < reach && rel.y < 6.0f && rel.y > -reach * 1.4f) {
                float age = splash.z;
                float drops = 0.0f;
                for (int i = 0; i < 14; ++i) {
                    float a = hash01(uint(i) * 7919u + 17u) * 6.2831853f;
                    float speed = (0.6f + 1.6f * hash01(uint(i) * 104729u + 3u)) * splash.w;
                    float up = (1.6f + 2.4f * hash01(uint(i) * 1299709u + 11u)) * splash.w;
                    float height = up * age - 4.9f * age * age;
                    if (height < -0.02f) continue;
                    float3 q = base + float3(cos(a) * speed * age * 0.5f, height, sin(a) * speed * age * 0.5f);
                    float3 qc = worldToCamera(q, yaw);
                    float2 s = cameraToUV(qc, aspect) * resolution;
                    float size = max(0.05f * pixelsPerMetre(qc.z, resolution.y), 1.3f);
                    drops = max(drops, clamp(size - length(pixel - s) + 0.5f, 0.0f, 1.0f));
                }
                color = mix(color, float3(0.9f, 0.93f, 0.95f) * (0.5f + 0.6f * tint), drops * (1.0f - age / 0.9f));
            }
        }
    }
    // A leaping fish.
    if (game.flow.x == phasePlay && game.flow.z == modeFight && game.fight3.w >= 0.0f
        && game.counters.w < uint(fishSlots)) {
        Fish f = game.fish[game.counters.w];
        float t = clamp(game.fight3.w, 0.0f, 1.0f);
        float len = f.body.z;
        // Leaps are drawn side-on to the camera so they read at any heading.
        float2 view = normalize(f.pos.xy - float2(cameraPosition.x, cameraPosition.z));
        float2 side = float2(view.y, -view.x);
        float2 forward = dot(side, headingVector(f.pos.z)) >= 0.0f ? side : -side;
        len *= 1.3f;
        float height = (0.5f + 0.5f * f.aux.w) * 0.9f * sin(3.14159f * t);
        float3 centre = float3(f.pos.x + forward.x * (t - 0.5f) * 0.6f, height,
            f.pos.y + forward.y * (t - 0.5f) * 0.6f);
        float pitch = mix(0.9f, -0.9f, t);
        float3 axis = float3(forward.x * cos(pitch), sin(pitch), forward.y * cos(pitch));
        float3 head = centre + axis * 0.5f * len;
        float3 tail = centre - axis * 0.5f * len;
        float3 hc = worldToCamera(head, yaw);
        float3 tc = worldToCamera(tail, yaw);
        if (hc.z > 0.5f && tc.z > 0.5f) {
            float2 hs = cameraToUV(hc, aspect) * resolution;
            float2 ts = cameraToUV(tc, aspect) * resolution;
            int species = int(f.body.x);
            float halfWidth = max(speciesWidth[species] * len * pixelsPerMetre(0.5f * (hc.z + tc.z), resolution.y), 2.0f);
            float2 ab = hs - ts;
            float lenPx = max(length(ab), 1.0f);
            float2 along = ab / lenPx;
            float2 rel = pixel - 0.5f * (hs + ts);
            float a = dot(rel, along);
            float b = dot(rel, float2(-along.y, along.x));
            if (abs(a) < lenPx && abs(b) < max(lenPx, 2.0f * halfWidth)) {
                float e = length(float2(a / (0.5f * lenPx), b / halfWidth));
                float bodyShape = clamp((1.0f - e) * halfWidth + 0.5f, 0.0f, 1.0f);
                float tailX = -a - 0.42f * lenPx;
                float fin = (tailX > 0.0f && tailX < 0.2f * lenPx) ? clamp(tailX * 0.9f - abs(b) + 0.5f, 0.0f, 1.0f) : 0.0f;
                float shape = max(bodyShape, fin);
                float3 fishColor = mix(speciesBelly[species], speciesBack[species],
                    smoothstep(-halfWidth, halfWidth, b));
                float sheen = b / halfWidth + 0.2f;
                fishColor += 0.25f * exp(-sheen * sheen * 8.0f);
                color = mix(color, fishColor * (0.4f + 0.7f * tint), shape);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Text, HUD and screens, drawn in a 1440 x 900 design space. Text cells are
// multiples of 1.5 design units, i.e. whole pixels at the default 960 x 600.

float glyphDot(uint code, int column, int row) {
    if (code < 32u || code > 90u || column < 0 || column > 4 || row < 0 || row > 6) {
        return 0.0f;
    }
    uint bits = uint(fontRows[(code - 32u) * 7u + uint(row)]);
    return float((bits >> uint(4 - column)) & 1u);
}

float textCoverage(float2 p, float2 origin, float cell, int text) {
    int start = textRanges[text * 2];
    int count = textRanges[text * 2 + 1];
    float2 spot = (p - origin) / cell;
    if (spot.x < 0.0f || spot.y < 0.0f || spot.y >= 7.0f
        || spot.x >= float(count * 6)) return 0.0f;
    int column = int(spot.x);
    int character = column / 6;
    return glyphDot(uint(textPool[start + character]), column - character * 6,
        int(spot.y));
}

float textWidth(int text, float cell) {
    return (float(textRanges[text * 2 + 1]) * 6.0f - 1.0f) * cell;
}

uint digitCount(uint value) {
    uint digits = 1u;
    for (int i = 0; i < 9 && value >= 10u; ++i) {
        value /= 10u;
        digits += 1u;
    }
    return digits;
}

uint powerOfTen(int exponent) {
    uint value = 1u;
    for (int i = 0; i < 4 && i < exponent; ++i) value *= 10u;
    return value;
}

// ASCII code of character `index` of a fixed-point number with `decimals`
// digits after the point (decimals 0 prints a plain integer).
uint decimalChar(float value, int decimals, int index, thread int &count) {
    uint scale = powerOfTen(decimals);
    uint scaled = uint(min(max(value, 0.0f), 999999.0f) * float(scale) + 0.5f);
    uint whole = scaled / scale;
    uint fraction = scaled - whole * scale;
    int wholeDigits = int(digitCount(whole));
    count = wholeDigits + (decimals > 0 ? 1 + decimals : 0);
    if (index < wholeDigits) {
        uint v = whole;
        for (int k = 0; k < 9 && k < wholeDigits - 1 - index; ++k) v /= 10u;
        return 48u + v % 10u;
    }
    if (index == wholeDigits) return 46u;
    uint f = fraction;
    for (int k = 0; k < 4 && k < count - 1 - index; ++k) f /= 10u;
    return 48u + f % 10u;
}

float decimalCoverage(float2 p, float2 origin, float cell, float value, int decimals) {
    int count = 0;
    decimalChar(value, decimals, 0, count);
    float2 spot = (p - origin) / cell;
    if (spot.x < 0.0f || spot.y < 0.0f || spot.y >= 7.0f || spot.x >= float(count * 6)) return 0.0f;
    int column = int(spot.x);
    int index = column / 6;
    int unused = 0;
    return glyphDot(decimalChar(value, decimals, index, unused), column - index * 6, int(spot.y));
}

float decimalWidth(float value, int decimals, float cell) {
    int count = 0;
    decimalChar(value, decimals, 0, count);
    return (float(count) * 6.0f - 1.0f) * cell;
}

// Clock time HH:MM for an hour such as 13.5.
float hourCoverage(float2 p, float2 origin, float cell, float hour) {
    float2 spot = (p - origin) / cell;
    if (spot.x < 0.0f || spot.y < 0.0f || spot.y >= 7.0f || spot.x >= 30.0f) return 0.0f;
    uint minutes = uint(clamp(hour, 0.0f, 23.99f) * 60.0f);
    uint hours = minutes / 60u;
    minutes -= hours * 60u;
    int column = int(spot.x);
    int index = column / 6;
    uint code = 48u + hours / 10u;
    if (index == 1) code = 48u + hours % 10u;
    if (index == 2) code = 58u;
    if (index == 3) code = 48u + minutes / 10u;
    if (index == 4) code = 48u + minutes % 10u;
    return glyphDot(code, column - index * 6, int(spot.y));
}

constant float hourCells = 29.0f;

void drawText(thread float3 &color, float2 p, float2 origin, float cell, int text, float3 ink) {
    float shadow = textCoverage(p, origin + float2(cell * 0.5f), cell, text);
    color = mix(color, float3(0.0f), 0.6f * shadow);
    color = mix(color, ink, textCoverage(p, origin, cell, text));
}

void drawPlainText(thread float3 &color, float2 p, float2 origin, float cell, int text, float3 ink) {
    color = mix(color, ink, textCoverage(p, origin, cell, text));
}

void drawPlainDecimal(thread float3 &color, float2 p, float2 origin, float cell, float value,
    int decimals, float3 ink) {
    color = mix(color, ink, decimalCoverage(p, origin, cell, value, decimals));
}

void drawTextCentred(thread float3 &color, float2 p, float centreX, float y, float cell,
    int text, float3 ink) {
    drawText(color, p, float2(centreX - 0.5f * textWidth(text, cell), y), cell, text, ink);
}

void drawDecimal(thread float3 &color, float2 p, float2 origin, float cell, float value,
    int decimals, float3 ink) {
    float shadow = decimalCoverage(p, origin + float2(cell * 0.5f), cell, value, decimals);
    color = mix(color, float3(0.0f), 0.6f * shadow);
    color = mix(color, ink, decimalCoverage(p, origin, cell, value, decimals));
}

void drawHour(thread float3 &color, float2 p, float2 origin, float cell, float hour, float3 ink) {
    float shadow = hourCoverage(p, origin + float2(cell * 0.5f), cell, hour);
    color = mix(color, float3(0.0f), 0.6f * shadow);
    color = mix(color, ink, hourCoverage(p, origin, cell, hour));
}

// Dark rounded panel with a warm rim.
void panel(thread float3 &color, float2 p, float2 lower, float2 upper, float alpha) {
    float2 centre = 0.5f * (lower + upper);
    float d = sdRoundBox(p - centre, 0.5f * (upper - lower), 12.0f);
    if (d > 3.0f) return;
    float inside = clamp(0.5f - d, 0.0f, 1.0f);
    color = mix(color, float3(0.012f, 0.016f, 0.02f), inside * alpha);
    float rim = clamp(1.0f - abs(d + 1.5f), 0.0f, 1.0f);
    color = mix(color, float3(0.62f, 0.46f, 0.22f), rim * 0.8f);
}

// Wooden frame (generated wood) around a parchment or picture area.
void woodFrame(thread float3 &color, float2 p, float2 lower, float2 upper, float border,
    texture2d<float> wood, float3 inner, float3 tint) {
    float2 centre = 0.5f * (lower + upper);
    float2 halfSize = 0.5f * (upper - lower);
    float outer = sdRoundBox(p - centre, halfSize, 10.0f);
    if (outer > 8.0f) return;
    float shadow = clamp(1.0f - (outer - 2.0f) / 10.0f, 0.0f, 1.0f);
    color = mix(color, float3(0.0f), 0.45f * shadow * step(0.0f, outer));
    float innerD = sdRoundBox(p - centre, halfSize - float2(border), 4.0f);
    float inFrame = clamp(0.5f - outer, 0.0f, 1.0f);
    float3 grain = imageColor(wood, p / 420.0f) * (0.75f + 0.35f * tint);
    float bevel = clamp(1.0f - abs(innerD) / 4.0f, 0.0f, 1.0f);
    float3 frame = grain * (1.0f - 0.45f * bevel) + 0.08f * clamp(1.0f - abs(outer + 2.0f) / 2.0f, 0.0f, 1.0f);
    color = mix(color, frame, inFrame);
    color = mix(color, inner, clamp(0.5f - innerD, 0.0f, 1.0f));
}

void drawBar(thread float3 &color, float2 p, float2 origin, float2 size, float fraction,
    float3 fill) {
    float2 centre = origin + 0.5f * size;
    float d = sdRoundBox(p - centre, 0.5f * size, 0.5f * size.y);
    if (d > 2.0f) return;
    color = mix(color, float3(0.05f, 0.055f, 0.06f), clamp(0.5f - d, 0.0f, 1.0f) * 0.9f);
    float filled = step(p.x, origin.x + size.x * clamp(fraction, 0.0f, 1.0f));
    color = mix(color, fill, clamp(0.5f - (d + 2.0f), 0.0f, 1.0f) * filled);
    color = mix(color, float3(0.6f, 0.5f, 0.3f), clamp(1.0f - abs(d), 0.0f, 1.0f) * 0.6f);
}

int speciesText(int species) {
    if (species == 1) return textTrout;
    if (species == 2) return textCarp;
    if (species == 3) return textPike;
    return textPerch;
}

int dayText(uint day) {
    if (day == 1u) return textDay2;
    if (day == 2u) return textDay3;
    return textDay1;
}

int briefText(uint day) {
    if (day == 1u) return textBrief2;
    if (day == 2u) return textBrief3;
    return textBrief1;
}

float3 fishPicture(int species, float2 uv, texture2d<float> perch, texture2d<float> trout,
    texture2d<float> carp, texture2d<float> pike) {
    if (species == 1) return pictureColor(trout, uv);
    if (species == 2) return pictureColor(carp, uv);
    if (species == 3) return pictureColor(pike, uv);
    return pictureColor(perch, uv);
}

// "CATCH 3.45 OF 7.0 KG" and friends, top right.
void drawCatchPanel(thread float3 &color, float2 p, float2 size, device const GameState &game) {
    float right = size.x - 24.0f;
    float left = right - 420.0f;
    panel(color, p, float2(left, 20.0f), float2(right, 168.0f), 0.62f);
    if (p.x < left - 4.0f || p.y > 172.0f) return;
    float3 ink = float3(0.93f, 0.90f, 0.82f);
    float3 label = float3(0.75f, 0.72f, 0.62f);
    float3 accent = float3(1.0f, 0.78f, 0.35f);
    float x = left + 22.0f;
    drawText(color, p, float2(x, 36.0f), 3.0f, textCatch, label);
    float fx = right - 22.0f - decimalWidth(float(game.counters.y), 0, 3.0f);
    drawDecimal(color, p, float2(fx, 36.0f), 3.0f, float(game.counters.y), 0, ink);
    drawText(color, p, float2(fx - 14.0f - textWidth(textFish, 3.0f), 36.0f), 3.0f, textFish, label);
    float cell = 4.5f;
    float y = 62.0f;
    float vx = x;
    drawDecimal(color, p, float2(vx, y), cell, game.today.x, 2, accent);
    vx += decimalWidth(game.today.x, 2, cell) + 14.0f;
    drawText(color, p, float2(vx, y + 3.0f), 3.0f, textOf, ink);
    vx += textWidth(textOf, 3.0f) + 14.0f;
    drawDecimal(color, p, float2(vx, y), cell, game.dayInfo.x, 1, ink);
    vx += decimalWidth(game.dayInfo.x, 1, cell) + 12.0f;
    drawText(color, p, float2(vx, y + 3.0f), 3.0f, textKg, ink);
    float progress = game.today.x / max(game.dayInfo.x, 0.1f);
    float3 fill = progress >= 1.0f ? float3(1.0f, 0.75f, 0.2f) : float3(0.35f, 0.62f, 0.4f);
    drawBar(color, p, float2(x, 104.0f), float2(376.0f, 12.0f), progress, fill);
    drawText(color, p, float2(x, 134.0f), 3.0f, textScore, label);
    drawDecimal(color, p, float2(x + textWidth(textScore, 3.0f) + 16.0f, 131.0f), 4.5f, game.totals.y, 0, ink);
}

// Day name and the time of day, top left.
void drawDayPanel(thread float3 &color, float2 p, device const GameState &game, float time) {
    panel(color, p, float2(24.0f, 20.0f), float2(484.0f, 168.0f), 0.62f);
    if (p.x > 490.0f || p.y > 172.0f) return;
    float3 ink = float3(0.93f, 0.90f, 0.82f);
    float x = 46.0f;
    drawText(color, p, float2(x, 36.0f), 3.0f, textDay, float3(0.75f, 0.72f, 0.62f));
    float numberX = x + textWidth(textDay, 3.0f) + 12.0f;
    drawDecimal(color, p, float2(numberX, 36.0f), 3.0f,
        float(game.flow.y + 1u), 0, float3(0.75f, 0.72f, 0.62f));
    drawText(color, p, float2(numberX + 33.0f, 36.0f), 3.0f, dayText(game.flow.y), ink);
    float hour = currentHour(game);
    bool late = game.clock.x < 20.0f && game.flow.x == phasePlay;
    float flash = late ? 0.5f + 0.5f * sin(time * 8.0f) : 0.0f;
    float3 clockInk = mix(float3(1.0f, 0.86f, 0.55f), float3(1.0f, 0.3f, 0.15f), flash);
    drawHour(color, p, float2(x, 70.0f), 7.5f, hour, clockInk);
    // The day as a strip from start to end with a sun marker.
    float barWidth = 190.0f;
    float2 barOrigin = float2(x + 240.0f, 84.0f);
    float progress = clamp(1.0f - game.clock.x / max(game.dayInfo.w, 1.0f), 0.0f, 1.0f);
    drawBar(color, p, barOrigin, float2(barWidth, 10.0f), progress, float3(0.85f, 0.62f, 0.3f));
    float2 sun = barOrigin + float2(barWidth * progress, 5.0f);
    float sunD = length(p - sun) - 8.0f;
    color = mix(color, float3(1.0f, 0.82f, 0.4f), clamp(0.5f - sunD, 0.0f, 1.0f));
    drawHour(color, p, float2(barOrigin.x, 112.0f), 3.0f, game.dayInfo.y, float3(0.7f, 0.68f, 0.6f));
    drawHour(color, p, float2(barOrigin.x + barWidth - hourCells * 3.0f, 112.0f), 3.0f,
        game.dayInfo.z, float3(0.7f, 0.68f, 0.6f));
}

// Tension, fish strength, line and the reel gauge during a fight.
void drawFightHud(thread float3 &color, float2 p, float2 size, device const GameState &game,
    constant ProgramUniforms &u, float time) {
    float top = size.y - 270.0f;
    panel(color, p, float2(24.0f, top), float2(470.0f, size.y - 80.0f), 0.6f);
    float3 label = float3(0.75f, 0.72f, 0.62f);
    float3 ink = float3(0.93f, 0.90f, 0.82f);
    if (p.x < 500.0f && p.y > top - 6.0f) {
        float x = 46.0f;
        float tension = game.fight0.y;
        bool reeling = game.fight2.y > 0.04f;
        drawText(color, p, float2(x, top + 20.0f), 3.0f, textTension, label);
        float2 barOrigin = float2(x, top + 44.0f);
        float2 barSize = float2(400.0f, 22.0f);
        float2 centre = barOrigin + 0.5f * barSize;
        float d = sdRoundBox(p - centre, 0.5f * barSize, 6.0f);
        if (d < 2.0f) {
            float f = (p.x - barOrigin.x) / barSize.x * 1.2f;
            float3 zone = f < 0.75f ? float3(0.18f, 0.45f, 0.22f)
                : (f < 1.0f ? float3(0.62f, 0.48f, 0.12f) : float3(0.65f, 0.12f, 0.08f));
            color = mix(color, zone * 0.55f, clamp(0.5f - d, 0.0f, 1.0f));
            float lit = step(f, tension);
            color = mix(color, zone * 1.5f, clamp(0.5f - (d + 3.0f), 0.0f, 1.0f) * lit);
            color = mix(color, float3(0.6f, 0.5f, 0.3f), clamp(1.0f - abs(d), 0.0f, 1.0f) * 0.6f);
        }
        float needleX = barOrigin.x + barSize.x * clamp(tension / 1.2f, 0.0f, 1.0f);
        float needle = clamp(2.0f - abs(p.x - needleX), 0.0f, 1.0f)
            * step(barOrigin.y - 6.0f, p.y) * step(p.y, barOrigin.y + barSize.y + 6.0f);
        color = mix(color, float3(1.0f), needle);
        if (reeling && tension > 0.95f) {
            float flash = 0.5f + 0.5f * sin(time * 20.0f);
            drawText(color, p, float2(x + 230.0f, top + 20.0f), 3.0f, textEaseOff,
                mix(float3(1.0f, 0.35f, 0.2f), float3(1.0f, 0.9f, 0.6f), flash));
        } else if (game.fight2.z > 0.3f) {
            drawText(color, p, float2(x + 230.0f, top + 20.0f), 3.0f, textSideStrain,
                float3(0.55f, 0.95f, 0.55f));
        }
        drawText(color, p, float2(x, top + 88.0f), 3.0f, textStrength, label);
        float stamina = game.fight0.z;
        float3 strengthColor = mix(float3(0.45f, 0.55f, 0.65f), float3(0.95f, 0.45f, 0.18f),
            smoothstep(0.3f, 0.8f, stamina));
        float2 sOrigin = float2(x, top + 110.0f);
        drawBar(color, p, sOrigin, float2(400.0f, 14.0f), stamina, strengthColor);
        // Netting is possible below this mark.
        float markX = sOrigin.x + 400.0f * 0.42f;
        float mark = clamp(1.5f - abs(p.x - markX), 0.0f, 1.0f) * step(sOrigin.y - 6.0f, p.y)
            * step(p.y, sOrigin.y + 20.0f);
        color = mix(color, float3(0.95f, 0.95f, 0.8f), mark * 0.8f);
        drawText(color, p, float2(x, top + 150.0f), 3.0f, textLine, label);
        float lx = x + textWidth(textLine, 3.0f) + 16.0f;
        drawDecimal(color, p, float2(lx, top + 147.0f), 4.5f, game.fight0.x, 1, ink);
        lx += decimalWidth(game.fight0.x, 1, 4.5f) + 10.0f;
        drawText(color, p, float2(lx, top + 150.0f), 3.0f, textM, ink);
    }

    // Reel gauge on the right edge: where the crosshair sits sets the reel speed.
    float gx = size.x - 70.0f;
    float gTop = 220.0f;
    float gBottom = size.y - 230.0f;
    if (p.x > gx - 80.0f && p.y > gTop - 40.0f && p.y < gBottom + 40.0f) {
        float2 centre = float2(gx, 0.5f * (gTop + gBottom));
        float d = sdRoundBox(p - centre, float2(12.0f, 0.5f * (gBottom - gTop)), 10.0f);
        if (d < 3.0f) {
            float py = (p.y - gTop) / (gBottom - gTop);
            float reelAt = clamp((0.72f - py) / 0.52f, 0.0f, 1.0f);
            float3 zone = py < 0.72f ? mix(float3(0.15f, 0.35f, 0.2f), float3(0.35f, 0.9f, 0.4f), reelAt)
                : float3(0.25f, 0.25f, 0.27f);
            color = mix(color, zone, clamp(0.5f - d, 0.0f, 1.0f) * 0.85f);
            color = mix(color, float3(0.6f, 0.5f, 0.3f), clamp(1.0f - abs(d), 0.0f, 1.0f) * 0.7f);
        }
        float markerY = gTop + u.pointer.y * (gBottom - gTop);
        float2 m = p - float2(gx - 22.0f, markerY);
        float tri = max(abs(m.y) * 1.2f + m.x * 0.8f, -m.x - 14.0f);
        color = mix(color, float3(1.0f, 0.95f, 0.8f), clamp(0.5f - tri, 0.0f, 1.0f));
        drawTextCentred(color, p, gx, gTop - 30.0f, 3.0f, textReel, float3(0.55f, 0.95f, 0.55f));
        drawTextCentred(color, p, gx, gBottom + 14.0f, 3.0f, textHold, label);
    }
}

void drawCatchCard(thread float3 &color, float2 p, float2 size, device const GameState &game,
    texture2d<float> wood, texture2d<float> perch, texture2d<float> trout,
    texture2d<float> carp, texture2d<float> pike, float3 tint, float time) {
    float2 centre = 0.5f * size;
    float2 lower = centre - float2(440.0f, 230.0f);
    float2 upper = centre + float2(440.0f, 230.0f);
    float3 parchment = float3(0.80f, 0.70f, 0.50f);
    woodFrame(color, p, lower, upper, 22.0f, wood, parchment, float3(1.0f));
    if (p.x < lower.x || p.x > upper.x || p.y < lower.y || p.y > upper.y) return;
    int species = int(game.catchInfo.x);
    // The generated illustration, cropped to its middle band.
    float2 picLower = lower + float2(44.0f, 60.0f);
    float2 picSize = float2(420.0f, 315.0f);
    float2 local = (p - picLower) / picSize;
    if (local.x >= 0.0f && local.y >= 0.0f && local.x <= 1.0f && local.y <= 1.0f) {
        float2 uv = float2(mix(0.03f, 0.97f, local.x), mix(0.15f, 0.85f, local.y));
        color = fishPicture(species, uv, perch, trout, carp, pike);
    }
    float frameD = sdBox(p - (picLower + 0.5f * picSize), 0.5f * picSize);
    color = mix(color, float3(0.25f, 0.16f, 0.08f), clamp(1.5f - abs(frameD), 0.0f, 1.0f));
    float3 ink = float3(0.09f, 0.06f, 0.03f);
    float3 red = float3(0.45f, 0.12f, 0.04f);
    float x = picLower.x + picSize.x + 36.0f;
    float y = lower.y + 70.0f;
    drawPlainText(color, p, float2(x, y), 4.5f, speciesText(species), ink);
    drawPlainDecimal(color, p, float2(x, y + 64.0f), 9.0f, game.catchInfo.y, 2, red);
    drawPlainText(color, p, float2(x + decimalWidth(game.catchInfo.y, 2, 9.0f) + 18.0f, y + 85.0f), 4.5f,
        textKg, red);
    drawPlainText(color, p, float2(x, y + 160.0f), 4.5f, textPlus, ink);
    drawPlainDecimal(color, p, float2(x + 40.0f, y + 160.0f), 4.5f, game.catchInfo.z, 0, ink);
    drawPlainText(color, p, float2(x + 64.0f + decimalWidth(game.catchInfo.z, 0, 4.5f), y + 160.0f), 4.5f,
        textPoints, ink);
    float flags = game.catchInfo.w;
    float badgeY = y + 220.0f;
    if (fmod(flags, 2.0f) >= 1.0f) {
        drawPlainText(color, p, float2(x, badgeY), 4.5f, textTrophy, float3(0.6f, 0.35f, 0.02f));
        badgeY += 44.0f;
    }
    if (flags >= 2.0f) {
        drawPlainText(color, p, float2(x, badgeY), 3.0f, textBest, float3(0.2f, 0.3f, 0.12f));
    }
    float blink = 0.6f + 0.4f * sin(time * 4.0f);
    float hintWidth = textWidth(textHintCard, 3.0f);
    drawPlainText(color, p, float2(centre.x - 0.5f * hintWidth, upper.y - 52.0f), 3.0f, textHintCard,
        ink * blink);
}

void drawHud(thread float3 &color, float2 p, float2 size, device const GameState &game,
    constant ProgramUniforms &u, float2 resolution, float ui, float time) {
    drawDayPanel(color, p, game, time);
    drawCatchPanel(color, p, size, game);
    uint mode = game.flow.z;
    float3 hintInk = float3(0.92f, 0.9f, 0.82f);
    float hintY = size.y - 46.0f;
    if (mode == modeFight) {
        drawFightHud(color, p, size, game, u, time);
        if (game.fight2.w > 0.5f) {
            float pulse = 0.5f + 0.5f * sin(time * 9.0f);
            float netWidth = textWidth(textNet, 7.5f);
            panel(color, p, float2(0.5f * (size.x - netWidth) - 34.0f, 262.0f),
                float2(0.5f * (size.x + netWidth) + 34.0f, 352.0f), 0.6f);
            drawTextCentred(color, p, 0.5f * size.x, 282.0f, 7.5f, textNet,
                mix(float3(1.0f, 0.78f, 0.3f), float3(1.0f, 0.97f, 0.85f), pulse));
            drawTextCentred(color, p, 0.5f * size.x, hintY, 3.0f, textHintNet, hintInk);
        } else {
            drawTextCentred(color, p, 0.5f * size.x, hintY, 3.0f, textHintFight, hintInk);
        }
    } else if (mode == modeAim) {
        drawTextCentred(color, p, 0.5f * size.x, hintY, 3.0f, textHintAim, hintInk);
        // Distance label beside the reticle.
        float aspect = resolution.x / resolution.y;
        float3 c = worldToCamera(float3(game.aim.x, 0.0f, game.aim.y), game.camera.x);
        float2 spot = cameraToUV(c, aspect) * resolution / ui;
        float2 m = p - (spot + float2(0.0f, -26.0f));
        float pin = max(abs(m.x) * 0.9f + m.y * 0.5f - 6.0f, -m.y - 6.0f);
        color = mix(color, float3(1.0f, 0.9f, 0.65f), clamp(0.5f - pin, 0.0f, 1.0f) * 0.9f);
        float2 at = spot + float2(30.0f, -36.0f);
        drawDecimal(color, p, at, 3.0f, floor(game.aim.z + 0.5f), 0, float3(1.0f, 0.9f, 0.65f));
        drawText(color, p, at + float2(decimalWidth(floor(game.aim.z + 0.5f), 0, 3.0f) + 8.0f, 0.0f),
            3.0f, textM, float3(1.0f, 0.9f, 0.65f));
    } else if (mode == modeWait) {
        int hint = textHintWait;
        if (game.flightInfo.w < 0.5f) hint = textBaitStolen;
        drawTextCentred(color, p, 0.5f * size.x, hintY, 3.0f, hint, hintInk);
    }

    // Messages.
    if (game.message.y > 0.0f && game.message.x >= 0.0f) {
        int text = int(game.message.x);
        float fade = clamp(game.message.y / 0.4f, 0.0f, 1.0f);
        float cell = 6.0f;
        float width = textWidth(text, cell);
        float2 lower = float2(0.5f * (size.x - width) - 30.0f, 178.0f);
        float2 upper = float2(0.5f * (size.x + width) + 30.0f, 248.0f);
        if (p.y > 160.0f && p.y < 266.0f) {
            float3 before = color;
            panel(color, p, lower, upper, 0.55f);
            float3 ink = game.message.w >= 3.0f ? float3(1.0f, 0.45f, 0.3f)
                : (text == textFishOn || text == textTargetReached ? float3(1.0f, 0.85f, 0.4f)
                : float3(0.95f, 0.92f, 0.85f));
            drawTextCentred(color, p, 0.5f * size.x, 192.0f, cell, text, ink);
            color = mix(before, color, fade);
        }
    }
}

// Title, day briefing, results and the trip summary.
void drawScreens(thread float3 &color, float2 p, float2 size, device const GameState &game,
    texture2d<float> wood, texture2d<float> poster, texture2d<float> perch,
    texture2d<float> trout, texture2d<float> carp, texture2d<float> pike, float time) {
    uint phase = game.flow.x;
    float3 ink = float3(0.94f, 0.91f, 0.83f);
    float3 gold = float3(1.0f, 0.8f, 0.4f);
    float3 soft = float3(0.75f, 0.72f, 0.62f);
    float blink = 0.55f + 0.45f * sin(time * 4.0f);
    float cx = 0.5f * size.x;
    if (phase == phaseTitle) {
        color *= 0.55f;
        float2 lower = float2(50.0f, 170.0f);
        float2 upper = float2(480.0f, 600.0f);
        woodFrame(color, p, lower, upper, 20.0f, wood, float3(0.0f), float3(1.0f));
        float2 local = (p - (lower + 20.0f)) / (upper - lower - 40.0f);
        if (local.x >= 0.0f && local.y >= 0.0f && local.x <= 1.0f && local.y <= 1.0f) {
            color = pictureColor(poster, local);
        }
        float x = 540.0f;
        drawText(color, p, float2(x, 170.0f), 7.5f, textTitle, gold);
        drawText(color, p, float2(x, 248.0f), 3.0f, textSubtitle, ink);
        panel(color, p, float2(x - 20.0f, 300.0f), float2(size.x - 50.0f, 640.0f), 0.55f);
        int lines[7] = {textHow1, textHow2, textHow3, textHow4, textHow5, textHow6, textHow7};
        for (int i = 0; i < 7; ++i) {
            float y = 330.0f + 42.0f * float(i);
            float bullet = length(p - float2(x + 6.0f, y + 10.0f)) - 5.0f;
            color = mix(color, gold, clamp(0.5f - bullet, 0.0f, 1.0f));
            drawText(color, p, float2(x + 26.0f, y), 3.0f, lines[i], ink);
        }
        drawText(color, p, float2(x, 700.0f), 4.5f, textPressStart, gold * blink);
        return;
    }
    if (phase == phaseBriefing) {
        color *= 0.7f;
        float2 lower = float2(cx - 570.0f, 210.0f);
        float2 upper = float2(cx + 570.0f, 660.0f);
        panel(color, p, lower, upper, 0.72f);
        if (p.y < lower.y - 4.0f || p.y > upper.y + 4.0f) return;
        uint day = game.flow.y;
        float dayW = textWidth(textDay, 4.5f) + 14.0f + decimalWidth(float(day + 1u), 0, 4.5f);
        drawText(color, p, float2(cx - 0.5f * dayW, 240.0f), 4.5f, textDay, soft);
        drawDecimal(color, p, float2(cx - 0.5f * dayW + textWidth(textDay, 4.5f) + 14.0f, 240.0f), 4.5f,
            float(day + 1u), 0, soft);
        drawTextCentred(color, p, cx, 290.0f, 7.5f, dayText(day), gold);
        drawTextCentred(color, p, cx, 370.0f, 3.0f, briefText(day), ink);
        // LAND x.x KG OF FISH BEFORE HH:MM
        float cell = 4.5f;
        float w = textWidth(textLand, cell) + decimalWidth(game.dayInfo.x, 1, cell)
            + textWidth(textKgBefore, cell) + hourCells * cell + 3.0f * 22.0f;
        float lx = cx - 0.5f * w;
        drawText(color, p, float2(lx, 430.0f), cell, textLand, ink);
        lx += textWidth(textLand, cell) + 22.0f;
        drawDecimal(color, p, float2(lx, 430.0f), cell, game.dayInfo.x, 1, gold);
        lx += decimalWidth(game.dayInfo.x, 1, cell) + 22.0f;
        drawText(color, p, float2(lx, 430.0f), cell, textKgBefore, ink);
        lx += textWidth(textKgBefore, cell) + 22.0f;
        drawHour(color, p, float2(lx, 430.0f), cell, game.dayInfo.z, gold);
        // Species in the lake today.
        float names = textWidth(textInLake, 3.0f);
        for (int s = 0; s < 4; ++s) {
            if (daySpecies[day * 4u + uint(s)] > 0.0f) names += textWidth(speciesText(s), 3.0f) + 30.0f;
        }
        float nx = cx - 0.5f * names;
        drawText(color, p, float2(nx, 500.0f), 3.0f, textInLake, soft);
        nx += textWidth(textInLake, 3.0f) + 30.0f;
        for (int s = 0; s < 4; ++s) {
            if (daySpecies[day * 4u + uint(s)] <= 0.0f) continue;
            drawText(color, p, float2(nx, 500.0f), 3.0f, speciesText(s), ink);
            nx += textWidth(speciesText(s), 3.0f) + 30.0f;
        }
        drawTextCentred(color, p, cx, 590.0f, 4.5f, textPressFish, gold * blink);
        return;
    }
    if (phase == phaseDayDone || phase == phaseDayFailed) {
        color *= 0.6f;
        bool done = phase == phaseDayDone;
        float2 lower = float2(cx - 430.0f, 200.0f);
        float2 upper = float2(cx + 430.0f, 680.0f);
        panel(color, p, lower, upper, 0.75f);
        if (p.y < lower.y - 4.0f || p.y > upper.y + 4.0f) return;
        int heading = textDayOver;
        if (done) heading = textDayComplete;
        drawTextCentred(color, p, cx, 236.0f, 7.5f, heading,
            done ? gold : float3(1.0f, 0.5f, 0.35f));
        float x = cx - 330.0f;
        float vx = cx + 120.0f;
        drawText(color, p, float2(x, 340.0f), 4.5f, textFishCaught, soft);
        drawDecimal(color, p, float2(vx, 340.0f), 4.5f, float(game.counters.y), 0, ink);
        drawText(color, p, float2(x, 392.0f), 4.5f, textWeight, soft);
        drawDecimal(color, p, float2(vx, 392.0f), 4.5f, game.today.x, 2, ink);
        drawText(color, p, float2(vx + decimalWidth(game.today.x, 2, 4.5f) + 16.0f, 392.0f), 4.5f, textKg, ink);
        drawText(color, p, float2(x, 444.0f), 4.5f, textBiggest, soft);
        if (game.today.z > 0.0f) {
            drawDecimal(color, p, float2(vx, 444.0f), 4.5f, game.today.z, 2, ink);
            drawText(color, p, float2(vx + decimalWidth(game.today.z, 2, 4.5f) + 16.0f, 444.0f), 4.5f, textKg, ink);
        } else {
            drawText(color, p, float2(vx, 444.0f), 4.5f, textNone, ink);
        }
        drawText(color, p, float2(x, 496.0f), 4.5f, textScore, soft);
        drawDecimal(color, p, float2(vx, 496.0f), 4.5f, game.today.y, 0, ink);
        if (!done) {
            drawText(color, p, float2(x, 548.0f), 4.5f, textNeeded, float3(1.0f, 0.6f, 0.45f));
            drawDecimal(color, p, float2(vx, 548.0f), 4.5f, game.dayInfo.x, 1, float3(1.0f, 0.6f, 0.45f));
            drawText(color, p, float2(vx + decimalWidth(game.dayInfo.x, 1, 4.5f) + 16.0f, 548.0f), 4.5f,
                textKg, float3(1.0f, 0.6f, 0.45f));
        }
        int prompt = textRetry;
        if (done) prompt = textNextDay;
        drawTextCentred(color, p, cx, 622.0f, 3.0f, prompt, gold * blink);
        return;
    }
    if (phase == phaseVictory) {
        color *= 0.55f;
        float2 lower = float2(cx - 540.0f, 140.0f);
        float2 upper = float2(cx + 540.0f, 770.0f);
        panel(color, p, lower, upper, 0.78f);
        if (p.y < lower.y - 4.0f || p.y > upper.y + 4.0f) return;
        drawTextCentred(color, p, cx, 172.0f, 7.5f, textVictory, gold);
        float x = cx - 480.0f;
        float vx = cx - 160.0f;
        drawText(color, p, float2(x, 300.0f), 4.5f, textTripWeight, soft);
        drawDecimal(color, p, float2(vx, 300.0f), 4.5f, game.totals.x, 1, ink);
        drawText(color, p, float2(vx + decimalWidth(game.totals.x, 1, 4.5f) + 16.0f, 300.0f), 4.5f, textKg, ink);
        drawText(color, p, float2(x, 356.0f), 4.5f, textFishCaught, soft);
        drawDecimal(color, p, float2(vx, 356.0f), 4.5f, float(game.counters.z), 0, ink);
        drawText(color, p, float2(x, 412.0f), 4.5f, textFinalScore, soft);
        drawDecimal(color, p, float2(vx, 406.0f), 6.0f, game.totals.y, 0, gold);
        float score = game.totals.y;
        int rank = textRank1;
        if (score >= 2500.0f) rank = textRank2;
        if (score >= 5000.0f) rank = textRank3;
        if (score >= 8000.0f) rank = textRank4;
        drawTextCentred(color, p, cx, 588.0f, 3.0f, textRank, soft);
        drawTextCentred(color, p, cx, 630.0f, 7.5f, rank, gold);
        // The biggest fish of the trip.
        float2 picLower = float2(cx + 150.0f, 290.0f);
        float2 picSize = float2(320.0f, 240.0f);
        drawText(color, p, float2(picLower.x, 262.0f), 3.0f, textBiggest, soft);
        if (game.totals.z > 0.0f) {
            float2 local = (p - picLower) / picSize;
            if (local.x >= 0.0f && local.y >= 0.0f && local.x <= 1.0f && local.y <= 1.0f) {
                float2 uv = float2(mix(0.03f, 0.97f, local.x), mix(0.15f, 0.85f, local.y));
                color = fishPicture(int(game.totals.w), uv, perch, trout, carp, pike);
            }
            float frameD = sdBox(p - (picLower + 0.5f * picSize), 0.5f * picSize);
            color = mix(color, float3(0.62f, 0.46f, 0.22f), clamp(2.0f - abs(frameD), 0.0f, 1.0f));
            float ny = picLower.y + picSize.y + 18.0f;
            drawText(color, p, float2(picLower.x, ny), 3.0f, speciesText(int(game.totals.w)), ink);
            float kx = picLower.x + textWidth(speciesText(int(game.totals.w)), 3.0f) + 20.0f;
            drawDecimal(color, p, float2(kx, ny), 3.0f, game.totals.z, 2, gold);
            drawText(color, p, float2(kx + decimalWidth(game.totals.z, 2, 3.0f) + 12.0f, ny), 3.0f, textKg, gold);
        } else {
            drawText(color, p, float2(picLower.x, 300.0f), 4.5f, textNone, ink);
        }
        drawTextCentred(color, p, cx, 714.0f, 4.5f, textAgain, gold * blink);
    }
}

// ---------------------------------------------------------------------------
// Present pass

fragment float4 lakeFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> panoramaTexture [[texture(1)]],
    texture2d<float> woodTexture [[texture(2)]],
    texture2d<float> perchTexture [[texture(3)]],
    texture2d<float> troutTexture [[texture(4)]],
    texture2d<float> carpTexture [[texture(5)]],
    texture2d<float> pikeTexture [[texture(6)]],
    texture2d<float> posterTexture [[texture(7)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 pixel = in.uv * resolution;
    float time = game.clock.w;
    float hour = currentHour(game);
    float3 tint = lightTint(hour);

    float3 color = shadeScene(in.uv, resolution, game, panoramaTexture, woodTexture, time);
    drawSplashAndLeap(color, pixel, resolution, game, tint);
    drawLine(color, pixel, resolution, game, tint);
    drawFloat(color, pixel, resolution, game, time);
    drawRod(color, pixel, resolution, game, tint);

    // Gentle vignette.
    float2 centred = in.uv - 0.5f;
    color *= 1.0f - 0.35f * dot(centred, centred);

    // HUD in a 1440 x 900 design space.
    float ui = min(resolution.x / 1440.0f, resolution.y / 900.0f);
    float2 design = pixel / ui;
    float2 designSize = resolution / ui;
    uint phase = game.flow.x;
    if (phase == phasePlay) {
        drawHud(color, design, designSize, game, u, resolution, ui, time);
        if (game.flow.z == modeCard) {
            color *= 0.45f;
            drawCatchCard(color, design, designSize, game, woodTexture, perchTexture,
                troutTexture, carpTexture, pikeTexture, tint, time);
        }
    }
    drawScreens(color, design, designSize, game, woodTexture, posterTexture, perchTexture,
        troutTexture, carpTexture, pikeTexture, time);

    // Soft highlight roll-off, then the display transfer.
    float3 lit = max(color, float3(0.0f));
    float3 rolled = 0.8f + 0.2f * (1.0f - exp(-(lit - 0.8f) * 5.0f));
    float3 mapped = select(lit, rolled, lit > 0.8f);
    float3 srgb = select(1.055f * pow(mapped, float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

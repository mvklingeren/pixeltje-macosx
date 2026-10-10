#include <metal_stdlib>
using namespace metal;

// Bramblegate Keep: an isometric tower-defence game for the generic GPU Program
// node. Goblins, hounds, armoured brutes, bats and finally a troll king march
// along a cobbled road across a diorama board towards the keep. The player
// moves the Trackpad cursor and clicks with Action (Space): pick a tower card,
// click grass to build, click a tower to upgrade it, or sell it.
//
// Passes (see the workflow's program JSON):
//   initialize: initializeKeep (one thread) sets up the game state, and
//               prepareAtlas (one thread per atlas texel) box-filters the six
//               generated material textures into a prefiltered atlas.
//   tick:       advanceKeep (one thread) runs input, waves, foes, towers,
//               shots and effects.
//   present:    fullscreenVertex + keepFragment ray-cast the board with an
//               orthographic isometric camera and draw the HUD in one
//               clear-and-replace pass.
//
// Time: during a live preview pointer.w carries the wall time between ticks
// (capped at 0.1 s); saved and replayed calls use the fixed step.

struct ProgramUniforms {
    float4 resolutionTime; // width, height, frame time, fixed step
    uint4 frameSeed;       // frame index, seed low word, seed high word, reserved
    float4 parameters0;    // startGold, startLives, enemyHealth, breakSeconds
    float4 parameters1;    // firstBreakSeconds, unused x3
    float4 parameters2;
    float4 parameters3;
    float4 pointer;        // normalized Trackpad X/Y, action count, live frame interval
};

// Seconds simulated by one tick.
float tickSeconds(constant ProgramUniforms &u) {
    return min(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w, 0.1f);
}

constant int gridSize = 14;
constant int cellCount = 196;
constant int maxEnemies = 48;
constant int maxTowers = 40;
constant int maxShots = 48;
constant int maxEffects = 32;
constant int waveCount = 10;

// Cell contents. Values of 16 and above hold a tower: 16 + tower slot.
constant uint cellGrass = 0u;
constant uint cellRoad = 1u;
constant uint cellKeep = 2u;
constant uint cellTree = 3u;
constant uint cellRock = 4u;
constant uint cellPine = 5u;
constant uint cellTowerBase = 16u;

// Screens.
constant float screenTitle = 0.0f;
constant float screenPlaying = 1.0f;
constant float screenVictory = 2.0f;
constant float screenDefeat = 3.0f;

// Hover targets.
constant float hoverNone = 0.0f;
constant float hoverCell = 1.0f;
constant float hoverCard = 2.0f;
constant float hoverCall = 3.0f;
constant float hoverSpeed = 4.0f;

// Hover verdicts for a board cell.
constant float verdictBlocked = 0.0f;   // road, keep, tree or rock
constant float verdictBuild = 1.0f;     // free grass, affordable
constant float verdictBuildPoor = 2.0f; // free grass, too expensive
constant float verdictUpgrade = 3.0f;   // own tower, affordable upgrade
constant float verdictUpgradePoor = 4.0f;
constant float verdictMaxLevel = 5.0f;
constant float verdictSell = 6.0f;      // sell tool over a tower
constant float verdictNoSell = 7.0f;    // sell tool over anything else
constant float verdictRoad = 8.0f;      // road cell (for the hint)
constant float verdictKeep = 9.0f;      // keep cell (for the hint)

struct Enemy {
    float4 body;    // world x, flight height y, world z, heading (radians, 0 = +x)
    float4 stats;   // type (-1 = free slot), hit points, maximum hit points, distance along the road
    float4 status;  // slow seconds left, slow fraction, hit flash seconds, walk phase
    float4 extra;   // sideways offset from the road centre, unused x3
};

struct Tower {
    float4 place;   // cell x, cell z, type (-1 = free slot), level 1-3
    float4 fire;    // reload seconds left, aim heading, shot flash seconds, gold spent
};

struct Shot {
    float4 pos;     // world position, kind (-1 = free, 0 = arrow, 1 = shell)
    float4 vel;     // world velocity, target enemy slot (arrows)
    float4 info;    // damage, splash radius, age, flight time (shells)
};

struct Effect {
    float4 pos;     // world position, kind (-1 free, 0 blast, 1 frost ring, 2 puff, 3 gold popup, 4 dust)
    float4 info;    // age, duration, value (radius or gold), unused
};

struct GameState {
    float4 mode;      // screen, seconds on this screen, play seconds, game speed (1 or 2)
    float4 economy;   // gold, lives, score, foes defeated
    float4 wave;      // wave number (0 before the first), seconds since its start, break countdown, running (0/1)
    float4 input;     // last action count, selected tool (0 archer, 1 cannon, 2 frost, 3 sell), pointer design x, y
    float4 hover;     // target, cell x or card index, cell z, verdict
    float4 notice;    // message text (-1 none), message seconds, banner wave, banner seconds
    float4 flashes;   // keep hit flash, gold warning flash, last gold gain, gold gain seconds
    float4 spawn[3];  // per wave group: foes spawned so far, unused x3
    float4 settings;  // start gold, start lives, enemy health multiplier, break seconds
    uint4 counters;   // random state, waves cleared, foes leaked, best score this run
    Enemy enemies[48];
    Tower towers[40];
    Shot shots[48];
    Effect effects[32];
    uint cells[196];
};

// Size: 12 float4/uint4 header members (192 bytes) + 48 Enemy of 4 float4
// (3,072) + 40 Tower of 2 float4 (1,280) + 48 Shot of 3 float4 (2,304)
// + 32 Effect of 2 float4 (1,024) + 196 uint cells (784) = 8,656 bytes.
// Every vector member is 16-byte aligned and 8,656 is a multiple of 16, so
// there is no padding. The program declares the buffer with 16,384 bytes.

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

// ---------------------------------------------------------------------------
// Game data

// Road centre line from the spawn point on the back-right edge to the
// keep gate. Cells are one world unit; the board spans x, z = 0..14.
constant float2 roadPoints[9] = {
    float2(10.5f, 0.0f), float2(10.5f, 2.5f), float2(3.5f, 2.5f),
    float2(3.5f, 6.5f), float2(10.5f, 6.5f), float2(10.5f, 10.5f),
    float2(5.5f, 10.5f), float2(5.5f, 12.5f), float2(2.0f, 12.5f)
};
constant float roadTotal = 35.0f;
constant float roadHalfWidth = 0.42f;

// Decorations: cell x, cell z, kind (3 tree, 4 rock, 5 pine).
constant int decorationCount = 22;
constant int3 decorations[22] = {
    int3(0, 0, 5), int3(1, 0, 5), int3(0, 1, 5), int3(2, 0, 3),
    int3(13, 0, 5), int3(12, 0, 3), int3(13, 1, 5), int3(7, 0, 4),
    int3(0, 5, 3), int3(0, 7, 5), int3(1, 9, 4), int3(0, 10, 3),
    int3(13, 5, 4), int3(13, 8, 3), int3(12, 12, 3), int3(13, 12, 5),
    int3(13, 13, 3), int3(12, 13, 5), int3(11, 13, 3), int3(8, 13, 4),
    int3(7, 4, 4), int3(8, 8, 4)
};

// Enemy types: 0 goblin, 1 hound, 2 brute, 3 bat (flies), 4 troll king.
constant float enemyHealthTable[5] = {36.0f, 24.0f, 125.0f, 38.0f, 1320.0f};
constant float enemySpeedTable[5] = {1.2f, 2.0f, 0.75f, 1.55f, 0.5f};
constant float enemyBountyTable[5] = {4.0f, 4.0f, 10.0f, 6.0f, 120.0f};
constant float enemyArmourTable[5] = {0.0f, 0.0f, 4.0f, 0.0f, 6.0f};
constant float enemyLeakTable[5] = {1.0f, 1.0f, 2.0f, 1.0f, 10.0f};
// Drawing scale of each foe model and its bounding radius at that scale.
constant float enemyScaleTable[5] = {1.25f, 1.25f, 1.25f, 1.45f, 1.1f};
constant float enemyBoundTable[5] = {0.43f, 0.45f, 0.53f, 0.64f, 0.73f};
constant float enemyAimHeightTable[5] = {0.32f, 0.25f, 0.4f, 0.0f, 0.55f};
constant float batFlightHeight = 0.95f;

// Tower tables, index type * 3 + level - 1. Types: 0 archer, 1 cannon, 2 frost.
constant float towerRangeTable[9] = {2.6f, 2.95f, 3.3f, 2.3f, 2.55f, 2.85f, 2.1f, 2.35f, 2.6f};
constant float towerDamageTable[9] = {10.0f, 17.0f, 27.0f, 26.0f, 44.0f, 70.0f, 4.0f, 7.0f, 11.0f};
constant float towerReloadTable[9] = {0.7f, 0.58f, 0.48f, 1.9f, 1.7f, 1.5f, 1.25f, 1.1f, 0.95f};
constant float towerSplashTable[9] = {0.0f, 0.0f, 0.0f, 0.95f, 1.05f, 1.2f, 0.0f, 0.0f, 0.0f};
constant float towerSlowTable[9] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.38f, 0.48f, 0.58f};
// Gold to build (level 1) or to upgrade to level 2 and 3.
constant float towerCostTable[9] = {50.0f, 60.0f, 90.0f, 80.0f, 90.0f, 130.0f, 65.0f, 70.0f, 100.0f};

// Waves: three groups each of (type, count, seconds between foes, start delay);
// a negative type marks an unused group.
constant float4 waveTable[30] = {
    float4(0.0f, 10.0f, 1.3f, 0.0f), float4(-1.0f, 0.0f, 1.0f, 0.0f), float4(-1.0f, 0.0f, 1.0f, 0.0f),
    float4(0.0f, 12.0f, 1.1f, 0.0f), float4(1.0f, 5.0f, 1.0f, 8.0f), float4(-1.0f, 0.0f, 1.0f, 0.0f),
    float4(1.0f, 12.0f, 0.7f, 0.0f), float4(0.0f, 8.0f, 1.0f, 5.0f), float4(-1.0f, 0.0f, 1.0f, 0.0f),
    float4(2.0f, 5.0f, 2.4f, 0.0f), float4(0.0f, 12.0f, 0.9f, 3.0f), float4(-1.0f, 0.0f, 1.0f, 0.0f),
    float4(3.0f, 10.0f, 1.0f, 0.0f), float4(0.0f, 10.0f, 0.9f, 4.0f), float4(-1.0f, 0.0f, 1.0f, 0.0f),
    float4(2.0f, 8.0f, 1.8f, 0.0f), float4(1.0f, 14.0f, 0.6f, 6.0f), float4(-1.0f, 0.0f, 1.0f, 0.0f),
    float4(3.0f, 16.0f, 0.7f, 0.0f), float4(2.0f, 6.0f, 2.0f, 5.0f), float4(-1.0f, 0.0f, 1.0f, 0.0f),
    float4(0.0f, 24.0f, 0.45f, 0.0f), float4(1.0f, 14.0f, 0.6f, 6.0f), float4(2.0f, 6.0f, 1.8f, 10.0f),
    float4(2.0f, 12.0f, 1.4f, 0.0f), float4(3.0f, 16.0f, 0.7f, 4.0f), float4(1.0f, 10.0f, 0.6f, 12.0f),
    float4(4.0f, 1.0f, 1.0f, 8.0f), float4(2.0f, 12.0f, 1.5f, 0.0f), float4(3.0f, 14.0f, 0.8f, 4.0f)
};

float waveHealthScale(float wave) {
    float w = max(wave - 1.0f, 0.0f);
    return 1.0f + 0.13f * w + 0.015f * w * w;
}

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

// ---------------------------------------------------------------------------
// Small math helpers

float segmentDistance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6f), 0.0f, 1.0f);
    return length(p - a - ab * t);
}

float sdBox(float2 q, float2 halfSize) {
    float2 d = abs(q) - halfSize;
    return length(max(d, float2(0.0f))) + min(max(d.x, d.y), 0.0f);
}

float sdRoundBox(float2 q, float2 halfSize, float radius) {
    return sdBox(q, halfSize - float2(radius)) - radius;
}

// Choices between program-scope constants go through these helpers instead of
// a ternary operator on the constants themselves.
int pickInt(bool first, int a, int b) {
    if (first) return a;
    return b;
}

float pickFloat(bool first, float a, float b) {
    if (first) return a;
    return b;
}

float3 pickColour(bool first, float3 a, float3 b) {
    if (first) return a;
    return b;
}

// ---------------------------------------------------------------------------
// Isometric camera. An orthographic camera looks down at 30 degrees along the
// board diagonal, so a cell is a 2:1 diamond. All layout uses a 960 x 600
// design space that is scaled and centred into the output.

constant float designWidth = 960.0f;
constant float designHeight = 600.0f;
constant float boardScale = 44.0f;      // design units per world unit across the screen
constant float boardCentreX = 480.0f;
constant float boardCentreY = 324.0f;
constant float3 boardCentre = float3(7.0f, 0.0f, 7.0f);
constant float3 cameraRight = float3(0.70710678f, 0.0f, -0.70710678f);
constant float3 cameraUp = float3(-0.35355339f, 0.8660254f, -0.35355339f);
constant float3 viewDirection = float3(-0.61237244f, -0.5f, -0.61237244f);
constant float boardDepth = 0.6f;
constant float objectCeiling = 2.95f;  // nothing on the board is taller

float designScale(float2 resolution) {
    return min(resolution.x / designWidth, resolution.y / designHeight);
}

float2 toDesign(float2 pixel, float2 resolution) {
    float s = designScale(resolution);
    float2 offset = 0.5f * (resolution - s * float2(designWidth, designHeight));
    return (pixel - offset) / s;
}

float3 rayOrigin(float2 design) {
    float sx = (design.x - boardCentreX) / boardScale;
    float sy = (boardCentreY - design.y) / boardScale;
    return boardCentre + cameraRight * sx + cameraUp * sy - viewDirection * 30.0f;
}

float2 projectToDesign(float3 p) {
    float3 q = p - boardCentre;
    return float2(boardCentreX + boardScale * dot(q, cameraRight),
        boardCentreY - boardScale * dot(q, cameraUp));
}

// ---------------------------------------------------------------------------
// Road

float roadDistance(float2 p) {
    float d = 1000.0f;
    for (int i = 0; i < 8; ++i) {
        d = min(d, segmentDistance(p, roadPoints[i], roadPoints[i + 1]));
    }
    return d;
}

// Position on the road `along` units from the spawn point, shifted sideways by
// `side`. Near corners the sideways direction blends between the two segments
// so foes walk around the bend instead of jumping.
float3 roadPosition(float along, float side, thread float &heading) {
    float start = 0.0f;
    float2 point = roadPoints[8];
    float2 direction = float2(-1.0f, 0.0f);
    float2 blended = direction;
    for (int i = 0; i < 8; ++i) {
        float2 a = roadPoints[i];
        float2 b = roadPoints[i + 1];
        float len = length(b - a);
        if (along <= start + len || i == 7) {
            direction = (b - a) / len;
            float t = clamp(along - start, 0.0f, len);
            point = a + direction * t;
            blended = direction;
            if (i < 7 && t > len - 0.4f) {
                float2 next = normalize(roadPoints[i + 2] - b);
                float w = smoothstep(len - 0.4f, len, t);
                blended = normalize(mix(direction, next, 0.5f * w));
            } else if (i > 0 && t < 0.4f) {
                float2 previous = normalize(a - roadPoints[i - 1]);
                float w = smoothstep(0.0f, 0.4f, t);
                blended = normalize(mix(previous, direction, 0.5f + 0.5f * w));
            }
            break;
        }
        start += len;
    }
    heading = atan2(blended.y, blended.x);
    float2 normal = float2(-blended.y, blended.x);
    return float3(point.x + normal.x * side, 0.0f, point.y + normal.y * side);
}

// Tower table index for a type and level.
int towerIndex(float type, float tier) {
    return clamp(int(type), 0, 2) * 3 + clamp(int(tier), 1, 3) - 1;
}

int enemyType(float type) {
    return clamp(int(type), 0, 4);
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
    0x04, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00,  // "'"
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '('
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ')'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '*'
    0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00,  // '+'
    0x00, 0x00, 0x00, 0x00, 0x0C, 0x04, 0x08,  // ','
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
    0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04,  // '?'
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
constant uchar textPool[1359] = {
    66, 82, 65, 77, 66, 76, 69, 71, 65, 84, 69, 32, 75, 69, 69, 80,
    72, 79, 76, 68, 32, 84, 72, 69, 32, 82, 79, 65, 68, 32, 84, 79,
    32, 84, 72, 69, 32, 75, 69, 69, 80, 32, 70, 79, 82, 32, 84, 69,
    78, 32, 87, 65, 86, 69, 83, 68, 82, 65, 71, 32, 84, 72, 69, 32,
    67, 85, 82, 83, 79, 82, 32, 45, 32, 80, 82, 69, 83, 83, 32, 83,
    80, 65, 67, 69, 32, 84, 79, 32, 67, 76, 73, 67, 75, 80, 73, 67,
    75, 32, 65, 32, 84, 79, 87, 69, 82, 32, 67, 65, 82, 68, 44, 32,
    84, 72, 69, 78, 32, 67, 76, 73, 67, 75, 32, 71, 82, 65, 83, 83,
    32, 84, 79, 32, 66, 85, 73, 76, 68, 67, 76, 73, 67, 75, 32, 79,
    78, 69, 32, 79, 70, 32, 89, 79, 85, 82, 32, 84, 79, 87, 69, 82,
    83, 32, 84, 79, 32, 85, 80, 71, 82, 65, 68, 69, 32, 73, 84, 65,
    82, 67, 72, 69, 82, 83, 32, 72, 73, 84, 32, 65, 78, 89, 84, 72,
    73, 78, 71, 44, 32, 67, 65, 78, 78, 79, 78, 83, 32, 83, 80, 76,
    65, 83, 72, 32, 84, 72, 69, 32, 71, 82, 79, 85, 78, 68, 70, 82,
    79, 83, 84, 32, 84, 79, 87, 69, 82, 83, 32, 83, 76, 79, 87, 32,
    69, 86, 69, 82, 89, 32, 70, 79, 69, 32, 65, 82, 79, 85, 78, 68,
    32, 84, 72, 69, 77, 75, 73, 76, 76, 83, 32, 80, 65, 89, 32, 71,
    79, 76, 68, 32, 45, 32, 69, 86, 69, 82, 89, 32, 70, 79, 69, 32,
    65, 84, 32, 84, 72, 69, 32, 71, 65, 84, 69, 32, 67, 79, 83, 84,
    83, 32, 76, 73, 86, 69, 83, 80, 82, 69, 83, 83, 32, 83, 80, 65,
    67, 69, 32, 84, 79, 32, 66, 69, 71, 73, 78, 83, 67, 79, 82, 69,
    87, 65, 86, 69, 79, 70, 78, 69, 88, 84, 32, 87, 65, 86, 69, 32,
    73, 78, 67, 65, 76, 76, 32, 78, 79, 87, 70, 79, 69, 83, 32, 76,
    69, 70, 84, 65, 82, 67, 72, 69, 82, 67, 65, 78, 78, 79, 78, 70,
    82, 79, 83, 84, 83, 69, 76, 76, 65, 82, 67, 72, 69, 82, 32, 84,
    79, 87, 69, 82, 67, 65, 78, 78, 79, 78, 32, 84, 79, 87, 69, 82,
    70, 82, 79, 83, 84, 32, 84, 79, 87, 69, 82, 83, 69, 76, 76, 32,
    84, 79, 87, 69, 82, 83, 70, 65, 83, 84, 32, 65, 82, 82, 79, 87,
    83, 44, 32, 65, 73, 82, 32, 65, 78, 68, 32, 71, 82, 79, 85, 78,
    68, 83, 80, 76, 65, 83, 72, 73, 78, 71, 32, 83, 72, 69, 76, 76,
    83, 44, 32, 78, 79, 32, 66, 65, 84, 83, 73, 67, 69, 32, 80, 85,
    76, 83, 69, 32, 83, 76, 79, 87, 83, 32, 65, 76, 76, 32, 78, 69,
    65, 82, 32, 73, 84, 67, 76, 73, 67, 75, 32, 65, 32, 84, 79, 87,
    69, 82, 32, 84, 79, 32, 83, 69, 76, 76, 32, 73, 84, 82, 69, 70,
    85, 78, 68, 83, 32, 55, 48, 37, 32, 79, 70, 32, 73, 84, 83, 32,
    67, 79, 83, 84, 67, 76, 73, 67, 75, 32, 84, 79, 32, 66, 85, 73,
    76, 68, 32, 70, 79, 82, 67, 76, 73, 67, 75, 32, 84, 79, 32, 85,
    80, 71, 82, 65, 68, 69, 32, 70, 79, 82, 67, 76, 73, 67, 75, 32,
    84, 79, 32, 83, 69, 76, 76, 32, 70, 79, 82, 76, 69, 86, 69, 76,
    77, 65, 88, 73, 77, 85, 77, 32, 76, 69, 86, 69, 76, 67, 79, 83,
    84, 84, 72, 69, 32, 82, 79, 65, 68, 32, 77, 85, 83, 84, 32, 83,
    84, 65, 89, 32, 67, 76, 69, 65, 82, 78, 79, 32, 82, 79, 79, 77,
    32, 72, 69, 82, 69, 32, 70, 79, 82, 32, 65, 32, 84, 79, 87, 69,
    82, 66, 82, 65, 77, 66, 76, 69, 71, 65, 84, 69, 32, 75, 69, 69,
    80, 71, 85, 65, 82, 68, 32, 73, 84, 32, 87, 73, 84, 72, 32, 89,
    79, 85, 82, 32, 84, 79, 87, 69, 82, 83, 67, 65, 76, 76, 32, 84,
    72, 69, 32, 87, 65, 86, 69, 32, 69, 65, 82, 76, 89, 65, 78, 68,
    32, 69, 65, 82, 78, 32, 66, 79, 78, 85, 83, 32, 71, 79, 76, 68,
    71, 65, 77, 69, 32, 83, 80, 69, 69, 68, 78, 79, 82, 77, 65, 76,
    32, 79, 82, 32, 68, 79, 85, 66, 76, 69, 32, 83, 80, 69, 69, 68,
    67, 76, 73, 67, 75, 32, 71, 82, 65, 83, 83, 32, 66, 69, 83, 73,
    68, 69, 32, 84, 72, 69, 32, 82, 79, 65, 68, 71, 79, 76, 68, 78,
    79, 84, 32, 69, 78, 79, 85, 71, 72, 32, 71, 79, 76, 68, 89, 79,
    85, 32, 67, 65, 78, 78, 79, 84, 32, 66, 85, 73, 76, 68, 32, 84,
    72, 69, 82, 69, 84, 79, 87, 69, 82, 32, 66, 85, 73, 76, 84, 84,
    79, 87, 69, 82, 32, 85, 80, 71, 82, 65, 68, 69, 68, 84, 79, 87,
    69, 82, 32, 83, 79, 76, 68, 78, 79, 84, 72, 73, 78, 71, 32, 84,
    79, 32, 83, 69, 76, 76, 32, 84, 72, 69, 82, 69, 65, 76, 82, 69,
    65, 68, 89, 32, 65, 84, 32, 77, 65, 88, 32, 76, 69, 86, 69, 76,
    87, 65, 86, 69, 32, 67, 76, 69, 65, 82, 69, 68, 33, 65, 32, 70,
    79, 69, 32, 82, 69, 65, 67, 72, 69, 68, 32, 84, 72, 69, 32, 71,
    65, 84, 69, 33, 69, 65, 82, 76, 89, 32, 67, 65, 76, 76, 32, 66,
    79, 78, 85, 83, 66, 85, 73, 76, 68, 32, 66, 69, 83, 73, 68, 69,
    32, 84, 72, 69, 32, 82, 79, 65, 68, 71, 79, 66, 76, 73, 78, 32,
    83, 67, 79, 85, 84, 83, 71, 79, 66, 76, 73, 78, 83, 32, 65, 78,
    68, 32, 72, 79, 85, 78, 68, 83, 84, 72, 69, 32, 72, 79, 85, 78,
    68, 32, 80, 65, 67, 75, 32, 45, 32, 70, 65, 83, 84, 33, 65, 82,
    77, 79, 85, 82, 69, 68, 32, 66, 82, 85, 84, 69, 83, 32, 45, 32,
    67, 65, 78, 78, 79, 78, 83, 32, 80, 73, 69, 82, 67, 69, 32, 65,
    82, 77, 79, 85, 82, 66, 65, 84, 83, 32, 65, 84, 32, 68, 85, 83,
    75, 32, 45, 32, 67, 65, 78, 78, 79, 78, 83, 32, 67, 65, 78, 78,
    79, 84, 32, 72, 73, 84, 32, 84, 72, 69, 77, 66, 82, 85, 84, 69,
    83, 32, 65, 78, 68, 32, 72, 79, 85, 78, 68, 83, 84, 72, 69, 32,
    66, 65, 84, 32, 83, 87, 65, 82, 77, 84, 72, 69, 32, 71, 79, 66,
    76, 73, 78, 32, 72, 79, 82, 68, 69, 73, 82, 79, 78, 32, 65, 78,
    68, 32, 87, 73, 78, 71, 83, 70, 73, 78, 65, 76, 32, 87, 65, 86,
    69, 32, 45, 32, 84, 72, 69, 32, 84, 82, 79, 76, 76, 32, 75, 73,
    78, 71, 32, 67, 79, 77, 69, 83, 84, 72, 69, 32, 75, 69, 69, 80,
    32, 83, 84, 65, 78, 68, 83, 33, 84, 72, 69, 32, 75, 69, 69, 80,
    32, 72, 65, 83, 32, 70, 65, 76, 76, 69, 78, 87, 65, 86, 69, 83,
    32, 72, 69, 76, 68, 70, 79, 69, 83, 32, 68, 69, 70, 69, 65, 84,
    69, 68, 76, 73, 86, 69, 83, 32, 76, 69, 70, 84, 70, 73, 78, 65,
    76, 32, 83, 67, 79, 82, 69, 66, 69, 83, 84, 32, 84, 72, 73, 83,
    32, 82, 85, 78, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32,
    84, 79, 32, 80, 76, 65, 89, 32, 65, 71, 65, 73, 78, 43, 88,
};
constant int textRanges[150] = {
    0, 16,  // BRAMBLEGATE KEEP
    16, 39,  // HOLD THE ROAD TO THE KEEP FOR TEN WAVES
    55, 38,  // DRAG THE CURSOR - PRESS SPACE TO CLICK
    93, 44,  // PICK A TOWER CARD, THEN CLICK GRASS TO BUILD
    137, 38,  // CLICK ONE OF YOUR TOWERS TO UPGRADE IT
    175, 47,  // ARCHERS HIT ANYTHING, CANNONS SPLASH THE GROUND
    222, 39,  // FROST TOWERS SLOW EVERY FOE AROUND THEM
    261, 50,  // KILLS PAY GOLD - EVERY FOE AT THE GATE COSTS LIVES
    311, 20,  // PRESS SPACE TO BEGIN
    331, 5,  // SCORE
    336, 4,  // WAVE
    340, 2,  // OF
    342, 12,  // NEXT WAVE IN
    354, 8,  // CALL NOW
    362, 9,  // FOES LEFT
    371, 6,  // ARCHER
    377, 6,  // CANNON
    383, 5,  // FROST
    388, 4,  // SELL
    392, 12,  // ARCHER TOWER
    404, 12,  // CANNON TOWER
    416, 11,  // FROST TOWER
    427, 11,  // SELL TOWERS
    438, 27,  // FAST ARROWS, AIR AND GROUND
    465, 25,  // SPLASHING SHELLS, NO BATS
    490, 27,  // ICE PULSE SLOWS ALL NEAR IT
    517, 24,  // CLICK A TOWER TO SELL IT
    541, 23,  // REFUNDS 70% OF ITS COST
    564, 18,  // CLICK TO BUILD FOR
    582, 20,  // CLICK TO UPGRADE FOR
    602, 17,  // CLICK TO SELL FOR
    619, 5,  // LEVEL
    624, 13,  // MAXIMUM LEVEL
    637, 4,  // COST
    641, 24,  // THE ROAD MUST STAY CLEAR
    665, 24,  // NO ROOM HERE FOR A TOWER
    689, 16,  // BRAMBLEGATE KEEP
    705, 25,  // GUARD IT WITH YOUR TOWERS
    730, 19,  // CALL THE WAVE EARLY
    749, 19,  // AND EARN BONUS GOLD
    768, 10,  // GAME SPEED
    778, 22,  // NORMAL OR DOUBLE SPEED
    800, 27,  // CLICK GRASS BESIDE THE ROAD
    827, 4,  // GOLD
    831, 15,  // NOT ENOUGH GOLD
    846, 22,  // YOU CANNOT BUILD THERE
    868, 11,  // TOWER BUILT
    879, 14,  // TOWER UPGRADED
    893, 10,  // TOWER SOLD
    903, 21,  // NOTHING TO SELL THERE
    924, 20,  // ALREADY AT MAX LEVEL
    944, 13,  // WAVE CLEARED!
    957, 23,  // A FOE REACHED THE GATE!
    980, 16,  // EARLY CALL BONUS
    996, 21,  // BUILD BESIDE THE ROAD
    1017, 13,  // GOBLIN SCOUTS
    1030, 18,  // GOBLINS AND HOUNDS
    1048, 22,  // THE HOUND PACK - FAST!
    1070, 39,  // ARMOURED BRUTES - CANNONS PIERCE ARMOUR
    1109, 38,  // BATS AT DUSK - CANNONS CANNOT HIT THEM
    1147, 17,  // BRUTES AND HOUNDS
    1164, 13,  // THE BAT SWARM
    1177, 16,  // THE GOBLIN HORDE
    1193, 14,  // IRON AND WINGS
    1207, 33,  // FINAL WAVE - THE TROLL KING COMES
    1240, 16,  // THE KEEP STANDS!
    1256, 19,  // THE KEEP HAS FALLEN
    1275, 10,  // WAVES HELD
    1285, 13,  // FOES DEFEATED
    1298, 10,  // LIVES LEFT
    1308, 11,  // FINAL SCORE
    1319, 13,  // BEST THIS RUN
    1332, 25,  // PRESS SPACE TO PLAY AGAIN
    1357, 1,  // +
    1358, 1,  // X
};
constant int textTitle = 0;
constant int textSubtitle = 1;
constant int textHow1 = 2;
constant int textHow2 = 3;
constant int textHow3 = 4;
constant int textHow4 = 5;
constant int textHow5 = 6;
constant int textHow6 = 7;
constant int textPressBegin = 8;
constant int textScore = 9;
constant int textWave = 10;
constant int textOf = 11;
constant int textNextWaveIn = 12;
constant int textCallNow = 13;
constant int textFoes = 14;
constant int textArcher = 15;
constant int textCannon = 16;
constant int textFrost = 17;
constant int textSell = 18;
constant int textArcherTower = 19;
constant int textCannonTower = 20;
constant int textFrostTower = 21;
constant int textSellTowers = 22;
constant int textArcherInfo = 23;
constant int textCannonInfo = 24;
constant int textFrostInfo = 25;
constant int textSellInfo = 26;
constant int textRefund = 27;
constant int textBuildFor = 28;
constant int textUpgradeFor = 29;
constant int textSellFor = 30;
constant int textLevel = 31;
constant int textMaxLevel = 32;
constant int textCost = 33;
constant int textRoadHere = 34;
constant int textBlocked = 35;
constant int textKeepName = 36;
constant int textKeepInfo = 37;
constant int textCallTitle = 38;
constant int textCallInfo = 39;
constant int textSpeed = 40;
constant int textSpeedInfo = 41;
constant int textGrassHint = 42;
constant int textGold = 43;
constant int textNoGold = 44;
constant int textCannotBuild = 45;
constant int textBuilt = 46;
constant int textUpgraded = 47;
constant int textSold = 48;
constant int textNothingToSell = 49;
constant int textAlreadyMax = 50;
constant int textWaveCleared = 51;
constant int textLeak = 52;
constant int textEarlyBonus = 53;
constant int textFirstBuild = 54;
constant int textWave1 = 55;
constant int textWave2 = 56;
constant int textWave3 = 57;
constant int textWave4 = 58;
constant int textWave5 = 59;
constant int textWave6 = 60;
constant int textWave7 = 61;
constant int textWave8 = 62;
constant int textWave9 = 63;
constant int textWave10 = 64;
constant int textVictory = 65;
constant int textDefeat = 66;
constant int textWavesHeld = 67;
constant int textFoesDefeated = 68;
constant int textLivesLeft = 69;
constant int textFinalScore = 70;
constant int textBest = 71;
constant int textAgain = 72;
constant int textPlus = 73;
constant int textX = 74;

// ---------------------------------------------------------------------------
// Ray intersection. Camera rays never run parallel to an axis (their
// direction is fixed by the isometric camera), but enemy parts are traced in a
// rotated local frame, so the curved primitives make no such assumption.

// Materials.
constant int matNone = 0;
constant int matStoneRound = 10;  // stone on a vertical cylinder
constant int matStoneBox = 11;    // stone on an axis-aligned box
constant int matRoof = 12;        // shingles on a cone
constant int matWood = 13;
constant int matIron = 14;
constant int matIce = 15;
constant int matPaleStone = 16;
constant int matFlag = 17;
constant int matGoldTrim = 18;
constant int matTrunk = 20;
constant int matFoliage = 21;
constant int matPine = 22;
constant int matRock = 23;
constant int matGate = 32;
constant int matSkin = 40;        // enemy skin, colour by type
constant int matCloth = 41;       // enemy tunic or fur, colour by type
constant int matMetal = 42;       // shields, spear tips
constant int matWing = 43;
constant int matEye = 44;
constant int matArrow = 60;
constant int matShell = 61;

struct SceneHit {
    float t;
    float3 normal;
    int material;
    int owner;      // cell index, enemy slot or -2 for the keep
    float3 part;    // position relative to the part, for texturing
    float tint;     // per-object variation (tower level, flag colour)
};

SceneHit noHit() {
    SceneHit hit;
    hit.t = 1.0e9f;
    hit.normal = float3(0.0f, 1.0f, 0.0f);
    hit.material = matNone;
    hit.owner = -1;
    hit.part = float3(0.0f);
    hit.tint = 0.0f;
    return hit;
}

void setHit(thread SceneHit &hit, float t, float3 normal, int material,
    int owner, float3 part, float tint) {
    hit.t = t;
    hit.normal = normal;
    hit.material = material;
    hit.owner = owner;
    hit.part = part;
    hit.tint = tint;
}

bool sphereT(float3 ro, float3 rd, float3 centre, float radius, float limit, thread float &t) {
    float3 oc = ro - centre;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float h = b * b - c;
    if (h < 0.0f) return false;
    float s = -b - sqrt(h);
    if (s <= 0.0f || s >= limit) return false;
    t = s;
    return true;
}

// Distance from a ray (unit direction) to a point, squared: a cheap bound test.
float rayPointDistance2(float3 ro, float3 rd, float3 p) {
    float3 op = p - ro;
    float along = dot(op, rd);
    return dot(op, op) - along * along;
}

void traceSphere(float3 ro, float3 rd, float3 centre, float radius, int material,
    int owner, float tint, thread SceneHit &hit) {
    float t = 0.0f;
    if (sphereT(ro, rd, centre, radius, hit.t, t)) {
        float3 p = ro + rd * t - centre;
        setHit(hit, t, p / radius, material, owner, p, tint);
    }
}

void traceEllipsoid(float3 ro, float3 rd, float3 centre, float3 radii, int material,
    int owner, float tint, thread SceneHit &hit) {
    float3 oc = (ro - centre) / radii;
    float3 dn = rd / radii;
    float a = dot(dn, dn);
    float b = dot(oc, dn);
    float c = dot(oc, oc) - 1.0f;
    float h = b * b - a * c;
    if (h < 0.0f) return;
    float s = (-b - sqrt(h)) / a;
    if (s <= 0.0f || s >= hit.t) return;
    float3 p = ro + rd * s - centre;
    setHit(hit, s, normalize(p / (radii * radii)), material, owner, p, tint);
}

// Vertical cylinder around (centre.x, centre.y) in x/z from y0 to y1 with its
// top cap (camera rays always look down, so a bottom cap is never visible).
void traceCylinder(float3 ro, float3 rd, float2 centre, float radius, float y0, float y1,
    int material, int owner, float tint, thread SceneHit &hit) {
    float2 o = ro.xz - centre;
    float2 d = rd.xz;
    float a = dot(d, d);
    if (a < 1e-8f) return;
    float b = dot(o, d);
    float c = dot(o, o) - radius * radius;
    float h = b * b - a * c;
    if (h < 0.0f) return;
    float s = (-b - sqrt(h)) / a;
    float y = ro.y + rd.y * s;
    if (s > 0.0f && s < hit.t && y >= y0 && y <= y1) {
        float2 q = o + d * s;
        setHit(hit, s, float3(q.x / radius, 0.0f, q.y / radius), material, owner,
            float3(atan2(q.y, q.x) * radius, y - y0, 0.0f), tint);
        return;
    }
    if (rd.y < 0.0f) {
        float sc = (y1 - ro.y) / rd.y;
        float2 q = o + d * sc;
        if (sc > 0.0f && sc < hit.t && dot(q, q) <= radius * radius) {
            setHit(hit, sc, float3(0.0f, 1.0f, 0.0f), material, owner,
                float3(q.x, y1 - y0 + q.y, 1.0f), tint);
        }
    }
}

// Vertical cone: base radius at y0, apex at y1 above the centre.
void traceCone(float3 ro, float3 rd, float2 centre, float radius, float y0, float y1,
    int material, int owner, float tint, thread SceneHit &hit) {
    float k = radius / (y1 - y0);
    float k2 = k * k;
    float3 o = ro - float3(centre.x, y1, centre.y);
    float a = dot(rd.xz, rd.xz) - k2 * rd.y * rd.y;
    float b = dot(o.xz, rd.xz) - k2 * o.y * rd.y;
    float c = dot(o.xz, o.xz) - k2 * o.y * o.y;
    if (abs(a) < 1e-7f) return;
    float h = b * b - a * c;
    if (h < 0.0f) return;
    float root = sqrt(h);
    float s0 = (-b - root) / a;
    float s1 = (-b + root) / a;
    float first = min(s0, s1);
    float second = max(s0, s1);
    for (int i = 0; i < 2; ++i) {
        float s = i == 0 ? first : second;
        if (s <= 0.0f || s >= hit.t) continue;
        float3 p = o + rd * s;
        if (p.y > 0.0f || p.y < y0 - y1) continue;
        float3 n = normalize(float3(p.x, -k2 * p.y, p.z));
        setHit(hit, s, n, material, owner,
            float3(atan2(p.z, p.x) * radius, p.y, length(p.xz)), tint);
        return;
    }
}

// Axis-aligned box. The ray components must not be zero (true for camera rays).
void traceBox(float3 ro, float3 rd, float3 low, float3 high, int material, int owner,
    float tint, thread SceneHit &hit) {
    float3 inv = 1.0f / rd;
    float3 t0 = (low - ro) * inv;
    float3 t1 = (high - ro) * inv;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (tn > tf || tn <= 0.0f || tn >= hit.t) return;
    float3 n = float3(0.0f, 0.0f, -sign(rd.z));
    if (tn == tmin.x) {
        n = float3(-sign(rd.x), 0.0f, 0.0f);
    } else if (tn == tmin.y) {
        n = float3(0.0f, -sign(rd.y), 0.0f);
    }
    setHit(hit, tn, n, material, owner, ro + rd * tn - low, tint);
}

// Ray against an axis-aligned box: entry distance or a negative value.
float boxEntry(float3 ro, float3 rd, float3 low, float3 high) {
    float3 inv = 1.0f / rd;
    float3 t0 = (low - ro) * inv;
    float3 t1 = (high - ro) * inv;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (tn > tf || tf <= 0.0f) return -1.0f;
    return max(tn, 0.0f);
}

void traceCapsule(float3 ro, float3 rd, float3 pa, float3 pb, float radius, int material,
    int owner, float tint, thread SceneHit &hit) {
    float3 ba = pb - pa;
    float3 oa = ro - pa;
    float baba = dot(ba, ba);
    float bard = dot(ba, rd);
    float baoa = dot(ba, oa);
    float rdoa = dot(rd, oa);
    float oaoa = dot(oa, oa);
    float a = baba - bard * bard;
    float b = baba * rdoa - baoa * bard;
    float c = baba * oaoa - baoa * baoa - radius * radius * baba;
    float h = b * b - a * c;
    float s = -1.0f;
    if (h >= 0.0f && a > 1e-7f) {
        float side = (-b - sqrt(h)) / a;
        float y = baoa + side * bard;
        if (y > 0.0f && y < baba) {
            s = side;
        } else {
            float3 oc = y <= 0.0f ? oa : ro - pb;
            float bb = dot(rd, oc);
            float cc = dot(oc, oc) - radius * radius;
            float hh = bb * bb - cc;
            if (hh > 0.0f) s = -bb - sqrt(hh);
        }
    } else {
        float t = 0.0f;
        if (sphereT(ro, rd, pa, radius, hit.t, t)) s = t;
    }
    if (s <= 0.0f || s >= hit.t) return;
    float3 p = ro + rd * s;
    float along = clamp(dot(p - pa, ba) / max(baba, 1e-7f), 0.0f, 1.0f);
    float3 n = normalize(p - (pa + ba * along));
    setHit(hit, s, n, material, owner, float3(along, 0.0f, 0.0f), tint);
}

// ---------------------------------------------------------------------------
// Board objects

float archerWallHeight(float tier) { return 0.95f + 0.25f * (tier - 1.0f); }
float cannonWallHeight(float tier) { return 0.48f + 0.12f * (tier - 1.0f); }
float frostWallHeight(float tier) { return 0.75f + 0.2f * (tier - 1.0f); }

// Where a tower's shots start.
float3 towerMuzzle(float type, float tier, float2 centre, float aim) {
    if (type < 0.5f) return float3(centre.x, archerWallHeight(tier) + 0.2f, centre.y);
    if (type < 1.5f) {
        float top = cannonWallHeight(tier);
        return float3(centre.x + 0.36f * cos(aim), top + 0.16f, centre.y + 0.36f * sin(aim));
    }
    return float3(centre.x, frostWallHeight(tier) + 0.36f, centre.y);
}

void traceTower(float3 ro, float3 rd, float type, float tier, float2 centre, float aim,
    float recoil, float time, int owner, thread SceneHit &hit) {
    if (type < 0.5f) {
        float wall = archerWallHeight(tier);
        traceCylinder(ro, rd, centre, 0.27f, 0.0f, wall, matStoneRound, owner, tier, hit);
        traceCylinder(ro, rd, centre, 0.33f, wall, wall + 0.14f,
            pickInt(tier > 2.5f, matGoldTrim, matWood), owner, tier, hit);
        float apex = wall + 0.62f;
        traceCone(ro, rd, centre, 0.40f, wall + 0.14f, apex, matRoof, owner, tier, hit);
        if (tier > 1.5f) {
            float3 top = float3(centre.x, apex, centre.y);
            traceCapsule(ro, rd, top, top + float3(0.0f, 0.24f, 0.0f), 0.016f, matWood,
                owner, tier, hit);
            float wave = 0.02f * sin(time * 5.0f + centre.x);
            traceEllipsoid(ro, rd, top + float3(0.09f, 0.18f + wave, 0.0f),
                float3(0.09f, 0.05f, 0.025f), matFlag, owner, tier, hit);
        }
    } else if (type < 1.5f) {
        float wall = cannonWallHeight(tier);
        float extent = 0.34f + 0.02f * tier;
        traceBox(ro, rd, float3(centre.x - extent, 0.0f, centre.y - extent),
            float3(centre.x + extent, wall, centre.y + extent), matStoneBox, owner, tier, hit);
        for (int i = 0; i < 4; ++i) {
            float2 corner = centre + float2(i % 2 == 0 ? -extent + 0.09f : extent - 0.09f,
                i < 2 ? -extent + 0.09f : extent - 0.09f);
            traceBox(ro, rd, float3(corner.x - 0.09f, wall, corner.y - 0.09f),
                float3(corner.x + 0.09f, wall + 0.13f, corner.y + 0.09f),
                matStoneBox, owner, tier, hit);
        }
        traceSphere(ro, rd, float3(centre.x, wall, centre.y), 0.17f + 0.02f * tier,
            pickInt(tier > 2.5f, matGoldTrim, matWood), owner, tier, hit);
        float2 aimDir = float2(cos(aim), sin(aim));
        float back = 0.08f * clamp(recoil * 4.0f, 0.0f, 1.0f);
        float3 breech = float3(centre.x, wall + 0.08f, centre.y);
        float3 muzzle = float3(centre.x + aimDir.x * (0.34f - back), wall + 0.16f,
            centre.y + aimDir.y * (0.34f - back));
        traceCapsule(ro, rd, breech, muzzle, 0.065f + 0.012f * tier, matIron, owner, tier, hit);
    } else {
        float wall = frostWallHeight(tier);
        traceCylinder(ro, rd, centre, 0.22f, 0.0f, wall, matPaleStone, owner, tier, hit);
        traceCylinder(ro, rd, centre, 0.29f, wall, wall + 0.08f, matPaleStone, owner, tier, hit);
        float grow = 1.0f + 0.12f * (tier - 1.0f);
        float bob = 0.04f * sin(time * 2.2f + centre.y);
        traceEllipsoid(ro, rd, float3(centre.x, wall + 0.36f + bob, centre.y),
            float3(0.12f, 0.22f, 0.12f) * grow, matIce, owner, tier, hit);
    }
}

void traceDecoration(float3 ro, float3 rd, uint content, float2 centre, int owner,
    thread SceneHit &hit) {
    float variation = hash01(uint(owner) * 7919u + 13u);
    if (content == cellTree) {
        traceCylinder(ro, rd, centre, 0.06f, 0.0f, 0.55f, matTrunk, owner, variation, hit);
        traceSphere(ro, rd, float3(centre.x, 0.80f, centre.y), 0.34f, matFoliage, owner,
            variation, hit);
        traceSphere(ro, rd, float3(centre.x + 0.1f, 1.02f, centre.y - 0.08f), 0.22f,
            matFoliage, owner, variation, hit);
    } else if (content == cellPine) {
        traceCylinder(ro, rd, centre, 0.05f, 0.0f, 0.3f, matTrunk, owner, variation, hit);
        traceCone(ro, rd, centre, 0.36f, 0.2f, 0.95f, matPine, owner, variation, hit);
        traceCone(ro, rd, centre, 0.27f, 0.6f, 1.3f, matPine, owner, variation, hit);
    } else if (content == cellRock) {
        traceEllipsoid(ro, rd, float3(centre.x, 0.04f, centre.y),
            float3(0.34f, 0.22f, 0.28f), matRock, owner, variation, hit);
        traceEllipsoid(ro, rd, float3(centre.x + 0.2f, 0.02f, centre.y + 0.18f),
            float3(0.15f, 0.12f, 0.14f), matRock, owner, variation, hit);
    }
}

// The keep fills cells x 0-1, z 12-13; its gate faces the road at z = 12.5.
constant float3 keepLow = float3(0.0f, 0.0f, 11.85f);
constant float3 keepHigh = float3(2.08f, 2.95f, 14.0f);

void traceKeep(float3 ro, float3 rd, float time, thread SceneHit &hit) {
    if (boxEntry(ro, rd, keepLow, keepHigh) < 0.0f) return;
    int owner = -2;
    traceBox(ro, rd, float3(0.15f, 0.0f, 12.15f), float3(1.75f, 1.2f, 13.85f), matStoneBox,
        owner, 0.0f, hit);
    // Crenellations along the two walls that face the camera.
    for (int i = 0; i < 5; ++i) {
        float z = 12.45f + 0.3f * float(i);
        traceBox(ro, rd, float3(1.62f, 1.2f, z - 0.07f), float3(1.75f, 1.34f, z + 0.07f),
            matStoneBox, owner, 0.0f, hit);
        float x = 0.35f + 0.3f * float(i);
        traceBox(ro, rd, float3(x - 0.07f, 1.2f, 13.72f), float3(x + 0.07f, 1.34f, 13.85f),
            matStoneBox, owner, 0.0f, hit);
    }
    for (int i = 0; i < 2; ++i) {
        float2 c = float2(1.8f, i == 0 ? 12.08f : 12.92f);
        traceCylinder(ro, rd, c, 0.22f, 0.0f, 1.6f, matStoneRound, owner, 0.0f, hit);
        traceCone(ro, rd, c, 0.29f, 1.6f, 2.05f, matRoof, owner, 0.0f, hit);
    }
    for (int i = 0; i < 3; ++i) {
        float2 c = float2(0.32f, 12.3f);
        if (i == 1) c = float2(0.32f, 13.68f);
        if (i == 2) c = float2(1.45f, 13.68f);
        traceCylinder(ro, rd, c, 0.3f, 0.0f, 1.75f, matStoneRound, owner, 0.0f, hit);
        traceCone(ro, rd, c, 0.38f, 1.75f, 2.35f, matRoof, owner, 0.0f, hit);
    }
    float2 donjon = float2(0.85f, 13.0f);
    traceCylinder(ro, rd, donjon, 0.42f, 0.0f, 2.05f, matStoneRound, owner, 0.0f, hit);
    traceCone(ro, rd, donjon, 0.53f, 2.05f, 2.72f, matRoof, owner, 0.0f, hit);
    float3 top = float3(donjon.x, 2.72f, donjon.y);
    traceCapsule(ro, rd, top, top + float3(0.0f, 0.2f, 0.0f), 0.02f, matWood, owner, 0.0f, hit);
    float wave = 0.025f * sin(time * 4.0f);
    traceEllipsoid(ro, rd, top + float3(0.12f, 0.15f + wave, 0.0f), float3(0.12f, 0.06f, 0.03f),
        matFlag, owner, 4.0f, hit);
}

// Nearest tower, tree, rock or keep along a ray. Board objects stay inside
// their cell (radius < 0.48), and the camera looks exactly along the board
// diagonal, so only cells within a narrow band around the ray's ground track
// between the ceiling and the ground can be hit.
void traceStatic(device const GameState &game, float3 ro, float3 rd, float time,
    thread SceneHit &hit) {
    float tGround = ro.y / -rd.y;
    float tCeiling = (ro.y - objectCeiling) / -rd.y;
    float3 g = ro + rd * tGround;
    float3 e = ro + rd * tCeiling;
    int xMin = max(int(floor(min(g.x, e.x) - 0.5f)), 0);
    int xMax = min(int(floor(max(g.x, e.x) + 0.5f)), gridSize - 1);
    int zMin = max(int(floor(min(g.z, e.z) - 0.5f)), 0);
    int zMax = min(int(floor(max(g.z, e.z) + 0.5f)), gridSize - 1);
    float diagonal = g.x - g.z;
    for (int dz = 0; dz < 7; ++dz) {
        int z = zMin + dz;
        if (z > zMax) break;
        for (int dx = 0; dx < 7; ++dx) {
            int x = xMin + dx;
            if (x > xMax) break;
            if (abs(float(x - z) - diagonal) > 0.75f) continue;
            int index = z * gridSize + x;
            uint content = game.cells[index];
            float2 centre = float2(float(x) + 0.5f, float(z) + 0.5f);
            if (content >= cellTowerBase) {
                int slot = int(content - cellTowerBase);
                if (slot < maxTowers) {
                    Tower tower = game.towers[slot];
                    if (tower.place.z >= 0.0f) {
                        traceTower(ro, rd, tower.place.z, tower.place.w, centre,
                            tower.fire.y, tower.fire.z, time, index, hit);
                    }
                }
            } else if (content == cellTree || content == cellPine || content == cellRock) {
                traceDecoration(ro, rd, content, centre, index, hit);
            }
        }
    }
    traceKeep(ro, rd, time, hit);
}

// ---------------------------------------------------------------------------
// HUD layout in design units, shared by input hit-testing and drawing.

float2 cardLow(int card) { return float2(14.0f + 78.0f * float(card), 500.0f); }
constant float2 cardSize = float2(70.0f, 88.0f);
constant float2 callLow = float2(684.0f, 72.0f);
constant float2 callHigh = float2(852.0f, 102.0f);
constant float2 speedLow = float2(864.0f, 72.0f);
constant float2 speedHigh = float2(936.0f, 102.0f);

bool insideRect(float2 p, float2 low, float2 high) {
    return p.x >= low.x && p.y >= low.y && p.x <= high.x && p.y <= high.y;
}

bool inBreak(device const GameState &game) {
    return game.wave.w < 0.5f && game.wave.x < float(waveCount);
}

float toolCost(float tool) {
    return towerCostTable[clamp(int(tool), 0, 2) * 3];
}

// ---------------------------------------------------------------------------
// Game state helpers

void showNotice(device GameState &game, int text, float seconds) {
    game.notice.x = float(text);
    game.notice.y = seconds;
}

void gainGold(device GameState &game, float amount) {
    game.economy.x += amount;
    game.flashes.z = amount;
    game.flashes.w = 2.0f;
}

void spawnEffect(device GameState &game, float3 position, float kind, float duration,
    float value) {
    for (int i = 0; i < maxEffects; ++i) {
        if (game.effects[i].pos.w < 0.0f) {
            game.effects[i].pos = float4(position, kind);
            game.effects[i].info = float4(0.0f, duration, value, 0.0f);
            return;
        }
    }
}

void resetGame(device GameState &game) {
    game.mode = float4(screenPlaying, 0.0f, 0.0f, 1.0f);
    game.economy = float4(game.settings.x, game.settings.y, 0.0f, 0.0f);
    game.wave = float4(0.0f);
    game.input.y = 0.0f;
    game.hover = float4(hoverNone, 0.0f, 0.0f, 0.0f);
    game.notice = float4(float(textFirstBuild), 4.0f, 0.0f, 0.0f);
    game.flashes = float4(0.0f);
    for (int g = 0; g < 3; ++g) game.spawn[g] = float4(0.0f);
    game.counters.y = 0u;
    game.counters.z = 0u;
    for (int i = 0; i < maxEnemies; ++i) {
        game.enemies[i].body = float4(0.0f);
        game.enemies[i].stats = float4(-1.0f, 0.0f, 0.0f, 0.0f);
        game.enemies[i].status = float4(0.0f);
        game.enemies[i].extra = float4(0.0f);
    }
    for (int i = 0; i < maxTowers; ++i) {
        game.towers[i].place = float4(0.0f, 0.0f, -1.0f, 0.0f);
        game.towers[i].fire = float4(0.0f);
    }
    for (int i = 0; i < maxShots; ++i) {
        game.shots[i].pos = float4(0.0f, 0.0f, 0.0f, -1.0f);
        game.shots[i].vel = float4(0.0f);
        game.shots[i].info = float4(0.0f);
    }
    for (int i = 0; i < maxEffects; ++i) {
        game.effects[i].pos = float4(0.0f, 0.0f, 0.0f, -1.0f);
        game.effects[i].info = float4(0.0f);
    }
    for (int z = 0; z < gridSize; ++z) {
        for (int x = 0; x < gridSize; ++x) {
            float2 centre = float2(float(x) + 0.5f, float(z) + 0.5f);
            uint content = cellGrass;
            if (roadDistance(centre) < 0.5f) content = cellRoad;
            if (x < 2 && z >= 12) content = cellKeep;
            game.cells[z * gridSize + x] = content;
        }
    }
    for (int i = 0; i < decorationCount; ++i) {
        int3 d = decorations[i];
        game.cells[d.y * gridSize + d.x] = uint(d.z);
    }
}

void startGame(device GameState &game, float firstBreak) {
    resetGame(game);
    game.wave.z = firstBreak;
}

// ---------------------------------------------------------------------------
// Hover and clicks

float cellVerdict(device const GameState &game, int index) {
    uint content = game.cells[index];
    float tool = game.input.y;
    float gold = game.economy.x;
    if (content >= cellTowerBase) {
        int slot = int(content - cellTowerBase);
        if (slot >= maxTowers) return verdictBlocked;
        Tower tower = game.towers[slot];
        if (tool > 2.5f) return verdictSell;
        if (tower.place.w > 2.5f) return verdictMaxLevel;
        float cost = towerCostTable[towerIndex(tower.place.z, tower.place.w + 1.0f)];
        return pickFloat(gold >= cost, verdictUpgrade, verdictUpgradePoor);
    }
    if (tool > 2.5f) return verdictNoSell;
    if (content == cellGrass) return pickFloat(gold >= toolCost(tool), verdictBuild, verdictBuildPoor);
    if (content == cellRoad) return verdictRoad;
    if (content == cellKeep) return verdictKeep;
    return verdictBlocked;
}

void updateHover(device GameState &game, float time) {
    float2 p = game.input.zw;
    game.hover = float4(hoverNone, 0.0f, 0.0f, 0.0f);
    for (int card = 0; card < 4; ++card) {
        if (insideRect(p, cardLow(card), cardLow(card) + cardSize)) {
            game.hover = float4(hoverCard, float(card), 0.0f, 0.0f);
            return;
        }
    }
    if (inBreak(game) && insideRect(p, callLow, callHigh)) {
        game.hover = float4(hoverCall, 0.0f, 0.0f, 0.0f);
        return;
    }
    if (insideRect(p, speedLow, speedHigh)) {
        game.hover = float4(hoverSpeed, 0.0f, 0.0f, 0.0f);
        return;
    }
    float3 ro = rayOrigin(p);
    float3 rd = viewDirection;
    SceneHit hit = noHit();
    traceStatic(game, ro, rd, time, hit);
    int index = -1;
    if (hit.material != matNone && hit.owner >= 0) {
        index = hit.owner;
    } else if (hit.material != matNone && hit.owner == -2) {
        index = 12 * gridSize;  // a keep cell
    } else {
        float3 g = ro + rd * (ro.y / -rd.y);
        if (g.x >= 0.0f && g.z >= 0.0f && g.x < float(gridSize) && g.z < float(gridSize)) {
            index = int(g.z) * gridSize + int(g.x);
        }
    }
    if (index < 0 || index >= cellCount) return;
    game.hover = float4(hoverCell, float(index % gridSize), float(index / gridSize),
        cellVerdict(game, index));
}

void buildDust(device GameState &game, float2 centre) {
    spawnEffect(game, float3(centre.x, 0.05f, centre.y), 4.0f, 0.6f, 0.0f);
}

void handleClick(device GameState &game) {
    float kind = game.hover.x;
    if (kind == hoverCard) {
        game.input.y = game.hover.y;
        return;
    }
    if (kind == hoverSpeed) {
        game.mode.w = game.mode.w > 1.5f ? 1.0f : 2.0f;
        return;
    }
    if (kind == hoverCall) {
        if (inBreak(game)) {
            float bonus = floor(max(game.wave.z, 0.0f) * 0.5f);
            if (bonus > 0.0f) {
                gainGold(game, bonus);
                showNotice(game, textEarlyBonus, 2.0f);
            }
            game.wave.z = 0.0f;
        }
        return;
    }
    if (kind != hoverCell) return;
    int x = int(game.hover.y);
    int z = int(game.hover.z);
    int index = z * gridSize + x;
    float2 centre = float2(float(x) + 0.5f, float(z) + 0.5f);
    float verdict = cellVerdict(game, index);
    if (verdict == verdictBuild) {
        float tool = game.input.y;
        for (int slot = 0; slot < maxTowers; ++slot) {
            if (game.towers[slot].place.z >= 0.0f) continue;
            float cost = toolCost(tool);
            game.towers[slot].place = float4(float(x), float(z), tool, 1.0f);
            game.towers[slot].fire = float4(0.3f, 0.785f, 0.0f, cost);
            game.cells[index] = cellTowerBase + uint(slot);
            game.economy.x -= cost;
            showNotice(game, textBuilt, 1.2f);
            buildDust(game, centre);
            return;
        }
        showNotice(game, textCannotBuild, 1.5f);
    } else if (verdict == verdictUpgrade) {
        int slot = int(game.cells[index] - cellTowerBase);
        float cost = towerCostTable[towerIndex(game.towers[slot].place.z,
            game.towers[slot].place.w + 1.0f)];
        game.towers[slot].place.w += 1.0f;
        game.towers[slot].fire.w += cost;
        game.economy.x -= cost;
        showNotice(game, textUpgraded, 1.2f);
        buildDust(game, centre);
    } else if (verdict == verdictSell) {
        int slot = int(game.cells[index] - cellTowerBase);
        float refund = floor(game.towers[slot].fire.w * 0.7f);
        game.towers[slot].place = float4(0.0f, 0.0f, -1.0f, 0.0f);
        game.towers[slot].fire = float4(0.0f);
        game.cells[index] = cellGrass;
        gainGold(game, refund);
        showNotice(game, textSold, 1.2f);
        buildDust(game, centre);
    } else if (verdict == verdictBuildPoor || verdict == verdictUpgradePoor) {
        showNotice(game, textNoGold, 1.5f);
        game.flashes.y = 1.0f;
    } else if (verdict == verdictMaxLevel) {
        showNotice(game, textAlreadyMax, 1.5f);
    } else if (verdict == verdictNoSell) {
        showNotice(game, textNothingToSell, 1.5f);
    } else {
        showNotice(game, textCannotBuild, 1.5f);
    }
}

// ---------------------------------------------------------------------------
// Foes

bool spawnEnemy(device GameState &game, float type, thread uint &rng) {
    for (int i = 0; i < maxEnemies; ++i) {
        if (game.enemies[i].stats.x >= 0.0f) continue;
        int t = enemyType(type);
        float health = enemyHealthTable[t] * waveHealthScale(game.wave.x) * game.settings.z;
        float side = t == 4 ? 0.0f : (random01(rng) - 0.5f) * 0.32f;
        float heading = 0.0f;
        float3 p = roadPosition(0.0f, side, heading);
        float y = pickFloat(t == 3, batFlightHeight, 0.0f);
        game.enemies[i].body = float4(p.x, y, p.z, heading);
        game.enemies[i].stats = float4(float(t), health, health, 0.0f);
        game.enemies[i].status = float4(0.0f, 0.0f, 0.0f, random01(rng) * 6.28f);
        game.enemies[i].extra = float4(side, 0.0f, 0.0f, 0.0f);
        spawnEffect(game, p + float3(0.0f, 0.15f + y, 0.0f), 2.0f, 0.45f, t == 4 ? 2.5f : 1.0f);
        return true;
    }
    return false;
}

void killEnemy(device GameState &game, int i) {
    int t = enemyType(game.enemies[i].stats.x);
    float bounty = enemyBountyTable[t];
    float3 p = game.enemies[i].body.xyz;
    game.enemies[i].stats.x = -1.0f;
    game.economy.x += bounty;
    game.economy.z += bounty * 10.0f;
    game.economy.w += 1.0f;
    spawnEffect(game, p + float3(0.0f, 0.2f, 0.0f), 2.0f, 0.5f, t == 4 ? 2.0f : 1.0f);
    spawnEffect(game, p + float3(0.0f, 0.5f, 0.0f), 3.0f, 1.1f, bounty);
}

void damageEnemy(device GameState &game, int i, float damage) {
    if (i < 0 || i >= maxEnemies || game.enemies[i].stats.x < 0.0f) return;
    int t = enemyType(game.enemies[i].stats.x);
    float effective = max(damage - enemyArmourTable[t], damage * 0.35f);
    game.enemies[i].stats.y -= effective;
    game.enemies[i].status.z = 0.12f;
    if (game.enemies[i].stats.y <= 0.0f) killEnemy(game, i);
}

int aliveEnemies(device const GameState &game) {
    int count = 0;
    for (int i = 0; i < maxEnemies; ++i) {
        if (game.enemies[i].stats.x >= 0.0f) count += 1;
    }
    return count;
}

void updateEnemies(device GameState &game, float dt) {
    for (int i = 0; i < maxEnemies; ++i) {
        if (game.enemies[i].stats.x < 0.0f) continue;
        int t = enemyType(game.enemies[i].stats.x);
        float4 status = game.enemies[i].status;
        float slow = status.x > 0.0f ? status.y : 0.0f;
        float speed = enemySpeedTable[t] * (1.0f - slow);
        float along = game.enemies[i].stats.w + speed * dt;
        status.x = max(status.x - dt, 0.0f);
        status.z = max(status.z - dt, 0.0f);
        status.w += dt * (t == 3 ? 14.0f : speed * 7.0f);
        game.enemies[i].status = status;
        if (along >= roadTotal) {
            float3 gate = game.enemies[i].body.xyz;
            game.economy.y = max(game.economy.y - enemyLeakTable[t], 0.0f);
            game.flashes.x = 1.0f;
            game.counters.z += 1u;
            game.enemies[i].stats.x = -1.0f;
            showNotice(game, textLeak, 1.8f);
            spawnEffect(game, gate + float3(0.0f, 0.2f, 0.0f), 2.0f, 0.5f, 1.0f);
            continue;
        }
        game.enemies[i].stats.w = along;
        float heading = 0.0f;
        float3 p = roadPosition(along, game.enemies[i].extra.x, heading);
        float y = 0.0f;
        if (t == 3) y = batFlightHeight + 0.07f * sin(status.w * 0.5f);
        game.enemies[i].body = float4(p.x, y, p.z, heading);
    }
}

// Where foe `i` will be `seconds` from now if it keeps walking.
float3 predictEnemy(device const GameState &game, int i, float seconds) {
    int t = enemyType(game.enemies[i].stats.x);
    float4 status = game.enemies[i].status;
    float slow = status.x > seconds ? status.y : 0.0f;
    float along = min(game.enemies[i].stats.w + enemySpeedTable[t] * (1.0f - slow) * seconds,
        roadTotal);
    float heading = 0.0f;
    float3 p = roadPosition(along, game.enemies[i].extra.x, heading);
    p.y = game.enemies[i].body.y;
    return p;
}

// ---------------------------------------------------------------------------
// Towers and shots

void fireArrow(device GameState &game, float3 from, int target, float damage) {
    for (int i = 0; i < maxShots; ++i) {
        if (game.shots[i].pos.w >= 0.0f) continue;
        float3 aim = game.enemies[target].body.xyz
            + float3(0.0f, enemyAimHeightTable[enemyType(game.enemies[target].stats.x)], 0.0f);
        float3 v = normalize(aim - from) * 9.0f;
        game.shots[i].pos = float4(from, 0.0f);
        game.shots[i].vel = float4(v, float(target));
        game.shots[i].info = float4(damage, 0.0f, 0.0f, 0.0f);
        return;
    }
    damageEnemy(game, target, damage);  // no free shot slot: hit at once
}

void fireShell(device GameState &game, float3 from, int target, float damage, float splash) {
    float3 now = game.enemies[target].body.xyz;
    float flight = 0.45f + 0.12f * length(now.xz - from.xz);
    float3 landing = predictEnemy(game, target, flight);
    landing.y = 0.0f;
    float3 v = (landing - from) / flight;
    v.y += 4.9f * flight;
    for (int i = 0; i < maxShots; ++i) {
        if (game.shots[i].pos.w >= 0.0f) continue;
        game.shots[i].pos = float4(from, 1.0f);
        game.shots[i].vel = float4(v, -1.0f);
        game.shots[i].info = float4(damage, splash, 0.0f, flight);
        return;
    }
}

void updateTowers(device GameState &game, float dt) {
    for (int i = 0; i < maxTowers; ++i) {
        float4 place = game.towers[i].place;
        if (place.z < 0.0f) continue;
        float4 fire = game.towers[i].fire;
        fire.x = max(fire.x - dt, 0.0f);
        fire.z = max(fire.z - dt, 0.0f);
        int k = towerIndex(place.z, place.w);
        float2 centre = place.xy + 0.5f;
        float range = towerRangeTable[k];
        if (fire.x <= 0.0f) {
            if (place.z > 1.5f) {
                bool pulsed = false;
                for (int j = 0; j < maxEnemies; ++j) {
                    if (game.enemies[j].stats.x < 0.0f) continue;
                    if (distance(game.enemies[j].body.xz, centre) > range) continue;
                    pulsed = true;
                    float previous = game.enemies[j].status.x > 0.0f
                        ? game.enemies[j].status.y : 0.0f;
                    game.enemies[j].status.y = max(previous, towerSlowTable[k]);
                    game.enemies[j].status.x = 1.6f;
                    damageEnemy(game, j, towerDamageTable[k]);
                }
                if (pulsed) {
                    fire.x = towerReloadTable[k];
                    fire.z = 0.5f;
                    spawnEffect(game, float3(centre.x, 0.03f, centre.y), 1.0f, 0.6f, range);
                }
            } else {
                int target = -1;
                float best = -1.0f;
                for (int j = 0; j < maxEnemies; ++j) {
                    float type = game.enemies[j].stats.x;
                    if (type < 0.0f) continue;
                    if (place.z > 0.5f && type > 2.5f && type < 3.5f) continue;  // cannons miss bats
                    if (distance(game.enemies[j].body.xz, centre) > range) continue;
                    if (game.enemies[j].stats.w > best) {
                        best = game.enemies[j].stats.w;
                        target = j;
                    }
                }
                if (target >= 0) {
                    float2 to = game.enemies[target].body.xz - centre;
                    fire.y = atan2(to.y, to.x);
                    fire.x = towerReloadTable[k];
                    fire.z = 0.25f;
                    float3 muzzle = towerMuzzle(place.z, place.w, centre, fire.y);
                    if (place.z < 0.5f) {
                        fireArrow(game, muzzle, target, towerDamageTable[k]);
                    } else {
                        fireShell(game, muzzle, target, towerDamageTable[k], towerSplashTable[k]);
                    }
                }
            }
        }
        game.towers[i].fire = fire;
    }
}

void updateShots(device GameState &game, float dt) {
    for (int i = 0; i < maxShots; ++i) {
        float4 pos = game.shots[i].pos;
        if (pos.w < 0.0f) continue;
        float4 vel = game.shots[i].vel;
        float4 info = game.shots[i].info;
        info.z += dt;
        if (pos.w < 0.5f) {
            int target = int(vel.w);
            bool tracking = target >= 0 && target < maxEnemies
                && game.enemies[target].stats.x >= 0.0f;
            if (tracking) {
                float3 aim = game.enemies[target].body.xyz + float3(0.0f,
                    enemyAimHeightTable[enemyType(game.enemies[target].stats.x)], 0.0f);
                float3 to = aim - pos.xyz;
                float dist = length(to);
                if (dist <= 9.0f * dt + 0.12f) {
                    damageEnemy(game, target, info.x);
                    game.shots[i].pos.w = -1.0f;
                    continue;
                }
                vel.xyz = to / dist * 9.0f;
            } else {
                vel.w = -1.0f;
                vel.y -= 9.8f * dt;
            }
            pos.xyz += vel.xyz * dt;
            if (pos.y < 0.0f || info.z > 2.0f) pos.w = -1.0f;
        } else {
            vel.y -= 9.8f * dt;
            pos.xyz += vel.xyz * dt;
            if (info.z >= info.w || pos.y <= 0.0f) {
                float3 at = float3(pos.x, 0.0f, pos.z);
                for (int j = 0; j < maxEnemies; ++j) {
                    float type = game.enemies[j].stats.x;
                    if (type < 0.0f || (type > 2.5f && type < 3.5f)) continue;
                    float d = distance(game.enemies[j].body.xz, at.xz);
                    if (d > info.y) continue;
                    damageEnemy(game, j, info.x * (1.0f - 0.5f * d / max(info.y, 0.01f)));
                }
                spawnEffect(game, at, 0.0f, 0.55f, info.y);
                pos.w = -1.0f;
            }
        }
        game.shots[i].pos = pos;
        game.shots[i].vel = vel;
        game.shots[i].info = info;
    }
}

void updateEffects(device GameState &game, float dt) {
    for (int i = 0; i < maxEffects; ++i) {
        if (game.effects[i].pos.w < 0.0f) continue;
        game.effects[i].info.x += dt;
        if (game.effects[i].info.x >= game.effects[i].info.y) game.effects[i].pos.w = -1.0f;
    }
}

// ---------------------------------------------------------------------------
// Waves

void startWave(device GameState &game) {
    game.wave = float4(game.wave.x + 1.0f, 0.0f, 0.0f, 1.0f);
    for (int g = 0; g < 3; ++g) game.spawn[g] = float4(0.0f);
    game.notice.z = game.wave.x;
    game.notice.w = 3.5f;
}

void finishGame(device GameState &game, float screen) {
    game.mode.x = screen;
    game.mode.y = 0.0f;
    if (screen == screenVictory) game.economy.z += game.economy.y * 100.0f;
    game.counters.w = max(game.counters.w, uint(game.economy.z));
}

void updateWaves(device GameState &game, float dt, thread uint &rng) {
    if (game.wave.w < 0.5f) {
        game.wave.z -= dt;
        if (game.wave.z <= 0.0f) startWave(game);
        return;
    }
    game.wave.y += dt;
    int w = clamp(int(game.wave.x) - 1, 0, waveCount - 1);
    bool allSpawned = true;
    for (int g = 0; g < 3; ++g) {
        float4 group = waveTable[w * 3 + g];
        if (group.x < 0.0f) continue;
        float spawned = game.spawn[g].x;
        if (spawned >= group.y) continue;
        allSpawned = false;
        if (game.wave.y >= group.w + spawned * group.z && spawnEnemy(game, group.x, rng)) {
            game.spawn[g].x = spawned + 1.0f;
        }
    }
    if (!allSpawned || aliveEnemies(game) > 0) return;
    game.counters.y = uint(game.wave.x);
    float bonus = 20.0f + 5.0f * game.wave.x;
    gainGold(game, bonus);
    game.economy.z += bonus * 5.0f;
    if (game.wave.x >= float(waveCount)) {
        finishGame(game, screenVictory);
        return;
    }
    game.wave.w = 0.0f;
    game.wave.z = game.settings.w;
    showNotice(game, textWaveCleared, 2.5f);
}

void simulate(device GameState &game, float dt, thread uint &rng) {
    game.mode.z += dt;
    updateWaves(game, dt, rng);
    if (game.mode.x != screenPlaying) return;
    updateEnemies(game, dt);
    updateTowers(game, dt);
    updateShots(game, dt);
    updateEffects(game, dt);
    if (game.economy.y <= 0.0f) finishGame(game, screenDefeat);
}

// ---------------------------------------------------------------------------
// Kernels

void readSettings(device GameState &game, constant ProgramUniforms &u) {
    float4 p = u.parameters0;
    game.settings.x = p.x > 0.0f ? clamp(floor(p.x), 20.0f, 5000.0f) : 150.0f;
    game.settings.y = p.y > 0.0f ? clamp(floor(p.y), 1.0f, 99.0f) : 20.0f;
    game.settings.z = p.z > 0.0f ? clamp(p.z, 0.25f, 4.0f) : 1.0f;
    game.settings.w = p.w > 0.0f ? clamp(p.w, 3.0f, 120.0f) : 15.0f;
}

float firstBreakSeconds(constant ProgramUniforms &u) {
    return u.parameters1.x > 0.0f ? clamp(u.parameters1.x, 5.0f, 300.0f) : 30.0f;
}

kernel void initializeKeep(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    readSettings(game, u);
    game.counters = uint4(hashUint(u.frameSeed.y ^ 0x9e3779b9u) | 1u, 0u, 0u, 0u);
    resetGame(game);
    game.mode = float4(screenTitle, 0.0f, 0.0f, 1.0f);
    game.notice = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    float2 resolution = u.resolutionTime.xy;
    // The saved Trackpad count is the starting point, not a click.
    game.input = float4(u.pointer.z, 0.0f, toDesign(u.pointer.xy * resolution, resolution));
}

kernel void advanceKeep(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = tickSeconds(u);
    float time = u.resolutionTime.z;
    float2 resolution = u.resolutionTime.xy;
    game.input.zw = toDesign(u.pointer.xy * resolution, resolution);
    bool click = u.pointer.z > game.input.x + 0.5f;
    game.input.x = u.pointer.z;
    game.mode.y += dt;
    game.notice.y = max(game.notice.y - dt, 0.0f);
    game.notice.w = max(game.notice.w - dt, 0.0f);
    game.flashes.x = max(game.flashes.x - dt * 1.5f, 0.0f);
    game.flashes.y = max(game.flashes.y - dt * 2.0f, 0.0f);
    game.flashes.w = max(game.flashes.w - dt, 0.0f);
    uint rng = game.counters.x;
    float firstBreak = firstBreakSeconds(u);
    if (game.mode.x == screenTitle) {
        if (click) startGame(game, firstBreak);
    } else if (game.mode.x == screenPlaying) {
        updateHover(game, time);
        if (click) {
            handleClick(game);
            updateHover(game, time);
        }
        int steps = game.mode.w > 1.5f ? 2 : 1;
        for (int substep = 0; substep < 2; ++substep) {
            if (substep >= steps || game.mode.x != screenPlaying) break;
            simulate(game, dt, rng);
        }
    } else {
        updateEffects(game, dt);
        if (click && game.mode.y > 1.0f) startGame(game, firstBreak);
    }
    game.counters.x = rng;
}

// One thread per atlas texel: the six material textures, box-filtered to a
// third of the output width and half its height each, so distant texture
// detail does not alias (generated textures have no mipmaps).
kernel void prepareAtlas(constant ProgramUniforms &u [[buffer(0)]],
    texture2d<float> grassImage [[texture(1)]],
    texture2d<float> cobbleImage [[texture(2)]],
    texture2d<float> stoneImage [[texture(3)]],
    texture2d<float> roofImage [[texture(4)]],
    texture2d<float> foliageImage [[texture(5)]],
    texture2d<float> woodImage [[texture(6)]],
    texture2d<float, access::write> atlas [[texture(7)]],
    uint2 gid [[thread_position_in_grid]]) {
    uint width = atlas.get_width();
    uint height = atlas.get_height();
    if (gid.x >= width || gid.y >= height) return;
    uint tileWidth = max(width / 3u, 1u);
    uint tileHeight = max(height / 2u, 1u);
    uint column = min(gid.x / tileWidth, 2u);
    uint row = min(gid.y / tileHeight, 1u);
    uint tile = row * 3u + column;
    float2 tileSize = float2(float(tileWidth), float(tileHeight));
    float2 inTile = float2(float(gid.x - column * tileWidth), float(gid.y - row * tileHeight));
    constexpr sampler source(coord::normalized, address::repeat, filter::linear);
    float3 sum = float3(0.0f);
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            float2 uv = (inTile + (float2(float(i), float(j)) + 0.5f) * 0.25f) / tileSize;
            float4 c = float4(0.0f);
            if (tile == 0u) c = grassImage.sample(source, uv, level(0.0f));
            else if (tile == 1u) c = cobbleImage.sample(source, uv, level(0.0f));
            else if (tile == 2u) c = stoneImage.sample(source, uv, level(0.0f));
            else if (tile == 3u) c = roofImage.sample(source, uv, level(0.0f));
            else if (tile == 4u) c = foliageImage.sample(source, uv, level(0.0f));
            else c = woodImage.sample(source, uv, level(0.0f));
            float3 srgb = clamp(c.rgb / max(c.a, 0.001f), float3(0.0f), float3(1.0f));
            sum += select(pow((srgb + 0.055f) / 1.055f, float3(2.4f)), srgb / 12.92f,
                srgb <= 0.04045f);
        }
    }
    atlas.write(float4(sum / 16.0f, 1.0f), gid);
}

// ---------------------------------------------------------------------------
// Materials. The prefiltered atlas holds six generated textures as linear
// colour in a 3 x 2 grid of tiles (see prepareAtlas).

constant int tileGrass = 0;
constant int tileCobble = 1;
constant int tileStone = 2;
constant int tileRoof = 3;
constant int tileFoliage = 4;
constant int tileWood = 5;

constant float3 sunDirection = float3(-0.3412f, 0.8106f, 0.4757f);  // normalized
constant float2 shadowDirection = float2(0.5829f, -0.8125f);        // away from the sun, on the ground

float3 atlasColor(texture2d<float> atlas, float2 atlasSize, int tile, float2 uv) {
    float2 tileSize = max(floor(atlasSize / float2(3.0f, 2.0f)), float2(2.0f));
    float2 origin = float2(float(tile % 3), float(tile / 3)) * tileSize;
    float2 t = uv - 2.0f * floor(uv * 0.5f);
    float2 m = select(t, 2.0f - t, t > float2(1.0f));
    float2 texel = clamp(m * tileSize, float2(0.75f), tileSize - float2(0.75f));
    constexpr sampler atlasSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return atlas.sample(atlasSampler, (origin + texel) / atlasSize).rgb;
}

float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, float3(2.4f)), c / 12.92f, c <= float3(0.04045f));
}

float3 linearToSrgb(float3 c) {
    c = max(c, float3(0.0f));
    return select(1.055f * pow(c, float3(1.0f / 2.4f)) - 0.055f, 12.92f * c,
        c <= float3(0.0031308f));
}

float luminance(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

// Texture coordinates for a box face from its normal.
float2 boxFaceUV(float3 p, float3 n) {
    if (abs(n.y) > 0.5f) return p.xz;
    if (abs(n.x) > abs(n.z)) return float2(p.z, -p.y);
    return float2(p.x, -p.y);
}

float3 enemySkin(int type) {
    if (type == 0) return float3(0.28f, 0.42f, 0.10f);
    if (type == 1) return float3(0.30f, 0.24f, 0.18f);
    if (type == 2) return float3(0.36f, 0.40f, 0.18f);
    if (type == 3) return float3(0.26f, 0.15f, 0.30f);
    return float3(0.34f, 0.40f, 0.46f);
}

float3 enemyCloth(int type) {
    if (type == 0) return float3(0.36f, 0.20f, 0.08f);
    if (type == 1) return float3(0.40f, 0.33f, 0.25f);
    if (type == 2) return float3(0.20f, 0.18f, 0.20f);
    if (type == 3) return float3(0.22f, 0.12f, 0.26f);
    return float3(0.36f, 0.22f, 0.10f);
}

float3 flagColour(float tier) {
    if (tier > 3.5f) return float3(0.62f, 0.05f, 0.04f);
    if (tier > 2.5f) return float3(0.08f, 0.16f, 0.55f);
    return float3(0.60f, 0.08f, 0.05f);
}

// Albedo of a hit plus how much it glows.
float3 materialAlbedo(thread const SceneHit &hit, float3 p, texture2d<float> atlas,
    float2 atlasSize, int enemy, thread float &glow) {
    glow = 0.0f;
    int m = hit.material;
    if (m == matStoneRound) {
        return atlasColor(atlas, atlasSize, tileStone, hit.part.xy / 2.4f) * 1.05f;
    }
    if (m == matStoneBox) {
        float3 c = atlasColor(atlas, atlasSize, tileStone, boxFaceUV(p, hit.normal) / 2.4f);
        return c * 1.05f;
    }
    if (m == matPaleStone) {
        float3 c = atlasColor(atlas, atlasSize, tileStone, hit.part.xy / 2.4f);
        return mix(float3(luminance(c)), float3(0.75f, 0.85f, 0.95f), 0.45f) * 1.25f;
    }
    if (m == matRoof) {
        float3 c = atlasColor(atlas, atlasSize, tileRoof, float2(hit.part.x, hit.part.y * 1.4f) / 1.5f);
        if (hit.tint > 2.5f && hit.tint < 3.5f) c = mix(c, float3(luminance(c)) * float3(0.55f, 0.65f, 1.1f), 0.6f);
        return c;
    }
    if (m == matWood) {
        return atlasColor(atlas, atlasSize, tileWood, float2(hit.part.x * 1.5f, hit.part.y) / 1.2f
            + p.xz * 0.3f) * 0.9f;
    }
    if (m == matGoldTrim) return float3(0.80f, 0.56f, 0.16f);
    if (m == matIron) return float3(0.10f, 0.10f, 0.11f);
    if (m == matIce) {
        glow = 0.8f;
        return float3(0.45f, 0.85f, 1.0f);
    }
    if (m == matFlag) return flagColour(hit.tint);
    if (m == matTrunk) return float3(0.22f, 0.14f, 0.08f);
    if (m == matFoliage) {
        float3 c = atlasColor(atlas, atlasSize, tileFoliage,
            (hit.part.xz + float2(hit.part.y * 0.7f, hit.tint * 3.0f)) / 0.9f);
        return c * mix(0.85f, 1.15f, hit.tint);
    }
    if (m == matPine) {
        float3 c = atlasColor(atlas, atlasSize, tileFoliage, hit.part.xy / 0.8f);
        return float3(0.10f, 0.22f, 0.13f) * (0.6f + 0.9f * luminance(c));
    }
    if (m == matRock) {
        float3 c = atlasColor(atlas, atlasSize, tileStone, (hit.part.xz + hit.part.y) / 1.2f);
        return mix(c, float3(luminance(c)), 0.5f) * 0.9f;
    }
    if (m == matGate) return float3(0.16f, 0.09f, 0.05f);
    if (m == matSkin) return enemySkin(enemy);
    if (m == matCloth) return enemyCloth(enemy);
    if (m == matMetal) return float3(0.46f, 0.47f, 0.50f);
    if (m == matWing) return float3(0.30f, 0.17f, 0.36f);
    if (m == matEye) {
        glow = 1.0f;
        return float3(1.0f, 0.25f, 0.1f);
    }
    if (m == matArrow) return float3(0.55f, 0.42f, 0.25f);
    if (m == matShell) return float3(0.06f, 0.06f, 0.07f);
    return float3(0.5f);
}

// ---------------------------------------------------------------------------
// Foes and shots

float3 toLocal(float3 v, float heading) {
    float c = cos(heading);
    float s = sin(heading);
    return float3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

float3 toWorld(float3 v, float heading) {
    float c = cos(heading);
    float s = sin(heading);
    return float3(v.x * c - v.z * s, v.y, v.x * s + v.z * c);
}

// Height of a foe's bounding-sphere centre above its feet (world units).
float enemyCentreHeight(int type) {
    if (type == 3) return 0.0f;
    if (type == 4) return 0.6f;
    if (type == 1) return 0.22f;
    return 0.38f;
}

// Traces one foe in its own frame (it faces local +x). The hit keeps the
// local normal; the caller rotates it back.
void traceEnemyParts(float3 lro, float3 lrd, int type, float phase, float lift, int slot,
    thread SceneHit &hit) {
    float bob = abs(sin(phase)) * 0.035f;
    if (type == 0) {
        traceEllipsoid(lro, lrd, float3(0.0f, 0.2f + bob, 0.0f), float3(0.11f, 0.14f, 0.12f),
            matCloth, slot, 0.0f, hit);
        traceSphere(lro, lrd, float3(0.03f, 0.4f + bob, 0.0f), 0.1f, matSkin, slot, 0.0f, hit);
        traceEllipsoid(lro, lrd, float3(0.0f, 0.43f + bob, 0.0f), float3(0.03f, 0.025f, 0.17f),
            matSkin, slot, 0.0f, hit);
        float swing = 0.04f * sin(phase);
        traceCapsule(lro, lrd, float3(-0.05f + swing, 0.1f + bob, 0.13f),
            float3(0.15f + swing, 0.62f + bob, 0.13f), 0.016f, matArrow, slot, 0.0f, hit);
    } else if (type == 1) {
        traceEllipsoid(lro, lrd, float3(0.0f, 0.2f + bob, 0.0f), float3(0.22f, 0.1f, 0.09f),
            matCloth, slot, 0.0f, hit);
        traceEllipsoid(lro, lrd, float3(0.22f, 0.28f + bob, 0.0f), float3(0.1f, 0.07f, 0.065f),
            matCloth, slot, 0.0f, hit);
        float stride = 0.07f * sin(phase);
        traceCapsule(lro, lrd, float3(0.12f, 0.17f, 0.0f), float3(0.12f + stride, 0.02f, 0.0f),
            0.035f, matSkin, slot, 0.0f, hit);
        traceCapsule(lro, lrd, float3(-0.13f, 0.17f, 0.0f), float3(-0.13f - stride, 0.02f, 0.0f),
            0.035f, matSkin, slot, 0.0f, hit);
        traceSphere(lro, lrd, float3(0.3f, 0.3f + bob, 0.035f), 0.018f, matEye, slot, 0.0f, hit);
    } else if (type == 2) {
        traceEllipsoid(lro, lrd, float3(0.0f, 0.28f + bob, 0.0f), float3(0.15f, 0.2f, 0.17f),
            matCloth, slot, 0.0f, hit);
        traceSphere(lro, lrd, float3(0.03f, 0.54f + bob, 0.0f), 0.11f, matSkin, slot, 0.0f, hit);
        traceEllipsoid(lro, lrd, float3(0.03f, 0.6f + bob, 0.0f), float3(0.115f, 0.06f, 0.115f),
            matMetal, slot, 0.0f, hit);
        traceEllipsoid(lro, lrd, float3(0.15f, 0.3f + bob, 0.11f), float3(0.035f, 0.15f, 0.12f),
            matMetal, slot, 0.0f, hit);
    } else if (type == 3) {
        float flap = 0.09f * sin(phase);
        traceSphere(lro, lrd, float3(0.0f, lift, 0.0f), 0.085f, matCloth, slot, 0.0f, hit);
        traceEllipsoid(lro, lrd, float3(-0.02f, lift + flap, 0.16f), float3(0.08f, 0.02f, 0.15f),
            matWing, slot, 0.0f, hit);
        traceEllipsoid(lro, lrd, float3(-0.02f, lift + flap, -0.16f), float3(0.08f, 0.02f, 0.15f),
            matWing, slot, 0.0f, hit);
        traceSphere(lro, lrd, float3(0.07f, lift + 0.03f, 0.03f), 0.02f, matEye, slot, 0.0f, hit);
        traceSphere(lro, lrd, float3(0.07f, lift + 0.03f, -0.03f), 0.02f, matEye, slot, 0.0f, hit);
    } else {
        traceEllipsoid(lro, lrd, float3(0.0f, 0.46f + bob, 0.0f), float3(0.25f, 0.33f, 0.27f),
            matSkin, slot, 0.0f, hit);
        traceEllipsoid(lro, lrd, float3(0.02f, 0.28f + bob, 0.0f), float3(0.26f, 0.12f, 0.28f),
            matCloth, slot, 0.0f, hit);
        traceSphere(lro, lrd, float3(0.12f, 0.86f + bob, 0.0f), 0.15f, matSkin, slot, 0.0f, hit);
        traceEllipsoid(lro, lrd, float3(0.12f, 0.99f + bob, 0.0f), float3(0.1f, 0.045f, 0.1f),
            matGoldTrim, slot, 0.0f, hit);
        float swing = 0.1f * sin(phase * 0.5f);
        traceCapsule(lro, lrd, float3(0.08f, 0.38f + bob, 0.3f),
            float3(0.3f + swing, 0.86f + bob, 0.34f), 0.065f, matTrunk, slot, 0.0f, hit);
    }
}

void traceEnemies(device const GameState &game, float3 ro, float3 rd, thread SceneHit &hit,
    thread int &hitType, thread float &hitFlash, thread float &hitSlow) {
    for (int i = 0; i < maxEnemies; ++i) {
        float4 stats = game.enemies[i].stats;
        if (stats.x < 0.0f) continue;
        int type = enemyType(stats.x);
        float4 body = game.enemies[i].body;
        float bound = enemyBoundTable[type];
        float3 centre = body.xyz + float3(0.0f, enemyCentreHeight(type), 0.0f);
        float3 op = centre - ro;
        float along = dot(op, rd);
        if (along - bound > hit.t) continue;
        if (dot(op, op) - along * along > bound * bound) continue;
        // Trace the model in its own scaled frame: dividing the origin by the
        // scale keeps the direction a unit vector and divides distances by it.
        float scale = enemyScaleTable[type];
        float3 base = float3(body.x, 0.0f, body.z);
        float3 lro = toLocal(ro - base, body.w) / scale;
        float3 lrd = toLocal(rd, body.w);
        SceneHit model = hit;
        model.t = hit.t / scale;
        model.owner = -100;
        traceEnemyParts(lro, lrd, type, game.enemies[i].status.w, body.y / scale, i, model);
        if (model.owner == i) {
            hit = model;
            hit.t = model.t * scale;
            hit.normal = toWorld(model.normal, body.w);
            hitType = type;
            hitFlash = game.enemies[i].status.z;
            hitSlow = game.enemies[i].status.x > 0.0f ? game.enemies[i].status.y : 0.0f;
        }
    }
}

void traceShots(device const GameState &game, float3 ro, float3 rd, thread SceneHit &hit) {
    for (int i = 0; i < maxShots; ++i) {
        float4 pos = game.shots[i].pos;
        if (pos.w < 0.0f) continue;
        if (rayPointDistance2(ro, rd, pos.xyz) > 0.06f) continue;
        if (pos.w < 0.5f) {
            float3 v = game.shots[i].vel.xyz;
            float3 back = pos.xyz - normalize(v) * 0.2f;
            traceCapsule(ro, rd, back, pos.xyz, 0.02f, matArrow, -3, 0.0f, hit);
        } else {
            traceSphere(ro, rd, pos.xyz, 0.075f, matShell, -3, 0.0f, hit);
        }
    }
}

// ---------------------------------------------------------------------------
// Ground

// Soft shadow of a vertical object: a capsule from its foot towards the
// shadow direction, length growing with height.
float blobShadow(float2 p, float2 foot, float radius, float height) {
    float2 tip = foot + shadowDirection * height * 0.55f;
    float d = segmentDistance(p, foot, tip);
    return 1.0f - smoothstep(radius * 0.55f, radius * 1.25f, d);
}

float staticShadow(device const GameState &game, float2 p) {
    int cx = int(floor(p.x));
    int cz = int(floor(p.y));
    float shade = 0.0f;
    for (int dz = -1; dz <= 2; ++dz) {
        for (int dx = -2; dx <= 1; ++dx) {
            int x = cx + dx;
            int z = cz + dz;
            if (x < 0 || z < 0 || x >= gridSize || z >= gridSize) continue;
            uint content = game.cells[z * gridSize + x];
            float2 foot = float2(float(x) + 0.5f, float(z) + 0.5f);
            if (content >= cellTowerBase) {
                int slot = int(content - cellTowerBase);
                if (slot >= maxTowers) continue;
                float4 place = game.towers[slot].place;
                float height = 1.0f;
                float radius = 0.36f;
                if (place.z < 0.5f) height = archerWallHeight(place.w) + 0.62f;
                else if (place.z < 1.5f) { height = cannonWallHeight(place.w) + 0.2f; radius = 0.46f; }
                else height = frostWallHeight(place.w) + 0.5f;
                shade = max(shade, blobShadow(p, foot, radius, height));
            } else if (content == cellTree) {
                shade = max(shade, 0.85f * blobShadow(p, foot + shadowDirection * 0.35f, 0.36f, 0.9f));
            } else if (content == cellPine) {
                shade = max(shade, 0.85f * blobShadow(p, foot, 0.3f, 1.3f));
            } else if (content == cellRock) {
                shade = max(shade, 0.7f * blobShadow(p, foot, 0.36f, 0.2f));
            }
        }
    }
    // The keep in the left corner.
    float2 q = p - float2(0.95f, 13.0f) - shadowDirection * 0.8f;
    float keep = 1.0f - smoothstep(-0.1f, 0.45f, sdRoundBox(q, float2(0.95f, 0.95f), 0.3f));
    return max(shade, keep * 0.9f);
}

float cellBorderDistance(float2 p, float2 cell) {
    float2 q = abs(p - cell - 0.5f);
    return 0.5f - max(q.x, q.y);
}

float3 verdictColour(float verdict) {
    if (verdict == verdictBuild) return float3(0.35f, 1.0f, 0.4f);
    if (verdict == verdictUpgrade) return float3(1.0f, 0.82f, 0.25f);
    if (verdict == verdictSell) return float3(1.0f, 0.55f, 0.15f);
    if (verdict == verdictMaxLevel) return float3(0.75f, 0.8f, 1.0f);
    return float3(1.0f, 0.25f, 0.2f);
}

// Range shown around the hovered cell, or zero.
float hoverRange(device const GameState &game) {
    if (game.hover.x != hoverCell) return 0.0f;
    float verdict = game.hover.w;
    int index = int(game.hover.z) * gridSize + int(game.hover.y);
    uint content = game.cells[clamp(index, 0, cellCount - 1)];
    if (content >= cellTowerBase && int(content - cellTowerBase) < maxTowers) {
        float4 place = game.towers[content - cellTowerBase].place;
        if (place.z >= 0.0f) return towerRangeTable[towerIndex(place.z, place.w)];
    }
    if ((verdict == verdictBuild || verdict == verdictBuildPoor) && game.input.y < 2.5f) {
        return towerRangeTable[towerIndex(game.input.y, 1.0f)];
    }
    return 0.0f;
}

float3 shadeGround(device const GameState &game, float3 g, texture2d<float> atlas,
    float2 atlasSize, float time, float enemyShade) {
    float2 p = g.xz;
    float3 grass = atlasColor(atlas, atlasSize, tileGrass, p / 7.0f);
    grass *= 0.9f + 0.2f * valueNoise(p * 0.7f, 3u);
    float3 colour = grass;
    float road = roadDistance(p);
    float3 cobble = atlasColor(atlas, atlasSize, tileCobble, p / 6.0f);
    float3 dirt = float3(0.20f, 0.14f, 0.08f) * (0.8f + 0.4f * valueNoise(p * 3.0f, 9u));
    colour = mix(colour, dirt, 1.0f - smoothstep(roadHalfWidth + 0.02f, roadHalfWidth + 0.12f, road));
    colour = mix(colour, cobble, 1.0f - smoothstep(roadHalfWidth - 0.06f, roadHalfWidth + 0.01f, road));
    float shade = max(staticShadow(game, p), enemyShade);
    // Effects on the ground: frost rings, scorch marks and build dust.
    float3 glow = float3(0.0f);
    for (int i = 0; i < maxEffects; ++i) {
        float4 e = game.effects[i].pos;
        if (e.w < 0.0f || e.w > 4.5f) continue;
        float4 info = game.effects[i].info;
        float a = clamp(info.x / max(info.y, 0.01f), 0.0f, 1.0f);
        float d = distance(p, e.xz);
        if (e.w > 0.5f && e.w < 1.5f) {
            float radius = info.z * (0.15f + 0.85f * sqrt(a));
            float ring = 1.0f - smoothstep(0.0f, 0.12f, abs(d - radius));
            float inside = (1.0f - smoothstep(radius - 0.05f, radius, d)) * 0.25f;
            glow += float3(0.45f, 0.85f, 1.0f) * (ring + inside) * (1.0f - a);
        } else if (e.w < 0.5f) {
            float scorch = 1.0f - smoothstep(info.z * 0.35f, info.z * 0.8f, d);
            shade = max(shade, scorch * 0.7f * (1.0f - a * a));
        } else if (e.w > 3.5f) {
            float ring = 1.0f - smoothstep(0.0f, 0.1f, abs(d - 0.3f - 0.4f * a));
            colour = mix(colour, float3(0.45f, 0.36f, 0.24f), ring * (1.0f - a) * 0.8f);
        }
    }
    float3 light = float3(0.40f, 0.43f, 0.50f) + float3(1.05f, 0.93f, 0.78f) * 0.81f * (1.0f - 0.62f * shade);
    colour *= light;
    // Placement aids: a faint grid near the cursor, the hovered cell and the range.
    if (game.hover.x == hoverCell && game.mode.x == screenPlaying) {
        float2 cell = game.hover.yz;
        float2 centre = cell + 0.5f;
        float nearby = 1.0f - smoothstep(1.5f, 3.0f, distance(p, centre));
        float2 f = abs(fract(p) - 0.5f);
        float grid = smoothstep(0.47f, 0.5f, max(f.x, f.y)) * nearby;
        colour *= 1.0f - 0.25f * grid;
        float border = cellBorderDistance(p, cell);
        if (border >= 0.0f) {
            float3 tint = verdictColour(game.hover.w);
            colour = mix(colour, tint, 0.18f);
            colour = mix(colour, tint * 1.3f, 1.0f - smoothstep(0.03f, 0.07f, border));
        }
        float range = hoverRange(game);
        if (range > 0.0f) {
            float d = distance(p, centre);
            float ring = 1.0f - smoothstep(0.015f, 0.05f, abs(d - range));
            colour = mix(colour, colour * 1.15f + float3(0.05f), (d < range ? 0.5f : 0.0f));
            colour = mix(colour, float3(1.0f, 0.95f, 0.7f), ring * 0.85f);
        }
    }
    return colour + glow;
}

// ---------------------------------------------------------------------------
// The scene

struct WorldSample {
    float3 colour;
    float depth;      // ray distance of the opaque surface
    bool board;       // the ray hit the board, an object or the keep
};

float3 shadeTable(float3 p, texture2d<float> atlas, float2 atlasSize) {
    float3 wood = atlasColor(atlas, atlasSize, tileWood, p.xz / 9.0f + float2(0.31f, 0.17f));
    float2 q = p.xz - float2(7.0f, 7.0f) - shadowDirection * 0.9f;
    float board = 1.0f - smoothstep(-0.2f, 1.4f, sdRoundBox(q, float2(7.0f), 0.4f));
    float distant = smoothstep(9.0f, 20.0f, length(p.xz - float2(7.0f)));
    float3 colour = wood * 0.7f * (1.0f - 0.55f * board);
    return mix(colour, colour * 0.35f, distant);
}

WorldSample renderWorld(device const GameState &game, float2 design, texture2d<float> atlas,
    float2 atlasSize, float time) {
    float3 ro = rayOrigin(design);
    float3 rd = viewDirection;
    SceneHit hit = noHit();
    float slabEntry = boxEntry(ro, rd, float3(0.0f, -boardDepth, 0.0f),
        float3(float(gridSize), 0.0f, float(gridSize)));
    traceStatic(game, ro, rd, time, hit);
    int hitType = -1;
    float hitFlash = 0.0f;
    float hitSlow = 0.0f;
    traceEnemies(game, ro, rd, hit, hitType, hitFlash, hitSlow);
    traceShots(game, ro, rd, hit);
    float tGround = ro.y / -rd.y;
    float3 g = ro + rd * tGround;
    bool onBoard = g.x >= 0.0f && g.z >= 0.0f && g.x <= float(gridSize) && g.z <= float(gridSize);
    WorldSample result;
    result.board = hit.material != matNone || slabEntry >= 0.0f;
    if (hit.material == matNone) {
        if (onBoard) {
            float enemyShade = 0.0f;
            for (int i = 0; i < maxEnemies; ++i) {
                float4 stats = game.enemies[i].stats;
                if (stats.x < 0.0f) continue;
                float4 body = game.enemies[i].body;
                float2 d = g.xz - body.xz - shadowDirection * body.y * 0.6f;
                float size = enemyBoundTable[enemyType(stats.x)] * 0.6f;
                enemyShade = max(enemyShade, (1.0f - smoothstep(size * 0.4f, size, length(d))) * 0.75f);
            }
            for (int i = 0; i < maxShots; ++i) {
                float4 pos = game.shots[i].pos;
                if (pos.w < 0.5f) continue;
                float2 d = g.xz - pos.xz - shadowDirection * pos.y * 0.6f;
                enemyShade = max(enemyShade, (1.0f - smoothstep(0.03f, 0.08f, length(d))) * 0.6f);
            }
            result.colour = shadeGround(game, g, atlas, atlasSize, time, enemyShade);
            result.depth = tGround;
            return result;
        }
        if (slabEntry >= 0.0f) {
            float3 p = ro + rd * slabEntry;
            float2 uv = abs(p.x - float(gridSize)) < 0.01f ? float2(p.z, -p.y) : float2(p.x, -p.y);
            float3 stone = atlasColor(atlas, atlasSize, tileStone, uv / 2.2f);
            float3 earth = mix(stone * float3(0.75f, 0.62f, 0.5f), float3(0.24f, 0.16f, 0.1f), 0.35f);
            float lip = 1.0f - smoothstep(-0.07f, -0.04f, p.y);
            float3 grassLip = atlasColor(atlas, atlasSize, tileGrass, p.xz / 7.0f) * 0.9f;
            float3 colour = mix(grassLip, earth, lip);
            bool rightFace = abs(p.x - float(gridSize)) < 0.01f;
            float light = rightFace ? 0.42f : 0.78f;
            colour *= light * (0.7f + 0.3f * smoothstep(-boardDepth, -0.1f, p.y));
            result.colour = colour;
            result.depth = slabEntry;
            return result;
        }
        float tTable = (ro.y + boardDepth) / -rd.y;
        result.colour = shadeTable(ro + rd * tTable, atlas, atlasSize);
        result.depth = tTable;
        return result;
    }
    float3 p = ro + rd * hit.t;
    float glow = 0.0f;
    float3 albedo = materialAlbedo(hit, p, atlas, atlasSize, max(hitType, 0), glow);
    float3 n = hit.normal;
    if (hit.material == matIce) {
        // Faceted crystal: quantize the normal.
        n = normalize(floor(n * 2.5f + 0.5f));
    }
    float diffuse = max(dot(n, sunDirection), 0.0f);
    float ambient = 0.45f + 0.25f * n.y;
    float occlusion = mix(0.72f, 1.0f, smoothstep(0.0f, 0.45f, p.y));
    float3 colour = albedo * (float3(0.42f, 0.45f, 0.53f) * ambient
        + float3(1.05f, 0.93f, 0.78f) * diffuse) * occlusion;
    float rim = pow(1.0f - max(dot(n, -rd), 0.0f), 3.0f);
    colour += albedo * rim * 0.25f;
    colour = mix(colour, albedo * 1.4f, glow);
    if (hit.material == matIce) colour += float3(0.2f, 0.45f, 0.6f) * (0.5f + 0.5f * sin(time * 3.0f));
    if (hitType >= 0) {
        colour = mix(colour, colour * float3(0.55f, 0.8f, 1.25f) + float3(0.04f, 0.08f, 0.14f),
            clamp(hitSlow * 1.6f, 0.0f, 1.0f));
        colour = mix(colour, float3(1.2f, 1.1f, 1.0f), clamp(hitFlash * 6.0f, 0.0f, 0.8f));
    }
    // Hovered tower highlight.
    if (game.hover.x == hoverCell && hit.owner >= 0
        && hit.owner == int(game.hover.z) * gridSize + int(game.hover.y)
        && hit.material != matSkin && hit.material != matCloth) {
        colour = mix(colour, verdictColour(game.hover.w), 0.18f + 0.06f * sin(time * 6.0f));
    }
    result.colour = colour;
    result.depth = hit.t;
    return result;
}

// Translucent effects in front of the opaque surface: blasts and puffs.
float3 addEffects(device const GameState &game, float2 design, float3 colour, float depth) {
    float3 ro = rayOrigin(design);
    float3 rd = viewDirection;
    for (int i = 0; i < maxEffects; ++i) {
        float4 e = game.effects[i].pos;
        if (e.w < -0.5f || (e.w > 0.5f && e.w < 1.5f) || e.w > 2.5f) continue;
        float4 info = game.effects[i].info;
        float a = clamp(info.x / max(info.y, 0.01f), 0.0f, 1.0f);
        float radius = e.w < 0.5f ? info.z * (0.25f + 0.55f * sqrt(a)) : 0.12f + 0.25f * a * info.z;
        float3 centre = e.xyz + float3(0.0f, e.w < 0.5f ? 0.15f + 0.3f * a : 0.0f, 0.0f);
        float3 op = centre - ro;
        float along = dot(op, rd);
        float d2 = dot(op, op) - along * along;
        if (d2 > radius * radius || along - radius > depth) continue;
        float thickness = sqrt(max(radius * radius - d2, 0.0f)) / radius;
        float alpha = thickness * (1.0f - a) * (e.w < 0.5f ? 0.85f : 0.6f);
        float3 tint = e.w < 0.5f
            ? mix(float3(2.2f, 1.2f, 0.35f), float3(0.35f, 0.32f, 0.3f), smoothstep(0.0f, 0.5f, a))
            : float3(0.85f, 0.85f, 0.8f);
        colour = mix(colour, tint, clamp(alpha, 0.0f, 1.0f));
    }
    return colour;
}

// Translucent preview of the tower that a click would build.
float3 addGhost(device const GameState &game, float2 design, float3 colour, float depth,
    float time) {
    if (game.hover.x != hoverCell || game.input.y > 2.5f) return colour;
    float verdict = game.hover.w;
    if (verdict != verdictBuild && verdict != verdictBuildPoor) return colour;
    float3 ro = rayOrigin(design);
    float3 rd = viewDirection;
    SceneHit ghost = noHit();
    float2 centre = game.hover.yz + 0.5f;
    traceTower(ro, rd, game.input.y, 1.0f, centre, 0.785f, 0.0f, time, -4, ghost);
    if (ghost.material == matNone || ghost.t > depth + 0.001f) {
        // Even behind other towers, hint at the hidden ghost.
        if (ghost.material != matNone) {
            return mix(colour, verdictColour(verdict), 0.18f);
        }
        return colour;
    }
    float shade = 0.55f + 0.45f * max(dot(ghost.normal, sunDirection), 0.0f);
    return mix(colour, verdictColour(verdict) * shade, 0.55f);
}

// Outline of the hovered cell drawn through anything in front of it.
float3 addHoverOutline(device const GameState &game, float2 design, float3 colour, float depth) {
    if (game.hover.x != hoverCell) return colour;
    float3 ro = rayOrigin(design);
    float3 rd = viewDirection;
    float tGround = ro.y / -rd.y;
    if (depth >= tGround - 0.01f) return colour;
    float3 g = ro + rd * tGround;
    float border = cellBorderDistance(g.xz, game.hover.yz);
    if (border < 0.0f) return colour;
    float line = 1.0f - smoothstep(0.03f, 0.07f, border);
    return mix(colour, verdictColour(game.hover.w), line * 0.55f);
}

// ---------------------------------------------------------------------------
// Text and HUD, drawn in the 960 x 600 design space after the world has been
// tone mapped. Colours here are display-linear; the fragment encodes sRGB last.

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
    return glyphDot(uint(textPool[start + character]), column - character * 6, int(spot.y));
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

uint wholeNumber(float value) {
    return uint(floor(clamp(value, 0.0f, 9999999.0f) + 0.5f));
}

uint numberChar(uint value, int index, int count) {
    uint v = value;
    for (int k = 0; k < 9; ++k) {
        if (k >= count - 1 - index) break;
        v /= 10u;
    }
    return 48u + v % 10u;
}

float numberCoverage(float2 p, float2 origin, float cell, float value) {
    uint v = wholeNumber(value);
    int count = int(digitCount(v));
    float2 spot = (p - origin) / cell;
    if (spot.x < 0.0f || spot.y < 0.0f || spot.y >= 7.0f || spot.x >= float(count * 6)) {
        return 0.0f;
    }
    int column = int(spot.x);
    int index = column / 6;
    return glyphDot(numberChar(v, index, count), column - index * 6, int(spot.y));
}

float numberWidth(float value, float cell) {
    return (float(digitCount(wholeNumber(value))) * 6.0f - 1.0f) * cell;
}

void drawText(thread float3 &colour, float2 p, float2 origin, float cell, int text,
    float3 ink, float alpha) {
    float shadow = textCoverage(p, origin + float2(max(cell * 0.5f, 1.0f)), cell, text);
    colour = mix(colour, float3(0.0f), 0.65f * shadow * alpha);
    colour = mix(colour, ink, textCoverage(p, origin, cell, text) * alpha);
}

void drawTextCentred(thread float3 &colour, float2 p, float centreX, float y, float cell,
    int text, float3 ink, float alpha) {
    drawText(colour, p, float2(floor(centreX - 0.5f * textWidth(text, cell)), y), cell, text,
        ink, alpha);
}

void drawNumber(thread float3 &colour, float2 p, float2 origin, float cell, float value,
    float3 ink, float alpha) {
    float shadow = numberCoverage(p, origin + float2(max(cell * 0.5f, 1.0f)), cell, value);
    colour = mix(colour, float3(0.0f), 0.65f * shadow * alpha);
    colour = mix(colour, ink, numberCoverage(p, origin, cell, value) * alpha);
}

// Text followed by a space and a number; returns the x after the number.
float drawTextNumber(thread float3 &colour, float2 p, float2 origin, float cell, int text,
    float value, float3 ink, float3 numberInk) {
    drawText(colour, p, origin, cell, text, ink, 1.0f);
    float x = origin.x + textWidth(text, cell) + 7.0f * cell;
    drawNumber(colour, p, float2(x, origin.y), cell, value, numberInk, 1.0f);
    return x + numberWidth(value, cell);
}

constant float3 inkWhite = float3(0.94f, 0.92f, 0.86f);
constant float3 inkGold = float3(1.0f, 0.78f, 0.30f);
constant float3 inkRed = float3(1.0f, 0.32f, 0.26f);
constant float3 inkGreen = float3(0.50f, 1.0f, 0.45f);
constant float3 inkDim = float3(0.55f, 0.53f, 0.50f);
constant float3 inkIce = float3(0.55f, 0.88f, 1.0f);

float rectCoverage(float2 p, float2 low, float2 high, float radius) {
    float d = sdRoundBox(p - 0.5f * (low + high), 0.5f * (high - low), radius);
    return clamp(0.5f - d, 0.0f, 1.0f);
}

// Dark rounded panel with a warm rim.
void panel(thread float3 &colour, float2 p, float2 low, float2 high, float alpha) {
    float d = sdRoundBox(p - 0.5f * (low + high), 0.5f * (high - low), 9.0f);
    if (d > 6.0f) return;
    float shadow = clamp(1.0f - (d - 1.0f) / 6.0f, 0.0f, 1.0f) * step(0.0f, d);
    colour = mix(colour, float3(0.0f), 0.35f * shadow * alpha);
    colour = mix(colour, float3(0.035f, 0.028f, 0.022f), clamp(0.5f - d, 0.0f, 1.0f) * alpha * 0.82f);
    float rim = clamp(1.0f - abs(d + 1.5f), 0.0f, 1.0f);
    colour = mix(colour, float3(0.62f, 0.45f, 0.20f), rim * 0.85f * alpha);
}

// Wooden card frame around a dark inner area.
void woodCard(thread float3 &colour, float2 p, float2 low, float2 high, texture2d<float> atlas,
    float2 atlasSize, float3 rimColour, float rimAmount) {
    float2 centre = 0.5f * (low + high);
    float2 halfSize = 0.5f * (high - low);
    float outer = sdRoundBox(p - centre, halfSize, 8.0f);
    if (outer > 7.0f) return;
    float shadow = clamp(1.0f - (outer - 1.0f) / 6.0f, 0.0f, 1.0f) * step(0.0f, outer);
    colour = mix(colour, float3(0.0f), 0.4f * shadow);
    float inner = sdRoundBox(p - centre, halfSize - float2(5.0f), 4.0f);
    float3 grain = atlasColor(atlas, atlasSize, tileWood, p / 160.0f) * 1.25f;
    float bevel = clamp(1.0f - abs(inner) / 3.0f, 0.0f, 1.0f);
    float3 frame = grain * (1.0f - 0.4f * bevel);
    colour = mix(colour, frame, clamp(0.5f - outer, 0.0f, 1.0f));
    colour = mix(colour, float3(0.05f, 0.04f, 0.035f), clamp(0.5f - inner, 0.0f, 1.0f) * 0.9f);
    float rim = clamp(1.5f - abs(outer + 1.0f), 0.0f, 1.0f);
    colour = mix(colour, rimColour, rim * rimAmount);
}

void coinIcon(thread float3 &colour, float2 p, float2 centre, float radius) {
    float d = length(p - centre);
    if (d > radius + 2.0f) return;
    float body = clamp(radius + 0.5f - d, 0.0f, 1.0f);
    float shine = 0.75f + 0.35f * clamp(dot(normalize(p - centre + float2(0.001f)),
        float2(-0.6f, -0.8f)), -1.0f, 1.0f);
    colour = mix(colour, float3(0.95f, 0.66f, 0.12f) * shine, body);
    float inner = clamp(1.2f - abs(d - radius * 0.62f), 0.0f, 1.0f);
    colour = mix(colour, float3(0.62f, 0.38f, 0.05f), inner * body * 0.8f);
}

void heartIcon(thread float3 &colour, float2 p, float2 centre, float size, float3 tint) {
    float2 q = (p - centre) / size;
    q.y = -q.y + 0.25f;
    q.x = abs(q.x);
    float d;
    if (q.y + q.x > 1.0f) {
        d = sqrt(dot(q - float2(0.25f, 0.75f), q - float2(0.25f, 0.75f))) - 0.3536f;
    } else {
        float2 a = q - float2(0.0f, 1.0f);
        float2 b = q - 0.5f * max(q.x + q.y, 0.0f);
        d = sqrt(min(dot(a, a), dot(b, b))) * sign(q.x - q.y);
    }
    colour = mix(colour, tint, clamp(0.5f - d * size, 0.0f, 1.0f));
}

float segmentCoverage(float2 p, float2 a, float2 b, float width) {
    return clamp(width - segmentDistance(p, a, b) + 0.5f, 0.0f, 1.0f);
}

void towerIcon(thread float3 &colour, float2 p, float2 c, int type, float dim) {
    float2 q = p - c;
    if (dot(q, q) > 26.0f * 26.0f) return;
    float3 ink = mix(float3(0.92f, 0.86f, 0.70f), inkDim, dim);
    if (type == 0) {
        // Bow and arrow.
        float r = length(q - float2(-8.0f, 0.0f));
        float arc = clamp(1.6f - abs(r - 17.0f), 0.0f, 1.0f) * step(-2.0f, q.x);
        colour = mix(colour, float3(0.55f, 0.34f, 0.15f) * (1.0f - 0.5f * dim), arc);
        colour = mix(colour, ink, segmentCoverage(p, c + float2(0.0f, -14.0f), c + float2(0.0f, 14.0f), 0.5f));
        colour = mix(colour, ink, segmentCoverage(p, c + float2(-6.0f, 0.0f), c + float2(16.0f, 0.0f), 1.0f));
        float head = clamp(1.0f - (abs(q.y) * 1.2f + (q.x - 16.0f)) * 0.5f, 0.0f, 1.0f)
            * step(10.0f, q.x) * step(q.x, 18.0f);
        colour = mix(colour, ink, head);
    } else if (type == 1) {
        // Cannon: barrel, wheel and a ball.
        float2 axis = normalize(float2(1.0f, -0.55f));
        float barrel = segmentCoverage(p, c + float2(-12.0f, 6.0f), c + float2(-12.0f, 6.0f) + axis * 26.0f, 5.0f);
        colour = mix(colour, float3(0.16f, 0.16f, 0.18f) + 0.25f * (1.0f - dim), barrel);
        float wheel = clamp(2.0f - abs(length(q - float2(-4.0f, 9.0f)) - 7.0f), 0.0f, 1.0f);
        colour = mix(colour, float3(0.55f, 0.34f, 0.15f) * (1.0f - 0.5f * dim), wheel);
        float ball = clamp(4.5f - length(q - float2(15.0f, 10.0f)), 0.0f, 1.0f);
        colour = mix(colour, float3(0.2f, 0.2f, 0.22f) + 0.2f * (1.0f - dim), ball);
    } else if (type == 2) {
        // Snowflake.
        float flake = 0.0f;
        for (int i = 0; i < 3; ++i) {
            float a = 3.14159265f * float(i) / 3.0f + 0.2617994f;
            float2 d = float2(cos(a), sin(a)) * 15.0f;
            flake = max(flake, segmentCoverage(p, c - d, c + d, 1.2f));
            for (int s = -1; s <= 1; s += 2) {
                float2 tip = c + d * 0.62f * float(s);
                float2 side = float2(-d.y, d.x) * 0.22f;
                flake = max(flake, segmentCoverage(p, tip, tip + d * 0.25f * float(s) + side, 0.9f));
                flake = max(flake, segmentCoverage(p, tip, tip + d * 0.25f * float(s) - side, 0.9f));
            }
        }
        colour = mix(colour, mix(inkIce, inkDim, dim), flake);
    } else {
        coinIcon(colour, p, c + float2(-5.0f, 3.0f), 11.0f);
        float arrow = segmentCoverage(p, c + float2(9.0f, 12.0f), c + float2(9.0f, -12.0f), 1.5f);
        arrow = max(arrow, segmentCoverage(p, c + float2(9.0f, -12.0f), c + float2(3.0f, -5.0f), 1.5f));
        arrow = max(arrow, segmentCoverage(p, c + float2(9.0f, -12.0f), c + float2(15.0f, -5.0f), 1.5f));
        colour = mix(colour, inkGreen * (1.0f - 0.4f * dim), arrow);
    }
}

void drawBar(thread float3 &colour, float2 p, float2 low, float2 size, float fraction,
    float3 fill) {
    if (p.x < low.x - 2.0f || p.y < low.y - 2.0f || p.x > low.x + size.x + 2.0f
        || p.y > low.y + size.y + 2.0f) return;
    float2 high = low + size;
    colour = mix(colour, float3(0.02f), rectCoverage(p, low - 1.0f, high + 1.0f, 2.0f) * 0.9f);
    float2 fillHigh = float2(low.x + size.x * clamp(fraction, 0.0f, 1.0f), high.y);
    colour = mix(colour, fill, rectCoverage(p, low, fillHigh, 1.0f));
}

int towerName(int type) {
    if (type == 0) return textArcherTower;
    if (type == 1) return textCannonTower;
    if (type == 2) return textFrostTower;
    return textSellTowers;
}

int towerInfo(int type) {
    if (type == 0) return textArcherInfo;
    if (type == 1) return textCannonInfo;
    if (type == 2) return textFrostInfo;
    return textSellInfo;
}

int cardName(int type) {
    if (type == 0) return textArcher;
    if (type == 1) return textCannon;
    if (type == 2) return textFrost;
    return textSell;
}

int waveText(float wave) {
    int w = int(wave);
    if (w <= 1) return textWave1;
    if (w == 2) return textWave2;
    if (w == 3) return textWave3;
    if (w == 4) return textWave4;
    if (w == 5) return textWave5;
    if (w == 6) return textWave6;
    if (w == 7) return textWave7;
    if (w == 8) return textWave8;
    if (w == 9) return textWave9;
    return textWave10;
}

float foesInWave(float wave) {
    int w = clamp(int(wave) - 1, 0, waveCount - 1);
    float total = 0.0f;
    for (int g = 0; g < 3; ++g) {
        float4 group = waveTable[w * 3 + g];
        if (group.x >= 0.0f) total += group.y;
    }
    return total;
}

void drawInfoPanel(thread float3 &colour, float2 p, device const GameState &game) {
    float2 low = float2(600.0f, 506.0f);
    float2 high = float2(948.0f, 590.0f);
    if (p.x < low.x - 8.0f || p.y < low.y - 8.0f) return;
    panel(colour, p, low, high, 1.0f);
    float x = low.x + 12.0f;
    float tool = game.input.y;
    int title = towerName(int(tool));
    int line2 = towerInfo(int(tool));
    int line3 = pickInt(tool > 2.5f, textRefund, textGrassHint);
    float3 ink3 = inkWhite;
    float number = -1.0f;
    float tier = 0.0f;
    float kind = game.hover.x;
    if (kind == hoverCard) {
        int card = int(game.hover.y);
        title = towerName(card);
        line2 = towerInfo(card);
        line3 = pickInt(card == 3, textRefund, textCost);
        if (card < 3) {
            number = toolCost(float(card));
            ink3 = pickColour(game.economy.x >= number, inkGold, inkRed);
        }
    } else if (kind == hoverCall) {
        title = textCallTitle;
        line2 = textCallInfo;
        line3 = textGold;
        number = floor(max(game.wave.z, 0.0f) * 0.5f);
        ink3 = inkGold;
    } else if (kind == hoverSpeed) {
        title = textSpeed;
        line2 = textSpeedInfo;
        line3 = -1;
    } else if (kind == hoverCell) {
        float verdict = game.hover.w;
        int index = int(game.hover.z) * gridSize + int(game.hover.y);
        uint content = game.cells[clamp(index, 0, cellCount - 1)];
        if (content >= cellTowerBase && int(content - cellTowerBase) < maxTowers) {
            float4 place = game.towers[content - cellTowerBase].place;
            float4 fire = game.towers[content - cellTowerBase].fire;
            title = towerName(int(place.z));
            line2 = towerInfo(int(place.z));
            tier = place.w;
            if (verdict == verdictSell) {
                line3 = textSellFor;
                number = floor(fire.w * 0.7f);
                ink3 = inkGold;
            } else if (verdict == verdictMaxLevel) {
                line3 = textMaxLevel;
                ink3 = inkIce;
            } else {
                line3 = textUpgradeFor;
                number = towerCostTable[towerIndex(place.z, place.w + 1.0f)];
                ink3 = pickColour(verdict == verdictUpgrade, inkGold, inkRed);
            }
        } else if (verdict == verdictBuild || verdict == verdictBuildPoor) {
            line3 = textBuildFor;
            number = toolCost(tool);
            ink3 = pickColour(verdict == verdictBuild, inkGold, inkRed);
        } else if (verdict == verdictRoad) {
            title = textRoadHere;
            line2 = -1;
            line3 = -1;
        } else if (verdict == verdictKeep) {
            title = textKeepName;
            line2 = textKeepInfo;
            line3 = -1;
        } else if (verdict == verdictNoSell) {
            title = textSellTowers;
            line2 = textSellInfo;
            line3 = textRefund;
        } else {
            title = textBlocked;
            line2 = -1;
            line3 = -1;
        }
    }
    drawText(colour, p, float2(x, low.y + 10.0f), 2.0f, title, inkGold, 1.0f);
    if (tier > 0.5f) {
        float lx = x + textWidth(title, 2.0f) + 14.0f;
        drawTextNumber(colour, p, float2(lx, low.y + 10.0f), 2.0f, textLevel, tier, inkIce, inkIce);
    }
    if (line2 >= 0) drawText(colour, p, float2(x, low.y + 34.0f), 2.0f, line2, inkWhite, 1.0f);
    if (line3 >= 0) {
        float2 origin = float2(x, low.y + 58.0f);
        drawText(colour, p, origin, 2.0f, line3, ink3, 1.0f);
        if (number >= 0.0f) {
            float nx = origin.x + textWidth(line3, 2.0f) + 14.0f;
            coinIcon(colour, p, float2(nx + 6.0f, origin.y + 6.5f), 6.5f);
            drawNumber(colour, p, float2(nx + 17.0f, origin.y), 2.0f, number, ink3, 1.0f);
        }
    }
}

void drawCards(thread float3 &colour, float2 p, device const GameState &game,
    texture2d<float> atlas, float2 atlasSize, float time) {
    if (p.y < 480.0f || p.x > 340.0f) return;
    for (int card = 0; card < 4; ++card) {
        bool selected = int(game.input.y) == card;
        bool hovered = game.hover.x == hoverCard && int(game.hover.y) == card;
        float lift = selected ? -5.0f : 0.0f;
        float2 low = cardLow(card) + float2(0.0f, lift);
        float2 high = low + cardSize;
        if (p.x < low.x - 8.0f || p.x > high.x + 8.0f) continue;
        float3 rim = selected ? float3(1.0f, 0.8f, 0.3f) : float3(0.9f, 0.85f, 0.7f);
        float rimAmount = selected ? 0.9f + 0.1f * sin(time * 5.0f) : (hovered ? 0.6f : 0.0f);
        woodCard(colour, p, low, high, atlas, atlasSize, rim, rimAmount);
        float cost = card < 3 ? toolCost(float(card)) : 0.0f;
        float dim = card < 3 && game.economy.x < cost ? 1.0f : 0.0f;
        towerIcon(colour, p, low + float2(35.0f, 31.0f), card, dim);
        int name = cardName(card);
        drawTextCentred(colour, p, low.x + 35.0f, low.y + 55.0f, 1.0f, name, inkWhite, 1.0f);
        if (card < 3) {
            float w = numberWidth(cost, 2.0f) + 15.0f;
            float x0 = low.x + 35.0f - 0.5f * w;
            coinIcon(colour, p, float2(x0 + 5.5f, low.y + 72.5f), 5.5f);
            drawNumber(colour, p, float2(x0 + 15.0f, low.y + 66.0f), 2.0f, cost,
                pickColour(dim > 0.5f, inkRed, inkGold), 1.0f);
        } else {
            // "70%" refund label.
            drawNumber(colour, p, float2(low.x + 18.0f, low.y + 66.0f), 2.0f, 70.0f, inkGreen, 1.0f);
            float2 spot = (p - float2(low.x + 42.0f, low.y + 66.0f)) / 2.0f;
            if (spot.x >= 0.0f && spot.y >= 0.0f) {
                colour = mix(colour, inkGreen, glyphDot(37u, int(spot.x), int(spot.y)));
            }
        }
    }
}

void drawTopPanels(thread float3 &colour, float2 p, device const GameState &game, float time) {
    if (p.y > 120.0f) return;
    if (p.x < 300.0f) {
        panel(colour, p, float2(12.0f, 12.0f), float2(292.0f, 100.0f), 1.0f);
        coinIcon(colour, p, float2(36.0f, 38.0f), 11.0f);
        float3 goldInk = mix(inkGold, inkRed, clamp(game.flashes.y * 2.0f, 0.0f, 1.0f));
        drawNumber(colour, p, float2(56.0f, 28.0f), 3.0f, game.economy.x, goldInk, 1.0f);
        if (game.flashes.w > 0.0f && game.flashes.z > 0.0f) {
            float x = 56.0f + numberWidth(game.economy.x, 3.0f) + 10.0f;
            float alpha = clamp(game.flashes.w, 0.0f, 1.0f);
            drawText(colour, p, float2(x, 32.0f - 6.0f * (2.0f - game.flashes.w)), 2.0f, textPlus,
                inkGreen, alpha);
            drawNumber(colour, p, float2(x + 12.0f, 32.0f - 6.0f * (2.0f - game.flashes.w)), 2.0f,
                game.flashes.z, inkGreen, alpha);
        }
        float3 heart = mix(float3(0.85f, 0.12f, 0.12f), float3(1.0f, 0.6f, 0.5f),
            clamp(game.flashes.x, 0.0f, 1.0f));
        heartIcon(colour, p, float2(36.0f, 75.0f), 11.0f, heart);
        drawNumber(colour, p, float2(56.0f, 65.0f), 3.0f, game.economy.y,
            mix(inkWhite, inkRed, clamp(game.flashes.x, 0.0f, 1.0f)), 1.0f);
        drawText(colour, p, float2(150.0f, 70.0f), 2.0f, textScore, inkDim, 1.0f);
        drawNumber(colour, p, float2(216.0f, 70.0f), 2.0f, game.economy.z, inkWhite, 1.0f);
    } else if (p.x > 660.0f) {
        panel(colour, p, float2(668.0f, 12.0f), float2(948.0f, 112.0f), 1.0f);
        float wave = max(game.wave.x, 1.0f);
        if (game.wave.w < 0.5f && game.wave.x < float(waveCount)) wave = game.wave.x + 1.0f;
        float x = drawTextNumber(colour, p, float2(684.0f, 22.0f), 3.0f, textWave, wave, inkWhite, inkGold);
        drawText(colour, p, float2(x + 18.0f, 22.0f), 3.0f, textOf, inkDim, 1.0f);
        drawNumber(colour, p, float2(x + 18.0f + textWidth(textOf, 3.0f) + 18.0f, 22.0f), 3.0f,
            float(waveCount), inkDim, 1.0f);
        if (game.wave.w < 0.5f) {
            drawTextNumber(colour, p, float2(684.0f, 52.0f), 2.0f, textNextWaveIn,
                ceil(max(game.wave.z, 0.0f)), inkWhite, inkGold);
            bool hot = game.hover.x == hoverCall;
            float pulse = 0.5f + 0.5f * sin(time * 4.0f);
            colour = mix(colour, mix(float3(0.22f, 0.16f, 0.06f), float3(0.42f, 0.30f, 0.10f),
                hot ? 1.0f : 0.3f * pulse), rectCoverage(p, callLow, callHigh, 6.0f));
            float rim = clamp(1.0f - abs(sdRoundBox(p - 0.5f * (callLow + callHigh),
                0.5f * (callHigh - callLow), 6.0f) + 1.0f), 0.0f, 1.0f);
            colour = mix(colour, inkGold, rim * 0.8f);
            drawText(colour, p, callLow + float2(10.0f, 9.0f), 2.0f, textCallNow, inkWhite, 1.0f);
            float bonus = floor(max(game.wave.z, 0.0f) * 0.5f);
            float bx = callLow.x + 10.0f + textWidth(textCallNow, 2.0f) + 12.0f;
            drawText(colour, p, float2(bx, callLow.y + 9.0f), 2.0f, textPlus, inkGreen, 1.0f);
            drawNumber(colour, p, float2(bx + 12.0f, callLow.y + 9.0f), 2.0f, bonus, inkGreen, 1.0f);
        } else {
            float total = foesInWave(game.wave.x);
            float spawned = game.spawn[0].x + game.spawn[1].x + game.spawn[2].x;
            float left = total - spawned + float(aliveEnemies(game));
            drawTextNumber(colour, p, float2(684.0f, 52.0f), 2.0f, textFoes, left, inkWhite, inkRed);
            drawBar(colour, p, float2(686.0f, 80.0f), float2(162.0f, 10.0f),
                1.0f - left / max(total, 1.0f), float3(0.85f, 0.62f, 0.2f));
        }
        bool fast = game.mode.w > 1.5f;
        bool hot = game.hover.x == hoverSpeed;
        colour = mix(colour, fast ? float3(0.12f, 0.30f, 0.12f) : float3(0.12f, 0.11f, 0.10f),
            rectCoverage(p, speedLow, speedHigh, 6.0f));
        float rim = clamp(1.0f - abs(sdRoundBox(p - 0.5f * (speedLow + speedHigh),
            0.5f * (speedHigh - speedLow), 6.0f) + 1.0f), 0.0f, 1.0f);
        colour = mix(colour, pickColour(hot, inkGold, float3(0.5f, 0.45f, 0.35f)), rim * 0.8f);
        float2 c = 0.5f * (speedLow + speedHigh);
        for (int i = 0; i < 2; ++i) {
            float2 q = p - (c + float2(-17.0f + 9.0f * float(i), 0.0f));
            float tri = max(-q.x - 5.0f, q.x * 0.6f + abs(q.y) - 3.5f);
            colour = mix(colour, pickColour(fast, inkGreen, inkWhite), clamp(0.5f - tri, 0.0f, 1.0f));
        }
        drawNumber(colour, p, c + float2(4.0f, -7.0f), 2.0f, fast ? 2.0f : 1.0f,
            pickColour(fast, inkGreen, inkWhite), 1.0f);
        drawText(colour, p, c + float2(16.0f, -7.0f), 2.0f, textX, pickColour(fast, inkGreen, inkWhite), 1.0f);
    }
}

void drawWorldLabels(thread float3 &colour, float2 p, device const GameState &game) {
    for (int i = 0; i < maxEnemies; ++i) {
        float4 stats = game.enemies[i].stats;
        if (stats.x < 0.0f || stats.y >= stats.z) continue;
        int type = enemyType(stats.x);
        float top = 0.78f;
        if (type == 1) top = 0.5f;
        if (type == 2) top = 0.92f;
        if (type == 3) top = 0.28f;
        if (type == 4) top = 1.25f;
        float4 body = game.enemies[i].body;
        float2 s = projectToDesign(body.xyz + float3(0.0f, top, 0.0f));
        float width = type == 4 ? 44.0f : 22.0f;
        float2 low = s + float2(-0.5f * width, -9.0f);
        float fraction = stats.y / max(stats.z, 1.0f);
        float3 fill = mix(float3(0.95f, 0.2f, 0.12f), float3(0.35f, 0.9f, 0.25f),
            smoothstep(0.2f, 0.7f, fraction));
        drawBar(colour, p, low, float2(width, 3.0f), fraction, fill);
    }
    for (int i = 0; i < maxEffects; ++i) {
        float4 e = game.effects[i].pos;
        if (e.w < 2.5f || e.w > 3.5f) continue;
        float4 info = game.effects[i].info;
        float a = clamp(info.x / max(info.y, 0.01f), 0.0f, 1.0f);
        float2 s = projectToDesign(e.xyz) + float2(0.0f, -26.0f * a - 6.0f);
        float w = numberWidth(info.z, 2.0f) + 12.0f;
        if (abs(p.x - s.x) > w || abs(p.y - s.y) > 12.0f) continue;
        float alpha = 1.0f - a * a;
        drawText(colour, p, s - float2(0.5f * w, 7.0f), 2.0f, textPlus, inkGold, alpha);
        drawNumber(colour, p, s - float2(0.5f * w - 12.0f, 7.0f), 2.0f, info.z, inkGold, alpha);
    }
}

void drawMessages(thread float3 &colour, float2 p, device const GameState &game) {
    if (game.notice.w > 0.0f) {
        float w = game.notice.w;
        float alpha = (1.0f - smoothstep(3.1f, 3.5f, w)) * smoothstep(0.0f, 0.5f, w);
        if (p.y > 236.0f && p.y < 340.0f) {
            float band = smoothstep(236.0f, 252.0f, p.y) * (1.0f - smoothstep(324.0f, 340.0f, p.y));
            colour = mix(colour, float3(0.03f, 0.02f, 0.015f), 0.6f * band * alpha);
            float wave = game.notice.z;
            float cell = 5.0f;
            float width = textWidth(textWave, cell) + 7.0f * cell + numberWidth(wave, cell);
            float x = 480.0f - 0.5f * width;
            drawText(colour, p, float2(x, 252.0f), cell, textWave, inkWhite, alpha);
            drawNumber(colour, p, float2(x + textWidth(textWave, cell) + 7.0f * cell, 252.0f), cell,
                wave, inkGold, alpha);
            drawTextCentred(colour, p, 480.0f, 302.0f, 2.0f, waveText(wave),
                pickColour(wave > 9.5f, inkRed, inkWhite), alpha);
        }
    }
    if (game.notice.x >= 0.0f && game.notice.y > 0.0f && p.y > 566.0f) {
        int text = int(game.notice.x);
        float3 ink = inkGold;
        if (text == textNoGold || text == textCannotBuild || text == textLeak
            || text == textNothingToSell || text == textAlreadyMax) ink = inkRed;
        float alpha = clamp(game.notice.y * 2.0f, 0.0f, 1.0f);
        drawTextCentred(colour, p, 459.0f, 572.0f, 2.0f, text, ink, alpha);
    }
}

void drawHud(thread float3 &colour, float2 p, device const GameState &game,
    texture2d<float> atlas, float2 atlasSize, float time) {
    drawTopPanels(colour, p, game, time);
    drawCards(colour, p, game, atlas, atlasSize, time);
    drawInfoPanel(colour, p, game);
    drawMessages(colour, p, game);
}

// ---------------------------------------------------------------------------
// Screens

float3 posterColour(texture2d<float> poster, float2 p, float time) {
    constexpr sampler posterSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float zoom = 1.04f + 0.03f * sin(time * 0.07f);
    float2 uv = (p - float2(480.0f, 300.0f)) / (960.0f * zoom) + 0.5f;
    float4 c = poster.sample(posterSampler, uv);
    return srgbToLinear(clamp(c.rgb / max(c.a, 0.001f), float3(0.0f), float3(1.0f)));
}

float3 drawTitle(float2 p, device const GameState &game, texture2d<float> poster, float time) {
    float3 colour = posterColour(poster, p, time);
    float top = 1.0f - smoothstep(30.0f, 150.0f, p.y);
    colour = mix(colour, float3(0.02f, 0.015f, 0.01f), 0.62f * top);
    colour = 1.0f - exp(-colour * 1.6f);
    panel(colour, p, float2(110.0f, 378.0f), float2(850.0f, 584.0f), 0.92f);
    float cell = 6.0f;
    drawTextCentred(colour, p, 480.0f, 34.0f, cell, textTitle, inkGold, 1.0f);
    drawTextCentred(colour, p, 480.0f, 92.0f, 2.0f, textSubtitle, inkWhite, 1.0f);
    for (int i = 0; i < 6; ++i) {
        drawTextCentred(colour, p, 480.0f, 394.0f + 22.0f * float(i), 2.0f, textHow1 + i,
            pickColour(i == 5, inkGold, inkWhite), 1.0f);
    }
    float pulse = 0.65f + 0.35f * sin(time * 4.0f);
    drawTextCentred(colour, p, 480.0f, 540.0f, 3.0f, textPressBegin, inkGold, pulse);
    return colour;
}

void drawEndScreen(thread float3 &colour, float2 p, device const GameState &game, float time) {
    bool won = game.mode.x == screenVictory;
    float fade = clamp(game.mode.y * 2.0f, 0.0f, 1.0f);
    colour = mix(colour, colour * 0.35f, fade);
    if (won) {
        float glow = 1.0f - smoothstep(0.0f, 420.0f, length(p - float2(480.0f, 260.0f)));
        colour += float3(0.35f, 0.25f, 0.08f) * glow * fade * (0.6f + 0.2f * sin(time * 2.0f));
    } else {
        colour = mix(colour, float3(0.25f, 0.02f, 0.02f), 0.25f * fade);
    }
    panel(colour, p, float2(240.0f, 130.0f), float2(720.0f, 470.0f), fade);
    drawTextCentred(colour, p, 480.0f, 156.0f, 4.0f, pickInt(won, textVictory, textDefeat),
        pickColour(won, inkGold, inkRed), fade);
    float y = 222.0f;
    float labelX = 300.0f;
    float valueX = 560.0f;
    drawText(colour, p, float2(labelX, y), 2.0f, textWavesHeld, inkWhite, fade);
    float x = valueX;
    drawNumber(colour, p, float2(x, y), 2.0f, float(game.counters.y), inkGold, fade);
    x += numberWidth(float(game.counters.y), 2.0f) + 12.0f;
    drawText(colour, p, float2(x, y), 2.0f, textOf, inkDim, fade);
    drawNumber(colour, p, float2(x + textWidth(textOf, 2.0f) + 12.0f, y), 2.0f,
        float(waveCount), inkDim, fade);
    drawText(colour, p, float2(labelX, y + 30.0f), 2.0f, textFoesDefeated, inkWhite, fade);
    drawNumber(colour, p, float2(valueX, y + 30.0f), 2.0f, game.economy.w, inkGold, fade);
    drawText(colour, p, float2(labelX, y + 60.0f), 2.0f, textLivesLeft, inkWhite, fade);
    drawNumber(colour, p, float2(valueX, y + 60.0f), 2.0f, game.economy.y, inkGold, fade);
    drawText(colour, p, float2(labelX, y + 100.0f), 3.0f, textFinalScore, inkWhite, fade);
    drawNumber(colour, p, float2(valueX, y + 100.0f), 3.0f, game.economy.z, inkGold, fade);
    drawText(colour, p, float2(labelX, y + 140.0f), 2.0f, textBest, inkDim, fade);
    drawNumber(colour, p, float2(valueX, y + 140.0f), 2.0f, float(game.counters.w), inkDim, fade);
    if (game.mode.y > 1.0f) {
        float pulse = 0.65f + 0.35f * sin(time * 4.0f);
        drawTextCentred(colour, p, 480.0f, 428.0f, 2.0f, textAgain, inkGold, pulse);
    }
}

// Arrow cursor at the Trackpad position.
void drawCursor(thread float3 &colour, float2 p, float2 cursor) {
    float2 q = p - cursor;
    if (q.x < -4.0f || q.y < -4.0f || q.x > 22.0f || q.y > 26.0f) return;
    // Arrow: tip at the pointer, edges down and to the lower right, with a tail.
    float left = -q.x;
    float right = dot(q, normalize(float2(0.8f, -0.6f)));
    float bottom = dot(q, normalize(float2(0.45f, 0.9f))) - 15.5f;
    float arrow = max(max(left, right), bottom);
    float tail = segmentDistance(q, float2(6.0f, 12.0f), float2(10.5f, 20.5f)) - 2.2f;
    float d = min(arrow, tail);
    colour = mix(colour, float3(0.0f), clamp(2.0f - d, 0.0f, 1.0f) * 0.85f);
    colour = mix(colour, float3(1.0f, 0.97f, 0.9f), clamp(0.5f - d, 0.0f, 1.0f));
}

// ---------------------------------------------------------------------------
// Present

vertex ScreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2(float((vertexID << 1u) & 2u), float(vertexID & 2u));
    ScreenVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

fragment float4 keepFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> atlas [[texture(1)]],
    texture2d<float> poster [[texture(2)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 p = toDesign(in.uv * resolution, resolution);
    float time = u.resolutionTime.z;
    float2 cursor = toDesign(u.pointer.xy * resolution, resolution);
    float3 colour;
    if (game.mode.x == screenTitle) {
        colour = drawTitle(p, game, poster, time);
    } else {
        WorldSample world = renderWorld(game, p, atlas, resolution, time);
        float3 c = addEffects(game, p, world.colour, world.depth);
        if (game.mode.x == screenPlaying) {
            c = addGhost(game, p, c, world.depth, time);
            c = addHoverOutline(game, p, c, world.depth);
        }
        colour = 1.0f - exp(-max(c, float3(0.0f)) * 1.3f);
        float2 centred = p / float2(designWidth, designHeight) - 0.5f;
        float edge = smoothstep(0.3f, 0.75f, length(centred * float2(1.0f, 1.25f)));
        colour *= 1.0f - 0.35f * edge;
        colour = mix(colour, float3(0.8f, 0.05f, 0.03f), 0.45f * edge * clamp(game.flashes.x, 0.0f, 1.0f));
        drawWorldLabels(colour, p, game);
        if (game.mode.x == screenPlaying) {
            drawHud(colour, p, game, atlas, resolution, time);
        } else {
            drawEndScreen(colour, p, game, time);
        }
    }
    drawCursor(colour, p, cursor);
    return float4(clamp(linearToSrgb(colour), float3(0.0f), float3(1.0f)), 1.0f);
}

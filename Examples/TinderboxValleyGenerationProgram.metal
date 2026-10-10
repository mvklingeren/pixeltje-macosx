#include <metal_stdlib>
using namespace metal;

// Tinderbox Valley: an aerial firefighting game for the generic GPU Program node.
//
// The valley is a 480 x 300 cell grid seen straight from above. A wildfire
// cellular automaton runs in parallel on the GPU, one thread per cell, every
// tick: burning cells heat their 5 x 5 neighbourhood with wind- and slope-
// dependent weights, strong fires throw embers downwind, wet cells resist
// ignition, and smoke is advected with the wind. The player flies a water
// bomber that follows the Trackpad, skims lakes to fill its tank and drops
// water with Action (Space). Save enough villages until the rain arrives.
//
// Tick passes: advanceValley (1 thread: rules, plane, wind, lightning, stats),
// buildTerrain (480 x 300: regenerates a mission map when requested),
// spreadFire (480 x 300: cellsA -> cellsB), commitCells (480 x 300: copies
// cellsB back into cellsA and blurs the fire light into terrain.w) and
// tallyRows (300 threads: per-row statistics that advanceValley sums on the
// next tick). The program needs no swap pair, so the engine can encode the
// single clear-and-replace present pass together with the tick.
//
// Time: the live preview supplies the wall time between ticks in pointer.w;
// saved and replayed frames use the fixed program step, so they stay
// reproducible. The fire rates are per second, so play speed does not depend
// on the frame rate.

constant int gridW = 480;
constant int gridH = 300;
constant int gridCells = gridW * gridH;
constant int statsPerRow = 4;
constant int villageSlots = 4;
constant int trailSlots = 16;

constant uint phaseTitle = 0u;
constant uint phaseBriefing = 1u;
constant uint phasePlay = 2u;
constant uint phaseWon = 3u;
constant uint phaseLost = 4u;
constant uint phaseVictory = 5u;

// Terrain type codes stored in terrain.y; houses are 4 + village index.
constant float typeGrass = 0.0f;
constant float typeForest = 1.0f;
constant float typeRock = 2.0f;
constant float typeWater = 3.0f;
constant float typeHouse = 4.0f;

constant float elevationScale = 36.0f; // elevation units (cells) per 1.0 of terrain.x

struct ProgramUniforms {
    float4 resolutionTime; // width, height, time, fixed step
    uint4 frameSeed;       // frame, seed low, seed high, reserved
    float4 parameters0;    // fireSpread, rainSeconds, firstMission, planeSpeed
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;        // normalized Trackpad X/Y, action count, live frame interval
};

// Seconds simulated by this tick (see the note on time above).
float tickSeconds(constant ProgramUniforms &u) {
    return min(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w, 0.1f);
}

// Size: 18 float4/uint4 members (288 bytes) + float[24] (96 bytes)
// + 4 + 4 + 16 float4 arrays (384 bytes) + 1200 float4 row statistics
// (19,200 bytes) = 19,968 bytes. Every member is 16-byte aligned and the
// float[24] block is a multiple of 16 bytes, so there is no padding. The
// program declares the buffer with 24,576 bytes.
struct GameState {
    uint4 flow;          // phase, mission (0-based), regenerate flag, frames in phase
    uint4 counters;      // drops made, lightning strikes, random state, villages lost mask
    float4 clock;        // rain countdown, phase time, last action count, play time
    float4 plane;        // x, y, heading (radians), speed (cells per second)
    float4 planeAux;     // tank 0..1, altitude 0..1, drop seconds left, over water
    float4 dropSegment;  // water released this tick: from xy to zw
    float4 dropInfo;     // radius, wetness per second at the centre, active, splash timer
    float4 wind;         // unit direction xy (blowing towards), strength, angle
    float4 strike;       // lightning ignition this tick: xy, radius, active
    float4 strikeMark;   // last strike xy, age seconds, flash seconds
    float4 score;        // total, total at mission start, mission score, best mission
    float4 stats;        // burning cells, burnt cells, fuel cells, wet cells
    float4 villageInfo;  // villages, required, lost, threatened count
    float4 message;      // message text id (or -1), seconds left, value, priority
    float4 result;       // villages saved, wildland percent, containment bonus, mission score
    float4 settings;     // fire spread, rain seconds, first mission (0-based), plane speed
    float4 lightning;    // seconds to next strike, interval, unused, unused
    float4 misc;         // last splash x, y, animation clock (seconds), contained flag
    float spreadWeights[24]; // wind/slope-free heat weights for the 5 x 5 neighbourhood
    float4 villages[villageSlots];      // centre xy, lost (0/1), threat 0..1
    float4 villageDamage[villageSlots]; // damaged houses, houses, damage fraction, nearest fire
    float4 trail[trailSlots];           // water mist: xy, age seconds, strength
    float4 rowStats[gridH * statsPerRow];
};

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

// ---------------------------------------------------------------------------
// Hashing and noise

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

float fbm(float2 p, uint seed) {
    float total = 0.0f;
    float amplitude = 0.5f;
    for (int octave = 0; octave < 4; ++octave) {
        total += amplitude * valueNoise(p, seed + uint(octave) * 101u);
        p = p * 2.03f + float2(17.3f, 9.1f);
        amplitude *= 0.5f;
    }
    return total / 0.9375f;
}

uint nextRandom(thread uint &state) {
    state = state * 1664525u + 1013904223u;
    return hashUint(state);
}

float random01(thread uint &state) {
    return float(nextRandom(state) >> 8) * (1.0f / 16777216.0f);
}

float segmentDistance(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float len2 = dot(ab, ab);
    float t = len2 > 0.0001f ? clamp(dot(p - a, ab) / len2, 0.0f, 1.0f) : 0.0f;
    return length(p - (a + ab * t));
}

int cellIndex(int2 c) {
    return c.y * gridW + c.x;
}

bool inGrid(int2 c) {
    return c.x >= 0 && c.y >= 0 && c.x < gridW && c.y < gridH;
}

int houseVillage(float type) {
    if (type < typeHouse - 0.5f) return -1;
    return int(type - typeHouse + 0.5f);
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
constant uchar textPool[1011] = {
    84, 73, 78, 68, 69, 82, 66, 79, 88, 32, 86, 65, 76, 76, 69, 89,
    65, 69, 82, 73, 65, 76, 32, 70, 73, 82, 69, 70, 73, 71, 72, 84,
    73, 78, 71, 32, 73, 78, 32, 84, 72, 82, 69, 69, 32, 77, 73, 83,
    83, 73, 79, 78, 83, 68, 82, 65, 71, 32, 84, 72, 69, 32, 84, 82,
    65, 67, 75, 80, 65, 68, 32, 84, 79, 32, 83, 84, 69, 69, 82, 32,
    89, 79, 85, 82, 32, 87, 65, 84, 69, 82, 32, 66, 79, 77, 66, 69,
    82, 83, 75, 73, 77, 32, 76, 79, 87, 32, 79, 86, 69, 82, 32, 65,
    32, 76, 65, 75, 69, 32, 84, 79, 32, 70, 73, 76, 76, 32, 84, 72,
    69, 32, 84, 65, 78, 75, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67,
    69, 32, 84, 79, 32, 68, 82, 79, 80, 32, 87, 65, 84, 69, 82, 32,
    79, 78, 32, 84, 72, 69, 32, 70, 76, 65, 77, 69, 83, 87, 69, 84,
    32, 71, 82, 79, 85, 78, 68, 32, 72, 79, 76, 68, 83, 32, 84, 72,
    69, 32, 70, 73, 82, 69, 32, 66, 65, 67, 75, 32, 70, 79, 82, 32,
    65, 32, 87, 72, 73, 76, 69, 87, 73, 78, 68, 32, 68, 82, 73, 86,
    69, 83, 32, 84, 72, 69, 32, 70, 73, 82, 69, 32, 65, 78, 68, 32,
    67, 65, 82, 82, 73, 69, 83, 32, 69, 77, 66, 69, 82, 83, 83, 65,
    86, 69, 32, 84, 72, 69, 32, 86, 73, 76, 76, 65, 71, 69, 83, 32,
    85, 78, 84, 73, 76, 32, 84, 72, 69, 32, 82, 65, 73, 78, 32, 65,
    82, 82, 73, 86, 69, 83, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67,
    69, 32, 84, 79, 32, 84, 65, 75, 69, 32, 79, 70, 70, 77, 73, 83,
    83, 73, 79, 78, 80, 73, 78, 69, 32, 72, 79, 76, 76, 79, 87, 68,
    82, 89, 32, 76, 73, 71, 72, 84, 78, 73, 78, 71, 82, 69, 68, 32,
    70, 76, 65, 71, 32, 87, 65, 82, 78, 73, 78, 71, 65, 32, 67, 65,
    77, 80, 70, 73, 82, 69, 32, 69, 83, 67, 65, 80, 69, 68, 32, 78,
    69, 65, 82, 32, 84, 72, 69, 32, 79, 76, 68, 32, 77, 73, 76, 76,
    65, 32, 83, 84, 79, 82, 77, 32, 73, 83, 32, 70, 73, 82, 73, 78,
    71, 32, 76, 73, 71, 72, 84, 78, 73, 78, 71, 32, 73, 78, 84, 79,
    32, 68, 82, 89, 32, 84, 73, 77, 66, 69, 82, 71, 65, 76, 69, 32,
    70, 79, 82, 67, 69, 32, 87, 73, 78, 68, 83, 32, 45, 32, 84, 72,
    69, 32, 87, 73, 78, 68, 32, 87, 73, 76, 76, 32, 83, 72, 73, 70,
    84, 83, 65, 86, 69, 79, 70, 86, 73, 76, 76, 65, 71, 69, 83, 87,
    73, 78, 68, 75, 77, 47, 72, 82, 65, 73, 78, 32, 73, 78, 87, 65,
    84, 69, 82, 83, 67, 79, 82, 69, 83, 67, 79, 79, 80, 73, 78, 71,
    84, 65, 78, 75, 32, 70, 85, 76, 76, 84, 65, 78, 75, 32, 69, 77,
    80, 84, 89, 32, 45, 32, 83, 75, 73, 77, 32, 65, 32, 76, 65, 75,
    69, 76, 73, 71, 72, 84, 78, 73, 78, 71, 32, 83, 84, 82, 73, 75,
    69, 33, 65, 32, 86, 73, 76, 76, 65, 71, 69, 32, 72, 65, 83, 32,
    66, 85, 82, 78, 69, 68, 33, 86, 73, 76, 76, 65, 71, 69, 32, 73,
    78, 32, 68, 65, 78, 71, 69, 82, 33, 83, 80, 76, 65, 83, 72, 33,
    70, 73, 82, 69, 32, 67, 79, 78, 84, 65, 73, 78, 69, 68, 33, 72,
    69, 82, 69, 32, 67, 79, 77, 69, 83, 32, 84, 72, 69, 32, 82, 65,
    73, 78, 77, 73, 83, 83, 73, 79, 78, 32, 67, 79, 77, 80, 76, 69,
    84, 69, 86, 73, 76, 76, 65, 71, 69, 83, 32, 83, 65, 86, 69, 68,
    87, 73, 76, 68, 76, 65, 78, 68, 32, 83, 65, 86, 69, 68, 67, 79,
    78, 84, 65, 73, 78, 77, 69, 78, 84, 32, 66, 79, 78, 85, 83, 77,
    73, 83, 83, 73, 79, 78, 32, 83, 67, 79, 82, 69, 80, 82, 69, 83,
    83, 32, 83, 80, 65, 67, 69, 32, 70, 79, 82, 32, 84, 72, 69, 32,
    78, 69, 88, 84, 32, 77, 73, 83, 83, 73, 79, 78, 77, 73, 83, 83,
    73, 79, 78, 32, 70, 65, 73, 76, 69, 68, 84, 79, 79, 32, 77, 65,
    78, 89, 32, 86, 73, 76, 76, 65, 71, 69, 83, 32, 66, 85, 82, 78,
    69, 68, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 84, 79,
    32, 82, 69, 84, 82, 89, 32, 84, 72, 69, 32, 77, 73, 83, 83, 73,
    79, 78, 84, 72, 69, 32, 86, 65, 76, 76, 69, 89, 32, 73, 83, 32,
    83, 65, 70, 69, 33, 70, 73, 78, 65, 76, 32, 83, 67, 79, 82, 69,
    82, 65, 78, 75, 82, 79, 79, 75, 73, 69, 32, 80, 73, 76, 79, 84,
    65, 73, 82, 32, 84, 65, 78, 75, 69, 82, 32, 80, 73, 76, 79, 84,
    65, 73, 82, 32, 65, 84, 84, 65, 67, 75, 32, 76, 69, 65, 68, 70,
    73, 82, 69, 32, 66, 79, 83, 83, 80, 82, 69, 83, 83, 32, 83, 80,
    65, 67, 69, 32, 84, 79, 32, 70, 76, 89, 32, 65, 71, 65, 73, 78,
    80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 83,
    84, 65, 82, 84, 32, 84, 72, 69, 32, 77, 73, 83, 83, 73, 79, 78,
    37, 71, 79, 33, 32, 71, 79, 33, 32, 71, 79, 33, 80, 82, 69, 83,
    83, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 67, 79, 78, 84, 73,
    78, 85, 69,
};
constant int textRanges[108] = {
    0, 16,  // TINDERBOX VALLEY
    16, 37,  // AERIAL FIREFIGHTING IN THREE MISSIONS
    53, 44,  // DRAG THE TRACKPAD TO STEER YOUR WATER BOMBER
    97, 37,  // SKIM LOW OVER A LAKE TO FILL THE TANK
    134, 39,  // PRESS SPACE TO DROP WATER ON THE FLAMES
    173, 42,  // WET GROUND HOLDS THE FIRE BACK FOR A WHILE
    215, 39,  // WIND DRIVES THE FIRE AND CARRIES EMBERS
    254, 40,  // SAVE THE VILLAGES UNTIL THE RAIN ARRIVES
    294, 23,  // PRESS SPACE TO TAKE OFF
    317, 7,  // MISSION
    324, 11,  // PINE HOLLOW
    335, 13,  // DRY LIGHTNING
    348, 16,  // RED FLAG WARNING
    364, 36,  // A CAMPFIRE ESCAPED NEAR THE OLD MILL
    400, 43,  // A STORM IS FIRING LIGHTNING INTO DRY TIMBER
    443, 38,  // GALE FORCE WINDS - THE WIND WILL SHIFT
    481, 4,  // SAVE
    485, 2,  // OF
    487, 8,  // VILLAGES
    495, 4,  // WIND
    499, 4,  // KM/H
    503, 7,  // RAIN IN
    510, 5,  // WATER
    515, 5,  // SCORE
    520, 8,  // SCOOPING
    528, 9,  // TANK FULL
    537, 24,  // TANK EMPTY - SKIM A LAKE
    561, 17,  // LIGHTNING STRIKE!
    578, 21,  // A VILLAGE HAS BURNED!
    599, 18,  // VILLAGE IN DANGER!
    617, 7,  // SPLASH!
    624, 15,  // FIRE CONTAINED!
    639, 19,  // HERE COMES THE RAIN
    658, 16,  // MISSION COMPLETE
    674, 14,  // VILLAGES SAVED
    688, 14,  // WILDLAND SAVED
    702, 17,  // CONTAINMENT BONUS
    719, 13,  // MISSION SCORE
    732, 32,  // PRESS SPACE FOR THE NEXT MISSION
    764, 14,  // MISSION FAILED
    778, 24,  // TOO MANY VILLAGES BURNED
    802, 32,  // PRESS SPACE TO RETRY THE MISSION
    834, 19,  // THE VALLEY IS SAFE!
    853, 11,  // FINAL SCORE
    864, 4,  // RANK
    868, 12,  // ROOKIE PILOT
    880, 16,  // AIR TANKER PILOT
    896, 15,  // AIR ATTACK LEAD
    911, 9,  // FIRE BOSS
    920, 24,  // PRESS SPACE TO FLY AGAIN
    944, 32,  // PRESS SPACE TO START THE MISSION
    976, 1,  // %
    977, 11,  // GO! GO! GO!
    988, 23,  // PRESS SPACE TO CONTINUE
};
constant int textTitle = 0;
constant int textSubtitle = 1;
constant int textHow1 = 2;
constant int textHow2 = 3;
constant int textHow3 = 4;
constant int textHow4 = 5;
constant int textHow5 = 6;
constant int textHow6 = 7;
constant int textPressStart = 8;
constant int textMission = 9;
constant int textMission1 = 10;
constant int textMission2 = 11;
constant int textMission3 = 12;
constant int textBrief1 = 13;
constant int textBrief2 = 14;
constant int textBrief3 = 15;
constant int textSave = 16;
constant int textOf = 17;
constant int textVillages = 18;
constant int textWind = 19;
constant int textKmh = 20;
constant int textRainIn = 21;
constant int textWater = 22;
constant int textScore = 23;
constant int textScooping = 24;
constant int textTankFull = 25;
constant int textTankEmpty = 26;
constant int textLightning = 27;
constant int textVillageLost = 28;
constant int textDanger = 29;
constant int textSplash = 30;
constant int textContained = 31;
constant int textRain = 32;
constant int textComplete = 33;
constant int textVillagesSaved = 34;
constant int textWildland = 35;
constant int textBonus = 36;
constant int textMissionScore = 37;
constant int textNext = 38;
constant int textFailed = 39;
constant int textTooMany = 40;
constant int textRetry = 41;
constant int textVictory = 42;
constant int textFinalScore = 43;
constant int textRank = 44;
constant int textRank1 = 45;
constant int textRank2 = 46;
constant int textRank3 = 47;
constant int textRank4 = 48;
constant int textAgain = 49;
constant int textTakeOff = 50;
constant int textPercent = 51;
constant int textGo = 52;
constant int textContinue = 53;


// ---------------------------------------------------------------------------
// Missions. Coordinates are cells: x 0..480 to the right, y 0..300 downwards.
// Wind angles name the direction the wind blows towards (0 = east, +y = south).

struct MissionInfo {
    float windAngle;
    float windStrength;   // 0 calm .. 1.2 gale
    float windDrift;      // radians per second the wind turns during play
    float gust;           // relative gust amplitude
    float lightningEvery; // seconds between dry-lightning strikes, 0 = none
    int villages;
    int required;
    int lakes;
    int ignitions;
    uint terrainSeed;
};

MissionInfo missionInfo(uint mission) {
    MissionInfo info;
    if (mission == 0u) {
        info.windAngle = 0.30f; info.windStrength = 0.50f; info.windDrift = 0.0f;
        info.gust = 0.10f; info.lightningEvery = 0.0f;
        info.villages = 3; info.required = 2; info.lakes = 1; info.ignitions = 1;
        info.terrainSeed = 11u;
    } else if (mission == 1u) {
        info.windAngle = 0.85f; info.windStrength = 0.55f; info.windDrift = 0.0f;
        info.gust = 0.20f; info.lightningEvery = 30.0f;
        info.villages = 3; info.required = 2; info.lakes = 2; info.ignitions = 2;
        info.terrainSeed = 23u;
    } else {
        info.windAngle = -0.25f; info.windStrength = 0.74f; info.windDrift = 0.0050f;
        info.gust = 0.25f; info.lightningEvery = 24.0f;
        info.villages = 4; info.required = 3; info.lakes = 2; info.ignitions = 2;
        info.terrainSeed = 37u;
    }
    return info;
}

int missionNameText(uint mission) {
    if (mission == 0u) return textMission1;
    if (mission == 1u) return textMission2;
    return textMission3;
}

int missionBriefText(uint mission) {
    if (mission == 0u) return textBrief1;
    if (mission == 1u) return textBrief2;
    return textBrief3;
}

float2 villageCentre(uint mission, int village) {
    if (mission == 0u) {
        if (village == 0) return float2(275.0f, 82.0f);
        if (village == 1) return float2(288.0f, 152.0f);
        return float2(420.0f, 240.0f);
    }
    if (mission == 1u) {
        if (village == 0) return float2(340.0f, 262.0f);
        if (village == 1) return float2(440.0f, 118.0f);
        return float2(215.0f, 230.0f);
    }
    if (village == 0) return float2(335.0f, 58.0f);
    if (village == 1) return float2(440.0f, 150.0f);
    if (village == 2) return float2(330.0f, 238.0f);
    return float2(165.0f, 40.0f);
}

// Lake centre xy and radii zw.
float4 lakeShape(uint mission, int lake) {
    if (mission == 0u) return float4(100.0f, 190.0f, 60.0f, 36.0f);
    if (mission == 1u) {
        if (lake == 0) return float4(380.0f, 70.0f, 54.0f, 30.0f);
        return float4(105.0f, 232.0f, 48.0f, 32.0f);
    }
    if (lake == 0) return float4(235.0f, 150.0f, 50.0f, 30.0f);
    return float4(425.0f, 262.0f, 42.0f, 24.0f);
}

float2 ignitionPoint(uint mission, int index) {
    if (mission == 0u) return float2(150.0f, 78.0f);
    if (mission == 1u) {
        if (index == 0) return float2(85.0f, 62.0f);
        return float2(262.0f, 108.0f);
    }
    if (index == 0) return float2(48.0f, 112.0f);
    return float2(105.0f, 258.0f);
}

// House k of a village: centre xy and half extents zw, in cells.
float4 houseRect(int village, int house) {
    float2 offset;
    if (house == 0) offset = float2(-6.0f, -5.0f);
    else if (house == 1) offset = float2(1.0f, -7.0f);
    else if (house == 2) offset = float2(7.0f, -3.0f);
    else if (house == 3) offset = float2(6.0f, 5.0f);
    else if (house == 4) offset = float2(-1.0f, 7.0f);
    else if (house == 5) offset = float2(-7.0f, 3.0f);
    else offset = float2(0.0f, 0.0f);
    bool wide = ((house + village) & 1) == 0;
    float2 halfSize = wide ? float2(2.0f, 1.5f) : float2(1.5f, 2.0f);
    if (house == 6) halfSize = float2(2.0f, 2.0f);
    return float4(offset, halfSize);
}

constant int housesPerVillage = 7;

// Terrain cell: elevation 0..1, type code, fuel capacity, glow (written later).
float4 generateTerrainCell(uint mission, int2 cell, uint seed) {
    MissionInfo info = missionInfo(mission);
    float2 p = float2(cell) + 0.5f;
    uint s = info.terrainSeed * 7919u + seed * 104729u;
    float elevation = 0.78f * fbm(p * 0.0105f + float2(3.1f, 7.7f), s)
        + 0.22f * valueNoise(p * 0.0042f + float2(1.7f, 0.3f), s + 9u);
    bool water = false;
    for (int lake = 0; lake < 2; ++lake) {
        if (lake >= info.lakes) break;
        float4 shape = lakeShape(mission, lake);
        float2 q = (p - shape.xy) / shape.zw;
        float d = length(q) + 0.24f * (valueNoise(p * 0.07f, s + 31u) - 0.5f)
            + 0.10f * (valueNoise(p * 0.19f, s + 33u) - 0.5f);
        if (d < 1.0f) water = true;
        elevation = min(elevation, mix(0.02f, elevation, smoothstep(0.75f, 2.0f, d)));
    }
    float ridgeNoise = valueNoise(p * 0.016f + float2(5.0f, 2.0f), s + 57u);
    float ridge = 1.0f - abs(ridgeNoise * 2.0f - 1.0f);
    float outcrop = valueNoise(p * 0.045f + float2(2.0f, 9.0f), s + 61u);
    bool rock = !water && ((ridge > 0.88f && outcrop > 0.58f && elevation > 0.36f)
        || elevation > 0.78f);
    if (rock) elevation += 0.05f * ridge;
    float vegetation = fbm(p * 0.024f + float2(13.0f, 4.0f), s + 77u);
    float type = typeGrass;
    if (vegetation > 0.47f) type = typeForest;
    float fuel = type == typeForest ? 1.0f : 0.45f + 0.15f * smoothstep(0.30f, 0.47f, vegetation);
    for (int index = 0; index < 3; ++index) {
        if (index < info.ignitions && distance(p, ignitionPoint(mission, index)) < 7.0f) rock = false;
    }
    if (rock) { type = typeRock; fuel = 0.0f; }
    if (water) { type = typeWater; fuel = 0.0f; }
    for (int village = 0; village < villageSlots; ++village) {
        if (village >= info.villages) break;
        float2 centre = villageCentre(mission, village);
        float2 local = p - centre;
        float clearing = length(local) + 2.5f * (valueNoise(p * 0.15f, s + 91u) - 0.5f);
        if (clearing < 15.0f && !water) {
            type = typeGrass;
            fuel = 0.35f;
        }
        if (abs(local.x) < 10.0f && abs(local.y) < 10.0f) {
            for (int house = 0; house < housesPerVillage; ++house) {
                float4 rect = houseRect(village, house);
                float2 d = abs(local - rect.xy);
                if (d.x < rect.z && d.y < rect.w) {
                    type = typeHouse + float(village);
                    fuel = 0.8f;
                }
            }
        }
    }
    return float4(clamp(elevation, 0.0f, 1.0f), type, fuel, 0.0f);
}

// Initial cell state: fuel, fire, wetness, smoke.
float4 initialCell(uint mission, int2 cell, float4 ground) {
    MissionInfo info = missionInfo(mission);
    float2 p = float2(cell) + 0.5f;
    float fire = 0.0f;
    float fuel = ground.z;
    for (int index = 0; index < 3; ++index) {
        if (index >= info.ignitions) break;
        // An established fire: a burnt core inside a burning ring.
        float d = distance(p, ignitionPoint(mission, index))
            + 2.0f * (valueNoise(p * 0.3f, uint(index) + 5u) - 0.5f);
        if (d < 9.0f && ground.z > 0.0f) {
            fire = max(fire, 0.35f + 0.6f * smoothstep(3.0f, 8.0f, d));
            fuel = min(fuel, ground.z * mix(0.15f, 1.0f, smoothstep(2.0f, 8.5f, d)));
        }
    }
    float wet = ground.y == typeWater ? 1.0f : 0.0f;
    return float4(fuel, fire, wet, 0.0f);
}


// ---------------------------------------------------------------------------
// Fire behaviour per fuel type

float typeIgnition(float type) {
    if (type == typeGrass) return 0.15f;
    if (type == typeForest) return 0.075f;
    if (type >= typeHouse - 0.5f) return 0.07f;
    return 0.0f;
}

float typeBurnRate(float type) {
    if (type == typeGrass) return 0.32f;
    if (type == typeForest) return 0.075f;
    return 0.075f;
}

float typePeak(float type) {
    return type == typeGrass ? 0.70f : 1.0f;
}

// Bilinear smoke (w) with cell centres at integer coordinates.
float sampleSmoke(device const float4 *cells, float2 q) {
    q = clamp(q, float2(0.0f), float2(float(gridW - 1), float(gridH - 1)));
    int2 i = min(int2(floor(q)), int2(gridW - 2, gridH - 2));
    float2 f = q - float2(i);
    float a = cells[cellIndex(i)].w;
    float b = cells[cellIndex(i + int2(1, 0))].w;
    float c = cells[cellIndex(i + int2(0, 1))].w;
    float d = cells[cellIndex(i + int2(1, 1))].w;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Regenerates the terrain and the initial fire when a mission (re)starts.
kernel void buildTerrain(constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    device float4 *terrain [[buffer(2)]],
    device float4 *cells [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(gridW) || gid.y >= uint(gridH)) return;
    device const GameState &game = states[0];
    if (game.flow.z == 0u) return;
    int2 cell = int2(gid);
    int index = cellIndex(cell);
    float4 ground = generateTerrainCell(game.flow.y, cell, u.frameSeed.y);
    terrain[index] = ground;
    cells[index] = initialCell(game.flow.y, cell, ground);
}

// One wildfire step, cellsIn -> cellsOut, one thread per cell.
kernel void spreadFire(constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    device const float4 *terrain [[buffer(2)]],
    device const float4 *cellsIn [[buffer(3)]],
    device float4 *cellsOut [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(gridW) || gid.y >= uint(gridH)) return;
    device const GameState &game = states[0];
    int2 cell = int2(gid);
    int index = cellIndex(cell);
    float4 state = cellsIn[index];
    uint phase = game.flow.x;
    bool live = phase == phasePlay || phase == phaseWon || phase == phaseLost;
    if (!live || game.flow.z != 0u) {
        cellsOut[index] = state;
        return;
    }
    float4 ground = terrain[index];
    float dt = tickSeconds(u);
    float fuel = state.x;
    float fire = state.y;
    float wet = state.z;
    float fuelMax = ground.z;
    float type = ground.y;
    float2 p = float2(cell) + 0.5f;
    float strength = game.wind.z;

    // Water released by the plane during this tick.
    if (game.dropInfo.z > 0.5f) {
        float d = segmentDistance(p, game.dropSegment.xy, game.dropSegment.zw);
        float radius = game.dropInfo.x;
        if (d < radius) {
            float added = game.dropInfo.y * dt * (1.0f - (d * d) / (radius * radius));
            wet += added;
            fire = max(0.0f, fire - added * 2.4f);
        }
    }
    // Dry lightning ignites the fuel around a strike.
    if (game.strike.w > 0.5f && fuel > 0.1f && wet < 0.4f
        && distance(p, game.strike.xy) < game.strike.z) {
        fire = max(fire, 0.8f);
    }
    // The rain front at the end of a mission.
    if (phase == phaseWon) {
        wet += 0.7f * dt;
        fire = max(0.0f, fire - 0.9f * dt);
    }

    // Radiant and convective heat from the 5 x 5 neighbourhood.
    float heat = 0.0f;
    float warmth = 0.0f;
    int weightIndex = 0;
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            if (dx == 0 && dy == 0) continue;
            int2 n = cell + int2(dx, dy);
            int k = weightIndex;
            weightIndex += 1;
            if (!inGrid(n)) continue;
            int neighbour = cellIndex(n);
            float neighbourFire = cellsIn[neighbour].y;
            if (neighbourFire <= 0.0f) continue;
            float span = length(float2(float(dx), float(dy)));
            float rise = (ground.x - terrain[neighbour].x) * elevationScale / span;
            float slope = clamp(1.0f + 0.7f * rise, 0.45f, 2.2f);
            heat += neighbourFire * game.spreadWeights[k] * slope;
            warmth += neighbourFire / (span * span);
        }
    }
    // Embers thrown downwind by strong fires.
    if (strength > 0.25f) {
        for (int ember = 0; ember < 2; ++ember) {
            float reach = (ember == 0 ? 5.0f : 9.0f) * (0.6f + 0.6f * strength);
            int2 source = int2(floor(p - game.wind.xy * reach));
            if (inGrid(source)) {
                float sourceFire = cellsIn[cellIndex(source)].y;
                if (sourceFire > 0.55f) heat += sourceFire * 0.05f * strength * strength;
            }
        }
    }

    if (fire <= 0.0f) {
        if (fuelMax > 0.0f && fuel > 0.08f * fuelMax && heat > 0.0f) {
            float dryness = clamp(1.0f - wet * 1.6f, 0.0f, 1.0f);
            dryness *= dryness;
            float chance = 1.0f - exp(-typeIgnition(type) * game.settings.x
                * heat * dryness * dt);
            uint h = uint(index) * 747796405u + u.frameSeed.x * 2891336453u
                + u.frameSeed.y * 1442695041u;
            if (hash01(h) < chance) fire = 0.22f;
        }
    } else {
        float peak = typePeak(type) * smoothstep(0.0f, 0.25f, fuel / max(fuelMax, 0.01f));
        fire += (peak - fire) * 1.5f * dt;
        fuel = max(0.0f, fuel - typeBurnRate(type) * fire * dt);
        if (wet > 0.0f) {
            fire -= 1.6f * wet * dt;
            wet = max(0.0f, wet - 0.5f * max(fire, 0.0f) * dt);
        }
        if (fire < 0.03f) fire = 0.0f;
    }
    if (type != typeWater) wet = max(0.0f, wet - (0.016f + 0.03f * warmth) * dt);
    wet = min(wet, 2.0f);

    // Smoke drifts with the wind (semi-Lagrangian) and fades.
    float2 drift = game.wind.xy * (2.0f + 9.0f * strength) * dt;
    float smoke = sampleSmoke(cellsIn, p - 0.5f - drift) * (1.0f - 0.32f * dt)
        + fire * 0.55f * dt;
    if (phase == phaseWon) smoke *= 1.0f - 0.6f * dt;
    cellsOut[index] = float4(fuel, fire, wet, min(smoke, 4.0f));
}

// Copies the new cells back into cellsA for the next tick and the present
// pass (so the program needs no swap), and blurs the fire light into terrain.w.
kernel void commitCells(constant ProgramUniforms &u [[buffer(0)]],
    device float4 *terrain [[buffer(2)]],
    device const float4 *cellsNew [[buffer(3)]],
    device float4 *cellsCurrent [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(gridW) || gid.y >= uint(gridH)) return;
    int2 cell = int2(gid);
    int index = cellIndex(cell);
    cellsCurrent[index] = cellsNew[index];
    float total = 0.0f;
    for (int dy = -3; dy <= 3; ++dy) {
        for (int dx = -3; dx <= 3; ++dx) {
            int2 n = cell + int2(dx, dy);
            if (!inGrid(n)) continue;
            float fire = cellsNew[cellIndex(n)].y;
            if (fire <= 0.0f) continue;
            total += fire / (1.0f + 0.35f * float(dx * dx + dy * dy));
        }
    }
    terrain[index].w = total * 0.16f;
}

// Per-row statistics; advanceValley adds the rows on the next tick.
kernel void tallyRows(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device const float4 *terrain [[buffer(2)]],
    device const float4 *cells [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id >= uint(gridH)) return;
    device GameState &game = states[0];
    int row = int(id);
    float4 totals = float4(0.0f);   // burning, burnt, fuel cells, wet cells
    float4 damaged = float4(0.0f);  // damaged house cells per village
    float4 houses = float4(0.0f);   // house cells per village
    float4 nearest = float4(10000.0f); // nearest burning cell per village
    float2 v0 = game.villages[0].xy;
    float2 v1 = game.villages[1].xy;
    float2 v2 = game.villages[2].xy;
    float2 v3 = game.villages[3].xy;
    for (int x = 0; x < gridW; ++x) {
        int index = row * gridW + x;
        float4 state = cells[index];
        float4 ground = terrain[index];
        bool burning = state.y > 0.05f;
        if (burning) {
            totals.x += 1.0f;
            float2 p = float2(float(x) + 0.5f, float(row) + 0.5f);
            nearest = min(nearest, float4(distance(p, v0), distance(p, v1),
                distance(p, v2), distance(p, v3)));
        }
        if (ground.z > 0.0f) {
            totals.z += 1.0f;
            if (state.x < 0.5f * ground.z) totals.y += 1.0f;
        }
        if (state.z > 0.3f && ground.y != typeWater) totals.w += 1.0f;
        int village = houseVillage(ground.y);
        if (village >= 0) {
            float hurt = (burning || state.x < 0.6f * ground.z) ? 1.0f : 0.0f;
            float4 slot = float4(village == 0 ? 1.0f : 0.0f, village == 1 ? 1.0f : 0.0f,
                village == 2 ? 1.0f : 0.0f, village == 3 ? 1.0f : 0.0f);
            houses += slot;
            damaged += slot * hurt;
        }
    }
    int base = row * statsPerRow;
    game.rowStats[base] = totals;
    game.rowStats[base + 1] = damaged;
    game.rowStats[base + 2] = houses;
    game.rowStats[base + 3] = nearest;
}


// ---------------------------------------------------------------------------
// Game rules (one thread)

constant float cruiseSpeed = 56.0f;   // cells per second
constant float turnRate = 2.3f;       // radians per second
constant float dropSeconds = 0.55f;   // a full tank empties in 0.55 seconds
constant float dropRadius = 7.5f;     // half width of the water swath in cells
constant float dropRate = 7.0f;       // wetness per second at the swath centre

float4 readSettings(constant ProgramUniforms &u) {
    float4 p = u.parameters0;
    float spread = p.x > 0.0f ? clamp(p.x, 0.4f, 2.0f) : 1.0f;
    float rain = p.y > 0.0f ? clamp(p.y, 45.0f, 400.0f) : 150.0f;
    float first = p.z > 0.0f ? clamp(floor(p.z + 0.5f), 1.0f, 3.0f) - 1.0f : 0.0f;
    float speed = p.w > 0.0f ? clamp(p.w, 0.6f, 1.5f) : 1.0f;
    return float4(spread, rain, first, speed);
}

float wrapAngle(float a) {
    return a - 6.28318530718f * floor((a + 3.14159265359f) / 6.28318530718f);
}

void updateWind(device GameState &game, MissionInfo info) {
    float t = game.clock.w;
    float angle = info.windAngle + info.windDrift * t;
    float gust = 1.0f + info.gust * sin(t * 0.45f + 1.3f) * (0.6f + 0.4f * sin(t * 1.7f));
    float strength = info.windStrength * gust;
    float2 direction = float2(cos(angle), sin(angle));
    game.wind = float4(direction, strength, angle);
    int k = 0;
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            if (dx == 0 && dy == 0) continue;
            float2 offset = float2(float(dx), float(dy));
            float span = length(offset);
            // Heat from the neighbour at cell + offset travels along -offset.
            float align = dot(-offset / span, direction);
            float gain = (span > 1.5f ? 2.5f : 2.2f) * strength;
            game.spreadWeights[k] = exp(gain * align) / (span * span);
            k += 1;
        }
    }
}

void postMessage(device GameState &game, int text, float seconds, float priority) {
    if (game.message.y <= 0.0f || priority >= game.message.w) {
        game.message = float4(float(text), seconds, 0.0f, priority);
    }
}

void startMission(device GameState &game, uint mission, uint phase) {
    MissionInfo info = missionInfo(mission);
    game.flow = uint4(phase, mission, 1u, 0u);
    game.clock = float4(game.settings.y, 0.0f, game.clock.z, 0.0f);
    float4 lake = lakeShape(mission, 0);
    game.plane = float4(lake.x, lake.y - lake.w - 22.0f, 0.0f, cruiseSpeed);
    game.planeAux = float4(1.0f, 1.0f, 0.0f, 0.0f);
    game.dropSegment = float4(0.0f);
    game.dropInfo = float4(dropRadius, 0.0f, 0.0f, 0.0f);
    game.strike = float4(0.0f);
    game.strikeMark = float4(-100.0f, -100.0f, 99.0f, 0.0f);
    game.score.y = game.score.x;
    game.score.z = 0.0f;
    game.stats = float4(0.0f);
    game.villageInfo = float4(float(info.villages), float(info.required), 0.0f, 0.0f);
    game.message = float4(-1.0f, 0.0f, 0.0f, 0.0f);
    game.result = float4(0.0f);
    game.lightning = float4(info.lightningEvery * 0.55f, info.lightningEvery, 0.0f, 0.0f);
    game.misc = float4(0.0f, 0.0f, game.misc.z, 0.0f); // keeps the animation clock
    game.counters.x = 0u;
    game.counters.y = 0u;
    game.counters.w = 0u;
    for (int v = 0; v < villageSlots; ++v) {
        float2 centre = v < info.villages ? villageCentre(mission, v) : float2(-1000.0f);
        game.villages[v] = float4(centre, 0.0f, 0.0f);
        game.villageDamage[v] = float4(0.0f, 1.0f, 0.0f, 10000.0f);
    }
    for (int i = 0; i < trailSlots; ++i) game.trail[i] = float4(0.0f, 0.0f, 99.0f, 0.0f);
    updateWind(game, info);
}

kernel void initializeValley(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    game.settings = readSettings(u);
    game.score = float4(0.0f);
    // A stale action count from before the run is not a press.
    game.clock = float4(0.0f, 0.0f, u.pointer.z, 0.0f);
    game.counters = uint4(0u, 0u, hashUint(u.frameSeed.y + 4242u) | 1u, 0u);
    game.misc = float4(0.0f);
    startMission(game, uint(game.settings.z), phaseTitle);
}

float2 pointerToWorld(float2 pointer, float2 resolution) {
    float scale = min(resolution.x / float(gridW), resolution.y / float(gridH));
    float2 offset = 0.5f * (resolution - scale * float2(float(gridW), float(gridH)));
    return (pointer * resolution - offset) / scale;
}

kernel void advanceValley(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device const float4 *terrain [[buffer(2)]],
    device const float4 *cells [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = tickSeconds(u);
    // Events last exactly one tick.
    game.flow.z = 0u;
    game.strike.w = 0.0f;
    game.dropInfo.z = 0.0f;
    game.flow.w += 1u;
    game.clock.y += dt;
    game.message.y = max(0.0f, game.message.y - dt);
    game.strikeMark.z += dt;
    game.strikeMark.w = max(0.0f, game.strikeMark.w - dt);
    game.misc.z += dt;
    for (int i = 0; i < trailSlots; ++i) game.trail[i].z += dt;

    uint phase = game.flow.x;
    uint mission = game.flow.y;
    MissionInfo info = missionInfo(mission);

    // Statistics gathered by tallyRows during the previous tick.
    float4 totals = float4(0.0f);
    float4 damaged = float4(0.0f);
    float4 houses = float4(0.0f);
    float4 nearest = float4(10000.0f);
    for (int row = 0; row < gridH; ++row) {
        int base = row * statsPerRow;
        totals += game.rowStats[base];
        damaged += game.rowStats[base + 1];
        houses += game.rowStats[base + 2];
        nearest = min(nearest, game.rowStats[base + 3]);
    }
    game.stats = totals;

    bool pressed = u.pointer.z > game.clock.z;
    if (pressed) game.clock.z = u.pointer.z;
    bool accept = pressed && game.clock.y > 0.4f;

    if (phase == phaseTitle) {
        if (accept) {
            game.flow.x = phaseBriefing;
            game.clock.y = 0.0f;
        }
    } else if (phase == phaseBriefing) {
        if (accept) {
            game.flow.x = phasePlay;
            game.clock.y = 0.0f;
            postMessage(game, textGo, 2.0f, 1.0f);
        }
    } else if (phase == phaseWon) {
        if (accept && game.clock.y > 2.5f) {
            if (mission + 1u < 3u) {
                startMission(game, mission + 1u, phaseBriefing);
            } else {
                game.flow.x = phaseVictory;
                game.clock.y = 0.0f;
            }
        }
    } else if (phase == phaseLost) {
        if (accept && game.clock.y > 1.0f) {
            game.score.x = game.score.y;
            startMission(game, mission, phaseBriefing);
        }
    } else if (phase == phaseVictory) {
        if (accept && game.clock.y > 1.5f) {
            game.score = float4(0.0f);
            startMission(game, uint(game.settings.z), phaseTitle);
        }
    }
    if (game.flow.z != 0u) return; // a new map is generated this tick
    if (game.flow.x != phase) pressed = false; // that press changed the screen
    phase = game.flow.x;
    bool playing = phase == phasePlay;

    if (playing) {
        game.clock.x = max(0.0f, game.clock.x - dt);
        game.clock.w += dt;
        updateWind(game, info);
    }

    // The water bomber follows the Trackpad; outside play it circles the lake.
    float4 lake = lakeShape(mission, 0);
    float2 goal = playing ? clamp(pointerToWorld(u.pointer.xy, u.resolutionTime.xy),
        float2(4.0f), float2(float(gridW) - 4.0f, float(gridH) - 4.0f)) : lake.xy;
    float2 position = game.plane.xy;
    float heading = game.plane.z;
    float2 toGoal = goal - position;
    if (length(toGoal) > 5.0f) {
        float turn = wrapAngle(atan2(toGoal.y, toGoal.x) - heading);
        heading = wrapAngle(heading + clamp(turn, -turnRate * dt, turnRate * dt));
    }
    int2 planeCell = int2(floor(position));
    bool overWater = inGrid(planeCell)
        && abs(terrain[cellIndex(planeCell)].y - typeWater) < 0.5f;
    float tank = game.planeAux.x;
    float altitude = game.planeAux.y;
    float dropLeft = game.planeAux.z;
    bool scooping = playing && overWater && tank < 0.999f && dropLeft <= 0.0f;
    float speed = cruiseSpeed * game.settings.w * (scooping ? 0.8f : 1.0f);
    float2 previous = position;
    position += float2(cos(heading), sin(heading)) * speed * dt;
    position = clamp(position, float2(-25.0f), float2(float(gridW) + 25.0f, float(gridH) + 25.0f));
    altitude += ((scooping ? 0.12f : 1.0f) - altitude) * min(1.0f, 3.0f * dt);
    if (scooping && altitude < 0.4f) {
        float before = tank;
        tank = min(1.0f, tank + 1.0f * dt);
        if (before < 1.0f && tank >= 1.0f) postMessage(game, textTankFull, 1.2f, 0.5f);
    }

    if (playing && pressed) {
        if (dropLeft > 0.0f) {
            // Already dropping; the press is spent.
        } else if (tank > 0.05f) {
            dropLeft = tank * dropSeconds;
            game.counters.x += 1u;
        } else {
            postMessage(game, textTankEmpty, 2.0f, 2.0f);
        }
    }
    if (dropLeft > 0.0f) {
        float release = min(dropLeft, dt);
        dropLeft = max(0.0f, dropLeft - dt);
        tank = max(0.0f, tank - release / dropSeconds);
        game.dropSegment = float4(previous, position);
        game.dropInfo = float4(dropRadius, dropRate * release / max(dt, 0.0001f), 1.0f, 0.0f);
        int slot = int(game.flow.w % uint(trailSlots));
        game.trail[slot] = float4(position, 0.0f, release / max(dt, 0.0001f));
        game.misc = float4(position, game.misc.z, game.misc.w);
        if (inGrid(planeCell) && cells[cellIndex(planeCell)].y > 0.05f) {
            postMessage(game, textSplash, 1.0f, 0.6f);
        }
    }
    game.plane = float4(position, heading, speed);
    game.planeAux = float4(tank, altitude, dropLeft, scooping ? 1.0f : 0.0f);

    if (!playing) return;

    // Dry lightning.
    if (info.lightningEvery > 0.0f) {
        game.lightning.x -= dt;
        if (game.lightning.x <= 0.0f) {
            uint rng = game.counters.z;
            bool found = false;
            float2 spot = float2(0.0f);
            for (int attempt = 0; attempt < 24; ++attempt) {
                float2 c = float2(20.0f + random01(rng) * float(gridW - 40),
                    20.0f + random01(rng) * float(gridH - 40));
                int ci = cellIndex(int2(c));
                bool clear = terrain[ci].z > 0.9f && cells[ci].x > 0.6f
                    && cells[ci].y <= 0.0f && cells[ci].z < 0.2f
                    && distance(c, position) > 30.0f;
                for (int v = 0; v < villageSlots; ++v) {
                    if (v < info.villages && distance(c, game.villages[v].xy) < 70.0f) clear = false;
                }
                if (clear && !found) {
                    spot = c;
                    found = true;
                }
            }
            if (found) {
                game.strike = float4(spot, 2.6f, 1.0f);
                game.strikeMark = float4(spot, 0.0f, 0.45f);
                game.counters.y += 1u;
                postMessage(game, textLightning, 2.5f, 3.0f);
            }
            game.lightning.x = info.lightningEvery * (0.75f + 0.5f * random01(rng));
            game.counters.z = rng;
        }
    }

    // Villages burn when 40% of their house cells are on fire or charred.
    int lost = 0;
    int threatened = 0;
    for (int v = 0; v < villageSlots; ++v) {
        if (v >= info.villages) break;
        float hurt = v == 0 ? damaged.x : (v == 1 ? damaged.y : (v == 2 ? damaged.z : damaged.w));
        float total = v == 0 ? houses.x : (v == 1 ? houses.y : (v == 2 ? houses.z : houses.w));
        float closest = v == 0 ? nearest.x : (v == 1 ? nearest.y : (v == 2 ? nearest.z : nearest.w));
        float fraction = total > 0.0f ? hurt / total : 0.0f;
        game.villageDamage[v] = float4(hurt, total, fraction, closest);
        if (game.villages[v].z < 0.5f && fraction >= 0.4f) {
            game.villages[v].z = 1.0f;
            game.counters.w |= 1u << uint(v);
            postMessage(game, textVillageLost, 3.0f, 4.0f);
        }
        float threat = game.villages[v].z > 0.5f ? 0.0f : clamp((60.0f - closest) / 45.0f, 0.0f, 1.0f);
        if (threat > 0.5f && game.villages[v].w <= 0.5f) postMessage(game, textDanger, 2.5f, 2.5f);
        game.villages[v].w = threat;
        if (game.villages[v].z > 0.5f) lost += 1;
        if (threat > 0.5f) threatened += 1;
    }
    game.villageInfo = float4(float(info.villages), float(info.required), float(lost), float(threatened));

    // Mission end.
    bool failed = lost > info.villages - info.required;
    bool contained = totals.x <= 0.0f && game.clock.w > 2.0f;
    if (failed) {
        game.flow.x = phaseLost;
        game.clock.y = 0.0f;
        game.flow.w = 0u;
    } else if (contained || game.clock.x <= 0.0f) {
        float saved = float(info.villages - lost);
        float wildland = totals.z > 0.0f ? floor(100.0f * (1.0f - totals.y / totals.z) + 0.5f) : 100.0f;
        float bonus = contained ? floor(game.clock.x) * 20.0f : 0.0f;
        float points = saved * 1000.0f + wildland * 20.0f + bonus;
        game.result = float4(saved, wildland, bonus, points);
        game.score.x += points;
        game.score.z = points;
        game.score.w = max(game.score.w, points);
        game.misc.w = contained ? 1.0f : 0.0f;
        for (int v = 0; v < villageSlots; ++v) game.villages[v].w = 0.0f;
        game.flow.x = phaseWon;
        game.clock.y = 0.0f;
        game.flow.w = 0u;
        int text = textRain;
        if (contained) text = textContained;
        postMessage(game, text, 2.5f, 5.0f);
    }
}


// ---------------------------------------------------------------------------
// Presentation: the valley seen straight from above

vertex ScreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2(float((vertexID << 1u) & 2u), float(vertexID & 2u));
    ScreenVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

float mapScale(float2 resolution) {
    return min(resolution.x / float(gridW), resolution.y / float(gridH));
}

float2 mapOffset(float2 resolution) {
    return 0.5f * (resolution - mapScale(resolution) * float2(float(gridW), float(gridH)));
}

float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, float3(2.4f)), c / 12.92f, c <= 0.04045f);
}

// Generated images are premultiplied display sRGB; returns linear colour.
float3 textureColor(texture2d<float> image, float2 uv) {
    constexpr sampler materialSampler(coord::normalized, address::mirrored_repeat,
        filter::linear);
    float4 sample = image.sample(materialSampler, uv);
    float3 srgb = clamp(sample.rgb / max(sample.a, 0.001f), float3(0.0f), float3(1.0f));
    return srgbToLinear(srgb);
}

float3 posterColor(texture2d<float> image, float2 uv) {
    constexpr sampler posterSampler(coord::normalized, address::clamp_to_edge,
        filter::linear);
    float4 sample = image.sample(posterSampler, uv);
    float3 srgb = clamp(sample.rgb / max(sample.a, 0.001f), float3(0.0f), float3(1.0f));
    return srgbToLinear(srgb);
}

struct MapSample {
    float4 ground;  // bilinear elevation, (type), fuel capacity, glow
    float4 cell;    // bilinear fuel, fire, wetness, smoke
    float water;    // corner coverage of each terrain class
    float rock;
    float house;
    float forest;
};

void addCorner(thread MapSample &s, float4 ground, float4 cell, float weight) {
    s.ground += ground * weight;
    s.cell += cell * weight;
    float type = ground.y;
    if (abs(type - typeWater) < 0.5f) s.water += weight;
    else if (abs(type - typeRock) < 0.5f) s.rock += weight;
    else if (type > typeHouse - 0.5f) s.house += weight;
    else if (abs(type - typeForest) < 0.5f) s.forest += weight;
}

MapSample sampleMap(device const float4 *terrain, device const float4 *cells, float2 world) {
    float2 q = clamp(world - 0.5f, float2(0.0f), float2(float(gridW - 1), float(gridH - 1)));
    int2 i = min(int2(floor(q)), int2(gridW - 2, gridH - 2));
    float2 f = q - float2(i);
    MapSample s;
    s.ground = float4(0.0f);
    s.cell = float4(0.0f);
    s.water = 0.0f;
    s.rock = 0.0f;
    s.house = 0.0f;
    s.forest = 0.0f;
    int a = cellIndex(i);
    addCorner(s, terrain[a], cells[a], (1.0f - f.x) * (1.0f - f.y));
    addCorner(s, terrain[a + 1], cells[a + 1], f.x * (1.0f - f.y));
    addCorner(s, terrain[a + gridW], cells[a + gridW], (1.0f - f.x) * f.y);
    addCorner(s, terrain[a + gridW + 1], cells[a + gridW + 1], f.x * f.y);
    return s;
}

float elevationAt(device const float4 *terrain, float2 world) {
    float2 q = clamp(world - 0.5f, float2(0.0f), float2(float(gridW - 1), float(gridH - 1)));
    int2 i = min(int2(floor(q)), int2(gridW - 2, gridH - 2));
    float2 f = q - float2(i);
    int a = cellIndex(i);
    return mix(mix(terrain[a].x, terrain[a + 1].x, f.x),
        mix(terrain[a + gridW].x, terrain[a + gridW + 1].x, f.x), f.y);
}

float forestAt(device const float4 *terrain, float2 world) {
    float2 q = clamp(world - 0.5f, float2(0.0f), float2(float(gridW - 1), float(gridH - 1)));
    int2 i = min(int2(floor(q)), int2(gridW - 2, gridH - 2));
    float2 f = q - float2(i);
    int a = cellIndex(i);
    float4 forest = float4(abs(terrain[a].y - typeForest) < 0.5f ? 1.0f : 0.0f,
        abs(terrain[a + 1].y - typeForest) < 0.5f ? 1.0f : 0.0f,
        abs(terrain[a + gridW].y - typeForest) < 0.5f ? 1.0f : 0.0f,
        abs(terrain[a + gridW + 1].y - typeForest) < 0.5f ? 1.0f : 0.0f);
    return mix(mix(forest.x, forest.y, f.x), mix(forest.z, forest.w, f.x), f.y);
}

float sdBox(float2 q, float2 halfSize) {
    float2 d = abs(q) - halfSize;
    return length(max(d, float2(0.0f))) + min(max(d.x, d.y), 0.0f);
}

float sdRoundBox(float2 q, float2 halfSize, float radius) {
    return sdBox(q, halfSize - float2(radius)) - radius;
}

float sdCapsule(float2 q, float2 a, float2 b, float radius) {
    return segmentDistance(q, a, b) - radius;
}

// Water bomber outline in plane space (x forward, y to the right), in cells.
float planeBody(float2 q) {
    float d = sdCapsule(q, float2(-6.4f, 0.0f), float2(6.0f, 0.0f), 1.15f);
    d = min(d, sdRoundBox(q - float2(1.3f, 0.0f), float2(1.25f, 8.3f), 0.45f));
    d = min(d, sdRoundBox(q - float2(-5.7f, 0.0f), float2(0.75f, 3.1f), 0.3f));
    float2 mirrored = float2(q.x, abs(q.y));
    d = min(d, sdCapsule(mirrored, float2(-0.2f, 3.2f), float2(3.5f, 3.2f), 0.68f));
    d = min(d, sdCapsule(mirrored, float2(0.5f, 7.3f), float2(2.3f, 7.3f), 0.38f));
    return d;
}

float3 planeColor(float2 q, float time) {
    float2 mirrored = float2(q.x, abs(q.y));
    float3 yellow = float3(1.0f, 0.62f, 0.05f);
    float3 red = float3(0.75f, 0.06f, 0.04f);
    float3 color = yellow;
    // Red wing tips, nose and tail band.
    if (mirrored.y > 6.6f || q.x > 5.0f || (q.x < -4.9f && q.x > -6.5f && mirrored.y > 2.2f)) color = red;
    if (segmentDistance(mirrored, float2(-0.2f, 3.2f), float2(3.5f, 3.2f)) < 0.68f) color = float3(0.16f, 0.17f, 0.19f);
    if (q.x > 3.4f && q.x < 4.7f && mirrored.y < 0.7f) color = float3(0.05f, 0.12f, 0.20f);
    // Wing shading: a lighter leading edge.
    if (abs(q.x - 1.3f) < 1.25f && mirrored.y > 1.2f && mirrored.y < 8.3f) {
        color *= 0.86f + 0.22f * smoothstep(0.0f, 2.4f, q.x - 0.05f);
    }
    float body = planeBody(q);
    return color * (0.72f + 0.30f * smoothstep(0.0f, 0.9f, -body));
}

float3 flameColor(float heat) {
    float3 ember = float3(0.85f, 0.10f, 0.02f);
    float3 orange = float3(1.0f, 0.38f, 0.04f);
    float3 yellow = float3(1.0f, 0.80f, 0.32f);
    return heat < 0.5f ? mix(ember, orange, heat * 2.0f) : mix(orange, yellow, heat * 2.0f - 1.0f);
}

float3 shadeValley(float2 world, float2 pixelSize, device const GameState &game,
    device const float4 *terrain, device const float4 *cells,
    texture2d<float> forestTexture, texture2d<float> meadowTexture,
    texture2d<float> rockTexture, texture2d<float> lakeTexture,
    texture2d<float> ashTexture, float time) {
    float2 jitter = float2(valueNoise(world * 0.45f, 3u), valueNoise(world * 0.45f, 4u)) - 0.5f;
    MapSample s = sampleMap(terrain, cells, world + jitter * 1.4f);
    float forest = smoothstep(0.35f, 0.65f, s.forest + 0.25f * (valueNoise(world * 1.1f, 6u) - 0.5f));
    float rock = smoothstep(0.3f, 0.7f, s.rock);
    float water = smoothstep(0.42f, 0.58f, s.water);

    // Ground materials from the generated textures.
    // Each 1024 x 1024 generated image spans most of the 480 x 300 cell valley,
    // so it is shown at about one texel per pixel and does not visibly repeat.
    float3 meadow = textureColor(meadowTexture, world / 470.0f);
    meadow *= mix(float3(1.08f, 1.0f, 0.82f), float3(0.86f, 1.02f, 0.88f),
        valueNoise(world * 0.02f, 8u));
    float3 trees = textureColor(forestTexture, world / 480.0f + float2(0.03f, 0.11f));
    trees = mix(trees, textureColor(forestTexture, world.yx / 390.0f), 0.25f);
    float3 stone = textureColor(rockTexture, world / 380.0f);
    // Tree crowns cast shadows to the south-east onto open ground.
    float crownShadow = smoothstep(0.3f, 0.7f, forestAt(terrain, world - float2(1.3f, 1.7f) + jitter));
    meadow *= 1.0f - 0.38f * crownShadow;
    float3 color = mix(meadow, trees, forest);
    color = mix(color, stone, rock);
    // Raised rock: a dark rim around each outcrop.
    color *= 1.0f - 0.35f * (smoothstep(0.15f, 0.45f, s.rock) - smoothstep(0.5f, 0.85f, s.rock));

    // Hill shading from the elevation field.
    float2 e = float2(elevationAt(terrain, world + float2(1.5f, 0.0f))
        - elevationAt(terrain, world - float2(1.5f, 0.0f)),
        elevationAt(terrain, world + float2(0.0f, 1.5f))
        - elevationAt(terrain, world - float2(0.0f, 1.5f)));
    float3 normal = normalize(float3(-e.x * elevationScale, 1.0f, -e.y * elevationScale));
    float3 sun = normalize(float3(-0.55f, 0.75f, -0.45f));
    float shade = 0.55f + 0.55f * max(dot(normal, sun), 0.0f);
    color *= shade * (0.86f + 0.24f * s.ground.x);

    // Charred ground where fuel has burned away.
    float burnt = s.ground.z > 0.02f ? clamp(1.0f - s.cell.x / s.ground.z, 0.0f, 1.0f) : 0.0f;
    float3 ash = textureColor(ashTexture, world / 460.0f) * 0.75f;
    float charred = smoothstep(0.30f, 0.80f, burnt + 0.15f * (valueNoise(world * 0.7f, 12u) - 0.5f));
    color = mix(color, ash * shade, charred * (1.0f - water));

    // Lakes: texture, ripples and a sandy shore line.
    if (s.water > 0.02f) {
        float3 lake = textureColor(lakeTexture, world / 420.0f + float2(time * 0.002f, 0.0f));
        lake = mix(lake, float3(0.02f, 0.07f, 0.11f), 0.35f);
        float depth = smoothstep(0.5f, 1.0f, s.water);
        lake *= mix(1.15f, 0.75f, depth);
        float ripple = valueNoise(world * float2(0.30f, 1.1f) + float2(time * 0.25f, time * 0.5f), 14u);
        lake += float3(0.05f, 0.07f, 0.08f) * smoothstep(0.80f, 0.97f, ripple);
        float shore = 1.0f - smoothstep(0.0f, 0.12f, abs(s.water - 0.5f));
        color = mix(color, lake, water);
        color = mix(color, float3(0.55f, 0.50f, 0.38f), shore * 0.6f);
    }

    // Houses with gabled roofs.
    for (int v = 0; v < villageSlots; ++v) {
        float2 local = world - game.villages[v].xy;
        if (abs(local.x) > 11.0f || abs(local.y) > 11.0f) continue;
        for (int house = 0; house < housesPerVillage; ++house) {
            float4 rect = houseRect(v, house);
            float2 q = local - rect.xy;
            float d = sdBox(q, rect.zw);
            if (d > 1.2f) continue;
            // Soft shadow to the south-east, then the roof.
            float shadow = 1.0f - smoothstep(-0.2f, 0.9f, sdBox(q - float2(0.7f, 0.9f), rect.zw));
            color *= 1.0f - 0.45f * shadow * step(0.0f, d);
            float inside = 1.0f - smoothstep(-pixelSize.x, pixelSize.x, d);
            if (inside > 0.0f) {
                bool alongX = rect.z >= rect.w;
                float across = alongX ? q.y / rect.w : q.x / rect.z;
                // Terracotta roof with tile courses parallel to the ridge.
                float2 r = alongX ? q : q.yx;
                float3 roof = mix(float3(0.36f, 0.09f, 0.05f), float3(0.52f, 0.20f, 0.09f),
                    hash01(uint(house) * 7u + uint(v) * 31u));
                roof *= 1.0f - 0.22f * smoothstep(0.55f, 0.9f, fract(abs(r.y) * 1.6f));
                roof *= across < 0.0f ? 1.12f : 0.72f;
                roof *= 1.0f - 0.35f * smoothstep(0.86f, 1.0f, abs(across));
                if (abs(across) < 0.08f) roof *= 0.8f;
                roof = mix(roof, ash * 0.6f, charred);
                color = mix(color, roof, inside);
            }
        }
    }

    // Wet ground is darker and bluer.
    float wet = water > 0.5f ? 0.0f : clamp(s.cell.z, 0.0f, 1.2f);
    color = mix(color, color * float3(0.55f, 0.68f, 0.85f), smoothstep(0.05f, 0.7f, wet));

    // Embers in the char.
    float embers = smoothstep(0.82f, 0.97f, valueNoise(world * 2.2f + float2(0.0f, time * 0.4f), 17u));
    color += float3(1.0f, 0.25f, 0.03f) * embers * smoothstep(0.4f, 0.9f, charred)
        * clamp(s.cell.y * 6.0f + 0.15f * smoothstep(0.6f, 1.0f, burnt) * (1.0f - smoothstep(0.1f, 0.4f, wet)), 0.0f, 1.0f);

    // Flames and their light.
    float2 flow = game.wind.xy * time * 2.5f;
    float flicker = valueNoise(world * 1.3f - flow + float2(0.0f, time * 1.7f), 21u);
    float fire = s.cell.y * (0.55f + 0.9f * flicker);
    float flame = smoothstep(0.06f, 0.45f, fire);
    color = mix(color, flameColor(clamp(fire, 0.0f, 1.0f)) * 2.4f, flame * 0.92f);
    color += float3(1.0f, 0.33f, 0.07f) * s.ground.w * (0.75f + 0.25f * flicker);

    // Smoke drifting with the wind, lit from below by the fire.
    float wisps = valueNoise(world * 0.12f - flow * 0.8f, 25u) * 0.65f
        + valueNoise(world * 0.31f - flow * 1.3f, 26u) * 0.35f;
    float smoke = 1.0f - exp(-s.cell.w * (0.35f + 0.8f * wisps));
    float3 smokeColor = mix(float3(0.30f, 0.29f, 0.28f), float3(0.85f, 0.38f, 0.14f),
        clamp(s.ground.w * 0.8f, 0.0f, 0.6f));
    color = mix(color, smokeColor, smoke * 0.8f);
    return color;
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

float numberCoverage(float2 p, float2 origin, float cell, uint value) {
    int count = int(digitCount(value));
    float2 spot = (p - origin) / cell;
    if (spot.x < 0.0f || spot.y < 0.0f || spot.y >= 7.0f
        || spot.x >= float(count * 6)) return 0.0f;
    int column = int(spot.x);
    int index = column / 6;
    uint v = value;
    for (int k = 0; k < 9 && k < count - 1 - index; ++k) v /= 10u;
    return glyphDot(48u + v % 10u, column - index * 6, int(spot.y));
}

float numberWidth(uint value, float cell) {
    return (float(digitCount(value)) * 6.0f - 1.0f) * cell;
}

// M:SS, capped at 9:59.
float clockCoverage(float2 p, float2 origin, float cell, float seconds) {
    float2 spot = (p - origin) / cell;
    if (spot.x < 0.0f || spot.y < 0.0f || spot.y >= 7.0f || spot.x >= 24.0f) return 0.0f;
    uint whole = min(uint(ceil(max(seconds, 0.0f))), 599u);
    int column = int(spot.x);
    int index = column / 6;
    uint code = 48u + whole / 60u;
    if (index == 1) code = 58u;
    if (index == 2) code = 48u + (whole % 60u) / 10u;
    if (index == 3) code = 48u + whole % 10u;
    return glyphDot(code, column - index * 6, int(spot.y));
}

constant float clockCells = 23.0f;

void drawText(thread float3 &color, float2 p, float2 origin, float cell, int text,
    float3 ink) {
    float shadow = textCoverage(p, origin + float2(cell * 0.5f), cell, text);
    color = mix(color, float3(0.0f), 0.65f * shadow);
    color = mix(color, ink, textCoverage(p, origin, cell, text));
}

void drawTextCentred(thread float3 &color, float2 p, float centreX, float y, float cell,
    int text, float3 ink) {
    drawText(color, p, float2(centreX - 0.5f * textWidth(text, cell), y), cell, text, ink);
}

void drawNumber(thread float3 &color, float2 p, float2 origin, float cell, uint value,
    float3 ink) {
    float shadow = numberCoverage(p, origin + float2(cell * 0.5f), cell, value);
    color = mix(color, float3(0.0f), 0.65f * shadow);
    color = mix(color, ink, numberCoverage(p, origin, cell, value));
}

void drawClock(thread float3 &color, float2 p, float2 origin, float cell, float seconds,
    float3 ink) {
    float shadow = clockCoverage(p, origin + float2(cell * 0.5f), cell, seconds);
    color = mix(color, float3(0.0f), 0.65f * shadow);
    color = mix(color, ink, clockCoverage(p, origin, cell, seconds));
}

void panel(thread float3 &color, float2 p, float2 lower, float2 upper, float alpha) {
    float2 centre = 0.5f * (lower + upper);
    float d = sdRoundBox(p - centre, 0.5f * (upper - lower), 10.0f);
    float inside = clamp(0.5f - d, 0.0f, 1.0f);
    color = mix(color, float3(0.018f, 0.020f, 0.024f), inside * alpha);
    float rim = clamp(1.0f - abs(d + 1.5f), 0.0f, 1.0f);
    color = mix(color, float3(0.55f, 0.36f, 0.16f), rim * 0.8f);
}

// "SAVE n OF m VILLAGES" centred on centreX.
void drawObjective(thread float3 &color, float2 p, float centreX, float y, float cell,
    uint need, uint count, float3 ink, float3 accent) {
    float gap = 6.0f * cell;
    float width = textWidth(textSave, cell) + numberWidth(need, cell) + textWidth(textOf, cell)
        + numberWidth(count, cell) + textWidth(textVillages, cell) + 4.0f * gap;
    float x = centreX - 0.5f * width;
    drawText(color, p, float2(x, y), cell, textSave, ink);
    x += textWidth(textSave, cell) + gap;
    drawNumber(color, p, float2(x, y), cell, need, accent);
    x += numberWidth(need, cell) + gap;
    drawText(color, p, float2(x, y), cell, textOf, ink);
    x += textWidth(textOf, cell) + gap;
    drawNumber(color, p, float2(x, y), cell, count, accent);
    x += numberWidth(count, cell) + gap;
    drawText(color, p, float2(x, y), cell, textVillages, ink);
}

float windKmh(device const GameState &game) {
    return floor(game.wind.z * 40.0f + 0.5f);
}

void drawWindArrow(thread float3 &color, float2 p, float2 centre, float radius, float2 direction) {
    float ring = abs(length(p - centre) - radius);
    color = mix(color, float3(0.45f, 0.42f, 0.36f), clamp(1.5f - ring, 0.0f, 1.0f) * 0.8f);
    float2 tip = centre + direction * radius * 0.78f;
    float2 tail = centre - direction * radius * 0.70f;
    float2 side = float2(-direction.y, direction.x);
    float d = segmentDistance(p, tail, tip) - 2.2f;
    d = min(d, segmentDistance(p, tip, tip - direction * radius * 0.42f + side * radius * 0.32f) - 2.2f);
    d = min(d, segmentDistance(p, tip, tip - direction * radius * 0.42f - side * radius * 0.32f) - 2.2f);
    color = mix(color, float3(0.95f, 0.92f, 0.85f), clamp(0.5f - d, 0.0f, 1.0f));
}

void drawHouseIcon(thread float3 &color, float2 p, float2 centre, float size, float3 fill) {
    float2 q = (p - centre) / size;
    float body = sdBox(q - float2(0.0f, 0.25f), float2(0.62f, 0.45f));
    // Roof: apex at y = -0.95, eaves at y = -0.2 spanning x = +-0.85.
    float rise = q.y + 0.95f;
    float roof = max((abs(q.x) * 0.75f - rise * 0.85f) / 1.134f, max(-rise, q.y + 0.2f));
    float d = min(body, roof) * size;
    color = mix(color, float3(0.0f), clamp(2.0f - d, 0.0f, 1.0f) * 0.6f);
    color = mix(color, fill, clamp(0.5f - d, 0.0f, 1.0f));
}

void drawPoster(thread float3 &color, float2 p, float2 lower, float size,
    texture2d<float> posterTexture) {
    float2 uv = (p - lower) / size;
    float frame = sdBox(p - lower - float2(0.5f * size), float2(0.5f * size + 8.0f));
    color = mix(color, float3(0.82f, 0.74f, 0.58f), clamp(0.5f - frame, 0.0f, 1.0f));
    if (uv.x >= 0.0f && uv.y >= 0.0f && uv.x <= 1.0f && uv.y <= 1.0f) {
        color = posterColor(posterTexture, uv);
    }
}

int rankText(float score) {
    if (score >= 14500.0f) return textRank4;
    if (score >= 11000.0f) return textRank3;
    if (score >= 7500.0f) return textRank2;
    return textRank1;
}

void drawHud(thread float3 &color, float2 p, float2 size, device const GameState &game,
    float time) {
    uint phase = game.flow.x;
    float3 white = float3(0.93f, 0.92f, 0.88f);
    float3 gold = float3(1.0f, 0.70f, 0.22f);
    float3 dim = float3(0.62f, 0.60f, 0.55f);
    float3 cyan = float3(0.35f, 0.80f, 1.0f);

    // Mission name.
    panel(color, p, float2(16.0f, 14.0f), float2(400.0f, 86.0f), 0.72f);
    drawText(color, p, float2(32.0f, 26.0f), 3.0f, textMission, gold);
    drawNumber(color, p, float2(32.0f + textWidth(textMission, 3.0f) + 18.0f, 26.0f), 3.0f,
        game.flow.y + 1u, gold);
    drawText(color, p, float2(32.0f, 52.0f), 3.0f, missionNameText(game.flow.y), white);

    // Rain countdown.
    float centreX = 0.5f * size.x;
    panel(color, p, float2(centreX - 110.0f, 14.0f), float2(centreX + 110.0f, 100.0f), 0.72f);
    drawTextCentred(color, p, centreX, 22.0f, 3.0f, textRainIn, dim);
    float3 clockInk = game.clock.x < 20.0f && phase == phasePlay ? cyan : white;
    drawClock(color, p, float2(centreX - 0.5f * clockCells * 7.5f, 42.0f), 7.5f, game.clock.x, clockInk);

    // Score and wind.
    float right = size.x - 16.0f;
    panel(color, p, float2(right - 380.0f, 14.0f), float2(right, 92.0f), 0.72f);
    drawText(color, p, float2(right - 364.0f, 24.0f), 3.0f, textScore, dim);
    drawNumber(color, p, float2(right - 364.0f, 50.0f), 4.5f, uint(game.score.x), white);
    drawText(color, p, float2(right - 215.0f, 24.0f), 3.0f, textWind, dim);
    uint kmh = uint(windKmh(game));
    drawNumber(color, p, float2(right - 215.0f, 50.0f), 4.5f, kmh, white);
    drawText(color, p, float2(right - 215.0f + numberWidth(kmh, 4.5f) + 12.0f, 60.5f), 3.0f,
        textKmh, dim);
    drawWindArrow(color, p, float2(right - 44.0f, 53.0f), 26.0f, game.wind.xy);

    // Water tank.
    float bottom = size.y - 16.0f;
    panel(color, p, float2(16.0f, bottom - 66.0f), float2(360.0f, bottom), 0.72f);
    drawText(color, p, float2(32.0f, bottom - 56.0f), 3.0f, textWater, dim);
    if (game.planeAux.w > 0.5f) {
        float blink = step(0.5f, fract(time * 2.5f));
        drawText(color, p, float2(140.0f, bottom - 56.0f), 3.0f, textScooping, mix(cyan, white, blink));
    }
    float2 barLow = float2(32.0f, bottom - 30.0f);
    float2 barHigh = float2(344.0f, bottom - 14.0f);
    float bar = sdBox(p - 0.5f * (barLow + barHigh), 0.5f * (barHigh - barLow));
    color = mix(color, float3(0.05f, 0.07f, 0.09f), clamp(0.5f - bar, 0.0f, 1.0f));
    float filled = barLow.x + (barHigh.x - barLow.x) * clamp(game.planeAux.x, 0.0f, 1.0f);
    if (bar < 0.0f && p.x < filled) {
        float wave = 0.5f + 0.5f * sin(p.x * 0.15f - time * 4.0f);
        color = mix(float3(0.08f, 0.38f, 0.75f), float3(0.25f, 0.70f, 1.0f),
            0.6f * wave * smoothstep(barHigh.y, barLow.y, p.y));
    }
    color = mix(color, float3(0.6f, 0.55f, 0.45f), clamp(1.0f - abs(bar), 0.0f, 1.0f));

    // Villages.
    int villages = int(game.villageInfo.x);
    panel(color, p, float2(right - 390.0f, bottom - 66.0f), float2(right, bottom), 0.72f);
    drawObjective(color, p, right - 195.0f, bottom - 58.0f, 3.0f, uint(game.villageInfo.y),
        uint(game.villageInfo.x), dim, white);
    for (int v = 0; v < villageSlots; ++v) {
        if (v >= villages) break;
        float2 centre = float2(right - 195.0f + (float(v) - 0.5f * float(villages - 1)) * 48.0f,
            bottom - 20.0f);
        float3 fill = float3(0.45f, 0.85f, 0.45f);
        if (game.villages[v].w > 0.5f) {
            fill = mix(float3(1.0f, 0.55f, 0.08f), float3(1.0f, 0.2f, 0.05f),
                0.5f + 0.5f * sin(time * 9.0f));
        }
        if (game.villages[v].z > 0.5f) fill = float3(0.20f, 0.06f, 0.05f);
        drawHouseIcon(color, p, centre, 14.0f, fill);
    }

    // Centre message.
    bool showMessage = phase == phasePlay || (phase == phaseWon && game.clock.y <= 2.5f)
        || (phase == phaseLost && game.clock.y <= 1.0f);
    if (game.message.y > 0.0f && game.message.x >= 0.0f && showMessage) {
        int text = int(game.message.x);
        float alpha = clamp(game.message.y * 3.0f, 0.0f, 1.0f);
        float width = textWidth(text, 4.5f);
        float3 before = color;
        panel(color, p, float2(centreX - 0.5f * width - 24.0f, 116.0f),
            float2(centreX + 0.5f * width + 24.0f, 174.0f), 0.6f);
        float3 ink = white;
        if (text == textLightning || text == textDanger) ink = gold;
        if (text == textVillageLost || text == textTankEmpty) ink = float3(1.0f, 0.35f, 0.25f);
        if (text == textTankFull || text == textGo || text == textRain || text == textContained) ink = cyan;
        drawTextCentred(color, p, centreX, 129.0f, 4.5f, text, ink);
        color = mix(before, color, alpha);
    }
}

void drawScreens(thread float3 &color, float2 p, float2 size, device const GameState &game,
    float time, texture2d<float> posterTexture) {
    uint phase = game.flow.x;
    float3 white = float3(0.93f, 0.92f, 0.88f);
    float3 gold = float3(1.0f, 0.70f, 0.22f);
    float3 orange = float3(1.0f, 0.45f, 0.12f);
    float3 dim = float3(0.62f, 0.60f, 0.55f);
    float3 cyan = float3(0.35f, 0.80f, 1.0f);
    float cx = 0.5f * size.x;
    float cy = 0.5f * size.y;
    float blink = 0.55f + 0.45f * sin(time * 4.0f);

    if (phase == phaseTitle || phase == phaseVictory) {
        color *= 0.38f;
        panel(color, p, float2(cx - 650.0f, cy - 350.0f), float2(cx + 650.0f, cy + 350.0f), 0.78f);
        drawPoster(color, p, float2(cx - 610.0f, cy - 290.0f), 400.0f, posterTexture);
        float x = cx - 170.0f;
        drawText(color, p, float2(x, cy - 294.0f), 7.5f, textTitle, gold);
        if (phase == phaseTitle) {
            drawText(color, p, float2(x, cy - 222.0f), 3.0f, textSubtitle, orange);
            for (int line = 0; line < 6; ++line) {
                drawText(color, p, float2(x, cy - 160.0f + float(line) * 44.0f), 3.0f,
                    textHow1 + line, white);
            }
            drawTextCentred(color, p, cx, cy + 250.0f, 4.5f, textPressStart, mix(dim, gold, blink));
        } else {
            drawText(color, p, float2(x, cy - 222.0f), 4.5f, textVictory, cyan);
            drawText(color, p, float2(x, cy - 140.0f), 3.0f, textFinalScore, dim);
            drawNumber(color, p, float2(x, cy - 112.0f), 9.0f, uint(game.score.x), white);
            drawText(color, p, float2(x, cy - 10.0f), 3.0f, textRank, dim);
            drawText(color, p, float2(x, cy + 18.0f), 6.0f, rankText(game.score.x), gold);
            drawTextCentred(color, p, cx, cy + 250.0f, 4.5f, textAgain, mix(dim, gold, blink));
        }
        return;
    }
    if (phase == phaseBriefing) {
        color *= 0.85f;
        panel(color, p, float2(cx - 430.0f, cy - 160.0f), float2(cx + 430.0f, cy + 160.0f), 0.72f);
        float y = cy - 135.0f;
        float missionWidth = textWidth(textMission, 4.5f) + 27.0f + numberWidth(game.flow.y + 1u, 4.5f);
        drawText(color, p, float2(cx - 0.5f * missionWidth, y), 4.5f, textMission, orange);
        drawNumber(color, p, float2(cx + 0.5f * missionWidth - numberWidth(game.flow.y + 1u, 4.5f), y),
            4.5f, game.flow.y + 1u, orange);
        drawTextCentred(color, p, cx, cy - 92.0f, 6.0f, missionNameText(game.flow.y), gold);
        drawTextCentred(color, p, cx, cy - 22.0f, 3.0f, missionBriefText(game.flow.y), white);
        drawObjective(color, p, cx, cy + 22.0f, 3.0f, uint(game.villageInfo.y),
            uint(game.villageInfo.x), white, gold);
        uint kmh = uint(windKmh(game));
        float windWidth = textWidth(textWind, 3.0f) + numberWidth(kmh, 3.0f)
            + textWidth(textKmh, 3.0f) + 36.0f + 60.0f;
        float wx = cx - 0.5f * windWidth;
        drawText(color, p, float2(wx, cy + 66.0f), 3.0f, textWind, white);
        wx += textWidth(textWind, 3.0f) + 18.0f;
        drawNumber(color, p, float2(wx, cy + 66.0f), 3.0f, kmh, gold);
        wx += numberWidth(kmh, 3.0f) + 18.0f;
        drawText(color, p, float2(wx, cy + 66.0f), 3.0f, textKmh, white);
        wx += textWidth(textKmh, 3.0f) + 34.0f;
        drawWindArrow(color, p, float2(wx, cy + 76.0f), 20.0f, game.wind.xy);
        drawTextCentred(color, p, cx, cy + 118.0f, 3.0f, textTakeOff, mix(dim, gold, blink));
        return;
    }
    if (phase == phaseWon && game.clock.y > 2.5f) {
        panel(color, p, float2(cx - 390.0f, cy - 180.0f), float2(cx + 390.0f, cy + 200.0f), 0.82f);
        int title = textComplete;
        if (game.misc.w > 0.5f) title = textContained;
        drawTextCentred(color, p, cx, cy - 155.0f, 6.0f, title, cyan);
        float left = cx - 340.0f;
        float valueRight = cx + 340.0f;
        for (int row = 0; row < 5; ++row) {
            float y = cy - 70.0f + float(row) * 42.0f;
            int label = textVillagesSaved;
            uint value = uint(game.result.x);
            float3 ink = white;
            if (row == 1) { label = textWildland; value = uint(game.result.y); }
            if (row == 2) { label = textBonus; value = uint(game.result.z); }
            if (row == 3) { label = textMissionScore; value = uint(game.result.w); ink = gold; }
            if (row == 4) { label = textScore; value = uint(game.score.x); ink = gold; }
            drawText(color, p, float2(left, y), 3.0f, label, row >= 3 ? gold : white);
            float width = numberWidth(value, 3.0f);
            if (row == 1) {
                drawText(color, p, float2(valueRight - textWidth(textPercent, 3.0f), y), 3.0f,
                    textPercent, ink);
                width += textWidth(textPercent, 3.0f) + 6.0f;
            }
            drawNumber(color, p, float2(valueRight - width, y), 3.0f, value, ink);
        }
        int next = textNext;
        if (game.flow.y >= 2u) next = textContinue;
        drawTextCentred(color, p, cx, cy + 150.0f, 3.0f, next, mix(dim, gold, blink));
        return;
    }
    if (phase == phaseLost && game.clock.y > 1.0f) {
        panel(color, p, float2(cx - 390.0f, cy - 110.0f), float2(cx + 390.0f, cy + 110.0f), 0.82f);
        drawTextCentred(color, p, cx, cy - 85.0f, 6.0f, textFailed, float3(1.0f, 0.32f, 0.22f));
        drawTextCentred(color, p, cx, cy - 10.0f, 3.0f, textTooMany, white);
        drawTextCentred(color, p, cx, cy + 50.0f, 3.0f, textRetry, mix(dim, gold, blink));
    }
}

// ---------------------------------------------------------------------------
// World-space overlays: villages, lightning, water, the plane

void drawOverlays(thread float3 &color, float2 world, float cell, constant ProgramUniforms &u,
    device const GameState &game, float time) {
    uint phase = game.flow.x;
    // Village rings.
    for (int v = 0; v < villageSlots; ++v) {
        if (v >= int(game.villageInfo.x)) break;
        float ring = abs(length(world - game.villages[v].xy) - 15.0f);
        float line = clamp(1.0f - (ring - 0.35f) / cell, 0.0f, 1.0f);
        float3 ink = float3(0.55f, 0.95f, 0.55f);
        float alpha = 0.45f;
        if (game.villages[v].w > 0.5f) {
            ink = float3(1.0f, 0.45f, 0.08f);
            alpha = 0.55f + 0.45f * sin(time * 9.0f);
        }
        if (game.villages[v].z > 0.5f) {
            ink = float3(0.45f, 0.05f, 0.03f);
            alpha = 0.8f;
        }
        color = mix(color, ink, line * alpha);
    }

    // Lightning: a fading ring where it struck and the bolt itself.
    if (game.strikeMark.z < 5.0f) {
        float age = game.strikeMark.z;
        float ring = abs(length(world - game.strikeMark.xy) - (4.0f + age * 3.0f));
        color = mix(color, float3(1.0f, 0.92f, 0.45f),
            clamp(1.0f - (ring - 0.4f) / cell, 0.0f, 1.0f) * (1.0f - age / 5.0f));
    }
    if (game.strikeMark.w > 0.0f) {
        float2 strikePoint = game.strikeMark.xy;
        float2 from = strikePoint + float2(18.0f, -150.0f);
        float bolt = 1000.0f;
        float2 previous = from;
        for (int k = 1; k <= 8; ++k) {
            float t = float(k) / 8.0f;
            float2 next = mix(from, strikePoint, t);
            if (k < 8) next.x += (hash01(uint(k) * 977u + uint(game.counters.y) * 131u) - 0.5f) * 16.0f;
            bolt = min(bolt, segmentDistance(world, previous, next));
            previous = next;
        }
        float strength = game.strikeMark.w / 0.45f;
        color += float3(0.75f, 0.80f, 1.0f) * strength * (clamp(1.0f - (bolt - 0.3f) / cell, 0.0f, 1.0f) * 2.5f
            + 0.6f * exp(-bolt * 0.35f));
    }

    // Water mist from the drop.
    for (int i = 0; i < trailSlots; ++i) {
        float4 drop = game.trail[i];
        if (drop.z > 1.4f) continue;
        float radius = 4.0f + drop.z * 5.0f;
        float d = length(world - drop.xy);
        if (d > radius) continue;
        float grain = valueNoise(world * 0.9f + float2(float(i) * 3.1f, drop.z * 6.0f), 31u);
        float mist = (1.0f - d / radius) * (1.0f - drop.z / 1.4f) * (0.5f + 0.6f * grain);
        color = mix(color, float3(0.85f, 0.92f, 1.0f), clamp(mist * 0.75f * drop.w, 0.0f, 0.85f));
    }

    float2 position = game.plane.xy;
    float heading = game.plane.z;
    float2 forward = float2(cos(heading), sin(heading));
    float2 rightward = float2(-forward.y, forward.x);
    float altitude = game.planeAux.y;

    // Spray while skimming the lake.
    if (game.planeAux.w > 0.5f && altitude < 0.6f) {
        float2 rel = world - position;
        float along = dot(rel, forward);
        float side = abs(dot(rel, rightward));
        if (along < 2.0f && along > -22.0f) {
            float width = 1.5f + 0.25f * (-along);
            float foam = (1.0f - smoothstep(0.0f, width, side)) * (1.0f + along / 22.0f);
            foam *= 0.5f + 0.7f * valueNoise(world * 1.4f + float2(time * 5.0f), 33u);
            color = mix(color, float3(0.92f, 0.96f, 1.0f), clamp(foam, 0.0f, 0.9f));
        }
    }

    // Planned swath for the next drop.
    bool playing = phase == phasePlay;
    if (playing && game.planeAux.x > 0.05f && game.planeAux.z <= 0.0f) {
        float reach = game.plane.w * game.planeAux.x * dropSeconds;
        float d = segmentDistance(world, position + forward * 2.0f, position + forward * (2.0f + reach));
        float edge = abs(d - dropRadius);
        float dash = step(0.5f, fract(dot(world - position, forward) * 0.25f - time * 2.0f));
        color = mix(color, float3(0.45f, 0.85f, 1.0f),
            clamp(1.0f - (edge - 0.25f) / cell, 0.0f, 1.0f) * 0.55f * dash);
        color = mix(color, float3(0.45f, 0.85f, 1.0f), (d < dropRadius ? 0.08f : 0.0f));
    }

    // Steering target.
    if (playing) {
        float2 goal = clamp(pointerToWorld(u.pointer.xy, u.resolutionTime.xy),
            float2(4.0f), float2(float(gridW) - 4.0f, float(gridH) - 4.0f));
        float2 rel = world - goal;
        float ring = abs(length(rel) - 4.5f);
        float arm = min(abs(rel.x), abs(rel.y));
        float tick = length(rel) > 2.0f && length(rel) < 7.0f && arm < 0.35f ? 1.0f : 0.0f;
        float mark = max(clamp(1.0f - (ring - 0.3f) / cell, 0.0f, 1.0f), tick);
        color = mix(color, float3(1.0f, 1.0f, 1.0f), mark * 0.7f);
    }

    // Shadow, then the plane and its propellers.
    float planeScale = 1.0f + 0.18f * altitude;
    float2 shadowShift = float2(4.5f, 6.0f) * (0.25f + altitude);
    float2 shadowRel = world - position - shadowShift;
    float2 shadowQ = float2(dot(shadowRel, forward), dot(shadowRel, rightward)) / planeScale;
    if (dot(shadowQ, shadowQ) < 120.0f) {
        float shadow = 1.0f - smoothstep(-0.3f, 0.6f, planeBody(shadowQ));
        color *= 1.0f - 0.5f * shadow;
    }
    float2 rel = world - position;
    float2 q = float2(dot(rel, forward), dot(rel, rightward)) / planeScale;
    if (dot(q, q) < 120.0f) {
        float body = planeBody(q);
        float coverage = 1.0f - smoothstep(-cell * 0.6f, cell * 0.6f, body * planeScale);
        if (coverage > 0.0f) color = mix(color, planeColor(q, time), coverage);
        float2 mirrored = float2(q.x, abs(q.y));
        float disc = length(mirrored - float2(3.85f, 3.2f));
        if (disc < 1.9f) {
            float angle = atan2(mirrored.y - 3.2f, mirrored.x - 3.85f) + time * 40.0f;
            float blade = pow(abs(cos(angle)), 12.0f);
            color = mix(color, float3(0.15f, 0.15f, 0.16f), 0.18f + 0.45f * blade * (disc / 1.9f));
        }
    }
}

// ---------------------------------------------------------------------------
// Present pass

fragment float4 valleyFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    device const float4 *terrain [[buffer(2)]],
    device const float4 *cells [[buffer(3)]],
    texture2d<float> forestTexture [[texture(1)]],
    texture2d<float> meadowTexture [[texture(2)]],
    texture2d<float> rockTexture [[texture(3)]],
    texture2d<float> lakeTexture [[texture(4)]],
    texture2d<float> ashTexture [[texture(5)]],
    texture2d<float> posterTexture [[texture(6)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 pixel = in.uv * resolution;
    float time = game.misc.z; // real-time animation clock kept by advanceValley
    float scale = mapScale(resolution);
    float2 world = (pixel - mapOffset(resolution)) / scale;
    float cell = 1.0f / scale;
    uint phase = game.flow.x;

    float3 color;
    bool onMap = world.x >= 0.0f && world.y >= 0.0f
        && world.x < float(gridW) && world.y < float(gridH);
    if (onMap) {
        color = shadeValley(world, float2(cell), game, terrain, cells, forestTexture,
            meadowTexture, rockTexture, lakeTexture, ashTexture, time);
    } else {
        float pattern = valueNoise(pixel * 0.012f, 41u);
        color = mix(float3(0.020f, 0.025f, 0.022f), float3(0.026f, 0.032f, 0.027f), pattern);
    }
    drawOverlays(color, world, cell, u, game, time);

    // Rain front after the mission.
    if (phase == phaseWon) {
        float fade = clamp(game.clock.y * 0.8f, 0.0f, 1.0f);
        color *= 1.0f - 0.25f * fade;
        float2 slant = float2(pixel.x + pixel.y * 0.22f, pixel.y);
        float column = floor(slant.x / 9.0f);
        float phaseOffset = hash01(uint(column + 4096.0f) * 2654435761u);
        float fall = fract(slant.y / 140.0f - time * 2.2f + phaseOffset);
        float streak = (1.0f - smoothstep(0.0f, 0.18f, fall)) * step(0.55f, phaseOffset);
        float thin = 1.0f - smoothstep(0.4f, 1.2f, abs(fract(slant.x / 9.0f) * 9.0f - 4.5f));
        color = mix(color, float3(0.70f, 0.78f, 0.88f), streak * thin * 0.35f * fade);
    }
    // Lightning flash.
    if (game.strikeMark.w > 0.0f) {
        float flash = game.strikeMark.w / 0.45f;
        color = mix(color, color * 1.6f + float3(0.05f, 0.055f, 0.07f), flash * flash);
    }

    // HUD in a 1440 x 900 design space.
    float ui = min(resolution.x / 1440.0f, resolution.y / 900.0f);
    float2 design = pixel / ui;
    float2 designSize = resolution / ui;
    if (phase == phasePlay || phase == phaseWon || phase == phaseLost) {
        drawHud(color, design, designSize, game, time);
    }
    drawScreens(color, design, designSize, game, time, posterTexture);

    // Soft highlight roll-off, then the display transfer.
    float3 lit = max(color, float3(0.0f));
    float3 rolled = 0.8f + 0.2f * (1.0f - exp(-(lit - 0.8f) * 5.0f));
    float3 mapped = select(lit, rolled, lit > 0.8f);
    float3 srgb = select(1.055f * pow(mapped, float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
    return float4(clamp(srgb, float3(0.0f), float3(1.0f)), 1.0f);
}

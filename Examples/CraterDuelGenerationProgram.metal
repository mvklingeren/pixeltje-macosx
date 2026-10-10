#include <metal_stdlib>
using namespace metal;

// Crater Duel: a turn-based artillery duel for the generic GPU Program node.
//
// The player's green tank (left) aims at the Trackpad crosshair: the direction
// from its turret to the crosshair sets the barrel angle, and the distance sets
// the firing speed. Action or Space fires. Shells follow gravity plus the wind
// shown at the top, carve craters into a destructible height-field ridge, and
// damage nearby tanks. Tanks drop into craters dug beneath them. The red enemy
// (right) answers with a simulated ballistic solution whose error shrinks after
// each of its shots. Win the configured number of rounds to conquer the ridge.
//
// All game state lives in one GPU buffer advanced by single-thread kernels once
// per Loop call; the fragment pass only reads it.
//
// World units: x runs 0..320 from left to right, y runs 0..200 from bottom to
// top. The world is fitted into the output frame (16:10 fills 1440 x 900).
//
// Generated textures from the Asset Cache, sampled as sRGB albedo:
//   texture(1) asset0 soil, texture(2) asset1 grass turf,
//   texture(3) asset2 bedrock, texture(4) asset3 armor plate,
//   texture(5) asset4 dusk sky backdrop.
//
// Parameters, in declared order: windStrength (0 calm, 1 normal, up to 3),
// enemySkill (1 normal, 0.25..4; higher aims better), roundsToWin (1..9).

constant float worldWidth = 320.0f;
constant float worldHeight = 200.0f;
constant int columnCount = 640;
constant float columnWidth = 0.5f;
constant float bedrockHeight = 6.0f;
constant float gravity = 90.0f;
constant float minimumSpeed = 25.0f;
constant float maximumSpeed = 172.0f;
constant float speedPerUnit = 1.6f;
constant float barrelLength = 8.5f;
constant float craterRadius = 13.0f;
constant float damageRadius = 23.0f;
constant float lowestAngle = 0.04f;
constant float highestAngle = 3.1015926f; // pi - 0.04

constant uint phaseAim = 0u;
constant uint phaseFlight = 1u;
constant uint phaseBlast = 2u;
constant uint phaseEnemyThink = 3u;
constant uint phaseRoundWon = 4u;
constant uint phaseDefeat = 5u;
constant uint phaseVictory = 6u;

constant uint resultNone = 0u;
constant uint resultMiss = 1u;
constant uint resultHit = 2u;
constant uint resultDirect = 3u;
constant uint resultOut = 4u;

// Must match the engine's slot-0 uniform layout exactly.
struct ProgramUniforms {
    float4 resolutionTime;
    uint4 frameSeed;
    float4 parameters0;
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;
};

struct Tank {
    float4 body;   // x, ground contact y, hit points, barrel angle (radians)
    float4 motion; // tilt (radians), hit flash seconds, fall velocity, shown hit points
};

// Buffer layout with Metal alignment (float4/uint4 = 16 bytes, align 16):
//   tanks[2]             2 * 32 =   64 bytes at offset    0
//   shell .. feedback    6 * 16 =   96 bytes at offset   64
//   flow, score          2 * 16 =   32 bytes at offset  160
//   heights[640]       640 *  4 = 2560 bytes at offset  192
//   pristine[640]      640 *  4 = 2560 bytes at offset 2752
//   sizeof(GameState)            = 5312 bytes (a multiple of 16).
// The workflow declares an 8192-byte "game" buffer, which covers it.
struct GameState {
    Tank tanks[2];   // 0 = player (left), 1 = enemy (right)
    float4 shell;    // launch x, launch y, launch velocity x, launch velocity y
    float4 flight;   // seconds in flight, shooter (0 player, 1 enemy), active, wind
    float4 blast;    // impact x, impact y, seconds since impact, kind (-1 none, 0 ground, 1 direct)
    float4 aim;      // player speed, player angle, current wind, seconds in phase
    float4 ai;       // enemy angle, enemy speed, enemy shots this round, player shots this round
    float4 feedback; // shake seconds, message seconds, last damage dealt, last action count
    uint4 flow;      // phase, round (1-based), random state, shots fired this campaign
    uint4 score;     // score, rounds won, best score, last shot result
    float heights[columnCount];  // current terrain surface per 0.5-unit column
    float pristine[columnCount]; // surface at round start (craters show bare earth)
};

// 5 x 7 dot font for ASCII 32 (space) to 90 (Z); bit 4 is the leftmost dot.
constant uchar fontRows[413] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ' '
    0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04,  // '!'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '"'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '#'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '$'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '%'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '&'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // "'"
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '('
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ')'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '*'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // '+'
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
constant uchar textPool[279] = {
    83, 67, 79, 82, 69, 66, 69, 83, 84, 82, 79, 85, 78, 68, 47, 87,
    73, 78, 68, 67, 65, 76, 77, 80, 79, 87, 69, 82, 65, 78, 71, 76,
    69, 89, 79, 85, 82, 32, 84, 85, 82, 78, 32, 45, 32, 83, 80, 65,
    67, 69, 32, 84, 79, 32, 70, 73, 82, 69, 68, 82, 65, 71, 32, 84,
    79, 32, 65, 73, 77, 32, 45, 32, 70, 65, 82, 84, 72, 69, 82, 32,
    77, 69, 65, 78, 83, 32, 77, 79, 82, 69, 32, 80, 79, 87, 69, 82,
    83, 72, 69, 76, 76, 32, 65, 87, 65, 89, 73, 78, 67, 79, 77, 73,
    78, 71, 33, 68, 73, 82, 69, 67, 84, 32, 72, 73, 84, 33, 72, 73,
    84, 33, 77, 73, 83, 83, 79, 85, 84, 32, 79, 70, 32, 82, 65, 78,
    71, 69, 69, 78, 69, 77, 89, 32, 73, 83, 32, 65, 73, 77, 73, 78,
    71, 69, 78, 69, 77, 89, 32, 68, 69, 83, 84, 82, 79, 89, 69, 68,
    83, 80, 65, 67, 69, 32, 70, 79, 82, 32, 84, 72, 69, 32, 78, 69,
    88, 84, 32, 82, 79, 85, 78, 68, 84, 65, 78, 75, 32, 76, 79, 83,
    84, 83, 80, 65, 67, 69, 32, 84, 79, 32, 84, 82, 89, 32, 65, 71,
    65, 73, 78, 82, 73, 68, 71, 69, 32, 67, 79, 78, 81, 85, 69, 82,
    69, 68, 70, 73, 78, 65, 76, 32, 83, 67, 79, 82, 69, 83, 80, 65,
    67, 69, 32, 84, 79, 32, 80, 76, 65, 89, 32, 65, 71, 65, 73, 78,
    89, 79, 85, 70, 79, 69, 45,
};
constant int textRanges[54] = {
    0, 5,  // SCORE
    5, 4,  // BEST
    9, 5,  // ROUND
    14, 1,  // /
    15, 4,  // WIND
    19, 4,  // CALM
    23, 5,  // POWER
    28, 5,  // ANGLE
    33, 25,  // YOUR TURN - SPACE TO FIRE
    58, 38,  // DRAG TO AIM - FARTHER MEANS MORE POWER
    96, 10,  // SHELL AWAY
    106, 9,  // INCOMING!
    115, 11,  // DIRECT HIT!
    126, 4,  // HIT!
    130, 4,  // MISS
    134, 12,  // OUT OF RANGE
    146, 15,  // ENEMY IS AIMING
    161, 15,  // ENEMY DESTROYED
    176, 24,  // SPACE FOR THE NEXT ROUND
    200, 9,  // TANK LOST
    209, 18,  // SPACE TO TRY AGAIN
    227, 15,  // RIDGE CONQUERED
    242, 11,  // FINAL SCORE
    253, 19,  // SPACE TO PLAY AGAIN
    272, 3,  // YOU
    275, 3,  // FOE
    278, 1,  // -
};
constant int textScore = 0;
constant int textBest = 1;
constant int textRound = 2;
constant int textSlash = 3;
constant int textWind = 4;
constant int textCalm = 5;
constant int textPower = 6;
constant int textAngle = 7;
constant int textYourTurn = 8;
constant int textAimHint = 9;
constant int textShellAway = 10;
constant int textIncoming = 11;
constant int textDirectHit = 12;
constant int textHit = 13;
constant int textMiss = 14;
constant int textOutOfRange = 15;
constant int textEnemyAiming = 16;
constant int textEnemyDestroyed = 17;
constant int textNextRound = 18;
constant int textTankLost = 19;
constant int textTryAgain = 20;
constant int textRidgeConquered = 21;
constant int textFinalScore = 22;
constant int textPlayAgain = 23;
constant int textYou = 24;
constant int textFoe = 25;
constant int textMinus = 26;

// ---------------------------------------------------------------------------
// Random numbers and settings

uint hashUInt(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    value ^= value >> 16;
    return value;
}

float nextRandom(thread uint &state) {
    state = hashUInt(state + 0x9e3779b9u);
    return float(state >> 8) * (1.0f / 16777216.0f);
}

float hashUnit(uint index, uint salt) {
    return float(hashUInt(index * 747796405u + salt * 2891336453u) >> 8)
        * (1.0f / 16777216.0f);
}

float windStrength(constant ProgramUniforms &u) {
    return clamp(u.parameters0.x, 0.0f, 3.0f);
}

float enemySkill(constant ProgramUniforms &u) {
    return u.parameters0.y > 0.0f ? clamp(u.parameters0.y, 0.25f, 4.0f) : 1.0f;
}

uint roundsToWin(constant ProgramUniforms &u) {
    if (u.parameters0.z < 1.0f) return 5u;
    return uint(clamp(floor(u.parameters0.z + 0.5f), 1.0f, 9.0f));
}

float enemyMaxHitPoints(uint roundIndex) {
    return 80.0f + 10.0f * float(max(roundIndex, 1u) - 1u);
}

// ---------------------------------------------------------------------------
// World and screen coordinates (pixels: origin top-left, y down)

float worldScale(float2 resolution) {
    return min(resolution.x / worldWidth, resolution.y / worldHeight);
}

float2 worldOrigin(float2 resolution) {
    return 0.5f * (resolution
        - float2(worldWidth, worldHeight) * worldScale(resolution));
}

float2 pixelToWorld(float2 pixel, float2 resolution) {
    float2 local = (pixel - worldOrigin(resolution)) / worldScale(resolution);
    return float2(local.x, worldHeight - local.y);
}

float2 worldToPixel(float2 world, float2 resolution) {
    return worldOrigin(resolution)
        + float2(world.x, worldHeight - world.y) * worldScale(resolution);
}

// ---------------------------------------------------------------------------
// Terrain height field

// Returns the interpolated surface height and its slope at x.
float2 terrainAt(device const float *heights, float x) {
    float column = clamp(x / columnWidth, 0.0f, float(columnCount - 1));
    int first = min(int(column), columnCount - 2);
    float blend = column - float(first);
    float left = heights[first];
    float right = heights[first + 1];
    return float2(mix(left, right, blend), (right - left) / columnWidth);
}

float heightAt(device const float *heights, float x) {
    return terrainAt(heights, x).x;
}

float terrainTilt(device const float *heights, float x) {
    float rise = heightAt(heights, x + 5.0f) - heightAt(heights, x - 5.0f);
    return clamp(atan2(rise, 10.0f), -0.5f, 0.5f);
}

// ---------------------------------------------------------------------------
// Tank and shell geometry

float2 rotate2(float2 value, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float2(c * value.x - s * value.y, s * value.x + c * value.y);
}

float2 turretPivot(Tank tank) {
    return tank.body.xy + rotate2(float2(0.0f, 6.0f), tank.motion.x);
}

float2 hullCenter(Tank tank) {
    return tank.body.xy + rotate2(float2(0.0f, 3.2f), tank.motion.x);
}

bool insideHull(Tank tank, float2 point) {
    float2 offset = (point - hullCenter(tank)) / float2(8.0f, 4.8f);
    return dot(offset, offset) < 1.0f;
}

float2 shellPosition(float4 shell, float wind, float seconds) {
    return shell.xy + shell.zw * seconds
        + 0.5f * float2(wind, -gravity) * seconds * seconds;
}

// ---------------------------------------------------------------------------
// Round setup

struct TerrainShape {
    float base;
    float3 phase;
    float ridgeX;
    float ridgeHeight;
    float ridgeWidth;
};

float rawTerrain(TerrainShape shape, float x) {
    float ridge = (x - shape.ridgeX) / shape.ridgeWidth;
    return shape.base
        + 16.0f * sin(x * 0.021f + shape.phase.x)
        + 8.0f * sin(x * 0.057f + shape.phase.y)
        + 2.5f * sin(x * 0.16f + shape.phase.z)
        + 0.9f * sin(x * 0.93f + 3.0f * shape.phase.z)
        + shape.ridgeHeight * exp(-ridge * ridge);
}

void generateTerrain(device GameState &game, thread uint &rng) {
    float level = float(min(game.flow.y, 6u));
    TerrainShape shape;
    shape.base = 34.0f + 22.0f * nextRandom(rng);
    float phaseX = 6.2831853f * nextRandom(rng);
    float phaseY = 6.2831853f * nextRandom(rng);
    float phaseZ = 6.2831853f * nextRandom(rng);
    shape.phase = float3(phaseX, phaseY, phaseZ);
    shape.ridgeX = 128.0f + 64.0f * nextRandom(rng);
    shape.ridgeHeight = 16.0f + 7.0f * level + 22.0f * nextRandom(rng);
    shape.ridgeWidth = 16.0f + 14.0f * nextRandom(rng);
    float playerX = 30.0f + 40.0f * nextRandom(rng);
    float enemyX = 250.0f + 40.0f * nextRandom(rng);
    // Tank pads stay well above the bottom of the frame.
    float playerPad = max(rawTerrain(shape, playerX), 38.0f);
    float enemyPad = max(rawTerrain(shape, enemyX), 38.0f);
    for (int column = 0; column < columnCount; ++column) {
        float x = float(column) * columnWidth;
        float height = rawTerrain(shape, x);
        height = mix(height, playerPad,
            1.0f - smoothstep(7.0f, 17.0f, abs(x - playerX)));
        height = mix(height, enemyPad,
            1.0f - smoothstep(7.0f, 17.0f, abs(x - enemyX)));
        height = clamp(height, bedrockHeight + 14.0f, 150.0f);
        game.heights[column] = height;
        game.pristine[column] = height;
    }
    game.tanks[0].body.xy = float2(playerX, heightAt(game.heights, playerX));
    game.tanks[1].body.xy = float2(enemyX, heightAt(game.heights, enemyX));
}

void rollWind(device GameState &game, constant ProgramUniforms &u,
    thread uint &rng) {
    float limit = (6.0f + 3.0f * float(min(game.flow.y, 5u))) * windStrength(u);
    // Whole numbers read cleanly in the wind gauge.
    game.aim.z = floor((nextRandom(rng) * 2.0f - 1.0f) * limit + 0.5f);
}

void startRound(device GameState &game, constant ProgramUniforms &u,
    uint roundIndex) {
    uint rng = game.flow.z;
    game.flow.y = roundIndex;
    generateTerrain(game, rng);
    float enemyHitPoints = enemyMaxHitPoints(roundIndex);
    game.tanks[0].body.zw = float2(100.0f, 0.8f);
    game.tanks[1].body.zw = float2(enemyHitPoints, 2.36f);
    game.tanks[0].motion = float4(terrainTilt(game.heights,
        game.tanks[0].body.x), 0.0f, 0.0f, 100.0f);
    game.tanks[1].motion = float4(terrainTilt(game.heights,
        game.tanks[1].body.x), 0.0f, 0.0f, enemyHitPoints);
    game.shell = float4(0.0f);
    game.flight = float4(0.0f);
    game.blast = float4(0.0f, 0.0f, 99.0f, -1.0f);
    game.ai = float4(2.36f, 120.0f, 0.0f, 0.0f);
    game.feedback.xyz = float3(0.0f);
    game.score.w = resultNone;
    rollWind(game, u, rng);
    game.flow.x = phaseAim;
    game.aim.w = 0.0f;
    game.flow.z = rng;
}

// ---------------------------------------------------------------------------
// Turn simulation

void updatePlayerAim(device GameState &game, constant ProgramUniforms &u) {
    Tank player = game.tanks[0];
    if (player.body.z <= 0.0f) return;
    float2 resolution = u.resolutionTime.xy;
    float2 pointer = clamp(u.pointer.xy, float2(0.0f), float2(1.0f));
    float2 target = pixelToWorld(pointer * resolution, resolution);
    float2 delta = target - turretPivot(player);
    float angle = atan2(delta.y, delta.x);
    if (delta.y < 0.0f) {
        // Below the turret: hold the barrel level toward that side.
        if (delta.x >= 0.0f) {
            angle = lowestAngle;
        } else {
            angle = highestAngle;
        }
    }
    game.aim.x = clamp(length(delta) * speedPerUnit, minimumSpeed, maximumSpeed);
    game.aim.y = clamp(angle, lowestAngle, highestAngle);
    game.tanks[0].body.w = game.aim.y;
}

void launchShell(device GameState &game, uint shooter, float speed,
    float angle) {
    Tank tank = game.tanks[shooter];
    float2 direction = float2(cos(angle), sin(angle));
    float2 muzzle = turretPivot(tank) + direction * barrelLength;
    game.shell = float4(muzzle, direction * speed);
    game.flight = float4(0.0f, float(shooter), 1.0f, game.aim.z);
    game.tanks[shooter].body.w = angle;
    game.flow.x = phaseFlight;
    game.flow.w += 1u;
    game.aim.w = 0.0f;
    if (shooter == 0u) {
        game.ai.w += 1.0f;
    } else {
        game.ai.z += 1.0f;
    }
}

void explode(device GameState &game, float2 point, int directTank) {
    // Carve a shallow circular crater; bedrock cannot be destroyed.
    int first = max(0, int(floor((point.x - craterRadius) / columnWidth)));
    int last = min(columnCount - 1,
        int(ceil((point.x + craterRadius) / columnWidth)));
    for (int column = first; column <= last; ++column) {
        float offset = float(column) * columnWidth - point.x;
        float inside = craterRadius * craterRadius - offset * offset;
        if (inside <= 0.0f) continue;
        float floorHeight = point.y - 0.8f * sqrt(inside);
        game.heights[column] = max(bedrockHeight,
            min(game.heights[column], floorHeight));
    }
    uint shooter = uint(game.flight.y);
    float dealt = 0.0f;
    for (uint index = 0u; index < 2u; ++index) {
        Tank tank = game.tanks[index];
        if (tank.body.z <= 0.0f) continue;
        float reach = length(point - hullCenter(tank));
        float damage = 58.0f * clamp(1.0f - reach / damageRadius, 0.0f, 1.0f);
        if (int(index) == directTank) damage += 14.0f;
        if (damage < 0.5f) continue;
        game.tanks[index].body.z = max(0.0f, tank.body.z - damage);
        game.tanks[index].motion.y = 0.5f;
        if (index != shooter) dealt += damage;
    }
    bool direct = directTank >= 0 && directTank != int(shooter);
    uint result = resultMiss;
    if (dealt >= 0.5f) result = resultHit;
    if (direct) result = resultDirect;
    if (shooter == 0u) {
        game.score.x += uint(dealt + 0.5f) + (direct ? 25u : 0u);
    }
    game.score.w = result;
    game.feedback.x = 0.3f + 0.3f * clamp(dealt / 40.0f, 0.0f, 1.0f);
    game.feedback.y = 1.8f;
    game.feedback.z = dealt;
    game.blast = float4(point, 0.0f, direct ? 1.0f : 0.0f);
    game.flight.z = 0.0f;
    game.flow.x = phaseBlast;
    game.aim.w = 0.0f;
}

void shellLeftWorld(device GameState &game) {
    game.score.w = resultOut;
    game.feedback.y = 1.6f;
    game.feedback.z = 0.0f;
    game.blast.w = -1.0f;
    game.flight.z = 0.0f;
    game.flow.x = phaseBlast;
    game.aim.w = 0.5f; // a shorter pause than an explosion
}

void advanceShell(device GameState &game, float dt) {
    float start = game.flight.x;
    uint shooter = uint(game.flight.y);
    // Six sub-steps keep fast shells from skipping thin ground or a hull.
    for (int part = 1; part <= 6; ++part) {
        float seconds = start + dt * float(part) / 6.0f;
        float2 point = shellPosition(game.shell, game.flight.w, seconds);
        int directTank = -1;
        for (uint index = 0u; index < 2u; ++index) {
            Tank tank = game.tanks[index];
            if (tank.body.z <= 0.0f) continue;
            if (index == shooter && seconds < 0.3f) continue;
            if (insideHull(tank, point)) directTank = int(index);
        }
        bool grounded = point.y <= heightAt(game.heights, point.x);
        if (directTank >= 0 || grounded) {
            game.flight.x = seconds;
            explode(game, point, directTank);
            return;
        }
        if (point.x < -40.0f || point.x > worldWidth + 40.0f
            || seconds > 14.0f) {
            game.flight.x = seconds;
            shellLeftWorld(game);
            return;
        }
    }
    game.flight.x = start + dt;
}

// Drops tanks onto the (possibly carved) ground. Returns true when both rest.
bool settleTanks(device GameState &game, float dt) {
    bool settled = true;
    for (uint index = 0u; index < 2u; ++index) {
        Tank tank = game.tanks[index];
        float ground = heightAt(game.heights, tank.body.x);
        if (tank.body.y > ground + 0.02f) {
            settled = false;
            tank.motion.z -= gravity * dt;
            tank.body.y += tank.motion.z * dt;
            if (tank.body.y <= ground) {
                float impact = -tank.motion.z;
                tank.body.y = ground;
                tank.motion.z = 0.0f;
                float damage = clamp((impact - 30.0f) * 0.5f, 0.0f, 25.0f);
                if (damage > 0.0f && tank.body.z > 0.0f) {
                    tank.body.z = max(0.0f, tank.body.z - damage);
                    tank.motion.y = 0.5f;
                }
            }
        } else {
            tank.body.y = ground;
            tank.motion.z = 0.0f;
        }
        float tilt = terrainTilt(game.heights, tank.body.x);
        tank.motion.x += (tilt - tank.motion.x) * min(1.0f, dt * 8.0f);
        game.tanks[index] = tank;
    }
    return settled;
}

// Distance from where a trial shell lands to the target hull (0 on a hit).
float simulateMiss(device const float *heights, float2 start, float2 velocity,
    float wind, Tank target) {
    float2 aimPoint = hullCenter(target);
    for (int stepIndex = 1; stepIndex <= 160; ++stepIndex) {
        float seconds = float(stepIndex) * 0.04f;
        float2 point = start + velocity * seconds
            + 0.5f * float2(wind, -gravity) * seconds * seconds;
        if (insideHull(target, point)) return 0.0f;
        if (point.x < -40.0f || point.x > worldWidth + 40.0f) return 1000.0f;
        if (point.y <= heightAt(heights, point.x)) {
            return length(point - aimPoint);
        }
    }
    return 2000.0f;
}

void planEnemyShot(device GameState &game, constant ProgramUniforms &u,
    thread uint &rng) {
    Tank enemy = game.tanks[1];
    Tank player = game.tanks[0];
    float2 pivot = turretPivot(enemy);
    float wind = game.aim.z;
    float baseAngle = 2.15f + 0.30f * nextRandom(rng); // 123 to 140 degrees
    float bestMiss = 1.0e9f;
    float bestAngle = baseAngle;
    float bestSpeed = 120.0f;
    for (int option = 0; option < 3; ++option) {
        float angle = min(baseAngle + 0.17f * float(option), 2.95f);
        float2 direction = float2(cos(angle), sin(angle));
        float2 muzzle = pivot + direction * barrelLength;
        for (int candidate = 0; candidate < 50; ++candidate) {
            float speed = 40.0f + 2.7f * float(candidate);
            float miss = simulateMiss(game.heights, muzzle, direction * speed,
                wind, player);
            if (miss < bestMiss) {
                bestMiss = miss;
                bestAngle = angle;
                bestSpeed = speed;
            }
        }
        if (bestMiss < 3.0f) break; // steeper arcs only when a ridge blocks
    }
    // The solution is exact; the gunner's error shrinks with every shot it
    // takes this round, with later rounds, and with the enemySkill setting.
    float roundsPlayed = float(min(game.flow.y, 9u) - 1u);
    float base = max(32.0f - 3.0f * roundsPlayed, 8.0f);
    float spread = max(base * pow(0.72f, game.ai.z) / enemySkill(u) + 1.5f, 1.0f);
    float noise = nextRandom(rng) * 2.0f - 1.0f;
    noise = sign(noise) * (0.35f + 0.65f * abs(noise));
    game.ai.x = bestAngle;
    game.ai.y = clamp(bestSpeed + noise * spread, minimumSpeed, maximumSpeed);
}

void resolveTurn(device GameState &game, constant ProgramUniforms &u) {
    uint rng = game.flow.z;
    float playerHitPoints = game.tanks[0].body.z;
    float enemyHitPoints = game.tanks[1].body.z;
    game.aim.w = 0.0f;
    if (playerHitPoints <= 0.0f) {
        game.flow.x = phaseDefeat;
    } else if (enemyHitPoints <= 0.0f) {
        uint shotBonus = 25u * uint(max(0.0f, 6.0f - game.ai.w));
        game.score.x += 200u + uint(playerHitPoints) * 2u + shotBonus;
        game.score.y += 1u;
        if (game.score.y >= roundsToWin(u)) {
            game.flow.x = phaseVictory;
        } else {
            game.flow.x = phaseRoundWon;
        }
    } else {
        rollWind(game, u, rng);
        if (game.flight.y < 0.5f) {
            planEnemyShot(game, u, rng);
            game.flow.x = phaseEnemyThink;
        } else {
            game.flow.x = phaseAim;
        }
    }
    game.score.z = max(game.score.z, game.score.x);
    game.flow.z = rng;
}

kernel void initializeDuel(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    uint rng = hashUInt(u.frameSeed.y ^ hashUInt(u.frameSeed.z + 0x51ed270bu));
    game.flow = uint4(phaseAim, 1u, rng, 0u);
    game.score = uint4(0u);
    // The run's current action count is the baseline, not a fire command.
    game.feedback = float4(0.0f, 0.0f, 0.0f, u.pointer.z);
    game.aim = float4(100.0f, 0.8f, 0.0f, 0.0f);
    startRound(game, u, 1u);
    updatePlayerAim(game, u);
}

kernel void advanceDuel(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = min(u.resolutionTime.w, 0.05f);
    // A larger count than last frame is one Action/Space press.
    bool pressed = u.pointer.z > game.feedback.w;
    game.feedback.w = u.pointer.z;
    game.aim.w += dt;
    game.blast.z += dt;
    game.feedback.x = max(0.0f, game.feedback.x - dt);
    game.feedback.y = max(0.0f, game.feedback.y - dt);
    for (uint index = 0u; index < 2u; ++index) {
        game.tanks[index].motion.y = max(0.0f, game.tanks[index].motion.y - dt);
        game.tanks[index].motion.w += (game.tanks[index].body.z
            - game.tanks[index].motion.w) * min(1.0f, dt * 5.0f);
    }
    bool settled = settleTanks(game, dt);
    updatePlayerAim(game, u);

    uint phase = game.flow.x;
    if (phase == phaseAim) {
        if (pressed) launchShell(game, 0u, game.aim.x, game.aim.y);
    } else if (phase == phaseFlight) {
        advanceShell(game, dt);
    } else if (phase == phaseBlast) {
        if (game.aim.w >= 1.2f && settled) resolveTurn(game, u);
    } else if (phase == phaseEnemyThink) {
        float current = game.tanks[1].body.w;
        game.tanks[1].body.w = current
            + clamp(game.ai.x - current, -2.4f * dt, 2.4f * dt);
        if (game.aim.w >= 1.1f) launchShell(game, 1u, game.ai.y, game.ai.x);
    } else if (phase == phaseRoundWon) {
        if (pressed && game.aim.w > 0.6f) {
            game.flow.z ^= hashUInt(u.frameSeed.x + 0x632be5abu);
            startRound(game, u, game.flow.y + 1u);
        }
    } else if (pressed && game.aim.w > 0.6f) {
        // Defeat or victory: Space starts a new campaign on a new ridge.
        game.flow.z ^= hashUInt(u.frameSeed.x + 0x85ebca6bu);
        game.score.x = 0u;
        game.score.y = 0u;
        game.flow.w = 0u;
        startRound(game, u, 1u);
    }
}

// ---------------------------------------------------------------------------
// Presentation

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenVertex duelVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1u) & 2u, vertexID & 2u);
    ScreenVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

float3 decodeSRGB(float4 texel) {
    float3 srgb = clamp(texel.rgb / max(texel.a, 0.001f),
        float3(0.0f), float3(1.0f));
    return select(pow((srgb + 0.055f) / 1.055f, float3(2.4f)),
        srgb / 12.92f, srgb <= 0.04045f);
}

float3 textureAlbedo(texture2d<float> image, float2 uv) {
    constexpr sampler materialSampler(coord::normalized,
        address::mirrored_repeat, filter::linear);
    return decodeSRGB(image.sample(materialSampler, uv));
}

float3 backdropAlbedo(texture2d<float> image, float2 uv) {
    constexpr sampler backdropSampler(coord::normalized,
        address::clamp_to_edge, filter::linear);
    return decodeSRGB(image.sample(backdropSampler, uv));
}

float lumaOf(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

float sdRoundBox(float2 point, float2 halfSize, float radius) {
    float2 q = abs(point) - halfSize + radius;
    return length(max(q, float2(0.0f))) + min(max(q.x, q.y), 0.0f) - radius;
}

float sdSegment(float2 point, float2 a, float2 b) {
    float2 pa = point - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.000001f), 0.0f, 1.0f);
    return length(pa - ba * h);
}

// Anti-aliased fill from a signed distance in world units.
float fillCoverage(float signedDistance, float pixelSize) {
    return clamp(0.5f - signedDistance / pixelSize, 0.0f, 1.0f);
}

float3 shadeTerrain(float2 world, float2 terrain, float pristineHeight,
    texture2d<float> soil, texture2d<float> grass, texture2d<float> rock,
    float4 blast) {
    float depth = max(terrain.x - world.y, 0.0f);
    float3 earth = textureAlbedo(soil, world * float2(0.0095f, -0.0095f))
        * float3(1.0f, 0.92f, 0.82f);
    float3 stone = textureAlbedo(rock, world * 0.011f + float2(0.31f, 0.0f))
        * float3(0.85f, 0.88f, 0.95f);
    float bedrock = 1.0f - smoothstep(bedrockHeight - 1.0f,
        bedrockHeight + 4.0f, world.y + 2.0f * sin(world.x * 0.23f));
    float seam = smoothstep(30.0f, 46.0f,
        depth + 6.0f * sin(world.x * 0.05f + 1.3f));
    float3 body = mix(earth, stone, max(bedrock, 0.75f * seam));
    body *= mix(1.0f, 0.5f, smoothstep(0.0f, 60.0f, depth));
    float2 normal = normalize(float2(-terrain.y, 1.0f));
    float sun = max(dot(normal, normalize(float2(-0.45f, 0.89f))), 0.0f);
    float surface = exp(-depth / 3.0f);
    body *= mix(1.0f, 0.55f + 0.65f * sun, surface);
    // Turf survives only where no crater has lowered the ground.
    float carved = smoothstep(0.25f, 1.5f, pristineHeight - terrain.x);
    float tuft = 2.1f + 0.6f * sin(world.x * 2.7f)
        + 0.4f * sin(world.x * 6.1f + 1.3f);
    float turfMask = (1.0f - smoothstep(tuft - 0.5f, tuft, depth))
        * (1.0f - carved);
    float3 turf = textureAlbedo(grass, world * 0.012f)
        * float3(0.85f, 1.05f, 0.75f) * (0.7f + 0.5f * sun);
    body = mix(body, turf, turfMask);
    body *= mix(1.0f, 0.5f, carved * exp(-depth / 4.0f));
    if (blast.w >= 0.0f) {
        float2 offset = world - blast.xy;
        float heat = exp(-dot(offset, offset)
            / (craterRadius * craterRadius * 0.7f));
        float cooling = clamp(1.0f - (blast.z - 0.2f) / 3.5f, 0.0f, 1.0f);
        body += float3(1.4f, 0.45f, 0.08f) * heat * cooling * cooling
            * exp(-depth / 2.0f) * 0.8f;
    }
    return body;
}

void paintTank(thread float3 &color, float2 world, float pixelSize, Tank tank,
    bool enemy, texture2d<float> armor, float time) {
    if (length(world - tank.body.xy) > 24.0f) return;
    bool destroyed = tank.body.z <= 0.0f;
    float facing = enemy ? -1.0f : 1.0f;
    float2 local = rotate2(world - tank.body.xy, -tank.motion.x);
    float3 tint = enemy ? float3(0.78f, 0.30f, 0.22f)
        : float3(0.36f, 0.60f, 0.34f);
    // The generated plate supplies wear and rivets; the tint names the side.
    float grain = lumaOf(textureAlbedo(armor,
        world * 0.02f + (enemy ? float2(0.43f, 0.17f) : float2(0.0f))));
    float3 plate = tint * (0.45f + 1.2f * grain);
    float angle = destroyed ? (enemy ? 3.6f : -0.46f) : tank.body.w;
    float2 pivot = turretPivot(tank);
    float2 direction = float2(cos(angle), sin(angle));
    float2 muzzle = pivot + direction * barrelLength;
    float barrel = sdSegment(world, pivot, muzzle) - 0.72f;
    float brake = sdSegment(world, muzzle - direction * 1.5f, muzzle) - 1.05f;
    float antenna = sdSegment(local, float2(-4.6f * facing, 5.2f),
        float2(-5.6f * facing, 12.5f)) - 0.16f;
    float dome = max(length(local - float2(-0.6f * facing, 5.0f)) - 3.4f,
        5.0f - local.y);
    float hull = sdRoundBox(local - float2(0.0f, 4.0f),
        float2(6.4f, 1.5f), 0.8f);
    float tread = sdRoundBox(local - float2(0.0f, 1.55f),
        float2(7.5f, 1.55f), 1.5f);

    color = mix(color, float3(0.10f, 0.10f, 0.11f),
        fillCoverage(antenna, pixelSize));
    if (!destroyed) {
        float blink = step(0.5f, fract(time * 1.3f + (enemy ? 0.5f : 0.0f)));
        float3 beacon = enemy ? float3(2.2f, 0.25f, 0.15f)
            : float3(0.35f, 2.0f, 0.5f);
        float tip = length(local - float2(-5.6f * facing, 12.6f)) - 0.45f;
        color = mix(color, beacon * (0.3f + 0.7f * blink),
            fillCoverage(tip, pixelSize));
    }
    float3 darkMetal = plate * 0.5f;
    color = mix(color, darkMetal, fillCoverage(barrel, pixelSize));
    color = mix(color, darkMetal * 0.8f, fillCoverage(brake, pixelSize));
    color = mix(color, plate * (0.85f + 0.35f
        * clamp((local.y - 5.0f) / 3.4f, 0.0f, 1.0f)),
        fillCoverage(dome, pixelSize));
    color = mix(color, plate * (0.7f + 0.45f
        * clamp((local.y - 2.5f) / 3.0f, 0.0f, 1.0f)),
        fillCoverage(hull, pixelSize));
    float links = 0.5f + 0.5f * sin(local.x * 3.8f);
    color = mix(color, float3(0.04f, 0.04f, 0.045f) + 0.03f * links,
        fillCoverage(tread, pixelSize));
    for (int wheel = 0; wheel < 4; ++wheel) {
        float2 center = float2(-5.4f + 3.6f * float(wheel), 1.55f);
        float reach = length(local - center);
        color = mix(color, float3(0.15f, 0.15f, 0.14f),
            fillCoverage(reach - 1.05f, pixelSize));
        color = mix(color, float3(0.42f, 0.40f, 0.35f),
            fillCoverage(reach - 0.4f, pixelSize));
    }
    float shape = min(min(barrel, brake), min(min(dome, hull), tread));
    float shapeCoverage = fillCoverage(shape, pixelSize);
    if (destroyed) {
        color = mix(color, color * float3(0.22f, 0.20f, 0.19f), shapeCoverage);
    }
    float flash = clamp(tank.motion.y * 2.5f, 0.0f, 1.0f);
    color = mix(color, float3(1.6f, 1.25f, 0.85f), shapeCoverage * flash * 0.75f);
}

void paintWreckSmoke(thread float3 &color, float2 world, Tank tank,
    float time) {
    if (tank.body.z > 0.0f) return;
    float2 source = turretPivot(tank);
    for (int puff = 0; puff < 6; ++puff) {
        float cycle = fract(time * 0.32f + float(puff) / 6.0f);
        float2 at = source + float2(2.5f * sin(float(puff) * 2.1f + time * 0.7f)
            + cycle * 6.0f, cycle * 34.0f);
        float radius = 1.6f + cycle * 5.5f;
        float alpha = 0.55f * (1.0f - cycle) * smoothstep(0.0f, 0.12f, cycle);
        float reach = length(world - at) - radius;
        color = mix(color, float3(0.09f, 0.085f, 0.08f),
            alpha * clamp(0.5f - reach / (radius * 0.8f), 0.0f, 1.0f));
    }
}

// Marching dots along the first half second of the arc, without wind.
void paintAimGuide(thread float3 &color, float2 world, float pixelSize,
    device const GameState &game, float time) {
    Tank player = game.tanks[0];
    if (game.flow.x != phaseAim || player.body.z <= 0.0f) return;
    float angle = game.aim.y;
    float2 direction = float2(cos(angle), sin(angle));
    float2 muzzle = turretPivot(player) + direction * barrelLength;
    float2 velocity = direction * game.aim.x;
    float march = fract(time * 1.5f);
    for (int marker = 1; marker <= 10; ++marker) {
        float seconds = (float(marker) - march) * 0.055f;
        float2 at = muzzle + velocity * seconds
            + float2(0.0f, -0.5f * gravity * seconds * seconds);
        float fade = 1.0f - float(marker) / 11.0f;
        color = mix(color, float3(1.0f, 0.95f, 0.75f),
            0.85f * fade * fillCoverage(length(world - at) - 0.65f, pixelSize));
    }
}

void paintShell(thread float3 &color, float2 world, float pixelSize,
    device const GameState &game) {
    if (game.flight.z < 0.5f) return;
    float seconds = game.flight.x;
    float wind = game.flight.w;
    for (int puff = 12; puff >= 1; --puff) {
        float age = float(puff) * 0.045f;
        float past = seconds - age;
        if (past < 0.0f) continue;
        float2 at = shellPosition(game.shell, wind, past) + float2(0.0f, age * 4.0f);
        float radius = 0.6f + 0.22f * float(puff);
        float alpha = 0.55f * (1.0f - float(puff) / 13.0f);
        float reach = length(world - at) - radius;
        color = mix(color, float3(0.55f, 0.53f, 0.50f),
            alpha * clamp(0.5f - reach / (radius * 0.9f + pixelSize), 0.0f, 1.0f));
    }
    float2 at = shellPosition(game.shell, wind, seconds);
    float reach = length(world - at);
    color += float3(1.6f, 0.75f, 0.2f) * exp(-reach * reach / 3.5f) * 0.9f;
    color = mix(color, float3(0.08f, 0.07f, 0.06f),
        fillCoverage(reach - 1.0f, pixelSize));
}

void paintBlast(thread float3 &color, float2 world, float pixelSize,
    float4 blast) {
    if (blast.w < 0.0f || blast.z > 2.2f) return;
    float age = blast.z;
    float2 center = blast.xy;
    // Clods of earth thrown out on ballistic arcs.
    float clodFade = 1.0f - smoothstep(1.2f, 2.0f, age);
    for (uint index = 0u; index < 14u; ++index) {
        float angle = 0.25f + 2.64f * hashUnit(index, 3u);
        float speed = 30.0f + 55.0f * hashUnit(index, 7u);
        float2 at = center + float2(cos(angle), sin(angle)) * speed * age
            + float2(0.0f, -0.5f * gravity * age * age);
        float size = 0.45f + 0.5f * hashUnit(index, 11u);
        color = mix(color, float3(0.10f, 0.07f, 0.05f),
            clodFade * fillCoverage(length(world - at) - size, pixelSize));
    }
    float reach = length(world - center);
    if (reach > 4.0f * craterRadius) return;
    // Rising smoke column.
    float2 smokeCenter = center + float2(0.0f, age * 12.0f);
    float smokeRadius = craterRadius * (0.6f + 0.6f * age);
    float smokeAlpha = smoothstep(0.15f, 0.5f, age)
        * (1.0f - smoothstep(1.2f, 2.2f, age)) * 0.6f;
    float smoke = length(world - smokeCenter) - smokeRadius;
    color = mix(color, float3(0.11f, 0.10f, 0.095f),
        smokeAlpha * clamp(0.5f - smoke / (0.6f * smokeRadius), 0.0f, 1.0f));
    // Fireball.
    float grow = 1.0f - pow(1.0f - clamp(age / 0.35f, 0.0f, 1.0f), 3.0f);
    float radius = craterRadius * (0.35f + 0.85f * grow);
    float fade = 1.0f - smoothstep(0.15f, 0.95f, age);
    float heat = clamp(1.0f - reach / radius, 0.0f, 1.0f);
    float3 fire = mix(float3(2.2f, 0.55f, 0.08f), float3(3.2f, 2.6f, 1.4f),
        heat * heat);
    color = mix(color, fire, fade * smoothstep(0.0f, 0.25f, heat));
    // Shock ring.
    float ringProgress = clamp(age / 0.45f, 0.0f, 1.0f);
    float ring = abs(reach - 2.6f * craterRadius * ringProgress);
    color += float3(1.0f, 0.8f, 0.55f) * (1.0f - smoothstep(0.0f, 1.2f, ring))
        * (1.0f - ringProgress) * 0.6f;
}

// ---------------------------------------------------------------------------
// Pixel-font text (display space)

float glyphDot(uint code, int column, int row) {
    if (code < 32u || code > 90u || column < 0 || column > 4
        || row < 0 || row > 6) return 0.0f;
    uint bits = uint(fontRows[(code - 32u) * 7u + uint(row)]);
    return float((bits >> uint(4 - column)) & 1u);
}

// Origin is the top-left pixel; one font dot is cell pixels wide.
float textCoverage(float2 pixel, float2 origin, float cell, int text) {
    int start = textRanges[text * 2];
    int count = textRanges[text * 2 + 1];
    float2 local = (pixel - origin) / cell;
    if (local.x < 0.0f || local.y < 0.0f || local.y >= 7.0f
        || local.x >= float(count * 6)) return 0.0f;
    int column = int(local.x);
    int character = column / 6;
    return glyphDot(uint(textPool[start + character]),
        column - character * 6, int(local.y));
}

float textWidth(int text, float cell) {
    return (float(textRanges[text * 2 + 1]) * 6.0f - 1.0f) * cell;
}

uint digitCount(uint value) {
    uint count = 1u;
    for (int index = 0; index < 9; ++index) {
        if (value < 10u) break;
        value /= 10u;
        count += 1u;
    }
    return count;
}

float numberCoverage(float2 pixel, float2 origin, float cell, uint value) {
    float2 local = (pixel - origin) / cell;
    if (local.x < 0.0f || local.y < 0.0f || local.y >= 7.0f) return 0.0f;
    uint count = digitCount(value);
    if (local.x >= float(count * 6u)) return 0.0f;
    int column = int(local.x);
    int character = column / 6;
    int remaining = int(count) - 1 - character;
    uint divisor = 1u;
    for (int index = 0; index < 9; ++index) {
        if (index >= remaining) break;
        divisor *= 10u;
    }
    uint digit = (value / divisor) % 10u;
    return glyphDot(48u + digit, column - character * 6, int(local.y));
}

float numberWidth(uint value, float cell) {
    return (float(digitCount(value)) * 6.0f - 1.0f) * cell;
}

void paintText(thread float3 &color, float2 pixel, float2 origin, float cell,
    int text, float3 ink, float alpha) {
    float shadow = textCoverage(pixel - float2(0.7f * cell), origin, cell, text);
    color = mix(color, float3(0.02f, 0.02f, 0.03f), 0.75f * shadow * alpha);
    color = mix(color, ink, textCoverage(pixel, origin, cell, text) * alpha);
}

void paintNumber(thread float3 &color, float2 pixel, float2 origin, float cell,
    uint value, float3 ink, float alpha) {
    float shadow = numberCoverage(pixel - float2(0.7f * cell), origin, cell, value);
    color = mix(color, float3(0.02f, 0.02f, 0.03f), 0.75f * shadow * alpha);
    color = mix(color, ink, numberCoverage(pixel, origin, cell, value) * alpha);
}

float panelMask(float2 pixel, float2 lower, float2 upper, float radius) {
    float2 extent = 0.5f * max(upper - lower, float2(0.0f));
    float corner = min(radius, min(extent.x, extent.y));
    float signedDistance = sdRoundBox(pixel - 0.5f * (lower + upper),
        extent, corner);
    return clamp(0.5f - signedDistance, 0.0f, 1.0f);
}

void paintHud(thread float3 &color, float2 pixel, float2 resolution,
    device const GameState &game, constant ProgramUniforms &u, float time) {
    float ui = min(resolution.x / 1280.0f, resolution.y / 800.0f);
    float3 ink = float3(0.97f, 0.94f, 0.86f);
    float3 gold = float3(1.0f, 0.80f, 0.30f);
    float3 muted = float3(0.66f, 0.70f, 0.76f);
    float3 panel = float3(0.025f, 0.03f, 0.045f);
    uint phase = game.flow.x;
    bool overlay = phase == phaseRoundWon || phase == phaseDefeat
        || phase == phaseVictory;
    if (overlay) color *= 0.5f;

    // Armor bars and names above both tanks.
    for (uint index = 0u; index < 2u; ++index) {
        Tank tank = game.tanks[index];
        float2 anchor = worldToPixel(tank.body.xy + float2(0.0f, 20.0f),
            resolution);
        float maximum = index == 0u ? 100.0f : enemyMaxHitPoints(game.flow.y);
        float fraction = clamp(tank.motion.w / maximum, 0.0f, 1.0f);
        float2 extent = float2(38.0f, 5.0f) * ui;
        color = mix(color, panel, 0.8f * panelMask(pixel, anchor - extent,
            anchor + extent, 4.0f * ui));
        float3 fill = index == 0u ? float3(0.40f, 0.86f, 0.42f)
            : float3(0.95f, 0.36f, 0.26f);
        if (fraction > 0.01f) {
            float2 lower = anchor - extent + 2.0f * ui;
            float2 upper = float2(lower.x
                + (2.0f * extent.x - 4.0f * ui) * fraction,
                anchor.y + extent.y - 2.0f * ui);
            color = mix(color, fill, panelMask(pixel, lower, upper, 2.0f * ui));
        }
        int label = textYou;
        if (index == 1u) label = textFoe;
        float labelCell = 2.2f * ui;
        float2 labelOrigin = float2(anchor.x - 0.5f * textWidth(label, labelCell),
            anchor.y - extent.y - 20.0f * ui);
        paintText(color, pixel, labelOrigin, labelCell, label, fill, 1.0f);
    }

    // Damage dealt by the last shot rises above the target.
    if (game.feedback.y > 0.0f && game.feedback.z >= 1.0f) {
        uint target = 1u - min(uint(game.flight.y), 1u);
        Tank tank = game.tanks[target];
        float popupCell = 3.2f * ui;
        uint amount = uint(game.feedback.z + 0.5f);
        float minusWidth = textWidth(textMinus, popupCell) + popupCell;
        float width = minusWidth + numberWidth(amount, popupCell);
        float2 anchor = worldToPixel(tank.body.xy + float2(0.0f, 20.0f),
            resolution);
        float rise = (1.8f - game.feedback.y) * 26.0f * ui;
        float2 origin = float2(anchor.x - 0.5f * width,
            anchor.y - 56.0f * ui - rise);
        float alpha = clamp(game.feedback.y / 0.5f, 0.0f, 1.0f);
        paintText(color, pixel, origin, popupCell, textMinus, gold, alpha);
        paintNumber(color, pixel, origin + float2(minusWidth, 0.0f), popupCell,
            amount, gold, alpha);
    }

    // Score, best score, round, firing power and barrel elevation.
    float cell = 2.6f * ui;
    color = mix(color, panel, 0.6f * panelMask(pixel, float2(14.0f, 14.0f) * ui,
        float2(276.0f, 162.0f) * ui, 10.0f * ui));
    float2 cursor = float2(28.0f, 26.0f) * ui;
    float valueX = cursor.x + 36.0f * cell; // labels have at most five letters
    float rowStep = 26.0f * ui;
    paintText(color, pixel, cursor, cell, textScore, muted, 1.0f);
    paintNumber(color, pixel, float2(valueX, cursor.y), cell, game.score.x,
        gold, 1.0f);
    cursor.y += rowStep;
    paintText(color, pixel, cursor, cell, textBest, muted, 1.0f);
    paintNumber(color, pixel, float2(valueX, cursor.y), cell,
        max(game.score.z, game.score.x), ink, 1.0f);
    cursor.y += rowStep;
    uint totalRounds = roundsToWin(u);
    uint roundIndex = min(game.flow.y, totalRounds);
    paintText(color, pixel, cursor, cell, textRound, muted, 1.0f);
    paintNumber(color, pixel, float2(valueX, cursor.y), cell, roundIndex,
        ink, 1.0f);
    float slashX = valueX + numberWidth(roundIndex, cell) + cell;
    paintText(color, pixel, float2(slashX, cursor.y), cell, textSlash,
        muted, 1.0f);
    paintNumber(color, pixel, float2(slashX + 6.0f * cell, cursor.y), cell,
        totalRounds, ink, 1.0f);
    cursor.y += rowStep;
    float power = clamp((game.aim.x - minimumSpeed)
        / (maximumSpeed - minimumSpeed), 0.0f, 1.0f);
    paintText(color, pixel, cursor, cell, textPower, muted, 1.0f);
    paintNumber(color, pixel, float2(valueX, cursor.y), cell,
        uint(power * 100.0f + 0.5f), ink, 1.0f);
    float2 barLower = float2(184.0f * ui, cursor.y + 2.0f * ui);
    float2 barUpper = float2(262.0f * ui, cursor.y + 16.0f * ui);
    color = mix(color, float3(0.10f, 0.11f, 0.13f),
        panelMask(pixel, barLower, barUpper, 5.0f * ui));
    if (power > 0.01f) {
        float3 heat = mix(float3(0.35f, 0.85f, 0.40f),
            float3(1.0f, 0.42f, 0.22f), power);
        float2 fillUpper = float2(barLower.x + (barUpper.x - barLower.x) * power,
            barUpper.y);
        color = mix(color, heat, panelMask(pixel, barLower, fillUpper, 5.0f * ui));
    }
    cursor.y += rowStep;
    paintText(color, pixel, cursor, cell, textAngle, muted, 1.0f);
    float elevation = clamp(game.aim.y * 57.29578f, 0.0f, 180.0f);
    paintNumber(color, pixel, float2(valueX, cursor.y), cell,
        uint(elevation + 0.5f), ink, 1.0f);

    // Wind gauge.
    float centerX = 0.5f * resolution.x;
    color = mix(color, panel, 0.6f * panelMask(pixel,
        float2(centerX - 120.0f * ui, 14.0f * ui),
        float2(centerX + 120.0f * ui, 96.0f * ui), 10.0f * ui));
    float wind = game.aim.z;
    uint windValue = uint(abs(wind) + 0.5f);
    float labelWidth = textWidth(textWind, cell) + 2.0f * cell;
    if (windValue == 0u) {
        float total = labelWidth + textWidth(textCalm, cell);
        float2 origin = float2(centerX - 0.5f * total, 26.0f * ui);
        paintText(color, pixel, origin, cell, textWind, muted, 1.0f);
        paintText(color, pixel, origin + float2(labelWidth, 0.0f), cell,
            textCalm, ink, 1.0f);
    } else {
        float total = labelWidth + numberWidth(windValue, cell);
        float2 origin = float2(centerX - 0.5f * total, 26.0f * ui);
        paintText(color, pixel, origin, cell, textWind, muted, 1.0f);
        paintNumber(color, pixel, origin + float2(labelWidth, 0.0f), cell,
            windValue, ink, 1.0f);
        float direction = wind > 0.0f ? 1.0f : -1.0f;
        float headLength = 14.0f * ui;
        float span = min(abs(wind) * 4.5f, 100.0f) * ui;
        float arrowY = 70.0f * ui;
        float2 tip = float2(centerX + direction * 0.5f * (span + headLength),
            arrowY);
        float2 tail = float2(centerX - direction * 0.5f * (span + headLength),
            arrowY);
        float2 headBase = tip - float2(direction * headLength, 0.0f);
        float shaft = sdSegment(pixel, tail, headBase) - 2.6f * ui;
        float2 q = float2((tip.x - pixel.x) * direction, abs(pixel.y - arrowY));
        float head = max(-q.x, max(q.x - headLength, q.y - q.x * 0.62f));
        color = mix(color, float3(0.55f, 0.85f, 1.0f),
            clamp(0.5f - min(shaft, head), 0.0f, 1.0f));
    }

    float bottom = resolution.y;

    // Turn status.
    int message = -1;
    float3 messageInk = ink;
    if (phase == phaseAim) {
        message = textYourTurn;
        messageInk = gold * (0.75f + 0.25f * sin(time * 5.0f));
    } else if (phase == phaseFlight) {
        if (game.flight.y < 0.5f) {
            message = textShellAway;
        } else {
            message = textIncoming;
            messageInk = float3(1.0f, 0.55f, 0.45f);
        }
    } else if (phase == phaseBlast) {
        uint result = game.score.w;
        if (result == resultDirect) {
            message = textDirectHit;
            messageInk = gold;
        } else if (result == resultHit) {
            message = textHit;
        } else if (result == resultOut) {
            message = textOutOfRange;
            messageInk = muted;
        } else {
            message = textMiss;
            messageInk = muted;
        }
    } else if (phase == phaseEnemyThink) {
        message = textEnemyAiming;
        messageInk = float3(1.0f, 0.55f, 0.45f);
    }
    if (message >= 0) {
        float messageCell = 3.0f * ui;
        float2 origin = float2(centerX - 0.5f * textWidth(message, messageCell),
            bottom - 52.0f * ui);
        paintText(color, pixel, origin, messageCell, message, messageInk, 1.0f);
    }
    if (phase == phaseAim && game.flow.w == 0u) {
        float hintCell = 2.2f * ui;
        float2 origin = float2(centerX - 0.5f * textWidth(textAimHint, hintCell),
            bottom - 84.0f * ui);
        paintText(color, pixel, origin, hintCell, textAimHint, muted, 1.0f);
    }

    // Round result, defeat, or campaign victory.
    if (overlay) {
        int title = textEnemyDestroyed;
        int subtitle = textNextRound;
        int scoreLabel = textScore;
        float3 titleInk = gold;
        if (phase == phaseDefeat) {
            title = textTankLost;
            subtitle = textTryAgain;
            scoreLabel = textFinalScore;
            titleInk = float3(1.0f, 0.42f, 0.32f);
        } else if (phase == phaseVictory) {
            title = textRidgeConquered;
            subtitle = textPlayAgain;
            scoreLabel = textFinalScore;
        }
        float bigCell = 7.0f * ui;
        float2 titleOrigin = float2(centerX - 0.5f * textWidth(title, bigCell),
            0.34f * resolution.y);
        paintText(color, pixel, titleOrigin, bigCell, title, titleInk, 1.0f);
        float scoreCell = 3.6f * ui;
        float scoreLabelWidth = textWidth(scoreLabel, scoreCell) + 2.0f * scoreCell;
        float scoreWidth = scoreLabelWidth + numberWidth(game.score.x, scoreCell);
        float2 scoreOrigin = float2(centerX - 0.5f * scoreWidth,
            titleOrigin.y + 80.0f * ui);
        paintText(color, pixel, scoreOrigin, scoreCell, scoreLabel, muted, 1.0f);
        paintNumber(color, pixel, scoreOrigin + float2(scoreLabelWidth, 0.0f),
            scoreCell, game.score.x, gold, 1.0f);
        float subtitleCell = 3.0f * ui;
        float2 subtitleOrigin = float2(
            centerX - 0.5f * textWidth(subtitle, subtitleCell),
            scoreOrigin.y + 56.0f * ui);
        float ready = game.aim.w > 0.6f ? 0.7f + 0.3f * sin(time * 4.0f) : 0.0f;
        paintText(color, pixel, subtitleOrigin, subtitleCell, subtitle, ink,
            ready);
    }

    // A marker on the top edge while a shell is above the frame.
    if (game.flight.z > 0.5f) {
        float2 shellPoint = shellPosition(game.shell, game.flight.w,
            game.flight.x);
        if (shellPoint.y > worldHeight) {
            float2 top = worldToPixel(float2(shellPoint.x, worldHeight),
                resolution);
            float2 tipPixel = float2(top.x, max(top.y, 0.0f) + 6.0f * ui);
            float2 q = float2(abs(pixel.x - tipPixel.x), pixel.y - tipPixel.y);
            float size = 14.0f * ui;
            float marker = max(-q.y, max(q.y - size, q.x - q.y * 0.6f));
            color = mix(color, float3(1.0f, 0.75f, 0.3f),
                clamp(0.5f - marker, 0.0f, 1.0f));
        }
    }

    // Trackpad crosshair; bright while it is the player's turn.
    float2 aimPixel = clamp(u.pointer.xy, float2(0.0f), float2(1.0f)) * resolution;
    float2 offset = abs(pixel - aimPixel);
    float ringDistance = abs(length(pixel - aimPixel) - 11.0f * ui) - 1.3f * ui;
    float horizontal = max(offset.y - 1.0f * ui, abs(offset.x - 11.0f * ui) - 6.0f * ui);
    float vertical = max(offset.x - 1.0f * ui, abs(offset.y - 11.0f * ui) - 6.0f * ui);
    float mark = min(ringDistance, min(horizontal, vertical));
    float strength = phase == phaseAim ? 1.0f : 0.35f;
    color = mix(color, float3(0.0f), 0.5f * strength
        * clamp(0.5f - (mark - 1.5f * ui), 0.0f, 1.0f));
    color = mix(color, float3(1.0f, 0.95f, 0.8f),
        strength * clamp(0.5f - mark, 0.0f, 1.0f));
}

// Linear scene color to display sRGB with a soft shoulder above 0.8.
float3 toDisplay(float3 linearColor) {
    float3 value = max(linearColor, float3(0.0f));
    float3 rolled = 0.8f + 0.2f * (1.0f - exp(-(value - 0.8f) / 0.2f));
    float3 mapped = select(value, rolled, value > 0.8f);
    return select(1.055f * pow(mapped, float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
}

fragment float4 duelFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> soilTexture [[texture(1)]],
    texture2d<float> grassTexture [[texture(2)]],
    texture2d<float> rockTexture [[texture(3)]],
    texture2d<float> armorTexture [[texture(4)]],
    texture2d<float> skyTexture [[texture(5)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 pixel = in.uv * resolution;
    float time = u.resolutionTime.z;
    float ui = min(resolution.x / 1280.0f, resolution.y / 800.0f);
    float pixelSize = 1.0f / worldScale(resolution);
    float2 shake = game.feedback.x * 7.0f * ui
        * float2(sin(time * 97.0f), cos(time * 83.0f));
    float2 world = pixelToWorld(pixel + shake, resolution);

    // Generated dusk sky with two hazy procedural ridges in front of it.
    float3 color = backdropAlbedo(skyTexture, in.uv) * 0.95f;
    float farRidge = 72.0f + 12.0f * sin(world.x * 0.031f + 1.7f)
        + 7.0f * sin(world.x * 0.083f + 0.4f) + 3.0f * sin(world.x * 0.21f);
    color = mix(color, mix(color, float3(0.09f, 0.11f, 0.19f), 0.55f),
        clamp((farRidge - world.y) / pixelSize + 0.5f, 0.0f, 1.0f));
    float nearRidge = 50.0f + 10.0f * sin(world.x * 0.05f + 2.3f)
        + 5.0f * sin(world.x * 0.13f + 0.7f);
    color = mix(color, mix(color, float3(0.06f, 0.075f, 0.12f), 0.75f),
        clamp((nearRidge - world.y) / pixelSize + 0.5f, 0.0f, 1.0f));

    // Destructible ground.
    float2 terrain = terrainAt(game.heights, world.x);
    float edge = (terrain.x - world.y) / sqrt(1.0f + terrain.y * terrain.y);
    float ground = clamp(edge / pixelSize + 0.5f, 0.0f, 1.0f);
    if (ground > 0.0f) {
        float untouched = heightAt(game.pristine, world.x);
        float3 earth = shadeTerrain(world, terrain, untouched, soilTexture,
            grassTexture, rockTexture, game.blast);
        color = mix(color, earth, ground);
    }
    for (uint index = 0u; index < 2u; ++index) {
        Tank tank = game.tanks[index];
        float2 offset = (world - tank.body.xy) / float2(10.0f, 2.6f);
        float contact = 1.0f - smoothstep(0.5f, 1.2f, length(offset));
        color *= 1.0f - 0.45f * contact * ground;
    }

    Tank player = game.tanks[0];
    Tank enemy = game.tanks[1];
    paintTank(color, world, pixelSize, player, false, armorTexture, time);
    paintTank(color, world, pixelSize, enemy, true, armorTexture, time);
    paintWreckSmoke(color, world, player, time);
    paintWreckSmoke(color, world, enemy, time);
    paintAimGuide(color, world, pixelSize, game, time);
    paintShell(color, world, pixelSize, game);
    paintBlast(color, world, pixelSize, game.blast);

    float vignette = 1.0f - 0.25f * smoothstep(0.35f, 0.85f,
        length(in.uv - 0.5f));
    float3 display = toDisplay(color * vignette);
    paintHud(display, pixel, resolution, game, u, time);
    return float4(clamp(display, float3(0.0f), float3(1.0f)), 1.0f);
}

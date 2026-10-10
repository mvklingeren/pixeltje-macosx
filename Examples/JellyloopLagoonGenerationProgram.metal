#include <metal_stdlib>
using namespace metal;

// Jellyloop Lagoon: a lasso-drawing arcade game for the generic GPU Program
// node, set in a goofy cartoon seabed town.
//
// Bixby, a cheerful seahorse, runs jelly orders for the Soggy Bun diner in
// Fizzwater Flats. The Trackpad pointer steers Bixby's bubble wand, which
// leaves a trail of soap bubbles. Whenever the trail crosses itself, the
// enclosed area becomes a loop: every swimming jellyfish inside is wrapped in
// a bubble and floats up to the diner. Catching several jellies in one loop
// multiplies their points (combo). Each shift posts an order ticket (pink,
// blue and lime jellies) and a clock; golden jellies are a bonus worth extra
// points and five extra seconds. Grumbles, spiky pufferfish, pop any trail
// they touch, cost a heart when they bump Bixby, and burst a loop (and cost a
// heart) when they are inside it. Action/Space toots the bubble horn: nearby
// Grumbles are pushed away and stunned for a moment (a few toots per shift).
// Fill all four orders to win; running out of time or hearts lets you retry
// the shift.
//
// All game state lives in one GPU buffer. Single-thread kernels advance it once
// per Loop call; the fragment pass only reads it and draws the whole scene in
// 2D with signed distance shapes, generated textures and a 5 x 7 pixel font.
//
// World space: one unit is the screen height. x runs 0..aspect from left to
// right, y runs 0..1 from the top edge to the bottom edge (Trackpad space
// scaled by the aspect ratio in x).
//
// Generated textures from the Asset Cache, sampled as sRGB albedo:
//   texture(1) asset0 lagoon backdrop (FLUX.2 Klein 4B, 1024 x 1024),
//   texture(2) asset1 seabed sand, texture(3) asset2 jelly skin,
//   texture(4) asset3 fruit skin (pear and lemon houses),
//   texture(5) asset4 pastel pebbles (pebble tower and coral),
//   texture(6) asset5 striped shell (the Soggy Bun diner); SDXS 512 each.
//
// Parameters, in declared order: shiftTimeScale (1 normal, 0.5..3),
// startingHearts (1..9, default 3), tootsPerShift (0..9, default 3),
// firstShift (1..4). When all four are zero the defaults apply.

constant int trailCapacity = 96;
constant int jellyCount = 12;
constant int grumbleCapacity = 4;
constant uint shiftCount = 4u;

constant uint phaseTitle = 0u;
constant uint phaseBriefing = 1u;  // the order ticket is shown, the clock waits
constant uint phasePlaying = 2u;
constant uint phaseCleared = 3u;
constant uint phaseGameOver = 4u;
constant uint phaseVictory = 5u;

constant uint jellySwim = 0u;
constant uint jellyCaught = 1u;    // wrapped in a bubble, floating up
constant uint jellyWaiting = 2u;   // gone until it respawns

constant uint kindPink = 0u;
constant uint kindBlue = 1u;
constant uint kindLime = 2u;
constant uint kindGold = 3u;

// Rules, in screen-height units and seconds.
constant float waterTop = 0.17f;
constant float waterBottom = 0.66f;
constant float trailSpacing = 0.016f;
constant float trailLife = 3.0f;
constant float minLoopArea = 0.0030f;
constant float wandFollow = 12.0f;
constant float wandMaxSpeed = 1.9f;
constant float jellySize = 0.034f;
constant float grumbleRadius = 0.036f;
constant float grumblePuffRadius = 0.060f;
constant float bumpReach = 0.016f;
constant float tootRadius = 0.38f;
constant float briefingSeconds = 2.6f;
constant float hintReach = 0.075f;
constant float snapReach = 0.024f;   // touching an older bubble closes the loop

// Order ticket per shift: pink, blue, lime, unused.
constant uint shiftQuota[16] = {
    4u, 3u, 0u, 0u,
    5u, 4u, 3u, 0u,
    6u, 6u, 5u, 0u,
    8u, 7u, 7u, 0u};
constant float shiftSeconds[4] = {90.0f, 100.0f, 110.0f, 120.0f};
constant uint shiftGrumbles[4] = {1u, 2u, 3u, 4u};

// Must match the engine's slot-0 uniform layout exactly (7 x 16 = 112 bytes).
struct ProgramUniforms {
    float4 resolutionTime;
    uint4 frameSeed;
    float4 parameters0;
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;
};

struct Jelly {
    float4 body;   // x, y, velocity x, velocity y
    float4 anim;   // pulse phase 0..1, pulses per second, colour shimmer seed, seconds in state
    uint4 info;    // kind (pink, blue, lime, gold), state (swim, caught, waiting), unused, unused
};

struct Grumble {
    float4 body;   // x, y, velocity x, velocity y
    float4 anim;   // puff seconds, stun seconds, cruising speed, active (0 or 1)
};

// Buffer layout with Metal alignment (float4/uint4 = 16 bytes, align 16):
//   wand .. hint          8 * 16 =  128 bytes at offset    0
//   flow .. trailInfo     8 * 16 =  128 bytes at offset  128
//   trail[96]            96 * 16 = 1536 bytes at offset  256
//   jellies[12]          12 * 48 =  576 bytes at offset 1792 (Jelly = 3 * 16)
//   grumbles[4]           4 * 32 =  128 bytes at offset 2368 (Grumble = 2 * 16)
//   sizeof(GameState)             = 2496 bytes (a multiple of 16).
// The workflow declares a 4096-byte "game" buffer, which covers it.
struct GameState {
    float4 wand;       // x, y, velocity x, velocity y
    float4 control;    // last action count, facing (-1 left .. 1 right), seconds in phase, hurt seconds
    float4 clock;      // shift seconds left, notice seconds, toot seconds, hurry warned (0 or 1)
    float4 loopFx;     // last loop centre x, y, mean radius, seconds since it closed
    float4 popFx;      // x, y, seconds since the pop, kind (0 trail pop, 1 loop burst, 2 bump)
    float4 tootFx;     // x, y of the last toot, unused, unused
    float4 trailBox;   // trail bounds min x, min y, max x, max y (fragment gate)
    float4 hint;       // nearest older trail bubble x, y, strength (0 = none), trail index
    uint4 flow;        // phase, shift (0-based), hearts, toots left
    uint4 score;       // score, best, score at shift start, last time bonus
    uint4 quota;       // pink, blue, lime ordered this shift, unused
    uint4 caught;      // pink, blue, lime, gold caught this shift
    uint4 notice;      // text, number, game over reason text, unused
    uint4 loopInfo;    // points of the last loop, jellies in it, unused, unused
    uint4 stats;       // jellies caught this game, best combo, loops closed, unused
    uint4 trailInfo;   // trail point count, random state, unused, unused
    float4 trail[96];  // x, y, birth time, unused; [0] is the oldest
    Jelly jellies[12];
    Grumble grumbles[4];
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
constant uchar textPool[684] = {
    74, 69, 76, 76, 89, 76, 79, 79, 80, 32, 76, 65, 71, 79, 79, 78,
    72, 69, 76, 80, 32, 66, 73, 88, 66, 89, 32, 84, 72, 69, 32, 83,
    69, 65, 72, 79, 82, 83, 69, 32, 70, 73, 76, 76, 32, 84, 72, 69,
    32, 74, 69, 76, 76, 89, 32, 79, 82, 68, 69, 82, 83, 65, 84, 32,
    84, 72, 69, 32, 83, 79, 71, 71, 89, 32, 66, 85, 78, 32, 68, 73,
    78, 69, 82, 32, 73, 78, 32, 70, 73, 90, 90, 87, 65, 84, 69, 82,
    32, 70, 76, 65, 84, 83, 68, 82, 65, 71, 32, 84, 79, 32, 83, 87,
    73, 77, 32, 45, 32, 89, 79, 85, 82, 32, 87, 65, 78, 68, 32, 76,
    69, 65, 86, 69, 83, 32, 65, 32, 66, 85, 66, 66, 76, 69, 32, 84,
    82, 65, 73, 76, 67, 82, 79, 83, 83, 32, 89, 79, 85, 82, 32, 84,
    82, 65, 73, 76, 32, 84, 79, 32, 67, 76, 79, 83, 69, 32, 65, 32,
    76, 79, 79, 80, 32, 65, 82, 79, 85, 78, 68, 32, 74, 69, 76, 76,
    73, 69, 83, 77, 79, 82, 69, 32, 74, 69, 76, 76, 73, 69, 83, 32,
    73, 78, 32, 79, 78, 69, 32, 76, 79, 79, 80, 32, 77, 69, 65, 78,
    83, 32, 65, 32, 66, 73, 71, 71, 69, 82, 32, 67, 79, 77, 66, 79,
    75, 69, 69, 80, 32, 71, 82, 85, 77, 66, 76, 69, 83, 32, 79, 85,
    84, 32, 45, 32, 83, 80, 65, 67, 69, 32, 84, 79, 79, 84, 83, 32,
    84, 72, 69, 77, 32, 65, 87, 65, 89, 80, 82, 69, 83, 83, 32, 83,
    80, 65, 67, 69, 32, 84, 79, 32, 79, 80, 69, 78, 32, 84, 72, 69,
    32, 68, 73, 78, 69, 82, 83, 72, 73, 70, 84, 79, 82, 68, 69, 82,
    32, 85, 80, 33, 83, 67, 79, 82, 69, 84, 73, 77, 69, 66, 69, 83,
    84, 78, 73, 67, 69, 32, 76, 79, 79, 80, 33, 67, 79, 77, 66, 79,
    32, 88, 71, 79, 76, 68, 69, 78, 32, 74, 69, 76, 76, 89, 32, 43,
    53, 32, 83, 69, 67, 80, 79, 80, 33, 79, 85, 67, 72, 33, 71, 82,
    85, 77, 66, 76, 69, 32, 73, 78, 32, 84, 72, 69, 32, 76, 79, 79,
    80, 33, 84, 79, 79, 84, 33, 78, 79, 32, 84, 79, 79, 84, 83, 32,
    76, 69, 70, 84, 72, 85, 82, 82, 89, 32, 85, 80, 33, 79, 82, 68,
    69, 82, 32, 67, 79, 77, 80, 76, 69, 84, 69, 33, 84, 73, 77, 69,
    32, 66, 79, 78, 85, 83, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67,
    69, 32, 70, 79, 82, 32, 84, 72, 69, 32, 78, 69, 88, 84, 32, 83,
    72, 73, 70, 84, 79, 85, 84, 32, 79, 70, 32, 84, 73, 77, 69, 79,
    85, 84, 32, 79, 70, 32, 72, 69, 65, 82, 84, 83, 80, 82, 69, 83,
    83, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 82, 69, 84, 82, 89,
    32, 84, 72, 69, 32, 83, 72, 73, 70, 84, 65, 76, 76, 32, 79, 82,
    68, 69, 82, 83, 32, 83, 69, 82, 86, 69, 68, 33, 70, 73, 90, 90,
    87, 65, 84, 69, 82, 32, 70, 76, 65, 84, 83, 32, 73, 83, 32, 87,
    69, 76, 76, 32, 70, 69, 68, 70, 73, 78, 65, 76, 32, 83, 67, 79,
    82, 69, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 84, 79,
    32, 80, 76, 65, 89, 32, 65, 71, 65, 73, 78, 83, 79, 71, 71, 89,
    32, 66, 85, 78, 43, 47, 74, 69, 76, 76, 73, 69, 83, 66, 69, 83,
    84, 32, 67, 79, 77, 66, 79, 68, 82, 65, 87, 32, 76, 79, 79, 80,
    83, 32, 65, 82, 79, 85, 78, 68, 32, 84, 72, 69, 32, 79, 82, 68,
    69, 82, 69, 68, 32, 74, 69, 76, 76, 73, 69, 83,
};
constant int textRanges[76] = {
    0, 16,  // JELLYLOOP LAGOON
    16, 45,  // HELP BIXBY THE SEAHORSE FILL THE JELLY ORDERS
    61, 41,  // AT THE SOGGY BUN DINER IN FIZZWATER FLATS
    102, 46,  // DRAG TO SWIM - YOUR WAND LEAVES A BUBBLE TRAIL
    148, 47,  // CROSS YOUR TRAIL TO CLOSE A LOOP AROUND JELLIES
    195, 45,  // MORE JELLIES IN ONE LOOP MEANS A BIGGER COMBO
    240, 41,  // KEEP GRUMBLES OUT - SPACE TOOTS THEM AWAY
    281, 29,  // PRESS SPACE TO OPEN THE DINER
    310, 5,  // SHIFT
    315, 9,  // ORDER UP!
    324, 5,  // SCORE
    329, 4,  // TIME
    333, 4,  // BEST
    337, 10,  // NICE LOOP!
    347, 7,  // COMBO X
    354, 19,  // GOLDEN JELLY +5 SEC
    373, 4,  // POP!
    377, 5,  // OUCH!
    382, 20,  // GRUMBLE IN THE LOOP!
    402, 5,  // TOOT!
    407, 13,  // NO TOOTS LEFT
    420, 9,  // HURRY UP!
    429, 15,  // ORDER COMPLETE!
    444, 10,  // TIME BONUS
    454, 30,  // PRESS SPACE FOR THE NEXT SHIFT
    484, 11,  // OUT OF TIME
    495, 13,  // OUT OF HEARTS
    508, 30,  // PRESS SPACE TO RETRY THE SHIFT
    538, 18,  // ALL ORDERS SERVED!
    556, 27,  // FIZZWATER FLATS IS WELL FED
    583, 11,  // FINAL SCORE
    594, 25,  // PRESS SPACE TO PLAY AGAIN
    619, 9,  // SOGGY BUN
    628, 1,  // +
    629, 1,  // /
    630, 7,  // JELLIES
    637, 10,  // BEST COMBO
    647, 37,  // DRAW LOOPS AROUND THE ORDERED JELLIES
};
constant int textTitle = 0;
constant int textIntro1 = 1;
constant int textIntro2 = 2;
constant int textIntro3 = 3;
constant int textIntro4 = 4;
constant int textIntro5 = 5;
constant int textIntro6 = 6;
constant int textPressStart = 7;
constant int textShift = 8;
constant int textOrderUp = 9;
constant int textScore = 10;
constant int textTime = 11;
constant int textBest = 12;
constant int textNiceLoop = 13;
constant int textCombo = 14;
constant int textGolden = 15;
constant int textPop = 16;
constant int textOuch = 17;
constant int textGrumbleLoop = 18;
constant int textToot = 19;
constant int textNoToots = 20;
constant int textHurry = 21;
constant int textOrderComplete = 22;
constant int textTimeBonus = 23;
constant int textNextShift = 24;
constant int textOutOfTime = 25;
constant int textOutOfHearts = 26;
constant int textRetry = 27;
constant int textAllServed = 28;
constant int textTownFed = 29;
constant int textFinalScore = 30;
constant int textPlayAgain = 31;
constant int textSign = 32;
constant int textPlus = 33;
constant int textSlash = 34;
constant int textJellies = 35;
constant int textBestCombo = 36;
constant int textGetReady = 37;

// ---------------------------------------------------------------------------
// Settings and helpers

struct Settings {
    float timeScale;
    uint hearts;
    uint toots;
    uint firstShift;
};

Settings readSettings(constant ProgramUniforms &u) {
    float4 p = u.parameters0;
    Settings settings;
    settings.timeScale = 1.0f;
    settings.hearts = 3u;
    settings.toots = 3u;
    settings.firstShift = 0u;
    if (all(p == float4(0.0f))) return settings;
    settings.timeScale = p.x > 0.0f ? clamp(p.x, 0.5f, 3.0f) : 1.0f;
    settings.hearts = uint(clamp(round(p.y), 1.0f, 9.0f));
    settings.toots = uint(clamp(round(p.z), 0.0f, 9.0f));
    settings.firstShift = uint(clamp(round(p.w), 1.0f, 4.0f)) - 1u;
    return settings;
}

float aspectOf(constant ProgramUniforms &u) {
    return u.resolutionTime.x / max(u.resolutionTime.y, 1.0f);
}

uint nextRandom(device GameState &game) {
    uint state = game.trailInfo.y * 747796405u + 2891336453u;
    game.trailInfo.y = state;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float random01(device GameState &game) {
    return float(nextRandom(game) >> 8u) * (1.0f / 16777216.0f);
}

float segmentDistance(float2 point, float2 a, float2 b) {
    float2 pa = point - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0000001f), 0.0f, 1.0f);
    return length(pa - ba * h);
}

// Proper crossing of segment p0-p1 with segment q0-q1; t is the position on p.
bool segmentsCross(float2 p0, float2 p1, float2 q0, float2 q1, thread float &t) {
    float2 r = p1 - p0;
    float2 s = q1 - q0;
    float denominator = r.x * s.y - r.y * s.x;
    if (abs(denominator) < 1.0e-9f) return false;
    float2 offset = q0 - p0;
    float along = (offset.x * s.y - offset.y * s.x) / denominator;
    float across = (offset.x * r.y - offset.y * r.x) / denominator;
    if (along < 0.0f || along > 1.0f || across < 0.0f || across > 1.0f) return false;
    t = along;
    return true;
}

void showNotice(device GameState &game, int text, uint number) {
    game.notice.x = uint(text);
    game.notice.y = number;
    game.clock.y = 0.0f;
}

void clearTrail(device GameState &game) {
    game.trailInfo.x = 0u;
    game.hint = float4(0.0f);
}

void dropOldest(device GameState &game, int drop) {
    int count = int(game.trailInfo.x);
    drop = min(drop, count);
    for (int index = 0; index + drop < count; ++index) {
        game.trail[index] = game.trail[index + drop];
    }
    game.trailInfo.x = uint(count - drop);
}

uint4 addKind(uint4 counts, uint kind) {
    return counts + uint4(kind == 0u ? 1u : 0u, kind == 1u ? 1u : 0u,
        kind == 2u ? 1u : 0u, kind == 3u ? 1u : 0u);
}

bool orderComplete(device const GameState &game) {
    return game.caught.x >= game.quota.x && game.caught.y >= game.quota.y
        && game.caught.z >= game.quota.z;
}

// Favour colours the current order still needs, so every order stays reachable.
uint chooseKind(device GameState &game) {
    if (random01(game) < 0.07f) return kindGold;
    uint4 quota = game.quota;
    uint4 caught = game.caught;
    uint needed[3];
    uint neededCount = 0u;
    if (caught.x < quota.x) { needed[neededCount] = kindPink; neededCount += 1u; }
    if (caught.y < quota.y) { needed[neededCount] = kindBlue; neededCount += 1u; }
    if (caught.z < quota.z) { needed[neededCount] = kindLime; neededCount += 1u; }
    if (neededCount > 0u && random01(game) < 0.7f) {
        uint pick = min(uint(random01(game) * float(neededCount)), neededCount - 1u);
        return needed[pick];
    }
    return min(uint(random01(game) * 3.0f), 2u);
}

void spawnJelly(device GameState &game, int index, float aspect) {
    float2 at = float2(0.5f * aspect, 0.4f);
    for (int attempt = 0; attempt < 8; ++attempt) {
        at = float2(mix(0.10f, aspect - 0.10f, random01(game)),
            mix(waterTop + 0.03f, waterBottom - 0.03f, random01(game)));
        if (distance(at, game.wand.xy) > 0.24f) break;
    }
    uint kind = chooseKind(game);
    device Jelly &jelly = game.jellies[index];
    jelly.body = float4(at, (random01(game) - 0.5f) * 0.06f, 0.0f);
    jelly.anim = float4(random01(game), mix(0.75f, 1.05f, random01(game)),
        random01(game), 0.0f);
    if (kind == kindGold) jelly.anim.y = 1.45f;
    jelly.info = uint4(kind, jellySwim, 0u, 0u);
}

void placeGrumble(device GameState &game, int index, float aspect, bool active) {
    float2 at = float2(0.2f, 0.3f);
    for (int attempt = 0; attempt < 10; ++attempt) {
        at = float2(mix(0.12f, aspect - 0.12f, random01(game)),
            mix(waterTop + 0.05f, waterBottom - 0.05f, random01(game)));
        if (distance(at, game.wand.xy) > 0.40f) break;
    }
    float angle = random01(game) * 6.2831853f;
    float speed = mix(0.065f, 0.095f, random01(game)) * (1.0f + 0.08f * float(game.flow.y));
    device Grumble &grumble = game.grumbles[index];
    grumble.body = float4(at, cos(angle) * speed, sin(angle) * speed);
    grumble.anim = float4(0.0f, 0.0f, speed, active ? 1.0f : 0.0f);
}

void resetEffects(device GameState &game) {
    game.loopFx = float4(0.0f, 0.0f, 0.0f, 99.0f);
    game.popFx = float4(0.0f, 0.0f, 99.0f, 0.0f);
    game.tootFx = float4(0.0f);
    game.loopInfo = uint4(0u);
    game.clock.y = 99.0f;
    game.clock.z = 99.0f;
    clearTrail(game);
}

void showTitle(device GameState &game, constant ProgramUniforms &u) {
    float aspect = aspectOf(u);
    game.flow = uint4(phaseTitle, 0u, 0u, 0u);
    game.quota = uint4(0u);
    game.caught = uint4(0u);
    game.clock = float4(0.0f);
    game.control.z = 0.0f;
    game.control.w = 0.0f;
    resetEffects(game);
    for (int index = 0; index < jellyCount; ++index) {
        spawnJelly(game, index, aspect);
        game.jellies[index].anim.w = 1.0f;
    }
    for (int index = 0; index < grumbleCapacity; ++index) {
        placeGrumble(game, index, aspect, index == 0);
    }
}

void startShift(device GameState &game, constant ProgramUniforms &u, uint shift) {
    Settings settings = readSettings(u);
    float aspect = aspectOf(u);
    shift = min(shift, shiftCount - 1u);
    game.flow = uint4(phaseBriefing, shift, game.flow.z, settings.toots);
    game.quota = uint4(shiftQuota[shift * 4u], shiftQuota[shift * 4u + 1u],
        shiftQuota[shift * 4u + 2u], 0u);
    game.caught = uint4(0u);
    game.clock = float4(shiftSeconds[shift] * settings.timeScale, 0.0f, 0.0f, 0.0f);
    game.control.z = 0.0f;
    game.control.w = 0.0f;
    game.score.z = game.score.x;
    resetEffects(game);
    for (int index = 0; index < jellyCount; ++index) spawnJelly(game, index, aspect);
    uint active = shiftGrumbles[shift];
    for (int index = 0; index < grumbleCapacity; ++index) {
        placeGrumble(game, index, aspect, uint(index) < active);
    }
}

void startGame(device GameState &game, constant ProgramUniforms &u) {
    Settings settings = readSettings(u);
    game.score.x = 0u;
    game.score.w = 0u;
    game.flow.z = settings.hearts;
    game.stats = uint4(0u);
    startShift(game, u, settings.firstShift);
}

void retryShift(device GameState &game, constant ProgramUniforms &u) {
    Settings settings = readSettings(u);
    game.score.x = game.score.z;
    game.flow.z = settings.hearts;
    startShift(game, u, game.flow.y);
}

void finishShift(device GameState &game) {
    uint bonus = 100u + 5u * uint(max(game.clock.x, 0.0f));
    game.score.x += bonus;
    game.score.w = bonus;
    game.score.y = max(game.score.y, game.score.x);
    if (game.flow.y + 1u >= shiftCount) game.flow.x = phaseVictory;
    else game.flow.x = phaseCleared;
    game.control.z = 0.0f;
    clearTrail(game);
}

void loseShift(device GameState &game, int reason) {
    game.flow.x = phaseGameOver;
    game.notice.z = uint(reason);
    game.control.z = 0.0f;
    game.score.y = max(game.score.y, game.score.x);
    clearTrail(game);
}

void hurt(device GameState &game, int text) {
    game.flow.z = game.flow.z > 0u ? game.flow.z - 1u : 0u;
    game.control.w = 2.0f;
    clearTrail(game);
    showNotice(game, text, 0u);
    if (game.flow.z == 0u) loseShift(game, textOutOfHearts);
}

// ---------------------------------------------------------------------------
// Loops

// The loop polygon is the crossing point followed by trail[first..last].
bool insideLoop(device const GameState &game, float2 point, float2 start,
    int first, int last) {
    bool inside = false;
    float2 a = start;
    for (int index = first; index <= last + 1; ++index) {
        float2 b = index <= last ? game.trail[index].xy : start;
        if ((a.y > point.y) != (b.y > point.y)) {
            float crossX = a.x + (b.x - a.x) * (point.y - a.y) / (b.y - a.y);
            if (point.x < crossX) inside = !inside;
        }
        a = b;
    }
    return inside;
}

float loopArea(device const GameState &game, float2 start, int first, int last) {
    float twiceArea = 0.0f;
    float2 a = start;
    for (int index = first; index <= last + 1; ++index) {
        float2 b = index <= last ? game.trail[index].xy : start;
        twiceArea += a.x * b.y - b.x * a.y;
        a = b;
    }
    return 0.5f * twiceArea;
}

void resolveLoop(device GameState &game, float2 start, int first, int last) {
    float2 center = start;
    float corners = 1.0f;
    for (int index = first; index <= last; ++index) {
        center += game.trail[index].xy;
        corners += 1.0f;
    }
    center /= corners;
    float radius = distance(start, center);
    for (int index = first; index <= last; ++index) {
        radius += distance(game.trail[index].xy, center);
    }
    radius /= corners;
    game.loopFx = float4(center, radius, 0.0f);
    game.loopInfo = uint4(0u);
    if (game.flow.x != phasePlaying) return;
    game.stats.z += 1u;

    // A Grumble inside the loop bursts it before anything is caught.
    for (int index = 0; index < grumbleCapacity; ++index) {
        device Grumble &grumble = game.grumbles[index];
        if (grumble.anim.w < 0.5f || grumble.anim.y > 0.0f) continue;
        if (insideLoop(game, grumble.body.xy, start, first, last)) {
            grumble.anim.x = 1.4f;
            game.popFx = float4(grumble.body.xy, 0.0f, 1.0f);
            game.loopFx.w = 99.0f;
            hurt(game, textGrumbleLoop);
            return;
        }
    }

    uint4 caught = game.caught;
    uint count = 0u;
    uint base = 0u;
    bool golden = false;
    for (int index = 0; index < jellyCount; ++index) {
        device Jelly &jelly = game.jellies[index];
        if (jelly.info.y != jellySwim || jelly.anim.w < 0.2f) continue;
        if (!insideLoop(game, jelly.body.xy, start, first, last)) continue;
        uint kind = jelly.info.x;
        jelly.info.y = jellyCaught;
        jelly.anim.w = 0.0f;
        jelly.body.zw = float2(0.0f);
        caught = addKind(caught, kind);
        count += 1u;
        base += kind == kindGold ? 50u : 10u;
        if (kind == kindGold) golden = true;
    }
    game.caught = caught;
    if (count == 0u) return;
    uint points = base * count;
    game.score.x += points;
    game.score.y = max(game.score.y, game.score.x);
    game.loopInfo = uint4(points, count, 0u, 0u);
    game.stats.x += count;
    game.stats.y = max(game.stats.y, count);
    if (golden) {
        game.clock.x += 5.0f;
        showNotice(game, textGolden, 0u);
    } else if (count >= 2u) {
        showNotice(game, textCombo, count);
    } else {
        showNotice(game, textNiceLoop, 0u);
    }
    if (orderComplete(game)) finishShift(game);
}

// Appends one bubble; returns true when it closed a loop (the trail restarts).
bool addTrailPoint(device GameState &game, float2 point, float time) {
    int count = int(game.trailInfo.x);
    float2 last = game.trail[count - 1].xy;
    int hitIndex = -1;
    float hitAlong = 0.0f;
    // Segment index joins trail[index] and trail[index + 1]; the newest
    // segment shares its end point with the new one and is skipped.
    for (int index = 0; index + 2 < count; ++index) {
        float along = 0.0f;
        if (segmentsCross(last, point, game.trail[index].xy,
            game.trail[index + 1].xy, along)) {
            hitIndex = index;
            hitAlong = along;
        }
    }
    if (hitIndex >= 0) {
        float2 crossing = mix(last, point, hitAlong);
        int first = hitIndex + 1;
        if (abs(loopArea(game, crossing, first, count - 1)) >= minLoopArea) {
            resolveLoop(game, crossing, first, count - 1);
        }
        game.trail[0] = float4(point, time, 0.0f);
        game.trailInfo.x = 1u;
        return true;
    }
    if (count >= trailCapacity) {
        dropOldest(game, 1);
        count -= 1;
    }
    game.trail[count] = float4(point, time, 0.0f);
    game.trailInfo.x = uint(count + 1);
    return false;
}

void updateTrail(device GameState &game, float time) {
    int count = int(game.trailInfo.x);
    int expired = 0;
    for (int index = 0; index < count; ++index) {
        if (time - game.trail[index].z <= trailLife) break;
        expired = index + 1;
    }
    if (expired > 0) dropOldest(game, expired);
    float2 wand = game.wand.xy;
    if (game.trailInfo.x == 0u) {
        game.trail[0] = float4(wand, time, 0.0f);
        game.trailInfo.x = 1u;
    }
    bool closed = false;
    for (int added = 0; added < 8; ++added) {
        float2 last = game.trail[int(game.trailInfo.x) - 1].xy;
        float2 delta = wand - last;
        float reach = length(delta);
        if (reach < trailSpacing) break;
        if (addTrailPoint(game, last + delta * (trailSpacing / reach), time)) {
            closed = true;
            break;
        }
    }

    // The nearest older bubble: a hint ring, and touching it closes the loop
    // even when the wand stops just short of an exact crossing.
    count = int(game.trailInfo.x);
    float bestReach = hintReach;
    int bestIndex = -1;
    for (int index = 0; index + 10 < count; ++index) {
        float reach = distance(game.trail[index].xy, wand);
        if (reach < bestReach) {
            bestReach = reach;
            bestIndex = index;
        }
    }
    if (!closed && bestIndex >= 0 && bestReach < snapReach) {
        float2 start = game.trail[bestIndex].xy;
        if (abs(loopArea(game, start, bestIndex + 1, count - 1)) >= minLoopArea) {
            resolveLoop(game, start, bestIndex + 1, count - 1);
        }
        game.trail[0] = float4(wand, time, 0.0f);
        game.trailInfo.x = 1u;
        count = 1;
        bestIndex = -1;
    }

    // Bounds for the fragment pass.
    float2 lower = wand;
    float2 upper = wand;
    for (int index = 0; index < count; ++index) {
        lower = min(lower, game.trail[index].xy);
        upper = max(upper, game.trail[index].xy);
    }
    game.trailBox = float4(lower - 0.03f, upper + 0.03f);
    game.hint = float4(0.0f);
    if (bestIndex >= 0) {
        game.hint = float4(game.trail[bestIndex].xy, 1.0f - bestReach / hintReach,
            float(bestIndex));
    }
}

// ---------------------------------------------------------------------------
// Creatures

void updateJellies(device GameState &game, float dt, float aspect, float time) {
    for (int index = 0; index < jellyCount; ++index) {
        device Jelly &jelly = game.jellies[index];
        jelly.anim.w += dt;
        if (jelly.info.y == jellyCaught) {
            jelly.body.y -= 0.32f * dt;
            jelly.body.x += 0.04f * sin(time * 5.0f + float(index)) * dt;
            if (jelly.anim.w > 1.15f) {
                jelly.info.y = jellyWaiting;
                jelly.anim.w = 0.0f;
            }
            continue;
        }
        if (jelly.info.y == jellyWaiting) {
            if (jelly.anim.w > 1.0f) spawnJelly(game, index, aspect);
            continue;
        }
        float4 body = jelly.body;
        float pulse = jelly.anim.x + dt * jelly.anim.y;
        if (pulse >= 1.0f) {
            pulse -= 1.0f;
            body.w -= mix(0.09f, 0.15f, random01(game));
            body.z += (random01(game) - 0.5f) * 0.10f;
        }
        jelly.anim.x = pulse;
        body.w += 0.10f * dt;
        if (jelly.info.x == kindGold) {
            // Golden jellies are shy and drift away from the wand.
            float2 away = body.xy - game.wand.xy;
            float reach = length(away);
            if (reach < 0.16f && reach > 0.0001f) {
                body.zw += away / reach * (0.6f * (1.0f - reach / 0.16f)) * dt;
            }
        }
        body.zw *= exp(-1.7f * dt);
        body.xy += body.zw * dt;
        if (body.y < waterTop) { body.y = waterTop; body.w = abs(body.w) * 0.4f; }
        if (body.y > waterBottom) { body.y = waterBottom; body.w = -abs(body.w) * 0.4f - 0.02f; }
        if (body.x < 0.06f) { body.x = 0.06f; body.z = abs(body.z); }
        if (body.x > aspect - 0.06f) { body.x = aspect - 0.06f; body.z = -abs(body.z); }
        jelly.body = body;
    }
}

void updateGrumbles(device GameState &game, float dt, float aspect, float time) {
    for (int index = 0; index < grumbleCapacity; ++index) {
        device Grumble &grumble = game.grumbles[index];
        if (grumble.anim.w < 0.5f) continue;
        grumble.anim.x = max(0.0f, grumble.anim.x - dt);
        grumble.anim.y = max(0.0f, grumble.anim.y - dt);
        float4 body = grumble.body;
        float speed = length(body.zw);
        float2 heading = speed > 0.0001f ? body.zw / speed : float2(1.0f, 0.0f);
        float turn = 0.6f * sin(time * 0.6f + float(index) * 1.7f) * dt;
        heading = float2(heading.x * cos(turn) - heading.y * sin(turn),
            heading.x * sin(turn) + heading.y * cos(turn));
        float cruise = grumble.anim.y > 0.0f ? grumble.anim.z * 0.35f : grumble.anim.z;
        speed = mix(speed, cruise, min(1.0f, dt * 1.2f));
        body.zw = heading * speed;
        body.xy += body.zw * dt;
        if (body.y < waterTop) { body.y = waterTop; body.w = abs(body.w); }
        if (body.y > waterBottom) { body.y = waterBottom; body.w = -abs(body.w); }
        if (body.x < 0.08f) { body.x = 0.08f; body.z = abs(body.z); }
        if (body.x > aspect - 0.08f) { body.x = aspect - 0.08f; body.z = -abs(body.z); }
        grumble.body = body;
        if (game.flow.x != phasePlaying || grumble.anim.y > 0.0f) continue;

        float radius = grumbleRadius;
        if (grumble.anim.x > 0.0f) radius = grumblePuffRadius;
        float2 away = game.wand.xy - body.xy;
        float reach = length(away);
        if (game.control.w <= 0.0f && reach < radius + bumpReach) {
            float2 direction = reach > 0.0001f ? away / reach : float2(0.0f, -1.0f);
            game.wand.xy += direction * 0.06f;
            game.popFx = float4(game.wand.xy, 0.0f, 2.0f);
            hurt(game, textOuch);
            if (game.flow.x != phasePlaying) return;
            continue;
        }
        int count = int(game.trailInfo.x);
        for (int point = 0; point + 1 < count; ++point) {
            if (segmentDistance(body.xy, game.trail[point].xy,
                game.trail[point + 1].xy) < radius + 0.006f) {
                game.popFx = float4(body.xy, 0.0f, 0.0f);
                clearTrail(game);
                break;
            }
        }
    }
}

void toot(device GameState &game) {
    if (game.flow.w == 0u) {
        showNotice(game, textNoToots, 0u);
        return;
    }
    game.flow.w -= 1u;
    game.tootFx = float4(game.wand.xy, 0.0f, 0.0f);
    game.clock.z = 0.0f;
    showNotice(game, textToot, 0u);
    for (int index = 0; index < grumbleCapacity; ++index) {
        device Grumble &grumble = game.grumbles[index];
        if (grumble.anim.w < 0.5f) continue;
        float2 away = grumble.body.xy - game.wand.xy;
        float reach = length(away);
        if (reach >= tootRadius) continue;
        float2 direction = reach > 0.0001f ? away / reach : float2(0.0f, -1.0f);
        grumble.body.zw = direction * 0.55f;
        grumble.anim.x = 0.0f;
        grumble.anim.y = 3.0f;
    }
}

// ---------------------------------------------------------------------------
// Kernels

kernel void initializeLagoon(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float aspect = aspectOf(u);
    game.wand = float4(clamp(u.pointer.x, 0.0f, 1.0f) * aspect,
        clamp(u.pointer.y, 0.0f, 1.0f), 0.0f, 0.0f);
    // The current action count is the baseline, not a press.
    game.control = float4(u.pointer.z, 1.0f, 0.0f, 0.0f);
    game.trailInfo = uint4(0u, u.frameSeed.y * 2654435761u + u.frameSeed.z + 12345u, 0u, 0u);
    game.score = uint4(0u);
    game.stats = uint4(0u);
    game.notice = uint4(0u);
    game.trailBox = float4(0.0f);
    showTitle(game, u);
}

kernel void advanceLagoon(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.resolutionTime.w, 0.0f, 0.05f);
    float time = u.resolutionTime.z;
    float aspect = aspectOf(u);
    bool pressed = u.pointer.z > game.control.x;
    if (pressed) game.control.x = u.pointer.z;

    // The wand swims after the pointer with a little lag and a top speed.
    float2 target = float2(clamp(u.pointer.x, 0.0f, 1.0f) * aspect,
        clamp(u.pointer.y, 0.0f, 1.0f));
    target = clamp(target, float2(0.03f, 0.10f), float2(aspect - 0.03f, 0.95f));
    float2 previous = game.wand.xy;
    float2 move = (target - previous) * min(1.0f, dt * wandFollow);
    float moveLength = length(move);
    float maxMove = wandMaxSpeed * dt;
    if (moveLength > maxMove) move *= maxMove / moveLength;
    game.wand.xy = previous + move;
    game.wand.zw = dt > 0.0f ? move / dt : float2(0.0f);
    if (abs(game.wand.z) > 0.25f) {
        game.control.y = clamp(game.control.y + sign(game.wand.z) * dt * 6.0f,
            -1.0f, 1.0f);
    }
    game.control.z += dt;
    game.control.w = max(0.0f, game.control.w - dt);
    game.clock.y += dt;
    game.clock.z += dt;
    game.loopFx.w += dt;
    game.popFx.z += dt;

    uint phase = game.flow.x;
    if (phase == phaseTitle) {
        if (pressed) {
            startGame(game, u);
            return;
        }
    } else if (phase == phaseBriefing) {
        if (pressed || game.control.z >= briefingSeconds) {
            game.flow.x = phasePlaying;
            game.control.z = 0.0f;
        }
    } else if (phase == phasePlaying) {
        if (pressed) toot(game);
        game.clock.x -= dt;
        if (game.clock.x <= 10.0f && game.clock.w < 0.5f) {
            game.clock.w = 1.0f;
            showNotice(game, textHurry, 0u);
        }
        if (game.clock.x <= 0.0f) {
            game.clock.x = 0.0f;
            loseShift(game, textOutOfTime);
        }
    } else if (pressed && game.control.z > 0.6f) {
        if (phase == phaseCleared) startShift(game, u, game.flow.y + 1u);
        else if (phase == phaseGameOver) retryShift(game, u);
        else showTitle(game, u);
        return;
    }
    updateJellies(game, dt, aspect, time);
    updateGrumbles(game, dt, aspect, time);
    updateTrail(game, time);
}

// ---------------------------------------------------------------------------
// Pixel-font text (pixel space)

float glyphDot(uint code, int column, int row) {
    if (code < 32u || code > 90u || column < 0 || column > 4
        || row < 0 || row > 6) return 0.0f;
    uint bits = uint(fontRows[(code - 32u) * 7u + uint(row)]);
    return float((bits >> uint(4 - column)) & 1u);
}

// Origin is the top-left pixel; one font dot is cell pixels wide. Each
// character may bob by wave * sin(time * 4 + character) pixels.
float waveCoverage(float2 pixel, float2 origin, float cell, int text,
    float wave, float time) {
    int start = textRanges[text * 2];
    int count = textRanges[text * 2 + 1];
    float2 local = (pixel - origin) / cell;
    if (local.x < 0.0f || local.x >= float(count * 6)) return 0.0f;
    int column = int(local.x);
    int character = column / 6;
    local.y -= wave * sin(time * 4.0f + float(character) * 0.7f) / cell;
    if (local.y < 0.0f || local.y >= 7.0f) return 0.0f;
    return glyphDot(uint(textPool[start + character]),
        column - character * 6, int(local.y));
}

float textCoverage(float2 pixel, float2 origin, float cell, int text) {
    return waveCoverage(pixel, origin, cell, text, 0.0f, 0.0f);
}

float textWidth(int text, float cell) {
    return (float(textRanges[text * 2 + 1]) * 6.0f - 1.0f) * cell;
}

// ---------------------------------------------------------------------------
// Presentation

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenVertex lagoonVertex(uint vertexID [[vertex_id]]) {
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

float lumaOf(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// Recolours a texture: keeps its light and dark detail, takes the hue of tint.
float3 tinted(float3 albedo, float3 tint, float detail) {
    float luma = lumaOf(albedo);
    return tint * mix(1.0f, clamp(luma * 2.4f, 0.35f, 1.6f), detail);
}

float smin(float a, float b, float k) {
    float h = clamp(0.5f + 0.5f * (b - a) / k, 0.0f, 1.0f);
    return mix(b, a, h) - k * h * (1.0f - h);
}

float sdCircle(float2 q, float radius) {
    return length(q) - radius;
}

float sdEllipse(float2 q, float2 radii) {
    return (length(q / radii) - 1.0f) * min(radii.x, radii.y);
}

float sdBox(float2 q, float2 halfSize) {
    float2 d = abs(q) - halfSize;
    return length(max(d, float2(0.0f))) + min(max(d.x, d.y), 0.0f);
}

float sdCapsule(float2 q, float2 a, float2 b, float radius) {
    return segmentDistance(q, a, b) - radius;
}

// Arched door: a box with a round top. Origin at the bottom centre.
float sdArch(float2 q, float halfWidth, float height) {
    float box = sdBox(q - float2(0.0f, -0.5f * (height - halfWidth)),
        float2(halfWidth, 0.5f * (height - halfWidth)));
    return min(box, sdCircle(q - float2(0.0f, -(height - halfWidth)), halfWidth));
}

// Fills a shape and inks its outline (cartoon style). d and px share units.
void paintShape(thread float3 &color, float d, float px, float3 fill,
    float3 ink, float outline) {
    color = mix(color, fill, 1.0f - smoothstep(-px, px, d));
    color = mix(color, ink, 1.0f - smoothstep(outline - px, outline + px, abs(d)));
}

void paintFill(thread float3 &color, float d, float px, float3 fill, float alpha) {
    color = mix(color, fill, (1.0f - smoothstep(-px, px, d)) * alpha);
}

void paintPorthole(thread float3 &color, float2 q, float2 at, float radius,
    float px, float time, float3 ink) {
    float d = sdCircle(q - at, radius);
    if (d > radius) return;
    float glow = 0.85f + 0.15f * sin(time * 2.3f + at.x * 40.0f);
    float3 glass = mix(float3(1.0f, 0.86f, 0.42f), float3(1.0f, 0.97f, 0.75f),
        clamp(0.5f - (q.y - at.y) / radius, 0.0f, 1.0f)) * glow;
    paintShape(color, d, px, glass, float3(0.85f, 0.55f, 0.25f), 0.0042f);
    float frame = abs(d) - 0.0035f;
    color = mix(color, ink, 1.0f - smoothstep(-px, px, abs(frame) - 0.0012f));
}

void paintBubble(thread float3 &color, float2 p, float2 center, float radius,
    float px, float alpha) {
    float d = length(p - center) - radius;
    if (d > 2.0f * px) return;
    float inside = 1.0f - smoothstep(-px, px, d);
    color = mix(color, color * 0.85f + float3(0.18f, 0.24f, 0.26f), inside * 0.35f * alpha);
    float rim = 1.0f - smoothstep(0.0f, max(1.6f * px, radius * 0.18f), abs(d));
    color = mix(color, float3(0.92f, 0.98f, 1.0f), rim * 0.85f * alpha);
    float shine = 1.0f - smoothstep(0.0f, radius * 0.28f + px,
        length(p - center + radius * float2(0.38f, 0.38f)));
    color = mix(color, float3(1.0f), shine * 0.9f * alpha);
}

// ---------------------------------------------------------------------------
// Water, sky flowers and seabed

float groundLine(float x) {
    return 0.80f + 0.016f * sin(x * 2.7f + 0.6f) + 0.009f * sin(x * 6.3f + 1.7f);
}

float3 waterColor(float2 p, float aspect, float time, texture2d<float> backdrop) {
    constexpr sampler backdropSampler(coord::normalized,
        address::clamp_to_edge, filter::linear);
    float2 uv = float2(p.x / aspect, 0.16f + p.y * 0.62f);
    uv.x += 0.006f * sin(time * 0.25f + p.y * 3.0f);
    float3 art = decodeSRGB(backdrop.sample(backdropSampler, uv));
    float3 grade = mix(float3(0.42f, 0.86f, 0.95f), float3(0.07f, 0.40f, 0.66f),
        smoothstep(0.0f, 0.95f, p.y));
    float3 color = mix(art, grade, 0.32f);
    float beams = pow(max(sin((p.x + 0.45f * p.y) * 9.0f + time * 0.4f), 0.0f), 6.0f)
        * (1.0f - smoothstep(0.0f, 0.75f, p.y));
    color += float3(0.22f, 0.28f, 0.22f) * beams * 0.35f;
    float caustic = sin(p.x * 31.0f + sin(p.y * 23.0f + time * 1.3f) * 2.0f + time)
        * sin(p.y * 27.0f - time * 0.9f + sin(p.x * 17.0f) * 2.0f);
    color += float3(0.05f, 0.07f, 0.06f) * smoothstep(0.55f, 1.0f, caustic)
        * (1.0f - smoothstep(0.2f, 0.8f, p.y));
    return color;
}

float3 flowerColor(int index) {
    int pick = index % 5;
    if (pick == 0) return float3(1.00f, 0.62f, 0.80f);
    if (pick == 1) return float3(0.62f, 0.95f, 0.66f);
    if (pick == 2) return float3(1.00f, 0.93f, 0.50f);
    if (pick == 3) return float3(0.78f, 0.68f, 1.00f);
    return float3(0.58f, 0.88f, 1.00f);
}

// The flower-shaped light patterns drifting across the water above town.
void paintSkyFlowers(thread float3 &color, float2 p, float aspect, float time,
    float px) {
    for (int index = 0; index < 8; ++index) {
        float fi = float(index);
        float size = 0.06f + 0.045f * fract(fi * 0.618f + 0.2f);
        float span = aspect + 0.5f;
        float x = fract(fi * 0.37f + 0.05f + time * (0.004f + 0.0015f * fi)) * span - 0.25f;
        float y = 0.09f + 0.46f * fract(fi * 0.53f + 0.31f);
        float2 q = p - float2(x, y + 0.012f * sin(time * 0.7f + fi));
        if (dot(q, q) > size * size * 1.2f) continue;
        q /= size;
        float petals = index % 2 == 0 ? 5.0f : 6.0f;
        float angle = atan2(q.y, q.x) + time * 0.08f * (index % 3 == 0 ? -1.0f : 1.0f) + fi;
        float d = length(q) - (0.62f + 0.38f * abs(cos(angle * petals * 0.5f)));
        float aa = px / size;
        float3 petal = flowerColor(index);
        float alpha = 0.50f;
        color = mix(color, petal, (1.0f - smoothstep(-aa, aa, d)) * alpha);
        color = mix(color, petal * 0.72f, (1.0f - smoothstep(0.0f, 3.0f * aa, abs(d))) * 0.35f);
        float center = 1.0f - smoothstep(0.24f - aa, 0.24f + aa, length(q));
        color = mix(color, float3(1.0f, 0.97f, 0.82f), center * 0.55f);
    }
}

void paintAmbientBubbles(thread float3 &color, float2 p, float aspect, float time,
    float px) {
    for (int index = 0; index < 16; ++index) {
        float fi = float(index);
        float speed = 0.05f + 0.04f * fract(fi * 0.731f);
        float x = fract(fi * 0.2137f + 0.1f) * aspect + 0.012f * sin(time * 2.0f + fi * 1.3f);
        float y = 1.0f - fract(time * speed + fi * 0.377f) * 1.15f;
        float radius = 0.005f + 0.007f * fract(fi * 0.917f);
        paintBubble(color, p, float2(x, y), radius, px, 0.8f);
    }
}

void paintSand(thread float3 &color, float2 p, float px, float time,
    texture2d<float> sand) {
    float ground = groundLine(p.x);
    float d = ground - p.y;              // negative below the ground line
    if (d > px * 2.0f) return;
    float3 albedo = textureAlbedo(sand, float2(p.x * 1.3f, p.y * 2.6f));
    float3 base = mix(albedo, float3(0.98f, 0.76f, 0.58f), 0.38f);
    float depth = clamp((p.y - ground) / 0.2f, 0.0f, 1.0f);
    base *= mix(1.06f, 0.82f, depth);
    float ripple = sin(p.x * 46.0f + sin(p.y * 31.0f) * 2.0f + p.y * 70.0f);
    base *= 1.0f + 0.05f * smoothstep(0.6f, 1.0f, ripple);
    // A pale cobbled street through town.
    float street = 1.0f - smoothstep(0.012f, 0.018f, abs(p.y - ground - 0.07f
        - 0.01f * sin(p.x * 3.0f)));
    base = mix(base, float3(1.0f, 0.90f, 0.78f), street * 0.55f);
    // Tiny pink shells scattered in the sand.
    float2 cell = floor(p * 28.0f);
    float pick = fract(sin(dot(cell, float2(12.9898f, 78.233f))) * 43758.547f);
    float2 spot = (cell + 0.25f + 0.5f * fract(pick * float2(13.7f, 29.3f))) / 28.0f;
    float shellDot = length((p - spot) * float2(1.0f, 1.5f)) - 0.0045f;
    if (pick > 0.86f) base = mix(base, float3(1.0f, 0.78f, 0.84f), 1.0f - smoothstep(-px, px, shellDot));
    color = mix(color, base, smoothstep(px, -px, d));
    color = mix(color, float3(0.62f, 0.40f, 0.30f),
        (1.0f - smoothstep(0.0f, 2.2f * px, abs(d))) * 0.8f);
}

void paintKelp(thread float3 &color, float2 p, float baseX, float time, float px,
    float seed) {
    if (abs(p.x - baseX) > 0.12f || p.y < 0.48f) return;
    for (int index = 0; index < 3; ++index) {
        float fi = float(index);
        float x0 = baseX + (fi - 1.0f) * 0.034f;
        float ground = groundLine(x0) + 0.012f;
        float height = 0.20f + 0.08f * fract(seed + 0.37f * fi);
        float t = (ground - p.y) / height;
        if (t < 0.0f || t > 1.0f) continue;
        float sway = 0.032f * sin(time * 1.3f + t * 4.0f + seed * 6.0f + fi) * t;
        float center = x0 + sway + 0.012f * sin(t * 9.0f + fi);
        float width = 0.013f * (1.0f - 0.65f * t) + 0.003f;
        float d = abs(p.x - center) - width;
        float3 leaf = mix(float3(0.16f, 0.62f, 0.26f), float3(0.42f, 0.86f, 0.30f), t);
        paintShape(color, d, px, leaf, float3(0.05f, 0.25f, 0.10f), 0.0018f);
        float rib = 1.0f - smoothstep(0.0f, 1.5f * px, abs(p.x - center));
        color = mix(color, float3(0.62f, 0.95f, 0.45f), rib * 0.6f
            * (1.0f - smoothstep(-px, px, d)));
    }
}

void paintCoral(thread float3 &color, float2 p, float2 base, float time, float px,
    float3 tint, texture2d<float> pebbles) {
    float2 q = p - base;
    if (abs(q.x) > 0.09f || q.y < -0.15f || q.y > 0.02f) return;
    q.x -= 0.006f * sin(time * 1.6f + base.x * 9.0f) * clamp(-q.y / 0.12f, 0.0f, 1.0f);
    float d = sdCapsule(q, float2(0.0f, 0.0f), float2(0.0f, -0.06f), 0.013f);
    d = smin(d, sdCapsule(q, float2(0.0f, -0.04f), float2(-0.038f, -0.090f), 0.011f), 0.01f);
    d = smin(d, sdCapsule(q, float2(0.0f, -0.05f), float2(0.034f, -0.105f), 0.011f), 0.01f);
    d = smin(d, sdCapsule(q, float2(-0.038f, -0.09f), float2(-0.056f, -0.122f), 0.009f), 0.01f);
    d = min(d, sdCircle(q - float2(0.0f, -0.068f), 0.016f));
    d = min(d, sdCircle(q - float2(0.034f, -0.110f), 0.014f));
    d = min(d, sdCircle(q - float2(-0.058f, -0.126f), 0.012f));
    float3 fill = tinted(textureAlbedo(pebbles, q * 6.0f + base), tint, 0.5f);
    paintShape(color, d, px, fill, tint * 0.35f, 0.0018f);
}

void paintPearHouse(thread float3 &color, float2 p, float2 base, float px,
    float time, texture2d<float> fruit) {
    float2 q = p - base;
    if (abs(q.x) > 0.15f || q.y < -0.37f || q.y > 0.02f) return;
    float rise = clamp(-q.y / 0.34f, 0.0f, 1.0f);
    q.x -= 0.010f * sin(time * 1.9f) * rise * rise;
    q.y *= 1.0f + 0.025f * sin(time * 3.1f);
    float3 ink = float3(0.12f, 0.16f, 0.05f);
    // Stem and leaf behind the fruit.
    paintShape(color, sdCapsule(q, float2(0.0f, -0.29f), float2(0.012f, -0.335f), 0.008f),
        px, float3(0.42f, 0.24f, 0.10f), ink, 0.0016f);
    paintShape(color, sdEllipse(q - float2(0.036f, -0.322f), float2(0.030f, 0.012f)),
        px, float3(0.30f, 0.78f, 0.25f), ink, 0.0016f);
    float body = smin(sdCircle(q - float2(0.0f, -0.105f), 0.105f),
        sdCircle(q - float2(0.0f, -0.235f), 0.066f), 0.06f);
    float3 skin = mix(textureAlbedo(fruit, q * 3.2f), float3(0.80f, 0.92f, 0.28f), 0.35f);
    float shade = 1.0f - 0.24f * smoothstep(-0.02f, 0.09f, q.x - 0.25f * (q.y + 0.15f));
    paintShape(color, body, px, skin * shade, ink, 0.0022f);
    float sheen = 1.0f - smoothstep(0.0f, 0.03f, length(q - float2(-0.05f, -0.15f)));
    color = mix(color, float3(1.0f, 1.0f, 0.9f), sheen * 0.35f * (body < 0.0f ? 1.0f : 0.0f));
    paintShape(color, sdArch(q, 0.026f, 0.072f), px, float3(0.55f, 0.30f, 0.16f), ink, 0.0018f);
    paintPorthole(color, q, float2(-0.052f, -0.125f), 0.019f, px, time, ink);
    paintPorthole(color, q, float2(0.046f, -0.205f), 0.016f, px, time, ink);
}

void paintPebbleTower(thread float3 &color, float2 p, float2 base, float px,
    float time, texture2d<float> pebbles) {
    float2 q = p - base;
    if (abs(q.x) > 0.13f || q.y < -0.40f || q.y > 0.02f) return;
    float rise = clamp(-q.y / 0.3f, 0.0f, 1.0f);
    q.x -= 0.008f * sin(time * 2.3f + 1.0f) * rise;
    float3 ink = float3(0.13f, 0.11f, 0.22f);
    // Flag on top.
    paintShape(color, sdCapsule(q, float2(0.0f, -0.300f), float2(0.0f, -0.365f), 0.0035f),
        px, float3(0.55f, 0.45f, 0.40f), ink, 0.0012f);
    float2 f = q - float2(0.0f, -0.362f);
    float wave = 0.006f * sin(time * 6.0f + f.x * 90.0f);
    float flag = max(max(-f.x, f.x - 0.045f), abs(f.y - 0.012f - wave) - 0.012f * (1.0f - f.x / 0.05f));
    paintShape(color, flag, px, float3(1.0f, 0.42f, 0.62f), ink, 0.0012f);
    float d = smin(sdEllipse(q - float2(0.0f, -0.065f), float2(0.105f, 0.068f)),
        sdEllipse(q - float2(0.012f, -0.168f), float2(0.082f, 0.056f)), 0.012f);
    d = smin(d, sdEllipse(q - float2(-0.005f, -0.258f), float2(0.062f, 0.046f)), 0.012f);
    float3 stone = tinted(textureAlbedo(pebbles, q * 4.0f), float3(0.66f, 0.62f, 0.92f), 0.7f);
    float shade = 1.0f - 0.22f * smoothstep(-0.02f, 0.08f, q.x);
    paintShape(color, d, px, stone * shade, ink, 0.0022f);
    // Seams between the stacked pebbles.
    float seam = min(abs(sdEllipse(q - float2(0.012f, -0.168f), float2(0.082f, 0.056f))),
        abs(sdEllipse(q - float2(-0.005f, -0.258f), float2(0.062f, 0.046f))));
    color = mix(color, ink, (1.0f - smoothstep(0.0f, 1.6f * px, seam)) * 0.6f
        * (d < 0.0f ? 1.0f : 0.0f));
    paintShape(color, sdArch(q, 0.024f, 0.066f), px, float3(0.95f, 0.55f, 0.35f), ink, 0.0018f);
    paintPorthole(color, q, float2(0.020f, -0.170f), 0.018f, px, time, ink);
    paintPorthole(color, q, float2(-0.012f, -0.258f), 0.014f, px, time, ink);
}

void paintDiner(thread float3 &color, float2 p, float2 base, float px, float time,
    float height, texture2d<float> shell) {
    float2 q = p - base;
    if (abs(q.x) > 0.27f || q.y < -0.40f || q.y > 0.02f) return;
    float3 ink = float3(0.25f, 0.08f, 0.14f);
    // Sign board on two posts.
    paintShape(color, min(sdBox(q - float2(-0.10f, -0.30f), float2(0.004f, 0.05f)),
        sdBox(q - float2(0.10f, -0.30f), float2(0.004f, 0.05f))), px,
        float3(0.45f, 0.30f, 0.22f), ink, 0.0012f);
    float board = sdBox(q - float2(0.0f, -0.345f), float2(0.135f, 0.027f)) - 0.008f;
    paintShape(color, board, px, float3(0.20f, 0.12f, 0.30f), ink, 0.0022f);
    // Scalloped shell facade, hinged at the ground.
    float2 v = q - float2(0.0f, -0.005f);
    float radius = length(v);
    float angle = atan2(v.x, -v.y);
    float edge = 0.255f + 0.010f * cos(angle * 16.0f);
    float fan = max(radius - edge, (abs(angle) - 1.22f) * radius);
    float ridge = 0.5f + 0.5f * cos(angle * 16.0f);
    float3 shellColor = mix(textureAlbedo(shell, float2(angle * 0.45f, radius * 2.5f)),
        mix(float3(1.0f, 0.80f, 0.86f), float3(1.0f, 0.55f, 0.66f), ridge), 0.45f);
    shellColor *= 0.86f + 0.22f * smoothstep(0.0f, 0.25f, radius);
    paintShape(color, fan, px, shellColor, ink, 0.0024f);
    float ridgeLine = 1.0f - smoothstep(0.0f, 2.0f * px / max(radius, 0.02f),
        abs(fract(angle * 16.0f / 6.2831853f + 0.5f) - 0.5f) * 6.2831853f / 16.0f);
    color = mix(color, ink, ridgeLine * 0.35f * (fan < 0.0f ? 1.0f : 0.0f)
        * smoothstep(0.04f, 0.08f, radius));
    // Counter, awning, door and windows.
    paintShape(color, sdBox(q - float2(0.0f, -0.035f), float2(0.21f, 0.035f)) - 0.006f, px,
        float3(0.98f, 0.82f, 0.56f), ink, 0.0018f);
    float2 a = q - float2(-0.125f, -0.112f);
    float awning = sdBox(a, float2(0.06f, 0.014f));
    float stripe = step(0.5f, fract(a.x * 40.0f));
    paintShape(color, awning, px, mix(float3(1.0f, 0.35f, 0.45f), float3(1.0f, 0.97f, 0.92f),
        stripe), ink, 0.0016f);
    paintShape(color, sdBox(q - float2(-0.125f, -0.068f), float2(0.048f, 0.026f)), px,
        float3(1.0f, 0.90f, 0.55f), ink, 0.0018f);
    paintShape(color, sdArch(q, 0.030f, 0.085f), px, float3(0.62f, 0.85f, 0.95f), ink, 0.0020f);
    paintPorthole(color, q, float2(0.115f, -0.120f), 0.026f, px, time, ink);
    paintPorthole(color, q, float2(0.040f, -0.195f), 0.020f, px, time, ink);
    paintPorthole(color, q, float2(-0.060f, -0.205f), 0.018f, px, time, ink);
    // Neon sign text.
    float cell = 0.0042f * height;
    float2 pixel = p * height;
    float2 origin = float2(base.x * height - 0.5f * textWidth(textSign, cell),
        (base.y - 0.345f) * height - 3.5f * cell);
    float flicker = 0.85f + 0.15f * step(0.08f, fract(time * 0.7f));
    float glow = textCoverage(pixel, origin, cell, textSign);
    color = mix(color, float3(1.0f, 0.45f, 0.75f) * 1.4f * flicker, glow);
}

void paintLemonHouse(thread float3 &color, float2 p, float2 base, float px,
    float time, texture2d<float> fruit) {
    float2 q = p - base;
    if (abs(q.x) > 0.14f || q.y < -0.33f || q.y > 0.02f) return;
    float tilt = 0.12f + 0.03f * sin(time * 1.7f);
    float c = cos(tilt);
    float s = sin(tilt);
    float2 r = float2(c * q.x + s * (q.y + 0.12f), -s * q.x + c * (q.y + 0.12f)) - float2(0.0f, 0.12f);
    r.y *= 1.0f + 0.03f * sin(time * 2.6f + 1.0f);
    float3 ink = float3(0.25f, 0.18f, 0.02f);
    float body = smin(sdEllipse(r - float2(0.0f, -0.128f), float2(0.088f, 0.122f)),
        sdCircle(r - float2(0.0f, -0.262f), 0.018f), 0.03f);
    float3 skin = tinted(textureAlbedo(fruit, r * 3.0f + 0.3f), float3(1.0f, 0.86f, 0.18f), 0.55f);
    float shade = 1.0f - 0.22f * smoothstep(-0.02f, 0.08f, r.x);
    paintShape(color, body, px, skin * shade, ink, 0.0022f);
    float dimple = sin(r.x * 140.0f) * sin(r.y * 130.0f);
    color = mix(color, color * 0.92f, smoothstep(0.7f, 1.0f, dimple) * (body < 0.0f ? 1.0f : 0.0f));
    paintShape(color, sdArch(r, 0.024f, 0.064f), px, float3(0.35f, 0.62f, 0.85f), ink, 0.0018f);
    paintPorthole(color, r, float2(-0.035f, -0.150f), 0.017f, px, time, ink);
    paintPorthole(color, r, float2(0.030f, -0.200f), 0.015f, px, time, ink);
    // Window box with three tiny flowers.
    paintShape(color, sdBox(r - float2(-0.035f, -0.126f), float2(0.024f, 0.006f)), px,
        float3(0.62f, 0.36f, 0.20f), ink, 0.0012f);
    for (int index = 0; index < 3; ++index) {
        float2 at = float2(-0.052f + 0.017f * float(index), -0.137f);
        paintShape(color, sdCircle(r - at, 0.0055f), px, flowerColor(index), ink, 0.001f);
    }
}

void paintSeabed(thread float3 &color, float2 p, float aspect, float px, float time,
    float height, texture2d<float> sand, texture2d<float> fruit,
    texture2d<float> pebbles, texture2d<float> shell) {
    if (p.y < 0.40f) return;
    paintKelp(color, p, 0.27f * aspect, time, px, 0.13f);
    paintKelp(color, p, 0.73f * aspect, time, px, 0.71f);
    float pearX = 0.10f * aspect;
    float towerX = 0.38f * aspect;
    float dinerX = 0.585f * aspect;
    float lemonX = 0.86f * aspect;
    paintPearHouse(color, p, float2(pearX, groundLine(pearX) + 0.012f), px, time, fruit);
    paintPebbleTower(color, p, float2(towerX, groundLine(towerX) + 0.012f), px, time, pebbles);
    paintDiner(color, p, float2(dinerX, groundLine(dinerX) + 0.014f), px, time, height, shell);
    paintLemonHouse(color, p, float2(lemonX, groundLine(lemonX) + 0.012f), px, time, fruit);
    paintSand(color, p, px, time, sand);
    float coral0 = 0.205f * aspect;
    float coral1 = 0.465f * aspect;
    float coral2 = 0.965f * aspect;
    paintCoral(color, p, float2(coral0, groundLine(coral0) + 0.02f), time, px,
        float3(1.0f, 0.45f, 0.55f), pebbles);
    paintCoral(color, p, float2(coral1, groundLine(coral1) + 0.02f), time, px,
        float3(1.0f, 0.62f, 0.30f), pebbles);
    paintCoral(color, p, float2(coral2, groundLine(coral2) + 0.02f), time, px,
        float3(0.78f, 0.45f, 1.0f), pebbles);
}

// ---------------------------------------------------------------------------
// Characters

float3 jellyTint(uint kind) {
    if (kind == kindPink) return float3(1.00f, 0.36f, 0.68f);
    if (kind == kindBlue) return float3(0.30f, 0.58f, 1.00f);
    if (kind == kindLime) return float3(0.52f, 0.95f, 0.28f);
    return float3(1.00f, 0.78f, 0.16f);
}

// One cartoon jellyfish in its local frame: q is in units of its size.
void paintJellyBody(thread float3 &color, float2 q, float aa, float pulse, uint kind,
    float shimmer, float time, float alpha, texture2d<float> jellyTexture) {
    float3 tint = jellyTint(kind);
    float3 ink = tint * 0.32f;
    for (int index = 0; index < 4; ++index) {
        float fi = float(index);
        float x0 = -0.56f + 0.373f * fi;
        float along = clamp(q.y, 0.2f, 1.45f);
        float tx = x0 + 0.16f * sin(along * 5.5f - time * 4.0f - fi * 1.3f) * (along - 0.2f);
        float width = 0.075f * (1.5f - along) / 1.25f + 0.025f;
        float d = max(abs(q.x - tx) - width, max(0.2f - q.y, q.y - 1.45f));
        paintFill(color, d, aa, mix(tint, float3(1.0f), 0.25f), 0.75f * alpha);
        color = mix(color, ink, (1.0f - smoothstep(0.0f, 2.0f * aa, abs(d))) * 0.5f * alpha);
    }
    float dome = length(q * float2(1.0f, 1.12f)) - 1.0f;
    float skirt = q.y - (0.30f + 0.09f * cos(q.x * 10.0f + time * 4.0f));
    float bell = max(dome, skirt);
    float3 skin = textureAlbedo(jellyTexture, q * 0.32f + float2(shimmer, shimmer * 0.7f));
    float3 fill = tinted(skin, tint, 0.45f) * (1.0f + 0.15f * (1.0f - pulse));
    fill = mix(fill, float3(1.0f), 0.45f * (1.0f - smoothstep(0.0f, 0.45f,
        length(q - float2(-0.38f, -0.48f)))));
    color = mix(color, fill, (1.0f - smoothstep(-aa, aa, bell)) * 0.92f * alpha);
    color = mix(color, ink, (1.0f - smoothstep(0.03f - aa, 0.03f + aa, abs(bell))) * alpha);
    // Face: blinking eyes, a smile and rosy cheeks.
    float blink = fract(time * 0.31f + shimmer) < 0.04f ? 0.25f : 1.0f;
    for (int side = -1; side <= 1; side += 2) {
        float2 eye = (q - float2(0.30f * float(side), -0.06f)) * float2(1.0f, 1.0f / blink);
        float d = length(eye) - 0.12f;
        color = mix(color, float3(0.04f, 0.03f, 0.08f), (1.0f - smoothstep(-aa, aa, d)) * alpha);
        float glint = length(eye - float2(-0.04f, -0.045f)) - 0.045f;
        color = mix(color, float3(1.0f), (1.0f - smoothstep(-aa, aa, glint)) * alpha
            * (blink > 0.5f ? 1.0f : 0.0f));
        float cheek = length((q - float2(0.52f * float(side), 0.10f)) * float2(1.0f, 1.6f)) - 0.12f;
        color = mix(color, float3(1.0f, 0.45f, 0.55f), (1.0f - smoothstep(-aa, aa, cheek)) * 0.5f * alpha);
    }
    float smile = abs(length(q - float2(0.0f, -0.02f)) - 0.20f) - 0.035f;
    smile = max(smile, 0.06f - q.y);
    color = mix(color, float3(0.30f, 0.05f, 0.12f), (1.0f - smoothstep(-aa, aa, smile)) * alpha);
}

void paintJelly(thread float3 &color, float2 p, device const Jelly &jelly, float px,
    float time, texture2d<float> jellyTexture) {
    uint state = jelly.info.y;
    if (state == jellyWaiting) return;
    float2 center = jelly.body.xy;
    float reach = length(p - center);
    if (reach > jellySize * 2.4f) return;
    float pulse = jelly.anim.x;
    float squeeze = exp(-pulse * 6.0f);
    float2 stretch = float2(1.04f - 0.16f * squeeze, 0.96f + 0.18f * squeeze);
    float scale = 1.0f;
    float alpha = 1.0f;
    float seconds = jelly.anim.w;
    if (state == jellySwim && seconds < 0.4f) {
        float grow = seconds / 0.4f;
        scale = grow * (1.0f + 0.45f * sin(grow * 3.14159265f));
    }
    if (state == jellyCaught) {
        // Wrapped in a bubble: the bubble wobbles, the jelly shrinks inside.
        float wobble = 1.0f + 0.06f * sin(time * 9.0f);
        alpha = 1.0f - smoothstep(0.85f, 1.15f, seconds);
        scale = 0.72f;
        stretch = float2(wobble, 2.0f - wobble);
    }
    float size = jellySize * max(scale, 0.001f);
    float2 q = (p - center) / size / stretch;
    float aa = px / size;
    paintJellyBody(color, q, aa, pulse, jelly.info.x, jelly.anim.z, time, alpha,
        jellyTexture);
    if (state == jellyCaught) {
        paintBubble(color, p, center + float2(0.0f, 0.006f), jellySize * 1.35f, px, alpha);
    } else if (jelly.info.x == kindGold) {
        for (int index = 0; index < 4; ++index) {
            float angle = time * 2.0f + float(index) * 1.5707963f;
            float2 at = center + jellySize * 1.55f * float2(cos(angle), sin(angle));
            float2 s = abs(p - at);
            float star = min(s.x * 4.0f + s.y, s.x + s.y * 4.0f) - 0.012f;
            color = mix(color, float3(1.4f, 1.2f, 0.6f), 1.0f - smoothstep(-px, px, star));
        }
    }
}

void paintGrumble(thread float3 &color, float2 p, device const Grumble &grumble,
    float px, float time, float2 wand, int index) {
    if (grumble.anim.w < 0.5f) return;
    float puff = smoothstep(0.0f, 0.3f, grumble.anim.x);
    float radius = mix(grumbleRadius, grumblePuffRadius, puff);
    float2 center = grumble.body.xy;
    float2 q = (p - center) / radius;
    if (dot(q, q) > 2.6f) return;
    bool stunned = grumble.anim.y > 0.0f;
    float facing = grumble.body.z >= 0.0f ? 1.0f : -1.0f;
    float wobble = 0.07f * sin(time * 6.0f + float(index) * 2.0f);
    q *= float2(1.0f + wobble, 1.0f - wobble);
    float aa = px / radius;
    float3 ink = float3(0.25f, 0.10f, 0.04f);
    float3 skin = stunned ? float3(0.55f, 0.62f, 0.82f) : float3(1.0f, 0.55f, 0.16f);
    // Tail fin and spikes behind the body.
    float tail = sdEllipse(q - float2(-1.12f * facing, 0.0f), float2(0.30f, 0.42f));
    paintShape(color, tail, aa, skin * 0.8f, ink, 0.05f);
    float angle = atan2(q.y, q.x);
    float spikeLength = stunned ? 0.10f : 0.32f;
    float spikes = length(q) - (1.0f + spikeLength
        * pow(max(cos(angle * 10.0f), 0.0f), 6.0f));
    paintShape(color, spikes, aa, float3(0.95f, 0.85f, 0.55f), ink, 0.04f);
    float body = length(q) - 1.0f;
    paintShape(color, body, aa, skin, ink, 0.06f);
    float belly = max(body, 0.25f - q.y);
    paintFill(color, belly, aa, float3(1.0f, 0.88f, 0.62f), 1.0f);
    for (int spot = 0; spot < 3; ++spot) {
        float2 at = float2(-0.45f * facing + 0.3f * float(spot) * facing, -0.62f + 0.12f * float(spot % 2));
        paintFill(color, sdCircle(q - at, 0.09f), aa, skin * 0.65f, 1.0f);
    }
    float2 look = normalize(wand - center + float2(0.0001f, 0.0f)) * 0.07f;
    for (int side = 0; side < 2; ++side) {
        float2 eye = float2((0.12f + 0.36f * float(side)) * facing, -0.22f);
        if (stunned) {
            float swirl = abs(length(q - eye) - 0.09f) - 0.03f;
            paintFill(color, sdCircle(q - eye, 0.17f), aa, float3(1.0f), 1.0f);
            paintFill(color, swirl, aa, ink, 1.0f);
        } else {
            paintShape(color, sdCircle(q - eye, 0.17f), aa, float3(1.0f), ink, 0.03f);
            paintFill(color, sdCircle(q - eye - look, 0.08f), aa, float3(0.05f), 1.0f);
            // Angry brows slope down toward the middle of the face.
            float middle = 0.30f * facing;
            float2 a = float2(eye.x - 0.15f, -0.52f);
            float2 b = float2(eye.x + 0.15f, -0.52f);
            if (abs(a.x - middle) < abs(b.x - middle)) a.y = -0.41f;
            else b.y = -0.41f;
            paintFill(color, sdCapsule(q, a, b, 0.045f), aa, ink, 1.0f);
        }
    }
    float frown = abs(length(q - float2(0.32f * facing, 0.38f)) - 0.16f) - 0.035f;
    frown = max(frown, q.y - 0.30f);
    paintFill(color, frown, aa, ink, 1.0f);
    if (stunned) {
        for (int star = 0; star < 3; ++star) {
            float angle2 = time * 3.0f + float(star) * 2.0943951f;
            float2 at = float2(cos(angle2) * 0.8f, -1.25f + 0.18f * sin(angle2));
            float2 s = abs(q - at);
            float shape = min(s.x * 3.0f + s.y, s.x + s.y * 3.0f) - 0.22f;
            paintFill(color, shape, aa, float3(1.3f, 1.15f, 0.4f), 1.0f);
        }
    }
}

// Bixby the seahorse, holding the bubble wand ring at the trail head.
void paintSeahorse(thread float3 &color, float2 p, device const GameState &game,
    float px, float time) {
    float2 ring = game.wand.xy;
    float facing = game.control.y >= 0.0f ? 1.0f : -1.0f;
    float turn = max(abs(game.control.y), 0.35f);
    float unit = 0.058f;
    float2 origin = ring + float2(-1.40f * unit * facing * turn, 0.90f * unit);
    if (length(p - origin) > 2.6f * unit) return;
    if (game.control.w > 0.0f && fract(time * 8.0f) < 0.4f) return;
    // Local frame around the wand ring, mirrored to face the swim direction;
    // squash and stretch keep the ring on the trail head.
    float2 r = (p - ring) / unit;
    r.x *= facing / turn;
    float speed = clamp(length(game.wand.zw) * 0.35f, 0.0f, 0.25f);
    r *= float2(1.0f + speed, 1.0f - 0.5f * speed);
    float2 q = r + float2(1.40f, -0.90f);
    q.y += 0.12f * sin(time * 4.0f);
    float aa = px / unit;
    float3 ink = float3(0.04f, 0.18f, 0.20f);
    float3 skin = float3(0.18f, 0.80f, 0.68f);
    float3 belly = float3(1.0f, 0.86f, 0.42f);
    // Dorsal fin flutters behind the body.
    float flutter = 1.0f + 0.35f * sin(time * 16.0f);
    float fin = sdEllipse(q - float2(-0.50f, -0.10f), float2(0.20f * flutter, 0.34f));
    paintShape(color, fin, aa, float3(1.0f, 0.55f, 0.75f), ink, 0.05f);
    float tailCurl = abs(length(q - float2(0.30f, 1.02f)) - 0.24f) - 0.09f;
    tailCurl = max(tailCurl, -(q.x - 0.05f));
    float body = sdCapsule(q, float2(0.0f, -0.62f), float2(-0.04f, 0.28f), 0.36f);
    body = smin(body, sdCircle(q - float2(0.12f, -0.05f), 0.34f), 0.12f);
    body = smin(body, sdCapsule(q, float2(-0.04f, 0.28f), float2(0.04f, 0.90f), 0.16f), 0.15f);
    body = min(body, tailCurl);
    float head = sdCircle(q - float2(0.15f, -0.95f), 0.42f);
    head = smin(head, sdCapsule(q, float2(0.45f, -0.93f), float2(1.08f, -0.90f), 0.13f), 0.10f);
    float crest = min(sdCircle(q - float2(-0.08f, -1.33f), 0.10f),
        min(sdCircle(q - float2(0.13f, -1.40f), 0.10f), sdCircle(q - float2(0.33f, -1.32f), 0.09f)));
    paintShape(color, crest, aa, float3(1.0f, 0.55f, 0.75f), ink, 0.05f);
    float shape = smin(body, head, 0.12f);
    paintShape(color, shape, aa, skin, ink, 0.06f);
    // Belly: a disc kept inside the outline.
    float bellyShape = max(sdCircle(q - float2(0.22f, -0.05f), 0.32f), shape + 0.06f);
    paintFill(color, bellyShape, aa, belly, 1.0f);
    float ridges = abs(fract(q.y * 4.0f) - 0.5f) - 0.06f;
    color = mix(color, belly * 0.75f, (1.0f - smoothstep(-aa, aa, ridges))
        * (bellyShape < 0.0f ? 1.0f : 0.0f) * 0.7f);
    paintShape(color, sdCircle(q - float2(0.26f, -1.00f), 0.17f), aa, float3(1.0f), ink, 0.04f);
    paintFill(color, sdCircle(q - float2(0.31f, -0.99f), 0.085f), aa, float3(0.03f, 0.05f, 0.10f), 1.0f);
    paintFill(color, sdCircle(q - float2(0.27f, -1.04f), 0.035f), aa, float3(1.0f), 1.0f);
    float cheek = sdCircle(q - float2(0.40f, -0.80f), 0.08f);
    paintFill(color, cheek, aa, float3(1.0f, 0.55f, 0.60f), 0.6f);
    // The wand ring at the snout tip, filled with a soap film.
    float2 ringLocal = r;
    float film = length(ringLocal) - 0.26f;
    float3 rainbow = 0.65f + 0.35f * cos(6.2831853f * (float3(0.0f, 0.33f, 0.67f)
        + ringLocal.x * 1.5f + time * 0.6f));
    paintFill(color, film, aa, rainbow, 0.30f);
    float ringLine = abs(film) - 0.045f;
    paintShape(color, ringLine, aa, float3(1.0f, 0.40f, 0.70f), ink, 0.025f);
    paintFill(color, sdCapsule(q, float2(1.08f, -0.90f), float2(1.14f, -0.90f), 0.05f),
        aa, float3(1.0f, 0.40f, 0.70f), 1.0f);
}

void paintTrail(thread float3 &color, float2 p, device const GameState &game,
    float px, float time) {
    float4 box = game.trailBox;
    if (p.x < box.x || p.y < box.y || p.x > box.z || p.y > box.w) return;
    int count = int(game.trailInfo.x);
    if (count <= 0) return;
    float ribbon = 1000.0f;
    float ribbonAge = 0.0f;
    for (int index = 0; index + 1 < count; ++index) {
        float d = segmentDistance(p, game.trail[index].xy, game.trail[index + 1].xy);
        if (d < ribbon) {
            ribbon = d;
            ribbonAge = time - game.trail[index].z;
        }
    }
    float lead = segmentDistance(p, game.trail[count - 1].xy, game.wand.xy);
    if (lead < ribbon) {
        ribbon = lead;
        ribbonAge = 0.0f;
    }
    float fade = 1.0f - smoothstep(trailLife * 0.6f, trailLife, ribbonAge);
    float3 rainbow = 0.62f + 0.38f * cos(6.2831853f * (float3(0.0f, 0.33f, 0.67f)
        + p.x * 3.0f + p.y * 2.0f + time * 0.5f));
    color = mix(color, rainbow, (1.0f - smoothstep(0.0035f - px, 0.0035f + px, ribbon))
        * 0.6f * fade);
    for (int index = 0; index < count; ++index) {
        float4 point = game.trail[index];
        float life = clamp(1.0f - (time - point.z) / trailLife, 0.0f, 1.0f);
        float radius = 0.005f + 0.007f * life * (0.85f + 0.15f * sin(time * 8.0f + float(index)));
        if (length(p - point.xy) - radius > 2.0f * px) continue;
        paintBubble(color, p, point.xy, radius, px, 0.4f + 0.6f * life);
    }
}

void paintEffects(thread float3 &color, float2 p, device const GameState &game,
    float px, float time) {
    // Closing hint: the old bubble that the wand can cross to close a loop.
    if (game.hint.z > 0.0f) {
        float pulse = 0.020f + 0.004f * sin(time * 12.0f);
        float ring = abs(length(p - game.hint.xy) - pulse) - 0.0025f;
        color = mix(color, float3(1.3f, 1.2f, 0.5f),
            (1.0f - smoothstep(-px, px, ring)) * game.hint.z);
    }
    float loopAge = game.loopFx.w;
    if (loopAge < 0.8f) {
        float fade = 1.0f - loopAge / 0.8f;
        float radius = game.loopFx.z * (1.0f + 0.7f * loopAge);
        float ring = abs(length(p - game.loopFx.xy) - radius) - 0.006f * fade;
        color = mix(color, float3(1.2f, 1.15f, 0.7f), (1.0f - smoothstep(-px, px, ring)) * fade);
        for (int index = 0; index < 8; ++index) {
            float angle = float(index) * 0.785398f + loopAge * 2.0f;
            float2 at = game.loopFx.xy + (radius + 0.02f) * float2(cos(angle), sin(angle));
            float2 s = abs(p - at);
            float star = min(s.x * 4.0f + s.y, s.x + s.y * 4.0f) - 0.016f * fade;
            color = mix(color, float3(1.4f, 1.3f, 0.8f), 1.0f - smoothstep(-px, px, star));
        }
    }
    float popAge = game.popFx.z;
    if (popAge < 0.5f) {
        float fade = 1.0f - popAge / 0.5f;
        float3 tone = game.popFx.w > 0.5f ? float3(1.2f, 0.35f, 0.25f) : float3(0.9f, 1.0f, 1.1f);
        for (int index = 0; index < 8; ++index) {
            float angle = float(index) * 0.785398f;
            float2 at = game.popFx.xy + (0.02f + 0.09f * popAge / 0.5f) * float2(cos(angle), sin(angle));
            float d = length(p - at) - 0.007f * fade;
            color = mix(color, tone, (1.0f - smoothstep(-px, px, d)) * fade);
        }
    }
    float tootAge = game.clock.z;
    if (tootAge < 0.6f) {
        float fade = 1.0f - tootAge / 0.6f;
        float radius = tootRadius * (0.15f + 0.85f * tootAge / 0.6f);
        float ring = abs(length(p - game.tootFx.xy) - radius) - 0.010f * fade;
        color = mix(color, float3(0.7f, 1.2f, 1.0f), (1.0f - smoothstep(-px, px, ring)) * fade * 0.8f);
        float inner = abs(length(p - game.tootFx.xy) - radius * 0.7f) - 0.004f * fade;
        color = mix(color, float3(1.0f), (1.0f - smoothstep(-px, px, inner)) * fade * 0.6f);
    }
}

// ---------------------------------------------------------------------------
// Display transfer and overlay (display space, pixel units)

// Linear scene colour to display sRGB with a soft shoulder above 0.8.
float3 toDisplay(float3 linearColor) {
    float3 value = max(linearColor, float3(0.0f));
    float3 rolled = 0.8f + 0.2f * (1.0f - exp(-(value - 0.8f) / 0.2f));
    float3 mapped = select(value, rolled, value > 0.8f);
    return select(1.055f * pow(mapped, float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
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

float3 inkDark() { return float3(0.20f, 0.10f, 0.30f); }
float3 inkShadow() { return float3(0.08f, 0.04f, 0.16f); }

void paintText(thread float3 &color, float2 pixel, float2 origin, float cell,
    int text, float3 ink, float alpha) {
    float shadow = textCoverage(pixel - float2(0.7f * cell), origin, cell, text);
    color = mix(color, inkShadow(), 0.7f * shadow * alpha);
    color = mix(color, ink, textCoverage(pixel, origin, cell, text) * alpha);
}

void paintWaveText(thread float3 &color, float2 pixel, float2 origin, float cell,
    int text, float3 ink, float wave, float time) {
    float shadow = waveCoverage(pixel - float2(0.5f * cell), origin, cell, text, wave, time);
    color = mix(color, inkShadow(), 0.65f * shadow);
    color = mix(color, ink, waveCoverage(pixel, origin, cell, text, wave, time));
}

void paintNumber(thread float3 &color, float2 pixel, float2 origin, float cell,
    uint value, float3 ink, float alpha) {
    float shadow = numberCoverage(pixel - float2(0.7f * cell), origin, cell, value);
    color = mix(color, inkShadow(), 0.7f * shadow * alpha);
    color = mix(color, ink, numberCoverage(pixel, origin, cell, value) * alpha);
}

void paintCentered(thread float3 &color, float2 pixel, float centerX, float y,
    float cell, int text, float3 ink, float alpha) {
    paintText(color, pixel, float2(centerX - 0.5f * textWidth(text, cell), y),
        cell, text, ink, alpha);
}

// Text followed by a number, centred as one line ("COMBO X3", "TIME BONUS +120").
void paintCenteredNumber(thread float3 &color, float2 pixel, float centerX, float y,
    float cell, int text, uint value, bool plus, float3 ink, float alpha) {
    float gap = 4.0f * cell;
    float plusWidth = plus ? textWidth(textPlus, cell) + cell : 0.0f;
    float total = textWidth(text, cell) + gap + plusWidth + numberWidth(value, cell);
    float x = centerX - 0.5f * total;
    paintText(color, pixel, float2(x, y), cell, text, ink, alpha);
    x += textWidth(text, cell) + gap;
    if (plus) {
        paintText(color, pixel, float2(x, y), cell, textPlus, ink, alpha);
        x += plusWidth;
    }
    paintNumber(color, pixel, float2(x, y), cell, value, ink, alpha);
}

// A label on the left and a number on the right of a centred column.
void paintRow(thread float3 &color, float2 pixel, float centerX, float halfWidth,
    float y, float cell, int label, uint value, float3 labelInk, float3 valueInk) {
    paintText(color, pixel, float2(centerX - halfWidth, y), cell, label, labelInk, 1.0f);
    paintNumber(color, pixel, float2(centerX + halfWidth - numberWidth(value, cell), y),
        cell, value, valueInk, 1.0f);
}

float panelMask(float2 pixel, float2 lower, float2 upper, float radius) {
    float2 extent = 0.5f * max(upper - lower, float2(0.0f));
    float corner = min(radius, min(extent.x, extent.y));
    float2 d = abs(pixel - 0.5f * (lower + upper)) - extent + corner;
    float signedDistance = length(max(d, float2(0.0f))) + min(max(d.x, d.y), 0.0f) - corner;
    return clamp(0.5f - signedDistance, 0.0f, 1.0f);
}

// A cheerful rounded card with a candy-pink border.
void paintPanel(thread float3 &color, float2 pixel, float2 lower, float2 upper,
    float ui, float opacity) {
    float outer = panelMask(pixel, lower - 3.0f * ui, upper + 3.0f * ui, 22.0f * ui);
    float inner = panelMask(pixel, lower, upper, 19.0f * ui);
    color = mix(color, float3(1.0f, 0.48f, 0.70f), outer * opacity);
    float stripes = step(0.5f, fract((pixel.x + pixel.y) / (26.0f * ui)));
    float3 paper = mix(float3(1.0f, 0.97f, 0.90f), float3(0.99f, 0.93f, 0.86f), stripes);
    color = mix(color, paper, inner * opacity);
}

float sdHeart(float2 p) {
    p.x = abs(p.x);
    if (p.y + p.x > 1.0f) {
        return length(p - float2(0.25f, 0.75f)) - 0.35355339f;
    }
    float2 a = p - float2(0.0f, 1.0f);
    float2 b = p - 0.5f * max(p.x + p.y, 0.0f);
    return sqrt(min(dot(a, a), dot(b, b))) * sign(p.x - p.y);
}

void paintHeartIcon(thread float3 &color, float2 pixel, float2 center, float size) {
    float2 local = (pixel - center) / size;
    float d = sdHeart(float2(local.x, 0.6f - local.y)) * size;
    color = mix(color, float3(0.45f, 0.05f, 0.15f), clamp(1.5f - abs(d), 0.0f, 1.0f));
    color = mix(color, float3(1.0f, 0.25f, 0.42f), clamp(0.5f - d - 1.0f, 0.0f, 1.0f));
}

void paintJellyIcon(thread float3 &color, float2 pixel, float2 center, float size,
    uint kind) {
    float2 q = (pixel - center) / size;
    if (dot(q, q) > 4.0f) return;
    float3 tint = toDisplay(jellyTint(kind));
    float aa = 1.0f / size;
    for (int index = 0; index < 3; ++index) {
        float x0 = -0.45f + 0.45f * float(index);
        float d = max(abs(q.x - x0 - 0.08f * sin(q.y * 6.0f)) - 0.08f, max(0.1f - q.y, q.y - 1.0f));
        color = mix(color, tint * 0.8f, 1.0f - smoothstep(-aa, aa, d));
    }
    float bell = max(length(q * float2(1.0f, 1.15f)) - 0.8f, q.y - 0.25f);
    color = mix(color, inkDark(), 1.0f - smoothstep(-aa, aa, bell - 0.12f));
    color = mix(color, tint, 1.0f - smoothstep(-aa, aa, bell));
    for (int side = -1; side <= 1; side += 2) {
        float eye = length(q - float2(0.25f * float(side), -0.12f)) - 0.1f;
        color = mix(color, inkShadow(), 1.0f - smoothstep(-aa, aa, eye));
    }
}

void paintTootIcon(thread float3 &color, float2 pixel, float2 center, float size) {
    float d = length(pixel - center) - size;
    color = mix(color, float3(0.78f, 0.95f, 1.0f), clamp(0.5f - d, 0.0f, 1.0f) * 0.8f);
    color = mix(color, float3(0.25f, 0.55f, 0.75f), clamp(1.2f - abs(d), 0.0f, 1.0f));
    float shine = length(pixel - center + size * float2(0.35f, 0.35f)) - size * 0.25f;
    color = mix(color, float3(1.0f), clamp(0.5f - shine, 0.0f, 1.0f));
}

void paintHudBar(thread float3 &color, float2 pixel, float2 resolution,
    device const GameState &game, float time, float ui) {
    float2 lower = float2(14.0f * ui, 10.0f * ui);
    float2 upper = float2(resolution.x - 14.0f * ui, 60.0f * ui);
    if (pixel.y > upper.y + 6.0f * ui) return;
    paintPanel(color, pixel, lower, upper, ui, 0.9f);
    float cell = 3.0f * ui;
    float textY = 0.5f * (lower.y + upper.y) - 3.5f * cell;
    float centerY = 0.5f * (lower.y + upper.y);
    float x = lower.x + 18.0f * ui;
    paintText(color, pixel, float2(x, textY), cell, textShift, inkDark(), 1.0f);
    x += textWidth(textShift, cell) + 4.0f * cell;
    paintNumber(color, pixel, float2(x, textY), cell, game.flow.y + 1u,
        float3(0.90f, 0.25f, 0.50f), 1.0f);
    x = lower.x + 190.0f * ui;
    paintText(color, pixel, float2(x, textY), cell, textScore, inkDark(), 1.0f);
    x += textWidth(textScore, cell) + 4.0f * cell;
    paintNumber(color, pixel, float2(x, textY), cell, game.score.x,
        float3(0.90f, 0.25f, 0.50f), 1.0f);

    // The order ticket: caught / ordered per colour, golden jellies as a bonus.
    x = 0.36f * resolution.x;
    uint4 quota = game.quota;
    uint4 caught = game.caught;
    for (uint kind = 0u; kind < 4u; ++kind) {
        uint wanted = kind == 0u ? quota.x : kind == 1u ? quota.y : kind == 2u ? quota.z : 0u;
        uint have = kind == 0u ? caught.x : kind == 1u ? caught.y : kind == 2u ? caught.z : caught.w;
        if (kind < 3u && wanted == 0u) continue;
        if (kind == 3u && have == 0u) continue;
        paintJellyIcon(color, pixel, float2(x + 11.0f * ui, centerY - 2.0f * ui), 12.0f * ui, kind);
        x += 30.0f * ui;
        bool done = kind < 3u && have >= wanted;
        float3 ink = inkDark();
        if (done) ink = float3(0.15f, 0.62f, 0.25f);
        paintNumber(color, pixel, float2(x, textY), cell, kind < 3u ? min(have, wanted) : have, ink, 1.0f);
        x += numberWidth(kind < 3u ? min(have, wanted) : have, cell) + cell;
        if (kind < 3u) {
            paintText(color, pixel, float2(x, textY), cell, textSlash, ink, 1.0f);
            x += textWidth(textSlash, cell) + cell;
            paintNumber(color, pixel, float2(x, textY), cell, wanted, ink, 1.0f);
            x += numberWidth(wanted, cell);
        }
        x += 22.0f * ui;
    }

    x = 0.665f * resolution.x;
    uint seconds = uint(ceil(max(game.clock.x, 0.0f)));
    bool hurry = game.flow.x == phasePlaying && game.clock.x < 10.0f;
    float3 timeInk = inkDark();
    if (hurry && fract(time * 2.0f) < 0.5f) timeInk = float3(0.95f, 0.15f, 0.20f);
    paintText(color, pixel, float2(x, textY), cell, textTime, inkDark(), 1.0f);
    x += textWidth(textTime, cell) + 4.0f * cell;
    paintNumber(color, pixel, float2(x, textY), cell, seconds, timeInk, 1.0f);

    float right = upper.x - 22.0f * ui;
    for (uint index = 0u; index < min(game.flow.z, 9u); ++index) {
        paintHeartIcon(color, pixel, float2(right - float(index) * 30.0f * ui, centerY), 13.0f * ui);
    }
    right -= float(min(game.flow.z, 9u)) * 30.0f * ui + 14.0f * ui;
    for (uint index = 0u; index < min(game.flow.w, 9u); ++index) {
        paintTootIcon(color, pixel, float2(right - float(index) * 24.0f * ui, centerY), 8.5f * ui);
    }
}

void paintWorldLabels(thread float3 &color, float2 pixel, float height,
    device const GameState &game, float ui) {
    float cell = 3.2f * ui;
    // Points rise from the loop that earned them.
    float loopAge = game.loopFx.w;
    if (game.loopInfo.x > 0u && loopAge < 1.3f) {
        float alpha = 1.0f - smoothstep(0.9f, 1.3f, loopAge);
        float2 at = game.loopFx.xy * height - float2(0.0f, (20.0f + 60.0f * loopAge) * ui);
        float pop = 1.0f + 0.6f * exp(-loopAge * 10.0f);
        float big = cell * 1.4f * pop;
        float width = textWidth(textPlus, big) + big + numberWidth(game.loopInfo.x, big);
        float2 origin = at - float2(0.5f * width, 3.5f * big);
        paintText(color, pixel, origin, big, textPlus, float3(1.0f, 0.92f, 0.30f), alpha);
        paintNumber(color, pixel, origin + float2(textWidth(textPlus, big) + big, 0.0f), big,
            game.loopInfo.x, float3(1.0f, 0.92f, 0.30f), alpha);
    }
    float popAge = game.popFx.z;
    if (popAge < 0.7f) {
        float alpha = 1.0f - smoothstep(0.4f, 0.7f, popAge);
        int text = textPop;
        if (game.popFx.w > 0.5f) text = textOuch;
        float3 ink = game.popFx.w > 0.5f ? float3(1.0f, 0.35f, 0.30f) : float3(0.85f, 0.97f, 1.0f);
        float2 at = game.popFx.xy * height - float2(0.0f, (30.0f + 40.0f * popAge) * ui);
        paintCentered(color, pixel, at.x, at.y - 3.5f * cell, cell, text, ink, alpha);
    }
}

void paintNotice(thread float3 &color, float2 pixel, float2 resolution,
    device const GameState &game, float ui) {
    float age = game.clock.y;
    if (age >= 1.6f) return;
    int text = int(game.notice.x);
    float alpha = 1.0f - smoothstep(1.2f, 1.6f, age);
    float pop = 1.0f + 0.5f * exp(-age * 9.0f) * cos(age * 25.0f);
    float cell = 5.0f * ui * pop;
    float y = 0.205f * resolution.y - 3.5f * cell;
    float3 ink = float3(1.0f, 0.85f, 0.30f);
    if (text == textOuch || text == textGrumbleLoop || text == textNoToots) {
        ink = float3(1.0f, 0.40f, 0.36f);
    } else if (text == textToot) {
        ink = float3(0.62f, 1.0f, 0.92f);
    } else if (text == textHurry) {
        ink = float3(1.0f, 0.55f, 0.25f);
    }
    if (text == textCombo) {
        paintCenteredNumber(color, pixel, 0.5f * resolution.x, y, cell, textCombo,
            game.notice.y, false, ink, alpha);
    } else {
        paintCentered(color, pixel, 0.5f * resolution.x, y, cell, text, ink, alpha);
    }
}

void paintScreens(thread float3 &color, float2 pixel, float2 resolution,
    device const GameState &game, float time, float ui) {
    uint phase = game.flow.x;
    float centerX = 0.5f * resolution.x;
    float H = resolution.y;
    float blink = 0.55f + 0.45f * sin(time * 5.0f);
    float3 accent = float3(0.90f, 0.25f, 0.50f);
    if (phase == phaseTitle) {
        color = mix(color, float3(0.05f, 0.12f, 0.25f), 0.18f);
        float2 lower = float2(centerX - 0.37f * resolution.x, 0.08f * H);
        float2 upper = float2(centerX + 0.37f * resolution.x, 0.70f * H);
        paintPanel(color, pixel, lower, upper, ui, 0.88f);
        float cell = min(9.0f * ui, 0.68f * resolution.x / 95.0f);
        paintWaveText(color, pixel, float2(centerX - 0.5f * textWidth(textTitle, cell),
            0.12f * H), cell, textTitle, float3(1.0f, 0.42f, 0.66f), 6.0f * ui, time);
        float small = min(3.0f * ui, 0.68f * resolution.x / 282.0f);
        paintCentered(color, pixel, centerX, 0.27f * H, small, textIntro1, inkDark(), 1.0f);
        paintCentered(color, pixel, centerX, 0.31f * H, small, textIntro2, inkDark(), 1.0f);
        paintCentered(color, pixel, centerX, 0.38f * H, small, textIntro3, float3(0.10f, 0.45f, 0.60f), 1.0f);
        paintCentered(color, pixel, centerX, 0.42f * H, small, textIntro4, float3(0.10f, 0.45f, 0.60f), 1.0f);
        paintCentered(color, pixel, centerX, 0.46f * H, small, textIntro5, float3(0.10f, 0.45f, 0.60f), 1.0f);
        paintCentered(color, pixel, centerX, 0.50f * H, small, textIntro6, float3(0.80f, 0.30f, 0.15f), 1.0f);
        for (uint kind = 0u; kind < 4u; ++kind) {
            paintJellyIcon(color, pixel, float2(centerX + (float(kind) - 1.5f) * 60.0f * ui,
                0.565f * H + 6.0f * sin(time * 3.0f + float(kind)) * ui), 16.0f * ui, kind);
        }
        paintCentered(color, pixel, centerX, 0.62f * H, 4.0f * ui, textPressStart, accent, blink);
        if (game.score.y > 0u) {
            paintCenteredNumber(color, pixel, centerX, 0.74f * H, 3.0f * ui, textBest,
                game.score.y, false, float3(1.0f, 0.95f, 0.70f), 1.0f);
        }
        return;
    }
    if (phase == phaseBriefing) {
        float2 lower = float2(centerX - 0.24f * resolution.x, 0.22f * H);
        float2 upper = float2(centerX + 0.24f * resolution.x, 0.62f * H);
        paintPanel(color, pixel, lower, upper, ui, 0.9f);
        paintCenteredNumber(color, pixel, centerX, 0.25f * H, 7.0f * ui, textShift,
            game.flow.y + 1u, false, accent, 1.0f);
        paintCentered(color, pixel, centerX, 0.35f * H, 4.0f * ui, textOrderUp, inkDark(), 1.0f);
        uint4 quota = game.quota;
        uint kinds = (quota.x > 0u ? 1u : 0u) + (quota.y > 0u ? 1u : 0u) + (quota.z > 0u ? 1u : 0u);
        float slot = 120.0f * ui;
        float x = centerX - 0.5f * slot * float(kinds) + 0.5f * slot;
        float cell = 4.5f * ui;
        for (uint kind = 0u; kind < 3u; ++kind) {
            uint wanted = kind == 0u ? quota.x : kind == 1u ? quota.y : quota.z;
            if (wanted == 0u) continue;
            paintJellyIcon(color, pixel, float2(x - 22.0f * ui, 0.455f * H), 18.0f * ui, kind);
            paintNumber(color, pixel, float2(x + 4.0f * ui, 0.455f * H - 3.5f * cell), cell,
                wanted, inkDark(), 1.0f);
            x += slot;
        }
        paintCenteredNumber(color, pixel, centerX, 0.52f * H, 3.5f * ui, textTime,
            uint(ceil(game.clock.x)), false, inkDark(), 1.0f);
        paintCentered(color, pixel, centerX, 0.575f * H, min(2.6f * ui,
            0.44f * resolution.x / 222.0f), textGetReady, float3(0.10f, 0.45f, 0.60f), 1.0f);
        return;
    }
    if (phase == phasePlaying) return;
    color = mix(color, float3(0.05f, 0.12f, 0.25f), 0.25f);
    float2 lower = float2(centerX - 0.27f * resolution.x, 0.20f * H);
    float2 upper = float2(centerX + 0.27f * resolution.x, 0.70f * H);
    paintPanel(color, pixel, lower, upper, ui, 0.92f);
    float cell = 3.5f * ui;
    float columnHalf = 0.17f * resolution.x;
    float bigCell = min(6.0f * ui, 0.5f * resolution.x / 107.0f);
    if (phase == phaseCleared) {
        paintWaveText(color, pixel, float2(centerX - 0.5f * textWidth(textOrderComplete, bigCell),
            0.25f * H), bigCell, textOrderComplete, float3(0.20f, 0.70f, 0.35f), 3.0f * ui, time);
        paintCenteredNumber(color, pixel, centerX, 0.38f * H, cell, textTimeBonus,
            game.score.w, true, inkDark(), 1.0f);
        paintRow(color, pixel, centerX, columnHalf, 0.45f * H, cell, textScore, game.score.x,
            inkDark(), accent);
        paintRow(color, pixel, centerX, columnHalf, 0.50f * H, cell, textBestCombo, game.stats.y,
            inkDark(), accent);
        paintCentered(color, pixel, centerX, 0.60f * H, 3.2f * ui, textNextShift, accent,
            game.control.z > 0.6f ? blink : 0.0f);
    } else if (phase == phaseGameOver) {
        int reason = int(game.notice.z);
        paintWaveText(color, pixel, float2(centerX - 0.5f * textWidth(reason, bigCell),
            0.25f * H), bigCell, reason, float3(0.95f, 0.30f, 0.30f), 3.0f * ui, time);
        paintRow(color, pixel, centerX, columnHalf, 0.40f * H, cell, textScore, game.score.x,
            inkDark(), accent);
        paintRow(color, pixel, centerX, columnHalf, 0.46f * H, cell, textBest, game.score.y,
            inkDark(), accent);
        paintCentered(color, pixel, centerX, 0.58f * H, 3.2f * ui, textRetry, accent,
            game.control.z > 0.6f ? blink : 0.0f);
    } else {
        paintWaveText(color, pixel, float2(centerX - 0.5f * textWidth(textAllServed, bigCell),
            0.24f * H), bigCell, textAllServed, float3(1.0f, 0.45f, 0.70f), 4.0f * ui, time);
        paintCentered(color, pixel, centerX, 0.33f * H, cell, textTownFed,
            float3(0.10f, 0.45f, 0.60f), 1.0f);
        paintRow(color, pixel, centerX, columnHalf, 0.40f * H, cell, textFinalScore, game.score.x,
            inkDark(), accent);
        paintRow(color, pixel, centerX, columnHalf, 0.45f * H, cell, textBest, game.score.y,
            inkDark(), accent);
        paintRow(color, pixel, centerX, columnHalf, 0.50f * H, cell, textJellies, game.stats.x,
            inkDark(), accent);
        paintRow(color, pixel, centerX, columnHalf, 0.55f * H, cell, textBestCombo, game.stats.y,
            inkDark(), accent);
        paintCentered(color, pixel, centerX, 0.62f * H, 3.2f * ui, textPlayAgain, accent,
            game.control.z > 0.6f ? blink : 0.0f);
    }
}

void paintOverlay(thread float3 &color, float2 pixel, float2 resolution,
    device const GameState &game, float time) {
    float ui = min(resolution.x / 1280.0f, resolution.y / 800.0f);
    uint phase = game.flow.x;
    if (phase != phaseTitle) {
        paintWorldLabels(color, pixel, resolution.y, game, ui);
        if (phase == phasePlaying || phase == phaseBriefing) {
            paintNotice(color, pixel, resolution, game, ui);
        }
        paintHudBar(color, pixel, resolution, game, time, ui);
    }
    paintScreens(color, pixel, resolution, game, time, ui);
}

fragment float4 lagoonFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> backdropTexture [[texture(1)]],
    texture2d<float> sandTexture [[texture(2)]],
    texture2d<float> jellyTexture [[texture(3)]],
    texture2d<float> fruitTexture [[texture(4)]],
    texture2d<float> pebbleTexture [[texture(5)]],
    texture2d<float> shellTexture [[texture(6)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 pixel = in.uv * resolution;
    float height = max(resolution.y, 1.0f);
    float aspect = resolution.x / height;
    float2 p = pixel / height;
    float px = 1.0f / height;
    float time = u.resolutionTime.z;

    float3 color = waterColor(p, aspect, time, backdropTexture);
    paintSkyFlowers(color, p, aspect, time, px);
    paintSeabed(color, p, aspect, px, time, height, sandTexture, fruitTexture,
        pebbleTexture, shellTexture);
    paintAmbientBubbles(color, p, aspect, time, px);
    for (int index = 0; index < jellyCount; ++index) {
        paintJelly(color, p, game.jellies[index], px, time, jellyTexture);
    }
    for (int index = 0; index < grumbleCapacity; ++index) {
        paintGrumble(color, p, game.grumbles[index], px, time, game.wand.xy, index);
    }
    paintTrail(color, p, game, px, time);
    paintSeahorse(color, p, game, px, time);
    paintEffects(color, p, game, px, time);

    float vignette = 1.0f - 0.22f * smoothstep(0.45f, 0.95f, length(in.uv - 0.5f));
    float3 display = toDisplay(color * vignette);
    paintOverlay(display, pixel, resolution, game, time);
    return float4(clamp(display, float3(0.0f), float3(1.0f)), 1.0f);
}

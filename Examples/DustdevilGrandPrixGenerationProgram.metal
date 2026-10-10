#include <metal_stdlib>
using namespace metal;

// Dustdevil Grand Prix: a pseudo-3D desert rally for the generic GPU Program
// node, seen from a chase camera behind the player's car.
//
// Eight cars race three laps on a winding, hilly desert road. The Trackpad is
// the steering pad: its X position picks the line across the road (the car
// steers towards it) and its Y position is the pedal (upper part gas, middle
// coast, bottom brake). Action/Space fires one of a few nitro boosts. In a
// bend the car is pushed towards the outside; up to its grip limit the car
// holds the chosen line by itself, beyond it the car slides wide, so hard
// bends and hairpins need a lift or a dab of brake. Off-road sand slows the
// car, cacti, hoodoo rocks and billboards beside the road end in a crash, and
// dust devils wander across the road and shove the car sideways. Finish in
// the top three to reach the next race; the cup has three races with points
// for every finish and a trophy at the end. Missing the top three retries the
// race.
//
// All game state lives in one GPU buffer. Single-thread kernels advance the
// race once per Loop call (advanceRace) and project the road for the current
// camera (projectView): a classic segment projection fills one row record per
// screen row and a depth-sorted sprite list. The present phase draws the road
// and sky (worldFragment), the sprites as instanced quads with alpha blending
// (spriteVertex/spriteFragment), and the HUD and screens (hudFragment).
//
// World units are metres. A lap is a loop of 6 m segments; lateral positions
// are measured in road half-widths (0 is the centre line, +-1 the road edge).
// Screen coordinates are pixels with y down, matching the Trackpad.
//
// Generated textures from the Asset Cache, sampled as sRGB albedo:
//   texture(1) asset0 desert panorama backdrop (FLUX.2 Klein 4B, 1024 x 1024),
//   texture(2) asset1 asphalt, texture(3) asset2 desert sand,
//   texture(4) asset3 red sandstone, texture(5) asset4 weathered wood,
//   texture(6) asset5 retro roadside poster art; SDXS 512 each.
//
// Parameters, in declared order: laps (1..5, default 3), rivalPace (0.8..1.2,
// default 1), nitroPerRace (0..5, default 3), firstRace (1..3, default 1).
// When all four are zero the defaults apply.

// ---------------------------------------------------------------------------
// Rules and camera, in metres, seconds and pixels.

constant float segmentLength = 6.0f;
constant float roadHalfWidth = 6.0f;
constant float cameraHeight = 3.4f;
constant float cameraBack = 6.6f;      // camera distance behind the player car
constant float focalScale = 0.92f;     // focal length in screen heights
constant float horizonScale = 0.42f;   // flat-ground horizon in screen heights
constant float nearDepth = 1.0f;
constant int drawSegments = 170;
constant int spriteSegments = 120;
constant int maxSegments = 640;
constant int maxSprites = 128;
constant int scenerySprites = 112;  // the rest is kept for cars and dust devils
constant int maxRows = 4096;
constant int carCount = 8;
constant int minimapCapacity = 96;

constant float maxSpeed = 70.0f;       // 252 km/h
constant float nitroSpeed = 88.0f;     // 317 km/h
constant float offroadSpeed = 26.0f;
constant float nitroSeconds = 3.0f;
constant float gripDrift = 13.6f;      // sideways push: gripDrift * (speed/maxSpeed)^2 * curve
constant float carHalfWidth = 0.16f;   // road half-widths (0.95 m)
constant float carLength = 4.4f;
constant float laneSpacing = 0.6f;
constant float countdownSeconds = 3.4f;
constant float finishSeconds = 4.0f;

constant uint phaseTitle = 0u;     // demo race behind the title card
constant uint phaseCountdown = 1u;
constant uint phaseRacing = 2u;
constant uint phaseFinish = 3u;    // the player has crossed the line
constant uint phaseResults = 4u;
constant uint phaseChampion = 5u;

constant float kindPost = 1.0f;
constant float kindCactus = 2.0f;
constant float kindHoodoo = 3.0f;
constant float kindMesa = 4.0f;
constant float kindBillboard = 5.0f;
constant float kindGantry = 6.0f;
constant float kindDevil = 7.0f;
constant float kindCar = 8.0f;

constant float finishPoints[8] = {10.0f, 8.0f, 6.0f, 5.0f, 4.0f, 3.0f, 2.0f, 1.0f};
// Rival top speed as a fraction of maxSpeed (car 1..7) plus a per-race
// offset. Car 0 is the player.
constant float rivalSkill[8] = {0.95f, 0.94f, 0.93f, 0.92f, 0.91f, 0.90f, 0.89f, 0.88f};
constant float raceSkill[3] = {-0.01f, -0.004f, 0.012f};
// Preferred lane per car (-1, 0, 1 times laneSpacing).
constant float preferredLane[8] = {0.0f, -1.0f, 1.0f, 0.0f, -1.0f, 1.0f, 0.0f, 1.0f};

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

struct Car {
    float4 motion;  // lap distance (m, negative on the grid), lateral (half-widths), speed (m/s), lane target
    float4 timers;  // nitro seconds, bump seconds, finish time (s, 0 while running), top speed (m/s)
    uint4 info;     // laps completed, finish order (0 while running), lane cooldown ticks, braking (0 or 1)
};

struct Sprite {
    float4 rect;    // x0, y0, x1, y1 in pixels
    float4 meta;    // kind, depth (m), clip row (px; rows at or below are hidden), size multiplier
    float4 extra;   // kind-specific: variant or car index, steering, brake, effect bits
};

// Buffer layout with Metal alignment (float4/uint4 = 16 bytes, align 16):
//   flow .. sketch       10 * 16 =    160 bytes at offset      0
//   results[8]            8 * 16 =    128 bytes at offset    160
//   minimap[96]          96 * 16 =   1536 bytes at offset    288
//   cars[8]               8 * 48 =    384 bytes at offset   1824 (Car = 3 * 16)
//   sprites[128]        128 * 48 =   6144 bytes at offset   2208 (Sprite = 3 * 16)
//   segments[640]       640 * 16 =  10240 bytes at offset   8352
//   rows[4096]         4096 * 16 =  65536 bytes at offset  18592
//   sizeof(GameState)              =  84128 bytes (a multiple of 16).
// The workflow declares a 98304-byte "game" buffer, which covers it.
struct GameState {
    uint4 flow;      // phase, race index (0..2), laps per race, sprite count
    uint4 tally;     // cup points before this race, points of this race, player place, cars finished
    uint4 notice;    // text id, number, segment count, unused
    uint4 control;   // last action count, nitro charges, last place (overtakes), first race index
    float4 timing;   // race seconds, lap seconds, best lap seconds, seconds in phase
    float4 driver;   // target lateral, gas 0..1, brake 0..1, slide amount
    float4 effects;  // notice seconds, sky scroll, dust devil push (half-widths/s), crash seconds
    float4 hazard;   // dust devil cooldown, steering visual (-1..1), last lap seconds, rival pace
    float4 view;     // focal length px, horizon row px, camera height (m above datum), lap length m
    float4 sketch;   // minimap stride (segments per point), minimap point count, unused, unused
    float4 results[8];     // car index, time (s), points, unused, in finishing order
    float4 minimap[96];    // x, y in 0..1, unused, unused
    Car cars[8];
    Sprite sprites[128];
    float4 segments[640];  // curve (m/segment^2), start height (m), unused, unused
    float4 rows[4096];     // centre x px, half width px (negative for sky), 1/depth, lap distance m
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
constant uchar textPool[814] = {
    68, 85, 83, 84, 68, 69, 86, 73, 76, 32, 71, 82, 65, 78, 68, 32,
    80, 82, 73, 88, 65, 32, 84, 72, 82, 69, 69, 32, 82, 65, 67, 69,
    32, 68, 69, 83, 69, 82, 84, 32, 82, 65, 76, 76, 89, 68, 82, 65,
    71, 32, 76, 69, 70, 84, 32, 79, 82, 32, 82, 73, 71, 72, 84, 32,
    84, 79, 32, 80, 73, 67, 75, 32, 89, 79, 85, 82, 32, 76, 73, 78,
    69, 68, 82, 65, 71, 32, 85, 80, 32, 70, 79, 82, 32, 71, 65, 83,
    32, 45, 32, 68, 82, 65, 71, 32, 68, 79, 87, 78, 32, 84, 79, 32,
    66, 82, 65, 75, 69, 83, 80, 65, 67, 69, 32, 70, 73, 82, 69, 83,
    32, 65, 32, 78, 73, 84, 82, 79, 32, 66, 79, 79, 83, 84, 69, 65,
    83, 69, 32, 79, 70, 70, 32, 73, 78, 32, 72, 65, 82, 68, 32, 66,
    69, 78, 68, 83, 32, 79, 82, 32, 89, 79, 85, 32, 83, 76, 73, 68,
    69, 32, 87, 73, 68, 69, 68, 79, 68, 71, 69, 32, 84, 72, 69, 32,
    68, 85, 83, 84, 32, 68, 69, 86, 73, 76, 83, 32, 65, 78, 68, 32,
    84, 72, 69, 32, 67, 65, 67, 84, 73, 70, 73, 78, 73, 83, 72, 32,
    73, 78, 32, 84, 72, 69, 32, 84, 79, 80, 32, 51, 32, 84, 79, 32,
    82, 69, 65, 67, 72, 32, 84, 72, 69, 32, 78, 69, 88, 84, 32, 82,
    65, 67, 69, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 84,
    79, 32, 83, 84, 65, 82, 84, 82, 65, 67, 69, 79, 70, 77, 69, 83,
    65, 32, 76, 79, 79, 80, 82, 65, 84, 84, 76, 69, 83, 78, 65, 75,
    69, 32, 82, 73, 68, 71, 69, 68, 85, 83, 84, 68, 69, 86, 73, 76,
    32, 67, 65, 78, 89, 79, 78, 76, 65, 80, 80, 79, 83, 84, 73, 77,
    69, 66, 69, 83, 84, 75, 77, 47, 72, 78, 73, 84, 82, 79, 71, 79,
    33, 70, 73, 78, 65, 76, 32, 76, 65, 80, 33, 78, 73, 84, 82, 79,
    33, 78, 79, 32, 78, 73, 84, 82, 79, 32, 76, 69, 70, 84, 79, 70,
    70, 32, 82, 79, 65, 68, 33, 67, 82, 65, 83, 72, 33, 68, 85, 83,
    84, 32, 68, 69, 86, 73, 76, 33, 66, 85, 77, 80, 33, 66, 69, 83,
    84, 32, 76, 65, 80, 33, 83, 76, 73, 68, 73, 78, 71, 32, 87, 73,
    68, 69, 32, 45, 32, 69, 65, 83, 69, 32, 79, 70, 70, 33, 70, 73,
    78, 73, 83, 72, 69, 68, 82, 69, 83, 85, 76, 84, 83, 81, 85, 65,
    76, 73, 70, 73, 69, 68, 33, 32, 80, 82, 69, 83, 83, 32, 83, 80,
    65, 67, 69, 32, 70, 79, 82, 32, 84, 72, 69, 32, 78, 69, 88, 84,
    32, 82, 65, 67, 69, 84, 79, 80, 32, 51, 32, 78, 69, 69, 68, 69,
    68, 32, 45, 32, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32,
    84, 79, 32, 82, 69, 84, 82, 89, 81, 85, 65, 76, 73, 70, 73, 69,
    68, 33, 32, 80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 70,
    79, 82, 32, 84, 72, 69, 32, 84, 82, 79, 80, 72, 89, 71, 82, 65,
    78, 68, 32, 80, 82, 73, 88, 32, 67, 79, 77, 80, 76, 69, 84, 69,
    33, 71, 79, 76, 68, 32, 84, 82, 79, 80, 72, 89, 83, 73, 76, 86,
    69, 82, 32, 84, 82, 79, 80, 72, 89, 66, 82, 79, 78, 90, 69, 32,
    84, 82, 79, 80, 72, 89, 67, 85, 80, 32, 80, 79, 73, 78, 84, 83,
    80, 82, 69, 83, 83, 32, 83, 80, 65, 67, 69, 32, 84, 79, 32, 80,
    76, 65, 89, 32, 65, 71, 65, 73, 78, 89, 79, 85, 66, 76, 65, 90,
    69, 67, 79, 89, 79, 84, 69, 86, 73, 80, 69, 82, 83, 73, 68, 69,
    87, 73, 78, 68, 69, 82, 77, 69, 83, 65, 32, 77, 65, 88, 74, 65,
    67, 75, 82, 65, 66, 66, 73, 84, 84, 85, 77, 66, 76, 69, 87, 69,
    69, 68, 83, 84, 78, 68, 82, 68, 84, 72, 71, 65, 83, 67, 79, 65,
    83, 84, 66, 82, 65, 75, 69, 43, 47, 67, 65, 67, 84, 85, 83, 32,
    67, 79, 76, 65, 78, 69, 88, 84, 32, 71, 65, 83, 32, 57, 48, 32,
    77, 73, 68, 85, 83, 84, 68, 69, 86, 73, 76, 32, 71, 80, 83, 78,
    65, 75, 69, 32, 77, 79, 84, 69, 76, 79, 86, 69, 82, 84, 65, 75,
    69, 33, 68, 69, 77, 79, 32, 82, 65, 67, 69, 80, 65, 68,
};
constant int textRanges[130] = {
    0, 20,  // DUSTDEVIL GRAND PRIX
    20, 25,  // A THREE RACE DESERT RALLY
    45, 36,  // DRAG LEFT OR RIGHT TO PICK YOUR LINE
    81, 36,  // DRAG UP FOR GAS - DRAG DOWN TO BRAKE
    117, 25,  // SPACE FIRES A NITRO BOOST
    142, 40,  // EASE OFF IN HARD BENDS OR YOU SLIDE WIDE
    182, 35,  // DODGE THE DUST DEVILS AND THE CACTI
    217, 42,  // FINISH IN THE TOP 3 TO REACH THE NEXT RACE
    259, 20,  // PRESS SPACE TO START
    279, 4,  // RACE
    283, 2,  // OF
    285, 9,  // MESA LOOP
    294, 17,  // RATTLESNAKE RIDGE
    311, 16,  // DUSTDEVIL CANYON
    327, 3,  // LAP
    330, 3,  // POS
    333, 4,  // TIME
    337, 4,  // BEST
    341, 4,  // KM/H
    345, 5,  // NITRO
    350, 3,  // GO!
    353, 10,  // FINAL LAP!
    363, 6,  // NITRO!
    369, 13,  // NO NITRO LEFT
    382, 9,  // OFF ROAD!
    391, 6,  // CRASH!
    397, 11,  // DUST DEVIL!
    408, 5,  // BUMP!
    413, 9,  // BEST LAP!
    422, 24,  // SLIDING WIDE - EASE OFF!
    446, 8,  // FINISHED
    454, 7,  // RESULTS
    461, 40,  // QUALIFIED! PRESS SPACE FOR THE NEXT RACE
    501, 35,  // TOP 3 NEEDED - PRESS SPACE TO RETRY
    536, 37,  // QUALIFIED! PRESS SPACE FOR THE TROPHY
    573, 20,  // GRAND PRIX COMPLETE!
    593, 11,  // GOLD TROPHY
    604, 13,  // SILVER TROPHY
    617, 13,  // BRONZE TROPHY
    630, 10,  // CUP POINTS
    640, 25,  // PRESS SPACE TO PLAY AGAIN
    665, 3,  // YOU
    668, 5,  // BLAZE
    673, 6,  // COYOTE
    679, 5,  // VIPER
    684, 10,  // SIDEWINDER
    694, 8,  // MESA MAX
    702, 10,  // JACKRABBIT
    712, 10,  // TUMBLEWEED
    722, 2,  // ST
    724, 2,  // ND
    726, 2,  // RD
    728, 2,  // TH
    730, 3,  // GAS
    733, 5,  // COAST
    738, 5,  // BRAKE
    743, 1,  // +
    744, 1,  // /
    745, 11,  // CACTUS COLA
    756, 14,  // NEXT GAS 90 MI
    770, 12,  // DUSTDEVIL GP
    782, 11,  // SNAKE MOTEL
    793, 9,  // OVERTAKE!
    802, 9,  // DEMO RACE
    811, 3,  // PAD
};
constant int textTitle = 0;
constant int textSubtitle = 1;
constant int textHelp1 = 2;
constant int textHelp2 = 3;
constant int textHelp3 = 4;
constant int textHelp4 = 5;
constant int textHelp5 = 6;
constant int textHelp6 = 7;
constant int textPressStart = 8;
constant int textRace = 9;
constant int textOf = 10;
constant int textTrack1 = 11;
constant int textTrack2 = 12;
constant int textTrack3 = 13;
constant int textLap = 14;
constant int textPos = 15;
constant int textTime = 16;
constant int textBest = 17;
constant int textKmh = 18;
constant int textNitro = 19;
constant int textGo = 20;
constant int textFinalLap = 21;
constant int textNitroOn = 22;
constant int textNoNitro = 23;
constant int textOffRoad = 24;
constant int textCrash = 25;
constant int textDustDevil = 26;
constant int textBump = 27;
constant int textBestLap = 28;
constant int textSlide = 29;
constant int textFinished = 30;
constant int textResults = 31;
constant int textQualified = 32;
constant int textRetry = 33;
constant int textToTrophy = 34;
constant int textCupComplete = 35;
constant int textGold = 36;
constant int textSilver = 37;
constant int textBronze = 38;
constant int textCupPoints = 39;
constant int textPlayAgain = 40;
constant int textName0 = 41;
constant int textName1 = 42;
constant int textName2 = 43;
constant int textName3 = 44;
constant int textName4 = 45;
constant int textName5 = 46;
constant int textName6 = 47;
constant int textName7 = 48;
constant int textSt = 49;
constant int textNd = 50;
constant int textRd = 51;
constant int textTh = 52;
constant int textGas = 53;
constant int textCoast = 54;
constant int textBrake = 55;
constant int textPlus = 56;
constant int textSlash = 57;
constant int textBoard1 = 58;
constant int textBoard2 = 59;
constant int textBoard3 = 60;
constant int textBoard4 = 61;
constant int textOvertake = 62;
constant int textDemo = 63;
constant int textPad = 64;

// Track pieces: enter, hold and leave segments, curve (m per segment^2,
// positive bends right), and the height change over the piece (m). Each
// track's height changes sum to zero so the lap closes smoothly.
constant float trackPieces[195] = {
    // MESA LOOP
    0.00f, 36.00f, 0.00f, 0.00f, 0.00f,
    12.00f, 30.00f, 12.00f, 0.12f, 12.00f,
    10.00f, 30.00f, 10.00f, 0.00f, -12.00f,
    14.00f, 26.00f, 14.00f, 0.18f, 0.00f,
    8.00f, 20.00f, 8.00f, -0.06f, 16.00f,
    12.00f, 24.00f, 12.00f, 0.12f, -16.00f,
    10.00f, 34.00f, 10.00f, 0.00f, 0.00f,
    14.00f, 22.00f, 14.00f, 0.18f, 10.00f,
    10.00f, 16.00f, 10.00f, -0.12f, -10.00f,
    12.00f, 28.00f, 12.00f, 0.12f, 0.00f,
    0.00f, 10.00f, 0.00f, 0.00f, 0.00f,
    // RATTLESNAKE RIDGE
    0.00f, 30.00f, 0.00f, 0.00f, 0.00f,
    10.00f, 18.00f, 10.00f, 0.18f, 20.00f,
    8.00f, 14.00f, 8.00f, -0.18f, 0.00f,
    10.00f, 18.00f, 10.00f, 0.18f, -20.00f,
    10.00f, 40.00f, 10.00f, 0.00f, 24.00f,
    12.00f, 20.00f, 12.00f, 0.24f, -24.00f,
    10.00f, 20.00f, 10.00f, -0.12f, 14.00f,
    10.00f, 16.00f, 10.00f, 0.12f, -14.00f,
    10.00f, 26.00f, 10.00f, 0.00f, 0.00f,
    12.00f, 24.00f, 12.00f, 0.18f, 18.00f,
    10.00f, 16.00f, 10.00f, -0.06f, -18.00f,
    12.00f, 20.00f, 12.00f, 0.24f, 0.00f,
    0.00f, 12.00f, 0.00f, 0.00f, 0.00f,
    // DUSTDEVIL CANYON
    0.00f, 26.00f, 0.00f, 0.00f, 0.00f,
    10.00f, 22.00f, 10.00f, 0.24f, 16.00f,
    8.00f, 16.00f, 8.00f, -0.18f, -16.00f,
    8.00f, 14.00f, 8.00f, 0.18f, 22.00f,
    8.00f, 14.00f, 8.00f, -0.24f, -22.00f,
    10.00f, 30.00f, 10.00f, 0.00f, 28.00f,
    12.00f, 24.00f, 12.00f, 0.24f, -28.00f,
    8.00f, 12.00f, 8.00f, -0.12f, 0.00f,
    10.00f, 18.00f, 10.00f, 0.18f, 18.00f,
    8.00f, 16.00f, 8.00f, -0.18f, -18.00f,
    10.00f, 34.00f, 10.00f, 0.00f, 0.00f,
    12.00f, 22.00f, 12.00f, 0.24f, 12.00f,
    8.00f, 14.00f, 8.00f, -0.12f, -12.00f,
    10.00f, 16.00f, 10.00f, 0.18f, 0.00f,
    0.00f, 10.00f, 0.00f, 0.00f, 0.00f,
};
constant int trackPieceStart[3] = {0, 11, 24};
constant int trackPieceCount[3] = {11, 13, 15};


// ---------------------------------------------------------------------------
// Settings and small helpers

struct Settings {
    uint laps;
    float pace;
    uint nitro;
    uint firstRace;
};

Settings readSettings(constant ProgramUniforms &u) {
    float4 p = u.parameters0;
    Settings settings;
    settings.laps = 3u;
    settings.pace = 1.0f;
    settings.nitro = 3u;
    settings.firstRace = 0u;
    if (all(p == float4(0.0f))) return settings;
    settings.laps = p.x > 0.0f ? uint(clamp(round(p.x), 1.0f, 5.0f)) : 3u;
    settings.pace = p.y > 0.0f ? clamp(p.y, 0.8f, 1.2f) : 1.0f;
    settings.nitro = uint(clamp(round(p.z), 0.0f, 5.0f));
    settings.firstRace = p.w > 0.0f ? uint(clamp(round(p.w), 1.0f, 3.0f)) - 1u : 0u;
    return settings;
}

uint hashUint(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

float hash01(uint x) {
    return float(hashUint(x) & 0xffffffu) / 16777216.0f;
}

float easeIn(float a, float b, float p) {
    return a + (b - a) * p * p;
}

float easeInOut(float a, float b, float p) {
    return a + (b - a) * (0.5f - 0.5f * cos(p * M_PI_F));
}

float wrapDistance(float z, float lap) {
    return z - floor(z / lap) * lap;
}

// Shortest signed lap distance from 0 to dz (-lap/2 .. lap/2).
float wrapSigned(float dz, float lap) {
    return dz - floor(dz / lap + 0.5f) * lap;
}

int segmentIndexAt(float z, float lap, int count) {
    return clamp(int(wrapDistance(z, lap) / segmentLength), 0, count - 1);
}

float curveAt(device const GameState &game, float z) {
    int count = int(game.notice.z);
    return game.segments[segmentIndexAt(z, game.view.w, count)].x;
}

float heightAt(device const GameState &game, float z) {
    int count = int(game.notice.z);
    float along = wrapDistance(z, game.view.w) / segmentLength;
    int index = clamp(int(along), 0, count - 1);
    float t = clamp(along - float(index), 0.0f, 1.0f);
    return mix(game.segments[index].y, game.segments[(index + 1) % count].y, t);
}

// Largest bend magnitude between `from` and `from + 6 * samples` metres.
float sharpestCurveAhead(device const GameState &game, float from, int samples) {
    float sharpest = 0.0f;
    for (int i = 0; i < samples; ++i) {
        sharpest = max(sharpest, abs(curveAt(game, from + float(i) * segmentLength)));
    }
    return sharpest;
}

// Speed fraction (of maxSpeed) at which a car can still hold its line in a
// bend: gripDrift * c * s^2 = 1 + 0.9 * s, the steering authority below.
float gripFraction(float curve) {
    float kc = gripDrift * abs(curve);
    if (kc < 0.0001f) return 10.0f;
    return (0.9f + sqrt(0.81f + 4.0f * kc)) / (2.0f * kc);
}

float totalDistance(device const Car &car, float lap) {
    return float(car.info.x) * lap + car.motion.x;
}

void showNotice(device GameState &game, int text, uint number) {
    game.notice.x = uint(text);
    game.notice.y = number;
    game.effects.x = 0.0f;
}

// ---------------------------------------------------------------------------
// Track

void buildTrack(device GameState &game, uint race) {
    int first = trackPieceStart[min(race, 2u)];
    int pieces = trackPieceCount[min(race, 2u)];
    int count = 0;
    float y = 0.0f;
    for (int p = 0; p < pieces; ++p) {
        int base = (first + p) * 5;
        int enter = int(trackPieces[base]);
        int hold = int(trackPieces[base + 1]);
        int leave = int(trackPieces[base + 2]);
        float curve = trackPieces[base + 3];
        float y0 = y;
        float y1 = y + trackPieces[base + 4];
        int total = enter + hold + leave;
        for (int k = 0; k < total && count < maxSegments; ++k) {
            float c = curve;
            if (k < enter) c = easeIn(0.0f, curve, float(k) / float(enter));
            else if (k >= enter + hold) c = easeInOut(curve, 0.0f, float(k - enter - hold) / float(leave));
            float height = easeInOut(y0, y1, float(k) / float(total));
            game.segments[count] = float4(c, height, 0.0f, 0.0f);
            ++count;
        }
        y = y1;
    }
    game.notice.z = uint(count);
    game.view.w = float(count) * segmentLength;

    // A schematic minimap: integrate the bends scaled to one full turn, close
    // the loop linearly, and fit it into the unit square.
    float sum = 0.0f;
    for (int i = 0; i < count; ++i) sum += game.segments[i].x;
    float turn = abs(sum) > 0.001f ? 2.0f * M_PI_F / sum : 0.0f;
    int stride = (count + minimapCapacity - 1) / minimapCapacity;
    int points = (count + stride - 1) / stride;
    float heading = 0.0f;
    float2 at = float2(0.0f);
    for (int i = 0; i < count; ++i) {
        if (i % stride == 0) game.minimap[i / stride] = float4(at, 0.0f, 0.0f);
        heading += game.segments[i].x * turn;
        at += float2(cos(heading), sin(heading));
    }
    float2 lower = float2(1.0e9f);
    float2 upper = float2(-1.0e9f);
    for (int j = 0; j < points; ++j) {
        float2 corrected = game.minimap[j].xy - at * (float(j * stride) / float(count));
        game.minimap[j].xy = corrected;
        lower = min(lower, corrected);
        upper = max(upper, corrected);
    }
    float2 extent = max(upper - lower, float2(0.001f));
    float size = max(extent.x, extent.y);
    float2 margin = 0.5f * (float2(size) - extent);
    for (int j = 0; j < points; ++j) {
        game.minimap[j].xy = (game.minimap[j].xy - lower + margin) / size;
    }
    game.sketch = float4(float(stride), float(points), 0.0f, 0.0f);
}

// Roadside scenery for one side of a segment, placed at its start:
// kind, lateral position (half-widths), size multiplier, variant.
float4 sceneryAt(uint race, int segment, int side, int count) {
    if (segment == 0) return side == 0 ? float4(kindGantry, 0.0f, 1.0f, 0.0f) : float4(0.0f);
    float sideSign = side == 0 ? -1.0f : 1.0f;
    if (segment % 8 == 4) return float4(kindPost, 1.22f * sideSign, 1.0f, 0.0f);
    if (segment < 5 || segment > count - 5) return float4(0.0f);
    uint key = uint(segment) * 2u + uint(side) + race * 7919u;
    if (segment % 46 == 23 && (segment / 46) % 2 == side) {
        return float4(kindBillboard, 2.35f * sideSign, 1.0f,
            float(uint(segment / 46 + int(race)) % 4u));
    }
    float pick = hash01(key * 3u + 1u);
    float spread = hash01(key * 3u + 2u);
    float size = hash01(key * 7u + 5u);
    if (pick < 0.17f) {
        return float4(kindCactus, (1.75f + 1.7f * spread) * sideSign, 0.8f + 0.45f * size, 0.0f);
    }
    if (pick < 0.24f) {
        return float4(kindHoodoo, (2.4f + 2.6f * spread) * sideSign, 0.8f + 0.5f * size, 0.0f);
    }
    if (pick < 0.28f) {
        return float4(kindMesa, (8.0f + 7.0f * spread) * sideSign, 0.7f + 0.6f * size, 0.0f);
    }
    return float4(0.0f);
}

// Half-width in road half-widths of a scenery item the car can hit (0 = none).
float sceneryReach(float kind, float size) {
    if (kind == kindCactus) return 0.11f * size;
    if (kind == kindHoodoo) return 0.36f * size;
    if (kind == kindBillboard) return 0.78f;
    return 0.0f;
}

int devilCount(uint race) {
    return race == 0u ? 2 : 3;
}

// A dust devil: lap distance (m) and lateral position (half-widths).
float2 devilAt(device const GameState &game, int index, float time) {
    float lap = game.view.w;
    float z = lap * (0.24f + 0.27f * float(index)) + 30.0f;
    float x = 1.2f * sin(time * (0.45f + 0.1f * float(index)) + 2.1f * float(index));
    return float2(z, x);
}

// ---------------------------------------------------------------------------
// Race set-up

void placeGrid(device GameState &game, float pace, uint race) {
    for (int i = 0; i < carCount; ++i) {
        int slot = i - 1;
        if (i == 0) slot = carCount - 1;
        float z = -8.0f - float(slot / 2) * 10.0f;
        float x = slot % 2 == 0 ? -0.36f : 0.36f;
        float top = maxSpeed * (rivalSkill[i] + raceSkill[min(race, 2u)]) * (i == 0 ? 1.0f : pace);
        game.cars[i].motion = float4(z, x, 0.0f, x);
        game.cars[i].timers = float4(0.0f, 0.0f, 0.0f, top);
        game.cars[i].info = uint4(0u, 0u, uint(i) * 7u, 0u);
    }
}

void resetRaceState(device GameState &game, Settings settings, uint race) {
    buildTrack(game, race);
    game.flow.y = race;
    game.flow.z = settings.laps;
    game.tally.z = 0u;
    game.tally.w = 0u;
    game.control.y = settings.nitro;
    game.control.z = uint(carCount);
    game.control.w = settings.firstRace;
    game.timing = float4(0.0f);
    game.driver = float4(0.0f, 1.0f, 0.0f, 0.0f);
    game.effects = float4(10.0f, 0.0f, 0.0f, 0.0f);
    game.hazard = float4(0.0f, 0.0f, 0.0f, settings.pace);
    game.notice.x = 0u;
    game.notice.y = 0u;
    placeGrid(game, settings.pace, race);
}

void showTitle(device GameState &game, constant ProgramUniforms &u) {
    Settings settings = readSettings(u);
    resetRaceState(game, settings, settings.firstRace);
    game.flow.x = phaseTitle;
    game.tally.x = 0u;
    game.tally.y = 0u;
}

void startRace(device GameState &game, constant ProgramUniforms &u, uint race) {
    Settings settings = readSettings(u);
    if (race == settings.firstRace) game.tally.x = 0u;
    game.tally.y = 0u;
    resetRaceState(game, settings, race);
    game.flow.x = phaseCountdown;
}

// ---------------------------------------------------------------------------
// Driving

// Lane choice for a computer driver: the lane with the least traffic ahead.
float chooseLane(device const GameState &game, int self, float lap) {
    device const Car &car = game.cars[self];
    float best = car.motion.w;
    float bestCost = 1.0e9f;
    for (int lane = -1; lane <= 1; ++lane) {
        float x = float(lane) * laneSpacing;
        float cost = 0.25f * abs(x - car.motion.y);
        for (int j = 0; j < carCount; ++j) {
            if (j == self) continue;
            float dz = wrapSigned(game.cars[j].motion.x - car.motion.x, lap);
            if (dz > -7.0f && dz < 40.0f && abs(game.cars[j].motion.y - x) < 0.40f) {
                cost += 1.0f + (40.0f - max(dz, 0.0f)) / 20.0f;
            }
        }
        if (cost < bestCost) {
            bestCost = cost;
            best = x;
        }
    }
    return best;
}

// Computer driving for rivals, the demo race and the player's car after the
// finish. Rivals obey the same grip limit but never slide; they lift early.
void driveComputer(device GameState &game, int index, float dt, float top) {
    device Car &car = game.cars[index];
    float lap = game.view.w;
    float z = car.motion.x;
    float speed = car.motion.z;
    float bend = sharpestCurveAhead(game, z + 4.0f, 10);
    float desired = min(top, gripFraction(bend) * maxSpeed * 0.95f);

    int blocker = -1;
    float gap = 1.0e9f;
    for (int j = 0; j < carCount; ++j) {
        if (j == index) continue;
        float dz = wrapSigned(game.cars[j].motion.x - z, lap);
        if (dz > 0.0f && dz < 32.0f && abs(game.cars[j].motion.y - car.motion.y) < 0.36f
            && dz < gap) {
            gap = dz;
            blocker = j;
        }
    }
    if (car.info.z > 0u) car.info.z -= 1u;
    if (blocker >= 0) {
        float ahead = game.cars[blocker].motion.z;
        if (gap < 16.0f) desired = min(desired, ahead + (gap - 8.0f) * 0.7f);
        if (car.info.z == 0u && ahead < top - 1.0f) {
            car.motion.w = chooseLane(game, index, lap);
            car.info.z = 36u;
        }
    } else if (car.info.z == 0u) {
        // Drift back to the favourite lane when it is free.
        float home = preferredLane[index] * laneSpacing;
        if (abs(car.motion.w - home) > 0.01f && chooseLane(game, index, lap) == home) {
            car.motion.w = home;
        }
        car.info.z = 45u;
    }
    float accel = 13.5f - 7.0f * min(speed / maxSpeed, 1.0f);
    float before = speed;
    speed = speed < desired ? min(desired, speed + accel * dt) : max(desired, speed - 16.0f * dt);
    speed = max(speed, 0.0f);
    car.info.w = speed < before - 0.05f ? 1u : 0u;
    float slew = 0.85f * dt;
    car.motion.y += clamp(car.motion.w - car.motion.y, -slew, slew);
    car.motion.z = speed;
    car.motion.x = z + speed * dt;
}

// Player input: X picks the line across the road, Y is the pedal.
void readPedals(device GameState &game, float2 pointer) {
    float2 p = clamp(pointer, float2(0.0f), float2(1.0f));
    game.driver.x = clamp((p.x - 0.5f) * 3.0f, -1.55f, 1.55f);
    game.driver.y = clamp((0.72f - p.y) / 0.20f, 0.0f, 1.0f);
    game.driver.z = clamp((p.y - 0.78f) / 0.14f, 0.0f, 1.0f);
}

void drivePlayer(device GameState &game, float dt) {
    device Car &car = game.cars[0];
    float gas = game.driver.y;
    float brake = game.driver.z;
    float speed = car.motion.z;
    float x = car.motion.y;
    bool nitro = car.timers.x > 0.0f;
    bool offroad = abs(x) > 1.08f;
    float top = maxSpeed;
    if (nitro) top = nitroSpeed;
    if (offroad) top = min(top, offroadSpeed);
    float accel = nitro ? 22.0f : 15.0f - 8.0f * min(speed / maxSpeed, 1.0f);
    if (speed < top) speed = min(top, speed + gas * accel * dt);
    else speed = max(top, speed - (offroad ? 30.0f : 10.0f) * dt);
    speed = max(0.0f, speed - (brake * 30.0f + (1.0f - gas) * 3.5f) * dt);
    car.info.w = brake > 0.05f ? 1u : 0u;

    // The car steers towards the chosen line; the bend pushes it outwards.
    // Beyond the grip limit the car slides wide and scrubs off speed.
    float sp = speed / maxSpeed;
    float bend = curveAt(game, car.motion.x);
    float authority = (1.0f + 0.9f * sp) * clamp(speed / 10.0f, 0.15f, 1.0f);
    if (offroad) authority *= 0.7f;
    if (game.effects.w > 0.0f) authority *= 0.4f;
    float drift = gripDrift * sp * sp * bend;
    float desired = clamp((game.driver.x - x) * 3.2f, -2.4f, 2.4f);
    float command = clamp(desired + drift, -authority, authority);
    float slide = max(0.0f, abs(drift) - authority);
    float lateral = command - drift - sign(drift) * slide * 0.8f + game.effects.z;
    speed = max(0.0f, speed - slide * 10.0f * dt);
    game.driver.w = mix(game.driver.w, slide, min(1.0f, dt * 6.0f));
    game.hazard.y = mix(game.hazard.y, clamp(command * 0.6f, -1.0f, 1.0f), min(1.0f, dt * 8.0f));
    x += lateral * dt;
    if (abs(x) > 2.3f) {
        x = clamp(x, -2.3f, 2.3f);
        speed *= max(0.0f, 1.0f - 1.5f * dt);
    }
    car.motion.y = x;
    car.motion.z = speed;
    car.motion.x += speed * dt;
}

// Overlapping cars: the car behind is pushed back and slowed down.
void resolveContacts(device GameState &game, bool racing) {
    float lap = game.view.w;
    for (int i = 0; i < carCount; ++i) {
        for (int j = i + 1; j < carCount; ++j) {
            device Car &a = game.cars[i];
            device Car &b = game.cars[j];
            float dz = wrapSigned(b.motion.x - a.motion.x, lap);
            float dx = b.motion.y - a.motion.y;
            if (abs(dz) >= carLength || abs(dx) >= 2.0f * carHalfWidth * 0.95f) continue;
            int front = dz > 0.0f ? j : i;
            int back = dz > 0.0f ? i : j;
            device Car &ahead = game.cars[front];
            device Car &behind = game.cars[back];
            float overlap = carLength - abs(dz);
            behind.motion.x -= overlap;
            float lost = max(0.0f, behind.motion.z - ahead.motion.z * 0.94f);
            if (behind.motion.z > ahead.motion.z) {
                ahead.motion.z += 0.25f * (behind.motion.z - ahead.motion.z);
                behind.motion.z = ahead.motion.z * 0.94f;
            }
            float side = dx >= 0.0f ? 1.0f : -1.0f;
            a.motion.y -= 0.03f * side;
            b.motion.y += 0.03f * side;
            if (racing && (front == 0 || back == 0)) {
                game.cars[0].timers.y = 0.4f;
                if (lost > 3.0f && game.effects.x > 0.8f) showNotice(game, textBump, 0u);
            }
        }
    }
}

// Crashes into roadside scenery and shoves from dust devils (player only).
void checkHazards(device GameState &game, float dt, float time) {
    device Car &car = game.cars[0];
    float lap = game.view.w;
    int count = int(game.notice.z);
    float z = car.motion.x;
    float x = car.motion.y;
    game.effects.w = max(0.0f, game.effects.w - dt);
    game.hazard.x = max(0.0f, game.hazard.x - dt);
    game.effects.z *= max(0.0f, 1.0f - 2.2f * dt);
    if (abs(x) > 1.3f && game.effects.w <= 0.0f) {
        int here = segmentIndexAt(z, lap, count);
        for (int k = -1; k <= 1; ++k) {
            int segment = (here + k + count) % count;
            for (int side = 0; side < 2; ++side) {
                float4 item = sceneryAt(game.flow.y, segment, side, count);
                float reach = sceneryReach(item.x, item.z);
                if (reach <= 0.0f) continue;
                float dz = wrapSigned(float(segment) * segmentLength - z, lap);
                if (abs(dz) < 2.6f && abs(x - item.y) < reach + carHalfWidth) {
                    car.motion.z = min(car.motion.z * 0.35f, 15.0f);
                    car.motion.y -= 0.25f * sign(item.y);
                    car.timers.x = 0.0f;
                    game.effects.w = 1.1f;
                    showNotice(game, textCrash, 0u);
                }
            }
        }
    }
    if (game.hazard.x <= 0.0f) {
        for (int k = 0; k < devilCount(game.flow.y); ++k) {
            float2 devil = devilAt(game, k, time);
            float dz = wrapSigned(devil.x - z, lap);
            if (abs(dz) < 4.0f && abs(x - devil.y) < 0.42f) {
                float away = x >= devil.y ? 1.0f : -1.0f;
                game.effects.z = 2.0f * away;
                car.motion.z *= 0.85f;
                game.hazard.x = 1.4f;
                showNotice(game, textDustDevil, 0u);
            }
        }
    }
}

int placeOf(device const GameState &game, int index) {
    float lap = game.view.w;
    float mine = totalDistance(game.cars[index], lap);
    int place = 1;
    for (int j = 0; j < carCount; ++j) {
        if (j == index) continue;
        device const Car &other = game.cars[j];
        bool ahead = other.info.y > 0u && (game.cars[index].info.y == 0u
            || other.info.y < game.cars[index].info.y);
        if (game.cars[index].info.y == 0u && other.info.y == 0u) {
            ahead = totalDistance(other, lap) > mine;
        }
        if (ahead) place += 1;
    }
    return place;
}

// Lap counting for every car; returns true when the player finishes. With
// racing set, cars that complete the last lap get a finishing place; with
// playerRacing set, the player's laps also record lap times and notices.
bool countLaps(device GameState &game, bool racing, bool playerRacing) {
    float lap = game.view.w;
    bool playerFinished = false;
    for (int i = 0; i < carCount; ++i) {
        device Car &car = game.cars[i];
        if (car.motion.x < lap) continue;
        car.motion.x -= lap;
        car.info.x += 1u;
        if (!racing) continue;
        if (car.info.x >= game.flow.z && car.info.y == 0u) {
            game.tally.w += 1u;
            car.info.y = game.tally.w;
            car.timers.z = game.timing.x;
        }
        if (i != 0 || !playerRacing) continue;
        float lapTime = game.timing.y;
        game.hazard.z = lapTime;
        bool best = game.timing.z <= 0.0f || lapTime < game.timing.z;
        if (best) game.timing.z = lapTime;
        game.timing.y = 0.0f;
        if (car.info.y > 0u) {
            playerFinished = true;
            continue;
        }
        game.control.y = min(game.control.y + 1u, 5u);
        if (car.info.x + 1u == game.flow.z) showNotice(game, textFinalLap, 0u);
        else if (best && car.info.x > 1u) showNotice(game, textBestLap, 0u);
        else showNotice(game, textLap, car.info.x + 1u);
    }
    return playerFinished;
}

void computeResults(device GameState &game) {
    float lap = game.view.w;
    float raceDistance = float(game.flow.z) * lap;
    float times[8];
    int order[8];
    for (int i = 0; i < carCount; ++i) {
        device const Car &car = game.cars[i];
        float remaining = max(0.0f, raceDistance - totalDistance(car, lap));
        times[i] = game.timing.x + remaining / max(car.motion.z, 20.0f);
        if (car.info.y > 0u) times[i] = car.timers.z;
        order[i] = i;
    }
    for (int i = 1; i < carCount; ++i) {
        int key = order[i];
        int j = i - 1;
        while (j >= 0 && times[order[j]] > times[key]) {
            order[j + 1] = order[j];
            --j;
        }
        order[j + 1] = key;
    }
    for (int k = 0; k < carCount; ++k) {
        game.results[k] = float4(float(order[k]), times[order[k]], finishPoints[k], 0.0f);
        if (order[k] == 0) {
            game.tally.z = uint(k + 1);
            game.tally.y = uint(finishPoints[k]);
        }
    }
}

// Every car moves; the player car is human-driven only while racing.
void moveField(device GameState &game, float dt, float time, bool human, bool racing) {
    float lap = game.view.w;
    float playerDistance = totalDistance(game.cars[0], lap);
    for (int i = 1; i < carCount; ++i) {
        device Car &car = game.cars[i];
        float top = car.timers.w;
        if (racing && car.info.y == 0u) {
            // Mild rubber band so the field stays within reach.
            float gap = playerDistance - totalDistance(car, lap);
            float beyond = max(abs(gap) - 150.0f, 0.0f) * sign(gap);
            top *= 1.0f + clamp(beyond / 450.0f, -0.04f, 0.04f);
        }
        driveComputer(game, i, dt, top);
    }
    if (human) {
        drivePlayer(game, dt);
        checkHazards(game, dt, time);
    } else {
        game.effects.z = 0.0f;
        driveComputer(game, 0, dt, maxSpeed * 0.95f);
    }
    device Car &player = game.cars[0];
    player.timers.x = max(0.0f, player.timers.x - dt);
    player.timers.y = max(0.0f, player.timers.y - dt);
    resolveContacts(game, racing);
    game.effects.y += dt * (player.motion.z / maxSpeed) * curveAt(game, player.motion.x) * 0.05f;
}

// ---------------------------------------------------------------------------
// Kernels

kernel void initializeRace(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    // The current action count is the baseline, not a press.
    game.control.x = uint(u.pointer.z);
    game.flow.w = 0u;
    showTitle(game, u);
}

kernel void advanceRace(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.resolutionTime.w, 0.0f, 0.05f);
    float time = u.resolutionTime.z;
    uint actions = uint(u.pointer.z);
    bool pressed = actions > game.control.x;
    if (pressed) game.control.x = actions;
    game.timing.w += dt;
    game.effects.x += dt;
    readPedals(game, u.pointer.xy);

    uint phase = game.flow.x;
    if (phase == phaseTitle) {
        if (pressed) {
            startRace(game, u, game.control.w);
            return;
        }
        moveField(game, dt, time, false, false);
        countLaps(game, false, false);
    } else if (phase == phaseCountdown) {
        if (game.timing.w >= countdownSeconds) {
            game.flow.x = phaseRacing;
            game.timing.w = 0.0f;
            showNotice(game, textGo, 0u);
        }
    } else if (phase == phaseRacing) {
        game.timing.x += dt;
        game.timing.y += dt;
        device Car &player = game.cars[0];
        if (pressed) {
            if (game.control.y > 0u && player.timers.x <= 0.0f) {
                game.control.y -= 1u;
                player.timers.x = nitroSeconds;
                showNotice(game, textNitroOn, 0u);
            } else if (game.control.y == 0u) {
                showNotice(game, textNoNitro, 0u);
            }
        }
        moveField(game, dt, time, true, true);
        if (game.driver.w > 0.25f && game.effects.x > 2.5f) showNotice(game, textSlide, 0u);
        if (abs(player.motion.y) > 1.15f && game.effects.x > 3.0f && player.motion.z > 20.0f) {
            showNotice(game, textOffRoad, 0u);
        }
        bool finished = countLaps(game, true, true);
        uint place = uint(placeOf(game, 0));
        if (place < game.control.z && game.effects.x > 1.2f && game.timing.x > 5.0f) {
            showNotice(game, textOvertake, 0u);
        }
        game.control.z = place;
        if (finished) {
            game.flow.x = phaseFinish;
            game.timing.w = 0.0f;
            game.tally.z = player.info.y;
            showNotice(game, textFinished, player.info.y);
        }
    } else if (phase == phaseFinish) {
        game.timing.x += dt;
        moveField(game, dt, time, false, true);
        countLaps(game, true, false);
        if (game.timing.w >= finishSeconds || (pressed && game.timing.w > 1.0f)) {
            computeResults(game);
            game.flow.x = phaseResults;
            game.timing.w = 0.0f;
        }
    } else if (phase == phaseResults) {
        moveField(game, dt, time, false, false);
        countLaps(game, false, false);
        if (pressed && game.timing.w > 0.8f) {
            uint race = game.flow.y;
            if (game.tally.z <= 3u) {
                game.tally.x += game.tally.y;
                if (race < 2u) {
                    startRace(game, u, race + 1u);
                } else {
                    game.tally.y = 0u;
                    game.flow.x = phaseChampion;
                    game.timing.w = 0.0f;
                }
            } else {
                startRace(game, u, race);
            }
        }
    } else {
        moveField(game, dt, time, false, false);
        countLaps(game, false, false);
        if (pressed && game.timing.w > 1.0f) showTitle(game, u);
    }
}


// ---------------------------------------------------------------------------
// Projection: one row record per screen row and a depth-sorted sprite list

// Width, height and the part below the ground line (m) of a sprite kind.
float3 spriteSize(float kind) {
    if (kind == kindPost) return float3(0.4f, 1.25f, 0.0f);
    if (kind == kindCactus) return float3(3.2f, 6.0f, 0.0f);
    if (kind == kindHoodoo) return float3(4.8f, 8.6f, 0.0f);
    if (kind == kindMesa) return float3(46.0f, 24.0f, 0.0f);
    if (kind == kindBillboard) return float3(10.0f, 7.6f, 0.0f);
    if (kind == kindGantry) return float3(2.0f * roadHalfWidth + 2.8f, 9.2f, 0.0f);
    if (kind == kindDevil) return float3(7.0f, 16.0f, 0.4f);
    return float3(3.2f, 2.0f, 0.3f);   // car, with room for its shadow, dust and flames
}

void addSprite(device GameState &game, thread uint &count, uint limit, float kind,
    float size, float depth, float2 ground, float scale, float clip, float4 extra,
    float2 resolution) {
    if (count >= limit) return;
    float3 dims = spriteSize(kind) * size;
    float halfWidth = 0.5f * dims.x * scale;
    float top = ground.y - dims.y * scale;
    float bottom = ground.y + dims.z * scale;
    if (halfWidth < 0.4f || top >= clip || top >= resolution.y || bottom <= 0.0f
        || ground.x + halfWidth <= 0.0f || ground.x - halfWidth >= resolution.x) return;
    device Sprite &sprite = game.sprites[count];
    sprite.rect = float4(ground.x - halfWidth, top, ground.x + halfWidth, bottom);
    sprite.meta = float4(kind, depth, clip, size);
    sprite.extra = extra;
    count += 1u;
}

kernel void projectView(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float time = u.resolutionTime.z;
    int rowCount = clamp(int(resolution.y), 1, maxRows);
    float focal = focalScale * resolution.y;
    float horizon = horizonScale * resolution.y;
    float lap = game.view.w;
    int count = int(game.notice.z);
    uint race = game.flow.y;
    device const Car &player = game.cars[0];
    float camZ = wrapDistance(player.motion.x - cameraBack, lap);
    int base = clamp(int(camZ / segmentLength), 0, count - 1);
    float frac = clamp(camZ / segmentLength - float(base), 0.0f, 1.0f);
    float camX = player.motion.y * roadHalfWidth;
    float camY = cameraHeight + heightAt(game, player.motion.x);
    game.view.x = focal;
    game.view.y = horizon;
    game.view.z = camY;

    for (int r = 0; r < rowCount; ++r) game.rows[r] = float4(0.0f, -1.0f, 0.0f, 0.0f);

    // Per drawn segment: road centre offset at its start (m), the offset
    // change across it (m), and the clip row before its road rows.
    float3 placement[drawSegments];
    uint spriteCount = 0u;
    float x = 0.0f;
    float dx = -game.segments[base].x * frac;
    float maxY = resolution.y;
    for (int n = 0; n < drawSegments; ++n) {
        int segment = (base + n) % count;
        int next = (segment + 1) % count;
        placement[n] = float3(x, dx, maxY);
        float z1 = (float(n) - frac) * segmentLength;
        float z2 = z1 + segmentLength;
        float x1 = x - camX;
        float x2 = x + dx - camX;
        x += dx;
        dx += game.segments[segment].x;
        float y1 = game.segments[segment].y - camY;
        float y2 = game.segments[next].y - camY;
        if (z2 <= nearDepth) continue;
        float zc = z1;
        float xc = x1;
        float yc = y1;
        if (z1 < nearDepth) {
            float t = (nearDepth - z1) / segmentLength;
            zc = nearDepth;
            xc = mix(x1, x2, t);
            yc = mix(y1, y2, t);
        }
        float s1 = focal / zc;
        float s2 = focal / z2;
        float2 near = float2(0.5f * resolution.x + s1 * xc, horizon - s1 * yc);
        float2 far = float2(0.5f * resolution.x + s2 * x2, horizon - s2 * y2);

        if (n >= 1 && n < spriteSegments && z1 >= nearDepth) {
            for (int side = 0; side < 2; ++side) {
                float4 item = sceneryAt(race, segment, side, count);
                if (item.x <= 0.0f) continue;
                if (item.x == kindPost && n >= 64) continue;
                float2 ground = float2(near.x + s1 * item.y * roadHalfWidth, near.y);
                addSprite(game, spriteCount, uint(scenerySprites), item.x, item.z, z1,
                    ground, s1, maxY, float4(item.w, float(segment), 0.0f, 0.0f),
                    resolution);
            }
        }
        if (far.y < maxY && far.y < near.y) {
            int first = max(int(ceil(far.y - 0.5f)), 0);
            int last = min(int(ceil(min(near.y, maxY) - 0.5f)), rowCount);
            float span = near.y - far.y;
            for (int r = first; r < last; ++r) {
                float t = (near.y - (float(r) + 0.5f)) / span;
                float inverse = mix(1.0f / zc, 1.0f / z2, t);
                game.rows[r] = float4(mix(near.x, far.x, t),
                    focal * roadHalfWidth * inverse, inverse,
                    wrapDistance(camZ + 1.0f / inverse, lap));
            }
            maxY = far.y;
        }
    }

    // Cars and dust devils, placed on the projected road.
    float reach = float(drawSegments - 1) * segmentLength;
    int devils = devilCount(race);
    for (int i = 0; i < carCount + devils; ++i) {
        bool isCar = i < carCount;
        float along = 0.0f;
        float lateral = 0.0f;
        if (isCar) {
            along = game.cars[i].motion.x;
            lateral = game.cars[i].motion.y;
        } else {
            float2 devil = devilAt(game, i - carCount, time);
            along = devil.x;
            lateral = devil.y;
        }
        float depth = wrapDistance(along - camZ, lap);
        if (depth < nearDepth + 0.5f || depth > reach) continue;
        float segmentsAhead = depth / segmentLength + frac;
        int n = min(int(segmentsAhead), drawSegments - 1);
        float t = segmentsAhead - float(n);
        float3 place = placement[n];
        float centre = place.x + place.y * t;
        int segment = (base + n) % count;
        float groundY = mix(game.segments[segment].y,
            game.segments[(segment + 1) % count].y, t) - camY;
        float scale = focal / depth;
        float2 ground = float2(
            0.5f * resolution.x + scale * (centre + lateral * roadHalfWidth - camX),
            horizon - scale * groundY);
        if (isCar) {
            device const Car &car = game.cars[i];
            float steer = clamp((car.motion.w - car.motion.y) * 2.0f, -1.0f, 1.0f) * 0.5f;
            if (i == 0) steer = game.hazard.y;
            uint bits = 0u;
            if (car.timers.x > 0.0f) bits |= 1u;
            if (i == 0 && abs(car.motion.y) > 1.08f && car.motion.z > 5.0f) bits |= 2u;
            if (i == 0 && game.driver.w > 0.08f) bits |= 4u;
            if (i == 0 && game.effects.w > 0.0f) bits |= 8u;
            if (car.timers.y > 0.0f) bits |= 16u;
            addSprite(game, spriteCount, uint(maxSprites), kindCar, 1.0f, depth, ground,
                scale, place.z, float4(float(i), steer, float(car.info.w), float(bits)),
                resolution);
        } else {
            addSprite(game, spriteCount, uint(maxSprites), kindDevil, 1.0f, depth,
                ground, scale, place.z, float4(float(i - carCount), 0.0f, 0.0f, 0.0f),
                resolution);
        }
    }

    // Far to near, so nearer sprites are blended over farther ones.
    for (uint i = 1u; i < spriteCount; ++i) {
        Sprite key = game.sprites[i];
        int j = int(i) - 1;
        while (j >= 0 && game.sprites[j].meta.y < key.meta.y) {
            game.sprites[j + 1] = game.sprites[j];
            --j;
        }
        game.sprites[j + 1] = key;
    }
    game.flow.w = spriteCount;
}


// ---------------------------------------------------------------------------
// Presentation helpers

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenVertex screenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1u) & 2u, vertexID & 2u);
    ScreenVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

float3 decodeSRGB(float4 texel) {
    float3 srgb = clamp(texel.rgb / max(texel.a, 0.001f), float3(0.0f), float3(1.0f));
    return select(pow((srgb + 0.055f) / 1.055f, float3(2.4f)), srgb / 12.92f,
        srgb <= 0.04045f);
}

float3 textureAlbedo(texture2d<float> image, float2 uv) {
    constexpr sampler materialSampler(coord::normalized, address::mirrored_repeat,
        filter::linear);
    return decodeSRGB(image.sample(materialSampler, uv));
}

float lumaOf(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// Linear light to display sRGB through a soft shoulder.
float3 toDisplay(float3 linearColor) {
    float3 mapped = 1.0f - exp(-max(linearColor, float3(0.0f)) * 1.45f);
    float3 srgb = select(1.055f * pow(mapped, float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
    return clamp(srgb, float3(0.0f), float3(1.0f));
}

// The inverse shoulder, so a generated backdrop shows with its own tones.
float3 fromDisplayLinear(float3 linearDisplay) {
    float3 m = clamp(linearDisplay, float3(0.0f), float3(0.985f));
    return -log(1.0f - m) / 1.45f;
}

float3 fromSRGBish(float3 c) {
    return pow(clamp(c, float3(0.0f), float3(1.0f)), float3(2.2f));
}

// Lighting per race: midday, golden hour, dusk.
struct Look {
    float3 grade;  // backdrop colour grade
    float3 haze;   // distance haze
    float3 sun;    // light on the ground, scenery and cars
    float stars;
};

Look lookFor(uint race) {
    Look look;
    if (race == 1u) {
        look.grade = float3(1.10f, 0.86f, 0.66f);
        look.haze = float3(0.92f, 0.56f, 0.32f);
        look.sun = float3(1.30f, 0.98f, 0.70f);
        look.stars = 0.0f;
    } else if (race == 2u) {
        look.grade = float3(0.60f, 0.52f, 0.86f);
        look.haze = float3(0.36f, 0.27f, 0.52f);
        look.sun = float3(0.78f, 0.66f, 1.00f);
        look.stars = 1.0f;
    } else {
        look.grade = float3(1.0f);
        look.haze = float3(0.78f, 0.70f, 0.60f);
        look.sun = float3(1.32f, 1.24f, 1.10f);
        look.stars = 0.0f;
    }
    return look;
}

float2 backdropUV(float2 pixel, float2 resolution, float horizon, float scroll) {
    float u = (pixel.x - 0.5f * resolution.x) / (1.5f * resolution.y) + 0.5f + scroll;
    float v = 0.40f + pixel.y / max(horizon, 1.0f) * 0.57f;
    return float2(u, v);
}

// Backdrop colour at the horizon line above this column, mixed with the haze.
float3 hazeAt(float2 pixel, float2 resolution, device const GameState &game,
    Look look, texture2d<float> backdrop) {
    float2 uv = backdropUV(float2(pixel.x, game.view.y), resolution, game.view.y,
        game.effects.y);
    float3 horizonColor = fromDisplayLinear(textureAlbedo(backdrop,
        float2(uv.x, 0.965f))) * look.grade;
    return mix(look.haze, horizonColor, 0.55f);
}

float fogAmount(float depth) {
    float far = float(drawSegments - 2) * segmentLength;
    return max(0.88f * (1.0f - exp(-depth / 560.0f)), smoothstep(0.78f * far, far, depth));
}

float lineCoverage(float distanceToLine, float halfWidth, float footprint) {
    float soft = max(footprint, 0.001f);
    float area = clamp(halfWidth * 2.0f / soft, 0.0f, 1.0f);
    return clamp((halfWidth - distanceToLine) / soft + 0.5f, 0.0f, 1.0f) * area;
}

// A repeating on/off pattern along the road that fades to its average when a
// pixel row spans more than a period.
float bandPattern(float along, float period, float footprintAlong) {
    float on = fract(along / period) < 0.5f ? 1.0f : 0.0f;
    return mix(on, 0.5f, smoothstep(0.25f * period, 0.9f * period, footprintAlong));
}

float3 skyColor(float2 pixel, float2 resolution, device const GameState &game, Look look,
    texture2d<float> backdrop, float time) {
    float2 uv = backdropUV(pixel, resolution, game.view.y, game.effects.y);
    float3 color = fromDisplayLinear(textureAlbedo(backdrop,
        float2(uv.x, min(uv.y, 0.985f)))) * look.grade;
    if (look.stars > 0.0f) {
        float2 cell = floor(pixel / 3.0f);
        float star = hash01(uint(cell.x) * 1973u + uint(cell.y) * 9277u + 17u);
        float twinkle = 0.6f + 0.4f * sin(time * 2.0f + star * 40.0f);
        float upper = 1.0f - smoothstep(0.15f, 0.62f, pixel.y / max(game.view.y, 1.0f));
        float dark = 1.0f - smoothstep(0.05f, 0.25f, lumaOf(color));
        color += float3(0.9f, 0.9f, 1.1f) * step(0.9965f, star) * twinkle * upper * dark;
    }
    if (uv.y > 0.965f) {
        color = mix(color, hazeAt(pixel, resolution, game, look, backdrop),
            smoothstep(0.965f, 1.08f, uv.y));
    }
    return color;
}

float3 groundColor(float2 pixel, float4 row, device const GameState &game, Look look,
    texture2d<float> asphalt, texture2d<float> sand) {
    float depth = 1.0f / max(row.z, 0.00001f);
    float along = row.w;
    float lateral = (pixel.x - row.x) / max(row.y, 0.0001f) * roadHalfWidth;
    float side = abs(lateral);
    float footprint = roadHalfWidth / max(row.y, 0.0001f);
    float footprintAlong = footprint * depth / cameraHeight;
    float near = 1.0f - smoothstep(120.0f, 420.0f, depth);

    // Desert sand with the classic alternating bands for a sense of speed.
    float3 color = textureAlbedo(sand, float2(lateral, along) / 11.0f)
        * float3(1.0f, 0.93f, 0.84f);
    color *= mix(1.0f, 0.9f, bandPattern(along, 2.0f * segmentLength, footprintAlong) * near);
    float verge = 1.0f - smoothstep(roadHalfWidth + 0.9f, roadHalfWidth + 4.0f, side);
    color *= 1.0f - 0.18f * verge;

    if (side < roadHalfWidth + 0.9f) {
        if (side < roadHalfWidth) {
            float3 road = textureAlbedo(asphalt, float2(lateral, along) / 8.0f);
            road = mix(float3(lumaOf(road)), road, 0.35f) * 0.62f + float3(0.012f);
            // Darker tyre lines in each lane.
            float lanes = abs(fract((lateral + 1.8f) / 3.6f) - 0.5f) * 3.6f;
            road *= 1.0f - 0.18f * lineCoverage(abs(lanes - 0.9f), 0.35f, footprint) * near;
            float paint = lineCoverage(abs(side - (roadHalfWidth - 0.45f)), 0.12f, footprint);
            float dash = lineCoverage(abs(side - 1.8f), 0.09f, footprint)
                * bandPattern(along, 12.0f, footprintAlong);
            road = mix(road, float3(0.85f, 0.83f, 0.78f), max(paint, dash) * 0.9f);
            float start = along < 3.0f ? 1.0f : 0.0f;
            if (start > 0.0f) {
                int2 check = int2(floor(float2(lateral, along) / 0.75f));
                float white = ((check.x + check.y) & 1) == 0 ? 1.0f : 0.0f;
                float fade = smoothstep(0.4f, 1.2f, footprint);
                road = mix(road, mix(float3(0.02f), float3(0.9f), mix(white, 0.5f, fade)),
                    0.95f);
            }
            color = road;
        } else {
            float red = bandPattern(along, 6.0f, footprintAlong);
            color = mix(float3(0.80f, 0.78f, 0.74f), float3(0.62f, 0.05f, 0.03f), red);
        }
    }

    // Hills: slopes facing the camera catch a little more light.
    int count = int(game.notice.z);
    int index = clamp(int(along / segmentLength), 0, count - 1);
    float slope = (game.segments[(index + 1) % count].y - game.segments[index].y)
        / segmentLength;
    color *= look.sun * clamp(1.0f + slope * 2.2f, 0.72f, 1.25f);

    // The chosen line, as a chevron painted a few metres ahead of the car.
    if (game.flow.x == phaseRacing) {
        float ahead = depth - (cameraBack + 7.0f);
        float across = lateral - game.driver.x * roadHalfWidth;
        if (abs(ahead) < 4.0f && abs(across) < 1.8f) {
            float chevron = abs(ahead + 0.9f * abs(across) - 1.0f);
            float mark = lineCoverage(chevron, 0.28f, footprintAlong)
                * (1.0f - smoothstep(1.2f, 1.8f, abs(across)));
            color = mix(color, float3(0.30f, 1.10f, 1.20f), 0.55f * mark);
        }
    }
    return color;
}

fragment float4 worldFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> backdrop [[texture(1)]],
    texture2d<float> asphalt [[texture(2)]],
    texture2d<float> sand [[texture(3)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 pixel = in.uv * resolution;
    Look look = lookFor(game.flow.y);
    int r = clamp(int(pixel.y), 0, maxRows - 1);
    float4 row = game.rows[r];
    float3 color;
    if (row.y < 0.0f) {
        color = skyColor(pixel, resolution, game, look, backdrop, u.resolutionTime.z);
    } else {
        color = groundColor(pixel, row, game, look, asphalt, sand);
        float depth = 1.0f / max(row.z, 0.00001f);
        color = mix(color, hazeAt(pixel, resolution, game, look, backdrop), fogAmount(depth));
    }
    return float4(toDisplay(color), 1.0f);
}


// ---------------------------------------------------------------------------
// Pixel-font text in any space with y down; one font dot is `cell` units.

float glyphDot(uint code, int column, int row) {
    if (code < 32u || code > 90u || column < 0 || column > 4 || row < 0 || row > 6) {
        return 0.0f;
    }
    uint bits = uint(fontRows[(code - 32u) * 7u + uint(row)]);
    return float((bits >> uint(4 - column)) & 1u);
}

float charCoverage(float2 p, float2 origin, float cell, uint code) {
    float2 spot = (p - origin) / cell;
    if (spot.x < 0.0f || spot.y < 0.0f || spot.x >= 5.0f || spot.y >= 7.0f) return 0.0f;
    return glyphDot(code, int(spot.x), int(spot.y));
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

// ---------------------------------------------------------------------------
// Sprite shapes, in metres with y up from the ground line

float sdBox(float2 q, float2 halfSize) {
    float2 d = abs(q) - halfSize;
    return length(max(d, float2(0.0f))) + min(max(d.x, d.y), 0.0f);
}

float sdRoundBox(float2 q, float2 halfSize, float radius) {
    return sdBox(q, halfSize - float2(radius)) - radius;
}

float sdCapsule(float2 q, float2 a, float2 b, float radius) {
    float2 pa = q - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0f, 1.0f);
    return length(pa - ba * h) - radius;
}

float sdEllipse(float2 q, float2 radii) {
    return (length(q / radii) - 1.0f) * min(radii.x, radii.y);
}

float smin(float a, float b, float k) {
    float h = clamp(0.5f + 0.5f * (b - a) / k, 0.0f, 1.0f);
    return mix(b, a, h) - k * h * (1.0f - h);
}

float fillOf(float d, float px) {
    return clamp(0.5f - d / max(px, 0.0001f), 0.0f, 1.0f);
}

// Premultiplied "over" compositing inside one sprite.
void layer(thread float4 &acc, float3 color, float alpha) {
    acc.rgb = color * alpha + acc.rgb * (1.0f - alpha);
    acc.a = alpha + acc.a * (1.0f - alpha);
}

void paintPost(thread float4 &acc, float2 q, float px, Look look) {
    float a = fillOf(sdBox(q - float2(0.0f, 0.55f), float2(0.09f, 0.55f)), px);
    if (a <= 0.0f) return;
    float3 color = float3(0.85f, 0.84f, 0.80f) * look.sun * (q.x < 0.0f ? 1.0f : 0.72f);
    if (q.y > 0.78f && q.y < 0.90f) color = float3(0.03f);
    if (q.y > 0.93f && q.y < 1.05f) color = float3(1.6f, 0.10f, 0.04f);
    layer(acc, color, a);
}

void paintCactus(thread float4 &acc, float2 q, float px, Look look,
    texture2d<float> sand, float seed) {
    float flip = fract(seed * 0.618f) > 0.5f ? -1.0f : 1.0f;
    float2 p = float2(q.x * flip, q.y);
    float trunk = sdCapsule(p, float2(0.0f, 0.0f), float2(0.0f, 5.0f), 0.42f);
    float left = min(sdCapsule(p, float2(0.0f, 2.2f), float2(-1.15f, 2.2f), 0.30f),
        sdCapsule(p, float2(-1.15f, 2.2f), float2(-1.15f, 3.8f), 0.30f));
    float right = min(sdCapsule(p, float2(0.0f, 2.9f), float2(1.0f, 2.9f), 0.28f),
        sdCapsule(p, float2(1.0f, 2.9f), float2(1.0f, 4.3f), 0.28f));
    float d = min(trunk, min(left, right));
    float a = fillOf(d, px);
    if (a <= 0.0f) return;
    float across = p.x / 0.42f;
    if (left < trunk && left < right) across = (p.x + 1.15f) / 0.30f;
    if (right < trunk && right <= left) across = (p.x - 1.0f) / 0.28f;
    across = clamp(across * flip, -1.0f, 1.0f);
    float ribs = 0.80f + 0.20f * cos(across * 7.0f);
    float light = 0.62f - 0.38f * across;
    float3 detail = textureAlbedo(sand, q * 0.35f);
    float3 green = float3(0.055f, 0.20f, 0.075f) * (0.6f + 0.8f * lumaOf(detail));
    layer(acc, green * ribs * light * look.sun, a);
}

// A hoodoo: a weathered sandstone spire of uneven ledges under a cap rock.
void paintHoodoo(thread float4 &acc, float2 q, float px, Look look,
    texture2d<float> sandstone, float seed) {
    float d = 1.0e9f;
    for (int i = 0; i < 4; ++i) {
        float jitter = fract(seed * 1.37f + float(i) * 0.61f);
        float y = 0.9f + 1.55f * float(i);
        float halfWidth = 1.55f - 0.26f * float(i) + 0.35f * jitter;
        float lean = 0.18f * sin(seed + float(i) * 1.7f);
        d = smin(d, sdRoundBox(q - float2(lean, y), float2(halfWidth, 0.95f), 0.55f), 0.35f);
    }
    float neck = sdBox(q - float2(0.0f, 6.6f), float2(0.55f, 0.6f));
    d = smin(d, neck, 0.25f);
    float cap = sdRoundBox(q - float2(0.15f, 7.55f), float2(1.75f, 0.45f), 0.35f);
    float a = fillOf(min(d, cap), px);
    if (a <= 0.0f) return;
    float3 stone = textureAlbedo(sandstone, q * 0.18f + float2(seed, 0.0f));
    float ledges = 0.80f + 0.20f * smoothstep(-0.2f, 0.2f, sin(q.y * 4.05f + 1.0f));
    float3 color = stone * float3(1.0f, 0.64f, 0.48f) * ledges;
    if (cap < d) color = stone * float3(0.62f, 0.46f, 0.38f);
    float light = clamp(0.82f - 0.32f * q.x, 0.45f, 1.15f);
    layer(acc, color * light * look.sun, a);
}

void paintMesa(thread float4 &acc, float2 q, float px, Look look,
    texture2d<float> sandstone, float seed) {
    float top = 19.0f + 3.0f * fract(seed * 0.37f) + 0.6f * sin(q.x * 0.4f + seed);
    float halfWidth = mix(22.0f, 12.5f, smoothstep(0.0f, top, q.y))
        + 1.4f * sin(q.y * 0.9f + seed);
    float d = max(abs(q.x) - halfWidth, max(q.y - top, -q.y - 0.5f));
    float a = fillOf(d, px * 1.5f);
    if (a <= 0.0f) return;
    float3 stone = textureAlbedo(sandstone, q * 0.05f + float2(seed, 0.3f));
    float strata = 0.74f + 0.26f * sin(q.y * 1.2f + 0.3f * sin(q.x * 0.2f));
    float light = clamp(0.80f - 0.35f * q.x / halfWidth, 0.42f, 1.15f);
    layer(acc, stone * float3(1.0f, 0.58f, 0.42f) * strata * light * look.sun, a);
}

void paintBillboard(thread float4 &acc, float2 q, float px, Look look,
    texture2d<float> wood, texture2d<float> poster, int variant) {
    for (int side = -1; side <= 1; side += 2) {
        float post = fillOf(sdBox(q - float2(3.3f * float(side), 2.0f), float2(0.16f, 2.0f)), px);
        if (post > 0.0f) {
            float3 grain = textureAlbedo(wood, float2(q.x * 0.6f, q.y * 0.12f));
            layer(acc, grain * 0.55f * look.sun, post);
        }
    }
    float frame = fillOf(sdBox(q - float2(0.0f, 5.35f), float2(4.75f, 2.05f)), px);
    if (frame <= 0.0f) return;
    float3 plank = textureAlbedo(wood, float2(q.x * 0.15f, q.y * 0.5f));
    layer(acc, plank * 0.9f * look.sun, frame);
    float picture = fillOf(sdBox(q - float2(0.0f, 5.75f), float2(4.45f, 1.45f)), px);
    if (picture > 0.0f) {
        // The middle band of the square poster keeps its proportions.
        float2 uv = float2((q.x + 4.45f) / 8.9f, 0.33f + 0.34f * (7.2f - q.y) / 2.9f);
        layer(acc, textureAlbedo(poster, uv) * look.sun * 0.95f, picture);
    }
    float strip = fillOf(sdBox(q - float2(0.0f, 3.82f), float2(4.45f, 0.42f)), px);
    if (strip > 0.0f) {
        int text = textBoard1 + clamp(variant, 0, 3);
        float cell = min(0.085f, 8.4f / (float(textRanges[text * 2 + 1]) * 6.0f));
        float width = textWidth(text, cell);
        float ink = textCoverage(float2(q.x, -q.y), float2(-0.5f * width, -3.82f - 3.5f * cell),
            cell, text);
        float3 paper = mix(float3(0.82f, 0.74f, 0.55f), float3(0.45f, 0.04f, 0.03f), ink);
        layer(acc, paper * look.sun, strip);
    }
}

void paintGantry(thread float4 &acc, float2 q, float px, Look look) {
    float postX = roadHalfWidth + 0.9f;
    for (int side = -1; side <= 1; side += 2) {
        float post = fillOf(sdBox(q - float2(postX * float(side), 4.4f), float2(0.22f, 4.4f)), px);
        if (post > 0.0f) {
            float band = fract(q.y * 0.8f) < 0.5f ? 1.0f : 0.55f;
            layer(acc, float3(0.42f, 0.42f, 0.45f) * band * look.sun, post);
        }
    }
    float banner = fillOf(sdBox(q - float2(0.0f, 7.7f), float2(7.1f, 1.05f)), px);
    if (banner <= 0.0f) return;
    float3 color = float3(0.42f, 0.035f, 0.025f);
    if (abs(q.y - 7.7f) > 0.75f) {
        int2 check = int2(floor(float2(q.x, q.y) / 0.3f));
        color = ((check.x + check.y) & 1) == 0 ? float3(0.9f) : float3(0.02f);
    } else {
        float cell = 0.105f;
        float width = textWidth(textTitle, cell);
        float ink = textCoverage(float2(q.x, -q.y), float2(-0.5f * width, -7.7f - 3.5f * cell),
            cell, textTitle);
        color = mix(color, float3(1.25f, 0.95f, 0.18f), ink);
    }
    layer(acc, color * look.sun, banner);
}

void paintDevil(thread float4 &acc, float2 q, Look look, texture2d<float> sand,
    float time, float index) {
    float phase = index * 2.7f;
    float h = clamp(q.y, 0.0f, 16.0f);
    float halfWidth = 0.55f + 0.2f * h + 0.3f * sin(h * 0.7f - time * 2.3f + phase);
    float centre = 0.7f * sin(h * 0.33f + time * 1.2f + phase) * (h / 16.0f);
    float across = (q.x - centre) / halfWidth;
    float body = 1.0f - smoothstep(0.5f, 1.0f, abs(across));
    float fade = smoothstep(-0.4f, 0.8f, q.y) * (1.0f - smoothstep(9.5f, 15.5f, q.y));
    float around = across * 1.4f + time * 3.0f - q.y * 0.35f + phase;
    float3 grit = textureAlbedo(sand, float2(around * 0.3f, q.y * 0.07f - time * 0.5f));
    float streak = 0.55f + 0.45f * sin(around * 4.0f + q.y * 1.3f);
    float density = body * fade * (0.30f + 0.55f * streak * clamp(lumaOf(grit) * 2.2f, 0.0f, 1.0f));
    float puff = 1.0f - smoothstep(0.4f, 1.0f, length((q - float2(0.0f, 0.5f)) / float2(2.8f, 1.3f)));
    puff *= 0.55f + 0.45f * sin(q.x * 3.0f + time * 4.0f + phase);
    float alpha = clamp(max(density, puff * 0.55f), 0.0f, 0.8f);
    if (alpha <= 0.002f) return;
    float3 color = mix(float3(0.50f, 0.37f, 0.25f), grit, 0.45f)
        * (0.75f + 0.35f * (1.0f - abs(across)));
    layer(acc, color * look.sun, alpha);
}

float3 carPaint(int index) {
    if (index == 0) return fromSRGBish(float3(0.94f, 0.94f, 0.96f));
    if (index == 1) return fromSRGBish(float3(0.80f, 0.08f, 0.06f));
    if (index == 2) return fromSRGBish(float3(0.90f, 0.50f, 0.16f));
    if (index == 3) return fromSRGBish(float3(0.12f, 0.58f, 0.22f));
    if (index == 4) return fromSRGBish(float3(0.97f, 0.80f, 0.10f));
    if (index == 5) return fromSRGBish(float3(0.50f, 0.18f, 0.66f));
    if (index == 6) return fromSRGBish(float3(0.12f, 0.34f, 0.88f));
    return fromSRGBish(float3(0.74f, 0.66f, 0.48f));
}

float3 carStripe(int index) {
    if (index == 0) return fromSRGBish(float3(1.0f, 0.45f, 0.05f));
    if (index == 2 || index == 7) return fromSRGBish(float3(0.30f, 0.12f, 0.05f));
    if (index == 3 || index == 5) return fromSRGBish(float3(0.98f, 0.85f, 0.25f));
    if (index == 4) return float3(0.02f);
    return fromSRGBish(float3(0.95f, 0.95f, 0.95f));
}

// A rear view of a rally car. Bits: 1 nitro, 2 off-road dust, 4 sliding,
// 8 crashed, 16 bumped.
void paintCar(thread float4 &acc, float2 q, float px, Look look, texture2d<float> sand,
    int index, float steer, bool braking, uint bits, float time, bool dusk) {
    float shake = (bits & 24u) != 0u ? 0.04f * sin(time * 47.0f) : 0.0f;
    float shadow = 1.0f - smoothstep(0.7f, 1.0f, length((q - float2(0.0f, 0.02f))
        / float2(1.25f, 0.16f)));
    if (shadow > 0.0f) layer(acc, float3(0.0f), shadow * 0.55f);
    float2 p = float2(q.x - steer * 0.10f * max(q.y, 0.0f) - shake, q.y);
    float3 paint = carPaint(index) * look.sun;
    float3 stripeColor = carStripe(index) * look.sun;

    float tyre = fillOf(sdRoundBox(float2(abs(p.x) - 0.78f, p.y - 0.25f),
        float2(0.15f, 0.25f), 0.06f), px);
    if (tyre > 0.0f) layer(acc, float3(0.025f), tyre);

    float body = fillOf(sdRoundBox(p - float2(0.0f, 0.63f), float2(0.98f, 0.31f), 0.14f), px);
    if (body > 0.0f) {
        float gleam = (p.y - 0.84f) * 14.0f;
        float shade = 0.62f + 0.38f * smoothstep(0.32f, 0.92f, p.y)
            + 0.25f * exp(-gleam * gleam);
        float3 color = paint * shade;
        if (abs(abs(p.x) - 0.2f) < 0.07f) color = stripeColor * shade;
        layer(acc, color, body);
    }
    float bumper = fillOf(sdRoundBox(p - float2(0.0f, 0.37f), float2(0.97f, 0.07f), 0.035f), px);
    if (bumper > 0.0f) layer(acc, float3(0.05f) * look.sun, bumper);

    float cabinT = clamp((p.y - 0.90f) / 0.52f, 0.0f, 1.0f);
    float cabinHalf = mix(0.86f, 0.62f, cabinT);
    float cabin = fillOf(max(abs(p.x) - cabinHalf, max(0.90f - p.y, p.y - 1.42f)), px);
    if (cabin > 0.0f) {
        float3 color = paint * 0.78f;
        if (abs(abs(p.x) - 0.2f) < 0.07f) color = stripeColor * 0.78f;
        layer(acc, color, cabin);
        float glass = fillOf(max(abs(p.x) - (cabinHalf - 0.09f),
            max(0.97f - p.y, p.y - 1.35f)), px);
        if (glass > 0.0f) {
            float glint = (1.0f - smoothstep(0.0f, 0.08f, abs(p.x * 0.6f + p.y - 1.35f))) * 0.5f;
            float3 sky = dusk ? float3(0.05f, 0.04f, 0.09f) : float3(0.07f, 0.09f, 0.12f);
            layer(acc, sky + glint * look.sun * 0.3f, glass);
        }
    }

    for (int side = -1; side <= 1; side += 2) {
        float lamp = fillOf(sdRoundBox(p - float2(0.72f * float(side), 0.77f),
            float2(0.17f, 0.055f), 0.03f), px);
        if (lamp > 0.0f) {
            float3 lit = braking ? float3(3.2f, 0.25f, 0.12f)
                : (dusk ? float3(1.4f, 0.08f, 0.05f) : float3(0.55f, 0.03f, 0.02f));
            layer(acc, lit, lamp);
        }
    }
    float plate = fillOf(sdBox(p - float2(0.0f, 0.535f), float2(0.22f, 0.065f)), px);
    if (plate > 0.0f) {
        float ink = charCoverage(float2(p.x, -p.y), float2(-0.04f, -0.585f), 0.016f,
            uint(48 + index));
        layer(acc, mix(float3(0.85f, 0.78f, 0.52f) * look.sun, float3(0.02f), ink), plate);
    }

    if ((bits & 1u) != 0u) {
        for (int side = -1; side <= 1; side += 2) {
            float2 at = p - float2(0.42f * float(side), 0.30f);
            float flicker = 0.85f + 0.15f * sin(time * 53.0f + float(side) * 2.0f);
            float glow = 1.0f - smoothstep(0.0f, 0.34f * flicker, length(at * float2(1.0f, 1.2f)));
            float core = 1.0f - smoothstep(0.0f, 0.12f, length(at));
            if (glow > 0.0f) {
                layer(acc, mix(float3(3.0f, 1.3f, 0.35f), float3(1.2f, 2.0f, 4.0f), core), glow);
            }
        }
    }
    if ((bits & 14u) != 0u) {
        // Dust or smoke rolling off the wheels.
        bool smoke = (bits & 12u) != 0u;
        float2 drift = float2(q.x * 0.9f, q.y * 0.9f - time * 1.8f);
        float noise = lumaOf(textureAlbedo(sand, drift * 0.45f + float2(time * 0.3f, 0.0f)));
        float cloud = (1.0f - smoothstep(0.5f, 1.0f, length((float2(abs(q.x), q.y)
            - float2(0.85f, 0.25f)) / float2(0.75f, 0.75f))));
        float alpha = clamp(cloud * (0.25f + 1.1f * noise), 0.0f, 0.75f);
        float3 color = smoke ? float3(0.42f, 0.41f, 0.40f) : float3(0.55f, 0.40f, 0.26f);
        if (alpha > 0.0f) layer(acc, color * look.sun, alpha);
    }
}

struct SpriteVertex {
    float4 position [[position]];
    uint index [[flat]];
};

vertex SpriteVertex spriteVertex(uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]], constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]]) {
    device const GameState &game = states[0];
    SpriteVertex out;
    out.index = min(instanceID, uint(maxSprites - 1));
    if (instanceID >= game.flow.w) {
        out.position = float4(-2.0f, -2.0f, 0.0f, 1.0f);
        return out;
    }
    float4 rect = game.sprites[instanceID].rect;
    float2 corner = float2(vertexID == 1u || vertexID == 3u || vertexID == 4u ? 1.0f : 0.0f,
        vertexID == 2u || vertexID == 4u || vertexID == 5u ? 1.0f : 0.0f);
    float2 pixel = mix(rect.xy, rect.zw, corner);
    float2 resolution = u.resolutionTime.xy;
    out.position = float4(pixel.x / resolution.x * 2.0f - 1.0f,
        1.0f - pixel.y / resolution.y * 2.0f, 0.0f, 1.0f);
    return out;
}

fragment float4 spriteFragment(SpriteVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> backdrop [[texture(1)]],
    texture2d<float> sand [[texture(3)]],
    texture2d<float> sandstone [[texture(4)]],
    texture2d<float> wood [[texture(5)]],
    texture2d<float> poster [[texture(6)]]) {
    device const GameState &game = states[0];
    device const Sprite &sprite = game.sprites[in.index];
    float2 pixel = in.position.xy;
    if (pixel.y >= sprite.meta.z) return float4(0.0f);
    float2 resolution = u.resolutionTime.xy;
    float time = u.resolutionTime.z;
    float kind = sprite.meta.x;
    float3 base = spriteSize(kind);
    float2 extent = max(sprite.rect.zw - sprite.rect.xy, float2(0.001f));
    float2 spot = clamp((pixel - sprite.rect.xy) / extent, float2(0.0f), float2(1.0f));
    float2 q = float2((spot.x - 0.5f) * base.x, (1.0f - spot.y) * (base.y + base.z) - base.z);
    float px = base.x / extent.x;
    Look look = lookFor(game.flow.y);
    float seed = sprite.extra.y * 0.731f;
    float4 acc = float4(0.0f);
    if (kind == kindPost) paintPost(acc, q, px, look);
    else if (kind == kindCactus) paintCactus(acc, q, px, look, sand, seed);
    else if (kind == kindHoodoo) paintHoodoo(acc, q, px, look, sandstone, seed);
    else if (kind == kindMesa) paintMesa(acc, q, px, look, sandstone, seed);
    else if (kind == kindBillboard) paintBillboard(acc, q, px, look, wood, poster, int(sprite.extra.x));
    else if (kind == kindGantry) paintGantry(acc, q, px, look);
    else if (kind == kindDevil) paintDevil(acc, q, look, sand, time, sprite.extra.x);
    else {
        paintCar(acc, q, px, look, sand, int(sprite.extra.x), sprite.extra.y,
            sprite.extra.z > 0.5f, uint(sprite.extra.w), time, game.flow.y == 2u);
    }
    if (acc.a <= 0.002f) return float4(0.0f);
    float3 color = acc.rgb / acc.a;
    color = mix(color, hazeAt(pixel, resolution, game, look, backdrop),
        fogAmount(sprite.meta.y));
    return float4(toDisplay(color), clamp(acc.a, 0.0f, 1.0f));
}


// ---------------------------------------------------------------------------
// HUD and screens, painted in display space over the scene

uint digitCount(uint value) {
    uint digits = 1u;
    for (int i = 0; i < 8 && value >= 10u; ++i) {
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
    for (int k = 0; k < 8 && k < count - 1 - index; ++k) v /= 10u;
    return glyphDot(48u + v % 10u, column - index * 6, int(spot.y));
}

float numberWidth(uint value, float cell) {
    return (float(digitCount(value)) * 6.0f - 1.0f) * cell;
}

// Race time as M:SS.T (capped at 9:59.9).
float timeCoverage(float2 p, float2 origin, float cell, float seconds) {
    float2 spot = (p - origin) / cell;
    if (spot.x < 0.0f || spot.y < 0.0f || spot.y >= 7.0f || spot.x >= 36.0f) return 0.0f;
    uint tenths = min(uint(max(seconds, 0.0f) * 10.0f + 0.5f), 5999u);
    uint minutes = tenths / 600u;
    uint secs = (tenths / 10u) % 60u;
    int column = int(spot.x);
    int index = column / 6;
    uint code = 48u + minutes;
    if (index == 1) code = 58u;
    if (index == 2) code = 48u + secs / 10u;
    if (index == 3) code = 48u + secs % 10u;
    if (index == 4) code = 46u;
    if (index == 5) code = 48u + tenths % 10u;
    return glyphDot(code, column - index * 6, int(spot.y));
}

float timeWidth(float cell) {
    return 35.0f * cell;
}

int ordinalText(uint place) {
    if (place == 1u) return textSt;
    if (place == 2u) return textNd;
    if (place == 3u) return textRd;
    return textTh;
}

float roundedRect(float2 p, float2 lower, float2 upper, float radius) {
    float2 centre = 0.5f * (lower + upper);
    float d = sdRoundBox(p - centre, 0.5f * (upper - lower), radius);
    return clamp(0.5f - d, 0.0f, 1.0f);
}

void hudPanel(thread float4 &acc, float2 p, float2 lower, float2 upper, float radius,
    float3 color, float alpha) {
    float a = roundedRect(p, lower, upper, radius) * alpha;
    if (a > 0.0f) layer(acc, color, a);
}

void hudInk(thread float4 &acc, float ink, float shadowInk, float3 color) {
    if (shadowInk > 0.0f) layer(acc, float3(0.0f), 0.75f * shadowInk);
    if (ink > 0.0f) layer(acc, color, ink);
}

void hudText(thread float4 &acc, float2 p, float2 origin, float cell, int text, float3 color) {
    float shadow = textCoverage(p, origin + float2(cell * 0.6f), cell, text);
    hudInk(acc, textCoverage(p, origin, cell, text), shadow, color);
}

void hudCentered(thread float4 &acc, float2 p, float centreX, float y, float cell, int text,
    float3 color) {
    hudText(acc, p, float2(centreX - 0.5f * textWidth(text, cell), y), cell, text, color);
}

void hudNumber(thread float4 &acc, float2 p, float2 origin, float cell, uint value,
    float3 color) {
    float shadow = numberCoverage(p, origin + float2(cell * 0.6f), cell, value);
    hudInk(acc, numberCoverage(p, origin, cell, value), shadow, color);
}

void hudTime(thread float4 &acc, float2 p, float2 origin, float cell, float seconds,
    float3 color) {
    float shadow = timeCoverage(p, origin + float2(cell * 0.6f), cell, seconds);
    hudInk(acc, timeCoverage(p, origin, cell, seconds), shadow, color);
}

void hudChar(thread float4 &acc, float2 p, float2 origin, float cell, uint code, float3 color) {
    float shadow = charCoverage(p, origin + float2(cell * 0.6f), cell, code);
    hudInk(acc, charCoverage(p, origin, cell, code), shadow, color);
}

bool inBox(float2 p, float2 lower, float2 upper) {
    return all(p >= lower) && all(p <= upper);
}

float3 hudWhite() { return float3(0.96f, 0.94f, 0.90f); }
float3 hudGold() { return float3(1.0f, 0.80f, 0.20f); }
float3 hudDim() { return float3(0.72f, 0.68f, 0.62f); }
float3 hudOrange() { return float3(1.0f, 0.52f, 0.10f); }

// Minimap with every car as a dot.
void hudMinimap(thread float4 &acc, float2 p, float2 lower, float size,
    device const GameState &game) {
    if (!inBox(p, lower - float2(4.0f), lower + float2(size + 4.0f))) return;
    int points = int(game.sketch.y);
    int stride = max(int(game.sketch.x), 1);
    float2 q = (p - lower) / size;
    float nearest = 1.0e9f;
    for (int j = 0; j < points; ++j) {
        float2 a = game.minimap[j].xy;
        float2 b = game.minimap[(j + 1) % points].xy;
        float2 pa = q - a;
        float2 ba = b - a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1.0e-8f), 0.0f, 1.0f);
        nearest = min(nearest, length(pa - ba * h));
    }
    float pixel = 1.0f / size;
    float outline = clamp((0.016f - nearest) / pixel + 0.5f, 0.0f, 1.0f);
    float road = clamp((0.009f - nearest) / pixel + 0.5f, 0.0f, 1.0f);
    if (outline > 0.0f) layer(acc, float3(0.05f), outline * 0.8f);
    if (road > 0.0f) layer(acc, float3(0.85f, 0.80f, 0.72f), road);
    float lap = game.view.w;
    for (int i = carCount - 1; i >= 0; --i) {
        float along = wrapDistance(game.cars[i].motion.x, lap) / segmentLength / float(stride);
        int j = min(int(along), points - 1);
        float t = clamp(along - float(j), 0.0f, 1.0f);
        float2 at = mix(game.minimap[j].xy, game.minimap[(j + 1) % points].xy, t);
        float radius = (i == 0 ? 0.034f : 0.024f);
        float blob = clamp((radius - length(q - at)) / pixel + 0.5f, 0.0f, 1.0f);
        if (blob > 0.0f) {
            float3 color = i == 0 ? float3(1.0f, 1.0f, 1.0f) : pow(carPaint(i), float3(1.0f / 2.2f));
            layer(acc, float3(0.0f), clamp((radius + 0.012f - length(q - at)) / pixel + 0.5f, 0.0f, 1.0f));
            layer(acc, color, blob);
        }
    }
}

void paintRaceHud(thread float4 &acc, float2 p, float2 resolution, float s,
    device const GameState &game, float2 pointer) {
    float w = resolution.x;
    float h = resolution.y;
    device const Car &player = game.cars[0];
    uint place = game.control.z;
    if (game.flow.x == phaseFinish) place = game.tally.z;
    place = clamp(place, 1u, 8u);

    // Place and lap.
    if (p.y < 140.0f * s && p.x < 300.0f * s) {
        hudPanel(acc, p, float2(18.0f, 16.0f) * s, float2(282.0f, 128.0f) * s, 14.0f * s,
            float3(0.05f, 0.03f, 0.02f), 0.55f);
        hudText(acc, p, float2(36.0f, 26.0f) * s, 2.5f * s, textPos, hudDim());
        hudNumber(acc, p, float2(36.0f, 50.0f) * s, 8.0f * s, place, hudGold());
        hudText(acc, p, float2(82.0f, 50.0f) * s, 3.6f * s, ordinalText(place), hudGold());
        hudChar(acc, p, float2(82.0f, 86.0f) * s, 3.6f * s, 47u, hudDim());
        hudNumber(acc, p, float2(104.0f, 86.0f) * s, 3.6f * s, uint(carCount), hudDim());
        hudText(acc, p, float2(160.0f, 26.0f) * s, 2.5f * s, textLap, hudDim());
        uint lapNow = min(player.info.x + 1u, game.flow.z);
        hudNumber(acc, p, float2(160.0f, 52.0f) * s, 5.0f * s, lapNow, hudWhite());
        hudChar(acc, p, float2(192.0f, 52.0f) * s, 5.0f * s, 47u, hudDim());
        hudNumber(acc, p, float2(224.0f, 52.0f) * s, 5.0f * s, game.flow.z, hudDim());
    }

    // Race time, best lap and the minimap.
    if (p.y < 340.0f * s && p.x > w - 300.0f * s) {
        hudPanel(acc, p, float2(w - 282.0f * s, 16.0f * s), float2(w - 18.0f * s, 128.0f * s),
            14.0f * s, float3(0.05f, 0.03f, 0.02f), 0.55f);
        hudText(acc, p, float2(w - 262.0f * s, 26.0f * s), 2.5f * s, textTime, hudDim());
        // After the finish the clock keeps running for the rivals; show ours.
        float raceTime = game.timing.x;
        if (game.flow.x == phaseFinish && player.timers.z > 0.0f) raceTime = player.timers.z;
        hudTime(acc, p, float2(w - 262.0f * s, 50.0f * s), 5.0f * s, raceTime, hudWhite());
        hudText(acc, p, float2(w - 262.0f * s, 100.0f * s), 2.5f * s, textBest, hudDim());
        if (game.timing.z > 0.0f) {
            hudTime(acc, p, float2(w - 186.0f * s, 98.0f * s), 3.0f * s, game.timing.z, hudGold());
        }
        hudPanel(acc, p, float2(w - 212.0f * s, 140.0f * s), float2(w - 18.0f * s, 334.0f * s),
            14.0f * s, float3(0.05f, 0.03f, 0.02f), 0.45f);
        hudMinimap(acc, p, float2(w - 200.0f * s, 152.0f * s), 170.0f * s, game);
    }

    // Speed.
    if (p.y > h - 150.0f * s && p.x > w - 330.0f * s) {
        uint kmh = uint(player.motion.z * 3.6f + 0.5f);
        hudPanel(acc, p, float2(w - 312.0f * s, h - 136.0f * s), float2(w - 18.0f * s, h - 18.0f * s),
            14.0f * s, float3(0.05f, 0.03f, 0.02f), 0.55f);
        float cell = 9.0f * s;
        float3 tint = player.timers.x > 0.0f ? float3(0.45f, 0.85f, 1.0f) : hudWhite();
        hudNumber(acc, p, float2(w - 140.0f * s - numberWidth(kmh, cell), h - 122.0f * s),
            cell, kmh, tint);
        hudText(acc, p, float2(w - 124.0f * s, h - 76.0f * s), 3.0f * s, textKmh, hudDim());
        float fill = clamp(player.motion.z / nitroSpeed, 0.0f, 1.0f);
        float2 barLow = float2(w - 296.0f * s, h - 44.0f * s);
        float2 barHigh = float2(w - 34.0f * s, h - 32.0f * s);
        hudPanel(acc, p, barLow, barHigh, 5.0f * s, float3(0.15f), 0.8f);
        float2 litHigh = float2(mix(barLow.x, barHigh.x, fill), barHigh.y);
        float3 barColor = fill > maxSpeed / nitroSpeed ? float3(0.40f, 0.80f, 1.0f) : hudOrange();
        if (fill > 0.01f) hudPanel(acc, p, barLow, litHigh, 5.0f * s, barColor, 1.0f);
    }

    // Nitro canisters and the pad: where the pointer sits on the Trackpad.
    if (p.y > h - 170.0f * s && p.x < 420.0f * s) {
        hudPanel(acc, p, float2(18.0f * s, h - 156.0f * s), float2(400.0f * s, h - 18.0f * s),
            14.0f * s, float3(0.05f, 0.03f, 0.02f), 0.55f);
        hudText(acc, p, float2(36.0f * s, h - 142.0f * s), 2.5f * s, textNitro, hudDim());
        for (int i = 0; i < 5; ++i) {
            float2 lower = float2(36.0f + float(i) * 34.0f, 0.0f) * s + float2(0.0f, h - 118.0f * s);
            float2 upper = lower + float2(24.0f, 50.0f) * s;
            bool full = uint(i) < game.control.y;
            hudPanel(acc, p, lower, upper, 7.0f * s, full ? hudOrange() : float3(0.22f), full ? 1.0f : 0.6f);
            if (full) hudPanel(acc, p, lower + float2(5.0f, 6.0f) * s, upper - float2(13.0f, 8.0f) * s,
                3.0f * s, float3(1.0f, 0.85f, 0.55f), 0.8f);
        }
        if (player.timers.x > 0.0f) {
            float2 lower = float2(36.0f * s, h - 56.0f * s);
            float2 upper = float2((36.0f + 166.0f * player.timers.x / nitroSeconds) * s, h - 46.0f * s);
            hudPanel(acc, p, lower, upper, 4.0f * s, float3(0.45f, 0.85f, 1.0f), 1.0f);
        }
        // The pad: gas, coast and brake zones with the pointer position.
        float2 padLow = float2(250.0f * s, h - 146.0f * s);
        float2 padHigh = float2(386.0f * s, h - 30.0f * s);
        if (inBox(p, padLow - float2(2.0f), padHigh + float2(2.0f))) {
            float t = (p.y - padLow.y) / (padHigh.y - padLow.y);
            float3 zone = t < 0.52f ? float3(0.10f, 0.42f, 0.16f)
                : (t < 0.78f ? float3(0.25f, 0.24f, 0.22f) : float3(0.50f, 0.08f, 0.06f));
            hudPanel(acc, p, padLow, padHigh, 6.0f * s, zone, 0.85f);
            float lane = abs(fract((p.x - padLow.x) / (padHigh.x - padLow.x) * 3.0f) - 0.5f);
            if (lane > 0.47f) layer(acc, float3(0.0f), 0.25f);
            float2 marker = mix(padLow, padHigh, clamp(pointer, float2(0.0f), float2(1.0f)));
            float ring = clamp(7.5f * s - length(p - marker) + 0.5f, 0.0f, 1.0f);
            float core = clamp(5.0f * s - length(p - marker) + 0.5f, 0.0f, 1.0f);
            if (ring > 0.0f) layer(acc, float3(0.0f), ring);
            if (core > 0.0f) layer(acc, float3(1.0f), core);
        }
        hudText(acc, p, padLow + float2(8.0f, 8.0f) * s, 2.2f * s, textGas, float3(0.75f, 1.0f, 0.75f));
        hudText(acc, p, float2(padLow.x + 8.0f * s, mix(padLow.y, padHigh.y, 0.84f)), 2.2f * s,
            textBrake, float3(1.0f, 0.75f, 0.7f));
    }
}


int trackName(uint race) {
    return textTrack1 + int(min(race, 2u));
}

// Large centred message with a short pop-in.
void paintNotice(thread float4 &acc, float2 p, float2 resolution, float s,
    device const GameState &game) {
    float age = game.effects.x;
    int text = int(game.notice.x);
    if (age > 1.8f || text <= 0) return;
    if (game.flow.x != phaseRacing && game.flow.x != phaseFinish) return;
    float y = resolution.y * 0.20f;
    if (abs(p.y - y) > 70.0f * s) return;
    float pop = 1.0f + 0.35f * (1.0f - smoothstep(0.0f, 0.18f, age));
    // Long messages shrink so they stay clear of the corner panels.
    float fit = (resolution.x - 640.0f * s) / (float(textRanges[text * 2 + 1] + 4) * 6.0f);
    float cell = min(6.0f * s, fit) * pop;
    float3 color = text == textCrash || text == textDustDevil || text == textNoNitro
        || text == textSlide || text == textOffRoad ? float3(1.0f, 0.45f, 0.30f)
        : (text == textNitroOn ? float3(0.45f, 0.85f, 1.0f) : hudGold());
    float fade = 1.0f - smoothstep(1.3f, 1.8f, age);
    float4 before = acc;
    float width = textWidth(text, cell);
    uint number = game.notice.y;
    bool ordinal = text == textFinished;
    float extra = 0.0f;
    if (number > 0u) {
        extra = 6.0f * cell + numberWidth(number, cell);
        if (ordinal) extra += 6.0f * cell * 2.0f;
    }
    float x = 0.5f * resolution.x - 0.5f * (width + extra);
    hudText(acc, p, float2(x, y - 3.5f * cell), cell, text, color);
    if (number > 0u) {
        float nx = x + width + 6.0f * cell;
        hudNumber(acc, p, float2(nx, y - 3.5f * cell), cell, number, color);
        if (ordinal) {
            hudText(acc, p, float2(nx + numberWidth(number, cell) + cell, y - 3.5f * cell),
                cell, ordinalText(number), color);
        }
    }
    acc = mix(before, acc, fade);
}

void paintCountdown(thread float4 &acc, float2 p, float2 resolution, float s,
    device const GameState &game) {
    float w = resolution.x;
    float h = resolution.y;
    float t = game.timing.w;
    float cx = 0.5f * w;
    if (p.y > 0.12f * h && p.y < 0.50f * h) {
        hudPanel(acc, p, float2(cx - 330.0f * s, 0.14f * h), float2(cx + 330.0f * s, 0.14f * h + 210.0f * s),
            18.0f * s, float3(0.05f, 0.03f, 0.02f), 0.62f);
        float y = 0.14f * h + 22.0f * s;
        float cell = 3.4f * s;
        float raceWidth = textWidth(textRace, cell) + 6.0f * cell + 5.0f * cell + 6.0f * cell
            + textWidth(textOf, cell) + 6.0f * cell + 5.0f * cell;
        float x = cx - 0.5f * raceWidth;
        hudText(acc, p, float2(x, y), cell, textRace, hudDim());
        x += textWidth(textRace, cell) + 6.0f * cell;
        hudNumber(acc, p, float2(x, y), cell, game.flow.y + 1u, hudWhite());
        x += 11.0f * cell;
        hudText(acc, p, float2(x, y), cell, textOf, hudDim());
        x += textWidth(textOf, cell) + 6.0f * cell;
        hudNumber(acc, p, float2(x, y), cell, 3u, hudWhite());
        hudCentered(acc, p, cx, y + 36.0f * s, 6.0f * s, trackName(game.flow.y), hudGold());
        for (int i = 0; i < 3; ++i) {
            float2 centre = float2(cx + float(i - 1) * 80.0f * s, 0.14f * h + 160.0f * s);
            float onAt = 0.4f + float(i);
            bool green = t >= countdownSeconds - 0.15f;
            float3 lamp = green ? float3(0.2f, 1.0f, 0.35f)
                : (t >= onAt ? float3(1.0f, 0.12f, 0.06f) : float3(0.18f, 0.06f, 0.05f));
            float rim = clamp(30.0f * s - length(p - centre) + 0.5f, 0.0f, 1.0f);
            float bulb = clamp(24.0f * s - length(p - centre) + 0.5f, 0.0f, 1.0f);
            if (rim > 0.0f) layer(acc, float3(0.02f), rim);
            if (bulb > 0.0f) layer(acc, lamp, bulb);
        }
    }
}

void paintTitle(thread float4 &acc, float2 p, float2 resolution, float s, float time,
    device const GameState &game) {
    float w = resolution.x;
    float h = resolution.y;
    float cx = 0.5f * w;
    float top = 0.13f * h;
    float bottom = top + 500.0f * s;
    if (p.y < top - 10.0f * s || p.y > bottom + 10.0f * s) {
        hudText(acc, p, float2(24.0f, 20.0f) * s, 2.5f * s, textDemo, hudDim());
        return;
    }
    hudPanel(acc, p, float2(cx - 440.0f * s, top), float2(cx + 440.0f * s, bottom), 22.0f * s,
        float3(0.06f, 0.035f, 0.02f), 0.72f);
    hudCentered(acc, p, cx, top + 30.0f * s, 6.4f * s, textTitle, hudOrange());
    hudCentered(acc, p, cx, top + 92.0f * s, 3.4f * s, textSubtitle, hudGold());
    float cell = 2.8f * s;
    for (int i = 0; i < 6; ++i) {
        hudCentered(acc, p, cx, top + (150.0f + 36.0f * float(i)) * s, cell,
            textHelp1 + i, hudWhite());
    }
    float blink = 0.55f + 0.45f * sin(time * 4.0f);
    float4 before = acc;
    hudCentered(acc, p, cx, top + 400.0f * s, 4.4f * s, textPressStart, hudGold());
    acc = mix(before, acc, blink);
    // First race name under the prompt.
    float y = top + 452.0f * s;
    float c2 = 2.6f * s;
    float width = textWidth(textRace, c2) + 11.0f * c2 + textWidth(trackName(game.control.w), c2);
    float x = cx - 0.5f * width;
    hudText(acc, p, float2(x, y), c2, textRace, hudDim());
    hudNumber(acc, p, float2(x + textWidth(textRace, c2) + 6.0f * c2, y), c2, game.control.w + 1u, hudDim());
    hudText(acc, p, float2(x + textWidth(textRace, c2) + 17.0f * c2, y), c2,
        trackName(game.control.w), hudDim());
}

void paintResults(thread float4 &acc, float2 p, float2 resolution, float s, float time,
    device const GameState &game) {
    float w = resolution.x;
    float h = resolution.y;
    float cx = 0.5f * w;
    float top = 0.09f * h;
    float bottom = top + 560.0f * s;
    if (p.y < top - 10.0f * s || p.y > bottom + 10.0f * s
        || abs(p.x - cx) > 400.0f * s) return;
    hudPanel(acc, p, float2(cx - 380.0f * s, top), float2(cx + 380.0f * s, bottom), 20.0f * s,
        float3(0.06f, 0.035f, 0.02f), 0.78f);
    hudCentered(acc, p, cx, top + 24.0f * s, 5.0f * s, textResults, hudOrange());
    hudCentered(acc, p, cx, top + 70.0f * s, 3.0f * s, trackName(game.flow.y), hudGold());
    float cell = 3.2f * s;
    for (int k = 0; k < carCount; ++k) {
        float y = top + (112.0f + 44.0f * float(k)) * s;
        if (p.y < y - 12.0f * s || p.y > y + 34.0f * s) continue;
        int car = int(game.results[k].x);
        bool mine = car == 0;
        if (mine) {
            hudPanel(acc, p, float2(cx - 350.0f * s, y - 9.0f * s), float2(cx + 350.0f * s, y + 31.0f * s),
                8.0f * s, float3(0.55f, 0.32f, 0.05f), 0.65f);
        }
        float3 ink = mine ? float3(1.0f) : (k < 3 ? hudGold() : hudWhite());
        float x = cx - 330.0f * s;
        hudNumber(acc, p, float2(x, y), cell, uint(k + 1), ink);
        hudText(acc, p, float2(x + 6.0f * cell, y), cell * 0.75f, ordinalText(uint(k + 1)), ink);
        float2 swatchLow = float2(x + 90.0f * s, y + 2.0f * s);
        hudPanel(acc, p, swatchLow, swatchLow + float2(18.0f, 18.0f) * s, 4.0f * s,
            pow(carPaint(car), float3(1.0f / 2.2f)), 1.0f);
        hudText(acc, p, float2(x + 124.0f * s, y), cell, textName0 + car, ink);
        hudTime(acc, p, float2(x + 400.0f * s, y), cell, game.results[k].y, ink);
        hudChar(acc, p, float2(x + 560.0f * s, y), cell, 43u, ink);
        hudNumber(acc, p, float2(x + 560.0f * s + 6.0f * cell, y), cell, uint(game.results[k].z), ink);
    }
    float y = top + 478.0f * s;
    float c2 = 2.6f * s;
    float width = textWidth(textCupPoints, c2) + 6.0f * c2 + numberWidth(game.tally.x + game.tally.y, c2);
    hudText(acc, p, float2(cx - 0.5f * width, y), c2, textCupPoints, hudDim());
    bool qualified = game.tally.z <= 3u;
    uint shown = game.tally.x;
    if (qualified) shown += game.tally.y;
    hudNumber(acc, p, float2(cx - 0.5f * width + textWidth(textCupPoints, c2) + 6.0f * c2, y), c2,
        shown, hudGold());
    if (game.timing.w > 0.8f) {
        int prompt = textRetry;
        if (qualified) prompt = game.flow.y < 2u ? int(textQualified) : int(textToTrophy);
        float blink = 0.6f + 0.4f * sin(time * 4.0f);
        float4 before = acc;
        hudCentered(acc, p, cx, top + 514.0f * s, 2.9f * s, prompt,
            qualified ? float3(0.55f, 1.0f, 0.55f) : float3(1.0f, 0.55f, 0.45f));
        acc = mix(before, acc, blink);
    }
}

void paintTrophy(thread float4 &acc, float2 p, float2 centre, float s, float3 tint) {
    float2 q = (p - centre) / s;   // y down
    float bowl = max(sdEllipse(q - float2(0.0f, -60.0f), float2(58.0f, 64.0f)), -(q.y + 60.0f));
    float rim = sdRoundBox(q - float2(0.0f, -60.0f), float2(64.0f, 6.0f), 3.0f);
    float2 side = float2(abs(q.x) - 58.0f, q.y + 30.0f);
    float handle = max(abs(length(side) - 22.0f) - 5.0f, -side.x);
    float stem = sdBox(q - float2(0.0f, 18.0f), float2(9.0f, 16.0f));
    float foot = sdRoundBox(q - float2(0.0f, 44.0f), float2(44.0f, 10.0f), 4.0f);
    float d = min(min(min(bowl, rim), handle), min(stem, foot));
    float a = clamp(0.5f - d * s, 0.0f, 1.0f);
    if (a <= 0.0f) return;
    float shine = 0.78f + 0.40f * (1.0f - smoothstep(-40.0f, 20.0f, q.x))
        - 0.22f * smoothstep(10.0f, 60.0f, q.x);
    layer(acc, clamp(tint * shine, float3(0.0f), float3(1.0f)), a);
    float star = abs(q.x) * 0.6f + abs(q.y + 22.0f);
    if (star < 14.0f && bowl < 0.0f) {
        layer(acc, float3(1.0f, 0.97f, 0.85f), clamp(14.0f - star, 0.0f, 1.0f) * 0.85f);
    }
}

void paintChampion(thread float4 &acc, float2 p, float2 resolution, float s, float time,
    device const GameState &game) {
    float w = resolution.x;
    float h = resolution.y;
    float cx = 0.5f * w;
    float top = 0.10f * h;
    float bottom = top + 540.0f * s;
    if (p.y < top - 10.0f * s || p.y > bottom + 10.0f * s || abs(p.x - cx) > 460.0f * s) return;
    hudPanel(acc, p, float2(cx - 440.0f * s, top), float2(cx + 440.0f * s, bottom), 22.0f * s,
        float3(0.06f, 0.035f, 0.02f), 0.78f);
    hudCentered(acc, p, cx, top + 28.0f * s, 5.6f * s, textCupComplete, hudOrange());
    uint races = 3u - min(game.control.w, 2u);
    float best = 10.0f * float(races);
    float points = float(game.tally.x);
    int award = textBronze;
    float3 trophyColor = float3(0.80f, 0.50f, 0.26f);
    if (points >= 0.65f * best) {
        award = textSilver;
        trophyColor = float3(0.82f, 0.84f, 0.88f);
    }
    if (points >= 0.85f * best) {
        award = textGold;
        trophyColor = float3(1.0f, 0.78f, 0.22f);
    }
    float bob = 4.0f * sin(time * 2.0f);
    paintTrophy(acc, p, float2(cx, top + (230.0f + bob) * s), s, trophyColor);
    hudCentered(acc, p, cx, top + 340.0f * s, 4.6f * s, award, trophyColor);
    float c2 = 3.2f * s;
    float width = textWidth(textCupPoints, c2) + 6.0f * c2 + numberWidth(game.tally.x, c2);
    float x = cx - 0.5f * width;
    hudText(acc, p, float2(x, top + 400.0f * s), c2, textCupPoints, hudDim());
    hudNumber(acc, p, float2(x + textWidth(textCupPoints, c2) + 6.0f * c2, top + 400.0f * s), c2,
        game.tally.x, hudGold());
    if (game.timing.w > 1.0f) {
        float blink = 0.6f + 0.4f * sin(time * 4.0f);
        float4 before = acc;
        hudCentered(acc, p, cx, top + 470.0f * s, 3.4f * s, textPlayAgain, hudGold());
        acc = mix(before, acc, blink);
    }
}

fragment float4 hudFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 p = in.uv * resolution;
    float s = min(resolution.x / 1280.0f, resolution.y / 800.0f);
    float time = u.resolutionTime.z;
    float4 acc = float4(0.0f);
    uint phase = game.flow.x;
    if (phase == phaseTitle) {
        paintTitle(acc, p, resolution, s, time, game);
    } else if (phase == phaseResults) {
        paintResults(acc, p, resolution, s, time, game);
    } else if (phase == phaseChampion) {
        paintChampion(acc, p, resolution, s, time, game);
    } else {
        paintRaceHud(acc, p, resolution, s, game, u.pointer.xy);
        if (phase == phaseCountdown) paintCountdown(acc, p, resolution, s, game);
        paintNotice(acc, p, resolution, s, game);
    }
    if (acc.a <= 0.001f) return float4(0.0f);
    return float4(clamp(acc.rgb / acc.a, float3(0.0f), float3(1.0f)), clamp(acc.a, 0.0f, 1.0f));
}

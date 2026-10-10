#include <metal_stdlib>
using namespace metal;

// Tiltwood Labyrinth: a tilt-maze dexterity game for the generic GPU Program
// node, after the classic wooden labyrinth toy.
//
// The Trackpad pointer tilts the board: its offset from the centre sets the
// target tilt, so the marble rolls toward the pointer. A small dead zone at the
// centre levels the board, and full tilt is reached about a third of the way to
// each edge. The marble rolls under gravity with rolling friction and bounces
// off the walnut walls. Steer it past the holes into the brass goal ring.
// Pearls score a bonus, checkpoints move the respawn point, and Action/Space
// releases the held marble. While the marble rolls, Space hops it over a hole
// (a few hops per board). Clear five boards to master the labyrinth.
//
// All game state lives in one GPU buffer. Single-thread kernels advance it once
// per Loop call; the fragment pass only reads it. The fragment pass ray traces
// the tilted 3D board with a grid DDA in board space.
//
// Board space: x runs 0..32 from left to right, z runs 0..20 from the far
// (top) edge to the near (bottom) edge, y is up and the board top is y = 0.
// One cell is one unit. World space is the board space rotated by the tilt
// around the board centre (16, 0, 10), which sits at the world origin.
//
// Generated textures from the Asset Cache, sampled as sRGB albedo:
//   texture(1) asset0 maple board top, texture(2) asset1 walnut walls,
//   texture(3) asset2 felt tray, texture(4) asset3 swirled glass marble,
//   texture(5) asset4 study-room panorama (marble and pearl reflections).
//
// Parameters, in declared order: tiltSensitivity (1 normal, 0.25..2.5),
// startingMarbles (1..9, default 5), hopsPerBoard (0..5), firstBoard (1..5).

constant int boardWidth = 32;
constant int boardHeight = 20;
constant int cellCount = 640;
constant int boardCount = 5;

constant uint cellFloor = 0u;
constant uint cellWall = 1u;
constant uint cellHole = 2u;
constant uint cellGoal = 3u;
constant uint cellPearl = 4u;
constant uint cellCheck = 5u;
constant uint cellCheckOn = 6u;
constant uint cellStart = 7u;

constant uint phaseReady = 0u;    // marble held at the start or checkpoint
constant uint phasePlaying = 1u;
constant uint phaseFalling = 2u;  // marble drops through a hole
constant uint phaseSinking = 3u;  // marble rolls into the goal
constant uint phaseCleared = 4u;
constant uint phaseGameOver = 5u;
constant uint phaseVictory = 6u;

// Physics, in cells and seconds.
constant float ballRadius = 0.34f;
constant float holeRadius = 0.42f;     // drawn opening
constant float holeFall = 0.26f;       // the marble drops inside this reach
constant float holeRim = 0.46f;        // the rim starts pulling inside this reach
constant float holePull = 16.0f;
constant float goalRadius = 0.46f;
constant float goalFall = 0.30f;
constant float goalPullRadius = 0.9f;
constant float goalPull = 9.0f;
constant float maxTilt = 0.10f;        // radians at full pointer offset
constant float tiltRate = 2.0f;        // radians per second
constant float rollAccel = 85.0f;      // acceleration per unit sin(tilt)
constant float rollDamping = 0.45f;
constant float maxSpeed = 9.0f;
constant float restitution = 0.3f;
constant float hopSpeed = 3.0f;
constant float hopGravity = 14.0f;
constant float pointerDead = 0.015f;
constant float pointerFull = 0.32f;

// Geometry and camera.
constant float wallHeight = 0.62f;
constant float boardThickness = 0.55f;
constant float pearlRadius = 0.21f;
constant float trayDepth = -3.2f;
constant float cameraPitch = 1.11701f;  // 64 degrees below the horizon
constant float cameraDistance = 43.0f;
constant float cameraFocal = 1.86603f;  // 0.5 / tan(15 degrees): 30 degree field

constant float boardPars[5] = {60.0f, 45.0f, 50.0f, 70.0f, 110.0f};

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

// Buffer layout with Metal alignment (float4/uint4 = 16 bytes, align 16):
//   ball .. feedback     6 * 16 =   96 bytes at offset   0
//   flow .. notice       4 * 16 =   64 bytes at offset  96
//   cells[640]         640 *  4 = 2560 bytes at offset 160
//   sizeof(GameState)            = 2720 bytes (a multiple of 16).
// The workflow declares a 4096-byte "game" buffer, which covers it.
struct GameState {
    float4 ball;     // x, z on the board (cells), hop height, hop vertical speed
    float4 motion;   // velocity x, velocity z, seconds in this phase, seconds on this board
    float4 tilt;     // tilt x, tilt z (radians; positive lowers +x / +z), last action count, unused
    float4 spin;     // marble orientation quaternion (x, y, z, w), body to board space
    float4 respawn;  // respawn x, z; sink target x, z (hole or goal centre)
    float4 feedback; // notice seconds, unused, bump shake seconds, pearl sparkle seconds
    uint4 flow;      // phase, board index (0-based), marbles left, hops left
    uint4 score;     // score, best score, pearls collected on this board, pearls on this board
    uint4 tally;     // time bonus, hop bonus, flawless bonus, extra marble awarded (0 or 1)
    uint4 notice;    // notice text, falls on this board, ready reason (0 new board, 1 lost), goal cell index
    uint cells[640]; // the current board; pearls vanish and checkpoints light up
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
constant uchar textPool[429] = {
    66, 79, 65, 82, 68, 83, 67, 79, 82, 69, 66, 69, 83, 84, 84, 73,
    77, 69, 80, 65, 82, 77, 65, 82, 66, 76, 69, 83, 72, 79, 80, 83,
    80, 69, 65, 82, 76, 83, 47, 84, 73, 76, 84, 70, 73, 82, 83, 84,
    32, 82, 79, 76, 76, 72, 79, 76, 69, 32, 71, 65, 82, 68, 69, 78,
    84, 72, 69, 32, 77, 65, 90, 69, 84, 72, 69, 32, 78, 65, 82, 82,
    79, 87, 83, 84, 72, 69, 32, 71, 65, 85, 78, 84, 76, 69, 84, 68,
    82, 65, 71, 32, 84, 72, 69, 32, 84, 82, 65, 67, 75, 80, 65, 68,
    32, 84, 79, 32, 84, 73, 76, 84, 32, 84, 72, 69, 32, 66, 79, 65,
    82, 68, 83, 80, 65, 67, 69, 32, 84, 79, 32, 82, 69, 76, 69, 65,
    83, 69, 32, 84, 72, 69, 32, 77, 65, 82, 66, 76, 69, 87, 72, 73,
    76, 69, 32, 82, 79, 76, 76, 73, 78, 71, 44, 32, 83, 80, 65, 67,
    69, 32, 72, 79, 80, 83, 32, 79, 86, 69, 82, 32, 65, 32, 72, 79,
    76, 69, 67, 72, 69, 67, 75, 80, 79, 73, 78, 84, 80, 69, 65, 82,
    76, 32, 43, 49, 48, 48, 72, 79, 80, 33, 78, 79, 32, 72, 79, 80,
    83, 32, 76, 69, 70, 84, 77, 65, 82, 66, 76, 69, 32, 76, 79, 83,
    84, 77, 65, 82, 66, 76, 69, 83, 32, 76, 69, 70, 84, 77, 65, 82,
    66, 76, 69, 32, 76, 69, 70, 84, 66, 79, 65, 82, 68, 32, 67, 76,
    69, 65, 82, 69, 68, 67, 76, 69, 65, 82, 32, 66, 79, 78, 85, 83,
    84, 73, 77, 69, 32, 66, 79, 78, 85, 83, 72, 79, 80, 32, 66, 79,
    78, 85, 83, 70, 76, 65, 87, 76, 69, 83, 83, 43, 49, 32, 77, 65,
    82, 66, 76, 69, 83, 80, 65, 67, 69, 32, 70, 79, 82, 32, 84, 72,
    69, 32, 78, 69, 88, 84, 32, 66, 79, 65, 82, 68, 79, 85, 84, 32,
    79, 70, 32, 77, 65, 82, 66, 76, 69, 83, 83, 80, 65, 67, 69, 32,
    84, 79, 32, 84, 82, 89, 32, 65, 71, 65, 73, 78, 76, 65, 66, 89,
    82, 73, 78, 84, 72, 32, 77, 65, 83, 84, 69, 82, 69, 68, 70, 73,
    78, 65, 76, 32, 83, 67, 79, 82, 69, 83, 80, 65, 67, 69, 32, 84,
    79, 32, 80, 76, 65, 89, 32, 65, 71, 65, 73, 78, 43,
};
constant int textRanges[76] = {
    0, 5,  // BOARD
    5, 5,  // SCORE
    10, 4,  // BEST
    14, 4,  // TIME
    18, 3,  // PAR
    21, 7,  // MARBLES
    28, 4,  // HOPS
    32, 6,  // PEARLS
    38, 1,  // /
    39, 4,  // TILT
    43, 10,  // FIRST ROLL
    53, 11,  // HOLE GARDEN
    64, 8,  // THE MAZE
    72, 11,  // THE NARROWS
    83, 12,  // THE GAUNTLET
    95, 35,  // DRAG THE TRACKPAD TO TILT THE BOARD
    130, 27,  // SPACE TO RELEASE THE MARBLE
    157, 37,  // WHILE ROLLING, SPACE HOPS OVER A HOLE
    194, 10,  // CHECKPOINT
    204, 10,  // PEARL +100
    214, 4,  // HOP!
    218, 12,  // NO HOPS LEFT
    230, 11,  // MARBLE LOST
    241, 12,  // MARBLES LEFT
    253, 11,  // MARBLE LEFT
    264, 13,  // BOARD CLEARED
    277, 11,  // CLEAR BONUS
    288, 10,  // TIME BONUS
    298, 9,  // HOP BONUS
    307, 8,  // FLAWLESS
    315, 9,  // +1 MARBLE
    324, 24,  // SPACE FOR THE NEXT BOARD
    348, 14,  // OUT OF MARBLES
    362, 18,  // SPACE TO TRY AGAIN
    380, 18,  // LABYRINTH MASTERED
    398, 11,  // FINAL SCORE
    409, 19,  // SPACE TO PLAY AGAIN
    428, 1,  // +
};
constant int textBoard = 0;
constant int textScore = 1;
constant int textBest = 2;
constant int textTime = 3;
constant int textPar = 4;
constant int textMarbles = 5;
constant int textHops = 6;
constant int textPearls = 7;
constant int textSlash = 8;
constant int textTilt = 9;
constant int textFirstRoll = 10;
constant int textHoleGarden = 11;
constant int textTheMaze = 12;
constant int textTheNarrows = 13;
constant int textTheGauntlet = 14;
constant int textTiltHint = 15;
constant int textRelease = 16;
constant int textHopHint = 17;
constant int textCheckpoint = 18;
constant int textPearlBonus = 19;
constant int textHop = 20;
constant int textNoHops = 21;
constant int textMarbleLost = 22;
constant int textMarblesLeft = 23;
constant int textMarbleLeft = 24;
constant int textBoardCleared = 25;
constant int textClearBonus = 26;
constant int textTimeBonus = 27;
constant int textHopBonus = 28;
constant int textFlawless = 29;
constant int textExtraMarble = 30;
constant int textNextBoard = 31;
constant int textOutOfMarbles = 32;
constant int textTryAgain = 33;
constant int textMastered = 34;
constant int textFinalScore = 35;
constant int textPlayAgain = 36;
constant int textPlus = 37;

// Five boards of 32 x 20 cells, row 0 at the far (top) edge. Codes:
// 0 floor, 1 wall, 2 hole, 3 goal, 4 pearl, 5 checkpoint, 7 start.
constant uchar boardCells[3200] = {
    // Board 1: FIRST ROLL
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    1,7,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,0,0,0,0,1,  // #S.......#.........*...........#
    1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,1,  // #..............O..........O....#
    1,0,0,0,0,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,1,  // #...........*........#.........#
    1,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,1,0,0,0,0,0,2,0,0,0,1,  // #............O.......#.....O...#
    1,0,0,4,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,2,0,1,0,0,0,0,0,0,0,0,0,1,  // #..*.....#.........O.#.........#
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,1,1,1,  // #######################......###
    1,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,5,0,0,0,0,0,1,  // #.....#..........O.......C.....#
    1,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,1,  // #...........O.........#........#
    1,0,0,2,0,0,0,0,0,0,4,0,0,0,0,0,0,0,2,0,0,0,1,0,0,0,2,0,0,0,0,1,  // #..O......*.......O...#...O....#
    1,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,1,  // #.....#..............O.........#
    1,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,0,2,0,0,0,0,1,  // #........O.......*........O....#
    1,0,0,0,0,0,1,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,  // #.....#.....O..................#
    1,1,1,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ###......#######################
    1,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,1,  // #..........O........#..........#
    1,0,0,0,2,0,0,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,1,  // #...O.........*..........O.....#
    1,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,2,0,0,0,1,0,0,0,0,0,0,0,1,0,0,1,  // #.........#.....O...#.......#..#
    1,0,0,4,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,1,3,0,1,  // #..*......#.............O...#G.#
    1,0,0,0,0,0,2,0,0,0,1,0,0,0,0,0,0,2,0,0,4,0,0,0,0,0,0,0,1,0,0,1,  // #.....O...#......O..*.......#..#
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    // Board 2: HOLE GARDEN
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    1,7,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,  // #S.....#.......................#
    1,0,0,0,0,0,0,1,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #......#..O...O...O...O...O....#
    1,0,0,2,0,0,0,1,0,0,0,0,4,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,1,  // #..O...#....*...O...O...O...O..#
    1,0,0,0,0,0,0,1,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #......#..O...O...O...O...O....#
    1,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,4,0,0,0,2,0,0,1,  // #...........O...O...O...*...O..#
    1,0,0,0,0,0,0,1,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #......#..O...O...O...O...O....#
    1,0,4,0,0,0,0,1,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,1,  // #.*....#....O...O...O...O...O..#
    1,0,0,0,0,0,0,1,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #......#..O...O...O...O...O....#
    1,1,1,1,1,1,1,1,0,0,0,0,2,0,0,0,4,0,0,0,2,0,0,0,2,0,0,0,5,0,0,1,  // ########....O...*...O...O...C..#
    1,0,0,0,0,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #.........O...O...O...O...O....#
    1,0,0,5,0,0,0,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,1,  // #..C........O...O...O...O...O..#
    1,0,0,0,0,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #.........O...O...O...O...O....#
    1,0,0,0,0,2,0,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,4,0,0,0,2,0,0,1,  // #....O......O...O...O...*...O..#
    1,0,0,0,0,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #.........O...O...O...O...O....#
    1,0,0,2,0,0,0,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,1,  // #..O........O...O...O...O...O..#
    1,0,0,0,0,0,4,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #.....*...O...O...O...O...O....#
    1,0,2,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,3,0,1,  // #.O.....O...O...O...O...O...OG.#
    1,0,0,0,0,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,1,  // #.........O...O...O...O...O....#
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    // Board 3: THE MAZE
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    1,7,0,0,1,0,0,0,0,0,2,0,0,0,1,0,0,0,0,0,4,1,0,0,0,0,2,0,0,0,0,1,  // #S..#.....O...#.....*#....O....#
    1,0,0,0,1,0,0,0,0,0,0,0,0,0,0,2,0,1,0,0,0,1,0,0,0,0,0,0,0,0,0,1,  // #...#..........O.#...#.........#
    1,0,2,0,1,0,0,1,1,1,1,0,0,1,0,0,0,1,0,0,0,2,0,0,0,1,1,1,2,0,0,1,  // #.O.#..####..#...#...O...###O..#
    1,0,0,0,2,0,0,1,0,0,1,0,0,1,2,0,0,1,0,0,0,1,0,0,2,1,4,1,0,0,0,1,  // #...O..#..#..#O..#...#..O#*#...#
    1,0,0,0,1,0,0,1,4,0,1,0,0,1,0,0,0,1,1,1,1,0,1,1,1,0,0,1,0,2,0,1,  // #...#..#*.#..#...####.###..#.O.#
    1,0,0,1,1,2,0,1,0,0,2,0,0,1,0,0,0,0,0,0,0,0,5,0,1,0,0,1,0,0,0,1,  // #..##O.#..O..#........C.#..#...#
    1,0,0,0,0,0,0,0,1,0,0,0,0,1,1,1,1,1,2,1,1,1,1,0,1,0,0,1,0,0,0,1,  // #.......#....#####O####.#..#...#
    1,0,0,2,0,0,0,2,1,0,2,0,0,0,0,0,0,0,1,0,0,0,0,0,1,0,0,1,0,2,0,1,  // #..O...O#.O.......#.....#..#.O.#
    1,1,1,1,1,0,0,1,1,0,0,0,0,1,0,0,2,0,1,0,0,4,0,0,2,0,0,1,0,0,0,1,  // #####..##....#..O.#..*..O..#...#
    1,0,0,5,0,0,0,0,1,0,0,2,0,1,0,0,0,0,1,0,0,0,0,0,1,0,0,1,0,0,2,1,  // #..C....#..O.#....#.....#..#..O#
    1,0,1,1,1,0,2,0,1,1,1,1,0,1,0,2,0,0,1,1,1,1,2,1,1,0,0,1,1,0,0,1,  // #.###.O.####.#.O..####O##..##..#
    1,0,1,4,1,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,1,  // #.#*#........#...........O.....#
    1,0,1,0,1,0,0,2,0,0,2,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,2,0,0,2,0,1,  // #.#.#..O..O..##########...O..O.#
    1,0,1,0,1,1,0,0,0,0,0,0,0,1,0,0,0,0,0,2,0,0,1,0,0,1,1,1,1,0,0,1,  // #.#.##.......#.....O..#..####..#
    1,0,0,0,2,0,0,1,1,1,1,0,0,1,0,0,4,0,0,0,0,0,2,0,0,1,0,0,1,0,0,1,  // #...O..####..#..*.....O..#..#..#
    1,0,2,0,0,0,0,0,0,0,1,0,0,1,0,0,2,0,1,1,0,0,1,0,0,1,0,3,1,0,0,1,  // #.O.......#..#..O.##..#..#.G#..#
    1,0,0,0,1,1,1,1,0,0,2,0,0,1,0,0,0,0,0,0,0,0,1,0,0,0,0,0,2,0,0,1,  // #...####..O..#........#.....O..#
    1,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,2,0,0,2,0,0,0,0,0,0,0,0,1,  // #.......O..........O..O........#
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    // Board 4: THE NARROWS
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    1,7,0,0,0,2,0,0,0,2,0,0,0,2,0,0,1,0,0,4,0,0,0,0,0,0,0,0,0,2,0,1,  // #S...O...O...O..#..*.........O.#
    1,0,0,0,0,0,0,2,0,0,0,2,0,0,0,0,1,0,2,0,0,0,0,2,0,0,0,0,0,0,0,1,  // #......O...O....#.O....O.......#
    1,0,0,1,1,1,1,1,1,1,1,0,0,0,0,0,1,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1,  // #..########.....#....O....O....#
    1,0,0,1,0,0,0,0,0,4,1,0,0,2,0,0,1,0,0,1,1,1,1,1,1,1,0,0,2,0,0,1,  // #..#.....*#..O..#..#######..O..#
    1,0,0,1,0,0,0,0,0,0,1,0,0,0,0,0,1,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,  // #..#......#.....#..#.....#.....#
    1,2,0,1,0,0,2,0,0,0,1,0,0,5,0,0,2,0,0,1,0,4,0,0,0,1,0,0,2,0,0,1,  // #O.#..O...#..C..O..#.*...#..O..#
    1,0,0,1,0,0,0,0,0,0,1,0,0,0,0,0,1,0,0,1,0,0,2,0,0,1,0,0,0,0,0,1,  // #..#......#.....#..#..O..#.....#
    1,0,0,1,0,0,1,1,0,0,1,2,0,0,0,0,1,0,0,1,0,0,0,0,0,1,0,0,5,0,0,1,  // #..#..##..#O....#..#.....#..C..#
    1,0,0,1,0,0,1,1,0,0,1,0,0,0,0,0,1,0,0,1,1,0,1,1,0,1,0,0,0,0,0,1,  // #..#..##..#.....#..##.##.#.....#
    1,0,0,2,0,0,1,1,0,0,1,0,0,2,0,0,1,0,0,1,0,0,0,0,0,1,2,0,0,0,0,1,  // #..O..##..#..O..#..#.....#O....#
    1,0,0,1,0,0,1,1,0,0,1,0,0,0,0,0,1,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,  // #..#..##..#.....#..#.....#.....#
    1,0,0,1,0,0,1,0,0,0,1,0,2,0,0,0,1,0,0,2,0,0,2,0,0,1,0,0,2,0,0,1,  // #..#..#...#.O...#..O..O..#..O..#
    1,5,0,1,0,0,1,0,0,2,1,0,0,0,0,0,1,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,  // #C.#..#..O#.....#..#.....#.....#
    1,0,0,1,0,0,1,0,0,0,1,0,0,2,0,0,1,0,0,1,0,0,4,0,0,1,0,0,2,0,0,1,  // #..#..#...#..O..#..#..*..#..O..#
    1,0,0,1,0,0,1,0,0,0,1,0,0,0,0,0,1,0,0,1,0,0,0,0,0,1,0,0,0,0,0,1,  // #..#..#...#.....#..#.....#.....#
    1,0,0,2,0,0,1,0,2,0,2,0,0,4,0,0,2,0,0,1,0,2,0,0,1,1,0,0,2,0,0,1,  // #..O..#.O.O..*..O..#.O..##..O..#
    1,0,0,1,0,0,1,0,0,0,0,0,0,0,0,0,1,0,0,1,0,0,0,0,0,2,0,0,0,3,0,1,  // #..#..#.........#..#.....O...G.#
    1,0,0,0,0,0,1,0,0,2,0,0,0,0,2,0,0,0,0,1,0,0,2,0,0,0,0,0,0,0,0,1,  // #.....#..O....O....#..O........#
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    // Board 5: THE GAUNTLET
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
    1,7,0,0,2,0,0,0,0,2,0,0,0,0,0,0,0,0,2,0,0,0,0,4,2,0,0,0,0,0,0,1,  // #S..O....O........O....*O......#
    1,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,2,0,0,0,0,2,0,0,0,0,0,2,0,0,0,1,  // #.......*.......O....O.....O...#
    1,0,0,0,2,0,0,0,0,2,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,2,0,0,1,  // #...O....O........O.........O..#
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,1,  // ###########################....#
    1,0,0,0,0,0,2,0,0,0,2,0,0,0,0,0,2,0,0,0,0,2,0,0,0,0,5,0,0,0,0,1,  // #.....O...O.....O....O....C....#
    1,0,0,4,0,0,0,0,2,0,0,0,0,2,0,0,0,0,2,0,0,0,0,2,0,0,0,0,0,0,0,1,  // #..*....O....O....O....O.......#
    1,0,0,0,0,0,2,0,0,0,2,0,0,0,0,0,2,0,0,0,0,2,0,0,0,1,1,1,1,1,1,1,  // #.....O...O.....O....O...#######
    1,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // #....###########################
    1,0,5,0,0,1,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,0,1,  // #.C..#...O...O...O...O...O.....#
    1,0,0,0,0,1,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,0,0,0,1,  // #....#.....O...O...O...O.......#
    1,0,0,2,0,0,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,4,0,0,1,  // #..O.....O...O...O...O...O..*..#
    1,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,  // #....#..........*..............#
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,1,  // #############################..#
    1,0,0,2,0,0,0,2,0,0,0,2,0,0,0,1,0,0,0,0,0,5,0,0,0,0,0,0,0,0,0,1,  // #..O...O...O...#.....C.........#
    1,0,4,0,0,2,0,0,0,2,0,0,0,2,0,0,0,2,0,0,0,0,0,0,0,0,0,2,0,0,0,1,  // #.*..O...O...O...O.........O...#
    1,0,0,2,0,0,0,2,0,0,0,2,0,0,0,1,0,0,0,0,0,2,0,0,0,0,2,0,0,2,0,1,  // #..O...O...O...#.....O....O..O.#
    1,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,1,  // #....#######################...#
    1,3,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,2,0,0,0,0,0,2,0,0,0,0,0,1,  // #G...........O.....O.....O.....#
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  // ################################
};

// ---------------------------------------------------------------------------
// Settings and board access

float tiltSensitivity(constant ProgramUniforms &u) {
    return u.parameters0.x > 0.0f ? clamp(u.parameters0.x, 0.25f, 2.5f) : 1.0f;
}

uint startingMarbles(constant ProgramUniforms &u) {
    if (u.parameters0.y < 1.0f) return 5u;
    return uint(clamp(floor(u.parameters0.y + 0.5f), 1.0f, 9.0f));
}

uint hopsPerBoard(constant ProgramUniforms &u) {
    return uint(clamp(floor(u.parameters0.z + 0.5f), 0.0f, 5.0f));
}

uint firstBoard(constant ProgramUniforms &u) {
    if (u.parameters0.w < 1.0f) return 0u;
    return uint(clamp(floor(u.parameters0.w + 0.5f), 1.0f, float(boardCount))) - 1u;
}

float boardPar(uint board) {
    return boardPars[min(board, uint(boardCount - 1))];
}

float2 goalCenter(device const GameState &game) {
    uint index = min(game.notice.w, uint(cellCount - 1));
    return float2(float(index % uint(boardWidth)), float(index / uint(boardWidth))) + 0.5f;
}

uint cellAt(device const GameState &game, int2 at) {
    if (at.x < 0 || at.y < 0 || at.x >= boardWidth || at.y >= boardHeight) {
        return cellWall;
    }
    return game.cells[at.y * boardWidth + at.x];
}

// ---------------------------------------------------------------------------
// Tilt and marble orientation

float axisTilt(float pointer) {
    float offset = pointer - 0.5f;
    float amount = clamp((abs(offset) - pointerDead) / (pointerFull - pointerDead),
        0.0f, 1.0f);
    return offset < 0.0f ? -amount : amount;
}

float2 targetTilt(constant ProgramUniforms &u) {
    float2 pointer = clamp(u.pointer.xy, float2(0.0f), float2(1.0f));
    return float2(axisTilt(pointer.x), axisTilt(pointer.y))
        * (maxTilt * tiltSensitivity(u));
}

float4 quatMultiply(float4 a, float4 b) {
    return float4(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz),
        a.w * b.w - dot(a.xyz, b.xyz));
}

float3 rotateByQuat(float4 q, float3 v) {
    float3 t = 2.0f * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

// Rolling without slipping turns the marble about up x velocity.
float4 rollSpin(float4 spin, float2 velocity, float dt) {
    float3 omega = float3(velocity.y, 0.0f, -velocity.x) / ballRadius;
    float rate = length(omega);
    if (rate * dt < 0.00001f) return spin;
    float halfAngle = 0.5f * rate * dt;
    float4 turn = float4(omega / rate * sin(halfAngle), cos(halfAngle));
    return normalize(quatMultiply(turn, spin));
}

// Board space to world space: R = Rx(tilt z) * Rz(-tilt x).
float3 boardToWorld(float3 v, float2 tilt) {
    float c = cos(tilt.x);
    float s = sin(tilt.x);
    v = float3(v.x * c + v.y * s, -v.x * s + v.y * c, v.z);
    c = cos(tilt.y);
    s = sin(tilt.y);
    return float3(v.x, v.y * c - v.z * s, v.y * s + v.z * c);
}

// World space to board space: the transpose, Rz(tilt x) * Rx(-tilt z).
float3 worldToBoard(float3 v, float2 tilt) {
    float c = cos(tilt.y);
    float s = sin(tilt.y);
    v = float3(v.x, v.y * c + v.z * s, -v.y * s + v.z * c);
    c = cos(tilt.x);
    s = sin(tilt.x);
    return float3(v.x * c - v.y * s, v.x * s + v.y * c, v.z);
}

// ---------------------------------------------------------------------------
// Game flow

void showNotice(device GameState &game, int text) {
    game.notice.x = uint(text);
    game.feedback.x = 1.6f;
}

void loadBoard(device GameState &game, constant ProgramUniforms &u, uint board) {
    uint pearls = 0u;
    uint goal = 0u;
    float2 start = float2(1.5f, 1.5f);
    for (int index = 0; index < cellCount; ++index) {
        uint code = uint(boardCells[int(board) * cellCount + index]);
        if (code == cellPearl) pearls += 1u;
        if (code == cellGoal) goal = uint(index);
        if (code == cellStart) {
            start = float2(float(index % boardWidth), float(index / boardWidth)) + 0.5f;
        }
        game.cells[index] = code;
    }
    game.ball = float4(start, 0.0f, 0.0f);
    game.motion = float4(0.0f);
    game.spin = float4(0.0f, 0.0f, 0.0f, 1.0f);
    game.respawn = float4(start, start);
    game.feedback = float4(0.0f);
    game.flow.x = phaseReady;
    game.flow.y = board;
    game.flow.w = hopsPerBoard(u);
    game.score.z = 0u;
    game.score.w = pearls;
    game.tally = uint4(0u);
    game.notice = uint4(0u, 0u, 0u, goal);
}

void startGame(device GameState &game, constant ProgramUniforms &u) {
    game.score.x = 0u;
    game.flow.z = startingMarbles(u);
    loadBoard(game, u, firstBoard(u));
}

void loseMarble(device GameState &game) {
    game.notice.y += 1u;
    game.flow.z = game.flow.z > 0u ? game.flow.z - 1u : 0u;
    game.motion = float4(0.0f, 0.0f, 0.0f, game.motion.w);
    if (game.flow.z == 0u) {
        game.flow.x = phaseGameOver;
    } else {
        game.ball = float4(game.respawn.xy, 0.0f, 0.0f);
        game.flow.x = phaseReady;
        game.notice.z = 1u;
    }
    game.score.y = max(game.score.y, game.score.x);
}

void finishBoard(device GameState &game) {
    uint board = game.flow.y;
    uint timeBonus = 10u * uint(max(0.0f, boardPar(board) - game.motion.w));
    uint hopBonus = 150u * game.flow.w;
    uint flawless = game.notice.y == 0u ? 300u : 0u;
    uint extraMarble = game.flow.z < 9u ? 1u : 0u;
    game.score.x += 500u + timeBonus + hopBonus + flawless;
    game.score.y = max(game.score.y, game.score.x);
    game.tally = uint4(timeBonus, hopBonus, flawless, extraMarble);
    game.flow.z += extraMarble;
    game.flow.x = phaseCleared;
    if (board + 1u >= uint(boardCount)) game.flow.x = phaseVictory;
    game.motion = float4(0.0f, 0.0f, 0.0f, game.motion.w);
}

// ---------------------------------------------------------------------------
// Marble physics

// Pushes the marble out of every nearby wall cell. Returns the strongest
// impact speed into a wall.
float collideWalls(device const GameState &game, thread float2 &position,
    thread float2 &velocity) {
    float impact = 0.0f;
    int2 base = int2(floor(position));
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 at = base + int2(dx, dz);
            if (cellAt(game, at) != cellWall) continue;
            float2 lower = float2(at);
            float2 nearest = clamp(position, lower, lower + 1.0f);
            float2 offset = position - nearest;
            float reach = length(offset);
            if (reach >= ballRadius) continue;
            float2 normal;
            if (reach > 0.00001f) {
                normal = offset / reach;
            } else {
                float2 fromCenter = position - (lower + 0.5f);
                if (abs(fromCenter.x) > abs(fromCenter.y)) {
                    normal = float2(fromCenter.x >= 0.0f ? 1.0f : -1.0f, 0.0f);
                } else {
                    normal = float2(0.0f, fromCenter.y >= 0.0f ? 1.0f : -1.0f);
                }
            }
            position = nearest + normal * ballRadius;
            float along = dot(velocity, normal);
            if (along < 0.0f) {
                velocity -= (1.0f + restitution) * along * normal;
                impact = max(impact, -along);
            }
        }
    }
    return impact;
}

void playStep(device GameState &game, float dt, bool pressed) {
    game.motion.w += dt;
    float2 position = game.ball.xy;
    float2 velocity = game.motion.xy;
    float height = game.ball.z;
    float lift = game.ball.w;
    bool grounded = height <= 0.0f;
    if (pressed && grounded) {
        if (game.flow.w > 0u) {
            game.flow.w -= 1u;
            lift = hopSpeed;
            height = 0.0001f;
            grounded = false;
            showNotice(game, textHop);
        } else {
            showNotice(game, textNoHops);
        }
    }

    float2 accel = rollAccel * sin(game.tilt.xy);
    int2 base = int2(floor(position));
    uint hazard = 0u; // 1 = hole, 2 = goal
    float2 sinkAt = position;
    if (grounded) {
        for (int dz = -1; dz <= 1; ++dz) {
            for (int dx = -1; dx <= 1; ++dx) {
                int2 at = base + int2(dx, dz);
                uint code = cellAt(game, at);
                if (code != cellHole && code != cellGoal) continue;
                float2 center = float2(at) + 0.5f;
                float2 offset = center - position;
                float reach = length(offset);
                if (code == cellHole) {
                    if (reach < holeRim) {
                        accel += offset * (holePull * (1.0f - reach / holeRim)
                            / max(reach, 0.001f));
                    }
                    if (reach < holeFall && hazard == 0u) {
                        hazard = 1u;
                        sinkAt = center;
                    }
                } else {
                    if (reach < goalPullRadius) {
                        accel += offset * (goalPull * (1.0f - reach / goalPullRadius)
                            / max(reach, 0.001f));
                    }
                    if (reach < goalFall) {
                        hazard = 2u;
                        sinkAt = center;
                    }
                }
            }
        }
    }
    if (hazard != 0u) {
        game.respawn.zw = sinkAt;
        game.flow.x = phaseFalling;
        if (hazard == 2u) game.flow.x = phaseSinking;
        game.motion.xy = velocity;
        game.motion.z = 0.0f;
        game.ball.zw = float2(0.0f);
        return;
    }

    velocity += accel * dt;
    velocity *= exp(-rollDamping * dt);
    float speed = length(velocity);
    if (speed > maxSpeed) velocity *= maxSpeed / speed;
    float impact = 0.0f;
    for (int part = 0; part < 4; ++part) {
        position += velocity * (0.25f * dt);
        impact = max(impact, collideWalls(game, position, velocity));
    }
    if (impact > 2.5f) {
        game.feedback.z = 0.05f + 0.12f * min(impact / 6.0f, 1.0f);
    }
    if (!grounded) {
        height += lift * dt;
        lift -= hopGravity * dt;
        if (height <= 0.0f) {
            height = 0.0f;
            lift = 0.0f;
        }
    }
    game.spin = rollSpin(game.spin, velocity, dt);
    game.ball = float4(position, height, lift);
    game.motion.xy = velocity;

    base = int2(floor(position));
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 at = base + int2(dx, dz);
            if (at.x < 0 || at.y < 0 || at.x >= boardWidth || at.y >= boardHeight) {
                continue;
            }
            int index = at.y * boardWidth + at.x;
            uint code = game.cells[index];
            float reach = distance(float2(at) + 0.5f, position);
            if (code == cellPearl && reach < 0.55f && height < 0.5f) {
                game.cells[index] = cellFloor;
                game.score.x += 100u;
                game.score.z += 1u;
                game.feedback.w = 0.5f;
                showNotice(game, textPearlBonus);
            } else if ((code == cellCheck || code == cellCheckOn) && reach < 0.6f) {
                if (code == cellCheck) {
                    game.cells[index] = cellCheckOn;
                    showNotice(game, textCheckpoint);
                }
                game.respawn.xy = float2(at) + 0.5f;
            }
        }
    }
    game.score.y = max(game.score.y, game.score.x);
}

kernel void initializeLabyrinth(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    game.score = uint4(0u);
    // The run's current action count is the baseline, not a press.
    game.tilt = float4(targetTilt(u), u.pointer.z, 0.0f);
    startGame(game, u);
}

kernel void advanceLabyrinth(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    // Live preview supplies elapsed wall time in pointer.w. Saved frames keep
    // the fixed program step, so they remain reproducible.
    float dt = min(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w, 0.1f);
    // A larger count than last frame is one Action/Space press.
    bool pressed = u.pointer.z > game.tilt.z;
    game.tilt.z = u.pointer.z;
    float2 tilt = game.tilt.xy;
    tilt += clamp(targetTilt(u) - tilt, float2(-tiltRate * dt), float2(tiltRate * dt));
    game.tilt.xy = tilt;
    game.motion.z += dt;
    game.feedback.x = max(0.0f, game.feedback.x - dt);
    game.feedback.z = max(0.0f, game.feedback.z - dt);
    game.feedback.w = max(0.0f, game.feedback.w - dt);

    uint phase = game.flow.x;
    if (phase == phaseReady) {
        if (pressed && game.motion.z > 0.3f) {
            game.flow.x = phasePlaying;
            game.motion.z = 0.0f;
        }
    } else if (phase == phasePlaying) {
        playStep(game, dt, pressed);
    } else if (phase == phaseFalling || phase == phaseSinking) {
        float seconds = game.motion.z;
        float2 position = game.ball.xy;
        position += (game.respawn.zw - position) * min(1.0f, dt * 10.0f);
        game.ball.xy = position;
        game.ball.z = -3.0f * seconds * seconds - 0.4f * seconds;
        game.spin = rollSpin(game.spin,
            game.motion.xy * max(0.0f, 1.0f - seconds * 3.0f), dt);
        if (phase == phaseFalling && seconds >= 0.75f) {
            loseMarble(game);
        } else if (phase == phaseSinking && seconds >= 0.9f) {
            finishBoard(game);
        }
    } else if (phase == phaseCleared) {
        if (pressed && game.motion.z > 0.6f) loadBoard(game, u, game.flow.y + 1u);
    } else if (pressed && game.motion.z > 0.8f) {
        // Out of marbles or labyrinth mastered: Space starts a new game.
        startGame(game, u);
    }
}

// ---------------------------------------------------------------------------
// Presentation: camera and board ray tracing

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenVertex labyrinthVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1u) & 2u, vertexID & 2u);
    ScreenVertex out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

void cameraRay(float2 pixel, float2 resolution, thread float3 &origin,
    thread float3 &direction) {
    float3 target = float3(0.0f, 0.0f, 0.5f);
    float3 eye = target + cameraDistance
        * float3(0.0f, sin(cameraPitch), cos(cameraPitch));
    float3 forward = normalize(target - eye);
    float3 right = normalize(cross(forward, float3(0.0f, 1.0f, 0.0f)));
    float3 up = cross(right, forward);
    // Narrower frames zoom out so the whole board stays visible.
    float zoom = max(1.0f, 1.6f * resolution.y / resolution.x);
    float2 screen = (pixel - 0.5f * resolution) / resolution.y * zoom;
    origin = eye;
    direction = normalize(forward * cameraFocal + right * screen.x - up * screen.y);
}

constant int hitNone = 0;
constant int hitFloor = 1;
constant int hitWallTop = 2;
constant int hitWallSide = 3;
constant int hitBoardEdge = 4;
constant int hitHoleShaft = 5;
constant int hitGoalShaft = 6;
constant int hitPearl = 7;

struct BoardHit {
    float t;
    float3 normal;
    int kind;
    int2 cell;
};

// Distance along the ray to a sphere, or a large value when it misses.
float sphereHit(float3 origin, float3 direction, float3 center, float radius) {
    float3 offset = origin - center;
    float along = dot(offset, direction);
    float discriminant = along * along - dot(offset, offset) + radius * radius;
    if (discriminant < 0.0f) return 1.0e9f;
    float root = sqrt(discriminant);
    float t = -along - root;
    if (t <= 0.0f) t = -along + root;
    return t > 0.0f ? t : 1.0e9f;
}

// Walks the cells under the ray (Amanatides-Woo) in board space.
BoardHit traceBoard(device const GameState &game, float3 o, float3 d) {
    BoardHit hit;
    hit.t = 1.0e9f;
    hit.normal = float3(0.0f, 1.0f, 0.0f);
    hit.kind = hitNone;
    hit.cell = int2(0);
    float3 safe = select(d, float3(0.000001f), abs(d) < float3(0.000001f));
    float3 lower = float3(0.0f, -boardThickness, 0.0f);
    float3 upper = float3(float(boardWidth), wallHeight, float(boardHeight));
    float3 first = (lower - o) / safe;
    float3 second = (upper - o) / safe;
    float3 entry = min(first, second);
    float3 exit = max(first, second);
    float tEnter = max(entry.x, max(entry.y, entry.z));
    float tExit = min(exit.x, min(exit.y, exit.z));
    if (tExit < max(tEnter, 0.0f) || tEnter < 0.0f) return hit;
    int2 stepDir = int2(safe.x > 0.0f ? 1 : -1, safe.z > 0.0f ? 1 : -1);
    // 0: entered through an x face, 1: through the top, 2: through a z face.
    int lastAxis = entry.x > entry.y && entry.x > entry.z ? 0
        : (entry.y > entry.z ? 1 : 2);
    float3 start = o + d * tEnter;
    if (start.y < -0.0001f) {
        hit.t = tEnter;
        hit.kind = hitBoardEdge;
        hit.normal = lastAxis == 0 ? float3(-float(stepDir.x), 0.0f, 0.0f)
            : float3(0.0f, 0.0f, -float(stepDir.y));
        return hit;
    }
    int2 cell = clamp(int2(floor(start.xz)), int2(0),
        int2(boardWidth - 1, boardHeight - 1));
    float2 boundary = float2(cell) + float2(stepDir.x > 0 ? 1.0f : 0.0f,
        stepDir.y > 0 ? 1.0f : 0.0f);
    float2 tMax = (boundary - o.xz) / safe.xz;
    float2 tDelta = abs(1.0f / safe.xz);
    float tCell = tEnter;
    for (int iteration = 0; iteration < 64; ++iteration) {
        float tNext = min(min(tMax.x, tMax.y), tExit);
        uint code = cellAt(game, cell);
        if (code == cellWall) {
            float yIn = o.y + d.y * tCell;
            if (yIn <= wallHeight + 0.0001f && lastAxis != 1) {
                hit.t = tCell;
                hit.kind = hitWallSide;
                hit.normal = lastAxis == 0 ? float3(-float(stepDir.x), 0.0f, 0.0f)
                    : float3(0.0f, 0.0f, -float(stepDir.y));
                hit.cell = cell;
                return hit;
            }
            float tTop = (wallHeight - o.y) / safe.y;
            if (tTop <= tNext) {
                hit.t = max(tTop, tCell);
                hit.kind = hitWallTop;
                hit.normal = float3(0.0f, 1.0f, 0.0f);
                hit.cell = cell;
                return hit;
            }
        } else {
            float2 center = float2(cell) + 0.5f;
            if (code == cellPearl) {
                float3 pearlCenter = float3(center.x, pearlRadius, center.y);
                float tPearl = sphereHit(o, d, pearlCenter, pearlRadius);
                if (tPearl < 1.0e8f) {
                    hit.t = tPearl;
                    hit.kind = hitPearl;
                    hit.normal = normalize(o + d * tPearl - pearlCenter);
                    hit.cell = cell;
                    return hit;
                }
            }
            float tFloor = -o.y / safe.y;
            if (tFloor <= tNext) {
                float tHit = max(tFloor, tCell);
                float3 point = o + d * tHit;
                hit.cell = cell;
                if (code == cellHole || code == cellGoal) {
                    float radius = goalRadius;
                    if (code == cellHole) radius = holeRadius;
                    float2 rel = point.xz - center;
                    if (dot(rel, rel) < radius * radius) {
                        // Through the opening: find the shaft wall below it.
                        float a = max(dot(d.xz, d.xz), 0.00000001f);
                        float b = dot(rel, d.xz);
                        float c = dot(rel, rel) - radius * radius;
                        float s = (-b + sqrt(max(b * b - a * c, 0.0f))) / a;
                        float2 wall = rel + d.xz * s;
                        hit.t = tHit + s;
                        hit.kind = hitGoalShaft;
                        if (code == cellHole) hit.kind = hitHoleShaft;
                        hit.normal = float3(-wall.x, 0.0f, -wall.y) / radius;
                        return hit;
                    }
                }
                hit.t = tHit;
                hit.kind = hitFloor;
                hit.normal = float3(0.0f, 1.0f, 0.0f);
                return hit;
            }
        }
        if (tMax.x < tMax.y) {
            tCell = tMax.x;
            tMax.x += tDelta.x;
            cell.x += stepDir.x;
            lastAxis = 0;
        } else {
            tCell = tMax.y;
            tMax.y += tDelta.y;
            cell.y += stepDir.y;
            lastAxis = 2;
        }
        if (tCell > tExit || cell.x < 0 || cell.y < 0
            || cell.x >= boardWidth || cell.y >= boardHeight) break;
    }
    return hit;
}

// ---------------------------------------------------------------------------
// Materials

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

// Mirrored equirectangular lookup: continuous in every direction.
float3 roomAlbedo(texture2d<float> image, float3 direction) {
    constexpr sampler roomSampler(coord::normalized,
        address::clamp_to_edge, filter::linear);
    float u = abs(atan2(direction.x, -direction.z)) * 0.31830989f;
    float v = acos(clamp(direction.y, -1.0f, 1.0f)) * 0.31830989f;
    return decodeSRGB(image.sample(roomSampler, float2(u, v)));
}

float lumaOf(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// Light falls on a floor point unless a wall stands between it and the lamp.
float wallShadow(device const GameState &game, float2 point, float3 light) {
    float2 slope = light.xz / max(light.y, 0.2f);
    float lit = 1.0f;
    for (int tap = 0; tap < 4; ++tap) {
        float rise = wallHeight * (float(tap) + 0.5f) * 0.25f;
        if (cellAt(game, int2(floor(point + slope * rise))) == cellWall) lit -= 0.2f;
    }
    return lit;
}

float wallOcclusion(device const GameState &game, float2 point) {
    int2 base = int2(floor(point));
    float closest = 2.0f;
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 at = base + int2(dx, dz);
            if (cellAt(game, at) != cellWall) continue;
            float2 lower = float2(at);
            closest = min(closest,
                distance(point, clamp(point, lower, lower + 1.0f)));
        }
    }
    return 1.0f - 0.45f * exp(-closest * 7.0f);
}

float marbleShadow(device const GameState &game, float2 point, float3 light) {
    float lift = ballRadius + game.ball.z;
    if (lift <= 0.0f) return 1.0f;
    float2 center = game.ball.xy - light.xz / max(light.y, 0.2f) * lift;
    float soft = 1.0f - smoothstep(ballRadius * 0.55f,
        ballRadius * 1.15f + 0.1f * game.ball.z, distance(point, center));
    float contact = 1.0f - smoothstep(0.0f, ballRadius * 0.9f,
        distance(point, game.ball.xy));
    float grounded = game.ball.z < 0.05f ? 1.0f : 0.0f;
    return 1.0f - 0.55f * soft - 0.25f * contact * grounded;
}

float ringMask(float reach, float radius, float width) {
    return 1.0f - smoothstep(width * 0.5f, width * 0.5f + 0.025f,
        abs(reach - radius));
}

float3 shadeFloor(float3 p, int2 cell, device const GameState &game,
    float3 light, texture2d<float> boardTop, float time) {
    float3 albedo = textureAlbedo(boardTop, p.xz * 0.085f)
        * float3(1.0f, 0.95f, 0.88f);
    uint code = cellAt(game, cell);
    float2 center = float2(cell) + 0.5f;
    float reach = distance(p.xz, center);
    float3 glow = float3(0.0f);
    if (code == cellHole) {
        albedo = mix(albedo, float3(0.025f, 0.02f, 0.016f),
            ringMask(reach, holeRadius + 0.03f, 0.06f));
    } else if (code == cellStart) {
        albedo = mix(albedo, float3(0.80f, 0.78f, 0.72f),
            0.8f * ringMask(reach, 0.36f, 0.05f));
    } else if (code == cellCheck || code == cellCheckOn) {
        bool lit = code == cellCheckOn;
        float3 paint = lit ? float3(0.20f, 0.75f, 0.30f) : float3(0.25f, 0.35f, 0.55f);
        float2 local = abs(p.xz - center);
        float diamond = 1.0f - smoothstep(0.15f, 0.18f, local.x + local.y);
        albedo = mix(albedo, paint, ringMask(reach, 0.38f, 0.06f));
        albedo = mix(albedo, paint, diamond);
        if (lit) glow += float3(0.10f, 0.45f, 0.16f) * diamond;
    }
    // The goal's painted target spans its neighbours, so it is drawn by
    // distance to the goal centre rather than by cell.
    float goalReach = distance(p.xz, goalCenter(game));
    if (goalReach < 1.4f) {
        float3 brass = float3(0.95f, 0.66f, 0.24f);
        albedo = mix(albedo, float3(0.62f, 0.07f, 0.05f),
            ringMask(goalReach, goalRadius + 0.42f, 0.14f));
        albedo = mix(albedo, float3(0.92f, 0.88f, 0.80f),
            ringMask(goalReach, goalRadius + 0.24f, 0.12f));
        albedo = mix(albedo, brass, ringMask(goalReach, goalRadius + 0.05f, 0.10f));
        float pulse = 0.6f + 0.4f * sin(time * 3.0f);
        glow += brass * 0.30f * pulse * exp(-goalReach * goalReach * 1.4f);
    }
    float shade = wallShadow(game, p.xz, light) * wallOcclusion(game, p.xz)
        * marbleShadow(game, p.xz, light);
    float diffuse = max(light.y, 0.0f);
    return albedo * (0.30f + 0.85f * diffuse * shade) * mix(0.75f, 1.0f, shade)
        + glow;
}

float3 shadeWood(float3 p, float3 n, float3 light, texture2d<float> wallWood) {
    float2 uv;
    if (n.y > 0.5f) {
        uv = p.xz * 0.23f;
    } else if (abs(n.x) > 0.5f) {
        uv = float2(p.z * 0.23f, p.y * 0.6f);
    } else {
        uv = float2(p.x * 0.23f, p.y * 0.6f);
    }
    float3 albedo = textureAlbedo(wallWood, uv + float2(0.37f, 0.11f))
        * float3(0.95f, 0.85f, 0.75f);
    float diffuse = max(dot(n, light), 0.0f);
    float3 color = albedo * (0.30f + 0.85f * diffuse);
    if (n.y < 0.5f) color *= mix(0.55f, 1.0f, smoothstep(-0.2f, 0.35f, p.y));
    return color;
}

float3 shadeShaft(float3 p, float3 n, float3 light, bool goal,
    texture2d<float> boardTop, float time, bool cleared) {
    float depth = -p.y;
    if (depth > boardThickness) {
        return goal ? float3(0.35f, 0.20f, 0.05f) * (cleared ? 1.5f : 0.4f)
            : float3(0.004f, 0.003f, 0.003f);
    }
    float around = atan2(n.z, n.x);
    float3 grain = textureAlbedo(boardTop, float2(around * 0.2f, p.y * 0.5f))
        * float3(0.5f, 0.42f, 0.34f);
    float3 color = grain * (0.25f + 0.6f * max(dot(n, light), 0.0f))
        * exp(-depth * 4.0f);
    if (goal) {
        float pulse = 0.6f + 0.4f * sin(time * 3.0f);
        color += float3(0.9f, 0.55f, 0.15f) * (cleared ? 0.8f : 0.25f * pulse)
            * exp(-(boardThickness - depth) * 3.0f);
    }
    return color;
}

float3 shadePearl(float3 n, float3 d, float3 light, float2 tilt,
    texture2d<float> room) {
    float diffuse = max(dot(n, light), 0.0f);
    float3 sheen = float3(0.93f, 0.90f, 0.86f) + 0.08f * float3(
        sin(n.x * 6.0f + 1.0f), sin(n.y * 5.0f + 2.0f), sin(n.z * 7.0f + 3.0f));
    float3 color = sheen * (0.30f + 0.75f * diffuse);
    float facing = max(dot(-d, n), 0.0f);
    float fresnel = 0.04f + 0.96f * pow(1.0f - facing, 5.0f);
    float3 reflected = roomAlbedo(room, boardToWorld(reflect(d, n), tilt));
    color = mix(color, reflected * 1.2f, 0.25f + 0.6f * fresnel);
    float3 halfway = normalize(light - d);
    color += float3(1.6f) * pow(max(dot(n, halfway), 0.0f), 60.0f);
    return color;
}

float3 shadeMarble(float3 p, float3 center, float3 d, float3 light,
    device const GameState &game, float2 tilt, texture2d<float> marble,
    texture2d<float> room) {
    float3 n = normalize(p - center);
    float4 q = game.spin;
    float3 body = rotateByQuat(float4(-q.xyz, q.w), n);
    float around = atan2(body.z, body.x) * 0.15915494f + 0.5f;
    // Mirrored around the sphere so the texture has no seam.
    float2 uv = float2(abs(around * 2.0f - 1.0f),
        acos(clamp(body.y, -1.0f, 1.0f)) * 0.31830989f);
    float3 swirl = textureAlbedo(marble, uv);
    // Lift the swirl's colour so a dark generated image still reads as glass.
    swirl = mix(swirl, swirl / max(lumaOf(swirl), 0.05f) * 0.35f, 0.5f);
    float diffuse = max(dot(n, light), 0.0f);
    float facing = max(dot(-d, n), 0.0f);
    float fresnel = 0.05f + 0.95f * pow(1.0f - facing, 5.0f);
    float3 reflected = roomAlbedo(room, boardToWorld(reflect(d, n), tilt));
    float3 color = swirl * (0.18f + 0.85f * diffuse);
    color = mix(color, reflected * 1.3f, clamp(fresnel + 0.15f, 0.0f, 1.0f));
    float3 halfway = normalize(light - d);
    float highlight = max(dot(n, halfway), 0.0f);
    color += float3(2.2f, 2.0f, 1.8f) * pow(highlight, 90.0f)
        + float3(0.10f, 0.09f, 0.07f) * pow(highlight, 8.0f);
    color += float3(0.9f, 0.85f, 0.6f) * game.feedback.w * pow(1.0f - facing, 2.0f);
    // A marble dropping below the board fades into the shaft.
    if (p.y < 0.0f) color *= exp(p.y * 3.0f);
    return color;
}

float3 shadeTray(float3 eye, float3 dir, float2 tilt, float3 lightWorld,
    texture2d<float> felt) {
    if (dir.y > -0.001f) return float3(0.01f);
    float t = (trayDepth - eye.y) / dir.y;
    float3 p = eye + dir * t;
    float3 albedo = textureAlbedo(felt, p.xz * 0.05f) * float3(0.55f, 0.72f, 0.60f);
    // The board's shadow: follow the light back up to the board plane.
    float3 local = worldToBoard(p, tilt) + float3(16.0f, 0.0f, 10.0f);
    float3 light = worldToBoard(lightWorld, tilt);
    float2 across = local.xz + light.xz / max(light.y, 0.2f) * (-local.y);
    float2 outside = max(max(-across, across - float2(32.0f, 20.0f)), float2(0.0f));
    float shadow = 1.0f - 0.75f * (1.0f - smoothstep(0.0f, 1.6f, length(outside)));
    float falloff = exp(-0.0015f * dot(p.xz, p.xz));
    return albedo * (0.25f + 0.65f * lightWorld.y) * shadow * falloff;
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

void paintCentered(thread float3 &color, float2 pixel, float centerX, float y,
    float cell, int text, float3 ink, float alpha) {
    paintText(color, pixel, float2(centerX - 0.5f * textWidth(text, cell), y),
        cell, text, ink, alpha);
}

// A label on the left and a number on the right of a centred column.
void paintRow(thread float3 &color, float2 pixel, float centerX, float halfWidth,
    float y, float cell, int label, uint value, float3 labelInk, float3 valueInk) {
    paintText(color, pixel, float2(centerX - halfWidth, y), cell, label,
        labelInk, 1.0f);
    paintNumber(color, pixel, float2(centerX + halfWidth
        - numberWidth(value, cell), y), cell, value, valueInk, 1.0f);
}

float sdRoundBox(float2 point, float2 halfSize, float radius) {
    float2 q = abs(point) - halfSize + radius;
    return length(max(q, float2(0.0f))) + min(max(q.x, q.y), 0.0f) - radius;
}

float panelMask(float2 pixel, float2 lower, float2 upper, float radius) {
    float2 extent = 0.5f * max(upper - lower, float2(0.0f));
    float corner = min(radius, min(extent.x, extent.y));
    float signedDistance = sdRoundBox(pixel - 0.5f * (lower + upper),
        extent, corner);
    return clamp(0.5f - signedDistance, 0.0f, 1.0f);
}

float discMask(float2 pixel, float2 center, float radius) {
    return clamp(radius - length(pixel - center) + 0.5f, 0.0f, 1.0f);
}

float sdSegment(float2 point, float2 a, float2 b) {
    float2 pa = point - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.000001f), 0.0f, 1.0f);
    return length(pa - ba * h);
}

// Small marble icons for the remaining marbles.
void paintMarbleIcons(thread float3 &color, float2 pixel, float2 origin,
    float size, uint count) {
    for (uint index = 0u; index < 9u; ++index) {
        if (index >= count) break;
        float2 center = origin + float2((float(index) + 0.5f) * size * 1.2f,
            0.5f * size);
        float2 offset = (pixel - center) / (0.5f * size);
        float shade = clamp(1.0f - 0.55f * length(offset - float2(-0.35f, -0.35f)),
            0.0f, 1.0f);
        float3 glass = mix(float3(0.08f, 0.16f, 0.42f),
            float3(0.75f, 0.85f, 1.0f), shade * shade);
        color = mix(color, glass, discMask(pixel, center, 0.5f * size));
    }
}

// Upward chevrons for the remaining hops.
void paintHopIcons(thread float3 &color, float2 pixel, float2 origin,
    float size, uint count, float3 ink) {
    for (uint index = 0u; index < 5u; ++index) {
        if (index >= count) break;
        float2 center = origin + float2((float(index) + 0.5f) * size * 1.2f,
            0.5f * size);
        float2 left = center + float2(-0.38f, 0.2f) * size;
        float2 apex = center + float2(0.0f, -0.2f) * size;
        float2 right = center + float2(0.38f, 0.2f) * size;
        float stroke = min(sdSegment(pixel, left, apex),
            sdSegment(pixel, apex, right)) - 0.1f * size;
        color = mix(color, ink, clamp(0.5f - stroke, 0.0f, 1.0f));
    }
}

int boardTitle(uint board) {
    return textFirstRoll + int(min(board, uint(boardCount - 1)));
}

// All panels stay above the board's far edge so the start cell is visible.
void paintHud(thread float3 &color, float2 pixel, float2 resolution,
    device const GameState &game, constant ProgramUniforms &u, float time) {
    float ui = min(resolution.x / 1280.0f, resolution.y / 800.0f);
    float3 ink = float3(0.97f, 0.94f, 0.86f);
    float3 gold = float3(1.0f, 0.80f, 0.30f);
    float3 muted = float3(0.70f, 0.70f, 0.72f);
    float3 alarm = float3(1.0f, 0.45f, 0.35f);
    float3 calm = float3(0.5f, 1.0f, 0.6f);
    float3 panel = float3(0.03f, 0.025f, 0.02f);
    uint phase = game.flow.x;
    uint board = game.flow.y;
    float centerX = 0.5f * resolution.x;
    float blink = 0.7f + 0.3f * sin(time * 4.0f);
    float cell = 2.4f * ui;
    float firstRow = 22.0f * ui;
    float secondRow = 48.0f * ui;

    // Left: board number, score and best score.
    color = mix(color, panel, 0.62f * panelMask(pixel, float2(14.0f, 12.0f) * ui,
        float2(350.0f, 76.0f) * ui, 10.0f * ui));
    float leftX = 28.0f * ui;
    float valueX = leftX + 36.0f * cell;
    paintText(color, pixel, float2(leftX, firstRow), cell, textBoard, muted, 1.0f);
    paintNumber(color, pixel, float2(valueX, firstRow), cell, board + 1u, ink, 1.0f);
    float slashX = valueX + numberWidth(board + 1u, cell) + cell;
    paintText(color, pixel, float2(slashX, firstRow), cell, textSlash, muted, 1.0f);
    paintNumber(color, pixel, float2(slashX + 6.0f * cell, firstRow), cell,
        uint(boardCount), ink, 1.0f);
    paintText(color, pixel, float2(leftX, secondRow), cell, textScore, muted, 1.0f);
    paintNumber(color, pixel, float2(valueX, secondRow), cell, game.score.x,
        gold, 1.0f);
    float bestX = valueX + 38.0f * cell;
    paintText(color, pixel, float2(bestX, secondRow), cell, textBest, muted, 1.0f);
    paintNumber(color, pixel, float2(bestX + 28.0f * cell, secondRow), cell,
        max(game.score.y, game.score.x), ink, 1.0f);

    // Centre: board name, then time, par and pearls.
    color = mix(color, panel, 0.62f * panelMask(pixel,
        float2(centerX - 230.0f * ui, 12.0f * ui),
        float2(centerX + 230.0f * ui, 76.0f * ui), 10.0f * ui));
    paintCentered(color, pixel, centerX, 18.0f * ui, 2.8f * ui, boardTitle(board),
        gold, 1.0f);
    uint seconds = uint(game.motion.w);
    uint par = uint(boardPar(board));
    float infoCell = 2.2f * ui;
    float gap = 12.0f * infoCell;
    float timeLabel = textWidth(textTime, infoCell) + 6.0f * infoCell;
    float parLabel = textWidth(textPar, infoCell) + 6.0f * infoCell;
    float pearlLabel = textWidth(textPearls, infoCell) + 6.0f * infoCell;
    float pearlSlash = numberWidth(game.score.z, infoCell) + infoCell;
    float total = timeLabel + numberWidth(seconds, infoCell) + gap
        + parLabel + numberWidth(par, infoCell) + gap
        + pearlLabel + pearlSlash + 6.0f * infoCell
        + numberWidth(game.score.w, infoCell);
    float2 info = float2(centerX - 0.5f * total, secondRow + 2.0f * ui);
    paintText(color, pixel, info, infoCell, textTime, muted, 1.0f);
    info.x += timeLabel;
    paintNumber(color, pixel, info, infoCell, seconds,
        seconds > par ? alarm : ink, 1.0f);
    info.x += numberWidth(seconds, infoCell) + gap;
    paintText(color, pixel, info, infoCell, textPar, muted, 1.0f);
    info.x += parLabel;
    paintNumber(color, pixel, info, infoCell, par, ink, 1.0f);
    info.x += numberWidth(par, infoCell) + gap;
    paintText(color, pixel, info, infoCell, textPearls, muted, 1.0f);
    info.x += pearlLabel;
    paintNumber(color, pixel, info, infoCell, game.score.z, gold, 1.0f);
    info.x += pearlSlash;
    paintText(color, pixel, info, infoCell, textSlash, muted, 1.0f);
    info.x += 6.0f * infoCell;
    paintNumber(color, pixel, info, infoCell, game.score.w, ink, 1.0f);

    // Right: marbles and hops left.
    float rightX = resolution.x - 300.0f * ui;
    color = mix(color, panel, 0.62f * panelMask(pixel, float2(rightX - 14.0f * ui,
        12.0f * ui), float2(resolution.x - 14.0f * ui, 76.0f * ui), 10.0f * ui));
    float iconX = rightX + 46.0f * cell;
    paintText(color, pixel, float2(rightX, firstRow), cell, textMarbles, muted, 1.0f);
    paintMarbleIcons(color, pixel, float2(iconX, firstRow - 1.0f * ui),
        14.0f * ui, game.flow.z);
    paintText(color, pixel, float2(rightX, secondRow), cell, textHops, muted, 1.0f);
    paintHopIcons(color, pixel, float2(iconX, secondRow - 1.0f * ui),
        16.0f * ui, game.flow.w, gold);

    // Spirit level: the dot leans toward the downhill side.
    float gaugeRadius = 30.0f * ui;
    float2 gaugeCenter = resolution - float2(48.0f, 48.0f) * ui;
    color = mix(color, panel, 0.62f * discMask(pixel, gaugeCenter, gaugeRadius));
    float ring = abs(length(pixel - gaugeCenter) - gaugeRadius) - 1.2f * ui;
    color = mix(color, muted, clamp(0.5f - ring, 0.0f, 1.0f));
    float2 across = abs(pixel - gaugeCenter);
    float crossLines = min(max(across.x - 0.6f * ui, across.y - gaugeRadius),
        max(across.y - 0.6f * ui, across.x - gaugeRadius));
    color = mix(color, muted * 0.6f, clamp(0.5f - crossLines, 0.0f, 1.0f));
    float2 lean = game.tilt.xy / (maxTilt * tiltSensitivity(u));
    float2 dotCenter = gaugeCenter + clamp(lean, float2(-1.0f), float2(1.0f))
        * gaugeRadius * 0.72f;
    color = mix(color, gold, discMask(pixel, dotCenter, 5.0f * ui));
    float tiltCell = 2.0f * ui;
    paintText(color, pixel, float2(gaugeCenter.x - gaugeRadius - 10.0f * ui
        - textWidth(textTilt, tiltCell), gaugeCenter.y - 3.5f * tiltCell),
        tiltCell, textTilt, muted, 1.0f);

    // Trackpad pointer while the board answers to it, and the level centre.
    if (phase == phaseReady || phase == phasePlaying) {
        float2 aim = clamp(u.pointer.xy, float2(0.0f), float2(1.0f)) * resolution;
        float pointerRing = abs(length(pixel - aim) - 9.0f * ui) - 1.1f * ui;
        float pointerDot = length(pixel - aim) - 1.8f * ui;
        float mark = min(pointerRing, pointerDot);
        color = mix(color, float3(0.0f), 0.45f
            * clamp(0.5f - (mark - 1.5f * ui), 0.0f, 1.0f));
        color = mix(color, float3(1.0f, 0.95f, 0.8f),
            0.85f * clamp(0.5f - mark, 0.0f, 1.0f));
        float level = abs(length(pixel - 0.5f * resolution) - 4.0f * ui) - 0.8f * ui;
        color = mix(color, float3(1.0f), 0.35f * clamp(0.5f - level, 0.0f, 1.0f));
    }

    // Short notices during play, below the board.
    if (game.feedback.x > 0.0f && phase == phasePlaying) {
        int notice = int(game.notice.x);
        float3 noticeInk = gold;
        if (notice == textNoHops) noticeInk = alarm;
        if (notice == textCheckpoint) noticeInk = calm;
        paintCentered(color, pixel, centerX, resolution.y - 52.0f * ui, 3.0f * ui,
            notice, noticeInk, clamp(game.feedback.x / 0.4f, 0.0f, 1.0f));
    }

    if (phase == phasePlaying || phase == phaseFalling || phase == phaseSinking) {
        return;
    }
    float phaseSeconds = game.motion.z;
    if (phase == phaseReady) {
        float2 lower = float2(centerX - 330.0f * ui,
            0.5f * resolution.y - 100.0f * ui);
        float2 upper = float2(centerX + 330.0f * ui,
            0.5f * resolution.y + 110.0f * ui);
        color = mix(color, panel, 0.72f * panelMask(pixel, lower, upper, 16.0f * ui));
        float top = lower.y + 22.0f * ui;
        if (game.notice.z == 1u) {
            paintCentered(color, pixel, centerX, top, 6.0f * ui, textMarbleLost,
                alarm, 1.0f);
            int left = textMarblesLeft;
            if (game.flow.z == 1u) left = textMarbleLeft;
            float leftCell = 3.0f * ui;
            float countWidth = numberWidth(game.flow.z, leftCell) + 6.0f * leftCell;
            float leftWidth = countWidth + textWidth(left, leftCell);
            float2 origin = float2(centerX - 0.5f * leftWidth, top + 66.0f * ui);
            paintNumber(color, pixel, origin, leftCell, game.flow.z, gold, 1.0f);
            paintText(color, pixel, origin + float2(countWidth, 0.0f), leftCell,
                left, ink, 1.0f);
        } else {
            float boardCell = 2.6f * ui;
            float boardLabel = textWidth(textBoard, boardCell) + 6.0f * boardCell;
            float labelWidth = boardLabel + numberWidth(board + 1u, boardCell);
            float2 origin = float2(centerX - 0.5f * labelWidth, top);
            paintText(color, pixel, origin, boardCell, textBoard, muted, 1.0f);
            paintNumber(color, pixel, origin + float2(boardLabel, 0.0f), boardCell,
                board + 1u, ink, 1.0f);
            paintCentered(color, pixel, centerX, top + 30.0f * ui, 6.0f * ui,
                boardTitle(board), gold, 1.0f);
            paintCentered(color, pixel, centerX, top + 96.0f * ui, 2.4f * ui,
                textTiltHint, ink, 1.0f);
            if (game.flow.w > 0u) {
                paintCentered(color, pixel, centerX, top + 122.0f * ui, 2.4f * ui,
                    textHopHint, muted, 1.0f);
            }
        }
        float releaseAlpha = phaseSeconds > 0.3f ? blink : 0.0f;
        paintCentered(color, pixel, centerX, upper.y - 40.0f * ui, 3.0f * ui,
            textRelease, gold, releaseAlpha);
        return;
    }

    // Board cleared, out of marbles, or labyrinth mastered.
    color *= 0.55f;
    bool summary = phase == phaseCleared;
    float2 lower = float2(centerX - 300.0f * ui,
        0.5f * resolution.y - (summary ? 170.0f : 125.0f) * ui);
    float2 upper = float2(centerX + 300.0f * ui,
        0.5f * resolution.y + (summary ? 180.0f : 125.0f) * ui);
    color = mix(color, panel, 0.75f * panelMask(pixel, lower, upper, 18.0f * ui));
    float row = lower.y + 28.0f * ui;
    float rowCell = 3.0f * ui;
    float halfWidth = 210.0f * ui;
    float rowGap = 32.0f * ui;
    if (phase == phaseCleared) {
        paintCentered(color, pixel, centerX, row, 6.0f * ui, textBoardCleared,
            gold, 1.0f);
        row += 74.0f * ui;
        paintRow(color, pixel, centerX, halfWidth, row, rowCell, textClearBonus,
            500u, muted, ink);
        row += rowGap;
        paintRow(color, pixel, centerX, halfWidth, row, rowCell, textTimeBonus,
            game.tally.x, muted, ink);
        row += rowGap;
        paintRow(color, pixel, centerX, halfWidth, row, rowCell, textHopBonus,
            game.tally.y, muted, ink);
        row += rowGap;
        if (game.tally.z > 0u) {
            paintRow(color, pixel, centerX, halfWidth, row, rowCell, textFlawless,
                game.tally.z, calm, ink);
            row += rowGap;
        }
        if (game.tally.w > 0u) {
            paintText(color, pixel, float2(centerX - halfWidth, row), rowCell,
                textExtraMarble, float3(0.6f, 0.8f, 1.0f), 1.0f);
            row += rowGap;
        }
        paintRow(color, pixel, centerX, halfWidth, row + 6.0f * ui, rowCell,
            textScore, game.score.x, ink, gold);
        float nextAlpha = phaseSeconds > 0.6f ? blink : 0.0f;
        paintCentered(color, pixel, centerX, upper.y - 44.0f * ui, 3.0f * ui,
            textNextBoard, ink, nextAlpha);
        return;
    }
    bool won = phase == phaseVictory;
    int title = textOutOfMarbles;
    int prompt = textTryAgain;
    float3 titleInk = alarm;
    float titleCell = 6.0f * ui;
    if (won) {
        title = textMastered;
        prompt = textPlayAgain;
        titleInk = gold;
        titleCell = 5.4f * ui;
    }
    paintCentered(color, pixel, centerX, row + 8.0f * ui, titleCell, title,
        titleInk, 1.0f);
    row += 82.0f * ui;
    paintRow(color, pixel, centerX, halfWidth, row, 3.6f * ui, textFinalScore,
        game.score.x, muted, gold);
    row += 46.0f * ui;
    paintRow(color, pixel, centerX, halfWidth, row, 3.0f * ui, textBest,
        max(game.score.y, game.score.x), muted, ink);
    float againAlpha = phaseSeconds > 0.8f ? blink : 0.0f;
    paintCentered(color, pixel, centerX, upper.y - 44.0f * ui, 3.0f * ui,
        prompt, ink, againAlpha);
}

// Linear scene colour to display sRGB with a soft shoulder above 0.8.
float3 toDisplay(float3 linearColor) {
    float3 value = max(linearColor, float3(0.0f));
    float3 rolled = 0.8f + 0.2f * (1.0f - exp(-(value - 0.8f) / 0.2f));
    float3 mapped = select(value, rolled, value > 0.8f);
    return select(1.055f * pow(mapped, float3(1.0f / 2.4f)) - 0.055f,
        12.92f * mapped, mapped <= 0.0031308f);
}

fragment float4 labyrinthFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> boardTopTexture [[texture(1)]],
    texture2d<float> wallWoodTexture [[texture(2)]],
    texture2d<float> trayFeltTexture [[texture(3)]],
    texture2d<float> marbleTexture [[texture(4)]],
    texture2d<float> roomTexture [[texture(5)]]) {
    device const GameState &game = states[0];
    float2 resolution = u.resolutionTime.xy;
    float2 pixel = in.uv * resolution;
    float time = u.resolutionTime.z;
    float ui = min(resolution.x / 1280.0f, resolution.y / 800.0f);
    float2 shake = game.feedback.z * 40.0f * ui
        * float2(sin(time * 91.0f), cos(time * 77.0f));

    float3 eye;
    float3 dir;
    cameraRay(pixel + shake, resolution, eye, dir);
    float2 tilt = game.tilt.xy;
    float3 lightWorld = normalize(float3(-0.42f, 0.82f, 0.38f));
    float3 light = worldToBoard(lightWorld, tilt);
    float3 origin = worldToBoard(eye, tilt) + float3(16.0f, 0.0f, 10.0f);
    float3 ray = worldToBoard(dir, tilt);

    BoardHit hit = traceBoard(game, origin, ray);
    float3 marbleCenter = float3(game.ball.x, ballRadius + game.ball.z, game.ball.y);
    float tMarble = sphereHit(origin, ray, marbleCenter, ballRadius);
    bool cleared = game.flow.x == phaseCleared || game.flow.x == phaseVictory;

    float3 color;
    if (tMarble < hit.t && tMarble < 1.0e8f) {
        color = shadeMarble(origin + ray * tMarble, marbleCenter, ray, light, game,
            tilt, marbleTexture, roomTexture);
    } else if (hit.kind == hitNone) {
        color = shadeTray(eye, dir, tilt, lightWorld, trayFeltTexture);
    } else {
        float3 p = origin + ray * hit.t;
        if (hit.kind == hitFloor) {
            color = shadeFloor(p, hit.cell, game, light, boardTopTexture, time);
        } else if (hit.kind == hitWallTop || hit.kind == hitWallSide) {
            color = shadeWood(p, hit.normal, light, wallWoodTexture);
            if (hit.kind == hitWallTop) {
                color *= marbleShadow(game, p.xz, light) * 0.15f + 0.85f;
            }
        } else if (hit.kind == hitBoardEdge) {
            color = shadeWood(p, hit.normal, light, wallWoodTexture) * 0.7f;
        } else if (hit.kind == hitPearl) {
            color = shadePearl(hit.normal, ray, light, tilt, roomTexture);
        } else {
            color = shadeShaft(p, hit.normal, light, hit.kind == hitGoalShaft,
                boardTopTexture, time, cleared);
        }
    }

    float vignette = 1.0f - 0.28f * smoothstep(0.35f, 0.85f, length(in.uv - 0.5f));
    float3 display = toDisplay(color * vignette);
    paintHud(display, pixel, resolution, game, u, time);
    return float4(clamp(display, float3(0.0f), float3(1.0f)), 1.0f);
}

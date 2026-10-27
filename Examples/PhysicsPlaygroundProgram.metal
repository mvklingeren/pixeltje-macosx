// pixeltje:3d-v1
// pixeltje:physics-v1
#include <metal_stdlib>
using namespace metal;

// A first-person physics playground for structural collapse. Static parts
// are boxes divided into a grid of up to 8 x 8 cells; a shot removes one.
// A support pass then asks which cells still reach the ground and turns
// every cell that does not into a falling rigid chunk. The chunks, loose
// shards, crates and dominoes share one sequential-impulse solver with
// four-point contact manifolds. Painted toy cubes and balls, and a ball
// hanging on a rope from a steel frame, never break: a shot only pushes
// them. The haunted house uses the same support rules and solver for its
// buildings. F switches to a third-person camera behind a skinned character
// loaded from an FBX file. Space jumps, and C launches the heavy box.
struct ProgramUniforms {
    float4 resolutionTime;
    uint4 frameSeed;
    float4 parameters0;
    float4 parameters1;
    float4 parameters2;
    float4 parameters3;
    float4 pointer;
    float4 movement;
};

constant uint partCapacity = 48u;
constant uint linkCapacity = 8u;
constant uint bodyCapacity = 72u;
constant uint contactCapacity = 448u;
constant uint cannonSlot = 0u;
constant uint propFirst = 1u;          // crates and dominoes, 1..10, then
constant uint propCount = 17u;         // toy cubes and balls, 11..17
constant uint pendulumSlot = propFirst + propCount - 1u;
constant uint chunkFirst = propFirst + propCount;
constant uint chunkCount = 16u;
constant uint shardFirst = chunkFirst + chunkCount;
constant uint shardCount = bodyCapacity - shardFirst;
constant float cellPitch = 1.0f;
constant float linkTolerance = 0.03f;
constant float contactSlop = 0.02f;
constant float3 gravity = float3(0.0f, -9.8f, 0.0f);
constant uint solverIterations = 12u;

constant uint styleBrick = 1u;
constant uint styleStone = 2u;
constant uint styleWood = 3u;
constant uint styleRoof = 4u;
constant uint styleCrate = 5u;
constant uint styleCannon = 6u;
constant uint styleSteel = 7u;         // never breaks
constant uint styleToy = 8u;
constant uint styleRope = 9u;
constant uint styleBall = 10u;

constant uint fKey = 262144u;         // WASD Pad bit for F
constant uint cKey = 8u;              // WASD Pad bit for C
constant float playerEyeHeight = 1.7f;
constant float playerHeight = 1.8f;
constant float playerRadius = 0.35f;
constant float playerStep = 0.45f;    // highest ledge walked onto unjumped
// Yaku's 1.99 m walking cycle is sampled into a 31-frame loop at 30 fps.
constant float walkingSpeed = 1.93f;

constant ulong firstColumn = 0x0101010101010101ul;
constant ulong lastColumn = 0x8080808080808080ul;

struct Part {
    float4 lower;   // world corner, style
    float4 upper;   // world corner, 1 when the part bears its own load
};

// Support that reaches part p from part `from`: when any of `theirs` (cells
// of from) is supported, the cells `mine` (of p) are seeded. A bearing
// link means p rests on from; a hanging link means p is held at its side
// by from, which only parts that do not bear their own load receive.
struct SupportLink {
    ulong mine;
    ulong theirs;
    uint from;
    uint bearing;
    uint2 unused;
};

// What a body looks like: a box in the rest frame of the scene, so a
// chunk keeps the coordinates of the part it broke from. cells lists the
// source part's cells it carries; props and shards carry every cell.
struct Piece {
    float4 lower;   // rest corner, style
    float4 upper;   // rest corner, source part + 1 (0 for none)
    ulong cells;
    uint kind;      // 0 prop, 1 chunk, 2 shard, 3 cannonball, 4 ball
    uint tint;      // paint of a toy
};

// A box or ball that darkens the ambient light around it, gathered each
// frame from the alive cells of the parts and from the bodies.
struct Occluder {
    float4 centre;      // world centre, radius of a ball (0 for a box)
    float4 extent;      // box half extent
    float4 orientation; // local-to-world unit quaternion
};

struct GameState {
    float4 player;      // eye position, yaw
    float4 view;        // pitch, last action count, muzzle flash, last
                        // secondary action count
    float4 clock;       // elapsed seconds, previous keys, shots, collapses
    uint4 counts;       // parts, support dirty, next shard, contacts
    uint4 control;      // restart requested, next chunk, unused, unused
    float4 push;        // direction of the latest break, its time
    Part parts[partCapacity];
    ulong gone[partCapacity];
    ulong grounded[partCapacity];
    ulong supported[partCapacity];
    uint linkCount[partCapacity];
    SupportLink links[partCapacity][linkCapacity];
    Piece pieces[bodyCapacity];
    pixeltje_physics::World<bodyCapacity> world;
    pixeltje_physics::SolverContact contacts[contactCapacity];
    float4 rope;        // anchor of the pendulum's rope, its length
    float4 camera;      // camera position, 1 in third person
    float4 stride;      // character facing yaw, walk seconds, camera too close,
                        // vertical jump speed
    // Light read once from the environment HDR by lightFromEnvironment.
    float4 sunLight;    // direction toward its sun, exposure
    float4 sunColor;    // the sun's irradiance at normal incidence, the
                        // brightest sky radiance left
    float4 skyFill[9];  // band-2 spherical harmonics of the irradiance of
                        // everything but the sun, over pi
    uint4 occluderCount;
    Occluder occluders[partCapacity + bodyCapacity];
};

static_assert(sizeof(GameState) <= 131072,
    "The game buffer must hold the playground state");

float hash11(float n) {
    return fract(sin(n * 12.9898f + 4.1414f) * 43758.5453f);
}

// ------------------------------------------------------------------ cells

// The two broadest directions carry the cells; roofs use their plan.
uint2 cellAxes(float3 lower, float3 upper, uint style) {
    if (style == styleRoof) return uint2(0u, 2u);
    float3 span = upper - lower;
    if (span.x <= span.y && span.x <= span.z) return uint2(1u, 2u);
    if (span.y <= span.z) return uint2(0u, 2u);
    return uint2(0u, 1u);
}

uint2 cellGrid(float3 lower, float3 upper, uint2 axes) {
    float3 span = upper - lower;
    return uint2(clamp(ceil(float2(span[axes.x], span[axes.y]) / cellPitch),
        float2(1.0f), float2(8.0f)));
}

ulong gridMask(uint2 grid) {
    ulong row = (grid.x >= 8u ? 0xfful : ((1ul << grid.x) - 1ul));
    ulong mask = 0ul;
    for (uint y = 0u; y < grid.y; ++y) mask |= row << (y * 8u);
    return mask;
}

ulong partAlive(device const GameState &game, uint index) {
    Part part = game.parts[index];
    uint2 axes = cellAxes(part.lower.xyz, part.upper.xyz, uint(part.lower.w));
    return gridMask(cellGrid(part.lower.xyz, part.upper.xyz, axes))
        & ~game.gone[index];
}

// The cells of a part that touch a box.
ulong cellsInBox(Part part, float3 lower, float3 upper) {
    float3 lo = max(lower, part.lower.xyz);
    float3 hi = min(upper, part.upper.xyz);
    if (any(hi < lo)) return 0ul;
    uint2 axes = cellAxes(part.lower.xyz, part.upper.xyz, uint(part.lower.w));
    uint2 grid = cellGrid(part.lower.xyz, part.upper.xyz, axes);
    float3 span = part.upper.xyz - part.lower.xyz;
    float2 size = float2(span[axes.x], span[axes.y]) / float2(grid);
    float2 origin = float2(part.lower[axes.x], part.lower[axes.y]);
    int2 first = int2(floor((float2(lo[axes.x], lo[axes.y]) - origin)
        / size));
    int2 last = int2(ceil((float2(hi[axes.x], hi[axes.y]) - origin)
        / size)) - 1;
    first = clamp(first, int2(0), int2(grid) - 1);
    last = clamp(max(last, first), int2(0), int2(grid) - 1);
    ulong mask = 0ul;
    for (int y = first.y; y <= last.y; ++y)
        for (int x = first.x; x <= last.x; ++x)
            mask |= 1ul << uint(y * 8 + x);
    return mask;
}

void cellBox(Part part, uint bit, thread float3 &lower, thread float3 &upper) {
    uint2 axes = cellAxes(part.lower.xyz, part.upper.xyz, uint(part.lower.w));
    uint2 grid = cellGrid(part.lower.xyz, part.upper.xyz, axes);
    float3 span = part.upper.xyz - part.lower.xyz;
    float2 size = float2(span[axes.x], span[axes.y]) / float2(grid);
    lower = part.lower.xyz;
    upper = part.upper.xyz;
    lower[axes.x] += float(bit & 7u) * size.x;
    lower[axes.y] += float(bit >> 3u) * size.y;
    upper[axes.x] = lower[axes.x] + size.x;
    upper[axes.y] = lower[axes.y] + size.y;
}

uint cellAt(Part part, float3 p) {
    uint2 axes = cellAxes(part.lower.xyz, part.upper.xyz, uint(part.lower.w));
    uint2 grid = cellGrid(part.lower.xyz, part.upper.xyz, axes);
    float3 span = max(part.upper.xyz - part.lower.xyz, float3(0.001f));
    float2 uv = (float2(p[axes.x], p[axes.y])
        - float2(part.lower[axes.x], part.lower[axes.y]))
        / float2(span[axes.x], span[axes.y]);
    uint2 cell = uint2(clamp(floor(uv * float2(grid)), float2(0.0f),
        float2(grid - 1u)));
    return cell.y * 8u + cell.x;
}

// Grows seeds through 4-connected alive cells: a part's own cells hold
// together like a mortared wall.
ulong floodCells(ulong alive, ulong seeds) {
    ulong mask = seeds & alive;
    for (uint i = 0u; i < 64u; ++i) {
        ulong grown = (mask | (mask << 8u) | (mask >> 8u)
            | ((mask & ~lastColumn) << 1u) | ((mask & ~firstColumn) >> 1u))
            & alive;
        if (grown == mask) break;
        mask = grown;
    }
    return mask;
}

// ------------------------------------------------------------------ scene

void addPart(device GameState &game, float3 lower, float3 upper,
    uint style) {
    uint index = game.counts.x;
    if (index >= partCapacity) return;
    game.parts[index] = {float4(lower, float(style)), float4(upper, 0.0f)};
    game.gone[index] = 0ul;
    game.counts.x = index + 1u;
}

void addProp(device GameState &game, uint slot, float3 lower, float3 upper,
    float mass) {
    float3 centre = 0.5f * (lower + upper);
    game.pieces[slot] = {float4(lower, float(styleCrate)),
        float4(upper, 0.0f), ~0ul, 0u, 0u};
    pixeltje_physics::RigidBody body = pixeltje_physics::makeRigidBody(
        centre, 0.5f * (upper - lower), float4(0.0f, 0.0f, 0.0f, 1.0f),
        float3(0.0f), 1.0f / mass, 0.15f, 0.6f);
    body.extentState.w = 2.0f; // placed at rest, asleep until disturbed
    game.world.bodies[slot] = body;
    game.world.sleepSeconds[slot] = 0.0f;
}

// A painted cube or ball that never breaks. A ball's box is its bounds;
// its inertia is the box's, which matches a hollow ball.
void addToy(device GameState &game, uint slot, float3 centre, float3 extent,
    bool ball, uint tint, float mass) {
    game.pieces[slot] = {float4(centre - extent,
        float(ball ? styleBall : styleToy)),
        float4(centre + extent, 0.0f), ~0ul, ball ? 4u : 0u, tint};
    pixeltje_physics::RigidBody body = pixeltje_physics::makeRigidBody(
        centre, extent, float4(0.0f, 0.0f, 0.0f, 1.0f), float3(0.0f),
        1.0f / mass, ball ? 0.35f : 0.15f, 0.6f);
    body.extentState.w = 2.0f;
    game.world.bodies[slot] = body;
    game.world.sleepSeconds[slot] = 0.0f;
}

__attribute__((noinline))
void buildPlayground(device GameState &game) {
    game.player = float4(-1.0f, playerEyeHeight, 15.0f, -0.12f);
    game.stride.w = 0.0f;
    game.view = float4(0.04f, game.view.y, 0.0f, game.view.w);
    game.clock = float4(0.0f, game.clock.y, 0.0f, 0.0f);
    game.counts = uint4(0u, 0u, 0u, 0u);
    game.control = uint4(0u, 0u, 0u, 0u);
    game.push = float4(0.0f, 0.0f, 0.0f, -100.0f);
    for (uint i = 0u; i < bodyCapacity; ++i) {
        game.world.bodies[i].extentState.w = 0.0f;
        game.world.sleepSeconds[i] = 0.0f;
    }

    // A cottage with a flat roof and a brick chimney on its west gable:
    // the chimney stands on its own footing, beside the wall.
    addPart(game, float3(-11.0f, 0.0f, 1.75f), float3(-5.0f, 3.2f, 2.0f),
        styleWood);
    addPart(game, float3(-11.0f, 0.0f, -4.0f), float3(-5.0f, 3.2f, -3.75f),
        styleWood);
    addPart(game, float3(-11.0f, 0.0f, -3.75f), float3(-10.75f, 3.2f, 1.75f),
        styleWood);
    addPart(game, float3(-5.25f, 0.0f, -3.75f), float3(-5.0f, 3.2f, 1.75f),
        styleWood);
    addPart(game, float3(-11.0f, 3.2f, -4.3f), float3(-4.7f, 3.5f, 2.3f),
        styleRoof);
    addPart(game, float3(-12.2f, 0.0f, -1.6f), float3(-11.0f, 4.5f, -0.4f),
        styleBrick);
    addPart(game, float3(-12.0f, 4.5f, -1.4f), float3(-11.2f, 6.5f, -0.6f),
        styleBrick);
    addPart(game, float3(-12.3f, 6.5f, -1.7f), float3(-10.9f, 6.75f, -0.3f),
        styleStone);

    // A stone tower of four drums under a broad capstone.
    for (uint tier = 0u; tier < 4u; ++tier)
        addPart(game, float3(-0.8f, 2.2f * float(tier), -8.8f),
            float3(0.8f, 2.2f * float(tier + 1u), -7.2f), styleStone);
    addPart(game, float3(-1.4f, 8.8f, -9.4f), float3(1.4f, 9.2f, -6.6f),
        styleStone);

    // A free-standing brick garden wall.
    addPart(game, float3(4.0f, 0.0f, -3.0f), float3(12.0f, 3.0f, -2.6f),
        styleBrick);

    // Post and lintel: the lintel only rests on the two posts.
    addPart(game, float3(6.0f, 0.0f, -10.0f), float3(7.0f, 4.0f, -9.0f),
        styleStone);
    addPart(game, float3(10.0f, 0.0f, -10.0f), float3(11.0f, 4.0f, -9.0f),
        styleStone);
    addPart(game, float3(5.8f, 4.0f, -10.1f), float3(11.2f, 4.8f, -8.9f),
        styleStone);

    // A crate pyramid and a row of dominoes, at rest and asleep.
    const float c = 0.45f;
    uint slot = propFirst;
    for (uint row = 0u; row < 3u; ++row)
        for (uint k = 0u; k < 3u - row; ++k) {
            float x = -6.0f + (float(k) + 0.5f * float(row)) * 2.0f * c;
            float y = 2.0f * c * float(row);
            addProp(game, slot++, float3(x - c, y, 5.0f - c),
                float3(x + c, y + 2.0f * c, 5.0f + c), 1.0f);
        }
    for (uint k = 0u; k < 4u; ++k) {
        float x = 4.0f + 1.0f * float(k);
        addProp(game, slot++, float3(x - 0.1f, 0.0f, 4.6f),
            float3(x + 0.1f, 1.6f, 5.4f), 0.5f);
    }

    // Toy cubes, one stacked on another, and three balls, to the right of
    // the path from the start to the crates.
    addToy(game, slot++, float3(0.6f, 0.5f, 10.5f), float3(0.5f), false,
        0u, 2.0f);
    addToy(game, slot++, float3(0.7f, 1.35f, 10.5f), float3(0.35f), false,
        1u, 1.0f);
    addToy(game, slot++, float3(2.2f, 0.3f, 11.5f), float3(0.3f), false,
        2u, 0.8f);
    addToy(game, slot++, float3(1.6f, 0.5f, 12.6f), float3(0.5f), true,
        3u, 1.5f);
    addToy(game, slot++, float3(2.8f, 0.35f, 12.8f), float3(0.35f), true,
        1u, 0.6f);
    addToy(game, slot++, float3(-0.2f, 0.25f, 11.6f), float3(0.25f), true,
        2u, 0.3f);

    // A steel frame with a ball hanging on a rope from its crossbeam.
    addPart(game, float3(3.3f, 0.0f, 7.4f), float3(3.5f, 4.4f, 7.6f),
        styleSteel);
    addPart(game, float3(7.3f, 0.0f, 7.4f), float3(7.5f, 4.4f, 7.6f),
        styleSteel);
    addPart(game, float3(3.2f, 4.4f, 7.35f), float3(7.6f, 4.65f, 7.65f),
        styleSteel);
    game.rope = float4(5.4f, 4.4f, 7.5f, 2.6f);
    addToy(game, slot++, float3(5.4f, 4.4f - 2.6f - 0.4f, 7.5f), float3(0.4f),
        true, 0u, 2.0f);
}

bool restsOn(Part upper, Part lower) {
    return abs(upper.lower.y - lower.upper.y) <= linkTolerance
        && min(upper.upper.x, lower.upper.x)
            > max(upper.lower.x, lower.lower.x) + 0.01f
        && min(upper.upper.z, lower.upper.z)
            > max(upper.lower.z, lower.lower.z) + 0.01f;
}

bool partsTouch(Part a, Part b) {
    return all(min(a.upper.xyz, b.upper.xyz) + linkTolerance
        >= max(a.lower.xyz, b.lower.xyz));
}

void addLink(device GameState &game, uint p, uint q, bool bearing) {
    uint n = game.linkCount[p];
    if (n >= linkCapacity) return;
    Part a = game.parts[p], b = game.parts[q];
    float3 lower = max(a.lower.xyz, b.lower.xyz) - linkTolerance;
    float3 upper = min(a.upper.xyz, b.upper.xyz) + linkTolerance;
    game.links[p][n] = {cellsInBox(a, lower, upper),
        cellsInBox(b, lower, upper), q, bearing ? 1u : 0u, uint2(0u)};
    game.linkCount[p] = n + 1u;
}

// Once per scene: which parts bear their own load, the cells that stand
// on the ground, and every link through which support can arrive.
__attribute__((noinline))
void linkPlayground(device GameState &game) {
    uint count = min(game.counts.x, partCapacity);
    thread bool standing[partCapacity];
    for (uint p = 0u; p < count; ++p) {
        Part part = game.parts[p];
        game.grounded[p] = cellsInBox(part, float3(-1.0e4f),
            float3(1.0e4f, linkTolerance, 1.0e4f));
        standing[p] = game.grounded[p] != 0ul;
        game.linkCount[p] = 0u;
    }
    // A part bears its own load when a chain of parts, each resting on
    // the one below, reaches the ground.
    for (uint round = 0u; round < count; ++round) {
        bool changed = false;
        for (uint p = 0u; p < count; ++p) {
            if (standing[p]) continue;
            for (uint q = 0u; q < count && !standing[p]; ++q)
                if (q != p && standing[q]
                    && restsOn(game.parts[p], game.parts[q])) {
                    standing[p] = true;
                    changed = true;
                }
        }
        if (!changed) break;
    }
    for (uint p = 0u; p < count; ++p) {
        game.parts[p].upper.w = standing[p] ? 1.0f : 0.0f;
        for (uint q = 0u; q < count; ++q)
            if (q != p && restsOn(game.parts[p], game.parts[q]))
                addLink(game, p, q, true);
        if (standing[p]) continue;
        for (uint q = 0u; q < count; ++q)
            if (q != p && !restsOn(game.parts[p], game.parts[q])
                && !restsOn(game.parts[q], game.parts[p])
                && partsTouch(game.parts[p], game.parts[q]))
                addLink(game, p, q, false);
    }
    for (uint p = 0u; p < count; ++p) game.supported[p] = partAlive(game, p);
}

kernel void initializePlayground(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    states[0].view = float4(0.0f);
    states[0].clock = float4(0.0f);
    buildPlayground(states[0]);
    states[0].camera = float4(states[0].player.xyz, 0.0f);
    states[0].stride = float4(states[0].player.w, 0.0f, 0.0f, 0.0f);
}

kernel void linkPlaygroundParts(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    linkPlayground(states[0]);
}

// R rebuilds the scene. The rebuild runs only in this pass and only when
// the player asked for it.
kernel void restartPlayground(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u || states[0].control.x == 0u) return;
    buildPlayground(states[0]);
    linkPlayground(states[0]);
}

// ----------------------------------------------------------------- tracing

struct SceneHit {
    float distance;
    float3 normal;
    float3 local;   // rest-frame point for texturing; on a toy, the
                    // point from its centre over its half extent
    uint style;
    uint kind;      // 0 sky, 1 ground, 2 part, 3 body, 4 rope
    uint index;
    uint cell;
    bool broken;    // an inner face exposed by a missing cell
    uint tint;      // paint of a toy
};

// The first alive cell along the ray inside a celled box, by a 2D walk
// across the cell grid. Inner faces of missing cells become visible.
float traceCells(float3 o, float3 d, float3 lower, float3 upper, uint style,
    ulong alive, float limit, thread float3 &normal, thread uint &cell,
    thread bool &broken) {
    float3 safe = select(d, float3(1.0e-6f), abs(d) < float3(1.0e-6f));
    float3 a = (lower - o) / safe;
    float3 b = (upper - o) / safe;
    float3 nearT = min(a, b), farT = max(a, b);
    float enter = max(nearT.x, max(nearT.y, nearT.z));
    float exit = min(farT.x, min(farT.y, farT.z));
    if (exit < max(enter, 0.0f) || enter > limit) return -1.0f;
    float t = max(enter, 0.0f);
    uint entryAxis = nearT.x >= nearT.y && nearT.x >= nearT.z ? 0u
        : (nearT.y >= nearT.z ? 1u : 2u);
    normal = float3(0.0f);
    normal[entryAxis] = -sign(safe[entryAxis]);
    broken = false;
    uint2 axes = cellAxes(lower, upper, style);
    uint2 grid = cellGrid(lower, upper, axes);
    float3 span = upper - lower;
    float2 size = float2(span[axes.x], span[axes.y]) / float2(grid);
    float2 start = float2(lower[axes.x], lower[axes.y]);
    float2 o2 = float2(o[axes.x], o[axes.y]);
    float2 d2 = float2(safe[axes.x], safe[axes.y]);
    float3 p = o + d * (t + 1.0e-4f);
    int2 c = clamp(int2(floor((float2(p[axes.x], p[axes.y]) - start)
        / size)), int2(0), int2(grid) - 1);
    int2 stepDir = int2(d2.x > 0.0f ? 1 : -1, d2.y > 0.0f ? 1 : -1);
    float2 boundary = start + (float2(c)
        + select(float2(0.0f), float2(1.0f), stepDir > 0)) * size;
    float2 tNext = (boundary - o2) / d2;
    float2 tDelta = size / abs(d2);
    for (uint i = 0u; i < 17u; ++i) {
        uint bit = uint(c.y * 8 + c.x);
        if ((alive & (1ul << bit)) != 0ul) {
            if (t > limit) return -1.0f;
            cell = bit;
            return t;
        }
        uint axis;
        if (tNext.x < tNext.y) {
            t = tNext.x; tNext.x += tDelta.x; c.x += stepDir.x;
            axis = axes.x; normal = float3(0.0f);
            normal[axis] = -float(stepDir.x);
        } else {
            t = tNext.y; tNext.y += tDelta.y; c.y += stepDir.y;
            axis = axes.y; normal = float3(0.0f);
            normal[axis] = -float(stepDir.y);
        }
        broken = true;
        if (t > exit || t > limit || any(c < int2(0))
            || any(c >= int2(grid))) return -1.0f;
    }
    return -1.0f;
}

void traceParts(thread SceneHit &hit, float3 o, float3 d,
    device const GameState &game) {
    uint count = min(game.counts.x, partCapacity);
    for (uint i = 0u; i < count; ++i) {
        ulong alive = partAlive(game, i);
        if (alive == 0ul) continue;
        Part part = game.parts[i];
        float3 normal;
        uint cell = 0u;
        bool broken = false;
        float t = traceCells(o, d, part.lower.xyz, part.upper.xyz,
            uint(part.lower.w), alive, hit.distance, normal, cell, broken);
        if (t >= 0.0f)
            hit = {t, normal, o + d * t, uint(part.lower.w), 2u, i, cell,
                broken};
    }
}

void traceBodies(thread SceneHit &hit, float3 o, float3 d,
    device const GameState &game) {
    for (uint i = 0u; i < bodyCapacity; ++i) {
        pixeltje_physics::RigidBody body = game.world.bodies[i];
        if (body.extentState.w == 0.0f) continue;
        float3 reach = o - body.centreMass.xyz;
        float b = dot(reach, d);
        float r = length(body.extentState.xyz);
        if (dot(reach, reach) - b * b > r * r || b > hit.distance + r)
            continue;
        Piece piece = game.pieces[i];
        float3 restCentre = 0.5f * (piece.lower.xyz + piece.upper.xyz);
        float3 lo = restCentre
            + pixeltje_physics::unrotate(body.orientation, reach);
        float3 ld = pixeltje_physics::unrotate(body.orientation, d);
        float3 normal;
        uint cell = 0u;
        bool broken = false;
        float t;
        uint style = uint(piece.lower.w);
        if (piece.kind == 4u) {
            float radius = 0.5f * (piece.upper.x - piece.lower.x);
            t = pixeltje_3d::raySphere(lo, ld, restCentre, radius, 0.0f);
            if (t >= 0.0f && t < hit.distance) {
                float3 local = (lo + ld * t - restCentre) / radius;
                hit = {t, pixeltje_physics::rotate(body.orientation, local),
                    local, style, 3u, i, 0u, false, piece.tint};
            }
            continue;
        }
        if (piece.kind == 1u) {
            // A chunk walks the cell grid of the part it broke from.
            Part source = game.parts[uint(piece.upper.w) - 1u];
            float3 bLower = max(source.lower.xyz, piece.lower.xyz);
            float3 bUpper = min(source.upper.xyz, piece.upper.xyz);
            float3 safe = select(ld, float3(1.0e-6f),
                abs(ld) < float3(1.0e-6f));
            float3 ta = (bLower - lo) / safe, tb = (bUpper - lo) / safe;
            float3 nearT = min(ta, tb), farT = max(ta, tb);
            float enter = max(nearT.x, max(nearT.y, nearT.z));
            float exit = min(farT.x, min(farT.y, farT.z));
            if (exit < max(enter, 0.0f) || enter > hit.distance) continue;
            // Start the walk where the ray enters the chunk's box so cells
            // of the source outside it are never reported.
            float start = max(enter, 0.0f);
            t = traceCells(lo + ld * start, ld, source.lower.xyz,
                source.upper.xyz, uint(source.lower.w), piece.cells,
                hit.distance - start, normal, cell, broken);
            if (t >= 0.0f) {
                if (t + start > exit) continue;
                if (!broken) {
                    // The entry face is the chunk box's, a fracture face
                    // unless it lies on the source part's surface.
                    uint axis = nearT.x >= nearT.y && nearT.x >= nearT.z
                        ? 0u : (nearT.y >= nearT.z ? 1u : 2u);
                    if (enter > 0.0f) {
                        normal = float3(0.0f);
                        normal[axis] = -sign(safe[axis]);
                        broken = (abs(piece.lower[axis]
                                - source.lower[axis]) > 1.0e-3f
                                && normal[axis] < 0.0f)
                            || (abs(piece.upper[axis]
                                - source.upper[axis]) > 1.0e-3f
                                && normal[axis] > 0.0f);
                    }
                }
                t += start;
            }
        } else {
            t = traceCells(lo, ld, piece.lower.xyz, piece.upper.xyz, style,
                ~0ul, hit.distance, normal, cell, broken);
            broken = piece.kind == 2u;
        }
        if (t >= 0.0f && t < hit.distance) {
            float3 local = lo + ld * t;
            if (style == styleToy)
                local = (local - restCentre)
                    / (0.5f * (piece.upper.xyz - piece.lower.xyz));
            hit = {t, pixeltje_physics::rotate(body.orientation, normal),
                local, style, 3u, i, cell, broken, piece.tint};
        }
    }
}

// The pendulum's rope, a thin capsule from the anchor to the top of its
// ball.
void traceRope(thread SceneHit &hit, float3 o, float3 d,
    device const GameState &game) {
    pixeltje_physics::RigidBody ball = game.world.bodies[pendulumSlot];
    if (ball.extentState.w == 0.0f || game.pieces[pendulumSlot].kind != 4u)
        return;
    const float radius = 0.025f;
    float3 a = game.rope.xyz;
    float3 b = ball.centreMass.xyz + pixeltje_physics::rotate(
        ball.orientation, float3(0.0f, ball.extentState.y, 0.0f));
    float3 ba = b - a, oa = o - a;
    float baba = dot(ba, ba), bard = dot(ba, d), baoa = dot(ba, oa);
    float rdoa = dot(d, oa), oaoa = dot(oa, oa);
    float qa = baba - bard * bard;
    float qb = baba * rdoa - baoa * bard;
    float qc = baba * oaoa - baoa * baoa - radius * radius * baba;
    float h = qb * qb - qa * qc;
    if (h < 0.0f || qa < 1.0e-6f) return;
    float t = (-qb - sqrt(h)) / qa;
    float along = baoa + t * bard;
    if (t <= 0.0f || t >= hit.distance || along < 0.0f || along > baba)
        return;
    float3 axis = a + ba * (along / baba);
    float3 point = o + d * t;
    hit = {t, normalize(point - axis), point, styleRope, 4u, 0u, 0u, false,
        0u};
}

SceneHit traceScene(float3 o, float3 d, float limit,
    device const GameState &game) {
    SceneHit hit = {limit, float3(0.0f, 1.0f, 0.0f), float3(0.0f), 0u, 0u,
        0u, 0u, false};
    if (d.y < -1.0e-5f) {
        float t = -o.y / d.y;
        if (t > 0.0f && t < hit.distance)
            hit = {t, float3(0.0f, 1.0f, 0.0f), o + d * t, 0u, 1u, 0u, 0u,
                false};
    }
    traceParts(hit, o, d, game);
    traceBodies(hit, o, d, game);
    traceRope(hit, o, d, game);
    return hit;
}

// ------------------------------------------------------------------ damage

void launchShard(device GameState &game, Part source, uint bit,
    uint shard, float3 velocity) {
    float3 lower, upper;
    cellBox(source, bit, lower, upper);
    float seed = hash11(float(bit * 7u + shard * 13u) + game.clock.x * 3.1f);
    float3 centre = 0.5f * (lower + upper)
        + (float3(hash11(seed * 9.0f), hash11(seed * 5.0f),
            hash11(seed * 3.0f)) - 0.5f) * min(upper - lower, float3(0.6f));
    float side = 0.18f + 0.14f * seed;
    uint slot = shardFirst + game.counts.z++ % shardCount;
    game.pieces[slot] = {float4(centre - side, source.lower.w),
        float4(centre + side, 0.0f), ~0ul, 2u, 0u};
    pixeltje_physics::RigidBody body = pixeltje_physics::makeRigidBody(
        centre, float3(side), float4(0.0f, 0.0f, 0.0f, 1.0f), velocity,
        1.0f / 0.3f, 0.1f, 0.7f);
    body.angularFriction.xyz = (float3(hash11(seed * 17.0f),
        hash11(seed * 19.0f), hash11(seed * 23.0f)) - 0.5f) * 12.0f;
    game.world.bodies[slot] = body;
    game.world.sleepSeconds[slot] = 0.0f;
}

// Removes one cell, throws two shards out of it and asks the support pass
// to look again.
void breakCell(device GameState &game, uint index, uint bit,
    float3 outward) {
    ulong mask = 1ul << bit;
    if ((partAlive(game, index) & mask) == 0ul
        || uint(game.parts[index].lower.w) == styleSteel) return;
    game.gone[index] |= mask;
    game.counts.y = 1u;
    game.push = float4(-outward, game.clock.x);
    Part part = game.parts[index];
    for (uint shard = 0u; shard < 2u; ++shard)
        launchShard(game, part, bit, shard,
            outward * (2.5f + 1.5f * float(shard))
            + float3(0.0f, 1.0f, 0.0f));
}

// ------------------------------------------------------------------ player

// What the player meets standing on `feet` at p: the highest top within a
// step, to stand on, and whether anything taller overlaps the body.
struct PlayerProbe {
    float floor;
    bool blocked;
};

bool besidePlayer(float3 lower, float3 upper, float2 p, float feet) {
    float2 gap = max(max(lower.xz - p, p - upper.xz), float2(0.0f));
    return length(gap) < playerRadius && lower.y < feet + playerHeight;
}

void probeBox(thread PlayerProbe &probe, float3 lower, float3 upper,
    float2 p, float feet) {
    if (!besidePlayer(lower, upper, p, feet)) return;
    if (upper.y <= feet + playerStep) probe.floor = max(probe.floor, upper.y);
    else probe.blocked = true;
}

// The player collides with what the solver collides with: the alive cells
// of the parts and the bodies where they are now, not the initial boxes.
// shortcut: a tilted body counts as its world bounds, so the player stands
// a little high on tipped rubble; trace its rotated box if that shows.
__attribute__((noinline))
PlayerProbe probePlayer(device const GameState &game, float2 p, float feet) {
    PlayerProbe probe = {0.0f, any(abs(p) > float2(30.0f))};
    uint count = min(game.counts.x, partCapacity);
    for (uint i = 0u; i < count; ++i) {
        Part part = game.parts[i];
        if (!besidePlayer(part.lower.xyz, part.upper.xyz, p, feet)) continue;
        for (ulong cells = partAlive(game, i); cells != 0ul;
            cells &= cells - 1ul) {
            float3 lower, upper;
            cellBox(part, uint(ctz(cells)), lower, upper);
            probeBox(probe, lower, upper, p, feet);
        }
    }
    for (uint i = 0u; i < bodyCapacity; ++i) {
        pixeltje_physics::RigidBody body = game.world.bodies[i];
        if (body.extentState.w == 0.0f) continue;
        float3 reach = game.pieces[i].kind == 4u
            ? float3(body.extentState.x)
            : pixeltje_physics::boxHalfBounds(body);
        probeBox(probe, body.centreMass.xyz - reach,
            body.centreMass.xyz + reach, p, feet);
    }
    return probe;
}

void launchCannonball(device GameState &game, float3 origin,
    float3 direction) {
    const float side = 0.3f;
    float3 centre = origin + direction * 1.2f;
    game.pieces[cannonSlot] = {float4(centre - side, float(styleCannon)),
        float4(centre + side, 0.0f), ~0ul, 3u, 0u};
    pixeltje_physics::RigidBody body = pixeltje_physics::makeRigidBody(
        centre, float3(side), float4(0.0f, 0.0f, 0.0f, 1.0f),
        direction * 26.0f, 1.0f / 8.0f, 0.2f, 0.5f);
    body.angularFriction.xyz = float3(3.0f, 1.0f, 0.0f);
    game.world.bodies[cannonSlot] = body;
    game.world.sleepSeconds[cannonSlot] = 0.0f;
}

kernel void advancePlayer(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.1f);
    game.clock.x += dt;
    uint keys = uint(u.movement.w);
    uint previousKeys = uint(game.clock.y);
    game.clock.y = float(keys);
    if ((keys & fKey) != 0u && (previousKeys & fKey) == 0u)
        game.camera.w = 1.0f - game.camera.w;
    if ((keys & 4u) != 0u && (previousKeys & 4u) == 0u) {
        game.control.x = 1u; // R: the restart pass rebuilds the scene
        return;
    }
    game.control.x = 0u;
    game.player.w = (clamp(u.pointer.x, 0.0f, 1.0f) - 0.5f) * 6.2831853f
        - 0.12f;
    game.view.x = (0.5f - clamp(u.pointer.y, 0.0f, 1.0f)) * 1.9f + 0.04f;
    game.view.z = max(game.view.z - dt, 0.0f);

    // In third person, shots leave from the camera along the crosshair.
    float3 eye = game.camera.w > 0.5f ? game.camera.xyz : game.player.xyz;
    float3 direction = pixeltje_3d::forward(game.player.w, game.view.x);
    uint action = uint(u.pointer.z);
    if (action > uint(game.view.y)) {
        game.view.z = 0.12f;
        game.clock.z += 1.0f;
        SceneHit hit = traceScene(eye, direction, 120.0f, game);
        if (hit.kind == 2u) {
            breakCell(game, hit.index, hit.cell, hit.normal);
        } else if (hit.kind == 3u) {
            pixeltje_physics::RigidBody body = game.world.bodies[hit.index];
            float3 point = eye + direction * hit.distance;
            pixeltje_physics::applyImpulse(body, direction * 4.0f,
                point - body.centreMass.xyz);
            game.world.bodies[hit.index] = body;
            game.world.sleepSeconds[hit.index] = 0.0f;
        }
    }
    game.view.y = float(action);
    if ((keys & cKey) != 0u && (previousKeys & cKey) == 0u)
        launchCannonball(game, game.player.xyz - float3(0.0f, 0.3f, 0.0f),
            direction);
}

// Walking and jumping, a pass of their own so the player's collision probes
// do not compile into one kernel with the shot's scene trace.
kernel void movePlayer(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u || states[0].control.x != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.1f);
    float2 move = clamp(u.movement.xy, float2(-1.0f), float2(1.0f));
    if (length(move) > 1.0f) move = normalize(move);
    float yaw = game.player.w;
    float2 delta = (float2(cos(yaw), sin(yaw)) * move.x
        + float2(sin(yaw), -cos(yaw)) * move.y) * walkingSpeed * dt;
    float2 position = game.player.xz;
    float feet = game.player.y - playerEyeHeight;
    // shortcut: a body that lands on the player frees every move until they
    // step out of it; push the player out instead if walking through shows.
    bool stuck = probePlayer(game, position, feet).blocked;
    if (stuck || !probePlayer(game, position + float2(delta.x, 0.0f),
        feet).blocked)
        position.x += delta.x;
    if (stuck || !probePlayer(game, position + float2(0.0f, delta.y),
        feet).blocked)
        position.y += delta.y;
    game.player.xz = position;

    // The Trackpad's Space action is delivered as a transient secondary
    // action count. Jump only from something underfoot; gravity lands the
    // eye and the skinned character on the highest top beneath them, and a
    // ledge within a step lifts them onto it.
    float ground = probePlayer(game, position, feet).floor;
    uint secondary = uint(u.movement.z);
    if (secondary > uint(game.view.w) && feet <= ground + 0.001f)
        game.stride.w = 5.6f;
    game.view.w = float(secondary);
    if (feet > ground || game.stride.w > 0.0f) {
        float rise = game.stride.w * dt - 4.9f * dt * dt;
        game.stride.w -= 9.8f * dt;
        if (rise > 0.0f && !stuck
            && probePlayer(game, position, feet + rise).blocked) {
            rise = 0.0f; // the head meets something overhead
            game.stride.w = 0.0f;
        }
        feet += rise;
        if (feet <= ground) {
            feet = ground;
            game.stride.w = 0.0f;
        }
    } else {
        feet = ground;
    }
    game.player.y = feet + playerEyeHeight;

    // The character turns toward movement and walks only while grounded.
    if (length(move) > 0.01f) {
        float target = atan2(delta.x, -delta.y);
        float turn = target - game.stride.x;
        turn -= 6.2831853f * floor((turn + 3.1415927f) / 6.2831853f);
        game.stride.x += clamp(turn, -10.0f * dt, 10.0f * dt);
        if (feet <= ground)
            game.stride.y += dt * length(move);
    }
}

// ----------------------------------------------------------------- support

float2 cellsCentroid(Part part, ulong cells, thread float4 &bounds) {
    float2 sum = float2(0.0f);
    float weight = 0.0f;
    bounds = float4(1.0e4f, 1.0e4f, -1.0e4f, -1.0e4f);
    for (uint bit = 0u; bit < 64u; ++bit) {
        if ((cells & (1ul << bit)) == 0ul) continue;
        float3 lower, upper;
        cellBox(part, bit, lower, upper);
        sum += 0.5f * (lower.xz + upper.xz);
        weight += 1.0f;
        bounds = float4(min(bounds.xy, lower.xz), max(bounds.zw, upper.xz));
    }
    return weight > 0.0f ? sum / weight : float2(0.0f);
}

// A part that bears its own load must also balance: the centroid of what
// stands must lie over the cells it stands on. A lintel left on one post
// topples instead of floating as a cantilever.
bool partBalanced(Part part, ulong standing, ulong footing) {
    float4 unused, foot;
    float2 centre = cellsCentroid(part, standing, unused);
    cellsCentroid(part, footing, foot);
    return all(centre >= foot.xy - 0.3f) && all(centre <= foot.zw + 0.3f);
}

// One rectangle of unsupported cells becomes one rigid box. Loose cells
// that are not rectangular split into several boxes, so no body collides
// with cells that are no longer there.
void detachChunk(device GameState &game, uint index, ulong cells) {
    Part part = game.parts[index];
    float3 lower = float3(1.0e4f), upper = float3(-1.0e4f);
    for (uint bit = 0u; bit < 64u; ++bit) {
        if ((cells & (1ul << bit)) == 0ul) continue;
        float3 lo, hi;
        cellBox(part, bit, lo, hi);
        lower = min(lower, lo);
        upper = max(upper, hi);
    }
    float3 size = upper - lower;
    float volume = size.x * size.y * size.z;
    uint slot = chunkFirst + game.control.y++ % chunkCount;
    game.pieces[slot] = {float4(lower, part.lower.w),
        float4(upper, float(index + 1u)), cells, 1u, 0u};
    float seed = hash11(float(index * 31u + slot) + game.clock.x);
    pixeltje_physics::RigidBody body = pixeltje_physics::makeRigidBody(
        0.5f * (lower + upper), 0.5f * size,
        float4(0.0f, 0.0f, 0.0f, 1.0f), float3(0.0f),
        1.0f / clamp(volume * 1.6f, 0.4f, 9.0f), 0.05f, 0.75f);
    body.angularFriction.xyz = (float3(hash11(seed), 0.0f,
        hash11(seed * 7.0f)) - 0.5f) * 0.3f;
    // What the break just did carries over: the freed piece drifts and
    // tips away from the side that was knocked out, so a severed column
    // topples instead of settling straight down onto its stump.
    if (game.clock.x - game.push.w < 0.5f) {
        float3 away = game.push.xyz - float3(0.0f, game.push.y, 0.0f);
        if (length(away) > 1.0e-3f) {
            away = normalize(away);
            body.linearBounce.xyz += away * 0.5f;
            body.angularFriction.xyz += cross(float3(0.0f, 1.0f, 0.0f), away)
                * 0.9f;
        }
    }
    game.world.bodies[slot] = body;
    game.world.sleepSeconds[slot] = 0.0f;
}

// The largest rectangle that grows from the lowest loose cell: first
// along its row, then over the rows above while the whole run is loose.
ulong looseRectangle(ulong loose) {
    uint first = uint(ctz(loose));
    uint x0 = first & 7u, y0 = first >> 3u;
    uint x1 = x0;
    while (x1 < 7u && (loose & (1ul << (y0 * 8u + x1 + 1u))) != 0ul) ++x1;
    ulong run = ((1ul << (x1 - x0 + 1u)) - 1ul) << x0;
    ulong rect = run << (y0 * 8u);
    for (uint y = y0 + 1u; y < 8u; ++y) {
        ulong row = run << (y * 8u);
        if ((loose & row) != row) break;
        rect |= row;
    }
    return rect;
}

__attribute__((noinline))
void resolveSupport(device GameState &game) {
    uint count = min(game.counts.x, partCapacity);
    thread ulong alive[partCapacity];
    thread ulong next[partCapacity];
    for (uint p = 0u; p < count; ++p) {
        alive[p] = partAlive(game, p);
        next[p] = 0ul;
    }
    // Start from nothing so that parts which only hold each other up,
    // with no path to the ground, do not keep themselves standing.
    for (uint round = 0u; round < 2u * partCapacity; ++round) {
        bool changed = false;
        for (uint p = 0u; p < count; ++p) {
            if (alive[p] == 0ul) continue;
            ulong seeds = game.grounded[p];
            ulong footing = game.grounded[p];
            for (uint k = 0u; k < game.linkCount[p]; ++k) {
                SupportLink link = game.links[p][k];
                if ((next[link.from] & link.theirs) == 0ul) continue;
                seeds |= link.mine;
                if (link.bearing != 0u) footing |= link.mine;
            }
            ulong standing = floodCells(alive[p], seeds);
            Part part = game.parts[p];
            if (standing != 0ul && part.upper.w > 0.5f
                && !partBalanced(part, standing, footing & alive[p]))
                standing = 0ul;
            if (standing != next[p]) {
                next[p] = standing;
                changed = true;
            }
        }
        if (!changed) break;
    }
    for (uint p = 0u; p < count; ++p) {
        game.supported[p] = next[p];
        ulong loose = alive[p] & ~next[p];
        for (uint piece = 0u; piece < 6u && loose != 0ul; ++piece) {
            ulong rect = looseRectangle(loose);
            detachChunk(game, p, rect);
            loose &= ~rect;
            game.clock.w += 1.0f;
        }
        game.gone[p] |= alive[p] & ~next[p];
    }
}

kernel void supportPlayground(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u || states[0].counts.y == 0u) return;
    states[0].counts.y = 0u;
    resolveSupport(states[0]);
}

// ----------------------------------------------------------------- physics

pixeltje_physics::RigidBody solverBody(device const GameState &game,
    uint index) {
    if (index == pixeltje_physics::staticBody) {
        pixeltje_physics::RigidBody ground
            = pixeltje_physics::staticRigidBody();
        ground.angularFriction.w = 0.7f;
        ground.linearBounce.w = 0.1f;
        return ground;
    }
    pixeltje_physics::RigidBody body = game.world.bodies[index];
    if (body.extentState.w != 1.0f) body.centreMass.w = 0.0f;
    return body;
}

void addManifold(device GameState &game, uint a, uint b,
    pixeltje_physics::RigidBody bodyA, pixeltje_physics::RigidBody bodyB,
    pixeltje_physics::RigidManifold manifold, float dt) {
    for (uint k = 0u; k < manifold.count; ++k) {
        uint n = game.counts.w;
        if (n >= contactCapacity) return;
        game.contacts[n] = pixeltje_physics::prepareContact(bodyA, bodyB,
            a, b, manifold.normal, manifold.points[k], dt);
        game.counts.w = n + 1u;
    }
}

// The box library has no balls, so they collide here. Each pairing gives
// one point, which a ball needs: it touches only there.
pixeltje_physics::RigidManifold onePoint(float3 normal, float3 point,
    float depth) {
    pixeltje_physics::RigidManifold manifold;
    manifold.normal = normal;
    manifold.count = depth > -contactSlop ? 1u : 0u;
    manifold.points[0] = float4(point, depth);
    return manifold;
}

// A ball against an oriented box; the normal points from the box to the
// ball.
pixeltje_physics::RigidManifold ballBoxManifold(
    pixeltje_physics::RigidBody ball, pixeltje_physics::RigidBody box) {
    float radius = ball.extentState.x;
    float3 local = pixeltje_physics::unrotate(box.orientation,
        ball.centreMass.xyz - box.centreMass.xyz);
    float3 extent = box.extentState.xyz;
    pixeltje_physics::Contact contact = pixeltje_physics::sphereBox(local,
        radius, -extent, extent);
    float3 normal = pixeltje_physics::rotate(box.orientation,
        contact.normal);
    return onePoint(normal, ball.centreMass.xyz
        - normal * (radius - 0.5f * contact.depth), contact.depth);
}

// Any two bodies. The normal points from b to a, as for boxes.
pixeltje_physics::RigidManifold bodyManifold(
    pixeltje_physics::RigidBody a, bool ballA,
    pixeltje_physics::RigidBody b, bool ballB) {
    if (!ballA && !ballB)
        return pixeltje_physics::boxBoxManifold(a, b, contactSlop);
    if (ballA && ballB) {
        pixeltje_physics::Contact contact = pixeltje_physics::sphereSphere(
            a.centreMass.xyz, a.extentState.x, b.centreMass.xyz,
            b.extentState.x);
        return onePoint(contact.normal, b.centreMass.xyz + contact.normal
            * (b.extentState.x - 0.5f * contact.depth), contact.depth);
    }
    if (ballA) return ballBoxManifold(a, b);
    pixeltje_physics::RigidManifold manifold = ballBoxManifold(b, a);
    manifold.normal = -manifold.normal;
    return manifold;
}

bool isBall(device const GameState &game, uint index) {
    return game.pieces[index].kind == 4u;
}

// The rope pulls the top of the pendulum's ball toward the anchor but
// never pushes: a contact whose normal points at the anchor, with depth
// the stretch and no friction. While slack it is speculative and lets the
// ball move only until the rope is straight.
void addRope(device GameState &game, float dt) {
    pixeltje_physics::RigidBody ball = solverBody(game, pendulumSlot);
    if (ball.extentState.w != 1.0f || !isBall(game, pendulumSlot))
        return;
    float3 end = ball.centreMass.xyz + pixeltje_physics::rotate(
        ball.orientation, float3(0.0f, ball.extentState.y, 0.0f));
    float3 toAnchor = game.rope.xyz - end;
    float span = length(toAnchor);
    if (span < game.rope.w - 0.25f || span < 1.0e-4f) return;
    uint n = game.counts.w;
    if (n >= contactCapacity) return;
    pixeltje_physics::SolverContact contact
        = pixeltje_physics::prepareContact(ball,
            solverBody(game, pixeltje_physics::staticBody), pendulumSlot,
            pixeltje_physics::staticBody, toAnchor / span,
            float4(end, span - game.rope.w), dt);
    contact.material.x = 0.0f;
    game.contacts[n] = contact;
    game.counts.w = n + 1u;
}

// A heavy fast body breaks the cells it strikes and keeps going.
bool strikePart(device GameState &game, uint bodyIndex, uint part,
    float3 point, float3 normal, float closing) {
    pixeltje_physics::RigidBody body = game.world.bodies[bodyIndex];
    float mass = 1.0f / max(body.centreMass.w, 1.0e-3f);
    if (closing * mass < 30.0f || closing < 5.0f) return false;
    uint bit = cellAt(game.parts[part], point - normal * 0.05f);
    breakCell(game, part, bit, -normal);
    body.linearBounce.xyz *= 0.75f;
    game.world.bodies[bodyIndex] = body;
    return true;
}

__attribute__((noinline))
void collideBodyWithParts(device GameState &game, uint i, float dt) {
    pixeltje_physics::RigidBody body = solverBody(game, i);
    bool ball = isBall(game, i);
    float3 reach = pixeltje_physics::boxHalfBounds(body) + contactSlop;
    uint count = min(game.counts.x, partCapacity);
    uint source = game.pieces[i].kind == 1u
        ? uint(game.pieces[i].upper.w) - 1u : partCapacity;
    for (uint p = 0u; p < count; ++p) {
        if (p == source) continue;
        Part part = game.parts[p];
        if (any(body.centreMass.xyz + reach < part.lower.xyz)
            || any(body.centreMass.xyz - reach > part.upper.xyz)) continue;
        ulong alive = partAlive(game, p);
        if (alive == 0ul) continue;
        uint2 axes = cellAxes(part.lower.xyz, part.upper.xyz,
            uint(part.lower.w));
        uint2 grid = cellGrid(part.lower.xyz, part.upper.xyz, axes);
        bool whole = alive == gridMask(grid);
        // A damaged part collides as runs of alive cells along its rows.
        for (uint row = 0u; row < (whole ? 1u : grid.y); ++row) {
            uint x = 0u;
            while (x < (whole ? 1u : grid.x)) {
                float3 lower = part.lower.xyz, upper = part.upper.xyz;
                if (!whole) {
                    if ((alive & (1ul << (row * 8u + x))) == 0ul) {
                        ++x;
                        continue;
                    }
                    uint end = x;
                    while (end + 1u < grid.x
                        && (alive & (1ul << (row * 8u + end + 1u))) != 0ul)
                        ++end;
                    float3 lo, hi, lo2, hi2;
                    cellBox(part, row * 8u + x, lo, hi);
                    cellBox(part, row * 8u + end, lo2, hi2);
                    lower = lo;
                    upper = hi2;
                    x = end + 1u;
                } else {
                    x = 1u;
                }
                pixeltje_physics::RigidBody box
                    = pixeltje_physics::makeRigidBody(0.5f * (lower + upper),
                        0.5f * (upper - lower),
                        float4(0.0f, 0.0f, 0.0f, 1.0f), float3(0.0f),
                        0.0f, 0.1f, 0.7f);
                pixeltje_physics::RigidManifold manifold
                    = bodyManifold(body, ball, box, false);
                if (manifold.count == 0u) continue;
                float closing = -dot(body.linearBounce.xyz, manifold.normal);
                uint kind = game.pieces[i].kind;
                if ((kind == 1u || kind == 3u) && manifold.points[0].w > 0.0f
                    && strikePart(game, i, p, manifold.points[0].xyz,
                        manifold.normal, closing)) {
                    body = solverBody(game, i);
                    continue;
                }
                addManifold(game, i, pixeltje_physics::staticBody, body,
                    solverBody(game, pixeltje_physics::staticBody), manifold,
                    dt);
            }
        }
    }
}

kernel void collidePlayground(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = 0.5f * clamp(u.resolutionTime.w, 0.0f, 1.0f / 30.0f);
    game.counts.w = 0u;
    if (dt <= 0.0f) return;
    for (uint i = 0u; i < bodyCapacity; ++i) {
        pixeltje_physics::RigidBody body = game.world.bodies[i];
        pixeltje_physics::integrateVelocity(body, gravity, 0.02f, 0.1f, dt);
        game.world.bodies[i] = body;
    }
    for (uint i = 0u; i < bodyCapacity; ++i) {
        pixeltje_physics::RigidBody a = game.world.bodies[i];
        if (a.extentState.w != 1.0f) continue;
        pixeltje_physics::RigidManifold floor;
        if (isBall(game, i)) {
            float radius = a.extentState.x;
            floor = onePoint(float3(0.0f, 1.0f, 0.0f), a.centreMass.xyz
                - float3(0.0f, radius, 0.0f), radius - a.centreMass.y);
            // A ball on the ground rolls to a stop rather than for ever.
            if (floor.count != 0u) {
                float drag = exp(-0.5f * dt);
                a.linearBounce.xyz *= drag;
                a.angularFriction.xyz *= drag;
                game.world.bodies[i] = a;
            }
        } else {
            floor = pixeltje_physics::boxPlaneManifold(a, float3(0.0f),
                float3(0.0f, 1.0f, 0.0f), contactSlop);
        }
        addManifold(game, i, pixeltje_physics::staticBody, a,
            solverBody(game, pixeltje_physics::staticBody), floor, dt);
        collideBodyWithParts(game, i, dt);
    }
    addRope(game, dt);
    for (uint i = 0u; i < bodyCapacity; ++i) {
        pixeltje_physics::RigidBody a = game.world.bodies[i];
        if (a.extentState.w == 0.0f) continue;
        for (uint j = i + 1u; j < bodyCapacity; ++j) {
            pixeltje_physics::RigidBody b = game.world.bodies[j];
            if (b.extentState.w == 0.0f
                || (a.extentState.w != 1.0f && b.extentState.w != 1.0f)
                || (game.pieces[i].kind == 2u && game.pieces[j].kind == 2u))
                continue;
            float reach = length(a.extentState.xyz)
                + length(b.extentState.xyz) + contactSlop;
            if (distance(a.centreMass.xyz, b.centreMass.xyz) > reach)
                continue;
            pixeltje_physics::RigidManifold manifold = bodyManifold(a,
                isBall(game, i), b, isBall(game, j));
            if (manifold.count == 0u) continue;
            // A moving neighbour wakes a sleeping one; a shard does not.
            float closing = length(a.linearBounce.xyz - b.linearBounce.xyz);
            if (closing > 0.3f) {
                if (a.extentState.w == 2.0f && game.pieces[j].kind != 2u) {
                    a.extentState.w = 1.0f;
                    game.world.bodies[i] = a;
                    game.world.sleepSeconds[i] = 0.0f;
                }
                if (b.extentState.w == 2.0f && game.pieces[i].kind != 2u) {
                    b.extentState.w = 1.0f;
                    game.world.bodies[j] = b;
                    game.world.sleepSeconds[j] = 0.0f;
                }
            }
            addManifold(game, i, j, solverBody(game, i), solverBody(game, j),
                manifold, dt);
        }
    }
}

kernel void solvePlayground(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = 0.5f * clamp(u.resolutionTime.w, 0.0f, 1.0f / 30.0f);
    if (dt <= 0.0f) return;
    uint count = min(game.counts.w, contactCapacity);
    for (uint iteration = 0u; iteration < solverIterations; ++iteration) {
        for (uint c = 0u; c < count; ++c) {
            pixeltje_physics::SolverContact contact = game.contacts[c];
            uint2 pair = contact.bodies;
            pixeltje_physics::RigidBody a = solverBody(game, pair.x);
            pixeltje_physics::RigidBody b = solverBody(game, pair.y);
            pixeltje_physics::solveContact(a, b, contact);
            game.contacts[c] = contact;
            if (a.centreMass.w > 0.0f) {
                game.world.bodies[pair.x].linearBounce = a.linearBounce;
                game.world.bodies[pair.x].angularFriction
                    = a.angularFriction;
            }
            if (pair.y != pixeltje_physics::staticBody
                && b.centreMass.w > 0.0f) {
                game.world.bodies[pair.y].linearBounce = b.linearBounce;
                game.world.bodies[pair.y].angularFriction
                    = b.angularFriction;
            }
        }
    }
    for (uint i = 0u; i < bodyCapacity; ++i) {
        pixeltje_physics::RigidBody body = game.world.bodies[i];
        if (body.extentState.w != 1.0f) continue;
        float spin = length(body.angularFriction.xyz);
        if (spin > 20.0f) body.angularFriction.xyz *= 20.0f / spin;
        pixeltje_physics::integratePosition(body, dt);
        bool quiet = length(body.linearBounce.xyz) < 0.12f
            && length(body.angularFriction.xyz) < 0.25f;
        game.world.sleepSeconds[i] = quiet
            ? game.world.sleepSeconds[i] + dt : 0.0f;
        if (game.world.sleepSeconds[i] > 0.6f) {
            body.linearBounce.xyz = float3(0.0f);
            body.angularFriction.xyz = float3(0.0f);
            body.extentState.w = 2.0f;
        }
        if (body.centreMass.y < -20.0f) body.extentState.w = 0.0f;
        game.world.bodies[i] = body;
    }
}

// ------------------------------------------------------------------ render

// ------------------------------------------------------------------ camera

// First person looks from the eye. Third person looks over the character's
// right shoulder from behind, pulled in front of anything in the way. This
// runs in present, after a preview view's writes have placed the player.
kernel void placeCamera(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.camera.w < 0.5f) {
        game.camera.xyz = game.player.xyz;
        game.stride.z = 0.0f;
        return;
    }
    float3 look = pixeltje_3d::forward(game.player.w, game.view.x);
    float3 right = normalize(cross(look, float3(0.0f, 1.0f, 0.0f)));
    // Follow some of the rise, leaving the avatar visibly above the ground.
    float rise = max(game.player.y - playerEyeHeight, 0.0f);
    float3 pivot = float3(game.player.x, 1.9f + 0.35f * rise,
        game.player.z) + right * 0.55f;
    const float reach = 4.6f;
    SceneHit hit = traceScene(pivot, -look, reach, game);
    float distance = clamp(hit.distance - 0.25f, 0.4f, reach);
    // A wall can force the camera inside the character. Temporarily use the
    // eye view until there is room for a third-person camera again.
    float eyeThreshold = game.stride.z > 0.5f ? 1.2f : 1.0f;
    if (distance < eyeThreshold) {
        game.camera.xyz = game.player.xyz;
        game.stride.z = 1.0f;
        return;
    }
    game.stride.z = 0.0f;
    float3 camera = pivot - look * distance;
    camera.y = max(camera.y, 0.25f);
    game.camera.xyz = camera;
}

// Clip-space position of a world point for the camera the ray tracer uses:
// pixeltje_3d::cameraDirection with a focal length of 1.1.
float4 cameraClip(float3 p, device const GameState &game, float2 resolution) {
    float3 front = pixeltje_3d::forward(game.player.w, game.view.x);
    float3 right = normalize(cross(front, float3(0.0f, 1.0f, 0.0f)));
    float3 up = cross(right, front);
    float3 v = p - game.camera.xyz;
    const float focal = 1.1f, near = 0.05f, far = 400.0f;
    float depth = dot(v, front);
    return float4(2.0f * focal * dot(v, right) * resolution.y / resolution.x,
        2.0f * focal * dot(v, up), far / (far - near) * (depth - near), depth);
}

struct ScreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 p = float2((vertexID << 1u) & 2u, vertexID & 2u);
    return {float4(p * 2.0f - 1.0f, 0.0f, 1.0f),
        float2(p.x, 1.0f - p.y)};
}

// Scene brightness in stops against the exposure the environment sets, at
// which a white surface facing up under its sun and sky shows as 1.
constant float exposureStops = 0.5f;

float luminance(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

// Radiance equirectangular maps arrive as linear half-float textures with a
// mip chain. Longitude wraps and latitude clamps at the poles.
float3 environmentRadiance(texture2d<float> environment, float3 d, float lod) {
    float2 uv = float2(atan2(d.z, d.x) * 0.159154943f + 0.5f,
        acos(clamp(d.y, -1.0f, 1.0f)) * 0.318309886f);
    constexpr sampler environmentSampler(coord::normalized,
        s_address::repeat, t_address::clamp_to_edge,
        filter::linear, mip_filter::linear);
    return environment.sample(environmentSampler, uv, level(lod)).rgb;
}

// The direction of a point of the equirectangular map, the inverse of the
// lookup in environmentRadiance.
float3 environmentDirection(float2 uv) {
    float phi = (uv.x - 0.5f) * 6.2831853f, theta = uv.y * 3.1415927f;
    return float3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));
}

struct SkyBasis {
    float y[9];
};

// The real spherical harmonics of bands 0 to 2.
SkyBasis skyBasis(float3 d) {
    return {{0.282095f, 0.488603f * d.y, 0.488603f * d.z, 0.488603f * d.x,
        1.092548f * d.x * d.y, 1.092548f * d.y * d.z,
        0.315392f * (3.0f * d.z * d.z - 1.0f), 1.092548f * d.x * d.z,
        0.546274f * (d.x * d.x - d.y * d.y)}};
}

// The radiance of a white surface facing n under the environment's sky and
// ground, without its sun.
float3 skyFill(device const GameState &game, float3 n) {
    SkyBasis basis = skyBasis(n);
    float3 fill = float3(0.0f);
    for (uint i = 0u; i < 9u; ++i) fill += game.skyFill[i].rgb * basis.y[i];
    return max(fill, float3(0.0f));
}

// The average colour of the yard's grass, which lights from below.
constant float3 grassAlbedo = float3(0.26f, 0.32f, 0.185f);

// Splits the environment once into a sun and a sky. Texels far brighter than
// the map's mean are the sun: their direction and irradiance light the scene
// through the GGX sun term and its traced shadow. The rest of the upper half
// projects to spherical harmonics of irradiance. The lower half is the
// yard's own sunlit grass rather than the map's ground, which in
// suburban_garden_1k is shaded garden about four times darker. A 128 x 64
// level is plenty for band 2 and still holds suburban_garden_1k's sun in two
// texels, about 500 times brighter than its brightest sky. A map without
// such texels, such as an overcast sky, lights the scene through the
// harmonics alone.
kernel void lightFromEnvironment(device GameState *states [[buffer(1)]],
    texture2d<float> environment [[texture(2)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    uint level = uint(max(int(environment.get_num_mip_levels()) - 8, 0));
    uint2 size = uint2(environment.get_width(level),
        environment.get_height(level));
    float texelAngle = 6.2831853f / float(size.x) * 3.1415927f
        / float(size.y);
    float total = 0.0f;
    for (uint y = 0u; y < size.y; ++y) {
        float angle = texelAngle
            * sin((float(y) + 0.5f) / float(size.y) * 3.1415927f);
        for (uint x = 0u; x < size.x; ++x)
            total += luminance(environment.read(uint2(x, y), level).rgb)
                * angle;
    }
    float threshold = 32.0f * total / 12.566371f;
    float3 sunSum = float3(0.0f), sunColor = float3(0.0f);
    float3 fill[9];
    float ground[9];
    for (uint i = 0u; i < 9u; ++i) {
        fill[i] = float3(0.0f);
        ground[i] = 0.0f;
    }
    float skyPeak = 0.0f;
    for (uint y = 0u; y < size.y; ++y) {
        for (uint x = 0u; x < size.x; ++x) {
            float2 uv = (float2(x, y) + 0.5f) / float2(size);
            float3 d = environmentDirection(uv);
            float3 radiance = environment.read(uint2(x, y), level).rgb;
            float angle = texelAngle * sin(uv.y * 3.1415927f);
            SkyBasis basis = skyBasis(d);
            if (d.y < 0.0f) {
                for (uint i = 0u; i < 9u; ++i) ground[i] += basis.y[i] * angle;
                continue;
            }
            float brightness = luminance(radiance);
            if (brightness > threshold) {
                sunSum += d * brightness * angle;
                sunColor += radiance * angle;
                continue;
            }
            skyPeak = max(skyPeak, brightness);
            for (uint i = 0u; i < 9u; ++i)
                fill[i] += radiance * (basis.y[i] * angle);
        }
    }
    // Convolution with the cosine lobe, over pi, per band.
    const float band[9] = {1.0f, 0.666667f, 0.666667f, 0.666667f,
        0.25f, 0.25f, 0.25f, 0.25f, 0.25f};
    for (uint i = 0u; i < 9u; ++i)
        game.skyFill[i] = float4(fill[i] * band[i], 0.0f);
    float3 sun = length(sunSum) > 0.0f ? normalize(sunSum)
        : float3(0.0f, 1.0f, 0.0f);
    float3 lit = sunColor * max(sun.y, 0.0f) * 0.318309886f
        + skyFill(game, float3(0.0f, 1.0f, 0.0f));
    for (uint i = 0u; i < 9u; ++i)
        game.skyFill[i].rgb += grassAlbedo * lit * (ground[i] * band[i]);
    game.sunLight = float4(sun, 1.0f / max(luminance(lit), 1.0e-4f));
    game.sunColor = float4(sunColor, max(skyPeak, 1.0e-4f));
}

// The visible sky stays procedural; the HDR map only lights surfaces.
float3 skyColor(float3 d, float3 sunDirection) {
    float3 horizon = float3(0.42f, 0.6f, 0.86f);
    float3 zenith = float3(0.04f, 0.18f, 0.6f);
    float3 color = mix(horizon, zenith, pow(clamp(d.y, 0.0f, 1.0f), 0.35f));
    float sun = max(dot(d, sunDirection), 0.0f);
    return color + float3(1.0f, 0.85f, 0.6f) * pow(sun, 400.0f) * 8.0f;
}

// Khronos PBR Neutral: colours below the highlight shoulder pass unchanged,
// so a material shows the base colour it was given.
float3 neutralToneMap(float3 color) {
    const float start = 0.76f, shoulder = 1.0f - start;
    float x = min(color.r, min(color.g, color.b));
    color -= x < 0.08f ? x - 6.25f * x * x : 0.04f;
    float peak = max(color.r, max(color.g, color.b));
    if (peak < start) return color;
    float newPeak = 1.0f - shoulder * shoulder / (peak + shoulder - start);
    color *= newPeak / peak;
    float g = 1.0f - 1.0f / (0.15f * (peak - newPeak) + 1.0f);
    return mix(color, float3(newPeak), g);
}

// Cosine-weighted share of the sky an axis-aligned box hides from a point
// with normal n, both in the box's frame: Lambert's form factors of the
// faces the point sees. A face across the point's horizon counts its lower
// part against the upper, so the share comes out low there.
float boxOcclusion(float3 p, float3 n, float3 extent) {
    if (all(abs(p) < extent)) return 0.0f;
    const float2 corners[4] = {float2(1.0f, 1.0f), float2(-1.0f, 1.0f),
        float2(-1.0f, -1.0f), float2(1.0f, -1.0f)};
    float hidden = 0.0f;
    for (uint a = 0u; a < 3u; ++a) {
        if (abs(p[a]) <= extent[a]) continue;
        float side = sign(p[a]);
        uint b = (a + 1u) % 3u, c = (a + 2u) % 3u;
        // Counter-clockwise about the face's outward normal; the far face's
        // mirror image keeps that order.
        float3 v[4];
        for (uint k = 0u; k < 4u; ++k) {
            float3 q;
            q[a] = side * extent[a];
            q[b] = corners[k].x * extent[b];
            q[c] = corners[k].y * extent[c] * side;
            v[k] = normalize(q - p);
        }
        for (uint k = 0u; k < 4u; ++k) {
            float3 e = cross(v[k], v[(k + 1u) & 3u]);
            float length2 = dot(e, e);
            if (length2 > 1.0e-12f)
                hidden -= dot(n, e) * rsqrt(length2) * acos(clamp(
                    dot(v[k], v[(k + 1u) & 3u]), -1.0f, 1.0f));
        }
    }
    return clamp(hidden * 0.159154943f, 0.0f, 1.0f);
}

// The same share for a ball above the point's horizon.
float ballOcclusion(float3 p, float3 n, float3 centre, float radius) {
    float3 d = centre - p;
    float distance2 = dot(d, d);
    return clamp(dot(n, d) * rsqrt(distance2) * radius * radius / distance2,
        0.0f, 1.0f);
}

// The boxes and balls ambientOcclusion darkens around: each part as the box
// of its alive cells, and every body but the flying shards.
kernel void gatherOccluders(device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    uint count = 0u;
    uint parts = min(game.counts.x, partCapacity);
    for (uint p = 0u; p < parts; ++p) {
        ulong alive = partAlive(game, p);
        if (alive == 0ul) continue;
        float3 lower = float3(1.0e4f), upper = float3(-1.0e4f);
        for (uint bit = 0u; bit < 64u; ++bit) {
            if ((alive & (1ul << bit)) == 0ul) continue;
            float3 cellLower, cellUpper;
            cellBox(game.parts[p], bit, cellLower, cellUpper);
            lower = min(lower, cellLower);
            upper = max(upper, cellUpper);
        }
        game.occluders[count++] = {float4(0.5f * (lower + upper), 0.0f),
            float4(0.5f * (upper - lower), 0.0f),
            float4(0.0f, 0.0f, 0.0f, 1.0f)};
    }
    for (uint i = 0u; i < bodyCapacity; ++i) {
        pixeltje_physics::RigidBody body = game.world.bodies[i];
        Piece piece = game.pieces[i];
        if (body.extentState.w == 0.0f || piece.kind == 2u) continue;
        float radius = piece.kind == 4u
            ? 0.5f * (piece.upper.x - piece.lower.x) : 0.0f;
        game.occluders[count++] = {float4(body.centreMass.xyz, radius),
            float4(body.extentState.xyz, 0.0f), body.orientation};
    }
    game.occluderCount.x = count;
}

// The ambient light left at p after the boxes and balls around it. Each
// occluder fades out between 2 and 3 m, so the full form factor is worked
// out only for the few close by.
float ambientOcclusion(float3 p, float3 n, device const GameState &game) {
    float open = 1.0f;
    uint count = min(game.occluderCount.x, partCapacity + bodyCapacity);
    for (uint i = 0u; i < count; ++i) {
        Occluder o = game.occluders[i];
        float3 local = pixeltje_physics::unrotate(o.orientation,
            p - o.centre.xyz);
        float distance = length(max(abs(local) - o.extent.xyz, 0.0f));
        if (distance > 3.0f
            || dot(n, o.centre.xyz - p) < -length(o.extent.xyz)) continue;
        float hidden = o.centre.w > 0.0f
            ? ballOcclusion(p, n, o.centre.xyz, o.centre.w)
            : boxOcclusion(local, pixeltje_physics::unrotate(o.orientation,
                n), o.extent.xyz);
        open *= 1.0f - hidden * (1.0f - smoothstep(2.0f, 3.0f, distance));
    }
    return open;
}

struct PlaygroundMaterial {
    float3 albedo;
    float roughness;
    float metallic;
    float specular; // scales sun and environment highlights
};

PlaygroundMaterial materialForStyle(uint style, float3 albedo, bool broken) {
    float roughness = 0.88f;
    float metallic = 0.0f;
    if (style == styleSteel) {
        roughness = 0.32f;
        metallic = 0.9f;
    } else if (style == styleToy || style == styleBall) {
        roughness = 0.28f;
    } else if (style == styleRoof) {
        roughness = 0.63f;
        metallic = 0.15f;
    } else if (style == styleRope) {
        roughness = 0.95f;
    } else if (style == styleStone || style == styleBrick) {
        roughness = 0.92f;
    }
    if (broken) {
        roughness = 0.98f;
        metallic = 0.0f;
    }
    return {albedo, roughness, metallic, 1.0f};
}

// GGX microfacet sun light with Schlick Fresnel and Smith masking, from the
// sun lightFromEnvironment found. Diffuse ambient light comes from the
// environment's spherical harmonics; specular light samples
// roughness-dependent mip levels of the HDR map, held to its brightest sky
// so the sun's highlight comes from the GGX term alone. Mip filtering is a
// compact approximation to GGX environment convolution. Occlusion darkens
// both, reflections less on smooth surfaces seen face on.
float3 lightMaterial(PlaygroundMaterial material, float3 normal,
    float3 view, float sunVisibility, float occlusion,
    device const GameState &game, texture2d<float> environment) {
    const float invPi = 0.318309886f;
    float3 n = normalize(normal);
    float3 v = normalize(view);
    float3 l = game.sunLight.xyz;
    float3 h = normalize(v + l);
    float noV = max(dot(n, v), 0.001f);
    float noL = max(dot(n, l), 0.0f);
    float noH = max(dot(n, h), 0.0f);
    float voH = max(dot(v, h), 0.0f);
    float roughness = clamp(material.roughness, 0.08f, 1.0f);
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float divisor = noH * noH * (alpha2 - 1.0f) + 1.0f;
    float distribution = alpha2 * invPi / max(divisor * divisor, 0.0001f);
    float k = (roughness + 1.0f) * (roughness + 1.0f) * 0.125f;
    float geometry = noV / (noV * (1.0f - k) + k)
        * noL / max(noL * (1.0f - k) + k, 0.001f);
    float3 f0 = mix(float3(0.04f), material.albedo, material.metallic);
    float3 fresnel = pixeltje_3d::fresnelSchlick(voH, f0);
    float3 diffuse = (1.0f - fresnel) * (1.0f - material.metallic)
        * material.albedo * invPi;
    float3 specular = distribution * geometry * fresnel
        / max(4.0f * noV * noL, 0.001f) * material.specular;
    float3 sun = (diffuse + specular) * noL * sunVisibility
        * game.sunColor.rgb;

    float3 environmentFresnel = f0 + (max(float3(1.0f - roughness), f0)
        - f0) * pow(1.0f - noV, 5.0f);
    float3 ambientDiffuse = (1.0f - environmentFresnel)
        * (1.0f - material.metallic) * material.albedo * skyFill(game, n)
        * occlusion;
    float environmentLod = float(environment.get_num_mip_levels() - 1u);
    float specularLod = roughness * roughness * environmentLod;
    float3 reflection = environmentRadiance(environment, reflect(-v, n),
        specularLod);
    reflection *= min(1.0f, game.sunColor.w
        / max(luminance(reflection), 1.0e-4f));
    // Lagarde and de Rousiers' specular occlusion.
    float specularOcclusion = saturate(pow(noV + occlusion,
        exp2(-16.0f * roughness - 1.0f)) - 1.0f + occlusion);
    float3 ambientSpecular = environmentFresnel * reflection
        * (1.0f - 0.45f * roughness) * material.specular * specularOcclusion;
    return sun + ambientDiffuse + ambientSpecular;
}

// Mortar courses for brick and stone, planks for wood, all in rest-frame
// coordinates so a falling chunk carries its pattern with it.
float3 surfaceColor(SceneHit hit) {
    float3 p = hit.local;
    float3 n = abs(hit.normal);
    float2 face = n.x > 0.5f ? p.zy : (n.z > 0.5f ? p.xy : p.xz);
    float3 base;
    float grain = hash11(floor(face.x * 3.0f) + floor(face.y * 7.0f) * 17.0f);
    if (hit.style == styleBrick) {
        float2 brick = float2(face.x / 0.5f
            + 0.5f * fmod(floor(face.y / 0.22f), 2.0f), face.y / 0.22f);
        float2 edge = abs(fract(brick) - 0.5f);
        float mortar = step(0.44f, edge.x) + step(0.4f, edge.y);
        base = mix(float3(0.42f, 0.16f, 0.11f) * (0.8f + 0.4f * grain),
            float3(0.55f, 0.52f, 0.47f), clamp(mortar, 0.0f, 1.0f));
    } else if (hit.style == styleStone) {
        float2 block = float2(face.x / 0.8f
            + 0.5f * fmod(floor(face.y / 0.55f), 2.0f), face.y / 0.55f);
        float2 edge = abs(fract(block) - 0.5f);
        float joint = step(0.47f, max(edge.x, edge.y));
        base = mix(float3(0.5f, 0.48f, 0.44f) * (0.85f + 0.3f * grain),
            float3(0.3f, 0.29f, 0.27f), joint);
    } else if (hit.style == styleWood) {
        float plank = fract(face.y / 0.3f);
        base = float3(0.36f, 0.24f, 0.14f) * (0.8f + 0.35f * grain)
            * (plank < 0.06f ? 0.55f : 1.0f);
    } else if (hit.style == styleRoof) {
        base = float3(0.2f, 0.22f, 0.25f) * (0.85f + 0.3f * grain);
    } else if (hit.style == styleCrate) {
        float2 edge = abs(fract(face / 0.9f + 0.5f) - 0.5f);
        base = float3(0.55f, 0.38f, 0.18f) * (0.85f + 0.25f * grain)
            * (max(edge.x, edge.y) > 0.42f ? 0.6f : 1.0f);
    } else if (hit.style == styleSteel) {
        float band = fract(dot(p, float3(1.0f, 0.37f, 1.0f)) * 1.5f);
        base = float3(0.2f, 0.27f, 0.34f) * (0.9f + 0.15f * band);
    } else if (hit.style == styleToy || hit.style == styleBall) {
        const float3 paints[4] = {float3(0.75f, 0.1f, 0.08f),
            float3(0.1f, 0.3f, 0.75f), float3(0.9f, 0.62f, 0.06f),
            float3(0.12f, 0.55f, 0.2f)};
        float3 paint = paints[hit.tint % 4u];
        if (hit.style == styleBall) {
            // A ball: six wedges of paint and white, and a white band, so
            // its roll shows.
            float wedge = floor((atan2(p.z, p.x) + 3.1415927f)
                / 1.0471976f);
            bool white = fmod(wedge, 2.0f) > 0.5f || abs(p.y) < 0.18f;
            base = white ? float3(0.82f, 0.8f, 0.76f) : paint;
        } else {
            // A cube: painted faces with a pale rim along their edges. The
            // face is the rest-frame axis the point reaches, so a tumbling
            // cube keeps its pattern.
            float3 r = abs(p);
            float2 q = r.x >= r.y && r.x >= r.z ? r.yz
                : (r.y >= r.z ? r.xz : r.xy);
            base = max(q.x, q.y) > 0.86f ? float3(0.82f, 0.8f, 0.76f) : paint;
        }
    } else if (hit.style == styleRope) {
        base = float3(0.52f, 0.43f, 0.3f);
    } else {
        base = float3(0.08f, 0.08f, 0.09f);
    }
    // Fracture faces show the rough, paler inside of the material.
    if (hit.broken) base = mix(base, float3(0.45f, 0.42f, 0.38f), 0.45f)
        * (0.75f + 0.5f * hash11(floor(face.x * 9.0f) + floor(face.y * 9.0f)
            * 31.0f));
    return base;
}

// The colour and the depth of what the ray hit, so the character's raster
// pass hides behind walls and props.
struct SceneFragment {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

fragment SceneFragment playgroundFragment(ScreenVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> environment [[texture(2)]]) {
    device const GameState &game = states[0];
    float3 origin = game.camera.xyz;
    float3 direction = pixeltje_3d::cameraDirection(in.uv,
        u.resolutionTime.xy, game.player.w, game.view.x, 1.1f);
    SceneHit hit = traceScene(origin, direction, 200.0f, game);
    float3 color;
    float depth = 1.0f;
    if (hit.kind == 0u) {
        color = skyColor(direction, game.sunLight.xyz);
    } else {
        float3 point = origin + direction * hit.distance;
        float4 clip = cameraClip(point, game, u.resolutionTime.xy);
        depth = clamp(clip.z / clip.w, 0.0f, 1.0f);
        float3 base;
        if (hit.kind == 1u) {
            float2 tile = floor(point.xz / 2.0f);
            float checker = fmod(abs(tile.x + tile.y), 2.0f);
            base = mix(float3(0.24f, 0.3f, 0.17f), float3(0.28f, 0.34f, 0.2f),
                checker) * (0.9f + 0.2f * hash11(floor(point.x * 4.0f)
                + floor(point.z * 4.0f) * 13.0f));
        } else {
            base = surfaceColor(hit);
        }
        float3 sun = game.sunLight.xyz;
        float sunVisibility = 1.0f;
        if (dot(hit.normal, sun) > 0.0f) {
            SceneHit blocker = traceScene(point + hit.normal * 0.01f, sun,
                60.0f, game);
            if (blocker.kind != 0u) sunVisibility = 0.0f;
        }
        PlaygroundMaterial material = hit.kind == 1u
            ? materialForStyle(0u, base, false)
            : materialForStyle(hit.style, base, hit.broken);
        float occlusion = ambientOcclusion(point + hit.normal * 0.01f,
            hit.normal, game);
        color = lightMaterial(material, hit.normal, -direction, sunVisibility,
            occlusion, game, environment) * game.sunLight.w
            * exp2(exposureStops);
        // A soft contact shadow under the third-person character.
        if (hit.kind == 1u && game.camera.w > 0.5f
            && game.stride.z < 0.5f)
            color *= mix(0.45f + 0.55f * smoothstep(0.12f, 0.7f,
                length(point.xz - game.player.xz)), 1.0f,
                clamp((game.player.y - playerEyeHeight) / 2.0f, 0.0f, 1.0f));
    }
    color = neutralToneMap(color);
    float2 pixel = in.uv * u.resolutionTime.xy;
    float2 cross = abs(pixel - u.resolutionTime.xy * 0.5f);
    if ((cross.x < 1.2f && cross.y > 3.0f && cross.y < 10.0f)
        || (cross.y < 1.2f && cross.x > 3.0f && cross.x < 10.0f))
        color = float3(1.0f, 0.95f, 0.85f);
    color += game.view.z * float3(1.0f, 0.6f, 0.25f) * 0.6f;
    return {float4(clamp(pixeltje_3d::linearToSRGB(
        clamp(color, float3(0.0f), float3(1.0f))),
        float3(0.0f), float3(1.0f)), 1.0f), depth};
}

// --------------------------------------------------------------- character

// The layout of a GPU Program skinnedModel resource; see
// PipelineSkinnedModel.swift.
struct SkinnedModelHeader {
    uint vertexCount;
    uint boneCount;
    uint frameCount;
    float framesPerSecond;
    float4 boundsMin;   // w = loop seconds
    float4 boundsMax;
    uint verticesOffset;
    uint framesOffset;
    uint2 reserved;
};

struct SkinnedVertex {
    packed_float3 position;
    uint color;
    packed_float3 normal;
    uint joints;
    float4 weights;
    packed_float2 uv;
};

struct CharacterVertex {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 albedo;
    float2 uv;
};

// Skins one vertex between the two sampled frames around the walk clock,
// then turns the character to its facing and stands it at the player.
vertex CharacterVertex characterVertex(uint id [[vertex_id]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]],
    device const uchar *model [[buffer(2)]]) {
    device const GameState &game = states[0];
    device const SkinnedModelHeader &header =
        *(device const SkinnedModelHeader *)model;
    // Hidden in first person: the camera is inside the head.
    if (game.camera.w < 0.5f || game.stride.z > 0.5f
        || id >= header.vertexCount)
        return {float4(0.0f, 0.0f, -2.0f, 1.0f), float3(0.0f), float3(0.0f),
            float3(0.0f), float2(0.0f)};
    SkinnedVertex v = ((device const SkinnedVertex *)(model
        + header.verticesOffset))[id];
    device const float4x4 *bones = (device const float4x4 *)(model
        + header.framesOffset);
    float frame = game.stride.y * header.framesPerSecond;
    uint first = uint(floor(frame)) % header.frameCount;
    uint second = (first + 1u) % header.frameCount;
    float blend = fract(frame);
    float4x4 skin = float4x4(0.0f);
    for (uint k = 0u; k < 4u; ++k) {
        float weight = v.weights[k];
        if (weight <= 0.0f) continue;
        uint joint = (v.joints >> (8u * k)) & 0xFFu;
        skin = skin + bones[first * header.boneCount + joint]
            * (weight * (1.0f - blend))
            + bones[second * header.boneCount + joint] * (weight * blend);
    }
    float3 local = (skin * float4(float3(v.position), 1.0f)).xyz;
    float3 normal = (skin * float4(float3(v.normal), 0.0f)).xyz;
    // The model faces +Z; turn it to face pixeltje_3d::forward(stride.x).
    float turn = 3.1415927f - game.stride.x;
    float c = cos(turn), s = sin(turn);
    float3 world = float3(c * local.x + s * local.z, local.y,
        -s * local.x + c * local.z) + float3(game.player.x,
        game.player.y - playerEyeHeight,
        game.player.z);
    normal = float3(c * normal.x + s * normal.z, normal.y,
        -s * normal.x + c * normal.z);
    return {cameraClip(world, game, u.resolutionTime.xy), world, normal,
        unpack_unorm4x8_to_float(v.color).rgb, float2(v.uv)};
}

// Lit by the same sun and environment as the traced scene, without its traced
// shadows. The sRGB atlas is converted to linear by its Metal texture format.
fragment float4 characterFragment(CharacterVertex in [[stage_in]],
    device const GameState *states [[buffer(1)]],
    texture2d<float> diffuseAtlas [[texture(1)]],
    texture2d<float> environment [[texture(2)]]) {
    device const GameState &game = states[0];
    constexpr sampler diffuseSampler(coord::normalized, filter::linear,
        address::clamp_to_edge);
    float3 albedo = in.albedo * diffuseAtlas.sample(diffuseSampler, in.uv).rgb;
    float3 view = in.world - game.camera.xyz;
    // Skin and cloth: matte, with faint highlights so rims stay soft.
    PlaygroundMaterial material = {albedo, 0.8f, 0.0f, 0.2f};
    float3 color = neutralToneMap(lightMaterial(material, in.normal, -view,
        1.0f, 1.0f, game, environment) * game.sunLight.w
        * exp2(exposureStops));
    return float4(clamp(pixeltje_3d::linearToSRGB(
        clamp(color, float3(0.0f), float3(1.0f))),
        float3(0.0f), float3(1.0f)), 1.0f);
}

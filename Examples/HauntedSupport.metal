// Structural support for the haunted buildings, as in the Physics
// Playground (PhysicsPlaygroundProgram.metal). The initialize passes link
// every part to the parts it rests on and, when a part does not bear its
// own load (a floor between walls, trim, a frame), to the parts it touches
// at its sides. After damage, damageBuildings asks which cells of the
// struck building still reach the ground. Every structural cell that does
// not falls as a rigid chunk in the physics world; anything else vanishes.

constant uint supportLinkCapacity = 8u;
constant float supportTolerance = 0.03f;
constant uint supportHung = 0u;      // held by whatever it touches
constant uint supportBearing = 1u;   // bears its own load to the ground
constant uint supportAnchored = 2u;  // never falls

// Support reaches part p from part `from`: when any of `theirs` (cells of
// from) stands, the cells `mine` (of p) are seeded.
struct SupportLink {
    ulong mine;
    ulong theirs;
    uint from;
    uint bearing;   // 1 when p rests on from, 0 when from holds p's side
};

// The support buffer. The initialize passes write it; afterwards it is
// read-only, so frames share it instead of copying it.
struct BuildingSupport {
    ulong grounded[houseCapacity];  // cells on the ground; every cell of an
                                    // anchored part
    uint kind[houseCapacity];       // supportHung, Bearing or Anchored
    uint linkCount[houseCapacity];
    SupportLink links[houseCapacity][supportLinkCapacity];
};

static_assert(sizeof(BuildingSupport) <= 346112,
    "The support buffer must hold every part's links");

ulong buildingGridMask(device const HousePart &part) {
    uint2 grid = buildingCellGrid(part);
    ulong row = grid.x >= 8u ? 0xfful : ((1ul << grid.x) - 1ul);
    ulong mask = 0ul;
    for (uint y = 0u; y < grid.y; ++y) mask |= row << (y * 8u);
    return mask;
}

ulong buildingAlive(device const GameState &game, uint index) {
    ulong gone = game.buildingGone[index];
    return gone == ~0ul ? 0ul
        : buildingGridMask(game.house.parts[index]) & ~gone;
}

// The cells of a part that touch a box in its group's frame.
ulong buildingCellsInBox(device const HousePart &part, float3 lower,
    float3 upper) {
    float3 lo = max(lower, part.lower.xyz);
    float3 hi = min(upper, part.upper.xyz);
    if (any(hi < lo)) return 0ul;
    uint2 axes = buildingCellAxes(part);
    uint2 grid = buildingCellGrid(part);
    float3 span = max(part.upper.xyz - part.lower.xyz, float3(0.001f));
    float2 size = float2(span[axes.x], span[axes.y]) / float2(grid);
    float2 origin = float2(part.lower[axes.x], part.lower[axes.y]);
    int2 first = clamp(int2(floor((float2(lo[axes.x], lo[axes.y]) - origin)
        / size)), int2(0), int2(grid) - 1);
    int2 last = clamp(int2(ceil((float2(hi[axes.x], hi[axes.y]) - origin)
        / size)) - 1, first, int2(grid) - 1);
    ulong mask = 0ul;
    for (int y = first.y; y <= last.y; ++y)
        for (int x = first.x; x <= last.x; ++x)
            mask |= 1ul << uint(y * 8 + x);
    return mask;
}

void buildingCellBox(device const HousePart &part, uint bit,
    thread float3 &lower, thread float3 &upper) {
    uint2 axes = buildingCellAxes(part);
    uint2 grid = buildingCellGrid(part);
    float3 span = part.upper.xyz - part.lower.xyz;
    float2 size = float2(span[axes.x], span[axes.y]) / float2(grid);
    lower = part.lower.xyz;
    upper = part.upper.xyz;
    lower[axes.x] += float(bit & 7u) * size.x;
    lower[axes.y] += float(bit >> 3u) * size.y;
    upper[axes.x] = lower[axes.x] + size.x;
    upper[axes.y] = lower[axes.y] + size.y;
}

// Grows seeds through 4-connected alive cells: a part's own cells hold
// together like a mortared wall.
__attribute__((noinline))
ulong floodBuildingCells(ulong alive, ulong seeds) {
    const ulong firstColumn = 0x0101010101010101ul;
    const ulong lastColumn = 0x8080808080808080ul;
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

// A part that bears its own load must balance: the plan centroid of what
// stands lies over the cells it stands on. A beam left on one post topples.
__attribute__((noinline))
bool buildingBalanced(device const HousePart &part, ulong standing,
    ulong footing) {
    float2 sum = float2(0.0f);
    float weight = 0.0f;
    float4 foot = float4(1.0e9f, 1.0e9f, -1.0e9f, -1.0e9f);
    for (uint bit = 0u; bit < 64u; ++bit) {
        ulong mask = 1ul << bit;
        if (((standing | footing) & mask) == 0ul) continue;
        float3 lower, upper;
        buildingCellBox(part, bit, lower, upper);
        if ((standing & mask) != 0ul) {
            sum += 0.5f * (lower.xz + upper.xz);
            weight += 1.0f;
        }
        if ((footing & mask) != 0ul)
            foot = float4(min(foot.xy, lower.xz), max(foot.zw, upper.xz));
    }
    float2 centre = sum / max(weight, 1.0f);
    return all(centre >= foot.xy - 0.3f) && all(centre <= foot.zw + 0.3f);
}

int buildingGroupOf(device const HouseModel &house, uint index) {
    for (uint g = 0u; g < min(house.counts.y, houseGroupCapacity); ++g)
        if (index >= uint(house.groups[g].lower.w)
            && index < uint(house.groups[g].upper.w))
            return int(g);
    return -1;
}

// Parts with their own motion or their own breakage stay out of the
// support graph: the swinging and sliding doors, the masonry panels and
// the tomb rubble.
bool buildingSupportExcluded(device const GameState &game, uint index) {
    device const HouseModel &house = game.house;
    uint style = uint(house.parts[index].lower.w);
    if (style == houseMasonry || physicsReservedPart(house, index))
        return true;
    if (any(uint4(index) == house.doorParts)) return true;
    return index >= game.candyDoorFirstPart
        && index < game.candyDoorFirstPart + 2u * candyStoreDoorPartsPerLeaf;
}

bool buildingRestsOn(device const HousePart &upper,
    device const HousePart &lower) {
    return abs(upper.lower.y - lower.upper.y) <= supportTolerance
        && min(upper.upper.x, lower.upper.x)
            > max(upper.lower.x, lower.lower.x) + 0.01f
        && min(upper.upper.z, lower.upper.z)
            > max(upper.lower.z, lower.lower.z) + 0.01f;
}

// One thread per part: its ground cells and the links through which
// support can reach it, from parts of the same building in the same frame.
// Links where it rests come first; side links fill the rest by area.
kernel void linkBuildingSupport(device const GameState *states [[buffer(1)]],
    device BuildingSupport *supports [[buffer(2)]],
    uint p [[thread_position_in_grid]]) {
    device const GameState &game = states[0];
    device const HouseModel &house = game.house;
    device BuildingSupport &support = supports[0];
    if (p >= houseCapacity) return;
    support.linkCount[p] = 0u;
    support.kind[p] = supportAnchored;
    support.grounded[p] = ~0ul;
    if (p >= min(house.counts.x, houseCapacity)) return;
    int g = buildingGroupOf(house, p);
    device const HousePart &part = house.parts[p];
    if (g < 0 || buildingSupportExcluded(game, p)
        || any(part.upper.xyz <= part.lower.xyz)) return;
    uint owner = house.groupBuilding[g];
    if (owner == 0u || owner >= buildingCount) return;
    HouseGroup group = house.groups[g];
    HouseTurn turn = houseGroupTurn(group);
    float3 centre = houseTurnPointOut(turn,
        0.5f * (part.lower.xyz + part.upper.xyz));
    float ground = buildingsGround(centre.xz,
        moonHeight(centre.xz, moonTraceDetail));
    float top = max(ground, part.lower.y) + 0.15f;
    support.grounded[p] = part.lower.y <= ground + 0.15f
        ? buildingCellsInBox(part, float3(-1.0e9f),
            float3(1.0e9f, top, 1.0e9f)) : 0ul;
    support.kind[p] = support.grounded[p] != 0ul ? supportBearing
        : supportHung;

    thread SupportLink sides[supportLinkCapacity];
    thread float sideArea[supportLinkCapacity];
    uint bearingCount = 0u, sideCount = 0u;
    for (uint other = 0u; other < min(house.counts.y, houseGroupCapacity);
            ++other) {
        HouseGroup next = house.groups[other];
        if (house.groupBuilding[other] != owner
            || any(next.last.yzw != group.last.yzw)
            || any(next.lower.xyz > part.upper.xyz + supportTolerance)
            || any(next.upper.xyz < part.lower.xyz - supportTolerance))
            continue;
        uint end = min(uint(next.upper.w), houseCapacity);
        for (uint q = uint(next.lower.w); q < end; ++q) {
            if (q == p) continue;
            device const HousePart &neighbour = house.parts[q];
            float3 lower = max(part.lower.xyz, neighbour.lower.xyz)
                - supportTolerance;
            float3 upper = min(part.upper.xyz, neighbour.upper.xyz)
                + supportTolerance;
            if (any(upper < lower)
                || any(neighbour.upper.xyz <= neighbour.lower.xyz)
                || buildingRestsOn(neighbour, part)) continue;
            SupportLink link = {buildingCellsInBox(part, lower, upper),
                buildingCellsInBox(neighbour, lower, upper), q, 0u};
            if (buildingRestsOn(part, neighbour)) {
                link.bearing = 1u;
                if (bearingCount < supportLinkCapacity)
                    support.links[p][bearingCount++] = link;
                continue;
            }
            float3 size = upper - lower;
            float area = max(max(size.x * size.y, size.y * size.z),
                size.x * size.z);
            uint slot = sideCount;
            if (sideCount == supportLinkCapacity) {
                slot = 0u;
                for (uint k = 1u; k < supportLinkCapacity; ++k)
                    if (sideArea[k] < sideArea[slot]) slot = k;
                if (area <= sideArea[slot]) continue;
            } else {
                ++sideCount;
            }
            sides[slot] = link;
            sideArea[slot] = area;
        }
    }
    uint count = bearingCount;
    for (uint k = 0u; k < sideCount && count < supportLinkCapacity; ++k)
        support.links[p][count++] = sides[k];
    support.linkCount[p] = count;
}

// Which cells of the parts in [first, end) of the building reach the ground,
// worked out from nothing so that parts which only hold each other up do
// not keep themselves standing. Writes game.buildingSupported.
__attribute__((noinline))
void settleBuildingCells(device GameState &game,
    device const BuildingSupport &support, uint owner) {
    device const HouseModel &house = game.house;
    uint groups = min(house.counts.y, houseGroupCapacity);
    for (uint g = 0u; g < groups; ++g) {
        if (owner != 0u && house.groupBuilding[g] != owner) continue;
        uint end = min(uint(house.groups[g].upper.w), houseCapacity);
        for (uint p = uint(house.groups[g].lower.w); p < end; ++p)
            game.buildingSupported[p] = support.kind[p] == supportAnchored
                ? buildingAlive(game, p) : 0ul;
    }
    for (uint round = 0u; round < 96u; ++round) {
        bool changed = false;
        for (uint g = 0u; g < groups; ++g) {
            if (owner != 0u && house.groupBuilding[g] != owner) continue;
            uint end = min(uint(house.groups[g].upper.w), houseCapacity);
            for (uint p = uint(house.groups[g].lower.w); p < end; ++p) {
                uint kind = support.kind[p];
                if (kind == supportAnchored) continue;
                ulong alive = buildingAlive(game, p);
                ulong seeds = support.grounded[p];
                ulong footing = seeds;
                for (uint k = 0u; k < support.linkCount[p]; ++k) {
                    SupportLink link = support.links[p][k];
                    if ((link.bearing == 0u && kind == supportBearing)
                        || (game.buildingSupported[link.from] & link.theirs)
                            == 0ul) continue;
                    seeds |= link.mine;
                    if (link.bearing != 0u) footing |= link.mine;
                }
                ulong standing = alive == 0ul ? 0ul
                    : floodBuildingCells(alive, seeds);
                if (standing != 0ul && kind == supportBearing
                    && !buildingBalanced(house.parts[p], standing,
                        footing & alive))
                    standing = 0ul;
                if (standing != game.buildingSupported[p]) {
                    game.buildingSupported[p] = standing;
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
}

// Which parts bear their own load: a chain of parts, each resting on the
// one below, reaches the ground. Then anything that would not stand in the
// intact town is anchored, so the graph never drops what it cannot explain.
kernel void settleBuildingSupport(device GameState *states [[buffer(1)]],
    device BuildingSupport *supports [[buffer(2)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    device BuildingSupport &support = supports[0];
    uint count = min(game.house.counts.x, houseCapacity);
    for (uint round = 0u; round < 64u; ++round) {
        bool changed = false;
        for (uint p = 0u; p < count; ++p) {
            if (support.kind[p] != supportHung) continue;
            for (uint k = 0u; k < support.linkCount[p]; ++k) {
                SupportLink link = support.links[p][k];
                if (link.bearing != 0u
                    && support.kind[link.from] != supportHung) {
                    support.kind[p] = supportBearing;
                    changed = true;
                    break;
                }
            }
        }
        if (!changed) break;
    }
    settleBuildingCells(game, support, 0u);
    for (uint p = 0u; p < count; ++p) {
        if (support.kind[p] == supportAnchored
            || game.buildingSupported[p] == buildingAlive(game, p)) continue;
        support.kind[p] = supportAnchored;
        support.grounded[p] = ~0ul;
    }
}

// A chunk takes a free chunk slot, else the slot of the longest-resting
// chunk, whose rubble then clears; with every chunk still moving, the
// detachment waits for a later frame.
int buildingChunkSlot(device GameState &game) {
    uint chunkSlots = buildingFragmentCount - buildingShardSlots;
    int sleeping = -1;
    for (uint k = 0u; k < chunkSlots; ++k) {
        uint slot = buildingShardSlots
            + (game.buildingChunkNext + k) % chunkSlots;
        float state = game.physicsWorld.bodies[slot].extentState.w;
        if (state == 0.0f) return int(slot);
        if (state == 2.0f && sleeping < 0) sleeping = int(slot);
    }
    if (sleeping >= 0) {
        // Whatever rested on the cleared rubble settles again.
        for (uint i = 0u; i < physicsBodyCount; ++i)
            if (game.physicsWorld.bodies[i].extentState.w == 2.0f) {
                game.physicsWorld.bodies[i].extentState.w = 1.0f;
                game.physicsWorld.sleepSeconds[i] = 0.0f;
            }
    }
    return sleeping;
}

// The largest rectangle of loose cells that grows from the lowest one,
// first along its row and then over the rows above.
ulong looseBuildingRectangle(ulong loose) {
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

// One rectangle of a part's cells becomes a rigid chunk that keeps the
// part's geometry, cut planes and texture. False when no slot is free.
bool detachBuildingChunk(device GameState &game, uint index, ulong cells) {
    int found = buildingChunkSlot(game);
    if (found < 0) return false;
    uint slot = uint(found);
    game.buildingChunkNext = slot - buildingShardSlots + 1u;
    device const HousePart &source = game.house.parts[index];
    HousePart piece = source;
    uint style = uint(source.lower.w);
    if (!houseRoundStyle(style)) {
        float3 lower = float3(1.0e9f), upper = float3(-1.0e9f);
        for (uint bit = 0u; bit < 64u; ++bit) {
            if ((cells & (1ul << bit)) == 0ul) continue;
            float3 lo, hi;
            buildingCellBox(source, bit, lo, hi);
            lower = min(lower, lo);
            upper = max(upper, hi);
        }
        piece.lower.xyz = max(lower, source.lower.xyz);
        piece.upper.xyz = min(upper, source.upper.xyz);
    }
    game.buildingFragments[slot] = piece;
    game.buildingFragmentSource[slot] = index;
    game.buildingFragmentGone[slot] = houseRoundStyle(style) ? 0ul : ~cells;
    game.buildingFragmentActive = 1u;
    HouseTurn turn = housePartTurn(game.house, index);
    float3 size = piece.upper.xyz - piece.lower.xyz;
    float volume = size.x * size.y * size.z;
    float3 velocity = float3(0.0f);
    float3 spin = float3(0.0f);
    // What the break just did carries over: the freed piece drifts and tips
    // away from the side that was knocked out, so a severed chimney topples
    // instead of settling straight down onto its stump.
    float3 away = game.buildingPush.xyz * float3(1.0f, 0.0f, 1.0f);
    if (game.effects.x - game.buildingPush.w < 0.5f
        && length(away) > 1.0e-3f) {
        away = normalize(away);
        velocity = away * 0.6f;
        spin = cross(float3(0.0f, 1.0f, 0.0f), away) * 0.9f;
    }
    pixeltje_physics::RigidBody body = pixeltje_physics::makeRigidBody(
        houseTurnPointOut(turn, 0.5f * (piece.lower.xyz + piece.upper.xyz)),
        0.5f * size, physicsGroupRotation(turn), velocity,
        1.0f / clamp(volume, 0.3f, 12.0f), 0.05f, 0.75f);
    body.angularFriction.xyz = spin;
    game.physicsWorld.bodies[slot] = body;
    game.physicsWorld.sleepSeconds[slot] = 0.0f;
    resetLandingPlayed(game, slot);
    return true;
}

// After damage: the cells of a building that no longer reach the ground
// come loose. Structural cells fall as chunks; trim, glass, furniture and
// the like vanish. False when a chunk must wait for a free slot.
__attribute__((noinline))
bool releaseUnsupportedCells(device GameState &game, device RangeAudio &audio,
    device const BuildingSupport &support, uint owner) {
    settleBuildingCells(game, support, owner);
    device const HouseModel &house = game.house;
    bool done = true;
    bool sounded = false;
    for (uint g = 0u; g < min(house.counts.y, houseGroupCapacity); ++g) {
        if (house.groupBuilding[g] != owner) continue;
        uint end = min(uint(house.groups[g].upper.w), houseCapacity);
        for (uint p = uint(house.groups[g].lower.w); p < end; ++p) {
            if (support.kind[p] == supportAnchored) continue;
            ulong alive = buildingAlive(game, p);
            ulong loose = alive & ~game.buildingSupported[p];
            if (loose == 0ul) continue;
            uint style = uint(house.parts[p].lower.w);
            if (!buildingBreakable(style)) {
                game.buildingGone[p] = ~0ul;
                continue;
            }
            for (uint piece = 0u; piece < 6u && loose != 0ul; ++piece) {
                ulong rect = houseRoundStyle(style) ? loose
                    : looseBuildingRectangle(loose);
                if (!detachBuildingChunk(game, p, rect)) {
                    done = false;
                    break;
                }
                game.buildingGone[p] |= rect;
                loose &= ~rect;
                if (!sounded) {
                    emitDebrisSound(game, audio, style, 2u);
                    sounded = true;
                }
            }
            if ((buildingAlive(game, p)) == 0ul) game.buildingGone[p] = ~0ul;
        }
    }
    return done;
}

__attribute__((noinline))
void settleDamagedBuildings(device GameState &game, device RangeAudio &audio,
    device const BuildingSupport &support) {
    for (uint owner = 1u; owner < buildingCount; ++owner) {
        uint bit = 1u << owner;
        if ((game.buildingSupportDirty & bit) == 0u) continue;
        if (releaseUnsupportedCells(game, audio, support, owner))
            game.buildingSupportDirty &= ~bit;
    }
}

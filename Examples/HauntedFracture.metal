// Damage for the haunted buildings. Intact parts keep their original trace
// cost. A hit removes cells from only the struck part, and a small shared
// pool holds the fragments that are actually in flight.

float buildingsGround(float2 p, float h);
float moonHeight(float2 p, int detail);

uint buildingPartOwner(device const HouseModel &house, uint index) {
    for (uint g = 0u; g < min(house.counts.y, houseGroupCapacity); ++g)
        if (index >= uint(house.groups[g].lower.w)
            && index < uint(house.groups[g].upper.w))
            return house.groupBuilding[g];
    return 0u;
}

bool buildingBreakable(uint style) {
    return style == houseSiding || style == houseBattens
        || style == houseRoof || style == houseTrim || style == houseStone
        || style == houseBrick || style == houseTimber || style == houseLog
        || style == houseGrave || style == houseCorrugated
        || style == housePlaster || style == housePlasterColumn
        || style == houseFloor || style == houseStair;
}

// The two broadest directions define a damage map without storing separate
// pieces before an impact. Roofs and floors use their plan.
uint2 buildingCellAxes(device const HousePart &part) {
    uint style = uint(part.lower.w);
    if (style == houseRoof || style == houseCorrugated
        || style == houseFloor) return uint2(0u, 2u);
    float3 span = part.upper.xyz - part.lower.xyz;
    if (span.x <= span.y && span.x <= span.z) return uint2(1u, 2u);
    if (span.y <= span.z) return uint2(0u, 2u);
    return uint2(0u, 1u);
}

uint2 buildingCellGrid(device const HousePart &part) {
    uint2 axes = buildingCellAxes(part);
    float3 span = part.upper.xyz - part.lower.xyz;
    return uint2(clamp(ceil(float2(span[axes.x], span[axes.y]) / 1.25f),
        float2(1.0f), float2(8.0f)));
}

uint2 buildingCell(device const HousePart &part, float3 p) {
    uint2 axes = buildingCellAxes(part);
    uint2 grid = buildingCellGrid(part);
    float3 span = max(part.upper.xyz - part.lower.xyz, float3(0.001f));
    float2 uv = (float2(p[axes.x], p[axes.y])
        - float2(part.lower[axes.x], part.lower[axes.y]))
        / float2(span[axes.x], span[axes.y]);
    return uint2(clamp(floor(uv * float2(grid)), float2(0.0f),
        float2(grid - 1u)));
}

bool buildingCellGone(device const GameState &game, uint index,
    device const HousePart &part, float3 p) {
    ulong mask = game.buildingGone[index];
    if (mask == 0ul) return false;
    uint2 cell = buildingCell(part, p);
    return (mask & (1ul << (cell.y * 8u + cell.x))) != 0ul;
}

float buildingCollapseThreshold(uint owner) {
    if (owner == 1u) return 60.0f;
    if (owner == 2u || owner == 3u || owner >= 13u) return 28.0f;
    if (owner == 6u || (owner >= 7u && owner <= 9u)) return 38.0f;
    return 30.0f; // original and street-copy barns and open sheds
}

// Keep the exact cut-box geometry and material of a detached section. Its
// group turn stays with it, so street copies retain their angle as they fall.
void launchBuildingFragment(device GameState &game, uint index, uint2 cell,
    HouseTurn turn, float3 velocity, bool whole) {
    device const HousePart &source = game.house.parts[index];
    HousePart piece = source;
    if (!whole && !houseRoundStyle(uint(source.lower.w))) {
        uint2 axes = buildingCellAxes(source);
        uint2 grid = buildingCellGrid(source);
        float3 span = source.upper.xyz - source.lower.xyz;
        piece.lower[axes.x] = source.lower[axes.x]
            + float(cell.x) * span[axes.x] / float(grid.x);
        piece.upper[axes.x] = source.lower[axes.x]
            + float(cell.x + 1u) * span[axes.x] / float(grid.x);
        piece.lower[axes.y] = source.lower[axes.y]
            + float(cell.y) * span[axes.y] / float(grid.y);
        piece.upper[axes.y] = source.lower[axes.y]
            + float(cell.y + 1u) * span[axes.y] / float(grid.y);
    }
    uint slot = game.buildingFragmentNext++ % buildingFragmentCount;
    game.buildingFragments[slot] = piece;
    game.buildingFragmentSource[slot] = index;
    game.buildingFragmentGone[slot] = whole ? game.buildingGone[index] : 0ul;
    game.buildingFragmentActive = 1u;
    float3 centre = houseTurnPointOut(turn,
        0.5f * (piece.lower.xyz + piece.upper.xyz));
    float angle = atan2(turn.sine, turn.cosine);
    float4 orientation = float4(0.0f, -sin(0.5f * angle), 0.0f,
        cos(0.5f * angle));
    float3 halfExtent = 0.5f * (piece.upper.xyz - piece.lower.xyz);
    float inverseMass = 1.0f / max(0.2f,
        2.0f * halfExtent.x * 2.0f * halfExtent.y
            * 2.0f * halfExtent.z);
    game.physicsWorld.bodies[slot] = pixeltje_physics::makeRigidBody(
        centre, halfExtent, orientation, velocity, inverseMass, 0.18f, 0.75f);
    game.physicsWorld.sleepSeconds[slot] = 0.0f;
}

bool buildingCollapseSurface(uint style) {
    return style == houseSiding || style == houseBattens
        || style == houseRoof || style == houseCorrugated
        || style == houseStone || style == houseBrick
        || style == housePlaster;
}

void buildingMaybeCollapse(device GameState &game, uint owner) {
    if (owner == 0u || owner >= buildingCount
        || game.buildingCollapseTime[owner] >= 0.0f
        || game.buildingDamage[owner] < buildingCollapseThreshold(owner))
        return;
    game.buildingCollapseTime[owner] = game.effects.x;
    // Detach a few of the building's largest structural surfaces as the
    // remaining framework gives way. The shared pool bounds render cost.
    thread float area[8];
    thread uint selected[8];
    for (uint k = 0u; k < 8u; ++k) {
        area[k] = 0.0f;
        selected[k] = 0u;
    }
    for (uint g = 0u; g < min(game.house.counts.y, houseGroupCapacity);
            ++g) {
        if (game.house.groupBuilding[g] != owner) continue;
        HouseGroup group = game.house.groups[g];
        for (uint index = uint(group.lower.w);
                index < min(uint(group.upper.w), houseCapacity); ++index) {
            device const HousePart &part = game.house.parts[index];
            if (!buildingCollapseSurface(uint(part.lower.w))) continue;
            float3 size = part.upper.xyz - part.lower.xyz;
            if (any(size <= 0.0f)) continue;
            float score = max(max(size.x * size.y, size.y * size.z),
                size.x * size.z);
            uint smallest = 0u;
            for (uint k = 1u; k < 8u; ++k)
                if (area[k] < area[smallest]) smallest = k;
            if (score > area[smallest]) {
                area[smallest] = score;
                selected[smallest] = index;
            }
        }
    }
    for (uint k = 0u; k < 8u; ++k) {
        if (area[k] <= 0.0f) continue;
        uint index = selected[k];
        HouseTurn turn = housePartTurn(game.house, index);
        float seed = houseHash(float(index * 37u + owner * 13u));
        float3 velocity = float3(1.8f * (seed - 0.5f), 0.8f,
            1.8f * (houseHash(float(index * 19u)) - 0.5f));
        launchBuildingFragment(game, index, uint2(0u), turn,
            velocity, true);
        // The detached surface now belongs only to the moving world body.
        game.buildingGone[index] = ~0ul;
    }
}

bool markBuildingCell(device GameState &game, uint index, uint2 cell) {
    if (houseRoundStyle(uint(game.house.parts[index].lower.w))) {
        if (game.buildingGone[index] != 0ul) return false;
        game.buildingGone[index] = ~0ul;
        return true;
    }
    ulong bit = 1ul << (cell.y * 8u + cell.x);
    if ((game.buildingGone[index] & bit) != 0ul) return false;
    game.buildingGone[index] |= bit;
    return true;
}

// Bullets use the actual part reported by the weapon trace. A removed cell
// remains absent in view and shadow rays as well as subsequent weapon rays.
__attribute__((noinline))
void damageBuildingHit(device GameState &game, BuildingImpact impact) {
    uint index = impact.part;
    if (index >= min(game.house.counts.x, houseCapacity)) return;
    uint owner = buildingPartOwner(game.house, index);
    if (owner == 0u) return;
    device const HousePart &part = game.house.parts[index];
    uint style = uint(part.lower.w);
    if (!buildingBreakable(style)) return;
    HouseTurn turn = housePartTurn(game.house, index);
    float3 local = houseTurnPointIn(turn, impact.pointDamage.xyz);
    uint2 cell = buildingCell(part, local);
    if (!markBuildingCell(game, index, cell)) return;
    game.buildingDamage[owner] += impact.pointDamage.w;
    float3 velocity = impact.normal.xyz * 1.2f
        + float3(0.0f, 0.35f, 0.0f);
    launchBuildingFragment(game, index, cell, turn, velocity, false);
    buildingMaybeCollapse(game, owner);
}

// Blast work stays out of the per-frame player and shot traces. Group and
// part bounds prune the search, and damage per building is capped per blast
// so a single explosion cannot drop a whole house through overlapping trim.
__attribute__((noinline))
void damageBuildingsBlast(device GameState &game, float3 blast) {
    thread float added[buildingCount];
    for (uint owner = 0u; owner < buildingCount; ++owner) added[owner] = 0.0f;
    thread float nearestDistance[buildingFragmentCount];
    thread uint nearestPart[buildingFragmentCount];
    thread uint2 nearestCell[buildingFragmentCount];
    for (uint k = 0u; k < buildingFragmentCount; ++k)
        nearestDistance[k] = 1.0e9f;
    for (uint g = 0u; g < min(game.house.counts.y, houseGroupCapacity); ++g) {
        uint owner = game.house.groupBuilding[g];
        if (owner == 0u || owner >= buildingCount) continue;
        HouseGroup group = game.house.groups[g];
        HouseTurn turn = houseGroupTurn(group);
        float3 localBlast = houseTurnPointIn(turn, blast);
        if (distance(localBlast, clamp(localBlast, group.lower.xyz,
                group.upper.xyz)) > blastRadius) continue;
        for (uint index = uint(group.lower.w);
                index < min(uint(group.upper.w), houseCapacity); ++index) {
            device const HousePart &part = game.house.parts[index];
            uint style = uint(part.lower.w);
            if (!buildingBreakable(style)
                || any(part.upper.xyz <= part.lower.xyz)) continue;
            float3 nearest = clamp(localBlast, part.lower.xyz, part.upper.xyz);
            if (distance(localBlast, nearest) > blastRadius) continue;
            uint2 cell = buildingCell(part, nearest);
            uint2 grid = buildingCellGrid(part);
            uint2 axes = buildingCellAxes(part);
            float3 span = part.upper.xyz - part.lower.xyz;
            int extent = houseRoundStyle(style) ? 0 : 1;
            for (int y = -extent; y <= extent; ++y)
                for (int x = -extent; x <= extent; ++x) {
                    int2 next = int2(cell) + int2(x, y);
                    if (any(next < int2(0)) || any(next >= int2(grid))) continue;
                    float3 sample = nearest;
                    sample[axes.x] = part.lower[axes.x]
                        + (float(next.x) + 0.5f) * span[axes.x] / float(grid.x);
                    sample[axes.y] = part.lower[axes.y]
                        + (float(next.y) + 0.5f) * span[axes.y] / float(grid.y);
                    float distanceToBlast = distance(sample, localBlast);
                    if (distanceToBlast > blastRadius) continue;
                    ulong bit = 1ul << (uint(next.y) * 8u + uint(next.x));
                    if ((game.buildingGone[index] & bit) != 0ul) continue;
                    uint farthest = 0u;
                    for (uint k = 1u; k < buildingFragmentCount; ++k)
                        if (nearestDistance[k] > nearestDistance[farthest])
                            farthest = k;
                    if (distanceToBlast < nearestDistance[farthest]) {
                        nearestDistance[farthest] = distanceToBlast;
                        nearestPart[farthest] = index;
                        nearestCell[farthest] = uint2(next);
                    }
                }
        }
    }
    for (uint k = 0u; k < buildingFragmentCount; ++k) {
        if (nearestDistance[k] > blastRadius) continue;
        uint index = nearestPart[k];
        uint owner = buildingPartOwner(game.house, index);
        uint2 cell = nearestCell[k];
        if (!markBuildingCell(game, index, cell)) continue;
        if (added[owner] < 10.0f) {
            game.buildingDamage[owner] += 1.0f;
            added[owner] += 1.0f;
        }
        HouseTurn turn = housePartTurn(game.house, index);
        device const HousePart &part = game.house.parts[index];
        uint2 axes = buildingCellAxes(part);
        uint2 grid = buildingCellGrid(part);
        float3 local = 0.5f * (part.lower.xyz + part.upper.xyz);
        local[axes.x] = part.lower[axes.x] + (float(cell.x) + 0.5f)
            * (part.upper[axes.x] - part.lower[axes.x]) / float(grid.x);
        local[axes.y] = part.lower[axes.y] + (float(cell.y) + 0.5f)
            * (part.upper[axes.y] - part.lower[axes.y]) / float(grid.y);
        float3 away = houseTurnPointOut(turn, local) - blast;
        float seed = houseHash(float(index * 29u + cell.x * 7u + cell.y));
        float3 velocity = normalize(away + float3(0.0f, 0.5f, 0.0f))
            * (1.0f + 1.5f * seed);
        launchBuildingFragment(game, index, cell, turn, velocity, false);
    }
    for (uint owner = 1u; owner < buildingCount; ++owner)
        buildingMaybeCollapse(game, owner);
}

void resetBuildingDamage(device GameState &game) {
    for (uint i = 0u; i < houseCapacity; ++i) game.buildingGone[i] = 0ul;
    for (uint i = 0u; i < buildingCount; ++i) {
        game.buildingDamage[i] = 0.0f;
        game.buildingCollapseTime[i] = -100.0f;
    }
    for (uint i = 0u; i < buildingFragmentCount; ++i) {
        game.buildingFragmentSource[i] = 0u;
        game.buildingFragmentGone[i] = 0ul;
        game.physicsWorld.bodies[i].extentState.w = 0.0f;
        game.physicsWorld.sleepSeconds[i] = 0.0f;
    }
    game.buildingFragmentNext = 0u;
    game.buildingFragmentActive = 0u;
    game.buildingImpactCountNow = 0u;
    game.buildingLastBlast = -100.0f;
}

// Dynamic fragments keep their authoring geometry and follow world bodies.
void traceBuildingFragments(thread SceneHit &hit, float3 origin,
    float3 direction, device const GameState &game) {
    if (game.buildingFragmentActive == 0u) return;
    for (uint i = 0u; i < buildingFragmentCount; ++i) {
        pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
        if (body.extentState.w <= 0.0f) continue;
        device const HousePart &part = game.buildingFragments[i];
        float3 originalCentre = 0.5f * (part.lower.xyz + part.upper.xyz);
        float3 localOrigin = originalCentre
            + pixeltje_physics::unrotate(body.orientation,
                origin - body.centreMass.xyz);
        float3 localDirection
            = pixeltje_physics::unrotate(body.orientation, direction);
        float3 normal;
        float t = houseHitPart(part, localOrigin, localDirection,
            hit.distance, normal);
        if (t > 0.0f) {
            float3 point = localOrigin + localDirection * t;
            uint2 cell = buildingCell(part, point);
            if ((game.buildingFragmentGone[i]
                    & (1ul << (cell.y * 8u + cell.x))) != 0ul) continue;
            uint source = game.buildingFragmentSource[i];
            device const HousePart &original = game.house.parts[source];
            float3 originalPoint = point;
            uint style = uint(part.lower.w);
            if (houseCutoutStyle(style)
                && houseCutoutOpen(style, original, originalPoint)) continue;
            if ((style == houseSiding || style == houseBattens)
                && houseSeeThrough(original)
                && houseWindow(original, source, originalPoint, normal,
                    0.002f, houseWind(game)).glass > 0.5f) continue;
        }
        if (t > 0.0f) hit = {t,
            pixeltje_physics::rotate(body.orientation, normal),
            origin + direction * t,
            houseMaterialBase + uint(part.lower.w), -1, houseCapacity + i};
    }
}

// Resting chunks have the same basic footing and clearance as the tomb's
// masonry rubble. Moving chunks are still visual until they settle.
constant float buildingFragmentClimb = 0.8f;
__attribute__((noinline))
float buildingFragmentStand(device const GameState &game, float2 p,
    float foot, float ground) {
    if (game.buildingFragmentActive == 0u) return ground;
    float top = ground;
    for (uint i = 0u; i < buildingFragmentCount; ++i) {
        pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
        if (body.extentState.w < 1.5f) continue;
        float3 boundsHalf = pixeltje_physics::boxHalfBounds(body);
        float3 lower = body.centreMass.xyz - boundsHalf;
        float3 upper = body.centreMass.xyz + boundsHalf;
        if (all(p >= lower.xz) && all(p <= upper.xz)
            && upper.y <= foot + buildingFragmentClimb)
            top = max(top, upper.y);
    }
    return top;
}

__attribute__((noinline))
bool buildingFragmentBlocked(device const GameState &game, float2 p,
    float foot) {
    if (game.buildingFragmentActive == 0u) return false;
    for (uint i = 0u; i < buildingFragmentCount; ++i) {
        pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
        if (body.extentState.w < 1.5f) continue;
        float3 boundsHalf = pixeltje_physics::boxHalfBounds(body);
        float3 lower = body.centreMass.xyz - boundsHalf;
        float3 upper = body.centreMass.xyz + boundsHalf;
        float2 gap = max(max(lower.xz - p,
            p - upper.xz), float2(0.0f));
        if (length(gap) < housePlayerPad
            && upper.y > foot + buildingFragmentClimb
            && lower.y < foot + 1.75f) return true;
    }
    return false;
}

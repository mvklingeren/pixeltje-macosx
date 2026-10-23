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

uint debrisMaterialKind(uint style) {
    if (style == houseStone || style == houseBrick || style == houseGrave)
        return 1u;
    if (style == houseCorrugated || style == houseCastIronRod)
        return 2u;
    if (style == housePlaster || style == housePlasterColumn)
        return 3u;
    return 0u;
}

bool concreteImpactStyle(uint style) {
    return style == houseStone || style == houseBrick
        || style == houseGrave || style == houseMasonry
        || style == housePlaster || style == housePlasterColumn
        || style == houseRoof;
}

bool woodImpactStyle(uint style) {
    return style == houseSiding || style == houseBattens
        || style == houseTrim || style == houseTimber
        || style == houseLog || style == houseFloor
        || style == houseStair;
}

void emitSurfaceImpact(device GameState &game, device RangeAudio &audio,
    uint material) {
    if (!houseMaterial(material)
        || game.effects.x < game.surfaceImpactReadyAt
        || audio.surfaceImpact[0] != 0u || audio.surfaceImpact[1] != 0u)
        return;
    uint style = material - houseMaterialBase;
    if (!woodImpactStyle(style) && !concreteImpactStyle(style)) return;
    audio.surfaceImpact[concreteImpactStyle(style) ? 1u : 0u] = 1u;
    // A shotgun may strike several cells in one tick. Its first solid hit
    // supplies the single close impact instead of a stack of pellet sounds.
    game.surfaceImpactReadyAt = game.effects.x + 0.12f;
}

void resetLandingPlayed(device GameState &game, uint slot) {
    if (slot < 32u) game.debrisLandingMask.x &= ~(1u << slot);
    else game.debrisLandingMask.y &= ~(1u << (slot - 32u));
}

void emitDebrisSound(device GameState &game, device RangeAudio &audio,
    uint style, uint size) {
    uint previous = audio.debrisSelectedChannel;
    if (previous == 0u && game.effects.x < game.debrisSoundReadyAt) return;
    size = min(size, 2u);
    if (previous != 0u) {
        if (size <= (previous - 1u) % 3u) return;
        audio.debrisImpact[previous - 1u] = 0u;
    }
    uint channel = debrisMaterialKind(style) * 3u + size;
    audio.debrisImpact[channel] = 1u;
    audio.debrisSelectedChannel = channel + 1u;
    // The clip already contains its break and landing. Let it finish before
    // another piece of the same blast can start a new debris clip.
    game.debrisSoundReadyAt = game.effects.x + (size == 2u ? 2.0f : 1.0f);
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
    // Large mausoleum faces use finer cells for compact fracture pieces.
    float pitch = uint(part.lower.w) == houseGrave
        && max(max(span.x, span.y), span.z) > 3.0f ? 0.52f : 1.25f;
    return uint2(clamp(ceil(float2(span[axes.x], span[axes.y]) / pitch),
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

// Split a removed cell into four small pieces. Stone and plaster make cubes;
// wood makes narrow splinters. Keep the source part for material sampling so
// each piece carries the texture of the surface it broke from.
void launchBuildingFragment(device GameState &game, uint index, uint2 cell,
    uint shard, HouseTurn turn, float3 velocity) {
    device const HousePart &source = game.house.parts[index];
    HousePart piece = source;
    uint style = uint(source.lower.w);
    bool wood = woodImpactStyle(style);
    bool concrete = concreteImpactStyle(style) && style != houseRoof;
    float seed = houseHash(float(index * 31u + cell.x * 11u
        + cell.y * 7u + shard * 43u));
    if (style == houseLog) {
        float3 axis = source.windows.xyz;
        float segment = min(0.18f + 0.06f * seed,
            0.5f * source.windows.w);
        piece.windows.w = segment;
        piece.rows.xyz = source.rows.xyz + axis
            * ((float(shard) - 1.5f) * 0.5f * source.windows.w);
        piece.rows.w = min(source.rows.w, 0.045f + 0.025f * seed);
        float3 a = piece.rows.xyz - axis * segment;
        float3 b = piece.rows.xyz + axis * segment;
        piece.lower.xyz = max(source.lower.xyz,
            min(a, b) - float3(piece.rows.w));
        piece.upper.xyz = min(source.upper.xyz,
            max(a, b) + float3(piece.rows.w));
    } else {
        uint2 axes = buildingCellAxes(source);
        uint2 grid = buildingCellGrid(source);
        float3 span = source.upper.xyz - source.lower.xyz;
        uint2 sub = uint2(shard & 1u, shard >> 1u);
        float2 begin = float2(cell) + 0.5f * float2(sub);
        float2 end = begin + 0.5f;
        piece.lower[axes.x] = source.lower[axes.x]
            + begin.x * span[axes.x] / float(grid.x);
        piece.upper[axes.x] = source.lower[axes.x]
            + end.x * span[axes.x] / float(grid.x);
        piece.lower[axes.y] = source.lower[axes.y]
            + begin.y * span[axes.y] / float(grid.y);
        piece.upper[axes.y] = source.lower[axes.y]
            + end.y * span[axes.y] / float(grid.y);
        float3 available = piece.upper.xyz - piece.lower.xyz;
        float3 centre = 0.5f * (piece.lower.xyz + piece.upper.xyz);
        if (concrete) {
            float side = min(0.42f + 0.24f * seed,
                min(available[axes.x], available[axes.y]));
            piece.lower.xyz = centre - 0.5f * side;
            piece.upper.xyz = centre + 0.5f * side;
            piece.upper.w = 0.0f; // fracture faces are square, not roof cuts
            if (style == housePlasterColumn) piece.lower.w = housePlaster;
        } else if (wood) {
            uint axis = available.x >= available.z ? 0u : 2u;
            if (available.y > max(available.x, available.z) * 1.6f)
                axis = 1u;
            float3 halfSize = min(0.5f * available,
                float3(0.025f + 0.015f * seed));
            halfSize[axis] = min(0.5f * available[axis],
                0.16f + 0.07f * seed);
            piece.lower.xyz = centre - halfSize;
            piece.upper.xyz = centre + halfSize;
            piece.upper.w = 0.0f;
        }
    }
    uint slot = game.buildingFragmentNext++ % buildingFragmentCount;
    game.buildingFragments[slot] = piece;
    game.buildingFragmentSource[slot] = index;
    game.buildingFragmentGone[slot] = 0ul;
    game.buildingFragmentActive = 1u;
    float3 centre = houseTurnPointOut(turn,
        0.5f * (piece.lower.xyz + piece.upper.xyz));
    float angle = atan2(turn.sine, turn.cosine);
    float4 orientation = float4(0.0f, -sin(0.5f * angle), 0.0f,
        cos(0.5f * angle));
    if (wood) {
        float3 tiltAxis = normalize(float3(
            houseHash(seed * 31.0f + 1.0f) - 0.5f,
            houseHash(seed * 37.0f + 2.0f) - 0.5f,
            houseHash(seed * 43.0f + 3.0f) - 0.5f));
        float tilt = 0.5f * (houseHash(seed * 47.0f + 4.0f) - 0.5f);
        orientation = pixeltje_physics::multiplyRotation(orientation,
            float4(tiltAxis * sin(0.5f * tilt), cos(0.5f * tilt)));
    }
    float3 halfExtent = 0.5f * (piece.upper.xyz - piece.lower.xyz);
    float inverseMass = 1.0f / max(0.2f,
        2.0f * halfExtent.x * 2.0f * halfExtent.y
            * 2.0f * halfExtent.z);
    game.physicsWorld.bodies[slot] = pixeltje_physics::makeRigidBody(
        centre, halfExtent, orientation, velocity, inverseMass, 0.06f, 0.75f);
    game.physicsWorld.bodies[slot].angularFriction.xyz = float3(
        1.8f + 2.2f * seed, 1.0f - 2.0f * seed, -2.5f + 2.0f * seed);
    game.physicsWorld.sleepSeconds[slot] = 0.0f;
    resetLandingPlayed(game, slot);
}

void launchBuildingCellFragments(device GameState &game, uint index,
    uint2 cell, HouseTurn turn, float3 velocity) {
    for (uint shard = 0u; shard < buildingShardsPerCell; ++shard) {
        float seed = houseHash(float(index * 53u + cell.x * 19u
            + cell.y * 29u + shard * 17u));
        float3 scatter = float3(float(shard & 1u) - 0.5f,
            0.15f * seed, float(shard >> 1u) - 0.5f);
        launchBuildingFragment(game, index, cell, shard, turn,
            velocity + 1.5f * scatter);
    }
}

// A shotgun pellets the mausoleum's broad stone facade without punching a
// wall-sized opening. Detached cubes and a persistent scar record the hit.
void spallMausoleumFacade(device GameState &game, BuildingImpact impact) {
    uint index = impact.part;
    if (index >= min(game.house.counts.x, houseCapacity)) return;
    device const HousePart &part = game.house.parts[index];
    if (uint(part.lower.w) != houseGrave) return;
    HouseTurn turn = housePartTurn(game.house, index);
    float3 local = houseTurnPointIn(turn, impact.pointDamage.xyz);
    uint2 cell = buildingCell(part, local);
    game.mausoleumSpalls[game.mausoleumSpallNext++ % mausoleumSpallCount]
        = float4(local, float(index + 1u));
    launchBuildingCellFragments(game, index, cell, turn,
        impact.normal.xyz * 3.0f + float3(0.0f, 0.15f, 0.0f));
    uint owner = buildingPartOwner(game.house, index);
    if (owner < buildingCount) game.buildingDamage[owner] += 0.10f;
}

__attribute__((noinline))
SurfaceMaterial shadeMausoleumSpalls(SurfaceMaterial material,
    device const GameState &game, uint index, float3 p, float3 normal,
    float blur) {
    for (uint i = 0u; i < mausoleumSpallCount; ++i) {
        float4 chip = game.mausoleumSpalls[i];
        if (uint(chip.w) != index + 1u) continue;
        float3 offset = p - chip.xyz;
        if (abs(dot(offset, normal)) > 0.08f) continue;
        float3 tangent = abs(normal.y) < 0.85f
            ? normalize(cross(float3(0.0f, 1.0f, 0.0f), normal))
            : float3(1.0f, 0.0f, 0.0f);
        float3 across = cross(normal, tangent);
        float2 q = float2(dot(offset, tangent), dot(offset, across));
        float r = length(q);
        if (r >= 0.27f) continue;
        float angle = atan2(q.y, q.x);
        float jagged = 0.018f * sin(7.0f * angle + float(i) * 2.1f);
        float ring = 1.0f - smoothstep(0.006f, 0.015f + blur,
            abs(r - 0.13f - jagged));
        float centre = 1.0f - smoothstep(0.025f, 0.085f, r);
        material.albedo *= 1.0f - 0.46f * ring - 0.38f * centre;
    }
    return material;
}

bool buildingCollapseSurface(uint style) {
    return style == houseSiding || style == houseBattens
        || style == houseRoof || style == houseCorrugated
        || style == houseStone || style == houseBrick
        || style == housePlaster;
}

void buildingMaybeCollapse(device GameState &game, device RangeAudio &audio,
    uint owner) {
    if (owner == 0u || owner >= buildingCount
        || game.buildingCollapseTime[owner] >= 0.0f
        || game.buildingDamage[owner] < buildingCollapseThreshold(owner))
        return;
    game.buildingCollapseTime[owner] = game.effects.x;
    // Remove the largest structural surfaces, then keep a bounded selection
    // of their small cells as physical rubble instead of dropping whole roofs.
    thread float area[4];
    thread uint selected[4];
    for (uint k = 0u; k < 4u; ++k) {
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
            if (game.buildingGone[index] == ~0ul) continue;
            float3 size = part.upper.xyz - part.lower.xyz;
            if (any(size <= 0.0f)) continue;
            float score = max(max(size.x * size.y, size.y * size.z),
                size.x * size.z);
            uint smallest = 0u;
            for (uint k = 1u; k < 4u; ++k)
                if (area[k] < area[smallest]) smallest = k;
            if (score > area[smallest]) {
                area[smallest] = score;
                selected[smallest] = index;
            }
        }
    }
    thread bool sounded[4] = {false, false, false, false};
    for (uint k = 0u; k < 4u; ++k) {
        if (area[k] <= 0.0f) continue;
        uint index = selected[k];
        device const HousePart &part = game.house.parts[index];
        HouseTurn turn = housePartTurn(game.house, index);
        uint2 grid = buildingCellGrid(part);
        uint2 axes = buildingCellAxes(part);
        float3 span = part.upper.xyz - part.lower.xyz;
        uint cellCount = grid.x * grid.y;
        uint first = uint(houseHash(float(index * 37u + owner * 13u))
            * float(cellCount)) % cellCount;
        uint launched = 0u;
        for (uint offset = 0u; offset < cellCount && launched < 2u;
                ++offset) {
            uint cellID = (first + offset) % cellCount;
            uint2 cell = uint2(cellID % grid.x, cellID / grid.x);
            ulong bit = 1ul << (cell.y * 8u + cell.x);
            if ((game.buildingGone[index] & bit) != 0ul) continue;
            float3 midpoint = 0.5f * (part.lower.xyz + part.upper.xyz);
            midpoint[axes.x] = part.lower[axes.x]
                + (float(cell.x) + 0.5f) * span[axes.x] / float(grid.x);
            midpoint[axes.y] = part.lower[axes.y]
                + (float(cell.y) + 0.5f) * span[axes.y] / float(grid.y);
            bool outside = false;
            for (uint plane = 0u; plane < uint(part.upper.w); ++plane)
                outside |= dot(part.planes[plane].xyz, midpoint)
                    > part.planes[plane].w;
            if (outside) continue;
            float seed = houseHash(float(index * 19u + cellID * 23u));
            float3 velocity = float3(2.4f * (seed - 0.5f), 0.15f,
                2.4f * (houseHash(float(index * 23u + cellID)) - 0.5f));
            launchBuildingCellFragments(game, index, cell, turn, velocity);
            ++launched;
        }
        uint material = debrisMaterialKind(uint(part.lower.w));
        if (!sounded[material]) {
            emitDebrisSound(game, audio, uint(part.lower.w), 2u);
            sounded[material] = true;
        }
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
void damageBuildingHit(device GameState &game, device RangeAudio &audio,
    BuildingImpact impact) {
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
    float3 velocity = impact.normal.xyz * 2.8f
        + float3(0.0f, 0.15f, 0.0f);
    launchBuildingCellFragments(game, index, cell, turn, velocity);
    buildingMaybeCollapse(game, audio, owner);
}

// Blast work stays out of the per-frame player and shot traces. Group and
// part bounds prune the search, and damage per building is capped per blast
// so a single explosion cannot drop a whole house through overlapping trim.
__attribute__((noinline))
void damageBuildingsBlast(device GameState &game, device RangeAudio &audio,
    float3 blast) {
    thread float added[buildingCount];
    for (uint owner = 0u; owner < buildingCount; ++owner) added[owner] = 0.0f;
    thread float nearestDistance[buildingBlastCellCount];
    thread uint nearestPart[buildingBlastCellCount];
    thread uint2 nearestCell[buildingBlastCellCount];
    thread bool sounded[4] = {false, false, false, false};
    for (uint k = 0u; k < buildingBlastCellCount; ++k)
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
                    for (uint k = 1u; k < buildingBlastCellCount; ++k)
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
    for (uint k = 0u; k < buildingBlastCellCount; ++k) {
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
        float3 velocity = normalize(away + float3(0.0f, 0.15f, 0.0f))
            * (2.4f + 1.8f * seed);
        launchBuildingCellFragments(game, index, cell, turn, velocity);
        uint style = uint(part.lower.w);
        uint material = debrisMaterialKind(style);
        if (!sounded[material]) {
            emitDebrisSound(game, audio, style, 2u);
            sounded[material] = true;
        }
    }
    for (uint owner = 1u; owner < buildingCount; ++owner)
        buildingMaybeCollapse(game, audio, owner);
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
    game.debrisSoundReadyAt = -100.0f;
    game.surfaceImpactReadyAt = -100.0f;
    game.landingSoundReadyAt = -100.0f;
    game.debrisLandingMask = uint2(0u);
    game.buildingImpactCountNow = 0u;
    game.buildingLastBlast = -100.0f;
    game.mausoleumSpallNext = 0u;
    for (uint i = 0u; i < mausoleumSpallCount; ++i)
        game.mausoleumSpalls[i] = float4(0.0f);
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

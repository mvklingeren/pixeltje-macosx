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

// The two broadest directions give an 8x8 damage map without storing 64
// separate parts. Roofs and floors use their plan, including pitched roofs.
uint2 buildingCellAxes(device const HousePart &part) {
    uint style = uint(part.lower.w);
    if (style == houseRoof || style == houseCorrugated
        || style == houseFloor) return uint2(0u, 2u);
    float3 span = part.upper.xyz - part.lower.xyz;
    if (span.x <= span.y && span.x <= span.z) return uint2(1u, 2u);
    if (span.y <= span.z) return uint2(0u, 2u);
    return uint2(0u, 1u);
}

uint2 buildingCell(device const HousePart &part, float3 p) {
    uint2 axes = buildingCellAxes(part);
    float3 span = max(part.upper.xyz - part.lower.xyz, float3(0.001f));
    float2 uv = (float2(p[axes.x], p[axes.y])
        - float2(part.lower[axes.x], part.lower[axes.y]))
        / float2(span[axes.x], span[axes.y]);
    return uint2(clamp(floor(uv * 8.0f), float2(0.0f), float2(7.0f)));
}

bool buildingCellGone(device const GameState &game, uint index,
    device const HousePart &part, float3 p) {
    ulong mask = game.buildingGone[index];
    if (mask == 0ul) return false;
    uint2 cell = buildingCell(part, p);
    return (mask & (1ul << (cell.y * 8u + cell.x))) != 0ul;
}

float buildingCollapseAge(device const GameState &game, uint owner) {
    return owner > 0u && owner < buildingCount
        && game.buildingCollapseTime[owner] >= 0.0f
        ? game.effects.x - game.buildingCollapseTime[owner] : -1.0f;
}

float buildingCollapseDrop(device const GameState &game, uint owner) {
    float age = buildingCollapseAge(game, owner);
    return age > 0.0f ? min(7.0f * age * age, 16.0f) : 0.0f;
}

float buildingCollapseThreshold(uint owner) {
    if (owner == 1u) return 60.0f;
    if (owner == 2u || owner == 3u || owner >= 13u) return 28.0f;
    if (owner == 6u || (owner >= 7u && owner <= 9u)) return 38.0f;
    return 30.0f; // original and street-copy barns and open sheds
}

void launchBuildingFragment(device GameState &game, float3 point,
    float3 blast, uint style, float size, float seed) {
    uint slot = game.buildingFragmentNext++ % buildingFragmentCount;
    float r = clamp(size, 0.09f, 0.8f);
    float3 radius = float3(r, 0.55f * r, 0.75f * r);
    game.buildingFragments[slot] = houseBox(point - radius,
        point + radius, style);
    float3 away = point - blast;
    away = length(away) > 0.01f ? normalize(away)
        : float3(0.0f, 0.6f, 0.8f);
    game.buildingFragmentMotion[slot] = float4(
        away * (2.0f + 3.0f * seed) + float3(0.0f, 2.0f, 0.0f), 3.2f);
    game.buildingFragmentActive = 1u;
}

void buildingMaybeCollapse(device GameState &game, uint owner) {
    if (owner == 0u || owner >= buildingCount
        || game.buildingCollapseTime[owner] >= 0.0f
        || game.buildingDamage[owner] < buildingCollapseThreshold(owner))
        return;
    game.buildingCollapseTime[owner] = game.effects.x;
    // Make a few large pieces only at the transition. The intact building
    // remains one set of broad surfaces until this point.
    uint launched = 0u;
    for (uint g = 0u; g < min(game.house.counts.y, houseGroupCapacity)
            && launched < 8u; ++g) {
        if (game.house.groupBuilding[g] != owner) continue;
        HouseGroup group = game.house.groups[g];
        uint first = uint(group.lower.w);
        uint end = min(uint(group.upper.w), houseCapacity);
        if (end <= first) continue;
        uint stride = max((end - first) / (8u - launched), 1u);
        HouseTurn turn = houseGroupTurn(group);
        for (uint index = first; index < end && launched < 8u;
                index += stride) {
            device const HousePart &part = game.house.parts[index];
            uint style = uint(part.lower.w);
            if (!buildingBreakable(style)
                || any(part.upper.xyz <= part.lower.xyz)) continue;
            float3 local = 0.5f * (part.lower.xyz + part.upper.xyz);
            float3 point = houseTurnPointOut(turn, local);
            float seed = houseHash(float(index * 37u + owner * 13u));
            launchBuildingFragment(game, point,
                houseTurnPointOut(turn, 0.5f *
                    (group.lower.xyz + group.upper.xyz)), style,
                0.45f + 0.35f * seed, seed);
            ++launched;
        }
    }
}

bool markBuildingCell(device GameState &game, uint index, uint2 cell) {
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
    if (owner == 0u || buildingCollapseAge(game, owner) >= 0.0f) return;
    device const HousePart &part = game.house.parts[index];
    uint style = uint(part.lower.w);
    if (!buildingBreakable(style)) return;
    HouseTurn turn = housePartTurn(game.house, index);
    float3 local = houseTurnPointIn(turn, impact.pointDamage.xyz);
    if (!markBuildingCell(game, index, buildingCell(part, local))) return;
    game.buildingDamage[owner] += impact.pointDamage.w;
    float seed = houseHash(float(index) * 11.0f + game.effects.x * 3.0f);
    launchBuildingFragment(game, impact.pointDamage.xyz,
        impact.pointDamage.xyz - float3(0.0f, 0.3f, 0.0f), style,
        0.13f + 0.13f * seed, seed);
    buildingMaybeCollapse(game, owner);
}

// Blast work stays out of the per-frame player and shot traces. Group and
// part bounds prune the search, and damage per building is capped per blast
// so a single explosion cannot drop a whole house through overlapping trim.
__attribute__((noinline))
void damageBuildingsBlast(device GameState &game, float3 blast) {
    thread float added[buildingCount];
    for (uint owner = 0u; owner < buildingCount; ++owner) added[owner] = 0.0f;
    uint launched = 0u;
    for (uint g = 0u; g < min(game.house.counts.y, houseGroupCapacity); ++g) {
        uint owner = game.house.groupBuilding[g];
        if (owner == 0u || owner >= buildingCount
            || buildingCollapseAge(game, owner) >= 0.0f) continue;
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
            uint2 axes = buildingCellAxes(part);
            float3 span = part.upper.xyz - part.lower.xyz;
            for (int y = -1; y <= 1; ++y)
                for (int x = -1; x <= 1; ++x) {
                    int2 next = int2(cell) + int2(x, y);
                    if (any(next < int2(0)) || any(next > int2(7))) continue;
                    float3 sample = nearest;
                    sample[axes.x] = part.lower[axes.x]
                        + (float(next.x) + 0.5f) * span[axes.x] / 8.0f;
                    sample[axes.y] = part.lower[axes.y]
                        + (float(next.y) + 0.5f) * span[axes.y] / 8.0f;
                    if (distance(sample, localBlast) > blastRadius) continue;
                    if (!markBuildingCell(game, index, uint2(next))) continue;
                    if (added[owner] < 10.0f) {
                        game.buildingDamage[owner] += 1.0f;
                        added[owner] += 1.0f;
                    }
                    if (launched < buildingFragmentCount / 2u) {
                        float seed = houseHash(float(index * 29u
                            + uint(next.x) * 7u + uint(next.y)));
                        launchBuildingFragment(game,
                            houseTurnPointOut(turn, sample), blast, style,
                            0.16f + 0.18f * seed, seed);
                        ++launched;
                    }
                }
        }
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
    for (uint i = 0u; i < buildingFragmentCount; ++i)
        game.buildingFragmentMotion[i] = float4(0.0f);
    game.buildingFragmentNext = 0u;
    game.buildingFragmentActive = 0u;
    game.buildingImpactCountNow = 0u;
    game.buildingLastBlast = -100.0f;
}

// Fragments are temporary: inactive slots are never traced. The settled
// masonry blocks keep their separate, persistent collision behaviour.
__attribute__((noinline))
void advanceBuildingFragments(device GameState &game, float dt) {
    game.buildingFragmentActive = 0u;
    for (uint i = 0u; i < buildingFragmentCount; ++i) {
        float4 motion = game.buildingFragmentMotion[i];
        if (motion.w <= 0.0f) continue;
        device HousePart &part = game.buildingFragments[i];
        float3 radius = 0.5f * (part.upper.xyz - part.lower.xyz);
        pixeltje_physics::Body body = {
            0.5f * (part.upper.xyz + part.lower.xyz), motion.xyz};
        body = pixeltje_physics::integrate(body,
            float3(0.0f, -9.8f, 0.0f), 0.6f, dt);
        float floorY = buildingsGround(body.position.xz,
            moonHeight(body.position.xz, moonTraceDetail));
        pixeltje_physics::Contact floor = pixeltje_physics::spherePlane(
            body.position, radius.y, float3(0.0f, floorY, 0.0f),
            float3(0.0f, 1.0f, 0.0f));
        body = pixeltje_physics::resolve(body, floor, 0.25f, 0.55f);
        float3 delta = body.position
            - 0.5f * (part.upper.xyz + part.lower.xyz);
        part.lower.xyz += delta;
        part.upper.xyz += delta;
        motion = float4(body.velocity, motion.w - dt);
        game.buildingFragmentMotion[i] = motion;
        if (motion.w > 0.0f) game.buildingFragmentActive = 1u;
    }
}

void traceBuildingFragments(thread SceneHit &hit, float3 origin,
    float3 direction, device const GameState &game) {
    if (game.buildingFragmentActive == 0u) return;
    for (uint i = 0u; i < buildingFragmentCount; ++i) {
        if (game.buildingFragmentMotion[i].w <= 0.0f) continue;
        device const HousePart &part = game.buildingFragments[i];
        float3 normal;
        float t = houseHitPart(part, origin, direction, hit.distance, normal);
        if (t > 0.0f) hit = {t, normal, origin + direction * t,
            houseMaterialBase + uint(part.lower.w), -1, houseCapacity + i};
    }
}

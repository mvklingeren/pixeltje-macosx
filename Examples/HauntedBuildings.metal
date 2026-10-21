// The haunted buildings for HauntedHouseProgram.metal: every building site
// generated, traced, shadowed, walked and stood on through one place.
//
// Each building lives in its own file and builds itself with the parts of
// HauntedBuildingKit.metal into its own site; site 0 is the Victorian house
// of HauntedHouse.metal. The program includes the kit first, then each
// building, then this file, and calls only the functions here for what
// every building shares: the scene traces, the Earth's shadows, the glass,
// footing, obstacles and the levelled ground. A building's own lights,
// rooms and haunting stay in its file.
//
// The traces loop over groups, never over buildings, so a new building adds
// parts rather than code to the kernels that trace the scene. Footing and
// obstacles run inside the spider and drone kernels, where every added loop
// costs cold compile time; each building answers them in straight-line code
// or with a single loop over its own table.

// ---------------------------------------------------------------- building

// Runs once in the initialize pass.
void buildBuildings(device HouseModel &house) {
    house.counts = uint4(0u);
    beginBuildingSite(house);
    buildHouse(house);
}

// ----------------------------------------------------------------- tracing

// Adds the nearest building surface along the ray, among groups
// [groups.x, groups.y), to hit.
void traceBuildingGroups(thread SceneHit &hit, float3 origin,
    float3 direction, device const GameState &game, uint2 groups) {
    device const HouseModel &house = game.house;
    groups.y = min(groups.y, min(house.counts.y, houseGroupCapacity));
    HouseWind wind = houseWind(game);
    bool found = false;
    for (uint g = groups.x; g < groups.y; ++g) {
        HouseGroup group = house.groups[g];
        if (!houseRayEntersBox(origin, direction, group.lower.xyz,
                group.upper.xyz, hit.distance)) {
            g = max(g, group.last.x);
            continue;
        }
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            float3 normal;
            float t = houseHitPart(house.parts[i], origin, direction,
                hit.distance, normal);
            if (t < 0.0f) continue;
            float3 p = origin + direction * t;
            uint style = uint(house.parts[i].lower.w);
            if (((style >= houseIron && style <= houseFrieze)
                    || style == houseCandle)
                && houseCutoutOpen(style, house.parts[i], p)) continue;
            // Rays pass through the clear glass of the ground floor.
            if (style == houseSiding && houseSeeThrough(house.parts[i])
                && houseWindow(house.parts[i], i, p, normal, 0.002f,
                    wind).glass
                    > 0.5f) continue;
            hit = {t, normal, p, houseMaterialBase + style, -1, i};
            found = true;
        }
    }
    // The nearest wall face becomes the board under it.
    if (found && (hit.material == houseMaterialBase + houseSiding
            || hit.material == houseMaterialBase + houseBattens))
        houseCladdingRelief(hit, direction, game);
}

// Adds every building's nearest surface along the ray to hit.
void traceBuildings(thread SceneHit &hit, float3 origin, float3 direction,
    device const GameState &game) {
    traceBuildingGroups(hit, origin, direction, game,
        uint2(0u, game.house.counts.y));
}

// True when a solid part lies between origin and the light. Cut-out panels
// and lanterns cast no shadow.
bool buildingsBlockLight(float3 origin, float3 direction,
    float lightDistance, device const GameState &game) {
    device const HouseModel &house = game.house;
    uint groups = min(house.counts.y, houseGroupCapacity);
    for (uint g = 0u; g < groups; ++g) {
        HouseGroup group = house.groups[g];
        if (!houseRayEntersBox(origin, direction, group.lower.xyz,
                group.upper.xyz, lightDistance)) {
            g = max(g, group.last.x);
            continue;
        }
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            uint style = uint(house.parts[i].lower.w);
            if ((style >= houseIron && style <= houseFrieze)
                || style == houseLantern || style == houseCandle) continue;
            float3 normal;
            if (houseHitPart(house.parts[i], origin, direction,
                    lightDistance, normal) > 0.0f) return true;
        }
    }
    return false;
}

// The nearest see-through pane the ray crosses before limit: its distance,
// or -1. normal and pane describe it.
float buildingsGlassCrossing(float3 origin, float3 direction, float limit,
    device const GameState &game, thread float3 &normal,
    thread HouseWindow &pane) {
    device const HouseModel &house = game.house;
    float nearest = -1.0f;
    uint groups = min(house.counts.y, houseGroupCapacity);
    HouseWind wind = houseWind(game);
    for (uint g = 0u; g < groups; ++g) {
        HouseGroup group = house.groups[g];
        if (!houseRayEntersBox(origin, direction, group.lower.xyz,
                group.upper.xyz, limit)) {
            g = max(g, group.last.x);
            continue;
        }
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            if (uint(house.parts[i].lower.w) != houseSiding
                || !houseSeeThrough(house.parts[i])) continue;
            float3 faceNormal;
            float t = housePartHit(house.parts[i], origin, direction, limit,
                faceNormal);
            if (t < 0.0f) continue;
            HouseWindow w = houseWindow(house.parts[i], i,
                origin + direction * t, faceNormal, 0.002f, wind);
            if (w.glass <= 0.5f) continue;
            nearest = t;
            limit = t;
            normal = faceNormal;
            pane = w;
        }
    }
    return nearest;
}

// ------------------------------------------------------------------ ground

// Weight of the natural terrain at p: 0 on a building's levelled ground,
// rising to 1 away from it.
float buildingsGroundBlend(float2 p) {
    return houseLotBlend(p);
}

// The terrain height h at p, levelled under the buildings.
float buildingsGround(float2 p, float h) {
    return mix(houseOrigin.y, h, houseLotBlend(p));
}

// The floor, deck, step or stair under p, or ground where there is none.
float buildingsStand(float2 p, float ground) {
    return houseStand(p, ground);
}

// True where a wall, post, fence, grave or piece of furniture keeps the
// walker out.
bool buildingsBlocked(float2 p) {
    return houseBlocked(p);
}

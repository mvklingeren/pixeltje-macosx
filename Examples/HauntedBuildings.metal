// The haunted buildings for HauntedHouseProgram.metal: every building site
// generated, traced, shadowed, walked and stood on through one place.
//
// Each building lives in its own file and builds itself with the parts of
// HauntedBuildingKit.metal into its own site; site 0 is the Victorian house
// of HauntedHouse.metal. HauntedStreet.metal lays the road and drives
// between them, copies the cottage, the barn and the shed along it and
// puts up its lamps. The program includes the kit first, then each
// building and the street, then this file, and calls only the functions
// here for what every building shares: the scene traces, the Earth's
// shadows, the glass, footing, obstacles, the levelled ground, the paving,
// the lights outside and the doors a visitor can knock on. A building's own
// lights, rooms and haunting stay in its file.
//
// The traces loop over groups, never over buildings, so a new building adds
// parts rather than code to the kernels that trace the scene. Each turns
// the ray into a group's frame before it meets the group, so a building
// can stand turned from the road; a hit is turned back out to the world. Footing and
// obstacles run inside the spider and drone kernels, where every added loop
// costs cold compile time; each building answers them in straight-line code
// or with a single loop over its own table.

// ---------------------------------------------------------------- building

// Runs once in the initialize pass: the house with its graveyards and
// their mausoleums as site 0, the shed yard behind it and the cottage, then
// the street's copies of them and its lamps.
void buildBuildings(device HouseModel &house) {
    house.counts = uint4(0u);
    beginBuildingSite(house);
    buildHouse(house);
    buildMausoleums(house);
    buildShedYard(house);
    buildCottage(house);
    buildStreet(house);
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
    HouseTurn foundTurn = {0.0f, 1.0f, float2(0.0f)};
    for (uint g = groups.x; g < groups.y; ++g) {
        HouseGroup group = house.groups[g];
        HouseTurn turn = houseGroupTurn(group);
        float3 o = houseTurnPointIn(turn, origin);
        float3 d = houseTurnDirectionIn(turn, direction);
        if (!houseRayEntersBox(o, d, group.lower.xyz, group.upper.xyz,
                hit.distance)) {
            g = max(g, group.last.x);
            continue;
        }
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            float3 normal;
            float t = houseHitPart(house.parts[i], o, d, hit.distance,
                normal);
            if (t < 0.0f) continue;
            float3 p = o + d * t;
            uint style = uint(house.parts[i].lower.w);
            if (houseCutoutStyle(style)
                && houseCutoutOpen(style, house.parts[i], p)) continue;
            // Rays pass through the clear glass of the house's rooms.
            if ((style == houseSiding || style == houseBattens)
                && houseSeeThrough(house.parts[i])
                && houseWindow(house.parts[i], i, p, normal, 0.002f,
                    wind).glass
                    > 0.5f) continue;
            hit = {t, normal, p, houseMaterialBase + style, -1, i};
            found = true;
            foundTurn = turn;
        }
    }
    if (!found) return;
    // The nearest wall face becomes the board under it, in its group's
    // frame, before the hit turns back out.
    if (hit.material == houseMaterialBase + houseSiding
            || hit.material == houseMaterialBase + houseBattens)
        houseCladdingRelief(hit, houseTurnDirectionIn(foundTurn, direction),
            game);
    hit.position = houseTurnPointOut(foundTurn, hit.position);
    hit.normal = houseTurnDirectionOut(foundTurn, hit.normal);
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
        HouseTurn turn = houseGroupTurn(group);
        float3 o = houseTurnPointIn(turn, origin);
        float3 d = houseTurnDirectionIn(turn, direction);
        if (!houseRayEntersBox(o, d, group.lower.xyz, group.upper.xyz,
                lightDistance)) {
            g = max(g, group.last.x);
            continue;
        }
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            uint style = uint(house.parts[i].lower.w);
            if (houseCutoutStyle(style) || style == houseLantern) continue;
            float3 normal;
            if (houseHitPart(house.parts[i], o, d, lightDistance, normal)
                    > 0.0f) return true;
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
        HouseTurn turn = houseGroupTurn(group);
        float3 o = houseTurnPointIn(turn, origin);
        float3 d = houseTurnDirectionIn(turn, direction);
        if (!houseRayEntersBox(o, d, group.lower.xyz, group.upper.xyz,
                limit)) {
            g = max(g, group.last.x);
            continue;
        }
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            uint style = uint(house.parts[i].lower.w);
            if ((style != houseSiding && style != houseBattens)
                || !houseSeeThrough(house.parts[i])) continue;
            float3 faceNormal;
            float t = housePartHit(house.parts[i], o, d, limit, faceNormal);
            if (t < 0.0f) continue;
            HouseWindow w = houseWindow(house.parts[i], i, o + d * t,
                faceNormal, 0.002f, wind);
            if (w.glass <= 0.5f) continue;
            nearest = t;
            limit = t;
            normal = houseTurnDirectionOut(turn, faceNormal);
            pane = w;
        }
    }
    return nearest;
}

// ------------------------------------------------------------------ ground

// Weight of the natural terrain at p: 0 on a building's levelled ground and
// under the street, rising to 1 away from them.
float buildingsGroundBlend(float2 p) {
    return houseLotBlend(p) * shedYardBlend(p) * cottageGroundBlend(p)
        * streetGroundBlend(p);
}

// The terrain height h at p, graded under the street and levelled under the
// buildings.
float buildingsGround(float2 p, float h) {
    h = streetGround(p, h);
    h = mix(houseOrigin.y, h, houseLotBlend(p));
    h = mix(shedYardOrigin.y, h, shedYardBlend(p));
    return mix(cottageOrigin.y, h, cottageGroundBlend(p));
}

// The flagstone paths: the house's, and the aisles of its graveyards.
float3 buildingsPath(float2 p, float blur) {
    return housePath(p, blur);
}

// The asphalt of the road and the drives under p: its colour, and how much
// of the ground it covers.
float4 buildingsPaving(float2 p, float blur) {
    return streetPaving(p, blur);
}

// 0 to 1: how much of p is paved. The plain's fine relief stays off it.
float buildingsPaved(float2 p) {
    return streetPaved(p);
}

// The lanterns outside: the house's, then the porch lanterns of the cottage
// and its copies. They go out while the house is haunted.
constant uint buildingsOutdoorLightCount = houseOutdoorLightCount
    + streetCottageCount;

PointLight buildingsOutdoorLight(uint index, device const GameState &game) {
    if (index < houseOutdoorLightCount)
        return houseHauntedOutdoorLight(index, game);
    PointLight light = streetCottageLantern(index - houseOutdoorLightCount,
        game.effects.x);
    light.power *= houseHaunting(game).dim;
    return light;
}

// The street lamps, too many to light every point: only those from x up to
// y can reach p, and each reaches buildingsStreetLampReach. dim is the
// haunting's.
constant float buildingsStreetLampReach = streetLampReach;

uint2 buildingsStreetLampsNear(float3 p) {
    return streetLampsNear(p);
}

PointLight buildingsStreetLamp(uint index, device const GameState &game,
    float dim) {
    return streetLampLight(index, game, dim);
}

// The floor, deck, step or stair under p, or ground where there is none.
float buildingsStand(float2 p, float ground) {
    return houseStand(p, ground);
}

// The player alone climbs to the haunted house's upper floors. With their
// feet at foot, these stand in for buildingsStand and buildingsBlocked over
// the house's body, and give the height of what is over their head.
float buildingsStandFrom(float2 p, float ground, float foot) {
    return houseStandFrom(p, ground, foot);
}

float buildingsCeilingOver(float2 p, float foot) {
    return houseCeilingOver(p, foot);
}

bool buildingsBlocked(float2 p);

bool buildingsBlockedFrom(float2 p, float foot) {
    if (!houseBodyHolds(p)) return buildingsBlocked(p);
    // The ground floor's walls and furniture stand in the house's table.
    if ((foot - houseOrigin.y) / houseScale < houseCeilingY
        && buildingsBlocked(p)) return true;
    return houseBlockedAbove(p, foot);
}

// True where a wall, post, fence, grave or piece of furniture keeps the
// walker out, padded by the walker's reach. Each site keeps a table of
// footprints in its own frame; the site under p picks the table, so one
// loop serves them all. Off every site, the street's lamp posts and its
// copies of the buildings.
bool buildingsBlocked(float2 p) {
    float2 local;
    float pad;
    constant float4 *footprints;
    uint count;
    if (houseGroundHolds(p)) {
        local = houseLocal(p);
        pad = housePlayerPad / houseScale;
        if (abs(local.x) > houseLotUpper.x && houseYardBlocked(local, pad))
            return true;
        footprints = houseObstacles;
        count = houseObstacleCount;
    } else if (shedYardHolds(p)) {
        local = p - shedYardOrigin.xz;
        pad = housePlayerPad;
        footprints = shedObstacles;
        count = shedObstacleCount;
    } else if (cottageGroundHolds(p)) {
        local = p - cottageOrigin.xz;
        pad = housePlayerPad;
        footprints = cottageObstacles;
        count = cottageObstacleCount;
    } else {
        // The street: its lamp posts, then the copies' footprints.
        if (streetLampBlocked(p, housePlayerPad)) return true;
        if (!streetNearProperties(p)) return false;
        local = p;
        pad = housePlayerPad;
        footprints = streetObstacles;
        count = streetObstacleCount;
    }
    for (uint i = 0u; i < count; ++i) {
        float4 r = footprints[i];
        if (all(local > r.xy - pad) && all(local < r.zw + pad)) return true;
    }
    return false;
}

// ------------------------------------------------------------------- smoke

// Smoke from the cottages' chimneys, over color where the opaque scene lies
// sceneDistance along the ray. light is the light the smoke catches.
float3 buildingsSmoke(float3 color, float3 origin, float3 direction,
    float sceneDistance, device const GameState &game, float3 light) {
    float gale = houseWind(game).strength;
    for (uint i = 0u; i < streetCottageCount; ++i) {
        float4 chimney = streetChimneys[i];
        color = cottageSmoke(color, origin, direction, sceneDistance,
            chimney.xyz, chimney.w, 0.37f * float(i), game.effects.x, gale,
            light);
    }
    return color;
}

// ------------------------------------------------------------------- doors

// The doors a visitor can knock on: the house's two front doors, the
// cottage's plank door and the barn's two sliding leaves. Each building's
// file places its own. The house's pair and the cottage's door are shut
// until knocked on, then swing open and stay open until the match
// restarts; the barn's leaves stay as they are. A swinging door is a part
// rehung every tick, so the scene traces, shadows and shots see it where
// it is.
constant uint buildingsDoorCount = 5u;
constant uint doorOfHouse = 1u;
constant uint doorOfCottage = 2u;
constant uint doorOfBarn = 3u;
// Seconds a door takes to swing open, and how long after the last rap it
// starts: an old latch gives a moment before the door moves.
constant float buildingsHouseDoorsSwing = 2.6f;
constant float buildingsCottageDoorSwing = 1.8f;
constant float buildingsDoorDelay = 0.3f;

void buildingsShutDoors(device GameState &game) {
    game.house.doors = float4(-100.0f, -100.0f, 0.0f, 0.0f);
}

// Sets the house's (building doorOfHouse) or the cottage's door swinging
// open, unless it already is.
void buildingsOpenDoor(device GameState &game, uint building) {
    float start = game.effects.x + buildingsDoorDelay;
    if (building == doorOfHouse && game.house.doors.x < 0.0f)
        game.house.doors.x = start;
    if (building == doorOfCottage && game.house.doors.y < 0.0f)
        game.house.doors.y = start;
}

// How far the house's pair (set 0) or the cottage's door (set 1) has swung
// open, from 0 to 1: it gives a little as the latch lets go, then creaks
// round, slowing as it comes to rest.
float buildingsDoorOpen(device const GameState &game, uint set) {
    float start = set == 0u ? game.house.doors.x : game.house.doors.y;
    if (start < 0.0f) return 0.0f;
    float t = (game.effects.x - start) / (set == 0u
        ? buildingsHouseDoorsSwing : buildingsCottageDoorSwing);
    return 0.1f * smoothstep(0.0f, 0.12f, t)
        + 0.9f * smoothstep(0.18f, 1.0f, t);
}

// Rehangs the swinging doors' parts for this tick. Each swings within the
// bounds its group was built with: the house's leaves into the hall, the
// cottage's into its lobby.
void buildingsHangDoors(device GameState &game) {
    device HouseModel &house = game.house;
    float leaves = buildingsDoorOpen(game, 0u);
    for (uint side = 0u; side < 2u; ++side)
        house.parts[min(house.doorParts[side], houseCapacity - 1u)]
            = houseWorldPart(houseFrontDoor(side, leaves));
    house.parts[min(house.doorParts.z, houseCapacity - 1u)]
        = cottageDoor(buildingsDoorOpen(game, 1u));
}

// True where the house's front doors, while still too far shut to pass,
// keep the walker out of the doorway.
bool buildingsDoorsBar(device const GameState &game, float2 p) {
    if (buildingsDoorOpen(game, 0u) > 0.7f) return false;
    float2 local = houseLocal(p);
    float pad = housePlayerPad / houseScale;
    return abs(local.x) < houseDoorHalfWidth && local.y > -6.0f - pad
        && local.y < -5.7f + pad;
}

// The nearest door the ray meets before limit: its distance, or -1 when
// there is none. door names its building, or is 0. The house's and the
// cottage's doors are met where they hang; the barn's leaves are boxes.
float buildingsDoorCrossing(device const HouseModel &house, float3 origin,
    float3 direction, float limit, thread uint &door) {
    float nearest = -1.0f;
    door = 0u;
    for (uint i = 0u; i < buildingsDoorCount; ++i) {
        float3 normal;
        float t;
        uint building;
        if (i < 3u) {
            HouseTurn turn = i == 2u ? cottageFrame()
                : HouseTurn{0.0f, 1.0f, float2(0.0f)};
            building = i == 2u ? doorOfCottage : doorOfHouse;
            t = housePartHit(house.parts[min(house.doorParts[i],
                    houseCapacity - 1u)], houseTurnPointIn(turn, origin),
                houseTurnDirectionIn(turn, direction), limit, normal);
        } else {
            float3 lower, upper;
            shedDoorLeaf(barnSpec(), i - 3u, lower, upper);
            lower += shedYardOrigin;
            upper += shedYardOrigin;
            building = doorOfBarn;
            // A little proud of the boards, which are traced in relief.
            t = pixeltje_3d::rayBox(origin, direction, lower - 0.03f,
                upper + 0.03f, 0.0f, normal);
        }
        if (t < 0.0f || t > limit) continue;
        nearest = t;
        limit = t;
        door = building;
    }
    return nearest;
}

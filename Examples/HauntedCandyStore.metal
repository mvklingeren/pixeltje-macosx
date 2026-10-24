// The candy-store: a compact 1960s Halloween storefront to the left of the
// crater-side cottage, west of the street mausoleum. Its ground floor is an
// empty, walkable room ready for the candy shelves in a later change.
// The two glass door leaves slide apart when someone stands on the iron
// pressure plate on either side of the threshold.

constant float3 candyStoreOrigin = float3(-105.5f, -0.35f, 31.9f);
constant float2 candyStoreHalf = float2(3.25f, 2.8f);
constant float candyStoreFloor = 0.2f;
constant float candyStoreDoorZ = candyStoreHalf.y + 0.035f;
constant float candyStoreDoorHalf = 0.86f;
constant uint candyStoreDoorPartsPerLeaf = 5u;

HousePart candyStoreBox(float3 lower, float3 upper, uint style) {
    return houseBox(candyStoreOrigin + lower, candyStoreOrigin + upper, style);
}

float candyStoreGroundBlend(float2 p) {
    return buildingPadBlend(p, candyStoreOrigin.xz,
        -candyStoreHalf - float2(0.6f),
        candyStoreHalf + float2(0.6f), 0.4f, 7.0f);
}

bool candyStoreGroundHolds(float2 p) {
    float2 q = p - candyStoreOrigin.xz;
    return all(abs(q) < candyStoreHalf + float2(1.0f));
}

float candyStoreStand(float2 p, float ground) {
    float2 q = p - candyStoreOrigin.xz;
    if (all(abs(q) < candyStoreHalf + float2(0.1f)))
        return max(ground, candyStoreOrigin.y + candyStoreFloor);
    return ground;
}

// The glass is not a collision wall; the fixed piers and the moving door
// are tested separately, leaving the whole shop floor accessible.
bool candyStoreBlocked(float2 p, float pad) {
    float2 q = p - candyStoreOrigin.xz;
    if (abs(q.y) < candyStoreHalf.y + pad) {
        if (abs(q.x) > candyStoreHalf.x - 0.17f - pad
            && abs(q.x) < candyStoreHalf.x + pad) return true;
        if (q.y < -candyStoreHalf.y + 0.16f + pad
            && q.y > -candyStoreHalf.y - pad) return true;
        if (q.y > candyStoreHalf.y - 0.16f - pad
            && q.y < candyStoreHalf.y + pad
            && abs(q.x) > candyStoreDoorHalf - pad) return true;
    }
    return false;
}

bool candyStoreDoorsBar(device const GameState &game, float2 p) {
    if (game.candyDoor.x > 0.82f) return false;
    float2 q = p - candyStoreOrigin.xz;
    return abs(q.x) < candyStoreDoorHalf + housePlayerPad
        && abs(q.y - candyStoreDoorZ) < 0.11f + housePlayerPad;
}

// Part 0 is a clear pane; the remaining four are black metal stiles and
// rails. Sliding each leaf sideways keeps the door entirely in its group.
HousePart candyStoreDoorPart(uint side, uint element, float open) {
    float shift = (side == 0u ? -1.0f : 1.0f)
        * candyStoreDoorHalf * 0.98f * open;
    float lo = side == 0u ? -candyStoreDoorHalf : 0.0f;
    float hi = lo + candyStoreDoorHalf;
    lo += shift;
    hi += shift;
    float3 lower = float3(lo, candyStoreFloor + 0.04f,
        candyStoreDoorZ - 0.02f);
    float3 upper = float3(hi, 2.52f, candyStoreDoorZ + 0.02f);
    if (element == 0u)
        return candyStoreBox(lower, upper, houseCandyGlass);
    if (element == 1u) upper.x = lo + 0.055f;
    if (element == 2u) lower.x = hi - 0.055f;
    if (element == 3u) lower.y = upper.y - 0.07f;
    if (element == 4u) upper.y = lower.y + 0.13f;
    return candyStoreBox(lower - float3(0.0f, 0.0f, 0.025f),
        upper + float3(0.0f, 0.0f, 0.025f), houseCastIron);
}

void buildCandyStore(device HouseModel &house, device GameState &game) {
    house.activeBuilding = 15u;
    beginBuildingSite(house);
    beginHouseGroup(house);
    const float X = candyStoreHalf.x, Z = candyStoreHalf.y;
    // A raised floor and a plain empty sales room. The second
    // floor is a separate slab under the shallow pitched roof.
    addHouseWorldPart(house, candyStoreBox(
        float3(-X - 0.12f, -0.18f, -Z - 0.12f),
        float3(X + 0.12f, candyStoreFloor, Z + 0.12f), houseStone));
    addHouseWorldPart(house, candyStoreBox(float3(-X, 3.32f, -Z),
        float3(X, 3.45f, Z), houseFloor));
    addHouseWorldPart(house, candyStoreBox(float3(-X, candyStoreFloor, -Z),
        float3(X, 6.25f, -Z + 0.16f), houseBrick));
    for (uint side = 0u; side < 2u; ++side) {
        float x = side == 0u ? -X : X - 0.16f;
        addHouseWorldPart(house, candyStoreBox(
            float3(x, candyStoreFloor, -Z),
            float3(x + 0.16f, 6.25f, Z), houseSiding));
    }
    // The shopfront's broad plate glass sits between brick piers. A narrow
    // central opening remains genuinely open behind the sliding leaves.
    for (uint side = 0u; side < 2u; ++side) {
        float sign = side == 0u ? -1.0f : 1.0f;
        float x0 = side == 0u ? -X : 2.42f;
        addHouseWorldPart(house, candyStoreBox(
            float3(x0, candyStoreFloor, Z - 0.16f),
            float3(x0 + 0.83f, 3.32f, Z), houseBrick));
        float a = side == 0u ? -2.42f : 1.0f;
        float b = side == 0u ? -1.0f : 2.42f;
        addHouseWorldPart(house, candyStoreBox(
            float3(a, 0.42f, Z - 0.035f),
            float3(b, 2.53f, Z + 0.035f), houseCandyGlass));
        addHouseWorldPart(house, candyStoreBox(
            float3(a, candyStoreFloor, Z - 0.12f),
            float3(b, 0.42f, Z + 0.07f), houseCastIron));
        addHouseWorldPart(house, candyStoreBox(
            float3(a, 2.53f, Z - 0.12f),
            float3(b, 2.62f, Z + 0.07f), houseCastIron));
        for (uint edge = 0u; edge < 2u; ++edge) {
            float x = edge == 0u ? a : b - 0.055f;
            addHouseWorldPart(house, candyStoreBox(
                float3(x, 0.42f, Z - 0.08f),
                float3(x + 0.055f, 2.62f, Z + 0.08f), houseCastIron));
        }
        // Two rectangular upper-floor windows give the small store a clear
        // second storey without borrowing the cottage's pointed arches.
        float u0 = sign < 0.0f ? -2.28f : 0.55f;
        float u1 = sign < 0.0f ? -0.55f : 2.28f;
        addHouseWorldPart(house, candyStoreBox(
            float3(u0, 4.2f, Z - 0.04f),
            float3(u1, 5.75f, Z + 0.04f), houseCandyGlass));
        for (uint edge = 0u; edge < 2u; ++edge) {
            float x = edge == 0u ? u0 - 0.07f : u1;
            addHouseWorldPart(house, candyStoreBox(
                float3(x, 4.13f, Z - 0.09f),
                float3(x + 0.07f, 5.82f, Z + 0.09f), houseCastIron));
        }
        addHouseWorldPart(house, candyStoreBox(
            float3(u0 - 0.07f, 4.13f, Z - 0.09f),
            float3(u1 + 0.07f, 4.2f, Z + 0.09f), houseCastIron));
        addHouseWorldPart(house, candyStoreBox(
            float3(u0 - 0.07f, 5.75f, Z - 0.09f),
            float3(u1 + 0.07f, 5.82f, Z + 0.09f), houseCastIron));
    }
    // Fixed doorway frame, sign, and a striped canvas awning in 1960s
    // orange and black. The readable sign shares the street's font atlas.
    for (uint side = 0u; side < 2u; ++side) {
        float x = side == 0u ? -0.98f : 0.9f;
        addHouseWorldPart(house, candyStoreBox(
            float3(x, candyStoreFloor, Z - 0.12f),
            float3(x + 0.08f, 2.62f, Z + 0.1f), houseCastIron));
    }
    addHouseWorldPart(house, candyStoreBox(
        float3(-X, 2.62f, Z - 0.16f),
        float3(X, 3.33f, Z), houseSiding));
    HousePart sign = candyStoreBox(float3(-3.02f, 3.48f, Z + 0.08f),
        float3(3.02f, 4.05f, Z + 0.17f), houseSign);
    sign.rows = float4(5.0f, 0.48f, 1.0f, 1.0f);
    addHouseWorldPart(house, sign);
    addHouseWorldPart(house, candyStoreBox(
        float3(-3.12f, 2.55f, Z + 0.02f),
        float3(3.12f, 2.69f, Z + 1.18f), houseCandyAwning));
    // Fixed orange pressure plates both welcome and release a visitor.
    addHouseWorldPart(house, candyStoreBox(
        float3(-1.15f, candyStoreFloor, Z + 0.13f),
        float3(1.15f, candyStoreFloor + 0.018f, Z + 1.22f),
        houseCastIron));
    addHouseWorldPart(house, candyStoreBox(
        float3(-1.15f, candyStoreFloor, Z - 1.18f),
        float3(1.15f, candyStoreFloor + 0.018f, Z - 0.13f),
        houseCastIron));
    game.candyDoorFirstPart = house.counts.x;
    for (uint side = 0u; side < 2u; ++side)
        for (uint element = 0u; element < candyStoreDoorPartsPerLeaf;
                ++element)
            addHouseWorldPart(house,
                candyStoreDoorPart(side, element, 0.0f));
    // Plaster gable face and a roof with enough pitch to read at street
    // height, yet flatter than the neighboring Victorian houses.
    addHouseWorldPart(house, houseGable(
        candyStoreOrigin + float3(-X, 6.25f, -Z),
        candyStoreOrigin + float3(X, 8.12f, Z), false, houseBattens));
    HousePart roof = houseGable(
        candyStoreOrigin + float3(-X - 0.28f, 6.32f, -Z - 0.32f),
        candyStoreOrigin + float3(X + 0.28f, 8.32f, Z + 0.32f),
        false, houseRoof);
    addHouseWorldPart(house, roof);
    house.activeBuilding = 0u;
}

PointLight candyStoreLight(device const GameState &game) {
    return {candyStoreOrigin + float3(0.0f, 2.8f, 0.2f),
        float3(1.0f, 0.33f, 0.1f),
        145.0f * houseFlicker(game.effects.x, 5.0f, 0.12f)
            * houseHaunting(game).dim,
        false};
}

void candyStoreReset(device GameState &game) {
    game.candyDoor = float4(0.0f, -100.0f, 0.0f, 0.0f);
    for (uint side = 0u; side < 2u; ++side)
        for (uint element = 0u; element < candyStoreDoorPartsPerLeaf;
                ++element)
            game.house.parts[game.candyDoorFirstPart
                + side * candyStoreDoorPartsPerLeaf + element]
                = candyStoreDoorPart(side, element, 0.0f);
}

void advanceCandyStoreDoor(device GameState &game) {
    float2 q = game.player.xz - candyStoreOrigin.xz;
    float foot = game.player.y - 1.55f;
    bool pressed = abs(q.x) < 1.22f
        && abs(q.y - candyStoreDoorZ) < 1.5f
        && abs(foot - candyStoreOrigin.y - candyStoreFloor) < 0.42f;
    float time = game.effects.x;
    if (pressed) game.candyDoor.y = time;
    float dt = clamp(time - game.candyDoor.w, 0.0f, 0.1f);
    bool held = time - game.candyDoor.y < 1.5f;
    game.candyDoor.x = clamp(game.candyDoor.x
        + (held ? 1.0f : -1.0f) * dt / 0.8f, 0.0f, 1.0f);
    game.candyDoor.z = pressed ? 1.0f : 0.0f;
    game.candyDoor.w = time;
    for (uint side = 0u; side < 2u; ++side)
        for (uint element = 0u; element < candyStoreDoorPartsPerLeaf;
                ++element)
            game.house.parts[game.candyDoorFirstPart
                + side * candyStoreDoorPartsPerLeaf + element]
                = candyStoreDoorPart(side, element, game.candyDoor.x);
}

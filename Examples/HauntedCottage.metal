// The cottage for HauntedHouseProgram.metal: a smaller haunted house beside
// the flagstone path from the base, west of it and halfway to the big
// house, on a branch path of its own.
//
// A storey and a half under a steep slate roof whose gable ends jut out
// over the walls, with a catslide lean-to down its back, a dormer in its
// front slope and a brick chimney that leans away from its west gable. A
// gabled hood over a stone step shelters the front door and a lantern. Its
// clapboard walls carry the house's pointed windows, a few boarded, onto
// dim rooms where candles burn; they go dark and green when the house is
// haunted, but shooting them leaves the house asleep. Nobody goes in.
//
// Parts are in world metres around cottageOrigin, the middle of the floor:
// x east, y up from the levelled ground, z north. The cottage faces -z.

constant float3 cottageOrigin = float3(-36.0f, 0.5f, 54.0f);
constant float2 cottagePadLower = float2(-7.0f, -6.5f);
constant float2 cottagePadUpper = float2(6.0f, 8.0f);
constant float2 cottageHalf = float2(4.5f, 3.5f);   // the walls
constant float cottageFloor = 0.5f;                 // top of the foundation
constant float cottageEaves = 3.4f;
constant float cottageRidge = 8.0f;
constant float3 cottageLantern = float3(0.0f, 2.25f, -4.3f);

// Where the walker cannot go, in the cottage's frame as lower and upper
// x and z: the house on its foundation, the lean-to, the chimney and the
// step with its posts.
constant uint cottageObstacleCount = 4u;
constant float4 cottageObstacles[cottageObstacleCount] = {
    float4(-4.65f, -3.65f, 4.65f, 3.65f), float4(-4.6f, 3.5f, 1.3f, 6.4f),
    float4(-5.6f, 1.15f, -4.65f, 2.25f), float4(-1.2f, -4.8f, 1.2f, -3.65f),
};

// Weight of the natural terrain around the cottage: 0 on its levelled
// ground and 1.5 m beyond, rising to 1 another 14 m out.
float cottageGroundBlend(float2 p) {
    return buildingPadBlend(p, cottageOrigin.xz, cottagePadLower,
        cottagePadUpper, 1.5f, 14.0f);
}

// True where p, in world x and z, lies on the cottage's ground.
bool cottageGroundHolds(float2 p) {
    float2 local = p - cottageOrigin.xz;
    return all(local > cottagePadLower) && all(local < cottagePadUpper);
}

// The plank door in the front wall, as a box in the cottage's frame.
void cottageDoor(thread float3 &lower, thread float3 &upper) {
    lower = float3(-0.55f, cottageFloor, -cottageHalf.y - 0.06f);
    upper = float3(0.55f, cottageFloor + 2.2f, -cottageHalf.y);
}

// The porch lantern's light.
PointLight cottageLanternLight(float time) {
    return {cottageOrigin + cottageLantern - float3(0.0f, 0.1f, 0.0f),
        float3(1.0f, 0.6f, 0.27f), 150.0f * houseFlicker(time, 7.0f, 0.15f),
        false};
}

// The branch path from the flagstone path to the cottage's step, as
// housePath measures it.
float3 cottagePath(float2 p, float blur) {
    const float2 from = float2(-1.2f, 46.0f);
    float2 to = cottageOrigin.xz + float2(0.0f, -4.8f);
    float2 along = normalize(to - from);
    float2 offset = p - from;
    float2 metres = float2(dot(offset, float2(-along.y, along.x)),
        dot(offset, along));
    if (metres.y < 0.0f || metres.y > distance(from, to)
        || abs(metres.x) > 1.05f + 0.12f * smoothNoise(p * 1.7f))
        return float3(0.0f);
    return houseFlagstones(metres, blur);
}

// A box in the cottage's frame.
HousePart cottageBox(float3 lower, float3 upper, uint style) {
    return houseBox(cottageOrigin + lower, cottageOrigin + upper, style);
}

void buildCottage(device HouseModel &house) {
    beginBuildingSite(house);
    beginHouseGroup(house);
    const float3 o = cottageOrigin;
    const float2 h = cottageHalf;
    const float F = cottageFloor, E = cottageEaves, R = cottageRidge;
    // Foundation, walls with their windows, a plank door and its step.
    addHouseWorldPart(house, cottageBox(float3(-h.x - 0.15f, -0.3f,
        -h.y - 0.15f), float3(h.x + 0.15f, F, h.y + 0.15f), houseStone));
    HousePart walls = cottageBox(float3(-h.x, F, -h.y), float3(h.x, E, h.y),
        houseSiding);
    houseWindows(walls, float2(2.0f, 1.0f), float2(0.5f, 0.85f), 0.45f, 1.0f,
        0.0f, 0.7f);
    uint wallIndex = house.counts.x;
    addHouseWorldPart(house, walls);
    float2 clad = float2(F + 0.1f, E - 0.1f) + o.y - houseOrigin.y;
    addLooseClapboards(house, wallIndex, float3(0.0f, 0.0f, -1.0f), clad,
        float2(o.x - 0.9f, o.x + 0.9f), 2u);
    addLooseClapboards(house, wallIndex, float3(1.0f, 0.0f, 0.0f), clad,
        houseNoSkip, 1u);
    float3 doorLower, doorUpper;
    cottageDoor(doorLower, doorUpper);
    addHouseWorldPart(house, cottageBox(doorLower, doorUpper, houseBattens));
    addHouseWorldPart(house, cottageBox(float3(-1.2f, -0.3f, -4.8f),
        float3(1.2f, 0.3f, -h.y - 0.15f), houseStone));
    // The door hood on two posts, and the lantern under it.
    for (uint side = 0u; side < 2u; ++side) {
        float x = side == 0u ? -0.95f : 0.95f;
        addHouseWorldPart(house, cottageBox(float3(x - 0.06f, 0.3f, -4.66f),
            float3(x + 0.06f, 2.75f, -4.54f), houseTrim));
    }
    addHouseWorldPart(house, houseGable(o + float3(-1.2f, 2.75f, -4.85f),
        o + float3(1.2f, 3.55f, -h.y), true, houseRoof));
    addHouseWorldPart(house, cottageBox(cottageLantern + float3(-0.015f, 0.2f,
        -0.015f), cottageLantern + float3(0.015f, 0.5f, 0.015f), houseTrim));
    addHouseWorldPart(house, cottageBox(cottageLantern - float3(0.13f, 0.2f,
        0.13f), cottageLantern + float3(0.13f, 0.2f, 0.13f), houseLantern));
    // The steep roof, its gable ends jutting over the walls, each with a
    // window into the attic.
    HousePart roof = houseGable(o + float3(-h.x - 0.4f, E, -h.y - 0.45f),
        o + float3(h.x + 0.4f, R, h.y + 0.45f), false, houseRoof);
    houseWindows(roof, float2(0.0f, 1.0f), float2(0.45f, 0.75f), 0.35f, 1.0f,
        0.0f, 0.85f);
    addHouseWorldPart(house, roof);
    // A dormer in the front slope.
    HousePart dormer = cottageBox(float3(1.4f, 3.9f, -3.1f),
        float3(3.0f, 6.1f, -1.2f), houseBattens);
    houseWindows(dormer, float2(1.0f, 0.0f), float2(0.42f, 0.65f), 0.35f, 1.0f,
        0.0f, 0.9f);
    addHouseWorldPart(house, dormer);
    addHouseWorldPart(house, houseGable(o + float3(1.2f, 6.1f, -3.3f),
        o + float3(3.2f, 7.0f, -1.0f), true, houseRoof));
    // The lean-to: board and batten under a catslide that carries on from
    // the back slope, shallower.
    addHouseWorldPart(house, cottageBox(float3(-h.x - 0.1f, -0.3f, h.y),
        float3(1.3f, F, 6.4f), houseStone));
    addHouseWorldPart(house, cottageBox(float3(-h.x, F, h.y),
        float3(1.2f, 2.5f, 6.3f), houseBattens));
    float slope = (R - E) / (h.y + 0.45f);
    float3 kink = float3(0.0f, R - slope * h.y, h.y);
    HousePart catslide = cottageBox(float3(-h.x - 0.3f, 2.3f, h.y),
        float3(1.5f, kink.y + 0.01f, 6.75f), houseRoof);
    houseCut(catslide, float3(0.0f, 1.0f, 0.47f), o + kink);
    addHouseWorldPart(house, catslide);
    // The chimney: straight up the gable, then leaning out, under a cap.
    const float lean = 0.1f;
    addHouseWorldPart(house, cottageBox(float3(-5.6f, -0.3f, 1.15f),
        float3(-h.x, 6.0f, 2.25f), houseBrick));
    HousePart stack = cottageBox(float3(-5.6f - 0.36f, 6.0f, 1.15f),
        float3(-h.x - 0.4f, 9.6f, 2.25f), houseBrick);
    houseCut(stack, float3(-1.0f, -lean, 0.0f), o + float3(-5.6f, 6.0f, 0.0f));
    houseCut(stack, float3(1.0f, lean, 0.0f),
        o + float3(-h.x - 0.4f, 6.0f, 0.0f));
    addHouseWorldPart(house, stack);
    addHouseWorldPart(house, cottageBox(float3(-6.06f, 9.6f, 1.05f),
        float3(-5.16f, 9.8f, 2.35f), houseStone));
}

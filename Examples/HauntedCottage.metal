// The cottage for HauntedHouseProgram.metal: the smaller haunted house west
// of the flagstone path from the base, halfway to the big house, across a
// short drive from the street. It stands a few degrees off square with the
// road, as a house built before the road would.
//
// Two storeys under a steep slate roof whose gable ends jut out over the
// walls, with a catslide lean-to down its back, two dormers in its front
// slope and a brick chimney that leans away from its west gable, where a
// wood fire keeps a thin smoke rising. A gabled hood over a stone step
// shelters the front door and a lantern. Its oak clapboard walls carry the
// house's pointed windows, a few boarded, onto dim rooms where candles
// burn; they go dark and green when the house is haunted, but shooting
// them leaves the house asleep. Nobody goes in.
//
// Parts are in metres around cottageOrigin, the middle of the floor, in the
// cottage's own frame: x east, y up from the levelled ground, z north,
// before cottageTurn turns it. The cottage faces -z.

constant float3 cottageOrigin = float3(-38.0f, 0.5f, 60.0f);
// cos and sin of the 7° the cottage stands turned, taking +x toward +z.
constant float2 cottageTurn = float2(0.992546f, 0.121869f);
constant float2 cottagePadLower = float2(-12.5f, -11.5f);
constant float2 cottagePadUpper = float2(11.5f, 15.5f);
constant float2 cottageHalf = float2(9.0f, 7.0f);   // the walls
constant float cottageFloor = 0.5f;                 // top of the foundation
constant float cottageEaves = 6.4f;
constant float cottageRidge = 14.6f;
constant float3 cottageLantern = float3(0.0f, 2.25f, -7.8f);
// The mouth of the chimney pot, where the smoke leaves it.
constant float3 cottageChimneyTop = float3(-10.33f, 18.1f, 2.8f);

// Where the walker cannot go, in the cottage's frame as lower and upper
// x and z: the house on its foundation, the lean-to, the chimney and the
// step with its posts.
constant uint cottageObstacleCount = 4u;
constant float4 cottageObstacles[cottageObstacleCount] = {
    float4(-9.2f, -7.2f, 9.2f, 7.2f), float4(-9.1f, 7.0f, 2.7f, 12.8f),
    float4(-10.3f, 2.0f, -9.2f, 3.6f), float4(-1.2f, -8.35f, 1.2f, -7.2f),
};

// The cottage's turn about the vertical through its origin.
HouseTurn cottageFrame() {
    return {cottageTurn.y, cottageTurn.x, cottageOrigin.xz};
}

// p, in world x and z, in the cottage's frame around its origin.
float2 cottageLocal(float2 p) {
    return houseRotate(p - cottageOrigin.xz,
        float2(cottageTurn.x, -cottageTurn.y));
}

// Weight of the natural terrain around the cottage: 0 on its levelled
// ground and 1.5 m beyond, rising to 1 another 14 m out.
float cottageGroundBlend(float2 p) {
    return buildingPadBlend(cottageLocal(p), float2(0.0f), cottagePadLower,
        cottagePadUpper, 1.5f, 14.0f);
}

// True where p, in world x and z, lies on the cottage's ground.
bool cottageGroundHolds(float2 p) {
    float2 local = cottageLocal(p);
    return all(local > cottagePadLower) && all(local < cottagePadUpper);
}

// The plank door in the front wall, as a box in the cottage's frame.
void cottageDoor(thread float3 &lower, thread float3 &upper) {
    lower = float3(-0.55f, cottageFloor, -cottageHalf.y - 0.06f);
    upper = float3(0.55f, cottageFloor + 2.2f, -cottageHalf.y);
}

// The porch lantern's light. The street's table says where each cottage's
// hangs.
PointLight cottageLanternLight(float time) {
    return {cottageOrigin + cottageLantern - float3(0.0f, 0.1f, 0.0f),
        float3(1.0f, 0.6f, 0.27f), 150.0f * houseFlicker(time, 7.0f, 0.15f),
        false};
}

// A box in the cottage's frame.
HousePart cottageBox(float3 lower, float3 upper, uint style) {
    return houseBox(cottageOrigin + lower, cottageOrigin + upper, style);
}

// A dormer in the front slope, centred on x: a battened front with one
// window under its own small gable, its back buried in the main roof.
void addCottageDormer(device HouseModel &house, float x) {
    const float3 o = cottageOrigin;
    HousePart dormer = cottageBox(float3(x - 1.5f, 8.0f, -5.6f),
        float3(x + 1.5f, 11.0f, -2.0f), houseBattens);
    houseWindows(dormer, float2(1.0f, 0.0f), float2(0.45f, 0.65f), 0.5f, 1.0f,
        0.0f, 0.9f);
    addHouseWorldPart(house, dormer);
    addHouseWorldPart(house, houseGable(o + float3(x - 1.7f, 11.0f, -5.8f),
        o + float3(x + 1.7f, 12.2f, -1.8f), true, houseRoof));
}

void buildCottage(device HouseModel &house) {
    beginBuildingSite(house);
    uint firstGroup = house.counts.y;
    beginHouseGroup(house);
    const float3 o = cottageOrigin;
    const float2 h = cottageHalf;
    const float F = cottageFloor, E = cottageEaves, R = cottageRidge;
    // Foundation, walls with two storeys of windows, a plank door and its
    // step.
    addHouseWorldPart(house, cottageBox(float3(-h.x - 0.2f, -0.3f,
        -h.y - 0.2f), float3(h.x + 0.2f, F, h.y + 0.2f), houseStone));
    HousePart walls = cottageBox(float3(-h.x, F, -h.y), float3(h.x, E, h.y),
        houseSiding);
    houseWindows(walls, float2(4.0f, 3.0f), float2(0.5f, 0.85f), 0.45f, 2.0f,
        1.45f, 0.7f);
    uint wallIndex = house.counts.x;
    addHouseWorldPart(house, walls);
    float2 clad = float2(F + 0.1f, E - 0.1f) + o.y - houseOrigin.y;
    addLooseClapboards(house, wallIndex, float3(0.0f, 0.0f, -1.0f), clad,
        float2(o.x - 0.9f, o.x + 0.9f), 3u);
    addLooseClapboards(house, wallIndex, float3(1.0f, 0.0f, 0.0f), clad,
        houseNoSkip, 1u);
    float3 doorLower, doorUpper;
    cottageDoor(doorLower, doorUpper);
    addHouseWorldPart(house, cottageBox(doorLower, doorUpper, houseBattens));
    addHouseWorldPart(house, cottageBox(float3(-1.2f, -0.3f, -8.35f),
        float3(1.2f, 0.3f, -h.y - 0.2f), houseStone));
    // The door hood on two posts, and the lantern under it.
    for (uint side = 0u; side < 2u; ++side) {
        float x = side == 0u ? -0.95f : 0.95f;
        addHouseWorldPart(house, cottageBox(float3(x - 0.06f, 0.3f, -8.16f),
            float3(x + 0.06f, 2.75f, -8.04f), houseTrim));
    }
    addHouseWorldPart(house, houseGable(o + float3(-1.2f, 2.75f, -8.35f),
        o + float3(1.2f, 3.55f, -h.y), true, houseRoof));
    addHouseWorldPart(house, cottageBox(cottageLantern + float3(-0.015f, 0.2f,
        -0.015f), cottageLantern + float3(0.015f, 0.5f, 0.015f), houseTrim));
    addHouseWorldPart(house, cottageBox(cottageLantern - float3(0.13f, 0.2f,
        0.13f), cottageLantern + float3(0.13f, 0.2f, 0.13f), houseLantern));
    // The steep roof, its gable ends jutting over the walls, each with a
    // window into the attic.
    HousePart roof = houseGable(o + float3(-h.x - 0.8f, E, -h.y - 0.9f),
        o + float3(h.x + 0.8f, R, h.y + 0.9f), false, houseRoof);
    houseWindows(roof, float2(0.0f, 1.0f), float2(0.45f, 0.75f), 0.9f, 1.0f,
        0.0f, 0.85f);
    addHouseWorldPart(house, roof);
    // Two dormers in the front slope.
    addCottageDormer(house, -4.2f);
    addCottageDormer(house, 4.0f);
    // The lean-to: board and batten under a catslide that carries on from
    // the back slope, shallower.
    addHouseWorldPart(house, cottageBox(float3(-h.x - 0.1f, -0.3f, h.y),
        float3(2.7f, F, 12.8f), houseStone));
    addHouseWorldPart(house, cottageBox(float3(-h.x, F, h.y),
        float3(2.6f, 4.2f, 12.6f), houseBattens));
    float slope = (R - E) / (h.y + 0.9f);
    float3 kink = float3(0.0f, R - slope * h.y, h.y);
    HousePart catslide = cottageBox(float3(-h.x - 0.3f, 4.0f, h.y),
        float3(2.9f, kink.y + 0.01f, 13.25f), houseRoof);
    houseCut(catslide, float3(0.0f, 1.0f, 0.47f), o + kink);
    addHouseWorldPart(house, catslide);
    // The chimney: straight up the gable, then leaning out, under a cap
    // with a pot on it.
    const float lean = 0.08f;
    addHouseWorldPart(house, cottageBox(float3(-h.x - 1.3f, -0.3f, 2.0f),
        float3(-h.x, 11.4f, 3.6f), houseBrick));
    HousePart stack = cottageBox(float3(-h.x - 1.8f, 11.4f, 2.2f),
        float3(-h.x - 0.4f, 17.4f, 3.4f), houseBrick);
    houseCut(stack, float3(-1.0f, -lean, 0.0f),
        o + float3(-h.x - 1.3f, 11.4f, 0.0f));
    houseCut(stack, float3(1.0f, lean, 0.0f),
        o + float3(-h.x - 0.4f, 11.4f, 0.0f));
    addHouseWorldPart(house, stack);
    addHouseWorldPart(house, cottageBox(float3(-h.x - 1.88f, 17.4f, 2.1f),
        float3(-h.x - 0.78f, 17.6f, 3.5f), houseStone));
    addHouseWorldPart(house, cottageBox(cottageChimneyTop
        - float3(0.15f, 0.5f, 0.15f), cottageChimneyTop
        + float3(0.15f, 0.0f, 0.15f), houseBrick));
    turnHouseGroups(house, firstGroup, house.counts.y, cottageTurn, o.xz);
}

// ------------------------------------------------------------------- smoke

float2 rayPointGap(float3 origin, float3 direction, float3 point);

// Wood smoke rising from a chimney pot at top, for a cottage at scale: a
// stream of soft puffs that leave the pot every second or so, climb,
// slow, swell and thin out as the breeze carries them off and shreds them.
// light is the light the smoke catches; seed sets each chimney's own
// rhythm. The puffs are depth-tested against the opaque scene.
float3 cottageSmoke(float3 color, float3 origin, float3 direction,
    float sceneDistance, float3 top, float scale, float seed, float time,
    float gale, float3 light) {
    const uint puffs = 12u;
    const float life = 11.0f;
    // The breeze blows the smoke east and a little north; the haunting's
    // gale bends it harder.
    float3 breeze = normalize(float3(1.0f, 0.0f, 0.35f))
        * (0.55f + 1.6f * gale);
    // The whole plume first: rays that pass it by skip every puff.
    float3 middle = top + (float3(0.0f, 4.0f, 0.0f) + breeze * 4.5f) * scale;
    float2 bound = rayPointGap(origin, direction, middle);
    if (bound.x > 9.0f * scale || bound.y < -9.0f * scale) return color;
    float3 smoke = float3(0.2f, 0.2f, 0.21f) * light;
    for (uint k = 0u; k < puffs; ++k) {
        float phase = fract(time / life + (float(k) + 0.5f) / float(puffs)
            + seed);
        float age = phase * life;
        float key = houseHash(seed * 17.0f + float(k)
            + floor(time / life + (float(k) + 0.5f) / float(puffs) + seed));
        // Up fast out of the pot, slowing as it cools; the breeze takes
        // over and the puff wanders.
        float rise = 2.6f * (1.0f - exp(-age / 2.8f)) + 0.12f * age;
        float3 wander = float3(sin(time * 0.6f + key * 6.3f),
            0.4f * sin(time * 0.9f + key * 4.1f),
            cos(time * 0.5f + key * 5.7f)) * (0.12f * age);
        float3 centre = top + (float3(0.0f, rise, 0.0f) + breeze * age
            + wander) * scale;
        float radius = (0.25f + 0.24f * age) * (0.8f + 0.4f * key) * scale;
        float2 gap = rayPointGap(origin, direction, centre);
        if (gap.x > radius || gap.y <= 0.0f || gap.y - radius > sceneDistance)
            continue;
        float depth = sqrt(max(radius * radius - gap.x * gap.x, 0.0f));
        float visible = saturate((sceneDistance - (gap.y - depth))
            / max(2.0f * depth, 1.0e-3f));
        float core = 1.0f - smoothstep(0.1f * radius, radius, gap.x);
        // Torn into wisps: noise over the puff's face, coarser as it swells.
        float3 offset = (origin + direction * gap.y - centre) / radius;
        float wisp = smoothNoise(float2(offset.x + offset.z, offset.y) * 2.2f
            + key * 37.0f + float2(0.0f, -0.3f * age));
        float thin = smoothstep(0.0f, 0.04f, phase)
            * (1.0f - smoothstep(0.2f, 1.0f, phase));
        color = mix(color, smoke, 0.3f * core * (0.35f + 0.9f * wisp) * thin
            * visible);
    }
    return color;
}

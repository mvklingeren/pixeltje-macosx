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
// them leaves the house asleep. Nobody goes in, but a knock opens the
// door: it creaks in on a dark lobby.
//
// Parts are in metres around cottageOrigin, the middle of the floor, in the
// cottage's own frame: x east, y up from the levelled ground, z north,
// before cottageTurn turns it. The cottage faces -z.

constant float3 cottageOrigin = float3(-38.0f, 0.5f, 60.0f);
// cos and sin of the 7° the cottage stands turned, taking +x toward +z.
constant float2 cottageTurn = float2(0.992546f, 0.121869f);
// The levelled ground around the origin: the box around the turned pad,
// whose corners are at -12.5, -11.5 and 11.5, 15.5 in the cottage's frame.
constant float2 cottagePadLower = float2(-14.295802f, -12.937648f);
constant float2 cottagePadUpper = float2(12.815778f, 16.785963f);
constant float2 cottageHalf = float2(9.0f, 7.0f);   // the walls
constant float cottageFloor = 0.5f;                 // top of the foundation
constant float cottageEaves = 6.4f;
constant float cottageRidge = 14.6f;
constant float cottageDoorHalfWidth = 0.55f;
constant float cottageDoorHeight = 2.2f;
// The lobby behind the door, deep enough for the door to swing into and
// shallow enough to stay clear of the side walls' first windows.
constant float cottageLobbyDepth = 1.3f;
constant float3 cottageLantern = float3(0.0f, 2.25f, -7.8f);
// The mouth of the chimney pot, where the smoke leaves it.
constant float3 cottageChimneyTop = float3(-10.33f, 18.1f, 2.8f);

// Where the walker cannot go, as world boxes around the origin: the
// outlines of the house on its foundation (-9.2, -7.2 to 9.2, 7.2 in the
// cottage's frame), the lean-to (-9.1, 7.0 to 2.7, 12.8), the chimney
// (-10.3, 2.0 to -9.2, 3.6) and the step with its posts (-1.2, -8.35 to
// 1.2, -7.2), turned with it and cut into pieces whose boxes reach at most
// 0.6 m past them. The street's copies are worked out from the same
// outlines.
constant uint cottageObstacleCount = 32u;
constant float4 cottageObstacles[cottageObstacleCount] = {
    float4(-8.290526f, -8.267530f, -3.688253f, -7.409167f),
    float4(-3.724814f, -7.706931f, 0.877459f, -6.848568f),
    float4(0.840898f, -7.146332f, 5.443172f, -6.287969f),
    float4(5.406611f, -6.585733f, 10.008884f, -5.727370f),
    float4(-10.008884f, 5.727370f, -5.406611f, 6.585733f),
    float4(-5.443172f, 6.287969f, -0.840898f, 7.146332f),
    float4(-0.877459f, 6.848568f, 3.724814f, 7.706931f),
    float4(3.688253f, 7.409167f, 8.290526f, 8.267530f),
    float4(-8.851125f, -7.969766f, -7.992762f, -3.367493f),
    float4(-9.411724f, -3.404054f, -8.553361f, 1.198219f),
    float4(-9.972323f, 1.161658f, -9.113960f, 5.763931f),
    float4(9.113960f, -5.763931f, 9.972323f, -1.161658f),
    float4(8.553361f, -1.198219f, 9.411724f, 3.404054f),
    float4(7.992762f, 3.367493f, 8.851125f, 7.969766f),
    float4(-9.921816f, 5.838812f, -5.981241f, 6.615929f),
    float4(-6.017801f, 6.318165f, -2.077226f, 7.095281f),
    float4(-2.113786f, 6.797518f, 1.826789f, 7.574634f),
    float4(-10.592098f, 11.297816f, -6.651522f, 12.074932f),
    float4(-6.688083f, 11.777169f, -2.747507f, 12.554285f),
    float4(-2.784068f, 12.256521f, 1.156508f, 13.033638f),
    float4(-10.238676f, 6.136576f, -9.624052f, 8.753757f),
    float4(-10.555537f, 8.717196f, -9.940913f, 11.334377f),
    float4(1.175604f, 7.538073f, 1.790228f, 10.155254f),
    float4(0.858744f, 10.118693f, 1.473368f, 12.735874f),
    float4(-10.503525f, 0.729838f, -9.375163f, 1.161658f),
    float4(-10.661955f, 2.020148f, -9.533593f, 2.451968f),
    float4(-10.625394f, 1.027602f, -10.205761f, 2.056709f),
    float4(-9.831357f, 1.125097f, -9.411724f, 2.154204f),
    float4(-0.210007f, -8.434004f, 2.208664f, -7.843753f),
    float4(-0.313596f, -7.590339f, 2.105075f, -7.000089f),
    float4(-0.277035f, -8.136240f, 0.087757f, -7.553779f),
    float4(1.807312f, -7.880314f, 2.172104f, -7.297853f),
};

// The cottage's turn about the vertical through its origin.
HouseTurn cottageFrame() {
    return {cottageTurn.y, cottageTurn.x, cottageOrigin.xz};
}

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

// The plank door, in world metres in the cottage's frame, hung on the
// doorway's west jamb. open runs from 0, shut over the doorway in front of
// the wall, to 1, swung in against the lobby's west wall.
HousePart cottageDoor(float open) {
    return houseDoorLeaf(cottageOrigin + float3(-cottageDoorHalfWidth,
            cottageFloor, -cottageHalf.y), float2(1.0f, 0.0f),
        float2(0.0f, -1.0f), float3(2.0f * cottageDoorHalfWidth,
            cottageDoorHeight, 0.06f), open * 0.5f * M_PI_F, houseBattens);
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
    // Foundation, walls with two storeys of windows either side of the
    // doorway, a dark lobby behind it, a plank door and its step. The walls
    // are a west and an east block, each with two windows across the front
    // and back and three along its gable end, joined behind the lobby and
    // over the door.
    const float W = cottageDoorHalfWidth, D = cottageLobbyDepth;
    addHouseWorldPart(house, cottageBox(float3(-h.x - 0.2f, -0.3f,
        -h.y - 0.2f), float3(h.x + 0.2f, F, h.y + 0.2f), houseStone));
    float2 clad = float2(F + 0.1f, E - 0.1f) + o.y - houseOrigin.y;
    for (uint side = 0u; side < 2u; ++side) {
        HousePart walls = cottageBox(float3(side == 0u ? -h.x : W, F, -h.y),
            float3(side == 0u ? -W : h.x, E, h.y), houseSiding);
        houseWindows(walls, float2(2.0f, 3.0f), float2(0.5f, 0.85f), 0.45f,
            2.0f, 1.45f, 0.7f);
        uint wallIndex = house.counts.x;
        addHouseWorldPart(house, walls);
        addLooseClapboards(house, wallIndex, float3(0.0f, 0.0f, -1.0f), clad,
            float2(o.x - 0.9f, o.x + 0.9f), side == 0u ? 2u : 1u);
        if (side == 1u)
            addLooseClapboards(house, wallIndex, float3(1.0f, 0.0f, 0.0f),
                clad, houseNoSkip, 1u);
    }
    // The lobby's back wall is painted panelling; the wall over the door
    // is clad like the rest.
    addHouseWorldPart(house, cottageBox(float3(-W, F, -h.y + D),
        float3(W, E, h.y), houseTrim));
    addHouseWorldPart(house, cottageBox(float3(-W, F + cottageDoorHeight,
        -h.y), float3(W, E, -h.y + D), houseSiding));
    house.doorParts.z = house.counts.x;
    addHouseWorldPart(house, cottageDoor(0.0f));
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

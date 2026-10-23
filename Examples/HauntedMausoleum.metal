// The mausoleums for HauntedHouseProgram.metal: one stands at the back of
// each graveyard plot, at the end of its aisle, facing the gate.
//
// A Greek revival tomb of pale limestone, at its real size: three steps up
// to a plinth, four plastered round columns on stone bases before the door
// carrying a plastered, inscribed entablature, and a plastered pediment
// under a stone raking cornice with a cross on its
// apex and finials on its corners. Iron bars close the doorway over a dark
// recess that glows while the house is haunted. Nobody enters it: the
// graveyard grid hands its footprint to the walker like a grave's.
//
// HauntedStreet.metal copies it five times its size across the road from
// the house, where the walker climbs its steps onto the plinth through
// the footing and walls below. One of those copies stands ruined: the back
// corner of its cella's +x side has fallen in, from the plinth to high up
// both walls, and the stone lies heaped in the gap, so a visitor can climb
// the heap into the cella's hollow hall.
//
// Parts are in world metres around the doorway's foot: x across the front,
// y up from the levelled ground, z back from the door. The tomb faces -z.

constant float mausoleumPlinthTop = 0.6f;
constant float mausoleumPlinthFront = -2.55f;
constant float mausoleumStepRun = 0.32f;
constant uint mausoleumStepCount = 3u;
constant float mausoleumColumnZ = -1.75f;
constant float mausoleumColumnX[2] = {0.95f, 2.6f};
constant float mausoleumEntablature = 4.3f;     // top of the capitals
constant float mausoleumCornice = 5.16f;        // top of the cornice
constant float mausoleumPedimentFront = -2.2f;
constant float mausoleumHalfSpan = 2.95f;       // the pediment's
constant float mausoleumPedimentRise = 1.4f;

// The footprint's lower and upper corners in x and z: from the bottom step
// to the back of the plinth. The street's copies use it as their table of
// obstacles.
constant uint mausoleumObstacleCount = 1u;
constant float4 mausoleumObstacles[mausoleumObstacleCount] = {
    float4(-3.2f, mausoleumPlinthFront
        - mausoleumStepRun * float(mausoleumStepCount), 3.2f, 5.7f)};

float4 mausoleumFootprint() {
    return mausoleumObstacles[0];
}

// Limestone without the small tomb's lettering. Engraved parts set rows to
// one line on their front face: its height above the part's foot, its half
// width and its letter size.
HousePart mausoleumStone(float3 lower, float3 upper) {
    HousePart part = houseBox(lower, upper, houseGrave);
    part.rows = float4(0.0f);
    return part;
}

// A column on its stone base under its stone capital, standing on the
// plinth at x and z around o: a solid round shaft rendered in plaster, with
// a plastered ring at its foot and its neck.
void addMausoleumColumn(device HouseModel &house, float3 o, float x,
    float z) {
    const float P = mausoleumPlinthTop, top = mausoleumEntablature - 0.22f;
    const float bottom = P + 0.2f, radius = 0.26f;
    const float3 up = float3(0.0f, 1.0f, 0.0f);
    float3 c = o + float3(x, 0.0f, z);
    addHouseWorldPart(house, mausoleumStone(c + float3(-0.34f, P, -0.34f),
        c + float3(0.34f, bottom, 0.34f)));
    addHouseWorldPart(house, houseRound(c + up * (0.5f * (bottom + top)), up,
        0.5f * (top - bottom), radius, housePlasterColumn));
    addHouseWorldPart(house, houseRound(c + up * (bottom + 0.06f), up, 0.06f,
        radius + 0.045f, housePlasterColumn));
    addHouseWorldPart(house, houseRound(c + up * (top - 0.05f), up, 0.05f,
        radius + 0.03f, housePlasterColumn));
    addHouseWorldPart(house, mausoleumStone(c + float3(-0.36f, top, -0.36f),
        c + float3(0.36f, mausoleumEntablature, 0.36f)));
}

// The parts addMausoleum adds, by their place in its order, that the ruin
// replaces: the plinth and its cap. The giant copies replace their cella,
// pilasters, doorway frame and roof separately with breakable pieces.
constant uint mausoleumPlinthPart = 3u;
constant uint mausoleumCapPart = 4u;
constant uint mausoleumCellaPart = 5u;
constant uint mausoleumPilasterFirstPart = 6u;
constant uint mausoleumDoorFrameFirstPart = 14u;
constant uint mausoleumRoofFirstPart = 37u;
constant uint mausoleumRoofLastPart = 41u;
constant uint mausoleumRoofOrnamentFirstPart = 42u;

// The whole tomb around the doorway's foot o.
void addMausoleum(device HouseModel &house, float3 o) {
    const float P = mausoleumPlinthTop, E = mausoleumEntablature;
    const float C = mausoleumCornice, front = mausoleumPlinthFront;
    // Steps, the plinth and its projecting cap.
    for (uint k = 1u; k <= mausoleumStepCount; ++k)
        addHouseWorldPart(house, mausoleumStone(
            o + float3(-2.4f, -0.2f, front - mausoleumStepRun * float(k)),
            o + float3(2.4f, P - 0.15f * float(k),
                front - mausoleumStepRun * float(k - 1u))));
    addHouseWorldPart(house, mausoleumStone(o + float3(-3.15f, -0.2f, front),
        o + float3(3.15f, P - 0.1f, 5.65f)));
    addHouseWorldPart(house, mausoleumStone(
        o + float3(-3.2f, P - 0.1f, front - 0.05f), o + float3(3.2f, P, 5.7f)));
    // The cella, and its doorway: a dark recess behind iron bars in a
    // stone frame.
    addHouseWorldPart(house, mausoleumStone(o + float3(-2.55f, P, 0.0f),
        o + float3(2.55f, E, 5.3f)));
    // Pilasters divide its long sides into two bays.
    for (uint k = 0u; k < 6u; ++k) {
        float s = k < 3u ? -1.0f : 1.0f;
        float z = 2.44f * float(k % 3u);
        addHouseWorldPart(house, mausoleumStone(
            o + float3(min(s * 2.55f, s * 2.67f), P, z),
            o + float3(max(s * 2.55f, s * 2.67f), E, z + 0.42f)));
    }
    HousePart recess = mausoleumStone(o + float3(-0.62f, P, -0.003f),
        o + float3(0.62f, 3.15f, 0.0f));
    recess.windows.w = -1.0f;
    addHouseWorldPart(house, recess);
    addHouseWorldPart(house, houseBox(o + float3(-0.62f, P, -0.07f),
        o + float3(0.62f, 3.15f, -0.04f), houseIron));
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        addHouseWorldPart(house, mausoleumStone(
            o + float3(min(s * 0.62f, s * 0.85f), P, -0.1f),
            o + float3(max(s * 0.62f, s * 0.85f), 3.15f, 0.0f)));
    }
    addHouseWorldPart(house, mausoleumStone(o + float3(-0.95f, 3.15f, -0.12f),
        o + float3(0.95f, 3.5f, 0.0f)));
    // The portico's columns.
    for (uint i = 0u; i < 4u; ++i)
        addMausoleumColumn(house, o,
            (i < 2u ? -1.0f : 1.0f) * mausoleumColumnX[i % 2u],
            mausoleumColumnZ);
    // The plastered entablature, inscribed across its front, and the stone
    // cornice.
    HousePart entablature = houseBox(
        o + float3(-mausoleumHalfSpan, E, mausoleumPedimentFront),
        o + float3(mausoleumHalfSpan, C - 0.16f, 5.45f), housePlaster);
    entablature.rows = float4(0.38f, 2.0f, 0.14f, 0.0f);
    addHouseWorldPart(house, entablature);
    addHouseWorldPart(house, mausoleumStone(o + float3(-3.1f, C - 0.16f, -2.38f),
        o + float3(3.1f, C, 5.62f)));
    // The plastered pediment, and the raking cornice as a sloping stone slab
    // over each side of it, 20 cm thick and overhanging its face and eaves.
    HousePart pediment = houseGable(
        o + float3(-mausoleumHalfSpan, C, mausoleumPedimentFront),
        o + float3(mausoleumHalfSpan, C + mausoleumPedimentRise, 5.45f), true,
        housePlaster);
    pediment.rows = float4(0.0f);
    addHouseWorldPart(house, pediment);
    float slope = mausoleumPedimentRise / mausoleumHalfSpan;
    float apex = C + mausoleumPedimentRise;
    for (uint side = 0u; side < 2u; ++side) {
        HousePart slab = houseRoofSheet(float2(o.x, o.y + apex + 0.2f),
            side == 0u ? -1.0f : 1.0f, 3.1f, slope, 0.2f,
            float2(o.z - 2.38f, o.z + 5.62f), houseGrave);
        slab.rows = float4(0.0f);
        addHouseWorldPart(house, slab);
    }
    // A cross on the apex, and a finial on each corner of the roof.
    addHouseWorldPart(house, mausoleumStone(o + float3(-0.07f, apex, -2.36f),
        o + float3(0.07f, apex + 1.25f, -2.2f)));
    addHouseWorldPart(house, mausoleumStone(
        o + float3(-0.3f, apex + 0.85f, -2.36f),
        o + float3(0.3f, apex + 0.97f, -2.2f)));
    for (uint k = 0u; k < 4u; ++k) {
        float x = ((k & 1u) != 0u ? 1.0f : -1.0f) * 2.95f;
        float z = (k & 2u) != 0u ? 5.47f : -2.23f;
        HousePart finial = houseSpire(o + float3(x - 0.16f, C, z - 0.16f),
            o + float3(x + 0.16f, C + 0.85f, z + 0.16f), float2(0.0f),
            houseGrave);
        finial.rows = float4(0.0f);
        addHouseWorldPart(house, finial);
    }
}

// ------------------------------------------------------------------- ruin
// The ruined tomb, in the same frame as addMausoleum: the walls stand 0.3 m
// thick around a hollow hall, the plinth's +x back corner has gone from
// x = 1 and z = 3.6 on, and the cella's +x wall from z = 3 and its back
// wall from x = 0.6 are open below a broken edge that climbs toward the
// corner. The fallen stone lies in a heap that rises from the ground
// beyond the plinth to the hall's floor.

// The ruin's hall inside its walls: x and z of its lower and upper
// corners. Its floor is the plinth's top and its ceiling the
// entablature's underside.
constant float4 mausoleumHall = float4(-2.25f, 0.3f, 2.25f, 5.0f);

// A block of the ruin: a plain box, a piece hanging from the entablature
// whose broken underside slopes by tilt across x and z, or a fallen block
// whose top slopes by tilt and whose downhill corner is knocked off.
constant uint mausoleumBlockPlain = 0u;
constant uint mausoleumBlockHanging = 1u;
constant uint mausoleumBlockFallen = 2u;

struct MausoleumBlock {
    float4 lower;   // xyz, and the shape in w
    float4 upper;   // xyz, unused
    float2 tilt;
};

// The first blocks replace the copied plinth and cap. The cella, corner
// pilasters and roof use breakable pieces; the rest is fallen rubble.
constant uint mausoleumRuinReplaced = 2u;
constant uint mausoleumRuinReplaces[mausoleumRuinReplaced] = {
    mausoleumPlinthPart, mausoleumCapPart};

constant uint mausoleumRuinBlockCount = 23u;
constant MausoleumBlock mausoleumRuinBlocks[mausoleumRuinBlockCount] = {
    // The plinth and its cap short of the gap.
    {float4(-3.15f, -0.2f, -2.55f, 0.0f), float4(1.0f, 0.5f, 5.65f, 0.0f),
        float2(0.0f)},
    {float4(-3.2f, 0.5f, -2.6f, 0.0f), float4(1.0f, 0.6f, 5.7f, 0.0f),
        float2(0.0f)},
    // The plinth and its cap in front of the gap.
    {float4(1.0f, -0.2f, -2.55f, 0.0f), float4(3.15f, 0.5f, 3.6f, 0.0f),
        float2(0.0f)},
    {float4(1.0f, 0.5f, -2.6f, 0.0f), float4(3.2f, 0.6f, 3.6f, 0.0f),
        float2(0.0f)},
    // The heap, from the hall's floor down to the ground outside.
    {float4(1.0f, -0.05f, 3.6f, 2.0f), float4(1.7f, 0.57f, 4.3f, 0.0f),
        float2(0.1f, 0.08f)},
    {float4(1.6f, -0.05f, 3.6f, 2.0f), float4(2.25f, 0.55f, 4.85f, 0.0f),
        float2(0.12f, -0.06f)},
    {float4(1.0f, -0.05f, 4.25f, 2.0f), float4(1.65f, 0.56f, 4.85f, 0.0f),
        float2(-0.08f, 0.12f)},
    {float4(2.2f, -0.05f, 3.6f, 2.0f), float4(2.65f, 0.47f, 4.6f, 0.0f),
        float2(0.15f, 0.05f)},
    {float4(2.15f, -0.05f, 4.55f, 2.0f), float4(2.65f, 0.46f, 5.25f, 0.0f),
        float2(0.1f, 0.12f)},
    {float4(1.0f, -0.05f, 4.8f, 2.0f), float4(2.2f, 0.45f, 5.25f, 0.0f),
        float2(-0.06f, 0.14f)},
    {float4(2.6f, -0.05f, 3.6f, 2.0f), float4(3.05f, 0.34f, 4.7f, 0.0f),
        float2(0.18f, -0.05f)},
    {float4(2.6f, -0.05f, 4.65f, 2.0f), float4(3.05f, 0.33f, 5.55f, 0.0f),
        float2(0.15f, 0.15f)},
    {float4(1.0f, -0.05f, 5.2f, 2.0f), float4(2.65f, 0.33f, 5.55f, 0.0f),
        float2(0.05f, 0.18f)},
    {float4(3.0f, -0.05f, 3.6f, 2.0f), float4(3.45f, 0.21f, 5.0f, 0.0f),
        float2(0.2f, 0.04f)},
    {float4(3.0f, -0.05f, 4.95f, 2.0f), float4(3.45f, 0.2f, 5.9f, 0.0f),
        float2(0.16f, 0.12f)},
    {float4(1.0f, -0.05f, 5.5f, 2.0f), float4(3.05f, 0.2f, 5.9f, 0.0f),
        float2(-0.04f, 0.2f)},
    {float4(3.4f, -0.05f, 3.6f, 2.0f), float4(3.85f, 0.09f, 6.2f, 0.0f),
        float2(0.15f, 0.0f)},
    {float4(1.0f, -0.05f, 5.85f, 2.0f), float4(3.45f, 0.08f, 6.2f, 0.0f),
        float2(0.02f, 0.15f)},
    // Blocks thrown farther: two on the heap, three on the ground beside
    // the plinth, the last a length of the fallen pilaster.
    {float4(2.7f, 0.25f, 4.0f, 2.0f), float4(3.25f, 0.55f, 4.45f, 0.0f),
        float2(0.35f, -0.2f)},
    {float4(1.3f, 0.3f, 5.3f, 2.0f), float4(1.9f, 0.52f, 5.75f, 0.0f),
        float2(-0.3f, 0.25f)},
    {float4(3.9f, -0.05f, 4.4f, 2.0f), float4(4.35f, 0.18f, 4.95f, 0.0f),
        float2(0.3f, 0.2f)},
    {float4(3.6f, -0.05f, 2.3f, 2.0f), float4(3.95f, 0.12f, 3.2f, 0.0f),
        float2(0.25f, -0.1f)},
    {float4(3.3f, -0.05f, 1.2f, 2.0f), float4(3.48f, 0.1f, 2.0f, 0.0f),
        float2(0.2f, 0.05f)},
};

// Ruin block k around the doorway's foot o, as a part.
HousePart mausoleumRuinPart(uint k, float3 o) {
    MausoleumBlock block = mausoleumRuinBlocks[min(k,
        mausoleumRuinBlockCount - 1u)];
    float3 lower = block.lower.xyz, upper = block.upper.xyz;
    HousePart part = mausoleumStone(o + lower, o + upper);
    uint shape = uint(block.lower.w);
    if (shape == mausoleumBlockPlain) return part;
    float2 extent = 0.5f * (upper.xz - lower.xz);
    float2 centre = 0.5f * (upper.xz + lower.xz);
    float2 t = block.tilt;
    float reach = abs(t.x) * extent.x + abs(t.y) * extent.y;
    if (shape == mausoleumBlockHanging) {
        // The underside's lowest corner reaches the block's foot.
        houseCut(part, float3(t.x, -1.0f, t.y),
            o + float3(centre.x, lower.y + reach, centre.y));
        return part;
    }
    // The top's highest corner reaches the block's top, and the corner
    // downhill of it is knocked off.
    houseCut(part, float3(t.x, 1.0f, t.y),
        o + float3(centre.x, upper.y - reach, centre.y));
    float2 down = select(float2(-1.0f), float2(1.0f), t >= 0.0f);
    houseCut(part, float3(down.x, 0.35f, down.y),
        o + float3(centre.x + down.x * 0.4f * extent.x, upper.y,
            centre.y + down.y * 0.4f * extent.y));
    return part;
}

// ---------------------------------------------------------------- walking
// What the walker stands on and meets on a copy, in the same frame:
// rectangles in x and z, each for the whole tomb, the intact one or the
// ruined one. Footing gives the height of its top; the ruin's heap rises
// in tiers no more than a step apart, under its tilted blocks.
constant uint mausoleumIntact = 1u;
constant uint mausoleumRuined = 2u;

struct MausoleumFooting {
    float4 rect;    // lower x and z, upper x and z
    float top;
    uint tombs;     // 0 for both, or mausoleumIntact or mausoleumRuined
};

constant uint mausoleumFootingCount = 14u;
constant MausoleumFooting mausoleumFootings[mausoleumFootingCount] = {
    {float4(-2.4f, -2.87f, 2.4f, -2.55f), 0.45f, 0u},
    {float4(-2.4f, -3.19f, 2.4f, -2.87f), 0.3f, 0u},
    {float4(-2.4f, -3.51f, 2.4f, -3.19f), 0.15f, 0u},
    {float4(-3.2f, -2.6f, 3.2f, 5.7f), 0.6f, mausoleumIntact},
    {float4(-3.2f, -2.6f, 1.0f, 5.7f), 0.6f, mausoleumRuined},
    {float4(1.0f, -2.6f, 3.2f, 3.6f), 0.6f, mausoleumRuined},
    {float4(1.0f, 3.6f, 2.25f, 4.85f), 0.53f, mausoleumRuined},
    {float4(1.0f, 3.6f, 2.65f, 5.25f), 0.43f, mausoleumRuined},
    {float4(1.0f, 3.6f, 3.05f, 5.55f), 0.31f, mausoleumRuined},
    {float4(1.0f, 3.6f, 3.45f, 5.9f), 0.18f, mausoleumRuined},
    {float4(1.0f, 3.6f, 3.85f, 6.2f), 0.07f, mausoleumRuined},
    {float4(3.9f, 4.4f, 4.35f, 4.95f), 0.16f, mausoleumRuined},
    {float4(3.6f, 2.3f, 3.95f, 3.2f), 0.1f, mausoleumRuined},
    {float4(3.3f, 1.2f, 3.48f, 2.0f), 0.08f, mausoleumRuined},
};

// The portico's columns stay fixed. The cella walls use the same removable
// masonry stones for both rendering and collision in HauntedStreet.metal.
constant uint mausoleumWallCount = 4u;
constant MausoleumFooting mausoleumWalls[mausoleumWallCount] = {
    {float4(-2.96f, -2.11f, -2.24f, -1.39f), 0.0f, 0u},
    {float4(-1.31f, -2.11f, -0.59f, -1.39f), 0.0f, 0u},
    {float4(0.59f, -2.11f, 1.31f, -1.39f), 0.0f, 0u},
    {float4(2.24f, -2.11f, 2.96f, -1.39f), 0.0f, 0u},
};

bool mausoleumHas(MausoleumFooting f, uint tomb, float2 p, float pad) {
    return (f.tombs == 0u || f.tombs == tomb)
        && all(p > f.rect.xy - pad) && all(p < f.rect.zw + pad);
}

// The height of the highest footing of tomb (mausoleumIntact or
// mausoleumRuined) over p, in metres above the doorway's foot, or below
// the ground where there is none.
float mausoleumStand(float2 p, uint tomb) {
    float top = -1.0e3f;
    for (uint i = 0u; i < mausoleumFootingCount; ++i)
        if (mausoleumHas(mausoleumFootings[i], tomb, p, 0.0f))
            top = max(top, mausoleumFootings[i].top);
    return top;
}

// True where a wall keeps out a walker padded by pad, or a footing stands
// higher than climb above their feet at foot.
bool mausoleumBlocked(float2 p, uint tomb, float foot, float climb,
    float pad) {
    for (uint i = 0u; i < mausoleumWallCount; ++i)
        if (mausoleumHas(mausoleumWalls[i], tomb, p, pad)) return true;
    for (uint i = 0u; i < mausoleumFootingCount; ++i)
        if (mausoleumFootings[i].top > foot + climb
            && mausoleumHas(mausoleumFootings[i], tomb, p, pad)) return true;
    return false;
}

// A mausoleum at the back of each plot, each traced as a group of its own:
// the last two groups of the house's site, the west plot's first.
void buildMausoleums(device HouseModel &house) {
    for (uint plot = 0u; plot < 2u; ++plot) {
        beginHouseGroup(house);
        addMausoleum(house, houseWorld(float3(houseYardAisle(plot), 0.0f,
            houseYardMausoleumZ)));
    }
}

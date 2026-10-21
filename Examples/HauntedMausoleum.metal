// The mausoleums for HauntedHouseProgram.metal: one stands at the back of
// each graveyard plot, at the end of its aisle, facing the gate.
//
// A Greek revival tomb of pale limestone, at its real size: three steps up
// to a plinth, four chamfered columns before the door carrying an inscribed
// entablature, and a pediment under a raking cornice with a cross on its
// apex and finials on its corners. Iron bars close the doorway over a dark
// recess that glows while the house is haunted. Nobody enters it: the
// graveyard grid hands its footprint to the walker like a grave's.
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

// A column on its base under its capital, standing on the plinth at x and z
// around o. The shaft's corners are chamfered.
void addMausoleumColumn(device HouseModel &house, float3 o, float x,
    float z) {
    const float P = mausoleumPlinthTop, top = mausoleumEntablature - 0.22f;
    float3 c = o + float3(x, 0.0f, z);
    addHouseWorldPart(house, mausoleumStone(c + float3(-0.34f, P, -0.34f),
        c + float3(0.34f, P + 0.2f, 0.34f)));
    HousePart shaft = mausoleumStone(c + float3(-0.25f, P + 0.2f, -0.25f),
        c + float3(0.25f, top, 0.25f));
    for (uint k = 0u; k < 4u; ++k) {
        float2 corner = float2((k & 1u) != 0u ? 1.0f : -1.0f,
            (k & 2u) != 0u ? 1.0f : -1.0f);
        houseCut(shaft, float3(corner.x, 0.0f, corner.y),
            c + float3(corner.x * 0.25f, 0.0f, corner.y * 0.18f));
    }
    addHouseWorldPart(house, shaft);
    addHouseWorldPart(house, mausoleumStone(c + float3(-0.36f, top, -0.36f),
        c + float3(0.36f, mausoleumEntablature, 0.36f)));
}

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
    // The entablature, inscribed across its front, and the cornice.
    HousePart entablature = mausoleumStone(
        o + float3(-mausoleumHalfSpan, E, mausoleumPedimentFront),
        o + float3(mausoleumHalfSpan, C - 0.16f, 5.45f));
    entablature.rows = float4(0.38f, 2.0f, 0.14f, 0.0f);
    addHouseWorldPart(house, entablature);
    addHouseWorldPart(house, mausoleumStone(o + float3(-3.1f, C - 0.16f, -2.38f),
        o + float3(3.1f, C, 5.62f)));
    // The pediment, and the raking cornice as a sloping slab over each side
    // of it, 20 cm thick and overhanging its face and eaves.
    addHouseWorldPart(house, houseGable(
        o + float3(-mausoleumHalfSpan, C, mausoleumPedimentFront),
        o + float3(mausoleumHalfSpan, C + mausoleumPedimentRise, 5.45f), true,
        houseGrave));
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

// A mausoleum at the back of each plot, each traced as a group of its own:
// the last two groups of the house's site, the west plot's first.
void buildMausoleums(device HouseModel &house) {
    for (uint plot = 0u; plot < 2u; ++plot) {
        beginHouseGroup(house);
        addMausoleum(house, houseWorld(float3(houseYardAisle(plot), 0.0f,
            houseYardMausoleumZ)));
    }
}

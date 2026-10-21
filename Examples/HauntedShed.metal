// The sheds for HauntedHouseProgram.metal: a large closed barn and a large
// half-open shed on a levelled yard behind the house, reached through the
// gate in the back of the house's lot.
//
// One builder raises both from a ShedSpec, at their real size: board and
// batten walls on a stone sill, a pitched roof of rusted corrugated iron
// with one sheet to each bay and side and a few torn away, and plank trusses
// under it. The barn is closed but for a sliding door in its south gable,
// one leaf drawn aside; inside is a bare hall, lit only by the Earth through
// its door and the holes in its roof. The shed stands open to the yard on
// its west side, its roof carried on posts, with crates against its back
// wall.
//
// Layout is in metres in the yard's frame: x east, z north from
// shedYardOrigin, y up from the levelled yard. Both sheds' ridges run north.

constant float3 shedYardOrigin = float3(0.0f, -2.3f, 172.0f);
constant float2 shedYardLower = float2(-46.0f, -26.0f);
constant float2 shedYardUpper = float2(46.0f, 24.0f);

constant uint shedBays = 6u;
constant float shedWall = 0.15f;      // the boards' depth
constant float shedSill = 0.35f;      // top of the stone sill under them
constant float shedOverhang = 0.45f;  // of the roof, at eaves and gables

constant float barnX = -22.0f;
constant float barnZ = -2.0f;
constant float barnHalfSpan = 7.0f;
constant float barnHalfLength = 13.0f;
constant float barnDoor = 5.0f;       // width of the south doorway

constant float openShedX = 22.0f;
constant float openShedZ = 0.0f;
constant float openShedHalfSpan = 5.5f;
constant float openShedHalfLength = 12.0f;
constant float openShedPost = 0.15f;  // half the width of a post
constant float openShedPostPitch = 2.0f * (openShedHalfLength - openShedPost)
    / float(shedBays);

struct ShedSpec {
    float2 centre;      // yard x and z of the middle of the floor
    float2 halfSize;    // half the span across x, half the length along z
    float eaves;        // top of the walls
    float rise;         // ridge above the eaves
    bool openWest;      // the west long side stands open on posts
    float door;         // width of the sliding doorway in the south gable
    uint torn;          // roof sheets left off: bit b for bay b of the west
                        // slope, bit 8 + b for the east
};

// The crates in the open shed: yard x and z of each footprint's lower and
// upper corners. Their heights are in openShedCrateTop.
constant uint openShedCrateCount = 4u;
constant float4 openShedCrates[openShedCrateCount] = {
    float4(25.6f, -8.0f, 27.2f, -6.6f), float4(25.9f, -5.9f, 27.2f, -4.8f),
    float4(24.0f, 3.0f, 25.0f, 4.2f), float4(25.7f, 5.0f, 27.2f, 6.6f),
};
constant float openShedCrateTop[openShedCrateCount] = {1.1f, 0.9f, 0.8f, 1.3f};

// Where the walker cannot go, in the yard's frame as lower and upper
// corners: the barn's west, east and north walls, its south wall either
// side of the doorway with a door leaf before each part, the shed's back
// wall and ends, its posts, and its crates as openShedCrates sets them.
constant uint shedObstacleCount = 19u;
constant float4 shedObstacles[shedObstacleCount] = {
    float4(barnX - barnHalfSpan - 0.1f, barnZ - barnHalfLength - 0.1f,
        barnX - barnHalfSpan + 0.2f, barnZ + barnHalfLength + 0.1f),
    float4(barnX + barnHalfSpan - 0.2f, barnZ - barnHalfLength - 0.1f,
        barnX + barnHalfSpan + 0.1f, barnZ + barnHalfLength + 0.1f),
    float4(barnX - barnHalfSpan - 0.1f, barnZ + barnHalfLength - 0.2f,
        barnX + barnHalfSpan + 0.1f, barnZ + barnHalfLength + 0.1f),
    float4(barnX - barnHalfSpan - 0.1f, barnZ - barnHalfLength - 0.15f,
        barnX, barnZ - barnHalfLength + 0.2f),
    float4(barnX + 0.5f * barnDoor, barnZ - barnHalfLength - 0.27f,
        barnX + barnHalfSpan + 0.1f, barnZ - barnHalfLength + 0.2f),
    float4(openShedX + openShedHalfSpan - 0.2f,
        openShedZ - openShedHalfLength - 0.1f,
        openShedX + openShedHalfSpan + 0.1f,
        openShedZ + openShedHalfLength + 0.1f),
    float4(openShedX - openShedHalfSpan - 0.1f,
        openShedZ - openShedHalfLength - 0.1f,
        openShedX + openShedHalfSpan + 0.1f,
        openShedZ - openShedHalfLength + 0.2f),
    float4(openShedX - openShedHalfSpan - 0.1f,
        openShedZ + openShedHalfLength - 0.2f,
        openShedX + openShedHalfSpan + 0.1f,
        openShedZ + openShedHalfLength + 0.1f),
    float4(openShedX - openShedHalfSpan, openShedZ - openShedHalfLength
        + 0.0f * openShedPostPitch, openShedX - openShedHalfSpan
        + 2.0f * openShedPost, openShedZ - openShedHalfLength
        + 2.0f * openShedPost + 0.0f * openShedPostPitch),
    float4(openShedX - openShedHalfSpan, openShedZ - openShedHalfLength
        + 1.0f * openShedPostPitch, openShedX - openShedHalfSpan
        + 2.0f * openShedPost, openShedZ - openShedHalfLength
        + 2.0f * openShedPost + 1.0f * openShedPostPitch),
    float4(openShedX - openShedHalfSpan, openShedZ - openShedHalfLength
        + 2.0f * openShedPostPitch, openShedX - openShedHalfSpan
        + 2.0f * openShedPost, openShedZ - openShedHalfLength
        + 2.0f * openShedPost + 2.0f * openShedPostPitch),
    float4(openShedX - openShedHalfSpan, openShedZ - openShedHalfLength
        + 3.0f * openShedPostPitch, openShedX - openShedHalfSpan
        + 2.0f * openShedPost, openShedZ - openShedHalfLength
        + 2.0f * openShedPost + 3.0f * openShedPostPitch),
    float4(openShedX - openShedHalfSpan, openShedZ - openShedHalfLength
        + 4.0f * openShedPostPitch, openShedX - openShedHalfSpan
        + 2.0f * openShedPost, openShedZ - openShedHalfLength
        + 2.0f * openShedPost + 4.0f * openShedPostPitch),
    float4(openShedX - openShedHalfSpan, openShedZ - openShedHalfLength
        + 5.0f * openShedPostPitch, openShedX - openShedHalfSpan
        + 2.0f * openShedPost, openShedZ - openShedHalfLength
        + 2.0f * openShedPost + 5.0f * openShedPostPitch),
    float4(openShedX - openShedHalfSpan, openShedZ - openShedHalfLength
        + 6.0f * openShedPostPitch, openShedX - openShedHalfSpan
        + 2.0f * openShedPost, openShedZ - openShedHalfLength
        + 2.0f * openShedPost + 6.0f * openShedPostPitch),
    float4(25.6f, -8.0f, 27.2f, -6.6f), float4(25.9f, -5.9f, 27.2f, -4.8f),
    float4(24.0f, 3.0f, 25.0f, 4.2f), float4(25.7f, 5.0f, 27.2f, 6.6f),
};

// Weight of the natural terrain around the yard: 0 on it and 2 m beyond,
// rising to 1 another 18 m out.
float shedYardBlend(float2 p) {
    return buildingPadBlend(p, shedYardOrigin.xz, shedYardLower,
        shedYardUpper, 2.0f, 18.0f);
}

// True where p, in world x and z, lies on the yard or within a metre of it.
bool shedYardHolds(float2 p) {
    float2 local = p - shedYardOrigin.xz;
    return all(local > shedYardLower - 1.0f) && all(local < shedYardUpper + 1.0f);
}

// A box in the yard's frame.
void addShedBox(device HouseModel &house, float3 lower, float3 upper,
    uint style) {
    addHouseWorldPart(house, houseBox(shedYardOrigin + lower,
        shedYardOrigin + upper, style));
}

// A wall of boards on its stone sill, from lower to upper in the yard's
// frame, its sill a little wider and buried.
void addShedWall(device HouseModel &house, float3 lower, float3 upper) {
    float3 grow = upper.x - lower.x < upper.z - lower.z
        ? float3(0.06f, 0.0f, 0.1f) : float3(0.1f, 0.0f, 0.06f);
    addShedBox(house, float3(lower.x, -0.2f, lower.z) - grow,
        float3(upper.x, shedSill, upper.z) + grow, houseStone);
    addShedBox(house, float3(lower.x, shedSill, lower.z), upper, houseBattens);
}

void buildShed(device HouseModel &house, ShedSpec shed) {
    beginHouseGroup(house);
    const float t = shedWall;
    float2 h = shed.halfSize;
    float E = shed.eaves, R = shed.rise;
    float3 o = shedYardOrigin + float3(shed.centre.x, 0.0f, shed.centre.y);
    float3 c = float3(shed.centre.x, 0.0f, shed.centre.y);
    // The long walls, or posts under an eaves beam on the open side.
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        if (side == 0u && shed.openWest) {
            for (uint k = 0u; k <= shedBays; ++k) {
                float z = -h.y + openShedPost + float(k) * openShedPostPitch;
                addHouseBoard(house, o + float3(-h.x + openShedPost,
                        0.5f * E - 0.05f, z), float3(0.0f, 1.0f, 0.0f),
                    float3(1.0f, 0.0f, 0.0f),
                    float3(E + 0.1f, 2.0f * openShedPost, 2.0f * openShedPost),
                    houseNailsAtEnds);
            }
            addHouseBoard(house, o + float3(-h.x + openShedPost, E - 0.15f,
                    0.0f), float3(0.0f, 0.0f, 1.0f), float3(1.0f, 0.0f, 0.0f),
                float3(2.0f * h.y + 0.3f, 0.3f, 0.24f), houseNailsAtEnds);
            continue;
        }
        addShedWall(house, c + float3(min(s * h.x, s * (h.x - t)), 0.0f, -h.y),
            c + float3(max(s * h.x, s * (h.x - t)), E, h.y));
    }
    // The gable ends, the south one with its doorway: two sliding leaves
    // on a rail, one drawn aside.
    for (uint end = 0u; end < 2u; ++end) {
        float e = end == 0u ? -1.0f : 1.0f;
        float z0 = min(e * h.y, e * (h.y - t)), z1 = max(e * h.y, e * (h.y - t));
        if (end == 0u && shed.door > 0.0f) {
            float d = 0.5f * shed.door, top = min(E - 0.7f, 4.2f);
            addShedWall(house, c + float3(-h.x, 0.0f, z0),
                c + float3(-d, E, z1));
            addShedWall(house, c + float3(d, 0.0f, z0), c + float3(h.x, E, z1));
            addShedBox(house, c + float3(-d, top, z0), c + float3(d, E, z1),
                houseBattens);
            float leaf = d + 0.15f;
            addShedBox(house, c + float3(-leaf, 0.05f, -h.y - 0.13f),
                c + float3(0.0f, top + 0.15f, -h.y - 0.03f), houseBattens);
            addShedBox(house, c + float3(d, 0.05f, -h.y - 0.25f),
                c + float3(d + leaf, top + 0.15f, -h.y - 0.15f), houseBattens);
            addHouseBoard(house, o + float3(0.5f * d, top + 0.3f,
                    -h.y - 0.09f), float3(1.0f, 0.0f, 0.0f),
                float3(0.0f, 0.0f, 1.0f), float3(d + 2.0f * leaf + 0.1f, 0.14f,
                    0.08f), houseNailsAtEnds);
        } else {
            addShedWall(house, c + float3(-h.x, 0.0f, z0), c + float3(h.x, E, z1));
        }
        addHouseWorldPart(house, houseGable(o + float3(-h.x, E, z0),
            o + float3(h.x, E + R, z1), true, houseBattens));
    }
    // Plank trusses at each bay line: a tie beam, two rafters, a king post.
    float rafter = length(float2(h.x, R));
    for (uint k = 1u; k < shedBays; ++k) {
        float z = -h.y + 2.0f * h.y * float(k) / float(shedBays);
        addHouseBoard(house, o + float3(0.0f, E - 0.12f, z),
            float3(1.0f, 0.0f, 0.0f), float3(0.0f, 0.0f, 1.0f),
            float3(2.0f * h.x - 0.3f, 0.24f, 0.1f), houseNailsAtEnds);
        for (uint side = 0u; side < 2u; ++side) {
            float s = side == 0u ? -1.0f : 1.0f;
            addHouseBoard(house, o + float3(0.5f * s * h.x, E + 0.5f * R - 0.12f,
                    z), float3(-s * h.x, R, 0.0f), float3(0.0f, 0.0f, 1.0f),
                float3(rafter - 0.1f, 0.2f, 0.08f), houseNailsAtEnds);
        }
        addHouseBoard(house, o + float3(0.0f, E + 0.5f * R - 0.1f, z),
            float3(0.0f, 1.0f, 0.0f), float3(0.0f, 0.0f, 1.0f),
            float3(R - 0.1f, 0.16f, 0.08f), houseNailsAtEnds);
    }
    // The roof: a corrugated sheet to each bay and side, overlapping a
    // little, over a ridge cap.
    float slope = R / h.x, reach = h.x + shedOverhang;
    float2 ridge = float2(o.x, o.y + E + R + 0.06f);
    float bay = 2.0f * (h.y + shedOverhang) / float(shedBays);
    for (uint side = 0u; side < 2u; ++side)
        for (uint b = 0u; b < shedBays; ++b) {
            if ((shed.torn & (1u << (b + 8u * side))) != 0u) continue;
            float z = o.z - h.y - shedOverhang + bay * float(b);
            addHouseWorldPart(house, houseRoofSheet(ridge,
                side == 0u ? -1.0f : 1.0f, reach, slope, 0.06f,
                float2(z, z + bay + 0.02f), houseCorrugated));
        }
    addShedBox(house, c + float3(-0.2f, E + R - 0.03f, -h.y - shedOverhang),
        c + float3(0.2f, E + R + 0.14f, h.y + shedOverhang), houseCorrugated);
}

// The barn, then the open shed with its crates and the planks left lying in
// the barn, each traced as a group of its own, in a site of their own.
void buildShedYard(device HouseModel &house) {
    beginBuildingSite(house);
    buildShed(house, {float2(barnX, barnZ), float2(barnHalfSpan,
        barnHalfLength), 5.5f, 4.5f, false, barnDoor,
        (1u << 2u) | (1u << (8u + 4u))});
    addHouseBoard(house, shedYardOrigin + float3(barnX - 3.0f, 0.04f,
            barnZ + 2.0f), float3(0.3f, 0.0f, 1.0f), float3(0.0f, 1.0f, 0.0f),
        float3(3.6f, 0.25f, 0.05f), houseNailsAtEnds);
    addHouseBoard(house, shedYardOrigin + float3(barnX + barnHalfSpan - 0.18f,
            1.5f, barnZ + 6.0f), float3(0.0f, 1.0f, 0.25f),
        float3(1.0f, 0.0f, 0.0f), float3(3.2f, 0.25f, 0.05f),
        houseNailsAtEnds);
    buildShed(house, {float2(openShedX, openShedZ), float2(openShedHalfSpan,
        openShedHalfLength), 4.6f, 2.6f, true, 0.0f, 1u << (8u + 1u)});
    for (uint i = 0u; i < openShedCrateCount; ++i) {
        float4 r = openShedCrates[i];
        addShedBox(house, float3(r.x, 0.0f, r.y),
            float3(r.z, openShedCrateTop[i], r.w), houseFurniture);
    }
    addShedBox(house, float3(25.8f, 1.1f, -7.8f), float3(27.0f, 2.0f, -6.8f),
        houseFurniture);
}

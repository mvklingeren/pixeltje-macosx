// The street for HauntedHouseProgram.metal: an asphalt road across the plain
// between the base exit and the cottage, drives to the buildings, copies of
// those buildings along it, and lantern posts beside it.
//
// The road runs east and west along streetRoadZ, graded to a level that
// follows the plain but skips its craters and boulders, and fades under the
// dust a few hundred metres out either way. A long drive climbs beside the
// flagstone path to the house's front fence, and a farm track runs round
// the east graveyard and behind the lot to the barn door; both are graded
// too. The cottage and its neighbours have short drives from the road.
//
// The neighbours are the cottage, the barn and the open shed again, at
// other sizes, standing on either side of the road and turned to face it,
// each a few degrees off square and set back by its own distance, as
// buildings older than the road would stand.
// Across the road from the house, two of the graveyards' mausoleums rise
// five times their size, either side of the base exit.
// buildStreet copies the originals' parts, already in the game buffer,
// through a scale and a quarter turn, then turns the copy's groups by its
// few degrees, so a copy is traced, shadowed and shaded like its original
// and adds no code to the traces. Loose clapboards
// stay on the original; a copy's clapboards are whole. The walker meets a
// copy's walls through its original's footprint table. Nobody goes in.
//
// Sixteen lantern posts six metres tall stand along the road, alternating
// sides: a rusted cast-iron post with a shepherd's crook, a big lantern
// hanging from its tip.
// Only the few near a point light it. They go out while the house is
// haunted.
//
// HauntedHouseProgram.metal includes this file after the buildings and
// before HauntedBuildings.metal, which calls it. Layout is in world metres:
// x east, y up, z north, away from the base.

float moonHeight(float2 p, int detail);

// ------------------------------------------------------------------ layout

constant float streetRoadZ = 38.0f;         // the road's centre line
constant float streetRoadHalfWidth = 3.5f;
constant float streetRoadEnd = 320.0f;      // |x| where the dust has it
constant float streetShoulder = 1.0f;       // graded beyond the paving
constant float streetGradeReach = 10.0f;    // the plain blends back over this
constant float streetPadMargin = 1.5f;
constant float streetPadReach = 12.0f;

// buildBuildings raises the house, the shed yard and the cottage as sites 0
// to 2, then buildStreet the copies north and south of the road and the
// lamps as sites 3 to 5. The mausoleums are the house site's last two
// groups.
constant uint streetHouseSite = 0u;
constant uint streetShedYardSite = 1u;
constant uint streetCottageSite = 2u;
constant uint streetLampSite = 5u;

// The road's level every 50 m from x = -350 to 350.
constant uint streetLevelCount = 15u;
constant float streetLevels[streetLevelCount] = {
    2.1f, 0.5f, 1.0f, -1.2f, -1.2f, -0.6f, 0.35f, 0.3f, 0.4f, 0.85f, 1.8f,
    2.7f, 2.4f, 1.0f, 2.4f};

// The road's level at x, eased through the table as a Catmull-Rom curve.
float streetLevel(float x) {
    float f = clamp((x + 350.0f) / 50.0f, 0.0f,
        float(streetLevelCount - 1u) - 0.001f);
    uint i = uint(f);
    float t = f - float(i);
    float a = streetLevels[max(i, 1u) - 1u], b = streetLevels[i];
    float c = streetLevels[i + 1u];
    float d = streetLevels[min(i + 2u, streetLevelCount - 1u)];
    return b + 0.5f * t * (c - a + t * (2.0f * a - 5.0f * b + 4.0f * c - d
        + t * (3.0f * (b - c) + d - a)));
}

// The long drives, leg by leg: the house's drive from the road to its front
// fence, then the farm track to the barn door. Each leg runs straight from
// one x and z at one level to the next; its corners and ends are round.
struct StreetLeg {
    float4 from;    // x, z, level, half width
    float4 to;      // x, z, level, how worn the paving is, 0 to 1
};

constant uint streetLegCount = 7u;
constant StreetLeg streetLegs[streetLegCount] = {
    {float4(7.0f, 38.0f, 0.3f, 1.7f), float4(7.0f, 68.0f, 0.3f, 0.45f)},
    {float4(7.0f, 68.0f, 0.3f, 1.7f), float4(7.0f, 92.0f, -2.3f, 0.45f)},
    {float4(72.0f, 38.0f, 0.55f, 1.6f), float4(72.0f, 70.0f, 1.2f, 0.8f)},
    {float4(72.0f, 70.0f, 1.2f, 1.6f), float4(72.0f, 92.0f, -1.7f, 0.8f)},
    {float4(72.0f, 92.0f, -1.7f, 1.6f), float4(72.0f, 151.0f, -2.3f, 0.8f)},
    {float4(72.0f, 151.0f, -2.3f, 1.6f), float4(-22.0f, 151.0f, -2.3f, 0.8f)},
    {float4(-22.0f, 151.0f, -2.3f, 1.6f), float4(-22.0f, 155.0f, -2.3f, 0.8f)},
};

// ------------------------------------------------------------- properties
// The buildings that front the road: the cottage itself, then the copies.
// A copy is an original moved so its floor's centre stands at `at`, scaled,
// and turned by quarter turns: once turns the original's west side to face
// south, twice turns it about. The cottages lead the table, so their porch
// lanterns are the first streetCottageCount.
constant uint streetCottage = 0u;
constant uint streetBarn = 1u;      // the shed yard's first group
constant uint streetOpenShed = 2u;  // and its second
constant uint streetTomb = 3u;      // the west plot's mausoleum

struct StreetProperty {
    float4 at;      // world centre of the floor, scale
    uint kind;
    uint turns;     // quarter turns
};

constant uint streetPropertyCount = 9u;
constant uint streetCottageCount = 4u;
constant StreetProperty streetProperties[streetPropertyCount] = {
    {float4(cottageOrigin, 1.0f), streetCottage, 0u},
    {float4(36.0f, 0.45f, 57.5f, 0.9f), streetCottage, 0u},
    {float4(-124.0f, -0.85f, 55.0f, 0.75f), streetCottage, 0u},
    {float4(-92.0f, -0.35f, 21.0f, 0.8f), streetCottage, 2u},
    {float4(-85.0f, -0.2f, 59.5f, 0.65f), streetBarn, 0u},
    {float4(93.0f, 0.85f, 14.5f, 0.8f), streetBarn, 2u},
    {float4(105.0f, 1.0f, 55.0f, 0.75f), streetOpenShed, 1u},
    {float4(40.0f, 0.45f, 10.95f, 5.0f), streetTomb, 2u},
    {float4(-40.0f, 0.45f, 10.95f, 5.0f), streetTomb, 2u},
};

// How far each property stands turned off square, beyond its quarter
// turns, about the vertical through its centre: the cosine and sine of the
// angle, taking +x toward +z. The cottage's is cottageTurn.
constant float2 streetPropertyTurns[streetPropertyCount] = {
    float2(0.992546f, 0.121869f),
    float2(0.984808f, -0.173648f),
    float2(0.974370f, 0.224951f),
    float2(0.994522f, -0.104528f),
    float2(0.987688f, 0.156434f),
    float2(0.978148f, -0.207912f),
    float2(0.996195f, 0.087156f),
    float2(1.000000f, 0.000000f),
    float2(1.000000f, 0.000000f),
};
static_assert(streetPropertyTurns[0].x == cottageTurn.x
    && streetPropertyTurns[0].y == cottageTurn.y,
    "the cottage is property 0");

// The centre of each original's floor in world metres; a mausoleum's
// doorway's foot.
constant float3 streetBarnSource = shedYardOrigin
    + float3(barnX, 0.0f, barnZ);
constant float3 streetOpenShedSource = shedYardOrigin
    + float3(openShedX, 0.0f, openShedZ);
constant float3 streetTombSource = houseOrigin
    + houseScale * float3(-houseYardAisleX, 0.0f, houseYardMausoleumZ);

constexpr float3 streetSource(uint kind) {
    return kind == streetCottage ? cottageOrigin
        : (kind == streetBarn ? streetBarnSource
            : (kind == streetOpenShed ? streetOpenShedSource
                : streetTombSource));
}

// Turns x and z by quarter turns: each takes west to south.
constexpr float2 streetTurn(float2 v, uint turns) {
    return (turns & 3u) == 0u ? v : ((turns & 3u) == 1u ? float2(-v.y, v.x)
        : ((turns & 3u) == 2u ? -v : float2(v.y, -v.x)));
}

float3 streetTurnDirection(StreetProperty c, float3 v) {
    float2 xz = streetTurn(v.xz, c.turns);
    return float3(xz.x, v.y, xz.y);
}

// A point of the original, in world metres, moved onto the copy.
constexpr float3 streetPlace(StreetProperty c, float3 source, float3 q) {
    float2 xz = streetTurn((q - source).xz * c.at.w, c.turns);
    return c.at.xyz + float3(xz.x, (q.y - source.y) * c.at.w, xz.y);
}

// These layout tables are literal. Metal emits a forbidden global
// constructor for computed vector arrays, even when their helpers are
// constexpr. Keep them in sync with the properties, their turns and the
// source footprints and pads. The spider and drone kernels read them with
// one turn of the point into the copy that holds it, never by moving the
// originals' tables onto the copies each frame; doing that made the spider
// kernel take minutes to compile.

// Each property's levelled ground in its own frame: x and z from its
// centre, after its quarter turns and before its turn off square.
constant float4 streetPads[streetPropertyCount] = {
    float4(-12.500000f, -11.500000f, 11.500000f, 15.500000f),
    float4(-11.250000f, -10.350000f, 10.350000f, 13.950000f),
    float4(-9.375000f, -8.625000f, 8.625000f, 11.625000f),
    float4(-9.200000f, -12.400000f, 10.000000f, 9.200000f),
    float4(-5.850000f, -10.400000f, 5.850000f, 9.750000f),
    float4(-7.200000f, -12.000000f, 7.200000f, 12.800000f),
    float4(-10.500000f, -6.375000f, 10.500000f, 5.625000f),
    float4(-22.500000f, -31.000000f, 22.500000f, 21.000000f),
    float4(-22.500000f, -31.000000f, 22.500000f, 21.000000f),
};

// The copies' walls, posts and crates from their originals' tables, in
// each copy's frame like its pad: the cottages' (properties 1 to 3), the
// barns' (4 and 5), the open shed's (6) and the mausoleums' (7 and 8).
// Property i's run from streetObstacleFirst[i] up to the next one's.
static_assert(streetProperties[1].kind == streetCottage
    && streetProperties[2].kind == streetCottage
    && streetProperties[3].kind == streetCottage
    && streetProperties[4].kind == streetBarn
    && streetProperties[5].kind == streetBarn
    && streetProperties[6].kind == streetOpenShed
    && streetProperties[7].kind == streetTomb
    && streetProperties[8].kind == streetTomb,
    "streetObstacles holds the copies in this order");

constant uint streetObstacleCount = 38u;
static_assert(streetObstacleCount == 3u * cottageObstacleCount
    + shedObstacleCount + barnObstacleCount + 2u * mausoleumObstacleCount,
    "one entry for each footprint of each copy");
constant uint streetObstacleFirst[streetPropertyCount + 1u] = {
    0u, 0u, 4u, 8u, 12u, 17u, 22u, 36u, 37u, 38u};
static_assert(streetObstacleFirst[streetPropertyCount] == streetObstacleCount,
    "the last copy's footprints end the table");

constant float4 streetObstacles[streetObstacleCount] = {
    float4(-8.280000f, -6.480000f, 8.280000f, 6.480000f),
    float4(-8.190000f, 6.300000f, 2.430000f, 11.520000f),
    float4(-9.270000f, 1.800000f, -8.280000f, 3.240000f),
    float4(-1.080000f, -7.515000f, 1.080000f, -6.480000f),
    float4(-6.900000f, -5.400000f, 6.900000f, 5.400000f),
    float4(-6.825000f, 5.250000f, 2.025000f, 9.600000f),
    float4(-7.725000f, 1.500000f, -6.900000f, 2.700000f),
    float4(-0.900000f, -6.262500f, 0.900000f, -5.400000f),
    float4(-7.360000f, -5.760000f, 7.360000f, 5.760000f),
    float4(-2.160000f, -10.240000f, 7.280000f, -5.600000f),
    float4(7.360000f, -2.880000f, 8.240000f, -1.600000f),
    float4(-0.960000f, 5.760000f, 0.960000f, 6.680000f),
    float4(-4.615000f, -8.515000f, -4.420000f, 8.515000f),
    float4(4.420000f, -8.515000f, 4.615000f, 8.515000f),
    float4(-4.615000f, 8.320000f, 4.615000f, 8.515000f),
    float4(-4.615000f, -8.547500f, 0.000000f, -8.320000f),
    float4(1.625000f, -8.625500f, 4.615000f, -8.320000f),
    float4(5.440000f, -10.480000f, 5.680000f, 10.480000f),
    float4(-5.680000f, -10.480000f, -5.440000f, 10.480000f),
    float4(-5.680000f, -10.480000f, 5.680000f, -10.240000f),
    float4(-0.000000f, 10.240000f, 5.680000f, 10.520000f),
    float4(-5.680000f, 10.240000f, -2.000000f, 10.616000f),
    float4(-9.075000f, 3.975000f, 9.075000f, 4.200000f),
    float4(8.850000f, -4.200000f, 9.075000f, 4.200000f),
    float4(-9.075000f, -4.200000f, -8.850000f, 4.200000f),
    float4(8.775000f, -4.125000f, 9.000000f, -3.900000f),
    float4(5.812500f, -4.125000f, 6.037500f, -3.900000f),
    float4(2.850000f, -4.125000f, 3.075000f, -3.900000f),
    float4(-0.112500f, -4.125000f, 0.112500f, -3.900000f),
    float4(-3.075000f, -4.125000f, -2.850000f, -3.900000f),
    float4(-6.037500f, -4.125000f, -5.812500f, -3.900000f),
    float4(-9.000000f, -4.125000f, -8.775000f, -3.900000f),
    float4(4.950000f, 2.700000f, 6.000000f, 3.900000f),
    float4(3.600000f, 2.925000f, 4.425000f, 3.900000f),
    float4(-3.150000f, 1.500000f, -2.250000f, 2.250000f),
    float4(-4.950000f, 2.775000f, -3.750000f, 3.900000f),
    float4(-16.000000f, -28.500000f, 16.000000f, 17.550000f),
    float4(-16.000000f, -28.500000f, 16.000000f, 17.550000f),
};

// Each property's drive in world x and z, from its end by the building to
// the road's centre line, square to the road however the building stands.
// The mausoleums, last, have none.
constant uint streetDriveCount = 7u;

constant float4 streetDrives[streetDriveCount] = {
    float4(-34.938678f, 38.000000f, -31.738678f, 53.217517f),
    float4(36.787174f, 38.000000f, 39.667174f, 50.435936f),
    float4(-121.191438f, 38.000000f, -118.791438f, 50.306434f),
    float4(-95.692900f, 27.125774f, -93.132900f, 38.000000f),
    float4(-85.452372f, 38.000000f, -81.812372f, 50.865135f),
    float4(92.997130f, 25.024868f, 97.477130f, 38.000000f),
    float4(102.392201f, 38.000000f, 108.392201f, 50.517124f),
};

// The cottages' porch lanterns, where their lights hang.
constant float3 streetLanterns[streetCottageCount] = {
    float3(-37.049419f, 2.650000f, 52.258140f),
    float3(34.780990f, 2.385000f, 50.586650f),
    float3(-122.684036f, 0.762500f, 49.299935f),
    float3(-91.347742f, 1.370000f, 27.205817f),
};

// The cottages' chimney pots, where their smoke leaves them, and each
// cottage's scale.
constant float4 streetChimneys[streetCottageCount] = {
    float4(-48.594236f, 18.600000f, 61.520219f, 1.000000f),
    float4(27.281836f, 16.740000f, 61.596123f, 0.900000f),
    float4(-132.021329f, 12.725000f, 55.303369f, 0.750000f),
    float4(-84.015415f, 14.130000f, 17.908448f, 0.800000f),
};

// p, in world x and z, in property i's frame.
float2 streetLocal(uint i, float2 p) {
    return houseRotate(p - streetProperties[i].at.xz,
        float2(streetPropertyTurns[i].x, -streetPropertyTurns[i].y));
}

float streetPadBlend(uint i, float2 p) {
    return buildingPadBlend(streetLocal(i, p), float2(0.0f),
        streetPads[i].xy, streetPads[i].zw, streetPadMargin, streetPadReach);
}

// The porch lantern of cottage i, each flickering in its own time.
PointLight streetCottageLantern(uint i, float time) {
    PointLight light = cottageLanternLight(time + 1.7f * float(i));
    light.position = streetLanterns[i];
    light.power *= streetProperties[i].at.w * streetProperties[i].at.w;
    return light;
}

// ------------------------------------------------------------------ ground

// The plain's own weight in the ground's height near the road and the long
// drives: 0 on them and their shoulders, rising to 1 a reach beyond. level
// is the graded height there.
// Keep the grading loop out of the scene fragment's ray-march inlining.
__attribute__((noinline))
float streetGrade(float2 p, thread float &level) {
    float weight = 1.0f;
    level = 0.0f;
    float beyond = length(max(float2(abs(p.y - streetRoadZ)
        - streetRoadHalfWidth - streetShoulder, abs(p.x) - streetRoadEnd),
        float2(0.0f)));
    if (beyond < streetGradeReach) {
        weight = smoothstep(0.0f, streetGradeReach, beyond);
        level = streetLevel(p.x);
    }
    if (p.x < -36.0f || p.x > 86.0f || p.y < 26.0f || p.y > 170.0f)
        return weight;
    for (uint i = 0u; i < streetLegCount; ++i) {
        StreetLeg leg = streetLegs[i];
        float2 a = leg.from.xy, ab = leg.to.xy - a;
        float t = saturate(dot(p - a, ab) / dot(ab, ab));
        float w = smoothstep(0.0f, streetGradeReach,
            distance(p, a + ab * t) - leg.from.w - streetShoulder);
        level = w < weight ? mix(leg.from.z, leg.to.z, t) : level;
        weight = min(weight, w);
    }
    return weight;
}

// True where p lies near enough a copy for its ground to matter.
bool streetNearProperties(float2 p) {
    return p.y > -36.0f && p.y < 86.0f && abs(p.x) < 146.0f;
}

// The copy whose levelled ground holds p, with p in its frame as local, or
// streetPropertyCount where there is none.
// Kept out of line: inlined into the spider and drone kernels' footing, its
// loop of turns took their cold compile from seconds to minutes.
__attribute__((noinline))
uint streetPropertyAt(float2 p, thread float2 &local) {
    if (!streetNearProperties(p)) return streetPropertyCount;
    for (uint i = 1u; i < streetPropertyCount; ++i) {
        local = streetLocal(i, p);
        if (all(local > streetPads[i].xy) && all(local < streetPads[i].zw))
            return i;
    }
    return streetPropertyCount;
}

// The terrain height h at p, graded under the road and the long drives and
// levelled under the copies.
float streetGround(float2 p, float h) {
    float level;
    float weight = streetGrade(p, level);
    h = mix(level, h, weight);
    if (!streetNearProperties(p)) return h;
    for (uint i = 1u; i < streetPropertyCount; ++i)
        h = mix(streetProperties[i].at.y, h, streetPadBlend(i, p));
    return h;
}

// Weight of the natural terrain at p: 0 where the street grades or levels
// it, rising to 1 away from it.
float streetGroundBlend(float2 p) {
    float level;
    float blend = streetGrade(p, level);
    if (!streetNearProperties(p)) return blend;
    for (uint i = 1u; i < streetPropertyCount; ++i)
        blend *= streetPadBlend(i, p);
    return blend;
}

// ------------------------------------------------------------------ paving

// Where p lies on the street's asphalt: how far inside its edge (negative
// outside), how worn it is, whether it is the road, and on the road the
// metres across from its centre line and along it.
struct StreetPave {
    float inside;
    float wear;
    bool road;
    float2 at;
};

StreetPave streetPave(float2 p) {
    StreetPave pave = {-1.0e3f, 0.0f, false, float2(0.0f)};
    float across = p.y - streetRoadZ;
    if (abs(p.x) < streetRoadEnd)
        pave = {streetRoadHalfWidth - abs(across), 0.3f + 0.7f
            * smoothstep(streetRoadEnd - 120.0f, streetRoadEnd, abs(p.x)),
            true, float2(across, p.x)};
    if (p.x > -36.0f && p.x < 86.0f && p.y > 30.0f && p.y < 160.0f) {
        for (uint i = 0u; i < streetLegCount; ++i) {
            StreetLeg leg = streetLegs[i];
            float2 a = leg.from.xy, ab = leg.to.xy - a;
            float t = saturate(dot(p - a, ab) / dot(ab, ab));
            float inside = leg.from.w - distance(p, a + ab * t);
            if (inside > pave.inside)
                pave = {inside, leg.to.w, false, float2(0.0f)};
        }
    }
    if (!streetNearProperties(p)) return pave;
    for (uint i = 0u; i < streetDriveCount; ++i) {
        float4 drive = streetDrives[i];
        float2 inside = min(p - drive.xy, drive.zw - p);
        if (min(inside.x, inside.y) > pave.inside)
            pave = {min(inside.x, inside.y), 0.55f, false, float2(0.0f)};
    }
    return pave;
}

// Metres from p to the nearest crack of a network of irregular cells about
// size across: the polygons asphalt breaks into as it ages.
float streetCrackDistance(float2 p, float size, float seed) {
    float2 q = p / size;
    q += 0.12f * float2(pixeltje_terrain::valueNoise(q * 3.0f, seed + 2.0f),
        pixeltje_terrain::valueNoise(q * 3.0f, seed + 3.0f));
    float2 cell = floor(q);
    float first = 8.0f, second = 8.0f;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            float2 c = cell + float2(float(i), float(j));
            float2 point = c + 0.15f + 0.7f * float2(
                pixeltje_terrain::hash(c, seed),
                pixeltje_terrain::hash(c, seed + 1.0f));
            float d = distance(q, point);
            second = min(second, max(d, first));
            first = min(first, d);
        }
    }
    return 0.5f * (second - first) * size;
}

// 0 to 1: how much of p is paved, before the dust.
float streetPaved(float2 p) {
    return smoothstep(-0.1f, 0.1f, streetPave(p).inside);
}

// The asphalt under p: its colour, and how much of the ground it covers, 0
// off it and where the dust has drifted over it. On the road, faded lines
// mark its edges and dash its centre.
// Material noise is independent of the scene trace. Keeping it as a call
// also prevents the scene fragment's cold compile from growing sharply.
__attribute__((noinline))
float4 streetPaving(float2 p, float blur) {
    StreetPave pave = streetPave(p);
    if (pave.inside < -0.4f) return float4(0.0f);
    float ragged = 0.1f * (smoothNoise(p * 1.3f) - 0.5f)
        + 0.05f * (smoothNoise(p * 4.7f) - 0.5f);
    float cover = smoothstep(-blur, blur, pave.inside + ragged);
    if (cover <= 0.0f) return float4(0.0f);
    float wear = pave.wear;
    // Dust drifts in from the edges and lies in patches, more on the old
    // drives and toward the road's ends.
    float drift = pixeltje_terrain::valueNoise(p * 0.3f, 71.0f)
        * (0.55f + 0.5f * wear)
        + 0.35f * (1.0f - smoothstep(0.0f, 0.9f, pave.inside));
    cover *= 1.0f - 0.9f * smoothstep(0.55f, 0.95f, drift);
    // Pale chips of aggregate in a dark binder, to their mean below a
    // pixel, bleached grey in places by grit.
    float chips = (pixeltje_terrain::valueNoise(p * 41.0f, 72.0f) - 0.5f)
        * (1.0f - smoothstep(0.01f, 0.04f, blur));
    float3 asphalt = float3(0.05f, 0.049f, 0.047f) * (1.0f + 0.7f * chips);
    asphalt = mix(asphalt, float3(0.088f, 0.085f, 0.08f),
        (0.35f + 0.5f * wear) * smoothstep(0.35f, 0.8f,
            pixeltje_terrain::valueNoise(p * 0.22f, 73.0f)));
    // Patches of newer, blacker tar.
    float2 cell = p / float2(4.2f, 2.7f);
    float2 patch = abs(fract(cell) - 0.5f) * float2(4.2f, 2.7f);
    if (hashTile(floor(cell) + 17.0f) > 0.93f)
        asphalt *= 1.0f - 0.3f * (1.0f - smoothstep(-blur, blur,
            max(patch.x - 0.9f, patch.y - 0.55f)));
    // Long cracks part it into blocks a few metres across, and where it is
    // worn it breaks up finer, like a crocodile's back. They fade out
    // before they thin below a pixel.
    if (blur < 0.05f) {
        float block = smoothstep(0.35f, 0.6f,
            pixeltje_terrain::valueNoise(p * 0.12f, 74.0f) + 0.25f * wear);
        float fine = smoothstep(0.66f, 0.82f,
            pixeltje_terrain::valueNoise(p * 0.09f, 75.0f) + 0.2f * wear);
        float crack = block * (1.0f - smoothstep(0.005f, 0.005f + blur,
            streetCrackDistance(p, 4.5f, 76.0f)));
        if (fine > 0.0f)
            crack = max(crack, fine * (1.0f - smoothstep(0.003f,
                0.003f + blur, streetCrackDistance(p, 0.7f, 78.0f))));
        asphalt *= 1.0f - 0.8f * crack * (1.0f - smoothstep(0.01f, 0.05f,
            blur));
    }
    if (pave.road) {
        float across = abs(pave.at.x);
        float dash = abs(fract(pave.at.y / 9.0f + 0.5f - 1.0f / 6.0f) - 0.5f)
            * 9.0f;
        float paint = max(
            (1.0f - smoothstep(0.06f - blur, 0.06f + blur, across))
                * (1.0f - smoothstep(1.5f - blur, 1.5f + blur, dash)),
            1.0f - smoothstep(0.05f - blur, 0.05f + blur,
                abs(across - streetRoadHalfWidth + 0.3f)));
        paint *= smoothstep(0.2f, 0.55f, pixeltje_terrain::valueNoise(
            p * float2(0.8f, 2.3f), 77.0f)) * (1.0f - wear);
        asphalt = mix(asphalt, float3(0.3f, 0.28f, 0.22f), 0.8f * paint);
    }
    return float4(asphalt, cover);
}

// ------------------------------------------------------------------ copies

// A part of an original moved onto a copy. Its box and cutting planes move
// with it; boards, logs and rods keep their frames in the window fields,
// which move too; windows grow with the copy and swap faces as it turns. A
// clad wall's gaps for loose boards are dropped.
HousePart streetCopyPart(HousePart part, StreetProperty c, float3 source) {
    uint style = uint(part.lower.w);
    float s = c.at.w;
    float3 a = streetPlace(c, source, part.lower.xyz);
    float3 b = streetPlace(c, source, part.upper.xyz);
    part.lower.xyz = min(a, b);
    part.upper.xyz = max(a, b);
    uint planes = uint(part.upper.w);
    for (uint k = 0u; k < 4u; ++k) {
        float4 plane = part.planes[k];
        float3 normal = streetTurnDirection(c, plane.xyz);
        part.planes[k] = k < planes ? float4(normal, s * (plane.w
            - dot(plane.xyz, source)) + dot(normal, c.at.xyz)) : float4(0.0f);
    }
    bool headstone = style == houseGrave && length(part.windows.xyz) > 0.5f;
    if (style == houseTimber || houseRoundStyle(style) || headstone) {
        part.windows = float4(streetTurnDirection(c, part.windows.xyz),
            headstone ? part.windows.w : s * part.windows.w);
        part.rows = float4(streetPlace(c, source, part.rows.xyz),
            style == houseTimber ? part.rows.w : s * part.rows.w);
    } else if (style == houseGrave || style == housePlaster) {
        // Tomb stone and plaster: an engraved line's height, half width and
        // letter size grow with it, and a copy turned about carves its +z
        // face.
        part.windows.xyz = streetTurnDirection(c, part.windows.xyz);
        part.rows.xyz *= s;
        if (part.rows.z > 0.0f && (c.turns & 3u) == 2u) part.rows.w = -1.0f;
    } else {
        if ((c.turns & 1u) != 0u) part.windows.xy = part.windows.yx;
        part.windows.zw *= s;
        part.rows.xz *= s;
    }
    return part;
}

// Copies group g, an original's, onto c as a group of the open site. Loose
// clapboards hang from the original only.
void copyBuildingGroup(device HouseModel &house, uint g, StreetProperty c) {
    if (g >= min(house.counts.y, houseGroupCapacity)) return;
    uint first = uint(house.groups[g].lower.w);
    uint end = min(uint(house.groups[g].upper.w), houseCapacity);
    float3 source = streetSource(c.kind);
    beginHouseGroup(house);
    for (uint i = first; i < end; ++i) {
        HousePart part = house.parts[i];
        if (uint(part.lower.w) == houseTimber
            && part.rows.w == houseNailAtPivot) continue;
        addHouseWorldPart(house, streetCopyPart(part, c, source));
    }
}

// ------------------------------------------------------------------- lamps

constant uint streetLampCount = 16u;
constant float streetLampFirstX = -150.0f;
constant float streetLampSpacing = 20.0f;
constant float streetLampSize = 2.0f;     // twice a garden lamp's
constant float streetLampSetback = 1.3f;  // from the asphalt's edge
constant float streetLampReach = 36.0f;   // of its light
constant float streetLampPower = 600.0f;
constant float streetLampGlow = 2.5f;     // its glass, against a lantern's
constant uint streetLampParts = 12u;
constant uint streetLampLantern = 10u;    // the lantern's part in a lamp

// Lamp k's foot in x and z, and which way along z its crook reaches over
// the road: even lamps stand north of it, odd ones south.
float3 streetLampFoot(uint k) {
    float side = (k & 1u) == 0u ? 1.0f : -1.0f;
    return float3(streetLampFirstX + streetLampSpacing * float(k),
        streetRoadZ + side * (streetRoadHalfWidth + streetLampSetback),
        -side);
}

// A lamp post, every measure below times streetLampSize: a flanged foot on
// a round base plate, a slender post 3 m tall with a collar halfway up, and
// a shepherd's crook bent from three rods. A lantern hangs from a hook at
// the crook's tip, under a flared cap and over a drip plate; its glass
// burns brighter than a house lantern's.
void addStreetLamp(device HouseModel &house, uint k) {
    float3 lamp = streetLampFoot(k);
    float3 foot = float3(lamp.x, moonHeight(lamp.xy, moonTraceDetail),
        lamp.y);
    const float u = streetLampSize;
    const float3 up = float3(0.0f, u, 0.0f);
    float3 out = float3(0.0f, 0.0f, lamp.z * u);
    const float bend = 0.24f;
    addHouseRod(house, foot - up * 0.015f, foot + up * 0.02f, 0.14f * u);
    addHouseRod(house, foot, foot + up * 0.22f, 0.065f * u);
    addHouseRod(house, foot, foot + up * 3.0f, 0.045f * u);
    addHouseRod(house, foot + up * 1.5f, foot + up * 1.56f, 0.056f * u);
    float3 centre = foot + up * 3.0f + out * bend;
    float3 a = foot + up * 3.0f;
    for (uint i = 1u; i <= 3u; ++i) {
        float angle = rangePi * (1.0f - float(i) / 3.0f);
        float3 b = centre + (out * cos(angle) + up * sin(angle)) * bend;
        addHouseRod(house, a, b, 0.028f * u);
        a = b;
    }
    addHouseRod(house, a, a - up * 0.13f, 0.012f * u);
    float3 top = a - up * 0.12f;
    addHouseWorldPart(house, houseHip(top + float3(-0.15f, 0.0f, -0.15f) * u,
        top + float3(0.15f, 0.11f, 0.15f) * u, float2(0.13f * u),
        houseCastIron));
    addHouseWorldPart(house, houseBox(top - float3(0.18f, 0.03f, 0.18f) * u,
        top + float3(0.18f, 0.0f, 0.18f) * u, houseCastIron));
    HousePart lantern = houseBox(top - float3(0.12f, 0.39f, 0.12f) * u,
        top + float3(0.12f, -0.03f, 0.12f) * u, houseLantern);
    lantern.rows.w = streetLampGlow;
    addHouseWorldPart(house, lantern);
    addHouseWorldPart(house, houseBox(top - float3(0.14f, 0.43f, 0.14f) * u,
        top + float3(0.14f, -0.39f, 0.14f) * u, houseCastIron));
}

// The lamps whose light can reach p: from x up to y.
uint2 streetLampsNear(float3 p) {
    if (abs(p.z - streetRoadZ) > streetLampReach + streetRoadHalfWidth
        + streetLampSetback) return uint2(0u);
    float first = clamp(ceil((p.x - streetLampReach - streetLampFirstX)
        / streetLampSpacing), 0.0f, float(streetLampCount));
    float end = clamp(floor((p.x + streetLampReach - streetLampFirstX)
        / streetLampSpacing) + 1.0f, first, float(streetLampCount));
    return uint2(uint(first), uint(end));
}

// Lamp k's light, from the middle of its lantern, flickering as the
// lantern's glass does; dim is the haunting's.
PointLight streetLampLight(uint k, device const GameState &game, float dim) {
    uint index = min(game.house.sites[streetLampSite].z
        + k * streetLampParts + streetLampLantern, houseCapacity - 1u);
    device const HousePart &lantern = game.house.parts[index];
    return {0.5f * (lantern.lower.xyz + lantern.upper.xyz),
        float3(1.0f, 0.6f, 0.27f), streetLampPower
            * houseFlicker(game.effects.x, lantern.lower.x, 0.12f) * dim,
        false};
}

// True where the nearest lamp post keeps a walker padded by pad out.
bool streetLampBlocked(float2 p, float pad) {
    float k = clamp(round((p.x - streetLampFirstX) / streetLampSpacing), 0.0f,
        float(streetLampCount - 1u));
    return distance(p, streetLampFoot(uint(k)).xy)
        < 0.065f * streetLampSize + pad;
}

// ---------------------------------------------------------------- building

// Runs in the initialize pass after the originals: the copies north of the
// road as one site and those south of it as another, then the lamps, one
// group each, as a third.
void buildStreet(device HouseModel &house) {
    for (uint side = 0u; side < 2u; ++side) {
        beginBuildingSite(house);
        for (uint i = 1u; i < streetPropertyCount; ++i) {
            StreetProperty c = streetProperties[i];
            if ((c.at.z < streetRoadZ) != (side == 1u)) continue;
            uint first = house.counts.y;
            if (c.kind == streetCottage) {
                uint2 groups = house.sites[streetCottageSite].xy;
                for (uint g = groups.x + 1u; g < groups.y; ++g)
                    copyBuildingGroup(house, g, c);
            } else if (c.kind == streetTomb) {
                copyBuildingGroup(house, house.sites[streetHouseSite].y - 2u,
                    c);
            } else {
                copyBuildingGroup(house,
                    house.sites[streetShedYardSite].x + c.kind, c);
            }
            turnHouseGroups(house, first, house.counts.y,
                streetPropertyTurns[i], c.at.xz);
        }
    }
    beginBuildingSite(house);
    for (uint k = 0u; k < streetLampCount; ++k) {
        beginHouseGroup(house);
        addStreetLamp(house, k);
    }
}

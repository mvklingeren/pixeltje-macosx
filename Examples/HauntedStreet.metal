// The street for HauntedHouseProgram.metal: an asphalt road across the plain
// between the base exit and the cottage, drives to the buildings, copies of
// those buildings along it, lantern posts beside it, and name signs at the
// corners where drives meet it.
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
// five times their size, either side of the base exit. The walker climbs
// their steps onto their plinths, and the east one is a ruin whose fallen
// back corner opens its hall, where the broodmother waits by a few
// candles; see HauntedMausoleum.metal.
// buildStreet copies the originals' parts, already in the game buffer,
// through a scale and a quarter turn, then turns the copy's groups by its
// few degrees, so a copy is traced, shadowed and shaded like its original
// and adds no code to the traces. Loose clapboards
// stay on the original; a copy's clapboards are whole. The walker meets a
// copy's walls through its original's footprint table, and nobody goes
// into the houses; the mausoleums' own footing serves theirs.
//
// Sixteen lantern posts nine metres tall stand along the road, alternating
// sides: a cast-iron post in glossy black enamel whose top arches out over
// the road, a big lantern hanging from its tip.
// Only the few near a point light it. They go out while the house is
// haunted.
//
// Four street name signs stand where the long drives and two of the
// cottages' drives meet the road: green blades with white letters crossed
// on a black post, the road's name below and the drive's above.
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
// to 2, then buildStreet the copies north and south of the road as sites 3
// and 4, and the lamps and then the signs as site 5. The mausoleums are the
// house site's last two groups.
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
constant uint streetTombFirst = 7u; // the first mausoleum property
constant uint streetRuinedTomb = 7u; // the ruined one, east of the exit

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
// angle, taking +x toward +z. The cottage's is cottageTurn. buildStreet
// turns the copies' groups by them; the tables below are worked out with
// them.
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
// source footprints and pads. They are world boxes, so the spider and drone
// kernels read them without turning or moving points each frame; doing
// either made the spider kernel take minutes to compile.

// Each property's levelled ground in world x and z: the box around its
// pad, turned with it.
constant float4 streetPads[streetPropertyCount] = {
    float4(-52.295802f, 47.062352f, -25.184222f, 76.785963f),
    float4(23.123654f, 45.509981f, 48.615152f, 73.191610f),
    float4(-135.749775f, 44.487142f, -113.655855f, 68.267255f),
    float4(-102.445754f, 7.622644f, -81.093119f, 31.111263f),
    float4(-92.303213f, 48.312900f, -77.595105f, 70.045103f),
    float4(83.462397f, 1.265265f, 102.703932f, 28.517253f),
    float4(94.049705f, 47.734124f, 116.015662f, 61.518730f),
    float4(17.500000f, -20.050000f, 62.500000f, 31.950000f),
    float4(-62.500000f, -20.050000f, -17.500000f, 31.950000f),
};

// The copies' walls, posts and crates from their originals' footprints, in
// world x and z: the cottages' (properties 1 to 3), the barns' (4 and 5),
// the open shed's (6) and the mausoleums' (7 and 8). A turned footprint is
// never entered, so only its outline is kept, cut into pieces whose boxes
// reach at most 0.6 m past it. The street name signs' posts follow, last.
static_assert(streetProperties[1].kind == streetCottage
    && streetProperties[2].kind == streetCottage
    && streetProperties[3].kind == streetCottage
    && streetProperties[4].kind == streetBarn
    && streetProperties[5].kind == streetBarn
    && streetProperties[6].kind == streetOpenShed
    && streetProperties[7].kind == streetTomb
    && streetProperties[8].kind == streetTomb,
    "streetObstacles holds the copies in this order");

constant uint streetObstacleCount = 178u;
constant float4 streetObstacles[streetObstacleCount] = {
    float4(26.720552f, 51.981130f, 30.034329f, 52.851695f),
    float4(29.982235f, 51.406007f, 33.296013f, 52.276572f),
    float4(33.243918f, 50.830884f, 36.557696f, 51.701449f),
    float4(36.505601f, 50.255762f, 39.819379f, 51.126327f),
    float4(39.767285f, 49.680639f, 43.081062f, 50.551204f),
    float4(28.918938f, 64.448796f, 32.232715f, 65.319361f),
    float4(32.180621f, 63.873673f, 35.494399f, 64.744238f),
    float4(35.442304f, 63.298551f, 38.756082f, 64.169116f),
    float4(38.703987f, 62.723428f, 42.017765f, 63.593993f),
    float4(41.965671f, 62.148305f, 45.279448f, 63.018870f),
    float4(26.772646f, 52.799601f, 27.604661f, 55.894751f),
    float4(27.309219f, 55.842657f, 28.141234f, 58.937807f),
    float4(27.845792f, 58.885712f, 28.677807f, 61.980863f),
    float4(28.382365f, 61.928768f, 29.214380f, 65.023919f),
    float4(42.785620f, 49.976081f, 43.617635f, 53.071232f),
    float4(43.322193f, 53.019137f, 44.154208f, 56.114288f),
    float4(43.858766f, 56.062193f, 44.690781f, 59.157343f),
    float4(44.395339f, 59.105249f, 45.227354f, 62.200399f),
    float4(29.028408f, 64.665432f, 31.695167f, 65.421910f),
    float4(31.643073f, 64.204396f, 34.309832f, 64.960874f),
    float4(34.257737f, 63.743360f, 36.924496f, 64.499838f),
    float4(36.872402f, 63.282324f, 39.539161f, 64.038802f),
    float4(29.882757f, 69.510686f, 32.549516f, 70.267164f),
    float4(32.497422f, 69.049650f, 35.164181f, 69.806128f),
    float4(35.112086f, 68.588614f, 37.778845f, 69.345092f),
    float4(37.726751f, 68.127578f, 40.393510f, 68.884056f),
    float4(29.080502f, 65.369815f, 29.777072f, 67.696816f),
    float4(29.481630f, 67.644721f, 30.178199f, 69.971722f),
    float4(39.243718f, 63.577766f, 39.940288f, 65.904766f),
    float4(39.644846f, 65.852672f, 40.341415f, 68.179672f),
    float4(27.183399f, 60.710461f, 28.210453f, 61.177815f),
    float4(27.381358f, 61.833142f, 28.408412f, 62.300496f),
    float4(27.235493f, 61.125720f, 27.676800f, 62.005053f),
    float4(27.915011f, 61.005903f, 28.356317f, 61.885236f),
    float4(33.631442f, 49.911630f, 35.810721f, 50.582152f),
    float4(33.759073f, 50.635463f, 35.938352f, 51.305986f),
    float4(33.683536f, 50.530058f, 34.054515f, 51.010543f),
    float4(35.515278f, 50.207072f, 35.886258f, 50.687558f),
    float4(-129.575903f, 48.186239f, -127.267367f, 48.995938f),
    float4(-127.334852f, 48.703627f, -125.026315f, 49.513325f),
    float4(-125.093801f, 49.221014f, -122.785264f, 50.030713f),
    float4(-122.852750f, 49.738402f, -120.544213f, 50.548100f),
    float4(-120.611698f, 50.255789f, -118.303162f, 51.065488f),
    float4(-118.370647f, 50.773177f, -116.062111f, 51.582875f),
    float4(-131.937889f, 58.417125f, -129.629353f, 59.226823f),
    float4(-129.696838f, 58.934512f, -127.388302f, 59.744211f),
    float4(-127.455787f, 59.451900f, -125.147250f, 60.261598f),
    float4(-125.214736f, 59.969287f, -122.906199f, 60.778986f),
    float4(-122.973685f, 60.486675f, -120.665148f, 61.296373f),
    float4(-120.732633f, 61.004062f, -118.424097f, 61.813761f),
    float4(-130.149528f, 48.478550f, -129.283592f, 51.030679f),
    float4(-130.723153f, 50.963194f, -129.857217f, 53.515323f),
    float4(-131.296779f, 53.447838f, -130.430842f, 55.999967f),
    float4(-131.870404f, 55.932481f, -131.004468f, 58.484610f),
    float4(-116.995532f, 51.515390f, -116.129596f, 54.067519f),
    float4(-117.569158f, 54.000033f, -116.703221f, 56.552162f),
    float4(-118.142783f, 56.484677f, -117.276847f, 59.036806f),
    float4(-118.716408f, 58.969321f, -117.850472f, 61.521450f),
    float4(-131.898554f, 58.580152f, -129.675275f, 59.370167f),
    float4(-129.742760f, 59.077856f, -127.519481f, 59.867871f),
    float4(-127.586967f, 59.575560f, -125.363687f, 60.365576f),
    float4(-125.431173f, 60.073265f, -123.207894f, 60.863280f),
    float4(-132.809606f, 62.526351f, -130.586327f, 63.316366f),
    float4(-130.653812f, 63.024055f, -128.430533f, 63.814070f),
    float4(-128.498018f, 63.521759f, -126.274739f, 64.311774f),
    float4(-126.342225f, 64.019463f, -124.118945f, 64.809479f),
    float4(-132.320337f, 58.872463f, -131.606243f, 60.766892f),
    float4(-132.742120f, 60.699407f, -132.028026f, 62.593836f),
    float4(-123.989473f, 60.795794f, -123.275379f, 62.690224f),
    float4(-124.411256f, 62.622738f, -123.697162f, 64.517167f),
    float4(-131.931921f, 54.723808f, -131.060580f, 55.201704f),
    float4(-132.134377f, 55.600741f, -131.263036f, 56.078637f),
    float4(-132.066891f, 55.016119f, -131.639610f, 55.668227f),
    float4(-131.555347f, 55.134219f, -131.128065f, 55.786326f),
    float4(-123.535662f, 48.695552f, -121.714311f, 49.392774f),
    float4(-123.662197f, 49.243635f, -121.840846f, 49.940858f),
    float4(-123.594712f, 48.987863f, -123.243351f, 49.311120f),
    float4(-122.133157f, 49.325289f, -121.781796f, 49.648547f),
    float4(-99.921765f, 15.527997f, -95.010619f, 16.339240f),
    float4(-95.041978f, 15.015111f, -90.130832f, 15.826354f),
    float4(-90.162190f, 14.502224f, -85.251044f, 15.313467f),
    float4(-98.748956f, 26.686533f, -93.837810f, 27.497776f),
    float4(-93.869168f, 26.173646f, -88.958022f, 26.984889f),
    float4(-88.989381f, 25.660760f, -84.078235f, 26.472003f),
    float4(-99.890407f, 16.307881f, -99.021325f, 21.769329f),
    float4(-99.319681f, 21.737971f, -98.450599f, 27.199419f),
    float4(-85.549401f, 14.800581f, -84.680319f, 20.262029f),
    float4(-84.978675f, 20.230671f, -84.109593f, 25.692119f),
    float4(-95.218539f, 10.548503f, -90.493037f, 11.340234f),
    float4(-90.524395f, 10.055129f, -85.798894f, 10.846859f),
    float4(-94.764885f, 14.864728f, -90.039383f, 15.656459f),
    float4(-90.070742f, 14.371354f, -85.345240f, 15.163085f),
    float4(-95.187180f, 11.308875f, -94.466529f, 15.358102f),
    float4(-86.097250f, 10.353485f, -85.376599f, 14.402712f),
    float4(-84.981361f, 17.274462f, -84.074823f, 17.664804f),
    float4(-84.878923f, 18.249094f, -83.972385f, 18.639435f),
    float4(-84.950002f, 17.633445f, -84.580566f, 18.341079f),
    float4(-84.373180f, 17.572819f, -84.003744f, 18.280452f),
    float4(-92.352657f, 26.628099f, -90.411816f, 27.127150f),
    float4(-92.287849f, 27.244702f, -90.347009f, 27.743754f),
    float4(-92.321299f, 27.095791f, -91.989493f, 27.445397f),
    float4(-90.710173f, 26.926455f, -90.378367f, 27.276061f),
    float4(-88.758958f, 50.367889f, -88.033543f, 53.762460f),
    float4(-89.291774f, 53.731955f, -88.566359f, 57.126526f),
    float4(-89.824590f, 57.096022f, -89.099175f, 60.490593f),
    float4(-90.357405f, 60.460088f, -89.631990f, 63.854659f),
    float4(-90.890221f, 63.824155f, -90.164806f, 67.218726f),
    float4(-79.835194f, 51.781274f, -79.109779f, 55.175845f),
    float4(-80.368010f, 55.145341f, -79.642595f, 58.539912f),
    float4(-80.900825f, 58.509407f, -80.175410f, 61.903978f),
    float4(-81.433641f, 61.873474f, -80.708226f, 65.268045f),
    float4(-81.966457f, 65.237540f, -81.241042f, 68.632111f),
    float4(-90.890221f, 66.995622f, -87.820929f, 67.669518f),
    float4(-87.851433f, 67.476919f, -84.782141f, 68.150815f),
    float4(-84.812646f, 67.958215f, -81.743353f, 68.632111f),
    float4(-88.256647f, 50.335789f, -85.941967f, 50.921460f),
    float4(-85.977556f, 50.696761f, -83.662876f, 51.282433f),
    float4(-82.093472f, 51.234900f, -79.092493f, 52.004378f),
    float4(96.142208f, 3.068075f, 96.921692f, 5.680720f),
    float4(96.686937f, 5.630821f, 97.466421f, 8.243467f),
    float4(97.231666f, 8.193568f, 98.011150f, 10.806214f),
    float4(97.776394f, 10.756315f, 98.555878f, 13.368960f),
    float4(98.321123f, 13.319062f, 99.100607f, 15.931707f),
    float4(98.865852f, 15.881808f, 99.645336f, 18.494454f),
    float4(99.410580f, 18.444555f, 100.190064f, 21.057201f),
    float4(99.955309f, 21.007302f, 100.734793f, 23.619947f),
    float4(85.265207f, 5.380053f, 86.044691f, 7.992698f),
    float4(85.809936f, 7.942799f, 86.589420f, 10.555445f),
    float4(86.354664f, 10.505546f, 87.134148f, 13.118192f),
    float4(86.899393f, 13.068293f, 87.678877f, 15.680938f),
    float4(87.444122f, 15.631040f, 88.223606f, 18.243685f),
    float4(87.988850f, 18.193786f, 88.768334f, 20.806432f),
    float4(88.533579f, 20.756533f, 89.313063f, 23.369179f),
    float4(89.078308f, 23.319280f, 89.857792f, 25.931925f),
    float4(85.265207f, 4.839482f, 88.093045f, 5.664707f),
    float4(88.043146f, 4.249013f, 90.870984f, 5.074238f),
    float4(90.821085f, 3.658544f, 93.648923f, 4.483769f),
    float4(93.599025f, 3.068075f, 96.426863f, 3.893299f),
    float4(95.129016f, 23.925762f, 97.965170f, 24.790113f),
    float4(97.906955f, 23.335293f, 100.743109f, 24.199644f),
    float4(89.573137f, 25.314612f, 91.451104f, 26.064953f),
    float4(91.372929f, 24.932055f, 93.250895f, 25.682396f),
    float4(95.593479f, 58.168936f, 101.640067f, 58.920372f),
    float4(101.620457f, 58.696228f, 107.667045f, 59.447664f),
    float4(107.647435f, 59.223520f, 113.694023f, 59.974956f),
    float4(113.816323f, 51.587311f, 114.406521f, 55.790938f),
    float4(113.450269f, 55.771328f, 114.040467f, 59.974956f),
    float4(95.959533f, 50.025044f, 96.549731f, 54.228672f),
    float4(95.593479f, 54.209062f, 96.183677f, 58.412689f),
    float4(114.081516f, 51.655489f, 114.325270f, 51.899242f),
    float4(111.130289f, 51.397290f, 111.374043f, 51.641043f),
    float4(108.179062f, 51.139091f, 108.422816f, 51.382845f),
    float4(105.227835f, 50.880892f, 105.471589f, 51.124646f),
    float4(102.276609f, 50.622693f, 102.520363f, 50.866447f),
    float4(99.325382f, 50.364494f, 99.569136f, 50.608248f),
    float4(96.374155f, 50.106295f, 96.617909f, 50.350049f),
    float4(109.669697f, 58.121147f, 110.741848f, 58.511519f),
    float4(109.591256f, 59.017722f, 110.663408f, 59.408094f),
    float4(109.617403f, 58.420005f, 109.968555f, 59.043869f),
    float4(110.364549f, 58.485372f, 110.715701f, 59.109235f),
    float4(108.305224f, 58.227630f, 109.153231f, 58.598392f),
    float4(108.246394f, 58.900062f, 109.094401f, 59.270823f),
    float4(108.272540f, 58.526489f, 108.604082f, 58.926208f),
    float4(108.795542f, 58.572245f, 109.127084f, 58.971965f),
    float4(101.705106f, 56.219751f, 102.627828f, 56.597050f),
    float4(101.665886f, 56.668039f, 102.588608f, 57.045338f),
    float4(101.692033f, 56.518610f, 102.003965f, 56.694186f),
    float4(102.289750f, 56.570903f, 102.601682f, 56.746479f),
    float4(99.800832f, 57.333019f, 101.022413f, 57.736465f),
    float4(99.728929f, 58.154880f, 100.950509f, 58.558325f),
    float4(99.755076f, 57.631878f, 100.099691f, 58.181027f),
    float4(100.651651f, 57.710318f, 100.996266f, 58.259467f),
    float4(24.000000f, -17.550000f, 56.000000f, 28.500000f),
    float4(-56.000000f, -17.550000f, -24.000000f, 28.500000f),
    float4(4.15f, 42.75f, 4.25f, 42.85f),
    float4(74.55f, 42.75f, 74.65f, 42.85f),
    float4(-35.95f, 42.75f, -35.85f, 42.85f),
    float4(-96.75f, 33.15f, -96.65f, 33.25f),
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

float streetPadBlend(uint i, float2 p) {
    return buildingPadBlend(p, float2(0.0f), streetPads[i].xy,
        streetPads[i].zw, streetPadMargin, streetPadReach);
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
constant float streetLampPower = 1500.0f; // from its lantern 8.3 m up
constant float streetLampGlow = 2.5f;     // its glass, against a lantern's
constant float streetLampPost = 4.5f;     // height, times streetLampSize
constant float2 streetLampArch = float2(0.5f, 0.4f); // out and up, the same
constant uint streetLampArchRods = 12u;
// A lamp's parts, in addStreetLamp's order: five for the post, the arch's
// rods, the hook, the cap's two, the lantern and its drip plate.
constant uint streetLampParts = 10u + streetLampArchRods;
constant uint streetLampLantern = 8u + streetLampArchRods;

// Lamp k's foot in x and z, and which way along z its arch reaches over
// the road: even lamps stand north of it, odd ones south.
float3 streetLampFoot(uint k) {
    float side = (k & 1u) == 0u ? 1.0f : -1.0f;
    return float3(streetLampFirstX + streetLampSpacing * float(k),
        streetRoadZ + side * (streetRoadHalfWidth + streetLampSetback),
        -side);
}

// A lamp post, every measure below times streetLampSize: a flanged foot on
// a round base plate, a slender post 4.5 m tall with a collar halfway up
// and another under its top, and an arch that rises on from the post and
// curls over in half an ellipse until its tip points down, thinning as it
// goes. A lantern hangs from a hook at the tip, under a flared cap and over
// a drip plate; its glass burns brighter than a house lantern's.
void addStreetLamp(device HouseModel &house, uint k) {
    float3 lamp = streetLampFoot(k);
    float3 foot = float3(lamp.x, moonHeight(lamp.xy, moonTraceDetail),
        lamp.y);
    const float u = streetLampSize;
    const float3 up = float3(0.0f, u, 0.0f);
    float3 out = float3(0.0f, 0.0f, lamp.z * u);
    float3 a = foot + up * streetLampPost;
    addHouseRod(house, foot - up * 0.015f, foot + up * 0.02f, 0.14f * u);
    addHouseRod(house, foot, foot + up * 0.22f, 0.065f * u);
    addHouseRod(house, foot, a, 0.045f * u);
    addHouseRod(house, foot + up * 2.22f, foot + up * 2.28f, 0.056f * u);
    addHouseRod(house, a - up * 0.1f, a - up * 0.06f, 0.054f * u);
    float3 centre = a + out * streetLampArch.x;
    for (uint i = 1u; i <= streetLampArchRods; ++i) {
        float f = float(i) / float(streetLampArchRods);
        float angle = rangePi * (1.0f - f);
        float3 b = centre + out * (streetLampArch.x * cos(angle))
            + up * (streetLampArch.y * sin(angle));
        addHouseRod(house, a, b, mix(0.036f, 0.026f, f) * u);
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

// ------------------------------------------------------------------- signs
// Street name signs, in metres. Each blade is green sheeting with a white
// border, and carries its name in white from the program's signFont, whose
// runs follow streetSignRoad and the signs' names in order. A blade is as
// long as its name at streetSignLetters, measured in that bold monospaced
// font and condensed by houseSignCondense, plus 0.13 m at each end.

struct StreetSign {
    float2 foot;    // x and z
    uint name;      // the drive's run in signFont
    float length;   // of the drive's blade
};

constant uint streetSignRoad = 0u;          // SKULL HOLLOW RD
constant float streetSignRoadLength = 1.67f;
constant float streetSignHeight = 2.9f;     // the lower blade's foot
constant float streetSignBlade = 0.28f;     // a blade's height
constant float streetSignGap = 0.04f;       // between the blades
constant float streetSignLetters = 0.19f;   // the letters' size
constant float streetSignPost = 0.045f;     // the post's radius

// Keep the feet in sync with the last four streetObstacles.
constant uint streetSignCount = 4u;
constant StreetSign streetSigns[streetSignCount] = {
    {float2(4.2f, 42.8f), 1u, 1.11f},       // COFFIN LN, the house's drive
    {float2(74.6f, 42.8f), 2u, 1.76f},      // PUMPKIN PATCH RD, the farm track
    {float2(-35.9f, 42.8f), 3u, 1.39f},     // TOMBSTONE CT
    {float2(-96.7f, 33.2f), 4u, 1.67f},     // GRAVEDIGGER WAY
};
static_assert(streetObstacleCount == 174u + streetSignCount,
    "streetObstacles ends with the sign posts");

// A blade along `along` from its foot's centre, naming run `name`.
void addStreetSignBlade(device HouseModel &house, float3 foot, float3 along,
    float length, uint name) {
    float3 reach = along * (0.5f * length)
        + float3(along.z, 0.0f, along.x) * 0.01f;
    HousePart blade = houseBox(foot - reach,
        foot + reach + float3(0.0f, streetSignBlade, 0.0f), houseSign);
    blade.rows = float4(float(name), streetSignLetters, 0.0f, 1.0f);
    addHouseWorldPart(house, blade);
}

// Sign i: a black post on a flanged foot, the road's blade along x clamped
// to its top, the drive's blade along z crossed over it, and a cap.
void addStreetSign(device HouseModel &house, uint i) {
    StreetSign sign = streetSigns[i];
    float3 foot = float3(sign.foot.x, moonHeight(sign.foot,
        moonTraceDetail), sign.foot.y);
    const float3 up = float3(0.0f, 1.0f, 0.0f);
    float low = streetSignHeight;
    float high = low + streetSignBlade + streetSignGap;
    float top = high + streetSignBlade;
    addHouseRod(house, foot - up * 0.02f, foot + up * 0.03f,
        2.2f * streetSignPost);
    addHouseRod(house, foot, foot + up * 0.25f, 1.4f * streetSignPost);
    addHouseRod(house, foot, foot + up * (low - 0.05f), streetSignPost);
    addHouseWorldPart(house, houseBox(foot + float3(-0.06f, low - 0.07f,
        -0.03f), foot + float3(0.06f, low + 0.03f, 0.03f), houseCastIron));
    addStreetSignBlade(house, foot + up * low, float3(1.0f, 0.0f, 0.0f),
        streetSignRoadLength, streetSignRoad);
    addHouseWorldPart(house, houseBox(foot + float3(-0.03f,
        high - streetSignGap - 0.03f, -0.03f),
        foot + float3(0.03f, high + 0.03f, 0.03f), houseCastIron));
    addStreetSignBlade(house, foot + up * high, float3(0.0f, 0.0f, 1.0f),
        sign.length, sign.name);
    addHouseWorldPart(house, houseBox(foot + float3(-0.03f, top - 0.03f,
        -0.06f), foot + float3(0.03f, top + 0.04f, 0.06f), houseCastIron));
}

// ------------------------------------------------------------------ tombs
// The mausoleum copies stand where the base's front rooms are, which the
// view does not draw: on their pads the walker climbs their steps and meets
// their walls rather than the rooms' (see the program's playerGround). The
// ruin's hall is the broodmother's lair, lit only by a few candles on its
// floor and what comes in through the gap.

static_assert(streetProperties[streetTombFirst].kind == streetTomb
    && streetProperties[streetTombFirst + 1u].kind == streetTomb
    && streetTombFirst + 2u == streetPropertyCount
    && streetRuinedTomb >= streetTombFirst
    && streetPropertyTurns[7].x == 1.0f && streetPropertyTurns[8].x == 1.0f,
    "the tombs are the last two properties and stand square");
static_assert(streetProperties[streetRuinedTomb].turns == 2u,
    "streetLairHall turns the ruin's hall about");

// The highest step a walker takes without jumping, in metres.
constant float streetTombClimb = 0.8f;

// The tomb on whose pad p lies, or streetPropertyCount.
uint streetTombUnder(float2 p) {
    const uint east = streetTombFirst, west = streetTombFirst + 1u;
    if (all(p >= streetPads[east].xy) && all(p <= streetPads[east].zw))
        return east;
    if (all(p >= streetPads[west].xy) && all(p <= streetPads[west].zw))
        return west;
    return streetPropertyCount;
}

bool streetTombPadHolds(float2 p) {
    return streetTombUnder(p) < streetPropertyCount;
}

// p in the frame addMausoleum built the original in, around its doorway's
// foot.
float2 streetTombLocal(StreetProperty c, float2 p) {
    return streetTurn((p - c.at.xz) / c.at.w, 4u - (c.turns & 3u));
}

uint streetTombKind(uint i) {
    return i == streetRuinedTomb ? mausoleumRuined : mausoleumIntact;
}

// The height a walker stands at over p on a tomb's pad: its steps, plinth
// or heap, or ground.
float streetTombStand(float2 p, float ground) {
    uint i = streetTombUnder(p);
    if (i >= streetPropertyCount) return ground;
    StreetProperty c = streetProperties[i];
    float top = mausoleumStand(streetTombLocal(c, p), streetTombKind(i));
    return max(ground, c.at.y + top * c.at.w);
}

// True where a tomb's wall, or footing more than a step above their feet
// at foot, keeps the walker out.
__attribute__((noinline))
bool streetTombBlockedFrom(device const GameState &game, float2 p,
    float foot) {
    uint i = streetTombUnder(p);
    if (i >= streetPropertyCount) return false;
    StreetProperty c = streetProperties[i];
    if (mausoleumBlocked(streetTombLocal(c, p), streetTombKind(i),
        (foot - c.at.y) / c.at.w, streetTombClimb / c.at.w,
        housePlayerPad / c.at.w)) return true;
    uint first = (i - streetTombFirst) * 6u;
    for (uint wall = 0u; wall < 6u; ++wall) {
        uint panel = first + wall;
        uint partIndex = game.house.masonryParts[panel];
        device const HousePart &part = game.house.parts[partIndex];
        HouseTurn turn = housePartTurn(game.house, partIndex);
        float3 point = houseTurnPointIn(turn, float3(p.x, foot, p.y));
        if (point.x < part.lower.x - housePlayerPad
            || point.x > part.upper.x + housePlayerPad
            || point.z < part.lower.z - housePlayerPad
            || point.z > part.upper.z + housePlayerPad) continue;
        for (uint row = 0u; row < masonryRows(part); ++row) {
            float y0 = part.lower.y + float(row) * part.windows.y;
            if (y0 > foot + 1.75f || y0 + part.windows.y < foot + 0.1f)
                continue;
            for (uint col = 0u; col < masonryColumns(part); ++col) {
                if (masonryStoneGone(game, panel, row, col)) continue;
                float3 lower, upper;
                masonryStoneBox(part, row, col, lower, upper);
                float2 gap = max(max(lower.xz - point.xz,
                    point.xz - upper.xz), float2(0.0f));
                if (length(gap) < housePlayerPad) return true;
            }
        }
    }
    return false;
}

// Fallen blocks share the wall's stone geometry and become solid once they
// settle. A walker can step onto a block only within the tomb's climb limit.
__attribute__((noinline))
float streetTombDebrisStand(device const GameState &game, float2 p,
    float foot, float ground) {
    float top = ground;
    for (uint i = 0u; i < masonryDebrisCount; ++i) {
        if (game.masonryDebrisVelocity[i].w < 1.5f) continue;
        device const HousePart &part = game.house.parts[
            game.house.debrisParts[i]];
        if (all(p >= part.lower.xz) && all(p <= part.upper.xz)
            && part.upper.y <= foot + streetTombClimb)
            top = max(top, part.upper.y);
    }
    return top;
}

__attribute__((noinline))
bool streetTombDebrisBlocked(device const GameState &game, float2 p,
    float foot) {
    for (uint i = 0u; i < masonryDebrisCount; ++i) {
        if (game.masonryDebrisVelocity[i].w < 1.5f) continue;
        device const HousePart &part = game.house.parts[
            game.house.debrisParts[i]];
        float2 gap = max(max(part.lower.xz - p,
            p - part.upper.xz), float2(0.0f));
        if (length(gap) < housePlayerPad
            && part.upper.y > foot + streetTombClimb
            && part.lower.y < foot + 1.75f) return true;
    }
    return false;
}

// The ruin's hall in world x and z, lower corner then upper; the tomb is
// turned about, so its broken +x wall faces the other tomb and its back
// the base. Then its floor and the entablature's underside over it.
constant float4 streetRuinAt = streetProperties[streetRuinedTomb].at;
constant float4 streetLairHall = float4(
    streetRuinAt.x - streetRuinAt.w * mausoleumHall.z,
    streetRuinAt.z - streetRuinAt.w * mausoleumHall.w,
    streetRuinAt.x - streetRuinAt.w * mausoleumHall.x,
    streetRuinAt.z - streetRuinAt.w * mausoleumHall.y);
constant float2 streetLairLevels = float2(
    streetRuinAt.y + streetRuinAt.w * mausoleumPlinthTop,
    streetRuinAt.y + streetRuinAt.w * mausoleumEntablature);

// True for a point in the hall, or on its walls, floor or ceiling.
bool streetLairHolds(float3 p) {
    const float margin = 0.05f;
    return all(p.xz > streetLairHall.xy - margin)
        && all(p.xz < streetLairHall.zw + margin)
        && p.y > streetLairLevels.x - margin
        && p.y < streetLairLevels.y + margin;
}

// The candles stand in a cluster on the hall's floor by its east wall,
// at their real size: x and z from the cluster's centre, and height.
constant float2 streetLairCandlesAt = float2(48.4f, -2.5f);
constant uint streetLairCandleCount = 7u;
constant float3 streetLairCandles[streetLairCandleCount] = {
    float3(0.0f, 0.0f, 0.36f), float3(0.16f, 0.09f, 0.26f),
    float3(-0.12f, 0.14f, 0.3f), float3(0.05f, -0.17f, 0.22f),
    float3(-0.2f, -0.08f, 0.18f), float3(0.27f, -0.1f, 0.32f),
    float3(-0.04f, 0.3f, 0.2f)};

void addStreetLairCandles(device HouseModel &house) {
    for (uint i = 0u; i < streetLairCandleCount; ++i) {
        float3 c = streetLairCandles[i];
        float3 foot = float3(streetLairCandlesAt.x + c.x, streetLairLevels.x,
            streetLairCandlesAt.y + c.y);
        addHouseWorldPart(house, houseBox(foot - float3(0.025f, 0.0f, 0.025f),
            foot + float3(0.025f, c.z, 0.025f), houseCandle));
    }
}

// The candles' light, a little above their flames. It reaches only the
// hall; the haunting dims it with the house's lights.
PointLight streetLairLight(device const GameState &game) {
    return {float3(streetLairCandlesAt.x, streetLairLevels.x + 0.45f,
            streetLairCandlesAt.y),
        float3(1.0f, 0.6f, 0.26f),
        90.0f * houseFlicker(game.effects.x, 3.1f, 0.25f)
            * houseHaunting(game).dim, false};
}

// Ruins the copy just made on c, whose group is still open: replace its
// plinth, cap and corner pilaster, then add the fallen blocks and candles.
void ruinStreetTomb(device HouseModel &house, StreetProperty c) {
    if (house.counts.y == 0u) return;
    uint first = uint(house.groups[house.counts.y - 1u].lower.w);
    float3 source = streetTombSource;
    for (uint k = 0u; k < mausoleumRuinBlockCount; ++k) {
        HousePart part = streetCopyPart(mausoleumRuinPart(k, source), c,
            source);
        if (k < mausoleumRuinReplaced)
            house.parts[min(first + mausoleumRuinReplaces[k],
                houseCapacity - 1u)] = part;
        else
            addHouseWorldPart(house, part);
    }
    addStreetLairCandles(house);
}

// Six wall panels make a hollow cella with its barred doorway. The panel
// bounds cull rays; its stones are generated from rows and columns at hit
// time, so removing a block never exposes a solid backing wall.
void addStreetTombMasonry(device HouseModel &house, StreetProperty c,
    uint instance) {
    const float3 source = streetTombSource;
    const float3 lower[6] = {
        float3(-2.55f, 0.6f, 0.0f),
        float3(-0.62f, 3.15f, 0.0f),
        float3(0.62f, 0.6f, 0.0f),
        float3(-2.55f, 0.6f, 5.0f),
        float3(-2.55f, 0.6f, 0.3f),
        float3(2.25f, 0.6f, 0.3f)};
    const float3 upper[6] = {
        float3(-0.62f, 4.3f, 0.3f),
        float3(0.62f, 4.3f, 0.3f),
        float3(2.55f, 4.3f, 0.3f),
        float3(2.55f, 4.3f, 5.3f),
        float3(-2.25f, 4.3f, 5.0f),
        float3(2.55f, 4.3f, 5.0f)};
    for (uint wall = 0u; wall < 6u; ++wall) {
        HousePart part = streetCopyPart(houseBox(source + lower[wall],
            source + upper[wall], houseMasonry), c, source);
        float axis = (wall == 4u || wall == 5u) ? 1.0f : 0.0f;
        part.windows = float4(1.25f, 0.8f, float(instance * 6u + wall), axis);
        house.masonryParts[instance * 6u + wall] = house.counts.x;
        addHouseWorldPart(house, part);
    }
    // Reserved parts are updated by the debris tick without changing the
    // building's part ranges. Their bounds stay inside the padded group.
    for (uint k = 0u; k < masonryDebrisCount / 2u; ++k) {
        uint slot = instance * (masonryDebrisCount / 2u) + k;
        house.debrisParts[slot] = house.counts.x;
        addHouseWorldPart(house, houseBox(c.at.xyz, c.at.xyz, houseGrave));
    }
    uint group = house.counts.y - 1u;
    house.groups[group].lower.xyz -= float3(12.0f, 0.0f, 12.0f);
    house.groups[group].upper.xyz += float3(12.0f, 4.0f, 12.0f);
}

void resetStreetTombMasonry(device GameState &game) {
    for (uint panel = 0u; panel < masonryPanelCount; ++panel)
        for (uint row = 0u; row < masonryMaxRows; ++row)
            game.masonryGone[panel][row] = 0u;
    StreetProperty ruin = streetProperties[streetRuinedTomb];
    for (uint wall = 3u; wall < 6u; wall += 2u) {
        uint panel = wall;
        device const HousePart &part = game.house.parts[
            game.house.masonryParts[panel]];
        for (uint row = 0u; row < masonryRows(part); ++row) {
            for (uint col = 0u; col < masonryColumns(part); ++col) {
                float3 lower, upper;
                masonryStoneBox(part, row, col, lower, upper);
                if (any(lower >= upper)) continue;
                float3 middle = 0.5f * (lower + upper);
                float2 local = streetTombLocal(ruin, middle.xz);
                float height = (middle.y - ruin.at.y) / ruin.at.w;
                float edge = 0.30f * (houseHash(float(row * 29u + col * 11u
                    + wall * 73u)) - 0.5f);
                bool gone = wall == 3u
                    ? local.x > 0.6f && height < 1.55f
                        + 0.92f * (local.x - 0.6f) + edge
                    : local.y > 3.0f && height < 1.45f
                        + 0.88f * (local.y - 3.0f) + edge;
                if (gone) game.masonryGone[panel][row] |= 1u << col;
            }
        }
    }
    for (uint i = 0u; i < masonryDebrisCount; ++i)
        game.masonryDebrisVelocity[i] = float4(0.0f);
    for (uint i = 0u; i < masonryDebrisCount; ++i) {
        StreetProperty c = streetProperties[streetTombFirst
            + i / (masonryDebrisCount / 2u)];
        game.house.parts[game.house.debrisParts[i]] = houseBox(c.at.xyz,
            c.at.xyz, houseGrave);
    }
    game.masonryDebrisNext[0] = 0u;
    game.masonryDebrisNext[1] = 0u;
}

void launchMasonryStone(device GameState &game, uint instance,
    float3 centre, float3 halfSize, float3 blast, float seed) {
    uint slot = instance * (masonryDebrisCount / 2u)
        + game.masonryDebrisNext[instance]++ % (masonryDebrisCount / 2u);
    uint partIndex = game.house.debrisParts[slot];
    float3 radius = max(halfSize * 0.82f, float3(0.04f));
    game.house.parts[partIndex] = houseBox(centre - radius,
        centre + radius, houseGrave);
    float3 away = centre - blast;
    away = length(away) > 0.01f ? normalize(away)
        : float3(0.0f, 0.5f, 1.0f);
    game.masonryDebrisVelocity[slot] = float4(
        away * (3.0f + 2.5f * seed) + float3(0.0f, 2.5f, 0.0f), 1.0f);
}

// The same occupancy bit that opens a sightline launches the detached block.
// A local radius leaves whole stones at the edge; it can straddle two panels
// at a corner and repeated strikes enlarge the opening.
__attribute__((noinline))
void damageStreetTombMasonry(device GameState &game, float3 blast) {
    const float reach = 2.9f;
    for (uint panel = 0u; panel < masonryPanelCount; ++panel) {
        uint partIndex = game.house.masonryParts[panel];
        device const HousePart &part = game.house.parts[partIndex];
        HouseTurn turn = housePartTurn(game.house, partIndex);
        float3 point = houseTurnPointIn(turn, blast);
        if (distance(point, clamp(point, part.lower.xyz, part.upper.xyz))
            >= reach) continue;
        for (uint row = 0u; row < masonryRows(part); ++row) {
            float y0 = part.lower.y + float(row) * part.windows.y;
            if (abs(point.y - (y0 + 0.5f * part.windows.y))
                > reach + part.windows.y) continue;
            for (uint col = 0u; col < masonryColumns(part); ++col) {
                if (masonryStoneGone(game, panel, row, col)) continue;
                float3 lower, upper;
                masonryStoneBox(part, row, col, lower, upper);
                if (any(lower >= upper)) continue;
                float seed = houseHash(float(panel * 101u + row * 29u
                    + col * 13u));
                if (distance(point, clamp(point, lower, upper))
                    > reach * (0.82f + 0.22f * seed)) continue;
                game.masonryGone[panel][row] |= 1u << col;
                float3 centre = houseTurnPointOut(turn,
                    0.5f * (lower + upper));
                launchMasonryStone(game, panel / 6u, centre,
                    0.5f * (upper - lower), blast, seed);
            }
        }
    }
}

__attribute__((noinline))
void advanceStreetTombDebris(device GameState &game, float dt) {
    for (uint i = 0u; i < masonryDebrisCount; ++i) {
        float4 motion = game.masonryDebrisVelocity[i];
        if (motion.w < 0.5f || motion.w > 1.5f) continue;
        uint partIndex = game.house.debrisParts[i];
        device HousePart &part = game.house.parts[partIndex];
        float3 radius = 0.5f * (part.upper.xyz - part.lower.xyz);
        float3 centre = 0.5f * (part.upper.xyz + part.lower.xyz);
        motion.y -= 9.8f * dt;
        centre += motion.xyz * dt;
        uint instance = i / (masonryDebrisCount / 2u);
        float floorY = streetTombStand(centre.xz,
            streetProperties[streetTombFirst + instance].at.y);
        if (centre.y - radius.y <= floorY) {
            centre.y = floorY + radius.y;
            motion.xz *= 0.55f;
            motion.y = abs(motion.y) > 1.1f ? -motion.y * 0.23f : 0.0f;
            if (motion.y == 0.0f) motion.w = 2.0f;
        }
        part.lower.xyz = centre - radius;
        part.upper.xyz = centre + radius;
        game.masonryDebrisVelocity[i] = motion;
    }
}

// ---------------------------------------------------------------- building

// Runs in the initialize pass after the originals: the copies north of the
// road as one site and those south of it as another, then the lamps and the
// signs, one group each, as a third.
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
                uint group = house.counts.y - 1u;
                uint part = uint(house.groups[group].lower.w)
                    + mausoleumCellaPart;
                house.parts[part] = houseBox(c.at.xyz, c.at.xyz,
                    houseGrave);
                if (i == streetRuinedTomb) ruinStreetTomb(house, c);
                addStreetTombMasonry(house, c, i - streetTombFirst);
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
    for (uint i = 0u; i < streetSignCount; ++i) {
        beginHouseGroup(house);
        addStreetSign(house, i);
    }
}

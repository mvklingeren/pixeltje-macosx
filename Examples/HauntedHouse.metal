// The haunted house for HauntedHouseProgram.metal: a Victorian house on a
// levelled, fenced lot at the end of a flagstone path from the base exit.
//
// buildHouse runs once in the initialize pass and writes the house into the
// game buffer as convex parts: boxes, some cut by sloping planes into
// gables, hips, a mansard, spires and a tapered coffin. A ray tests a group
// of parts only when it enters the group's bounds. Shingles, windows,
// wallpaper and the rest are shaded onto those parts; the clapboards and
// battens are traced in relief on the walls' faces. A timber generator lays
// real boards and logs: loose clapboards hanging from one nail, the grave
// crosses and the mantel log.
//
// The ground floor is open: a hall with a staircase, a parlour with a
// fireplace and a coffin, and a dining room. A small graveyard of crosses,
// headstones and a tomb surrounds the house. Floors, steps, walls and graves
// for walking come from the same layout constants in straight-line code, so
// the spider and drone kernels that test walkability never loop over the
// parts.
//
// Shooting any window wakes the house: its lights go out, a wind rises and
// blows the curtains about, a poison green glow snaps on, and a ghost flies
// out of the front doors at you.

// ------------------------------------------------------------------ layout
// House-local coordinates: x across the facade, y up from the levelled lot,
// z from the front (negative, facing the base) to the back. One local unit
// is houseScale metres: the whole house, its lot, lamps and footing grow
// with it, while siding, slate and brick keep their real size.
constant float3 houseOrigin = float3(0.0f, -2.3f, 128.0f);
constant float houseScale = 2.0f;
constant float houseFloorY = 0.75f;      // ground floor boards and porch deck
constant float houseCeilingY = 4.15f;    // ground floor ceiling
constant float houseEavesY = 7.35f;      // top of the upper storey
constant float housePartitionX = 2.2f;   // hall face of the two partitions
constant float2 houseInnerDoorZ = float2(-2.8f, -0.8f);
constant float houseInnerDoorHeight = 2.4f;
constant float houseDoorHalfWidth = 0.9f;
constant float houseDoorHeight = 2.6f;
constant float housePorchFront = -9.6f;
constant float housePostZ = -9.35f;
constant float housePostX[3] = {1.75f, 5.05f, 8.35f};
constant uint houseStepCount = 5u;
constant float houseStepRun = 0.3f;
constant float houseStepHalfWidth = 1.5f;
constant uint houseStairCount = 12u;
constant float houseStairStart = 1.9f;
constant float houseStairRun = 0.225f;
constant float houseStairRise = 0.1f;
constant float2 houseLotLower = float2(-15.0f, -17.0f);  // the fence
constant float2 houseLotUpper = float2(15.0f, 9.0f);
constant float houseGatePostX = 2.0f;
constant float housePlayerPad = 0.4f;

// Styles; a part's material is houseMaterialBase plus its style. The
// cut-out styles are thin panels whose openings rays pass through.
constant uint houseMaterialBase = 70u;
constant uint houseSiding = 0u;     // clapboard; wallpaper and plaster inside
constant uint houseBattens = 1u;    // board and batten: bay, dormers, tower
constant uint houseRoof = 2u;       // slate; fish-scale shingles on gable ends
constant uint houseTrim = 3u;       // painted wood: posts, fascia, belt, doors
constant uint houseStone = 4u;      // foundation, deck, steps; boards on top
constant uint houseBrick = 5u;      // chimneys and the fireplace
constant uint houseIron = 6u;       // the fence (cut out)
constant uint houseCresting = 7u;   // roof cresting (cut out)
constant uint houseRailing = 8u;    // porch balusters (cut out)
constant uint houseFrieze = 9u;     // porch arches (cut out)
constant uint houseFurniture = 10u;
constant uint houseLantern = 11u;
constant uint houseCandle = 12u;    // a wax candle and its flame (cut out)
constant uint houseTimber = 13u;    // a board or beam from addHouseBoard
constant uint houseLog = 14u;       // a round log from addHouseLog
constant uint houseGrave = 15u;     // headstones and the tomb
constant uint houseStyleCount = 16u;

bool houseMaterial(uint material) {
    return material >= houseMaterialBase
        && material < houseMaterialBase + houseStyleCount;
}

float3 houseLocal(float3 world) {
    return (world - houseOrigin) / houseScale;
}

float2 houseLocal(float2 worldXZ) {
    return (worldXZ - houseOrigin.xz) / houseScale;
}

float3 houseWorld(float3 local) {
    return houseOrigin + local * houseScale;
}

// A repeatable hash in [0, 1) for the house's irregularities.
float houseHash(float seed) {
    return fract(sin(seed * 12.9898f + 4.1414f) * 43758.5453f);
}

// ----------------------------------------------------------------- builder

HousePart houseBox(float3 lower, float3 upper, uint style) {
    HousePart part;
    part.lower = float4(lower, float(style));
    part.upper = float4(upper, 0.0f);
    for (uint k = 0u; k < 4u; ++k) part.planes[k] = float4(0.0f);
    part.windows = float4(0.0f);
    part.rows = float4(0.0f, 1.0f, 0.0f, 1.0f);
    return part;
}

// Keeps the part behind a plane through `through`; normal points outward.
void houseCut(thread HousePart &part, float3 normal, float3 through) {
    uint k = uint(part.upper.w);
    if (k >= 4u) return;
    float3 n = normalize(normal);
    part.planes[k] = float4(n, dot(n, through));
    part.upper.w = float(k + 1u);
}

// Two roof planes rise from the box's lower long edges to a ridge along z
// (or along x) at the top of the box.
HousePart houseGable(float3 lower, float3 upper, bool ridgeAlongZ,
    uint style) {
    HousePart part = houseBox(lower, upper, style);
    float rise = upper.y - lower.y;
    float3 eave = float3(upper.x, lower.y, upper.z);
    if (ridgeAlongZ) {
        float halfSpan = 0.5f * (upper.x - lower.x);
        houseCut(part, float3(-rise, halfSpan, 0.0f), lower);
        houseCut(part, float3(rise, halfSpan, 0.0f), eave);
    } else {
        float halfSpan = 0.5f * (upper.z - lower.z);
        houseCut(part, float3(0.0f, halfSpan, -rise), lower);
        houseCut(part, float3(0.0f, halfSpan, rise), eave);
    }
    return part;
}

// All four faces lean in by inset over the box height: a hip, a mansard
// slope, or with the inset at half the size, a spire.
HousePart houseHip(float3 lower, float3 upper, float2 inset, uint style) {
    HousePart part = houseBox(lower, upper, style);
    float rise = upper.y - lower.y;
    float3 eave = float3(upper.x, lower.y, upper.z);
    houseCut(part, float3(-rise, inset.x, 0.0f), lower);
    houseCut(part, float3(rise, inset.x, 0.0f), eave);
    houseCut(part, float3(0.0f, inset.y, -rise), lower);
    houseCut(part, float3(0.0f, inset.y, rise), eave);
    return part;
}

// A four-sided spire whose apex leans off centre by `lean`, as old timber
// settles. The lean must stay inside the base.
HousePart houseSpire(float3 lower, float3 upper, float2 lean, uint style) {
    HousePart part = houseBox(lower, upper, style);
    float rise = upper.y - lower.y;
    float2 apex = 0.5f * (lower.xz + upper.xz) + lean;
    float3 eave = float3(upper.x, lower.y, upper.z);
    houseCut(part, float3(-rise, apex.x - lower.x, 0.0f), lower);
    houseCut(part, float3(rise, upper.x - apex.x, 0.0f), eave);
    houseCut(part, float3(0.0f, apex.y - lower.z, -rise), lower);
    houseCut(part, float3(0.0f, upper.z - apex.y, rise), eave);
    return part;
}

// Windows sit centred in equal cells across each vertical face: `counts`
// across the ±z faces and across the ±x faces. Rows stack `pitch` apart from
// the first sill; glow scales how brightly the room behind them is lit.
void houseWindows(thread HousePart &part, float2 counts, float2 size,
    float sill, float rows, float pitch, float glow) {
    part.windows = float4(counts, size);
    part.rows = float4(sill, rows, pitch, glow);
}

void beginHouseGroup(device HouseModel &house) {
    uint g = house.counts.y;
    if (g >= houseGroupCapacity) return;
    float first = float(house.counts.x);
    house.groups[g].lower = float4(float3(1.0e9f), first);
    house.groups[g].upper = float4(float3(-1.0e9f), first);
    house.counts.y = g + 1u;
}

// Adds a part already in world metres to the open group.
void addHouseWorldPart(device HouseModel &house, HousePart part) {
    uint i = house.counts.x;
    if (i >= houseCapacity || house.counts.y == 0u) return;
    house.parts[i] = part;
    house.counts.x = i + 1u;
    uint g = house.counts.y - 1u;
    HouseGroup group = house.groups[g];
    house.groups[g].lower = float4(min(group.lower.xyz, part.lower.xyz),
        group.lower.w);
    house.groups[g].upper = float4(max(group.upper.xyz, part.upper.xyz),
        float(i + 1u));
}

// Scales a house-local part into the world and adds it to the open group.
// Window sizes stay in local units; houseWindow measures in them.
void addHousePart(device HouseModel &house, HousePart part) {
    part.lower.xyz = houseWorld(part.lower.xyz);
    part.upper.xyz = houseWorld(part.upper.xyz);
    for (uint k = 0u; k < 4u; ++k)
        part.planes[k].w = part.planes[k].w * houseScale
            + dot(part.planes[k].xyz, houseOrigin);
    addHouseWorldPart(house, part);
}

// Adds a piece of furniture at its real size: its anchor moves with the
// house's scale, but the part keeps its size around the anchor.
void addHouseProp(device HouseModel &house, HousePart part, float3 anchor) {
    float3 shift = anchor * (houseScale - 1.0f) / houseScale;
    part.lower.xyz = part.lower.xyz / houseScale + shift;
    part.upper.xyz = part.upper.xyz / houseScale + shift;
    for (uint k = 0u; k < 4u; ++k)
        part.planes[k].w = part.planes[k].w / houseScale
            + dot(part.planes[k].xyz, shift);
    addHousePart(house, part);
}

// ------------------------------------------------------------------ timber
// The timber generator lays boards, beams and logs at their real size in
// world metres. A board lies flat in a plane whose normal is a world axis
// and may turn within that plane, so a loose plank can swing from its last
// nail and a grave cross can lean: its box is cut by four planes along its
// edges. A log is a round trunk, traced as a capped cylinder.
//
// A board keeps its frame for shading: windows holds its unit length
// direction and half length, rows its centre and how it is nailed, and its
// third cutting plane its width direction.
constant float houseNailsAtEnds = 0.0f;   // now and then a nail or a hole
                                          // near each end
constant float houseNailAtCentre = 1.0f;  // one nail through the middle
constant float houseNailAtPivot = 2.0f;   // a painted clapboard hanging
                                          // from the nail at its start; the
                                          // other end's nail pulled out
constant float houseNoNails = 3.0f;

// size is length, width and thickness. along need not be square to normal;
// the board turns about normal to follow it.
void addHouseBoard(device HouseModel &house, float3 centre, float3 along,
    float3 normal, float3 size, float nails) {
    float3 a = normalize(along - normal * dot(along, normal));
    float3 b = cross(normal, a);
    float3 h = 0.5f * size;
    float3 reach = abs(a) * h.x + abs(b) * h.y + abs(normal) * h.z;
    HousePart part = houseBox(centre - reach, centre + reach, houseTimber);
    houseCut(part, a, centre + a * h.x);
    houseCut(part, -a, centre - a * h.x);
    houseCut(part, b, centre + b * h.y);
    houseCut(part, -b, centre - b * h.y);
    part.windows = float4(a, h.x);
    part.rows = float4(centre, nails);
    addHouseWorldPart(house, part);
}

// A round log along any direction.
void addHouseLog(device HouseModel &house, float3 centre, float3 along,
    float halfLength, float radius) {
    float3 a = normalize(along);
    float3 reach = abs(a) * halfLength
        + sqrt(max(1.0f - a * a, float3(0.0f))) * radius;
    HousePart part = houseBox(centre - reach, centre + reach, houseLog);
    part.windows = float4(a, halfLength);
    part.rows = float4(centre, radius);
    addHouseWorldPart(house, part);
}

// Entry distance of a ray into a log, or -1. A ray that starts inside the
// log misses it, as with every other part.
float houseLogHit(device const HousePart &part, float3 origin,
    float3 direction, float limit, thread float3 &normal) {
    float3 a = part.windows.xyz;
    float halfLength = part.windows.w, radius = part.rows.w;
    float3 offset = origin - part.rows.xyz;
    float offsetAlong = dot(offset, a), directionAlong = dot(direction, a);
    float3 offsetAcross = offset - a * offsetAlong;
    float3 directionAcross = direction - a * directionAlong;
    float qa = dot(directionAcross, directionAcross);
    float qb = dot(offsetAcross, directionAcross);
    float qc = dot(offsetAcross, offsetAcross) - radius * radius;
    if (qc < 0.0f && abs(offsetAlong) < halfLength) return -1.0f;
    float best = -1.0f;
    if (qa > 1.0e-8f) {
        float discriminant = qb * qb - qa * qc;
        if (discriminant >= 0.0f) {
            float t = (-qb - sqrt(discriminant)) / qa;
            if (t > 1.0e-4f && t < limit
                && abs(offsetAlong + directionAlong * t) <= halfLength) {
                best = t;
                normal = normalize(offsetAcross + directionAcross * t);
            }
        }
    }
    if (abs(directionAlong) > 1.0e-6f) {
        float side = offsetAlong > 0.0f ? 1.0f : -1.0f;
        float t = (side * halfLength - offsetAlong) / directionAlong;
        float3 rim = offsetAcross + directionAcross * t;
        if (t > 1.0e-4f && t < limit && (best < 0.0f || t < best)
            && dot(rim, rim) <= radius * radius) {
            best = t;
            normal = a * side;
        }
    }
    return best;
}

// ----------------------------------------------------------------- windows

float houseLines(float coord, float spacing, float width, float blur);

struct HouseWindow {
    float glass;    // coverage of the clear panes
    float drape;    // coverage of the curtains tied back at the sides
    float frame;    // coverage of the sash, mullions, casing and boards
    float2 uv;      // -1 to 1 across the pane, 0 at the sill to 1 at the top
    float seed;     // the same for every pixel of one window
    float row;
    float boarded;  // 1 where planks are nailed across the window
    float4 room;    // u and v from the sill's centre, half width, height
    float cell;     // width of the window's cell along the wall
    float fold;     // -1 to 1 across the curtains' folds
};

// The wind that blows through the house while it is haunted. Every caller
// of houseWindow passes it, so the trace, a shot and the shading all see
// the curtains where the wind has blown them.
struct HouseWind {
    float strength; // 0 while the house is quiet, 1 in the full gale
    float time;     // seconds, which moves the curtains
};

HouseWind houseWind(device const GameState &game);

// Windows with negative glow look into the real ground floor rooms: rays
// pass through their glass. The others are in solid parts and show a room
// shaded behind the pane.
bool houseSeeThrough(device const HousePart &part) {
    return part.rows.w < 0.0f;
}

float houseWindowSeed(uint index, float k, float row, bool zFace) {
    return float(index) * 7.31f + k * 1.73f + row * 3.17f
        + (zFace ? 0.0f : 50.0f);
}

// How a window departs from its cell: centre shift across the wall, sill
// shift, and width and height factors. buildHouse places sill candles with
// it, so they stand on the window they belong to.
float4 houseWindowShift(float seed, float cell, float baseWidth) {
    float width = baseWidth * (0.92f + 0.14f * houseHash(seed + 1.0f));
    float slack = max(0.5f * (cell - width) - 0.13f, 0.0f);
    return float4(min(slack, 0.09f) * (2.0f * houseHash(seed + 3.0f) - 1.0f),
        0.07f * (houseHash(seed + 4.0f) - 0.5f),
        0.92f + 0.14f * houseHash(seed + 1.0f),
        0.94f + 0.1f * houseHash(seed + 2.0f));
}

// The pointed-arch window under p on a vertical face of part, if any. It is
// measured in house-local units. No two windows are alike: each sits a
// little off its cell, is its own size, leans, and has the tip of its arch
// pushed to one side, as an old frame settles. A few are boarded up. The
// seed ignores which side of the wall is shaded, so a window looks the same
// from the room and from outside.
HouseWindow houseWindow(device const HousePart &part, uint index, float3 p,
    float3 n, float blur, HouseWind wind) {
    HouseWindow w = {0.0f, 0.0f, 0.0f, float2(0.0f), 0.0f, 0.0f, 0.0f,
        float4(0.0f), 0.0f, 0.0f};
    if (abs(n.y) > 0.5f) return w;
    bool zFace = abs(n.z) > 0.5f;
    float count = zFace ? part.windows.x : part.windows.y;
    if (count < 0.5f) return w;
    blur /= houseScale;
    float lo = (zFace ? part.lower.x : part.lower.z) / houseScale;
    float hi = (zFace ? part.upper.x : part.upper.z) / houseScale;
    float s = (zFace ? p.x : p.z) / houseScale;
    float cell = (hi - lo) / count;
    float k = clamp(floor((s - lo) / cell), 0.0f, count - 1.0f);
    float u = s - (lo + (k + 0.5f) * cell);
    float y = (p.y - part.lower.y) / houseScale - part.rows.x;
    float row = part.rows.y > 1.5f
        ? clamp(floor(y / part.rows.z), 0.0f, part.rows.y - 1.0f) : 0.0f;
    float v = y - row * part.rows.z;
    float seed = houseWindowSeed(index, k, row, zFace);
    float4 shift = houseWindowShift(seed, cell, part.windows.z);
    float width = part.windows.z * shift.z;
    float height = part.windows.w * shift.w;
    u -= shift.x;
    v -= shift.y;
    float roomU = u, roomV = v;
    // The frame leans, and its sill sags in the middle.
    u -= 0.05f * (houseHash(seed + 5.0f) - 0.5f) * v;
    float halfSpan = 0.5f * width;
    v += 0.025f * houseHash(seed + 6.0f)
        * (1.0f - saturate(u * u / (halfSpan * halfSpan)));
    // Two arcs of radius 0.7 width meet 0.67 width above the springing;
    // the meeting point drifts sideways.
    float radius = 0.7f * width;
    float spring = height - 0.67f * width;
    float tipShift = 0.14f * width * (houseHash(seed + 7.0f) - 0.5f);
    float archU = u - tipShift * saturate((v - spring) / (height - spring));
    float inside = v < spring ? min(halfSpan - abs(u), v)
        : min(radius - length(float2(abs(archU) + radius - halfSpan,
            v - spring)), v);
    const float casing = 0.11f;
    if (inside < -casing - blur) return w;
    float opening = smoothstep(-blur, blur, inside);
    // Sash, a centre mullion, a transom at the springing and glazing bars
    // dividing the lower lights into small panes.
    float glazing = min(abs(abs(u) - 0.5f * halfSpan) - 0.012f,
        abs(fract(v / 0.42f + 0.5f) - 0.5f) * 0.42f - 0.012f);
    float bars = min(min(inside - 0.05f, abs(archU) - 0.022f),
        abs(v - spring) - 0.022f);
    if (v < spring) bars = min(bars, glazing);
    w.boarded = houseHash(seed + 8.0f) > 0.88f ? 1.0f : 0.0f;
    if (w.boarded > 0.5f) {
        // Two planks nailed across at odd angles.
        float plank = min(abs(v - 0.42f * height - 0.45f * u),
            abs(v - 0.6f * height + 0.3f * u)) - 0.075f;
        bars = min(bars, plank);
    }
    float sash = 1.0f - smoothstep(-blur, blur, bars);
    float pane = opening * (1.0f - sash);
    // Heavy curtains are tied back to both sides, gathered toward the sill.
    float rise = saturate(v / height);
    float across = abs(u) / halfSpan;
    float tie = 0.68f + 0.12f * smoothstep(0.1f, 0.6f, v / height)
        + 0.05f * houseHash(seed + 9.0f);
    // While the house is haunted the wind tears them loose. Hanging from
    // the rod, each curtain billows into the window and falls back in its
    // own gusts, most at the hem, with ripples running down its edge.
    float edge = tie, flutter = 0.0f;
    if (wind.strength > 0.0f) {
        float phase = 6.2832f * houseHash(seed + (u < 0.0f ? 15.0f : 16.0f));
        float t = wind.time;
        float gust = (0.5f + 0.5f * sin(t * 1.9f + phase))
            * (0.55f + 0.45f * sin(t * 0.73f + 1.7f * phase));
        float hem = 1.0f - rise;
        float reach = (0.12f + 0.5f * gust) * (0.4f + 0.6f * hem);
        float ripple = 0.05f * sin(rise * 11.0f - t * 7.0f + phase)
            * (0.3f + 0.7f * hem);
        edge = clamp(tie - wind.strength * (reach - ripple), 0.05f, 0.97f);
        flutter = wind.strength * 1.2f * sin(t * 4.3f + rise * 6.0f + phase);
    }
    w.drape = pane * smoothstep(edge - 0.02f, edge + 0.02f, across);
    w.glass = pane - w.drape;
    w.frame = 1.0f - pane;
    w.uv = float2(u / halfSpan, rise);
    // The folds spread as the cloth swings in and ripple in the wind.
    float spread = (1.0f - tie) / max(1.0f - edge, 0.05f);
    w.fold = sin(sign(u) * (1.0f - (1.0f - across) * spread) * 26.0f
        + 3.0f * rise + flutter);
    w.row = row;
    w.seed = seed;
    w.room = float4(roomU, roomV, halfSpan, height);
    w.cell = cell;
    return w;
}

// ---------------------------------------------------------------- cladding
// The outer walls are clad in wide clapboards, and the bay, dormers and
// tower in board and batten, in metres. A wall part's box is the boards'
// outer face: each clapboard leans back from its proud lower edge to where
// the next one laps over it, and the boards between battens sit back from
// them. houseCladdingRelief finds the real board under the box's face.
// Corner boards, casings and windows stay flush with the face.
constant float houseClapExposure = 0.3f;    // height of each board's course
constant float houseSheathingDepth = 0.05f; // behind a missing board
constant float houseBattenPitch = 0.6f;
constant float houseBattenHalfWidth = 0.045f;
constant float houseBattenDepth = 0.022f;
constant float houseCornerBoard = 0.2f;
constant float2 houseNoSkip = float2(1.0e9f, -1.0e9f);

bool houseInteriorPoint(float3 p);

struct HouseBoardCell {
    float course;   // the board's row
    float lap;      // 0 at its lower edge to 1 where the next board laps it
    float run;      // length of the boards in this row
    float along;    // along the row, shifted so joints fall at whole runs
    float segment;  // which board of the row
    float pick;     // 0 to 1, the same over one board
};

// s runs along the wall and y up from houseOrigin, both in metres.
HouseBoardCell houseClapboardCell(float s, float y, float seed) {
    HouseBoardCell cell;
    cell.course = floor(y / houseClapExposure);
    cell.lap = y / houseClapExposure - cell.course;
    cell.run = 1.8f + 1.9f * hashTile(float2(cell.course, seed + 3.0f));
    cell.along = s + cell.run * hashTile(float2(cell.course, seed + 5.0f));
    cell.segment = floor(cell.along / cell.run);
    cell.pick = hashTile(float2(cell.course * 1.37f + cell.segment,
        seed + 7.0f));
    return cell;
}

// How far a course's boards lean back from their lower edge, in metres.
float houseClapDepth(float course, float seed) {
    return 0.024f + 0.014f * hashTile(float2(course, seed + 11.0f));
}

// 1 to 4 for the −z, +z, −x and +x faces.
float houseFaceCode(float3 face) {
    return abs(face.z) > 0.5f ? (face.z < 0.0f ? 1.0f : 2.0f)
        : (face.x < 0.0f ? 3.0f : 4.0f);
}

// Each face of each wall part lays its boards out differently.
float houseCladdingSeed(uint index, float faceCode) {
    return float(index) * 3.1f + 17.0f * (faceCode - 1.0f);
}

// The vertical face of a part's box nearest p, which lies on or just
// behind it.
float3 houseFaceNormal(device const HousePart &part, float3 p) {
    float4 gap = float4(p.x - part.lower.x, part.upper.x - p.x,
        p.z - part.lower.z, part.upper.z - p.z);
    float nearest = min(min(gap.x, gap.y), min(gap.z, gap.w));
    if (nearest == gap.x) return float3(-1.0f, 0.0f, 0.0f);
    if (nearest == gap.y) return float3(1.0f, 0.0f, 0.0f);
    if (nearest == gap.z) return float3(0.0f, 0.0f, -1.0f);
    return float3(0.0f, 0.0f, 1.0f);
}

// A clapboard that has rotted away, or that hangs loose in front of the gap
// it left. A clad wall keeps up to four such gaps in its unused cutting
// planes: start and end along the wall, the course's lower edge, face code.
bool houseBoardGone(device const HousePart &part, float faceCode, float s,
    float y, HouseBoardCell cell) {
    if (cell.pick > 0.986f) return true;
    if (uint(part.upper.w) != 0u) return false;
    for (uint k = 0u; k < 4u; ++k) {
        float4 gap = part.planes[k];
        if (gap.w == faceCode && s >= gap.x && s <= gap.y && y >= gap.z
            && y < gap.z + houseClapExposure) return true;
    }
    return false;
}

// The centre of batten k along the wall at height y. Battens stand a little
// crooked, and a few are gone.
float houseBattenCentre(float k, float y, float seed, thread bool &present) {
    float pick = hashTile(float2(k, seed));
    present = pick <= 0.93f;
    return k * houseBattenPitch + 0.04f * (pick - 0.5f)
        + 0.003f * (hashTile(float2(k, seed + 1.0f)) - 0.5f) * y;
}

// Moves a hit on the outer face of a clad wall onto the board beneath it:
// the sloping face of a clapboard, the underside of the one above where a
// rising ray slips under its lap, sheathing where a board is gone, or the
// side or recessed boards of board and batten.
void houseCladdingRelief(thread SceneHit &hit, float3 direction,
    device const GameState &game) {
    uint index = min(hit.variant, houseCapacity - 1u);
    device const HousePart &part = game.house.parts[index];
    uint style = hit.material - houseMaterialBase;
    float3 face = hit.normal, p = hit.position;
    if (abs(face.y) > 0.5f || houseInteriorPoint(p)) return;
    bool zFace = abs(face.z) > 0.5f;
    float lo = zFace ? part.lower.x : part.lower.z;
    float hi = zFace ? part.upper.x : part.upper.z;
    float s = zFace ? p.x : p.z;
    if (min(s - lo, hi - s) < houseCornerBoard) return;
    HouseWindow w = houseWindow(part, index, p, face, 0.002f,
        houseWind(game));
    if (w.glass + w.drape + w.frame > 0.0f) return;
    float into = -dot(direction, face);
    if (into < 0.05f) return;
    const float3 up = float3(0.0f, 1.0f, 0.0f);
    float3 across = zFace ? float3(1.0f, 0.0f, 0.0f) : float3(0.0f, 0.0f, 1.0f);
    float ds = dot(direction, across), dy = direction.y;
    float y = p.y - houseOrigin.y;
    float seed = houseCladdingSeed(index, houseFaceCode(face));
    float t;
    float3 normal = face;
    if (style == houseBattens) {
        bool present;
        float k = round(s / houseBattenPitch);
        float centre = houseBattenCentre(k, y, seed, present);
        if (present && abs(s - centre) < houseBattenHalfWidth) return;
        // The battens either side of p.
        float left = s > centre ? k : k - 1.0f;
        t = houseBattenDepth / into;
        float reach = s + ds * t;
        bool leftPresent, rightPresent;
        float leftEdge = houseBattenCentre(left, y, seed, leftPresent)
            + houseBattenHalfWidth;
        float rightEdge = houseBattenCentre(left + 1.0f, y, seed,
            rightPresent) - houseBattenHalfWidth;
        if (ds > 0.0f && rightPresent && reach > rightEdge) {
            t = (rightEdge - s) / ds;
            normal = -across;
        } else if (ds < 0.0f && leftPresent && reach < leftEdge) {
            t = (leftEdge - s) / ds;
            normal = across;
        }
    } else {
        HouseBoardCell cell = houseClapboardCell(s, y, seed);
        float bottom = cell.course * houseClapExposure;
        float top = bottom + houseClapExposure;
        if (houseBoardGone(part, houseFaceCode(face), s, y, cell)) {
            t = houseSheathingDepth / into;
            float reach = y + dy * t;
            if (reach > top) {
                t = (top - y) / dy;
                normal = -up;
            } else if (reach < bottom) {
                // Into the course below: its top edge, bared by the gap,
                // or its sloping face.
                t = (bottom - y) / dy;
                float below = houseClapDepth(cell.course - 1.0f, seed);
                if (into * t >= below) {
                    normal = up;
                } else {
                    float slope = below / houseClapExposure;
                    t = slope * (y - bottom + houseClapExposure)
                        / (into - slope * dy);
                    normal = normalize(face + up * slope);
                }
            }
        } else {
            float slope = houseClapDepth(cell.course, seed) / houseClapExposure;
            float denominator = into - slope * dy;
            t = denominator > 1.0e-4f ? slope * (y - bottom) / denominator
                : 1.0e9f;
            if (y + dy * t <= top) {
                normal = normalize(face + up * slope);
            } else {
                t = (top - y) / dy;
                normal = -up;
            }
        }
    }
    if (!(t > 0.0f && t < 0.3f)) return;
    hit.distance += t;
    hit.position = p + direction * t;
    hit.normal = normal;
}

// True when a point on a wall's face, at s along it and y up from
// houseOrigin in metres, lies within margin of a window's casing.
bool houseNearWindow(device const HousePart &wall, uint index, bool zFace,
    float2 at, float margin) {
    float count = zFace ? wall.windows.x : wall.windows.y;
    if (count < 0.5f) return false;
    float lo = (zFace ? wall.lower.x : wall.lower.z) / houseScale;
    float hi = (zFace ? wall.upper.x : wall.upper.z) / houseScale;
    float s = at.x / houseScale, pad = 0.14f + margin / houseScale;
    float cell = (hi - lo) / count;
    float k = clamp(floor((s - lo) / cell), 0.0f, count - 1.0f);
    float u = s - (lo + (k + 0.5f) * cell);
    float y = (at.y + houseOrigin.y - wall.lower.y) / houseScale - wall.rows.x;
    float row = wall.rows.y > 1.5f
        ? clamp(floor(y / wall.rows.z), 0.0f, wall.rows.y - 1.0f) : 0.0f;
    float v = y - row * wall.rows.z;
    float4 shift = houseWindowShift(houseWindowSeed(index, k, row, zFace),
        cell, wall.windows.z);
    u -= shift.x;
    v -= shift.y;
    return abs(u) < 0.5f * wall.windows.z * shift.z + pad && v > -pad
        && v < wall.windows.w * shift.w + pad;
}

// A few of the clapboards on one face of a wall part have come loose: each
// hangs from the nail at one end, swung down, in front of the gap it left.
// They come from the same rows and joints houseClapboards shades, between
// heights `height` (metres above houseOrigin) and outside `skip` along the
// wall, and keep clear of the windows.
void addLooseClapboards(device HouseModel &house, uint index, float3 face,
    float2 height, float2 skip, uint limit) {
    if (index >= house.counts.x) return;
    device HousePart &wall = house.parts[index];
    bool zFace = abs(face.z) > 0.5f;
    float faceCode = houseFaceCode(face);
    float seed = houseCladdingSeed(index, faceCode);
    float lo = (zFace ? wall.lower.x : wall.lower.z) + 0.35f;
    float hi = (zFace ? wall.upper.x : wall.upper.z) - 0.35f;
    float outward = faceCode == 1.0f ? wall.lower.z - 0.016f
        : (faceCode == 2.0f ? wall.upper.z + 0.016f
            : (faceCode == 3.0f ? wall.lower.x - 0.016f
                : wall.upper.x + 0.016f));
    uint used = 0u;
    while (used < 4u && wall.planes[used].w != 0.0f) ++used;
    uint added = 0u;
    for (float course = ceil(height.x / houseClapExposure);
        course < floor(height.y / houseClapExposure) && added < limit
            && used < 4u; course += 1.0f) {
        float run = 1.8f + 1.9f * hashTile(float2(course, seed + 3.0f));
        float shift = run * hashTile(float2(course, seed + 5.0f));
        float last = floor((hi + shift) / run);
        for (float segment = floor((lo + shift) / run); segment <= last
            && added < limit && used < 4u; segment += 1.0f) {
            float pick = hashTile(float2(course * 1.37f + segment,
                seed + 7.0f));
            if (pick < 0.925f || pick >= 0.968f) continue;
            float s0 = max(segment * run - shift, lo);
            float s1 = min((segment + 1.0f) * run - shift, hi);
            float span = s1 - s0;
            if (span < 1.2f || (s1 > skip.x && s0 < skip.y)) continue;
            bool fromLeft = hashTile(float2(pick * 91.0f, seed + 13.0f)) < 0.5f;
            float drop = hashTile(float2(pick * 57.0f, seed + 17.0f));
            // Most have dropped a little; one in six hangs nearly straight
            // down.
            float angle = drop > 0.83f
                ? 1.05f + 0.4f * hashTile(float2(pick * 23.0f, seed + 19.0f))
                : 0.1f + 0.3f * drop;
            float middle = (course + 0.5f) * houseClapExposure;
            float2 pivot = float2(fromLeft ? s0 + 0.07f : s1 - 0.07f, middle);
            float2 swing = float2((fromLeft ? 1.0f : -1.0f) * cos(angle),
                -sin(angle));
            bool clear = true;
            for (uint k = 0u; k <= 4u && clear; ++k) {
                float f = 0.25f * float(k);
                float2 hang = pivot + swing * (span - 0.07f) * f;
                clear = hang.y - 0.2f > height.x
                    && !houseNearWindow(wall, index, zFace,
                        float2(mix(s0, s1, f), middle), 0.25f)
                    && !houseNearWindow(wall, index, zFace, hang, 0.3f);
            }
            if (!clear) continue;
            wall.planes[used] = float4(s0, s1, course * houseClapExposure,
                faceCode);
            ++used;
            ++added;
            float2 centre = pivot + swing * (0.5f * span - 0.07f);
            float y = centre.y + houseOrigin.y;
            addHouseBoard(house,
                zFace ? float3(centre.x, y, outward) : float3(outward, y, centre.x),
                zFace ? float3(swing.x, swing.y, 0.0f)
                    : float3(0.0f, swing.y, swing.x),
                face, float3(span, houseClapExposure + 0.03f, 0.026f),
                houseNailAtPivot);
        }
    }
}

uint houseRoom(float3 p);

// --------------------------------------------------------------- the house

void buildHouseBody(device HouseModel &house) {
    const float C = houseCeilingY, U = houseEavesY;
    beginHouseGroup(house);
    // The upper storey's underside is the ground floor ceiling.
    HousePart storey = houseBox(float3(-8.0f, C, -6.0f),
        float3(8.0f, U, 6.0f), houseSiding);
    houseWindows(storey, float2(3.0f), float2(1.05f, 2.0f), 0.7f, 1.0f, 0.0f,
        0.9f);
    uint storeyIndex = house.counts.x;
    addHousePart(house, storey);
    // One loose clapboard on each face, clear of the porch roof and the bay
    // in front and the belt course and mansard skirt above and below.
    float2 upper = float2(C + 0.3f, U - 0.3f) * houseScale;
    addLooseClapboards(house, storeyIndex, float3(0.0f, 0.0f, -1.0f),
        float2(4.6f, U - 0.3f) * houseScale, float2(-3.4f, 3.4f) * houseScale,
        1u);
    addLooseClapboards(house, storeyIndex, float3(0.0f, 0.0f, 1.0f), upper,
        houseNoSkip, 1u);
    addLooseClapboards(house, storeyIndex, float3(-1.0f, 0.0f, 0.0f), upper,
        houseNoSkip, 1u);
    addLooseClapboards(house, storeyIndex, float3(1.0f, 0.0f, 0.0f), upper,
        houseNoSkip, 1u);
    // A belt course starts a hair above the ceiling so the storey stays the
    // ceiling indoors.
    addHousePart(house, houseBox(float3(-8.12f, C + 0.0005f, -6.12f),
        float3(8.12f, C + 0.26f, 6.12f), houseTrim));
    // A bell-cast mansard: a flared skirt under steep slopes, under a low hip.
    addHousePart(house, houseHip(float3(-8.85f, U - 0.25f, -6.85f),
        float3(8.85f, U + 0.35f, 6.85f), float2(0.55f), houseRoof));
    addHousePart(house, houseHip(float3(-8.45f, U, -6.45f),
        float3(8.45f, U + 3.2f, 6.45f), float2(1.0f), houseRoof));
    addHousePart(house, houseHip(float3(-7.45f, U + 3.2f, -5.45f),
        float3(7.45f, U + 4.3f, 5.45f), float2(5.45f), houseRoof));
    // Iron cresting rings the top of the mansard.
    addHousePart(house, houseBox(float3(-7.45f, U + 3.2f, -5.48f),
        float3(7.45f, U + 3.62f, -5.42f), houseCresting));
    addHousePart(house, houseBox(float3(-7.45f, U + 3.2f, 5.42f),
        float3(7.45f, U + 3.62f, 5.48f), houseCresting));
    addHousePart(house, houseBox(float3(-7.48f, U + 3.2f, -5.45f),
        float3(-7.42f, U + 3.62f, 5.45f), houseCresting));
    addHousePart(house, houseBox(float3(7.42f, U + 3.2f, -5.45f),
        float3(7.48f, U + 3.62f, 5.45f), houseCresting));

    // The central bay rises from the porch roof into a steep front gable.
    HousePart bay = houseBox(float3(-3.0f, houseFloorY + 3.1f, -7.5f),
        float3(3.0f, U + 2.6f, -6.0f), houseBattens);
    houseWindows(bay, float2(1.0f, 0.0f), float2(1.35f, 2.0f),
        C + 0.75f - (houseFloorY + 3.1f), 2.0f, 2.85f, 1.15f);
    addHousePart(house, bay);
    HousePart gable = houseGable(float3(-3.35f, U + 2.6f, -7.85f),
        float3(3.35f, U + 7.0f, -0.6f), true, houseRoof);
    houseWindows(gable, float2(1.0f, 0.0f), float2(0.8f, 1.7f), 0.55f, 1.0f,
        0.0f, 1.0f);
    addHousePart(house, gable);

    // A slender belfry tower behind the gable, under a needle spire that
    // has settled off true.
    HousePart tower = houseBox(float3(-1.15f, U + 3.2f, -2.75f),
        float3(1.15f, U + 9.0f, -0.45f), houseBattens);
    houseWindows(tower, float2(1.0f), float2(0.7f, 1.55f), 4.05f, 1.0f, 0.0f,
        1.5f);
    addHousePart(house, tower);
    addHousePart(house, houseBox(float3(-1.35f, U + 9.0f, -2.95f),
        float3(1.35f, U + 9.3f, -0.25f), houseTrim));
    addHousePart(house, houseSpire(float3(-1.3f, U + 9.3f, -2.9f),
        float3(1.3f, U + 16.5f, -0.3f), float2(0.38f, -0.22f), houseRoof));

    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        // Pinnacles on the gable's eaves and the mansard's front corners,
        // each leaning its own way.
        float gableX = s * 3.35f, cornerX = s * 7.45f;
        float2 lean = 0.14f * float2(houseHash(s * 3.0f) - 0.5f,
            houseHash(s * 5.0f) - 0.5f);
        addHousePart(house, houseSpire(float3(gableX - 0.2f, U + 2.6f, -8.05f),
            float3(gableX + 0.2f, U + 4.7f, -7.65f), lean, houseRoof));
        addHousePart(house, houseSpire(
            float3(cornerX - 0.22f, U + 3.2f, -5.67f),
            float3(cornerX + 0.22f, U + 5.3f, -5.23f), lean.yx * 1.2f,
            houseRoof));
        // A gabled dormer in the front slope and one in the side slope.
        float x = s * 5.5f;
        HousePart dormer = houseBox(float3(x - 0.95f, U + 0.3f, -6.75f),
            float3(x + 0.95f, U + 2.15f, -4.6f), houseBattens);
        houseWindows(dormer, float2(1.0f, 0.0f), float2(0.85f, 1.4f), 0.25f,
            1.0f, 0.0f, 0.85f);
        addHousePart(house, dormer);
        addHousePart(house, houseGable(float3(x - 1.15f, U + 2.15f, -6.95f),
            float3(x + 1.15f, U + 3.3f, -4.6f), true, houseRoof));
        float inner = s * 6.6f, outer = s * 8.75f, gableOuter = s * 8.95f;
        HousePart sideDormer = houseBox(
            float3(min(inner, outer), U + 0.3f, -0.95f),
            float3(max(inner, outer), U + 2.15f, 0.95f), houseBattens);
        houseWindows(sideDormer, float2(0.0f, 1.0f), float2(0.85f, 1.4f),
            0.25f, 1.0f, 0.0f, 0.85f);
        addHousePart(house, sideDormer);
        addHousePart(house, houseGable(
            float3(min(inner, gableOuter), U + 2.15f, -1.15f),
            float3(max(inner, gableOuter), U + 3.3f, 1.15f), false,
            houseRoof));
        // Brick chimneys with stone caps rise through the back of the roof.
        float c = s * 6.0f;
        addHousePart(house, houseBox(float3(c - 0.5f, U + 1.0f, 2.5f),
            float3(c + 0.5f, U + 6.3f, 3.5f), houseBrick));
        addHousePart(house, houseBox(float3(c - 0.65f, U + 6.3f, 2.35f),
            float3(c + 0.65f, U + 6.55f, 3.65f), houseStone));
    }
}

// Two candles at their real size on a narrow inner sill under window k of
// a ground floor wall, placed where houseWindow draws that window. `inner`
// is the wall's room face and roomSide the direction into the room. The
// taller flame also lights the room.
void addSillCandles(device HouseModel &house, HousePart wall, uint index,
    float k, bool zFace, float inner, float roomSide) {
    float lo = zFace ? wall.lower.x : wall.lower.z;
    float hi = zFace ? wall.upper.x : wall.upper.z;
    float count = zFace ? wall.windows.x : wall.windows.y;
    float cell = (hi - lo) / count;
    float4 shift = houseWindowShift(houseWindowSeed(index, k, 0.0f, zFace),
        cell, wall.windows.z);
    float centre = lo + (k + 0.5f) * cell + shift.x;
    float halfWidth = 0.5f * wall.windows.z * shift.z + 0.06f;
    float sill = wall.lower.y + wall.rows.x + shift.y;
    float2 depth = roomSide > 0.0f ? float2(inner, inner + 0.09f)
        : float2(inner - 0.09f, inner);
    addHousePart(house, zFace
        ? houseBox(float3(centre - halfWidth, sill - 0.025f, depth.x),
            float3(centre + halfWidth, sill, depth.y), houseTrim)
        : houseBox(float3(depth.x, sill - 0.025f, centre - halfWidth),
            float3(depth.y, sill, centre + halfWidth), houseTrim));
    for (uint i = 0u; i < 2u; ++i) {
        float along = centre + (i == 0u ? -0.4f : 0.3f) * halfWidth;
        float into = inner + roomSide * 0.045f;
        float3 anchor = zFace ? float3(along, sill, into)
            : float3(into, sill, along);
        float tall = i == 0u ? 0.34f : 0.24f;  // metres, with the flame
        addHouseProp(house, houseBox(anchor - float3(0.025f, 0.0f, 0.025f),
            anchor + float3(0.025f, tall, 0.025f), houseCandle), anchor);
        uint c = house.counts.z;
        if (i == 0u && c < houseCandleCapacity) {
            float3 flame = houseWorld(anchor) + float3(0.0f, tall - 0.04f, 0.0f);
            house.candles[c] = float4(flame, float(houseRoom(flame)));
            house.counts.z = c + 1u;
        }
    }
}

// The ground floor walls, the partitions either side of the hall and the
// furniture in the three rooms.
void buildHouseRooms(device HouseModel &house) {
    const float F = houseFloorY, C = houseCeilingY;
    beginHouseGroup(house);
    HousePart fronts[2], walls[2];
    uint frontIndex[2], wallIndex[2];
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        // The front wall either side of the double doorway.
        HousePart front = houseBox(
            float3(side == 0u ? -8.0f : houseDoorHalfWidth, F, -6.0f),
            float3(side == 0u ? -houseDoorHalfWidth : 8.0f, C, -5.7f),
            houseSiding);
        houseWindows(front, float2(2.0f, 0.0f), float2(1.1f, 2.2f), 0.85f,
            1.0f, 0.0f, -1.0f);
        frontIndex[side] = house.counts.x;
        fronts[side] = front;
        addHousePart(house, front);
        HousePart wall = houseBox(
            float3(side == 0u ? -8.0f : 7.7f, F, -5.7f),
            float3(side == 0u ? -7.7f : 8.0f, C, 5.7f), houseSiding);
        houseWindows(wall, float2(0.0f, 2.0f), float2(1.1f, 2.2f), 0.85f,
            1.0f, 0.0f, -1.0f);
        wallIndex[side] = house.counts.x;
        walls[side] = wall;
        addHousePart(house, wall);
        // Each partition has a doorway toward the front of the house.
        float a = s * housePartitionX, b = s * (housePartitionX + 0.15f);
        float x0 = min(a, b), x1 = max(a, b);
        addHousePart(house, houseBox(float3(x0, F, -5.7f),
            float3(x1, C, houseInnerDoorZ.x), houseSiding));
        addHousePart(house, houseBox(float3(x0, F, houseInnerDoorZ.y),
            float3(x1, C, 5.7f), houseSiding));
        addHousePart(house, houseBox(
            float3(x0, F + houseInnerDoorHeight, houseInnerDoorZ.x),
            float3(x1, C, houseInnerDoorZ.y), houseSiding));
        // The front doors stand open against the hall walls.
        addHousePart(house, houseBox(
            float3(side == 0u ? -0.9f : 0.84f, F, -5.7f),
            float3(side == 0u ? -0.84f : 0.9f, F + houseDoorHeight, -4.8f),
            houseTrim));
        // Closed stringers flank the hall stairs, their tops following the
        // handrail.
        HousePart stringer = houseBox(
            float3(side == 0u ? -1.12f : 1.0f, F, 1.45f),
            float3(side == 0u ? -1.0f : 1.12f, F + 1.75f, 5.7f),
            houseFurniture);
        houseCut(stringer, float3(0.0f, houseStairRun, -houseStairRise),
            float3(0.0f, F + houseStairRise + 0.5f, houseStairStart));
        addHousePart(house, stringer);
    }
    addHousePart(house, houseBox(float3(-houseDoorHalfWidth,
        F + houseDoorHeight, -6.0f), float3(houseDoorHalfWidth, C, -5.7f),
        houseSiding));
    HousePart back = houseBox(float3(-8.0f, F, 5.7f), float3(8.0f, C, 6.0f),
        houseSiding);
    houseWindows(back, float2(3.0f, 0.0f), float2(1.1f, 2.2f), 0.85f, 1.0f,
        0.0f, -0.8f);
    uint backIndex = house.counts.x;
    addHousePart(house, back);
    // Loose clapboards hang on the ground floor walls; the porch roof
    // shelters the top of the front.
    float2 clad = float2(F + 0.1f, C - 0.08f) * houseScale;
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        addLooseClapboards(house, frontIndex[side], float3(0.0f, 0.0f, -1.0f),
            float2(F + 0.1f, F + 2.88f) * houseScale, houseNoSkip, 2u);
        addLooseClapboards(house, wallIndex[side], float3(s, 0.0f, 0.0f),
            clad, houseNoSkip, 3u);
    }
    addLooseClapboards(house, backIndex, float3(0.0f, 0.0f, 1.0f), clad,
        houseNoSkip, 3u);

    // Parlour: a brick fireplace under a thick log mantel, and a coffin on a
    // bier.
    addHousePart(house, houseBox(float3(-7.7f, F, -1.1f),
        float3(-7.1f, C, 1.1f), houseBrick));
    const float mantelRadius = 0.24f;
    addHouseLog(house, houseWorld(float3(-7.1f, F + 1.31f, 0.0f))
            + float3(mantelRadius + 0.01f, 0.0f, 0.0f),
        float3(0.0f, 0.0f, 1.0f), 1.3f * houseScale, mantelRadius);
    const float3 coffinAt = float3(-4.6f, F, 2.8f);
    addHouseProp(house, houseBox(float3(-4.85f, F, 2.0f),
        float3(-4.35f, F + 0.55f, 3.6f), houseFurniture), coffinAt);
    // The coffin narrows from its shoulders to the head and the foot.
    const float xc = -4.6f, foot = 1.8f, head = 3.8f, shoulder = 3.24f;
    HousePart coffin = houseBox(float3(xc - 0.35f, F + 0.55f, foot),
        float3(xc + 0.35f, F + 1.0f, head), houseFurniture);
    houseCut(coffin, float3(shoulder - foot, 0.0f, -0.13f),
        float3(xc + 0.22f, 0.0f, foot));
    houseCut(coffin, float3(foot - shoulder, 0.0f, -0.13f),
        float3(xc - 0.22f, 0.0f, foot));
    houseCut(coffin, float3(head - shoulder, 0.0f, 0.1f),
        float3(xc + 0.35f, 0.0f, shoulder));
    houseCut(coffin, float3(shoulder - head, 0.0f, 0.1f),
        float3(xc - 0.35f, 0.0f, shoulder));
    addHouseProp(house, coffin, coffinAt);

    // Dining room: a pedestal table and a tall clock against the wall.
    const float3 tableAt = float3(5.0f, F, 0.0f);
    addHouseProp(house, houseBox(float3(3.9f, F + 0.72f, -1.2f),
        float3(6.1f, F + 0.8f, 1.2f), houseFurniture), tableAt);
    addHouseProp(house, houseBox(float3(4.8f, F, -0.5f),
        float3(5.2f, F + 0.72f, 0.5f), houseFurniture), tableAt);
    addHouseProp(house, houseBox(float3(7.05f, F, 4.7f),
        float3(7.7f, F + 2.2f, 5.3f), houseFurniture), float3(7.7f, F, 5.0f));

    // The hall stairs climb toward a landing under the back window.
    for (uint k = 1u; k <= houseStairCount; ++k)
        addHousePart(house, houseBox(float3(-1.0f, F,
            houseStairStart + houseStairRun * float(k - 1u)),
            float3(1.0f, F + houseStairRise * float(k), 5.7f),
            houseFurniture));
    // Lanterns hang on rods over the hall and the dining table; the lamps
    // houseIndoorLight places light the rooms from inside them.
    for (uint i = 0u; i < 2u; ++i) {
        float2 at = i == 0u ? float2(0.0f, -2.0f) : float2(5.0f, 0.0f);
        addHousePart(house, houseBox(float3(at.x - 0.015f, C - 0.6f,
            at.y - 0.015f), float3(at.x + 0.015f, C, at.y + 0.015f),
            houseTrim));
        addHousePart(house, houseBox(float3(at.x - 0.16f, C - 1.02f,
            at.y - 0.16f), float3(at.x + 0.16f, C - 0.6f, at.y + 0.16f),
            houseLantern));
    }
    // Candles burn on the sills of the front windows beside the door and of
    // a window in each side room.
    addSillCandles(house, fronts[0], frontIndex[0], 1.0f, true, -5.7f, 1.0f);
    addSillCandles(house, fronts[1], frontIndex[1], 0.0f, true, -5.7f, 1.0f);
    addSillCandles(house, walls[0], wallIndex[0], 1.0f, false, -7.7f, 1.0f);
    addSillCandles(house, walls[1], wallIndex[1], 0.0f, false, 7.7f, -1.0f);
}

// Foundation, porch deck and steps, posts, arches, railings and roof.
void buildHousePorch(device HouseModel &house) {
    const float F = houseFloorY;
    beginHouseGroup(house);
    addHousePart(house, houseBox(float3(-8.15f, -1.0f, -6.15f),
        float3(8.15f, F, 6.15f), houseStone));
    addHousePart(house, houseBox(float3(-8.6f, -1.0f, housePorchFront),
        float3(8.6f, F, -6.15f), houseStone));
    for (uint k = 1u; k <= houseStepCount; ++k)
        addHousePart(house, houseBox(float3(-houseStepHalfWidth, -1.0f,
                housePorchFront - houseStepRun * float(k)),
            float3(houseStepHalfWidth, F - 0.125f * float(k),
                housePorchFront - houseStepRun * float(k - 1u)),
            houseStone));
    for (uint i = 0u; i < 6u; ++i) {
        float x = (i < 3u ? -1.0f : 1.0f) * housePostX[i % 3u];
        addHousePart(house, houseBox(float3(x - 0.12f, F, housePostZ - 0.12f),
            float3(x + 0.12f, F + 3.0f, housePostZ + 0.12f), houseTrim));
    }
    addHousePart(house, houseBox(float3(-8.8f, F + 3.0f, -9.85f),
        float3(8.8f, F + 3.22f, -6.0f), houseTrim));
    HousePart roof = houseBox(float3(-8.8f, F + 3.22f, -9.85f),
        float3(8.8f, F + 3.75f, -6.0f), houseRoof);
    houseCut(roof, float3(0.0f, 3.85f, -0.51f),
        float3(0.0f, F + 3.24f, -9.85f));
    addHousePart(house, roof);
    // Arches between the posts, and turned balusters below them.
    addHousePart(house, houseBox(float3(-8.35f, F + 2.3f, housePostZ - 0.05f),
        float3(8.35f, F + 3.0f, housePostZ + 0.05f), houseFrieze));
    for (uint side = 0u; side < 2u; ++side) {
        float x0 = side == 0u ? -8.4f : 8.3f, x1 = x0 + 0.1f;
        addHousePart(house, houseBox(float3(x0, F + 2.3f, housePostZ),
            float3(x1, F + 3.0f, -6.0f), houseFrieze));
        addHousePart(house, houseBox(float3(x0, F, housePostZ),
            float3(x1, F + 0.92f, -6.15f), houseRailing));
        addHousePart(house, houseBox(
            float3(side == 0u ? -8.35f : housePostX[0], F, housePostZ - 0.05f),
            float3(side == 0u ? -housePostX[0] : 8.35f, F + 0.92f,
                housePostZ + 0.05f),
            houseRailing));
    }
    // A lantern hangs over the steps on a short rod.
    addHousePart(house, houseBox(float3(-0.015f, F + 2.78f, -8.215f),
        float3(0.015f, F + 3.0f, -8.185f), houseTrim));
    addHousePart(house, houseBox(float3(-0.15f, F + 2.35f, -8.35f),
        float3(0.15f, F + 2.78f, -8.05f), houseLantern));
}

// The iron fence round the lot, and stone gate posts carrying lanterns.
void buildHouseFence(device HouseModel &house) {
    beginHouseGroup(house);
    const float top = 1.0f, base = -0.05f;
    float gap = houseGatePostX + 0.25f;
    addHousePart(house, houseBox(float3(houseLotLower.x, base,
        houseLotLower.y - 0.03f), float3(-gap, top, houseLotLower.y + 0.03f),
        houseIron));
    addHousePart(house, houseBox(float3(gap, base, houseLotLower.y - 0.03f),
        float3(houseLotUpper.x, top, houseLotLower.y + 0.03f), houseIron));
    addHousePart(house, houseBox(float3(houseLotLower.x - 0.03f, base,
        houseLotLower.y), float3(houseLotLower.x + 0.03f, top,
        houseLotUpper.y), houseIron));
    addHousePart(house, houseBox(float3(houseLotUpper.x - 0.03f, base,
        houseLotLower.y), float3(houseLotUpper.x + 0.03f, top,
        houseLotUpper.y), houseIron));
    addHousePart(house, houseBox(float3(houseLotLower.x, base,
        houseLotUpper.y - 0.03f), float3(houseLotUpper.x, top,
        houseLotUpper.y + 0.03f), houseIron));
    for (uint side = 0u; side < 2u; ++side) {
        float c = (side == 0u ? -1.0f : 1.0f) * houseGatePostX;
        float z = houseLotLower.y;
        addHousePart(house, houseBox(float3(c - 0.25f, base, z - 0.25f),
            float3(c + 0.25f, 2.0f, z + 0.25f), houseStone));
        addHousePart(house, houseBox(float3(c - 0.32f, 2.0f, z - 0.32f),
            float3(c + 0.32f, 2.14f, z + 0.32f), houseStone));
        addHousePart(house, houseBox(float3(c - 0.13f, 2.14f, z - 0.13f),
            float3(c + 0.13f, 2.56f, z + 0.13f), houseLantern));
    }
}

// --------------------------------------------------------------- graveyard
// Crosses, headstones and a tomb stand in the lot around the house at their
// real size. Each marker's foot is in house-local x and z on the levelled
// ground; its face looks along -z, +x, +z or -x. Headstones lean back or
// forward (round tops) or to one side (pointed tops), crosses to one side,
// and a fallen cross lies turned on the ground.
constant uint houseGraveCross = 0u;
constant uint houseGraveRound = 1u;
constant uint houseGravePointed = 2u;
constant uint houseGraveFallen = 3u;
constant uint houseGraveTomb = 4u;

struct HouseGrave {
    float2 at;      // house-local x and z of the foot
    uint facing;    // 0 −z, 1 +x, 2 +z, 3 −x
    uint kind;
    float lean;     // radians; the fallen cross's turn on the ground
};

constant uint houseGraveCount = 19u;
constant HouseGrave houseGraves[houseGraveCount] = {
    // West of the path, in front of the porch, and down the west side.
    {float2(-4.6f, -14.2f), 0u, houseGraveRound, 0.1f},
    {float2(-6.4f, -13.4f), 0u, houseGraveCross, 0.16f},
    {float2(-8.3f, -14.6f), 0u, houseGravePointed, -0.09f},
    {float2(-3.7f, -12.0f), 0u, houseGraveCross, -0.07f},
    {float2(-6.9f, -11.4f), 0u, houseGraveRound, -0.12f},
    {float2(-10.4f, -12.6f), 0u, houseGraveFallen, 0.6f},
    {float2(-11.9f, -15.0f), 0u, houseGraveCross, 0.27f},
    {float2(-12.6f, -10.0f), 0u, houseGravePointed, 0.16f},
    {float2(-11.2f, -5.2f), 1u, houseGraveCross, -0.12f},
    {float2(-12.9f, -1.6f), 1u, houseGraveRound, 0.14f},
    {float2(-11.0f, 2.0f), 1u, houseGraveCross, 0.21f},
    {float2(-13.2f, 5.4f), 1u, houseGravePointed, -0.2f},
    // East of the path: the tomb, and a row down the east side.
    {float2(5.6f, -14.8f), 0u, houseGraveRound, 0.06f},
    {float2(7.6f, -13.6f), 0u, houseGraveCross, 0.12f},
    {float2(11.6f, -13.0f), 0u, houseGraveTomb, 0.0f},
    {float2(12.6f, -6.4f), 3u, houseGravePointed, 0.1f},
    {float2(11.0f, -2.6f), 3u, houseGraveCross, -0.15f},
    {float2(13.0f, 1.2f), 3u, houseGraveRound, 0.18f},
    {float2(11.4f, 4.6f), 3u, houseGraveCross, 0.34f},
};

float3 houseGraveFace(uint facing) {
    return facing == 0u ? float3(0.0f, 0.0f, -1.0f)
        : (facing == 1u ? float3(1.0f, 0.0f, 0.0f)
            : (facing == 2u ? float3(0.0f, 0.0f, 1.0f)
                : float3(-1.0f, 0.0f, 0.0f)));
}

// A headstone set 0.2 m into the ground. A round-topped stone leans back
// (or forward) about the line of its foot and has its top corners dressed
// off; a pointed stone leans to one side. Its front face carries the
// engraving: windows holds the front normal and the sideways lean, rows the
// foot and the height.
void addHeadstone(device HouseModel &house, float3 foot, float3 face,
    float width, float height, float lean, bool pointed) {
    const float3 up = float3(0.0f, 1.0f, 0.0f);
    const float thickness = 0.15f;
    float3 side = cross(up, face);
    float3 rise = up, front = face, across = side;
    if (pointed) {
        rise = up * cos(lean) + side * sin(lean);
        across = side * cos(lean) - up * sin(lean);
    } else {
        rise = up * cos(lean) - face * sin(lean);
        front = face * cos(lean) + up * sin(lean);
    }
    float3 lower = float3(1.0e9f), upper = float3(-1.0e9f);
    for (uint k = 0u; k < 8u; ++k) {
        float3 corner = foot
            + across * ((k & 1u) != 0u ? 0.5f : -0.5f) * width
            + rise * ((k & 2u) != 0u ? height : 0.0f)
            + front * ((k & 4u) != 0u ? 0.5f : -0.5f) * thickness;
        lower = min(lower, corner);
        upper = max(upper, corner);
    }
    HousePart part = houseBox(lower, upper, houseGrave);
    float3 top = foot + rise * height;
    if (pointed) {
        const float gable = 0.16f;
        houseCut(part, across, foot + across * 0.5f * width);
        houseCut(part, -across, foot - across * 0.5f * width);
        houseCut(part, rise * 0.5f * width + across * gable, top);
        houseCut(part, rise * 0.5f * width - across * gable, top);
    } else {
        float dressed = 0.3f * width;
        houseCut(part, front, foot + front * 0.5f * thickness);
        houseCut(part, -front, foot - front * 0.5f * thickness);
        houseCut(part, rise + across, top + across * (0.5f * width - dressed));
        houseCut(part, rise - across, top - across * (0.5f * width - dressed));
    }
    part.windows = float4(front, pointed ? lean : 0.0f);
    part.rows = float4(foot, height);
    addHouseWorldPart(house, part);
}

// A wooden cross from two boards: a post set 0.3 m into the ground and a
// crossbar nailed across its face, leaning to one side.
void addGraveCross(device HouseModel &house, float3 foot, float3 face,
    float height, float lean) {
    const float3 up = float3(0.0f, 1.0f, 0.0f);
    float3 side = cross(up, face);
    float3 rise = up * cos(lean) + side * sin(lean);
    float3 across = side * cos(lean) - up * sin(lean);
    float post = height + 0.3f;
    addHouseBoard(house, foot + rise * (0.5f * post), rise, face,
        float3(post, 0.1f, 0.06f), houseNoNails);
    addHouseBoard(house, foot + rise * (post - 0.42f) + face * 0.052f,
        across, face, float3(0.62f, 0.085f, 0.045f), houseNailAtCentre);
}

// A cross that has fallen and lies on the ground, its crossbar knocked
// askew.
void addFallenCross(device HouseModel &house, float3 ground, float turn) {
    const float3 up = float3(0.0f, 1.0f, 0.0f);
    float3 along = float3(sin(turn), 0.0f, cos(turn));
    addHouseBoard(house, ground + up * 0.03f, along, up,
        float3(1.7f, 0.1f, 0.06f), houseNailsAtEnds);
    float askew = turn + 0.5f * rangePi + 0.22f;
    addHouseBoard(house, ground + along * 0.42f + up * 0.083f,
        float3(sin(askew), 0.0f, cos(askew)), up,
        float3(0.62f, 0.085f, 0.045f), houseNailAtCentre);
}

// A small stone mausoleum facing −z on a plinth, under a gabled stone roof
// with a cross on its ridge. An iron gate closes its doorway over a dark
// recess; windows.w marks the recess so it can glow. Parts in metres around
// its foot.
void addHouseTomb(device HouseModel &house, float3 g) {
    addHouseWorldPart(house, houseBox(g + float3(-1.7f, -0.2f, -2.2f),
        g + float3(1.7f, 0.35f, 2.2f), houseGrave));
    addHouseWorldPart(house, houseBox(g + float3(-0.85f, -0.2f, -2.55f),
        g + float3(0.85f, 0.18f, -2.2f), houseGrave));
    addHouseWorldPart(house, houseBox(g + float3(-1.4f, 0.35f, -1.8f),
        g + float3(1.4f, 2.75f, 1.8f), houseGrave));
    HousePart recess = houseBox(g + float3(-0.55f, 0.35f, -1.803f),
        g + float3(0.55f, 2.3f, -1.8f), houseGrave);
    recess.windows.w = -1.0f;
    addHouseWorldPart(house, recess);
    addHouseWorldPart(house, houseBox(g + float3(-0.55f, 0.35f, -1.86f),
        g + float3(0.55f, 2.3f, -1.83f), houseIron));
    for (uint side = 0u; side < 2u; ++side) {
        float x = side == 0u ? -1.05f : 1.05f;
        addHouseWorldPart(house, houseBox(g + float3(x - 0.17f, 0.35f, -2.05f),
            g + float3(x + 0.17f, 2.75f, -1.75f), houseGrave));
    }
    addHouseWorldPart(house, houseBox(g + float3(-1.6f, 2.75f, -2.1f),
        g + float3(1.6f, 3.0f, 2.0f), houseGrave));
    addHouseWorldPart(house, houseGable(g + float3(-1.65f, 3.0f, -2.15f),
        g + float3(1.65f, 3.95f, 2.05f), true, houseGrave));
    addHouseWorldPart(house, houseBox(g + float3(-0.06f, 3.7f, -2.1f),
        g + float3(0.06f, 4.55f, -1.98f), houseGrave));
    addHouseWorldPart(house, houseBox(g + float3(-0.26f, 4.16f, -2.1f),
        g + float3(0.26f, 4.28f, -1.98f), houseGrave));
}

// The graves either side of the path, as two groups.
void buildHouseGraveyard(device HouseModel &house) {
    for (uint side = 0u; side < 2u; ++side) {
        beginHouseGroup(house);
        for (uint i = 0u; i < houseGraveCount; ++i) {
            HouseGrave grave = houseGraves[i];
            if ((grave.at.x < 0.0f) != (side == 0u)) continue;
            float3 ground = houseWorld(float3(grave.at.x, 0.0f, grave.at.y));
            float3 face = houseGraveFace(grave.facing);
            float pick = houseHash(float(i) * 3.7f + 11.0f);
            float3 buried = ground - float3(0.0f, 0.2f, 0.0f);
            if (grave.kind == houseGraveCross)
                addGraveCross(house, ground - float3(0.0f, 0.3f, 0.0f), face,
                    1.25f + 0.35f * pick, grave.lean);
            else if (grave.kind == houseGraveFallen)
                addFallenCross(house, ground, grave.lean);
            else if (grave.kind == houseGraveTomb)
                addHouseTomb(house, ground);
            else
                addHeadstone(house, buried, face, 0.58f + 0.2f * pick,
                    0.95f + 0.3f * houseHash(float(i) + 5.0f), grave.lean,
                    grave.kind == houseGravePointed);
        }
    }
}

void buildHouse(device HouseModel &house) {
    house.counts = uint4(0u);
    buildHouseBody(house);
    buildHouseRooms(house);
    buildHousePorch(house);
    buildHouseFence(house);
    buildHouseGraveyard(house);
}

// ----------------------------------------------------------------- tracing

bool houseRayEntersBox(float3 origin, float3 direction, float3 lower,
    float3 upper, float limit) {
    float3 safe = select(direction, float3(1.0e-6f),
        abs(direction) < float3(1.0e-6f));
    float3 a = (lower - origin) / safe, b = (upper - origin) / safe;
    float3 entry = min(a, b), exit = max(a, b);
    float near = max(max(entry.x, entry.y), entry.z);
    float far = min(min(exit.x, exit.y), min(exit.z, limit));
    return far >= max(near, 0.0f);
}

// Entry distance of a ray into a part, or -1. A ray that starts inside a
// part misses it, so a shadow ray leaving a surface ignores its own part.
float housePartHit(device const HousePart &part, float3 origin,
    float3 direction, float limit, thread float3 &normal) {
    float3 safe = select(direction, float3(1.0e-6f),
        abs(direction) < float3(1.0e-6f));
    float3 a = (part.lower.xyz - origin) / safe;
    float3 b = (part.upper.xyz - origin) / safe;
    float3 entry3 = min(a, b), exit3 = max(a, b);
    float entry = entry3.x;
    normal = float3(-sign(safe.x), 0.0f, 0.0f);
    if (entry3.y > entry) {
        entry = entry3.y;
        normal = float3(0.0f, -sign(safe.y), 0.0f);
    }
    if (entry3.z > entry) {
        entry = entry3.z;
        normal = float3(0.0f, 0.0f, -sign(safe.z));
    }
    float exit = min(min(exit3.x, exit3.y), min(exit3.z, limit));
    uint planes = min(uint(part.upper.w), 4u);
    for (uint k = 0u; k < planes; ++k) {
        float4 plane = part.planes[k];
        float facing = dot(plane.xyz, direction);
        float gap = plane.w - dot(plane.xyz, origin);
        if (abs(facing) < 1.0e-6f) {
            if (gap < 0.0f) return -1.0f;
            continue;
        }
        float t = gap / facing;
        if (facing < 0.0f) {
            if (t > entry) {
                entry = t;
                normal = plane.xyz;
            }
        } else {
            exit = min(exit, t);
        }
    }
    return entry > 1.0e-4f && entry < exit ? entry : -1.0f;
}

// The bay between porch posts that holds local x, as centre and half span.
float2 housePorchBay(float x) {
    float side = x < 0.0f ? -1.0f : 1.0f;
    float ax = abs(x);
    if (ax < housePostX[0]) return float2(0.0f, housePostX[0]);
    if (ax < housePostX[1])
        return float2(side * 0.5f * (housePostX[0] + housePostX[1]),
            0.5f * (housePostX[1] - housePostX[0]));
    return float2(side * 0.5f * (housePostX[1] + housePostX[2]),
        0.5f * (housePostX[2] - housePostX[1]));
}

// True where a ray passes through a cut-out panel's openings. Patterns are
// measured in house-local units.
bool houseCutoutOpen(uint style, device const HousePart &part, float3 p) {
    if (style == houseCandle) {
        // A round wax stick under a teardrop flame, in metres. The hit lies
        // on a face of the box, so its offset along that face, the smaller
        // of the two, measures the silhouette.
        float3 size = part.upper.xyz - part.lower.xyz;
        float2 offset = abs(p.xz - 0.5f * (part.lower.xz + part.upper.xz));
        float radius = min(offset.x, offset.y);
        float h = p.y - part.lower.y, waxTop = size.y - 0.075f;
        if (h < waxTop) return radius > 0.021f;
        float t = saturate((h - waxTop) / 0.075f);
        return radius > 0.013f * pow(sin(rangePi * (0.15f + 0.85f * t)), 0.8f)
            * (1.0f - 0.35f * t);
    }
    float3 size = (part.upper.xyz - part.lower.xyz) / houseScale;
    bool alongX = size.x >= size.z;
    float along = (alongX ? p.x - part.lower.x : p.z - part.lower.z)
        / houseScale;
    float h = (p.y - part.lower.y) / houseScale;
    if (style == houseIron) {
        // Spear-topped bars between two rails, a heavier post every 2.4
        // units, and bars bent out of line here and there.
        float cellIndex = floor(along / 0.15f);
        float bend = 0.02f * (houseHash(cellIndex) - 0.5f) * h;
        float bar = abs(fract((along + bend) / 0.15f) - 0.5f) * 0.15f;
        float post = abs(fract(along / 2.4f) - 0.5f) * 2.4f;
        if (post < 0.03f && h < size.y - 0.03f) return false;
        if ((h > 0.12f && h < 0.15f) || (h > 0.78f && h < 0.81f)) return false;
        float tip = size.y - 0.12f - 0.03f * houseHash(cellIndex + 7.0f);
        if (h < tip) return bar > 0.011f;
        return bar > 0.03f * (size.y - h) / (size.y - tip);
    }
    if (style == houseCresting) {
        // Spikes every 22 cm over a rail, with a ring between each pair.
        if (h < 0.05f || (h > 0.22f && h < 0.245f)) return false;
        float cell = fract(along / 0.22f) - 0.5f;
        float bar = abs(cell) * 0.22f;
        if (h < size.y - 0.12f && bar < 0.009f) return false;
        if (h >= size.y - 0.12f)
            return bar > 0.026f * (size.y - h) / 0.12f;
        float ring = length(float2((abs(cell) - 0.5f) * 0.22f, h - 0.135f));
        return abs(ring - 0.055f) > 0.009f;
    }
    if (style == houseRailing) {
        if (h > size.y - 0.09f || (h > 0.05f && h < 0.12f)) return false;
        if (h <= 0.05f) return true;
        // Turned balusters: a vase profile every 13 cm.
        float cell = abs(fract(along / 0.13f) - 0.5f) * 0.13f;
        float t = saturate((h - 0.12f) / (size.y - 0.21f));
        float width = 0.014f + 0.01f * sin(t * rangePi)
            + 0.006f * exp(-(t - 0.25f) * (t - 0.25f) * 140.0f);
        return cell > width;
    }
    if (style == houseFrieze) {
        // Elliptical arches span each bay between posts, with a round
        // piercing in each spandrel. The old frame has sagged: every arch
        // has its own height, leans to one side, and its piercings sit
        // unevenly.
        float3 local = houseLocal(p);
        float x = alongX ? local.x : local.z;
        float2 bay = alongX ? housePorchBay(x)
            : float2(0.5f * (housePostZ - 6.0f), 0.5f * (6.0f + housePostZ));
        float seed = floor(bay.x * 3.0f + 0.5f) + (alongX ? 0.0f : 40.0f);
        float u = (x - bay.x) / max(abs(bay.y), 0.001f);
        float top = 0.47f * (0.86f + 0.24f * houseHash(seed));
        float lean = 0.3f * (houseHash(seed + 1.0f) - 0.5f);
        float arch = top * sqrt(max(1.0f - u * u, 0.0f)) * (1.0f + lean * u);
        if (abs(u) < 0.94f && h < arch) return true;
        float drift = 0.04f * (houseHash(seed + sign(u)) - 0.5f);
        float2 hole = float2((abs(u) - 0.86f) * abs(bay.y) + drift,
            h - 0.55f - drift);
        return length(hole) < 0.055f + 0.015f * houseHash(seed + 3.0f);
    }
    return false;
}

// Entry distance into any part: logs are round, everything else is a cut
// box.
float houseHitPart(device const HousePart &part, float3 origin,
    float3 direction, float limit, thread float3 &normal) {
    return uint(part.lower.w) == houseLog
        ? houseLogHit(part, origin, direction, limit, normal)
        : housePartHit(part, origin, direction, limit, normal);
}

// Adds the house's nearest surface along the ray to hit.
void traceHouse(thread SceneHit &hit, float3 origin, float3 direction,
    device const GameState &game) {
    device const HouseModel &house = game.house;
    uint groups = min(house.counts.y, houseGroupCapacity);
    HouseWind wind = houseWind(game);
    bool found = false;
    for (uint g = 0u; g < groups; ++g) {
        HouseGroup group = house.groups[g];
        if (!houseRayEntersBox(origin, direction, group.lower.xyz,
                group.upper.xyz, hit.distance)) continue;
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            float3 normal;
            float t = houseHitPart(house.parts[i], origin, direction,
                hit.distance, normal);
            if (t < 0.0f) continue;
            float3 p = origin + direction * t;
            uint style = uint(house.parts[i].lower.w);
            if (((style >= houseIron && style <= houseFrieze)
                    || style == houseCandle)
                && houseCutoutOpen(style, house.parts[i], p)) continue;
            // Rays pass through the clear glass of the ground floor.
            if (style == houseSiding && houseSeeThrough(house.parts[i])
                && houseWindow(house.parts[i], i, p, normal, 0.002f,
                    wind).glass
                    > 0.5f) continue;
            hit = {t, normal, p, houseMaterialBase + style, -1, i};
            found = true;
        }
    }
    // The nearest wall face becomes the board under it.
    if (found && (hit.material == houseMaterialBase + houseSiding
            || hit.material == houseMaterialBase + houseBattens))
        houseCladdingRelief(hit, direction, game);
}

// True when a solid part lies between origin and the light. Cut-out panels
// and lanterns cast no shadow.
bool houseBlocksLight(float3 origin, float3 direction, float lightDistance,
    device const GameState &game) {
    device const HouseModel &house = game.house;
    uint groups = min(house.counts.y, houseGroupCapacity);
    for (uint g = 0u; g < groups; ++g) {
        HouseGroup group = house.groups[g];
        if (!houseRayEntersBox(origin, direction, group.lower.xyz,
                group.upper.xyz, lightDistance)) continue;
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            uint style = uint(house.parts[i].lower.w);
            if ((style >= houseIron && style <= houseFrieze)
                || style == houseLantern || style == houseCandle) continue;
            float3 normal;
            if (houseHitPart(house.parts[i], origin, direction,
                    lightDistance, normal) > 0.0f) return true;
        }
    }
    return false;
}

// The nearest ground floor pane the ray crosses before limit: its
// distance, or -1. normal and pane describe it.
float houseGlassCrossing(float3 origin, float3 direction, float limit,
    device const GameState &game, thread float3 &normal,
    thread HouseWindow &pane) {
    device const HouseModel &house = game.house;
    float nearest = -1.0f;
    uint groups = min(house.counts.y, houseGroupCapacity);
    HouseWind wind = houseWind(game);
    for (uint g = 0u; g < groups; ++g) {
        HouseGroup group = house.groups[g];
        if (!houseRayEntersBox(origin, direction, group.lower.xyz,
                group.upper.xyz, limit)) continue;
        uint end = min(uint(group.upper.w), houseCapacity);
        for (uint i = uint(group.lower.w); i < end; ++i) {
            if (uint(house.parts[i].lower.w) != houseSiding
                || !houseSeeThrough(house.parts[i])) continue;
            float3 faceNormal;
            float t = housePartHit(house.parts[i], origin, direction, limit,
                faceNormal);
            if (t < 0.0f) continue;
            HouseWindow w = houseWindow(house.parts[i], i,
                origin + direction * t, faceNormal, 0.002f, wind);
            if (w.glass <= 0.5f) continue;
            nearest = t;
            limit = t;
            normal = faceNormal;
            pane = w;
        }
    }
    return nearest;
}

// Old glass over what lies beyond it: a green tint, grime that catches the
// light, a crack across some panes, and a faint reflection of the room or
// the night, stronger at grazing angles.
float3 houseThroughGlass(float3 color, HouseWindow pane, float3 normal,
    float3 direction, float3 p, bool fromInside) {
    float facing = abs(dot(direction, normal));
    float fresnel = 0.04f + 0.96f * pow(1.0f - facing, 5.0f);
    float grime = smoothstep(0.4f, 0.9f, smoothNoise(float2(p.x + p.z, p.y)
        * 3.5f)) * (0.4f + 0.6f * pane.uv.y);
    float3 lit = fromInside ? float3(0.07f, 0.045f, 0.025f)
        : earthColor * 0.012f;
    float3 through = color * float3(0.86f, 0.92f, 0.84f) * (1.0f - 0.4f * grime);
    float3 result = mix(through, lit, fresnel) + lit * 0.5f * grime;
    if (houseHash(pane.seed + 13.0f) > 0.7f) {
        float2 q = (pane.uv - float2(0.3f * (houseHash(pane.seed + 14.0f)
            - 0.5f), 0.45f)) * float2(pane.room.z, pane.room.w);
        float angle = atan2(q.y, q.x) / (2.0f * rangePi);
        float spoke = abs(fract(angle * 7.0f + 0.3f
            * smoothNoise(q * 9.0f)) - 0.5f);
        float crack = (1.0f - smoothstep(0.0f, 0.03f, spoke))
            * (1.0f - smoothstep(0.1f, 0.45f, length(q)));
        result += (fromInside ? float3(0.25f, 0.17f, 0.1f)
            : float3(0.12f, 0.14f, 0.18f)) * crack;
    }
    return result;
}

// --------------------------------------------------------------- footing

// Weight of the natural terrain: 0 on the lot and one unit beyond its
// fence, rising to 1 another 18 m out.
float houseLotBlend(float2 p) {
    float2 local = houseLocal(p);
    float2 outside = max(max(houseLotLower - 1.0f - local,
        local - houseLotUpper - 1.0f), float2(0.0f));
    return smoothstep(0.0f, 18.0f, length(outside) * houseScale);
}

// The floor, porch, steps and hall stairs under p, or ground elsewhere.
float houseStand(float2 p, float ground) {
    float2 local = houseLocal(p);
    float stepsFront = housePorchFront - houseStepRun * float(houseStepCount);
    if (abs(local.x) > 8.6f || local.y < stepsFront || local.y > 6.15f)
        return ground;
    float floorY = houseOrigin.y + houseFloorY * houseScale;
    if (local.y < housePorchFront) {
        if (abs(local.x) > houseStepHalfWidth) return ground;
        float k = ceil((housePorchFront - local.y) / houseStepRun);
        return max(ground, floorY - 0.125f * houseScale * k);
    }
    if (local.y >= -6.15f && abs(local.x) > 8.15f) return ground;
    if (abs(local.x) < 1.0f && local.y >= houseStairStart) {
        float k = min(floor((local.y - houseStairStart) / houseStairRun) + 1.0f,
            float(houseStairCount));
        return floorY + houseStairRise * houseScale * k;
    }
    return floorY;
}

// Footprints the walker cannot enter, in house-local x/z: walls,
// partitions, door leaves, furniture, stair sides, porch posts and
// railings out to the deck edge, the sides of the steps, the gate posts, the
// fence and the graves. Each matches a part buildHouse makes. The graves'
// footprints are listed here rather than read from houseGraves: a second
// loop in this test, which the spider kernels inline, made them take a
// minute to compile cold.
constant uint houseObstacleCount = 54u;
constant float4 houseObstacles[houseObstacleCount] = {
    float4(-8.0f, -6.0f, -0.9f, -5.7f), float4(0.9f, -6.0f, 8.0f, -5.7f),
    float4(-8.0f, 5.7f, 8.0f, 6.0f), float4(-8.0f, -6.0f, -7.7f, 6.0f),
    float4(7.7f, -6.0f, 8.0f, 6.0f),
    float4(-2.35f, -5.7f, -2.2f, -2.8f), float4(-2.35f, -0.8f, -2.2f, 5.7f),
    float4(2.2f, -5.7f, 2.35f, -2.8f), float4(2.2f, -0.8f, 2.35f, 5.7f),
    float4(-0.9f, -5.7f, -0.84f, -4.8f), float4(0.84f, -5.7f, 0.9f, -4.8f),
    float4(-7.7f, -1.25f, -6.95f, 1.25f), float4(-4.775f, 2.3f, -4.425f, 3.3f),
    float4(4.45f, -0.6f, 5.55f, 0.6f), float4(7.375f, 4.85f, 7.7f, 5.15f),
    float4(-1.12f, 1.45f, -1.0f, 5.7f), float4(1.0f, 1.45f, 1.12f, 5.7f),
    float4(-8.47f, -9.47f, -8.23f, -9.23f), float4(-5.17f, -9.47f, -4.93f, -9.23f),
    float4(-1.87f, -9.47f, -1.63f, -9.23f), float4(1.63f, -9.47f, 1.87f, -9.23f),
    float4(4.93f, -9.47f, 5.17f, -9.23f), float4(8.23f, -9.47f, 8.47f, -9.23f),
    float4(-8.35f, -9.6f, -1.75f, -9.3f), float4(1.75f, -9.6f, 8.35f, -9.3f),
    float4(-8.6f, -9.6f, -8.3f, -6.15f), float4(8.3f, -9.6f, 8.6f, -6.15f),
    float4(-1.55f, -11.1f, -1.5f, -9.6f), float4(1.5f, -11.1f, 1.55f, -9.6f),
    float4(-2.25f, -17.25f, -1.75f, -16.75f),
    float4(1.75f, -17.25f, 2.25f, -16.75f),
    float4(-15.0f, -17.03f, -2.25f, -16.97f),
    float4(2.25f, -17.03f, 15.0f, -16.97f),
    float4(-15.03f, -17.0f, -14.97f, 9.0f), float4(14.97f, -17.0f, 15.03f, 9.0f),
    float4(-15.0f, 8.97f, 15.0f, 9.03f),
    // The standing graves of houseGraves in order, and the tomb's plinth
    // and step; a fallen cross can be stepped over.
    float4(-4.81f, -14.31f, -4.39f, -14.09f),
    float4(-6.525f, -13.46f, -6.275f, -13.34f),
    float4(-8.51f, -14.71f, -8.09f, -14.49f),
    float4(-3.825f, -12.06f, -3.575f, -11.94f),
    float4(-7.11f, -11.51f, -6.69f, -11.29f),
    float4(-12.025f, -15.06f, -11.775f, -14.94f),
    float4(-12.81f, -10.11f, -12.39f, -9.89f),
    float4(-11.26f, -5.325f, -11.14f, -5.075f),
    float4(-13.01f, -1.81f, -12.79f, -1.39f),
    float4(-11.06f, 1.875f, -10.94f, 2.125f),
    float4(-13.31f, 5.19f, -13.09f, 5.61f),
    float4(5.39f, -14.91f, 5.81f, -14.69f),
    float4(7.475f, -13.66f, 7.725f, -13.54f),
    float4(10.75f, -14.275f, 12.45f, -11.9f),
    float4(12.49f, -6.61f, 12.71f, -6.19f),
    float4(10.94f, -2.725f, 11.06f, -2.475f),
    float4(12.89f, 0.99f, 13.11f, 1.41f),
    float4(11.34f, 4.475f, 11.46f, 4.725f)
};

bool houseBlocked(float2 p) {
    float2 local = houseLocal(p);
    if (any(local < houseLotLower - 1.0f) || any(local > houseLotUpper + 1.0f))
        return false;
    float pad = housePlayerPad / houseScale;
    for (uint i = 0u; i < houseObstacleCount; ++i) {
        float4 r = houseObstacles[i];
        if (all(local > r.xy - pad) && all(local < r.zw + pad)) return true;
    }
    return false;
}

// Inside the ground floor rooms, between floor and ceiling.
bool houseInteriorPoint(float3 p) {
    float3 local = houseLocal(p);
    float margin = 0.02f / houseScale;
    return abs(local.x) < 7.7f + margin && abs(local.z) < 5.7f + margin
        && local.y > houseFloorY - margin && local.y < houseCeilingY + margin;
}

bool houseUnderRoof(float2 p) {
    float2 local = houseLocal(p);
    return abs(local.x) < 7.7f && abs(local.y) < 5.7f;
}

// 0 for the hall, 1 for the parlour, 2 for the dining room.
uint houseRoom(float3 p) {
    float x = houseLocal(p).x;
    return x < -housePartitionX - 0.075f ? 1u
        : (x > housePartitionX + 0.075f ? 2u : 0u);
}

// ------------------------------------------------------------------ lights

float houseFlicker(float time, float phase, float depth) {
    return 1.0f - depth * (0.5f + 0.3f * sin(time * 7.3f + phase)
        + 0.2f * sin(time * 17.9f + 2.7f * phase));
}

// Three lanterns light the outside: one on each gate post and one over the
// porch steps.
constant uint houseOutdoorLightCount = 3u;

PointLight houseOutdoorLight(uint index, float time) {
    float3 position = index < 2u
        ? float3(index == 0u ? -houseGatePostX : houseGatePostX, 2.35f,
            houseLotLower.y)
        : float3(0.0f, houseFloorY + 2.57f, -8.2f);
    return {houseWorld(position), float3(1.0f, 0.6f, 0.27f),
        (index < 2u ? 55.0f : 75.0f) * houseScale * houseScale
            * houseFlicker(time, float(index), 0.12f),
        false};
}

// The hall chandelier, the parlour fire and candles, the dining
// chandelier. Each lights only its own room.
constant uint houseIndoorLightCount = 4u;

// Powers grow with the square of the scale, so the larger rooms are lit as
// brightly.
PointLight houseIndoorLight(uint index, float time, thread uint &room) {
    const float F = houseFloorY, area = houseScale * houseScale;
    if (index == 0u) {
        room = 0u;
        return {houseWorld(float3(0.0f, houseCeilingY - 0.85f, -2.0f)),
            float3(1.0f, 0.72f, 0.42f), 240.0f * area * houseFlicker(time, 4.0f, 0.06f),
            false};
    }
    if (index == 1u) {
        room = 1u;
        return {houseWorld(float3(-6.55f, F + 0.6f, 0.0f)),
            float3(1.0f, 0.45f, 0.14f), 170.0f * area * houseFlicker(time, 1.3f, 0.3f),
            false};
    }
    if (index == 2u) {
        room = 1u;
        return {houseWorld(float3(-4.2f, F + 0.65f, 2.8f)),
            float3(1.0f, 0.62f, 0.3f), 25.0f * area * houseFlicker(time, 2.1f, 0.15f),
            false};
    }
    room = 2u;
    return {houseWorld(float3(5.0f, houseCeilingY - 0.9f, 0.0f)),
        float3(1.0f, 0.66f, 0.34f), 200.0f * area * houseFlicker(time, 5.5f, 0.08f),
        false};
}

// ---------------------------------------------------------------- haunting
// A shot through any window wakes the house. Its lamps, candles, lanterns
// and fire sputter and go out. In the dark a wind rises and tears the
// curtains loose behind the windows; then a poison green glow snaps on
// through the rooms and the fire, and a second later the ghost from the bay
// window bursts out of the front doors, sweeps down the porch steps and
// flies at whoever fired. It vanishes as it reaches them, or after a while,
// and the house settles: the wind dies away and the lamps come back.
constant float houseLightsOut = 0.25f;      // the lamps sputter, then die
constant float houseWindRise = 0.4f;        // the wind starts in the dark
constant float houseWindFadeIn = 1.6f;      // and reaches full strength
constant float houseGreenOn = 2.4f;         // the green glow snaps on
constant float houseGhostEmerge = 3.4f;     // seconds after the shot
constant float houseGhostLife = 11.4f;      // vanishes by then regardless
constant float houseGhostVanish = 0.45f;
constant float houseHauntSettle = 2.5f;     // wind fades, lamps recover
constant float houseGhostHeight = 1.75f;    // head centre above the floor
constant float3 houseGhostGreen = float3(0.32f, 1.0f, 0.22f);

// Seconds since the shot, or -1 while the house is quiet.
float houseHauntAge(device const GameState &game) {
    return game.house.haunt.x < 0.0f ? -1.0f
        : game.effects.x - game.house.haunt.x;
}

// 0 until the ghost begins to vanish, then rising to 1 as the house
// settles.
float houseHauntSettled(device const GameState &game) {
    float end = game.house.hauntMotion.w;
    return end < 0.0f ? 0.0f
        : smoothstep(end, end + houseHauntSettle, game.effects.x);
}

// 0 while quiet, 1 at the height of the haunting; it eases off once the
// ghost begins to vanish.
float houseHauntStrength(device const GameState &game) {
    float age = houseHauntAge(game);
    if (age < 0.0f) return 0.0f;
    return smoothstep(0.0f, 0.12f, age) * (1.0f - houseHauntSettled(game));
}

// The haunting's wind, 0 to 1: it fades in once the lamps are out and
// fades out as the house settles. The wind voice and the curtains follow
// it.
float houseHauntWind(device const GameState &game) {
    float age = houseHauntAge(game);
    if (age < 0.0f) return 0.0f;
    return smoothstep(houseWindRise, houseWindRise + houseWindFadeIn, age)
        * (1.0f - houseHauntSettled(game));
}

HouseWind houseWind(device const GameState &game) {
    return {houseHauntWind(game), game.effects.x};
}

// How solid the ghost is, 0 to 1.
float houseGhostFade(device const GameState &game) {
    float age = houseHauntAge(game);
    if (age < houseGhostEmerge) return 0.0f;
    float end = game.house.hauntMotion.w;
    float vanish = end < 0.0f ? 1.0f
        : 1.0f - smoothstep(end, end + houseGhostVanish, game.effects.x);
    return smoothstep(houseGhostEmerge, houseGhostEmerge + 0.5f, age) * vanish;
}

struct HouseHaunting {
    float dim;      // multiplies the house's warm lights
    float green;    // 0 to 1, the poison glow
    float age;      // seconds since the shot, -1 while quiet
    float seed;     // differs for every haunting
    float blink;    // the one flicker every green light shares, 0 to 1
};

HouseHaunting houseHaunting(device const GameState &game) {
    HouseHaunting mood = {1.0f, 0.0f, houseHauntAge(game),
        game.house.haunt.x, 1.0f};
    float strength = houseHauntStrength(game);
    if (strength <= 0.0f) return mood;
    float time = game.effects.x, age = mood.age;
    // The warm lights sputter as the glass breaks and go out; they stay
    // dark until the house settles. The green glow comes on at once, with
    // no fade.
    float level = age < houseLightsOut
        ? step(0.5f, fract(time * 21.0f)) * (1.0f - age / houseLightsOut)
        : 0.0f;
    mood.dim = mix(1.0f, level, strength);
    mood.green = step(houseGreenOn, age) * strength;
    // Once in each haunting, a moment after the ghost bursts out, every
    // green light in the house drops out together and comes back.
    float blinkAt = houseGhostEmerge + 0.9f + 0.8f * houseHash(mood.seed);
    mood.blink = 1.0f - 0.95f * smoothstep(blinkAt, blinkAt + 0.03f, age)
        * (1.0f - smoothstep(blinkAt + 0.11f, blinkAt + 0.16f, age));
    return mood;
}

// One room's poison glow: its own shade of green, from yellowish to bluish,
// and its own strength, chosen afresh for every haunting and drifting
// slowly, times the flicker all rooms share. room is a room's index or a
// window's seed. Returns the shade and the strength; mood.green scales both.
float4 houseRoomGreen(HouseHaunting mood, float room, float time) {
    float key = mood.seed * 7.13f + room * 3.7f;
    float3 shade = mix(float3(0.55f, 1.0f, 0.12f), float3(0.18f, 1.0f, 0.42f),
        houseHash(key));
    float drift = 0.88f + 0.12f * sin(time * (0.9f + 0.8f
        * houseHash(key + 2.0f)) + 6.0f * houseHash(key + 3.0f));
    return float4(shade, (0.75f + 0.45f * houseHash(key + 1.0f)) * drift
        * mood.blink);
}

// A room lamp of the house, going out and turning green while it is
// haunted; the hall, where the ghost rises, turns greenest. Its warm light
// dies with the others; its green glow holds steady but for the shared
// flicker.
PointLight houseHauntedIndoorLight(uint index, device const GameState &game,
    thread uint &room) {
    PointLight light = houseIndoorLight(index, game.effects.x, room);
    HouseHaunting mood = houseHaunting(game);
    float4 glow = houseRoomGreen(mood, float(room), game.effects.x);
    float share = mood.green * (room == 0u ? 0.85f : 0.55f);
    float warm = mood.dim * (1.0f - share), green = glow.w * share;
    light.color = (light.color * warm + glow.rgb * green)
        / max(warm + green, 1.0e-4f);
    light.power *= warm + green;
    return light;
}

PointLight houseHauntedOutdoorLight(uint index, device const GameState &game) {
    PointLight light = houseOutdoorLight(index, game.effects.x);
    light.power *= houseHaunting(game).dim;
    return light;
}

// The ghost's own green light, for surfaces on the same side of the walls:
// indoors while it is in the rooms, outdoors once it is out.
bool houseGhostLight(device const GameState &game, bool indoors,
    thread PointLight &light) {
    float fade = houseGhostFade(game);
    float3 ghost = game.house.haunt.yzw;
    if (fade <= 0.0f || houseInteriorPoint(ghost) != indoors) return false;
    light = {ghost - float3(0.0f, 0.5f, 0.0f), houseGhostGreen,
        (indoors ? 260.0f : 420.0f) * fade, false};
    return true;
}

// The ghost waits in the hall, at head height.
void houseWake(device GameState &game) {
    game.house.haunt = float4(game.effects.x,
        houseWorld(float3(0.0f, houseFloorY, -3.0f))
            + float3(0.0f, houseGhostHeight, 0.0f));
    game.house.hauntMotion = float4(0.0f, 0.0f, 0.0f, -1.0f);
}

void houseQuiet(device GameState &game) {
    game.house.haunt = float4(-100.0f, 0.0f, 0.0f, 0.0f);
    game.house.hauntMotion = float4(0.0f, 0.0f, 0.0f, -1.0f);
}

// A shot that crosses a ground floor pane, or strikes a window anywhere
// within its casing: its glass, curtains, sash or boards.
bool houseShotHitsWindow(device const GameState &game, float3 origin,
    float3 direction, float limit) {
    float3 normal;
    HouseWindow pane;
    if (houseGlassCrossing(origin, direction, limit, game, normal, pane) > 0.0f)
        return true;
    SceneHit hit = {limit + 0.05f, float3(0.0f), float3(0.0f), 0u, -1, 0u};
    traceHouse(hit, origin, direction, game);
    uint style = hit.material - houseMaterialBase;
    if (!houseMaterial(hit.material) || (style != houseSiding
            && style != houseBattens && style != houseRoof)) return false;
    uint index = min(hit.variant, houseCapacity - 1u);
    device const HousePart &part = game.house.parts[index];
    float3 face = abs(hit.normal.y) < 0.5f && style != houseRoof
        ? houseFaceNormal(part, hit.position) : hit.normal;
    HouseWindow w = houseWindow(part, index, hit.position, face, 0.002f,
        houseWind(game));
    return w.glass + w.drape + w.frame > 0.5f;
}

// Moves the ghost: out of the hall through the front doors to the foot of
// the porch steps, then straight at the player, gathering speed. It
// vanishes when it reaches them, with a jolt and the scare sound.
void advanceHaunt(device GameState &game, device RangeAudio &audio,
    float dt) {
    device HouseModel &house = game.house;
    if (house.haunt.x < 0.0f) return;
    float now = game.effects.x, age = now - house.haunt.x;
    float end = house.hauntMotion.w;
    if (end >= 0.0f && now > end + houseHauntSettle) {
        houseQuiet(game);
        return;
    }
    if (age < houseGhostEmerge) return;
    if (age - dt < houseGhostEmerge) audio.scare = 1u;
    float3 ghost = house.haunt.yzw, velocity = house.hauntMotion.xyz;
    float3 eye = game.player.xyz;
    float3 steps = houseWorld(float3(0.0f, houseFloorY,
        housePorchFront - 1.6f)) + float3(0.0f, houseGhostHeight, 0.0f);
    float3 playerLocal = houseLocal(eye);
    bool playerOnPorch = abs(playerLocal.x) < 8.6f
        && playerLocal.z > housePorchFront - 0.6f && playerLocal.z < 6.2f;
    bool out = houseLocal(ghost).z < housePorchFront - 1.2f || playerOnPorch;
    float3 target = out ? eye : steps;
    float speed = out ? min(3.5f + 2.6f * (age - houseGhostEmerge), 11.0f)
        : 5.0f;
    float3 toward = target - ghost;
    velocity = mix(velocity, toward * (speed / max(length(toward), 0.001f)),
        1.0f - exp(-dt * (out ? 2.5f : 6.0f)));
    ghost += velocity * dt;
    float reach = distance(ghost, eye);
    if (end < 0.0f && (reach < 1.2f || age > houseGhostLife)) {
        house.hauntMotion.w = now;
        if (reach < 1.6f) {
            game.recoil.w = max(game.recoil.w, 0.9f);
            audio.scare = 1u;
        }
    }
    house.haunt.yzw = ghost;
    house.hauntMotion.xyz = velocity;
}

// Box occlusion where the rooms' floors, walls and ceilings meet.
float houseAmbientOcclusion(float3 p) {
    float3 local = houseLocal(p);
    uint room = houseRoom(p);
    float x0 = room == 1u ? -7.7f : (room == 2u ? housePartitionX + 0.15f
        : -housePartitionX);
    float x1 = room == 1u ? -housePartitionX - 0.15f
        : (room == 2u ? 7.7f : housePartitionX);
    float3 below = local - float3(x0, houseFloorY, -5.7f);
    float3 above = float3(x1, houseCeilingY, 5.7f) - local;
    float faces[6] = {below.x, above.x, below.y, above.y, below.z, above.z};
    float occlusion = 1.0f;
    for (uint face = 0u; face < 6u; ++face) {
        float gap = faces[face] * houseScale;
        if (gap < 0.03f) continue;
        occlusion *= 1.0f - 0.42f * exp(-gap / 0.55f);
    }
    return occlusion;
}

// --------------------------------------------------------------- materials

// What shows through a pane of a solid part: a dusty room shaded behind the
// glass, lit by a candle on the sill. A few rooms are dark or lamp-lit, and
// a pale sheet ghost stands in the bay's upper window. House-local units.
// While the house is haunted the light fails and the rooms glow green; the
// ghost's eyes kindle when the glass breaks, and once it has burst out of
// the house the window is empty.
float3 houseRoomBehind(HouseWindow w, device const HousePart &part,
    float3 n, float3 direction, float time, HouseHaunting mood) {
    float3 across = abs(n.z) > 0.5f ? float3(1.0f, 0.0f, 0.0f)
        : float3(0.0f, 0.0f, 1.0f);
    float3 d = float3(dot(direction, across), direction.y,
        max(dot(direction, -n), 0.02f));
    float3 o = float3(w.room.x, w.room.y, 0.0f);
    float halfRoom = max(0.5f * w.cell, w.room.z + 0.5f);
    const float floorV = -0.7f, ceilingV = 2.7f, depth = 2.4f;
    float t = depth / d.z;
    uint surface = 0u;  // back wall, side wall, floor, ceiling
    if (abs(d.x) > 1.0e-4f) {
        float side = ((d.x > 0.0f ? halfRoom : -halfRoom) - o.x) / d.x;
        if (side < t) { t = side; surface = 1u; }
    }
    if (d.y < 0.0f) {
        float floorT = (floorV - o.y) / d.y;
        if (floorT < t) { t = floorT; surface = 2u; }
    } else if (d.y > 0.0f) {
        float ceilingT = (ceilingV - o.y) / d.y;
        if (ceilingT < t) { t = ceilingT; surface = 3u; }
    }
    float3 q = o + d * t;
    float pick = houseHash(w.seed + 11.0f);
    float3 albedo;
    if (surface == 2u) {
        float plank = houseLines(q.x * houseScale, 0.15f, 0.01f, 0.01f);
        albedo = float3(0.07f, 0.045f, 0.03f) * (1.0f - 0.5f * plank);
    } else if (surface == 3u) {
        albedo = float3(0.16f, 0.15f, 0.13f);
    } else {
        // Faded striped paper, peeling in places, with a dark picture frame
        // on the back wall.
        float along = surface == 0u ? q.x : q.z;
        float stripe = step(0.5f, fract(along * 4.0f + pick));
        albedo = mix(float3(0.09f, 0.1f, 0.07f), float3(0.12f, 0.09f, 0.06f),
            stripe) * (0.7f + 0.5f * smoothNoise(float2(along, q.y) * 3.0f));
        float2 picture = abs(float2(q.x - 0.4f * (pick - 0.5f), q.y - 1.3f))
            - float2(0.35f, 0.45f);
        if (surface == 0u && max(picture.x, picture.y) < 0.0f)
            albedo = max(picture.x, picture.y) > -0.06f
                ? float3(0.06f, 0.045f, 0.02f) : float3(0.03f, 0.03f, 0.035f);
    }
    // A candle on the sill, or for a few rooms a lamp further in.
    float level = abs(part.rows.w) * (w.boarded > 0.5f ? 0.25f : 1.0f);
    bool dark = pick < 0.12f, lamp = pick > 0.82f;
    float3 candle = float3(0.3f * (pick - 0.5f), 0.1f, 0.18f);
    float3 source = lamp ? float3(-0.5f, 1.1f, 1.4f) : candle + float3(0.0f,
        0.06f, 0.0f);
    float flicker = houseFlicker(time, w.seed, lamp ? 0.05f : 0.25f);
    float3 toLight = source - q;
    float power = (lamp ? 2.6f : 0.9f) * level * flicker * (dark ? 0.06f : 1.0f)
        * mood.dim;
    float4 glow = houseRoomGreen(mood, w.seed + 10.0f, time);
    float3 warm = mix(float3(1.0f, 0.58f, 0.24f), glow.rgb, mood.green);
    float3 radiance = albedo * warm * power / (dot(toLight, toLight) + 0.08f)
        + albedo * float3(0.07f, 0.05f, 0.03f) * level * (dark ? 0.2f : 1.0f)
            * mood.dim
        + albedo * glow.rgb * 1.4f * mood.green * glow.w * level;
    if (!dark && !lamp) {
        // The candle itself: a wax stub and a flame in front of the room.
        float3 toFlame = candle + float3(0.0f, 0.045f, 0.0f) - o;
        float along = clamp(dot(toFlame, normalize(d)), 0.0f, t * length(d));
        float3 nearest = o + normalize(d) * along;
        float3 offset = (nearest - candle - float3(0.0f, 0.045f, 0.0f))
            * float3(1.0f, 0.55f, 1.0f);
        radiance += (float3(1.0f, 0.62f, 0.25f) * flicker * mood.dim
            + glow.rgb * glow.w * mood.green) * 2.2f
            * exp(-dot(offset, offset) / 0.00012f);
        float wax = length((nearest - candle).xz);
        if (nearest.y > candle.y - 0.09f && nearest.y < candle.y + 0.02f
            && wax < 0.012f)
            radiance = float3(0.5f, 0.45f, 0.35f) * 0.5f * power;
    }
    if (part.rows.y > 1.5f && w.row > 0.5f && mood.age < houseGhostEmerge) {
        // The ghost: a pale sheet with a ragged hem, swaying a little.
        float ghostT = 0.9f / d.z;
        if (ghostT < t) {
            float3 g = o + d * ghostT;
            float sway = 0.05f * sin(time * 0.8f);
            float2 r = float2(g.x - 0.15f - sway * g.y, g.y);
            float head = length((r - float2(0.0f, 1.55f)) * float2(1.0f, 0.9f));
            float hem = 0.12f + 0.04f * sin(r.x * 40.0f + time * 2.0f);
            float body = abs(r.x) - (0.16f + 0.18f * saturate((1.45f - r.y)
                / 1.3f));
            bool sheet = head < 0.17f || (body < 0.0f && r.y < 1.55f
                && r.y > hem);
            if (sheet) {
                float3 pale = float3(0.55f, 0.6f, 0.65f) * (0.5f + 0.5f
                    * smoothNoise(r * 9.0f));
                bool eye = length(float2(abs(r.x) - 0.055f, r.y - 1.57f))
                    < 0.03f;
                radiance = mix(radiance, eye
                    ? houseGhostGreen * 3.0f * step(0.0f, mood.age) * mood.blink
                    : pale * (0.25f + 0.8f * power) + glow.rgb
                        * 0.6f * mood.green * glow.w, 0.85f);
            }
        }
    }
    return radiance;
}

// Seams `width` wide every `spacing` metres, fading to their average
// coverage once finer than a pixel.
float houseLines(float coord, float spacing, float width, float blur) {
    return shellLines(coord, spacing, 0.5f * width, blur);
}

// Fish-scale shingles in courses 20 cm tall: 1 on a scale's rounded lower
// edge, 0 on its face. tone varies per scale.
float houseScales(float2 uv, float blur, thread float &tone) {
    float course = floor(uv.y / 0.2f);
    float offset = fmod(abs(course), 2.0f) * 0.5f;
    float2 cell = float2(uv.x / 0.24f + offset, uv.y / 0.2f);
    float2 f = fract(cell) - float2(0.5f, 0.0f);
    tone = hashTile(floor(cell) + float2(13.0f, 7.0f));
    float edge = length(float2(f.x, (f.y - 0.55f) * 1.15f));
    float line = smoothstep(0.42f, 0.5f, edge) * step(f.y, 0.55f);
    return mix(line, 0.3f, saturate(4.0f * blur / 0.2f));
}

// A nail through a board, seen at q metres from it along the grain and
// across it: a rusty head whose stain weeps down the board (down, in the
// same frame; zero for a board lying flat), or, where the nail has rusted
// through or pulled out, its dark hole with a split running from it.
float3 houseNail(float3 wood, float2 q, bool hole, float2 down, float blur) {
    float r = length(q);
    if (hole) {
        float pit = 1.0f - smoothstep(0.0045f, 0.0045f + blur, r);
        float rim = (1.0f - smoothstep(0.006f, 0.014f + blur, r)) * (1.0f - pit);
        float split = (1.0f - smoothstep(0.0012f, 0.0012f + blur, abs(q.y)))
            * (1.0f - smoothstep(0.01f, 0.04f, abs(q.x)));
        wood = mix(wood, wood * 1.4f + 0.008f, 0.6f * rim);
        return mix(wood, float3(0.004f), max(pit, 0.8f * split));
    }
    float below = dot(q, down);
    float lateral = abs(dot(q, float2(-down.y, down.x)));
    float stain = (1.0f - smoothstep(0.008f, 0.03f, r))
        + (1.0f - smoothstep(0.003f, 0.01f, lateral)) * step(0.0f, below)
            * exp(-below / 0.06f) * dot(down, down);
    wood = mix(wood, float3(0.11f, 0.05f, 0.026f), 0.55f * saturate(stain));
    float head = 1.0f - smoothstep(0.0065f, 0.0065f + blur, r);
    float shine = 1.0f - smoothstep(0.0f, 0.004f,
        length(q - float2(-0.002f, 0.002f)));
    return mix(wood, float3(0.03f, 0.027f, 0.025f)
        + float3(0.05f, 0.032f, 0.02f) * shine, head);
}

// Old clapboards in metres, wide and 30 cm to the weather: butt joints fall
// at random, a few boards have split, rotted away or hang loose, paint has
// peeled back to grey wood, and the boards are nailed near their ends and
// to the odd stud, through their lower edge; here and there a nail has
// rusted away and left its hole. houseCladdingRelief gives them depth; the
// shadow under each lap and the darker butt edge are shaded here. gone
// shows the sheathing behind a missing board.
float3 houseClapboards(HouseBoardCell cell, float s, float y, float seed,
    float blur, float3 paint, bool gone, bool edge) {
    if (gone) {
        float sheathing = houseLines(y, 0.2f, 0.01f, blur);
        float paper = smoothstep(0.45f, 0.6f, smoothNoise(float2(s * 1.3f,
            y * 2.0f + seed)));
        return mix(float3(0.016f, 0.013f, 0.011f), float3(0.006f), paper)
            * (1.0f + 0.8f * sheathing);
    }
    float lap = cell.lap;
    float shade = edge ? 0.7f : 1.0f - 0.4f * smoothstep(0.72f, 1.0f, lap);
    shade = mix(shade, 0.9f, saturate(2.0f * blur / houseClapExposure));
    float joint = houseLines(cell.along, cell.run, 0.01f, blur);
    float3 wood = paint * (0.78f + 0.44f * cell.pick) * shade
        * (1.0f - 0.6f * joint);
    // Peeling paint bares weathered grey grain.
    float peel = smoothstep(0.6f, 0.68f, smoothNoise(float2(s * 1.9f,
        y * 2.7f + seed)) + 0.25f * smoothNoise(float2(s * 7.0f, y * 9.0f)));
    float grain = 0.85f + 0.15f * sin(s * 47.0f + 6.0f
        * smoothNoise(float2(s * 2.0f, cell.course)));
    wood = mix(wood, float3(0.15f, 0.14f, 0.125f) * grain * shade, peel);
    if (cell.pick > 0.93f) {
        // A split runs along the board.
        float crack = abs(lap - 0.5f - 0.15f * sin(s * 2.3f + cell.pick * 9.0f));
        wood *= 0.35f + 0.65f * smoothstep(0.006f,
            0.006f + blur / houseClapExposure, crack);
    }
    if (edge) return wood;
    const float2 down = float2(0.0f, -1.0f);
    float nailY = (lap - 0.22f) * houseClapExposure;
    float start = cell.along - cell.segment * cell.run;
    float far = start < 0.5f * cell.run ? 0.0f : 1.0f;
    float key = hashTile(float2(cell.course * 3.1f + cell.segment + 0.5f * far,
        seed + 19.0f));
    float2 q = float2(start - (far < 0.5f ? 0.045f : cell.run - 0.045f), nailY);
    if (key > 0.48f && dot(q, q) < 0.005f)
        wood = houseNail(wood, q, key < 0.62f, down, blur);
    float stud = round(s / 0.6f);
    float studKey = hashTile(float2(cell.course + 0.37f * stud, seed + 23.0f));
    q = float2(s - stud * 0.6f, nailY);
    if (studKey > 0.82f && dot(q, q) < 0.005f)
        wood = houseNail(wood, q, studKey < 0.86f, down, blur);
    return wood;
}

// Board and batten in metres: crooked battens, a few gone, stand proud of
// the boards between them, which show their grain where paint has peeled
// and lie in the battens' shadow at their edges. Nails run up the battens.
float3 houseBattenBoards(float s, float y, float seed, float blur,
    float3 paint) {
    bool present;
    float k = round(s / houseBattenPitch);
    float centre = houseBattenCentre(k, y, seed, present);
    float pick = hashTile(float2(k, seed));
    float offset = abs(s - centre);
    float peel = smoothstep(0.62f, 0.7f, smoothNoise(float2(s * 2.2f,
        y * 1.3f + seed)));
    float grain = 0.85f + 0.15f * sin(s * 47.0f + 5.0f * smoothNoise(float2(
        s * 3.0f, y * 0.3f)));
    float3 wood;
    if (present && offset <= houseBattenHalfWidth + 0.001f) {
        wood = mix(paint * (0.95f + 0.2f * pick),
            float3(0.15f, 0.14f, 0.125f) * grain, 0.7f * peel);
        float row = round(y / 0.5f);
        float key = hashTile(float2(k * 1.7f + row, seed + 29.0f));
        float2 q = float2(s - centre, y - row * 0.5f);
        if (key > 0.78f && dot(q, q) < 0.005f)
            wood = houseNail(wood, q, key < 0.86f, float2(0.0f, -1.0f), blur);
    } else {
        float board = hashTile(float2(floor(s / houseBattenPitch + 0.5f),
            seed + 2.0f));
        float shadow = present ? 0.62f + 0.38f * smoothstep(0.0f, 0.06f,
            offset - houseBattenHalfWidth) : 1.0f;
        wood = mix(paint * (0.8f + 0.25f * board),
            float3(0.15f, 0.14f, 0.125f) * grain, peel) * shadow;
    }
    return wood * (1.0f - 0.25f * smoothstep(0.7f, 0.9f,
        smoothNoise(float2(s * 0.8f, y * 0.2f))));
}

// The glass of a solid part's window: old, slightly green glass smeared
// with grime, the room behind it shaded through, and curtains tied back or
// blowing across it.
SurfaceMaterial houseGlassPane(HouseWindow w, device const HousePart &part,
    float3 n, float3 direction, float3 p, float time, float3 surround,
    float3 trim, HouseHaunting mood) {
    float3 albedo = mix(surround, trim, w.frame);
    float3 emission = float3(0.0f);
    float level = abs(part.rows.w);
    if (w.drape > 0.0f) {
        float folds = 0.55f + 0.45f * w.fold;
        albedo = mix(albedo, float3(0.18f, 0.02f, 0.025f) * folds, w.drape);
        float4 glow = houseRoomGreen(mood, w.seed + 10.0f, time);
        emission += (float3(0.06f, 0.012f, 0.008f) * mood.dim
            + glow.rgb * 0.05f * mood.green * glow.w) * level * folds * w.drape;
    }
    if (w.glass > 0.0f) {
        float grime = smoothstep(0.4f, 0.9f, smoothNoise(float2(p.x + p.z,
            p.y) * 3.5f)) * (0.5f + 0.5f * w.uv.y);
        float3 room = houseRoomBehind(w, part, n, direction, time, mood)
            * float3(0.86f, 0.92f, 0.84f) * (1.0f - 0.45f * grime);
        albedo = mix(albedo, float3(0.03f, 0.032f, 0.028f) * (1.0f + 3.0f
            * grime), w.glass);
        emission += room * w.glass;
    }
    return {albedo, mix(0.8f, 0.12f, w.glass), 0.0f, emission};
}

// A board from the timber generator: silvered, weathered grain along its
// length, rot toward its ends, the odd check, growth rings on its sawn ends,
// and the nails it was given. A loose clapboard keeps patches of paint.
SurfaceMaterial houseTimberMaterial(device const HousePart &part, float3 p,
    float3 n, float blur, float3 paint) {
    float3 a = part.windows.xyz, centre = part.rows.xyz;
    float3 b = part.planes[2].xyz;
    float halfLength = part.windows.w;
    float halfWidth = part.planes[2].w - dot(b, centre);
    float3 d = p - centre;
    float u = dot(d, a), v = dot(d, b);
    float nails = part.rows.w;
    float seed = dot(centre, float3(1.7f, 3.1f, 5.3f));
    float grain = 0.8f + 0.2f * sin(v * 160.0f + 7.0f * smoothNoise(float2(
        u * 1.3f, v * 9.0f + seed)));
    float3 wood = float3(0.115f, 0.104f, 0.09f) * grain
        * (0.8f + 0.4f * houseHash(seed));
    wood *= 1.0f - 0.45f * smoothstep(halfLength - 0.3f, halfLength, abs(u));
    float checkAt = halfLength * (houseHash(seed + 4.0f) - 0.5f);
    float check = abs(v - halfWidth * (houseHash(seed + 1.0f) - 0.5f)
        - 0.004f * sin(u * 9.0f + seed));
    wood *= mix(1.0f, 0.4f + 0.6f * smoothstep(0.0012f, 0.0012f + blur, check),
        step(abs(u - checkAt), 0.3f * halfLength));
    if (abs(dot(n, a)) > 0.7f) {
        float rings = houseLines(length(float2(v, dot(d, cross(a, b))))
            + 0.01f * houseHash(seed + 2.0f), 0.006f, 0.0015f, blur);
        return {wood * 0.65f * (1.0f - 0.4f * rings), 0.9f, 0.0f, float3(0.0f)};
    }
    if (nails == houseNailAtPivot) {
        float peel = smoothstep(0.55f, 0.65f, smoothNoise(float2(u * 1.9f
            + seed, v * 9.0f)));
        wood = mix(paint * (0.85f + 0.3f * houseHash(seed + 2.0f)),
            wood * 1.2f, peel);
    }
    if (abs(dot(n, b)) < 0.5f && nails != houseNoNails) {
        float2 down = float2(-a.y, -b.y);
        down = dot(down, down) > 0.09f ? normalize(down) : float2(0.0f);
        float2 q = float2(u, v);
        if (nails == houseNailAtCentre) {
            wood = houseNail(wood, q, false, down, blur);
        } else if (nails == houseNailAtPivot) {
            float end = halfLength - 0.07f;
            wood = u < 0.0f ? houseNail(wood, q + float2(end, 0.0f), false,
                down, blur) : houseNail(wood, q - float2(end, 0.0f), true,
                down, blur);
        } else {
            float side = u < 0.0f ? -1.0f : 1.0f;
            float key = houseHash(seed + 3.0f + side);
            if (key > 0.35f)
                wood = houseNail(wood, q - float2(side * (halfLength - 0.05f),
                    0.0f), key < 0.55f, down, blur);
        }
    }
    return {wood, 0.85f, 0.0f, float3(0.0f)};
}

// A log from the timber generator: deep fissures between corky plates of
// bark, worn away in patches to silvered wood, a few knots, and sawn ends
// with growth rings, radial checks and the bark's dark rim. Over the fire
// it is blackened by soot from below.
SurfaceMaterial houseLogMaterial(device const HousePart &part, float3 p,
    float3 n, float blur, bool sooty) {
    float3 a = part.windows.xyz, centre = part.rows.xyz;
    float radius = part.rows.w;
    float3 d = p - centre;
    float u = dot(d, a);
    float3 across = d - a * u;
    float3 e1 = normalize(cross(abs(a.y) < 0.9f ? float3(0.0f, 1.0f, 0.0f)
        : float3(1.0f, 0.0f, 0.0f), a));
    float3 e2 = cross(a, e1);
    float angle = atan2(dot(across, e2), dot(across, e1));
    float2 ring = float2(cos(angle), sin(angle));
    float seed = dot(centre, float3(1.7f, 3.1f, 5.3f));
    float soot = sooty ? 0.15f + 0.75f * smoothstep(0.1f, -0.6f, n.y) : 0.0f;
    if (abs(dot(n, a)) > 0.7f) {
        float rho = length(across);
        float wobble = 0.004f * sin(angle * 3.0f + seed)
            + 0.003f * smoothNoise(ring * 2.0f + rho * 30.0f);
        float rings = houseLines(rho + wobble, 0.011f, 0.0025f, blur);
        float3 wood = float3(0.2f, 0.145f, 0.09f) * (0.85f + 0.3f
            * smoothNoise(ring * 3.0f + rho * 20.0f)) * (1.0f - 0.35f * rings);
        wood *= 1.0f - 0.3f * smoothstep(0.5f * radius, 0.0f, rho);
        // Five checks split out from the heart.
        float spoke = abs(fract(angle / (2.0f * rangePi) * 5.0f + 0.13f
            * smoothNoise(float2(rho * 25.0f, seed))) - 0.5f)
            * 2.0f * rangePi * rho / 5.0f;
        float check = (1.0f - smoothstep(0.0015f, 0.0015f + blur, spoke))
            * step(0.25f * radius, rho) * step(rho, 0.85f * radius);
        wood *= 1.0f - 0.85f * check;
        if (rho > radius - 0.03f) wood = float3(0.04f, 0.03f, 0.022f);
        if (rho < 0.008f) wood *= 0.4f;
        return {mix(wood, float3(0.008f), soot * 0.5f), 0.9f, 0.0f,
            float3(0.0f)};
    }
    float columns = max(round(2.0f * rangePi * radius / 0.045f), 6.0f);
    float column = angle / (2.0f * rangePi) * columns
        + 0.35f * smoothNoise(ring * 2.0f + float2(u * 1.3f, seed));
    float fissure = smoothstep(0.75f, 0.95f, abs(fract(column) - 0.5f) * 2.0f);
    float shift = hashTile(float2(fmod(floor(column) + columns, columns), seed));
    float crossing = smoothstep(0.85f, 0.97f,
        abs(fract(u / 0.22f + shift) - 0.5f) * 2.0f);
    float groove = mix(max(fissure, 0.7f * crossing), 0.35f,
        saturate(blur / 0.02f));
    float3 bark = mix(float3(0.075f, 0.058f, 0.042f),
        float3(0.012f, 0.009f, 0.007f), groove)
        * (0.8f + 0.4f * smoothNoise(ring * 3.0f + float2(u * 5.0f, 0.0f)));
    float bare = smoothstep(0.6f, 0.68f, smoothNoise(ring * 1.5f
        + float2(u * 1.1f + seed, 0.0f)));
    float grain = 0.8f + 0.2f * sin(angle * round(radius * 140.0f)
        + 6.0f * smoothNoise(ring * 4.0f + float2(u * 2.0f, 0.0f)));
    float3 albedo = mix(bark, float3(0.17f, 0.13f, 0.09f) * grain, bare);
    for (uint k = 0u; k < 2u; ++k) {
        float at = (houseHash(seed + float(k) * 5.0f) - 0.5f)
            * 1.6f * part.windows.w;
        float turn = 2.0f * rangePi * houseHash(seed + float(k) * 5.0f + 1.0f);
        float2 offset = float2(radius * atan2(sin(angle - turn),
            cos(angle - turn)), (u - at) * 0.6f);
        float knot = length(offset);
        albedo = mix(albedo, float3(0.03f, 0.02f, 0.014f),
            (1.0f - smoothstep(0.02f, 0.035f, knot))
                * (0.6f + 0.4f * smoothstep(0.012f, 0.0f, abs(knot - 0.026f))));
    }
    return {mix(albedo, float3(0.008f), soot), mix(0.95f, 0.7f, bare), 0.0f,
        float3(0.0f)};
}

// One line of worn engraved letters centred on q = 0, in metres: each
// letter is a few stems, bars and a bowl, with a gap now and then between
// words. Returns the groove's coverage.
float houseLettering(float2 q, float halfWidth, float size, float seed,
    float blur) {
    if (abs(q.x) > halfWidth || abs(q.y) > 0.6f * size) return 0.0f;
    float pitch = 0.62f * size;
    float cell = floor(q.x / pitch);
    float key = hashTile(float2(cell, seed));
    if (key < 0.12f) return 0.0f;
    float2 f = float2(q.x / pitch - cell - 0.5f, q.y / size);
    if (abs(f.x) > 0.32f || abs(f.y) > 0.5f) return 0.0f;
    float aspect = pitch / size;
    float stroke = 1.0e3f;
    if (key > 0.3f) stroke = min(stroke, abs(f.x + 0.25f) * aspect);
    if (fract(key * 7.0f) > 0.5f) stroke = min(stroke, abs(f.x - 0.25f) * aspect);
    if (fract(key * 13.0f) > 0.55f) stroke = min(stroke, abs(f.y - 0.44f));
    if (fract(key * 17.0f) > 0.6f) stroke = min(stroke, abs(f.y + 0.44f));
    if (fract(key * 19.0f) > 0.65f) stroke = min(stroke, abs(f.y));
    if (fract(key * 23.0f) > 0.75f)
        stroke = min(stroke, abs(length(f * float2(aspect, 1.0f)) - 0.3f));
    return 1.0f - smoothstep(0.07f, 0.07f + blur / size, stroke);
}

// Headstones and the tomb, in metres. A headstone is grey or dark slate,
// streaked and blotched with lichen, dirty near the ground, and engraved
// with a cross over three lines of lettering. The tomb is pale ashlar under
// stone roof slabs, with a worn inscription over its door, and its doorway
// is dark; a sick glow stirs in it while the house is haunted.
SurfaceMaterial houseGraveMaterial(device const HousePart &part, float3 p,
    float3 n, float blur, HouseHaunting mood, float time) {
    float seed = dot(part.lower.xyz, float3(1.3f, 2.9f, 4.7f));
    if (part.windows.w < -0.5f) {
        float v = (p.y - part.lower.y) / (part.upper.y - part.lower.y);
        float glow = 0.004f + 0.09f * mood.green * mood.blink * (0.7f + 0.3f
            * sin(time * 3.1f));
        return {float3(0.003f), 1.0f, 0.0f,
            houseGhostGreen * glow * (1.0f - 0.6f * v)};
    }
    float lichen = smoothstep(0.62f, 0.75f, smoothNoise(float2(
        (p.x + p.z) * 6.0f, p.y * 6.0f) + seed));
    float height = p.y - houseOrigin.y;
    if (length(part.windows.xyz) > 0.5f) {
        float3 front = part.windows.xyz, foot = part.rows.xyz;
        float lean = part.windows.w, tall = part.rows.w;
        float tone = houseHash(seed);
        float3 albedo = mix(float3(0.13f, 0.128f, 0.12f),
            float3(0.07f, 0.075f, 0.08f), step(0.5f, tone))
            * (0.8f + 0.4f * smoothNoise(p.xz * 7.0f + p.y * 5.0f));
        albedo = mix(albedo, float3(0.085f, 0.09f, 0.06f), 0.7f * lichen);
        albedo *= 0.65f + 0.35f * smoothstep(0.0f, 0.25f, height);
        if (dot(n, front) > 0.8f) {
            float3 side = normalize(cross(float3(0.0f, 1.0f, 0.0f), front));
            float3 rise = cross(front, side);
            float2 q = float2(dot(p - foot, side), dot(p - foot, rise));
            q = float2(q.x * cos(lean) - q.y * sin(lean),
                q.y * cos(lean) + q.x * sin(lean));
            float top = tall - 0.3f;
            float groove = max(
                step(abs(q.x), 0.012f) * step(abs(q.y - top), 0.11f),
                step(abs(q.y - top - 0.04f), 0.012f) * step(abs(q.x), 0.065f));
            for (uint row = 0u; row < 3u; ++row)
                groove = max(groove, houseLettering(float2(q.x,
                    q.y - top + 0.24f + 0.085f * float(row)),
                    0.17f - 0.03f * float(row) * tone, 0.045f,
                    seed + float(row) * 31.0f, blur));
            albedo = mix(albedo, albedo * 0.35f,
                groove * (0.55f + 0.45f * houseHash(seed + 9.0f)));
        }
        return {albedo, 0.85f, 0.0f, float3(0.0f)};
    }
    // The tomb: streaked limestone.
    float s = abs(n.z) > 0.5f ? p.x : p.z;
    float3 stone = float3(0.17f, 0.162f, 0.145f)
        * (0.8f + 0.35f * smoothNoise(float2(s * 3.0f, p.y * 0.4f)));
    stone *= 1.0f - 0.35f * smoothstep(0.55f, 0.8f, smoothNoise(float2(s * 5.0f,
        p.y * 0.25f)));
    stone = mix(stone, float3(0.09f, 0.095f, 0.065f), 0.6f * lichen);
    if (abs(n.y) < 0.2f) {
        float course = floor(height / 0.35f);
        float along = s + fmod(abs(course), 2.0f) * 0.35f;
        float mortar = max(houseLines(height, 0.35f, 0.012f, blur),
            houseLines(along, 0.7f, 0.012f, blur));
        stone *= (0.85f + 0.3f * hashTile(float2(floor(along / 0.7f), course)))
            * (1.0f - 0.55f * mortar);
        float centre = 0.5f * (part.lower.x + part.upper.x);
        if (n.z < -0.9f && part.upper.x - part.lower.x > 2.0f
            && height > 2.42f && height < 2.66f)
            stone *= 1.0f - 0.6f * houseLettering(float2(p.x - centre,
                height - 2.54f), 0.8f, 0.09f, seed, blur);
    } else if (n.y < 0.98f) {
        // Roof slabs, laid down the slope.
        stone *= 1.0f - 0.5f * houseLines(p.z, 0.5f, 0.015f, blur);
    }
    return {stone, 0.9f, 0.0f, float3(0.0f)};
}

// The rooms' walls, s along the wall and y above the floor in metres: a
// skirting board and panelled wainscot under a dado rail; damask paper
// with gilt rosettes on an ogee lattice, ochre in the hall, oxblood in the
// parlour and bottle green in the dining room; a picture rail, a gilt
// palmette frieze and a dentilled plaster cornice. The paper is old: its
// seams are dark and some have lifted and curled back to the plaster, damp
// has stained it in tide marks, it is torn away to plaster and lath in
// places and spotted with mould low down, and pale patches show where
// pictures hung. On walls without windows crooked portraits still hang
// within span, their eyes lit green while the house is haunted.
SurfaceMaterial houseWallpaper(float s, float y, uint room, float seed,
    bool portraits, float2 span, float blur, HouseHaunting mood, float time) {
    const float3 wood = float3(0.07f, 0.04f, 0.025f);
    const float3 plaster = float3(0.25f, 0.23f, 0.2f);
    const float3 gold = float3(0.3f, 0.21f, 0.075f);
    const float height = (houseCeilingY - houseFloorY) * houseScale;
    float3 ground = room == 1u ? float3(0.12f, 0.022f, 0.028f)
        : (room == 2u ? float3(0.028f, 0.062f, 0.042f)
            : float3(0.105f, 0.072f, 0.034f));
    float3 flock = ground * float3(0.42f, 0.36f, 0.4f);
    // Fine pattern fades to its mean once it is smaller than a pixel.
    float detail = saturate(1.0f - blur / 0.012f);
    if (y < 0.2f)
        return {wood * 0.6f * (1.6f - 0.6f * smoothstep(0.01f, 0.01f + blur,
            abs(y - 0.17f))), 0.5f, 0.0f, float3(0.0f)};
    if (y < 1.3f) {
        float panel = max(houseLines(s, 0.62f, 0.05f, blur),
            houseLines(y - 0.2f, 1.1f, 0.05f, blur));
        return {wood * (1.0f - 0.35f * panel), 0.45f, 0.0f, float3(0.0f)};
    }
    if (y < 1.38f) return {wood * 1.3f, 0.4f, 0.0f, float3(0.0f)};
    if (y > height - 0.25f) {
        // A cove over a row of dentils.
        float band = (y - (height - 0.25f)) / 0.25f;
        float dentil = band > 0.12f && band < 0.4f
            ? mix(0.55f, step(0.45f, fract(s / 0.075f)), detail) : 0.0f;
        float cove = smoothstep(0.45f, 0.75f, band)
            * (1.0f - smoothstep(0.85f, 1.0f, band));
        return {plaster * (0.85f + 0.15f * band) * (1.0f - 0.35f * dentil)
            * (1.0f - 0.25f * cove), 0.9f, 0.0f, float3(0.0f)};
    }
    if (y > height - 0.95f && y < height - 0.91f)
        return {wood * 1.1f, 0.4f, 0.0f, float3(0.0f)};

    // A crooked portrait in a gilt frame: a pale face over dark shoulders
    // on black varnished canvas. It casts a soft shadow down the wall.
    float slot = floor(s / 2.6f);
    float hang = hashTile(float2(slot, seed + 41.0f));
    float2 at = float2((slot + 0.5f) * 2.6f
        + 0.6f * (hashTile(float2(slot, seed + 42.0f)) - 0.5f),
        2.7f + 0.5f * hashTile(float2(slot, seed + 43.0f)));
    const float2 frame = float2(0.34f, 0.44f);
    bool portrait = portraits && hang >= 0.62f && at.x - 0.5f > span.x
        && at.x + 0.5f < span.y;
    float tilt = 0.12f * (hashTile(float2(slot, seed + 44.0f)) - 0.5f);
    float2 q = float2(s, y) - at;
    q = float2(q.x * cos(tilt) + q.y * sin(tilt),
        q.y * cos(tilt) - q.x * sin(tilt));
    float2 outside = abs(q) - frame;
    float box = max(outside.x, outside.y);
    if (portrait && box < 0.0f) {
        if (box > -0.07f) {
            float bevel = smoothstep(-0.07f, -0.035f, box);
            return {gold * (0.6f + 0.6f * bevel) * (0.8f + 0.3f
                * smoothNoise(q * 40.0f)), 0.4f, 0.7f, float3(0.0f)};
        }
        float2 face = (q - float2(0.0f, 0.08f)) / float2(0.1f, 0.13f);
        float2 body = (q - float2(0.0f, -0.32f)) / float2(0.26f, 0.2f);
        float3 canvas = float3(0.025f, 0.018f, 0.012f)
            * (0.8f + 0.4f * smoothNoise(q * 6.0f));
        if (dot(body, body) < 1.0f) canvas = float3(0.008f, 0.006f, 0.005f);
        if (dot(face, face) < 1.0f)
            canvas = float3(0.075f, 0.058f, 0.042f) * (0.8f + 0.2f * face.y);
        float3 glow = float3(0.0f);
        if (length(float2(abs(q.x) - 0.035f, q.y - 0.1f)) < 0.013f) {
            canvas = float3(0.005f);
            glow = houseGhostGreen * 1.6f * mood.green * mood.blink
                * (0.7f + 0.3f * sin(time * 6.0f));
        }
        return {canvas, 0.3f, 0.0f, glow};
    }

    float3 albedo;
    float roughness = 0.85f, metallic = 0.0f;
    if (y >= height - 0.91f) {
        // The frieze: gilt palmettes over a scroll, between gilt borders.
        float v = (y - (height - 0.91f)) / 0.66f;
        float2 c = float2((fract(s / 0.34f) - 0.5f) * 0.34f, (v - 0.22f) * 0.66f);
        float r = length(c), angle = atan2(c.x, c.y);
        float lobe = 0.2f + 0.035f * cos(angle * 7.0f);
        float fan = step(abs(angle), 1.25f);
        float palmette = (1.0f - smoothstep(0.005f, 0.005f + blur,
            abs(r - lobe))) * fan;
        float ribs = (1.0f - smoothstep(0.004f, 0.004f + blur,
            abs(fract(angle * 7.0f / (2.0f * rangePi) + 0.5f) - 0.5f) * r))
            * fan * step(r, lobe) * step(0.03f, r);
        float scroll = 1.0f - smoothstep(0.004f, 0.004f + blur,
            abs(c.y + 0.07f - 0.03f * sin(s * 2.0f * rangePi / 0.34f)));
        float border = 1.0f - smoothstep(0.005f, 0.005f + blur,
            min(abs(v - 0.04f), abs(v - 0.96f)) * 0.66f);
        float line = mix(0.12f, max(max(palmette, ribs), max(scroll, border)),
            detail);
        albedo = mix(ground * 0.55f, gold, line);
        metallic = 0.55f * line;
        roughness = mix(0.85f, 0.35f, line);
    } else {
        // Damask: rosettes at the points of a half-drop repeat, each in a
        // diamond of the gilt ogee lattice, with sprigs where the diamonds
        // meet. The repeat is 53 cm across and 64 cm up.
        float2 t = float2(s / 0.53f, (y - 1.38f) / 0.64f);
        float2 cell = fract(float2(0.5f * t.x + t.y, 0.5f * t.x - t.y) + 0.5f)
            - 0.5f;
        float2 m = float2((cell.x + cell.y) * 0.53f,
            0.5f * (cell.x - cell.y) * 0.64f);
        float r = length(m * float2(1.0f, 0.82f));
        float angle = atan2(m.y, m.x);
        float petal = 0.105f + 0.022f * cos(angle * 8.0f)
            + 0.012f * cos(angle * 4.0f + 1.0f);
        float rosette = 1.0f - smoothstep(petal - blur, petal + blur, r);
        float boss = 1.0f - smoothstep(0.035f - blur, 0.035f + blur, r);
        float outline = 1.0f - smoothstep(0.004f, 0.004f + blur,
            abs(r - petal - 0.014f));
        float2 wave = cell + 0.09f * sin(2.0f * rangePi * cell.yx);
        float edge = (0.5f - max(abs(wave.x), abs(wave.y))) / 1.83f;
        float ogee = 1.0f - smoothstep(0.003f, 0.003f + blur, edge);
        float2 corner = sign(cell) * 0.5f - cell;
        float sprig = 1.0f - smoothstep(0.018f - blur, 0.018f + blur,
            length(float2((corner.x + corner.y) * 0.53f,
                0.5f * (corner.x - corner.y) * 0.64f)));
        float motif = mix(0.3f, max(rosette - 0.6f * boss, sprig), detail);
        float line = mix(0.1f, max(outline, ogee), detail);
        albedo = mix(ground, flock, motif);
        albedo = mix(albedo, gold, 0.8f * line);
        metallic = 0.5f * line;
        roughness = mix(0.85f, 0.35f, line);
    }
    albedo *= 0.8f + 0.3f * smoothNoise(float2(s, y) * 1.7f);

    // Pale where a picture hung straight, with its nail above.
    if (hang > 0.35f && hang < 0.62f) {
        float2 patch = abs(float2(s, y) - at) - frame;
        albedo = mix(albedo, albedo * 1.45f,
            1.0f - smoothstep(-0.03f, 0.0f, max(patch.x, patch.y)));
        albedo = mix(albedo, float3(0.02f), 1.0f - smoothstep(0.004f,
            0.004f + blur, length(float2(s, y) - at
                - float2(0.0f, frame.y + 0.18f))));
    } else if (portrait) {
        float2 shadow = abs(q - float2(0.02f, -0.03f)) - frame;
        albedo *= 0.5f + 0.5f * smoothstep(0.0f, 0.035f,
            max(shadow.x, shadow.y));
    }
    // Dark seams between the drops; a few have lifted and curl back.
    float seamDistance = abs(fract(s / 0.53f) - 0.5f) * 0.53f;
    float seam = floor(s / 0.53f);
    albedo *= 1.0f - 0.5f * (1.0f - smoothstep(0.0015f, 0.0015f + blur,
        seamDistance));
    float lift = hashTile(float2(seam, seed + 31.0f));
    float peelAt = (y - 1.6f - 3.5f * hashTile(float2(seam, seed + 32.0f)))
        / (0.6f + 1.2f * hashTile(float2(seam, seed + 33.0f)));
    if (lift > 0.55f && peelAt > 0.0f && peelAt < 1.0f) {
        float width = 0.07f * sin(peelAt * rangePi) * (0.6f + 0.4f * lift);
        if (seamDistance < width) {
            albedo = width - seamDistance < 0.012f ? ground * 0.25f
                : plaster * 0.85f;
            metallic = 0.0f;
            roughness = 0.9f;
        }
    }
    // Damp runs down from the ceiling and leaves tide marks.
    float damp = smoothNoise(float2(s * 0.45f + seed, y * 0.18f))
        + 0.4f * smoothNoise(float2(s * 1.7f, y * 0.9f))
        + 0.35f * smoothstep(0.5f * height, height, y);
    albedo = mix(albedo, albedo * float3(0.7f, 0.6f, 0.45f)
        + float3(0.02f, 0.014f, 0.006f), smoothstep(1.0f, 1.12f, damp));
    albedo *= 1.0f - 0.35f * (1.0f - smoothstep(0.0f, 0.02f,
        abs(damp - 1.02f)));
    // Torn away to the plaster, and further to the laths.
    float tear = smoothNoise(float2(s * 0.9f + 17.0f + seed, y * 0.7f))
        + 0.35f * smoothNoise(float2(s * 4.0f, y * 3.6f));
    if (tear > 1.1f) {
        metallic = 0.0f;
        roughness = 0.95f;
        albedo = tear < 1.125f ? mix(ground, plaster, 0.5f) * 1.1f
            : (tear < 1.24f ? plaster * (0.75f + 0.25f
                * smoothNoise(float2(s, y) * 9.0f))
                : mix(wood * 1.3f, float3(0.006f),
                    houseLines(y, 0.038f, 0.012f, blur)));
    }
    // Mould spots low on the paper.
    float mould = smoothstep(0.7f, 0.9f, smoothNoise(float2(s, y) * 6.0f))
        * smoothNoise(float2(s, y) * 30.0f)
        * (1.0f - smoothstep(1.4f, 2.6f, y));
    albedo *= 1.0f - 0.6f * mould * detail;
    return {albedo, roughness, metallic, float3(0.0f)};
}

SurfaceMaterial houseSurfaceMaterial(SceneHit hit,
    device const GameState &game, float time, float pixelWidth,
    float3 direction) {
    uint index = min(hit.variant, houseCapacity - 1u);
    device const HousePart &part = game.house.parts[index];
    uint style = hit.material - houseMaterialBase;
    float3 p = hit.position, n = hit.normal;
    float3 local = houseLocal(p);
    float3 metres = p - houseOrigin;
    float blur = max(pixelWidth, 0.003f);
    bool inside = houseInteriorPoint(p);
    bool zFace = abs(n.z) > 0.5f;
    float s = zFace ? p.x : p.z;
    const float3 trim = float3(0.045f, 0.038f, 0.034f);
    const float3 paint = float3(0.13f, 0.115f, 0.12f);
    const float3 iron = float3(0.02f, 0.02f, 0.022f);
    HouseHaunting mood = houseHaunting(game);
    HouseWind wind = houseWind(game);

    if (style == houseSiding || style == houseBattens) {
        float storeyY = metres.y - houseFloorY * houseScale;
        if (inside && n.y < -0.5f) {
            // Plaster ceiling, water-stained.
            float stain = smoothstep(0.55f, 0.8f, smoothNoise(p.xz * 0.6f));
            return {float3(0.24f, 0.22f, 0.19f) * (1.0f - 0.3f * stain), 0.9f,
                0.0f, float3(0.0f)};
        }
        // The board under a relief hit may slope or face up or down; the
        // wall's face it belongs to sets the windows and the pattern.
        float3 face = houseFaceNormal(part, p);
        zFace = abs(face.z) > 0.5f;
        s = zFace ? p.x : p.z;
        float lo = zFace ? part.lower.x : part.lower.z;
        float hi = zFace ? part.upper.x : part.upper.z;
        HouseWindow w = houseWindow(part, index, p, face, blur, wind);
        if (inside) {
            // Wallpaper between wainscot and cornice; curtains are drawn
            // across the windows.
            float3 wood = float3(0.07f, 0.04f, 0.025f);
            SurfaceMaterial paper = houseWallpaper(s, storeyY, houseRoom(p),
                float(index) * 3.1f, part.windows.x + part.windows.y < 0.5f,
                float2(lo, hi), blur, mood, time);
            // Seen through glass the trace passes on; what is shaded here
            // is the frame and the curtains, tied back at the sides or
            // blowing loose.
            float folds = 0.6f + 0.4f * w.fold;
            float3 curtain = float3(0.2f, 0.018f, 0.026f) * folds;
            float covered = saturate(w.frame + w.drape + w.glass);
            float3 albedo = mix(paper.albedo, wood * 0.8f, w.frame);
            albedo = mix(albedo, curtain, w.drape + w.glass);
            return {albedo, mix(mix(paper.roughness, 0.6f, w.frame), 0.95f,
                    w.drape),
                paper.metallic * (1.0f - covered),
                paper.emission * (1.0f - covered)};
        }
        float seed = houseCladdingSeed(index, houseFaceCode(face));
        bool edge = abs(n.y) > 0.5f;
        float3 wall;
        if (style == houseBattens) {
            wall = houseBattenBoards(s, metres.y, seed, blur, paint);
        } else {
            HouseBoardCell cell = houseClapboardCell(s, metres.y, seed);
            wall = houseClapboards(cell, s, metres.y, seed, blur, paint,
                houseBoardGone(part, houseFaceCode(face), s, metres.y, cell),
                edge);
        }
        // Grime streaks down from the sills and a damp band near the
        // foundation.
        float grime = smoothstep(0.45f, 0.85f,
            smoothNoise(float2(s * 1.6f, p.y * 0.25f)));
        wall *= 1.0f - 0.35f * grime;
        wall *= 0.75f + 0.25f * smoothstep(0.2f, 1.6f, storeyY);
        // Corner boards and door casings at the face's edges.
        float corner = min(s - lo, hi - s);
        if (corner < houseCornerBoard && !edge)
            wall = trim * (1.0f + 0.4f * smoothNoise(float2(s * 3.0f,
                p.y * 0.7f)));
        if (houseSeeThrough(part)) {
            // Clear panes are passed through by the trace; only the frame
            // and the backs of the curtains are shaded here. While the
            // house glows green, it shows through the cloth.
            float folds = 0.6f + 0.4f * w.fold;
            float3 albedo = mix(wall, trim, w.frame);
            albedo = mix(albedo, float3(0.12f, 0.015f, 0.02f) * folds,
                w.drape + w.glass);
            float4 glow = houseRoomGreen(mood, float(houseRoom(p)), time);
            return {albedo, 0.8f, 0.0f, glow.rgb * 0.16f * mood.green * glow.w
                * abs(part.rows.w) * folds * folds * (w.drape + w.glass)};
        }
        return houseGlassPane(w, part, face, direction, p, time, wall, trim,
            mood);
    }

    if (style == houseTimber) return houseTimberMaterial(part, p, n, blur, paint);
    if (style == houseLog) return houseLogMaterial(part, p, n, blur, inside);
    if (style == houseGrave)
        return houseGraveMaterial(part, p, n, blur, mood, time);

    if (style == houseRoof) {
        if (n.y < -0.5f) {
            // Soffits under the eaves, with brackets every 60 cm.
            float bracket = houseLines(p.x + p.z, 0.6f, 0.06f, blur);
            return {trim * (1.0f - 0.4f * bracket), 0.7f, 0.0f, float3(0.0f)};
        }
        float tone;
        // Box faces are exactly vertical; spire and roof planes never are.
        if (abs(n.y) < 0.01f) {
            // Gable ends: fish-scale shingles, a bargeboard along the rakes
            // and the gable's window.
            float rake = 1.0e9f;
            for (uint k = 0u; k < min(uint(part.upper.w), 4u); ++k) {
                float4 plane = part.planes[k];
                if (abs(plane.y) > 0.05f)
                    rake = min(rake, plane.w - dot(plane.xyz, p));
            }
            HouseWindow w = houseWindow(part, index, p, n, blur, wind);
            float edge = houseScales(float2(s, p.y), blur, tone);
            float3 shingle = paint * (0.85f + 0.3f * tone) * (1.0f - 0.45f * edge);
            if (rake < 0.35f) shingle = trim;
            return houseGlassPane(w, part, n, direction, p, time, shingle,
                trim, mood);
        }
        // Slate: scales laid along the slope, dusted with regolith.
        float3 across = length(n.xz) > 0.05f
            ? normalize(float3(n.z, 0.0f, -n.x)) : float3(1.0f, 0.0f, 0.0f);
        float3 up = cross(n, across);
        float edge = houseScales(float2(dot(p, across), dot(p, up)), blur,
            tone);
        float3 slate = float3(0.05f, 0.057f, 0.068f) * (0.75f + 0.5f * tone)
            * (1.0f - 0.5f * edge);
        float dust = smoothstep(0.5f, 0.85f, smoothNoise(p.xz * 0.9f + p.y));
        slate = mix(slate, float3(0.1f, 0.096f, 0.09f), 0.45f * dust);
        return {slate, 0.55f, 0.0f, float3(0.0f)};
    }

    if (style == houseTrim || style == houseRailing || style == houseFrieze) {
        float3 size = part.upper.xyz - part.lower.xyz;
        // Weathered paint: grain shows through, worn to grey on edges and
        // in patches.
        float2 grainAt = abs(n.y) > 0.5f ? p.xz : float2(s, p.y);
        float grain = 0.8f + 0.2f * sin(grainAt.y * 23.0f + 7.0f
            * smoothNoise(grainAt * float2(2.0f, 0.5f)));
        float worn = smoothstep(0.58f, 0.72f, smoothNoise(grainAt * 2.1f
            + float2(index)));
        float3 albedo = mix(trim * (0.8f + 0.4f * smoothNoise(float2(s * 3.0f,
            p.y * 0.4f))), float3(0.12f, 0.11f, 0.1f) * grain, worn);
        // The open doors carry three raised panels.
        if (size.y > 2.0f * houseScale && size.x < 0.1f * houseScale
            && abs(n.x) > 0.5f) {
            float2 d = float2(p.z - part.lower.z, p.y - part.lower.y);
            float panel = max(houseLines(d.x - 0.12f, size.z - 0.24f, 0.04f,
                blur), houseLines(d.y - 0.12f, (size.y - 0.24f) / 3.0f, 0.04f,
                blur));
            albedo *= 1.0f - 0.45f * panel;
        }
        return {albedo, 0.6f, 0.0f, float3(0.0f)};
    }

    if (style == houseStone) {
        if (n.y > 0.5f) {
            bool deck = local.z < -6.15f || (abs(local.x) < 8.15f
                && abs(local.z) < 6.15f);
            if (inside || (deck && local.y > 0.05f)) {
                // Floor and deck boards, staggered at their ends. Outside
                // they are warped and grey, with uneven gaps and the odd
                // board rotted through.
                float across = metres.x + (inside ? 0.0f
                    : 0.02f * sin(metres.z * 0.7f + floor(metres.x / 0.15f)));
                float plank = floor(across / 0.15f);
                float run = metres.z + 2.4f * hashTile(float2(plank, 3.0f));
                float pick = hashTile(float2(plank, floor(run / 2.4f)));
                float joint = max(houseLines(across, 0.15f,
                    inside ? 0.008f : 0.01f + 0.02f * pick, blur),
                    houseLines(run, 2.4f, 0.008f, blur));
                float tone = 0.8f + 0.4f * pick;
                float3 wood = inside ? float3(0.09f, 0.055f, 0.034f)
                    : float3(0.07f, 0.064f, 0.058f);
                float3 albedo = wood * tone * (1.0f - 0.6f * joint);
                float roughness = inside ? 0.45f : 0.8f;
                if (!inside) {
                    albedo *= 0.8f + 0.2f * sin(run * 31.0f + 5.0f
                        * smoothNoise(float2(across * 4.0f, run)));
                    if (pick > 0.96f) albedo = float3(0.008f);
                }
                // Stains: dark blots with tide lines where water dried,
                // and dust gathered toward the walls.
                float blot = smoothNoise(metres.xz * 0.55f + 3.0f)
                    + 0.5f * smoothNoise(metres.xz * 2.1f + 11.0f);
                float stain = smoothstep(0.98f, 1.06f, blot);
                float tide = 1.0f - smoothstep(0.0f, 0.025f,
                    abs(blot - 0.99f));
                albedo *= (1.0f - 0.5f * stain) * (1.0f - 0.3f * tide);
                roughness = mix(roughness, 0.9f, stain);
                if (inside) {
                    float2 wall = min(local.xz + float2(7.7f, 5.7f),
                        float2(7.7f, 5.7f) - local.xz) * houseScale;
                    float dust = 1.0f - smoothstep(0.0f, 0.9f,
                        min(wall.x, wall.y));
                    albedo = mix(albedo, float3(0.11f, 0.1f, 0.09f), 0.4f * dust);
                }
                // A long runner rug down the hall.
                float2 rug = abs(local.xz - float2(0.0f, -2.0f))
                    - float2(1.25f, 2.9f);
                if (inside && max(rug.x, rug.y) < 0.0f) {
                    float border = smoothstep(-0.2f, -0.17f, max(rug.x, rug.y));
                    float line = 1.0f - smoothstep(0.012f,
                        0.012f + blur / houseScale,
                        abs(max(rug.x, rug.y) + 0.24f));
                    float medallion = smoothstep(0.25f, 0.2f,
                        abs(length(local.xz - float2(0.0f, -2.0f)) - 0.6f));
                    albedo = mix(float3(0.17f, 0.022f, 0.028f),
                        float3(0.06f, 0.01f, 0.012f), border);
                    albedo = mix(albedo, float3(0.3f, 0.2f, 0.07f),
                        max(line, medallion * 0.5f));
                    // Worn bare down the middle, with old dark stains.
                    float wear = (1.0f - smoothstep(0.1f, 0.6f,
                        abs(local.x))) * smoothNoise(metres.xz * 1.3f);
                    albedo = mix(albedo, float3(0.12f, 0.08f, 0.06f),
                        0.5f * wear);
                    float spill = smoothstep(1.1f, 1.16f,
                        smoothNoise(metres.xz * 0.9f + 27.0f)
                        + 0.5f * smoothNoise(metres.xz * 3.0f));
                    albedo = mix(albedo, float3(0.035f, 0.006f, 0.005f),
                        0.85f * spill);
                    roughness = 0.95f;
                }
                return {albedo, roughness, 0.0f, float3(0.0f)};
            }
        }
        // Coursed stone; the porch skirt under the deck is lattice.
        if (local.z < -6.2f && local.y < houseFloorY - 0.05f
            && abs(local.x) > houseStepHalfWidth + 0.01f && abs(n.y) < 0.5f) {
            float a = houseLines(s + p.y, 0.16f, 0.03f, blur);
            float b = houseLines(s - p.y, 0.16f, 0.03f, blur);
            return {mix(float3(0.006f), trim, max(a, b)), 0.7f, 0.0f,
                float3(0.0f)};
        }
        float course = floor(p.y / 0.3f);
        float along = s + fmod(abs(course), 2.0f) * 0.28f;
        float mortar = max(houseLines(p.y, 0.3f, 0.02f, blur),
            houseLines(along, 0.56f, 0.02f, blur));
        float tone = 0.75f + 0.5f * hashTile(float2(floor(along / 0.56f),
            course));
        float3 stone = float3(0.115f, 0.11f, 0.104f) * tone;
        return {mix(stone, float3(0.04f), mortar), 0.9f, 0.0f, float3(0.0f)};
    }

    if (style == houseBrick) {
        float storeyY = local.y - houseFloorY;
        if (inside && n.x > 0.5f) {
            // The firebox: an arched opening with a stone surround, logs on
            // glowing embers, and tongues of flame that lick upward, yellow
            // at their roots and red at their tips.
            float2 q = float2(local.z, storeyY);
            float arch = q.y < 0.6f ? 0.5f - abs(q.x)
                : 0.5f - length(float2(q.x, (q.y - 0.6f) * 2.0f));
            if (arch > -0.12f) {
                if (arch < 0.0f) return {float3(0.2f, 0.19f, 0.17f), 0.8f,
                    0.0f, float3(0.0f)};
                float lick = smoothNoise(float2(q.x * 9.0f,
                    q.y * 5.0f - time * 3.4f));
                float tongues = 0.5f + 0.5f * sin(q.x * 31.0f
                    + 2.0f * sin(q.y * 9.0f - time * 5.0f));
                float body = 1.0f - abs(q.x) / 0.42f;
                float heat = lick * 0.7f + tongues * 0.4f + 0.45f * body
                    - q.y / 0.5f;
                float flame = smoothstep(0.05f, 0.35f, heat);
                float3 tint = mix(float3(1.0f, 0.12f, 0.02f),
                    float3(1.0f, 0.62f, 0.2f), smoothstep(0.1f, 0.6f, heat));
                // A haunted fire goes out with the lamps, leaving its
                // embers, and flares up poison green with the glow.
                float4 glow = houseRoomGreen(mood, 1.0f, time);
                tint = mix(tint, glow.rgb * float3(0.7f, 1.0f, 0.6f) * glow.w,
                    mood.green);
                float burning = max(mood.dim, mood.green);
                float3 fire = tint * 0.8f * flame * burning;
                // Two crossed logs over a bed of embers.
                float log = min(abs(q.y - 0.09f - 0.12f * q.x),
                    abs(q.y - 0.09f + 0.12f * q.x));
                if (log < 0.045f && abs(q.x) < 0.36f) {
                    float crack = smoothstep(0.6f, 0.9f,
                        smoothNoise(float2(q.x * 30.0f, time * 0.7f)));
                    return {float3(0.02f, 0.012f, 0.008f), 0.9f, 0.0f,
                        float3(1.0f, 0.3f, 0.05f) * 0.6f * crack + fire * 0.3f};
                }
                float embers = (1.0f - smoothstep(0.0f, 0.06f, q.y))
                    * (0.5f + 0.5f * smoothNoise(float2(q.x * 25.0f,
                        time * 0.9f)));
                fire += mix(float3(1.0f, 0.25f, 0.05f),
                    glow.rgb * 0.6f * glow.w, mood.green) * 0.6f * embers
                    * (0.3f + 0.7f * burning);
                return {float3(0.01f), 1.0f, 0.0f, fire};
            }
        }
        float course = floor(p.y / 0.075f);
        float along = s + fmod(abs(course), 2.0f) * 0.115f;
        float mortar = max(houseLines(p.y, 0.075f, 0.012f, blur),
            houseLines(along, 0.23f, 0.012f, blur));
        float tone = 0.7f + 0.6f * hashTile(float2(floor(along / 0.23f),
            course + 50.0f));
        float3 brick = float3(0.13f, 0.05f, 0.034f) * tone;
        // Soot blackens the chimney tops.
        float soot = smoothstep(houseEavesY + 4.5f, houseEavesY + 6.3f,
            local.y);
        brick = mix(brick, float3(0.015f), soot * 0.8f);
        return {mix(brick, float3(0.06f, 0.055f, 0.05f), mortar), 0.85f, 0.0f,
            float3(0.0f)};
    }

    if (style == houseFurniture) {
        float3 size = part.upper.xyz - part.lower.xyz;
        float3 wood = float3(0.055f, 0.028f, 0.018f)
            * (0.85f + 0.3f * smoothNoise(float2(s * 6.0f, p.y * 1.5f)));
        // Stairs: a red runner up the treads and risers.
        if (abs(local.x) < 1.0f && local.z > houseStairStart - 0.01f
            && size.x > 1.5f) {
            if (abs(local.x) < 0.55f)
                return {float3(0.15f, 0.018f, 0.024f), 0.95f, 0.0f,
                    float3(0.0f)};
            return {wood, 0.4f, 0.0f, float3(0.0f)};
        }
        // The tall clock's face.
        if (size.y > 2.0f && n.x < -0.5f) {
            float2 q = float2(p.z - 0.5f * (part.lower.z + part.upper.z),
                p.y - part.lower.y - 1.75f);
            float r = length(q);
            if (r < 0.17f) {
                float angle = atan2(q.x, q.y);
                float hands = (abs(angle - 0.9f) < 0.06f && r < 0.13f)
                    || (abs(angle + 1.6f) < 0.08f && r < 0.09f) ? 1.0f : 0.0f;
                float ticks = step(0.14f, r) * step(0.9f,
                    abs(cos(angle * 6.0f)));
                return {mix(float3(0.5f, 0.46f, 0.36f), float3(0.02f),
                    max(hands, ticks)), 0.4f, 0.0f, float3(0.0f)};
            }
        }
        // The coffin: brass handles along its sides and a cross on the lid.
        if (part.upper.w > 3.5f) {
            float2 c = float2(p.x - (part.lower.x + part.upper.x) * 0.5f,
                p.z - part.lower.z - 1.45f);
            bool cross = n.y > 0.5f && ((abs(c.x) < 0.025f
                && abs(c.y) < 0.35f) || (abs(c.y - 0.12f) < 0.025f
                && abs(c.x) < 0.15f));
            float lift = p.y - part.lower.y;
            bool handle = n.y < 0.5f && abs(lift - 0.2f) < 0.025f
                && fract((p.z - part.lower.z) / 0.5f) < 0.5f;
            if (cross || handle)
                return {float3(0.5f, 0.36f, 0.12f), 0.3f, 1.0f, float3(0.0f)};
            return {wood * 0.7f, 0.3f, 0.0f, float3(0.0f)};
        }
        return {wood, 0.35f, 0.0f, float3(0.0f)};
    }

    if (style == houseLantern) {
        // Glass panes in an iron frame.
        float3 q = (p - part.lower.xyz) / (part.upper.xyz - part.lower.xyz);
        float2 face = abs(n.x) > 0.5f ? q.zy : q.xy;
        float2 rim = min(face, 1.0f - face);
        if (abs(n.y) > 0.5f || rim.x < 0.12f || rim.y < 0.1f)
            return {iron, 0.5f, 0.6f, float3(0.0f)};
        float level = houseFlicker(time, part.lower.x, 0.12f) * mood.dim;
        return {float3(0.05f, 0.04f, 0.03f), 0.2f, 0.0f,
            float3(1.0f, 0.62f, 0.28f) * 1.4f * level};
    }

    if (style == houseCandle) {
        float h = p.y - part.lower.y;
        float waxTop = part.upper.y - part.lower.y - 0.075f;
        float flicker = houseFlicker(time, part.lower.x * 7.0f, 0.25f)
            * mood.dim;
        if (h > waxTop) {
            float4 glow = houseRoomGreen(mood, float(houseRoom(p)), time);
            return {float3(0.0f), 1.0f, 0.0f,
                mix(mix(float3(1.0f, 0.75f, 0.35f), float3(1.0f, 0.4f, 0.1f),
                    saturate((h - waxTop) / 0.075f)) * flicker,
                    glow.rgb * glow.w, mood.green) * 3.0f};
        }
        // Wax glows warm where the flame shines through it, and drips.
        float drip = smoothstep(0.6f, 0.9f, smoothNoise(float2(
            atan2(n.z, n.x) * 3.0f, h * 20.0f)));
        return {float3(0.62f, 0.56f, 0.44f) * (0.85f + 0.15f * drip), 0.45f,
            0.0f, float3(1.0f, 0.6f, 0.25f) * 0.25f * flicker
                * smoothstep(waxTop - 0.06f, waxTop, h)};
    }

    // Iron fence and cresting.
    return {iron, 0.45f, 0.6f, float3(0.0f)};
}

// ------------------------------------------------------------------ ground

// The flagstone path from the base exit to the porch steps, as on the path
// (0 or 1), stone coverage against the grout, and a tone per stone.
float3 housePath(float2 p, float blur) {
    float2 metres = p - houseOrigin.xz;
    float stepsFront = (housePorchFront
        - houseStepRun * float(houseStepCount)) * houseScale;
    float edge = 1.6f + 0.15f * smoothNoise(p * 1.7f);
    if (abs(metres.x) > edge || p.y < hullSouth + 0.3f
        || metres.y > stepsFront + 0.05f) return float3(0.0f);
    // Uneven stones: each row is offset, each stone its own size.
    float row = floor(metres.y / 0.5f);
    float2 cell = float2(metres.x / 0.62f + 0.5f * fmod(abs(row), 2.0f)
        + 0.3f * hashTile(float2(row, 5.0f)), metres.y / 0.5f);
    float2 f = abs(fract(cell) - 0.5f) * float2(0.62f, 0.5f);
    float2 shrink = 0.04f * float2(hashTile(floor(cell) + 11.0f),
        hashTile(floor(cell) + 23.0f));
    float grout = max(f.x - 0.29f + shrink.x, f.y - 0.23f + shrink.y);
    return float3(1.0f, 1.0f - smoothstep(-blur, blur, grout),
        hashTile(floor(cell)));
}

// Dug earth over each standing grave, 0 to 1: a plot in front of its
// marker with a ragged edge.
float houseGraveSoil(float2 p) {
    float2 local = houseLocal(p);
    if (any(local < houseLotLower) || any(local > houseLotUpper)) return 0.0f;
    float plot = 0.0f;
    float ragged = 0.04f * (smoothNoise(p * 9.0f) - 0.5f);
    for (uint i = 0u; i < houseGraveCount; ++i) {
        HouseGrave grave = houseGraves[i];
        if (grave.kind == houseGraveFallen || grave.kind == houseGraveTomb)
            continue;
        float2 face = houseGraveFace(grave.facing).xz;
        float2 offset = (local - grave.at) * houseScale;
        float along = dot(offset, face) - 1.15f;
        float across = dot(offset, float2(-face.y, face.x));
        float edge = max(abs(across) - 0.45f, abs(along) - 0.95f) + ragged;
        plot = max(plot, 1.0f - smoothstep(-0.05f, 0.03f, edge));
    }
    return plot;
}

// ------------------------------------------------------------------- ghost

float houseSmoothMin(float a, float b, float k) {
    float h = saturate(0.5f + 0.5f * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0f - h);
}

// The ghost's sheet as a distance in metres from q, in its own frame: x to
// its right, y up from the centre of its head, z toward the player. The
// hem streams back and ripples as it flies, and two sleeves reach out.
float houseGhostShape(float3 q, float time) {
    float down = max(-q.y, 0.0f);
    q.z += 0.22f * down * down;
    q.x += 0.06f * sin(time * 2.3f + down * 2.5f) * down;
    float head = length(q * float3(1.0f, 0.92f, 1.0f)) - 0.3f;
    float spread = saturate(down / 1.55f);
    float angle = atan2(q.x, q.z);
    float radius = 0.27f + 0.3f * spread + 0.035f * spread
        * sin(angle * 6.0f + q.y * 3.0f - time * 4.0f);
    float hem = -1.55f + 0.14f * sin(angle * 5.0f + time * 5.0f)
        + 0.07f * sin(angle * 11.0f - time * 8.0f);
    float body = max(max(length(q.xz) - radius, hem - q.y), q.y - 0.05f);
    float3 arm = float3(abs(q.x), q.y, q.z);
    const float3 shoulder = float3(0.24f, -0.42f, 0.05f);
    float3 reach = float3(0.3f, -0.3f + 0.05f * sin(time * 3.0f), 0.62f)
        - shoulder;
    float h = saturate(dot(arm - shoulder, reach) / dot(reach, reach));
    float sleeve = length(arm - shoulder - reach * h) - mix(0.11f, 0.05f, h);
    return houseSmoothMin(houseSmoothMin(head, body, 0.14f), sleeve, 0.08f);
}

// Draws the ghost over what lies within limit along the ray: a pale green
// sheet you can see through, thicker at its edges, with black hollow eyes
// and a gaping mouth, in a faint glow. From inside it, the view fogs green.
float3 houseGhostOverlay(float3 color, float3 origin, float3 direction,
    float limit, device const GameState &game) {
    float fade = houseGhostFade(game);
    if (fade <= 0.0f) return color;
    float time = game.effects.x;
    float3 ghost = game.house.haunt.yzw
        + float3(0.0f, 0.07f * sin(time * 2.6f), 0.0f);
    float3 offset = origin - (ghost - float3(0.0f, 0.7f, 0.0f));
    float b = dot(offset, direction);
    float c = dot(offset, offset) - 1.8f * 1.8f;
    float discriminant = b * b - c;
    if (discriminant <= 0.0f) return color;
    float root = sqrt(discriminant);
    float t = max(-b - root, 0.0f), far = min(-b + root, limit);
    if (far <= t) return color;
    float2 toward = game.player.xz - ghost.xz;
    float2 front = dot(toward, toward) > 1.0e-4f ? normalize(toward)
        : float2(0.0f, -1.0f);
    float3 z = float3(front.x, 0.0f, front.y), x = float3(-front.y, 0.0f, front.x);
    float3 local = origin + direction * t - ghost;
    float3 q = float3(dot(local, x), local.y, dot(local, z));
    float3 heading = float3(dot(direction, x), direction.y, dot(direction, z));
    float d = houseGhostShape(q, time);
    if (d < 0.0f && t <= 0.0f)
        return mix(color, houseGhostGreen * 0.35f, 0.45f * fade);
    float nearest = d;
    bool found = false;
    for (uint i = 0u; i < 48u && t < far; ++i) {
        if (d < 0.004f) {
            found = true;
            break;
        }
        float advance = max(d * 0.8f, 0.01f);
        t += advance;
        q += heading * advance;
        d = houseGhostShape(q, time);
        nearest = min(nearest, d);
    }
    float3 glow = houseGhostGreen * 0.12f * exp(-max(nearest, 0.0f) * 7.0f)
        * fade;
    if (!found) return color + glow;
    const float e = 0.01f;
    float3 normal = normalize(
        float3(1.0f, -1.0f, -1.0f) * houseGhostShape(q + float3(e, -e, -e), time)
        + float3(-1.0f, -1.0f, 1.0f) * houseGhostShape(q + float3(-e, -e, e), time)
        + float3(-1.0f, 1.0f, -1.0f) * houseGhostShape(q + float3(-e, e, -e), time)
        + float3(1.0f, 1.0f, 1.0f) * houseGhostShape(q + float3(e, e, e), time));
    float rim = 1.0f - abs(dot(normal, heading));
    rim *= rim;
    float eyes = length(float2(abs(q.x) - 0.1f, (q.y - 0.03f) * 0.8f)) - 0.062f;
    float mouth = length(float2(q.x, (q.y + 0.15f) * 0.55f)) - 0.055f
        - 0.015f * sin(time * 9.0f);
    float hollow = q.z > 0.0f
        ? 1.0f - smoothstep(-0.006f, 0.006f, min(eyes, mouth)) : 0.0f;
    float shimmer = 0.75f + 0.25f * smoothNoise(float2(q.x * 7.0f + time,
        q.y * 5.0f - time * 1.7f));
    float3 sheet = mix(float3(0.55f, 0.85f, 0.65f), houseGhostGreen, 0.45f)
        * (0.35f + 1.6f * rim) * shimmer;
    float alpha = fade * mix(0.3f + 0.55f * rim, 0.92f, hollow);
    return mix(color, mix(sheet, float3(0.0f, 0.01f, 0.0f), hollow), alpha)
        + glow;
}

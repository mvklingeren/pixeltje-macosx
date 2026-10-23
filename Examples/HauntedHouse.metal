// The haunted house for HauntedHouseProgram.metal: a Victorian house on a
// levelled, fenced lot at the end of a flagstone path from the base exit.
//
// buildHouse runs once in the initialize pass and writes the house into the
// game buffer, as site 0 of the haunted buildings, from the parts of
// HauntedBuildingKit.metal: boxes, some cut by sloping planes into gables,
// hips, a mansard, spires and a tapered coffin. Shingles, windows,
// wallpaper and the rest are shaded onto those parts; the clapboards and
// battens are traced in relief on the walls' faces. The kit's timber
// generator lays real boards and logs: loose clapboards hanging from one
// nail, the grave crosses and the mantel log.
//
// All three floors are open. The ground floor has a hall, a parlour with a
// fireplace and a coffin, and a dining room; the first floor a gallery over
// the hall, a bedroom and a study; the mansard an attic under its slates,
// lit through its dormers. A staircase rises through the middle of the
// house: one wide flight climbs the hall to a half landing under a tall
// lancet window, two narrower flights turn back from it to the gallery, and
// from the gallery a flying flight crosses the stairwell to the attic. Oak
// treads carry a worn runner held by brass rods, and turned balusters,
// newels and pointed finials line every flight. A small graveyard of crosses,
// headstones and a tomb surrounds the house, and a large one lies on a
// fenced plot of its own on either side of the lot, before a mausoleum.
// Floors, steps, walls and graves for walking come from the same layout
// constants in straight-line code, so the spider and drone kernels that
// test walkability never loop over the parts. Spiders keep to the ground
// floor and the main flight; only the player climbs higher, and their
// footing and walls depend on how high their feet are.
//
// Shooting or punching any window, or knocking on the front doors, wakes the
// house: its lights go out, a wind rises and blows the curtains about, a
// poison green glow snaps on, and a ghost flies out of the front doors at
// you.

// ------------------------------------------------------------------ layout
// House-local coordinates: x across the facade, y up from the levelled lot,
// z from the front (negative, facing the base) to the back. One local unit
// is houseScale metres: the whole house, its lot, lamps and footing grow
// with it, while siding, slate and brick keep their real size.
constant float3 houseOrigin = float3(0.0f, -2.3f, 128.0f);
constant float houseScale = 2.0f;
constant float houseFloorY = 0.75f;      // ground floor boards and porch deck
constant float houseCeilingY = 4.15f;    // ground floor ceiling
constant float houseUpperFloorY = 4.35f; // first floor boards
constant float houseEavesY = 7.35f;      // first floor ceiling, top of its walls
constant float houseAtticFloorY = 7.45f; // attic boards
constant float houseAtticCeilingY = 9.75f; // attic ceiling, under the mansard's top
// Storeys part in the middle of the floors between them, so a ceiling
// belongs to the room under it and a floor to the room over it.
constant float houseFirstStoreyY = 0.5f * (houseCeilingY + houseUpperFloorY);
constant float houseAtticStoreyY = 0.5f * (houseEavesY + houseAtticFloorY);
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
// The staircase. Every flight shares one riser and one going. The main
// flight climbs the hall toward the back from houseStairStart to the half
// landing; the two returns climb from the landing back toward the front, on
// either side of it, and reach the first floor at houseStairStart, where the
// gallery ends. The attic flight rises from the gallery toward the back over
// the stairwell, through a hole in the attic floor. Tread k (from 1) of a
// flight stands k risers above the flight's foot.
constant float houseStairRun = 0.225f;
constant float houseStairRise = 0.1f;
constant float houseStairSlope = houseStairRise / houseStairRun;
constant uint houseStairCount = 17u;      // treads in each flight to the gallery
constant float houseStairStart = 0.675f;  // foot of the main flight
constant float houseLandingZ = 4.5f;      // front of the half landing
constant float houseLandingY = 2.55f;     // houseFloorY + 18 risers
constant float houseFlightHalfWidth = 1.0f;   // the main flight's treads
constant float2 houseReturnX = float2(1.2f, 2.2f); // |x| of a return's treads
constant float houseStringX = 1.12f;      // |x| where the returns' strings begin
constant uint houseAtticStairCount = 30u;
constant float houseAtticStairStart = -2.15f;
constant float houseAtticStairTop = 4.6f; // where the attic flight lands
constant float houseAtticFlightHalfWidth = 0.92f;
constant float2 houseAtticHole = float2(1.1f, 2.2f); // half width, front z
constant float houseSoffitDepth = 0.3f;   // the floating flights, measured up
constant float houseRailHeight = 0.5f;    // handrail over the nosings
// A walker steps onto anything up to houseStepUp above their feet and
// bumps into anything between that and houseHeadHeight.
constant float houseStepUp = 0.2f;
constant float houseHeadHeight = 0.9f;
constant float2 houseLotLower = float2(-15.0f, -17.0f);  // the fence
constant float2 houseLotUpper = float2(15.0f, 9.0f);
constant float houseGatePostX = 2.0f;
constant float housePlayerPad = 0.4f;
// The graveyard plots flank the lot and share its side fences: each is
// 18 units wide and as deep as the lot, so the levelled ground spans both.
constant float2 houseGroundLower = float2(-33.0f, -17.0f);
constant float2 houseGroundUpper = float2(33.0f, 9.0f);
constant float houseYardAisleX = 24.0f;   // |x| of each plot's gate and aisle
constant float houseYardGatePostX = 1.2f; // gate posts either side of it

float3 houseLocal(float3 world) {
    return (world - houseOrigin) / houseScale;
}

float2 houseLocal(float2 worldXZ) {
    return (worldXZ - houseOrigin.xz) / houseScale;
}

float3 houseWorld(float3 local) {
    return houseOrigin + local * houseScale;
}

// A front door leaf as a house-local part, hung on its jamb at the back of
// the doorway: side 0 is the west leaf, 1 the east. open runs from 0, shut
// against its neighbour, to 1, swung in to stand against the hall.
HousePart houseFrontDoor(uint side, float open) {
    float s = side == 0u ? 1.0f : -1.0f;
    return houseDoorLeaf(float3(-s * houseDoorHalfWidth, houseFloorY, -5.7f),
        float2(s, 0.0f), float2(0.0f, -1.0f),
        float3(houseDoorHalfWidth, houseDoorHeight, 0.06f),
        open * 0.5f * M_PI_F, houseTrim);
}

// The pressure plate under the front doors: an iron plate let into the
// floor over the threshold and the boards the leaves swing across, in
// house-local units. It stands a little proud of the floor until someone
// steps on it, then sinks almost flush.
constant float housePlateHalfWidth = houseDoorHalfWidth - 0.02f;
constant float2 housePlateZ = float2(-5.98f, -4.75f);

HousePart houseDoorPlate(bool pressed) {
    return houseBox(float3(-housePlateHalfWidth, houseFloorY - 0.01f,
            housePlateZ.x),
        float3(housePlateHalfWidth, houseFloorY + (pressed ? 0.003f : 0.012f),
            housePlateZ.y), houseCastIron);
}

// True where a body of radius pad, in metres, with its feet at the world
// point feet stands on the plate.
bool houseOnDoorPlate(float3 feet, float pad) {
    float3 local = houseLocal(feet);
    pad /= houseScale;
    return abs(local.x) < housePlateHalfWidth + pad
        && local.z > housePlateZ.x - pad && local.z < housePlateZ.y + pad
        && abs(local.y - houseFloorY) < 0.3f;
}

// A house-local part scaled into the world. Window sizes stay in local
// units; houseWindow measures in them.
HousePart houseWorldPart(HousePart part) {
    part.lower.xyz = houseWorld(part.lower.xyz);
    part.upper.xyz = houseWorld(part.upper.xyz);
    for (uint k = 0u; k < 4u; ++k)
        part.planes[k].w = part.planes[k].w * houseScale
            + dot(part.planes[k].xyz, houseOrigin);
    return part;
}

// Scales a house-local part into the world and adds it to the open group.
void addHousePart(device HouseModel &house, HousePart part) {
    addHouseWorldPart(house, houseWorldPart(part));
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

// ----------------------------------------------------------------- windows

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

// Windows with negative glow look into the house's real rooms: rays pass
// through their glass. The others are in solid parts and show a room shaded
// behind the pane.
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
    // A door leaf may stand at any angle; it is shaded flat.
    if (houseIsDoorLeaf(part)) return;
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
    // A batten's side lies inside the wall's box, where a shadow ray would
    // pass through the wall it starts in. It is lit from the face plane
    // instead, so a light behind the wall stays out.
    if (abs(dot(normal, across)) > 0.5f)
        hit.position += face * (into * t + 0.001f);
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

// The mansard leans in by one unit for every 3.2 it rises; the attic's
// slate walls are houseMansardDepth thick, measured level.
constant float houseMansardLean = 1.0f / 3.2f;
constant float houseMansardDepth = 0.3f;
constant float2 houseMansardReach = float2(8.45f, 6.45f); // at houseEavesY

// The outward direction of side 0 (front, -z), 1 (back, +z), 2 (west, -x)
// or 3 (east, +x).
float3 houseSideOut(uint side) {
    return side == 0u ? float3(0.0f, 0.0f, -1.0f)
        : (side == 1u ? float3(0.0f, 0.0f, 1.0f)
            : (side == 2u ? float3(-1.0f, 0.0f, 0.0f)
                : float3(1.0f, 0.0f, 0.0f)));
}

// One side of a hollow mansard ring as a sheet between heights height.x and
// height.y, from span.x to span.y along that side. Its outer face is the
// slope of a hip whose half extents at yRef are outer (x, z), leaning in by
// lean for each unit it rises; its inner face reaches inner at yRef and
// leans in by innerLean. An end that runs to a corner (mitre.x at the
// negative end, mitre.y at the positive) is mitred against the next side,
// so the sheets of a ring meet along its hips.
HousePart houseMansardSheet(uint side, float2 outer, float2 inner,
    float yRef, float lean, float innerLean, float2 height, float2 span,
    bool2 mitre, uint style) {
    const float3 up = float3(0.0f, 1.0f, 0.0f);
    float3 out = houseSideOut(side);
    bool alongX = side < 2u;
    float reach = alongX ? outer.y : outer.x;
    float depth = alongX ? inner.y : inner.x;
    float near = min(depth - innerLean * (height.x - yRef),
        depth - innerLean * (height.y - yRef));
    float far = max(reach - lean * (height.x - yRef),
        reach - lean * (height.y - yRef));
    float2 across = side == 0u || side == 2u ? float2(-far, -near)
        : float2(near, far);
    HousePart part = alongX
        ? houseBox(float3(span.x, height.x, across.x),
            float3(span.y, height.y, across.y), style)
        : houseBox(float3(across.x, height.x, span.x),
            float3(across.y, height.y, span.y), style);
    houseCut(part, out + up * lean, out * reach + up * yRef);
    houseCut(part, -(out + up * innerLean), out * depth + up * yRef);
    for (uint end = 0u; end < 2u; ++end) {
        if (!(end == 0u ? mitre.x : mitre.y)) continue;
        float s = end == 0u ? -1.0f : 1.0f;
        float3 next = alongX ? float3(s, 0.0f, 0.0f) : float3(0.0f, 0.0f, s);
        houseCut(part, next - out, next * (alongX ? outer.x : outer.y)
            + out * reach);
    }
    return part;
}

// A sheet of the attic's slate walls, from houseEavesY up to the attic
// ceiling unless height says otherwise. depth is how far its inner face
// lies inside the slope.
HousePart houseAtticWall(uint side, float2 span, bool2 mitre, float2 height,
    float depth) {
    return houseMansardSheet(side, houseMansardReach,
        houseMansardReach - depth, houseEavesY, houseMansardLean,
        houseMansardLean, height, span, mitre, houseRoof);
}

// The first floor's walls: clapboard over the belt course, with clear
// windows into the rooms, and the tall lancet window over the stair landing,
// which rises from the hall floor to the first floor ceiling.
void buildHouseUpperWalls(device HouseModel &house) {
    const float F = houseFloorY, C = houseCeilingY;
    const float L = houseUpperFloorY, U = houseEavesY;
    beginHouseGroup(house);
    // The windows' sills stay where the old solid storey had them.
    const float sill = C + 0.7f - L;
    HousePart walls[6] = {
        houseBox(float3(-8.0f, L, -6.0f), float3(-3.0f, U, -5.7f), houseSiding),
        houseBox(float3(3.0f, L, -6.0f), float3(8.0f, U, -5.7f), houseSiding),
        houseBox(float3(-8.0f, L, -5.7f), float3(-7.7f, U, 5.7f), houseSiding),
        houseBox(float3(7.7f, L, -5.7f), float3(8.0f, U, 5.7f), houseSiding),
        houseBox(float3(-8.0f, L, 5.7f), float3(-housePartitionX, U, 6.0f),
            houseSiding),
        houseBox(float3(housePartitionX, L, 5.7f), float3(8.0f, U, 6.0f),
            houseSiding)};
    const float3 faces[6] = {float3(0.0f, 0.0f, -1.0f),
        float3(0.0f, 0.0f, -1.0f), float3(-1.0f, 0.0f, 0.0f),
        float3(1.0f, 0.0f, 0.0f), float3(0.0f, 0.0f, 1.0f),
        float3(0.0f, 0.0f, 1.0f)};
    uint index[6];
    for (uint i = 0u; i < 6u; ++i) {
        bool side = i == 2u || i == 3u;
        houseWindows(walls[i], side ? float2(0.0f, 3.0f) : float2(1.0f, 0.0f),
            float2(1.05f, 2.0f), sill, 1.0f, 0.0f, -0.9f);
        index[i] = house.counts.x;
        addHousePart(house, walls[i]);
    }
    // The bay stands in front of the middle of the front wall.
    addHousePart(house, houseBox(float3(-3.0f, L, -6.0f),
        float3(3.0f, U, -5.7f), houseSiding));
    HousePart lancet = houseBox(float3(-housePartitionX, F, 5.7f),
        float3(housePartitionX, U, 6.0f), houseSiding);
    houseWindows(lancet, float2(1.0f, 0.0f), float2(1.3f, 3.5f),
        houseLandingY + 0.4f - F, 1.0f, 0.0f, -1.0f);
    addHousePart(house, lancet);
    // One loose clapboard on each face, clear of the porch roof, the belt
    // course and the mansard skirt.
    for (uint i = 0u; i < 6u; ++i)
        addLooseClapboards(house, index[i], faces[i],
            float2(i < 2u ? 4.6f : L + 0.3f, U - 0.3f) * houseScale,
            houseNoSkip, 1u);
    // The belt course rings the house over the floor between the storeys,
    // broken at the back by the lancet window.
    const float2 belt = float2(C + 0.0005f, C + 0.26f);
    addHousePart(house, houseBox(float3(-8.12f, belt.x, -6.12f),
        float3(8.12f, belt.y, -6.0f), houseTrim));
    addHousePart(house, houseBox(float3(-8.12f, belt.x, 6.0f),
        float3(-housePartitionX, belt.y, 6.12f), houseTrim));
    addHousePart(house, houseBox(float3(housePartitionX, belt.x, 6.0f),
        float3(8.12f, belt.y, 6.12f), houseTrim));
    addHousePart(house, houseBox(float3(-8.12f, belt.x, -6.0f),
        float3(-8.0f, belt.y, 6.0f), houseTrim));
    addHousePart(house, houseBox(float3(8.0f, belt.x, -6.0f),
        float3(8.12f, belt.y, 6.0f), houseTrim));
}

// A dormer's window bay through the attic's slate wall on side `side`: a
// clear window in its face, cheeks back to the attic wall, a floor and a
// gabled roof. centre is its middle along the side.
void addHouseDormer(device HouseModel &house, uint side, float centre) {
    const float U = houseEavesY;
    const float3 up = float3(0.0f, 1.0f, 0.0f);
    float3 out = houseSideOut(side);
    bool alongX = side < 2u;
    float s = side == 0u || side == 2u ? -1.0f : 1.0f;
    // Distances out from the middle of the house, and along the side.
    float face = alongX ? 6.75f : 8.75f;
    float back = (alongX ? houseMansardReach.y : houseMansardReach.x)
        - houseMansardDepth;
    // A box from `near` to `far` outward and from a to b along the side.
    float2 head = float2(U + 0.3f, U + 2.15f);
    HousePart front = alongX
        ? houseBox(float3(centre - 0.95f, head.x, -face),
            float3(centre + 0.95f, head.y, -face + 0.15f), houseBattens)
        : houseBox(float3(min(s * face, s * (face - 0.15f)), head.x,
            centre - 0.95f), float3(max(s * face, s * (face - 0.15f)),
            head.y, centre + 0.95f), houseBattens);
    houseWindows(front, alongX ? float2(1.0f, 0.0f) : float2(0.0f, 1.0f),
        float2(0.85f, 1.4f), 0.25f, 1.0f, 0.0f, -0.85f);
    addHousePart(house, front);
    float inner = alongX ? 5.4f : 7.4f;
    for (uint c = 0u; c < 2u; ++c) {
        float a = c == 0u ? centre - 0.95f : centre + 0.8f;
        float2 depth = float2(min(s * inner, s * (face - 0.15f)),
            max(s * inner, s * (face - 0.15f)));
        HousePart cheek = alongX
            ? houseBox(float3(a, head.x, depth.x), float3(a + 0.15f, head.y,
                depth.y), houseBattens)
            : houseBox(float3(depth.x, head.x, a), float3(depth.y, head.y,
                a + 0.15f), houseBattens);
        houseCut(cheek, -(out + up * houseMansardLean), out * back
            + up * U);
        addHousePart(house, cheek);
    }
    float2 sill = float2(min(s * (back - 0.15f), s * face),
        max(s * (back - 0.15f), s * face));
    addHousePart(house, alongX
        ? houseBox(float3(centre - 0.95f, U + 0.25f, sill.x),
            float3(centre + 0.95f, head.x, sill.y), houseFloor)
        : houseBox(float3(sill.x, U + 0.25f, centre - 0.95f),
            float3(sill.y, head.x, centre + 0.95f), houseFloor));
    // The roof stops at the attic wall, so it stays out of the attic.
    float2 roof = float2(min(s * (inner + 0.06f), s * (face + 0.2f)),
        max(s * (inner + 0.06f), s * (face + 0.2f)));
    addHousePart(house, alongX
        ? houseGable(float3(centre - 1.15f, head.y, roof.x),
            float3(centre + 1.15f, U + 3.3f, roof.y), true, houseRoof)
        : houseGable(float3(roof.x, head.y, centre - 1.15f),
            float3(roof.y, U + 3.3f, centre + 1.15f), false, houseRoof));
}

void buildHouseBody(device HouseModel &house) {
    const float U = houseEavesY, A = houseAtticCeilingY;
    const float depth = houseMansardDepth;
    beginHouseGroup(house);
    // A bell-cast mansard: a flared skirt under steep slopes, under a low
    // hip. The skirt and the slopes are hollow sheets around the attic, and
    // the slopes stop at its ceiling, where the solid crown of the hip
    // begins.
    for (uint side = 0u; side < 4u; ++side)
        addHousePart(house, houseMansardSheet(side, float2(8.85f, 6.85f),
            float2(8.0f, 6.0f), U - 0.25f, 0.55f / 0.6f, 0.0f,
            float2(U - 0.25f, U + 0.35f), float2(-8.85f, 8.85f),
            bool2(true), houseRoof));
    const float2 full = float2(U, A), below = float2(U, U + 0.3f);
    const float2 above = float2(U + 2.15f, A);
    // The front slope opens for two dormers. Behind the bay its inner face
    // stands deeper, so the bay stays inside the slates.
    addHousePart(house, houseAtticWall(0u, float2(-8.45f, -6.45f),
        bool2(true, false), full, depth));
    addHousePart(house, houseAtticWall(0u, float2(-4.55f, 4.55f), bool2(false),
        full, depth + 0.2f));
    addHousePart(house, houseAtticWall(0u, float2(6.45f, 8.45f),
        bool2(false, true), full, depth));
    for (uint i = 0u; i < 2u; ++i) {
        float2 span = i == 0u ? float2(-6.45f, -4.55f) : float2(4.55f, 6.45f);
        addHousePart(house, houseAtticWall(0u, span, bool2(false), below,
            depth));
        addHousePart(house, houseAtticWall(0u, span, bool2(false), above,
            depth));
    }
    addHousePart(house, houseAtticWall(1u, float2(-8.45f, 8.45f), bool2(true),
        full, depth));
    // The side slopes open for one dormer each.
    for (uint side = 2u; side < 4u; ++side) {
        addHousePart(house, houseAtticWall(side, float2(-6.45f, -0.95f),
            bool2(true, false), full, depth));
        addHousePart(house, houseAtticWall(side, float2(-0.95f, 0.95f),
            bool2(false), below, depth));
        addHousePart(house, houseAtticWall(side, float2(-0.95f, 0.95f),
            bool2(false), above, depth));
        addHousePart(house, houseAtticWall(side, float2(0.95f, 6.45f),
            bool2(false, true), full, depth));
    }
    HousePart crown = houseHip(float3(-8.45f, U, -6.45f),
        float3(8.45f, U + 3.2f, 6.45f), float2(1.0f), houseRoof);
    crown.lower.y = A;
    addHousePart(house, crown);
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
        houseCeilingY + 0.75f - (houseFloorY + 3.1f), 2.0f, 2.85f, 1.15f);
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
        addHouseDormer(house, 0u, s * 5.5f);
        addHouseDormer(house, side == 0u ? 2u : 3u, 0.0f);
        // Brick chimneys with stone caps rise from the attic floor through
        // the back of the roof.
        float c = s * 6.0f;
        addHousePart(house, houseBox(float3(c - 0.5f, U, 2.5f),
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
    // The walls rise through the floor between the storeys, to the first
    // floor's boards; the belt course covers the joint outside.
    const float F = houseFloorY, C = houseCeilingY, L = houseUpperFloorY;
    beginHouseGroup(house);
    HousePart fronts[2], walls[2];
    uint frontIndex[2], wallIndex[2], backIndex[2];
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        // The front wall either side of the double doorway.
        HousePart front = houseBox(
            float3(side == 0u ? -8.0f : houseDoorHalfWidth, F, -6.0f),
            float3(side == 0u ? -houseDoorHalfWidth : 8.0f, L, -5.7f),
            houseSiding);
        houseWindows(front, float2(2.0f, 0.0f), float2(1.1f, 2.2f), 0.85f,
            1.0f, 0.0f, -1.0f);
        frontIndex[side] = house.counts.x;
        fronts[side] = front;
        addHousePart(house, front);
        HousePart wall = houseBox(
            float3(side == 0u ? -8.0f : 7.7f, F, -5.7f),
            float3(side == 0u ? -7.7f : 8.0f, L, 5.7f), houseSiding);
        houseWindows(wall, float2(0.0f, 2.0f), float2(1.1f, 2.2f), 0.85f,
            1.0f, 0.0f, -1.0f);
        wallIndex[side] = house.counts.x;
        walls[side] = wall;
        addHousePart(house, wall);
        // The back wall either side of the stair's lancet window.
        HousePart back = houseBox(
            float3(side == 0u ? -8.0f : housePartitionX, F, 5.7f),
            float3(side == 0u ? -housePartitionX : 8.0f, L, 6.0f),
            houseSiding);
        houseWindows(back, float2(1.0f, 0.0f), float2(1.1f, 2.2f), 0.85f,
            1.0f, 0.0f, -0.8f);
        backIndex[side] = house.counts.x;
        addHousePart(house, back);
        // Each partition has a doorway toward the front of the house.
        float a = s * housePartitionX, b = s * (housePartitionX + 0.15f);
        float x0 = min(a, b), x1 = max(a, b);
        addHousePart(house, houseBox(float3(x0, F, -5.7f),
            float3(x1, L, houseInnerDoorZ.x), houseSiding));
        addHousePart(house, houseBox(float3(x0, F, houseInnerDoorZ.y),
            float3(x1, L, 5.7f), houseSiding));
        addHousePart(house, houseBox(
            float3(x0, F + houseInnerDoorHeight, houseInnerDoorZ.x),
            float3(x1, L, houseInnerDoorZ.y), houseSiding));
        // The front doors are shut until someone knocks;
        // buildingsHangDoors swings them open.
        house.doorParts[side] = house.counts.x;
        addHousePart(house, houseFrontDoor(side, 0.0f));
    }
    // The pressure plate under them holds them open while anyone stands
    // on it; buildingsHangDoors sinks it under their weight.
    house.doorParts.w = house.counts.x;
    addHousePart(house, houseDoorPlate(false));
    addHousePart(house, houseBox(float3(-houseDoorHalfWidth,
        F + houseDoorHeight, -6.0f), float3(houseDoorHalfWidth, L, -5.7f),
        houseSiding));
    // Loose clapboards hang on the ground floor walls; the porch roof
    // shelters the top of the front.
    float2 clad = float2(F + 0.1f, C - 0.08f) * houseScale;
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        addLooseClapboards(house, frontIndex[side], float3(0.0f, 0.0f, -1.0f),
            float2(F + 0.1f, F + 2.88f) * houseScale, houseNoSkip, 2u);
        addLooseClapboards(house, wallIndex[side], float3(s, 0.0f, 0.0f),
            clad, houseNoSkip, 3u);
        addLooseClapboards(house, backIndex[side], float3(0.0f, 0.0f, 1.0f),
            clad, houseNoSkip, 2u);
    }

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

// ---------------------------------------------------------------- staircase

// The band from a to b out from the middle of the house, on the west
// (s = -1) or east (s = 1) side.
float2 houseSideBand(float s, float a, float b) {
    return s < 0.0f ? float2(-b, -a) : float2(a, b);
}

// A tread of the staircase. Its runner lies down the flight's middle at x =
// centre, `runner` to either side, and the flight rises toward +z (rising
// 1) or toward -z (rising -1).
HousePart houseTread(float3 lower, float3 upper, float centre, float runner,
    float rising) {
    HousePart part = houseBox(lower, upper, houseStair);
    part.windows = float4(centre, runner, rising, 0.0f);
    return part;
}

// Keeps a raked part of a flight between two lines at the stairs' pitch:
// `top` and `bottom` above the line through the treads' front lower edges,
// which starts at foot (height, z) and rises toward +z (rising 1) or -z.
// The top plane is cut first.
void houseRake(thread HousePart &part, float rising, float2 foot, float top,
    float bottom) {
    const float k = houseStairSlope;
    houseCut(part, float3(0.0f, 1.0f, -rising * k),
        float3(0.0f, foot.x + top, foot.y));
    houseCut(part, float3(0.0f, -1.0f, rising * k),
        float3(0.0f, foot.x + bottom, foot.y));
}

// A newel post on the footprint from lower to upper (x, z), from height y0
// to y1, under a moulded cap and a pointed finial.
void addHouseNewel(device HouseModel &house, float2 lower, float2 upper,
    float y0, float y1) {
    addHousePart(house, houseBox(float3(lower.x, y0, lower.y),
        float3(upper.x, y1, upper.y), houseStair));
    addHousePart(house, houseBox(float3(lower.x - 0.02f, y1, lower.y - 0.02f),
        float3(upper.x + 0.02f, y1 + 0.05f, upper.y + 0.02f), houseStair));
    addHousePart(house, houseSpire(float3(lower.x + 0.01f, y1 + 0.05f,
        lower.y + 0.01f), float3(upper.x - 0.01f, y1 + 0.25f,
        upper.y - 0.01f), float2(0.0f), houseStair));
}

// A lantern on a rod from a ceiling at height y over (x, z).
void addHouseHangingLantern(device HouseModel &house, float2 at, float y) {
    addHousePart(house, houseBox(float3(at.x - 0.015f, y - 0.6f,
        at.y - 0.015f), float3(at.x + 0.015f, y, at.y + 0.015f), houseTrim));
    addHousePart(house, houseBox(float3(at.x - 0.16f, y - 1.02f,
        at.y - 0.16f), float3(at.x + 0.16f, y - 0.6f, at.y + 0.16f),
        houseLantern));
}

// From the hall to the gallery: the main flight's solid treads on the hall
// floor between closed strings, the half landing under the lancet window,
// and the two returns floating on soffits between the main flight and the
// partitions, with balustrades on their open sides.
void buildHouseStairs(device HouseModel &house) {
    const float F = houseFloorY, L = houseUpperFloorY;
    const float run = houseStairRun, rise = houseStairRise;
    const float S = houseStairStart, Z = houseLandingZ, Y = houseLandingY;
    const float D = houseSoffitDepth, rail = houseRailHeight;
    const float W = houseFlightHalfWidth;
    beginHouseGroup(house);
    for (uint k = 1u; k <= houseStairCount; ++k)
        addHousePart(house, houseTread(float3(-W, F, S + run * float(k - 1u)),
            float3(W, F + rise * float(k), S + run * float(k)), 0.0f, 0.62f,
            1.0f));
    addHousePart(house, houseBox(float3(-W, F, Z), float3(W, Y - D, 5.7f),
        houseStair));
    addHousePart(house, houseTread(float3(-housePartitionX, Y - D, Z),
        float3(housePartitionX, Y, 5.7f), 0.0f, 0.62f, 1.0f));
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        float2 band = houseSideBand(s, W, houseStringX);
        HousePart string = houseBox(float3(band.x, F, S),
            float3(band.y, Y + 0.2f, Z), houseStair);
        houseCut(string, float3(0.0f, 1.0f, -houseStairSlope),
            float3(0.0f, F + rise + 0.08f, S));
        addHousePart(house, string);
        float x = s * 0.5f * (W + houseStringX);
        HousePart rails = houseBox(float3(x - 0.025f, F + rise, S + 0.14f),
            float3(x + 0.025f, Y + rail + 0.2f, Z - 0.1f), houseBanister);
        houseRake(rails, 1.0f, float2(F, S), rise + rail, rise + 0.05f);
        addHousePart(house, rails);

        // The return on this side climbs back toward the front.
        band = houseSideBand(s, houseReturnX.x, houseReturnX.y);
        float centre = s * 0.5f * (houseReturnX.x + houseReturnX.y);
        for (uint k = 1u; k <= houseStairCount; ++k)
            addHousePart(house, houseTread(
                float3(band.x, Y + rise * float(k - 1u), Z - run * float(k)),
                float3(band.y, Y + rise * float(k), Z - run * float(k - 1u)),
                centre, 0.3f, -1.0f));
        HousePart soffit = houseBox(float3(band.x, Y - D - 0.01f, S),
            float3(band.y, L, Z), houseStair);
        houseRake(soffit, -1.0f, float2(Y, Z), 0.0f, -D);
        soffit.windows.w = 1.0f;
        addHousePart(house, soffit);
        band = houseSideBand(s, houseStringX, houseReturnX.x);
        string = houseBox(float3(band.x, Y - D - 0.01f, S),
            float3(band.y, L + 0.2f, Z), houseStair);
        houseRake(string, -1.0f, float2(Y, Z), rise + 0.08f, -D);
        addHousePart(house, string);
        x = s * 0.5f * (houseStringX + houseReturnX.x);
        rails = houseBox(float3(x - 0.025f, Y + rise, S + 0.1f),
            float3(x + 0.025f, L + rail + 0.2f, Z - 0.12f), houseBanister);
        houseRake(rails, -1.0f, float2(Y, Z), rise + rail, rise + 0.05f);
        addHousePart(house, rails);

        // Newels at the foot, at the landing, where the main flight's
        // string meets the return's, and at the gallery, where the post
        // hangs below the floor.
        band = houseSideBand(s, 0.98f, 1.14f);
        addHouseNewel(house, float2(band.x, S - 0.16f), float2(band.y, S),
            F, F + 0.8f);
        band = houseSideBand(s, 0.98f, 1.24f);
        addHouseNewel(house, float2(band.x, Z - 0.1f), float2(band.y,
            Z + 0.12f), F, Y + 0.75f);
        band = houseSideBand(s, 1.08f, 1.24f);
        addHouseNewel(house, float2(band.x, 0.6f), float2(band.y, 0.76f),
            Y - D + (Z - 0.76f) * houseStairSlope - 0.05f, L + 0.75f);
    }
    // Between the gallery newels a railing guards the gallery's edge, under
    // the attic flight.
    addHousePart(house, houseBox(float3(-1.08f, L, 0.65f),
        float3(1.08f, L + rail, 0.7f), houseBanister));
}

// The first floor: its boards around the stairwell, the partitions either
// side of the gallery with doorways over the ones below, a bedroom with a
// four-poster under a dust sheet, a study, and lanterns over the stairwell
// and in each room.
void buildHouseUpperRooms(device HouseModel &house) {
    const float C = houseCeilingY, L = houseUpperFloorY, U = houseEavesY;
    beginHouseGroup(house);
    addHousePart(house, houseBox(float3(-7.7f, C, -5.7f),
        float3(7.7f, L, houseStairStart), houseFloor));
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        float2 band = houseSideBand(s, housePartitionX, 7.7f);
        addHousePart(house, houseBox(float3(band.x, C, houseStairStart),
            float3(band.y, L, 5.7f), houseFloor));
        band = houseSideBand(s, housePartitionX, housePartitionX + 0.15f);
        addHousePart(house, houseBox(float3(band.x, L, -5.7f),
            float3(band.y, U, houseInnerDoorZ.x), houseSiding));
        addHousePart(house, houseBox(float3(band.x, L, houseInnerDoorZ.y),
            float3(band.y, U, 5.7f), houseSiding));
        addHousePart(house, houseBox(
            float3(band.x, L + houseInnerDoorHeight, houseInnerDoorZ.x),
            float3(band.y, U, houseInnerDoorZ.y), houseSiding));
    }
    // The bedroom: the bed's head against the west wall.
    const float3 bedAt = float3(-7.1f, L, 2.0f);
    HousePart sheet = houseBox(bedAt + float3(-1.06f, 0.1f, -0.99f),
        bedAt + float3(1.09f, 0.66f, 0.99f), houseFurniture);
    sheet.windows.x = 1.0f;
    addHouseProp(house, sheet, bedAt);
    addHouseProp(house, houseBox(bedAt + float3(-1.15f, 0.0f, -0.95f),
        bedAt + float3(-1.06f, 1.5f, 0.95f), houseFurniture), bedAt);
    for (uint i = 0u; i < 4u; ++i) {
        float2 c = float2((i & 1u) != 0u ? 1.06f : -1.1f,
            (i & 2u) != 0u ? 0.95f : -0.95f);
        addHouseProp(house, houseBox(bedAt + float3(c.x - 0.05f, 0.0f,
            c.y - 0.05f), bedAt + float3(c.x + 0.05f, 2.3f, c.y + 0.05f),
            houseFurniture), bedAt);
    }
    addHouseProp(house, houseBox(bedAt + float3(-1.15f, 2.22f, -1.0f),
        bedAt + float3(1.11f, 2.34f, 1.0f), houseFurniture), bedAt);
    const float3 wardrobeAt = float3(-2.95f, L, 5.7f);
    addHouseProp(house, houseBox(wardrobeAt + float3(-0.6f, 0.0f, -0.62f),
        wardrobeAt + float3(0.6f, 2.3f, 0.0f), houseFurniture), wardrobeAt);
    // The study: a desk under the front window, a bookcase and a shrouded
    // armchair.
    const float3 deskAt = float3(5.5f, L, -4.5f);
    addHouseProp(house, houseBox(deskAt + float3(-0.75f, 0.72f, -0.4f),
        deskAt + float3(0.75f, 0.78f, 0.4f), houseFurniture), deskAt);
    for (uint i = 0u; i < 2u; ++i) {
        float x = i == 0u ? -0.55f : 0.55f;
        addHouseProp(house, houseBox(deskAt + float3(x - 0.2f, 0.0f, -0.38f),
            deskAt + float3(x + 0.2f, 0.72f, 0.38f), houseFurniture), deskAt);
    }
    const float3 shelvesAt = float3(7.7f, L, 1.5f);
    HousePart shelves = houseBox(shelvesAt + float3(-0.38f, 0.0f, -0.9f),
        shelvesAt + float3(0.0f, 2.2f, 0.9f), houseFurniture);
    shelves.windows.x = 2.0f;
    addHouseProp(house, shelves, shelvesAt);
    const float3 chairAt = float3(4.8f, L, 2.6f);
    HousePart chair = houseBox(chairAt + float3(-0.45f, 0.0f, -0.42f),
        chairAt + float3(0.45f, 0.95f, 0.42f), houseFurniture);
    chair.windows.x = 1.0f;
    addHouseProp(house, chair, chairAt);
    const float2 lanterns[4] = {float2(-1.66f, 2.6f), float2(1.66f, 2.6f),
        float2(-5.0f, 0.0f), float2(5.0f, 0.0f)};
    for (uint i = 0u; i < 4u; ++i)
        addHouseHangingLantern(house, lanterns[i], U);
}

// The flying flight from the gallery to the attic, crossing the stairwell
// on its soffit between closed strings, with a balustrade on each side.
void buildHouseAtticStairs(device HouseModel &house) {
    const float L = houseUpperFloorY, U = houseEavesY;
    const float run = houseStairRun, rise = houseStairRise;
    const float S = houseAtticStairStart, T = houseAtticStairTop;
    const float D = houseSoffitDepth, rail = houseRailHeight;
    const float W = houseAtticFlightHalfWidth;
    beginHouseGroup(house);
    for (uint k = 1u; k <= houseAtticStairCount; ++k)
        addHousePart(house, houseTread(float3(-W, L + rise * float(k - 1u),
            S + run * float(k - 1u)), float3(W, L + rise * float(k),
            S + run * float(k)), 0.0f, 0.5f, 1.0f));
    HousePart soffit = houseBox(float3(-W, L + 0.001f, S), float3(W, U, T),
        houseStair);
    houseRake(soffit, 1.0f, float2(L, S), 0.0f, -D);
    soffit.windows.w = 1.0f;
    addHousePart(house, soffit);
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        float2 band = houseSideBand(s, W, 1.0f);
        HousePart string = houseBox(float3(band.x, L + 0.001f, S),
            float3(band.y, U + 0.25f, T), houseStair);
        houseRake(string, 1.0f, float2(L, S), rise + 0.08f, -D);
        addHousePart(house, string);
        float x = s * 0.96f;
        HousePart rails = houseBox(float3(x - 0.025f, L + rise, S + 0.14f),
            float3(x + 0.025f, houseAtticFloorY + rail + 0.2f, T - 0.06f),
            houseBanister);
        houseRake(rails, 1.0f, float2(L, S), rise + rail, rise + 0.05f);
        addHousePart(house, rails);
        band = houseSideBand(s, 0.9f, 1.06f);
        addHouseNewel(house, float2(band.x, S - 0.16f), float2(band.y, S),
            L, L + 0.8f);
        band = houseSideBand(s, 0.9f, 1.22f);
        addHouseNewel(house, float2(band.x, T - 0.08f), float2(band.y,
            T + 0.08f), U - 0.3f, houseAtticFloorY + 0.8f);
    }
}

// The attic: its boards around the stairwell, a railing round the
// stairwell, a lantern, and old trunks, a crate and shrouded furniture.
void buildHouseAttic(device HouseModel &house) {
    const float U = houseEavesY, L = houseAtticFloorY;
    const float rail = houseRailHeight;
    const float2 hole = houseAtticHole;
    const float back = houseAtticStairTop;
    beginHouseGroup(house);
    addHousePart(house, houseBox(float3(-8.15f, U, -6.15f),
        float3(8.15f, L, hole.y), houseFloor));
    addHousePart(house, houseBox(float3(-8.15f, U, back),
        float3(8.15f, L, 6.15f), houseFloor));
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        float2 band = houseSideBand(s, hole.x, 8.15f);
        addHousePart(house, houseBox(float3(band.x, U, hole.y),
            float3(band.y, L, back), houseFloor));
        float x = s * 1.13f;
        addHousePart(house, houseBox(float3(x - 0.025f, L, hole.y + 0.05f),
            float3(x + 0.025f, L + rail, back - 0.08f), houseBanister));
        band = houseSideBand(s, 1.06f, 1.2f);
        addHouseNewel(house, float2(band.x, hole.y - 0.1f),
            float2(band.y, hole.y + 0.04f), L, L + 0.75f);
    }
    addHousePart(house, houseBox(float3(-1.13f, L, hole.y - 0.055f),
        float3(1.13f, L + rail, hole.y - 0.005f), houseBanister));
    addHouseHangingLantern(house, float2(0.0f, -1.0f), houseAtticCeilingY);
    const float3 trunkAt = float3(-5.2f, L, 3.6f);
    addHouseProp(house, houseBox(trunkAt + float3(-0.45f, 0.0f, -0.28f),
        trunkAt + float3(0.45f, 0.5f, 0.28f), houseFurniture), trunkAt);
    const float3 chestAt = float3(-6.6f, L, -1.8f);
    addHouseProp(house, houseBox(chestAt + float3(-0.28f, 0.0f, -0.45f),
        chestAt + float3(0.28f, 0.45f, 0.45f), houseFurniture), chestAt);
    const float3 crateAt = float3(-3.2f, L, -4.6f);
    addHouseProp(house, houseBox(crateAt + float3(-0.35f, 0.0f, -0.35f),
        crateAt + float3(0.35f, 0.7f, 0.35f), houseFurniture), crateAt);
    const float3 tableAt = float3(4.6f, L, -2.6f);
    HousePart table = houseBox(tableAt + float3(-0.55f, 0.0f, -0.45f),
        tableAt + float3(0.55f, 1.05f, 0.45f), houseFurniture);
    table.windows.x = 1.0f;
    addHouseProp(house, table, tableAt);
    const float3 mirrorAt = float3(3.8f, L, 4.8f);
    HousePart mirror = houseBox(mirrorAt + float3(-0.3f, 0.0f, -0.25f),
        mirrorAt + float3(0.3f, 1.7f, 0.25f), houseFurniture);
    mirror.windows.x = 1.0f;
    addHouseProp(house, mirror, mirrorAt);
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
    float back = houseYardGatePostX + 0.25f;
    addHousePart(house, houseBox(float3(houseLotLower.x, base,
        houseLotUpper.y - 0.03f), float3(-back, top,
        houseLotUpper.y + 0.03f), houseIron));
    addHousePart(house, houseBox(float3(back, base, houseLotUpper.y - 0.03f),
        float3(houseLotUpper.x, top, houseLotUpper.y + 0.03f), houseIron));
    // A narrower gate in the back leads to the shed yard: plain posts, and
    // both leaves standing open against the lot.
    for (uint side = 0u; side < 2u; ++side) {
        float s = side == 0u ? -1.0f : 1.0f;
        float c = s * houseYardGatePostX, z = houseLotUpper.y;
        addHousePart(house, houseBox(float3(c - 0.25f, base, z - 0.25f),
            float3(c + 0.25f, 2.0f, z + 0.25f), houseStone));
        addHousePart(house, houseBox(float3(c - 0.32f, 2.0f, z - 0.32f),
            float3(c + 0.32f, 2.14f, z + 0.32f), houseStone));
        addHousePart(house, houseBox(float3(s * 0.9f - 0.03f, 0.02f,
            z - 1.17f), float3(s * 0.9f + 0.03f, 0.92f, z - 0.25f),
            houseIron));
    }
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

// --------------------------------------------------------- graveyard plots
// A large graveyard lies on a plot of its own west and east of the lot. Each
// is fenced in iron on its three open sides, with a gate in front between
// stone posts carrying lanterns and its two leaves swung open into the plot.
// An aisle runs from the gate to a mausoleum at the back, and graves stand
// in rows either side of it, all facing the front. They are set out on a
// grid of cells, one marker or none to a cell, whose kind, size, lean and
// offset come from a hash of the cell, so walking and the dug earth find a
// cell's grave by arithmetic rather than a loop. The mausoleum of
// HauntedMausoleum.metal takes the four cells either side of the aisle in
// the back two rows. Plot 0 is west and plot 1 east; a plot's columns run
// west to east, three either side of its aisle.
constant uint houseYardRows = 9u;
constant uint houseYardColumns = 6u;
constant uint houseYardBandRows = 3u;      // rows traced as one group
constant float houseYardFrontRow = -13.0f; // z of the front row's cells
constant float houseYardRowPitch = 2.5f;
constant float houseYardColumnPitch = 2.2f;
constant uint houseYardMausoleumRow = 7u;  // its first row
constant float houseYardMausoleumZ = 5.26f; // z of the foot of its doorway
constant uint houseGraveNone = 5u;         // an empty cell
constant uint houseGraveMausoleum = 6u;    // a cell under the mausoleum

float4 mausoleumFootprint();

struct HouseYardGrave {
    float2 at;      // house-local x and z of the foot
    uint kind;
    float lean;     // radians; the fallen cross's turn on the ground
    float2 size;    // 0 to 1, for its width and its height
};

float houseYardAisle(uint plot) {
    return plot == 0u ? -houseYardAisleX : houseYardAisleX;
}

HouseYardGrave houseYardGrave(uint plot, uint row, uint column) {
    float o = float(column) - 2.5f;
    float2 cell = float2(houseYardAisle(plot)
        + sign(o) * (abs(o) + 0.5f) * houseYardColumnPitch,
        houseYardFrontRow + float(row) * houseYardRowPitch);
    if (row >= houseYardMausoleumRow && (column == 2u || column == 3u))
        return {float2(houseYardAisle(plot), houseYardMausoleumZ),
            houseGraveMausoleum, 0.0f, float2(0.0f)};
    float seed = float(plot * 64u + row * houseYardColumns + column) * 1.37f
        + 211.0f;
    float pick = houseHash(seed);
    uint kind = pick < 0.08f ? houseGraveNone
        : (pick < 0.15f ? houseGraveFallen
            : (pick < 0.45f ? houseGraveCross
                : (pick < 0.75f ? houseGraveRound : houseGravePointed)));
    float2 shift = float2(0.5f, 0.4f)
        * (float2(houseHash(seed + 1.0f), houseHash(seed + 2.0f)) - 0.5f);
    float swing = houseHash(seed + 3.0f) - 0.5f;
    float lean = kind == houseGraveFallen ? 2.0f * rangePi * swing
        : swing * (kind == houseGraveCross ? 0.6f : 0.34f);
    return {cell + shift, kind, lean,
        float2(houseHash(seed + 4.0f), houseHash(seed + 5.0f))};
}

// The plot, row and column of the cell nearest a house-local point on a
// plot, its row found with z moved on by ahead.
uint3 houseYardCell(float2 local, float ahead) {
    uint plot = local.x < 0.0f ? 0u : 1u;
    float u = local.x - houseYardAisle(plot);
    float step = clamp(round(abs(u) / houseYardColumnPitch), 1.0f, 3.0f);
    uint column = u < 0.0f ? uint(3.0f - step) : uint(2.0f + step);
    float row = clamp(round((local.y + ahead - houseYardFrontRow)
        / houseYardRowPitch), 0.0f, float(houseYardRows - 1u));
    return uint3(plot, uint(row), column);
}

// The footprint a walker cannot enter, in house-local x/z as lower and
// upper corners, matching the parts addHouseYardGrave and the mausoleum
// make. An empty cell and a fallen cross, which can be stepped over, have
// none. Every cell under the mausoleum hands out its whole footprint, which
// stays a pad's width inside those cells.
float4 houseYardFootprint(HouseYardGrave grave) {
    if (grave.kind == houseGraveMausoleum) {
        float4 r = mausoleumFootprint() / houseScale;
        return float4(grave.at + r.xy, grave.at + r.zw);
    }
    if (grave.kind == houseGraveNone || grave.kind == houseGraveFallen)
        return float4(1.0e9f, 1.0e9f, -1.0e9f, -1.0e9f);
    float2 reach = grave.kind == houseGraveCross ? float2(0.16f, 0.06f)
        : float2(0.25f * (0.58f + 0.2f * grave.size.x) + 0.02f, 0.11f);
    return float4(grave.at - reach, grave.at + reach);
}

void addHouseYardGrave(device HouseModel &house, HouseYardGrave grave) {
    const float3 face = float3(0.0f, 0.0f, -1.0f);
    float3 ground = houseWorld(float3(grave.at.x, 0.0f, grave.at.y));
    if (grave.kind == houseGraveCross)
        addGraveCross(house, ground - float3(0.0f, 0.3f, 0.0f), face,
            1.25f + 0.35f * grave.size.y, grave.lean);
    else if (grave.kind == houseGraveFallen)
        addFallenCross(house, ground, grave.lean);
    else if (grave.kind == houseGraveRound || grave.kind == houseGravePointed)
        addHeadstone(house, ground - float3(0.0f, 0.2f, 0.0f), face,
            0.58f + 0.2f * grave.size.x, 0.95f + 0.3f * grave.size.y,
            grave.lean, grave.kind == houseGravePointed);
}

// A plot's fence and gate. The lot's side fence closes its inner side.
void buildHouseYardFence(device HouseModel &house, uint plot) {
    beginHouseGroup(house);
    const float top = 1.0f, base = -0.05f;
    float side = plot == 0u ? -1.0f : 1.0f;
    float inner = side * houseLotUpper.x, outer = side * houseGroundUpper.x;
    float west = min(inner, outer), east = max(inner, outer);
    float c = houseYardAisle(plot), gap = houseYardGatePostX + 0.25f;
    float front = houseGroundLower.y, back = houseGroundUpper.y;
    addHousePart(house, houseBox(float3(west, base, front - 0.03f),
        float3(c - gap, top, front + 0.03f), houseIron));
    addHousePart(house, houseBox(float3(c + gap, base, front - 0.03f),
        float3(east, top, front + 0.03f), houseIron));
    addHousePart(house, houseBox(float3(outer - 0.03f, base, front),
        float3(outer + 0.03f, top, back), houseIron));
    addHousePart(house, houseBox(float3(west, base, back - 0.03f),
        float3(east, top, back + 0.03f), houseIron));
    for (uint k = 0u; k < 2u; ++k) {
        float post = c + (k == 0u ? -1.0f : 1.0f) * houseYardGatePostX;
        addHousePart(house, houseBox(float3(post - 0.25f, base, front - 0.25f),
            float3(post + 0.25f, 2.0f, front + 0.25f), houseStone));
        addHousePart(house, houseBox(float3(post - 0.32f, 2.0f, front - 0.32f),
            float3(post + 0.32f, 2.14f, front + 0.32f), houseStone));
        addHousePart(house, houseBox(float3(post - 0.13f, 2.14f, front - 0.13f),
            float3(post + 0.13f, 2.56f, front + 0.13f), houseLantern));
        // The gate leaf hung on this post stands open against the plot.
        float leaf = c + (k == 0u ? -0.9f : 0.9f);
        addHousePart(house, houseBox(float3(leaf - 0.03f, 0.02f, front + 0.25f),
            float3(leaf + 0.03f, 0.92f, front + 1.17f), houseIron));
    }
}

// Each plot's fence, then its graves in bands of rows either side of the
// aisle, so a ray tests only the bands it passes over.
void buildHouseYards(device HouseModel &house) {
    for (uint plot = 0u; plot < 2u; ++plot) {
        buildHouseYardFence(house, plot);
        for (uint band = 0u; band < houseYardRows; band += houseYardBandRows)
            for (uint aisleSide = 0u; aisleSide < 2u; ++aisleSide) {
                beginHouseGroup(house);
                uint first = aisleSide * 3u;
                for (uint row = band; row < band + houseYardBandRows; ++row)
                    for (uint column = first; column < first + 3u; ++column)
                        addHouseYardGrave(house,
                            houseYardGrave(plot, row, column));
            }
    }
}

// The house, its lot and both graveyard plots, into the open site.
void buildHouse(device HouseModel &house) {
    house.activeBuilding = 1u;
    buildHouseBody(house);
    buildHouseUpperWalls(house);
    buildHouseRooms(house);
    buildHouseUpperRooms(house);
    buildHouseStairs(house);
    buildHouseAtticStairs(house);
    buildHouseAttic(house);
    buildHousePorch(house);
    house.activeBuilding = 0u;
    buildHouseFence(house);
    buildHouseGraveyard(house);
    buildHouseYards(house);
}

// ---------------------------------------------------------------- cut-outs

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

// Height of p over a balustrade's foot, and in `height` the balustrade's
// whole height there, in house-local units. A raked balustrade follows its
// flight between two cutting planes, its handrail's and then its foot's; a
// level one fills its box.
float houseBanisterHeight(device const HousePart &part, float3 p,
    thread float &height) {
    if (uint(part.upper.w) >= 2u) {
        float4 top = part.planes[0], foot = part.planes[1];
        float above = (foot.w - dot(foot.xyz, p)) / max(-foot.y, 1.0e-3f);
        float below = (top.w - dot(top.xyz, p)) / max(top.y, 1.0e-3f);
        height = (above + below) / houseScale;
        return above / houseScale;
    }
    height = (part.upper.y - part.lower.y) / houseScale;
    return (p.y - part.lower.y) / houseScale;
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
    if (style == houseBanister) {
        // Turned balusters, two to a tread, between a shoe rail and the
        // handrail: a vase over a slim neck, with a ring at each end.
        float height;
        h = houseBanisterHeight(part, p, height);
        if (h > height - 0.09f || h < 0.06f) return false;
        float cell = abs(fract(along / 0.1125f) - 0.5f) * 0.1125f;
        float t = saturate((h - 0.06f) / (height - 0.15f));
        float width = 0.011f + 0.009f * sin(t * rangePi)
            + 0.007f * exp(-(t - 0.3f) * (t - 0.3f) * 60.0f)
            + 0.006f * (exp(-t * t * 900.0f)
                + exp(-(t - 1.0f) * (t - 1.0f) * 900.0f));
        return cell > width;
    }
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

// Weight of the natural terrain: 0 on the lot and the graveyard plots and
// one unit beyond their fences, rising to 1 another 18 m out.
float houseLotBlend(float2 p) {
    float2 local = houseLocal(p);
    float2 outside = max(max(houseGroundLower - 1.0f - local,
        local - houseGroundUpper - 1.0f), float2(0.0f));
    return smoothstep(0.0f, 18.0f, length(outside) * houseScale);
}

// The flights in house-local units: the top of the tread over z, counting
// the floor or landing a flight arrives at as its last tread; the underside
// of a floating flight; and the top of the handrail beside it.
float houseMainFlightTop(float z) {
    float k = floor((z - houseStairStart) / houseStairRun) + 1.0f;
    return houseFloorY + houseStairRise
        * clamp(k, 1.0f, float(houseStairCount + 1u));
}

float houseMainRail(float z) {
    return houseFloorY + houseStairRise + houseRailHeight
        + (z - houseStairStart) * houseStairSlope;
}

float houseReturnTop(float z) {
    float k = floor((houseLandingZ - z) / houseStairRun) + 1.0f;
    return houseLandingY + houseStairRise
        * clamp(k, 1.0f, float(houseStairCount + 1u));
}

float houseReturnSoffit(float z) {
    return houseLandingY - houseSoffitDepth
        + (houseLandingZ - z) * houseStairSlope;
}

float houseReturnRail(float z) {
    return houseLandingY + houseStairRise + houseRailHeight
        + (houseLandingZ - z) * houseStairSlope;
}

float houseAtticFlightTop(float z) {
    float k = floor((z - houseAtticStairStart) / houseStairRun) + 1.0f;
    return houseUpperFloorY + houseStairRise
        * clamp(k, 1.0f, float(houseAtticStairCount + 1u));
}

float houseAtticFlightSoffit(float z) {
    return max(houseUpperFloorY, houseUpperFloorY - houseSoffitDepth
        + (z - houseAtticStairStart) * houseStairSlope);
}

float houseAtticRail(float z) {
    return houseUpperFloorY + houseStairRise + houseRailHeight
        + (z - houseAtticStairStart) * houseStairSlope;
}

// The floor, porch, steps, main flight and landing under p, or ground
// elsewhere: what a walker on the ground floor stands on.
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
    if (abs(local.x) < houseFlightHalfWidth && local.y >= houseStairStart)
        return houseOrigin.y + houseMainFlightTop(local.y) * houseScale;
    return floorY;
}

// Footprints the walker cannot enter, in house-local x/z: walls,
// partitions, door leaves, furniture, stair sides, porch posts and
// railings out to the deck edge, the sides of the steps, the gate posts, the
// fence, the back gate and the graves, then the plots' fences, gate posts
// and open gate leaves. Each matches a part buildHouse makes. The graves'
// footprints are listed here rather than read from houseGraves: a second
// loop in this test, which the spider kernels inline, made them take a
// minute to compile cold. The plots' graves are found by houseYardBlocked
// without one, and buildingsBlocked runs this table's loop for every site.
constant uint houseObstacleCount = 75u;
constant float4 houseObstacles[houseObstacleCount] = {
    float4(-8.0f, -6.0f, -0.9f, -5.7f), float4(0.9f, -6.0f, 8.0f, -5.7f),
    float4(-8.0f, 5.7f, 8.0f, 6.0f), float4(-8.0f, -6.0f, -7.7f, 6.0f),
    float4(7.7f, -6.0f, 8.0f, 6.0f),
    float4(-2.35f, -5.7f, -2.2f, -2.8f), float4(-2.35f, -0.8f, -2.2f, 5.7f),
    float4(2.2f, -5.7f, 2.35f, -2.8f), float4(2.2f, -0.8f, 2.35f, 5.7f),
    float4(-0.9f, -5.7f, -0.84f, -4.8f), float4(0.84f, -5.7f, 0.9f, -4.8f),
    float4(-7.7f, -1.25f, -6.95f, 1.25f), float4(-4.775f, 2.3f, -4.425f, 3.3f),
    float4(4.45f, -0.6f, 5.55f, 0.6f), float4(7.375f, 4.85f, 7.7f, 5.15f),
    float4(-1.12f, 0.675f, -1.0f, 4.62f), float4(1.0f, 0.675f, 1.12f, 4.62f),
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
    float4(-15.0f, 8.97f, -1.45f, 9.03f), float4(1.45f, 8.97f, 15.0f, 9.03f),
    float4(-1.45f, 8.75f, -0.95f, 9.25f), float4(0.95f, 8.75f, 1.45f, 9.25f),
    float4(-0.93f, 7.83f, -0.87f, 8.75f), float4(0.87f, 7.83f, 0.93f, 8.75f),
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
    float4(11.34f, 4.475f, 11.46f, 4.725f),
    // The west plot, then the east.
    float4(-33.0f, -17.03f, -25.45f, -16.97f),
    float4(-22.55f, -17.03f, -15.0f, -16.97f),
    float4(-33.03f, -17.0f, -32.97f, 9.0f), float4(-33.0f, 8.97f, -15.0f, 9.03f),
    float4(-25.45f, -17.25f, -24.95f, -16.75f),
    float4(-23.05f, -17.25f, -22.55f, -16.75f),
    float4(-24.93f, -16.75f, -24.87f, -15.83f),
    float4(-23.13f, -16.75f, -23.07f, -15.83f),
    float4(15.0f, -17.03f, 22.55f, -16.97f),
    float4(25.45f, -17.03f, 33.0f, -16.97f),
    float4(32.97f, -17.0f, 33.03f, 9.0f), float4(15.0f, 8.97f, 33.0f, 9.03f),
    float4(22.55f, -17.25f, 23.05f, -16.75f),
    float4(24.95f, -17.25f, 25.45f, -16.75f),
    float4(23.07f, -16.75f, 23.13f, -15.83f),
    float4(24.87f, -16.75f, 24.93f, -15.83f)
};

// True where the grave in the plot cell nearest a house-local point keeps
// the walker out. A footprint stays well inside its cell, so no neighbour
// can reach the point.
bool houseYardBlocked(float2 local, float pad) {
    uint3 cell = houseYardCell(local, 0.0f);
    float4 r = houseYardFootprint(houseYardGrave(cell.x, cell.y, cell.z));
    return all(local > r.xy - pad) && all(local < r.zw + pad);
}

// True where p, in world x and z, lies on the lot or the graveyard plots or
// within a unit of them.
bool houseGroundHolds(float2 p) {
    float2 local = houseLocal(p);
    return all(local >= houseGroundLower - 1.0f)
        && all(local <= houseGroundUpper + 1.0f);
}

// Inside the house's rooms: the ground and first floors between the hall
// floor and the first floor ceiling, the attic within its slate walls, and
// the dormers' window bays off it.
bool houseInteriorPoint(float3 p) {
    float3 local = houseLocal(p);
    float margin = 0.02f / houseScale;
    float2 a = abs(local.xz);
    if (a.x < 7.7f + margin && a.y < 5.7f + margin
        && local.y > houseFloorY - margin && local.y < houseEavesY + margin)
        return true;
    if (local.y < houseEavesY - margin
        || local.y > houseAtticCeilingY + margin) return false;
    float lean = (local.y - houseEavesY) * houseMansardLean;
    float2 wall = houseMansardReach - houseMansardDepth - lean + margin;
    if (a.x < wall.x && a.y < wall.y) return true;
    if (local.y < houseEavesY + 0.3f - margin
        || local.y > houseEavesY + 2.15f + margin) return false;
    return (abs(a.x - 5.5f) < 0.8f + margin && local.z < -5.4f
            && local.z > -6.6f - margin)
        || (a.y < 0.8f + margin && a.x > 7.4f && a.x < 8.6f + margin);
}

bool houseUnderRoof(float2 p) {
    float2 local = houseLocal(p);
    return abs(local.x) < 7.7f && abs(local.y) < 5.7f;
}

// Rooms by storey: 0 the hall, 1 the parlour, 2 the dining room; 3 the
// gallery and the stairwell over the hall, 4 the bedroom, 5 the study; 6
// the attic. A room's storey is its number over 3, and the halls (and the
// attic) are the multiples of 3.
uint houseRoom(float3 p) {
    float3 local = houseLocal(p);
    if (local.y >= houseAtticStoreyY) return 6u;
    uint storey = local.y < houseFirstStoreyY ? 0u : 3u;
    float x = local.x;
    return storey + (x < -housePartitionX - 0.075f ? 1u
        : (x > housePartitionX + 0.075f ? 2u : 0u));
}

// In the stairwell between the partitions, open from the hall floor to the
// first floor ceiling, or in the attic flight's hole through the floor over
// it.
bool houseInStairwell(float3 local) {
    return abs(local.x) < housePartitionX + 0.01f
        && local.z > houseStairStart - 0.01f && local.y < houseEavesY + 0.01f;
}

bool houseInAtticStairs(float3 local) {
    return abs(local.x) < houseAtticHole.x + 0.1f
        && local.z > houseAtticHole.y - 0.1f
        && local.z < houseAtticStairTop + 0.1f;
}

// How much of a lamp in room lightRoom reaches local, in room `room`. A
// room's own lamps light it fully, and a hall's lamps spill a little into
// the rooms beside it. Through the stairwell the halls of neighbouring
// storeys light each other.
float houseLightShare(uint lightRoom, uint room, float3 local) {
    if (lightRoom == room) return 1.0f;
    uint a = lightRoom / 3u, b = room / 3u;
    bool halls = lightRoom % 3u == 0u && room % 3u == 0u;
    if (a == b) return lightRoom % 3u == 0u || room % 3u == 0u ? 0.12f : 0.0f;
    if (!halls || max(a, b) - min(a, b) != 1u) return 0.0f;
    bool open = min(a, b) == 0u ? houseInStairwell(local)
        : houseInAtticStairs(local);
    return open ? 0.35f : 0.0f;
}

// The floor and ceiling heights of the storey around local: the stairwell
// is one storey from the hall floor to the first floor ceiling.
float2 houseStoreyBand(float3 local) {
    if (houseInStairwell(local)) return float2(houseFloorY, houseEavesY);
    if (local.y < houseFirstStoreyY)
        return float2(houseFloorY, houseCeilingY);
    if (local.y < houseAtticStoreyY)
        return float2(houseUpperFloorY, houseEavesY);
    return float2(houseAtticFloorY, houseAtticCeilingY);
}

// --------------------------------------------------------------- upstairs
// Only the player climbs above the ground floor. Their footing, walls and
// headroom inside the house's body depend on the height of their feet: a
// floor or tread is footing while it lies within houseStepUp of them, and a
// solid is in the way where it overlaps the band from there up to their
// head. The flights and floors are measured here from the layout; the
// walls, railings and furniture upstairs are listed in houseBlocks.

// The house's body, walls included, with a little room around it.
bool houseBodyHolds(float2 p) {
    float2 local = houseLocal(p);
    return abs(local.x) < 8.6f && abs(local.y) < 6.4f;
}

void houseOffer(thread float &best, float top, float reach) {
    if (top <= reach) best = max(best, top);
}

// What a walker at p with feet at foot stands on, in world height: the
// highest floor, tread or landing they can step onto. ground is the
// terrain's height.
float houseStandFrom(float2 p, float ground, float foot) {
    float stand = houseStand(p, ground);
    if (!houseBodyHolds(p)) return stand;
    float2 local = houseLocal(p);
    float x = abs(local.x), z = local.y;
    float reach = (foot - houseOrigin.y) / houseScale + houseStepUp;
    float best = (stand - houseOrigin.y) / houseScale;
    if (x <= housePartitionX && z >= houseLandingZ && z <= 5.7f)
        houseOffer(best, houseLandingY, reach);
    if (x >= houseStringX && x <= houseReturnX.y && z >= houseStairStart
        && z <= houseLandingZ)
        houseOffer(best, houseReturnTop(z), reach);
    if (x <= 7.7f && abs(z) <= 5.7f
        && (x >= housePartitionX || z <= houseStairStart))
        houseOffer(best, houseUpperFloorY, reach);
    if (x <= 1.0f && z >= houseAtticStairStart && z <= houseAtticStairTop)
        houseOffer(best, houseAtticFlightTop(z), reach);
    if (x <= 8.15f && abs(z) <= 6.15f && (x >= houseAtticHole.x
            || z <= houseAtticHole.y || z >= houseAtticStairTop))
        houseOffer(best, houseAtticFloorY, reach);
    return houseOrigin.y + best * houseScale;
}

// True when local lies within pad of the rectangle (x0, z0, x1, z1); q is
// the rectangle's nearest point.
bool houseNear(float2 local, float4 rect, float pad, thread float2 &q) {
    q = clamp(local, rect.xy, rect.zw);
    return all(abs(local - q) <= float2(pad));
}

// True when a solid from bottom to top overlaps a walker's band.
bool houseSpans(float bottom, float top, float2 band) {
    return top > band.x && bottom < band.y;
}

// True when a floor, flight, string or landing within pad of local is in
// the way of a walker whose body fills band (house-local heights). East
// and west mirror each other, so each side's parts are tested on the east.
bool houseStructureBlocks(float2 local, float pad, float2 band) {
    float2 q;
    const float S = houseStairStart, Z = houseLandingZ;
    const float T = houseAtticStairTop, R = houseAtticStairStart;
    const float W = houseAtticFlightHalfWidth;
    float2 east = float2(abs(local.x), local.y);
    // The main flight stands solid on the hall floor.
    if (houseNear(local, float4(-houseFlightHalfWidth, S,
            houseFlightHalfWidth, 5.7f), pad, q)
        && houseMainFlightTop(q.y) > band.x) return true;
    if (houseNear(local, float4(-housePartitionX, Z, housePartitionX, 5.7f),
            pad, q) && houseSpans(houseLandingY - houseSoffitDepth,
            houseLandingY, band)) return true;
    if (houseNear(east, float4(houseFlightHalfWidth, S, houseStringX, 4.62f),
            pad, q) && houseSpans(houseFloorY, houseMainRail(q.y), band))
        return true;
    // The returns, their strings and balustrades.
    if (houseNear(east, float4(houseStringX, S, houseReturnX.x, Z), pad, q)
        && houseSpans(houseReturnSoffit(q.y), houseReturnRail(q.y), band))
        return true;
    if (houseNear(east, float4(houseReturnX.x, S, houseReturnX.y, Z), pad, q)
        && houseSpans(houseReturnSoffit(q.y), houseReturnTop(q.y), band))
        return true;
    // The first floor around the stairwell.
    if ((houseNear(east, float4(0.0f, -5.7f, 7.7f, S), pad, q)
            || houseNear(east, float4(housePartitionX, S, 7.7f, 5.7f), pad, q))
        && houseSpans(houseCeilingY, houseUpperFloorY, band)) return true;
    // The attic flight, and its strings and balustrades.
    if (houseNear(local, float4(-W, R, W, T), pad, q)
        && houseSpans(houseAtticFlightSoffit(q.y), houseAtticFlightTop(q.y),
            band)) return true;
    if (houseNear(east, float4(W, R, 1.0f, T), pad, q)
        && houseSpans(houseAtticFlightSoffit(q.y), houseAtticRail(q.y), band))
        return true;
    // The attic floor around its stairwell, and the attic ceiling.
    if ((houseNear(east, float4(0.0f, -6.15f, 8.15f, houseAtticHole.y), pad, q)
            || houseNear(east, float4(0.0f, T, 8.15f, 6.15f), pad, q)
            || houseNear(east, float4(houseAtticHole.x, houseAtticHole.y,
                8.15f, T), pad, q))
        && houseSpans(houseEavesY, houseAtticFloorY, band)) return true;
    return houseNear(east, float4(0.0f, -6.3f, 8.3f, 6.3f), pad, q)
        && houseSpans(houseAtticCeilingY, houseAtticCeilingY + 10.0f, band);
}

// The upstairs walls, railings, newels and furniture as boxes, in
// house-local x/z and heights; each matches a part buildHouse makes.
struct HouseBlock {
    float4 rect;     // x0, z0, x1, z1
    float2 height;   // bottom, top
};

constant uint houseBlockCount = 40u;
constant HouseBlock houseBlocks[houseBlockCount] = {
    // The first floor's outer walls and partitions.
    {float4(-8.0f, -6.0f, 8.0f, -5.7f), float2(4.15f, 7.35f)},
    {float4(-8.0f, 5.7f, 8.0f, 6.0f), float2(4.15f, 7.35f)},
    {float4(-8.0f, -6.0f, -7.7f, 6.0f), float2(4.15f, 7.35f)},
    {float4(7.7f, -6.0f, 8.0f, 6.0f), float2(4.15f, 7.35f)},
    {float4(-2.35f, -5.7f, -2.2f, -2.8f), float2(4.15f, 7.35f)},
    {float4(-2.35f, -0.8f, -2.2f, 5.7f), float2(4.15f, 7.35f)},
    {float4(2.2f, -5.7f, 2.35f, -2.8f), float2(4.15f, 7.35f)},
    {float4(2.2f, -0.8f, 2.35f, 5.7f), float2(4.15f, 7.35f)},
    // The gallery's railing and the newels of the staircase.
    {float4(-1.08f, 0.62f, 1.08f, 0.73f), float2(4.35f, 4.85f)},
    {float4(-1.14f, 0.515f, -0.98f, 0.675f), float2(0.75f, 1.85f)},
    {float4(0.98f, 0.515f, 1.14f, 0.675f), float2(0.75f, 1.85f)},
    {float4(-1.24f, 4.4f, -0.98f, 4.62f), float2(0.75f, 3.6f)},
    {float4(0.98f, 4.4f, 1.24f, 4.62f), float2(0.75f, 3.6f)},
    {float4(-1.24f, 0.6f, -1.08f, 0.76f), float2(3.85f, 5.4f)},
    {float4(1.08f, 0.6f, 1.24f, 0.76f), float2(3.85f, 5.4f)},
    {float4(-1.06f, -2.31f, -0.9f, -2.15f), float2(4.35f, 5.45f)},
    {float4(0.9f, -2.31f, 1.06f, -2.15f), float2(4.35f, 5.45f)},
    // The bedroom's bed and wardrobe; the study's desk, bookcase and chair.
    {float4(-7.675f, 1.5f, -6.545f, 2.5f), float2(4.35f, 5.6f)},
    {float4(-3.25f, 5.39f, -2.65f, 5.7f), float2(4.35f, 5.5f)},
    {float4(5.125f, -4.7f, 5.875f, -4.3f), float2(4.35f, 4.75f)},
    {float4(7.51f, 1.05f, 7.7f, 1.95f), float2(4.35f, 5.45f)},
    {float4(4.575f, 2.39f, 5.025f, 2.81f), float2(4.35f, 4.85f)},
    // The attic's slate walls, kept clear of where they lean in.
    {float4(-8.3f, -6.3f, -7.75f, 6.3f), float2(7.35f, 9.75f)},
    {float4(7.75f, -6.3f, 8.3f, 6.3f), float2(7.35f, 9.75f)},
    {float4(-8.3f, -6.3f, 8.3f, -5.6f), float2(7.35f, 9.75f)},
    {float4(-8.3f, 5.75f, 8.3f, 6.3f), float2(7.35f, 9.75f)},
    // The railing round the attic stairwell, its newels and the attic
    // flight's top newels.
    {float4(-1.2f, 2.1f, -1.06f, 4.68f), float2(7.45f, 8.25f)},
    {float4(1.06f, 2.1f, 1.2f, 4.68f), float2(7.45f, 8.25f)},
    {float4(-1.2f, 2.1f, 1.2f, 2.24f), float2(7.45f, 8.25f)},
    {float4(-1.22f, 4.52f, -0.9f, 4.68f), float2(7.05f, 8.55f)},
    {float4(0.9f, 4.52f, 1.22f, 4.68f), float2(7.05f, 8.55f)},
    // The chimneys rise through the attic.
    {float4(-6.5f, 2.5f, -5.5f, 3.5f), float2(7.35f, 9.75f)},
    {float4(5.5f, 2.5f, 6.5f, 3.5f), float2(7.35f, 9.75f)},
    // Trunks, a crate and shrouded furniture in the attic.
    {float4(-5.425f, 3.46f, -4.975f, 3.74f), float2(7.45f, 7.7f)},
    {float4(-6.74f, -2.025f, -6.46f, -1.575f), float2(7.45f, 7.7f)},
    {float4(-3.375f, -4.775f, -3.025f, -4.425f), float2(7.45f, 7.8f)},
    {float4(4.325f, -2.825f, 4.875f, -2.375f), float2(7.45f, 7.98f)},
    {float4(3.65f, 4.675f, 3.95f, 4.925f), float2(7.45f, 8.3f)},
    // The lanterns over the stairwell hang clear of heads on the returns.
    {float4(-1.82f, 2.44f, -1.5f, 2.76f), float2(6.33f, 7.35f)},
    {float4(1.5f, 2.44f, 1.82f, 2.76f), float2(6.33f, 7.35f)}
};

bool houseBlocksBand(float2 local, float pad, float2 band) {
    for (uint i = 0u; i < houseBlockCount; ++i) {
        HouseBlock block = houseBlocks[i];
        if (all(local > block.rect.xy - pad) && all(local < block.rect.zw + pad)
            && houseSpans(block.height.x, block.height.y, band)) return true;
    }
    return false;
}

// True when something upstairs, on the staircase or in the attic keeps a
// walker at p with feet at foot out. The ground floor's walls and furniture
// are buildingsBlocked's.
bool houseBlockedAbove(float2 p, float foot) {
    float2 local = houseLocal(p);
    float h = (foot - houseOrigin.y) / houseScale;
    float2 band = float2(h + houseStepUp, h + houseHeadHeight);
    float pad = housePlayerPad / houseScale;
    return houseStructureBlocks(local, pad, band)
        || houseBlocksBand(local, pad, band);
}

void houseOfferCeiling(thread float &ceiling, float bottom, float above) {
    if (bottom >= above) ceiling = min(ceiling, bottom);
}

// The underside of the lowest floor, flight or landing over a walker at p
// with feet at foot, in world height; very high where there is none.
float houseCeilingOver(float2 p, float foot) {
    if (!houseBodyHolds(p)) return 1.0e9f;
    float2 local = houseLocal(p);
    float x = abs(local.x), z = local.y;
    float above = (foot - houseOrigin.y) / houseScale + 0.5f;
    float ceiling = 1.0e4f;
    if (x <= 7.7f && abs(z) <= 5.7f
        && (x >= housePartitionX || z <= houseStairStart))
        houseOfferCeiling(ceiling, houseCeilingY, above);
    if (x <= housePartitionX && z >= houseLandingZ && z <= 5.7f)
        houseOfferCeiling(ceiling, houseLandingY - houseSoffitDepth, above);
    if (x >= houseStringX && x <= houseReturnX.y && z >= houseStairStart
        && z <= houseLandingZ)
        houseOfferCeiling(ceiling, houseReturnSoffit(z), above);
    if (x <= 1.0f && z >= houseAtticStairStart && z <= houseAtticStairTop)
        houseOfferCeiling(ceiling, houseAtticFlightSoffit(z), above);
    if (x <= 8.15f && abs(z) <= 6.15f && (x >= houseAtticHole.x
            || z <= houseAtticHole.y || z >= houseAtticStairTop))
        houseOfferCeiling(ceiling, houseEavesY, above);
    if (x <= 8.3f && abs(z) <= 6.3f)
        houseOfferCeiling(ceiling, houseAtticCeilingY, above);
    return houseOrigin.y + ceiling * houseScale;
}

// ------------------------------------------------------------------ lights

// Five lights the outside: one on each gate post, one over the porch steps,
// and one for the pair of lanterns over each graveyard plot's gate.
constant uint houseOutdoorLightCount = 5u;

PointLight houseOutdoorLight(uint index, float time) {
    float3 position = index < 2u
        ? float3(index == 0u ? -houseGatePostX : houseGatePostX, 2.35f,
            houseLotLower.y)
        : (index == 2u ? float3(0.0f, houseFloorY + 2.57f, -8.2f)
            : float3(houseYardAisle(index - 3u), 2.35f, houseGroundLower.y));
    return {houseWorld(position), float3(1.0f, 0.6f, 0.27f),
        (index < 2u ? 55.0f : (index == 2u ? 75.0f : 110.0f))
            * houseScale * houseScale * houseFlicker(time, float(index), 0.12f),
        false};
}

// The hall lantern, the parlour fire and candles, the dining lantern; the
// two lanterns over the stairwell, the bedroom's and the study's; the
// attic's. Each lights its own room, and a little of the rooms
// houseLightShare opens onto it.
constant uint houseIndoorLightCount = 9u;

// Powers grow with the square of the scale, so the larger rooms are lit as
// brightly.
PointLight houseIndoorLight(uint index, float time, thread uint &room) {
    const float F = houseFloorY, area = houseScale * houseScale;
    const float U = houseEavesY;
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
    if (index == 3u) {
        room = 2u;
        return {houseWorld(float3(5.0f, houseCeilingY - 0.9f, 0.0f)),
            float3(1.0f, 0.66f, 0.34f), 200.0f * area * houseFlicker(time, 5.5f, 0.08f),
            false};
    }
    if (index < 6u) {
        room = 3u;
        float x = index == 4u ? -1.66f : 1.66f;
        return {houseWorld(float3(x, U - 0.85f, 2.6f)),
            float3(1.0f, 0.7f, 0.4f),
            150.0f * area * houseFlicker(time, 6.1f + x, 0.07f), false};
    }
    if (index < 8u) {
        room = index == 6u ? 4u : 5u;
        float x = index == 6u ? -5.0f : 5.0f;
        return {houseWorld(float3(x, U - 0.85f, 0.0f)),
            float3(1.0f, 0.64f, 0.32f),
            230.0f * area * houseFlicker(time, 7.7f + x, 0.09f), false};
    }
    room = 6u;
    return {houseWorld(float3(0.0f, houseAtticCeilingY - 0.85f, -1.0f)),
        float3(1.0f, 0.6f, 0.28f), 280.0f * area * houseFlicker(time, 9.3f, 0.14f),
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

// The ghost's own light, for surfaces on the same side of the walls:
// indoors while it is in the rooms, outdoors once it is out.
bool houseGhostLight(device const GameState &game, bool indoors,
    thread PointLight &light) {
    float fade = houseGhostFade(game);
    float3 ghost = game.house.haunt.yzw;
    if (fade <= 0.0f || houseInteriorPoint(ghost) != indoors) return false;
    bool angry = game.gesture.w > 0.5f;
    float3 color = angry ? float3(0.08f, 0.35f, 1.0f)
        : houseGhostGreen;
    light = {ghost - float3(0.0f, 0.5f, 0.0f), color,
        (indoors ? 260.0f : 420.0f) * fade * (angry ? 0.7f : 1.0f),
        false};
    return true;
}

// The house sleeps through the day. A shot through a window, a punch or a
// knock wakes it only once the afternoon is getting dark: from
// houseWakeAfter seconds after noon, when the sun has sunk about halfway
// and the plain has lost half its light. Without the day-night transition
// it is always night, and the house wakes at once.
constant float houseWakeAfter = 0.5f * dayNightDuration;

bool houseCanWake(device const GameState &game) {
    return !enableDayNightTransition || dayClock(game) >= houseWakeAfter;
}

// The ghost waits in the hall, at head height.
void houseWake(device GameState &game) {
    if (!houseCanWake(game)) return;
    // A fresh haunting can be taunted again. Earlier summoned bats keep
    // circling until the shotgun has cleared the entire raid.
    game.gesture = float4(0.0f, -100.0f, -100.0f, 0.0f);
    if (game.batRaid.x == 0u) game.batRaid.w = 0u;
    game.house.haunt = float4(game.effects.x,
        houseWorld(float3(0.0f, houseFloorY, -3.0f))
            + float3(0.0f, houseGhostHeight, 0.0f));
    game.house.hauntMotion = float4(0.0f, 0.0f, 0.0f, -1.0f);
}

void houseQuiet(device GameState &game) {
    game.house.haunt = float4(-100.0f, 0.0f, 0.0f, 0.0f);
    game.house.hauntMotion = float4(0.0f, 0.0f, 0.0f, -1.0f);
}

void traceBuildingGroups(thread SceneHit &hit, float3 origin,
    float3 direction, device const GameState &game, uint2 groups);
float buildingsGlassCrossing(float3 origin, float3 direction, float limit,
    device const GameState &game, thread float3 &normal,
    thread HouseWindow &pane);

// A shot that crosses a ground floor pane, or strikes one of the house's
// windows anywhere within its casing: its glass, curtains, sash or boards.
// Other buildings' windows leave it asleep.
bool houseShotHitsWindow(device const GameState &game, float3 origin,
    float3 direction, float limit) {
    float3 normal;
    HouseWindow pane;
    if (buildingsGlassCrossing(origin, direction, limit, game, normal, pane)
        > 0.0f) return true;
    SceneHit hit = {limit + 0.05f, float3(0.0f), float3(0.0f), 0u, -1, 0u};
    traceBuildingGroups(hit, origin, direction, game,
        game.house.sites[0].xy);
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

// The scare sound plays a moment after the shot, as the lamps die; the
// ghost's own looping voice follows it from when it emerges.
//
// Moves the ghost: out of the hall through the front doors to the foot of
// the porch steps, then straight at the player, gathering speed. It
// vanishes when it reaches them, with a jolt and the scare sound again.
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
    if (age >= houseLightsOut && age - dt < houseLightsOut) audio.scare = 1u;
    if (age < houseGhostEmerge) return;
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
    if (game.gesture.w > 0.5f) speed *= 1.35f;
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
    float3 lower, upper;
    if (room == 6u) {
        lower = float3(-7.9f, houseAtticFloorY, -5.9f);
        upper = float3(7.9f, houseAtticCeilingY, 5.9f);
    } else {
        uint side = room % 3u;
        float2 band = houseStoreyBand(local);
        lower = float3(side == 1u ? -7.7f : (side == 2u
            ? housePartitionX + 0.15f : -housePartitionX), band.x, -5.7f);
        upper = float3(side == 1u ? -housePartitionX - 0.15f
            : (side == 2u ? 7.7f : housePartitionX), band.y, 5.7f);
    }
    float3 below = local - lower;
    float3 above = upper - local;
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

// Old clapboards in metres, wide and 30 cm to the weather: butt joints fall
// at random, a few boards have split, rotted away or hang loose, paint has
// worn back to bare oak, and the boards are nailed near their ends and
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
    // Where the finish has worn away the bare oak's grain shows.
    float peel = smoothstep(0.6f, 0.68f, smoothNoise(float2(s * 1.9f,
        y * 2.7f + seed)) + 0.25f * smoothNoise(float2(s * 7.0f, y * 9.0f)));
    float grain = 0.85f + 0.15f * sin(s * 47.0f + 6.0f
        * smoothNoise(float2(s * 2.0f, cell.course)));
    wood = mix(wood, houseBareOak * grain * shade, peel);
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
            houseBareOak * grain, 0.7f * peel);
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
            houseBareOak * grain, peel) * shadow;
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

// Headstones, the tomb and the mausoleums, in metres. A headstone is grey
// or dark slate, streaked and blotched with lichen, dirty near the ground,
// and engraved with a cross over three lines of lettering. The tomb and the
// mausoleums are pale ashlar under stone roof slabs (the mausoleums'
// columns, entablature and pediment are plaster), with a worn inscription
// over the door, and their doorways are dark; a sick glow stirs
// in them while the house is haunted.
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
        // A line over the tomb's door, or the one a mausoleum's part
        // carries on its front: the -z face, or the +z face of a copy
        // turned about, which marks the line's part with a negative w.
        float centre = 0.5f * (part.lower.x + part.upper.x);
        bool carved = part.rows.z > 0.0f;
        float front = part.rows.w < -0.5f ? 1.0f : -1.0f;
        if (n.z * front > 0.9f && (carved || (part.upper.x - part.lower.x > 2.0f
                && height > 2.42f && height < 2.66f && part.rows.w > 0.5f)))
            stone *= 1.0f - 0.6f * houseLettering(float2(p.x - centre,
                carved ? p.y - part.lower.y - part.rows.x : height - 2.54f),
                carved ? part.rows.y : 0.8f, carved ? part.rows.z : 0.09f,
                seed, blur);
    } else if (n.y < 0.98f) {
        // Roof slabs, laid down the slope.
        stone *= 1.0f - 0.5f * houseLines(p.z, 0.5f, 0.015f, blur);
    }
    return {stone, 0.9f, 0.0f, float3(0.0f)};
}

// The rooms' walls, s along the wall and y above the floor in metres, in a
// storey `height` metres tall: a skirting board and panelled wainscot under
// a dado rail; damask paper with gilt rosettes on an ogee lattice, ochre in
// the hall and up the stairwell, oxblood in the parlour, bottle green in
// the dining room, faded rose in the bedroom and slate blue in the study;
// over the ceiling of a storey, a plaster band; a picture rail, a gilt
// palmette frieze and a dentilled plaster cornice. The paper is old: its
// seams are dark and some have lifted and curled back to the plaster, damp
// has stained it in tide marks, it is torn away to plaster and lath in
// places and spotted with mould low down, and pale patches show where
// pictures hung. On walls without windows crooked portraits still hang
// within span, their eyes lit green while the house is haunted.
SurfaceMaterial houseWallpaper(float s, float y, float height, uint room,
    float seed, bool portraits, float2 span, float blur, HouseHaunting mood,
    float time) {
    const float3 wood = float3(0.07f, 0.04f, 0.025f);
    const float3 plaster = float3(0.25f, 0.23f, 0.2f);
    const float3 gold = float3(0.3f, 0.21f, 0.075f);
    float3 ground = room == 1u ? float3(0.12f, 0.022f, 0.028f)
        : (room == 2u ? float3(0.028f, 0.062f, 0.042f)
            : (room == 4u ? float3(0.088f, 0.046f, 0.056f)
                : (room == 5u ? float3(0.026f, 0.046f, 0.064f)
                    : float3(0.105f, 0.072f, 0.034f))));
    float3 flock = ground * float3(0.42f, 0.36f, 0.4f);
    // Fine pattern fades to its mean once it is smaller than a pixel.
    float detail = saturate(1.0f - blur / 0.012f);
    if (y > height) return {plaster * 0.8f, 0.9f, 0.0f, float3(0.0f)};
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

// Floor and deck boards in metres, staggered at their ends. Outside they
// are warped, weathered oak, with uneven gaps and the odd board rotted
// through; the attic's are wide, rough and grey with dust. Dark blots with
// tide lines show where water dried, and dust gathers toward the walls.
SurfaceMaterial houseBoards(float3 metres, float3 local, float blur,
    bool inside, bool attic) {
    float width = attic ? 0.24f : 0.15f;
    float across = metres.x + (inside ? 0.0f
        : 0.02f * sin(metres.z * 0.7f + floor(metres.x / 0.15f)));
    float plank = floor(across / width);
    float run = metres.z + 2.4f * hashTile(float2(plank, 3.0f));
    float pick = hashTile(float2(plank, floor(run / 2.4f)));
    float joint = max(houseLines(across, width, inside
            ? (attic ? 0.012f : 0.008f) : 0.01f + 0.02f * pick, blur),
        houseLines(run, 2.4f, 0.008f, blur));
    float tone = 0.8f + 0.4f * pick;
    float3 wood = attic ? houseBareOak * 0.5f
        : (inside ? float3(0.09f, 0.055f, 0.034f) : houseBareOak * 0.55f);
    float3 albedo = wood * tone * (1.0f - 0.6f * joint);
    float roughness = attic ? 0.85f : (inside ? 0.45f : 0.8f);
    if (!inside || attic) {
        albedo *= 0.8f + 0.2f * sin(run * 31.0f + 5.0f
            * smoothNoise(float2(across * 4.0f, run)));
        if (!inside && pick > 0.96f) albedo = float3(0.008f);
    }
    float blot = smoothNoise(metres.xz * 0.55f + 3.0f)
        + 0.5f * smoothNoise(metres.xz * 2.1f + 11.0f);
    float stain = smoothstep(0.98f, 1.06f, blot);
    float tide = 1.0f - smoothstep(0.0f, 0.025f, abs(blot - 0.99f));
    albedo *= (1.0f - 0.5f * stain) * (1.0f - 0.3f * tide);
    roughness = mix(roughness, 0.9f, stain);
    if (inside) {
        float2 reach = attic ? float2(7.9f, 5.9f) : float2(7.7f, 5.7f);
        float2 wall = min(local.xz + reach, reach - local.xz) * houseScale;
        float dust = 1.0f - smoothstep(0.0f, 0.9f, min(wall.x, wall.y));
        albedo = mix(albedo, float3(0.11f, 0.1f, 0.09f),
            (attic ? 0.25f : 0.0f) + 0.4f * dust);
    }
    return {albedo, roughness, 0.0f, float3(0.0f)};
}

// The attic's bare timber, in metres: rough sawn sarking boards laid level
// across the rafters, which stand every 60 cm along its slate walls, or
// across the joists of its ceiling; grey with dust, stained where the
// slates let rain in, and hung with cobwebs high in its corners.
SurfaceMaterial houseAtticBoards(float3 p, float3 n, float blur,
    bool ceiling) {
    float3 metres = p - houseOrigin;
    float2 q = ceiling ? metres.xz
        : float2(abs(n.z) > abs(n.x) ? metres.x : metres.z, metres.y);
    float course = floor(q.y / 0.18f);
    float seam = houseLines(q.y, 0.18f, 0.012f, blur);
    float pick = hashTile(float2(course, floor((q.x + 3.0f
        * hashTile(float2(course, 7.0f))) / 3.2f)));
    float grain = 0.8f + 0.2f * sin(q.x * 31.0f + 5.0f
        * smoothNoise(float2(q.x * 0.7f, q.y * 9.0f)));
    float3 wood = houseBareOak * 0.5f * (0.75f + 0.5f * pick) * grain
        * (1.0f - 0.55f * seam);
    float rafter = 1.0f - smoothstep(0.04f, 0.04f + blur,
        abs(fract(q.x / 0.6f) - 0.5f) * 0.6f);
    wood = mix(wood, houseBareOak * 0.3f * grain, rafter);
    float dust = smoothstep(0.35f, 0.8f, smoothNoise(metres.xz * 0.8f
        + metres.y));
    wood = mix(wood, float3(0.075f, 0.07f, 0.064f), 0.35f * dust);
    float stain = smoothstep(1.0f, 1.1f, smoothNoise(q * 0.5f + 5.0f)
        + 0.4f * smoothNoise(q * 2.3f));
    wood *= 1.0f - 0.45f * stain;
    float high = 1.0f - smoothstep(0.0f, 0.9f,
        (houseAtticCeilingY - houseLocal(p).y) * houseScale);
    float web = high * smoothstep(0.55f, 0.8f, smoothNoise(q * 1.7f + 9.0f))
        * (0.6f + 0.4f * smoothNoise(q * 23.0f));
    wood = mix(wood, float3(0.16f, 0.16f, 0.15f), 0.5f * web);
    return {wood, 0.92f, 0.0f, float3(0.0f)};
}

// A floor between storeys, in metres: boards on top, a water-stained
// plaster ceiling below, and a beaded oak fascia where its edge shows in a
// stairwell. Outside, under a dormer's sill, it is painted trim.
SurfaceMaterial houseFloorMaterial(float3 p, float3 n, float3 local,
    float blur, bool inside) {
    float3 metres = p - houseOrigin;
    if (!inside)
        return {float3(0.045f, 0.038f, 0.034f), 0.7f, 0.0f, float3(0.0f)};
    if (n.y > 0.5f)
        return houseBoards(metres, local, blur, true,
            local.y > houseAtticStoreyY);
    if (n.y < -0.5f) {
        float stain = smoothstep(0.55f, 0.8f, smoothNoise(p.xz * 0.6f));
        return {float3(0.24f, 0.22f, 0.19f) * (1.0f - 0.3f * stain), 0.9f,
            0.0f, float3(0.0f)};
    }
    float bead = houseLines(metres.y, 0.1f, 0.012f, blur);
    return {houseOak * 0.85f * (1.0f - 0.35f * bead), 0.45f, 0.0f,
        float3(0.0f)};
}

// The staircase, in metres: dark oak polished by a century of hands and
// feet, paler where the treads' nosings wear. Down the treads runs a
// wine-red carpet with a black border, a gold line and a lozenge on every
// step, worn to its backing over the nosings and held at the back of each
// tread by a brass rod. Under the floating flights, plaster panels lie in
// oak frames.
SurfaceMaterial houseStairMaterial(device const HousePart &part, float3 p,
    float3 n, float blur) {
    float3 metres = p - houseOrigin;
    float3 size = part.upper.xyz - part.lower.xyz;
    bool longZ = size.z >= size.x;
    float u = longZ ? metres.z : metres.x;
    float v = abs(n.y) > 0.5f ? (longZ ? metres.x : metres.z) : metres.y;
    float grain = 0.82f + 0.18f * sin(v * 140.0f + 7.0f
        * smoothNoise(float2(u * 0.9f, v * 11.0f)));
    float3 oak = float3(0.062f, 0.032f, 0.017f) * grain
        * (0.85f + 0.3f * smoothNoise(float2(u * 0.4f, v * 3.0f)));
    if (part.windows.w > 0.5f) {
        // A soffit: its sides are the flight's strings.
        if (n.y > -0.2f) return {oak, 0.4f, 0.0f, float3(0.0f)};
        float side = 0.5f * size.x
            - abs(p.x - 0.5f * (part.lower.x + part.upper.x));
        float frame = max(1.0f - smoothstep(0.1f, 0.1f + blur, side),
            houseLines(metres.z * 1.094f, 1.2f, 0.14f, blur));
        float stain = smoothstep(0.55f, 0.85f,
            smoothNoise(float2(p.x, metres.z) * 0.7f));
        float3 plaster = float3(0.16f, 0.15f, 0.13f) * (1.0f - 0.3f * stain);
        return {mix(plaster, oak * 1.2f, frame), mix(0.9f, 0.45f, frame), 0.0f,
            float3(0.0f)};
    }
    float rising = part.windows.z;
    float runner = part.windows.y * houseScale;
    if (runner <= 0.0f || abs(rising) < 0.5f)
        return {oak, 0.38f, 0.0f, float3(0.0f)};
    float riseMetres = houseStairRise * houseScale;
    bool tread = n.y > 0.5f;
    bool riser = !tread && n.z * rising < -0.5f
        && p.y > part.upper.y - riseMetres - 0.002f;
    if (!tread && !riser) return {oak, 0.38f, 0.0f, float3(0.0f)};
    float across = metres.x - part.windows.x * houseScale;
    // Distances from the nosing, over the tread or down the riser, and
    // from the corner behind the tread, where the rod lies.
    float nose = tread
        ? (rising > 0.0f ? p.z - part.lower.z : part.upper.z - p.z)
        : part.upper.y - p.y;
    float back = tread
        ? (rising > 0.0f ? part.upper.z - p.z : p.z - part.lower.z)
        : p.y - (part.upper.y - riseMetres);
    float rod = 1.0f - smoothstep(0.009f, 0.009f + blur, abs(back - 0.02f));
    if (abs(across) < runner + 0.035f && rod > 0.5f)
        return {float3(0.42f, 0.3f, 0.12f) * (0.6f + 0.5f
            * smoothNoise(float2(across * 9.0f, u))), 0.35f, 1.0f,
            float3(0.0f)};
    if (abs(across) < runner) {
        float edge = runner - abs(across);
        // Up the flight, over treads and risers alike.
        float up = (rising > 0.0f ? metres.z : -metres.z) + metres.y;
        float3 carpet = float3(0.13f, 0.013f, 0.02f);
        float2 q = float2(abs(across) / max(runner - 0.1f, 0.05f),
            (fract(up / 0.65f) - 0.5f) * 0.65f / 0.22f);
        float lozenge = abs(q.x) + abs(q.y);
        float soft = 4.0f * blur / 0.22f;
        float motif = 1.0f - smoothstep(0.5f, 0.5f + soft, lozenge);
        float outline = 1.0f - smoothstep(0.035f, 0.035f + soft,
            abs(lozenge - 0.6f));
        carpet = mix(carpet, float3(0.03f, 0.008f, 0.01f), 0.8f * motif);
        carpet = mix(carpet, float3(0.24f, 0.15f, 0.05f), outline);
        float border = 1.0f - smoothstep(0.07f, 0.07f + blur, edge);
        float line = 1.0f - smoothstep(0.006f, 0.006f + blur,
            abs(edge - 0.085f));
        carpet = mix(carpet, float3(0.018f, 0.007f, 0.007f), border);
        carpet = mix(carpet, float3(0.26f, 0.17f, 0.05f), line);
        carpet *= 0.85f + 0.3f * mix(smoothNoise(float2(across, up) * 60.0f),
            0.5f, saturate(blur / 0.01f));
        float wear = (1.0f - smoothstep(0.0f, 0.1f, nose))
            * smoothstep(0.1f, 0.5f, edge / runner)
            * (0.55f + 0.45f * smoothNoise(float2(across * 6.0f, up * 3.0f)));
        carpet = mix(carpet, float3(0.085f, 0.068f, 0.05f), 0.75f * wear);
        if (tread)
            carpet = mix(carpet, float3(0.08f, 0.072f, 0.064f),
                0.35f * (1.0f - smoothstep(0.0f, 0.06f, back)));
        return {carpet, 0.95f, 0.0f, float3(0.0f)};
    }
    oak = mix(oak, houseBareOak * 0.75f,
        0.6f * (1.0f - smoothstep(0.0f, 0.05f, nose)));
    return {oak, 0.32f, 0.0f, float3(0.0f)};
}

// A balustrade's oak, in metres: a dark, polished handrail worn pale on
// top by hands, a shoe rail, and turned balusters ringed at their necks.
SurfaceMaterial houseBanisterMaterial(device const HousePart &part, float3 p,
    float3 n, float blur) {
    float height;
    float h = houseBanisterHeight(part, p, height);
    float3 metres = p - houseOrigin;
    float u = metres.x + metres.z;
    float grain = 0.82f + 0.18f * sin(metres.y * 60.0f + u * 3.0f
        + 6.0f * smoothNoise(float2(u * 2.0f, metres.y * 5.0f)));
    float3 oak = float3(0.06f, 0.031f, 0.017f) * grain;
    if (h > height - 0.09f) {
        float worn = saturate(n.y) * smoothNoise(float2(u * 1.5f, 3.0f));
        return {mix(oak * 0.85f, houseBareOak * 0.7f, 0.5f * worn), 0.22f,
            0.0f, float3(0.0f)};
    }
    if (h < 0.06f) return {oak * 0.9f, 0.35f, 0.0f, float3(0.0f)};
    float t = (h - 0.06f) / max(height - 0.15f, 0.05f);
    float rings = max(exp(-(t - 0.08f) * (t - 0.08f) * 2500.0f),
        exp(-(t - 0.92f) * (t - 0.92f) * 2500.0f));
    return {oak * (0.85f + 0.35f * rings), 0.3f, 0.0f, float3(0.0f)};
}

// A bookcase's face, in metres: shelves of old books, cloth and leather
// spines in dark reds, greens and browns with gilt bands, gapped here and
// there; the rest of it is wood.
SurfaceMaterial houseBookcase(device const HousePart &part, float3 p,
    float3 n, float blur, float3 wood) {
    float3 size = part.upper.xyz - part.lower.xyz;
    bool alongZ = size.z > size.x;
    SurfaceMaterial plain = {wood, 0.4f, 0.0f, float3(0.0f)};
    if (abs(alongZ ? n.x : n.z) < 0.5f) return plain;
    float s = alongZ ? p.z - part.lower.z : p.x - part.lower.x;
    float span = alongZ ? size.z : size.x;
    float y = p.y - part.lower.y;
    float shelf = floor(y / 0.36f);
    float inShelf = y - shelf * 0.36f - 0.03f;
    if (s < 0.04f || s > span - 0.04f || inShelf < 0.0f || y < 0.08f
        || y > size.y - 0.06f) return plain;
    float along = s + shelf * 0.17f;
    float cell = floor(along / 0.045f);
    float pick = hashTile(float2(cell, shelf + 11.0f));
    float tall = 0.2f + 0.11f * hashTile(float2(cell, shelf + 13.0f));
    if (pick < 0.08f || inShelf > tall)
        return {float3(0.008f), 0.9f, 0.0f, float3(0.0f)};
    float3 cloth = pick < 0.35f ? float3(0.07f, 0.012f, 0.012f)
        : (pick < 0.6f ? float3(0.02f, 0.04f, 0.022f)
            : (pick < 0.85f ? float3(0.06f, 0.035f, 0.018f)
                : float3(0.03f, 0.03f, 0.04f)));
    float top = tall - inShelf;
    float gilt = max(1.0f - smoothstep(0.004f, 0.004f + blur,
        abs(top - 0.03f)), 1.0f - smoothstep(0.004f, 0.004f + blur,
        abs(top - 0.05f)));
    cloth = mix(cloth, float3(0.2f, 0.14f, 0.05f), 0.7f * gilt);
    cloth *= 1.0f - 0.5f * houseLines(along, 0.045f, 0.004f, blur);
    return {cloth, 0.75f, 0.0f, float3(0.0f)};
}

// A dust sheet thrown over furniture, in metres: grey-white linen whose
// folds hang down its sides, greyer with dust on top.
SurfaceMaterial houseDustSheet(float3 p, float3 n) {
    float3 metres = p - houseOrigin;
    float s = metres.x + metres.z;
    float folds = abs(n.y) > 0.5f
        ? 0.9f + 0.1f * smoothNoise(metres.xz * 4.0f)
        : 0.72f + 0.28f * (0.5f + 0.5f * sin(s * 23.0f + 4.0f
            * smoothNoise(float2(s, metres.y) * 2.0f)));
    float3 linen = float3(0.2f, 0.195f, 0.18f) * folds;
    if (n.y > 0.5f) linen = mix(linen, float3(0.12f, 0.115f, 0.105f), 0.4f);
    return {linen, 0.95f, 0.0f, float3(0.0f)};
}

SurfaceMaterial houseSurfaceMaterial(SceneHit hit,
    device const GameState &game, float time, float pixelWidth,
    float3 direction, device const float4 *signFont) {
    bool buildingDebris = hit.variant >= houseCapacity
        && hit.variant < houseCapacity + buildingFragmentCount;
    bool masonryDebris = hit.variant >= houseCapacity + buildingFragmentCount;
    uint fragmentSlot = buildingDebris ? hit.variant - houseCapacity : 0u;
    uint masonrySlot = masonryDebris ? min(hit.variant - houseCapacity
        - buildingFragmentCount, masonryDebrisCount - 1u) : 0u;
    uint masonryPieceIndex = masonryDebris
        ? game.house.debrisParts[masonrySlot] : 0u;
    uint masonryPanel = masonryDebris ? min(uint(game.house.parts[
        masonryPieceIndex].windows.z), masonryPanelCount - 1u) : 0u;
    uint index = buildingDebris ? game.buildingFragmentSource[fragmentSlot]
        : masonryDebris ? game.house.masonryParts[masonryPanel]
        : min(hit.variant, houseCapacity - 1u);
    device const HousePart &part = game.house.parts[index];
    uint style = hit.material - houseMaterialBase;
    // A turned building is shaded in its own frame, where it was built.
    if (buildingDebris || masonryDebris) {
        uint bodyIndex = buildingDebris ? fragmentSlot
            : buildingFragmentCount + masonrySlot;
        pixeltje_physics::RigidBody body
            = game.physicsWorld.bodies[bodyIndex];
        device const HousePart &piece = buildingDebris
            ? game.buildingFragments[fragmentSlot]
            : game.house.parts[masonryPieceIndex];
        float3 originalCentre = 0.5f * (piece.lower.xyz + piece.upper.xyz);
        hit.position = originalCentre + pixeltje_physics::unrotate(
            body.orientation, hit.position - body.centreMass.xyz);
        hit.normal = pixeltje_physics::unrotate(body.orientation, hit.normal);
        direction = pixeltje_physics::unrotate(body.orientation, direction);
    } else {
        HouseTurn turn = housePartTurn(game.house, index);
        hit.position = houseTurnPointIn(turn, hit.position);
        hit.normal = houseTurnDirectionIn(turn, hit.normal);
        direction = houseTurnDirectionIn(turn, direction);
    }
    float3 p = hit.position, n = hit.normal;
    float3 local = houseLocal(p);
    float3 metres = p - houseOrigin;
    float blur = max(pixelWidth, 0.003f);
    bool inside = houseInteriorPoint(p);
    bool zFace = abs(n.z) > 0.5f;
    float s = zFace ? p.x : p.z;
    const float3 trim = float3(0.045f, 0.038f, 0.034f);
    const float3 paint = houseOak;
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
        if (houseIsDoorLeaf(part)) {
            // A plank door's boards run along it from the hinge, whichever
            // way it has swung.
            float2 span = houseDoorLeafSpan(part, p);
            s = span.x;
            lo = 0.0f;
            hi = span.y;
        }
        HouseWindow w = houseWindow(part, index, p, face, blur, wind);
        if (inside && local.y > houseAtticStoreyY) {
            // The dormers' bays are bare boards, and sacking hangs at their
            // windows.
            SurfaceMaterial boards = houseAtticBoards(p, face, blur, false);
            float folds = 0.6f + 0.4f * w.fold;
            float3 albedo = mix(boards.albedo, houseBareOak * 0.4f, w.frame);
            albedo = mix(albedo, float3(0.075f, 0.062f, 0.045f) * folds,
                w.drape + w.glass);
            return {albedo, 0.92f, 0.0f, float3(0.0f)};
        }
        if (inside) {
            // Wallpaper between wainscot and cornice; curtains are drawn
            // across the windows.
            float3 wood = float3(0.07f, 0.04f, 0.025f);
            float2 band = houseStoreyBand(local);
            SurfaceMaterial paper = houseWallpaper(s,
                (local.y - band.x) * houseScale, (band.y - band.x) * houseScale,
                houseRoom(p), float(index) * 3.1f,
                part.windows.x + part.windows.y < 0.5f, float2(lo, hi), blur,
                mood, time);
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

    if (style == houseMasonry)
        return masonrySurfaceMaterial(part, p, n, blur, game);
    if (style == houseTimber) return houseTimberMaterial(part, p, n, blur, paint);
    if (style == houseLog) return houseLogMaterial(part, p, n, blur, inside);
    if (style == houseGrave) {
        SurfaceMaterial stone = houseGraveMaterial(part, p, n, blur,
            mood, time);
        return buildingDebris ? stone : shadeMausoleumSpalls(stone, game,
            index, p, n, blur);
    }
    if (style == housePlaster || style == housePlasterColumn)
        return housePlasterMaterial(part, p, n, blur);
    if (style == houseCorrugated) return houseCorrugatedMaterial(p, n, blur);
    if (style == houseCastIron || style == houseCastIronRod)
        return houseCastIronMaterial(style == houseCastIronRod ? part.rows.w
            : 0.5f * min(min(part.upper.x - part.lower.x,
                part.upper.y - part.lower.y), part.upper.z - part.lower.z),
            blur);
    if (style == houseSign)
        return houseSignMaterial(part, p, n, blur, signFont);

    if (style == houseFloor)
        return houseFloorMaterial(p, n, local, blur, inside);
    if (style == houseStair) return houseStairMaterial(part, p, n, blur);
    if (style == houseBanister)
        return houseBanisterMaterial(part, p, n, blur);

    if (style == houseRoof) {
        if (inside) return houseAtticBoards(p, n, blur, n.y < -0.5f);
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
        // A door leaf's grain runs along it, whichever way it has swung.
        bool leaf = houseIsDoorLeaf(part);
        float2 span = houseDoorLeafSpan(part, p);
        if (leaf) s = span.x;
        // Weathered paint: grain shows through, worn to bare oak on edges
        // and in patches.
        float2 grainAt = abs(n.y) > 0.5f ? p.xz : float2(s, p.y);
        float grain = 0.8f + 0.2f * sin(grainAt.y * 23.0f + 7.0f
            * smoothNoise(grainAt * float2(2.0f, 0.5f)));
        float worn = smoothstep(0.58f, 0.72f, smoothNoise(grainAt * 2.1f
            + float2(index)));
        float3 albedo = mix(trim * (0.8f + 0.4f * smoothNoise(float2(s * 3.0f,
            p.y * 0.4f))), houseBareOak * 0.8f * grain, worn);
        // The front doors carry three raised panels on each broad face.
        if (leaf && abs(dot(n, part.planes[3].xyz)) > 0.5f) {
            float2 d = float2(span.x, p.y - part.lower.y);
            float panel = max(houseLines(d.x - 0.12f, span.y - 0.24f, 0.04f,
                blur), houseLines(d.y - 0.12f, (size.y - 0.24f) / 3.0f, 0.04f,
                blur));
            albedo *= 1.0f - 0.45f * panel;
        }
        return {albedo, 0.6f, 0.0f, float3(0.0f)};
    }

    if (style == houseStone) {
        if (n.y > 0.5f && !buildingDebris) {
            bool deck = local.z < -6.15f || (abs(local.x) < 8.15f
                && abs(local.z) < 6.15f);
            if (inside || (deck && local.y > 0.05f)) {
                SurfaceMaterial boards = houseBoards(metres, local, blur,
                    inside, false);
                float3 albedo = boards.albedo;
                float roughness = boards.roughness;
                // A long runner rug down the hall.
                float2 rug = abs(local.xz - float2(0.0f, -2.25f))
                    - float2(1.25f, 2.65f);
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
        if (inside && n.x > 0.5f && houseRoom(p) == 1u) {
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
        if (part.windows.x > 1.5f)
            return houseBookcase(part, p, n, blur, wood);
        if (part.windows.x > 0.5f) return houseDustSheet(p, n);
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
        // rows.w brightens a lantern; it is 1 unless its builder sets it.
        float level = houseFlicker(time, part.lower.x, 0.12f) * mood.dim
            * part.rows.w;
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

// Uneven flagstones at metres across and along a path: each row is
// offset, each stone its own size. Returns 1 for on the path, stone
// coverage against the grout, and a tone per stone.
float3 houseFlagstones(float2 metres, float blur) {
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

// The flagstone path from the base exit to the porch steps, and the
// narrower aisle of each graveyard plot from its gate to the mausoleum's
// steps, as houseFlagstones measures them, or zero off them.
float3 housePath(float2 p, float blur) {
    float2 metres = p - houseOrigin.xz;
    float stepsFront = (housePorchFront
        - houseStepRun * float(houseStepCount)) * houseScale;
    float edge = 1.6f + 0.15f * smoothNoise(p * 1.7f);
    if (abs(metres.x) > edge || p.y < hullSouth + 0.3f
        || metres.y > stepsFront + 0.05f) {
        float aisle = abs(metres.x) - houseYardAisleX * houseScale;
        float aisleEnd = houseYardMausoleumZ
            + mausoleumFootprint().y / houseScale;
        if (abs(aisle) > edge - 0.5f
            || metres.y < (houseGroundLower.y - 0.4f) * houseScale
            || metres.y > aisleEnd * houseScale) return float3(0.0f);
        metres.x = aisle;
    }
    return houseFlagstones(metres, blur);
}

// Dug earth over each standing grave, 0 to 1: a plot in front of its
// marker with a ragged edge.
float houseGraveSoil(float2 p) {
    float2 local = houseLocal(p);
    float ragged = 0.04f * (smoothNoise(p * 9.0f) - 0.5f);
    if (abs(local.x) > houseLotUpper.x && all(local >= houseGroundLower)
        && all(local <= houseGroundUpper)) {
        // On a graveyard plot: the grave of the cell whose earth can lie
        // here, which reaches up to 1.25 units in front of its foot.
        uint3 cell = houseYardCell(local, 0.55f);
        HouseYardGrave grave = houseYardGrave(cell.x, cell.y, cell.z);
        if (grave.kind != houseGraveCross && grave.kind != houseGraveRound
            && grave.kind != houseGravePointed) return 0.0f;
        float2 offset = (local - grave.at) * houseScale;
        float edge = max(abs(offset.x) - 0.45f, abs(-offset.y - 1.15f) - 0.95f)
            + ragged;
        return 1.0f - smoothstep(-0.05f, 0.03f, edge);
    }
    if (any(local < houseLotLower) || any(local > houseLotUpper)) return 0.0f;
    float plot = 0.0f;
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
    bool angry = game.gesture.w > 0.5f;
    float3 ghostColor = angry ? float3(0.025f, 1.0f, 0.025f)
        : houseGhostGreen;
    float3 glowColor = angry ? float3(0.05f, 0.3f, 1.0f)
        : ghostColor;
    float3 glow = glowColor * (angry ? 0.05f : 0.12f)
        * exp(-max(nearest, 0.0f) * 7.0f)
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
    float3 sheet = mix(float3(0.55f, 0.85f, 0.65f), ghostColor,
        angry ? 1.0f : 0.45f)
        * (0.35f + 1.6f * rim) * shimmer;
    float alpha = fade * mix(0.3f + 0.55f * rim, 0.92f, hollow);
    return mix(color, mix(sheet, float3(0.0f, 0.01f, 0.0f), hollow), alpha)
        + glow;
}

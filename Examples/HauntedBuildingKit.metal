// The building kit for HauntedHouseProgram.metal: the parts every haunted
// building is made of, and the shared surfaces they are shaded with.
//
// A building is written once, in the initialize pass, into the game
// buffer's HouseModel as convex parts: boxes, some cut by up to four planes
// into gables, hips, spires and sloping boards, and round logs. Parts are
// gathered into groups, and groups into building sites. A ray tests a
// group's parts only when it enters the group's bounds, and a site's first
// group bounds the whole site, so a ray that misses it skips every group of
// that site. Adding a building therefore adds parts, not code, to the scene
// traces in HauntedBuildings.metal.
//
// A part's style picks its shading: clapboard, battens, slate, trim,
// stone, brick, cut-out iron and the rest. Styles are shared, so a new
// building looks like it belongs with the house. Pattern sizes are in
// metres unless a style says otherwise.
//
// HauntedHouseProgram.metal includes this file before HauntedHouse.metal
// and the other buildings, and HauntedBuildings.metal after them all; an
// included file cannot include another.

// ------------------------------------------------------------------ styles
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

// A repeatable hash in [0, 1) for the buildings' irregularities.
float houseHash(float seed) {
    return fract(sin(seed * 12.9898f + 4.1414f) * 43758.5453f);
}

// Lamps, lanterns and candles flicker by the same law.
float houseFlicker(float time, float phase, float depth) {
    return 1.0f - depth * (0.5f + 0.3f * sin(time * 7.3f + phase)
        + 0.2f * sin(time * 17.9f + 2.7f * phase));
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

// Opens a group in the open site.
void beginHouseGroup(device HouseModel &house) {
    uint g = house.counts.y;
    if (g >= houseGroupCapacity) return;
    float first = float(house.counts.x);
    house.groups[g].lower = float4(float3(1.0e9f), first);
    house.groups[g].upper = float4(float3(-1.0e9f), first);
    house.groups[g].last = uint4(g, 0u, 0u, 0u);
    house.counts.y = g + 1u;
    uint s = house.counts.w;
    if (s == 0u) return;
    house.groups[house.sites[s - 1u].x].last.x = g;
    house.sites[s - 1u].y = g + 1u;
}

// Opens a building site. Its first group holds no parts of its own: it
// grows to bound every part the site adds, and records the site's last
// group, so a ray that misses it skips the site.
void beginBuildingSite(device HouseModel &house) {
    uint s = house.counts.w, g = house.counts.y;
    if (s >= buildingSiteCapacity || g >= houseGroupCapacity) return;
    house.sites[s] = uint4(g, g, house.counts.x, house.counts.x);
    house.counts.w = s + 1u;
    beginHouseGroup(house);
}

// Grows the bounds of group g to hold a part.
void growHouseGroup(device HouseModel &house, uint g, HousePart part) {
    HouseGroup group = house.groups[g];
    house.groups[g].lower = float4(min(group.lower.xyz, part.lower.xyz),
        group.lower.w);
    house.groups[g].upper = float4(max(group.upper.xyz, part.upper.xyz),
        group.upper.w);
}

// Adds a part already in world metres to the open group.
void addHouseWorldPart(device HouseModel &house, HousePart part) {
    uint i = house.counts.x;
    if (i >= houseCapacity || house.counts.y == 0u) return;
    house.parts[i] = part;
    house.counts.x = i + 1u;
    uint g = house.counts.y - 1u;
    growHouseGroup(house, g, part);
    house.groups[g].upper.w = float(i + 1u);
    uint s = house.counts.w;
    if (s == 0u) return;
    uint first = house.sites[s - 1u].x;
    if (first != g) growHouseGroup(house, first, part);
    house.sites[s - 1u].w = i + 1u;
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

// Entry distance into any part: logs are round, everything else is a cut
// box.
float houseHitPart(device const HousePart &part, float3 origin,
    float3 direction, float limit, thread float3 &normal) {
    return uint(part.lower.w) == houseLog
        ? houseLogHit(part, origin, direction, limit, normal)
        : housePartHit(part, origin, direction, limit, normal);
}

// ---------------------------------------------------------------- surfaces

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

// ------------------------------------------------------------------ graves
// Headstones and wooden crosses at their real size in world metres, for
// any graveyard.

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

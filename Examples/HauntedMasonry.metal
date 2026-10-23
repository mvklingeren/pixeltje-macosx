// Reusable, bounded masonry wall panels. A panel is one HousePart for broad
// phase culling, while its courses are generated only for cells a ray crosses.
// windows: stone width, course height, panel ID, horizontal axis (0 x, 1 z).
// masonryGone stores one bit per removed stone, so a hole has real thickness
// and the same stone is absent from view, weapon and shadow rays.

uint masonryRows(device const HousePart &part) {
    return min(uint(ceil((part.upper.y - part.lower.y) / part.windows.y)),
        masonryMaxRows);
}

uint masonryColumns(device const HousePart &part) {
    float span = part.windows.w < 0.5f
        ? part.upper.x - part.lower.x : part.upper.z - part.lower.z;
    return min(uint(ceil(span / part.windows.x)) + 1u, 32u);
}

void masonryStoneBox(device const HousePart &part, uint row, uint column,
    thread float3 &lower, thread float3 &upper) {
    lower = part.lower.xyz;
    upper = part.upper.xyz;
    float pitch = part.windows.x;
    float start = (part.windows.w < 0.5f ? part.lower.x : part.lower.z)
        + (float(column) - 0.5f * float(row & 1u)) * pitch;
    float end = start + pitch;
    if (part.windows.w < 0.5f) {
        lower.x = max(lower.x, start);
        upper.x = min(upper.x, end);
    } else {
        lower.z = max(lower.z, start);
        upper.z = min(upper.z, end);
    }
    lower.y = part.lower.y + float(row) * part.windows.y;
    upper.y = min(part.upper.y, lower.y + part.windows.y);
}

bool masonryStoneGone(device const GameState &game, uint panel, uint row,
    uint column) {
    return (game.masonryGone[min(panel, masonryPanelCount - 1u)]
        [min(row, masonryMaxRows - 1u)] & (1u << min(column, 31u))) != 0u;
}

// The panel is at most one wall thick. Test only courses and stones crossed
// by that segment of the ray, rather than every block in the building.
__attribute__((noinline))
float masonryHitPart(device const HousePart &part,
    device const GameState &game, float3 origin, float3 direction,
    float limit, thread float3 &normal) {
    float3 safe = select(direction, float3(1.0e-6f),
        abs(direction) < float3(1.0e-6f));
    float3 a = (part.lower.xyz - origin) / safe;
    float3 b = (part.upper.xyz - origin) / safe;
    float entry = max(max(min(a.x, b.x), min(a.y, b.y)), min(a.z, b.z));
    float exit = min(min(max(a.x, b.x), max(a.y, b.y)), max(a.z, b.z));
    entry = max(entry, 0.0f);
    exit = min(exit, limit);
    if (entry >= exit) return -1.0f;

    uint panel = uint(part.windows.z);
    uint rows = masonryRows(part), columns = masonryColumns(part);
    float best = limit;
    for (uint row = 0u; row < rows; ++row) {
        float y0 = part.lower.y + float(row) * part.windows.y;
        float y1 = min(y0 + part.windows.y, part.upper.y);
        float begin = entry, end = exit;
        if (abs(direction.y) < 1.0e-6f) {
            if (origin.y < y0 || origin.y > y1) continue;
        } else {
            float t0 = (y0 - origin.y) / direction.y;
            float t1 = (y1 - origin.y) / direction.y;
            begin = max(begin, min(t0, t1));
            end = min(end, max(t0, t1));
            if (begin > end) continue;
        }
        float u0 = part.windows.w < 0.5f ? origin.x + direction.x * begin
            : origin.z + direction.z * begin;
        float u1 = part.windows.w < 0.5f ? origin.x + direction.x * end
            : origin.z + direction.z * end;
        float base = part.windows.w < 0.5f ? part.lower.x : part.lower.z;
        float stagger = 0.5f * float(row & 1u);
        int first = max(int(floor((min(u0, u1) - base)
            / part.windows.x + stagger)) - 1, 0);
        int last = min(int(floor((max(u0, u1) - base)
            / part.windows.x + stagger)) + 1, int(columns) - 1);
        for (int col = first; col <= last; ++col) {
            if (masonryStoneGone(game, panel, row, uint(col))) continue;
            float3 lower, upper, face;
            masonryStoneBox(part, row, uint(col), lower, upper);
            if (any(lower >= upper)) continue;
            float t = rayBox(origin, direction, lower, upper, face);
            if (t <= 0.0f || t >= best) continue;
            best = t;
            normal = face;
        }
    }
    return best < limit ? best : -1.0f;
}

SurfaceMaterial masonrySurfaceMaterial(device const HousePart &part,
    float3 p, float3 n, float blur) {
    float u = part.windows.w < 0.5f ? p.x - part.lower.x
        : p.z - part.lower.z;
    float v = p.y - part.lower.y;
    float row = floor(v / part.windows.y);
    float shifted = u / part.windows.x + 0.5f * fmod(row, 2.0f);
    float edgeU = min(fract(shifted), 1.0f - fract(shifted))
        * part.windows.x;
    float edgeV = min(fract(v / part.windows.y),
        1.0f - fract(v / part.windows.y)) * part.windows.y;
    float joint = 1.0f - smoothstep(0.012f, 0.012f + blur,
        min(edgeU, edgeV));
    float cell = floor(shifted);
    float tone = 0.82f + 0.3f * houseHash(cell * 17.0f + row * 41.0f
        + part.windows.z * 113.0f);
    float weather = 0.86f + 0.18f * smoothNoise(float2(
        (p.x + p.z) * 3.0f, p.y * 0.55f));
    float3 stone = float3(0.17f, 0.162f, 0.145f) * tone * weather;
    // Faces revealed by a missing neighbour show the less weathered core.
    if (abs(n.y) > 0.5f || (part.windows.w < 0.5f
            ? abs(n.x) > 0.5f : abs(n.z) > 0.5f))
        stone *= 1.10f;
    return {stone * (1.0f - 0.48f * joint), 0.87f, 0.0f,
        float3(0.0f)};
}

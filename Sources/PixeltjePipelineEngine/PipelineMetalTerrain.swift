/// Stateless procedural terrain for GPU Program and Metal Render sources.
/// Version 1 supplies seeded noise, crater and rock layers and a generic
/// height-field tracer. The caller composes its own height field from them and
/// keeps materials, lighting and collision policy.
///
/// A height field is any value with `float operator()(float2 xz) const`
/// returning the surface height at world XZ. Pass a cheaper field to `trace`
/// and `softShadow` than to `normal` when only the shading needs fine detail.
enum PipelineMetalTerrain {
  static let marker = "// pixeltje:terrain-v1"

  static let library = """
    #include <metal_stdlib>
    namespace pixeltje_terrain {
      using namespace metal;

      // An integer hash of a lattice point stays stable far from the origin,
      // where sin-based hashes lose precision. Returns [0, 1).
      inline float hash(float2 cell, float seed) {
        uint2 q = as_type<uint2>(int2(cell));
        uint h = q.x * 0x8da6b343u ^ q.y * 0xd8163841u
          ^ as_type<uint>(seed) * 0xcb1ab31fu;
        h ^= h >> 16u; h *= 0x7feb352du;
        h ^= h >> 15u; h *= 0x846ca68bu;
        h ^= h >> 16u;
        return float(h) * (1.0f / 4294967296.0f);
      }

      // Quintic value noise in [0, 1], continuous in slope.
      inline float valueNoise(float2 p, float seed) {
        float2 cell = floor(p), f = p - cell;
        float2 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
        return mix(
          mix(hash(cell, seed), hash(cell + float2(1.0f, 0.0f), seed), u.x),
          mix(hash(cell + float2(0.0f, 1.0f), seed),
            hash(cell + float2(1.0f, 1.0f), seed), u.x), u.y);
      }

      // Fractal sum in (-1, 1). Octaves are not renormalized, so a field with
      // fewer octaves has the same broad shape and only lacks fine detail.
      inline float fbm(float2 p, int octaves, float seed) {
        const float2x2 turn = float2x2(1.6f, 1.2f, -1.2f, 1.6f);
        float sum = 0.0f, amplitude = 0.5f;
        for (int i = 0; i < octaves; ++i) {
          sum += amplitude * (valueNoise(p, seed + float(i)) * 2.0f - 1.0f);
          p = turn * p;
          amplitude *= 0.5f;
        }
        return sum;
      }

      // At most one crater per square cell of cellSize world units, with the
      // given chance per cell. Returns a height offset in world units: a bowl
      // 0.35 radius deep and a raised rim that fades out by 1.45 radii, kept
      // inside its own cell so each layer reads one cell per sample.
      inline float craters(float2 p, float cellSize, float density,
                           float seed) {
        float2 q = p / cellSize, cell = floor(q);
        if (hash(cell, seed) >= density) return 0.0f;
        float2 centre = 0.35f + 0.3f * float2(hash(cell, seed + 1.0f),
          hash(cell, seed + 2.0f));
        float radius = mix(0.12f, 0.23f, hash(cell, seed + 3.0f));
        float d = length(q - cell - centre) / radius;
        float profile = d < 1.0f ? 0.43f * d * d - 0.35f
          : 0.08f * (1.0f - smoothstep(1.0f, 1.45f, d));
        return profile * radius * cellSize;
      }

      // At most one boulder per square cell of cellSize world units, with the
      // given chance per cell. Returns a height offset in world units: an
      // angular rock of six sloping faces under a tilted top, up to 0.17
      // cellSize tall and kept inside its own cell like a crater. Its faces
      // stay below slope 1.8, which `trace` steps across safely.
      inline float rocks(float2 p, float cellSize, float density,
                         float seed) {
        float2 q = p / cellSize, cell = floor(q);
        if (hash(cell, seed) >= density) return 0.0f;
        float2 o = q - cell - 0.35f - 0.3f * float2(hash(cell, seed + 1.0f),
          hash(cell, seed + 2.0f));
        float slope = mix(1.1f, 1.8f, hash(cell, seed + 3.0f));
        float turn = 6.2831853f * hash(cell, seed + 4.0f);
        float2 tilt = 0.3f * float2(hash(cell, seed + 5.0f),
          hash(cell, seed + 6.0f)) - 0.15f;
        float h = mix(0.04f, 0.1f, hash(cell, seed + 7.0f)) + dot(o, tilt);
        // Each face's foot lies 0.1 to 0.22 of the cell from the centre, and
        // neighbouring faces turn 60 +- 18 degrees apart, so no corner of the
        // footprint lies farther than 0.33 of the cell from the centre.
        for (int k = 0; k < 6; ++k) {
          float angle = turn + 1.0471976f
            * (float(k) + 0.6f * hash(cell, seed + 8.0f + float(k)) - 0.3f);
          float reach = mix(0.1f, 0.22f, hash(cell, seed + 14.0f + float(k)));
          h = min(h, slope * (reach - dot(o, float2(cos(angle), sin(angle)))));
        }
        return max(h, 0.0f) * cellSize;
      }

      // Ray distance to the field between near and far, or -1 on a miss. A
      // ray that rises above ceiling, the field's highest point, stops early.
      template <typename Field>
      inline float trace(Field field, float3 origin, float3 direction,
                         float near, float far, float ceiling, int steps) {
        float t = near, previousT = near, previousGap = 0.0f;
        for (int i = 0; i < steps; ++i) {
          float3 p = origin + direction * t;
          float gap = p.y - field(p.xz);
          if (gap < 0.0f) return i == 0 ? t
            : mix(previousT, t, previousGap / (previousGap - gap));
          if (gap < 0.001f * t) return t;
          if (t >= far || (p.y > ceiling && direction.y >= 0.0f)) return -1.0f;
          previousT = t;
          previousGap = gap;
          t = min(t + max(gap * 0.45f, 0.002f + 0.004f * t), far);
        }
        // Grazing rays can run out of steps just above the ground; treat
        // those as hits so the horizon has no gaps.
        return previousGap < 0.03f * previousT ? previousT : -1.0f;
      }

      template <typename Field>
      inline float3 normal(Field field, float2 xz, float epsilon) {
        float2 e = float2(epsilon, 0.0f);
        return normalize(float3(field(xz - e.xy) - field(xz + e.xy),
          2.0f * epsilon, field(xz - e.yx) - field(xz + e.yx)));
      }

      // Soft shadow toward a distant light: 1 is fully lit. Larger hardness
      // narrows the penumbra. Offset origin off the surface before calling.
      template <typename Field>
      inline float softShadow(Field field, float3 origin, float3 direction,
                              float near, float far, float ceiling,
                              float hardness, int steps) {
        float lit = 1.0f, t = near;
        for (int i = 0; i < steps && t < far; ++i) {
          float3 p = origin + direction * t;
          if (p.y > ceiling && direction.y >= 0.0f) break;
          float gap = p.y - field(p.xz);
          lit = min(lit, hardness * gap / t);
          if (lit <= 0.0f) return 0.0f;
          t += max(gap * 0.5f, 0.05f + 0.02f * t);
        }
        return smoothstep(0.0f, 1.0f, lit);
      }
    }
    """
}

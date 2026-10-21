/// Stateless post-processing for GPU Program and Metal Render sources.
/// Version 1 supplies bokeh depth of field, bloom and chromatic aberration
/// over a linear-light texture. The caller owns the passes, the textures
/// between them, and when and how strongly each effect applies.
enum PipelineMetalPostFX {
  static let marker = "// pixeltje:postfx-v1"

  static let library = """
    #include <metal_stdlib>
    namespace pixeltje_postfx {
      using namespace metal;

      constexpr sampler linearClamp(coord::normalized,
        address::clamp_to_edge, filter::linear);

      // Blur radius in pixels: `aperture` at infinite depth, growing toward
      // `maxRadius` in front of the focus plane. Depth <= 0 stays sharp.
      inline float circleOfConfusion(float depth, float focusDistance,
                                     float aperture, float maxRadius) {
        if (depth <= 0.0f) return 0.0f;
        return clamp(aperture * abs(1.0f - focusDistance / depth),
          0.0f, maxRadius);
      }

      // Single-pass gather depth of field over linear light with view depth
      // in alpha. Running before tone mapping turns bright highlights into
      // discs. Cost grows with maxRadius squared, so it is capped at 32
      // pixels. Aperture <= 0 returns the pixel unchanged.
      inline float4 bokeh(texture2d<float> scene, float2 uv,
                          float2 resolution, float focusDistance,
                          float aperture, float maxRadius) {
        float4 centre = scene.sample(linearClamp, uv);
        maxRadius = min(maxRadius, 32.0f);
        if (aperture <= 0.0f || maxRadius <= 0.5f) return centre;
        float centreSize = circleOfConfusion(centre.a, focusDistance,
          aperture, maxRadius);
        float2 texel = 1.0f / resolution;
        float3 color = centre.rgb;
        float total = 1.0f;
        float radius = 0.5f;
        // Golden-angle spiral whose taps stay about one pixel apart.
        for (float angle = 0.0f; radius < maxRadius; angle += 2.39996323f) {
          float4 tap = scene.sample(linearClamp,
            uv + float2(cos(angle), sin(angle)) * radius * texel);
          float size = circleOfConfusion(tap.a, focusDistance, aperture,
            maxRadius);
          // Background never blurs over a sharper pixel in front of it.
          if (tap.a > centre.a) size = min(size, centreSize * 2.0f);
          color += mix(color / total, tap.rgb,
            smoothstep(radius - 0.5f, radius + 0.5f, size));
          total += 1.0f;
          radius += 0.5f / radius;
        }
        return float4(color / total, centre.a);
      }

      // One direction of a 13-tap Gaussian over light above `threshold`;
      // `stride` is the UV offset between taps. Run it across, then down
      // with threshold 0, and add a fraction of the result to the scene.
      inline float3 bloomBlur(texture2d<float> source, float2 uv,
                              float2 stride, float threshold) {
        float3 sum = float3(0.0f);
        float total = 0.0f;
        for (int i = -6; i <= 6; ++i) {
          float weight = exp(-float(i * i) / 12.5f);
          sum += max(source.sample(linearClamp, uv + float(i) * stride).rgb
            - threshold, float3(0.0f)) * weight;
          total += weight;
        }
        return sum / total;
      }

      // Radial lens fringing: red samples `amount` of the offset from the
      // image centre further out and blue as far in. Amount 0 is a plain
      // sample.
      inline float3 chromaticAberration(texture2d<float> source, float2 uv,
                                        float amount) {
        float2 fringe = (uv - 0.5f) * amount;
        return float3(source.sample(linearClamp, uv + fringe).r,
          source.sample(linearClamp, uv).g,
          source.sample(linearClamp, uv - fringe).b);
      }
    }
    """
}

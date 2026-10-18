import Foundation

/// Versioned Metal helpers included only when a shader opts in on its first line.
/// The resolved source is used for validation, compilation, and cache identity.
enum PipelineMetalEasing {
  static let marker = "// pixeltje:easing-v1"

  static func resolving(_ source: String) -> String {
    guard source.hasPrefix(marker + "\n") || source.hasPrefix(marker + "\r\n") else {
      return source
    }
    return library + "\n" + source
  }

  private static let library = """
    #include <metal_stdlib>
    namespace pixeltje_easing {
      inline float unit(float t) {
        return metal::clamp(t, 0.0f, 1.0f);
      }

      inline float bezierCoordinate(float t, float first, float second) {
        float remaining = 1.0f - t;
        return 3.0f * remaining * remaining * t * first
          + 3.0f * remaining * t * t * second + t * t * t;
      }

      // Invert the time coordinate before sampling the value coordinate.
      // These are the same control points used by Pipeline Timeline.
      inline float cubicBezier(float time, float x1, float y1,
                               float x2, float y2) {
        float fraction = unit(time);
        if (fraction <= 0.0f || fraction >= 1.0f) return fraction;
        float lower = 0.0f;
        float upper = 1.0f;
        for (int index = 0; index < 18; ++index) {
          float middle = (lower + upper) * 0.5f;
          if (bezierCoordinate(middle, x1, x2) < fraction)
            lower = middle;
          else
            upper = middle;
        }
        return bezierCoordinate((lower + upper) * 0.5f, y1, y2);
      }

      inline float linear(float time) { return unit(time); }
      inline float easeIn(float time) {
        return cubicBezier(time, 0.42f, 0.0f, 1.0f, 1.0f);
      }
      inline float easeOut(float time) {
        return cubicBezier(time, 0.0f, 0.0f, 0.58f, 1.0f);
      }
      inline float easeInOut(float time) {
        return cubicBezier(time, 0.42f, 0.0f, 0.58f, 1.0f);
      }
    }
    """
}

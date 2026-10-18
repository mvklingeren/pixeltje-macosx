/// Stateless 3D helpers for GPU Program and Metal Render sources. Version 1
/// keeps game state, materials, scene tracing, and lighting policy in the caller.
enum PipelineMetal3D {
  static let marker = "// pixeltje:3d-v1"

  static let library = """
    #include <metal_stdlib>
    namespace pixeltje_3d {
      using namespace metal;

      inline float3 forward(float yaw, float pitch) {
        return float3(sin(yaw) * cos(pitch), sin(pitch),
          -cos(yaw) * cos(pitch));
      }

      // UV origin is top-left; focal length is in screen-height units.
      inline float3 cameraDirection(float2 uv, float2 resolution,
                                    float yaw, float pitch, float focal) {
        float3 front = forward(yaw, pitch);
        float3 right = normalize(cross(front, float3(0.0f, 1.0f, 0.0f)));
        float3 up = cross(right, front);
        float2 screen = (uv - 0.5f) * resolution / resolution.y;
        return normalize(front * focal + right * screen.x - up * screen.y);
      }

      // Directions are normalized. Negative distance means no hit.
      inline float raySphere(float3 origin, float3 direction, float3 centre,
                             float radius, float minimumDistance) {
        float3 offset = origin - centre;
        float b = dot(offset, direction);
        float c = dot(offset, offset) - radius * radius;
        float discriminant = b * b - c;
        if (discriminant < 0.0f) return -1.0f;
        float root = sqrt(discriminant);
        float near = -b - root;
        float far = -b + root;
        return near > minimumDistance ? near
          : (far > minimumDistance ? far : -1.0f);
      }

      inline float rayEllipsoid(float3 origin, float3 direction, float3 centre,
                                float3 radii, float minimumDistance,
                                thread float3 &normal) {
        float3 o = (origin - centre) / radii;
        float3 d = direction / radii;
        float a = dot(d, d);
        float b = dot(o, d);
        float discriminant = b * b - a * (dot(o, o) - 1.0f);
        if (discriminant < 0.0f) return -1.0f;
        float root = sqrt(discriminant);
        float near = (-b - root) / a;
        float far = (-b + root) / a;
        float t = near > minimumDistance ? near : far;
        if (t <= minimumDistance) return -1.0f;
        normal = normalize((origin + direction * t - centre)
          / (radii * radii));
        return t;
      }

      inline float rayBox(float3 origin, float3 direction, float3 lower,
                          float3 upper, float minimumDistance,
                          thread float3 &normal) {
        float3 safe = select(direction, float3(0.00001f),
          abs(direction) < float3(0.00001f));
        float3 a = (lower - origin) / safe;
        float3 b = (upper - origin) / safe;
        float3 entry = min(a, b);
        float3 exit = max(a, b);
        float near = max(entry.x, max(entry.y, entry.z));
        float far = min(exit.x, min(exit.y, exit.z));
        if (far < max(near, minimumDistance)) return -1.0f;
        float t = near > minimumDistance ? near : far;
        float3 point = origin + direction * t;
        float3 centre = (lower + upper) * 0.5f;
        float3 edge = abs((point - centre) / max((upper - lower) * 0.5f,
          float3(0.001f)));
        normal = edge.x > edge.y && edge.x > edge.z
          ? float3(sign(point.x - centre.x), 0.0f, 0.0f)
          : edge.y > edge.z
            ? float3(0.0f, sign(point.y - centre.y), 0.0f)
            : float3(0.0f, 0.0f, sign(point.z - centre.z));
        return t;
      }

      inline float3 fresnelSchlick(float cosine, float3 f0) {
        return f0 + (1.0f - f0) * pow(1.0f - cosine, 5.0f);
      }

      inline float3 srgbToLinear(float3 srgb) {
        return select(pow((srgb + 0.055f) / 1.055f, float3(2.4f)),
          srgb / 12.92f, srgb <= 0.04045f);
      }

      inline float3 linearToSRGB(float3 linear) {
        return select(1.055f * pow(linear, float3(1.0f / 2.4f)) - 0.055f,
          12.92f * linear, linear <= 0.0031308f);
      }

      inline float3 filmicToneMap(float3 color) {
        return clamp((color * (2.51f * color + 0.03f))
          / (color * (2.43f * color + 0.59f) + 0.14f),
          float3(0.0f), float3(1.0f));
      }
    }
    """
}

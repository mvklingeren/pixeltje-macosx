#include <metal_stdlib>
using namespace metal;

/*
 * "Seascape" by Alexander Alekseev aka TDM - 2014
 * License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
 * https://creativecommons.org/licenses/by-nc-sa/3.0/
 * Contact: tdmaav@gmail.com
 *
 * Metal adaptation of the shader supplied by the user. The original
 * attribution and license apply to this adapted example source.
 */

// Metal Render supplies these two float4 values at fragment buffer 0.
struct ShaderUniforms {
    float4 resolutionTime; // width, height, iTime in seconds, unused
    float4 mouse;          // pointer pixels, engaged flag, time at first touch
};

constant int NUM_STEPS = 32;
constant int ITER_GEOMETRY = 3;
constant int ITER_FRAGMENT = 5;
constant float PI = 3.141592f;
constant float EPSILON = 1e-3f;
constant float SEA_HEIGHT = 0.6f;
constant float SEA_CHOPPY = 4.0f;
constant float SEA_SPEED = 0.8f;
constant float SEA_FREQ = 0.16f;
constant float3 SEA_BASE = float3(0.0f, 0.09f, 0.18f);
constant float3 SEA_WATER_COLOR = float3(0.8f, 0.9f, 0.6f) * 0.6f;

float2 seaOctaveMatrix(float2 value) {
    // GLSL's vec2 * mat2(1.6, 1.2, -1.2, 1.6), in column-major order.
    return float2(1.6f * value.x + 1.2f * value.y,
                 -1.2f * value.x + 1.6f * value.y);
}

float3x3 fromEuler(float3 angle) {
    float2 a1 = float2(sin(angle.x), cos(angle.x));
    float2 a2 = float2(sin(angle.y), cos(angle.y));
    float2 a3 = float2(sin(angle.z), cos(angle.z));
    return float3x3(
        float3(a1.y * a3.y + a1.x * a2.x * a3.x,
               a1.y * a2.x * a3.x + a3.y * a1.x, -a2.y * a3.x),
        float3(-a2.y * a1.x, a1.y * a2.y, a2.x),
        float3(a3.y * a1.x * a2.x + a1.y * a3.x,
               a1.x * a3.x - a1.y * a3.y * a2.x, a2.y * a3.y));
}

float seaHash(float2 point) {
    return fract(sin(dot(point, float2(127.1f, 311.7f))) * 43758.5453123f);
}

float seaNoise(float2 point) {
    float2 cell = floor(point);
    float2 fraction = fract(point);
    float2 blend = fraction * fraction * (3.0f - 2.0f * fraction);
    return -1.0f + 2.0f * mix(
        mix(seaHash(cell + float2(0.0f, 0.0f)),
            seaHash(cell + float2(1.0f, 0.0f)), blend.x),
        mix(seaHash(cell + float2(0.0f, 1.0f)),
            seaHash(cell + float2(1.0f, 1.0f)), blend.x), blend.y);
}

float seaDiffuse(float3 normal, float3 light, float power) {
    return pow(dot(normal, light) * 0.4f + 0.6f, power);
}

float seaSpecular(float3 normal, float3 light, float3 eye, float power) {
    float normalization = (power + 8.0f) / (PI * 8.0f);
    return pow(max(dot(reflect(eye, normal), light), 0.0f), power) * normalization;
}

float3 skyColor(float3 direction) {
    direction.y = (max(direction.y, 0.0f) * 0.8f + 0.2f) * 0.8f;
    return float3(pow(1.0f - direction.y, 2.0f),
                  1.0f - direction.y,
                  0.6f + (1.0f - direction.y) * 0.4f) * 1.1f;
}

float seaOctave(float2 uv, float choppy) {
    uv += seaNoise(uv);
    float2 wave = 1.0f - abs(sin(uv));
    float2 swell = abs(cos(uv));
    wave = mix(wave, swell, wave);
    return pow(1.0f - pow(wave.x * wave.y, 0.65f), choppy);
}

float seaMap(float3 point, float seaTime, int iterations) {
    float frequency = SEA_FREQ;
    float amplitude = SEA_HEIGHT;
    float choppy = SEA_CHOPPY;
    float2 uv = point.xz;
    uv.x *= 0.75f;
    float height = 0.0f;
    for (int index = 0; index < iterations; ++index) {
        float wave = seaOctave((uv + seaTime) * frequency, choppy);
        wave += seaOctave((uv - seaTime) * frequency, choppy);
        height += wave * amplitude;
        uv = seaOctaveMatrix(uv);
        frequency *= 1.9f;
        amplitude *= 0.22f;
        choppy = mix(choppy, 1.0f, 0.2f);
    }
    return point.y - height;
}

float3 seaColor(float3 point, float3 normal, float3 light,
                float3 eye, float3 distance) {
    float fresnel = clamp(1.0f - dot(normal, -eye), 0.0f, 1.0f);
    fresnel = min(fresnel * fresnel * fresnel, 0.5f);
    float3 reflected = skyColor(reflect(eye, normal));
    float3 refracted = SEA_BASE
        + seaDiffuse(normal, light, 80.0f) * SEA_WATER_COLOR * 0.12f;
    float3 color = mix(refracted, reflected, fresnel);
    float attenuation = max(1.0f - dot(distance, distance) * 0.001f, 0.0f);
    color += SEA_WATER_COLOR * (point.y - SEA_HEIGHT) * 0.18f * attenuation;
    color += float3(seaSpecular(normal, light, eye,
        600.0f * rsqrt(dot(distance, distance))));
    return color;
}

float3 seaNormal(float3 point, float epsilon, float seaTime) {
    float3 normal;
    normal.y = seaMap(point, seaTime, ITER_FRAGMENT);
    normal.x = seaMap(point + float3(epsilon, 0.0f, 0.0f),
                      seaTime, ITER_FRAGMENT) - normal.y;
    normal.z = seaMap(point + float3(0.0f, 0.0f, epsilon),
                      seaTime, ITER_FRAGMENT) - normal.y;
    normal.y = epsilon;
    return normalize(normal);
}

float traceHeightMap(float3 origin, float3 direction,
                     thread float3 &point, float seaTime) {
    float nearTime = 0.0f;
    float farTime = 1000.0f;
    float farHeight = seaMap(origin + direction * farTime,
                             seaTime, ITER_GEOMETRY);
    if (farHeight > 0.0f) {
        point = origin + direction * farTime;
        return farTime;
    }
    float nearHeight = seaMap(origin, seaTime, ITER_GEOMETRY);
    for (int index = 0; index < NUM_STEPS; ++index) {
        float middleTime = mix(nearTime, farTime,
                               nearHeight / (nearHeight - farHeight));
        point = origin + direction * middleTime;
        float middleHeight = seaMap(point, seaTime, ITER_GEOMETRY);
        if (middleHeight < 0.0f) {
            farTime = middleTime;
            farHeight = middleHeight;
        } else {
            nearTime = middleTime;
            nearHeight = middleHeight;
        }
        if (abs(middleHeight) < EPSILON) break;
    }
    return mix(nearTime, farTime, nearHeight / (nearHeight - farHeight));
}

float3 seaPixel(float2 coordinate, float time,
                float2 resolution, float seaTime, float cameraPitch) {
    float2 uv = coordinate / resolution;
    uv = uv * 2.0f - 1.0f;
    uv.x *= resolution.x / resolution.y;

    float3 angle = float3(sin(time * 3.0f) * 0.1f,
                          sin(time) * 0.2f + 0.3f + cameraPitch, time);
    float3 origin = float3(0.0f, 3.5f, time * 5.0f);
    float3 direction = normalize(float3(uv, -2.0f));
    direction.z += length(uv) * 0.14f;
    direction = normalize(direction) * fromEuler(angle);

    float3 point;
    traceHeightMap(origin, direction, point, seaTime);
    float3 distance = point - origin;
    float epsilon = dot(distance, distance) * (0.1f / resolution.x);
    float3 normal = seaNormal(point, epsilon, seaTime);
    float3 light = normalize(float3(0.0f, 1.0f, 0.8f));
    float seaBlend = pow(1.0f - smoothstep(-0.02f, 0.0f, direction.y), 0.2f);
    return mix(skyColor(direction),
               seaColor(point, normal, light, direction, distance), seaBlend);
}

vertex float4 fullscreenVertex(uint vertexID [[vertex_id]]) {
    float2 position = float2((vertexID << 1) & 2, vertexID & 2);
    return float4(position * 2.0f - 1.0f, 0.0f, 1.0f);
}

fragment float4 seascapeFragment(
    float4 position [[position]], constant ShaderUniforms &uniforms [[buffer(0)]]) {
    float2 resolution = uniforms.resolutionTime.xy;
    float2 coordinate = float2(position.x, resolution.y - position.y);
    // Normalize the pointer so the small card preview and full-size output
    // have the same camera framing. Center matches the original idle camera.
    float2 camera = uniforms.mouse.xy / resolution - 0.5f;
    // Keep the sea moving, but hold the camera at its first-touch phase until
    // the Trackpad is reset. X and Y still move the held camera directly.
    float cameraTime = uniforms.mouse.z > 0.5f
        ? uniforms.mouse.w : uniforms.resolutionTime.z;
    float time = cameraTime * 0.3f + camera.x * 2.0f;
    float seaTime = 1.0f + uniforms.resolutionTime.z * SEA_SPEED;
    float3 color = seaPixel(coordinate, time, resolution, seaTime,
                            -camera.y * 0.6f);
    // The original shader writes display-referred color with this transfer.
    return float4(pow(max(color, float3(0.0f)), float3(0.65f)), 1.0f);
}

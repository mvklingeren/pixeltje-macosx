// Haunted House Winchester Model 1873: a lever-action rifle on key 5 with a
// tube magazine loaded one cartridge at a time through the loading gate on
// the right of the receiver. Included by HauntedHouseProgram.metal after
// SignalRangeShotgun.metal; game.rifle holds its state.

constant float heldRifle = 4.0f;
constant float rifleCapacity = 15.0f;    // tube magazine, .44-40
// A shot works the lever: the next shot waits for the whole cycle, and the
// lever swings down and back up over its last `rifleLeverTime` seconds.
constant float rifleCycleTime = 0.62f;
constant float rifleLeverTime = 0.48f;
// One cartridge pressed through the loading gate.
constant float rifleLoadTime = 0.42f;
// A .44-40 round strikes twice as hard as a pistol round.
constant float rifleDamage = 2.0f;
// Rifle frame, as the shotgun's: X right, Y up, Z along the barrel, origin
// at the wrist of the stock where the right hand grips it.
constant float3 rifleMuzzle = float3(0.0f, 0.024f, 0.785f);
constant float3 rifleLeverPivot = float3(0.0f, -0.020f, 0.150f);

bool holdingRifle(device const GameState &game) {
    return game.arms.x > 3.5f;
}

void resetRifle(device GameState &game) {
    game.rifle = float4(rifleCapacity, 0.0f, 0.0f, 0.0f);
}

// R loads the tube a cartridge at a time until it is full.
void startRifleLoading(device GameState &game) {
    if (game.rifle.y <= 0.0f && game.rifle.x < rifleCapacity)
        game.rifle.y = rifleLoadTime;
}

// The lever and loading clocks, and their sounds: the lever as it swings
// down after a shot, and each cartridge as it clicks into the tube. Loading
// stops when the rifle leaves the hand; R starts it again.
void advanceRifle(device GameState &game, device RangeAudio &audio,
    float dt) {
    float lever = game.rifle.z;
    game.rifle.z = max(game.rifle.z - dt, 0.0f);
    if (lever > rifleLeverTime && game.rifle.z <= rifleLeverTime)
        audio.rifleLever += 1u;
    if (game.rifle.y > 0.0f) {
        if (!holdingRifle(game) || game.arsenal.x != heldRifle) {
            game.rifle.y = 0.0f;
        } else if (armsReady(game)) {
            game.rifle.y -= dt;
            if (game.rifle.y <= 0.0f) {
                game.rifle.x = min(game.rifle.x + 1.0f, rifleCapacity);
                audio.rifleLoad += 1u;
                game.rifle.y = game.rifle.x < rifleCapacity
                    ? rifleLoadTime : 0.0f;
            }
        }
    }
    // w eases the gun into and out of the loading hold.
    float holding = game.rifle.y > 0.0f ? 1.0f : 0.0f;
    game.rifle.w += clamp(holding - game.rifle.w, -dt / 0.22f, dt / 0.22f);
}

// How far the lever is swung open: 0 shut, 1 fully down.
float rifleLeverSwing(device const GameState &game) {
    if (game.rifle.z <= 0.0f || game.rifle.z > rifleLeverTime) return 0.0f;
    return sin(rangePi * (1.0f - game.rifle.z / rifleLeverTime));
}

// Held low at the hip like the shotgun, a little further out. A shot shoves
// it into the shoulder and the lever nods it down; loading rolls the gate
// side up and dips the gun with each cartridge the thumb pushes in.
GunPose riflePose(device const GameState &game) {
    float loading = smoothstep(0.0f, 1.0f, game.rifle.w);
    float push = game.rifle.y > 0.0f
        ? sin(rangePi * (1.0f - game.rifle.y / rifleLoadTime)) : 0.0f;
    float lever = rifleLeverSwing(game);
    float kick = game.recoil.z;
    float bob = game.motion.w, phase = game.motion.z;
    float2 sway = game.look.zw;
    float lowered = weaponLowered(game);
    float3 pivot = float3(0.12f, -0.175f, 0.28f) + float3(
        0.012f * bob * sin(phase) - 0.007f * sway.x - 0.03f * loading,
        -0.009f * bob * abs(cos(phase)) - 0.007f * sway.y
            + 0.012f * kick - 0.012f * lever - 0.05f * loading
            - 0.012f * push * loading - 0.34f * lowered
            - 0.5f * game.hurt.w,
        -0.07f * kick - 0.04f * loading);
    float pitch = 0.16f * kick - 0.06f * lever - 0.22f * loading
        - 0.9f * lowered - 0.02f * sway.y;
    float yaw = -0.035f * sway.x - 0.10f * loading;
    float roll = 0.5f * loading + 0.08f * lever;
    float3 f = float3(sin(yaw) * cos(pitch), sin(pitch),
        cos(yaw) * cos(pitch));
    float3 r = normalize(float3(f.z, 0.0f, -f.x));
    float3 up = cross(f, r);
    return {pivot, float3x3(r * cos(roll) + up * sin(roll),
        up * cos(roll) - r * sin(roll), f), 0.0f};
}

// The pose and muzzle of whatever is in hand, the rifle included.
GunPose armedPose(device const GameState &game) {
    return holdingRifle(game) ? riflePose(game) : heldPose(game);
}

float3 armedMuzzle(device const GameState &game) {
    if (!holdingRifle(game)) return heldMuzzle(game);
    GunPose pose = riflePose(game);
    return pose.pivot + pose.basis * rifleMuzzle;
}

// An octagonal prism along Z, flats `apothem` from its axis at `centre`:
// the slabs of four plane pairs and the two end caps.
void rifleOctagon(thread GunHit &hit, float3 origin, float3 direction,
    float2 centre, float apothem, float near, float far, uint part) {
    const float k = 0.70710678f;
    const float2 axes[4] = {
        float2(1.0f, 0.0f), float2(0.0f, 1.0f), float2(k, k), float2(k, -k)};
    float3 o = origin - float3(centre, 0.0f);
    float dz = abs(direction.z) < 1.0e-6f ? 1.0e-6f : direction.z;
    float entry = (near - o.z) / dz, exit = (far - o.z) / dz;
    float3 normal = float3(0.0f, 0.0f, -1.0f);
    if (entry > exit) {
        float swap = entry;
        entry = exit;
        exit = swap;
        normal.z = 1.0f;
    }
    for (uint i = 0u; i < 4u; ++i) {
        float s = dot(o.xy, axes[i]), d = dot(direction.xy, axes[i]);
        if (abs(d) < 1.0e-6f) {
            if (abs(s) > apothem) return;
            continue;
        }
        float a = (-apothem - s) / d, b = (apothem - s) / d;
        if (min(a, b) > entry) {
            entry = min(a, b);
            normal = float3(axes[i] * -sign(d), 0.0f);
        }
        exit = min(exit, max(a, b));
    }
    if (entry > exit || entry <= 0.001f || entry >= hit.distance) return;
    hit = {entry, normal, part, origin + direction * entry};
}

// Parts: 4 glove, 5 sleeve, 7 walnut, 8 blued steel, 9 case-hardened
// receiver.
GunHit traceRifle(float3 origin, float3 direction, float lever) {
    GunHit hit = {1.0e6f, float3(0.0f), 0u, float3(0.0f)};
    if (raySphere(origin, direction, float3(0.0f, -0.05f, 0.21f), 0.68f)
        < 0.0f) return hit;
    // Octagonal barrel, the tube magazine under it and the band joining
    // them near the muzzle; sights on top.
    rifleOctagon(hit, origin, direction, float2(0.0f, 0.024f), 0.0105f,
        0.172f, 0.785f, 8u);
    gunCapsule(hit, origin, direction, float3(0.0f, -0.003f, 0.43f),
        float3(0.0f, -0.003f, 0.742f), 0.0085f, 8u);
    gunBox(hit, origin, direction, float3(-0.0118f, -0.0125f, 0.700f),
        float3(0.0118f, 0.0362f, 0.712f), 8u);
    gunBox(hit, origin, direction, float3(-0.0013f, 0.034f, 0.758f),
        float3(0.0013f, 0.0425f, 0.774f), 8u);
    gunBox(hit, origin, direction, float3(-0.0085f, 0.034f, 0.300f),
        float3(0.0085f, 0.0415f, 0.309f), 8u);
    // Receiver with its dust cover, which slides back as the lever opens,
    // the upper tang and the hammer behind it.
    gunBox(hit, origin, direction, float3(-0.0165f, -0.020f, 0.0f),
        float3(0.0165f, 0.040f, 0.174f), 9u);
    float cover = 0.045f * lever;
    gunBox(hit, origin, direction, float3(-0.009f, 0.040f, 0.030f - cover),
        float3(0.009f, 0.0465f, 0.150f - cover), 8u);
    gunBox(hit, origin, direction, float3(-0.0055f, 0.028f, -0.060f),
        float3(0.0055f, 0.037f, 0.0f), 8u);
    gunBox(hit, origin, direction, float3(-0.0035f, 0.034f, -0.016f),
        float3(0.0035f, 0.060f, -0.004f), 8u);
    // Walnut fore-end and its steel cap.
    gunBox(hit, origin, direction, float3(-0.0160f, -0.0185f, 0.176f),
        float3(0.0160f, 0.0215f, 0.420f), 7u);
    gunBox(hit, origin, direction, float3(-0.0165f, -0.0195f, 0.420f),
        float3(0.0165f, 0.0225f, 0.432f), 8u);
    // The lever and its finger loop, swung about the pivot at the front of
    // the receiver's underside: the loop drops as the lever opens.
    {
        float s = sin(0.95f * lever), c = cos(0.95f * lever);
        float3 o = rotateSpiderPitch(origin - rifleLeverPivot, s, c);
        float3 d = rotateSpiderPitch(direction, s, c);
        GunHit loop = {hit.distance, float3(0.0f), 0u, float3(0.0f)};
        gunCapsule(loop, o, d, float3(0.0f), float3(0.0f, -0.004f, -0.135f),
            0.0048f, 8u);
        gunCapsule(loop, o, d, float3(0.0f, -0.004f, -0.040f),
            float3(0.0f, -0.040f, -0.052f), 0.0045f, 8u);
        gunCapsule(loop, o, d, float3(0.0f, -0.040f, -0.052f),
            float3(0.0f, -0.052f, -0.088f), 0.0045f, 8u);
        gunCapsule(loop, o, d, float3(0.0f, -0.052f, -0.088f),
            float3(0.0f, -0.040f, -0.128f), 0.0045f, 8u);
        gunCapsule(loop, o, d, float3(0.0f, -0.040f, -0.128f),
            float3(0.0f, -0.004f, -0.135f), 0.0045f, 8u);
        if (loop.part != 0u)
            hit = {loop.distance, rotateSpiderPitch(loop.normal, -s, c), 8u,
                origin + direction * loop.distance};
    }
    // The straight-gripped stock dropping back from the receiver.
    float c = cos(0.20f), s = sin(0.20f);
    GunHit stock = {hit.distance, float3(0.0f), 0u, float3(0.0f)};
    gunBox(stock, rotateSpiderPitch(origin - float3(0.0f, 0.025f, 0.0f), -s, c),
        rotateSpiderPitch(direction, -s, c),
        float3(-0.0165f, -0.044f, -0.34f), float3(0.0165f, 0.010f, 0.0f), 7u);
    if (stock.part != 0u)
        hit = {stock.distance, rotateSpiderPitch(stock.normal, s, c), 7u,
            origin + direction * stock.distance};
    // The right hand grips the wrist with its fingers in the loop and
    // follows the lever down; the left cradles the fore-end.
    float3 normal;
    float t = pixeltje_3d::rayEllipsoid(origin, direction,
        float3(0.004f, -0.012f - 0.035f * lever, -0.068f),
        float3(0.036f, 0.044f, 0.046f), 0.001f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, 4u, origin + direction * t};
    t = pixeltje_3d::rayEllipsoid(origin, direction,
        float3(-0.004f, -0.004f, 0.300f), float3(0.039f, 0.032f, 0.066f),
        0.001f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, 4u, origin + direction * t};
    gunCapsule(hit, origin, direction, float3(0.021f, 0.024f, 0.282f),
        float3(0.019f, 0.028f, 0.336f), 0.011f, 4u);
    gunCapsule(hit, origin, direction, float3(-0.012f, -0.032f, 0.300f),
        float3(-0.17f, -0.31f, -0.02f), 0.045f, 5u);
    gunCapsule(hit, origin, direction,
        float3(0.012f, -0.055f - 0.035f * lever, -0.085f),
        float3(0.07f, -0.31f, -0.36f), 0.046f, 5u);
    return hit;
}

SurfaceMaterial rifleMaterial(GunHit hit) {
    float3 p = hit.local;
    if (hit.part == 9u) {
        // Case-hardened receiver: mottled blue, straw and brown temper
        // colours, a loading-gate seam on the right and two side-plate
        // screws.
        float mottle = smoothNoise(p.zy * 180.0f + p.x * 40.0f);
        float swirl = smoothNoise(p.zy * 520.0f + 7.0f);
        float3 colour = mix(mix(float3(0.05f, 0.07f, 0.11f),
                float3(0.20f, 0.13f, 0.06f), mottle),
            float3(0.30f, 0.24f, 0.12f), 0.35f * swirl * swirl);
        float seam = 0.0f;
        if (hit.normal.x > 0.5f) {
            float2 gate = abs(p.zy - float2(0.128f, 0.004f))
                - float2(0.024f, 0.010f);
            seam = 1.0f - smoothstep(0.0f, 0.0009f,
                abs(max(gate.x, gate.y)));
        }
        if (abs(hit.normal.x) > 0.5f) {
            seam = max(seam, 1.0f - smoothstep(0.0018f, 0.0026f,
                length(p.zy - float2(0.052f, 0.012f))));
            seam = max(seam, 1.0f - smoothstep(0.0018f, 0.0026f,
                length(p.zy - float2(0.090f, -0.008f))));
        }
        return {colour * (1.0f - 0.8f * seam), 0.32f + 0.3f * seam, 0.85f,
            float3(0.0f)};
    }
    bool bore = p.z > rifleMuzzle.z - 0.002f
        && length(p.xy - rifleMuzzle.xy) < 0.0058f;
    // Blued steel, worn bright along the edges and flats that catch the
    // hands.
    float wear = smoothstep(0.6f, 0.95f, abs(hit.normal.y))
        * (0.5f + 0.5f * smoothNoise(p.zx * float2(90.0f, 400.0f)));
    return {bore ? float3(0.004f) : mix(float3(0.030f, 0.036f, 0.052f),
            float3(0.20f, 0.21f, 0.22f), 0.3f * wear),
        bore ? 0.9f : 0.28f, bore ? 0.0f : 0.9f, float3(0.0f)};
}

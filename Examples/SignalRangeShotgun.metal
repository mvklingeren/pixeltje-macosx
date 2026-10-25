// Signal Range double-barrel shotgun: the weapon switch, Signal Range's
// automatic swap at the base exit, the break-action reload, and the
// viewmodel. Included by SignalRangeFPSProgram.metal and
// HauntedHouseProgram.metal after the pistol's pose.

constant float heldPistol = 0.0f;
constant float heldShotgun = 1.0f;
constant float heldLauncher = 2.0f;
constant float heldHand = 3.0f;         // bare hand; SignalRangeHand.metal
constant float shotgunShells = 2.0f;
constant float shotgunReloadDuration = 2.3f;
constant uint shotgunPellets = 8u;
// Half-angle of the pellet cone, in radians: about a metre wide at 20 m.
constant float shotgunSpread = 0.05f;
constant float weaponLowerTime = 0.22f;
constant float weaponRaiseTime = 0.30f;

void resetArms(device GameState &game) {
    game.arms = float4(heldPistol, 1.0f, shotgunShells, 0.0f);
}

bool holdingShotgun(device const GameState &game) {
    return game.arms.x > 0.5f && game.arms.x < 1.5f;
}

bool holdingLauncher(device const GameState &game) {
    return game.arms.x > 1.5f && game.arms.x < 2.5f;
}

bool holdingHand(device const GameState &game) {
    return game.arms.x > 2.5f && game.arms.x < 3.5f;
}

// Fully raised; a weapon being lowered or raised cannot fire.
bool armsReady(device const GameState &game) {
    return game.arms.y >= 1.0f;
}

// Puts `wanted` in hand: the held weapon is lowered out of view, swapped,
// then raised. An empty shotgun reloads meanwhile, in hand or not.
void switchArms(device GameState &game, float wanted, float dt) {
    if (wanted != game.arms.x) {
        game.arms.y = max(game.arms.y - dt / weaponLowerTime, 0.0f);
        if (game.arms.y <= 0.0f) game.arms.x = wanted;
    } else {
        game.arms.y = min(game.arms.y + dt / weaponRaiseTime, 1.0f);
    }
    // Both barrels empty: the gun breaks open and reloads by itself.
    if (game.arms.w > 0.0f) {
        game.arms.w = max(game.arms.w - dt, 0.0f);
        if (game.arms.w <= 0.0f) game.arms.z = shotgunShells;
    }
}

// Signal Range: stepping out onto the moon swaps the pistol for the
// shotgun, and stepping back inside swaps it back. The thresholds sit half
// a metre either side of the shell wall, so standing in the doorway never
// flickers between them. The launcher, once chosen, stays in hand anywhere.
void advanceArms(device GameState &game, float dt) {
    bool outside = outdoors(game.player.xz, holdingShotgun(game) ? -0.5f : 0.5f);
    switchArms(game, game.arsenal.x > 0.5f ? heldLauncher
        : (outside ? heldShotgun : heldPistol), dt);
}

// How far the held weapon is lowered for a switch: 0 raised, 1 out of view.
float weaponLowered(device const GameState &game) {
    return 1.0f - smoothstep(0.0f, 1.0f, game.arms.y);
}

// The shotgun's frame matches the pistol's: X right, Y up, Z along the
// barrels, origin at the wrist of the stock where the right hand grips it.
// The right barrel fires first, then the left.
float3 shotgunMuzzle(float barrel) {
    return float3(barrel < 0.5f ? 0.0115f : -0.0115f, 0.035f, 0.612f);
}

// The barrel that fired last: one shell left means the right one.
float3 shotgunLastMuzzle(device const GameState &game) {
    return shotgunMuzzle(game.arms.z > 0.5f ? 0.0f : 1.0f);
}

GunPose shotgunPose(device const GameState &game) {
    float reload = game.arms.w > 0.0f
        ? sin(rangePi * (1.0f - game.arms.w / shotgunReloadDuration)) : 0.0f;
    float kick = game.recoil.z;
    float bob = game.motion.w, phase = game.motion.z;
    float2 sway = game.look.zw;
    float lowered = weaponLowered(game);
    // Held lower and further out than the pistol. A shot shoves it back
    // into the shoulder; a reload tips the barrels down and rolls the gun.
    float3 pivot = float3(0.13f, -0.19f, 0.30f) + float3(
        0.012f * bob * sin(phase) - 0.007f * sway.x,
        -0.009f * bob * abs(cos(phase)) - 0.007f * sway.y
            + 0.014f * kick - 0.08f * reload - 0.34f * lowered
            - 0.5f * game.hurt.w,
        -0.075f * kick);
    float pitch = 0.20f * kick - 0.42f * reload - 0.9f * lowered
        - 0.02f * sway.y;
    float yaw = -0.035f * sway.x - 0.12f * reload;
    float roll = -0.38f * reload;
    float3 f = float3(sin(yaw) * cos(pitch), sin(pitch),
        cos(yaw) * cos(pitch));
    float3 r = normalize(float3(f.z, 0.0f, -f.x));
    float3 up = cross(f, r);
    return {pivot, float3x3(r * cos(roll) + up * sin(roll),
        up * cos(roll) - r * sin(roll), f), 0.0f};
}

// The pose and muzzle of whichever weapon is in hand, in view space.
GunPose heldPose(device const GameState &game) {
    if (holdingLauncher(game)) return launcherPose(game);
    return holdingShotgun(game) ? shotgunPose(game) : gunPose(game);
}

float3 heldMuzzle(device const GameState &game) {
    GunPose pose = heldPose(game);
    return pose.pivot + pose.basis * (holdingLauncher(game) ? launcherMuzzle
        : (holdingShotgun(game) ? shotgunLastMuzzle(game) : gunMuzzle));
}

// Parts: 3 dark steel, 4 glove, 5 sleeve, 6 blued barrels, 7 walnut.
GunHit traceShotgun(float3 origin, float3 direction) {
    GunHit hit = {1.0e6f, float3(0.0f), 0u, float3(0.0f)};
    if (raySphere(origin, direction, float3(0.0f, -0.06f, 0.14f), 0.62f)
        < 0.0f) return hit;
    for (uint side = 0u; side < 2u; ++side) {
        float x = side == 0u ? 0.0115f : -0.0115f;
        gunCapsule(hit, origin, direction, float3(x, 0.035f, 0.03f),
            float3(x, 0.035f, 0.600f), 0.0115f, 6u);
    }
    // Sighting rib along the top, and the receiver the barrels hinge on.
    gunBox(hit, origin, direction, float3(-0.0035f, 0.044f, 0.05f),
        float3(0.0035f, 0.0505f, 0.590f), 3u);
    gunBox(hit, origin, direction, float3(-0.021f, 0.004f, -0.045f),
        float3(0.021f, 0.047f, 0.050f), 3u);
    gunBox(hit, origin, direction, float3(-0.0045f, -0.020f, -0.020f),
        float3(0.0045f, 0.004f, 0.030f), 3u);
    // Splinter fore-end under the barrels, and the stock dropping back
    // from the wrist toward the shoulder.
    gunBox(hit, origin, direction, float3(-0.019f, 0.006f, 0.115f),
        float3(0.019f, 0.030f, 0.330f), 7u);
    float c = cos(0.20f), s = sin(0.20f);
    GunHit stock = {hit.distance, float3(0.0f), 0u, float3(0.0f)};
    gunBox(stock, rotateSpiderPitch(origin - float3(0.0f, 0.02f, -0.045f), -s, c),
        rotateSpiderPitch(direction, -s, c),
        float3(-0.019f, -0.034f, -0.33f), float3(0.019f, 0.022f, 0.0f), 7u);
    if (stock.part != 0u)
        hit = {stock.distance, rotateSpiderPitch(stock.normal, s, c), 7u,
            origin + direction * stock.distance};
    // The right hand holds the wrist; the left cradles the fore-end.
    float3 normal;
    float t = pixeltje_3d::rayEllipsoid(origin, direction,
        float3(0.004f, -0.012f, -0.075f), float3(0.036f, 0.044f, 0.046f),
        0.001f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, 4u, origin + direction * t};
    t = pixeltje_3d::rayEllipsoid(origin, direction,
        float3(-0.004f, -0.004f, 0.225f), float3(0.040f, 0.033f, 0.068f),
        0.001f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, 4u, origin + direction * t};
    gunCapsule(hit, origin, direction, float3(0.022f, 0.026f, 0.205f),
        float3(0.020f, 0.030f, 0.262f), 0.011f, 4u);
    gunCapsule(hit, origin, direction, float3(-0.012f, -0.035f, 0.205f),
        float3(-0.17f, -0.31f, -0.10f), 0.045f, 5u);
    gunCapsule(hit, origin, direction, float3(0.012f, -0.055f, -0.095f),
        float3(0.07f, -0.31f, -0.37f), 0.046f, 5u);
    return hit;
}

SurfaceMaterial shotgunMaterial(GunHit hit) {
    float3 p = hit.local;
    if (hit.part == 6u) {
        bool bore = p.z > 0.597f && (length(p.xy - shotgunMuzzle(0.0f).xy) < 0.0078f
            || length(p.xy - shotgunMuzzle(1.0f).xy) < 0.0078f);
        // Blued steel, worn bright along the upper edge.
        float wear = smoothstep(0.6f, 0.95f, hit.normal.y)
            * (0.5f + 0.5f * smoothNoise(p.zx * float2(90.0f, 400.0f)));
        return {bore ? float3(0.004f) : mix(float3(0.035f, 0.04f, 0.055f),
                float3(0.20f, 0.21f, 0.22f), 0.35f * wear),
            bore ? 0.9f : 0.30f, bore ? 0.0f : 0.9f, float3(0.0f)};
    }
    // Walnut: dark open grain running along the stock and fore-end.
    float grain = smoothNoise(float2(p.z * 26.0f, p.y * 260.0f + p.x * 140.0f));
    float figure = 0.5f + 0.5f * sin(p.z * 70.0f + grain * 9.0f);
    return {mix(float3(0.12f, 0.05f, 0.022f), float3(0.24f, 0.11f, 0.045f),
            figure) * (0.8f + 0.25f * grain),
        0.42f, 0.0f, float3(0.0f)};
}

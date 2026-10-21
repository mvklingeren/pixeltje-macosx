// Signal Range arsenal and sentries: the Javelin-style launcher's seeker,
// missile and blast, the sentry turrets and their plasma bolts, and the
// supply pickups. Included by SignalRangeFPSProgram.metal after the spiders,
// the shotgun and the drones.

float tickStep(constant ProgramUniforms &u) {
    return clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.10f);
}

bool bossCutscene(device const GameState &game) {
    return game.bossScene.x >= 0.0f && game.bossScene.x < 5.0f;
}

// MARK: Sentries

float3 sentryBase(device const GameState &game, uint i) {
    return float3(sentryGround[i].x, game.sentryFloor[i], sentryGround[i].y);
}

float sentryRestYaw(uint i) {
    float2 toward = sentryWatch[i] - sentryGround[i];
    return atan2(toward.x, -toward.y);
}

bool sentryMaterial(uint material) {
    return material >= sentryArmourMaterial && material <= sentryWreckMaterial;
}

bool sentryAlive(device const GameState &game, uint i) {
    return game.sentryState[i].x > 0.0f;
}

// The head turns on its column; a destroyed sentry slumps forward.
struct SentryFrame {
    float3 base;
    float3 head;
    float3 front;
    float3 right;
    float3 up;
};

SentryFrame sentryFrame(device const GameState &game, uint i) {
    float3 base = sentryBase(game, i);
    float wreck = sentryAlive(game, i) ? 0.0f
        : smoothstep(0.0f, 0.5f, game.effects.x - game.sentryState[i].z);
    float3 front = pixeltje_3d::forward(game.sentryAim[i].x,
        mix(game.sentryAim[i].y, -0.62f, wreck));
    float3 right = normalize(cross(front, float3(0.0f, 1.0f, 0.0f)));
    return {base, base + float3(0.0f, 1.35f - 0.2f * wreck, 0.0f), front,
        right, cross(right, front)};
}

float3 sentryMuzzle(SentryFrame frame) {
    return frame.head + frame.front * 0.88f - frame.up * 0.04f;
}

// Tripod, column, armoured ball head with a collar, twin barrels and a red
// sensor eye. Returns material 0 when nothing nearer than limit is hit.
SpiderHit traceSentry(float3 origin, float3 direction,
    device const GameState &game, uint i, float limit) {
    SpiderHit hit = {limit, float3(0.0f), 0u, float3(0.0f)};
    if (raySphere(origin, direction, sentryBase(game, i)
        + float3(0.0f, 0.8f, 0.0f), 1.45f) < 0.0f) return hit;
    SentryFrame frame = sentryFrame(game, i);
    bool alive = sentryAlive(game, i);
    uint armour = alive ? sentryArmourMaterial : sentryWreckMaterial;
    float3 hub = frame.base + float3(0.0f, 0.78f, 0.0f);
    for (uint leg = 0u; leg < 3u; ++leg) {
        float angle = float(leg) * 2.0943951f + 0.5f;
        acceptSpiderLeg(hit, origin, direction, hub,
            frame.base + float3(cos(angle) * 0.72f, 0.03f,
                sin(angle) * 0.72f), 0.045f, sentryMetalMaterial);
    }
    acceptSpiderLeg(hit, origin, direction, hub - float3(0.0f, 0.08f, 0.0f),
        frame.head - float3(0.0f, 0.2f, 0.0f), 0.1f, sentryMetalMaterial);
    acceptSpiderEllipsoid(hit, origin, direction,
        frame.head - float3(0.0f, 0.12f, 0.0f),
        float3(0.47f, 0.12f, 0.47f), armour);
    acceptSpiderSphere(hit, origin, direction, frame.head, 0.36f, armour);
    for (uint side = 0u; side < 2u; ++side) {
        float3 offset = frame.right * (side == 0u ? -0.14f : 0.14f)
            - frame.up * 0.04f;
        acceptSpiderLeg(hit, origin, direction,
            frame.head + offset + frame.front * 0.25f,
            frame.head + offset + frame.front * 0.88f, 0.048f,
            sentryMetalMaterial);
    }
    acceptSpiderSphere(hit, origin, direction,
        frame.head + frame.front * 0.36f + frame.up * 0.06f, 0.1f,
        alive ? sentrySensorMaterial : sentryMetalMaterial);
    return hit;
}

// Returns true when the damage destroyed the sentry.
bool damageSentry(device GameState &game, uint i, float amount) {
    if (!sentryAlive(game, i)) return false;
    game.sentryState[i].x -= amount;
    game.sentryState[i].y = 0.2f;
    game.sentryAim[i].z = 1.0f;
    if (game.sentryState[i].x > 0.0f) return false;
    game.sentryAim[i].w = -1.0f;
    game.sentryState[i].z = game.effects.x;
    game.pickups.z += 1u;
    return true;
}

// A sentry sweeps its room until it sees the player, then tracks them more
// slowly than a strafe can cross its view up close. Before each shot its
// sensor and a red laser charge for a moment; the bolt flies straight, so a
// sidestep after the tell dodges it. Returns true when it fired.
bool advanceSentry(device GameState &game, uint i, float dt) {
    game.sentryState[i].y = max(game.sentryState[i].y - dt, 0.0f);
    game.sentryState[i].w = max(game.sentryState[i].w - dt, 0.0f);
    if (!sentryAlive(game, i)) return false;
    float3 head = sentryBase(game, i) + float3(0.0f, 1.35f, 0.0f);
    float3 chest = game.player.xyz - float3(0.0f, 0.45f, 0.0f);
    float3 toPlayer = chest - head;
    float range = length(toPlayer);
    float3 toward = toPlayer / max(range, 0.001f);
    bool sees = range < 34.0f
        && spiderSeesPoint(game, head + toward * 0.5f, chest);
    if (sees) game.sentryAim[i].z = 1.0f;
    bool alert = game.sentryAim[i].z > 0.5f;
    float desiredYaw = game.sentryAim[i].x;
    float desiredPitch = 0.0f;
    if (sees) {
        desiredYaw = atan2(toPlayer.x, -toPlayer.z);
        desiredPitch = atan2(toPlayer.y, length(toPlayer.xz));
    } else if (!alert) {
        desiredYaw = sentryRestYaw(i)
            + 0.75f * sin(game.effects.x * 0.45f + float(i) * 1.7f);
    }
    float yawRate = alert ? 1.5f : 0.5f;
    float yaw = game.sentryAim[i].x;
    float yawDelta = atan2(sin(desiredYaw - yaw), cos(desiredYaw - yaw));
    yaw += clamp(yawDelta, -yawRate * dt, yawRate * dt);
    game.sentryAim[i].x = atan2(sin(yaw), cos(yaw));
    game.sentryAim[i].y += clamp(clamp(desiredPitch, -0.6f, 0.6f)
        - game.sentryAim[i].y, -dt, dt);
    float3 front = pixeltje_3d::forward(game.sentryAim[i].x,
        game.sentryAim[i].y);
    float aimError = acos(clamp(dot(front, toward), -1.0f, 1.0f));
    if (game.sentryAim[i].w >= 0.0f) {
        game.sentryAim[i].w += dt;
        if (game.sentryAim[i].w < sentryCharge) return false;
        game.sentryAim[i].w = -1.0f;
        game.sentryState[i].w = 1.4f;
        SentryFrame frame = sentryFrame(game, i);
        uint slot = game.pickups.w % boltCount;
        game.pickups.w += 1u;
        game.boltPosition[slot] = float4(sentryMuzzle(frame), game.effects.x);
        game.boltVelocity[slot] = float4(frame.front * sentryBoltSpeed, -1.0f);
        return true;
    }
    if (sees && !bossCutscene(game) && aimError < 0.14f
        && game.sentryState[i].w <= 0.0f)
        game.sentryAim[i].w = 0.0f;
    return false;
}

bool boltInFlight(device const GameState &game, uint b) {
    return game.boltPosition[b].w > -50.0f && game.boltVelocity[b].w < 0.0f;
}

// Bolts fly straight until they strike the player or a surface, then burst.
void advanceBolt(device GameState &game, uint b, float dt, ChromePose chrome) {
    if (!boltInFlight(game, b)) return;
    if (game.effects.x - game.boltPosition[b].w > 3.0f) {
        game.boltPosition[b].w = -100.0f;
        return;
    }
    float3 position = game.boltPosition[b].xyz;
    float3 stride = game.boltVelocity[b].xyz * dt;
    float stepLength = length(stride);
    if (stepLength < 0.00001f) return;
    float3 direction = stride / stepLength;
    SceneHit hit = {stepLength, float3(0.0f), float3(0.0f), 0u, -1, 0u};
    traceEnvironment(hit, position, direction, chrome, game);
    float travel = hit.material != 0u ? hit.distance : stepLength;
    float3 chest = game.player.xyz - float3(0.0f, 0.6f, 0.0f);
    float along = clamp(dot(chest - position, direction), 0.0f, travel);
    float3 closest = position + direction * along;
    float2 apart = closest.xz - chest.xz;
    float rise = closest.y - chest.y;
    if (dot(apart, apart) < 0.45f * 0.45f && rise > -1.0f && rise < 0.75f) {
        damagePlayer(game, sentryBoltDamage,
            position.xz - direction.xz * 10.0f, 0.3f);
        game.boltPosition[b].xyz = closest;
        game.boltVelocity[b].w = game.effects.x;
        return;
    }
    game.boltPosition[b].xyz = position + direction * travel;
    if (hit.material != 0u) game.boltVelocity[b].w = game.effects.x;
}

// MARK: Pickups

float3 pickupCentre(uint i, float time) {
    return pickupGround[i] + float3(0.0f,
        0.5f + 0.07f * sin(time * 2.2f + float(i) * 1.9f), 0.0f);
}

bool pickupTaken(device const GameState &game, uint i) {
    return ((game.pickups.x >> i) & 1u) != 0u;
}

void tracePickups(thread SceneHit &hit, float3 origin, float3 direction,
    device const GameState &game) {
    for (uint i = 0u; i < pickupCount; ++i) {
        if (pickupTaken(game, i)) continue;
        float3 centre = pickupCentre(i, game.effects.x);
        float3 normal;
        float t = pixeltje_3d::rayBox(origin, direction,
            centre - pickupHalfSize, centre + pickupHalfSize, 0.01f, normal);
        if (t > 0.0f && t < hit.distance)
            hit = {t, normal, origin + direction * t, pickupMaterialID, -1, i};
    }
}

// Rocket caches carry an orange band; medkits a green cross on every face.
SurfaceMaterial pickupMaterial(SceneHit hit, float time) {
    float3 local = (hit.position - pickupCentre(hit.variant, time))
        / pickupHalfSize;
    if (hit.variant >= pickupMedkitStart) {
        float2 face = abs(hit.normal.y) > 0.5f ? local.xz
            : (abs(hit.normal.x) > 0.5f ? local.zy : local.xy);
        float2 a = abs(face);
        if ((a.x < 0.2f && a.y < 0.66f) || (a.y < 0.2f && a.x < 0.66f))
            return {float3(0.02f, 0.2f, 0.05f), 0.4f, 0.0f,
                float3(0.12f, 1.25f, 0.3f)};
        return {float3(0.60f, 0.62f, 0.60f), 0.45f, 0.0f, float3(0.0f)};
    }
    if (abs(local.x) < 0.14f)
        return {float3(0.3f, 0.12f, 0.02f), 0.4f, 0.0f,
            float3(1.6f, 0.55f, 0.08f)};
    float rim = step(0.9f, max(abs(local.y), abs(local.z)));
    return {mix(float3(0.085f, 0.10f, 0.055f), float3(0.03f), rim),
        0.7f, 0.15f, float3(0.0f)};
}

void collectPickups(device GameState &game) {
    for (uint i = 0u; i < pickupCount; ++i) {
        if (pickupTaken(game, i)) continue;
        float3 ground = pickupGround[i];
        float lift = game.player.y - 1.55f - ground.y;
        if (distance(game.player.xz, ground.xz) > 1.3f
            || lift < -0.6f || lift > 1.4f) continue;
        bool medkit = i >= pickupMedkitStart;
        if (medkit) {
            if (game.view.y >= 100.0f) continue;
            game.view.y = min(game.view.y + 40.0f, 100.0f);
        } else {
            if (game.arsenal.z + game.arsenal.w >= float(rocketLimit)) continue;
            game.arsenal.z = min(game.arsenal.z + 2.0f,
                float(rocketLimit) - game.arsenal.w);
            if (game.arsenal.w < 0.5f && game.launcher.z <= 0.0f)
                game.launcher.z = launcherReloadDuration;
        }
        game.pickups.x |= 1u << i;
        game.pickups.y = medkit ? 2u : 1u;
        game.dodge.z = game.effects.x;
    }
}

// MARK: Targets shared by the seeker and the blast

// Target IDs: 1–11 are spider slots + 1, 12–14 sentries + 12 and 15–17
// drones + 15; 0 is none.
constant uint firstSentryTarget = enemyCount + 1u;
constant uint firstDroneTarget = enemyCount + sentryCount + 1u;
constant uint targetCount = enemyCount + sentryCount + droneCount;

bool targetAlive(device const GameState &game, uint target) {
    if (target >= 1u && target < firstSentryTarget)
        return spiderActive(game, target - 1u);
    if (target >= firstSentryTarget && target < firstDroneTarget)
        return sentryAlive(game, target - firstSentryTarget);
    if (target >= firstDroneTarget && target <= targetCount)
        return droneFlying(game, target - firstDroneTarget);
    return false;
}

float3 targetPoint(device const GameState &game, uint target) {
    if (target < firstSentryTarget) return game.enemy[target - 1u].xyz;
    if (target < firstDroneTarget)
        return sentryBase(game, target - firstSentryTarget)
            + float3(0.0f, 1.3f, 0.0f);
    return game.drones[target - firstDroneTarget].pose.xyz;
}

float targetRadius(device const GameState &game, uint target) {
    if (target < firstSentryTarget)
        return 0.55f * spiderTraits(spiderVariantForSlot(target - 1u)).scale;
    return 0.45f;
}

// Returns true when the hit killed the spider. A killed spider is recorded
// as fallen so it stays on the floor.
bool damageSpider(device GameState &game, uint slot, float amount,
    float2 push) {
    game.enemy[slot].w -= amount;
    game.enemyClock[slot].z = 0.24f;
    if (slot == bossSlot) {
        game.reaction[slot].x = 0.12f;
    } else {
        game.reaction[slot].xyz = float3(0.32f, push);
        game.senses[slot].w = -1.0f;   // a hit interrupts a bite
        wakeSpider(game, slot, game.player.xz);
    }
    if (game.enemy[slot].w > 0.0f) return false;
    uint fallenIndex = game.progress.x;
    if (fallenIndex < targetKills) {
        game.fallen[fallenIndex].pose = float4(game.enemy[slot].xyz,
            game.enemyClock[slot].w);
        game.fallen[fallenIndex].motion = float4(game.gait[slot].x,
            game.gait[slot].y, game.effects.x,
            spiderBodyRise(game.effects.x, slot));
        game.fallen[fallenIndex].appearance = uint4(
            uint(spiderVariantForSlot(slot)), 0u, 0u, 0u);
    }
    game.progress.x += 1u;
    return true;
}

// MARK: Launcher, seeker and missile

// The seeker locks the target nearest the crosshair within its field while
// the launcher is raised and loaded. Holding a target in view for a second
// completes the lock; a completed lock follows its target over a wider field.
void updateSeeker(device GameState &game, float dt) {
    bool raised = holdingLauncher(game) && armsReady(game)
        && game.arsenal.w > 0.5f
        && game.missile.w < 0.0f && !bossCutscene(game);
    if (!raised) {
        game.launcher.xy = float2(0.0f);
        return;
    }
    float3 eye = game.player.xyz + eyeOffset(game);
    float3 aim = pixeltje_3d::forward(game.player.w, game.view.x);
    uint current = uint(game.launcher.x);
    uint best = 0u;
    float bestAngle = 0.105f;
    for (uint target = 1u; target <= targetCount; ++target) {
        if (!targetAlive(game, target)) continue;
        float3 offset = targetPoint(game, target) - eye;
        float range = length(offset);
        if (range < 3.0f || range > 90.0f) continue;
        float angle = acos(clamp(dot(offset / range, aim), -1.0f, 1.0f));
        float field = target == current && game.launcher.y >= 1.0f
            ? 0.22f : bestAngle;
        if (angle < field) {
            best = target;
            bestAngle = min(angle, bestAngle);
            if (target == current) break;
        }
    }
    if (best != 0u && !spiderSeesPoint(game, eye, targetPoint(game, best)))
        best = 0u;
    if (best == 0u) {
        game.launcher.y = max(game.launcher.y - dt * 3.0f, 0.0f);
        if (game.launcher.y <= 0.0f) game.launcher.x = 0.0f;
        return;
    }
    if (best != current) game.launcher.xy = float2(float(best), 0.0f);
    game.launcher.y = min(game.launcher.y + dt / lockDuration, 1.0f);
}

bool seekerLocked(device const GameState &game) {
    return game.launcher.x > 0.5f && game.launcher.y >= 1.0f;
}

// Fire and forget: a locked missile ejects, lights its motor, climbs above
// its target and dives onto it. Without a lock it flies straight.
void launchMissile(device GameState &game, float3 muzzle, float3 heading) {
    uint target = seekerLocked(game) ? uint(game.launcher.x) : 0u;
    game.missile = float4(muzzle, game.effects.x);
    game.missileVelocity = float4(heading * 14.0f, float(target));
    game.missileAim = float4(target != 0u ? targetPoint(game, target)
        : muzzle + heading * 100.0f, 0.0f);
    for (uint i = 0u; i < trailCount; ++i)
        game.trail[i] = float4(muzzle, -100.0f);
    game.arsenal.w = 0.0f;
    if (game.arsenal.z >= 1.0f) game.launcher.z = launcherReloadDuration;
    game.launcher.xy = float2(0.0f);
    game.launcher.w = 1.0f;
    game.recoil.x += 0.05f;
    game.recoil.w = max(game.recoil.w, 0.45f);
    hearGunshot(game);
}

// Interior ceiling height above a point; the moon has none.
float ceilingHeight(float2 p) {
    if (outdoors(p, 0.0f)) return moonCeiling;
    if (p.y < bossRoomSouth) return bossCeilingY;
    if (p.y < -outerRoomFar) return 9.0f;
    if (p.y < -outerRoomNear) return northernCeilingY;
    if (p.y < -mainRoomHalfExtent) return 6.7f;
    if (p.x > mainRoomHalfExtent) return 6.4f;
    if (p.x < -mainRoomHalfExtent) return 7.0f;
    return 5.5f;
}

// Which room, passage or the moon a point is in: the boss arena with its
// staging bay, its corridor, the four rooms and their three stair passages.
uint rangeRoom(float2 p) {
    if (outdoors(p, 0.0f)) return 9u;
    if (p.y < bossRoomSouth) return 8u;
    if (p.y < -outerRoomFar) return 7u;
    if (p.y < -outerRoomNear) return 1u;
    if (p.y < -mainRoomHalfExtent) return 4u;
    if (p.x > outerRoomNear) return 2u;
    if (p.x > mainRoomHalfExtent) return 5u;
    if (p.x < -outerRoomNear) return 3u;
    if (p.x < -mainRoomHalfExtent) return 6u;
    return 0u;
}

// Doorways are 3.5 m high, so a missile only climbs once it shares a room
// with its target.
bool sameSpace(float2 a, float2 b) {
    return rangeRoom(a) == rangeRoom(b);
}

float3 turnToward(float3 from, float3 to, float maximumAngle) {
    float cosine = clamp(dot(from, to), -1.0f, 1.0f);
    if (acos(cosine) <= maximumAngle) return to;
    float3 across = to - from * cosine;
    float acrossLength = length(across);
    if (acrossLength < 0.00001f) return from;
    return normalize(from * cos(maximumAngle)
        + across / acrossLength * sin(maximumAngle));
}

// The blast hurts spiders, sentries, drones and the player by distance,
// throws the player clear (a rocket jump), shakes the view and wakes nearby
// spiders.
void detonateMissile(device GameState &game, float3 point,
    device RangeAudio &audio) {
    game.blast = float4(point, game.effects.x);
    game.missile = float4(point, -1.0f);
    uint target = uint(game.missileVelocity.w);
    bool topAttack = game.missileAim.w > 0.5f;
    bool hit = false, killed = false;
    for (uint slot = 0u; slot < enemyCount; ++slot) {
        if (!spiderActive(game, slot)) continue;
        float scale = spiderTraits(spiderVariantForSlot(slot)).scale;
        float gap = max(distance(point, game.enemy[slot].xyz)
            - 0.5f * scale, 0.0f);
        if (gap >= blastRadius) continue;
        // The boss's hide shrugs off part of a blast, so rockets alone
        // cannot carry the fight.
        float damage = mix(6.0f, 1.0f, gap / blastRadius)
            * (topAttack && target == slot + 1u ? 1.4f : 1.0f)
            * (slot == bossSlot ? 0.6f : 1.0f);
        float2 away = game.enemy[slot].xz - point.xz;
        float2 push = length(away) > 0.01f
            ? normalize(away) * 4.0f * (1.0f - gap / blastRadius)
            : float2(0.0f);
        hit = true;
        killed = damageSpider(game, slot, damage, push) || killed;
    }
    for (uint i = 0u; i < sentryCount; ++i) {
        if (!sentryAlive(game, i)) continue;
        float gap = max(distance(point, sentryBase(game, i)
            + float3(0.0f, 1.3f, 0.0f)) - 0.4f, 0.0f);
        if (gap >= blastRadius) continue;
        hit = true;
        killed = damageSentry(game, i, mix(8.0f, 2.0f, gap / blastRadius))
            || killed;
    }
    if (hit)
        game.weapon.zw = killed ? float2(0.40f, 3.0f) : float2(0.30f, 2.0f);
    // A drone takes three hits; a close blast deals all of them.
    for (uint i = 0u; i < droneCount; ++i) {
        if (!droneFlying(game, i)) continue;
        float3 away = game.drones[i].pose.xyz - point;
        float gap = max(length(away) - 0.3f, 0.0f);
        if (gap >= blastRadius) continue;
        uint hits = gap < 1.5f ? 3u : (gap < 3.0f ? 2u : 1u);
        float3 shove = length(away) > 0.01f ? normalize(away)
            : float3(0.0f, 1.0f, 0.0f);
        for (uint k = 0u; k < hits; ++k)
            damageDrone(game, i, shove, 1.0f, audio);
    }
    float3 body = game.player.xyz - float3(0.0f, 0.75f, 0.0f);
    float gap = distance(point, body);
    if (gap < blastRadius) {
        float strength = 1.0f - gap / blastRadius;
        damagePlayer(game, mix(4.0f, 34.0f, strength), point.xz, 0.4f);
        float2 away = body.xz - point.xz;
        if (length(away) > 0.01f)
            game.motion.xy += normalize(away) * 9.0f * strength;
        game.effects.w = max(game.effects.w, 7.5f * strength);
    }
    game.recoil.w = max(game.recoil.w,
        1.3f * (1.0f - saturate(distance(point, game.player.xyz) / 28.0f)));
    for (uint i = 0u; i < ordinaryEnemyCount; ++i)
        if (distance(game.enemy[i].xz, point.xz) < 26.0f)
            wakeSpider(game, i, game.player.xz);
}

// Returns true when the missile detonated this tick.
bool flyMissile(device GameState &game, float dt, ChromePose chrome,
    device RangeAudio &audio) {
    float age = game.effects.x - game.missile.w;
    float3 position = game.missile.xyz;
    float3 velocity = game.missileVelocity.xyz;
    float3 heading = normalize(velocity);
    uint target = uint(game.missileVelocity.w);
    if (target != 0u && targetAlive(game, target))
        game.missileAim.xyz = targetPoint(game, target);
    if (target != 0u && age > 0.2f) {
        float3 aim = game.missileAim.xyz;
        float cruise = min(aim.y + 6.0f, min(ceilingHeight(position.xz),
            ceilingHeight(aim.xz)) - 0.9f);
        if (!sameSpace(position.xz, aim.xz)) cruise = min(cruise, 2.6f);
        // Tip over into the dive while the target is still well ahead, so
        // the turn finishes before the missile passes over it.
        if (game.missileAim.w < 0.5f && length(aim.xz - position.xz)
            < max(position.y - aim.y, 1.0f) * 1.6f + 2.5f)
            game.missileAim.w = 1.0f;
        float3 goal = game.missileAim.w > 0.5f ? aim
            : float3(aim.x, max(cruise, aim.y + 0.5f), aim.z);
        heading = turnToward(heading, normalize(goal - position),
            (game.missileAim.w > 0.5f ? 9.0f : 2.6f) * dt);
    }
    // Soft launch: the motor lights 0.2 s after ejection.
    float speed = age < 0.2f ? 14.0f : min(14.0f + (age - 0.2f) * 36.0f, 30.0f);
    float stepLength = speed * dt;
    game.missileVelocity.xyz = heading * speed;
    uint previousPuff = uint(max(age - dt, 0.0f) / trailInterval);
    uint puff = uint(age / trailInterval);
    if (puff != previousPuff || age <= dt)
        game.trail[puff % trailCount] = float4(position, game.effects.x);
    if (stepLength <= 0.0f) return false;
    SceneHit hit = {stepLength, float3(0.0f), float3(0.0f), 0u, -1, 0u};
    traceEnvironment(hit, position, heading, chrome, game);
    float travel = hit.material != 0u ? hit.distance : stepLength;
    bool burst = hit.material != 0u || age > 7.0f;
    // Proximity fuse: spiders and sentries along this step.
    for (uint candidate = 1u; candidate <= targetCount; ++candidate) {
        if (!targetAlive(game, candidate)) continue;
        float3 centre = targetPoint(game, candidate);
        float along = clamp(dot(centre - position, heading), 0.0f, travel);
        if (distance(position + heading * along, centre)
            < targetRadius(game, candidate) + 0.35f) {
            travel = along;
            burst = true;
        }
    }
    position += heading * travel;
    if (burst) {
        detonateMissile(game, position - heading * 0.1f, audio);
        return true;
    }
    game.missile.xyz = position;
    return false;
}

// The seeker feed replaces the view while a missile flies, and lingers on
// its blast for a moment.
bool flightCamActive(device const GameState &game) {
    if (game.controls.y < 0.5f || game.progress.w != phasePlaying) return false;
    if (game.missile.w >= 0.0f) return game.effects.x - game.missile.w > 0.12f;
    return game.blast.w >= 0.0f && game.effects.x - game.blast.w < 0.8f;
}

void flightCamera(device const GameState &game, thread float3 &origin,
    thread float3 &front) {
    float3 heading = normalize(game.missileVelocity.xyz);
    if (game.missile.w >= 0.0f) {
        origin = game.missile.xyz + heading * 0.15f;
        front = heading;
        return;
    }
    origin = game.blast.xyz - heading * 4.5f + float3(0.0f, 1.4f, 0.0f);
    front = normalize(game.blast.xyz - origin);
}

// MARK: Ordnance rendering

void traceMissile(thread SceneHit &hit, float3 origin, float3 direction,
    device const GameState &game) {
    if (game.missile.w < 0.0f) return;
    float3 heading = normalize(game.missileVelocity.xyz);
    SpiderHit body = {hit.distance, float3(0.0f), 0u, float3(0.0f)};
    acceptSpiderLeg(body, origin, direction,
        game.missile.xyz - heading * 1.0f, game.missile.xyz - heading * 0.08f,
        0.064f, missileMaterial);
    if (body.material != 0u)
        hit = {body.distance, body.normal, origin + direction * body.distance,
            missileMaterial, -1, 0u};
}

// Distance from a view ray to a point, and how far along the ray it lies.
float2 rayPointGap(float3 origin, float3 direction, float3 point) {
    float depth = dot(point - origin, direction);
    return float2(length(origin + direction * depth - point), depth);
}

// Motor flame, smoke trail, fireball and sparks, depth-tested against the
// opaque scene.
float3 shadeOrdnance(float3 color, float3 origin, float3 direction,
    float sceneDistance, device const GameState &game) {
    float time = game.effects.x;
    // The smoke trail: soft tubes between puffs that widen and thin out.
    for (uint i = 0u; i < trailCount; ++i) {
        float4 puff = game.trail[i];
        float age = time - puff.w;
        if (age < 0.0f || age > 2.2f) continue;
        float4 next = game.trail[(i + 1u) % trailCount];
        float3 end = next.w > puff.w && next.w - puff.w < 1.5f * trailInterval
            ? next.xyz
            : (game.missile.w >= 0.0f && time - puff.w < 1.5f * trailInterval
                ? game.missile.xyz : puff.xyz);
        float3 segment = end - puff.xyz;
        float segmentSquared = max(dot(segment, segment), 0.0001f);
        float3 fromStart = origin - puff.xyz;
        float alongRay = dot(direction, segment);
        float fraction = clamp((dot(segment, fromStart)
            - alongRay * dot(direction, fromStart))
            / max(segmentSquared - alongRay * alongRay, 0.0001f), 0.0f, 1.0f);
        float3 closest = puff.xyz + segment * fraction;
        float2 gap = rayPointGap(origin, direction, closest);
        float radius = 0.07f + 0.32f * age;
        if (gap.y <= 0.0f || gap.y >= sceneDistance || gap.x > radius) continue;
        float density = (1.0f - smoothstep(0.2f * radius, radius, gap.x))
            * (1.0f - smoothstep(0.3f, 2.2f, age)) * 0.55f;
        color = mix(color, float3(0.07f, 0.07f, 0.075f), density);
    }
    if (game.missile.w >= 0.0f && time - game.missile.w > 0.2f) {
        float3 heading = normalize(game.missileVelocity.xyz);
        float2 gap = rayPointGap(origin, direction,
            game.missile.xyz - heading * 1.08f);
        if (gap.y > 0.0f && gap.y < sceneDistance + 0.1f) {
            float flicker = 0.85f + 0.15f * sin(time * 97.0f);
            color += float3(3.2f, 1.6f, 0.45f) * flicker
                * ((1.0f - smoothstep(0.0f, 0.06f, gap.x))
                + 0.2f * (1.0f - smoothstep(0.06f, 0.25f, gap.x)));
        }
    }
    float age = time - game.blast.w;
    if (game.blast.w < 0.0f || age < 0.0f || age > 3.0f) return color;
    float2 gap = rayPointGap(origin, direction, game.blast.xyz);
    float fire = 1.0f - smoothstep(0.0f, 0.55f, age);
    float radius = 0.4f + 3.0f * (1.0f - exp(-age * 9.0f)) + 0.5f * age;
    if (gap.y > 0.0f && gap.y - radius < sceneDistance) {
        float depth = sqrt(max(radius * radius - gap.x * gap.x, 0.0f));
        // Only the part of the ball in front of the scene shows.
        float visible = saturate((sceneDistance - (gap.y - depth))
            / max(2.0f * depth, 0.001f));
        float core = (1.0f - smoothstep(0.0f, radius, gap.x)) * visible;
        float3 hot = mix(float3(6.0f, 3.2f, 1.2f), float3(2.6f, 0.7f, 0.12f),
            smoothstep(0.0f, 0.35f, age));
        color += hot * core * core * fire;
        float smoke = core * smoothstep(0.15f, 0.5f, age)
            * (1.0f - smoothstep(1.2f, 3.0f, age));
        color = mix(color, float3(0.07f, 0.065f, 0.06f), 0.7f * smoke);
    }
    for (uint spark = 0u; spark < 18u; ++spark) {
        float key = float(spark) * 7.31f + 1.0f;
        float life = 0.45f + 0.5f * fract(sin(key * 12.9898f) * 43758.5453f);
        if (age >= life) continue;
        float angle = 2.0f * rangePi * fract(sin(key * 78.233f) * 12345.678f);
        float rise = fract(sin(key * 39.346f) * 28675.433f);
        float3 heading = normalize(float3(cos(angle), 0.3f + rise, sin(angle)));
        float3 centre = game.blast.xyz + heading * (9.0f * age)
            - float3(0.0f, 4.9f * age * age, 0.0f);
        float2 sparkGap = rayPointGap(origin, direction, centre);
        if (sparkGap.y <= 0.0f || sparkGap.y >= sceneDistance) continue;
        float width = 0.025f + 0.002f * sparkGap.y;
        color += float3(2.4f, 1.1f, 0.25f)
            * (1.0f - smoothstep(width * 0.3f, width, sparkGap.x))
            * (1.0f - smoothstep(0.2f, life, age));
    }
    return color;
}

// Charging lasers, plasma bolts and bursts, and sparks from wrecks.
float3 shadeSentryEffects(float3 color, float3 origin, float3 direction,
    float sceneDistance, device const GameState &game) {
    float time = game.effects.x;
    for (uint i = 0u; i < sentryCount; ++i) {
        bool alive = sentryAlive(game, i);
        float charge = game.sentryAim[i].w;
        if (alive && charge < 0.0f) continue;
        SentryFrame frame = sentryFrame(game, i);
        if (!alive) {
            float cycle = fract(time * 0.7f + float(i) * 0.37f);
            float2 gap = rayPointGap(origin, direction,
                frame.head + frame.front * 0.3f);
            if (cycle < 0.12f && gap.y > 0.0f && gap.y < sceneDistance + 0.3f)
                color += float3(2.2f, 1.2f, 0.4f) * (1.0f - cycle / 0.12f)
                    * (1.0f - smoothstep(0.0f, 0.12f, gap.x));
            continue;
        }
        float3 start = sentryMuzzle(frame);
        float reach = max(distance(start, game.player.xyz
            - float3(0.0f, 0.45f, 0.0f)) - 0.4f, 0.5f);
        float3 segment = frame.front * reach;
        float3 fromStart = origin - start;
        float alongRay = dot(direction, segment);
        float fraction = clamp((dot(segment, fromStart)
            - alongRay * dot(direction, fromStart))
            / max(reach * reach - alongRay * alongRay, 0.0001f), 0.0f, 1.0f);
        float2 gap = rayPointGap(origin, direction, start + segment * fraction);
        if (gap.y <= 0.0f || gap.y >= sceneDistance) continue;
        float width = 0.006f + 0.0012f * gap.y;
        // Seen from the target the beam is a dot at the sensor, not a bar
        // reaching into the eye.
        float strength = (0.6f + 0.4f * sin(time * 40.0f))
            * smoothstep(1.5f, 5.0f, gap.y);
        color += float3(2.4f, 0.12f, 0.08f) * strength
            * smoothstep(0.0f, sentryCharge, charge)
            * ((1.0f - smoothstep(0.3f * width, width, gap.x))
            + 0.25f * (1.0f - smoothstep(width, 4.0f * width, gap.x)));
    }
    for (uint b = 0u; b < boltCount; ++b) {
        float4 bolt = game.boltPosition[b];
        if (bolt.w < -50.0f) continue;
        float burst = game.boltVelocity[b].w;
        if (burst < 0.0f) {
            float3 heading = normalize(game.boltVelocity[b].xyz);
            for (uint k = 0u; k < 3u; ++k) {
                float2 gap = rayPointGap(origin, direction,
                    bolt.xyz - heading * (0.22f * float(k)));
                if (gap.y <= 0.0f || gap.y >= sceneDistance + 0.1f) continue;
                float radius = (0.11f - 0.03f * float(k));
                color += float3(0.9f, 0.45f, 3.0f) / float(k + 1u)
                    * ((1.0f - smoothstep(0.3f * radius, radius, gap.x))
                    + 0.3f * (1.0f - smoothstep(radius, 4.0f * radius, gap.x)));
            }
        } else if (time - burst < 0.3f) {
            float age = time - burst;
            float2 gap = rayPointGap(origin, direction, bolt.xyz);
            float radius = 0.15f + 1.4f * age;
            if (gap.y > 0.0f && gap.y < sceneDistance + radius)
                color += float3(1.0f, 0.5f, 3.2f) * (1.0f - age / 0.3f)
                    * (1.0f - smoothstep(0.0f, radius, gap.x));
        }
    }
    return color;
}

// Blast scorch on any surface near the detonation.
float3 shadeScorch(float3 color, SceneHit hit, device const GameState &game) {
    if (game.blast.w < 0.0f || hit.material == 0u || hit.enemy >= 0)
        return color;
    float age = game.effects.x - game.blast.w;
    if (age < 0.0f || age > 12.0f) return color;
    float reach = distance(hit.position, game.blast.xyz);
    float burn = (1.0f - smoothstep(0.6f, 2.4f, reach))
        * (1.0f - smoothstep(9.0f, 12.0f, age));
    return color * (1.0f - 0.8f * burn);
}

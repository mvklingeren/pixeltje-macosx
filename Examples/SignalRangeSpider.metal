// Signal Range spider geometry, locomotion, and pursuit behavior.
// Included by SignalRangeFPSProgram.metal after shared game state.

constant float spiderChaseSpeed = 1.8f;

enum class SpiderVariant : uint {
    brown = 0u,
    blackRedEyes = 1u
};

struct SpiderTraits {
    float scale;
    float frontLegReach;
    float legSpread;
    float legFan;
    float restExtension;
    float kneeHeight;
    float strideSpan;
    float stepLift;
    float bodyMotion;
    bool canJump;
    float jumpHeight;
    float jumpDuration;
    float jumpInterval;
};

SpiderTraits spiderTraits(SpiderVariant variant) {
    // Both variants share a walking cycle and jump behavior; proportions and
    // movement amplitudes define their different silhouettes.
    if (variant == SpiderVariant::blackRedEyes)
        return {0.35f, 0.70f, 1.08f, 0.70f, 0.66f, 0.44f,
            0.84f, 0.34f, 0.22f, true, 0.28f, 0.46f, 2.0f};
    return {0.70f, 0.0f, 0.0f, 0.0f, 1.0f, 0.11f,
        0.48f, 0.23f, 1.0f, false, 0.28f, 0.46f, 2.0f};
}

float spiderFootprintRadius(SpiderTraits traits) {
    return (1.5f + traits.frontLegReach + traits.legSpread
        + 0.5f * traits.legFan) * traits.scale;
}

SpiderVariant spiderVariantForSlot(uint slot) {
    return slot == 2u ? SpiderVariant::blackRedEyes : SpiderVariant::brown;
}

float spiderBodyBob(float phase, float movementBlend,
    SpiderTraits traits) {
    return traits.bodyMotion * movementBlend
        * (0.048f * sin(phase * 4.0f * rangePi)
        + 0.012f * sin(phase * 2.0f * rangePi + 1.1f));
}

float spiderBodyRise(float time, uint slot) {
    SpiderTraits traits = spiderTraits(spiderVariantForSlot(slot));
    return 0.014f * (float(slot) - 1.0f)
        + traits.bodyMotion * 0.013f
            * sin(time * 1.9f + float(slot) * 2.2f);
}

float3 spawnPosition(uint slot) {
    float2 initial[3] = {
        float2(-9.5f, -8.0f), float2(9.0f, -10.0f),
        float2(0.0f, -14.0f)
    };
    float2 xz = initial[slot];
    SpiderTraits traits = spiderTraits(spiderVariantForSlot(slot));
    return float3(xz.x, 0.52f * traits.scale, xz.y);
}

float spiderJumpLift(SpiderTraits traits, bool pursuing, float dt,
    thread float &clock) {
    if (!traits.canJump) return 0.0f;
    // Negative time counts down to takeoff; nonnegative time is the jump arc.
    if (clock < 0.0f) {
        if (pursuing) clock = min(0.0f, clock + dt);
    } else {
        clock += dt;
        if (clock >= traits.jumpDuration) {
            clock = -traits.jumpInterval;
            return 0.0f;
        }
    }
    return clock >= 0.0f
        ? traits.jumpHeight * sin(rangePi * clock / traits.jumpDuration)
        : 0.0f;
}

float raySphere(float3 origin, float3 direction, float3 center, float radius) {
    return pixeltje_3d::raySphere(origin, direction, center, radius, 0.01f);
}

struct SpiderHit {
    float distance;
    float3 normal;
    uint material;
    float3 furPosition;
};

float smoothNoise(float2 p);

void acceptSpiderSphere(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 centre, float radius, uint material) {
    float t = raySphere(origin, direction, centre, radius);
    if (t > 0.0f && t < hit.distance) {
        hit = {t, normalize(origin + direction * t - centre),
            material, origin + direction * t - centre};
    }
}

void acceptSpiderEllipsoid(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 centre, float3 radii, uint material) {
    float3 normal;
    float t = pixeltje_3d::rayEllipsoid(origin, direction, centre,
        radii, 0.01f, normal);
    if (t > 0.0f && t < hit.distance) {
        hit = {t, normal,
            material, origin + direction * t - centre};
    }
}

void acceptSpiderLeg(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 start, float3 end, float radius,
    uint material) {
    float3 axis = end - start;
    float3 offset = origin - start;
    float axisSquared = dot(axis, axis);
    float axisDirection = dot(axis, direction);
    float axisOffset = dot(axis, offset);
    float a = axisSquared - axisDirection * axisDirection;
    float b = axisSquared * dot(offset, direction)
        - axisOffset * axisDirection;
    float c = axisSquared * (dot(offset, offset) - radius * radius)
        - axisOffset * axisOffset;
    float discriminant = b * b - a * c;
    if (a > 0.00001f && discriminant >= 0.0f) {
        float t = (-b - sqrt(discriminant)) / a;
        float along = axisOffset + t * axisDirection;
        if (t > 0.01f && t < hit.distance
            && along > 0.0f && along < axisSquared) {
            float3 closest = start + axis * (along / axisSquared);
            hit = {t, normalize(origin + direction * t - closest),
                material, origin + direction * t - start};
        }
    }
    acceptSpiderSphere(hit, origin, direction, start, radius, material);
    acceptSpiderSphere(hit, origin, direction, end, radius, material);
}

float3 spiderLegCorner(uint corner, float3 sideways, float3 upwards) {
    if (corner == 0u) return upwards;
    return -0.5f * upwards
        + (corner == 1u ? 0.8660254f : -0.8660254f) * sideways;
}

bool clipSpiderLegFace(float3 origin, float3 direction,
    float3 point, float3 outward, thread float &entry,
    thread float &exit, thread float3 &entryNormal,
    thread float3 &exitNormal) {
    float facing = dot(outward, direction);
    float side = dot(outward, origin - point);
    if (abs(facing) < 0.000001f) return side <= 0.0f;
    float distance = -side / facing;
    if (facing < 0.0f) {
        if (distance > entry) {
            entry = distance;
            entryNormal = outward;
        }
    } else if (distance < exit) {
        exit = distance;
        exitNormal = outward;
    }
    return entry <= exit;
}

void acceptSpiderFacetedLeg(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 start, float3 end,
    float startRadius, float endRadius) {
    // A three-sided tapered prism gives the black legs flat, sharp facets.
    // The round knee is traced separately where the two prisms meet.
    float3 axis = normalize(end - start);
    float3 guide = abs(axis.y) < 0.9f
        ? float3(0.0f, 1.0f, 0.0f)
        : float3(0.0f, 0.0f, 1.0f);
    float3 sideways = normalize(cross(axis, guide));
    float3 upwards = cross(sideways, axis);
    float3 interior = (start + end) * 0.5f;
    float entry = -1000000.0f, exit = 1000000.0f;
    float3 entryNormal = float3(0.0f);
    float3 exitNormal = float3(0.0f);
    if (!clipSpiderLegFace(origin, direction, start, -axis,
            entry, exit, entryNormal, exitNormal)
        || !clipSpiderLegFace(origin, direction, end, axis,
            entry, exit, entryNormal, exitNormal)) return;
    for (uint side = 0u; side < 3u; ++side) {
        float3 radialA = spiderLegCorner(side, sideways, upwards);
        float3 radialB = spiderLegCorner((side + 1u) % 3u,
            sideways, upwards);
        float3 a = start + radialA * startRadius;
        float3 b = start + radialB * startRadius;
        float3 c = end + radialA * endRadius;
        float3 normal = cross(b - a, c - a);
        if (dot(normal, interior - a) > 0.0f) normal = -normal;
        if (!clipSpiderLegFace(origin, direction, a, normal,
                entry, exit, entryNormal, exitNormal)) return;
    }
    float distance = entry > 0.01f ? entry : exit;
    if (distance > 0.01f && distance < hit.distance) {
        hit = {distance, normalize(entry > 0.01f
            ? entryNormal : exitNormal), 15u,
            origin + direction * distance - start};
    }
}

void acceptSpiderPaw(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 foot) {
    // Test the small paw volume before tracing its separate furry toe lobes.
    float3 paw = foot + float3(0.0f, 0.045f, -0.035f);
    float bound = raySphere(origin, direction, paw, 0.34f);
    if (bound < 0.0f || (dot(origin - paw, origin - paw) > 0.1156f
        && bound >= hit.distance)) return;

    float previousDistance = hit.distance;
    acceptSpiderEllipsoid(hit, origin, direction, paw,
        float3(0.19f, 0.12f, 0.20f), 18u);
    for (uint toe = 0u; toe < 3u; ++toe) {
        float spread = (float(toe) - 1.0f) * 0.09f;
        acceptSpiderEllipsoid(hit, origin, direction,
            paw + float3(spread, -0.022f, -0.13f),
            float3(0.055f, 0.065f, 0.09f), 18u);
    }
    if (hit.distance < previousDistance)
        hit.furPosition = origin + direction * hit.distance - paw;
}

void acceptSpiderEyes(thread SpiderHit &hit, float3 origin,
    float3 direction, SpiderVariant variant) {
    float3 eyeRegion = float3(0.0f, 0.16f, -0.62f);
    float bound = raySphere(origin, direction, eyeRegion, 0.55f);
    if (bound < 0.0f || (dot(origin - eyeRegion, origin - eyeRegion)
        > 0.3025f && bound >= hit.distance)) return;

    if (variant == SpiderVariant::blackRedEyes) {
        // The black variant has only two red corneas, with no extra socket
        // spheres that could read as additional eyes.
        for (uint side = 0u; side < 2u; ++side) {
            float signX = side == 0u ? -1.0f : 1.0f;
            acceptSpiderSphere(hit, origin, direction,
                float3(signX * 0.17f, 0.13f, -0.75f), 0.095f, 16u);
        }
        return;
    }

    // Eight differently sized corneas sit in recessed dark sockets.
    for (uint side = 0u; side < 2u; ++side) {
        float signX = side == 0u ? -1.0f : 1.0f;
        for (uint eye = 0u; eye < 4u; ++eye) {
            float3 centre;
            float radius;
            if (eye == 0u) {
                centre = float3(signX * 0.14f, 0.085f, -0.75f);
                radius = 0.082f;
            } else if (eye == 1u) {
                centre = float3(signX * 0.28f, 0.105f, -0.665f);
                radius = 0.055f;
            } else if (eye == 2u) {
                centre = float3(signX * 0.085f, 0.255f, -0.67f);
                radius = 0.047f;
            } else {
                centre = float3(signX * 0.245f, 0.225f, -0.605f);
                radius = 0.044f;
            }
            acceptSpiderSphere(hit, origin, direction,
                centre + float3(0.0f, 0.0f, radius * 0.85f),
                radius * 1.28f, 19u);
            acceptSpiderSphere(hit, origin, direction,
                centre, radius, 16u);
        }
    }
}

float3 rotateSpiderPitch(float3 point, float sine, float cosine) {
    return float3(point.x,
        cosine * point.y - sine * point.z,
        sine * point.y + cosine * point.z);
}

// A single articulated ray test serves both the camera and the gun. Local -Z
// is forward; the stored yaw turns the chassis toward the player.
SpiderHit traceSpider(float3 origin, float3 direction, float3 centre,
    SpiderVariant variant, float yaw, float gaitPhase,
    float movementBlend, float bodyRise,
    float collapse, float maxDistance) {
    SpiderTraits traits = spiderTraits(variant);
    float cosine = cos(yaw), sine = sin(yaw);
    // Keep the authored geometry in one local scale for both gun hits and
    // drawing; converting the final distance preserves world-space depth.
    float3 offset = (origin - centre) / traits.scale;
    float3 localOrigin = float3(cosine * offset.x + sine * offset.z,
        offset.y, -sine * offset.x + cosine * offset.z);
    float3 localDirection = float3(
        cosine * direction.x + sine * direction.z, direction.y,
        -sine * direction.x + cosine * direction.z);
    float localMaxDistance = maxDistance / traits.scale;
    SpiderHit hit = {localMaxDistance, float3(0.0f), 0u, float3(0.0f)};
    float farthestFootX = 1.19f + traits.legSpread + 0.22f * collapse;
    float farthestFootZ = 0.67f + traits.legFan
        + traits.frontLegReach + 0.5f * traits.strideSpan;
    float boundRadius = max(2.15f,
        length(float2(farthestFootX, farthestFootZ)) + 0.30f);
    float bound = raySphere(localOrigin, localDirection,
        float3(0.0f), boundRadius);
    if (bound < 0.0f
        || (dot(localOrigin, localOrigin) > boundRadius * boundRadius
        && bound >= localMaxDistance)) {
        hit.distance = maxDistance;
        return hit;
    }

    // The front lifts as a walk starts, then rocks gently with the steps.
    // Trace the pitched body separately so all six feet remain grounded.
    float startLift = sin(rangePi * clamp(movementBlend, 0.0f, 1.0f));
    float pitch = (0.23f * startLift + 0.12f * movementBlend
        * sin(gaitPhase * 2.0f * rangePi - 0.5f))
        * traits.bodyMotion * (1.0f - collapse) - 0.32f * collapse;
    float sinePitch = sin(pitch), cosinePitch = cos(pitch);
    float3 bodyOrigin = rotateSpiderPitch(
        localOrigin - float3(0.0f, bodyRise, 0.0f),
        -sinePitch, cosinePitch);
    float3 bodyDirection = rotateSpiderPitch(
        localDirection, -sinePitch, cosinePitch);
    SpiderHit bodyHit = {localMaxDistance,
        float3(0.0f), 0u, float3(0.0f)};

    acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, -0.02f, 0.29f), float3(0.55f, 0.32f, 0.61f), 5u);
    acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, 0.03f, -0.37f), float3(0.41f, 0.29f, 0.40f), 17u);
    acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, 0.20f, 0.28f), float3(0.44f, 0.15f, 0.45f), 17u);
    for (uint side = 0u; side < 2u; ++side) {
        float signX = side == 0u ? -1.0f : 1.0f;
        for (uint tuft = 0u; tuft < 4u; ++tuft) {
            acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
                float3(signX * 0.44f, 0.10f,
                    -0.05f + float(tuft) * 0.27f),
                float3(0.16f, 0.14f, 0.15f), 5u);
        }
        acceptSpiderEllipsoid(bodyHit, bodyOrigin, bodyDirection,
            float3(signX * 0.32f, -0.02f, -0.50f),
            float3(0.16f, 0.15f, 0.19f), 17u);
    }
    acceptSpiderEyes(bodyHit, bodyOrigin, bodyDirection, variant);
    if (bodyHit.material != 0u) {
        bodyHit.normal = rotateSpiderPitch(
            bodyHit.normal, sinePitch, cosinePitch);
        hit = bodyHit;
    }
    // Tuck the black spider's legs in while resting, then extend them as its
    // movement blend rises. Brown legs keep their original resting spread.
    float reachBlend = mix(traits.restExtension, 1.0f,
        clamp(movementBlend, 0.0f, 1.0f));
    float legSpread = traits.legSpread * reachBlend;
    float legFan = traits.legFan * reachBlend;
    for (uint side = 0u; side < 2u; ++side) {
        float signX = side == 0u ? -1.0f : 1.0f;
        for (uint leg = 0u; leg < 3u; ++leg) {
            float z = -0.42f + float(leg) * 0.42f;
            float forwardReach = leg == 0u
                ? traits.frontLegReach * reachBlend : 0.0f;
            // Opposite tripods alternate. Local -Z is forward: planted tips
            // sweep rearward as the chassis advances, then lift and reach
            // forward for the next contact.
            float phase = fract(gaitPhase
                + (((leg + side) & 1u) != 0u ? 0.5f : 0.0f));
            float stride, lift = 0.0f;
            if (phase < 0.6f) {
                // The linear planted sweep matches the distance-based phase,
                // keeping the tip near one ground position while walking.
                stride = traits.strideSpan * (phase / 0.6f - 0.5f);
            } else {
                float swing = (phase - 0.6f) / 0.4f;
                float eased = smoothstep(0.0f, 1.0f, swing);
                stride = traits.strideSpan * (0.5f - eased);
                lift = traits.stepLift * sin(rangePi * eased);
            }
            lift *= movementBlend;
            float bob = spiderBodyBob(gaitPhase, movementBlend, traits);
            float3 hip = rotateSpiderPitch(
                float3(signX * 0.33f, -0.08f, z),
                sinePitch, cosinePitch)
                + float3(0.0f, bodyRise, 0.0f);
            float fan = (float(leg) - 1.0f) * legFan;
            float3 knee = float3(signX * (0.83f
                    + 0.55f * legSpread + 0.15f * collapse),
                mix(traits.kneeHeight, -0.10f, collapse)
                    + lift * 0.35f,
                z + (float(leg) - 1.0f) * 0.13f
                    + fan * 0.5f + stride * 0.5f
                    - forwardReach * 0.45f);
            float3 foot = float3(signX * (1.19f
                    + legSpread + 0.22f * collapse),
                mix((variant == SpiderVariant::blackRedEyes
                    ? -0.52f : -0.45f) - bob, -0.37f, collapse) + lift,
                z + (float(leg) - 1.0f) * 0.25f + stride
                    + fan - forwardReach);
            if (variant == SpiderVariant::blackRedEyes) {
                acceptSpiderFacetedLeg(hit, localOrigin, localDirection,
                    hip, knee, 0.10f, 0.17f);
                acceptSpiderFacetedLeg(hit, localOrigin, localDirection,
                    knee, foot, 0.17f, 0.025f);
                acceptSpiderSphere(hit, localOrigin, localDirection,
                    knee, 0.165f, 17u);
            } else {
                acceptSpiderLeg(hit, localOrigin, localDirection,
                    hip, knee, 0.12f, 15u);
                acceptSpiderLeg(hit, localOrigin, localDirection,
                    knee, foot, 0.095f, 15u);
                acceptSpiderSphere(hit, localOrigin, localDirection,
                    knee, 0.14f, 17u);
                acceptSpiderEllipsoid(hit, localOrigin, localDirection,
                    mix(knee, foot, 0.38f),
                    float3(0.14f, 0.14f, 0.16f), 15u);
                acceptSpiderPaw(hit, localOrigin, localDirection, foot);
            }
        }
    }
    float3 n = hit.normal;
    if (hit.material == 5u
        || (hit.material == 15u
            && variant != SpiderVariant::blackRedEyes)
        || hit.material == 17u || hit.material == 18u) {
        // Stronger normal variation gives the enlarged coat visible depth.
        float3 fibers = float3(
            smoothNoise(hit.furPosition.yz * 79.0f),
            smoothNoise(hit.furPosition.xz * 73.0f),
            smoothNoise(hit.furPosition.xy * 83.0f)) - 0.5f;
        n = normalize(n + fibers * 0.34f);
    }
    hit.normal = float3(cosine * n.x - sine * n.z, n.y,
        sine * n.x + cosine * n.z);
    hit.distance *= traits.scale;
    return hit;
}

bool spiderPositionClear(float2 position, uint self,
    device const GameState &game) {
    if (!walkable(position)) return false;
    float selfRadius = spiderFootprintRadius(
        spiderTraits(spiderVariantForSlot(self)));
    for (uint other = 0u; other < enemyCount; ++other) {
        if (other == self || game.enemy[other].w <= 0.0f) continue;
        float minimumSeparation = selfRadius + spiderFootprintRadius(
            spiderTraits(spiderVariantForSlot(other)));
        float2 offset = position - game.enemy[other].xz;
        if (dot(offset, offset) < minimumSeparation * minimumSeparation)
            return false;
    }
    return true;
}

float2 moveSpider(float2 position, float2 step, uint self,
    device const GameState &game) {
    float2 next = position + step;
    if (spiderPositionClear(next, self, game)) return next;

    // The rendered feet extend beyond the chassis. Use a circular ground
    // footprint and slide around the nearest living spider when blocked.
    uint blocker = enemyCount;
    float selfRadius = spiderFootprintRadius(
        spiderTraits(spiderVariantForSlot(self)));
    float closest = 1.0e30f;
    for (uint other = 0u; other < enemyCount; ++other) {
        if (other == self || game.enemy[other].w <= 0.0f) continue;
        float minimumSeparation = selfRadius + spiderFootprintRadius(
            spiderTraits(spiderVariantForSlot(other)));
        float2 offset = next - game.enemy[other].xz;
        float distanceSquared = dot(offset, offset);
        if (distanceSquared < minimumSeparation * minimumSeparation
            && distanceSquared < closest) {
            closest = distanceSquared;
            blocker = other;
        }
    }
    if (blocker == enemyCount) return position;

    float2 away = position - game.enemy[blocker].xz;
    float distanceSquared = dot(away, away);
    away = distanceSquared > 0.000001f
        ? away * rsqrt(distanceSquared) : float2(1.0f, 0.0f);
    float2 tangent = float2(-away.y, away.x);
    float sideways = dot(step, tangent);
    if (abs(sideways) < length(step) * 0.2f)
        sideways = (self & 1u) == 0u ? length(step) : -length(step);
    float2 slide = position + tangent * sideways;
    return spiderPositionClear(slide, self, game) ? slide : position;
}

void advanceSpiders(device GameState &game, float dt) {
    for (uint i = 0u; i < enemyCount; ++i) {
        game.enemyClock[i].x = max(game.enemyClock[i].x - dt, 0.0f);
        game.enemyClock[i].z = max(game.enemyClock[i].z - dt, 0.0f);
        if (game.enemy[i].w <= 0.0f) continue;
        SpiderTraits traits = spiderTraits(spiderVariantForSlot(i));
        float attackRange = 1.65f * traits.scale;
        float2 toPlayer = game.player.xz - game.enemy[i].xz;
        float distanceToPlayer = length(toPlayer);
        bool pursuing = distanceToPlayer > attackRange;
        if (pursuing) {
            float desiredYaw = atan2(toPlayer.x, -toPlayer.y);
            float delta = desiredYaw - game.enemyClock[i].w;
            float shortestTurn = atan2(sin(delta), cos(delta));
            float desiredTurnRate = clamp(shortestTurn * 4.0f,
                -2.4f, 2.4f);
            game.gait[i].w = mix(game.gait[i].w, desiredTurnRate,
                1.0f - exp(-dt * 6.0f));
            float turn = game.gait[i].w * dt;
            if (abs(turn) >= abs(shortestTurn)) {
                game.enemyClock[i].w = desiredYaw;
                game.gait[i].w = 0.0f;
            } else {
                game.enemyClock[i].w += turn;
            }
        } else {
            game.gait[i].w = 0.0f;
        }
        float2 oldPosition = game.enemy[i].xz;
        float walkBlend = mix(game.gait[i].y, pursuing ? 1.0f : 0.0f,
            1.0f - exp(-dt * 7.0f));
        if (pursuing) {
            // Two smooth, differently timed rhythms give each spider slow
            // approaches and brief rushes without a walk/pause switch.
            float slot = float(i);
            float slowPace = smoothNoise(float2(
                game.effects.x * 0.37f + slot * 2.17f,
                slot * 5.31f + 0.73f));
            float quickPace = smoothNoise(float2(
                game.effects.x * 1.07f + slot * 3.41f,
                slot * 7.19f + 2.13f));
            float targetSpeed = spiderChaseSpeed
                * (0.38f + 0.95f * slowPace + 0.22f * quickPace);
            float speedResponse = targetSpeed > game.gait[i].z
                ? 1.8f : 2.8f;
            game.gait[i].z = mix(game.gait[i].z, targetSpeed,
                1.0f - exp(-dt * speedResponse));
            float yaw = game.enemyClock[i].w;
            float2 nextEnemy = oldPosition
                + float2(sin(yaw), -cos(yaw))
                    * min(game.gait[i].z * walkBlend * dt,
                        distanceToPlayer - attackRange);
            game.enemy[i].xz = moveSpider(oldPosition,
                nextEnemy - oldPosition, i, game);
        } else {
            game.gait[i].z *= exp(-dt * 3.0f);
        }
        if (distanceToPlayer <= attackRange
            && game.enemyClock[i].x <= 0.0f) {
            game.view.y = max(game.view.y - 12.0f, 0.0f);
            game.effects.y = 0.35f;
            game.enemyClock[i].x = 1.2f;
        }
        float travel = length(game.enemy[i].xz - oldPosition);
        game.gait[i].x = fract(game.gait[i].x
            + 0.6f * travel / (traits.strideSpan * traits.scale));
        game.gait[i].y = pursuing && travel > 0.0001f
            ? walkBlend
            : mix(game.gait[i].y, 0.0f, 1.0f - exp(-dt * 7.0f));
        float jumpClock = game.enemyClock[i].y;
        float jumpLift = spiderJumpLift(traits, pursuing, dt, jumpClock);
        game.enemyClock[i].y = jumpClock;
        game.enemy[i].y = stairHeight(game.enemy[i].xz)
            + traits.scale * (0.52f
                + spiderBodyBob(game.gait[i].x, game.gait[i].y,
                    traits))
            + jumpLift;
    }
}

SurfaceMaterial spiderSurfaceMaterial(uint material, float3 furPosition,
    SpiderVariant variant) {
    if (material == 16u) return {
        variant == SpiderVariant::blackRedEyes
            ? float3(0.12f, 0.012f, 0.014f)
            : float3(0.012f, 0.019f, 0.023f),
        0.045f, 0.02f,
        variant == SpiderVariant::blackRedEyes
            ? float3(0.42f, 0.012f, 0.008f)
            : float3(0.0f)};
    if (material == 19u) return {
        variant == SpiderVariant::blackRedEyes
            ? float3(0.025f, 0.005f, 0.006f)
            : float3(0.035f, 0.018f, 0.012f),
        0.82f, 0.0f, float3(0.0f)};
    if (material == 5u || material == 15u
        || material == 17u || material == 18u) {
        // Body, legs, joints and paws all use primitive-local fur coordinates,
        // so the coat follows the spider's turns and articulated gait.
        float fibers = 0.5f * smoothNoise(
            furPosition.xy * 68.0f + furPosition.z * 13.0f)
            + 0.5f * smoothNoise(
                furPosition.zy * 74.0f + furPosition.x * 17.0f);
        float flecks = hashTile(floor(furPosition.xz * 95.0f)
            + floor(furPosition.y * 37.0f));
        float mottling = smoothNoise(
            furPosition.xy * 8.0f + furPosition.z * 2.0f);
        float3 root = float3(0.18f, 0.09f, 0.045f);
        float3 tip = float3(0.43f, 0.26f, 0.13f);
        if (material == 5u) {
            root = float3(0.12f, 0.075f, 0.05f);
            tip = float3(0.34f, 0.23f, 0.15f);
        } else if (material == 17u) {
            root = float3(0.24f, 0.12f, 0.055f);
            tip = float3(0.58f, 0.36f, 0.18f);
        } else if (material == 18u) {
            root = float3(0.23f, 0.11f, 0.055f);
            tip = float3(0.56f, 0.33f, 0.17f);
        }
        if (variant == SpiderVariant::blackRedEyes) {
            root = float3(0.006f, 0.008f, 0.011f);
            tip = material == 17u
                ? float3(0.085f, 0.094f, 0.10f)
                : float3(0.049f, 0.055f, 0.063f);
        }
        float3 coat = mix(root, tip, fibers)
            * (0.84f + 0.25f * flecks)
            * (0.83f + 0.28f * mottling);
        return {coat, 0.94f, 0.0f, float3(0.0f)};
    }
    return {float3(0.0f), 1.0f, 0.0f, float3(0.0f)};
}

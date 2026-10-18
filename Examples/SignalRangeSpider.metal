// Signal Range spider geometry, locomotion, and pursuit behavior.
// Included by SignalRangeFPSProgram.metal after shared game state.

constant float spiderChaseSpeed = 1.8f;

enum class SpiderVariant : uint {
    brown = 0u,
    blackRedEyes = 1u,
    bossBlack = 2u
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
    if (variant == SpiderVariant::bossBlack)
        return {3.30f, 0.75f, 1.05f, 0.72f, 0.79f, 0.50f,
            0.84f, 0.30f, 0.18f, false, 0.0f, 0.0f, 0.0f};
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
    return slot == bossSlot ? SpiderVariant::bossBlack
        : slot == 2u ? SpiderVariant::blackRedEyes : SpiderVariant::brown;
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
    // The third spider waits out of sight in the north room for the ambush.
    float2 initial[4] = {
        float2(-9.5f, -8.0f), float2(9.0f, -10.0f),
        float2(0.0f, -38.0f), float2(0.0f, -118.0f)
    };
    float2 xz = initial[slot];
    SpiderTraits traits = spiderTraits(spiderVariantForSlot(slot));
    return float3(xz.x, stairHeight(xz) + 0.52f * traits.scale, xz.y);
}

// Unaware range spiders face away from the start so the player can open fire.
float idleYaw(uint slot) {
    return slot == 0u ? -0.5f * rangePi : (slot == 1u ? 0.0f : rangePi);
}

// Dead spiders and the ambush spider before it drops are neither drawn nor hit.
bool spiderActive(device const GameState &game, uint slot) {
    return game.enemy[slot].w > 0.0f && game.senses[slot].z >= 0.0f;
}

bool bossEnraged(device const GameState &game) {
    return game.enemy[bossSlot].w <= 7.0f;
}

float bossWindup(device const GameState &game) {
    return bossEnraged(game) ? 0.36f : 0.48f;
}

// How far the front of a spider rears up: before a bite or rush, and briefly
// when a shot lands.
float spiderRear(device const GameState &game, uint slot) {
    float rear = 0.0f;
    if (slot == bossSlot) {
        float charge = game.bossAttack.x;
        if (charge > 0.0f && charge < bossWindup(game))
            rear = smoothstep(0.0f, bossWindup(game), charge);
    } else if (game.senses[slot].w >= 0.0f) {
        float bite = game.senses[slot].w;
        rear = smoothstep(0.0f, 0.4f, bite)
            * (1.0f - smoothstep(biteWindup, 0.6f, bite));
    }
    return max(rear, 0.6f * smoothstep(0.0f, 0.32f, game.reaction[slot].x));
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
    float4 fur;     // strand tangent and height in coat lengths; zero off fur
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

// Furry parts are wrapped in a shell one coat deep. A ray entering the shell
// marches toward the core and stops at the first procedural strand; a ray
// that slips between strands reaches the core or leaves the shell again,
// which gives the silhouette its loose, hairy edge.
constant float spiderFurDensity = 55.0f;    // strand cells per local unit
constant float spiderFurLean = 1.25f;       // tip offset along the comb, in coats
// One pixel spans about 1 / (focal 1.1 * 900 rows) radians. Strands never get
// thinner than a pixel, so a distant coat reads as solid instead of sparkling.
// shortcut: assumes the 900-row default preview; pass the real resolution in
// if much larger or smaller previews alias or look blobby.
constant float spiderFurPixelAngle = 0.001f;

struct SpiderFurPoint {
    float height;   // above the core surface, in local units
    float3 normal;
    float3 comb;    // surface tangent the coat lies along
};

// Shapes are a capsule from a to b with the given radius, or an ellipsoid at a
// with radii b when the radius is zero.
SpiderFurPoint spiderFurPoint(float3 p, float3 a, float3 b, float radius) {
    SpiderFurPoint point;
    if (radius > 0.0f) {
        // Leg hair lies toward the foot.
        float3 axis = b - a;
        float3 offset = p - a
            - axis * saturate(dot(p - a, axis) / dot(axis, axis));
        float distance = length(offset);
        point = {distance - radius, offset / max(distance, 0.0001f), axis};
    } else {
        // Body hair lies rearward (+Z) and down the flanks.
        float3 gradient = (p - a) / (b * b);
        float k0 = length((p - a) / b), k1 = length(gradient);
        point = {k0 * (k0 - 1.0f) / k1, gradient / k1,
            float3(0.0f, -0.45f, 1.0f)};
    }
    float3 comb = point.comb - point.normal * dot(point.comb, point.normal);
    point.comb = length(comb) > 0.001f ? normalize(comb)
        : normalize(cross(point.normal, abs(point.normal.x) < 0.9f
            ? float3(1.0f, 0.0f, 0.0f) : float3(0.0f, 1.0f, 0.0f)));
    return point;
}

// Strand-cell coordinates of a root: around and along a capsule, or on the
// cube face an ellipsoid direction projects onto. A cell holds one strand.
float2 spiderFurCell(float3 root, float3 a, float3 b, float radius) {
    if (radius > 0.0f) {
        float3 axis = normalize(b - a);
        float3 side = normalize(cross(axis, abs(axis.y) < 0.9f
            ? float3(0.0f, 1.0f, 0.0f) : float3(0.0f, 0.0f, 1.0f)));
        float3 offset = root - a;
        // A whole number of cells around the leg hides the atan2 seam.
        float around = max(round(
            2.0f * rangePi * radius * spiderFurDensity), 3.0f);
        float angle = atan2(dot(offset, cross(side, axis)),
            dot(offset, side));
        return float2((angle / (2.0f * rangePi) + 0.5f) * around,
            dot(offset, axis) * spiderFurDensity);
    }
    float3 q = (root - a) / b;
    float3 m = abs(q);
    // Whole-number face offsets keep neighbouring faces' strands distinct.
    if (m.x >= m.y && m.x >= m.z)
        return q.yz / m.x * b.yz * spiderFurDensity
            + float2(q.x > 0.0f ? 70.0f : 140.0f, 0.0f);
    if (m.y >= m.z)
        return q.xz / m.y * b.xz * spiderFurDensity
            + float2(q.y > 0.0f ? 210.0f : 280.0f, 0.0f);
    return q.xy / m.z * b.xy * spiderFurDensity
        + float2(q.z > 0.0f ? 350.0f : 420.0f, 0.0f);
}

// Each cell grows one tapered strand with its own length and position.
bool spiderFurStrand(float2 cell, float height, float minimumWidth) {
    float2 id = floor(cell);
    float strandLength = 0.55f + 0.45f * hashTile(id + 23.17f);
    if (height > strandLength) return false;
    float width = clamp(0.34f * (1.0f - 0.8f * height / strandLength),
        minimumWidth, 0.5f);
    float2 centre = 0.5f + (float2(hashTile(id), hashTile(id + 41.3f))
        - 0.5f) * (1.0f - 2.0f * width);
    return distance(fract(cell), centre) < width;
}

void acceptSpiderFur(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 a, float3 b, float radius, float coat,
    uint material) {
    SpiderHit shell = {hit.distance, float3(0.0f), 0u, float3(0.0f)};
    SpiderHit core = shell;
    if (radius > 0.0f) {
        acceptSpiderLeg(shell, origin, direction, a, b, radius + coat,
            material);
        acceptSpiderLeg(core, origin, direction, a, b, radius, material);
    } else {
        acceptSpiderEllipsoid(shell, origin, direction, a, b + coat,
            material);
        acceptSpiderEllipsoid(core, origin, direction, a, b, material);
    }
    if (shell.material == 0u) return;
    // Steps shorter than a strand cell keep slanted rays from skipping strands.
    float step = 0.6f / spiderFurDensity;
    for (uint i = 0u; i < 24u; ++i) {
        float t = shell.distance + step * float(i);
        if (t >= core.distance) break;
        float3 p = origin + direction * t;
        SpiderFurPoint point = spiderFurPoint(p, a, b, radius);
        float height = max(point.height / coat, 0.0f);
        if (height > 1.0f) {
            if (dot(direction, point.normal) > 0.0f) break;
            continue;
        }
        // Strands rise from the root, then curve over along the comb.
        float3 root = p - point.comb
            * (coat * spiderFurLean * height * height);
        if (spiderFurStrand(spiderFurCell(root, a, b, radius), height,
                0.5f * t * spiderFurPixelAngle * spiderFurDensity)) {
            hit = {t, point.normal, material,
                root - point.normal * point.height - a,
                float4(normalize(point.normal
                    + point.comb * (2.0f * spiderFurLean * height)),
                    height)};
            return;
        }
    }
    if (core.material != 0u) {
        hit = core;
        hit.fur = float4(spiderFurPoint(origin + direction * core.distance,
            a, b, radius).comb, 0.0f);
    }
}

void acceptSpiderFurEllipsoid(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 centre, float3 radii, float coat,
    uint material) {
    acceptSpiderFur(hit, origin, direction, centre, radii, 0.0f, coat,
        material);
}

void acceptSpiderFurLeg(thread SpiderHit &hit, float3 origin,
    float3 direction, float3 start, float3 end, float radius, float coat,
    uint material) {
    acceptSpiderFur(hit, origin, direction, start, end, radius, coat,
        material);
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
    acceptSpiderFurEllipsoid(hit, origin, direction, paw,
        float3(0.19f, 0.12f, 0.20f), 0.045f, 18u);
    for (uint toe = 0u; toe < 3u; ++toe) {
        float spread = (float(toe) - 1.0f) * 0.09f;
        acceptSpiderFurEllipsoid(hit, origin, direction,
            paw + float3(spread, -0.022f, -0.13f),
            float3(0.055f, 0.065f, 0.09f), 0.022f, 18u);
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

    if (variant != SpiderVariant::brown) {
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
    float collapse, float rear, float maxDistance) {
    SpiderTraits traits = spiderTraits(variant);
    bodyRise += 0.10f * rear;
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
        * traits.bodyMotion * (1.0f - collapse) - 0.32f * collapse
        + 0.55f * rear;
    float sinePitch = sin(pitch), cosinePitch = cos(pitch);
    float3 bodyOrigin = rotateSpiderPitch(
        localOrigin - float3(0.0f, bodyRise, 0.0f),
        -sinePitch, cosinePitch);
    float3 bodyDirection = rotateSpiderPitch(
        localDirection, -sinePitch, cosinePitch);
    SpiderHit bodyHit = {localMaxDistance,
        float3(0.0f), 0u, float3(0.0f)};

    acceptSpiderFurEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, -0.02f, 0.29f), float3(0.55f, 0.32f, 0.61f),
        0.075f, 5u);
    // The head coat stays short so the eyes stand clear of it.
    acceptSpiderFurEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, 0.03f, -0.37f), float3(0.41f, 0.29f, 0.40f),
        0.045f, 17u);
    acceptSpiderFurEllipsoid(bodyHit, bodyOrigin, bodyDirection,
        float3(0.0f, 0.20f, 0.28f), float3(0.44f, 0.15f, 0.45f),
        0.06f, 17u);
    for (uint side = 0u; side < 2u; ++side) {
        float signX = side == 0u ? -1.0f : 1.0f;
        for (uint tuft = 0u; tuft < 4u; ++tuft) {
            acceptSpiderFurEllipsoid(bodyHit, bodyOrigin, bodyDirection,
                float3(signX * 0.44f, 0.10f,
                    -0.05f + float(tuft) * 0.27f),
                float3(0.16f, 0.14f, 0.15f), 0.06f, 5u);
        }
        acceptSpiderFurEllipsoid(bodyHit, bodyOrigin, bodyDirection,
            float3(signX * 0.32f, -0.02f, -0.50f),
            float3(0.16f, 0.15f, 0.19f), 0.04f, 17u);
    }
    acceptSpiderEyes(bodyHit, bodyOrigin, bodyDirection, variant);
    if (bodyHit.material != 0u) {
        bodyHit.normal = rotateSpiderPitch(
            bodyHit.normal, sinePitch, cosinePitch);
        bodyHit.fur.xyz = rotateSpiderPitch(
            bodyHit.fur.xyz, sinePitch, cosinePitch);
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
            // Rearing raises the front pair high and the middle pair a little.
            lift += rear * (leg == 0u ? 0.42f : (leg == 1u ? 0.10f : 0.0f));
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
                mix((variant != SpiderVariant::brown
                    ? -0.52f : -0.45f) - bob, -0.37f, collapse) + lift,
                z + (float(leg) - 1.0f) * 0.25f + stride
                    + fan - forwardReach);
            if (variant != SpiderVariant::brown) {
                acceptSpiderFacetedLeg(hit, localOrigin, localDirection,
                    hip, knee, 0.10f, 0.17f);
                acceptSpiderFacetedLeg(hit, localOrigin, localDirection,
                    knee, foot, 0.17f, 0.025f);
                acceptSpiderSphere(hit, localOrigin, localDirection,
                    knee, 0.165f, 17u);
            } else {
                acceptSpiderFurLeg(hit, localOrigin, localDirection,
                    hip, knee, 0.12f, 0.05f, 15u);
                acceptSpiderFurLeg(hit, localOrigin, localDirection,
                    knee, foot, 0.095f, 0.045f, 15u);
                acceptSpiderFurEllipsoid(hit, localOrigin, localDirection,
                    knee, float3(0.14f), 0.055f, 17u);
                acceptSpiderFurEllipsoid(hit, localOrigin, localDirection,
                    mix(knee, foot, 0.38f),
                    float3(0.14f, 0.14f, 0.16f), 0.055f, 15u);
                acceptSpiderPaw(hit, localOrigin, localDirection, foot);
            }
        }
    }
    float3 n = hit.normal;
    if (hit.material == 5u
        || (hit.material == 15u
            && variant == SpiderVariant::brown)
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
    float3 strand = hit.fur.xyz;
    hit.fur.xyz = float3(cosine * strand.x - sine * strand.z, strand.y,
        sine * strand.x + cosine * strand.z);
    hit.distance *= traits.scale;
    return hit;
}

// Bodies keep clear of the crates, the glass box and the chrome cube; the
// pad is a fraction of the leg footprint, so feet may still overlap them.
bool insideProp(float2 p, float pad) {
    return (all(p > float2(-4.1f, -3.1f) - pad)
            && all(p < float2(-1.8f, -0.7f) + pad))
        || (all(p > float2(2.1f, -6.5f) - pad)
            && all(p < float2(4.5f, -4.1f) + pad))
        || (all(p > glassBoxLower.xz - pad) && all(p < glassBoxUpper.xz + pad))
        || distance(p, chromeGroundPosition) < 1.25f + pad;
}

bool spiderPositionClear(float2 position, uint self,
    device const GameState &game) {
    if (!walkable(position) || (self != bossSlot && position.y < -outerRoomFar))
        return false;
    float selfRadius = spiderFootprintRadius(
        spiderTraits(spiderVariantForSlot(self)));
    if (insideProp(position, 0.45f * selfRadius)) return false;
    for (uint other = 0u; other < enemyCount; ++other) {
        if (other == self || !spiderActive(game, other)) continue;
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
        if (other == self || !spiderActive(game, other)) continue;
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
    if (blocker == enemyCount) {
        // Walls and props: slide along one axis at a time, like the player.
        float2 alongX = float2(next.x, position.y);
        if (spiderPositionClear(alongX, self, game)) return alongX;
        float2 alongZ = float2(position.x, next.y);
        return spiderPositionClear(alongZ, self, game) ? alongZ : position;
    }

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

// Coarse navigation: the start room is a hub with a passage and a room along
// each branch (0 north, 1 east, 2 west). A region is (branch, depth), with
// depth 0 for the hub, 1 for a passage and 2 for the room beyond it.
uint2 navRegion(float2 p) {
    if (p.y < -mainRoomHalfExtent)
        return uint2(0u, p.y < -outerRoomNear ? 2u : 1u);
    if (p.x > mainRoomHalfExtent)
        return uint2(1u, p.x > outerRoomNear ? 2u : 1u);
    if (p.x < -mainRoomHalfExtent)
        return uint2(2u, p.x < -outerRoomNear ? 2u : 1u);
    return uint2(0u, 0u);
}

// The next point to walk toward: the goal itself in the same region,
// otherwise just past the boundary into the next region along the route.
float2 navWaypoint(float2 from, float2 goal) {
    uint2 a = navRegion(from), b = navRegion(goal);
    if (a.y == b.y && (a.x == b.x || a.y == 0u)) return goal;
    uint branch = a.y == 0u ? b.x : a.x;
    bool inward = a.y != 0u && (a.x != b.x || b.y < a.y);
    uint nextDepth = inward ? a.y - 1u : a.y + 1u;
    float boundary = min(a.y, nextDepth) == 0u
        ? mainRoomHalfExtent : outerRoomNear;
    float2 axis = branch == 0u ? float2(0.0f, -1.0f)
        : (branch == 1u ? float2(1.0f, 0.0f) : float2(-1.0f, 0.0f));
    return axis * (boundary + (inward ? -0.8f : 0.8f));
}

bool spiderSeesPoint(device const GameState &game, float3 eye,
    float3 target) {
    float3 offset = target - eye;
    float distance = length(offset);
    SceneHit hit = {distance, float3(0.0f), float3(0.0f), 0u, -1, 0u};
    ChromePose chrome = {game.chromeRotation, game.chromeCentre.xyz};
    traceEnvironment(hit, eye, offset / max(distance, 0.0001f), chrome, game);
    return hit.material == 0u;
}

void wakeSpider(device GameState &game, uint slot, float2 lastKnown) {
    if (game.enemy[slot].w <= 0.0f || game.senses[slot].z < 0.0f) return;
    if (game.senses[slot].z > 0.5f) {
        game.senses[slot].xy = lastKnown;
        return;
    }
    // A startled spider turns to the threat before it moves, and rouses
    // unaware neighbours.
    game.senses[slot] = float4(lastKnown, 1.0f, -1.0f);
    game.reaction[slot].w = 0.45f;
    for (uint other = 0u; other < ordinaryEnemyCount; ++other) {
        if (other == slot || game.senses[other].z != 0.0f
            || game.enemy[other].w <= 0.0f
            || distance(game.enemy[other].xz, game.enemy[slot].xz) > 12.0f)
            continue;
        game.senses[other] = float4(lastKnown, 1.0f, -1.0f);
        game.reaction[other].w = 0.7f;
    }
}

// Gunfire carries through walls.
void hearGunshot(device GameState &game) {
    for (uint i = 0u; i < ordinaryEnemyCount; ++i)
        if (distance(game.enemy[i].xz, game.player.xz) < 26.0f)
            wakeSpider(game, i, game.player.xz);
}

// The ambush spider drops from the dark north ceiling ahead of the player.
void startAmbush(device GameState &game) {
    game.ambush = float4(game.effects.x + 0.2f, 0.0f, 0.0f, 0.0f);
    game.enemy[ambushSlot].xyz = float3(
        clamp(game.player.x, -10.0f, 10.0f), 16.5f, -38.0f);
}

void advanceSpiders(device GameState &game, float dt) {
    for (uint i = 0u; i < ordinaryEnemyCount; ++i) {
        game.enemyClock[i].x = max(game.enemyClock[i].x - dt, 0.0f);
        game.enemyClock[i].z = max(game.enemyClock[i].z - dt, 0.0f);
        game.reaction[i].x = max(game.reaction[i].x - dt, 0.0f);
        game.reaction[i].w = max(game.reaction[i].w - dt, 0.0f);
        if (game.enemy[i].w <= 0.0f) continue;
        SpiderTraits traits = spiderTraits(spiderVariantForSlot(i));
        float2 toPlayer = game.player.xz - game.enemy[i].xz;
        float distanceToPlayer = length(toPlayer);
        if (game.senses[i].z < 0.0f) {
            if (game.ambush.x < 0.0f || game.effects.x < game.ambush.x)
                continue;
            game.senses[i] = float4(game.player.xz, 1.0f, -1.0f);
        }
        if (i == ambushSlot && game.ambush.z < 0.5f) {
            // Falling legs-tucked; the landing stuns it for a moment.
            float landing = stairHeight(game.enemy[i].xz)
                + traits.scale * 0.52f;
            game.ambush.y -= 20.0f * dt;
            game.enemy[i].y += game.ambush.y * dt;
            game.enemyClock[i].w = atan2(toPlayer.x, -toPlayer.y);
            if (game.enemy[i].y <= landing) {
                game.enemy[i].y = landing;
                game.ambush.z = 1.0f;
                game.reaction[i].w = 0.5f;
                game.recoil.w = max(game.recoil.w,
                    0.5f * (1.0f - saturate(distanceToPlayer / 14.0f)));
            }
            continue;
        }

        float yaw = game.enemyClock[i].w;
        bool aware = game.senses[i].z > 0.5f;
        bool inView = dot(float2(sin(yaw), -cos(yaw)), toPlayer)
            > 0.42f * distanceToPlayer;
        bool sees = distanceToPlayer < 24.0f
            && (aware || inView || distanceToPlayer < 4.5f)
            && spiderSeesPoint(game, game.enemy[i].xyz
                + float3(0.0f, 0.3f * traits.scale + 0.1f, 0.0f),
                game.player.xyz);
        if (sees) {
            wakeSpider(game, i, game.player.xz);
            aware = true;
        }

        // A bite is telegraphed: the spider rears, then strikes whoever is
        // still within reach. Backing off or a hit avoids it.
        float attackRange = 1.65f * traits.scale;
        float playerLift = game.player.y - 1.55f - stairHeight(game.player.xz);
        bool busy = game.reaction[i].x > 0.0f || game.reaction[i].w > 0.0f;
        if (game.senses[i].w >= 0.0f) {
            float before = game.senses[i].w;
            game.senses[i].w += dt;
            if (before < biteWindup && game.senses[i].w >= biteWindup
                && distanceToPlayer <= attackRange * 1.3f && playerLift < 1.2f)
                damagePlayer(game, 12.0f, game.enemy[i].xz, 0.35f);
            if (game.senses[i].w >= 0.6f) {
                game.senses[i].w = -1.0f;
                game.enemyClock[i].x = 1.2f;
            }
        } else if (aware && sees && !busy && distanceToPlayer <= attackRange
            && game.enemyClock[i].x <= 0.0f) {
            game.senses[i].w = 0.0f;
        }
        bool biting = game.senses[i].w >= 0.0f;

        // Out of sight, a spider makes for where it last saw the player;
        // after that it homes on the player's noise.
        // shortcut: no search pattern or memory timeout; add one if spiders
        // tracking through walls feels unfair.
        float2 goal = game.player.xz;
        if (aware && !sees
            && distance(game.enemy[i].xz, game.senses[i].xy) > 1.2f)
            goal = game.senses[i].xy;
        float2 toWaypoint = navWaypoint(game.enemy[i].xz, goal)
            - game.enemy[i].xz;
        float desiredYaw = aware
            ? (biting || distanceToPlayer <= attackRange
                || length(toWaypoint) < 0.01f
                ? atan2(toPlayer.x, -toPlayer.y)
                : atan2(toWaypoint.x, -toWaypoint.y))
            : idleYaw(i) + 0.7f * sin(game.effects.x * 0.31f + float(i) * 2.0f);
        float maximumTurn = aware ? 2.4f : 0.7f;
        if (game.reaction[i].x <= 0.0f) {
            float delta = desiredYaw - yaw;
            float shortestTurn = atan2(sin(delta), cos(delta));
            float desiredTurnRate = clamp(shortestTurn * 4.0f,
                -maximumTurn, maximumTurn);
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

        bool pursuing = aware && !busy && !biting
            && distanceToPlayer > attackRange;
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
            float heading = game.enemyClock[i].w;
            float2 nextEnemy = oldPosition
                + float2(sin(heading), -cos(heading))
                    * min(game.gait[i].z * walkBlend * dt,
                        distanceToPlayer - attackRange);
            game.enemy[i].xz = moveSpider(oldPosition,
                nextEnemy - oldPosition, i, game);
        } else {
            game.gait[i].z *= exp(-dt * 3.0f);
        }
        // A hit shoves the spider back along the shot.
        if (game.reaction[i].x > 0.0f)
            game.enemy[i].xz = moveSpider(game.enemy[i].xz,
                game.reaction[i].yz * dt, i, game);
        game.reaction[i].yz *= exp(-dt * 7.0f);
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

bool bossPositionClear(float2 position) {
    // Keep the entire huge footprint inside the arena after the reveal.
    return abs(position.x) < 12.8f
        && position.y < bossRoomSouth - 4.5f
        && position.y > bossRoomNorth + 5.0f;
}

void advanceBoss(device GameState &game, float dt) {
    game.reaction[bossSlot].x = max(game.reaction[bossSlot].x - dt, 0.0f);
    if (game.bossScene.x < 0.0f || game.enemy[bossSlot].w <= 0.0f)
        return;
    float time = game.bossScene.x;
    SpiderTraits traits = spiderTraits(SpiderVariant::bossBlack);
    game.enemyClock[bossSlot].z = max(game.enemyClock[bossSlot].z - dt, 0.0f);
    game.enemyClock[bossSlot].x = max(game.enemyClock[bossSlot].x - dt, 0.0f);
    float2 previous = game.enemy[bossSlot].xz;
    if (time < 5.0f) {
        // The rear blast door rises, the boss walks out, then it drops shut.
        float emerge = smoothstep(1.25f, 4.25f, time);
        game.enemy[bossSlot].z = mix(-118.0f, -96.0f, emerge);
        game.enemyClock[bossSlot].w = rangePi;
        game.gait[bossSlot].y = smoothstep(1.0f, 2.0f, time);
    } else {
        // Below half health the boss is enraged: shorter tells, faster
        // rushes and two webs per throw, one aimed where the player is going.
        bool enraged = bossEnraged(game);
        float windup = bossWindup(game);
        game.bossAttack.y = max(game.bossAttack.y - dt, 0.0f);
        game.bossWeb.x = max(game.bossWeb.x - dt, 0.0f);
        float2 toPlayer = game.player.xz - game.enemy[bossSlot].xz;
        float distance = length(toPlayer);
        if (game.bossAttack.x <= 0.0f && game.bossAttack.y <= 0.0f
            && distance > 4.0f) {
            // Snapshot a heading once. The charge never turns to follow a dodge.
            float2 heading = toPlayer / max(distance, 0.001f);
            game.bossAttack.zw = heading;
            game.bossAttack.x = 0.001f;
            game.bossAttack.y = enraged ? 1.7f : 2.5f;
            game.enemyClock[bossSlot].w = atan2(heading.x, -heading.y);
        }
        if (game.bossAttack.x > 0.0f) {
            game.bossAttack.x += dt;
            float charge = game.bossAttack.x;
            if (charge > windup && charge < windup + 0.82f) {
                float2 next = game.enemy[bossSlot].xz
                    + game.bossAttack.zw * ((enraged ? 15.0f : 12.5f) * dt);
                if (bossPositionClear(next)) game.enemy[bossSlot].xz = next;
                float gap = length(game.player.xz - game.enemy[bossSlot].xz);
                game.recoil.w = max(game.recoil.w,
                    0.45f * pow(1.0f - saturate(gap / 16.0f), 2.0f));
                if (gap < 4.2f && game.enemyClock[bossSlot].x <= 0.0f) {
                    damagePlayer(game, 23.0f, game.enemy[bossSlot].xz, 0.42f);
                    game.enemyClock[bossSlot].x = 1.4f;
                }
            }
            if (charge >= windup + 0.82f) game.bossAttack.x = 0.0f;
        } else if (game.bossWeb.x <= 0.0f && distance < 36.0f) {
            for (uint cloth = 0u; cloth < (enraged ? 2u : 1u); ++cloth) {
                uint slot = uint(game.bossWeb.y) % webCount;
                float2 landing = clamp(game.player.xz
                        + (cloth == 1u ? game.motion.xy * 0.9f : float2(0.0f)),
                    float2(-18.5f, bossRoomNorth + 4.0f),
                    float2(18.5f, bossRoomSouth - 3.0f));
                game.webs[slot].startTime = float4(
                    game.enemy[bossSlot].xyz + float3(0.0f, 2.0f, 0.0f),
                    game.effects.x);
                // Shorter-lived enraged webs keep all cloths within the slots.
                game.webs[slot].targetExpiry = float4(landing.x, 1.27f,
                    landing.y, game.effects.x + (enraged ? 5.5f : 6.7f));
                game.bossWeb.y += 1.0f;
            }
            game.bossWeb.x = 3.0f;
        }
        // Deliberately slow reorientation between fixed-heading lunges.
        if (game.bossAttack.x <= 0.0f && distance > 0.01f) {
            float desired = atan2(toPlayer.x, -toPlayer.y);
            float delta = atan2(sin(desired - game.enemyClock[bossSlot].w),
                cos(desired - game.enemyClock[bossSlot].w));
            game.enemyClock[bossSlot].w += clamp(delta,
                -0.8f * dt, 0.8f * dt);
        }
        game.gait[bossSlot].y = mix(game.gait[bossSlot].y,
            game.bossAttack.x > windup ? 1.0f : 0.15f,
            1.0f - exp(-dt * 5.0f));
    }
    float travel = length(game.enemy[bossSlot].xz - previous);
    game.gait[bossSlot].x = fract(game.gait[bossSlot].x
        + 0.6f * travel / (traits.strideSpan * traits.scale));
    game.enemy[bossSlot].y = 1.2f + traits.scale * (0.52f
        + spiderBodyBob(game.gait[bossSlot].x,
            game.gait[bossSlot].y, traits));
}

// Kajiya-Kay strand lighting with two shifted highlights (Scheuermann): a
// white reflection from the cuticle and a dimmer one tinted by the strand it
// passed through. Roots get less light through the strands above them.
float3 spiderFurReflectance(float3 albedo, float4 fur, float3 normal,
    float3 toLight, float3 toView) {
    float3 strand = normalize(fur.xyz);
    float3 halfway = normalize(toLight + toView);
    float strandLight = dot(strand, toLight);
    float primary = dot(normalize(strand + normal * 0.1f), halfway);
    float secondary = dot(normalize(strand - normal * 0.1f), halfway);
    float3 diffuse = albedo / rangePi
        * sqrt(max(1.0f - strandLight * strandLight, 0.0f));
    float3 specular = 0.12f * pow(max(1.0f - primary * primary, 0.0f), 45.0f)
        + 0.5f * albedo
            * pow(max(1.0f - secondary * secondary, 0.0f), 11.0f);
    return (diffuse + specular) * mix(0.35f, 1.0f, fur.w)
        * saturate(dot(normal, toLight));
}

SurfaceMaterial spiderSurfaceMaterial(uint material, float3 furPosition,
    float4 fur, SpiderVariant variant) {
    if (material == 16u) return {
        variant != SpiderVariant::brown
            ? float3(0.12f, 0.012f, 0.014f)
            : float3(0.012f, 0.019f, 0.023f),
        0.045f, 0.02f,
        variant != SpiderVariant::brown
            ? float3(0.42f, 0.012f, 0.008f)
            : float3(0.0f)};
    if (material == 19u) return {
        variant != SpiderVariant::brown
            ? float3(0.025f, 0.005f, 0.006f)
            : float3(0.035f, 0.018f, 0.012f),
        0.82f, 0.0f, float3(0.0f)};
    if (material == 5u || material == 15u
        || material == 17u || material == 18u) {
        // Body, legs, joints and paws all use primitive-local fur coordinates,
        // so the coat follows the spider's turns and articulated gait. Strands
        // brighten from root to tip; their fur positions are strand roots, so
        // the noise below varies the tint between strands, not along one.
        // The black spider's smooth leg facets keep the fibre noise.
        float fibers = dot(fur.xyz, fur.xyz) > 0.0f
            ? smoothstep(0.0f, 0.9f, fur.w)
            : 0.5f * smoothNoise(
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
        if (variant != SpiderVariant::brown) {
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

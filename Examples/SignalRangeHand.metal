// The bare right hand: a gloved fist held up in a loose guard that punches,
// or lifts itself upright and raps three times on a door within reach.
// Included by HauntedHouseProgram.metal after SignalRangeShotgun.metal; the
// program decides what a swing strikes and keeps the swing in game.hand:
// start time (negative while idle), 0 for a punch or 1 for a knock, contacts
// resolved (a punch: 1 missed, 2 landed; a knock: raps struck), and the door
// within reach while idle.

// Reach is measured from the eye, generously, as a shooter's use key is:
// a punch meets a spider rearing to bite, and a knock reaches a door from
// the foot of its step.
constant float handPunchReach = 2.1f;
constant float handKnockReach = 1.8f;
constant float handPunchContact = 0.09f;
constant float handPunchDuration = 0.42f;
constant uint handRaps = 3u;
constant float handFirstRap = 0.2f;
constant float handRapInterval = 0.16f;
constant float handKnockDuration = handFirstRap
    + handRapInterval * float(handRaps - 1u) + 0.3f;
constant float handPunchDamage = 1.0f;
constant float handPunchShove = 3.4f;

bool handKnocking(device const GameState &game) {
    return game.hand.y > 0.5f;
}

// Seconds into the current swing, or -1 while the hand is idle.
float handSwingAge(device const GameState &game) {
    if (game.hand.x < 0.0f) return -1.0f;
    float age = game.effects.x - game.hand.x;
    float duration = handKnocking(game) ? handKnockDuration : handPunchDuration;
    return age >= 0.0f && age < duration ? age : -1.0f;
}

float handRapTime(uint rap) {
    return handFirstRap + handRapInterval * float(rap);
}

bool handGestureActive(device const GameState &game) {
    return game.gesture.z >= 0.0f
        && game.effects.x - game.gesture.z < 2.2f;
}

// Turn the closed hand first, then extend the middle finger. Retract it
// before the wrist returns to its guard pose.
float handFingerExtension(device const GameState &game) {
    if (!handGestureActive(game)) return 0.0f;
    float age = game.effects.x - game.gesture.z;
    return smoothstep(0.35f, 0.68f, age)
        * (1.0f - smoothstep(1.55f, 1.9f, age));
}

// The fist in view space, and the elbow its forearm runs back to, in the
// fist's frame.
struct HandPose {
    GunPose fist;
    float3 elbow;
};

// The fist's frame: X right, Y up off the back of the hand, Z out through
// the knuckles; origin at the middle knuckle. The thumb is on the -X side.
// At rest the fist is up in a guard low on the right, knuckles raised and
// the back of the hand toward the eye, its forearm dropping to an elbow
// below. A punch drives it out at the crosshair, turning it palm down, the
// forearm reaching back toward the shoulder; one that lands stops short. A
// knock lifts it upright before the face, wrist bent so the knuckles meet
// the door, and taps it forward three times.
HandPose handPose(device const GameState &game) {
    float bob = game.motion.w, phase = game.motion.z;
    float2 sway = game.look.zw;
    float lowered = weaponLowered(game);
    float3 pivot = float3(0.15f, -0.095f, 0.40f);
    float3 elbow = float3(0.08f, -0.32f, -0.12f);
    float pitch = 0.7f, yaw = -0.18f, roll = -0.55f;
    float age = handSwingAge(game);
    if (handGestureActive(game)) {
        float gestureAge = game.effects.x - game.gesture.z;
        float turn = smoothstep(0.0f, 0.32f, gestureAge)
            * (1.0f - smoothstep(1.85f, 2.2f, gestureAge));
        pivot = mix(pivot, float3(0.12f, -0.025f, 0.42f), turn);
        elbow = mix(elbow, float3(0.25f, -0.32f, -0.14f), turn);
        // Local -Y is the palm; the wrist turn brings it toward the eye.
        // Local +Z follows the tilted arm and carries the extended finger.
        pitch = mix(pitch, 1.12f, turn);
        yaw = mix(yaw, -0.76f, turn);
        roll = mix(roll, -2.33f, turn);
    } else if (age >= 0.0f && !handKnocking(game)) {
        float u = saturate(age / handPunchContact);
        float out = u * (2.0f - u);
        if (age > handPunchContact) {
            float peak = game.hand.z > 1.5f ? 0.86f : 1.0f;
            out = peak * (1.0f - smoothstep(handPunchContact + 0.05f,
                handPunchDuration, age));
        }
        pivot = mix(pivot, float3(0.06f, -0.045f, 0.56f), out);
        elbow = mix(elbow, float3(0.17f, -0.27f, -0.27f), out);
        pitch = mix(pitch, 0.3f, out);
        yaw = mix(yaw, -0.22f, out);
        roll = mix(roll, -0.1f, out);
    } else if (age >= 0.0f) {
        float lift = smoothstep(0.0f, 0.15f, age)
            * (1.0f - smoothstep(handKnockDuration - 0.24f,
                handKnockDuration, age));
        float rap = 0.0f;
        for (uint k = 0u; k < handRaps; ++k) {
            float x = (age - handRapTime(k)) / 0.045f;
            rap += exp(-x * x);
        }
        pivot = mix(pivot, float3(0.08f, -0.05f, 0.42f), lift)
            + float3(-0.004f, 0.004f, 0.05f) * rap;
        elbow = mix(elbow, float3(0.13f, -0.3f, -0.15f), lift)
            - float3(0.0f, 0.0f, 0.04f) * rap;
        pitch = mix(pitch, 0.18f, lift) - 0.25f * rap;
        yaw = mix(yaw, -0.1f, lift);
        roll = mix(roll, -1.45f, lift);
    }
    pivot += float3(0.010f * bob * sin(phase) - 0.007f * sway.x,
        -0.008f * bob * abs(cos(phase)) - 0.007f * sway.y
            - 0.34f * lowered - 0.5f * game.hurt.w,
        0.0f);
    pitch += -0.02f * sway.y - 0.9f * lowered;
    yaw += -0.035f * sway.x;
    float3 f = float3(sin(yaw) * cos(pitch), sin(pitch),
        cos(yaw) * cos(pitch));
    float3 r = normalize(float3(f.z, 0.0f, -f.x));
    float3 up = cross(f, r);
    float3x3 basis = float3x3(r * cos(roll) + up * sin(roll),
        up * cos(roll) - r * sin(roll), f);
    return {{pivot, basis, 0.0f}, transpose(basis) * elbow};
}

// The hand is a signed distance field in the fist's frame, sphere-traced
// like the pistol's rounded parts. Knuckles, finger joints, the heels of
// the palm and the base of the thumb blend into one another as flesh under
// a leather glove does; fingers only press against their neighbours, so
// the creases between them stay. Parts: 13 leather, 14 the cuff's strap,
// 15 sleeve.

// Per finger, index to little: the head of its metacarpal, which stands up
// as the knuckle, and the finger's size. The knuckles arc back toward the
// little finger, and the index and middle knuckles lead the punch.
constant float4 handKnuckles[4] = {
    float4(-0.0262f, -0.0055f, -0.0030f, 0.97f),
    float4(-0.0088f, -0.0040f, 0.0000f, 1.00f),
    float4(0.0086f, -0.0060f, -0.0035f, 0.96f),
    float4(0.0250f, -0.0110f, -0.0110f, 0.84f)};

// The wrist the cuff and sleeve run back from toward the elbow, and where
// the sleeve's hem ends, along that run.
constant float3 handWrist = float3(0.0f, -0.020f, -0.084f);
constant float handSleeveHem = 0.060f;

float handSmoothMin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0f) / k;
    return min(a, b) - h * h * k * 0.25f;
}

// A capsule whose radius runs from `ra` at `a` to `rb` at `b`.
float handTaper(float3 p, float3 a, float3 b, float ra, float rb) {
    float3 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - mix(ra, rb, h);
}

float handEllipsoid(float3 p, float3 centre, float3 radii) {
    float3 q = (p - centre) / radii;
    float k0 = length(q);
    return k0 * (k0 - 1.0f) / length(q / radii);
}

// The bare fist: the palm and its two heels, the four fingers each curled
// down from the knuckle and back under it, their tips buried in the palm,
// and the thumb folded across the index and middle fingers.
float handFist(float3 p, float extension) {
    float3 box = abs(p - float3(-0.001f, -0.022f, -0.046f))
        - float3(0.029f, 0.013f, 0.036f) + 0.011f;
    float palm = length(max(box, 0.0f))
        + min(max(box.x, max(box.y, box.z)), 0.0f) - 0.011f;
    palm = handSmoothMin(palm, handEllipsoid(p,
        float3(-0.024f, -0.033f, -0.060f), float3(0.016f, 0.015f, 0.026f)),
        0.012f);
    palm = handSmoothMin(palm, handEllipsoid(p,
        float3(0.023f, -0.031f, -0.062f), float3(0.012f, 0.013f, 0.027f)),
        0.012f);
    // The fingertips press into the palm: fill the tunnel they curl around.
    palm = handSmoothMin(palm, handEllipsoid(p,
        float3(-0.001f, -0.037f, -0.014f), float3(0.030f, 0.011f, 0.014f)),
        0.008f);
    float fingers = 1.0e6f;
    for (uint i = 0u; i < 4u; ++i) {
        float3 knuckle = handKnuckles[i].xyz;
        float size = handKnuckles[i].w;
        palm = handSmoothMin(palm, handTaper(p,
            float3(knuckle.x * 0.55f, -0.009f, -0.080f), knuckle,
            0.0095f, 0.0108f * size), 0.010f);
        float3 middle = knuckle + size * float3(0.0f, -0.040f, 0.006f);
        float3 last = middle + size * float3(0.0f, -0.002f, -0.026f);
        if (i == 1u && extension > 0.0f) {
            // The finger unfolds along the palm's plane and the wrist's
            // length, rather than sticking out through the back of the hand.
            middle = mix(middle,
                knuckle + float3(0.0f, -0.002f, 0.046f), extension);
            last = mix(last,
                knuckle + float3(0.0f, -0.005f, 0.093f), extension);
        }
        float finger = handTaper(p, knuckle, middle,
            0.0106f * size, 0.0097f * size);
        finger = handSmoothMin(finger, handTaper(p, middle, last,
            0.0095f * size, 0.0087f * size), 0.004f);
        fingers = min(fingers, finger);
    }
    float3 base = float3(-0.022f, -0.028f, -0.078f);
    float3 joint = float3(-0.042f, -0.048f, -0.040f);
    float3 bend = float3(-0.032f, -0.061f, -0.012f);
    float thumb = handTaper(p, base, joint, 0.0135f, 0.0122f);
    thumb = handSmoothMin(thumb, handTaper(p, joint, bend, 0.0122f, 0.0108f),
        0.004f);
    thumb = handSmoothMin(thumb, handTaper(p, bend,
        float3(-0.011f, -0.062f, -0.003f), 0.0106f, 0.0092f), 0.004f);
    return min(handSmoothMin(palm, fingers, 0.006f),
        handSmoothMin(palm, thumb, 0.012f));
}

struct HandDistance {
    float distance;
    uint part;
};

// The whole arm: the fist, the glove's gauntlet cuff with its strap, and
// the sleeve, which ends in a hem over the cuff and creases as it bunches
// toward it. Cuff and sleeve are oval, wider across the back of the hand
// than through it, and run from the wrist toward `elbow`.
HandDistance handDistance(float3 p, float3 elbow, float extension) {
    // The fist is only worked out near it.
    float3 fistCentre = mix(float3(-0.008f, -0.028f, -0.038f),
        float3(-0.008f, -0.025f, -0.010f), extension);
    float fist = length(p - fistCentre) - (0.083f + 0.035f * extension);
    if (fist < 0.01f) fist = handFist(p, extension);
    float3 along = normalize(elbow - handWrist);
    float3 side = normalize(float3(1.0f, 0.0f, 0.0f) - along * along.x);
    float3 q = p - handWrist;
    float run = dot(q, along);
    float2 section = float2(dot(q, side) * 0.82f, dot(q, cross(along, side)));
    float radial = length(section);
    float strap = smoothstep(0.026f, 0.028f, run)
        * (1.0f - smoothstep(0.050f, 0.052f, run));
    float2 cuffEdge = float2(radial - mix(0.0215f, 0.0275f,
            saturate(run / 0.07f)) - 0.0018f * strap,
        max(-0.01f - run, run - 0.072f));
    float cuff = length(max(cuffEdge, 0.0f))
        + min(max(cuffEdge.x, cuffEdge.y), 0.0f);
    float sleeveRadius = mix(0.034f, 0.041f,
        saturate((run - handSleeveHem) / 0.22f));
    // The folds only matter within reach of the cloth.
    if (abs(radial - sleeveRadius) < 0.008f) {
        float angle = atan2(section.y, section.x);
        sleeveRadius += 0.0024f * sin(2.0f * angle + run * 26.0f + 0.7f)
            + 0.0024f * exp(-(run - handSleeveHem) * 14.0f)
                * sin(run * 110.0f + 1.4f * sin(3.0f * angle));
    }
    float2 sleeveEdge = float2(radial - sleeveRadius,
        max(handSleeveHem - run, run - length(elbow - handWrist) - 0.05f))
        + 0.004f;
    float sleeve = length(max(sleeveEdge, 0.0f))
        + min(max(sleeveEdge.x, sleeveEdge.y), 0.0f) - 0.004f;
    float glove = handSmoothMin(fist, cuff, 0.02f);
    if (sleeve < glove) return {sleeve, 15u};
    return {glove, strap > 0.5f && cuff < fist ? 14u : 13u};
}

// Sphere-traces the arm from where the ray enters a sphere around it. The
// hit carries how far the surface is shut in by the rest of the hand, from
// a few steps out along its normal.
GunHit traceHand(float3 origin, float3 direction, float3 elbow,
    float extension) {
    GunHit hit = {1.0e6f, float3(0.0f), 0u, float3(0.0f)};
    // Rays passing wide of both the fist and the forearm's axis miss.
    float3 toFist = origin - float3(-0.008f, -0.028f, -0.038f);
    float3 arm = elbow - handWrist, fromWrist = origin - handWrist;
    float armDirection = dot(arm, direction);
    float closest = saturate((dot(arm, fromWrist)
            - armDirection * dot(direction, fromWrist))
        / max(dot(arm, arm) - armDirection * armDirection, 1.0e-8f));
    float passing = max(armDirection * closest - dot(direction, fromWrist),
        0.0f);
    closest = saturate((armDirection * passing + dot(arm, fromWrist))
        / dot(arm, arm));
    if (length(toFist - direction * dot(toFist, direction))
            > 0.085f + 0.045f * extension
        && length(fromWrist + direction * passing - arm * closest) > 0.06f)
        return hit;
    float3 offset = origin - 0.5f * elbow;
    float bound = 0.5f * length(elbow) + 0.12f + 0.05f * extension;
    float b = dot(offset, direction);
    float discriminant = b * b - dot(offset, offset) + bound * bound;
    if (discriminant < 0.0f) return hit;
    float t = max(-b - sqrt(discriminant), 0.01f);
    float far = -b + sqrt(discriminant);
    for (uint step = 0u; step < 96u && t < far; ++step) {
        float3 p = origin + direction * t;
        HandDistance d = handDistance(p, elbow, extension);
        if (d.distance < 1.5e-4f) {
            const float2 e = float2(2.5e-4f, -2.5e-4f);
            float3 normal = normalize(
                e.xyy * handDistance(p + e.xyy, elbow, extension).distance
                + e.yyx * handDistance(p + e.yyx, elbow, extension).distance
                + e.yxy * handDistance(p + e.yxy, elbow, extension).distance
                + e.xxx * handDistance(p + e.xxx, elbow, extension).distance);
            float shut = 0.0f;
            for (uint i = 1u; i <= 3u; ++i) {
                float h = 0.005f * float(i);
                shut += (h - handDistance(p + normal * h, elbow,
                    extension).distance)
                    / float(i);
            }
            hit = {t, normal, d.part, p, saturate(shut * 70.0f)};
            return hit;
        }
        // Folds and blends bend the field; shorter steps keep it from
        // stepping through an edge.
        t += d.distance * 0.85f;
    }
    return hit;
}

// Black leather with a fine pebbled grain, rubbed brown and smooth over the
// knuckles; a woven nylon strap; the olive sleeve of the pistol's arm,
// heathered. Shut-in creases go dark and dull.
SurfaceMaterial handMaterial(GunHit hit) {
    float3 p = hit.local;
    float shade = 1.0f - 0.8f * hit.cavity;
    if (hit.part == 15u) {
        float weave = 0.5f * (smoothNoise(p.xz * 260.0f)
            + smoothNoise(p.yz * 260.0f));
        return {float3(0.085f, 0.090f, 0.060f)
                * (0.8f + 0.4f * smoothNoise(p.xz * 45.0f + 7.0f))
                * (0.88f + 0.24f * weave) * shade,
            0.95f, 0.0f, float3(0.0f)};
    }
    if (hit.part == 14u) {
        float weave = smoothNoise(p.xy * 900.0f) * smoothNoise(p.yz * 900.0f);
        return {float3(0.030f, 0.030f, 0.032f) * (0.85f + 0.3f * weave)
                * shade,
            0.8f, 0.0f, float3(0.0f)};
    }
    float grain = (smoothNoise(p.xy * 520.0f) + smoothNoise(p.yz * 520.0f)
        + smoothNoise(p.zx * 520.0f)) / 3.0f;
    float mottle = 0.5f * (smoothNoise(p.xz * 70.0f + 3.1f)
        + smoothNoise(p.xy * 70.0f));
    float rubbed = 0.0f;
    for (uint i = 0u; i < 4u; ++i)
        rubbed = max(rubbed, 1.0f - smoothstep(0.004f, 0.015f,
            length(p - handKnuckles[i].xyz - float3(0.0f, 0.007f, 0.006f))));
    float wear = saturate(rubbed * (0.6f + 0.6f * mottle) + 0.2f * mottle);
    float3 leather = mix(float3(0.040f, 0.034f, 0.030f),
        float3(0.090f, 0.068f, 0.052f), wear) * (0.82f + 0.36f * grain);
    float palmFacing = smoothstep(0.15f, 0.7f, -hit.normal.y);
    leather *= 1.0f + 0.45f * palmFacing;
    return {leather * shade,
        mix(mix(0.44f, 0.30f, rubbed) + 0.08f * grain, 1.0f, hit.cavity),
        0.0f, float3(0.035f, 0.042f, 0.038f) * palmFacing
            * (1.0f - hit.cavity)};
}

// Near its outline the hand mirrors what lies just past it, so a fist held
// against a lit door or a bright floor picks up a rim of that light, as
// leather does at a glancing angle; the sleeve's fibres scatter a softer
// rim. `behind` is the scene the hand covers at this pixel; the rim fades
// in the creases.
float3 handSheen(GunHit hit, float3x3 basis, float3 viewDirection,
    float3 behind) {
    float facing = saturate(dot(basis * hit.normal, -viewDirection));
    return behind * (hit.part == 15u ? 0.3f : 0.55f)
        * pow(1.0f - facing, 3.0f) * (1.0f - hit.cavity);
}

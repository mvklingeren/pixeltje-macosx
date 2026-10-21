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
    if (age >= 0.0f && !handKnocking(game)) {
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

// Parts: 4 glove, 5 sleeve. Each finger is curled down at the knuckle and
// back under it; the thumb wraps across the index and middle fingers. The
// forearm runs from the wrist to `elbow`, in the fist's frame.
GunHit traceHand(float3 origin, float3 direction, float3 elbow) {
    GunHit hit = {1.0e6f, float3(0.0f), 0u, float3(0.0f)};
    if (raySphere(origin, direction, 0.5f * elbow,
            0.5f * length(elbow) + 0.12f) < 0.0f) return hit;
    float3 normal;
    float t = pixeltje_3d::rayEllipsoid(origin, direction,
        float3(0.0f, -0.017f, -0.046f), float3(0.042f, 0.025f, 0.053f),
        0.001f, normal);
    if (t > 0.0f && t < hit.distance)
        hit = {t, normal, 4u, origin + direction * t};
    for (uint finger = 0u; finger < 4u; ++finger) {
        float x = -0.026f + 0.0172f * float(finger);
        float size = finger == 3u ? 0.86f : 1.0f;
        float3 knuckle = float3(x, -0.002f, 0.004f * size);
        float3 middle = float3(x, -0.038f * size, 0.011f);
        gunCapsule(hit, origin, direction, knuckle, middle,
            0.0105f * size, 4u);
        gunCapsule(hit, origin, direction, middle,
            float3(x, -0.041f * size, -0.021f), 0.0095f * size, 4u);
    }
    gunCapsule(hit, origin, direction, float3(-0.036f, -0.022f, -0.072f),
        float3(-0.042f, -0.044f, -0.031f), 0.0125f, 4u);
    gunCapsule(hit, origin, direction, float3(-0.042f, -0.044f, -0.031f),
        float3(-0.03f, -0.055f, -0.005f), 0.0115f, 4u);
    gunCapsule(hit, origin, direction, float3(-0.03f, -0.055f, -0.005f),
        float3(-0.009f, -0.055f, 0.0f), 0.0102f, 4u);
    // The glove's cuff over the wrist, then the sleeve back to the elbow.
    float3 wrist = float3(0.0f, -0.017f, -0.085f);
    float3 along = normalize(elbow - wrist);
    gunCapsule(hit, origin, direction, wrist, wrist + along * 0.07f,
        0.029f, 4u);
    gunCapsule(hit, origin, direction, wrist + along * 0.06f, elbow,
        0.036f, 5u);
    return hit;
}

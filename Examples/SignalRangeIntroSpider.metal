// Signal Range's opening visitor: a small fuzzy cartoon spider lowers itself
// on a silk thread in front of the view at the right side, bounces on the
// silk, dangles and looks around, then takes to the glass and creeps down over
// the right of the screen and off its bottom edge. It is a screen overlay drawn
// after the HUD and never enters the game: nothing can shoot it and it never
// bites. Included by SignalRangeFPSProgram.metal.
//
// game.intro.x counts seconds since the workflow started. initializeRange
// zeroes it and a match restart leaves it alone, so the spider visits once
// per run.

constant float introDropStart = 0.8f;    // the spider starts down its thread
constant float introCreepStart = 5.4f;   // it takes to the glass
constant float introCreepTime = 5.2f;    // from the hang point off the bottom
constant float introThreadFade = 0.8f;   // the dragline lingers, then fades
constant float introSpiderEnd = introCreepStart + introCreepTime
    + introThreadFade;
constant float introSurgePeriod = 1.3f;  // creeping comes in surges and pauses
constant float introSurgeMove = 0.72f;   // moving share of each surge
constant float introStride = 1.4f;       // body radii travelled per gait cycle
// Legs, in body radii: hip, thigh and shin lengths.
constant float introHip = 0.78f;
constant float introThigh = 1.0f;
constant float introShin = 1.15f;

struct IntroSpiderPose {
    float2 centre;      // body centre in pixels, y down
    float2 anchor;      // where the thread leaves the top edge
    float radius;       // body radius in pixels
    float heading;      // body rotation; 0 hangs head down
    float stride;       // gait cycles walked on the glass
    float walking;      // 0 hanging on the thread, 1 walking on the glass
    float tuck;         // legs drawn in while dropping
    float2 gaze;        // pupil offset in the body frame, unit disk
    float blink;        // 0 open, 1 closed
    float silk;         // thread opacity
    float time;         // seconds since the drop started
    bool visible;
};

float2 introRotate(float2 v, float angle) {
    float s = sin(angle), c = cos(angle);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// Distance along the creeping path: four surges, each easing in and out,
// with a short pause after it.
float introCreepProgress(float time) {
    float surges = introCreepTime / introSurgePeriod;
    float cycle = clamp(time, 0.0f, introCreepTime) / introSurgePeriod;
    float step = smoothstep(0.0f, 1.0f,
        saturate(fract(cycle) / introSurgeMove));
    return saturate((floor(cycle) + step) / surges);
}

// The creeping path on screen: a gentle swerve to the right and back while
// heading down past the bottom edge.
float2 introCreepPoint(float progress, float2 hang, float radius,
    float bottom) {
    return float2(hang.x + radius * (1.5f * sin(4.4f * progress)
            + 1.2f * progress),
        mix(hang.y, bottom, progress));
}

float introBump(float time, float start, float end, float edge) {
    return smoothstep(start, start + edge, time)
        * (1.0f - smoothstep(end - edge, end, time));
}

IntroSpiderPose introSpiderPose(float clock, float2 resolution) {
    IntroSpiderPose pose;
    float time = clock - introDropStart;
    pose.time = time;
    pose.visible = time >= 0.0f && clock < introSpiderEnd;
    pose.radius = 0.06f * resolution.y;
    float radius = pose.radius;
    pose.anchor = float2(max(resolution.x - 0.36f * resolution.y,
        0.6f * resolution.x), -4.0f);
    float2 hang = float2(pose.anchor.x, 0.38f * resolution.y);
    float creepTime = clock - introCreepStart;
    float2 toCrosshair = 0.5f * resolution;

    if (creepTime < 0.0f) {
        // An underdamped spring from rest above the top edge: the spider
        // drops, overshoots on the stretching silk and settles.
        float t = max(time, 0.0f);
        const float damping = 2.0f;
        const float frequency = 2.6f;
        float spring = exp(-damping * t) * (cos(frequency * t)
            + damping / frequency * sin(frequency * t));
        float top = -3.2f * radius;
        float sway = sin(1.6f * t) * smoothstep(0.6f, 1.6f, t)
            * (1.0f - smoothstep(3.8f, 4.6f, t));
        pose.centre = float2(hang.x + 0.12f * radius * sway,
            hang.y + (top - hang.y) * spring);
        pose.heading = -0.06f * sway;
        pose.stride = 0.0f;
        pose.walking = 0.0f;
        pose.tuck = 1.0f - smoothstep(0.5f, 1.3f, t);
        // Watch the drop, eye the crosshair, blink, stare at the player,
        // then look down for a way off the thread.
        float2 crosshair = normalize(toCrosshair - pose.centre);
        float2 gaze = float2(0.0f, 0.6f);
        float aim = introBump(t, 1.2f, 2.8f, 0.3f);
        float stare = introBump(t, 3.0f, 4.3f, 0.2f);
        gaze = mix(gaze, 0.75f * introRotate(crosshair, -pose.heading), aim);
        gaze = mix(gaze, float2(0.0f, 0.05f), stare);
        pose.gaze = gaze;
        pose.blink = introBump(t, 2.86f, 3.14f, 0.12f);
        pose.silk = 1.0f;
        return pose;
    }

    float bottom = resolution.y + 3.3f * radius;
    float progress = introCreepProgress(creepTime);
    pose.centre = introCreepPoint(progress, hang, radius, bottom);
    float2 tangent = introCreepPoint(min(progress + 0.01f, 1.0f), hang,
            radius, bottom)
        - introCreepPoint(max(progress - 0.01f, 0.0f), hang, radius, bottom);
    float settle = smoothstep(0.0f, 0.5f, creepTime);
    pose.heading = settle * atan2(-tangent.x, tangent.y);
    // The path is mostly straight down, so its length is close to the drop.
    pose.stride = progress * (bottom - hang.y) * 1.06f
        / (introStride * radius);
    pose.walking = smoothstep(0.0f, 0.35f, creepTime);
    pose.tuck = 0.0f;
    // Look ahead, and glance back at the player during the second pause.
    float2 crosshair = normalize(toCrosshair - pose.centre);
    pose.gaze = mix(float2(0.0f, 0.6f),
        0.7f * introRotate(crosshair, -pose.heading),
        introBump(creepTime, 2.05f, 2.85f, 0.15f));
    pose.blink = introBump(creepTime, 2.32f, 2.58f, 0.11f);
    pose.silk = 1.0f - smoothstep(introCreepTime,
        introCreepTime + introThreadFade, creepTime);
    return pose;
}

struct IntroLeg {
    float2 hip;
    float2 knee;
    float2 foot;
};

// One leg in the body frame, in body radii with y toward the head. Leg 0
// reaches forward, leg 3 back; side is -1 on the left and 1 on the right.
IntroLeg introSpiderLeg(IntroSpiderPose pose, uint index, float side) {
    float rank = float(index) / 3.0f;
    float hipAngle = mix(0.75f, -0.55f, rank);
    IntroLeg leg;
    leg.hip = introHip * float2(side * cos(hipAngle), sin(hipAngle));
    // Hanging, the feet droop around the body like a cartoon spider's.
    const float2 hangFeet[4] = {
        float2(1.45f, 1.45f), float2(1.95f, 0.95f),
        float2(2.15f, 0.45f), float2(2.05f, -0.05f)};
    // On the glass they spread for a walking stance.
    const float2 walkFeet[4] = {
        float2(1.55f, 1.5f), float2(2.1f, 0.55f),
        float2(2.1f, -0.4f), float2(1.6f, -1.3f)};
    float2 hangFoot = hangFeet[index] * float2(side, 1.0f);
    float phase = float(index) * 1.7f + side * 0.9f;
    hangFoot += 0.09f * float2(sin(pose.time * 2.7f + phase),
        cos(pose.time * 2.1f + phase * 1.3f));
    // While dropping, the legs fold in and up.
    hangFoot = mix(hangFoot, leg.hip * 1.35f + float2(0.0f, -0.35f),
        0.55f * pose.tuck);
    // Alternating tetrapod gait: a foot pushes back while planted, then
    // swings forward with a small outward lift.
    float group = (index + (side > 0.0f ? 1u : 0u)) % 2u == 0u ? 0.0f : 0.5f;
    float cycle = fract(pose.stride + group);
    const float stance = 0.6f;
    const float reach = 0.42f;
    float along;
    float lift = 0.0f;
    if (cycle < stance) {
        along = mix(reach, -reach, cycle / stance);
    } else {
        float swing = (cycle - stance) / (1.0f - stance);
        along = mix(-reach, reach, smoothstep(0.0f, 1.0f, swing));
        lift = sin(swing * rangePi);
    }
    float2 walkFoot = walkFeet[index] * float2(side, 1.0f)
        + float2(side * 0.18f * lift, along);
    leg.foot = mix(hangFoot, walkFoot, pose.walking);
    // Two-bone solve with the knee bent up and outward.
    float2 toFoot = leg.foot - leg.hip;
    float distance = clamp(length(toFoot), 0.2f,
        introThigh + introShin - 0.02f);
    float2 direction = normalize(toFoot);
    float a = (introThigh * introThigh - introShin * introShin
        + distance * distance) / (2.0f * distance);
    float h = sqrt(max(introThigh * introThigh - a * a, 0.0f));
    float2 bend = float2(direction.y, -direction.x);
    if (dot(bend, float2(side * 0.35f, -1.0f)) < 0.0f) bend = -bend;
    leg.knee = leg.hip + direction * a + bend * h;
    return leg;
}

// Distance to a tapered segment and the unit offset from its axis.
float introLimb(float2 p, float2 a, float2 b, float ra, float rb,
    thread float2 &across) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 0.000001f));
    float radius = mix(ra, rb, h);
    float2 offset = pa - ba * h;
    float d = length(offset);
    across = offset / max(radius, 0.0001f);
    return d - radius;
}

// Distance to one leg in the body frame, and the offset across the nearer of
// its two segments for shading.
float introLegDistance(float2 q, IntroLeg leg, thread float2 &across) {
    float2 thighAcross, shinAcross;
    float thigh = introLimb(q, leg.hip, leg.knee, 0.10f, 0.075f, thighAcross);
    float shin = introLimb(q, leg.knee, leg.foot, 0.075f, 0.028f, shinAcross);
    across = thigh < shin ? thighAcross : shinAcross;
    return min(thigh, shin);
}

// The body outline: two layers of uneven fur spikes around a round body.
float introFurRadius(float angle) {
    float fur = 0.0f;
    for (uint layer = 0u; layer < 2u; ++layer) {
        float count = layer == 0u ? 46.0f : 71.0f;
        float position = angle / (2.0f * rangePi) * count
            + float(layer) * 0.37f;
        float cell = floor(position);
        // Wrap the last cell onto the first so the seam has no step.
        float wrapped = fmod(cell + count, count);
        float spikeLength = 0.05f + 0.15f
            * hashTile(float2(wrapped, 17.0f + float(layer)));
        float spike = 1.0f - abs(fract(position) - 0.5f) * 2.0f;
        fur = max(fur, spikeLength * spike * spike);
    }
    return 1.0f + fur;
}

struct IntroVertex {
    float4 position [[position]];
};

// One quad around the thread and the spider; collapsed outside the intro.
vertex IntroVertex introSpiderVertex(uint vertexID [[vertex_id]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]]) {
    float2 resolution = u.resolutionTime.xy;
    IntroSpiderPose pose = introSpiderPose(states[0].intro.x, resolution);
    float reach = 3.3f * pose.radius;
    float2 lower = float2(min(pose.anchor.x, pose.centre.x) - reach, 0.0f);
    float2 upper = float2(max(pose.anchor.x, pose.centre.x) + reach,
        pose.centre.y + reach);
    upper += 0.7f * pose.radius;   // room for the shadow
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    float2 pixel = mix(lower, upper, corners[vertexID]);
    IntroVertex result;
    result.position = pose.visible
        ? float4(pixel.x * 2.0f / resolution.x - 1.0f,
            1.0f - pixel.y * 2.0f / resolution.y, 0.0f, 1.0f)
        : float4(-2.0f, -2.0f, 0.0f, 1.0f);
    return result;
}

// Composites one layer over the colour gathered so far.
void introOver(thread float4 &gathered, float3 color, float alpha) {
    gathered.rgb = color * alpha + gathered.rgb * (1.0f - alpha);
    gathered.a = alpha + gathered.a * (1.0f - alpha);
}

fragment float4 introSpiderFragment(IntroVertex in [[stage_in]],
    constant ProgramUniforms &u [[buffer(0)]],
    device const GameState *states [[buffer(1)]]) {
    float2 resolution = u.resolutionTime.xy;
    IntroSpiderPose pose = introSpiderPose(states[0].intro.x, resolution);
    if (!pose.visible) return float4(0.0f);
    float2 pixel = in.position.xy;
    float radius = pose.radius;
    float pixelSize = 1.0f / radius;          // one pixel in body radii
    float4 gathered = float4(0.0f);
    // Screen light from the upper left, toward the viewer.
    const float3 light = normalize(float3(-0.45f, -0.65f, 0.6f));

    IntroLeg legs[8];
    for (uint i = 0u; i < 8u; ++i)
        legs[i] = introSpiderLeg(pose, i % 4u, i < 4u ? -1.0f : 1.0f);
    float2 q = introRotate(pixel - pose.centre, -pose.heading) * pixelSize;

    // A soft shadow on the screen behind it, wider while it hangs off the
    // glass and tighter once it walks on it.
    {
        float2 offset = mix(float2(0.45f, 0.6f), float2(0.16f, 0.24f),
            pose.walking);
        float softness = mix(0.45f, 0.18f, pose.walking);
        float2 s = introRotate(pixel - pose.centre - offset * radius,
            -pose.heading) * pixelSize;
        float shade = 1.0f - smoothstep(1.0f - softness, 1.08f + softness,
            length(s));
        for (uint i = 0u; i < 8u; ++i) {
            float2 across;
            float d = introLegDistance(s, legs[i], across);
            shade = max(shade, 1.0f - smoothstep(-0.02f, softness * 0.4f, d));
        }
        introOver(gathered, float3(0.0f), 0.34f * shade);
    }

    // Silk dragline from the top edge to the spinnerets, with a glint that
    // runs down it.
    float2 spinneret = pose.centre
        + introRotate(float2(0.0f, -0.88f), pose.heading) * radius;
    {
        float2 pa = pixel - pose.anchor, ba = spinneret - pose.anchor;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 0.0001f));
        float d = length(pa - ba * h);
        float width = max(0.55f * resolution.y / 900.0f, 0.5f);
        float coverage = saturate(width + 0.5f - d);
        float glint = exp(-pow((h - fract(pose.time * 0.45f)) * 9.0f, 2.0f));
        introOver(gathered, mix(float3(0.80f, 0.83f, 0.88f), float3(1.0f),
            glint), coverage * pose.silk * (0.62f + 0.38f * glint));
    }

    // Legs: thin, near-black tubes with a light edge so they read against
    // the dark ceiling.
    for (uint i = 0u; i < 8u; ++i) {
        float2 across;
        float d = introLegDistance(q, legs[i], across);
        float coverage = 1.0f - smoothstep(-pixelSize * 0.5f,
            pixelSize * 0.5f, d);
        if (coverage <= 0.0f) continue;
        float2 n2 = clamp(across, float2(-1.0f), float2(1.0f));
        float3 n = float3(introRotate(n2, pose.heading),
            sqrt(saturate(1.0f - dot(n2, n2))));
        float diffuse = saturate(dot(n, light));
        float sheen = pow(saturate(dot(reflect(-light, n),
            float3(0.0f, 0.0f, 1.0f))), 12.0f);
        float3 color = float3(0.045f, 0.040f, 0.050f)
            + 0.20f * diffuse * float3(0.60f, 0.58f, 0.66f)
            + 0.30f * sheen;
        introOver(gathered, color, coverage);
    }

    // Body: a fuzzy ball. Fur spikes form the outline, fine strands run out
    // from the centre and a grey rim catches the light.
    float r = length(q);
    float angle = atan2(q.y, q.x) + rangePi;
    float outline = introFurRadius(angle);
    float body = 1.0f - smoothstep(outline - pixelSize, outline + pixelSize, r);
    if (body > 0.0f) {
        float inner = saturate(r);
        float2 screenQ = introRotate(q, pose.heading);
        float3 n = float3(screenQ / max(r, 0.0001f) * inner,
            sqrt(saturate(1.0f - inner * inner)));
        float diffuse = saturate(dot(n, light));
        float strands = 0.82f + 0.18f * sin(angle * 90.0f
            + 7.0f * sin(r * 9.0f + angle * 5.0f));
        float rim = smoothstep(0.72f, 1.12f, r);
        float3 color = float3(0.035f, 0.031f, 0.040f) * strands
            + 0.17f * diffuse * float3(0.55f, 0.53f, 0.60f) * strands
            + rim * (0.05f + 0.30f * saturate(dot(n.xy, light.xy)))
                * float3(0.62f, 0.60f, 0.68f);
        introOver(gathered, color, body);
    }

    // Two big white eyes with pupils, glints and blinking lids.
    for (uint i = 0u; i < 2u; ++i) {
        float side = i == 0u ? -1.0f : 1.0f;
        float2 eyeCentre = float2(side * 0.33f, 0.22f);
        const float2 eyeRadius = float2(0.30f, 0.36f);
        float2 e = (q - eyeCentre) / eyeRadius;
        float eyeDistance = (length(e) - 1.0f) * eyeRadius.x;
        float eye = 1.0f - smoothstep(-pixelSize, pixelSize, eyeDistance);
        if (eye <= 0.0f) continue;
        float3 white = mix(float3(0.98f, 0.98f, 0.96f),
            float3(0.78f, 0.79f, 0.82f), smoothstep(-0.2f, 1.0f, e.y));
        float2 pupilCentre = eyeCentre + pose.gaze * float2(0.13f, 0.16f);
        float pupil = 1.0f - smoothstep(0.145f - pixelSize,
            0.145f + pixelSize, length(q - pupilCentre));
        float glint = 1.0f - smoothstep(0.045f - pixelSize,
            0.045f + pixelSize,
            length(q - pupilCentre - float2(-0.05f, -0.06f)));
        float3 color = mix(white, float3(0.015f), pupil);
        color = mix(color, float3(1.0f), glint * pupil);
        // Bowed lids in the fur colour meet below the middle of the eye,
        // and a pale rim on the upper lid marks the closed eye.
        float bow = 0.06f * (1.0f - e.x * e.x);
        float upperEdge = eyeCentre.y - eyeRadius.y
            + (1.45f * eyeRadius.y + bow) * pose.blink;
        float lowerEdge = eyeCentre.y + eyeRadius.y
            - (0.55f * eyeRadius.y - bow) * pose.blink;
        float lid = max(1.0f - smoothstep(upperEdge - pixelSize,
                upperEdge + pixelSize, q.y),
            saturate(pose.blink * 10.0f) * smoothstep(lowerEdge - pixelSize,
                lowerEdge + pixelSize, q.y));
        color = mix(color, float3(0.07f, 0.065f, 0.08f), lid);
        float aboveRim = upperEdge - q.y;
        float rim = smoothstep(-pixelSize, pixelSize, aboveRim)
            * (1.0f - smoothstep(0.035f, 0.035f + 2.0f * pixelSize, aboveRim))
            * saturate(pose.blink * 3.0f);
        color = mix(color, float3(0.52f, 0.52f, 0.58f), rim);
        introOver(gathered, color, eye);
    }

    if (gathered.a <= 0.0f) return float4(0.0f);
    return float4(saturate(gathered.rgb / gathered.a), gathered.a);
}

// Bats for HauntedHouseProgram.metal: flocks of six to fifteen that come out
// once the sun has set, flit low along the street under its lamps and circle
// the haunted house and its spire. The program sets batFlockCount and
// batFlockSize, keeps the Bat poses in its game state, and includes this
// file after its lighting, just before rangeFragment.
//
// Flights are a function of the time of day alone. advanceBats, a tick pass
// of its own, works out where every bat is and stores its pose; the view
// only reads the poses. Each flock flies one flight per period along a
// route of control points eased through as a Catmull-Rom curve: out of the
// belfry window and away along the street, the length of the street, along
// the street and around the spire, or in from behind the house, once
// around it and off over the street. The bats follow their leader at a few
// metres' spacing, each keeping its own place beside the line and
// fluttering about it, and bank into the turns.
//
// A bat is traced as a furry body and head with ears, eyes and legs, and
// two wings of thin skin. Each wing is two flat panels, the arm's from the
// shoulder to the wrist and the hand's beyond it, hinged so that the hand
// lags the beat and folds in on the upstroke. The skin is cut to a bat's
// outline, scalloped between the finger tips, and the finger bones show on
// it. Lit from behind, the skin glows a warm red.

constant uint batMembraneMaterial = 66u;
constant uint batSkinMaterial = 67u;    // ears, legs and finger bones
constant uint batFurMaterial = 68u;
constant uint batEyeMaterial = 69u;
constant float batReach = 0.68f;         // bounding radius at size 1
constant float batWingbeat = 4.2f;       // beats per second
constant uint batRouteCapacity = 20u;
constant uint batRouteBelfry = 0u;
constant uint batRouteStreet = 1u;
constant uint batRouteSpire = 2u;
constant uint batRouteRing = 3u;
// Seconds between a flock's flights, and when after dusk its first leaves.
constant float batPeriods[batFlockCount] = {52.0f, 67.0f};
constant float batOffsets[batFlockCount] = {1.0f, 19.0f};

// Front-facing wing coordinates, in metres from the shoulder. Long finger
// bones fan across a broad membrane whose trailing edge falls into scallops.
constant float2 batWrist = float2(0.18f, 0.035f);
constant float2 batTip = float2(0.54f, 0.145f);
constant float2 batFourth = float2(0.45f, -0.09f);
constant float2 batFifth = float2(0.29f, -0.17f);
constant float2 batAnkle = float2(0.01f, -0.18f);
constant float2 batFlank = float2(-0.045f, -0.085f);
constant float2 batShoulder = float2(0.055f, 0.025f);

bool batMaterial(uint material) {
    return material >= batMembraneMaterial && material <= batEyeMaterial;
}

// The time of day when the sun's disc has fully set: daylight's sine of
// the sun's height runs from 1 at noon to -0.1 over dayNightDuration.
float batDusk() {
    return enableDayNightTransition
        ? dayNightDuration * (1.0f + sunRadius) / 1.1f : 0.0f;
}

// ------------------------------------------------------------------ flights

struct BatRoute {
    float3 points[batRouteCapacity];
    float lengths[batRouteCapacity];   // chord length up to each point
    uint count;
};

void batAdd(thread BatRoute &route, float3 p) {
    if (route.count >= batRouteCapacity) return;
    route.lengths[route.count] = route.count == 0u ? 0.0f
        : route.lengths[route.count - 1u]
            + distance(route.points[route.count - 1u], p);
    route.points[route.count] = p;
    route.count += 1u;
}

// Points on a circle around centre (world x and z), from angle `from` to
// `to` in radians, climbing from height `low` to `high`.
void batCircle(thread BatRoute &route, float2 centre, float radius,
    float from, float to, float low, float high, uint steps, float side) {
    for (uint i = 0u; i <= steps; ++i) {
        float f = float(i) / float(steps);
        float a = mix(from, to, f);
        batAdd(route, float3(side * (centre.x + radius * cos(a)),
            mix(low, high, f) + 0.8f * sin(a * 1.7f),
            centre.y + radius * sin(a)));
    }
}

// The control points of a route. Side mirrors it across the path from the
// base, so it runs either way along the street; lift raises its open
// stretches a little.
void batBuildRoute(thread BatRoute &route, uint kind, float side,
    float lift) {
    route.count = 0u;
    float s = side, h = lift;
    if (kind == batRouteBelfry) {
        // Out of the belfry's front window, low over the gable's ridge, down
        // over the front garden and away along the street under its lamps.
        batAdd(route, float3(0.0f, 28.3f, 125.0f));
        batAdd(route, float3(0.0f, 28.4f, 121.3f));
        batAdd(route, float3(0.0f, 28.2f, 116.0f));
        batAdd(route, float3(0.4f * s, 27.5f, 109.5f));
        batAdd(route, float3(3.0f * s, 22.0f, 97.0f));
        batAdd(route, float3(10.0f * s, 15.0f, 78.0f));
        batAdd(route, float3(20.0f * s, 10.0f, 57.0f));
        batAdd(route, float3(38.0f * s, 7.5f + h, 42.5f));
        batAdd(route, float3(75.0f * s, 7.0f + h, 37.5f));
        batAdd(route, float3(130.0f * s, 8.0f + h, 39.5f));
        batAdd(route, float3(190.0f * s, 10.0f, 37.0f));
        batAdd(route, float3(270.0f * s, 12.0f, 38.0f));
    } else if (kind == batRouteStreet) {
        // The length of the street, weaving just under the lamps' heads.
        batAdd(route, float3(270.0f * s, 10.0f, 37.0f));
        batAdd(route, float3(180.0f * s, 8.0f + h, 41.0f));
        batAdd(route, float3(110.0f * s, 6.5f + h, 35.5f));
        batAdd(route, float3(55.0f * s, 6.0f + h, 40.0f));
        batAdd(route, float3(5.0f * s, 6.5f + h, 36.5f));
        batAdd(route, float3(-45.0f * s, 7.0f + h, 40.5f));
        batAdd(route, float3(-100.0f * s, 6.5f + h, 36.0f));
        batAdd(route, float3(-165.0f * s, 7.5f + h, 40.0f));
        batAdd(route, float3(-270.0f * s, 10.0f, 38.0f));
    } else if (kind == batRouteSpire) {
        // Low along the street, up over the front roof, once around the
        // belfry and the spire above the chimneys, and off behind the house.
        batAdd(route, float3(270.0f * s, 10.0f, 39.0f));
        batAdd(route, float3(170.0f * s, 8.0f + h, 37.0f));
        batAdd(route, float3(95.0f * s, 7.0f + h, 40.0f));
        batAdd(route, float3(48.0f * s, 9.0f, 48.0f));
        batAdd(route, float3(24.0f * s, 14.0f, 68.0f));
        batAdd(route, float3(17.0f * s, 22.0f, 95.0f));
        batCircle(route, float2(0.0f, 124.8f), 17.0f, 0.384f, 7.453f,
            27.0f, 31.0f, 9u, s);
        batAdd(route, float3(-14.0f * s, 33.0f, 152.0f));
        batAdd(route, float3(-40.0f * s, 38.0f, 185.0f));
        batAdd(route, float3(-80.0f * s, 45.0f, 250.0f));
        batAdd(route, float3(-130.0f * s, 52.0f, 330.0f));
    } else {
        // Down from behind the house, once and a quarter around it below
        // its eaves, then north low over the street and on over the base.
        batAdd(route, float3(40.0f * s, 30.0f, 300.0f));
        batAdd(route, float3(34.0f * s, 20.0f, 225.0f));
        batAdd(route, float3(30.0f * s, 13.0f + h, 168.0f));
        batCircle(route, float2(0.0f, 125.0f), 28.0f, 0.0f, -7.854f,
            11.0f + h, 10.0f + h, 10u, s);
        batAdd(route, float3(-25.0f * s, 9.0f + h, 84.0f));
        batAdd(route, float3(-45.0f * s, 7.5f + h, 55.0f));
        batAdd(route, float3(-62.0f * s, 12.0f, 15.0f));
        batAdd(route, float3(-85.0f * s, 20.0f, -60.0f));
        batAdd(route, float3(-115.0f * s, 30.0f, -160.0f));
    }
}

// The point `along` metres into a route, measured on its chords.
float3 batRoutePoint(thread const BatRoute &route, float along) {
    uint n = route.count;
    along = clamp(along, 0.0f, route.lengths[n - 1u]);
    uint i = 0u;
    while (i + 2u < n && route.lengths[i + 1u] < along) i += 1u;
    float f = (along - route.lengths[i])
        / max(route.lengths[i + 1u] - route.lengths[i], 0.001f);
    float3 p1 = route.points[i], p2 = route.points[i + 1u];
    float3 p0 = i > 0u ? route.points[i - 1u] : 2.0f * p1 - p2;
    float3 p3 = i + 2u < n ? route.points[i + 2u] : 2.0f * p2 - p1;
    return 0.5f * (2.0f * p1 + (p2 - p0) * f
        + (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * f * f
        + (3.0f * p1 - p0 - 3.0f * p2 + p3) * f * f * f);
}

struct BatFlight {
    BatRoute route;
    float start;     // time of day the leader sets off
    float speed;     // metres per second
    float spacing;   // metres between one bat and the next along the route
    uint size;
    float seed;
};

// The flight flock is on at time of day `clock`, or false between flights
// and before dusk. Each flight starts somewhere in its period and ends
// before the next can begin. The first after dusk leaves at once: the first
// flock pours out of the belfry, the second comes along the street.
bool batFlight(uint flock, float clock, thread BatFlight &flight) {
    float since = clock - batDusk() - batOffsets[flock];
    if (since < 0.0f) return false;
    float period = batPeriods[flock];
    float number = floor(since / period);
    float seed = number * 7.31f + float(flock) * 101.7f;
    uint kind = number == 0.0f
        ? (flock == 0u ? batRouteBelfry : batRouteStreet)
        : min(uint(houseHash(seed) * 4.0f), 3u);
    batBuildRoute(flight.route, kind,
        houseHash(seed + 1.0f) < 0.5f ? -1.0f : 1.0f,
        1.5f * houseHash(seed + 2.0f) - 0.5f);
    flight.size = min(6u + uint(houseHash(seed + 3.0f) * 10.0f),
        batFlockSize);
    flight.spacing = mix(1.6f, 3.2f, houseHash(seed + 4.0f));
    float travel = flight.route.lengths[flight.route.count - 1u]
        + flight.spacing * float(flight.size - 1u);
    flight.speed = max(mix(9.5f, 12.5f, houseHash(seed + 5.0f)),
        travel / (period - 4.0f));
    float duration = travel / flight.speed;
    float slack = number == 0.0f ? 0.0f
        : max(period - 4.0f - duration, 0.0f) * houseHash(seed + 6.0f);
    flight.start = batDusk() + batOffsets[flock] + number * period + slack;
    flight.seed = seed;
    return clock >= flight.start && clock <= flight.start + duration;
}

// Places bat j of a flight, or takes it out of the sky while it is not yet
// out or has gone.
void placeBat(device Bat &bat, thread const BatFlight &flight, uint j,
    float clock) {
    float along = (clock - flight.start) * flight.speed
        - float(j) * flight.spacing;
    if (along < 0.0f
        || along > flight.route.lengths[flight.route.count - 1u]) {
        bat.pose = float4(0.0f);
        return;
    }
    float seed = flight.seed + float(j) * 13.7f;
    const float step = 1.5f;
    float3 before = batRoutePoint(flight.route, along - step);
    float3 centre = batRoutePoint(flight.route, along);
    float3 after = batRoutePoint(flight.route, along + step);
    float3 forward = normalize(after - before);
    float3 side = cross(forward, float3(0.0f, 1.0f, 0.0f));
    side = dot(side, side) > 1.0e-4f ? normalize(side) : float3(1.0f, 0.0f, 0.0f);
    // Its own place beside the line, eased in from the start so a flock
    // leaves the belfry in single file, and an erratic flutter about it.
    float t = clock + seed;
    float spread = smoothstep(0.0f, 14.0f, along);
    float lateral = 6.0f * (houseHash(seed + 1.0f) - 0.5f)
        + 0.45f * sin(1.7f * t) + 0.2f * sin(4.3f * t + 1.0f);
    float vertical = 3.0f * (houseHash(seed + 2.0f) - 0.5f)
        + 0.3f * sin(2.3f * t + 2.0f) + 0.12f * sin(5.1f * t);
    centre += (side * lateral + float3(0.0f, vertical, 0.0f)) * spread;
    // Lift carries the weight and turns the bat, so it banks into a turn.
    float3 turn = (before - 2.0f * centre + after) / (step * step)
        * flight.speed * flight.speed;
    float3 up = float3(0.0f, 9.81f, 0.0f) + turn;
    up.xz *= min(1.0f, 14.0f / max(length(up.xz), 0.001f));
    up = normalize(up - forward * dot(up, forward));
    // A bat climbs on full strokes, glides down and now and then holds its
    // wings out for a moment.
    float glide = smoothstep(0.62f, 0.8f,
        smoothNoise(float2(t * 0.45f, seed)));
    glide = max(glide, smoothstep(-0.08f, -0.3f, forward.y));
    float rate = batWingbeat * mix(0.9f, 1.12f, houseHash(seed + 4.0f));
    float phase = 2.0f * rangePi
        * fract(rate * clock + houseHash(seed + 5.0f));
    bat.pose = float4(centre, mix(0.85f, 1.15f, houseHash(seed + 3.0f)));
    bat.heading = float4(forward, phase);
    bat.lift = float4(up, mix(1.0f, 0.22f, glide));
}

kernel void advanceBats(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float clock = dayClock(game);
    for (uint flock = 0u; flock < batFlockCount; ++flock) {
        BatFlight flight;
        bool flying = batFlight(flock, clock, flight);
        for (uint j = 0u; j < batFlockSize; ++j) {
            device Bat &bat = game.bats[flock * batFlockSize + j];
            if (flying && j < flight.size) placeBat(bat, flight, j, clock);
            else bat.pose = float4(0.0f);
        }
    }
}

// Summoned bats leave the unseen rear of the house. They orbit on both
// sides, dive one or two at a time, and climb back to their circuit after
// each pass. A contact costs one health but never removes the bat.
kernel void advanceRaidBats(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    if (game.progress.w != phasePlaying) return;
    const float2 centre = float2(0.0f, 128.0f);
    const float orbitRadius = 26.0f;
    if (game.gesture.w > 0.5f && game.batRaid.x == 0u
        && game.batRaid.w == 0u) {
        game.batRaid.x = 1u;
        game.batRaid.yz = uint2(0u);
        game.batRaid.w = 1u;
        for (uint i = 0u; i < raidBatCount; ++i) {
            float angle = 0.5f * rangePi
                + (float(i) - 0.5f * float(raidBatCount - 1u)) * 0.085f;
            float3 start = float3(orbitRadius * cos(angle),
                20.0f + 1.0f * float(i % 3u),
                centre.y + orbitRadius * sin(angle));
            device Bat &bat = game.raidBats[i];
            bat.pose = float4(start, 1.65f);
            bat.heading = float4(0.0f, 0.0f, -1.0f, 0.0f);
            bat.lift = float4(0.0f, 1.0f, 0.0f, 1.0f);
            game.raidFlight[i] = float4(angle, 0.0f,
                game.effects.x + 4.0f + 1.2f * float(i), -100.0f);
        }
    }
    if (game.batRaid.x == 0u) return;
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.10f);
    uint diving = 0u;
    for (uint i = 0u; i < raidBatCount; ++i)
        if (game.raidBats[i].pose.w > 0.0f
            && game.raidFlight[i].y > 0.5f
            && game.raidFlight[i].y < 1.5f) diving += 1u;
    for (uint i = 0u; i < raidBatCount; ++i) {
        device Bat &bat = game.raidBats[i];
        if (bat.pose.w <= 0.0f) continue;
        device float4 &flight = game.raidFlight[i];
        float directionSign = i % 2u == 0u ? 1.0f : -1.0f;
        float angularSpeed = directionSign * (0.39f + 0.025f * float(i % 3u));
        float altitude = 20.0f + 1.0f * float(i % 3u);
        float speed = 12.0f + 0.45f * float(i);
        float3 target;
        if (flight.y < 0.5f) {
            flight.x += angularSpeed * dt;
            target = float3(orbitRadius * cos(flight.x), altitude,
                centre.y + orbitRadius * sin(flight.x));
            float2 playerOffset = game.player.xz - centre;
            float towardPlayer = dot(playerOffset
                    / max(length(playerOffset), 0.001f),
                normalize(target.xz - centre));
            if (diving == 0u && game.effects.x >= flight.z
                && length(playerOffset) > 21.0f && towardPlayer > 0.5f) {
                flight.y = 1.0f;
                flight.w = game.effects.x;
                diving += 1u;
            }
        }
        if (flight.y > 0.5f && flight.y < 1.5f) {
            target = game.player.xyz + float3(0.0f, 0.15f, 0.0f);
            if (distance(target, bat.pose.xyz) < 1.0f) {
                game.batRaid.z += 1u;
                damagePlayer(game, 1.0f, bat.pose.xz, 0.28f);
                flight.y = 2.0f;
            } else if (game.effects.x - flight.w > 3.2f) {
                flight.y = 2.0f;
            }
            if (flight.y > 1.5f) {
                flight.x = atan2(bat.pose.z - centre.y, bat.pose.x);
                flight.z = game.effects.x + 7.0f + 1.0f * float(i);
            }
        }
        if (flight.y > 1.5f) {
            target = float3(orbitRadius * cos(flight.x), altitude,
                centre.y + orbitRadius * sin(flight.x));
            if (distance(target, bat.pose.xyz) < 1.5f) flight.y = 0.0f;
        }
        float3 toward = target - bat.pose.xyz;
        float remaining = length(toward);
        float3 forward = remaining > 0.001f
            ? toward / remaining : bat.heading.xyz;
        bat.pose.xyz += forward * min(speed * dt, remaining);
        bat.heading = float4(forward,
            2.0f * rangePi * fract(batWingbeat * game.effects.x
                + float(i) * 0.19f));
        float3 up = float3(0.0f, 1.0f, 0.0f)
            - forward * forward.y;
        up = dot(up, up) > 1.0e-4f
            ? normalize(up) : float3(0.0f, 0.0f, 1.0f);
        bat.lift = float4(up, 1.0f);
    }
}

// Shotgun pellets use a generous flying silhouette for fast, reliable hits.
// Ordinary bullets still meet the bats but cannot end the supernatural raid.
int traceRaidBatShot(float3 eye, float3 direction,
    device const GameState &game, thread float &limit,
    thread float3 &normal) {
    int target = -1;
    for (uint i = 0u; i < raidBatCount; ++i) {
        Bat bat = game.raidBats[i];
        if (bat.pose.w <= 0.0f) continue;
        float3 offset = eye - bat.pose.xyz;
        float b = dot(offset, direction);
        float radius = 0.55f * bat.pose.w;
        float disc = b * b - dot(offset, offset) + radius * radius;
        if (disc < 0.0f) continue;
        float t = -b - sqrt(disc);
        if (t <= 0.0f || t >= limit) continue;
        limit = t;
        normal = normalize(eye + direction * t - bat.pose.xyz);
        target = int(i);
    }
    return target;
}

// ----------------------------------------------------------------- geometry

float batCross(float2 a, float2 b) {
    return a.x * b.y - a.y * b.x;
}

// Whether x lies in the wedge of skin the wrist fans out between finger
// tips p and q, behind the trailing edge's scallop between them.
bool batWedge(float2 x, float2 p, float2 q, float scallop) {
    float2 a = p - batWrist, b = q - batWrist, r = x - batWrist;
    float turn = batCross(a, b);
    if (batCross(a, r) * turn < 0.0f || batCross(r, b) * turn < 0.0f)
        return false;
    float2 edge = q - p;
    float span = length(edge);
    float inside = batCross(edge, x - p) / span
        * sign(batCross(edge, batWrist - p));
    float f = saturate(dot(x - p, edge) / (span * span));
    return inside >= scallop * span * 4.0f * f * (1.0f - f);
}

float batSegment(float2 x, float2 a, float2 b) {
    float2 ab = b - a;
    float f = saturate(dot(x - a, ab) / dot(ab, ab));
    return distance(x, a + ab * f);
}

// What a spread wing has at x: 0 nothing, 1 skin, 2 bone.
uint batWing(float2 x, float tipLift) {
    float2 tip = batTip + float2(-0.025f, tipLift);
    float2 fourth = batFourth + float2(-0.012f, 0.45f * tipLift);
    float bone = min(batSegment(x, float2(0.0f), batWrist) - 0.008f,
        batSegment(x, batWrist, tip) - 0.0055f);
    bone = min(bone, min(batSegment(x, batWrist, fourth),
        batSegment(x, batWrist, batFifth)) - 0.004f);
    if (bone < 0.0f) return 2u;
    bool skin = batWedge(x, tip, fourth, 0.18f)
        || batWedge(x, fourth, batFifth, 0.22f)
        || batWedge(x, batFifth, batAnkle, 0.16f)
        || batWedge(x, batAnkle, batFlank, 0.07f)
        || batWedge(x, batFlank, float2(-0.05f, 0.01f), 0.0f);
    return skin ? 1u : 0u;
}

// The membrane faces the direction of flight, so a dive presents its
// spread wings to the player instead of showing their edges.
void batPanel(thread SpiderHit &hit, float3 o, float3 d, float side,
    float flap, float tipLift) {
    if (abs(d.z) < 1.0e-5f) return;
    float t = (0.015f - o.z) / d.z;
    if (t <= 0.0f || t >= hit.distance) return;
    float3 p = o + d * t;
    float2 q = float2(side * p.x, p.y) - batShoulder;
    float c = cos(flap), s = sin(flap);
    float2 spread = float2(c * q.x + s * q.y,
        -s * q.x + c * q.y);
    uint part = batWing(spread, tipLift);
    if (part == 0u) return;
    hit.distance = t;
    hit.normal = float3(0.0f, 0.0f, d.z > 0.0f ? -1.0f : 1.0f);
    hit.material = part == 2u ? batSkinMaterial : batMembraneMaterial;
}

// A bat in its own frame, at size 1: x right, y up, z forward.
SpiderHit traceBatLocal(float3 o, float3 d, float limit, float phase,
    float amplitude) {
    SpiderHit hit = {limit, float3(0.0f), 0u, float3(0.0f), float4(0.0f)};
    acceptSpiderEllipsoid(hit, o, d, float3(0.0f, -0.035f, 0.015f),
        float3(0.073f, 0.095f, 0.078f), batFurMaterial);
    acceptSpiderSphere(hit, o, d, float3(0.0f, 0.065f, 0.065f), 0.057f,
        batFurMaterial);
    acceptSpiderEllipsoid(hit, o, d, float3(0.0f, 0.037f, 0.119f),
        float3(0.024f, 0.018f, 0.022f), batSkinMaterial);
    float flap = 0.12f + 0.42f * amplitude * cos(phase);
    float tipLift = 0.05f * amplitude * cos(phase - 1.1f);
    for (uint i = 0u; i < 2u; ++i) {
        float side = i == 0u ? -1.0f : 1.0f;
        acceptSpiderEllipsoid(hit, o, d,
            float3(0.051f * side, 0.125f, 0.065f),
            float3(0.018f, 0.05f, 0.019f), batSkinMaterial);
        acceptSpiderSphere(hit, o, d,
            float3(0.025f * side, 0.072f, 0.113f),
            0.0055f, batEyeMaterial);
        acceptSpiderLeg(hit, o, d,
            float3(0.037f * side, -0.115f, 0.016f),
            float3(0.052f * side, -0.19f, 0.012f),
            0.005f, batSkinMaterial);
        batPanel(hit, o, d, side, flap, tipLift);
    }
    // A narrow tail membrane joins the ankles below the body.
    if (abs(d.z) > 1.0e-5f) {
        float t = (0.0f - o.z) / d.z;
        float3 p = o + d * t;
        float width = 0.085f * saturate((p.y + 0.22f) / 0.13f);
        if (t > 0.0f && t < hit.distance && p.y < -0.09f
            && p.y > -0.22f && abs(p.x) < width) {
            hit.distance = t;
            hit.normal = float3(0.0f, 0.0f, d.z > 0.0f ? -1.0f : 1.0f);
            hit.material = batMembraneMaterial;
        }
    }
    return hit;
}

// The nearest bat along the ray before hit.distance joins the scene; the
// variant names the bat.
void traceBats(thread SceneHit &hit, float3 origin, float3 direction,
    device const GameState &game) {
    for (uint i = 0u; i < batCount + raidBatCount; ++i) {
        Bat bat = i < batCount ? game.bats[i]
            : game.raidBats[i - batCount];
        float size = bat.pose.w;
        if (size <= 0.0f) continue;
        float3 offset = origin - bat.pose.xyz;
        float b = dot(offset, direction);
        float reach = batReach * size;
        if (b > 0.0f || b * b - dot(offset, offset) + reach * reach < 0.0f
            || -b - reach > hit.distance) continue;
        float3 forward = bat.heading.xyz, up = bat.lift.xyz;
        float3x3 basis = float3x3(cross(forward, up), up, forward);
        float3x3 toLocal = transpose(basis);
        SpiderHit local = traceBatLocal(toLocal * offset / size,
            toLocal * direction, hit.distance / size, bat.heading.w,
            bat.lift.w);
        if (local.material == 0u) continue;
        float distance = local.distance * size;
        hit = {distance, normalize(basis * local.normal),
            origin + direction * distance, local.material, -1, i};
    }
}

// ------------------------------------------------------------------ shading

SurfaceMaterial batSurfaceMaterial(uint material, bool raiding) {
    if (material == batFurMaterial)
        return {raiding ? float3(0.24f, 0.14f, 0.09f)
                : float3(0.075f, 0.052f, 0.038f),
            0.85f, 0.0f, raiding ? float3(0.055f, 0.028f, 0.013f)
                : float3(0.0f)};
    if (material == batSkinMaterial)
        return {raiding ? float3(0.17f, 0.085f, 0.06f)
                : float3(0.065f, 0.045f, 0.04f),
            0.6f, 0.0f, raiding ? float3(0.035f, 0.016f, 0.008f)
                : float3(0.0f)};
    if (material == batEyeMaterial)
        return {raiding ? float3(0.008f, 0.007f, 0.006f)
                : float3(0.01f, 0.005f, 0.005f), 0.1f, 0.0f,
            raiding ? float3(0.01f, 0.009f, 0.007f)
                : float3(0.22f, 0.02f, 0.01f)};
    return {raiding ? float3(0.23f, 0.115f, 0.075f)
            : float3(0.05f, 0.034f, 0.03f),
        0.5f, 0.0f, raiding ? float3(0.045f, 0.021f, 0.01f)
            : float3(0.0f)};
}

// Light the Earth and the sun shine through a wing from behind it, warmest
// when the bat crosses in front of them.
float3 batTranslucency(SceneHit hit, float3 direction,
    device const GameState &game) {
    if (hit.material != batMembraneMaterial) return float3(0.0f);
    float3 tint = hit.variant >= batCount
        ? float3(0.11f, 0.045f, 0.025f)
        : float3(0.1f, 0.028f, 0.012f);
    float3 light = earthColor * 1.4f * saturate(-dot(hit.normal,
            earthDirection))
        * (1.0f + pow(saturate(dot(direction, earthDirection)), 8.0f));
    Daylight sun = daylight(dayClock(game));
    if (sun.strength > 0.0f)
        light += sunColor * sunTransmittance(sun) * sunIrradiance
            * sun.strength * saturate(-dot(hit.normal, sun.direction))
            * (1.0f + pow(saturate(dot(direction, sun.direction)), 8.0f));
    return tint * light / rangePi;
}

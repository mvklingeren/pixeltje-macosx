// Signal Range quadcopter drones: flight, the laser rifle they turn on the
// player once shot at, their navigation lights, and the hover sound.
// Included by SignalRangeFPSProgram.metal after shared game state.
//
// Flight follows a real multirotor. Rotors only push along the body's up
// axis, so a drone moves sideways by tilting toward where it wants to go:
// horizontal acceleration is gravity times the tangent of the tilt. The
// flight controller turns a target position into a target velocity and that
// into a target tilt, which the airframe reaches with a short lag; the lag
// gives the slight overshoot and settling of a real drone, and gusts keep
// it from hanging perfectly still.

constant float droneHealth = 3.0f;
// A pistol round or a blast step costs a drone one point; a shotgun pellet
// only part of one, so each barrel visibly drains its power bar.
constant float dronePelletDamage = 0.25f;
constant float droneBarDrain = 2.0f;      // health per second the bar runs down
constant float droneGravity = 9.81f;      // the tilt a drone needs, as on Earth
constant float droneFallGravity = 13.0f;  // matches the player's jumps
constant float droneTiltLag = 0.16f;      // seconds for the frame to follow
constant float droneMaxTilt = 0.75f;      // tangent: about 37 degrees
constant float droneLoiterSpeed = 3.5f;
constant float droneAttackSpeed = 9.0f;
constant float droneBoundingRadius = 0.58f;
constant float droneRotorRadius = 0.15f;
constant float droneLaserSpeed = 55.0f;
constant float droneBoltLength = 1.5f;
constant float droneLaserDamage = 9.0f;
constant float droneLaserRange = 260.0f;
constant float droneChargeTime = 0.4f;   // the emitter glows before a shot

constant uint droneShellMaterial = 50u;
constant uint droneCanopyMaterial = 51u;
constant uint droneFrameMaterial = 52u;
constant uint droneMotorMaterial = 53u;
constant uint droneRifleMaterial = 54u;
constant uint droneEmitterMaterial = 55u;
constant uint droneRedLightMaterial = 56u;
constant uint droneBlueLightMaterial = 57u;

float sphereSoftShadow(float3 origin, float3 direction, float lightDistance,
    float4 sphere);

bool droneMaterial(uint material) {
    return material >= droneShellMaterial && material <= droneBlueLightMaterial;
}

bool droneFlying(device const GameState &game, uint index) {
    return game.drones[index].pose.w > 0.0f;
}

// Each drone keeps station south of the exit until it is shot at.
float2 droneStation(uint index) {
    const float2 stations[droneCount] = {
        float2(-17.0f, 44.0f), float2(15.0f, 58.0f), float2(37.0f, 33.0f)};
    return stations[index];
}

void resetDrones(device GameState &game) {
    for (uint i = 0u; i < droneCount; ++i) {
        float2 station = droneStation(i);
        float height = 5.5f + 1.3f * float(i);
        game.drones[i].pose = float4(station.x,
            stairHeight(station) + height, station.y, droneHealth);
        game.drones[i].velocity = float4(0.0f, 0.0f, 0.0f,
            1.3f * float(i) - 1.0f);
        game.drones[i].attitude = float4(0.0f, 0.0f, 0.0f, 1.0f);
        game.drones[i].brain = float4(0.0f, 0.0f, droneHealth, -1.0f);
        game.drones[i].wander = float4(station, height, 2.1f * float(i));
    }
    for (uint i = 0u; i < laserCount; ++i) {
        game.lasers[i].startTime = float4(0.0f, 0.0f, 0.0f, -100.0f);
        game.lasers[i].endHit = float4(0.0f);
    }
    game.burst = uint4(0u);
}

// Body axes in world space: X right, Y along the rotor thrust, Z forward
// toward the rifle. The attitude stores the tilt as its tangent vector.
float3x3 droneBasis(Drone drone) {
    float3 up = normalize(float3(drone.attitude.x, 1.0f, drone.attitude.y));
    float yaw = drone.velocity.w;
    float3 heading = float3(sin(yaw), 0.0f, -cos(yaw));
    float3 forward = normalize(heading - up * dot(heading, up));
    return float3x3(cross(forward, up), up, forward);
}

float3 droneWorldPoint(Drone drone, float3 local) {
    return drone.pose.xyz + droneBasis(drone) * local;
}

constant float3 droneEmitter = float3(0.0f, -0.085f, 0.282f);
constant float3 droneRedLight = float3(-0.27f, -0.035f, 0.27f);
constant float3 droneBlueLight = float3(0.27f, -0.035f, 0.27f);

float3 droneRotorCentre(uint rotor) {
    return float3(rotor % 2u == 0u ? -0.27f : 0.27f, 0.054f,
        rotor < 2u ? 0.27f : -0.27f);
}

float wrapAngle(float angle) {
    return atan2(sin(angle), cos(angle));
}

constant float droneRoofClearance = 23.0f;  // above the tallest shell block

// Moves a point inside the grown footprint to its nearest edge.
float2 outsideBase(float2 point, float margin) {
    float2 lower = float2(-hullHalfWidth, hullNorth) - margin;
    float2 upper = float2(hullHalfWidth, hullSouth) + margin;
    if (any(point <= lower) || any(point >= upper)) return point;
    float4 gaps = float4(point.x - lower.x, upper.x - point.x,
        point.y - lower.y, upper.y - point.y);
    float nearest = min(min(gaps.x, gaps.y), min(gaps.z, gaps.w));
    if (nearest == gaps.x) point.x = lower.x;
    else if (nearest == gaps.y) point.x = upper.x;
    else if (nearest == gaps.z) point.y = lower.y;
    else point.y = upper.y;
    return point;
}

// What a drone or its wreck rests above: the regolith, or the shell's roof.
float droneGround(float2 point) {
    if (outdoors(point, 0.0f)) return stairHeight(point);
    return point.y > hullFrontLower.z ? hullFrontUpper.y : hullRearUpper.y;
}

// True when the straight path from a to b crosses the grown footprint.
bool pathCrossesBase(float2 a, float2 b, float margin) {
    float2 lower = float2(-hullHalfWidth, hullNorth) - margin;
    float2 upper = float2(hullHalfWidth, hullSouth) + margin;
    float2 travel = b - a;
    float2 safe = select(travel, float2(1.0e-5f),
        abs(travel) < float2(1.0e-5f));
    float2 near = (lower - a) / safe, far = (upper - a) / safe;
    float2 entry = min(near, far), exit = max(near, far);
    return max(max(entry.x, entry.y), 0.0f) <= min(min(exit.x, exit.y), 1.0f);
}

// ---------------------------------------------------------------- geometry

struct DroneHit {
    float distance;
    float3 normal;          // world space
    uint material;
};

DroneHit traceDrone(float3 origin, float3 direction, Drone drone,
    float limit) {
    DroneHit result = {limit, float3(0.0f), 0u};
    if (raySphere(origin, direction, drone.pose.xyz, droneBoundingRadius)
        < 0.0f) return result;
    float3x3 basis = droneBasis(drone);
    float3x3 toLocal = transpose(basis);
    float3 o = toLocal * (origin - drone.pose.xyz);
    float3 d = toLocal * direction;
    SpiderHit hit = {limit, float3(0.0f), 0u, float3(0.0f)};
    acceptSpiderEllipsoid(hit, o, d, float3(0.0f),
        float3(0.13f, 0.062f, 0.20f), droneShellMaterial);
    acceptSpiderEllipsoid(hit, o, d, float3(0.0f, 0.048f, -0.03f),
        float3(0.085f, 0.036f, 0.11f), droneCanopyMaterial);
    for (uint rotor = 0u; rotor < 4u; ++rotor) {
        float3 tip = droneRotorCentre(rotor) * float3(1.0f, 0.0f, 1.0f);
        acceptSpiderLeg(hit, o, d, tip * 0.27f, tip + float3(0.0f, 0.012f, 0.0f),
            0.016f, droneFrameMaterial);
        acceptSpiderLeg(hit, o, d, tip - float3(0.0f, 0.006f, 0.0f),
            tip + float3(0.0f, 0.042f, 0.0f), 0.030f, droneMotorMaterial);
    }
    // The laser rifle hangs under the nose on a short mount.
    acceptSpiderLeg(hit, o, d, float3(0.0f, -0.045f, 0.02f),
        float3(0.0f, -0.078f, 0.02f), 0.014f, droneFrameMaterial);
    acceptSpiderLeg(hit, o, d, float3(0.0f, -0.085f, -0.05f),
        float3(0.0f, -0.085f, 0.262f), 0.021f, droneRifleMaterial);
    acceptSpiderSphere(hit, o, d, droneEmitter, 0.018f, droneEmitterMaterial);
    // Two landing skids on splayed struts.
    for (uint side = 0u; side < 2u; ++side) {
        float x = side == 0u ? -0.10f : 0.10f;
        acceptSpiderLeg(hit, o, d, float3(x, -0.15f, -0.14f),
            float3(x, -0.15f, 0.14f), 0.008f, droneFrameMaterial);
        for (uint end = 0u; end < 2u; ++end) {
            float z = end == 0u ? -0.08f : 0.08f;
            acceptSpiderLeg(hit, o, d, float3(x * 0.6f, -0.05f, z),
                float3(x, -0.15f, z * 1.25f), 0.0065f, droneFrameMaterial);
        }
    }
    acceptSpiderSphere(hit, o, d, droneRedLight, 0.02f, droneRedLightMaterial);
    acceptSpiderSphere(hit, o, d, droneBlueLight, 0.02f, droneBlueLightMaterial);
    if (hit.material != 0u)
        result = {hit.distance, normalize(basis * hit.normal), hit.material};
    return result;
}

// Living drones and wrecks are part of the scene; the variant names the drone.
void traceDrones(thread SceneHit &hit, float3 origin, float3 direction,
    device const GameState &game) {
    for (uint i = 0u; i < droneCount; ++i) {
        DroneHit drone = traceDrone(origin, direction, game.drones[i],
            hit.distance);
        if (drone.material != 0u)
            hit = {drone.distance, drone.normal,
                origin + direction * drone.distance, drone.material, -1, i};
    }
}

// The nearest flying drone a shot strikes before limit, or -1.
int traceDroneShot(float3 origin, float3 direction,
    device const GameState &game, thread float &limit,
    thread float3 &normal, thread uint &material) {
    int struck = -1;
    for (uint i = 0u; i < droneCount; ++i) {
        if (!droneFlying(game, i)) continue;
        DroneHit drone = traceDrone(origin, direction, game.drones[i], limit);
        if (drone.material == 0u) continue;
        limit = drone.distance;
        normal = drone.normal;
        material = drone.material;
        struck = int(i);
    }
    return struck;
}

// Sunlight shadow of each drone body. The drone being shaded skips its own.
float droneShadow(float3 origin, float3 direction, float lightDistance,
    device const GameState &game) {
    float lit = 1.0f;
    for (uint i = 0u; i < droneCount; ++i) {
        float3 centre = game.drones[i].pose.xyz;
        if (distance(origin, centre) < droneBoundingRadius) continue;
        lit *= sphereSoftShadow(origin, direction, lightDistance,
            float4(centre, 0.26f));
    }
    return lit;
}

// --------------------------------------------------------------- behaviour

// A hit turns the drone and every flying drone in radio range hostile.
// Pellets also shove it and kick its frame, which the controller then
// fights to level again.
void damageDrone(device GameState &game, uint index, float3 shotDirection,
    float amount, device RangeAudio &audio) {
    device Drone &drone = game.drones[index];
    if (drone.pose.w <= 0.0f) return;
    drone.pose.w -= amount;
    drone.attitude.z = 0.2f;
    drone.velocity.xyz += shotDirection * 1.2f;
    drone.attitude.xy += shotDirection.xz * 0.35f;
    for (uint i = 0u; i < droneCount; ++i) {
        if (!droneFlying(game, i)
            || distance(game.drones[i].pose.xyz, drone.pose.xyz) > 90.0f)
            continue;
        if (game.drones[i].brain.x < 0.5f) {
            // Turning and aiming take a moment before the first shot.
            game.drones[i].brain.x = 1.0f;
            game.drones[i].brain.y = (i == index ? 0.9f : 1.6f)
                + 0.5f * float(i);
        }
    }
    game.weapon.zw = float2(0.22f, 1.0f);
    if (drone.pose.w > 0.0f) return;
    // Shot down: the motors cut, it tumbles and falls, and sparks burst
    // from where it was hit.
    drone.pose.w = 0.0f;
    drone.brain.w = game.effects.x;
    drone.wander = float4(drone.pose.xyz, 0.0f);
    drone.velocity.xyz += shotDirection * 2.5f + float3(0.0f, 1.5f, 0.0f);
    game.weapon.zw = float2(0.40f, 3.0f);
    audio.droneDown += 1u;
}

// Closest distance between segments ab and cd.
float segmentDistance(float3 a, float3 b, float3 c, float3 d) {
    float3 u = b - a, v = d - c, w = a - c;
    float uu = dot(u, u), uv = dot(u, v), vv = dot(v, v);
    float uw = dot(u, w), vw = dot(v, w);
    float denominator = uu * vv - uv * uv;
    float s = denominator > 1.0e-6f
        ? clamp((uv * vw - vv * uw) / denominator, 0.0f, 1.0f) : 0.0f;
    float t = vv > 1.0e-6f ? clamp((uv * s + vw) / vv, 0.0f, 1.0f) : 0.0f;
    s = uu > 1.0e-6f ? clamp((uv * t - uw) / uu, 0.0f, 1.0f) : 0.0f;
    return length(w + u * s - v * t);
}

void fireDroneLaser(device GameState &game, uint index,
    device RangeAudio &audio) {
    device Drone &drone = game.drones[index];
    float3 muzzle = droneWorldPoint(drone, droneEmitter);
    float3 chest = game.player.xyz - float3(0.0f, 0.35f, 0.0f);
    float range = distance(muzzle, chest);
    // Lead the player's motion over most of the bolt's flight, and scatter
    // more at range so distance and strafing both pay off.
    float3 aim = chest + float3(game.motion.x, 0.0f, game.motion.y)
        * (range / droneLaserSpeed) * 0.7f;
    float key = game.effects.x * 13.7f + float(index) * 3.1f;
    float3 scatter = float3(hashTile(float2(key, 1.0f)),
        hashTile(float2(key, 2.0f)), hashTile(float2(key, 3.0f))) - 0.5f;
    aim += scatter * (0.3f + 0.035f * range);
    float3 direction = normalize(aim - muzzle);
    float3 forward = droneBasis(drone)[2];
    if (dot(forward, direction) < 0.82f) {
        drone.brain.y = 0.15f;          // still turning toward the player
        return;
    }
    ChromePose chrome = {game.chromeRotation, game.chromeCentre.xyz};
    SceneHit sight = {range + 1.0f, float3(0.0f), float3(0.0f), 0u, -1, 0u};
    traceEnvironment(sight, muzzle, normalize(chest - muzzle), chrome, game);
    if (sight.material != 0u && sight.distance < range - 0.6f) {
        drone.brain.y = 0.3f;           // no line of sight: reposition
        return;
    }
    SceneHit hit = {droneLaserRange, float3(0.0f), float3(0.0f), 0u, -1, 0u};
    traceEnvironment(hit, muzzle, direction, chrome, game);
    uint slot = game.burst.y % laserCount;
    game.burst.y += 1u;
    game.lasers[slot].startTime = float4(muzzle, game.effects.x);
    game.lasers[slot].endHit = float4(muzzle + direction * hit.distance,
        hit.material != 0u ? 1.0f : 0.0f);
    audio.laser += 1u;
    drone.brain.y = 1.35f + 0.9f * hashTile(float2(key, 4.0f));
    // The rifle's kick rocks the airframe back.
    drone.velocity.xyz -= direction * 0.5f;
    drone.attitude.xy -= direction.xz * 0.12f;
}

// Spinning down after the motors cut: the wreck falls, tumbles, and comes
// to rest tipped over on the ground.
void fallDrone(device Drone &drone, float dt) {
    float ground = droneGround(drone.pose.xz) + 0.13f;
    if (drone.pose.y <= ground && drone.velocity.y <= 0.0f) {
        drone.pose.y = ground;
        drone.velocity.xyz = float3(0.0f);
        return;
    }
    drone.velocity.y -= droneFallGravity * dt;
    drone.velocity.xyz *= exp(-dt * 0.2f);
    drone.pose.xyz += drone.velocity.xyz * dt;
    float2 tumble = float2(0.9f, 1.7f) * dt;
    drone.attitude.xy = clamp(drone.attitude.xy + tumble, float2(-2.5f),
        float2(2.5f));
    drone.velocity.w += 5.5f * dt;
    if (drone.pose.y < ground) drone.pose.y = ground;
}

void flyDrone(device GameState &game, uint index, float dt,
    device RangeAudio &audio) {
    device Drone &drone = game.drones[index];
    float time = game.effects.x;
    drone.attitude.z = max(drone.attitude.z - dt, 0.0f);
    drone.brain.z = max(drone.brain.z - droneBarDrain * dt, drone.pose.w);
    if (drone.pose.w <= 0.0f) {
        fallDrone(drone, dt);
        return;
    }
    float3 p = drone.pose.xyz;
    float3 v = drone.velocity.xyz;
    bool hostile = drone.brain.x > 0.5f;
    float3 target;
    float targetYaw;
    float speedLimit;
    if (!hostile) {
        // A slow figure-of-eight around the station with gentle height drift.
        float phase = time * 0.19f + drone.wander.w;
        float2 point = drone.wander.xy
            + float2(7.0f * sin(phase), 3.5f * sin(2.0f * phase));
        target = float3(point.x, stairHeight(point) + drone.wander.z
            + 0.8f * sin(phase * 1.7f), point.y);
        // Nose into the direction of travel once it is moving.
        targetYaw = length(v.xz) > 0.6f ? atan2(v.x, -v.z) : drone.velocity.w;
        speedLimit = droneLoiterSpeed;
    } else {
        // Hold a ring around the player at standoff range, a few metres up,
        // and circle it, reversing every few seconds. A player inside the
        // base is besieged from just outside the exit. Ring points over the
        // base move off it, and a drone on the far side climbs over the roof.
        float2 focus = game.player.xz;
        float radius = 13.0f + 2.5f * float(index);
        if (!outdoors(focus, 0.0f)) {
            focus = float2(clamp(focus.x, -2.0f, 2.0f), hullSouth);
            radius += 6.0f;
        }
        float2 from = p.xz - focus;
        float angle = atan2(from.y, from.x);
        float strafe = hashTile(float2(floor(time / 3.2f + 0.37f * float(index)),
            float(index) + 5.0f)) < 0.5f ? -1.0f : 1.0f;
        angle += strafe * 0.5f;
        float2 point = outsideBase(
            focus + radius * float2(cos(angle), sin(angle)), 6.0f);
        target = float3(point.x, max(stairHeight(point),
                game.player.y - 1.55f) + 4.5f + 1.2f * float(index)
                + 0.9f * sin(time * 0.8f + float(index)),
            point.y);
        if (pathCrossesBase(p.xz, point, 3.0f))
            target.y = max(target.y, droneRoofClearance);
        float2 toPlayer = game.player.xz - p.xz;
        targetYaw = atan2(toPlayer.x, -toPlayer.y);
        speedLimit = droneAttackSpeed;
    }

    // Position loop to velocity loop to the acceleration the tilt delivers.
    float3 wanted = (target - p) * 0.9f;
    if (length(wanted) > speedLimit) wanted = normalize(wanted) * speedLimit;
    float3 acceleration = (wanted - v) * 2.2f;
    for (uint other = 0u; other < droneCount; ++other) {
        if (other == index || !droneFlying(game, other)) continue;
        float3 apart = p - game.drones[other].pose.xyz;
        float gap = length(apart);
        if (gap < 5.0f && gap > 0.001f)
            acceleration += apart / gap * (5.0f - gap) * 1.6f;
    }
    // Stay clear of the shell below roof height and keep the skids off the
    // ground.
    float2 wall = clamp(p.xz, float2(-hullHalfWidth, hullNorth),
        float2(hullHalfWidth, hullSouth));
    float2 away = p.xz - wall;
    float wallGap = length(away);
    if (wallGap < 6.0f && p.y < droneRoofClearance - 2.0f)
        acceleration.xz += (wallGap > 0.01f ? away / wallGap
            : float2(0.0f, 1.0f)) * (6.0f - wallGap) * 2.5f;
    float clearance = p.y - droneGround(p.xz);
    if (clearance < 2.5f) acceleration.y += (2.5f - clearance) * 4.0f;

    // Rotors push along the body axis only: tilt toward the wanted
    // horizontal acceleration, and let the airframe follow with a lag.
    float2 tilt = acceleration.xz / droneGravity;
    if (length(tilt) > droneMaxTilt) tilt = normalize(tilt) * droneMaxTilt;
    drone.attitude.xy = mix(drone.attitude.xy, tilt,
        1.0f - exp(-dt / droneTiltLag));
    float3 gust = 0.45f * float3(
        sin(time * 1.3f + float(index) * 4.1f)
            + 0.5f * sin(time * 3.7f + float(index)),
        0.6f * sin(time * 2.3f + float(index) * 1.7f),
        cos(time * 1.1f + float(index) * 2.9f)
            + 0.5f * sin(time * 4.3f + float(index) * 0.7f));
    float3 rotor = float3(drone.attitude.x * droneGravity,
        clamp(acceleration.y, -4.0f, 5.0f), drone.attitude.y * droneGravity);
    float3 actual = rotor + gust - v * 0.25f;
    v += actual * dt;
    p += v * dt;
    // Keep the skids above the regolith even after a hard shove.
    p.y = max(p.y, droneGround(p.xz) + 0.6f);
    drone.pose.xyz = p;
    drone.velocity.xyz = v;
    // Rotor thrust in units of hover thrust sets the rotor speed and its
    // pitch. Gusts and drag act on the airframe, not through the motors.
    float thrust = length(rotor + float3(0.0f, droneGravity, 0.0f))
        / droneGravity;
    drone.attitude.w = mix(drone.attitude.w, thrust, 1.0f - exp(-dt * 6.0f));
    drone.velocity.w += clamp(wrapAngle(targetYaw - drone.velocity.w),
        -2.2f * dt, 2.2f * dt);

    if (hostile) {
        drone.brain.y -= dt;
        if (drone.brain.y <= 0.0f) fireDroneLaser(game, index, audio);
    }
}

// Bolts fly at a finite speed, so a strafing player can step out of the way.
// A bolt that reaches the player's body burns them and stops there.
void advanceLasers(device GameState &game, float dt) {
    float3 feet = game.player.xyz - float3(0.0f, 1.25f, 0.0f);
    float3 head = game.player.xyz + float3(0.0f, 0.1f, 0.0f);
    for (uint i = 0u; i < laserCount; ++i) {
        device LaserBolt &bolt = game.lasers[i];
        float age = game.effects.x - bolt.startTime.w;
        if (age < 0.0f || bolt.endHit.w > 1.5f) continue;
        float3 start = bolt.startTime.xyz;
        float3 path = bolt.endHit.xyz - start;
        float span = length(path);
        if (span < 0.01f) continue;
        float3 direction = path / span;
        float lead = min(age * droneLaserSpeed, span);
        float previous = clamp((age - dt) * droneLaserSpeed - droneBoltLength,
            0.0f, span);
        if (previous >= span) continue;
        float3 a = start + direction * previous;
        float3 b = start + direction * lead;
        if (segmentDistance(a, b, feet, head) < 0.38f
            && game.progress.w == phasePlaying) {
            damagePlayer(game, droneLaserDamage, start.xz, 0.3f);
            // Stop the bolt where it met the body.
            float along = clamp(dot(game.player.xyz - start, direction),
                0.0f, span);
            bolt.endHit = float4(start + direction * along, 2.0f);
        }
    }
}

// The motor whine of each drone as the player hears it: inverse-distance
// loudness, panning, Doppler shift from both motions, and FPV motor pitch.
// Rotor speed follows the square root of thrust, and like an FPV pilot the
// controller punches the throttle to climb and cuts it to drop, so the whine
// rises and gets louder as a drone goes up and sags as it descends. A downed
// drone's motors spin down in under a second. Walls muffle drones the player
// cannot see from inside the base.
void updateDroneVoices(device GameState &game, float dt,
    device RangeAudio &audio, bool playing) {
    DopplerListener listener = {game.player.xyz,
        float3(game.motion.x, game.effects.w, game.motion.y),
        float3(cos(game.player.w), 0.0f, sin(game.player.w))};
    float muffle = outdoors(game.player.xz, 0.0f) ? 1.0f
        : 0.35f * (1.0f - smoothstep(0.0f, 30.0f,
            hullSouth - game.player.z));
    const float detune[droneCount] = {0.97f, 1.0f, 1.04f};
    for (uint i = 0u; i < droneCount; ++i) {
        Drone drone = game.drones[i];
        float climb = drone.pose.w > 0.0f ? drone.velocity.y : 0.0f;
        float rpm = sqrt(max(drone.attitude.w + 0.15f * climb, 0.35f));
        float loudness = 0.85f * clamp(rpm, 0.75f, 1.25f);
        float pitch = detune[i] * clamp(rpm, 0.7f, 1.6f);
        if (drone.pose.w <= 0.0f) {
            float spin = smoothstep(0.0f, 0.9f,
                game.effects.x - drone.brain.w);
            loudness *= 1.0f - spin;
            pitch *= mix(1.0f, 0.45f, spin);
        }
        if (!playing) loudness = 0.0f;
        DopplerSource source = {drone.pose.xyz, drone.velocity.xyz,
            loudness, 6.0f, pitch};
        float4 voice = dopplerVoice(listener, source);
        voice.x *= muffle;
        audio.droneVoice[i] = smoothVoice(audio.droneVoice[i], voice, dt);
    }
}

kernel void advanceDrones(constant ProgramUniforms &u [[buffer(0)]],
    device GameState *states [[buffer(1)]],
    device RangeAudio *audio [[buffer(3)]],
    uint id [[thread_position_in_grid]]) {
    if (id != 0u) return;
    device GameState &game = states[0];
    float dt = clamp(u.pointer.w > 0.0f ? u.pointer.w : u.resolutionTime.w,
        0.0f, 0.10f);
    bool playing = game.progress.w == phasePlaying;
    if (playing) {
        for (uint i = 0u; i < droneCount; ++i) flyDrone(game, i, dt, audio[0]);
        advanceLasers(game, dt);
    }
    updateDroneVoices(game, dt, audio[0], playing);
}

// ---------------------------------------------------------------- shading

SurfaceMaterial droneSurfaceMaterial(uint material, bool wreck) {
    float scorch = wreck ? 0.35f : 1.0f;
    if (material == droneShellMaterial)
        return {float3(0.30f, 0.31f, 0.32f) * scorch, 0.42f, 0.0f, float3(0.0f)};
    if (material == droneCanopyMaterial)
        return {float3(0.025f, 0.03f, 0.035f), 0.16f, 0.0f, float3(0.0f)};
    if (material == droneMotorMaterial)
        return {float3(0.55f, 0.56f, 0.58f) * scorch, 0.32f, 0.9f, float3(0.0f)};
    if (material == droneRifleMaterial)
        return {float3(0.09f, 0.09f, 0.10f), 0.38f, 0.8f, float3(0.0f)};
    if (material == droneEmitterMaterial)
        return {float3(0.25f, 0.02f, 0.02f), 0.1f, 0.0f, float3(0.0f)};
    if (material == droneRedLightMaterial)
        return {float3(0.35f, 0.05f, 0.04f), 0.2f, 0.0f, float3(0.0f)};
    if (material == droneBlueLightMaterial)
        return {float3(0.05f, 0.08f, 0.35f), 0.2f, 0.0f, float3(0.0f)};
    return {float3(0.035f), 0.55f, 0.0f, float3(0.0f)};   // carbon frame
}

// Red is steady with a slow breath; blue flashes twice a second and never
// goes fully dark. Both go out when the drone is shot down.
float droneLightLevel(device const GameState &game, uint index, bool blue) {
    if (!droneFlying(game, index)) return 0.0f;
    float time = game.effects.x + 0.37f * float(index);
    if (!blue) return 0.85f + 0.15f * sin(time * 2.4f);
    float phase = fract(time * 1.1f);
    return (phase < 0.07f || (phase > 0.16f && phase < 0.23f)) ? 1.0f : 0.25f;
}

float droneCharge(device const GameState &game, uint index) {
    Drone drone = game.drones[index];
    if (drone.pose.w <= 0.0f || drone.brain.x < 0.5f) return 0.0f;
    return 1.0f - smoothstep(0.0f, droneChargeTime, drone.brain.y);
}

// Light a drone gives off itself, and its brief glow when hit.
float3 droneEmission(SceneHit hit, device const GameState &game) {
    uint index = hit.variant;
    float3 glow = float3(0.0f);
    if (hit.material == droneRedLightMaterial)
        glow = float3(6.0f, 0.35f, 0.22f) * droneLightLevel(game, index, false);
    if (hit.material == droneBlueLightMaterial)
        glow = float3(0.4f, 1.3f, 7.0f) * droneLightLevel(game, index, true);
    if (hit.material == droneEmitterMaterial)
        glow = float3(5.0f, 0.4f, 0.3f) * droneCharge(game, index);
    float flash = game.drones[index].attitude.z / 0.2f;
    return glow + float3(0.9f, 0.5f, 0.2f) * saturate(flash);
}

// Spinning rotors read as faint, slightly darker discs with bright tips,
// layered over whatever lies behind them.
float3 shadeDroneRotors(float3 color, float3 origin, float3 direction,
    float sceneDistance, device const GameState &game) {
    for (uint i = 0u; i < droneCount; ++i) {
        if (!droneFlying(game, i)) continue;
        Drone drone = game.drones[i];
        if (raySphere(origin, direction, drone.pose.xyz, droneBoundingRadius)
            < 0.0f) continue;
        float3x3 basis = droneBasis(drone);
        float3 up = basis[1];
        float facing = dot(direction, up);
        if (abs(facing) < 1.0e-4f) continue;
        for (uint rotor = 0u; rotor < 4u; ++rotor) {
            float3 centre = drone.pose.xyz + basis * droneRotorCentre(rotor);
            float t = dot(centre - origin, up) / facing;
            if (t <= 0.01f || t >= sceneDistance) continue;
            float radius = length(origin + direction * t - centre);
            if (radius >= droneRotorRadius) continue;
            float blades = 0.14f + 0.06f * smoothstep(0.03f, 0.14f, radius);
            float tips = 1.0f - smoothstep(0.004f, 0.012f,
                abs(radius - droneRotorRadius + 0.012f));
            color = mix(color, float3(0.012f, 0.012f, 0.014f), blades)
                + float3(0.05f) * tips;
        }
    }
    return color;
}

// Navigation lights and the charging emitter bloom beyond their small
// spheres so they stay visible from across the plain.
float3 shadeDroneLights(float3 color, float3 origin, float3 direction,
    float sceneDistance, float pixelAngle, device const GameState &game) {
    for (uint i = 0u; i < droneCount; ++i) {
        if (!droneFlying(game, i)) continue;
        Drone drone = game.drones[i];
        for (uint light = 0u; light < 3u; ++light) {
            float3 local = light == 0u ? droneRedLight
                : (light == 1u ? droneBlueLight : droneEmitter);
            float level = light == 2u ? droneCharge(game, i)
                : droneLightLevel(game, i, light == 1u);
            if (level <= 0.0f) continue;
            float3 position = droneWorldPoint(drone, local);
            float depth = dot(position - origin, direction);
            if (depth <= 0.0f || depth > sceneDistance + 0.06f) continue;
            float angle = length(origin + direction * depth - position) / depth;
            float core = max(0.02f / depth, 1.5f * pixelAngle);
            float glow = exp(-angle * angle / (core * core))
                + 0.12f * exp(-angle / (5.0f * core));
            float3 tint = light == 1u ? float3(0.12f, 0.35f, 1.0f)
                : float3(1.0f, 0.07f, 0.04f);
            color += tint * glow * level * 3.0f;
        }
    }
    return color;
}

// Red laser bolts with white-hot cores, their muzzle flash, and the flash
// where one strikes rock or the shell.
float3 shadeLasers(float3 color, float3 origin, float3 direction,
    float sceneDistance, float pixelAngle, device const GameState &game) {
    for (uint i = 0u; i < laserCount; ++i) {
        LaserBolt bolt = game.lasers[i];
        float age = game.effects.x - bolt.startTime.w;
        if (age < 0.0f || age > 6.0f) continue;
        float3 start = bolt.startTime.xyz;
        float3 path = bolt.endHit.xyz - start;
        float span = length(path);
        if (span < 0.01f) continue;
        float3 unit = path / span;
        float lead = age * droneLaserSpeed;
        float headAt = min(lead, span);
        float tailAt = clamp(lead - droneBoltLength, 0.0f, span);
        if (tailAt < span) {
            float3 tail = start + unit * tailAt;
            float3 segment = unit * (headAt - tailAt);
            float segmentSquared = max(dot(segment, segment), 1.0e-6f);
            float3 fromTail = origin - tail;
            float along = dot(direction, segment);
            float fraction = clamp((dot(segment, fromTail)
                - along * dot(direction, fromTail))
                / max(segmentSquared - along * along, 1.0e-6f), 0.0f, 1.0f);
            float3 closest = tail + segment * fraction;
            float depth = dot(closest - origin, direction);
            if (depth > 0.0f && depth < sceneDistance + 0.02f) {
                float separation = length(origin + direction * depth - closest);
                float width = max(0.018f, 1.2f * pixelAngle * depth);
                float core = 1.0f - smoothstep(0.3f * width, width, separation);
                float halo = exp(-separation / (2.5f * width));
                color += float3(5.0f, 1.2f, 0.9f) * core
                    + float3(1.4f, 0.06f, 0.035f) * halo;
            }
        }
        // Muzzle flash at the drone, impact flash where a bolt ends.
        for (uint k = 0u; k < 2u; ++k) {
            float since = k == 0u ? age : age - span / droneLaserSpeed;
            // A bolt that burned the player ends at the camera; the damage
            // feedback shows that hit instead of a flash in the face.
            if (since < 0.0f || since > 0.15f || (k == 1u
                && (bolt.endHit.w < 0.5f || bolt.endHit.w > 1.5f))) continue;
            float3 point = k == 0u ? start : bolt.endHit.xyz - unit * 0.05f;
            float depth = dot(point - origin, direction);
            if (depth <= 0.0f || depth > sceneDistance + 0.1f) continue;
            float angle = length(origin + direction * depth - point) / depth;
            float size = max(0.12f / depth, 2.0f * pixelAngle);
            color += float3(3.0f, 0.35f, 0.2f) * exp(-angle / size)
                * (1.0f - smoothstep(0.0f, 0.15f, since));
        }
    }
    return color;
}

// Sparks burst from a drone as it is shot down.
float3 shadeDroneSparks(float3 color, float3 origin, float3 direction,
    float sceneDistance, device const GameState &game) {
    for (uint i = 0u; i < droneCount; ++i) {
        Drone drone = game.drones[i];
        if (drone.pose.w > 0.0f || drone.brain.w < 0.0f) continue;
        float age = game.effects.x - drone.brain.w;
        if (age < 0.0f || age > 1.2f) continue;
        float3 burst = drone.wander.xyz;
        float burstDepth = dot(burst - origin, direction);
        if (burstDepth <= 0.0f
            || length(origin + direction * burstDepth - burst) > 6.0f) continue;
        for (uint spark = 0u; spark < 18u; ++spark) {
            float key = float(i * 29u + spark * 13u + 3u);
            float a = hashTile(float2(key, 11.0f));
            float b = hashTile(float2(key, 12.0f));
            float life = 0.6f + 0.6f * hashTile(float2(key, 13.0f));
            if (age >= life) continue;
            float angle = 2.0f * rangePi * a;
            float3 spray = normalize(float3(cos(angle), 2.0f * b - 0.6f,
                sin(angle)));
            float3 centre = burst + spray * (3.0f + 5.0f * b) * age
                - float3(0.0f, 0.5f * droneFallGravity * age * age, 0.0f);
            float depth = dot(centre - origin, direction);
            if (depth <= 0.0f || depth >= sceneDistance) continue;
            float separation = length(origin + direction * depth - centre);
            float radius = 0.025f + 0.0015f * depth;
            if (separation >= radius * 3.0f) continue;
            float fade = 1.0f - smoothstep(0.2f, life, age);
            color += mix(float3(3.0f, 2.2f, 1.2f), float3(2.4f, 0.6f, 0.1f), b)
                * ((1.0f - smoothstep(0.35f * radius, radius, separation))
                    + 0.2f * (1.0f - smoothstep(radius, 3.0f * radius,
                        separation))) * fade;
        }
    }
    return color;
}

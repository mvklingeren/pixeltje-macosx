// The haunted scene's adapter for the reusable bounded physics world. Static
// colliders are the surviving HouseParts; the world owns 12 building chunks
// and 24 masonry stones. Only this dedicated tick pass walks the colliders.

bool physicsReservedPart(device const HouseModel &house, uint index) {
    for (uint tomb = 0u; tomb < 2u; ++tomb) {
        uint first = house.debrisParts[tomb * (masonryDebrisCount / 2u)];
        uint last = house.debrisParts[(tomb + 1u)
            * (masonryDebrisCount / 2u) - 1u];
        if (index >= first && index <= last) return true;
    }
    return false;
}

void traceStreetTombDebris(thread SceneHit &hit, float3 origin,
    float3 direction, device const GameState &game) {
    for (uint i = 0u; i < masonryDebrisCount; ++i) {
        pixeltje_physics::RigidBody body
            = game.physicsWorld.bodies[buildingFragmentCount + i];
        if (body.extentState.w == 0.0f) continue;
        device const HousePart &part
            = game.house.parts[game.house.debrisParts[i]];
        float3 originalCentre = 0.5f * (part.lower.xyz + part.upper.xyz);
        float3 localOrigin = originalCentre
            + pixeltje_physics::unrotate(body.orientation,
                origin - body.centreMass.xyz);
        float3 localDirection
            = pixeltje_physics::unrotate(body.orientation, direction);
        float3 normal;
        float t = houseHitPart(part, localOrigin, localDirection,
            hit.distance, normal);
        if (t > 0.0f) hit = {t,
            pixeltje_physics::rotate(body.orientation, normal),
            origin + direction * t, houseMaterialBase + houseGrave,
            -1, houseCapacity + buildingFragmentCount + i};
    }
}

float4 physicsGroupRotation(HouseTurn turn) {
    float halfAngle = 0.5f * atan2(turn.sine, turn.cosine);
    return float4(0.0f, -sin(halfAngle), 0.0f, cos(halfAngle));
}

// The rendered masonry panel is a grid of removable stones. Its broad-phase
// box is a collider only where a surviving stone occupies the contact point.
bool physicsMasonryAt(device const GameState &game,
    device const HousePart &part, float3 local) {
    uint row = min(uint(max(floor((local.y - part.lower.y)
        / part.windows.y), 0.0f)), masonryMaxRows - 1u);
    float axis = part.windows.w < 0.5f ? local.x : local.z;
    float start = part.windows.w < 0.5f ? part.lower.x : part.lower.z;
    uint col = min(uint(max(floor((axis - start) / part.windows.x
        + 0.5f * float(row & 1u)), 0.0f)), 31u);
    return !masonryStoneGone(game, uint(part.windows.z), row, col);
}

bool physicsSolidPart(uint style) {
    return buildingBreakable(style) || style == houseMasonry;
}

__attribute__((noinline))
bool physicsResolveBuildings(device const GameState &game,
    thread pixeltje_physics::RigidBody &body, uint worldIndex) {
    bool touched = false;
    float reach = length(body.extentState.xyz) + 0.1f;
    for (uint g = 0u; g < min(game.house.counts.y, houseGroupCapacity);
            ++g) {
        HouseGroup group = game.house.groups[g];
        HouseTurn turn = houseGroupTurn(group);
        float3 localCentre = houseTurnPointIn(turn, body.centreMass.xyz);
        if (distance(localCentre, clamp(localCentre, group.lower.xyz,
                group.upper.xyz)) > reach) {
            g = max(g, group.last.x);
            continue;
        }
        for (uint index = uint(group.lower.w);
                index < min(uint(group.upper.w), houseCapacity); ++index) {
            if (physicsReservedPart(game.house, index)
                || (worldIndex < buildingFragmentCount
                    && game.buildingFragmentSource[worldIndex] == index)
                || game.buildingGone[index] == ~0ul) continue;
            device const HousePart &part = game.house.parts[index];
            uint style = uint(part.lower.w);
            if (!physicsSolidPart(style)
                || any(part.upper.xyz <= part.lower.xyz)) continue;
            if (distance(localCentre, clamp(localCentre, part.lower.xyz,
                    part.upper.xyz)) > reach) continue;
            float3 centre = houseTurnPointOut(turn,
                0.5f * (part.lower.xyz + part.upper.xyz));
            pixeltje_physics::RigidBody staticBody
                = pixeltje_physics::makeRigidBody(centre,
                    0.5f * (part.upper.xyz - part.lower.xyz),
                    physicsGroupRotation(turn), float3(0.0f),
                    0.0f, 0.12f, 0.85f);
            pixeltje_physics::RigidContact contact
                = pixeltje_physics::boxBox(body, staticBody);
            if (contact.depth <= 0.0f) continue;
            float3 localPoint = houseTurnPointIn(turn, contact.point);
            bool outsideCut = false;
            for (uint plane = 0u; plane < uint(part.upper.w); ++plane)
                outsideCut |= dot(part.planes[plane].xyz, localPoint)
                    > part.planes[plane].w + 0.03f;
            if (outsideCut) continue;
            if (style == houseMasonry) {
                if (!physicsMasonryAt(game, part, localPoint)) continue;
            } else if (buildingCellGone(game, index, part, localPoint)) {
                continue;
            }
            pixeltje_physics::solve(body, staticBody, contact);
            touched = true;
        }
    }
    return touched;
}

float physicsGroundY(device const GameState &game, uint worldIndex,
    float2 point) {
    if (worldIndex >= buildingFragmentCount) {
        uint slot = worldIndex - buildingFragmentCount;
        uint tomb = slot / (masonryDebrisCount / 2u);
        return streetTombStand(point,
            streetProperties[streetTombFirst + tomb].at.y);
    }
    return buildingsGround(point, moonHeight(point, moonTraceDetail));
}

__attribute__((noinline))
bool physicsResolveStatic(device const GameState &game,
    thread pixeltje_physics::RigidBody &body, uint worldIndex) {
    float floorY = physicsGroundY(game, worldIndex, body.centreMass.xz);
    pixeltje_physics::RigidContact floor = pixeltje_physics::boxPlane(
        body, float3(0.0f, floorY, 0.0f), float3(0.0f, 1.0f, 0.0f));
    bool touched = floor.depth > 0.0f;
    if (touched) {
        pixeltje_physics::RigidBody ground
            = pixeltje_physics::makeRigidBody(float3(0.0f), float3(1.0f),
                float4(0.0f, 0.0f, 0.0f, 1.0f), float3(0.0f),
                0.0f, 0.1f, 0.9f);
        pixeltje_physics::solve(body, ground, floor);
    }
    return physicsResolveBuildings(game, body, worldIndex) || touched;
}

// One deterministic solver updates all active debris together. The two pools
// share one array so a roof section can strike masonry rubble and vice versa.
__attribute__((noinline))
void advancePhysicsWorld(device GameState &game, float dt) {
    dt = clamp(dt, 0.0f, 0.05f);
    if (dt <= 0.0f) return;
    uint steps = min(uint(ceil(dt * 60.0f)), 3u);
    float step = dt / float(steps);
    for (uint sub = 0u; sub < steps; ++sub) {
        thread bool touched[physicsBodyCount];
        for (uint i = 0u; i < physicsBodyCount; ++i) {
            touched[i] = false;
            pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
            pixeltje_physics::integrateRigid(body,
                float3(0.0f, -9.8f, 0.0f), 0.12f, 0.25f, step);
            game.physicsWorld.bodies[i] = body;
        }
        // Two iterations make stacked contacts less order-dependent without
        // putting the building search in a player or rendering kernel.
        for (uint iteration = 0u; iteration < 2u; ++iteration) {
            for (uint i = 0u; i < physicsBodyCount; ++i) {
                pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
                if (body.extentState.w != 1.0f) continue;
                touched[i] |= physicsResolveStatic(game, body, i);
                game.physicsWorld.bodies[i] = body;
            }
            for (uint i = 0u; i < physicsBodyCount; ++i) {
                pixeltje_physics::RigidBody a = game.physicsWorld.bodies[i];
                if (a.extentState.w == 0.0f) continue;
                for (uint j = i + 1u; j < physicsBodyCount; ++j) {
                    pixeltje_physics::RigidBody b
                        = game.physicsWorld.bodies[j];
                    if (b.extentState.w == 0.0f
                        || (a.extentState.w == 2.0f
                            && b.extentState.w == 2.0f)) continue;
                    float broad = length(a.extentState.xyz)
                        + length(b.extentState.xyz);
                    if (distance(a.centreMass.xyz, b.centreMass.xyz)
                        > broad) continue;
                    pixeltje_physics::RigidContact contact
                        = pixeltje_physics::boxBox(a, b);
                    if (contact.depth <= 0.0f) continue;
                    pixeltje_physics::solve(a, b, contact);
                    game.physicsWorld.bodies[j] = b;
                    touched[i] = true;
                    touched[j] = true;
                }
                game.physicsWorld.bodies[i] = a;
            }
        }
        for (uint i = 0u; i < physicsBodyCount; ++i) {
            pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
            if (body.extentState.w != 1.0f) continue;
            bool quiet = touched[i]
                && length(body.linearBounce.xyz) < 0.18f
                && length(body.angularFriction.xyz) < 0.22f;
            game.physicsWorld.sleepSeconds[i] = quiet
                ? game.physicsWorld.sleepSeconds[i] + step : 0.0f;
            if (game.physicsWorld.sleepSeconds[i] > 0.35f) {
                body.linearBounce.xyz = float3(0.0f);
                body.angularFriction.xyz = float3(0.0f);
                body.extentState.w = 2.0f;
                game.physicsWorld.bodies[i] = body;
            }
        }
    }
}

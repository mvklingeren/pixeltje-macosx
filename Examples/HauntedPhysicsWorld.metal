// The haunted scene's adapter for the reusable bounded physics world. Static
// colliders are the surviving HouseParts; the world owns 32 building chunks
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
            origin + direction * t,
            houseMaterialBase + uint(part.lower.w),
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

// Static building parts and the ground join the contacts of one substep
// as staticBody. The solver runs after every contact is known, so a stack
// of rubble shares its load instead of resolving one pair at a time.
pixeltje_physics::RigidBody physicsSolverBody(device const GameState &game,
    uint index) {
    if (index == pixeltje_physics::staticBody)
        return pixeltje_physics::staticRigidBody();
    pixeltje_physics::RigidBody body = game.physicsWorld.bodies[index];
    // A sleeping body is solid but immovable until something wakes it.
    if (body.extentState.w != 1.0f) body.centreMass.w = 0.0f;
    return body;
}

void physicsAddContacts(device GameState &game, uint a, uint b,
    pixeltje_physics::RigidBody bodyA, pixeltje_physics::RigidBody bodyB,
    float3 normal, thread const float4 *points, uint count, float dt) {
    for (uint k = 0u; k < count; ++k) {
        uint n = game.physicsContactCount;
        if (n >= physicsContactCapacity) return;
        game.physicsContacts[n] = pixeltje_physics::prepareContact(bodyA,
            bodyB, a, b, normal, points[k], dt);
        game.physicsContactCount = n + 1u;
    }
}

constant float physicsSlop = 0.02f;
// A chunk starts out overlapping whatever its part was built into, such as
// trim or a roof's box; such deep overlaps are not collisions.
constant float physicsBuiltInDepth = 0.15f;

bool physicsChunkSlot(uint worldIndex) {
    return worldIndex >= buildingShardSlots
        && worldIndex < buildingFragmentCount;
}

__attribute__((noinline))
void physicsCollectBuildings(device GameState &game,
    pixeltje_physics::RigidBody body, uint worldIndex, float dt) {
    float reach = length(body.extentState.xyz) + 0.1f;
    bool chunk = physicsChunkSlot(worldIndex);
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
            pixeltje_physics::RigidManifold manifold
                = pixeltje_physics::boxBoxManifold(body, staticBody,
                    physicsSlop);
            // Keep the points that touch what is really there: inside the
            // part's cut planes, on a stone or cell that is not gone.
            float4 kept[4];
            uint count = 0u;
            for (uint k = 0u; k < manifold.count; ++k) {
                float4 point = manifold.points[k];
                if (chunk && point.w > physicsBuiltInDepth) continue;
                float3 localPoint = houseTurnPointIn(turn, point.xyz
                    - manifold.normal * max(point.w, 0.0f) * 0.5f);
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
                kept[count++] = point;
            }
            physicsAddContacts(game, worldIndex, pixeltje_physics::staticBody,
                body, staticBody, manifold.normal, kept, count, dt);
        }
    }
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
void physicsCollectStatic(device GameState &game, device RangeAudio &audio,
    pixeltje_physics::RigidBody body, uint worldIndex, float dt) {
    float floorY = physicsGroundY(game, worldIndex, body.centreMass.xz);
    pixeltje_physics::RigidManifold floor
        = pixeltje_physics::boxPlaneManifold(body, float3(0.0f, floorY, 0.0f),
            float3(0.0f, 1.0f, 0.0f), physicsSlop);
    if (floor.count > 0u) {
        uint bit = 1u << (worldIndex < 32u ? worldIndex : worldIndex - 32u);
        bool landed = worldIndex < 32u
            ? (game.debrisLandingMask.x & bit) != 0u
            : (game.debrisLandingMask.y & bit) != 0u;
        if (!landed && body.linearBounce.y < -1.2f) {
            // The first meaningful floor strike consumes this body's event,
            // even if another fragment already used the shared sound slot.
            if (worldIndex < 32u) game.debrisLandingMask.x |= bit;
            else game.debrisLandingMask.y |= bit;
            if (game.effects.x >= game.landingSoundReadyAt
                && audio.landingImpact == 0u) {
                audio.landingImpact = 1u;
                game.landingSoundReadyAt = game.effects.x + 1.0f;
            }
        }
        pixeltje_physics::RigidBody ground
            = pixeltje_physics::makeRigidBody(float3(0.0f), float3(1.0f),
                float4(0.0f, 0.0f, 0.0f, 1.0f), float3(0.0f),
                0.0f, 0.1f, 0.9f);
        float4 points[4] = {floor.points[0], floor.points[1],
            floor.points[2], floor.points[3]};
        physicsAddContacts(game, worldIndex, pixeltje_physics::staticBody,
            body, ground, floor.normal, points, floor.count, dt);
    }
    physicsCollectBuildings(game, body, worldIndex, dt);
}

// Every moving body against the ground and the buildings, and every pair
// with at least one moving body. A quiet neighbour rests as a solid
// collider; only a substantial strike wakes an already settled piece.
__attribute__((noinline))
void physicsCollectContacts(device GameState &game, device RangeAudio &audio,
    float dt) {
    game.physicsContactCount = 0u;
    for (uint i = 0u; i < physicsBodyCount; ++i) {
        pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
        if (body.extentState.w == 1.0f)
            physicsCollectStatic(game, audio, body, i, dt);
    }
    for (uint i = 0u; i < physicsBodyCount; ++i) {
        pixeltje_physics::RigidBody a = game.physicsWorld.bodies[i];
        if (a.extentState.w == 0.0f) continue;
        for (uint j = i + 1u; j < physicsBodyCount; ++j) {
            pixeltje_physics::RigidBody b = game.physicsWorld.bodies[j];
            if (b.extentState.w == 0.0f
                || (a.extentState.w != 1.0f && b.extentState.w != 1.0f))
                continue;
            float broad = length(a.extentState.xyz)
                + length(b.extentState.xyz) + physicsSlop;
            if (distance(a.centreMass.xyz, b.centreMass.xyz) > broad)
                continue;
            pixeltje_physics::RigidManifold manifold
                = pixeltje_physics::boxBoxManifold(a, b, physicsSlop);
            if (manifold.count == 0u) continue;
            bool builtIn = physicsChunkSlot(i) && physicsChunkSlot(j);
            float4 points[4];
            uint count = 0u;
            for (uint k = 0u; k < manifold.count; ++k)
                if (!builtIn || manifold.points[k].w <= physicsBuiltInDepth)
                    points[count++] = manifold.points[k];
            if (count == 0u) continue;
            float impact = max(-dot(a.linearBounce.xyz - b.linearBounce.xyz,
                manifold.normal), 0.0f);
            if (impact >= 1.25f) {
                if (a.extentState.w == 2.0f) {
                    a.extentState.w = 1.0f;
                    game.physicsWorld.bodies[i].extentState.w = 1.0f;
                    game.physicsWorld.sleepSeconds[i] = 0.0f;
                }
                if (b.extentState.w == 2.0f) {
                    game.physicsWorld.bodies[j].extentState.w = 1.0f;
                    game.physicsWorld.sleepSeconds[j] = 0.0f;
                }
            }
            physicsAddContacts(game, i, j, physicsSolverBody(game, i),
                physicsSolverBody(game, j), manifold.normal, points, count,
                dt);
        }
    }
}

__attribute__((noinline))
void physicsSolveContacts(device GameState &game) {
    uint count = min(game.physicsContactCount, physicsContactCapacity);
    for (uint iteration = 0u; iteration < 8u; ++iteration) {
        for (uint c = 0u; c < count; ++c) {
            pixeltje_physics::SolverContact contact = game.physicsContacts[c];
            uint2 pair = contact.bodies;
            pixeltje_physics::RigidBody a = physicsSolverBody(game, pair.x);
            pixeltje_physics::RigidBody b = physicsSolverBody(game, pair.y);
            pixeltje_physics::solveContact(a, b, contact);
            game.physicsContacts[c] = contact;
            if (a.centreMass.w > 0.0f) {
                game.physicsWorld.bodies[pair.x].linearBounce
                    = a.linearBounce;
                game.physicsWorld.bodies[pair.x].angularFriction
                    = a.angularFriction;
            }
            if (pair.y != pixeltje_physics::staticBody
                && b.centreMass.w > 0.0f) {
                game.physicsWorld.bodies[pair.y].linearBounce
                    = b.linearBounce;
                game.physicsWorld.bodies[pair.y].angularFriction
                    = b.angularFriction;
            }
        }
    }
}

// One deterministic solver updates all active debris together. The two pools
// share one array so a roof section can strike masonry rubble and vice versa.
__attribute__((noinline))
void advancePhysicsWorld(device GameState &game, device RangeAudio &audio,
    float dt) {
    dt = clamp(dt, 0.0f, 0.05f);
    if (dt <= 0.0f) return;
    uint steps = min(uint(ceil(dt * 60.0f)), 3u);
    float step = dt / float(steps);
    for (uint sub = 0u; sub < steps; ++sub) {
        for (uint i = 0u; i < physicsBodyCount; ++i) {
            pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
            pixeltje_physics::integrateVelocity(body,
                float3(0.0f, -22.0f, 0.0f), 0.06f, 0.18f, step);
            game.physicsWorld.bodies[i] = body;
        }
        physicsCollectContacts(game, audio, step);
        physicsSolveContacts(game);
        for (uint i = 0u; i < physicsBodyCount; ++i) {
            pixeltje_physics::RigidBody body = game.physicsWorld.bodies[i];
            if (body.extentState.w != 1.0f) continue;
            float spin = length(body.angularFriction.xyz);
            if (spin > 12.0f) body.angularFriction.xyz *= 12.0f / spin;
            pixeltje_physics::integratePosition(body, step);
            // Resting friction now holds a pile still, so a body sleeps
            // once it has been slow for half a second.
            bool quiet = length(body.linearBounce.xyz) < 0.3f
                && length(body.angularFriction.xyz) < 0.6f;
            game.physicsWorld.sleepSeconds[i] = quiet
                ? game.physicsWorld.sleepSeconds[i] + step : 0.0f;
            if (game.physicsWorld.sleepSeconds[i] > 0.5f) {
                body.linearBounce.xyz = float3(0.0f);
                body.angularFriction.xyz = float3(0.0f);
                body.extentState.w = 2.0f;
            }
            game.physicsWorld.bodies[i] = body;
        }
    }
}

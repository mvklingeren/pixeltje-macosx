// NPC path network for GPU Programs: a waypoint graph generated from a room
// layout, a shared route field toward one goal, and followers that patrol or
// hunt along it. Include it before the program's game state, which embeds one
// NPCPathNetwork and one float4 follower per NPC. It needs only metal_stdlib.
//
// Positions are on the ground plane, stored as float2(world X, world Z).
// The including program defines the two world queries the network needs:
//
//     bool npcPathPointClear(float2 point);   // true where an NPC may stand
//     bool npcPathNodeAllowed(float2 point, uint area);
//
// The second keeps one area's nodes out of places that belong to another,
// such as an outdoor area whose rectangle encloses a building.
//
// Generation lays a jittered grid of nodes over each area, drops nodes where
// an NPC cannot stand, links grid neighbours whose straight walk is clear,
// and links joined areas through their nearest clear node pair. A different
// seed generates a different network over the same layout.

constant uint npcPathCapacity = 104u;
constant uint npcPathLinkCapacity = 8u;
constant uint npcPathNone = 255u;
constant float npcPathUnreached = 1.0e30f;
constant float npcPathSampleSpacing = 0.5f;   // metres between clearance probes

// A rectangle that receives a cells.x × cells.y grid of nodes from lower to
// upper inclusive. An axis with one cell places its nodes on the centre line,
// so a 1 × 1 area is a fixed portal node, for example inside a doorway.
// Each node moves randomly by up to jitter × the grid spacing per axis.
struct NPCPathArea {
    float2 lower;
    float2 upper;
    uint2 cells;
    float jitter;
};

struct NPCPathNode {
    float2 position;
    float cost;            // route length to the goal node
    uchar area;            // npcPathNone where no NPC can stand
    uchar linkCount;
    uchar settled;         // route-field scratch flag
    uchar reserved;
    uchar links[npcPathLinkCapacity];
};

struct NPCPathNetwork {
    NPCPathNode nodes[npcPathCapacity];
    uint4 info;            // node slots, goal node, seed, reserved
};

bool npcPathPointClear(float2 point);
bool npcPathNodeAllowed(float2 point, uint area);

uint npcPathHash(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

// A uniform value in [0, 1) for one stream and draw.
float npcPathRandom(uint stream, uint draw) {
    return float(npcPathHash(stream * 0x9e3779b9u ^ npcPathHash(draw)) >> 8)
        * (1.0f / 16777216.0f);
}

bool npcPathUsable(device const NPCPathNetwork &net, uint node) {
    return node < net.info.x && net.nodes[node].area != npcPathNone;
}

// True when the straight walk from a to b stays clear. The start point is
// not probed, so an NPC pressed against a wall can still walk away from it.
bool npcPathSegmentClear(float2 a, float2 b) {
    uint steps = clamp(uint(ceil(distance(a, b) / npcPathSampleSpacing)),
        1u, 256u);
    for (uint s = 1u; s <= steps; ++s)
        if (!npcPathPointClear(mix(a, b, float(s) / float(steps))))
            return false;
    return true;
}

void npcPathLink(device NPCPathNetwork &net, uint a, uint b) {
    if (a == b || !npcPathUsable(net, a) || !npcPathUsable(net, b)) return;
    device NPCPathNode &first = net.nodes[a];
    device NPCPathNode &second = net.nodes[b];
    if (first.linkCount >= npcPathLinkCapacity
        || second.linkCount >= npcPathLinkCapacity) return;
    for (uint i = 0u; i < first.linkCount; ++i)
        if (first.links[i] == b) return;
    if (!npcPathSegmentClear(first.position, second.position)) return;
    first.links[first.linkCount] = uchar(b);
    first.linkCount += 1u;
    second.links[second.linkCount] = uchar(a);
    second.linkCount += 1u;
}

uint npcPathAreaSlots(NPCPathArea area) {
    uint2 cells = max(area.cells, uint2(1u));
    return cells.x * cells.y;
}

// Builds the network. joins lists pairs of area indices connected by a
// doorway or opening; each node of the smaller area links to its nearest
// node in the larger one that it can walk to in a straight line.
void npcPathGenerate(device NPCPathNetwork &net,
    constant NPCPathArea *areas, uint areaCount,
    constant uint2 *joins, uint joinCount, uint seed) {
    uint count = 0u;
    for (uint a = 0u; a < areaCount; ++a) {
        NPCPathArea area = areas[a];
        uint2 cells = max(area.cells, uint2(1u));
        float2 span = area.upper - area.lower;
        float2 spacing = float2(
            cells.x > 1u ? span.x / float(cells.x - 1u) : 0.0f,
            cells.y > 1u ? span.y / float(cells.y - 1u) : 0.0f);
        uint first = count;
        for (uint row = 0u; row < cells.y; ++row) {
            for (uint column = 0u; column < cells.x; ++column) {
                if (count >= npcPathCapacity) break;
                float2 grid = float2(
                    cells.x > 1u ? area.lower.x + spacing.x * float(column)
                        : 0.5f * (area.lower.x + area.upper.x),
                    cells.y > 1u ? area.lower.y + spacing.y * float(row)
                        : 0.5f * (area.lower.y + area.upper.y));
                // Jitter, halving the reach each time the node lands where an
                // NPC cannot stand. The last attempt uses the plain grid point.
                float2 position = grid;
                bool clear = false;
                float reach = 2.0f * area.jitter;
                for (uint attempt = 0u; attempt < 4u && !clear; ++attempt) {
                    float2 jitter = attempt == 3u ? float2(0.0f) : float2(
                        npcPathRandom(seed, count * 8u + attempt * 2u),
                        npcPathRandom(seed, count * 8u + attempt * 2u + 1u))
                        - 0.5f;
                    position = clamp(grid + jitter * reach * spacing,
                        area.lower, area.upper);
                    clear = npcPathPointClear(position)
                        && npcPathNodeAllowed(position, a);
                    reach *= 0.5f;
                }
                device NPCPathNode &node = net.nodes[count];
                node.position = position;
                node.cost = npcPathUnreached;
                node.area = clear ? uchar(a) : uchar(npcPathNone);
                node.linkCount = 0u;
                node.settled = 0u;
                node.reserved = 0u;
                count += 1u;
            }
        }
        net.info.x = count;
        // Grid neighbours, including both diagonals.
        for (uint row = 0u; row < cells.y; ++row) {
            for (uint column = 0u; column < cells.x; ++column) {
                uint node = first + row * cells.x + column;
                if (column + 1u < cells.x) npcPathLink(net, node, node + 1u);
                if (row + 1u >= cells.y) continue;
                uint below = node + cells.x;
                npcPathLink(net, node, below);
                if (column + 1u < cells.x) npcPathLink(net, node, below + 1u);
                if (column > 0u) npcPathLink(net, node, below - 1u);
            }
        }
    }
    for (uint j = 0u; j < joinCount; ++j) {
        uint2 pair = joins[j];
        if (pair.x >= areaCount || pair.y >= areaCount) continue;
        if (npcPathAreaSlots(areas[pair.x]) > npcPathAreaSlots(areas[pair.y]))
            pair = pair.yx;
        uint fromStart = 0u, toStart = 0u;
        for (uint a = 0u; a < pair.x; ++a)
            fromStart += npcPathAreaSlots(areas[a]);
        for (uint a = 0u; a < pair.y; ++a)
            toStart += npcPathAreaSlots(areas[a]);
        uint fromEnd = min(fromStart + npcPathAreaSlots(areas[pair.x]), count);
        uint toEnd = min(toStart + npcPathAreaSlots(areas[pair.y]), count);
        for (uint from = fromStart; from < fromEnd; ++from) {
            if (!npcPathUsable(net, from)) continue;
            // Nearest first: try candidates in order of distance.
            float tried = -1.0f;
            for (uint attempt = 0u; attempt < 4u; ++attempt) {
                uint best = npcPathNone;
                float bestDistance = npcPathUnreached;
                for (uint to = toStart; to < toEnd; ++to) {
                    if (!npcPathUsable(net, to)) continue;
                    float d = distance(net.nodes[from].position,
                        net.nodes[to].position);
                    if (d > tried && d < bestDistance) {
                        bestDistance = d;
                        best = to;
                    }
                }
                if (best == npcPathNone) break;
                uint before = net.nodes[from].linkCount;
                npcPathLink(net, from, best);
                if (net.nodes[from].linkCount > before) break;
                tried = bestDistance;
            }
        }
    }
    // A node boxed in by obstacles would strand an NPC that walks to it.
    for (uint i = 0u; i < count; ++i)
        if (net.nodes[i].linkCount == 0u) net.nodes[i].area = npcPathNone;
    net.info = uint4(count, npcPathNone, seed, 0u);
}

// The nearest node an NPC at point can walk to in a straight line. When no
// node within reach is in a clear line, the nearest node at all.
uint npcPathNearest(device const NPCPathNetwork &net, float2 point) {
    const float reachSquared = 30.0f * 30.0f;
    uint best = npcPathNone, fallback = npcPathNone;
    float bestDistance = reachSquared, fallbackDistance = npcPathUnreached;
    for (uint i = 0u; i < net.info.x; ++i) {
        if (!npcPathUsable(net, i)) continue;
        float2 offset = net.nodes[i].position - point;
        float d = dot(offset, offset);
        if (d < fallbackDistance) {
            fallbackDistance = d;
            fallback = i;
        }
        if (d < bestDistance
            && npcPathSegmentClear(point, net.nodes[i].position)) {
            bestDistance = d;
            best = i;
        }
    }
    return best != npcPathNone ? best : fallback;
}

// Routes every node toward goal. Each node's cost becomes its path length to
// the node nearest the goal. The field is rebuilt only when that node changes.
void npcPathRouteTo(device NPCPathNetwork &net, float2 goal) {
    uint target = npcPathNearest(net, goal);
    if (target == net.info.y) return;
    net.info.y = target;
    uint count = net.info.x;
    for (uint i = 0u; i < count; ++i) {
        net.nodes[i].cost = npcPathUnreached;
        net.nodes[i].settled = 0u;
    }
    if (target == npcPathNone) return;
    net.nodes[target].cost = 0.0f;
    // Dijkstra with a linear scan; the graph is small and the scan is cheap.
    for (uint pass = 0u; pass < count; ++pass) {
        uint current = npcPathNone;
        float lowest = npcPathUnreached;
        for (uint i = 0u; i < count; ++i) {
            if (net.nodes[i].settled == 0u && net.nodes[i].cost < lowest) {
                lowest = net.nodes[i].cost;
                current = i;
            }
        }
        if (current == npcPathNone) break;
        net.nodes[current].settled = 1u;
        float2 from = net.nodes[current].position;
        for (uint l = 0u; l < net.nodes[current].linkCount; ++l) {
            uint next = net.nodes[current].links[l];
            float cost = lowest + distance(from, net.nodes[next].position);
            if (cost < net.nodes[next].cost) net.nodes[next].cost = cost;
        }
    }
}

// The neighbour that continues the route from node, or npcPathNone at the
// goal node and on nodes the route does not reach.
uint npcPathNextHop(device const NPCPathNetwork &net, uint node) {
    float cost = net.nodes[node].cost;
    if (cost <= 0.0f || cost >= npcPathUnreached) return npcPathNone;
    uint best = npcPathNone;
    float lowest = cost + 0.001f;
    for (uint l = 0u; l < net.nodes[node].linkCount; ++l) {
        uint next = net.nodes[node].links[l];
        float through = net.nodes[next].cost
            + distance(net.nodes[node].position, net.nodes[next].position);
        if (through < lowest) {
            lowest = through;
            best = next;
        }
    }
    return best;
}

// A follower is one float4 per NPC: target node, previous node, rest time
// left and stuck time. Node indices are stored as floats, -1 for none.
float4 npcPathFollower(float rest) {
    return float4(-1.0f, -1.0f, rest, 0.0f);
}

uint npcPathFollowerNode(float value) {
    return value < 0.0f ? npcPathNone : uint(value + 0.5f);
}

float npcPathFollowerValue(uint node) {
    return node == npcPathNone ? -1.0f : float(node);
}

// Forget the route, for example while the NPC chases its goal directly;
// the next call to npcPathHunt picks up the nearest node again.
void npcPathRelease(thread float4 &follower) {
    follower.xy = float2(-1.0f);
    follower.w = 0.0f;
}

// The point to walk toward on the route to the goal of npcPathRouteTo. The
// follower skips ahead while the following node is already in a straight
// line, so it cuts corners instead of touching every node. Once at the goal
// node, or where the route does not reach, it returns the goal itself.
float2 npcPathHunt(device const NPCPathNetwork &net, thread float4 &follower,
    float2 position, float2 goal, float arriveRadius) {
    follower.z = 0.0f;
    uint target = npcPathFollowerNode(follower.x);
    if (!npcPathUsable(net, target)) {
        target = npcPathNearest(net, position);
        if (target == npcPathNone) return goal;
        follower.x = npcPathFollowerValue(target);
        follower.y = -1.0f;
    }
    for (uint hop = 0u; hop < 3u; ++hop) {
        NPCPathNode node = net.nodes[target];
        if (node.cost >= npcPathUnreached) return goal;
        bool reached = distance(position, node.position) < arriveRadius;
        uint next = npcPathNextHop(net, target);
        if (next == npcPathNone)
            return reached || npcPathSegmentClear(position, goal)
                ? goal : node.position;
        if (!reached
            && !npcPathSegmentClear(position, net.nodes[next].position))
            break;
        follower.y = npcPathFollowerValue(target);
        follower.x = npcPathFollowerValue(next);
        target = next;
    }
    return net.nodes[target].position;
}

// The point to walk toward on a patrol: a random walk over linked nodes in
// the areas set in areaMask that avoids turning straight back. At some nodes
// the follower rests; resting reports true and the NPC should stand still.
// entropy varies the choices, for example a hash of the elapsed time.
float2 npcPathPatrol(device const NPCPathNetwork &net, thread float4 &follower,
    float2 position, uint areaMask, uint stream, uint entropy, float dt,
    float arriveRadius, float restChance, thread bool &resting) {
    resting = follower.z > 0.0f;
    if (resting) {
        follower.z = max(follower.z - dt, 0.0f);
        uint target = npcPathFollowerNode(follower.x);
        return npcPathUsable(net, target) ? net.nodes[target].position
            : position;
    }
    uint target = npcPathFollowerNode(follower.x);
    if (!npcPathUsable(net, target)
        || ((areaMask >> net.nodes[target].area) & 1u) == 0u) {
        target = npcPathNearest(net, position);
        if (target == npcPathNone) return position;
        follower.x = npcPathFollowerValue(target);
        follower.y = -1.0f;
    }
    NPCPathNode node = net.nodes[target];
    if (distance(position, node.position) >= arriveRadius)
        return node.position;
    uint previous = npcPathFollowerNode(follower.y);
    uint choices = 0u;
    for (uint l = 0u; l < node.linkCount; ++l) {
        uint next = node.links[l];
        if (next != previous && ((areaMask >> net.nodes[next].area) & 1u) != 0u)
            choices += 1u;
    }
    uint pick = npcPathNone;
    uint draw = npcPathHash(entropy ^ (target * 0x27d4eb2du));
    if (choices > 0u) {
        uint chosen = uint(npcPathRandom(stream, draw) * float(choices));
        for (uint l = 0u; l < node.linkCount; ++l) {
            uint next = node.links[l];
            if (next == previous
                || ((areaMask >> net.nodes[next].area) & 1u) == 0u) continue;
            if (chosen == 0u) {
                pick = next;
                break;
            }
            chosen -= 1u;
        }
    } else if (npcPathUsable(net, previous)) {
        pick = previous;   // a dead end: turn back
    }
    if (pick == npcPathNone) return position;
    follower.y = npcPathFollowerValue(target);
    follower.x = npcPathFollowerValue(pick);
    if (npcPathRandom(stream, draw + 1u) < restChance) {
        follower.z = mix(0.35f, 1.3f, npcPathRandom(stream, draw + 2u));
        resting = true;
    }
    return net.nodes[pick].position;
}

// Call after moving. An NPC that covers less than a quarter of the distance
// it tried to walk for most of a second turns back to its previous node, so a
// spider wedged against another spider or a corner finds another way round.
void npcPathProgress(thread float4 &follower, float moved, float wanted,
    float dt) {
    if (wanted <= 0.0001f) return;
    follower.w = moved < 0.25f * wanted ? follower.w + dt
        : max(follower.w - 2.0f * dt, 0.0f);
    if (follower.w < 0.8f) return;
    follower.w = 0.0f;
    float previous = follower.y;
    follower.y = follower.x;
    follower.x = previous;
}

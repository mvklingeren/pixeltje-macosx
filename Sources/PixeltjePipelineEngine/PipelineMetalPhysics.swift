/// Small, stateless 3D motion and static-collider helpers for GPU Program.
/// Callers own body buffers, choose the fixed step and collision order, and
/// define their world. Contacts use an outward unit normal pointing from the
/// static collider toward the moving sphere; depth <= 0 means no overlap.
enum PipelineMetalPhysics {
  static let marker = "// pixeltje:physics-v1"

  static let library = """
    #include <metal_stdlib>
    namespace pixeltje_physics {
      using namespace metal;

      struct Body {
        float3 position;
        float3 velocity;
      };

      struct Contact {
        float3 normal;
        float depth;
      };

      // Semi-implicit Euler: update velocity before position. Damping is a
      // non-negative rate per second, independent of the chosen fixed step.
      inline Body integrate(Body body, float3 acceleration,
                            float damping, float dt) {
        dt = max(dt, 0.0f);
        body.velocity = (body.velocity + acceleration * dt)
          * exp(-max(damping, 0.0f) * dt);
        body.position += body.velocity * dt;
        return body;
      }

      // The plane is a one-sided solid half-space. Normal must have unit
      // length and point into the space that the sphere may occupy.
      inline Contact spherePlane(float3 centre, float radius,
                                 float3 planePoint, float3 normal) {
        return {normal, max(radius, 0.0f)
          - dot(centre - planePoint, normal)};
      }

      // The second sphere is static. A coincident pair separates along +X.
      inline Contact sphereSphere(float3 centre, float radius,
                                  float3 otherCentre, float otherRadius) {
        float3 delta = centre - otherCentre;
        float distance = length(delta);
        return {distance > 1.0e-6f ? delta / distance
          : float3(1.0f, 0.0f, 0.0f),
          max(radius, 0.0f) + max(otherRadius, 0.0f) - distance};
      }

      // Box lower <= upper componentwise. A centre inside the box exits by
      // the nearest face; ties consistently choose X, then Y, then Z.
      inline Contact sphereBox(float3 centre, float radius,
                               float3 lower, float3 upper) {
        float3 closest = clamp(centre, lower, upper);
        float3 delta = centre - closest;
        float distance = length(delta);
        radius = max(radius, 0.0f);
        if (any(centre < lower) || any(centre > upper)) {
          return {delta / distance, radius - distance};
        }
        float3 toLower = centre - lower;
        float3 toUpper = upper - centre;
        float nearest = toLower.x;
        float3 normal = float3(-1.0f, 0.0f, 0.0f);
        if (toUpper.x < nearest) {
          nearest = toUpper.x; normal = float3(1.0f, 0.0f, 0.0f);
        }
        if (toLower.y < nearest) {
          nearest = toLower.y; normal = float3(0.0f, -1.0f, 0.0f);
        }
        if (toUpper.y < nearest) {
          nearest = toUpper.y; normal = float3(0.0f, 1.0f, 0.0f);
        }
        if (toLower.z < nearest) {
          nearest = toLower.z; normal = float3(0.0f, 0.0f, -1.0f);
        }
        if (toUpper.z < nearest) {
          nearest = toUpper.z; normal = float3(0.0f, 0.0f, 1.0f);
        }
        return {normal, radius + nearest};
      }

      // Resolve one contact against a static collider. Restitution is 0..1;
      // friction is a non-negative Coulomb coefficient. This handles impact
      // friction, not resting/static friction or dynamic-body impulses.
      inline Body resolve(Body body, Contact contact,
                          float restitution, float friction) {
        if (contact.depth <= 0.0f) return body;
        body.position += contact.normal * contact.depth;
        float incoming = dot(body.velocity, contact.normal);
        if (incoming >= 0.0f) return body;
        float impulse = (1.0f + clamp(restitution, 0.0f, 1.0f)) * -incoming;
        body.velocity += contact.normal * impulse;
        float3 tangent = body.velocity
          - contact.normal * dot(body.velocity, contact.normal);
        float speed = length(tangent);
        if (speed > 1.0e-6f) {
          body.velocity -= tangent * (min(speed,
            max(friction, 0.0f) * impulse) / speed);
        }
        return body;
      }

      // A GPU Program owns this bounded world in one of its persistent buffers.
      // The host decides which static scene shapes are registered as colliders.
      // State: 0 unused, 1 moving, 2 sleeping. A sleeping body remains solid.
      struct RigidBody {
        float4 centreMass;       // world centre, inverse mass
        float4 orientation;      // local-to-world unit quaternion (xyzw)
        float4 linearBounce;     // linear velocity, restitution
        float4 angularFriction;  // angular velocity, Coulomb friction
        float4 extentState;      // box half extent, state
      };

      template <uint Capacity> struct World {
        RigidBody bodies[Capacity];
        float sleepSeconds[Capacity];
      };

      struct RigidContact {
        float3 normal; // from the second body toward the first
        float depth;
        float3 point;
      };

      inline float4 multiplyRotation(float4 a, float4 b) {
        return float4(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz),
          a.w * b.w - dot(a.xyz, b.xyz));
      }

      inline float3 rotate(float4 q, float3 v) {
        float3 t = 2.0f * cross(q.xyz, v);
        return v + q.w * t + cross(q.xyz, t);
      }

      inline float3 unrotate(float4 q, float3 v) {
        return rotate(float4(-q.xyz, q.w), v);
      }

      inline RigidBody makeRigidBody(float3 centre, float3 halfExtent,
                                     float4 orientation, float3 velocity,
                                     float inverseMass, float restitution,
                                     float friction) {
        RigidBody body;
        body.centreMass = float4(centre, max(inverseMass, 0.0f));
        body.orientation = normalize(orientation);
        body.linearBounce = float4(velocity, clamp(restitution, 0.0f, 1.0f));
        body.angularFriction = float4(0.0f, 0.0f, 0.0f,
          max(friction, 0.0f));
        body.extentState = float4(max(halfExtent, float3(0.02f)), 1.0f);
        return body;
      }

      inline void integrateRigid(thread RigidBody &body, float3 acceleration,
                                 float linearDamping, float angularDamping,
                                 float dt) {
        if (body.extentState.w != 1.0f) return;
        dt = max(dt, 0.0f);
        body.linearBounce.xyz = (body.linearBounce.xyz + acceleration * dt)
          * exp(-max(linearDamping, 0.0f) * dt);
        body.angularFriction.xyz *= exp(-max(angularDamping, 0.0f) * dt);
        body.centreMass.xyz += body.linearBounce.xyz * dt;
        float4 spin = float4(body.angularFriction.xyz, 0.0f);
        body.orientation = normalize(body.orientation
          + 0.5f * dt * multiplyRotation(spin, body.orientation));
      }

      inline float3 inverseInertia(RigidBody body, float3 torque) {
        float3 h = body.extentState.xyz;
        float3 local = unrotate(body.orientation, torque);
        float3 diagonal = 3.0f * body.centreMass.w / max(float3(
          h.y * h.y + h.z * h.z,
          h.x * h.x + h.z * h.z,
          h.x * h.x + h.y * h.y), float3(1.0e-5f));
        return rotate(body.orientation, local * diagonal);
      }

      inline float projectedRadius(RigidBody body, float3 axis) {
        float3 h = body.extentState.xyz;
        return abs(dot(rotate(body.orientation, float3(1.0f, 0.0f, 0.0f)),
          axis)) * h.x
          + abs(dot(rotate(body.orientation, float3(0.0f, 1.0f, 0.0f)),
          axis)) * h.y
          + abs(dot(rotate(body.orientation, float3(0.0f, 0.0f, 1.0f)),
          axis)) * h.z;
      }

      inline float3 boxHalfBounds(RigidBody body) {
        float3 h = body.extentState.xyz;
        return abs(rotate(body.orientation, float3(1.0f, 0.0f, 0.0f)))
          * h.x
          + abs(rotate(body.orientation, float3(0.0f, 1.0f, 0.0f)))
          * h.y
          + abs(rotate(body.orientation, float3(0.0f, 0.0f, 1.0f)))
          * h.z;
      }

      inline bool testBoxAxis(RigidBody a, RigidBody b, float3 axis,
                              thread RigidContact &best) {
        float axisLength = length(axis);
        if (axisLength < 1.0e-5f) return true;
        axis /= axisLength;
        float3 between = a.centreMass.xyz - b.centreMass.xyz;
        float depth = projectedRadius(a, axis)
          + projectedRadius(b, axis) - abs(dot(between, axis));
        if (depth <= 0.0f) return false;
        if (depth < best.depth) {
          best.depth = depth;
          best.normal = dot(between, axis) >= 0.0f ? axis : -axis;
          float3 reach = boxHalfBounds(a);
          best.point = clamp(0.5f * (a.centreMass.xyz + b.centreMass.xyz),
            a.centreMass.xyz - reach, a.centreMass.xyz + reach);
        }
        return true;
      }

      // Fifteen separating axes cover two oriented boxes, including
      // edge-on-edge contacts. Clamp the centre estimate to the first body's
      // bounds: a tiny piece against a large wall must not take an impulse at
      // the wall's distant centre. Plane contacts below use exact support points.
      inline RigidContact boxBox(RigidBody a, RigidBody b) {
        RigidContact best = {float3(0.0f, 1.0f, 0.0f),
          1.0e9f, 0.5f * (a.centreMass.xyz + b.centreMass.xyz)};
        float3 axesA[3] = {
          rotate(a.orientation, float3(1.0f, 0.0f, 0.0f)),
          rotate(a.orientation, float3(0.0f, 1.0f, 0.0f)),
          rotate(a.orientation, float3(0.0f, 0.0f, 1.0f))};
        float3 axesB[3] = {
          rotate(b.orientation, float3(1.0f, 0.0f, 0.0f)),
          rotate(b.orientation, float3(0.0f, 1.0f, 0.0f)),
          rotate(b.orientation, float3(0.0f, 0.0f, 1.0f))};
        for (uint i = 0u; i < 3u; ++i) {
          if (!testBoxAxis(a, b, axesA[i], best)
              || !testBoxAxis(a, b, axesB[i], best))
            return {float3(0.0f), 0.0f, float3(0.0f)};
        }
        for (uint i = 0u; i < 3u; ++i)
          for (uint j = 0u; j < 3u; ++j)
            if (!testBoxAxis(a, b, cross(axesA[i], axesB[j]), best))
              return {float3(0.0f), 0.0f, float3(0.0f)};
        return best;
      }

      inline RigidContact boxPlane(RigidBody body, float3 planePoint,
                                   float3 normal) {
        float3 point = body.centreMass.xyz;
        float3 localAxis[3] = {float3(1.0f, 0.0f, 0.0f),
          float3(0.0f, 1.0f, 0.0f), float3(0.0f, 0.0f, 1.0f)};
        for (uint i = 0u; i < 3u; ++i) {
          float3 axis = rotate(body.orientation, localAxis[i]);
          float projection = dot(axis, normal);
          if (abs(projection) > 1.0e-5f)
            point -= sign(projection) * axis * body.extentState[i];
        }
        return {normal, dot(planePoint - point, normal), point};
      }

      inline float impulseDenominator(RigidBody body, float3 lever,
                                      float3 direction) {
        if (body.centreMass.w == 0.0f) return 0.0f;
        return body.centreMass.w + dot(direction,
          cross(inverseInertia(body, cross(lever, direction)), lever));
      }

      inline void applyImpulse(thread RigidBody &body, float3 impulse,
                               float3 lever) {
        if (body.centreMass.w == 0.0f) return;
        body.linearBounce.xyz += impulse * body.centreMass.w;
        body.angularFriction.xyz += inverseInertia(body, cross(lever, impulse));
        body.extentState.w = 1.0f;
      }

      inline void solve(thread RigidBody &a, thread RigidBody &b,
                        RigidContact contact) {
        if (contact.depth <= 0.0f) return;
        float totalInverseMass = a.centreMass.w + b.centreMass.w;
        if (totalInverseMass <= 0.0f) return;
        float correction = max(contact.depth - 0.002f, 0.0f) * 0.8f
          / totalInverseMass;
        a.centreMass.xyz += contact.normal * correction * a.centreMass.w;
        b.centreMass.xyz -= contact.normal * correction * b.centreMass.w;
        float3 ra = contact.point - a.centreMass.xyz;
        float3 rb = contact.point - b.centreMass.xyz;
        float3 relative = a.linearBounce.xyz
          + cross(a.angularFriction.xyz, ra) - b.linearBounce.xyz
          - cross(b.angularFriction.xyz, rb);
        float incoming = dot(relative, contact.normal);
        if (incoming >= 0.0f) return;
        float denominator = impulseDenominator(a, ra, contact.normal)
          + impulseDenominator(b, rb, contact.normal);
        if (denominator <= 1.0e-7f) return;
        float restitution = min(a.linearBounce.w, b.linearBounce.w);
        float impulseSize = -(1.0f + restitution) * incoming / denominator;
        float3 normalImpulse = contact.normal * impulseSize;
        applyImpulse(a, normalImpulse, ra);
        applyImpulse(b, -normalImpulse, rb);
        relative = a.linearBounce.xyz + cross(a.angularFriction.xyz, ra)
          - b.linearBounce.xyz - cross(b.angularFriction.xyz, rb);
        float3 tangent = relative - contact.normal
          * dot(relative, contact.normal);
        float tangentLength = length(tangent);
        if (tangentLength <= 1.0e-6f) return;
        tangent /= tangentLength;
        float frictionDenominator = impulseDenominator(a, ra, tangent)
          + impulseDenominator(b, rb, tangent);
        if (frictionDenominator <= 1.0e-7f) return;
        float friction = sqrt(a.angularFriction.w * b.angularFriction.w);
        float frictionImpulse = min(tangentLength / frictionDenominator,
          friction * impulseSize);
        applyImpulse(a, -tangent * frictionImpulse, ra);
        applyImpulse(b, tangent * frictionImpulse, rb);
      }

      // Stacking needs a contact patch, not one point, and impulses that
      // accumulate over several iterations. A manifold holds up to four
      // points sharing one normal from the second body toward the first.
      // Depth may be slightly negative: such a speculative point lets the
      // solver stop an approach before the boxes overlap.
      struct RigidManifold {
        float3 normal;
        uint count;
        float4 points[4]; // world point, depth
      };

      inline float3 boxCorner(RigidBody body, uint corner) {
        float3 side = float3((corner & 1u) != 0u ? 1.0f : -1.0f,
          (corner & 2u) != 0u ? 1.0f : -1.0f,
          (corner & 4u) != 0u ? 1.0f : -1.0f);
        return body.centreMass.xyz
          + rotate(body.orientation, side * body.extentState.xyz);
      }

      inline bool boxContains(RigidBody body, float3 point, float slop) {
        float3 local = unrotate(body.orientation,
          point - body.centreMass.xyz);
        return all(abs(local) <= body.extentState.xyz + slop);
      }

      // Keeps the candidates at the four diagonal extremes of the contact
      // plane: for two overlapping rectangles these are the patch corners.
      inline RigidManifold reduceManifold(float3 normal,
                                          thread const float4 *candidates,
                                          uint count) {
        RigidManifold manifold;
        manifold.normal = normal;
        manifold.count = 0u;
        if (count <= 4u) {
          for (uint i = 0u; i < count; ++i)
            manifold.points[i] = candidates[i];
          manifold.count = count;
          return manifold;
        }
        float3 t1 = normalize(abs(normal.x) > 0.57f
          ? float3(normal.y, -normal.x, 0.0f)
          : float3(0.0f, normal.z, -normal.y));
        float3 t2 = cross(normal, t1);
        uint picks[4] = {0u, 0u, 0u, 0u};
        float best[4] = {-INFINITY, -INFINITY, -INFINITY, -INFINITY};
        for (uint i = 0u; i < count; ++i) {
          float a = dot(candidates[i].xyz, t1);
          float b = dot(candidates[i].xyz, t2);
          float score[4] = {a + b, a - b, b - a, -a - b};
          for (uint k = 0u; k < 4u; ++k)
            if (score[k] > best[k]) { best[k] = score[k]; picks[k] = i; }
        }
        for (uint k = 0u; k < 4u; ++k) {
          bool repeated = false;
          for (uint j = 0u; j < k; ++j) repeated |= picks[j] == picks[k];
          if (!repeated)
            manifold.points[manifold.count++] = candidates[picks[k]];
        }
        return manifold;
      }

      // Corners of each box that lie inside the other, measured against the
      // separating-axis normal. Edge-on-edge contacts have no such corner and
      // fall back to the single point from boxBox.
      inline RigidManifold boxBoxManifold(RigidBody a, RigidBody b,
                                          float slop) {
        // Inflate both boxes by half the slop so that a pair just apart
        // still finds its separating normal.
        RigidBody inflatedA = a, inflatedB = b;
        inflatedA.extentState.xyz += 0.5f * slop;
        inflatedB.extentState.xyz += 0.5f * slop;
        RigidContact contact = boxBox(inflatedA, inflatedB);
        RigidManifold manifold;
        manifold.normal = contact.normal;
        manifold.count = 0u;
        if (contact.depth <= 0.0f) return manifold;
        contact.depth -= slop;
        float3 n = contact.normal;
        float topB = dot(b.centreMass.xyz, n) + projectedRadius(b, n);
        float bottomA = dot(a.centreMass.xyz, n) - projectedRadius(a, n);
        float4 candidates[16];
        uint count = 0u;
        for (uint i = 0u; i < 8u; ++i) {
          float3 p = boxCorner(a, i);
          float depth = topB - dot(p, n);
          if (depth > -slop && boxContains(b, p, slop))
            candidates[count++] = float4(p, min(depth, contact.depth));
        }
        for (uint i = 0u; i < 8u; ++i) {
          float3 q = boxCorner(b, i);
          float depth = dot(q, n) - bottomA;
          if (depth > -slop && boxContains(a, q, slop))
            candidates[count++] = float4(q, min(depth, contact.depth));
        }
        if (count == 0u) {
          if (contact.depth <= 0.0f) return manifold;
          candidates[0] = float4(contact.point, contact.depth);
          count = 1u;
        }
        return reduceManifold(n, candidates, count);
      }

      // The plane is a solid half-space below normal; its normal points
      // toward the body (the manifold's second body is the plane).
      inline RigidManifold boxPlaneManifold(RigidBody body, float3 planePoint,
                                            float3 normal, float slop) {
        float4 candidates[8];
        uint count = 0u;
        for (uint i = 0u; i < 8u; ++i) {
          float3 p = boxCorner(body, i);
          float depth = dot(planePoint - p, normal);
          if (depth > -slop) candidates[count++] = float4(p, depth);
        }
        return reduceManifold(normal, candidates, count);
      }

      // One manifold point prepared for sequential impulses. Bodies are
      // caller indices; a static collider uses staticBody and no state.
      constant uint staticBody = 0xffffffffu;

      struct SolverContact {
        float4 point;     // world point, depth
        float4 normal;    // from the second body toward the first, impulse
        float4 tangent;   // first friction direction, impulse
        float4 bitangent; // second friction direction, impulse
        float4 masses;    // normal, tangent, bitangent effective mass,
                          // target normal velocity
        float4 material;  // Coulomb friction, closing speed, unused
        uint2 bodies;
      };

      inline RigidBody staticRigidBody() {
        return makeRigidBody(float3(0.0f), float3(1.0f),
          float4(0.0f, 0.0f, 0.0f, 1.0f), float3(0.0f), 0.0f, 0.0f, 0.0f);
      }

      inline float3 pointVelocity(RigidBody body, float3 point) {
        return body.linearBounce.xyz + cross(body.angularFriction.xyz,
          point - body.centreMass.xyz);
      }

      // Depth beyond slop is removed at baumgarte per step, at most
      // maxPush m/s. Restitution applies only above one metre per second,
      // so resting contacts do not bounce.
      inline SolverContact prepareContact(RigidBody a, RigidBody b,
                                          uint indexA, uint indexB,
                                          float3 normal, float4 pointDepth,
                                          float dt) {
        SolverContact c;
        c.bodies = uint2(indexA, indexB);
        c.point = pointDepth;
        float3 p = pointDepth.xyz;
        float3 t1 = normalize(abs(normal.x) > 0.57f
          ? float3(normal.y, -normal.x, 0.0f)
          : float3(0.0f, normal.z, -normal.y));
        float3 t2 = cross(normal, t1);
        c.normal = float4(normal, 0.0f);
        c.tangent = float4(t1, 0.0f);
        c.bitangent = float4(t2, 0.0f);
        float3 ra = p - a.centreMass.xyz;
        float3 rb = p - b.centreMass.xyz;
        float kn = impulseDenominator(a, ra, normal)
          + impulseDenominator(b, rb, normal);
        float kt = impulseDenominator(a, ra, t1)
          + impulseDenominator(b, rb, t1);
        float kb = impulseDenominator(a, ra, t2)
          + impulseDenominator(b, rb, t2);
        float closing = dot(pointVelocity(a, p) - pointVelocity(b, p),
          normal);
        float depth = pointDepth.w;
        dt = max(dt, 1.0e-4f);
        float target = depth > 0.0f
          ? min(0.25f * max(depth - 0.004f, 0.0f) / dt, 2.0f)
          : depth / dt;
        float restitution = min(a.linearBounce.w, b.linearBounce.w);
        if (closing < -1.0f) target = max(target, -restitution * closing);
        c.masses = float4(kn > 1.0e-7f ? 1.0f / kn : 0.0f,
          kt > 1.0e-7f ? 1.0f / kt : 0.0f,
          kb > 1.0e-7f ? 1.0f / kb : 0.0f, target);
        c.material = float4(sqrt(a.angularFriction.w * b.angularFriction.w),
          closing, 0.0f, 0.0f);
        return c;
      }

      // Accumulated impulses: the normal total never pulls, and friction
      // stays inside the Coulomb cone of the current normal total, which
      // gives resting (static) friction as well as sliding friction.
      inline void solveContact(thread RigidBody &a, thread RigidBody &b,
                               thread SolverContact &c) {
        float3 p = c.point.xyz;
        float3 ra = p - a.centreMass.xyz;
        float3 rb = p - b.centreMass.xyz;
        float3 n = c.normal.xyz;
        float vn = dot(pointVelocity(a, p) - pointVelocity(b, p), n);
        float previous = c.normal.w;
        c.normal.w = max(previous + c.masses.x * (c.masses.w - vn), 0.0f);
        float3 impulse = n * (c.normal.w - previous);
        applyImpulse(a, impulse, ra);
        applyImpulse(b, -impulse, rb);
        float limit = c.material.x * c.normal.w;
        float3 relative = pointVelocity(a, p) - pointVelocity(b, p);
        previous = c.tangent.w;
        c.tangent.w = clamp(previous
          - c.masses.y * dot(relative, c.tangent.xyz), -limit, limit);
        impulse = c.tangent.xyz * (c.tangent.w - previous);
        previous = c.bitangent.w;
        c.bitangent.w = clamp(previous
          - c.masses.z * dot(relative, c.bitangent.xyz), -limit, limit);
        impulse += c.bitangent.xyz * (c.bitangent.w - previous);
        applyImpulse(a, impulse, ra);
        applyImpulse(b, -impulse, rb);
      }

      // integrateRigid in two halves, for solvers that resolve contacts
      // between the velocity and position updates.
      inline void integrateVelocity(thread RigidBody &body,
                                    float3 acceleration, float linearDamping,
                                    float angularDamping, float dt) {
        if (body.extentState.w != 1.0f) return;
        dt = max(dt, 0.0f);
        body.linearBounce.xyz = (body.linearBounce.xyz + acceleration * dt)
          * exp(-max(linearDamping, 0.0f) * dt);
        body.angularFriction.xyz *= exp(-max(angularDamping, 0.0f) * dt);
      }

      inline void integratePosition(thread RigidBody &body, float dt) {
        if (body.extentState.w != 1.0f) return;
        dt = max(dt, 0.0f);
        body.centreMass.xyz += body.linearBounce.xyz * dt;
        float4 spin = float4(body.angularFriction.xyz, 0.0f);
        body.orientation = normalize(body.orientation
          + 0.5f * dt * multiplyRotation(spin, body.orientation));
      }
    }
    """
}

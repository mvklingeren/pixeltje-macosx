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
    }
    """
}

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
    }
    """
}

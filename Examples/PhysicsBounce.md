# Physics Bounce starter

Open `shader-physics-bounce.pixpipeline.json` in the Pipeline Editor and run its
Loop. `PhysicsBounceProgram.metal` opts into `// pixeltje:physics-v1` and keeps
one moving sphere in the GPU Program's `game` buffer. The example demonstrates
gravity, a one-sided floor, a static box, bounce, and impact friction. Its
offline views are in `Scripts/ShaderPreview/physics-bounce.views.json`.

`pixeltje_physics::Body` stores a 3D position and velocity. `integrate` applies
semi-implicit Euler motion with acceleration, damping rate per second, and a
step in seconds. `spherePlane`, `sphereSphere`, and `sphereBox` return a
`Contact` with a unit normal pointing out of the static collider and a
penetration depth; depth at or below zero means no overlap. `resolve` separates
the moving sphere and applies restitution (0–1) and impact friction (a
non-negative Coulomb coefficient).

The helpers have no global state, world, broad phase, swept collision or
joints. The GPU Program owns its bodies, passes, fixed step, and collision
order. For stacks and resting contact between oriented boxes, use the
manifold and accumulated-impulse helpers that the Physics Playground
(`PhysicsPlayground.md`) demonstrates. Use small steps for fast bodies. A future Haunted House
integration can start with the player's collision shape against floor and
wall boxes while leaving its scene and gameplay state in that workflow.

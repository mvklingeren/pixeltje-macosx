# Physics Playground

Open `shader-physics-playground.pixpipeline.json` in the Pipeline Editor with
`PhysicsPlaygroundProgram.metal` beside it and run its Loop. Move the pointer
to look around, hold W/A/S/D to walk, click to shoot and press Space to fire a
heavy cannonball. R rebuilds the scene. The yard holds a cottage with a brick
chimney on its own footing, a stone tower of four drums, a garden wall, a
post-and-lintel gate, a crate pyramid and a row of dominoes.

Painted toy cubes and balls in the foreground, and a ball hanging on a rope
from a steel frame, never break: a shot or a hit only pushes them, so they
show how bodies interact. The steel frame ignores shots and the cannonball.
The library has boxes only, so balls collide in the playground itself with
one contact point each. The rope is a contact that only pulls the top of
its ball toward the anchor, with no friction; it is slack below its length.

Static structures are boxes divided into a grid of up to 8 × 8 cells. A shot
removes the cell it hits and throws two shards. A support pass then works out,
from nothing, which cells still reach the ground. Inside a part, cells hold
together through their four neighbours. Between parts, support passes
through two kinds of link:

- A part that rests on another (its bottom face on the other's top) is
  supported through the cells where they meet. A part with such a chain to
  the ground bears its own load. It must also balance: the centre of what
  stands must lie over the cells it stands on, so a lintel left on one post
  topples.
- A part with no such chain, such as a floor laid between walls, is held by
  whatever it touches at its sides. Parts that bear their own load ignore
  side contact, so a chimney beside a wall falls when its base is shot
  through.

Every loose cell turns into a rigid chunk. Loose cells that do not form a
rectangle split into several box chunks, so no body collides with cells that
are gone. A freed chunk drifts and tips away from the latest break. A fast
heavy body, such as the cannonball, breaks the cells it strikes.

The bodies use the `// pixeltje:physics-v1` solver: `boxBoxManifold` and
`boxPlaneManifold` return up to four contact points, `prepareContact` and
`solveContact` apply accumulated impulses with resting friction, and
`integrateVelocity` and `integratePosition` bracket the solve. The tick runs
two substeps, each as a collide pass and a solve pass. Offline views are in
`Scripts/ShaderPreview/physics-playground.views.json`. The haunted house uses
the same support rules (`HauntedSupport.metal`) and solver
(`HauntedPhysicsWorld.metal`).

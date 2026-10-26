# Physics Playground

Open `shader-physics-playground.pixpipeline.json` in the Pipeline Editor with
`PhysicsPlaygroundProgram.metal` beside it and run its Loop. Move the pointer
to look around, hold W/A/S/D to walk, click to shoot, press Space to jump, and
press C to launch the heavy box. Right click and J also trigger the jump
because they share the Trackpad's second action with Space. R rebuilds the scene. F switches between
first person and a third-person camera behind a walking character. The yard
holds a cottage with a brick chimney on its own footing, a stone tower of four
drums, a garden wall, a post-and-lintel gate, a crate pyramid and a row of
dominoes.

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

The scene uses a GGX microfacet BRDF for its directional sun. Brick, stone,
wood, roof, steel, rope, and painted toys each have roughness and metallic
values; newly exposed fracture faces become rough and nonmetallic. The
`Environment HDR` File Path node links to
`~/Downloads/suburban_garden_1k.hdr`; choose another Radiance RGBE `.hdr`
file there if needed. The GPU Program decodes the linked file in linear light
and uses it only for diffuse fill and roughness-filtered reflections; the
visible sky stays procedural and there is no distance fog. The file stays
outside the repository and must be present to run the example. Mip filtering
and five-direction diffuse sampling approximate environment convolution; the
diffuse fill is capped so the map's own sun does not light surfaces twice.
Scene objects do not appear in reflections. The character's material is matte
with faint highlights. Traced sun shadows still cover the scene; the character
uses the same lighting model with a fixed nonmetallic material but does not
receive those traced shadows.

## Third-person character

The character is a skinned FBX model. A File Path node points to
`/Users/mvklingeren/Downloads/Yaku-Walking.fbx` (a Mixamo export outside the
repository). Its file picker can choose another FBX; choose **Absolute** for
a file outside the workflow folder or **Relative** for one inside it. The
Load Skinned Model node reads it through the vendored ufbx library, samples
one animation at 30 fps with the hips' net travel removed, and packs its
embedded diffuse textures into an atlas. An Asset Cache hands the geometry,
animation and texture to the GPU Program as one `skinnedModel` resource.
Yaku-Walking has one
animation stack, `mixamo.com`, lasting about 1.02 seconds. The loader's
Animation field can select a named stack when an FBX has several; when it is
empty the loader chooses the longest moving stack. Only one stack is packed
for a Run, so this example cannot change animation clips during play. Space
currently lifts the character with a physical jump while holding its current
walking pose; a separate jump clip would need to be supplied and wired for
runtime clip switching.

In third person the camera looks over the character's right shoulder and
moves in front of anything behind it. If an obstacle pushes the camera inside
the character, it temporarily uses the eye view and hides the character until
there is room again. `placeCamera` runs in present so it follows a preview
view's writes. The ray-traced scene writes its depth to a
depth resource, and `characterVertex` skins every vertex between two sampled
frames in a second, depth-tested render pass. The character turns toward
where it moves and walks only while grounded; standing still or jumping holds
the last stride. Movement is about 1.93 m/s, matching the distance covered by
Yaku's walking cycle. It is lit like the scene and casts a soft contact shadow, but
not the scene's traced sun shadow, and shots pass through it. Offline views are
in `Scripts/ShaderPreview/physics-playground-character.views.json`; they hold F on
their first frame to switch to third person.

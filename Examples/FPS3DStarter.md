# First-Person 3D Starter

Open `shader-fps-3d-starter.pixpipeline.json` in the Pipeline Editor with its
`FPS3DStarterProgram.metal` file beside it. Run with **Save generated images to
disk** off and open the full-screen preview. Move the pointer to look around,
hold W/S to move forward/back and A/D to strafe, and click or press Space to
shoot the orange target. The crosshair turns green after a hit. Reset the Loop
to restore the target. No generated assets or model links are needed.

The GPU Program declares one game-state buffer and one output texture. Its
initialize pass sets the player position; its tick reads Trackpad and WASD
inputs, moves the player, and performs a hitscan shot; its present pass traces
the room and draws the crosshair. `traceScene` serves both shooting and
rendering. The `// pixeltje:3d-v1` marker supplies camera, intersection, and
color helpers. Replace the room, crate, target, collision, and rules with your
own game while retaining the documented GPU Program uniform layout and the
compute-owned state flow.

For outdoor ground, add `// pixeltje:terrain-v1` to the leading marker lines.
It supplies seeded `pixeltje_terrain::valueNoise`, `fbm` and `craters` to
compose a height field, and `trace`, `normal` and `softShadow`, which accept
any struct with `float operator()(float2 xz) const` as that field. Use the
same field for collision height so the player walks on what is drawn.

Signal Range shows a larger FPS built on the same pattern, with enemy AI,
generated assets, audio, a scene handoff, and an exit onto a terrain-library
moon. Abyssal Treasure shows the 3D helpers in a different first-person game.

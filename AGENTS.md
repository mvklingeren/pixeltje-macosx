# Pixeltje macOS native application plan

## Development tooling

For semantic Swift navigation and inspection, prefer the read-only tools from
the project-scoped `swift_pixeltje_macosx` MCP server when they are available.
Use SourceKit-backed definitions, references, hover information, diagnostics,
and hierarchies to complement text search. Write-capable rename, formatting,
and code-action tools are deliberately not enabled.

The server is configured by [`.codex/config.toml`](.codex/config.toml). On a
new machine, install its pinned local bridge by running
`.codex/sourcekit-mcp/setup.sh` from the repository root, then restart Codex.
This development tool is isolated from the application and does not add a
runtime, build-time, or test-time product dependency.

### Swift toolchain selection

Select the Xcode toolchain that contains the macOS 27 SDK explicitly when
building or testing. The standalone Command Line Tools selected by
`xcode-select` can carry a Swift compiler patch version that does not match
its installed macOS SDK. Use the per-command developer directory rather than
relying on that global selection; with an Xcode beta installed at the default
location:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test
```

Keep this override local to the command unless the maintainer explicitly wants
to change the machine-wide `xcode-select` setting.

### SwiftPM builds in the Codex sandbox

SwiftPM cannot compile the package manifest in Codex's default workspace
sandbox. It first fails to write the Clang module cache under
`~/.cache/clang/ModuleCache`; redirecting the cache still fails when SwiftPM
calls `sandbox-exec` (`sandbox_apply: Operation not permitted`). For a build,
request `sandbox_permissions: "require_escalated"` on the first `exec_command`
attempt and keep the `DEVELOPER_DIR` override above. Use the same approach for
tests only after the test execution preference below permits them. Do not
change the machine-wide toolchain or `HOME` to work around this restriction.

### FLUX.2 Klein Core AI example

To open the known-working FLUX.2 Klein 4B Distilled example in the Pipeline
Editor with the local Apple Core AI export, run this repository command:

```sh
./Scripts/run-flux2-klein-4b-distilled.command
```

The command selects the Xcode beta toolchain and defaults to
`~/coreai-models/exports/FLUX.2-klein-4B`. Set
`PIXELTJE_FLUX2_KLEIN_MODEL_PATH` before launching to use another compatible
package directory. That public export contains the Distilled transformer; do
not use it with the separate 4B Base example.

### Test execution preference

After completing a task that changes or adds project files, ask the maintainer
whether to run selected tests, all tests, or no tests. Do not run unit tests
before the maintainer makes that choice, and do not automatically run the full
suite. Build and non-test checks may still run as needed.

Exception: after a substantial changeset to `PixeltjePipelineDomain` or
`PixeltjePipelineEngine`, always run the focused tests for both pipeline
modules in the same session without asking first. Continue to ask before
running the complete repository test suite.

### Pasteboard tests

Failures confined to macOS pasteboard tests are acceptable and do not block
completion. The pasteboard is shared process state and can be cleared by other
tests or applications; rerun a failing pasteboard test in isolation for useful
diagnostics, but do not change product code merely to make that environmental
failure pass.

### ComfyUI generation connector

The active external generation architecture, workflow-template contract,
transport responsibilities, persistence rules, and extension procedure are
documented in
[ComfyUI Integration](Documentation/Architecture/ComfyUI-Integration.md).
Read that document before changing the connector or adding a workflow. The
older Core AI Z-Image documents describe the parked in-process pipeline and are
not the contract for ComfyUI execution.

The bundled FLUX.2 Klein Base/Distilled inpaint workflows share one path:
capture the composite and selection mask, upload an opaque source PNG and an
inverted-alpha mask PNG, then apply the same feathered mask to the returned
pixels as premultiplied layer alpha. Pixels outside mask coverage must be
transparent in the generated layer so the existing stack remains their sole
source. Keep the maskless FLUX image-edit workflows separate from these inpaint
workflows. A broad selection permits changes anywhere
inside its mask. Completed ComfyUI inpaints are generated-inpaint layers with a
local 0–100 Change threshold property. When enabled, the compositor compares
the returned pixels against the uploaded sRGB source, softens the change matte,
and makes near-unchanged generated pixels transparent. Persist the frozen
source, returned pixels, and final mask/comparison data with the layer so the
threshold remains editable after reopening. The threshold never changes the
uploaded mask or server workflow.

The Core AI generation milestones and model policy below describe the parked
in-process direction. For the active user-managed ComfyUI execution path and
its server-side model formats, follow the integration document instead.

### Core AI pipeline framework

The portable `*.pixpipeline.json` graph, ComfyUI frontend-workflow converter,
Pipeline Editor, validation and planning phases, resource-linking rules, and
first executable Z-Image family adapter are documented in
[Pixeltje Core AI Pipeline](Documentation/Architecture/pixeltje-coreai-pipeline.md).
Read that document before changing `PixeltjePipelineDomain`,
`PixeltjePipelineComfyUIConverter`, `PixeltjePipelineEngine`,
`PixeltjePipelineEditor`, or `PixeltjePipelineConverterCLI`. The framework is a
working but parked in-process slice; it does not replace the active ComfyUI
connector contract above.

Use the [Pipeline node reference](Documentation/Architecture/Pipeline-Node-Reference.md)
when working with the built-in node vocabulary. Keep it in sync with the
`PipelineNodeRegistry.coreAIV1` descriptors, ComfyUI mappings, and installed
executors whenever node types, ports, parameters, or execution support change.

### Pixeltje Pipeline node design

Minimize new node kinds. First check whether a workflow can be assembled from
existing, reusable nodes and typed ports. When a new operation is necessary,
design one composable primitive that can serve other workflows; avoid nodes
whose fixed inputs, colors, or behavior encode one example or request.

Always ask the maintainer for explicit permission before creating a new
Pipeline node kind. Present the proposed purpose, ports, parameters, and why
existing nodes are insufficient. A general request for a new workflow does
not grant permission to add node kinds. An explicit instruction to implement
an already proposed node kind does grant that permission.

## Visual verification

Visual inspection of the running application is always done by the human
maintainer, never by an agent. Do not use computer use, screen capture,
AppleScript or System Events, accessibility clicking, or any other UI automation
to look at or drive this app.

Agents verify their work with `swift build`, code reading, and the tests chosen
by the maintainer under the test execution preference above.
When a change needs to be seen, say how to launch it (for example
`swift run PixeltjeMacApp "/path/to/photo.RAF"`) and what to look at, then leave
the looking to the maintainer.

## Toolbar containers

Toolbar controls in the document window use macOS glass containers. A custom
`NSToolbarItem.view` is measured from Auto Layout rather than its initial
frame, so give every `NSGlassEffectView` explicit width and height constraints.
Use a 32-point height and a 16-point corner radius: equal width makes a circular
icon control, while a wider control becomes a pill.

Use fixed toolbar spacing between controls that must remain visually distinct;
otherwise nearby glass can read as one group. Hide the complete
`NSToolbarItem`, not only its content, when a transient control such as render
progress is inactive, so no empty container or gap remains. Mark leading
controls as navigational when they must stay before the document filename.
Panel toggle buttons must also have matching, discoverable View-menu keyboard
commands.

## Purpose

This repository contains a native macOS 27 application written in Swift.

The application uses Apple's public Core Image stack, with `CIRAWFilter` as
the sole RAW decoder and developer. The first product milestone was a focused,
native RAW developer; the product scope below builds compose and generate on
top of it.

## Dependency boundary

The application must not depend on any of the following at runtime, build
time, test time, or through generated artifacts:

- files imported through paths outside this project directory;
- LibRaw, rsraw, third-party RAW converters, or another hidden RAW fallback;
- private RawCamera APIs, reverse-engineered symbols, private framework entry
  points, or redistributed Apple RAW/model assets.

The project must build and test from a standalone copy of this repository. CI
enforces this with a standalone-copy build and the dependency audit in
`Scripts/check-independence.sh`.

## Platform and technology choices

- Swift 6.
- macOS 27 minimum deployment target.
- AppKit for application lifecycle, document windows, menus, undo/redo,
  drag-and-drop, and native platform behavior.
- SwiftUI for inspectors, settings, toolbar content, and other state-driven UI.
- MetalKit `MTKView` for the image canvas.
- Core Image and `CIRAWFilter` for RAW development and image processing.
- A Metal-backed `CIContext` for display and export rendering.
- Core AI for learned-model runtimes embedded in the application. The active
  external generation path delegates inference to user-managed ComfyUI and
  does not load its model artifacts. Core AI is distinct from the older Core ML
  stack: do not import `CoreML`, construct an `MLModel`, or accept `.mlmodel`,
  `.mlpackage`, or `.mlmodelc` artifacts.
- ImageIO for metadata and encoded output.
- Uniform Type Identifiers for document, import, and export declarations.
- OSLog and Signposts for diagnostics and performance measurement.

Prefer Apple frameworks and standard library facilities. Any future external
package requires an explicit architecture decision and license review.

## Core AI model policy

- The parked in-process model path imports and executes `.aimodel` and
  `.aimodelc` packages only. The application does not import or convert
  `.ckpt`, `.safetensors`, `.pt`, `.pth`, Core ML, or other training and runtime
  formats; ComfyUI manages its own server-side model files.
- Original weights obtained directly from their original publisher may be
  inputs to an independently authored, offline Core AI conversion workflow.
  Original weights and conversion tooling are not application runtime inputs.
- Draw Things is product and workflow reference material only. Do not use its
  code, runtime, converted model files, catalogs, metadata, or distribution
  services.
- Until Pixeltje has its own distribution channel, index Core AI packages in a
  user-selected model-library directory under the user's home directory. Store
  access as a security-scoped bookmark, load packages in place, and identify
  them by package identity and content hash rather than by path.
- Model packages are link-only dependencies of project recipes. A missing or
  changed package requires an explicit relink; it is never copied into a
  project or silently substituted.

## Product scope

The application is one native editor that develops RAW, composes layers and
generates images, measured against leading photo and image-generation editors.
The RAW developer described in the milestones below is the foundation, not the
ceiling.

RAW layers are deliberately conservative: the default workflow is one
developed RAW plus JPEG, TIFF, or PNG output placed as ordinary image layers.
Multiple linked RAW layers are an advanced, off-by-default workflow governed by
the multiple-RAW contract below.

Placement rule: tools in the left toolbar, tool and generation settings in the
left panel, layers and canvas in the right panel, per-layer development in
the Develop panel, history, snapshots and background queues in the assistance
panel, prompts in the prompt box. The split is what a surface is about, not how
wide its scope is: the left panel is the tool in hand, the right panel is what
the document is, the Develop panel is the selected RAW, linked-image, or paint
layer, and the assistance panel is how the work is going. Selection and crop are
document-wide and still belong on the left, because they are what a tool is
doing. The assistance panel is the outermost column on the right and starts
collapsed, because the Develop panel needs to remain available beside the
layers at the default window width. Tags: [engine] no direct UI, [panel]
inspector panel, [assist] assistance panel, [toolbar] a tool, [tool-setting] a
setting of a tool, [popup] small in-screen popup, [menu] menu command,
[settings] settings window.

### Basic requirements

In order of importance. Ship these before anything in the continuation list.

1. Undo, redo and history [assist]. Every recipe change is an undoable step,
   the history panel lists them, and snapshots pin a state to return to.
   Edit menu for undo and redo, history and snapshots in the assistance panel.
2. Layer stack [panel]. Text, group and adjustment layers added to RAW, image,
   vector and canvas. Blend modes, opacity, fill. Right panel, the existing
   layers inspector.
3. Crop and straighten [toolbar] with aspect ratio, angle and overlay
   [tool-setting]. Lens correction and upright [panel]. Crop tool in the left
   toolbar, its settings in the left panel, lens and upright in the Develop
   panel for the selected RAW layer.
4. Canvas size [panel] with the existing presets. Rulers, guides, grids,
   snapping [panel] with toggles [menu]. Right panel canvas settings, toggles
   mirrored in the View menu.
5. Histogram and clipping indicators [panel]. White-balance picker [panel].
   As shot white balance [panel]. Before and after [panel]. Histogram at the
   top of the right panel with the clipping triangles and before/after in its
   header; picker and as shot in the Apple RAW section, above the two sliders
   they write. None of the three is a tool, so none is in the tool strip: the
   picker arms a one-shot pixel request over whichever tool is active rather
   than being a mode of its own, and it has no tool settings and nothing to
   switch back from.
6. Basic tone panel [panel]. Exposure, contrast, highlights, shadows, whites,
   blacks, texture, clarity, dehaze, vibrance, saturation. Develop panel for
   the selected RAW, linked-image, or paint layer.
7. Tone curve [panel]. Parametric, point, and per-channel RGB in one editor.
   Rename the existing boost slider to "Tone boost". Develop panel for the
   selected RAW, linked-image, or paint layer.
8. Detail [panel]. Sharpening with masking, luminance and color noise
   reduction. Develop panel for the selected RAW, linked-image, or paint layer.
9. Export presets [popup] for format, resize, output sharpening, watermark,
   naming and embedded generation metadata. Background export queue [assist].
   Popup from the File menu, queue in the assistance panel.
10. Profiles and presets [panel]. Copy, paste and sync settings across the
   browser selection [menu]. Presets list in the left panel, profile picker
   at the top of the Develop panel, copy and sync in the Edit menu.
11. Virtual copy [menu] of a non-destructive recipe. File menu, copies appear
    in the browser.
12. Free transform [toolbar]. Scale, rotate, skew, perspective, warp
    [tool-setting]. Left toolbar, mode and numeric fields in the left panel.
13. Masks tool [toolbar] on the shared mask model. Subject and person from
    Vision, background as the inverse, sky through a Core AI segmentation
    package [tool-setting]. Linear gradient, radial gradient, brush, luminance
    range, color range [tool-setting]. Add, subtract, intersect
    [tool-setting]. Per-mask adjustments [panel]. Tool in the left toolbar,
    mask type and combine mode in the left panel, mask list with its
    adjustments in the right panel under the layer.
14. Layer masks [panel]. Pixel, vector and clipping mask per layer, painted
    with the brush [toolbar]. Mask thumbnail beside the layer in the right
    panel, brush in the left toolbar.
15. Brush and eraser [toolbar]. Size, hardness, opacity, flow, pressure
    [tool-setting]. Dodge and burn [toolbar] with range and exposure
    [tool-setting]. Content-aware fill [menu]. Tools in the left toolbar,
    settings in the left panel, fill in the Edit menu.
16. Selections. Marquee, lasso, quick select [toolbar]. Select subject and
    person [menu]. Color range [popup]. Refine with feather, expand, contract,
    smooth [popup]. Save selection as mask [menu]. Tools in the left toolbar,
    tool settings in the left panel, commands in a Select menu, popups on the
    canvas.
17. Diffusion pipeline on Core AI [engine]. Text encoder, denoiser and VAE
    decoder as package functions. Tokenizer, scheduler and samplers in Swift.
    Inference encoded on the canvas's Metal queue. No UI beyond progress in
    the prompt box.
18. Model manager [settings]. Import `.aimodel` and `.aimodelc` only. Catalog
    download. Metadata, functions and storage types shown. Specialize on
    import. Compute unit preference and cache purge policy [settings].
    Settings window, with a model picker at the top of the left panel
    generation section.
19. Text-to-image and image-to-image through the generate tool. Model,
    sampler, steps, guidance, seed, seed mode, clip skip, batch count
    [tool-setting]. Left panel generation section, generate button in the
    prompt box.
20. Generate tool [toolbar] for inpaint and outpaint. Mask source, strength,
    mask blur [tool-setting]. Prompt and negative prompt [popup]. Tool in the
    left toolbar, settings in the left panel, prompts in the prompt box.
21. Generation as a layer recipe [engine]. Result is an image layer carrying
    parameters and model identity. Regenerate [menu]. Relink a missing
    package [popup]. Regenerate in the prompt box and Layer menu, relink
    popup on the canvas, parameters readable in the right panel layer
    properties.
22. Generation queue [panel] with progress and cancel. Progress and cancel in
    the prompt box, queued jobs in the left panel.

### Continuation

After the basic requirements, in this order.

1. Color mixer [panel] and color grading wheels [panel]. Shadows, midtones
   and highlights with blending and balance, as ASC CDL math in the linear
   working space. Develop panel for the selected RAW layer.
2. Vignette and grain [panel]. Develop panel for the selected RAW layer.
3. Adjustment layers [panel]. Curves, levels, hue and saturation, black and
   white, color lookup, gradient map. Added from the layers inspector,
   settings shown in the right panel when selected.
4. Heal, clone and remove [toolbar]. Size, feather, opacity, source mode
   [tool-setting]. Left toolbar, settings in the left panel.
5. Text tool [toolbar]. Font, size, tracking, color, alignment
   [tool-setting]. Left toolbar, settings in the left panel.
6. Shape tool [toolbar] beside the existing pen [toolbar]. Stroke, fill,
   boolean operations [tool-setting]. Left toolbar, settings in the left
   panel.
7. Smart filters [menu] with a live-preview parameter popup [popup].
   Gaussian blur, motion blur, unsharp mask, high pass, noise. Filter menu,
   popup on the canvas, applied filters listed under the layer in the right
   panel.
8. Smart objects [panel]. Linked placed layers with non-destructive
   transform and smart filters. Right panel, layer properties.
9. Layer styles [panel]. Drop shadow, inner shadow, stroke, outer glow.
   Right panel, layer properties.
10. HDR editing [panel] and HDR export with gain map [menu]. HDR toggle in
    the right panel canvas settings, export in the File menu.
11. Guidance [tool-setting]. Depth, edge, pose and tile conditioning with a
    source layer picker, when the package exposes it. Edge and pose from
    Vision. Image reference adapter. Left panel generation section.
12. LoRA [tool-setting]. Per-LoRA weights when the package takes them,
    otherwise merged variants in the model list. Left panel generation
    section.
13. Upscale [menu] with an options popup [popup]. Upscaler package, tiled
    diffusion, plain resampling. Image menu, popup on the canvas.
14. Detailer pass [tool-setting]. Second inpaint pass on Vision face and hand
    rectangles. Left panel generation section.
15. Instruction editing [popup]. One sentence changes the selected layer. An
    edit mode of the prompt box.
16. Automation [engine]. One protocol-independent semantic command API with
    adapters for authenticated local MCP, Shortcuts actions, and a small script
    API. Shortcuts app, run script in the File menu, and an opt-in MCP endpoint
    in Settings.

### Out of scope

- PSD compatibility;
- arbitrary executable plug-ins, general-purpose material graphs, and headless
  operation. The typed Core AI pipeline graph and its dedicated companion
  editor are explicitly in scope under the pipeline framework contract;
- portable or non-Apple RAW decoding.

## Architectural rules

Use one-way state and rendering flow:

```text
AppKit / SwiftUI events
  -> typed editor action
  -> document recipe mutation + UndoManager record + revision
  -> immutable render request
  -> render actor
  -> revision-tagged result
  -> Metal canvas or export destination
```

Required ownership boundaries:

- `ProjectDocument` owns serializable edit intent, linked source identities,
  dirty state, undo registration, and document persistence. It owns no GPU
  resources.
- `EditorModel` contains typed, framework-light recipes and produces immutable
  render snapshots.
- `RawCoreImage` is the only module allowed to construct or mutate
  `CIRAWFilter`.
- `RenderEngine` owns `MTLDevice`, command queues, `CIContext` instances,
  per-layer RAW filter sessions, bounded render caches, cancellation, and
  memory-pressure handling.
- `MetalCanvas` owns viewport interaction and presentation, but cannot mutate
  the document recipe directly.
- SwiftUI views receive view models and emit typed actions. They cannot perform
  file IO, create filters, or start independent rendering work.
- Non-`Sendable` Core Image and Metal objects remain isolated to their owning
  actor or main-actor view.
- Every asynchronous render is tagged with a document ID and monotonically
  increasing content revision. Stale completions must be discarded.

Automation follows the same one-way path rather than creating a second editor:

- `PixeltjeAutomation` contains only semantic commands, sanitized snapshots,
  scopes, errors, and receipts. It imports no AppKit, MCP, network, Core Image,
  or Metal API.
- Transport adapters such as `PixeltjeMCP` depend on that automation contract;
  the automation contract never depends on a transport.
- `PixeltjeScripting` is a JavaScriptCore adapter over that same contract. It
  runs each trusted local script off the main thread in a fresh context and
  exposes one versioned, frozen, JSON-only `pixeltje` global; it never exports
  native editor objects or implicit file, network, shell, bookmark, or model
  access.
- `ProjectAutomationController` resolves stable document and object IDs and is
  the only layer that translates automation commands into `EditorAction`.
- Every mutation requires an expected content revision and an idempotency key,
  validates the complete request first, and commits as one undoable history
  step. Stale requests and requests that overlap uncommitted human gestures
  fail clearly.
- Automation never exposes serialized project recipes, arbitrary key paths,
  linked-source paths, security-scoped bookmarks, or generic execute/eval
  escape hatches.
- The MCP adapter is disabled by default, binds only to loopback while the app
  is running, authenticates every request with a Keychain-backed token, and
  grants read, edit, and job-control scopes separately.

Suggested modules:

```text
PixeltjeMacApp
PixeltjeAutomation
PixeltjeMCP
PixeltjeScripting
PixeltjePipelineDomain
PixeltjePipelineEngine
PixeltjePipelineScripting
PixeltjePipelineEditor
ProjectDocument
EditorModel
RawCoreImage
RenderEngine
MetalCanvas
Inspectors
ExportKit
TestSupport
```

Add a boundary only when the native implementation has a real consumer for it.

## One editor and one shared pipeline engine

Develop, compose and generate share one document, one window and one render
path in Pixeltje Mac. A separate Pixeltje Pipeline Editor may author, validate,
and preview `*.pixpipeline.json` graphs, but it is a companion authoring tool,
not a second photo editor. Both executables must import the same
`PixeltjePipelineEngine`; the companion must not acquire a private generation
runtime or independent pipeline semantics. These rules keep the product and
companion from drifting into separate generation systems:

- **One mask model.** Local adjustments, layer masks, selections and inpaint
  masks are the same type. A mask made by any tool can be handed to any other
  without conversion.
- **Everything is a recipe.** Every edit, including generation parameters, is
  serializable state in the project. No pixels are produced that cannot be
  reproduced from the recipe plus its linked sources. Adjustments belong to the
  layer they act on, not to the project; only the canvas extent and crop are
  document-level.
- **Link-only sources, including models.** A recipe records a package name,
  content hash and the function names it calls, never a copy of the package.
  A missing package is a relink prompt, not a silent substitution.
- **One model-service implementation.** Each host process owns exactly one
  `PixeltjePipelineEngine` model service, and both applications use that shared
  Swift implementation. It loads, specializes and caches every Core AI package
  for segmentation, diffusion, upscaling and detailing. Tools ask it for a
  function by identity; they never open a package themselves.
- **Linear Display P3 with EDR end to end.** Develop, compose and generate all
  work in the Extended Linear Display P3 working space described under
  orientation, coordinates and color, and present through the EDR canvas.
  Generation output enters the pipeline as linear P3 like any other layer.
- **Proxy rendering for everything.** Compose and generate use the same proxy
  and final render qualities, revision tagging and stale-result discard as RAW
  development, so one window serves all three.

## Multiple RAW layer contract

The normal workflow has one primary RAW layer. A user who wants to reuse its
developed pixels should export JPEG, TIFF, or PNG and place that output as an
ordinary image layer. Settings may expose **Allow multiple RAW layers** for
advanced compositing, but it is off by default. Turning it off hides creation
of additional RAW layers; it must not make an existing multi-RAW document
unopenable or uneditable.

Keep RAW placement explicit:

- The ordinary Add Image action rejects camera RAW types and never sends them
  through generic Core Image URL loading.
- When the setting is enabled, expose a separate Add RAW action that accepts
  only camera RAW types. `CIRAWFilter` remains the authority for support and
  image geometry.
- The original `.rawBackground` is the locked primary layer and establishes
  the document canvas. Additional RAW layers are unlocked, transformable
  placed layers whose initial frames aspect-fit the developed RAW dimensions.

Every developed RAW layer owns its own linked `SourceReference`, source
fingerprint, decoder selection, captured defaults, capabilities,
`RawDevelopmentRecipe`, `UprightRecipe`, and placement frame. It also gets its
own render-session state and caches. Never use the document's legacy background
RAW fields as the source of truth for a placed RAW layer, and never share a
mutable `CIRAWFilter` between layers.

The Develop panel always follows `layerStack.activeLayerID`. It names the
selected RAW, linked-image, or paint layer, and every control targets that layer
by ID. Linked images and paint layers receive the shared Basic Tone, Tone Curve
and Detail controls. White-balance sampling, RAW reset, before/after, decoder,
lens and upright controls remain available only for developed RAW layers. When
the selected layer is not a developed RAW, linked image, or paint layer, keep
the panel visible but disable its editing content and explain which layer types
are supported. The histogram continues to describe the composite document
output.

Persistence and migration must preserve old projects exactly:

- Schema version 13 and later persist RAW state on each developed RAW layer.
- When opening schema version 12 or earlier, migrate the legacy source, RAW
  recipe, and upright recipe only onto `.rawBackground`.
- Legacy top-level RAW fields, while they remain decodable, are compatibility
  mirrors of `.rawBackground`; they must never overwrite sibling RAW layers.
- Legacy post-processing remains attached to `.rawBackground` so old projects
  keep their rendered appearance. Do not reinterpret it as global composite
  tone without a separate product decision and migration.

A render request carries RAW inputs keyed by layer ID. Develop and cache every
enabled RAW independently before layer placement and compositing, bound caches
per render quality, and clear them under memory pressure. A missing, changed,
or unsupported enabled RAW source fails clearly instead of silently omitting
that layer or substituting another decoder.

## RAW rendering contract

For every enabled developed RAW layer, the complete image path is:

```text
RAW URL
  -> CIRAWFilter
       decoder selection and resource preparation
       Apple exposure, white balance, lens, denoise, detail, and tone behavior
  -> complete-image RGBA16F Metal texture
  -> canonical orientation and crop
  -> non-destructive Core Image adjustment graph
  -> layer placement and layer-stack composition
  -> explicit display or export color transform
  -> MTKView or ImageIO destination
```

`CIRAWFilter` is the sole authority for RAW geometry, crop, camera decoding,
demosaic, calibration, noise processing, lens correction, and foundational
tone behavior. Do not reconcile its output against LibRaw or another
decoder's dimensions.

Materialize the RAW result as one complete image before downstream viewport or
region rendering. Direct strip or partial-region evaluation of RAW output is
not permitted until a macOS 27 test corpus proves it safe. Pan and zoom operate
on cached textures and must not trigger a new RAW decode.

The render engine supports two qualities:

- interactive proxy: complete image at a reduced `scaleFactor`, with draft mode
  enabled;
- final display/export: complete image at scale 1, draft mode disabled, rendered
  into RGBA16F.

The canvas uses the final quality for every frame it shows, a slider drag
included: an adjustment is judged on the real pixels, so the window never
presents a draft that a sharper frame replaces a moment later. Continuous
gestures are throttled instead, and each render is discarded unless its revision
is still current. Proxy quality remains available for work that is explicitly
not the displayed image.

## Folder-browser preview contract

The folder browser is a discovery surface, not another RAW developer:

- For a camera RAW file, request only a preview already embedded in the file
  through ImageIO. Keep both full-image thumbnail synthesis options disabled.
  If there is no embedded preview, show an unavailable state; never fall back
  to `CIRAWFilter`, `CIImage(contentsOf:)`, or a full sensor-image decode.
- For a non-RAW image type supported by the installed ImageIO/Core Image stack,
  load it lazily with Core Image, apply its orientation metadata once, and
  render a bounded, explicitly color-managed browser thumbnail.
- Treat type identification conservatively. A source identified as camera RAW
  must never enter the generic Core Image URL-loading branch.
- Opening a RAW browser item hands the original URL to `ProjectDocument`; only
  that document path enters the full RAW rendering contract above.
- Keep browser tasks cancellable and cache entries bounded and keyed by source
  identity, modification date, size, and requested preview dimensions.

## Decoder and resource policy

For each imported RAW file:

1. Create `CIRAWFilter(imageURL:)`. A `nil` result means the installed macOS
   RAW system does not support the source.
2. Read `supportedDecoderVersions` and select by explicit identifier. Never
   rely on array order or the filter's implicit default.
3. Prefer `CIRAWDecoderVersion9` or `CIRAWDecoderVersion9DNG` when the matching
   identifier is supported.
4. Set the decoder version, prepare/download its macOS 27 resources through the
   public API, and expose progress and cancellation to the user.
5. After selecting the decoder, snapshot every public default and capability
   flag before applying user changes.
6. Persist the exact decoder identifier, public filter values, source identity,
   orientation policy, color-space policy, and OS version in the project.

For a new import, failure to obtain RAW9 resources may offer an explicit older
Apple decoder that the file supports. For an existing saved project, never
silently change decoder version; offer retry, an explicit downgrade, or a
read-only embedded preview.

Unsupported cameras must fail with a clear macOS RAW-support message. There is
no automatic or hidden non-Apple fallback.

Controls must be capability-driven. Hide or disable unsupported detail, color
noise reduction, moire, lens correction, local tone mapping, sharpening, or
other properties rather than applying guessed equivalents.

## Orientation, coordinates, and color

- The complete color architecture, terminology, source boundaries, display and
  export paths, precision analysis, and verification policy are documented in
  [Pixeltje color pipeline analysis](Documentation/Architecture/color-analysis.md). Keep that general
  contract separate from decoder-specific evidence reports.
- Establish one canonical image coordinate space and document it in code and
  tests. Core Image, AppKit, image metadata, and export coordinates must cross
  explicit adapters.
- Apply EXIF orientation exactly once. Cover orientations 1 through 8 in tests.
- Treat every source RAW as immutable and never write metadata or pixels back
  to it.
- Configure the Core Image working color space explicitly; never depend on a
  context default.
- Treat `CIRAWFilter.outputImage` as a lazy graph whose kernels execute in the
  rendering `CIContext`'s working color space. Materialize that graph with an
  Extended Linear sRGB working context, then request Extended Linear Display P3
  as the render destination color space. This is a real color conversion, not
  a profile reassignment. Never evaluate the RAW graph with an Extended Linear
  Display P3 working context: on RawCamera 9 it changes the kernel results and
  produces a cyan/green, heavily oversaturated image. After the first complete
  materialization, tag the `IOSurface` as Extended Linear Display P3 and use a
  separate Extended Linear Display P3 context for downstream edits and display.
  The evidence, experiments, forum references, and limits of this conclusion
  are recorded in the
  [RawCamera 9 working-color-space evidence report](Documentation/Architecture/raw9-color-analysis.md).
  This color boundary is maintainer-approved: before changing the RAW
  evaluation working space, materialization destination, surface tagging, or
  downstream P3 handoff for this issue, obtain the maintainer's explicit
  consent. A new OS result, Apple fix, or forum report may justify
  investigation and a proposed change, but does not by itself authorize
  changing the production pipeline.
- Keep RAW development, working color space, display color space, and export
  color space as distinct recorded decisions.
- Do not call Apple-developed pixels scene-linear unless that contract has been
  demonstrated. Use the term "linear working space" where appropriate.
- Embed the selected ICC profile in every encoded export.
- Never apply a second default exposure, tone curve, denoise, sharpening, or
  camera look after `CIRAWFilter`. Post-RAW adjustments represent explicit user
  edits only.

## Document format

Use a versioned native file-package format.

The package should contain:

- a versioned `project.json` recipe;
- a linked-source security-scoped bookmark for every RAW and placed image
  layer, never a copy of their pixels;
- a source fingerprint for each linked source, including byte length,
  modification date, and content hash;
- the exact decoder identifier, captured defaults, capabilities, and current
  RAW values for each developed RAW layer;
- crop, orientation, post-RAW adjustments, and export defaults;
- a color-managed preview and Finder thumbnail;
- masks and other independently authored assets when those features arrive.

Opening a RAW creates a new unsaved project. Save must never overwrite or
replace any source RAW. If a linked source changes, stop and ask the user to
relink, accept the changed source, or use an embedded preview.

Use `NSDocument` and native file coordination for autosave, safe writes,
revert, edited-state indication, and multi-window behavior.

## Implementation milestones

### Phase 0 — technical proof

Build a small Swift-only diagnostic target using public APIs. It must:

- initialize `CIRAWFilter` directly from a URL;
- enumerate capabilities and decoder identifiers;
- exercise macOS 27 resource preparation and cancellation;
- render complete proxy and full-resolution RGBA16F outputs;
- report source identity, decoder, every public value, dimensions, extent,
  orientation, working/output color spaces, timing, Metal device, and errors;
- export deterministic lossless references and exact 1:1 regions.

Exit when all eight unique X-T5 samples and representative Bayer/DNG samples
render at correct dimensions and orientation with no reordered columns,
mirroring, seams, or nondeterministic geometry in a signed sandboxed build.

### Phase 1 — native vertical slice

Create the Xcode application, `NSDocument` model, native document window,
SwiftUI inspector host, `MTKView` canvas, render actor, and proxy/full cache.

Exit when one RAW can be opened, shown quickly as a proxy, replaced atomically
by its full render, panned, zoomed, closed, and reopened without blocking the
main actor.

### Phase 2 — RAW development

Add typed RAW recipes, capability-driven controls, white-balance sampling,
reset-to-captured-defaults, histogram, clipping indicators, before/after, undo,
and cancellation/stale-result protection.

Exit when every visible RAW control maps directly to a supported public
`CIRAWFilter` property and all recipe changes are undoable and reproducible.

### Phase 3 — document persistence

Add the native project package, atomic saves, autosave, linked sources,
security-scoped bookmarks, source validation, relinking, preview generation,
schema migration, and reopen tests.

Exit when a project reopens with the same decoder and values and reproduces its
reference render within the recorded tolerance.

### Phase 4 — color-managed output

Add canonical crop/orientation, post-RAW Core Image adjustments, EDR display,
export recipes, ImageIO encoding, metadata policy, and ICC embedding.

Exit when JPEG, PNG, HEIF, and 16-bit TIFF exports have correct pixels,
dimensions, orientation, metadata policy, and color profile.

### Phase 5 — hardening and release

Add memory-pressure eviction, render prioritization, crash-safe recovery,
accessibility, localization readiness, UI automation, performance signposts,
signed sandbox testing, packaging, notarization, and release diagnostics.

Exit when the complete open-edit-undo-save-reopen-export path passes on the
maintained RAW corpus in release configuration.

### Phase 6 — compose and generate

Work through the basic requirements in order, then the continuation list.
Layer composition, masks and blend modes are implemented on Core Image and
the shared mask model. Painting, selection and diffusion each
get a short architecture and performance note before their first commit.

## Test strategy and acceptance gates

Maintain legal committed fixtures where possible and hash manifests for local
camera files that cannot be committed. Test at minimum:

- all eight unique Fujifilm X-T5 files used by the RAW9 color research;
- representative Sony or other Bayer RAW files;
- native RAW and DNG decoder identifiers;
- EXIF orientations 1 through 8;
- low and high ISO, lens correction on/off, supported/unsupported controls;
- absent resources, cancelled downloads, offline operation, and unsupported
  cameras;
- linked source relocation, mutation, and deletion;
- two simultaneous RAW layers with different sources and development values,
  including selection targeting, placement, and cache isolation;
- schema 12 migration and schema 13 round-trip without sibling RAW state being
  overwritten;
- the multiple-RAW setting defaults off, while existing multi-RAW projects
  remain usable when it is off;
- cold and warm render time, peak memory, cancellation latency, and rapid
  slider changes;
- wide-gamut, SDR, and EDR presentation and every export format.

Required gates:

- dependency audit finds no hidden RAW decoder, C export, dynamic loading,
  child-process launch, parent-directory reference, or symlink;
- standalone copied-directory build and test succeeds;
- only public Apple RAW APIs are used;
- complete-image RAW rendering has correct dimensions, orientation, and pixel
  order;
- proxy and final output use an identical recipe;
- stale results never replace current document state;
- every RAW layer's exact decoder and values survive save/reopen;
- no source RAW is ever modified;
- ordinary image placement cannot decode or admit a camera RAW, and additional
  RAW placement is exposed only by the explicit opt-in workflow;
- unsupported cameras fail clearly without hidden fallback;
- exports contain the requested dimensions, bit depth, metadata, and ICC
  profile;
- comparisons use documented pixel tolerances because OS, compiler, and GPU
  floating-point behavior need not be byte-identical.

## First implementation slice

The first end-to-end slice is:

```text
open one X-T5 RAF
  -> explicitly select and prepare RAW9
  -> render one complete RGBA16F image
  -> display it in MTKView
  -> change exposure and white balance
  -> undo and redo
  -> save a native project
  -> reopen the project
  -> export a color-managed 16-bit TIFF
```

This slice and its gates are complete. Product scope now governs what comes
next; the decoder and dependency rules still hold.

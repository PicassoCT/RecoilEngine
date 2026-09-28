# Runtime model windows

This opt-in, unsynced module adds windows to existing opaque unit, feature or
custom model surfaces without changing their meshes. Windows reference reusable
**miniature scenes** containing ordinary model assets. Create new scenes and add,
move, hide or remove model instances at runtime. Multiple attachments may share a
scene; changing that scene changes every view of it.

The backend renders real geometry through stencil apertures. It provides full
perspective parallax, multiple decks and interior self-occlusion. It is more
expensive than a cubemap or a flat interior-mapping shader. It creates no gameplay
objects, collisions, pathing or simulation state.

## Quick start

Include once in an unsynced gadget or widget. Paths below refer to assets supplied
by your game; the coordinates must match its host model.

```lua
local ModelWindows = VFS.Include("LuaModelWindows/ModelWindows.lua")
local windows = ModelWindows.New({maxGroups=64, maxModelDraws=512})

local bridge = windows:CreateScene({background={0.02,0.03,0.05}, ambient=0.65})
local room = windows:AddModel(bridge, "objects3d/bridge.s3o")
local crew = windows:AddModel(bridge, "objects3d/crew.s3o", {
    position={0,0,-8}, scale=0.5,
})

local hullWindows = windows:CreateSurface({
    position={0,12,24}, normal={0,0,1}, up={0,1,0},
    polygons={
        {{-12,-3},{-2,-3},{-2,3},{-12,3}},
        {{  2,-3},{12,-3},{12,3},{  2,3}},
    },
})
local attachment = windows:AttachUnit(unitID, "hull", hullWindows, bridge)

-- Later, in Update: every window referencing bridge sees the moving crew.
windows:UpdateModel(bridge, crew, {position={2,0,-8}, rotation={0,45,0}})
-- Models can be loaded for the first time after the game has started.
local console = windows:AddModel(bridge, "objects3d/console.s3o", {
    position={-3,0,-6},
})
windows:RemoveModel(bridge, console)

-- New miniature scenes do not require an engine restart or new UnitDefs.
local engineRoom = windows:CreateScene({ambient=0.4})
windows:AddModel(engineRoom, "objects3d/reactor.s3o", {position={0,0,-10}})
windows:SetScene(attachment, engineRoom)
```

A complete integration helper is in [examples/model_windows.lua](examples/model_windows.lua).
It animates an instance and builds a second miniature scene at runtime. Supply
your host coordinates and asset paths to its constructor.

## Draw and lifetime integration

Call `windows:Draw()` **once from `DrawWorldPostUnit`**, the new main-world draw
callin after opaque world objects and before alpha objects, particles and water.
`DrawWorld` is too late: drawing over it would erase already drawn transparency.
The engine's bundled gadget handler routes the new callin. Games with their own
widget/gadget handlers must add it to their callin lists and dispatch functions.
The callin is not run in reflection, refraction, shadow or minimap passes.

```lua
function gadget:DrawWorldPostUnit() windows:Draw() end
function gadget:UnitDestroyed(id) windows:RemoveObject("unit", id) end
function gadget:FeatureDestroyed(id) windows:RemoveObject("feature", id) end
function gadget:Shutdown() windows:Shutdown() end
```

Forward the object destruction events available in your handler (or forward them
from synced code via sync actions). This is required to prevent retained
attachments from following a reused object ID. Detach explicitly when replacing
a host. Disabling, detaching, deleting scenes and creating new ones is allowed
outside rendering; mutation or recursive drawing during a draw is rejected.

## Placement

A surface defines one plane in host model or piece-local coordinates. `normal`
points out of the hull. `up` is orthogonalized against it; their cross product
establishes local X. The transform is deterministic and does not use a random
seed, UVs, importer triangle ordering or engine-generated polygon IDs.

Use `width` and `height` for one rectangle, or `polygons` for a group of openings.
Each polygon is a strictly convex, counter-clockwise array of `{x,y}` points in
that plane. Split concave apertures into convex polygons. All polygons in a
surface share one scene origin and one rendering pass; adjacent windows show
continuous parts of the same room. Different decks can be placed at different Y
coordinates inside the scene. Openings on different hull planes need separate
surfaces, with scenes authored in each surface's coordinate frame.

Scene coordinates are relative to the surface origin. Interior geometry must be
behind the aperture (`z < -0.001`); geometry on or in front of the plane is clipped.
Model transformations apply translation, X/Y/Z Euler rotations in degrees, then
positive scale, using OpenGL's matrix multiplication order. Individual model
assets draw in their bind pose; animate whole instances through `UpdateModel`.
A scene has unlimited geometric depth, subject to the current camera far plane.

Attach the plane directly to an **existing opaque planar face** of the host.
The renderer replaces its pixels and restores depth at that plane. This is not
mesh Boolean cutting: the hull remains intact from other directions. Placing the
plane in empty space produces a floating window. Curved, transparent, changing
or partially built hull geometry needs application-specific placement/visibility.
Disable attachments when a host piece is hidden or destroyed; the module does
not infer per-piece visibility or construction progress.

`AttachUnit` and `AttachFeature` accept a piece name, a Lua piece index (one-based)
or `nil` for model-local coordinates. Piece transforms follow engine animation.
For a custom-drawn model, apply its model/piece transform and call
`windows:DrawSurface(surfaceID, sceneID)` in the same draw phase. This path applies
the surface transform and geometric culling but leaves host visibility, ordering
and draw budgeting to the caller.

## API

| Method | Result / behavior |
|---|---|
| `ModelWindows.New(options)` | Independent manager; GPU resources are created lazily. |
| `CreateScene({background, ambient, teamColor})` | Scene handle. Background is RGB, teamColor RGBA; opaque output. |
| `AddModel(scene, path, {position, rotation, scale, visible})` | Instance handle local to that scene. Scale is positive number or `{x,y,z}`. |
| `UpdateModel(scene, instance, transform)` | Partial transform/visibility update; omitted values are retained. |
| `RemoveModel(scene, instance)` | Removes that instance from every view of the scene. |
| `CreateSurface({position, normal, up, width, height, polygons})` | Reusable surface handle; input arrays are copied. |
| `AttachUnit(id, piece, surface, scene)` | Attachment handle. |
| `AttachFeature(id, piece, surface, scene)` | Attachment handle. |
| `SetScene(attachment, scene)` | Switches one attachment to a different shared scene. |
| `SetEnabled(attachment, bool)` | Toggle an attachment. |
| `Detach(attachment)` | Remove an attachment. |
| `RemoveObject("unit" or "feature", id)` | Remove all attachments belonging to an object. |
| `DeleteScene(scene)` / `DeleteSurface(surface)` | Delete the object and all attachments referencing it. |
| `Draw()` | Draw eligible attachments; returns number of groups submitted. |
| `DrawSurface(surface, scene)` | Draw under caller's model matrix; returns whether submitted. |
| `Shutdown()` | Free lists/shaders and manager state; safe to call twice. |

Handles are monotonically allocated and scoped to their manager. Scene/model
updates are visible on the next draw. No serialization or automatic synced
replication is supplied; replicate visual state through the game's Lua system.

Low-level engine additions are `Spring.PreloadModel(path)`, `gl.ModelShape(path)`
and `gl.ModelShapeTextures(path, push)`. They reuse the engine model cache without
requiring a UnitDef or FeatureDef. `ModelShape` draws raw bind-pose geometry under
the current matrix/shader. Pair texture-state push/pop calls; as with existing
`UnitShapeTextures`, the pop does not restore prior texture bindings.

## Performance and renderer contract

Defaults: `maxDistance=2000`, `minPixels=3`, `maxGroups=64`,
`maxModelDraws=512`, `stencilBit=128`. Limits apply per call to `Draw()`.
`minPixels` is a conservative estimate of the aperture group's bounding diameter.
Closest eligible groups receive the budgets first, with stable handle tie-breaking.
A group that would exceed the remaining model budget is skipped; farther cheaper
groups may still render. A model's pieces can each require additional GPU draws.

* Model vertex/index data and textures are shared by the engine. Scene instances
  hold transforms, not mesh copies. Assets remain cached until the game ends.
* Each path is preloaded once per manager. CPU parsing may run in the loader's
  worker pool; **first rendering can still wait or upload to the GPU**. Preload
  anticipated assets during loading and keep hot-added assets small.
* Geometry lists are cached per surface. Models are grouped by asset to reuse
  texture bindings; this backend is not GPU instancing or indirect rendering.
* Unit LOS, icon, cloak, no-draw and opaque flags are checked. Features use visible
  opaque draw flags. Apertures also use distance, frustum, backface and size tests.
* Foreground occlusion is resolved by depth/stencil tests. Fully occluded groups
  can still submit model draw calls; no synchronous occlusion readbacks are used.
* All openings in one surface render the scene once. There are no per-window
  FBOs or full-frame depth/stencil clears/copies. Repeated attachments still render
  separate views, even when sharing scene data. Detailed scenes need sensible LOD.

Reserve the configured stencil bit for this module; other bits are preserved.
The target must have an 8-bit stencil buffer. Do not nest it inside another active
stencil pass. After rendering, the reserved bit is zero within the aperture and
depth is restored to the aperture plane with a small polygon offset. This lets
subsequent world alpha geometry composite over the window without exposing
interior depth. It intentionally does not integrate interior depth with exterior
SSAO, depth-of-field or screen-space reflections.

The included material uses the engine's legacy diffuse/teamcolor and extra
emission/alpha-mask textures with simple lighting. Interior alpha blending,
skinned/per-piece animation, world shadows, PBR materials, recursive windows,
reflections/refractions and secondary cameras are not implemented. Use separate
instances for independently animated props. Maximum practical scene detail is
hardware/content dependent; no in-game performance benchmark is claimed.

## Validation and status

This feature branch was implemented with OpenAI Codex assistance, including its
C++, Lua, GLSL, documentation and tests. It has not been submitted upstream.

Run from the repository root:

```sh
lua test/validation/model_windows/test_registry.lua
# Or use Lupa's Lua 5.1 runtime when no lua executable is installed.
python test/validation/model_windows/test_render.py
```

The registry test validates input, deterministic transforms, asset sharing,
mutation, lifecycle, visibility and draw budgets. The render test needs `numpy`,
`PyOpenGL`, `lupa` and Mesa EGL. It runs the actual Lua renderer and GLSL using
synthetic model geometry, checking apertures, foreground occlusion, dynamic
instances, clipping, perspective parallax, zero-to-one depth, state/error cleanup
and exterior depth/stencil preservation.
It does not test the native asset loader or engine callin routing.

Development validation: both suites passed on Lua 5.1 / Mesa llvmpipe. Full engine
configuration was attempted but blocked by missing SDL2/DevIL development
packages; the native integration has not been built or exercised in a game here.
Before release, build the branch and verify the example against actual S3O/3DO/
Assimp assets, animated host pieces, disappearing objects, LOS transitions,
MSAA and the game's custom shader/render passes. Measure frame time with the
intended scene complexity and window counts.

# Native animations and visuals

RayWM 0.2 retains plugin API v1. These optional facilities extend
`wlr_scene`; the compositor owns all nodes and buffer locks. Lua sees
plugin registration IDs, never pointers. Load `animations` after your
workspace/layout plugins to enable the supplied transitions. It is off
by default. Configure its `duration`, `distance`, and `easing` options
through `raywm.configure("animations", {...})` before loading it.

## Animations

`ctx.animate(view, options)` returns a registration ID, or
`nil, "stale"/"hidden"/"failed"/"limit"`. Options:

| Field | Default | Meaning |
|---|---|---|
| `x`, `y` | 0 | Visual offset from the current layout position, clamped to ±65536 logical pixels. |
| `opacity` | 1 | Multiplier of the window's normal opacity, clamped to 0..1. |
| `from_x`, `from_y`, `from_opacity` | Current transform | Explicit starting values; a snapshot defaults to multiplier 1. |
| `duration` | 180 | Integer milliseconds, 0..10000. |
| `easing` | `"out_quad"` | `"linear"`, `"in_quad"`, `"out_quad"`, `"in_out_cubic"`. |
| `snapshot` | false | Copy the current client-buffer scene into an independently owned, input-transparent tree. |

Non-finite numbers raise Lua argument errors. Layout geometry and client
configure sizes do not change during these transforms. Input hit testing
uses the transformed surface's actual scene position. A new animation
of a view interrupts its previous animation from the current transform;
explicit `from_*` fields override that continuity. `ctx.cancel(id)` resets
a view to offset zero and opacity multiplier one. It destroys snapshots.

Native output frames advance monotonic time; Lua does not run per frame.
Map animations wait for the initial configure/reveal. Completed
animations ending at `(0,0,1)` retire automatically. Other final
transforms retain their registration until cancelled, replaced, unloaded
or the view unmaps. Snapshot animations always retire at completion.

`view_will_unmap(id)` runs before native view state is cleared, allowing
a close snapshot. `workspace_will_activate(new, old)` runs before
visibility changes; `workspace_activate(new, old)` runs afterward.
Snapshots can outlive their source view or a hidden workspace. They
contain client buffers, including subsurfaces, with their source crops,
transforms and opacity; they exclude borders and rectangle primitives.
They retain buffer locks, so use short durations. There are at most 256
animation slots and 256 buffers per snapshot, with a combined 128 MiB
budget estimated from buffer dimensions at four bytes per pixel. This
estimate is not a measurement of driver allocations. Allocation failures
return an error without retaining a partial tree. Session locking clears
all animations and snapshots.

## Rectangles

`ctx.rect(options)` returns a registration ID or
`nil, "stale"/"failed"/"limit"`. Options are `x=0`, `y=0`, `w=1`, `h=1`,
`color="#ffffff"`, `visible=true`, `view=0`, `background=false`.
Colors accept the same premultiplied `#RRGGBB[AA]` form as window borders.
Dimensions are clamped to 1..16777216; coordinates to ±16777216.

A nonzero `view` attaches the tree to that window, using window-relative
coordinates and following its visibility, stacking and visual position.
Without a view it belongs to the overlay layer, or background when
`background=true`. All rectangles ignore pointer input, and the lock
layer remains above them. The native table holds at most 256 rectangles.

`ctx.rect_update(registration, options)` changes geometry, color and
visibility. Supply the full desired options; omitted values use creation
defaults. The original parent remains fixed. Only the creating plugin
can update or cancel the registration. A stale/foreign ID returns
`nil, "stale"`. `ctx.cancel(id)` removes it. View unmap/destruction,
plugin error, unload and reload remove its owned nodes automatically.

```lua
return {
  api = 1,
  setup = function(ctx)
    local marker = assert(ctx.rect({x=12, y=12, w=8, h=8, color="#80c0ff"}))
    ctx.on("view_focus", function(id)
      assert(ctx.rect_update(marker, {
        x=12, y=12, w=8, h=8, color=id == 0 and "#666666" or "#80c0ff",
      }))
    end)
  end,
}
```

This API supplies solid rectangles and existing border/opacity controls.
Blur, rounded clipping, shadows, text, images and custom shader effects
are **NOT IMPLEMENTED**. No renderer rewrite or simulated effect support
is implied by this API.

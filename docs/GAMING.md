# Gaming on RayWM

This page explains how RayWM presents games, what v0.2.1 changed, what is
and is not supported, and how to report a performance problem. It describes
the code as shipped; physical-hardware results are tracked separately in
[GAMING-TESTING.md](GAMING-TESTING.md) and the v0.2.1 release report.

## FPS, refresh rate and latency are different numbers

A game's FPS counter measures how often the game finishes rendering a frame.
Your monitor shows at most its refresh rate (144 frames per second on a
144 Hz panel). With vsync off, a game may render 1000 frames per second, but
on a 144 Hz monitor at most 144 of them are shown, whole or in parts (tearing).
What is worth comparing between desktops:

- the game's own FPS, with the **same** limiter, vsync and fullscreen mode;
- frame-time consistency (stutter), not just the average;
- the monitor mode RayWM actually uses (`raywmctl perf` → `refresh_mhz`);
- how the frames reach the screen (`path`: `scanout` or `composited`).

A compositor that shows 144 frames per second on a 144 Hz monitor is working
as intended even if the game counter said 1000 elsewhere.

## How a frame reaches the screen

1. The game renders into a buffer and commits it to its Wayland surface
   (Xwayland does this on behalf of X11 games).
2. RayWM's scene (wlroots `wlr_scene`) records the damage. Nothing renders
   per client commit; RayWM does no per-commit Lua work.
3. When the output can show a new frame, wlroots emits `frame`. RayWM builds
   the output state with `wlr_scene_output_build_state` and commits it.
   - **Direct scanout:** if exactly one buffer covers what the output shows
     (a fullscreen game with nothing above it), wlroots tries to give the
     game's buffer to the display hardware without copying it.
   - **Composition:** otherwise the GPU draws all visible surfaces into an
     output buffer. Only damaged areas are redrawn.
4. Clients that asked for a frame callback get it after the commit, and
   presentation-time feedback reports when (and whether) a frame was shown.

An unchanged desktop renders nothing: wlroots only emits `frame` when
something changed or a frame was explicitly scheduled.

## Fullscreen and direct scanout

RayWM does not force or fake scanout; the wlroots scene decides per frame.
In RayWM's fullscreen layout:

- the fullscreen window is stacked above panels (`top` layer) and normal
  windows; only `overlay`-layer surfaces, popups, X11 override-redirect
  windows, drag icons and the lock screen are above it;
- the black backdrop behind a fullscreen window is skipped by wlroots and
  does **not** prevent scanout;
- focus borders are disabled while a window is fullscreen;
- the shipped `animations` plugin does not animate fullscreen windows when
  they map.

Things that legitimately prevent scanout (RayWM composes instead):

- anything visible above the game on that output: an overlay-layer
  notification or OSD, a popup, a software cursor, a drag icon;
- window opacity below 1 (a window rule `opacity`, or an animation running);
- output scaling/transform that the game's buffer does not match, or a
  buffer format/modifier the display plane cannot use;
- a gamma ramp (gammastep, wlsunset) on drivers that cannot apply it with
  scanout;
- nested/headless backends (`scanout_possible: false`).

`raywmctl perf` shows the last path per output and how many commits used
each. RayWM reports `scanout` only when the committed buffer is not one of
the output's own render buffers; it never infers it from "a fullscreen
window exists". The exact reason a candidate was rejected is not exposed by
wlroots, so RayWM does not guess one.

## Explicit synchronization

From v0.2.1 RayWM advertises `linux-drm-syncobj-v1` when, and only when,
both the renderer and the backend support DRM syncobj timelines (the
condition wlroots documents). The wlroots scene then waits on each surface's
acquire fence and signals its release fence. Clients without explicit sync
keep using implicit synchronization. This matters most for NVIDIA's
proprietary driver and for Xwayland 24.1 or later, which use explicit sync
when the compositor offers it.

Check with `raywmctl perf`: `explicit_sync`, `renderer_timeline`,
`backend_timeline`. If a driver misbehaves, start RayWM with
`RAYWM_EXPLICIT_SYNC=0` to turn it off.

## Tearing (async page flips)

Off by default. To allow it on a monitor:

```lua
-- ~/.config/raywm/plugins/outputs.lua
local outputs = {
  { name = "DP-1", mode = "1920x1080@144", allow_tearing = true },
}
```

Then a frame is flipped without waiting for vblank only when **all** hold:

- that output has `allow_tearing = true`;
- a fullscreen window is visible on it and its surface asked for async
  presentation through `wp_tearing_control_v1` (games and Xwayland do this
  when vsync is off);
- the session is not locked;
- the backend accepts the async flip for that commit (it is tested first;
  if refused, RayWM falls back to a normal synchronized flip and counts
  `tearing_rejected`).

Tearing lowers latency at the cost of visible tear lines. RayWM never
enables it globally.

## Adaptive sync (VRR / FreeSync / G-SYNC Compatible)

Set `adaptive_sync = true` for an output in `outputs.lua`, or use
`wlr-randr --output DP-1 --adaptive-sync enabled`. The setting is tested
before it is applied and refused if the monitor/driver does not support it;
`raywmctl perf` shows `adaptive_sync` as `enabled` or `disabled`. RayWM does
not enable VRR automatically
and does not change monitor settings permanently.

## Refresh rate

New monitors start in the mode their EDID marks as preferred. Some 144 Hz
monitors prefer 60 Hz. RayWM logs a line such as
`output DP-1: running 1920x1080 at 60.000 Hz; the monitor also offers 144.001 Hz`
and `raywmctl perf` shows `refresh_mhz` and `max_refresh_mhz_at_size`. Set
the mode in `outputs.lua` (`mode = "1920x1080@144"`) or for one session with
`RAYWM_OUTPUT_MODE=1920x1080@144`.

## Xwayland games

X11 games (Wine/Proton, many native games) run through Xwayland, started
lazily on first use. v0.2.1 fixes X11 windows that are already fullscreen
or maximized when they first map (what SDL and Wine do): they are now
configured to the output (or usable area) and their state is confirmed;
leaving that state restores the window's own size. Earlier versions left
them at their initial size (centred on black) and could shrink them to
1×1 when leaving fullscreen.

Pointer locking/confinement and relative motion are supported for both
Wayland and X11 clients (Xwayland uses the same protocols). Ctrl+Alt+Escape
releases a pointer capture.

## Multi-GPU and hybrid laptops

wlroots renders with the GPU it picks at startup (normally the one driving
the built-in panel), shown as `render_node` in `raywmctl perf`. On a
laptop with an integrated and a discrete GPU, games run on the integrated
GPU unless asked otherwise (`prime-run`, `DRI_PRIME=1`, Steam launch options,
or your distribution's switcheroo tool). Compare games on the same GPU when
comparing desktops. Outputs on a second GPU are handled by wlroots'
multi-GPU path (a copy between GPUs), which costs some performance compared
with a monitor attached to the rendering GPU. RayWM has no vendor-specific
workarounds and sets no driver environment variables.

## Things that were slow before v0.2.1

- Every surface commit made RayWM republish every window's title and
  app id to `wlr-foreign-toplevel` clients (Waybar's `wlr/taskbar`, docks),
  because wlroots sends those two events unconditionally. A game rendering
  1000 frames per second could make a taskbar process hundreds of thousands
  of events per second and compete with the game for CPU. Fixed: RayWM now
  publishes only real changes.

## Performance diagnostics

```sh
raywmctl perf
```

prints renderer, render node, capability status and, per output: mode,
highest refresh at that size, adaptive sync and tearing settings, presentation
path, frame/commit/scanout/composited/tearing/failure counters, presented and
discarded frames, and p50/p99/max of frame work and present intervals over
the last 256 frames. Counters are fixed-size and updated once per output
frame, never per client commit. Nothing is sent anywhere; the output does
not contain window titles or other client data. The values are counters since
startup: take one snapshot before and one after a test and compare.

## Reporting a gaming problem

Please include:

1. RayWM version (release archive name, or `git rev-parse HEAD` for a
   source build), distribution, kernel (`uname -r`).
2. GPU(s) and driver version (`nvidia-smi` or `glxinfo -B`), hybrid or not,
   and which GPU the game runs on.
3. Monitor mode and refresh rate, `raywmctl perf` taken while the game runs.
4. The game, its version, native/Wine/Proton, Wayland or X11, renderer
   (OpenGL/Vulkan/DirectX via DXVK).
5. In-game FPS limiter, vsync, and fullscreen/borderless/windowed mode.
6. What you compared against (desktop, version) with the same settings.
7. Whether panels (Waybar) and the `animations` plugin were running.

[GAMING-TESTING.md](GAMING-TESTING.md) has a step-by-step procedure.

## Known limitations

- No physical DRM/KMS, NVIDIA, Intel, multi-monitor or VRR validation was
  possible for v0.2.1; see the release report.
- Direct-scanout rejection reasons are not reported (wlroots does not
  expose them).
- Animations advance on every output's frame and keep all outputs
  committing while any animation runs (normally under 200 ms).
- No gaming-specific "game mode"; use window rules (`opacity`, floating) and
  the optional plugins to keep fullscreen games undecorated.
- wlroots 0.20's XWM learns an X11 window's pre-map `_NET_WM_STATE` only if
  it subscribed to the window's property changes before the client set it;
  otherwise wlroots overwrites the state when the window maps and the window
  starts as a normal window (RayWM never sees the request). Games that also
  request fullscreen after mapping (most SDL/Wine paths) are unaffected.
- Frame scheduling is wlroots' default (render at the frame event); there is
  no configurable render delay ("max render time") in this release.

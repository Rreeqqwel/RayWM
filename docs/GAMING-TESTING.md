# Gaming hardware testing

Automated tests run headless and cannot show how a physical GPU, driver
and monitor behave. This is the manual procedure for that, and the short
version for testers reporting a problem. Record results as PASS, FAIL or
SKIPPED with the exact configuration; never copy a result between
configurations.

Before starting, read [HARDWARE-TESTING.md](HARDWARE-TESTING.md) (session
setup, recovery from a black screen) and keep another TTY available.

## Quick procedure for a tester (about 20 minutes)

You do not need to disable any security feature or patch RayWM.

### 1. Describe the system

```sh
uname -r
cat /etc/os-release | head -3
lspci -k | grep -EA3 'VGA|3D|Display'
nvidia-smi --query-gpu=name,driver_version --format=csv 2>/dev/null
glxinfo -B 2>/dev/null | grep -E 'renderer|version'   # run inside RayWM
```

Note: hybrid graphics (integrated + discrete) or not; which outputs are
connected to which GPU; the desktop you compare against and its version.

### 2. Describe the game setup

- Game and version (for osu!: stable or lazer; build/date).
- Native, Wine or Proton (version); Wayland or X11 (for SDL games,
  `SDL_VIDEODRIVER`); renderer (OpenGL, Vulkan, DirectX via DXVK).
- Which GPU it runs on (`prime-run`, `DRI_PRIME=1`, Steam launch options).
- Frame limiter and vsync settings, fullscreen / borderless / windowed.

Keep these identical on both desktops.

### 3. Measure in RayWM

Start the game, get to a repeatable scene (for osu!: the same map, at the
same point, or the main menu), then in a terminal:

```sh
raywmctl perf > perf-before.json
# play/observe for 60 seconds
raywmctl perf > perf-after.json
```

Write down the in-game FPS and, if the game shows it, frame time. If you
use MangoHud, log frame times to a file (`MANGOHUD_CONFIG=output_folder=...`)
— this is optional.

Repeat with each change below, one at a time, then undo it:

| Run | Change | How |
|---|---|---|
| A | none | your normal setup |
| B | no panel | close Waybar (or your panel) |
| C | no animations | if your `init.lua` loads `animations`, comment it out and restart RayWM |
| D | fullscreen vs borderless | switch the game's display mode |
| E | refresh rate | check `refresh_mhz` in `perf-after.json`; if lower than your monitor, set `mode` in `outputs.lua` and repeat A |
| F | explicit sync off | restart RayWM with `RAYWM_EXPLICIT_SYNC=0` |
| G | tearing (optional) | `allow_tearing = true` for the monitor in `outputs.lua`, vsync off in the game |

### 4. Measure in the other desktop

Same game, settings, scene and GPU. Write down FPS (and frame time).

### 5. Send

- The answers from steps 1–2.
- A table: run, desktop, FPS, frame time (if available).
- `perf-before.json`, `perf-after.json` for runs A and the best/worst run.
- RayWM's output (wherever your session start script writes it) if
  anything looked wrong.

### Rolling back

v0.2.1 keeps your configuration. To go back to v0.2.0, reinstall the
v0.2.0 archive with its `install.sh` (existing configurations are kept;
see INSTALL.md). Settings added for tests (`allow_tearing`, a `mode`) can
simply be removed from `outputs.lua`. `RAYWM_EXPLICIT_SYNC=0` turns off the
only new protocol that changes buffer synchronization.

## Full manual matrix (maintainers)

For each configuration actually available, record GPU, driver, kernel,
monitor(s) and mode(s). Mark unavailable ones SKIPPED.

| Configuration | Status |
|---|---|
| AMD + Mesa, single monitor | |
| AMD + Mesa, two monitors, mixed refresh (e.g. 144 + 60 Hz) | |
| Intel integrated | |
| NVIDIA proprietary (≥ 555 for explicit sync), single GPU | |
| NVIDIA hybrid / PRIME laptop (internal panel on iGPU) | |
| NVIDIA hybrid with an external monitor on the dGPU | |

Per configuration:

1. `raywmctl perf`: renderer, `render_node`, `explicit_sync`, outputs and
   modes are what you expect; `refresh_mhz` equals the monitor's maximum.
2. Native Wayland game or demo (`vkcube`, `eglgears_wayland` with
   `vblank_mode=0`), fullscreen, nothing above it: `path` is `scanout` and
   `scanout_commits` grows. Then open a notification or move the software
   cursor over it (if the driver uses a software cursor): `path` becomes
   `composited`, and returns to `scanout` afterwards.
3. Same with an X11 game through Xwayland (`glxgears -fullscreen`,
   a Wine/Proton game).
4. Fullscreen enter/exit 20 times with F11 / the game's setting: the window
   returns to its previous size; no stuck black backdrop; `failed` stays 0.
5. Lock the session (`swaylock`) during fullscreen: only the lock screen is
   visible and receives input; unlocking returns to the game.
6. Unplug a monitor while a game runs on another, and while a game runs on
   the unplugged one: no crash; the game moves to a remaining output.
7. `adaptive_sync = true`: if supported, `adaptive_sync: enabled`; the
   monitor OSD shows VRR active in a fullscreen game below max refresh.
8. `allow_tearing = true` with a game with vsync off: `tearing_commits`
   grows (or `tearing_rejected` if the driver cannot); with vsync on or
   windowed it does not.
9. Pointer lock: a first-person game or `osu!` with raw input keeps the
   pointer locked and moves smoothly; Ctrl+Alt+Escape releases it.
10. One hour of play: compositor RSS (`ps -o rss= -C raywm`) stable within
    a few MiB; `failed` 0; no growing `discarded` for a vsync game.
11. Input-to-photon latency: only with a measuring setup (high-speed camera
    or a photodiode tool). Otherwise SKIPPED; do not substitute FPS.

Results go in the release report under "Hardware tests performed"; anything
not done is listed under "Hardware tests skipped".

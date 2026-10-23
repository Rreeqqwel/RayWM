# RayWM

A lightweight Wayland compositor written in Zig on top of wlroots, with
its window-management policy written in Lua.

**Philosophy:** a minimal core and maximum extensibility, with
correctness ahead of artificial code reduction.
- The native core does what must be correct and fast: Wayland protocols,
  input, outputs, rendering and resource lifetimes.
- Everything that is policy is a Lua plugin: tiling, key bindings and
  window rules.

> **Status: v0.2.0 development, experimental.** The continuation preserves
> the v0.1.2 core and adds native window state, workspaces, configuration
> and protocol support. Remaining work and validation are recorded in
> [the development ledger](docs/DEVELOPMENT.md). This checkout is not a
> published v0.2.0 release. Headless tests do not establish physical
> hardware compatibility.

## Features

- **Wayland compositor on wlroots 0.20.**
  - xdg-shell windows and popups, with correct configure/ack handling.
  - Keyboard and pointer, click-to-focus, and the Wayland **implicit
    pointer grab**: a drag keeps going to the window where it started
    (also across outputs) until the last button is released.
  - Key bindings that work in every layout of the keymap (e.g. `us,ru`).
  - Multiple outputs with hotplug.
  - VT switching on a real session.
- **Layer-shell** (wlr-layer-shell v5) for external panels, docks,
  launchers and wallpapers: exclusive zones, keyboard interactivity,
  popups.
- **Native window state:** floating, fullscreen, maximize, minimize and
  urgency, with configure/ack handling, dialog stacking and focus rules.
- **Workspaces:** one shown per output, native visibility/focus and hotplug
  recovery; Lua controls naming, switching, assignment and tiling.
- **Window rules:** application/title/parent/output/workspace matching,
  floating dialog defaults, geometry, opacity and decoration choices.
- **Session lock and idle:** ext-session-lock with abandoned-lock handling,
  idle notifications/inhibition, and optional swaylock/swayidle autostart.
- **Output/input configuration:** mode, scale, transform, position,
  adaptive sync, DPMS and gamma; keyboard layouts/repeat and libinput
  settings by device or type. Hardware-dependent settings need physical
  testing.
- **Wayland protocols:** data control and primary selection, scaling,
  viewporter/single-pixel buffers, presentation, cursor shape,
  decorations, activation and security-context filtering. See
  [SECURITY.md](SECURITY.md) for the unrestricted-client trust boundary.
- **Interactive move/resize** for floating windows (Super + drag, or the
  client's own title bar).
- **Lua 5.4 plugin system (API v1).**
  - One clear loading contract.
  - Per-plugin ownership of every handler, binding and timer.
  - A failing plugin is unloaded without affecting the others.
  - Memory and instruction limits.
  - Integer ids instead of pointers.
  - Live reload.
- **Dwindle tiling** (Hyprland-style), written entirely in Lua.
  - Per-workspace binary trees, focus-based splits, inner/outer gaps,
    split resizing, swapping and split-direction toggling.
  - Respects panels, and keeps its layout across reloads.
  - Tiled windows are protected from accidental dragging through
    `ctx.manage`.
- **Keyboard focus navigation** (`config/plugins/focus.lua`, Lua):
  directional focus (Super+H/J/K/L) by window geometry across outputs,
  a focus cycle (Super+Tab), an optional pointer warp, and a border
  around the focused window.
- **Screenshots** (`config/plugins/screenshot.lua`, a plain Lua plugin):
  full screen, interactive region, clipboard copy, PNG files with unique
  names, notifications. The capturing is done by grim, slurp and
  wl-clipboard; the core only provides the standard wlr-screencopy and
  xdg-output protocols. See [Screenshots](#screenshots).
- **Robust defaults.** Fallback bindings when the configuration is
  missing or broken, and clean shutdown.

## Supported platforms

- Linux, **x86_64**. The release binary is built on Arch Linux and
  dynamically linked.
- Needs **wlroots 0.20.x**, **Lua 5.4**, wayland-server, xkbcommon and
  **glibc ≥ 2.36** at runtime, with the sonames listed in
  [docs/INSTALL.md](docs/INSTALL.md).
- On other distributions, build from source. Only Arch Linux was
  tested.

## Build

```sh
# Arch Linux build dependencies
sudo pacman -S --needed git wlroots0.20 wayland wayland-protocols libxkbcommon pixman lua54 pkgconf
# Zig 0.16.0 exactly (see docs/INSTALL.md for the checksum-verified download)
zig build -Doptimize=ReleaseSafe      # -> zig-out/bin/raywm
```

| Component | Version |
|---|---|
| Zig | 0.16.0 |
| wlroots (system) | 0.20.x |
| zig-wlroots / zig-wayland / zig-xkbcommon / zig-pixman | 0.20.1 / 0.6.0 / 0.3.0 / 0.3.0 (hashes in `build.zig.zon`) |
| Lua (system) | 5.4 |

## Install

From a release archive (after checking `sha256sum -c SHA256SUMS`):

```sh
tar -xzf raywm-v0.1.2-linux-x86_64.tar.gz && cd raywm-v0.1.2
./install.sh        # ~/.local/bin/raywm; config copied only if ~/.config/raywm does not exist
```

`install.sh` needs no root. It does not replace your current window
manager, and it never overwrites an existing binary (without `--force`)
or configuration. Full guide: [docs/INSTALL.md](docs/INSTALL.md).

### Upgrading from v0.1.1

Replace the binary (`./install.sh --force`, which keeps a backup). Your
`~/.config/raywm` is not touched and keeps working as before. To get the
new focus keys and the focus border, copy `config/plugins/focus.lua` and
`config/plugins/dwindle.lua` into `~/.config/raywm/plugins/`, add
`raywm.load("focus")` to `init.lua`, and press Ctrl+Alt+R. Step by step:
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#upgrading-from-v011).

## Run

**Nested**, inside an existing Wayland session (the safest way to try it):

```sh
raywm -s foot
```

**From a TTY:** log in on a free VT (e.g. Ctrl+Alt+F3) and run
`raywm -s foot`. Seat access comes from systemd-logind or seatd. Quit
with Super+Shift+E. TTY use is not covered by the automated tests.

Options:
- `-c FILE`: use another config file;
- `-s CMD`: startup command, e.g. `-s 'waybar & foot'`;
- `-d`: verbose log: wlroots, plus each key press with Super, Ctrl or
  Alt and the binding it matched (plain typing is never logged);
- `-h`: help.

The keyboard layout comes from `XKB_DEFAULT_LAYOUT`, `XKB_DEFAULT_OPTIONS`
and the other xkb variables, e.g.
`XKB_DEFAULT_LAYOUT=us,ru XKB_DEFAULT_OPTIONS=grp:alt_shift_toggle`.

## Default key bindings

With the example configuration (`config/`):

| Keys | Action |
|---|---|
| Super+Return | terminal (`$TERMINAL`, default `foot`) |
| Super+Q | close the focused window |
| Super+Shift+Space | toggle floating |
| Super+F / Super+M | toggle fullscreen / maximize |
| Super+N / Super+Shift+N | minimize / restore the latest minimized visible-workspace window |
| Super+1..9 / Super+Shift+1..9 | switch workspace / move focused window |
| Super+Ctrl+H/J/K/L | resize the neighboring dwindle split |
| Super+Shift+H/J/K/L | swap with the neighboring tile |
| Super+T | toggle split direction |
| Ctrl+Alt+Escape | release pointer capture and shortcut inhibition |
| Super+H / J / K / L | focus the window to the left / below / above / right |
| Super+Tab / Super+Shift+Tab | focus the next / previous window |
| Ctrl+Alt+R (or Super+Shift+R) | reload the configuration |
| Super+Shift+E | quit |
| Print / Shift+Print | save a screenshot of all outputs / of a selected region |
| Ctrl+Print / Ctrl+Shift+Print | copy a screenshot / a region to the clipboard |
| Ctrl+Alt+P | save a screenshot (for nested sessions, where the outer compositor may keep Print) |
| Super + left / right drag | move / resize a floating window |
| Ctrl+Alt+F1..F12 | switch VT (TTY sessions) |

Without a configuration, or when no plugin binds keys, the core keeps
three **fallback bindings**: Super+Return, Super+Shift+R and
Super+Shift+E.

## Dwindle tiling

`config/plugins/dwindle.lua` gives each workspace (or output without
workspaces) a binary tree:
- a new window splits the focused window's area along its longer side
  and takes focus, so windows spiral inwards;
- closing a window gives its area to its sibling;
- the tree is edited in place, and only geometry is recomputed when
  windows, outputs or panels change;
- gaps default to 8 px;
- the tree shape survives `raywm.reload()`.

Details and options: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Screenshots

These are real screenshots of RayWM, taken with grim through RayWM's
wlr-screencopy support in an isolated headless session
(`scripts/gallery.sh` regenerates them). The clients are foot and
fuzzel; the layout is the shipped dwindle plugin.

| Dwindle tiling (three foot windows) | Layer-shell launcher (fuzzel) over the tiles |
|---|---|
| ![Dwindle tiling](docs/screenshots/tiling.png) | ![fuzzel launcher](docs/screenshots/launcher.png) |

A region capture (`grim -g`, as Shift+Print saves it):

![Region](docs/screenshots/region.png)

### Taking screenshots

The example configuration loads `screenshot.lua`. It needs these
programs, which are **not** needed by RayWM itself:

| Program | Arch Linux package | Used for | If missing |
|---|---|---|---|
| `grim` | `grim` | capturing | every action fails with a logged error and, if possible, a notification |
| `slurp` | `slurp` | selecting a region | region actions fail the same way |
| `wl-copy` | `wl-clipboard` | the clipboard | copy actions fail the same way |
| `notify-send` | `libnotify` | notifications | silently skipped |

Files go to `$XDG_PICTURES_DIR/Screenshots` (when that variable holds an
absolute path) or `~/Pictures/Screenshots`, named
`screenshot-YYYY-MM-DD_HH-MM-SS.png`; an existing file is never
overwritten. Escape cancels a selection without saving anything.
Options: [docs/CONFIGURATION.md](docs/CONFIGURATION.md#screenshots-pluginsscreenshotlua).

**Privacy:** unrestricted clients can capture outputs and use data-control
clipboard access whether or not the screenshot plugin is loaded.
Clients labeled through a security-context listener are denied those
privileged globals. The launcher must also isolate the unrestricted
socket. See [SECURITY.md](SECURITY.md).

## Lua plugins

```lua
-- ~/.config/raywm/init.lua
raywm.load("dwindle")
raywm.load("binds")
raywm.load("focus")
raywm.load("screenshot")
```

```lua
-- ~/.config/raywm/plugins/hello.lua
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function(id)
      local v = raywm.view(id)
      if v then raywm.log("new window: " .. v.app_id) end
    end)
    ctx.bind("Super+d", function() raywm.spawn("fuzzel") end)
  end,
}
```

Plugins are **trusted code**. They are not sandboxed, and get the full
Lua standard library. See [SECURITY.md](SECURITY.md). API reference:
[docs/API.md](docs/API.md). Design: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Known limitations

- Xwayland, cross-client drag-and-drop, text input/IME, animation/visual
  APIs and external IPC remain tracked milestones in
  [DEVELOPMENT.md](docs/DEVELOPMENT.md). Do not infer support from a
  preparatory type or protocol XML.
- Touch and tablet input are not implemented.
- Blur, shadows and rounded corners require rendering work beyond the
  existing scene primitives; they are not implemented.
- Privileged protocols are available to unrestricted clients without
  permission prompts. Plugins are trusted user code. See
  [SECURITY.md](SECURITY.md).
- A broken binding plugin can leave only other plugins' bindings active;
  fallback keys apply when no live plugin has bindings.
- Distribution binaries are dynamically linked; matching sonames are
  required. Build from source on other distributions.
- DRM/KMS, GPU rendering, physical input and monitor hotplug require the
  [manual hardware checks](docs/HARDWARE-TESTING.md). Current automated
  validation is isolated headless pixman.

## Testing

All tests are headless and isolated from your session. The input tests
use test-only virtual input inside a private compositor.

```sh
zig build test                      # Zig unit tests (core + Lua host), dwindle, focus and screenshot plugin tests
tests/smoke.sh && tests/focus.sh && tests/docs.sh
zig build -Dtest-input -p zig-out/test-input
tests/input.sh && tests/stress.sh   # real pointer/keyboard events, stress
tests/pointer.sh                    # implicit pointer grab: exact wl_pointer event streams
tests/navigation.sh                 # focus keys, layouts (us/ru), two outputs, warp, border
tests/screenshot.sh                 # real grim/slurp/wl-clipboard, PNGs checked pixel by pixel
```

See [docs/TESTING.md](docs/TESTING.md) for every suite, CI, and the
known coverage gaps. CI runs on GitHub Actions in an Arch Linux
container (`.github/workflows/ci.yml`).

## Project layout

```
src/            Zig core
  main.zig        startup, signals, config path
  server.zig      backend, scene, outputs, focus, spawn
  view.zig        xdg-shell toplevels/popups, configure/ack geometry
  input.zig       keyboard, bindings, pointer focus and grabs, move/resize
  layer.zig       wlr-layer-shell
  lua.zig         Lua 5.4 host: plugins, isolation, limits
  host.zig        compositor functions exposed to Lua (id-based)
config/         example ~/.config/raywm (layout, state, workspaces, rules, devices, autostart)
docs/           INSTALL, CONFIGURATION, API, ARCHITECTURE, TESTING, screenshots/
tests/          unit, integration, input, pointer, navigation, screenshot and stress tests
scripts/        package.sh (release archive), install.sh, gallery.sh
```

## Contributing

Issues and pull requests are welcome.
- Keep the core minimal and put policy in plugins.
- Add a test with every fix; reverting the fix should make that test fail.
- Before sending changes, run the CI commands from docs/TESTING.md.
- Use Conventional Commits (`fix(core): ...`, `feat(lua): ...`).

## License and credits

RayWM is licensed under the **GNU GPL v3** (see `LICENSE`).

- The core started from `tinywl` in zig-wlroots (© Isaac Freund,
  permissive license).
- Uses [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) and
  [Lua](https://www.lua.org).
- `protocol/wlr-layer-shell-unstable-v1.xml` is © Drew DeVault.
- Screenshots are taken by [grim](https://gitlab.freedesktop.org/emersion/grim),
  [slurp](https://github.com/emersion/slurp) and
  [wl-clipboard](https://github.com/bugaevc/wl-clipboard), which are
  separate programs.
- The test-only protocol files in `tests/protocol/` keep their upstream
  licenses (inside each file).

# RayWM

A lightweight Wayland compositor written in Zig on top of wlroots, with
its window-management policy written in Lua.

**Philosophy:** a minimal core and maximum extensibility, with
correctness ahead of artificial code reduction.
- The native core does what must be correct and fast: Wayland protocols,
  input, outputs, rendering and resource lifetimes.
- Everything that is policy is a Lua plugin: tiling, key bindings and
  window rules.

> **Status: v0.1.0, first experimental release.** It is usable for
> trying out and for development, nested in another session or from a
> TTY. Expect missing features (see [Known limitations](#known-limitations))
> and an evolving plugin API.

## Features

- **Wayland compositor on wlroots 0.20.**
  - xdg-shell windows and popups, with correct configure/ack handling.
  - Keyboard and pointer, click-to-focus.
  - Multiple outputs with hotplug.
  - VT switching on a real session.
- **Layer-shell** (wlr-layer-shell v4) for external panels, docks,
  launchers and wallpapers: exclusive zones, keyboard interactivity,
  popups.
- **Floating windows** with interactive move/resize (Super + drag, or
  the client's own title bar).
- **Lua 5.4 plugin system (API v1).**
  - One clear loading contract.
  - Per-plugin ownership of every handler, binding and timer.
  - A failing plugin is unloaded without affecting the others.
  - Memory and instruction limits.
  - Integer ids instead of pointers.
  - Live reload.
- **Dwindle tiling** (Hyprland-style), written entirely in Lua.
  - Per-output binary trees, focus-based splits and gaps.
  - Respects panels, and keeps its layout across reloads.
  - Tiled windows are protected from accidental dragging through
    `ctx.manage`.
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
tar -xzf raywm-v0.1.0-linux-x86_64.tar.gz && cd raywm-v0.1.0
./install.sh        # ~/.local/bin/raywm; config copied only if ~/.config/raywm does not exist
```

`install.sh` needs no root. It does not replace your current window
manager, and it never overwrites an existing binary (without `--force`)
or configuration. Full guide: [docs/INSTALL.md](docs/INSTALL.md).

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
- `-d`: verbose wlroots log;
- `-h`: help.

The keyboard layout comes from `XKB_DEFAULT_LAYOUT`, `XKB_DEFAULT_OPTIONS`
and the other xkb variables.

## Default key bindings

With the example configuration (`config/`):

| Keys | Action |
|---|---|
| Super+Return | terminal (`$TERMINAL`, default `foot`) |
| Super+Q | close the focused window |
| Super+J / Super+K | focus next / previous window |
| Ctrl+Alt+R (or Super+Shift+R) | reload the configuration |
| Super+Shift+E | quit |
| Super + left / right drag | move / resize a floating window |
| Ctrl+Alt+F1..F12 | switch VT (TTY sessions) |

Without a configuration, or when no plugin binds keys, the core keeps
three **fallback bindings**: Super+Return, Super+Shift+R and
Super+Shift+E.

## Dwindle tiling

`config/plugins/dwindle.lua` gives each output a binary tree:
- a new window splits the focused window's area along its longer side
  and takes focus, so windows spiral inwards;
- closing a window gives its area to its sibling;
- the tree is edited in place, and only geometry is recomputed when
  windows, outputs or panels change;
- gaps default to 8 px;
- the tree shape survives `raywm.reload()`.

Details and options: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Lua plugins

```lua
-- ~/.config/raywm/init.lua
raywm.load("dwindle")
raywm.load("binds")
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

- **No** Xwayland, workspaces, fullscreen or maximize (the requests are
  answered and ignored), touch, tablets, HiDPI output scaling, or screen
  capture.
- **No** animations, per-frame plugin hooks or decorations; these are
  planned for v0.2. Blur, shadows and rounded corners would need a
  custom renderer.
- **No** per-window floating rules: dwindle tiles every window.
- **Optional protocols are not implemented**, so clients warn and fall
  back. With foot 1.28:
  - no primary selection (middle-click paste);
  - no XDG activation (the bell falls back to red margins);
  - no fractional scaling;
  - no cursor-shape (client-drawn cursors);
  - no xdg-toplevel-icon;
  - no text-input (IME disabled);
  - no xdg-decoration (clients always draw their own decorations).
- The release binary targets Arch Linux sonames; other distributions
  should build from source.
- Not verified on real hardware from a TTY, or with real monitor
  hotplug, by the automated tests: see [docs/TESTING.md](docs/TESTING.md).

## Testing

All tests are headless and isolated from your session. The input tests
use test-only virtual input inside a private compositor.

```sh
zig build test                      # Zig unit tests + Lua host + dwindle (37 tests)
tests/smoke.sh && tests/focus.sh && tests/docs.sh
zig build -Dtest-input -p zig-out/test-input
tests/input.sh && tests/stress.sh   # real pointer/keyboard events, stress
```

See [docs/TESTING.md](docs/TESTING.md) for every suite, CI, and the
known coverage gaps. CI runs on GitHub Actions in an Arch Linux
container (`.github/workflows/ci.yml`).

## Project layout

```
src/            Zig core (2148 lines in v0.1.0)
  main.zig        startup, signals, config path
  server.zig      backend, scene, outputs, focus, spawn
  view.zig        xdg-shell toplevels/popups, configure/ack geometry
  input.zig       keyboard, bindings, pointer, move/resize
  layer.zig       wlr-layer-shell
  lua.zig         Lua 5.4 host: plugins, isolation, limits
  host.zig        compositor functions exposed to Lua (id-based)
config/         example ~/.config/raywm (dwindle + bindings)
docs/           INSTALL, CONFIGURATION, API, ARCHITECTURE, TESTING
tests/          unit, integration, input and stress tests
scripts/        package.sh (release archive), install.sh
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
- The test-only protocol files in `tests/protocol/` keep their upstream
  licenses (inside each file).

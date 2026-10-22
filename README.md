# RayWM

A small Wayland compositor written in Zig on top of wlroots. The native
core handles protocols, input, outputs and rendering, and everything else
is a Lua plugin. Philosophy: a minimal architecture with explicit
boundaries, not a contest for the fewest lines.

Status: **v0.1, early**. It has floating windows, Dwindle tiling (a Lua
plugin), Lua key bindings, reload, and layer-shell panels. See
[docs/API.md](docs/API.md) for the plugin API and what is not supported
yet.

## Build

Pinned versions (see `build.zig.zon` for hashes):

| | version |
|---|---|
| Zig | 0.16.0 |
| wlroots (system) | 0.20.x |
| zig-wlroots | 0.20.1 |
| zig-wayland / zig-xkbcommon / zig-pixman | 0.6.0 / 0.3.0 / 0.3.0 |
| Lua (system) | 5.4 (`pkg-config lua5.4`) |

System packages: wlroots 0.20, wayland, wayland-protocols, libxkbcommon,
pixman, lua5.4.

```sh
zig build                 # zig-out/bin/raywm
zig build test            # Lua host unit tests
tests/smoke.sh            # headless end-to-end test (no GPU, isolated)
tests/focus.sh            # headless focus tests with two windows
```

LLVM and LLD are used by default because the Zig 0.16 linker cannot handle
SFrame sections in recent GCC crt objects (`-Dllvm=false` to opt out).

## Run

```sh
cp -r config ~/.config/raywm     # example config: dwindle + bindings
raywm -s waybar                  # from a TTY, or nested in another session
```

Options: `-c config.lua`, `-s startup-command`, `-d` (verbose wlroots
log). Keyboard layout comes from the standard `XKB_DEFAULT_*` variables.

Default bindings of the example config: Super+Return terminal, Super+Q
close, Super+J/K cycle focus, Super+Shift+R reload, Super+Shift+E quit. Super+left drag moves a window
and Super+right drag resizes it. Ctrl+Alt+F1..F12 switch VTs when running
on a real session.

## Dwindle tiling

`config/plugins/dwindle.lua` tiles each output with a binary tree, in the
style of Hyprland's dwindle layout:

- a new window splits the focused window's area in two, along that area's
  longer side. It then gets focus (core default, see below), so repeated
  windows spiral inwards;
- closing a window gives its area to its sibling, and the tree collapses;
- each output has its own tree, and windows from an unplugged output move
  to the first remaining one;
- the usable area excludes panel exclusive zones, and an 8 px `gap` (outer
  margin and space between windows) can be changed at the top of the file;
- only geometry is recomputed when outputs, panels or windows change, and
  requests whose geometry did not change are skipped;
- across `raywm.reload()` the tree shape is kept in
  `$XDG_RUNTIME_DIR/raywm-dwindle-$WAYLAND_DISPLAY.lua`. The file is read
  once, and only if windows exist, so a new session never reuses it.

Tested by `tests/dwindle_test.lua` (run by `zig build test`) against a mock
of the plugin API. It covers 1–5 windows, closing the first, middle and
last window, focus-based splits, output resize, panels, two outputs and
unplugging, stale windows, reload, and minimum sizes.

## Focus

A newly mapped window gets keyboard focus, even when another window is
focused. A plugin can override this: if any `view_map` handler calls
`raywm.view_focus` (even on the previously focused window), the core
keeps that choice. Handlers still see the previous window in
`raywm.focused()`, which is what dwindle splits.

## Known limitations (v0.1)

- **Optional Wayland protocols are not implemented**, so clients log
  warnings and fall back. With foot 1.28:
  - primary selection (middle-click paste) is unavailable;
  - XDG activation is missing, so the urgency bell falls back to red window margins;
  - fractional scaling is missing, so integer scale is used;
  - cursor-shape is missing, so clients draw their own cursors;
  - xdg-toplevel-icon is missing, so windows have no icons;
  - text-input is missing, so IME is disabled;
  - xdg-decoration is missing, so clients always draw their own decorations.

  None of these affect basic use. Also not supported: maximize and
  fullscreen requests (answered, but ignored), Xwayland, workspaces,
  animations (planned for v0.2).
- Tiled windows can still be moved or resized with Super+drag. The
  dwindle plugin does not track this, so such a window stays out of place
  until its own tile changes position or size.

## Layout

```
src/main.zig     startup, signals, config path
src/server.zig   backend, scene, outputs, focus, spawn
src/view.zig     xdg-shell toplevels/popups, configure/ack geometry
src/input.zig    keyboard, bindings, pointer, move/resize
src/layer.zig    wlr-layer-shell
src/lua.zig      Lua 5.4 host: plugin registry, isolation, limits
src/host.zig     compositor functions exposed to Lua (id-based)
config/          example ~/.config/raywm
tests/           unit tests, test client, headless smoke test
```

## Credits

The core started from `tinywl` in zig-wlroots (© Isaac Freund, permissive
license). `protocol/wlr-layer-shell-unstable-v1.xml` is © Drew DeVault
(license inside the file).

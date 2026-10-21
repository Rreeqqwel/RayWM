# RayWM

A small Wayland compositor written in Zig on top of wlroots. The native
core handles protocols, input, outputs and rendering, and everything else
is a Lua plugin. Philosophy: a minimal architecture with explicit
boundaries, not a contest for the fewest lines.

Status: **v0.1, early**. It has floating and tiling windows (through a
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
```

LLVM and LLD are used by default because the Zig 0.16 linker cannot handle
SFrame sections in recent GCC crt objects (`-Dllvm=false` to opt out).

## Run

```sh
cp -r config ~/.config/raywm     # example config: tiling + bindings
raywm -s waybar                  # from a TTY, or nested in another session
```

Options: `-c config.lua`, `-s startup-command`, `-d` (verbose wlroots
log). Keyboard layout comes from the standard `XKB_DEFAULT_*` variables.

Default bindings of the example config: Super+Return terminal, Super+Q
close, Super+J/K focus, Super+Shift+Return promote to master,
Super+Shift+R reload, Super+Shift+E quit. Super+left drag moves a window
and Super+right drag resizes it. Ctrl+Alt+F1..F12 switch VTs when running
on a real session.

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

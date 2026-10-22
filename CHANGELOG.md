# Changelog

All notable changes to RayWM. Versions follow [Semantic
Versioning](https://semver.org/); before 1.0, minor versions may break
the Lua API (the API version, `raywm.api_version`, is bumped when they do).

## [v0.1.1] — 2026-10-22 — Screenshots and core hardening

The Lua plugin API is unchanged (still `api = 1`).

### Added

- **Screen capture protocols in the core** (`src/server.zig`, from
  wlroots 0.20): `wlr-screencopy-unstable-v1` (v3) and
  `xdg-output-unstable-v1` (output names and layout positions, which
  grim and slurp need for correct regions on several outputs). No
  renderer, image encoder, key binding or save policy was added to the
  core. **Privacy:** every client of the RayWM socket can capture the
  screen, with or without the plugin (see `SECURITY.md`).
- **`config/plugins/screenshot.lua`**, a self-contained API v1 plugin,
  loaded by the example configuration:
  - full screenshot (Print, or Ctrl+Alt+P for nested sessions where the
    outer compositor keeps Print), region (Shift+Print, with slurp),
    clipboard copies (Ctrl+Print, Ctrl+Shift+Print, with wl-copy);
  - PNG files in `$XDG_PICTURES_DIR/Screenshots` or
    `~/Pictures/Screenshots` (configurable), named by date and time,
    never overwritten, created with mode 0600;
  - notifications through notify-send when it is installed;
  - a clear logged error (and notification) when grim, slurp or wl-copy
    is missing; a cancelled selection saves and reports nothing;
  - everything runs in the background via `raywm.spawn`; file names reach
    the shell only as single-quoted arguments of a fixed script.
- **Screenshot gallery** in `docs/screenshots/`: real RayWM screenshots
  from an isolated headless session (`scripts/gallery.sh`).
- **Tests:**
  - `tests/screenshot.sh`: real grim, slurp, wl-copy and wl-paste against
    an isolated headless RayWM, driven by real key presses. A client draws
    a known pattern and every PNG is decoded and checked pixel by pixel:
    full screen, region, cancel, clipboard, two outputs, an output
    unplugged during a pending capture, plugin removal by reload, window
    geometry offsets. Passes with pixman and GLES2.
  - `tests/screenshot_test.lua` (in `zig build test`): bindings and
    conflicts with the shipped plugins, unload/reload, no blocking calls
    in callbacks, directory selection, and the generated commands run by
    `/bin/sh` against hostile file names.
  - `tests/input.sh`: four new scenarios (below).

### Fixed

- **Destroying a toplevel with an open popup** could crash the
  compositor. wlroots destroys the popup's scene tree together with the
  toplevel's, before the popup itself; the popup kept a dangling pointer,
  used by a nested popup created in that window. Popup trees now live
  exactly as long as the popup role. Also, the popups of a closing window
  are taken out of the scene before the pointer is refocused, so the next
  click no longer goes to the dead popup.
- **A new top/overlay layer surface could take the keyboard from an
  exclusive one** (for example a notification stealing it from a
  launcher or lock screen). It now takes the keyboard only from nobody,
  from an on-demand surface, or, when exclusive itself, from an exclusive
  surface in the same or a lower layer. When the holder goes away, the
  keyboard returns to the remaining exclusive surface before the window.
- **Unplugging the seat's active keyboard while another one remains**
  left the seat without a keyboard: new clients got no keymap and no
  focus until a key was pressed elsewhere (wl-copy hung). The seat now
  switches to the remaining keyboard.
- **Windows with client-side title bars or shadows were drawn
  displaced** by their window geometry offset (foot 26 px too low, over
  its tile's bottom gap): the offset was applied twice. Popup
  unconstraining now uses the coordinates wlroots expects.

### Investigated

- **Pointer device removed during a grab:** listed as a known issue of
  v0.1.0, but not reproducible. wlroots 0.20 sends the release of every
  held button when a pointer goes away (`wlr_pointer_finish`, used by the
  libinput, Wayland and X11 backends and by virtual pointers), and that
  release ends the grab. A regression test now covers Super+drag,
  client-side moves and Super+resize, including that later presses reach
  the client.

### Known limitations

New in this release: screen capture is open to every client; clipboard
copies briefly map a helper window (no data-control protocol); no
implicit pointer grab, so slurp selections cannot cross outputs. See
`README.md`.

## [v0.1.0] — 2026-10-22 — First experimental release

### Added

- **Compositor core** (Zig 0.16, wlroots 0.20):
  - xdg-shell toplevels and popups. Window sizes follow the
    configure/ack protocol, so a position that depends on a new size is
    applied in the same commit.
  - Keyboard (xkb, layout from `XKB_DEFAULT_*`), pointer, click-to-focus.
  - Interactive move and resize: Super + left/right drag, and client-side
    title bars. Resizing from the left/top keeps the opposite edge fixed.
  - Multiple outputs with hotplug; windows left on a removed output are
    moved to a visible one.
  - wlr-layer-shell v4 for panels, docks, launchers and backgrounds:
    exclusive zones, keyboard interactivity (exclusive and on-demand), and
    popups.
  - VT switching (Ctrl+Alt+F1..F12) when running on a real session.
  - Clean shutdown on SIGINT/SIGTERM.
- **Lua 5.4 plugin host, API v1** (see `docs/API.md`):
  - One loading contract: `raywm.load(name)` and
    `{ api = 1, setup, teardown }`.
  - Per-plugin ownership of handlers, bindings, timers and managed
    windows, released with deferred cleanup.
  - Error isolation: an error unloads only the plugin that raised it.
  - Memory cap and an instruction budget that cannot be bypassed with
    `pcall`; no `debug` library.
  - Integer ids checked on every call.
  - `raywm.reload()`.
  - Fallback bindings while no plugin binds keys.
- **`ctx.manage(view, on)`**: layout plugins declare the windows they
  tile. The core then refuses free interactive move/resize for them;
  clicks still focus.
- **Dwindle tiling** (`config/plugins/dwindle.lua`, pure Lua): one binary
  tree per output, focus-based splits along the longer side, sibling
  collapse, gaps, usable area aware, tree shape kept across reload.
- Example configuration (`config/`): dwindle and key bindings.
- **Tests**:
  - Zig unit tests for the core and the Lua host.
  - A Lua test suite for dwindle with randomized fixed-seed sequences.
  - Headless Wayland integration tests with real clients.
  - Real pointer/keyboard interaction tests through a test-only
    virtual-input build.
  - Bounded stress tests.
- CI (GitHub Actions, Arch Linux container), packaging and per-user
  install scripts, documentation.

### Fixed before release (found by independent audits)

- An instruction-budget bypass through `pcall` or coroutines (including
  coroutines created before the budget ran out) could hang the
  compositor.
- The key of a binding that changed focus was reported as held to the
  newly focused client.
- A second `view_place` before the client's ack could be lost.
- Extreme Lua coordinates could overflow geometry arithmetic.
- A drag continued after its window became managed.
- Extra mouse buttons during a grab broke the grab state.
- Layer surfaces changing keyboard interactivity after map were ignored.
- The `debug` library exposed host internals, and `package.loadlib`
  could load it again from the Lua shared library.
- Registrations could grow without bound.
- Windows beyond 256 were dropped by `raywm.views()`.
- The dwindle reload snapshot was executed as code and parsed without
  depth limits.

### Known limitations

See "Known limitations" in `README.md`. In short: no Xwayland,
workspaces, fullscreen/maximize, animations or effects; several optional
protocols are missing; the release binary is built for Arch Linux.

[v0.1.1]: https://github.com/Rreeqqwel/RayWM/releases/tag/v0.1.1
[v0.1.0]: https://github.com/Rreeqqwel/RayWM/releases/tag/v0.1.0

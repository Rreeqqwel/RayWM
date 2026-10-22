# Changelog

All notable changes to RayWM. Versions follow [Semantic
Versioning](https://semver.org/); before 1.0, minor versions may break
the Lua API (the API version, `raywm.api_version`, is bumped when they do).

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

[v0.1.0]: https://github.com/Rreeqqwel/RayWM/releases/tag/v0.1.0

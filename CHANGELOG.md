# Changelog

All notable changes to RayWM. Versions follow [Semantic
Versioning](https://semver.org/); before 1.0, minor versions may break
the Lua API (the API version, `raywm.api_version`, is bumped when they do).

## [Unreleased]

### Added

- **More Wayland protocols** (wlroots implements them; RayWM creates and
  connects them), each checked with real requests in `tests/protocols.sh`:
  - clipboard managers: wlr data control and ext-data-control (`wl-copy`
    no longer maps a helper window, so tiles no longer jump; cliphist
    works); primary selection (middle-click paste);
  - fractional scale (clients get e.g. 1.5 as 180/120 when the output's
    scale changes), viewporter, single-pixel buffers, alpha modifier,
    presentation time (an update replaced before it was shown is
    reported discarded), linux-dmabuf v5 with the GLES2 renderer (given
    to the scene for per-surface feedback), xdg-foreign v2 (portal
    dialogs), cursor shapes from the client that has the pointer;
  - security-context-v1: clients started by a sandbox (Flatpak) do not
    see privileged globals: screen capture, data control, output
    management and power, gamma, layer shell, session lock, foreign
    toplevel and workspace management, virtual input, input methods.
- **Input configuration** (`config/plugins/input.lua`, in the example
  `init.lua` with every setting commented out):
  - `raywm.input_configure(match, settings)` for `"*"`, `"type:keyboard"`
    (pointer, touchpad, touch, tablet, switch) or a device name; more
    specific entries override less specific ones setting by setting;
    unset settings keep their defaults, so removing one and reloading
    undoes it; unknown setting names are errors;
  - keyboards: XKB rules, model, layout, variant and options, repeat
    rate and delay; a layout that does not compile is refused and the
    keyboard keeps its keymap; virtual keyboards keep their client's
    keymap; bindings still match in every layout;
  - pointers and touchpads (libinput): acceleration profile and speed,
    natural scrolling, left-handed, tap, tap-and-drag, drag lock,
    disable-while-typing, middle-button emulation, scroll and click
    methods, send-events mode — applied when a device supports them.
    These need real devices and were only unit-tested (the layering) on
    the headless test setup;
  - hotplug: every new device gets its settings; `raywm.input_devices()`;
    events `input_add`, `input_remove`;
  - keyboard layouts: `raywm.keyboard_layout()`,
    `raywm.keyboard_set_layout(n)`, event `keyboard_layout(0, n)`.
- **Output configuration**:
  - wlr-output-management (wlr-randr, kanshi): mode and refresh rate
    (also custom modes), scale (HiDPI), rotation, position, enabling
    and disabling, adaptive sync; tested before it is applied, atomic for
    all outputs it changes;
  - `raywm.output_configure(name or id, { mode, scale, transform,
    position, enabled, adaptive_sync })`, `raywm.output_modes(id)`;
    `raywm.outputs()` entries have name, description, make, model,
    serial, scale, transform, mode, physical size, power and
    `enabled`; `raywm.outputs({ all = true })` lists disabled outputs
    too;
  - `config/plugins/outputs.lua` (in the example `init.lua`, with an
    empty list) applies settings by output name or description at
    startup and on hotplug;
  - a configuration that would disable every output is refused, from
    clients and from Lua alike;
  - a disabled output stops being usable like an unplugged one
    (`output_remove`; its workspaces move to another output) and comes
    back where it was when enabled again (`output_add`; workspaces.lua
    moves its workspaces home); placing one output never moves another;
  - output power (wlr-output-power-management, DPMS): a powered-off
    output stays in the layout;
  - gamma control (wlr-gamma-control: gammastep, wlsunset), applied by
    wlroots' scene; not verifiable on headless outputs, which have no
    gamma ramp.
- **Screen locking** (ext-session-lock-v1; works with swaylock):
  - while locked, only the locker's surfaces are drawn: every other
    layer is hidden and each output has an opaque background below the
    lock surfaces, so no window or panel shows, also on an output without
    a lock surface and in screenshots;
  - the locker is told it locked only after every output has presented a
    frame in that state;
  - keyboard and pointer reach only the locker; no key binding runs
    (not even the core's fallback Super+Shift+E), except VT switching;
    plugins cannot move focus (`raywm.pointer_warp` returns
    `nil, "locked"`);
  - if the locker crashes, the session stays locked (dark red) until a
    new locker unlocks it; a second locker is refused while one holds
    the lock;
  - `raywm.locked()`, events `session_lock` and `session_unlock`.
- **Idle**: ext-idle-notify-v1 (swayidle and others get idle and resume
  notifications from real input) and idle-inhibit-unstable-v1 (a video
  player keeps the session awake while its window is visible; a hidden
  window's inhibitor does not count).
- **Autostart**: `config/plugins/autostart.lua` (in the example
  `init.lua`, with an empty list) starts programs once per RayWM start;
  `raywm.spawn_once(cmd)` (a command is not started again by a reload; a
  new one starts at the next reload) and `raywm.startup(fn)` (runs fn
  after the first `init.lua` only, in order; errors are reported as
  `startup`).
- **Window rules** (`config/plugins/window-rules.lua`, loaded by the
  example `init.lua`; your rules go in `rules.lua` next to `init.lua`):
  match windows by app id, title (Lua patterns, or lists of them), being
  a dialog, the parent's app id, output, workspace, fixed size, X11, or
  any test function; float or tile them, give them a size (pixels or
  percent) and position (pixels, centre, cursor), opacity, a workspace or
  output, fullscreen or maximized, or keep the keyboard on the focused
  window. Rules run in `view_new`, before layouts, so nothing jumps.
  Dialogs float by default, centred over their parent: windows with a
  parent, and fixed-size windows that are at most 80 % of the usable
  area (a fixed-size game is not taken for a dialog). Bad patterns are
  reported once and their rule is skipped.
- `raywm.config_dir`: the directory of `init.lua`, for plugins' own
  files.
- **Workspaces** (`config/plugins/workspaces.lua`, loaded by the example
  `init.lua`): nine per output. Super+1..9 show one, Super+Shift+1..9
  move the focused window there, Super+Ctrl+Left/Right show the
  previous/next one, Super+Shift+Ctrl+Left/Right move the window there,
  Super+Alt+Left/Right move it to the next output. Count, names, keys
  and `follow` are options.
  - The core keeps the workspaces (src/workspace.zig): each output shows
    one; windows on the others are hidden and can get neither keyboard
    nor pointer input, whatever plugins ask. New windows open on the
    workspace shown where they appear. Focus history is per workspace:
    showing one focuses its most recently focused window.
  - A workspace belongs to the plugin that created it. If that plugin
    fails or is reloaded, its workspaces are kept as orphans that a
    plugin adopts again (workspaces.lua does); orphans nobody adopted
    after a (re)load are removed and their windows shown, so removing the
    plugin from the config never loses windows.
  - Unplugging an output moves its workspaces, with their windows, to
    another output; when that output comes back, workspaces.lua moves
    them home. A new output gets its own nine.
  - Dwindle tiles every workspace separately and keeps the trees across
    reloads.
  - Lua API: `raywm.workspaces()`, `raywm.workspace(id)`,
    `raywm.workspace_activate/rename/set_output/remove`,
    `raywm.view_workspace(view, ws)`, `ctx.workspace_create(output,
    name)`, `ctx.workspace_adopt(id)`; `view(id).workspace`;
    `raywm.outputs()` entries have `name` and `workspace`; events
    `workspace_add`, `workspace_remove`, `workspace_activate(id, prev)`,
    `workspace_change`, `view_workspace(view, ws, old)`.
- **Floating windows** (`config/plugins/floating.lua`, loaded by the
  example `init.lua`): Super+Shift+Space toggles the focused window
  between tiled and floating. Floating is window state kept by the core
  (`raywm.view_floating(id, on)`, `raywm.view(id).floating`), so it
  survives reloads and every layout plugin sees it. A window floats where
  it last floated; the first time, centred at the size it chose itself.
  Floating windows always stay above tiled ones.
- **Fullscreen and maximize**, implemented in the core (before, the
  requests were answered and ignored):
  - Super+F and Super+M (binds.lua) toggle them for the focused window;
    `raywm.view_fullscreen(id, on [, output])`,
    `raywm.view_maximize(id, on)`; `view(id).fullscreen`,
    `fullscreen_output`, `maximized`;
  - client requests (also before the window maps: it then starts
    fullscreen or maximized) are granted unless a plugin decides
    otherwise in `view_request_fullscreen(id, on, output)` /
    `view_request_maximize(id, on)`; every request gets a configure;
  - a fullscreen window covers its output, panels included (a black
    backdrop fills what a smaller buffer leaves free); overlay surfaces
    stay above it; its border is not drawn;
  - leaving either state restores the previous geometry and layout
    place; while fullscreen or maximized, layout requests are only
    remembered, so the client gets no extra resizes;
  - output-aware: a fullscreen window follows its output when outputs
    move, and moves to another output when its output is unplugged; a
    maximized window follows the usable area (panels appearing);
  - keyboard focus never goes to a window hidden behind a fullscreen
    one: new windows open behind it and focus keys do not reach them,
    until it leaves fullscreen. Its dialogs are shown above it and can be
    focused;
  - fullscreen and maximized windows are not moved or resized by hand
    (Super+drag, title bars).
- Dialogs (windows with a parent) are kept above their parent window
  when it is raised.
- **Dwindle** (`config/plugins/dwindle.lua`):
  - Super+Ctrl+H/J/K/L move the split next to the focused window
    (`resize_step`, 40 px);
  - Super+Shift+H/J/K/L swap the focused window with its neighbour;
  - Super+T switches the focused window's split between side by side
    and stacked;
  - separate `gaps_in` and `gaps_out`; clients' minimum sizes are
    respected when they fit;
  - floating windows leave the tiling and come back;
  - one tree per space (an output, or a workspace once a workspace
    plugin is loaded); the reload snapshot format is now version 2, and
    a v0.1 snapshot is still read once after an upgrade.
- **Lua API** (still `api = 1`, additions only): `raywm.version`;
  `raywm.view(id)` also reports `parent`, `min_w`, `min_h`, `max_w`,
  `max_h`, `floating`, `managed`, `pid` (and `fullscreen`,
  `fullscreen_output`, `maximized`, `workspace`, `urgent`, `xwayland`,
  filled in by later features); events `view_new` (a window mapped,
  before `view_map`, for window rules), `view_state` and `view_app_id`;
  handlers may receive arguments after the id.
- `RAYWM_OUTPUT_MODE=WIDTHxHEIGHT@HZ` (`src/server.zig`) picks an
  output mode other than the monitor's preferred one, e.g.
  `1920x1080@240`. The nearest mode within 1 Hz is used; a mode the
  driver rejects falls back to the preferred mode with a warning. See
  docs/CONFIGURATION.md.

### Changed

- **New windows are shown only once they have the size a plugin gave
  them** while they mapped (or after 150 ms), so a tiled window no longer
  flashes at its own size in the middle of the screen before jumping
  into its tile.
- **Stacking:** windows a layout manages (`ctx.manage`) are kept below
  floating ones; focusing a tiled window no longer raises it above
  floating windows.
- `raywm.view_show(id, true)` only undoes a plugin's own hiding; it does
  not show windows the core hides (needed for workspaces).

### Fixed

- tests: the "client-side move and resize" pointer scenario raced its
  own client and failed about 1 run in 10.

## [v0.1.2] — 2026-10-22 — Input, focus and pointer reliability

The Lua plugin API is still `api = 1`. Its additions are compatible
(see below), and v0.1.1 configurations keep working unchanged.

### Fixed

- **Implicit pointer grab** (`src/input.zig`). wlroots' default pointer
  grab does not implement the implicit grab of `wl_pointer`, and RayWM
  re-ran hit-testing on every motion. While a button was held, a drag
  that left the window moved pointer focus away: the window got a
  `leave`, the window under the cursor got an `enter`, and the release
  was delivered to nobody. Visible effects: text selection, scrollbar
  and slider drags stopped at the window edge; a slurp selection dragged
  across two outputs was lost; a client could be left thinking a button
  was still pressed. Now, while a button the client saw is held:
  - the surface that got the press keeps the pointer (windows,
    subsurfaces, popups and layer-shell surfaces alike), and gets every
    motion in its own coordinates, also outside its bounds, and the
    release;
  - extra buttons pressed meanwhile also go to it; the grab ends with
    the last release, and only then does focus follow the cursor again;
  - windows moving, mapping or hiding under the cursor (plugin layouts,
    `view_move`) do not take the pointer away;
  - if the surface goes away (closed, crashed, unmapped, its output
    unplugged), no other client gets pointer events until the last
    release, so none sees the release of a press it never got.
  wlroots' own grabs (an `xdg_popup` grab) keep working as before.
- **Key bindings with a non-Latin layout active** (`src/input.zig`).
  With a keymap like `us,ru` and the Russian layout active, Super+J
  produced `Cyrillic_o` and matched no binding (the key went to the
  window instead). Letter bindings now also match the key's Latin keysym
  from another layout of the keymap. This was a likely cause of the
  report "Super+J and Super+K do nothing"; see the upgrade notes below.
- **A layer surface mapping or unmapping under a still cursor** now
  updates pointer focus at once (before, only the next motion did).
- **Duplicate-binding check** is bounded (no quadratic native work for
  a plugin binding thousands of keys) and warns once per plugin.

### Added

- **`config/plugins/focus.lua`** (loaded by the example `init.lua`):
  - **directional focus**: Super+H/J/K/L focus the window to the
    left/below/above/right, by geometry, preferring windows directly in
    that direction, on the same output first (another output only if it
    lies in that direction); focus stays when there is none;
  - **focus cycle**: Super+Tab / Super+Shift+Tab, in a fixed order
    (outputs left to right, windows in opening order), wrapping;
  - **optional pointer warp** (`warp = true`; off by default) to the
    centre of the newly focused window; never while a button is held,
    a window is dragged, or an exclusive launcher/lock surface is open;
  - **focus border**: a 2 px `#5294e2` border around the focused window
    (width and color configurable; 0 disables it).
- **Lua API v1 additions** (compatible; feature-test with
  `if raywm.pointer_warp then`):
  - `raywm.view(id).visible`;
  - `raywm.pointer()` → `{x, y, busy}`;
  - `raywm.pointer_warp(x, y)` → `true`, or `nil` and
    `"busy"`/`"exclusive"`/`"outside"`;
  - `raywm.view_border(id, width, color)`: a solid border outside the
    window, drawn with wlr_scene rectangles.
- **Diagnostics** that do not clutter the normal log:
  - `loaded plugin NAME (N key bindings)` per plugin;
  - a warning when a key is bound twice (the first binding wins);
  - a warning when no plugin registered any binding (only the fallback
    keys work);
  - `raywm -d` also logs each key press with Super, Ctrl or Alt, the
    keysym and layout it was matched with, and whether a binding ran.
    Plain typing is never logged.
- **Tests:**
  - `tests/pointer.sh` (13 scenarios): real clients log every
    `wl_pointer` event; drags across windows, several buttons, release
    outside, subsurface, layer surface, popup destroyed and window killed
    while held, output unplugged while held, scene changes under a held
    button, client-side move/resize, Super+drag, Super+click during a
    client's grab, an `xdg_popup` grab. 11 of them fail on v0.1.1.
  - `tests/navigation.sh` (11 scenarios): US and Russian layouts,
    dwindle and floating windows, two outputs, pointer warp versus a
    held button, the border checked on screen with grim, reload during a
    held button, edited bindings applied by a reload, an exclusive
    launcher, closing a window whose button is held, unchanged and
    half-migrated v0.1.1 configurations.
  - `tests/focus_test.lua` (19, in `zig build test`), including 400
    random two-output layouts; xkb unit tests for the layout rule;
    host tests for the new API.
  - `tests/screenshot.sh`: a slurp selection across two outputs.

### Changed

- **dwindle.lua no longer binds Super+J/K.** Its tree-order cycle
  (`focus_step`) is kept, unbound by default (`keys.focus_next`,
  `keys.focus_prev`). focus.lua owns Super+H/J/K/L and Super+Tab.
- The press that starts an interaction decides its target: click focus
  and Super+drag/resize act on the first press only; buttons pressed
  while a client holds the implicit grab go to that client.
- `raywm -d` now also enables RayWM's own key diagnostics.

### Upgrading from v0.1.1

`install.sh` never changes an existing `~/.config/raywm`. Your
configuration keeps working as before (dwindle's Super+J/K included).
To get the new focus keys and the border:

```sh
cp ~/.config/raywm/plugins/dwindle.lua ~/.config/raywm/plugins/dwindle.lua.v011   # backup
cp config/plugins/focus.lua config/plugins/dwindle.lua ~/.config/raywm/plugins/
echo 'raywm.load("focus")' >> ~/.config/raywm/init.lua
```

Then press Ctrl+Alt+R. If you copy only `focus.lua` and keep the old
`dwindle.lua`, the log warns `plugin focus: key Super+j is already bound
by plugin dwindle`: dwindle's Super+J/K win until you update it. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#upgrading-from-v011).

### Known limitations

- Drag and drop between clients is still not supported (RayWM does not
  start `wl_data_device` drags).
- Not verified on real hardware with real mice and keyboards; the same
  wlroots input path is driven headlessly with virtual devices.

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

# Testing RayWM

All automated tests run **headless**:
- in a private `XDG_RUNTIME_DIR`, with a scrubbed environment (`env -i`);
- with a virtual output (`WLR_BACKENDS=headless`);
- with no real input devices.

They never connect to, or inject input into, your running desktop
session.

## Requirements

- Zig 0.16.0 and the build dependencies from [INSTALL.md](INSTALL.md).
- `lua5.4` and `luac5.4` (Arch: `lua54`).
- Standard tools: `sh`, `awk`, `timeout`, `strings` (binutils), `file`,
  `ldd`.
- For GLES2 runs, a DRM render node (`/dev/dri/renderD*`). Pixman runs
  need nothing extra.

## Running everything (what CI runs)

```sh
zig fmt --check build.zig build.zig.zon src tests
for f in src/*.zig tests/*.zig tests/support/*.zig; do zig ast-check "$f"; done
find config tests -name '*.lua' -print0 | xargs -0 -n1 luac5.4 -p

zig build                                   # Debug build  -> zig-out/bin
zig build -Dtest-input -p zig-out/test-input # TEST build with virtual input
zig build test --summary all                # unit tests (Zig + Lua)

tests/smoke.sh                              # each script: RENDERER=gles2 to use GLES2
tests/focus.sh
tests/docs.sh
tests/input.sh                              # needs the -Dtest-input build
tests/stress.sh                             # needs the -Dtest-input build

zig build -Doptimize=ReleaseSafe -p zig-out/release && tests/smoke.sh zig-out/release/bin
```

Useful variables: `KEEP=1` keeps the temporary directory with all logs;
`ONLY=<substring>` runs only matching scenarios of `tests/input.sh`.

## Test suites

| Suite | Kind | What it covers |
|---|---|---|
| `tests/core_test.zig` | Zig unit (4) | configure serial wrap-around, key spec parsing, coordinate clamping, `spawn` (no zombie, unblocked signals) |
| `tests/lua_test.zig` | Zig unit (16), fake compositor | the plugin contract (api version, rejection), dispatch, error isolation, deferred cleanup, cancellation during dispatch, stale/invalid ids, timers (injected clock), memory and instruction limits incl. `pcall`/coroutine bypass attempts, no `debug` library, nested dispatch depth limit, duplicate bindings, setup/teardown failures, reload (from a binding, init.lua, teardown, 25× with flat memory, failed reload), `ctx.manage` lifecycle, registration cap |
| `tests/dwindle_test.lua` | Lua (17), mock API that follows the core's rules | layouts with 1–5, 10 and 20 windows; focus-based insertion; closing in every order (tree collapse); output resize, panels, two outputs and unplugging; geometry cache and externally moved windows; managed-window registration; tiny geometries; stale windows; reload and hostile snapshot files; **20 fixed-seed random sequences × 300 operations**, checking after every step that each window has exactly one leaf, parent links hold, every leaf is a live window, managed set = tiled set, no negative sizes, everything inside the usable area, no overlaps except in deliberately shared sub-pixel areas |
| `tests/smoke.sh` | Wayland, real client | connection, xdg toplevel configure/ack, buffer commit, frame callback, a toplevel re-created on the same `xdg_surface`, asynchronous resize by dwindle with position applied on ack, a layer-shell panel and its exclusive zone, Lua event order, children with unblocked signals, clean SIGTERM exit |
| `tests/focus.sh` | Wayland, two clients at once | focus seen by clients (`xdg_toplevel` activated state): a new window takes focus, focus returns on close, a plugin overriding focus in `view_map`, dwindle insertion + focus |
| `tests/docs.sh` | Wayland | every plugin example in `docs/API.md` loads and runs |
| `tests/input.sh` | Wayland + **real pointer/keyboard events** (virtual input) | 8 scenarios: floating Super+drag move and resize; client-side title-bar move; managed windows refuse all three while clicks still focus; binding keys never reported as held to the newly focused client; second `view_place` before ack; clamped extreme coordinates; window becoming managed mid-drag; extra buttons during a grab; panel crash and window crash re-tiling; a layer surface releasing the keyboard |
| `tests/stress.sh` | Wayland, bounded | 100 window cycles; 20 waves of 8 `SIGKILL`ed clients; 40 reloads with a plugin failing on each map; 1500 geometry changes in 3 s; clean shutdown; compositor RSS per phase (fails above +16 MiB) |

Each fix found by the pre-release audits was checked by reverting it and
confirming that its test fails.

### Virtual input (test builds only)

`zig build -Dtest-input` links `tests/support/virtual_input.zig` into
the compositor. It exposes the wlroots virtual pointer and virtual
keyboard protocols. `tests/input_driver.zig` uses them to move the
pointer, press buttons and type keys. The test compositor runs on its
own socket in a private runtime directory, so this input reaches only
the test clients. Such builds log `TEST BUILD` at startup, and release
packaging refuses binaries that contain this code.

## Measured results (v0.1.0, local machine)

Arch Linux, x86_64, wlroots 0.20.2, Lua 5.4.9, Zig 0.16.0, foot 1.28,
with a GPU render node (GLES2 available):

| Suite | Pixman | GLES2 |
|---|---|---|
| unit (Zig 20 + Lua 17) | pass | — |
| smoke | pass | pass |
| focus | pass | pass |
| docs | pass | — |
| input (8 scenarios) | pass | pass |
| stress | pass, RSS +1.0 MiB | pass, RSS +0.8 MiB |

In CI (GitHub-hosted runners, Arch Linux container), everything runs
with pixman. **GLES2 cannot run on hosted runners**, which have no DRM
render node. The GLES2 job then reports "NOT RUN" as a warning; it does
not report a pass.

## Not covered by automated tests

These were **not** verified automatically. Unless noted, they were not
verified manually for v0.1.0 either:

| Area | Status |
|---|---|
| Running from a TTY on real hardware (DRM/KMS, libinput, logind/seatd, VT switching) | not verified |
| Real monitor hotplug and mode changes | not verified; logic covered by the dwindle mock and output code review |
| Real keyboards and mice | indirectly: the same wlroots input path as the virtual devices |
| Nested session with foot and multiple windows; Lua tiling | observed manually during development (earlier builds) |
| Popups (menus) positioning on screen edges | not verified automatically |
| HiDPI / output scaling | not supported in v0.1 |
| Memory errors with sanitizers | not available: no valgrind on the development machine, and AddressSanitizer is not usable with this Zig/C setup. Long runs were checked with RSS measurements only |

### Manual test procedure (before trusting a new build on real hardware)

1. Nested: `raywm -s foot`.
   - Open three terminals with Super+Return; check the dwindle spiral.
   - Super+J/K moves focus.
   - Super+Q closes a window; its sibling fills the space.
2. Super + left drag on a tiled window: it must not move, and must get
   focus. Run `raywm -c /dev/null -s foot` (no plugins, windows float):
   Super + left/right drag must move and resize.
3. Drag a foot window by its title bar: it moves when floating and is
   refused when tiled.
4. `raywm -s waybar` (or another bar): the tiles start below the bar.
   `pkill waybar`: the tiles grow back.
5. Edit `~/.config/raywm/plugins/dwindle.lua` to raise an error. Press
   Ctrl+Alt+R: only dwindle is unloaded, and the bindings keep working.
   Fix the file and reload again.
6. From a TTY (Ctrl+Alt+F3): `raywm -s foot`. Check keyboard, mouse,
   Ctrl+Alt+F1 to go back, and Super+Shift+E to quit.

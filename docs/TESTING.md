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
- For `tests/screenshot.sh`: `grim`, `slurp`, `wl-clipboard` (wl-copy,
  wl-paste) and `python3` (standard library only, for the PNG checker).
  The script stops with exit status 2 if one is missing; it never skips
  silently.

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
tests/screenshot.sh                         # needs the -Dtest-input build
tests/stress.sh                             # needs the -Dtest-input build

zig build -Doptimize=ReleaseSafe -p zig-out/release && tests/smoke.sh zig-out/release/bin
```

Useful variables: `KEEP=1` keeps the temporary directory with all logs;
`ONLY=<substring>` runs only matching scenarios of `tests/input.sh` and
`tests/screenshot.sh`.

## Test suites

| Suite | Kind | What it covers |
|---|---|---|
| `tests/core_test.zig` | Zig unit (4) | configure serial wrap-around, key spec parsing (including the screenshot plugin's `Print` bindings, with real xkb), coordinate clamping, `spawn` (no zombie, unblocked signals) |
| `tests/lua_test.zig` | Zig unit (17), fake compositor | the plugin contract (api version, rejection), dispatch, error isolation, deferred cleanup, cancellation during dispatch, stale/invalid ids, timers (injected clock), memory and instruction limits incl. `pcall`/coroutine bypass attempts (also via a coroutine created before the budget ran out), no `debug` library and no native module loading, nested dispatch depth limit, duplicate bindings, setup/teardown failures, reload (from a binding, init.lua, teardown, 25× with flat memory, failed reload), `ctx.manage` lifecycle, registration cap |
| `tests/dwindle_test.lua` | Lua (17), mock API that follows the core's rules | layouts with 1–5, 10 and 20 windows; focus-based insertion; closing in every order (tree collapse); output resize, panels, two outputs and unplugging; geometry cache and externally moved windows; managed-window registration; tiny geometries; stale windows; reload and hostile snapshot files; **20 fixed-seed random sequences × 300 operations**, checking after every step that each window has exactly one leaf, parent links hold, every leaf is a live window, managed set = tiled set, no negative sizes, everything inside the usable area, no overlaps except in deliberately shared sub-pixel areas |
| `tests/screenshot_test.lua` | Lua (99 checks), mock API + `/bin/sh` with fake grim/slurp/wl-copy/notify-send | the five bindings and no key bound twice across binds.lua, dwindle.lua and screenshot.lua (nor over the core's fallback or VT keys); unload leaves nothing, other plugins untouched; reload; setup and callbacks call no blocking function (`os.execute`, `io.*`, ...) and spawn exactly one command; argument layout per action; directory choice (`XDG_PICTURES_DIR` absolute/relative/empty/trailing slash, `HOME`, `options.dir`, NUL bytes); the generated commands executed by `/bin/sh` against a directory name full of shell syntax (`$(...)`, backticks, quotes, `;`, newline, leading `-`, `*`): the file lands exactly there and nothing is executed; unique names with no temporary files left; mode 0600; region geometry passed to grim; cancel saves, runs and reports nothing; clipboard gets the PNG with `--type image/png`; each missing tool gives a logged error and a notification; no notify-send; grim failure; no `WAYLAND_DISPLAY`; no directory; `notify = false` |
| `tests/smoke.sh` | Wayland, real client | connection, xdg toplevel configure/ack, buffer commit, frame callback, a toplevel re-created on the same `xdg_surface`, asynchronous resize by dwindle with position applied on ack, a layer-shell panel and its exclusive zone, Lua event order, children with unblocked signals, clean SIGTERM exit |
| `tests/focus.sh` | Wayland, two clients at once | focus seen by clients (`xdg_toplevel` activated state): a new window takes focus, focus returns on close, a plugin overriding focus in `view_map`, dwindle insertion + focus |
| `tests/docs.sh` | Wayland | every plugin example in `docs/API.md` loads and runs |
| `tests/input.sh` | Wayland + **real pointer/keyboard events** (virtual input) | 12 scenarios: floating Super+drag move and resize; client-side title-bar move; managed windows refuse all three while clicks still focus; binding keys never reported as held to the newly focused client; second `view_place` before ack; clamped extreme coordinates; window becoming managed mid-drag; extra buttons during a grab; panel crash and window crash re-tiling; a layer surface releasing the keyboard; **v0.1.1:** a pointer removed in the middle of Super+drag, a client-side move and Super+resize (the grab ends, later presses reach the client); an on-demand overlay surface not taking the keyboard from an exclusive one, a higher exclusive one taking it and giving it back to the first, not to the window; a toplevel destroyed while its popup is open, with a nested popup racing the destruction (`MALLOC_PERTURB_` makes a use-after-free crash) and a click afterwards reaching no dead popup; the seat's active keyboard unplugged while another remains |
| `tests/screenshot.sh` | Wayland + real **grim, slurp, wl-copy, wl-paste**, real key presses | 8 scenarios. A client draws opaque quadrants (red, green, blue, white) at a known position; every PNG is decoded (`tests/support/png_check.py`: signature, chunk CRCs, zlib stream, every filter) and its size and pixels are checked: Print and Ctrl+Alt+P full screenshots (distinct names, mode 0600, notification, no temporary files); Shift+Print with a real slurp drag (exact crop); Escape cancels (no file, no grim, no notification; the next shot works); Ctrl+Print and Ctrl+Shift+Print, read back with wl-paste as `image/png`; two outputs (full layout and a region on the second); an output unplugged while a capture is pending (`raywm-test-screencopy`: the copy fails cleanly, a new request for the removed output fails, a copy racing the unplug ends either way, no crash); plugin removed by reload (keys gone, other plugins work, reload back works); a window whose geometry excludes a 10 px shadow lands exactly at its position. Every tool is wrapped to record `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR`; the test fails if any ran outside the test session |
| `tests/stress.sh` | Wayland, bounded | 100 window cycles; 20 waves of 8 `SIGKILL`ed clients; 40 reloads with a plugin failing on each map; 1500 geometry changes in 3 s; clean shutdown; compositor RSS per phase (fails above +16 MiB) |

Each fix found by the pre-release audits was checked by reverting it and
confirming that its test fails. For v0.1.1 this was done for the popup
fixes (both parts separately), the layer focus rule, the keyboard
handover, the geometry offset and the plugin's quoting (replacing it
with naive double quotes fails the injection checks).

### Virtual input (test builds only)

`zig build -Dtest-input` links `tests/support/virtual_input.zig` into
the compositor. It exposes the wlroots virtual pointer and virtual
keyboard protocols. `tests/input_driver.zig` uses them to move the
pointer, press buttons and type keys. The test compositor runs on its
own socket in a private runtime directory, so this input reaches only
the test clients. Such builds log `TEST BUILD` at startup, and release
packaging refuses binaries that contain this code.

Test builds also unplug an output on `SIGUSR2` (the output named in
`$XDG_RUNTIME_DIR/raywm-test-unplug`), so `tests/screenshot.sh` can
remove an output while a capture is pending, and build
`raywm-test-screencopy`, a minimal wlr-screencopy client.

## Measured results (v0.1.1, local machine)

Arch Linux, x86_64, wlroots 0.20.2, Lua 5.4.9, Zig 0.16.0, foot 1.28,
grim 1.5.0, slurp 1.5.0, wl-clipboard 2.3.0, with a GPU render node
(GLES2 available):

| Suite | Pixman | GLES2 |
|---|---|---|
| unit (Zig 21 + Lua 17 + screenshot 99 checks) | pass | — |
| smoke | pass | pass |
| focus | pass | pass |
| docs | pass | — |
| input (12 scenarios) | pass | pass |
| screenshot (8 scenarios) | pass | pass |
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
| Screenshots in a real (non-headless) session: the Print key on a real keyboard, slurp with a real mouse, a real notification daemon, clipboard managers | **not verified manually for v0.1.1**; the same programs and code paths are tested headlessly with virtual input |
| A slurp selection dragged across two outputs | known not to work (no implicit pointer grab in the core) |
| Screencopy with DMA-BUF buffers (`linux_dmabuf`) | not tested; grim uses shared memory |
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

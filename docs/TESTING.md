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
- For Xwayland/client tests: `Xwayland`, libxcb development files and
  `wayland-scanner` (Arch: `xorg-xwayland libxcb wayland`). Session/protocol
  suites also need `swaylock`, `swayidle`, `wlr-randr`, and `cliphist`.
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
tests/pointer.sh                            # needs the -Dtest-input build
tests/captures.sh zig-out/test-input/bin     # pointer constraints and shortcut inhibitors
tests/navigation.sh                         # needs the -Dtest-input build (and grim for one scenario)
tests/screenshot.sh                         # needs the -Dtest-input build
tests/stress.sh                             # needs the -Dtest-input build
for suite in windows workspaces rules session outputs devices protocols shell taskbar xwayland data effects ipc; do
    tests/"$suite".sh zig-out/test-input/bin
done

zig build -Doptimize=ReleaseSafe -p zig-out/release && tests/smoke.sh zig-out/release/bin
```

Useful variables: `KEEP=1` keeps the temporary directory with all logs;
`ONLY=<substring>` runs only matching scenarios of `tests/input.sh`,
`tests/pointer.sh`, `tests/navigation.sh` and `tests/screenshot.sh`.
`tests/run.sh BIN_DIR LOG_DIR` runs all integration suites and preserves
complete logs plus numeric exit statuses. `SUITES="data effects"` selects a
subset; existing logs are never overwritten. The interaction suites share
their session helpers in
`tests/support/harness.sh`.

## v0.2 continuation coverage

The recovered-state ledger is [DEVELOPMENT.md](DEVELOPMENT.md); final candidate
acceptance and limitations are recorded separately from historical results.
The combined unit suite contains 38 Zig tests (12 core, 26 Lua host), plus
25 dwindle / 19 focus / 12 workspace / 10 rule Lua scenarios and 145 screenshot
checks. Negative keymap compilation deliberately logs xkb errors; that test
passes when the invalid keymap is rejected.

| Additional suite | Actual client-level assertions |
|---|---|
| `windows.sh` / `workspaces.sh` / `rules.sh` | 16 / 12 / 6 scenarios: layout/state/visibility/dialog reparenting, workspace/hotplug/reload, real rule policy |
| `session.sh` / `outputs.sh` / `devices.sh` | 9 / 7 / 3 scenarios: real locker/idle clients, output transactions/power/gamma, virtual device settings |
| `protocols.sh` / `shell.sh` | 8 / 16 scenarios: actual globals/filtering/selections and xdg initial-configure/decorations/state; activation enter/missing-source/expiry/replay/destruction regressions |
| `captures.sh` | 10 pointer lock/confine/relative/shortcut-inhibit scenarios with lifecycle and lock coverage |
| `taskbar.sh` | 9 foreign-toplevel/ext-workspace request/state/lifecycle scenarios |
| `xwayland.sh` | 6 actual XCB scenarios: X11 map/focus/move/resize/floating/state/workspace/menus, clipboard both directions, early/long-lived process crash, output hotplug; exact known upstream XWM BadWindow/property diagnostics are printed and allowed, all other errors fail |
| `data.sh` | 10 Wayland-client scenarios: UTF-8 DnD/icon/finish, outside cancellation, dead source/target, invalid serial, session lock, composition/surrounding/preedit/delete/focus, duplicate/replacement IME, candidate popup pixels/destruction and virtual-keyboard reinjection without feedback |
| `effects.sh` | 7 pixel/lifecycle scenarios: rectangle updates/input transparency/reload, native transform/cancel/interrupt, independent close/workspace snapshots, reentrant workspace removal, shipped visual example and initial rule opacity after reveal |
| `ipc.sh` | 3035 query/action/framing/subscription/resource/disconnect checks plus lock action gating and replacement-inode preservation; malformed JSON, nesting/size/time limits, client admission, slow consumer and fd stability |
| `package.sh ARCHIVE` | disposable extraction, payload hashes/provenance, no test-only code, binary help, installation/refusal/force/numbered backup/config preservation/symlink/argument checks, actual production registry and live raywmctl query |

All automated input is injected only into a private test compositor. Headless
GLES2 runs exercise the renderer through a render node; neither those runs nor
pixman passes establish physical DRM/KMS, monitors, input devices or real-toolkit
interoperability. An alternate-UID IPC connection test is SKIPPED without an
available second user; permissions and same-UID credential admission are tested,
and the mismatched-UID rejection is reviewed in the native code. DMA-BUF capture,
real IME frameworks (fcitx/ibus), GTK/Qt DnD combinations, Steam/gaming, sanitizers
and physical input-to-photon latency remain SKIPPED. Follow
[HARDWARE-TESTING.md](HARDWARE-TESTING.md) before trusting a hardware session.

## Test suites

`tests/captures.sh` adds ten real-client scenarios for pointer locking,
confinement, relative motion, shortcut inhibition, oneshot and persistent
lifetime, client destruction, region updates and holes, cursor hints,
plugin warps, emergency capture release, and session-lock interactions.
Its default build directory is `zig-out/test-input/bin`; an alternate
test build directory can be passed as its first argument.

| Suite | Kind | What it covers |
|---|---|---|
| `tests/core_test.zig` | Zig unit (12) | configure serial wrap-around, key spec parsing (including the screenshot plugin's `Print` bindings, with real xkb), **the keysym used for bindings with real xkb keymaps** (`us,ru` with either layout active, `ru,us`, `ru` alone, `de,us`), coordinate clamping, `spawn` (no zombie, unblocked signals) |
| `tests/lua_test.zig` | Zig unit (26), fake compositor | the plugin contract (api version, rejection), dispatch, error isolation, deferred cleanup, cancellation during dispatch, stale/invalid ids, timers (injected clock), memory and instruction limits incl. `pcall`/coroutine bypass attempts (also via a coroutine created before the budget ran out), no `debug` library and no native module loading, nested dispatch depth limit, duplicate bindings, setup/teardown failures, reload (from a binding, init.lua, teardown, 25× with flat memory, failed reload), `ctx.manage` lifecycle, registration cap; **v0.1.2:** `raywm.pointer`, `pointer_warp` (incl. a refused warp), `view_border` (stale ids, bad widths and colors), `view().visible`, premultiplied color parsing, the duplicate-binding warning (once per plugin) and the no-bindings warning, binding thousands of keys in a loop without quadratic native work |
| `tests/dwindle_test.lua` | Lua (25), mock API that follows the core's rules | layouts with 1–5, 10 and 20 windows; focus-based insertion; closing in every order (tree collapse); output resize, panels, two outputs and unplugging; geometry cache and externally moved windows; managed-window registration; tiny geometries; stale windows; reload and hostile snapshot files; **20 fixed-seed random sequences × 300 operations**, checking after every step that each window has exactly one leaf, parent links hold, every leaf is a live window, managed set = tiled set, no negative sizes, everything inside the usable area, no overlaps except in deliberately shared sub-pixel areas |
| `tests/focus_test.lua` | Lua (19), mock API that follows the core's rules | the six bindings and their fixed registration order; directional focus with dwindle layouts of 2, 3 and 4 windows (ties broken by recency); windows directly beside beat diagonal ones, nearer beats better aligned; spanning/enclosing windows are in no direction; hidden windows; nothing focused; two outputs side by side and stacked (same output first, only the output in that direction, `cross_output = false`); the cycle order across outputs, wrapping, closed and hidden windows; warp off by default, to the centre only on a real change and not when the pointer is already inside, never while busy; the border following focus, removed on focus 0 and on teardown, a bordered window closing; reload without duplicate registrations; **400 random two-output layouts** checking every choice is visible, in that direction, on the same output whenever possible, never on an output in another direction, and deterministic |
| `tests/screenshot_test.lua` | Lua (145 checks), mock API + `/bin/sh` with fake grim/slurp/wl-copy/notify-send | the five bindings and no key bound twice across binds.lua, dwindle.lua, focus.lua and screenshot.lua (nor over the core's fallback or VT keys); unload leaves nothing, other plugins untouched; reload; setup and callbacks call no blocking function (`os.execute`, `io.*`, ...) and spawn exactly one command; argument layout per action; directory choice (`XDG_PICTURES_DIR` absolute/relative/empty/trailing slash, `HOME`, `options.dir`, NUL bytes); the generated commands executed by `/bin/sh` against a directory name full of shell syntax (`$(...)`, backticks, quotes, `;`, newline, leading `-`, `*`): the file lands exactly there and nothing is executed; unique names with no temporary files left; mode 0600; region geometry passed to grim; cancel saves, runs and reports nothing; clipboard gets the PNG with `--type image/png`; each missing tool gives a logged error and a notification; no notify-send; grim failure; no `WAYLAND_DISPLAY`; no directory; `notify = false` |
| `tests/smoke.sh` | Wayland, real client | connection, xdg toplevel configure/ack, buffer commit, frame callback, a toplevel re-created on the same `xdg_surface`, asynchronous resize by dwindle with position applied on ack, a layer-shell panel and its exclusive zone, Lua event order, children with unblocked signals, clean SIGTERM exit |
| `tests/focus.sh` | Wayland, two clients at once | focus seen by clients (`xdg_toplevel` activated state): a new window takes focus, focus returns on close, a plugin overriding focus in `view_map`, dwindle insertion + focus |
| `tests/docs.sh` | Wayland | every plugin example in `docs/API.md` loads and runs |
| `tests/input.sh` | Wayland + **real pointer/keyboard events** (virtual input) | 12 scenarios: floating Super+drag move and resize; client-side title-bar move; managed windows refuse all three while clicks still focus; binding keys never reported as held to the newly focused client (since v0.1.2 with focus.lua's Super+H); second `view_place` before ack; clamped extreme coordinates; window becoming managed mid-drag; extra buttons during a grab; panel crash and window crash re-tiling; a layer surface releasing the keyboard; **v0.1.1:** a pointer removed in the middle of Super+drag, a client-side move and Super+resize (the grab ends, later presses reach the client); an on-demand overlay surface not taking the keyboard from an exclusive one, a higher exclusive one taking it and giving it back to the first, not to the window; a toplevel destroyed while its popup is open, with a nested popup racing the destruction (`MALLOC_PERTURB_` makes a use-after-free crash) and a click afterwards reaching no dead popup; the seat's active keyboard unplugged while another remains |
| `tests/pointer.sh` | Wayland + **real pointer events**, clients that log every `wl_pointer` event (enter, leave, motion with surface-local coordinates, button) | 13 scenarios of the **implicit pointer grab**, each comparing exact event streams: press in A, drag across B, release over B (A gets every motion, outside its bounds, and the release; B nothing until after it); several buttons (the grab ends with the last release); release outside every surface; a subsurface keeps the grab over its parent and outside; a layer-shell panel keeps it over a window; a popup destroyed on press (no events to anyone until the release); a window killed with `SIGKILL` while held; plugins moving the grabbed window away and another under the cursor (coordinates follow the window; no focus change); the second output unplugged while held; client-side move and resize; Super+click while a client holds a button goes to the client; Super+drag sends neither press nor release; an `xdg_popup` grab still routes to the popup and is dismissed by a click elsewhere. **11 of the 13 fail on v0.1.1** (the other two guard unchanged behaviour) |
| `tests/navigation.sh` | Wayland + **real key and pointer events** | 11 scenarios: Super+H/L with a `us,ru` keymap and Russian active (fails on v0.1.1), `raywm -d` key trace, plain typing never logged; dwindle Super+H/J/K/L and Super+Tab/Shift+Tab with geometry unchanged and no key reaching a client; two outputs (crossing only in that direction, the cycle across outputs); pointer warp to the window centres, and no warp while a button is held (the window keeps the pointer and gets the release); the focus border on screen (grim + PNG pixels, before and after a focus change); reload during a held button (grab survives, 6 bindings once, no warnings); edited bindings applied by reload and clicks afterwards; an exclusive launcher keeps keyboard and pointer while focus keys work; Super+Q closing the window whose button is held; an unchanged v0.1.1 config (dwindle Super+J/K) and a half-migrated one (one clear warning) |
| `tests/screenshot.sh` | Wayland + real **grim, slurp, wl-copy, wl-paste**, real key presses | 8 scenarios. A client draws opaque quadrants (red, green, blue, white) at a known position; every PNG is decoded (`tests/support/png_check.py`: signature, chunk CRCs, zlib stream, every filter) and its size and pixels are checked: Print and Ctrl+Alt+P full screenshots (distinct names, mode 0600, notification, no temporary files); Shift+Print with a real slurp drag (exact crop); Escape cancels (no file, no grim, no notification; the next shot works); Ctrl+Print and Ctrl+Shift+Print, read back with wl-paste as `image/png`; two outputs (full layout, a region on the second, and **a slurp selection dragged across both**, which needs the implicit grab and fails on v0.1.1); an output unplugged while a capture is pending (`raywm-test-screencopy`: the copy fails cleanly, a new request for the removed output fails, a copy racing the unplug ends either way, no crash); plugin removed by reload (keys gone, other plugins work, reload back works); a window whose geometry excludes a 10 px shadow lands exactly at its position. Every tool is wrapped to record `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR`; the test fails if any ran outside the test session |
| `tests/stress.sh` | Wayland, bounded | 100 window cycles; 20 waves of 8 `SIGKILL`ed clients; 40 reloads with a plugin failing on each map; 1500 geometry changes in 3 s; clean shutdown; compositor RSS per phase (fails above +16 MiB) |

Each fix found by the pre-release audits was checked by reverting it and
confirming that its test fails. For v0.1.2 this was done for the
implicit grab (`tests/pointer.sh` against the v0.1.1 core: 11 of 13
scenarios fail), the layout rule for bindings (`tests/navigation.sh`
scenario 1 failed before the fix: the J key reached the window) and the
cross-output slurp selection (`tests/screenshot.sh` against v0.1.1: no
screenshot). For v0.1.1 this was done for the popup
fixes (both parts separately), the layer focus rule, the keyboard
handover, the geometry offset and the plugin's quoting (replacing it
with naive double quotes fails the injection checks).

### Virtual input (test builds only)

`zig build -Dtest-input` links `tests/support/virtual_input.zig` into
the compositor. It exposes the wlroots virtual pointer protocol; the
virtual keyboard protocol is also used by production input methods.
`tests/input_driver.zig` uses them to move the
pointer, press buttons and type keys. The test compositor runs on its
own socket in a private runtime directory, so this input reaches only
the test clients. Such builds log `TEST BUILD` at startup, and release
packaging refuses binaries that contain this code.

Test builds also unplug an output on `SIGUSR2` (the output named in
`$XDG_RUNTIME_DIR/raywm-test-unplug`), so `tests/screenshot.sh` can
remove an output while a capture is pending, and build
`raywm-test-screencopy`, a minimal wlr-screencopy client.

## Historical developer-reported results (v0.1.2)

These historical results were recovered from the earlier developer. Fresh
same-host continuation samples are in [PERFORMANCE.md](PERFORMANCE.md).

Arch Linux (kernel 7.2, zen), x86_64, wlroots 0.20.2, Lua 5.4.9,
Zig 0.16.0, grim 1.5.0, slurp 1.5.0, wl-clipboard 2.3.0, with a GPU
render node (GLES2 available):

| Suite | Pixman | GLES2 |
|---|---|---|
| unit (Zig 25 + dwindle 17 + focus 19 + screenshot 105 checks) | pass | — |
| smoke (Debug and ReleaseSafe) | pass | pass (Debug) |
| focus | pass | pass |
| docs (5 examples) | pass | pass |
| input (12 scenarios) | pass | pass |
| pointer (13 scenarios) | pass | pass |
| navigation (11 scenarios) | pass | pass |
| screenshot (8 scenarios) | pass | pass |
| stress | pass, RSS +1.0 MiB | pass, RSS +0.8 MiB |

Performance, measured with ReleaseSafe test builds of v0.1.1 and v0.1.2
on the same machine (headless, pixman, three windows, 20 000 absolute
motion events per sample through the virtual pointer, each followed by
a client roundtrip; six samples per version and mode; CPU is user +
system time of the raywm process from `/proc`, in 10 ms ticks):

| | v0.1.1 | v0.1.2 |
|---|---|---|
| compositor CPU, pointer moving freely across windows | 300–510 ms per 20 000 events | 300–470 ms |
| compositor CPU, the same with a button held | 230–460 ms | 260–460 ms |
| driver wall time per event (incl. roundtrip), both modes | 26–45 µs | 26–43 µs |
| compositor RSS after the samples | 15.3–15.4 MiB | 15.4–15.6 MiB |

The difference is within the run-to-run noise (±40 %); no change was
measurable. While a button is held, v0.1.2 skips the scene hit-test and
only computes the surface's position. Directional focus (`focus.lua`,
Lua side, one key press) costs 22 µs with 10 windows, 95 µs with 50 and
1.8 ms with 1000 (linear); it runs only on key presses, never per frame
or per motion.

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
| Screenshots in a real (non-headless) session: the Print key on a real keyboard, slurp with a real mouse, a real notification daemon, clipboard managers | **not verified manually for v0.1.2**; the same programs and code paths are tested headlessly with virtual input |
| Implicit grab and focus keys with real toolkits (GTK, Qt, Firefox: text selection, scrollbars, menus opened on press) | not verified manually; the protocol behaviour is checked with the test client, which logs every event |
| A nested session in a desktop that keeps Super+letter keys (the outer compositor may never forward Super+J/K) | not testable headlessly; `raywm -d` shows whether a key arrives |
| Real GTK/Qt/X11 drag-and-drop combinations | SKIPPED; native Wayland client transfer/cancel/destruction/lock cases pass automatically |
| Screencopy with DMA-BUF buffers (`linux_dmabuf`) | not tested; grim uses shared memory |
| Physical HiDPI / output scaling | SKIPPED; native scale/transform and protocol tests use headless outputs |
| Memory errors with sanitizers | not available: no valgrind on the development machine, and AddressSanitizer is not usable with this Zig/C setup. Long runs were checked with RSS measurements only |

### Manual test procedure (before trusting a new build on real hardware)

1. Nested: `raywm -s foot`.
   - Open three terminals with Super+Return; check the dwindle spiral.
   - Super+H/J/K/L moves focus between the tiles (a blue border marks
     the focused window); Super+Tab cycles.
   - Select text in one terminal and drag far outside it, over another
     terminal: the selection keeps growing until you release.
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

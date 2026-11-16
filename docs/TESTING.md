# Testing RayWM

The Zig automated tests run **headless**:
- in a private `XDG_RUNTIME_DIR`, with a scrubbed environment (`env -i`);
- with a virtual output (`WLR_BACKENDS=headless`);
- with no real input devices.

They never connect to, or inject input into, your running desktop
session.

## Experimental Rust foundation

The `rust/` workspace preserves the current Zig desktop and tests. Its build,
CLI and nested launch are in [INSTALL.md](INSTALL.md#experimental-rust-foundation);
architecture, historical baselines and qualification limits are in
[RUST_MIGRATION.md](RUST_MIGRATION.md).

From `rust/` (validated with Rust/Cargo 1.99.1):

```sh
cargo fmt --all -- --check
cargo check --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo build --workspace --locked
# Additional renderer-free regression checks:
cargo clippy --workspace --all-targets --no-default-features --locked -- -D warnings
cargo test --workspace --no-default-features --locked
```

The default tests comprise seven core tests and eleven real headless process/
protocol tests; Stage 4B's DnD/icon and reactive-popup tests are graphical and
therefore ignored in that run. They cover ID deletion/non-reuse/exhaustion, geometry and
focus, cascade/stack/fallback policy, all resize edges, size limits, anchored
commit geometry and operation cancellation; registry/sync, shm and synchronized subsurface buffer lifetimes;
initial configure/ACK, map/unmap/remap and role recreation; premature-buffer/
invalid-ACK isolation; disconnect, SIGINT/SIGTERM, socket ownership/cleanup and
bad runtime/CLI/nested startup paths. Stage 3 adds three independent clients,
rapid role creation/destruction, popup configure/ACK and reposition tokens,
nested/ancestor cleanup, early-buffer isolation and correct wm_base errors for
invalid/self/roleless parents. Stage 4A adds the data-device and primary
selection manager globals/versions, source offer/destroy ordering and
isolation from a following client. Stage 4B's Rust tests add negotiated drag
targets, actions, icon lifecycle and reactive popup configure/ACK/pixel checks;
they are compiled only with the Winit feature because they need a seat, grab
and output. Protocol errors printed by negative
cases are expected; the connection is rejected and a fresh client still works.
Each process has a scrubbed environment, private mode-0700 runtime directory,
bounded waits and a kill/reap guard. Headless mode sends no fabricated frames.

The Stage 2/3 graphical tests, the Stage 4A selection test and the two Stage 4B
DnD/popup tests are explicitly ignored by default because they need a parent.
Run them through the separate harnesses from the repository root:

```sh
# Requires the unchanged Zig -Dtest-input build, Python 3 and grim.
python3 rust/tests/nested-smoke.py
python3 rust/tests/nested-smoke.py --stage3
# Additionally needs foot and wl-clipboard (wl-copy/wl-paste).
python3 rust/tests/selection-smoke.py
# Additionally needs gcc, g++, pkg-config, GTK4 and Qt6 development files.
python3 rust/tests/stage4b-smoke.py
```

The harness builds the Rust test/binary with Cargo.lock, creates a private
headless pixman Zig parent, then starts Winit with software EGL/GLES in a
separate runtime. Its client uses actual XDG/shm/seat/output requests; parent
PNG screenshots check four color quadrants and orientation before/after
800x600 → 700x500 resize. Assertions cover configure/ACK, frame callbacks,
output enter/leave/mode, no callback for a bufferless child surface,
key/button press/release, pointer motion, unmap focus
cleanup and process/socket/lock destruction. All virtual input and screen
capture target only the newly created parent. Test-only RAYWM_SMOKE_SOCKET
and RAYWM_SMOKE_CONTROL are set by this harness, never inferred from the user's
display. Missing tools and failed observations cause a nonzero exit, not a pass.
The script prints a new `/tmp/raywm-stage2-*`, `/tmp/raywm-stage3-*`,
`/tmp/raywm-stage4-*` or `/tmp/raywm-stage4b-*` directory containing logs/PNGs. The Stage 3 and 4A
scenarios keep a parent seat alive throughout the test: removing the last
virtual keyboard would legitimately remove Winit host focus and invalidate the
new-map focus precondition.

Stage 3 asserts actual three-window overlap pixels, initial/click/fallback
Activated and keyboard focus, exclusive key delivery, valid move and rejected
stale/foreign serials, top-left/min and bottom-right/max resize, bounded
configure traffic during withheld ACK and final committed anchor pixels. It
checks nested popup constraints, local pointer coordinates, key routing,
reposition tokens/pixels, outside-click, parent destruction while held, keyboard
serial invocation, new-map isolation, popup disconnect, resize unmap/remap and
mid-resize disconnect without release leakage into a new client. Three unchanged
independent Zig clients additionally check concurrent rendering and a CSD move
from a real synchronized subsurface. Screenshot
barriers wait for real submitted frame callbacks. All helpers have bounded
waits and child cleanup. Evidence is in
[the Stage 3 qualification record](measurements/v0.3.0/stage3/qualification.md).

The Stage 4B harness keeps one virtual-pointer process alive per gesture so a
real implicit grab spans the whole press/move/release sequence. It verifies
forged/stale drag serials, target switching, source action negotiation
(copy/move/ask), MIME payloads, EPIPE containment, drop/finish once,
cancel/destroy/drop icon removal, source/target disconnect, clipboard during
DnD and a fresh drag after teardown. Its popup scenario checks parent move,
output 800x600 → 700x500, nested popup following, bottom-right resize without
configure churn, a reposition token, unmap/remap and destruction with an
unACKed configure, using real popup events and submitted pixels. The same
harness runs GTK4 → Qt6 and Qt6 → GTK4 pointer-driven DnD with payload files,
cancellation, source/target close mid-drag and context-menu popups. The Qt
nested submenu and GTK primary-selection attempts are recorded as BLOCKED, not
passed; Qt primary selection passes. Evidence is in
[the Stage 4B qualification record](measurements/v0.3.0/stage4b/qualification.md).

The Stage 4A harness runs two independent Wayland clients with real focus
gates. It verifies clipboard and primary-selection ownership, distinct payloads
per MIME type, unfocused receivers, empty selection, forged/stale serial
rejection, data-device recreation, source destruction, early pipe close,
unoffered MIME types, unmap/remap, popup dismissal with a live selection and
receiver/source disconnect. It then qualifies foot (map/render, keyboard input,
mouse selection to primary, copy to `wl-paste` and paste from `wl-copy`).
Minimal GTK4 and Qt6 probes, compiled against installed development files when
present, additionally check map/render, typed text, copy to `wl-paste` and paste
from `wl-copy`. Every process/socket/lock is cleaned up. Evidence is in
[the Stage 4A qualification record](measurements/v0.3.0/stage4a/qualification.md).

This qualifies a nested software renderer, basic input, the standard
clipboard/primary-selection paths and client-initiated DnD with drag icons. It
does not qualify physical hardware, server-side DnD, a full toolkit application
matrix or desktop parity. No Lua/IPC/config/IME/Xwayland
services are ported in Stages 1–4A. Rust checks remain local commands, not
additional release or CI jobs.

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
tests/docs-sync.sh                          # docs cover the public surface

zig build                                   # Debug build  -> zig-out/bin
zig build -Dtest-input -p zig-out/test-input # TEST build with virtual input
timeout 600 zig build test --summary all   # unit tests (Zig + Lua); bounded: some regressions are infinite loops

tests/smoke.sh                              # each script: RENDERER=gles2 to use GLES2
tests/focus.sh
tests/docs.sh
tests/input.sh                              # needs the -Dtest-input build
tests/pointer.sh                            # needs the -Dtest-input build
tests/captures.sh zig-out/test-input/bin     # pointer constraints and shortcut inhibitors
tests/navigation.sh                         # needs the -Dtest-input build (and grim for one scenario)
tests/screenshot.sh                         # needs the -Dtest-input build
tests/stress.sh                             # needs the -Dtest-input build
for suite in windows workspaces rules session outputs devices protocols shell taskbar xwayland data effects ipc perf conf; do
    tests/"$suite".sh zig-out/test-input/bin
done
tests/release-meta.sh
tests/update.sh                             # as a normal user (as root: only the root check)

zig build -Doptimize=ReleaseSafe -p zig-out/release && tests/smoke.sh zig-out/release/bin
```

Useful variables: `KEEP=1` keeps the temporary directory with all logs;
`ONLY=<substring>` runs only matching scenarios of `tests/input.sh`,
`tests/pointer.sh`, `tests/navigation.sh` and `tests/screenshot.sh`.
`tests/run.sh BIN_DIR LOG_DIR` runs all integration suites (and the
`docs-sync` check) and preserves
complete logs plus numeric exit statuses. `SUITES="data effects"` selects a
subset; existing logs are never overwritten. The interaction suites share
their session helpers in
`tests/support/harness.sh`.

## v0.2 continuation coverage

The recovered-state ledger is [DEVELOPMENT.md](DEVELOPMENT.md); final candidate
acceptance and limitations are recorded separately from historical results.
The combined unit suite contains 47 Zig tests (13 core, 34 Lua host), plus
25 dwindle / 19 focus / 12 workspace / 10 rule Lua scenarios and 145 screenshot
checks. Negative keymap compilation deliberately logs xkb errors; that test
passes when the invalid keymap is rejected.

| Additional suite | Actual client-level assertions |
|---|---|
| `windows.sh` / `workspaces.sh` / `rules.sh` | 17 / 15 / 6 scenarios: layout/state/visibility/dialog reparenting, pinned stacking, workspace/hotplug/reload, special overlays and sticky windows, real rule policy |
| `session.sh` / `outputs.sh` / `devices.sh` | 10 / 7 / 3 scenarios: real locker/idle clients, output transactions/power/gamma, virtual device settings, and a layer surface destroyed while locked |
| `protocols.sh` / `shell.sh` | 8 / 16 scenarios: actual globals/filtering/selections and xdg initial-configure/decorations/state; activation enter/missing-source/expiry/replay/destruction regressions |
| `captures.sh` | 10 pointer lock/confine/relative/shortcut-inhibit scenarios with lifecycle and lock coverage |
| `taskbar.sh` | 9 foreign-toplevel/ext-workspace request/state/lifecycle scenarios |
| `xwayland.sh` | 8 actual XCB scenarios: X11 map/focus/move/resize/floating/state/workspace/menus, clipboard both directions, early/long-lived process crash, output hotplug, windows fullscreen/maximized before their first map (v0.2.1); exact known upstream XWM BadWindow/property diagnostics are printed and allowed, all other errors fail |
| `data.sh` | 10 Wayland-client scenarios: UTF-8 DnD/icon/finish, outside cancellation, dead source/target, invalid serial, session lock, composition/surrounding/preedit/delete/focus, duplicate/replacement IME, candidate popup pixels/destruction and virtual-keyboard reinjection without feedback |
| `effects.sh` | 9 pixel/lifecycle scenarios: rectangle updates/input transparency/reload, native transform/cancel/interrupt, independent close/workspace snapshots, reentrant workspace removal, shipped visual example, initial rule opacity after reveal, completed animation ownership across more than 256 distinct windows, and plugin unload resetting a completed transform |
| `ipc.sh` | 3053 query/action/framing/subscription/resource/disconnect checks plus lock action gating and replacement-inode preservation; malformed JSON (including trailing commas/sequences after the root), nesting/size/time limits, client admission, slow consumer and fd stability; the connection and compositor stay usable after every bad message |
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

`tests/captures.sh` adds eleven real-client scenarios for pointer locking,
confinement, relative motion, shortcut inhibition, oneshot and persistent
lifetime, client destruction, region updates and holes (including a ONESHOT
region commit), cursor hints, plugin warps, emergency capture release, and
session-lock interactions.
Its default build directory is `zig-out/test-input/bin`; an alternate
test build directory can be passed as its first argument.

| Suite | Kind | What it covers |
|---|---|---|
| `tests/core_test.zig` | Zig unit (13) | configure serial wrap-around, key spec parsing (including the screenshot plugin's `Print` bindings, with real xkb), **the keysym used for bindings with real xkb keymaps** (`us,ru` with either layout active, `ru,us`, `ru` alone, `de,us`), coordinate clamping, `spawn` (no zombie, unblocked signals), the IPC JSON envelope (separators/trailing commas/second values/nesting rejected before the parser) |
| `tests/lua_test.zig` | Zig unit (34), fake compositor | the plugin contract (api version, rejection), dispatch, error isolation, deferred cleanup, cancellation during dispatch, stale/invalid ids, timers (injected clock), memory and instruction limits incl. `pcall`/coroutine bypass attempts (also via a coroutine created before the budget ran out), one shared budget per dispatched event (the next event starts fresh), nested-budget attribution (the hog or the nested runaway is unloaded, an innocent caller is not), `coroutine.create`/`wrap`/nested/load-time hooks, a thread created or resumed without a hook being re-armed, and normal `yield`/`resume`/errors, no `debug` library and no native module loading, nested dispatch depth limit, duplicate bindings, setup/teardown failures, reload (from a binding, init.lua, teardown, 25× with flat memory, failed reload), `ctx.manage` lifecycle, registration cap; **v0.1.2:** `raywm.pointer`, `pointer_warp` (incl. a refused warp), `view_border` (stale ids, bad widths and colors), `view().visible`, premultiplied color parsing, the duplicate-binding warning (once per plugin) and the no-bindings warning, binding thousands of keys in a loop without quadratic native work |
| `tests/dwindle_test.lua` | Lua (25), mock API that follows the core's rules | layouts with 1–5, 10 and 20 windows; focus-based insertion; closing in every order (tree collapse); output resize, panels, two outputs and unplugging; geometry cache and externally moved windows; managed-window registration; tiny geometries; stale windows; reload and hostile snapshot files; **20 fixed-seed random sequences × 300 operations**, checking after every step that each window has exactly one leaf, parent links hold, every leaf is a live window, managed set = tiled set, no negative sizes, everything inside the usable area, no overlaps except in deliberately shared sub-pixel areas |
| `tests/focus_test.lua` | Lua (19), mock API that follows the core's rules | the six bindings and their fixed registration order; directional focus with dwindle layouts of 2, 3 and 4 windows (ties broken by recency); windows directly beside beat diagonal ones, nearer beats better aligned; spanning/enclosing windows are in no direction; hidden windows; nothing focused; two outputs side by side and stacked (same output first, only the output in that direction, `cross_output = false`); the cycle order across outputs, wrapping, closed and hidden windows; warp off by default, to the centre only on a real change and not when the pointer is already inside, never while busy; the border following focus, removed on focus 0 and on teardown, a bordered window closing; reload without duplicate registrations; **400 random two-output layouts** checking every choice is visible, in that direction, on the same output whenever possible, never on an output in another direction, and deterministic |
| `tests/screenshot_test.lua` | Lua (145 checks), mock API + `/bin/sh` with fake grim/slurp/wl-copy/notify-send | the five bindings and no key bound twice across binds.lua, dwindle.lua, focus.lua and screenshot.lua (nor over the core's fallback or VT keys); unload leaves nothing, other plugins untouched; reload; setup and callbacks call no blocking function (`os.execute`, `io.*`, ...) and spawn exactly one command; argument layout per action; directory choice (`XDG_PICTURES_DIR` absolute/relative/empty/trailing slash, `HOME`, `options.dir`, NUL bytes); the generated commands executed by `/bin/sh` against a directory name full of shell syntax (`$(...)`, backticks, quotes, `;`, newline, leading `-`, `*`): the file lands exactly there and nothing is executed; unique names with no temporary files left; mode 0600; region geometry passed to grim; cancel saves, runs and reports nothing; clipboard gets the PNG with `--type image/png`; each missing tool gives a logged error and a notification; no notify-send; grim failure; no `WAYLAND_DISPLAY`; no directory; `notify = false` |
| `tests/smoke.sh` | Wayland, real client | connection, xdg toplevel configure/ack, buffer commit, frame callback, a toplevel re-created on the same `xdg_surface`, asynchronous resize by dwindle with position applied on ack, a layer-shell panel and its exclusive zone, Lua event order, children with unblocked signals, clean SIGTERM exit |
| `tests/focus.sh` | Wayland, two clients at once | focus seen by clients (`xdg_toplevel` activated state): a new window takes focus, focus returns on close, a plugin overriding focus in `view_map`, dwindle insertion + focus. Every step waits (bounded) for an observable state instead of a sleep: B stays mapped until the compositor's event log shows A committed its half (v0.2.2; before, B could close before A acked the 628×704 configure, and A legitimately skipped it) |
| `src/conf.zig` | Zig unit (17) | ray.conf: defaults equal v0.2.1, every value type, comments, CRLF, syntax errors with line numbers rejecting the whole file, unknown keys/sections as warnings, invalid values and ranges, string limits, duplicate keys, bounded diagnostics, layering, restart-only detection, the shipped `config/ray.conf` |
| `tests/conf.sh` | Wayland + real input (test build) | 13 scenarios: `raywm -t` (defaults, valid, unknown keys, line-numbered errors, system/user layers, broken system file); gaps reaching dwindle; reload applying a changed file, keeping the previous settings for a broken one, recovering; 41 reloads with plugin/binding counts and RSS growth < 512 KiB after warm-up; `focus_new_windows = false`; `mouse_modifier = alt` (Alt+drag moves, Super+drag is a click) and the default; `focus_follows_mouse` on (once per entry) and off; `xwayland = false` and the restart-only warning; system file under the user's; v0.2.1 plugins next to ray.conf; no file at all; `[autostart] exec` entries in `raywm -t` |
| `src/update.zig` | Zig unit (8) | raywm-update: tag scheme, asset names, channel rules, `update.conf` parsing, channel of a package version, download URL checks, release-list parsing (drafts, historical tags, flags, missing assets, foreign URLs, garbage), metadata cross-checks (12 contradicting edits) |
| `tests/update.sh` | raywm-update + scriptlet, local fixtures | 27 scenarios against a fake release list and assets (file:// URLs), a fake pacman and a fake Beta build, with the real curl, vercmp and tar: fresh Beta/Stable installs, the channel surviving Beta→Stable→Beta→Stable upgrades, reinstall and removal, Beta→Beta (non-root build), Beta→Stable (ready package, channel kept), Stable→Stable, Stable never offered a Beta, vercmp order (`0.2.10beta` over `0.2.9beta.3`), no update, pagination, corrupted archive and package, missing/404 assets, invalid metadata, API missing/garbage/unreachable, failed build, failed pacman, a package with files in `/etc`, confirmation and `--dry-run`, channel switching, missing/malformed/unreadable `update.conf`; the cache is empty and `~/.config/raywm` unchanged after each. As root: refuses to build a Beta |
| `tests/docs.sh` | Wayland | every plugin example in `docs/API.md` loads and runs |
| `tests/docs-sync.sh` | no build, no compositor | every `raywm.*`/`ctx.*` name and event in `src/lua.zig`, every setting in `src/conf.zig`, every IPC method in `src/ipc.zig` (also offered by `scripts/raywmctl`) and every option in `src/main.zig`'s usage text is documented, and every `*.zig` module named in the docs exists; run it after any change to that surface (AGENTS.md) |
| `tests/input.sh` | Wayland + **real pointer/keyboard events** (virtual input) | 12 scenarios: floating Super+drag move and resize; client-side title-bar move; managed windows refuse all three while clicks still focus; binding keys never reported as held to the newly focused client (since v0.1.2 with focus.lua's Super+H); second `view_place` before ack; clamped extreme coordinates; window becoming managed mid-drag; extra buttons during a grab; panel crash and window crash re-tiling; a layer surface releasing the keyboard; **v0.1.1:** a pointer removed in the middle of Super+drag, a client-side move and Super+resize (the grab ends, later presses reach the client); an on-demand overlay surface not taking the keyboard from an exclusive one, a higher exclusive one taking it and giving it back to the first, not to the window; a toplevel destroyed while its popup is open, with a nested popup racing the destruction (`MALLOC_PERTURB_` makes a use-after-free crash) and a click afterwards reaching no dead popup; the seat's active keyboard unplugged while another remains |
| `tests/pointer.sh` | Wayland + **real pointer events**, clients that log every `wl_pointer` event (enter, leave, motion with surface-local coordinates, button) | 13 scenarios of the **implicit pointer grab**, each comparing exact event streams: press in A, drag across B, release over B (A gets every motion, outside its bounds, and the release; B nothing until after it); several buttons (the grab ends with the last release); release outside every surface; a subsurface keeps the grab over its parent and outside; a layer-shell panel keeps it over a window; a popup destroyed on press (no events to anyone until the release); a window killed with `SIGKILL` while held; plugins moving the grabbed window away and another under the cursor (coordinates follow the window; no focus change); the second output unplugged while held; client-side move and resize; Super+click while a client holds a button goes to the client; Super+drag sends neither press nor release; an `xdg_popup` grab still routes to the popup and is dismissed by a click elsewhere. **11 of the 13 fail on v0.1.1** (the other two guard unchanged behaviour) |
| `tests/navigation.sh` | Wayland + **real key and pointer events** | 11 scenarios: Super+H/L with a `us,ru` keymap and Russian active (fails on v0.1.1), `raywm -d` key trace, plain typing never logged; dwindle Super+H/J/K/L and Super+Tab/Shift+Tab with geometry unchanged and no key reaching a client; two outputs (crossing only in that direction, the cycle across outputs); pointer warp to the window centres, and no warp while a button is held (the window keeps the pointer and gets the release); the focus border on screen (grim + PNG pixels, before and after a focus change); reload during a held button (grab survives, 6 bindings once, no warnings); edited bindings applied by reload and clicks afterwards; an exclusive launcher keeps keyboard and pointer while focus keys work; Super+Q closing the window whose button is held; an unchanged v0.1.1 config (dwindle Super+J/K) and a half-migrated one (one clear warning) |
| `tests/screenshot.sh` | Wayland + real **grim, slurp, wl-copy, wl-paste**, real key presses | 8 scenarios. A client draws opaque quadrants (red, green, blue, white) at a known position; every PNG is decoded (`tests/support/png_check.py`: signature, chunk CRCs, zlib stream, every filter) and its size and pixels are checked: Print and Ctrl+Alt+P full screenshots (distinct names, mode 0600, notification, no temporary files); Shift+Print with a real slurp drag (exact crop); Escape cancels (no file, no grim, no notification; the next shot works); Ctrl+Print and Ctrl+Shift+Print, read back with wl-paste as `image/png`; two outputs (full layout, a region on the second, and **a slurp selection dragged across both**, which needs the implicit grab and fails on v0.1.1); an output unplugged while a capture is pending (`raywm-test-screencopy`: the copy fails cleanly, a new request for the removed output fails, a copy racing the unplug ends either way, no crash); plugin removed by reload (keys gone, other plugins work, reload back works); a window whose geometry excludes a 10 px shadow lands exactly at its position. Every tool is wrapped to record `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR`; the test fails if any ran outside the test session |
| `tests/perf.sh` | Wayland, gaming path (v0.2.1) | 8 scenarios with `raywm-test-perf` (an uncapped or frame-callback-paced client and a passive taskbar) and `raywmctl perf`: an unchanged desktop does not commit; uncapped fullscreen client gets truthful presentation feedback (monotonic, never in the future, presented ≤ committed) and a taskbar receives a bounded number of events (v0.2.0 sent title+app_id+done per window per client commit); one frame callback per presented frame; animations return to idle; tearing only with `allow_tearing` and an async hint on a fullscreen window; session lock and output unplug during uncapped rendering; perf IPC with disconnecting clients. No FPS thresholds |
| `tests/gaming_bench.py` | samples, not a test | records headless commit/present/CPU samples for one build (`BIN CONFIG PERF_CLIENT OUT.json [pixman\|gles2] [RUNS] [SECONDS]`) for before/after comparisons; raw JSON kept |
| `tests/release-meta.sh` | release scripts | tag scheme, pacman `vercmp` order of beta/stable versions, `raywm-release.json`, CHANGELOG notes |
| `tests/release-archive.sh ARCHIVE TAG [--build]` | release asset | Beta source archive: layout, required files, vendored Zig dependencies, no binaries or CI/agent files, version; `--build` builds and runs unit tests from it (network-isolated when possible) |
| `tests/release-package.sh PKG TAG` | release asset | pacman package (the Stable asset, or built from a Beta archive): metadata, dependencies, file list (`raywm-update`, `ray.conf`, nothing in `/etc`), the channel scriptlet, baseline-CPU binary without test code, packaged `ray.conf` valid, headless start with the packaged configuration |
| `tests/release-install.sh PKG TAG` | release asset, root, CI container only | real `pacman -U`, reinstall, `-R`, install again: `/etc/raywm/update.conf` created once with the package's channel, not owned by the package, kept across all of them, switched by `raywm-update --set-channel` |
| `tests/stress/run.sh` | torture suite, FAST/STRESS/SOAK | seeded chaos clients, compositor-side chaos, random input, failing plugins, config fuzzing, update attacks, hotplug, crashes, perf against a baseline, soaks; see [TORTURE.md](TORTURE.md) |
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

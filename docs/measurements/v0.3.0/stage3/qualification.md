# Stage 3 floating compositor qualification

Status: **PASS for the Stage 3 nested/software scope**. This is migration work
on `feature/rust-smithay`, not a release or a v0.3.0 Beta declaration. The Zig
desktop, packaging and protected branches remain unchanged. No push was made.
The core checkpoint is `1defd22`; `sources.sha256` binds this evidence to the
Rust implementation and harness sources without a self-referential commit hash.

The [migration architecture](../../../RUST_MIGRATION.md) describes ownership,
focus, configure transactions and the remaining parity gates. This record
contains the concrete tests, screenshots, corrections and file inventory.

## Environment and reproduction

- Rust/Cargo 1.99.1; Smithay pinned to `=0.7.0`, unchanged Cargo.lock.
- Private Zig 0.16.0 / wlroots headless pixman parent, 1280×720.
- Winit Wayland child output 800×600, scale 1; llvmpipe, EGL 1.5 / GLES 3.2,
  Mesa 26.2.5-arch1.1. See [backend metadata](backend.txt) and
  [environment/tool/binary hashes](environment.txt).
- Stage 3 run: `/tmp/raywm-stage3-amiv3uci`; Stage 2 regression run:
  `/tmp/raywm-stage2-43v8igas`. Full ephemeral parent/nested logs remain there.
- All inherited display variables are scrubbed. Virtual keyboard/pointer and
  `grim` target only the parent created by this invocation. No running desktop
  input, capture, installation or session/VT acquisition occurred.

From the repository root, after the unchanged Zig test-input build:

```sh
python3 rust/tests/nested-smoke.py
python3 rust/tests/nested-smoke.py --stage3
sha256sum -c docs/measurements/v0.3.0/stage3/sources.sha256
sha256sum -c docs/measurements/v0.3.0/stage3/images.sha256
```

The harness finds actual Cargo executables from JSON build messages. It uses
private runtime directories, bounded protocol/control/exit waits and reaps
children on success or failure. Stage 3 retains a virtual seat throughout the
scenario: removal of the last virtual keyboard legitimately clears host focus.
Window/popup screenshot barriers wait for a newly requested, individually tagged
frame callback from that surface after actual render submission. Withheld-ACK
screenshots deliberately inspect the still-committed previous geometry.
Independent Zig-client screenshots poll bounded pixel observations.

## Validation results

All commands returned zero:

| Check | Result |
|---|---|
| `cargo fmt --all -- --check` | PASS |
| `cargo check --workspace --locked` | PASS |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | PASS |
| `cargo test --workspace --locked` | PASS: 7 core + 10 real headless tests; 2 graphical tests ignored here and run separately |
| `cargo build --workspace --locked` | PASS |
| `cargo clippy --workspace --all-targets --no-default-features --locked -- -D warnings` | PASS |
| `cargo test --workspace --no-default-features --locked` | PASS: 7 core + 10 real headless tests; the original graphical test remains explicitly ignored |
| `cargo build --workspace --no-default-features --locked` | PASS |
| `tests/docs-sync.sh` | PASS: 54 API names, 28 events, 11 settings, 8 IPC methods, 5 options |
| Stage 2 graphics harness | PASS: original quadrants/orientation, 800×600 → 700×500, real key/pointer events, frame/output/unmap and socket/process cleanup |
| Stage 3 graphics harness | PASS: all 15 Rust-probe pixel stages, real client events, 3 existing independent Zig clients and final socket/process cleanup |
| `git diff --check` | PASS |
| Zig source/build/config/protocol/test equality against `568b3d7` | PASS; no Zig implementation or tests changed |

Expected protocol-error output in negative cases is intentional. The tests
assert the offending connection fails while healthy clients continue; invalid
parents report wm_base error 3 and premature buffers report xdg_surface error 3.
The original Stage 1/2 test observations and assertions are preserved.

The seven core tests cover checked ID exhaustion/non-reuse, map/focus/order,
cascade/fallback after middle removal, all eight resize edges/corners, min/max,
extreme arithmetic, delayed committed geometry, client rounding/anchor behavior,
intent coalescing and operation lifetime cancellation. Ten headless tests cover
the previous bootstrap/XDG cases plus three independent clients, repeated
map/unmap/remap, middle destruction, rapid create/destroy, abrupt disconnect,
popup initial ACK, nested geometry, reposition token, parent/ancestor cleanup,
unmapped parent rejection, self/roleless parent errors and client isolation.

The Stage 3 [wire probe log](protocol-probe.log) records successful phases.
The graphical assertions additionally cover initial/click/fallback activation,
exclusive key routing, root/subsurface/popup hit testing, valid held serials,
stale/foreign serial rejection, top-left/min and bottom-right/max resizing,
bounded configure flow without ACK, final anchor pixels, popup output bounds,
local pointer coordinates, keyboard focus, outside-click, reposition, parent
destruction while held, keyboard serial invocation, new-map grab isolation,
active popup disconnect, resize unmap/remap and disconnect during resize.
Newly mapped clients never receive an orphaned button release.

Three unchanged `zig-out/test-input/bin/raywm-test-client` processes then map
concurrently and receive real frames. The first renders a synchronized 60×60
subsurface, receives a pointer enter at local (10,10), and its existing CSD
handler successfully moves the root from that subsurface's held-button serial.
Pixels verify both the three-window arrangement and final moved content.
See [client 0](independent-0.log), [client 1](independent-1.log) and
[client 2](independent-2.log). All three exit successfully when Rust shuts down.
This is sufficient to qualify Stage 3 without adding data-device/clipboard.

## Screenshots and observed geometry

Each image captures the 1280×720 private parent; the Rust output occupies
its upper-left 800×600. The black remainder is outside the Rust output.

| Screenshot | Observation |
|---|---|
| [three.png](three.png) | Red root at (0,0), green at (48,48), blue at (96,96), each 320×240; all three visible |
| [focus.png](focus.png) | Click raises red over the previous blue/green overlap; only red receives the key |
| [moved.png](moved.png) | Red moves to (150,100) after a valid CSD-style request |
| [invalid-serial.png](invalid-serial.png) | Old serial and another client's live serial cannot move a root |
| [resize-unacked.png](resize-unacked.png) | Original committed rectangle persists while the resize configure is withheld |
| [resize-min.png](resize-min.png) | ACK/commit produces 220×150 at (250,190), right/bottom anchor unchanged; minimum height respected |
| [resize-max.png](resize-max.png) | Bottom-right resize caps at 420×300, keeping (250,190) |
| [popups.png](popups.png) | Yellow 140×90 constrained to (660,490); magenta nested 80×50 to (720,550), above its parent |
| [reposition.png](reposition.png) | Reposition token 777 ACKed; nested magenta moves to (661,491) |
| [dismissed.png](dismissed.png) | Outside-click removes popup rendering and restores root keyboard focus |
| [parent-destroyed.png](parent-destroyed.png) | Parent destruction while held dismisses its popup/grab; blue remains usable |
| [keyboard-popup.png](keyboard-popup.png) | Keyboard-serial popup receives focus; a new client cannot steal the grab |
| [popup-disconnect.png](popup-disconnect.png) | Disconnect removes the popup and restores focus to the remaining root |
| [unmap-resize.png](unmap-resize.png) | Unmap cancels a left resize; remap clears Resizing and rejects the orphan release |
| [survivor.png](survivor.png) | New cyan client renders after active-window mid-resize disconnect |
| [independent-three.png](independent-three.png) | Three unchanged Zig clients, plus a real synchronized subsurface |
| [independent-moved.png](independent-moved.png) | Independent Zig CSD move from that subsurface; committed pixels match |
| [stage2-initial.png](stage2-initial.png), [stage2-resized.png](stage2-resized.png) | Original Stage 2 800×600 and 700×500 quadrant regression |

## Implementation corrections and audit

The Wayland audit used the pinned Smithay sources and installed xdg-shell XML,
traced role/surface destruction, seat/grab serials, ACK/commit, render callbacks
and teardown, then exercised these transitions with actual clients. Corrections
made during Stage 3 include:

- Core order is projected explicitly into Space; native focus restoration no
  longer chooses an arbitrary creation-order element.
- Resize position changes only with an ACKed commit's actual client size;
  a single geometry configure slot prevents motion-driven queue growth.
- Popup parent-coordinate helpers run outside the pending-role mutex, avoiding
  recursive locking; ancestry is validated before Smithay's unbounded helpers.
- Popup null-buffer unmap removes the native descendant tree, and dismissal
  is sent once. Native seat grabs end even when dismissed objects stay alive.
- Unmap resets Resizing and pending geometry/grab state before remap. Pointer
  repair accepts popup/subsurface roots and suppresses orphan releases.
- Weak wm_base error scope follows wl_surface ownership; errors use the correct
  interface without a parallel client registry or private Smithay-field access.
- Tests track which surface owns each configure and never ACK an already
  consumed serial; frame barriers identify their own requested callback.

This audit is targeted protocol/lifecycle validation, not a whole-project
security or production resource-budget certification.

## File inventory

New implementation/test files:

```text
rust/crates/raywm-compositor/src/grabs.rs
rust/crates/raywm-compositor/src/popups.rs
rust/tests/floating.rs
rust/tests/floating-smoke.py
```

Changed files across Stage 3:

```text
rust/crates/raywm-core/src/windows.rs
rust/crates/raywm-compositor/src/main.rs
rust/crates/raywm-compositor/src/state.rs
rust/crates/raywm-compositor/src/shell.rs
rust/crates/raywm-compositor/src/input.rs
rust/crates/raywm-compositor/src/nested.rs
rust/tests/headless.rs
rust/tests/nested-smoke.py
README.md
CHANGELOG.md
docs/ARCHITECTURE.md
docs/INSTALL.md
docs/TESTING.md
docs/RUST_MIGRATION.md
```

New evidence files are this record, the 19 images listed above,
`protocol-probe.log`, `independent-0.log` through `independent-2.log`,
`backend.txt`, `environment.txt`, `sources.sha256` and `images.sha256`.
No unrelated untracked user files are included.

## Limits and next work

The qualified scope is one software-rendered nested output, fixed floating
policy, standard client move/resize and XDG popups, with event-driven full
redraw. No perpetual redraw timer or blocking geometry wait is added.

Clipboard/data-device, primary selection, DnD, cursor surfaces, decorations,
maximize/minimize/fullscreen policy, layer-shell, Lua, IPC, ray.conf, tiling,
effects, Xwayland and physical DRM/libinput sessions remain deferred. `foot`
still requires the absent data-device global. GTK/Qt, hardware GL, physical
hotplug, fractional client scaling, presentation-time, context loss, sanitizers
and production resource budgets are unqualified. Output resize does not yet
relocate floating windows or reactively reposition popups.

Next: isolate real data-device/selection support and qualify independent toolkit
clients; exercise output/active-popup resizing; review workspace/config ownership
before separately authorizing Lua, tiling or additional shell services. Do not
promote release branches or packaging based on this nested qualification.

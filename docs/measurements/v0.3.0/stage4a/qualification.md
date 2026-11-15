# Stage 4A clipboard and client compatibility qualification

Status: **PASS for the Stage 4A nested/software scope**. This is migration work
on `feature/rust-smithay`, not a release or a v0.3.0 declaration. The Zig
desktop, packaging and protected branches remain unchanged. Nothing was pushed.
Evidence run: `/tmp/raywm-stage4-lp25zldb` (ephemeral logs remain there).

The [migration architecture](../../../RUST_MIGRATION.md) describes selection
ownership, focus following, the serial policy and the fd path. This record
contains the concrete run, images and non-claims.

## Environment

- Rust/Cargo 1.99.1; Smithay pinned to `=0.7.0`, unchanged `Cargo.lock`.
- Private Zig 0.16.0 / wlroots 0.20 headless pixman parent, 1280×720.
- Winit Wayland child output 800×600, scale 1; llvmpipe, EGL 1.5 / GLES 3.2,
  Mesa 26.2.5-arch1.1.
- foot 1.28.0 (PGO, IME, graphemes, toplevel-tag, blur); wl-clipboard 2.3.0.
- GTK 4.24.1 and Qt 6.12.0 development files were present; the harness compiles
  a minimal C GTK4 probe and C++ Qt6 probe. This is not a full toolkit matrix.
- All inherited display/socket variables are scrubbed. Virtual keyboard/pointer
  and `grim` target only the parent created by this invocation. No running
  desktop input, capture, installation or session/VT acquisition occurred.

## Reproduction

From the repository root, after the unchanged Zig `-Dtest-input` build:

```sh
python3 rust/tests/selection-smoke.py
```

The harness finds actual Cargo executables from JSON build messages, creates
private mode-0700 runtime directories and bounded waits, then:

1. starts the private Zig parent and the Rust Winit compositor;
2. runs the ignored `selection::clipboard_primary_and_focus_lifecycle` test;
3. answers its `want-*` focus gates with virtual pointer clicks;
4. after the Rust client exits, runs foot with a private config, takes
   screenshots and injects real keyboard/pointer input;
5. runs `wl-copy` and `wl-paste` as independent clients;
6. compiles and runs minimal GTK4 and Qt6 probes, checking rendered pixels,
   typed text, copy to `wl-paste` and paste from `wl-copy`;
7. asserts sockets/locks are removed and every process exits.

## Results

All commands returned zero:

| Check | Result |
|---|---|
| `cargo fmt --all -- --check` | PASS |
| `cargo check --workspace --locked` | PASS |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | PASS |
| `cargo test --workspace --locked` | PASS: 7 core + 11 real headless tests; 3 graphical tests ignored here |
| `cargo build --workspace --locked` | PASS |
| `cargo clippy --workspace --all-targets --no-default-features --locked -- -D warnings` | PASS |
| `cargo test --workspace --no-default-features --locked` | PASS: 7 core + 10 headless tests; graphical selection test ignored |
| `cargo build --workspace --no-default-features --locked` | PASS |
| Stage 2 graphics harness | PASS (unchanged) |
| Stage 3 graphics harness | PASS (unchanged, 15 Rust stages + 3 independent Zig clients) |
| Stage 4A selection harness | PASS |
| `tests/docs-sync.sh` | PASS |
| Zig source/build/config/protocol/test equality against `f5d9677` | PASS; no Zig implementation or tests changed |

### Rust client scenario

Two independent Wayland connections, real keyboard focus transitions and real
fds. Verified observations:

- selection set with the actual `wl_keyboard.enter` serial; offer list contains
  three MIME types; `text/plain;charset=utf-8`, `text/plain` and
  `application/x-raywm` each return their distinct payload;
- a focused client reads its own selection;
- ownership transfers to the second client and back, and the receiver that
  loses focus receives no later selection events;
- primary selection is set and read independently while the clipboard still
  returns its own payload;
- clearing produces a null selection for the next focused receiver;
- a forged serial and a serial from a previous focus are denied (compositor
  log shows two `Denying clipboard selection...` warnings) and a valid serial
  still works afterwards;
- releasing and recreating a data device while focused immediately yields the
  current offer;
- destroying the owning source clears the selection;
- an unknown MIME type never reaches the source; a receiver that closes its
  read end produces a contained `EPIPE` on the source; normal transfer resumes;
- unmap/remap and owner destroy-with-live-selection keep or clear state without
  a crash; receiver and source disconnects are isolated;
- with an open popup grab, an outside click dismisses the popup, keyboard focus
  returns to the root and the same client's clipboard remains readable;
- an invalid `start_drag` serial transfers nothing;
- final SIGTERM removes socket and lockfile.

### foot

| Observation | Result |
|---|---|
| connect, XDG map, render | PASS; client-selected red background at parent pixel 200,120 |
| keyboard input | PASS; injected `hi` + Return reached the shell, which wrote `hi` |
| mouse selection → primary | PASS; `wl-paste -p` returned `FOOTCOPY-1234` |
| copy → independent receiver | PASS; Ctrl+Shift+C then `wl-paste` returned `FOOTCOPY-1234` |
| paste from independent source | PASS; `wl-copy WLCOPY-PASTE` then Ctrl+Shift+V + Return reached the shell |
| clean teardown | PASS; foot terminated, compositor survived and shut down |

`foot.log` records only non-fatal capability warnings: no XDG activation,
fractional scaling, server-side cursors, xdg-toplevel-icon or text-input. Those
remain real limitations listed in the migration document.

### GTK 4 and Qt 6 probes

| Observation | GTK 4.24.1 | Qt 6.12.0 |
|---|---|---|
| connect, map, render | PASS (blue area at 150,150) | PASS (green area at 150,150) |
| keyboard text entry | PASS (`gtktyped`) | PASS (`qttyped`) |
| copy → independent `wl-paste` | PASS | PASS |
| paste from independent `wl-copy` | PASS | PASS |
| clean teardown | PASS | PASS |

The probes are frameless 320×200 windows with one text field; successful text is
confirmed by a file written from the application's Return handler. GTK's log
contains only D-Bus/Vulkan fallback warnings from running without a session bus
and with the software renderer. This is a minimal toolkit selection check, not
a full application or theme qualification.

## Images

- `foot.png` — mapped foot window with its private red background.
- `foot-selected.png` — the same window after the mouse drag that produced the
  primary selection copied in the next step.
- `gtk4.png` — mapped frameless GTK4 probe with its blue area.
- `qt6.png` — mapped frameless Qt6 probe with its green area.

## Non-claims

Drag icons are not rendered and DnD negotiation is not qualified. There is no
clipboard history/manager, persistence, Xwayland bridge or compositor-owned
selection. GTK/Qt were not exercised. This is nested software behavior, not
physical hardware, a full toolkit matrix or a release qualification.

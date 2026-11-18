# RayWM Stage 5B qualification

**Verdict: PASS for Linux x86_64 nested/software.** The Winit compositor runs
Master-Stack, Columns, Monocle and Floating with real GTK4 and Qt6 clients.
The core and Smithay integration also exercise two logical outputs. Native
outputs and physical hotplug are outside this qualification.

## Git and implementation

| Item | Value |
|---|---|
| Branch | `feature/rust-smithay` |
| Verified Stage 5A baseline | `8311d1baa4f77319c073871dfbd110087bf9463a` |
| Qualified implementation HEAD | `32004f91c8ede3167f7ccd10c1bed3f3c3db95e7` |
| Protected Zig paths and Rust workspace dependency files | PASS, identical to baseline |
| Environment and complete evidence manifest | [Environment](environment.txt), [Source hashes](sources.sha256), [Command exit codes](results.tsv) |

The initial cloud checkout was a clean Zig-only branch. The GitHub
`feature/rust-smithay` ref matched the supplied baseline exactly. The
qualification commit adds this record and the raw evidence. Its parent is
the qualified implementation HEAD. [Stage 5A reference results](../stage5a/qualification.md).

| Area | Implementation |
|---|---|
| Core | Pure validated plans, deterministic integer layout and size hints, per-workspace layout/focus, master/gap settings, presentation modes, separate floating restore geometry |
| Smithay | Event-driven Space projection, XDG flags and ACK/commit gates, coalesced resize suggestions, fullscreen centering, clipping of managed toplevel trees and popup reconciliation |
| Controls | Nine startup workspaces, layout switching, floating/fullscreen/maximize, focus and reordering, family transfer and output-aware focus |
| Outputs | Output-specific logical and usable bounds, workspace fallback by stable ID, detachment and restoration |
| Tests | Nine new core tests, four new real-wire tests and a new graphical GTK4/Qt6 harness |

[Architecture, state transitions and controls](../../../RUST_STAGE5B.md).

## Final test matrix

Cargo ran in `rust/` with the locked dependencies. Check and Clippy covered
all targets. The renderer-free variant uses `--no-default-features`.
Graphical tests ran separately.

| Gate | Result | Evidence |
|---|---|---|
| `cargo fmt --all -- --check` | PASS | [fmt](fmt.log) |
| Default check, build, test and Clippy `-D warnings` | PASS, 49 tests passed | [check](check.log), [build](build.log), [test](test.log), [Clippy](clippy.log) |
| Renderer-free check, build, test and Clippy `-D warnings` | PASS, 49 tests passed | [check](headless-check.log), [build](headless-build.log), [test](headless-test.log), [Clippy](headless-clippy.log) |
| Project docs-sync | PASS | [docs-sync](docs-sync.log) |
| Protected paths | PASS | [path list and command](environment.txt), [diff output](protected-paths.log) |
| Stage 2 | PASS, one graphical Rust test | [harness](stage2.log), [rendered frame](stage2-runtime/resized.png) |
| Stage 3 | PASS, one graphical Rust test and three independent Zig clients | [harness](stage3.log), [delayed resize](stage3-runtime/resize-unacked.png), [popup](stage3-runtime/popups.png) |
| Stage 4A | PASS, one graphical Rust test and foot/GTK4/Qt6 probes | [harness](stage4a.log), [foot](stage4a-runtime/foot.png), [GTK4](stage4a-runtime/gtk4.png), [Qt6](stage4a-runtime/qt6.png) |
| Stage 4B | PASS, three graphical Rust tests and GTK4/Qt6 DnD, popup and primary-selection probes | [harness](stage4b.log), [drag icon](stage4b-runtime/shot-dnd-icon.png), [Qt submenu](stage4b-runtime/qt-nested-menus.png) |
| Stage 5A | PASS, 12 core and five real-wire integration tests in both Cargo runs | [test](test.log), [renderer-free](headless-test.log) |
| Stage 5B | PASS, nine core and four real-wire tests plus the graphical harness | [harness](stage5b.log), [GTK wire](stage5b-runtime/gtk.wire), [Qt wire](stage5b-runtime/qt.wire) |
| Accepted DnD source disconnect completes the transfer | FAIL, known upstream Smithay 0.7.0 defect | [wire trace](stage4b-runtime/final_admission_and_accepted_source_disconnect.log) |
| Physical hotplug, DRM/KMS, other platforms, hardware GL, scale-factor matrix and benchmarks | NOT_RUN | Outside Linux nested/software scope |

Each Cargo run executed 29 core tests, nine real-wire integration tests and
11 headless process/protocol tests. Default Cargo marked six graphical tests
ignored. The renderer-free build marked one graphical test ignored and
feature-gated the rest. The four Stage 2–4B harnesses ran all six separately.

## Protocol and visual evidence

- Stage 5B checks ACK-only and buffer-only progress independently, coalescing
  while a client holds an old buffer, two pending presentation configures,
  committed geometry from a differently sized buffer, fullscreen centering,
  floating restore geometry, late commits on a hidden workspace, and
  fullscreen destruction/focus repair. The multi-output wire case maps two
  real Smithay output handles at different origins and observes a window
  transfer, focus crossing, loss, rebinding and reappearance.
  [Default wire test results](test.log).
- The Stage 5B Winit/Xvfb run used Mesa llvmpipe with simultaneous GTK4 and
  Qt6 Wayland clients. It checked 24 submitted pixel states, ordinary key
  forwarding, pointer delivery, shortcut handling, geometry after output
  resize, toolkit-requested maximize/fullscreen, popup composition in a tile,
  `popup_done` on workspace switch, client-buffer ACKs and socket cleanup.
  [Master-Stack](stage5b-runtime/master-stack.png),
  [Columns](stage5b-runtime/columns.png),
  [Monocle](stage5b-runtime/monocle-gtk.png),
  [floating over a tile](stage5b-runtime/floating-over-tile.png),
  [fullscreen](stage5b-runtime/fullscreen.png),
  [popup in a tile](stage5b-runtime/popup-in-tile.png),
  [retile after resize](stage5b-runtime/retiled-after-output-resize.png).
- The unchanged Zig parent test executables hosted the Stage 2–4B software
  runs. Stage 3 checks a three-window stack, serial-validated move/resize,
  ACK-delayed sizing and anchors, popup grabs/reposition, destruction and
  remap. Stage 4A checks independent clipboard/primary transfers and font/pixel,
  input, copy/paste and teardown for foot, GTK4 and Qt6. Stage 4B checks
  negotiated DnD and drag-icon pixels, GTK↔Qt payloads, cancellation and
  disconnect, reactive popups, two hover-driven Qt submenu levels and
  exact primary-selection FD payloads. [Stage 3](stage3.log),
  [Stage 4A](stage4a.log), [Stage 4B](stage4b.log).

## Regression comparison and remaining work

The Stage 5A baseline had 36 automated tests. Stage 5B executes 49 and repeats
the six graphical Rust regression tests. Stage 4A's foot fixture checks the
installed font/color syntax and waits for the red frame it asserts. The
Stage 4B reactive popup fixture chooses a verified exposed root pixel after
output resize. An earlier click landed on the repositioned child popup.
The headless process test now waits for both the socket and the ready log
before connecting. These changes preserve the assertions for pixels,
event ordering and payloads.

The accepted-source-disconnect failure remains exactly the Smithay 0.7.0
zero-byte EOF case. Other DnD and popup tests completed successfully. Native
multi-output rendering and hotplug still require a backend. Maximize/fullscreen
capabilities are offered in Winit. Minimize and the compositor window menu
are unavailable. Configuration is typed and internal. No performance
measurements were taken.

Stage 5C can build on stable window/workspace IDs, the typed configuration and
command entry point, validated placement plans and the XDG adapter. The
remaining work is config loading and reload, lifecycle publication and a
bounded Lua host. [Stage 5C prerequisites](../../../RUST_STAGE5B.md#scope-and-stage-5c).

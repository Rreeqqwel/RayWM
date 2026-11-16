# Stage 4B drag-and-drop, drag icon and reactive popup qualification

Historical record for the initial Stage 4B commit `7e9c67e`. The initial run
passed its DnD/icon/reactive-popup scope and left GTK primary selection and Qt
submenus BLOCKED by inconclusive probes. The toolkit/environment explanation
was not established. Both scenarios are now resolved by
[Stage 4B-Final qualification](final-qualification.md), which also identifies
the accepted-source-disconnect upstream defect precisely. The tables below
retain the original observations; they do not describe current qualification.
This is migration work on `feature/rust-smithay`, not a release. Zig sources,
build, protocol, config, packaging and scripts are unchanged. Nothing was pushed.
Base commit: `ecd2a28` (Stage 4A). Evidence run:
`/tmp/raywm-stage4b-2_zajh7q`.

The [migration architecture](../../../RUST_MIGRATION.md) describes DnD state
ownership, icon rendering and popup constraint coalescing. This record contains
the executable observations, images, payloads and known limits.

## Environment and reproduction

- Rust/Cargo 1.99.1; Smithay pinned to `=0.7.0`, unchanged `Cargo.lock`.
- Private Zig 0.16.0 / wlroots 0.20 headless pixman parent, 1280×720.
- Winit Wayland child, 800×600 then 700×500, scale 1; llvmpipe, EGL 1.5 /
  GLES 3.2, Mesa 26.2.5-arch1.1.
- foot 1.28.0; wl-clipboard 2.3.0; GTK 4.24.1; Qt 6.12.0 development files.
- No GTK/Qt package was installed for this run; the harness compiles frameless
  probes against the already-installed development files. Missing development
  files would print a skip/BLOCKED reason rather than a PASS.

From the repository root, after the unchanged Zig `-Dtest-input` build:

```sh
python3 rust/tests/stage4b-smoke.py
```

The harness finds the real Cargo executables from JSON build messages, creates
private mode-0700 runtime directories and bounded waits, and runs:

1. `dnd::dnd_icon_targets_actions_and_teardown`;
2. `dnd::reactive_popup_constraints_and_lifecycle`;
3. GTK4 → Qt6 and Qt6 → GTK4 pointer-driven toolkit DnD;
4. toolkit cancellation and source/target close during a drag;
5. GTK and Qt context-menu popups;
6. final socket/lock/process cleanup.

The Rust scenarios use one persistent virtual-pointer process per gesture, so a
real implicit grab spans the whole press/move/release sequence. The test acts on
wire events while the driver holds the button; screenshots are taken only after
a real frame callback (or a protocol-visible popup configure), and pixel
assertions use `grim` plus the repository PNG checker.

## Results

All Cargo commands returned zero:

| Check | Result |
|---|---|
| `cargo fmt --all -- --check` | PASS |
| `cargo check --workspace --locked` | PASS |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | PASS |
| `cargo test --workspace --locked` | PASS: 7 core + 11 automatic protocol tests; 5 graphical tests ignored |
| `cargo build --workspace --locked` | PASS |
| headless-only clippy/test/build | PASS: 7 core + 11 tests; DnD graphical tests not compiled |
| `tests/docs-sync.sh` | PASS |
| Stage 2 nested smoke | PASS (unchanged) |
| Stage 3 nested smoke | PASS (unchanged, 15 Rust stages + 3 independent Zig clients) |
| Stage 4A selection harness | PASS (unchanged: clipboard, primary, foot, wl-clipboard, GTK/Qt copy/paste) |
| Stage 4B harness | PASS with the matrix below |

### Rust DnD scenario

| Observation | Result |
|---|---|
| Forged drag serial (`0xdeadbeef`) starts no drag | PASS |
| Real held pointer serial starts the drag | PASS |
| Copy/move/ask source actions arrive at the target | PASS |
| Preferred `ask` is the negotiated action | PASS |
| Preferred `move` is the negotiated action | PASS |
| Target switching (A↔B) produces leave/enter, not motion on the wrong device | PASS |
| Clipboard transfer during an active DnD grab | PASS |
| Yellow 32×32 icon rendered at the pointer above the target | PASS |
| Buffer-scale-2 icon (64×64 buffer, 32×32 logical) and no out-of-size bleed | PASS |
| Icon gone after drop / cancel / icon-surface destroy / source disconnect | PASS |
| MIME-specific payload (`dnd-payload`) via fd | PASS |
| Receiver closes its read end → source EPIPE contained, next transfer works | PASS |
| Drop exactly once; finish exactly once | PASS |
| Unoffered MIME acceptance → no drop, source cancelled | PASS |
| Source client disconnect mid-drag | PASS (target survives; no data) |
| Fresh drag after teardown to the surviving target | PASS |
| Stale serial after release starts no drag | PASS |

Direct evidence: `dnd-icon.png`, `dnd-icon-scale.png`, `dnd-icon-gone.png`,
`drops.txt`, `events.log`.

### Reactive popup scenario

| Observation | Result |
|---|---|
| Initial popup geometry `(201,181,120,80)` | PASS |
| Toplevel moved by a real pointer grab → constrained configure | PASS |
| Output 800×600 → 700×500 re-constrains the popup | PASS |
| Large nested popup follows the parent and is constrained on parent move | PASS |
| Bottom-right parent resize does not emit an unnecessary configure | PASS |
| Valid `reposition` token 4242 repositions and is ACKed | PASS |
| Parent unmap dismisses the popup tree exactly once | PASS |
| Remap + fresh popup works | PASS |
| Destroy parent with an unACKed initial popup configure | PASS, no stale entry |
| Nested popup pixel at its constrained screen position | PASS (`popup-child.png`) |

The popup configure values are relative to their parent window geometry; the
test adds the known toplevel origin when checking screen bounds.

### Toolkit matrix

| Scenario | Result |
|---|---|
| GTK 4 source → Qt 6 target, payload `gtk-to-qt` | PASS (`gtk-to-qt.png`, `drops.txt`) |
| Qt 6 source → GTK 4 target, payload `qt-to-gtk` | PASS (`qt-to-gtk.png`, `drops.txt`) |
| Toolkit drag cancelled by returning to the source | PASS, no drop |
| Target app closed mid-drag | PASS, source/compositor survive, no drop |
| Source app closed mid-drag | PASS, target/compositor survive, no payload |
| GTK context-menu popup | PASS |
| Qt context-menu popup | PASS (`qt-menu.png`, popup role in `events.log`) |
| Qt nested submenu popup | **BLOCKED**: `QMenu` did not open the submenu under synthetic hover |
| Qt primary selection (text selection) | PASS |
| GTK primary selection (text selection) | **BLOCKED**: no primary offer was published through the advertised `zwp_primary_selection` protocol |
| Clipboard copy/paste in GTK/Qt | Already qualified in Stage 4A; unchanged |

The toolkit DnD scenarios use an ordinary left-button press, several real motion
events, a release over the other application, and verify the actual text written
by the target's drop handler. They are not programmatic toolkit API calls.

## Defects found and corrected

1. **DnD grab cancelled by pointer-focus repair.** `repair_pointer_focus` ran
   after window commits with no pointer focus during a DnD grab and unset the
   grab. It now returns early while `dnd_active`.
2. **Drag-icon frame deadlock.** Sending icon frame callbacks with a closure
   that called `with_renderer_surface_state` recursively locked the same surface
   data map. The closure now reads `SurfaceAttributes` from the `SurfaceData`
   already provided by the traversal and sends callbacks only for buffered
   surfaces.
3. **No icon rendering redraw.** Pointer motion now requests a frame only while
   an icon exists; icon commits and `buffer_delta` also request one. Idle scenes
   still do not redraw.
4. **Popup constraints skipped after an interactive move.** `FloatingGrab`
   finished the interaction before `unset`, so the unset path's reposition pass
   never ran. The release path now calls `reposition_popups` explicitly.
5. **Transient nested-popup configure.** Using acknowledged parent-popup
   geometry produced an extra configure (`-160,-160`) before the final value.
   The adapter now accumulates pending parent-popup geometry, yielding the final
   constraint in one pass.
6. **Stale popup configure traffic.** A per-entry last-sent geometry and a
   one-shot `reactive_blocked` flag prevent repeated configures and retries for
   non-reactive positioners.
7. **Stationary-pointer focus loss.** When a focused surface was destroyed and
   another window appeared under an unmoved pointer, the next click had no
   pointer focus. Pointer repair now re-enters the surface under the pointer
   after dropping orphaned button state.
8. **Source-disconnect drop indication.** Smithay's grab teardown can still emit
   a final drop when the drag-origin surface dies, even though the source is
   gone. The target receives no data; the icon and grab are cleared. Recorded as
   a known protocol edge rather than claimed successful transfer.

## Images

- `dnd-icon.png` — yellow drag icon above the green target window.
- `dnd-icon-scale.png` — scale-2 icon at the same pointer position; the test
  also asserts the target background outside the 32×32 logical icon.
- `dnd-icon-gone.png` — the same point after drop, showing the target again.
- `popup-child.png` — nested popup (magenta) at its constrained position.
- `gtk-to-qt.png` — GTK source (white `DRAG-GTK`) over the Qt target (cyan
  `DROP-QT`), before the pointer-driven drag.
- `qt-to-gtk.png` — the reverse pair.
- `qt-menu.png` — Qt probe window used for the context-menu check.

## Non-claims

Server-side (compositor-owned) DnD is not implemented. Drag icons are composited
in the nested software renderer, not a general cursor/icon stack. The toolkit
results are frameless probe windows with the default themes; no full
application, decoration, IME, Xwayland or hardware matrix is claimed. The Qt
nested submenu is BLOCKED, not passed.

# Stage 5A qualification — 2026-11-18

**Verdict: Stage 5A is complete within the specified foundation and nested/software scope.**

Stage 5A implements the workspace/configuration foundation in the existing
Rust core and Smithay adapter. Scope: Linux x86_64, headless protocol and
nested/software execution. This is not a release or native-desktop qualification.

## Baseline and reconnaissance

Verified baseline: branch `feature/rust-smithay`, HEAD
`9d846f6` (`fix(rust): resolve stage 4b protocol and toolkit regressions`).
Tracked files were clean. Pre-existing untracked `.agents/`, `.claude/`,
`.codex/`, `CLAUDE.md`, `graphify-out/`, `dist-v0.1.1-backup/` and `recovery/`
are excluded from the checkpoint. No branch switch, push, merge, release,
reset/clean or dependency upgrade was performed.

The supplied Stage 4B baseline was correct. The previous documentation's
Rust/Cargo 1.99.1 is historical: this qualification uses **1.100.0**.
[Environment](environment.txt). Cargo still has two crates, `raywm-core` and
`raywm-compositor`; Smithay remains exactly 0.7.0. Graphify was queried first,
but its graph primarily described the Zig tree. Tracked Cargo sources and
the pinned local Smithay source established the Rust implementation details.
Context7 returned master documentation; it was not used as proof of 0.7.0 APIs.

Existing components reused: Desktop registry/geometry/interactions, View
resource bindings, Smithay Space, seat/grab handling, PopupManager, output
rendering and the Stage 2–4B real-client harnesses. No second policy registry
or generic transaction/event-bus subsystem was added.

## Architecture and invariants

The full contracts, module map, operation rules and Stage 5B prerequisites are
in [RUST_STAGE5A.md](../../../RUST_STAGE5A.md).

| Boundary | Implemented ownership |
|---|---|
| Window registry | Desktop owns stable checked IDs, lifecycle, committed floating geometry, membership, parent IDs, participation metadata, focus and global stack |
| Wayland resources | View owns only Smithay Window/surface bindings and handshake/flight metadata; destruction removes both binding and core record |
| Workspace model | Checked u64 IDs; membership stored once on windows; per-output active workspace, explicit fallback removal, validated family transfer and output binding |
| Output model | Optional workspace binding, validated bounds, detach/cancel on output loss and selected-workspace adoption on new output; backend currently supplies one nested output |
| Layout | Pure input → validated desired-placement plan; floating preserves current geometry; fullscreen/maximized bounds are pure contracts; tiling returns Unsupported |
| Configuration | Typed candidate snapshots with defaults/ranges; validate before replacement, reject busy operations, preserve existing windows; no file/Lua loader |
| Commands/events | Typed synchronous requests/results, explicit close effects and controlled errors; unsupported stateful commands do not mutate state |
| Integration | Validated core transition → visible Space projection, popup dismissal, seat/selection focus repair and existing configure/ACK/commit path |

IDs do not wrap or recycle. Every live window references an existing workspace;
parent links are acyclic and families share membership. The stack has exactly
one entry per mapped window. Focus never references a removed, unmapped or
inactive window. Hidden workspaces retain protocol mapping but leave Space.
Unmap/remap preserves geometry/membership and repeats the handshake; parent
unmap/destroy clears direct child links. Popups never become managed windows.
Output loss retains logical windows and detaches workspaces. With no physical
outputs, headless logical visibility does not fabricate frame callbacks.

Resize commands queue suggestions; one configure remains in flight until an
ACK **and** associated commit. A commit before that ACK does not change core
size. Reparenting to another workspace cancels affected operations and clears
adapter flights. Protocol-grab guards prevent internal commands from stealing
an implicit/explicit pointer, keyboard, popup or DnD grab.

## Final verification matrix

[Machine-readable commands and exit statuses](results.json). Logs below are
from actual execution, not inferred from compilation. Cargo commands ran from
`rust/` with `--locked`; the recorded check commands additionally use
`--all-targets`. Headless variants use `--no-default-features`.

| Check | Status | Evidence |
|---|---|---|
| cargo fmt --all -- --check | PASS | [fmt.log](fmt.log) |
| cargo check --workspace --all-targets --locked | PASS | [check.log](check.log) |
| cargo test --workspace --locked | PASS: 36 executed, 6 graphical ignored here | [test.log](test.log) |
| cargo clippy --workspace --all-targets --locked -- -D warnings | PASS | [clippy.log](clippy.log) |
| cargo build --workspace --locked | PASS | [build.log](build.log) |
| Renderer-free check/test/clippy/build | PASS: same 36 executed tests; 1 graphical ignored here (other graphical tests are feature-gated) | [check](headless-check.log), [test](headless-test.log), [clippy](headless-clippy.log), [build](headless-build.log) |
| tests/docs-sync.sh | PASS | [docs-sync-final.log](docs-sync-final.log) |
| Protected-path equality against 9d846f6 | PASS | [protected-paths.log](protected-paths.log), exact path list in results.json |
| Stage 2 nested/software runtime | PASS | [stage2.log](stage2.log), [wire/backend logs](stage2-runtime/) |
| Stage 3 floating/input/resize/popup runtime | PASS | [stage3.log](stage3.log), [wire/backend logs](stage3-runtime/) |
| Stage 4A clipboard/primary/toolkit runtime | PASS | [stage4a.log](stage4a.log), [wire/backend logs](stage4a-runtime/) |
| Stage 4B DnD/icon/reactive popup/toolkit runtime | PASS after the log-reader fix; initial harness FAIL retained | [stage4b.log](stage4b.log), [wire/backend logs](stage4b-runtime/) |
| Successful accepted-source-disconnect data transfer | FAIL: confirmed existing Smithay 0.7.0 defect; no new regression claimed | See known limitations below |
| Full unchanged Zig suite, DRM/KMS, hardware GL/hotplug, sanitizers, performance benchmarks | NOT_RUN | Outside this milestone; no inferred performance or hardware result |

Default Cargo execution contains 20 core tests (eight library and twelve
Stage 5A policy tests), five real-wire in-process integration tests and eleven
headless process/protocol tests. The six ignored graphical tests are executed
separately by their actual private-parent harnesses. An ignored Cargo test
alone is **NOT_RUN**, not PASS.

## Stage 5A test cases

All cases below are **PASS**, executed in both Cargo feature configurations;
individual test names/results are retained in the two test logs.

| Core test | Verified behavior |
|---|---|
| registry_lifecycle_remap_stable_ids_and_destroy_cleanup | Created/map/unmap/remap, geometry, stable ID and stale access |
| activation_transfer_hidden_focus_and_fallback | Hidden focus rejection, transfer and workspace focus selection |
| removal_transfers_mapped_and_unmapped_and_never_recycles_workspace | Last-workspace/fallback validation and complete membership migration |
| output_attach_switch_rebind_remove_and_reappear | Two-output bindings, activation, loss/reappearance and focus consistency |
| detached_workspace_activation_and_removal_are_explicit | Detached activation error and output active-selection repair |
| transient_family_transfer_stacking_cycles_and_parent_destruction | Family stacking/transfer, cycle rejection and parent cleanup |
| commands_reject_busy_stale_and_unsupported_without_mutation | Busy grabs/resizes, stale IDs and explicit unsupported contracts |
| command_effects_resize_coalescing_and_committed_geometry_are_distinct | Close effects, resize scheduling and actual committed size separation |
| configuration_defaults_validation_atomic_replacement_and_placement | Defaults/ranges, rejected snapshot preservation and placement behavior |
| floating_fullscreen_maximized_plans_are_pure_and_validated | Determinism, output-box contracts, duplicate/foreign/missing plan validation |
| output_loss_cancels_resize_and_retains_membership | Safe output loss with pending geometry |
| deterministic_lifecycle_command_sequences_preserve_invariants | 600 lifecycle/command steps with invariants checked after every step |
| workspace_id_exhaustion_never_wraps | u64 workspace counter exhaustion |

| Real-wire in-process test | Verified behavior |
|---|---|
| workspace_commands_reconcile_real_surfaces_space_and_lifecycle | Two real XDG/shm windows, workspace visibility/Space, focus, move, close, unmap/remap and destroy |
| command_resize_waits_for_ack_commit_and_transient_wire_parent_is_resolved | Wire parent linkage, unacknowledged buffer commit, ACK-only hold and final resize commit |
| logical_output_geometry_matches_projected_smithay_output | Core output binding/geometry versus actual Smithay Space output |
| hiding_workspace_dismisses_wire_popup_without_creating_managed_window | Real popup configure/ACK/buffer, popup_done on hide and cleanup without registry pollution |
| reparent_to_hidden_workspace_cancels_core_and_adapter_resize | Real parent request during configure flight, membership change, flight cancellation and parent-unmap cleanup |

The existing seven core regressions also execute. Existing eleven process/
protocol regressions retain initial configure/ACK, early-buffer and invalid-ACK
isolation, popup parent/ancestor errors, buffer/subsurface lifetime, independent
clients, disconnect and shutdown/socket cleanup coverage.

## Runtime observations and development corrections

Stage 2 observes actual submitted pixels at 800×600 and 700×500, forwarded
keyboard/pointer events, output resize, frames and process/socket cleanup.
Stage 3 checks three-window pixels, actual focus/key routing, valid and
invalid-serial move, delayed ACK/min/max resize, popup grabs/reposition,
ancestor/parent destruction and independent Zig clients with CSD/subsurface
input. Stage 4A checks independent FD clipboard/primary transfers and foot,
GTK4 and Qt6 map/render/input/copy/paste. These are software runtime tests,
not just a successful build or simulated protocol callback.
+
+The final Stage 4B rerun executes all three graphical Rust protocol tests and
+actual GTK→Qt/Qt→GTK DnD with payload checks, cancellation, target/source close,
+GTK context menu, Qt root/child/grandchild hover/render/grab/outside-click
+teardown, and GTK/Qt primary-selection FD payload/cleanup. All those scenarios
+are PASS; the accepted-source-disconnect data-transfer limitation is recorded
+separately below. All four harnesses verify process/socket cleanup.

During development, the first new remap integration assertion failed because
the existing shell adapter clamped retained position against a headless
fallback box. Remap now preserves its stored floating position. Inspection
also found that repeated map updates wrote size before the resize ACK check;
the adapter now maps once and updates existing size only through the gated
commit path. The new delayed-ACK wire regression passes. An initial clippy
failure for a derivable Default and a test-only unused mut were corrected;
the final matrix forbids warnings.
+
+The first final Stage 4B run completed the DnD checks but failed in the Qt
+menu harness with `JSONDecodeError`: a snapshot caught the final log record
+mid-write. The completed log contains all three actual aboutToHide events.
+The reader now parses only newline-terminated records, while malformed
+complete JSON still fails. The initial failure is retained in
+[stage4b-initial.log](stage4b-initial.log), its
+[raw logs](stage4b-initial-runtime/) and results.json; the complete harness is
+rerun after the fix and is PASS. No protocol assertion or pixel check was weakened.
+No unresolved new critical lifecycle
regression was observed.

## Known limitations and next stages

The existing **accepted DnD source disconnect** defect remains in pinned
Smithay 0.7.0: an accepting target can receive a drop indication and zero-byte
FD EOF. The regression detector can PASS while confirming that defect;
successful transfer in that scenario is **FAIL**. No workaround, cancellation
semantic change or dependency upgrade was attempted. Historical root-cause
evidence remains in [Stage 4B-Final](../stage4b/final-qualification.md).

Tiling, floating/tiled toggling and fullscreen/maximized protocol application
are explicit unsupported commands. Their pure types/calculation boundary do
not claim working stateful window management. Lua, user config parsing/reload,
IPC, user bindings/workspace UX, native hotplug, effects and XWayland remain
deferred. Command results are not a full lifecycle event subscription stream.

No benchmark was run and no performance numbers are claimed. Reconciliation
constructs short-lived layout snapshots/plans only on events; large-window/
workspace scale and optimized batching remain unmeasured. Idle still blocks
on the existing event loop without a new timer or event bus.

Stage 5B can build on `State::execute_command`, workspace queries,
`Desktop::layout_plan`, `LayoutEngine` and validated `LayoutPlan`. It still
needs the tiling algorithm, restore/floating geometry policy, stateful
configure scheduling/capabilities and graphical workspace UX qualification.
Stage 5C can submit validated configuration snapshots through the command
boundary; it still needs the compatible loader and a separately audited Lua
host. Neither next stage was started.

## Evidence and Git policy

[sources.sha256](sources.sha256) identifies the qualified Rust sources and
tests. Runtime subdirectories retain real harness logs; their `source.txt`
records the temporary session directory where PNGs and other raw artifacts
were produced. No artificial screenshots, measurements or benchmark data were
generated. The checkpoint is local to `feature/rust-smithay`, with parent
`9d846f6`; its hash and final working-tree status are reported in the task's
final response. **No push was performed.**

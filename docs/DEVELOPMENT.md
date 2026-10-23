# v0.2.0 continuation ledger

This is an engineering record for the continuation started on 2026-10-23.
It describes inspected source and recorded checks. It is not a declaration
that v0.2.0 is ready for production or physical hardware.

Status terms used here:

- **PASS**: the stated check was run and passed for the stated build.
- **FAIL**: the check ran and failed.
- **SKIPPED**: the check was not run, with a reason.
- **NOT IMPLEMENTED**: the requested capability has no implementation.
- **PENDING**: implementation exists, but continuation validation is outstanding.

## Recovered state

The checkout initially contained branch `feature/v0.2.0-complete`, HEAD
`1da71f9f43100ea9615353fc62139d49cc1d6821`:
`feat(core): window states and requests (xdg-shell v7, decorations, minimize, activation)`.
The worktree was dirty. No reset, clean, history rewrite, push, merge or
release tag was used to recover it.

The tracked edits were `.github/workflows/ci.yml`, `CHANGELOG.md`,
`config/plugins/{binds,dwindle,window-rules,workspaces}.lua`,
`config/rules.lua`, and the dwindle, rules and workspace Lua tests.
They implement the second part of the shell work: shipped policy,
regressions and integration-test wiring for the already committed native
shell changes. Untracked files included `tests/shell.sh`, `tests/shell/`,
the foreign-toplevel protocol XML, local Claude instructions and tools,
`graphify-out/`, and `dist-v0.1.1-backup/`. The foreign-toplevel XML alone
does not implement the protocol.

A recovery snapshot is stored locally in `recovery/handoff-20261023/`.
Its `head.txt`, `status.txt`, `history.txt`, `tracked.patch`, and
`untracked.tar.gz` preserve the recovered state. These are recovery
materials, not release inputs; the original local files remain in place.
Recorded SHA256 values:

| File | SHA256 |
|---|---|
| `tracked.patch` | `51a024171d2b773152bf19d119a6a3e40481dc372db1311b9cd9b8d3a63b513b` |
| `status.txt` | `6ba9615608476229f65e4b2c08928ab5486f8ff9c4d845a7b62642eb6e5c44fd` |
| `history.txt` | `8d35e1c540d5b5a5d71e80240333f3c9359198ecf82b8b3aa44418e605bd7dca` |
| `head.txt` | `59b6d57642abb2a8eeae67dccb1b7e474ae085aef0647a579404c6c9be67f3da` |
| `untracked.tar.gz` | `70016792d698e81a0445ad5ad848ded869e1fcfc7db350c20cae87e0e4514e77` |

The previous developer's original scratchpad `PLAN.md` was subsequently
found and copied, without modifying its source, into the same recovery
directory. `PLAN.sha256` records its SHA256:
`bb77782c3788630d697f2bb6597530efbce86481f4b4d87975e96b75f61a4ff6`.
This addition does not alter the original snapshot's `SHA256.json`.

There is no `v0.1.2` Git tag in the recovered repository. The comparison
baseline is `89278579a0d00e42183eb6e93fcf3b77402d90dc`, the parent of
the first v0.2 implementation commit `9391194`. It contains the v0.1.2
version bump (`8334d9a`), documentation, output-mode addition and final
pointer-test determinism fix. The latter changes the final regression
click to the middle button, avoiding a new client-side move being
started by the assertion itself. This baseline choice preserves the
complete pre-v0.2 state without inventing a release tag.

## Inspected milestone state at recovery

The evidence below is implementation and test-source evidence. Existing
test files or historical reported passes do not mean the continuation
has rerun them successfully.

| Milestone | Inspected state | Evidence and acceptance still needed |
|---|---|---|
| F/1: advanced dwindle and floating windows | Implemented; PENDING validation | `9391194`, `a97a3a7`; split resize/toggle, swaps, gaps, client minimum sizes, native floating state and remembered geometry, deferred first reveal; Lua tests and window/input suites. |
| 2: fullscreen/maximize | Implemented; PENDING validation | `043e434`; native configure/state and backdrop, output-aware placement, focus exclusion, dialogs; `tests/windows.sh`. |
| 3: workspaces | Implemented; PENDING validation | `f93a962`, `fe47d8a`; native visibility/focus and plugin ownership, orphan/adopt reload, one shown per output; `tests/workspaces.sh` and Lua tests. |
| 4: window rules | Implemented; PENDING validation | `2261584`; policy plugin runs on `view_new`; matching and actions, dialog default; `tests/rules.sh` and Lua tests. |
| 5: session locking/idle | Implemented; PENDING validation | `51ad238`, `2ea9865`; `src/lock.zig`, idle globals and visible-surface inhibition, startup/spawn-once API; `tests/session.sh` with real swaylock/swayidle and probe locker. |
| 6: output configuration | Implemented; PENDING validation | `a3b6a80`, `c088da9`; output transactions, output power/gamma; `tests/outputs.sh` and unit coverage. Hardware properties need physical testing. |
| 7: input configuration | Implemented; PENDING validation | `70aa837`, `c3f729a`; layered settings, keymaps/repeat and libinput controls; `tests/devices.sh` and unit coverage. Hardware settings need physical testing. |
| 8A: protocol globals and sandbox handling | Implemented; PENDING validation | `ce08e80`, `413684c`; `src/protocols.zig`, buffers/scaling/presentation, selections, cursor shapes, security-context filtering, C-bool ABI workaround; `tests/protocols.sh` and ABI unit/lint checks. |
| 8B: shell/decorations | Native first part committed; second part interrupted | `1da71f9`; xdg-shell v7, decoration negotiation, minimize, activation and urgency. Dirty policy/tests constitute B2; validate/reconcile before committing. Initial configure and decoration timing require particular scrutiny. |
| 8C: pointer constraints | NOT IMPLEMENTED | No manager, constraint lifecycle, relative-motion routing or client regression suite at recovery. |
| 8D: taskbar/workspace protocols | NOT IMPLEMENTED | Foreign-toplevel XML is untracked; no native manager or workspace-protocol bridge at recovery. |
| 9: Xwayland | NOT IMPLEMENTED | `View.Impl` contains only `.xdg`; `.unmanaged` scene layer and `ViewInfo.xwayland = false` are preparatory fields. |
| 10: drag-and-drop/text input/IME | NOT IMPLEMENTED | `wl_data_device_manager` supports selections, but no request-start-drag handler or drag icon lifecycle; no text-input/input-method globals or focus bridge. |
| 11: animation infrastructure | NOT IMPLEMENTED | Existing opacity/position setters are immediate; no frame-driven animation state/cancellation or Lua animation registrations. |
| 12: visual extension API | NOT IMPLEMENTED beyond existing border/opacity | Four scene rectangles form a window border; there is no general plugin-owned visual-handle registry. Blur/rounded-corner support must not be inferred from `wlr_scene`. |
| 13: external IPC | NOT IMPLEMENTED | No local server, versioned wire contract, subscriptions, access checks or resource-limit implementation. |
| 14: plugin ecosystem | Strong existing foundation; PENDING completion | API v1 additive changes, protected callbacks, deferred cleanup, ownership of handlers/binds/timers/managed views/workspaces, orphan adoption, trusted-code limits and compatibility fixtures exist. New resource ownership, examples and API documentation remain necessary. |

## Continuation results

These results are separate from the recovered state above. Baseline logs
are in `/tmp/raywm-handoff-baseline/` on the development machine. They
are transient evidence paths, not release archive contents.

| Check at takeover | Result |
|---|---|
| Debug and test-input builds | PASS |
| Zig format/AST, Lua and shell syntax, C-bool lint | PASS |
| `zig build test --summary all` | PASS: 33/33 Zig tests, plus shipped Lua suites |
| smoke, focus, docs examples | PASS; docs checked five API examples |
| input / pointer / navigation / screenshot | PASS: 12 / 13 / 11 / 8 scenarios, headless pixman |
| workspaces / rules / session / outputs / devices / protocols / shell | PASS: 12 / 6 / 7 / 7 / 3 / 8 / 9 scenarios, headless pixman |
| stress | PASS; recorded RSS 18,428 to 19,536 KiB, delta 1,108 KiB below the 16 MiB guard. This is a stress-test sample, not a controlled v0.1.2 comparison. |
| original window scenarios | PASS: 15 original scenarios |
| added reparenting regression before its fix | FAIL: the first run used an old test client and produced six setup/assertion failures; after rebuilding that client, three assertions reproduced the actual descendant stacking/focus defect. |

Validated local continuation commits:

| Commit | Change and result |
|---|---|
| `0e61750` | Reconciled and committed the interrupted B2 shell-state policy and real client integration tests. |
| `a2b7661` | Restacked descendants and restored native focus after dialog reparenting. The new client-level regression failed before the fix; window suite PASS, 16 scenarios afterward. |
| `f0ff48b` | Rejected NaN/infinite Lua numeric arguments before native conversion/calls. Its regression failed before the fix; unit suite PASS, 34/34 afterward. |

The pointer-constraint implementation subsequently brought the current
core/Lua unit total to **35/35 PASS**, and the C implementation's
headless GLES2 capture/constraint suite passed **10/10**. This GLES2 run
used OpenGL ES 3.2, Mesa 26.2.5 and an AMD Radeon RX 580 through radeonsi;
its renderer log was `/tmp/tmp.pztGA4tN7P/raywm.log`. The managed sandbox
did not expose the render node, but the authorized host test could use
it. A missing render node in one sandbox view must not be recorded as
proof that the host has no GPU. These results still do not establish
physical DRM/KMS/input or monitor-hotplug compatibility.

Activation validation is also being strengthened: only a recent native
forwarded key/button press, exchanged once within five seconds with a
source surface still focused at token commit, authorizes focus. Bounded
input/token registries use destroy listeners and leave `token.data`
untouched. Existing F7 activation and new real-client enter-serial,
missing-source, expired-grant, serial/token replay, pointer-press and
focus-loss regressions passed together (10 activation scenarios).
The complete shell suite subsequently passed **16 scenarios**, including
source destruction both before grant exchange and after token creation
(`/tmp/raywm-activation-full.log`). The source-destruction case kills
only its private test clients; a token already minted from verified input
remains usable when the source application exits.
The enter/no-source/expired-grant regression was also run against a
copied pre-fix compositor with the new test client: **FAIL, six assertions
across three scenarios**, because each request incorrectly stole focus
(`/tmp/raywm-activation-before.log`). The comparison did not reset or
modify the shared worktree.

### Historical performance evidence

The recovered `PLAN.md` records the previous developer's M0 measurements
for a ReleaseSafe test build of v0.1.2 plus output-mode support, headless
pixman: 25.5 ms median startup (23.8–28.7 ms, ten samples), 0 ms idle CPU
over ten seconds with zero/three windows, RSS 14.5/18.5 MiB with
zero/three windows, a 4.1 MiB binary (663 KiB stripped), and 2,646 native
source lines. It also records a local GLES2 smoke pass. These are
**historical developer-reported measurements**, not measurements rerun
or independently reproduced by the continuation. They do not establish
candidate performance or a v0.2 speedup.

## Architecture retained

The native core owns Wayland protocol state, the seat, outputs, scene
nodes and deterministic resource teardown. `View` is the shared window
abstraction: backend-specific requests belong behind its methods, while
focus, workspaces, stacking, fullscreen and Lua policy use it through
integer IDs. The native workspace model enforces visibility and focus;
Lua decides names, bindings and layout policy.

`src/lua.zig` owns one Lua 5.4 VM. Registrations carry a plugin index and
are marked dead before deferred compaction. No Lua callback retains a
native pointer. Plugins are trusted user code, not a security sandbox:
their standard libraries can access files and start commands. New
animations and visuals must use the same bounded registration and
ownership model, with native per-frame work and cleanup on cancellation,
view destruction, plugin unload and reload.

The wlroots 0.20.1 Zig bindings and installed wlroots 0.20.x C headers
are the API/lifetime references. `src/cabi.zig` branches computed booleans
into constant C-call arguments because of a Zig 0.16 bool ABI issue;
new native setters must preserve this convention.

## Candidate acceptance (continuation)

The table of inspected milestone state above is intentionally historical.
The continuation implemented M8 C/D, M9–10, M11–12 and M13 in the retained
native View/scene architecture. M14 adds the author guide, optional native
resource examples, live-reload/ownership tests, complete validation runner,
performance sampling and release engineering. No second compositor/layout
implementation was introduced.

Additional local checkpoints:

| Commit | Result |
|---|---|
| `42f17da` | M8: native constraints/relative input/inhibitors, foreign toplevel/workspace protocols and stricter input-backed activation. |
| `d204222` | M9–10: Xwayland common View lifecycle/clipboard and native DnD/text-input/IME relay. |
| `83328fb` | M11–12: native frame animations, retained snapshots, owned input-transparent rectangles and resource cleanup. |
| `db3c1a7` | M13: versioned same-UID bounded IPC and raywmctl. |
| `c69daa9` | Extra real-client tests reproduced a continuation DnD cancellation defect; source destruction now notifies clients. All ten data/IME scenarios pass after the fix. |
| `1716ef8` | ReleaseSafe exposed Zig translate-c diagnosing glibc fortified fcntl stubs. Plain declarations are imported locally; explicit IPC bounds remain enforced. ReleaseSafe build and IPC client suite pass. |

Further GPU validation exposed `Failed to get backend DRM FD` during
animation-driven scanout feedback on headless outputs. Both close/workspace
pixel cases rendered correctly but **FAILED** the log check before its fix
(`bbb1a57`).
Outputs without a backend DRM FD now hold a balanced render-attachment lock,
avoiding invalid scanout recommendations while keeping DMA-BUF imports and
renderer feedback. The existing real-client effect cases are its regression.
This is independent of the retained computed-C-bool workaround.

| Gate | Recorded state |
|---|---|
| Debug/test-input build | PASS, 30/30 build steps |
| Production ReleaseSafe build | PASS, 8/8 steps, including final output/lifecycle fixes |
| Units and shipped Lua compatibility | PASS, 38/38 Zig tests; dwindle25/focus19/workspaces12/rules10 and screenshot145 checks |
| Formatting, AST, Lua/shell syntax and C-bool lint | PASS |
| Debug headless matrix | PASS at recorded checkpoints; extra data10/effects6 and all seven documentation examples passed independently. Final native bug regressions also ran with ReleaseSafe/GLES2. |
| ReleaseSafe headless matrix | Full run exposed the locked-shutdown defect; all suites have subsequent PASS evidence after targeted lifecycle reruns. Complete logs retain the initial failure. |
| Selected ReleaseSafe GLES2 | PASS: capture10/taskbar9/shell16/data10/Xwayland6, effects7, outputs7/protocols8 and session9; initial feedback/diagnostic failures retained separately |
| Physical DRM/KMS/input/hotplug/toolkits | SKIPPED; [hardware procedure](HARDWARE-TESTING.md) |
| Performance | PASS as measured samples, not thresholds; [PERFORMANCE.md](PERFORMANCE.md) and raw JSON. Final native-code samples repeated; raw hashes/results are recorded. |
| Security review | Native ownership/filtering/activation/lock/IPC boundaries reviewed; actual client regression evidence and uncovered areas in TESTING.md/SECURITY.md |
| Release packaging/installer/reproducibility | PASS on preparatory archive: two identical builds and 160 actual archive/install/runtime checks; final artifact identity is recorded in the external release report |
| Publication | Not authorized; no push/merge/tag/GitHub Release |

The final lifecycle regression (`ed023e8`) reproduces two compositor aborts
against the retained old production binary: shutdown while actively locked,
and shutdown after a locker died. The backend now destroys outputs/devices
before their scene/cursor/renderer resources and registries. Both cases and
all nine session scenarios pass on pixman and GLES2. A test-side unlock race
now waits for the lock client's replacement keyboard; asynchronous autostart
processes are checked for multiplicity rather than completion order. Neither
change makes the compositor block on child processes.

The initial-opacity pixel regression (`0ef7f3c`) shows opaque red on the old
M9–10 compositor and half-opacity red after the existing reveal fix. Production
packaging checks the virtual-pointer manager's creation symbol and test-only
markers, rather than rejecting the interface name in the security deny-list.
The archive test additionally connects to its actual production registry.

## Deliberate limitations

Scene primitives are borders and rectangles, plus client-buffer snapshots;
blur, shadows, rounded clipping, text/images and custom shaders are
**NOT IMPLEMENTED**. These were explicitly excluded by the recovered plan's
wlr_scene boundary. Touch/tablet device routing is not implemented. Real
fcitx/ibus, GTK/Qt/X11 DnD combinations, Steam/gaming, physical latency and
DRM/KMS/monitor/input testing remain **SKIPPED**, not evidence of support.
Headless GLES2 uses an actual AMD RX580/radeonsi render node but no physical
output/input session. The mismatched-UID IPC branch is reviewed but a second
UID test is SKIPPED. Exact upstream XWM BadWindow/property teardown diagnostics
are printed and allowed only by the Xwayland harness; other errors fail.

All original numbered implementation areas now have native/Lua implementations;
acceptance retains these explicit hardware/interoperability gaps. An archive
and green automated tests do not establish production readiness.

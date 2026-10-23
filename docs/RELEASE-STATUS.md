# RayWM v0.2.0 continuation acceptance

Prepared locally on 2026-10-23. This is an **experimental release candidate**,
not a production-readiness declaration. Publication is not authorized.
The archive's `COMMIT` identifies its exact local source revision; its external
release report records final HEAD, archive checksum and full local history.

## Recovery and completed scope

Initial branch: `feature/v0.2.0-complete`; initial HEAD:
`1da71f9f43100ea9615353fc62139d49cc1d6821`. The tree contained tracked
policy/CI/Lua-test edits and untracked shell integration files, protocol XML,
Claude tooling, graph files and an old release backup. Recovery preserved all
of these, with a patch/archive/checksum checkpoint in
`recovery/handoff-20261023/`. No reset, clean or history rewrite was used.
[DEVELOPMENT.md](DEVELOPMENT.md) records the exact initial state and hashes.

The previous developer completed the native foundation, advanced dwindle,
floating/fullscreen/maximize, workspaces, window rules, session lock/idle,
output/input configuration and M8 A/B1. Its interrupted B2 policy/tests were
reconciled and committed first. The initial-configure/decoration deferral was
retained and verified with real shell clients; scheduling before surface
initialization was not reintroduced.

| Milestone | Final implementation state |
|---|---|
| 1–7 | Retained and validated; fixes preserve native View/scene and Lua policy architecture. |
| 8 A–D | Implemented: globals/filtering, shell/decorations, constraints/relative input/inhibitors and foreign-toplevel/workspace protocols. |
| 9 | Implemented: lazy Xwayland, common views/states/workspaces, menus, focus/move/resize, clipboard bridge and bounded crash recovery. |
| 10 | Implemented: native DnD lifecycle/icons, text-input/IME relay, candidate popups and virtual keyboard reinjection. |
| 11 | Implemented: bounded native frame-driven offset/opacity engine, easing/interruption/cancellation and independent close/workspace snapshots; optional plugin. |
| 12 | Implemented within the recovered wlr_scene scope: owned input-transparent rectangles plus existing borders/opacity, integer registration handles and cleanup. Advanced rendering effects remain explicitly unsupported. |
| 13 | Implemented: IPC v1 queries/actions/events, UID/permission checks, bounded framing/queues/clients and raywmctl. |
| 14 | Implemented: API v1 compatibility, ownership/error/reload checks, author documentation, optional examples, CI/integration runner, performance and packaging tools. |

No numbered implementation milestone was silently omitted. Hardware and wider
application acceptance remain separate, explicitly skipped work below.

## Corrections and architecture

Inherited defects corrected during continuation: descendant restacking/focus
on dialog reparenting; non-finite Lua numbers reaching native conversion;
activation accepting enter/no-source/expired/replayed grants; initial opacity
lost during deferred reveal; invalid scanout feedback on outputs without a
DRM device; and shutdown using freed active/abandoned lock backgrounds.
New regressions failed against retained pre-fix binaries where recorded.
The continuation's own DnD cancellation defect was also reproduced and fixed:
source destruction now notifies the client rather than merely ending a grab.
ReleaseSafe C-import and debug-diagnostic build differences were corrected.

The native compositor owns wlroots objects, protocol listeners, the seat,
outputs, View/workspace state and scene nodes. Lua uses integer IDs and owns
policy registrations. X11 and Wayland share view state; IME/DnD delegate native
resource lifetimes to wlroots. Animations retain IDs or separately locked
buffers, run on output frames and execute no per-frame Lua. IPC shares the
event loop through bounded nonblocking callbacks and deferred client cleanup.
Backend teardown precedes scene/cursor/renderer/registry destruction.
[ARCHITECTURE.md](ARCHITECTURE.md) describes the module boundaries.

## Validation matrix

PASS means a stated check ran; historical failures remain in the engineering
record rather than being counted as passes. The full ReleaseSafe run exposed
a lock-shutdown bug; targeted lifecycle reruns passed after fixing it. It also
exposed two test assumptions: asynchronous autostart completion order and a
new virtual keyboard needing time for a lock client to bind it. These checks
now verify the intended asynchronous contract.

| Gate | Result |
|---|---|
| Final Debug build / production ReleaseSafe build | PASS, 8/8 steps each |
| ReleaseSafe test build | PASS, 30/30 steps |
| Zig core + Lua host units | PASS, 38/38 (12 + 26) |
| Lua dwindle / focus / workspace / rules | PASS, 25 / 19 / 12 / 10 scenarios |
| Screenshot policy checks | PASS, 145 checks |
| Format / AST / Lua/shell syntax / C-bool lint | PASS |
| Smoke / focus / documentation examples | PASS; seven executable documentation examples |
| Input / implicit pointer grabs / navigation | PASS, 12 / 13 / 11 scenarios |
| Windows / workspaces / rules | PASS, 16 / 12 / 6 scenarios |
| Session / outputs / devices | PASS, 9 / 7 / 3 scenarios; lock teardown also PASS with GLES2 |
| Protocols / shell / capture / taskbar | PASS, 8 / 16 / 10 / 9 scenarios |
| Screenshots / bounded stress | PASS, 8 screenshot scenarios; window/kill/reload/geometry stress |
| Xwayland | PASS, 6 actual XCB scenarios with clipboard and process restart |
| DnD / text-input / IME | PASS, 10 real-client scenarios |
| Animation / visual primitives | PASS, 7 pixel/lifecycle scenarios, including deferred initial opacity |
| IPC | PASS, 3035 socket checks plus lock gating and replacement-inode preservation |
| Selected headless GLES2 | PASS: capture, taskbar, shell, Xwayland, data, effects, outputs, protocols, session; AMD RX580/radeonsi, OpenGL ES 3.2, Mesa 26.2.5 |
| Performance | PASS as measured samples, with no portable threshold or latency-improvement claim; see PERFORMANCE.md |
| Archive reproducibility / installer / production registry | PASS on the preparatory archive: two identical builds and 160 checks, including actual production Wayland registry, no virtual-pointer manager and a live raywmctl query. Final archive is rebuilt and rechecked from this acceptance commit. |
| Physical DRM/KMS/monitor/input/VT compatibility | SKIPPED; dated manual evidence required |
| Actual GTK/Qt/X11 DnD combinations, fcitx/ibus, Steam/gaming | SKIPPED; custom client success does not prove these applications work |
| Alternate-UID IPC rejection / sanitizers / physical input latency | SKIPPED; kernel credential branch reviewed, same-UID admission tested |
| Blur / shadows / rounded clipping / text/image/shader primitives | NOT IMPLEMENTED; outside the recovered scene-primitive boundary |
| Touch/tablet device routing | NOT IMPLEMENTED; not implied by a protocol global |

Detailed test contracts and commands are in [TESTING.md](TESTING.md).
Headless GPU rendering is distinct from a physical desktop session.

## Compatibility, security and performance

Tested locally with Zig 0.16.0, wlroots 0.20.2 (zig-wlroots 0.20.1), Lua 5.4.9,
Wayland 1.26 on Linux x86_64. Plugin API remains v1; old configuration/snapshot
fixtures pass. Other distributions, wlroots patch builds and real toolkits
need validation against their headers/runtime. The archive is dynamically
linked; direct binary GLIBC symbol requirements reach 2.36, and installed
library dependencies impose their own requirements.

Lua plugins and unrestricted Wayland clients are trusted desktop software.
Security-context clients lose privileged globals; sandbox launchers must also
hide the unrestricted Wayland and IPC sockets. IPC has no eval/spawn command,
checks UID and mode 0600 in a private runtime directory, rejects locked actions
and disconnects slow/flooding peers. Same-user IPC queries can read titles
while locked. Clipboard/data-control access is not revoked by locking.
Snapshots/visuals are bounded and cleaned on retirement/unload/lock; these
controls do not turn Lua into an untrusted-code sandbox. See SECURITY.md.

Final same-host samples: idle CPU below one 10 ms tick over 10 s, RSS with three
windows 18,392→18,480 KiB, startup median 19.78→23.06 ms. Virtual motion+sync median
25.836→32.274 μs varied between runs and is not physical input latency. Three
animation intervals accounted 10/10/20 ms CPU and returned to no idle CPU tick.
Stripped test binaries 666,816→948,352 bytes. Raw hashes/samples and limitations
are in [PERFORMANCE.md](PERFORMANCE.md); the production payload has its own size.

## Readiness and remaining acceptance

Ready for **local experimental distribution and hardware evaluation** after
final archive verification, not proven production use. No push, merge, final
tag or GitHub Release was made. Existing local untracked tooling, backups,
graph files and recovery materials remain outside the release archive.

Known limitations include bounded Xwayland early-crash retries (restart RayWM
when exhausted or launch cannot reach readiness), upstream XWM BadWindow /
property teardown diagnostics, no broad gaming/IME/toolkit claims, advanced
visual primitives listed above, and untested physical behavior. Only the exact
known upstream XWM diagnostics are allowed by its test harness; other errors
fail tests. Follow [HARDWARE-TESTING.md](HARDWARE-TESTING.md) before trusting a
physical session. A green test matrix and an archive do not replace that work.

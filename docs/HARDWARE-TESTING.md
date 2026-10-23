# Physical hardware acceptance

Headless integration checks establish protocol and state-machine
behavior. They do not establish real DRM/KMS, GPU, input-device,
monitor, nested-desktop or toolkit compatibility. Until a dated result
is recorded here, each physical test is **SKIPPED**.

During the continuation, the pointer-constraint/capture suite did run
headlessly with GLES2 and passed 10/10 scenarios. Its renderer was OpenGL
ES 3.2, Mesa 26.2.5, AMD Radeon RX 580/radeonsi (log:
`/tmp/tmp.pztGA4tN7P/raywm.log`). The render node was accessible to an
authorized host test despite being hidden inside the managed sandbox.
That result checks the headless GLES2 rendering path; the physical tests
below remain SKIPPED.

Run the tests in a disposable user session with saved work elsewhere.
Keep a TTY available to stop the compositor or inspect its log. Use the
normal ReleaseSafe binary, never a binary built with `-Dtest-input`.
Keep the commit hash, binary SHA256, command line and log with the
result. Do not log ordinary typed text or clipboard contents containing
private information.

## Record for every run

| Field | Value |
|---|---|
| Date, tester, commit and binary SHA256 | Pending |
| Distribution, kernel, architecture | Pending |
| Zig, wlroots, Lua and Xwayland versions | Pending |
| GPU, kernel driver, renderer and monitor connectors | Pending |
| Monitor modes, scales, transforms and refresh rates | Pending |
| Input-device models; logind or seatd | Pending |
| Nested parent compositor or direct TTY/VT | Pending |

For each row below record **PASS**, **FAIL** or **SKIPPED**, exact steps,
and the relevant log or observation. Mark unavailable functionality
**NOT IMPLEMENTED**, never PASS. A failure needs a reproduction and
regression test where the existing harness can represent it.

## Desktop and hardware matrix

| Area | Procedure and observable result | Status |
|---|---|---|
| Nested startup | Launch `raywm -s foot` inside a Wayland desktop; open/close several windows; clean SIGTERM exit; parent session remains usable. | SKIPPED |
| Direct TTY | Start from a free VT using logind/seatd; keyboard/pointer work; switch away/back with Ctrl+Alt+Fn; exit and restart without stale seat/DRM ownership. | SKIPPED |
| Graphics | Exercise both available pixman/GLES2 paths; resize and expose windows, popups and panels; inspect corruption, freezes and log errors. Record unavailable renderers. | SKIPPED |
| Output configuration | Change a real mode, refresh rate, scale (including fractional), position and rotation; verify client configure/scale feedback and pointer alignment; restore original settings. | SKIPPED |
| Output hotplug | Unplug/replug primary/secondary monitors while windows are tiled/floating/fullscreen and while a pointer button is held; windows remain reachable and held events are not delivered to another client. | SKIPPED |
| Output power/gamma | Test DPMS on/off and a gamma client on supported hardware; output returns usable and gamma resets when its owner exits. Unsupported gamma is reported explicitly. | SKIPPED |
| Pointer/keyboard hotplug | Unplug active pointer during move/resize/text selection, and active keyboard with another attached; later input and focus remain correct. | SKIPPED |
| Device configuration | Exercise applicable acceleration, tapping, scrolling, handedness and keyboard layout/repeat settings; hotplug reapplies; removing settings and reloading restores defaults. | SKIPPED |
| Key layouts | In `us,ru` switch to Russian; all shipped Latin-name shortcuts work; plain typing reaches clients; consumed shortcut keys are not held in newly focused clients. | SKIPPED |
| Tiling/floating/states | Resize/swap/toggle splits; float/tile, maximize and fullscreen; panels reserve usable area; fullscreen covers panels; dialogs remain above parents; leaving states restores geometry. | SKIPPED |
| Workspaces | Switch/move windows on each monitor; hidden/minimized windows get no pointer/keyboard input; focus history restores; fullscreen does not capture focus on another hidden workspace. | SKIPPED |
| Toolkits and popups | Test GTK, Qt, Firefox and foot: menus/submenus at output edges, CSD move/resize, decoration negotiation, minimize/restore, activation urgency and focus decisions. | SKIPPED |
| Implicit pointer grabs | Select text/drag a scrollbar across another window and output; release outside all windows; source gets the release, destination never gets a release without a press. | SKIPPED |
| Pointer constraints | With an implemented client, test lock/confine, relative motion, cursor hints, focus loss, fullscreen/workspace changes, disconnect and output removal; no stuck lock. | SKIPPED |
| Session lock | Lock with swaylock; only lock content appears on every output and screenshots; no bindings operate; hotplug while locked; kill locker and ensure session stays locked; replacement locker can unlock. | SKIPPED |
| Idle | Run swayidle and a visible video player's idle inhibitor; activity resumes; a hidden workspace/minimized inhibitor no longer keeps idle awake. | SKIPPED |
| Capture | Run real grim/slurp with Print bindings and a physical mouse across outputs; verify crop, cancellation, notifications and file/clipboard PNG; test DMA-BUF only if actually used. | SKIPPED |
| Clipboard | Copy/paste regular and primary selections among GTK/Qt/foot, then X11 once implemented; client exit and clipboard-manager ownership changes leave no hung reads. | SKIPPED |
| Drag-and-drop | Once implemented, transfer and cancel among actual GTK/Qt/X11 clients; destination changes, destroyed source/destination and workspace switches leave pointer/keyboard focus usable. | SKIPPED |
| Text input/IME | Once implemented, use an actual IME for preedit/commit, candidate popup placement, app/focus/layout changes, password fields, IME restart and client exit. | SKIPPED |
| Xwayland | Once implemented, X11 applications map/focus/move/resize/fullscreen/minimize and switch workspaces; Xwayland process crash leaves Wayland clients usable and new X11 clients can start. Steam/gaming are separate tests. | SKIPPED |
| Animations/visuals | Once implemented, interrupt transitions rapidly, close a target mid-animation and reload/unload its plugin; no lingering scene nodes, pointer mismatches or unbounded idle rendering. | SKIPPED |
| External shell/IPC | Once implemented, exercise a real external shell against queries, events and actions; slow/disconnected subscribers cannot stall input/rendering; access controls match the documented trust boundary. | SKIPPED |
| Plugin recovery | Reload edited config repeatedly; deliberately fail one plugin; other bindings and native state remain usable; remove ownership-producing plugins and confirm cleanup/fallback behavior. | SKIPPED |

## Performance observations

Use the same machine, renderer, output modes, window workload and build
optimization for the inspected v0.1.2 baseline and the candidate. Record
idle CPU and RSS after settling, startup until socket/client readiness,
input roundtrip distribution, frame cadence and binary size. Run repeated
samples and retain raw data. Input roundtrip time is not physical
key-to-photon latency; call it that only if an actual end-to-end
measurement setup is used.

Measure animations both enabled and disabled, including the return to an
idle desktop. Native animation work should stop after completion or
cancellation. An idle desktop should not repeatedly redraw merely
because an optional animation or visual plugin was loaded.

No new physical performance measurements have been recorded for the
continuation. Historical v0.1.2 headless measurements in TESTING.md are
reference data, not v0.2.0 results.

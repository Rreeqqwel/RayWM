# Rust / Smithay migration — Stages 1–5B

This is the foundation for a future v0.3 migration, **not a v0.3 release**.
The working desktop remains Zig 0.16.0 + wlroots 0.20 + Lua 5.4.
`rust/` is an experimental Rust compositor with a headless protocol mode
and a nested Winit/EGL/GLES mode. Stage 3 added floating multi-window policy,
validated interactive move/resize and XDG popup/grab lifecycle on the Stage 2
virtual output and renderer. Stage 4A added the standard
`wl_data_device_manager` clipboard, independent primary selection, data-device
focus following and a serial policy. Stage 4B adds negotiated client
drag-and-drop with a rendered drag icon, compositor-driven reactive popup
constraints and GTK 4 / Qt 6 pointer-driven DnD qualification. It does not add
a clipboard manager or server-side DnD. Stage 5A extends the existing core
registry with workspaces/output bindings, pure layout contracts, validated
configuration snapshots and typed internal commands. See
[Rust Stage 5A architecture](RUST_STAGE5A.md) and its
[qualification](measurements/v0.3.0/stage5a/qualification.md). Stage 5B
adds hybrid tiling, fullscreen and maximize, workspace shortcuts and
restore geometry. [Stage 5B architecture and controls](RUST_STAGE5B.md) ·
[Stage 5B qualification](measurements/v0.3.0/stage5b/qualification.md).

## Baseline and audit scope

Starting point: `master` / `origin/master` at
`cc6bfbd6d14db7aaa6477cb5a56024892e085575`. Work is on
`feature/rust-smithay`, as requested for this migration. `beta` and `release`
remain generated source-only release trees; neither is an implementation branch.

The dependency graph was queried first, then the current sources and
[architecture](ARCHITECTURE.md), [API](API.md), [plugin contract](PLUGINS.md)
and [test inventory](TESTING.md) were read. Graph results also contain an old
backup tree; the table below refers to the current `src/` implementation.
This is a targeted architecture/lifecycle audit, not proof that all existing
native code is free of use-after-free or double-free bugs.

## Current architecture and migration map

`Server` is the composition root. It owns the display, backend, renderer,
allocator, scene layers, output layout, seat/cursor, native registries and
subsystem managers. Wayland/wlroots owns protocol resources; RayWM wrappers
own listeners, scene nodes and policy state. `host.zig` resolves integer IDs
for Lua instead of exposing native pointers. Lua owns layout, bindings,
rules, naming and optional effect policy. The updater is a separate process.

Rust destinations below describe responsibilities, not pre-created modules.
Stage 1 supplies bootstrap configuration and the compositor state/loop.
Stage 2 starts with a framework-independent desktop model in
`rust/crates/raywm-core/src/windows.rs`: non-recycled u32 window IDs with
checked exhaustion, position/positive size, map/focus state and optional
nested-output assignment. Stage 3 adds stacking, interaction state and focus
fallback to the topmost remaining mapped window; invalid focus requests leave
it unchanged. The compositor adapter connects this model to actual committed XDG surfaces,
Smithay desktop windows and the nested output.

| Current module | Responsibility and dependencies | Smithay responsibility | RayWM Rust destination / ownership |
|---|---|---|---|
| `server.zig`, `main.zig` | composition root, ordered teardown, focus, spawn, event delivery; connects every native subsystem to the Lua host | display/protocol building blocks and backend event sources | `raywm-compositor`: one owned runtime and explicit subsystems; bootstrap implemented |
| `view.zig` | xdg/X11 view model, popups, configure/ack geometry, map/unmap, focus; uses server, outputs, workspace, input, effects | xdg-shell roles, transactions, surface state and popup helpers | compositor view/shell adapter; pure geometry/state transitions can move to core; XDG initial configure/ACK/map/unmap, rendering and role destruction implemented; advanced shell policy deferred |
| `output.zig` | tested output transactions, modes/scale/DPMS/gamma, hotplug recovery, frame/presentation; uses layers, workspace, lock, effects | output globals, backend output/rendering/damage helpers | compositor output/backend adapter; one virtual nested output with positive-size mode updates; physical output transactions deferred |
| `input.zig`, `inputconfig.zig` | keyboard matching/layouts, pointer focus, explicit/implicit grabs, move/resize, device settings; uses views, layers, lock, constraints, Lua | seat, keyboard/pointer handles, input events/grab primitives, later libinput/session backend | compositor input adapter with core key/geometry policy; nested keyboard/pointer forwarding, focus and cleanup implemented; device policy deferred |
| `lua.zig`, `host.zig` | Lua VM, plugin registrations, limits and protected ordered callbacks; host resolves IDs into server/views/workspaces | no Lua/plugin policy | later separate Lua-host crate, framework-independent host command/event boundary; API v1 preserved by contract tests |
| `animation.zig`, `visual.zig` | bounded generation handles, monotonic tweens, retained snapshots/rectangles, plugin ownership; uses output frames and views | buffer lifetime, render elements, damage and synchronization primitives | core easing/handle logic, compositor rendering/snapshot ownership; no Lua frame hooks |
| `workspace.zig` | visibility, output affiliation, active/special overlays, orphan/adopt across reload; depends on server/views/outputs | surface/output primitives only | core desktop state machine plus compositor application of visibility/focus |
| `layer.zig` | panels/backgrounds, usable area, exclusive keyboard focus, layer popups; depends on output/input/view | layer-shell roles and protocol dispatch | compositor shell adapter; pure exclusive-zone geometry in core |
| `ipc.zig` | same-UID NDJSON socket, fixed actions/events, nonblocking I/O, bounded clients/requests/queues; uses host/server/Lua event vocabulary | no IPC policy | independent parser/envelope/limits plus event-loop transport and desktop adapter; no eval |
| `constraints.zig` | active pointer borrow, lock/confine, shortcut inhibition, deferred region commit, emergency release; uses input focus/seat | constraint/relative-pointer/inhibition protocols and handles | compositor capture state machine; clear handles before deactivation/destruction |
| `taskbar.zig` | ID-keyed foreign-toplevel/workspace handles, idle-coalesced publication after native/Lua transitions | supported foreign-toplevel/workspace protocol helpers; verify exact coverage before porting | compositor publication adapter; preserve unsupported protocol contracts explicitly rather than assuming helper parity |
| `lock.zig` | unlocked/locking/locked/abandoned states, presentation barrier, input exclusion and fail-closed locker crash; uses server/outputs/input | session-lock protocol, output presentation and seat primitives | compositor security state machine, independent of Lua policy |
| `xwayland.zig` | lazy Xwayland/XWM lifetime, associations to common views, override-redirect menus, retry timers and clipboard bridge | optional Xwayland server/XWM and selection integration | later compositor X11 adapter; no wlroots FFI in Rust |
| `data.zig`, `textinput.zig`, `protocols.zig` | DnD/icon/serial validation, IME relay, selection/activation/global filtering | corresponding Wayland protocol state and dispatch helpers | explicit compositor protocol adapters; reimplement RayWM eligibility/filtering rules. Stage 4A implements clipboard/primary selection and data-device focus; Stage 4B implements client DnD negotiation and drag-icon rendering. IME, activation and filtering stay deferred |
| `conf.zig`, `settings.zig` | bounded parser, system/user layers, reload validity, restart-only settings | none | independent core configuration parser/model; Stage 1 does not read ray.conf |
| `update.zig` | download/verification/channel/package policy in a short-lived tool | none | independent tool migration after compositor parity; existing tool stays operational |

## Existing invariants to preserve

- **Resource ownership:** clients own their Wayland objects; wrappers own only
  their listeners and native resources. View destroy removes the ID entry,
  destroys its scene tree and removes listeners before freeing the wrapper.
  Popup trees must not outlive their role or a parent's destruction. Rust
  resource clones are handles, not permission to retain stale desktop state.
- **Ordered destruction:** Lua is detached before `Server.deinit`; IPC/timers
  and Xwayland stop before clients, and backend output/device destruction
  occurs while scene/registries/renderer still exist. Preserve this dependency
  order rather than translating each `destroy` call mechanically into `Drop`.
- **Borrow invalidation:** pointer nodes clear on destruction; an active
  constraint borrow clears before deactivation can free a oneshot object.
  Region synchronization runs after wlroots' internal iteration, on commit.
  Layer focus must clear even while locked. These are regression requirements,
  not a claim that Rust handles alone reproduce the behavior.
- **Configure/commit:** geometry follows the acknowledged configure serial,
  including wrap-around and left/top resize anchors. Unmap clears pending
  requests and grabs; remapping does not inherit stale role state.
- **Events/reentrancy:** `view_new` precedes `view_map`; both see the previous
  focus. A plugin's explicit focus choice wins over default map focus.
  `view_will_unmap` allows a snapshot before native state is cleared;
  `view_unmap` follows that transition. Registrations run in insertion order;
  registrations added during dispatch wait for the next event. Re-resolve IDs
  after callbacks: nested events can remove or move workspaces/windows.
- **Plugin lifetime:** mark dead immediately; sweep only after Lua returns;
  failed setup/teardown must not retain registrations. Reload destroys the VM
  and rebuilds it without destroying clients. Workspaces orphan/adopt rather
  than dropping windows. Animation/snapshot resources retain generation
  handles or owned buffers, never borrowed views.
- **Lua limits:** the default VM-wide cap is 64 MiB, with 65536 registrations
  across all plugins and nesting depth 8. One dispatched event and its nested events
  share 10 million VM instructions. All coroutines must be armed, including
  those created before dispatch; `pcall`/yield must not bypass exhaustion or
  blame an innocent caller. Native/library calls are not bounded by the VM
  instruction hook: trusted plugins can still block on I/O. There is no
  existing wall-clock deadline or security sandbox guarantee.
- **Loop and frames:** native input/IPC is nonblocking, timers are integrated
  into the event loop, spawn is detached, and idle outputs do no rendering or
  Lua work. Long-running trusted Lua/native operations remain a known risk.
  Frame callbacks belong to actual visible output progress; buffer release
  is separate from frame completion.
- **Session/output/input:** preserve exclusive layer focus, implicit pointer
  grabs, key/button serial validation, consumed-key suppression, keyboard
  replacement and output/workspace recovery. Lock is acknowledged only after
  all outputs present the locked state; locker death leaves the session locked.
- **IDs:** public IDs resolve again on every call and stale IDs return the
  documented result. Existing documentation says IDs are never reused, but
  `Server.nextId` actually wraps a u32 counter to 1. Rust should reject
  exhaustion or use a checked generation scheme within the Lua numeric
  contract; do not copy wrapping reuse or silently claim it was fixed here.

## Dependency selection and references

Smithay is pinned to **`=0.7.0`** from crates.io with checksums/transitive
versions in `rust/Cargo.lock`. The matching upstream tag is
[`v0.7.0`, commit a166cf4c94b5aedc332a65aa1dd753e8148829c3](https://github.com/Smithay/smithay/tree/a166cf4c94b5aedc332a65aa1dd753e8148829c3).
It is the newest published tag found during Stage 1. A released, exact version
gives a reproducible baseline without depending on a moving master branch.
Dependency upgrades require rebuilding and rerunning the protocol tests.

Reviewed official sources at that tag:

- [Cargo manifest/features](https://github.com/Smithay/smithay/blob/v0.7.0/Cargo.toml).
- [Smallvil state/listener](https://github.com/Smithay/smithay/blob/v0.7.0/smallvil/src/state.rs)
  and its compositor/XDG handlers: a useful small composition example, including
  the distinction between committed surface state and desktop policy.
- [Anvil](https://github.com/Smithay/smithay/tree/v0.7.0/anvil/src): backend and
  protocol integration reference for later work; its broad backend/renderer
  feature set is unnecessary for the bootstrap.
- [Versioned API documentation](https://docs.rs/smithay/0.7.0/smithay/).
  [Upstream development documentation](https://smithay.github.io/smithay/)
  tracks master and must not be treated as the pinned API.

`wayland_frontend` and `desktop` are always enabled. The compositor's optional
`winit` Cargo feature (enabled by default) adds `backend_winit` and
`renderer_gl`, which pull in `backend_egl` and the parent Wayland client.
Smithay defaults remain disabled. No DRM/GBM/libinput/libseat, Smithay X11
backend, pixman renderer, Vulkan or Xwayland backend is enabled. Upstream
Winit itself compiles Wayland/X11 frontend support; use an absolute host
Wayland socket and unset DISPLAY for deterministic Wayland-only launch.
EGL/Mesa may use a render node internally; this does not acquire a KMS device,
VT, input device or session. `--no-default-features` retains a renderer-free
headless build. The small `drm-fourcc` dependency supplies format types.

System requirements are a C linker, pkg-config, xkbcommon, Wayland and an
EGL/OpenGL ES 3 implementation for Winit. Calloop's `signals` feature supplies
signalfd; rustix supplies safe UID validation and test polling/signals.
Tracing formats diagnostics. `wayland-client`, client `wayland-protocols` and
`tempfile` support real-client tests. No Lua binding is selected prematurely.

## Rust implementation (Stages 1–5A)

```text
rust/
  Cargo.toml / Cargo.lock
  crates/raywm-core/
    src/lib.rs                 bootstrap/socket contract and core module exports
    src/windows.rs             registry, lifecycle, committed geometry and interactions
    src/policy.rs              Desktop workspace/output/command transitions
    src/workspaces.rs          workspace/output model types
    src/layout.rs              pure layout inputs, plans and validation
    src/config.rs              typed policy defaults and validation
    src/commands.rs            requests, result events, effects and errors
    tests/stage5a.rs            policy invariants and deterministic transition sequences
  crates/raywm-compositor/
    src/main.rs                CLI, directory validation, display, loop, shutdown
    src/state.rs               core protocol handlers and client data
    src/shell.rs               XDG lifecycle, committed windows and ID adapter
    src/policy.rs              internal command validation and reconciliation
    src/stage5a_tests.rs        real-wire core/Space integration tests
    src/nested.rs              Winit output, EGL/GLES rendering and resize
    src/input.rs               seat focus, keyboard/pointer forwarding and cleanup
    src/grabs.rs               input validation and ID-based move/resize pointer grab
    src/popups.rs              PopupManager adapter, positioning, handshake and grabs
    src/selection.rs           data-device/primary focus, DnD icon, serial policy
  tests/headless.rs            protocol tests and opt-in graphical probe
  tests/floating.rs            Stage 3 real-client lifecycle and graphical probe
  tests/selection.rs           Stage 4A clipboard/primary/focus regressions
  tests/dnd.rs                 Stage 4B DnD/icon and reactive-popup regressions
  tests/nested-smoke.py        private graphical parent and Stage 2/3 dispatcher
  tests/floating-smoke.py      Stage 3 input driver and submitted-pixel assertions
  tests/selection-smoke.py     Stage 4A input driver, foot and wl-clipboard harness
  tests/stage4b-smoke.py       Stage 4B input driver, icon/popup and toolkit harness
```

Core has no dependencies on Smithay, Lua or native backends. Its desktop
model supplies checked IDs, committed geometry, stacking/focus, interaction
state, workspace membership and output association derived through the workspace.
Stage 5A configuration snapshots govern future floating placement; ray.conf
parsing and Lua remain future work. See [the current contracts](RUST_STAGE5A.md).
The private Cargo packages use `0.0.0` and `publish = false`; this is not a
change to RayWM's release version.

The compositor creates a display and registers an owned duplicate of its
poll FD with calloop. The `Display` stays in runtime data, so dispatch uses
ordinary disjoint mutable borrows instead of Smallvil's unsafe
`Generic::get_mut`. Per-client `CompositorClientState` is always installed
before dispatch. The one `expect` documents this internal type invariant;
fallible startup, registration, I/O and loop paths return errors.
Workspace lints forbid unsafe in RayWM code and reject unexplained
`unwrap`/`expect`. This does not claim dependencies contain no unsafe.

The listener owns socket cleanup and does not overwrite an occupied socket.
Every loop iteration sleeps until an event, dispatches requests and flushes
responses. A rejected client admission drops that stream and logs a warning;
display/loop failures terminate with an error status. SIGINT/SIGTERM stop
admission, disconnect clients, dispatch destruction while protocol state still
exists, release client GPU resources and the EGL renderer while Winit is
still alive, then remove event sources before dropping display/state. Startup
failures release already-created resources through ordinary ownership.

Headless globals are `wl_compositor`, `wl_subcompositor`, `wl_shm` and
`xdg_wm_base`. Smithay owns buffers and synchronized subsurface state.
The XDG adapter waits for the initial empty commit before sending configure,
requires an accepted ACK before committing a buffer, maps only committed
renderable buffers, unmaps on null buffers and requires a fresh configure/ACK
on remap. Removing a role or disconnecting removes the view and model ID.
A small delegating XDG-surface dispatch retains the correct protocol resource
for `UnconfiguredBuffer` errors, while Smithay handles the actual requests.
This is necessary with the pinned 0.7.0 API; current master examples differ.
Popups use Smithay’s popup tree attached to their root Window; they are not
independent core windows or Space elements. The shell advertises an empty WM-capability set: maximize, minimize, fullscreen
and window menus are not implemented.

Headless mode has no output, renderer or seat global. Frame callbacks remain
pending because no surface is visible; no presentation is fabricated.
Stage 1 at `aab3b3c` passed its original four tests before Stage 2 changes.

### Window ownership, focus and geometry

`Desktop` is the authority for checked, never-recycled IDs, mapped state,
committed position/size, bottom-to-top order, exclusive root focus and active
operation state. `View` associates an ID with one Smithay `Window` and XDG
handshake metadata; it does not maintain an independent geometry policy.
`sync_scene` projects core order and positions into `Space<Window>`.
Workspace membership is stored only in the core window record; output
association is derived from the workspace binding. Hidden mapped windows leave
Space without becoming protocol-unmapped. A role keeps its ID across
unmap/remap; role destruction or disconnect removes
it from the bindings, core and Space. ID exhaustion returns an error and closes
the new toplevel instead of wrapping.

Default initial placement is a 48-pixel cascade using live IDs in the workspace
and output bounds,
with five offsets. The first live role suggests the output size (preserving
Stage 2 single-window resize behavior); subsequent roles suggest 3/5 of it.
Clients may choose their own positive size. Actual new placement is bounded
using committed size; remap retains its geometry. No first-window pointer is
retained. Interactive dragging may place windows partly outside the output.

A newly mapped window activates while the host has focus and no native grab
is active. A primary or other pointer-button press selects the topmost input
surface’s root window and raises it. During implicit, interactive or explicit
popup grabs a new map cannot steal focus. Removing/unmapping the focused root
falls back to the topmost remaining mapped root; an empty desktop has no focus.
`sync_focus` reconciles root `Activated` state and seat keyboard focus. During
a popup grab the root stays activated while the deepest grabbed popup receives
keyboard input. Host focus loss cancels grabs, releases held input and clears
focus; host focus return selects the topmost mapped window. Invalid/unmapped
focus targets do not disturb the current target.

### Interactive move/resize and configure transitions

`xdg_toplevel.move/resize` must name the compositor’s actual seat and the serial
of its current implicit pointer grab. The initiating button must still be held,
the grabbed surface (including subsurfaces) must belong to that same toplevel
and client, and the root must be focused. Arbitrary, released/stale and foreign
client serials do not start an operation. Popup grabs exclude these operations.
The custom pointer grab retains a stable window ID and native grab start data;
core retains the original pointer and window geometry. Each event re-resolves
the ID. Motion is relative to the original point, with checked/saturating
coordinate arithmetic. Releasing the initiating button finishes the operation;
unmap, role destruction, disconnect and host focus loss cancel it.

All eight resize edges/corners use current committed min/max hints and positive
sizes. Desired geometry is distinct from committed geometry. At most one resize
configure per window awaits an ACK **and surface commit**; later motions and
button release coalesce into the latest desired size/state without a timer or
blocking the event loop. ACK alone never changes geometry or releases that slot.
After an ACKed commit the opposite right/bottom edge is anchored using the
client’s actual committed window size, including client rounding. A final
configure clears `Resizing`; after its ACK/commit the anchor is discarded.
A nonresponsive client can leave its bounded final configure pending until
unmap/disconnect; other clients and input remain responsive. Unmap clears all
operation/flight state and the native Resizing flag before a fresh handshake.

### Popup tree and grabs

Smithay 0.7.0 `PopupManager` owns popup tree order, rendering integration and
standard pointer/keyboard grabs. Adapter entries retain only protocol handshake,
mapped/dismissed state and a checked root ID. Parent traversal accepts live XDG
toplevel/popup roles, rejects cycles/self-parenting/roleless parents and is bounded
to 64 ancestors before calling Smithay’s root helpers. Invalid parents produce
`xdg_wm_base.invalid_popup_parent` on the originating wm_base. A weak error-resource
handle is stored with the wl_surface, without a second client registry.
The immediate parent must be mapped before the popup maps. Initial empty commit
produces configure; an accepted ACK is required before attaching its first buffer.

Positioner geometry is relative to the parent window geometry. Output bounds
are translated through the root and ancestor-popup offsets; Smithay applies
only the positioner’s permitted flip/slide/resize constraint adjustments.
`reposition` prepares that state, returns the original reposition token and
uses the normal configure/ACK/commit transaction. Popup helpers are called
outside the pending-role mutex to avoid recursive locking.

An explicit grab must occur before mapping and match a current held pointer
serial from the root client, the latest delivered pointer press after release
(one grant, at most five seconds, with the same pointer surface and keyboard
focus epoch), a recently delivered keyboard-press serial for that focused root
(one grant, at most five seconds), or an existing nested popup grab serial.
Pointer and keyboard grants are invalidated on keyboard focus transitions and
host focus loss. A successful popup grab consumes the pointer grant. This lets
ordinary GTK/Qt context menus survive a press/release delivered before the
client dispatches its grab request, without accepting forged, expired or
replayed input. Smithay additionally validates topmost-parent/grab ordering.
A rejected grab dismisses its popup without installing partial seat grabs.
Outside-click, client destruction and host focus loss dismiss/ungrab through
Smithay. Native grabs are explicitly cleared when the popup chain ends, even
if clients retain dismissed protocol objects. Keyboard focus returns safely
to the active root/fallback. Popup null-buffer unmap dismisses its subtree.

Root unmap/destruction dismisses the associated popup tree and cancels grabs
before final focus repair. Ancestor destruction also dismisses descendants.
Dismissal detaches surfaces from rendering/hit testing and sends popup_done
once. Client-owned protocol objects cannot be destroyed by the server: inert
bindings remain until the client destroys them or disconnects; they cannot map
again. This is not a second logical-window registry and does not retain a stale
usable root. No custom popup protocol or fake clipboard global is advertised.

### Clipboard, primary selection and focus

Stage 4A advertises exactly two selection globals: `wl_data_device_manager`
(version 3) and `zwp_primary_selection_device_manager_v1` (version 1). They are
registered through Smithay's `DataDeviceState` and `PrimarySelectionState`;
no `wlr-data-control`, `ext-data-control`, Xwayland bridge or compositor-owned
selection is added. Headless mode has no seat, so it can advertise the managers
but cannot create a data device or set a selection.

**Selection ownership.** Smithay's per-seat `SeatData` is the only selection
owner. `SelectionHandler::new_selection` only records the resulting mime types;
RayWM never stores a second `SelectionSource`. When the owning source object is
destroyed, the adapter forces Smithay's broadcast to re-run its liveness check,
so a focused receiver promptly gets a null selection instead of an inert offer.
A replaced or cancelled source is released by Smithay, and a client disconnect
leaves no retained resource in the compositor.

**Seat and focus integration.** The data-device/primary focus is derived from
the existing seat keyboard focus, never from a second focus registry. Every
keyboard `set_focus` site (window focus, fallback after unmap/disconnect, popup
grab and popup-grab end) goes through `raywm-compositor::selection`'s
`set_keyboard_focus`, which applies the keyboard focus and then calls
`set_data_device_focus` / `set_primary_focus` for the same client. A client
that creates another data device while already focused receives the current
offer immediately (Smithay alone waits for the next focus/selection change).
Clients without keyboard focus do not receive selection offers.

**Serial policy.** `wl_data_device.set_selection` and its primary counterpart
pass through a small dispatch adapter before Smithay's implementation. The
requesting client must present a serial that was delivered to it since its
current keyboard focus began: the keyboard-enter serial, a key press, a pointer
button, or a pointer-enter serial. The log holds at most 64 entries for ten
seconds and is cleared on every focus-client change. Missing, forged and stale
serials are denied with a warning and never reach the seat. Smithay still
enforces the protocol baseline: the data device must belong to a real seat and
the requesting client must own the keyboard focus. A serial is therefore a
policy narrowing, not a replacement for seat/focus validation.

**MIME types and data transfer.** The source's `offer` list is passed to the
receiver unchanged. On `wl_data_offer.receive`, Smithay checks the requested
MIME type and forwards the receiver's write end to the source client as
`wl_data_source.send`; the compositor never reads, buffers or copies clipboard
bytes, and no blocking I/O or retry loop exists in the event loop. An unknown
MIME type is rejected before reaching the source and its fd is closed. If a
receiver closes the read end early, the source's write fails with `EPIPE`; that
is client-local and the compositor remains responsive. Both clipboard and
primary selection use the same fd path but independent `SeatData` slots, so
they cannot overwrite each other.

There is no clipboard history, manager, persistence or
copy-on-source-disconnect. foot 1.28.0, wl-clipboard 2.3.0 and minimal
GTK 4.24 / Qt 6.12 probes were exercised as independent clients. Foot's
non-fatal diagnostics about missing XDG activation, fractional scaling,
server-side cursors, toplevel icons and text-input remain accurate limitations.
Stage 4B's DnD, drag-icon and toolkit qualification is described below.

### Drag and drop and drag icons

Stage 4B implements the client-initiated `wl_data_device_manager` DnD state
machine through Smithay's `DnDGrab`. The compositor does not duplicate offers,
targets or action state: Smithay owns `start_drag`, source metadata, the
data-device `enter`/`motion`/`leave`/`drop` events, `accept`/`set_actions`
negotiation, `receive` fd forwarding and `finish`/`cancelled`/
`dnd_drop_performed`/`dnd_finished` delivery. RayWM adds only:

* admission (the serial must match the current held implicit pointer grab,
  its focused surface must equal the origin and belong to the requesting
  client; an active DnD, popup or interactive move/resize cannot be replaced),
* an active-drag flag used to keep orphaned pointer-focus repair from cancelling
  a DnD grab, and
* the drag-icon render state.

Action negotiation uses Smithay's default chooser: a valid preferred
`copy`/`move`/`ask` is kept when offered, otherwise `ask`, `copy`, `move` in
that order. This negotiates the action; it does not move or delete application
data, which remains the clients' responsibility. On a normal release, a drop
is emitted only when the target accepted an
offered MIME type and a non-empty action was chosen. Source-disconnect is a
known exception in the pinned upstream state machine (see Limits below). A
target that accepts an unoffered MIME produces a cancellation, not a drop.

**Drag icon.** `ClientDndGrabHandler::started` stores the optional icon surface
and resets its offset; `dropped` clears it on drop, cancellation, grab unset and
host focus loss, and surface/client destruction also clears it. The icon is not
a `Space` element: it cannot become an input target and is drawn as a
front-to-back custom render element above every window and popup. Its position
is the pointer location translated into the output, plus the icon offset;
Smithay's surface render elements apply the client buffer scale and transform,
and legacy `buffer_delta` from `wl_surface.attach` is accumulated on commit.
The icon is composited only while the pointer is inside the output. A successful
submission sends frame callbacks to buffered surfaces in the icon tree; no idle
redraw is added, and pointer motion requests a frame only while an icon exists.
A commit of the icon or a subsurface updates the overlay.

**Limits.** Smithay does not start compositor-owned (server-side) DnD; RayWM
advertises and implements only client-initiated DnD. Drag icons larger than the
verified paths rely on the ordinary renderer; there is no separate icon cache.
If a source client disconnects while the pointer is over an accepting target,
Smithay 0.7.0's dead-origin pointer-grab cleanup calls `DnDGrab::unset`, which
unconditionally calls its drop path. That path tests accepted MIME/action but
not source liveness: the target gets a drop and leave, and a subsequent receive
gets FD EOF with zero bytes. This violates the protocol's source-destroy
cancellation requirement and can look successful to a target that trusts drop
without validating its payload. An unaccepted offer produces no drop. Icons,
grabs and resources are cleaned and the target/compositor survive. The
[Final qualification](measurements/v0.3.0/stage4b/final-qualification.md)
records the reproducer, event trace and minimal upstream fix direction. No
parallel DnD manager or dependency patch is installed; this remains an upstream
protocol limitation, not a successful transfer.

### Reactive popup constraints

Popup geometry remains Smithay's `PopupManager`/`PopupState`; the adapter adds
no second positioner store. After a parent toplevel commit (move, resize,
window-geometry change), an output mode change, or the end of an interactive
move/resize, `reposition_popups` recomputes every mapped, initially ACKed
popup's constrained rectangle from its current positioner, the root window
position and the current output bounds. A configure is sent only when the
computed rectangle differs from the last one sent or already pending, so pointer
motion, render frames and repeated commits cannot flood the client.

Interactive move/resize deliberately defers the pass until the grab ends,
rather than one configure per motion. Nested popups accumulate their parent
popup's latest pending geometry instead of the last acknowledged geometry, which
avoids a transient `-160,-160` configure followed by the true `-60,-60` value.
A child receives its own configure only when its constrained result changes;
otherwise it follows the parent popup during rendering. Positioners without
`xdg_positioner.set_reactive` are blocked after the first failed attempt and
retain the client's chosen geometry, as required by the protocol. The adapter
also records the last geometry on a client `reposition` request, so the
`repositioned` token and its configure are not duplicated by the next pass.
Parent unmap dismisses the tree, unmap/remap starts a fresh handshake, and
destroying a parent with an unACKed configure leaves no retained popup entry.

### Rendering, output and input

Winit's event source shares the existing calloop with the listener, display
poll FD and signalfd. It opens a normal host window and creates one
`raywm-nested` output, `wl_seat` with keyboard/pointer, and
`zxdg_output_manager_v1`. Logical coordinates deliberately match physical
nested pixels (output scale 1); host scale-factor changes update pixel size.
Resize updates current/preferred mode, discards the old local mode and sends
size-clamping suggestions through XDG configure for windows larger than the
new output; independent floating sizes are otherwise preserved. Window model geometry follows
committed buffers, never a configure request alone. Zero-size targets are not
rendered until a positive resize.

The rendering path uses `Space<Window>`, `OutputDamageTracker` and Smithay's
GLES surface render elements. Each requested frame binds the EGL framebuffer,
clears the background and draws committed windows in core order, with Smithay’s
popup trees above their respective parents. Buffer age zero gives
safe full redraws; texture/import caches remain owned by Smithay. GPU objects
are not recreated in an idle loop. Winit's submit performs pre-present
notification and swaps; only a successful render/submit allows frame callbacks
for surfaces present in the render report. Bufferless/occluded surfaces do not
receive fabricated callbacks. This is frame readiness, not a physical presentation-time
or latency guarantee. EGL/startup/render/submit errors exit through teardown;
context recreation is deferred.

Redraws are coalesced for commits (including frame requests), resize, focus and
host exposure. There is no perpetual `request_redraw`, polling frame timer or
idle animation. The event loop sleeps when there is no work. Rendering is
still a full-output operation when work is requested; optimized damage/buffer
age policy and explicit synchronization are later work.

Keyboard events use Smithay's keyboard state and target the focused mapped
window or deepest grabbed popup. Pointer hit testing uses the desktop space
and Window surface trees (including nested subsurfaces/popups), with Smithay's implicit
click grab; a click selects/raises the target. Host focus loss releases held
keys/buttons and clears child focus. Unmap/destruction clears invalid native
focus; an orphaned held-button interaction cannot send a release to a new
surface. No host input is injected by the compositor. Host pointer imagery
remains Winit's cursor; client cursor surfaces are not rendered yet. Smithay
0.7 Winit does not expose a distinct cursor-leave event, so pointer leave is
handled through hit testing, focus loss and surface lifetime. Scroll axes are
forwarded; touch, gestures and compositor key/modifier bindings remain outside
this stage. Interactive geometry comes from standard client requests.

### Running

The CLI is `raywm-smithay [--backend headless|winit] [--socket NAME]`.
Headless remains the default and needs no parent display. `--help` / `-h`
needs no runtime directory; a headless-only binary rejects Winit explicitly.
The default socket auto-selects `wayland-1` through `wayland-32` inside
XDG_RUNTIME_DIR. Names are ASCII basenames (letters, digits, `.`, `_`, `-`,
except `.`/`..`); bind/path-length errors are reported. The runtime directory
must be absolute, owned, mode 0700 and not a symlink.

For nested launch, preserve the original host socket as an absolute path
before selecting a private child runtime. RayWM never changes WAYLAND_DISPLAY
inside its process; Winit must connect to the parent and clients must connect
to the new server socket. Build/run commands, prerequisites and both launch
modes are in [INSTALL.md](INSTALL.md#experimental-rust-foundation). The process
reads no ray.conf/Lua configuration and never acquires a VT or session.

## Verification and limits

Baseline was recorded before Rust implementation, using Zig 0.16.0 at
`/home/reyz/.local/opt/zig-x86_64-linux-0.16.0/zig` (not initially on PATH),
wlroots 0.20.2, Wayland 1.26.0, Lua 5.4.9 and xkbcommon 1.13.2:

| Command | Result |
|---|---|
| `zig build` | PASS |
| `timeout 600 zig build test --summary all` | PASS: 77 Zig tests, six Lua runs; expected invalid-keymap diagnostics are not a failure |
| `zig build -Dtest-input -p zig-out/test-input` | PASS |
| `SUITES="smoke focus docs docs-sync captures session ipc" tests/run.sh zig-out/test-input/bin /tmp/raywm-stage1-zig-integration` | PASS: all seven suites; 8 documented plugin examples, 11 capture scenarios, 10 session scenarios, 3053 IPC checks plus lock/path lifecycle cases |

Historical Stages 1–4B checks used Rust/Cargo 1.99.1. Stage 5A uses 1.100.0;
see its qualification report for current results. Commands run from `rust/`:

```sh
cargo fmt --all -- --check
cargo check --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo build --workspace --locked
```

Stage 5A results are recorded in its
[qualification report](measurements/v0.3.0/stage5a/qualification.md). The default
test command runs 36 automatic tests (20 core, five core/Smithay integration,
eleven protocol/process); six graphical tests are explicitly ignored there
and run by the separate smoke scenarios below. Headless-only clippy/tests and
`tests/docs-sync.sh` also pass. The original process/protocol regressions remain
in place. Source equality confirms protected Zig/build/config/protocol files
and Cargo dependency manifests/lock are unchanged.

`cargo test` retains a core socket-path validation test and the original five
subprocess smoke tests: registry/sync and mandatory shm formats; buffer
commit/detach/destroy; synchronized subsurface release ordering; no false
frame completion; reconnects; malformed-client isolation; active-client
shutdown by SIGINT/SIGTERM; auto/named socket cleanup; collision preserving
the original server; bad arguments and missing, relative, public or symlinked
runtime directories. Every
server runs with a scrubbed environment and private directory. Startup,
protocol reads and exit waits have five-second deadlines and children are
killed/reaped on failure. XDG tests additionally observe initial configure/ACK,
bufferless non-mapping, map/unmap, fresh remap, role recreation, invalid ACK
and early-buffer protocol errors, release and abrupt disconnect. The Stage 4A
headless test verifies both manager globals/versions, source creation with
multiple MIME types, destroy ordering and isolation from a following client.
These checks establish more than compilation.

The graphics qualification commands are:

```sh
python3 rust/tests/nested-smoke.py
python3 rust/tests/nested-smoke.py --stage3
python3 rust/tests/selection-smoke.py
python3 rust/tests/stage4b-smoke.py
```

It uses the unchanged Zig `-Dtest-input` binary as a private headless pixman
parent, with llvmpipe OpenGL ES 3.2 / EGL 1.5. All inherited display/socket
variables are scrubbed; all virtual input goes only to the parent created by
this invocation. The Rust client checks frame callbacks, XDG configure/ACK,
wl_output resize, actual key/button/motion events and unmap focus/output leave.
The parent screenshots verify red/green/blue/white quadrants at 800x600 and
700x500 after resize, including orientation. Client, Rust compositor and parent
must exit; socket/lock cleanup is asserted. Logs and PNGs remain in the printed
new `/tmp/raywm-stage2-*` or `/tmp/raywm-stage3-*` directory. Selected Stage 3
qualification evidence is retained under `docs/measurements/v0.3.0/stage3/`.

Stage 2 passes the graphical smoke, including a bufferless child surface
that must receive no frame callback. An additional nested launch in the
existing host Wayland session passes with the unchanged independent Zig
raywm-test-client: configure/ACK, a real submitted frame, role destruction and
SIGTERM/socket cleanup. That host run injects no keyboard/pointer events;
input/pixel/resize assertions belong to the private parent test. These are
nested/software qualifications, not physical hardware or GPU-driver coverage.

Stage 3 adds real-client checks for three independent connections, remap,
middle/active removal, rapid role creation/destruction, popup ACK/error scope,
nested positioning/reposition tokens, null-buffer ancestor dismissal and
invalid/self/roleless/unmapped parents. Its private graphics scenario verifies
three visible windows and overlap colors, click activation and exclusive key
delivery, real pointer-serial move, stale/foreign serial rejection, left/top
resize with delayed ACK, min/max, final anchor pixels, nested popup rendering,
local pointer coordinates and keyboard focus, outside-click, parent destruction
while held, keyboard-triggered popup, new-map grab isolation, popup disconnect,
resize unmap/remap and mid-resize disconnect with orphan-release suppression.
Three unchanged independent Zig clients also run concurrently, render a real
synchronized subsurface and use its pointer serial for a CSD move, confirmed by
client logs and pixels. The independent Stage 2 smoke remains unchanged in its observations. Saved
images, environment and exact run results are described in the Stage 3 evidence
record; these establish nested software behavior, not a general desktop claim.

Stage 4A adds a private-parent selection scenario with two independent Wayland
clients and real focus changes. The client sets the clipboard with the serial
from its actual `wl_keyboard.enter`, verifies focus-owner switching, reads three
different MIME types through real fds, proves the unfocused receiver gets no
offers, clears the selection, rejects forged and focus-stale serials (observed in
the compositor log), recreates a data device while focused, destroys a source,
closes a pipe early, requests an unoffered MIME type, unmaps/remaps the owner and
disconnects both a receiver and a source client. Primary selection is set and
read independently and does not replace the clipboard. The same compositor then
qualifies foot 1.28.0: mapped/rendered pixels, keyboard input into a shell,
mouse selection to primary, Ctrl+Shift+C copy to `wl-paste`, and
`wl-copy` → Ctrl+Shift+V paste into foot measured through the shell. Minimal
GTK 4 and Qt 6 windows then map/render, receive typed text, copy it to
`wl-paste` and paste from `wl-copy`, with the text confirmed through files
written by the probe applications. The compositor survives every teardown and
shuts down cleanly. Evidence is retained
under `docs/measurements/v0.3.0/stage4a/`. These are nested/software
qualifications, not physical hardware or toolkit-matrix coverage.

Stage 4B adds three opt-in graphical Rust scenarios driven by
`stage4b-smoke.py`. The DnD
scenario uses a real held pointer from one persistent virtual-input process and
two independent Wayland clients. It verifies: a forged serial cannot start a
drag; the source action set (copy/move/ask) and an Ask preference reach the
target; target switching produces leave/enter without motion on the wrong
device; a live clipboard transfer during DnD; a yellow 32x32 icon at the pointer
above the target and its disappearance after drop/cancel/destroy; per-MIME
payload; EPIPE containment; finish exactly once; source and target disconnect
without fake data; a fresh drag after teardown; and a stale serial rejection.
The popup scenario opens a parent popup and a large nested popup, moves the
toplevel with a real pointer grab, checks the constrained configure and screen
position, shrinks the output 800x600 → 700x500, moves back, verifies nested
following and ACK/commit, exercises a bottom-right parent resize without
configure churn, a valid reposition token, parent unmap/remap dismissal and a
destroyed parent with an unACKed configure. Pixels come from `grim` after a real
frame callback; no test-only compositor state is read.

The same harness compiles small GTK 4.24 and Qt 6.12 probes against the
installed development files (failing with a BLOCKED reason if absent) and runs
pointer-driven toolkit DnD:

| Scenario | Result |
|---|---|
| GTK source → Qt target, payload checked | PASS |
| Qt source → GTK target, payload checked | PASS |
| Cancelled toolkit drag (return to source) | PASS, no drop |
| Target process closed mid-drag | PASS, source/compositor survive |
| Source process closed mid-drag | PASS, target/compositor survive, no data |
| GTK context-menu popup | PASS |
| Qt context-menu popup | PASS |
| Qt nested submenu popup | PASS: two hover-opened submenu levels, wire configure/ACK, submitted pixels, child motion and outside-click teardown |
| Qt primary selection from a text selection | PASS |
| GTK primary selection from a text selection | PASS: real GtkTextView pointer selection, standard `zwp` source/serial, independent receiver and exact UTF-8 FD payload |

The toolkit results are nested/software observations with frameless probe
windows, not a full application or theme matrix. The original GTK attempt
selected a non-selectable label containing no test payload; the original Qt
root grab was denied after release, before any submenu could open. Final
qualification fixes the GTK widget and RayWM popup admission, checks fresh
motion after enter and restores output size between scenarios. It also tests
foreign DnD serials, wrong origins, active-drag replacement, popup grant replay,
expiry/focus changes and an accepted-offer source disconnect. Evidence,
payloads, traces and images are in the
[Stage 4B-Final report](measurements/v0.3.0/stage4b/final-qualification.md).

### Prototype limits

Winit supports one nested output, full redraw, Master-Stack, Columns, Monocle
and Floating, plus XDG maximize and fullscreen. Workspace/output transitions
are qualified with virtual outputs through the core and Smithay Space.
Standard clipboard, primary selection, and client DnD with a drag icon are
implemented. Server-initiated DnD, native outputs, client cursor rendering,
server-side decorations, minimize, the compositor window menu, layer-shell,
Xwayland, Lua, IPC, ray.conf and effects remain deferred.

Physical DRM/KMS/input/hotplug, hardware GL, full GTK/Qt applications, IME,
server-side DnD, device rules, fractional client scaling, presentation-time,
sanitizers and production resource/admission budgets remain unqualified. If a
DnD source
disconnects with the pointer over an accepting target, Smithay may still emit a
drop indication with no data (documented above). Output resize updates the
mode, recalculates tiling, and may suggest a smaller floating size. Popup constraints react to parent/output changes
for reactive positioners; non-reactive clients keep their chosen geometry.
The unchanged Zig suites are not rerun wholesale in Stages 2/3/4A/4B; the Stage 1
baseline remains historical and source equality is checked. Context-loss
recovery and optimized damage tracking are deferred. This is a controlled
prototype, not an installed desktop.

## Lua API v1 preservation strategy

1. Use [API.md](API.md), [PLUGINS.md](PLUGINS.md), `src/lua.zig` and
   `src/host.zig` as the compatibility oracle. Retain Lua 5.4, API version 1,
   loading paths, plugin metadata, arguments, table fields, return/error
   values, settings and event vocabulary. Do not replace them with Rust
   userdata or native pointers exposed to plugins.
2. Put the VM/registration machinery behind a small host interface, independent
   of Smithay. Choose a Rust Lua binding only after verifying Lua 5.4 error
   handling across Rust frames, allocator/OOM behavior, hooks on all threads,
   coroutine/pcall bypass protection and explicit reference ownership. Lua
   longjmp must not cross Rust values requiring destruction. A small audited
   Lua/C trampoline may be needed; no Zig/wlroots compositor bridge is allowed.
3. Execute the current fake-host unit scenarios against the Rust host and run
   unchanged shipped plugins plus all eight documentation examples. Preserve
   order/reentrancy, deferred sweep/reload, ownership cancellation, teardown
   fault isolation, managed windows, workspace adoption, limits and no per-frame
   Lua. Compare observable event traces, not internal implementation details.
4. Extend the host adapter incrementally as real Rust desktop operations become
   available; do not expose dummy-success functions. Until parity passes, the
   Zig desktop remains the supported implementation.

## Subsequent stages and release gates

1. **Stage 2 — implemented:** optional Winit backend,
   compositor-owned output/render target, xdg-shell initial configure/ack/map,
   real shm rendering/damage, visible frame callbacks, buffer release and basic
   pointer/keyboard focus. Test parent resize, null-buffer unmap, role destroy,
   abrupt disconnect and shutdown, all within a private nested test session.
2. **Stage 3 — implemented:** floating multi-window state/order/focus,
   validated pointer move/resize with ACK/commit anchors and bounded configure
   flow, standard popup positioning/nested grabs/dismissal and lifecycle tests.
   Preserve these protocol and pixel regressions before adding policy or services.
3. **Stage 4A — implemented:** standard
   `wl_data_device_manager` clipboard and independent primary selection,
   data-device focus following the existing keyboard focus, input-serial
   policy, immediate source-death rebroadcast, real fd transfer tests and
   foot/wl-clipboard qualification.
4. **Stage 4B — implemented:** client-initiated negotiated DnD with action
   negotiation, a frontmost drag icon with scale/transform/commit handling,
   source/target/cancel/teardown tests, compositor-driven reactive popup
   constraints with nested-popup coalescing, and pointer-driven GTK 4 ↔ Qt 6
   qualification, GTK primary selection and two hover-driven Qt submenu levels.
   Server-side DnD, a full toolkit matrix and the pinned Smithay source-disconnect
   protocol defect remain open; see the Final qualification.
5. **Stage 5A — implemented:** unified managed-window/workspace/output model,
   floating and stateful layout contracts, validated configuration snapshots
   and internal typed commands with controlled Smithay reconciliation.
   **Stage 5B — implemented:** tiling algorithms, workspace user controls,
   mode transitions and XDG configure/restore policy. **Stage 5C remains
   deferred:** Lua host, compatible configuration loading/reload and
   adversarial plugin tests. Parallel Zig/Rust
   executables use independent private sockets/config roots.
6. **Shell and services:** layer-shell, lock/presentation barriers, capture,
   selection/DnD/IME, activation/filtering, taskbar/workspace publication and
   bounded same-UID IPC. Verify every old protocol version/limit against the
   pinned Smithay capability; write adapters only for proven gaps.
7. **Effects, Xwayland and native sessions:** native render elements/snapshots,
   synchronization/damage/performance; XWM lifecycle/selection bridge;
   explicit DRM/libinput/libseat backend. Hardware work requires a separate
   safe test session and [hardware checklist](HARDWARE-TESTING.md).
8. **Cutover:** packaging, CI, docs, updater and generated release allowlists
   move to Rust only after the gates below; no Stage 1 release promotion.

Primary risks are semantic drift despite compiling protocol handlers,
reentrant state mutation, Lua longjmp/OOM safety, stale handles, buffer/explicit
sync lifetime, lock acknowledgement timing, protocol coverage gaps and the
cost of rebuilding scene/damage/effect behavior without wlroots' scene graph.
Smallvil is an example, not a compatibility guarantee; copying Anvil wholesale
would add dependency and policy complexity without proving RayWM parity.

Before deleting Zig/wlroots, require all of the following: unchanged plugins
and API documentation examples pass; every existing unit/integration suite
has a Rust equivalent or an explicitly reviewed retirement; IPC/config/error
limits and reload semantics match; protocol/resource/error-path tests pass;
hardware session/input/hotplug and toolkit/Xwayland/IME checks pass; security
review covers capture/lock and Lua boundaries; measured idle CPU, memory,
frame scheduling, latency and effect costs are acceptable against the Zig
baseline; release packaging/updater/recovery are tested; published docs and
release scripts describe the actual Rust tree. Only a later explicit cutover
task may remove the Zig source or wlroots build dependencies.

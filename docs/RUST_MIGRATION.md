# Rust / Smithay migration — Stage 1

This is the foundation for a future v0.3 migration, **not a v0.3 release**.
The working desktop remains Zig 0.16.0 + wlroots 0.20 + Lua 5.4.
`rust/` is a separate, experimental, headless protocol server. It does not
load plugins, render windows, create outputs or provide desktop input.
No Zig module, package payload, release branch or project version is replaced.

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
Only the bootstrap configuration and compositor state/loop exist in Stage 1.

| Current module | Responsibility and dependencies | Smithay responsibility | RayWM Rust destination / ownership |
|---|---|---|---|
| `server.zig`, `main.zig` | composition root, ordered teardown, focus, spawn, event delivery; connects every native subsystem to the Lua host | display/protocol building blocks and backend event sources | `raywm-compositor`: one owned runtime and explicit subsystems; bootstrap implemented |
| `view.zig` | xdg/X11 view model, popups, configure/ack geometry, map/unmap, focus; uses server, outputs, workspace, input, effects | xdg-shell roles, transactions, surface state and popup helpers | compositor view/shell adapter; pure geometry/state transitions can move to core; no toplevels yet |
| `output.zig` | tested output transactions, modes/scale/DPMS/gamma, hotplug recovery, frame/presentation; uses layers, workspace, lock, effects | output globals, backend output/rendering/damage helpers | compositor output/backend adapter; core validation and placement; no outputs yet |
| `input.zig`, `inputconfig.zig` | keyboard matching/layouts, pointer focus, explicit/implicit grabs, move/resize, device settings; uses views, layers, lock, constraints, Lua | seat, keyboard/pointer handles, input events/grab primitives, later libinput/session backend | compositor input adapter with core key/geometry policy; no seat or input yet |
| `lua.zig`, `host.zig` | Lua VM, plugin registrations, limits and protected ordered callbacks; host resolves IDs into server/views/workspaces | no Lua/plugin policy | later separate Lua-host crate, framework-independent host command/event boundary; API v1 preserved by contract tests |
| `animation.zig`, `visual.zig` | bounded generation handles, monotonic tweens, retained snapshots/rectangles, plugin ownership; uses output frames and views | buffer lifetime, render elements, damage and synchronization primitives | core easing/handle logic, compositor rendering/snapshot ownership; no Lua frame hooks |
| `workspace.zig` | visibility, output affiliation, active/special overlays, orphan/adopt across reload; depends on server/views/outputs | surface/output primitives only | core desktop state machine plus compositor application of visibility/focus |
| `layer.zig` | panels/backgrounds, usable area, exclusive keyboard focus, layer popups; depends on output/input/view | layer-shell roles and protocol dispatch | compositor shell adapter; pure exclusive-zone geometry in core |
| `ipc.zig` | same-UID NDJSON socket, fixed actions/events, nonblocking I/O, bounded clients/requests/queues; uses host/server/Lua event vocabulary | no IPC policy | independent parser/envelope/limits plus event-loop transport and desktop adapter; no eval |
| `constraints.zig` | active pointer borrow, lock/confine, shortcut inhibition, deferred region commit, emergency release; uses input focus/seat | constraint/relative-pointer/inhibition protocols and handles | compositor capture state machine; clear handles before deactivation/destruction |
| `taskbar.zig` | ID-keyed foreign-toplevel/workspace handles, idle-coalesced publication after native/Lua transitions | supported foreign-toplevel/workspace protocol helpers; verify exact coverage before porting | compositor publication adapter; preserve unsupported protocol contracts explicitly rather than assuming helper parity |
| `lock.zig` | unlocked/locking/locked/abandoned states, presentation barrier, input exclusion and fail-closed locker crash; uses server/outputs/input | session-lock protocol, output presentation and seat primitives | compositor security state machine, independent of Lua policy |
| `xwayland.zig` | lazy Xwayland/XWM lifetime, associations to common views, override-redirect menus, retry timers and clipboard bridge | optional Xwayland server/XWM and selection integration | later compositor X11 adapter; no wlroots FFI in Rust |
| `data.zig`, `textinput.zig`, `protocols.zig` | DnD/icon/serial validation, IME relay, selection/activation/global filtering | corresponding Wayland protocol state and dispatch helpers | explicit compositor protocol adapters; reimplement RayWM eligibility/filtering rules |
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

Only `wayland_frontend` is enabled; Smithay default features are off. There
is no DRM, GBM, libinput, libseat, Winit, X11, GLES, pixman renderer or Xwayland
backend in the Rust build. The `drm-fourcc` crate in the lockfile supplies
format types and does not open DRM devices. Smithay still requires
`libxkbcommon` at link time. Calloop's `signals` feature supplies signalfd;
rustix supplies safe runtime-directory UID validation (and test polling/signals).
Tracing and its formatting subscriber supply diagnostics. `wayland-client`
and `tempfile` are test dependencies. No Lua binding is chosen prematurely.

## Stage 1 implementation

```text
rust/
  Cargo.toml / Cargo.lock
  crates/raywm-core/
    src/lib.rs                 validated socket basename, config and error
  crates/raywm-compositor/
    src/main.rs                CLI, directory validation, display, loop, shutdown
    src/state.rs               compositor/subcompositor/shm handlers, client data
  tests/headless.rs            isolated process and real protocol tests
```

Core has no dependencies on Smithay, Lua or native backends. IDs, general
configuration models, geometry and state machines will be added when their
first actual consumer is ported, with exhaustion/range behavior tested then.
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
exists, then remove event sources before dropping display/state. Startup
failures release already-created resources through ordinary ownership.

Advertised globals are exactly `wl_compositor`, `wl_subcompositor`, `wl_shm`.
Smithay's commit buffer helper handles synchronized subsurfaces, current
buffer replacement and destruction without reading pixels. No surface is
visible, so frame callbacks remain pending; no presentation is fabricated.
This is a renderer-free headless protocol harness, not Smithay's DRM/Winit
backend or an off-screen graphical renderer. XDG-shell/window rendering and
input are deliberately Stage 2 so they can be validated together.

Manual private launch (Linux; build and install prerequisites are in
[INSTALL.md](INSTALL.md#experimental-rust-foundation)):

```sh
cd rust
cargo build --locked --workspace
runtime=$(mktemp -d)
chmod 700 "$runtime"
env -i XDG_RUNTIME_DIR="$runtime" target/debug/raywm-smithay --socket raywm-test
# The server logs the socket path. Press Ctrl+C to stop, then remove the directory.
rmdir "$runtime"
```

`--help` needs no runtime directory. The default socket auto-selects
`wayland-1` through `wayland-32` inside `XDG_RUNTIME_DIR`. `--socket NAME`
accepts an ASCII basename (letters, digits, `.`, `_`, `-`, except `.`/`..`);
OS path-length/bind errors are reported. The runtime directory must be
absolute, owned by the current UID, private (mode 0700), and not a symlink.
The process does not change `WAYLAND_DISPLAY`, connect to a parent display,
read user configuration, request a VT or access input/DRM devices.

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

Rust checks run from `rust/` with Rust/Cargo 1.99.1. This is the verified
toolchain, not a claim that older Rust versions were tested:

```sh
cargo fmt --all -- --check
cargo check --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

All four commands PASS, including clippy with warnings denied and all four
tests (one core test, three subprocess/protocol tests). `cargo build --locked
--workspace` also links the runnable server. `tests/docs-sync.sh` passes.

`cargo test` includes a core socket-path validation test and three real
subprocess smoke tests: registry/sync and mandatory shm formats; buffer
commit/detach/destroy; synchronized subsurface release ordering; no false
frame completion; reconnects; malformed-client isolation; active-client
shutdown by SIGINT/SIGTERM; auto/named socket cleanup; collision preserving
the original server; bad arguments and missing, relative, public or symlinked
runtime directories. Every
server runs with a scrubbed environment and private directory. Startup,
protocol reads and exit waits have five-second deadlines and children are
killed/reaped on failure. These checks establish more than compilation.

Remaining Zig integration suites, ReleaseSafe, GLES, leak checking,
sanitizers and physical DRM/KMS/input/hotplug are not run for Stage 1.
Rust has no graphical smoke result because it has no renderer yet. Neither
the Zig headless baseline nor the Rust protocol tests establish physical
hardware or GTK/Qt/Xwayland/IME interoperability. Lua, IPC and configuration
compatibility are **not implemented in Rust** at this stage. The harness
does not yet enforce production per-client object/buffer/memory budgets;
it is for controlled local tests, not an installed desktop session.

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

1. **Stage 2 — one nested graphical window:** optional Winit backend,
   compositor-owned output/render target, xdg-shell initial configure/ack/map,
   real shm rendering/damage, visible frame callbacks, buffer release and basic
   pointer/keyboard focus. Test parent resize, null-buffer unmap, role destroy,
   abrupt disconnect and shutdown, all within a private nested test session.
2. **Desktop state:** checked IDs, configure geometry/resize, popup roles/grabs,
   seat serials, focus/input matching, output scale/hotplug and pure workspace
   state machines. Port existing exact-event and pixel tests before expanding.
3. **Lua host and settings:** compatibility boundary and unchanged API v1,
   parser/layered reload, adversarial budget/ownership tests and plugin traces.
   Parallel Zig/Rust executables use independent private sockets/config roots.
4. **Shell and services:** layer-shell, lock/presentation barriers, capture,
   selection/DnD/IME, activation/filtering, taskbar/workspace publication and
   bounded same-UID IPC. Verify every old protocol version/limit against the
   pinned Smithay capability; write adapters only for proven gaps.
5. **Effects, Xwayland and native sessions:** native render elements/snapshots,
   synchronization/damage/performance; XWM lifecycle/selection bridge;
   explicit DRM/libinput/libseat backend. Hardware work requires a separate
   safe test session and [hardware checklist](HARDWARE-TESTING.md).
6. **Cutover:** packaging, CI, docs, updater and generated release allowlists
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

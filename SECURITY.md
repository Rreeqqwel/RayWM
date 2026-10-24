# Security

RayWM is experimental software. The v0.2 development branch runs as your
user, owns your display, and receives all keyboard and pointer input. Treat it with the
same care as any other compositor.

## Lua plugins are trusted code — there is no sandbox

(One robustness rule that is not a sandbox: Lua code is only ever loaded
from source. Lua does not verify precompiled chunks, and a damaged one can
crash the interpreter and with it the compositor, so `init.lua`, plugins,
`load`, `loadfile`, `dofile` and `require` refuse binary chunks.)

Plugins (`~/.config/raywm/init.lua` and `plugins/*.lua`) run inside the
compositor with the full Lua standard library:

- `io` can read and write any file your user can access;
- `os.execute` and `raywm.spawn` start programs;
- `os.exit` terminates the compositor;
- all plugins share one global environment and can affect each other.

**Only install plugins you have read and trust**, as you would a shell
script in your `~/.profile`.

What RayWM *does* do, to contain mistakes rather than attacks:

| Measure | What it protects against | What it does not do |
|---|---|---|
| Every callback runs under `pcall`; a failing plugin is unloaded | a buggy plugin taking the compositor down | stop a plugin from misbehaving without raising errors |
| Memory cap (64 MiB, shared) | runaway allocation | per-plugin accounting; a hoarding plugin can cause another plugin's allocation to fail |
| Instruction budget per callback, re-raised on every instruction once exceeded (so `pcall` cannot swallow it) | infinite loops freezing the compositor | limit total CPU time over many callbacks |
| No `debug` library, no `package.loadlib`, no C module searchers | corrupting internal state through upvalues and the registry; loading native code from Lua | prevent other ways of misbehaving (for example `load` with crafted bytecode) |
| Integer ids instead of native pointers; ids checked on every call | use-after-free through stale handles | — |
| Coordinates clamped, geometry math saturating | arithmetic overflow from extreme values | — |

Crafted Lua bytecode passed to `load` can crash the Lua VM. This is
another reason why plugins have to be trusted.

## Wayland clients and privileged protocols

Ordinary clients connected to RayWM's Wayland socket are trusted to use
the privileged protocols RayWM advertises. There is no per-application
permission prompt or portal policy in the compositor.

- **Screen capture.** `wlr-screencopy-unstable-v1` lets ordinary clients
  capture every RayWM output, whether or not `screenshot.lua` is loaded.
  Unloading that plugin only removes its bindings. A nested RayWM session
  captures its own outputs, not the parent compositor's desktop.
- **Clipboard and primary selection.** wlr-data-control and
  ext-data-control let ordinary clients read and replace selections
  without keyboard focus. This enables wl-clipboard and clipboard
  managers, and also exposes copied data to other ordinary clients.
  Screen locking does not revoke their clipboard-manager access.
- **Desktop control.** Ordinary clients can use the advertised output
  configuration, power, gamma, layer-shell and session-lock protocols.
  Foreign-toplevel/workspace management has the same trust boundary.
  Requests that alter focus/state are refused during session lock.

RayWM implements `security-context-v1` through wlroots. A launcher can
provide a dedicated listening socket for restricted clients. wlroots
attaches context metadata to clients accepted through that socket;
RayWM's global filter then denies privileged globals both when the
registry is advertised and when a client attempts to bind them.
The policy is based on the presence of that context, not on trusting a
particular `app_id` or `sandbox_engine` string.

The denied interfaces include screencopy/image capture, both data-control
protocols, output management/power/gamma, foreign-toplevel/workspace
management, session lock, layer shell, virtual input, input methods, and
the security-context manager itself. The exact list lives in
`src/protocols.zig`; some entries reserve the boundary for protocols that
are not yet implemented. Core drawing/input protocols and ordinary
focused-client clipboard operations remain available.

This filter does not create an OS sandbox, authenticate an application,
or detect sandboxes automatically. A sandbox launcher must prevent its
clients from reaching the unrestricted Wayland socket. It also does not
isolate trusted Lua plugins or protect against other processes with the
same user's unrestricted filesystem/process access. The headless
security-context regression uses a real restricted listener; it does
not establish compatibility with every sandbox launcher.

## Session locking

`ext-session-lock-v1` owns the visual/input lock state. RayWM hides the
other scene layers and places opaque backgrounds under lock surfaces.
It sends the initial `locked` event only after each enabled output has
presented a frame committed after that state was applied. Outputs
without a lock surface remain covered. While locking or locked,
ordinary window/layer focus and compositor key bindings are refused;
VT switching remains available. Screenshots show the lock scene.

The locker is trusted to authenticate the user before sending
`unlock_and_destroy`. RayWM does not implement authentication or verify
that a lock client is swaylock. A second locker is refused while the
current lock object exists. If its client dies without unlocking,
RayWM enters the **abandoned** state, keeps other layers hidden and
input restricted, and turns the lock background dark red. An ordinary
client that obtains a new lock in this state can unlock it; this permits
recovery but is not an authentication boundary against already running
unrestricted clients. Restricted security-context clients cannot bind
the lock manager.

The lock does not stop background applications, clipboard managers or
trusted Lua plugins, and it cannot defend against the user killing the
compositor, malicious same-user processes or a compromised locker.
Physical DRM/KMS, VT and monitor-hotplug behavior still requires the
manual checks in [HARDWARE-TESTING.md](docs/HARDWARE-TESTING.md).

## Activation requests

For `xdg-activation-v1`, wlroots rejects unknown/expired tokens and
consumes a token after an activation request. RayWM exposes a boolean
named `user` to `view_request_activate` handlers: it is true when the
token was exchanged from a key/button press actually forwarded to the
client, with a supplied source surface still holding pointer or keyboard
focus when the token was committed. RayWM requires this in addition to
wlroots' broader seat-client serial validation, which also accepts enter
and other seat events. A press must be exchanged within five seconds and
can authorize only one token. Missing source surfaces, enter serials,
expired input grants and reused serials cannot authorize focus.

The native input and verified-token registries each hold at most 64
entries. When full, older grants lose their authorization and requests
fall back to urgency. Client/token destroy listeners remove the native
references, and the input path performs no allocation for these grants.
RayWM does not use the token's `app_id` as an authenticated identity or
enforce target-app matching.

Without a plugin decision, a verified request restores/focuses a
mapped window on a shown workspace if native focus rules permit it;
otherwise the window becomes urgent. This is a focus-stealing policy,
not a permission mechanism for screen, clipboard or session access.

## Local IPC and visual resources

IPC is a fixed versioned command interface, not a code execution API.
It checks kernel peer UID, requires a private owner-only runtime directory,
creates a mode-0600 socket without overwriting paths, and bounds clients,
framing, parsing depth, partial-request time and output queues. Slow/flooding
peers are disconnected. Actions are refused while locked; same-user queries
can still read titles/state. Wayland security-context does not constrain
filesystem IPC access; sandbox launchers must hide this socket separately.
See [docs/IPC.md](docs/IPC.md) for the full contract.

Visual/animation handles are generation-checked native resources owned by
Lua registrations. No native pointer is exposed. Snapshot buffers are locked
and bounded by a 128 MiB four-byte-per-pixel estimate; cancellation, plugin
fault/reload, completion and session lock release them. This is resource
management for trusted plugins, not an untrusted plugin sandbox. Rectangles
and snapshots are input-transparent and remain below the lock layer.

Xwayland is trusted session software, isolated from neither other X11
applications nor the user's unrestricted Wayland clients. Clipboard bridging
inherits that trust boundary. Repeated early Xwayland crashes have a bounded
retry policy; Wayland clients remain independent of its process lifecycle.

## Other notes

- **Virtual keyboard and input methods.** Ordinary clients can register an
  input method and inject keyboard events through virtual-keyboard-v1,
  which IMEs use to return unhandled keys. Sandboxed security-context
  clients cannot see either global. The first input method for the seat
  is accepted; additional methods receive unavailable. Treat ordinary
  clients of the Wayland socket as trusted desktop software.
- **Test-only virtual pointer.** Builds made with `zig build -Dtest-input`
  expose the virtual pointer protocol, allowing clients to inject pointer
  events. Such builds are for the test suite only, log a
  `TEST BUILD` warning at startup, and are never distributed. Release
  packages are checked to contain no such code (`scripts/package.sh`).
- **Screenshot files** are created with mode 0600 in the user's
  pictures directory; temporary files for clipboard copies live in
  `$XDG_RUNTIME_DIR` and are removed after use.
- **Dwindle snapshot.** The dwindle plugin keeps its tree shape across
  reloads in `$XDG_RUNTIME_DIR` (mode 0700). The snapshot is parsed as
  plain data and never executed. Without `XDG_RUNTIME_DIR` it is not
  written at all; there is no `/tmp` fallback.
- **Child processes** are started in a new session with an empty signal
  mask and are not left as zombies.

## Reporting a vulnerability

Please report security issues privately, not in a public issue:

- use GitHub's private vulnerability reporting for this repository, if
  available ("Security" → "Report a vulnerability"); or
- contact the repository owner through their GitHub profile.

Include the RayWM version or commit (`COMMIT` file in release archives),
your wlroots version, and steps to reproduce. As a small hobby project
there is no guaranteed response time, but reports are taken seriously.
Please allow time for a fix before disclosing publicly.

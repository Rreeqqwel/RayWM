# Security

RayWM v0.1 is experimental software. It runs as your user, owns your
display, and receives all keyboard and pointer input. Treat it with the
same care as any other compositor.

## Lua plugins are trusted code — there is no sandbox

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

## Other notes

- **Test-only virtual input.** Builds made with `zig build -Dtest-input`
  expose the virtual pointer and keyboard protocols. These let *any*
  client inject input. Such builds are for the test suite only, log a
  `TEST BUILD` warning at startup, and are never distributed. Release
  packages are checked to contain no such code (`scripts/package.sh`).
- **Protocols.** RayWM v0.1 does not implement screen capture, data
  control, input inhibition or security-context protocols, so clients have
  no RayWM-provided way to capture other clients' contents.
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

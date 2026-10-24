# Torture suite

`tests/stress/` breaks RayWM on purpose, under controlled and repeatable
conditions: seeded random clients, compositor-side chaos, random input,
hostile plugins, fuzzed configuration, a misbehaving update server, output
hotplug, crashes and long soaks. Everything is headless (pixman) and
isolated like the other suites: private `XDG_RUNTIME_DIR`, scrubbed
environment, no access to the running session. Results of the first full
run: [TORTURE-TEST-REPORT.md](TORTURE-TEST-REPORT.md).

## Running it

```sh
zig build -Dtest-input -p zig-out/test-input        # the test build (virtual input, test clients)
tests/stress/run.sh --level fast                     # about 10 minutes
tests/stress/run.sh --level stress                   # about an hour
tests/stress/run.sh --level soak --duration 7200     # 2 hours (300: smoke, 1800: extended)
zig build stress -Dtest-input -p zig-out/test-input -- --level fast   # the same through zig build
```

Options: `--category lifecycle,lua,...`, `--case <substring>`, `--seed N`
(random when omitted, always printed), `--iterations N`, `--duration S`,
`--timeout S` (per category), `--rss-cap KB`, `--out DIR`, `--bin DIR`,
`--baseline-bin DIR` (perf: an older test build to compare with).

Leak detection: build with `zig build -Dtest-input -Dleak-check -p zig-out/leak`
and pass `--bin zig-out/leak/bin`. The compositor then uses Zig's
DebugAllocator: double frees are reported, freed memory is poisoned, and at
exit every allocation still alive is listed and the exit status is 3 (the
suite reports it as a failure). Allocations made inside wlroots, libwayland
and libinput (C) are not tracked; the RSS and descriptor checks cover them.

| Level | Where | Purpose |
|---|---|---|
| FAST | every CI run (`ci.yml`, job "torture suite (FAST, pixman)", seed = run number) | short rounds of every category |
| STRESS | manual (`stress.yml`, Actions → Torture → level stress) | many rounds and seeds, perf against v0.2.2-beta |
| SOAK | manual (`stress.yml`, level soak, duration) | one long-lived compositor under mixed load |

## Output

`<out>/results.jsonl` has one JSON object per case: category, case, seed,
level, status, duration, peak RSS and descriptors, notes, log directory and
the command that reproduces it. `<out>/summary.txt` is the human summary
with the failed cases first; `<out>/<category>-<case>-<seed>/` keeps every
log (compositor, clients, input, resource samples `samples.tsv`, descriptor
history `fds-timeline.txt`, phase markers, audits). Logs are never deleted
by the suite.

## Reproducing a failure

Every random decision comes from the seed: the chaos client draws each
operation from its own sub-seed, the chaos plugin and the input and
configuration generators (`tests/stress/gen.py`, Python's specified
`random.Random`) are seeded too. The reproduce line of a failed case reruns
exactly that case and seed:

```sh
tests/stress/run.sh --level fast --category lifecycle --case 'mixed-round' --seed 17 --iterations 1
```

Timing still differs between runs (clients and compositor are separate
processes), so an interleaving-dependent failure can need a few repeats;
`RAYWM_CHAOS_VERBOSE=1` (client) and `RAYWM_CHAOS_LOG=1` (plugin) log every
operation. Fixed failures get a deterministic regression test in the
regular suites (see the report).

## Categories

| Category | Cases | What is checked |
|---|---|---|
| `lifecycle` | `mixed-round` | 4–8 chaos clients (random xdg/layer/subsurface/popup operations, crashes, one protocol violation), the chaos plugin (random focus, float, fullscreen, maximize, minimize, hide, workspaces, place, close, animations, reloads) and random real input on two outputs. After every round: alive and answering IPC, IPC windows equal the clients' windows (no stale or lost window), focus valid, tiles requested by the layout neither overlap nor leave the usable area, real geometry equals the request (allowing the client's size hints), one workspace per output; after all clients leave: no window, no focus, no descriptor left except bounded wlroots state |
| `lua` | `failure-modes`, `churn`, `overlap`, `reload-storm`, `bytecode` | 51 plugins failing in every way and place; registration churn; two layouts fighting; reloads every few ms with clients; corrupted precompiled chunks |
| `config` | `raywm-t`, `live-reload` | generated raywm.conf files through `raywm -t` and through live reloads: a valid file is applied exactly as `raywm -t` reports, a rejected one changes nothing |
| `protocol` | `profiles`, `taskbar-flood`, `invalid-storm`, `kill-pending`, `outputs`, `xwayland` | per-area protocol pressure, taskbar traffic under uncapped clients, dozens of violators, SIGKILL mid-sequence, output hotplug under load, X11 clients and the X server killed |
| `update` | `deep-json`, `http-errors`, `redirects`, `truncated`, `endless`, `stall`, `disk-full`, `traversal`, `metadata-fuzz`, `channel-file`, `downgrade`, `pagination` | raywm-update against a misbehaving HTTPS server (`tests/stress/update/server.py`), crafted archives, mutated metadata; nothing is installed on the host (fake pacman), never as root |
| `recovery` | `start-stop`, `shutdown-busy`, `init-failures`, `ipc-abuse` | start/stop cycles, shutdown under load, broken environments, IPC garbage and floods |
| `perf` | `startup`, `idle`, `commit-storm`, `ipc`, `reload`, `switching`, `churn` | numbers (with `--baseline-bin`, against the baseline); fails only on gross regressions |
| `soak` | `soak-<seconds>s` | rounds of everything at once on one compositor; RSS trend of quiescent samples, descriptor bound |

## Limits

- Headless pixman only. GPU renderers, DRM/KMS, VRR, tearing, real input
  devices and monitors are not exercised; frame-rate claims cannot be
  derived from these numbers. The osu! report from v0.2.1 stays unverified.
- Coverage-guided fuzzing (`zig test -ffuzz`) does not build with Zig
  0.16.0's own test runner; the raywm.conf fuzzer is a seeded generator
  (20000 inputs per `zig build test`) plus a `std.testing.fuzz` target kept
  for a fixed Zig.
- No sanitizer for the C libraries (no Valgrind/ASan in the toolchain);
  wlroots-internal problems show up as assertions, crashes or resource
  growth.

# Torture test report

First full run of the torture suite ([TORTURE.md](TORTURE.md)) and the
reliability fixes it led to.

| | |
|---|---|
| Baseline | `d0fbe73` (v0.2.2-beta, also `beta`); `release` untouched |
| Fixes and suite | on `master` after the baseline (commits listed below) |
| Host | Linux 7.2.11-zen1 x86_64, 24 CPUs, Zig 0.16.0, wlroots 0.20, Lua 5.4 |
| Renderer | headless, pixman (CI also runs the regular suites with GLES2 on llvmpipe) |
| Dates | 2026-10-24 … 2026-10-25 |

All results are headless. They say nothing about GPU drivers, DRM/KMS,
VRR, tearing, real monitors or input devices; see [Limits](#limits).

## What was run

| Run | Level, seed | Cases | Result | Time |
|---|---|---|---|---|
| FAST, all categories | fast, 4242 | 38 | 38 pass | ~6 min (351 s in cases) |
| STRESS, all but perf | stress, 9001 | 42 | 41 pass, 1 fail (test timing, see T1) | 1300 s |
| STRESS lua rerun after T1 | stress, 9001 | 5 | 5 pass | 493 s |
| STRESS perf vs v0.2.2-beta | stress, 9004 | 7 | 7 pass | 91 s |
| STRESS sequential clients | stress, 9005 | 1 | pass | 59 s |
| SOAK 2 h, leak-check build | soak, 9002 | 1 | pass, no leak reported | 7205 s |
| SOAK 30 min, normal build | soak, 9003 | 1 | pass | 1800 s |
| SOAK 5 min, normal build | soak, 9006 | 1 | pass | 303 s |
| SOAK 30 min, leak-check build, capped hotplug | soak, 9007 | 1 | pass, no leak reported | 1802 s |
| Final check on `caded64` | `zig build test`, `tests/run.sh` | 69 unit tests, 25 suites | all pass; fmt, ast-check, luac, lint clean | – |
| Regular suites under `-Dleak-check` | 24 suites | – | all pass, no leak | – |
| CI (`ci.yml` on `ed67886`) | FAST, run number | 38 | pass (build+tests, torture FAST, GLES2) | – |

Categories and what they check are in [TORTURE.md](TORTURE.md#categories):
lifecycle (`mixed-round`, `sequential-clients`), lua (5 cases), config (2),
protocol (6), update (12), recovery (4), perf (7), soak. Each STRESS
lifecycle round runs 4–8 chaos clients (1500 random protocol operations
each), the chaos plugin and 800 random input events on two outputs.

STRESS category times (seed 9001): config 111 s, update 329 s, lua 551 s,
lifecycle 138 s (13 cases), protocol 146 s, recovery 25 s.

Amounts in that STRESS run: 600 generated raywm.conf files through
`raywm -t` and 600 live reloads (308 applied, 292 rejected exactly as
`raywm -t` predicted); 400 mutated update metadata documents; 300 corrupted
bytecode chunks; 51 failing plugins over 20 reloads (1046 plugin failures
reported, compositor alive); 2.1 M commits in 15 s from 3 uncapped clients
with a taskbar; 60 protocol violators; 80 clients SIGKILLed mid-sequence; 30
output unplug/plug cycles under load; 40 X11 clients with the X server
killed 10 times; 100 start/stop cycles (slowest 138 ms); 3000 abusive IPC
connections in 4.8 s; 600 sequential clients.

## Defects found and fixed

Each fix is its own commit, separate from the test infrastructure, with a
regression test that fails without it.

### D1. Compositor abort when an output goes away (`322eba0`)

- **Failure.** `wlr_output_finish: Assertion 'wl_list_empty(&output->events.bind.listener_list)' failed`, compositor aborted. Found by `protocol/outputs` (hotplug under load).
- **Root cause.** In wlroots 0.20 the scene output is an addon of the
  output and was destroyed only after the output's destroy signal. Our
  destroy handler moved the output's workspaces away (`outputGone →
  setOutput → firstOn`), which made another workspace of the dying output
  visible; its windows got `wl_surface.enter` for the dying output, which
  registered a new `bind` listener during the destroy emission (wlroots'
  `surface_handle_output_bind`, identified in a core dump with gdb and
  debuginfod). That listener is never removed, so `wlr_output_finish`
  asserts.
- **Fix.** `src/output.zig` destroys the scene output first in the destroy handler.
- **Before/after.** `protocol/outputs`: 5/5 seeds aborted before, 0/5
  after. Regression `tests/outputs.sh` case "o8" (a window on a hidden
  workspace of the unplugged output): 3/3 aborts without the fix, 3/3 pass
  with it.

### D2. A corrupted precompiled Lua chunk could crash the compositor (`f1ea30c`)

- **Failure.** `lua/bytecode`: 7 of 40 corrupted chunks in `plugins/`
  crashed the compositor (Lua's bytecode loader does not verify its input).
- **Root cause.** `luaL_loadfilex` was called with mode `NULL` (text and
  binary), and `load`/`loadfile`/`dofile`/`require` accepted binary chunks too.
- **Fix.** Configuration and plugins are loaded with mode `"t"`; a
  prelude makes `load`, `loadfile`, `dofile` and the `require` searcher
  text-only. Documented as a behavior change in API.md and SECURITY.md.
- **Before/after.** 7/40 crashed before; 0/40, then 0/300 (STRESS) after.
  Regression in `tests/lua_test.zig` ("precompiled chunks are refused",
  `tests/lua/textonly.lua`).

### D3. One runaway plugin at load time disabled every later plugin (`9d1b6c1`)

- **Failure.** In `lua/failure-modes` a plugin spinning in its body (4th of
  51) used up the instruction budget of the whole `init.lua`; the
  remaining 48 plugins were never loaded.
- **Root cause.** The budget was set once for `init.lua`, and `raywm.load`
  ran inside it.
- **Fix.** Each `raywm.load` gets its own budget and the outer one resumes afterwards.
- **Regression.** `tests/lua_test.zig` with `tests/lua/loadbudget.lua`
  (plugins `loadspin`, `setupspin`).

### D4. Stale window geometry after buffer-only commits (`5cc4797`)

- **Failure.** `lifecycle/mixed-round` seed 2: the audit found windows whose
  geometry did not match their buffer (200x150 kept instead of 1264x704 /
  628x704).
- **Root cause.** wlroots 0.20 recomputes the xdg geometry only on commits
  that set it; a client that sets geometry once (or a bad one) and then
  resizes its buffer keeps the old value.
- **Fix.** `effectiveGeometry()`: the set geometry clipped to
  `wlr_surface_get_extents`, as the protocol requires.
- **Regression.** `tests/shell.sh` s15, client modes
  `RAYWM_TEST_BAD_GEOMETRY` and `RAYWM_TEST_GEOMETRY_ONCE`; fails without the fix.

### D5. raywm-update hung on a stalled server; killed runs left work dirs (`f34cb54`)

- **Failure.** `update/stall`: with a server that stops sending, raywm-update
  waited until the test killed it at 240 s (curl had only `--max-time 1800`,
  times 3 retries, so up to 90 min). Work directories `run-<pid>-*` of
  killed runs stayed forever.
- **Fix.** `--speed-limit 1 --speed-time 30` on every transfer, `--max-time
  120` for lists and metadata; stale run directories of dead processes are
  removed at start. Documented in INSTALL.md.
- **Before/after.** Gave up after 95 s (stalled API and stalled download,
  status 1). Regression in `tests/update.sh` ("working directories of killed
  runs"), fails without the fix.

### D6. Links in Beta source archives were extracted (`e03c40a`)

- **Failure.** A Beta source archive with a symlink pointing at
  `/etc/passwd` inside the tree was extracted and its build script ran.
  (`tar` itself already blocked directory symlinks, hardlinks and
  devices; raywm-update already refused `../` and absolute paths.)
- **Fix.** raywm-update lists the archive types (`tar -tvzf`) and refuses
  any link or special file before extracting.
- **Regression.** `tests/update.sh` 10c (`world.py` flag `symlink`);
  `update/traversal` covers dotdot, absolute, symlink-dir, symlink-abs,
  hardlink and device entries.

### D7. Too long IPC socket path stopped the compositor (`2940cf3`)

- **Failure.** With a long `XDG_RUNTIME_DIR` the start failed with just
  `error: NoSpaceLeft`.
- **Fix.** The IPC socket is optional: the compositor logs `IPC disabled
  (...)` and runs. A Wayland socket failure now explains `XDG_RUNTIME_DIR`.
- **Regression.** `tests/ipc.sh` long-path scenario, fails without the fix.

### D8. Settings kept bytes of a previous, longer string value (`4f781de`, `daf61f4`)

- **Failure.** raywm.conf fuzz round trip (seed 9375164653104804668): a
  value that was parsed, reapplied and compared differed.
- **Root cause.** `conf.Text` copied a shorter string over a longer one
  without clearing the tail, so `std.meta.eql` on settings saw stale bytes
  (reload change detection).
- **Fix.** Zero the tail; `conf.Value` now tells free-form text apart.
- **Regression.** Unit test in `src/conf.zig`; the fuzzer runs 20000 inputs
  per `zig build test`.

### Test infrastructure defects (fixed, not RayWM)

- T1. `lua/failure-modes` STRESS seed 9001 failed "canary (generation 21)
  stopped ticking". Runaway plugins hold the event loop up to their budget
  (~1 s each) several times after a reload; the canary waited 0.5 s. It now
  waits up to 15 s and notes long waits (`caded64`). The rerun of seed 9001 passed.
- T2. The startup commands of `tests/support/harness.sh`, `smoke.sh`,
  `focus.sh`, `screenshot.sh` waited forever for a client's log line and
  outlived the test when the client died (`49e6eba`).
- Chaos client corrections while developing it (re-role commit rules,
  stale configure serials, toolkit-like geometry with subsurfaces) are part
  of the tool, not RayWM defects.

## Findings that are not defects

- **Descriptors left after rounds** (2–4): wlroots' cursor/primary
  swapchain shm buffers (bounded, at most 4 per swapchain, 2 per output) and
  `/dev/urandom` held by the ext-foreign-toplevel token generator. Traced
  with an `LD_PRELOAD` shim on `shm_open`/`open`; `check_fds` allows exactly these.
- **Tiles under 10 px share space** on purpose (dwindle, as in `dwindle_test`).
- **Workspaces accumulate per output name.** `workspaces.lua` keeps the
  workspaces of every output name it has seen (1755 workspaces after 193
  headless hotplugs, none removed). Real hardware has few connector names,
  so this is bounded there; headless hotplug invents a new name each time.
  The soak caps hotplug at 12 cycles. Open question for a later release
  whether workspaces of long-gone outputs should be dropped.
- **Runaway plugins freeze the loop about 1 s per callback** (200 M
  instruction budget). By design; the plugin is reported and disabled.
- **Xwayland mapping scenario** failed once in the leak-check run under
  full CPU load and passed 6/6 on repeat. Not reproduced; recorded, not hidden.

## Memory and CPU

| Run | Quiescent RSS (after warm-up → end) | Slope | Busy peak | FDs max |
|---|---|---|---|---|
| SOAK 2 h leak-check, seed 9002, 966 rounds, 3693 reloads, uncapped hotplug | 32.7 → 55.7 MiB | 12.8 MiB/h | 73.3 MiB | 23 |
| SOAK 30 min normal, seed 9003, 364 rounds, 1400 reloads | 25.9 → 26.3 MiB | 1.0 MiB/h | 63.8 MiB | 23 |
| SOAK 5 min normal, seed 9006, 72 rounds, 250 reloads | 24.9 → 25.1 MiB | 2.5 MiB/h | 58.1 MiB | 23 |
| SOAK 30 min leak-check, seed 9007, 417 rounds, 1518 reloads, hotplug capped at 12 | 28.3 → 28.4 MiB | 0.3 MiB/h | 73.5 MiB | 23 |
| sequential clients, 600 (200 without cleanup), seed 9005 | 19.3 → 21.6 MiB | – | – | – |

The 2 h leak-check soak grew about 30 KB per round. That run had
uncapped hotplug (every round a new output name, so the workspace state
above grew) and the DebugAllocator, which keeps metadata per allocation;
it reported no leaked allocation at exit (exit status 0, not 3). The normal
build is flat over 30 minutes, and so is the leak-check build once hotplug is
capped (seed 9007: 0.3 MiB/h, rise 0.1 MiB, no leak at exit). The growth of
the 2 h run therefore comes from the per-output-name workspace state, not
from a leak.

Perf, STRESS seed 9004, current master vs v0.2.2-beta (same machine, same run):

| Measure | master | v0.2.2-beta |
|---|---|---|
| Start to first output | 47 ms | 48 ms |
| RSS after start | 19060 kB | 19140 kB |
| Idle CPU, 4 windows, 5 s | 0.00 % | 0.00 % |
| Commit storm, 10 s | 1.27 M commits, 7.71 µs/commit | 1.34 M, 7.31 µs/commit |
| IPC sequential p50 / p99 | 324 / 544 µs | 398 / 544 µs |
| IPC parallel p99, rps | 2962 µs, 5212 | 2992 µs, 5087 |
| Reload | 51.5 ms | 50.4 ms |
| Workspace switch / fullscreen | 4.34 / 2.43 ms | 3.21 / 2.22 ms |
| Map/unmap churn with animations | 7756 ms, CPU 4.32 s | 7127 ms, CPU 4.12 s |

Repeated switch measurements gave 3.71–4.26 ms (master) and 4.00–4.18 ms
(baseline): noise, not a regression. Churn RSS (+15.4 MB for both)
does not scale with the number of operations (33, 21, 9.7 MB at 2k, 8k,
20k ops): allocator high-water mark, not a leak. Taskbar flood: 546 k commits
in 4 s produced 3 title and 4 done events (the v0.2.1 throttling holds).

## Limits

- Headless pixman only (GLES2 llvmpipe in CI for the regular suites). GPU
  renderers, DRM/KMS, VRR, tearing, real input devices, real monitors and
  hotplug of real connectors are not exercised. No frame-rate or latency
  claim for real hardware follows from these numbers.
- The osu! issue reported against v0.2.1 remains **unverified**.
- No Valgrind or ASan for the C libraries; wlroots problems show up only as
  assertions, crashes or resource growth. Allocations inside wlroots,
  libwayland and libinput are not seen by the DebugAllocator.
- Zig 0.16.0 `-ffuzz` does not build (its test runner,
  `lib/compiler/test_runner.zig:566`, has a StackTrace mismatch); the
  raywm.conf fuzzer is a seeded generator plus a `std.testing.fuzz` target.
- Timing between processes is not deterministic: a seed reproduces the
  operations, not the exact interleaving.

## Reproducing

```sh
export PATH=$HOME/.local/share/zig-0.16.0:$PATH   # or any Zig 0.16.0
zig build -Dtest-input -p zig-out/test-input
tests/stress/run.sh --level fast --seed 4242                              # FAST
tests/stress/run.sh --level stress --seed 9001 --category config,update,lua,lifecycle,protocol,recovery
tests/stress/run.sh --level soak --duration 1800 --seed 9003              # soak
zig build -Dtest-input -p zig-out/test-input-base   # on d0fbe73, then:
tests/stress/run.sh --level stress --category perf --seed 9004 --baseline-bin zig-out/test-input-base/bin
zig build -Dtest-input -Dleak-check -p zig-out/leak
tests/stress/run.sh --level soak --duration 7200 --seed 9002 --bin zig-out/leak/bin
```

Single defects (revert the fix commit to see the failure):

```sh
tests/stress/run.sh --level fast --category protocol --case outputs --seed 1   # D1
ONLY="never shown there" tests/outputs.sh zig-out/test-input/bin              # D1 regression o8
tests/stress/run.sh --level fast --category lua --case bytecode --seed 1       # D2
zig build test                                                                 # D2, D3, D8
tests/stress/run.sh --level stress --category lifecycle --case mixed-round --seed 2 --iterations 1   # D4
tests/shell.sh zig-out/test-input/bin                                          # D4 regression s15
tests/stress/run.sh --level stress --category update --case stall --seed 1     # D5
tests/update.sh zig-out/test-input/bin                                         # D5, D6
tests/ipc.sh zig-out/test-input/bin                                            # D7
```

## Commits

Fixes: `5cc4797` view geometry, `4f781de` + `daf61f4` conf text,
`f1ea30c` Lua text-only, `9d1b6c1` per-plugin budget, `f34cb54` update
stalls, `e03c40a` archive links, `2940cf3` IPC optional, `322eba0` output
destroy. Infrastructure: `7dba26b` `-Dleak-check`, `7cc786e` chaos client,
`8a5604b` conf fuzz, `0730232` suite, `ed67886` CI, `ccaef5d` docs,
`49e6eba` bounded waits, `caded64` suite additions.

## Stable readiness (automated testing view)

No open crash, hang or leak is known from these runs. The fixes landed on
`master` after v0.2.2-beta, and D2 changes plugin behavior (bytecode
refused), so they need a new Beta before any Stable; Stable also still
depends on the hardware checklist ([HARDWARE-TESTING.md](HARDWARE-TESTING.md))
and the unverified osu! report. Nothing was published during this work.

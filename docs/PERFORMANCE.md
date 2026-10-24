# v0.2.1 gaming-path samples

Measured on 2026-10-24 on one host (Xeon E5-2680 v3, 24 threads; AMD RX 580
render node `/dev/dri/renderD128`, Mesa; Linux 7.2.11-zen1), Zig 0.16.0
ReleaseSafe **test** builds, wlroots 0.20.2, headless backend at 1280×720
(60 Hz frame timer). Baseline: v0.2.0 `76d2d8c`; candidate: the v0.2.1
working tree. Five sessions per scenario, run interleaved per renderer, one
`raywm-test-perf` binary for both builds. Values are median (min–max).
Commit rates are what an uncapped client achieved; they measure how quickly
the compositor accepts and releases buffers, not FPS on a monitor.

| Renderer | Scenario | Metric | v0.2.0 | v0.2.1 |
|---|---|---|---:|---:|
| pixman | idle, no windows / one window (3 s) | compositor CPU ms | 0 / 0 | 0 / 0 |
| pixman | uncapped window | commits/s | 102,629 (87,989–107,685) | 110,130 (93,759–115,031) |
| pixman | uncapped fullscreen | commits/s | 95,652 (91,398–97,572) | 108,928 (107,143–110,177) |
| pixman | uncapped fullscreen + panel | commits/s | 102,597 (95,861–104,929) | 108,624 (102,220–111,236) |
| pixman | uncapped fullscreen + 3 windows + taskbar | commits/s | 66,721 (64,955–67,120) | 108,827 (100,389–115,453) |
| pixman | same | taskbar `title` events | 540,221 | 4 |
| pixman | same | taskbar CPU ms / 3 s | 1,720 (1,630–1,900) | 0 |
| pixman | frame-callback client | presented/s | 58.5 | 58.4 |
| gles2 | uncapped fullscreen (shm upload bound) | commits/s | 1,289 (1,254–1,304) | 1,606 (1,592–1,618) |
| gles2 | same + 3 windows + taskbar | taskbar `title` events | 7,001 | 4 |
| gles2 | glxgears via Xwayland, fullscreen, uncapped | client FPS | 8,488 (8,218–9,430) | 9,475 (8,992–11,078) |
| gles2 | same + 3 windows + taskbar | client FPS | 8,583 (8,411–8,699) | 9,700 (9,195–10,369) |
| gles2 | same | taskbar `title` events (≈12 s) | 416,917 | 4 |
| gles2 | same | taskbar CPU ms | 1,590 (1,570–1,680) | 0 |
| gles2 | same | compositor CPU ms | 6,710 (6,630–6,730) | 5,620 (5,490–5,820) |

Notes. CPU accounting has 10 ms resolution. Uncapped clients keep the
compositor busy (~97 % of a core) in both versions: they commit as soon as a
buffer is released. The v0.2.0 cost came from republishing every window to
foreign-toplevel clients on every commit (also without any taskbar client
connected, which is why window-only scenarios improved too). With GLES2,
shm clients are limited by texture uploads of every 1280×720 buffer; real
games submit GPU (dmabuf) buffers, which glxgears through Xwayland does.
vkgears and es2gears_wayland could not run (they request a keyboard from a
seat without one in the device-less session) and are SKIPPED. Headless runs
have no scanout, vblank or physical display; nothing here is a monitor,
NVIDIA or input-latency result.

Raw data: [measurements/v0.2.1/](measurements/v0.2.1/) (`base-*`/`cand-*`
final interleaved runs; `initial-baseline-*` were taken before any change,
3 runs; the initial GLES2 taskbar runs overlapped with an accidental client
start outside the test session and are kept only for the record).
Reproduce: `GPU_CLIENTS=1 tests/gaming_bench.py BIN CONFIG PERF_CLIENT OUT.json gles2 5 3`.

# v0.2 headless performance samples

Measured on the same host on 2026-10-23 using Zig 0.16.0 ReleaseSafe
**test** builds, wlroots 0.20.2, Lua 5.4.9, headless pixman at 1280×720.
Baseline is `89278579a0d00e42183eb6e93fcf3b77402d90dc` (the complete
pre-v0.2 checkout; there is no v0.1.2 tag). Each uses its shipped config;
the candidate also loads a dormant benchmark binding. Xwayland remains
lazy, with no X11 applications. Other tests/builds were stopped during
sampling. These are small local samples, not portable performance guarantees.

| Measurement | v0.1.2 baseline | v0.2 candidate |
| --- | ---: | ---: |
| Startup to observed running log, median of 10 | 19.78 ms | 23.06 ms |
| Startup min–max | 18.50–21.55 ms | 21.99–24.47 ms |
| Idle CPU, 0 windows / 10 seconds | 0 ms | 0 ms |
| Idle RSS, 0 windows | 14,612 KiB | 14,804 KiB |
| Idle CPU, 3 windows / 10 seconds | 0 ms | 0 ms |
| Idle RSS, 3 windows | 18,392 KiB | 18,480 KiB |
| Motion + display-sync roundtrip, median / p95 (1000 samples) | 25.836 / 36.161 μs | 32.274 / 53.901 μs |
| Binary, unstripped test build | 4,081,512 bytes | 5,547,280 bytes |
| Binary, stripped test build | 666,816 bytes | 948,352 bytes |
| ELF text section | 632,567 bytes | 903,599 bytes |

CPU accounting has **10 ms resolution**: zero means no accounted tick,
not proof of zero instructions. Startup uses a 1 ms log polling interval
and includes configuration/process setup. The input sample uses the same
candidate driver against both compositors and measures a virtual pointer
motion followed by `wl_display.sync`; it excludes device/key-to-photon
latency and is not proof of a latency improvement. Different shipped
policies and one short run limit causal comparisons.

Three one-second offset/opacity animations consumed 10, 10 and 20 ms of
compositor CPU in respective 1.214 / 1.218 / 1.219 second sample intervals.
These intervals include virtual-keyboard setup and the trigger, not just
the animation engine. Ten seconds after
completion accounted 0 ms CPU. This checks that finished animations return
to idle; it does not establish frame pacing on a physical monitor. Native
output frame callbacks schedule only active jobs. Real frame cadence,
high-refresh behavior, physical input latency and longer workloads remain
**SKIPPED**, with the hardware procedure in HARDWARE-TESTING.md.

The combined Debug stress run completed 100 window cycles, 20 waves of
8 killed clients, 40 faulting reloads and 1501 resize acknowledgements in
three seconds; RSS grew from 19,064 to 20,172 KiB (1,108 KiB). This is a
bounded stress sample, not a leak proof. The production archive excludes
test input/tools and has its own payload size/checksum; the sizes above
must not be presented as its binary size.

Raw final samples: [measurements/v0.2.0-headless.json](measurements/v0.2.0-headless.json).
The [earlier sample](measurements/v0.2.0-headless-initial.json), before the
final output/lifecycle fixes, had roundtrip medians 29.59 / 29.42 μs and
startup medians 22.95 / 24.42 ms. The variation cautions against attributing
microsecond differences to one change. The final observed roundtrip increased;
no latency improvement is claimed. Final data records exact test-binary hashes
and the source commit; neither sample measures physical input latency.
Reproduction tool: `tests/benchmark.py BASE_BIN BASE_CONFIG NEW_BIN NEW_CONFIG OUTPUT_JSON`.
Build both with `-Doptimize=ReleaseSafe -Dtest-input`; use the new input
driver with its `benchmark 1000` command. Preserve machine/toolchain,
renderer, output size, configs and idle intervals for comparisons.

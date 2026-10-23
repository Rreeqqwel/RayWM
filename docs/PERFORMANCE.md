# v0.2 headless performance samples

Measured on the same host on 2026-10-23 using Zig 0.16.0 ReleaseSafe
**test** builds, wlroots 0.20.2, Lua 5.4.9, headless pixman at 1280×720.
Baseline is `89278579a0d00e42183eb6e93fcf3b77402d90dc` (the complete
pre-v0.2 checkout; there is no v0.1.2 tag). Each uses its shipped config;
the candidate also loads a dormant benchmark binding. Xwayland remains
lazy, with no X11 applications. Other tests/builds were stopped during
sampling. These are small local samples, not portable performance guarantees.

| Measurement | v0.1.2 baseline | v0.2 candidate |
|---|---:|---:|
| Startup to observed running log, median of 10 | 22.95 ms | 24.42 ms |
| Startup min–max | 21.93–25.35 ms | 22.07–29.85 ms |
| Idle CPU, 0 windows / 10 seconds | 0 ms | 0 ms |
| Idle RSS, 0 windows | 14,544 KiB | 14,828 KiB |
| Idle CPU, 3 windows / 10 seconds | 0 ms | 0 ms |
| Idle RSS, 3 windows | 18,360 KiB | 18,516 KiB |
| Motion + display-sync roundtrip, median / p95 (1000 samples) | 29.59 / 52.94 μs | 29.42 / 50.26 μs |
| Binary, unstripped test build | 4,081,512 bytes | 5,542,312 bytes |
| Binary, stripped test build | 666,816 bytes | 947,264 bytes |
| ELF text section | 632,567 bytes | 902,518 bytes |

CPU accounting has **10 ms resolution**: zero means no accounted tick,
not proof of zero instructions. Startup uses a 1 ms log polling interval
and includes configuration/process setup. The input sample uses the same
candidate driver against both compositors and measures a virtual pointer
motion followed by `wl_display.sync`; it excludes device/key-to-photon
latency and is not proof of a latency improvement. Different shipped
policies and one short run limit causal comparisons.

Three one-second offset/opacity animations consumed 10, 10 and 20 ms of
compositor CPU in respective 1.2-second sample intervals. Ten seconds after
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

Raw samples: [measurements/v0.2.0-headless.json](measurements/v0.2.0-headless.json).
Reproduction tool: `tests/benchmark.py BASE_BIN BASE_CONFIG NEW_BIN NEW_CONFIG OUTPUT_JSON`.
Build both with `-Doptimize=ReleaseSafe -Dtest-input`; use the new input
driver with its `benchmark 1000` command. Preserve machine/toolchain,
renderer, output size, configs and idle intervals for comparisons.

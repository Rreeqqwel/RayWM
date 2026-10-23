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

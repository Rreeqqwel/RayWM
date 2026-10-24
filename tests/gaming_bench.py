#!/usr/bin/env python3
"""Headless gaming-path samples for one build; raw results are kept in JSON.

Usage: gaming_bench.py BIN_DIR CONFIG_DIR PERF_CLIENT OUTPUT_JSON [RENDERER] [RUNS] [SECONDS]

BIN_DIR needs a ReleaseSafe raywm and raywm-test-client (for panels and
idle windows); PERF_CLIENT is one raywm-test-perf binary used for every
build compared, so the workload is identical. RENDERER is pixman (default)
or gles2 (needs a DRM render node). No thresholds are asserted: this
records samples. Headless results are not physical GPU/monitor results:
the headless backend has no scanout, no vblank and a fixed 60 Hz frame
timer. Run with other builds/tests stopped.
"""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

bin_dir, cfg, perf, output = map(lambda p: Path(p).resolve(), sys.argv[1:5])
renderer = sys.argv[5] if len(sys.argv) > 5 else 'pixman'
runs = int(sys.argv[6]) if len(sys.argv) > 6 else 3
seconds = float(sys.argv[7]) if len(sys.argv) > 7 else 3.0
ticks = os.sysconf('SC_CLK_TCK')


def cpu_ms(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return (int(fields[11]) + int(fields[12])) * 1000 / ticks


def rss_kib(pid):
    return int(re.search(r'VmRSS:\s+(\d+)', Path(f'/proc/{pid}/status').read_text())[1])


def parse(line):
    return {k: (int(v) if v.lstrip('-').isdigit() else v) for k, v in re.findall(r'(\w+)=(\S+)', line)}


def session(windows, panel, action):
    with tempfile.TemporaryDirectory(prefix='raywm-gaming-') as directory:
        task = Path(directory)
        shutil.copytree(cfg, task / 'config' / 'raywm')
        env = dict(PATH=os.environ['PATH'], HOME=directory, XDG_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(task / 'config'), WLR_BACKENDS='headless',
                   WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=renderer, WLR_LIBINPUT_NO_DEVICES='1',
                   RAYWM_XWAYLAND='1' if os.environ.get('GPU_CLIENTS') else '0')
        client = shlex.quote(str(bin_dir / 'raywm-test-client'))
        startup = []
        if panel:
            log = shlex.quote(str(task / 'panel.log'))
            startup.append(f'RAYWM_TEST_LAYER=1 {client} >{log} 2>&1 & until grep -q "layer frame done" {log}; do sleep 0.01; done')
        for i in range(windows):
            log = shlex.quote(str(task / f'window{i}.log'))
            startup.append(f'RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 RAYWM_TEST_APP_ID=idle{i} {client} >{log} 2>&1 & until grep -q "frame done" {log}; do sleep 0.01; done')
        startup.append('touch ' + shlex.quote(str(task / 'ready')))
        logpath = task / 'raywm.log'
        with logpath.open('w') as log:
            process = subprocess.Popen([str(bin_dir / 'raywm'), '-s', '; '.join(startup)], env=env, stdout=log, stderr=log)
            try:
                until = time.monotonic() + 15
                while not (task / 'ready').exists():
                    if process.poll() is not None or time.monotonic() > until:
                        raise RuntimeError('startup failed:\n' + logpath.read_text())
                    time.sleep(0.01)
                env['WAYLAND_DISPLAY'] = re.search(r'running on WAYLAND_DISPLAY=(\S+)', logpath.read_text())[1]
                time.sleep(0.5)
                return action(process, env)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def workload(mode, args=(), watcher=False):
    def action(process, env):
        sample = {}
        watch = None
        if watcher:
            watch = subprocess.Popen([str(perf), 'watch', str(seconds + 3)], env=env, stderr=subprocess.PIPE, text=True)
            time.sleep(0.5)
            watch_cpu0 = cpu_ms(watch.pid)
        before = cpu_ms(process.pid)
        began = time.monotonic()
        if mode == 'idle':
            time.sleep(seconds)
            sample['client'] = {}
        else:
            out = subprocess.run([str(perf), mode, str(seconds), *args], env=env, capture_output=True, text=True, timeout=seconds + 20)
            lines = [l for l in out.stderr.splitlines() if l.startswith('perf: mode=')]
            if out.returncode != 0 or not lines:
                raise RuntimeError(f'perf client failed: {out.returncode} {out.stderr}')
            sample['client'] = parse(lines[-1])
        elapsed = time.monotonic() - began
        sample['compositor_cpu_ms'] = cpu_ms(process.pid) - before
        sample['wall_s'] = round(elapsed, 3)
        sample['compositor_rss_kib'] = rss_kib(process.pid)
        if watch:
            sample['watcher_cpu_ms'] = cpu_ms(watch.pid) - watch_cpu0
            _, err = watch.communicate(timeout=seconds + 10)
            lines = [l for l in err.splitlines() if l.startswith('perf: mode=watch')]
            sample['watcher'] = parse(lines[-1]) if lines else {'error': err[-500:]}
        return sample
    return action


def external(argv, x11=False, watcher=False, extra_env=None):
    """A real GPU client (mesa-utils demos), run only inside the test session.
    Its own FPS lines are the client-side rate; the first one is dropped."""
    # vkgears and es2gears_wayland request a keyboard from a seat without
    # one (no input devices headless) and are killed by a protocol error,
    # so only glxgears (through Xwayland) is used. Its FPS line covers 5 s.
    seconds = float(os.environ.get('GPU_SECONDS', 11))

    def action(process, env):
        cmd_env = dict(PATH=env['PATH'], HOME=env['HOME'], XDG_RUNTIME_DIR=env['XDG_RUNTIME_DIR'], vblank_mode='0')
        if x11:
            log = Path(env['XDG_RUNTIME_DIR']) / 'raywm.log'
            display = re.findall(r'lazy Xwayland display (:\d+)', log.read_text())
            if not display:
                raise RuntimeError('no Xwayland display')
            cmd_env['DISPLAY'] = display[-1]
        else:
            cmd_env['WAYLAND_DISPLAY'] = env['WAYLAND_DISPLAY']
        cmd_env.update(extra_env or {})
        sample = {}
        watch = None
        if watcher:
            watch = subprocess.Popen([str(perf), 'watch', str(seconds + 4)], env=env, stderr=subprocess.PIPE, text=True)
            time.sleep(0.5)
            watch_cpu0 = cpu_ms(watch.pid)
        before = cpu_ms(process.pid)
        began = time.monotonic()
        try:
            out = subprocess.run(['timeout', '-s', 'INT', str(seconds + 1.5)] + argv, env=cmd_env, capture_output=True, text=True, timeout=seconds + 20)
            text = out.stdout + out.stderr
        except subprocess.TimeoutExpired as e:
            text = (e.stdout or b'').decode() + (e.stderr or b'').decode()
        sample['wall_s'] = round(time.monotonic() - began, 3)
        sample['compositor_cpu_ms'] = cpu_ms(process.pid) - before
        fps = [float(x) for x in re.findall(r'=\s*([0-9.]+) FPS', text)]
        sample['client'] = {'fps_lines': fps, 'fps': statistics.median(fps[1:]) if len(fps) > 1 else (fps[0] if fps else 0)}
        if not fps:
            sample['client']['output_tail'] = text[-400:]
        if watch:
            sample['watcher_cpu_ms'] = cpu_ms(watch.pid) - watch_cpu0
            _, err = watch.communicate(timeout=seconds + 10)
            lines = [l for l in err.splitlines() if l.startswith('perf: mode=watch')]
            sample['watcher'] = parse(lines[-1]) if lines else {'error': err[-500:]}
        return sample
    return action


scenarios = {
    'A_idle_empty': (0, False, workload('idle')),
    'B_idle_static_window': (1, False, workload('idle')),
    'C_spin_window': (0, False, workload('spin')),
    'C2_vsync_window': (0, False, workload('vsync')),
    'D_spin_fullscreen': (0, False, workload('spin', ['fullscreen'])),
    'D2_vsync_fullscreen': (0, False, workload('vsync', ['fullscreen'])),
    'D3_spin_fullscreen_translucent': (0, False, workload('spin', ['fullscreen', 'translucent'])),
    'F_spin_fullscreen_panel': (0, True, workload('spin', ['fullscreen'])),
    'T_spin_fullscreen_3windows_taskbar': (3, True, workload('spin', ['fullscreen'], watcher=True)),
    'T2_idle_3windows_taskbar': (3, True, workload('idle', watcher=True)),
}
if os.environ.get('GPU_CLIENTS') and renderer == 'gles2':
    scenarios.update({
        'G1_glxgears_xwayland_fullscreen': (0, False, external(['glxgears', '-fullscreen'], x11=True)),
        'G2_glxgears_xwayland_fullscreen_taskbar': (3, True, external(['glxgears', '-fullscreen'], x11=True, watcher=True)),
    })
only = os.environ.get('ONLY')
results = dict(method=f'headless {renderer} 1280x720, ReleaseSafe, {runs} runs x {seconds}s per scenario; '
               'CPU from /proc (10 ms ticks); client counts from raywm-test-perf; not physical hardware',
               bin=str(bin_dir), perf_client=str(perf), host=os.uname().nodename, kernel=os.uname().release,
               scenarios={})
for name, (windows, panel, action) in scenarios.items():
    if only and only not in name:
        continue
    samples = []
    for _ in range(runs):
        samples.append(session(windows, panel, action))
    summary = {}
    for key in ('compositor_cpu_ms', 'watcher_cpu_ms'):
        vals = [s[key] for s in samples if key in s]
        if vals:
            summary[key + '_median'] = statistics.median(vals)
    for key in ('commits', 'presented', 'frames', 'releases'):
        vals = [s['client'][key] / s['wall_s'] for s in samples if key in s.get('client', {})]
        if vals:
            summary[key + '_per_s_median'] = round(statistics.median(vals), 1)
    vals = [s['client']['fps'] for s in samples if 'fps' in s.get('client', {})]
    if vals:
        summary['client_fps_median'] = round(statistics.median(vals), 1)
    for key in ('title', 'app_id', 'done'):
        vals = [s['watcher'][key] for s in samples if key in s.get('watcher', {})]
        if vals:
            summary['watcher_' + key + '_median'] = statistics.median(vals)
    results['scenarios'][name] = dict(summary=summary, samples=samples)
    print(name, json.dumps(summary), flush=True)
    Path(output).write_text(json.dumps(results, indent=2) + '\n')

#!/usr/bin/env python3
"""Same-host headless samples; no thresholds or physical-latency claims.

Usage: benchmark.py BASELINE_BIN BASELINE_CONFIG CANDIDATE_BIN CANDIDATE_CONFIG OUTPUT_JSON
Both bin directories need ReleaseSafe raywm and raywm-test-client. The
candidate's raywm-test-input supplies the same roundtrip workload to both.
Run after other tests/builds have stopped. Raw samples are retained in JSON.
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

base_bin, base_cfg, new_bin, new_cfg, output = map(Path, sys.argv[1:])
base_bin, base_cfg, new_bin, new_cfg = [p.resolve() for p in (base_bin, base_cfg, new_bin, new_cfg)]
clock_ticks = os.sysconf('SC_CLK_TCK')


def wait_for(test, process, limit=10):
    until = time.monotonic() + limit
    while not test():
        if process.poll() is not None or time.monotonic() > until:
            raise RuntimeError('compositor startup failed or timed out')
        time.sleep(0.001)


def cpu_ms(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().split()
    return (int(fields[13]) + int(fields[14])) * 1000 / clock_ticks


def rss_kib(pid):
    return int(re.search(r'VmRSS:\s+(\d+)', Path(f'/proc/{pid}/status').read_text())[1])


def run_session(bin_dir, cfg, windows, candidate, action):
    with tempfile.TemporaryDirectory(prefix='raywm-perf-') as directory:
        task = Path(directory)
        config = task / 'config' / 'raywm'
        shutil.copytree(cfg, config)
        if candidate:
            (config / 'plugins' / 'benchmark.lua').write_text('''return {api=1, setup=function(ctx)
  ctx.bind("Super+t", function()
    local id=raywm.focused()
    if id then assert(ctx.animate(id, {from_x=120, from_opacity=0.4, duration=1000, easing="linear"})) end
  end)
end}
''')
            with (config / 'init.lua').open('a') as f:
                f.write('\nraywm.load("benchmark")\n')
        env = dict(PATH=os.environ['PATH'], HOME=directory, XDG_RUNTIME_DIR=directory,
                   XDG_CONFIG_HOME=str(task / 'config'), WLR_BACKENDS='headless',
                   WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman', WLR_LIBINPUT_NO_DEVICES='1')
        startup = []
        for i in range(windows):
            log = shlex.quote(str(task / f'window{i}.log'))
            client = shlex.quote(str(bin_dir / 'raywm-test-client'))
            startup.append(f'RAYWM_TEST_HOLD=1 RAYWM_TEST_ROUNDS=1 {client} >{log} 2>&1 & until grep -q "frame done" {log}; do sleep 0.01; done')
        startup.append('touch ' + shlex.quote(str(task / 'ready')))
        logpath = task / 'raywm.log'
        with logpath.open('w') as log:
            began = time.monotonic_ns()
            process = subprocess.Popen([str(bin_dir / 'raywm'), '-s', '; '.join(startup)], env=env, stdout=log, stderr=log)
            try:
                wait_for(lambda: 'running on WAYLAND_DISPLAY=' in logpath.read_text(), process)
                startup_ms = (time.monotonic_ns() - began) / 1e6
                wait_for(lambda: (task / 'ready').exists(), process)
                display = re.search(r'running on WAYLAND_DISPLAY=(\S+)', logpath.read_text())[1]
                env['WAYLAND_DISPLAY'] = display
                return action(process, env, startup_ms)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
                if process.returncode != 0:
                    raise RuntimeError(logpath.read_text())


def measure(bin_dir, cfg, candidate):
    result = dict(startup_ms=[])
    for _ in range(10):
        result['startup_ms'].append(run_session(bin_dir, cfg, 0, candidate, lambda p,e,s: s))
    for windows in (0, 3):
        def idle(process, env, startup):
            time.sleep(2)
            before = cpu_ms(process.pid)
            time.sleep(10)
            sample = dict(cpu_ms=cpu_ms(process.pid)-before, seconds=10, rss_kib=rss_kib(process.pid))
            if windows:
                driver = [str(new_bin / 'raywm-test-input')]
                sample['motion_sync_roundtrip'] = subprocess.check_output(driver + ['benchmark','1000'],env=env,stderr=subprocess.STDOUT,text=True).strip()
                if candidate:
                    sample['animation_samples'] = []
                    for _ in range(3):
                        before = cpu_ms(process.pid)
                        began = time.monotonic()
                        subprocess.run(driver + ['key','super','down','key','t','down','key','t','up','key','super','up'], env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                        time.sleep(1.2)
                        sample['animation_samples'].append(dict(cpu_ms=cpu_ms(process.pid)-before, elapsed_s=time.monotonic()-began))
                    before = cpu_ms(process.pid)
                    time.sleep(10)
                    sample['after_animation_idle_cpu_ms_10s'] = cpu_ms(process.pid)-before
            return sample
        result[f'idle_{windows}_windows'] = run_session(bin_dir, cfg, windows, candidate, idle)
    binary = bin_dir / 'raywm'
    result['binary_bytes'] = binary.stat().st_size
    result['binary_size_sections'] = subprocess.check_output(['size',str(binary)],text=True).strip()
    with tempfile.TemporaryDirectory() as tmp:
        stripped = Path(tmp)/'raywm'
        shutil.copy2(binary,stripped)
        subprocess.run(['strip','--strip-all',str(stripped)],check=True)
        result['stripped_binary_bytes'] = stripped.stat().st_size
    result['startup_median_ms'] = statistics.median(result['startup_ms'])
    return result


results = dict(method='ReleaseSafe test builds; shipped config + candidate benchmark binding; headless pixman 1280x720; 10 ms CPU tick resolution; startup observed at running log line with 1 ms polling; motion plus sync is not physical input latency', baseline_commit='89278579a0d00e42183eb6e93fcf3b77402d90dc')
for label, bin_dir, cfg, candidate in [('baseline',base_bin,base_cfg,False),('candidate',new_bin,new_cfg,True)]:
    print('measuring',label,flush=True)
    results[label] = measure(bin_dir,cfg,candidate)
    Path(output).write_text(json.dumps(results,indent=2)+'\n')
    print(label,json.dumps(results[label]),flush=True)

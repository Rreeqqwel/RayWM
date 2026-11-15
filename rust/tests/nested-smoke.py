#!/usr/bin/env python3
"""Pixel/input/resize smoke in a private headless Zig parent; never the desktop.

Run from the repository: python3 rust/tests/nested-smoke.py
Needs the unchanged Zig -Dtest-input build, grim and the Rust toolchain.
All logs/screenshots stay in a newly created /tmp/raywm-stage2-* directory.
"""

import argparse
import json
import os
import runpy
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig-bin", type=Path, default=ROOT / "zig-out/test-input/bin")
    parser.add_argument("--stage3", action="store_true", help="qualify floating windows and popups")
    args = parser.parse_args()
    zig_bin = args.zig_bin.resolve()
    executables = [zig_bin / "raywm", zig_bin / "raywm-test-input"]
    if args.stage3:
        executables.append(zig_bin / "raywm-test-client")
    for executable in executables:
        if not executable.is_file():
            parser.error(f"missing {executable}; build Zig with -Dtest-input first")
    for executable in ["cargo", "grim"]:
        if not shutil.which(executable):
            parser.error(f"missing {executable}")

    result = subprocess.run(
        ["cargo", "test", "--workspace", "--locked", "--no-run", "--message-format=json"],
        cwd=ROOT / "rust", capture_output=True, text=True, timeout=240, check=True,
    )
    artifacts = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    probe = next(item["executable"] for item in artifacts
                 if item.get("reason") == "compiler-artifact"
                 and item.get("target", {}).get("name") == "headless" and item.get("executable"))
    compositor = next(item["executable"] for item in artifacts
                      if item.get("reason") == "compiler-artifact"
                      and item.get("target", {}).get("name") == "raywm-smithay"
                      and not item.get("profile", {}).get("test") and item.get("executable"))
    directory = Path(tempfile.mkdtemp(prefix="raywm-stage3-" if args.stage3 else "raywm-stage2-"))
    directory.chmod(0o700)
    print(f"artifacts: {directory}", flush=True)
    parent_dir, nested_dir = directory / "parent", directory / "nested"
    for path in [parent_dir, nested_dir]:
        path.mkdir(mode=0o700)
    config = directory / "config"
    (config / "plugins").mkdir(parents=True)
    (config / "init.lua").write_text('raywm.load("parent")\n')
    (config / "plugins/parent.lua").write_text('''return { api = 1, setup = function(ctx)
  local target = 0
  ctx.on("view_map", function(id)
    target = id
    raywm.view_place(id, 0, 0, 800, 600)
  end)
  ctx.bind("Super+F9", function()
    if target ~= 0 then raywm.view_place(target, 0, 0, 700, 500) end
  end)
end }
''')

    def env(runtime):
        return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(directory),
                "XDG_RUNTIME_DIR": str(runtime), "XDG_CACHE_HOME": str(directory / "cache")}

    processes = []
    logs = []

    def start(command, environment, name):
        log = (directory / f"{name}.log").open("wb")
        logs.append(log)
        process = subprocess.Popen(command, env=environment, cwd=ROOT,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   start_new_session=True)
        processes.append((name, process))
        return process

    def wait_for(predicate, label):
        deadline = time.monotonic() + 20
        while not predicate():
            dead = [(name, process.returncode) for name, process in processes if process.poll() is not None]
            if dead or time.monotonic() >= deadline:
                raise RuntimeError(f"{label}: timeout or early exit {dead}")
            time.sleep(0.02)

    def stop(process):
        process.send_signal(signal.SIGTERM)
        status = process.wait(timeout=5)
        if status:
            raise RuntimeError(f"server exited with {status}")

    try:
        parent_env = env(parent_dir) | {
            "WLR_BACKENDS": "headless", "WLR_HEADLESS_OUTPUTS": "1",
            "WLR_RENDERER": "pixman", "WLR_LIBINPUT_NO_DEVICES": "1",
            "RAYWM_SYSTEM_CONF": "", "RAYWM_XWAYLAND": "0",
        }
        parent = start([str(zig_bin / "raywm"), "-c", str(config / "init.lua")], parent_env, "parent")

        def sockets():
            return [path for path in parent_dir.glob("wayland-*") if stat.S_ISSOCK(path.stat().st_mode)]

        wait_for(sockets, "parent socket")
        parent_socket = sockets()[0]
        nested_env = env(nested_dir) | {
            "WAYLAND_DISPLAY": str(parent_socket), "LIBGL_ALWAYS_SOFTWARE": "1",
            "EGL_PLATFORM": "wayland", "MESA_SHADER_CACHE_DIR": str(directory / "shader-cache"),
        }
        nested = start([compositor, "--backend", "winit", "--socket", "nested"], nested_env, "nested")
        nested_socket = nested_dir / "nested"
        wait_for(lambda: nested_socket.exists() and "Nested Wayland server ready" in (directory / "nested.log").read_text(), "nested startup")
        probe_env = env(nested_dir) | {"RAYWM_SMOKE_SOCKET": str(nested_socket), "RAYWM_SMOKE_CONTROL": str(directory)}
        driver_env = env(parent_dir) | {"WAYLAND_DISPLAY": parent_socket.name, "RAYWM_TEST_EXTENT": "1280x720"}

        def drive(*commands):
            subprocess.run([str(zig_bin / "raywm-test-input"), *commands], env=driver_env,
                           capture_output=True, text=True, timeout=10, check=True)

        def screenshot(marker, name):
            width, height = map(int, (directory / marker).read_text().split())
            path = directory / name
            subprocess.run(["grim", str(path)], env=driver_env, timeout=10, check=True, capture_output=True)
            points = [(width // 4, height // 4, "ff0000"), (3 * width // 4, height // 4, "00ff00"),
                      (width // 4, 3 * height // 4, "0000ff"), (3 * width // 4, 3 * height // 4, "ffffff")]
            command = [sys.executable, str(ROOT / "tests/support/png_check.py"), str(path), "--size", "1280x720"]
            for x, y, rgb in points:
                command += ["--pixel", f"{x},{y},{rgb}"]
            subprocess.run(command, timeout=10, check=True)
            print(f"pixels: PASS ({width}x{height})", flush=True)

        if args.stage3:
            # Give Winit real parent-seat focus before testing the policy that
            # newly mapped clients activate while the host window has focus.
            keeper = start([str(zig_bin / "raywm-test-input"), "move", "700", "550",
                            "down", "left", "up", "left", "sleep", "60000"], driver_env, "seat-keeper")
            time.sleep(0.15)
            drive("move", "700", "550", "down", "left", "up", "left", "sleep", "150")
            client = runpy.run_path(str(ROOT / "rust/tests/floating-smoke.py"))["qualify"](
                ROOT, directory, probe, probe_env, driver_env, start, wait_for, drive, zig_bin)
        else:
            client = start([probe, "nested_graphics_pixels_input_resize_and_unmap", "--exact", "--ignored", "--nocapture"], probe_env, "client")
            wait_for(lambda: (directory / "client-ready").exists(), "initial submitted frame")

            screenshot("client-ready", "initial.png")
            drive("move", "100", "100", "sleep", "100", "down", "left", "up", "left",
                  "key", "a", "down", "key", "a", "up", "sleep", "100")
            wait_for(lambda: (directory / "client-input").exists(), "forwarded keyboard and pointer")
            print("keyboard/pointer: PASS (actual client events)", flush=True)
            drive("key", "super", "down", "key", "f9", "down", "key", "f9", "up", "key", "super", "up", "sleep", "200")
            wait_for(lambda: (directory / "client-resized").exists(), "resize configure, ACK and frame")
            screenshot("client-resized", "resized.png")
            (directory / "finish").touch()
            if client.wait(timeout=10):
                raise RuntimeError("graphics client failed")
            assert (directory / "client-done").exists()
        processes.remove(("client", client))
        independent = []
        if args.stage3:
            independent = runpy.run_path(str(ROOT / "rust/tests/floating-smoke.py"))["independent"](
                ROOT, directory, probe_env, driver_env, start, wait_for, drive, zig_bin)
            keeper.terminate()
            keeper.wait(timeout=3)
            processes.remove(("seat-keeper", keeper))
        stop(nested)
        processes.remove(("nested", nested))
        for name, process in independent:
            if process.wait(timeout=5):
                raise RuntimeError(f"independent client {name} failed on compositor shutdown")
            processes.remove((name, process))
        assert not nested_socket.exists() and not (nested_dir / "nested.lock").exists()
        stop(parent)
        processes.remove(("parent", parent))
        print("nested graphics: PASS (scenario, submitted pixels and process/socket cleanup)", flush=True)
        return 0
    except Exception:
        for name in ["parent", "nested", "client"]:
            log = directory / f"{name}.log"
            if log.exists():
                print(f"{name}:\n{log.read_text(errors='replace')[-6000:]}", file=sys.stderr)
        raise
    finally:
        for _, process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
        for log in logs:
            log.close()


if __name__ == "__main__":
    sys.exit(main())

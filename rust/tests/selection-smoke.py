#!/usr/bin/env python3
"""Stage 4A clipboard qualification in a private headless Zig parent.

Run from the repository: python3 rust/tests/selection-smoke.py

Starts the unchanged Zig `-Dtest-input` compositor as a private pixman parent,
runs the Rust Winit compositor inside it, drives real focus changes through the
parent virtual seat, then qualifies foot, wl-copy and wl-paste as independent
clients. Logs and screenshots stay in a new /tmp/raywm-stage4-* directory.
"""

import argparse
import json
import os
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
    args = parser.parse_args()
    zig_bin = args.zig_bin.resolve()
    for executable in [zig_bin / "raywm", zig_bin / "raywm-test-input"]:
        if not executable.is_file():
            parser.error(f"missing {executable}; build Zig with -Dtest-input first")
    for executable in ["cargo", "grim", "foot", "wl-copy", "wl-paste"]:
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
    directory = Path(tempfile.mkdtemp(prefix="raywm-stage4-"))
    directory.chmod(0o700)
    print(f"artifacts: {directory}", flush=True)
    parent_dir, nested_dir = directory / "parent", directory / "nested"
    for path in [parent_dir, nested_dir]:
        path.mkdir(mode=0o700)
    config = directory / "config"
    (config / "plugins").mkdir(parents=True)
    (config / "init.lua").write_text('raywm.load("parent")\n')
    (config / "plugins/parent.lua").write_text('''return { api = 1, setup = function(ctx)
  ctx.on("view_map", function(id)
    raywm.view_place(id, 0, 0, 800, 600)
  end)
end }
''')
    foot_config = directory / "foot.ini"
    foot_base = "[main]\nfont=monospace:pixelsize=16\npad=0x0\n[csd]\npreferred=none\n"
    foot_colors = "background=ff0000\nforeground=ffffff\nalpha=1.0\n"
    foot_config.write_text(foot_base + "[colors-dark]\n" + foot_colors + "[colors-light]\n" + foot_colors)
    config_check = ["foot", "--check-config", "--config", str(foot_config)]
    if subprocess.run(config_check, capture_output=True, timeout=10).returncode:
        # Older foot exposes the same color settings in a single section.
        foot_config.write_text(foot_base + "[colors]\n" + foot_colors)
        subprocess.run(config_check, capture_output=True, timeout=10, check=True)

    def env(runtime):
        libraries = {key: os.environ[key] for key in ("LD_LIBRARY_PATH", "QT_PLUGIN_PATH",
                     "GI_TYPELIB_PATH", "XDG_DATA_DIRS") if key in os.environ}
        return libraries | {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(directory),
                "XDG_RUNTIME_DIR": str(runtime), "XDG_CACHE_HOME": str(directory / "cache"),
                "XDG_CONFIG_HOME": str(directory / "config-home")}

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

    def wait_for(predicate, label, timeout=25):
        deadline = time.monotonic() + timeout
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
        nested = start([compositor, "--backend", "winit", "--floating", "--socket", "nested"], nested_env, "nested")
        nested_socket = nested_dir / "nested"
        wait_for(lambda: nested_socket.exists()
                 and "Nested Wayland server ready" in (directory / "nested.log").read_text(),
                 "nested startup")
        driver_env = env(parent_dir) | {"WAYLAND_DISPLAY": parent_socket.name,
                                        "RAYWM_TEST_EXTENT": "1280x720"}

        def drive(*commands):
            subprocess.run([str(zig_bin / "raywm-test-input"), *commands], env=driver_env,
                           capture_output=True, text=True, timeout=10, check=True)

        def client_env():
            return env(nested_dir) | {"WAYLAND_DISPLAY": str(nested_socket)}

        # Hold the parent seat on the nested Winit window so host focus is real.
        keeper = start([str(zig_bin / "raywm-test-input"), "move", "700", "550",
                        "down", "left", "up", "left", "sleep", "120000"], driver_env, "seat-keeper")
        time.sleep(0.15)
        drive("move", "700", "550", "down", "left", "up", "left", "sleep", "150")

        probe_env = client_env() | {"RAYWM_SMOKE_SOCKET": str(nested_socket),
                                    "RAYWM_SMOKE_CONTROL": str(directory)}
        client = start([probe, "selection::clipboard_primary_and_focus_lifecycle",
                        "--exact", "--ignored", "--nocapture"], probe_env, "selection-client")
        deadline = time.monotonic() + 120
        while not (directory / "selection-done").exists():
            for want in sorted(directory.glob("want-*")):
                name = want.name[len("want-"):]
                done = directory / f"{name}-done"
                if done.exists():
                    continue
                commands = want.read_text().split()
                if commands:
                    drive(*commands)
                done.touch()
            if client.poll() is not None:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("selection client timed out")
            time.sleep(0.01)
        rejected = client.wait(timeout=30)
        if rejected:
            raise RuntimeError(f"selection client exited with {rejected}")
        processes.remove(("selection-client", client))
        log = (directory / "nested.log").read_text(errors="replace")
        if "Denying clipboard selection without a matching recent input serial" not in log:
            raise RuntimeError("serial rejection was not observed in the compositor log")
        print("selection: PASS (two independent clients, focus, both serial policies, fd errors)", flush=True)

        # ---- foot, wl-copy and wl-paste as independent applications ----
        typed_marker = directory / "foot-typed"
        paste_marker = directory / "foot-pasted"
        mapped_before = log.count("Window mapped")
        foot_env = client_env() | {"LC_ALL": "C.UTF-8", "FOOT_TYPED": str(typed_marker),
                                   "FOOT_PASTED": str(paste_marker), "TERM": "foot"}
        foot = start([shutil.which("foot"), "-c", str(foot_config), "-w", "400x240",
                      "-T", "raywm-stage4-foot", "--", "sh", "-c",
                      'printf "\\033[2J\\033[HFOOTCOPY-1234\\n"; read x; printf "%s" "$x" > "$FOOT_TYPED"; '
                      'read y; printf "%s" "$y" > "$FOOT_PASTED"'],
                     foot_env, "foot")
        wait_for(lambda: foot.poll() is None
                 and (directory / "nested.log").read_text(errors="replace").count("Window mapped") > mapped_before,
                 "foot window map", timeout=20)
        screenshot = directory / "foot.png"

        def foot_rendered():
            subprocess.run(["grim", str(screenshot)], env=driver_env, timeout=10,
                           check=True, capture_output=True)
            return subprocess.run(
                [sys.executable, str(ROOT / "tests/support/png_check.py"), str(screenshot),
                 "--size", "1280x720", "--pixel", "200,120,ff0000"],
                timeout=10, capture_output=True,
            ).returncode == 0

        wait_for(foot_rendered, "foot submitted the configured red background", timeout=20)
        print("foot: map/render PASS (red client-selected background at 200,120)", flush=True)

        # Focus foot and type into the waiting shell: real keyboard delivery.
        drive("move", "100", "120", "down", "left", "up", "left", "sleep", "80")
        drive("key", "h", "down", "key", "h", "up", "key", "i", "down", "key", "i", "up",
              "key", "return", "down", "key", "return", "up", "sleep", "200")
        wait_for(typed_marker.exists, "typed text reached the foot shell")
        if typed_marker.read_text() != "hi":
            raise RuntimeError(f"foot keyboard marker: {typed_marker.read_text()!r}")
        print("foot: keyboard input PASS", flush=True)

        # The fixture clears the terminal and writes the offer on the first row.
        drive("move", "2", "8", "down", "left", "move", "300", "8", "up", "left", "sleep", "200")
        subprocess.run(["grim", str(directory / "foot-selected.png")], env=driver_env,
                       timeout=10, check=True, capture_output=True)
        primary = subprocess.run([shutil.which("wl-paste"), "-p", "-n"], env=client_env(),
                                 capture_output=True, text=True, timeout=15)
        if "FOOTCOPY-1234" not in primary.stdout:
            raise RuntimeError(f"foot primary selection: {primary.stdout!r} {primary.stderr!r}")
        print("foot: mouse selection to primary PASS", flush=True)

        # Copy the selection to the clipboard and read it from wl-paste. Do not
        # click the terminal here: a click would start a new, empty selection.
        time.sleep(0.4)
        drive("key", "ctrl", "down", "key", "shift", "down", "key", "c", "down",
              "key", "c", "up", "key", "shift", "up", "key", "ctrl", "up", "sleep", "300")
        pasted = subprocess.run([shutil.which("wl-paste"), "-n"], env=client_env(),
                                capture_output=True, text=True, timeout=15)
        if "FOOTCOPY-1234" not in pasted.stdout:
            raise RuntimeError(f"foot copy did not reach wl-paste: {pasted.stdout!r} {pasted.stderr!r}")
        print("foot: copy to an independent client PASS", flush=True)

        # Copy from an independent client, paste into foot, run the shell read.
        copier = start([shutil.which("wl-copy"), "--foreground", "WLCOPY-PASTE"],
                       client_env(), "wl-copy")
        time.sleep(0.4)
        drive("move", "100", "120", "down", "left", "up", "left", "sleep", "100")
        drive("key", "ctrl", "down", "key", "shift", "down", "key", "v", "down",
              "key", "v", "up", "key", "shift", "up", "key", "ctrl", "up",
              "sleep", "150", "key", "return", "down", "key", "return", "up", "sleep", "300")
        wait_for(paste_marker.exists, "pasted text reached the foot shell")
        if paste_marker.read_text() != "WLCOPY-PASTE":
            raise RuntimeError(f"foot paste marker: {paste_marker.read_text()!r}")
        print("foot: paste from an independent client PASS", flush=True)

        foot.terminate()
        foot.wait(timeout=5)
        processes.remove(("foot", foot))
        copier.terminate()
        copier.wait(timeout=5)
        processes.remove(("wl-copy", copier))
        if nested.poll() is not None:
            raise RuntimeError("compositor exited during the client qualification")

        # ---- GTK4 and Qt6 probes, when their development files exist ----
        def pkg_flags(*modules):
            cflags = subprocess.check_output(["pkg-config", "--cflags", *modules], text=True).split()
            libs = subprocess.check_output(["pkg-config", "--libs", *modules], text=True).split()
            return cflags + libs

        def pkg_available(*modules):
            return subprocess.run(["pkg-config", "--exists", *modules]).returncode == 0

        def type_text(text):
            commands = []
            for char in text:
                commands += ["key", char, "down", "key", char, "up"]
            commands += ["sleep", "120"]
            drive(*commands)

        def mapped():
            return (directory / "nested.log").read_text(errors="replace").count("Window mapped")

        def qualify_gui(name, source, compiler, modules, extra_flags, color, typed, pasted):
            if not shutil.which(compiler) or not shutil.which("pkg-config"):
                print(f"{name}: SKIP (missing compiler or pkg-config)", flush=True)
                return
            if not pkg_available(*modules):
                print(f"{name}: SKIP (missing {' '.join(modules)} development files)", flush=True)
                return
            program = directory / f"{name}.bin"
            source_path = directory / f"{name}{'.cpp' if name == 'qt6' else '.c'}"
            source_path.write_text(source)
            flags = extra_flags + pkg_flags(*modules)
            subprocess.run([compiler, "-O2", str(source_path), "-o", str(program), *flags],
                           timeout=120, check=True, capture_output=True)
            typed_marker = directory / f"{name}-typed"
            pasted_marker = directory / f"{name}-pasted"
            before = mapped()
            app = start([str(program)], client_env() | {
                "PROBE_TYPED": str(typed_marker), "PROBE_PASTED": str(pasted_marker),
                "QT_QPA_PLATFORM": "wayland", "GDK_BACKEND": "wayland"},
                name)
            wait_for(lambda: app.poll() is None and mapped() > before, f"{name} window map", timeout=25)
            time.sleep(0.5)
            shot = directory / f"{name}.png"
            subprocess.run(["grim", str(shot)], env=driver_env, timeout=10, check=True, capture_output=True)
            subprocess.run([sys.executable, str(ROOT / "tests/support/png_check.py"), str(shot),
                            "--size", "1280x720", "--pixel", f"150,150,{color}"],
                           timeout=10, check=True)
            drive("move", "100", "20", "down", "left", "up", "left", "sleep", "100")
            type_text(typed)
            drive("key", "ctrl", "down", "key", "a", "down", "key", "a", "up",
                  "key", "ctrl", "up", "sleep", "120")
            drive("key", "ctrl", "down", "key", "c", "down", "key", "c", "up",
                  "key", "ctrl", "up", "sleep", "400")
            clipboard = subprocess.run([shutil.which("wl-paste"), "-n"], env=client_env(),
                                       capture_output=True, text=True, timeout=15)
            if typed not in clipboard.stdout:
                raise RuntimeError(f"{name} copy: {clipboard.stdout!r} {clipboard.stderr!r}")
            drive("move", "100", "20", "down", "left", "up", "left", "sleep", "100")
            drive("key", "return", "down", "key", "return", "up", "sleep", "200")
            wait_for(typed_marker.exists, f"{name} typed marker")
            if typed_marker.read_text() != typed:
                raise RuntimeError(f"{name} typed marker: {typed_marker.read_text()!r}")
            pasted_from = start([shutil.which("wl-copy"), "--foreground", pasted],
                                client_env(), f"{name}-copier")
            time.sleep(0.4)
            drive("move", "100", "20", "down", "left", "up", "left", "sleep", "100")
            drive("key", "ctrl", "down", "key", "v", "down", "key", "v", "up",
                  "key", "ctrl", "up", "sleep", "150",
                  "key", "return", "down", "key", "return", "up", "sleep", "250")
            wait_for(pasted_marker.exists, f"{name} pasted marker")
            if pasted_marker.read_text() != pasted:
                raise RuntimeError(f"{name} pasted marker: {pasted_marker.read_text()!r}")
            pasted_from.terminate()
            pasted_from.wait(timeout=5)
            processes.remove((f"{name}-copier", pasted_from))
            if app.poll() is not None:
                raise RuntimeError(f"{name} exited during qualification")
            app.terminate()
            app.wait(timeout=5)
            processes.remove((name, app))
            if nested.poll() is not None:
                raise RuntimeError(f"compositor exited during {name} qualification")
            print(f"{name}: map/render/input/copy/paste PASS", flush=True)

        gtk_source = r"""
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
static int activations = 0;
static void on_activate(GtkEntry *entry, gpointer data) {
    (void) data;
    const char *path = activations++ == 0 ? getenv("PROBE_TYPED") : getenv("PROBE_PASTED");
    FILE *file = path ? fopen(path, "w") : NULL;
    if (file) { fputs(gtk_editable_get_text(GTK_EDITABLE(entry)), file); fclose(file); }
    gtk_editable_set_text(GTK_EDITABLE(entry), "");
}
static void draw_blue(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void) area; (void) width; (void) height; (void) data;
    cairo_set_source_rgb(cr, 0.0, 0.0, 1.0);
    cairo_paint(cr);
}
static void activate(GtkApplication *app, gpointer data) {
    (void) data;
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "RayWM GTK4 probe");
    gtk_window_set_default_size(GTK_WINDOW(window), 320, 200);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *entry = gtk_entry_new();
    GtkWidget *area = gtk_drawing_area_new();
    gtk_widget_set_vexpand(area, TRUE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw_blue, NULL, NULL);
    g_signal_connect(entry, "activate", G_CALLBACK(on_activate), window);
    gtk_box_append(GTK_BOX(box), entry);
    gtk_box_append(GTK_BOX(box), area);
    gtk_window_set_child(GTK_WINDOW(window), box);
    gtk_window_present(GTK_WINDOW(window));
    gtk_widget_grab_focus(entry);
}
int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.raywm.GtkProbe", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
"""
        qt_source = r"""
#include <QApplication>
#include <QFile>
#include <QLineEdit>
#include <QPalette>
#include <QVBoxLayout>
#include <QWidget>
#include <cstdlib>
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QWidget window;
    window.setWindowTitle("RayWM Qt6 probe");
    window.setWindowFlags(Qt::FramelessWindowHint);
    window.resize(320, 200);
    QPalette palette = window.palette();
    palette.setColor(QPalette::Window, QColor(0, 255, 0));
    window.setPalette(palette);
    window.setAutoFillBackground(true);
    auto *edit = new QLineEdit(&window);
    auto *layout = new QVBoxLayout(&window);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->addWidget(edit);
    layout->addStretch(1);
    static int activations = 0;
    QObject::connect(edit, &QLineEdit::returnPressed, [&]() {
        const char *path = activations++ == 0 ? std::getenv("PROBE_TYPED")
                                              : std::getenv("PROBE_PASTED");
        if (path) {
            QFile file(QString::fromLocal8Bit(path));
            if (file.open(QIODevice::WriteOnly)) file.write(edit->text().toUtf8());
        }
        edit->clear();
    });
    window.show();
    return app.exec();
}
"""
        qualify_gui("gtk4", gtk_source, "gcc", ("gtk4",), [], "0000ff", "gtktyped", "gtkpasted")
        qualify_gui("qt6", qt_source, "g++", ("Qt6Widgets",), ["-fPIC"], "00ff00", "qttyped", "qtpasted")
        stop(nested)
        processes.remove(("nested", nested))
        keeper.terminate()
        keeper.wait(timeout=3)
        processes.remove(("seat-keeper", keeper))
        assert not nested_socket.exists() and not (nested_dir / "nested.lock").exists()
        stop(parent)
        processes.remove(("parent", parent))
        print("stage4: PASS (clipboard, primary selection, foot, wl-clipboard, cleanup)", flush=True)
        return 0
    except Exception:
        for name in ["parent", "nested", "selection-client", "foot", "wl-copy"]:
            path = directory / f"{name}.log"
            if path.exists():
                print(f"{name}:\n{path.read_text(errors='replace')[-8000:]}", file=sys.stderr)
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

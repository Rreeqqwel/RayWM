#!/usr/bin/env python3
"""Verify Stage 5B through Winit, Xvfb, software EGL and real GTK4/Qt6 clients."""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

RED = "c72d32"
GREEN = "159258"
PURPLE = "8138b5"
BACKGROUND = "141a24"


def client(toolkit):
    def report(event, **fields):
        print(json.dumps(dict(event=event, **fields)), flush=True)

    if toolkit == "gtk":
        import gi
        gi.require_version("Gtk", "4.0")
        from gi.repository import Gdk, GLib, Gtk

        Gtk.init()
        loop = GLib.MainLoop()
        window = Gtk.Window(title="Stage 5B GTK")
        window.connect("close-request", lambda *_: (loop.quit(), False)[1])
        window.set_decorated(False)
        window.set_default_size(310, 210)
        provider = Gtk.CssProvider()
        provider.load_from_data(f"window {{ background: #{RED}; }}".encode())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        keys = Gtk.EventControllerKey()

        def gtk_key(_controller, key, *_):
            report("key", key=Gdk.keyval_name(key))
            return False

        keys.connect("key-pressed", gtk_key)
        window.add_controller(keys)
        pointer = Gtk.GestureClick()
        pointer.connect("pressed", lambda *_: report("click"))
        window.add_controller(pointer)
        window.present()
        loop.run()
        return 0
    from PyQt6.QtCore import QPoint, Qt
    from PyQt6.QtWidgets import QApplication, QMenu, QWidget

    class Window(QWidget):
        def keyPressEvent(self, event):
            key = event.text()
            report("key", key=key)
            if key == "u":
                self.showFullScreen()
            elif key == "i":
                self.showNormal()
            elif key == "o":
                self.showMaximized()
            elif key == "p":
                self.menu = QMenu(self)
                self.menu.setStyleSheet(f"QMenu {{ background: #{PURPLE}; padding: 6px; }}")
                self.menu.addAction("Stage 5B popup")
                self.menu.popup(self.mapToGlobal(QPoint(20, 20)))

        def mousePressEvent(self, event):
            report("click")

    app = QApplication([])
    window = Window()
    window.setWindowTitle("Stage 5B Qt")
    window.setWindowFlags(Qt.WindowType.FramelessWindowHint)
    window.setAttribute(Qt.WidgetAttribute.WA_StyledBackground)
    window.setStyleSheet(f"background-color: #{GREEN};")
    window.resize(340, 230)
    window.show()
    return app.exec()


def stop(process, expect_clean=False):
    code = process.poll()
    if code is None:
        process.terminate()
        try:
            code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            raise
    if expect_clean and code != 0:
        raise RuntimeError(f"compositor stopped with status {code}")


def qualify(options):
    from PIL import ImageGrab

    for tool in ("Xvfb", "xdotool"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"missing {tool}")
    artifacts = Path(tempfile.mkdtemp(prefix="raywm-stage5b-", dir=options.artifacts))
    print(f"artifacts: {artifacts}", flush=True)
    runtime = artifacts / "runtime"
    runtime.mkdir(mode=0o700)
    processes = {}
    with ExitStack() as cleanup:
        def start(label, args, env, **kwargs):
            stdout = cleanup.enter_context((artifacts / f"{label}.log").open("wb"))
            stderr = cleanup.enter_context((artifacts / f"{label}.wire").open("wb"))
            process = subprocess.Popen(args, env=env, stdout=stdout, stderr=stderr, **kwargs)
            cleanup.callback(stop, process)
            processes[label] = process
            return process

        env = os.environ.copy()
        for name in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "XAUTHORITY"):
            env.pop(name, None)
        env.update(XDG_RUNTIME_DIR=str(runtime), LIBGL_ALWAYS_SOFTWARE="1",
                   XDG_CACHE_HOME=str(artifacts / "cache"))
        read_fd, write_fd = os.pipe()
        try:
            start("xvfb", ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1024x768x24",
                           "-nolisten", "tcp", "-noreset"], env, pass_fds=(write_fd,))
        finally:
            os.close(write_fd)
        import select
        with os.fdopen(read_fd) as display_file:
            if not select.select([display_file], [], [], 10)[0]:
                raise RuntimeError("Xvfb display allocation timed out")
            display = display_file.readline().strip()
            if not display.isdecimal():
                raise RuntimeError("Xvfb could not allocate a display")
        env["DISPLAY"] = f":{display}"
        server = start("nested", [str(options.binary.resolve()), "--backend", "winit",
                                   "--socket", "stage5b"], env)
        socket = runtime / "stage5b"

        def wait(predicate, description):
            end = time.monotonic() + 20
            while time.monotonic() < end:
                dead = [name for name, p in processes.items() if p.poll() is not None]
                if dead:
                    raise RuntimeError(f"{description}: early exit {dead}")
                result = predicate()
                if result:
                    return result
                time.sleep(0.04)
            raise RuntimeError(f"{description}: timed out")

        def xdo(*args, check=True):
            return subprocess.run(["xdotool", *args], env=env, capture_output=True,
                                  text=True, timeout=5, check=check).stdout.strip()

        wait(socket.exists, "nested socket")
        host = wait(lambda: xdo("search", "--name", "RayWM", check=False),
                    "Winit X11 window").splitlines()[0]
        xdo("windowmove", host, "0", "0")
        xdo("windowfocus", "--sync", host)
        gui = env | {"WAYLAND_DISPLAY": socket.name, "WAYLAND_DEBUG": "1",
                     "GDK_BACKEND": "wayland", "GSK_RENDERER": "cairo",
                     "GTK_A11Y": "none", "GSETTINGS_BACKEND": "memory", "QT_QPA_PLATFORM": "wayland",
                     "QT_WAYLAND_DISABLE_WINDOWDECORATION": "1"}

        def wire(label):
            return (artifacts / f"{label}.wire").read_text(errors="replace")

        def event_count(label, event, **fields):
            lines = (artifacts / f"{label}.log").read_text().splitlines(keepends=True)
            return sum(row.get("event") == event and all(row.get(k) == v for k, v in fields.items())
                       for row in (json.loads(line) for line in lines if line.endswith("\n") and line.startswith("{")))

        def pixels(label, points):
            def capture():
                image = ImageGrab.grab(xdisplay=env["DISPLAY"]).convert("RGB")
                values = {f"{x},{y}": image.getpixel((x, y)) for x, y, _ in points}
                if any(any(abs(a - b) > 2 for a, b in zip(values[f"{x},{y}"], bytes.fromhex(hex_rgb)))
                       for x, y, hex_rgb in points):
                    image.save(artifacts / "latest.png")
                    return False
                image.save(artifacts / f"{label}.png")
                print(f"{label}: PASS {values}", flush=True)
                return True
            wait(capture, f"{label} submitted pixels")

        def key(chord):
            xdo("key", "--clearmodifiers", chord)

        def has_configure(label, width, height):
            return re.search(rf"xdg_toplevel[@#]\d+\.configure\({width}, {height},", wire(label))

        script = str(Path(__file__).resolve())
        start("gtk", [sys.executable, script, "--client", "gtk"], gui)
        pixels("single-tile", [(30, 30, RED), (750, 550, RED), (3, 30, BACKGROUND)])
        start("qt", [sys.executable, script, "--client", "qt"], gui)
        pixels("master-stack", [(30, 30, RED), (750, 30, GREEN), (438, 30, BACKGROUND)])
        wait(lambda: has_configure("gtk", 426, 584) and has_configure("qt", 350, 584), "master-stack XDG sizes")
        key("Super_L+space")
        pixels("columns", [(30, 30, RED), (410, 30, GREEN), (399, 30, BACKGROUND)])
        key("Super_L+Shift_L+k")
        pixels("reordered-columns", [(30, 30, GREEN), (410, 30, RED)])
        key("Super_L+space")
        pixels("monocle-qt", [(30, 30, GREEN), (750, 30, GREEN)])
        key("Super_L+j")
        pixels("monocle-gtk", [(30, 30, RED), (750, 30, RED)])
        key("a")
        wait(lambda: event_count("gtk", "key", key="a") == 1, "GTK key focus")
        assert event_count("qt", "key", key="a") == 0
        assert event_count("gtk", "key", key="j") == 0
        key("Super_L+space")
        pixels("floating-layout", [(20, 20, RED), (60, 60, RED), (750, 550, BACKGROUND)])

        key("Super_L+space")
        key("Super_L+Shift_L+space")
        pixels("floating-over-tile", [(30, 30, RED), (750, 550, GREEN)])
        xdo("mousemove", "40", "40", "click", "1")
        wait(lambda: event_count("gtk", "click") == 1, "pointer routed to floating GTK")
        key("Super_L+f")
        pixels("fullscreen", [(3, 3, RED), (797, 597, RED)])
        key("Super_L+f")
        pixels("restore-floating", [(30, 30, RED), (750, 550, GREEN)])
        key("Super_L+Shift_L+space")
        pixels("restore-tiled", [(30, 30, GREEN), (750, 30, RED)])
        key("Super_L+m")
        pixels("maximized", [(3, 3, RED), (797, 597, RED)])
        key("Super_L+m")
        pixels("unmaximized-tiled", [(30, 30, GREEN), (750, 30, RED)])
        key("Super_L+Shift_L+2")
        pixels("workspace-transfer", [(30, 30, GREEN), (750, 30, GREEN)])
        key("Super_L+2")
        pixels("workspace-two", [(30, 30, RED), (750, 30, RED)])
        key("Super_L+Page_Up")
        pixels("workspace-one", [(30, 30, GREEN), (750, 30, GREEN)])

        key("p")
        wait(lambda: re.search(r"xdg_surface[@#]\d+\.get_popup\(", wire("qt")), "Qt xdg_popup")
        pixels("popup-in-tile", [(30, 30, PURPLE), (750, 30, GREEN)])
        key("Super_L+2")
        pixels("switch-with-popup", [(30, 30, RED), (750, 30, RED)])
        wait(lambda: re.search(r"xdg_popup[@#]\d+\.popup_done\(", wire("qt")), "popup_done on workspace switch")
        key("Super_L+1")
        pixels("switch-back-from-popup", [(30, 30, GREEN), (750, 30, GREEN)])

        key("u")
        pixels("qt-xdg-fullscreen", [(3, 3, GREEN), (797, 597, GREEN)])
        key("i")
        pixels("qt-xdg-unfullscreen", [(3, 3, BACKGROUND), (750, 30, GREEN)])
        key("o")
        pixels("qt-xdg-maximized", [(3, 3, GREEN), (797, 597, GREEN)])
        key("i")
        pixels("qt-xdg-unmaximized", [(3, 3, BACKGROUND), (750, 30, GREEN)])

        xdo("windowsize", host, "700", "500")
        wait(lambda: has_configure("qt", 684, 484), "Qt retiled on output resize")
        pixels("retiled-after-output-resize", [(30, 30, GREEN), (690, 490, GREEN), (695, 495, BACKGROUND)])
        for label in ("gtk", "qt"):
            assert ".ack_configure(" in wire(label), label
            assert "wl_keyboard" in wire(label), label
        for name in ("set_fullscreen", "unset_fullscreen", "set_maximized", "unset_maximized"):
            assert re.search(rf"xdg_toplevel[@#]\d+\.{name}\(", wire("qt")), name
        stop(server, expect_clean=True)
        assert not socket.exists()
        assert not (runtime / "stage5b.lock").exists()
        print("Stage 5B nested GTK4 + Qt6 keyboard, pointer, XDG, pixels and socket cleanup: PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=("gtk", "qt"))
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / "target/debug/raywm-smithay")
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    return client(args.client) if args.client else qualify(args)


if __name__ == "__main__":
    sys.exit(main())

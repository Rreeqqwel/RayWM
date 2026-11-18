#!/usr/bin/env python3
"""Stage 4B drag-and-drop, drag-icon and reactive-popup qualification.

Run from the repository: python3 rust/tests/stage4b-smoke.py

Starts the unchanged Zig `-Dtest-input` compositor as a private pixman parent,
runs the Rust Winit compositor inside it, answers the Rust tests' input and
screenshot gates, then qualifies GTK4/Qt6 drag-and-drop between independent
applications. Logs and PNGs stay in a new /tmp/raywm-stage4b-* directory.
"""

import argparse
import json
import os
import re
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig-bin", type=Path, default=ROOT / "zig-out/test-input/bin")
    parser.add_argument("--toolkits-only", action="store_true", help="skip the Rust protocol tests")
    args = parser.parse_args()
    zig_bin = args.zig_bin.resolve()
    for executable in [zig_bin / "raywm", zig_bin / "raywm-test-input"]:
        if not executable.is_file():
            parser.error(f"missing {executable}; build Zig with -Dtest-input first")
    for executable in ["cargo", "grim", "gcc", "g++", "pkg-config", "wl-paste"]:
        if not shutil.which(executable):
            parser.error(f"missing {executable}")

    result = subprocess.run(
        ["cargo", "test", "--workspace", "--locked", "--no-run", "--message-format=json"],
        cwd=ROOT / "rust", capture_output=True, text=True, timeout=300, check=True,
    )
    artifacts = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    probe = next(item["executable"] for item in artifacts
                 if item.get("reason") == "compiler-artifact"
                 and item.get("target", {}).get("name") == "headless" and item.get("executable"))
    compositor = next(item["executable"] for item in artifacts
                      if item.get("reason") == "compiler-artifact"
                      and item.get("target", {}).get("name") == "raywm-smithay"
                      and not item.get("profile", {}).get("test") and item.get("executable"))
    directory = Path(tempfile.mkdtemp(prefix="raywm-stage4b-"))
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
  ctx.bind("Super+F10", function()
    if target ~= 0 then raywm.view_place(target, 0, 0, 800, 600) end
  end)
end }
''')

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
                           capture_output=True, text=True, timeout=60, check=True)

        def client_env():
            return env(nested_dir) | {"WAYLAND_DISPLAY": str(nested_socket)}

        keeper = start([str(zig_bin / "raywm-test-input"), "move", "700", "550",
                        "down", "left", "up", "left", "sleep", "180000"], driver_env, "seat-keeper")
        time.sleep(0.15)
        drive("move", "700", "550", "down", "left", "up", "left", "sleep", "150")

        started = set()

        def run_gate(label, commands):
            done = directory / f"{label}-done"
            try:
                if commands and commands[0] == "parent":
                    commands = commands[1:]
                if commands:
                    drive(*commands)
                reply = "ok"
            except Exception as error:
                reply = f"fail: {error}"
            temporary = done.with_suffix(".tmp")
            temporary.write_text(reply)
            temporary.replace(done)

        def handle_wants():
            for want in sorted(directory.glob("want-*")):
                name = want.name
                if name.startswith("want-shot-"):
                    label = name[len("want-shot-"):]
                    done = directory / f"shot-{label}-done"
                    if done.exists():
                        continue
                    specs = [spec for spec in want.read_text().strip().split(";") if spec]
                    shot = directory / f"shot-{label}.png"
                    subprocess.run(["grim", str(shot)], env=driver_env, timeout=15,
                                   check=True, capture_output=True)
                    command = [sys.executable, str(ROOT / "tests/support/png_check.py"),
                               str(shot), "--size", "1280x720"]
                    for spec in specs:
                        command += ["--pixel", spec.strip()]
                    result = subprocess.run(command, timeout=15, capture_output=True, text=True)
                    reply = ("ok" if result.returncode == 0
                             else "fail: " + (result.stdout + result.stderr).strip())
                    temporary = done.with_suffix(".tmp")
                    temporary.write_text(reply)
                    temporary.replace(done)
                else:
                    label = name[len("want-"):]
                    done = directory / f"{label}-done"
                    if done.exists() or label in started:
                        continue
                    started.add(label)
                    commands = want.read_text().split()
                    threading.Thread(target=run_gate, args=(label, commands),
                                     daemon=True).start()

        def run_test(name, marker):
            process = start([probe, name, "--exact", "--ignored", "--nocapture"],
                            client_env() | {"RAYWM_SMOKE_SOCKET": str(nested_socket),
                                            "RAYWM_SMOKE_CONTROL": str(directory)}
                            | ({"WAYLAND_DEBUG": "client"} if "final_admission" in name else {}),
                            name.split("::")[-1])
            deadline = time.monotonic() + 150
            while not (directory / marker).exists():
                handle_wants()
                if process.poll() is not None:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"{name} timed out")
                time.sleep(0.01)
            status = process.wait(timeout=30)
            if status:
                raise RuntimeError(f"{name} exited with {status}")
            processes.remove((name.split("::")[-1], process))
            print(f"{name}: PASS", flush=True)

        if not args.toolkits_only:
            run_test("dnd::dnd_icon_targets_actions_and_teardown", "dnd-done")
            run_test("dnd::reactive_popup_constraints_and_lifecycle", "popup-done")
            # The reactive scenario leaves a 700x500 output. Restore the host
            # size before the next scenario's 800x600 pointer coordinates.
            drive("key", "super", "down", "key", "f10", "down", "key", "f10", "up", "key", "super", "up")
            wait_for(lambda: "Nested output resized width=800 height=600" in
                     (directory / "nested.log").read_text(errors="replace"), "restore 800x600 output")
            run_test("dnd::final_admission_and_accepted_source_disconnect", "final-admission-done")
            print("source-disconnect: CONFIRMED Smithay 0.7 upstream limitation (drop + FD EOF, zero bytes)", flush=True)

        # ---- GTK4 <-> Qt6 pointer-driven drag and drop ----
        gtk_source = r"""
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void write_text(const char *path, const char *text) {
    if (!path) return;
    FILE *file = fopen(path, "w");
    if (!file) return;
    fputs(text ? text : "", file);
    fclose(file);
}

static gboolean on_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void) target; (void) x; (void) y;
    (void) data;
    write_text(getenv("DROP_FILE"), g_value_get_string(value));
    return TRUE;
}

static void on_right_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void) gesture; (void) n_press; (void) x; (void) y;
    GtkWidget *window = data;
    GtkWidget *popover = gtk_popover_new();
    GtkWidget *label = gtk_label_new("CTX-GTK");
    gtk_popover_set_child(GTK_POPOVER(popover), label);
    gtk_widget_set_parent(popover, window);
    gtk_popover_popup(GTK_POPOVER(popover));
}

static void on_drag_begin(GtkDragSource *source, GdkDrag *drag, gpointer data) {
    (void) source; (void) drag; (void) data;
    fprintf(stderr, "gtk drag-begin\n"); fflush(stderr);
}
static void on_drag_end(GtkDragSource *source, GdkDrag *drag, gboolean delete_data, gpointer data) {
    (void) source; (void) drag; (void) delete_data; (void) data;
    fprintf(stderr, "gtk drag-end\n"); fflush(stderr);
}
static gboolean on_drag_failed(GtkDragSource *source, GdkDrag *drag, GdkDragCancelReason reason, gpointer data) {
    (void) source; (void) drag; (void) data;
    fprintf(stderr, "gtk drag-failed %d\n", (int) reason); fflush(stderr);
    return FALSE;
}

static void activate(GtkApplication *app, gpointer data) {
    (void) data;
    const char *role = getenv("PROBE_ROLE");
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "RayWM GTK DnD probe");
    gtk_window_set_default_size(GTK_WINDOW(window), 320, 200);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    fprintf(stderr, "gtk backend=%s version=%u.%u.%u\n",
            G_OBJECT_TYPE_NAME(gtk_widget_get_display(window)),
            gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
    if (role && strcmp(role, "primary") == 0) {
        GtkWidget *text = gtk_text_view_new();
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(text)), "primary-gtk", -1);
        gtk_window_set_child(GTK_WINDOW(window), text);
    } else if (role && strcmp(role, "source") == 0) {
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        GtkWidget *label = gtk_label_new("DRAG-GTK");
        gtk_widget_set_hexpand(label, FALSE);
        gtk_widget_set_vexpand(label, FALSE);
        gtk_widget_set_halign(label, GTK_ALIGN_START);
        gtk_widget_set_valign(label, GTK_ALIGN_START);
        gtk_widget_set_size_request(label, 200, 60);
        GtkDragSource *source = gtk_drag_source_new();
        GdkContentProvider *provider = gdk_content_provider_new_typed(G_TYPE_STRING, "gtk-to-qt");
        gtk_drag_source_set_content(source, provider);
        gtk_drag_source_set_actions(source, GDK_ACTION_COPY);
        g_signal_connect(source, "drag-begin", G_CALLBACK(on_drag_begin), NULL);
        g_signal_connect(source, "drag-end", G_CALLBACK(on_drag_end), NULL);
        g_signal_connect(source, "drag-failed", G_CALLBACK(on_drag_failed), NULL);
        gtk_widget_add_controller(label, GTK_EVENT_CONTROLLER(source));
        g_object_unref(provider);
        gtk_box_append(GTK_BOX(box), label);
        gtk_window_set_child(GTK_WINDOW(window), box);
        gtk_widget_set_can_focus(label, TRUE);
        gtk_widget_grab_focus(label);
    } else {
        GtkDropTarget *drop = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_COPY);
        g_signal_connect(drop, "drop", G_CALLBACK(on_drop), NULL);
        gtk_widget_add_controller(window, GTK_EVENT_CONTROLLER(drop));
        GtkWidget *label = gtk_label_new("DROP-GTK");
        gtk_window_set_child(GTK_WINDOW(window), label);
    }
    GtkGesture *gesture = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(gesture), 3);
    g_signal_connect(gesture, "pressed", G_CALLBACK(on_right_click), window);
    gtk_widget_add_controller(window, GTK_EVENT_CONTROLLER(gesture));
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.raywm.GtkDndProbe", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
"""
        qt_source = r"""
#include <QApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QTimer>
#include <QWindow>
#include <QContextMenuEvent>
#include <QDrag>
#include <QDropEvent>
#include <QLineEdit>
#include <QMenu>
#include <QLabel>
#include <QMimeData>
#include <QMouseEvent>
#include <QWidget>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void write_text(const char *path, const QString &text) {
    if (!path) return;
    FILE *file = fopen(path, "w");
    if (!file) return;
    fputs(text.toUtf8().constData(), file);
    fclose(file);
}

class Menu : public QMenu {
public:
    Menu(const QString &name, QWidget *parent) : QMenu(name, parent), name_(name) {
        setMouseTracking(true);
        connect(this, &QMenu::hovered, this, [this](QAction *a) { report("hovered", a); });
        connect(this, &QMenu::aboutToShow, this, [this]() { report("aboutToShow"); });
        connect(this, &QMenu::aboutToHide, this, [this]() { report("aboutToHide"); });
        setStyleSheet(QString("QMenu { background: %1; color: black; border: 2px solid black; }")
                      .arg(name == "root" ? "#e04040" : name == "child" ? "#40e040" : "#4040e0"));
    }
    void report(const char *event, QAction *action = nullptr) {
        QJsonArray items;
        for (auto *a : actions()) {
            QRect r = actionGeometry(a);
            QPoint p = mapToGlobal(r.center());
            items.append(QJsonObject{{"text", a->text()}, {"x", p.x()}, {"y", p.y()}});
        }
        auto *w = windowHandle();
        QJsonObject obj{{"menu", name_}, {"event", event}, {"visible", isVisible()},
                        {"surface", w && w->isVisible()},
                        {"x", x()}, {"y", y()}, {"w", width()}, {"h", height()},
                        {"items", items}, {"action", action ? action->text() : ""}};
        if (event == QString("motion")) {
            QPoint p = mapFromGlobal(QCursor::pos());
            obj.insert("local_x", p.x()); obj.insert("local_y", p.y());
        }
        auto line = QJsonDocument(obj).toJson(QJsonDocument::Compact);
        fprintf(stderr, "MENU %s\n", line.constData()); fflush(stderr);
    }
protected:
    bool event(QEvent *event) override {
        bool result = QMenu::event(event);
        if (event->type() == QEvent::Paint) report("paint");
        if (event->type() == QEvent::MouseMove) report("motion");
        return result;
    }
private:
    QString name_;
};

class Probe : public QWidget {
public:
    explicit Probe(bool source) : source_(source), pressed_(false) {
        setWindowTitle("RayWM Qt DnD probe");
        setWindowFlags(Qt::FramelessWindowHint);
        resize(320, 200);
        setAcceptDrops(!source_);
        label_ = new QLabel(source_ ? "DRAG-QT" : "DROP-QT", this);
        label_->setGeometry(0, 0, 200, 40);
        if (!source_) {
            edit_ = new QLineEdit(this);
            edit_->setGeometry(0, 40, 300, 30);
            edit_->setText("primary-qt");
        }
        label_->setAlignment(Qt::AlignLeft | Qt::AlignTop);
        QPalette palette = this->palette();
        palette.setColor(QPalette::Window, source_ ? QColor(255, 255, 0) : QColor(0, 255, 255));
        setPalette(palette);
        setAutoFillBackground(true);
    }
protected:
    void mousePressEvent(QMouseEvent *event) override {
        fprintf(stderr, "qt press button=%d source=%d\n", (int) event->button(), source_ ? 1 : 0);
        fflush(stderr);
        if (source_ && event->button() == Qt::LeftButton) {
            pressed_ = true;
            start_ = event->pos();
        }
    }
    void mouseMoveEvent(QMouseEvent *event) override {
        if (!source_ || !pressed_ || !(event->buttons() & Qt::LeftButton)) return;
        if ((event->pos() - start_).manhattanLength() < QApplication::startDragDistance()) return;
        pressed_ = false;
        auto *drag = new QDrag(this);
        auto *mime = new QMimeData;
        mime->setText("qt-to-gtk");
        drag->setMimeData(mime);
        drag->exec(Qt::CopyAction);
    }
    void mouseReleaseEvent(QMouseEvent *) override { pressed_ = false; }
    void dragEnterEvent(QDragEnterEvent *event) override {
        fprintf(stderr, "qt dragEnter text=%d formats=%s\n", event->mimeData()->hasText() ? 1 : 0,
                event->mimeData()->formats().join(",").toUtf8().constData());
        fflush(stderr);
        if (event->mimeData()->hasText()) event->acceptProposedAction();
    }
    void dropEvent(QDropEvent *event) override {
        fprintf(stderr, "qt drop text=%d\n", event->mimeData()->hasText() ? 1 : 0);
        fflush(stderr);
        if (event->mimeData()->hasText()) {
            write_text(getenv("DROP_FILE"), event->mimeData()->text());
            event->acceptProposedAction();
        }
    }
    void contextMenuEvent(QContextMenuEvent *event) override {
        fprintf(stderr, "qt context menu\n"); fflush(stderr);
        Menu menu("root", this);
        menu.addAction("CTX-QT");
        Menu child("child", &menu);
        child.setTitle("MORE-QT");
        menu.addMenu(&child);
        child.addAction("NESTED-QT");
        Menu grand("grand", &child);
        grand.setTitle("DEEPER-QT");
        child.addMenu(&grand);
        grand.addAction("LEAF-QT");
        menu.exec(event->globalPos());
    }
private:
    bool source_;
    bool pressed_;
    QPoint start_;
    QLabel *label_;
    QLineEdit *edit_ = nullptr;
};

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    const char *role = getenv("PROBE_ROLE");
    bool source = role && strcmp(role, "source") == 0;
    Probe probe(source);
    probe.show();
    return app.exec();
}
"""
        if not (subprocess.run(["pkg-config", "--exists", "gtk4"]).returncode == 0
                and subprocess.run(["pkg-config", "--exists", "Qt6Widgets"]).returncode == 0):
            raise RuntimeError("toolkit qualification BLOCKED: GTK4/Qt6 development files missing")
        else:
            gtk = directory / "gtk-dnd"
            qt = directory / "qt-dnd"
            (directory / "gtk-dnd.c").write_text(gtk_source)
            (directory / "qt-dnd.cpp").write_text(qt_source)
            gtk_flags = (subprocess.check_output(["pkg-config", "--cflags", "--libs", "gtk4"], text=True).split())
            qt_flags = (subprocess.check_output(["pkg-config", "--cflags", "--libs", "Qt6Widgets"], text=True).split())
            subprocess.run(["gcc", "-O2", str(directory / "gtk-dnd.c"), "-o", str(gtk), *gtk_flags],
                           timeout=120, check=True, capture_output=True)
            subprocess.run(["g++", "-O2", "-fPIC", str(directory / "qt-dnd.cpp"), "-o", str(qt), *qt_flags],
                           timeout=120, check=True, capture_output=True)

            def toolkit_env(role):
                return client_env() | {"PROBE_ROLE": role, "GDK_BACKEND": "wayland",
                                       "QT_QPA_PLATFORM": "wayland", "WAYLAND_DEBUG": "client"}

            def wait_window_map(before):
                deadline = time.monotonic() + 25
                while (directory / "nested.log").read_text(errors="replace").count("Window mapped") <= before:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("toolkit window did not map")
                    time.sleep(0.02)

            def run_pair(source_app, target_app, source_name, target_name, expected, label):
                drop_file = directory / f"{label}-drop"
                # The target maps first (full output); the source maps second
                # at the 48px cascade. The drop point is outside the source but
                # inside the target, so raising the pressed source cannot hide
                # the destination.
                mapped = (directory / "nested.log").read_text(errors="replace").count("Window mapped")
                target_process = start([str(target_app)],
                                       toolkit_env("target") | {"DROP_FILE": str(drop_file)},
                                       f"{label}-target")
                wait_window_map(mapped)
                mapped = (directory / "nested.log").read_text(errors="replace").count("Window mapped")
                source_process = start([str(source_app)], toolkit_env("source"), f"{label}-source")
                wait_window_map(mapped)
                time.sleep(0.6)
                subprocess.run(["grim", str(directory / f"{label}-pair.png")], env=driver_env,
                               timeout=15, check=True, capture_output=True)
                drive("move", "100", "80", "down", "left", "sleep", "300",
                      "move", "200", "140", "sleep", "250",
                      "move", "350", "250", "sleep", "250",
                      "move", "600", "450", "sleep", "900", "up", "left", "sleep", "700")
                subprocess.run(["grim", str(directory / f"{label}-dropped.png")], env=driver_env,
                               timeout=15, check=True, capture_output=True)
                if not drop_file.exists():
                    raise RuntimeError(f"{label}: target received no drop")
                if drop_file.read_text() != expected:
                    raise RuntimeError(f"{label}: payload {drop_file.read_text()!r} != {expected!r}")
                for process, name in [(target_process, f"{label}-target"),
                                      (source_process, f"{label}-source")]:
                    if process.poll() is not None:
                        raise RuntimeError(f"{label}: {name} exited during DnD")
                if nested.poll() is not None:
                    raise RuntimeError(f"{label}: compositor exited during DnD")
                source_process.terminate()
                source_process.wait(timeout=5)
                processes.remove((f"{label}-source", source_process))
                target_process.terminate()
                target_process.wait(timeout=5)
                processes.remove((f"{label}-target", target_process))
                print(f"{label}: pointer-driven toolkit DnD PASS ({expected})", flush=True)

            just_menus = bool(os.environ.get("RAYWM_ONLY_MENU"))
            if not just_menus:
                run_pair(gtk, qt, "gtk4", "qt6", "gtk-to-qt", "gtk-to-qt")
                run_pair(qt, gtk, "qt6", "gtk4", "qt-to-gtk", "qt-to-gtk")

            def launch_pair(source_app, target_app, label):
                drop_file = directory / f"{label}-drop"
                mapped = (directory / "nested.log").read_text(errors="replace").count("Window mapped")
                target_process = start([str(target_app)],
                                       toolkit_env("target") | {"DROP_FILE": str(drop_file)},
                                       f"{label}-target")
                wait_window_map(mapped)
                mapped = (directory / "nested.log").read_text(errors="replace").count("Window mapped")
                source_process = start([str(source_app)], toolkit_env("source"), f"{label}-source")
                wait_window_map(mapped)
                time.sleep(0.6)
                return source_process, target_process, drop_file

            def close_pair(label, source_process, target_process):
                for process, name in [(target_process, f"{label}-target"),
                                      (source_process, f"{label}-source")]:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
                    processes.remove((name, process))

            if not just_menus:
                # Cancelled pointer drag: enter the target, return to the source,
                # release. No drop may reach the target and both apps survive.
                label = "cancel"
                source_process, target_process, drop_file = launch_pair(gtk, qt, label)
                drive("move", "100", "80", "down", "left", "sleep", "300",
                      "move", "600", "450", "sleep", "500",
                      "move", "100", "80", "sleep", "300", "up", "left", "sleep", "600")
                if drop_file.exists():
                    raise RuntimeError("cancelled toolkit drag still delivered a drop")
                if source_process.poll() is not None or target_process.poll() is not None:
                    raise RuntimeError("toolkit app exited during a cancelled drag")
                if nested.poll() is not None:
                    raise RuntimeError("compositor exited during a cancelled drag")
                close_pair(label, source_process, target_process)
                print("cancel: toolkit drag cancellation PASS", flush=True)

                # Target closes during an active drag.
                label = "target-close"
                source_process, target_process, drop_file = launch_pair(gtk, qt, label)
                drag_thread = threading.Thread(
                    target=lambda: drive("move", "100", "80", "down", "left", "sleep", "300",
                                         "move", "200", "140", "sleep", "250",
                                         "move", "600", "450", "sleep", "900",
                                         "up", "left", "sleep", "600"),
                    daemon=True)
                drag_thread.start()
                time.sleep(1.1)
                target_process.terminate()
                target_process.wait(timeout=5)
                drag_thread.join(timeout=15)
                time.sleep(0.5)
                if drop_file.exists():
                    raise RuntimeError("dead target received a drop")
                if source_process.poll() is not None or nested.poll() is not None:
                    raise RuntimeError("source or compositor died with a closing target")
                close_pair(label, source_process, target_process)
                print("target-close: drag survives target disconnect PASS", flush=True)

                # Source closes during an active drag.
                label = "source-close"
                source_process, target_process, drop_file = launch_pair(qt, gtk, label)
                drag_thread = threading.Thread(
                    target=lambda: drive("move", "100", "80", "down", "left", "sleep", "300",
                                         "move", "200", "140", "sleep", "250",
                                         "move", "600", "450", "sleep", "3000",
                                         "up", "left", "sleep", "600"),
                    daemon=True)
                drag_thread.start()
                time.sleep(1.1)
                source_process.terminate()
                source_process.wait(timeout=5)
                drag_thread.join(timeout=15)
                time.sleep(0.5)
                # Smithay tears the grab down when the drag origin surface dies and
                # may still emit a final drop indication. The source is gone, so the
                # target must receive no payload; an empty file is the toolkit's
                # representation of that no-data drop.
                if drop_file.exists() and drop_file.read_text():
                    raise RuntimeError("disconnected source delivered data")
                if target_process.poll() is not None or nested.poll() is not None:
                    raise RuntimeError("target or compositor died with a closing source")
                close_pair(label, source_process, target_process)
                print("source-close: drag teardown without data PASS", flush=True)

            def run_context_menu(app, label):
                before = (directory / "nested.log").read_text(errors="replace")
                before = before.count("Popup role created")
                mapped = (directory / "nested.log").read_text(errors="replace").count("Window mapped")
                process = start([str(app)], toolkit_env("target"), f"{label}-ctx")
                wait_window_map(mapped)
                time.sleep(0.5)
                if label.startswith("qt"):
                    shot = directory / f"{label}.png"
                    subprocess.run(["grim", str(shot)], env=driver_env, timeout=15,
                                   check=True, capture_output=True)
                    subprocess.run([sys.executable, str(ROOT / "tests/support/png_check.py"),
                                    str(shot), "--size", "1280x720", "--pixel", "250,150,00ffff"],
                                   timeout=15, check=True)
                drive("move", "250", "150", "down", "right", "up", "right", "sleep", "500")
                deadline = time.monotonic() + 15
                while (directory / "nested.log").read_text(errors="replace").count(
                        "Popup role created") <= before:
                    if time.monotonic() >= deadline:
                        raise RuntimeError(f"{label}: context menu did not create a popup")
                    time.sleep(0.02)
                if process.poll() is not None or nested.poll() is not None:
                    raise RuntimeError(f"{label}: process died opening a context menu")
                if label.startswith("qt"):
                    qualify_menu(process, f"{label}-ctx")
                drive("key", "escape", "down", "key", "escape", "up", "sleep", "300")
                process.terminate()
                process.wait(timeout=5)
                processes.remove((f"{label}-ctx", process))
                print(f"{label}: context-menu popup PASS", flush=True)

            def qualify_menu(process, name):
                log = directory / f"{name}.log"

                def events():
                    # The toolkit is still appending. A snapshot may end in
                    # the middle of its JSON write; wait for the newline.
                    # Malformed complete records must still fail qualification.
                    complete = log.read_text(errors="replace").split("\n")[:-1]
                    return [json.loads(line[5:]) for line in complete
                            if line.startswith("MENU ")]

                def observed(menu, event, action=None):
                    return [e for e in events() if e["menu"] == menu and e["event"] == event
                            and (action is None or e["action"] == action)]

                def hover(menu, text):
                    wait_for(lambda: observed(menu, "paint"), f"{menu} painted")
                    state = observed(menu, "paint")[-1]
                    item = next(item for item in state["items"] if item["text"] == text)
                    motions = len(observed(menu, "motion"))
                    drive("move", str(item["x"]-2), str(item["y"]),
                          "move", str(item["x"]), str(item["y"]))
                    wait_for(lambda: observed(menu, "hovered", text), f"{menu} hovered {text}", timeout=5)
                    wait_for(lambda: len(observed(menu, "motion")) > motions,
                             f"{menu} fresh pointer motion", timeout=5)
                    return state

                hover("root", "MORE-QT")
                wait_for(lambda: observed("child", "paint"), "Qt hover submenu timer", timeout=5)
                hover("child", "DEEPER-QT")
                wait_for(lambda: observed("grand", "paint"), "Qt second submenu timer", timeout=5)
                grand = hover("grand", "LEAF-QT")
                # Capture actual submitted menu pixels, with bounded observation
                # retries while the toolkit frame callback completes.
                specs = []
                for menu, color in [("root", "e04040"), ("child", "40e040"), ("grand", "4040e0")]:
                    state = observed(menu, "paint")[-1]
                    if not state["visible"] or not state["surface"]:
                        raise RuntimeError(f"{menu}: no visible platform surface")
                    if not (0 <= state["x"] < 800 and 0 <= state["y"] < 600
                            and state["x"] + state["w"] <= 800
                            and state["y"] + state["h"] <= 600):
                        raise RuntimeError(f"{menu}: out-of-output geometry {state}")
                    specs += ["--pixel", f"{state['x']+4},{state['y']+4},{color}"]
                shot = directory / "qt-nested-menus.png"
                def rendered():
                    subprocess.run(["grim", str(shot)], env=driver_env, timeout=10,
                                   check=True, capture_output=True)
                    return subprocess.run([sys.executable, str(ROOT / "tests/support/png_check.py"),
                                           str(shot), "--size", "1280x720", *specs],
                                          timeout=10, capture_output=True).returncode == 0
                wait_for(rendered, "Qt nested rendered pixels", timeout=5)
                # Return across the same submenu action and re-enter the child.
                hover("child", "DEEPER-QT")
                hover("grand", "LEAF-QT")
                drive("move", "700", "550", "down", "left", "up", "left")
                for menu in ["grand", "child", "root"]:
                    wait_for(lambda menu=menu: observed(menu, "aboutToHide"), f"{menu} outside-click hide", timeout=5)
                wait_for(lambda: len(re.findall(r"xdg_popup[#@]\d+\.destroy\(\)", log.read_text(errors="replace"))) >= 3,
                         "popup teardown", timeout=5)
                trace = log.read_text(errors="replace")
                if trace.count(".get_popup(") < 3 or trace.count(".ack_configure(") < 3:
                    raise RuntimeError("missing Qt popup configure/ACK sequence")
                print("qt-menu: two hover-driven nested popups/render/grab/outside-click PASS", flush=True)

            run_context_menu(gtk, "gtk-menu")
            run_context_menu(qt, "qt-menu")

            def run_primary(app, label, expected):
                mapped = (directory / "nested.log").read_text(errors="replace").count("Window mapped")
                process = start([str(app)], toolkit_env("primary"), f"{label}-primary")
                wait_window_map(mapped)
                trace = directory / f"{label}-primary.log"
                wait_for(lambda: "wl_keyboard" in trace.read_text(errors="replace")
                         and ".enter(" in trace.read_text(errors="replace"), f"{label} keyboard enter")
                # GtkTextView and QLineEdit are ordinary text widgets. Select by
                # a real held-pointer gesture, never by setting clipboard content.
                y = "8" if label.startswith("gtk") else "55"
                drive("move", "2", y, "down", "left", "sleep", "80",
                      "move", "160", y, "up", "left")
                wait_for(lambda: re.search(r"zwp_primary_selection_device_v1[#@]\d+\.set_selection",
                                           trace.read_text(errors="replace")), f"{label} set_selection")
                paste = subprocess.run(["wl-paste", "-p", "-n", "--type", "text/plain;charset=utf-8"],
                                       env=client_env() | {"WAYLAND_DEBUG": "client"},
                                       capture_output=True, timeout=15, check=True)
                (directory / f"{label}-receiver.log").write_bytes(paste.stderr)
                (directory / f"{label}-payload").write_bytes(paste.stdout)
                source_trace = trace.read_text(errors="replace")
                selection = re.findall(r"zwp_primary_selection_device_v1[#@]\d+\.set_selection\([^,]+, (\d+)\)", source_trace)
                buttons = re.findall(r"wl_pointer[#@]\d+\.button\((\d+), \d+, 272, ([01])\)", source_trace)
                receiver_trace = paste.stderr.decode(errors="replace")
                # GTK uses the selection-start press; Qt uses the release.
                # Both are actual delivered user events allowed by Stage 4A.
                if not selection or selection[-1] not in [serial for serial, _ in buttons]:
                    raise RuntimeError(f"{label}: set_selection did not use a delivered button serial")
                if label.startswith("gtk") and (selection[-1], "1") not in buttons:
                    raise RuntimeError(f"{label}: GTK did not use the traced press serial")
                for required in ["zwp_primary_selection_device_manager_v1", ".get_device(", ".create_source(",
                                 '.offer("text/plain;charset=utf-8")', '.send("text/plain;charset=utf-8", fd ']:
                    if required not in source_trace:
                        raise RuntimeError(f"{label}: missing source protocol observation {required}")
                if '.receive("text/plain;charset=utf-8", fd ' not in receiver_trace:
                    raise RuntimeError(f"{label}: missing receiver FD request")
                (directory / f"{label}-summary.json").write_text(json.dumps({
                    "backend": "wayland", "selection_serial": int(selection[-1]),
                    "delivered_pointer_buttons": [{"serial": int(serial), "pressed": state == "1"}
                                                  for serial, state in buttons],
                    "mime": "text/plain;charset=utf-8", "payload_bytes": len(paste.stdout),
                    "payload": paste.stdout.decode()}, indent=2) + "\n")
                if paste.stdout != expected.encode():
                    raise RuntimeError(f"{label}: payload {paste.stdout!r} != {expected!r}")
                process.terminate()
                process.wait(timeout=5)
                processes.remove((f"{label}-primary", process))
                empty = subprocess.run(["wl-paste", "-p", "-n"], env=client_env(),
                                       capture_output=True, timeout=10)
                if empty.returncode == 0 or empty.stdout:
                    raise RuntimeError(f"{label}: stale selection after source disconnect")
                print(f"{label}: real toolkit primary selection/FD payload/cleanup PASS", flush=True)

            run_primary(gtk, "gtk-primary", "primary-gtk")
            run_primary(qt, "qt-primary", "primary-qt")

        if nested.poll() is not None:
            raise RuntimeError("compositor exited before shutdown")
        stop(nested)
        processes.remove(("nested", nested))
        keeper.terminate()
        keeper.wait(timeout=3)
        processes.remove(("seat-keeper", keeper))
        assert not nested_socket.exists() and not (nested_dir / "nested.lock").exists()
        stop(parent)
        processes.remove(("parent", parent))
        print("stage4b: PASS", flush=True)
        return 0
    except Exception:
        for name in ["parent", "nested"] + [name for name, _ in processes]:
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

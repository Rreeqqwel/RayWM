"""Stage 3 driver; called by nested-smoke.py --stage3 inside its private parent."""
import subprocess
import sys


def qualify(root, directory, probe, probe_env, driver_env, start, wait_for, drive, zig_bin):
    client = start([probe, "floating::nested_floating_focus_geometry_and_popups", "--exact",
                    "--ignored", "--nocapture"], probe_env, "client")

    def ready(name):
        wait_for(lambda: (directory / name).exists(), name)

    def mark(name):
        (directory / name).touch()

    def pixels(name, points):
        path = directory / (name + ".png")
        subprocess.run(["grim", str(path)], env=driver_env, timeout=10, check=True,
                       capture_output=True)
        command = [sys.executable, str(root / "tests/support/png_check.py"), str(path),
                   "--size", "1280x720"]
        for x, y, rgb in points:
            command += ["--pixel", f"{x},{y},{rgb}"]
        subprocess.run(command, timeout=10, check=True)
        print(f"stage3 pixels: PASS ({name})", flush=True)

    ready("three-ready")
    pixels("three", [(20,20,"ff0000"),(60,60,"00ff00"),(110,110,"0000ff")])
    drive("move","20","20","sleep","100","down","left","up","left",
          "key","a","down","key","a","up","sleep","100")
    ready("focus-ready")
    pixels("focus",[(110,110,"ff0000"),(340,80,"00ff00"),(400,300,"0000ff")])
    drive("move","100","100","down","left","sleep","250","move","250","200",
          "sleep","150","up","left","sleep","100")
    mark("move-driven")
    ready("move-ready")
    pixels("moved",[(160,110,"ff0000"),(60,60,"00ff00"),(110,110,"0000ff")])
    drive("move","160","110","down","left","sleep","250","move","210","160",
          "sleep","150","up","left","sleep","100")
    mark("invalid-driven")
    ready("invalid-ready")
    pixels("invalid-serial",[(160,110,"ff0000"),(200,105,"ff0000"),(110,110,"0000ff")])
    ready("resize-armed")
    drive("move","160","110","down","left","sleep","250","move","260","210",
          "sleep","150","up","left","sleep","100")
    mark("resize-driven")
    ready("resize-unacked")
    pixels("resize-unacked",[(160,110,"ff0000"),(460,330,"ff0000")])
    mark("resize-ack")
    ready("resize-ready")
    pixels("resize-min",[(260,200,"ff0000"),(460,330,"ff0000"),(240,200,"0000ff")])
    drive("move","460","330","down","left","sleep","250","move","790","590",
          "sleep","150","up","left","sleep","100")
    mark("max-driven")
    ready("max-ready")
    pixels("resize-max",[(260,200,"ff0000"),(660,480,"ff0000"),(680,480,"141a24")])
    drive("move","300","230","down","left","sleep","400","up","left","sleep","100")
    ready("popup-ready")
    pixels("popups",[(670,500,"ffff00"),(730,560,"ff00ff"),(650,480,"ff0000")])
    drive("move","730","560","down","left","up","left",
          "key","b","down","key","b","up","sleep","100")
    mark("popup-key-driven")
    ready("reposition-ready")
    pixels("reposition",[(670,500,"ff00ff"),(750,550,"ffff00")])
    drive("move","100","100","down","left","up","left","sleep","100")
    ready("dismiss-ready")
    pixels("dismissed",[(670,500,"141a24"),(660,480,"ff0000")])
    ready("parent-armed")
    # Keep a real button down while the root and its explicit popup grab die.
    driver = subprocess.Popen([str(zig_bin / "raywm-test-input"),
                               "move","300","230","down","left","sleep","1500","up","left",
                               "sleep","100"], env=driver_env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ready("parent-popup-ready")
        mark("destroy-parent")
        ready("parent-destroyed")
        if driver.wait(timeout=5):
            raise RuntimeError("held-parent driver failed")
    finally:
        if driver.poll() is None:
            driver.kill()
            driver.wait(timeout=3)
    pixels("parent-destroyed",[(110,110,"0000ff"),(300,230,"0000ff")])
    ready("keyboard-popup-armed")
    drive("key","c","down","key","c","up","sleep","100")
    ready("keyboard-popup-ready")
    pixels("keyboard-popup",[(130,130,"ffff00"),(300,230,"0000ff")])
    mark("disconnect-popup")
    ready("popup-disconnected")
    pixels("popup-disconnect",[(130,130,"0000ff"),(300,230,"0000ff")])
    ready("unmap-armed")
    drive("move","200","150","down","left","sleep","1500","up","left","sleep","100")
    mark("unmap-driven")
    ready("unmap-remapped")
    pixels("unmap-resize",[(110,110,"0000ff"),(300,230,"0000ff")])
    ready("disconnect-armed")
    drive("move","200","150","down","left","sleep","400","move","250","150",
          "sleep","150","up","left","sleep","100")
    mark("disconnect-driven")
    ready("survivor-ready")
    pixels("survivor",[(20,20,"00ffff"),(300,230,"00ffff")])
    mark("finish")
    if client.wait(timeout=10):
        raise RuntimeError("Stage 3 graphics client failed")
    assert (directory / "client-done").exists()
    return client


def independent(root, directory, client_env, driver_env, start, wait_for, drive, zig_bin):
    """Use the existing, unchanged Zig client, including its real CSD handler."""
    clients = []
    for index in range(3):
        name = f"independent-{index}"
        environment = client_env | {"WAYLAND_DISPLAY": client_env["RAYWM_SMOKE_SOCKET"],
                                    "RAYWM_TEST_ROUNDS": "1", "RAYWM_TEST_HOLD": "1",
                                    "RAYWM_TEST_PATTERN": "1", "RAYWM_TEST_KBD": "1",
                                    "RAYWM_TEST_PTR": "1", "RAYWM_TEST_CSD_MOVE": "1"}
        if index == 0:
            environment["RAYWM_TEST_SUB"] = "1"
        process = start([str(zig_bin / "raywm-test-client")], environment, name)
        clients.append((name, process))
        log = directory / (name + ".log")
        wait_for(lambda: "round 0 frame done" in log.read_text(), name + " submitted frame")

    def pixels(name, points):
        path = directory / (name + ".png")

        def observed():
            subprocess.run(["grim", str(path)], env=driver_env, timeout=10, check=True,
                           capture_output=True)
            command = [sys.executable, str(root / "tests/support/png_check.py"), str(path),
                       "--size", "1280x720"]
            for x, y, rgb in points:
                command += ["--pixel", f"{x},{y},{rgb}"]
            return subprocess.run(command, timeout=10, capture_output=True).returncode == 0

        wait_for(observed, name + " pixels")

    pixels("independent-three",[(20,20,"ff0000"),(65,25,"00ff00"),
                                 (300,70,"00ff00"),(300,110,"ff0000")])
    drive("move","30","30","down","left","sleep","250","move","130","130",
          "sleep","150","up","left","key","a","down","key","a","up","sleep","150")
    log = directory / "independent-0.log"
    wait_for(lambda: "ptr enter sub at 10,10" in log.read_text()
             and "csd move requested" in log.read_text(), "independent subsurface input/CSD")
    pixels("independent-moved",[(20,20,"141a24"),(110,110,"ff0000"),(165,125,"00ff00")])
    print("independent Zig clients: PASS (three frames, subsurface input, CSD move and pixels)", flush=True)
    return clients

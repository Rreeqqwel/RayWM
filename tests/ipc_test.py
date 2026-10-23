"""Real socket tests. The shell harness supplies a private compositor."""
import json
import os
import socket
import stat
import struct
import subprocess
import sys
import time

path, root = sys.argv[1:]
checks = 0


def check(condition):
    global checks
    assert condition
    checks += 1


def connect():
    peer = socket.socket(socket.AF_UNIX)
    peer.settimeout(3)
    deadline = time.monotonic() + 3
    while True:
        try:
            peer.connect(path)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.01)
    return peer


class Client:
    def __init__(self):
        self.socket = connect()
        self.stream = self.socket.makefile("rb")
        self.ident = 0

    def request(self, method, params=None, **extra):
        self.ident += 1
        message = {"v": 1, "id": self.ident, "method": method, "params": params or {}}
        message.update(extra)
        self.socket.sendall((json.dumps(message) + "\n").encode())
        return self.read()

    def read(self):
        return json.loads(self.stream.readline(131073))

    def close(self):
        self.stream.close()
        self.socket.close()


check(stat.S_IMODE(os.stat(path).st_mode) == 0o600)
client = Client()
compositor = struct.unpack("3i", client.socket.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
fd_baseline = len(os.listdir(f"/proc/{compositor}/fd"))
windows = client.request("windows")["result"]["items"]
check(len(windows) == 1 and isinstance(windows[0]["xwayland"], bool))
view = windows[0]["id"]
outputs = client.request("outputs")["result"]["items"]
check(len(outputs) == 1 and outputs[0]["enabled"])
workspaces = client.request("workspaces")["result"]["items"]
check(len(workspaces) == 9)
page = client.request("workspaces", {"limit": 1})["result"]
check(len(page["items"]) == 1 and page["next"] == 1)
check(not client.request("eval", {"code": "os.exit()"})["ok"])
check(not client.request("windows", v=2)["ok"])
check(not client.request("windows", id=True)["ok"])
check(not client.request("windows", {"limit": 10000})["ok"])
check(not client.request("focus", {"window": -1})["ok"])
check(not client.request("focus", {"window": 4294967295})["ok"])
check(not client.request("workspace_activate", {"workspace": 1, "extra": "bad"})["ok"])
check(client.request("windows")["ok"])

# Framing survives fragmented requests, malformed JSON and nested payloads.
for payload in (b'{bad}\n', b'[' * 33 + b'0' + b']' * 33 + b'\n', b'{"v":1,"id":1,"id":2,"method":"windows"}\n', b'\x00\n'):
    client.socket.sendall(payload)
    check(not client.read()["ok"])
frame = b'{"v":1,"id":1000,"method":"windows"}\n'
client.socket.sendall(frame[:10])
time.sleep(0.02)
client.socket.sendall(frame[10:])
check(client.read()["ok"])

subscription = Client()
check(subscription.request("subscribe", {"events": ["workspace_activate", "view_focus"]})["ok"])
second = next(w["id"] for w in workspaces if w["name"] == "2")
first = next(w["id"] for w in workspaces if w["name"] == "1")
check(client.request("workspace_activate", {"workspace": second})["ok"])
events = [subscription.read(), subscription.read()]
check(any(e.get("event") == "workspace_activate" and e["subject"] == second for e in events))
check(not client.request("focus", {"window": view})["ok"])
check(client.request("window_workspace", {"window": view, "workspace": second})["ok"])
check(client.request("focus", {"window": view})["ok"])
check(client.request("workspace_activate", {"workspace": first})["ok"])
subscription.close()

# Half-close drains the response; an oversized line disconnects safely.
half = connect()
half.sendall(frame)
half.shutdown(socket.SHUT_WR)
check(json.loads(half.makefile("rb").readline())["ok"])
half.close()
oversize = connect()
try:
    oversize.sendall(b"x" * 65537)
    check(oversize.recv(1) == b"")
except (ConnectionResetError, BrokenPipeError):
    check(True)
oversize.close()
partial = connect()
partial.sendall(b"{")
time.sleep(5.2)
check(partial.recv(1) == b"")
partial.close()

# Admission and disconnect limits leave the compositor usable.
peers = [connect() for _ in range(40)]
time.sleep(0.1)
admitted = 0
for peer in peers:
    try:
        peer.sendall(frame)
        if peer.recv(4096):
            admitted += 1
    except (ConnectionResetError, BrokenPipeError):
        pass
check(0 < admitted <= 31)
for peer in peers:
    peer.close()
time.sleep(0.1)
for _ in range(100):
    peer = connect()
    peer.sendall(frame)
    peer.close()
check(client.request("windows")["ok"])
time.sleep(0.1)
check(len(os.listdir(f"/proc/{compositor}/fd")) <= fd_baseline + 1)

# Stop reading one subscriber while another client keeps making progress.
slow = Client()
slow.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
check(slow.request("subscribe", {"events": ["workspace_activate", "workspace_will_activate"]})["ok"])
for i in range(3000):
    check(client.request("workspace_activate", {"workspace": first if i % 2 else second})["ok"])
slow.socket.settimeout(3)
try:
    while slow.socket.recv(65536):
        pass
    check(True)
except ConnectionResetError:
    check(True)
slow.close()
check(client.request("windows")["ok"])
result = subprocess.check_output([sys.executable, root + "/scripts/raywmctl", "--socket", path, "workspaces"])
check(len(json.loads(result)) == 9)
client.close()
print(f"ipc: {checks} checks passed")

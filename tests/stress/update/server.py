#!/usr/bin/env python3
"""A misbehaving HTTPS stand-in for GitHub, for tests/stress/cat/update.sh.

  server.py ROOT CERT KEY PLAN PORT_FILE

Serves files under ROOT. PLAN is a JSON file, re-read on every request,
mapping a URL path to a behaviour (paths not in it are served normally):
  {"status": 403, "headers": {"x-ratelimit-remaining": "0"}, "body": "..."}
  {"truncate": N}        send the full Content-Length, close after N bytes
  {"chunked_extra": N}   no Content-Length, N bytes more than the file
  {"slow": BPS}          send at BPS bytes per second
  {"redirect": URL}      302 to URL
  {"endless": true}      an endless body without Content-Length
  {"hang": SECONDS}      accept, then say nothing
Writes the chosen port to PORT_FILE and every request line to ROOT/requests.log.
"""
import http.server
import json
import os
import socketserver
import ssl
import sys
import time
import urllib.parse

ROOT, CERT, KEY, PLAN, PORT_FILE = sys.argv[1:6]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        with open(os.path.join(ROOT, "requests.log"), "a") as f:
            f.write("%s %s\n" % (self.command, self.path))
        path = self.path.split("?")[0]
        query = self.path[len(path):]
        try:
            plan = json.load(open(PLAN))
        except (OSError, ValueError):
            plan = {}
        rule = plan.get(self.path) or plan.get(path) or {}
        file = os.path.normpath(os.path.join(ROOT, path.lstrip("/")))
        # The API URL template carries ?page=N: map it to releases-N.json.
        page = urllib.parse.parse_qs(query.lstrip("?")).get("page")
        if page:
            file = os.path.join(os.path.dirname(file), "releases-%s.json" % page[0])
        if not file.startswith(os.path.abspath(ROOT)):
            return self.reply(404, b"no")
        if "hang" in rule:
            time.sleep(rule["hang"])
            return
        if "redirect" in rule:
            self.send_response(302)
            self.send_header("Location", rule["redirect"])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if "status" in rule:
            return self.reply(rule["status"], rule.get("body", "error").encode(), rule.get("headers", {}))
        if "endless" in rule:
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                while True:
                    self.wfile.write(b"x" * 65536)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                return
        try:
            data = open(file, "rb").read()
        except OSError:
            return self.reply(404, b"not found")
        if "chunked_extra" in rule:
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(data + b"\0" * rule["chunked_extra"])
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            if "truncate" in rule:
                self.wfile.write(data[: rule["truncate"]])
                self.wfile.flush()
                self.close_connection = True
                return
            if "slow" in rule:
                step = max(1, int(rule["slow"]) // 10)
                for i in range(0, len(data), step):
                    self.wfile.write(data[i:i + step])
                    self.wfile.flush()
                    time.sleep(0.1)
                return
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def reply(self, status, body, headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


httpd = Server(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(httpd.server_address[1]))
os.rename(PORT_FILE + ".tmp", PORT_FILE)
httpd.serve_forever()

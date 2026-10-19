#!/usr/bin/env python3
"""Real HTTP origin for the native broker contract; never logs credentials."""
import argparse
import base64
import http.server
import json
from pathlib import Path
import select
import threading
import time
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True)
root = Path(parser.parse_args().root)
root.mkdir(parents=True, exist_ok=True)
lock = threading.Lock()
observed = []


def publish(name, value):
    temporary = root / (name + ".tmp")
    temporary.write_text(json.dumps(value), encoding="utf-8")
    temporary.replace(root / name)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.do_GET()

    def do_GET(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size > 65536:
            self.send_error(413)
            return
        raw = self.rfile.read(size)
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            body = {}
        header = (root / "header-secret").read_text(encoding="utf-8")
        secret = (root / "body-secret").read_text(encoding="utf-8")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        mode = query.get("case", ["normal"])[0]
        with lock:
            observed.append({"method": self.command, "mode": mode,
                             "path": urllib.parse.urlsplit(self.path).path,
                             "query_q": query.get("q", [""])[0],
                             "header_ok": self.headers.get("X-Fixture-Key") == header,
                             "json_ok": body.get("api_key") == secret,
                             "sentinel_ok": body.get("sentinel") == "approved-body"})
            number = len(observed)
            publish("observed.json", observed)
        if mode in ("hold", "timeout"):
            if select.select([self.connection], [], [], 20)[0]:
                try:
                    closed = self.connection.recv(1) == b""
                except ConnectionResetError:
                    closed = True
                if closed:
                    (root / f"closed-{number}").write_text("closed")
            return
        if mode == "controlled-hold":
            # Each real exchange has its own release marker. A cancelled A
            # connection cannot release B or cause a queued A exchange to run.
            deadline = time.monotonic() + 20
            while not (root / f"release-{number}").exists():
                if time.monotonic() >= deadline:
                    self.close_connection = True
                    return
                if select.select([self.connection], [], [], 0.02)[0]:
                    try:
                        closed = self.connection.recv(1) == b""
                    except ConnectionResetError:
                        closed = True
                    if closed:
                        (root / f"closed-{number}").write_text("closed")
                        return
        if mode == "disconnect":
            self.close_connection = True
            return
        status = 503 if mode == "status" else (302 if mode == "redirect" else 200)
        if urllib.parse.urlsplit(self.path).path == "/search":
            payload = json.dumps({"results": [{"title": "Native Searx fixture",
                "url": "https://example.test/real-plugin", "content": "real gateway web result"}]}).encode()
        elif mode == "reflect-raw":
            payload = json.dumps({"echo": secret}).encode()
        elif mode == "reflect-unicode":
            payload = ('{"echo":"' + ''.join(f"\\u{ord(c):04x}" for c in secret) + '"}').encode()
        elif mode == "reflect-percent":
            payload = json.dumps({"echo": urllib.parse.quote(secret, safe="")}).encode()
        elif mode == "reflect-base64":
            payload = json.dumps({"echo": base64.b64encode(secret.encode()).decode()}).encode()
        elif mode == "limit-length":
            payload = b"x" * 65536
        elif mode in ("oversize-length", "oversize-chunked"):
            payload = b"x" * 65537
        elif mode == "escaped-output":
            payload = b"\x01" * 65536
        else:
            payload = b'{"message":"origin response"}'
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if mode == "redirect":
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/attacker")
        if mode == "oversize-chunked":
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            if mode == "oversize-chunked":
                for start in range(0, len(payload), 4096):
                    chunk = payload[start:start + 4096]
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            else:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
publish("observed.json", [])
publish("ready.json", {"port": server.server_port})
server.serve_forever()

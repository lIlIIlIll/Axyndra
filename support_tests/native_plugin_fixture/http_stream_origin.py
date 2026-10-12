#!/usr/bin/env python3
"""Local real HTTP stream fixture; never used by a production plugin."""
import http.server
import json
from pathlib import Path
import socket
import sys
import time

root = Path(sys.argv[1])
secret = b"stream-secret-481d"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.exchange()

    def do_POST(self):
        self.exchange()

    def exchange(self):
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 <= size <= 65536:
            self.send_error(413)
            return
        body = self.rfile.read(size)
        (root / "observed.json").write_text(json.dumps({
            "path": self.path, "body_hex": body.hex(),
            "header_ok": self.headers.get("Authorization") == secret.decode(),
            "empty_header_present": self.headers.get("X-Empty") == "",
        }))
        mode = self.path.split("?", 1)[0].rsplit("/", 1)[-1]
        if mode == "hold":
            self.wait_closed()
            return
        self.send_response(200)
        self.send_header("Set-Cookie", secret.decode())
        self.send_header("Content-Type", "text/event-stream" if mode == "sse" else "application/octet-stream")
        if mode == "truncated":
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"5\r\nabc")
            self.wfile.flush()
            self.close_connection = True
            return
        if mode == "sse":
            self.end_headers()
            self.wfile.write(b'data: {"ok":true}\n\n')
            self.wfile.flush()
            self.wait_closed()
            return
        payload = {
            "raw": b"prefix/" + secret,
            "escaped": b'"' + b"".join(("\\u%04x" % b).encode() for b in secret) + b'"',
        }.get(mode, bytes([0, 1, 254, 255]))
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            for offset in range(0, len(payload), 3):
                self.wfile.write(payload[offset:offset + 3])
                self.wfile.flush()
                time.sleep(0.002)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def wait_closed(self):
        self.connection.settimeout(15)
        try:
            while self.connection.recv(1):
                pass
            (root / "closed").write_text("peer EOF")
        except (BrokenPipeError, ConnectionResetError):
            (root / "closed").write_text("peer reset")
        except socket.timeout:
            (root / "timed-out").write_text("fixture timeout")
        self.close_connection = True


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "ready.json").write_text(json.dumps({"port": server.server_port}))
server.serve_forever()

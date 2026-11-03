#!/usr/bin/env python3
"""Controlled real HTTP peer for the actual installed native model codecs.

This is transport fixture data. It cannot create a ModelDecision, Attempt,
grant, Store row or source; the compiled package and canonical Host do that.
"""
import argparse
import copy
import importlib.util
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import select
import socket
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--protocol-fixture", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    spec = importlib.util.spec_from_file_location("actual_native_model_wire_fixture", args.protocol_fixture.resolve())
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    lock = threading.Lock()
    observed = []

    def write_json(name, value):
        temporary = root / (name + ".tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf8")
        temporary.replace(root / name)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            size = int(self.headers.get("Content-Length", "0"))
            assert 0 < size <= 4194304
            body = json.loads(self.rfile.read(size))
            api = {"/v1/chat/completions": "chat", "/v1/responses": "responses", "/v1/messages": "messages"}.get(self.path)
            secret = (root / "secret").read_text(encoding="utf8")
            authorized = self.headers.get("Authorization") == "Bearer " + secret or (
                api == "messages" and self.headers.get("x-api-key") == secret)
            with lock:
                observed.append(dict(path=self.path, model=body.get("model"), authorized=authorized,
                                     streaming=body.get("stream", False)))
                ordinal = len(observed)
                write_json("observed.json", observed)
            if not authorized or api is None:
                self.send_error(403)
                return
            mode = (root / "mode").read_text().strip()
            streaming = body.get("stream", False)
            if mode == "unknown_usage":
                # A real complete response with absent usage is valid. The actual
                # codec must preserve unknown accounting rather than invent 0.
                if streaming:
                    lines = []
                    for line in fixture.stream_response(api).splitlines(keepends=True):
                        if line.startswith(b"data: ") and line.strip() != b"data: [DONE]":
                            value = json.loads(line[6:])
                            value.pop("usage", None)
                            for field in ["message", "response"]:
                                if isinstance(value.get(field), dict):
                                    value[field].pop("usage", None)
                            line = b"data: " + fixture.encoded(value) + b"\n"
                        lines.append(line)
                    output = b"".join(lines)
                else:
                    reply = copy.deepcopy(fixture.response(api))
                    reply.pop("usage", None)
                    output = fixture.encoded(reply)
            else:
                output = fixture.stream_response(api) if streaming else fixture.encoded(fixture.response(api))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream" if streaming else "application/json")
            self.send_header("Content-Length", str(len(output)))
            self.end_headers()
            if mode == "crash":
                # A real socket EOF after a partial response; never synthesize a
                # provider reply or terminal accounting for the actual worker.
                self.wfile.write(output[:max(1, len(output) // 3)])
                self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            if mode == "hang":
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([self.connection], [], [], 0.01)
                    if ready and self.connection.recv(1, socket.MSG_PEEK) == b"":
                        (root / ("closed-" + str(ordinal))).write_text("closed")
                        return
            try:
                for offset in range(0, len(output), 7):
                    self.wfile.write(output[offset:offset + 7])
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                (root / ("closed-" + str(ordinal))).write_text("closed")

    write_json("observed.json", observed)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    write_json("ready.json", dict(port=server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()

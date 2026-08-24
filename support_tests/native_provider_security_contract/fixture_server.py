#!/usr/bin/env python3
import argparse
import json
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        authorization = self.headers.get("authorization", "")
        secret = authorization.removeprefix("Bearer ")
        case = request.get("case", "")
        if case == "echo-error":
            self.respond(
                500,
                json.dumps(
                    {"error": {"message": f"malicious echo {secret}"}},
                    separators=(",", ":"),
                ).encode(),
                "application/json",
            )
            return
        if case == "stream-error":
            self.respond(
                500,
                f'data: {{"error":"malicious echo {secret}"}}\n\n'.encode(),
                "text/event-stream",
            )
            return
        if case == "callback-error":
            self.respond(
                200,
                b'data: {"type":"fixture"}\n\n',
                "text/event-stream",
            )
            return
        if case == "partial-timeout":
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(
                b'data: {"type":"response.output_text.delta","delta":"partial"}\n\n'
            )
            self.wfile.flush()
            time.sleep(2.0)
            return
        if case == "stalled-cancel":
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(
                b'data: {"type":"response.output_text.delta","delta":"active"}\n\n'
            )
            self.wfile.flush()
            time.sleep(5.0)
            return
        if case == "delayed-headers":
            time.sleep(2.0)
            try:
                self.respond(200, b'{"ok":true}', "application/json")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.respond(200, b'{"ok":true}', "application/json")

    def respond(self, status, payload, content_type):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(payload)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if args.tls_cert or args.tls_key:
        if not args.tls_cert or not args.tls_key:
            parser.error("--tls-cert and --tls-key must be used together")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    Path(args.ready_file).write_text(str(server.server_address[1]), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()

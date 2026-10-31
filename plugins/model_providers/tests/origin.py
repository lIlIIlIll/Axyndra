#!/usr/bin/env python3
"""Local real HTTP origin for the installed ModelProvider Product contracts."""
import argparse
import importlib.util
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import select
import socket
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, required=True)
args = parser.parse_args()
root = args.root.resolve()
spec = importlib.util.spec_from_file_location('model_wire_fixture', Path(__file__).resolve().parents[1] / 'check.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
lock = threading.Lock()
observations = []
(root / 'observed.json').write_text('[]')


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    temporary.replace(path)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size < 1 or size > 4194304:
            self.send_error(413)
            return
        raw_body = self.rfile.read(size)
        body = json.loads(raw_body)
        api = {'/v1/chat/completions': 'chat', '/v1/responses': 'responses', '/v1/messages': 'messages'}.get(self.path)
        secret = (root / 'secret').read_text(encoding='utf-8')
        bearer_authorized = self.headers.get('Authorization') == 'Bearer ' + secret
        key_authorized = api == 'messages' and self.headers.get('x-api-key') == secret
        authorized = bearer_authorized or key_authorized
        with lock:
            observations.append({'path': self.path, 'authorized': authorized,
                                 'auth_header_kind': 'x-api-key' if key_authorized else 'authorization' if bearer_authorized else 'none',
                                 'model': body.get('model'),
                                 'streaming': body.get('stream', False), 'request_bytes': len(raw_body),
                                 'request_sha256': hashlib.sha256(raw_body).hexdigest()})
            ordinal = len(observations)
            write_json(root / 'observed.json', observations)
        mode = (root / 'mode').read_text().strip()
        if api is None or not authorized:
            self.send_error(403)
            return
        status = 200
        streaming = body.get('stream', False)
        output = fixture.stream_response(api) if streaming else fixture.encoded(fixture.response(api))
        if mode == 'large':
            large_text = 'installed payload 雪' * 28000
            output = output.replace('answer 雪'.encode(), fixture.encoded(large_text)[1:-1])
        if mode == 'near_semantic_limit':
            assert api == 'messages' and streaming
            output = fixture.large_messages_stream('x' * 8387584)
            assert 8388608 < len(output) <= 8454144
        if mode == 'reflect':
            output = fixture.encoded({'error': secret})
        if mode == 'rate_limit':
            status, output = 429, b'{"error":{"message":"limited"}}'
        self.send_response(status)
        self.send_header('Content-Type', 'text/event-stream' if streaming else 'application/json')
        self.send_header('Content-Length', str(len(output)))
        self.send_header('Retry-After', '2')
        self.end_headers()
        if mode == 'hold_after_delta':
            # Send one complete content SSE event, then wait for the actual
            # Product TextDelta observer to mutate the installed package.
            assert api == 'chat' and streaming
            content = output.index(b'answer')
            boundary = output.index(b'\n\n', content) + 2
            self.wfile.write(output[:boundary])
            self.wfile.flush()
            output = output[boundary:]
            (root / 'prefix-sent').write_text('sent')
        if mode in ('hang', 'hold_after_delta'):
            until = time.monotonic() + 15
            while time.monotonic() < until and not (root / 'release').exists():
                ready, _, _ = select.select([self.connection], [], [], 0.02)
                if ready and self.connection.recv(1, socket.MSG_PEEK) == b'':
                    (root / f'closed-{ordinal}').write_text('closed')
                    return
        try:
            step = 8192 if mode in ('large', 'near_semantic_limit') else 7
            for offset in range(0, len(output), step):
                self.wfile.write(output[offset:offset + step])
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            (root / f'closed-{ordinal}').write_text('closed')
        if mode == 'hold_after_delta':
            until = time.monotonic() + 5
            while time.monotonic() < until:
                ready, _, _ = select.select([self.connection], [], [], 0.02)
                if ready and self.connection.recv(1, socket.MSG_PEEK) == b'':
                    (root / f'closed-{ordinal}').write_text('closed')
                    return


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
write_json(root / 'ready.json', {'port': server.server_port})
server.serve_forever()

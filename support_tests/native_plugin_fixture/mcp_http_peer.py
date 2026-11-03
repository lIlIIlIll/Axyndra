#!/usr/bin/env python3
"""Actual local MCP 2026-07-28 HTTP/SSE peer for Product integration.

It is only an origin, never a broker/transport substitute. Product must create
its real Mediated exchange and inject the operator credential. Evidence stores
an authentication boolean, raw nonsecret request bytes, and actual socket close.
"""
import argparse
import http.server
import json
from pathlib import Path
import socket
import threading


class Origin(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, root):
        self.root = root
        self.secret = (root / 'credential').read_text(encoding='utf-8')
        self.prefix = (root / 'header-prefix').read_text(encoding='utf-8') if (root / 'header-prefix').exists() else ''
        self.require_public = (root / 'require-public-headers').exists()
        self.lock = threading.Lock()
        self.rows = []
        self.errors = []
        self.revision = 0
        super().__init__(('127.0.0.1', 0), Handler)
        self.persist()

    def handle_error(self, request, client_address):
        with self.lock:
            self.errors.append('origin_handler_failed')

    def persist(self):
        # Caller holds lock after startup. Readers always see a full document.
        pending = self.root / 'observed.tmp'
        pending.write_text(json.dumps(self.rows, ensure_ascii=False), encoding='utf-8')
        pending.replace(self.root / 'observed.json')

    def observed(self, request, body, path, headers):
        with self.lock:
            row = {'method': request['method'], 'body_hex': body.hex(), 'path': path,
                   'authorized': headers.get('Authorization') == self.prefix + self.secret,
                   'origin': headers.get('Origin', ''), 'deployment': headers.get('X-Deployment', ''),
                   'mcp_method': headers.get('Mcp-Method'),
                   'protocol': headers.get('Mcp-Protocol-Version'),
                   'accept': headers.get('Accept'), 'response_bytes': 0,
                   'closed': False, 'eof_sent': False}
            self.rows.append(row)
            self.persist()
            return row

    def update(self, row, **values):
        with self.lock:
            row.update(values)
            self.persist()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass

    def do_POST(self):
        row = None
        try:
            size = int(self.headers.get('Content-Length', '-1'))
            request_limit = 4128768 if (self.server.root / "mode").read_text(encoding="utf-8").startswith("payload") else 30720
            if not 0 <= size <= request_limit:
                self.send_error(413)
                return
            body = self.rfile.read(size)
            request = json.loads(body)
            row = self.server.observed(request, body, self.path, self.headers)
            if (not row['authorized'] or (self.server.require_public and
                    (row['origin'] != 'https://client.example.test' or row['deployment'] != 'operator-public'))
                    or row['mcp_method'] != request['method']
                    or row['protocol'] != '2026-07-28'):
                self.send_error(401)
                return
            mode = (self.server.root / 'mode').read_text(encoding='utf-8')
            method = request['method']
            if method == 'server/discover':
                if mode == 'startup-hang':
                    self.wait_closed(row)
                    return
                result = {'resultType': 'complete', 'supportedVersions': ['2026-07-28'],
                          'capabilities': {'tools': {}}, 'ttlMs': 0, 'cacheScope': 'private'}
            elif method == 'tools/list':
                cursor = request.get('params', {}).get('cursor', '')
                if not cursor:
                    self.server.revision += 1
                revision = self.server.revision
                remote = 'remote.updated:雪' if mode == 'refresh-change' and revision > 1 else 'remote.echo:雪'
                names = [remote, 'remote.extra-a'] if not cursor else ['remote.extra-b', 'remote.extra-c']
                # Each page < 8 KiB, aggregate startup responses > 8 KiB.
                # The plugin preserves these descriptions in its real catalog.
                result = {'resultType': 'complete', 'ttlMs': 0, 'cacheScope': 'private',
                          'tools': [{'name': name, 'description': 'd' * 3000,
                                     'inputSchema': {'type': 'object'}} for name in names]}
                if mode == 'annotation':
                    for tool in result['tools']:
                        tool['annotations'] = {'readOnlyHint': True}
                if not cursor:
                    result['nextCursor'] = 'second-page'
                elif cursor != 'second-page':
                    raise ValueError('unexpected bounded directory cursor')
            elif method == 'tools/call':
                if mode == 'hang':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.end_headers()
                    self.wait_closed(row)
                    return
                if mode == 'disconnect':
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                content = body.decode('utf-8')
                if mode.startswith('payload'):
                    arguments = request['params']['arguments']
                    requested = arguments.get('size', 0)
                    if not isinstance(requested, int) or not 0 <= requested <= 3145728:
                        raise ValueError('invalid payload fixture bound')
                    content = arguments.get('input', 'x' * requested)
                if mode == 'reflect':
                    content = self.server.secret
                if mode == 'reflect-prefixed':
                    content = self.server.prefix + self.server.secret
                result = {'resultType': 'complete', 'content': [{'type': 'text', 'text': content}]}
            else:
                raise ValueError('unexpected MCP method')
            if method == 'tools/call' and mode == 'payload-dense':
                result['content'] = [{'type': 'text', 'text': 'observed before dense decode'}]
                result['structuredContent'] = [0 for _ in range(65536)]
            encoded = json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result},
                                 ensure_ascii=False, separators=(',', ':')).encode()
            sse = self.headers.get('Accept', '').startswith('text/event-stream')
            payload = b'data: ' + encoded + b'\n\n' if sse else encoded
            if sse and mode in ('payload-dense', 'payload-mixed'):
                # An unmatched metadata quote cannot hide subsequent JSON nodes.
                payload = b': "\nid: event-one\nevent: message\n' + payload
            self.server.update(row, response_bytes=len(payload))
            self.send_response(200)
            content_type = 'Text/Event-Stream' if mode in ('payload-dense', 'payload-mixed') else 'text/event-stream'
            self.send_header('Content-Type', content_type if sse else 'application/json')
            self.send_header('Set-Cookie', self.server.secret)
            if not sse:
                self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            if sse:
                self.wait_closed(row)
            else:
                self.server.update(row, eof_sent=True)
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            pass
        finally:
            self.close_connection = True
            if row is not None:
                self.server.update(row, closed=True)

    def wait_closed(self, row):
        # Client cleanup, not the fixture, must break a hanging/SSE exchange.
        self.connection.settimeout(15)
        try:
            while self.connection.recv(1):
                pass
        except (OSError, ConnectionError):
            pass
        self.server.update(row, closed=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    origin = Origin(args.root.resolve(strict=True))
    (args.root / 'ready.json').write_text(json.dumps({'port': origin.server_port}), encoding='utf-8')
    try:
        origin.serve_forever()
    finally:
        origin.server_close()


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Actual OS probe. Host controls the listener; the granted backend owns MCP."""
import json
import os
import socket
import sys
from pathlib import Path


def origin(root):
    root = Path(root)
    def publish(name, value):
        temporary = root / (name + '.new')
        temporary.write_text(str(value))
        temporary.replace(root / name)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(8)
        listener.settimeout(.2)
        publish('connections', 0)
        publish('port', listener.getsockname()[1])
        count = 0
        while not (root / 'stop').exists():
            try:
                connection, _ = listener.accept()
            except TimeoutError:
                continue
            with connection:
                count += 1
                publish('connections', count)


def peer(record, port):
    record = Path(record)
    for physical in sys.stdin.buffer:
        with record.open('ab') as output:
            output.write(physical)
        request = json.loads(physical)
        method = request['method']
        if method == 'server/discover':
            result = {'resultType': 'complete', 'supportedVersions': ['2026-07-28'],
                      'capabilities': {'tools': {}}, 'ttlMs': 0, 'cacheScope': 'private'}
        elif method == 'tools/list':
            result = {'resultType': 'complete', 'tools': [{'name': 'remote.echo:雪',
                      'description': 'Real backend OS network probe', 'inputSchema': {'type': 'object'}}],
                      'ttlMs': 0, 'cacheScope': 'private'}
        elif method == 'tools/call':
            connected = False
            try:
                with socket.create_connection(('127.0.0.1', int(port)), timeout=.5):
                    connected = True
            except OSError:
                pass
            # Check fixed CA wiring without exposing paths/content or attempting
            # to mutate the operator's real bundle. The filesystem mount is
            # separately exercised by the raw factory's immutable mount tests.
            cert = os.environ.get('SSL_CERT_FILE', '')
            fixed_ca = bool(cert and cert == os.environ.get('CURL_CA_BUNDLE') and Path(cert).is_file())
            result = {'resultType': 'complete', 'content': [{'type': 'text', 'text':
                      json.dumps({'connected': connected, 'fixed_ca': fixed_ca,
                                  'ambient_absent': 'AXYNDRA_HOST_NETWORK_UNGRANTED' not in os.environ})}]}
        else:
            raise AssertionError('unexpected MCP method')
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result},
                         ensure_ascii=False, separators=(',', ':')), flush=True)


if __name__ == '__main__':
    if sys.argv[1] == 'origin':
        origin(sys.argv[2])
    elif sys.argv[1] == 'peer':
        peer(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit('unknown fixture mode')

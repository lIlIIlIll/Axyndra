#!/usr/bin/env python3
"""Run the public web contract against local curl/config/cancellation fixtures."""
import argparse
import http.server
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import threading
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument('--candidate', required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='axyndra-web-fixture-') as directory:
    observed = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_POST(self):
            self.do_GET()
        def do_GET(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            observed.append((self.path, self.headers.get('X-Subscription-Token'), body.decode()))
            if self.path.startswith('/slow/'):
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['q'][0]
                Path(directory, query).touch()
                # End this fixture when the real cancelled curl closes its socket.
                if select.select([self.connection], [], [], 35)[0]:
                    return
            payload = b'{"results":[],"web":{"results":[]},"answer":"local fixture"}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except BrokenPipeError:
                pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        env = dict(os.environ, AXYNDRA_WEB_FIXTURE_URL=f'http://127.0.0.1:{server.server_port}',
                   AXYNDRA_WEB_FIXTURE_ROOT=directory)
        result = subprocess.run([str(Path(args.candidate).resolve())], env=env, timeout=70)
        assert result.returncode == 0, result.returncode
        assert not any(path.startswith('/attacker') for path, _, _ in observed), observed
        assert any(path.startswith('/brave') and token == 'FAKE-LOCAL-BRAVE' for path, token, _ in observed), observed
        assert any(path.startswith('/tavily') and 'FAKE-LOCAL-TAVILY' in body for path, _, body in observed), observed
        assert sum(not path.startswith('/slow') for path, _, _ in observed) == 3, observed
        assert sum(path.startswith('/slow') for path, _, _ in observed) == 3, observed
        print('PASS T1/T9 local curl isolation, actual concurrent cancellation, early cancellation')
    finally:
        server.shutdown()
        server.server_close()

#!/usr/bin/env python3
"""Real MCP stdio peer for Product tests; no host/database access or fake receipts."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

mode, record = sys.argv[1], Path(sys.argv[2])
if mode not in {'cwd', 'annotation', 'echo', 'empty', 'eof', 'hang', 'startup-hang', 'refresh-change', 'refresh-empty', 'refresh-malformed', 'refresh-hang', 'shutdown-eof', 'shutdown-stubborn', 'shutdown-startup-hang'}:
    raise SystemExit('unknown MCP Product fixture mode')

shutdown = mode.startswith('shutdown-')
child = None

def shutdown_event(kind):
    with (record.parent / 'shutdown.jsonl').open('a', encoding='utf-8') as log:
        log.write(json.dumps({'event': kind, 'pid': os.getpid(), 'time': time.monotonic(),
                              'child': child.pid if child else None}) + '\n')

if shutdown:
    if mode == 'shutdown-stubborn':
        child = subprocess.Popen([sys.executable, '-c',
            'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(300)'])
    shutdown_event('started')

directories = 0
for line in sys.stdin.buffer:
    with record.open('ab') as log:
        log.write(line)
    request = json.loads(line)
    if 'id' not in request:
        raise AssertionError('Product tests authorize no extra MCP notification writes')
    if request['method'] == 'server/discover':
        if mode in {'startup-hang', 'shutdown-startup-hang'}:
            time.sleep(30)
            sys.exit(9)
        result = {'resultType': 'complete', 'supportedVersions': ['2026-07-28'],
                  'capabilities': {'tools': {}}, 'ttlMs': 0, 'cacheScope': 'private'}
    elif request['method'] == 'tools/list':
        directories += 1
        tools = [] if mode == 'empty' else [{'name': 'remote.echo:雪', 'description': 'Real Product MCP peer',
                                            'inputSchema': {'type': 'object'}}]
        if mode == 'annotation':
            tools[0]['annotations'] = {'readOnlyHint': True}
        result = {'resultType': 'complete', 'tools': tools, 'ttlMs': 0, 'cacheScope': 'private'}
        if mode.startswith('refresh-') and directories > 1:
            if mode == 'refresh-empty':
                result['tools'] = []
            elif mode == 'refresh-malformed':
                result['tools'][0]['inputSchema'] = 'invalid schema'
            elif mode == 'refresh-hang':
                time.sleep(30)
                raise SystemExit(9)
            else:
                result['tools'][0]['name'] = 'remote.updated:雪'
    elif request['method'] == 'tools/call':
        if mode == 'eof':
            # The test releases EOF only after observing the real host child
            # Receipt. This is a fixture event, never an injected receipt.
            release = record.parent / 'release-eof'
            deadline = time.monotonic() + 20
            while not release.exists() and time.monotonic() < deadline:
                time.sleep(.005)
            raise SystemExit(0 if release.exists() else 8)
        if mode == 'hang':
            time.sleep(30)
            raise SystemExit(9)
        result = {'resultType': 'complete', 'content': [{'type': 'text', 'text': line.decode()[:-1]}]}
        if mode == 'cwd':
            result['content'][0]['text'] = json.dumps({'cwd': str(Path.cwd()),
                'relative_data': Path('cwd-data.txt').read_text(encoding='utf-8')}, ensure_ascii=False)
    else:
        raise AssertionError('unexpected MCP request method')
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result},
                     ensure_ascii=False, separators=(',', ':')), flush=True)

if shutdown:
    shutdown_event('stdin-eof')
    if child:
        child.wait()
    else:
        time.sleep(.25)
    shutdown_event('exited')

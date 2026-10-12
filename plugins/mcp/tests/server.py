#!/usr/bin/env python3
"""A real stdio MCP 2026-07-28 peer. It records every physical input frame."""
import json
import sys
import time
from pathlib import Path

mode, record = sys.argv[1], Path(sys.argv[2])

def send(value):
    print(json.dumps(value, ensure_ascii=False, separators=(',', ':')), flush=True)

directories = 0
for line in sys.stdin.buffer:
    with record.open('ab') as target:
        target.write(line)
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request['method']
    if method == 'server/discover':
        result = {'resultType': 'complete', 'supportedVersions': ['2026-07-28'],
                  'capabilities': {'tools': {}}, 'ttlMs': 0, 'cacheScope': 'private'}
    elif method == 'tools/list':
        directories += 1
        tools = [] if mode == 'empty' else [{
            'name': 'remote.echo:雪', 'description': 'Echo exact received bytes',
            'inputSchema': {'type': 'object'},
        }]
        if mode == 'required-task':
            tools[0]['execution'] = {'taskSupport': 'required'}
        result = {'resultType': 'complete', 'tools': tools, 'ttlMs': 0, 'cacheScope': 'private'}
        if mode == 'cursor-loop':
            result['nextCursor'] = 'same-cursor'
            if request.get('params', {}).get('cursor'):
                result['tools'] = []
        if mode in ('two-pages', 'ttl-change', 'scope-change'):
            cursor = request.get('params', {}).get('cursor', '')
            assert cursor in ('', 'page-two'), cursor
            result['ttlMs'] = 60000
            if not cursor:
                result['nextCursor'] = 'page-two'
            else:
                result['tools'][0]['name'] = 'remote.second:雪'
                if mode == 'ttl-change':
                    result['ttlMs'] = 60001
                if mode == 'scope-change':
                    result['cacheScope'] = 'public'
        if mode.startswith('refresh-') and directories > 1:
            if mode == 'refresh-empty':
                result['tools'] = []
            elif mode == 'refresh-malformed':
                result['tools'][0]['inputSchema'] = 'invalid schema'
            else:
                result['tools'][0]['name'] = 'remote.updated:雪'
    elif method == 'tools/call':
        if mode == 'eof':
            sys.exit(0)
        if mode == 'hang':
            time.sleep(30)
            sys.exit(0)
        if mode == 'input':
            result = {'resultType': 'input_required', 'requestState': 'needs-a-new-user-decision'}
        elif mode == 'large':
            result = {'resultType': 'complete', 'content': [{'type': 'text', 'text': 'x' * 48000}]}
        elif mode == 'oversize':
            result = {'resultType': 'complete', 'content': [{'type': 'text', 'text': 'x' * 70000}]}
        else:
            # The exact received request includes request ID, metadata, argument
            # escaping and final newline. No test-side request reserialization.
            result = {'resultType': 'complete', 'content': [{'type': 'text', 'text': line.decode()[:-1]}]}
            if mode == 'business-error':
                result['isError'] = True
        send({'jsonrpc': '2.0', 'method': 'notifications/progress', 'params': {'progress': 1}})
    else:
        raise AssertionError(f'unexpected MCP method {method}')
    send({'jsonrpc': '2.0', 'id': request['id'], 'result': result})

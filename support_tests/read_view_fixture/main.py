#!/usr/bin/python3
"""Adversarial native protocol fixture; no business implementation lives in host."""
import json
import os
from pathlib import Path
import sys

KEYS = ['protocol', 'extension_id', 'extension_version', 'generation', 'id', 'tool', 'kind',
        'command_id', 'thread_id', 'run_id', 'epoch', 'operation_id', 'call_id']
def send(value):
    sys.stdout.write(json.dumps(value, separators=(',', ':')) + '\n'); sys.stdout.flush()
def envelope(frame, kind):
    return {**{k: frame[k] for k in KEYS if k in frame}, 'type': kind}
def result(frame, value, ok=True):
    send({**envelope(frame, 'result'), 'ok': ok, 'result': value})

if len(sys.argv) > 1 and sys.argv[1] == '--probe':
    authored = json.loads(sys.argv[2])
    def content(path):
        try:
            return Path(path).read_text()
        except (FileNotFoundError, PermissionError, IsADirectoryError):
            return None
    send({'visible': content('public.txt'), 'relative_secret': content('.env'),
          'absolute_secret': content(authored['secret']), 'outside': content(authored['outside']),
          'proc_root_outside': content('/proc/1/root' + authored['outside']),
          'environment_secret': os.environ.get('READ_VIEW_AMBIENT_SECRET'),
          'symlink': content('escape.txt')})
    raise SystemExit(0)

pending = None
for line in sys.stdin.buffer:
    frame = json.loads(line)
    kind = frame.get('type')
    if kind == 'hello':
        send({**envelope(frame, 'ready'), 'capabilities': frame['capabilities'],
              'tools': [{'name': 'read', 'description': 'Adversarial resource-view fixture',
                         'input_schema': {'type': 'object'}}], 'commands': [], 'hooks': []})
    elif kind == 'invoke' and frame['kind'] == 'prepare':
        value = frame['arguments']['input']
        result(frame, {'intents': [{'id': 'view', 'request': {'executable': 'plugin.py',
                 'arguments': ['--probe', json.dumps(value, separators=(',', ':'))], 'timeout_ms': 3000},
                 'resources': [{'source': '.', 'path': '.', 'mode': 'directory'}]}]})
    elif kind == 'invoke':
        pending = frame
        mode = frame['arguments'].get('service', 'process.readview')
        if mode == 'process.readview':
            arguments = {'intent_id': 'view'}
        elif mode == 'file.plan.propose':
            arguments = {'proposal': {'schema': 'axyndra.file-change-proposal/v1', 'operations': [
                {'kind': 'create', 'path': 'forbidden.txt', 'content': 'never'}]}}
        else:
            arguments = {'executable': 'plugin.py', 'arguments': ['--probe', json.dumps(frame['arguments'])], 'timeout_ms': 3000}
        send({**envelope(frame, 'service_request'), 'request_id': 'view', 'service': mode, 'arguments': arguments})
    elif kind == 'service_response':
        if pending is None or any(frame.get(k) != pending.get(k) for k in KEYS):
            raise SystemExit(3)
        if frame.get('ok'):
            output = frame['result']['output']
            result(pending, json.loads(output['stdout']), not frame['result'].get('is_error', False))
        else:
            result(pending, frame['error'], False)
        pending = None
    elif kind == 'cancel':
        send(envelope(frame, 'cancelled')); pending = None
    elif kind in ['shutdown', 'close']:
        break
    else:
        raise SystemExit(3)

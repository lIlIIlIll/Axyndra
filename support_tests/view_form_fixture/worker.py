#!/usr/bin/env python3
import hashlib
import json
import sys

IDENTITY = ('protocol', 'extension_id', 'extension_version', 'generation', 'id', 'tool', 'kind',
            'command_id', 'thread_id', 'run_id', 'epoch', 'operation_id', 'call_id')

def send(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n')
    sys.stdout.flush()

hello = json.loads(sys.stdin.readline())
ready = {key: hello[key] for key in ('protocol', 'extension_id', 'extension_version', 'generation')}
ready.update(type='ready', capabilities=[], tools=[], hooks=[],
    commands=[dict(name='submit', description='Compute a checksum of actual declared form inputs')],
    views=[dict(name='overview', description='No-Tool View with actual generic user input')])
if 'content_payload_limits' in hello:
    ready['content_payload_limits'] = hello['content_payload_limits']
send(ready)
for line in sys.stdin:
    frame = json.loads(line)
    if frame['type'] in ('close', 'shutdown'):
        break
    assert frame['type'] == 'invoke'
    assert frame['run_id'] == '' and frame['operation_id'] == ''
    if frame['kind'] == 'view':
        assert frame['call_id']
    else:
        assert frame['call_id'] == ''
    reply = {key: frame[key] for key in IDENTITY}
    reply.update(type='result', ok=True)
    if 'payload_window' in frame:
        reply['payload_window'] = frame['payload_window']
    if frame['kind'] == 'view' and frame['tool'] == 'overview':
        query = frame['arguments']
        assert set(query) == {'schema', 'context', 'input'}
        assert query['schema'] == 'axyndra.view-query/v1'
        reply['result'] = dict(schema='axyndra.view/v1', title='Independent no-Tool form',
            summary='Actual Native View and Command. Tab selects nodes; inputs are not permission grants.',
            status='input_required', interaction='required',
            nodes=[dict(id='text', kind='text', text='Native text 雪'),
                   dict(id='status', kind='status', status='ready', text='Plugin status is not Host status'),
                   dict(id='code', kind='code', language='text', text='code example'),
                   dict(id='diff', kind='diff', text='- old\n+ new'),
                   dict(id='result', kind='tool_result', status='unknown', text='Display data never settles a Tool'),
                   dict(id='list', kind='list', items=[dict(id='a', text='first choice'), dict(id='b', text='second choice')], selected_id='b'),
                   dict(id='table', kind='table', columns=['Key', 'Value'], rows=[dict(id='r', cells=['actual', 'row'])]),
                   dict(id='input', kind='input', label='Actual user input', text='editable text', multiline=True)],
            actions=[dict(id='submit', label='Submit actual form', command='submit', input={})])
    elif frame['kind'] == 'command' and frame['tool'] == 'submit':
        envelope = json.loads(frame['arguments']['command_args'])
        assert envelope['schema'] == 'axyndra.view-command/v1'
        assert envelope['view']['id'] and envelope['view']['revision'] == '1'
        assert envelope['event']['kind'] == 'action' and envelope['event']['action_id'] == 'submit'
        fields = envelope['event']['fields']
        assert set(fields) == {'list', 'table', 'input'}
        assert fields['list'] in ('', 'a', 'b') and fields['table'] in ('', 'r')
        assert not envelope['event']['field_refs']
        digest = hashlib.sha256(json.dumps(fields, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        reply['result'] = dict(schema='axyndra.command-message/v1', text='Native form checksum: ' + digest)
    else:
        raise SystemExit(3)
    send(reply)

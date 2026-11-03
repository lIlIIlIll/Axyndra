"""Test-only neutral intern/copy transport; all summary decisions run natively."""
import json


class ReferencePeer:
    def __init__(self, peer, *, batch=False):
        self.peer = peer
        self.values, self.index = [], {}
        self.sequence = 0
        self.batch = batch

    def query(self, phase, **fields):
        self.sequence += 1
        response = self.peer.invoke(dict(schema='axyndra.compaction-policy/v1', phase=phase,
                                        snapshot_digest='immutable-test-source', **fields))
        assert response['ok'], response
        return response['result']['value']

    def intern(self, value):
        raw = value.encode()
        if value not in self.index:
            self.index[value] = len(self.values)
            self.values.append(raw)
        return dict(query='query-local-test', ref=self.index[value], bytes=len(raw),
                    inline=value if len(raw) <= 2048 else None)

    def value(self, ref):
        assert set(ref) == {'query', 'ref', 'bytes', 'inline'}
        assert ref['query'] == 'query-local-test'
        value = self.values[ref['ref']]
        assert len(value) == ref['bytes']
        assert ref['inline'] == (value.decode() if len(value) <= 2048 else None)
        return value

    def compose(self, parts, maximum=8388608):
        out = bytearray()
        for part in parts:
            if set(part) == {'literal'}:
                selected = part['literal'].encode()
                assert len(selected) <= 65536
            else:
                assert set(part) == {'source', 'offset', 'bytes'}
                raw = self.value(part['source'])
                start, size = part['offset'], part['bytes']
                assert 0 <= start <= len(raw) and 0 <= size <= len(raw) - start
                selected = raw[start:start+size]
                selected.decode()
            assert len(selected) <= maximum-len(out)
            out.extend(selected)
        return out.decode()

    def reduce(self, task):
        source = task['source']
        raw, offset, carry, paths = self.value(source), 0, None, []
        while True:
            end = min(len(raw), offset+262144)
            while end < len(raw) and raw[end] & 0xC0 == 0x80:
                end -= 1
            fields = dict(source=source, sequence=self.sequence+1, offset=offset,
                          total=len(raw), text=raw[offset:end].decode(), carry=carry)
            if task['mode'] != 'hashlines':
                fields.update(mode=task['mode'], limit=task['limit'])
            phase = {'hashlines':'hashline_fragment', 'overview':'overview_fragment'}.get(task['mode'], 'text_fragment')
            response = self.query(phase, **fields)
            assert response['source'] == source and response['sequence'] == fields['sequence']
            assert offset <= response['next_offset'] <= end
            assert response['next_offset'] > offset or len(raw) == 0
            if task['mode'] == 'hashlines':
                refs = []
                for span in response['ranges']:
                    start, size = span['offset'], span['bytes']
                    assert 0 <= start <= response['next_offset'] and 0 <= size <= response['next_offset']-start
                    refs.append(self.intern(raw[start:start+size].decode()))
                paths = self.query('reference_paths', paths=paths, values=refs)
                if response['complete'] or len(paths) == 24:
                    return paths
            elif response['complete']:
                return dict(result=response['result'], prior=response['prior'])
            offset, carry = response['next_offset'], response['carry']

    def event(self, state, event):
        if self.batch:
            response = self.query('reference_event', state=state, event=event)
            if response['kind'] == 'reduce':
                assert set(response) == {'kind', 'tasks', 'reduced'}
                reduced = dict(response['reduced'])
                for task in response['tasks']:
                    assert task['key'] not in reduced
                    reduced[task['key']] = self.reduce(task)
                response = self.query('reference_event_fold', state=state, event=event, reduced=reduced)
            if response['kind'] == 'state':
                assert set(response) == {'kind', 'state'}
                return response['state']
            assert response['kind'] == 'commands' and set(response) == {'kind', 'commands'}
            resolved = [dict(target=item['target'], value=self.intern(self.compose(item['recipe'])))
                        for item in response['commands']]
            return self.query('reference_merge', state=state, event=event, commands=resolved)
        tasks = self.query('reference_plan', state=state, event=event)['tasks']
        reduced = {task['key']:self.reduce(task) for task in tasks}
        commands = self.query('reference_fold', state=state, event=event, reduced=reduced)['commands']
        resolved = [dict(target=entry['target'], value=self.intern(self.compose(entry['recipe']))) for entry in commands]
        return self.query('reference_merge', state=state, event=event, commands=resolved)

    def summary(self, messages, goal=None, todos=()):
        layout = self.query('reference_layout')
        state = layout['state']
        for message in messages:
            state = self.event(state, dict(kind='message', role=message['role']))
            for block in message['blocks']:
                args = {}
                for selector in layout['arguments']:
                    value = block['arguments'].get(selector['field'])
                    if selector['kind'] == 'text':
                        value = value if isinstance(value, str) else ''
                    else:
                        value = json.dumps(value, separators=(',', ':')) if isinstance(value, (int, float)) and not isinstance(value, bool) else ''
                    args[selector['field']] = self.intern(value)
                state = self.event(state, dict(kind=block['kind'], role=message['role'], name=self.intern(block['name']),
                                              text=self.intern(block['text']), is_error=block['is_error'], arguments=args))
        if goal is not None:
            state = self.event(state, dict(kind='goal', objective=self.intern(goal['objective']), status=self.intern(goal['status'])))
        for phase in todos:
            for task in phase['tasks']:
                state = self.event(state, dict(kind='todo', name=self.intern(phase['name']), content=self.intern(task['content']),
                                              status=task['status'], blocker=self.intern(task['blocker'])))
        return self.compose(self.query('reference_finish', state=state)['recipe'])

    def overview(self, blocks, tokens, accepted=True, stop='end_turn'):
        state = self.query('overview_begin', max_output_tokens=tokens, accepted_output=accepted, stop_reason=stop)
        for block in blocks:
            plan = self.query('overview_plan', state=state, kind=block['kind'], max_output_tokens=tokens)
            value = self.reduce(dict(source=self.intern(block['text']), mode='overview', limit=max(64,tokens*4)))['result'] if plan['read'] else ''
            state = self.query('overview_merge', state=state, kind=block['kind'], reduced=value, max_output_tokens=tokens)
        return self.query('overview_finish', state=state, max_output_tokens=tokens)['overview']

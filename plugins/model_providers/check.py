#!/usr/bin/env python3
"""Run the packaged three real adapters against a controlled host wire peer.

This exercises actual adapter codecs in the executable, not Product authority,
SQLite, credential injection or public provider availability.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import unittest

SCHEMA = 'axyndra.model-provider/v1'
BINARY = None
PAYLOAD = {'version': 1, 'max_message_bytes': 16777216, 'max_input_bytes': 4194304,
           'max_prepare_bytes': 8388608, 'max_result_bytes': 8388608, 'max_write_bytes': 3932160}
LOGICAL_SCHEMA = 'axyndra.logical-json/v1'

def reframed(value):
    value['identity']['binding_digest'] = sha(value['binding'])
    value['identity']['input_digest'] = sha(value['request'])
    return value


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


def canonical(value):
    def framed(text):
        return f'{len(text.encode())}:{text}'
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        return 'n' + framed(str(value))
    if isinstance(value, str):
        return 's' + framed(value)
    if isinstance(value, list):
        return '[' + ''.join(framed(canonical(v)) for v in value) + ']'
    return '{' + ''.join(framed(k) + framed(canonical(value[k])) for k in sorted(value)) + '}'


def sha(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def fixture(api='chat', streaming=False):
    contribution, dialect, provider = {
        'chat': ('openai-chat-completions', 'openai_chat', 'openai'),
        'responses': ('openai-responses', 'openai_responses', 'openai'),
        'messages': ('anthropic-messages', 'anthropic_messages', 'anthropic'),
    }[api]
    cap = ('snapshot_schema_version=1\nmodel_id=7:fixture\nthinking_mode=none\n'
           'supported_levels=\nbudget_tiers=\nmodel_max_output_tokens=2048\nendpoint_max_output_tokens=-\n')
    binding = {'plugin': 'native:model-providers', 'package_digest': 'sha256:' + 'a' * 64,
               'configuration_digest': 'b' * 64, 'instance_identity': 'fixed-mounted-instance',
               'contribution': contribution, 'provider_id': 'profile', 'model': 'fixture', 'wire_model': 'wire-model',
               'capabilities': cap, 'context_window': 8192, 'execution_capabilities': {'schema_version': 1, 'model': 'fixture', 'mode': 'none',
                   'levels': [], 'tiers': [], 'max_output': 2048, 'endpoint_max_output': None,
                   'fingerprint': hashlib.sha256(cap.encode()).hexdigest()},
               'images': False, 'tools': True, 'structured_output': False, 'parallel_tools': True, 'prompt_cache': False,
               'configuration': {'base_url': 'https://provider.invalid', 'provider': provider, 'dialect': dialect,
                                 'headers': {'x-example': 'nonsecret'}, 'timeout_ms': 10000, 'allow_insecure_http': False},
               'credential_refs': ['provider-key']}
    block = {'kind': 'text', 'text': 'hello 雪', 'call_id': '', 'name': '', 'arguments': {},
             'is_error': False, 'receipt_id': '', 'image': None, 'opaque_state': None}
    request = {'model': 'fixture', 'system': '', 'messages': [{'role': 'user', 'blocks': [block]}],
               'tools': [], 'thinking': 'off', 'wire_max_output_tokens': 1024, 'streaming': streaming,
               'parallel_tool_calls': False, 'service_tier': '', 'cache_policy': 'default', 'cache_key': '',
               'tool_choice': 'auto', 'structured_output': None, 'resolved_policy': None}
    identity = {'attempt_id': 'attempt-real-host-fixture', 'run_id': 'run-1', 'thread_id': 'thread-1', 'epoch': 1,
                'request_id': 'model-request-1', 'binding_digest': sha(binding), 'input_digest': sha(request)}
    return {'schema': SCHEMA, 'type': 'execute', 'identity': identity, 'binding': binding, 'request': request,
            'transport_hard_timeout_ms': 10000}


def response(api):
    if api == 'chat':
        return {'id': 'response-1', 'object': 'chat.completion', 'model': 'wire-model',
                'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'answer 雪'}, 'finish_reason': 'stop'}],
                'usage': {'prompt_tokens': 11, 'completion_tokens': 3, 'total_tokens': 14}}
    if api == 'responses':
        return {'id': 'response-1', 'object': 'response', 'status': 'completed', 'model': 'wire-model',
                'output': [{'type': 'message', 'id': 'message-1', 'role': 'assistant', 'status': 'completed',
                            'content': [{'type': 'output_text', 'text': 'answer 雪', 'annotations': []}]}],
                'usage': {'input_tokens': 11, 'output_tokens': 3, 'total_tokens': 14}}
    return {'id': 'response-1', 'type': 'message', 'role': 'assistant', 'model': 'wire-model',
            'content': [{'type': 'text', 'text': 'answer 雪'}], 'stop_reason': 'end_turn', 'stop_sequence': None,
            'usage': {'input_tokens': 11, 'output_tokens': 3}}


def stream_response(api):
    if api == 'chat':
        rows = [
            {'id': 'response-1', 'object': 'chat.completion.chunk', 'model': 'wire-model',
             'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'answer 雪'}, 'finish_reason': None}]},
            {'id': 'response-1', 'object': 'chat.completion.chunk', 'model': 'wire-model',
             'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}],
             'usage': {'prompt_tokens': 11, 'completion_tokens': 3, 'total_tokens': 14}},
        ]
        return b''.join(b'data: ' + encoded(v) + b'\n\n' for v in rows) + b'data: [DONE]\n\n'
    if api == 'messages':
        rows = [('message_start', {'type': 'message_start', 'message': {**response(api), 'content': [], 'stop_reason': None,
                 'usage': {'input_tokens': 11, 'output_tokens': 0}}}),
                ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
                ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'answer 雪'}}),
                ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
                ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 3}}),
                ('message_stop', {'type': 'message_stop'})]
        return b''.join(f'event: {kind}\n'.encode() + b'data: ' + encoded(row) + b'\n\n' for kind, row in rows)
    item = response(api)['output'][0]
    rows = [{'type': 'response.created', 'response': {**response(api), 'status': 'in_progress', 'output': []}},
            {'type': 'response.output_item.added', 'output_index': 0, 'item': {**item, 'status': 'in_progress', 'content': []}},
            {'type': 'response.content_part.added', 'output_index': 0, 'item_id': 'message-1', 'content_index': 0, 'part': {'type': 'output_text', 'text': '', 'annotations': []}},
            {'type': 'response.output_text.delta', 'output_index': 0, 'item_id': 'message-1', 'content_index': 0, 'delta': 'answer 雪'},
            {'type': 'response.output_text.done', 'output_index': 0, 'item_id': 'message-1', 'content_index': 0, 'text': 'answer 雪'},
            {'type': 'response.content_part.done', 'output_index': 0, 'item_id': 'message-1', 'content_index': 0, 'part': item['content'][0]},
            {'type': 'response.output_item.done', 'output_index': 0, 'item_id': 'message-1', 'item': item},
            {'type': 'response.completed', 'response': response(api)}]
    return b''.join(b'event: ' + row['type'].encode() + b'\ndata: ' + encoded(row) + b'\n\n' for row in rows)


def large_messages_stream(text):
    marker = (b'event: content_block_delta\ndata: ' + encoded({'type': 'content_block_delta', 'index': 0,
              'delta': {'type': 'text_delta', 'text': 'answer 雪'}}) + b'\n\n')
    original = stream_response('messages')
    assert original.count(marker) == 1
    chunks = b''.join(b'event: content_block_delta\ndata: ' + encoded({'type': 'content_block_delta', 'index': 0,
                      'delta': {'type': 'text_delta', 'text': text[offset:offset + 32768]}}) + b'\n\n'
                      for offset in range(0, len(text), 32768))
    return original.replace(marker, chunks)


class Peer:
    def __init__(self, payload=None):
        self.payload = copy.deepcopy(payload)
        self.identity = None
        self.window = None
        self.sent = self.received = 0
        self.logical_sent = self.logical_received = 0
        env = os.environ.copy()
        for name in ['LD_LIBRARY_PATH', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'AXYNDRA_OPAQUE_MODEL_CREDENTIAL']:
            env.pop(name, None)
        self.process = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        self.frames = queue.Queue()
        self.stderr = bytearray()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.error_reader = threading.Thread(target=lambda: self.stderr.extend(self.process.stderr.read(65537)), daemon=True)
        self.reader.start()
        self.error_reader.start()
        self.requests = []
        self.events = []

    def _read(self):
        try:
            while True:
                raw = self.process.stdout.readline(262146)
                if not raw:
                    self.frames.put(None)
                    return
                if len(raw) > 262145 or not raw.endswith(b'\n'):
                    raise ValueError('invalid physical frame')
                self.frames.put(json.loads(raw))
        except BaseException as error:
            self.frames.put(error)

    def physical_next(self):
        value = self.frames.get(timeout=30)
        if isinstance(value, BaseException):
            raise value
        return value

    def next(self):
        value = self.physical_next()
        if value is None or value.get('type') != 'payload_begin':
            return value
        assert self.payload is not None
        self.received += 1
        header = value['payload']
        common = {'schema': LOGICAL_SCHEMA, 'window': self.window, 'transfer_sequence': self.received}
        assert value['schema'] == SCHEMA and value['identity'] == self.identity
        assert all(header[k] == v for k, v in common.items())
        assert set(header) == set(common) | {'message_type', 'bytes', 'sha256'}
        assert header['message_type'] == 'model_message'
        assert 0 < header['bytes'] <= self.payload['max_message_bytes']
        output = bytearray()
        while True:
            frame = self.physical_next()
            assert frame['schema'] == SCHEMA and frame['identity'] == self.identity
            chunk = frame['payload']
            assert all(chunk[k] == v for k, v in common.items())
            if frame['type'] == 'payload_end':
                assert chunk == common
                break
            assert frame['type'] == 'payload_chunk' and set(chunk) == set(common) | {'offset', 'bytes_hex'}
            assert chunk['offset'] == len(output) and 0 < len(chunk['bytes_hex']) <= 32768
            part = bytes.fromhex(chunk['bytes_hex'])
            assert part.hex() == chunk['bytes_hex'] and len(part) <= header['bytes'] - len(output)
            output.extend(part)
        assert len(output) == header['bytes'] and hashlib.sha256(output).hexdigest() == header['sha256']
        result = json.loads(output)
        assert result['identity'] == self.identity and result['schema'] == SCHEMA
        self.logical_received += 1
        return result

    def physical_send(self, value):
        self.process.stdin.write(encoded(value) + b'\n')
        self.process.stdin.flush()

    def payload_frames(self, value):
        raw = encoded(value)
        self.sent += 1
        common = {'schema': LOGICAL_SCHEMA, 'window': self.window, 'transfer_sequence': self.sent}
        def frame(kind, extras):
            return {'schema': SCHEMA, 'type': kind, 'identity': copy.deepcopy(self.identity), 'payload': {**common, **extras}}
        yield frame('payload_begin', {'message_type': 'model_message', 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
        for offset in range(0, len(raw), 16384):
            yield frame('payload_chunk', {'offset': offset, 'bytes_hex': raw[offset:offset+16384].hex()})
        yield frame('payload_end', {})

    def send(self, value):
        if self.payload is not None and len(encoded(value)) > 262144 - 4096:
            for frame in self.payload_frames(value): self.physical_send(frame)
            self.logical_sent += 1
        else:
            self.physical_send(value)

    def handshake(self, value):
        self.identity = copy.deepcopy(value['identity'])
        self.window = 'model-' + sha(self.identity)
        hello = {'schema': SCHEMA, 'type': 'hello', 'binding_digest': self.identity['binding_digest']}
        ready = {**hello, 'type': 'ready'}
        if self.payload is not None:
            hello.update(identity=self.identity, payload_limits=self.payload, payload_window=self.window)
            ready.update(payload_limits=self.payload, payload_window=self.window)
        self.physical_send(hello)
        assert self.next() == ready

    def start(self, value):
        self.handshake(value)
        self.send(value)

    def run(self, value, body, *, status=200, retry_after='', chunk=5, close_ack=True, poison=False):
        self.start(value)
        offset = 0
        sequence = 0
        while True:
            frame = self.next()
            if frame is None:
                return None
            if frame.get('type') == 'done':
                assert frame['identity'] == value['identity']
                assert self.process.wait(timeout=5) == 0
                return self.events
            if frame.get('type') != 'http_request':
                sequence += 1
                assert frame['sequence'] == sequence and frame['identity'] == value['identity']
                self.events.append(frame)
                continue
            self.requests.append(frame)
            assert frame['sequence'] == len(self.requests) and frame['identity'] == value['identity']
            action = frame['action']
            if action == 'open':
                result = {'opened': True}
            elif action == 'head':
                result = {'status': status, 'content_type': 'text/event-stream' if value['request']['streaming'] else 'application/json', 'retry_after': retry_after}
            elif action == 'read':
                part = body[offset:offset + chunk]
                offset += len(part)
                result = {'bytes_hex': part.hex(), 'eof': offset == len(body)}
            elif action == 'close':
                result = {'closed': close_ack}
            else:
                raise AssertionError(action)
            identity = copy.deepcopy(value['identity'])
            if poison:
                identity['epoch'] += 1
            self.send({'schema': SCHEMA, 'type': 'http_response', 'identity': identity,
                       'sequence': frame['sequence'], 'action': action, 'ok': True, 'result': result})

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        self.reader.join(timeout=5)
        self.error_reader.join(timeout=5)
        if self.reader.is_alive() or self.error_reader.is_alive():
            raise AssertionError('packaged endpoint pipe cleanup was not acknowledged')
        if self.process.stdin is not None:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                # A rejected malformed frame can leave buffered input after exit.
                # The process and both pipe readers have already acknowledged close.
                pass
        self.process.stdout.close()
        self.process.stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class ModelProviderProtocolTests(unittest.TestCase):
    def test_neutral_configuration_digest_binds_three_actual_codecs(self):
        for api in ['chat', 'responses', 'messages']:
            with self.subTest(api=api), Peer() as peer:
                value = fixture(api)
                binding = value['binding']
                binding['execution_capabilities']['configuration_digest'] = binding['configuration_digest']
                binding['capabilities'] += 'configuration_digest=' + binding['configuration_digest'] + '\n'
                binding['execution_capabilities']['fingerprint'] = hashlib.sha256(binding['capabilities'].encode()).hexdigest()
                events = peer.run(reframed(value), encoded(response(api)))
                replies = [e['payload'] for e in events if e['kind'] == 'reply']
                self.assertEqual(len(replies), 1)
                self.assertEqual(replies[0]['usage']['input'], 11)
                self.assertEqual(sum(r['action'] == 'open' for r in peer.requests), 1)

    def test_neutral_configuration_digest_mismatch_has_zero_http(self):
        value = fixture()
        binding = value['binding']
        binding['execution_capabilities']['configuration_digest'] = 'c' * 64
        binding['capabilities'] += 'configuration_digest=' + 'c' * 64 + '\n'
        binding['execution_capabilities']['fingerprint'] = hashlib.sha256(binding['capabilities'].encode()).hexdigest()
        with Peer() as peer:
            events = peer.run(reframed(value), encoded(response('chat')))
            self.assertFalse(peer.requests)
            self.assertTrue(events is None or not any(e['kind'] == 'reply' for e in events))

    def successful(self, api, streaming=False):
        value = fixture(api, streaming)
        with Peer() as peer:
            events = peer.run(value, stream_response(api) if streaming else encoded(response(api)), chunk=1 if streaming else 5)
            replies = [e['payload'] for e in events if e['kind'] == 'reply']
            self.assertEqual(len(replies), 1)
            self.assertIn('answer 雪', ''.join(b['text'] for b in replies[0]['blocks']))
            self.assertEqual(replies[0]['usage']['input'], 11)
            self.assertEqual(replies[0]['usage']['output'], 3)
            request = peer.requests[0]['arguments']['request']
            self.assertEqual(request['credential_refs'], ['provider-key'])
            self.assertNotIn('authorization', request['headers'])
            sent = json.loads(bytes.fromhex(request['body_hex']))
            self.assertEqual(sent['model'], 'wire-model')
            self.assertEqual(sum(r['action'] == 'open' for r in peer.requests), 1)
            self.assertEqual(peer.requests[-1]['action'], 'close')
            if streaming:
                kinds = [e['payload']['kind'] for e in events if e['kind'] == 'event']
                self.assertIn('terminal', kinds)
                self.assertIn('transport_closed', kinds)
            self.assertEqual(peer.stderr, b'')

    def test_chat(self): self.successful('chat')
    def test_responses(self): self.successful('responses')
    def test_messages(self): self.successful('messages')

    def test_all_explicit_dialects_dispatch_through_package_owned_adapters(self):
        for dialect, api in [('openai_chat', 'chat'), ('generic_chat', 'chat'), ('deepseek_chat', 'chat'),
                             ('openai_responses', 'responses'), ('deepseek_responses', 'responses'),
                             ('anthropic_messages', 'messages'), ('generic_messages', 'messages'),
                             ('deepseek_messages', 'messages')]:
            with self.subTest(dialect=dialect):
                value = fixture(api)
                value['binding']['configuration']['dialect'] = dialect
                value['binding']['parallel_tools'] = not dialect.startswith('deepseek_')
                reframed(value)
                with Peer() as peer:
                    events = peer.run(value, encoded(response(api)), chunk=8192)
                    replies = [event['payload'] for event in events if event['kind'] == 'reply']
                    self.assertEqual(len(replies), 1)
                    self.assertEqual(replies[0]['usage']['input'], 11)
                    self.assertEqual(replies[0]['usage']['output'], 3)
                    self.assertIn('answer 雪', ''.join(block['text'] for block in replies[0]['blocks']))
                    suffix = {'chat': '/v1/chat/completions', 'responses': '/v1/responses', 'messages': '/v1/messages'}[api]
                    self.assertTrue(peer.requests[0]['arguments']['request']['url'].endswith(suffix))
                    self.assertEqual(sum(request['action'] == 'open' for request in peer.requests), 1)
                    self.assertEqual(peer.requests[-1]['action'], 'close')
    def test_chat_stream_utf8_split(self): self.successful('chat', True)
    def test_responses_stream_utf8_split(self): self.successful('responses', True)
    def test_messages_stream_utf8_split(self): self.successful('messages', True)

    def test_discovery_has_three_model_contributions_and_no_tools(self):
        with Peer() as peer:
            peer.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'model-providers',
                       'extension_version': '1.2.0', 'generation': 7, 'capabilities': ['network.http']})
            ready = peer.next()
            self.assertEqual(len(ready['model_providers']), 3)
            self.assertEqual(ready['tools'], [])
            self.assertEqual(ready['services'], [])
            peer.process.stdin.close()
            peer.process.stdin = None
            self.assertEqual(peer.next(), None)
            self.assertEqual(peer.process.wait(timeout=5), 0)

    def failure(self, status, kind):
        with Peer() as peer:
            events = peer.run(fixture(), b'{"error":{"message":"fixture error"}}', status=status, retry_after='2', chunk=8192)
            failures = [e['payload'] for e in events if e['kind'] == 'failure']
            self.assertEqual(len(failures), 1)
            self.assertEqual(failures[0]['kind'], kind)
            self.assertEqual(failures[0]['retry_after_ms'], 2000)
            self.assertFalse(any(e['kind'] == 'reply' for e in events))

    def test_authentication_failure(self): self.failure(401, 'authentication')
    def test_rate_limit_retry_after(self): self.failure(429, 'rate_limited')
    def test_provider_failure(self): self.failure(503, 'provider')

    def test_invalid_json_is_typed_failure(self):
        with Peer() as peer:
            events = peer.run(fixture(), b'{"incomplete":', chunk=8192)
            self.assertEqual([e['kind'] for e in events][-1], 'failure')

    def test_missing_terminal_is_not_success(self):
        body = b'data: {"id":"r","choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}\n\n'
        with Peer() as peer:
            events = peer.run(fixture(streaming=True), body, chunk=8192)
            self.assertFalse(any(e['kind'] == 'reply' for e in events))
            self.assertEqual(events[-1]['payload']['attempt_failure'], 'terminal_missing')

    def test_close_without_ack_is_failure(self):
        with Peer() as peer:
            events = peer.run(fixture(), encoded(response('chat')), close_ack=False, chunk=8192)
            self.assertFalse(any(e['kind'] == 'reply' for e in events))
            self.assertEqual(events[-1]['kind'], 'failure')

    def invalid_before_io(self, change, rehash=False):
        value = fixture()
        change(value)
        if rehash:
            value['identity']['binding_digest'] = sha(value['binding'])
            value['identity']['input_digest'] = sha(value['request'])
        with Peer() as peer:
            peer.start(value)
            self.assertIsNone(peer.next())
            self.assertEqual(peer.process.wait(timeout=5), 3)
            self.assertEqual(peer.requests, [])

    def test_binding_digest_drift_before_io(self): self.invalid_before_io(lambda v: v['binding'].update(wire_model='other'))
    def test_input_digest_drift_before_io(self): self.invalid_before_io(lambda v: v['request'].update(system='changed'))
    def test_wrong_epoch_before_io(self): self.invalid_before_io(lambda v: v['identity'].update(epoch=0))
    def test_wrong_dialect_before_io(self): self.invalid_before_io(lambda v: v['binding']['configuration'].update(dialect='anthropic_messages'), True)
    def test_capability_fingerprint_before_io(self): self.invalid_before_io(lambda v: v['binding']['execution_capabilities'].update(max_output=9999), True)

    def test_identity_poison_never_yields_success(self):
        with Peer() as peer:
            events = peer.run(fixture(), encoded(response('chat')), poison=True)
            self.assertTrue(events is None or all(e['kind'] != 'reply' for e in events))

    def test_transport_eof_cannot_complete(self):
        with Peer() as peer:
            peer.start(fixture())
            self.assertEqual(peer.next()['type'], 'http_request')
            peer.process.stdin.close(); peer.process.stdin = None
            events = []
            while True:
                event = peer.next()
                if event is None: break
                events.append(event)
            self.assertFalse(any(e.get('kind') == 'reply' for e in events))
            peer.process.wait(timeout=5)

    def test_request_limit_has_zero_http_requests(self):
        value = fixture()
        value['request']['system'] = 'x' * 70000
        value['identity']['input_digest'] = sha(value['request'])
        with Peer() as peer:
            events = peer.run(value, b'')
            self.assertEqual(peer.requests, [])
            self.assertEqual(events[-1]['kind'], 'failure')


    def test_logical_large_unicode_input_reaches_real_adapter_exactly(self):
        value = fixture()
        text = 'model payload 雪\n' * 24000
        value['request']['messages'][0]['blocks'][0]['text'] = text
        reframed(value)
        with Peer(PAYLOAD) as peer:
            events = peer.run(value, encoded(response('chat')), chunk=16384)
            sent = json.loads(bytes.fromhex(peer.requests[0]['arguments']['request']['body_hex']))
            self.assertEqual(sent['messages'][-1]['content'], text)
            self.assertEqual(sum(e['kind'] == 'reply' for e in events), 1)
            self.assertGreater(peer.logical_sent, 0)
            self.assertGreater(peer.logical_received, 0)

    def test_logical_reply_exceeds_physical_frame_without_loss(self):
        body = response('chat'); text = 'large reply 雪' * 26000
        body['choices'][0]['message']['content'] = text
        with Peer(PAYLOAD) as peer:
            events = peer.run(fixture(), encoded(body), chunk=16384)
            replies = [e['payload'] for e in events if e['kind'] == 'reply']
            self.assertEqual(len(replies), 1)
            self.assertEqual(''.join(block['text'] for block in replies[0]['blocks']), text)
            self.assertGreater(peer.logical_received, 0)

    def test_logical_input_profile_limit_rejects_before_any_http(self):
        limits = {**PAYLOAD, 'max_input_bytes': 1000}
        value = fixture(); value['request']['system'] = 'x' * 2000; reframed(value)
        with Peer(limits) as peer:
            peer.start(value)
            self.assertIsNone(peer.next())
            self.assertEqual(peer.process.wait(timeout=5), 3)
            self.assertEqual(peer.requests, [])

    def poisoned_logical(self, change):
        value = fixture(); value['request']['system'] = 'x' * 270000; reframed(value)
        with Peer(PAYLOAD) as peer:
            peer.handshake(value)
            frames = list(peer.payload_frames(value))
            change(frames)
            for frame in frames:
                try: peer.physical_send(frame)
                except BrokenPipeError: break
            self.assertIsNone(peer.next())
            self.assertEqual(peer.process.wait(timeout=5), 3)
            self.assertEqual(peer.requests, [])

    def test_logical_wrong_outer_identity_rejected(self):
        self.poisoned_logical(lambda rows: rows[1]['identity'].update(epoch=2))

    def test_logical_wrong_digest_rejected(self):
        self.poisoned_logical(lambda rows: rows[0]['payload'].update(sha256='0' * 64))

    def test_logical_wrong_offset_rejected(self):
        self.poisoned_logical(lambda rows: rows[1]['payload'].update(offset=1))

    def test_logical_wrong_sequence_rejected(self):
        self.poisoned_logical(lambda rows: rows[1]['payload'].update(transfer_sequence=2))

    def test_logical_eof_mid_body_cannot_dispatch(self):
        value = fixture(); value['request']['system'] = 'x' * 270000; reframed(value)
        with Peer(PAYLOAD) as peer:
            peer.handshake(value)
            rows = list(peer.payload_frames(value))
            peer.physical_send(rows[0]); peer.physical_send(rows[1])
            peer.process.stdin.close(); peer.process.stdin = None
            self.assertIsNone(peer.next()); self.assertEqual(peer.process.wait(timeout=5), 3)
            self.assertEqual(peer.requests, [])

    def test_streaming_zero_timeout_is_not_replaced_by_120_seconds(self):
        value = fixture(streaming=True); value['transport_hard_timeout_ms'] = 0
        value['binding']['configuration']['timeout_ms'] = 0; reframed(value)
        with Peer(PAYLOAD) as peer:
            events = peer.run(value, stream_response('chat'), chunk=16384)
            self.assertEqual(peer.requests[0]['arguments']['request']['timeout_ms'], 0)
            self.assertEqual(sum(e['kind'] == 'reply' for e in events), 1)

    def test_incremental_sse_heartbeats_keep_one_terminal_and_exact_usage(self):
        value = fixture('messages', True)
        body = (b':' + b' ' * 4093 + b'\n\n') * 1024 + stream_response('messages')
        with Peer(PAYLOAD) as peer:
            events = peer.run(value, body, chunk=16384)
            replies = [e['payload'] for e in events if e['kind'] == 'reply']
            self.assertEqual(len(replies), 1)
            self.assertEqual(''.join(b['text'] for b in replies[0]['blocks']), 'answer 雪')
            self.assertEqual(replies[0]['usage']['input'], 11)
            self.assertEqual(replies[0]['usage']['output'], 3)
            kinds = [e['payload']['kind'] for e in events if e['kind'] == 'event']
            self.assertEqual(kinds.count('terminal'), 1)
            self.assertEqual(kinds.count('transport_closed'), 1)
            self.assertEqual(peer.requests[-1]['action'], 'close')

    def test_incremental_missing_terminal_retains_typed_usage_failure(self):
        value = fixture('messages', True)
        body = stream_response('messages')
        # Remove the final message_stop event while preserving real observed
        # text and the final usage update from the preceding message_delta.
        body = body[:body.rfind(b'event: message_stop')]
        self.assertTrue(body and b'message_delta' in body)
        with Peer(PAYLOAD) as peer:
            events = peer.run(value, body, chunk=16384)
            self.assertFalse(any(e['kind'] == 'reply' for e in events))
            failures = [e['payload'] for e in events if e['kind'] == 'failure']
            self.assertEqual(len(failures), 1)
            self.assertEqual(failures[0]['code'], 'llm.stream_terminal_missing')
            self.assertEqual(peer.requests[-1]['action'], 'close')

    def test_long_frozen_timeout_is_preserved_in_actual_request(self):
        value = fixture(); value['transport_hard_timeout_ms'] = 3600000
        value['binding']['configuration']['timeout_ms'] = 3600000; reframed(value)
        with Peer(PAYLOAD) as peer:
            events = peer.run(value, encoded(response('chat')), chunk=16384)
            self.assertEqual(peer.requests[0]['arguments']['request']['timeout_ms'], 3600000)
            self.assertEqual(sum(e['kind'] == 'reply' for e in events), 1)

    def compact_stream(self, text):
        # Keep the real provider codec: replace the one Messages text delta,
        # never manufacture typed ModelProvider output in this peer.
        body = stream_response('messages').replace(encoded('answer 雪'), encoded(text))
        with Peer(PAYLOAD) as peer:
            events = peer.run(fixture('messages', True), body, chunk=16384)
            terminals = [e for e in events if e['kind'] in ('reply', 'reply_stream')]
            self.assertEqual(len(terminals), 1)
            self.assertEqual(terminals[0]['kind'], 'reply_stream')
            value = terminals[0]['payload']
            self.assertEqual(value['schema'], 'axyndra.model-stream-reply/v1')
            deltas = [e['payload']['text'] for e in events if e['kind'] == 'event' and e['payload']['kind'] == 'text']
            self.assertEqual(''.join(deltas), text)
            self.assertTrue(all(len(delta.encode()) <= 16384 for delta in deltas))
            self.assertEqual(value['references'], [{'block_index': 0, 'kind': 'text', 'offset': 0,
                'length': len(text.encode()), 'sha256': hashlib.sha256(text.encode()).hexdigest()}])
            self.assertEqual(value['reply']['blocks'][0]['text'], '')
            self.assertLess(len(encoded(value)), 4096)
            self.assertEqual(value['reply']['usage']['input'], 11)
            self.assertEqual(value['reply']['usage']['output'], 3)
            self.assertEqual(sum(e['kind'] == 'event' and e['payload']['kind'] == 'terminal' for e in events), 1)
            self.assertEqual(peer.requests[-1]['action'], 'close')

    def test_compact_stream_terminal_does_not_repeat_text(self):
        self.compact_stream('x' * 180000)

    def test_compact_stream_chunks_preserve_utf8_and_json_escapes(self):
        self.compact_stream('雪λ\n\\"\t' * 12000)

    def test_near_eight_mib_semantic_text_with_larger_sse_envelope(self):
        text = 'x' * 8387584
        body = large_messages_stream(text)
        self.assertGreater(len(body), 8388608)
        self.assertLessEqual(len(body), 8388608 + 65536)
        with Peer(PAYLOAD) as peer:
            events = peer.run(fixture('messages', True), body, chunk=16384)
            terminals = [event for event in events if event['kind'] in ('reply', 'reply_stream')]
            self.assertEqual(len(terminals), 1)
            self.assertEqual(terminals[0]['kind'], 'reply_stream')
            parts = [e['payload']['text'] for e in events if e['kind'] == 'event' and e['payload']['kind'] == 'text']
            self.assertEqual(''.join(parts), text)
            self.assertEqual(terminals[0]['payload']['references'][0]['sha256'], hashlib.sha256(text.encode()).hexdigest())
            self.assertEqual(peer.requests[0]['arguments']['request']['max_response_bytes'], 8454144)
            self.assertEqual(peer.requests[-1]['action'], 'close')

    def alias_fixture(self, api, streaming=False):
        value = fixture(api, streaming)
        name = 'plugin.axyndra:mcp-client.service.stdio.remote.echo:雪.' + 'long_' * 20
        alias = hashlib.sha256(name.encode()).hexdigest()
        arguments = {'text': 'exact 雪', 'line': 'one\ntwo', 'input': {'role': 'user'}}
        value['request']['tools'] = [dict(name=name, description='independent Tool', input_schema={'type': 'object', 'properties': {}}),
                                     dict(name='read_file', description='portable name unchanged', input_schema={'type': 'object', 'properties': {}})]
        return reframed(value), name, alias, arguments

    def alias_response(self, api, alias, arguments):
        result = response(api)
        if api == 'chat':
            result['choices'][0]['message'] = {'role': 'assistant', 'content': None, 'tool_calls': [
                {'id': 'alias-call', 'type': 'function', 'function': {'name': alias, 'arguments': json.dumps(arguments, ensure_ascii=False)}}]}
            result['choices'][0]['finish_reason'] = 'tool_calls'
        elif api == 'responses':
            result['output'] = [{'type': 'function_call', 'id': 'function-1', 'call_id': 'alias-call', 'name': alias,
                                 'arguments': json.dumps(arguments, ensure_ascii=False), 'status': 'completed'}]
        else:
            result['content'] = [{'type': 'tool_use', 'id': 'alias-call', 'name': alias, 'input': arguments}]
            result['stop_reason'] = 'tool_use'
        return encoded(result)

    def alias_success(self, api):
        value, name, alias, arguments = self.alias_fixture(api)
        original = copy.deepcopy(value)
        with Peer() as peer:
            events = peer.run(value, self.alias_response(api, alias, arguments), chunk=16384)
            reply = next(e['payload'] for e in events if e['kind'] == 'reply')
            call = next(b for b in reply['blocks'] if b['kind'] == 'tool_call')
            self.assertEqual((call['name'], call['call_id'], call['arguments']), (name, 'alias-call', arguments))
            sent = json.loads(bytes.fromhex(peer.requests[0]['arguments']['request']['body_hex']))
            if api == 'messages': offered = [t['name'] for t in sent['tools']]
            elif api == 'chat': offered = [t['function']['name'] for t in sent['tools']]
            else: offered = [t['name'] for t in sent['tools']]
            self.assertEqual(offered, [alias, 'read_file'])
            self.assertEqual(sum(r['action'] == 'open' for r in peer.requests), 1)
            self.assertEqual(peer.requests[-1]['action'], 'close')
            self.assertEqual(value, original)
            self.assertEqual(reply['usage']['input'], 11)
            self.assertEqual(reply['usage']['output'], 3)

    def test_namespaced_tool_chat_reply_returns_canonical_name(self): self.alias_success('chat')
    def test_namespaced_tool_responses_reply_returns_canonical_name(self): self.alias_success('responses')
    def test_namespaced_tool_messages_reply_returns_canonical_name(self): self.alias_success('messages')

    def alias_stream(self, alias, arguments):
        rows = [dict(type='message_start', message={**response('messages'), 'content': [], 'stop_reason': None,
                                                   'usage': {'input_tokens': 11, 'output_tokens': 0}}),
                dict(type='content_block_start', index=0, content_block=dict(type='tool_use', id='alias-call', name=alias, input={})),
                dict(type='content_block_delta', index=0, delta=dict(type='input_json_delta', partial_json=json.dumps(arguments, ensure_ascii=False))),
                dict(type='content_block_stop', index=0),
                dict(type='message_delta', delta=dict(stop_reason='tool_use', stop_sequence=None), usage=dict(output_tokens=3)),
                dict(type='message_stop')]
        return b''.join(b'event: ' + row['type'].encode() + b'\ndata: ' + encoded(row) + b'\n\n' for row in rows)

    def test_streamed_alias_events_and_reply_have_same_canonical_name(self):
        value, name, alias, arguments = self.alias_fixture('messages', True)
        with Peer() as peer:
            events = peer.run(value, self.alias_stream(alias, arguments), chunk=1)
            starts = [e['payload'] for e in events if e['kind'] == 'event' and e['payload']['kind'] == 'tool_start']
            self.assertEqual([(e['id'], e['name']) for e in starts], [('alias-call', name)])
            self.assert_stream_blocks(events,1)
            reply = next(e['payload'] for e in events if e['kind'] == 'reply')
            self.assertEqual(reply['blocks'][0]['name'], name)
            self.assertEqual(reply['blocks'][0]['arguments'], arguments)

    def test_history_call_and_full_result_use_same_alias_without_mutating_input(self):
        value, name, alias, arguments = self.alias_fixture('messages')
        base = value['request']['messages'][0]['blocks'][0]
        call = {**base, 'kind': 'tool_call', 'text': '', 'call_id': 'past', 'name': name, 'arguments': arguments}
        result = {**base, 'kind': 'tool_result', 'text': 'full result 雪', 'call_id': 'past', 'name': name, 'receipt_id': 'receipt-1'}
        value['request']['messages'] += [dict(role='assistant', blocks=[call]), dict(role='user', blocks=[result])]
        reframed(value); original = copy.deepcopy(value)
        with Peer() as peer:
            events = peer.run(value, encoded(response('messages')), chunk=16384)
            self.assertTrue(any(e['kind'] == 'reply' for e in events))
            sent = json.loads(bytes.fromhex(peer.requests[0]['arguments']['request']['body_hex']))
            history = json.dumps(sent['messages'], ensure_ascii=False)
            self.assertIn(alias, history); self.assertNotIn(name, history)
            self.assertIn('full result 雪', history)
            self.assertEqual(value, original)

    def test_alias_collision_with_portable_catalog_name_fails_before_http(self):
        value, name, alias, _ = self.alias_fixture('messages')
        value['request']['tools'][1]['name'] = alias
        with Peer() as peer:
            events = peer.run(reframed(value), encoded(response('messages')))
            self.assertEqual(peer.requests, [])
            self.assertTrue(events is None or not any(e['kind'] == 'reply' for e in events))

    def test_duplicate_canonical_tool_name_fails_before_http(self):
        value, name, _, _ = self.alias_fixture('messages')
        value['request']['tools'][1]['name'] = name
        with Peer() as peer:
            events = peer.run(reframed(value), encoded(response('messages')))
            self.assertEqual(peer.requests, [])
            self.assertTrue(events is None or not any(e['kind'] == 'reply' for e in events))

    def test_unoffered_wire_alias_is_failure_with_observed_usage(self):
        value, _, _, arguments = self.alias_fixture('messages', True)
        with Peer() as peer:
            events = peer.run(value, self.alias_stream('unoffered_name', arguments), chunk=16384)
            self.assertFalse(any(e['kind'] in ('reply', 'reply_stream') for e in events))
            self.assertFalse(any(e['kind'] == 'event' and e['payload']['kind'] == 'tool_start' for e in events))
            failure = next(e['payload'] for e in events if e['kind'] == 'failure')
            self.assertEqual(failure['code'], 'model.tool_name_unknown')
            self.assertEqual(failure['usage_fields']['usage_input_tokens'], '11')
            self.assertEqual(failure['usage_fields']['usage_output_tokens'], '3')
            self.assertEqual(peer.requests[-1]['action'], 'close')

    def assert_stream_blocks(self, events, expected_tools):
        active = {}; completed = set(); tools = set()
        for event in events:
            if event['kind'] != 'event': continue
            value = event['payload']; kind = value['kind']
            if kind == 'block_start':
                self.assertNotIn(value['index'], active); self.assertNotIn(value['index'], completed)
                active[value['index']] = value['block_kind']
            elif kind == 'block_end':
                self.assertEqual(active.pop(value['index']), value['block_kind']); completed.add(value['index'])
            elif kind == 'tool_start':
                self.assertIn('tool_call', active.values()); tools.add(value['id'])
            elif kind == 'terminal': self.assertEqual(active, {})
        self.assertEqual(active, {}); self.assertEqual(len(tools), expected_tools)
        self.assertEqual(len(completed), expected_tools)

    def chat_alias_stream(self, aliases, arguments):
        result = response('chat')
        first = {'id': result['id'], 'object': 'chat.completion.chunk', 'model': 'wire-model', 'choices': [
            {'index': 0, 'delta': {'role': 'assistant', 'tool_calls': [
                {'index': i, 'id': 'alias-call-'+str(i), 'type': 'function', 'function': {'name': alias, 'arguments': json.dumps(arguments, ensure_ascii=False)}}
                for i, alias in enumerate(aliases)]}, 'finish_reason': None}]}
        last = {'id': result['id'], 'object': 'chat.completion.chunk', 'model': 'wire-model', 'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}], 'usage': {'prompt_tokens': 11, 'completion_tokens': 3, 'total_tokens': 14}}
        return b''.join(b'data: '+encoded(row)+b'\n\n' for row in [first,last])+b'data: [DONE]\n\n'

    def test_chat_stream_alias_has_complete_block_lifecycle(self):
        value,name,alias,arguments=self.alias_fixture('chat',True)
        with Peer() as peer:
            events=peer.run(value,self.chat_alias_stream([alias],arguments),chunk=1)
            self.assert_stream_blocks(events,1)
            reply=next(e['payload'] for e in events if e['kind']=='reply')
            self.assertEqual(reply['blocks'][0]['name'],name)

    def test_parallel_chat_tool_locations_have_distinct_block_ids(self):
        value,name,alias,arguments=self.alias_fixture('chat',True)
        value['request']['parallel_tool_calls']=True;reframed(value)
        with Peer() as peer:
            events=peer.run(value,self.chat_alias_stream([alias,'read_file'],arguments),chunk=1)
            self.assert_stream_blocks(events,2)
            reply=next(e['payload'] for e in events if e['kind']=='reply')
            self.assertEqual([b['name'] for b in reply['blocks']],[name,'read_file'])
            self.assertEqual([b['arguments'] for b in reply['blocks']],[arguments,arguments])

    def test_responses_stream_alias_has_complete_block_lifecycle(self):
        value,name,alias,arguments=self.alias_fixture('responses',True)
        call=json.loads(self.alias_response('responses',alias,arguments))['output'][0]
        final=json.loads(self.alias_response('responses',alias,arguments))
        rows=[dict(type='response.created',response={**final,'status':'in_progress','output':[]}),
              dict(type='response.output_item.added',output_index=0,item={**call,'status':'in_progress','arguments':''}),
              dict(type='response.function_call_arguments.delta',output_index=0,item_id=call['id'],delta=json.dumps(arguments,ensure_ascii=False)),
              dict(type='response.function_call_arguments.done',output_index=0,item_id=call['id'],arguments=json.dumps(arguments,ensure_ascii=False)),
              dict(type='response.output_item.done',output_index=0,item_id=call['id'],item=call),dict(type='response.completed',response=final)]
        body=b''.join(b'event: '+r['type'].encode()+b'\ndata: '+encoded(r)+b'\n\n' for r in rows)
        with Peer() as peer:
            events=peer.run(value,body,chunk=1)
            self.assert_stream_blocks(events,1)
            reply=next(e['payload'] for e in events if e['kind']=='reply')
            self.assertEqual(reply['blocks'][0]['name'],name)
            self.assertEqual(reply['blocks'][0]['arguments'],arguments)


    def test_incomplete_chat_tool_cannot_complete_and_retains_observed_usage(self):
        value,_,alias,arguments=self.alias_fixture('chat',True)
        body=self.chat_alias_stream([alias],arguments)
        argument=b'"arguments":'+encoded(json.dumps(arguments,ensure_ascii=False))
        self.assertEqual(body.count(argument),1)
        body=body.replace(argument,b'"arguments":'+encoded('{"text":'),1)
        body=body.replace(b'"finish_reason":"tool_calls"',b'"finish_reason":"length"')
        with Peer() as peer:
            events=peer.run(value,body,chunk=1)
            self.assertFalse(any(e['kind'] in ('reply','reply_stream') for e in events))
            self.assertFalse(any(e['kind']=='event' and e['payload']['kind']=='tool_end' for e in events))
            failure=next(e['payload'] for e in events if e['kind']=='failure')
            self.assertIn(failure['code'],['model.stream_tool_terminal_incomplete','llm.tool_arguments_not_executable'])
            self.assertEqual(failure['usage_fields']['usage_input_tokens'],'11')
            self.assertEqual(failure['usage_fields']['usage_output_tokens'],'3')
            self.assertEqual(peer.requests[-1]['action'],'close')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--summary', type=Path)
    args, remaining = parser.parse_known_args()
    BINARY = args.package.resolve() / 'bin/model-providers'
    if not BINARY.is_file(): parser.error('actual independent package is required')
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ModelProviderProtocolTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    summary = {'executed': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
               'skipped': len(result.skipped), 'entry_sha256': hashlib.sha256(BINARY.read_bytes()).hexdigest()}
    if args.summary:
        args.summary.write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    raise SystemExit(0 if result.wasSuccessful() and result.testsRun == 51 and not result.skipped else 1)

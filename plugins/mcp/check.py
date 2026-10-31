#!/usr/bin/env python3
"""Actual packaged native plugin + real stdio peer; host broker is a protocol fixture.

This proves plugin protocol/session behavior, not Product/SQLite authorization.
No transport substitution inside mcp4cj and no execution of forged host authority.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import queue
import selectors
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent
IDENTITY = ('protocol', 'extension_id', 'extension_version', 'generation', 'id', 'tool', 'kind',
            'command_id', 'thread_id', 'run_id', 'epoch', 'operation_id', 'call_id')
BINARY = None

def configuration():
    return {'version': 1, 'transport': 'stdio', 'request_timeout_ms': 10000,
            'directory': {'max_pages': 8, 'max_tools': 64}}

def local_name(remote='remote.echo:雪'):
    return 't_' + hashlib.sha256(remote.encode()).hexdigest()

class Peer:
    def __init__(self, mode='echo', *, profile=None, server=None):
        self.profile = profile
        self.frame_limit = profile['max_frame_bytes'] if profile else 262144
        self.directory = tempfile.TemporaryDirectory(prefix='mcp-plugin-protocol-')
        self.record = Path(self.directory.name) / 'requests.jsonl'
        self.record.touch()
        self.origin = None
        self.plugin = None
        try:
            self.origin = subprocess.Popen([sys.executable, '-u', str(server or ROOT / 'tests/server.py'), mode, str(self.record)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.plugin = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.frames = queue.Queue()
            self.send_lock = threading.Lock()
            self.errors = bytearray()
            self.reader = threading.Thread(target=self._read, daemon=True)
            self.reader.start()
            self.error_reader = threading.Thread(target=self._errors, daemon=True)
            self.error_reader.start()
            self.counter = 0
            self.events = []
            self.allowed = {}
            self.current = None
            self.poison_response = False
            self.omit_receipt = False
            self.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'mcp-client',
                'extension_version': '1.0.0', 'generation': 7, 'capabilities': ['process.channel'],
                **({'max_frame_bytes': self.frame_limit, 'service_protocol_limits': profile} if profile else {})})
            ready = self.next(3)
            assert ready['type'] == 'ready' and ready['tools'] == [] and ready['services'][0]['name'] == 'session'
        except BaseException:
            self.close()
            raise

    def _read(self):
        try:
            for line in self.plugin.stdout:
                if len(line) > self.frame_limit + 1 or not line.endswith(b'\n'):
                    raise AssertionError('unbounded or incomplete native frame')
                self.frames.put(json.loads(line))
        except BaseException as error:
            self.frames.put(error)
        finally:
            self.frames.put(EOFError('plugin exited'))

    def _errors(self):
        for chunk in iter(lambda: self.plugin.stderr.read(4096), b''):
            if len(self.errors) < 65536:
                self.errors.extend(chunk)

    def send(self, frame):
        encoded = (json.dumps(frame, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
        with self.send_lock:
            self.plugin.stdin.write(encoded)
            self.plugin.stdin.flush()

    def next(self, timeout=15):
        value = self.frames.get(timeout=timeout)
        if isinstance(value, BaseException):
            raise value
        return value

    def invocation(self, arguments, *, kind='service', call='call-1', run='run-1', thread='thread-1'):
        self.counter += 1
        return {'type': 'invoke', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'mcp-client',
            'extension_version': '1.0.0', 'generation': 7, 'id': f'invoke-{self.counter}', 'tool': 'session',
            'kind': kind, 'command_id': '', 'thread_id': thread, 'run_id': run, 'epoch': 3,
            'operation_id': '' if kind == 'service_prepare' else f'operation-{run}-{call}', 'call_id': call,
            'arguments': arguments}

    def answer(self, message, *, fail=False):
        assert self.current is not None
        for key in IDENTITY:
            assert message[key] == self.current[key], (key, message[key], self.current[key])
        service, args = message['service'], message['arguments']
        self.events.append((service, args))
        response = {key: message[key] for key in IDENTITY}
        response.update(type='service_response', request_id=message['request_id'], ok=not fail)
        if self.poison_response:
            response['epoch'] += 1
        if fail:
            response['error'] = {'code': 'fixture.permission_denied', 'message': 'denied'}
        elif service == 'process.channel.read':
            assert set(args) == {'stream', 'max_bytes', 'wait_ms'}
            assert args['stream'] in ('stdout', 'stderr') and 1 <= args['max_bytes'] <= 65536 and 0 <= args['wait_ms'] <= 25
            stream = self.origin.stdout if args['stream'] == 'stdout' else self.origin.stderr
            with selectors.DefaultSelector() as poll:
                poll.register(stream, selectors.EVENT_READ)
                data = os.read(stream.fileno(), args['max_bytes']) if poll.select(args['wait_ms'] / 1000) else None
            response['result'] = {'bytes_hex': data.hex() if data else '', 'eof': data == b''}
        elif service in ('process.channel.startup.write', 'process.channel.refresh.write'):
            expected_action = 'start' if service == 'process.channel.startup.write' else 'refresh'
            assert self.current['arguments']['action'] == expected_action and set(args) == {'bytes_hex'}
            data = bytes.fromhex(args['bytes_hex'])
            assert 0 < len(data) <= 30720
            self.origin.stdin.write(data)
            self.origin.stdin.flush()
            response['result'] = {'written_bytes': len(data)}
        elif service == 'process.channel.write':
            assert set(args) == {'intent_id'} and args['intent_id'] == 'mcp-call'
            data = self.allowed.pop((self.current['run_id'], self.current['call_id']))
            self.origin.stdin.write(data)
            self.origin.stdin.flush()
            response['result'] = {'written_bytes': len(data), 'receipt_id': 'fixture-receipt-completed'}
            if self.omit_receipt:
                del response['result']['receipt_id']
        else:
            raise AssertionError(f'plugin requested unsupported service {service}')
        self.send(response)
        return service

    def invoke(self, arguments, *, kind='service', call='call-1', run='run-1', fail_services=False):
        frame = self.invocation(arguments, kind=kind, call=call, run=run)
        self.current = frame
        self.send(frame)
        deadline = time.monotonic() + 15
        # stdout and stderr reads are independent broker requests. A quiet
        # stderr poll must not serialize every ready stdout chunk behind its
        # wait_ms; the real host brokers both stream readers concurrently.
        def answer_read(message):
            try:
                self.answer(message, fail=fail_services)
            except BaseException as error:
                self.frames.put(error)
        with ThreadPoolExecutor(max_workers=2) as reads:
            while time.monotonic() < deadline:
                message = self.next(max(.01, deadline - time.monotonic()))
                if message['type'] == 'service_request':
                    assert kind != 'service_prepare', 'pure preparation performed I/O'
                    if message['service'] == 'process.channel.read':
                        reads.submit(answer_read, message)
                    else:
                        self.answer(message, fail=fail_services)
                    continue
                assert message['type'] == 'result', message
                for key in IDENTITY:
                    assert message[key] == frame[key]
                self.current = None
                return message
            raise TimeoutError('native invocation deadline')

    def start(self):
        return self.invoke({'action': 'start', 'configuration': configuration()}, call='startup', run='maintenance')

    def refresh(self, config=None):
        return self.invoke({'action': 'refresh', 'configuration': configuration() if config is None else config},
                           call='refresh-' + str(self.counter), run='refresh-maintenance')

    def prepare(self, *, data=None, call='call-1', run='run-1', tool=None):
        arguments = {'action': 'call', 'tool': tool or local_name(), 'input': {} if data is None else data}
        response = self.invoke(arguments, kind='service_prepare', call=call, run=run)
        if response['ok']:
            self.allowed[(run, call)] = bytes.fromhex(response['result']['intents'][0]['bytes_hex'])
        return response

    def execute(self, prepared, *, data=None, call='call-1', run='run-1'):
        return self.invoke({'action': 'call', 'tool': local_name(), 'input': {} if data is None else data,
            'host_plan': {'version': 'process-channel-intent-v1', 'binding': {'protocol_fixture': True},
                          'intents': prepared['result']['intents']}}, call=call, run=run)

    def observed(self):
        return self.record.read_bytes().splitlines(keepends=True)

    def idle(self):
        try:
            value = self.frames.get(timeout=.12)
        except queue.Empty:
            return
        raise AssertionError(f'frame emitted while no actual invocation owns gate: {value}')

    def close(self):
        for process in [self.plugin, self.origin]:
            if process is None:
                continue
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
            for stream in [process.stdin, process.stdout, process.stderr]:
                if stream:
                    try:
                        stream.close()
                    except BrokenPipeError:
                        # A rejected protocol may close stdin before buffered
                        # fixture writes flush. Still close every owned peer.
                        pass
        self.directory.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class NativeMcpClientTests(unittest.TestCase):
    def test_refresh_reuses_real_connection_replaces_map_and_invalidates_prepared(self):
        with Peer('refresh-change') as peer:
            self.assertTrue(peer.start()['ok'])
            old = peer.prepare()
            count = len(peer.events)
            response = peer.refresh()
            self.assertTrue(response['ok'])
            self.assertEqual(response['result']['tools'][0]['name'], local_name('remote.updated:雪'))
            writes = [name for name, _ in peer.events[count:] if name.endswith('.write')]
            self.assertEqual(writes, ['process.channel.refresh.write'])
            self.assertEqual([json.loads(line)['method'] for line in peer.observed()],
                             ['server/discover', 'tools/list', 'tools/list'])
            peer.idle()
            count = len(peer.events)
            self.assertEqual(peer.execute(old)['result']['error'], 'mcp_plugin.prepared_consumed')
            self.assertEqual(peer.prepare(call='old-name')['result']['error'], 'mcp_plugin.tool_unknown')
            self.assertEqual(len(peer.events), count)
            new = peer.prepare(call='new-name', tool=local_name('remote.updated:雪'))
            result = peer.invoke({'action': 'call', 'tool': local_name('remote.updated:雪'), 'input': {},
                'host_plan': {'version': 'process-channel-intent-v1', 'binding': {'protocol_fixture': True},
                              'intents': new['result']['intents']}}, call='new-name')
            self.assertTrue(result['ok'])
            self.assertEqual(json.loads(peer.observed()[-1])['params']['name'], 'remote.updated:雪')
            peer.idle()

    def test_refresh_empty_directory_is_valid_and_malformed_directory_closes_session(self):
        for mode in ('refresh-empty', 'refresh-malformed'):
            with self.subTest(mode=mode), Peer(mode) as peer:
                self.assertTrue(peer.start()['ok'])
                response = peer.refresh()
                if mode == 'refresh-empty':
                    self.assertTrue(response['ok'])
                    self.assertEqual(response['result'], {'tools': []})
                    self.assertEqual(peer.prepare()['result']['error'], 'mcp_plugin.tool_unknown')
                    peer.idle()
                else:
                    self.assertFalse(response['ok'])
                    self.assertEqual(peer.prepare()['result']['error'], 'mcp_plugin.session_closed')
                self.assertEqual(len(peer.observed()), 3)

    def test_configuration_is_strict_bounded_nonsecret_and_validated_before_mcp_io(self):
        values = []
        for key, value in [('version', 2), ('transport', 'http'), ('request_timeout_ms', 0),
                           ('request_timeout_ms', 10001), ('credential', 'operator-secret')]:
            item = configuration()
            item[key] = value
            values.append(item)
        for key, value in [('max_pages', 0), ('max_pages', 9), ('max_tools', 65), ('secret', 'forbidden')]:
            item = configuration()
            item['directory'][key] = value
            values.append(item)
        for config in values:
            with self.subTest(config=config), Peer() as peer:
                reply = peer.invoke({'action': 'start', 'configuration': config}, call='startup', run='maintenance')
                self.assertFalse(reply['ok'])
                self.assertEqual(peer.events, [])
                self.assertEqual(peer.observed(), [])

    def test_changed_configuration_requires_new_start_and_preserves_old_live_map(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            old_events = len(peer.events)
            config = configuration()
            config['request_timeout_ms'] = 1000
            self.assertEqual(peer.refresh(config)['result']['error'], 'mcp_plugin.configuration_changed')
            self.assertEqual(len(peer.events), old_events)
            self.assertTrue(peer.execute(peer.prepare())['ok'])
            peer.idle()

    def test_operator_directory_limits_reject_complete_oversized_catalog(self):
        with Peer('two-pages') as peer:
            config = configuration()
            config['directory']['max_tools'] = 1
            reply = peer.invoke({'action': 'start', 'configuration': config}, call='startup', run='maintenance')
            self.assertFalse(reply['ok'])
            self.assertEqual(reply['result']['error'], 'mcp_plugin.directory_limit')
            self.assertEqual(len(peer.observed()), 3)
            self.assertEqual(peer.prepare()['result']['error'], 'mcp_plugin.session_closed')


    def test_real_discovery_mapping_pure_prepare_and_exact_dispatch(self):
        with Peer() as peer:
            start = peer.start()
            self.assertTrue(start['ok'])
            self.assertEqual(start['result']['tools'][0]['name'], local_name())
            self.assertIn('remote.echo:雪', start['result']['tools'][0]['description'])
            self.assertEqual([json.loads(v)['method'] for v in peer.observed()], ['server/discover', 'tools/list'])
            peer.idle()
            count = len(peer.events)
            data = {'snow': '雪 &=+?#/%\n\\"', 'second': {'b': 2, 'a': 1}}
            prepared = peer.prepare(data=data)
            again = peer.prepare(data={'second': {'a': 1, 'b': 2}, 'snow': data['snow']})
            self.assertTrue(prepared['ok'])
            self.assertEqual(prepared['result'], again['result'])
            self.assertEqual(len(peer.events), count)
            exact_bytes = peer.allowed[('run-1', 'call-1')]
            request = json.loads(exact_bytes)
            expected_id = 'host-' + hashlib.sha256(json.dumps(['thread-1', 'run-1', 3, 'call-1'], separators=(',', ':')).encode()).hexdigest()
            self.assertEqual(request['id'], expected_id)
            self.assertEqual(request['params']['name'], 'remote.echo:雪')
            self.assertEqual(request['params']['arguments'], data)
            result = peer.execute(prepared, data=data)
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['schema'], 'axyndra.service-call-result/v1')
            self.assertEqual(result['result']['status'], 'complete')
            self.assertEqual(result['result']['result']['content'][0]['text'].encode() + b'\n', exact_bytes)
            self.assertEqual(peer.observed()[-1], exact_bytes)
            peer.idle()
            next_call = peer.prepare(call='call-2', run='run-2')
            self.assertTrue(peer.execute(next_call, call='call-2', run='run-2')['ok'])
            peer.idle()

    def test_empty_directory_keeps_real_service_without_fake_tool(self):
        with Peer('empty') as peer:
            response = peer.start()
            self.assertTrue(response['ok'])
            self.assertEqual(response['result'], {'tools': []})
            count = len(peer.events)
            self.assertEqual(peer.prepare()['result']['error'], 'mcp_plugin.tool_unknown')
            self.assertEqual(len(peer.events), count)
            peer.idle()

    def test_changed_input_intent_and_cross_run_cannot_dispatch(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare(data={'value': 1})
            before = len(peer.observed())
            self.assertEqual(peer.prepare(data={'value': 2})['result']['error'], 'mcp_plugin.prepared_identity_conflict')
            self.assertEqual(peer.execute(prepared, data={'value': 2})['result']['error'], 'mcp_plugin.prepared_identity_conflict')
            self.assertEqual(peer.execute(prepared, data={'value': 1}, run='forged-run')['result']['error'], 'mcp_plugin.prepared_missing')
            tampered = json.loads(json.dumps(prepared))
            tampered['result']['intents'][0]['bytes_hex'] += '20'
            self.assertEqual(peer.execute(tampered, data={'value': 1})['result']['error'], 'mcp_plugin.intent_mismatch')
            self.assertEqual(len(peer.observed()), before)
            self.assertTrue(peer.execute(prepared, data={'value': 1})['ok'])
            self.assertEqual(peer.execute(prepared, data={'value': 1})['result']['error'], 'mcp_plugin.prepared_consumed')
            self.assertEqual(peer.prepare(data={'value': 1})['result']['error'], 'mcp_plugin.prepared_consumed')

    def test_task_required_explicitly_rejected_before_io(self):
        with Peer('required-task') as peer:
            self.assertTrue(peer.start()['ok'])
            count = len(peer.events)
            self.assertEqual(peer.prepare()['result']['error'], 'mcp_plugin.tasks_unsupported')
            self.assertEqual(len(peer.events), count)

    def test_input_required_is_preserved_without_automatic_continuation(self):
        with Peer('input') as peer:
            self.assertTrue(peer.start()['ok'])
            result = peer.execute(peer.prepare())
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'mcp_plugin.input_required_unsupported')
            self.assertEqual(result['result']['status'], 'input_required')
            self.assertEqual(result['result']['result']['resultType'], 'input_required')
            self.assertEqual(len(peer.observed()), 3)
            peer.idle()

    def test_business_error_is_a_complete_exchange(self):
        with Peer('business-error') as peer:
            self.assertTrue(peer.start()['ok'])
            result = peer.execute(peer.prepare())
            self.assertFalse(result['ok'])
            self.assertTrue(result['result']['result']['isError'])
            self.assertEqual(result['result']['status'], 'complete')
            self.assertEqual(result['result']['result']['resultType'], 'complete')
            peer.idle()

    def test_disconnect_after_write_is_unknown_and_never_retried(self):
        with Peer('eof') as peer:
            self.assertTrue(peer.start()['ok'])
            result = peer.execute(peer.prepare())
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'mcp_plugin.call_outcome_unknown')
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertFalse(result['result']['retry_safe'])
            self.assertEqual(len(peer.observed()), 3)
            self.assertEqual(peer.prepare(call='again')['result']['error'], 'mcp_plugin.session_closed')

    def test_timeout_after_write_is_unknown_and_never_retried(self):
        with Peer('hang') as peer:
            self.assertTrue(peer.start()['ok'])
            started = time.monotonic()
            result = peer.execute(peer.prepare())
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertLess(time.monotonic() - started, 14)
            self.assertEqual(len(peer.observed()), 3)

    def test_missing_active_write_receipt_cannot_report_complete(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            peer.omit_receipt = True
            result = peer.execute(peer.prepare())
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertEqual(len(peer.observed()), 3)

    def test_cancellation_aborts_session_without_unapproved_cancel_write(self):
        with Peer('hang') as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            frame = peer.invocation({'action': 'call', 'tool': local_name(), 'input': {},
                'host_plan': {'version': 'process-channel-intent-v1', 'binding': {}, 'intents': prepared['result']['intents']}})
            peer.current = frame
            peer.send(frame)
            while True:
                request = peer.next()
                self.assertEqual(request['type'], 'service_request')
                if peer.answer(request) == 'process.channel.write':
                    break
            cancelled = {key: frame[key] for key in IDENTITY}
            cancelled['type'] = 'cancel'
            started = time.monotonic()
            peer.send(cancelled)
            while True:
                response = peer.next(2)
                if response['type'] == 'cancelled':
                    break
                self.assertEqual(response['type'], 'service_request')
                self.assertEqual(response['service'], 'process.channel.read')
                peer.answer(response)
            self.assertLess(time.monotonic() - started, 2)
            # No MCP notifications/cancelled frame is authorized by the frozen
            # tools/call bytes. Host cancellation owns process cleanup.
            self.assertEqual(len(peer.observed()), 3)
            self.assertEqual(peer.prepare(call='after-cancel')['result']['error'], 'mcp_plugin.session_closed')

    def test_service_error_is_never_idle_or_eof(self):
        with Peer() as peer:
            response = peer.invoke({'action': 'start', 'configuration': configuration()}, call='startup', run='maintenance', fail_services=True)
            self.assertFalse(response['ok'])
            self.assertEqual(peer.observed(), [])
            self.assertEqual(peer.prepare()['result']['error'], 'mcp_plugin.session_closed')

    def test_wrong_service_identity_poison_closes_protocol(self):
        with Peer() as peer:
            frame = peer.invocation({'action': 'start', 'configuration': configuration()}, call='startup', run='maintenance')
            peer.current = frame
            peer.send(frame)
            first = peer.next(3)
            self.assertEqual(first['type'], 'service_request')
            peer.poison_response = True
            peer.answer(first)
            # Two pipe readers may already have queued requests. After the
            # poison, never answer them or perform more backend I/O; observe
            # strict EOF with no terminal result emitted during shutdown.
            deadline = time.monotonic() + 3
            with self.assertRaises(EOFError):
                while True:
                    message = peer.next(max(.01, deadline - time.monotonic()))
                    self.assertEqual(message['type'], 'service_request', message)
                    self.assertLess(time.monotonic(), deadline)
            peer.plugin.wait(timeout=3)
            self.assertEqual(peer.plugin.returncode, 3)
            self.assertLessEqual(len(peer.observed()), 1)

    def test_fake_operation_in_pure_prepare_is_protocol_rejected(self):
        with Peer() as peer:
            frame = peer.invocation({'action': 'call', 'tool': local_name(), 'input': {}}, kind='service_prepare')
            frame['operation_id'] = 'invented-authority'
            peer.send(frame)
            with self.assertRaises(EOFError):
                peer.next(3)
            self.assertEqual(peer.observed(), [])

    def test_oversized_rpc_response_is_unknown_not_success(self):
        with Peer('oversize') as peer:
            self.assertTrue(peer.start()['ok'])
            response = peer.execute(peer.prepare())
            self.assertFalse(response['ok'])
            self.assertEqual(response['result']['error'], 'mcp_plugin.call_outcome_unknown')
            self.assertEqual(len(peer.observed()), 3)

    def test_two_page_directory_preserves_metadata_and_exact_second_tool(self):
        with Peer('two-pages') as peer:
            response = peer.start()
            self.assertTrue(response['ok'])
            self.assertEqual([tool['name'] for tool in response['result']['tools']],
                [local_name(), local_name('remote.second:雪')])
            requests = [json.loads(frame) for frame in peer.observed()]
            self.assertEqual([request['method'] for request in requests],
                ['server/discover', 'tools/list', 'tools/list'])
            self.assertEqual(requests[1].get('params', {}).get('cursor', ''), '')
            self.assertEqual(requests[2]['params']['cursor'], 'page-two')
            self.assertEqual(sum(service == 'process.channel.startup.write' for service, _ in peer.events), 3)
            peer.idle()
            prepared = peer.prepare(tool=local_name('remote.second:雪'))
            self.assertTrue(prepared['ok'])
            exact_bytes = peer.allowed[('run-1', 'call-1')]
            self.assertEqual(json.loads(exact_bytes)['params']['name'], 'remote.second:雪')
            result = peer.invoke({'action': 'call', 'tool': local_name('remote.second:雪'), 'input': {},
                'host_plan': {'version': 'process-channel-intent-v1', 'binding': {},
                              'intents': prepared['result']['intents']}})
            self.assertTrue(result['ok'])
            self.assertEqual(peer.observed()[-1], exact_bytes)
            self.assertEqual(len(peer.observed()), 4)

    def assert_directory_metadata_change_rejected(self, mode):
        with Peer(mode) as peer:
            response = peer.start()
            self.assertFalse(response['ok'])
            self.assertEqual(response['result'], {'error': 'mcp_plugin.directory_metadata_changed'})
            self.assertNotIn('tools', response['result'])
            self.assertEqual([json.loads(frame)['method'] for frame in peer.observed()],
                ['server/discover', 'tools/list', 'tools/list'])
            self.assertEqual(sum(service == 'process.channel.startup.write' for service, _ in peer.events), 3)
            before = len(peer.events)
            self.assertEqual(peer.prepare()['result']['error'], 'mcp_plugin.session_closed')
            self.assertEqual(peer.prepare(tool=local_name('remote.second:雪'))['result']['error'],
                'mcp_plugin.session_closed')
            self.assertEqual(len(peer.events), before)
            self.assertEqual(len(peer.observed()), 3)
            peer.idle()

    def test_changed_directory_ttl_rejects_entire_startup(self):
        self.assert_directory_metadata_change_rejected('ttl-change')

    def test_changed_directory_scope_rejects_entire_startup(self):
        self.assert_directory_metadata_change_rejected('scope-change')

    def test_long_valid_responses_survive_gc_while_protocol_input_is_idle(self):
        with Peer('large') as peer:
            self.assertTrue(peer.start()['ok'])
            # Each invocation allocates an 8 KiB request and a 48 KiB response.
            # The control reader waits for host input while MCP workers decode
            # them; unlike ConsoleReader, the fd reader must permit GC progress.
            for index in range(24):
                with self.subTest(iteration=index):
                    call = f'gc-pressure-{index}'
                    data = {'padding': 'q' * 8192, 'sequence': index}
                    prepared = peer.prepare(data=data, call=call)
                    self.assertTrue(prepared['ok'])
                    exact_bytes = peer.allowed[('run-1', call)]
                    response = peer.execute(prepared, data=data, call=call)
                    self.assertTrue(response['ok'])
                    self.assertEqual(response['result']['status'], 'complete')
                    self.assertEqual(response['result']['result']['content'], [{'type': 'text', 'text': 'x' * 48000}])
                    self.assertEqual(peer.observed()[-1], exact_bytes)
            self.assertEqual(len(peer.observed()), 26)
            self.assertEqual(sum(service == 'process.channel.write' for service, _ in peer.events), 24)
            peer.idle()

    def test_repeated_oversize_responses_always_settle_unknown_without_retry(self):
        # A failed session cannot be reused. Exercise fresh actual processes,
        # retaining the same 15-second invocation deadline on every iteration.
        for index in range(12):
            with self.subTest(iteration=index), Peer('oversize') as peer:
                self.assertTrue(peer.start()['ok'])
                data = {'padding': 'q' * 8192, 'sequence': index}
                prepared = peer.prepare(data=data)
                self.assertTrue(prepared['ok'])
                exact_bytes = peer.allowed[('run-1', 'call-1')]
                response = peer.execute(prepared, data=data)
                self.assertFalse(response['ok'])
                self.assertEqual(response['result']['status'], 'unknown')
                self.assertEqual(response['result']['error'], 'mcp_plugin.call_outcome_unknown')
                self.assertFalse(response['result']['retry_safe'])
                self.assertEqual(peer.observed()[-1], exact_bytes)
                self.assertEqual(len(peer.observed()), 3)
                self.assertEqual(sum(service == 'process.channel.write' for service, _ in peer.events), 1)
                self.assertEqual(peer.prepare(call='forbidden-retry')['result']['error'], 'mcp_plugin.session_closed')
                self.assertEqual(len(peer.observed()), 3)

    def test_repeated_directory_cursor_fails_explicitly(self):
        with Peer('cursor-loop') as peer:
            result = peer.start()
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'mcp_plugin.directory_cursor_repeated')
            self.assertEqual(len(peer.observed()), 3)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve(strict=True)
    if sys.platform != 'linux':
        parser.error('real stdio process contracts require Linux')
    sys.modules["check"] = sys.modules[__name__]
    import check_capacity
    CapacityTests = check_capacity.CapacityTests
    import check_payload
    PayloadTests = check_payload.PayloadTests
    import check_http
    check_http.BINARY = BINARY
    NativeMcpHttpTests = check_http.NativeMcpHttpTests
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)

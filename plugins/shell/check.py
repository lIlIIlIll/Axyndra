#!/usr/bin/env python3
"""Actual packaged native plugin + real stdio peer; host broker is a protocol fixture.

This proves plugin protocol/session behavior, not Product/SQLite authorization.
The protocol fixture is not proof of Product/SQLite authorization or sandboxing.
"""
import argparse
import base64
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
BACKEND = None

def configuration():
    return {'version': 1, 'request_timeout_ms': 10000}

def local_name():
    return 'bash'

class Peer:
    def __init__(self, mode='echo'):
        self.directory = tempfile.TemporaryDirectory(prefix='shell-plugin-protocol-')
        self.record = Path(self.directory.name) / 'requests.jsonl'
        self.record.touch()
        self.origin = None
        self.plugin = None
        try:
            self.origin = subprocess.Popen([sys.executable, '-u', str(BACKEND),
                '--workspace', self.directory.name, *(['--readonly'] if mode == 'readonly' else []), *(['--stream-output'] if mode == 'artifact' else [])],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.plugin = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.frames = queue.Queue()
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
            self.channel_read_maximum = 32768
            self.poison_channel_base64 = None
            self.channel_reads = []
            self.artifact_streams = {}
            self.artifact_values = {}
            self.encoded_artifact_chunks = 0
            self.poison_artifact = False
            self.omit_receipt = False
            self.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'shell',
                'extension_version': '1.1.0', 'generation': 7, 'capabilities': ['process.channel']})
            ready = self.next(3)
            assert ready['type'] == 'ready' and ready['tools'] == [] and ready['services'][0]['name'] == 'session'
            assert ready['services'][0]['supports_preparation_reference'] is True
        except BaseException:
            self.close()
            raise

    def _read(self):
        try:
            for line in self.plugin.stdout:
                if len(line) > 262145 or not line.endswith(b'\n'):
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
        self.plugin.stdin.write((json.dumps(frame, ensure_ascii=False, separators=(',', ':')) + '\n').encode())
        self.plugin.stdin.flush()

    def next(self, timeout=15):
        value = self.frames.get(timeout=timeout)
        if isinstance(value, BaseException):
            raise value
        return value

    def invocation(self, arguments, *, kind='service', call='call-1', run='run-1', thread='thread-1'):
        self.counter += 1
        return {'type': 'invoke', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'shell',
            'extension_version': '1.1.0', 'generation': 7, 'id': f'invoke-{self.counter}', 'tool': 'session',
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
            assert set(args) == {'stream', 'max_bytes', 'wait_ms', 'encoding'}
            assert args['encoding'] == 'base64'
            assert args['stream'] in ('stdout', 'stderr') and args['max_bytes'] == 32768 and 0 <= args['wait_ms'] <= 1000
            if self.current['arguments']['action'] == 'refresh':
                assert args['wait_ms'] <= 25, 'real refresh has a separate Host read bound'
            stream = self.origin.stdout if args['stream'] == 'stdout' else self.origin.stderr
            with selectors.DefaultSelector() as poll:
                poll.register(stream, selectors.EVENT_READ)
                data = os.read(stream.fileno(), min(args['max_bytes'], self.channel_read_maximum)) if poll.select(args['wait_ms'] / 1000) else None
            self.channel_reads.append(data)
            encoded = base64.b64encode(data or b'').decode('ascii')
            if self.poison_channel_base64 is not None and args['stream'] == 'stdout':
                encoded = self.poison_channel_base64
            response['result'] = {'bytes_base64': encoded, 'eof': data == b''}
        elif service in ('process.channel.startup.write', 'process.channel.refresh.write'):
            expected_action = 'start' if service == 'process.channel.startup.write' else 'refresh'
            assert self.current['arguments']['action'] == expected_action and set(args) == {'bytes_hex'}
            data = bytes.fromhex(args['bytes_hex'])
            assert 0 < len(data) <= 30720
            with self.record.open('ab') as record:
                record.write(data)
            self.origin.stdin.write(data)
            self.origin.stdin.flush()
            response['result'] = {'written_bytes': len(data)}
        elif service == 'output.artifact':
            assert self.current['arguments']['action'] == 'call'
            assert self.current['kind'] == 'service' and self.current['operation_id']
            key = (self.current['run_id'], self.current['call_id'], args['stream'])
            action = args['action']
            if action == 'begin':
                assert set(args) == {'action', 'stream', 'bytes', 'sha256'} and key not in self.artifact_streams
                assert 0 <= args['bytes'] <= 16777216
                self.artifact_streams[key] = [args['bytes'], args['sha256'], bytearray()]
                response['result'] = {'accepted_bytes': args['bytes']}
            elif action == 'append':
                field = 'data_base64' if 'data_base64' in args else 'text'
                assert set(args) == {'action', 'stream', 'offset', field}
                maximum, digest, data = self.artifact_streams[key]
                assert len(data) == args['offset']
                if field == 'data_base64':
                    raw = base64.b64decode(args[field], validate=True)
                    assert base64.b64encode(raw).decode('ascii') == args[field]
                    raw.decode('utf-8')
                    self.encoded_artifact_chunks += 1
                else:
                    raw = args['text'].encode()
                assert 0 < len(raw) <= 16384 and len(raw) <= maximum - len(data)
                data.extend(raw)
                response['result'] = {'next_offset': len(data)}
            else:
                assert action == 'finish' and set(args) == {'action', 'stream'}
                maximum, digest, data = self.artifact_streams[key]
                assert len(data) == maximum and hashlib.sha256(data).hexdigest() == digest
                self.artifact_values[key] = bytes(data)
                response['result'] = {'artifact': {'stream': args['stream'], 'ref': 'blob:sha256:' + digest,
                    'sha256': digest, 'bytes': maximum, 'content_type': 'text/plain; charset=utf-8'},
                    'preview': bytes(data[:8192]).decode('utf-8', errors='ignore'), 'truncated': maximum > 8192}
                if self.poison_artifact:
                    response['result']['artifact']['sha256'] = '0' * 64
        elif service == 'process.channel.write':
            assert set(args) == {'intent_id'} and args['intent_id'] == 'shell-call'
            data = self.allowed.pop((self.current['run_id'], self.current['call_id']))
            with self.record.open('ab') as record:
                record.write(data)
            self.origin.stdin.write(data)
            self.origin.stdin.flush()
            response['result'] = {'written_bytes': len(data), 'receipt_id': 'fixture-receipt-completed'}
            if self.omit_receipt:
                del response['result']['receipt_id']
        else:
            raise AssertionError(f'plugin requested unsupported service {service}')
        self.send(response)
        return service

    def invoke(self, arguments, *, kind='service', call='call-1', run='run-1', thread='thread-1', fail_services=False):
        frame = self.invocation(arguments, kind=kind, call=call, run=run, thread=thread)
        self.current = frame
        self.send(frame)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            message = self.next(max(.01, deadline - time.monotonic()))
            if message['type'] == 'service_request':
                assert kind != 'service_prepare', 'pure preparation performed I/O'
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

    def execute(self, prepared, *, data=None, call='call-1', run='run-1', tool=None):
        return self.invoke({'action': 'call', 'tool': tool or local_name(), 'input': {} if data is None else data,
            'host_plan': {'version': 'process-channel-intent-v1', 'binding': {'protocol_fixture': True},
                          'intents': prepared['result']['intents']}}, call=call, run=run)

    def managed_arguments(self, prepared, data, *, child_run='task-run', child_thread='task-thread', reference=None):
        reference = reference or {'thread_id': 'thread-1', 'run_id': 'run-1', 'epoch': 3, 'call_id': 'call-1'}
        return {'action': 'call', 'tool': local_name(), 'input': data, 'preparation_ref': reference,
            'host_plan': {'version': 'process-channel-intent-v1', 'binding': {'protocol_fixture': True, 'target_thread_id': 'thread-1'},
                'intents': prepared['result']['intents'], 'managed_job': {'schema': 'axyndra.managed-job/v1',
                    'job_id': 'host-job', 'thread_id': child_thread, 'run_id': child_run,
                    'deadline_ms': int(time.time() * 1000) + 10000, 'max_tool_calls': 2}}}

    def execute_managed(self, prepared, data, *, child_run='task-run', child_thread='task-thread', arguments=None):
        self.allowed[(child_run, 'call-1')] = bytes.fromhex(prepared['result']['intents'][0]['bytes_hex'])
        return self.invoke(arguments or self.managed_arguments(prepared, data, child_run=child_run, child_thread=child_thread),
            call='call-1', run=child_run, thread=child_thread)

    def observed(self):
        return self.record.read_bytes().splitlines(keepends=True)

    def idle(self):
        try:
            value = self.frames.get(timeout=.12)
        except queue.Empty:
            return
        raise AssertionError(f'frame emitted while no actual invocation owns gate: {value}')

    def close(self):
        # Each actual backend owns and joins its Bash group on EOF/TERM.
        # This fixture does not emulate the Product namespace authority.
        if self.plugin is not None:
            if self.plugin.poll() is None:
                self.plugin.kill()
            self.plugin.wait(timeout=3)
        if self.origin is not None:
            try:
                self.origin.stdin.close()
            except BrokenPipeError:
                pass
            try:
                self.origin.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.origin.terminate()
                self.origin.wait(timeout=3)
        for attribute in ('reader', 'error_reader'):
            if hasattr(self, attribute):
                worker = getattr(self, attribute)
                worker.join(timeout=3)
                assert not worker.is_alive(), 'owned native reader did not join'
        for process in (self.plugin, self.origin):
            if process is not None:
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        try:
                            stream.close()
                        except BrokenPipeError:
                            pass
        self.directory.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class NativeShellTests(unittest.TestCase):
    def test_binary_base64_channel_reassembles_real_backend_utf8_one_byte_at_a_time(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            peer.channel_read_maximum = 1
            peer.channel_reads.clear()
            data = {'command': "printf '雪'; printf '\\001'"}
            prepared = peer.prepare(data=data)
            reply = peer.execute(prepared, data=data)
            self.assertTrue(reply['ok'], reply)
            self.assertEqual(reply['result']['result']['stdout'], '雪\x01')
            for byte in '雪'.encode():
                self.assertIn(bytes([byte]), peer.channel_reads)
            self.assertTrue(all(value is None or len(value) <= 1 for value in peer.channel_reads))
            self.assertEqual(len([name for name, _ in peer.events if name == 'process.channel.write']), 1)

    def test_malformed_channel_base64_cannot_publish_success_or_repeat_the_write(self):
        for encoded in ('AB==', 'AA=A', '__8=', 'A' * 43692):
            with self.subTest(encoded_size=len(encoded)), Peer() as peer:
                self.assertTrue(peer.start()['ok'])
                data = {'command': 'printf once >> count.txt'}
                prepared = peer.prepare(data=data)
                peer.poison_channel_base64 = encoded
                reply = peer.execute(prepared, data=data)
                self.assertFalse(reply['ok'])
                self.assertEqual(reply['result']['status'], 'unknown')
                self.assertFalse(reply['result']['retry_safe'])
                writes = len([name for name, _ in peer.events if name == 'process.channel.write'])
                self.assertEqual(writes, 1)
                self.assertFalse(peer.execute(prepared, data=data)['ok'])
                self.assertEqual(len([name for name, _ in peer.events if name == 'process.channel.write']), writes)

    def test_real_refresh_uses_bounded_base64_reads_and_invalidates_old_preparation(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'printf frozen'}
            old = peer.prepare(data=data)
            self.assertTrue(old['ok'])
            before = len(peer.events)
            self.assertTrue(peer.refresh()['ok'])
            reads = [args for name, args in peer.events[before:] if name == 'process.channel.read']
            self.assertTrue(any(args['stream'] == 'stdout' for args in reads))
            self.assertTrue(all(args['encoding'] == 'base64' and args['wait_ms'] <= 25 for args in reads))
            self.assertEqual([json.loads(row)['action'] for row in peer.observed()], ['discover', 'discover'])
            after = len(peer.events)
            self.assertFalse(peer.execute(old, data=data)['ok'])
            self.assertEqual(len(peer.events), after)
            fresh = peer.prepare(data=data, call='new-after-refresh')
            self.assertTrue(fresh['ok'])
            reply = peer.execute(fresh, data=data, call='new-after-refresh')
            self.assertTrue(reply['ok'], reply)
            self.assertEqual(reply['result']['result']['stdout'], 'frozen')
            active_reads = [args for name, args in peer.events[after:] if name == 'process.channel.read' and args['stream'] == 'stdout']
            self.assertTrue(active_reads)
            self.assertTrue(all(args['wait_ms'] == 1000 for args in active_reads))
            self.assertEqual(len([name for name, _ in peer.events if name == 'process.channel.write']), 1)
            after = len(peer.events)
            changed = configuration(); changed['request_timeout_ms'] += 1
            self.assertFalse(peer.refresh(changed)['ok'])
            self.assertEqual(len(peer.events), after)
            peer.idle()

    def test_static_native_handshake_and_real_discovery_have_no_idle_traffic(self):
        with Peer() as peer:
            result = peer.start()
            self.assertTrue(result['ok'])
            self.assertEqual([tool['name'] for tool in result['result']['tools']], ['bash'])
            self.assertEqual([json.loads(row)['action'] for row in peer.observed()], ['discover'])
            peer.idle()

    def test_pure_prepare_exact_write_receipt_and_persistent_backend(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'export SHELL_SAMPLE=kept; printf first'}
            before = len(peer.events)
            prepared = peer.prepare(data=data)
            self.assertTrue(prepared['ok']); self.assertEqual(len(peer.events), before)
            result = peer.execute(prepared, data=data)
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['result']['result']['stdout'], 'first')
            self.assertFalse(result['result']['retry_safe'])
            data = {'command': 'printf "$SHELL_SAMPLE"'}
            prepared = peer.prepare(data=data, call='second')
            self.assertEqual(peer.execute(prepared, data=data, call='second')['result']['result']['stdout'], 'kept')
            self.assertEqual(len([name for name, _ in peer.events if name == 'process.channel.write']), 2)
            peer.idle()

    def test_changed_prepared_bytes_and_other_run_cannot_write(self):
        for mode in ('bytes', 'arguments', 'run'):
            with Peer() as peer:
                self.assertTrue(peer.start()['ok'])
                data = {'command': 'printf literal'}
                prepared = peer.prepare(data=data)
                if mode == 'bytes':
                    prepared['result']['intents'][0]['bytes_hex'] += '20'
                if mode == 'arguments':
                    data['command'] = 'printf changed'
                before = len(peer.events)
                result = peer.execute(prepared, data=data, run='other' if mode == 'run' else 'run-1')
                self.assertFalse(result['ok'])
                self.assertEqual(len(peer.events), before)
                self.assertEqual(len(peer.observed()), 1)

    def test_completed_call_cannot_be_prepared_or_dispatched_twice(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'printf once'}
            prepared = peer.prepare(data=data)
            self.assertTrue(peer.execute(prepared, data=data)['ok'])
            before = len(peer.events)
            self.assertFalse(peer.prepare(data=data)['ok'])
            self.assertFalse(peer.execute(prepared, data=data)['ok'])
            self.assertEqual(len(peer.events), before)
            self.assertEqual(len(peer.observed()), 2)

    def test_absent_write_receipt_never_becomes_completed_outcome(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'printf effect'}
            prepared = peer.prepare(data=data)
            peer.omit_receipt = True
            result = peer.execute(prepared, data=data)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertFalse(result['result']['retry_safe'])

    def test_readonly_backend_and_no_unowned_async_job(self):
        with Peer(mode='readonly') as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'touch forbidden'}
            prepared = peer.prepare(data=data, tool='bash_readonly', call='rejected-write')
            result = peer.execute(prepared, data=data, tool='bash_readonly', call='rejected-write')
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'complete')
            data = {'command': 'printf x', 'async': True}
            prepared = peer.prepare(data=data, tool='bash_readonly', call='unowned')
            self.assertEqual(prepared['result']['managed_job'], {'timeout_ms': 10000})
            before = len(peer.events)
            result = peer.execute(prepared, data=data, tool='bash_readonly', call='unowned')
            self.assertFalse(result['ok'])
            self.assertEqual(len(peer.events), before)
            self.assertFalse((Path(peer.directory.name) / 'forbidden').exists())

    def test_actual_large_stream_uses_only_host_observed_artifact_reference(self):
        peer = Peer('artifact')
        try:
            self.assertTrue(peer.start()['ok'])
            data = {'command': "/usr/bin/python3 -c 'print(\"雪\"*100000,end=\"\")'"}
            prepared = peer.prepare(data=data)
            self.assertTrue(prepared['ok'])
            reply = peer.execute(prepared, data=data)
            self.assertTrue(reply['ok'], reply)
            output = reply['result']['result']
            raw = ('雪' * 100000).encode()
            self.assertEqual(peer.artifact_values[('run-1', 'call-1', 'stdout')], raw)
            self.assertEqual(output['artifacts'][0]['sha256'], hashlib.sha256(raw).hexdigest())
            self.assertLessEqual(len(output['stdout'].encode()), 4096)
            self.assertTrue(output['truncated'])
        finally:
            peer.close()

    def test_escaped_control_stream_keeps_exact_host_artifact_and_original_request_quota(self):
        with Peer('artifact') as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'head -c 1048576 /dev/zero'}
            reply = peer.execute(peer.prepare(data=data), data=data)
            self.assertTrue(reply['ok'], reply)
            raw = b'\0' * 1048576
            self.assertEqual(peer.artifact_values[('run-1', 'call-1', 'stdout')], raw)
            self.assertEqual(peer.encoded_artifact_chunks, 64)
            self.assertEqual(reply['result']['result']['artifacts'][0]['sha256'], hashlib.sha256(raw).hexdigest())
            self.assertLess(len(peer.events), 4096)

    def test_forged_host_artifact_ack_is_not_a_successful_shell_completion(self):
        peer = Peer('artifact')
        try:
            self.assertTrue(peer.start()['ok'])
            peer.poison_artifact = True
            data = {'command': 'head -c 16000 /dev/zero'}
            reply = peer.execute(peer.prepare(data=data), data=data)
            self.assertFalse(reply['ok'])
            self.assertEqual(reply['result']['status'], 'unknown')
        finally:
            peer.close()

    def test_managed_child_uses_frozen_original_bytes_with_actual_child_identity(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'printf task-output > task.txt; printf task-output', 'async': True}
            before = len(peer.events)
            prepared = peer.prepare(data=data)
            repeated = peer.prepare(data=dict(data))
            self.assertEqual(prepared['result'], repeated['result'])
            self.assertEqual(len(peer.events), before)
            self.assertFalse((Path(peer.directory.name) / 'task.txt').exists())
            actual = peer.execute_managed(prepared, data)
            self.assertTrue(actual['ok'], actual)
            self.assertEqual(actual['thread_id'], 'task-thread')
            self.assertEqual(actual['run_id'], 'task-run')
            self.assertEqual(actual['result']['result']['stdout'], 'task-output')
            self.assertEqual((Path(peer.directory.name) / 'task.txt').read_text(), 'task-output')
            request = json.loads(peer.observed()[-1])
            self.assertFalse(request['input']['async'])
            self.assertEqual(peer.observed()[-1], bytes.fromhex(prepared['result']['intents'][0]['bytes_hex']))

    def test_each_original_identity_field_is_required_without_effect(self):
        for field, changed in [('thread_id', 'wrong-thread'), ('run_id', 'wrong-run'), ('epoch', 4), ('call_id', 'wrong-call')]:
            with self.subTest(field=field), Peer() as peer:
                self.assertTrue(peer.start()['ok'])
                data = {'command': 'touch never-created', 'async': True}
                prepared = peer.prepare(data=data)
                args = peer.managed_arguments(prepared, data)
                args['preparation_ref'][field] = changed
                before = len(peer.events)
                self.assertFalse(peer.execute_managed(prepared, data, arguments=args)['ok'])
                self.assertEqual(len(peer.events), before)
                self.assertFalse((Path(peer.directory.name) / 'never-created').exists())

    def test_changed_child_plan_or_input_cannot_reuse_reference(self):
        for mode in ('bytes', 'input', 'tool', 'child-run', 'child-thread'):
            with self.subTest(mode=mode), Peer() as peer:
                self.assertTrue(peer.start()['ok'])
                data = {'command': 'touch never-created', 'async': True}
                prepared = peer.prepare(data=data)
                args = peer.managed_arguments(prepared, dict(data))
                if mode == 'bytes':
                    args['host_plan']['intents'] = [dict(args['host_plan']['intents'][0])]
                    args['host_plan']['intents'][0]['bytes_hex'] += '20'
                elif mode == 'input': args['input']['command'] = 'printf changed'
                elif mode == 'tool': args['tool'] = 'other'
                else: args['host_plan']['managed_job'][mode.replace('child-', '') + '_id'] = 'other'
                before = len(peer.events)
                self.assertFalse(peer.execute_managed(prepared, data, arguments=args)['ok'])
                self.assertEqual(len(peer.events), before)
                self.assertFalse((Path(peer.directory.name) / 'never-created').exists())

    def test_managed_reference_is_consumed_exactly_once(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'printf once >> count.txt', 'async': True}
            prepared = peer.prepare(data=data)
            self.assertTrue(peer.execute_managed(prepared, data)['ok'])
            before = len(peer.events)
            self.assertFalse(peer.execute_managed(prepared, data, child_run='task-again')['ok'])
            self.assertFalse(peer.prepare(data=data)['ok'])
            self.assertEqual(len(peer.events), before)
            self.assertEqual((Path(peer.directory.name) / 'count.txt').read_text(), 'once')

    def test_managed_write_without_actual_receipt_remains_unknown(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'printf observed', 'async': True}
            prepared = peer.prepare(data=data)
            peer.omit_receipt = True
            result = peer.execute_managed(prepared, data)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertFalse(result['result']['retry_safe'])

    def test_real_backend_timeout_reports_unknown_without_retry(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'command': 'sleep 3', 'timeout': 1}
            prepared = peer.prepare(data=data)
            result = peer.execute(prepared, data=data)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertFalse(result['result']['retry_safe'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    arguments, remaining = parser.parse_known_args()
    BINARY = arguments.binary.resolve(strict=True)
    BACKEND = (BINARY.parent.parent / 'backend/shell_backend.py').resolve(strict=True)
    if not BACKEND.is_relative_to(BINARY.parent.parent):
        raise ValueError('backend must belong to the actual packaged endpoint')
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)

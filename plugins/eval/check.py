#!/usr/bin/env python3
"""Actual packaged Eval native endpoint + packaged Python runner; fixture broker only.

This proves plugin protocol/session behavior, not Product/SQLite authorization.
Interpreter state and cell execution are real. Product authority is verified separately.
"""
import argparse
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
RUNNER = None

def configuration():
    return {'version': 1, 'language': 'py', 'max_timeout_ms': 30000}

def local_name():
    return 'eval'

def cell(code='1 + 1', **extra):
    return dict(language='py', code=code, **extra)


class Peer:
    def __init__(self):
        self.directory = tempfile.TemporaryDirectory(prefix='eval-plugin-protocol-')
        self.record = Path(self.directory.name) / 'requests.jsonl'
        self.record.touch()
        self.origin = None
        self.plugin = None
        try:
            self.origin = subprocess.Popen([sys.executable, '-u', str(RUNNER)],
                cwd=self.directory.name, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
            self.omit_receipt = False
            self.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'eval',
                'extension_version': '1.0.0', 'generation': 7, 'capabilities': ['process.channel']})
            ready = self.next(3)
            assert ready['type'] == 'ready' and ready['tools'] == [] and ready['services'][0]['name'] == 'session'
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
        return {'type': 'invoke', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'eval',
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
            with self.record.open('ab') as record:
                record.write(data)
            self.origin.stdin.write(data)
            self.origin.stdin.flush()
            response['result'] = {'written_bytes': len(data)}
        elif service == 'process.channel.write':
            assert set(args) == {'intent_id'} and args['intent_id'] == 'eval-call'
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

    def invoke(self, arguments, *, kind='service', call='call-1', run='run-1', fail_services=False):
        frame = self.invocation(arguments, kind=kind, call=call, run=run)
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
        arguments = {'action': 'call', 'tool': tool or local_name(), 'input': cell() if data is None else data}
        response = self.invoke(arguments, kind='service_prepare', call=call, run=run)
        if response['ok']:
            self.allowed[(run, call)] = bytes.fromhex(response['result']['intents'][0]['bytes_hex'])
        return response

    def execute(self, prepared, *, data=None, call='call-1', run='run-1', tool=None):
        return self.invoke({'action': 'call', 'tool': tool or local_name(), 'input': cell() if data is None else data,
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
        # Tests execute only the packaged interpreter itself. No test here forks
        # children; the separate Product cancellation case proves namespace cleanup.
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


class NativeEvalTests(unittest.TestCase):
    def test_readiness_is_real_runner_and_startup_writes_nothing(self):
        with Peer() as peer:
            value = peer.start()
            self.assertTrue(value['ok'], value)
            self.assertEqual([tool['name'] for tool in value['result']['tools']], ['eval'])
            self.assertEqual(value['result']['tools'][0]['input_schema']['properties']['language']['enum'], ['py'])
            self.assertTrue(any(name == 'process.channel.read' for name, _ in peer.events))
            self.assertEqual(peer.observed(), [])
            peer.idle()

    def test_pure_prepare_freezes_actual_cell_without_any_io(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            before = len(peer.events)
            data = cell("print('雪|literal\\n$()')", title='literal title')
            prepared = peer.prepare(data=data)
            self.assertTrue(prepared['ok'], prepared)
            self.assertEqual(len(peer.events), before)
            self.assertEqual(peer.observed(), [])
            raw = bytes.fromhex(prepared['result']['intents'][0]['bytes_hex'])
            self.assertEqual(raw, b'30000|0|' + data['code'].encode().hex().encode() + b'\n')
            value = peer.execute(prepared, data=data)
            self.assertTrue(value['ok'], value)
            self.assertEqual(value['result']['status'], 'complete')
            self.assertEqual(value['result']['result']['title'], data['title'])
            self.assertIn('雪|literal', value['result']['result']['stdout'])
            self.assertEqual(peer.observed(), [raw])
            self.assertEqual([name for name, _ in peer.events if name.endswith('.write')], ['process.channel.write'])
            peer.idle()

    def test_persistent_state_and_reset_use_same_actual_interpreter(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            for call, data, expected in [('first', cell('counter = 40\ncounter'), '40'),
                    ('next', cell('counter += 2\ncounter'), '42'),
                    ('reset', cell("'counter' in globals()", reset=True), 'false')]:
                value = peer.execute(peer.prepare(data=data, call=call), data=data, call=call)
                self.assertTrue(value['ok'], value)
                self.assertEqual(value['result']['result']['stdout'].strip(), expected)
            self.assertEqual(len(peer.observed()), 3)

    def test_separate_endpoint_instances_do_not_share_language_state(self):
        with Peer() as one, Peer() as two:
            self.assertTrue(one.start()['ok']); self.assertTrue(two.start()['ok'])
            data = cell('private_value = 17')
            self.assertTrue(one.execute(one.prepare(data=data), data=data)['ok'])
            data = cell("'private_value' in globals()")
            value = two.execute(two.prepare(data=data), data=data)
            self.assertEqual(value['result']['result']['stdout'].strip(), 'false')

    def test_known_cell_exception_retains_output_and_session_is_usable(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = cell("print('before error')\nraise ValueError('known cell error')")
            value = peer.execute(peer.prepare(data=data), data=data)
            self.assertFalse(value['ok'])
            self.assertEqual(value['result']['status'], 'complete')
            self.assertEqual(value['result']['error'], 'eval_plugin.cell_failed')
            self.assertIn('before error', value['result']['result']['stdout'])
            self.assertIn('ValueError: known cell error', value['result']['result']['stderr'])
            self.assertTrue(peer.execute(peer.prepare(call='next'), call='next')['ok'])

    def test_python_timeout_is_observed_known_failure_without_retry(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = cell('while True: pass', timeout=1)
            value = peer.execute(peer.prepare(data=data), data=data)
            self.assertFalse(value['ok'])
            self.assertEqual(value['result']['status'], 'complete')
            self.assertTrue(value['result']['result']['timed_out'])
            self.assertEqual(value['result']['result']['exit_code'], 124)
            self.assertEqual(len(peer.observed()), 1)
            self.assertTrue(peer.execute(peer.prepare(call='next'), call='next')['ok'])

    def test_language_timeout_and_unknown_fields_rejected_before_io(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); before = len(peer.events)
            invalid = [dict(language='js', code='1'), cell(timeout=0), cell(timeout=31),
                       cell(timeout=True), cell(reset='true'), cell(extra='no'), cell(title=3)]
            for index, data in enumerate(invalid):
                self.assertFalse(peer.prepare(data=data, call=str(index))['ok'], data)
            self.assertEqual(len(peer.events), before)
            self.assertEqual(peer.observed(), [])

    def test_repeated_prepare_is_logically_equal_but_input_drift_is_rejected(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            first = peer.prepare(data={'language': 'py', 'code': '2', 'title': 'same'})
            again = peer.prepare(data={'title': 'same', 'code': '2', 'language': 'py'})
            self.assertEqual(first['result'], again['result'])
            changed = peer.prepare(data=cell('3', title='same'))
            self.assertEqual(changed['result']['error'], 'eval_plugin.prepared_identity_conflict')
            self.assertEqual(peer.observed(), [])

    def test_host_plan_bytes_and_execution_input_cannot_drift(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); prepared = peer.prepare()
            before = len(peer.events)
            changed = json.loads(json.dumps(prepared))
            changed['result']['intents'][0]['bytes_hex'] += '20'
            result = peer.execute(changed)
            self.assertEqual(result['result']['error'], 'eval_plugin.intent_mismatch')
            changed_input = peer.execute(prepared, data=cell('9'))
            self.assertEqual(changed_input['result']['error'], 'eval_plugin.prepared_identity_conflict')
            self.assertEqual(len(peer.events), before)
            self.assertEqual(peer.observed(), [])

    def test_consumed_identity_never_writes_again(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); prepared = peer.prepare()
            self.assertTrue(peer.execute(prepared)['ok']); before = len(peer.events)
            self.assertFalse(peer.prepare()['ok']); self.assertFalse(peer.execute(prepared)['ok'])
            self.assertEqual(len(peer.events), before); self.assertEqual(len(peer.observed()), 1)

    def test_same_call_id_in_other_run_cannot_reuse_preparation(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); prepared = peer.prepare(run='original')
            before = len(peer.events)
            value = peer.execute(prepared, run='other')
            self.assertEqual(value['result']['error'], 'eval_plugin.prepared_missing')
            self.assertEqual(len(peer.events), before); self.assertEqual(peer.observed(), [])

    def test_refresh_preserves_interpreter_state_but_invalidates_prepared_cells(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); data = cell('value = 19')
            self.assertTrue(peer.execute(peer.prepare(data=data), data=data)['ok'])
            stale = peer.prepare(call='stale'); writes = len(peer.observed())
            self.assertTrue(peer.refresh()['ok'])
            self.assertFalse(peer.execute(stale, call='stale')['ok'])
            self.assertEqual(len(peer.observed()), writes)
            data = cell('value'); fresh = peer.prepare(call='fresh', data=data)
            value = peer.execute(fresh, call='fresh', data=data)
            self.assertEqual(value['result']['result']['stdout'].strip(), '19')

    def test_configuration_drift_and_wrong_ready_language_are_rejected(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            changed = configuration(); changed['max_timeout_ms'] = 60000
            before = len(peer.events)
            self.assertFalse(peer.refresh(changed)['ok'])
            self.assertEqual(len(peer.events), before); self.assertEqual(peer.observed(), [])
        with Peer() as peer:
            changed = configuration(); changed['language'] = 'rb'
            value = peer.invoke({'action': 'start', 'configuration': changed})
            self.assertEqual(value['result']['error'], 'eval_plugin.runner_identity_invalid')
            self.assertEqual(peer.observed(), [])

    def test_missing_real_write_receipt_is_unknown_and_never_replayed(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); prepared = peer.prepare(); peer.omit_receipt = True
            value = peer.execute(prepared)
            self.assertFalse(value['ok']); self.assertEqual(value['result']['status'], 'unknown')
            self.assertFalse(peer.execute(prepared)['ok']); self.assertEqual(len(peer.observed()), 1)

    def test_runner_eof_after_write_is_unknown(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); data = cell('import os; os._exit(0)')
            value = peer.execute(peer.prepare(data=data), data=data)
            self.assertFalse(value['ok']); self.assertEqual(value['result']['status'], 'unknown')
            self.assertEqual(len(peer.observed()), 1)

    def test_oversized_output_after_execution_is_unknown_not_truncated_success(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); data = cell("print('x' * 100000)")
            value = peer.execute(peer.prepare(data=data), data=data)
            self.assertFalse(value['ok']); self.assertEqual(value['result']['status'], 'unknown')
            self.assertEqual(len(peer.observed()), 1)

    def test_escaped_json_result_limit_is_checked_after_actual_execution(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); data = cell("print(chr(1) * 8000)")
            value = peer.execute(peer.prepare(data=data), data=data)
            self.assertFalse(value['ok']); self.assertEqual(value['result']['status'], 'unknown')
            self.assertEqual(len(peer.observed()), 1)

    def test_cancel_and_late_service_reply_cannot_publish_a_cell_result(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok']); data = cell('while True: pass')
            prepared = peer.prepare(data=data)
            frame = peer.invocation({'action': 'call', 'tool': local_name(), 'input': data,
                'host_plan': {'version': 'process-channel-intent-v1', 'binding': {'protocol_fixture': True},
                              'intents': prepared['result']['intents']}})
            peer.current = frame; peer.send(frame)
            while not peer.observed():
                message = peer.next(5); self.assertEqual(message['type'], 'service_request'); peer.answer(message)
            pending = peer.next(5); self.assertEqual(pending['type'], 'service_request')
            cancel = {key: frame[key] for key in IDENTITY}; cancel['type'] = 'cancel'; peer.send(cancel)
            while True:
                message = peer.next(5)
                if message['type'] == 'service_request':
                    continue
                self.assertEqual(message['type'], 'cancelled')
                for key in IDENTITY: self.assertEqual(message[key], frame[key])
                break
            peer.answer(pending)  # exact but late response cannot re-open a closed gate
            peer.current = None; peer.idle()
            self.assertEqual(len(peer.observed()), 1)

    def test_poisoned_service_identity_is_fatal_without_late_result(self):
        with Peer() as peer:
            peer.poison_response = True
            # Fatal identity rejection can close either pipe direction first.
            with self.assertRaises((EOFError, BrokenPipeError)): peer.start()
            self.assertEqual(peer.plugin.wait(timeout=3), 3)
            self.assertEqual(peer.observed(), [])
            peer.reader.join(timeout=3)
            self.assertFalse(peer.reader.is_alive())
            while True:
                try:
                    pending = peer.frames.get_nowait()
                except queue.Empty:
                    break
                if isinstance(pending, EOFError):
                    continue
                self.assertIsInstance(pending, dict)
                self.assertNotIn(pending.get('type'), ('result', 'cancelled'))
                self.assertEqual(pending.get('type'), 'service_request')

    def test_input_bound_rejects_before_any_write(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            with self.assertRaises(EOFError): peer.prepare(data=cell('x' * 17000))
            self.assertEqual(peer.plugin.wait(timeout=3), 3)
            self.assertEqual(peer.observed(), [])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    arguments, remaining = parser.parse_known_args()
    BINARY = arguments.binary.resolve(strict=True)
    RUNNER = (BINARY.parent.parent / 'runners/python.py').resolve(strict=True)
    if not RUNNER.is_relative_to(BINARY.parent.parent):
        raise ValueError('runner must belong to the actual packaged endpoint')
    extraction = json.loads((RUNNER.parent / 'extraction.json').read_text())
    if hashlib.sha256(RUNNER.read_bytes()).hexdigest() != extraction['runners']['python.py']['packaged_sha256']:
        raise ValueError('packaged Python runner differs from reviewed extraction')
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)

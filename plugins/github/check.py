#!/usr/bin/env python3
"""Actual packaged native plugin + real stdio peer; host broker is a protocol fixture.

This proves plugin protocol/session behavior, not Product/SQLite authorization.
No transport substitution inside mcp4cj and no execution of forged host authority.
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
BACKEND = None

def configuration():
    return {'version': 1, 'request_timeout_ms': 10000}

def local_name():
    return 'repo_view'

class Peer:
    def __init__(self, mode='echo'):
        self.directory = tempfile.TemporaryDirectory(prefix='github-plugin-protocol-')
        self.record = Path(self.directory.name) / 'requests.jsonl'
        self.record.touch()
        self.origin = None
        self.plugin = None
        try:
            self.command_record = Path(self.directory.name) / 'commands.jsonl'
            self.command_record.touch()
            fake = Path(self.directory.name) / 'fake gh'
            fake.write_text('#!' + sys.executable + '\n' + (ROOT / 'tests/command.py').read_text())
            fake.chmod(0o755)
            environment = dict(os.environ, GITHUB_PLUGIN_TEST_MODE=mode,
                               GITHUB_PLUGIN_COMMANDS=str(self.command_record))
            self.origin = subprocess.Popen([sys.executable, '-u', str(BACKEND),
                '--gh', str(fake), '--git', str(fake)], env=environment,
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
            self.omit_receipt = False
            self.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'github',
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
        return {'type': 'invoke', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'github',
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
            assert set(args) == {'intent_id'} and args['intent_id'] == 'github-call'
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
        arguments = {'action': 'call', 'tool': tool or local_name(), 'input': {} if data is None else data}
        response = self.invoke(arguments, kind='service_prepare', call=call, run=run)
        if response['ok']:
            self.allowed[(run, call)] = bytes.fromhex(response['result']['intents'][0]['bytes_hex'])
        return response

    def execute(self, prepared, *, data=None, call='call-1', run='run-1', tool=None):
        return self.invoke({'action': 'call', 'tool': tool or local_name(), 'input': {} if data is None else data,
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

    def commands(self):
        return [json.loads(row) for row in self.command_record.read_text().splitlines()]

    def close(self):
        # This protocol fixture is not the real host namespace owner. Explicitly
        # reclaim only the fake command groups it started; Product proves actual
        # sandbox/process cancellation separately.
        for row in self.commands() if hasattr(self, 'command_record') else []:
            pid = row['pid']
            path = Path('/proc') / str(pid) / 'cmdline'
            try:
                if str(Path(self.directory.name) / 'fake gh').encode() in path.read_bytes().split(b'\0'):
                    os.killpg(pid, 9)
            except (FileNotFoundError, ProcessLookupError):
                pass
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


class NativeGithubTests(unittest.TestCase):
    def test_discovery_is_actual_backend_and_idle_has_no_service_traffic(self):
        with Peer() as peer:
            result = peer.start()
            self.assertTrue(result['ok'])
            self.assertEqual(len(result['result']['tools']), 11)
            self.assertEqual(json.loads(peer.observed()[0])['action'], 'discover')
            self.assertEqual(peer.commands(), [])
            peer.idle()

    def test_pure_prepare_and_actual_call_preserve_literal_arguments_and_receipt(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = {'title': '雪', 'body': 'line 1\n$(literal) `literal`', 'draft': True}
            before = len(peer.events)
            prepared = peer.prepare(data=data, tool='pr_create')
            self.assertTrue(prepared['ok'])
            self.assertEqual(len(peer.events), before)
            self.assertEqual(peer.commands(), [])
            result = peer.execute(prepared, data=data, tool='pr_create')
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['result']['status'], 'complete')
            self.assertFalse(result['result']['retry_safe'])
            commands = peer.commands()
            self.assertEqual(len(commands), 1)
            self.assertIn(data['body'], commands[0]['argv'])
            writes = [name for name, _ in peer.events[before:] if name.endswith('.write')]
            self.assertEqual(writes, ['process.channel.write'])
            peer.idle()

    def test_prepare_is_idempotent_for_key_order_but_rejects_changed_arguments(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            first = peer.prepare(data={'repo': 'owner/project', 'branch': 'topic'})
            again = peer.prepare(data={'branch': 'topic', 'repo': 'owner/project'})
            self.assertEqual(first['result'], again['result'])
            changed = peer.prepare(data={'repo': 'owner/other', 'branch': 'topic'})
            self.assertFalse(changed['ok'])
            self.assertEqual(changed['result']['error'], 'github_plugin.prepared_identity_conflict')
            self.assertEqual(peer.commands(), [])

    def test_forged_prepared_bytes_never_reach_backend(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            prepared['result']['intents'][0]['bytes_hex'] += '20'
            before = len(peer.events)
            result = peer.execute(prepared)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'github_plugin.intent_mismatch')
            self.assertEqual(len(peer.events), before)
            self.assertEqual(peer.commands(), [])

    def test_consumed_call_cannot_be_prepared_or_dispatched_again(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            self.assertTrue(peer.execute(prepared)['ok'])
            before = len(peer.events)
            self.assertFalse(peer.prepare()['ok'])
            self.assertFalse(peer.execute(prepared)['ok'])
            self.assertEqual(len(peer.events), before)
            self.assertEqual(len(peer.commands()), 1)

    def test_refresh_uses_maintenance_window_and_invalidates_old_preparation(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            before = len(peer.events)
            self.assertTrue(peer.refresh()['ok'])
            self.assertEqual([name for name, _ in peer.events[before:] if name.endswith('.write')],
                             ['process.channel.refresh.write'])
            self.assertFalse(peer.execute(prepared)['ok'])
            self.assertEqual(peer.commands(), [])
            fresh = peer.prepare(call='fresh')
            self.assertTrue(peer.execute(fresh, call='fresh')['ok'])

    def test_missing_active_receipt_is_unknown_and_closes_channel(self):
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            peer.omit_receipt = True
            result = peer.execute(prepared)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertFalse(peer.execute(prepared)['ok'])
            self.assertLessEqual(len(peer.commands()), 1)

    def test_actual_command_failure_is_unknown_without_retry(self):
        with Peer('fail') as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            result = peer.execute(prepared)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertEqual(result['result']['error'], 'github.process_failed')
            self.assertEqual(len(peer.commands()), 1)

    def test_invalid_configuration_and_unknown_tool_have_no_backend_effect(self):
        with Peer() as peer:
            result = peer.invoke({'action': 'start', 'configuration': {'version': 2, 'request_timeout_ms': 1000}})
            self.assertFalse(result['ok'])
            self.assertEqual(peer.events, [])
            self.assertEqual(peer.commands(), [])
        with Peer() as peer:
            self.assertTrue(peer.start()['ok'])
            before = len(peer.events)
            self.assertFalse(peer.prepare(tool='not-granted')['ok'])
            self.assertEqual(len(peer.events), before)

    def test_cancel_ack_is_correlated_and_never_dispatches_an_extra_write(self):
        with Peer('hang') as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            frame = peer.invocation({'action': 'call', 'tool': local_name(), 'input': {},
                'host_plan': {'version': 'process-channel-intent-v1', 'binding': {'protocol_fixture': True},
                              'intents': prepared['result']['intents']}})
            peer.current = frame
            peer.send(frame)
            until = time.monotonic() + 5
            while not peer.commands() and time.monotonic() < until:
                message = peer.next(5)
                self.assertEqual(message['type'], 'service_request')
                peer.answer(message)
            self.assertEqual(len(peer.commands()), 1)
            cancel = {key: frame[key] for key in IDENTITY}
            cancel['type'] = 'cancel'
            peer.send(cancel)
            while True:
                message = peer.next(5)
                if message['type'] == 'service_request':
                    peer.answer(message)
                    continue
                self.assertEqual(message['type'], 'cancelled')
                for key in IDENTITY:
                    self.assertEqual(message[key], frame[key])
                break
            self.assertEqual(len([name for name, _ in peer.events if name == 'process.channel.write']), 1)
            peer.current = None
            peer.idle()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    arguments, remaining = parser.parse_known_args()
    BINARY = arguments.binary.resolve(strict=True)
    BACKEND = (BINARY.parent.parent / 'backend/github_backend.py').resolve(strict=True)
    if not BACKEND.is_relative_to(BINARY.parent.parent):
        raise ValueError('backend must belong to the actual packaged endpoint')
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)

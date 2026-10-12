#!/usr/bin/env python3
"""Shared black-box native pure-provider peer; no Host authority is simulated."""
import hashlib
import time
import json
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent
CONTENT_LIMITS = dict(schema='axyndra.content-payload/v1', max_message_bytes=4521984,
                      max_input_bytes=4456448, max_result_bytes=4194304)
IDENTITY = ('protocol', 'extension_id', 'extension_version', 'generation', 'id', 'tool', 'kind',
            'command_id', 'thread_id', 'run_id', 'epoch', 'operation_id', 'call_id')


class Peer:
    def __init__(self, binary, *, plugin_id="compaction", version="1.0.0", contribution="summarize", payload=False, profile=None, sequence=False):
        self.directory = tempfile.TemporaryDirectory(prefix='pure-provider-native-')
        self.root = Path(self.directory.name)
        self.contribution = contribution
        self.process = subprocess.Popen([str(binary)], cwd=self.root, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.frames = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.counter = 0
        self.hello = dict(type='hello', protocol='axyndra-js-host-v2', extension_id=plugin_id,
            extension_version=version, generation=3, capabilities=[])
        self.payload = payload
        if sequence:
            self.hello['policy_sequence'] = 'invoke-i63-v1' if sequence is True else sequence
        if payload:
            self.hello['content_payload_limits'] = CONTENT_LIMITS if profile is None else profile
        try:
            self.send(self.hello)
            self.ready = self.next()
        except BaseException:
            self.close()
            raise

    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(262146)
                if not line:
                    raise EOFError('native process closed')
                if len(line) > 262145 or not line.endswith(b'\n'):
                    raise AssertionError('unbounded protocol output')
                self.frames.put(json.loads(line))
        except BaseException as error:
            self.frames.put(error)

    def send(self, value):
        self.process.stdin.write((json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n').encode())
        self.process.stdin.flush()

    def next(self):
        value = self.frames.get(timeout=5)
        if isinstance(value, BaseException):
            raise value
        return value

    def invocation(self, query):
        self.counter += 1
        frame = dict(self.hello)
        frame.update(type='invoke', id=f'invoke-{self.counter}', tool=self.contribution,
            kind="provider", command_id='',
            thread_id='thread', run_id='', epoch=0, operation_id='', call_id=f'query-{self.counter}', arguments=dict(schema="axyndra.policy-query/v1", input=query))
        del frame['capabilities']
        frame.pop('content_payload_limits', None)
        frame.pop('policy_sequence', None)
        if self.payload:
            frame['payload_window'] = f'query-window-{self.counter}'
        return frame

    def invoke(self, query):
        frame = self.invocation(query)
        source = json.dumps(frame, ensure_ascii=False, separators=(',', ':')).encode()
        if len(source) + 1 > 262144:
            self.send_logical(frame, source)
        else:
            self.send(frame)
        response = self.receive_result(frame)
        assert response['type'] == 'result', 'pure provider must never request a service or emit progress'
        assert all(response[name] == frame[name] for name in IDENTITY)
        return response

    @staticmethod
    def logical_frame(frame, kind, **values):
        return dict(type=kind, **{name: frame[name] for name in IDENTITY}, payload=dict(
            schema='axyndra.logical-json/v1', window=frame['payload_window'], transfer_sequence=1, **values))

    def send_logical(self, frame, source):
        self.send(self.logical_frame(frame, 'payload_begin', message_type='invoke', bytes=len(source),
                                     sha256=hashlib.sha256(source).hexdigest()))
        for offset in range(0, len(source), 16384):
            self.send(self.logical_frame(frame, 'payload_chunk', offset=offset,
                                         bytes_hex=source[offset:offset + 16384].hex()))
        self.send(self.logical_frame(frame, 'payload_end'))

    def receive_result(self, frame):
        result = self.next()
        if result['type'] == 'result':
            if self.payload:
                assert result['payload_window'] == frame['payload_window']
            return result
        assert self.payload and result['type'] == 'payload_begin'
        assert all(result[name] == frame[name] for name in IDENTITY)
        header = result['payload']
        assert header['schema'] == 'axyndra.logical-json/v1' and header['message_type'] == 'result'
        assert header['window'] == frame['payload_window'] and header['transfer_sequence'] == 1
        assert 0 < header['bytes'] <= CONTENT_LIMITS['max_message_bytes']
        body = bytearray()
        deadline = time.monotonic() + 5
        while True:
            assert time.monotonic() < deadline, 'logical output exceeded fixed consumer deadline'
            part = self.next()
            assert all(part[name] == frame[name] for name in IDENTITY)
            fields = part['payload']
            assert fields['window'] == header['window'] and fields['transfer_sequence'] == 1
            if part['type'] == 'payload_end':
                break
            assert part['type'] == 'payload_chunk' and fields['offset'] == len(body)
            raw = bytes.fromhex(fields['bytes_hex'])
            assert 0 < len(raw) <= 16384
            body.extend(raw)
            assert len(body) <= header['bytes']
        assert len(body) == header['bytes'] and hashlib.sha256(body).hexdigest() == header['sha256']
        result = json.loads(body)
        assert result['payload_window'] == frame['payload_window']
        return result

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=3)
        self.reader.join(timeout=3)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()
        self.directory.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


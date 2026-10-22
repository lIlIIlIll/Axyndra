#!/usr/bin/env python3
"""Exercise the installed Workspace executable's negotiated read payload protocol."""
import argparse
import hashlib
import json
import os
import selectors
import time
from pathlib import Path
import subprocess
import tempfile
import unittest
import check

OFFER = dict(schema='axyndra.ordinary-tool-payload/v1', max_input_bytes=2097152,
             max_result_bytes=1114112, max_service_response_bytes=1114112, max_message_bytes=2162688)
PROFILE = dict(OFFER, contribution='read')


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


def part(frame, kind, **values):
    return dict({key: frame[key] for key in check.KEYS}, type=kind,
                payload=dict(schema='axyndra.logical-json/v1', window=frame['payload_window'],
                             transfer_sequence=1, **values))


class PayloadProtocol(check.Protocol):
    def __init__(self, root):
        super().__init__(root)
        self._wire_buffer = bytearray()

    def physical(self, eof=False):
        deadline = time.monotonic()+5
        while b'\n' not in self._wire_buffer:
            if len(self._wire_buffer)>262144:
                raise AssertionError('workspace physical frame exceeds its fixed bound')
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                if not selector.select(max(0,deadline-time.monotonic())):
                    raise AssertionError('workspace endpoint did not produce a bounded reply')
            data=os.read(self.process.stdout.fileno(),8192)
            if not data:
                if not eof or self._wire_buffer:
                    raise AssertionError('workspace physical frame ended before its newline')
                self.process.wait(timeout=5)
                return None
            self._wire_buffer.extend(data)
        end=self._wire_buffer.index(10)+1
        if end>262144 or eof:
            raise AssertionError('invalid or unexpected workspace physical frame')
        line=bytes(self._wire_buffer[:end]);del self._wire_buffer[:end]
        return json.loads(line)

    def hello(self, offer=OFFER):
        self.send(dict(type='hello', protocol='axyndra-js-host-v2', extension_id='workspace',
                       extension_version='1.0.0', generation=7, capabilities=['process.readview'],
                       ordinary_tool_payload=offer))
        ready = self.receive()
        assert ready['ordinary_tool_payload'] == offer
        return ready

    def logical_send(self, frame):
        source = encode(frame)
        self.send(part(frame, 'payload_begin', message_type=frame['type'], bytes=len(source),
                       sha256=hashlib.sha256(source).hexdigest()))
        for offset in range(0, len(source), 16384):
            self.send(part(frame, 'payload_chunk', offset=offset, bytes_hex=source[offset:offset+16384].hex()))
        self.send(part(frame, 'payload_end'))

    def receive(self, eof=False):
        first = self.physical(eof=eof)
        if eof or first['type'] != 'payload_begin':
            return first
        header = first['payload']
        assert set(header) == {'schema', 'window', 'transfer_sequence', 'message_type', 'bytes', 'sha256'}
        assert header['schema'] == 'axyndra.logical-json/v1' and header['transfer_sequence'] == 1
        assert header['message_type'] == 'result' and 0 < header['bytes'] <= OFFER['max_message_bytes']
        body = bytearray()
        while True:
            value = self.physical()
            assert all(value[key] == first[key] for key in check.KEYS)
            payload = value['payload']
            assert payload['window'] == header['window'] and payload['transfer_sequence'] == 1
            if value['type'] == 'payload_end':
                assert set(payload) == {'schema', 'window', 'transfer_sequence'}
                break
            assert value['type'] == 'payload_chunk' and payload['offset'] == len(body)
            data = bytes.fromhex(payload['bytes_hex'])
            assert 0 < len(data) <= 16384 and len(body)+len(data) <= header['bytes']
            body.extend(data)
        assert len(body) == header['bytes'] and hashlib.sha256(body).hexdigest() == header['sha256']
        value = json.loads(body)
        assert all(value[key] == first[key] for key in check.KEYS)
        assert value['payload_window'] == header['window']
        return value

    def invocation(self, arguments, *, identifier='payload-1', kind='tool', profile=PROFILE):
        return dict(type='invoke', protocol='axyndra-js-host-v2', extension_id='workspace',
                    extension_version='1.0.0', generation=7, id=identifier, kind=kind, tool='read', command_id='',
                    thread_id='workspace-thread', run_id='workspace-run', epoch=2,
                    operation_id='' if kind == 'prepare' else 'workspace-op', call_id='workspace-call',
                    arguments=arguments, payload_window='window-'+identifier, tool_payload_limits=profile)


class WorkspacePayloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='workspace-payload-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def prepared_worker(self, content, profile=PROFILE):
        (self.root/'target').write_text(content, encoding='utf-8')
        with PayloadProtocol(self.root) as wire:
            wire.hello()
            frame = wire.invocation({'input': {'path': 'original.txt:raw'}}, kind='prepare', profile=profile)
            wire.logical_send(frame)
            result = wire.receive()
            self.assertTrue(result['ok'], result)
            request = result['result']['intents'][0]['request']
            self.assertEqual(request['arguments'][:2], ['--view-worker-profile', 'read'])
            self.assertEqual(json.loads(request['arguments'][3]), profile)
            worker = subprocess.run([str(check.PACKAGE/'bin/workspace-plugin'), *request['arguments']],
                                    cwd=self.root, env=check.environment(), capture_output=True, text=True, timeout=35)
            self.assertEqual(worker.returncode, 0, worker.stdout+worker.stderr)
            output = json.loads(worker.stdout)
            frame = wire.invocation({'path': 'original.txt:raw'}, identifier='payload-2', profile=profile)
            wire.logical_send(frame)
            self.assertEqual(wire.receive()['service'], 'process.readview')
            response = check.response(frame, dict(stdout=worker.stdout, stderr=worker.stderr, exit_code=0,
                                                  timed_out=False, truncated=False))
            response['payload_window'] = frame['payload_window']
            wire.logical_send(response)
            reply = wire.receive()
            self.assertTrue(reply['ok'], reply)
            self.assertEqual(reply['result'], output)
            return reply['result'], response

    def test_original_32k_96k_1m_raw_fixture_bytes_remain_exact(self):
        for size in (32768, 98304, 1048576):
            content = 'x'*(size-4)+'雪!'
            result, _ = self.prepared_worker(content)
            self.assertEqual(result['content'], content)
            self.assertEqual(result['returned_bytes'], size)
            self.assertFalse(result['truncated'])

    def test_absent_profile_retains_small_default_and_utf8_boundary(self):
        content = '雪'*50000
        (self.root/'plain.txt').write_text(content)
        result = check.worker(self.root, 'read', {'path':'plain.txt:raw'})
        self.assertEqual(result.returncode, 0)
        value = json.loads(result.stdout)
        self.assertTrue(value['truncated'])
        self.assertLessEqual(len(result.stdout.encode()), 65537)
        self.assertTrue(content.startswith(value['content']))
        self.assertEqual(value['returned_bytes'], len(value['content'].encode()))

    def test_insufficient_profile_truncates_without_refilling(self):
        profile = dict(PROFILE, max_input_bytes=16384, max_result_bytes=4096,
                       max_service_response_bytes=8192, max_message_bytes=20480)
        result, response = self.prepared_worker('雪'*50000, profile)
        self.assertTrue(result['truncated'])
        self.assertLessEqual(len(encode(result)), profile['max_result_bytes'])
        self.assertLessEqual(len(encode(response['result'])), profile['max_service_response_bytes'])
        self.assertEqual(result['returned_bytes'], len(result['content'].encode()))

    def test_dense_controls_respect_both_escaping_layers(self):
        content = ('\x01\b\t\r"\\雪')*50000
        result, response = self.prepared_worker(content)
        self.assertTrue(result['truncated'])
        self.assertTrue(content.startswith(result['content']))
        self.assertLessEqual(len(encode(result)), PROFILE['max_result_bytes'])
        self.assertLessEqual(len(encode(response['result'])), PROFILE['max_service_response_bytes'])
        self.assertEqual(result['returned_bytes'], len(result['content'].encode()))

    def test_foreign_and_unsolicited_profiles_fail_before_service(self):
        for offered, profile in [(False, PROFILE), (True, dict(PROFILE, contribution='write'))]:
            with PayloadProtocol(self.root) as wire:
                if offered: wire.hello()
                else: check.Protocol.hello(wire)
                wire.send(wire.invocation({'path':'target:raw'}, profile=profile))
                wire.receive(eof=True)
                self.assertEqual(wire.process.returncode, 3)

    def test_changed_generation_rejected_before_any_service(self):
        with PayloadProtocol(self.root) as wire:
            wire.hello(); frame = wire.invocation({'path':'target:raw'}); frame['generation']=8
            wire.logical_send(frame); wire.receive(eof=True)
            self.assertEqual(wire.process.returncode, 3)

    def test_excess_declaration_and_foreign_window_fail_closed(self):
        for mode in ('excess', 'window', 'identity', 'digest'):
            with PayloadProtocol(self.root) as wire:
                wire.hello(); frame=wire.invocation({'path':'target:raw'}); source=encode(frame)
                wire.send(part(frame,'payload_begin',message_type='invoke',
                               bytes=OFFER['max_message_bytes']+1 if mode=='excess' else len(source),
                               sha256='0'*64 if mode=='digest' else hashlib.sha256(source).hexdigest()))
                if mode != 'excess':
                    chunk=part(frame,'payload_chunk',offset=0,bytes_hex=source.hex())
                    if mode=='window': chunk['payload']['window']+='-foreign'
                    if mode=='identity': chunk['epoch']+=1
                    wire.send(chunk)
                    if mode=='digest': wire.send(part(frame,'payload_end'))
                wire.receive(eof=True); self.assertEqual(wire.process.returncode,3)

    def test_cancel_partial_response_ack_and_next_invocation(self):
        with PayloadProtocol(self.root) as wire:
            wire.hello(); frame=wire.invocation({'path':'target:raw'});wire.logical_send(frame)
            self.assertEqual(wire.receive()['service'],'process.readview')
            response=check.response(frame);response['payload_window']=frame['payload_window'];source=encode(response)
            wire.send(part(frame,'payload_begin',message_type='service_response',bytes=len(source),sha256=hashlib.sha256(source).hexdigest()))
            wire.send(part(frame,'payload_chunk',offset=0,bytes_hex=source[:32].hex()))
            wire.send(dict({key:frame[key] for key in check.KEYS},type='cancel'))
            self.assertEqual(wire.receive()['type'],'cancelled')
            subsequent=wire.invocation({'path':'target:raw'},identifier='subsequent')
            wire.logical_send(subsequent);self.assertEqual(wire.receive()['service'],'process.readview')
            wire.send(dict({key:subsequent[key] for key in check.KEYS},type='cancel'))
            self.assertEqual(wire.receive()['type'],'cancelled')

    def test_cancelled_window_cannot_accept_late_chunks(self):
        with PayloadProtocol(self.root) as wire:
            wire.hello();frame=wire.invocation({'path':'target:raw'});source=encode(frame)
            wire.send(part(frame,'payload_begin',message_type='invoke',bytes=len(source),sha256=hashlib.sha256(source).hexdigest()))
            wire.send(dict({key:frame[key] for key in check.KEYS},type='cancel'))
            self.assertEqual(wire.receive()['type'],'cancelled')
            wire.send(part(frame,'payload_chunk',offset=0,bytes_hex=source.hex()))
            wire.receive(eof=True);self.assertEqual(wire.process.returncode,3)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--package',type=Path,required=True)
    arguments,extra=parser.parse_known_args();check.PACKAGE=arguments.package.resolve(strict=True)
    unittest.main(argv=[__file__,*extra],verbosity=2)

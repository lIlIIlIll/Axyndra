#!/usr/bin/env python3
"""Real independent plugin; bounded logical frames, actual MCP peer and no Product mocks.

The fixture is a protocol peer, not proof of Store or operator authorization.
Those are verified by the separate Product/SQLite contracts.
"""
import argparse
import hashlib
import json
import queue
import time
import unittest
from pathlib import Path
import check
from check_capacity import PROFILE, SERVER, config

PAYLOAD = dict(version=1, max_message_bytes=16777216, max_input_bytes=4194304,
               max_prepare_bytes=8388608, max_result_bytes=8388608, max_write_bytes=4128768)


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


def envelope(invocation, kind, **header):
    return dict({key: invocation[key] for key in check.IDENTITY}, type=kind,
                payload=dict(schema='axyndra.logical-json/v1', window=invocation['payload_window'],
                             transfer_sequence=1, **header))


class PayloadPeer(check.Peer):
    def __init__(self, *, logical_input=False):
        self.logical_input = logical_input
        self.logical_results = 0
        self.logical_invocations = 0
        self.highest_physical_frame = 0
        super().__init__(profile=PROFILE, server=SERVER)

    def send(self, frame):
        if frame['type'] == 'hello':
            frame = dict(frame, service_payload_limits=PAYLOAD)
        source = encoded(frame)
        if frame['type'] == 'invoke' and (self.logical_input or len(source) > self.frame_limit):
            self.logical_invocations += 1
            self.send_begin(frame, source)
            for offset in range(0, len(source), 16384):
                self.send_raw(envelope(frame, 'payload_chunk', offset=offset, bytes_hex=source[offset:offset+16384].hex()))
            self.send_raw(envelope(frame, 'payload_end'))
            return
        self.send_raw(frame)

    def send_raw(self, frame):
        size = len(encoded(frame))
        self.highest_physical_frame = max(size, self.highest_physical_frame)
        assert size <= self.frame_limit
        super().send(frame)

    def send_begin(self, frame, source, **changes):
        value = envelope(frame, 'payload_begin', message_type='invoke', bytes=len(source),
                         sha256=hashlib.sha256(source).hexdigest())
        value['payload'].update(changes)
        self.send_raw(value)

    def invocation(self, *args, **kwargs):
        value = super().invocation(*args, **kwargs)
        value['payload_window'] = 'native-json-' + value['id']
        return value

    def next(self, timeout=15):
        deadline = time.monotonic() + timeout
        value = super().next(timeout)
        if value['type'] != 'payload_begin':
            return value
        self.logical_results += 1
        header = value['payload']
        assert set(header) == {'schema', 'window', 'transfer_sequence', 'message_type', 'bytes', 'sha256'}
        assert header['schema'] == 'axyndra.logical-json/v1' and header['transfer_sequence'] == 1
        assert header['message_type'] == 'result' and 0 < header['bytes'] <= PAYLOAD['max_message_bytes']
        assert header['window'] == self.current['payload_window']
        for name in check.IDENTITY:
            assert value[name] == self.current[name]
        body = bytearray()
        while True:
            part = super().next(max(.001, deadline - time.monotonic()))
            assert time.monotonic() < deadline
            for name in check.IDENTITY:
                assert part[name] == value[name]
            item = part['payload']
            assert item['schema'] == header['schema'] and item['window'] == header['window'] and item['transfer_sequence'] == 1
            if part['type'] == 'payload_end':
                assert set(item) == {'schema', 'window', 'transfer_sequence'}
                break
            assert part['type'] == 'payload_chunk' and set(item) == {'schema', 'window', 'transfer_sequence', 'offset', 'bytes_hex'}
            assert item['offset'] == len(body)
            chunk = bytes.fromhex(item['bytes_hex'])
            assert 0 < len(chunk) <= 16384 and len(body) + len(chunk) <= header['bytes']
            body.extend(chunk)
        assert len(body) == header['bytes'] and hashlib.sha256(body).hexdigest() == header['sha256']
        result = json.loads(body)
        assert result['type'] == 'result' and result['payload_window'] == header['window']
        for name in check.IDENTITY:
            assert result[name] == value[name]
        return result

    def start(self):
        return self.invoke(dict(action='start', configuration=config()), call='startup', run='maintenance')

    def execute(self, prepared, *, data=None, call='call-1', run='run-1', mutate=None):
        raw = bytes.fromhex(prepared['result']['intents'][0]['bytes_hex'])
        hexdigest = hashlib.sha256(raw.hex().encode()).hexdigest()
        payload = dict(schema='axyndra.service-payload/v1', artifact_ref='blob:sha256:'+hexdigest,
                       encoding='hex', bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(), encoded_sha256=hexdigest)
        if mutate:
            mutate(payload)
        return self.invoke(dict(action='call', tool=check.local_name(), input=data or {}, host_plan=dict(
            version='process-channel-intent-v2', binding={'protocol_fixture': True},
            intents=[dict(id='mcp-call', payload=payload)])), call=call, run=run)


class ImmediatePayloadPeer(PayloadPeer):
    # Issue the successor on the actual stdout consumer thread immediately
    # after consuming the previous terminal physical frame. No idle sleep or
    # test-only plugin hook gives its finally block time to finish first.
    def __init__(self):
        self.successors = []
        self.successor_index = 0
        super().__init__()

    def _read(self):
        try:
            for line in self.plugin.stdout:
                assert len(line) <= self.frame_limit + 1 and line.endswith(b'\n')
                value = json.loads(line)
                if self.successors and value['type'] in ('result', 'payload_end'):
                    expected = self.successors[self.successor_index]
                    for name in check.IDENTITY:
                        assert value[name] == expected[name]
                    self.successor_index += 1
                    if self.successor_index < len(self.successors):
                        self.send(self.successors[self.successor_index])
                    else:
                        self.successors = []
                self.frames.put(value)
        except BaseException as error:
            self.frames.put(error)
        finally:
            self.frames.put(EOFError('plugin exited'))


class PayloadTests(unittest.TestCase):
    def test_consumed_terminal_can_immediately_schedule_next_prepare_without_io_or_reuse(self):
        with ImmediatePayloadPeer() as peer:
            self.assertTrue(peer.start()['ok'])
            before_events = len(peer.events)
            before_peer = len(peer.observed())
            frames = []
            for index in range(48):
                # One result is logical; the remaining terminals are ordinary
                # physical frames. Both final-publication paths must be safe.
                data = dict(mode='input', input='x'*3145728) if index == 1 else dict(mode='input', input=str(index))
                frames.append(peer.invocation(dict(action='call', tool=check.local_name(), input=data),
                                              kind='service_prepare', call=f'immediate-{index}'))
            peer.current = frames[0]
            peer.successors = frames
            peer.send(frames[0])
            last = None
            for frame in frames:
                peer.current = frame
                result = peer.next(15)
                self.assertEqual(result['type'], 'result')
                for name in check.IDENTITY:
                    self.assertEqual(result[name], frame[name])
                self.assertTrue(result['ok'], result['result'].get('error'))
                last = result
            self.assertEqual(peer.successor_index, len(frames))
            self.assertEqual(len(peer.events), before_events)
            self.assertEqual(len(peer.observed()), before_peer)
            self.assertGreaterEqual(peer.logical_results, 1)
            data = frames[-1]['arguments']['input']
            exact_bytes = bytes.fromhex(last['result']['intents'][0]['bytes_hex'])
            peer.allowed[('run-1', 'immediate-47')] = exact_bytes
            self.assertTrue(peer.execute(last, data=data, call='immediate-47')['ok'])
            self.assertEqual(peer.observed()[-1], exact_bytes)
            self.assertEqual(sum(service == 'process.channel.write' for service, _ in peer.events), 1)


    def test_logical_payload_three_mib_input_and_complete_six_mib_result(self):
        with PayloadPeer(logical_input=True) as peer:
            self.assertTrue(peer.start()['ok'])
            for mode in ('input', 'output'):
                data = dict(mode=mode, **({'input': 'x'*3145728} if mode == 'input' else {'size': 3145728}))
                before = len(peer.events)
                prepared = peer.prepare(data=data, call=mode)
                self.assertTrue(prepared['ok']); self.assertEqual(len(peer.events), before)
                frozen = peer.allowed[('run-1', mode)]
                result = peer.execute(prepared, data=data, call=mode)
                self.assertTrue(result['ok']); self.assertEqual(peer.observed()[-1], frozen)
                self.assertEqual(result['result']['result']['content'][0]['text'], 'x'*3145728)
                self.assertGreater(len(encoded(result)), 6291456)
                peer.idle()
            self.assertGreaterEqual(peer.logical_results, 3)
            self.assertEqual(peer.logical_invocations, 5)
            self.assertLessEqual(peer.highest_physical_frame, PROFILE['max_frame_bytes'])

    def test_logical_payload_forged_artifact_identity_cannot_change_prepared_bytes(self):
        with PayloadPeer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = dict(mode='input', input='x'*1048576)
            prepared = peer.prepare(data=data)
            before = len(peer.events)
            for mutate in (lambda p: p.update(sha256='a'*64), lambda p: p.update(bytes=p['bytes']+1),
                           lambda p: p.update(artifact_ref='blob:sha256:'+'b'*64)):
                result = peer.execute(prepared, data=data, mutate=mutate)
                self.assertFalse(result['ok']); self.assertEqual(len(peer.events), before)
            self.assertTrue(peer.execute(prepared, data=data)['ok'])

    def test_logical_payload_bad_begin_declarations_reject_before_body_or_peer_io(self):
        for changes in ({'bytes': PAYLOAD['max_message_bytes']+1}, {'transfer_sequence': 2},
                        {'extra': True}, {'bytes': -1}, {'sha256': 'z'*64}):
            with self.subTest(changes=changes), PayloadPeer() as peer:
                frame = peer.invocation(dict(action='start', configuration=config()), run='maintenance')
                peer.send_begin(frame, encoded(frame), **changes)
                self.assertEqual(peer.plugin.wait(timeout=3), 3)
                self.assertEqual(peer.observed(), [])

        # Ordinary dense physical JSON must be accounted before the DOM and
        # must release on typed rejection, even without any logical transfer.
        with PayloadPeer() as peer:
            for index in range(8):
                result = peer.invoke(dict(action='start', configuration=config(), unexpected=[0]*50000),
                                     call=f'dense-{index}', run='maintenance')
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['error'], 'mcp_plugin.input_invalid')
                self.assertEqual(peer.observed(), [])
            self.assertTrue(peer.start()['ok'])
        with PayloadPeer() as peer:
            frame = peer.invocation(dict(action='start', configuration=config(), unexpected=[0]*70000), run='maintenance')
            peer.send_raw(frame)
            self.assertEqual(peer.plugin.wait(timeout=3), 3)
            self.assertEqual(peer.observed(), [])

    def test_logical_payload_overlap_offset_digest_and_cross_invocation_are_rejected(self):
        for mode in ('overlap', 'offset', 'digest', 'identity', 'window'):
            with self.subTest(mode=mode), PayloadPeer() as peer:
                frame = peer.invocation(dict(action='start', configuration=config()), run='maintenance')
                source = encoded(frame)
                peer.send_begin(frame, source, **({'sha256': 'a'*64} if mode == 'digest' else {}))
                if mode == 'overlap':
                    peer.send_begin(frame, source)
                else:
                    chunk = envelope(frame, 'payload_chunk', offset=1 if mode == 'offset' else 0, bytes_hex=source.hex())
                    if mode == 'identity': chunk['epoch'] += 1
                    if mode == 'window': chunk['payload']['window'] += '-foreign'
                    peer.send_raw(chunk)
                    if mode == 'digest': peer.send_raw(envelope(frame, 'payload_end'))
                self.assertEqual(peer.plugin.wait(timeout=3), 3)
                self.assertEqual(peer.observed(), [])

    def test_logical_payload_cancel_releases_assembly_and_cannot_resume_late_bytes(self):
        with PayloadPeer() as peer:
            frame = peer.invocation(dict(action='start', configuration=config()), run='maintenance')
            source = encoded(frame)
            peer.send_begin(frame, source)
            peer.send_raw(envelope(frame, 'payload_chunk', offset=0, bytes_hex=source[:32].hex()))
            cancel = {key: frame[key] for key in check.IDENTITY}; cancel['type'] = 'cancel'
            peer.send_raw(cancel)
            self.assertEqual(peer.next(3)['type'], 'cancelled'); self.assertEqual(peer.observed(), [])
            peer.send_raw(envelope(frame, 'payload_chunk', offset=32, bytes_hex=source[32:].hex()))
            self.assertEqual(peer.plugin.wait(timeout=3), 3)

    def test_logical_payload_cache_budget_rejects_without_eviction_or_second_write(self):
        with PayloadPeer() as peer:
            self.assertTrue(peer.start()['ok'])
            data = dict(mode='input', input='x'*1048576)
            before = len(peer.events); first = None
            for index in range(32):
                result = peer.prepare(data=data, call=f'payload-cache-{index}')
                if index == 0: first = result
                if not result['ok']:
                    self.assertIn(result['result']['error'], ('mcp_plugin.prepared_capacity', 'mcp_plugin.payload_capacity'))
                    break
            else: self.fail('bounded prepared cache was not enforced')
            self.assertEqual(len(peer.events), before)
            self.assertTrue(peer.execute(first, data=data, call='payload-cache-0')['ok'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--binary', required=True)
    args, remaining = parser.parse_known_args(); check.BINARY = Path(args.binary).resolve(strict=True)
    unittest.main(argv=['check_payload.py', *remaining], verbosity=2)

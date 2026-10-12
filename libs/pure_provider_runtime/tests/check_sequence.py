#!/usr/bin/env python3
"""Actual pure policy binary tests. No host authority is provided by this peer."""
import argparse
import json
import functools
from pathlib import Path
import unittest
from peer import Peer

BINARY = None
QUERY = dict(schema='axyndra.compaction-policy/v1', phase='prepare', facts='fixed', model='fixture', max_output_tokens=16)


class PurePolicySequenceTests(unittest.TestCase):
    def test_more_than_4096_actual_queries_keep_same_handshake_and_process(self):
        with Peer(BINARY, payload=True, sequence=True) as peer:
            self.assertEqual(peer.ready['policy_sequence'], 'invoke-i63-v1')
            generation, pid = peer.ready['generation'], peer.process.pid
            for index in range(4097):
                response = peer.invoke(QUERY)
                self.assertTrue(response['ok'])
                self.assertEqual(response['id'], f'invoke-{index+1}')
                self.assertEqual(response['generation'], generation)
            self.assertEqual(peer.process.pid, pid)
            self.assertIsNone(peer.process.poll())

    def test_negotiated_duplicate_noncanonical_stale_and_overflow_ids_are_rejected(self):
        variants = [('id','invoke-1'), ('id','invoke-01'), ('id','invoke-0'), ('id','invoke-9223372036854775807'),
                    ('id','invoke-9223372036854775808'), ('generation',2)]
        for field, value in variants:
            with self.subTest(field=field, value=value), Peer(BINARY, payload=True, sequence=True) as peer:
                self.assertTrue(peer.invoke(QUERY)['ok'])
                frame = peer.invocation(QUERY); frame[field] = value
                peer.send(frame)
                with self.assertRaises(EOFError): peer.next()
                self.assertEqual(peer.process.wait(timeout=3), 3)
        with Peer(BINARY, payload=True, sequence=True) as peer:
            # A policy data error still consumes its host request sequence.
            first = peer.invocation(dict(QUERY, phase='invalid'))
            peer.send(first); self.assertFalse(peer.receive_result(first)['ok'])
            first['arguments']['input'] = QUERY; peer.send(first)
            with self.assertRaises(EOFError): peer.next()

    def test_unnegotiated_legacy_id_limit_and_invalid_offer_remain_strict(self):
        with Peer(BINARY, payload=True) as peer:
            self.assertNotIn('policy_sequence', peer.ready)
            for _ in range(4096): self.assertTrue(peer.invoke(QUERY)['ok'])
            peer.send(peer.invocation(QUERY))
            with self.assertRaises(EOFError): peer.next()
        with self.assertRaises(EOFError):
            with Peer(BINARY, payload=False, sequence=True): pass


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--package',type=Path,required=True)
    args=parser.parse_args();root=args.package.resolve(strict=True)
    manifest=json.loads((root/'axyndra.plugin.json').read_text())
    Peer=functools.partial(Peer,plugin_id=manifest['id'],version=manifest['version'])
    BINARY=(root/manifest['entrypoint']).resolve(strict=True)
    if not BINARY.is_relative_to(root):raise SystemExit('entrypoint escapes package')
    unittest.main(argv=['check_sequence'],verbosity=2)

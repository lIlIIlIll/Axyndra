#!/usr/bin/env python3
"""Actual native artifact + real MCP peer. Product/Store evidence is separate."""
import argparse
import json
import time
import unittest
from pathlib import Path
import check

PROFILE = dict(max_frame_bytes=4194304, max_input_bytes=1048576,
               max_prepare_bytes=2097152, max_result_bytes=4128768,
               max_directory_bytes=2097152, max_tools=8192, call_timeout_ms=120000)
SERVER = Path(__file__).parent / 'tests/capacity_server.py'

def config():
    return dict(version=1, transport='stdio', request_timeout_ms=15000,
                directory=dict(max_pages=1024, max_tools=8192))

def start(peer):
    return peer.invoke(dict(action='start', configuration=config()), call='startup', run='maintenance')

class CapacityTests(unittest.TestCase):
    def test_actual_nine_pages_72_tools_and_96k_input_output(self):
        with check.Peer("large-directory", profile=PROFILE, server=SERVER) as peer:
            result=start(peer)
            self.assertTrue(result['ok']); self.assertEqual(len(result['result']['tools']),72)
            self.assertGreater(len(json.dumps(result['result'],separators=(',',':')).encode()),131072)
            self.assertEqual(sum(json.loads(x)['method']=='tools/list' for x in peer.observed()),9)
            for mode in ('input','output'):
                data={'mode':mode, **({'input':'x'*98304} if mode=='input' else {'size':98304})}
                before=len(peer.events)
                prepared=peer.prepare(data=data,call=mode)
                self.assertTrue(prepared['ok']); self.assertEqual(len(peer.events),before)
                exact=peer.allowed[('run-1',mode)]
                result=peer.execute(prepared,data=data,call=mode)
                self.assertTrue(result['ok']); self.assertEqual(peer.observed()[-1],exact)
                self.assertEqual(result['result']['result']['content'][0]['text'],'x'*98304)
                peer.idle()

    def test_real_11_second_response_uses_15_second_request_config(self):
        with check.Peer(profile=PROFILE, server=SERVER) as peer:
            self.assertTrue(start(peer)['ok'])
            data=dict(mode='delay',delay_ms=11000)
            prepared=peer.prepare(data=data)
            begun=time.monotonic(); result=peer.execute(prepared,data=data)
            self.assertTrue(result['ok']); self.assertGreaterEqual(time.monotonic()-begun,10.5)
            self.assertLess(time.monotonic()-begun,15)

    def test_operator_profile_required_before_large_directory_config(self):
        with check.Peer(server=SERVER) as peer:
            self.assertFalse(start(peer)['ok']); self.assertEqual(peer.observed(),[])

    def test_oversized_input_rejected_purely_without_channel_write(self):
        with check.Peer(profile=PROFILE, server=SERVER) as peer:
            self.assertTrue(start(peer)['ok']); before=len(peer.events)
            result=peer.prepare(data={'mode':'input','input':'x'*1048576})
            self.assertFalse(result['ok']); self.assertEqual(len(peer.events),before)

    def test_aggregate_prepared_cache_is_bounded_without_eviction_or_io(self):
        with check.Peer(profile=PROFILE, server=SERVER) as peer:
            self.assertTrue(start(peer)['ok']); before=len(peer.events)
            data={'mode':'input','input':'x'*200000}
            first=None; rejected=False
            for index in range(32):
                value=peer.prepare(data=data,call=f'cache-{index}')
                if index==0: first=value
                if not value['ok']:
                    self.assertEqual(value['result']['error'],'mcp_plugin.prepared_capacity');rejected=True;break
            self.assertTrue(rejected); self.assertEqual(len(peer.events),before)
            self.assertTrue(peer.execute(first,data=data,call='cache-0')['ok'])

    def test_profile_never_changes_frozen_execute_bytes(self):
        with check.Peer(profile=PROFILE, server=SERVER) as peer:
            self.assertTrue(start(peer)['ok'])
            data={'mode':'input','input':'x'*98304}; prepared=peer.prepare(data=data)
            before=len(peer.events)
            changed=dict(data,input='y'*98304)
            result=peer.execute(prepared,data=changed)
            self.assertFalse(result['ok']); self.assertEqual(len(peer.events),before)
            self.assertTrue(peer.execute(prepared,data=data)['ok'])

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True)
    options,args=parser.parse_known_args();check.BINARY=Path(options.binary).resolve()
    unittest.main(argv=['check_capacity.py',*args])

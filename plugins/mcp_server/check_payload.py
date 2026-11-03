#!/usr/bin/env python3
"""Actual standalone Server payload protocol. No broker, Store or authority fake."""
import hashlib
import json
import unittest
import time
import check

PROFILE=dict(max_frame_bytes=4194304,max_input_bytes=1048576,max_prepare_bytes=2097152,
             max_result_bytes=4128768,max_directory_bytes=2097152,max_tools=8192,call_timeout_ms=120000)
PAYLOAD=dict(version=1,max_message_bytes=16777216,max_input_bytes=4194304,max_prepare_bytes=8388608,
             max_result_bytes=8388608,max_write_bytes=4128768)

def payload_frame(frame,kind,**values):
    return dict({key:frame[key] for key in check.IDENTITY},type=kind,
                payload=dict(schema='axyndra.logical-json/v1',window=frame['payload_window'],transfer_sequence=1,**values))

class PackagedPayloadDecoderTests(unittest.TestCase):
    def decoder(self,**changes):return check.Decoder(profile=PROFILE,payload={**PAYLOAD,**changes})
    def ready_call(self,d):
        d.catalogue()
        proposed=d.decode(check.request('tools/call',{'name':'echo','arguments':{'value':'actual'}}))
        self.assertEqual(proposed['action'],'invoke')
    def test_profile_one_mib_results_are_complete_and_use_same_logical_protocol(self):
        d=self.decoder()
        try:
            self.ready_call(d)
            for _ in range(3):
                output={'text':'x'*1048576}
                directive=d.encode_result({'status':'complete','output':output,'is_error':False})
                raw=bytes.fromhex(directive['response_hex']);result=json.loads(raw)
                self.assertGreater(len(raw),2097152)
                self.assertEqual(result['id'],'request-1')
                self.assertEqual(result['result']['structuredContent'],output)
                self.assertEqual(json.loads(result['result']['content'][0]['text']),output)
            self.assertEqual(d.logical_results,3)
        finally:d.close()
    def test_profiles_are_host_selected_paired_exact_and_finite(self):
        variants=[(PROFILE,None),(None,PAYLOAD),({**PROFILE,'unknown':1},PAYLOAD),
                  (PROFILE,{**PAYLOAD,'unknown':1}),(PROFILE,{**PAYLOAD,'max_message_bytes':16777217}),
                  (PROFILE,{**PAYLOAD,'max_input_bytes':1024}),
                  (PROFILE,{**PAYLOAD,'version':2})]
        for profile,payload in variants:
            with self.subTest(profile=profile,payload=payload):
                d=check.Decoder(profile=profile,payload=payload,expect_ready=False)
                try:
                    with self.assertRaises(EOFError):d.next()
                    self.assertEqual(d.process.wait(timeout=2),3)
                finally:d.close()
    def test_blob_size_chunk_offset_digest_and_short_upload_fail_without_partial_response(self):
        d=self.decoder()
        try:
            self.ready_call(d)
            for slot,size in [('result',PAYLOAD['max_input_bytes']+1),('frame',65537),('catalogue',65537)]:
                self.assertFalse(d.invoke(dict(action='blob_begin',slot=slot,size=size,digest='a'*64))['ok'])
            raw=check.encode({'status':'complete','output':{'complete':True},'is_error':False})
            self.assertTrue(d.invoke(dict(action='blob_begin',slot='result',size=len(raw),digest=hashlib.sha256(raw).hexdigest()))['ok'])
            self.assertTrue(d.invoke(dict(action='blob_append',slot='result',offset=0,bytes_hex=raw[:-1].hex()))['ok'])
            self.assertFalse(d.invoke(dict(action='encode',frame_id='frame-1'))['ok'])
            self.assertFalse(d.invoke(dict(action='blob_append',slot='result',offset=0,bytes_hex='00'))['ok'])
            self.assertTrue(d.invoke(dict(action='blob_append',slot='result',offset=len(raw)-1,bytes_hex=raw[-1:].hex()))['ok'])
            response=d.invoke(dict(action='encode',frame_id='frame-1'))
            self.assertTrue(response['ok']);self.assertEqual(check.response(response['result'])['result']['structuredContent'],{'complete':True})
            self.assertFalse(d.invoke(dict(action='blob_append',slot='result',offset=len(raw),bytes_hex=''))['ok'])
            # An exact-sized but corrupt blob cannot yield even a partial RPC response.
            self.assertTrue(d.invoke(dict(action='blob_begin',slot='result',size=len(raw),digest='0'*64))['ok'])
            self.assertFalse(d.invoke(dict(action='blob_append',slot='result',offset=0,bytes_hex=raw.hex()))['ok'])
            self.assertFalse(d.invoke(dict(action='encode',frame_id='frame-1'))['ok'])
            chunk_over=bytes(131073)
            self.assertTrue(d.invoke(dict(action='blob_begin',slot='result',size=len(chunk_over),digest=hashlib.sha256(chunk_over).hexdigest()))['ok'])
            self.assertFalse(d.invoke(dict(action='blob_append',slot='result',offset=0,bytes_hex=chunk_over.hex()))['ok'])
            d.upload('result',check.encode({'status':'complete','output':'still valid','is_error':False}))
            self.assertTrue(d.invoke(dict(action='encode',frame_id='frame-1'))['ok'])
        finally:d.close()
    def test_partial_logical_cancel_closes_decoder_and_late_chunk_cannot_resume(self):
        d=self.decoder()
        try:
            frame=d.frame(dict(action='blob_begin',slot='result',size=1,digest=hashlib.sha256(b'x').hexdigest()))
            raw=check.encode(frame)
            d.send(payload_frame(frame,'payload_begin',message_type='invoke',bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))
            d.send(payload_frame(frame,'payload_chunk',offset=0,bytes_hex=raw[:16].hex()))
            d.send(dict({key:frame[key] for key in check.IDENTITY},type='cancel'))
            self.assertEqual(d.next()['type'],'cancelled')
            d.send(payload_frame(frame,'payload_chunk',offset=16,bytes_hex=raw[16:].hex()))
            with self.assertRaises(EOFError):d.next()
            self.assertEqual(d.process.wait(timeout=2),3)
        finally:d.close()
    def test_profile_cannot_widen_effects_or_external_raw_frame_and_response_overflow_is_explicit(self):
        default=check.Decoder()
        try:
            self.ready_call(default)
            bounded=check.response(default.encode_result({'status':'complete','output':{'text':'x'*32000},'is_error':False}))
            self.assertEqual(bounded['error']['code'],-32603)
            self.assertEqual(default.logical_results,0)
        finally:default.close()
        d=self.decoder()
        try:
            self.ready_call(d)
            self.assertFalse(d.invoke(dict(action='blob_begin',slot='frame',size=65537,digest='a'*64))['ok'])
            result=check.response(d.encode_result({'status':'complete','output':{'text':'x'*3145728},'is_error':False}))
            self.assertEqual(result['error']['code'],-32603)
            self.assertEqual(result['error']['message'],'MCP response exceeds the configured ingress bound')
            frame=d.frame({});frame['kind']='service';frame['operation_id']='forged-effect';d.send(frame)
            with self.assertRaises(EOFError):d.next()
            self.assertEqual(d.process.wait(timeout=2),3)
        finally:d.close()
    def test_dense_physical_rejection_releases_budget_and_unknown_window_is_not_reused(self):
        d=self.decoder()
        try:
            for _ in range(5):
                result=d.invoke(dict(action='blob_begin',slot='result',size=1,digest='a'*64,extra=[0]*50000))
                self.assertFalse(result['ok'])
            d.catalogue([])
            self.assertEqual(check.response(d.decode(check.request('tools/list')))['result']['tools'],[])
            frame=d.frame({});raw=check.encode(frame)
            d.send(payload_frame(frame,'payload_begin',message_type='invoke',bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))
            chunk=payload_frame(frame,'payload_chunk',offset=0,bytes_hex=raw.hex());chunk['payload']['window']+='-foreign'
            d.send(chunk)
            with self.assertRaises(EOFError):d.next()
            self.assertEqual(d.process.wait(timeout=2),3)
        finally:d.close()

    def test_dense_result_consumption_is_charged_with_a_small_prepare_profile_and_releases(self):
        # A small result reservation cannot stand in for the parsed blob DOM.
        # Twelve sequential consumers would exhaust 128 MiB if charges leaked.
        d=self.decoder(max_prepare_bytes=131072,max_write_bytes=32768)
        try:
            self.ready_call(d)
            for _ in range(12):
                value={'status':'complete','output':{'values':[0]*30000},'is_error':False}
                result=check.response(d.encode_result(value))
                self.assertEqual(result['error']['code'],-32603)
                self.assertEqual(result['error']['message'],'MCP response exceeds the configured ingress bound')
            too_dense=check.encode({'status':'complete','output':[0]*70000,'is_error':False})
            self.assertTrue(d.invoke(dict(action='blob_begin',slot='result',size=len(too_dense),digest=hashlib.sha256(too_dense).hexdigest()))['ok'])
            chunks=[too_dense[i:i+131072] for i in range(0,len(too_dense),131072)]
            offset=0
            for chunk in chunks[:-1]:
                self.assertTrue(d.invoke(dict(action='blob_append',slot='result',offset=offset,bytes_hex=chunk.hex()))['ok']);offset+=len(chunk)
            denied=d.invoke(dict(action='blob_append',slot='result',offset=offset,bytes_hex=chunks[-1].hex()))
            self.assertFalse(denied['ok']);self.assertEqual(denied['result']['error'],'mcp_server.payload_nodes')
            self.assertFalse(d.invoke(dict(action='encode',frame_id='frame-1'))['ok'])
            result=check.response(d.encode_result({'status':'complete','output':{'after':'rejected dense value'},'is_error':False}))
            self.assertEqual(result['result']['structuredContent'],{'after':'rejected dense value'})
        finally:d.close()
    def test_actual_fixed_upload_deadline_rejects_unfinished_but_preserves_verified_catalogue(self):
        # This intentionally slow test uses the actual 30-second monotonic
        # deadline. It does not inject a clock or shorten a production profile.
        d=self.decoder()
        try:
            d.catalogue()
            d.upload('result',check.encode({'status':'complete','output':{'verified':'before deadline'},'is_error':False}))
            raw=check.request('tools/call',{'name':'echo','arguments':{'value':'later'}})
            self.assertTrue(d.invoke(dict(action='blob_begin',slot='frame',size=len(raw),digest=hashlib.sha256(raw).hexdigest()))['ok'])
            self.assertTrue(d.invoke(dict(action='blob_append',slot='frame',offset=0,bytes_hex=raw[:-1].hex()))['ok'])
            time.sleep(30.25)
            late=d.invoke(dict(action='blob_append',slot='frame',offset=len(raw)-1,bytes_hex=raw[-1:].hex()))
            self.assertFalse(late['ok']);self.assertEqual(late['result']['error'],'mcp_server.blob_expired')
            self.assertFalse(d.invoke(dict(action='decode',frame_id='frame-1'))['ok'])
            self.assertEqual(d.decode(raw)['action'],'invoke')
            complete=d.invoke(dict(action='encode',frame_id='frame-1'))
            self.assertTrue(complete['ok'])
            self.assertEqual(check.response(complete['result'])['result']['structuredContent'],{'verified':'before deadline'})
        finally:d.close()

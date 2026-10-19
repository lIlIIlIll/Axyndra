#!/usr/bin/env python3
"""Run the actual packaged powerless decoder. This is wire/business proof,
not Product authorization or SQLite ingress proof. No host broker is provided.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import sys
import time
import unittest

BINARY = None
IDENTITY = ('protocol','extension_id','extension_version','generation','id','tool','kind',
            'command_id','thread_id','run_id','epoch','operation_id','call_id')
META = {'io.modelcontextprotocol/protocolVersion': '2026-07-28',
        'io.modelcontextprotocol/clientCapabilities': {}}
def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
def request(method, params=None, request_id='request-1'):
    return encode({'jsonrpc':'2.0','id':request_id,'method':method,'params':{'_meta':META, **(params or {})}})

class Decoder:
    def __init__(self, profile=None, payload=None, expect_ready=True):
        env = {k:v for k,v in os.environ.items() if k not in ('LD_LIBRARY_PATH','CANGJIE_HOME','CANGJIE_STDX_PATH')}
        self.process = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.frames = queue.Queue(); self.counter = 0
        self.profile = profile; self.payload = payload; self.current = None; self.logical_results = 0
        self.frame_limit = 262144 if profile is None else 4194304
        def read():
            try:
                for line in self.process.stdout:
                    if len(line) > self.frame_limit+1 or not line.endswith(b'\n'): raise AssertionError('unbounded native frame')
                    self.frames.put(json.loads(line))
            except BaseException as error: self.frames.put(error)
            finally: self.frames.put(EOFError())
        self.reader = threading.Thread(target=read, daemon=True); self.reader.start()
        hello={'type':'hello','protocol':'axyndra-js-host-v2','extension_id':'mcp-server',
               'extension_version':'1.0.0','generation':7,'capabilities':[]}
        if profile is not None: hello.update(service_protocol_limits=profile,max_frame_bytes=profile.get('max_frame_bytes',4194304))
        if payload is not None: hello['service_payload_limits']=payload
        self.send(hello)
        if expect_ready:
            try:
                ready = self.next()
                assert ready['type']=='ready' and ready['capabilities']==[] and ready['tools']==[] and ready['commands']==[]
                assert ready['services']==[{'name':'decoder','description':'Powerless MCP server frame decoder'}]
            except BaseException:
                self.close();raise
    def send(self, value):
        self.process.stdin.write(encode(value)+b'\n'); self.process.stdin.flush()
    def physical(self, timeout=6):
        value = self.frames.get(timeout=timeout)
        if isinstance(value, BaseException): raise value
        assert value['type'] not in ('service_request','progress'),value
        return value
    def next(self):
        until=time.monotonic()+6
        value=self.physical()
        if value['type']!='payload_begin':return value
        self.logical_results+=1
        header=value['payload'];assert self.payload is not None
        assert set(header)=={'schema','window','transfer_sequence','message_type','bytes','sha256'}
        assert header['schema']=='axyndra.logical-json/v1' and header['transfer_sequence']==1 and header['message_type']=='result'
        assert header['window']==self.current['payload_window'] and 0<header['bytes']<=self.payload['max_message_bytes']
        for key in IDENTITY:assert value[key]==self.current[key]
        data=bytearray()
        while True:
            part=self.physical(max(.001,until-time.monotonic()));assert time.monotonic()<until
            for key in IDENTITY:assert part[key]==value[key]
            item=part['payload']
            assert item['schema']==header['schema'] and item['window']==header['window'] and item['transfer_sequence']==1
            if part['type']=='payload_end':
                assert set(item)=={'schema','window','transfer_sequence'};break
            assert part['type']=='payload_chunk' and set(item)=={'schema','window','transfer_sequence','offset','bytes_hex'}
            assert item['offset']==len(data)
            raw=bytes.fromhex(item['bytes_hex']);assert 0<len(raw)<=16384 and len(raw)+len(data)<=header['bytes']
            data.extend(raw)
        assert len(data)==header['bytes'] and hashlib.sha256(data).hexdigest()==header['sha256']
        result=json.loads(data);assert result['payload_window']==header['window']
        for key in IDENTITY:assert result[key]==value[key]
        return result
    def frame(self, args):
        self.counter += 1
        frame = {'type':'invoke','protocol':'axyndra-js-host-v2','extension_id':'mcp-server','extension_version':'1.0.0',
                'generation':7,'id':f'invoke-{self.counter}','tool':'decoder','kind':'service_prepare','command_id':'',
                'thread_id':'actual-maintenance','run_id':f'actual-run-{self.counter}','epoch':3,
                'operation_id':'','call_id':f'actual-call-{self.counter}','arguments':args}
        if self.payload is not None:frame['payload_window']='native-json-'+frame['id']
        return frame
    def invoke(self, args):
        frame = self.frame(args); self.current=frame; self.send(frame); result = self.next()
        assert result['type']=='result', result  # Any service/progress frame fails.
        for field in IDENTITY: assert result[field]==frame[field], (field,result)
        return result
    def upload(self, slot, raw):
        result = self.invoke({'action':'blob_begin','slot':slot,'size':len(raw),'digest':hashlib.sha256(raw).hexdigest()})
        assert result['ok'], result
        chunk=4096 if self.payload is None else min(131072,(self.payload['max_input_bytes']-1024)//2)
        for offset in range(0,len(raw),chunk):
            result=self.invoke({'action':'blob_append','slot':slot,'offset':offset,'bytes_hex':raw[offset:offset+chunk].hex()})
            assert result['ok'], result
    def catalogue(self, tools=None):
        self.upload('catalogue',encode(tools if tools is not None else [
            {'name':'echo','description':'host export','input_schema':{'type':'object','properties':{'value':{'type':'string'}},'required':['value']}}]))
    def decode(self, raw):
        self.upload('frame',raw); result=self.invoke({'action':'decode','frame_id':'frame-1'}); assert result['ok'], result
        return result['result']
    def encode_result(self, value):
        self.upload('result',encode(value)); result=self.invoke({'action':'encode','frame_id':'frame-1'}); assert result['ok'], result
        return result['result']
    def close(self):
        try:
            if self.process.stdin: self.process.stdin.close()
            self.process.wait(timeout=2)
        except (subprocess.TimeoutExpired,BrokenPipeError):
            self.process.kill(); self.process.wait(timeout=2)
        finally:
            self.process.stdout.close(); self.process.stderr.close(); self.reader.join(timeout=1)

def response(directive):
    assert directive['action']=='respond'
    return json.loads(bytes.fromhex(directive['response_hex']))

class PackagedDecoderTests(unittest.TestCase):
    def setUp(self): self.decoder=Decoder()
    def tearDown(self): self.decoder.close()
    def test_discovery_and_empty_catalogue(self):
        d=self.decoder; d.catalogue([])
        self.assertIn('result',response(d.decode(request('server/discover'))))
        self.assertEqual(response(d.decode(request('tools/list')))['result']['tools'],[])
    def test_actual_library_schema_rejects_before_invoke(self):
        d=self.decoder; d.catalogue()
        error=response(d.decode(request('tools/call',{'name':'echo','arguments':{'value':42}})))['error']
        self.assertEqual(error['code'],-32602); self.assertEqual(error['data']['code'],'mcp.invalid_params')
    def test_unicode_call_and_completed_result_shape(self):
        d=self.decoder; d.catalogue()
        value='Unicode 雪 &=+?#/%'
        proposed=d.decode(request('tools/call',{'name':'echo','arguments':{'value':value}}))
        self.assertEqual(proposed['action'],'invoke'); self.assertEqual(proposed['arguments'],{'value':value})
        result=response(d.encode_result({'status':'complete','output':{'value':value},'is_error':False}))
        self.assertEqual(result['id'],'request-1'); self.assertEqual(result['result']['structuredContent'],{'value':value})
        self.assertFalse(result['result'].get('isError',False))
    def test_host_approval_failure_is_protocol_error(self):
        d=self.decoder; d.catalogue()
        proposed=d.decode(request('tools/call',{'name':'echo','arguments':{'value':'x'}}))
        self.assertEqual(proposed['action'],'invoke')
        error=response(d.encode_result({'status':'error','code':'external.approval_required'}))['error']
        self.assertEqual(error['code'],-32603); self.assertEqual(error['data']['code'],'external.approval_required')
    def test_cancellation_preserves_typed_id(self):
        d=self.decoder; d.catalogue()
        for value, kind, text in [(1,'number','1'),('1','text','1'),(None,'null','')]:
            result=d.decode(encode({'jsonrpc':'2.0','method':'notifications/cancelled','params':{'requestId':value}}))
            self.assertEqual(result['action'],'cancel'); self.assertEqual(result['request_id'],{'kind':kind,'value':text})
    def test_invalid_json_is_bounded_parse_response(self):
        d=self.decoder; d.catalogue(); self.assertEqual(response(d.decode(b'{broken'))['error']['code'],-32700)
    def test_unknown_and_task_methods_remain_explicit_errors(self):
        d=self.decoder; d.catalogue()
        for method in ('made/up','initialize'):
            self.assertEqual(response(d.decode(request(method)))['error']['code'],-32601)
        self.assertEqual(response(d.decode(request('tasks/get')))['error']['code'],-32021)
        task_meta={**META,'io.modelcontextprotocol/clientCapabilities':{
            'extensions':{'io.modelcontextprotocol/tasks':{}}}}
        self.assertEqual(response(d.decode(request('tasks/get',{'_meta':task_meta})))['error']['code'],-32601)
    def test_missing_protocol_meta_is_not_an_invocation(self):
        d=self.decoder; d.catalogue()
        raw=encode({'jsonrpc':'2.0','id':'x','method':'tools/call','params':{'name':'echo','arguments':{'value':'x'}}})
        error=response(d.decode(raw))['error']
        self.assertEqual(error['code'],-32602); self.assertEqual(error['message'],'MCP request requires _meta')
    def test_catalogue_is_immutable_after_first_decode(self):
        d=self.decoder; d.catalogue(); d.decode(request('tools/list'))
        self.assertFalse(d.invoke({'action':'blob_begin','slot':'catalogue','size':2,'digest':hashlib.sha256(b'[]').hexdigest()})['ok'])
    def test_blob_digest_and_offset_are_checked(self):
        d=self.decoder; d.catalogue(); d.upload('frame',b'{}')
        self.assertFalse(d.invoke({'action':'blob_append','slot':'frame','offset':0,'bytes_hex':'00'})['ok'])
    def test_service_execution_profile_is_rejected(self):
        frame=self.decoder.frame({'action':'decode','frame_id':'x'}); frame['kind']='service';frame['operation_id']='op'
        self.decoder.send(frame)
        with self.assertRaises(EOFError): self.decoder.next()
        self.assertEqual(self.decoder.process.wait(timeout=2),3)
    def test_opaque_invocation_id_wrong_type_is_rejected(self):
        frame=self.decoder.frame({});frame['id']=1;self.decoder.send(frame)
        with self.assertRaises(EOFError): self.decoder.next()
        self.assertEqual(self.decoder.process.wait(timeout=2),3)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--package',type=Path,required=True)
    args=parser.parse_args();BINARY=args.package.resolve()/'bin/mcp-server-plugin'
    if not BINARY.is_file():parser.error('actual packaged decoder is required')
    sys.modules['check']=sys.modules[__name__]
    import check_payload
    suite=unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(PackagedDecoderTests),
                             unittest.defaultTestLoader.loadTestsFromTestCase(check_payload.PackagedPayloadDecoderTests)])
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    if result.testsRun != 20 or result.skipped or not result.wasSuccessful():raise SystemExit(1)
    print('MCP server decoder packaged contract passed: 20 actual process cases')

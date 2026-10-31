#!/usr/bin/env python3
"""Real packaged Native binary tests. Wire peer is data only, not Root authority.

Worker subprocess cases test Native algorithms and actual ownership. Only the
separate Product/SQLite resource-view contracts prove Host sandbox and Source.
"""
import argparse,base64,hashlib,json,os,selectors,subprocess,sys,tempfile,time,unittest
from pathlib import Path
BINARY=None
IDS=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')
def digest(value):return hashlib.sha256(value.encode()).hexdigest()
def encoded_capture(value):
    raw=value.encode() if isinstance(value,str) else value
    return {'encoding':'base64','bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'data':base64.b64encode(raw).decode()}
def encoded_worker_body(value):
    return dict(value,stdout=encoded_capture(value['stdout']),stderr=encoded_capture(value['stderr']))
def decoded_worker_body(value):
    if 'error' in value:return value
    assert set(value)=={'exit_code','stdout','stderr','timed_out','truncated'}
    result=dict(value);total=0
    for key in ('stdout','stderr'):
        item=value[key];assert set(item)=={'encoding','bytes','sha256','data'} and item['encoding']=='base64'
        raw=base64.b64decode(item['data'],validate=True);assert base64.b64encode(raw).decode()==item['data']
        assert len(raw)==item['bytes'] and hashlib.sha256(raw).hexdigest()==item['sha256'];total+=len(raw)
        result[key]=raw.decode('utf-8',errors='replace')
    assert total<=131072
    return result
def scalar(value):
    kind='text' if isinstance(value,str) else 'number'
    raw=value if kind=='text' else str(value)
    node={'type':kind,'utf8_bytes':len(raw.encode()),'sha256':digest(raw),'has_nul':kind=='text' and '\0' in raw}
    if kind!='text' or len(json.dumps(value,ensure_ascii=False,separators=(',',':')).encode())<=8192:node['value']=value
    return node
def reference(frame,arguments,cwd='.'):
    encoded=json.dumps(arguments,ensure_ascii=False,separators=(',',':'))
    return {'binding':{'thread_id':frame['thread_id'],'run_id':frame['run_id'],'epoch':frame['epoch'],
        'call_id':frame['call_id'],'tool_name':'plugin.axyndra:shell-readonly.exec','plugin':'axyndra:shell-readonly',
        'contribution':'exec','package_digest':'sha256:'+digest('actual-fixture-package'),'generation':'7',
        'configuration_digest':digest('actual-fixture-config'),'working_directory':cwd},
        'input_bytes':len(encoded.encode()),'input_sha256':digest(encoded),
        'metadata':{'type':'object','fields':[{'name':key,'node':scalar(value)} for key,value in arguments.items()]}}
class Peer:
    def __init__(self,payload=False):
        self.payload=payload
        self.pending=b''
        self.process=subprocess.Popen([str(BINARY)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.send({'type':'hello','protocol':'axyndra-js-host-v2','extension_id':'shell-readonly','extension_version':'1.0.0',
            'generation':7,'capabilities':['process.readview'],**({'ordinary_tool_payload':{'schema':'axyndra.ordinary-tool-payload/v1',
                'max_input_bytes':2097152,'max_result_bytes':1114112,'max_service_response_bytes':1114112,'max_message_bytes':2162688}} if payload else {})})
        self.ready=self.next()
    def send(self,value):
        self.process.stdin.write((json.dumps(value,separators=(',',':'))+'\n').encode());self.process.stdin.flush()
    def next(self,timeout=5):
        deadline=time.monotonic()+timeout
        while b'\n' not in self.pending:
            remaining=deadline-time.monotonic()
            if remaining<=0:raise AssertionError('bounded actual Native response timed out')
            with selectors.DefaultSelector() as selected:
                selected.register(self.process.stdout,selectors.EVENT_READ)
                if not selected.select(remaining):
                    raise AssertionError('bounded actual Native response timed out')
            raw=os.read(self.process.stdout.fileno(),16384)
            if not raw:
                pending=self.pending;self.pending=b''
                return None if not pending else json.loads(pending)
            self.pending+=raw
        raw,self.pending=self.pending.split(b'\n',1)
        return json.loads(raw)
    def frame(self,kind='tool',arguments=None):
        return {'type':'invoke','protocol':'axyndra-js-host-v2','extension_id':'shell-readonly','extension_version':'1.0.0',
            'generation':7,'id':'call-1','tool':'exec','kind':kind,'command_id':'','thread_id':'thread-1','run_id':'run-1',
            'epoch':1,'operation_id':'' if kind=='prepare' else 'operation-1','call_id':'tool-call-1',
            'arguments':arguments or {'command':'cat input.txt'}}
    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait(timeout=5)
        self.process.stdin.close();self.process.stdout.close();self.process.stderr.close()
    def __enter__(self):return self
    def __exit__(self,*args):self.close()
def worker(directory,input,cwd='.',timeout=5):
    (Path(directory)/'.axyndra-worker-input.json').write_text(json.dumps(input,separators=(',',':')),encoding='utf-8')
    completed=subprocess.run([str(BINARY),'--view-worker-file',cwd],cwd=directory,capture_output=True,timeout=timeout)
    return completed,decoded_worker_body(json.loads(completed.stdout))


def service_response(frame,body):
    result={key:frame[key] for key in IDS}
    result.update(type='service_response',request_id='readonly-shell-1',ok=True,
        result={'request_id':'readonly-shell-1','service':'process.readview','receipt_id':'wire-only-fixture-receipt',
            'is_error':False,'output':{'exit_code':0,'stdout':json.dumps(body,separators=(',',':')),
            'stderr':'','timed_out':False,'truncated':False}})
    return result
def receive_logical(peer):
    first=peer.next()
    if first is None or first['type']!='payload_begin':return first
    header=first['payload'];body=bytearray()
    assert header['schema']=='axyndra.logical-json/v1' and header['message_type']=='result'
    assert header['window']=='wire-output-window' and header['transfer_sequence']==1 and header['bytes']<=1056768
    while True:
        frame=peer.next();assert all(frame[key]==first[key] for key in IDS)
        value=frame['payload'];assert value['window']==header['window'] and value['transfer_sequence']==1
        if frame['type']=='payload_end':break
        assert frame['type']=='payload_chunk' and value['offset']==len(body) and len(value['bytes_hex'])<=32768
        raw=bytes.fromhex(value['bytes_hex']);assert raw.hex()==value['bytes_hex'];body.extend(raw)
        assert len(body)<=header['bytes']
    assert len(body)==header['bytes'] and hashlib.sha256(body).hexdigest()==header['sha256']
    result=json.loads(body);assert all(result[key]==first[key] for key in IDS)
    assert result['payload_window']==header['window'];return result
def payload_frame(peer):
    frame=peer.frame();frame['payload_window']='wire-output-window'
    frame['tool_payload_limits']={'schema':'axyndra.ordinary-tool-payload/v1','contribution':'exec','max_input_bytes':229376,
        'max_result_bytes':1048576,'max_service_response_bytes':262144,'max_message_bytes':1056768}
    return frame

class NativeReadonlyShellPackageTests(unittest.TestCase):
    def test_two_frames_in_one_burst_are_read_before_waiting_for_another_pipe_notification(self):
        peer=Peer.__new__(Peer);peer.pending=b''
        peer.process=subprocess.Popen([sys.executable,'-B','-c',
            'import os,sys;os.write(1,b\'{"frame":1}\\n{"frame":2}\\n\');sys.stdin.buffer.readline()'],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        with peer:
            self.assertEqual(peer.next(),{'frame':1})
            self.assertEqual(peer.next(),{'frame':2})
            self.assertIsNone(peer.process.poll())
            peer.process.stdin.write(b'ACK\n');peer.process.stdin.flush()
            self.assertIsNone(peer.next());self.assertEqual(peer.process.wait(timeout=5),0)

    def test_ready_is_exact_ordinary_tool_and_has_no_idle_effects(self):
        with Peer() as peer:
            self.assertEqual(peer.ready['type'],'ready');self.assertEqual([v['name'] for v in peer.ready['tools']],['exec'])
            self.assertEqual(peer.ready['commands'],[]);self.assertEqual(peer.ready['hooks'],[])
            schema=peer.ready['tools'][0]['input_schema']
            self.assertEqual(schema['properties']['command']['maxLength'],131072)
            self.assertEqual(schema['properties']['timeout_ms']['maximum'],600000)
            with selectors.DefaultSelector() as selected:
                selected.register(peer.process.stdout,selectors.EVENT_READ);self.assertEqual(selected.select(.05),[])
    def test_pure_preparation_returns_the_exact_reference_and_actual_cwd_argv(self):
        with Peer() as peer:
            frame=peer.frame('prepare');ref=reference(frame,{'command':'cat input.txt'},'subdirectory')
            frame['arguments']={'schema':'axyndra.read-view-parameter-input/v1','reference':ref};peer.send(frame)
            response=peer.next();self.assertTrue(response['ok'])
            intent=response['result']['intents'][0]
            self.assertEqual(intent['request']['input_reference'],ref)
            self.assertEqual(intent['request']['arguments'],['--view-worker-file','subdirectory'])
            self.assertEqual(intent['resources'],[{'source':'.','path':'.','mode':'directory'}])
    def test_long_command_metadata_keeps_the_complete_actual_input_reference(self):
        with Peer() as peer:
            frame=peer.frame('prepare');ref=reference(frame,{'command':'#'+'a'*131071,'timeout_ms':600000})
            frame['arguments']={'schema':'axyndra.read-view-parameter-input/v1','reference':ref};peer.send(frame)
            response=peer.next();self.assertTrue(response['ok'])
            self.assertEqual(response['result']['intents'][0]['request']['timeout_ms'],600000)
            self.assertEqual(response['result']['intents'][0]['request']['input_reference'],ref)
    def test_normal_invocation_consumes_only_the_correlated_service_receipt(self):
        with Peer() as peer:
            frame=peer.frame();peer.send(frame);request=peer.next()
            self.assertEqual(request['service'],'process.readview');self.assertEqual(request['arguments'],{'intent_id':'readonly-shell-1'})
            response={key:frame[key] for key in IDS};response.update(type='service_response',request_id='readonly-shell-1',ok=True,
                result={'request_id':'readonly-shell-1','service':'process.readview','receipt_id':'actual-fixture-receipt',
                    'is_error':False,'output':{'exit_code':0,'stdout':json.dumps(encoded_worker_body({'exit_code':0,'stdout':'EXACT','stderr':'',
                        'timed_out':False,'truncated':False})),'stderr':'','timed_out':False,'truncated':False}})
            peer.send(response);result=peer.next();self.assertTrue(result['ok']);self.assertEqual(result['result']['stdout'],'EXACT')
    def test_other_call_response_cannot_complete_the_held_invocation(self):
        with Peer() as peer:
            frame=peer.frame();peer.send(frame);peer.next()
            reply={key:frame[key] for key in IDS};reply.update(type='service_response',request_id='readonly-shell-1',ok=True,call_id='other-call')
            peer.send(reply);self.assertIsNone(peer.next());self.assertEqual(peer.process.wait(timeout=5),3)
    def test_missing_receipt_cannot_report_a_completed_worker(self):
        with Peer() as peer:
            frame=peer.frame();peer.send(frame);peer.next()
            reply={key:frame[key] for key in IDS};reply.update(type='service_response',request_id='readonly-shell-1',ok=True,
                result={'request_id':'readonly-shell-1','service':'process.readview','receipt_id':'','output':{}})
            peer.send(reply);self.assertIsNone(peer.next());self.assertEqual(peer.process.wait(timeout=5),3)
    def test_unknown_fields_nul_and_oversized_commands_never_request_a_service(self):
        for arguments in [{'command':'printf x','grant':True},{'command':'printf \0'}, {'command':'a'*131073},
                          {'command':'printf x','timeout_ms':600001}]:
            with Peer() as peer:
                peer.send(peer.frame(arguments=arguments));response=peer.next()
                self.assertEqual(response['type'],'result');self.assertFalse(response['ok'])
    def test_forged_package_tag_or_context_reference_is_rejected_in_prepare(self):
        for field,value in [('package_digest',digest('raw-only')),('working_directory','../foreign'),('run_id','other-run')]:
            with Peer() as peer:
                frame=peer.frame('prepare');ref=reference(frame,{'command':'printf x'});ref['binding'][field]=value
                frame['arguments']={'schema':'axyndra.read-view-parameter-input/v1','reference':ref};peer.send(frame)
                response=peer.next();self.assertFalse(response['ok']);self.assertEqual(response['type'],'result')
    def test_real_worker_combines_exact_capture_with_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            result,body=worker(directory,{'command':"printf '%*s' 131077 ''"})
            self.assertEqual(result.returncode,0);self.assertEqual(body['exit_code'],0)
            self.assertEqual(len(body['stdout'].encode())+len(body['stderr'].encode()),131072);self.assertTrue(body['truncated'])
    def test_real_worker_timeout_returns_124_and_keeps_partial_output(self):
        with tempfile.TemporaryDirectory() as directory:
            result,body=worker(directory,{'command':'printf BEFORE; sleep 5','timeout_ms':100})
            self.assertEqual(result.returncode,0);self.assertEqual(body['exit_code'],124)
            self.assertTrue(body['timed_out']);self.assertEqual(body['stdout'],'BEFORE')
    def test_real_worker_uses_frozen_current_subdirectory_and_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            nested=Path(directory)/'nested';nested.mkdir();(nested/'input.txt').write_text('WORKSPACE')
            result,body=worker(directory,{'command':'printf "%s:" "$EXACT_VALUE"; cat input.txt','env':{'EXACT_VALUE':'VALUE'}},cwd='nested')
            self.assertEqual(result.returncode,0);self.assertEqual(body['stdout'],'VALUE:WORKSPACE');self.assertEqual(body['exit_code'],0)
    def test_real_worker_business_refusal_performs_no_file_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            result,body=worker(directory,{'command':'touch changed.txt'})
            self.assertEqual(result.returncode,3);self.assertEqual(body['error'],'tool.readonly_rejected');self.assertFalse((Path(directory)/'changed.txt').exists())
    def test_real_worker_finished_leader_does_not_leave_descendant_output_pipes_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            start=time.monotonic();result,body=worker(directory,{'command':'sleep 5 & printf FINISHED','timeout_ms':200})
            self.assertEqual(result.returncode,0);self.assertLess(time.monotonic()-start,3)
            self.assertEqual(body['stdout'],'FINISHED');self.assertEqual(body['exit_code'],0)

    def test_real_worker_control_capture_keeps_all_original_bytes_and_encoded_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            result,body=worker(directory,{'command':r"for ((i=0;i<131077;i++));do printf '\001';done"},timeout=15)
            self.assertEqual(result.returncode,0);self.assertEqual(body['stdout'],'\x01'*131072)
            self.assertEqual(body['stderr'],'');self.assertTrue(body['truncated'])
            self.assertLess(len(result.stdout),229376)
    def test_real_worker_invalid_utf8_keeps_original_per_byte_replacement_and_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            result,body=worker(directory,{'command':r"for ((i=0;i<131072;i++));do printf '\377';done"},timeout=15)
            self.assertEqual(result.returncode,0);self.assertEqual(body['stdout'],'\ufffd'*131072)
            self.assertEqual(len(body['stdout'].encode()),393216);self.assertFalse(body['truncated'])
            self.assertLess(len(result.stdout),229376)
    def test_private_encoding_corruption_padding_length_hash_and_unknown_fields_poison_output(self):
        for mutation in ('hash','length','padding','extra'):
            with Peer() as peer:
                frame=peer.frame();peer.send(frame);peer.next()
                body=encoded_worker_body({'exit_code':0,'stdout':'A','stderr':'','timed_out':False,'truncated':False})
                node=body['stdout']
                if mutation=='hash':node['sha256']='0'*64
                elif mutation=='length':node['bytes']=2
                elif mutation=='padding':node['data']='QR=='
                else:node['forged']=True
                peer.send(service_response(frame,body));self.assertIsNone(peer.next());self.assertEqual(peer.process.wait(timeout=5),3)
    def test_optin_logical_result_keeps_full_control_capture_and_current_identity(self):
        with Peer(payload=True) as peer:
            frame=payload_frame(peer);peer.send(frame);peer.next()
            body=encoded_worker_body({'exit_code':0,'stdout':'\x01'*131072,'stderr':'','timed_out':False,'truncated':False})
            response=service_response(frame,body)
            self.assertLess(len(json.dumps(response,separators=(',',':')).encode()),262144)
            peer.send(response);result=receive_logical(peer)
            self.assertTrue(result['ok']);self.assertEqual(result['result']['stdout'],'\x01'*131072)
            self.assertEqual(result['result']['stderr'],'');self.assertFalse(result['result']['truncated'])
    def test_optin_logical_result_keeps_invalid_utf8_capture_with_original_replacement(self):
        with Peer(payload=True) as peer:
            frame=payload_frame(peer);peer.send(frame);peer.next()
            body=encoded_worker_body({'exit_code':0,'stdout':b'\xff'*131072,'stderr':'','timed_out':False,'truncated':False})
            peer.send(service_response(frame,body));result=receive_logical(peer)
            self.assertTrue(result['ok']);self.assertEqual(result['result']['stdout'],'\ufffd'*131072)
            self.assertEqual(len(result['result']['stdout'].encode()),393216)
    def test_default_physical_result_does_not_silently_truncate_or_enable_logical_transport(self):
        with Peer() as peer:
            frame=peer.frame();peer.send(frame);peer.next()
            body=encoded_worker_body({'exit_code':0,'stdout':'\x01'*131072,'stderr':'','timed_out':False,'truncated':False})
            peer.send(service_response(frame,body));self.assertIsNone(peer.next());self.assertEqual(peer.process.wait(timeout=5),3)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);args,left=parser.parse_known_args()
    BINARY=args.binary.resolve(strict=True);unittest.main(argv=[__file__,*left],verbosity=2)

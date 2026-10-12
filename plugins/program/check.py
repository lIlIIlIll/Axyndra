#!/usr/bin/env python3
"""Actual packaged Program endpoint; host-response fixtures are wire tests, not Store authority."""
import argparse
import hashlib
import queue
import threading
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import unittest

PACKAGE = None
OFFER = dict(schema="axyndra.ordinary-tool-payload/v1", max_input_bytes=2097152, max_result_bytes=1114112, max_service_response_bytes=1114112, max_message_bytes=2162688)
PROFILE = dict(OFFER, contribution="run")
KEYS = ['protocol', 'extension_id', 'extension_version', 'generation', 'id', 'tool', 'kind',
        'command_id', 'thread_id', 'run_id', 'epoch', 'operation_id', 'call_id']


class Peer:
    def __init__(self, payload=False):
        self.directory = tempfile.TemporaryDirectory(prefix='program-package-')
        env = os.environ.copy()
        for key in ['LD_LIBRARY_PATH', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH', 'AXYNDRA_SDK_ROOT']:
            env.pop(key, None)
        self.process = subprocess.Popen([str(PACKAGE / 'bin/program-plugin')], cwd=self.directory.name,
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.frames = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True); self.reader.start()
        self.payload = payload
        self.send(dict(type='hello', protocol='axyndra-js-host-v2', extension_id='program',
            extension_version='1.0.0', generation=7, capabilities=['tool.readonly'], ordinary_tool_payload=OFFER if payload else None))
        ready = self.receive()
        assert ready['type'] == 'ready' and [item['name'] for item in ready['tools']] == ['run']
    def __enter__(self): return self
    def __exit__(self, *unused):
        if self.process.stdin:
            self.process.stdin.close()
        try: self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait(timeout=5)
        self.reader.join(timeout=5)
        self.process.stdout.close(); self.process.stderr.close(); self.directory.cleanup()
    def send(self, value):
        self.process.stdin.write((json.dumps(value, separators=(',', ':')) + '\n').encode()); self.process.stdin.flush()
    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(262146)
                self.frames.put(line)
                if not line: return
        except BaseException as error: self.frames.put(error)
    def physical(self, eof=False):
        line = self.frames.get(timeout=10)
        if isinstance(line, BaseException): raise line
        if eof:
            if line: raise AssertionError('poisoned identity returned output: ' + repr(line[:200]))
            return None
        if not line or len(line) > 262145 or not line.endswith(b'\n'): raise AssertionError('invalid Program frame')
        return json.loads(line)
    def receive(self, eof=False):
        first = self.physical(eof=eof)
        if eof or first['type'] != 'payload_begin': return first
        header = first['payload']; body = bytearray()
        assert header['schema'] == 'axyndra.logical-json/v1' and header['message_type'] == 'result'
        assert header['bytes'] <= OFFER['max_message_bytes'] and header['transfer_sequence'] == 1
        while True:
            frame = self.physical(); assert all(frame[k] == first[k] for k in KEYS)
            data = frame['payload']
            assert data['window'] == header['window'] and data['transfer_sequence'] == 1
            if frame['type'] == 'payload_end': break
            assert frame['type'] == 'payload_chunk' and data['offset'] == len(body)
            body.extend(bytes.fromhex(data['bytes_hex']))
        assert len(body) == header['bytes'] and hashlib.sha256(body).hexdigest() == header['sha256']
        result = json.loads(body); assert all(result[k] == first[k] for k in KEYS)
        assert result['payload_window'] == header['window']; return result
    def receive_request(self, sequence):
        first=self.physical()
        if first['type']!='payload_begin':return first
        h=first['payload'];body=bytearray()
        assert h['schema']=='axyndra.logical-json/v1' and h['message_type']=='service_request'
        assert h['transfer_sequence']==sequence and h['bytes']<=1048576 and h['window']=='program-window'
        while True:
            f=self.physical();assert all(f[k]==first[k] for k in KEYS)
            q=f['payload'];assert q['window']==h['window'] and q['transfer_sequence']==sequence
            if f['type']=='payload_end':break
            assert f['type']=='payload_chunk' and q['offset']==len(body);body.extend(bytes.fromhex(q['bytes_hex']))
        assert len(body)==h['bytes'] and hashlib.sha256(body).hexdigest()==h['sha256']
        result=json.loads(body);assert all(result[k]==first[k] for k in KEYS)
        assert result['type']=='service_request' and result['payload_window']==h['window']
        return result

    def logical(self, frame, sequence=1, window='program-window', stop=False):
        body = json.dumps(frame, separators=(',', ':'), ensure_ascii=True).encode()
        outer = {key: frame[key] for key in KEYS}
        common = dict(schema='axyndra.logical-json/v1', window=window, transfer_sequence=sequence)
        self.send(dict(outer, type='payload_begin', payload=dict(common, message_type=frame['type'], bytes=len(body), sha256=hashlib.sha256(body).hexdigest())))
        if stop: return
        for offset in range(0, len(body), 16384):
            self.send(dict(outer, type='payload_chunk', payload=dict(common, offset=offset, bytes_hex=body[offset:offset+16384].hex())))
        self.send(dict(outer, type='payload_end', payload=common))
    def invoke(self, code, **overrides):
        frame = dict(type='invoke', protocol='axyndra-js-host-v2', extension_id='program', extension_version='1.0.0',
            generation=7, id='invoke-1', tool='run', kind='tool', command_id='', thread_id='thread', run_id='run',
            epoch=1, operation_id='root', call_id='call', arguments={'code': code})
        frame.update(overrides)
        if self.payload:
            frame.update(payload_window='program-window', tool_payload_limits=PROFILE)
            if len(json.dumps(frame)) > 262144: self.logical(frame)
            else: self.send(frame)
        else: self.send(frame)
        return frame
    def response(self, request, output, receipt='wire-fixture-receipt', **overrides):
        frame = {key: request[key] for key in KEYS}
        frame.update(type='service_response', request_id=request['request_id'], ok=True,
            result=dict(request_id=request['request_id'], service='tool.readonly', receipt_id=receipt,
                        is_error=False, output=output))
        frame.update(overrides)
        if self.payload and len(json.dumps(frame)) > 262144:
            sequence = 1 + int(request['request_id'].rsplit('-', 1)[1]); self.logical(frame, sequence=sequence)
        else: self.send(frame)


class ProgramPackageTests(unittest.TestCase):
    def test_literal_has_no_host_io(self):
        with Peer() as peer:
            peer.invoke('return {"text":"雪"};')
            result = peer.receive(); self.assertEqual(result['type'], 'result')
            self.assertTrue(result['ok']); self.assertEqual(result['result']['value'], {'text': '雪'})
            self.assertEqual(result['result']['sub_call_count'], 0)
    def test_actual_compiler_and_interpreter_use_typed_readonly_service(self):
        with Peer() as peer:
            peer.invoke('const data = await tools.read({"path":"first.txt"}); return data;')
            request = peer.receive(); self.assertEqual(request['service'], 'tool.readonly')
            self.assertEqual(request['arguments'], {'tool': 'read', 'input': {'path': 'first.txt'}})
            peer.response(request, {'content': 'actual-wire-value'})
            reply = peer.receive(); self.assertTrue(reply['ok'])
            self.assertEqual(reply['result']['value'], {'content': 'actual-wire-value'})
            self.assertEqual(reply['result']['sub_call_count'], 1)
    def test_two_calls_have_distinct_receipt_correlation(self):
        with Peer() as peer:
            peer.invoke('const a = await tools.read({"path":"a"}); const b = await tools.read({"path":"b"}); return b;')
            first = peer.receive(); peer.response(first, {'v': 1})
            second = peer.receive(); self.assertNotEqual(second['request_id'], first['request_id']); peer.response(second, {'v': 2})
            self.assertEqual(peer.receive()['result']['value'], {'v': 2})
    def test_missing_receipt_cannot_publish_success(self):
        with Peer() as peer:
            peer.invoke('return await tools.read({"path":"a"});')
            peer.response(peer.receive(), {'v': 1}, receipt='')
            result = peer.receive(); self.assertFalse(result['ok']); self.assertEqual(result['result']['status'], 'recovery_required')
    def test_wrong_identity_is_fatal_without_terminal(self):
        with Peer() as peer:
            peer.invoke('return await tools.read({"path":"a"});')
            peer.response(peer.receive(), {}, epoch=2)
            peer.receive(eof=True); self.assertEqual(peer.process.wait(timeout=5), 3)
    def test_cancel_matches_actual_pending_invocation(self):
        with Peer() as peer:
            invocation = peer.invoke('return await tools.read({"path":"a"});')
            self.assertEqual(peer.receive()['type'], 'service_request')
            peer.send({**{key: invocation[key] for key in KEYS}, 'type': 'cancel'})
            self.assertEqual(peer.receive()['type'], 'cancelled'); peer.receive(eof=True)
    def test_forbidden_syntax_never_creates_service_request(self):
        with Peer() as peer:
            peer.invoke('import arbitrary; return 1;')
            result = peer.receive(); self.assertEqual(result['type'], 'result'); self.assertFalse(result['ok'])
    def test_duplicate_invocation_is_not_replayed(self):
        with Peer() as peer:
            invocation = peer.invoke('return 1;'); self.assertTrue(peer.receive()['ok'])
            peer.send(invocation); peer.receive(eof=True)

    def test_logical_raw_256k_source_reaches_actual_compiler(self):
        with Peer(payload=True) as peer:
            code = ' ' * (262144 - len('return 1;')) + 'return 1;'
            peer.invoke(code); reply = peer.receive(); self.assertTrue(reply['ok']); self.assertEqual(reply['result']['value'], 1)
    def test_json_escaped_256k_source_is_bounded_and_not_a_prepare_frame(self):
        with Peer(payload=True) as peer:
            # The exact raw source is invalid DSL; its 1.5 MiB JSON envelope
            # must reach the real compiler and return its syntax error.
            code = '\x00' * 262144
            self.assertGreater(len(json.dumps(dict(code=code))), 1500000)
            peer.invoke(code); reply = peer.receive()
            self.assertFalse(reply['ok']); self.assertEqual(reply['result']['error'], 'tool_program.parse')
    def test_source_over_raw_256k_is_rejected_before_service_io(self):
        with Peer(payload=True) as peer:
            peer.invoke(' ' * 262145); reply = peer.receive()
            self.assertFalse(reply['ok']); self.assertEqual(reply['result']['error'], 'tool_program.source_limit')
    def test_large_service_response_and_terminal_share_actual_value(self):
        with Peer(payload=True) as peer:
            peer.invoke('return await tools.read({"path":"large"});')
            text = 'x' * 900000; peer.response(peer.receive(), {'text': text})
            reply = peer.receive(); self.assertTrue(reply['ok']); self.assertEqual(reply['result']['value']['text'], text)
    def test_two_large_responses_retain_values_until_interpretation_ends(self):
        with Peer(payload=True) as peer:
            peer.invoke('const a = await tools.read({"path":"a"}); const b = await tools.read({"path":"b"}); return a;')
            peer.response(peer.receive(), {'text': 'a' * 400000})
            peer.response(peer.receive(), {'text': 'b' * 400000})
            self.assertEqual(peer.receive()['result']['value']['text'], 'a' * 400000)
    def test_original_tree_cost_boundary_remains_one_mib(self):
        # Original programValueBytes: object8 + key('text')4 + text8 + bytes.
        for size, accepted in [(1048576 - 20, True), (1048576 - 19, False)]:
            with self.subTest(size=size), Peer(payload=True) as peer:
                peer.invoke('return await tools.read({"path":"boundary"});')
                text = 'x' * size
                peer.response(peer.receive(), {'text': text})
                reply = peer.receive(); self.assertEqual(reply['ok'], accepted)
                if accepted:
                    self.assertEqual(reply['result']['value']['text'], text)
                else:
                    self.assertEqual(reply['result']['error_code'], 'tool_program.result_limit')
    def test_large_input_bound_is_host_selected_and_not_self_expanded(self):
        with Peer(payload=True) as peer:
            invocation = dict(type='invoke', protocol='axyndra-js-host-v2', extension_id='program',
                extension_version='1.0.0', generation=7, id='forged-limit', tool='run', kind='tool',
                command_id='', thread_id='thread', run_id='run', epoch=1, operation_id='root', call_id='call',
                arguments={'code':'return 1;'}, payload_window='program-window',
                tool_payload_limits=dict(PROFILE, max_input_bytes=2097153))
            peer.send(invocation); peer.receive(eof=True)

    def test_logical_wrong_window_poison_cannot_publish_result(self):
        with Peer(payload=True) as peer:
            invocation = peer.invoke('return await tools.read({"path":"a"});'); request = peer.receive()
            frame = {key: invocation[key] for key in KEYS}; frame.update(type='service_response', request_id=request['request_id'], ok=True, result={})
            peer.logical(frame, sequence=2, window='another-invocation'); peer.receive(eof=True)
    def test_cancel_during_large_service_payload_has_no_success(self):
        with Peer(payload=True) as peer:
            invocation = peer.invoke('return await tools.read({"path":"a"});'); request = peer.receive()
            frame = {key: invocation[key] for key in KEYS}; frame.update(type='service_response', request_id=request['request_id'], ok=True, result={'text':'x'*400000})
            peer.logical(frame, sequence=2, stop=True)
            peer.send({**{key:invocation[key] for key in KEYS}, 'type':'cancel'})
            self.assertEqual(peer.receive()['type'], 'cancelled'); peer.receive(eof=True)
    def test_logical_input_without_host_offer_is_rejected(self):
        with Peer() as peer:
            invocation = peer.invoke('return await tools.read({"path":"a"});'); peer.receive()
            frame = {key:invocation[key] for key in KEYS}; frame.update(type='service_response', request_id='program-call-1', ok=True, result={})
            peer.logical(frame, sequence=2); peer.receive(eof=True)
    def test_large_missing_receipt_still_cannot_publish_success(self):
        with Peer(payload=True) as peer:
            peer.invoke('return await tools.read({"path":"a"});'); peer.response(peer.receive(), {'text':'x'*400000}, receipt='')
            reply = peer.receive(); self.assertFalse(reply['ok']); self.assertEqual(reply['result']['status'], 'recovery_required')


class ProgramServiceRequestPackageTests(unittest.TestCase):
    def test_actual_static_literal_crosses_physical_request_frame_with_original_identity(self):
        prefix='return await tools.read({"text":"';suffix='"});'
        text='x'*(262144-len(prefix)-len(suffix));code=prefix+text+suffix
        self.assertEqual(len(code),262144)
        with Peer(payload=True) as peer:
            invocation=peer.invoke(code);request=peer.receive_request(2)
            self.assertEqual(request['type'],'service_request');self.assertEqual(request['arguments']['input']['text'],text)
            self.assertGreater(len(json.dumps(request,separators=(',',':')).encode()),262144)
            self.assertTrue(all(request[k]==invocation[k] for k in KEYS))
            peer.response(request,{'accepted_transport':True});reply=peer.receive()
            self.assertTrue(reply['ok']);self.assertEqual(reply['result']['value'],{'accepted_transport':True})
    def test_original_default_small_request_preserves_exact_raw_shape(self):
        with Peer() as peer:
            invocation=peer.invoke('return await tools.read({"path":"original"});')
            request=peer.physical()
            self.assertEqual(request['type'],'service_request');self.assertNotIn('payload_window',request)
            self.assertEqual(set(request),set(KEYS)|{'type','request_id','service','arguments'})
            self.assertTrue(all(request[k]==invocation[k] for k in KEYS))
            peer.response(request,{'raw_default':True});reply=peer.receive()
            self.assertTrue(reply['ok']);self.assertEqual(reply['result']['value'],{'raw_default':True})



class ProgramFilePlanRequestPackageTests(unittest.TestCase):
    # A wire peer is descriptive transport data, never a Root or grant.
    def test_near_raw_256k_application_plan_literal_uses_bounded_request_and_same_identity(self):
        prefix='return {"application_plan":{"schema":"axyndra.file-change-proposal/v1","operations":[{"kind":"create","path":"out.txt","content":"'
        suffix='"}]}};'
        content='x'*(262144-len(prefix)-len(suffix));code=prefix+content+suffix
        self.assertEqual(len(code.encode()),262144)
        with Peer(payload=True) as peer:
            invocation=peer.invoke(code);request=peer.receive_request(2)
            self.assertEqual(request['type'],'service_request')
            self.assertEqual(request['service'],'file.plan.propose')
            self.assertEqual(request['request_id'],'program-plan-1')
            proposal=request['arguments']['proposal']
            self.assertEqual(proposal,{'schema':'axyndra.file-change-proposal/v1','operations':[{'kind':'create','path':'out.txt','content':content}]})
            self.assertGreater(len(json.dumps(request,separators=(',',':')).encode()),262144)
            self.assertLessEqual(len(json.dumps(request,separators=(',',':')).encode()),1048576)
            self.assertTrue(all(request[k]==invocation[k] for k in KEYS))
            fields={key:request[key] for key in KEYS}
            observed={'transport_fixture':True,'summary':'bounded original literal'}
            peer.send(dict(fields,type='service_response',request_id=request['request_id'],ok=True,
                result=dict(request_id=request['request_id'],service='file.plan.propose',receipt_id='wire-only-preview-receipt',is_error=False,output=observed)))
            reply=peer.receive();self.assertTrue(reply['ok'])
            self.assertEqual(reply['result']['value'],{'application_plan':observed})
            self.assertEqual(reply['result']['sub_call_count'],1)

    def test_preview_missing_receipt_or_wrong_service_never_publishes_success(self):
        for receipt,service in [('', 'file.plan.propose'),('wire-only', 'tool.readonly')]:
            with self.subTest(receipt=receipt,service=service),Peer(payload=True) as peer:
                peer.invoke('return {"application_plan":{"schema":"axyndra.file-change-proposal/v1","operations":[]}};')
                request=peer.receive_request(2);fields={key:request[key] for key in KEYS}
                peer.send(dict(fields,type='service_response',request_id=request['request_id'],ok=True,
                    result=dict(request_id=request['request_id'],service=service,receipt_id=receipt,is_error=False,output={})))
                reply=peer.receive();self.assertFalse(reply['ok'])
                self.assertEqual(reply['result']['status'],'recovery_required')
                self.assertEqual(reply['result']['error_code'],'tool_program.receipt_missing')

    def test_host_refusal_is_preserved_without_a_preview_success(self):
        with Peer() as peer:
            peer.invoke('return {"application_plan":{"schema":"axyndra.file-change-proposal/v1","operations":[]}};')
            request=peer.physical();self.assertNotIn('payload_window',request)
            self.assertEqual(request['service'],'file.plan.propose')
            fields={key:request[key] for key in KEYS}
            peer.send(dict(fields,type='service_response',request_id=request['request_id'],ok=False,
                error={'code':'tool.readonly_plan_proposal_denied','message':'wire-only host refusal'}))
            reply=peer.receive();self.assertFalse(reply['ok'])
            self.assertEqual(reply['result']['status'],'failed')
            self.assertEqual(reply['result']['error_code'],'tool.readonly_plan_proposal_denied')
            self.assertEqual(reply['result']['sub_call_count'],1)
        # The interpreter used all32 actual readonly calls. An un-emitted
        # preview is refused at the same32 ceiling and must not count as33.
        with Peer(payload=True) as peer:
            code=''.join('const d'+str(i)+' = await tools.read({"path":"a"});' for i in range(32))
            code+='return {"application_plan":{"schema":"axyndra.file-change-proposal/v1","operations":[]}};'
            peer.invoke(code)
            for i in range(32):
                request=peer.receive_request(i+2)
                self.assertEqual(request['service'],'tool.readonly')
                self.assertEqual(request['request_id'],'program-call-'+str(i+1))
                peer.response(request,{'bounded_read':i})
            reply=peer.receive()
            self.assertEqual(reply['type'],'result')
            self.assertFalse(reply['ok'])
            self.assertEqual(reply['result']['status'],'failed')
            self.assertEqual(reply['result']['error_code'],'tool_program.subcall_limit')
            self.assertEqual(reply['result']['sub_call_count'],32)


class ProgramInputAttachmentPackageTests(unittest.TestCase):
    # These packets are descriptive wire fixtures. They contain NO real Root,
    # Store, Source, approval, artifact file or usable Receipt authority.
    def evidence(self, code):
        raw=code.encode('utf-8');digest=hashlib.sha256(raw).hexdigest()
        return dict(schema='axyndra.tool-input-attachment/v1',profile=dict(field='code',max_bytes=262144),
            artifact=dict(ref='blob:sha256:'+digest,sha256=digest,bytes=len(raw),content_type='text/plain; charset=utf-8'),
            thread_id='thread',run_id='run',epoch=1,operation_id='root',call_id='call',namespace='axyndra:program',
            package_digest='sha256:'+'0'*64,generation='7',configuration_digest='1'*64,reserved_receipt_id='wire-only-no-Root')
    def test_matching_complete_utf8_attachment_maps_business_without_service_or_budget(self):
        code='return {"text":"雪🙂"};'
        with Peer() as peer:
            packet=self.evidence(code);peer.invoke(code,input_attachment=packet)
            result=peer.receive();self.assertEqual(result['type'],'result');self.assertTrue(result['ok'])
            output=result['result'];self.assertEqual(output['program_artifact'],packet['artifact']['ref'])
            self.assertEqual(output['program_sha256'],hashlib.sha256(code.encode()).hexdigest())
            self.assertEqual(output['program_sdk'],'program-language-v1/native-readonly-v1')
            self.assertFalse(output['output_truncated']);self.assertEqual(output['sub_call_count'],0)
    def test_absent_attachment_keeps_original_output_shape_and_zero_calls(self):
        with Peer() as peer:
            peer.invoke('return 7;');reply=peer.receive();self.assertTrue(reply['ok'])
            self.assertEqual(set(reply['result']),{'status','value','instruction_count','sub_call_count','error_code','error_message'})
            self.assertEqual(reply['result']['sub_call_count'],0)
    def test_changed_content_identity_profile_and_spoofed_shape_are_terminal_refusals(self):
        code='return 7;'
        for fault in ['bytes','hash','field','limit','thread','run','epoch','operation','call','namespace','generation','package','grant']:
            with self.subTest(fault=fault),Peer() as peer:
                packet=self.evidence(code)
                if fault=='bytes':packet['artifact']['bytes']+=1
                elif fault=='hash':packet['artifact'].update(sha256='2'*64,ref='blob:sha256:'+'2'*64)
                elif fault=='field':packet['profile']['field']='other'
                elif fault=='limit':packet['profile']['max_bytes']=262143
                elif fault=='thread':packet['thread_id']='other'
                elif fault=='run':packet['run_id']='other'
                elif fault=='epoch':packet['epoch']=2
                elif fault=='operation':packet['operation_id']='other'
                elif fault=='call':packet['call_id']='other'
                elif fault=='namespace':packet['namespace']='axyndra:other'
                elif fault=='generation':packet['generation']='8'
                elif fault=='package':packet['package_digest']='self-reported'
                else:packet['grant']=True
                peer.invoke(code,input_attachment=packet);peer.receive(eof=True)
                self.assertEqual(peer.process.wait(timeout=5),3)
    def test_tool_error_keeps_full_source_mapping_and_actual_subcall_count(self):
        code='return await tools.read({"path":"outside"});'
        with Peer() as peer:
            packet=self.evidence(code);peer.invoke(code,input_attachment=packet)
            request=peer.receive();fields={key:request[key] for key in KEYS}
            peer.send(dict(fields,type='service_response',request_id=request['request_id'],ok=False,
                error={'code':'wire-only-refusal','message':'no Root grant in this fixture'}))
            reply=peer.receive();self.assertFalse(reply['ok']);self.assertEqual(reply['result']['sub_call_count'],0)
            self.assertEqual(request['request_id'],'program-call-1')
            self.assertEqual(reply['result']['error_code'],'wire-only-refusal')
            self.assertEqual(reply['result']['program_artifact'],packet['artifact']['ref'])
            self.assertEqual(reply['result']['program_sha256'],packet['artifact']['sha256'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--package', type=Path, required=True)
    args = parser.parse_args(); PACKAGE = args.package.resolve()
    suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(ProgramPackageTests),
        unittest.defaultTestLoader.loadTestsFromTestCase(ProgramServiceRequestPackageTests),
        unittest.defaultTestLoader.loadTestsFromTestCase(ProgramFilePlanRequestPackageTests),
        unittest.defaultTestLoader.loadTestsFromTestCase(ProgramInputAttachmentPackageTests)])
    outcome = unittest.TextTestRunner(verbosity=2).run(suite)
    if not outcome.wasSuccessful() or outcome.testsRun != 28: raise SystemExit(1)
    print('Program packaged protocol contract passed: 28 cases (original19 + neutral service-request2 + preview-transport3 + input-attachment4)')

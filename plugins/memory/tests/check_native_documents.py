#!/usr/bin/env python3
"""Black-box Native business/data protocol; this peer creates no Host authority."""
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import unittest

REPO=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(REPO/'libs/pure_provider_runtime/tests'))
from peer import Peer

TOOLS=['retain','recall','reflect','memory_edit','learn','manage_skill','memory_context']
SCHEMA='axyndra.document-data-query/v1'
def encoded(value): return json.dumps(value,ensure_ascii=False,separators=(',',':')).encode('utf-8')
def digest(value): return hashlib.sha256(value).hexdigest()
def empty_journal():
    return dict(schema='axyndra.opaque-row-journal/v1',layout='opaque-fact-events-v3',rows=[],events=[],
        journal_chain_sha256=digest(b'axyndra.opaque-row-journal/v1'),next_event_id=1,
        annotations=dict(workspace_root='/workspace',settings_root='/settings',thread_id='thread',lane_id='main'))

class MemoryNativeDocumentProtocolTests(unittest.TestCase):
    def peer(self): return Peer(os.environ['AXYNDRA_MEMORY_PLUGIN_BINARY'],plugin_id='memory',contribution='prepare_document',payload=True)
    def query(self,p,value):
        reply=p.invoke(value)
        self.assertTrue(reply['ok'],reply)
        self.assertEqual(reply['result']['schema'],'axyndra.policy-result/v1')
        return reply['result']['value']
    def prepare(self,p,name,arguments,journal,sequence=1):
        raw=encoded(journal);source=digest(encoded(dict(name=name,sequence=sequence)))
        document=dict(key='journal',revision=sequence,payload=dict(bytes=len(raw),sha256=digest(raw)))
        original=dict(arguments)
        original['_axyndra_context_read']=dict(schema='axyndra.context-read-input/v1',
            data=dict(schema='axyndra.plugin-document-read-result/v2',documents=[document]),facts=[])
        def phase(action,**fields): return dict(schema=SCHEMA,action=action,sequence=sequence,source_digest=source,**fields)
        parameters=encoded(original)
        documents=[dict(id='journal',bytes=len(raw),sha256=digest(raw))]
        if len(parameters)>65536:
            self.assertEqual(self.query(p,phase('begin',tool=name,input_payload=dict(bytes=len(parameters),sha256=digest(parameters)),documents=documents)),dict(accepted=True))
            for offset in range(0,len(parameters),65536):
                self.assertEqual(self.query(p,phase('append_input',offset=offset,bytes_hex=parameters[offset:offset+65536].hex())),dict(accepted=True))
        else:
            self.assertEqual(self.query(p,phase('begin',tool=name,input=original,documents=documents)),dict(accepted=True))
        for offset in range(0,len(raw),65536):
            self.assertEqual(self.query(p,phase('append',id='journal',offset=offset,bytes_hex=raw[offset:offset+65536].hex())),dict(accepted=True))
        response=p.invoke(phase('compute'))
        if not response['ok']:
            return response,None,None
        proposal=response['result']['value'];outputs={}
        for item in proposal['outputs']:
            output=bytearray()
            while True:
                part=self.query(p,phase('read',id=item['id'],offset=len(output),max_bytes=65536))
                self.assertEqual(part['offset'],len(output));chunk=bytes.fromhex(part['bytes_hex'])
                self.assertLessEqual(len(chunk),65536);output.extend(chunk)
                if part['eof']: break
            self.assertEqual(len(output),item['bytes']);self.assertEqual(digest(output),item['sha256'])
            outputs[item['id']]=json.loads(output)
        self.assertEqual(self.query(p,phase('release')),dict(released=True))
        return proposal,outputs.get('next',journal),outputs['result']
    def retain(self,p,journal,content='concise answers',sequence=1):
        proposal,next_value,output=self.prepare(p,'retain',dict(items=[dict(content=content,scope='workspace')]),journal,sequence)
        self.assertFalse(proposal['is_error'],output)
        return next_value,output['ids'][0]

    def test_combined_ready_and_first_read_keep_every_pure_contribution_inert(self):
        with self.peer() as p:
            self.assertEqual(p.ready['capabilities'],[])
            self.assertEqual([item['name'] for item in p.ready['tools']],TOOLS)
            self.assertEqual([item['name'] for item in p.ready['providers']],['memory','prepare_document','prepare_window_document','memory_live'])
            value=self.query(p,dict(schema='axyndra.tool-preparation-query/v1',tool='retain',input=dict(items=[])))
            self.assertEqual(value,dict(document_read=dict(keys=['journal'])))

    def test_retain_preserves_canonical_nineteen_field_codec_and_frozen_result(self):
        with self.peer() as p:
            journal,identity=self.retain(p,empty_journal())
            self.assertEqual(journal['next_event_id'],2)
            event=journal['events'][0];record=json.loads(event['payload'])['record']
            self.assertEqual(len(record),19);self.assertEqual(record['id'],identity)
            self.assertEqual(event['key'],identity);self.assertEqual(event['revision'],1)
            self.assertEqual(journal['rows'][0]['payload_sha256'],digest(event['payload'].encode('utf-8')))
            _,same,output=self.prepare(p,'recall',dict(query='concise'),journal,2)
            self.assertEqual(same,journal);self.assertEqual(output['memories'][0]['id'],identity)

    def test_correct_conflict_resolution_and_forget_preserve_the_original_event_prefix(self):
        with self.peer() as p:
            journal,first=self.retain(p,empty_journal(),'first concise',1)
            journal,second=self.retain(p,journal,'second concise',2)
            prefix=copy.deepcopy(journal['events'])
            proposal,journal,output=self.prepare(p,'memory_edit',dict(op='mark_conflict',id=first,conflict_ids=[second],reason='different'),journal,3)
            self.assertFalse(proposal['is_error'],output)
            proposal,journal,output=self.prepare(p,'memory_edit',dict(op='resolve_conflict',id=first),journal,4)
            self.assertFalse(proposal['is_error'],output)
            self.assertEqual(journal['events'][:2],prefix)
            current={item['key']:json.loads(item['payload'])['record'] for item in journal['events']}
            self.assertEqual(current[first]['status'],'active');self.assertEqual(current[second]['status'],'corrected')
            self.assertEqual(current[second]['replacementId'],first)
            proposal,journal,output=self.prepare(p,'memory_edit',dict(op='forget',id=first,reason='forget'),journal,5)
            self.assertFalse(proposal['is_error'],output)
            self.assertEqual(json.loads(journal['events'][-1]['payload'])['record']['status'],'deleted')

    def test_current_row_tamper_is_rejected_before_authored_events_or_outputs(self):
        with self.peer() as p:
            journal,_=self.retain(p,empty_journal(),sequence=1)
            bad=copy.deepcopy(journal);bad['rows'][0]['payload_sha256']='0'*64
            failure,next_value,output=self.prepare(p,'retain',dict(items=[dict(content='must not exist')]),bad,2)
            self.assertFalse(failure['ok']);self.assertEqual(failure['result']['code'],'memory.document_fact_invalid')
            self.assertIsNone(next_value);self.assertIsNone(output)

    def test_large_utf8_content_crosses_chunks_without_duplicate_current_payload(self):
        with self.peer() as p:
            content='中😀'*140000+' concise'
            journal,identity=self.retain(p,empty_journal(),content,1)
            self.assertGreater(len(encoded(journal)),65536)
            self.assertNotIn('payload',journal['rows'][0])
            event=journal['events'][0]
            self.assertEqual(json.loads(event['payload'])['record']['content'],content)
            proposal,same,output=self.prepare(p,'recall',dict(query='concise'),journal,2)
            self.assertFalse(proposal['is_error'],output);self.assertEqual(same,journal)
            self.assertEqual(output['memories'][0]['id'],identity)

    def test_document_only_profile_rejects_skill_effect_and_plain_reexecution(self):
        with self.peer() as p:
            failure,next_value,output=self.prepare(p,'manage_skill',dict(action='create',name='new',description='new',body='body'),empty_journal())
            self.assertFalse(failure['ok']);self.assertEqual(failure['result']['code'],'memory.workspace_fact_required')
            self.assertIsNone(next_value);self.assertIsNone(output)
        with self.peer() as p:
            failure=p.invoke(dict(schema='axyndra.tool-preparation-query/v1',tool='retain',input={'_axyndra_context_read':{}}))
            self.assertFalse(failure['ok']);self.assertEqual(failure['result']['code'],'memory.frozen_payload_required')

if __name__=='__main__': unittest.main(verbosity=2)

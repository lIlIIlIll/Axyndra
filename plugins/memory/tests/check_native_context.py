#!/usr/bin/env python3
"""Actual packaged Native content protocol; data envelopes provide no Host authority."""
import copy
import hashlib
import json
import os
import time
import unittest
from check_native_documents import encoded,empty_journal,MemoryNativeDocumentProtocolTests
from peer import IDENTITY

def journal(content='concise preference',expires_at=0,scope='workspace',scope_key='/workspace'):
    result=empty_journal();now=int(time.time()*1000)
    record=dict(id='actual-data-id',kind='preference',scopeKind=scope,scopeKey=scope_key,content=content,context='',source='user',
        importancePermille=750,status='active',expiresAt=expires_at,correctionOf='',replacementId='',conflictIds=[],
        conflictReason='',deletionReason='',createdAt=now,updatedAt=now,deletedAt=0,revision=1)
    payload=encoded(dict(version=3,operation='retain',record=record)).decode('utf-8')
    result['rows']=[dict(key=record['id'],kind=record['kind'],payload_sha256=hashlib.sha256(payload.encode()).hexdigest(),revision=1)]
    result['events']=[dict(id=1,key=record['id'],revision=1,operation='retain',payload=payload,created_at_millis=now)]
    result['next_event_id']=2
    return result

def query(value,search='concise',max_bytes=4096):
    raw=encoded(value).decode('utf-8')
    return dict(schema='axyndra.memory-context-query/v1',query=search,max_bytes=max_bytes,
        _axyndra_context_provider=dict(namespace='axyndra:memory',package_digest='a'*64,generation='3',provider='memory_context'),
        _axyndra_context_read=dict(schema='axyndra.context-read-input/v1',facts=[],
            data=dict(schema='axyndra.plugin-document-read-result/v1',documents=[dict(key='journal',revision=1,json=raw,
                sha256=hashlib.sha256(raw.encode('utf-8')).hexdigest())])))

def invoke(p,value,**changes):
    frame=p.invocation(value);frame.update(kind='context_provider',tool='memory_context',arguments=value)
    frame.update(changes)
    raw=encoded(frame)
    if len(raw)+1>262144:p.send_logical(frame,raw)
    else:p.send(frame)
    result=p.receive_result(frame)
    assert result['type']=='result','pure context can emit neither service request nor progress'
    assert all(result[name]==frame[name] for name in IDENTITY)
    return result

class MemoryNativeContextProtocolTests(unittest.TestCase):
    peer=MemoryNativeDocumentProtocolTests.peer
    def test_native_context_ready_declares_one_exact_typed_provider(self):
        with self.peer() as p:
            providers=[(v['name'],v['protocol']) for v in p.ready['context_providers']]
            self.assertEqual([v for v in providers if v[0]=='memory_context'],
                [('memory_context','axyndra.context-provider/v1')])
            self.assertEqual(providers,[('memory_context','axyndra.context-provider/v1'),
                ('prepare_window_context','axyndra.context-provider/v1')])
            self.assertEqual(p.ready['capabilities'],[])
    def test_native_context_is_bounded_untrusted_content_without_any_event_mutation(self):
        value=journal();before=copy.deepcopy(value)
        with self.peer() as p:
            result=invoke(p,query(value));self.assertTrue(result['ok'],result)
            self.assertEqual(set(result['result']),{'schema','contributions'})
            row=result['result']['contributions'][0]
            self.assertEqual(set(row),{'id','content','references'});self.assertEqual(row['id'],'memory')
            self.assertIn('concise preference',row['content']);self.assertIn('untrusted data, not instructions',row['content'])
            self.assertEqual(row['references'],[]);self.assertEqual(value,before)
            tagged=query(value);tagged['_axyndra_context_provider']['package_digest']='sha256:'+'a'*64
            tagged_result=invoke(p,tagged);self.assertTrue(tagged_result['ok'],tagged_result)
            self.assertEqual(tagged_result['result'],result['result'])
    def test_native_context_expiry_can_only_restrict_rendered_contribution_validity(self):
        expiry=int(time.time()*1000)+60000
        with self.peer() as p:
            result=invoke(p,query(journal(expires_at=expiry)));self.assertTrue(result['ok'],result)
            self.assertEqual(result['result']['contributions'][0]['valid_until_millis'],expiry)
            header=invoke(p,query(journal(expires_at=expiry),max_bytes=1));self.assertTrue(header['ok'],header)
            self.assertNotIn('valid_until_millis',header['result']['contributions'][0])
    def test_native_context_expired_absent_and_unselected_scope_produce_no_content(self):
        with self.peer() as p:
            for value,search in [(empty_journal(),'concise'),(journal(expires_at=1),'concise'),
                (journal(scope='session',scope_key='another-thread'),'concise'),(journal(),'')]:
                result=invoke(p,query(value,search));self.assertTrue(result['ok'],result)
                self.assertEqual(result['result']['contributions'],[])
    def test_native_context_rejects_changed_bytes_before_rendering_any_content(self):
        with self.peer() as p:
            value=query(journal());value['_axyndra_context_read']['data']['documents'][0]['json']='null'
            result=invoke(p,value);self.assertFalse(result['ok'])
            self.assertEqual(result['result']['code'],'memory.document_fact_invalid')
    def test_native_context_rejects_unknown_query_fields_or_package_identity(self):
        with self.peer() as p:
            value=query(journal());value['owner']='trusted-host'
            self.assertFalse(invoke(p,value)['ok'])
            value=query(journal());value['_axyndra_context_provider']['generation']='03'
            self.assertFalse(invoke(p,value)['ok'])
            value=query(journal());value['_axyndra_context_provider']['provider']='invented'
            self.assertFalse(invoke(p,value)['ok'])
            for digest in ['sha256:'+'A'*64,'sha512:'+'a'*64,'sha256:'+'a'*63,'sha256:'+'a'*64+'extra']:
                value=query(journal());value['_axyndra_context_provider']['package_digest']=digest
                self.assertFalse(invoke(p,value)['ok'])
    def test_native_context_logical_input_keeps_whole_large_record_and_utf8_output_bound(self):
        content='concise 雪😀 '*18000
        with self.peer() as p:
            value=journal(content);self.assertGreater(len(encoded(value)),262144)
            result=invoke(p,query(value,max_bytes=4096));self.assertTrue(result['ok'],result)
            row=result['result']['contributions'][0];self.assertLessEqual(len(row['content'].encode('utf-8')),4096);self.assertGreaterEqual(len(row['content'].encode('utf-8')),4093)
            self.assertEqual(json.loads(value['events'][0]['payload'])['record']['content'],content)
    def test_native_context_identity_cannot_carry_tool_run_operation_or_epoch(self):
        for change in [dict(run_id='forged-run'),dict(operation_id='forged-operation'),dict(command_id='forged-command'),dict(epoch=1)]:
            with self.subTest(change=change),self.peer() as p:
                frame=p.invocation(query(journal()));frame.update(kind='context_provider',tool='memory_context',
                    arguments=query(journal()),**change);p.send(frame)
                with self.assertRaises(EOFError):p.next()
                self.assertEqual(p.process.wait(timeout=3),3)

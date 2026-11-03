#!/usr/bin/env python3
"""Actual installed Native content wire only; supplied identities grant no Host authority."""
import argparse,copy,hashlib,json,sys,unittest
from pathlib import Path
import check as workflow
from peer import IDENTITY

def history(enabled=True,budget=50):
    return dict(id='goal-id',objective='finish verified work',status='active',tokenBudget=budget,tokensUsed=5,
                timeUsedSeconds=1,createdAt=1000,updatedAt=1000,enabled=enabled,baselineTokens=100,accountedAt=1000)
def query(document,total=100):
    raw=json.dumps(document,ensure_ascii=False,separators=(',',':'))
    return dict(schema='axyndra.goal-context-query/v1',_axyndra_context_provider=dict(namespace='axyndra:workflow',
        package_digest='a'*64,generation='3',provider='goal_context'),_axyndra_context_read=dict(
        schema='axyndra.context-read-input/v1',facts=[],data=dict(schema='axyndra.plugin-document-read-result/v1',
        request_digest='b'*64,documents=[dict(key='goal',revision=1,json=raw,sha256=hashlib.sha256(raw.encode()).hexdigest())],
        observation=dict(schema='axyndra.document-observation/v1',thread_id='actual-thread',run_id='actual-run',
                         observed_at_millis=2000,input_tokens=total,output_tokens=0))))
def invoke(p,q,**changes):
    frame=p.invocation(q);frame.update(kind='context_provider',tool='goal_context',arguments=q)
    frame.update(changes)
    source=json.dumps(frame,ensure_ascii=False,separators=(',',':')).encode()
    if len(source)+1>262144:p.send_logical(frame,source)
    else:p.send(frame)
    response=p.receive_result(frame)
    assert response['type']=='result','content must emit neither service request nor progress'
    assert all(response[name]==frame[name] for name in IDENTITY)
    return response

class NativeGoalContextProtocolTests(unittest.TestCase):
    def test_actual_ready_declares_only_the_exact_new_typed_context_provider(self):
        with workflow.peer() as p:
            self.assertEqual([(v['name'],v['protocol']) for v in p.ready['context_providers']],
                             [('goal_context','axyndra.context-provider/v1')])
            self.assertEqual(p.ready['capabilities'],[])
    def test_actual_content_preserves_history_and_has_no_mutation_or_user_control(self):
        document=history();original=copy.deepcopy(document)
        with workflow.peer() as p:
            response=invoke(p,query(document,total=110));self.assertTrue(response['ok'],response)
            value=response['result'];self.assertEqual(set(value),{'schema','contributions'})
            self.assertEqual(value['schema'],'axyndra.context-result/v1')
            row=value['contributions'][0];self.assertEqual(set(row),{'id','content','references'})
            self.assertIn('Tokens used: 15',row['content'])
            self.assertIn('Call plugin.axyndra:workflow.goal with op=complete',row['content'])
            self.assertEqual(row['references'],[]);self.assertEqual(document,original)
    def test_absent_disabled_and_observed_budget_limit_emit_no_content(self):
        with workflow.peer() as p:
            for document,total in [(None,100),(history(enabled=False),100),(history(),145)]:
                response=invoke(p,query(document,total));self.assertTrue(response['ok'],response)
                self.assertEqual(response['result']['contributions'],[])
    def test_changed_raw_document_digest_cannot_become_content(self):
        q=query(history());q['_axyndra_context_read']['data']['documents'][0]['json']='null'
        with workflow.peer() as p:
            response=invoke(p,q);self.assertFalse(response['ok'])
            self.assertEqual(response['result']['code'],'workflow.document_fact_invalid')
    def test_unsupported_legacy_fields_and_caller_control_are_rejected(self):
        with workflow.peer() as p:
            for document in [dict(history(),formatVersion=2),dict(history(),tokensUsed='5')]:
                response=invoke(p,query(document));self.assertFalse(response['ok'])
            q=query(history());q['user_control']={'action':'create'}
            self.assertFalse(invoke(p,q)['ok'])
    def test_actual_logical_window_retains_the_original_physical_frame_bound(self):
        document=history();document['objective']='x'*262144
        with workflow.peer(payload=True) as p:
            response=invoke(p,query(document));self.assertTrue(response['ok'],response)
            self.assertIn(document['objective'],response['result']['contributions'][0]['content'])
            self.assertEqual(response['result']['contributions'][0]['references'],[])
    def test_context_identity_cannot_carry_any_run_or_tool_operation(self):
        for changed in [dict(run_id='forged-run'),dict(operation_id='forged-operation'),dict(command_id='forged-command'),dict(epoch=1)]:
            with self.subTest(changed=changed),workflow.peer() as p:
                frame=p.invocation(query(history()));frame.update(kind='context_provider',tool='goal_context',arguments=query(history()),**changed)
                p.send(frame)
                with self.assertRaises(EOFError):p.next()
                self.assertEqual(p.process.wait(timeout=3),3)
    def test_provider_kind_and_unknown_context_name_do_not_select_content_handler(self):
        with workflow.peer() as p:
            frame=p.invocation(query(history()));frame.update(tool='goal_context')
            p.send(frame)
            with self.assertRaises(EOFError):p.next()
            self.assertEqual(p.process.wait(timeout=3),3)
        with workflow.peer() as p:
            frame=p.invocation(query(history()));frame.update(kind='context_provider',tool='unknown_context',arguments=query(history()))
            p.send(frame)
            with self.assertRaises(EOFError):p.next()
            self.assertEqual(p.process.wait(timeout=3),3)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--package',type=Path,required=True)
    args=parser.parse_args();workflow.BINARY=(args.package/'bin/workflow-plugin').resolve(strict=True)
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NativeGoalContextProtocolTests))
    return 0 if result.wasSuccessful() and result.testsRun==8 and not result.skipped else 1
if __name__=='__main__':raise SystemExit(main())

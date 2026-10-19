#!/usr/bin/env python3
"""Execute the real independently packaged compaction provider, without SDK paths."""
import argparse
import hashlib
import json
import functools
from pathlib import Path
import queue
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'libs/pure_provider_runtime/tests'))
from peer import Peer, CONTENT_LIMITS
from reference_peer import ReferencePeer
BINARY=None

def prepare(facts='authoritative facts',model='operator-model',limit=800):
    return dict(schema='axyndra.compaction-policy/v1',phase='prepare',facts=facts,model=model,max_output_tokens=limit)
def finalize(blocks,*,accepted=True,stop='end_turn',limit=800):
    return dict(schema='axyndra.compaction-policy/v1',phase='finalize',max_output_tokens=limit,
        reply=dict(accepted_output=accepted,stop_reason=stop,blocks=blocks))
def text(value):return dict(kind='text',text=value)
def result(response):
    assert response['ok'] and response['result']['schema']=='axyndra.policy-result/v1'
    assert set(response['result'])=={'schema','value'}
    return response['result']['value']


def block(kind='text', text='', name='', arguments=None, is_error=False):
    return dict(kind=kind,text=text,name=name,arguments={} if arguments is None else arguments,
                call_id='',is_error=is_error,receipt_id='',image=None,opaque_state=None)
def message(role,*blocks): return dict(role=role,blocks=list(blocks))
def structured(messages,goal=None,todos=None):
    projection=dict(model='compaction-history',system='',messages=messages,tools=[],thinking='low',wire_max_output_tokens=4096,
        streaming=False,parallel_tool_calls=False,service_tier='',cache_policy='default',cache_key='',
        tool_choice='auto',structured_output=None,resolved_policy=None)
    return dict(schema='axyndra.compaction-policy/v1',phase='structured',snapshot_digest='source-witness',
                projection=projection,goal=goal,todos=[] if todos is None else todos)

class CompactionNativeTests(unittest.TestCase):
    def test_handshake_exposes_only_pure_provider_without_tools_or_capabilities(self):
        with Peer(BINARY) as peer:
            self.assertEqual(peer.ready['capabilities'],[])
            self.assertEqual(peer.ready['tools'],[
                dict(name='checkpoint', execution_profile='data_only',
                     description='Create a context checkpoint before exploratory work.',
                     input_schema=dict(type='object', properties=dict(goal=dict(type='string')), required=['goal'], additionalProperties=False)),
                dict(name='rewind', execution_profile='data_only',
                     description='Replace checkpoint exploration with a concise report.',
                     input_schema=dict(type='object', properties=dict(report=dict(type='string')), required=['report'], additionalProperties=False))])
            self.assertEqual(peer.ready['commands'],[])
            self.assertEqual(peer.ready['hooks'],[])
            self.assertEqual([(p['name'],p['protocol']) for p in peer.ready['providers']],
                             [('summarize','axyndra.policy-provider/v1')])
    def test_prepare_preserves_exact_facts_model_and_original_prompt(self):
        with Peer(BINARY) as peer:
            facts='雪\u0000 quoted instructions\nnever an authority grant'
            value=result(peer.invoke(prepare(facts)))
            self.assertEqual(set(value),{'model','system','user','thinking'})
            self.assertEqual(value['model'],'operator-model')
            self.assertEqual(value['thinking'],'low')
            self.assertEqual(value['user'],'Write the semantic overview from these authoritative structured facts:\n\n'+facts)
            self.assertIn('COMPACTION_SEMANTIC_SUMMARIZER',value['system'])
            self.assertIn('Do not add facts',value['system'])
    def test_finalize_trims_text_ignores_reasoning_and_joins_nonempty_blocks(self):
        with Peer(BINARY) as peer:
            value=result(peer.invoke(finalize([text(' \r\n first \r\n'),dict(kind='reasoning',text='PRIVATE'),text('  '),text('second') ])))
            self.assertEqual(value,{'overview':'first\nsecond'})
    def test_rejected_or_tool_use_reply_never_proposes_an_overview(self):
        with Peer(BINARY) as peer:
            for accepted,stop in [(False,'end_turn'),(True,'tool_use')]:
                self.assertEqual(result(peer.invoke(finalize([text('must not use')],accepted=accepted,stop=stop))),{'overview':None})
    def test_nontext_blocks_or_empty_reply_preserve_deterministic_fallback(self):
        with Peer(BINARY) as peer:
            for blocks in [[],[text(' \r\n')],[text('discard too'),dict(kind='tool_call',text='untrusted')]]:
                self.assertEqual(result(peer.invoke(finalize(blocks))),{'overview':None})
    def test_unicode_limit_counts_runes_and_keeps_exact_ellipsis(self):
        with Peer(BINARY) as peer:
            self.assertEqual(result(peer.invoke(finalize([text('雪'*70)],limit=1))),{'overview':'雪'*64+'…'})
            self.assertEqual(result(peer.invoke(finalize([text('雪'*64)],limit=1))),{'overview':'雪'*64})
    def test_invalid_business_fields_return_typed_error_without_authority_or_process_loss(self):
        with Peer(BINARY) as peer:
            for query in [dict(prepare(),extra='unknown'),dict(prepare(),max_output_tokens=0),
                          dict(prepare(),max_output_tokens=65537),dict(prepare(),phase='grant')]:
                answer=peer.invoke(query)
                self.assertFalse(answer['ok']);self.assertIn('code',answer['result'])
            self.assertEqual(result(peer.invoke(prepare()))['model'],'operator-model')
    def test_logical_megabyte_facts_round_trip_then_small_query_on_same_process(self):
        with Peer(BINARY,payload=True) as peer:
            facts='雪'*(350000)
            value=result(peer.invoke(prepare(facts)))
            self.assertTrue(value['user'].endswith(facts))
            self.assertEqual(result(peer.invoke(finalize([text('after big query')]))),{'overview':'after big query'})
    def test_forged_run_operation_epoch_or_command_identity_cannot_execute(self):
        for field,value in [('run_id','forged'),('operation_id','forged'),('epoch',1),('command_id','forged'),('kind','tool')]:
            with self.subTest(field=field),Peer(BINARY) as peer:
                frame=peer.invocation(prepare());frame[field]=value;peer.send(frame)
                with self.assertRaises(EOFError):peer.next()
                self.assertNotEqual(peer.process.wait(timeout=3),0)
    def test_duplicate_invocation_is_not_replayed(self):
        with Peer(BINARY) as peer:
            frame=peer.invocation(prepare());peer.send(frame);self.assertTrue(peer.receive_result(frame)['ok'])
            peer.send(frame)
            with self.assertRaises(EOFError):peer.next()
    def test_unknown_contribution_cannot_invoke_arbitrary_business_handler(self):
        with Peer(BINARY) as peer:
            frame=peer.invocation(prepare());frame['tool']='unregistered';peer.send(frame)
            with self.assertRaises(EOFError):peer.next()
    def test_second_handshake_cannot_reset_query_or_resource_budgets(self):
        with Peer(BINARY) as peer:
            peer.send(peer.hello)
            with self.assertRaises(EOFError):peer.next()
    def test_profile_changes_fail_before_any_query(self):
        with self.assertRaises(EOFError):
            Peer(BINARY,payload=True,profile=dict(CONTENT_LIMITS,max_result_bytes=999999999))
    def test_logical_wrong_digest_cannot_be_consumed(self):
        with Peer(BINARY,payload=True) as peer:
            frame=peer.invocation(prepare());source=json.dumps(frame,separators=(',',':')).encode()
            peer.send(peer.logical_frame(frame,'payload_begin',message_type='invoke',bytes=len(source),sha256='0'*64))
            peer.send(peer.logical_frame(frame,'payload_chunk',offset=0,bytes_hex=source.hex()))
            peer.send(peer.logical_frame(frame,'payload_end'))
            with self.assertRaises(EOFError):peer.next()
    def test_logical_changed_identity_cannot_be_consumed(self):
        with Peer(BINARY,payload=True) as peer:
            frame=peer.invocation(prepare());source=json.dumps(frame,separators=(',',':')).encode()
            peer.send(peer.logical_frame(frame,'payload_begin',message_type='invoke',bytes=len(source),sha256=hashlib.sha256(source).hexdigest()))
            chunk=peer.logical_frame(frame,'payload_chunk',offset=0,bytes_hex=source.hex());chunk['thread_id']='foreign';peer.send(chunk)
            with self.assertRaises(EOFError):peer.next()
    def test_unnegotiated_logical_message_cannot_allocate_large_input(self):
        with Peer(BINARY) as peer:
            frame=peer.invocation(prepare());frame['payload_window']='unnegotiated'
            peer.send(peer.logical_frame(frame,'payload_begin',message_type='invoke',bytes=4000000,sha256='0'*64))
            with self.assertRaises(EOFError):peer.next()


    def test_structured_history_exact_legacy_summary_and_non_authoritative_overview_removal(self):
        with Peer(BINARY) as peer:
            query = structured([message('user', block(text='  first\r\nrequest ')),
                message('assistant', block(text='answer'), block(kind='reasoning', text='reason'))])
            self.assertEqual(result(peer.invoke(query)), dict(snapshot_digest='source-witness',
                summary='[Compacted session history]\nmessages: 2 (user 1, assistant 1)\nkey excerpts:\n- user: first request\n- assistant: answer\n- assistant: reason'))
            prior = '[Compacted session history]\nold fact\nmodel-generated overview (non-authoritative):\nNEVER-RETAIN-OVERVIEW'
            reply = result(peer.invoke(structured([message('user', block(text=prior))])))['summary']
            self.assertIn('prior structured context:\n---\n[Compacted session history] old fact', reply)
            self.assertNotIn('NEVER-RETAIN-OVERVIEW', reply)

    def test_structured_workflow_files_commands_errors_preserve_original_algorithm(self):
        with Peer(BINARY) as peer:
            query = structured([
                message('assistant', block(kind='tool_call', name='read', arguments=dict(path='src/a.cj')),
                    block(kind='tool_call', name='edit', arguments=dict(path='src/a.cj', input='[src/b.cj#8]\nchange')),
                    block(kind='tool_call', name='bash', arguments=dict(command='check\nunit'))),
                message('user', block(kind='tool_result', name='write', arguments=dict(path='src/new.cj', action='create')),
                    block(kind='tool_result', name='bash', arguments=dict(exit_code=1, stderr='compiler\nfailed'), is_error=True))],
                goal=dict(objective='finish issue', status='active'),
                todos=[dict(name='Build', tasks=[dict(content='compile', status='blocked', blocker='SDK'),
                    dict(content='review', status='pending'), dict(content='old', status='completed')])])
            self.assertEqual(result(peer.invoke(query))['summary'],
                '[Compacted session history]\nmessages: 2 (user 1, assistant 1)\ngoal:\n- objective: finish issue\n- status: active'
                '\nunresolved:\n- Build: compile [blocked: SDK]\n- Build: review\ntools: read, edit, bash'
                '\nfiles:\n- src/a.cj (RW)\n- src/b.cj (Write)\n- src/new.cj (Created)'
                '\nimportant commands:\n- check unit\ntool results:\n- bash exit 1\ndiagnostics:\n- bash: compiler failed')

    def test_structured_malformed_projections_fail_and_next_query_still_works(self):
        with Peer(BINARY) as peer:
            for query in [dict(structured([]), extra='unexpected'), dict(structured([]), projection={}),
                          dict(structured([]), todos=[dict(name='x', tasks=[dict(content='x', status='forged')])])]:
                self.assertFalse(peer.invoke(query)['ok'])
            self.assertEqual(result(peer.invoke(structured([])))['summary'],
                '[Compacted session history]\nmessages: 0 (user 0, assistant 0)')

    def test_structured_logical_large_history_applies_same_excerpt_policy(self):
        with Peer(BINARY, payload=True) as peer:
            query = structured([message('user', block(text='A'*1100000))])
            self.assertEqual(result(peer.invoke(query))['summary'],
                '[Compacted session history]\nmessages: 1 (user 1, assistant 0)\nkey excerpts:\n- user: '+'A'*240+'...')


    def test_structured_pages_transfer_history_larger_than_one_logical_message(self):
        messages = [message('user' if i % 2 == 0 else 'assistant', block(text='A' * 65536)) for i in range(130)]
        self.assertGreater(len(json.dumps(structured(messages))), 8 * 1024 * 1024)
        state = None
        with Peer(BINARY, payload=True) as peer:
            for offset in range(0, len(messages), 16):
                query = structured(messages[offset:offset+16])
                query.update(phase='structured_page', page_id=str(offset), offset=offset, total=len(messages), state=state)
                value = result(peer.invoke(query))
                self.assertEqual(value['next_offset'], min(len(messages), offset+16))
                self.assertEqual(value['page_id'], str(offset))
                state = value['state']
                if offset + 16 < len(messages): self.assertIsNone(value['summary'])
            expected = '[Compacted session history]\nmessages: 130 (user 65, assistant 65)\nkey excerpts:'
            for i in range(6): expected += '\n- ' + ('user' if i % 2 == 0 else 'assistant') + ': ' + 'A'*240 + '...'
            self.assertEqual(value['summary'], expected)
            self.assertIsNone(state)

    def test_structured_page_invalid_coverage_cannot_reuse_state(self):
        with Peer(BINARY) as peer:
            first = structured([message('user', block(text='first'))])
            first.update(phase='structured_page', page_id='0', offset=0, total=2, state=None)
            state = result(peer.invoke(first))['state']
            for offset, total, messages in [(2, 3, [message('user', block(text='bad'))]), (1, 2, []), (1, 1, [message('user', block(text='extra'))])]:
                query = structured(messages)
                query.update(phase='structured_page', page_id='bad', offset=offset, total=total, state=state)
                self.assertFalse(peer.invoke(query)['ok'])
            good = structured([message('assistant', block(text='second'))])
            good.update(phase='structured_page', page_id='1', offset=1, total=2, state=state)
            self.assertIn('messages: 2 (user 1, assistant 1)', result(peer.invoke(good))['summary'])

    def test_reference_driver_matches_actual_native_original_structured_policy(self):
        messages = [message('user', block(text='  snow 雪\r\n request ')), message('assistant',
            block(kind='tool_call',name='edit',arguments={'input':'[x#2]\n[x#3]\n[y#4]','path':'x','command':'build\nall'}),
            block(kind='tool_result',name='bash',arguments={'exit_code':1,'stderr':' bad\nnews '},is_error=True))]
        goal={'objective':'actual goal','status':'active'}
        todos=[{'name':'phase','tasks':[{'content':'work','status':'blocked','blocker':'SDK'}]}]
        with Peer(BINARY,payload=True) as peer:
            expected=result(peer.invoke(structured(messages,goal,todos)))['summary']
            self.assertEqual(ReferencePeer(peer).summary(messages,goal,todos),expected)

    def test_oversized_source_and_unbounded_names_use_exact_reference_recipe(self):
        path='p'*2300000
        messages=[message('user',block(text=' '*4500000+'important 雪'+' '*4500000)),
                  message('assistant',block(kind='tool_call',name='read',arguments={'path':path+'a'}),
                          block(kind='tool_call',name='edit',arguments={'input':'['+path+'b#2]'}))]
        with Peer(BINARY,payload=True) as peer:
            actual=ReferencePeer(peer,batch=True).summary(messages)
            expected='[Compacted session history]\nmessages: 2 (user 1, assistant 1)\nkey excerpts:\n- user: important 雪\ntools: read, edit\nfiles:\n- '+path+'a (Read)\n- '+path+'b (Write)'
            self.assertGreater(len(expected.encode()),4194304)
            self.assertEqual(actual,expected)
            self.assertEqual(result(peer.invoke(finalize([text('after huge source')]))),{'overview':'after huge source'})

    def test_oversized_goal_todo_and_boundary_marker_are_reduced_in_plugin(self):
        gap=' '*4300000
        messages=[message('user',block(text='[Compacted session history]'+gap+'\nmodel-generated overview (non-authoritative):\nOMIT'))]
        goal={'objective':gap+'goal'+gap,'status':'active'}
        todos=[{'name':'phase','tasks':[{'content':gap+'work','status':'blocked','blocker':gap+'SDK'}]}]
        with Peer(BINARY,payload=True) as peer:
            value=ReferencePeer(peer,batch=True).summary(messages,goal,todos)
            self.assertEqual(value,'[Compacted session history]\nmessages: 1 (user 1, assistant 0)\ngoal:\n- objective: goal\n- status: active\nunresolved:\n- phase: work [blocked: SDK]\nprior structured context:\n---\n[Compacted session history]')

    def test_reference_hybrid_prompt_and_large_reply_preserve_original_normalization(self):
        facts='F'*4600000
        with Peer(BINARY,payload=True) as peer:
            driver=ReferencePeer(peer)
            prepared=driver.query('prepare_reference',facts=driver.intern(facts),model='operator-model',max_output_tokens=1)
            self.assertEqual(driver.compose(prepared['user_recipe']),'Write the semantic overview from these authoritative structured facts:\n\n'+facts)
            self.assertEqual(driver.overview([text(' '*4400000+'雪'*70+' '*4400000)],1),'雪'*64+'…')
            self.assertIsNone(driver.overview([text('A'*4400000),dict(kind='unsupported',text='bad')],1))
            self.assertEqual(driver.overview([text(' '*4400000+'first\r\nline'+' '*4400000),text('second')],800),'first\nline\nsecond')

    def test_fragment_bad_coverage_and_carry_are_typed_without_process_loss(self):
        with Peer(BINARY,payload=True) as peer:
            driver=ReferencePeer(peer);source=driver.intern('abc')
            base=dict(schema='axyndra.compaction-policy/v1',phase='text_fragment',snapshot_digest='x',source=source,sequence=1,
                      mode='compact',limit=240,offset=0,total=3,text='abc',carry=None)
            for patch in [dict(offset=1),dict(total=2),dict(limit=0),dict(carry={}),dict(extra=True)]:
                self.assertFalse(peer.invoke(dict(base,**patch))['ok'])
            self.assertEqual(driver.summary([message('user',block(text='still alive'))]),
                             '[Compacted session history]\nmessages: 1 (user 1, assistant 0)\nkey excerpts:\n- user: still alive')

    def test_event_batch_matches_native_whole_policy_at_inline_boundaries_and_uses_fewer_requests(self):
        with Peer(BINARY, payload=True) as peer:
            for size in (0, 1, 26, 239, 240, 241, 1600, 2047, 2048, 2049):
                messages=[message('user', block(text='x'*size)), message('assistant', block(text='snow 雪'))]
                expected=result(peer.invoke(structured(messages)))['summary']
                old=ReferencePeer(peer); batch=ReferencePeer(peer, batch=True)
                self.assertEqual(old.summary(messages), expected)
                self.assertEqual(batch.summary(messages), expected)
                self.assertLess(batch.sequence, old.sequence)
            batch=ReferencePeer(peer, batch=True)
            batch.summary([message('user', block(text='short'))])
            self.assertEqual(batch.sequence, 5)  # layout + message + text/merge + finish

    def test_event_batch_preserves_deferred_huge_whitespace_marker_and_hashline_observations(self):
        gap=' '*530000
        path='p'*280000
        messages=[message('user', block(text=gap+'late 雪'+gap),
                          block(text='[Compacted session history]'+gap+'\nmodel-generated overview (non-authoritative):\nOMIT')),
                  message('assistant', block(kind='tool_call', name='edit', arguments={'input':'[first#1]\n['+path+'#2]\n[first#3]', 'command':'run\nall'}),
                          block(kind='tool_result', name='bash', text=gap+'detail', arguments={'stderr':'bad', 'exit_code':1}, is_error=True))]
        with Peer(BINARY, payload=True) as peer:
            old=ReferencePeer(peer); batch=ReferencePeer(peer, batch=True)
            expected=old.summary(messages)
            self.assertEqual(batch.summary(messages), expected)
            self.assertIn(path+' (Write)', expected)
            self.assertNotIn('OMIT', expected)
            self.assertLess(batch.sequence, old.sequence)

    def test_event_batch_rejects_changed_inline_identity_and_keeps_the_worker_alive(self):
        with Peer(BINARY) as peer:
            driver=ReferencePeer(peer, batch=True)
            state=driver.query('reference_layout')['state']
            source=driver.intern('abc')
            event=dict(kind='text', role='user', text=dict(source, bytes=2))
            request=dict(schema='axyndra.compaction-policy/v1', phase='reference_event', snapshot_digest='x', state=state, event=event)
            self.assertFalse(peer.invoke(request)['ok'])
            self.assertIn('still alive',driver.summary([message('user',block(text='still alive'))]))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--package',type=Path,required=True)
    args=parser.parse_args();package=args.package.resolve(strict=True)
    manifest=json.loads((package/'axyndra.plugin.json').read_text())
    Peer=functools.partial(Peer,plugin_id=manifest['id'],version=manifest['version'])
    BINARY=(package/manifest['entrypoint']).resolve(strict=True)
    if not BINARY.is_relative_to(package):raise SystemExit('entrypoint escapes package')
    unittest.main(argv=[sys.argv[0]],verbosity=2)

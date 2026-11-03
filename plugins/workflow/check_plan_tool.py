#!/usr/bin/env python3
"""Actual native Tool protocol only; frame identities are data, not Host grants."""
import argparse,hashlib,importlib.util,json,sys,unittest
from pathlib import Path
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('original_workflow',Path(__file__).with_name('check.py'))
original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
from peer import IDENTITY
def invoke(p,kind,arguments):
    frame=p.invocation(arguments)
    frame.update(kind=kind,tool='plan_write',run_id='protocol-only-run',epoch=1,operation_id='' if kind=='prepare' else 'protocol-only-operation',arguments=arguments)
    p.send(frame);response=p.receive_result(frame)
    assert response['type']=='result','data Tool must emit neither a service request nor progress'
    assert all(response[key]==frame[key] for key in IDENTITY)
    return response
class NativePlanToolTests(unittest.TestCase):
    def test_actual_pure_prepare_and_execute_keep_the_schema_and_original_output(self):
        with original.peer() as p:
            tool=next(t for t in p.ready['tools'] if t['name']=='plan_write')
            self.assertEqual(tool['execution_profile'],'data_only')
            self.assertEqual(tool['input_schema'],dict(type='object',properties=dict(content=dict(type='string')),required=['content'],additionalProperties=False))
            arguments=dict(content='  Goal: exact native plan 雪\nAcceptance: preserve receipt  ')
            prepared=invoke(p,'prepare',arguments);self.assertTrue(prepared['ok']);self.assertEqual(prepared['result'],arguments)
            result=invoke(p,'tool',arguments);self.assertIs(result['ok'],True)
            self.assertEqual(result['result'],'Plan recorded for review. The user reviews it via /plan-review before execution.')
    def test_empty_content_fails_without_service_or_process_loss(self):
        with original.peer() as p:
            for kind in ['prepare','tool']:
                response=invoke(p,kind,dict(content=' \t\n '));self.assertFalse(response['ok'])
                self.assertEqual(response['result']['code'],'plan_write.empty')
            self.assertTrue(invoke(p,'tool',dict(content='still-live'))['ok'])
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True);parser.add_argument('--summary',type=Path,required=True)
    args=parser.parse_args();original.BINARY=args.binary.resolve(strict=True)
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NativePlanToolTests))
    counts=dict(executed=result.testsRun,failures=len(result.failures),errors=len(result.errors),skipped=len(result.skipped),entry_sha256=hashlib.sha256(original.BINARY.read_bytes()).hexdigest())
    args.summary.write_text(json.dumps(counts,indent=2)+'\n')
    return 0 if result.wasSuccessful() and result.testsRun==2 and not result.skipped else 1
if __name__=='__main__':raise SystemExit(main())

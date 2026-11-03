#!/usr/bin/env python3
"""Kills the actual Product owner after uncommitted Derived CAS plus Receipt.

This runner never fabricates a Source, receipt, SQL write, or business result.
All SQL connections below are observation-only. Keep the fresh fixture root
and evidence after a failure; a failed/prepared root is never overwritten.
"""
import argparse,hashlib,json,os,sqlite3,subprocess,time
from pathlib import Path

def rows(database,sql,parameters=()):
    with sqlite3.connect(f'file:{database.as_posix()}?mode=ro',uri=True) as connection:
        return connection.execute(sql,parameters).fetchall()
def facts(database):
    return dict(rows=rows(database,'SELECT id,thread_id,kind,payload,revision FROM memories ORDER BY id'),
        events=rows(database,'SELECT id,memory_id,revision,operation,payload,created_at_millis FROM memory_events ORDER BY id'),
        sequence=rows(database,"SELECT seq FROM sqlite_sequence WHERE name='memory_events'"))
def invoke(binary,environment,action,root):
    env=dict(environment,AXYNDRA_MEMORY_INTERRUPT_ROOT=str(root),AXYNDRA_MEMORY_INTERRUPT_ACTION=action)
    with (root/f'{action}.stdout').open('wb') as output,(root/f'{action}.stderr').open('wb') as errors:
        result=subprocess.run([str(binary)],env=env,stdout=output,stderr=errors,timeout=90)
    if result.returncode:raise AssertionError(f'actual {action} process failed: {result.returncode}; retained logs at {root}')
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--root',type=Path,required=True);parser.add_argument('--package',type=Path,required=True)
    args=parser.parse_args();root=args.root.resolve();root.mkdir(parents=True,exist_ok=False)
    binary=args.binary.resolve();package=args.package.resolve();environment=dict(os.environ,AXYNDRA_MEMORY_PLUGIN_PACKAGE=str(package))
    invoke(binary,environment,'seed',root);database=root/'state/state.db'
    before=facts(database);completed_before=rows(database,"SELECT r.id,r.operation_id FROM operation_receipts r JOIN derived_operation_admissions a ON a.operation_id=r.operation_id WHERE r.outcome='completed' ORDER BY r.id")
    assert len(before['events'])==1 and len(before['rows'])==1 and len(completed_before)==1
    env=dict(environment,AXYNDRA_MEMORY_INTERRUPT_ROOT=str(root),AXYNDRA_MEMORY_INTERRUPT_ACTION='interrupt')
    with (root/'interrupt.stdout').open('wb') as output,(root/'interrupt.stderr').open('wb') as errors:
        process=subprocess.Popen([str(binary)],env=env,stdout=output,stderr=errors)
        barrier=root/'before-commit-barrier.json';deadline=time.monotonic()+90
        try:
            while not barrier.exists():
                if process.poll() is not None:raise AssertionError(f'actual process ended before transaction barrier: {process.returncode}')
                if time.monotonic()>=deadline:raise AssertionError('actual Derived precommit barrier was not reached')
                time.sleep(.02)
            witness=json.loads(barrier.read_text(encoding='utf-8'))
            assert witness['event_count']==3 and witness['row_revision']==2 and witness['operation_state']=='committed'
            # Other connections cannot see the actual uncommitted new events,
            # rows or Receipt even while the observed owner sees all three.
            assert facts(database)==before
            assert not rows(database,'SELECT id FROM operation_receipts WHERE id=?',(witness['receipt_id'],))
            process.kill();process.wait(timeout=30)
        finally:
            if process.poll() is None:process.kill();process.wait(timeout=30)
    after_kill=facts(database);assert after_kill==before
    assert not rows(database,'SELECT id FROM operation_receipts WHERE id=?',(witness['receipt_id'],))
    assert rows(database,"SELECT r.id,r.operation_id FROM operation_receipts r JOIN derived_operation_admissions a ON a.operation_id=r.operation_id WHERE r.outcome='completed' ORDER BY r.id")==completed_before
    interrupted=rows(database,"SELECT o.state,(SELECT COUNT(*) FROM audit_events h WHERE h.operation_id=o.id AND h.kind='operation_execution_handoff') FROM operations o WHERE o.id=?",(witness['operation_id'],))
    assert len(interrupted)==1 and interrupted[0][0]=='executing' and interrupted[0][1]==1
    # Reopen the actual Product and use a fresh canonical Root. Recovery must
    # preserve prior history and may not reapply the interrupted child.
    invoke(binary,environment,'retry',root)
    after_retry=facts(database);assert len(after_retry['events'])==3 and after_retry['events'][:1]==before['events']
    assert len(after_retry['rows'])==2 and after_retry['sequence']==[(3,)]
    identity=json.loads((root/'fixture-identity.json').read_text(encoding='utf-8'))
    original=rows(database,'SELECT revision,payload FROM memories WHERE id=?',(identity['id'],))
    assert len(original)==1 and original[0][0]==2 and json.loads(original[0][1])['record']['status']=='corrected'
    assert not (root/'state/memory-v3/events.jsonl').exists()
    completed_after=rows(database,"SELECT r.id,r.operation_id FROM operation_receipts r JOIN derived_operation_admissions a ON a.operation_id=r.operation_id WHERE r.outcome='completed' ORDER BY r.id")
    assert len(completed_after)==2
    evidence=dict(status='ACTUAL_PASS',binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        root=str(root),barrier=witness,interrupted_operation=interrupted,
        original_history_sha256=hashlib.sha256(json.dumps(before,ensure_ascii=False,separators=(',',':')).encode()).hexdigest(),
        completed_derived_before=len(completed_before),completed_derived_after=len(completed_after),
        event_count_after_retry=len(after_retry['events']),external_kill=True,sql_writes_by_runner=0)
    (root/'actual-evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(evidence,ensure_ascii=False))
if __name__=='__main__':main()

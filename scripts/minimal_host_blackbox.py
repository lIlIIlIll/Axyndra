#!/usr/bin/env python3
"""Execute only an explicitly supplied minimal binary in fresh local state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess


def check(binary: Path, work: Path, env=None):
    binary=binary.resolve(strict=True)
    before=hashlib.sha256(binary.read_bytes()).hexdigest()
    work.mkdir(parents=True,exist_ok=False)
    settings=work/'settings';workspace=work/'workspace';workspace.mkdir()
    records=[]
    prefix=[str(binary),'--settings-root',str(settings),'--workspace-root',str(workspace)]
    def call(tail,*,ok=True,paths=True):
        command=(prefix if paths else [str(binary)])+tail
        result=subprocess.run(command,cwd=workspace,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                              timeout=30,text=True,encoding='utf-8')
        records.append({'argv':tail,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
        assert (result.returncode==0)==ok,records[-1]
        return json.loads(result.stdout)
    def package(version):
        path=work/('package-'+version);(path/'extensions').mkdir(parents=True)
        (path/'package.json').write_text(json.dumps({'name':'minimal-blackbox','version':version,
            'pi':{'extensions':['extensions/index.js']}}),encoding='utf-8')
        (path/'extensions/index.js').write_text("throw new Error('management must not execute package code');\n",encoding='utf-8')
        return path
    first=package('1.0.0');second=package('2.0.0')
    inspected=call(['plugin','inspect',str(first)])
    installed=call(['plugin','install',str(first),'user'])['record']
    identity=installed['namespace']
    assert inspected['content_digest']==installed['content_digest'] and installed['enabled'] is False
    assert call(['plugin','enable',identity,'user'])['record']['enabled'] is True
    updated=call(['plugin','update',identity,str(second),'user'])['record']
    assert updated['version']=='2.0.0' and updated['content_digest']!=installed['content_digest']
    # Every invocation is a fresh process reopening the same registry and history.
    rolled=call(['plugin','rollback',identity,'user'])['record']
    assert rolled['content_digest']==installed['content_digest']
    assert call(['plugin','disable',identity,'user'])['record']['enabled'] is False
    assert call(['plugin','doctor'])['diagnostics']==[]
    assert call(['plugin','uninstall',identity,'user'])['ok'] is True
    assert call(['plugin','list'])['records']==[]
    assert call(['plugin','gc'])['deleted']==[]
    assert Path(installed['root']).is_dir() and Path(updated['root']).is_dir()
    # This schema-minimal historical fixture exercises readonly open/latest.
    # Full canonical Store/inspection proof is covered by the Cangjie unit tests.
    db=work/'historical.db'
    with sqlite3.connect(db) as connection:
        connection.execute('CREATE TABLE runs(id TEXT,thread_id TEXT,started_at_millis INTEGER)')
        connection.execute("INSERT INTO runs VALUES ('old-run','old-thread',123)")
        connection.execute('PRAGMA user_version=999')
    dbhash=hashlib.sha256(db.read_bytes()).hexdigest()
    assert call(['history','latest',str(db),'old-thread'],paths=False)['run_id']=='old-run'
    assert call(['history','latest',str(work/'missing'/'db'),'none'],paths=False,ok=False)['ok'] is False
    assert not (work/'missing').exists()
    assert hashlib.sha256(db.read_bytes()).hexdigest()==dbhash
    rejected=call(['tools','invoke','bash','{}'],ok=False,paths=False)
    assert rejected['code']=='minimal.command_invalid'
    assert hashlib.sha256(binary.read_bytes()).hexdigest()==before
    report={'status':'PASS','binary_sha256':before,'invocations':len(records),'checks':9,
        'checks_description':['static inspect/install remains disabled','explicit enable without code execution',
         'update exact package identity','rollback reads shared history across process restarts',
         'disable and doctor','uninstall/gc retains historical packages','read-only historical latest',
         'missing history does not create state','no model/tool/service execution command'],
        'records':records,'package_execution_trap_not_triggered':True,
        'process_tree_instrumented':False}
    (work/'summary.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);p.add_argument('--work',type=Path,required=True)
    args=p.parse_args();report=check(args.binary,args.work)
    print('minimal host blackbox passed: '+str(report['checks'])+' checks')

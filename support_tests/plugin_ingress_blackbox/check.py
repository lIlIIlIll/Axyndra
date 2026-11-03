#!/usr/bin/env python3
"""Actual App -> installed native decoder -> canonical External SQLite path.
No model provider, forged Runtime DTO, fake Tool executor or autoapproval.
Run after applying the candidate and building the App/package; never builds.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import select
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'support_tests/plugin_cli_blackbox'))
from check import stored_value
from owned_process import owned_process
META={'io.modelcontextprotocol/protocolVersion':'2026-07-28',
      'io.modelcontextprotocol/clientCapabilities':{}}
def encoded(value):return json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()
def request(identity,name,args):return {'jsonrpc':'2.0','id':identity,'method':'tools/call','params':{'_meta':META,'name':name,'arguments':args}}
def require(value,message):
    if not value:raise AssertionError(message)
def wait_until(check,timeout=15):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if check():return
        time.sleep(.025)
    raise AssertionError('bounded condition did not become true')
class Reader:
    def __init__(self,process):
        self.process=process;self.frames=queue.Queue()
        def read():
            try:
                for line in process.stdout:
                    require(len(line)<=65537 and line.endswith(b'\n'),'bounded complete response')
                    self.frames.put(json.loads(line))
            except BaseException as error:self.frames.put(error)
            finally:self.frames.put(EOFError())
        self.thread=threading.Thread(target=read,daemon=True);self.thread.start()
    def receive(self,timeout=30):
        value=self.frames.get(timeout=timeout)
        if isinstance(value,BaseException):raise value
        return value
    def send(self,value):
        raw=encoded(value);self.process.stdin.write(raw+b'\n');self.process.stdin.flush();return raw

def main(args):
    evidence=args.evidence.resolve();evidence.mkdir(parents=True,exist_ok=False)
    checks=[];commands=[]
    def checkpoint():
        (evidence/'progress.json').write_text(json.dumps({'status':'RUNNING','checks':checks,'commands':commands},indent=2)+'\n',encoding='utf-8')
    def mark(name):
        checks.append(name);checkpoint();print('PASS '+name,flush=True)
    with tempfile.TemporaryDirectory(prefix='axyndra-ingress-') as scratch:
        directory=Path(scratch);workspace=directory/'workspace';home=directory/'home';workspace.mkdir();home.mkdir()
        keep={'PATH','LANG','LC_ALL','HOME','TMPDIR','XDG_RUNTIME_DIR','AXYNDRA_NETWORK_BRIDGE','AXYNDRA_CLANG_RUNTIME_PATH'}
        env={key:value for key,value in os.environ.items() if key in keep}
        env['AXYNDRA_HOME']=str(home)
        app=args.app.resolve()
        def command(argv):
            line=[str(app),'--cwd',str(workspace)]+argv
            result=subprocess.run(line,cwd=workspace,env=env,capture_output=True,timeout=60)
            commands.append({'argv':argv,'exit':result.returncode,'stdout':result.stdout.decode(errors='replace'),'stderr':result.stderr.decode(errors='replace')})
            checkpoint()
            require(result.returncode==0,'real CLI command failed: '+str(commands[-1]))
            return result.stdout
        command(['plugin','import',str(args.package.resolve()),'--scope','user'])
        record=next(item for item in json.loads(command(['plugin','list','--json'])) if item['namespace']=='axyndra:mcp-server')
        command(['plugin','enable',record['id'],'--scope','user'])
        configuration={'schema':'axyndra.stdio-ingress-grants/v1','grants':[{'id':'local-peer','namespace':record['namespace'],
            'package_digest':record['content_digest'],'service':'decoder','principal':'local-operator-peer','thread_id':'actual-stdio-thread',
            'exports':['read','bash'],'capabilities':['workspace.read','workspace.write','process.spawn'],'lifetime_ms':120000}]}
        configuration_file=home/'plugins/ingress.json';configuration_file.write_text(json.dumps(configuration),encoding='utf-8')
        (workspace/'fixture.txt').write_text('ingress Unicode 闆猏n',encoding='utf-8')
        (workspace/'larger.txt').write_text('x'*7000,encoding='utf-8')
        database=next(home.rglob('state.db'))
        def start(approval='manual'):
            return owned_process([str(app),'--cwd',str(workspace),'--approval-mode',approval,'plugin','serve','local-peer'],
                cwd=workspace,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        with start() as process:
            peer=Reader(process)
            peer.send({'jsonrpc':'2.0','id':'list','method':'tools/list','params':{'_meta':META}})
            names={item['name'] for item in peer.receive()['result']['tools']};require(names=={'read','bash'},'fixed actual export snapshot')
            mark('actual native directory exposes only the operator allowlist')
            raw=peer.send(request('read-one','read',{'path':'fixture.txt'}));result=peer.receive()
            require(result['id']=='read-one' and 'result' in result and not result['result'].get('isError',False),'real read completes')
            with sqlite3.connect(database) as db:
                rows=db.execute("SELECT provenance FROM items WHERE kind='tool_call'").fetchall()
                decoded=[stored_value(row[0]) for row in rows]
                sources=[item['direct_origin'] for item in decoded if item.get('direct_origin',{}).get('kind')=='external']
                origin=next(item for item in sources if item['request_id']=={'kind':'text','value':'read-one'})
                require(origin['schema']=='axyndra.direct-origin/v3' and origin['principal_id']=='local-operator-peer','actual principal is host configuration')
                require(origin['frame']['raw_frame_digest']==hashlib.sha256(raw).hexdigest(),'raw bytes captured before decoder')
                require(origin['frame']['decoder']['package_digest']==record['content_digest'],'fixed decoder digest durable')
                require(db.execute('SELECT count(*) FROM model_decisions').fetchone()[0]==0,'no fabricated model')
                require(db.execute("SELECT count(*) FROM operation_receipts WHERE outcome='completed'").fetchone()[0]>=1,'real receipt')
            mark('real External v3 SystemNote ToolCall handoff Receipt and raw frame digest')
            peer.send(request('ask','bash',{'command':'printf forbidden > forbidden.txt'}));rejected=peer.receive()
            require('error' in rejected and not (workspace/'forbidden.txt').exists(),'approval is not granted by decoder or peer')
            mark('noninteractive ingress refuses host approval requirement without effect')
            for identity in (7,'7'):
                peer.send(request(identity,'read',{'path':'fixture.txt'}));require(peer.receive()['id']==identity,'typed correlation')
            mark('text and numeric request identities remain distinct')
            process.stdin.close();require(process.wait(timeout=5)==0,'EOF cleanup acknowledged')
        with start('trusted') as process:
            peer=Reader(process)
            peer.send(request('active','bash',{'command':'printf ready > ready; sleep 30','timeout':40}))
            wait_until(lambda:(workspace/'ready').exists(),timeout=30)
            peer.send(request('queued','bash',{'command':'printf forbidden > queued-effect'}))
            peer.send({'jsonrpc':'2.0','method':'notifications/cancelled','params':{'requestId':'queued'}})
            peer.send({'jsonrpc':'2.0','method':'notifications/cancelled','params':{'requestId':'active'}})
            replies=[peer.receive(),peer.receive()]
            require({item['id'] for item in replies}=={'active','queued'} and not (workspace/'queued-effect').exists(),'active and queued cancellation')
            peer.send(request('after-cancel','read',{'path':'fixture.txt'}));require('result' in peer.receive(),'next request remains live')
            mark('independent cancel stops active effect and prevents queued admission without revoking next request')
            process.stdin.close();require(process.wait(timeout=5)==0,'cancelled connection cleanup')
        for mode in ('backpressure','backpressure-cancel','closed-output'):
            with start() as process:
                if mode.startswith('backpressure'):fcntl.fcntl(process.stdout.fileno(),fcntl.F_SETPIPE_SZ,4096)
                process.stdin.write(encoded(request(mode,'read',{'path':'larger.txt'}))+b'\n');process.stdin.flush()
                if mode=='closed-output':process.stdout.close()
                if mode=='backpressure-cancel':
                    require(select.select([process.stdout],[],[],30)[0], 'actual writer produced bytes before cancellation')
                    time.sleep(.05)
                    started=time.monotonic();process.stdin.close();process.wait(timeout=3)
                    require(time.monotonic()-started<3,'EOF cancellation must interrupt the actual backpressured write')
                else:
                    code=process.wait(timeout=15)
                    require(code!=0,'bounded output failure must fail the process')
                mark('actual CLI '+mode+' returns without stuck writer or fabricated cleanup success')
        configuration['grants'][0]['exports']=[]
        configuration_file.write_text(json.dumps(configuration),encoding='utf-8')
        with start() as process:
            peer=Reader(process);peer.send({'jsonrpc':'2.0','id':'empty','method':'tools/list','params':{'_meta':META}})
            require(peer.receive()['result']['tools']==[],'empty directory remains usable')
            process.stdin.close();require(process.wait(timeout=5)==0,'empty owner cleanup')
        mark('empty authorized directory lists zero tools')
    summary={'status':'PASS','checks':checks,'actual_checks':len(checks),'app_sha256':hashlib.sha256(app.read_bytes()).hexdigest(),'commands':commands}
    (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
    require(len(checks)==9,'nonzero complete scenario list')
    print('Plugin stdio ingress blackbox passed: 9 actual App scenarios')
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--app',type=Path,required=True);parser.add_argument('--package',type=Path,required=True);parser.add_argument('--evidence',type=Path,required=True)
    main(parser.parse_args())

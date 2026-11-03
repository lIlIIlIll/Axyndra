"""Actual Linux ACP fd0/fd1 child, original Main writer, no compiled/runtime credit here."""
import argparse
from array import array
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import termios
import time
from frontend_real_io95 import canonical, error_oracle

MAX_BYTES=1048576
CASE_SECONDS=60
INNER_SECONDS=45

def require(value,why):
    if not value:
        raise AssertionError(why)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--repo',type=Path,required=True)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--case',required=True)
    parser.add_argument('--mode',choices=('eof','partial'),required=True)
    args=parser.parse_args()
    require(sys.platform=='linux','actual Linux native-pipe fixture only')
    repo=args.repo.resolve(strict=True);root=args.root.resolve(strict=True)
    require(args.case.startswith('ActualAcpPhysicalOwnership113Tests.'),'one actual selected ACP child case')
    require(not (root/'physical-pipe-proof113.json').exists(),'fresh independent pipe evidence')
    env=os.environ.copy()
    env['AXYNDRA_ACP_PHYSICAL_CHILD113']=str(root)
    # Existing Main95 redirect uses these real inherited descriptors; the
    # old six-case fixture itself and all its oracles remain byte-for-byte.
    data_read,data_write=os.pipe()
    capacity=fcntl.fcntl(data_write,fcntl.F_SETPIPE_SZ,4096)
    require(capacity==fcntl.fcntl(data_write,fcntl.F_GETPIPE_SZ)==4096,'actual measured kernel pipe capacity')
    env['AXYNDRA_FRONTEND_DATA_FD95']=str(data_write)
    command=[str(repo/'scripts/pinned_cangjie'),'cjpm','test','-m','agent_app','--skip-build',
        '--filter',args.case,'--parallel','1','--timeout-each=60s','--no-color','--no-progress']
    started=time.monotonic()
    proc=subprocess.Popen(command,cwd=repo,env=env,stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,pass_fds=(data_write,),start_new_session=True)
    os.close(data_write)
    selector=selectors.DefaultSelector()
    for stream,name in ((proc.stdout,'unit_stdout'),(proc.stderr,'unit_stderr'),(data_read,'data')):
        fd=stream if isinstance(stream,int) else stream.fileno()
        os.set_blocking(fd,False);selector.register(fd,selectors.EVENT_READ,name)
    buffers={name:bytearray() for name in ('unit_stdout','unit_stderr','data')}
    parsed=0;session=None;prompt_sent=False;blocked=False;block_verified=False
    data_open=True;stdin_closed=False;raw_exit=None;proof_written=False
    def send(value):
        proc.stdin.write((json.dumps(value,ensure_ascii=False,separators=(',',':'))+'\n').encode())
        proc.stdin.flush()
    send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{}})
    send({'jsonrpc':'2.0','id':2,'method':'session/new','params':{'cwd':str(root),'mcpServers':[]}})
    try:
        while selector.get_map() or proc.poll() is None:
            require(time.monotonic()-started<INNER_SECONDS,'actual child/drain exceeds45s inside original60s test')
            if not prompt_sent:
                # Parse actual original ACP setup, never fabricate sessionId.
                raw=bytes(buffers['data'])
                while b'\n' in raw[parsed:]:
                    end=raw.index(b'\n',parsed)
                    frame=json.loads(raw[parsed:end].decode('utf8','strict'));parsed=end+1
                    if frame.get('id')==2:
                        require('error' not in frame,'actual original new-session request failed')
                        session=frame['result']['sessionId']
                if session is not None:
                    require(isinstance(session,str) and session,'actual installed ACP session identity')
                    send({'jsonrpc':'2.0','id':47,'method':'session/prompt','params':{'sessionId':session,
                        'prompt':[{'type':'text','text':'Run the original installed canonical observer once95.'}]}})
                    prompt_sent=True
            if not blocked and (root/'canonical-ready95').exists():
                require(prompt_sent,'canonical producer follows real original prompt request')
                # Drain only the prelude while the real observer is held; then
                # stop consuming the same OS pipe before its large error.
                while True:
                    try:chunk=os.read(data_read,65536)
                    except BlockingIOError:break
                    require(chunk,'actual data pipe closed before original observer returned')
                    buffers['data'].extend(chunk)
                    require(len(buffers['data'])<=MAX_BYTES,'bounded actual ACP prelude')
                selector.unregister(data_read);blocked=True
                (root/'release-observer95').write_bytes(b'actual observer may return while stdout reader pauses\n')
            if blocked and not stdin_closed and (root/'actual-source-admitted113').exists():
                # First the real original output child enters Main's writer.
                # Then close the LAST fd0 writer, while that real frame is
                # blocked. This cannot race EOF ahead of canonical failure.
                proc.stdin.close();stdin_closed=True
                (root/'stdin-peer-closed113').write_bytes(b'actual last input writer closed after output admission\n')
            if blocked and not block_verified and (root/'blocked113.json').exists():
                state=json.loads((root/'blocked113.json').read_bytes())
                canonical(state)
                require(state['output_child_ack'] is False and state['failure_offers']==1,
                    'exact original Main output child stays unacknowledged while real writer is blocked')
                queued=array('i',[0])
                fcntl.ioctl(data_read,termios.FIONREAD,queued,True)
                require(queued[0]==capacity,'actual kernel pipe is full, not a mocked blocked-output flag')
                block_verified=True;selector.register(data_read,selectors.EVENT_READ,'data')
            for key,_ in selector.select(.01):
                try:chunk=os.read(key.fd,4096)
                except BlockingIOError:continue
                if not chunk:
                    selector.unregister(key.fd);continue
                buffers[key.data].extend(chunk)
                require(len(buffers[key.data])<=MAX_BYTES,'bounded actual raw pipe '+key.data)
                if args.mode=='partial' and key.data=='data' and b'"id":47,"error":' in buffers['data']:
                    # The real peer consumed an actual prefix and then closes
                    # the LAST OS reader. No injected exception or fake ACK.
                    require(len(buffers['data'])<131072,'actual broken prefix is shorter than complete large error')
                    selector.unregister(data_read);os.close(data_read);data_open=False
                    (root/'actual-reader-closed113').write_bytes(b'actual last stdout reader closed after original prefix\n')
            if proc.poll() is not None and not block_verified:
                raise AssertionError('child exited before actual kernel backpressure witness; exit is not ACK')
        raw_exit=proc.wait(timeout=1)
        require(raw_exit==0,'actual selected child failed, including SDK EPIPE/SIGPIPE: '+str(raw_exit))
        report=bytes(buffers['unit_stdout']).decode('utf8','strict')
        summaries=re.findall(r'Summary: TOTAL:\s*(\d+)\s+PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)\s+FAILED:\s*(\d+)',report,re.I)
        require(summaries,'actual fresh SDK unit summary, no default PASS')
        total,passed,skipped,errors,failed=map(int,summaries[-1])
        require(total>0 and passed==1 and skipped==total-1 and errors==failed==0,'one actual selected PASS and unchanged original denominator')
        require(stdin_closed and block_verified,'actual EOF and actual full kernel pipe observed')
        before=json.loads((root/'blocked113.json').read_bytes());done=json.loads((root/'done113.json').read_bytes())
        canonical(before);canonical(done)
        require(done['failure_offers']==1,'actual output offered once, no hidden retry')
        if args.mode=='partial':
            require(not data_open and done['output_child_ack'] is False and done['body_status']==1,
                'actual incomplete/broken output retains its precise child and nonzero frontend status')
            require(done['secondary_retained'] is True and done['secondary_full8_loan_verified'] is True,
                'actual returned original output-exception consumer stays unacknowledged, full8 checked inside paid loan')
            require(done['owners']>0 and done['bytes']>0,'original Native bank remains charged; numeric totals alone are not secondary evidence')
            require(bytes(buffers['data']).count(b'"id":47,"error":')==1,'real incomplete ACP response prefix not replayed')
        else:
            require(done['output_child_ack'] is True,'exact Main output child ACK after actual complete write/flush/helper return')
            frames=[json.loads(line.decode('utf8','strict')) for line in bytes(buffers['data']).splitlines() if line]
            replies=[v for v in frames if v.get('id')==47]
            require(len(replies)==1 and replies[0].get('jsonrpc')=='2.0' and 'error' in replies[0],
                'one original ACP error response identity/schema, no fake tool terminal or duplicate reply')
            data=replies[0]['error']['data']
            error_oracle(data['error_data'],True)
            require(data['secondary_errors']==[],'this actual successful writer adds no fabricated secondary failure')
            require(len(data['diagnostics'])==1,'one actual original Diagnostic event')
            diagnostic=data['diagnostics'][0]
            require(set(diagnostic)=={'type','sequence','occurred_at_millis','trace_id','run_id','turn_id',
                'request_id','semantic_request_id','attempt_id','tool_batch_id','tool_call_id','operation_id','error_data'},
                'all eleven original EventMeta fields and complete payload, no reduced six-field detail')
            require(diagnostic['type']=='diagnostic' and diagnostic['sequence']>0 and diagnostic['run_id'],
                'actual original event identity/sequence')
            error_oracle(diagnostic['error_data'],True)
        proof={'status':'ACTUAL_LINUX_ACP_PIPE_CHILD_SOURCE_SCOPED_ONLY','mode':args.mode,'command':command,
            'physical_child_exit_code':raw_exit,'pipe_capacity':capacity,'case_seconds':CASE_SECONDS,
            'actual_original_request_session_id':session,'actual_main_body_status':done['body_status'],
            'actual_output_child_ack':done['output_child_ack'],'physical_exit_as_ACK':False,
            'caller_event_complete_from_output_child_alone':False,'Root_zero_credit':0,
            'formal_Product_or_all18_credit':0,'raw_files':{}}
        for name,raw in buffers.items():
            path=root/(name+'.raw');path.write_bytes(raw)
            proof['raw_files'][path.name]=hashlib.sha256(raw).hexdigest()
        (root/'physical-pipe-proof113.json').write_text(json.dumps(proof,indent=2)+'\n',encoding='utf8')
        proof_written=True
        print(json.dumps({'status':proof['status'],'mode':args.mode,'exit_code':raw_exit}),flush=True)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
        selector.close()
        if data_open:os.close(data_read)
        if not stdin_closed:proc.stdin.close()
        for name,raw in buffers.items():(root/(name+'.raw')).write_bytes(raw)
        (root/'physical-child-exit113.json').write_text(json.dumps({'actual_exit':proc.returncode,
            'status':'PASS' if proof_written else 'FAIL','physical_exit_as_ACK':False})+'\n',encoding='utf8')

if __name__=='__main__':main()

#!/usr/bin/env python3
"""Actual App external ingress capacity; requires fresh payload-aware Server package."""
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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'support_tests/plugin_cli_blackbox'))
from check import stored_value
from owned_process import owned_process

META = {'io.modelcontextprotocol/protocolVersion': '2026-07-28', 'io.modelcontextprotocol/clientCapabilities': {}}
PHYSICAL = {'max_frame_bytes': 4194304, 'max_input_bytes': 1048576,
            'max_prepare_bytes': 2097152, 'max_result_bytes': 2097152,
            'max_directory_bytes': 65536, 'max_tools': 256, 'call_timeout_ms': 30000}
PAYLOAD = {'version': 1, 'max_message_bytes': 16777216, 'max_input_bytes': 4194304,
           'max_prepare_bytes': 8388608, 'max_result_bytes': 8388608, 'max_write_bytes': 1048576}

def require(ok, message):
    if not ok:
        raise AssertionError(message)

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def tree(root):
    return {p.relative_to(root).as_posix(): sha(p.read_bytes()) for p in sorted(root.rglob('*')) if p.is_file()}

def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()

def request(identity, path):
    return {'jsonrpc': '2.0', 'id': identity, 'method': 'tools/call',
            'params': {'_meta': META, 'name': 'read', 'arguments': {'path': path}}}

class Reader:
    def __init__(self, process):
        self.process = process
        self.frames = queue.Queue()
        def reader():
            try:
                while True:
                    raw = process.stdout.readline(4194305)
                    if not raw:
                        break
                    require(raw.endswith(b'\n') and len(raw) <= 4194304, 'bounded complete response')
                    self.frames.put((raw, json.loads(raw)))
            except BaseException as error:
                self.frames.put(error)
            finally:
                self.frames.put(EOFError())
        self.thread = threading.Thread(target=reader, daemon=True)
        self.thread.start()
    def send(self, value):
        raw = encoded(value)
        self.process.stdin.write(raw+b'\n')
        self.process.stdin.flush()
        return raw
    def receive(self):
        value = self.frames.get(timeout=90)
        if isinstance(value, BaseException):
            raise value
        return value

def main(args):
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=False)
    app = args.app.resolve()
    package = args.package.resolve()
    before_app, before_package = tree(app.parent.parent), tree(package)
    report = {'status': 'RUNNING', 'checks': [], 'app_sha256': sha(app.read_bytes()),
              'package_before': before_package, 'runner_sha256': sha(Path(__file__).read_bytes())}
    def save():
        (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    def mark(name, **evidence):
        report['checks'].append({'name': name, **evidence})
        print('PASS '+name, flush=True)
        save()
    try:
        with tempfile.TemporaryDirectory(prefix='axyndra-ingress-capacity-') as scratch:
            root = Path(scratch)
            home = root/'home'; home.mkdir()
            workspace = root/'workspace'; workspace.mkdir()
            env = {k: v for k, v in os.environ.items() if k in {'PATH','HOME','LANG','LC_ALL','TMPDIR','XDG_RUNTIME_DIR'}}
            env['AXYNDRA_HOME'] = str(home)
            base = [str(app), '--cwd', str(workspace)]
            def command(tail):
                run = subprocess.run(base+tail, cwd=workspace, env=env, capture_output=True, timeout=60)
                require(run.returncode == 0, 'CLI failed: '+run.stdout.decode(errors='replace')+run.stderr.decode(errors='replace'))
                return run.stdout
            command(['plugin','import',str(package),'--scope','user'])
            record = next(v for v in json.loads(command(['plugin','list','--json'])) if v['namespace']=='axyndra:mcp-server')
            command(['plugin','enable',record['id'],'--scope','user'])
            configuration = {'schema':'axyndra.stdio-ingress-grants/v1','grants':[{
                'id':'capacity-peer','namespace':record['namespace'],'package_digest':record['content_digest'],
                'service':'decoder','principal':'actual-capacity-peer','thread_id':'actual-capacity-thread',
                'exports':['read'],'capabilities':['workspace.read'],'lifetime_ms':300000,
                'protocol_limits':PHYSICAL,'payload_limits':PAYLOAD}]}
            config = home/'plugins/ingress.json'
            def configure(value):
                config.write_text(json.dumps(value))
            configure(configuration)
            database = next(home.rglob('state.db'))
            def start():
                return owned_process(base+['--approval-mode','manual','plugin','serve','capacity-peer'],
                    cwd=workspace, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            with start() as process:
                peer = Reader(process)
                for size in (32768, 98304, 1048576):
                    content = 'x'*(size-4)+'雪!'
                    filename = 'large-'+str(size)+'.txt'
                    (workspace/filename).write_text(content, encoding='utf-8')
                    identity = 'large-'+str(size)
                    raw_request = peer.send(request(identity, filename+':raw'))
                    raw_response, response = peer.receive()
                    require(response['id']==identity and 'result' in response and not response['result'].get('isError'), 'complete actual read')
                    value = response['result']['structuredContent']
                    require(value['content']==content and value['returned_bytes']==size and value['truncated'] is False, 'full Unicode read without truncation')
                    with sqlite3.connect(database) as db:
                        results = [stored_value(row[0]) for row in db.execute("SELECT payload FROM items WHERE kind='tool_result'")]
                        canonical = [item for item in results if item['result']==value]
                        require(len(canonical)==1, 'exactly one durable canonical ToolResult')
                        item = canonical[0]
                        receipt = db.execute('SELECT outcome FROM operation_receipts WHERE id=?', (item['receipt_id'],)).fetchone()
                        require(receipt == ('completed',), 'canonical ToolResult refers to actual completed Receipt')
                        origins = [stored_value(row[0]) for row in db.execute("SELECT provenance FROM items WHERE kind='tool_call'")]
                        origin = next(item['direct_origin'] for item in origins
                            if item.get('direct_origin',{}).get('request_id')=={'kind':'text','value':identity})
                        require(origin['principal_id']=='actual-capacity-peer' and
                                origin['frame']['raw_frame_digest']==sha(raw_request), 'original receiver bytes and principal persist')
                        require(db.execute('SELECT count(*) FROM model_decisions').fetchone()[0]==0, 'no fabricated model decisions')
                    mark('actual complete read '+str(size), payload_sha256=sha(content.encode()),
                         response_bytes=len(raw_response), response_sha256=sha(raw_response))
                process.stdin.close()
                require(process.wait(timeout=5)==0, 'normal EOF cleanup acknowledgement')
            mark('EOF closes actual decoder and stdin/stdout owners')

            # Conflicting profile shape fails before an external call/effect.
            for missing in ('protocol_limits', 'payload_limits'):
                with sqlite3.connect(database) as db:
                    before_operations = db.execute('SELECT count(*) FROM operations').fetchone()[0]
                invalid = json.loads(json.dumps(configuration))
                del invalid['grants'][0][missing]
                configure(invalid)
                with start() as process:
                    process.stdin.close()
                    require(process.wait(timeout=10)!=0, 'incomplete operator profile fails closed')
                with sqlite3.connect(database) as db:
                    require(db.execute('SELECT count(*) FROM operations').fetchone()[0] == before_operations,
                            'invalid capacity configuration admits no operation')
                mark('reject incomplete '+missing)
            configure(configuration)
            with start() as process:
                fcntl.fcntl(process.stdout.fileno(), fcntl.F_SETPIPE_SZ, 4096)
                process.stdin.write(encoded(request('backpressure', 'large-1048576.txt:raw'))+b'\n')
                process.stdin.flush()
                require(select.select([process.stdout], [], [], 90)[0], 'real large response has begun')
                started = time.monotonic()
                process.stdin.close()
                process.wait(timeout=5)
                require(time.monotonic()-started<5, 'EOF interrupts actual large blocked output')
            mark('large output backpressure cancellation joins actual owners')
            # Reopen the same application and SQLite; committed result persists.
            with start() as process:
                peer = Reader(process)
                peer.send(request('after-restart', 'large-32768.txt:raw'))
                require('result' in peer.receive()[1], 'new session works after actual restart')
                process.stdin.close()
                require(process.wait(timeout=5)==0, 'restart owner closes')
            with sqlite3.connect(database) as db:
                results = [stored_value(row[0]) for row in db.execute("SELECT payload FROM items WHERE kind='tool_result'")]
                require(any(item['result'].get('returned_bytes')==1048576 and
                            sha(item['result'].get('content','').encode())==sha(('x'*(1048576-4)+'雪!').encode())
                            for item in results), 'large canonical result survives application restart')
            mark('application restart preserves complete large canonical result')
        require(len(report['checks'])==8, 'all eight capacity scenarios')
        report['status'] = 'PASS'
    except BaseException as error:
        report['status'] = 'FAIL'; report['error'] = repr(error)
        raise
    finally:
        report['app_unchanged'] = before_app == tree(app.parent.parent)
        report['package_unchanged'] = before_package == tree(package)
        if not report['app_unchanged'] or not report['package_unchanged']:
            report['status'] = 'FAIL'
        report['actual_checks'] = len(report['checks'])
        save()
    require(report['status']=='PASS', 'fixed artifacts changed')
    print('Plugin ingress capacity blackbox passed: 8 actual App scenarios')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    main(parser.parse_args())

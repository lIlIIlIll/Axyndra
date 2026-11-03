#!/usr/bin/env python3
"""Actual authenticated View input failures, recovery and physical owner retirement."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
SCENARIOS = (
    'wrong_window', 'wrong_message_type', 'wrong_outer_sequence', 'wrong_header_sequence',
    'duplicate_begin', 'overlapping_chunk', 'duplicate_chunk', 'odd_hex', 'uppercase_hex',
    'oversized_chunk', 'oversized_logical', 'length_mismatch', 'early_end', 'bad_digest',
    'wrong_inner_command', 'invalid_utf8', 'invalid_json', 'partial_logical_eof', 'deadline',
    'partial_physical_eof', 'invalid_physical_utf8', 'oversized_physical',
)
parser = argparse.ArgumentParser(description=__doc__)
for name in ('candidate', 'output'):
    parser.add_argument('--' + name, type=Path, required=True)
parser.add_argument('--scenario', choices=SCENARIOS, help='Run one fault; the default runs the entire matrix.')
parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
args = parser.parse_args()
args.repo = ROOT
args.candidate = args.candidate.resolve(strict=True)
args.output = args.output.resolve()


def normalized(value):
    if isinstance(value, str):
        for source, replacement in sorted(((str(args.output), '<evidence>'), (str(args.repo), '<repo>'),
                                            (str(Path.home()), '$HOME')), key=lambda item: -len(item[0])):
            value = value.replace(source, replacement)
        return value
    if isinstance(value, dict):
        return {key: normalized(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalized(item) for item in value]
    return value


if not args.worker:
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    sys.path.insert(0, str(args.repo))
    from scripts import rpc_case_process_watch as custody
    guarded = [Path(__file__), args.repo / 'support_tests/view_form_fixture/worker.py',
               args.repo / 'support_tests/view_form_fixture/axyndra.plugin.json',
               args.repo / 'support_tests/tui_path_coverage/check.py', Path(custody.__file__),
               args.repo / 'libs/process4cj/native/libprocess4cj_native.so']
    def identities():
        return {path.relative_to(args.repo).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in guarded}
    before = identities()
    binary_before = hashlib.sha256(args.candidate.read_bytes()).hexdigest()
    started = time.monotonic()
    scenarios = (args.scenario,) if args.scenario else SCENARIOS
    results = []
    for scenario in scenarios:
        output = args.output / scenario
        output.mkdir(mode=0o700)
        command = [sys.executable, str(Path(__file__)), '--worker', '--scenario', scenario,
                   '--candidate', str(args.candidate), '--output', str(output / 'case')]
        physical = custody.run_case(command, output / 'case.log', 60, cwd=args.repo)
        case_path = output / 'case/summary.json'
        case = json.loads(case_path.read_text()) if case_path.is_file() else {'accepted': False, 'error': 'Actual case report is missing'}
        accepted = (case.get('accepted') is True and physical.get('exit_code') == 0 and
                    custody.process_custody_closed(physical))
        results.append({'scenario': scenario, 'accepted': accepted, 'case': case, 'physical_custody': physical})
        print(json.dumps({'scenario': scenario, 'accepted': accepted, 'error': case.get('error'),
                          'physical_closed': custody.process_custody_closed(physical)}), flush=True)
    after = identities()
    binary_after = hashlib.sha256(args.candidate.read_bytes()).hexdigest()
    accepted = (all(result['accepted'] for result in results) and len(results) == len(scenarios) and
                before == after and binary_before == binary_after)
    report = normalized({'status': 'PASS' if accepted else 'FAIL', 'accepted': accepted,
                         'scope': __doc__, 'seconds': time.monotonic() - started,
                         'candidate_sha256': binary_before, 'candidate_sha256_after': binary_after,
                         'sources_before': before, 'sources_after': after, 'scenarios': scenarios,
                         'case_process_seconds': 60, 'logical_transfer_deadline_seconds': 5,
                         'physical_request_bytes': 1048576, 'results': results})
    (args.output / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'status': report['status'], 'cases': len(results),
                      'passed': sum(result['accepted'] for result in results), 'seconds': report['seconds'],
                      'sources_unchanged': before == after, 'candidate_unchanged': binary_before == binary_after}, indent=2))
    raise SystemExit(0 if accepted else 1)
if args.scenario is None:
    parser.error('--worker requires --scenario')
scenario = args.scenario
args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
spec = importlib.util.spec_from_file_location('actual_private_view_environment', args.repo / 'support_tests/tui_path_coverage/check.py')
harness = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = harness
spec.loader.exec_module(harness)
workspace = args.output / 'workspace'
home = workspace / '.h'
environment = harness.clean_environment(home, workspace, args.output)
environment['AXYNDRA_HOME'] = '.h'
runtime = args.output / 'runtime'
runtime.mkdir(mode=0o700)
environment['XDG_RUNTIME_DIR'] = str(runtime)
for name in ('AXYNDRA_SDK_ROOT', 'AXYNDRA_REQUIRE_EXACT_TOOLCHAIN', 'AXYNDRA_SDK_CHECK_CACHE_DIR'):
    if name in os.environ:
        environment[name] = os.environ[name]
prefix = [str(args.repo / 'scripts/pinned_cangjie'), str(args.candidate), '--cwd', '.']
record = {'scope': 'Actual authenticated private owner TUI socket and typed logical View-action carrier; no internal Product mock or test-only dispatch.',
          'scenario': scenario, 'binary_sha256': hashlib.sha256(args.candidate.read_bytes()).hexdigest(), 'checks': {}}
process = None
peer = None
reader = None
frames = []
sent = []
public_frames = []
errors = []
threads = []


def cli(label, arguments):
    result = subprocess.run(prefix + ['plugin', *arguments], cwd=workspace, env=environment,
                            capture_output=True, timeout=10)
    record[label] = normalized({'exit': result.returncode, 'stdout': result.stdout.decode(errors='replace'),
                                'stderr': result.stderr.decode(errors='replace')})
    if result.returncode:
        raise RuntimeError('actual CLI failed: ' + label)


def check(label, condition):
    record['checks'][label] = bool(condition)
    if not condition:
        raise AssertionError(label)


def receive_until(predicate):
    until = time.monotonic() + 10
    while True:
        peer.settimeout(max(.001, until - time.monotonic()))
        raw = reader.readline(8388610)
        if not raw:
            raise EOFError('actual private owner closed before expected frame')
        if len(raw) > 8388609 or not raw.endswith(b'\n'):
            raise RuntimeError('actual private owner violated unchanged physical response bound')
        value = json.loads(raw)
        frames.append(value)
        if predicate(value):
            return value
        if isinstance(value, dict) and value.get('ok') is False:
            raise RuntimeError('actual private owner rejected authenticated request: ' + str(value.get('error')))


def send(value):
    data = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode() + b'\n'
    check('physical_request_bound', len(data) - 1 <= 1048576)
    sent.append(value)
    peer.sendall(data)



def connect_raw(identity):
    global peer, reader
    token = (root / 'token').read_text().strip()
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    peer.settimeout(10)
    peer.connect(str((root / 'broker.sock').relative_to(workspace)))
    request = {'version': 1, 'requestId': identity, 'token': token,
               'workspace': str(workspace.resolve()), 'kind': 'frontend180',
               'request': {'frontend': 'tui', 'command': 'tui', 'arguments': [], 'options': {'arguments': []}}}
    peer.sendall(json.dumps(request, separators=(',', ':')).encode() + b'\n')
    del request, token
    reader = peer.makefile('rb')
    receive_until(lambda value: isinstance(value, list) and value[:2] == ['state', 0])


def close_raw():
    global peer, reader
    if reader is not None:
        reader.close()
        reader = None
    if peer is not None:
        peer.close()
        peer = None


try:
    cli('import', ['import', str(args.repo / 'support_tests/view_form_fixture'), '--scope', 'user'])
    cli('enable', ['enable', 'axyndra:view_form', '--scope', 'user'])
    process = subprocess.Popen(prefix + ['--mode', 'rpc'], cwd=workspace, env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    ready = json.loads(process.stdout.readline())
    public_frames.append(ready)
    check('public_rpc_ready', ready.get('type') == 'ready')
    threads = [threading.Thread(target=lambda: public_frames.extend(json.loads(line) for line in process.stdout), daemon=True),
               threading.Thread(target=lambda: errors.append(process.stderr.read()), daemon=True)]
    for thread in threads:
        thread.start()
    roots = list((home / 'sessions/r').glob('pb-*'))
    record['broker_root_count'] = len(roots)
    check('one_actual_canonical_owner', len(roots) == 1)
    root = roots[0]
    os.chdir(workspace)
    connect_raw('private-wire-' + scenario)
    check('authenticated_actual_tui_backend', True)
    send(['call', 1, 'loadPluginView', ['plugin.axyndra:view_form.overview']])
    opened = receive_until(lambda value: isinstance(value, list) and value[:2] == ['result', 1])
    action = opened[2][2]
    check('actual_native_view_loaded', action[0] == 'PluginViewLoaded')
    metadata = json.loads(action[1][0])
    fields = {'list': 'a', 'table': 'r', 'input': 'actual private rejected chunk 雪 ' * 40}
    if scenario == 'oversized_chunk':
        fields['input'] = 'x' * 16384
    expected = hashlib.sha256(json.dumps(fields, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    value = ['call', 2, 'pluginViewAction', [metadata['view_id'], '1', 'submit', [[name, text] for name, text in fields.items()]]]
    if scenario == 'wrong_inner_command':
        value = ['call', 2, 'close', []]
    payload = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
    if scenario == 'invalid_utf8':
        payload = payload.replace('雪'.encode(), b'\xff', 1)
    if scenario == 'invalid_json':
        payload = payload[:-1]
    common = {'schema': 'axyndra.logical-json/v1', 'window': 'tui.view-action/v1', 'transfer_sequence': 1}
    begin = dict(common, message_type='pluginViewAction', bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
    chunk = dict(common, offset=0, bytes_hex=payload[:31].hex())
    outer = 1
    full_body = scenario in ('bad_digest', 'invalid_utf8', 'invalid_json', 'wrong_inner_command', 'length_mismatch')
    if scenario == 'wrong_window':
        begin['window'] = 'tui.foreign/v1'
    elif scenario == 'wrong_message_type':
        begin['message_type'] = 'confirmPluginView'
    elif scenario == 'wrong_outer_sequence':
        outer = 2
    elif scenario == 'wrong_header_sequence':
        begin['transfer_sequence'] = 2
    elif scenario == 'oversized_logical':
        begin['bytes'] = 16777217
    elif scenario == 'bad_digest':
        begin['sha256'] = '0' * 64
    elif scenario == 'length_mismatch':
        begin['bytes'] += 1
    start_frame = len(frames)
    started = time.monotonic()
    if scenario in ('partial_physical_eof', 'invalid_physical_utf8', 'oversized_physical'):
        raw = {'partial_physical_eof': b'["view_call_chunk",', 'invalid_physical_utf8': b'\xff\n',
               'oversized_physical': b'[' + b' ' * 1048576 + b']\n'}[scenario]
        sent.append({'physical_fault': scenario, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
        peer.sendall(raw)
        if scenario == 'partial_physical_eof':
            peer.shutdown(socket.SHUT_WR)
    else:
        send(['view_call_chunk', outer, 'payload_begin', begin])
        if full_body:
            for offset in range(0, len(payload), 4093):
                send(['view_call_chunk', 1, 'payload_chunk', dict(common, offset=offset, bytes_hex=payload[offset:offset + 4093].hex())])
            send(['view_call_chunk', 1, 'payload_end', common])
        elif scenario == 'duplicate_begin':
            send(['view_call_chunk', 1, 'payload_begin', begin])
        elif scenario == 'early_end':
            send(['view_call_chunk', 1, 'payload_end', common])
        elif scenario in ('overlapping_chunk', 'duplicate_chunk', 'odd_hex', 'uppercase_hex', 'oversized_chunk', 'partial_logical_eof'):
            if scenario == 'overlapping_chunk':
                chunk['offset'] = 1
            elif scenario == 'odd_hex':
                chunk['bytes_hex'] = 'a'
            elif scenario == 'uppercase_hex':
                chunk['bytes_hex'] = '5B'
            elif scenario == 'oversized_chunk':
                chunk['bytes_hex'] = payload[:16385].hex()
            send(['view_call_chunk', 1, 'payload_chunk', chunk])
            if scenario == 'duplicate_chunk':
                send(['view_call_chunk', 1, 'payload_chunk', chunk])
            if scenario == 'partial_logical_eof':
                peer.shutdown(socket.SHUT_WR)
    rejected = receive_until(lambda current: isinstance(current, dict) and current.get('ok') is False)
    record['rejection'] = rejected
    record['rejection_seconds'] = time.monotonic() - started
    error = rejected.get('error', {})
    code = {'partial_logical_eof': 'owner.peer_disconnected', 'deadline': 'owner.peer_frame_timeout',
            'partial_physical_eof': 'owner.peer_frame_incomplete', 'invalid_physical_utf8': 'owner.peer_read_failed',
            'oversized_physical': 'owner.peer_frame_too_large'}.get(scenario, 'tui.owner_transport_failed')
    kind = {'deadline': 'timeout', 'partial_physical_eof': 'protocol',
            'oversized_physical': 'protocol'}.get(scenario, 'transport')
    check('complete_canonical_rejection', set(error) == {'kind', 'code', 'message', 'retryable', 'fallback_allowed',
                                                       'fields', 'attempt_failure', 'observation'} and
          error['kind'] == kind and error['code'] == code and isinstance(error['message'], str) and
          error['retryable'] is False and error['fallback_allowed'] is False and error['fields'] == [] and
          error['attempt_failure'] is None and error['observation'] is None)
    check('invalid_input_never_invokes_native_command', expected not in json.dumps(frames[start_frame:]))
    close_raw()
    connect_raw('private-wire-recovery-' + scenario)
    send(['call', 9, 'loadPluginView', ['plugin.axyndra:view_form.overview']])
    reopened = receive_until(lambda current: isinstance(current, list) and current[:2] == ['result', 9])
    current = json.loads(reopened[2][2][1][0])
    recovered_fields = {'list': 'a', 'table': 'r', 'input': 'actual private recovery 雪'}
    recovered_digest = hashlib.sha256(json.dumps(recovered_fields, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    send(['call', 10, 'pluginViewAction', [current['view_id'], '1', 'submit', [[name, text] for name, text in recovered_fields.items()]]])
    receive_until(lambda current: isinstance(current, list) and current[:2] == ['result', 10])
    check('new_actual_private_frontend_recovers', recovered_digest in json.dumps(frames))
    send(['call', 11, 'close', []])
    receive_until(lambda current: isinstance(current, list) and current[:2] == ['result', 11])
    close_raw()
    process.stdin.close()
    process.wait(timeout=10)
    for thread in threads:
        thread.join(timeout=2)
    database = sqlite3.connect(home / 'sessions/state.db')
    try:
        counts = {table: database.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0]
                  for table in ('operations', 'operation_receipts', 'model_attempts', 'approvals')}
        counts['user_messages'] = database.execute("SELECT COUNT(*) FROM items WHERE kind='user_message'").fetchone()[0]
    finally:
        database.close()
    record['canonical_facts'] = counts
    check('no_execution_authority', all(count == 0 for count in counts.values()))
    check('natural_public_frontend_exit', process.returncode == 0)
    record['accepted'] = True
except Exception as failure:
    record['error'] = type(failure).__name__ + ': ' + str(failure)
finally:
    if reader is not None:
        reader.close()
    if peer is not None:
        peer.close()
    if process is not None:
        if process.poll() is None:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                record['forced_exit'] = True
                process.terminate()
                process.wait(timeout=5)
        for thread in threads:
            thread.join(timeout=2)
        record['exit'] = process.returncode
        record['stderr'] = b''.join(errors).decode(errors='replace')
    record['binary_sha256_after'] = hashlib.sha256(args.candidate.read_bytes()).hexdigest()
    record['accepted'] = (record.get('accepted') is True and record.get('exit') == 0 and not record.get('forced_exit')
                          and not record.get('error') and not record.get('stderr')
                          and record['binary_sha256'] == record['binary_sha256_after'])
    for name, value in [('private.sent.json', sent), ('private.received.json', frames), ('public.frames.json', public_frames), ('summary.json', record)]:
        (args.output / name).write_text(json.dumps(normalized(value), ensure_ascii=False, indent=2) + '\n')
print(json.dumps(normalized(record), ensure_ascii=False, indent=2))
raise SystemExit(0 if record['accepted'] else 1)
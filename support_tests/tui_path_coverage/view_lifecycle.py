#!/usr/bin/env python3
"""Real public View input, concurrent management, package updates and frontend lifetime."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import sqlite3
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description='Actual no-model public View and shared-owner lifecycle regression.')
for name in ('candidate', 'output'):
    parser.add_argument('--' + name, type=Path, required=True)
parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
args = parser.parse_args()
args.candidate = args.candidate.resolve(strict=True)
args.repo = ROOT
args.package = ROOT / 'support_tests/view_form_fixture'
args.output = args.output.resolve()


def normalized(value):
    if isinstance(value, str):
        for prefix, replacement in sorted([(str(args.output), '<evidence>'), (str(args.repo), '<repo>'),
                                            (str(Path.home()), '$HOME')], key=lambda item: -len(item[0])):
            value = value.replace(prefix, replacement)
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
    guarded = [Path(__file__), args.package / 'worker.py', args.package / 'axyndra.plugin.json',
               args.repo / 'support_tests/tui_path_coverage/check.py', Path(custody.__file__)]
    def source_hashes():
        return {path.relative_to(args.repo).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in guarded}
    before = source_hashes()
    binary_before = hashlib.sha256(args.candidate.read_bytes()).hexdigest()
    command = [sys.executable, str(Path(__file__)), '--worker',
               '--candidate', str(args.candidate), '--output', str(args.output / 'case')]
    result = custody.run_case(command, args.output / 'case.log', 20, cwd=args.repo)
    case_path = args.output / 'case/summary.json'
    case = json.loads(case_path.read_text()) if case_path.is_file() else {'accepted': False, 'error': 'Actual case report is missing'}
    after = source_hashes()
    binary_after = hashlib.sha256(args.candidate.read_bytes()).hexdigest()
    accepted = (case.get('accepted') is True and result.get('exit_code') == 0 and
                custody.process_custody_closed(result) and before == after and binary_before == binary_after)
    summary = normalized({'status': 'PASS' if accepted else 'FAIL', 'accepted': accepted,
                          'candidate_sha256': binary_before, 'candidate_sha256_after': binary_after,
                          'sources_before': before, 'sources_after': after,
                          'case': case, 'physical_custody': result})
    (args.output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    raise SystemExit(0 if accepted else 1)
args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
source = args.repo / 'support_tests/tui_path_coverage/check.py'
spec = importlib.util.spec_from_file_location('real_owner_repro_environment', source)
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
record = {'binary_sha256': hashlib.sha256(args.candidate.read_bytes()).hexdigest(),
          'scenario': 'Actual zero-Tool View stays open in RPC while a separate public plugin CLI uses the same canonical owner; no provider or execution facts.',
          'checks': {}}
seen, sent, raw, errors = [], [], [], []
incoming = queue.Queue()
process = None
readers = []


def cli(label, arguments):
    started = time.monotonic()
    result = subprocess.run(prefix + ['plugin', *arguments], cwd=workspace,
                            env=environment, capture_output=True, timeout=10)
    value = {'exit': result.returncode, 'seconds': time.monotonic() - started,
             'stdout': result.stdout.decode(errors='replace'),
             'stderr': result.stderr.decode(errors='replace')}
    record[label] = value
    return value


def read_frames():
    for line in iter(process.stdout.readline, b''):
        raw.append(line)
        try:
            incoming.put(json.loads(line))
        except Exception as error:
            incoming.put({'decode_error': str(error)})


def send(value):
    data = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode() + b'\n'
    sent.append(data)
    process.stdin.write(data)
    process.stdin.flush()


def until(predicate):
    deadline = time.monotonic() + 10
    while True:
        value = incoming.get(timeout=max(.001, deadline - time.monotonic()))
        seen.append(value)
        if 'decode_error' in value:
            raise ValueError(value['decode_error'])
        if predicate(value):
            return value


def completion(identity):
    return until(lambda value: value.get('type') == 'plugin_view_completed' and value.get('requestId') == identity)


def open_view(identity):
    send({'id': identity, 'type': 'plugin_view', 'routeName': 'plugin.axyndra:view_form.overview', 'input': {}})
    document = until(lambda value: value.get('type') == 'plugin_view_document' and value.get('requestId') == identity)['document']
    if not completion(identity)['success']:
        raise AssertionError('actual View open failed: ' + identity)
    return document


def action(document, identity, actual_fields=None, **changes):
    event = {'id': identity, 'type': 'plugin_view_action', 'viewId': document['metadata']['view_id'],
             'revision': '1', 'actionId': 'submit', 'fields': fields if actual_fields is None else actual_fields}
    event.update(changes)
    return event


def rejected(identity, event, check):
    start = len(seen)
    send(event)
    end = completion(identity)
    accepted = not end['success'] and not any('Native form checksum:' in value.get('output', '') for value in seen[start:])
    record['checks'][check] = accepted
    if not accepted:
        raise AssertionError('stale or malformed public event reached the Command: ' + check)


def usable(document, identity, check):
    start = len(seen)
    send(action(document, identity))
    accepted = completion(identity)['success'] and any(digest in value.get('output', '') for value in seen[start:])
    record['checks'][check] = accepted
    if not accepted:
        raise AssertionError('actual current Command unusable: ' + check)


def connect(protocol_id, profile_id):
    global process, readers
    process = subprocess.Popen(prefix + ['--mode', 'rpc'], cwd=workspace, env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    readers = [threading.Thread(target=read_frames, daemon=True),
               threading.Thread(target=lambda: errors.append(process.stderr.read()), daemon=True)]
    for reader in readers:
        reader.start()
    until(lambda value: value.get('type') == 'ready')
    for identity, request in [(protocol_id, {'type': 'negotiate_protocol', 'protocolVersion': 2}),
                              (profile_id, {'type': 'negotiate_interactions', 'profile': 'views-v1'})]:
        send(dict(request, id=identity))
        if not until(lambda value: value.get('id') == identity).get('success'):
            raise AssertionError('actual RPC negotiation refused')


try:
    for label, arguments in [('import', ['import', str(args.package), '--scope', 'user']),
                             ('enable', ['enable', 'axyndra:view_form', '--scope', 'user'])]:
        if cli(label, arguments)['exit'] != 0:
            raise ValueError('actual maintenance failed before concurrent case: ' + label)
    connect('protocol', 'profile')
    document = open_view('open')
    record['view_id'] = document['metadata']['view_id']
    concurrent = cli('concurrent_list', ['list', '--json'])
    record['checks']['management_returns_with_live_rpc'] = concurrent['exit'] == 0
    if concurrent['exit'] != 0:
        raise ValueError('public plugin list fails while the real View frontend stays open')
    namespace = [item['namespace'] for item in json.loads(concurrent['stdout'])]
    record['checks']['registry_still_current'] = namespace == ['axyndra:view_form']
    fields = {'list': 'a', 'table': 'r', 'input': 'after actual concurrent management 雪'}
    digest = hashlib.sha256(json.dumps(fields, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    event = {'type': 'plugin_view_action', 'viewId': record['view_id'], 'revision': '1', 'actionId': 'submit', 'fields': fields}
    send(dict(event, id='after-management'))
    record['checks']['rpc_still_usable'] = completion('after-management')['success'] and any(digest in value.get('output', '') for value in seen)
    send({'id': 'close', 'type': 'plugin_view_close', 'viewId': record['view_id']})
    record['checks']['explicit_close'] = until(lambda value: value.get('id') == 'close')['success']
    send(dict(event, id='late-after-close'))
    late = completion('late-after-close')
    record['checks']['late_event_rejected'] = not late['success'] and any(value.get('id') == 'late-after-close' and value.get('code') == 'view.closed' for value in seen)

    current = open_view('lifecycle-open')
    rejected('wrong-revision', action(current, 'wrong-revision', revision='2'), 'revision_rejected')
    rejected('wrong-action', action(current, 'wrong-action', actionId='undeclared'), 'undeclared_action_rejected')
    rejected('wrong-fields', action(current, 'wrong-fields', actual_fields=dict(fields, authority='approve')), 'forged_field_rejected')
    rejected('large-inline', action(current, 'large-inline', actual_fields=dict(fields, input='x' * 16385)), 'inline_limit_enforced')
    rejected('terminal-control', action(current, 'terminal-control', actual_fields=dict(fields, input='unsafe' + chr(27) + '[2J')), 'terminal_controls_rejected')
    rejected('wrong-selection', action(current, 'wrong-selection', actual_fields=dict(fields, list='nonexistent-selection')), 'selection_membership_enforced')
    usable(current, 'after-invalid-events', 'invalid_events_do_not_consume_current_view')
    replacement = open_view('replace-current')
    rejected('replaced-event', action(current, 'replaced-event'), 'replaced_view_rejected')
    usable(replacement, 'replacement-command', 'replacement_usable')
    if cli('disable-live', ['disable', 'axyndra:view_form', '--scope', 'user'])['exit'] != 0:
        raise AssertionError('actual disable failed with another live frontend')
    rejected('disabled-event', action(replacement, 'disabled-event'), 'disabled_generation_rejected')
    send({'id': 'open-disabled', 'type': 'plugin_view', 'routeName': 'plugin.axyndra:view_form.overview', 'input': {}})
    record['checks']['disabled_route_unavailable'] = not completion('open-disabled')['success']
    if cli('reenable-live', ['enable', 'axyndra:view_form', '--scope', 'user'])['exit'] != 0:
        raise AssertionError('actual enable failed with another live frontend')
    reenabled = open_view('open-reenabled')
    record['checks']['reenable_has_new_generation'] = reenabled['metadata']['generation'] != replacement['metadata']['generation']
    rejected('late-after-enable', action(replacement, 'late-after-enable'), 'old_generation_stays_rejected')
    usable(reenabled, 'after-reenable', 'reenabled_command_usable')
    invalid_package = args.output / 'invalid-package'
    shutil.copytree(args.package, invalid_package)
    manifest = json.loads((invalid_package / 'axyndra.plugin.json').read_text())
    manifest.update(version='1.0.3', entrypoint='../outside')
    (invalid_package / 'axyndra.plugin.json').write_text(json.dumps(manifest))
    rejected_update = cli('invalid-update', ['update', 'axyndra:view_form', str(invalid_package), '--scope', 'user'])
    record['checks']['invalid_update_rejected'] = rejected_update['exit'] != 0
    usable(reenabled, 'after-invalid-update', 'failed_update_preserves_current_view')
    update_package = args.output / 'updated-package'
    shutil.copytree(args.package, update_package)
    manifest['entrypoint'] = 'worker.py'
    (update_package / 'axyndra.plugin.json').write_text(json.dumps(manifest))
    if cli('valid-update', ['update', 'axyndra:view_form', str(update_package), '--scope', 'user'])['exit'] != 0:
        raise AssertionError('actual valid snapshot update failed')
    rejected('late-after-update', action(reenabled, 'late-after-update'), 'updated_snapshot_rejects_old_event')
    installed = cli('updated-record', ['list', '--json'])
    if installed['exit'] != 0:
        raise AssertionError('actual updated registry unavailable')
    if not json.loads(installed['stdout'])[0]['enabled']:
        if cli('enable-updated', ['enable', 'axyndra:view_form', '--scope', 'user'])['exit'] != 0:
            raise AssertionError('explicit enable of updated snapshot failed')
    updated = open_view('open-updated')
    record['checks']['new_snapshot_digest'] = updated['metadata']['package_digest'] != reenabled['metadata']['package_digest']
    usable(updated, 'updated-command', 'updated_command_usable')
    process.stdin.close()
    process.wait(timeout=6)
    for reader in readers:
        reader.join(timeout=1)
    record['first_rpc_exit'] = process.returncode
    record['checks']['disconnect_returns'] = process.returncode == 0
    connect('protocol-reconnect', 'profile-reconnect')
    rejected('late-after-disconnect', action(updated, 'late-after-disconnect'), 'disconnected_view_has_no_authority')
    reconnected = open_view('open-reconnected')
    record['checks']['new_frontend_identity'] = reconnected['metadata']['view_id'] != updated['metadata']['view_id']
    usable(reconnected, 'reconnected-command', 'reconnected_command_usable')
    database = sqlite3.connect(home / 'sessions/state.db')
    try:
        counts = {table: database.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0]
                  for table in ('operations', 'operation_receipts', 'model_attempts', 'approvals')}
        counts['user_messages'] = database.execute("SELECT COUNT(*) FROM items WHERE kind='user_message'").fetchone()[0]
        record['canonical_facts'] = counts
        record['checks']['no_execution_authority'] = all(value == 0 for value in counts.values())
    finally:
        database.close()
except Exception as error:
    record['error'] = type(error).__name__ + ': ' + str(error)
finally:
    if process is not None:
        process.stdin.close()
        try:
            process.wait(timeout=6)
        except subprocess.TimeoutExpired:
            record['forced_frontend_exit'] = True
            process.terminate()
            process.wait(timeout=3)
        for reader in readers:
            reader.join(timeout=1)
        record['rpc_exit'] = process.returncode
        record['rpc_stderr'] = b''.join(errors).decode(errors='replace')
    (args.output / 'rpc.requests.jsonl').write_bytes(b''.join(sent))
    (args.output / 'rpc.output.jsonl').write_bytes(b''.join(raw))
    expected = {
        'management_returns_with_live_rpc', 'registry_still_current', 'rpc_still_usable',
        'explicit_close', 'late_event_rejected', 'revision_rejected', 'undeclared_action_rejected',
        'forged_field_rejected', 'inline_limit_enforced', 'terminal_controls_rejected',
        'selection_membership_enforced', 'invalid_events_do_not_consume_current_view',
        'replaced_view_rejected', 'replacement_usable', 'disabled_generation_rejected',
        'disabled_route_unavailable', 'reenable_has_new_generation', 'old_generation_stays_rejected',
        'reenabled_command_usable', 'invalid_update_rejected', 'failed_update_preserves_current_view',
        'updated_snapshot_rejects_old_event', 'new_snapshot_digest', 'updated_command_usable',
        'disconnect_returns', 'disconnected_view_has_no_authority', 'new_frontend_identity',
        'reconnected_command_usable', 'no_execution_authority',
    }
    record['accepted'] = (set(record['checks']) == expected and all(record['checks'].values())
                          and record.get('rpc_exit') == 0 and not record.get('forced_frontend_exit')
                          and not record.get('error'))
    record = normalized(record)
    (args.output / 'summary.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(record, ensure_ascii=False, indent=2))
raise SystemExit(0 if record['accepted'] else 1)

#!/usr/bin/env python3
"""Public Codex import/activation -> readonly command hooks -> actual Pi TS Tool.

The candidate and native ModelProviders distribution are built outside this
harness. No fixture engine, forged Registry record, or implicit grant is used.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import threading
import time
from rpc_client import RpcClient

TOOL = 'plugin.pi:pi-pinned-hello.hello'
MODIFIED = 'A7 actual Codex hook'


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def package_files(root):
    return {path.relative_to(root).as_posix(): sha256(path)
            for path in sorted(root.rglob('*')) if path.is_file()}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def fixtures(repo, evidence):
    codex, pi = evidence / 'codex-hooks', evidence / 'pi-hello'
    write_json(codex / 'plugin.json', {
        '$schema': 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json',
        'name': 'a7-hooks', 'version': '1.0.0',
        'extensions': {'com.openai': {'hooks': './hooks/hooks.json'},
                       'axyndra': {'capabilities': ['workspace.write']}}})
    write_json(codex / 'hooks/hooks.json', {'hooks': {
        event: [{'matcher': TOOL, 'hooks': [{'type': 'command',
            'command': '/usr/bin/python3 ' + script, 'timeout': 2}]}]
        for event, script in [('PreToolUse', 'a7_pre.py'), ('PostToolUse', 'a7_post.py')]}})
    common = """import json, pathlib, sys, time
v=json.load(sys.stdin)
assert v['plugin_id']=='codex:a7-hooks' and v['plugin_version']=='1.0.0'
assert v['thread_id'] and v['run_id'] and v['call_id'] and v['epoch']>=1
assert v['tool_name']=='plugin.pi:pi-pinned-hello.hello'
assert pathlib.Path('plugin.json').is_file()
try:
 pathlib.Path('not-authorized-write').write_text('must not be writable')
except OSError: pass
else: raise AssertionError('Codex hook package filesystem was not readonly')
"""
    (codex / 'a7_pre.py').write_text(common +
        "assert v['event_name']=='PreToolUse'\n"
        "print(json.dumps({'decision':'modify','arguments':{'name':'A7 actual Codex hook'}}))\n"
        "time.sleep(.2)\n", encoding='utf-8')
    (codex / 'a7_post.py').write_text(common +
        "assert v['event_name']=='PostToolUse' and v['operation_id'] and v['receipt_id']\n"
        "assert v['outcome']=='completed'\n"
        "assert 'A7 actual Codex hook' in json.dumps(v['result'])\n"
        "time.sleep(.2)\n", encoding='utf-8')
    write_json(pi / 'package.json', {'name': 'pi-pinned-hello', 'version': '0.87.1',
        'type': 'module', 'pi': {'extensions': ['hello.ts']}})
    upstream = repo / 'support_tests/extension_runtime_contract/fixtures/upstream_pi_v0_87_1/hello.ts'
    (pi / 'hello.ts').write_bytes(upstream.read_bytes())
    return codex, pi


def descendants(root):
    pending, seen = [root], set()
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        try:
            proc = Path('/proc') / str(pid)
            yield pid, (proc / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            for task in (proc / 'task').iterdir():
                pending.extend(int(child) for child in (task / 'children').read_text().split())
        except (OSError, ValueError):
            continue


def refused_imports(case, codex):
    # Inspection/import must not publish or normalize invalid/unknown requests.
    from owned_process import owned_process
    import subprocess
    lock = case.home / 'plugins/lock.jsonl'
    original = lock.read_bytes()
    cases = [
        ('overlay-null', None, 'plugin.codex_overlay_invalid'),
        ('unknown-grant', {'grant': ['workspace.write']}, 'plugin.codex_overlay_invalid'),
        ('unknown-version', {'capabilities': [], 'schema_version': 2}, 'plugin.codex_overlay_invalid'),
        ('invalid-null', {'capabilities': None}, 'plugin.capability_list_invalid'),
        ('invalid-string', {'capabilities': 'workspace.read'}, 'plugin.capability_list_invalid'),
        ('invalid-item', {'capabilities': [True]}, 'plugin.capability_list_invalid'),
        ('unsupported-process', {'capabilities': ['process.spawn']}, 'plugin.capability_unsupported'),
        ('unsupported-network', {'capabilities': ['network.access:example.test']}, 'plugin.capability_unsupported'),
        ('unsupported-host', {'capabilities': ['host.network']}, 'plugin.capability_unsupported'),
        ('too-many', {'capabilities': ['workspace.read'] * 17}, 'plugin.capability_list_invalid'),
    ]
    for name, overlay, diagnostic in cases:
        package = case.case_dir / 'invalid-request-packages' / name
        value = json.loads((codex / 'plugin.json').read_bytes())
        value['extensions']['axyndra'] = overlay
        write_json(package / 'plugin.json', value)
        before = (package / 'plugin.json').read_bytes()
        for operation in ('inspect', 'import'):
            command = [str(case.candidate), '--cwd', str(case.workspace),
                       'plugin', operation, str(package)]
            with owned_process(command, cwd=case.workspace, env=case.environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE) as process:
                output, error = process.communicate(timeout=case.timeout)
            text = (output + error).decode('utf-8')
            (case.case_dir / (name + '-' + operation + '.log')).write_text(
                RpcClient.normalize(text), encoding='utf-8')
            assert process.returncode != 0 and diagnostic in text, (name, operation, text)
            assert lock.read_bytes() == original
            assert (package / 'plugin.json').read_bytes() == before
    case.record('unknown_invalid_requests_refused_before_publication', cases=len(cases))


def run(args):
    repo = args.repo.resolve()
    sys.path.insert(0, str(repo / 'support_tests/tui_path_coverage'))
    import check as tui
    import plugin_acceptance
    from workflow_family_fixture196 import _run196, _records196
    specification = importlib.util.spec_from_file_location('canonical_store_codec',
        repo / 'support_tests/plugin_cli_blackbox/check.py')
    codec = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(codec)
    case = tui.CaseRun({'case_id': 'public-codex-readonly-hooks',
                       'variant': {'execution': 'ecosystem-hooks'}}, args.app.resolve(), args.evidence.resolve())
    library = args.native_library.resolve()
    assert library.is_file()
    case.environment['LD_LIBRARY_PATH'] = str(library.parent) + ':' + case.environment['LD_LIBRARY_PATH']
    codex, pi = fixtures(repo, case.case_dir)
    immutable = {'codex': package_files(codex), 'pi': package_files(pi)}
    observed, stop, watcher = [], threading.Event(), None
    summary = {'app_sha256': sha256(args.app), 'native_sha256': sha256(library),
               'fixture_files': immutable, 'model_distribution_files': package_files(args.model_package)}
    try:
        wire_tool = hashlib.sha256(TOOL.encode()).hexdigest()
        # Real Responses terminal Tool arguments; no synthetic arguments delta.
        port = case.start_provider({'responses': [
            {'kind': 'tool', 'tool_name': wire_tool, 'tool_arguments': {'name': 'unmodified raw input'}},
            {'kind': 'text', 'chunks': ['actual-hook-final-result'], 'event_delay': .03}]})
        plugin_acceptance.configure(case, args.model_package, port, 'responses', 8000)
        _run196(case, 'codex-inspect', ['inspect', str(codex)])
        _run196(case, 'codex-import', ['import', str(codex)])
        record = next(row for row in _records196(case, 'static-records') if row['namespace'] == 'codex:a7-hooks')
        assert record['enabled'] is False
        assert not tui.read_jsonl(case.requests_path)
        database = case.home / 'sessions/state.db'
        with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as connection:
            assert connection.execute('SELECT COUNT(*) FROM operations').fetchone()[0] == 0
        refused_imports(case, codex)
        _run196(case, 'codex-enable', ['enable', 'codex:a7-hooks'])
        _run196(case, 'pi-import', ['import', str(pi)])
        _run196(case, 'pi-enable', ['enable', 'pi:pi-pinned-hello'])
        argv = [str(case.candidate), '--cwd', str(case.workspace), '--approval-mode', 'trusted', '--mode', 'rpc']
        case.record('execution_identity', argv=argv, app_sha256=summary['app_sha256'], native_sha256=summary['native_sha256'])
        with RpcClient(argv, workspace=case.workspace, environment=case.environment,
                       evidence=case.case_dir, label='actual-codex-core') as rpc:
            def monitor():
                while not stop.wait(.01):
                    for pid, command in descendants(rpc.process.pid):
                        if 'a7_pre.py' in command or 'a7_post.py' in command:
                            entry = {'pid': pid, 'command': RpcClient.normalize(command)}
                            if entry not in observed:
                                observed.append(entry)
            watcher = threading.Thread(target=monitor, daemon=True); watcher.start()
            identifier, accepted = rpc.request('prompt', message='Exercise supported Codex command hooks and upstream Pi Tool.')
            assert accepted['success'], accepted
            result = rpc.wait(lambda frame: frame.get('id') == identifier and (
                frame.get('type') == 'prompt_result' or frame.get('type') == 'response' and frame.get('success') is False))
            assert result.get('agentInvoked') is True, result
            _, messages = rpc.request('get_messages')
            assert messages['success'] and 'actual-hook-final-result' in json.dumps(messages), messages
        stop.set(); watcher.join(2)
        requests = tui.read_jsonl(case.requests_path)
        assert len(requests) == 2
        assert any(tool.get('name') == wire_tool for tool in requests[0]['request']['tools'])
        assert MODIFIED in json.dumps(requests[-1]), requests[-1]
        assert any('a7_pre.py' in entry['command'] for entry in observed), observed
        assert any('a7_post.py' in entry['command'] for entry in observed), observed
        with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as connection:
            rows = connection.execute('SELECT o.id,o.normalized_plan,r.id,r.outcome,r.detail '
                'FROM operations o JOIN operation_receipts r ON r.operation_id=o.id').fetchall()
            assert len(rows) == 1, rows
            operation, encoded, receipt, outcome, detail = rows[0]
            plan = codec.stored_value(encoded)
            assert plan['tool'] == TOOL and plan['arguments'] == {'name': MODIFIED}, plan
            assert outcome == 'completed' and MODIFIED in json.dumps(codec.stored_value(detail))
            assert connection.execute("SELECT COUNT(*) FROM items WHERE kind='tool_result'").fetchone()[0] == 1
            assert not connection.execute('PRAGMA foreign_key_check').fetchall()
        assert immutable == {'codex': package_files(codex), 'pi': package_files(pi)}
        assert not (codex / 'not-authorized-write').exists()
        summary.update(status='PASS', provider_requests=2, operation_id=operation,
                       receipt_id=receipt, normalized_plan=plan, hook_processes=observed,
                       static_import_disabled=True, static_import_operations=0)
        print('PASS public Codex readonly Pre/Post, actual Pi TS Tool, canonical receipt and real HTTP Core roundtrip')
    except BaseException as error:
        summary.update(status='FAIL', error=RpcClient.normalize(str(error)), hook_processes=observed)
        raise
    finally:
        stop.set()
        if watcher is not None:
            watcher.join(2)
        write_json(case.case_dir / 'summary.json', summary)
        case.stop()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repo', 'app', 'native-library', 'model-package', 'evidence'):
        parser.add_argument('--' + name, type=Path, required=True)
    run(parser.parse_args())

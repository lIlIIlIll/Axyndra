#!/usr/bin/env python3
"""Real relocated Minimal CLI matrix with empty PATH and isolated network.

No compiler, simulated model, Python Store writes or fabricated Root/Source.
The original Minimal gates stay independent. Requires Linux/bwrap and a real
packaged Minimal binary, supplied only as an execution input.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree(root):
    return {p.relative_to(root).as_posix(): digest(p) for p in sorted(root.rglob('*')) if p.is_file()}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--bwrap', type=Path, required=True)
    p.add_argument('--work-root', type=Path, required=True)
    a = p.parse_args()
    assert os.name == 'posix' and Path('/proc').is_dir()
    binary, bwrap = a.binary.resolve(strict=True), a.bwrap.resolve(strict=True)
    assert binary.name == 'axyndra' and binary.parent.name == 'bin'
    assert os.access(binary, os.X_OK) and os.access(bwrap, os.X_OK)
    package = binary.parent.parent
    provenance = json.loads((package / 'package-provenance.json').read_bytes())
    distribution = json.loads((package / 'share/axyndra/distribution.json').read_bytes())
    assert provenance['distribution'] == 'minimal' and provenance['expected_host_package'] == 'agent_minimal'
    assert provenance['bundled'] == provenance['default_enabled'] == provenance['core_required'] == []
    assert distribution == dict(schema='axyndra.distribution/v1', id='minimal', plugins=[], context=None)
    assert digest(binary) == provenance['packaged_binary_sha256']
    package_before = tree(package)
    helper = Path(__file__).resolve().parents[1] / 'minimal_host_contract/check.py'
    spec = importlib.util.spec_from_file_location('a7_original_minimal_observer', helper)
    original = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(original)
    root = a.work_root.resolve()
    assert not root.exists()
    root.mkdir(parents=True, mode=0o700)
    for name in ['home', 'workspace', 'empty-path', 'runtime', 'tmp', 'config', 'cache']:
        (root / name).mkdir(mode=0o700)
    settings, state = root / 'settings', root / 'state'
    env = dict(PATH=str(root / 'empty-path'), HOME=str(root / 'home'), LANG='C.UTF-8',
               XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
               XDG_STATE_HOME=str(state), XDG_RUNTIME_DIR=str(root / 'runtime'),
               TMPDIR=str(root / 'tmp'), PYTHONDONTWRITEBYTECODE='1')
    assert not any(shutil.which(name, path=env['PATH']) for name in ['node', 'bun', 'cjc', 'cjpm'])
    assert not (settings / 'plugins').exists()
    assert not any(k in env for k in ['LD_LIBRARY_PATH', 'CANGJIE_HOME', 'HTTP_PROXY', 'HTTPS_PROXY',
                                    'ALL_PROXY', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY'])
    host_net = os.readlink('/proc/self/ns/net')
    witness_program = ("import json,os,socket,sys; "
        "print('A7_OFFLINE_WITNESS='+json.dumps(dict(namespace=os.readlink('/proc/self/ns/net'),"
        "interfaces=[n for _,n in socket.if_nameindex()],routes=max(0,len(open('/proc/net/route').read().splitlines())-1))),flush=True); "
        "os.execve(sys.argv[1],sys.argv[1:],dict(os.environ))")
    records, completed = [], []
    base = ['--settings-root', str(settings), '--workspace-root', str(root / 'workspace')]

    def call(arguments, *, runtime=False, bare=False, code=0, as_json=True):
        argv = [str(binary), *([] if bare else base)]
        if runtime:
            argv += ['--state-root', str(state)]
        argv += list(arguments)
        # Real network namespace; no fallback when isolation is unavailable.
        command = [str(bwrap), '--die-with-parent', '--unshare-user', '--disable-userns',
                   '--unshare-net', '--ro-bind', '/', '/',
                   '--proc', '/proc', '--dev', '/dev', '--bind', str(root), str(root),
                   '--chdir', str(root / 'workspace'), '--', sys.executable, '-I', '-B',
                   '-c', witness_program, *argv]
        child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, encoding='utf-8', start_new_session=True)
        observed, stop = {}, threading.Event()

        def observe():
            while not stop.is_set():
                table = original.process_table()
                owned = {child.pid}
                changed = True
                while changed:
                    changed = False
                    for pid, (parent, birth, status) in table.items():
                        if parent in owned and pid not in owned:
                            owned.add(pid); changed = True
                for pid in owned:
                    if pid in table:
                        observed[pid] = table[pid][1]
                stop.wait(0.005)

        worker = threading.Thread(target=observe, daemon=True)
        worker.start()
        try:
            stdout, stderr = child.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate()
            raise
        finally:
            stop.set(); worker.join(timeout=5)
            survivors = []
            for pid, birth in observed.items():
                current = original.process_table().get(pid)
                if current and current[1] == birth and current[2] != 'Z':
                    survivors.append(pid)
                    os.kill(pid, signal.SIGKILL)
            assert not survivors, survivors
        first, separator, remainder = stdout.partition('\n')
        assert separator and first.startswith('A7_OFFLINE_WITNESS='), (child.returncode, stderr)
        witness = json.loads(first.split('=', 1)[1])
        assert witness['namespace'] != host_net and witness['interfaces'] == ['lo'] and witness['routes'] == 0, witness
        assert child.returncode == code, (argv, child.returncode, remainder, stderr)
        records.append(dict(arguments=arguments, exit_code=child.returncode,
                            offline_witness=witness, observed_processes=len(observed)))
        return json.loads(remainder) if as_json else remainder

    help_text = call(['--help'], bare=True, as_json=False)
    assert 'plugin list' in help_text and 'history latest' in help_text and 'infer' in help_text
    completed.append('empty-help-no-node-no-network-no-credentials')
    assert call(['plugin', 'list']) == dict(ok=True, records=[])
    assert call(['plugin', 'doctor']) == dict(ok=True, diagnostics=[])
    assert call(['plugin', 'gc']) == dict(ok=True, deleted=[])
    completed.append('empty-real-management')
    assert call(['tools', 'offline-thread'], runtime=True)['tools'] == []
    missing = call(['invoke', 'offline-thread', 'missing.tool', '{}'], runtime=True, code=2)
    assert missing['ok'] is False and missing['run_id']
    db = state / 'state.db'

    def rows(query, arguments=()):
        with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as connection:
            connection.execute('PRAGMA query_only=ON')
            return connection.execute(query, arguments).fetchall()

    assert rows('SELECT state FROM runs WHERE id=?', (missing['run_id'],)) == [('failed',)]
    assert rows('SELECT COUNT(*) FROM operations WHERE run_id=?', (missing['run_id'],)) == [(0,)]
    assert rows('SELECT kind FROM items WHERE turn_id=(SELECT turn_id FROM runs WHERE id=?)',
                (missing['run_id'],)) == [('user_message',)]
    completed.append('real-failed-root-without-fabricated-tool-admission')
    before = {name: rows('SELECT COUNT(*) FROM ' + name) for name in
              ['runs', 'operations', 'operation_receipts', 'model_attempts', 'model_decisions', 'decision_operations']}
    model = call(['infer', 'offline-model-thread', 'axyndra:no-model', 'missing', 'not-installed', 'offline prompt'], runtime=True, code=2)
    assert model['ok'] is False and model['code'] == 'model.provider_plugin_missing'
    assert {name: rows('SELECT COUNT(*) FROM ' + name) for name in before} == before
    assert all(before[name] == [(0,)] for name in ['model_attempts', 'model_decisions', 'decision_operations'])
    completed.append('typed-missing-model-no-request-or-operation')
    db_before, run_before = digest(db), rows('SELECT * FROM runs ORDER BY id')
    assert call(['history', 'latest', str(db), 'offline-thread'], bare=True)['run_id'] == missing['run_id']
    history = call(['history', 'inspect', str(db), 'offline-thread', missing['run_id']], bare=True)
    assert history['ok'] and history['inspection']['run_id'] == missing['run_id']
    assert history['inspection']['run_state'] == 'failed' and history['inspection']['operations'] == []
    assert digest(db) == db_before and rows('SELECT * FROM runs ORDER BY id') == run_before
    absent = root / 'absent-parent' / 'missing.db'
    assert call(['history', 'latest', str(absent), 'offline-thread'], bare=True, code=2)['ok'] is False
    assert not absent.parent.exists()
    completed.append('actual-history-readonly-and-missing-db-no-create')

    def package_input(version):
        destination = root / ('package-' + version)
        destination.mkdir()
        (destination / 'package.json').write_text(json.dumps(dict(name='a7-offline-managed', version=version,
            pi=dict(extensions=['index.js']))))
        (destination / 'index.js').write_text("throw new Error('A7 management must never execute package code');\n")
        return destination

    first, second = package_input('1.0.0'), package_input('2.0.0')
    inspect = call(['plugin', 'inspect', str(first)])
    installed = call(['plugin', 'install', str(first), 'user'])['record']
    assert not installed['enabled'] and installed['content_digest'] == inspect['content_digest']
    namespace = installed['namespace']
    assert call(['plugin', 'enable', namespace, 'user'])['record']['enabled']
    updated = call(['plugin', 'update', namespace, str(second), 'user'])['record']
    assert updated['version'] == '2.0.0' and updated['content_digest'] != installed['content_digest']
    assert call(['plugin', 'rollback', namespace, 'user'])['record']['content_digest'] == installed['content_digest']
    assert not call(['plugin', 'disable', namespace, 'user'])['record']['enabled']
    assert call(['plugin', 'doctor']) == dict(ok=True, diagnostics=[])
    assert call(['plugin', 'uninstall', namespace, 'user'])['ok']
    assert call(['plugin', 'list']) == dict(ok=True, records=[])
    assert call(['plugin', 'gc']) == dict(ok=True, deleted=[])
    assert Path(installed['root']).is_dir() and Path(updated['root']).is_dir()
    completed.append('local-install-update-rollback-disable-uninstall-no-runtime')
    assert call(['tools', 'after-uninstall'], runtime=True)['tools'] == []
    assert call(['infer', 'after-uninstall', 'axyndra:no-model', 'missing', 'not-installed', 'offline prompt'], runtime=True, code=2)['code'] == 'model.provider_plugin_missing'
    assert tree(package) == package_before
    assert not list((root / 'empty-path').iterdir())
    assert len(completed) == 6
    (root / 'summary.json').write_text(json.dumps(dict(status='PASS',cases_completed=6,
        cases=completed,commands=records,binary_sha256=digest(binary),package_unchanged=True,
        no_node_bun_on_actual_cli_path=True,actual_network_namespace_denied=True,
        python_database_writes=0,compiled_inputs=0,scope='Additional A7 CLI matrix only; no contribution execution/bootstrap/CodingFull acceptance claim.'),indent=2)+'\n')
    print('Minimal empty/offline CLI matrix passed: 6 actual cases')


if __name__ == '__main__':
    main()

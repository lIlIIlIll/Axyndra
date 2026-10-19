#!/usr/bin/env python3
"""Actual packaged App defaults -> Application -> same-Run ContextRead/SQLite.

No build or test-only import/config writer: --app must be the real Coding
package produced by package_candidate.sh, including its neighboring manifest.
The model is the existing explicit --fixture backend; the native Skills
provider, registry, reads, policy and database are real.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile


def run(app, args, workspace, environment, log):
    with log.open('wb') as output:
        process = subprocess.Popen([str(app), *args], cwd=workspace, env=environment,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            raise


def check(app, evidence):
    app = app.resolve(strict=True)
    bundle = app.parent.parent / 'share/axyndra'
    manifest = bundle / 'distribution.json'
    assert manifest.is_file(), 'actual Coding package manifest required'
    package_before = hashlib.sha256(app.read_bytes()).hexdigest()
    manifest_before = manifest.read_bytes()
    environment = os.environ.copy()
    environment.pop('LD_LIBRARY_PATH', None)
    with tempfile.TemporaryDirectory(prefix='axyndra-coding-') as temporary:
        root = Path(temporary)
        settings = root / 'settings'
        environment['AXYNDRA_HOME'] = str(settings)
        for name in ['first', 'second']:
            path = root / name / '.omp/skills/review'
            path.mkdir(parents=True)
            (path / 'SKILL.md').write_text(
                f'---\nname: review\ndescription: Review a change\n---\nCODING-{name.upper()}-BODY\n')
        arguments = ['--fixture', '--approval-mode', 'trusted', '--mode', 'json', '$review']
        first = root / 'first'
        assert run(app, arguments, first, environment, evidence / 'first.log') == 0
        configuration = settings / 'plugins/context.json'
        assert configuration.is_file()
        original = configuration.read_bytes()
        parsed = json.loads(original)
        assert parsed['version'] == 4 and parsed['namespace'] == 'axyndra:skills'
        assert '${workspace_root}' in original.decode()
        database = settings / 'sessions/fixture/state.db'
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
            first_snapshot = db.execute('SELECT skill_snapshot FROM runs ORDER BY rowid DESC LIMIT 1').fetchone()[0]
            assert 'CODING-FIRST-BODY' in first_snapshot
            assert db.execute("SELECT COUNT(DISTINCT run_id) FROM operations").fetchone()[0] == 1
            assert db.execute("SELECT COUNT(*) FROM operation_effect_records e JOIN operation_receipts r ON r.operation_id=e.operation_id WHERE e.tool_id='host.context.read' AND r.outcome='completed'").fetchone()[0] >= 2
            assert db.execute("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'").fetchone()[0] == 1
        assert run(app, arguments, root / 'second', environment, evidence / 'second.log') == 0
        assert configuration.read_bytes() == original
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
            second_snapshot = db.execute('SELECT skill_snapshot FROM runs ORDER BY rowid DESC LIMIT 1').fetchone()[0]
            assert 'CODING-SECOND-BODY' in second_snapshot and 'CODING-FIRST-BODY' not in second_snapshot
            before_model = db.execute('SELECT COUNT(*) FROM model_attempts').fetchone()[0]
        assert run(app, ['plugin', 'disable', 'axyndra:skills'], first, environment, evidence / 'disable.log') == 0
        assert run(app, arguments, first, environment, evidence / 'disabled-request.log') != 0
        assert configuration.read_bytes() == original
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
            assert db.execute('SELECT COUNT(*) FROM model_attempts').fetchone()[0] == before_model
            assert db.execute("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')").fetchone()[0] == 0
    assert hashlib.sha256(app.read_bytes()).hexdigest() == package_before
    assert manifest.read_bytes() == manifest_before
    return {'status': 'PASS', 'app_sha256': package_before,
            'checks': ['default-native-install', 'canonical-reads-before-model',
                       'actual-workspace-rebind', 'explicit-disable-no-legacy-fallback']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    options = parser.parse_args()
    options.evidence.mkdir(parents=True, exist_ok=False)
    summary = {'status': 'FAIL'}
    try:
        summary = check(options.app, options.evidence)
        print('Coding distribution actual App contract passed')
    finally:
        (options.evidence / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')

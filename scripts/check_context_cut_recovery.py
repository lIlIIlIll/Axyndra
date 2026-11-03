#!/usr/bin/env python3
"""Real SIGKILL/reopen probe; requires the genuinely built current Core contract.

This helper never builds or rewrites the source, seeds a Root/Receipt, or raises
the original process deadlines. The caller must supply fresh build provenance.
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
import time


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def snapshot(db):
    with sqlite3.connect(db, timeout=5) as connection:
        return {
            'old_attempt': connection.execute("SELECT * FROM model_attempts WHERE semantic_request_id='semantic-cut-recovery-run-model-1'").fetchall(),
            'old_receipts': connection.execute('SELECT * FROM operation_receipts ORDER BY id').fetchall(),
            'old_tool_items': connection.execute("SELECT * FROM items WHERE kind IN ('tool_call','tool_result') ORDER BY ordinal").fetchall(),
            'old_manifest': connection.execute("SELECT * FROM context_manifests WHERE id='context-cut-cut-recovery-run-request-1'").fetchall(),
            'run': connection.execute("SELECT state,epoch,skill_snapshot,lane_snapshot FROM runs WHERE id='cut-recovery-run'").fetchone(),
            'boundary_phase': connection.execute("SELECT phase FROM run_continuations WHERE run_id='cut-recovery-run'").fetchone(),
        }


def drain(child):
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGKILL)
    child.wait(timeout=5)
    # A killed parked worker has no forked children. Reject a surviving group,
    # rather than treating child wait() as physical cleanup acknowledgement.
    try:
        os.killpg(child.pid, 0)
    except ProcessLookupError:
        return
    raise AssertionError('owned crash process group survived SIGKILL')


def case(binary, root, phase, mode='resume'):
    owned = root / (phase + '-' + mode)
    owned.mkdir()
    db = owned / 'cut.db'
    marker = owned / 'committed.marker'
    command = [str(binary), '--context-cut-recovery-worker', 'start', phase, str(db), str(marker)]
    with (owned / 'start.log').open('wb') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 60
            while not marker.is_file():
                assert child.poll() is None, 'actual Core exited before the selected committed barrier'
                assert time.monotonic() < deadline, 'original 60 second crash-process deadline'
                time.sleep(.01)
            assert marker.read_text() == phase
            before = snapshot(db)
            assert before['run'][0] == 'running' and len(before['old_attempt']) == len(before['old_receipts']) == 1
            assert before['boundary_phase'][0] == ('context_ready' if phase == 'after_context_ready' else 'context_compiling')
            drain(child)
        finally:
            if child.poll() is None:
                drain(child)
    # The old process is physically dead before a different process opens WAL.
    if mode == 'tampered':
        with sqlite3.connect(db) as connection:
            connection.execute("UPDATE run_continuations SET digest=? WHERE run_id='cut-recovery-run'", ('0' * 64,))
    resumed = subprocess.run([str(binary), '--context-cut-recovery-worker', mode, phase, str(db), str(marker)],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    (owned / 'reopen.log').write_bytes(resumed.stdout)
    assert resumed.returncode == 0, resumed.stdout.decode(errors='replace')
    witness = b'Context boundary physical reopen passed: ' if mode == 'resume' else b'Context boundary negative reopen passed'
    assert witness in resumed.stdout, 'actual whole Core/SQLite assertion witness'
    after = snapshot(db)
    for key in ('old_attempt', 'old_receipts', 'old_tool_items', 'old_manifest'):
        assert after[key] == before[key], 'immutable canonical old facts: ' + key
    if mode == 'resume':
        assert after['run'][0] == 'completed'
        with sqlite3.connect(db) as connection:
            assert connection.execute('SELECT COUNT(*) FROM model_attempts').fetchone()[0] == 2
            assert connection.execute("SELECT COUNT(*) FROM model_attempts WHERE semantic_request_id='semantic-cut-recovery-run-model-2' AND attempt_no=1 AND dispatch_state='dispatch_claimed'").fetchone()[0] == 1
            if phase in ('after_canonical_input', 'after_context_ready'):
                assert connection.execute("SELECT COUNT(*) FROM items WHERE id='interaction-recovery-canonical-input'").fetchone()[0] == 1
    return {'phase': phase, 'mode': mode, 'start_log_sha256': sha(owned / 'start.log'),
            'reopen_log_sha256': sha(owned / 'reopen.log'), 'original_facts_unchanged': True}



def concurrent_single_winner(binary, root):
    owned = root / 'concurrent-single-winner'
    owned.mkdir()
    db = owned / 'cut.db'
    marker = owned / 'committed.marker'
    with (owned / 'start.log').open('wb') as log:
        start = subprocess.Popen([str(binary), '--context-cut-recovery-worker', 'start', 'after_turn_reserved', str(db), str(marker)],
                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 60
            while not marker.is_file():
                assert start.poll() is None, 'actual Core exits only after committed barrier'
                assert time.monotonic() < deadline, 'original sixty-second process deadline'
                time.sleep(.01)
            before = snapshot(db)
            assert len(before['old_attempt']) == len(before['old_receipts']) == 1
            drain(start)
        finally:
            if start.poll() is None:
                drain(start)
    children = []
    logs = []
    deadline = time.monotonic() + 60
    try:
        for name in ('a', 'b'):
            log = (owned / ('race-' + name + '.log')).open('wb')
            logs.append(log)
            ready = owned / ('race-' + name + '.ready')
            child = subprocess.Popen([str(binary), '--context-cut-recovery-worker', 'concurrent', 'after_turn_reserved', str(db), str(ready)],
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            children.append((child, ready, log))
        while not all(ready.is_file() for _, ready, _ in children):
            assert all(child.poll() is None for child, _, _ in children), 'both fresh processes meet before resume'
            assert time.monotonic() < deadline, 'original sixty-second concurrent process deadline'
            time.sleep(.01)
        Path(str(db) + '.race-go').write_bytes(b'go')
        for child, _, _ in children:
            assert child.wait(timeout=max(.001, deadline - time.monotonic())) == 0
    finally:
        for child, _, _ in children:
            if child.poll() is None:
                drain(child)
        for log in logs:
            log.close()
    outputs = [(owned / ('race-' + name + '.log')).read_bytes() for name in ('a', 'b')]
    assert sum(b'Context boundary physical reopen passed: ' in output for output in outputs) == 1, 'exactly one actual resume winner'
    assert sum(b'Context boundary concurrent loser: ' in output for output in outputs) == 1, 'one no-effect current/CAS loser'
    after = snapshot(db)
    for key in ('old_attempt', 'old_receipts', 'old_tool_items', 'old_manifest'):
        assert after[key] == before[key], 'concurrent recovery never replays old facts: ' + key
    assert after['run'][0] == 'completed'
    with sqlite3.connect(db) as connection:
        assert connection.execute('SELECT COUNT(*) FROM model_attempts').fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM model_attempts WHERE semantic_request_id='semantic-cut-recovery-run-model-2' AND attempt_no=1 AND dispatch_state='dispatch_claimed'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM operations WHERE run_id='cut-recovery-run'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM app_run_events WHERE run_id='cut-recovery-run' AND json_extract(payload,'$.payload_type')='budget_updated' AND json_extract(payload,'$.detail.turns')=2 AND json_extract(payload,'$.detail.model_requests')=1").fetchone()[0] == 1, 'only one post-cut work-turn reservation'
    return {'phase': 'concurrent_single_winner', 'mode': 'two_fresh_processes',
            'original_facts_unchanged': True, 'unique_new_attempt': True,
            'logs': {name: sha(owned / ('race-' + name + '.log')) for name in ('a', 'b')}}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--binary-sha256', required=True)
    parser.add_argument('--compiled-source-proof', type=Path, required=True)
    parser.add_argument('--compiled-source-proof-sha256', required=True)
    parser.add_argument('--compiled-source-root', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    assert os.name == 'posix', 'actual kill/reopen contract requires POSIX; Windows is not silently skipped'
    binary = args.binary.resolve(strict=True)
    assert binary.is_file() and binary.read_bytes()[:4] == b'\x7fELF' and sha(binary) == args.binary_sha256
    assert sha(args.compiled_source_proof) == args.compiled_source_proof_sha256
    # Full expected source closure, actual compile success and SDK provenance
    # are supplied by the separately reviewed serial gate, never a fake Source.
    proof = json.loads(args.compiled_source_proof.read_bytes())
    assert proof['status'] == 'PASS' and proof['binary_sha256'] == sha(binary)
    assert proof['source_files'] and proof['source_manifest_sha256'] and proof['sdk_guard_true'] is True
    assert proof['compiler_exit_code'] == 0 and proof['compiler_timed_out'] is False
    assert proof['sdk_source_files'] and len(proof['sdk_source_files']) == 96
    assert proof['source_root'] == str(args.compiled_source_root.resolve(strict=True))
    def source_guard():
        root = args.compiled_source_root.resolve(strict=True)
        actual = {}
        for path in root.rglob('*'):
            assert not path.is_symlink(), 'compiled source cannot acquire a symlink'
            if path.is_file():
                actual[path.relative_to(root).as_posix()] = sha(path)
        assert actual == proof['source_files'], 'complete genuinely compiled source map'
        assert sha(proof['source_manifest_path']) == proof['source_manifest_sha256']
        for path, expected in proof['sdk_source_files'].items():
            assert sha(Path(proof['sdk_root']) / path) == expected
        for entry in proof['sdk_aliases']:
            alias = Path(entry['path'])
            assert alias.is_symlink() and os.readlink(alias) == entry['target']
            assert str(alias.resolve(strict=True)) == entry['resolved']
        assert len(proof['sdk_aliases']) == 2
        assert len(proof['sdk_licenses']) == 3
        for path, expected in proof['sdk_licenses'].items():
            assert sha(path) == expected
        assert sha(proof['clang_path']) == proof['clang_sha256']
    source_guard()
    assert not args.evidence.exists(), 'fresh owned evidence directory'
    args.evidence.mkdir(parents=True)
    before_binary = sha(binary)
    results = []
    with tempfile.TemporaryDirectory(prefix='actual-context-cut-recovery-') as temporary:
        root = Path(temporary)
        for phase in ('after_safe_cut', 'after_turn_reserved', 'after_canonical_input', 'after_context_ready'):
            source_guard()
            results.append(case(binary, root, phase))
            source_guard()
        results.append(case(binary, root, 'after_context_ready', 'cancel'))
        results.append(case(binary, root, 'after_safe_cut', 'tampered'))
        source_guard()
        results.append(concurrent_single_winner(binary, root))
        source_guard()
        # Durable per-case logs are copied before the fresh owner is discarded.
        import shutil
        shutil.copytree(root, args.evidence / 'owned_cases')
    source_guard()
    assert sha(binary) == before_binary and sha(args.compiled_source_proof) == args.compiled_source_proof_sha256
    (args.evidence / 'summary.json').write_text(json.dumps({'status': 'PASS', 'actual_sigkill_reopen_controls': results,
        'binary_sha256': before_binary, 'compiled_source_proof_sha256': args.compiled_source_proof_sha256,
        'limits': {'each_process_seconds': 60}, 'background_resource_recovery': 'PENDING_DURABLE_OWNER_IMPLEMENTATION_AND_ACCEPTANCE'}, indent=2))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Prepare a fresh independently built Shell package for actual Product tests."""
from product_unit_gate import has_compiler_error
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# The original reviewed cases must remain. Discover added cases from the actual
# source and require every one by name in the runtime report; a release version
# or an added managed-job case must not silently bypass this gate.
REQUIRED_CASES = {
    "test_static_native_handshake_and_real_discovery_have_no_idle_traffic",
    "test_pure_prepare_exact_write_receipt_and_persistent_backend",
    "test_changed_prepared_bytes_and_other_run_cannot_write",
    "test_completed_call_cannot_be_prepared_or_dispatched_twice",
    "test_absent_write_receipt_never_becomes_completed_outcome",
    "test_readonly_backend_and_no_unowned_async_job",
    "test_actual_large_stream_uses_only_host_observed_artifact_reference",
    "test_forged_host_artifact_ack_is_not_a_successful_shell_completion",
    "test_real_backend_timeout_reports_unknown_without_retry",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(package):
    return {path.relative_to(package).as_posix(): digest(path)
            for path in sorted(package.rglob('*')) if path.is_file()}


def run(command, log, timeout, environment=None):
    with log.open('w') as stream:
        process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            code = 124
    text = log.read_text(errors='replace')
    sys.stderr.write(text)
    if code != 0:
        raise ValueError(f'fixture command failed ({code}); see {log}')
    return text


def prepare(output=None):
    if sys.platform != 'linux':
        raise ValueError('the independently packaged Shell fixture requires Linux')
    plugin = ROOT / 'plugins/shell'
    if output is None:
        artifacts = ROOT / 'target/plugin-contract-fixtures'
        artifacts.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='shell-plugin-', dir=artifacts)) / 'package'
    package = output.resolve()
    if package.exists():
        raise ValueError('fixture output must be a new directory')
    evidence = package.parent / (package.name + '-validation')
    evidence.mkdir(parents=True, exist_ok=False)
    record = {'status': 'FAIL', 'package': str(package), 'expected_cases': None,
              'scope': 'Standalone native binary and actual packaged Python/Bash backend through a fixture broker; Product/SQLite authority and sandboxing are tested separately. Every discovered protocol case must run without a skip.'}
    try:
        sources = [ast.parse((plugin / name).read_text()) for name in ('check.py',)]
        cases = [node.name for source in sources for node in ast.walk(source)
                 if isinstance(node, ast.FunctionDef) and node.name.startswith('test_')]
        if not REQUIRED_CASES.issubset(cases) or len(cases) != len(set(cases)):
            raise ValueError('review the independent Shell protocol test inventory')
        expected_cases = len(cases)
        record['cases'] = cases
        record['expected_cases'] = expected_cases
        record['protocol_source_sha256'] = digest(plugin / 'check.py')
        text = run(['bash', str(plugin / 'build-package.sh'), '--output', str(package)],
                   evidence / 'build.log', 900)
        if 'cjpm build success' not in text or has_compiler_error(text):
            raise ValueError('actual compiler success is missing')
        manifest = json.loads((package / 'axyndra.plugin.json').read_text())
        if manifest != json.loads((plugin / 'axyndra.plugin.json').read_text()):
            raise ValueError('packaged manifest differs from source')
        entry = (package / manifest['entrypoint']).resolve(strict=True)
        if not entry.is_relative_to(package) or not entry.is_file():
            raise ValueError('packaged entrypoint escapes its directory')
        provenance = json.loads((package / 'package-provenance.json').read_text())
        if provenance['plugin_sha256'] != digest(entry):
            raise ValueError('packaged binary hash differs from provenance')
        for directory, field in [('lib', 'bundled_libraries_sha256'), ('licenses', 'bundled_licenses_sha256')]:
            actual = {path.name: digest(path) for path in sorted((package / directory).iterdir()) if path.is_file()}
            if actual != provenance[field]:
                raise ValueError(f'packaged {directory} differs from provenance')
        backend = package / 'backend/shell_backend.py'
        if backend.is_symlink() or not backend.is_file() or not backend.resolve().is_relative_to(package):
            raise ValueError('packaged Shell backend escapes its package')
        if provenance['backend_sha256'] != digest(backend) or digest(backend) != digest(plugin / 'backend/shell_backend.py'):
            raise ValueError('packaged backend differs from its reviewed source/provenance')
        if provenance['version'] != manifest['version']:
            raise ValueError('package version differs from its manifest')
        record['backend_sha256'] = digest(backend)
        before = files(package)
        environment = dict(os.environ)
        for name in ['LD_LIBRARY_PATH', 'CANGJIE_HOME', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH']:
            environment.pop(name, None)
        record['loader_environment_removed'] = True
        text = run([sys.executable, str(plugin / 'check.py'), '--binary', str(entry)],
                   evidence / 'protocol.log', 240, environment)
        observed = re.findall(r'^(test_\w+) .*? \.\.\. (ok|skipped.*?)$', text, re.M)
        names = [name for name, _ in observed]
        if len(names) != expected_cases or set(names) != set(cases) or len(names) != len(set(names)) or \
                any(status != 'ok' for _, status in observed) or \
                not re.search(rf'^Ran {expected_cases} tests in [0-9.]+s$', text, re.M) or not re.search(r'^OK$', text, re.M) or \
                'FAILED' in text or 'ERROR:' in text or 'skipped' in text.lower():
            raise ValueError('Shell protocol fixture must execute every exact case without failure or skip')
        if record['protocol_source_sha256'] != digest(plugin / 'check.py'):
            raise ValueError('protocol test source changed during verification')
        if before != files(package):
            raise ValueError('package changed during protocol verification')
        record.update(status='PASS', protocol_counts={'total': expected_cases, 'passed': expected_cases,
                      'failed': 0, 'errors': 0, 'skipped': 0}, package_files=before,
                      entrypoint_sha256=digest(entry), package_provenance=provenance)
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        (evidence / 'summary.json').write_text(json.dumps(record, indent=2) + '\n')
    return package


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='new package directory; default is under target/plugin-contract-fixtures')
    arguments = parser.parse_args()
    try:
        print(prepare(arguments.output))
    except (OSError, ValueError, KeyError) as error:
        print(f'Shell fixture preparation failed: {error}', file=sys.stderr)
        raise SystemExit(1)

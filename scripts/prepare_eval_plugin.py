#!/usr/bin/env python3
"""Prepare a fresh independently built Eval package for actual Product tests."""
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
EXPECTED_CASES = 20


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
        raise ValueError('the independently packaged Eval fixture requires Linux')
    plugin = ROOT / 'plugins/eval'
    if output is None:
        artifacts = ROOT / 'target/plugin-contract-fixtures'
        artifacts.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='eval-plugin-', dir=artifacts)) / 'package'
    package = output.resolve()
    if package.exists():
        raise ValueError('fixture output must be a new directory')
    evidence = package.parent / (package.name + '-validation')
    evidence.mkdir(parents=True, exist_ok=False)
    record = {'status': 'FAIL', 'package': str(package), 'expected_cases': EXPECTED_CASES,
              'scope': 'Standalone native binary and actual packaged Python runner through a fixture broker; Product authority is tested separately. No optional interpreter skip can replace Python protocol coverage.'}
    try:
        sources = [ast.parse((plugin / name).read_text()) for name in ('check.py',)]
        cases = [node.name for source in sources for node in ast.walk(source)
                 if isinstance(node, ast.FunctionDef) and node.name.startswith('test_')]
        if len(cases) != EXPECTED_CASES or len(set(cases)) != EXPECTED_CASES:
            raise ValueError('review the independent Eval protocol test inventory')
        record['cases'] = cases
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
        for directory, field in [('lib', 'bundled_libraries_sha256'), ('licenses', 'bundled_licenses_sha256'), ('runners', 'runners_sha256')]:
            actual = {path.name: digest(path) for path in sorted((package / directory).iterdir()) if path.is_file()}
            if actual != provenance[field]:
                raise ValueError(f'packaged {directory} differs from provenance')
        extraction = json.loads((package / 'runners/extraction.json').read_text())
        if extraction != json.loads((plugin / 'runners/extraction.json').read_text()):
            raise ValueError('packaged runner provenance differs from reviewed source')
        for name, details in extraction['runners'].items():
            if digest(package / 'runners' / name) != details['packaged_sha256']:
                raise ValueError('runner differs from reviewed provenance: ' + name)
        record['runner_source_commit'] = extraction['source_commit']
        before = files(package)
        environment = dict(os.environ)
        for name in ['LD_LIBRARY_PATH', 'CANGJIE_HOME', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH']:
            environment.pop(name, None)
        record['loader_environment_removed'] = True
        text = run([sys.executable, str(plugin / 'check.py'), '--binary', str(entry)],
                   evidence / 'protocol.log', 240, environment)
        observed = re.findall(r'^test_\w+ .*? \.\.\. (ok|skipped.*?)$', text, re.M)
        if len(observed) != EXPECTED_CASES or any(item != 'ok' for item in observed) or \
                not re.search(rf'^Ran {EXPECTED_CASES} tests in [0-9.]+s$', text, re.M) or not re.search(r'^OK$', text, re.M) or \
                'FAILED' in text or 'ERROR:' in text or 'skipped' in text.lower():
            raise ValueError('Eval protocol fixture must execute every case without failure or skip')
        if before != files(package):
            raise ValueError('package changed during protocol verification')
        record.update(status='PASS', protocol_counts={'total': EXPECTED_CASES, 'passed': EXPECTED_CASES,
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
        print(f'Eval fixture preparation failed: {error}', file=sys.stderr)
        raise SystemExit(1)

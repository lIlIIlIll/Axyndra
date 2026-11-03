#!/usr/bin/env python3
"""Prepare a fresh independently built Skills package for actual Product tests."""
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
from product_unit_gate import summary, has_compiler_error

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_CASES = 45
EXPECTED_UNITS = 16


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(package):
    return {path.relative_to(package).as_posix(): digest(path)
            for path in sorted(package.rglob('*')) if path.is_file()}


def run(command, log, timeout, environment=None, cwd=None):
    with log.open('w') as stream:
        process = subprocess.Popen(command, cwd=cwd or ROOT, env=environment, stdout=stream,
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
    text = log.read_text(encoding='utf-8', errors='replace')
    sys.stderr.write(text)
    if code != 0:
        raise ValueError(f'fixture command failed ({code}); see {log}')
    return text


def prepare(output=None):
    if sys.platform != 'linux':
        raise ValueError('the independently packaged Skills fixture requires Linux')
    plugin = ROOT / 'plugins/skills'
    if output is None:
        artifacts = ROOT / 'target/plugin-contract-fixtures'
        artifacts.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='skills-plugin-', dir=artifacts)) / 'package'
    package = output.resolve()
    if package.exists():
        raise ValueError('fixture output must be a new directory')
    evidence = package.parent / (package.name + '-validation')
    evidence.mkdir(parents=True, exist_ok=False)
    record = {'status': 'FAIL', 'package': str(package), 'expected_cases': EXPECTED_CASES,
              'scope': 'Packaged native Skills Context/ResourceProvider and actual package-data fixtures; Product authority tested separately.'}
    try:
        source = ast.parse((plugin / 'check.py').read_text(encoding='utf-8'))
        cases = [node.name for node in ast.walk(source)
                 if isinstance(node, ast.FunctionDef) and node.name.startswith('test_')]
        if len(cases) != EXPECTED_CASES or len(set(cases)) != EXPECTED_CASES:
            raise ValueError('review the independent Skills protocol test inventory')
        record['cases'] = cases
        text = run(['bash', str(plugin / 'build-package.sh'), '--output', str(package), '--content-root', str(plugin / 'tests/content')],
                   evidence / 'build.log', 900)
        if 'cjpm build success' not in text or has_compiler_error(text):
            raise ValueError('actual compiler success is missing')
        unit_cases = sum(path.read_text(encoding='utf-8').count('@TestCase')
                         for path in (plugin / 'src').glob('*test.cj'))
        if unit_cases != EXPECTED_UNITS:
            raise ValueError('review independent Skills pure algorithm inventory')
        unit = summary(run([str(ROOT / 'scripts/pinned_cangjie'), 'cjpm', 'test'],
                           evidence / 'unit.log', 900, cwd=plugin))
        if unit != dict(total=EXPECTED_UNITS, passed=EXPECTED_UNITS, failed=0, errors=0, skipped=0):
            raise ValueError('all migrated Skills algorithm unit cases must execute and pass')
        record['unit_counts'] = unit
        manifest = json.loads((package / 'axyndra.plugin.json').read_text(encoding='utf-8'))
        if manifest != json.loads((plugin / 'axyndra.plugin.json').read_text(encoding='utf-8')):
            raise ValueError('packaged manifest differs from source')
        entry = (package / manifest['entrypoint']).resolve(strict=True)
        if not entry.is_relative_to(package) or not entry.is_file():
            raise ValueError('packaged entrypoint escapes its directory')
        provenance = json.loads((package / 'package-provenance.json').read_text(encoding='utf-8'))
        if provenance['plugin_sha256'] != digest(entry):
            raise ValueError('packaged binary hash differs from provenance')
        for directory, field in [('lib', 'bundled_libraries_sha256'), ('licenses', 'bundled_licenses_sha256')]:
            actual = {path.name: digest(path) for path in sorted((package / directory).iterdir()) if path.is_file()}
            if actual != provenance[field]:
                raise ValueError(f'packaged {directory} differs from provenance')
        content = files(package / 'skills')
        if content != provenance['content_sha256'] or content != files(plugin / 'tests/content'):
            raise ValueError('packaged Skill content differs from source or provenance')
        record['content_sha256'] = content
        before = files(package)
        environment = dict(os.environ)
        for name in ['LD_LIBRARY_PATH', 'CANGJIE_HOME', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH']:
            environment.pop(name, None)
        record['loader_environment_removed'] = True
        text = run([sys.executable, str(plugin / 'check.py'), '--package', str(package)],
                   evidence / 'protocol.log', 240, environment)
        observed = re.findall(r'^test_\w+ .*? \.\.\. (ok|skipped.*?)$', text, re.M)
        if len(observed) != EXPECTED_CASES or any(item != 'ok' for item in observed) or \
                not re.search(rf'^Ran {EXPECTED_CASES} tests in [0-9.]+s$', text, re.M) or not re.search(r'^OK$', text, re.M) or \
                'FAILED' in text or 'ERROR:' in text or 'skipped' in text.lower():
            raise ValueError('Skills protocol fixture must execute every case without failure or skip')
        if before != files(package):
            raise ValueError('package changed during protocol verification')
        record.update(status='PASS', protocol_counts={'total': EXPECTED_CASES, 'passed': EXPECTED_CASES,
                      'failed': 0, 'errors': 0, 'skipped': 0}, package_files=before,
                      entrypoint_sha256=digest(entry), package_provenance=provenance)
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        (evidence / 'summary.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    return package


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='new package directory; default is under target/plugin-contract-fixtures')
    arguments = parser.parse_args()
    try:
        print(prepare(arguments.output))
    except (OSError, ValueError, KeyError) as error:
        print(f'Skills fixture preparation failed: {error}', file=sys.stderr)
        raise SystemExit(1)

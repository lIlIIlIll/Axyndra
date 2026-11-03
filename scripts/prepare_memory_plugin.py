#!/usr/bin/env python3
"""Prepare a fresh independently built Memory package for actual Product tests."""
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
EXPECTED_CASES = 40


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(package):
    return {path.relative_to(package).as_posix(): digest(path)
            for path in sorted(package.rglob('*')) if path.is_file()}


def run(command, log, timeout, environment=None, working_directory=None):
    with log.open('w') as stream:
        process = subprocess.Popen(command, cwd=ROOT if working_directory is None else working_directory, env=environment, stdout=stream,
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


def complete_unit_inventory(plugin):
    inventory = json.loads((ROOT / 'scripts/memory_native_unit_inventory.json').read_text(encoding='utf-8'))
    if set(inventory) != {'version', 'cases', 'original_cases', 'files'} or inventory['version'] != 1:
        raise ValueError('invalid whole Memory unit inventory')
    cases, original = inventory['cases'], inventory['original_cases']
    if len(cases) != 138 or len(set(cases)) != 138 or len(original) != 21 or len(set(original)) != 21 or not set(original) <= set(cases):
        raise ValueError('whole 138 and original 21 Memory units must both remain inventoried')
    actual = {path.relative_to(ROOT).as_posix(): digest(path) for path in sorted((plugin / 'src').rglob('*_test.cj'))}
    if actual != inventory['files']:
        raise ValueError('review every current Memory unit source before preparing its package')
    return inventory


def complete_unit_results(text, expected):
    # The full package runs once, without filters. Only actual terminal TCS /
    # CASE result rows supply names; progress labels and counts are insufficient.
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    suite = None
    cases = []
    for line in text.splitlines():
        named = re.match(r'\s*TCS:\s+([A-Za-z_][A-Za-z0-9_]*)[,\s]', line)
        if named:
            suite = named.group(1)
            continue
        result = re.match(r'\s*\[\s*([A-Z]+)\s*\]\s+CASE:\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', line)
        if result:
            if suite is None or result.group(1) != 'PASSED':
                raise ValueError('Memory unit result must be a named actual pass')
            cases.append(suite + '.' + result.group(2))
    if len(cases) != len(set(cases)) or sorted(cases) != sorted(expected):
        raise ValueError('Memory unit result names differ from the complete current inventory')
    return cases


def prepare(output=None):
    if sys.platform != 'linux':
        raise ValueError('the independently packaged Memory fixture requires Linux')
    plugin = ROOT / 'plugins/memory'
    if output is None:
        artifacts = ROOT / 'target/plugin-contract-fixtures'
        artifacts.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='memory-plugin-', dir=artifacts)) / 'package'
    package = output.resolve()
    if package.exists():
        raise ValueError('fixture output must be a new directory')
    evidence = package.parent / (package.name + '-validation')
    evidence.mkdir(parents=True, exist_ok=False)
    record = {'status': 'FAIL', 'package': str(package), 'expected_cases': EXPECTED_CASES,
              'scope': 'Packaged Native Memory complete 138 named units, including all original 21 units, and all original 40 protocol cases. Actual Product Root, Source, Receipt and recovery gates run separately.'}
    try:
        inventory = complete_unit_inventory(plugin)
        record['unit_inventory'] = inventory
        sources = [ast.parse((plugin / 'tests' / name).read_text(encoding='utf-8'))
                   for name in ['check.py', 'check_fragments.py', 'check_ieee.py','check_native_documents.py','check_native_context.py']]
        cases = [node.name for source in sources for node in ast.walk(source)
                 if isinstance(node, ast.FunctionDef) and node.name.startswith('test_')]
        if len(cases) != EXPECTED_CASES or len(set(cases)) != EXPECTED_CASES:
            raise ValueError('review the independent Memory protocol test inventory')
        record['cases'] = cases
        text = run(['bash', str(plugin / 'build-package.sh'), '--output', str(package)],
                   evidence / 'build.log', 900)
        if 'cjpm build success' not in text or has_compiler_error(text):
            raise ValueError('actual compiler success is missing')
        # SDK workers execute independent test classes in separate processes.
        # Every Native case owns its own in-memory journal, budget and producer;
        # no shared filesystem fixture or mutable suite state is involved. Keep
        # two workers bounded, all cases unfiltered, and each case unchanged.
        unit_text = run([str(ROOT / 'scripts/pinned_cangjie'), 'cjpm', 'test', '--parallel', '2',
                         '--no-progress'], evidence / 'unit.log', 900,
                        working_directory=plugin)
        unit = summary(unit_text)
        if unit != dict(total=138, passed=138, failed=0, skipped=0, errors=0):
            raise ValueError('the complete-corpus Cangjie oracle must pass without skip')
        record['unit_counts'] = unit
        record['unit_cases'] = complete_unit_results(unit_text, inventory['cases'])
        record['original_unit_cases'] = inventory['original_cases']
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
        before = files(package)
        environment = dict(os.environ)
        for name in ['LD_LIBRARY_PATH', 'CANGJIE_HOME', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH']:
            environment.pop(name, None)
        record['loader_environment_removed'] = True
        text = run([sys.executable, str(plugin / 'tests/check.py'), '--package', str(package)],
                   evidence / 'protocol.log', 240, environment)
        observed = re.findall(r'^test_\w+ .*? \.\.\. (ok|skipped.*?)$', text, re.M)
        if len(observed) != EXPECTED_CASES or any(item != 'ok' for item in observed) or \
                not re.search(rf'^Ran {EXPECTED_CASES} tests in [0-9.]+s$', text, re.M) or not re.search(r'^OK$', text, re.M) or \
                'FAILED' in text or 'ERROR:' in text or 'skipped' in text.lower():
            raise ValueError('Memory protocol fixture must execute every case without failure or skip')
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
        print(f'Memory fixture preparation failed: {error}', file=sys.stderr)
        raise SystemExit(1)

#!/usr/bin/env python3
"""Execute every inventoried workspace unit-test package and retain summaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]

def inventory(root):
    workspace = tomllib.loads((root / 'cjpm.toml').read_text())['workspace']
    found = {}
    for member in workspace['members']:
        files = sorted(p.relative_to(root).as_posix() for p in (root / member / 'src').rglob('*_test.cj'))
        if files:
            if member not in workspace['test-members']:
                raise ValueError(f'test member omitted: {member}')
            found[member] = files
    if not found:
        raise ValueError("empty unit-test inventory")
    return found

def summary(text):
    text = re.sub(r'\x1b\[[0-9;]*m', '', text)
    matches = re.findall(r'Summary: TOTAL:\s*(\d+)\s+PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)\s+FAILED:\s*(\d+)', text, re.I)
    if not matches:
        raise ValueError('missing unittest result summary')
    total, passed, skipped, errors, failed = map(int, matches[-1])
    if total == 0 or total != passed + skipped + errors + failed:
        raise ValueError('invalid unittest totals')
    return dict(total=total, passed=passed, failed=failed, skipped=skipped, errors=errors)

def run_logged(command, log, cwd, timeout=900):
    with log.open('w') as output:
        process = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Terminate the entire compiler/test tree before starting another package.
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return 124


def dry_run_cases(text):
    suite = None
    cases = []
    for line in text.splitlines():
        suite_match = re.match(r'\s*TCS:\s+([A-Za-z_][A-Za-z0-9_]*)', line)
        if suite_match:
            suite = suite_match.group(1)
            continue
        case_match = re.match(r'\s*\[\s*NORUN\s*\]\s+CASE:\s+([A-Za-z_][A-Za-z0-9_]*)', line)
        if case_match:
            if suite is None:
                raise ValueError('dry-run case appeared before its test suite')
            cases.append(f'{suite}.{case_match.group(1)}')
    if not cases:
        raise ValueError('dry run returned no unit-test cases')
    if len(cases) != len(set(cases)):
        raise ValueError('dry run returned duplicate unit-test cases')
    return cases


def run_isolated_agent_product(root, output_dir, log):
    base = [str(root / 'scripts/pinned_cangjie'), 'cjpm', 'test', '-m', 'agent_product']
    dry_log = output_dir / 'agent_product.dry-run.log'
    dry_command = base + ['--dry-run', '--no-color', '--no-progress']
    dry_exit = run_logged(dry_command, dry_log, root)
    record = {
        'member': 'agent_product',
        'command': dry_command,
        'log': log.name,
        'dry_run_log': dry_log.name,
        'exit_code': dry_exit,
        'status': 'FAIL',
    }
    dry_text = dry_log.read_text(errors='replace')
    log.write_text(dry_text)
    if dry_exit != 0:
        record['error'] = 'agent_product dry run failed'
        return record
    try:
        cases = dry_run_cases(dry_text)
    except ValueError as error:
        record['error'] = str(error)
        return record
    case_dir = output_dir / 'agent_product-cases'
    case_dir.mkdir(exist_ok=True)
    record['case_count'] = len(cases)
    record['case_logs'] = []
    passed = 0
    for index, name in enumerate(cases):
        case_log = case_dir / f'{index + 1:03d}-{name}.log'
        command = base + [
            '--skip-build', '--filter', name, '--parallel', '1',
            '--timeout-each=60s', '--no-color', '--no-progress'
        ]
        exit_code = run_logged(command, case_log, root, timeout=90)
        relative_log = case_log.relative_to(output_dir).as_posix()
        record['case_logs'].append(relative_log)
        with log.open('a') as combined:
            combined.write(f'\n===== {name} =====\n')
            combined.write(case_log.read_text(errors='replace'))
        try:
            observed = summary(case_log.read_text(errors='replace'))
            valid = (
                exit_code == 0 and observed['total'] == len(cases) and
                observed['passed'] == 1 and observed['skipped'] == len(cases) - 1 and
                observed['failed'] == 0 and observed['errors'] == 0
            )
        except ValueError:
            valid = False
        if not valid:
            record.update(
                exit_code=exit_code if exit_code != 0 else 1,
                total=len(cases), passed=passed,
                failed=1, errors=0, skipped=len(cases) - passed - 1,
                error=f'isolated unit-test case failed: {name}'
            )
            return record
        passed += 1
    record.update(
        exit_code=0, total=len(cases), passed=passed,
        failed=0, errors=0, skipped=0, status='PASS'
    )
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=Path(os.environ.get('AXYNDRA_EVIDENCE_DIR', 'target/gate-evidence')) / 'unit-tests')
    parser.add_argument('--inventory-only', action='store_true')
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    result = {'schema_version': 1, 'mode': 'inventory' if args.inventory_only else 'execute', 'status': 'FAIL', 'packages': []}
    try:
        found = inventory(ROOT)
        result['inventory'] = found
        expected = json.loads((ROOT / 'scripts/product_unit_inventory.json').read_text())
        if found != expected:
            changed = sorted(member for member in found.keys() | expected.keys() if found.get(member) != expected.get(member))
            raise ValueError('unit-test inventory differs for ' + ', '.join(changed) + '; review scripts/product_unit_inventory.json against manifest inventory')
        result['sources'] = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for files in found.values() for p in files}
        if not args.inventory_only:
            for member in found:
                log = args.output_dir / (member.replace('/', '__') + '.log')
                print(f'unit tests: {member}', flush=True)
                if member == 'agent_product':
                    # Process-backed host lifecycle cases must not share a test process:
                    # a crashed or force-killed child can retain runner-owned resources
                    # until that process exits, contaminating the following case.
                    record = run_isolated_agent_product(ROOT, args.output_dir, log)
                else:
                    command = [str(ROOT / 'scripts/pinned_cangjie'), 'cjpm', 'test', '-m', member, '--no-color']
                    record = {'member': member, 'command': command, 'log': log.name}
                    record['exit_code'] = run_logged(command, log, ROOT)
                    try:
                        record.update(summary(log.read_text(errors='replace')))
                        record['status'] = 'PASS' if record['exit_code'] == 0 and record['failed'] == 0 and record['errors'] == 0 and record['skipped'] == 0 else 'FAIL'
                    except ValueError as error:
                        record.update(status='FAIL', error=str(error))
                result['packages'].append(record)
                (args.output_dir / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
                print(f"{member}: {record['status']}", flush=True)
        result['status'] = 'PASS' if all(p['status'] == 'PASS' for p in result['packages']) else 'FAIL'
    except (OSError, ValueError, KeyError) as error:
        result['error'] = str(error)
    (args.output_dir / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['status'] == 'PASS' else 1

if __name__ == '__main__':
    raise SystemExit(main())

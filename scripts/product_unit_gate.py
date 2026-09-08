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
                command = [str(ROOT / 'scripts/pinned_cangjie'), 'cjpm', 'test', '-m', member, '--no-color']
                record = {'member': member, 'command': command, 'log': log.name}
                print(f'unit tests: {member}', flush=True)
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

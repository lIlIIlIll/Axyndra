#!/usr/bin/env python3
"""Run and enumerate the independent search business tests with retained evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from product_unit_gate import dry_run_cases, run_logged, summary

EXPECTED_CASES = 29


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    package = ROOT / 'plugins/web_search'
    base = [str(ROOT / 'scripts/pinned_cangjie'), 'cjpm', 'test']
    test_log = args.output_dir / 'test.log'
    dry_log = args.output_dir / 'enumeration.log'
    record = dict(status='FAIL', expected_cases=EXPECTED_CASES)
    try:
        test_exit = run_logged(base + ['--parallel', '1', '--no-color', '--no-progress'], test_log, package)
        record['test_exit'] = test_exit
        if test_exit != 0:
            raise ValueError('web search pure test command failed')
        counts = summary(test_log.read_text(errors='replace'))
        record['counts'] = counts
        if counts != dict(total=EXPECTED_CASES, passed=EXPECTED_CASES, skipped=0, failed=0, errors=0):
            raise ValueError('web search pure tests did not execute all reviewed cases successfully')
        dry_exit = run_logged(base + ['--skip-build', '--dry-run', '--no-color', '--no-progress'], dry_log, package)
        record['enumeration_exit'] = dry_exit
        if dry_exit != 0:
            raise ValueError('web search pure test enumeration failed')
        cases = dry_run_cases(dry_log.read_text(errors='replace'))
        if len(cases) != EXPECTED_CASES:
            raise ValueError('web search pure test enumeration differs from the reviewed case count')
        binary = package / 'target/release/unittest_bin/web_search_plugin'
        record.update(status='PASS', cases=cases, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                      sources={p.relative_to(package).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sorted((package / 'src').glob('*.cj'))})
    except (OSError, ValueError) as error:
        record['error'] = str(error)
    (args.output_dir / 'summary.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(dict(status=record['status'], pure_cases=record.get('counts'), evidence=str(args.output_dir))))
    return 0 if record['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())

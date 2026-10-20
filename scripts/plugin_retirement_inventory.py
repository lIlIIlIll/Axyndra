#!/usr/bin/env python3
"""Enumerate legacy/compatibility paths for retirement (issue #48 T0-02).

Scans the repository for files whose NAME marks them as an older form or an
adapter (`legacy`, `compatibility`, `bridge`) and classifies each by whether
anything outside the file references its **distinctive** exported names.

Symbol matching is deliberately conservative: short or generic declaration
names (`main`, `parse`, `find`, `run`, ...) are ignored, because such a name
matches unrelated code and produced meaningless reference counts in an early
revision of this script. Counts here are therefore a LOWER bound on usage: a
file can still be live through an identifier this filter refuses to follow,
which is why the verdict is evidence for review and never authorisation to
delete. A file that only reads data written by older versions may be required
even with zero references.

Run: python3 scripts/plugin_retirement_inventory.py [--json]
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MARKERS = ('legacy', 'compatibility', 'bridge')
SKIP_DIRS = {'target', '.git', '.omp'}
MIN_NAME_LEN = 12
GENERIC = {
    'init', 'main', 'run', 'read', 'write', 'parse', 'encode', 'decode',
    'find', 'match', 'index', 'value', 'values', 'size', 'length', 'close',
    'open', 'create', 'update', 'delete', 'remove', 'insert', 'query',
    'error', 'message', 'result', 'options', 'config', 'configuration',
    'struct', 'class', 'enum', 'type', 'state', 'status', 'name', 'text',
}
DECL = re.compile(r'^\s*(?:public\s+)?(?:func|class|struct|enum|let|const|type)\s+'
                  r'([A-Za-z_][A-Za-z0-9_]*)', re.M)
TEST_SUFFIXES = ('_test.cj', '_test.py')


def source_files():
    for path in ROOT.rglob('*.cj'):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        yield path


def is_candidate(path):
    name = path.name.lower()
    return any(marker in name for marker in MARKERS)


def distinctive_exported_names(path):
    """Exported names specific enough to identify this file's surface."""
    try:
        text = path.read_text(encoding='utf-8')
    except (OSError, UnicodeDecodeError):
        return []
    names = set()
    for name in DECL.findall(text):
        lowered = name.lower()
        if len(name) < MIN_NAME_LEN or lowered in GENERIC:
            continue
        # Reject mixed-case single words that are common suffixes.
        names.add(name)
    return sorted(names)


def external_refs(path, names):
    if not names:
        return []
    pattern = re.compile(r'\b(' + '|'.join(re.escape(n) for n in names) + r')\b')
    hits = []
    for other in source_files():
        if other == path:
            continue
        try:
            text = other.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
        if pattern.search(text):
            hits.append(other.relative_to(ROOT).as_posix())
    return sorted(hits)


def build_report():
    rows = []
    for path in sorted(ROOT.rglob('*.cj')):
        if any(part in SKIP_DIRS for part in path.parts) or not is_candidate(path):
            continue
        names = distinctive_exported_names(path)
        refs = external_refs(path, names)
        production = [r for r in refs if not r.endswith(TEST_SUFFIXES)]
        tests = [r for r in refs if r.endswith(TEST_SUFFIXES)]
        own_test = path.name.endswith(TEST_SUFFIXES)
        if production:
            verdict = 'live'
        elif tests or own_test:
            verdict = 'test-only'
        else:
            verdict = 'dead'
        rows.append({
            'path': path.relative_to(ROOT).as_posix(),
            'distinctive_exports': len(names),
            'refs': len(refs),
            'production_refs': production,
            'test_refs': tests,
            'verdict': verdict,
        })
    summary = {v: sum(1 for r in rows if r['verdict'] == v)
               for v in ('live', 'test-only', 'dead')}
    return {'schema': 'axyndra.plugin-retirement-inventory/v1',
            'markers': list(MARKERS),
            'min_name_len': MIN_NAME_LEN,
            'summary': summary,
            'rows': rows}


DOC = ROOT / 'docs' / 'plugin-migration-retirement.md'


def check(report):
    """Gate: the inventory document must state the tree's actual counts."""
    counts = report['summary']
    total = len(report['rows'])
    expected = (f"**{total} candidates, {counts['live']} live, "
                f"{counts['test-only']} test-only, {counts['dead']} dead.**")
    if not DOC.is_file():
        print('plugin retirement inventory: document is missing', file=sys.stderr)
        return 1
    text = DOC.read_text(encoding='utf-8')
    if expected not in text:
        print('plugin retirement inventory: documented counts drift from the tree; '
              f'expected {expected!r} in {DOC.name}', file=sys.stderr)
        return 1
    print(f'plugin retirement inventory passed ({total} candidates: '
          f"{counts['live']} live, {counts['test-only']} test-only, "
          f"{counts['dead']} dead)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true',
                        help='emit the inventory as JSON')
    parser.add_argument('--check', action='store_true',
                        help='fail if the documented inventory drifts from the tree')
    arguments = parser.parse_args()
    report = build_report()
    if arguments.check:
        return check(report)
    if arguments.json:
        print(json.dumps(report, indent=2))
        return 0
    for row in report['rows']:
        print(f"{row['verdict']:<10} exports={row['distinctive_exports']:<3} "
              f"refs={row['refs']:<3} {row['path']}")
    counts = report['summary']
    print(f"\nlive={counts['live']} test-only={counts['test-only']} "
          f"dead={counts['dead']} (total {len(report['rows'])})")
    return 0


if __name__ == '__main__':
    sys.exit(main())

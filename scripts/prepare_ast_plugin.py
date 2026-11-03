#!/usr/bin/env python3
"""Build the independent, pinned AST plugin required by executable product gates."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def prepare():
    plugin = ROOT / 'plugins/ast'
    lock = json.loads((plugin / 'engine.lock.json').read_text())
    artifacts = ROOT / 'target/plugin-contract-fixtures'
    artifacts.mkdir(parents=True, exist_ok=True)
    engine = artifacts / ('ast-grep-' + lock['version'])
    subprocess.run([sys.executable, str(plugin / 'fetch-engine.py'), '--output', str(engine)],
                   cwd=ROOT, stdout=sys.stderr, check=True)
    invocation = Path(tempfile.mkdtemp(prefix='ast-plugin-', dir=artifacts))
    package = invocation / 'package'
    subprocess.run(['bash', str(plugin / 'build-package.sh'), '--output', str(package),
                    '--engine', str(engine / 'ast-grep'),
                    '--engine-license', str(engine / 'LICENSE.ast-grep')],
                   cwd=ROOT, stdout=sys.stderr, check=True)
    subprocess.run([sys.executable, str(plugin / 'check.py'), '--package', str(package)],
                   cwd=ROOT, stdout=sys.stderr, check=True)
    return package


if __name__ == '__main__':
    print(prepare())

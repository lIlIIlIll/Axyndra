#!/usr/bin/env python3
"""Create a fresh normal Coding distribution from an independently tested package."""
import argparse
from pathlib import Path
import shutil
import tempfile
from package_distribution import seal_distribution

ROOT = Path(__file__).resolve().parents[1]

def prepare(package, output=None):
    package = Path(package).resolve(strict=True)
    if output is None:
        directory = ROOT / 'target/plugin-contract-fixtures'
        directory.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='coding-distribution-', dir=directory)) / 'distribution'
    output = Path(output).absolute()
    if output.exists():
        raise ValueError('distribution fixture must be a new directory')
    output.mkdir(parents=True)
    shutil.copytree(package, output / 'plugins/skills', symlinks=True)
    seal_distribution(output, ROOT / 'profiles/coding-context.json')
    return output

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    print(prepare(args.package, args.output))

#!/usr/bin/env python3
"""Fetch the exact official AST engine and license pinned by engine.lock.json."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent


def verified_download(url, path, expected, limit):
    if path.exists():
        if path.stat().st_size > limit:
            raise ValueError(f'pinned cache exceeds its size limit: {path.name}')
        data = path.read_bytes()
    else:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(limit + 1)
    if len(data) > limit or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f'pinned download integrity check failed: {path.name}')
    if not path.exists():
        path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    lock = json.loads((ROOT / 'engine.lock.json').read_text())
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / 'engine.zip'
    verified_download(lock['archive_url'], archive, lock['archive_sha256'], 32 * 1024 * 1024)
    with zipfile.ZipFile(archive) as source:
        info = source.getinfo('ast-grep')
        if info.file_size > 64 * 1024 * 1024:
            raise ValueError('pinned engine extraction exceeds its limit')
        binary = source.read(info)
    if hashlib.sha256(binary).hexdigest() != lock['binary_sha256']:
        raise ValueError('extracted engine does not match its pinned digest')
    engine = output / 'ast-grep'
    if engine.exists() and (engine.stat().st_size != len(binary) or engine.read_bytes() != binary):
        raise ValueError('cached engine differs from the pinned release')
    if not engine.exists():
        engine.write_bytes(binary)
    engine.chmod(0o755)
    verified_download(lock['license_url'], output / 'LICENSE.ast-grep', lock['license_sha256'], 16384)
    print(output)


if __name__ == '__main__':
    main()

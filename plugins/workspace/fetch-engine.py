#!/usr/bin/env python3
"""Fetch an exact official ripgrep archive; extract only fixed regular members."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent


def fetch(output):
    lock = json.loads((ROOT / 'engine.lock.json').read_text())
    output = output.resolve(); output.mkdir(parents=True, exist_ok=True)
    archive = output / 'engine.tar.gz'
    if archive.exists():
        if archive.stat().st_size > 32 * 1024 * 1024:
            raise ValueError('engine archive exceeds limit')
        data = archive.read_bytes()
    else:
        with urllib.request.urlopen(lock['url'], timeout=60) as response:
            data = response.read(32 * 1024 * 1024 + 1)
    if len(data) > 32 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != lock['archive_sha256']:
        raise ValueError('engine archive does not match the official pinned SHA-256')
    if not archive.exists(): archive.write_bytes(data)
    prefix = 'ripgrep-' + lock['version'] + '-' + lock['platform'] + '/'
    with tarfile.open(archive, 'r:gz') as source:
        for name, key in [('rg', 'binary_sha256'), ('LICENSE-MIT', 'license_sha256'), ('COPYING', 'copying_sha256'), ('UNLICENSE', 'unlicense_sha256')]:
            matches = [member for member in source.getmembers() if member.name == prefix + name]
            if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 64 * 1024 * 1024:
                raise ValueError('missing, repeated or nonregular pinned member')
            data = source.extractfile(matches[0]).read(64 * 1024 * 1024 + 1)
            if hashlib.sha256(data).hexdigest() != lock[key]:
                raise ValueError('engine member does not match pinned digest: ' + name)
            path = output / name
            if path.is_symlink() or (path.exists() and path.read_bytes() != data):
                raise ValueError('refusing to overwrite a different cached member')
            if not path.exists(): path.write_bytes(data)
            if name == 'rg': path.chmod(0o755)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--output', type=Path, required=True)
    print(fetch(parser.parse_args().output))

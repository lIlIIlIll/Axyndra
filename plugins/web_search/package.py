#!/usr/bin/env python3
"""Bundle the independent web search endpoint and its Cangjie runtime closure."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dependencies(binary, environment=None):
    result = subprocess.run(['ldd', str(binary)], env=environment, text=True, capture_output=True, check=True)
    if 'not found' in result.stdout:
        raise ValueError(f'unresolved dependency in {binary.name}: {result.stdout}')
    for line in result.stdout.splitlines():
        match = re.match(r'\s*(\S+)\s+=>\s+(/.+?)\s+\(0x[0-9a-f]+\)', line)
        if match:
            yield match.group(1), Path(match.group(2)).resolve()
            continue
        match = re.match(r'\s*(/.+?)\s+\(0x[0-9a-f]+\)', line)
        if match:
            source = Path(match.group(1)).resolve()
            yield source.name, source


def system_library(path):
    return any(path.is_relative_to(prefix) for prefix in [Path('/lib'), Path('/lib64'), Path('/usr/lib'), Path('/usr/lib64')])


def package(arguments):
    if not arguments.binary or not arguments.binary.is_file():
        raise ValueError('compiled plugin is missing; run build-package.sh without --skip-build')
    if not arguments.sdk_root or not (arguments.sdk_root / 'LICENSE').is_file():
        raise ValueError('SDK runtime license is required')
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.web-search-package-', dir=output.parent) as temporary:
        stage = Path(temporary)
        for name in ['bin', 'lib', 'licenses']:
            (stage / name).mkdir()
        plugin = stage / 'bin/web-search-plugin'
        shutil.copy2(arguments.binary, plugin)
        plugin.chmod(0o755)
        shutil.copy2(ROOT / 'axyndra.plugin.json', stage / 'axyndra.plugin.json')
        shutil.copy2(arguments.sdk_root / 'LICENSE', stage / 'licenses/cangjie-runtime.txt')
        shutil.copy2(REPOSITORY / 'LICENSE', stage / 'licenses/axyndra.txt')
        if (REPOSITORY / 'NOTICE').is_file():
            shutil.copy2(REPOSITORY / 'NOTICE', stage / 'licenses/axyndra-NOTICE.txt')
        queue = [plugin]
        copied = {}
        required_system = set()
        while queue:
            current = queue.pop(0)
            for name, source in dependencies(current):
                if system_library(source):
                    required_system.add(name)
                    continue
                if name in copied:
                    if copied[name] != source and digest(source) != digest(stage / 'lib' / name):
                        raise ValueError(f'library name resolves to conflicting sources: {name}')
                    continue
                if len(copied) >= 128 or Path(name).name != name:
                    raise ValueError('unexpected dependency closure')
                destination = stage / 'lib' / name
                shutil.copy2(source, destination)
                copied[name] = source
                queue.append(destination)
        subprocess.run(['patchelf', '--set-rpath', '$ORIGIN/../lib', str(plugin)], check=True)
        for library in (stage / 'lib').iterdir():
            subprocess.run(['patchelf', '--set-rpath', '$ORIGIN', str(library)], check=True)
        clean = os.environ.copy()
        clean.pop('LD_LIBRARY_PATH', None)
        for binary in [plugin, *(stage / 'lib').iterdir()]:
            for name, resolved in dependencies(binary, clean):
                if not system_library(resolved) and not resolved.is_relative_to(stage):
                    raise ValueError(f'packaged dependency still escapes package: {name}')
        provenance = {
            'schema_version': 1, 'platform': 'linux-x86_64', 'version': '1.0.0',
            'source_binary_sha256': digest(arguments.binary), 'plugin_sha256': digest(plugin),
            'required_system_libraries': sorted(required_system),
            'bundled_libraries_sha256': {path.name: digest(path) for path in sorted((stage / 'lib').iterdir())},
        }
        (stage / 'package-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
        if sum(path.stat().st_size for path in stage.rglob('*') if path.is_file()) > 268435456:
            raise ValueError('package exceeds the host package byte limit')
        if output.exists():
            raise ValueError('output appeared during packaging; refusing to replace it')
        stage.rename(output)
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--sdk-root', type=Path)
    parser.add_argument('--validate', action='store_true')
    arguments = parser.parse_args()
    try:
        if arguments.output.resolve().exists():
            raise ValueError('output must be a new directory; existing packages are never merged or deleted')
        if not arguments.validate:
            package(arguments)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'web search package failed: {error}\n')


if __name__ == '__main__':
    main()

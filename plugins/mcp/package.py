#!/usr/bin/env python3
"""Bundle the independent MCP client endpoint and its Cangjie runtime closure."""
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


def stdx_notices(library_directory):
    if library_directory is None or not library_directory.is_dir():
        raise ValueError('the resolved StdX runtime library directory is required')
    directory = library_directory.resolve()
    # Supported StdX layouts put notices beside dynamic/stdx, or at one of
    # its two enclosing distribution directories. Never search arbitrary roots.
    for candidate in [directory, directory.parent, directory.parent.parent]:
        license_file = candidate / 'LICENSE'
        notice_file = candidate / 'Open_Source_Software_Notice.docx'
        if license_file.is_file() and notice_file.is_file():
            return license_file, notice_file
    raise ValueError('StdX LICENSE and Open_Source_Software_Notice.docx are required')


def package_identifier(value):
    if not re.fullmatch(r'[a-z0-9_-]{1,128}', value):
        raise ValueError('package id must be 1..128 lowercase ASCII letters, digits, hyphen or underscore')
    return value


def selected_manifest(identifier):
    manifest = json.loads((ROOT / 'axyndra.plugin.json').read_text())
    manifest['id'] = package_identifier(identifier)
    return manifest


def verify_clone_source(source):
    source = source.resolve()
    if not source.is_dir():
        raise ValueError('clone source must be an existing local independent package')
    files = [path for path in source.rglob('*') if path.is_file()]
    if any(path.is_symlink() for path in source.rglob('*')):
        raise ValueError('clone source must not contain symlinks')
    if sum(path.stat().st_size for path in files) > 268435456:
        raise ValueError('clone source exceeds the host package byte limit')
    manifest = json.loads((source / 'axyndra.plugin.json').read_text())
    if manifest != selected_manifest(manifest.get('id', '')):
        raise ValueError('clone source has a different immutable MCP manifest contract')
    provenance = json.loads((source / 'package-provenance.json').read_text())
    if any(provenance.get(key) != value for key, value in
           [('schema_version', 1), ('platform', 'linux-x86_64'), ('version', '1.0.0')]):
        raise ValueError('clone source has an unsupported provenance recipe')
    if not re.fullmatch(r'[0-9a-f]{64}', provenance.get('source_binary_sha256', '')):
        raise ValueError('clone source has no valid compiled-source digest')
    expected = {'axyndra.plugin.json', 'package-provenance.json', 'bin/mcp-client-plugin'}
    plugin = source / 'bin/mcp-client-plugin'
    if digest(plugin) != provenance.get('plugin_sha256') or not os.access(plugin, os.X_OK):
        raise ValueError('clone source executable differs from its provenance')
    if 'manifest_sha256' in provenance and digest(source / 'axyndra.plugin.json') != provenance['manifest_sha256']:
        raise ValueError('clone source manifest differs from its provenance')
    for directory, key in [('lib', 'bundled_libraries_sha256'), ('licenses', 'bundled_licenses_sha256')]:
        hashes = provenance.get(key)
        if not isinstance(hashes, dict) or not hashes or len(hashes) > 128:
            raise ValueError('clone source has an invalid runtime or license inventory')
        for name, sha in hashes.items():
            if not isinstance(name, str) or Path(name).name != name or name in ('.', '..'):
                raise ValueError('clone source inventory escapes its package')
            path = source / directory / name
            if not path.is_file() or digest(path) != sha:
                raise ValueError('clone source runtime or license digest differs')
            expected.add(directory + '/' + name)
    if {str(path.relative_to(source)) for path in files} != expected:
        raise ValueError('clone source contains undeclared or missing package files')
    clean = os.environ.copy()
    for name in ['LD_LIBRARY_PATH', 'LD_PRELOAD', 'LD_AUDIT']:
        clean.pop(name, None)
    system = set()
    for binary in [plugin, *(source / 'lib').iterdir()]:
        for name, resolved in dependencies(binary, clean):
            if system_library(resolved):
                system.add(name)
            elif not resolved.is_relative_to(source):
                raise ValueError('clone source runtime closure escapes the independent package')
    if provenance.get('required_system_libraries') != sorted(system):
        raise ValueError('clone source system runtime inventory differs from its provenance')
    return provenance


def clone_package(arguments):
    source = arguments.clone_source.resolve()
    provenance = verify_clone_source(source)
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.mcp-client-clone-', dir=output.parent) as temporary:
        stage = Path(temporary)
        shutil.copytree(source, stage, dirs_exist_ok=True)
        (stage / 'axyndra.plugin.json').write_text(json.dumps(selected_manifest(arguments.id), indent=2) + '\n')
        provenance['manifest_sha256'] = digest(stage / 'axyndra.plugin.json')
        (stage / 'package-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
        verify_clone_source(stage)
        if output.exists():
            raise ValueError('output appeared during cloning; refusing to replace it')
        stage.rename(output)
    print(output)
def package(arguments):
    if not arguments.binary or not arguments.binary.is_file():
        raise ValueError('compiled plugin is missing; run build-package.sh without --skip-build')
    if not arguments.sdk_root or not (arguments.sdk_root / 'LICENSE').is_file():
        raise ValueError('SDK runtime license is required')
    stdx_license, stdx_notice = stdx_notices(arguments.stdx_root)
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.mcp-client-package-', dir=output.parent) as temporary:
        stage = Path(temporary)
        for name in ['bin', 'lib', 'licenses']:
            (stage / name).mkdir()
        plugin = stage / 'bin/mcp-client-plugin'
        shutil.copy2(arguments.binary, plugin)
        plugin.chmod(0o755)
        (stage / 'axyndra.plugin.json').write_text(json.dumps(selected_manifest(arguments.id), indent=2) + '\n')
        shutil.copy2(arguments.sdk_root / 'LICENSE', stage / 'licenses/cangjie-runtime.txt')
        shutil.copy2(stdx_license, stage / 'licenses/cangjie-stdx.txt')
        shutil.copy2(stdx_notice, stage / 'licenses/cangjie-stdx-Open_Source_Software_Notice.docx')
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
            'manifest_sha256': digest(stage / 'axyndra.plugin.json'),
            'required_system_libraries': sorted(required_system),
            'bundled_libraries_sha256': {path.name: digest(path) for path in sorted((stage / 'lib').iterdir())},
            'bundled_licenses_sha256': {path.name: digest(path) for path in sorted((stage / 'licenses').iterdir())},
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
    parser.add_argument('--stdx-root', type=Path)
    parser.add_argument('--id', default='mcp-client', type=package_identifier)
    parser.add_argument('--clone-source', type=Path, help='verify and clone a local independent package without rebuilding its executable')
    parser.add_argument('--validate', action='store_true')
    arguments = parser.parse_args()
    try:
        if arguments.output.resolve().exists():
            raise ValueError('output must be a new directory; existing packages are never merged or deleted')
        if not arguments.validate:
            if arguments.clone_source:
                clone_package(arguments)
            else:
                package(arguments)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'MCP client package failed: {error}\n')


if __name__ == '__main__':
    main()

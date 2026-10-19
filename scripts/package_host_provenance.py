"""Publish byte provenance for a relocated host and its explicit distribution.

This metadata does not grant runtime capabilities or certify a build. The
source binary may be an explicit packaging input; its bytes are recorded.
"""
import argparse
import hashlib
import json
from pathlib import Path
import stat
from package_distribution import package_digest


def digest(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('provenance input must be a real regular file')
    before = path.stat()
    if before.st_size > 1073741824:
        raise ValueError('provenance input exceeds its byte bound')
    result = hashlib.sha256()
    count = 0
    with path.open('rb') as stream:
        while block := stream.read(65536):
            count += len(block)
            if count > before.st_size:
                raise ValueError('provenance input changed during hashing')
            result.update(block)
    after = path.stat()
    if count != before.st_size or path.is_symlink() or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError('provenance input changed during hashing')
    return result.hexdigest()


def publish(root, binary, recipe_path, profile, source_sha256, explicit_input=False):
    root, binary, recipe_path = Path(root), Path(binary), Path(recipe_path)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('host package must be a real fresh directory')
    if digest(binary) != source_sha256:
        raise ValueError('source binary changed after the packaging input was frozen')
    recipe = json.loads(recipe_path.read_bytes())
    if set(recipe) != {'schema', 'profiles'} or recipe['schema'] != 'axyndra.distribution-recipes/v1' or set(recipe['profiles']) != {'minimal', 'coding', 'full'}:
        raise ValueError('unsupported distribution recipes')
    selected = recipe['profiles'].get(profile)
    if not isinstance(selected, dict) or set(selected) != {'host_package', 'bundled', 'default_enabled', 'core_required'} or selected['host_package'] not in {'agent_minimal', 'agent_app'}:
        raise ValueError('invalid selected distribution recipe')
    for field in ['bundled', 'default_enabled', 'core_required']:
        values = selected[field]
        if not isinstance(values, list) or len(values) > 32 or len(set(values)) != len(values) or any(not isinstance(v, str) or not v.startswith('axyndra:') for v in values):
            raise ValueError('invalid distribution namespace list')
    bundled = set(selected['bundled'])
    if not set(selected['default_enabled']).issubset(bundled) or selected['core_required']:
        raise ValueError('optional plugin defaults cannot become Kernel requirements')
    if (profile == 'minimal' and (bundled or selected['host_package'] != 'agent_minimal')) or (profile != 'minimal' and selected['host_package'] != 'agent_app'):
        raise ValueError('distribution frontend does not match the reviewed recipe')
    manifest_path = root / 'share/axyndra/distribution.json'
    distribution = json.loads(manifest_path.read_bytes())
    if distribution.get('schema') != 'axyndra.distribution/v1' or distribution.get('id') != profile or not isinstance(distribution.get('plugins'), list):
        raise ValueError('distribution manifest identity changed')
    entries = distribution['plugins']
    if any(not isinstance(entry, dict) or set(entry) != {'path', 'namespace', 'version', 'package_digest', 'enabled'} or type(entry['enabled']) is not bool for entry in entries):
        raise ValueError('invalid sealed package entry')
    if len(entries) != len(bundled) or {entry['namespace'] for entry in entries} != bundled or {entry['namespace'] for entry in entries if entry['enabled']} != set(selected['default_enabled']):
        raise ValueError('actual bundled packages or defaults differ from the recipe')
    if profile == 'minimal' and (set(distribution) != {'schema', 'id', 'plugins', 'context'} or distribution.get('context') is not None):
        raise ValueError('Minimal permits only the empty distribution fields')
    for entry in entries:
        relative = entry['path']
        if not isinstance(relative, str) or '\\' in relative or relative.startswith('/') or any(part in {'', '.', '..'} for part in relative.split('/')):
            raise ValueError('sealed package path must be a fixed relative member')
        member = manifest_path.parent
        for part in relative.split('/'):
            member = member / part
            if member.is_symlink() or not member.is_dir():
                raise ValueError('sealed package path must contain real directories')
        if package_digest(member) != entry['package_digest']:
            raise ValueError('bundled package bytes changed after the distribution was sealed')
    # Runtime distribution parser remains the sole import/availability authority.
    # These independent hashes describe the exact packaging outputs only.
    files = {}
    for directory in ['bin', 'lib']:
        parent = root / directory
        if parent.is_symlink() or not parent.is_dir():
            raise ValueError('host output directory must be real')
        for path in parent.iterdir():
            if not stat.S_ISREG(path.lstat().st_mode):
                raise ValueError('host output contains a non-regular file')
            files[path.relative_to(root).as_posix()] = digest(path)
    result = dict(schema='axyndra.host-package-provenance/v1', distribution=profile,
        expected_host_package=selected['host_package'], explicit_source_input=bool(explicit_input),
        source_binary_sha256=source_sha256, packaged_binary_sha256=digest(root / 'bin/axyndra'),
        recipe_sha256=digest(recipe_path), distribution_manifest_sha256=digest(manifest_path),
        bundled=selected['bundled'], default_enabled=selected['default_enabled'], core_required=selected['core_required'],
        host_files=dict(sorted(files.items())), proves_actual_build=False)
    if digest(binary) != source_sha256:
        raise ValueError('source binary changed before provenance publication')
    output = root / 'package-provenance.json'
    with output.open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hash-file', type=Path)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--recipe', type=Path)
    parser.add_argument('--profile', choices=['minimal', 'coding', 'full'])
    parser.add_argument('--source-sha256')
    parser.add_argument('--explicit-input', action='store_true')
    args = parser.parse_args()
    if args.hash_file is not None:
        if any(value is not None for value in [args.root, args.binary, args.recipe, args.profile, args.source_sha256]) or args.explicit_input:
            parser.error('--hash-file must be used alone')
        print(digest(args.hash_file))
    else:
        if any(value is None for value in [args.root, args.binary, args.recipe, args.profile, args.source_sha256]):
            parser.error('root, binary, recipe, profile and source-sha256 are required')
        publish(args.root, args.binary, args.recipe, args.profile, args.source_sha256, args.explicit_input)

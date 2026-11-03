#!/usr/bin/env python3
"""Seal independent native package and policy defaults for the adjacent host."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import stat


def package_digest(root):
    """Exact axyndra-package-tree-v2 format used by inspectPluginPackage.

    Package bytes remain independently rechecked by Product before import.
    Hashing is streamed and bounded, not a trust shortcut or mtime cache.
    """
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('package root must be a real directory')
    files = []
    total = 0

    def visit(directory, depth):
        nonlocal total
        if depth > 64:
            raise ValueError('package depth exceeds the host bound')
        for path in directory.iterdir():
            relative = path.relative_to(root).as_posix()
            if relative in {'.git', '.hg', '.svn'}:
                continue
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ValueError('package symlink is forbidden')
            if stat.S_ISDIR(info.st_mode):
                visit(path, depth + 1)
            elif stat.S_ISREG(info.st_mode):
                total += info.st_size
                if len(files) >= 10000 or total > 268435456:
                    raise ValueError('package file or byte bound exceeded')
                files.append((relative, path, info.st_size))
            else:
                raise ValueError('package special file is forbidden')

    visit(root, 0)
    framing = bytearray(b'axyndra-package-tree-v2\n')
    for relative, path, size in sorted(files, key=lambda row: row[0].encode()):
        digest = hashlib.sha256()
        actual = 0
        with path.open('rb') as stream:
            while chunk := stream.read(65536):
                actual += len(chunk)
                if actual > size:
                    raise ValueError('package changed while hashing')
                digest.update(chunk)
        if actual != size or path.is_symlink() or path.stat().st_size != size:
            raise ValueError('package changed while hashing')
        executable = 'true' if os.access(path, os.X_OK) else 'false'
        framing += f'{len(relative.encode())}:{relative}:{executable}:{size}:{digest.hexdigest()}\n'.encode()
    return 'sha256:' + hashlib.sha256(framing).hexdigest()


def seal_distribution(root, profile, policies=None, read_scopes=None, packages=None):
    root = Path(root)
    profile = Path(profile)
    recipe = json.loads(profile.read_text(encoding='utf8'))
    if recipe.get('schema') == 'axyndra.minimal-profile/v1':
        if set(recipe) != {'schema', 'id', 'plugins', 'context'} or recipe['id'] != 'minimal' or recipe['plugins'] != [] or recipe['context'] is not None or any(value is not None for value in [policies, read_scopes, packages]):
            raise ValueError('Minimal profile permits no optional defaults or grants')
        if root.is_symlink() or not root.is_dir() or any(root.iterdir()):
            raise ValueError('Minimal distribution output must be a fresh real directory')
        result = {'schema': 'axyndra.distribution/v1', 'id': 'minimal', 'plugins': [], 'context': None}
        with (root / 'distribution.json').open('x', encoding='utf8', newline='\n') as stream:
            stream.write(json.dumps(result, indent=2) + '\n')
        return result
    if set(recipe) != {'schema', 'id', 'provider', 'context'} or recipe['schema'] != 'axyndra.context-profile/v1':
        raise ValueError('unsupported context profile')
    if not isinstance(recipe['id'], str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,63}', recipe['id']):
        raise ValueError('invalid distribution id')
    provider = recipe['provider']
    if not isinstance(provider, dict) or set(provider) != {'package', 'contribution', 'enabled_by_distribution'} or \
            provider['enabled_by_distribution'] is not True or not isinstance(provider['contribution'], str):
        raise ValueError('invalid provider recipe')
    relative = Path(provider['package'])
    if relative.is_absolute() or any(x in {'.', '..'} for x in relative.parts) or '\\' in provider['package']:
        raise ValueError('provider must be a fixed relative bundle member')
    package = root / relative
    if not package.resolve().is_relative_to(root.resolve()):
        raise ValueError('package escapes distribution')
    manifest = json.loads((package / 'axyndra.plugin.json').read_text(encoding='utf8'))
    if manifest['entry_kind'] != 'native-executable' or not any(
            c == {'kind': 'context_provider', 'name': provider['contribution']}
            for c in manifest['contributions']):
        raise ValueError('bundle lacks the selected native context provider')
    if recipe['context']['version'] != 4:
        raise ValueError('distributed roots require actual-workspace binding')
    namespace = 'axyndra:' + manifest['id']
    destination = root / 'profiles' / (recipe['id'] + '-context.json')
    if destination.exists() or (root / 'distribution.json').exists():
        raise ValueError('distribution output must be fresh')
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = {'schema': 'axyndra.distribution/v1', 'id': recipe['id'],
              'plugins': [{'path': relative.as_posix(), 'namespace': namespace,
                           'version': manifest['version'], 'package_digest': package_digest(package),
                           'enabled': provider['enabled_by_distribution']}],
              'context': {'namespace': namespace, 'recipe': destination.relative_to(root).as_posix(),
                          'sha256': hashlib.sha256(profile.read_bytes()).hexdigest()}}
    if policies is not None:
        policy_recipe = json.loads(Path(policies).read_text(encoding='utf8'))
        if not isinstance(policy_recipe, dict) or set(policy_recipe) != {'schema', 'bindings'} or policy_recipe['schema'] != 'axyndra.policy-defaults/v1':
            raise ValueError('invalid policy default recipe')
        if not isinstance(policy_recipe['bindings'], dict) or len(policy_recipe['bindings']) > 32:
            raise ValueError('invalid policy default bindings')
        selected = {}
        namespaces = {row['namespace'] for row in result['plugins']}
        for key, binding in policy_recipe['bindings'].items():
            workflow_plan = key == 'workflow' and isinstance(binding, dict) and 'plan_tool' in binding
            fields = {'package', 'provider', 'plan_tool'} if workflow_plan else {'package', 'provider'}
            if not re.fullmatch(r'[a-z][a-z0-9_-]{0,63}', key) or not isinstance(binding, dict) or set(binding) != fields:
                raise ValueError('invalid policy default')
            plan_tool = binding.get('plan_tool') if workflow_plan else None
            if workflow_plan and (not isinstance(plan_tool, str) or not re.fullmatch(r'[a-zA-Z0-9_.-]{1,128}', plan_tool)):
                raise ValueError('invalid selected Plan contribution')
            member = binding['package']
            if not isinstance(member, str) or not re.fullmatch(r'[a-zA-Z0-9_./-]+', member) or any(x in {'.','..',''} for x in member.split('/')) or member.startswith('/'):
                raise ValueError('policy package must be a fixed relative member')
            contribution = binding['provider']
            if not isinstance(contribution, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,128}', contribution):
                raise ValueError('invalid policy contribution')
            source = root / member
            actual = json.loads((source / 'axyndra.plugin.json').read_text(encoding='utf8'))
            if actual['entry_kind'] != 'native-executable' or {'kind': 'provider', 'name': contribution} not in actual['contributions']:
                raise ValueError('package lacks the declared pure Provider')
            if workflow_plan and {'kind': 'tool', 'name': plan_tool, 'execution_profile': 'data_only'} not in actual['contributions']:
                raise ValueError('package lacks the selected data-only Plan Tool')
            identity = 'axyndra:' + actual['id']
            if identity in namespaces:
                raise ValueError('duplicate package namespace in distribution')
            namespaces.add(identity)
            result['plugins'].append(dict(path=member, namespace=identity, version=actual['version'], package_digest=package_digest(source), enabled=True))
            selected[key] = dict(namespace=identity, provider=contribution)
            if workflow_plan:
                selected[key]['plan_tool'] = plan_tool
        result['policies'] = selected
    if packages is not None:
        package_recipe = json.loads(Path(packages).read_text(encoding='utf8'))
        if not isinstance(package_recipe, dict) or set(package_recipe) not in [{'schema', 'plugins'}, {'schema', 'plugins', 'workspace'}] or package_recipe['schema'] != 'axyndra.package-defaults/v1':
            raise ValueError('invalid bundled package recipe')
        members = package_recipe['plugins']
        if not isinstance(members, list) or len(members) > 32 - len(result['plugins']):
            raise ValueError('bundled package count exceeds the host bound')
        workspace_member = package_recipe.get('workspace')
        if workspace_member is not None and (not isinstance(workspace_member, str) or not any(
                isinstance(row, dict) and row.get('package') == workspace_member and row.get('enabled') is True for row in members)):
            raise ValueError('Workspace selection requires its enabled actual bundle member')
        namespaces = {entry['namespace'] for entry in result['plugins']}
        paths = {entry['path'] for entry in result['plugins']}
        for member in members:
            if not isinstance(member, dict) or set(member) != {'package', 'enabled'} or type(member['enabled']) is not bool:
                raise ValueError('package defaults contain only package and enabled')
            relative = member['package']
            if not isinstance(relative, str) or not re.fullmatch(r'[a-zA-Z0-9_./-]+', relative) or relative.startswith('/') or any(part in {'', '.', '..'} for part in relative.split('/')):
                raise ValueError('bundled package must be a fixed relative member')
            source = root
            for part in relative.split('/'):
                source = source / part
                if source.is_symlink() or not source.is_dir():
                    raise ValueError('bundled package path must contain only real directories')
            if not source.resolve().is_relative_to(root.resolve()):
                raise ValueError('bundled package escapes distribution')
            actual = json.loads((source / 'axyndra.plugin.json').read_text(encoding='utf8'))
            if actual.get('entry_kind') != 'native-executable' or not isinstance(actual.get('id'), str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,128}', actual['id']) or not isinstance(actual.get('version'), str) or not actual['version'] or len(actual['version'].encode()) > 256:
                raise ValueError('bundle member is not a versioned native package')
            if not isinstance(actual.get('contributions'), list) or not actual['contributions']:
                raise ValueError('bundled package declares no contribution')
            namespace = 'axyndra:' + actual['id']
            if namespace in namespaces or relative in paths:
                raise ValueError('duplicate bundled package path or namespace')
            namespaces.add(namespace)
            paths.add(relative)
            result['plugins'].append(dict(path=relative, namespace=namespace,
                version=actual['version'], package_digest=package_digest(source), enabled=member['enabled']))
            if relative == workspace_member:
                if actual.get('capabilities') != ['process.readview'] or actual['contributions'] != [
                        {'kind': 'tool', 'name': name} for name in ['read', 'grep', 'glob', 'edit', 'write']]:
                    raise ValueError('Workspace selection requires the exact native read-view contribution family')
                result['workspace'] = dict(namespace=namespace, package_digest=result['plugins'][-1]['package_digest'])
    if len(result['plugins']) > 32:
        raise ValueError('bundled package count exceeds the host bound')
    if read_scopes is not None:
        scopes = json.loads(Path(read_scopes).read_text(encoding='utf8'))
        if not isinstance(scopes, dict) or set(scopes) != {'version', 'roots'} or type(scopes['version']) is not int or scopes['version'] != 1 or not isinstance(scopes['roots'], list) or len(scopes['roots']) > 64:
            raise ValueError('invalid read scope defaults')
        seen = set()
        for item in scopes['roots']:
            if not isinstance(item, str) or not item.startswith('${settings_root}/') or len(item.encode()) > 4096 or item in seen:
                raise ValueError('read scope must be a unique settings-root template')
            suffix = item[17:]
            parts = suffix.split('/')
            if not suffix or any(part in {'', '.', '..'} for part in parts) or any(c in suffix for c in ['$', '\\', '\0']) or parts[0] == 'plugins' or any(part.lower() in {'.git','.hg','.svn','.ssh','.gnupg','.aws','.kube'} for part in parts) or '/credentials' in '/' + suffix.lower():
                raise ValueError('read scope must be a narrow ordinary data root')
            seen.add(item)
        result['read_scopes'] = scopes
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if len(encoded.encode()) > 65536:
        raise ValueError('distribution manifest exceeds its host bound')
    shutil.copyfile(profile, destination)
    with (root / 'distribution.json').open('x', encoding='utf8', newline='\n') as stream:
        stream.write(encoded)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--policies', type=Path)
    parser.add_argument('--read-scopes', type=Path)
    parser.add_argument('--packages', type=Path)
    args = parser.parse_args()
    seal_distribution(args.root, args.profile, args.policies, args.read_scopes, args.packages)

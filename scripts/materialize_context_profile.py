#!/usr/bin/env python3
"""Materialize an explicit distribution context recipe after provider installation.

This does not install/enable packages, grant reads, or overwrite operator policy.
The Product loader verifies the supplied exact installed namespace/package digest.
"""
import argparse
import json
from pathlib import Path
import re


def materialize(profile, *, settings_root, workspace_root, namespace, package_digest):
    if not isinstance(profile, dict) or set(profile) != {'schema', 'id', 'provider', 'context'} or \
            profile['schema'] != 'axyndra.context-profile/v1':
        raise ValueError('unsupported exact context profile')
    if not isinstance(namespace, str) or not namespace or '\0' in namespace or \
            not re.fullmatch(r'sha256:[0-9a-f]{64}', package_digest):
        raise ValueError('the actual installed provider binding is required')
    values = {'settings_root': Path(settings_root).resolve().as_posix(),
              'workspace_root': Path(workspace_root).resolve().as_posix(),
              'provider_namespace': namespace, 'provider_package_digest': package_digest}

    def expand(value):
        if isinstance(value, str):
            def variable(match):
                if match[1] not in values:
                    raise ValueError('unknown profile variable')
                return values[match[1]]
            return re.sub(r'\$\{([^}]+)\}', variable, value)
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        return value

    result = expand(profile['context'])
    encoded = json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n'
    if len(encoded.encode()) > 65536:
        raise ValueError('materialized operator configuration exceeds 64 KiB')
    return encoded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--settings-root', type=Path, required=True)
    parser.add_argument('--workspace-root', type=Path, required=True)
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--package-digest', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    encoded = materialize(json.loads(args.profile.read_text(encoding='utf-8')),
        settings_root=args.settings_root, workspace_root=args.workspace_root,
        namespace=args.namespace, package_digest=args.package_digest)
    # Exclusive create: a bundled default must never overwrite an operator's
    # existing selection or silently reverse an explicit disabled setting.
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(encoded)


if __name__ == '__main__':
    main()

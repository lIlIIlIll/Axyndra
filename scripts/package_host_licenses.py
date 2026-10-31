"""Copy the genuine licenses for the relocated host and bundled SDK libraries.

The separate provenance records exact license bytes only. It does not grant
runtime authority or certify that the host was built from a particular tree.
"""
import argparse
import json
from pathlib import Path
import shutil
from package_host_provenance import digest


def publish(root, sdk_root, stdx_root, repository_license):
    root, sdk_root, stdx_root = Path(root), Path(sdk_root), Path(stdx_root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('host license output must be a real directory')
    binary = root / 'bin/axyndra'
    binary_before = digest(binary)
    source_files = {
        'cangjie/LICENSE': sdk_root / 'LICENSE',
        'stdx/LICENSE': stdx_root.parent.parent / 'LICENSE',
        'stdx/Open_Source_Software_Notice.docx': stdx_root.parent.parent / 'Open_Source_Software_Notice.docx',
        'axyndra/LICENSE': Path(repository_license),
    }
    frozen = {name: digest(path) for name, path in source_files.items()}
    destination = root / 'licenses'
    if destination.exists() or destination.is_symlink() or (root / 'license-provenance.json').exists():
        raise ValueError('host licenses must be copied into a fresh output')
    destination.mkdir()
    copied = {}
    for name, source in sorted(source_files.items()):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if digest(target) != frozen[name] or digest(source) != frozen[name]:
            raise ValueError('host license bytes changed during copying')
        copied[name] = frozen[name]
    if digest(binary) != binary_before or any(digest(path) != frozen[name] for name, path in source_files.items()):
        raise ValueError('host or original license bytes changed before publication')
    value = dict(schema='axyndra.actual-host-license-copies/v1',
        packaged_binary_sha256=binary_before,
        source_files={str(path): frozen[name] for name, path in source_files.items()},
        license_files=copied, actual_build_claim=False)
    with (root / 'license-provenance.json').open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')
    return value


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--sdk-root', type=Path, required=True)
    parser.add_argument('--stdx-root', type=Path, required=True)
    parser.add_argument('--repository-license', type=Path, required=True)
    args = parser.parse_args()
    publish(args.root, args.sdk_root, args.stdx_root, args.repository_license)

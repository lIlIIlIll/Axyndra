#!/usr/bin/env bash
set -euo pipefail

version=${1:?usage: setup_ci_sdk.sh VERSION DESTINATION SHA256}
destination=${2:?destination required}
expected_sha256=${3:?published SDK SHA256 required}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]{14}$ && "$expected_sha256" =~ ^[a-f0-9]{64}$ ]] || exit 2
mkdir -p -- "$destination"
archive="$destination/cangjie-sdk-$version.tar.gz"
extract_root="$destination/cangjie-sdk-$version"
url="https://gitcode.com/Cangjie/nightly_build/releases/download/$version/cangjie-sdk-linux-x64-$version.tar.gz"
curl -fL --retry 3 --connect-timeout 20 --max-time 300 -o "$archive" "$url"
printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum --check --status
# No downloaded executable runs before archive verification. The data filter
# rejects absolute paths, escaping links and special files during extraction.
python3 - "$archive" "$extract_root" <<'PYTHON'
from pathlib import Path
import sys
import tarfile
archive, destination = map(Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=False)
with tarfile.open(archive) as source:
    source.extractall(destination, filter='data')
PYTHON
sdk_root="$extract_root/cangjie"
[[ -x "$sdk_root/bin/cjc" && -x "$sdk_root/tools/bin/cjpm" ]] || exit 2
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'AXYNDRA_CI_SDK_ACTUAL_SHA256=%s\nAXYNDRA_SDK_ROOT=%s\n' "$expected_sha256" "$sdk_root" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n%s\n' "$sdk_root/bin" "$sdk_root/tools/bin" >> "$GITHUB_PATH"
fi
printf '%s\n' "$sdk_root"

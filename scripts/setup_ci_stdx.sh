#!/usr/bin/env bash
set -euo pipefail

version=${1:-}
destination=${2:-}
expected_sha256=${3:-}
if [[ -z "$version" || -z "$destination" ]]; then
  printf 'usage: %s CANGJIE_VERSION DESTINATION [EXPECTED_SHA256]\n' "$0" >&2
  exit 2
fi

if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]{14}$ ]]; then
  # Nightly toolchains publish their matching stdx in the nightly_build
  # release stream, one archive per nightly version.
  archive_name="cangjie-stdx-linux-x64-$version.1.zip"
  url="https://gitcode.com/Cangjie/nightly_build/releases/download/$version/$archive_name"
elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  # Stable channels (lts/sts) publish stdx separately in cangjie_stdx
  # releases, tagged with the stdx version rather than the SDK version.
  stdx_version="$version.1"
  archive_name="cangjie-stdx-linux-x64-$stdx_version.zip"
  url="https://gitcode.com/Cangjie/cangjie_stdx/releases/download/v$stdx_version/$archive_name"
else
  printf 'axyndra: unsupported Cangjie version for stdx install: %s\n' "$version" >&2
  exit 2
fi

archive="$destination/$archive_name"
extract_root="$destination/cangjie-stdx-$version"

mkdir -p -- "$extract_root"
curl -fL --retry 3 --connect-timeout 20 -o "$archive" "$url"
actual_sha256=$(sha256sum "$archive" | cut -d " " -f1)
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf "AXYNDRA_CI_STDX_ACTUAL_SHA256=%s\n" "$actual_sha256" >> "$GITHUB_ENV"
fi
if [[ -n "$expected_sha256" ]]; then
  printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum --check --status
fi
unzip -tqq "$archive"
unzip -q -o "$archive" -d "$extract_root"

stdx_root="$extract_root/linux_x86_64_cjnative/dynamic/stdx"
if [[ ! -f "$stdx_root/libstdx.net.http.so" ]]; then
  printf 'axyndra: downloaded stdx is incomplete at %s\n' "$stdx_root" >&2
  exit 2
fi

printf '%s\n' "$stdx_root"

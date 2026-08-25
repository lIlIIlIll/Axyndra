#!/usr/bin/env bash
set -euo pipefail

version=${1:-}
destination=${2:-}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]{14}$ || -z "$destination" ]]; then
  printf 'usage: %s NIGHTLY_VERSION DESTINATION\n' "$0" >&2
  exit 2
fi

archive_name="cangjie-stdx-linux-x64-$version.1.zip"
archive="$destination/$archive_name"
extract_root="$destination/cangjie-stdx-$version"
url="https://gitcode.com/Cangjie/nightly_build/releases/download/$version/$archive_name"

mkdir -p -- "$extract_root"
curl -fL --retry 3 --connect-timeout 20 -o "$archive" "$url"
unzip -tqq "$archive"
unzip -q -o "$archive" -d "$extract_root"

stdx_root="$extract_root/linux_x86_64_cjnative/dynamic/stdx"
if [[ ! -f "$stdx_root/libstdx.net.http.so" ]]; then
  printf 'axyndra: downloaded nightly stdx is incomplete at %s\n' "$stdx_root" >&2
  exit 2
fi

printf '%s\n' "$stdx_root"

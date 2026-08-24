#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$root/libs/process4cj/native/process4cj_native.c"
output_file="$root/libs/process4cj/native/libprocess4cj_native.so"
compiler=/usr/lib/llvm15/bin/clang

if [[ ! -x "$compiler" ]]; then
  printf 'missing native dependency compiler: %s\n' "$compiler" >&2
  exit 2
fi

if [[ ! -f "$output_file" || "$source_file" -nt "$output_file" ]]; then
  "$compiler" -std=c11 -O2 -fPIC -shared \
    -Wl,-z,relro,-z,now \
    -o "$output_file" "$source_file"
fi

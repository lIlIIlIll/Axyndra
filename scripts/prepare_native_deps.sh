#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$root/libs/process4cj/native/process4cj_native.c"
output_file=${AXYNDRA_NATIVE_OUTPUT:-"$root/libs/process4cj/native/libprocess4cj_native.so"}
compiler_stamp="${output_file}.compiler-id"
compiler=$("$root/scripts/check_native_compiler.sh")
compiler_version=$("$compiler" --version 2>&1)

compiler_path=$(readlink -f -- "$compiler")
compiler_identity="$compiler_path|${compiler_version%%$'\n'*}"

cached_compiler_identity=
if [[ -f "$compiler_stamp" ]]; then
  IFS= read -r cached_compiler_identity < "$compiler_stamp" || true
fi
if [[ ! -f "$output_file" || "$source_file" -nt "$output_file" ||
      "$cached_compiler_identity" != "$compiler_identity" ]]; then
  mkdir -p -- "$(dirname -- "$output_file")"
  "$compiler" -std=c11 -O2 -fPIC -shared \
    -Wl,-z,relro,-z,now \
    -o "$output_file" "$source_file"
  stamp_tmp="${compiler_stamp}.$$"
  printf '%s\n' "$compiler_identity" > "$stamp_tmp"
  mv -f -- "$stamp_tmp" "$compiler_stamp"
fi

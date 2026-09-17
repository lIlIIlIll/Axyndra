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
  "$compiler" -std=c11 -O2 -fPIC -shared -Wl,-z,relro,-z,now -o "$output_file" "$source_file"
  stamp_tmp="${compiler_stamp}.$$"
  printf '%s\n' "$compiler_identity" > "$stamp_tmp"
  mv -f -- "$stamp_tmp" "$compiler_stamp"
fi

bridge_source="$root/libs/process4cj/native/sandbox_net_bridge.c"
bridge_output="${AXYNDRA_NETWORK_BRIDGE_OUTPUT:-$root/libs/process4cj/native/sandbox-net-bridge}"
bridge_stamp="${bridge_output}.compiler-id"
bridge_identity="$compiler_identity"
cached_bridge_identity=
if [[ -f "$bridge_stamp" ]]; then
  IFS= read -r cached_bridge_identity < "$bridge_stamp" || true
fi
needs_bridge_build=0
if [[ ! -x "$bridge_output" ]]; then
  needs_bridge_build=1
elif test "$bridge_source" -nt "$bridge_output"; then
  needs_bridge_build=1
elif [[ "$cached_bridge_identity" != "$bridge_identity" ]]; then
  needs_bridge_build=1
fi
if [[ "$needs_bridge_build" == 1 ]]; then
  mkdir -p -- "$(dirname -- "$bridge_output")"
  "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -Wl,-z,relro,-z,now -o "$bridge_output" "$bridge_source"
  chmod 0755 "$bridge_output"
  bridge_stamp_tmp="${bridge_stamp}.$$"
  printf '%s\n' "$bridge_identity" > "$bridge_stamp_tmp"
  mv -f -- "$bridge_stamp_tmp" "$bridge_stamp"
fi

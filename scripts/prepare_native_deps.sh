#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$root/libs/process4cj/native/process4cj_native.c"
output_file="$root/libs/process4cj/native/libprocess4cj_native.so"
compiler=${AXYNDRA_NATIVE_CC:-}
if [[ -z "$compiler" ]]; then
  compiler=$(command -v clang || true)
fi

if [[ -z "$compiler" || ! -x "$compiler" ]]; then
  printf 'missing native dependency compiler: set AXYNDRA_NATIVE_CC or install clang\n' >&2
  exit 2
fi

minimum_llvm=${AXYNDRA_MIN_LLVM_VERSION:-15}
compiler_version=$("$compiler" --version 2>&1 || true)
if [[ ! "$minimum_llvm" =~ ^[0-9]+$ || ! "$compiler_version" =~ [Cc]lang[[:space:]]version[[:space:]]([0-9]+) ]]; then
  printf 'cannot determine LLVM/Clang compatibility for native compiler: %s\n' "$compiler" >&2
  exit 2
fi
compiler_major=${BASH_REMATCH[1]}
if ((compiler_major < minimum_llvm)); then
  printf 'native dependency compiler requires LLVM/Clang >= %s, got: %s\n' \
    "$minimum_llvm" "${compiler_version%%$'\n'*}" >&2
  exit 2
fi

if ! "$compiler" -x c -std=c11 -fsyntax-only "$source_file"; then
  printf 'native dependency compiler lacks the required C11/Linux capabilities: %s\n' "$compiler" >&2
  exit 2
fi

if [[ ! -f "$output_file" || "$source_file" -nt "$output_file" ]]; then
  "$compiler" -std=c11 -O2 -fPIC -shared \
    -Wl,-z,relro,-z,now \
    -o "$output_file" "$source_file"
fi

#!/usr/bin/env bash
set -euo pipefail

# Native POSIX implementation only; Windows keeps its existing console fallback.
case "$(uname -s)" in Linux|Darwin) ;; *) exit 0 ;; esac
native_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compiler=${AXYNDRA_NATIVE_CC:-${CC:-clang}}
archiver=${AXYNDRA_NATIVE_AR:-${AR:-ar}}
output_dir="$native_root/target"
source_file="$native_root/terminal_signal.c"
output_file="$output_dir/libcjtui_terminal.a"
stamp="$output_dir/compiler-id"
identity="$compiler|$("$compiler" --version)"
identity+="|$archiver|$("$archiver" --version 2>&1 || true)"
cached_identity=
if [[ -f "$stamp" ]]; then cached_identity=$(<"$stamp"); fi
if [[ -f "$output_file" && "$source_file" -ot "$output_file" &&
      "${BASH_SOURCE[0]}" -ot "$output_file" && "$cached_identity" == "$identity" ]]; then
  exit 0
fi
mkdir -p -- "$output_dir"
# Unique intermediate names make concurrent independent build targets harmless.
work=$(mktemp -d "$output_dir/build.XXXXXX")
object="$work/terminal_signal.o"
archive="$work/libcjtui_terminal.a"
stamp_tmp="$work/compiler-id"
trap 'rm -rf -- "$work"' EXIT
"$compiler" -std=c11 -O2 -fPIC -Wall -Wextra -Werror -c "$source_file" -o "$object"
"$archiver" rcs "$archive" "$object"
printf '%s\n' "$identity" > "$stamp_tmp"
mv -f -- "$archive" "$output_file"
mv -f -- "$stamp_tmp" "$stamp"

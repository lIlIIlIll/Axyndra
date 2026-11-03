#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
flags=()
default_output="$root/target/native-plugin"
if [[ "${1:-}" == --service ]]; then
  flags+=(-DNATIVE_PLUGIN_TOOL=1 -DNATIVE_PLUGIN_SERVICE=1)
  default_output="$root/target/service/native-plugin-service"
  shift
elif [[ "${1:-}" == --tool ]]; then
  flags+=(-DNATIVE_PLUGIN_TOOL=1)
  default_output="$root/target/tool/native-plugin-tool"
  shift
fi
output=${1:-"$default_output"}
mkdir -p -- "$(dirname -- "$output")"
"${AXYNDRA_NATIVE_CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
  "${flags[@]}" "$root/main.c" -o "$output"
printf '%s\n' "$output"

#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sdk_root=$(DISABLE_ZOXIDE=1 "$root/scripts/check_sdk.sh")
source "$root/scripts/sdk_paths.sh"
stdx_root=$(resolve_cangjie_stdx_path "$sdk_root")
source_binary=${AXYNDRA_SOURCE_BINARY:-"$root/target/release/bin/agent_app"}
package_root=${AXYNDRA_PACKAGE_ROOT:-"$root/dist/axyndra"}
AWK=${AWK:-rp-awk}
GREP=${GREP:-rp-grep}
if ! command -v "$AWK" >/dev/null 2>&1; then
  AWK=awk
fi
if ! command -v "$GREP" >/dev/null 2>&1; then
  GREP=grep
fi

if [[ ! -x "$source_binary" ]]; then
  printf 'axyndra: build artifact is missing: %s\n' "$source_binary" >&2
  exit 2
fi
if ! command -v patchelf >/dev/null 2>&1; then
  printf 'axyndra: patchelf is required to package a relocatable candidate\n' >&2
  exit 2
fi

mkdir -p -- "$package_root/bin" "$package_root/lib" "$package_root/diagnostics"
cp -f -- "$source_binary" "$package_root/bin/axyndra"

runtime_paths=(
  "$root/libs/process4cj/native"
  "$sdk_root/runtime/lib/linux_x86_64_cjnative"
  "$sdk_root/tools/lib"
  "$stdx_root"
)
export LD_LIBRARY_PATH=$(IFS=:; printf '%s' "${runtime_paths[*]}")

queue=("$package_root/bin/axyndra")
seen='|'
while ((${#queue[@]})); do
  current=${queue[0]}
  queue=("${queue[@]:1}")
  while IFS='|' read -r needed dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*) continue ;;
    esac
    canonical=$(readlink -f -- "$dependency")
    [[ -n "$needed" ]] || needed=$(basename -- "$canonical")
    case "$seen" in *"|$needed|"*) continue ;; esac
    seen+="$needed|"
    destination="$package_root/lib/$needed"
    cp -f -- "$canonical" "$destination"
    queue+=("$destination")
  done < <(
    ldd "$current" | "$AWK" '
      /=> \/.* \(0x/ { print $1 "|" $3 }
      /^\/[[:graph:]]+ \(0x/ { print "|" $1 }
    '
  )
done

patchelf --set-rpath '$ORIGIN/../lib' "$package_root/bin/axyndra"
for library in "$package_root"/lib/*; do
  [[ -f "$library" ]] || continue
  patchelf --set-rpath '$ORIGIN' "$library"
done

env -u LD_LIBRARY_PATH ldd "$package_root/bin/axyndra" \
  > "$package_root/diagnostics/ldd.txt"
if "$GREP" -q 'not found' "$package_root/diagnostics/ldd.txt"; then
  cat "$package_root/diagnostics/ldd.txt" >&2
  exit 1
fi
printf '%s\n' "$package_root/bin/axyndra"

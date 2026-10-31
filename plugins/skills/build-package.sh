#!/usr/bin/env bash
set -euo pipefail
plugin_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$plugin_root/../.." && pwd)
output=''
skip_build=false
target_dir=''
content_args=()
while (($#)); do
  case "$1" in
    --output)
      if (($# < 2)); then printf 'missing output path\n' >&2; exit 2; fi
      output=$2; shift 2 ;;
    --target-dir)
      if (($# < 2)); then printf 'missing target directory\n' >&2; exit 2; fi
      target_dir=$2; shift 2 ;;
    --content-root)
      if (($# < 2)); then printf 'missing content root\n' >&2; exit 2; fi
      content_args=(--content-root "$2"); shift 2 ;;
    --skip-build) skip_build=true; shift ;;
    *) printf 'usage: %s --output NEW_DIRECTORY [--target-dir DIRECTORY] [--skip-build]\n' "$0" >&2; exit 2 ;;
  esac
done
if [[ -z "$output" || $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  printf 'a new output directory and x86_64 Linux are required\n' >&2
  exit 2
fi
command -v python3 >/dev/null
command -v patchelf >/dev/null
python3 "$plugin_root/package.py" --validate --output "$output"
if [[ "$skip_build" == true && -z "$target_dir" ]]; then
  printf '%s\n' '--skip-build requires the exact --target-dir to package' >&2
  exit 2
fi
target_dir=$(realpath -m -- "${target_dir:-${output}-build-target}")
if [[ "$skip_build" != true ]]; then
  (cd "$plugin_root" && "$root/scripts/pinned_cangjie" cjpm build --target-dir "$target_dir" >&2)
fi
sdk_root=$(DISABLE_ZOXIDE=1 "$root/scripts/check_sdk.sh")
source "$root/scripts/sdk_paths.sh"
stdx_root=$(resolve_cangjie_stdx_path "$sdk_root")
export LD_LIBRARY_PATH="$root/libs/process4cj/native:$sdk_root/runtime/lib/linux_x86_64_cjnative:$sdk_root/tools/lib:$stdx_root"
python3 "$plugin_root/package.py" --output "$output" --sdk-root "$sdk_root" \
  --binary "$target_dir/release/bin/main" --stdx-root "$stdx_root" "${content_args[@]}"

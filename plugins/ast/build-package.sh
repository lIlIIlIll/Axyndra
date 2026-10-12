#!/usr/bin/env bash
set -euo pipefail

plugin_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$plugin_root/../.." && pwd)
output=''
engine=''
engine_license=''
skip_build=false
while (($#)); do
  case "$1" in
    --output|--engine|--engine-license)
      if (($# < 2)); then printf 'missing value for %s\n' "$1" >&2; exit 2; fi
      case "$1" in
        --output) output=$2 ;;
        --engine) engine=$2 ;;
        --engine-license) engine_license=$2 ;;
      esac
      shift 2 ;;
    --skip-build) skip_build=true; shift ;;
    *) printf 'usage: %s --output NEW_DIRECTORY --engine AST_GREP --engine-license LICENSE [--skip-build]\n' "$0" >&2; exit 2 ;;
  esac
done
if [[ -z "$output" || -z "$engine" || -z "$engine_license" ]]; then
  printf 'output, pinned engine and its license must be supplied explicitly\n' >&2
  exit 2
fi
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  printf 'this package currently targets x86_64 Linux\n' >&2
  exit 2
fi
command -v python3 >/dev/null
command -v patchelf >/dev/null
python3 "$plugin_root/package.py" --validate --output "$output" \
  --engine "$engine" --engine-license "$engine_license"
if [[ "$skip_build" != true ]]; then
  (cd "$plugin_root" && "$root/scripts/pinned_cangjie" cjpm build >&2)
fi
sdk_root=$(DISABLE_ZOXIDE=1 "$root/scripts/check_sdk.sh")
source "$root/scripts/sdk_paths.sh"
stdx_root=$(resolve_cangjie_stdx_path "$sdk_root")
export LD_LIBRARY_PATH="$root/libs/process4cj/native:$sdk_root/runtime/lib/linux_x86_64_cjnative:$sdk_root/tools/lib:$stdx_root"
python3 "$plugin_root/package.py" --output "$output" --engine "$engine" \
  --engine-license "$engine_license" --sdk-root "$sdk_root" \
  --binary "$plugin_root/target/release/bin/main"

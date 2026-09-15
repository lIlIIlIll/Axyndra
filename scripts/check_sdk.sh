#!/usr/bin/env bash
set -euo pipefail

minimum_version=${AXYNDRA_MIN_CJC_VERSION:-1.1.0}
minimum_cjpm_version=${AXYNDRA_MIN_CJPM_VERSION:-1.1.0}
exact_toolchain=${AXYNDRA_REQUIRE_EXACT_TOOLCHAIN:-0}
expected_version=${AXYNDRA_CI_EXPECTED_CJC_VERSION:-1.1.3}
expected_cjpm_version=${AXYNDRA_CI_EXPECTED_CJPM_VERSION:-1.1.3}
sdk_root=${AXYNDRA_SDK_ROOT:-${CANGJIE_SDK_ROOT:-}}

if [[ -z "$sdk_root" ]]; then
  printf '%s\n' \
    'axyndra: set AXYNDRA_SDK_ROOT or CANGJIE_SDK_ROOT to the pinned Cangjie SDK' >&2
  exit 2
fi

sdk_root=$(readlink -f -- "$sdk_root")
if [[ -d "$sdk_root/cangjie" && ! -x "$sdk_root/bin/cjc" ]]; then
  sdk_root=$(readlink -f -- "$sdk_root/cangjie")
fi
cjc="$sdk_root/bin/cjc"
cjpm="$sdk_root/tools/bin/cjpm"
if [[ ! -x "$cjc" || ! -x "$cjpm" ]]; then
  printf 'axyndra: incomplete Cangjie SDK at %s (expected bin/cjc and tools/bin/cjpm)\n' \
    "$sdk_root" >&2
  exit 2
fi

# Version probes start the compiler and cjpm and used to cost roughly 300 ms
# for every short-lived CLI process. Cache only the successful validation of
# this exact immutable SDK fingerprint; executable path, size and mtime changes
# invalidate it. The cache never supplies an SDK path on its own.
cache_root=${AXYNDRA_SDK_CHECK_CACHE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/axyndra-sdk-check-${UID}}
cache_file=$cache_root/validation.cache
cjc_fingerprint=$(stat -Lc '%d:%i:%s:%Y' -- "$cjc")
cjpm_fingerprint=$(stat -Lc '%d:%i:%s:%Y' -- "$cjpm")
fingerprint="$sdk_root|$cjc_fingerprint|$cjpm_fingerprint|$minimum_version|$minimum_cjpm_version|$exact_toolchain|$expected_version|$expected_cjpm_version"
if [[ -f "$cache_file" && ! -L "$cache_file" && -O "$cache_file" ]]; then
  IFS= read -r cached_fingerprint < "$cache_file" || true
  if [[ "$cached_fingerprint" == "$fingerprint" ]]; then
    printf '%s\n' "$sdk_root"
    exit 0
  fi
fi

sdk_ld="$sdk_root/linux_x86_64_cjnative/dynamic/stdx:$sdk_root/runtime/lib/linux_x86_64_cjnative:$sdk_root/tools/lib"
cjc_version=$(env LD_LIBRARY_PATH="$sdk_ld" "$cjc" -v 2>&1 || true)
cjpm_version=$(env \
  PATH="$sdk_root/bin:$sdk_root/tools/bin:$PATH" \
  LD_LIBRARY_PATH="$sdk_ld" \
  "$cjpm" --version 2>&1 || true)
cjc_actual_version="${cjc_version#Cangjie Compiler: }"
cjc_actual_version="${cjc_actual_version%% *}"
cjpm_actual_version="${cjpm_version#Cangjie Project Manager: }"
cjpm_actual_version="${cjpm_actual_version%% *}"
version_core() {
  local version=$1
  if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-+].*)?$ ]]; then
    return 1
  fi
  printf '%09d%09d%09d\n' "$((10#${BASH_REMATCH[1]}))" \
    "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
}

require_supported_version() {
  local tool=$1 actual=$2 minimum=$3 raw=$4
  local actual_key minimum_key
  actual_key=$(version_core "$actual") || {
    printf 'axyndra: cannot parse %s version: %s\n' "$tool" "${raw//$'\n'/; }" >&2
    exit 2
  }
  minimum_key=$(version_core "$minimum") || {
    printf 'axyndra: invalid minimum %s version: %s\n' "$tool" "$minimum" >&2
    exit 2
  }
  if [[ "$actual_key" < "$minimum_key" ]]; then
    printf 'axyndra: unsupported %s; require >= %s, got: %s\n' \
      "$tool" "$minimum" "${raw//$'\n'/; }" >&2
    exit 2
  fi
}

require_supported_version cjc "$cjc_actual_version" "$minimum_version" "$cjc_version"
require_supported_version cjpm "$cjpm_actual_version" "$minimum_cjpm_version" "$cjpm_version"

if [[ "$exact_toolchain" == 1 && "$cjc_actual_version" != "$expected_version" ]]; then
  printf 'axyndra: release toolchain requires cjc %s, got: %s\n' \
    "$expected_version" "${cjc_version//$'\n'/; }" >&2
  exit 2
fi
if [[ "$exact_toolchain" == 1 && "$cjpm_actual_version" != "$expected_cjpm_version" ]]; then
  printf 'axyndra: release toolchain requires cjpm %s, got: %s\n' \
    "$expected_cjpm_version" "${cjpm_version//$'\n'/; }" >&2
  exit 2
fi

if [[ ! -e "$cache_root" ]]; then
  install -d -m 700 -- "$cache_root"
fi
if [[ -d "$cache_root" && ! -L "$cache_root" && -O "$cache_root" ]]; then
  chmod 700 -- "$cache_root"
  cache_tmp="$cache_file.$$"
  umask 077
  printf '%s\n' "$fingerprint" > "$cache_tmp"
  mv -f -- "$cache_tmp" "$cache_file"
fi

printf '%s\n' "$sdk_root"

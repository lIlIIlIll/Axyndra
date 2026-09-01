#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sdk_root=${AXYNDRA_SDK_ROOT:-/home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260817/cangjie}
export AXYNDRA_SDK_ROOT="$sdk_root"
work_root=$(mktemp -d /tmp/axyndra-package-readiness.XXXXXX)
mkdir -p "$work_root/logs"
log_sequence=0
GREP=${GREP:-rp-grep}
RG=${RG:-rp-rg}
if ! command -v "$GREP" >/dev/null 2>&1; then
  GREP=grep
fi
if ! command -v "$RG" >/dev/null 2>&1; then
  RG=rg
fi

cleanup() {
  if [[ ${AXYNDRA_KEEP_PACKAGE_WORKDIR:-0} == 1 ]]; then
    printf 'package readiness workdir retained: %s\n' "$work_root"
  else
    rm -rf -- "$work_root"
  fi
}
trap cleanup EXIT

run_cjpm() {
  local directory=$1
  shift
  log_sequence=$((log_sequence + 1))
  local label
  label=$(basename -- "$directory")
  local log_file="$work_root/logs/$(printf '%03d' "$log_sequence")-$label-$1.log"
  if ! (
    cd -- "$directory"
    AXYNDRA_SDK_ROOT="$sdk_root" DISABLE_ZOXIDE=1 "$root/scripts/pinned_cangjie" cjpm "$@"
  ) >"$log_file" 2>&1; then
    cat "$log_file" >&2
    return 1
  fi
  "$GREP" -E 'cjpm (check|build|test) success|Summary: TOTAL|Project tests finished|bundle success' "$log_file" | tail -n 8 || true
}

python3 "$root/scripts/package_readiness.py" self-test
python3 "$root/scripts/package_readiness.py" audit
python3 "$root/scripts/package_readiness.py" stage "$work_root/packages"
python3 "$root/scripts/package_readiness.py" stage "$work_root/packages-second"
python3 "$root/scripts/package_readiness.py" compare "$work_root/packages" "$work_root/packages-second"
python3 "$root/scripts/package_readiness.py" materialize-consumers "$work_root/packages" "$work_root/consumers"
python3 "$root/scripts/package_readiness.py" materialize-validation "$work_root/packages" "$work_root/validation"

public_packages=(
  yjson_support jsonrpc4cj process4cj mcp4cj sandbox4cj
  lsp4cj dap4cj agent_sdk axyndra_agent_testkit
)
for package in "${public_packages[@]}"; do
  printf '== staged package %s ==\n' "$package"
  run_cjpm "$work_root/validation/$package" check
  run_cjpm "$work_root/validation/$package" build
  run_cjpm "$work_root/validation/$package" test
done

for consumer in "${public_packages[@]}"; do
  printf '== external consumer %s ==\n' "$consumer"
  run_cjpm "$work_root/consumers/$consumer" check
  run_cjpm "$work_root/consumers/$consumer" build
  run_cjpm "$work_root/consumers/$consumer" test
  if [[ -x "$work_root/consumers/$consumer/target/release/bin/main" ]]; then
    (
      cd -- "$work_root/consumers/$consumer"
      AXYNDRA_SDK_ROOT="$sdk_root" DISABLE_ZOXIDE=1 \
        "$root/scripts/pinned_cangjie" target/release/bin/main
    )
  fi
done

if "$RG" -n '/home/elliot/playground/learn_agent_cj|\.\./libs/|\.\./agent_sdk|\.\./axyndra_agent_testkit' \
  "$work_root/packages" "$work_root/consumers" \
  --glob '!target/**' --glob '!package-inventory.json'; then
  printf 'package readiness: monorepo fallback found in staged package or consumer\n' >&2
  exit 1
fi

process_package="$work_root/packages/process4cj-0.1.0"
[[ -f "$process_package/native/process4cj_native.c" ]]
[[ -f "$process_package/native/libprocess4cj_native.a" ]]
if find "$process_package" -name '*.so' -print -quit | "$GREP" -q .; then
  printf 'package readiness: process4cj candidate unexpectedly contains a dynamic library\n' >&2
  exit 1
fi

process_binary="$work_root/consumers/process4cj/target/release/bin/main"
if readelf -d "$process_binary" | "$GREP" -E 'RPATH|RUNPATH' | "$GREP" -q '/home/|learn_agent_cj'; then
  printf 'package readiness: process consumer has an absolute developer RPATH\n' >&2
  exit 1
fi
if ldd "$process_binary" | "$GREP" -q 'libprocess4cj_native'; then
  printf 'package readiness: process consumer retained a dynamic process4cj native dependency\n' >&2
  exit 1
fi

AXYNDRA_SOURCE_BINARY="$process_binary" \
AXYNDRA_PACKAGE_ROOT="$work_root/process-runtime" \
AXYNDRA_SDK_ROOT="$sdk_root" \
  "$root/scripts/package_candidate.sh" >/dev/null
env -u LD_LIBRARY_PATH "$work_root/process-runtime/bin/axyndra"
if "$GREP" -q 'not found' "$work_root/process-runtime/diagnostics/ldd.txt"; then
  cat "$work_root/process-runtime/diagnostics/ldd.txt" >&2
  exit 1
fi

if [[ ${AXYNDRA_PACKAGE_TECHNICAL_ONLY:-0} != 1 ]]; then
  python3 "$root/scripts/package_readiness.py" audit --require-publication-metadata
fi

printf 'package readiness gate passed: %s\n' "$work_root"

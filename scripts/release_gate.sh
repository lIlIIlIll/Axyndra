#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
gate_kind=${AXYNDRA_GATE_KIND:-release}
if [[ "$gate_kind" != "release" && "$gate_kind" != "implementation" ]]; then
  printf 'unsupported AXYNDRA_GATE_KIND: %s\n' "$gate_kind" >&2
  exit 2
fi

if [[ "$gate_kind" == "release" ]]; then
  if [[ "${AXYNDRA_REAL_SMOKE:-0}" != "1" ]]; then
    printf '%s\n' \
      'release gate requires AXYNDRA_REAL_SMOKE=1 and DEEPSEEK_API_KEY' \
      >&2
    exit 2
  fi
  if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
    printf 'release gate requires DEEPSEEK_API_KEY\n' >&2
    exit 2
  fi
fi

mapfile -t contracts < "$root/scripts/release_contracts.txt"
contract_timeout_seconds=${AXYNDRA_CONTRACT_TIMEOUT_SECONDS:-180}
if [[ ! "$contract_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'AXYNDRA_CONTRACT_TIMEOUT_SECONDS must be a positive integer\n' >&2
  exit 2
fi
for contract in "${contracts[@]}"; do
  if [[ ! -f "$root/support_tests/$contract/cjpm.toml" ||
        ! -d "$root/support_tests/$contract/src" ]]; then
    printf 'release contract source closure is missing: %s\n' "$contract" >&2
    exit 2
  fi
done

cd "$root"
python3 scripts/tracked_artifact_gate.py
python3 scripts/docs_gate.py
sdk_root=$(DISABLE_ZOXIDE=1 "$root/scripts/check_sdk.sh")
source "$root/scripts/sdk_paths.sh"
stdx_root=$(resolve_cangjie_stdx_path "$sdk_root")
export CANGJIE_STDX_PATH="$stdx_root"
export LD_LIBRARY_PATH="$root/libs/process4cj/native:$stdx_root:$sdk_root/runtime/lib/linux_x86_64_cjnative:$sdk_root/tools/lib"
"$root/scripts/pinned_cangjie" cjpm build -m agent_app -o agent_app
package_root=$(mktemp -d -t axyndra-candidate.XXXXXX)
candidate=$(
  AXYNDRA_SDK_ROOT="$sdk_root" \
  AXYNDRA_PACKAGE_ROOT="$package_root" \
    "$root/scripts/package_candidate.sh"
)
"$root/scripts/pinned_cangjie" cjc -v \
  > "$package_root/diagnostics/cjc-version.txt" 2>&1
"$root/scripts/pinned_cangjie" cjpm --version \
  > "$package_root/diagnostics/cjpm-version.txt" 2>&1
bash scripts/architecture_gate.sh
python3 scripts/tui_visual_showcase_test.py
python3 scripts/vnext_contract_gate.py --sdk-root "$sdk_root"
AXYNDRA_PACKAGE_TECHNICAL_ONLY=1 \
AXYNDRA_SDK_ROOT="$sdk_root" \
  bash scripts/package_readiness_gate.sh

for contract in "${contracts[@]}"; do
  printf 'release contract: %s\n' "$contract"
  contract_root="$root/support_tests/$contract"
  (
    cd "$contract_root"
    "$root/scripts/pinned_cangjie" cjpm clean
    "$root/scripts/pinned_cangjie" cjpm build
    timeout --foreground --signal=TERM --kill-after=5s \
      "${contract_timeout_seconds}s" \
      "$root/scripts/pinned_cangjie" target/release/bin/main
  )
done

# This contract owns a malicious loopback fixture and therefore cannot use the
# generic no-argument executable runner above.
timeout --foreground --signal=TERM --kill-after=5s \
  "${contract_timeout_seconds}s" \
  bash support_tests/native_provider_security_contract/check.sh

(
  cd "$root/support_tests/provider_driver"
  "$root/scripts/pinned_cangjie" cjpm clean
  "$root/scripts/pinned_cangjie" cjpm build
)

AXYNDRA_BINARY="$candidate" python3 support_tests/setup_blackbox/check.py
AXYNDRA_BINARY="$candidate" python3 support_tests/package_candidate_clean_env/check.py
AXYNDRA_BINARY="$candidate" python3 support_tests/provider_profiles_blackbox/check.py
AXYNDRA_BINARY="$candidate" python3 support_tests/entry_modes_blackbox/check.py
AXYNDRA_BINARY="$candidate" python3 support_tests/acp_blackbox/check.py
python3 support_tests/process_broker_blackbox/check.py --candidate "$candidate"
bash support_tests/provider_blackbox/check.sh "$candidate"
if [[ "$gate_kind" == "release" ]]; then
  AXYNDRA_BINARY="$candidate" python3 support_tests/provider_real_smoke/check.py
fi

python3 scripts/cold_start_gate.py \
  --candidate "$candidate" \
  --diagnostics "$package_root/diagnostics"

python3 scripts/tui_golden_gate.py \
  --candidate "$candidate --fixture" \
  --scenario cards \
  --scenario default \
  --scenario initial-prompt \
  --scenario todo \
  --scenario ask
python3 scripts/tui_performance_gate.py \
  --candidate "$candidate --fixture"
AGENT_TUI_HEADLESS=1 \
AGENT_TUI_HEADLESS_DOCUMENT_PERF=1 \
  "$candidate" --fixture
AGENT_TUI_HEADLESS=1 \
AGENT_TUI_HEADLESS_COMPOSER_PERF=1 \
  "$candidate" --fixture
tui_setup_home=$(mktemp -d -t axyndra-tui-setup.XXXXXX)
trap 'rm -rf -- "$tui_setup_home"' EXIT
tui_setup_output=$(
  AXYNDRA_HOME="$tui_setup_home" \
  AGENT_TUI_HEADLESS=1 \
  AGENT_TUI_HEADLESS_SETUP=1 \
    "$candidate"
)
printf '%s\n' "$tui_setup_output"
if [[ "$tui_setup_output" != *"tui golden ok sizes="* ]]; then
  printf 'tui setup smoke did not report semantic success\n' >&2
  exit 1
fi
test -f "$tui_setup_home/config.yml"
test -f "$tui_setup_home/providers.yml"
test -f "$tui_setup_home/models.yml"
rm -rf -- "$tui_setup_home"
trap - EXIT

if [[ "$gate_kind" == "release" ]]; then
  printf 'axyndra release gate passed\n'
else
  printf 'axyndra implementation gate passed (real-provider smoke not run)\n'
fi

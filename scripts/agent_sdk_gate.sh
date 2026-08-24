#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${AXYNDRA_SDK_ROOT:=/home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260817/cangjie}"
export AXYNDRA_SDK_ROOT

python3 "$ROOT/scripts/check_library_boundaries.py"
python3 "$ROOT/scripts/check_sdk_compatibility.py"
python3 "$ROOT/scripts/check_sdk_compatibility.py" --self-test

for package in \
  agent_sdk \
  axyndra_agent_testkit \
  agent_extension_runtime \
  extensions/ast_extension \
  extensions/web_search_extension \
  extensions/workspace_search_extension \
  extensions/workspace_write_extension; do
  (cd "$ROOT/$package" && "$ROOT/scripts/pinned_cangjie" cjpm check)
done

(cd "$ROOT/axyndra_agent_testkit" && "$ROOT/scripts/pinned_cangjie" cjpm test)
(cd "$ROOT/support_tests/testkit_consumer" && \
  "$ROOT/scripts/pinned_cangjie" cjpm check && \
  "$ROOT/scripts/pinned_cangjie" cjpm build && \
  "$ROOT/scripts/pinned_cangjie" cjpm test)
(cd "$ROOT/support_tests/testkit_extension_contract" && \
  "$ROOT/scripts/pinned_cangjie" cjpm run)

(cd "$ROOT/support_tests/sdk_fixture_extension_runner" && \
  "$ROOT/scripts/pinned_cangjie" cjpm run)
(cd "$ROOT/support_tests/extensions_contract" && \
  "$ROOT/scripts/pinned_cangjie" cjpm run)
(cd "$ROOT/support_tests/extension_runtime_contract" && \
  "$ROOT/scripts/pinned_cangjie" cjpm run)

printf '%s\n' 'agent_sdk gate passed'

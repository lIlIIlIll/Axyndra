#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
python3 scripts/product_unit_gate_test.py
python3 scripts/ci_evidence_test.py
bash scripts/check_atomic_workspace.sh
python3 support_tests/frontend_regressions/check.py all
python3 support_tests/process_broker_blackbox/check.py --candidate "${AXYNDRA_BINARY:-$root/target/release/bin/agent_app}"
(
  cd support_tests/web_search_contract
  "$root/scripts/pinned_cangjie" cjpm build
  "$root/scripts/pinned_cangjie" python3 local_fixture.py --candidate target/release/bin/main
)

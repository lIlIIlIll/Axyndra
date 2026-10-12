#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
python3 scripts/product_unit_gate_test.py
python3 scripts/rpc_unit_isolation_test.py
python3 scripts/ci_evidence_test.py
bash scripts/check_atomic_workspace.sh
# Keep this gate self-contained. Earlier CI stages and focused contracts may use
# separate target trees or clean/rebuild workspace artifacts.
"$root/scripts/pinned_cangjie" cjpm build -m agent_app -o agent_app
python3 support_tests/frontend_regressions/check.py all
python3 support_tests/process_broker_blackbox/check.py --candidate "${AXYNDRA_BINARY:-$root/target/release/bin/agent_app}"
# Build real base/update packages and exercise no-model maintenance, invocation,
# durable HTTP authority and the complete local plugin lifecycle.
bash support_tests/plugin_cli_blackbox/run.sh --candidate "${AXYNDRA_BINARY:-$root/target/release/bin/agent_app}"
# Build the independent web package and exercise the real Product HTTP broker,
# operator grants, credentials, approval, bounded transport and cancellation.
python3 scripts/product_unit_gate.py --package agent_product --case-prefix PluginHttp \
  --output-dir "${AXYNDRA_EVIDENCE_DIR:-target/gate-evidence}/http-regression"

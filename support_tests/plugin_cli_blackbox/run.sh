#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
# The gate builds independent plugin fixtures only; the caller builds the app.
exec "$root/scripts/pinned_cangjie" python3 "$root/support_tests/plugin_cli_blackbox/run.py" "$@"

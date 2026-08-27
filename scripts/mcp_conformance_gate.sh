#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture="$root/support_tests/mcp_conformance_server"
conformance_package=${MCP_CONFORMANCE_PACKAGE:-@modelcontextprotocol/conformance@0.2.0-alpha.11}
port=${MCP_CONFORMANCE_PORT:-31341}
work_root=$(mktemp -d /tmp/mcp4cj-conformance.XXXXXX)
server_log="$work_root/server.log"
server_pid=

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ ${MCP_CONFORMANCE_KEEP_WORKDIR:-0} == 1 ]]; then
    printf 'MCP conformance workdir retained: %s\n' "$work_root"
  else
    rm -rf -- "$work_root"
  fi
}
trap cleanup EXIT

(
  cd -- "$fixture"
  "$root/scripts/pinned_cangjie" cjpm build
)

"$root/scripts/pinned_cangjie" "$fixture/target/release/bin/main" "$port" >"$server_log" 2>&1 &
server_pid=$!

http_code=000
for _ in {1..40}; do
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/mcp" || true)
  if [[ "$http_code" != 000 ]]; then
    break
  fi
  sleep 0.25
done
if [[ "$http_code" == 000 ]]; then
  cat "$server_log" >&2
  printf 'MCP conformance fixture did not become ready\n' >&2
  exit 1
fi

npx --yes "$conformance_package" server \
  --url "http://127.0.0.1:$port/mcp" \
  --requirements 2026-07-28 \
  --output-dir "$work_root/results"

printf 'MCP 2026-07-28 conformance requirements passed with no expected-failure baseline\n'

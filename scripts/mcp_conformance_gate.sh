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

failure_count=0
known_runner_failure_count=0
unexpected_report="$work_root/unexpected-results.tsv"
: >"$unexpected_report"

for checks in "$work_root"/results/server-*/checks.json; do
  failure_rows="$work_root/failure-rows.tsv"
  warning_rows="$work_root/warning-rows.tsv"
  if ! jq -e '
    type == "array" and length > 0 and
    all(.[]; type == "object" and (.id | type == "string") and (.status | type == "string"))
  ' "$checks" >/dev/null; then
    printf 'Invalid or empty MCP conformance report: %s\n' "$checks" >&2
    exit 1
  fi
  if ! jq -r '
    .[] | select(.status == "FAILURE") |
    [
      .id,
      (((.details.violations // []) | length) > 0 and
       all(.details.violations[];
         .origin == "implementation" and
         .specVersion == "2026-07-28" and
         .context == "response to '\''tools/call'\''" and
         .message.result.resultType == "task" and
         (.errors == ["CallToolResult: must have required property '\''content'\'' (result of '\''tools/call'\'')"])
       ))
    ] | @tsv
  ' "$checks" >"$failure_rows"; then
    printf 'Unable to parse MCP conformance failure rows: %s\n' "$checks" >&2
    exit 1
  fi
  while IFS=$'\t' read -r id known_task_schema_mismatch; do
    failure_count=$((failure_count + 1))
    known_scenario=false
    case "$checks" in
      */server-tasks-lifecycle-*|*/server-tasks-capability-negotiation-*|*/server-tasks-wire-fields-*|*/server-tasks-request-state-removal-*|*/server-tasks-mrtr-input-*|*/server-tasks-request-headers-*|*/server-tasks-dispatch-and-envelope-*|*/server-tasks-mrtr-composition-*)
        known_scenario=true
        ;;
    esac
    if [[ "$id" == wire-schema-valid && "$known_scenario" == true && "$known_task_schema_mismatch" == true ]]; then
      known_runner_failure_count=$((known_runner_failure_count + 1))
    else
      printf '%s\tFAILURE\t%s\n' "$checks" "$id" >>"$unexpected_report"
    fi
  done <"$failure_rows"

  if ! jq -r '.[] | select(.status == "WARNING" or .status == "SKIPPED") | [.status, .id] | @tsv' \
    "$checks" >"$warning_rows"; then
    printf 'Unable to parse MCP conformance warning rows: %s\n' "$checks" >&2
    exit 1
  fi
  while IFS=$'\t' read -r status id; do
    allowed_skip=false
    if [[ "$status" == SKIPPED ]]; then
      case "$id" in
        tasks-status-notifications|sep-2575-server-sends-prompts-list-changed-on-subscription|sep-2575-server-sends-tools-list-changed-on-subscription)
          allowed_skip=true
          ;;
      esac
    fi
    if [[ "$allowed_skip" != true ]]; then
      printf '%s\t%s\t%s\n' "$checks" "$status" "$id" >>"$unexpected_report"
    fi
  done <"$warning_rows"
done

if [[ -s "$unexpected_report" ]]; then
  printf 'Unexpected MCP conformance failures, warnings, or skips:\n' >&2
  cat "$unexpected_report" >&2
  exit 1
fi

printf 'MCP 2026-07-28 conformance passed; %d/%d failures are the pinned runner task-result schema mismatch\n' \
  "$known_runner_failure_count" "$failure_count"

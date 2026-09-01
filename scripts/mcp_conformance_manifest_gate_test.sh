#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work_root=$(mktemp -d /tmp/mcp4cj-manifest-test.XXXXXX)
trap 'rm -rf -- "$work_root"' EXIT

mkdir -p -- "$work_root/server-server-stateless-2026-09-01"
printf '[{"id":"anything","status":"SUCCESS"}]\n' \
  >"$work_root/server-server-stateless-2026-09-01/checks.json"

if bash "$root/scripts/mcp_conformance_manifest_gate.sh" "$work_root" >/dev/null 2>&1; then
  printf 'truncated MCP conformance report set was accepted\n' >&2
  exit 1
fi

rm -rf -- "$work_root"/*
while read -r _ scenario; do
  report="$work_root/server-$scenario-2026-09-01"
  mkdir -p -- "$report"
  printf '[{"id":"anything","status":"SUCCESS"}]\n' >"$report/checks.json"
done <"$root/scripts/mcp_conformance_2026_07_28_checks.sha256"
if bash "$root/scripts/mcp_conformance_manifest_gate.sh" "$work_root" >/dev/null 2>&1; then
  printf 'complete scenario set with arbitrary check IDs was accepted\n' >&2
  exit 1
fi

printf 'MCP conformance manifest regression passed\n'

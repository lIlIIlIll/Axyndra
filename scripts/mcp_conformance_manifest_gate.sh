#!/usr/bin/env bash
set -euo pipefail

results=${1:?usage: mcp_conformance_manifest_gate.sh RESULTS_DIR}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
check_manifest="$root/scripts/mcp_conformance_2026_07_28_checks.sha256"

# Frozen by @modelcontextprotocol/conformance@0.2.0-alpha.11 for the
# 2026-07-28 server requirement set. Keep this list explicit so a successful
# runner exit cannot hide partial scenario discovery or report generation.
expected_scenarios=(
  server-stateless
  completion-complete
  tools-list
  tools-call-simple-text
  tools-call-image
  tools-call-audio
  tools-call-embedded-resource
  tools-call-mixed-content
  tools-call-error
  tools-call-with-progress
  server-sse-multiple-streams
  resources-list
  resources-read-text
  resources-read-binary
  resources-templates-read
  sep-2164-resource-not-found
  prompts-list
  prompts-get-simple
  prompts-get-with-args
  prompts-get-embedded-resource
  prompts-get-with-image
  dns-rebinding-protection
  caching
  input-required-result-basic-elicitation
  input-required-result-basic-sampling
  input-required-result-basic-list-roots
  input-required-result-request-state
  input-required-result-multiple-input-requests
  input-required-result-multi-round
  input-required-result-missing-input-response
  input-required-result-non-tool-request
  input-required-result-result-type
  input-required-result-unsupported-methods
  input-required-result-tampered-state
  input-required-result-capability-check
  input-required-result-ignore-extra-params
  input-required-result-validate-input
  tasks-lifecycle
  tasks-capability-negotiation
  tasks-wire-fields
  tasks-request-state-removal
  tasks-mrtr-input
  tasks-request-headers
  tasks-dispatch-and-envelope
  tasks-status-notifications
  tasks-required-task-error
  tasks-mrtr-composition
  json-schema-2020-12
  http-header-validation
  http-custom-header-server-validation
)

shopt -s nullglob
all_reports=("$results"/server-*/checks.json)
if [[ ${#all_reports[@]} -ne ${#expected_scenarios[@]} ]]; then
  printf 'Incomplete MCP conformance report set: expected %d reports, found %d\n' \
    "${#expected_scenarios[@]}" "${#all_reports[@]}" >&2
  exit 1
fi

for scenario in "${expected_scenarios[@]}"; do
  reports=("$results/server-$scenario-"*/checks.json)
  if [[ ${#reports[@]} -ne 1 ]]; then
    printf 'Missing or duplicate MCP conformance report for scenario %s: found %d\n' \
      "$scenario" "${#reports[@]}" >&2
    exit 1
  fi
  if ! jq -e '
    type == "array" and length > 0 and
    all(.[];
      type == "object" and (.id | type == "string" and length > 0) and
      (.status == "SUCCESS" or .status == "FAILURE" or .status == "WARNING" or .status == "SKIPPED")
    )
  ' "${reports[0]}" >/dev/null; then
    printf 'Invalid MCP conformance check manifest: %s\n' "${reports[0]}" >&2
    exit 1
  fi
  expected_digest=$(awk -v scenario="$scenario" '$2 == scenario { print $1 }' "$check_manifest")
  actual_digest=$(jq -r '.[].id' "${reports[0]}" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
  if [[ -z "$expected_digest" || "$actual_digest" != "$expected_digest" ]]; then
    printf 'MCP conformance check-ID manifest mismatch for scenario %s\n' "$scenario" >&2
    exit 1
  fi
done

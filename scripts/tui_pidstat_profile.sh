#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-"$root/perf_results/tui/profiles/baseline/pidstat-stream.txt"}
mkdir -p -- "$(dirname -- "$output")"

AXYNDRA_SDK_ROOT=${AXYNDRA_SDK_ROOT:?set AXYNDRA_SDK_ROOT} \
python3 "$root/scripts/tui_pty_bench.py" \
  --candidate "$root/scripts/pinned_cangjie $root/target/release/bin/agent_app --fixture" \
  --output /tmp/axyndra-profile-pidstat \
  --scenarios stream \
  --data-counts 10000 \
  --runs 1 \
  --stream-chunks 100 \
  --timeout 10 &
benchmark_pid=$!

agent_pid=""
for _ in $(seq 1 100); do
  agent_pid=$(pgrep -n -x agent_app || true)
  if [[ -n "$agent_pid" ]]; then
    break
  fi
  sleep 0.05
done
if [[ -z "$agent_pid" ]]; then
  kill "$benchmark_pid" 2>/dev/null || true
  wait "$benchmark_pid" || true
  printf '%s\n' 'agent_app did not start' >&2
  exit 1
fi

pidstat -durw -h -p "$agent_pid" 1 8 > "$output"
wait "$benchmark_pid"

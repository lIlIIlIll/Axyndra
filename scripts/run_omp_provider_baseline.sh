#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
port=${OMP_COMPAT_PROVIDER_PORT:?OMP_COMPAT_PROVIDER_PORT is required}

OMP_BASELINE_OPENAI_BASE_URL="http://127.0.0.1:$port/v1" \
  exec "$root/scripts/run_omp_baseline.sh" \
    --mode json \
    --provider axyndra-blackbox \
    --model blackbox-model \
    --no-session \
    --approval-mode trusted \
    "$@"

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
sdk_root="${CANGJIE_SDK_ROOT:-/home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260817/cangjie}"

export DISABLE_ZOXIDE=1
exec /home/elliot/.codex/scripts/codex_cangjie_env \
  --sdk-root "$sdk_root" \
  --cwd "$repo_root/support_tests/artifact_contract" \
  cjpm run

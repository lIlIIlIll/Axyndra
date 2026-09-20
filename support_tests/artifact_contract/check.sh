#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
sdk_root="${CANGJIE_SDK_ROOT:-${HOME:?HOME must be set}/cangjie_sdk/main/linux_x64/vanilla/20260817/cangjie}"

export DISABLE_ZOXIDE=1
cd "$repo_root/support_tests/artifact_contract"
exec env CANGJIE_SDK_ROOT="$sdk_root" "$repo_root/scripts/pinned_cangjie" cjpm run

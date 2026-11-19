#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

export DISABLE_ZOXIDE=1
AXYNDRA_SDK_ROOT=$("$repo_root/scripts/check_sdk.sh")
export AXYNDRA_SDK_ROOT
AXYNDRA_SHELL_PLUGIN_PACKAGE=$(python3 "$repo_root/scripts/prepare_shell_plugin.py")
export AXYNDRA_SHELL_PLUGIN_PACKAGE
AXYNDRA_EVAL_PLUGIN_PACKAGE=$(python3 "$repo_root/scripts/prepare_eval_plugin.py")
export AXYNDRA_EVAL_PLUGIN_PACKAGE
cd "$repo_root/support_tests/artifact_contract"
exec "$repo_root/scripts/pinned_cangjie" cjpm run

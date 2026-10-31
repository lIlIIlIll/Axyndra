#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if (($# > 1)); then printf 'usage: prepare_model_provider_plugin.sh [NEW_OUTPUT_DIRECTORY]\n' >&2; exit 2; fi
if (($# == 1)); then
  output=$1
else
  artifacts="$root/target/plugin-contract-fixtures"
  mkdir -p "$artifacts"
  invocation=$(mktemp -d "$artifacts/model-provider-plugin-XXXXXX")
  output="$invocation/package"
fi
bash "$root/plugins/model_providers/build-package.sh" --output "$output" >&2
python3 "$root/plugins/model_providers/check.py" --package "$output" --summary "${output}.protocol-summary.json" >&2
python3 - "$output" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve())
PY

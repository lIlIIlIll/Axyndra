#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
artifacts="$root/target/plugin-contract-fixtures"
mkdir -p "$artifacts"
invocation=$(mktemp -d "$artifacts/web-search-plugin-XXXXXX")
package="$invocation/package"
bash "$root/plugins/web_search/build-package.sh" --output "$package" >&2
python3 "$root/plugins/web_search/check-business.py" --output-dir "$invocation/business-tests" >&2
python3 "$root/plugins/web_search/check.py" --package "$package" >&2
printf '%s\n' "$package"

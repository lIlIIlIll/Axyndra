#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
cd "$root/support_tests/product_contract"
"$root/scripts/pinned_cangjie" cjpm build
# The fault-injection fixture uses Linux LD_PRELOAD and libdl.
"${CC:-cc}" -shared -fPIC fail_rename.c -ldl -o "$fixture/fail_rename.so"
binary="$PWD/target/release/bin/main"
"$root/scripts/pinned_cangjie" env AXYNDRA_PRODUCT_CONTRACT_SCOPE=atomic-workspace "$binary"
"$root/scripts/pinned_cangjie" env LD_PRELOAD="$fixture/fail_rename.so" \
  AXYNDRA_FAIL_RENAME_SUFFIX=rollback-b AXYNDRA_PRODUCT_CONTRACT_SCOPE=atomic-rollback "$binary"
"$root/scripts/pinned_cangjie" env LD_PRELOAD="$fixture/fail_rename.so" \
  AXYNDRA_FAIL_RENAME_SUFFIX=fault-write AXYNDRA_PRODUCT_CONTRACT_SCOPE=atomic-write-failure "$binary"

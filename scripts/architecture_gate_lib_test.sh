#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=architecture_gate_lib.sh
source "$ROOT/scripts/architecture_gate_lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

printf 'authority\n' >"$tmp/authority.cj"
architecture_gate_require_file "$tmp/authority.cj"

if (architecture_gate_require_file "$tmp/missing.cj") 2>"$tmp/missing.err"; then
  printf 'missing authority was accepted\n' >&2
  exit 1
fi
rp-grep -q 'required architecture authority missing' "$tmp/missing.err"

cat >"$tmp/rg-none" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$tmp/rg-error" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$tmp/rg-none" "$tmp/rg-error"

RG="$tmp/rg-none"
if architecture_gate_rg_matches pattern "$tmp/authority.cj"; then
  printf 'no-match result was reported as a match\n' >&2
  exit 1
fi

RG="$tmp/rg-error"
if (architecture_gate_rg_matches pattern "$tmp/authority.cj") 2>"$tmp/rg.err"; then
  printf 'search execution error was accepted\n' >&2
  exit 1
fi
rp-grep -q 'search command failed with exit 2' "$tmp/rg.err"

printf 'architecture gate helper tests passed\n'

#!/usr/bin/env bash

architecture_gate_fail() {
  printf 'architecture gate failed: %s\n' "$1" >&2
  exit 1
}

architecture_gate_require_file() {
  [[ -f "$1" ]] || architecture_gate_fail "required architecture authority missing: $1"
}

architecture_gate_rg_matches() {
  local status=0
  "$RG" "$@" || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) architecture_gate_fail "search command failed with exit $status: $*" ;;
  esac
}

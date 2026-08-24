#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
AXYNDRA_GATE_KIND=implementation exec bash "$root/scripts/release_gate.sh"

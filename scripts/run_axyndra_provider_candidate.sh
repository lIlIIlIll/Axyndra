#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
binary=${AXYNDRA_BINARY:-"$root/target/release/bin/agent_app"}
port=${OMP_COMPAT_PROVIDER_PORT:?OMP_COMPAT_PROVIDER_PORT is required}
owns_home=1
if [[ -n "${OMP_COMPAT_HOME:-}" ]]; then
  home=$OMP_COMPAT_HOME
  mkdir -p "$home"
  owns_home=0
else
  home=$(mktemp -d -t axyndra-provider-candidate.XXXXXX)
fi

cleanup() {
  if [[ "$owns_home" == "1" ]]; then
    rm -rf -- "$home"
  fi
}
trap cleanup EXIT

mkdir -p "$home/credentials"
printf '%s\n' 'test-key' > "$home/credentials/axyndra-blackbox.key"
chmod 600 "$home/credentials/axyndra-blackbox.key"
printf '%s\n' \
  'default_model: axyndra-blackbox/blackbox-model' \
  > "$home/config.yml"
printf '%s\n' \
  'providers:' \
  '  - id: axyndra-blackbox' \
  '    provider: mock' \
  '    protocol: responses' \
  "    base_url: http://127.0.0.1:$port" \
  '    api_key_env: AXYNDRA_BLACKBOX_UNUSED' \
  '    timeout_millis: 120000' \
  > "$home/providers.yml"
printf '%s\n' \
  'models:' \
  '  - id: blackbox-model' \
  '    provider: axyndra-blackbox' \
  '    thinking:' \
  '      mode: toggle' \
  > "$home/models.yml"

work=${OMP_COMPAT_WORK:-"$root"}
cd "$work"
AXYNDRA_HOME="$home" "$binary" --approval-mode trusted --mode json "$@"

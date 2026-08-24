#!/usr/bin/env bash
set -euo pipefail

reference="${OMP_REFERENCE:-/tmp/oh-my-pi-09a7c865636457c50ed75fc3b1a7cc21ef72c105}"
entry="$reference/packages/coding-agent/src/cli.ts"
if [[ ! -f "$entry" ]]; then
  printf 'missing pinned OMP checkout: %s\n' "$reference" >&2
  exit 2
fi
modern="$reference/packages/natives/native/pi_natives.linux-x64-modern.node"
baseline="$reference/packages/natives/native/pi_natives.linux-x64-baseline.node"
modern_sha="8f86f4f84877049002cdf4dd026772e040d069b1a324cb54e9dbb29c891ed533"
baseline_sha="8d2011315e66b15597443f858550a61c3023ce114a6ec7699e298da52e2a2ba2"
if [[ ! -f "$modern" || ! -f "$baseline" ]] ||
   [[ "$(sha256sum "$modern" | cut -d' ' -f1)" != "$modern_sha" ]] ||
   [[ "$(sha256sum "$baseline" | cut -d' ' -f1)" != "$baseline_sha" ]]; then
  printf 'pinned OMP 17.2.3 native addons are missing or mismatched under %s\n' \
    "$reference" >&2
  exit 2
fi

owns_home=1
owns_work=1
if [[ -n "${OMP_COMPAT_HOME:-}" ]]; then
  baseline_home=$OMP_COMPAT_HOME
  mkdir -p "$baseline_home"
  owns_home=0
else
  baseline_home=$(mktemp -d /tmp/omp-baseline-home.XXXXXX)
fi
if [[ -n "${OMP_COMPAT_WORK:-}" ]]; then
  baseline_work=$OMP_COMPAT_WORK
  mkdir -p "$baseline_work"
  owns_work=0
elif [[ -n "${OMP_COMPAT_HOME:-}" ]]; then
  baseline_work="$OMP_COMPAT_HOME/work"
  mkdir -p "$baseline_work"
  owns_work=0
else
  baseline_work=$(mktemp -d /tmp/omp-baseline-work.XXXXXX)
fi
baseline_env=(
  PATH=/usr/bin:/bin
  TERM=dumb
  OPENAI_API_KEY=baseline-placeholder
)
if [[ -n "${OMP_BASELINE_OPENAI_BASE_URL:-}" ]]; then
  mkdir -p "$baseline_home/.omp/agent"
  printf '%s\n' \
    'providers:' \
    '  axyndra-blackbox:' \
    "    baseUrl: ${OMP_BASELINE_OPENAI_BASE_URL}" \
    '    api: openai-responses' \
    '    auth: none' \
    '    models:' \
    '      - id: blackbox-model' \
    '        name: Blackbox Model' \
    '        reasoning: false' \
    '        input: [text]' \
    '        contextWindow: 32768' \
    '        maxTokens: 4096' \
    > "$baseline_home/.omp/agent/models.yml"
fi
cleanup() {
  if [[ "$owns_home" == "1" ]]; then
    rm -rf -- "$baseline_home"
  fi
  if [[ "$owns_work" == "1" ]]; then
    rm -rf -- "$baseline_work"
  fi
}
trap cleanup EXIT

bwrap \
  --ro-bind / / \
  --bind "$baseline_home" /home/elliot \
  --tmpfs /tmp \
  --ro-bind "$reference" "$reference" \
  --bind "$baseline_work" /tmp/work \
  --dev /dev \
  --proc /proc \
  --chdir /tmp/work \
  /usr/bin/env -i \
  "${baseline_env[@]}" \
  /usr/bin/bun "$entry" "$@"

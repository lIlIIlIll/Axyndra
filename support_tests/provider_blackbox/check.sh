#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
binary="${1:-$repo_root/target/release/bin/agent_app}"
sdk_root=$(DISABLE_ZOXIDE=1 "$repo_root/scripts/check_sdk.sh")
source "$repo_root/scripts/sdk_paths.sh"
stdx_root=$(resolve_cangjie_stdx_path "$sdk_root")
export CANGJIE_STDX_PATH="$stdx_root"
export LD_LIBRARY_PATH="$repo_root/libs/process4cj/native:$stdx_root:$sdk_root/runtime/lib/linux_x86_64_cjnative:$sdk_root/tools/lib"
driver_root="$repo_root/support_tests/provider_driver"
driver="$driver_root/target/release/bin/main"
port="${AGENT_BLACKBOX_PORT:-18765}"
work="$(mktemp -d)"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ "${AXYNDRA_KEEP_BLACKBOX_WORK:-0}" != "1" ]]; then
    rm -rf "$work"
  else
    printf 'provider blackbox work retained: %s\n' "$work" >&2
  fi
}
trap cleanup EXIT

(
  cd "$driver_root"
  "$repo_root/scripts/pinned_cangjie" cjpm build
)

python3 "$repo_root/support_tests/provider_blackbox/mock_server.py" \
  --port "$port" &
server_pid=$!

for _ in {1..50}; do
  if python3 -c "import socket; s=socket.create_connection(('127.0.0.1',$port),.1); s.close()" 2>/dev/null; then
    break
  fi
  sleep 0.02
done

home="$work/home"
mkdir -p "$home/credentials"
printf '%s\n' 'test-key' > "$home/credentials/mock-responses.key"
printf '%s\n' 'test-key' > "$home/credentials/mock-messages.key"
chmod 600 "$home/credentials/mock-responses.key"
chmod 600 "$home/credentials/mock-messages.key"

write_config() {
  local timeout_millis="$1"
  local base_url="${2:-http://127.0.0.1:$port}"
  printf '%s\n' \
    'default_model: mock-responses/blackbox-model' \
    > "$home/config.yml"
  printf '%s\n' \
    'models:' \
    '  - id: blackbox-model' \
    '    provider: mock-responses' \
    '    thinking:' \
    '      mode: effort' \
    '      levels: [minimal, low, medium, high, xhigh, max]' \
    '  - id: blackbox-model' \
    '    provider: mock-messages' \
    '    thinking:' \
    '      mode: budget' \
    '      levels: [minimal, low, medium, high, xhigh, max]' \
    > "$home/models.yml"
  printf '%s\n' \
    'providers:' \
    '  - id: mock-responses' \
    '    provider: mock' \
    '    protocol: responses' \
    '    dialect: openai_responses' \
    "    base_url: $base_url" \
    '    api_key_env: AGENT_BLACKBOX_UNUSED' \
    "    timeout_millis: $timeout_millis" \
    '  - id: mock-messages' \
    '    provider: mock' \
    '    protocol: messages' \
    '    dialect: anthropic_messages' \
    "    base_url: $base_url" \
    '    api_key_env: AGENT_BLACKBOX_UNUSED' \
    "    timeout_millis: $timeout_millis" \
    > "$home/providers.yml"
}

write_config 120000
export AXYNDRA_HOME="$home"

responses="$(
  cd "$work"
  "$binary" --print "responses blackbox"
)"
printf '%s\n' 'tool fixture' > "$work/tool.txt"
tool_loop="$(
  cd "$work"
  "$binary" --approval-mode trusted --print \
    "tool-blackbox: read tool.txt"
)"
messages="$(
  cd "$work"
  "$binary" --model mock-messages/blackbox-model \
    --print "messages blackbox"
)"
cancel="$(
  cd "$work"
  "$repo_root/scripts/pinned_cangjie" "$driver" cancel
)"
write_config 100
timeout="$(
  cd "$work"
  "$repo_root/scripts/pinned_cangjie" "$driver" timeout
)"
write_config 120000
concurrency="$(
  cd "$work"
  "$repo_root/scripts/pinned_cangjie" "$driver" concurrency
)"
if "$binary" --print "provider-error" \
  > "$work/provider-error.log" 2>&1; then
  echo "provider error smoke unexpectedly succeeded" >&2
  exit 1
fi
if ! rp-grep -q 'model.rate_limited' "$work/provider-error.log"; then
  cat "$work/provider-error.log" >&2
  exit 1
fi
for case in \
  'authentication-401:model.authentication' \
  'authorization-403:model.authentication' \
  'request-timeout-408:model.timeout' \
  'gateway-timeout-504:model.timeout' \
  'provider-failure-500:model.provider_error'; do
  prompt="${case%%:*}"
  expected="${case#*:}"
  log="$work/$prompt.log"
  if "$binary" --print "$prompt" > "$log" 2>&1; then
    echo "$prompt unexpectedly succeeded" >&2
    exit 1
  fi
  if ! rp-grep -q "$expected" "$log"; then
    cat "$log" >&2
    exit 1
  fi
  if rp-grep -q '__AXYNDRA_HTTP_STATUS__' "$log"; then
    echo "curl HTTP marker leaked into $prompt diagnostics" >&2
    cat "$log" >&2
    exit 1
  fi
done
if "$binary" --print "context-overflow" \
  > "$work/context-overflow.log" 2>&1; then
  echo "context overflow smoke unexpectedly succeeded" >&2
  exit 1
fi
if ! rp-grep -q 'model.context_exceeded' "$work/context-overflow.log"; then
  cat "$work/context-overflow.log" >&2
  exit 1
fi
write_config 500 "http://127.0.0.1:9"
if "$binary" --print "network-interruption" \
  > "$work/network.log" 2>&1; then
  echo "network interruption smoke unexpectedly succeeded" >&2
  exit 1
fi
if ! rp-grep -q 'model.transport' "$work/network.log"; then
  cat "$work/network.log" >&2
  exit 1
fi

[[ "$responses" == *"responses-ok"* ]]
[[ "$tool_loop" == *"tool-loop-ok"* ]]
[[ "$messages" == *"messages-ok"* ]]
[[ "$cancel" == *"cancel smoke passed"* ]]
[[ "$timeout" == *"timeout smoke passed"* ]]
[[ "$concurrency" == *"concurrency smoke passed"* ]]
real_driver="$(
  DEEPSEEK_API_KEY="test-key" \
  AXYNDRA_REAL_OPENAI_PROTOCOL="responses" \
  AXYNDRA_REAL_OPENAI_BASE_URL="http://127.0.0.1:$port" \
  AXYNDRA_REAL_OPENAI_MODEL="blackbox-model" \
  AXYNDRA_REAL_ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
  AXYNDRA_REAL_ANTHROPIC_MODEL="blackbox-model" \
    AXYNDRA_BINARY="$binary" \
    python3 \
      "$repo_root/support_tests/provider_real_smoke/check.py"
)"
[[ "$real_driver" == *"real provider smoke passed"* ]]
printf '%s\n' \
  "provider blackbox passed: Responses + Messages + release-smoke driver + tool loop + cancellation + timeout + concurrency + provider/network/context errors"

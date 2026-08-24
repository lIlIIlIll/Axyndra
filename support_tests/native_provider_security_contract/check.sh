#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
contract_root="$repo_root/support_tests/native_provider_security_contract"
sdk_root="$(DISABLE_ZOXIDE=1 "$repo_root/scripts/check_sdk.sh")"
contract_tmp="$(mktemp -d)"
ready_file="$contract_tmp/port"
tls_ready_file="$contract_tmp/tls-port"
tls_cert="$contract_tmp/fixture.crt"
tls_key="$contract_tmp/fixture.key"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ -n "${tls_server_pid:-}" ]]; then
    kill "$tls_server_pid" 2>/dev/null || true
    wait "$tls_server_pid" 2>/dev/null || true
  fi
  rm -rf "$contract_tmp"
}
trap cleanup EXIT

python3 "$contract_root/fixture_server.py" --ready-file "$ready_file" &
server_pid=$!
for _ in {1..100}; do
  if [[ -s "$ready_file" ]]; then
    break
  fi
  sleep 0.02
done
if [[ ! -s "$ready_file" ]]; then
  echo "native provider security fixture did not start" >&2
  exit 1
fi
port="$(<"$ready_file")"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=localhost' -keyout "$tls_key" -out "$tls_cert" >/dev/null 2>&1
python3 "$contract_root/fixture_server.py" \
  --ready-file "$tls_ready_file" --tls-cert "$tls_cert" --tls-key "$tls_key" &
tls_server_pid=$!
for _ in {1..100}; do
  if [[ -s "$tls_ready_file" ]]; then
    break
  fi
  sleep 0.02
done
if [[ ! -s "$tls_ready_file" ]]; then
  echo "native provider TLS fixture did not start" >&2
  exit 1
fi
tls_port="$(<"$tls_ready_file")"

(
  cd "$contract_root"
  AXYNDRA_SDK_ROOT="$sdk_root" \
    "$repo_root/scripts/pinned_cangjie" cjpm build
)

AXYNDRA_NATIVE_PROVIDER_SECURITY_KEY='native-provider-secret-echo-20260810' \
AXYNDRA_SDK_ROOT="$sdk_root" \
  "$repo_root/scripts/pinned_cangjie" \
    "$contract_root/target/release/bin/main" "$port" "$tls_port"

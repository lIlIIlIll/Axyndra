#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sdk_root=$(DISABLE_ZOXIDE=1 "$root/scripts/check_sdk.sh")
source "$root/scripts/sdk_paths.sh"
stdx_root=$(resolve_cangjie_stdx_path "$sdk_root")
package_root=${AXYNDRA_PACKAGE_ROOT:-"$root/dist/axyndra"}
distribution=${AXYNDRA_DISTRIBUTION:-minimal}
case "$distribution" in coding|full|minimal) ;; *) printf 'unknown distribution: %s\n' "$distribution" >&2; exit 2 ;; esac
# Minimal uses its separately built generic host executable.
default_binary="$root/target/release/bin/agent_app"
if [[ "$distribution" == minimal ]]; then
  default_binary="$root/target/release/bin/agent_minimal"
fi
source_binary=${AXYNDRA_SOURCE_BINARY:-"$default_binary"}
explicit_binary=()
if [[ -n "${AXYNDRA_SOURCE_BINARY:-}" ]]; then explicit_binary=(--explicit-input); fi
# Supplied engine bytes are checked against each plugin's reviewed lock by its
# own packager. An ambient PATH binary is never substituted for a pinned engine.
if [[ "$distribution" != minimal ]]; then
  : "${AXYNDRA_WORKSPACE_ENGINE:?set the pinned Workspace ripgrep path}"
  : "${AXYNDRA_WORKSPACE_ENGINE_LICENSE:?set its LICENSE-MIT path}"
fi
if [[ "$distribution" == full ]]; then
  : "${AXYNDRA_AST_ENGINE:?set the pinned ast-grep path}"
  : "${AXYNDRA_AST_ENGINE_LICENSE:?set its license path}"
fi
if [[ -e "$package_root/share/axyndra" ]]; then
  printf 'distribution output must be fresh: %s\n' "$package_root/share/axyndra" >&2
  exit 2
fi
AWK=${AWK:-rp-awk}
GREP=${GREP:-rp-grep}
if ! command -v "$AWK" >/dev/null 2>&1; then
  AWK=awk
fi
if ! command -v "$GREP" >/dev/null 2>&1; then
  GREP=grep
fi

if [[ ! -x "$source_binary" ]]; then
  printf 'axyndra: build artifact is missing: %s\n' "$source_binary" >&2
  exit 2
fi
if ! command -v patchelf >/dev/null 2>&1; then
  printf 'axyndra: patchelf is required to package a relocatable candidate\n' >&2
  exit 2
fi
network_bridge="$root/libs/process4cj/native/sandbox-net-bridge"
if [[ ! -x "$network_bridge" ]]; then
  "$root/scripts/prepare_native_deps.sh" >/dev/null
fi
if [[ ! -x "$network_bridge" ]]; then
  printf 'axyndra: mediated network gateway helper is missing: %s\n' "$network_bridge" >&2
  exit 2
fi

source_binary_sha256=$(python3 "$root/scripts/package_host_provenance.py" --hash-file "$source_binary")
mkdir -p -- "$package_root/bin" "$package_root/lib" "$package_root/diagnostics"
cp -f -- "$source_binary" "$package_root/bin/axyndra"
cp -f -- "$network_bridge" "$package_root/bin/sandbox-net-bridge"

runtime_paths=(
  "$root/libs/process4cj/native"
  "$sdk_root/runtime/lib/linux_x86_64_cjnative"
  "$sdk_root/tools/lib"
  "$stdx_root"
)
export LD_LIBRARY_PATH=$(IFS=:; printf '%s' "${runtime_paths[*]}")

queue=("$package_root/bin/axyndra")
seen='|'
while ((${#queue[@]})); do
  current=${queue[0]}
  queue=("${queue[@]:1}")
  while IFS='|' read -r needed dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*) continue ;;
    esac
    canonical=$(readlink -f -- "$dependency")
    [[ -n "$needed" ]] || needed=$(basename -- "$canonical")
    case "$seen" in *"|$needed|"*) continue ;; esac
    seen+="$needed|"
    destination="$package_root/lib/$needed"
    cp -f -- "$canonical" "$destination"
    queue+=("$destination")
  done < <(
    ldd "$current" | "$AWK" '
      /=> \/.* \(0x/ { print $1 "|" $3 }
      /^\/[[:graph:]]+ \(0x/ { print "|" $1 }
    '
  )
done

patchelf --set-rpath '$ORIGIN/../lib' "$package_root/bin/axyndra"
for library in "$package_root"/lib/*; do
  [[ -f "$library" ]] || continue
  patchelf --set-rpath '$ORIGIN' "$library"
done

env -u LD_LIBRARY_PATH ldd "$package_root/bin/axyndra" \
  > "$package_root/diagnostics/ldd.txt"
if "$GREP" -q 'not found' "$package_root/diagnostics/ldd.txt"; then
  cat "$package_root/diagnostics/ldd.txt" >&2
  exit 1
fi
if [[ "$distribution" != minimal ]]; then
  distribution_root="$package_root/share/axyndra"
  mkdir -p -- "$distribution_root/plugins"
  # Independent native artifact: never link its implementation into the host.
  "$root/plugins/skills/build-package.sh" --output "$distribution_root/plugins/skills" >&2
  "$root/plugins/memory/build-package.sh" --output "$distribution_root/plugins/memory" >&2
  "$root/plugins/compaction/build-package.sh" --output "$distribution_root/plugins/compaction" >&2
  "$root/plugins/workflow/build-package.sh" --output "$distribution_root/plugins/workflow" >&2
  "$root/plugins/workspace/build-package.sh" --output "$distribution_root/plugins/workspace" \
    --engine "$AXYNDRA_WORKSPACE_ENGINE" --engine-license "$AXYNDRA_WORKSPACE_ENGINE_LICENSE" >&2
  "$root/plugins/shell/build-package.sh" --output "$distribution_root/plugins/shell" >&2
  "$root/plugins/shell_readonly/build-package.sh" --output "$distribution_root/plugins/shell_readonly" >&2
  "$root/plugins/model_providers/build-package.sh" --output "$distribution_root/plugins/model-providers" >&2
  "$root/plugins/program/build-package.sh" --output "$distribution_root/plugins/program" >&2
  if [[ "$distribution" == full ]]; then
    "$root/plugins/ast/build-package.sh" --output "$distribution_root/plugins/ast" \
      --engine "$AXYNDRA_AST_ENGINE" --engine-license "$AXYNDRA_AST_ENGINE_LICENSE" >&2
    for plugin in web_search github lsp dap eval mcp mcp_server; do
      "$root/plugins/$plugin/build-package.sh" --output "$distribution_root/plugins/$plugin" >&2
    done
  fi
  python3 "$root/scripts/package_distribution.py" --root "$distribution_root" \
    --profile "$root/profiles/$distribution-context.json" --policies "$root/profiles/coding-policies.json" \
    --read-scopes "$root/profiles/coding-read-scopes.json" \
    --packages "$root/profiles/$distribution-plugins.json"
else
  distribution_root="$package_root/share/axyndra"
  mkdir -p -- "$distribution_root"
  python3 "$root/scripts/package_distribution.py" --root "$distribution_root" \
    --profile "$root/profiles/minimal-context.json"
fi
python3 "$root/scripts/package_host_licenses.py" --root "$package_root" \
  --sdk-root "$sdk_root" --stdx-root "$stdx_root" --repository-license "$root/LICENSE"
python3 "$root/scripts/package_host_provenance.py" --root "$package_root" \
  --binary "$source_binary" --source-sha256 "$source_binary_sha256" \
  --recipe "$root/packaging/distributions.json" --profile "$distribution" "${explicit_binary[@]}"
printf '%s\n' "$package_root/bin/axyndra"

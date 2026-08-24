#!/usr/bin/env bash

# Resolve the dynamic stdx tree that belongs to the selected SDK. Some SDK
# bundles place `cangjie/` and the complete stdx installation next to each
# other, while installed SDKs keep stdx inside the SDK root. Native HTTP is a
# required product dependency, so a partial directory is not a valid match.
resolve_cangjie_stdx_path() {
  local sdk_root=$1
  local candidate
  local candidates=(
    "$sdk_root/linux_x86_64_cjnative/dynamic/stdx"
    "$(dirname -- "$sdk_root")/linux_x86_64_cjnative/dynamic/stdx"
    # Ambient shells often export CANGJIE_STDX_PATH for another SDK. It is a
    # fallback only: the pinned SDK's adjacent stdx must win whenever present,
    # otherwise one build links stdx against a different std generation.
    "${CANGJIE_STDX_PATH:-}"
  )
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    if [[ -f "$candidate/libstdx.net.http.so" ]]; then
      readlink -f -- "$candidate"
      return 0
    fi
  done
  printf 'axyndra: complete dynamic stdx with libstdx.net.http.so was not found for %s\n' \
    "$sdk_root" >&2
  return 1
}

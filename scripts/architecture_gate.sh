#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RG=${RG:-rp-rg}

# shellcheck source=architecture_gate_lib.sh
source "$ROOT/scripts/architecture_gate_lib.sh"

fail() {
  architecture_gate_fail "$1"
}

require_file() { architecture_gate_require_file "$1"; }
rg_matches() { architecture_gate_rg_matches "$@"; }

for authority in \
  agent_app/src/main.cj \
  agent_core/src/core.cj \
  agent_core/src/model_control.cj \
  agent_domain/src/v3_control.cj \
  agent_embed/src/sdk.cj \
  agent_product/src/application.cj \
  agent_product/src/checkpoint_tools.cj \
  agent_product/src/product.cj \
  agent_product/src/task_persistence.cj \
  agent_product/src/task_product.cj \
  agent_product/src/tools.cj \
  agent_runtime/src/run_lifecycle.cj; do
  require_file "$ROOT/$authority"
done

for removed in \
  agent_ports/src/session_store.cj \
  persistence_runtime/src/session_store.cj \
  persistence_runtime/src/session_conversation.cj \
  persistence_runtime/src/repositories.cj \
  persistence_runtime/src/disk.cj \
  agent_testkit/src/memory_ports.cj \
  agent_testkit/src/faults.cj; do
  if [[ -e "$ROOT/$removed" ]]; then
    fail "removed legacy source returned: $removed"
  fi
done

python3 "$ROOT/scripts/tracked_artifact_gate.py"
python3 "$ROOT/scripts/docs_gate.py"

if rg_matches -n 'ConversationRepository|Disk(SessionMetadata|Permission|Run|Conversation|Operation|Approval|Audit)Repository|DiskSessionStore|SessionConversationRepository' \
  "$ROOT"/agent_*/src "$ROOT"/persistence_runtime/src \
  "$ROOT"/support_tests --glob '*.cj' >/dev/null; then
  fail "legacy file-backed repository API remains in product or executable contracts"
fi

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import sys
import tomllib
from pathlib import Path


root = Path(sys.argv[1]).resolve()
workspace = tomllib.loads((root / "cjpm.toml").read_text(encoding="utf-8"))
members = workspace.get("workspace", {}).get("members", [])
if not isinstance(members, list) or not members:
    raise SystemExit("architecture gate failed: workspace members are missing")

required_vnext_packages = {
    "agent_app_protocol",
    "agent_skills",
    "agent_runtime",
    "agent_store",
}
missing_vnext_packages = required_vnext_packages.difference(
    str(member) for member in members
)
if missing_vnext_packages:
    raise SystemExit(
        "architecture gate failed: canonical vNext package omitted from workspace: "
        + ", ".join(sorted(missing_vnext_packages))
    )

packages: dict[str, dict[str, object]] = {}
package_roots: dict[str, Path] = {}
for member in members:
    manifest = root / str(member) / "cjpm.toml"
    if not manifest.is_file():
        raise SystemExit(
            f"architecture gate failed: workspace member has no manifest: {member}"
        )
    parsed = tomllib.loads(manifest.read_text(encoding="utf-8"))
    name = str(parsed.get("package", {}).get("name", "")).strip()
    if not name:
        raise SystemExit(
            f"architecture gate failed: workspace package has no name: {member}"
        )
    if name in packages:
        raise SystemExit(
            f"architecture gate failed: duplicate workspace package name: {name}"
        )
    packages[name] = parsed
    package_roots[name] = manifest.parent.resolve()


def dependency_entries(value: object) -> list[tuple[str, object]]:
    result: list[tuple[str, object]] = []
    if not isinstance(value, dict):
        return result
    for key, child in value.items():
        if key.endswith("dependencies") and isinstance(child, dict):
            result.extend((str(name), specification) for name, specification in child.items())
        else:
            result.extend(dependency_entries(child))
    return result


root_packages = {path: name for name, path in package_roots.items()}
graph: dict[str, set[str]] = {}
for name, manifest in packages.items():
    dependencies: set[str] = set()
    for declared_name, specification in dependency_entries(manifest):
        if declared_name in packages:
            dependencies.add(declared_name)
        if isinstance(specification, dict):
            relative = specification.get("path")
            if isinstance(relative, str) and "${" not in relative:
                dependency_root = (package_roots[name] / relative).resolve()
                resolved_name = root_packages.get(dependency_root)
                if resolved_name is not None:
                    dependencies.add(resolved_name)
    graph[name] = dependencies
state: dict[str, int] = {}
stack: list[str] = []


def visit(name: str) -> None:
    marker = state.get(name, 0)
    if marker == 2:
        return
    if marker == 1:
        start = stack.index(name)
        cycle = stack[start:] + [name]
        raise SystemExit(
            "architecture gate failed: workspace dependency cycle: "
            + " -> ".join(cycle)
        )
    state[name] = 1
    stack.append(name)
    for dependency in sorted(graph[name]):
        visit(dependency)
    stack.pop()
    state[name] = 2


for package in sorted(graph):
    visit(package)

# agent_app is the executable adapter and is the only package allowed to
# consume agent_tui. Runtime, protocol, SDK, persistence, and product packages
# must never acquire a reverse dependency on either UI or the executable.
for package, dependencies in sorted(graph.items()):
    if package == "agent_app":
        continue
    forbidden = dependencies.intersection({"agent_tui", "agent_app"})
    if forbidden:
        raise SystemExit(
            "architecture gate failed: UI/executable reverse dependency: "
            + package
            + " -> "
            + ", ".join(sorted(forbidden))
        )

# The TUI may consume only the narrow command/client/domain surface. Its
# cjtui rendering dependencies live outside this workspace and are ignored by
# the local-package graph above.
tui_dependencies = graph.get("agent_tui", set())
unexpected_tui_dependencies = tui_dependencies.difference(
    {"agent_cli", "agent_client", "agent_domain"}
)
if unexpected_tui_dependencies:
    raise SystemExit(
        "architecture gate failed: agent_tui crosses the frontend boundary: "
        + ", ".join(sorted(unexpected_tui_dependencies))
    )

edge_count = sum(len(values) for values in graph.values())
print(
    f"workspace dependency graph passed ({len(graph)} packages, "
    f"{edge_count} local edges; no UI reverse dependencies)"
)
PY

if rg_matches -n '"(agent_json|agent_json_macros|model_runtime|workspace_runtime|process_runtime|run_runtime|state_store|session_runtime|config_runtime|extension_runtime|isolation_runtime|rpc_runtime|agent_rpc_server)"' \
  "$ROOT/cjpm.toml" "$ROOT"/*/cjpm.toml >/dev/null; then
  fail "product graph contains a removed transition package"
fi

if rg_matches -n 'import (agent_json|agent_json_macros|model_runtime|workspace_runtime|process_runtime|run_runtime|state_store|session_runtime|config_runtime|extension_runtime|isolation_runtime|rpc_runtime)' \
  "$ROOT"/agent_*/src "$ROOT"/model_adapters/src "$ROOT"/tool_runtime/src \
  "$ROOT"/persistence_runtime/src "$ROOT"/run_control/src \
  "$ROOT"/task_runtime/src >/dev/null; then
  fail "product code imports a removed transition package"
fi

if rg_matches -n 'import (agent_core|model_adapters)' \
  "$ROOT/agent_cli/src" >/dev/null; then
  fail "CLI parser crosses the client/domain boundary"
fi

# Provider DTOs and legacy conversations are never Runtime truth.
if rg_matches -n 'conversations\.' \
  "$ROOT/agent_core/src" >/dev/null; then
  fail "AgentCore reads or writes the legacy conversation projection"
fi

if rg_matches -n 'ConversationRepository' \
  "$ROOT/agent_core/src/core.cj" "$ROOT/agent_embed/src/sdk.cj" >/dev/null; then
  fail "Core or SDK still binds a legacy conversation repository"
fi

if rg_matches -n 'DiskRunRepository' \
  "$ROOT/agent_core/src" "$ROOT/agent_product/src" "$ROOT/agent_sdk/src" >/dev/null; then
  fail "production Runtime still uses the file-backed duplicate Run repository"
fi

if rg_matches -n 'Disk(Operation|Audit|Permission)Repository' \
  "$ROOT/agent_core/src" "$ROOT/agent_product/src" "$ROOT/agent_sdk/src" >/dev/null; then
  fail "production Tool execution still writes file-backed operation, audit, or permission state"
fi

if rg_matches -n 'ConversationRepository|appendTranscriptOnceAndProject' \
  "$ROOT/agent_product/src/checkpoint_tools.cj" >/dev/null; then
  fail "checkpoint tools mutate legacy model history instead of saving a canonical checkpoint"
fi

if rg_matches -n 'sessionFile|fromByte|nextByte' \
  "$ROOT/agent_product/src" "$ROOT/agent_rpc/src" >/dev/null; then
  fail "Product or RPC retains file-backed subagent transcript protocol"
fi

if rg_matches -n 'match \(conversations\.' "$ROOT/agent_core/src" >/dev/null; then
  fail "legacy conversation projection can still veto canonical Runtime progress"
fi

if rg_matches -n 'conversations\.(append|appendMessageOnce|appendTranscriptOnceAndProject|replace|project)\(' \
  "$ROOT/agent_product/src/product.cj" \
  "$ROOT/agent_product/src/application.cj" \
  "$ROOT/agent_product/src/task_product.cj" >/dev/null; then
  fail "Product semantic writes bypass the canonical Thread owner"
fi

if rg_matches -n 'public func (appendMessage|appendMessageOnce|appendTranscriptOnceAndProject)\(' \
  "$ROOT/agent_product/src/product.cj" >/dev/null; then
  fail "Product exposes a legacy conversation mutation API"
fi

if rg_matches -n 'let (worker|deliveryWorker) = spawn' \
  "$ROOT/agent_product/src/task_product.cj" >/dev/null; then
  fail "Product task runtime starts an unowned background worker"
fi

if rg_matches -n \
  'repairInterruptedToolMessages|pruneOrphanToolResults|coalesceToolResultMessages' \
  "$ROOT/agent_core/src" >/dev/null; then
  fail "AgentCore retains legacy ModelMessage repair as semantic authority"
fi

# Core events are already represented by AgentEventPayload. The executable
# adapter may inspect string codes only inside the explicit Extension escape
# hatch; it must not erase typed events and redispatch them by detail.code.
if rg_matches -n 'eventCode\(|match \(eventCode\(' \
  "$ROOT/agent_app/src" >/dev/null; then
  fail "App/TUI bridge redispatches typed AgentEventPayload through string codes"
fi

if ! rg_matches -n 'import agent_app_protocol\.\*' \
  "$ROOT/agent_product/src" >/dev/null; then
  fail "typed App Protocol is not connected to the production boundary"
fi

if rg_matches -n 'typedEventFromLegacy|public init\([[:space:]]*sequence: Int64,[[:space:]]*runId: RunId,[[:space:]]*kind: AgentEventKind' \
  "$ROOT/agent_domain/src" >/dev/null; then
  fail "legacy AgentEvent conversion remains in the typed event runtime"
fi

if rg_matches -n '\bToolOutcome\b|OperationExecutionOutcomeKind' \
  "$ROOT"/agent_*/src "$ROOT/tool_runtime/src" \
  "$ROOT/persistence_runtime/src" >/dev/null; then
  fail "operation outcome still has a legacy or duplicate runtime model"
fi

if rg_matches -n '\bExecutionBudgetLedger\b' \
  "$ROOT/agent_domain/src" "$ROOT/agent_runtime/src" \
  "$ROOT/agent_core/src" >/dev/null; then
  fail "Run still has a duplicate execution budget ledger"
fi

if rg_matches -n 'migrateLegacyContinuation|ContinuationMigrationMetadata|version != 3 && version != 4' \
  "$ROOT/agent_domain/src" "$ROOT/agent_product/src" \
  "$ROOT/persistence_runtime/src" >/dev/null; then
  fail "legacy continuation migration remains on the production runtime path"
fi

if rg_matches -n 'model-attempt-timeout-ms|--yolo|--auto-approve|case "always-ask"|case "write"|case "yolo"' \
  "$ROOT/agent_app/src" >/dev/null; then
  fail "removed CLI compatibility aliases remain in the production executable"
fi

if rg_matches -n 'legacyInferredThinkingCapabilities|legacyOfficialProviderDialect|entry\.reasoning' \
  "$ROOT/agent_product/src" >/dev/null; then
  fail "provider/model capability resolution still contains legacy inference"
fi

if rg_matches -n 'case Result\.Err\(_\) => match \(session\.messages\(\)\)' \
  "$ROOT/agent_app/src/main.cj" >/dev/null; then
  fail "TUI canonical Thread loading still falls back to ModelMessage history"
fi

if rg_matches -n 'optionalString\(call, "path", ""\)' \
  "$ROOT/agent_product/src/tools.cj" >/dev/null; then
  fail "Glob runtime still accepts the removed path argument alias"
fi

if rg_matches -n 'subagent_runtime|SubagentCoordinator' \
  "$ROOT/agent_product/cjpm.toml" "$ROOT/agent_product/src" >/dev/null; then
  fail "Product retains a second child-run coordinator or budget authority"
fi

if rg_matches -n 'taskLegacySettlementReceipt|persistenceVersion|legacyInstanceId' \
  "$ROOT/agent_product/src/task_persistence.cj" \
  "$ROOT/agent_product/src/task_product.cj" >/dev/null; then
  fail "Task runtime retains v1 receipt or instance compatibility"
fi

if ! rg_matches -n 'appendExternalMessageOnce\(sessionId, receiptId, message\)' \
  "$ROOT/agent_product/src/task_product.cj" >/dev/null; then
  fail "async settlement bypasses the canonical Thread external-input boundary"
fi

if ! rg_matches -n 'Capability\(CapabilityKind\.PeerMessage\)' \
  "$ROOT/agent_product/src/tools.cj" >/dev/null; then
  fail "peer messaging is still coupled to the broader delegation capability"
fi

runtime_authorities=$(
  "$RG" -l 'class RunStateMachine|public class ExecutionBudget' \
    "$ROOT"/agent_*/src "$ROOT"/run_control/src \
    "$ROOT"/task_runtime/src \
    "$ROOT"/tool_runtime/src "$ROOT"/persistence_runtime/src \
    2>/dev/null | sort || true
)
allowed_runtime_authorities=$(printf '%s\n' \
  "$ROOT/agent_domain/src/v3_control.cj" \
  "$ROOT/agent_runtime/src/run_lifecycle.cj" \
  | sort)
if [[ "$runtime_authorities" != "$allowed_runtime_authorities" ]]; then
  printf '%s\n' "$runtime_authorities" >&2
  fail "Run lifecycle and execution budget must each have one authority"
fi

run_state_models=$(
  "$RG" -l 'public enum Run(State|Status)' "$ROOT"/agent_*/src \
    "$ROOT"/run_control/src "$ROOT"/persistence_runtime/src 2>/dev/null \
    | sort || true
)
if [[ "$run_state_models" != "$ROOT/agent_domain/src/v3_control.cj" ]]; then
  printf '%s\n' "$run_state_models" >&2
  fail "Run state must have one domain model"
fi

if rg_matches -n \
  'rpc-once|rpc-smoke|cancel-smoke|timeout-smoke|concurrency-smoke' \
  "$ROOT/agent_app/src" >/dev/null; then
  fail "product CLI contains a test-only or legacy command"
fi

python3 "$ROOT/scripts/check_cjtui_contract.py"
python3 "$ROOT/scripts/check_library_boundaries.py"
python3 "$ROOT/scripts/check_sdk_compatibility.py"
python3 "$ROOT/scripts/package_readiness.py" audit

model_callers=$(
  "$RG" -l -i '(model|provider)[a-z0-9_]*\.execute\(' "$ROOT" \
    --glob '*.cj' \
    --glob '!support_tests/**' \
    | sort || true
)
allowed_model_callers=$(printf '%s\n' \
  "$ROOT/agent_core/src/core.cj" \
  "$ROOT/agent_core/src/model_control.cj" \
  | sort)
if [[ "$model_callers" != "$allowed_model_callers" ]]; then
  printf '%s\n' "$model_callers" >&2
  fail "provider/model execute calls must stay inside agent_core's control plane"
fi

printf 'architecture gate passed\n'

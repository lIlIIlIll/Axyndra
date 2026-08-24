#!/usr/bin/env python3
"""Deterministic dependency/import boundary checks for reusable libraries."""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LIBS = ROOT / "libs"
FORBIDDEN = {
    "agent_domain", "agent_core", "agent_runtime", "agent_ports",
    "tool_runtime", "run_control", "task_runtime", "subagent_runtime",
    "persistence_runtime", "agent_store",
}
SDK_FORBIDDEN = {
    "agent_core", "agent_runtime", "agent_product", "agent_ports",
    "tool_runtime", "run_control", "persistence_runtime", "agent_store",
    "agent_embed", "agent_tui",
}
SDK_EXTENSION_ROOTS = {
    "extensions/ast_extension",
    "extensions/web_search_extension",
    "extensions/workspace_search_extension",
    "extensions/workspace_write_extension",
    "support_tests/sdk_fixture_extension",
}
PUBLIC_TESTKIT = ROOT / "omp_agent_testkit"
TESTKIT_FORBIDDEN = SDK_FORBIDDEN | {
    "agent_domain", "agent_ports", "agent_extensions", "agent_extension_runtime",
    "agent_testkit",
}
EXTENSION_FORBIDDEN = SDK_FORBIDDEN | {
    "agent_domain", "agent_extensions", "agent_extension_runtime",
}
REQUIRED = {
    "json4cj", "jsonrpc4cj", "process4cj", "mcp4cj", "sandbox4cj",
    "llm4cj", "lsp4cj", "dap4cj", "skill_runtime",
}
IMPORT = re.compile(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)
DECLARATION = re.compile(
    r"^\s*(?:public\s+)?(?:class|enum|struct)\s+(JsonValue|JsonParser|JsonEncoder)\b"
    r"|^\s*(?:public\s+)?func\s+(parseJson|encodeJson|encodeContentLengthFrame|readContentLengthBody|readLineBounded)\b",
    re.MULTILINE,
)


def fail(messages: list[str]) -> None:
    if messages:
        raise SystemExit("architecture gate failed:\n  " + "\n  ".join(messages))


errors: list[str] = []
found = {path.name for path in LIBS.iterdir() if (path / "cjpm.toml").is_file()}
workspace = tomllib.loads((ROOT / "cjpm.toml").read_text(encoding="utf-8"))
members = set(workspace.get("workspace", {}).get("members", []))
for missing in sorted(REQUIRED - found):
    errors.append(f"required reusable library is missing: libs/{missing}")
for library in sorted(REQUIRED):
    if f"libs/{library}" not in members:
        errors.append(f"reusable library is omitted from workspace: libs/{library}")

for library in sorted(found):
    root = LIBS / library
    manifest = tomllib.loads((root / "cjpm.toml").read_text(encoding="utf-8"))
    dependencies = manifest.get("dependencies", {})
    if isinstance(dependencies, dict):
        for dependency in sorted(set(dependencies).intersection(FORBIDDEN)):
            errors.append(f"libs/{library}/cjpm.toml depends on forbidden Agent package {dependency}")
    for source in sorted((root / "src").glob("**/*.cj")):
        text = source.read_text(encoding="utf-8")
        for imported in IMPORT.findall(text):
            if imported in FORBIDDEN:
                errors.append(f"{source.relative_to(ROOT)} imports forbidden Agent package {imported}")

sdk_manifest = tomllib.loads((ROOT / "agent_sdk" / "cjpm.toml").read_text(encoding="utf-8"))
sdk_dependencies = sdk_manifest.get("dependencies", {})
if isinstance(sdk_dependencies, dict):
    for dependency in sorted(set(sdk_dependencies).intersection(SDK_FORBIDDEN)):
        errors.append(f"agent_sdk depends on forbidden product authority package {dependency}")
for source in sorted((ROOT / "agent_sdk" / "src").glob("**/*.cj")):
    text = source.read_text(encoding="utf-8")
    for imported in IMPORT.findall(text):
        if imported in SDK_FORBIDDEN:
            errors.append(f"{source.relative_to(ROOT)} imports product authority package {imported}")
    for authority in (
        "PreparedOperation", "OperationReceipt", "AuditPort", "RunRepository",
        "ApprovalDecision", "CapabilityPolicy", "ToolExecutor", "ToolCatalog",
    ):
        if re.search(rf"\b{authority}\b", text):
            errors.append(f"agent_sdk exposes forbidden authority symbol {authority}: {source.relative_to(ROOT)}")

if not PUBLIC_TESTKIT.is_dir():
    errors.append("public omp_agent_testkit package is missing")
else:
    testkit_manifest = tomllib.loads((PUBLIC_TESTKIT / "cjpm.toml").read_text(encoding="utf-8"))
    testkit_dependencies = set(testkit_manifest.get("dependencies", {}))
    if testkit_dependencies != {"agent_sdk", "json4cj"}:
        errors.append(
            "omp_agent_testkit must depend only on agent_sdk and json4cj; got "
            + ", ".join(sorted(testkit_dependencies))
        )
    for source in sorted((PUBLIC_TESTKIT / "src").glob("**/*.cj")):
        text = source.read_text(encoding="utf-8")
        for imported in IMPORT.findall(text):
            if imported in TESTKIT_FORBIDDEN:
                errors.append(f"{source.relative_to(ROOT)} imports forbidden product/test authority {imported}")
        for line_number, line in enumerate(text.splitlines(), 1):
            if not re.search(r"^\s*public\s+(?:class|enum|struct|func|let)\b", line):
                continue
            if re.search(
                r"\b(?:PreparedOperation|OperationReceipt|AuditPort|RunRepository|"
                r"OperationRepository|ApprovalDecision|CapabilityPolicy|ToolExecutor|ToolCatalog|AgentError)\b",
                line,
            ):
                errors.append(
                    f"public testkit declaration exposes production authority: "
                    f"{source.relative_to(ROOT)}:{line_number}"
                )

for member in sorted(members):
    manifest_path = ROOT / member / "cjpm.toml"
    if not manifest_path.is_file() or member in {"agent_testkit", "omp_agent_testkit"}:
        continue
    manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    dependencies = set(manifest.get("dependencies", {}))
    for testkit_dependency in sorted(dependencies.intersection({"agent_testkit", "omp_agent_testkit"})):
        errors.append(
            f"production workspace package {member} depends on testkit package {testkit_dependency}"
        )

consumer_root = ROOT / "support_tests" / "testkit_consumer"
if not consumer_root.is_dir():
    errors.append("independent public testkit consumer is missing")
else:
    consumer_manifest = tomllib.loads((consumer_root / "cjpm.toml").read_text(encoding="utf-8"))
    consumer_dependencies = set(consumer_manifest.get("dependencies", {}))
    expected_consumer_dependencies = {"agent_sdk", "json4cj", "omp_agent_testkit"}
    if consumer_dependencies != expected_consumer_dependencies:
        errors.append(
            "testkit consumer dependency surface drifted; got "
            + ", ".join(sorted(consumer_dependencies))
        )
    for source in sorted((consumer_root / "src").glob("**/*.cj")):
        text = source.read_text(encoding="utf-8")
        for imported in IMPORT.findall(text):
            if imported in TESTKIT_FORBIDDEN:
                errors.append(f"{source.relative_to(ROOT)} imports forbidden host/internal package {imported}")

for relative_root in sorted(SDK_EXTENSION_ROOTS):
    extension_root = ROOT / relative_root
    if not extension_root.is_dir():
        errors.append(f"required SDK consumer is missing: {relative_root}")
        continue
    manifest_path = extension_root / "cjpm.toml"
    manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    dependencies = manifest.get("dependencies", {})
    if isinstance(dependencies, dict):
        for dependency in sorted(set(dependencies).intersection(EXTENSION_FORBIDDEN)):
            errors.append(f"{relative_root}/cjpm.toml depends on forbidden authority package {dependency}")
    for source in sorted((extension_root / "src").glob("**/*.cj")):
        text = source.read_text(encoding="utf-8")
        for imported in IMPORT.findall(text):
            if imported in EXTENSION_FORBIDDEN:
                errors.append(f"{source.relative_to(ROOT)} imports forbidden authority package {imported}")
        if re.search(r"\b(?:ToolExecutor|PreparedOperation|OperationReceipt|AuditPort|RunRepository|SubProcess|ManagedProcess)\b", text):
            errors.append(f"SDK consumer contains direct authority surface: {source.relative_to(ROOT)}")
        if re.search(r"^\s*import\s+(?:std\.process|std\.fs|stdx\.net)", text, re.MULTILINE):
            errors.append(f"SDK consumer imports a direct side-effect API: {source.relative_to(ROOT)}")

runtime_root = ROOT / "agent_extension_runtime"
if not runtime_root.is_dir():
    errors.append("internal agent_extension_runtime package is missing")
else:
    runtime_manifest = tomllib.loads((runtime_root / "cjpm.toml").read_text(encoding="utf-8"))
    runtime_dependencies = set(runtime_manifest.get("dependencies", {}))
    if runtime_dependencies != {"agent_sdk", "json4cj"}:
        errors.append(
            "agent_extension_runtime must depend only on agent_sdk and json4cj; got "
            + ", ".join(sorted(runtime_dependencies))
        )
    runtime_text = "\n".join(
        source.read_text(encoding="utf-8")
        for source in sorted((runtime_root / "src").glob("**/*.cj"))
    )
    manifest_match = re.search(
        r"public class ExtensionManifest\s*\{(?P<body>.*?)\n\}",
        runtime_text,
        re.DOTALL,
    )
    if manifest_match is None:
        errors.append("agent_extension_runtime has no explicit ExtensionManifest schema")
    else:
        body = manifest_match.group("body")
        for dangerous in (
            "approval", "trusted", "bypass", "preparedOperation", "receipt",
            "audit", "persistence", "sandbox",
        ):
            if re.search(rf"public let {dangerous}\b", body, re.IGNORECASE):
                errors.append(f"ExtensionManifest exposes forbidden authority field {dangerous}")

product_tools = (ROOT / "agent_product" / "src" / "tools.cj").read_text(encoding="utf-8")
if re.search(r"extensions\.install\(\s*(?:Workspace(?:Search|Write)|Ast|WebSearch)Extension", product_tools):
    errors.append("first-party SDK dogfood bypasses ExtensionRuntime lifecycle")
if "startBuiltInExtensionRuntime" not in product_tools:
    errors.append("first-party SDK dogfood is not assembled through ExtensionRuntime")
for legacy in ("installAstTools", "registerAstGrepTool", "registerAstEditTool", "installWebSearchTools"):
    if re.search(rf"\b{legacy}\b", product_tools):
        errors.append(f"migrated first-party extension retains legacy registration path {legacy}")

for source in sorted(ROOT.glob("**/*.cj")):
    relative = source.relative_to(ROOT)
    if "target" in relative.parts or ".git" in relative.parts:
        continue
    canonical_json = relative.parts[:2] == ("libs", "json4cj")
    canonical_process = relative.parts[:2] == ("libs", "process4cj")
    for match in DECLARATION.finditer(source.read_text(encoding="utf-8")):
        name = match.group(1) or match.group(2)
        if name in {"JsonValue", "JsonParser", "JsonEncoder", "parseJson", "encodeJson"}:
            if not canonical_json:
                errors.append(f"duplicate canonical JSON declaration {name}: {relative}")
        elif not canonical_process:
            errors.append(f"duplicate canonical process/framing declaration {name}: {relative}")

for source in sorted((ROOT / "agent_extensions" / "src").glob("*.cj")):
    text = source.read_text(encoding="utf-8")
    direct_effect_import = re.search(r"^\s*import\s+(?:std\.process|std\.fs|stdx\.)", text, re.MULTILINE)
    if direct_effect_import or "executeDirectly" in text:
        errors.append(f"extension has a direct side-effect surface: {source.relative_to(ROOT)}")

fail(errors)
print(f"reusable library boundaries passed ({len(found)} libraries)")

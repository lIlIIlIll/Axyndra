#!/usr/bin/env python3
"""Pinned OMP inventory and semantic-output comparison helper."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

BASELINE = "09a7c865636457c50ed75fc3b1a7cc21ef72c105"
ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs" / "omp-compat" / "reference-manifest.json"


def ordered_unique(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))


def arktype_schema(source: str, declaration: str) -> dict[str, Any]:
    marker = f"const {declaration} = type({{"
    start = source.index(marker) + len(marker)
    end = source.index("\n});", start)
    block = source[start:end]
    properties: dict[str, str] = {}
    required: list[str] = []
    for match in re.finditer(
        r'^\s*(?:"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*))'
        r'(\?)?:\s*([^\n]+)',
        block,
        re.MULTILINE,
    ):
        name = match.group(1) or match.group(2)
        optional = match.group(3) == "?"
        if name.endswith("?"):
            name = name[:-1]
            optional = True
        expression = match.group(4)
        if name == "env":
            kind = "object<string,string>"
        elif expression.startswith("searchPathEntry"):
            kind = "string"
        else:
            type_match = re.search(r'type\("([^"]+)"\)', expression)
            literal_match = re.match(r'"([^"]+)"', expression)
            if type_match:
                kind = type_match.group(1)
            elif literal_match:
                kind = literal_match.group(1)
            else:
                raise ValueError(
                    f"unsupported {declaration}.{name} schema: {expression}"
                )
        if name == "skip" and declaration == "searchSchema":
            kind = "number|null"
        properties[name] = kind
        if not optional:
            required.append(name)
    return {"properties": properties, "required": required}


def eval_arktype_schema(source: str) -> dict[str, Any]:
    common_marker = "const evalCellCommonFields = {"
    common_start = source.index(common_marker) + len(common_marker)
    common_end = source.index("\n};", common_start)
    common = source[common_start:common_end]
    schema_marker = "export const evalSchema = type({"
    schema_start = source.index(schema_marker) + len(schema_marker)
    schema_end = source.index("\n});", schema_start)
    schema = source[schema_start:schema_end].replace(
        "\t...evalCellCommonFields,",
        common,
    )
    synthetic = "const evalCompatSchema = type({" + schema + "\n});"
    return arktype_schema(synthetic, "evalCompatSchema")


def ast_edit_schema(source: str) -> dict[str, Any]:
    required_markers = [
        "const astEditOpSchema = type({",
        'pat: type("string").describe("ast pattern")',
        'out: type("string").describe("replacement template")',
        "const astEditSchema = type({",
        "ops: astEditOpSchema.array().atLeastLength(1)",
        'paths: type("string")',
        ".array()",
        ".atLeastLength(1)",
    ]
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream ast_edit schema marker: {marker}"
            )
    return {
        "properties": {
            "ops": "array<object{pat:string,out:string}>",
            "paths": "array<string>",
        },
        "required": ["ops", "paths"],
    }


def lsp_schema(source: str) -> dict[str, Any]:
    actions = (
        "'diagnostics' | 'definition' | 'references' | 'hover' | "
        "'symbols' | 'rename' | 'rename_file' | 'code_actions' | "
        "'type_definition' | 'implementation' | 'status' | 'reload' | "
        "'capabilities' | 'request'"
    )
    required_markers = [
        "export const lspSchema = type({",
        f'"{actions}"',
        'file: "string?"',
        'line: "number?"',
        'symbol: "string?"',
        'query: "string?"',
        'new_name: "string?"',
        'apply: "boolean?"',
        '"timeout?": type.number',
        'payload: "string?"',
    ]
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream lsp schema marker: {marker}"
            )
    return {
        "properties": {
            "action": actions,
            "file": "string",
            "line": "number",
            "symbol": "string",
            "query": "string",
            "new_name": "string",
            "apply": "boolean",
            "timeout": "number",
            "payload": "string",
        },
        "required": ["action"],
    }


def ask_schema(source: str) -> dict[str, Any]:
    required_markers = [
        "const OptionItem = arkType({",
        'label: arkType("string")',
        '"description?": arkType("string")',
        '"preview?": arkType("string")',
        "const QuestionItem = arkType({",
        'id: arkType("string")',
        'question: arkType("string")',
        '"header?": arkType("string")',
        "options: OptionItem.array()",
        '"multi?": arkType("boolean")',
        '"recommended?": arkType("number")',
        "questions: QuestionItem.array().atLeastLength(1)",
    ]
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream ask schema marker: {marker}"
            )
    return {
        "properties": {
            "questions": (
                "array<object{id:string,question:string,header?:string,"
                "options:array<object{label:string,description?:string,"
                "preview?:string}>,multi?:boolean,recommended?:number}>"
            )
        },
        "required": ["questions"],
    }


def memory_retain_schema(source: str) -> dict[str, Any]:
    required_markers = [
        "const memoryRetainSchema = type({",
        "items: type({",
        'content: type("string")',
        '"context?": type("string")',
        ".array()",
        ".atLeastLength(1)",
    ]
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream retain schema marker: {marker}"
            )
    return {
        "properties": {
            "items": "array<object{content:string,context?:string}>"
        },
        "required": ["items"],
    }


def learn_schema(source: str) -> dict[str, Any]:
    required_markers = [
        "const learnSchema = type({",
        'memory: type("string")',
        '"context?": type("string")',
        '"skill?": type({',
        'action: "\'create\' | \'update\'"',
        'name: type("string")',
        'description: type("string")',
        'body: type("string")',
    ]
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream learn schema marker: {marker}"
            )
    return {
        "properties": {
            "memory": "string",
            "context": "string",
            "skill": (
                "object{action:'create' | 'update',name:string,"
                "description:string,body:string}"
            ),
        },
        "required": ["memory"],
    }


def manage_skill_schema(source: str) -> dict[str, Any]:
    required_markers = [
        "const manageSkillSchema = type({",
        'action: "\'create\' | \'update\' | \'delete\'"',
        'name: type("string")',
        '"description?": type("string")',
        '"body?": type("string")',
        "p.action === \"delete\"",
        'used with both "description" and "body"',
    ]
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                "could not verify upstream manage_skill schema marker: "
                f"{marker}"
            )
    return {
        "properties": {
            "action": "'create' | 'update' | 'delete'",
            "name": "string",
            "description": "string",
            "body": "string",
        },
        "required": ["action", "name"],
    }


def github_schema(source: str) -> dict[str, Any]:
    operations = (
        "'repo_view' | 'file_read' | 'pr_create' | 'pr_checkout' | "
        "'pr_push' | 'search_issues' | 'search_prs' | 'search_code' | "
        "'search_commits' | 'search_repos' | 'run_watch'"
    )
    properties = {
        "op": operations,
        "repo": "string",
        "branch": "string",
        "path": "string",
        "pr": "string | string[]",
        "force": "boolean",
        "forceWithLease": "boolean",
        "title": "string",
        "body": "string",
        "base": "string",
        "head": "string",
        "draft": "boolean",
        "fill": "boolean",
        "reviewer": "string[]",
        "assignee": "string[]",
        "label": "string[]",
        "query": "string",
        "since": "string",
        "until": "string",
        "dateField": "'created' | 'updated'",
        "limit": "number",
        "run": "string",
        "tail": "number",
    }
    required_markers = [
        "const githubSchema = type({",
        f'"{operations}"',
    ]
    for name, kind in properties.items():
        if name == "op":
            continue
        required_markers.append(
            f'"{name}?": type("{kind}")'
        )
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream github schema marker: {marker}"
            )
    return {"properties": properties, "required": ["op"]}


def web_search_schema(source: str) -> dict[str, Any]:
    properties = {
        "query": "string",
        "recency": "'day' | 'week' | 'month' | 'year'",
        "limit": "number",
        "max_tokens": "number",
        "temperature": "number",
        "num_search_results": "number",
    }
    required_markers = [
        "export const webSearchSchema = type({",
        'query: "string"',
        'recency: "\'day\' | \'week\' | \'month\' | \'year\'?"',
        'limit: "number?"',
        'max_tokens: "number?"',
        'temperature: "number?"',
        'num_search_results: "number?"',
    ]
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream web_search schema marker: {marker}"
            )
    return {"properties": properties, "required": ["query"]}


def debug_schema(source: str) -> dict[str, Any]:
    actions = [
        "launch",
        "attach",
        "set_breakpoint",
        "remove_breakpoint",
        "set_instruction_breakpoint",
        "remove_instruction_breakpoint",
        "data_breakpoint_info",
        "set_data_breakpoint",
        "remove_data_breakpoint",
        "continue",
        "step_over",
        "step_in",
        "step_out",
        "pause",
        "evaluate",
        "stack_trace",
        "threads",
        "scopes",
        "variables",
        "disassemble",
        "read_memory",
        "write_memory",
        "modules",
        "loaded_sources",
        "custom_request",
        "output",
        "terminate",
        "sessions",
    ]
    fields = {
        "action": " | ".join(f"'{value}'" for value in actions),
        "program": "string",
        "args": "array<string>",
        "adapter": "string",
        "cwd": "string",
        "file": "string",
        "line": "number",
        "function": "string",
        "name": "string",
        "condition": "string",
        "hit_condition": "string",
        "expression": "string",
        "context": "string",
        "frame_id": "number",
        "scope_id": "number",
        "variable_ref": "number",
        "pid": "number",
        "port": "number",
        "host": "string",
        "levels": "number",
        "memory_reference": "string",
        "instruction_reference": "string",
        "instruction_count": "number",
        "instruction_offset": "number",
        "count": "number",
        "data": "string",
        "data_id": "string",
        "access_type": "'read' | 'write' | 'readWrite'",
        "command": "string",
        "arguments": "object",
        "offset": "number",
        "resolve_symbols": "boolean",
        "allow_partial": "boolean",
        "start_module": "number",
        "module_count": "number",
        "timeout": "number",
    }
    required_markers = [
        "const debugSchema = type({",
        "action: debugActionSchema",
        'args?": type("string[]")',
        '"access_type?": "\'read\' | \'write\' | \'readWrite\'"',
        '"arguments?": type({',
        '"[string]": "unknown"',
    ]
    for action in actions:
        required_markers.append(f'"{action}"')
    for field in fields:
        if field == "action":
            continue
        required_markers.append(field)
    for marker in required_markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream debug schema marker: {marker}"
            )
    return {"properties": fields, "required": ["action"]}


def verified_tool_schema(
    source: str,
    markers: list[str],
    properties: dict[str, str],
    required: list[str],
    name: str,
) -> dict[str, Any]:
    for marker in markers:
        if marker not in source:
            raise ValueError(
                f"could not verify upstream {name} schema marker: "
                + marker
            )
    return {"properties": properties, "required": required}


def task_schema(source: str) -> dict[str, Any]:
    return verified_tool_schema(
        source,
        [
            "const taskSchemaBatchNoIsolation = type({",
            'context: "string"',
            "tasks: taskItemSchema.array()",
            '"schemaMode?": \'"permissive" | "strict"\'',
        ],
        {
            "context": "string",
            "tasks": (
                "array<object{name?:string,agent?:string,task:string,"
                "outputSchema?:object | boolean | string | null,"
                "schemaMode?:'permissive' | 'strict'}>"
            ),
        },
        ["context", "tasks"],
        "task",
    )


def hub_schema(source: str) -> dict[str, Any]:
    return verified_tool_schema(
        source,
        [
            "const hubSchema = type({",
            (
                "'send' | 'wait' | 'inbox' | 'list' | 'jobs' | "
                "'cancel' | 'start' | 'ps' | 'logs' | 'stop' | "
                "'restart' | 'describe'"
            ),
            '"signal?"',
        ],
        {
            "op": (
                "'send' | 'wait' | 'inbox' | 'list' | 'jobs' | "
                "'cancel' | 'start' | 'ps' | 'logs' | 'stop' | "
                "'restart' | 'describe'"
            ),
            "to": "string",
            "message": "string",
            "replyTo": "string",
            "await": "boolean",
            "from": "string",
            "ids": "array<string>",
            "timeoutMs": "number",
            "peek": "boolean",
            "name": "string",
            "application": "string",
            "args": "array<string>",
            "env": "object<string,string>",
            "cwd": "string",
            "pty": "boolean",
            "ready": (
                "object{log?:string,port?:number,host?:string,"
                "timeout?:number}"
            ),
            "restart": "'no' | 'on-failure' | 'always'",
            "persist": "boolean",
            "detached": "boolean",
            "lines": "number",
            "head": "boolean",
            "grep": "string",
            "follow": "boolean",
            "cursor": "number",
            "for": "'ready' | 'exit'",
            "pattern": "string",
            "text": "string",
            "enter": "boolean",
            "keys": "array<string>",
            "signal": (
                "'SIGINT' | 'SIGTERM' | 'SIGHUP' | "
                "'SIGQUIT' | 'SIGKILL'"
            ),
            "timeout": "number",
        },
        ["op"],
        "hub",
    )


def todo_schema(source: str) -> dict[str, Any]:
    return verified_tool_schema(
        source,
        [
            "const todoSchema = type({",
            (
                '"init" | "start" | "done" | "rm" | "drop" | '
                '"block" | "unblock" | "append" | "view"'
            ),
            "InitListEntry.array()",
        ],
        {
            "op": (
                "'init' | 'start' | 'done' | 'rm' | 'drop' | "
                "'block' | 'unblock' | 'append' | 'view'"
            ),
            "list": (
                "array<object{phase:string,items:array<string>}>"
            ),
            "task": "string",
            "phase": "string",
            "items": "array<string>",
            "reason": "string",
        },
        ["op"],
        "todo",
    )


def yield_schema(source: str) -> dict[str, Any]:
    return verified_tool_schema(
        source,
        [
            "function wrapYieldParameters(",
            "properties: { data: dataSchema }",
            "properties: {",
            'error: { type: "string"',
            'required: ["result"]',
        ],
        {
            "type": "string | array<string>",
            "result": (
                "object{data:object} | object{error:string} | "
                "object{}"
            ),
        },
        ["result"],
        "yield",
    )


def extract(reference: Path) -> dict[str, Any]:
    coding = reference / "packages" / "coding-agent"
    cli = (coding / "src" / "cli-commands.ts").read_text()
    rpc = (coding / "src" / "modes" / "rpc" / "rpc-types.ts").read_text()
    slash = (
        coding / "src" / "slash-commands" / "builtin-registry.ts"
    ).read_text()
    args = (coding / "src" / "cli" / "args.ts").read_text()
    package = json.loads((coding / "package.json").read_text())
    tool_sources = coding / "src" / "tools"
    builtin_names = (tool_sources / "builtin-names.ts").read_text()
    edit_source = (
        coding / "src" / "edit" / "hashline" / "params.ts"
    ).read_text()
    eval_source = (tool_sources / "eval.ts").read_text()
    rpc_commands = rpc.split(
        "// ============================================================================\n"
        "// RPC State",
        1,
    )[0]
    mode_match = re.search(r"export type Mode = ([^;]+);", args)
    if mode_match is None:
        raise ValueError("could not locate the upstream Mode declaration")
    return {
        "baseline": BASELINE,
        "packageVersion": package["version"],
        "modes": re.findall(
            r'"(text|json|rpc|acp|rpc-ui)"', mode_match.group(1)
        ),
        "cliCommands": re.findall(
            r'\{ name: "([^"]+)"', cli.split("];", 1)[0]
        ),
        "rpcCommands": ordered_unique(
            re.findall(r'type: "([a-zA-Z0-9_]+)"', rpc_commands)
        ),
        "slashNames": ordered_unique(
            re.findall(r'name: "([^"]+)"', slash)
        ),
        "builtInToolNames": ordered_unique(
            re.findall(
                r'"([a-z][a-z0-9_]*)"',
                builtin_names.split(
                    "export const BUILTIN_TOOL_NAMES", 1
                )[1].split("export type BuiltinToolName", 1)[0]
                + builtin_names.split(
                    "export const HIDDEN_TOOL_NAMES", 1
                )[1].split("export type HiddenToolName", 1)[0],
            )
        ),
        "toolSchemas": {
            "read": arktype_schema(
                (tool_sources / "read.ts").read_text(), "readSchema"
            ),
            "write": arktype_schema(
                (tool_sources / "write.ts").read_text(), "writeSchema"
            ),
            "edit": arktype_schema(
                edit_source, "hashlineEditParamsSchema"
            ),
            "grep": arktype_schema(
                (tool_sources / "grep.ts").read_text(), "searchSchema"
            ),
            "glob": arktype_schema(
                (tool_sources / "glob.ts").read_text(), "findSchema"
            ),
            "bash": arktype_schema(
                (tool_sources / "bash.ts").read_text(),
                "bashSchemaWithAsync",
            ),
            "eval": eval_arktype_schema(eval_source),
            "ast_grep": arktype_schema(
                (tool_sources / "ast-grep.ts").read_text(),
                "astGrepSchema",
            ),
            "ast_edit": ast_edit_schema(
                (tool_sources / "ast-edit.ts").read_text()
            ),
            "checkpoint": arktype_schema(
                (tool_sources / "checkpoint.ts").read_text(),
                "checkpointSchema",
            ),
            "rewind": arktype_schema(
                (tool_sources / "checkpoint.ts").read_text(),
                "rewindSchema",
            ),
            "lsp": lsp_schema(
                (coding / "src" / "lsp" / "types.ts").read_text()
            ),
            "ask": ask_schema(
                (tool_sources / "ask.ts").read_text()
            ),
            "debug": debug_schema(
                (tool_sources / "debug.ts").read_text()
            ),
            "goal": arktype_schema(
                (
                    coding
                    / "src"
                    / "goals"
                    / "tools"
                    / "goal-tool.ts"
                ).read_text(),
                "goalSchema",
            ),
            "github": github_schema(
                (tool_sources / "gh.ts").read_text()
            ),
            "web_search": web_search_schema(
                (
                    coding
                    / "src"
                    / "web"
                    / "search"
                    / "index.ts"
                ).read_text()
            ),
            "memory_edit": arktype_schema(
                (tool_sources / "memory-edit.ts").read_text(),
                "memoryEditSchema",
            ),
            "retain": memory_retain_schema(
                (tool_sources / "memory-retain.ts").read_text()
            ),
            "recall": arktype_schema(
                (tool_sources / "memory-recall.ts").read_text(),
                "memoryRecallSchema",
            ),
            "reflect": arktype_schema(
                (tool_sources / "memory-reflect.ts").read_text(),
                "memoryReflectSchema",
            ),
            "learn": learn_schema(
                (tool_sources / "learn.ts").read_text()
            ),
            "manage_skill": manage_skill_schema(
                (tool_sources / "manage-skill.ts").read_text()
            ),
            "task": task_schema(
                (coding / "src" / "task" / "types.ts").read_text()
            ),
            "hub": hub_schema(
                (tool_sources / "hub" / "index.ts").read_text()
            ),
            "todo": todo_schema(
                (tool_sources / "todo.ts").read_text()
            ),
            "yield": yield_schema(
                (tool_sources / "yield.ts").read_text()
            ),
        },
    }


def normalize(value: Any) -> Any:
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            if key in {
                "timestamp",
                "createdAt",
                "updatedAt",
                "requestId",
                "responseId",
                "runId",
                "sessionId",
            }:
                result[key] = f"<{key}>"
            else:
                result[key] = normalize(item)
        return result
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, str):
        return re.sub(r"\x1b\[[0-9;]*m", "", value)
    return value


def inventory_check(reference: Path) -> int:
    expected = json.loads(MANIFEST.read_text())
    actual = extract(reference)
    if actual == expected:
        print(f"OMP inventory matches {BASELINE}")
        return 0
    print("OMP inventory drift detected", file=sys.stderr)
    for key in expected:
        if expected[key] != actual.get(key):
            print(
                json.dumps(
                    {
                        "surface": key,
                        "expected": expected[key],
                        "actual": actual.get(key),
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                file=sys.stderr,
            )
    return 1


def candidate_audit() -> int:
    """Report candidate surface coverage without treating decoding as support."""
    expected = json.loads(MANIFEST.read_text())
    app = (ROOT / "agent_app" / "src" / "main.cj").read_text()
    cli = (ROOT / "agent_cli" / "src" / "commands.cj").read_text()
    tools = "\n".join(
        path.read_text()
        for path in sorted((ROOT / "agent_product" / "src").glob("*.cj"))
    )
    rpc = (ROOT / "agent_rpc" / "src" / "product_rpc.cj").read_text()

    slash_block = cli.split(
        "public func slashCommandDefinitions()", 1
    )[1].split("public func availableSlashCommands()", 1)[0]
    candidate_slash = ordered_unique(
        re.findall(r'"([a-z][a-z0-9-]*)"', slash_block)
    )
    candidate_modes = ordered_unique(
        re.findall(r'mode == "(text|json|rpc|acp|rpc-ui)"', app)
    )
    candidate_cli = ordered_unique(
        re.findall(
            r'rawArguments\[1\] == "(__[a-z]+|[a-z][a-z0-9-]*)"',
            app,
        )
        + re.findall(
            r'cliCommand == "(__[a-z]+|[a-z][a-z0-9-]*)"',
            app,
        )
    )
    candidate_tools = ordered_unique(
        re.findall(
            r'ModelToolDefinition\(\s*"([a-z][a-z0-9_]*)"',
            tools,
        )
    )
    rpc_inventory = rpc.split(
        "public func availableRpcCommands()", 1
    )[1].split("func success(", 1)[0]
    decoded_rpc = ordered_unique(
        re.findall(r'"([a-z][a-z0-9_]+)"', rpc_inventory)
    )

    placeholders = {
        "todoWireValueOnly": "todoPhases = match" in rpc,
        "hostToolNamesOnly": "hostToolNames = namesFromList" in rpc,
        "hostUriSchemesOnly": "hostUriSchemes = namesFromList" in rpc,
        "queueModesStateOnly": "private func setQueueMode(" in rpc,
        "autoCompactionStateOnly": (
            'case "set_auto_compaction" =>' in rpc
            and "autoCompaction = productBoolField" in rpc
        ),
        "autoRetryStateOnly": (
            'case "set_auto_retry" =>' in rpc
            and "autoRetry = productBoolField" in rpc
        ),
        "abortRetryNoop": (
            'case "abort_retry" => success(id, command)' in rpc
        ),
        "sessionStatsZeroTokens": (
            'ValueField("inputTokens", integerValue(0))' in rpc
            and 'ValueField("outputTokens", integerValue(0))' in rpc
        ),
        "subagentEventBusUnavailable": (
            "Subagent event bus is unavailable" in rpc
        ),
    }

    def coverage(
        reference_values: list[str],
        candidate_values: list[str],
    ) -> dict[str, Any]:
        shared = [
            value for value in reference_values
            if value in candidate_values
        ]
        return {
            "referenceCount": len(reference_values),
            "candidateCount": len(candidate_values),
            "sharedCount": len(shared),
            "shared": shared,
            "missing": [
                value for value in reference_values
                if value not in candidate_values
            ],
            "candidateOnly": [
                value for value in candidate_values
                if value not in reference_values
            ],
        }

    report = {
        "baseline": BASELINE,
        "modes": coverage(expected["modes"], candidate_modes),
        "cliCommands": coverage(
            expected["cliCommands"],
            candidate_cli,
        ),
        "slashNames": coverage(
            expected["slashNames"],
            candidate_slash,
        ),
        "rpcCommands": coverage(
            expected["rpcCommands"],
            decoded_rpc,
        ),
        "builtInToolNames": coverage(
            expected["builtInToolNames"],
            candidate_tools,
        ),
        "knownRpcPlaceholders": placeholders,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if any(placeholders.values()) else 0


def semantic_compare(expected_path: Path, actual_path: Path) -> int:
    expected = normalize(json.loads(expected_path.read_text()))
    actual = normalize(json.loads(actual_path.read_text()))
    if expected == actual:
        print("semantic output matches")
        return 0
    print("semantic output differs", file=sys.stderr)
    print(
        json.dumps({"expected": expected, "actual": actual}, indent=2),
        file=sys.stderr,
    )
    return 1


def parse_output(source: str) -> list[Any]:
    stripped = re.sub(r"\x1b\[[0-9;]*m", "", source).strip()
    if stripped:
        try:
            return [normalize(json.loads(stripped))]
        except json.JSONDecodeError:
            pass
    values: list[Any] = []
    for line in source.splitlines():
        clean = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
        if not clean:
            continue
        try:
            values.append(normalize(json.loads(clean)))
        except json.JSONDecodeError:
            values.append(clean)
    return values


def run_scenario(command: str, scenario: dict[str, Any]) -> dict[str, Any]:
    with (
        tempfile.TemporaryDirectory(
            prefix="omp-compat-home-"
        ) as isolated_home,
        tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stdout,
        tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stderr,
    ):
        environment = os.environ.copy()
        work_root = Path(isolated_home) / "work"
        if scenario.get("isolatedHome"):
            environment["AXYNDRA_HOME"] = isolated_home
            environment["OMP_COMPAT_HOME"] = isolated_home
            environment["OMP_COMPAT_WORK"] = str(work_root)
        if scenario.get("workspaceFiles"):
            work_root.mkdir(parents=True, exist_ok=True)
            environment["OMP_COMPAT_WORK"] = str(work_root)
            for name, content in scenario["workspaceFiles"].items():
                target = work_root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
        if scenario.get("steps"):
            results: list[dict[str, Any]] = []
            for step in scenario["steps"]:
                completed = subprocess.run(
                    [
                        *shlex.split(command),
                        *step.get("args", []),
                    ],
                    input="\n".join(step.get("stdin", [])),
                    text=True,
                    capture_output=True,
                    env=environment,
                    timeout=step.get(
                        "timeoutSeconds",
                        scenario.get("timeoutSeconds", 10),
                    ),
                    check=False,
                )
                results.append({
                    "exitCode": completed.returncode,
                    "stdout": parse_output(completed.stdout),
                    "stderr": parse_output(completed.stderr),
                })
            return {"steps": results}
        process = subprocess.Popen(
            [*shlex.split(command), *scenario.get("args", [])],
            stdin=subprocess.PIPE,
            stdout=stdout,
            stderr=stderr,
            text=True,
            env=environment,
        )
        assert process.stdin is not None
        for line in scenario.get("stdin", []):
            process.stdin.write(line + "\n")
        process.stdin.flush()
        if scenario.get("stdin"):
            time.sleep(scenario.get("settleSeconds", 0.5))
        process.stdin.close()
        try:
            exit_code = process.wait(
                timeout=scenario.get("timeoutSeconds", 10)
            )
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            raise
        stdout.seek(0)
        stderr.seek(0)
        stdout_text = stdout.read()
        stderr_text = stderr.read()
    return {
        "exitCode": exit_code,
        "stdout": parse_output(stdout_text),
        "stderr": parse_output(stderr_text),
    }


def first_frame(result: dict[str, Any], frame_type: str) -> dict[str, Any]:
    for value in result["stdout"]:
        if isinstance(value, dict) and value.get("type") == frame_type:
            return value
    return {}


def response_frame(
    result: dict[str, Any], request_id: str
) -> dict[str, Any]:
    for value in result["stdout"]:
        if (
            isinstance(value, dict)
            and value.get("type") == "response"
            and value.get("id") == request_id
        ):
            return value
    return {}


def semantic_view(
    result: dict[str, Any], scenario: dict[str, Any]
) -> dict[str, Any]:
    projection = scenario.get("projection", "exact")
    if projection == "ssh_lifecycle":
        projected_steps: list[dict[str, Any]] = []
        for step in result.get("steps", []):
            payload = next(
                (
                    value
                    for value in step["stdout"]
                    if isinstance(value, dict)
                ),
                None,
            )
            if payload is None:
                json_lines = [
                    value
                    for value in step["stdout"]
                    if isinstance(value, str)
                ]
                try:
                    payload = json.loads("\n".join(json_lines))
                except json.JSONDecodeError:
                    payload = None
            text = "\n".join(
                value
                for stream in ("stdout", "stderr")
                for value in step[stream]
                if isinstance(value, str)
            )
            projected_steps.append({
                "exitCode": step["exitCode"],
                "payload": payload,
                "added": 'Added SSH host "alpha" to user config' in text,
                "duplicate": "already exists" in text,
                "removed": (
                    'Removed SSH host "alpha" from user config' in text
                ),
            })
        return {"steps": projected_steps}
    if projection == "exact":
        return result
    if projection == "help_surface":
        lines = [value for value in result["stdout"] if isinstance(value, str)]
        text = "\n".join(lines)
        shared = [
            "--model",
            "--cwd",
            "--mode",
            "--print",
            "--help",
            "--version",
        ]
        return {
            "exitCode": result["exitCode"],
            "sharedFlags": {
                flag: flag in text
                for flag in shared
            },
        }
    if projection == "version_surface":
        lines = [
            value
            for stream in ["stdout", "stderr"]
            for value in result[stream]
            if isinstance(value, str)
        ]
        match = re.search(r"\b(\d+\.\d+\.\d+)\b", "\n".join(lines))
        return {
            "exitCode": result["exitCode"],
            "compatibilityVersion": match.group(1) if match else None,
        }
    if projection == "unknown_flag":
        lines = [
            value
            for stream in ["stdout", "stderr"]
            for value in result[stream]
            if isinstance(value, str)
        ]
        text = "\n".join(lines).lower()
        return {
            "exitCode": result["exitCode"],
            "unknownFlag": "unknown flag" in text,
            "mentionsFlag": scenario["flag"].lower() in text,
        }
    if projection == "command_help_surface":
        lines = [
            value
            for stream in ["stdout", "stderr"]
            for value in result[stream]
            if isinstance(value, str)
        ]
        text = "\n".join(lines).lower()
        return {
            "exitCode": result["exitCode"],
            "tokens": {
                token: token.lower() in text
                for token in scenario["tokens"]
            },
        }
    if projection == "command_usage_error":
        lines = [
            value
            for stream in ["stdout", "stderr"]
            for value in result[stream]
            if isinstance(value, str)
        ]
        text = "\n".join(lines).lower()
        return {
            "failed": result["exitCode"] != 0,
            "tokens": {
                token: token.lower() in text
                for token in scenario["tokens"]
            },
        }
    if projection == "gc_empty":
        payload = next(
            (
                value
                for value in result["stdout"]
                if isinstance(value, dict)
            ),
            {},
        )
        view: dict[str, Any] = {
            "exitCode": result["exitCode"],
            "apply": payload.get("apply"),
            "subsystems": sorted(
                key
                for key in ("blobs", "archive", "wal")
                if key in payload
            ),
        }
        if isinstance(payload.get("blobs"), dict):
            view["blobs"] = payload["blobs"]
        if isinstance(payload.get("archive"), dict):
            view["archive"] = payload["archive"]
        wal = payload.get("wal")
        if isinstance(wal, dict):
            databases = wal.get("databases", [])
            view["wal"] = {
                "databaseCount": (
                    len(databases)
                    if isinstance(databases, list)
                    else None
                ),
                "databases": [
                    {
                        key: database.get(key)
                        for key in (
                            "walBytes",
                            "wouldCheckpoint",
                            "checkpointed",
                            "busy",
                            "log",
                            "checkpointedFrames",
                        )
                    }
                    for database in databases
                    if isinstance(database, dict)
                ],
                "walBytes": wal.get("walBytes"),
                "wouldCheckpoint": wal.get("wouldCheckpoint"),
                "checkpointed": wal.get("checkpointed"),
            }
        return view
    if projection == "usage_empty":
        payload = next(
            (
                value
                for value in result["stdout"]
                if isinstance(value, dict)
            ),
            {},
        )
        history = "entries" in payload
        if history:
            generated = payload.get("generatedAt")
            since = payload.get("sinceMs")
            return {
                "exitCode": result["exitCode"],
                "history": True,
                "hasGeneratedAt": isinstance(generated, int),
                "hasSinceMs": isinstance(since, int),
                "windowPositive": (
                    isinstance(generated, int)
                    and isinstance(since, int)
                    and generated > since
                ),
                "entries": payload.get("entries"),
            }
        return {
            "exitCode": result["exitCode"],
            "history": False,
            "hasGeneratedAt": isinstance(
                payload.get("generatedAt"),
                int,
            ),
            "reports": payload.get("reports"),
            "accountsWithoutUsage": payload.get(
                "accountsWithoutUsage"
            ),
            "disabledCredentials": payload.get(
                "disabledCredentials"
            ),
            "capacity": payload.get("capacity"),
        }
    if projection == "usage_no_credentials":
        lines = [
            value
            for stream in ("stdout", "stderr")
            for value in result[stream]
            if isinstance(value, str)
        ]
        text = "\n".join(lines).lower()
        return {
            "failed": result["exitCode"] != 0,
            "noCredentials": "no credentials found" in text,
            "mentionsLogin": "/login" in text,
        }
    if projection == "stats_exact":
        payload = next(
            (
                value
                for value in result["stdout"]
                if isinstance(value, dict)
            ),
            None,
        )
        if payload is None:
            json_lines = [
                value
                for value in result["stdout"]
                if (
                    isinstance(value, str)
                    and not value.startswith("Synced ")
                )
            ]
            try:
                payload = json.loads("\n".join(json_lines))
            except json.JSONDecodeError:
                payload = None
        stdout_lines = [
            value
            for value in result["stdout"]
            if isinstance(value, str)
        ]
        stderr_lines = [
            value
            for value in result["stderr"]
            if isinstance(value, str)
        ]
        return {
            "exitCode": result["exitCode"],
            "sync": next(
                (
                    value
                    for value in stdout_lines
                    if value.startswith("Synced ")
                ),
                None,
            ),
            "syncing": "Syncing session files..." in stderr_lines,
            "payload": payload,
        }
    if projection == "provider_stream":
        deltas: list[str] = []
        completed = False
        for frame in result["stdout"]:
            if not isinstance(frame, dict):
                continue
            update = frame.get("assistantMessageEvent")
            if (
                frame.get("type") == "message_update"
                and isinstance(update, dict)
                and update.get("type") == "text_delta"
                and isinstance(update.get("delta"), str)
            ):
                deltas.append(update["delta"])
            event = frame.get("event")
            if (
                frame.get("type") == "event"
                and isinstance(event, dict)
                and event.get("code") == "model.text_delta"
                and isinstance(event.get("text"), str)
            ):
                deltas.append(event["text"])
            if frame.get("type") == "agent_end":
                completed = True
            if (
                frame.get("type") == "result"
                and frame.get("status") == "completed"
                and frame.get("agent_invoked") is True
            ):
                completed = True
        return {
            "exitCode": result["exitCode"],
            "text": "".join(deltas),
            "expectedText": scenario["expectedText"],
            "completed": completed,
        }
    if projection == "empty_output":
        return {
            "exitCode": result["exitCode"],
            "stdoutEmpty": result["stdout"] == [],
            "stderrEmpty": result["stderr"] == [],
        }
    if projection == "json_session":
        session = first_frame(result, "session")
        return {
            "exitCode": result["exitCode"],
            "type": session.get("type"),
            "version": session.get("version"),
            "hasId": bool(session.get("id")),
            "hasTimestamp": bool(session.get("timestamp")),
            "hasCwd": bool(session.get("cwd")),
        }
    if projection == "rpc_state":
        ready = first_frame(result, "ready")
        response = response_frame(result, scenario["requestId"])
        data = response.get("data", {})
        state_keys = [
            "isStreaming",
            "isCompacting",
            "steeringMode",
            "followUpMode",
            "interruptMode",
            "autoCompactionEnabled",
            "fastModeEnabled",
            "fastModeActive",
            "tokensPerSecond",
            "messageCount",
            "queuedMessageCount",
            "todoPhases",
        ]
        return {
            "exitCode": result["exitCode"],
            "ready": {
                key: ready.get(key)
                for key in [
                    "protocolVersion",
                    "supportedProtocolVersions",
                    "maxFrameBytes",
                    "maxReassembledFrameBytes",
                ]
            },
            "response": {
                "command": response.get("command"),
                "success": response.get("success"),
                "state": {key: data.get(key) for key in state_keys},
            },
        }
    if projection == "rpc_ack":
        ready = first_frame(result, "ready")
        response = response_frame(result, scenario["requestId"])
        return {
            "exitCode": result["exitCode"],
            "protocolVersion": ready.get("protocolVersion"),
            "command": response.get("command"),
            "success": response.get("success"),
        }
    if projection == "rpc_local_command":
        ready = first_frame(result, "ready")
        response = response_frame(result, scenario["requestId"])
        output = ""
        invoked: bool | None = None
        data = response.get("data")
        if isinstance(data, dict) and isinstance(
            data.get("agentInvoked"), bool
        ):
            invoked = data["agentInvoked"]
        for frame in result["stdout"]:
            if not isinstance(frame, dict):
                continue
            if frame.get("type") == "command_output":
                candidate = frame.get("text", frame.get("output"))
                if isinstance(candidate, str):
                    output = candidate
            if (
                frame.get("type") == "prompt_result"
                and isinstance(frame.get("agentInvoked"), bool)
            ):
                invoked = frame["agentInvoked"]
        return {
            "exitCode": result["exitCode"],
            "protocolVersion": ready.get("protocolVersion"),
            "command": response.get("command"),
            "success": response.get("success"),
            "agentInvoked": invoked,
            "output": output,
        }
    if projection == "rpc_local_semantics":
        ready = first_frame(result, "ready")
        response = response_frame(result, scenario["requestId"])
        output = ""
        invoked: bool | None = None
        data = response.get("data")
        if isinstance(data, dict) and isinstance(
            data.get("agentInvoked"), bool
        ):
            invoked = data["agentInvoked"]
        for frame in result["stdout"]:
            if not isinstance(frame, dict):
                continue
            if frame.get("type") == "command_output":
                candidate = frame.get("text", frame.get("output"))
                if isinstance(candidate, str):
                    output = candidate
            if (
                frame.get("type") == "prompt_result"
                and isinstance(frame.get("agentInvoked"), bool)
            ):
                invoked = frame["agentInvoked"]
        return {
            "exitCode": result["exitCode"],
            "protocolVersion": ready.get("protocolVersion"),
            "command": response.get("command"),
            "success": response.get("success"),
            "agentInvoked": invoked,
            "outputPresent": bool(output.strip()),
        }
    raise ValueError(f"unknown scenario projection: {projection}")


def blackbox(
    scenarios_path: Path,
    baseline: str,
    candidate: str,
) -> int:
    scenarios = json.loads(scenarios_path.read_text())
    failures = 0
    for scenario in scenarios:
        expected_raw = run_scenario_with_retry(
            baseline,
            scenario,
            side="baseline",
        )
        actual_raw = run_scenario_with_retry(
            candidate,
            scenario,
            side="candidate",
        )
        expected = semantic_view(expected_raw, scenario)
        actual = semantic_view(actual_raw, scenario)
        if expected == actual:
            print(f"{scenario['id']}: match")
            continue
        failures += 1
        print(f"{scenario['id']}: mismatch", file=sys.stderr)
        print(
            json.dumps(
                {"baseline": expected, "candidate": actual},
                ensure_ascii=False,
                indent=2,
            ),
            file=sys.stderr,
        )
    return 1 if failures else 0


def run_scenario_with_retry(
    command: str,
    scenario: dict[str, Any],
    *,
    side: str,
) -> dict[str, Any]:
    try:
        return run_scenario(command, scenario)
    except subprocess.TimeoutExpired:
        print(
            f"{scenario['id']}: {side} timed out; retrying once",
            file=sys.stderr,
        )
        return run_scenario(command, scenario)


def split_schema_expression(source: str, delimiter: str) -> list[str]:
    values: list[str] = []
    start = 0
    angle = 0
    braces = 0
    quote = False
    index = 0
    while index < len(source):
        char = source[index]
        if char == "'":
            quote = not quote
        elif not quote:
            if char == "<":
                angle += 1
            elif char == ">":
                angle -= 1
            elif char == "{":
                braces += 1
            elif char == "}":
                braces -= 1
            elif (
                angle == 0
                and braces == 0
                and source.startswith(delimiter, index)
            ):
                values.append(source[start:index].strip())
                index += len(delimiter)
                start = index
                continue
        index += 1
    values.append(source[start:].strip())
    return [value for value in values if value]


def schema_union(values: list[dict[str, Any]]) -> dict[str, Any]:
    unique = {
        json.dumps(value, sort_keys=True): value
        for value in values
    }
    return {
        "union": [
            unique[key]
            for key in sorted(unique)
        ]
    }


def manifest_schema_type(source: str) -> dict[str, Any]:
    source = source.strip()
    union = split_schema_expression(source, " | ")
    if len(union) == 1 and "|" in source:
        union = split_schema_expression(source, "|")
    if len(union) > 1:
        return schema_union([
            manifest_schema_type(value)
            for value in union
        ])
    if source.startswith("'") and source.endswith("'"):
        return {"const": source[1:-1]}
    if source == "number.integer":
        return {"type": "integer"}
    if source.endswith("[]"):
        return {
            "type": "array",
            "items": manifest_schema_type(source[:-2]),
        }
    if source.startswith("array<") and source.endswith(">"):
        return {
            "type": "array",
            "items": manifest_schema_type(source[6:-1]),
        }
    if source == "object<string,string>":
        return {
            "type": "object",
            "additionalProperties": {"type": "string"},
        }
    if source.startswith("object{") and source.endswith("}"):
        properties: dict[str, Any] = {}
        required: list[str] = []
        for field in split_schema_expression(source[7:-1], ","):
            pieces = split_schema_expression(field, ":")
            if len(pieces) != 2:
                raise ValueError(
                    f"invalid object schema field: {field}"
                )
            name = pieces[0]
            optional = name.endswith("?")
            if optional:
                name = name[:-1]
            properties[name] = manifest_schema_type(pieces[1])
            if not optional:
                required.append(name)
        return {
            "type": "object",
            "properties": properties,
            "required": sorted(required),
        }
    if source in {"string", "number", "boolean", "object", "null"}:
        return {"type": source}
    raise ValueError(f"unsupported manifest schema type: {source}")


def candidate_schema_type(value: dict[str, Any]) -> dict[str, Any]:
    if isinstance(value.get("enum"), list):
        return schema_union([
            {"const": item}
            for item in value["enum"]
        ])
    alternatives = value.get("anyOf", value.get("oneOf"))
    if isinstance(alternatives, list):
        return schema_union([
            candidate_schema_type(item)
            for item in alternatives
            if isinstance(item, dict)
        ])
    kind = value.get("type")
    if isinstance(kind, list):
        return schema_union([
            {"type": item}
            for item in kind
        ])
    if kind == "array":
        items = value.get("items", {})
        return {
            "type": "array",
            "items": candidate_schema_type(
                items if isinstance(items, dict) else {}
            ),
        }
    if kind == "object":
        additional = value.get("additionalProperties")
        if isinstance(additional, dict):
            return {
                "type": "object",
                "additionalProperties": candidate_schema_type(
                    additional
                ),
            }
        properties = value.get("properties")
        if isinstance(properties, dict):
            return {
                "type": "object",
                "properties": {
                    name: candidate_schema_type(schema)
                    for name, schema in properties.items()
                    if isinstance(schema, dict)
                },
                "required": sorted(value.get("required", [])),
            }
    return {"type": kind}


def expected_tool_schema(value: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            name: manifest_schema_type(schema)
            for name, schema in value["properties"].items()
        },
        "required": sorted(value["required"]),
    }


def candidate_tool_schema_compatibility(
    name: str,
    expected: dict[str, Any],
    actual: dict[str, Any],
) -> tuple[bool, list[str]]:
    if expected == actual:
        return True, []
    allowed = {
        "read": {
            "offset": manifest_schema_type("number | null"),
            "limit": manifest_schema_type("number | null"),
            "destination": manifest_schema_type("string"),
        }
    }.get(name)
    if allowed is None:
        return False, []
    if (
        expected.get("type") != "object"
        or actual.get("type") != "object"
        or actual.get("required") != expected.get("required")
    ):
        return False, []
    expected_properties = expected.get("properties")
    actual_properties = actual.get("properties")
    if not isinstance(expected_properties, dict) or not isinstance(
        actual_properties, dict
    ):
        return False, []
    if any(
        actual_properties.get(field) != schema
        for field, schema in expected_properties.items()
    ):
        return False, []
    extensions = [
        field
        for field in actual_properties
        if field not in expected_properties
    ]
    if not extensions or any(
        field not in allowed or actual_properties[field] != allowed[field]
        for field in extensions
    ):
        return False, []
    return True, extensions


def candidate_tool_schema_check(candidate: str) -> int:
    request = json.dumps({
        "id": "tool-schema-check",
        "type": "get_state",
    })
    completed = subprocess.run(
        [*shlex.split(candidate), "--mode", "rpc"],
        input=request + "\n",
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )
    if completed.returncode != 0:
        print(
            "candidate tool-schema RPC failed: "
            + completed.stderr,
            file=sys.stderr,
        )
        return 1
    response: dict[str, Any] = {}
    for line in completed.stdout.splitlines():
        try:
            frame = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            frame.get("type") == "response"
            and frame.get("id") == "tool-schema-check"
        ):
            response = frame
    data = response.get("data", {})
    dump_tools = data.get("dumpTools", []) if isinstance(data, dict) else []
    actual = {
        value["name"]: value.get("parameters", {})
        for value in dump_tools
        if (
            isinstance(value, dict)
            and isinstance(value.get("name"), str)
            and isinstance(value.get("parameters"), dict)
        )
    }
    expected = json.loads(MANIFEST.read_text())["toolSchemas"]
    failures = 0
    for name, schema in expected.items():
        if name not in actual:
            failures += 1
            print(
                f"tool schema missing from candidate: {name}",
                file=sys.stderr,
            )
            continue
        expected_view = expected_tool_schema(schema)
        actual_view = candidate_schema_type(actual[name])
        compatible, extensions = candidate_tool_schema_compatibility(
            name,
            expected_view,
            actual_view,
        )
        if compatible and extensions:
            print(
                f"tool-schema-{name}: match + optional extensions "
                f"({', '.join(extensions)})"
            )
            continue
        if compatible:
            print(f"tool-schema-{name}: match")
            continue
        failures += 1
        print(f"tool-schema-{name}: mismatch", file=sys.stderr)
        print(
            json.dumps(
                {
                    "baseline": expected_view,
                    "candidate": actual_view,
                },
                ensure_ascii=False,
                indent=2,
            ),
            file=sys.stderr,
        )
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    inventory = commands.add_parser("inventory-check")
    inventory.add_argument("--reference", required=True, type=Path)
    commands.add_parser("candidate-audit")
    schema_check = commands.add_parser("candidate-schema-check")
    schema_check.add_argument("--candidate", required=True)
    compare = commands.add_parser("compare")
    compare.add_argument("--expected", required=True, type=Path)
    compare.add_argument("--actual", required=True, type=Path)
    scenarios = commands.add_parser("blackbox")
    scenarios.add_argument("--scenarios", required=True, type=Path)
    scenarios.add_argument("--baseline", required=True)
    scenarios.add_argument("--candidate", required=True)
    options = parser.parse_args()
    if options.command == "inventory-check":
        return inventory_check(options.reference)
    if options.command == "candidate-audit":
        return candidate_audit()
    if options.command == "candidate-schema-check":
        return candidate_tool_schema_check(options.candidate)
    if options.command == "compare":
        return semantic_compare(options.expected, options.actual)
    return blackbox(
        options.scenarios,
        options.baseline,
        options.candidate,
    )


if __name__ == "__main__":
    raise SystemExit(main())

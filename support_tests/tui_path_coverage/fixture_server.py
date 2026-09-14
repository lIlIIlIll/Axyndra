#!/usr/bin/env python3
"""Case-driven local Provider SSE and MCP fixture for real TUI runs.

The fixture deliberately speaks the public wire protocols.  It does not import
agent code or construct TuiAgentEvent values.  Every request, response event,
and MCP call is recorded so the runner can distinguish a visible frame from a
real integration side effect.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterable


REDACTED = "[REDACTED]"


def now() -> float:
    return time.time()


def append_json(path: Path | None, value: dict[str, Any]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")


def safe_headers(headers: Any) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, value in headers.items():
        normalized = key.lower()
        result[normalized] = REDACTED if normalized in {
            "authorization",
            "x-api-key",
            "proxy-authorization",
            "cookie",
        } else value
    return result


def text_values(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from text_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from text_values(child)


def request_contains(request: dict[str, Any], needle: str) -> bool:
    return any(needle in value for value in text_values(request))


def rule_matches(request: dict[str, Any], rule: dict[str, Any]) -> bool:
    needles = rule.get("contains", [])
    if isinstance(needles, str):
        needles = [needles]
    if not isinstance(needles, list) or not all(
        isinstance(needle, str) and request_contains(request, needle)
        for needle in needles
    ):
        return False
    request_input = request.get("input")
    last_input = request_input[-1] if isinstance(request_input, list) and request_input else {}
    last_needles = rule.get("last_contains", [])
    if isinstance(last_needles, str):
        last_needles = [last_needles]
    if not isinstance(last_needles, list) or not all(
        isinstance(needle, str) and request_contains(last_input, needle)
        for needle in last_needles
    ):
        return False
    last_role = rule.get("last_input_role")
    if isinstance(last_role, str) and last_input.get("role") != last_role:
        return False
    last_type = rule.get("last_input_type")
    if isinstance(last_type, str) and last_input.get("type") != last_type:
        return False
    return True


def response_created(response_id: str) -> dict[str, Any]:
    return {
        "type": "response.created",
        "response": {"id": response_id, "status": "in_progress", "output": []},
    }


def responses_text_events(
    response_id: str,
    chunks: list[str],
    *,
    reasoning: str = "",
    input_tokens: int = 7,
    output_tokens: int = 5,
) -> list[dict[str, Any]]:
    text = "".join(chunks)
    events: list[dict[str, Any]] = [response_created(response_id)]
    reasoning_item: dict[str, Any] | None = None
    if reasoning:
        reasoning_id = f"reason_{response_id}"
        reasoning_item = {
            "type": "reasoning",
            "id": reasoning_id,
            "status": "completed",
            "summary": [{"type": "summary_text", "text": reasoning}],
        }
        events.extend(
            [
                {
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": {
                        "type": "reasoning",
                        "id": reasoning_id,
                        "status": "in_progress",
                        "summary": [],
                    },
                },
                {
                    "type": "response.reasoning_summary_part.added",
                    "item_id": reasoning_id,
                    "output_index": 0,
                    "summary_index": 0,
                    "part": {"type": "summary_text", "text": ""},
                },
                {
                    "type": "response.reasoning_summary_text.delta",
                    "item_id": reasoning_id,
                    "output_index": 0,
                    "summary_index": 0,
                    "delta": reasoning,
                },
                {
                    "type": "response.reasoning_summary_part.done",
                    "item_id": reasoning_id,
                    "output_index": 0,
                    "summary_index": 0,
                    "part": {"type": "summary_text", "text": reasoning},
                },
                {
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item_id": reasoning_id,
                    "item": reasoning_item,
                },
            ]
        )
    output_index = 1 if reasoning else 0
    item_id = f"msg_{response_id}"
    message_item = {
        "type": "message",
        "id": item_id,
        "role": "assistant",
        "status": "completed",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }
    events.extend(
        [
            {
                "type": "response.output_item.added",
                "output_index": output_index,
                "item": {
                    "type": "message",
                    "id": item_id,
                    "role": "assistant",
                    "status": "in_progress",
                    "content": [],
                },
            },
            {
                "type": "response.content_part.added",
                "item_id": item_id,
                "output_index": output_index,
                "content_index": 0,
                "part": {"type": "output_text", "text": "", "annotations": []},
            },
        ]
    )
    for chunk in chunks:
        events.append(
            {
                "type": "response.output_text.delta",
                "item_id": item_id,
                "output_index": output_index,
                "content_index": 0,
                "delta": chunk,
            }
        )
    events.extend(
        [
            {
                "type": "response.output_text.done",
                "item_id": item_id,
                "output_index": output_index,
                "content_index": 0,
                "text": text,
            },
            {
                "type": "response.content_part.done",
                "item_id": item_id,
                "output_index": output_index,
                "content_index": 0,
                "part": {"type": "output_text", "text": text, "annotations": []},
            },
            {
                "type": "response.output_item.done",
                "output_index": output_index,
                "item_id": item_id,
                "item": message_item,
            },
            {
                "type": "response.completed",
                "response": {
                    "id": response_id,
                    "status": "completed",
                    "output": ([reasoning_item] if reasoning_item else []) + [message_item],
                    "usage": {
                        "input_tokens": input_tokens,
                        "output_tokens": output_tokens,
                        "input_tokens_details": {
                            "cached_tokens": 2,
                            "cache_write_tokens": 1,
                        },
                        "output_tokens_details": {"reasoning_tokens": 1 if reasoning else 0},
                    },
                },
            },
        ]
    )
    return events


def responses_text_body(
    response_id: str,
    chunks: list[str],
    *,
    reasoning: str = "",
    input_tokens: int = 7,
    output_tokens: int = 5,
) -> dict[str, Any]:
    text = "".join(chunks)
    message_item: dict[str, Any] = {
        "type": "message",
        "id": f"msg_{response_id}",
        "role": "assistant",
        "status": "completed",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }
    output: list[dict[str, Any]] = []
    if reasoning:
        output.append(
            {
                "type": "reasoning",
                "id": f"reason_{response_id}",
                "status": "completed",
                "summary": [{"type": "summary_text", "text": reasoning}],
            }
        )
    output.append(message_item)
    return {
        "id": response_id,
        "status": "completed",
        "output": output,
        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "input_tokens_details": {"cached_tokens": 2, "cache_write_tokens": 1},
            "output_tokens_details": {"reasoning_tokens": 1 if reasoning else 0},
        },
    }



def fixed_text_body(
    protocol: str,
    response_id: str,
    chunks: list[str],
    *,
    reasoning: str = "",
    input_tokens: int = 7,
    output_tokens: int = 5,
) -> dict[str, Any]:
    text = "".join(chunks)
    if protocol == "responses":
        return responses_text_body(
            response_id,
            chunks,
            reasoning=reasoning,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
        )
    if protocol == "completions":
        message: dict[str, Any] = {"role": "assistant", "content": text}
        if reasoning:
            message["reasoning_content"] = reasoning
        return {
            "id": response_id,
            "model": "coverage-model",
            "choices": [
                {
                    "index": 0,
                    "message": message,
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": input_tokens,
                "completion_tokens": output_tokens,
            },
        }
    return {
        "id": response_id,
        "type": "message",
        "role": "assistant",
        "model": "coverage-model",
        "content": [{"type": "text", "text": text}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens},
    }

def responses_tool_events(
    response_id: str,
    name: str,
    arguments: str,
) -> list[dict[str, Any]]:
    call = {
        "type": "function_call",
        "id": f"fc_{response_id}",
        "call_id": f"call_{response_id}",
        "name": name,
        "arguments": arguments,
    }
    return [
        response_created(response_id),
        {"type": "response.output_item.added", "output_index": 0, "item": call},
        {
            "type": "response.function_call_arguments.done",
            "output_index": 0,
            "item_id": call["id"],
            "name": name,
            "arguments": arguments,
        },
        {
            "type": "response.output_item.done",
            "output_index": 0,
            "item_id": call["id"],
            "item": call,
        },
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "status": "completed",
                "output": [call],
                "usage": {"input_tokens": 8, "output_tokens": 2},
            },
        },
    ]


def chat_events(
    response_id: str,
    chunks: list[str],
    *,
    reasoning: str = "",
    input_tokens: int = 7,
    output_tokens: int = 5,
) -> list[dict[str, Any] | str]:
    events: list[dict[str, Any] | str] = []
    if reasoning:
        events.append(
            {
                "id": response_id,
                "model": "coverage-model",
                "choices": [
                    {
                        "index": 0,
                        "delta": {"reasoning_content": reasoning},
                        "finish_reason": None,
                    }
                ],
                "usage": None,
            }
        )
    for chunk in chunks:
        events.append(
            {
                "id": response_id,
                "model": "coverage-model",
                "choices": [
                    {
                        "index": 0,
                        "delta": {"content": chunk},
                        "finish_reason": None,
                    }
                ],
                "usage": None,
            }
        )
    events.extend(
        [
            {
                "id": response_id,
                "model": "coverage-model",
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": None,
            },
            {
                "id": response_id,
                "model": "coverage-model",
                "choices": [],
                "usage": {
                    "prompt_tokens": input_tokens,
                    "completion_tokens": output_tokens,
                    "prompt_tokens_details": {"cached_tokens": 2, "cache_write_tokens": 1},
                    "completion_tokens_details": {"reasoning_tokens": 1 if reasoning else 0},
                },
            },
            "[DONE]",
        ]
    )
    return events


def messages_events(
    response_id: str,
    chunks: list[str],
    *,
    reasoning: str = "",
    input_tokens: int = 7,
    output_tokens: int = 5,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = [
        {
            "type": "message_start",
            "message": {
                "id": response_id,
                "type": "message",
                "role": "assistant",
                "content": [],
                "model": "coverage-model",
                "stop_reason": None,
                "usage": {"input_tokens": input_tokens},
            },
        },
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""},
        },
    ]
    if reasoning:
        events.append(
            {
                "type": "content_block_start",
                "index": 1,
                "content_block": {"type": "thinking", "thinking": ""},
            }
        )
        events.append(
            {
                "type": "content_block_delta",
                "index": 1,
                "delta": {"type": "thinking_delta", "thinking": reasoning},
            }
        )
        events.append({"type": "content_block_stop", "index": 1})
    for chunk in chunks:
        events.append(
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": chunk},
            }
        )
    events.extend(
        [
            {"type": "content_block_stop", "index": 0},
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn"},
                "usage": {"output_tokens": output_tokens},
            },
            {"type": "message_stop"},
        ]
    )
    return events


def mcp_result(request_id: Any, *, text: str = "fixture MCP result") -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {
            "resultType": "complete",
            "content": [{"type": "text", "text": text}],
            "structuredContent": {
                "case": "tui-path-coverage",
                "workspaceReadOnly": True,
                "networkAllowed": False,
            },
            "isError": False,
            "_meta": {
                "io.modelcontextprotocol/serverInfo": {
                    "name": "tui-path-coverage",
                    "version": "1.0.0",
                }
            },
        },
    }


def mcp_error(request_id: Any, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": message}}


@dataclass
class FixtureState:
    behavior: dict[str, Any]
    request_log: Path | None
    stream_log: Path | None
    mcp_log: Path | None
    request_count: int = 0
    lock: threading.Lock = threading.Lock()

    def next_request(self, record: dict[str, Any]) -> int:
        with self.lock:
            self.request_count += 1
            index = self.request_count
        record["request_index"] = index
        record["time"] = now()
        append_json(self.request_log, record)
        return index


def gate_wait(path_text: str | None, timeout: float = 30.0) -> bool:
    if not path_text:
        return True
    path = Path(path_text)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return True
        time.sleep(0.01)
    return False


def event_specs(events: list[Any], behavior: dict[str, Any]) -> list[dict[str, Any]]:
    gates = behavior.get("gates", {})
    delays = behavior.get("delays", {})
    output: list[dict[str, Any]] = []
    for index, payload in enumerate(events):
        spec: dict[str, Any] = {"payload": payload, "index": index}
        if str(index) in gates:
            spec["gate_after"] = gates[str(index)]
        elif index in gates:
            spec["gate_after"] = gates[index]
        if str(index) in delays:
            spec["delay_after"] = float(delays[str(index)])
        elif index in delays:
            spec["delay_after"] = float(delays[index])
        output.append(spec)
    return output


class ProviderHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _state(self) -> FixtureState:
        return self.server.fixture_state  # type: ignore[attr-defined]

    def _behavior_for_request(self, request: dict[str, Any], index: int) -> dict[str, Any]:
        behavior = self._state().behavior
        rules = behavior.get("rules")
        if isinstance(rules, list):
            for rule in rules:
                if isinstance(rule, dict) and rule_matches(request, rule):
                    merged = dict(behavior)
                    merged.update(rule)
                    return merged
        responses = behavior.get("responses")
        if isinstance(responses, list) and responses:
            position = min(index - 1, len(responses) - 1)
            selected = responses[position]
            if isinstance(selected, dict):
                merged = dict(behavior)
                merged.update(selected)
                return merged
        return behavior

    def _read_json(self) -> tuple[dict[str, Any], bytes]:
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length)
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            value = {"_malformed": raw.decode("utf-8", errors="replace")}
        return value if isinstance(value, dict) else {"value": value}, raw
    def do_GET(self) -> None:
        if self.path in {"/health", "/ready"}:
            payload = b"ok\n"
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", str(len(payload)))
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404)

    def do_POST(self) -> None:
        state = self._state()
        if state.behavior.get("mode") == "mcp-http":
            self._do_mcp_http(state)
            return
        request, raw = self._read_json()
        index = state.next_request(
            {
                "kind": "provider_request",
                "method": "POST",
                "path": self.path,
                "headers": safe_headers(self.headers),
                "body_bytes": len(raw),
                "request": request,
            }
        )
        behavior = self._behavior_for_request(request, index)
        error = behavior.get("error")
        if isinstance(error, dict) and int(error.get("status", 0)) > 0:
            self._write_error(int(error["status"]), str(error.get("body", "fixture error")), state, index)
            return
        protocol = (
            "messages"
            if self.path.endswith("/v1/messages")
            else "completions"
            if self.path.endswith("/v1/chat/completions")
            else "responses"
        )
        kind = str(behavior.get("kind", "text"))
        response_id = f"coverage-{index}"
        chunks: list[str] = []
        reasoning = ""
        events: list[Any] = []
        if kind == "tool" and (
            bool(behavior.get("force_tool", False))
            or not request_contains(request, "function_call_output")
        ):
            name = str(behavior.get("tool_name", "mcp__fixture__environment"))
            arguments = json.dumps(behavior.get("tool_arguments", {}), separators=(",", ":"))
            events = responses_tool_events(response_id, name, arguments)
        else:
            chunks = behavior.get("chunks", [str(behavior.get("response_text", "coverage response"))])
            chunks = [str(item) for item in chunks]
            reasoning = str(behavior.get("reasoning", ""))
            if protocol == "messages":
                events = messages_events(response_id, chunks, reasoning=reasoning)
            elif protocol == "completions":
                events = chat_events(response_id, chunks, reasoning=reasoning)
            else:
                events = responses_text_events(response_id, chunks, reasoning=reasoning)
        if not bool(request.get("stream", False)) and kind != "tool":
            body = json.dumps(
                fixed_text_body(protocol, response_id, chunks, reasoning=reasoning),
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.send_header("connection", "close")
            self.end_headers()
            try:
                self.wfile.write(body)
                self.wfile.flush()
                append_json(
                    state.stream_log,
                    {"kind": "provider_response", "request_index": index, "protocol": protocol},
                )
            except (BrokenPipeError, ConnectionResetError):
                append_json(state.stream_log, {"kind": "provider_disconnect", "request_index": index})
            return
        self._stream_events(protocol, events, behavior, state, index)

    def _write_error(
        self,
        status: int,
        body_text: str,
        state: FixtureState,
        index: int,
    ) -> None:
        body = body_text.encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
            self.wfile.flush()
            append_json(state.stream_log, {"kind": "http_error", "request_index": index, "status": status})
        except (BrokenPipeError, ConnectionResetError):
            append_json(state.stream_log, {"kind": "provider_disconnect", "request_index": index, "status": status})

    def _stream_events(
        self,
        protocol: str,
        events: list[Any],
        behavior: dict[str, Any],
        state: FixtureState,
        request_index: int,
    ) -> None:
        ending = str(behavior.get("line_ending", "\n"))
        if ending not in {"\n", "\r\n"}:
            ending = "\n"
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        fixed_chunks = behavior.get("wire_chunk_size")
        for event_index, spec in enumerate(event_specs(events, behavior)):
            payload = spec["payload"]
            if payload == "[DONE]":
                encoded = f"data: [DONE]{ending}{ending}".encode("utf-8")
                event_type = "[DONE]"
            else:
                encoded_json = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
                encoded = f"data: {encoded_json}{ending}{ending}".encode("utf-8")
                event_type = payload.get("type", "json") if isinstance(payload, dict) else "json"
            append_json(
                state.stream_log,
                {
                    "kind": "provider_event",
                    "request_index": request_index,
                    "event_index": event_index,
                    "protocol": protocol,
                    "event_type": event_type,
                    "bytes": len(encoded),
                    "wire_chunk_size": fixed_chunks,
                },
            )
            try:
                if isinstance(fixed_chunks, int) and fixed_chunks > 0:
                    for offset in range(0, len(encoded), fixed_chunks):
                        self.wfile.write(encoded[offset : offset + fixed_chunks])
                        self.wfile.flush()
                        time.sleep(float(behavior.get("chunk_delay", 0.0)))
                else:
                    self.wfile.write(encoded)
                    self.wfile.flush()
                gate = spec.get("gate_after")
                if gate and not gate_wait(str(gate), float(behavior.get("gate_timeout", 30.0))):
                    append_json(
                        state.stream_log,
                        {"kind": "gate_timeout", "request_index": request_index, "event_index": event_index},
                    )
                    return
                delay = float(spec.get("delay_after", behavior.get("event_delay", 0.0)))
                if delay > 0:
                    time.sleep(delay)
            except (BrokenPipeError, ConnectionResetError):
                append_json(
                    state.stream_log,
                    {"kind": "provider_disconnect", "request_index": request_index, "event_index": event_index},
                )
                return

    def _do_mcp_http(self, state: FixtureState) -> None:
        request, raw = self._read_json()
        request_id = request.get("id")
        method = request.get("method", "")
        append_json(
            state.mcp_log,
            {
                "kind": "mcp_request",
                "transport": "http",
                "method": method,
                "id": request_id,
                "request": request,
                "body_bytes": len(raw),
                "time": now(),
            },
        )
        if method in {"initialize", "server/discover"}:
            result: dict[str, Any] = {
                "resultType": "complete",
                "protocolVersion": "2026-07-28",
                "supportedVersions": ["2026-07-28"],
                "capabilities": {"tools": {"listChanged": False}},
                "ttlMs": 0,
                "cacheScope": "private",
                "serverInfo": {"name": "tui-path-coverage", "version": "1.0.0"},
            }
            response: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "result": result}
        elif method == "tools/list":
            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "tools": [
                        {
                            "name": "environment",
                            "description": "return deterministic fixture state",
                            "inputSchema": {"type": "object", "properties": {}},
                            "annotations": {"readOnlyHint": True},
                        }
                    ],
                    "ttlMs": 0,
                    "cacheScope": "private",
                },
            }
        elif method == "tools/call":
            response = mcp_result(request_id)
        else:
            response = mcp_error(request_id, "unsupported MCP method")
        body = json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            append_json(state.mcp_log, {"kind": "mcp_disconnect", "id": request_id, "time": now()})

    def log_message(self, *_args: Any) -> None:
        return


def run_stdio(args: argparse.Namespace, behavior: dict[str, Any]) -> int:
    log_path = Path(args.mcp_log) if args.mcp_log else None
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as error:
            append_json(log_path, {"kind": "mcp_invalid_json", "error": str(error), "time": now()})
            continue
        if not isinstance(request, dict):
            continue
        request_id = request.get("id")
        method = request.get("method", "")
        append_json(
            log_path,
            {"kind": "mcp_request", "transport": "stdio", "method": method, "id": request_id, "request": request, "time": now()},
        )
        if method in {"initialize", "server/discover"}:
            result: dict[str, Any] = {
                "resultType": "complete",
                "protocolVersion": "2026-07-28",
                "supportedVersions": ["2026-07-28"],
                "capabilities": {"tools": {"listChanged": False}},
                "ttlMs": 0,
                "cacheScope": "private",
                "serverInfo": {"name": "tui-path-coverage", "version": "1.0.0"},
            }
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        elif method == "tools/list":
            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "tools": [
                        {
                            "name": "environment",
                            "description": "return deterministic fixture state",
                            "inputSchema": {"type": "object", "properties": {}},
                            "annotations": {"readOnlyHint": True},
                        }
                    ],
                    "ttlMs": 0,
                    "cacheScope": "private",
                },
            }
        elif method == "tools/call":
            arguments = request.get("params", {}).get("arguments", {})
            text = "fixture MCP result"
            if isinstance(arguments, dict) and arguments.get("marker"):
                text += " " + str(arguments["marker"])
            response = mcp_result(request_id, text=text)
            append_json(log_path, {"kind": "mcp_tool_call", "id": request_id, "arguments": arguments, "time": now()})
        else:
            response = mcp_error(request_id, "unsupported MCP method")
        sys.stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    return 0


def run_http(args: argparse.Namespace, behavior: dict[str, Any]) -> int:
    state = FixtureState(
        behavior={**behavior, "mode": "mcp-http"},
        request_log=Path(args.request_log) if args.request_log else None,
        stream_log=Path(args.stream_log) if args.stream_log else None,
        mcp_log=Path(args.mcp_log) if args.mcp_log else None,
    )
    server = ThreadingHTTPServer(("127.0.0.1", args.port), ProviderHandler)
    server.daemon_threads = True
    server.fixture_state = state  # type: ignore[attr-defined]
    port = int(server.server_address[1])
    if args.port_file:
        Path(args.port_file).write_text(str(port) + "\n", encoding="utf-8")
    if args.ready_file:
        Path(args.ready_file).write_text(
            json.dumps({"mode": "mcp-http", "port": port, "case_id": args.case_id}) + "\n",
            encoding="utf-8",
        )
    print("TUI_PATH_COVERAGE_READY", file=sys.stderr, flush=True)
    try:
        server.serve_forever(poll_interval=0.05)
    finally:
        server.server_close()
    return 0


def run_provider(args: argparse.Namespace, behavior: dict[str, Any]) -> int:
    state = FixtureState(
        behavior=behavior,
        request_log=Path(args.request_log) if args.request_log else None,
        stream_log=Path(args.stream_log) if args.stream_log else None,
        mcp_log=Path(args.mcp_log) if args.mcp_log else None,
    )
    server = ThreadingHTTPServer(("127.0.0.1", args.port), ProviderHandler)
    server.daemon_threads = True
    server.fixture_state = state  # type: ignore[attr-defined]
    port = int(server.server_address[1])
    if args.port_file:
        Path(args.port_file).write_text(str(port) + "\n", encoding="utf-8")
    if args.ready_file:
        Path(args.ready_file).write_text(
            json.dumps({"mode": "provider", "port": port, "case_id": args.case_id}) + "\n",
            encoding="utf-8",
        )
    print("TUI_PATH_COVERAGE_READY", file=sys.stderr, flush=True)
    try:
        server.serve_forever(poll_interval=0.05)
    finally:
        server.server_close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("provider", "mcp-stdio", "mcp-http"), default="provider")
    parser.add_argument("--case-id", default="unknown")
    parser.add_argument("--behavior-file", type=Path)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", type=Path)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--request-log", type=Path)
    parser.add_argument("--stream-log", type=Path)
    parser.add_argument("--mcp-log", type=Path)
    args = parser.parse_args()
    behavior: dict[str, Any] = {}
    if args.behavior_file and args.behavior_file.is_file():
        behavior = json.loads(args.behavior_file.read_text(encoding="utf-8"))
    if args.mode == "mcp-stdio":
        return run_stdio(args, behavior)
    if args.mode == "mcp-http":
        return run_http(args, behavior)
    return run_provider(args, behavior)


if __name__ == "__main__":
    raise SystemExit(main())

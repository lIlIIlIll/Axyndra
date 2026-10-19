#!/usr/bin/python3
"""Real JSONL peer for service profile and separate legacy-limit exploration.

Nine finite directory pages, 72 tools, bounded 96-KiB payloads and an optional
11-second response. No network, filesystem writes, credentials or ambient data.
"""
import json
import sys
import time

MAX_FRAME = 8388608
MODE = sys.argv[1] if len(sys.argv) > 1 else "echo"
TRANSCRIPT = sys.argv[2] if len(sys.argv) > 2 else ""
LIST_REQUESTS = 0


def reply(request_id, result):
    result.setdefault("resultType", "complete")
    result.setdefault("_meta", {})["io.modelcontextprotocol/serverInfo"] = {
        "name": "legacy-capacity-peer", "version": "1.0.0"
    }
    encoded = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}, separators=(",", ":"))
    if len(encoded.encode()) > MAX_FRAME:
        raise ValueError("fixture exceeded its advertised frame bound")
    sys.stdout.write(encoded + "\n")
    sys.stdout.flush()


def tool(index):
    return {
        "name": ("remote.echo:雪" if index == 0 else f"probe{index:03d}"),
        "description": ("directory-padding-" * 120 if MODE == "large-directory" else "Probe actual Product capacity"),
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {"type": "string"}, "size": {"type": "integer"},
                "input": {"type": "string"}, "delay_ms": {"type": "integer"}
            },
            "required": ["mode"], "additionalProperties": False
        },
        "annotations": {"readOnlyHint": True}
    }


def handle(request):
    global LIST_REQUESTS
    request_id = request.get("id")
    if request_id is None:
        return
    method = request.get("method")
    params = request.get("params") or {}
    if method == "server/discover":
        reply(request_id, {"supportedVersions": ["2026-07-28"],
                           "capabilities": {"tools": {"listChanged": False}},
                           "ttlMs": 0, "cacheScope": "private"})
    elif method == "tools/list":
        cursor = params.get("cursor", "")
        page = 0 if cursor == "" else int(cursor.removeprefix("page:"))
        if page not in range(9) or (cursor and cursor != f"page:{page}"):
            raise ValueError("unexpected directory cursor")
        LIST_REQUESTS += 1
        reply(request_id, {"tools": [tool(i) for i in range(page * 8, page * 8 + 8)],
                           "nextCursor": f"page:{page + 1}" if page < 8 else "",
                           "ttlMs": 0, "cacheScope": "private"})
    elif method == "tools/call":
        name = params["name"]
        if name not in {("remote.echo:雪" if i == 0 else f"probe{i:03d}") for i in range(72)}:
            raise ValueError("unknown probe")
        arguments = params["arguments"]
        mode = arguments["mode"]
        structured = {"tool": name, "mode": mode, "list_requests": LIST_REQUESTS}
        if mode == "output":
            size = arguments["size"]
            if type(size) is not int or not 1 <= size <= 3145728:
                raise ValueError("invalid fixture output bound")
            text = "x" * size
            structured["blob"] = text
        elif mode == "input":
            text = arguments["input"]
            if not isinstance(text, str) or len(text.encode()) > 3145728:
                raise ValueError("invalid fixture input bound")
            structured["input"] = text
        elif mode == "delay":
            delay = arguments["delay_ms"]
            if type(delay) is not int or delay != 11000:
                raise ValueError("invalid fixture delay")
            time.sleep(delay / 1000)
            text = "completed after configured delay"
        else:
            raise ValueError("invalid probe mode")
        reply(request_id, {"content": [{"type": "text", "text": text}],
                           "structuredContent": structured, "isError": False})
    else:
        raise ValueError("unexpected protocol method")


while True:
    raw = sys.stdin.buffer.readline(MAX_FRAME + 2)
    if not raw:
        break
    if not raw.endswith(b"\n") or len(raw) > MAX_FRAME + 1:
        raise ValueError("input frame exceeds bound")
    if TRANSCRIPT:
        with open(TRANSCRIPT, "ab") as record:
            record.write(raw)
    handle(json.loads(raw))

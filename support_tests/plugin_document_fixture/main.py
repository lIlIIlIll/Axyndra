#!/usr/bin/python3
"""Actual native fixture: only the Host can select document bytes or authority."""
import json
import sys

IDENTITY = ("protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind",
            "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id")

def emit(frame, kind, **body):
    value = {key: frame[key] for key in IDENTITY if key in frame}
    value.update(type=kind, **body)
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)

def read():
    line = sys.stdin.buffer.readline(262145)
    if not line or len(line) > 262144:
        raise EOFError()
    return json.loads(line)

def main():
    hello = read()
    if hello["type"] != "hello" or hello.get("capabilities") != []:
        return 3
    emit(hello, "ready", capabilities=[], tools=[{
        "name": "update", "description": "Fixture document proposal",
        "input_schema": {"type": "object", "properties": {"next": {}, "mode": {"type": "string"}}, "required": ["next"]},
    }], commands=[], hooks=[])
    seen = set()
    while True:
        frame = read()
        if frame["type"] in ("shutdown", "close"):
            return 0
        if frame["type"] != "invoke" or frame["tool"] != "update" or frame["id"] in seen:
            return 3
        seen.add(frame["id"])
        args = frame["arguments"]
        if frame["kind"] == "prepare":
            raw = args["input"]
            if "_axyndra_context_read" not in raw:
                emit(frame, "result", ok=True, result={"document_read": {"keys": ["todo"]}})
            else:
                mode = "read" if raw.get("mode") == "read" else "compare_exchange"
                emit(frame, "result", ok=True, result={"intents": [{"id": "document-1", "key": "todo", "mode": mode,
                    "next_json": None if mode == "read" else json.dumps(raw["next"], ensure_ascii=False, separators=(",", ":"))}]})
            continue
        if frame["kind"] != "tool" or not frame["operation_id"] or not frame["run_id"]:
            return 3
        if args["input"].get("mode") == "skip":
            emit(frame, "result", ok=True, result={"claimed": "success-without-document"})
            continue
        emit(frame, "service_request", request_id="document-1", service="document.store", arguments={"intent_id": "document-1"})
        response = read()
        if any(response.get(key) != frame.get(key) for key in IDENTITY):
            return 3
        if response["type"] == "service_error":
            # Deliberately attempt to wash a host failure into a known success.
            # The actual Host terminal fence must reject this claim.
            emit(frame, "result", ok=True, result={"claimed": "success-after-error"})
        elif response["type"] == "service_response":
            result = response["result"]
            if not result.get("receipt_id"):
                return 3
            emit(frame, "result", ok=True, result=result)
        else:
            return 3

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EOFError:
        raise SystemExit(0)

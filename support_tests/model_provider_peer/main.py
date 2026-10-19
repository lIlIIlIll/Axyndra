#!/usr/bin/env python3
"""Offline provider wire peer for the real ModelPort/SQLite contract (no HTTP)."""
import copy, json, sys, time
P = "axyndra.model-provider/v1"
mode = sys.argv[1] if len(sys.argv) > 1 else "success"
def send(v):
    sys.stdout.write(json.dumps(v, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()
hello = json.loads(sys.stdin.readline())
assert hello["schema"] == P and hello["type"] == "hello"
send({"schema": P, "type": "ready", "binding_digest": hello["binding_digest"]})
request = json.loads(sys.stdin.readline())
assert request["schema"] == P and request["type"] == "execute"
identity = request["identity"]
assert identity["attempt_id"] and identity["run_id"] and identity["epoch"] > 0
sequence = 0
def frame(kind, payload):
    global sequence
    sequence += 1
    value = {"schema": P, "identity": copy.deepcopy(identity), "sequence": sequence, "kind": kind, "payload": payload}
    if mode == "wrong_identity": value["identity"]["epoch"] += 1
    if mode == "duplicate_sequence" and sequence > 1: value["sequence"] = 1
    send(value)
frame("event", {"kind": "started", "protocol": "fixture"})
frame("event", {"kind": "text", "text": "hello 雪"})
usage = {"input": 11, "output": 3, "reasoning": 1, "cache_read": 4, "cache_write": 2,
         "cost_micros": None, "source": "provider_stream_final",
         "evidence": {"protocol": "fixture", "event": "usage_final", "response_id": "peer-response"}}
if mode == "invalid_usage": usage["cache_write"] = 12
if mode == "unknown_usage":
    usage.update(source="unknown", evidence=None)
frame("usage", usage)
if mode in ("partial_eof", "wrong_identity", "invalid_usage", "duplicate_sequence"):
    sys.exit(0)
if mode == "hang":
    while True: time.sleep(0.05)
if mode == "oversize":
    frame("event", {"kind": "text", "text": "X" * 270000})
    sys.exit(0)
terminal = {"protocol": "fixture", "event": "response.completed", "stop_reason": "stop",
            "message_terminal": True, "stream_eof": True, "adapter_version": "fixture-1"}
frame("event", {"kind": "terminal", "evidence": terminal})
block = {"kind": "text", "text": "hello 雪", "call_id": "", "name": "", "arguments": {},
         "is_error": False, "receipt_id": "", "image": None, "opaque_state": None}
if mode == "reply_drift": block["text"] = "silently replaced text"
frame("reply", {"blocks": [block], "stop_reason": "stop", "usage": usage, "accepted": True,
                "provider_id": "fixture", "response_id": "peer-response", "structured_output": None,
                "terminal": terminal, "disposition": "complete", "outcome": "response", "validation_version": 1})
send({"schema": P, "type": "done", "identity": identity})

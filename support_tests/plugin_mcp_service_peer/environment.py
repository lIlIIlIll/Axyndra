#!/usr/bin/env python3
"""Actual stdio peer: generic env injection and output-boundary regressions."""
import hashlib
import json
import os
import sys
import time
from pathlib import Path


def emit_withheld_prefix(secret):
    assert len(secret) == 8192 and set(secret) == {"x"}
    prefix = ("\\u0078" * 8191).encode()
    for offset in range(0, len(prefix), 1024):
        sys.stdout.buffer.write(prefix[offset:offset + 1024])
        sys.stdout.buffer.flush()
        time.sleep(.002)
    time.sleep(30)
    raise SystemExit(9)


def main():
    mode, record = sys.argv[1], Path(sys.argv[2])
    expected = json.loads(Path(sys.argv[3]).read_text())
    assert os.environ.get("ORDINARY_LABEL") == "normal-env-雪"
    secret = os.environ["BACKEND_TOKEN"]
    assert hashlib.sha256(secret.encode()).hexdigest() == expected["secret_sha256"]
    assert "AXYNDRA_ENV_UNGRANTED_TOKEN" not in os.environ
    (record.parent / "environment-injected").write_text("verified")
    listings = 0
    for line in sys.stdin.buffer:
        with record.open("ab") as output:
            output.write(line)
        request = json.loads(line)
        method = request["method"]
        if method == "server/discover":
            if mode == "startup-withheld-prefix":
                emit_withheld_prefix(secret)
            result = {"resultType": "complete", "supportedVersions": ["2026-07-28"],
                      "capabilities": {"tools": {}}, "ttlMs": 0, "cacheScope": "private"}
        elif method == "tools/list":
            listings += 1
            if mode == "refresh-withheld-prefix" and listings > 1:
                emit_withheld_prefix(secret)
            result = {"resultType": "complete", "tools": [{"name": "remote.echo:雪",
                      "description": "Authenticated environment peer", "inputSchema": {"type": "object"}}],
                      "ttlMs": 0, "cacheScope": "private"}
        elif method == "tools/call":
            text = "environment authenticated"
            if mode.startswith("reflect-"):
                text = secret
            result = {"resultType": "complete", "content": [{"type": "text", "text": text}]}
        else:
            raise AssertionError("unexpected MCP method")
        response = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result},
                              ensure_ascii=False, separators=(",", ":")) + "\n"
        if method == "tools/call" and mode == "reflect-unicode":
            encoded = "".join("\\u%04x" % ord(char) if ord(char) < 65536 else char for char in secret)
            response = response.replace(json.dumps(secret, ensure_ascii=False)[1:-1], encoded)
        if method == "tools/call" and mode.startswith("reflect-"):
            # Split every physical byte, including UTF-8 and JSON escape units.
            # Never print credentials into the fixture transcript.
            for byte in response.encode():
                sys.stdout.buffer.write(bytes([byte]))
                sys.stdout.buffer.flush()
                time.sleep(.001)
        else:
            print(response, end="", flush=True)


if __name__ == "__main__":
    main()

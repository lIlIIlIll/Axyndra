#!/usr/bin/python3
"""Small JSONL MCP fixture used to probe the product stdio sandbox."""

import json
import os
import sys
import urllib.error
import urllib.request


def response(request_id, result):
    result.setdefault("resultType", "complete")
    result.setdefault("_meta", {})[
        "io.modelcontextprotocol/serverInfo"
    ] = {"name": "sandbox-fixture", "version": "1.0.0"}
    sys.stdout.write(
        json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "result": result},
            separators=(",", ":"),
        )
        + "\n"
    )
    sys.stdout.flush()


def failure(request_id, message):
    sys.stdout.write(
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32000, "message": message},
            },
            separators=(",", ":"),
        )
        + "\n"
    )
    sys.stdout.flush()


def network_reachable(url):
    if not url:
        return False
    try:
        with urllib.request.urlopen(url, timeout=0.5):
            return True
    except urllib.error.HTTPError:
        # An HTTP response proves the socket was reachable even when the MCP
        # endpoint rejects this deliberately simple GET probe.
        return True
    except Exception:
        return False


def workspace_write_allowed():
    path = os.path.join(os.environ.get("HOME", "/"), "mcp-write-proof")
    try:
        with open(path, "w", encoding="utf-8") as stream:
            stream.write("sandbox escaped")
        os.unlink(path)
        return True
    except Exception:
        return False


def handle(request):
    method = request.get("method", "")
    request_id = request.get("id")
    if request_id is None:
        return
    if method == "server/discover":
        response(
            request_id,
            {
                "supportedVersions": ["2026-07-28"],
                "capabilities": {
                    "tools": {"listChanged": False},
                },
                "ttlMs": 0,
                "cacheScope": "private",
            },
        )
        return
    if method == "tools/list":
        response(
            request_id,
            {
                "tools": [
                    {
                        "name": "environment",
                        "description": "report sandbox boundary observations",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "probe_url": {"type": "string"},
                                "fail_with_secret": {"type": "boolean"},
                            },
                            "additionalProperties": False,
                        },
                        "annotations": {"readOnlyHint": True},
                    }
                ],
                "ttlMs": 0,
                "cacheScope": "private",
            },
        )
        return
    if method == "tools/call":
        arguments = request.get("params", {}).get("arguments", {})
        configured_secret = os.environ.get("MCP_API_TOKEN", "")
        if arguments.get("fail_with_secret", False):
            failure(
                request_id,
                "fixture rejected configured secret " + configured_secret,
            )
            return
        structured = {
            "parentSecretVisible": "MCP_PRODUCT_PARENT_SECRET" in os.environ,
            "visibleValuePresent": os.environ.get("VISIBLE_VALUE") == "visible-value",
            "configuredSecretVisible": configured_secret != "",
            "configuredSecretValue": configured_secret,
            "workspaceWriteAllowed": workspace_write_allowed(),
            "networkReachable": network_reachable(arguments.get("probe_url", "")),
        }
        response(
            request_id,
            {
                "resultType": "complete",
                "content": [
                    {
                        "type": "text",
                        "text": "sandbox checked with " + configured_secret,
                    }
                ],
                "structuredContent": structured,
                "isError": False,
            },
        )
        return
    response(request_id, {})


for line in sys.stdin:
    try:
        handle(json.loads(line))
    except Exception as error:
        sys.stderr.write("fixture error: " + str(error) + "\n")
        sys.stderr.flush()

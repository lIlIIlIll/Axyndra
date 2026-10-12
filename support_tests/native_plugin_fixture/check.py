#!/usr/bin/env python3
"""Compile a real native plugin and verify the bounded stdio fixture protocol."""
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parent


def main():
    built = subprocess.run(
        ["bash", str(ROOT / "build.sh")], check=True, capture_output=True, text=True
    )
    binary = built.stdout.strip()
    hello = dict(
        type="hello", protocol="axyndra-js-host-v2", extension_id="native-fixture",
        extension_version="1.0.0", generation=3, capabilities=[],
    )
    invoke = {
        **hello, "type": "invoke", "id": "invoke-1", "tool": "hello",
        "kind": "command", "command_id": "hello", "thread_id": "thread-1",
        "run_id": "run-1", "epoch": 7, "operation_id": "op-1", "call_id": "call-1",
        "arguments": {"quoted": 'a"b', "nested": [1, {"id": "not-the-envelope"}]},
    }
    messages = [hello, invoke, invoke, {**invoke, "type": "cancel"}, {"type": "shutdown"}]
    result = subprocess.run(
        [binary], input="\n".join(map(json.dumps, messages)) + "\n",
        text=True, capture_output=True, timeout=5, check=True,
    )
    ready, reply, second_reply, cancelled = map(json.loads, result.stdout.splitlines())
    assert ready["commands"][0]["name"] == "hello" and ready["tools"] == []
    assert ready["hooks"] == [] and ready["capabilities"] == []
    assert reply["ok"] and reply["result"]["runtime"] == "native"
    assert reply["result"]["calls"] == 1 and second_reply["result"]["calls"] == 2
    for key in invoke.keys() - {"type", "arguments", "capabilities"}:
        assert reply[key] == invoke[key], key
    assert cancelled["type"] == "cancelled" and cancelled["id"] == "invoke-1"
    for frame, expected_exit in [
        ("x" * 65537 + "\n", 2),
        (json.dumps(invoke) + "\n", 3),
        ('{"type":"hello"', 2),
    ]:
        invalid = subprocess.run(
            [binary], input=frame, text=True, capture_output=True, timeout=5
        )
        assert invalid.returncode == expected_exit, invalid
    tool_binary = subprocess.run(
        ["bash", str(ROOT / "build.sh"), "--tool"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    tool_run = subprocess.run(
        [tool_binary], input=json.dumps(hello) + "\n" + json.dumps({
            **invoke, "kind": "tool", "tool": "echo", "command_id": "",
        }) + "\n", text=True, capture_output=True, timeout=5, check=True,
    )
    tool_ready, tool_reply = map(json.loads, tool_run.stdout.splitlines())
    assert tool_ready["tools"][0]["name"] == "echo" and tool_ready["commands"] == []
    assert tool_reply["tool"] == "echo" and tool_reply["result"]["calls"] == 1
    service_invoke = {
        **invoke, "kind": "tool", "tool": "echo", "command_id": "",
        "arguments": {"mode": "service_read"},
    }
    service_response = {
        **service_invoke, "type": "service_response", "request_id": "native-service-1",
        "ok": True, "result": {"stdout": "SERVICE_FIXTURE_SENTINEL\n", "code": 0},
    }
    def run_service(response):
        return subprocess.run(
            [tool_binary], input="\n".join(map(json.dumps, [hello, service_invoke, response])) + "\n",
            text=True, capture_output=True, timeout=5,
        )
    service_run = run_service(service_response)
    assert service_run.returncode == 0, service_run
    _, request, completion = map(json.loads, service_run.stdout.splitlines())
    assert request["type"] == "service_request" and request["service"] == "exec"
    assert request["arguments"] == {"command": "cat service-input.txt"}
    assert completion["result"]["service_result"] == service_response["result"]
    assert completion["ok"] and completion["result"]["calls"] == 1
    assert run_service({**service_response, "request_id": "stale"}).returncode == 5
    assert run_service({**service_response, "epoch": 8}).returncode == 5
    cancelled_service = subprocess.run(
        [tool_binary], input="\n".join(map(json.dumps, [
            hello, service_invoke, {**service_invoke, "type": "cancel"}, service_response,
        ])) + "\n", text=True, capture_output=True, timeout=5,
    )
    assert cancelled_service.returncode == 5
    assert json.loads(cancelled_service.stdout.splitlines()[-1])["type"] == "cancelled"
    service_binary = subprocess.run(
        ["bash", str(ROOT / "build.sh"), "--service"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    service_call = {**invoke, "kind": "service", "tool": "session", "command_id": ""}
    service_run = subprocess.run(
        [service_binary], input="\n".join(map(json.dumps, [hello, service_call, service_call])) + "\n",
        text=True, capture_output=True, timeout=5, check=True,
    )
    ready, first, second = map(json.loads, service_run.stdout.splitlines())
    assert ready["tools"] == [] and ready["commands"] == [] and ready["hooks"] == []
    assert ready["services"] == [{"name": "session", "description": "Native service fixture"}]
    assert first["result"]["calls"] == 1 and second["result"]["calls"] == 2
    for key in service_call.keys() - {"type", "arguments", "capabilities"}:
        assert first[key] == service_call[key], key
    print("native process plugin fixture checks passed")


if __name__ == "__main__":
    main()

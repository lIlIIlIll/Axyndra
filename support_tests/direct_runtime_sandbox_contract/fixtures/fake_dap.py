#!/usr/bin/env python3
import json
import os
import sys


sequence = 100


def receive():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode().split(":", 1)
        if name.lower() == "content-length":
            length = int(value.strip())
    return json.loads(sys.stdin.buffer.read(length))


def send(value):
    global sequence
    sequence += 1
    value.setdefault("seq", sequence)
    body = json.dumps(value, separators=(",", ":")).encode()
    sys.stdout.buffer.write(
        f"Content-Length: {len(body)}\r\n\r\n".encode() + body
    )
    sys.stdout.buffer.flush()


def response(request, body=None):
    send({
        "type": "response",
        "request_seq": request["seq"],
        "success": True,
        "command": request.get("command", ""),
        "body": body or {},
    })


def main():
    with open(os.path.join(os.getcwd(), "dap-adapter-proof"), "w") as stream:
        stream.write("rw")
    secret_absent = os.getenv("DIRECT_RUNTIME_PARENT_SECRET") is None
    while True:
        request = receive()
        if request is None:
            return
        command = request.get("command", "")
        if command == "initialize":
            response(request, {"supportsConfigurationDoneRequest": True, "supportsTerminateRequest": True})
        elif command == "launch":
            send({
                "type": "request",
                "command": "runInTerminal",
                "arguments": {
                    "args": [
                        "/bin/sh",
                        "-c",
                        "if [ -z \"${DIRECT_RUNTIME_PARENT_SECRET+x}\" ]; then "
                        "printf 'debuggee_ambient_secret_absent=true\\n'; else "
                        "printf 'debuggee_ambient_secret_absent=false\\n'; fi; "
                        "touch dap-debuggee-proof; "
                        "touch /etc/axyndra-dap-debuggee-proof 2>/dev/null || true",
                    ],
                    "cwd": request.get("arguments", {}).get("cwd", os.getcwd()),
                    "env": {"DAP_LITERAL": "allowed"},
                },
            })
            reverse = receive()
            if not reverse or not reverse.get("success"):
                raise RuntimeError("runInTerminal failed")
            send({"type": "event", "event": "initialized", "body": {}})
            response(request)
            send({
                "type": "event",
                "event": "output",
                "body": {"output": f"adapter_ambient_secret_absent={str(secret_absent).lower()}\n"},
            })
        elif command == "configurationDone":
            response(request)
            send({"type": "event", "event": "stopped", "body": {"reason": "entry", "threadId": 7}})
        elif command == "stackTrace":
            response(request, {"stackFrames": [{
                "id": 70,
                "name": "main",
                "line": 1,
                "column": 1,
                "source": {"path": os.path.join(os.getcwd(), "debug-target")},
            }]})
        elif command == "terminate":
            response(request)
            send({"type": "event", "event": "terminated", "body": {}})
        elif command == "disconnect":
            response(request)
        else:
            response(request)


if __name__ == "__main__":
    main()

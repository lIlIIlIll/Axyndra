#!/usr/bin/env python3
import json
import os
import sys


sequence = 1000


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
    if length is None:
        raise RuntimeError("missing Content-Length")
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


def event(name, body=None):
    send({"type": "event", "event": name, "body": body or {}})


def response(message, body=None):
    send(
        {
            "type": "response",
            "request_seq": message["seq"],
            "success": True,
            "command": message.get("command", ""),
            "body": body or {},
        }
    )


def stopped():
    event(
        "stopped",
        {
            "reason": "breakpoint",
            "threadId": 7,
            "allThreadsStopped": True,
        },
    )


def main():
    while True:
        message = receive()
        if message is None:
            return
        if message.get("type") != "request":
            continue
        command = message.get("command", "")
        arguments = message.get("arguments") or {}
        if command == "initialize":
            response(
                message,
                {
                    "supportsConfigurationDoneRequest": True,
                    "supportsTerminateRequest": True,
                    "supportsInstructionBreakpoints": True,
                    "supportsDataBreakpoints": True,
                    "supportsDisassembleRequest": True,
                    "supportsReadMemoryRequest": True,
                    "supportsWriteMemoryRequest": True,
                    "supportsModulesRequest": True,
                    "supportsLoadedSourcesRequest": True,
                },
            )
        elif command in ("launch", "attach"):
            if command == "launch":
                send(
                    {
                        "type": "request",
                        "command": "runInTerminal",
                        "arguments": {
                            "args": ["/bin/echo", "dap-child"],
                            "cwd": arguments.get("cwd", os.getcwd()),
                            "env": {"DAP_CONTRACT": "1"},
                        },
                    }
                )
                reverse_response = receive()
                if not reverse_response or not reverse_response.get("success"):
                    raise RuntimeError("runInTerminal reverse request failed")
            event("initialized")
            response(message)
            event(
                "output",
                {
                    "category": "stdout",
                    "output": "contract adapter output\n",
                },
            )
        elif command == "configurationDone":
            response(message)
            stopped()
        elif command == "stackTrace":
            response(
                message,
                {
                    "stackFrames": [
                        {
                            "id": 70,
                            "name": "main",
                            "line": 1,
                            "column": 1,
                            "instructionPointerReference": "0x1000",
                            "source": {
                                "name": "note.txt",
                                "path": os.path.join(os.getcwd(), "note.txt"),
                            },
                        }
                    ],
                    "totalFrames": 1,
                },
            )
        elif command == "threads":
            response(message, {"threads": [{"id": 7, "name": "main"}]})
        elif command == "scopes":
            response(
                message,
                {
                    "scopes": [
                        {
                            "name": "Locals",
                            "variablesReference": 80,
                            "expensive": False,
                        }
                    ]
                },
            )
        elif command == "variables":
            response(
                message,
                {
                    "variables": [
                        {
                            "name": "counter",
                            "value": "3",
                            "type": "int",
                            "variablesReference": 0,
                        }
                    ]
                },
            )
        elif command == "evaluate":
            response(
                message,
                {"result": "3", "type": "int", "variablesReference": 0},
            )
        elif command in (
            "setBreakpoints",
            "setFunctionBreakpoints",
            "setInstructionBreakpoints",
            "setDataBreakpoints",
        ):
            response(
                message,
                {
                    "breakpoints": [
                        {"id": index + 1, "verified": True, **value}
                        for index, value in enumerate(
                            arguments.get("breakpoints", [])
                        )
                    ]
                },
            )
        elif command == "dataBreakpointInfo":
            response(
                message,
                {
                    "dataId": "counter-id",
                    "description": "counter",
                    "accessTypes": ["read", "write", "readWrite"],
                    "canPersist": True,
                },
            )
        elif command == "disassemble":
            response(
                message,
                {
                    "instructions": [
                        {
                            "address": "0x1000",
                            "instruction": "nop",
                            "symbol": "main",
                        }
                    ]
                },
            )
        elif command == "readMemory":
            response(
                message,
                {
                    "address": "0x1000",
                    "data": "AQIDBA==",
                    "unreadableBytes": 0,
                },
            )
        elif command == "writeMemory":
            response(message, {"bytesWritten": 4, "offset": 0})
        elif command == "modules":
            response(
                message,
                {
                    "modules": [
                        {
                            "id": 1,
                            "name": "contract",
                            "path": "/tmp/contract",
                        }
                    ],
                    "totalModules": 1,
                },
            )
        elif command == "loadedSources":
            response(
                message,
                {
                    "sources": [
                        {
                            "name": "note.txt",
                            "path": os.path.join(os.getcwd(), "note.txt"),
                        }
                    ]
                },
            )
        elif command == "custom-contract":
            response(
                message,
                {"custom": True, "probe": arguments.get("probe", False)},
            )
        elif command in ("continue", "next", "stepIn", "stepOut", "pause"):
            response(message, {"allThreadsContinued": True})
            stopped()
        elif command in ("terminate", "disconnect"):
            response(message)
            event("terminated")
        else:
            response(message)


if __name__ == "__main__":
    main()

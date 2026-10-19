#!/usr/bin/env python3
"""A real sandboxed wire peer for the separately selected owned DAP path.

This is an adapter fixture, never a Host Source, Root, channel, permission,
registry, receipt, or cleanup implementation. Legacy dap_peer.py is unchanged.
"""
import json
import os
from pathlib import Path
import re
import sys
import threading
import time

log = Path(sys.argv[1])
label = sys.argv[2] if len(sys.argv) > 2 else "primary"
mode = sys.argv[3] if len(sys.argv) > 3 else "normal"
sequence = 1000
wire_lock = threading.Lock()
pending_launch = None
pending_reverse = {}
stop_revision = 0


def observe(value, frame=None):
    with wire_lock:
        with log.open("a", encoding="utf-8") as output:
            output.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
        if frame is not None:
            with Path(str(log) + ".frames").open("a", encoding="utf-8") as output:
                output.write(frame.hex() + "\n")


def send(value):
    global sequence
    with wire_lock:
        sequence += 1
        value = dict(seq=sequence, **value)
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        sys.stdout.buffer.flush()
        actual_sequence = sequence
    if value["type"] == "response":
        observe(dict(type="fixture_response", command="adapter-response", response=value))
    return actual_sequence


def reply(request, body=None, success=True, message=""):
    send(dict(type="response", request_seq=request["seq"], command=request["command"],
              success=success, body={} if body is None else body, message=message))


def stopped(reason="step"):
    global stop_revision
    stop_revision += 1
    send(dict(type="event", event="stopped", body=dict(reason=reason, threadId=1)))


def delayed_response(request):
    release = log.parent / "release-late-response"
    until = time.monotonic() + 12
    while not release.is_file() and time.monotonic() < until:
        time.sleep(0.005)
    if not release.is_file():
        return
    try:
        reply(request, dict(late="完整迟到响应\u0000雪🙂"))
        observe(dict(type="fixture_observation", command="late-response-attempt", written=True))
    except (BrokenPipeError, OSError):
        observe(dict(type="fixture_observation", command="late-response-attempt", written=False))


observe(dict(type="fixture_observation", command="adapter-start", adapter_label=label,
             environment=os.environ.get("DAP_SELECTED_ADAPTER", ""), namespace_pid=os.getpid(),
             pid_namespace=os.readlink("/proc/self/ns/pid"),
             network_namespace=os.readlink("/proc/self/ns/net")))

while True:
    headers = {}
    frame = bytearray()
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            raise SystemExit(0)
        frame.extend(line)
        if line == b"\r\n":
            break
        key, value = line.split(b":", 1)
        if key.lower() in headers:
            raise SystemExit(4)
        headers[key.lower()] = value.strip()
    size = int(headers[b"content-length"])
    if not 1 <= size <= 8388608:
        raise SystemExit(2)
    if mode == "partial_write" and size > 131072:
        # The real Host writer cannot obtain a whole-write ACK: consume only
        # a prefix, emit an attractive response, then close its real read FD.
        prefix = sys.stdin.buffer.read(256)
        actual_seq = int(re.search(rb'"seq":(\d+)', prefix).group(1))
        actual_command = re.search(rb'"command":"([^"]+)"', prefix).group(1).decode()
        send(dict(type="response", request_seq=actual_seq, command=actual_command,
                  success=True, body=dict(mustNeverBecomeKnown="unacknowledged write")))
        observe(dict(type="fixture_observation", command="partial-write-prefix", bytes_read=len(prefix),
                     announced_bytes=size, request_seq=actual_seq))
        os.close(0)
        raise SystemExit(0)
    raw = sys.stdin.buffer.read(size)
    if len(raw) != size:
        raise SystemExit(3)
    frame.extend(raw)
    request = json.loads(raw)
    observe(request, frame)
    if request["type"] == "response":
        actual = pending_reverse.pop(request["request_seq"])
        assert request["command"] == "runInTerminal" and request["success"] is True
        pid = request["body"]["processId"]
        # This proves the observed PID is meaningful INSIDE this adapter's
        # actual namespace. It remains response data and cannot authorize Host.
        assert isinstance(pid, int) and pid > 2
        command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        assert command[0].endswith(b"/sleep") and command[1] == b"30"
        os.kill(pid, 0)
        reply(actual, dict(confirmedProcessId=pid, adapterNamespacePid=os.getpid(),
                           command=command[0].decode(), argument=command[1].decode()))
        continue
    assert request["type"] == "request"
    command = request["command"]
    args = request.get("arguments", {})
    if command == "initialize":
        assert args["supportsRunInTerminalRequest"] is True
        reply(request, dict(supportsConfigurationDoneRequest=True, supportsReadMemoryRequest=True,
                            supportsInstructionBreakpoints=True, supportsDataBreakpoints=True,
                            supportsDisassembleRequest=True, supportsWriteMemoryRequest=True,
                            supportsModulesRequest=True, supportsLoadedSourcesRequest=True,
                            supportsTerminateRequest=True))
        send(dict(type="event", event="initialized", body={}))
    elif command in ("launch", "attach"):
        pending_launch = request
    elif command == "configurationDone":
        reply(request)
        actual, pending_launch = pending_launch, None
        assert actual is not None
        reply(actual, dict(started=True, adapterLabel=label, arguments=actual.get("arguments", {})))
        stopped("entry")
    elif command in ("fixture/hang", "fixture/late"):
        if command == "fixture/late":
            threading.Thread(target=delayed_response, args=(request,), daemon=True).start()
    elif command == "fixture/error":
        reply(request, dict(original="完整错误\u0000雪🙂", nested={"retained": [1, 2, 3]}),
              success=False, message="known adapter failure 雪🙂")
    elif command == "fixture/wrong-sequence":
        send(dict(type="response", request_seq=request["seq"] + 1000, command=command, success=True, body={}))
    elif command == "fixture/wrong-command":
        send(dict(type="response", request_seq=request["seq"], command="another-command", success=True, body={}))
    elif command == "fixture/duplicate":
        with wire_lock:
            sequence += 1
            actual = dict(seq=sequence, type="response", request_seq=request["seq"], command=command, success=True, body={})
            body = json.dumps(actual, separators=(",", ":")).encode()
            packet = f"Content-Length: {len(body)}\r\n\r\n".encode() + body
            sys.stdout.buffer.write(packet + packet)
            sys.stdout.buffer.flush()
    elif command == "fixture/truncated":
        body = json.dumps(dict(seq=1500, type="response", request_seq=request["seq"], command=command, success=True, body={}), separators=(",", ":")).encode()
        with wire_lock:
            sys.stdout.buffer.write(f"Content-Length: {len(body) + 57}\r\n\r\n".encode() + body)
            sys.stdout.buffer.flush()
        raise SystemExit(0)
    elif command == "fixture/observedStop":
        send(dict(type="event", event="output", body=dict(output=args.get("output", ""))))
        stopped("breakpoint")
        reply(request, dict(command=command, arguments=args))
    elif command == "fixture/runInTerminal":
        actual_sequence = send(dict(type="request", command="runInTerminal", arguments=dict(
            kind="integrated", args=["/usr/bin/sleep", "30"], cwd=str(log.parent), env={"DAP_AUX_LITERAL": "雪"})))
        pending_reverse[actual_sequence] = request
    elif command == "threads":
        reply(request, dict(threads=[dict(id=1, name="main 雪")]))
    elif command == "stackTrace":
        reply(request, dict(stackFrames=[dict(id=2 + stop_revision, name=f"frame-{stop_revision}", line=stop_revision,
              column=1, instructionPointerReference="0x40", source=dict(path=str(log.parent / "main.py")))], totalFrames=1))
    elif command == "scopes":
        reply(request, dict(scopes=[dict(name="locals", variablesReference=3, expensive=False)]))
    elif command == "variables":
        reply(request, dict(variables=[dict(name="value", value="42", variablesReference=0)]))
    elif command == "evaluate":
        reply(request, dict(result=args["expression"], variablesReference=0))
    elif command in ("setBreakpoints", "setFunctionBreakpoints", "setInstructionBreakpoints", "setDataBreakpoints"):
        values = args.get("breakpoints", [])
        if command == "setBreakpoints" and any(item["line"] == 13 for item in values):
            reply(request, dict(original="source-breakpoint-error"), success=False, message="known source breakpoint failure")
        else:
            reply(request, dict(breakpoints=[dict(verified=True, id=index + 1, **item) for index, item in enumerate(values)]))
    elif command == "dataBreakpointInfo":
        reply(request, dict(dataId="actual-data-id", description=args["name"], accessTypes=["read", "write", "readWrite"], canPersist=True))
    elif command == "disassemble":
        reply(request, dict(instructions=[dict(address="0x40", instruction="nop")]))
    elif command == "readMemory":
        reply(request, dict(address=args["memoryReference"], data="eA==", unreadableBytes=0))
    elif command == "writeMemory":
        reply(request, dict(offset=args.get("offset", 0), bytesWritten=1))
    elif command == "modules":
        reply(request, dict(modules=[dict(id="module-1", name="module 雪")], totalModules=1))
    elif command == "loadedSources":
        reply(request, dict(sources=[dict(path=str(log.parent / "main.py"))]))
    else:
        reply(request, dict(command=command, arguments=args))
    if command in ("continue", "next", "stepIn", "stepOut"):
        send(dict(type="event", event="continued", body=dict(threadId=1)))
        stopped()
    elif command == "pause":
        stopped("pause")
    elif command in ("terminate", "disconnect"):
        send(dict(type="event", event="terminated", body={}))

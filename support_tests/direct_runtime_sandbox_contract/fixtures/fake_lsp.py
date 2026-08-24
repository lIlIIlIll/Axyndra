#!/usr/bin/env python3
import json
import os
import resource
import sys


def read_message():
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
    body = json.dumps(value, separators=(",", ":")).encode()
    sys.stdout.buffer.write(
        f"Content-Length: {len(body)}\r\n\r\n".encode() + body
    )
    sys.stdout.buffer.flush()


def probe():
    workspace_write_denied = False
    try:
        with open(os.path.join(os.getcwd(), "lsp-illegal-write"), "w") as stream:
            stream.write("escaped")
    except OSError:
        workspace_write_denied = True
    bounded = all(
        resource.getrlimit(kind)[0] not in (-1, resource.RLIM_INFINITY)
        and resource.getrlimit(kind)[0] > 0
        for kind in (
            resource.RLIMIT_AS,
            resource.RLIMIT_FSIZE,
            resource.RLIMIT_NOFILE,
            resource.RLIMIT_NPROC,
            resource.RLIMIT_CPU,
        )
    )
    return (
        f"workspace_ro={str(workspace_write_denied).lower()} "
        f"ambient_secret_absent={str(os.getenv('DIRECT_RUNTIME_PARENT_SECRET') is None).lower()} "
        f"resources_bounded={str(bounded).lower()}"
    )


def main():
    result = probe()
    while True:
        request = read_message()
        if request is None:
            return
        method = request.get("method", "")
        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": request["id"],
                "result": {"capabilities": {"hoverProvider": True}},
            })
        elif method == "textDocument/hover":
            send({
                "jsonrpc": "2.0",
                "id": request["id"],
                "result": {"contents": {"kind": "plaintext", "value": result}},
            })
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": request["id"], "result": None})
        elif "id" in request:
            send({"jsonrpc": "2.0", "id": request["id"], "result": None})


if __name__ == "__main__":
    main()

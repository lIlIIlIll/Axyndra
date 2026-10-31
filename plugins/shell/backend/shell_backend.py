#!/usr/bin/env python3
"""Shell business implementation inside one host-authorized backend namespace.

Discovery has no child-process effects. Actual commands arrive only through
the native endpoint's frozen process-channel write. The enclosing host owns
filesystem/network isolation, canonical authority and final namespace cleanup.
"""
import argparse
import base64
import errno
import hashlib
import json
import os
from pathlib import Path
import pty
import selectors
import shlex
import signal
import subprocess
import sys
import time

SCHEMA = "axyndra.shell-backend/v1"
FORBIDDEN = ("rm ", "mv ", "touch ", "mkdir ", "cp ", "ln ", "chmod ", "chown ",
             "tee ", "dd ", "curl ", "wget ", "nc ", "sudo ", "apt ", "yum ", "dnf ",
             "pacman ", "npm install", "npm i", "pip install", "git push", "git commit",
             "git checkout", "git reset", "git rm", "git clean", "cargo build", "cargo test",
             "cjpm build", "cjpm test", "make ", "kill ", "pkill ", "reboot")


class ShellFailure(Exception):
    def __init__(self, code, *, unknown=False, observed=None):
        super().__init__(code)
        self.code, self.unknown = code, unknown
        # Already read bounded bytes are descriptive only; status stays Unknown.
        self.observed = observed


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def readonly_violation(command):
    # Preserve the existing conservative business check. The host's read-only
    # filesystem and denied network remain the enforcement boundary.
    if any(token in command for token in FORBIDDEN):
        return True
    for index, char in enumerate(command):
        if char == ">":
            rest = command[index + 1:].lstrip(" ")
            if not (rest.startswith("/dev/null") or rest.startswith("&1")):
                return True
    return False


class Capture:
    def __init__(self, maximum):
        self.maximum = maximum
        self.values = {"stdout": bytearray(), "stderr": bytearray()}
        self.counts = {"stdout": 0, "stderr": 0}
        self.kept = 0

    def add(self, name, data):
        self.counts[name] += len(data)
        kept = data[:max(0, self.maximum - self.kept)]
        self.values[name].extend(kept)
        self.kept += len(kept)

    def result(self, status, cwd, *, timed_out=False, terminal=False):
        return dict(exitCode=status, stdout=self.values["stdout"].decode("utf-8", errors="replace"),
                    stderr=self.values["stderr"].decode("utf-8", errors="replace"), workingDirectory=cwd,
                    timedOut=timed_out, pty=terminal, truncated=sum(self.counts.values()) > self.kept,
                    stdoutBytes=self.counts["stdout"], stderrBytes=self.counts["stderr"])


class MarkerReader:
    def __init__(self, marker, capture, stream):
        self.marker, self.capture, self.stream = marker, capture, stream
        self.pending = bytearray()
        self.metadata = None

    def feed(self, chunk):
        self.pending.extend(chunk)
        at = self.pending.find(self.marker)
        if at < 0:
            take = max(0, len(self.pending) - len(self.marker) + 1)
            self.capture.add(self.stream, self.pending[:take])
            del self.pending[:take]
            return
        end = self.pending.find(b"\x1f\n", at + len(self.marker))
        if end < 0:
            if len(self.pending) > at + len(self.marker) + 8192:
                raise ShellFailure("shell.completion_invalid", unknown=True)
            return
        self.capture.add(self.stream, self.pending[:at])
        self.metadata = bytes(self.pending[at + len(self.marker):end])
        # Trailing bytes would belong to work escaping the command boundary.
        if end + 2 != len(self.pending):
            raise ShellFailure("shell.output_after_completion", unknown=True)
        self.pending.clear()


class ShellExecutor:
    def __init__(self, workspace, *, readonly=False, persistent=True, output_bytes=24576, bash="/bin/bash"):
        self.workspace = Path(workspace).resolve(strict=True)
        self.readonly, self.persistent = readonly, persistent
        self.output_bytes, self.bash = output_bytes, bash
        self.process = None

    def directory(self):
        properties = {"command": {"type": "string", "minLength": 1}, "cwd": {"type": "string"},
                      "timeout": {"type": "integer", "minimum": 0, "maximum": 600},
                      "timeout_ms": {"type": "integer", "minimum": 1, "maximum": 600000},
                      "async": {"type": "boolean"}, "pty": {"type": "boolean"},
                       "env": {"type": "object", "additionalProperties": {"type": "string"}}}
        return {"tools": [{"name": "bash_readonly" if self.readonly else "bash",
                           "description": "Execute a bounded shell command in the approved service workspace.",
                           "input_schema": {"type": "object", "properties": properties,
                                            "required": ["command"], "additionalProperties": False}}]}

    def validate(self, tool, value):
        expected = "bash_readonly" if self.readonly else "bash"
        if tool != expected or not isinstance(value, dict) or set(value) - {"command", "cwd", "timeout", "timeout_ms", "async", "pty", "env"}:
            raise ShellFailure("shell.argument_invalid")
        command = value.get("command")
        if not isinstance(command, str) or not command.strip() or "\x00" in command:
            raise ShellFailure("shell.command_invalid")
        for key in ("async", "pty"):
            if key in value and type(value[key]) is not bool:
                raise ShellFailure("shell.argument_invalid")
        if value.get("async", False):
            # No unowned backend job. The host Task runtime migration is a
            # separate required part of the unfinished Shell package.
            raise ShellFailure("shell.managed_job_runtime_required")
        if self.readonly and (value.get("pty", False) or readonly_violation(command)):
            raise ShellFailure("tool.readonly_rejected")
        timeout = value.get("timeout", 60)
        if type(timeout) is not int or not 0 <= timeout <= 600:
            raise ShellFailure("shell.timeout_invalid")
        if "timeout_ms" in value:
            precise = value["timeout_ms"]
            if "timeout" in value or type(precise) is not int or not 1 <= precise <= 600000:
                raise ShellFailure("shell.timeout_invalid")
            timeout = precise / 1000
        requested = value.get("cwd", "")
        if not isinstance(requested, str) or "\x00" in requested:
            raise ShellFailure("shell.cwd_invalid")
        try:
            cwd = (self.workspace / requested).resolve(strict=True) if requested else self.workspace
        except (OSError, ValueError) as error:
            raise ShellFailure("shell.cwd_invalid") from error
        if not cwd.is_dir() or not cwd.is_relative_to(self.workspace):
            raise ShellFailure("shell.cwd_outside_workspace")
        # Explicit caller values become quoted exports inside the admitted
        # command. They never augment the operator's process-launch environment.
        environment = value.get("env", {})
        if not isinstance(environment, dict):
            raise ShellFailure("shell.env_invalid")
        prefix = []
        for name, authored in environment.items():
            if (not isinstance(name, str) or not name or
                not (name[0] in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_" and
                     all(c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789" for c in name)) or
                not isinstance(authored, str) or "\x00" in authored):
                raise ShellFailure("shell.env_invalid")
            prefix.append("export " + name + "=" + shlex.quote(authored) + "; ")
        return "".join(prefix) + command, cwd, timeout or 600

    @staticmethod
    def stop(process):
        for sig, wait in ((signal.SIGTERM, 0.15), (signal.SIGKILL, 2)):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=wait)
            except subprocess.TimeoutExpired:
                if sig == signal.SIGKILL:
                    raise ShellFailure("shell.cleanup_unknown", unknown=True)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()

    def close(self):
        selected, self.process = self.process, None
        if selected is not None:
            self.stop(selected)

    def execute(self, tool, value):
        command, cwd, timeout = self.validate(tool, value)
        if not os.path.isabs(self.bash) or not os.access(self.bash, os.X_OK):
            raise ShellFailure("shell.dependency_missing")
        if value.get("pty", False) or not self.persistent:
            return self.oneshot(command, cwd, timeout, terminal=value.get("pty", False))
        return self.session(command, cwd if value.get("cwd", "") else None, timeout)

    def session(self, command, cwd, timeout):
        if self.process is None:
            self.process = subprocess.Popen([self.bash, "--noprofile", "--norc"], cwd=self.workspace,
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                            start_new_session=True)
        process = self.process
        nonce = os.urandom(24).hex().encode("ascii")
        markers = {"stdout": b"\n\x1eAXYNDRA_DONE_" + nonce + b":",
                   "stderr": b"\n\x1eAXYNDRA_ERR_" + nonce + b":"}
        prefix = "cd -- " + shlex.quote(str(cwd)) + " &&\n" if cwd is not None else ""
        script = prefix + "{\n" + command + "\n} </dev/null\n__axyndra_status=$?\n"
        script += "printf " + shlex.quote(markers["stdout"].decode() + "%s|%s\x1f\n") + ' "$__axyndra_status" "$PWD"\n'
        script += "printf " + shlex.quote(markers["stderr"].decode() + "\x1f\n") + " >&2\n"
        capture = Capture(self.output_bytes)
        readers = {name: MarkerReader(marker, capture, name) for name, marker in markers.items()}
        selector = selectors.DefaultSelector()
        try:
            for name in readers:
                stream = getattr(process, name)
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            process.stdin.write(script.encode("utf-8")); process.stdin.flush()
            until = time.monotonic() + timeout
            while selector.get_map():
                if time.monotonic() >= until:
                    for reader in readers.values():
                        capture.add(reader.stream, reader.pending)
                        reader.pending.clear()
                    # Cwd after an interrupted command is unknown; do not invent it.
                    raise ShellFailure("shell.command_timeout", unknown=True,
                                       observed=capture.result(124, "", timed_out=True))
                for key, _ in selector.select(min(0.05, max(0, until - time.monotonic()))):
                    data = os.read(key.fileobj.fileno(), 16384)
                    if not data:
                        raise ShellFailure("shell.command_outcome_unknown", unknown=True)
                    reader = readers[key.data]; reader.feed(data)
                    if reader.metadata is not None:
                        selector.unregister(key.fileobj)
            status, directory = readers["stdout"].metadata.decode("utf-8").split("|", 1)
            return capture.result(int(status), directory)
        except (OSError, ValueError, ShellFailure) as error:
            self.close()
            if isinstance(error, ShellFailure):
                raise
            raise ShellFailure("shell.command_outcome_unknown", unknown=True) from error
        finally:
            selector.close()

    def oneshot(self, command, cwd, timeout, *, terminal):
        master = slave = None
        process = None
        capture = Capture(self.output_bytes)
        selector = selectors.DefaultSelector()
        try:
            if terminal:
                master, slave = pty.openpty()
            process = subprocess.Popen([self.bash, "--noprofile", "--norc", "-lc", command], cwd=cwd,
                                       stdin=subprocess.DEVNULL, stdout=slave if terminal else subprocess.PIPE,
                                       stderr=slave if terminal else subprocess.PIPE, start_new_session=True)
            if slave is not None:
                os.close(slave); slave = None
            sources = [(master, "stdout")] if terminal else [(process.stdout, "stdout"), (process.stderr, "stderr")]
            for stream, name in sources:
                descriptor = stream if isinstance(stream, int) else stream.fileno()
                os.set_blocking(descriptor, False); selector.register(stream, selectors.EVENT_READ, name)
            until = time.monotonic() + timeout
            while selector.get_map() or process.poll() is None:
                if time.monotonic() >= until:
                    raise ShellFailure("shell.command_timeout", unknown=True,
                                       observed=capture.result(124, "", timed_out=True, terminal=master is not None))
                for key, _ in selector.select(min(0.05, max(0, until - time.monotonic()))):
                    try:
                        data = os.read(key.fd, 16384)
                    except OSError as error:
                        if terminal and error.errno == errno.EIO:
                            data = b""
                        else:
                            raise
                    if data:
                        capture.add(key.data, data)
                    else:
                        selector.unregister(key.fileobj)
            return capture.result(process.wait(), str(cwd), terminal=master is not None)
        except OSError as error:
            raise ShellFailure("shell.command_outcome_unknown", unknown=process is not None) from error
        finally:
            selector.close()
            if process is not None:
                self.stop(process)
            for descriptor in (master, slave):
                if descriptor is not None:
                    os.close(descriptor)


def emit_reply(value):
    raw = encoded(value)
    if len(raw) > 60000:
        raise ShellFailure("shell.result_limit", unknown=True)
    sys.stdout.buffer.write(raw + b"\n"); sys.stdout.buffer.flush()


def stream_artifacts(request_id, value):
    """Only bytes become proposals. The native endpoint obtains references
    from the host, never accepts a backend path or a claimed artifact ID."""
    for stream in ("stdout", "stderr"):
        raw = value[stream].encode("utf-8")
        if len(raw) <= 4096:
            continue
        # Same raw-content bound as the host observer. Invalid byte replacement
        # can expand UTF8; reject that excessive text instead of false retention.
        if len(raw) > 16777216:
            raise ShellFailure("shell.artifact_text_limit", unknown=True)
        envelope = dict(schema=SCHEMA, id=request_id, stream=stream)
        emit_reply(dict(envelope, type="output_begin", bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
        offset = 0
        while offset < len(raw):
            end = min(offset + 16384, len(raw))
            while end < len(raw) and (raw[end] & 0xC0) == 0x80:
                end -= 1
            text = raw[offset:end].decode("utf-8")
            plain = dict(envelope, type="output_chunk", offset=offset, text=text)
            compact = dict(envelope, type="output_chunk", offset=offset,
                           data_base64=base64.b64encode(raw[offset:end]).decode("ascii"))
            # Keep ordinary UTF-8 unchanged. Escaped controls use canonical
            # base64 so byte-preserving framing does not multiply channel reads.
            emit_reply(compact if len(encoded(compact)) < len(encoded(plain)) else plain)
            offset = end
        emit_reply(dict(envelope, type="output_end"))
        value[stream] = raw[:4096].decode("utf-8", errors="ignore")
        value["truncated"] = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", default=os.getcwd())
    parser.add_argument("--bash", default="/bin/bash")
    parser.add_argument("--readonly", action="store_true")
    parser.add_argument("--oneshot", action="store_true")
    parser.add_argument("--stream-output", action="store_true")
    options = parser.parse_args()
    executor = ShellExecutor(options.workspace, readonly=options.readonly,
                             persistent=not options.oneshot, bash=options.bash,
                             output_bytes=16777216 if options.stream_output else 24576)
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        while True:
            raw = sys.stdin.buffer.readline(30721)
            if not raw:
                return 0
            if len(raw) > 30720 or not raw.endswith(b"\n"):
                return 2
            request = json.loads(raw, object_pairs_hook=no_duplicates)
            required = {"schema", "id", "action"} | ({"tool", "input"} if request.get("action") == "call" else set())
            if set(request) != required or request.get("schema") != SCHEMA or not isinstance(request.get("id"), str):
                return 2
            try:
                if request["action"] == "discover":
                    value = executor.directory()
                elif request["action"] == "call":
                    value = executor.execute(request["tool"], request["input"])
                    if options.stream_output:
                        stream_artifacts(request["id"], value)
                else:
                    return 2
                # A nonzero command is a known failed completion, not success and
                # not an unknown transport outcome. Keep its actual diagnostics.
                command_error = ("shell.command_failed" if request["action"] == "call"
                                 and value["exitCode"] != 0 else None)
                reply = dict(schema=SCHEMA, id=request["id"], status="complete", result=value, error=command_error)
            except ShellFailure as error:
                observed = error.observed
                if options.stream_output and observed is not None:
                    stream_artifacts(request["id"], observed)
                reply = dict(schema=SCHEMA, id=request["id"], status="unknown" if error.unknown else "complete",
                             result=observed, error=error.code)
            output = encoded(reply)
            if len(output) > 60000:
                output = encoded(dict(schema=SCHEMA, id=request["id"], status="unknown", result=None, error="shell.result_limit"))
            sys.stdout.buffer.write(output + b"\n"); sys.stdout.buffer.flush()
            if reply["status"] == "unknown":
                return 1
    finally:
        executor.close()


if __name__ == "__main__":
    raise SystemExit(main())

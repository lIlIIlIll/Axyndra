#!/usr/bin/env python3
import json
import base64
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from shell_backend import SCHEMA, ShellExecutor, ShellFailure


class ShellBackendTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="axyndra-shell-business-")
        self.root = Path(self.temporary.name)
        self.shell = ShellExecutor(self.root)

    def tearDown(self):
        self.shell.close()
        self.temporary.cleanup()

    def call(self, command, **options):
        return self.shell.execute("bash", dict(command=command, **options))

    def test_discovery_and_invalid_input_do_not_start_shell(self):
        with patch("subprocess.Popen", side_effect=AssertionError("discovery cannot spawn")):
            self.assertEqual(self.shell.directory()["tools"][0]["name"], "bash")
            for value in ({}, {"command": "echo x", "timeout": True}, {"command": "echo x", "pty": 1},
                          {"command": "echo x", "unknown": 1}, {"command": "\x00"}):
                with self.assertRaises(ShellFailure):
                    self.shell.execute("bash", value)
            self.assertIsNone(self.shell.process)

    def test_persistent_environment_function_cwd_and_exit_status(self):
        (self.root / "sub").mkdir()
        first = self.call("export SAMPLE=kept; function answer() { printf answer; }; cd sub; printf out; printf err >&2; false")
        self.assertEqual((first["stdout"], first["stderr"], first["exitCode"]), ("out", "err", 1))
        self.assertEqual(first["workingDirectory"], str(self.root / "sub"))
        second = self.call('printf "$SAMPLE:"; answer; printf ":$PWD"')
        self.assertEqual(second["stdout"], "kept:answer:" + str(self.root / "sub"))
        self.assertEqual(self.call("pwd", cwd=".")["stdout"].strip(), str(self.root))

    def test_stdin_eof_cannot_consume_next_completion_script(self):
        self.assertEqual(self.call("cat")["stdout"], "")
        self.assertEqual(self.call("printf next")["stdout"], "next")

    def test_actual_output_is_drained_bounded_and_next_command_remains_usable(self):
        self.shell.output_bytes = 128
        value = self.call("head -c 200000 /dev/zero; printf err >&2")
        self.assertTrue(value["truncated"])
        self.assertEqual(value["stdoutBytes"], 200000)
        self.assertEqual(value["stderrBytes"], 3)
        self.assertLessEqual(len(value["stdout"].encode()) + len(value["stderr"].encode()), 128)
        self.assertEqual(self.call("printf still-owned")["stdout"], "still-owned")

    def test_utf8_output_across_pipe_reads_keeps_exact_text(self):
        value = self.call("printf '雪%.0s' {1..5000}")
        self.assertEqual(value["stdout"], "雪" * 5000)
        self.assertEqual(value["stdoutBytes"], 15000)

    def test_pty_is_real_and_does_not_mutate_persistent_shell(self):
        value = self.call("test -t 1 && printf terminal; export PTY_LOCAL=changed", pty=True)
        self.assertEqual(value["exitCode"], 0)
        self.assertIn("terminal", value["stdout"])
        self.assertEqual(self.call('printf "${PTY_LOCAL-unset}"')["stdout"], "unset")

    def test_oneshot_environment_does_not_persist(self):
        self.shell.persistent = False
        self.assertEqual(self.call("export PRIVATE=inside; printf $PRIVATE")["stdout"], "inside")
        self.assertEqual(self.call('printf "${PRIVATE-unset}"')["stdout"], "unset")

    def test_timeout_kills_owned_process_group_and_marks_unknown(self):
        with self.assertRaises(ShellFailure) as raised:
            self.call("sleep 10 & echo $! >child.pid; wait", timeout=1)
        self.assertTrue(raised.exception.unknown)
        self.assertEqual(raised.exception.code, "shell.command_timeout")
        self.assertIsNone(self.shell.process)
        pid = int((self.root / "child.pid").read_text())
        status = Path(f"/proc/{pid}/stat")
        if status.exists():
            self.assertEqual(status.read_text().split(")", 1)[1].split()[0], "Z")

    def test_readonly_business_checks_and_explicit_async_rejection_have_no_effect(self):
        self.shell.readonly = True
        for value in ({"command": "touch side"}, {"command": "printf side >file"},
                      {"command": "echo x", "pty": True}, {"command": "echo x", "async": True}):
            with self.assertRaises(ShellFailure):
                self.shell.execute("bash_readonly", value)
        self.assertIsNone(self.shell.process)
        value = self.shell.execute("bash_readonly", {"command": "printf read; printf discard >/dev/null; true 2>&1"})
        self.assertEqual(value["stdout"], "read")
        self.assertFalse((self.root / "file").exists())

    def test_requested_cwd_cannot_escape_workspace_or_follow_outside_symlink(self):
        (self.root / "outside").symlink_to(self.root.parent, target_is_directory=True)
        for cwd in ("..", str(self.root.parent), "outside", "does-not-exist"):
            with self.assertRaises(ShellFailure):
                self.call("printf forbidden", cwd=cwd)
        self.assertIsNone(self.shell.process)

    def test_backend_protocol_correlation_discovery_and_call_through_real_process(self):
        frames = [dict(schema=SCHEMA, id="discover", action="discover"),
                  dict(schema=SCHEMA, id="call-1", action="call", tool="bash", input={"command": "printf protocol"})]
        payload = b"".join(json.dumps(frame).encode() + b"\n" for frame in frames)
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("shell_backend.py")),
                                 "--workspace", str(self.root)], input=payload, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], ["discover", "call-1"])
        self.assertEqual(replies[1]["result"]["stdout"], "protocol")
        self.assertTrue(all(reply["status"] == "complete" for reply in replies))

    def test_nonzero_completion_preserves_diagnostics_and_session_is_usable(self):
        frames = [dict(schema=SCHEMA, id="failed", action="call", tool="bash",
                       input={"command": "printf before; printf diagnostic >&2; false"}),
                  dict(schema=SCHEMA, id="next", action="call", tool="bash",
                       input={"command": "printf after"})]
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("shell_backend.py")),
                                 "--workspace", str(self.root)],
                                input=b"".join(json.dumps(frame).encode() + b"\n" for frame in frames),
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        failed, following = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual((failed["status"], failed["error"]), ("complete", "shell.command_failed"))
        self.assertEqual((failed["result"]["exitCode"], failed["result"]["stdout"], failed["result"]["stderr"]),
                         (1, "before", "diagnostic"))
        self.assertEqual((following["status"], following["error"], following["result"]["stdout"]),
                         ("complete", None, "after"))

    def test_backend_termination_joins_its_running_shell_group(self):
        process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("shell_backend.py")),
                                    "--workspace", str(self.root)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            frame = dict(schema=SCHEMA, id="owned", action="call", tool="bash",
                         input={"command": "sleep 60 & echo $! >owned-child.pid; wait", "timeout": 600})
            process.stdin.write(json.dumps(frame).encode() + b"\n"); process.stdin.flush()
            until = time.monotonic() + 3
            marker = self.root / "owned-child.pid"
            while not marker.exists() and time.monotonic() < until:
                time.sleep(0.01)
            self.assertTrue(marker.exists())
            child = int(marker.read_text())
            process.terminate(); self.assertEqual(process.wait(timeout=3), 143)
            status = Path(f"/proc/{child}/stat")
            if status.exists():
                self.assertEqual(status.read_text().split(")", 1)[1].split()[0], "Z")
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=3)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()

    def test_large_output_has_complete_bounded_utf8_stream_and_small_terminal(self):
        expected = ("雪" * 1000000).encode()
        frames = [dict(schema=SCHEMA, id="large", action="call", tool="bash",
                       input={"command": "/usr/bin/python3 -c 'print(\"雪\"*1000000,end=\"\")'"}),
                  dict(schema=SCHEMA, id="next", action="call", tool="bash", input={"command": "printf next"})]
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("shell_backend.py")),
                                 "--workspace", str(self.root), "--stream-output"],
                                input=b"".join(json.dumps(frame).encode() + b"\n" for frame in frames),
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        wire = result.stdout.splitlines()
        self.assertTrue(all(len(line) <= 60000 for line in wire))
        values = [json.loads(line) for line in wire]
        first = values[0]
        self.assertEqual((first["type"], first["stream"], first["bytes"], first["sha256"]),
                         ("output_begin", "stdout", len(expected), hashlib.sha256(expected).hexdigest()))
        restored = bytearray()
        for chunk in values[1:-3]:
            self.assertEqual(chunk["type"], "output_chunk")
            self.assertEqual(chunk["offset"], len(restored))
            raw = base64.b64decode(chunk["data_base64"], validate=True) if "data_base64" in chunk else chunk["text"].encode()
            self.assertTrue(0 < len(raw) <= 16384)
            restored.extend(raw)
        self.assertEqual(bytes(restored), expected)
        self.assertEqual(len(values[1:-3]), 184)
        self.assertEqual(values[-3]["type"], "output_end")
        self.assertEqual(values[-2]["status"], "complete")
        self.assertTrue(values[-2]["result"]["truncated"])
        self.assertLessEqual(len(values[-2]["result"]["stdout"].encode()), 4096)
        self.assertEqual(values[-1]["result"]["stdout"], "next")

    def test_control_characters_remain_complete_and_each_json_chunk_is_bounded(self):
        frame = dict(schema=SCHEMA, id="nul", action="call", tool="bash",
                     input={"command": "head -c 30000 /dev/zero; printf diagnostic >&2"})
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("shell_backend.py")),
                                 "--workspace", str(self.root), "--stream-output"],
                                input=json.dumps(frame).encode() + b"\n", capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(len(line) <= 60000 for line in result.stdout.splitlines()))
        values = [json.loads(line) for line in result.stdout.splitlines()]
        chunks = [value for value in values if value.get("type") == "output_chunk"]
        self.assertTrue(all("data_base64" in value and "text" not in value for value in chunks))
        self.assertEqual([len(base64.b64decode(value["data_base64"], validate=True)) for value in chunks], [16384, 13616])
        self.assertEqual(b"".join(base64.b64decode(value["data_base64"], validate=True) for value in chunks), b"\0" * 30000)
        self.assertLess(sum(len(json.dumps(value).encode()) for value in chunks), 45000)
        self.assertEqual(values[-1]["result"]["stderr"], "diagnostic")


if __name__ == "__main__":
    unittest.main(verbosity=2)

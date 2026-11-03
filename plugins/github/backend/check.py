#!/usr/bin/env python3
"""Backend business/process checks; never a Product or native endpoint claim."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().with_name("github_backend.py")
spec = importlib.util.spec_from_file_location("github_backend", path)
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


class RecordedExecutor(backend.Executor):
    def __init__(self):
        super().__init__("/usr/bin/gh", "/usr/bin/git")
        self.calls = []
        self.origin = "https://github.com/owner/project.git"

    def command(self, executable, arguments, timeout):
        self.calls.append((executable, arguments, timeout))
        self.commands_started += 1
        if arguments == ["remote", "get-url", "--push", "--all", "origin"]:
            return self.origin, "", 0
        if arguments == ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]:
            return "owner/project", "", 0
        return "fixture-result", "fixture-stderr", 0


class BusinessTests(unittest.TestCase):
    def test_directory_has_all_eleven_operations_and_closed_schemas(self):
        directory = backend.directory()
        self.assertEqual(len(directory["tools"]), 11)
        self.assertEqual({tool["name"] for tool in directory["tools"]}, set(backend.OPERATIONS))
        for tool in directory["tools"]:
            self.assertFalse(tool["input_schema"]["additionalProperties"])
        self.assertLess(len(backend.encoded(directory)), 65536)

    def test_repo_view_keeps_branch_and_fields(self):
        executor = RecordedExecutor()
        result = executor.execute("repo_view", {"repo": "owner/project", "branch": "topic"})
        self.assertEqual(executor.calls[0][1][:5], ["repo", "view", "owner/project", "--branch", "topic"])
        self.assertIn("defaultBranchRef", executor.calls[0][1][-1])
        self.assertEqual(result["content"], "fixture-result")
        self.assertEqual(result["exitCode"], 0)

    def test_file_read_resolves_local_repo_and_raw_accept(self):
        executor = RecordedExecutor()
        executor.execute("file_read", {"path": "src/file.cj", "branch": "topic"})
        self.assertEqual(len(executor.calls), 2)
        self.assertEqual(executor.calls[1][1], ["api", "repos/owner/project/contents/src/file.cj?ref=topic",
                                              "-H", "Accept: application/vnd.github.raw+json"])

    def test_pr_create_preserves_multiline_body_and_repeat_flags(self):
        executor = RecordedExecutor()
        body = "literal $(touch /should-not-exist)\n`not a shell`\n雪"
        executor.execute("pr_create", {"repo": "owner/project", "title": "Title", "body": body,
                         "draft": True, "fill": True, "reviewer": ["alice", "bob"], "label": ["ready"]})
        argv = executor.calls[0][1]
        self.assertEqual(argv[argv.index("--body") + 1], body)
        self.assertEqual(argv.count("--reviewer"), 2)
        self.assertIn("--draft", argv)

    def test_file_read_percent_encodes_literal_path_segments_and_ref(self):
        executor = RecordedExecutor()
        executor.execute("file_read", {"repo": "owner/project", "path": "src/a?#雪.cj", "branch": "topic/a&b#+"})
        self.assertEqual(executor.calls[0][1][1],
                         "repos/owner/project/contents/src/a%3F%23%E9%9B%AA.cj?ref=topic%2Fa%26b%23%2B")

    def test_all_search_kinds_keep_json_fields_dates_and_literal_query(self):
        for kind in backend.SEARCH_FIELDS:
            executor = RecordedExecutor()
            executor.execute("search_" + kind, {"query": "--untrusted-option", "repo": "owner/project",
                             "since": "2026-01-01", "until": "2026-02-01", "dateField": "updated", "limit": 40})
            argv = executor.calls[0][1]
            self.assertEqual(argv[:2], ["search", kind])
            self.assertEqual(argv[argv.index("--json") + 1], backend.SEARCH_FIELDS[kind])
            self.assertEqual(argv[-2:], ["--", "--untrusted-option updated:>=2026-01-01 updated:<=2026-02-01"])

    def test_checkout_keeps_multiple_targets_and_force(self):
        executor = RecordedExecutor()
        result = executor.execute("pr_checkout", {"pr": ["21", "feature"], "force": True, "repo": "owner/project"})
        self.assertEqual(len(executor.calls), 2)
        self.assertEqual([call[1][2] for call in executor.calls], ["21", "feature"])
        self.assertTrue(all(call[2] == 300 for call in executor.calls))
        self.assertEqual(result["targets"], ["21", "feature"])

    def test_push_checks_actual_https_origin_and_quotes_credential_helper(self):
        executor = RecordedExecutor()
        executor.gh = "/read only/gh'quoted"
        executor.execute("pr_push", {"branch": "feature", "forceWithLease": True})
        argv = executor.calls[1][1]
        self.assertEqual(shlex.split(argv[1].split("!", 1)[1]), [executor.gh, "auth", "git-credential"])
        self.assertEqual(argv[-4:], ["--force-with-lease", "--set-upstream", "origin", "feature"])
        for origin in ["git@github.com:owner/repo.git", "http://github.com/o/r", "https://other.test/o/r",
                       "https://token@github.com/o/r", "https://github.com:444/o/r", "https://github.com/o/r?q=x"]:
            executor = RecordedExecutor()
            executor.origin = origin
            with self.assertRaises(backend.GithubFailure):
                executor.execute("pr_push", {})
            self.assertEqual(len(executor.calls), 1)

    def test_multiple_actual_push_destinations_are_all_checked(self):
        executor = RecordedExecutor()
        executor.origin = "https://github.com/owner/project.git\nhttps://other.test/owner/project.git"
        with self.assertRaises(backend.GithubFailure):
            executor.execute("pr_push", {})
        self.assertEqual(len(executor.calls), 1)
        self.assertEqual(executor.calls[0][1], ["remote", "get-url", "--push", "--all", "origin"])

    def test_enterprise_origin_and_watch_deadline(self):
        executor = RecordedExecutor()
        executor.origin = "https://forge.example.test/owner/repo.git"
        executor.execute("pr_push", {"repo": "forge.example.test/owner/repo"})
        executor.execute("run_watch", {"run": "42", "tail": 20})
        self.assertEqual(executor.calls[-1][1], ["run", "watch", "42", "--exit-status"])
        self.assertEqual(executor.calls[-1][2], 1800)

    def test_invalid_business_arguments_do_not_spawn(self):
        for operation, value in [("unknown", {}), ("pr_create", {"body": 9}), ("pr_create", {"draft": "yes"}),
                                 ("repo_view", {"repo": "--config"}), ("file_read", {"path": "a/../b"}),
                                 ("pr_checkout", {"pr": []}), ("pr_checkout", {"pr": "--force"}),
                                 ("search_code", {"limit": True}), ("search_code", {"limit": 0}),
                                 ("run_watch", {"run": "--help"}), ("repo_view", {"unknown": 1})]:
            executor = RecordedExecutor()
            with self.assertRaises(backend.GithubFailure):
                executor.execute(operation, value)
            self.assertEqual(executor.calls, [])

    def test_correlated_wire_error_after_any_command_remains_unknown(self):
        executor = RecordedExecutor()
        executor.origin = "https://other.test/owner/repo"
        request = {"schema": backend.VERSION, "id": "unique-call", "action": "call", "tool": "pr_push", "input": {}}
        result = backend.handle(request, executor)
        self.assertEqual(result["id"], request["id"])
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(result["error"], "github.argument_invalid")


@unittest.skipUnless(os.name == "posix", "actual process boundary requires POSIX")
class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="github-backend-")
        self.root = Path(self.temp.name)
        self.program = self.root / "fake gh"
        self.program.write_text("#!" + sys.executable + "\n" + '''
import json, os, sys, time
mode = sys.argv[1] if len(sys.argv) > 1 else 'normal'
if mode == 'hang': time.sleep(10)
if mode == 'large':
    sys.stderr.buffer.write(b'x' * 16385); sys.stderr.flush()
elif mode == 'fail':
    print('private diagnostic', file=sys.stderr); raise SystemExit(7)
elif mode == 'fork':
    pid = os.fork()
    if pid == 0:
        open(sys.argv[2], 'w').write(str(os.getpid()))
        time.sleep(10)
    else:
        time.sleep(10)
else:
    print(json.dumps(sys.argv[1:], ensure_ascii=False))
''', encoding="utf-8")
        self.program.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def test_real_argv_path_with_spaces_and_no_shell_expansion(self):
        executor = backend.Executor(str(self.program), str(self.program))
        marker = self.root / "must-not-exist"
        payload = "$(touch " + str(marker) + ")\n雪; `id`"
        stdout, _, status = executor.command(str(self.program), ["normal", payload], 2)
        self.assertEqual(json.loads(stdout), ["normal", payload])
        self.assertEqual(status, 0)
        self.assertFalse(marker.exists())

    def test_real_timeout_and_combined_output_limit_are_unknown(self):
        for mode, timeout, expected in [("hang", 0.1, "github.command_timeout"),
                                        ("large", 2, "github.output_limit"), ("fail", 2, "github.process_failed")]:
            executor = backend.Executor(str(self.program), str(self.program), output_bytes=16384)
            with self.assertRaises(backend.GithubFailure) as raised:
                executor.command(str(self.program), [mode], timeout)
            self.assertEqual(raised.exception.code, expected)
            self.assertTrue(raised.exception.unknown)

    def test_real_timeout_terminates_command_descendant_group(self):
        executor = backend.Executor(str(self.program), str(self.program))
        pid_file = self.root / "descendant"
        with self.assertRaises(backend.GithubFailure):
            executor.command(str(self.program), ["fork", str(pid_file)], 0.3)
        self.assertTrue(pid_file.exists())
        pid = int(pid_file.read_text())
        stat = Path("/proc") / str(pid) / "stat"
        until = time.monotonic() + 2
        while stat.exists() and ") Z " not in stat.read_text() and time.monotonic() < until:
            time.sleep(0.01)
        self.assertTrue(not stat.exists() or ") Z " in stat.read_text(), "descendant remains live")

    def test_dependency_failure_precedes_process_handoff(self):
        executor = backend.Executor(str(self.root / "missing"), str(self.program))
        with self.assertRaises(backend.GithubFailure) as raised:
            executor.command(executor.gh, [], 1)
        self.assertFalse(raised.exception.unknown)
        self.assertEqual(executor.commands_started, 0)

    def test_real_backend_protocol_discovery_and_call(self):
        requests = [{"schema": backend.VERSION, "id": "startup", "action": "discover"},
                    {"schema": backend.VERSION, "id": "call", "action": "call", "tool": "repo_view", "input": {}}]
        result = subprocess.run([sys.executable, str(path), "--gh", str(self.program), "--git", str(self.program)],
                                input=b"".join(backend.encoded(row) + b"\n" for row in requests),
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([row["id"] for row in rows], ["startup", "call"])
        self.assertEqual(len(rows[0]["result"]["tools"]), 11)
        self.assertEqual(rows[1]["status"], "complete")


if __name__ == "__main__":
    unittest.main(verbosity=2)

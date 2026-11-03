#!/usr/bin/env python3
"""GitHub business executor for an explicitly approved managed process channel.

This program never opens the host database or invokes a host tool. Its only
authority is the enclosing backend process sandbox and explicitly supplied env.
The native endpoint owns host IPC; this backend speaks its own bounded protocol.
"""
import argparse
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from urllib.parse import quote, urlsplit

VERSION = "axyndra.github-backend/v1"
INPUT_BYTES = 1024 * 1024
OUTPUT_BYTES = 1024 * 1024
READ_OPERATIONS = (
    "repo_view", "file_read", "search_issues", "search_prs", "search_code",
    "search_commits", "search_repos", "run_watch",
)
OPERATIONS = READ_OPERATIONS + ("pr_create", "pr_checkout", "pr_push")
STRING_FIELDS = (
    "repo", "branch", "path", "title", "body", "base", "head", "query",
    "since", "until", "dateField", "run",
)
BOOL_FIELDS = ("force", "forceWithLease", "draft", "fill")
LIST_FIELDS = ("reviewer", "assignee", "label")
SEARCH_FIELDS = {
    "issues": "number,title,state,url,author,createdAt,updatedAt,repository",
    "prs": "number,title,state,url,author,createdAt,updatedAt,repository",
    "code": "path,repository,sha,textMatches,url",
    "commits": "sha,message,author,date,repository,url",
    "repos": "nameWithOwner,description,url,visibility,updatedAt",
}


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


class GithubFailure(Exception):
    def __init__(self, code, message, *, unknown=False, exit_code=None):
        super().__init__(message)
        self.code, self.unknown, self.exit_code = code, unknown, exit_code


def invalid(message):
    raise GithubFailure("github.argument_invalid", message)


def directory():
    properties = {name: {"type": "string"} for name in STRING_FIELDS}
    properties.update({name: {"type": "boolean"} for name in BOOL_FIELDS})
    properties.update({name: {"type": "array", "items": {"type": "string"}, "maxItems": 128}
                       for name in LIST_FIELDS})
    properties.update({"limit": {"type": "integer", "minimum": 1, "maximum": 1000},
                       "tail": {"type": "integer", "minimum": 0},
                       "pr": {"anyOf": [{"type": "string"},
                           {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 128}]}})
    properties["dateField"] = {"type": "string", "enum": ["created", "updated"]}
    tools = []
    for operation in OPERATIONS:
        required = {"file_read": ["path"], "pr_checkout": ["pr"], "run_watch": ["run"]}.get(operation, [])
        tools.append({"name": operation, "description": "GitHub " + operation.replace("_", " ") + ".",
                      "input_schema": {"type": "object", "properties": properties,
                                       "required": required, "additionalProperties": False}})
    return {"tools": tools}


def validate(operation, value):
    if operation not in OPERATIONS or not isinstance(value, dict):
        invalid("unknown operation or non-object arguments")
    allowed = set(STRING_FIELDS + BOOL_FIELDS + LIST_FIELDS + ("pr", "limit", "tail"))
    if set(value) - allowed:
        invalid("unknown argument")
    for key in STRING_FIELDS:
        if key in value and (not isinstance(value[key], str) or "\x00" in value[key]):
            invalid("string argument required")
    for key in BOOL_FIELDS:
        if key in value and type(value[key]) is not bool:
            invalid("boolean argument required")
    for key in LIST_FIELDS:
        if key in value and (not isinstance(value[key], list) or len(value[key]) > 128 or
                            any(not isinstance(item, str) or "\x00" in item for item in value[key])):
            invalid("bounded string list required")
    for key, low, high in [("limit", 1, 1000), ("tail", 0, 1000000)]:
        if key in value and (type(value[key]) is not int or not low <= value[key] <= high):
            invalid("integer argument out of range")
    if value.get("dateField", "created") not in ("created", "updated"):
        invalid("dateField must be created or updated")
    repo = value.get("repo", "").strip()
    if repo and (not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+){1,2}", repo)
                 or any(part in (".", "..") or part.startswith("-") for part in repo.split("/"))):
        invalid("repo must be OWNER/REPO or HOST/OWNER/REPO")
    if operation == "file_read":
        path = value.get("path", "").strip()
        if not path or path.startswith("/") or "\\" in path or any(part in ("", ".", "..") for part in path.split("/")):
            invalid("path must be repository-relative")
    if operation == "pr_checkout":
        targets = value.get("pr")
        if isinstance(targets, str):
            targets = [targets]
        if not isinstance(targets, list) or not 1 <= len(targets) <= 128 or any(
                not isinstance(item, str) or not item.strip() or item.strip().startswith("-") or "\x00" in item
                for item in targets):
            invalid("pr must be a nonempty target or bounded list")
    if operation == "run_watch" and (not value.get("run", "").strip() or value["run"].strip().startswith("-")):
        invalid("run id or URL is required")
    return value


class Executor:
    def __init__(self, gh, git, *, output_bytes=OUTPUT_BYTES):
        self.gh, self.git, self.output_bytes = gh, git, output_bytes
        self.commands_started = 0

    @staticmethod
    def _stop(process):
        # Each command has a process group inside the host's PID namespace.
        # Stopping the retained backend also destroys that enclosing namespace.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired as error:
            raise GithubFailure("github.cleanup_unknown", "command cleanup is unconfirmed", unknown=True) from error

    def command(self, executable, arguments, timeout):
        if not os.path.isabs(executable) or not os.access(executable, os.X_OK):
            raise GithubFailure("github.dependency_missing", "configured executable is unavailable")
        process = None
        buffers = {"stdout": bytearray(), "stderr": bytearray()}
        selector = selectors.DefaultSelector()
        try:
            process = subprocess.Popen([executable, *arguments], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True)
            self.commands_started += 1
            for name in buffers:
                stream = getattr(process, name)
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            until = time.monotonic() + timeout
            total = 0
            while selector.get_map() or process.poll() is None:
                if time.monotonic() >= until:
                    raise GithubFailure("github.command_timeout", "command deadline elapsed", unknown=True)
                for key, _ in selector.select(min(0.05, max(0, until - time.monotonic()))):
                    chunk = os.read(key.fileobj.fileno(), 16384)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    total += len(chunk)
                    if total > self.output_bytes:
                        raise GithubFailure("github.output_limit", "command output exceeded its limit", unknown=True)
                    buffers[key.data].extend(chunk)
            status = process.wait()
            stdout, stderr = (bytes(buffers[key]).decode("utf-8", errors="strict") for key in ("stdout", "stderr"))
            if status:
                raise GithubFailure("github.process_failed", "GitHub command failed", unknown=True, exit_code=status)
            return stdout.strip(), stderr.strip(), status
        except (OSError, UnicodeError) as error:
            raise GithubFailure("github.process_failed", "GitHub command transport failed", unknown=process is not None) from error
        finally:
            selector.close()
            if process is not None:
                self._stop(process)
                for stream in (process.stdout, process.stderr):
                    stream.close()

    @staticmethod
    def repo_option(value):
        repo = value.get("repo", "").strip()
        return ["--repo", repo] if repo else []

    def execute(self, operation, value):
        validate(operation, value)
        argv, timeout, targets = [], 120, []
        if operation == "repo_view":
            argv = ["repo", "view"]
            if value.get("repo", "").strip():
                argv.append(value["repo"].strip())
            if value.get("branch", "").strip():
                argv.extend(["--branch", value["branch"].strip()])
            argv.extend(["--json", "nameWithOwner,description,url,defaultBranchRef,visibility,isPrivate,homepageUrl,owner"])
        elif operation == "file_read":
            repo = value.get("repo", "").strip()
            if not repo:
                repo, _, _ = self.command(self.gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], 60)
                validate("repo_view", {"repo": repo})
            path = "/".join(quote(part, safe="") for part in value["path"].strip().split("/"))
            endpoint = "repos/" + repo + "/contents/" + path
            if value.get("branch", "").strip():
                endpoint += "?ref=" + quote(value["branch"].strip(), safe="")
            argv = ["api", endpoint, "-H", "Accept: application/vnd.github.raw+json"]
        elif operation == "pr_create":
            argv = ["pr", "create", *self.repo_option(value)]
            for key in ("title", "body", "base", "head"):
                if value.get(key, "").strip():
                    argv.extend(["--" + key, value[key].strip()])
            for key in ("draft", "fill"):
                if value.get(key, False):
                    argv.append("--" + key)
            for key in LIST_FIELDS:
                for item in value.get(key, []):
                    if item.strip():
                        argv.extend(["--" + key, item.strip()])
        elif operation.startswith("search_"):
            kind = operation[len("search_"):]
            query = value.get("query", "").strip()
            date = value.get("dateField", "created")
            for name, symbol in [("since", ">="), ("until", "<=")]:
                if value.get(name, "").strip():
                    query += " " + date + ":" + symbol + value[name].strip()
            argv = ["search", kind, *self.repo_option(value), "--limit", str(value.get("limit", 30)),
                    "--json", SEARCH_FIELDS[kind]]
            if query.strip():
                argv.extend(["--", query.strip()])
        elif operation == "pr_checkout":
            targets = value["pr"] if isinstance(value["pr"], list) else [value["pr"]]
            targets = [item.strip() for item in targets]
            outputs = []
            for target in targets:
                arguments = ["pr", "checkout", target, *self.repo_option(value)]
                if value.get("force", False):
                    arguments.append("--force")
                stdout, _, _ = self.command(self.gh, arguments, 300)
                outputs.append(stdout)
            return self.result(operation, "\n".join(outputs), "", 0, targets)
        elif operation == "pr_push":
            # Fetch and push URLs may differ. Git expands insteadOf and
            # pushInsteadOf here; validate every currently selected push URL.
            origins, _, _ = self.command(self.git, ["remote", "get-url", "--push", "--all", "origin"], 30)
            destinations = origins.splitlines()
            if not destinations or len(destinations) > 128:
                invalid("bounded push destinations are required")
            for origin in destinations:
                self.verify_push_origin(origin, value)
            # Git evaluates credential helpers with a shell. Quote the entire
            # executable path; user arguments never enter this helper string.
            quoted = "'" + self.gh.replace("'", "'\\''") + "'"
            argv = ["-c", "credential.helper=!" + quoted + " auth git-credential", "push"]
            if value.get("forceWithLease", False):
                argv.append("--force-with-lease")
            argv.extend(["--set-upstream", "origin"])
            branch = value.get("branch", "").strip()
            if branch:
                if branch.startswith("-"):
                    invalid("branch cannot begin with a command option")
                argv.append(branch)
            stdout, stderr, status = self.command(self.git, argv, 300)
            return self.result(operation, stdout, stderr, status, [])
        elif operation == "run_watch":
            argv = ["run", "watch", value["run"].strip(), "--exit-status", *self.repo_option(value)]
            timeout = 1800
        stdout, stderr, status = self.command(self.gh, argv, timeout)
        return self.result(operation, stdout, stderr, status, targets)

    @staticmethod
    def verify_push_origin(origin, value):
        try:
            url = urlsplit(origin.strip())
            repo = value.get("repo", "").strip().split("/")
            expected = repo[0] if len(repo) >= 3 else os.environ.get("GH_HOST", "github.com").strip()
            if (url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None
                    or url.query or url.fragment or (url.port or 443) != 443 or url.hostname.lower() != expected.lower()):
                invalid("actual HTTPS origin must match the selected forge")
        except ValueError:
            invalid("invalid HTTPS origin")

    @staticmethod
    def result(operation, stdout, stderr, status, targets):
        return {"content": stdout or "GitHub operation completed.", "op": operation,
                "exitCode": status, "stderr": stderr, "targets": targets}


def handle(request, executor):
    if (not isinstance(request, dict) or request.get("schema") != VERSION or
            not isinstance(request.get("id"), str) or not 1 <= len(request["id"].encode()) <= 256):
        invalid("invalid request identity")
    common = {"schema": VERSION, "id": request["id"]}
    if request.get("action") == "discover" and set(request) == {"schema", "id", "action"}:
        return {**common, "status": "complete", "result": directory(), "error": None}
    if request.get("action") != "call" or set(request) != {"schema", "id", "action", "tool", "input"}:
        invalid("invalid request fields")
    before = executor.commands_started
    try:
        result = executor.execute(request["tool"], request["input"])
        response = {**common, "status": "complete", "result": result, "error": None}
        if len(encoded(response)) > OUTPUT_BYTES:
            raise GithubFailure("github.output_limit", "encoded result exceeded its limit", unknown=True)
        return response
    except GithubFailure as error:
        return {**common, "status": "unknown" if error.unknown or executor.commands_started != before else "complete",
                "result": {"code": error.code, "message": str(error), "exitCode": error.exit_code},
                "error": error.code}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gh", required=True)
    parser.add_argument("--git", required=True)
    args = parser.parse_args(argv)
    executor = Executor(args.gh, args.git)
    while True:
        line = sys.stdin.buffer.readline(INPUT_BYTES + 1)
        if not line:
            return 0
        if len(line) > INPUT_BYTES or not line.endswith(b"\n"):
            return 3
        try:
            request = json.loads(line, object_pairs_hook=no_duplicates)
            response = handle(request, executor)
        except (ValueError, GithubFailure, UnicodeError):
            return 3
        data = encoded(response)
        if len(data) > OUTPUT_BYTES:
            return 3
        sys.stdout.buffer.write(data + b"\n")
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    raise SystemExit(main())

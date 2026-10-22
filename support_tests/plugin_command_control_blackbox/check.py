#!/usr/bin/env python3
"""Real installed Workflow Command -> CLI/RPC -> canonical SQLite contracts.

Does not build, use fixture mode, call model endpoints, or mint host control facts.
Run only against a fresh App/package built with the complete candidate chain.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugin_cli_blackbox"))
from owned_process import owned_process, termination_signals
from rpc_client import RpcClient
from check import stored_value


def require(value, message):
    if not value:
        raise AssertionError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package_seal(root):
    return [{"path": str(p.relative_to(root)), "sha256": sha(p), "mode": p.stat().st_mode & 0o777}
            for p in sorted(root.rglob("*")) if p.is_file()]


class Fixture:
    def __init__(self, args, label):
        self.args = args
        self.path = Path(tempfile.mkdtemp(prefix="workflow-command-" + label + "-", dir=args.temp_parent))
        self.workspace = self.path / "workspace"
        self.workspace.mkdir()
        self.settings = self.path / "settings"
        self.database = self.settings / "sessions/state.db"
        keep = {"PATH", "LD_LIBRARY_PATH", "LANG", "LC_ALL", "HOME", "TMPDIR", "XDG_RUNTIME_DIR",
                "CANGJIE_HOME", "CANGJIE_ROOT", "CANGJIE_PATH", "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH",
                "AXYNDRA_SDK_ROOT", "AXYNDRA_STDX_ROOT", "AXYNDRA_NATIVE_ROOT", "AXYNDRA_NETWORK_BRIDGE",
                "AXYNDRA_CLANG_RUNTIME_PATH", "SSL_CERT_FILE", "SSL_CERT_DIR"}
        self.env = {k: v for k, v in os.environ.items() if k in keep}
        self.env.update(AXYNDRA_HOME=str(self.settings), NO_COLOR="1")
        self.log = args.evidence / label
        self.log.mkdir()
        self.counter = 0
        self.run(["plugin", "import", str(args.workflow_package), "--scope", "workspace"])
        records = json.loads(self.run(["plugin", "list", "--json"]))
        records = [r for r in records if r["namespace"] == "axyndra:workflow"]
        require(len(records) == 1, "exact installed Workflow namespace missing")
        self.record = records[0]
        (self.settings / "plugins").mkdir(exist_ok=True)
        (self.settings / "plugins/documents.json").write_text(json.dumps({
            "version": 1, "plugins": [{"namespace": self.record["namespace"],
                "package_digest": self.record["content_digest"], "tools": [
                    {"name": name, "documents": [{"key": name, "read": True, "write": True}]}
                    for name in ("todo", "goal")]}]}) + "\n", encoding="utf-8")
        self.run(["plugin", "enable", self.record["namespace"], "--scope", "workspace"])
        self.route = "plugin." + self.record["namespace"] + ".todo"

    def argv(self, extra):
        return [str(self.args.app), "--cwd", str(self.workspace), "--approval-mode", "manual", *extra]

    def run(self, extra, input_text="", expected=0):
        self.counter += 1
        with (self.log / (str(self.counter) + ".stdout")).open("w", encoding="utf-8") as out, \
                (self.log / (str(self.counter) + ".stderr")).open("w", encoding="utf-8") as err:
            with owned_process(self.argv(extra), cwd=self.workspace, env=self.env,
                               stdin=subprocess.PIPE, stdout=out, stderr=err, text=True) as process:
                process.communicate(input=input_text, timeout=self.args.timeout)
                require(process.returncode == expected, "unexpected CLI exit " + str(process.returncode))
        return (self.log / (str(self.counter) + ".stdout")).read_text(encoding="utf-8")

    def scalar(self, sql):
        with sqlite3.connect(self.database.as_uri() + "?mode=ro", uri=True) as db:
            return db.execute(sql).fetchone()[0]

    def check(self, written):
        require(self.scalar("SELECT COUNT(*) FROM model_attempts") == 0, "Command fabricated a model Attempt")
        require(self.scalar("SELECT COUNT(*) FROM runs") == 1, "read/mutation did not share one Run")
        require(self.scalar("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')") == 0,
                "Command left active canonical operations")
        require(self.scalar("SELECT COUNT(*) FROM plugin_documents WHERE document_key='todo' AND revision=1") == int(written),
                "unexpected document mutation")
        require(self.scalar("SELECT COUNT(*) FROM operation_receipts") == (3 if written else 2), "actual receipt count")
        require(self.scalar("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'") == 0,
                "Todo Command created continuation authority")


def cli_approve(args):
    f = Fixture(args, "cli-approve")
    text = f.run(["plugin", "command", f.route, '{"op":"init","items":["CLI frozen item"]}'], "yes\nyes\n")
    require(text.count("Approval required:") == 2, "CLI must expose both actual stages")
    f.check(True)
    return {"fixture": str(f.path), "approvals": 2}


def cli_eof(args):
    f = Fixture(args, "cli-eof")
    f.run(["plugin", "command", f.route, '{"op":"init","items":["must not be written"]}'], expected=1)
    f.check(False)
    require(f.scalar("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0, "EOF started an effect")
    return {"fixture": str(f.path)}


def rpc_approve(args):
    f = Fixture(args, "rpc-approve")
    incoming = queue.Queue()
    with (f.log / "rpc.stdout").open("w", encoding="utf-8") as out, \
            (f.log / "rpc.stderr").open("w", encoding="utf-8") as err:
        with owned_process(f.argv(["--mode", "rpc"]), cwd=f.workspace, env=f.env,
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True, bufsize=1) as process:
            def read():
                try:
                    for line in process.stdout:
                        out.write(line)
                        out.flush()
                        incoming.put(json.loads(line))
                except Exception as error:
                    incoming.put(error)
                finally:
                    incoming.put(EOFError("RPC closed"))

            reader = threading.Thread(target=read, daemon=True)
            reader.start()

            def send(value):
                process.stdin.write(json.dumps(value) + "\n")
                process.stdin.flush()

            def until(predicate):
                end = time.monotonic() + args.timeout
                while time.monotonic() < end:
                    value = incoming.get(timeout=max(0.01, end - time.monotonic()))
                    if isinstance(value, Exception):
                        raise value
                    if predicate(value):
                        return value
                raise TimeoutError("RPC did not publish expected actual state")

            send({"id": "command", "type": "plugin_command", "routeName": f.route,
                  "arguments": '{"op":"init","items":["RPC frozen item"]}'})
            first = until(lambda v: v.get("type") == "approval_request")
            require(first["tool"] == "host.context.read", "first approval is actual ContextRead")
            send({"id": "invalid", "type": "approve_session", "operationId": first["operationId"]})
            invalid = until(lambda v: v.get("id") == "invalid")
            require(invalid.get("success") is False, "session-wide approval must be explicitly rejected")
            require(f.scalar("SELECT COUNT(*) FROM operation_receipts") == 0, "invalid choice consumed approval")
            send({"id": "read", "type": "approve", "operationId": first["operationId"]})
            second = until(lambda v: v.get("type") == "approval_request" and v["operationId"] != first["operationId"])
            require(f.scalar("SELECT COUNT(*) FROM plugin_documents WHERE document_key='todo'") == 0, "read phase mutated document")
            send({"id": "mutation", "type": "approve", "operationId": second["operationId"]})
            end = time.monotonic() + args.timeout
            while time.monotonic() < end:
                if f.scalar("SELECT COUNT(*) FROM runs WHERE state='completed'") == 1:
                    break
                time.sleep(0.02)
            f.check(True)
            process.stdin.close()
            process.wait(timeout=10)
            reader.join(timeout=5)
    return {"fixture": str(f.path), "approvals": [first["operationId"], second["operationId"]]}


def rpc_goal_budget(args):
    """An installed Goal must prepare again while its prior allowance is live."""
    f = Fixture(args, "rpc-goal-budget")
    row = f.record
    configuration = f.settings / "plugins"
    (configuration / "documents.json").write_text(json.dumps({
        "version": 1, "plugins": [{"namespace": row["namespace"],
            "package_digest": row["content_digest"], "tools": [
                {"name": name, "preparation_provider": "prepare_document",
                 "documents": [{"key": name, "read": True, "write": True}]}
                for name in ("todo", "goal")]}]}) + "\n", encoding="utf-8")
    (configuration / "todo-tools.json").write_text(json.dumps({
        "schema": "axyndra.todo-tools/v1", "namespace": row["namespace"],
        "package_digest": row["content_digest"], "tool": "todo", "command": "todo"}) + "\n", encoding="utf-8")
    (configuration / "policies.json").write_text(json.dumps({
        "version": 1, "bindings": {"workflow": {"namespace": row["namespace"],
            "package_digest": row["content_digest"], "provider": "propose", "plan_tool": "plan_write"}}}) + "\n", encoding="utf-8")
    argv = [str(args.app), "--cwd", str(f.workspace), "--approval-mode", "trusted", "--mode", "rpc"]
    with RpcClient(argv, workspace=f.workspace, environment=f.env, evidence=f.log,
                   label="goal", timeout=args.timeout) as rpc:
        _, state = rpc.request("get_state")
        require(state.get("success"), "actual RPC state unavailable")
        session = state["data"]["sessionId"]

        def command(name, arguments):
            identifier, accepted = rpc.request("plugin_command",
                routeName="plugin." + row["namespace"] + "." + name, arguments=arguments)
            require(accepted.get("success"), "installed Command was not accepted: " + repr(accepted))
            completed = rpc.wait(lambda value: value.get("type") == "plugin_command_completed" and
                                 value.get("requestId") == identifier)
            require(completed.get("ok"), "installed Command failed: " + repr(completed))

        # Preserve the original consumer sequence: Todo revision2, then Goal
        # set/budget200/pause in ONE running app with actual retained custody.
        command("todo", json.dumps({"op": "init", "items": ["first", "second"]}))
        command("todo", "done first")
        command("goal", "set preserve canonical user budget")
        command("goal", "budget 200")
        with sqlite3.connect(f.database.as_uri() + "?mode=ro", uri=True) as db:
            facts = [stored_value(payload) for (payload,) in db.execute(
                "SELECT payload FROM audit_events WHERE thread_id=? AND kind LIKE 'host_continuation_accounting_v1:%' ORDER BY id", (session,))]
            require(facts and facts[-1]["token_budget"] == 200 and facts[-1]["enabled"],
                    "positive budget200 was not applied to the canonical live allowance")
        command("goal", "pause")
        with sqlite3.connect(f.database.as_uri() + "?mode=ro", uri=True) as db:
            facts = [stored_value(payload) for (payload,) in db.execute(
                "SELECT payload FROM audit_events WHERE thread_id=? AND kind LIKE 'host_continuation_accounting_v1:%' ORDER BY id", (session,))]
            require(facts and facts[-1]["token_budget"] == 200 and not facts[-1]["enabled"],
                    "explicit pause changed the budget or failed to disable its canonical allowance")
            require(db.execute("SELECT revision FROM plugin_documents WHERE thread_id=? AND document_key='todo'", (session,)).fetchall() == [(2,)],
                    "Todo init/done did not retain canonical revision2")
            require(db.execute("SELECT COUNT(*) FROM thread_metadata WHERE goal_payload<>'' OR todo_payload<>''").fetchone()[0] == 0,
                    "installed commands wrote legacy Goal/Todo state")
            require(db.execute("SELECT COUNT(*) FROM model_attempts").fetchone()[0] == 0,
                    "Goal control fabricated a ModelDecision")
            require(db.execute("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')").fetchone()[0] == 0,
                    "Goal preparation left an unsettled canonical operation")
            (f.log / "goal-allowance.json").write_text(json.dumps(facts, indent=2) + "\n", encoding="utf-8")
    return {"fixture": str(f.path), "budget": 200, "paused": True, "todo_revision": 2}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--workflow-package", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--temp-parent", type=Path)
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    args.app = args.app.resolve()
    args.workflow_package = args.workflow_package.resolve()
    args.evidence = args.evidence.resolve()
    args.evidence.mkdir(parents=True, exist_ok=False)
    before = {"app": sha(args.app), "package": package_seal(args.workflow_package), "runner": sha(Path(__file__))}
    results = []
    with termination_signals():
        for case in (cli_approve, cli_eof, rpc_approve, rpc_goal_budget):
            try:
                details = case(args)
                results.append({"name": case.__name__, "status": "PASS", "details": details})
            except Exception:
                results.append({"name": case.__name__, "status": "FAIL", "traceback": traceback.format_exc()})
            print(results[-1]["status"], case.__name__, flush=True)
    after = {"app": sha(args.app), "package": package_seal(args.workflow_package), "runner": sha(Path(__file__))}
    summary = {"before": before, "after": after, "unchanged": before == after,
               "cases": results, "build_performed": False,
               "status": "PASS" if before == after and all(r["status"] == "PASS" for r in results) else "FAIL"}
    (args.evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())

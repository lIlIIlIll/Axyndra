#!/usr/bin/env python3
"""Real app CLI + installed native web plugin + loopback HTTP acceptance.

Run under scripts/pinned_cangjie after building the app and web package.
This script never builds, registers fake tools, edits installation locks, or
configures a model. Installation and tool invocation use real maintenance CLI
entry points with no --fixture and no provider credentials.
"""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
import traceback
import urllib.parse
from owned_process import kill_owned, owned_process, termination_signals

NAMESPACE = "axyndra:web-search"
TOOL = "plugin." + NAMESPACE + ".web_search"
HIDDEN = "host.network.http"
SEVEN_PARAMETERS = {
    "query", "provider", "recency", "limit", "max_tokens", "temperature", "num_search_results"
}


def write_json(path: Path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sha256(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def stored_value(source: str):
    """Read the documented byte-framed SQLite AgentValue codec, not JSON."""
    data = source.encode("utf-8")
    cursor = 0

    def frame():
        nonlocal cursor
        colon = data.index(b":", cursor)
        size = int(data[cursor:colon])
        start = colon + 1
        cursor = start + size
        require(size >= 0 and cursor <= len(data), "invalid stored frame")
        return data[start:cursor].decode("utf-8")

    def value():
        nonlocal cursor
        tag = chr(data[cursor])
        cursor += 1
        if tag in "ntf":
            return {"n": None, "t": True, "f": False}[tag]
        if tag == "s":
            return frame()
        if tag == "d":
            return json.loads(frame())
        if tag == "l":
            return [value() for _ in range(int(frame()))]
        if tag == "o":
            result = {}
            for _ in range(int(frame())):
                name = frame()
                require(name not in result, "duplicate stored object field")
                result[name] = value()
            return result
        raise AssertionError("unknown stored value tag: " + tag)

    result = value()
    require(cursor == len(data), "stored value has trailing bytes")
    return result


class Origin:
    """Actual HTTP origin. Mode changes its response, never the client path."""
    def __init__(self, evidence):
        self.evidence = evidence
        self.requests = []
        self.mode = "success"
        self.lock = threading.Lock()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                with owner.lock:
                    mode = owner.mode
                    owner.requests.append({
                        "method": "GET", "path": parsed.path,
                        "query": urllib.parse.parse_qs(parsed.query), "response_mode": mode,
                    })
                    write_json(owner.evidence / "origin-requests.json", owner.requests)
                status = 503 if mode == "http-error" else 200
                payload = {"results": [{
                    "title": "Native CLI Searx fixture", "url": "https://example.test/cli-result",
                    "content": "real tools CLI gateway result",
                }]} if status == 200 else {"error": "controlled origin unavailable"}
                encoded = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        write_json(evidence / "origin-requests.json", [])

    @property
    def base(self):
        return "http://127.0.0.1:" + str(self.server.server_address[1])

    def count(self):
        with self.lock:
            return len(self.requests)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(3)


class Acceptance:
    def __init__(self, args):
        self.args = args
        self.evidence = args.evidence.resolve()
        self.evidence.mkdir(parents=True, exist_ok=False)
        self.fixture = Path(tempfile.mkdtemp(prefix="axyndra-tools-cli-", dir=args.temp_parent))
        self.workspace = self.fixture / "workspace"
        self.workspace.mkdir()
        self.settings = self.fixture / "settings"
        self.database = self.settings / "sessions/state.db"
        # Deliberate allowlist: no model/provider tokens, generic proxy vars,
        # fixture probe settings, or user AXYNDRA configuration are inherited.
        keep = {
            "PATH", "LD_LIBRARY_PATH", "LANG", "LC_ALL", "HOME", "TMPDIR", "XDG_RUNTIME_DIR",
            "CANGJIE_HOME", "CANGJIE_ROOT", "CANGJIE_PATH", "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH",
            "AXYNDRA_SDK_ROOT", "AXYNDRA_STDX_ROOT", "AXYNDRA_NATIVE_ROOT", "AXYNDRA_NETWORK_BRIDGE",
            "AXYNDRA_CLANG_RUNTIME_PATH", "SSL_CERT_FILE", "SSL_CERT_DIR",
        }
        self.env = {key: val for key, val in os.environ.items() if key in keep}
        self.env["AXYNDRA_HOME"] = str(self.settings)
        self.env["NO_COLOR"] = "1"
        self.steps = []
        self.commands = []
        self.origin = Origin(self.evidence)
        self.started = time.time()
        package_files = [{"path": str(path.relative_to(args.web_package)), "sha256": sha256(path),
                          "mode": oct(path.stat().st_mode & 0o777)}
                         for path in sorted(args.web_package.rglob("*")) if path.is_file()]
        write_json(self.evidence / "package-files.json", package_files)
        self.metadata = {
            "app": str(args.app), "app_sha256": sha256(args.app),
            "web_package": str(args.web_package), "fixture": str(self.fixture),
            "settings_root": str(self.settings), "workspace": str(self.workspace),
            "database": str(self.database), "origin": self.origin.base,
            "environment_keys": sorted(self.env), "harness_sha256": sha256(Path(__file__)),
            "installation_mode": "real plugin maintenance CLI, no --fixture or model credentials",
            "tool_mode": "real LocalMaintenance, no --fixture, no model/provider credentials",
            "build": "not performed by this harness; app/package digests identify actual tested artifacts",
            "updated_web_package": str(args.updated_web_package),
            "updated_entry_sha256": sha256(args.updated_web_package / "bin/web-search-plugin"),
        }
        write_json(self.evidence / "environment.json", self.metadata)

    def mark(self, name, evidence=None):
        self.steps.append({"name": name, "status": "PASS", "evidence": evidence})
        print("PASS " + name, flush=True)

    def command(self, label, argv, *, approval="manual", static=False):
        command = [str(self.args.app)]
        if not static:
            command += ["--cwd", str(self.workspace), "--approval-mode", approval]
        command += argv
        prefix = f"{len(self.commands) + 1:02d}-{label}"
        started = time.monotonic()
        with (self.evidence / (prefix + ".stdout.log")).open("wb") as out, \
                (self.evidence / (prefix + ".stderr.log")).open("wb") as err:
            with owned_process(command, cwd=self.workspace, env=self.env,
                               stdin=subprocess.DEVNULL, stdout=out, stderr=err) as process:
                timed_out = False
                try:
                    code = process.wait(timeout=self.args.timeout)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    code = kill_owned(process)
        result = {"label": label, "command": command, "exit_code": code, "timed_out": timed_out,
                  "seconds": time.monotonic() - started,
                  "stdout": prefix + ".stdout.log", "stderr": prefix + ".stderr.log"}
        self.commands.append(result)
        write_json(self.evidence / "commands.json", self.commands)
        require(not timed_out, label + " timed out; see raw logs")
        stdout = (self.evidence / result["stdout"]).read_text(encoding="utf-8")
        stderr = (self.evidence / result["stderr"]).read_text(encoding="utf-8")
        require("An exception has occurred" not in stdout + stderr, label + " had uncaught exception")
        return code, stdout, stderr

    def db(self):
        require(self.database.is_file(), "normal tools CLI did not create its canonical database")
        connection = sqlite3.connect(self.database.as_uri() + "?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        return connection

    def operation_ids(self):
        with self.db() as database:
            return {row[0] for row in database.execute("SELECT id FROM operations")}

    def plugin_records(self, label):
        code, stdout, stderr = self.command(label, ["plugin", "list", "--json"])
        require(code == 0, label + " failed: " + stderr + stdout)
        return [row for row in json.loads(stdout) if row["namespace"] == NAMESPACE]

    def lock_records(self):
        path = self.workspace / ".axyndra/plugins/lock.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def expect_unavailable(self, label, arguments):
        code, stdout, stderr = self.command(label + "-inspect", ["tools", "inspect", TOOL])
        require(code != 0 and "tool.unavailable" in stdout + stderr, label + " remained inspectable")
        before = self.operation_ids()
        requests = self.origin.count()
        code, stdout, stderr = self.command(label + "-invoke", ["tools", "invoke", TOOL, arguments], approval="trusted")
        require(code != 0 and "tool.not_found" in stdout + stderr, label + " remained callable")
        require(before == self.operation_ids() and self.origin.count() == requests, label + " executed unavailable tool")

    def lifecycle(self, arguments, old_digest):
        self.origin.mode = "success"
        initial_requests = self.origin.count()
        services_digest = sha256(self.settings / "plugins/services.json")
        original = self.plugin_records("lifecycle-original")[0]
        for action in ("disable", "enable"):
            code, stdout, stderr = self.command(action + "-lifecycle", ["plugin", action, NAMESPACE, "--scope", "workspace"])
            require(code == 0, action + " failed: " + stdout + stderr)
            record = self.plugin_records(action + "-record")[0]
            require(record["enabled"] is (action == "enable") and record["content_digest"] == old_digest,
                    action + " changed unrelated plugin identity")
            if action == "disable":
                self.expect_unavailable("disabled", arguments)
            else:
                code, stdout, stderr = self.command("reenabled-inspect", ["tools", "inspect", TOOL])
                require(code == 0 and json.loads(stdout)["name"] == TOOL, "reenabled native tool missing: " + stderr)
        self.mark("disable makes tool unavailable; reenable restores its original contribution")

        # A manifest-only version bump must fail real endpoint activation and
        # restore the active previous generation, not masquerade as an upgrade.
        broken = self.fixture / "manifest-only-update"
        shutil.copytree(self.args.web_package, broken, symlinks=True)
        manifest = json.loads((broken / "axyndra.plugin.json").read_text())
        manifest["version"] = "1.0.1"
        write_json(broken / "axyndra.plugin.json", manifest)
        code, stdout, stderr = self.command("manifest-only-update-rejected",
            ["plugin", "update", NAMESPACE, str(broken), "--scope", "workspace"])
        require(code != 0, "manifest-only version change incorrectly activated an incompatible endpoint")
        restored = self.plugin_records("after-failed-update")[0]
        require(restored["version"] == original["version"] and restored["content_digest"] == old_digest and restored["enabled"],
                "failed activation did not retain the old enabled package")
        code, stdout, stderr = self.command("old-help-after-failed-update", ["plugin", "command", "plugin." + NAMESPACE + ".help"])
        require(code == 0 and "JSON INPUT" in stdout, "old native endpoint unusable after failed update: " + stderr)
        self.mark("manifest-only incompatible upgrade rejects and retains the callable original endpoint")

        code, stdout, stderr = self.command("real-version-update",
            ["plugin", "update", NAMESPACE, str(self.args.updated_web_package), "--scope", "workspace"])
        require(code == 0, "real 1.0.1 update failed: " + stdout + stderr)
        updated = self.plugin_records("updated-record")[0]
        require(updated["version"] == "1.0.1" and updated["content_digest"] != old_digest and updated["enabled"],
                "new version/digest did not become the active generation")
        code, stdout, stderr = self.command("new-help", ["plugin", "command", "plugin." + NAMESPACE + ".help"])
        require(code == 0 and "JSON INPUT" in stdout, "real new endpoint handshake/command failed: " + stderr)
        before = self.operation_ids()
        code, stdout, stderr = self.command("new-digest-not-granted", ["tools", "invoke", TOOL, arguments], approval="trusted")
        require(code != 0 and "plugin.http_configuration_missing" in stdout + stderr,
                "new package silently inherited old package HTTP grants")
        require(before == self.operation_ids() and self.origin.count() == initial_requests,
                "ungranted updated package admitted or executed HTTP")
        updated_lock = self.lock_records()
        write_json(self.evidence / "updated-generation-lock.json", updated_lock)
        self.mark("real 1.0.1 endpoint activates but cannot inherit earlier package HTTP authorization")

        code, stdout, stderr = self.command("rollback", ["plugin", "rollback", NAMESPACE, "--scope", "workspace"])
        require(code == 0, "rollback failed: " + stdout + stderr)
        rolled_back = self.plugin_records("rolled-back-record")[0]
        require(rolled_back["version"] == original["version"] and rolled_back["content_digest"] == old_digest and
                rolled_back["enabled"] is False,
                "rollback must restore exact prior identity without reviving its superseded workspace activation grant")
        self.expect_unavailable("rollback-awaiting-enable", arguments)
        require(sha256(self.settings / "plugins/services.json") == services_digest,
                "rollback silently rewrote the operator HTTP configuration")
        code, stdout, stderr = self.command("enable-rolled-back-generation",
            ["plugin", "enable", NAMESPACE, "--scope", "workspace"])
        require(code == 0, "explicit enable of rolled-back package failed: " + stderr + stdout)
        reenabled = self.plugin_records("explicitly-enabled-rollback")[0]
        require(reenabled["enabled"] and reenabled["content_digest"] == old_digest,
                "explicit enable did not authorize the exact rolled-back identity")
        require(sha256(self.settings / "plugins/services.json") == services_digest,
                "explicit activation changed separate HTTP grants")
        write_json(self.evidence / "rollback-activation.json", {
            "after_rollback": rolled_back, "after_explicit_enable": reenabled,
            "operator_http_configuration_sha256_before_and_after": services_digest,
            "reason": "Workspace activation grants bind one exact package digest. Reloading history after update disables its superseded grant; rollback does not silently reactivate it.",
            "http_grant": "The operator services file still explicitly binds the original digest; it is never rewritten by this lifecycle test."})
        before = self.operation_ids()
        code, stdout, stderr = self.command("rollback-real-search", ["tools", "invoke", TOOL, arguments], approval="trusted")
        require(code == 0 and "real tools CLI gateway result" in json.loads(stdout)["content"],
                "rolled-back original endpoint not callable with its existing grant: " + stderr)
        require(self.origin.count() == initial_requests + 1, "rollback did not perform one actual request")
        self.prove_http(before, "rollback")
        before_uninstall = self.lock_records()
        write_json(self.evidence / "rolled-back-generation-lock.json", before_uninstall)
        self.mark("rollback restores original identity disabled; explicit reenable permits its separately granted HTTP execution",
                  "rollback-durable-proof.json")

        code, stdout, stderr = self.command("uninstall", ["plugin", "uninstall", NAMESPACE, "--scope", "workspace"])
        require(code == 0, "uninstall failed: " + stdout + stderr)
        require(self.plugin_records("uninstalled-record") == [], "uninstall left an active installation record")
        self.expect_unavailable("uninstalled-after-use", arguments)
        retired = self.lock_records()
        require(retired and all(row.get("history_for") == NAMESPACE for row in retired),
                "uninstall did not preserve prior generations as history")
        roots = sorted({row["root"] for row in retired})
        require(all(Path(path).is_dir() for path in roots), "referenced history snapshot disappeared before GC")
        code, stdout, stderr = self.command("gc-retained-history", ["plugin", "gc"])
        require(code == 0 and "Garbage-collected 0 plugin generations." in stdout,
                "GC unexpectedly reclaimed a referenced generation: " + stdout + stderr)
        require(all(Path(path).is_dir() for path in roots), "GC deleted history-referenced package data")
        require(self.lock_records() == retired, "GC rewrote immutable generation references")
        code, stdout, stderr = self.command("doctor-after-lifecycle", ["plugin", "doctor"])
        require(code == 0 and "No plugin issues detected." in stdout, "doctor reports broken lifecycle state: " + stderr + stdout)
        write_json(self.evidence / "lifecycle-retention.json", {
            "active_after_uninstall": [], "history_records": retired, "retained_roots": roots,
            "gc_removed": 0, "reason": "ProductPluginRuntime.garbageCollect retains roots referenced by records or history; uninstall moves current generation into history.",
            "no_history_pruning_api_used": True, "doctor_exit_code": code})
        self.mark("uninstall withdraws contribution; GC preserves referenced history; doctor is clean", "lifecycle-retention.json")

    def prove_http(self, before, label):
        with self.db() as database:
            rows = [dict(row) for row in database.execute(
                "SELECT o.id,o.run_id,o.tool_call_item_id,o.state,e.tool_id,e.normalized_plan,"
                "r.id receipt_id,r.outcome,r.detail,r.verification,i.payload,i.provenance "
                "FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id "
                "LEFT JOIN operation_receipts r ON r.operation_id=o.id JOIN items i ON i.id=o.tool_call_item_id")
                if row["id"] not in before]
            require(len(rows) == 2, label + " must add exactly one root and one HTTP child")
            require({row["tool_id"] for row in rows} == {TOOL, HIDDEN}, "unexpected operation tool identities")
            root = next(row for row in rows if row["tool_id"] == TOOL)
            child = next(row for row in rows if row["tool_id"] == HIDDEN)
            for row in rows:
                for field in ("normalized_plan", "detail", "verification", "payload", "provenance"):
                    row[field] = stored_value(row[field])
            require(root["run_id"] == child["run_id"], "HTTP child escaped its root Run")
            require(root["receipt_id"] and child["receipt_id"], "missing durable Receipt")
            require(child["outcome"] == "completed", "actual HTTP exchange must have completed Receipt")
            require(root["provenance"] == {"source": "direct_tool", "run_id": root["run_id"],
                                           "operation_id": root["id"]}, "root is not sealed canonical Direct")
            require(root["tool_call_item_id"] == child["tool_call_item_id"], "child lost original ToolCall item")
            require(database.execute("SELECT count(*) FROM canonical_decision_items WHERE item_id=?",
                                     (root["tool_call_item_id"],)).fetchone()[0] == 0,
                    "CLI Direct operation must not claim a model Decision")
            require(database.execute("SELECT count(*) FROM model_decisions").fetchone()[0] == 0,
                    "model-free CLI created model Decisions")
            admission = database.execute("SELECT * FROM derived_operation_admissions WHERE operation_id=?",
                                         (child["id"],)).fetchone()
            require(admission is not None and admission["parent_operation_id"] == root["id"],
                    "missing actual derived admission")
            require(admission["request_key"] == "javascript-service:" + root["payload"]["call_id"] + ":search",
                    "HTTP intent was not atomically bound to canonical parent call and intent id")
            proofs = [stored_value(row[0]) for row in database.execute(
                "SELECT payload FROM audit_events WHERE operation_id=? AND kind='operation_parent_intent_authorized'",
                (child["id"],))]
            require(len(proofs) == 1, "missing or duplicated ParentIntent authorization")
            proof = proofs[0]
            require(proof["authorization_source"] == "parent_intent" and proof["root_source"] == "direct" and
                    proof["parent_operation_id"] == root["id"] and proof["child_operation_id"] == child["id"] and
                    proof["parent_plan_digest"] == root["normalized_plan"]["digest"] and
                    proof["child_plan_digest"] == child["normalized_plan"]["digest"],
                    "ParentIntent audit does not bind immutable root and child plans")
            require(database.execute("SELECT count(*) FROM approvals WHERE operation_id=?",
                                     (child["id"],)).fetchone()[0] == 0, "child forged a User approval")
            for operation in (root, child):
                require(database.execute("SELECT count(*) FROM audit_events WHERE operation_id=? "
                                         "AND kind='operation_execution_handoff'", (operation["id"],)).fetchone()[0] == 1,
                        "actual executor handoff absent or duplicated")
            run = dict(database.execute("SELECT id,state,epoch FROM runs WHERE id=?", (root["run_id"],)).fetchone())
            if label in ("success", "rollback"):
                require(root["outcome"] == "completed" and run["state"] == "completed", "successful root did not complete")
            write_json(self.evidence / (label + "-durable-proof.json"),
                       {"operations": rows, "admission": dict(admission), "authorization": proof, "run": run})

    def run(self):
        for args in (["--help"], ["tools"], ["tools", "--help"], ["plugin"], ["plugin", "--help"]):
            code, stdout, _ = self.command("static-help", args, static=True)
            require(code == 0 and ("tools" in stdout or "plugin" in stdout), "static help failed")
            require(not self.settings.exists(), "static help created settings/state")
            require(list(self.workspace.iterdir()) == [], "static help changed workspace")
        self.mark("static help does not initialize settings or state")
        for alias in ("search", "q"):
            code, stdout, stderr = self.command("retired-" + alias, [alias, "--help"], static=True)
            require(code == 2 and "cli.command_moved" in stdout + stderr and "tools" in stdout + stderr,
                    "retired command did not return explicit generic migration diagnostic")
            require(not self.settings.exists(), "retired command initialized product state")
        self.mark("retired search and q fail explicitly without state")
        code, stdout, _ = self.command("uninstalled-list", ["tools", "list"])
        require(code == 0 and TOOL not in {item["name"] for item in json.loads(stdout)}, "uninstalled tool leaked")
        code, stdout, stderr = self.command("uninstalled-inspect", ["tools", "inspect", TOOL])
        require(code != 0 and "tool.unavailable" in stdout + stderr, "uninstalled inspect must report unavailable")
        code, stdout, stderr = self.command("uninstalled-invoke", ["tools", "invoke", TOOL, '{"query":"unavailable"}'])
        require(code != 0 and "tool.not_found" in stdout + stderr, "uninstalled invoke must report missing tool")
        self.mark("uninstalled native tool is unavailable")
        code, stdout, stderr = self.command("package-inspect", ["plugin", "inspect", str(self.args.web_package), "--json"])
        require(code == 0, "package inspect failed: " + stderr + stdout)
        package_info = json.loads(stdout)
        require(package_info["namespace"] == NAMESPACE and package_info["entry_kind"] == "native-executable",
                "inspect did not describe actual native package")
        code, stdout, stderr = self.command("import", ["plugin", "import", str(self.args.web_package), "--scope", "workspace"])
        require(code == 0 and "import " + NAMESPACE + "@" in stdout, "real import failed: " + stderr + stdout)
        code, stdout, stderr = self.command("installed-list", ["plugin", "list", "--json"])
        require(code == 0, "plugin list failed: " + stderr)
        listed_records = [row for row in json.loads(stdout) if row["namespace"] == NAMESPACE]
        require(len(listed_records) == 1 and listed_records[0]["enabled"] is False and
                listed_records[0]["scope"] == "workspace", "CLI did not list one real disabled workspace import")
        lock_path = self.workspace / ".axyndra/plugins/lock.jsonl"
        records = [json.loads(line) for line in lock_path.read_text().splitlines() if line.strip()]
        records = [row for row in records if row.get("namespace") == NAMESPACE and not row.get("history_for")]
        require(len(records) == 1 and records[0]["enabled"] is False, "import did not create one disabled real record")
        digest = records[0]["content_digest"]
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is not None, "package digest lost canonical algorithm tag")
        require(listed_records[0]["content_digest"] == digest, "CLI list differs from actual installation lock")
        write_json(self.evidence / "imported-record.json", records[0])
        configuration = {"version": 1, "plugins": [{"namespace": NAMESPACE, "package_digest": digest,
            "configuration": {"searxng_url": self.origin.base},
            "requests": [{"url": self.origin.base + "/search", "methods": ["GET"],
                          "private_addresses": ["127.0.0.1"], "credential_refs": []}], "credentials": []}]}
        path = self.settings / "plugins/services.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(path, configuration)
        write_json(self.evidence / "operator-services.json", configuration)
        for bad_args in (["plugin", "enable", NAMESPACE, "--scope", "invalid"],
                         ["plugin", "enable", NAMESPACE, "--unknown"],
                         ["plugin", "enable", NAMESPACE, "--scope", "workspace", "--scope", "user"],
                         ["plugin", "list", "--unknown"]):
            code, stdout, stderr = self.command("invalid-maintenance-option", bad_args)
            require(code == 2 and "plugin.cli_usage" in stdout + stderr, "invalid CLI option was not strictly rejected")
        code, stdout, stderr = self.command("remote-acquisition", ["plugin", "import", "npm", "fixture-plugin", "1.0.0"])
        require(code == 3 and "plugin.cli_interactive_required" in stdout + stderr,
                "noninteractive remote request silently inherited interactive approval")
        self.mark("strict maintenance options and remote interactive approval boundary")
        code, stdout, stderr = self.command("enable", ["plugin", "enable", NAMESPACE, "--scope", "workspace"])
        require(code == 0 and "enabled" in stdout, "real enable failed: " + stderr + stdout)
        require(self.origin.count() == 0, "import/enable caused an unapproved network request")
        self.mark("real CLI import and enable with explicit exact-origin operator grant")
        code, stdout, stderr = self.command("commands", ["plugin", "commands", "--json"])
        require(code == 0, "contribution command listing failed: " + stderr)
        routes = json.loads(stdout)
        route = "plugin." + NAMESPACE + ".help"
        require(any(row["route"] == route and row["description"] for row in routes), "native help route absent")
        code, stdout, stderr = self.command("contribution-help", ["plugin", "command", route, "--help"])
        require(code == 0 and "JSON INPUT" in stdout and TOOL in stdout and "searxng" in stdout,
                "real native help contribution did not render through command observer: " + stderr)
        code, stdout, stderr = self.command("contribution-search-denied", ["plugin", "command", route, "search query"])
        require(code != 0 and "web_search.command_invalid" in stdout + stderr and self.origin.count() == 0,
                "contribution command acquired search/network authority")
        self.mark("actual native offline help uses generic command route with zero HTTP")
        code, stdout, stderr = self.command("installed-inspect", ["tools", "inspect", TOOL])
        require(code == 0, "installed inspect failed: " + stderr)
        descriptor = json.loads(stdout)
        require(descriptor["name"] == TOOL and set(descriptor["parameters"]["properties"]) == SEVEN_PARAMETERS,
                "native schema does not expose the seven actual business fields")
        require(descriptor["parameters"]["required"] == ["query"] and
                descriptor["parameters"]["additionalProperties"] is False, "native schema validation changed")
        self.mark("inspect exposes the real seven-field native schema")
        arguments = json.dumps({"query": "tools CLI actual gateway proof", "provider": "searxng"})
        before = self.operation_ids()
        invalid_arguments = ["{", "[]", "null", '[' * 40 + '0' + ']' * 40,
                             json.dumps({"query": "x" * 66000})]
        for bad in invalid_arguments:
            code, stdout, stderr = self.command("invalid-json", ["tools", "invoke", TOOL, bad], approval="trusted")
            require(code == 2, "invalid/beyond-limit tool JSON did not reject as usage error")
        for bad_args in (["tools", "list", "--unknown"], ["tools", "inspect"],
                         ["tools", "invoke", TOOL], ["tools", "invoke", TOOL, arguments, "extra"],
                         ["plugin", "command", "plugin." + NAMESPACE + ".help", "one", "two"]):
            code, stdout, stderr = self.command("malformed-cli", bad_args, approval="trusted")
            require(code == 2, "malformed CLI argument shape was accepted")
        require(before == self.operation_ids() and self.origin.count() == 0, "invalid input admitted or executed an operation")
        self.mark("invalid JSON, size/depth limits and malformed CLI reject without operation or HTTP")
        code, stdout, stderr = self.command("manual-invoke", ["tools", "invoke", TOOL, arguments])
        require(code != 0 and "cli.tool_approval_required" in stdout + stderr, "AlwaysAsk did not require approval")
        require(self.origin.count() == 0, "AlwaysAsk sent HTTP before approval")
        with self.db() as database:
            require(database.execute("SELECT count(*) FROM operation_effect_records WHERE tool_id=?", (HIDDEN,)).fetchone()[0] == 0,
                    "AlwaysAsk admitted a child before parent authorization")
        self.mark("AlwaysAsk requires approval and performs zero HTTP or child admission")
        before = self.operation_ids()
        code, stdout, stderr = self.command("trusted-invoke", ["tools", "invoke", TOOL, arguments], approval="trusted")
        require(code == 0, "trusted actual invocation failed: " + stderr + stdout)
        result = json.loads(stdout)
        require(result["provider"] == "searxng" and "real tools CLI gateway result" in result["content"] and
                "https://example.test/cli-result" in result["content"], "native business result not preserved")
        require(self.origin.count() == 1, "trusted invocation did not send exactly one HTTP request")
        request = self.origin.requests[0]
        require(request["method"] == "GET" and request["path"] == "/search" and
                request["query"]["q"] == ["tools CLI actual gateway proof"], "actual origin request differs from user query")
        self.prove_http(before, "success")
        self.mark("trusted Searx call uses gateway and persists Direct parent plus HTTP child Receipt", "success-durable-proof.json")
        self.origin.mode = "http-error"
        before = self.operation_ids()
        code, stdout, stderr = self.command("provider-http-error", ["tools", "invoke", TOOL, arguments], approval="trusted")
        require(code != 0, "business HTTP error incorrectly exited successfully")
        require("503" in stdout + stderr, "business HTTP status was not reported")
        require(self.origin.count() == 2, "HTTP error case did not reach the real origin exactly once")
        self.prove_http(before, "http-error")
        self.mark("native business HTTP error returns nonzero while HTTP exchange has durable Receipt", "http-error-durable-proof.json")
        code, stdout, _ = self.command("hidden-list", ["tools", "list"])
        require(code == 0 and HIDDEN not in {item["name"] for item in json.loads(stdout)}, "hidden service leaked in catalog")
        code, stdout, stderr = self.command("hidden-inspect", ["tools", "inspect", HIDDEN])
        require(code != 0 and "tool.unavailable" in stdout + stderr, "hidden service exposed to inspect")
        before = self.operation_ids()
        code, stdout, stderr = self.command("hidden-invoke", ["tools", "invoke", HIDDEN, "{}"], approval="trusted")
        require(code != 0 and "tool.not_found" in stdout + stderr, "trusted raw name bypassed hidden host service")
        require(self.operation_ids() == before and self.origin.count() == 2, "hidden raw invocation admitted or executed HTTP")
        self.mark("hidden HTTP service cannot be listed, inspected, or directly invoked")
        self.lifecycle(arguments, digest)

    def finish(self, error=None):
        self.origin.close()
        final_digest = sha256(self.args.app)
        self.metadata["app_sha256_after"] = final_digest
        if final_digest != self.metadata["app_sha256"]:
            error = (error or "") + "\nCandidate binary changed during CLI acceptance."
        write_json(self.evidence / "summary.json", {"status": "PASS" if error is None else "FAIL",
            "exit_code": 0 if error is None else 1, "started_unix": self.started,
            "elapsed_seconds": time.time() - self.started, "metadata": self.metadata,
            "passed_checks": len(self.steps), "checks": self.steps, "commands": self.commands,
            "error": error, "fixture_preserved": True,
            "limitations": ["Loopback Searx fixture; not public internet or provider production availability.",
                            "Local installation and tools calls use real CLI entry points; no --fixture mode is used.",
                            "No model credentials or fake registration; read-only SQLite queries inspect canonical results.",
                            "No SDK/dependency isolation claim; app and package are prebuilt artifacts."]})
        return 0 if error is None else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", "--app", dest="app", type=Path, required=True)
    parser.add_argument("--package", "--web-package", dest="web_package", type=Path, required=True)
    parser.add_argument("--updated-package", "--updated-web-package", dest="updated_web_package", type=Path, required=True,
                        help="Genuinely compiled same-namespace 1.0.1 endpoint; a manifest-only bump is rejected")
    parser.add_argument("--output-dir", "--evidence", dest="evidence", type=Path, required=True,
                        help="New output directory; existing directories are rejected")
    parser.add_argument("--temp-parent", type=Path, default=Path(os.environ.get("TMPDIR", "/tmp")))
    parser.add_argument("--timeout", type=float, default=180, help="Per app invocation wall deadline")
    args = parser.parse_args()
    args.app = args.app.resolve(strict=True)
    args.web_package = args.web_package.resolve(strict=True)
    args.updated_web_package = args.updated_web_package.resolve(strict=True)
    updated_manifest = json.loads((args.updated_web_package / "axyndra.plugin.json").read_text())
    require(updated_manifest["id"] == "web-search" and updated_manifest["version"] == "1.0.1",
            "updated fixture must be the actual web-search 1.0.1 package")
    require(sha256(args.updated_web_package / "bin/web-search-plugin") != sha256(args.web_package / "bin/web-search-plugin"),
            "updated fixture reuses the original binary instead of compiling its new version contract")
    suite = Acceptance(args)
    try:
        with termination_signals():
            suite.run()
    except Exception:
        error = traceback.format_exc()
        print(error, flush=True)
        suite.finish(error)
        return 1
    if suite.finish() != 0:
        print("Candidate binary changed during CLI acceptance.", flush=True)
        return 1
    print("tools CLI native web black-box contract passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Black-box shared Minimal host contracts; use actual prebuilt binaries.

No compiler, model mock, fabricated admission or database writes occur here.
The native input is the repository fixture built by native_plugin_fixture/build.sh
--tool. Linux is required for the actual protected host and /proc observation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import threading
import time


def stored_value(source):
    """Read the documented Store framing as data; never create Store facts."""
    raw = source.encode("utf-8")
    offset = 0

    def frame():
        nonlocal offset
        end = raw.index(b":", offset)
        size = int(raw[offset:end])
        assert 0 <= size <= 67108864
        offset = end + 1
        value = raw[offset:offset + size]
        assert len(value) == size
        offset += size
        return value.decode("utf-8")

    def value(depth=0):
        nonlocal offset
        assert depth <= 64 and offset < len(raw)
        tag = raw[offset:offset + 1]
        offset += 1
        if tag == b"n":
            return None
        if tag == b"t":
            return True
        if tag == b"f":
            return False
        if tag == b"s":
            return frame()
        if tag == b"d":
            return json.loads(frame())
        count = int(frame())
        assert 0 <= count <= 1000000
        if tag == b"l":
            return [value(depth + 1) for _ in range(count)]
        assert tag == b"o"
        result = {}
        for _ in range(count):
            key = frame()
            assert key not in result
            result[key] = value(depth + 1)
        return result

    result = value()
    assert offset == len(raw)
    return result


def process_table():
    result = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            stat = (entry / "stat").read_text()
            tail = stat[stat.rindex(")") + 2:].split()
            result[int(entry.name)] = (int(tail[1]), tail[19], tail[0])
        except (OSError, ValueError, IndexError):
            pass
    return result


class Cli:
    def __init__(self, binary, root):
        self.binary = str(binary)
        self.settings = root / "settings"
        self.workspace = root / "workspace"
        self.state = root / "state"
        self.workspace.mkdir()
        self.base = ["--settings-root", str(self.settings), "--workspace-root", str(self.workspace)]
        self.observed = 0

    def call(self, *arguments, runtime=False, grants=(), approval=None, limits=(), code=0):
        argv = [self.binary, *self.base]
        if runtime:
            argv += ["--state-root", str(self.state)]
        for grant in grants:
            argv += ["--grant", grant]
        if approval:
            argv += ["--approval-mode", approval]
        argv += [*limits, *arguments]
        child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, start_new_session=True)
        stop = threading.Event()
        observed = {}

        def watch():
            while not stop.is_set():
                table = process_table()
                owned = {child.pid}
                changed = True
                while changed:
                    changed = False
                    for pid, (parent, birth, state) in table.items():
                        if parent in owned and pid not in owned:
                            owned.add(pid)
                            observed[pid] = birth
                            changed = True
                stop.wait(0.01)

        watcher = threading.Thread(target=watch)
        watcher.start()
        try:
            stdout, stderr = child.communicate(timeout=180)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate()
            raise
        finally:
            stop.set()
            watcher.join(timeout=2)
            assert not watcher.is_alive(), "owned observer did not stop"
        deadline = time.monotonic() + 5
        while True:
            current = process_table()
            live = [pid for pid, birth in observed.items()
                    if pid in current and current[pid][1] == birth and current[pid][2] != "Z"]
            if not live or time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        assert not live, ("observed owned descendants survived Minimal close", live)
        self.observed += len(observed)
        assert child.returncode == code, (argv, child.returncode, stdout, stderr)
        lines = [line for line in stdout.splitlines() if line.strip()]
        assert len(lines) == 1, ("expected one bounded CLI JSON result", stdout, stderr)
        return json.loads(lines[0])

    def rows(self, query, arguments=()):
        database = self.state / "state.db"
        with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True) as connection:
            connection.execute("PRAGMA query_only=ON")
            return connection.execute(query, arguments).fetchall()

    def run(self, run):
        rows = self.rows("SELECT thread_id,state,epoch,lane_snapshot,usage,budget FROM runs WHERE id=?", (run,))
        assert len(rows) == 1
        return rows[0]

    def assert_no_model(self):
        for table in ["model_attempts", "model_decisions", "decision_operations"]:
            assert self.rows("SELECT COUNT(*) FROM " + table) == [(0,)], table


def package(root, name, native=None):
    root.mkdir()
    if native:
        shutil.copyfile(native, root / "native-plugin-tool")
        (root / "native-plugin-tool").chmod(0o755)
        descriptor = dict(id=name, version="1.0.0", entrypoint="native-plugin-tool",
                          entry_kind="native-executable", sdk_range="[2.0.0,3.0.0)",
                          protocol_range="axyndra-js-host-v2", capabilities=["workspace.read"],
                          contributions=[dict(kind="tool", name="echo")])
        (root / "axyndra.plugin.json").write_text(json.dumps(descriptor))
    else:
        descriptor = dict(name=name, version="1.0.0", pi=dict(extensions=["echo.js"]))
        (root / "package.json").write_text(json.dumps(descriptor))
        (root / "echo.js").write_text("""import { Type } from 'typebox';
export default function (pi) {
  pi.registerTool({name:'echo', label:'Echo', description:'Minimal actual JS fixture',
    parameters:Type.Object({text:Type.String()}),
    execute:async (_id, params) => ({content:[{type:'text', text:params.text}],
      details:{runtime:'javascript', echoed:params.text}})});
}
""")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--native-tool", type=Path, required=True)
    parser.add_argument("--work-root", type=Path, required=True)
    args = parser.parse_args()
    assert os.name == "posix" and Path("/proc").is_dir(), "requires actual Linux protected host"
    binary, native = args.binary.resolve(), args.native_tool.resolve()
    assert binary.is_file() and native.is_file() and os.access(binary, os.X_OK) and os.access(native, os.X_OK)
    root = args.work_root.resolve()
    assert not root.exists(), "contract needs a new isolated work directory"
    root.mkdir(parents=True)
    cli = Cli(binary, root)
    completed = []

    empty = cli.call("tools", "empty-thread", runtime=True)
    assert empty["ok"] and empty["tools"] == []
    completed.append("empty-host-actual-thread-no-business-tools")

    unknown = cli.call("invoke", "unknown-thread", "missing.tool", "{}", runtime=True, code=2)
    assert not unknown["ok"] and unknown["run_id"]
    assert cli.run(unknown["run_id"])[1] == "failed"
    assert cli.rows("SELECT kind FROM items WHERE turn_id=(SELECT turn_id FROM runs WHERE id=?)", (unknown["run_id"],)) == [("user_message",)]
    assert cli.rows("SELECT COUNT(*) FROM operations WHERE run_id=?", (unknown["run_id"],)) == [(0,)]
    cli.assert_no_model()
    completed.append("unknown-root-original-failed-run-without-fabricated-admission")

    records = []
    for name, artifact in [("minimal-native-contract", native), ("minimal-javascript-contract", None)]:
        source = root / name
        package(source, name, artifact)
        record = cli.call("plugin", "install", str(source), "workspace")["record"]
        assert not record["enabled"] and record["content_digest"]
        records.append(record)
    assert cli.call("tools", "disabled-thread", runtime=True)["tools"] == []
    for record in records:
        enabled = cli.call("plugin", "enable", record["id"], "workspace")["record"]
        assert enabled["enabled"] and enabled["content_digest"] == record["content_digest"]
    tools = cli.call("tools", "actual-thread", runtime=True)["tools"]
    assert len(tools) == 2 and all(not tool["available"] for tool in tools)
    native_name, js_name = ["plugin." + record["namespace"] + ".echo" for record in records]
    assert {tool["name"] for tool in tools} == {native_name, js_name}
    granted = dict(runtime=True, grants=("extension.invoke", "workspace.read"), approval="yolo")
    assert all(tool["available"] for tool in cli.call("tools", "actual-thread", **granted)["tools"])
    completed.append("verified-disabled-install-actual-native-js-mount-explicit-grants")

    first = cli.call("invoke", "actual-thread", native_name, "{}", **granted)
    assert first["ok"] and first["output"]["runtime"] == "native" and first["receipt_id"]
    prior = cli.run(first["run_id"])
    lane = stored_value(prior[3])
    assert prior[0:2] == ("actual-thread", "completed") and lane["tool_set_thread_id"] == "actual-thread"
    entry = next(tool for tool in lane["tools"] if tool["name"] == native_name)
    assert entry["available_at_snapshot"] and entry["executor_version"].startswith("native-adapter-v1:1.0.0:")
    assert len(entry["executor_version"]) > len("native-adapter-v1:1.0.0:")
    actual_plan = stored_value(cli.rows("SELECT normalized_plan FROM operations WHERE run_id=?", (first["run_id"],))[0][0])
    assert actual_plan["tool_version"] == entry["executor_version"]
    assert entry["implementation_fingerprint"] == records[0]["namespace"] + ":" + records[0]["content_digest"]
    receipts = cli.rows("SELECT receipt.id,receipt.outcome FROM operation_receipts receipt JOIN operations op ON op.id=receipt.operation_id WHERE op.run_id=?", (first["run_id"],))
    assert receipts == [(first["receipt_id"], "completed")]
    assert sorted(row[0] for row in cli.rows("SELECT kind FROM items WHERE turn_id=(SELECT turn_id FROM runs WHERE id=?)", (first["run_id"],))) == ["tool_call", "tool_result", "user_message"]
    completed.append("native-actual-root-frozen-instance-snapshot-receipt-items")

    second = cli.call("invoke", "actual-thread", js_name, json.dumps(dict(text="MINIMAL_JS_SENTINEL")), **granted)
    assert second["ok"] and "MINIMAL_JS_SENTINEL" in json.dumps(second["output"]) and second["receipt_id"]
    assert second["run_id"] != first["run_id"] and cli.run(second["run_id"])[2] > prior[2]
    assert cli.run(first["run_id"]) == prior
    history_before = cli.rows("SELECT * FROM runs ORDER BY id")
    latest = cli.call("history", "latest", str(cli.state / "state.db"), "actual-thread")
    assert latest["run_id"] == second["run_id"]
    inspection = cli.call("history", "inspect", str(cli.state / "state.db"), "actual-thread", first["run_id"])
    assert inspection["ok"] and cli.rows("SELECT * FROM runs ORDER BY id") == history_before
    completed.append("javascript-actual-root-cross-process-thread-reopen-readonly-history")

    denied = cli.call("invoke", "denied-thread", native_name, "{}", runtime=True, approval="yolo", code=2)
    assert not denied["ok"] and cli.run(denied["run_id"])[1] == "failed"
    assert cli.rows("SELECT COUNT(*) FROM operations WHERE run_id=?", (denied["run_id"],)) == [(0,)]
    completed.append("explicit-yolo-does-not-grant-missing-capability")

    (cli.workspace / "input.txt").write_text("MINIMAL_WORKER_SENTINEL\n")
    process = dict(executable="native-plugin-tool", arguments=["--worker-read", str(cli.workspace / "input.txt")], timeout_ms=1000)
    worker = cli.call("invoke", "worker-thread", native_name, json.dumps(dict(mode="process_readonly", process=process)),
                      limits=("--max-tool-calls", "2"), **granted)
    service = worker["output"]["service_result"]
    assert set(service) == {"request_id", "service", "call_id", "receipt_id", "output", "is_error"}
    assert service["request_id"] == "native-service-1" and service["service"] == "process.readonly"
    assert worker["ok"] and not service["is_error"] and service["output"]["stdout"] == "MINIMAL_WORKER_SENTINEL\n"
    rows = cli.rows("SELECT child.id,child.normalized_plan,receipt.outcome,child.tool_call_item_id,parent.tool_call_item_id,receipt.id FROM derived_operation_admissions admission JOIN operations child ON child.id=admission.operation_id JOIN operations parent ON parent.id=admission.parent_operation_id JOIN operation_receipts receipt ON receipt.operation_id=child.id WHERE child.run_id=?", (worker["run_id"],))
    assert len(rows) == 1 and rows[0][2] == "completed" and rows[0][3] == rows[0][4]
    assert service["receipt_id"] == rows[0][5] and service["call_id"]
    plan = stored_value(rows[0][1])
    assert plan["tool"] == "host.process.readonly" and plan["effect"] == "read_only" and plan["network"]["mode"] == "denied"
    assert plan["cwd"] == str(cli.workspace) and plan["environment"] == {}
    budget = stored_value(cli.run(worker["run_id"])[5])
    assert budget["max_tool_calls"] == 2 and budget["max_concurrent_tools"] == 1
    assert cli.rows("SELECT COUNT(*) FROM operations WHERE run_id=?", (worker["run_id"],)) == [(2,)]
    completed.append("actual-package-readonly-worker-same-parent-budget-source-receipt")

    process = dict(executable="native-plugin-tool", arguments=["--worker-wait"], timeout_ms=50)
    failed = cli.call("invoke", "failed-thread", native_name, json.dumps(dict(mode="process_readonly", process=process)),
                      limits=("--max-tool-calls", "2"), **granted)
    failure = failed["output"]["service_result"]
    assert set(failure) == {"request_id", "service", "call_id", "receipt_id", "output", "is_error"}
    assert failure["request_id"] == "native-service-1" and failure["service"] == "process.readonly"
    assert failed["ok"] and not failed["is_error"] and failure["is_error"]
    assert failure["output"]["timed_out"] and failure["output"]["exit_code"] == 124
    assert cli.run(failed["run_id"])[1] == "failed"
    outcomes = cli.rows("SELECT receipt.id,receipt.outcome,CASE WHEN admission.operation_id IS NULL THEN 0 ELSE 1 END FROM operations op JOIN operation_receipts receipt ON receipt.operation_id=op.id LEFT JOIN derived_operation_admissions admission ON admission.operation_id=op.id WHERE op.run_id=? ORDER BY CASE WHEN admission.operation_id IS NULL THEN 0 ELSE 1 END", (failed["run_id"],))
    assert outcomes == [(failed["receipt_id"], "completed", 0), (failure["receipt_id"], "failed", 1)]
    details = cli.rows("SELECT receipt.detail FROM operation_receipts receipt JOIN operations op ON op.id=receipt.operation_id WHERE op.run_id=? AND receipt.id=?", (failed["run_id"], failure["receipt_id"]))
    assert len(details) == 1
    detail = stored_value(details[0][0])
    assert detail["is_error"] and detail["output"] == failure["output"] and detail["call_id"] == failure["call_id"]
    assert cli.rows("SELECT COUNT(*) FROM operations WHERE run_id=? AND state IN ('prepared','executing','unknown','recovery_required')", (failed["run_id"],)) == [(0,)]
    assert sorted(row[0] for row in cli.rows("SELECT kind FROM items WHERE turn_id=(SELECT turn_id FROM runs WHERE id=?)", (failed["run_id"],))) == ["tool_call", "tool_result", "user_message"]
    completed.append("known-admitted-worker-timeout-failed-run-canonical-result-cleanup")

    absent = cli.call("infer", "model-thread", "absent-provider", "absent-contribution", runtime=True, code=2)
    assert absent["code"] == "model.provider_plugin_missing"
    cli.assert_no_model()
    assert cli.rows("SELECT COUNT(*) FROM runs WHERE thread_id='model-thread'") == [(0,)]
    completed.append("genuine-missing-model-dependency-without-fake-attempt-decision")

    other = root / "other-workspace"
    other.mkdir()
    saved_base = cli.base
    cli.base = ["--settings-root", str(cli.settings), "--workspace-root", str(other)]
    mismatch = cli.call("tools", "actual-thread", runtime=True, code=2)
    assert mismatch["code"] == "minimal.thread_workspace_mismatch" and cli.run(first["run_id"]) == prior
    cli.base = saved_base
    completed.append("same-thread-reopen-rejects-different-canonical-workspace")

    assert cli.observed > 0, "no actual protected child observed"
    report = dict(status="PASS", cases=completed, observed_owned_descendants=cli.observed,
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  native_fixture_sha256=hashlib.sha256(native.read_bytes()).hexdigest(),
                  scope="Actual Minimal CLI/runtime/native and JS tool assembly only; no model inference or lifecycle-service grant assertion")
    (root / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()

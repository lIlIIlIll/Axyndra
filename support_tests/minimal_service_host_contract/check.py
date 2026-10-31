#!/usr/bin/env python3
"""Actual Minimal lifecycle Client and powerless Server canonical ingress proof.

Needs fresh real Minimal/native packages and original native tool/MCP peer.
No compiler, mock Model, permission DTO, database write or executor substitute.
"""
import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time

spec = importlib.util.spec_from_file_location("minimal_original_contract",
    Path(__file__).resolve().parents[1] / "minimal_host_contract/check.py")
original = importlib.util.module_from_spec(spec)
spec.loader.exec_module(original)
META = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}}
GRANTS = ("extension.invoke", "process.spawn", "workspace.write", "workspace.read")


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def tree(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


def request(identity, name, arguments):
    return dict(jsonrpc="2.0", id=identity, method="tools/call",
                params={"_meta": META, "name": name, "arguments": arguments})


def wait_until(condition, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(.025)
    raise AssertionError("bounded actual condition did not become true")


class Reader:
    def __init__(self, process):
        self.process = process
        self.frames = queue.Queue()

        def read():
            try:
                for line in process.stdout:
                    assert len(line) <= 65537 and line.endswith(b"\n"), "bounded complete original ingress frame"
                    self.frames.put(json.loads(line))
            except BaseException as error:
                self.frames.put(error)
            finally:
                self.frames.put(EOFError())

        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()

    def send(self, value):
        raw = encoded(value).encode()
        self.process.stdin.write(raw + b"\n")
        self.process.stdin.flush()
        return raw

    def receive(self, timeout=30):
        value = self.frames.get(timeout=timeout)
        if isinstance(value, BaseException):
            raise value
        return value


@contextmanager
def serve(cli, grant, starts=(), approval="yolo", expected=0):
    argv = [cli.binary, *cli.base, "--state-root", str(cli.state), "--approval-mode", approval]
    for value in GRANTS:
        argv += ["--grant", value]
    argv += ["serve", grant]
    if starts:
        argv.append(encoded(list(starts)))
    child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    stop = threading.Event()
    observed = {}

    def watch():
        while not stop.is_set():
            table = original.process_table()
            owned = {child.pid}
            changed = True
            while changed:
                changed = False
                for pid, (parent, birth, state) in table.items():
                    if parent in owned and pid not in owned:
                        owned.add(pid)
                        observed[pid] = birth
                        changed = True
            stop.wait(.01)

    observer = threading.Thread(target=watch)
    observer.start()
    reader = Reader(child)
    try:
        yield child, reader
    finally:
        interrupted = False
        try:
            if child.stdin and not child.stdin.closed:
                child.stdin.close()
            child.wait(timeout=5)
        except (subprocess.TimeoutExpired, BrokenPipeError):
            interrupted = True
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
        finally:
            stop.set()
            observer.join(timeout=2)
            reader.thread.join(timeout=1)
        deadline = time.monotonic() + 5
        while True:
            current = original.process_table()
            live = [pid for pid, birth in observed.items() if pid in current
                    and current[pid][1] == birth and current[pid][2] != "Z"]
            if not live or time.monotonic() >= deadline:
                break
            time.sleep(.02)
        cli.observed += len(observed)
        stderr = child.stderr.read().decode(errors="replace")
        child.stdout.close()
        child.stderr.close()
        assert not observer.is_alive() and not reader.thread.is_alive()
        assert not interrupted and not live, ("actual ingress cleanup lacked acknowledgment", live, stderr)
        assert child.returncode == expected, (argv, child.returncode, stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--client-package", type=Path, required=True)
    parser.add_argument("--server-package", type=Path, required=True)
    parser.add_argument("--native-tool", type=Path, required=True)
    parser.add_argument("--original-mcp-peer", type=Path, required=True)
    parser.add_argument("--work-root", type=Path, required=True)
    args = parser.parse_args()
    assert os.name == "posix" and Path("/proc").is_dir()
    root = args.work_root.resolve()
    assert not root.exists(), "fresh actual Minimal workspace required"
    root.mkdir(parents=True)
    binary = args.binary.resolve()
    assert binary.is_file() and os.access(binary, os.X_OK)
    packages = [args.client_package.resolve(), args.server_package.resolve()]
    package_before = {str(package): tree(package) for package in packages}
    cli = original.Cli(binary, root)
    completed = []

    def mark(name):
        completed.append(name)
        (root / "progress.json").write_text(json.dumps(dict(status="RUNNING", cases=completed), indent=2) + "\n")
        print("PASS " + name, flush=True)

    # Reject authority-looking or unsupported operator action fields before any
    # database/native composition. There is no service-source DTO accepted here.
    bad = cli.call("service", "bad", "missing", "stdio", "session", "approve",
        encoded([dict(action="status", source="host_service")]), runtime=True, code=2)
    assert not bad["ok"] and not (cli.state / "state.db").exists()
    mark("strict-operator-actions-reject-source-before-runtime-creation")

    records = []
    for package in packages:
        record = cli.call("plugin", "install", str(package), "workspace")["record"]
        assert not record["enabled"]
        assert cli.call("plugin", "enable", record["id"], "workspace")["record"]["enabled"]
        records.append(record)
    client, decoder = records
    assert client["namespace"] == "axyndra:mcp-client" and decoder["namespace"] == "axyndra:mcp-server"
    missing = cli.call("service", "missing-grant", client["namespace"], "stdio", "session", "approve", "[]",
                       runtime=True, grants=GRANTS, approval="yolo", code=2)
    assert not missing["ok"] and cli.rows("SELECT COUNT(*) FROM operations") == [(0,)]
    cli.assert_no_model()
    mark("installed-client-declaration-does-not-grant-startup")

    external = root / "external"
    external.mkdir()
    peer = external / "original-peer.py"
    peer.write_bytes(args.original_mcp_peer.resolve().read_bytes())
    assert hashlib.sha256(peer.read_bytes()).digest() == hashlib.sha256(args.original_mcp_peer.read_bytes()).digest()
    transcript = cli.workspace / "actual-mcp-frames.jsonl"
    transcript.write_text("")
    config_path = cli.settings / "plugins/lifecycle.json"
    remote = "remote.echo:雪"

    def local_name(name):
        return "plugin." + client["namespace"] + ".service.stdio.t_" + hashlib.sha256(name.encode()).hexdigest()

    def configure(mode="echo"):
        service = dict(id="stdio", executable="/usr/bin/python3", arguments=["-u", str(peer), mode, str(transcript)],
            read_only_mounts=[str(external)], workspace_mode="workspace_readwrite", network=dict(mode="denied"),
            resources=dict(max_output_bytes=1048576, address_space_bytes=536870912, file_size_bytes=1048576,
                           open_files=64, processes=8, cpu_seconds=10),
            lifetime_ms=120000, max_input_bytes=131072, max_output_bytes=1048576,
            startup=dict(timeout_ms=30000, max_input_bytes=16384, max_output_bytes=65536, max_writes=10),
            refresh=dict(timeout_ms=10000, max_input_bytes=16384, max_output_bytes=65536, max_writes=8),
            environment={}, credential_refs=[])
        document = dict(version=1, plugins=[dict(namespace=client["namespace"], package_digest=client["content_digest"],
            configuration=dict(version=1, transport="stdio", request_timeout_ms=10000,
                               directory=dict(max_pages=8, max_tools=64)), max_instances=2, services=[service])])
        config_path.write_text(encoded(document))

    def frames():
        return [line for line in transcript.read_text().splitlines() if line]

    def run_service(thread, actions, decision="approve", code=0, grants=GRANTS):
        return cli.call("service", thread, client["namespace"], "stdio", "session", decision, encoded(actions),
                        runtime=True, grants=grants, approval="yolo", code=code)

    def maintenance_rows(tool):
        return cli.rows("SELECT r.thread_id,r.id,r.epoch,r.state,i.provenance,receipt.id FROM runs r "
            "JOIN operations op ON op.run_id=r.id JOIN operation_effect_records effect ON effect.operation_id=op.id "
            "JOIN items i ON i.id=op.tool_call_item_id JOIN operation_receipts receipt ON receipt.operation_id=op.id "
            "WHERE effect.tool_id=? ORDER BY r.started_at_millis,r.id", (tool,))

    configure()
    rejected = run_service("denied-start", [], decision="deny", code=2)
    assert not rejected["ok"] and frames() == []
    assert cli.rows("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == [(0,)]
    mark("explicit-rejected-canonical-start-performs-no-backend-io")

    no_capability = run_service("missing-capability", [], code=2, grants=("extension.invoke", "workspace.write"))
    assert not no_capability["ok"] and frames() == []
    mark("explicit-start-approval-still-requires-real-process-capability")

    payload = dict(query="MINIMAL_MCP_SENTINEL 雪 &=+?#/%\n\\\"")
    target = "actual-client-thread"
    direct = run_service(target, [dict(action="tools", thread=target), dict(action="tools", thread="other-thread"),
        dict(action="invoke", thread=target, tool=local_name(remote), arguments=payload), dict(action="status"), dict(action="stop")])
    result = direct["results"]
    assert result[0]["ok"] and result[0]["receipt_id"]
    assert local_name(remote) in {item["name"] for item in result[1]["tools"]}
    assert local_name(remote) not in {item["name"] for item in result[2]["tools"]}
    call = result[3]
    assert call["ok"] and call["output"]["status"] == "complete" and call["receipt_id"]
    physical = frames()[-1]
    assert json.loads(physical)["params"]["arguments"] == payload
    assert call["output"]["result"]["content"][0]["text"] == physical
    assert result[4]["statuses"][0]["state"] == "ready"
    assert result[5]["statuses"][0]["cleanup_acknowledged"]
    startup = [row for row in maintenance_rows("host.plugin.lifecycle.start") if row[3] == "completed"][-1]
    origin = original.stored_value(startup[4])["direct_origin"]
    assert startup[0] != target and origin["kind"] == "host_service" and origin["action"] == "start"
    assert origin["package_digest"] == client["content_digest"] and startup[5] == result[0]["receipt_id"]
    assert cli.rows("SELECT COUNT(*) FROM items WHERE thread_id=? AND kind='user_message'", (startup[0],)) == [(0,)]
    child = cli.rows("SELECT child.normalized_plan,receipt.outcome,receipt.id FROM derived_operation_admissions a "
        "JOIN operations child ON child.id=a.operation_id JOIN operation_receipts receipt ON receipt.operation_id=child.id "
        "WHERE child.run_id=?", (call["run_id"],))
    assert len(child) == 1 and child[0][1] == "completed"
    child_plan = original.stored_value(child[0][0])
    assert bytes.fromhex(child_plan["arguments"]["intent"]["bytes_hex"]).decode() == physical + "\n"
    before_run = cli.run(call["run_id"])
    history = cli.call("history", "inspect", str(cli.state / "state.db"), target, call["run_id"])
    assert history["ok"] and cli.run(call["run_id"]) == before_run
    cli.assert_no_model()
    mark("actual-client-start-hostsource-thread-bound-direct-derived-receipt-history")

    transcript.write_text("")
    configure("refresh-change")
    updated = local_name("remote.updated:雪")
    refreshed = run_service(target, [dict(action="invoke", thread=target, tool=local_name(remote), arguments={}),
        dict(action="refresh", decision="approve"), dict(action="tools", thread=target),
        dict(action="invoke", thread=target, tool=updated, arguments={}), dict(action="stop")])
    replies = refreshed["results"]
    assert replies[2]["ok"] and replies[2]["output"]["schema"] == "axyndra.lifecycle-refresh-result/v1"
    names = {item["name"] for item in replies[3]["tools"]}
    assert updated in names and local_name(remote) not in names
    assert replies[4]["ok"] and cli.run(replies[1]["run_id"])[2] > before_run[2]
    assert cli.run(call["run_id"]) == before_run
    refresh = maintenance_rows("host.plugin.lifecycle.refresh")[-1]
    origin = original.stored_value(refresh[4])["direct_origin"]
    assert origin["action"] == "refresh" and refresh[0] != target and refresh[5] == replies[2]["receipt_id"]
    call_rows = cli.rows("SELECT child.normalized_plan FROM derived_operation_admissions a JOIN operations child ON child.id=a.operation_id "
        "WHERE child.run_id IN (?,?) ORDER BY child.run_id", (replies[1]["run_id"], replies[4]["run_id"]))
    bindings = [original.stored_value(row[0])["arguments"]["binding"] for row in call_rows]
    assert len(bindings) == 2
    for key in ["lease_id", "endpoint_identity", "instance_identity", "launch_digest", "startup_operation_id"]:
        assert bindings[0][key] == bindings[1][key]
    assert sorted(item["directory_revision"] for item in bindings) == [1, 2]
    assert bindings[0]["implementation_fingerprint"] != bindings[1]["implementation_fingerprint"]
    mark("actual-refresh-same-lease-new-maintenance-source-atomic-directory-reopen")

    # A real installed generic native Tool is the Server export. No builtin
    # workspace/Shell/LSP implementation or second catalog is linked into Minimal.
    native_source = root / "native-export"
    original.package(native_source, "minimal-external-export", args.native_tool.resolve())
    exported = cli.call("plugin", "install", str(native_source), "workspace")["record"]
    cli.call("plugin", "enable", exported["id"], "workspace")
    export_name = "plugin." + exported["namespace"] + ".echo"
    ingress_path = cli.settings / "plugins/ingress.json"
    grant = dict(id="minimal-peer", namespace=decoder["namespace"], package_digest=decoder["content_digest"],
        service="decoder", principal="minimal-operator-peer", thread_id="external-thread", exports=[export_name],
        capabilities=list(GRANTS), lifetime_ms=120000)
    configuration = dict(schema="axyndra.stdio-ingress-grants/v1", grants=[grant])
    ingress_path.write_text(encoded(configuration))
    with serve(cli, "minimal-peer") as (process, reader):
        reader.send(dict(jsonrpc="2.0", id="directory", method="tools/list", params={"_meta": META}))
        assert {item["name"] for item in reader.receive()["result"]["tools"]} == {export_name}
        raw = reader.send(request("external-one", export_name, {}))
        response = reader.receive()
        assert response["id"] == "external-one" and "result" in response and not response["result"].get("isError", False)
        origins = [original.stored_value(row[0]).get("direct_origin", {})
                   for row in cli.rows("SELECT provenance FROM items WHERE kind='tool_call'")]
        origin = next(item for item in origins if item.get("kind") == "external"
                      and item["request_id"] == dict(kind="text", value="external-one"))
        assert origin["schema"] == "axyndra.direct-origin/v3" and origin["principal_id"] == "minimal-operator-peer"
        assert origin["frame"]["raw_frame_digest"] == hashlib.sha256(raw).hexdigest()
        assert origin["frame"]["decoder"]["package_digest"] == decoder["content_digest"]
        for identity in [7, "7"]:
            reader.send(request(identity, export_name, {}))
            assert reader.receive()["id"] == identity
    cli.assert_no_model()
    mark("actual-powerless-server-fixed-export-external-v3-rawbytes-typed-identities")

    transcript.write_text("")
    configure()
    configuration["grants"][0].update(thread_id="approval-thread", exports=[local_name(remote)])
    ingress_path.write_text(encoded(configuration))
    starts = [dict(thread="approval-thread", namespace=client["namespace"], service="stdio", route="session", decision="approve")]
    with serve(cli, "minimal-peer", starts=starts, approval="always-ask") as (process, reader):
        reader.send(dict(jsonrpc="2.0", id="approval-directory", method="tools/list", params={"_meta": META}))
        assert reader.receive()["result"]["tools"]
        handoffs = cli.rows("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'")[0][0]
        reader.send(request("unapproved", local_name(remote), {}))
        assert "error" in reader.receive()
        assert cli.rows("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'")[0][0] == handoffs
        assert all(json.loads(line)["method"] != "tools/call" for line in frames())
    mark("server-peer-does-not-approve-or-invent-canonical-handoff")

    configuration["grants"][0].update(thread_id="external-thread", exports=[export_name])
    ingress_path.write_text(encoded(configuration))
    with serve(cli, "minimal-peer", expected=2) as (process, reader):
        reader.send(dict(jsonrpc="2.0", id="pinned", method="tools/list", params={"_meta": META}))
        assert reader.receive()["result"]["tools"]
        configuration["grants"][0]["principal"] = "changed-operator-principal"
        ingress_path.write_text(encoded(configuration))
        # The original monitor revokes the actual pinned connection; there is
        # no attempt to accept another request under latest configuration.
        assert process.wait(timeout=15) != 0
    configuration["grants"][0]["principal"] = "minimal-operator-peer"
    ingress_path.write_text(encoded(configuration))
    mark("current-operator-configuration-change-revokes-actual-fixed-decoder")

    transcript.write_text("")
    configure("hang")
    configuration["grants"][0].update(thread_id="bridge-thread", exports=[local_name(remote)])
    ingress_path.write_text(encoded(configuration))
    starts = [dict(thread="bridge-thread", namespace=client["namespace"], service="stdio", route="session", decision="approve")]
    with serve(cli, "minimal-peer", starts=starts) as (process, reader):
        reader.send(request("active", local_name(remote), {}))
        wait_until(lambda: any(json.loads(line)["method"] == "tools/call" for line in frames()))
        reader.send(request("queued", local_name(remote), {}))
        reader.send(dict(jsonrpc="2.0", method="notifications/cancelled", params=dict(requestId="queued")))
        reader.send(dict(jsonrpc="2.0", method="notifications/cancelled", params=dict(requestId="active")))
        replies = [reader.receive(), reader.receive()]
        assert {item["id"] for item in replies} == {"active", "queued"}
        assert sum(json.loads(line)["method"] == "tools/call" for line in frames()) == 1
        assert cli.rows("SELECT COUNT(*) FROM operations WHERE state='executing'") == [(0,)]
    assert cli.rows("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")[0][0] >= 1
    cli.assert_no_model()
    mark("actual-client-server-bridge-independent-cancel-no-queued-effect-honest-unknown-cleanup")

    assert len(completed) == 10
    assert cli.observed > 0
    assert {str(package): tree(package) for package in packages} == package_before
    report = dict(status="PASS", cases=completed, observed_owned_descendants=cli.observed,
        minimal_binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), package_files=package_before,
        scope="Actual Minimal shared Host lifecycle Client and fixed powerless Server ingress on one DB/Runtime/catalog/native owner. Read-only Store inspection; no Model source fabrication or legacy App acceptance substitution. Owned process claim covers observed PID/start-time descendants only.")
    (root / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Minimal service host contract passed: 10 actual lifecycle/ingress cases")


if __name__ == "__main__":
    main()

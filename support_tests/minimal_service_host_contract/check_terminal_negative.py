#!/usr/bin/env python3
"""Real owned cancellation drain negatives; original whole Service10 stays exact."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import check as contract


def fixture(args, root, target):
    assert not root.exists()
    root.mkdir(parents=True)
    cli = contract.original.Cli(args.binary.resolve(), root)
    packages = [args.client_package.resolve(), args.server_package.resolve()]
    frozen = {str(package): contract.tree(package) for package in packages}
    records = []
    for package in packages:
        record = cli.call("plugin", "install", str(package), "workspace")["record"]
        assert not record["enabled"]
        assert cli.call("plugin", "enable", record["id"], "workspace")["record"]["enabled"]
        records.append(record)
    client, decoder = records
    assert client["namespace"] == "axyndra:mcp-client" and decoder["namespace"] == "axyndra:mcp-server"
    external = root / "external"
    external.mkdir()
    peer = external / "original-peer.py"
    peer.write_bytes(args.original_mcp_peer.read_bytes())
    assert peer.read_bytes() == args.original_mcp_peer.read_bytes()
    transcript = cli.workspace / "actual-mcp-frames.jsonl"
    transcript.write_text("")
    service = dict(id="stdio", executable="/usr/bin/python3", arguments=["-u", str(peer), "hang", str(transcript)],
        read_only_mounts=[str(external)], workspace_mode="workspace_readwrite", network=dict(mode="denied"),
        resources=dict(max_output_bytes=1048576, address_space_bytes=536870912, file_size_bytes=1048576,
                       open_files=64, processes=8, cpu_seconds=10),
        lifetime_ms=120000, max_input_bytes=131072, max_output_bytes=1048576,
        startup=dict(timeout_ms=30000, max_input_bytes=16384, max_output_bytes=65536, max_writes=10),
        refresh=dict(timeout_ms=10000, max_input_bytes=16384, max_output_bytes=65536, max_writes=8),
        environment={}, credential_refs=[])
    lifecycle = dict(version=1, plugins=[dict(namespace=client["namespace"], package_digest=client["content_digest"],
        configuration=dict(version=1, transport="stdio", request_timeout_ms=10000,
                           directory=dict(max_pages=8, max_tools=64)), max_instances=2, services=[service])])
    (cli.settings / "plugins/lifecycle.json").write_text(contract.encoded(lifecycle))
    remote = "plugin." + client["namespace"] + ".service.stdio.t_" + hashlib.sha256("remote.echo:雪".encode()).hexdigest()
    grant = dict(id="minimal-peer", namespace=decoder["namespace"], package_digest=decoder["content_digest"],
        service="decoder", principal="minimal-operator-peer", thread_id=target, exports=[remote],
        capabilities=list(contract.GRANTS), lifetime_ms=120000)
    ingress = dict(schema="axyndra.stdio-ingress-grants/v1", grants=[grant])
    (cli.settings / "plugins/ingress.json").write_text(contract.encoded(ingress))
    starts = [dict(thread=target, namespace=client["namespace"], service="stdio", route="session", decision="approve")]
    return cli, remote, starts, transcript, ingress, frozen, packages


def actual_calls(transcript):
    return [json.loads(line) for line in transcript.read_text().splitlines() if line]


def verify_terminal_cleanup(cli, transcript, frozen, packages):
    assert sum(frame["method"] == "tools/call" for frame in actual_calls(transcript)) == 1
    assert cli.rows("SELECT COUNT(*) FROM operations WHERE state='executing'") == [(0,)]
    assert cli.rows("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")[0][0] >= 1
    origins = [contract.original.stored_value(row[0]).get("direct_origin", {})
               for row in cli.rows("SELECT provenance FROM items WHERE kind='tool_call'")]
    external = [origin for origin in origins if origin.get("kind") == "external"]
    assert external and all(origin["request_id"] != dict(kind="text", value="queued") for origin in external)
    cli.assert_no_model()
    assert {str(package): contract.tree(package) for package in packages} == frozen


def run_negative(args, root, changed_operator):
    target = "pending-config-thread" if changed_operator else "uncancelled-queued-thread"
    cli, remote, starts, transcript, ingress, frozen, packages = fixture(args, root, target)
    with contract.serve(cli, "minimal-peer", starts=starts, expected=2) as (process, reader):
        reader.send(contract.request("active", remote, {}))
        contract.wait_until(lambda: any(frame["method"] == "tools/call" for frame in actual_calls(transcript)))
        reader.send(contract.request("queued", remote, {}))
        if changed_operator:
            reader.send(dict(jsonrpc="2.0", method="notifications/cancelled", params=dict(requestId="queued")))
        # An actual pure directory response proves all preceding input frames
        # were decoded in order while the actual first backend call still hangs.
        reader.send(dict(jsonrpc="2.0", id="parsed-before-cancel", method="tools/list", params={"_meta": contract.META}))
        response = reader.receive()
        assert response["id"] == "parsed-before-cancel" and response["result"]["tools"]
        if changed_operator:
            ingress["grants"][0]["principal"] = "changed-operator-principal"
            (cli.settings / "plugins/ingress.json").write_text(contract.encoded(ingress))
        else:
            reader.send(dict(jsonrpc="2.0", method="notifications/cancelled", params=dict(requestId="active")))
        assert process.wait(timeout=15) == 2
    verify_terminal_cleanup(cli, transcript, frozen, packages)
    return cli.observed


def main():
    parser = argparse.ArgumentParser()
    for name in ["binary", "client-package", "server-package", "original-mcp-peer", "work-root"]:
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    assert os.name == "posix" and Path("/proc").is_dir() and not args.work_root.exists()
    args.work_root.mkdir(parents=True)
    observed = run_negative(args, args.work_root / "uncancelled-queued", False)
    print("PASS uncancelled-queued-withdrawal-cannot-enter-terminal-drain-or-execute", flush=True)
    observed += run_negative(args, args.work_root / "changed-operator", True)
    print("PASS changed-operator-with-owned-pending-cancellation-still-revokes-decoder", flush=True)
    assert observed > 0
    (args.work_root / "summary.json").write_text(json.dumps(dict(status="PASS", additional_cases_completed=2,
        observed_owned_descendants=observed, scope="Real Minimal/native Client/powerless Server, actual canonical External calls, readonly Store inspection and original PID/start-time cleanup; no substitute source or Model."), indent=2) + "\n")
    print("Minimal terminal cancellation negatives passed: 2 actual cases", flush=True)


if __name__ == "__main__":
    main()

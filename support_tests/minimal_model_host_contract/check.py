#!/usr/bin/env python3
"""Actual Minimal -> installed native model -> real HTTP -> durable Core proof.

Requires the fresh actual Minimal binary, actual native package and original
protocol fixture. No build, Model mock, fake gate or database write is done.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

contract_path = Path(__file__).resolve().parents[1] / "minimal_host_contract/check.py"
spec = importlib.util.spec_from_file_location("minimal_original_cli_contract", contract_path)
original = importlib.util.module_from_spec(spec)
spec.loader.exec_module(original)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model-package", type=Path, required=True)
    parser.add_argument("--protocol-fixture", type=Path, required=True)
    parser.add_argument("--ca-bundle", type=Path, required=True)
    parser.add_argument("--work-root", type=Path, required=True)
    args = parser.parse_args()
    assert os.name == "posix" and Path("/proc").is_dir()
    root = args.work_root.resolve()
    assert not root.exists(), "fresh actual runtime workspace required"
    root.mkdir(parents=True)
    binary, package = args.binary.resolve(), args.model_package.resolve()
    assert binary.is_file() and os.access(binary, os.X_OK)
    assert package.is_dir() and (package / "axyndra.plugin.json").is_file()
    assert args.ca_bundle.resolve().is_file() and args.protocol_fixture.resolve().is_file()
    package_before = {p.relative_to(package).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in package.rglob("*") if p.is_file()}
    cli = original.Cli(binary, root)
    completed = []
    absent = cli.call("infer", "missing-thread", "absent-provider", "absent", runtime=True, code=2)
    assert absent["code"] == "model.provider_plugin_missing"
    cli.assert_no_model()
    assert cli.rows("SELECT COUNT(*) FROM runs") == [(0,)]
    completed.append("genuine-missing-contribution-no-fake-model-source")
    record = cli.call("plugin", "install", str(package), "workspace")["record"]
    assert not record["enabled"]
    assert cli.call("plugin", "enable", record["id"], "workspace")["record"]["enabled"]
    needs_input = cli.call("infer", "syntax-thread", record["namespace"], "openai-chat-completions", runtime=True, code=2)
    assert needs_input["code"] == "minimal.model_input_required"
    cli.assert_no_model()
    assert cli.rows("SELECT COUNT(*) FROM runs") == [(0,)]
    completed.append("installed-contribution-requires-real-model-input")

    origin_root = root / "origin"
    origin_root.mkdir()
    secret = "ACTUAL-MINIMAL-MODEL-SECRET/quoted"
    (origin_root / "secret").write_text(secret, encoding="utf8")
    (origin_root / "mode").write_text("success")
    origin = subprocess.Popen([sys.executable, str(Path(__file__).with_name("origin.py")),
        "--root", str(origin_root), "--protocol-fixture", str(args.protocol_fixture.resolve())],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        deadline = time.monotonic() + 5
        while not (origin_root / "ready.json").exists() and origin.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        assert (origin_root / "ready.json").is_file(), "actual HTTP origin failed to start"
        url = "http://127.0.0.1:" + str(json.loads((origin_root / "ready.json").read_text())["port"])
        credential_root = cli.settings / "credentials"
        credential_root.mkdir(exist_ok=True)
        (credential_root / "model-key").write_text(secret, encoding="utf8")
        apis = {"chat": ("openai", "openai_chat", "openai-chat-completions", "/v1/chat/completions"),
                "responses": ("openai", "openai_responses", "openai-responses", "/v1/responses"),
                "messages": ("anthropic", "anthropic_messages", "anthropic-messages", "/v1/messages")}

        def configure(api):
            provider, dialect, contribution, suffix = apis[api]
            policy = dict(context_window=8192, max_output=2048, endpoint_max_output=None,
                thinking=dict(mode="none", levels=[], tiers=[]), tools=True, parallel_tools=True,
                images=False, structured_output=False, prompt_cache=False)
            mapping = dict(version=2, capabilities=policy, model="minimal-model", contribution=contribution,
                wire_model="wire-model", provider_id="operator-neutral", credential_refs=["model-key"],
                configuration=dict(base_url=url, provider=provider, dialect=dialect, headers={},
                                   timeout_ms=10000, allow_insecure_http=True))
            document = dict(version=1, plugins=[dict(namespace=record["namespace"], package_digest=record["content_digest"],
                configuration=dict(model_providers=[mapping]),
                protocol_limits=dict(max_frame_bytes=4194304, max_input_bytes=1048576, max_prepare_bytes=2097152,
                    max_result_bytes=4128768, max_directory_bytes=2097152, max_tools=8192, call_timeout_ms=120000),
                payload_limits=dict(version=1, max_message_bytes=16777216, max_input_bytes=4194304,
                    max_prepare_bytes=8388608, max_result_bytes=8388608, max_write_bytes=4128768),
                requests=[dict(url=url + suffix, methods=["POST"], private_addresses=["127.0.0.1"], credential_refs=["model-key"])],
                credentials=[dict(ref="model-key", source=dict(file="model-key"), injection=dict(header="Authorization", prefix="Bearer "))])])
            source = json.dumps(document, ensure_ascii=False, separators=(",", ":"))
            (cli.settings / "plugins/services.json").write_text(source, encoding="utf8")
            return contribution, hashlib.sha256(source.encode()).hexdigest()

        def observed(): return json.loads((origin_root / "observed.json").read_text())

        def assert_snapshot_configuration(snapshot, contribution, digest):
            # Installed snapshot v1 stores the actual binding digest, not its
            # expanded package/contribution fields. The durable request's
            # capability fingerprint binds the exact services.json SHA, which
            # in turn binds the actual installed package and selected mapping.
            frozen = json.loads(snapshot)
            assert set(frozen) == {"schema", "binding_digest", "request"}
            assert frozen["schema"] == "axyndra.model-input/v1"
            binding = frozen["binding_digest"]
            assert isinstance(binding, str) and len(binding) == 64
            assert all(char in "0123456789abcdef" for char in binding)
            request = frozen["request"]
            assert request["model"] == "minimal-model"
            policy = request["resolved_policy"]
            configuration_bytes = (cli.settings / "plugins/services.json").read_bytes()
            assert hashlib.sha256(configuration_bytes).hexdigest() == digest
            configuration = json.loads(configuration_bytes)
            assert configuration["version"] == 1 and len(configuration["plugins"]) == 1
            selected = configuration["plugins"][0]
            assert selected["namespace"] == record["namespace"]
            assert selected["package_digest"] == record["content_digest"]
            mappings = selected["configuration"]["model_providers"]
            assert len(mappings) == 1
            mapping = mappings[0]
            assert mapping["version"] == 2 and mapping["model"] == request["model"]
            assert mapping["contribution"] == contribution
            assert mapping["wire_model"] == "wire-model" and mapping["provider_id"] == "operator-neutral"
            assert mapping["credential_refs"] == ["model-key"]
            caps = mapping["capabilities"]
            assert caps["thinking"] == dict(mode="none", levels=[], tiers=[])
            assert caps["max_output"] == 2048 and caps["endpoint_max_output"] is None
            expected = ("snapshot_schema_version=1\nmodel_id=13:minimal-model\n"
                "thinking_mode=none\nsupported_levels=\nbudget_tiers=\n"
                "model_max_output_tokens=2048\nendpoint_max_output_tokens=-\n"
                "configuration_digest=" + digest + "\n")
            assert policy["capability_snapshot_version"] == 1
            assert policy["capability_snapshot_payload"] == expected
            assert policy["capability_fingerprint"] == hashlib.sha256(expected.encode("utf8")).hexdigest()

        def assert_canonical_answer(run):
            # Core summary describes the provider stop reason. Actual answer
            # bytes must be in the canonical item linked to this committed
            # Decision and its actual Attempt; staging a response is insufficient.
            rows = cli.rows("SELECT i.payload FROM items i "
                "JOIN canonical_decision_items canonical ON canonical.item_id=i.id "
                "JOIN model_decisions decision ON decision.id=canonical.decision_id "
                "JOIN model_attempts attempt ON attempt.id=decision.attempt_id "
                "WHERE attempt.run_id=? AND i.kind='assistant_message' "
                "AND decision.canonical_committed_at_millis IS NOT NULL", (run,))
            assert len(rows) == 1
            answer = original.stored_value(rows[0][0])
            assert answer == dict(kind="assistant_message", parts=[dict(kind="text", value="answer 雪")])
        limits = ("--ca-bundle", str(args.ca_bundle.resolve()))
        prior_run = None
        for api in apis:
            contribution, digest = configure(api)
            before = len(observed())
            reply = cli.call("infer", "actual-model-thread", record["namespace"], contribution,
                "minimal-model", "Return one short answer.", runtime=True, limits=limits)
            assert reply["ok"] and isinstance(reply["summary"], str) and reply["summary"]
            assert_canonical_answer(reply["run_id"])
            run = reply["run_id"]
            assert cli.run(run)[0:2] == ("actual-model-thread", "completed")
            if prior_run:
                assert cli.run(run)[2] > prior_run[1][2]
                assert cli.run(prior_run[0]) == prior_run[1]
            prior_run = run, cli.run(run)
            attempts = cli.rows("SELECT a.id,a.lifecycle,a.dispatch_state,a.dispatch_started_at_millis,d.canonical_committed_at_millis "
                "FROM model_attempts a JOIN model_decisions d ON d.attempt_id=a.id WHERE a.run_id=?", (run,))
            assert len(attempts) == 1 and attempts[0][1] == "completed" and attempts[0][3] is not None and attempts[0][4] is not None
            assert cli.rows("SELECT COUNT(*) FROM context_manifests WHERE thread_id='actual-model-thread' AND turn_id=(SELECT turn_id FROM runs WHERE id=?)", (run,)) == [(1,)]
            snapshot = cli.rows("SELECT transcript_snapshot FROM model_attempts WHERE run_id=?", (run,))[0][0]
            assert_snapshot_configuration(snapshot, contribution, digest)
            assert cli.rows("SELECT COUNT(*) FROM operations WHERE run_id=?", (run,)) == [(0,)]
            usage = original.stored_value(cli.rows("SELECT u.payload FROM model_decision_usage u JOIN model_decisions d ON d.id=u.decision_id "
                "JOIN model_attempts a ON a.id=d.attempt_id WHERE a.run_id=?", (run,))[0][0])
            assert usage["input_tokens"] == 11 and usage["output_tokens"] == 3 and usage["source"] != "unknown"
            assert len(observed()) == before + 1 and observed()[-1]["authorized"] and observed()[-1]["model"] == "wire-model"
            completed.append("actual-minimal-core-attempt-context-decision-" + api)
        saved = cli.rows("SELECT * FROM runs ORDER BY id")
        inspect = cli.call("history", "inspect", str(cli.state / "state.db"), "actual-model-thread", prior_run[0])
        assert inspect["ok"] and cli.rows("SELECT * FROM runs ORDER BY id") == saved
        completed.append("actual-model-cross-process-epoch-reopen-readonly-history")

        contribution, _ = configure("chat")
        (origin_root / "mode").write_text("unknown_usage")
        unknown = cli.call("infer", "unknown-usage-thread", record["namespace"], contribution,
            "minimal-model", "Complete reply without provider billing.", runtime=True, limits=limits)
        assert unknown["ok"] and isinstance(unknown["summary"], str) and unknown["summary"]
        assert_canonical_answer(unknown["run_id"])
        unknown_usage = original.stored_value(cli.rows("SELECT u.payload FROM model_decision_usage u "
            "JOIN model_decisions d ON d.id=u.decision_id JOIN model_attempts a ON a.id=d.attempt_id "
            "WHERE a.run_id=? AND d.canonical_committed_at_millis IS NOT NULL", (unknown["run_id"],))[0][0])
        assert unknown_usage["source"] == "unknown"
        completed.append("actual-complete-provider-reply-preserves-unknown-usage")
        (origin_root / "mode").write_text("success")
        baseline = len(observed())
        (credential_root / "model-key").write_text("")
        rejected = cli.call("infer", "credential-thread", record["namespace"], contribution,
            "minimal-model", "No credential may grant HTTP.", runtime=True, limits=limits, code=2)
        assert not rejected["ok"] and len(observed()) == baseline
        assert cli.rows("SELECT COUNT(*) FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id WHERE a.run_id=?", (rejected["run_id"],)) == [(0,)]
        (credential_root / "model-key").write_text(secret)
        completed.append("actual-missing-secret-zero-http-no-canonical-decision")

        for mode in ["hang", "crash"]:
            (origin_root / "mode").write_text(mode)
            failed = cli.call("infer", mode + "-thread", record["namespace"], contribution,
                "minimal-model", "Incomplete transport must retain failure.", runtime=True,
                limits=(*limits, "--timeout-ms", "1000"), code=2)
            assert not failed["ok"] and failed["run_id"]
            run = failed["run_id"]
            attempts = cli.rows("SELECT dispatch_started_at_millis,completed_at_millis,lifecycle FROM model_attempts WHERE run_id=?", (run,))
            assert len(attempts) == 1 and attempts[0][0] is not None and attempts[0][1] is not None and attempts[0][2] != "completed"
            assert cli.rows("SELECT COUNT(*) FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id WHERE a.run_id=?", (run,)) == [(0,)]
            events = [json.loads(row[0]) for row in cli.rows("SELECT payload FROM app_run_events WHERE run_id=?", (run,))]
            terminal = [event["detail"] for event in events if event["payload_type"] == "model_request_attempt_completed"]
            assert len(terminal) == 1 and terminal[0]["outcome"] != "succeeded"
            assert terminal[0]["usage"] is None or terminal[0]["usage"]["source"] == "unknown"
            assert cli.rows("SELECT COUNT(*) FROM run_model_usage WHERE run_id=?", (run,)) == [(0,)]
            completed.append("actual-core-deadline-cancellation-unknown-usage-cleanup" if mode == "hang" else "actual-http-partial-crash-no-decision-unknown-usage")
        for query in ["SELECT payload FROM items", "SELECT payload FROM audit_events", "SELECT transcript_snapshot FROM model_attempts WHERE transcript_snapshot IS NOT NULL"]:
            assert all(secret not in row[0] for row in cli.rows(query))
        assert cli.observed > 0
        assert {p.relative_to(package).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in package.rglob("*") if p.is_file()} == package_before
        report = dict(status="PASS", cases=completed, observed_owned_descendants=cli.observed,
            binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), model_package_files=package_before,
            scope="Actual Minimal Core/Store/gate/installed native model worker/HTTP/credentials/context proof; no public-provider availability claim")
        (root / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report))
    finally:
        origin.terminate()
        try:
            origin.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            origin.kill()
            origin.communicate()
            raise AssertionError("controlled HTTP origin failed to close")


if __name__ == "__main__":
    main()

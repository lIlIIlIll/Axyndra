"""Linux real-OS-pipe companion, invoked by one exact fresh App unit case.

Never run during source authoring. No network or fake stdout callback. The
same fresh unit executable writes/flushes actual fd1, temporarily duplicated
to this pipe by the additive fixture. Formal unit reporting has another pipe.
An EPIPE/SIGPIPE/SDK exception discrepancy FAILS; it is not output ACK credit.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

MAX_BYTES = 1048576
CASE_SECONDS = 60
INNER_SECONDS = 45
KINDS = ("success", "borrow", "pressure", "partial", "rpc-eof", "rpc-once")


def require(value, reason):
    if not value:
        raise AssertionError(reason)


def read_json(path):
    return json.loads(path.read_bytes())


def error_oracle(value, large):
    # Independent original full-eight-field schema, not a mirror of the new
    # Runtime encoder. Duplicate map entries and all ten diagnostics matter.
    require(set(value) == {"kind", "code", "message", "retryable", "fallback_allowed", "fields",
                           "attempt_failure", "observation"}, "complete eight error fields")
    require(value["kind"] == "internal" and value["code"] == "frontend.error雪\0", "original error identity")
    message = "original failure雪🙂\0\n" + ("x" * 131072 if large else "tail95")
    require(value["message"] == message, "full Unicode/NUL/message bytes without truncation")
    require(value["retryable"] is True and value["fallback_allowed"] is True, "original error flags")
    require(value["fields"] == [{"name": "duplicate", "value": "first"},
                                {"name": "duplicate", "value": "second雪\0"}], "original ordered duplicate fields")
    require(value["attempt_failure"] == {"kind": "provider_protocol_error", "diagnostics": {
        "elapsed_millis": 11, "soft_deadline_millis": 12, "hard_deadline_millis": 13,
        "entered_completion_grace": True, "last_progress_kind": "tool_argument_progress",
        "last_progress_age_millis": 14, "provider_terminal_observed": True,
        "open_content_block_count": 15, "tool_calls_started": 16, "tool_calls_completed": 17}},
        "all original ten attempt diagnostics")
    require(value["observation"] == {"schema": "axyndra.operation-observation/v1", "trust": "untrusted_data", "authorizes_effects": False,
                                    "content": {"original": "雪\0🙂"}}, "frozen observation full original schema/bytes")


def canonical(state):
    for name in ("executed", "observed", "committed_operations", "completed_receipts", "canonical_items"):
        require(state[name] == 1, "single actual canonical execution " + name)
    require(state["unknown_receipts"] == 0, "no Unknown Receipt or replay")


def failure_values(value):
    if isinstance(value, dict):
        if set(value) == {"kind", "code", "message", "retryable", "fallback_allowed", "fields",
                          "attempt_failure", "observation"}:
            yield value
        else:
            for child in value.values():
                yield from failure_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from failure_values(child)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--case", required=True)
    parser.add_argument("--mode", choices=KINDS, required=True)
    args = parser.parse_args()
    require(sys.platform == "linux", "declared Linux native-pipe fixture only; no Windows support claim")
    repo, root = args.repo.resolve(strict=True), args.root.resolve(strict=True)
    require(args.case.startswith("ActualFrontendPhysicalIO95Tests."), "one exact owned child case")
    require(not (root / "physical-pipe-proof95.json").exists(), "fresh physical pipe evidence")
    env = os.environ.copy()
    env["AXYNDRA_FRONTEND_IO_CHILD95"] = str(root)
    data_read, data_write = os.pipe()
    actual_capacity = fcntl.fcntl(data_write, fcntl.F_SETPIPE_SZ, 4096)
    require(actual_capacity == fcntl.fcntl(data_write, fcntl.F_GETPIPE_SZ) == 4096,
            "actual kernel pipe capacity measured, not a mocked blocked-output flag")
    env["AXYNDRA_FRONTEND_DATA_FD95"] = str(data_write)
    command = [str(repo / "scripts/pinned_cangjie"), "cjpm", "test", "-m", "agent_app", "--skip-build",
               "--filter", args.case, "--parallel", "1", "--timeout-each=60s", "--no-color", "--no-progress"]
    started = time.monotonic()
    proc = subprocess.Popen(command, cwd=repo, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, pass_fds=(data_write,), start_new_session=True)
    os.close(data_write)
    # Real EOF on inherited fd0; once still binds actual handle.get() in child.
    proc.stdin.close()
    selector = selectors.DefaultSelector()
    for stream, name in ((proc.stdout, "unit_stdout"), (proc.stderr, "unit_stderr"), (data_read, "data")):
        descriptor = stream if isinstance(stream, int) else stream.fileno()
        os.set_blocking(descriptor, False)
        selector.register(descriptor, selectors.EVENT_READ, name)
    buffers = {name: bytearray() for name in ("unit_stdout", "unit_stderr", "data")}
    blocked = False
    data_open = True
    release_time = None
    window_seen = None
    raw_exit = None
    try:
        while selector.get_map() or proc.poll() is None:
            require(time.monotonic() - started < INNER_SECONDS, "real child/pipe drain exceeded 45s within original 60s case")
            if args.mode.startswith("rpc-") and not blocked and (root / "canonical-ready95").exists():
                if args.mode != "rpc-once" or (root / "once-returned95").exists():
                    # Drain the already-written prelude while the actual paid
                    # observer is held. Then stop reading this real data pipe.
                    while True:
                        try:
                            chunk = os.read(data_read, 65536)
                        except BlockingIOError:
                            break
                        require(chunk, "data pipe ended before original observer release")
                        buffers["data"].extend(chunk)
                        require(len(buffers["data"]) <= MAX_BYTES, "bounded original pipe corpus")
                    selector.unregister(data_read)
                    blocked = True
                    release_time = time.monotonic()
                    (root / "release-observer95").write_bytes(b"actual peer stopped reading original stdout\n")
            if blocked and window_seen is None and (root / "window-expired.json").exists():
                window_seen = time.monotonic()
                require(window_seen - release_time >= 5, "actual reviewed five-second exit window observed")
                state = read_json(root / "window-expired.json")
                require(state["mono_lower_bound_millis"] == 5000 and state["mono_upper_bound_millis"] == 6500,
                        "child measured original MonoTime window without widening it")
                require(state["bytes"] >= state["held_bytes"] and state["executed"] == state["observed"] == 1,
                        "actual original bank retains blocked producer/aliases, no fake early refund")
                selector.register(data_read, selectors.EVENT_READ, "data")
            for key, _ in selector.select(0.01):
                try:
                    chunk = os.read(key.fd, 4096)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                buffers[key.data].extend(chunk)
                require(len(buffers[key.data]) <= MAX_BYTES, "bounded real raw pipe " + key.data)
                if args.mode == "partial" and key.data == "data" and b'"type":"error"' in buffers["data"]:
                    # Real prefix accepted by OS reader; then close its actual
                    # last reader. No injected write error or synthetic ACK.
                    require(len(buffers["data"]) < 131072, "break after real partial frame, before complete payload")
                    selector.unregister(data_read)
                    os.close(data_read)
                    data_open = False
                    (root / "actual-reader-closed95").write_bytes(b"real partial pipe reader closed\n")
            if proc.poll() is not None and blocked and window_seen is None:
                raise AssertionError("child exited before observed-window receipt; physical exit is not ACK")
        raw_exit = proc.wait(timeout=1)
        require(raw_exit == 0, "actual fresh child unit failed (including SDK EPIPE/SIGPIPE behavior): " + str(raw_exit))
        # The unredirected same fresh unit reporter must confirm exactly one
        # selected test and zero errors/failures. No swallowed @Expect failure.
        report = bytes(buffers["unit_stdout"]).decode("utf8", "strict")
        summaries = re.findall(r'Summary: TOTAL:\s*(\d+)\s+PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)\s+FAILED:\s*(\d+)', report, re.I)
        require(bool(summaries), "actual child SDK summary required, not default PASS")
        total, passed, skipped, errors, failed = map(int, summaries[-1])
        require(total > 0 and passed == 1 and skipped == total - 1 and errors == failed == 0,
                "actual same fresh child unit reports one selected PASS/zero failures/errors with full original denominator")
        if args.mode.startswith("rpc-"):
            require(window_seen is not None, "real observed window before draining blocked SDK stdout")
            done = read_json(root / "rpc-done.json")
            require(done == {"workers_retired": True, "output_retired": True, "executed": 1, "observed": 1},
                    "actual Futures/output aliases retired after original pipe drains")
            values = []
            for raw in bytes(buffers["data"]).splitlines():
                require(bool(raw), "RPC StdOut frame is not an empty/truncated line")
                frame = json.loads(raw.decode("utf8", "strict"))
                values.extend(failure_values(frame))
            require(values, "full-eight-field RPC error reached actual stdout, not static marker")
            for value in values:
                error_oracle(value, True)
        else:
            before, done = read_json(root / "before.json"), read_json(root / "done.json")
            canonical(before)
            canonical(done)
            require(before["marker_in_slot"] and not before["source_ack"], "original paid caller identity initially retained")
            if args.mode == "partial":
                require(not data_open and not done["source_ack"] and done["cli_pending"],
                        "real partial/broken write keeps exact original source/controller/secondary paid")
                require(done["bytes"] >= before["bytes"], "no refund for unsuccessful actual output")
                require(bytes(buffers["data"]).count(b'"type":"error"') == 1,
                        "real partial prefix was not resent by repeated progress")
            else:
                require(done["source_ack"] and not done["cli_pending"] and not done["marker_in_slot"],
                        "original source ACK only after real complete write/flush/helper retirement")
                frames = [json.loads(raw) for raw in bytes(buffers["data"]).splitlines() if raw]
                require(len(frames) == 1 and frames[0]["type"] == "error", "exactly one original CLI output, no replay")
                error_oracle(frames[0]["error_data"], False)
                require(frames[0]["code"] == frames[0]["error_data"]["code"] and
                        frames[0]["message"] == frames[0]["error_data"]["message"], "original compatible prefix")
                if args.mode == "borrow":
                    state = read_json(root / "borrow-held.json")
                    require(not state["source_ack"] and state["cli_pending"], "original active loan blocks ACK despite real output")
                if args.mode == "pressure":
                    state = read_json(root / "pressure-refused.json")
                    require(state["marker_in_slot"] and not state["source_ack"], "same bank false admission preserves exact caller")
                    canonical(state)
        proof = {"status": "ACTUAL_LINUX_PIPE_CHILD_READY", "mode": args.mode, "command": command,
                 "physical_child_exit_code": raw_exit, "pipe_capacity": actual_capacity, "case_seconds": CASE_SECONDS,
                 "raw_files": {}, "source_ack_from_physical_exit": False, "no_mock_output": True,
                 "formal_Product_or_Root_credit": 0}
        for name, raw in buffers.items():
            path = root / (name + ".raw")
            path.write_bytes(raw)
            proof["raw_files"][path.name] = hashlib.sha256(raw).hexdigest()
        (root / "physical-pipe-proof95.json").write_text(json.dumps(proof, indent=2) + "\n", encoding="utf8")
        print(json.dumps({"status": proof["status"], "mode": args.mode, "exit_code": raw_exit}), flush=True)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
        selector.close()
        if data_open:
            os.close(data_read)
        for name, raw in buffers.items():
            (root / (name + ".raw")).write_bytes(raw)
        (root / "physical-child-exit95.json").write_text(json.dumps({"actual_exit": proc.returncode,
            "status": "PASS" if (root / "physical-pipe-proof95.json").exists() else "FAIL",
            "no_exit_as_ACK_credit": True}) + "\n", encoding="utf8")


if __name__ == "__main__":
    main()
